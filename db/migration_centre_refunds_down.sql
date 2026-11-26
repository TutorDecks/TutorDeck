-- Undo of migration_centre_refunds.sql (T4 step S5): drops the refund tables and functions and puts back the S3 centre_refund_family_credit and the S4 centre_revenue_totals.
-- DESTRUCTIVE: it deletes the refund records (a money record) and the "refund_id" / "request_key" columns on the two ledgers. Only for DEV and the test database;
-- never on a centre that has real refunds. Run the undo chain in reverse order (this one comes BEFORE migration_centre_deposits_down.sql).
-- If a credit or deposit was ever APPLIED to an invoice (internal payments with method 'family_credit' or 'deposit', or ledger rows of kind 'applied' on the
-- credit ledger), the widened checks are KEPT (they would otherwise destroy an issued payment); everything else is undone.
drop trigger if exists centre_internal_method_guard on public.centre_payments;
drop function if exists public.centre_internal_method_guard();
drop function if exists public.centre_refund_statement(uuid);
drop function if exists public.centre_refund_list(uuid, text);
drop function if exists public.centre_refund_cancel(uuid, text);
drop function if exists public.centre_refund_pay(uuid, text, date, text, text);
drop function if exists public.centre_refund_approve(uuid, text);
drop function if exists public.centre_refund_settle(centre_refunds, date, text, date, text, text);
drop function if exists public.centre_deposit_refund_request(uuid, bigint, bigint, bigint, date, text, text, text);
drop function if exists public.centre_deposit_release_proposal(uuid, date);
drop function if exists public.centre_credit_refund_request(uuid, uuid, bigint, text, text, text);
drop function if exists public.centre_apply_family_credit(uuid, uuid, uuid[], bigint, text);
drop function if exists public.centre_family_credit_status(uuid, uuid);
drop function if exists public.centre_refund_json(uuid);
drop function if exists public.centre_allocate_held(uuid, uuid, text, bigint, uuid[], uuid, date, text);
drop function if exists public.centre_deposit_gst_share(uuid, uuid, bigint);
drop function if exists public.centre_clean_reference(text);
drop function if exists public.centre_person_name(uuid, uuid);
drop function if exists public.centre_deposit_held_cents(uuid, uuid);
drop function if exists public.centre_credit_reserved(uuid, uuid);
drop function if exists public.centre_deposit_reserved(uuid, uuid);
drop function if exists public.centre_refund_state(uuid);
drop function if exists public.centre_refund_rule(uuid, date);
drop function if exists public.centre_refund_can_approve(uuid, text, uuid, text);
drop function if exists public.centre_refund_gate(uuid, text);
alter table public.centre_deposit_ledger drop constraint if exists centre_deposit_ledger_refund_fk;
alter table public.centre_family_credit drop constraint if exists centre_family_credit_refund_fk;
drop table if exists public.centre_refund_events cascade;
drop table if exists public.centre_refunds cascade;
drop function if exists public.centre_refund_event_guard();
drop function if exists public.centre_refund_guard();
drop index if exists public.centre_family_credit_applied_key;
alter table public.centre_deposit_ledger drop column if exists refund_id;
alter table public.centre_family_credit drop column if exists refund_id;
alter table public.centre_family_credit drop column if exists request_key;
do $$ begin
  if exists (select 1 from public.centre_payments where method in ('family_credit', 'deposit')) or exists (select 1 from public.centre_family_credit where kind = 'applied') then
    raise notice 'Credit or deposit was applied to invoices: the widened method / kind checks are kept';
  else
    alter table public.centre_payments drop constraint if exists centre_payments_method_s5;
    alter table public.centre_payments add constraint centre_payments_method_check check (method in ('manual_paynow', 'bank', 'cash', 'cheque', 'other'));
    alter table public.centre_family_credit drop constraint if exists centre_family_credit_kind_s5;
    alter table public.centre_family_credit add constraint centre_family_credit_kind_check check (kind in ('overpayment', 'credit_note_excess', 'payment_reversal', 'excess_release', 'refund'));
  end if;
end $$;

-- the S3 and S4 functions, as they were
create or replace function public.centre_refund_family_credit(p_org uuid, p_household uuid, p_cents bigint, p_method text, p_reference text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := centre_money_gate(p_org, 'owner'); why text := nullif(trim(coalesce(p_reason, '')), ''); ref text := nullif(trim(coalesce(p_reference, '')), ''); bal bigint;
begin
  if not exists (select 1 from households h where h.id = p_household and h.org_id = p_org) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_cents is null or p_cents <= 0 then raise exception 'BAD_VALUE: the refund must be more than S$0.00' using errcode = 'P0001'; end if;
  if p_method is null or p_method not in ('manual_paynow', 'bank', 'cash', 'cheque', 'other') then raise exception 'BAD_VALUE: choose how it was paid back' using errcode = 'P0001'; end if;
  if why is null then raise exception 'REASON_REQUIRED: say why this is being refunded' using errcode = 'P0001'; end if;
  if length(why) > 300 or length(coalesce(ref, '')) > 120 then raise exception 'TOO_LONG: keep the reason under 300 and the reference under 120 characters' using errcode = 'P0001'; end if;
  bal := centre_credit_balance(p_org, p_household);
  if p_cents > bal then raise exception 'CREDIT_SHORT: this family holds only %', centre_fmt_money(bal) using errcode = '42501'; end if;
  insert into centre_family_credit(org_id, household_id, kind, cents, method, reference, reason) values (p_org, p_household, 'refund', -p_cents, p_method, ref, why);
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), 'centre_family_credit_refund', 'centre_family_credit', p_household::text, jsonb_build_object('balance_cents', bal),
          jsonb_build_object('refunded_cents', p_cents, 'method', p_method, 'balance_cents', bal - p_cents));
  return jsonb_build_object('refunded_cents', p_cents, 'balance_cents', bal - p_cents);
end $$;

create or replace function public.centre_revenue_totals(p_org uuid, p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb; dep_in bigint; dep_held bigint;
begin
  if auth.uid() is null or not exists (select 1 from organisations o where o.id = p_org and o.kind = 'centre') or not org_can(p_org, 'view_revenue') then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  select jsonb_build_object(
    'invoiced_cents',  coalesce(sum(i.total_cents) filter (where i.kind not in ('credit_note', 'deposit')), 0),
    'gst_cents',       coalesce(sum(i.gst_cents) filter (where i.kind <> 'credit_note'), 0) - coalesce(sum(i.gst_cents) filter (where i.kind = 'credit_note'), 0),
    'credited_cents',  coalesce(sum(i.total_cents) filter (where i.kind = 'credit_note' and coalesce(ci.kind, '') <> 'deposit'), 0),
    'invoices',        count(*) filter (where i.kind not in ('credit_note', 'deposit')),
    'deposits_invoiced_cents', coalesce(sum(i.total_cents) filter (where i.kind = 'deposit'), 0))
    into r from centre_invoices i left join centre_invoices ci on ci.id = i.credits_invoice_id and ci.org_id = i.org_id
   where i.org_id = p_org and i.status = 'issued' and (p_from is null or i.issue_date >= p_from) and (p_to is null or i.issue_date <= p_to);
  select coalesce(sum(a.cents), 0) into dep_in
    from centre_payment_allocations a join centre_payments p on p.id = a.payment_id and p.org_id = a.org_id
    join centre_invoices i on i.id = a.invoice_id and i.org_id = a.org_id and i.kind = 'deposit'
   where a.org_id = p_org and (p_from is null or p.received_on >= p_from) and (p_to is null or p.received_on <= p_to);
  select coalesce(sum(cents) filter (where kind <> 'waived'), 0) into dep_held from centre_deposit_ledger where org_id = p_org;
  r := r || jsonb_build_object('received_cents', coalesce((select sum(case when p.kind = 'payment' then p.amount_cents else -p.amount_cents end)
       from centre_payments p where p.org_id = p_org and (p_from is null or p.received_on >= p_from) and (p_to is null or p.received_on <= p_to)), 0) - dep_in,
       'deposits_received_cents', dep_in, 'deposits_held_cents', dep_held);
  return r;
end $$;

grant execute on function public.centre_refund_family_credit(uuid, uuid, bigint, text, text, text), public.centre_revenue_totals(uuid, date, date) to authenticated, service_role;
