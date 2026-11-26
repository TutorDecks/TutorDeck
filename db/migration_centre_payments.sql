-- =====================================================================================================
-- T4 step S3 — centre payments: record a payment, part payments, overpayment, credit notes, status, share link, WhatsApp   undo: migration_centre_payments_down.sql
-- =====================================================================================================
-- Run order everywhere: org_foundation → billing → attendance → tutor_access → org_delete → function_lockdown → org_separation →
--   staff_home → staff_students → staff_attendance → staff_charges → staff_trials → staff_timetable → centre_money → centre_invoice_run → centre_payments.
-- Needs migration_centre_money.sql (S1: payments, allocations, the credit-note kind, numbering, GST) and migration_centre_invoice_run.sql (S2: issued invoices).
-- Run on the DEV project first. LIVE only when the owner says ship (it reads and changes no existing row: two new tables, one index, new functions).
-- Safe to run twice.
--
-- WHAT IT ADDS (database only; the screens are Money > Invoices and the public page pay.html)
--   centre_record_payment(org, household, method, amount, received_on, reference [, invoices, payer, note])
--                         allocates to the invoices the person chose, or OLDEST ISSUED INVOICE FIRST (issue date, then number) when none are chosen.
--                         A part payment leaves the invoice "part-paid". Whatever is left after every open invoice is covered is NEVER LOST: it is
--                         written to the family's credit ledger (see centre_family_credit below).
--   centre_reverse_payment(payment, reason)   a wrong payment is never edited: a REVERSING row is added (the original row is untouched), the
--                         money it covered is released from the invoices, any credit it created is taken back, and statuses recalculate.
--   centre_issue_credit_note(invoice, amount | lines, reason)   a credit note is its own immutable, numbered document (the S1 table, kind credit_note).
--                         NUMBERING: credit notes do NOT share the invoice counter. They have their own series "credit_note", gap-free, printed
--                         "CN-<prefix>-<n>" (CN-INV-1, CN-INV-2 ...). GST: the credit uses the GST rules FROZEN on the invoice it credits and the shared
--                         centre_gst_totals() (so it matches assets/js/money.js); the amount a person types is what the family is credited, GST included.
--   centre_invoice_account_list / centre_invoice_account_get / centre_pay_status   computed status of every issued invoice:
--                         issued · part_paid · paid · overdue (the due date has passed and something is owed) · void (a credit note covers it all).
--                         Nothing is stored: paid = allocations, credited = issued credit notes. Indexed for lists of ~400 families.
--   centre_invoice_share_link / centre_invoice_public / centre_invoice_whatsapp   a secret link per issued invoice (no login), the public read-only
--                         view it opens, and the WhatsApp message (the centre's own wording, a wa.me target).
--   centre_family_credit_get / centre_refund_family_credit   the family credit ledger (append-only) and the owner-only record of a refund.
--
-- THE CENTRE'S SETTINGS THAT DECIDE THINGS (read as of the day the payment is recorded; a process rule, not a money rule)
--   payments.partial_payments  true  → a payment may cover part of an invoice (it becomes part-paid)
--                              false → REFUSED unless every invoice the payment touches is covered in full. Never leaves an invoice part-paid.
--   payments.overpayments      credit → the extra is "credit held for the family"   refund → the extra is "to refund to the family"
--                              (same ledger row, a different label, so nothing is silently kept; the owner records the refund with centre_refund_family_credit)
--   payments.modes             manual PayNow may only be recorded if the centre switched manual PayNow on (cash, bank transfer, cheque and other always can)
--   invoicing.delivery.share_link  false → no share link is made and the public page shows nothing
--   invoicing.whatsapp_template    the message wording ({name} {centre} {number} {amount} {due_date} {link}); a default is used when the centre set none
--
-- WHO MAY CALL
--   record / reverse / credit ledger: an active OWNER or STAFF with `record_payments`.   credit note, share link, WhatsApp: OWNER or STAFF with `issue_invoices`.
--   the account list and one invoice's account: either permission (payment REFERENCES and payer names are shown only to `record_payments`).
--   refunding family credit: OWNER only (owner-approved decision).   Tutors, parents, switched-off staff, strangers, solo organisations and unknown ids
--   all get the same NOT_FOUND. The public view needs only the secret token; a wrong, expired or rotated token returns nothing (null).
-- AUDIT: the S1 triggers copy every row with payment references, payer names, notes and reasons replaced by "[redacted]" (PDPA); the share token is
--   redacted too; the summary line each function writes carries amounts and counts only, never a reference or a name.
-- =====================================================================================================

-- ---------------------------------------------------------------------------------------------------
-- 1. tables: the family credit ledger and the share links
-- ---------------------------------------------------------------------------------------------------
create table if not exists public.centre_family_credit (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organisations(id) on delete cascade,
  household_id uuid not null,
  kind         text not null check (kind in ('overpayment', 'credit_note_excess', 'payment_reversal', 'excess_release', 'refund')),
  handling     text check (handling in ('credit', 'refund')),       -- + rows: what the centre's setting said at the time (held as credit / to refund)
  cents        bigint not null check (cents <> 0),                  -- + the family is owed it · − it was taken back / paid back
  payment_id   uuid,
  invoice_id   uuid,
  method       text,                                                -- refunds: how it was paid back
  reference    text,                                                -- refunds: free text, never a full account number; redacted in the audit copy
  reason       text,                                                -- redacted in the audit copy
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now(),
  unique (id, org_id),
  foreign key (household_id, org_id) references public.households(id, org_id),
  foreign key (payment_id, org_id) references public.centre_payments(id, org_id),
  foreign key (invoice_id, org_id) references public.centre_invoices(id, org_id),
  check ((kind in ('overpayment', 'credit_note_excess')) = (cents > 0))
);
create index if not exists centre_family_credit_household on public.centre_family_credit(org_id, household_id);
create index if not exists centre_family_credit_payment on public.centre_family_credit(payment_id) where payment_id is not null;
create index if not exists centre_family_credit_invoice on public.centre_family_credit(invoice_id) where invoice_id is not null;

create table if not exists public.centre_invoice_share (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organisations(id) on delete cascade,
  invoice_id  uuid not null,
  token       uuid not null unique default gen_random_uuid(),       -- the secret in the link. 122 random bits; never logged, never listed
  expires_on  date,                                                 -- null = no expiry; valid through that day in the centre's time zone
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  rotated_at  timestamptz,
  unique (invoice_id),
  unique (id, org_id),
  foreign key (invoice_id, org_id) references public.centre_invoices(id, org_id) on delete cascade
);

-- the list of open invoices ("unpaid", "overdue") reads by due date
create index if not exists centre_invoices_open on public.centre_invoices(org_id, due_date) where status = 'issued' and kind <> 'credit_note';

-- ---------------------------------------------------------------------------------------------------
-- 2. guards and audit for the two tables
-- ---------------------------------------------------------------------------------------------------
-- the credit ledger is append-only, and a family's balance can never go below zero (you can't give back what you don't hold)
create or replace function public.centre_family_credit_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare bal bigint;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    if tg_op = 'DELETE' and centre_money_deleting(old.org_id) then return old; end if;
    raise exception 'The family credit ledger is append-only (a correction is a new row)' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(new.household_id::text, 5));
  select coalesce(sum(cents), 0) + new.cents into bal from centre_family_credit where org_id = new.org_id and household_id = new.household_id;
  if bal < 0 then
    raise exception 'CREDIT_SHORT: that would take the family''s credit below zero (they hold % cents)', bal - new.cents using errcode = '23514';
  end if;
  return new;
end $$;

-- the share row: same audit as the money tables but the token is never copied into the audit log
create or replace function public.centre_share_audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare b jsonb; a jsonb;
begin
  if coalesce(current_setting('td.skip_audit', true), '') = '1' then return null; end if;
  b := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) - 'token' end;
  a := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) - 'token' end;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (coalesce((a->>'org_id')::uuid, (b->>'org_id')::uuid), auth.uid(), lower(tg_op), tg_table_name, coalesce(a->>'id', b->>'id'), b, a);
  return null;
end $$;

drop trigger if exists centre_money_org_guard on public.centre_family_credit;
create trigger centre_money_org_guard before insert on public.centre_family_credit for each row execute function public.centre_money_org_guard();
drop trigger if exists centre_money_org_guard on public.centre_invoice_share;
create trigger centre_money_org_guard before insert on public.centre_invoice_share for each row execute function public.centre_money_org_guard();
drop trigger if exists audit_row on public.centre_family_credit;
create trigger audit_row after insert or update or delete on public.centre_family_credit for each row execute function public.centre_money_audit();
drop trigger if exists audit_row on public.centre_invoice_share;
create trigger audit_row after insert or update or delete on public.centre_invoice_share for each row execute function public.centre_share_audit();
drop trigger if exists centre_family_credit_guard on public.centre_family_credit;
create trigger centre_family_credit_guard before insert or update or delete on public.centre_family_credit for each row execute function public.centre_family_credit_guard();

-- access: the credit ledger is readable by record_payments (like payments); the share table by NOBODY (the token is a secret: functions only)
alter table public.centre_family_credit enable row level security;
alter table public.centre_invoice_share enable row level security;
drop policy if exists money_read on public.centre_family_credit;
create policy money_read on public.centre_family_credit for select using (org_can(org_id, 'record_payments') and not org_is_solo(org_id));
revoke all on public.centre_family_credit, public.centre_invoice_share from anon, authenticated;
grant select on public.centre_family_credit to authenticated;

-- ---------------------------------------------------------------------------------------------------
-- 3. small helpers (internal)
-- ---------------------------------------------------------------------------------------------------
-- "S$1,234.50" for messages
create or replace function public.centre_fmt_money(c bigint) returns text
language sql immutable set search_path = public as $$
  select case when c < 0 then '-' else '' end || 'S$' || to_char(abs(c) / 100, 'FM999,999,990') || '.' || lpad((abs(c) % 100)::text, 2, '0')
$$;

-- the gate every function here starts with: who, which permission, and the centre's own "today".
--   p_perm: 'record_payments' | 'issue_invoices' | 'either' | 'owner'
create or replace function public.centre_money_gate(p_org uuid, p_perm text) returns date
language plpgsql stable security definer set search_path = public as $$
declare tz text; ok boolean;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select o.timezone into tz from organisations o where o.id = p_org and o.kind = 'centre';
  if tz is null or not exists (select 1 from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active'
                               and m.role in ('owner', 'staff')) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  ok := case p_perm when 'either' then org_can(p_org, 'issue_invoices') or org_can(p_org, 'record_payments')
                    when 'owner' then org_can(p_org, 'owner')
                    else org_can(p_org, p_perm) end;
  if not ok then
    raise exception 'NOT_ALLOWED: your account can''t % at this centre',
      case p_perm when 'record_payments' then 'record or reverse payments' when 'issue_invoices' then 'issue credit notes or share invoices'
                  when 'owner' then 'do that (only the centre owner can)' else 'see invoices and payments' end using errcode = '42501';
  end if;
  return (now() at time zone tz)::date;
end $$;

-- the status of an issued invoice, from what is stored. Precedence: void > paid > overdue > part_paid > issued.
create or replace function public.centre_pay_status(p_status text, p_kind text, p_total bigint, p_credited bigint, p_paid bigint, p_due date, p_today date)
returns text language sql immutable set search_path = public as $$
  select case
    when p_status = 'draft' then 'draft'
    when p_status = 'void' then 'discarded'
    when p_kind = 'credit_note' then 'credit_note'
    when p_total > 0 and p_credited >= p_total then 'void'
    when p_total - p_credited - p_paid <= 0 then 'paid'
    when p_due is not null and p_due < p_today then 'overdue'
    when p_paid > 0 then 'part_paid'
    else 'issued' end
$$;

-- what an invoice has received, been credited and still owes (never below zero; an excess lives in the family credit ledger)
create or replace function public.centre_balance_rows(p_org uuid, p_ids uuid[])
returns table(invoice_id uuid, total_cents bigint, credited_cents bigint, paid_cents bigint, balance_cents bigint)
language sql stable security definer set search_path = public as $$
  select i.id, i.total_cents, coalesce(c.cr, 0)::bigint, coalesce(a.pd, 0)::bigint, greatest(i.total_cents - coalesce(c.cr, 0) - coalesce(a.pd, 0), 0)::bigint
    from centre_invoices i
    left join lateral (select sum(n.total_cents) cr from centre_invoices n where n.credits_invoice_id = i.id and n.status = 'issued') c on true
    left join lateral (select sum(x.cents) pd from centre_payment_allocations x where x.invoice_id = i.id) a on true
   where i.org_id = p_org and i.id = any(p_ids)
$$;

-- the household an invoice is billed to (a per-student invoice may carry only the student)
create or replace function public.centre_invoice_household(p_invoice uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce(i.household_id, (select s.household_id from students s where s.id = i.student_id and s.org_id = i.org_id))
    from centre_invoices i where i.id = p_invoice
$$;

-- the family's held credit, in cents
create or replace function public.centre_credit_balance(p_org uuid, p_household uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(sum(cents), 0)::bigint from centre_family_credit where org_id = p_org and household_id = p_household
$$;

-- "how the centre wants an overpayment handled", with anything unexpected read as the safe default (held as credit, never lost)
create or replace function public.centre_overpay_mode(p_settings jsonb) returns text
language sql immutable set search_path = public as $$ select case p_settings #>> '{payments,overpayments}' when 'refund' then 'refund' else 'credit' end $$;

-- An invoice must never be "overpaid" without the family holding the difference (a credit note can arrive after a payment, and a reversal can
-- take a payment away again). This writes the single row that makes the ledger match:  expected = max(paid + credited − total, 0).
create or replace function public.centre_sync_invoice_excess(p_invoice uuid, p_mode text) returns bigint
language plpgsql security definer set search_path = public as $$
declare inv centre_invoices; b record; hh uuid; expected bigint; have bigint; d bigint;
begin
  select * into inv from centre_invoices where id = p_invoice;
  select * into b from centre_balance_rows(inv.org_id, array[p_invoice]);
  hh := centre_invoice_household(p_invoice);
  expected := greatest(b.paid_cents + b.credited_cents - b.total_cents, 0);
  select coalesce(sum(cents), 0) into have from centre_family_credit where invoice_id = p_invoice and kind in ('credit_note_excess', 'excess_release');
  d := expected - have;
  if d = 0 then return 0; end if;
  if hh is null then raise exception 'NOT_ALLOWED: that invoice has no family on it, so there is nowhere to hold the extra money' using errcode = '42501'; end if;
  insert into centre_family_credit(org_id, household_id, kind, handling, cents, invoice_id, reason)
  values (inv.org_id, hh, case when d > 0 then 'credit_note_excess' else 'excess_release' end, case when d > 0 then p_mode end, d, p_invoice,
          case when d > 0 then 'A credit note left the invoice paid for more than it now costs' else 'Payment reversed: the invoice is no longer paid for more than it costs' end);
  return d;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 4. RECORD A PAYMENT
-- ---------------------------------------------------------------------------------------------------
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
  delete from _td_pay_open;
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

-- ---------------------------------------------------------------------------------------------------
-- 5. REVERSE A PAYMENT (never an edit: a reversing row, the original untouched)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_reverse_payment(p_payment uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare org uuid; today date; p centre_payments; why text := nullif(trim(coalesce(p_reason, '')), ''); rid uuid := gen_random_uuid(); a record;
  s jsonb; credit_back bigint; released int := 0; invs jsonb := '[]'::jsonb; d bigint; st text;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select org_id into org from centre_payments where id = p_payment;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := centre_money_gate(org, 'record_payments');
  select * into p from centre_payments where id = p_payment and org_id = org;
  if p.kind <> 'payment' then raise exception 'NOT_ALLOWED: that is already a reversal; record a new payment instead' using errcode = '42501'; end if;
  if why is null then raise exception 'REASON_REQUIRED: say why you are reversing this payment' using errcode = 'P0001'; end if;
  if length(why) > 300 then raise exception 'TOO_LONG: keep the reason under 300 characters' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p.household_id::text, 4));
  if exists (select 1 from centre_payments where reverses_payment_id = p.id and org_id = org) then
    raise exception 'ALREADY_REVERSED: that payment was already reversed' using errcode = 'P0001'; end if;
  s := org_settings_on(org, today);
  insert into centre_payments(id, org_id, kind, reverses_payment_id, household_id, method, amount_cents, received_on, note)
  values (rid, org, 'reversal', p.id, p.household_id, p.method, p.amount_cents, greatest(today, p.received_on), why);
  for a in select invoice_id, sum(cents) as cents from centre_payment_allocations where payment_id = p.id and org_id = org group by invoice_id having sum(cents) > 0 loop
    insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (org, rid, a.invoice_id, -a.cents);
    released := released + 1;
  end loop;
  -- the extra this payment put in the family's credit comes back out (refused if the family already had it paid back)
  select coalesce(sum(cents), 0) into credit_back from centre_family_credit where payment_id = p.id and org_id = org and kind = 'overpayment';
  if credit_back > 0 then
    insert into centre_family_credit(org_id, household_id, kind, cents, payment_id, reason)
    values (org, p.household_id, 'payment_reversal', -credit_back, p.id, 'The payment was reversed');
  end if;
  -- an invoice that had been credit-noted AFTER this payment no longer holds extra money for the family
  for a in select distinct invoice_id from centre_payment_allocations where payment_id = rid and org_id = org loop
    d := centre_sync_invoice_excess(a.invoice_id, centre_overpay_mode(s));
  end loop;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (org, auth.uid(), 'centre_payment_reverse', 'centre_payments', p.id::text, jsonb_build_object('amount_cents', p.amount_cents, 'method', p.method),
          jsonb_build_object('reversal_id', rid, 'invoices_released', released, 'credit_taken_back_cents', credit_back));
  return jsonb_build_object('reversal_id', rid, 'payment_id', p.id, 'invoices_released', released, 'credit_taken_back_cents', credit_back,
                            'credit_balance_cents', centre_credit_balance(org, p.household_id));
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 6. CREDIT NOTE (its own immutable document and number series)
-- ---------------------------------------------------------------------------------------------------
-- the pre-GST subtotal whose total (with GST) is exactly p_total, or null if no such subtotal exists (a few totals can't be made at some rates)
create or replace function public.centre_credit_subtotal(p_total bigint, p_rate_bp int, p_inclusive boolean, p_registered boolean) returns bigint
language plpgsql immutable set search_path = public as $$
declare s0 bigint; d int; s bigint;
begin
  if not coalesce(p_registered, false) or coalesce(p_rate_bp, 0) = 0 or coalesce(p_inclusive, false) then return p_total; end if;
  s0 := centre_div_round(p_total * 10000, 10000 + p_rate_bp);
  foreach d in array array[0, -1, 1, -2, 2] loop
    s := s0 + d;
    if s > 0 and (select t.total_cents from centre_gst_totals(s, p_rate_bp, false, true) t) = p_total then return s; end if;
  end loop;
  return null;
end $$;

create or replace function public.centre_issue_credit_note(p_invoice uuid, p_amount_cents bigint, p_reason text, p_lines jsonb default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare org uuid; today date; inv centre_invoices; b record; why text := nullif(trim(coalesce(p_reason, '')), ''); nid uuid := gen_random_uuid(); sub bigint; g record;
  l jsonb; i int := 0; desc_t text; qty int; unit bigint; cn centre_invoices; s jsonb; left_c bigint; excess bigint; lines_n int; alt1 bigint; alt2 bigint;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into inv from centre_invoices where id = p_invoice;
  if inv.id is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  org := inv.org_id;
  today := centre_money_gate(org, 'issue_invoices');
  if inv.status <> 'issued' or inv.kind = 'credit_note' then raise exception 'NOT_ALLOWED: only an issued invoice can be credited' using errcode = '42501'; end if;
  if why is null then raise exception 'REASON_REQUIRED: say why this credit note is being issued' using errcode = 'P0001'; end if;
  if length(why) > 300 then raise exception 'TOO_LONG: keep the reason under 300 characters' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended(inv.id::text, 0));
  select * into b from centre_balance_rows(org, array[inv.id]);
  left_c := b.total_cents - b.credited_cents;
  if left_c <= 0 then raise exception 'NOT_ALLOWED: that invoice is already credited in full' using errcode = '42501'; end if;
  s := org_settings_on(org, today);

  -- the lines: either the ones given (before GST when the invoice's prices exclude GST) or one line made from the amount (GST included)
  if p_lines is not null and jsonb_typeof(p_lines) = 'array' and jsonb_array_length(p_lines) > 0 then
    if jsonb_array_length(p_lines) > 50 then raise exception 'BAD_VALUE: a credit note can have up to 50 lines' using errcode = 'P0001'; end if;
    sub := 0;
    for l in select * from jsonb_array_elements(p_lines) loop
      desc_t := nullif(trim(coalesce(l->>'description', '')), ''); qty := coalesce((l->>'qty')::int, 1); unit := (l->>'unit_cents')::bigint;
      if desc_t is null or length(desc_t) > 300 or qty < 1 or unit is null or unit <= 0 then
        raise exception 'BAD_VALUE: every line needs a description, a quantity of 1 or more and an amount above S$0.00' using errcode = 'P0001'; end if;
      sub := sub + qty * unit;
    end loop;
  else
    if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'BAD_VALUE: the credit must be more than S$0.00' using errcode = 'P0001'; end if;
    if p_amount_cents > left_c then
      raise exception 'TOO_MUCH: you can credit at most % more on this invoice (it came to %, already credited %)', centre_fmt_money(left_c), centre_fmt_money(b.total_cents), centre_fmt_money(b.credited_cents) using errcode = '42501';
    end if;
    sub := centre_credit_subtotal(p_amount_cents, inv.gst_rate_bp, inv.gst_inclusive, inv.gst_registered);
    if sub is null then
      alt1 := (select t.total_cents from centre_gst_totals(centre_div_round(p_amount_cents * 10000, 10000 + inv.gst_rate_bp) - 1, inv.gst_rate_bp, false, true) t);
      alt2 := (select t.total_cents from centre_gst_totals(centre_div_round(p_amount_cents * 10000, 10000 + inv.gst_rate_bp) + 1, inv.gst_rate_bp, false, true) t);
      raise exception 'NOT_ALLOWED: with GST that exact amount can''t be made; try % or %', centre_fmt_money(alt1), centre_fmt_money(alt2) using errcode = '42501';
    end if;
  end if;
  select * into g from centre_gst_totals(sub, inv.gst_rate_bp, inv.gst_inclusive, inv.gst_registered);
  if g.total_cents > left_c then
    raise exception 'TOO_MUCH: you can credit at most % more on this invoice (it came to %, already credited %)', centre_fmt_money(left_c), centre_fmt_money(b.total_cents), centre_fmt_money(b.credited_cents) using errcode = '42501';
  end if;

  insert into centre_invoices(id, org_id, kind, household_id, student_id, credits_invoice_id, period_start, period_end, reason, gst_registered, gst_rate_bp, gst_inclusive, net_cents, gst_cents, total_cents)
  values (nid, org, 'credit_note', inv.household_id, inv.student_id, inv.id, inv.period_start, inv.period_end, why, inv.gst_registered, inv.gst_rate_bp, inv.gst_inclusive, g.net_cents, g.gst_cents, g.total_cents);
  if p_lines is not null and jsonb_typeof(p_lines) = 'array' and jsonb_array_length(p_lines) > 0 then
    for l in select * from jsonb_array_elements(p_lines) loop
      i := i + 1;
      insert into centre_invoice_lines(org_id, invoice_id, position, student_id, description, qty, unit_cents)
      values (org, nid, i, inv.student_id, trim(l->>'description'), coalesce((l->>'qty')::int, 1), (l->>'unit_cents')::bigint);
    end loop;
  else
    insert into centre_invoice_lines(org_id, invoice_id, position, student_id, description, qty, unit_cents)
    values (org, nid, 1, inv.student_id, 'Credit against invoice ' || inv.number_text, 1, sub);
  end if;
  update centre_invoices set status = 'issued', issue_date = today where id = nid returning * into cn;      -- the S1 guard numbers it (CN series) and freezes it
  excess := centre_sync_invoice_excess(inv.id, centre_overpay_mode(s));
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (org, auth.uid(), 'centre_credit_note_issue', 'centre_invoices', nid::text, null,
          jsonb_build_object('number', cn.number_text, 'invoice', inv.number_text, 'total_cents', cn.total_cents, 'gst_cents', cn.gst_cents, 'excess_to_family_cents', excess));
  select * into b from centre_balance_rows(org, array[inv.id]);
  return jsonb_build_object('id', cn.id, 'number', cn.number_text, 'total_cents', cn.total_cents, 'net_cents', cn.net_cents, 'gst_cents', cn.gst_cents,
    'invoice_id', inv.id, 'invoice_number', inv.number_text, 'excess_to_family_cents', excess, 'balance_cents', b.balance_cents,
    'pay_status', centre_pay_status('issued', inv.kind, b.total_cents, b.credited_cents, b.paid_cents, inv.due_date, today));
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 7. WHAT THE SCREENS READ: the account list and one invoice's account
-- ---------------------------------------------------------------------------------------------------
-- p_filter: null / 'all' | 'unpaid' (something owed) | 'overdue' | 'part_paid' | 'paid' | 'void'. Counts ignore the filter (they are the chips).
create or replace function public.centre_invoice_account_list(p_org uuid, p_period date default null, p_filter text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := centre_money_gate(p_org, 'either'); f text := coalesce(nullif(p_filter, ''), 'all'); ms date := case when p_period is null then null else date_trunc('month', p_period)::date end; r jsonb;
begin
  if f not in ('all', 'unpaid', 'overdue', 'part_paid', 'paid', 'void') then raise exception 'BAD_VALUE: unknown filter' using errcode = 'P0001'; end if;
  with base as (
    select i.id, i.number_text, i.number_seq, i.kind, i.household_id, i.student_id, i.period_start, i.issue_date, i.due_date, i.total_cents,
           coalesce(c.cr, 0)::bigint as credited, coalesce(a.pd, 0)::bigint as paid,
           coalesce(h.name, st.name) as nm
      from centre_invoices i
      left join households h on h.id = i.household_id and h.org_id = i.org_id
      left join students st on st.id = i.student_id and st.org_id = i.org_id
      left join lateral (select sum(n.total_cents) cr from centre_invoices n where n.credits_invoice_id = i.id and n.status = 'issued') c on true
      left join lateral (select sum(x.cents) pd from centre_payment_allocations x where x.invoice_id = i.id) a on true
     where i.org_id = p_org and i.status = 'issued' and i.kind <> 'credit_note' and (ms is null or i.period_start = ms)
  ), calc as (
    select b.*, greatest(b.total_cents - b.credited - b.paid, 0)::bigint as balance,
           centre_pay_status('issued', b.kind, b.total_cents, b.credited, b.paid, b.due_date, today) as ps
      from base b
  ), shown as (
    select * from calc c where case f when 'all' then true when 'unpaid' then c.balance > 0 and c.ps <> 'void' when 'overdue' then c.ps = 'overdue'
                                      when 'part_paid' then c.paid > 0 and c.balance > 0 and c.ps <> 'void' when 'paid' then c.ps = 'paid' else c.ps = 'void' end
     order by c.issue_date desc, c.number_seq desc limit 1000
  )
  select jsonb_build_object(
    'today', today,
    'counts', jsonb_build_object(
      'all', (select count(*) from calc), 'unpaid', (select count(*) from calc where balance > 0 and ps <> 'void'), 'overdue', (select count(*) from calc where ps = 'overdue'),
      'part_paid', (select count(*) from calc where paid > 0 and balance > 0 and ps <> 'void'), 'paid', (select count(*) from calc where ps = 'paid'), 'void', (select count(*) from calc where ps = 'void')),
    'outstanding_cents', (select coalesce(sum(balance), 0) from calc where ps <> 'void'),
    'overdue_cents', (select coalesce(sum(balance), 0) from calc where ps = 'overdue'),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'number', s.number_text, 'name', s.nm, 'household_id', s.household_id, 'student_id', s.student_id, 'kind', s.kind,
              'period_start', s.period_start, 'issue_date', s.issue_date, 'due_date', s.due_date, 'total_cents', s.total_cents, 'credited_cents', s.credited,
              'paid_cents', s.paid, 'balance_cents', s.balance, 'pay_status', s.ps) order by s.issue_date desc, s.number_seq desc), '[]'::jsonb) from shown s))
    into r;
  return r;
end $$;

create or replace function public.centre_invoice_account_get(p_invoice uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare org uuid; today date; r record; b record; s jsonb; see_pay boolean; hh uuid; sh record; pays jsonb; cns jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select org_id into org from centre_invoices where id = p_invoice;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := centre_money_gate(org, 'either');
  select i.*, coalesce(h.name, st.name) as nm into r from centre_invoices i left join households h on h.id = i.household_id and h.org_id = i.org_id
    left join students st on st.id = i.student_id and st.org_id = i.org_id where i.id = p_invoice;
  if r.kind = 'credit_note' or r.status <> 'issued' then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into b from centre_balance_rows(org, array[p_invoice]);
  s := org_settings_on(org, today); see_pay := org_can(org, 'record_payments'); hh := centre_invoice_household(p_invoice);
  select * into sh from centre_invoice_share where invoice_id = p_invoice;
  select coalesce(jsonb_agg(jsonb_build_object('payment_id', q.id, 'kind', q.kind, 'received_on', q.received_on, 'method', q.method, 'cents', q.cents,
         'reference', case when see_pay then q.reference end, 'reversed', q.reversed, 'reverses', q.reverses_payment_id) order by q.created_at, q.id), '[]'::jsonb) into pays
    from (select p.id, p.kind, p.received_on, p.method, p.reference, p.created_at, p.reverses_payment_id, sum(a.cents) as cents,
                 exists (select 1 from centre_payments x where x.reverses_payment_id = p.id and x.org_id = p.org_id) as reversed
            from centre_payment_allocations a join centre_payments p on p.id = a.payment_id and p.org_id = a.org_id
           where a.invoice_id = p_invoice group by p.id) q;
  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'number', n.number_text, 'issue_date', n.issue_date, 'total_cents', n.total_cents, 'reason', n.reason) order by n.number_seq), '[]'::jsonb) into cns
    from centre_invoices n where n.credits_invoice_id = p_invoice and n.status = 'issued';
  return jsonb_build_object('id', r.id, 'status', r.status, 'number', r.number_text, 'name', r.nm, 'household_id', hh, 'student_id', r.student_id,
    'period_start', r.period_start, 'period_end', r.period_end, 'issue_date', r.issue_date, 'due_date', r.due_date, 'kind', r.kind,
    'gst_registered', r.gst_registered, 'gst_rate_bp', r.gst_rate_bp, 'gst_inclusive', r.gst_inclusive,
    'net_cents', r.net_cents, 'gst_cents', r.gst_cents, 'total_cents', r.total_cents,
    'credited_cents', b.credited_cents, 'paid_cents', b.paid_cents, 'balance_cents', b.balance_cents,
    'pay_status', centre_pay_status('issued', r.kind, b.total_cents, b.credited_cents, b.paid_cents, r.due_date, today),
    'can', jsonb_build_object('record_payments', see_pay, 'issue_invoices', org_can(org, 'issue_invoices'), 'owner', org_can(org, 'owner')),
    'rules', jsonb_build_object('partial_payments', coalesce((s#>>'{payments,partial_payments}')::boolean, true), 'overpayments', centre_overpay_mode(s),
                                'manual_paynow', coalesce(s#>'{payments,modes}', '[]'::jsonb) ? 'manual_paynow', 'share_link', coalesce((s#>>'{invoicing,delivery,share_link}')::boolean, true)),
    'credit_balance_cents', case when see_pay and hh is not null then centre_credit_balance(org, hh) end,
    'share', case when sh.id is not null then jsonb_build_object('expires_on', sh.expires_on, 'expired', sh.expires_on is not null and sh.expires_on < today) end,
    'payments', case when see_pay then pays else '[]'::jsonb end, 'credit_notes', cns,
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('position', l.position, 'student_name', s2.name, 'description', l.description, 'qty', l.qty,
                'unit_cents', l.unit_cents, 'line_cents', l.line_cents, 'kind', coalesce(l.fee_kind, 'lesson')) order by l.position), '[]'::jsonb)
                from centre_invoice_lines l left join students s2 on s2.id = l.student_id and s2.org_id = l.org_id where l.invoice_id = r.id));
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 8. SHARE LINK, THE PUBLIC VIEW, THE WHATSAPP MESSAGE
-- ---------------------------------------------------------------------------------------------------
-- staff: get (or make, or replace) the secret link for an issued invoice. p_rotate = true gives a NEW token, so the old link stops working.
create or replace function public.centre_invoice_share_link(p_invoice uuid, p_expires_on date default null, p_rotate boolean default false) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare org uuid; today date; inv centre_invoices; s jsonb; sh centre_invoice_share;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select org_id into org from centre_invoices where id = p_invoice;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := centre_money_gate(org, 'issue_invoices');
  select * into inv from centre_invoices where id = p_invoice;
  if inv.status <> 'issued' or inv.kind = 'credit_note' then raise exception 'NOT_ALLOWED: only an issued invoice can be shared' using errcode = '42501'; end if;
  s := org_settings_on(org, today);
  if not coalesce((s#>>'{invoicing,delivery,share_link}')::boolean, true) then
    raise exception 'NOT_ALLOWED: shareable links are switched off in this centre''s invoicing settings' using errcode = '42501'; end if;
  if p_expires_on is not null and (p_expires_on < today or p_expires_on > today + 3650) then
    raise exception 'BAD_VALUE: the link must expire between today and ten years from now' using errcode = 'P0001'; end if;
  select * into sh from centre_invoice_share where invoice_id = p_invoice;
  if sh.id is null then
    insert into centre_invoice_share(org_id, invoice_id, expires_on) values (org, p_invoice, p_expires_on) returning * into sh;
  elsif p_rotate or (sh.expires_on is not null and sh.expires_on < today) then
    update centre_invoice_share set token = gen_random_uuid(), expires_on = p_expires_on, rotated_at = now() where id = sh.id returning * into sh;
  end if;
  return jsonb_build_object('token', sh.token, 'expires_on', sh.expires_on, 'rotated', coalesce(p_rotate, false));
end $$;

-- ANYONE with the secret token: one invoice, read only, nothing else. Wrong / expired / replaced token → null (not an error: nothing to learn from it).
create or replace function public.centre_invoice_public(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare sh record; inv centre_invoices; o organisations; s jsonb; today date; b record; nm text; pn text; modes jsonb; logo text;
begin
  if p_token is null then return null; end if;
  select * into sh from centre_invoice_share where token = p_token;
  if sh.id is null then return null; end if;
  select * into inv from centre_invoices where id = sh.invoice_id and org_id = sh.org_id;
  if inv.id is null or inv.status <> 'issued' or inv.kind = 'credit_note' then return null; end if;
  select * into o from organisations where id = sh.org_id and kind = 'centre';
  if o.id is null then return null; end if;
  today := (now() at time zone o.timezone)::date;
  if sh.expires_on is not null and sh.expires_on < today then return null; end if;
  select x.settings into s from org_settings x where x.org_id = o.id and x.effective_from <= today order by x.effective_from desc, x.version desc limit 1;
  s := coalesce(s, '{}'::jsonb);
  if not coalesce((s#>>'{invoicing,delivery,share_link}')::boolean, true) then return null; end if;
  select * into b from centre_balance_rows(o.id, array[inv.id]);
  nm := coalesce((select h.name from households h where h.id = inv.household_id and h.org_id = inv.org_id), (select st.name from students st where st.id = inv.student_id and st.org_id = inv.org_id));
  logo := case when o.logo_path ~ '^https://' then o.logo_path end;
  modes := coalesce(s#>'{payments,modes}', '[]'::jsonb);
  pn := nullif(trim(coalesce(s#>>'{payments,paynow,id}', '')), '');
  return jsonb_build_object(
    'centre', jsonb_build_object('name', coalesce(nullif(trim(s#>>'{profile,trading_name}'), ''), o.trading_name), 'legal_name', nullif(trim(coalesce(s#>>'{profile,legal_name}', o.legal_name, '')), ''),
        'uen', nullif(trim(coalesce(s#>>'{profile,uen}', o.uen, '')), ''), 'address', nullif(trim(coalesce(s#>>'{profile,address}', o.address, '')), ''),
        'brand_color', coalesce(s#>>'{profile,brand_color}', o.brand_color, '#0F766E'), 'logo_url', logo,
        'gst_number', case when coalesce((s#>>'{profile,gst_registered}')::boolean, false) then nullif(trim(coalesce(s#>>'{profile,gst_number}', '')), '') end),
    'invoice', jsonb_build_object('number', inv.number_text, 'bill_to', nm, 'issue_date', inv.issue_date, 'due_date', inv.due_date,
        'period_start', inv.period_start, 'period_end', inv.period_end, 'gst_registered', inv.gst_registered, 'gst_rate_bp', inv.gst_rate_bp,
        'net_cents', inv.net_cents, 'gst_cents', inv.gst_cents, 'total_cents', inv.total_cents, 'credited_cents', b.credited_cents, 'paid_cents', b.paid_cents,
        'balance_cents', b.balance_cents, 'pay_status', centre_pay_status('issued', inv.kind, b.total_cents, b.credited_cents, b.paid_cents, inv.due_date, today),
        'lines', (select coalesce(jsonb_agg(jsonb_build_object('student_name', s2.name, 'description', l.description, 'qty', l.qty, 'unit_cents', l.unit_cents, 'line_cents', l.line_cents)
                    order by l.position), '[]'::jsonb) from centre_invoice_lines l left join students s2 on s2.id = l.student_id and s2.org_id = l.org_id where l.invoice_id = inv.id)),
    'paynow', case when pn is not null and modes ? 'manual_paynow' and b.balance_cents > 0 and coalesce(s#>>'{payments,paynow,type}', 'uen') in ('uen', 'mobile')
                   then jsonb_build_object('type', coalesce(s#>>'{payments,paynow,type}', 'uen'), 'id', pn, 'reference', inv.number_text, 'amount_cents', b.balance_cents) end,
    'expires_on', sh.expires_on);
end $$;

-- staff: the WhatsApp message for one invoice. The wording is the centre's own (a setting); the browser fills the placeholders and builds the
-- wa.me address from `phone`. Makes the share link if the centre uses links, so {link} always has something to point at.
create or replace function public.centre_invoice_whatsapp(p_invoice uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare org uuid; today date; inv centre_invoices; s jsonb; b record; hh uuid; tpl text; ph text; nm text; link jsonb; cname text;
  dflt text := E'Hi {name}, this is {centre}. Invoice {number} for {amount} is due on {due_date}.\nYou can see it and pay by PayNow here: {link}\nThank you!';
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select org_id into org from centre_invoices where id = p_invoice;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := centre_money_gate(org, 'issue_invoices');
  select * into inv from centre_invoices where id = p_invoice;
  if inv.status <> 'issued' or inv.kind = 'credit_note' then raise exception 'NOT_ALLOWED: only an issued invoice can be sent' using errcode = '42501'; end if;
  s := org_settings_on(org, today);
  select * into b from centre_balance_rows(org, array[p_invoice]);
  hh := centre_invoice_household(p_invoice);
  tpl := coalesce(nullif(trim(s#>>'{invoicing,whatsapp_template}'), ''), dflt);
  if length(tpl) > 1000 then tpl := left(tpl, 1000); end if;
  if coalesce((s#>>'{invoicing,delivery,share_link}')::boolean, true) then link := centre_invoice_share_link(p_invoice); end if;
  select regexp_replace(g.phone, '\D', '', 'g') into ph from guardians g where g.org_id = org and g.household_id = hh and nullif(trim(coalesce(g.phone, '')), '') is not null order by g.created_at, g.id limit 1;
  if ph is not null then ph := case when length(ph) = 8 then '65' || ph else ph end; if length(ph) < 8 then ph := null; end if; end if;
  nm := coalesce((select h.name from households h where h.id = hh and h.org_id = org), (select st.name from students st where st.id = inv.student_id and st.org_id = org));
  cname := coalesce(nullif(trim(s#>>'{profile,trading_name}'), ''), (select trading_name from organisations where id = org));
  return jsonb_build_object('template', tpl, 'phone', ph, 'token', link->>'token',
    'vars', jsonb_build_object('name', nm, 'centre', cname, 'number', inv.number_text, 'amount_cents', b.balance_cents, 'total_cents', inv.total_cents,
                               'due_date', inv.due_date, 'issue_date', inv.issue_date, 'invoice_id', inv.id));
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 9. FAMILY CREDIT: what a family holds, and the owner's record of paying it back
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_family_credit_get(p_org uuid, p_household uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := centre_money_gate(p_org, 'record_payments');
begin
  if not exists (select 1 from households h where h.id = p_household and h.org_id = p_org) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  return jsonb_build_object('balance_cents', centre_credit_balance(p_org, p_household), 'rows', (select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'kind', c.kind, 'handling', c.handling, 'cents', c.cents, 'created_at', c.created_at, 'method', c.method, 'reason', c.reason) order by c.created_at, c.id), '[]'::jsonb)
    from centre_family_credit c where c.org_id = p_org and c.household_id = p_household));
end $$;

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

-- ---------------------------------------------------------------------------------------------------
-- 10. function access: signed-in users call the public ones (each starts with the gate); helpers and trigger functions are server-only
-- ---------------------------------------------------------------------------------------------------
revoke all on function public.centre_family_credit_guard() from public, anon, authenticated;
revoke all on function public.centre_share_audit() from public, anon, authenticated;
revoke all on function public.centre_fmt_money(bigint) from public, anon;
revoke all on function public.centre_money_gate(uuid, text) from public, anon, authenticated;
revoke all on function public.centre_pay_status(text, text, bigint, bigint, bigint, date, date) from public, anon;
revoke all on function public.centre_balance_rows(uuid, uuid[]) from public, anon, authenticated;
revoke all on function public.centre_invoice_household(uuid) from public, anon, authenticated;
revoke all on function public.centre_credit_balance(uuid, uuid) from public, anon, authenticated;
revoke all on function public.centre_overpay_mode(jsonb) from public, anon;
revoke all on function public.centre_sync_invoice_excess(uuid, text) from public, anon, authenticated;
revoke all on function public.centre_credit_subtotal(bigint, int, boolean, boolean) from public, anon;
revoke all on function public.centre_record_payment(uuid, uuid, text, bigint, date, text, uuid[], text, text) from public, anon;
revoke all on function public.centre_reverse_payment(uuid, text) from public, anon;
revoke all on function public.centre_issue_credit_note(uuid, bigint, text, jsonb) from public, anon;
revoke all on function public.centre_invoice_account_list(uuid, date, text) from public, anon;
revoke all on function public.centre_invoice_account_get(uuid) from public, anon;
revoke all on function public.centre_invoice_share_link(uuid, date, boolean) from public, anon;
revoke all on function public.centre_invoice_public(uuid) from public;
revoke all on function public.centre_invoice_whatsapp(uuid) from public, anon;
revoke all on function public.centre_family_credit_get(uuid, uuid) from public, anon;
revoke all on function public.centre_refund_family_credit(uuid, uuid, bigint, text, text, text) from public, anon;
grant execute on function public.centre_fmt_money(bigint), public.centre_pay_status(text, text, bigint, bigint, bigint, date, date), public.centre_credit_subtotal(bigint, int, boolean, boolean),
  public.centre_overpay_mode(jsonb) to authenticated, service_role;
grant execute on function public.centre_record_payment(uuid, uuid, text, bigint, date, text, uuid[], text, text), public.centre_reverse_payment(uuid, text),
  public.centre_issue_credit_note(uuid, bigint, text, jsonb), public.centre_invoice_account_list(uuid, date, text), public.centre_invoice_account_get(uuid),
  public.centre_invoice_share_link(uuid, date, boolean), public.centre_invoice_whatsapp(uuid), public.centre_family_credit_get(uuid, uuid),
  public.centre_refund_family_credit(uuid, uuid, bigint, text, text, text) to authenticated, service_role;
grant execute on function public.centre_invoice_public(uuid) to anon, authenticated, service_role;      -- the one function the world may call: it needs the secret token
