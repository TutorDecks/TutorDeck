-- =====================================================================================================
-- B4-FIX — "Record payment" failed with "Something went wrong" (PostgREST error 21000)   undo: migration_payment_fix_down.sql
-- =====================================================================================================
-- Run order: AFTER migration_centre_payments.sql (any time after; it only replaces one function). Run on the DEV project first. Safe to run twice.
-- Needs no data change and reads/changes no row.
--
-- CAUSE: centre_record_payment cleared its scratch table with `delete from _td_pay_open;` (no WHERE). Supabase's API layer runs the pg-safeupdate
-- extension, which refuses any DELETE or UPDATE without a WHERE clause with SQLSTATE 21000 ("DELETE requires a WHERE clause"). The throwaway test
-- Postgres has no such extension, so the SQL tests passed. Only this one statement was affected (every other DELETE / UPDATE in the migrations has a WHERE).
-- FIX: the same function with `delete from _td_pay_open where true;` (the scratch table is per-transaction, so it is empty on a first call anyway).
-- Behaviour is otherwise identical; grants are kept by CREATE OR REPLACE and restated below.
-- =====================================================================================================

create or replace function public.centre_record_payment(p_org uuid, p_household uuid, p_method text, p_amount_cents bigint, p_received_on date,
  p_reference text default null, p_invoice_ids uuid[] default null, p_payer_name text default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := centre_money_gate(p_org, 'record_payments'); s jsonb; partial boolean; mode text; modes jsonb;
  hh uuid := p_household; pid uuid := gen_random_uuid(); ref text := nullif(trim(coalesce(p_reference, '')), ''); payer text := nullif(trim(coalesce(p_payer_name, '')), '');
  note text := nullif(trim(coalesce(p_note, '')), ''); explicit boolean := coalesce(cardinality(p_invoice_ids), 0) > 0; r record; bad record;
  remaining bigint; take bigint; allocated jsonb := '[]'::jsonb; n_alloc int := 0; excess bigint := 0; hh_i uuid; ids uuid[]; open_n int;
begin
  if p_method is null or p_method not in ('manual_paynow', 'bank', 'cash', 'cheque', 'other') then
    raise exception 'BAD_VALUE: choose how it was paid (PayNow, bank transfer, cash, cheque or other)' using errcode = 'P0001'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'BAD_VALUE: the amount must be more than S$0.00' using errcode = 'P0001'; end if;
  if p_amount_cents > 100000000 then raise exception 'BAD_VALUE: that amount is too large to be right (over S$1,000,000)' using errcode = 'P0001'; end if;
  if p_received_on is null then raise exception 'BAD_VALUE: say the date it was received' using errcode = 'P0001'; end if;
  if p_received_on > today then raise exception 'BAD_VALUE: the date received can''t be in the future' using errcode = 'P0001'; end if;
  if p_received_on < today - 1825 then raise exception 'BAD_VALUE: the date received is too far back (over 5 years)' using errcode = 'P0001'; end if;
  if length(coalesce(ref, '')) > 120 or length(coalesce(payer, '')) > 120 or length(coalesce(note, '')) > 300 then
    raise exception 'TOO_LONG: keep the reference and name under 120 characters and the note under 300' using errcode = 'P0001'; end if;
  s := org_settings_on(p_org, today);
  if s is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  partial := coalesce((s#>>'{payments,partial_payments}')::boolean, true);
  mode := centre_overpay_mode(s);
  modes := coalesce(s#>'{payments,modes}', '[]'::jsonb);
  if p_method = 'manual_paynow' and not (modes ? 'manual_paynow') then
    raise exception 'NOT_ALLOWED: manual PayNow isn''t switched on in this centre''s payment settings (cash, bank transfer and cheque still can be recorded)' using errcode = '42501'; end if;

  -- which household? (from the chosen invoices when it isn't given)
  if explicit then
    select array(select distinct x from unnest(p_invoice_ids) x) into ids;
    for r in select i.id, i.status, i.kind, i.number_text, centre_invoice_household(i.id) as hid from centre_invoices i where i.org_id = p_org and i.id = any(ids) loop
      if r.status <> 'issued' or r.kind = 'credit_note' then raise exception 'NOT_ALLOWED: % can''t be paid (only an issued invoice can)', coalesce(r.number_text, 'that document') using errcode = '42501'; end if;
      if hh is null then hh := r.hid; end if;
      if r.hid is distinct from hh then raise exception 'NOT_ALLOWED: those invoices belong to different families; record one payment per family' using errcode = '42501'; end if;
    end loop;
    if (select count(*) from centre_invoices where org_id = p_org and id = any(ids)) <> cardinality(ids) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  end if;
  if hh is null then raise exception 'BAD_VALUE: choose which family paid' using errcode = 'P0001'; end if;
  if not exists (select 1 from households h where h.id = hh and h.org_id = p_org) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended(hh::text, 4));      -- two people recording for the same family: one waits

  -- the invoices this payment may cover, in the order money is applied: oldest issued first (issue date, then number)
  create temp table if not exists _td_pay_open(invoice_id uuid, number_text text, total_cents bigint, balance_cents bigint, ord int) on commit drop;
  delete from _td_pay_open where true;                                 -- Supabase refuses a DELETE with no WHERE (pg-safeupdate, SQLSTATE 21000)
  insert into _td_pay_open
    select i.id, i.number_text, i.total_cents, b.balance_cents, (row_number() over (order by i.issue_date, i.number_seq))::int
      from centre_invoices i, lateral centre_balance_rows(p_org, array[i.id]) b
     where i.org_id = p_org and i.status = 'issued' and i.kind <> 'credit_note'
       and (case when explicit then i.id = any(ids)
                 else (i.household_id = hh or (i.household_id is null and i.student_id in (select s2.id from students s2 where s2.household_id = hh and s2.org_id = p_org))) end);
  if explicit then
    select * into bad from _td_pay_open where balance_cents = 0 limit 1;
    if bad.invoice_id is not null then raise exception 'NOT_ALLOWED: % is already paid in full', bad.number_text using errcode = '42501'; end if;
  end if;
  select count(*) into open_n from _td_pay_open where balance_cents > 0;

  -- partial payments switched off: the money must cover whole invoices (the first one it can't finish is named)
  if not partial and open_n > 0 then
    remaining := p_amount_cents;
    for r in select * from _td_pay_open where balance_cents > 0 order by ord loop
      if remaining < r.balance_cents then
        raise exception 'PART_NOT_ALLOWED: this centre doesn''t accept part payments, so a payment has to cover whole invoices. % still owes %.', r.number_text, centre_fmt_money(r.balance_cents) using errcode = '42501';
      end if;
      remaining := remaining - r.balance_cents;
    end loop;
  end if;

  insert into centre_payments(id, org_id, kind, household_id, method, amount_cents, received_on, reference, payer_name, note)
  values (pid, p_org, 'payment', hh, p_method, p_amount_cents, p_received_on, ref, payer, note);
  remaining := p_amount_cents;
  for r in select * from _td_pay_open where balance_cents > 0 order by ord loop
    exit when remaining <= 0;
    take := least(remaining, r.balance_cents);
    insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (p_org, pid, r.invoice_id, take);
    remaining := remaining - take; n_alloc := n_alloc + 1;
    allocated := allocated || jsonb_build_object('invoice_id', r.invoice_id, 'number', r.number_text, 'cents', take, 'balance_after_cents', r.balance_cents - take);
  end loop;
  excess := remaining;
  if excess > 0 then
    insert into centre_family_credit(org_id, household_id, kind, handling, cents, payment_id, reason)
    values (p_org, hh, 'overpayment', mode, excess, pid, case when open_n = 0 then 'Paid in advance: nothing was owed' else 'More than the open invoices came to' end);
  end if;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), 'centre_payment_record', 'centre_payments', pid::text, null,
          jsonb_build_object('method', p_method, 'amount_cents', p_amount_cents, 'received_on', p_received_on, 'invoices_covered', n_alloc, 'excess_cents', excess, 'excess_handling', case when excess > 0 then mode end));
  return jsonb_build_object('payment_id', pid, 'household_id', hh, 'amount_cents', p_amount_cents, 'allocated', allocated, 'excess_cents', excess,
                            'excess_handling', case when excess > 0 then mode end, 'credit_balance_cents', centre_credit_balance(p_org, hh));
end $$;

revoke all on function public.centre_record_payment(uuid, uuid, text, bigint, date, text, uuid[], text, text) from public, anon;
grant execute on function public.centre_record_payment(uuid, uuid, text, bigint, date, text, uuid[], text, text) to authenticated, service_role;
