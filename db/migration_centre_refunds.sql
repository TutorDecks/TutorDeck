-- =====================================================================================================
-- T4 step S5 — centre refunds and family credit: refund a deposit, refund family credit, apply credit to the next invoice, keep a deposit   undo: migration_centre_refunds_down.sql
-- =====================================================================================================
-- Run order everywhere: org_foundation → billing → attendance → tutor_access → org_delete → function_lockdown → org_separation →
--   staff_home → staff_students → staff_attendance → staff_charges → staff_trials → staff_timetable → money_settings →
--   centre_money → centre_invoice_run → centre_payments → centre_deposits → centre_refunds.
-- Needs migration_centre_deposits.sql (S4: the deposit ledger) and migration_centre_payments.sql (S3: payments, the family credit ledger).
-- Run on the DEV project first. LIVE only when the owner says ship: it reads no existing row and changes none (two new tables, three new nullable
-- columns, two widened checks, new functions; it REPLACES centre_refund_family_credit and centre_revenue_totals with versions that know about refunds).
-- Safe to run twice.
--
-- WHAT A REFUND IS HERE (owner-approved T4 decisions, 2026-11-26)
--   Money held for a family leaves in a TRACKED, APPROVED, RECORDED step, never in one click and never by editing a number:
--     requested  →  approved  →  paid        (or  cancelled  from the first two)
--   centre_refunds           one IMMUTABLE row per request: what is asked (cash to pay out, deposit kept as forfeit, deposit kept against unpaid invoices),
--                            the calculation it came from (held, notice, the centre's release rule), the GST share, who asked and when.
--   centre_refund_events     APPEND-ONLY: approved · paid · cancelled, each with who, when, how it was paid and a reference. The state of a refund is the
--                            last event. Nothing is ever edited or deleted (a mistake is a new row on the ledgers, as everywhere in centre money).
--   The two ledgers (deposit ledger S4, family credit S3) get their negative row ONLY when the refund is PAID: refunded · forfeited · applied (deposit)
--   and refund (credit). Until then the money is RESERVED: every request counts the open refunds, so nothing can be refunded twice or beyond what is held.
--
-- THE CENTRE'S SETTINGS THAT DECIDE THINGS (process rules: read as of the day of the action)
--   billing.deposit.refund_approved_by   owner     only the centre owner approves
--                                        staff     the owner, or staff who may act on that kind of refund (below)
--                                        four_eyes the same people, but never the person who asked
--   billing.deposit.release              refund_full         the system SUGGESTS refunding what is held (less any forfeit)
--                                        refund_less_unpaid  …minus the family's unpaid invoices, which the deposit is KEPT AGAINST (a GST-free deposit only)
--                                        admin_decides       no suggestion: the person types the three amounts
--   billing.deposit.forfeit_notice_days  0 = never forfeit. Otherwise leaving with LESS notice than this many days suggests keeping the deposit.
--                                        The notice date is typed when the refund is asked for (the day the family said they were leaving).
--   billing.deposit.taxable              (S4, frozen on each deposit) a taxable deposit already carried GST when received, so its refund also gives that
--                                        GST back (stored on the refund, counted by centre_revenue_totals); it can't be kept against invoices (that would tax it twice).
--   payments.overpayments                (S3) credit or refund: unchanged. Both kinds of family credit can be applied or refunded here.
--
-- WHO MAY CALL
--   family credit  request / pay / cancel: owner or staff with record_payments.   deposit  request / pay / cancel: owner or staff with issue_invoices
--   (owner decision: "waiving or refunding a deposit needs the owner or a staff member with issue_invoices"; waiving is S4, unchanged).
--   approve: as refund_approved_by says. Apply credit to an invoice: owner or staff with record_payments.
--   reading: owner or staff with record_payments, issue_invoices or view_revenue.
--   Tutors, parents, switched-off staff, solo organisations, strangers and anonymous callers get NOT_FOUND. No browser role can write either new table.
--
-- DOUBLE PRESS: a repeated request with the same request key, or a repeated approve / pay / cancel, answers "already" and writes nothing.
-- RULES THAT NEVER CHANGE: a refund can't be asked for more than is held less what is already reserved; a deposit refund waits until the student's last
--   lesson day has passed and their final invoice is issued; a reference can't hold a full bank or PayNow number (PDPA: "ending 1234" is enough).
-- AUDIT: both tables use the S1 audit trigger (payee, reference, reason and note replaced by "[redacted]"); each function adds a summary row with amounts only.
-- NOT BUILT HERE (still on the plan): moving a deposit between students, adjusting a deposit, a numbered refund statement document.
-- =====================================================================================================

-- ---------------------------------------------------------------------------------------------------
-- 1. the two tables
-- ---------------------------------------------------------------------------------------------------
create table if not exists public.centre_refunds (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.organisations(id) on delete cascade,
  kind           text not null check (kind in ('deposit', 'family_credit')),
  student_id     uuid,                                      -- deposit refunds
  household_id   uuid,                                      -- the family (a snapshot for a deposit)
  deposit_id     uuid,
  refund_cents   bigint not null check (refund_cents >= 0), -- cash paid out to the family
  forfeit_cents  bigint not null default 0 check (forfeit_cents >= 0),   -- deposit kept by the centre (becomes income)
  set_off_cents  bigint not null default 0 check (set_off_cents >= 0),   -- deposit kept against the family's unpaid invoices
  held_cents     bigint not null check (held_cents >= 0),   -- what was held when it was asked (frozen, for the statement)
  taxable        boolean not null default false,
  gst_cents      bigint not null default 0 check (gst_cents >= 0),       -- GST given back with a taxable deposit's refund
  release_rule   text,                                      -- the centre's setting when it was asked
  notice_days    int,                                       -- forfeit_notice_days when it was asked
  notice_given_on date,
  lesson_end     date,
  payer_name     text,                                      -- the payee, free text (redacted in the audit copy)
  reason         text not null,
  request_key    text,
  requested_by   uuid default auth.uid(),
  requested_on   date not null,
  created_at     timestamptz not null default now(),
  unique (id, org_id),
  foreign key (student_id, org_id)   references public.students(id, org_id),
  foreign key (household_id, org_id) references public.households(id, org_id),
  foreign key (deposit_id, org_id)   references public.centre_deposits(id, org_id),
  check ((kind = 'deposit') = (student_id is not null and deposit_id is not null)),
  check (kind = 'deposit' or (household_id is not null and forfeit_cents = 0 and set_off_cents = 0 and refund_cents > 0 and gst_cents = 0)),
  check (kind = 'family_credit' or (refund_cents + forfeit_cents + set_off_cents > 0)),
  check (length(btrim(reason)) > 0)
);
create unique index if not exists centre_refunds_key on public.centre_refunds(org_id, request_key) where request_key is not null;
create index if not exists centre_refunds_student on public.centre_refunds(org_id, student_id) where student_id is not null;
create index if not exists centre_refunds_household on public.centre_refunds(org_id, household_id) where household_id is not null;

create table if not exists public.centre_refund_events (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.organisations(id) on delete cascade,
  refund_id      uuid not null,
  kind           text not null check (kind in ('approved', 'paid', 'cancelled')),
  event_on       date not null,                              -- the centre's day it happened (for 'paid': the day the money went out)
  method         text check (method in ('manual_paynow', 'bank', 'cash', 'cheque', 'other')),
  reference      text,                                       -- free text, never a full account number; redacted in the audit copy
  reason         text,
  note           text,
  set_off_cents  bigint,                                     -- 'paid': how much was really kept against invoices (never more than was asked)
  actor          uuid default auth.uid(),
  created_at     timestamptz not null default clock_timestamp(),     -- not now(): approve and pay can happen in one transaction and must stay in order
  unique (id, org_id),
  foreign key (refund_id, org_id) references public.centre_refunds(id, org_id),
  check (kind <> 'cancelled' or length(btrim(coalesce(reason, ''))) > 0)
);
create unique index if not exists centre_refund_events_approved on public.centre_refund_events(refund_id) where kind = 'approved';
create unique index if not exists centre_refund_events_closed on public.centre_refund_events(refund_id) where kind in ('paid', 'cancelled');

-- the ledgers learn which refund wrote a row; the credit ledger learns "applied" and a key that makes applying idempotent; payments learn two internal methods
alter table public.centre_deposit_ledger add column if not exists refund_id uuid;
alter table public.centre_family_credit add column if not exists refund_id uuid;
alter table public.centre_family_credit add column if not exists request_key text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'centre_deposit_ledger_refund_fk') then
    alter table public.centre_deposit_ledger add constraint centre_deposit_ledger_refund_fk foreign key (refund_id, org_id) references public.centre_refunds(id, org_id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'centre_family_credit_refund_fk') then
    alter table public.centre_family_credit add constraint centre_family_credit_refund_fk foreign key (refund_id, org_id) references public.centre_refunds(id, org_id);
  end if;
end $$;
create unique index if not exists centre_family_credit_applied_key on public.centre_family_credit(org_id, request_key) where request_key is not null;

do $$
declare c record;
begin
  -- family credit kinds gain 'applied' (credit used to pay an invoice)
  if not exists (select 1 from pg_constraint where conname = 'centre_family_credit_kind_s5') then
    for c in select conname from pg_constraint where conrelid = 'public.centre_family_credit'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%payment_reversal%' and pg_get_constraintdef(oid) like '%excess_release%' loop
      execute format('alter table public.centre_family_credit drop constraint %I', c.conname);
    end loop;
    alter table public.centre_family_credit add constraint centre_family_credit_kind_s5
      check (kind in ('overpayment', 'credit_note_excess', 'payment_reversal', 'excess_release', 'refund', 'applied'));
  end if;
  -- payments gain two internal methods: 'family_credit' and 'deposit' (money that is already held, moved onto an invoice; it is not new cash)
  if not exists (select 1 from pg_constraint where conname = 'centre_payments_method_s5') then
    for c in select conname from pg_constraint where conrelid = 'public.centre_payments'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%manual_paynow%' and pg_get_constraintdef(oid) like '%cheque%' loop
      execute format('alter table public.centre_payments drop constraint %I', c.conname);
    end loop;
    alter table public.centre_payments add constraint centre_payments_method_s5
      check (method in ('manual_paynow', 'bank', 'cash', 'cheque', 'other', 'family_credit', 'deposit'));
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 2. guards (same shape as S1/S4: centres only, append-only, the exception for deleting a whole organisation)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_refund_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    if tg_op = 'DELETE' and centre_money_deleting(old.org_id) then return old; end if;
    raise exception 'A refund request is a money record and can''t be changed (cancel it and ask again)' using errcode = '42501';
  end if;
  return new;
end $$;

-- the state machine, enforced where it can't be bypassed: approved once (not after the end), paid only after approved, one ending
create or replace function public.centre_refund_event_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare ended text;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    if tg_op = 'DELETE' and centre_money_deleting(old.org_id) then return old; end if;
    raise exception 'A refund''s history is append-only (nothing is edited or deleted)' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(new.refund_id::text, 7));
  select e.kind into ended from centre_refund_events e where e.refund_id = new.refund_id and e.org_id = new.org_id and e.kind in ('paid', 'cancelled');
  if ended is not null then raise exception 'That refund is already % and can''t change again', ended using errcode = '42501'; end if;
  if new.kind = 'paid' and not exists (select 1 from centre_refund_events e where e.refund_id = new.refund_id and e.org_id = new.org_id and e.kind = 'approved') then
    raise exception 'A refund can only be paid after it is approved' using errcode = '42501'; end if;
  return new;
end $$;

-- nobody types an internal method as a "reversal": a credit or deposit already applied to an invoice is corrected with a credit note
create or replace function public.centre_internal_method_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'reversal' and new.method in ('family_credit', 'deposit') then
    raise exception 'NOT_ALLOWED: credit or deposit that was applied to an invoice can''t be reversed; issue a credit note on the invoice instead (any excess goes back to the family credit)' using errcode = '42501';
  end if;
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['centre_refunds', 'centre_refund_events'] loop
    execute format('drop trigger if exists centre_money_org_guard on public.%I', t);
    execute format('create trigger centre_money_org_guard before insert on public.%I for each row execute function public.centre_money_org_guard()', t);
    execute format('drop trigger if exists audit_row on public.%I', t);
    execute format('create trigger audit_row after insert or update or delete on public.%I for each row execute function public.centre_money_audit()', t);
  end loop;
end $$;
drop trigger if exists centre_refund_guard on public.centre_refunds;
create trigger centre_refund_guard before insert or update or delete on public.centre_refunds for each row execute function public.centre_refund_guard();
drop trigger if exists centre_refund_event_guard on public.centre_refund_events;
create trigger centre_refund_event_guard before insert or update or delete on public.centre_refund_events for each row execute function public.centre_refund_event_guard();
drop trigger if exists centre_internal_method_guard on public.centre_payments;
create trigger centre_internal_method_guard before insert on public.centre_payments for each row execute function public.centre_internal_method_guard();

alter table public.centre_refunds enable row level security;
alter table public.centre_refund_events enable row level security;
drop policy if exists money_read on public.centre_refunds;
create policy money_read on public.centre_refunds for select
  using ((org_can(org_id, 'record_payments') or org_can(org_id, 'issue_invoices') or org_can(org_id, 'view_revenue')) and not org_is_solo(org_id));
drop policy if exists money_read on public.centre_refund_events;
create policy money_read on public.centre_refund_events for select
  using ((org_can(org_id, 'record_payments') or org_can(org_id, 'issue_invoices') or org_can(org_id, 'view_revenue')) and not org_is_solo(org_id));
revoke all on public.centre_refunds, public.centre_refund_events from anon, authenticated;
grant select on public.centre_refunds, public.centre_refund_events to authenticated;

-- ---------------------------------------------------------------------------------------------------
-- 3. helpers (internal)
-- ---------------------------------------------------------------------------------------------------
-- who and when. p_kind: 'deposit' (owner / issue_invoices) · 'family_credit' (owner / record_payments) · 'view' (any money reader). Returns the centre's own "today".
create or replace function public.centre_refund_gate(p_org uuid, p_kind text) returns date
language plpgsql stable security definer set search_path = public as $$
declare tz text; ok boolean;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select o.timezone into tz from organisations o where o.id = p_org and o.kind = 'centre';
  if tz is null or not exists (select 1 from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active' and m.role in ('owner', 'staff')) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  ok := case p_kind when 'view' then org_can(p_org, 'record_payments') or org_can(p_org, 'issue_invoices') or org_can(p_org, 'view_revenue')
                    when 'deposit' then org_can(p_org, 'issue_invoices')
                    else org_can(p_org, 'record_payments') end;
  if not ok then
    raise exception 'NOT_ALLOWED: your account can''t % at this centre', case p_kind when 'view' then 'see refunds'
      when 'deposit' then 'refund or keep a deposit (the owner or a staff member who issues invoices can)' else 'refund family credit (the owner or a staff member who records payments can)' end using errcode = '42501';
  end if;
  return (now() at time zone tz)::date;
end $$;

-- may the caller approve? (the setting is read by the caller as of today)
create or replace function public.centre_refund_can_approve(p_org uuid, p_kind text, p_requested_by uuid, p_rule text) returns boolean
language sql stable security definer set search_path = public as $$
  select case coalesce(p_rule, 'owner')
    when 'staff'     then org_can(p_org, case p_kind when 'deposit' then 'issue_invoices' else 'record_payments' end)
    when 'four_eyes' then org_can(p_org, case p_kind when 'deposit' then 'issue_invoices' else 'record_payments' end) and auth.uid() is distinct from p_requested_by
    else org_can(p_org, 'owner') end
$$;

create or replace function public.centre_refund_rule(p_org uuid, p_today date) returns text
language sql stable security definer set search_path = public as $$
  select case coalesce(org_settings_on(p_org, p_today)#>>'{billing,deposit,refund_approved_by}', 'owner') when 'staff' then 'staff' when 'four_eyes' then 'four_eyes' else 'owner' end
$$;

create or replace function public.centre_refund_state(p_refund uuid) returns text
language sql security definer set search_path = public as $$
  select case when exists (select 1 from centre_refund_events where refund_id = p_refund and kind = 'paid') then 'paid'
              when exists (select 1 from centre_refund_events where refund_id = p_refund and kind = 'cancelled') then 'cancelled'
              when exists (select 1 from centre_refund_events where refund_id = p_refund and kind = 'approved') then 'approved'
              else 'requested' end
$$;

-- money asked for in refunds that are not finished (so nobody can ask for it twice)
create or replace function public.centre_deposit_reserved(p_org uuid, p_student uuid) returns bigint
language sql security definer set search_path = public as $$
  select coalesce(sum(r.refund_cents + r.forfeit_cents + r.set_off_cents), 0)::bigint from centre_refunds r
   where r.org_id = p_org and r.kind = 'deposit' and r.student_id = p_student and centre_refund_state(r.id) in ('requested', 'approved')
$$;
create or replace function public.centre_credit_reserved(p_org uuid, p_household uuid) returns bigint
language sql security definer set search_path = public as $$
  select coalesce(sum(r.refund_cents), 0)::bigint from centre_refunds r
   where r.org_id = p_org and r.kind = 'family_credit' and r.household_id = p_household and centre_refund_state(r.id) in ('requested', 'approved')
$$;
create or replace function public.centre_deposit_held_cents(p_org uuid, p_student uuid) returns bigint
language sql security definer set search_path = public as $$
  select coalesce(sum(cents) filter (where kind <> 'waived'), 0)::bigint from centre_deposit_ledger where org_id = p_org and student_id = p_student
$$;

create or replace function public.centre_person_name(p_org uuid, p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select m.display_name from memberships m where m.org_id = p_org and m.user_id = p_user limit 1), case when p_user is null then null else 'Former staff member' end)
$$;

-- a reference may say "DBS ending 6789" but never carry a whole account or PayNow number (PDPA)
create or replace function public.centre_clean_reference(p_ref text) returns text
language plpgsql immutable set search_path = public as $$
declare r text := nullif(btrim(coalesce(p_ref, '')), '');
begin
  if r is null then return null; end if;
  if length(r) > 120 then raise exception 'TOO_LONG: keep the reference under 120 characters' using errcode = 'P0001'; end if;
  if r ~ '\d{8,}' then raise exception 'BAD_VALUE: don''t type a full bank account or PayNow number here, only the last 4 digits (for example “DBS ending 6789”)' using errcode = 'P0001'; end if;
  return r;
end $$;

-- the GST share of an amount of a TAXABLE deposit, from the rules frozen on the deposit invoice (never more than was charged)
create or replace function public.centre_deposit_gst_share(p_deposit uuid, p_org uuid, p_cents bigint) returns bigint
language plpgsql stable security definer set search_path = public as $$
declare i centre_invoices; d centre_deposits;
begin
  select * into d from centre_deposits where id = p_deposit and org_id = p_org;
  if d.id is null or not d.taxable or d.invoice_id is null or p_cents <= 0 then return 0; end if;
  select * into i from centre_invoices where id = d.invoice_id and org_id = p_org;
  if i.id is null or not coalesce(i.gst_registered, false) or coalesce(i.gst_rate_bp, 0) <= 0 then return 0; end if;
  return greatest(p_cents - centre_div_round(p_cents * 10000, 10000 + i.gst_rate_bp), 0);
end $$;

-- put money that is ALREADY HELD onto the family's open invoices, oldest first (issue date, then number). Writes one internal payment (method 'family_credit'
-- or 'deposit') for what was really allocated and its allocations. Never touches a deposit invoice or a credit note. p_student narrows it to one student's invoices.
-- Returns {payment_id, allocated_cents, allocated:[{invoice_id, number, cents}]}; allocated_cents may be less than asked (or 0: nothing is written).
create or replace function public.centre_allocate_held(p_org uuid, p_household uuid, p_method text, p_cents bigint, p_invoice_ids uuid[], p_student uuid, p_today date, p_ref text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; remaining bigint := p_cents; take bigint; pid uuid := gen_random_uuid(); total bigint := 0; picks jsonb := '[]'::jsonb; a jsonb;
begin
  for r in
    select i.id, i.number_text, b.balance_cents
      from centre_invoices i, lateral centre_balance_rows(p_org, array[i.id]) b
     where i.org_id = p_org and i.status = 'issued' and i.kind not in ('credit_note', 'deposit') and b.balance_cents > 0
       and (case when p_student is not null then i.student_id = p_student
                 else (i.household_id = p_household or (i.household_id is null and i.student_id in (select s.id from students s where s.household_id = p_household and s.org_id = p_org))) end)
       and (p_invoice_ids is null or i.id = any(p_invoice_ids))
     order by i.issue_date, i.number_seq
  loop
    exit when remaining <= 0;
    take := least(remaining, r.balance_cents);
    picks := picks || jsonb_build_object('invoice_id', r.id, 'number', r.number_text, 'cents', take);
    remaining := remaining - take; total := total + take;
  end loop;
  if total <= 0 then return jsonb_build_object('payment_id', null, 'allocated_cents', 0, 'allocated', '[]'::jsonb); end if;
  insert into centre_payments(id, org_id, kind, household_id, method, amount_cents, received_on, reference)
  values (pid, p_org, 'payment', p_household, p_method, total, p_today, p_ref);
  for a in select * from jsonb_array_elements(picks) loop
    insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (p_org, pid, (a->>'invoice_id')::uuid, (a->>'cents')::bigint);
  end loop;
  return jsonb_build_object('payment_id', pid, 'allocated_cents', total, 'allocated', picks);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 4. one refund as the screens read it (internal; every caller has already passed a gate)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_refund_json(p_refund uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r centre_refunds; st text; tz text; today date; rule text; perm text; appr boolean; own boolean; res jsonb;
begin
  select * into r from centre_refunds where id = p_refund;
  if r.id is null then return null; end if;
  st := centre_refund_state(r.id);
  select o.timezone into tz from organisations o where o.id = r.org_id; today := (now() at time zone coalesce(tz, 'Asia/Singapore'))::date;
  rule := centre_refund_rule(r.org_id, today);
  perm := case r.kind when 'deposit' then 'issue_invoices' else 'record_payments' end;
  own := org_can(r.org_id, 'owner');
  appr := st = 'requested' and centre_refund_can_approve(r.org_id, r.kind, r.requested_by, rule);
  res := jsonb_build_object('id', r.id, 'kind', r.kind, 'state', st, 'student_id', r.student_id, 'household_id', r.household_id,
    'student_name', (select s.name from students s where s.id = r.student_id and s.org_id = r.org_id),
    'household_name', (select h.name from households h where h.id = coalesce(r.household_id, (select s.household_id from students s where s.id = r.student_id and s.org_id = r.org_id)) and h.org_id = r.org_id),
    'refund_cents', r.refund_cents, 'forfeit_cents', r.forfeit_cents, 'set_off_cents', r.set_off_cents, 'held_cents', r.held_cents,
    'taxable', r.taxable, 'gst_cents', r.gst_cents, 'release_rule', r.release_rule, 'approver_rule', rule,
    'notice_days', r.notice_days, 'notice_given_on', r.notice_given_on, 'lesson_end', r.lesson_end,
    'payee', r.payer_name, 'reason', r.reason, 'requested_by_name', centre_person_name(r.org_id, r.requested_by), 'requested_on', r.requested_on,
    'can_approve', appr, 'can_pay', st = 'approved' and org_can(r.org_id, perm),
    'can_cancel', st in ('requested', 'approved') and (own or r.requested_by = auth.uid() or (rule <> 'owner' and org_can(r.org_id, perm))),
    'events', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'on', e.event_on, 'by', centre_person_name(r.org_id, e.actor), 'method', e.method,
        'reference', e.reference, 'reason', e.reason, 'note', e.note, 'set_off_cents', e.set_off_cents) order by e.created_at, case e.kind when 'approved' then 1 when 'paid' then 2 else 3 end, e.id)
        from centre_refund_events e where e.refund_id = r.id and e.org_id = r.org_id), '[]'::jsonb));
  return res;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 5. FAMILY CREDIT: what the family holds, what is already being refunded, what is open to apply it to
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_family_credit_status(p_org uuid, p_household uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := centre_refund_gate(p_org, 'view'); bal bigint; res bigint; hn text;
begin
  select h.name into hn from households h where h.id = p_household and h.org_id = p_org;
  if hn is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  bal := centre_credit_balance(p_org, p_household); res := centre_credit_reserved(p_org, p_household);
  return jsonb_build_object('today', today, 'household_id', p_household, 'household_name', hn, 'balance_cents', bal, 'reserved_cents', res, 'available_cents', greatest(bal - res, 0),
    'handling', centre_overpay_mode(org_settings_on(p_org, today)), 'approver_rule', centre_refund_rule(p_org, today),
    'open_invoices', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'number', i.number_text, 'balance_cents', b.balance_cents, 'due_date', i.due_date, 'student_id', i.student_id) order by i.issue_date, i.number_seq)
        from centre_invoices i, lateral centre_balance_rows(p_org, array[i.id]) b
       where i.org_id = p_org and i.status = 'issued' and i.kind not in ('credit_note', 'deposit') and b.balance_cents > 0
         and (i.household_id = p_household or (i.household_id is null and i.student_id in (select s.id from students s where s.household_id = p_household and s.org_id = p_org)))), '[]'::jsonb),
    'refunds', coalesce((select jsonb_agg(centre_refund_json(r.id) order by r.created_at desc, r.id) from centre_refunds r
        where r.org_id = p_org and r.kind = 'family_credit' and r.household_id = p_household), '[]'::jsonb));
end $$;

-- APPLY: use the family's credit to pay their open invoice(s), so no cash needs to be refunded. Oldest invoice first unless some are chosen;
-- the whole credit (or the amount given) up to what the invoices still owe. A repeated request key does nothing.
create or replace function public.centre_apply_family_credit(p_org uuid, p_household uuid, p_invoice_ids uuid[] default null, p_cents bigint default null, p_request_key text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := centre_refund_gate(p_org, 'family_credit'); key text := nullif(btrim(coalesce(p_request_key, '')), ''); prior record; avail bigint; take bigint; al jsonb; got bigint;
  ids uuid[]; bad int;
begin
  if not exists (select 1 from households h where h.id = p_household and h.org_id = p_org) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if key is not null and length(key) > 80 then raise exception 'BAD_VALUE: that request key is too long' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_household::text, 4));
  if key is not null then
    select * into prior from centre_family_credit where org_id = p_org and request_key = key;
    if prior.id is not null then
      if prior.household_id is distinct from p_household then raise exception 'BAD_VALUE: that request key was used for something else' using errcode = 'P0001'; end if;
      return jsonb_build_object('already', true, 'applied_cents', -prior.cents, 'credit_balance_cents', centre_credit_balance(p_org, p_household), 'payment_id', prior.payment_id);
    end if;
  end if;
  avail := centre_credit_balance(p_org, p_household) - centre_credit_reserved(p_org, p_household);
  if avail <= 0 then raise exception 'CREDIT_SHORT: this family has no credit left to apply (credit already being refunded can''t be used too)' using errcode = '42501'; end if;
  if p_cents is not null and p_cents <= 0 then raise exception 'BAD_VALUE: the amount must be more than S$0.00' using errcode = 'P0001'; end if;
  take := coalesce(p_cents, avail);
  if take > avail then raise exception 'CREDIT_SHORT: this family has only % of credit available to apply', centre_fmt_money(avail) using errcode = '42501'; end if;
  if coalesce(cardinality(p_invoice_ids), 0) > 0 then
    select array(select distinct x from unnest(p_invoice_ids) x) into ids;
    select count(*) into bad from unnest(ids) x where not exists (
      select 1 from centre_invoices i, lateral centre_balance_rows(p_org, array[i.id]) b
       where i.id = x and i.org_id = p_org and i.status = 'issued' and i.kind not in ('credit_note', 'deposit') and b.balance_cents > 0
         and (i.household_id = p_household or (i.household_id is null and i.student_id in (select s.id from students s where s.household_id = p_household and s.org_id = p_org))));
    if bad > 0 then raise exception 'NOT_ALLOWED: credit can only pay an open invoice of this family (not a deposit invoice or one that is already paid)' using errcode = '42501'; end if;
  end if;
  al := centre_allocate_held(p_org, p_household, 'family_credit', take, ids, null, today, 'Family credit applied');
  got := (al->>'allocated_cents')::bigint;
  if got <= 0 then raise exception 'NOTHING_TO_APPLY: this family has no open invoice for the credit to pay' using errcode = 'P0001'; end if;
  insert into centre_family_credit(org_id, household_id, kind, cents, payment_id, request_key, reason)
  values (p_org, p_household, 'applied', -got, (al->>'payment_id')::uuid, key,
          'Applied to ' || (select string_agg(a->>'number', ', ') from jsonb_array_elements(al->'allocated') a));
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), 'centre_credit_apply', 'centre_family_credit', p_household::text, null,
          jsonb_build_object('applied_cents', got, 'invoices', jsonb_array_length(al->'allocated'), 'credit_after_cents', centre_credit_balance(p_org, p_household)));
  return jsonb_build_object('already', false, 'applied_cents', got, 'allocated', al->'allocated', 'payment_id', al->>'payment_id', 'credit_balance_cents', centre_credit_balance(p_org, p_household));
end $$;

-- ASK to refund family credit (it is paid out only after approval; the amount is reserved at once)
create or replace function public.centre_credit_refund_request(p_org uuid, p_household uuid, p_cents bigint, p_payee text, p_reason text, p_request_key text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := centre_refund_gate(p_org, 'family_credit'); key text := nullif(btrim(coalesce(p_request_key, '')), ''); why text := nullif(btrim(coalesce(p_reason, '')), '');
  payee text := nullif(btrim(coalesce(p_payee, '')), ''); prior centre_refunds; bal bigint; res bigint; rid uuid := gen_random_uuid(); s jsonb := org_settings_on(p_org, today);
begin
  if not exists (select 1 from households h where h.id = p_household and h.org_id = p_org) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_cents is null or p_cents <= 0 then raise exception 'BAD_VALUE: the refund must be more than S$0.00' using errcode = 'P0001'; end if;
  if why is null then raise exception 'REASON_REQUIRED: say why this is being refunded' using errcode = 'P0001'; end if;
  if length(why) > 300 or length(coalesce(payee, '')) > 120 or length(coalesce(key, '')) > 80 then raise exception 'TOO_LONG: keep the reason under 300 and the name under 120 characters' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_household::text, 4));
  if key is not null then
    select * into prior from centre_refunds where org_id = p_org and request_key = key;
    if prior.id is not null then
      if prior.kind <> 'family_credit' or prior.household_id is distinct from p_household or prior.refund_cents <> p_cents then raise exception 'BAD_VALUE: that request key was used for something else' using errcode = 'P0001'; end if;
      return centre_refund_json(prior.id) || jsonb_build_object('already', true);
    end if;
  end if;
  bal := centre_credit_balance(p_org, p_household); res := centre_credit_reserved(p_org, p_household);
  if p_cents > bal - res then
    raise exception 'CREDIT_SHORT: this family has only % available to refund (% is held, % is already being refunded)', centre_fmt_money(greatest(bal - res, 0)), centre_fmt_money(bal), centre_fmt_money(res) using errcode = '42501';
  end if;
  insert into centre_refunds(id, org_id, kind, household_id, refund_cents, held_cents, release_rule, payer_name, reason, request_key, requested_on)
  values (rid, p_org, 'family_credit', p_household, p_cents, bal, centre_overpay_mode(s), payee, why, key, today);
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), 'centre_refund_request', 'centre_refunds', rid::text, null, jsonb_build_object('kind', 'family_credit', 'refund_cents', p_cents, 'credit_held_cents', bal));
  return centre_refund_json(rid) || jsonb_build_object('already', false);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 6. DEPOSIT RELEASE: what the centre's rules suggest when a student has left (read-only; nothing is written)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_deposit_release_proposal(p_student uuid, p_notice_given_on date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare org uuid; today date; st students; d centre_deposits; s jsonb; rule text; rel text; notice_days int; held bigint; resv bigint; avail bigint; endd date; hh uuid;
  grp text; reasons text[] := '{}'; n int; short boolean; unpaid bigint := 0; unpaid_list jsonb := '[]'::jsonb; sug_f bigint := 0; sug_s bigint := 0; sug_r bigint := 0;
  open_id uuid; state text; note text; scope_student uuid;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into st from students where id = p_student;
  if st.id is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  org := st.org_id; today := centre_refund_gate(org, 'view');
  s := org_settings_on(org, today);
  rule := centre_refund_rule(org, today);
  rel := coalesce(s#>>'{billing,deposit,release}', 'admin_decides');
  notice_days := coalesce((s#>>'{billing,deposit,forfeit_notice_days}')::int, 0);
  grp := coalesce(s#>>'{invoicing,grouping}', 'family');
  hh := st.household_id; endd := st.end_date;
  select * into d from centre_deposits where org_id = org and student_id = p_student;
  if d.id is null then return jsonb_build_object('state', 'no_deposit', 'student_id', p_student, 'name', st.name, 'waiting', '[]'::jsonb, 'today', today); end if;
  if p_notice_given_on is not null and p_notice_given_on > today then raise exception 'BAD_VALUE: the day notice was given can''t be in the future' using errcode = 'P0001'; end if;
  held := centre_deposit_held_cents(org, p_student); resv := centre_deposit_reserved(org, p_student); avail := greatest(held - resv, 0);
  select r.id into open_id from centre_refunds r where r.org_id = org and r.kind = 'deposit' and r.student_id = p_student and centre_refund_state(r.id) in ('requested', 'approved') limit 1;
  scope_student := case when grp = 'student' then p_student end;

  -- the final invoice: the proposal waits until it is issued
  if endd is null then reasons := array_append(reasons, 'The student hasn''t been ended yet. Set the day lessons run until in their profile.');
  elsif endd >= today then reasons := array_append(reasons, 'Lessons run until ' || to_char(endd, 'DD Mon YYYY') || '. A refund can be asked for after that day.'); end if;
  if endd is not null then
    select count(*) into n from centre_invoices i where i.org_id = org and i.status = 'draft' and i.kind in ('lesson', 'late_fee', 'opening')
       and (i.student_id = p_student or (grp <> 'student' and i.household_id = hh));
    if n > 0 then reasons := array_append(reasons, 'An invoice for this family is still a draft. Issue it first.'); end if;
    select count(*) into n from lessons l where l.org_id = org and l.student_id = p_student and l.lesson_date <= endd and coalesce(l.trial, false) = false
       and ((l.status = 'done' and coalesce(l.amount, 0) > 0) or (l.status = 'cancelled' and coalesce(l.compensation, 0) > 0))
       and not exists (select 1 from centre_invoice_lines x join centre_invoices i on i.id = x.invoice_id and i.org_id = x.org_id where x.lesson_id = l.id and i.status <> 'void');
    if n > 0 then reasons := array_append(reasons, n || case when n = 1 then ' lesson hasn''t' else ' lessons haven''t' end || ' been invoiced yet. Run the invoice run first.'); end if;
    select count(*) into n from lessons l where l.org_id = org and l.student_id = p_student and l.lesson_date <= endd and l.status = 'cancelled' and l.compensation is null;
    if n > 0 then reasons := array_append(reasons, 'A cancelled lesson is still waiting for its charge.'); end if;
  end if;

  -- what the family still owes (the deposit may be kept against it)
  select coalesce(sum(b.balance_cents), 0)::bigint,
         coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'number', i.number_text, 'balance_cents', b.balance_cents) order by i.issue_date, i.number_seq), '[]'::jsonb)
    into unpaid, unpaid_list
    from centre_invoices i, lateral centre_balance_rows(org, array[i.id]) b
   where i.org_id = org and i.status = 'issued' and i.kind not in ('credit_note', 'deposit') and b.balance_cents > 0
     and (case when scope_student is not null then i.student_id = scope_student
               else (i.household_id = hh or (i.household_id is null and i.student_id in (select s2.id from students s2 where s2.household_id = hh and s2.org_id = org))) end);

  short := case when notice_days > 0 and p_notice_given_on is not null and endd is not null then (endd - p_notice_given_on) < notice_days end;
  state := case when held <= 0 and open_id is null then 'nothing_held' when open_id is not null then 'open_refund' when cardinality(reasons) > 0 then 'waiting' when avail <= 0 then 'nothing_held' else 'ready' end;
  if rel <> 'admin_decides' then
    sug_f := case when coalesce(short, false) then avail else 0 end;
    sug_s := case when rel = 'refund_less_unpaid' and not d.taxable then least(avail - sug_f, unpaid) else 0 end;
    sug_r := avail - sug_f - sug_s;
  end if;
  note := case when d.taxable and rel = 'refund_less_unpaid' and unpaid > 0 then 'This deposit carried GST, so it can''t be kept against invoices: refund it and let the family pay the invoices.'
               when notice_days > 0 and p_notice_given_on is null then 'Type the day the family gave notice to see whether the deposit is kept.'
               when coalesce(short, false) then 'Less than ' || notice_days || ' days’ notice was given, so the centre''s rule suggests keeping the deposit. A kept deposit becomes income: ask your accountant whether GST applies.' end;
  return jsonb_build_object('today', today, 'student_id', p_student, 'name', st.name, 'household_id', hh, 'state', state, 'waiting', to_jsonb(reasons),
    'held_cents', held, 'reserved_cents', resv, 'available_cents', avail, 'taxable', d.taxable, 'unpaid_cents', unpaid, 'unpaid_invoices', unpaid_list,
    'release_rule', rel, 'approver_rule', rule, 'notice_days', notice_days, 'notice_given_on', p_notice_given_on, 'notice_needed', notice_days > 0 and p_notice_given_on is null,
    'notice_short', short, 'lesson_end', endd, 'open_refund_id', open_id, 'note', note,
    'suggest', case when rel = 'admin_decides' then null else jsonb_build_object('refund_cents', sug_r, 'forfeit_cents', sug_f, 'set_off_cents', sug_s) end,
    'can_request', state = 'ready' and org_can(org, 'issue_invoices'));
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 7. ASK to release a deposit: refund + keep (forfeit) + keep against unpaid invoices. Needs the proposal to be "ready".
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_deposit_refund_request(p_student uuid, p_refund_cents bigint, p_forfeit_cents bigint, p_set_off_cents bigint,
  p_notice_given_on date, p_payee text, p_reason text, p_request_key text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare org uuid; today date; st students; d centre_deposits; pr jsonb; why text := nullif(btrim(coalesce(p_reason, '')), ''); payee text := nullif(btrim(coalesce(p_payee, '')), '');
  key text := nullif(btrim(coalesce(p_request_key, '')), ''); f bigint := coalesce(p_forfeit_cents, 0); so bigint := coalesce(p_set_off_cents, 0); rf bigint := coalesce(p_refund_cents, 0);
  prior centre_refunds; rid uuid := gen_random_uuid(); gst bigint; s jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into st from students where id = p_student;
  if st.id is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  org := st.org_id; today := centre_refund_gate(org, 'deposit');
  if rf < 0 or f < 0 or so < 0 then raise exception 'BAD_VALUE: amounts can''t be negative' using errcode = 'P0001'; end if;
  if rf + f + so <= 0 then raise exception 'BAD_VALUE: choose how much to refund, keep or set off' using errcode = 'P0001'; end if;
  if why is null then raise exception 'REASON_REQUIRED: say why (kept in the record)' using errcode = 'P0001'; end if;
  if length(why) > 300 or length(coalesce(payee, '')) > 120 or length(coalesce(key, '')) > 80 then raise exception 'TOO_LONG: keep the reason under 300 and the name under 120 characters' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_student::text, 6));
  if key is not null then
    select * into prior from centre_refunds where org_id = org and request_key = key;
    if prior.id is not null then
      if prior.kind <> 'deposit' or prior.student_id is distinct from p_student or prior.refund_cents <> rf or prior.forfeit_cents <> f or prior.set_off_cents <> so then
        raise exception 'BAD_VALUE: that request key was used for something else' using errcode = 'P0001'; end if;
      return centre_refund_json(prior.id) || jsonb_build_object('already', true);
    end if;
  end if;
  pr := centre_deposit_release_proposal(p_student, p_notice_given_on);
  if pr->>'state' = 'no_deposit' then raise exception 'NO_DEPOSIT: this student has no deposit' using errcode = 'P0001'; end if;
  if pr->>'state' = 'open_refund' then
    -- a second press of the same request (no key) must do nothing twice: answer with the refund that is already open when it is the same
    select * into prior from centre_refunds where id = (pr->>'open_refund_id')::uuid;
    if prior.refund_cents = rf and prior.forfeit_cents = f and prior.set_off_cents = so then return centre_refund_json(prior.id) || jsonb_build_object('already', true); end if;
    raise exception 'OPEN_REFUND: a refund for this deposit is already in progress; finish or cancel it first' using errcode = 'P0001';
  end if;
  if pr->>'state' = 'nothing_held' then raise exception 'DEPOSIT_SHORT: nothing is held for this student, so there is nothing to refund' using errcode = '23514'; end if;
  if pr->>'state' = 'waiting' then raise exception 'NOT_READY: %', (pr->'waiting'->>0) using errcode = '42501'; end if;
  if rf + f + so > (pr->>'available_cents')::bigint then
    raise exception 'DEPOSIT_SHORT: only % is held and free to release (you asked for %)', centre_fmt_money((pr->>'available_cents')::bigint), centre_fmt_money(rf + f + so) using errcode = '23514'; end if;
  select * into d from centre_deposits where org_id = org and student_id = p_student;
  if so > 0 and d.taxable then raise exception 'NOT_ALLOWED: this deposit carried GST, so it can''t be kept against invoices. Refund it and let the family pay the invoices.' using errcode = '42501'; end if;
  if so > (pr->>'unpaid_cents')::bigint then
    raise exception 'NOT_ALLOWED: the family owes only % on open invoices, so you can''t keep % against them', centre_fmt_money((pr->>'unpaid_cents')::bigint), centre_fmt_money(so) using errcode = '42501'; end if;
  s := org_settings_on(org, today);
  gst := centre_deposit_gst_share(d.id, org, rf);
  insert into centre_refunds(id, org_id, kind, student_id, household_id, deposit_id, refund_cents, forfeit_cents, set_off_cents, held_cents, taxable, gst_cents, release_rule,
                             notice_days, notice_given_on, lesson_end, payer_name, reason, request_key, requested_on)
  values (rid, org, 'deposit', p_student, st.household_id, d.id, rf, f, so, (pr->>'held_cents')::bigint, d.taxable, gst, pr->>'release_rule',
          nullif((pr->>'notice_days')::int, 0), p_notice_given_on, st.end_date, payee, why, key, today);
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (org, auth.uid(), 'centre_refund_request', 'centre_refunds', rid::text, null,
          jsonb_build_object('kind', 'deposit', 'refund_cents', rf, 'forfeit_cents', f, 'set_off_cents', so, 'held_cents', (pr->>'held_cents')::bigint, 'gst_cents', gst));
  return centre_refund_json(rid) || jsonb_build_object('already', false);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 8. APPROVE · PAY · CANCEL
-- ---------------------------------------------------------------------------------------------------
-- the moment money moves on the ledgers: called once, when the refund is paid (or approved, when there is no cash to pay out)
create or replace function public.centre_refund_settle(r centre_refunds, p_today date, p_method text, p_paid_on date, p_reference text, p_note text)
returns bigint language plpgsql security definer set search_path = public, pg_temp as $$
declare d centre_deposits; hh uuid; al jsonb; got bigint := 0; nums text;
begin
  if r.kind = 'family_credit' then
    insert into centre_family_credit(org_id, household_id, kind, cents, method, reference, reason, refund_id)
    values (r.org_id, r.household_id, 'refund', -r.refund_cents, p_method, p_reference, r.reason, r.id);
  else
    perform pg_advisory_xact_lock(hashtextextended(r.student_id::text, 6));
    select * into d from centre_deposits where id = r.deposit_id and org_id = r.org_id;
    select s.household_id into hh from students s where s.id = r.student_id and s.org_id = r.org_id;
    if r.set_off_cents > 0 and hh is not null then
      perform pg_advisory_xact_lock(hashtextextended(hh::text, 4));
      al := centre_allocate_held(r.org_id, hh, 'deposit', r.set_off_cents, null,
                                 case when coalesce(org_settings_on(r.org_id, p_today)#>>'{invoicing,grouping}', 'family') = 'student' then r.student_id end, p_today, 'Deposit kept against invoices');
      got := (al->>'allocated_cents')::bigint;
      if got > 0 then
        select string_agg(a->>'number', ', ') into nums from jsonb_array_elements(al->'allocated') a;
        insert into centre_deposit_ledger(org_id, student_id, deposit_id, kind, cents, taxable, payment_id, entry_date, reason, refund_id)
        values (r.org_id, r.student_id, d.id, 'applied', -got, d.taxable, (al->>'payment_id')::uuid, p_today, 'Kept against ' || nums, r.id);
      end if;
    end if;
    if r.forfeit_cents > 0 then
      insert into centre_deposit_ledger(org_id, student_id, deposit_id, kind, cents, taxable, entry_date, reason, refund_id)
      values (r.org_id, r.student_id, d.id, 'forfeited', -r.forfeit_cents, d.taxable, p_today, 'Kept by the centre: ' || r.reason, r.id);
    end if;
    if r.refund_cents > 0 then
      insert into centre_deposit_ledger(org_id, student_id, deposit_id, kind, cents, taxable, entry_date, reason, refund_id)
      values (r.org_id, r.student_id, d.id, 'refunded', -r.refund_cents, d.taxable, coalesce(p_paid_on, p_today), 'Refunded to the family', r.id);
    end if;
  end if;
  insert into centre_refund_events(org_id, refund_id, kind, event_on, method, reference, note, set_off_cents)
  values (r.org_id, r.id, 'paid', coalesce(p_paid_on, p_today), p_method, p_reference, p_note, case when r.kind = 'deposit' then got end);
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (r.org_id, auth.uid(), 'centre_refund_paid', 'centre_refunds', r.id::text, null,
          jsonb_build_object('kind', r.kind, 'refund_cents', r.refund_cents, 'forfeit_cents', r.forfeit_cents, 'set_off_asked_cents', r.set_off_cents, 'set_off_done_cents', got, 'gst_cents', r.gst_cents));
  return got;
end $$;

create or replace function public.centre_refund_approve(p_refund uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r centre_refunds; today date; st text; rule text; note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into r from centre_refunds where id = p_refund;
  if r.id is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := centre_refund_gate(r.org_id, r.kind);
  if length(coalesce(note, '')) > 300 then raise exception 'TOO_LONG: keep the note under 300 characters' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_refund::text, 7));
  st := centre_refund_state(p_refund);
  if st in ('approved', 'paid') then return centre_refund_json(p_refund) || jsonb_build_object('already', true); end if;
  if st = 'cancelled' then raise exception 'ALREADY_CANCELLED: that refund was cancelled' using errcode = 'P0001'; end if;
  rule := centre_refund_rule(r.org_id, today);
  if not centre_refund_can_approve(r.org_id, r.kind, r.requested_by, rule) then
    raise exception 'NOT_ALLOWED: %', case rule
      when 'owner' then 'this centre lets only the owner approve refunds (see Centre settings)'
      when 'four_eyes' then case when auth.uid() is not distinct from r.requested_by then 'a refund has to be approved by someone other than the person who asked for it'
                                 else 'your account can''t approve this kind of refund' end
      else 'your account can''t approve this kind of refund' end using errcode = '42501';
  end if;
  insert into centre_refund_events(org_id, refund_id, kind, event_on, note) values (r.org_id, r.id, 'approved', today, note);
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (r.org_id, auth.uid(), 'centre_refund_approve', 'centre_refunds', r.id::text, null, jsonb_build_object('kind', r.kind, 'rule', rule, 'refund_cents', r.refund_cents));
  if r.refund_cents = 0 then perform centre_refund_settle(r, today, null, today, null, null); end if;     -- nothing to pay out: keeping a deposit is complete on approval
  return centre_refund_json(p_refund) || jsonb_build_object('already', false);
end $$;

create or replace function public.centre_refund_pay(p_refund uuid, p_method text, p_paid_on date, p_reference text default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r centre_refunds; today date; st text; ref text; note text := nullif(btrim(coalesce(p_note, '')), ''); got bigint;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into r from centre_refunds where id = p_refund;
  if r.id is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := centre_refund_gate(r.org_id, r.kind);
  perform pg_advisory_xact_lock(hashtextextended(p_refund::text, 7));
  st := centre_refund_state(p_refund);
  if st = 'paid' then return centre_refund_json(p_refund) || jsonb_build_object('already', true); end if;
  if st = 'cancelled' then raise exception 'ALREADY_CANCELLED: that refund was cancelled' using errcode = 'P0001'; end if;
  if st <> 'approved' then raise exception 'NOT_APPROVED: the refund has to be approved before it is marked paid' using errcode = '42501'; end if;
  if p_method is null or p_method not in ('manual_paynow', 'bank', 'cash', 'cheque', 'other') then raise exception 'BAD_VALUE: choose how it was paid back' using errcode = 'P0001'; end if;
  if p_paid_on is null then raise exception 'BAD_VALUE: say the day it was paid' using errcode = 'P0001'; end if;
  if p_paid_on > today then raise exception 'BAD_VALUE: the day it was paid can''t be in the future' using errcode = 'P0001'; end if;
  if p_paid_on < r.requested_on then raise exception 'BAD_VALUE: it can''t have been paid before it was asked for (%).', to_char(r.requested_on, 'DD Mon YYYY') using errcode = 'P0001'; end if;
  if length(coalesce(note, '')) > 300 then raise exception 'TOO_LONG: keep the note under 300 characters' using errcode = 'P0001'; end if;
  ref := centre_clean_reference(p_reference);
  got := centre_refund_settle(r, today, p_method, p_paid_on, ref, note);
  return centre_refund_json(p_refund) || jsonb_build_object('already', false, 'set_off_done_cents', got);
end $$;

create or replace function public.centre_refund_cancel(p_refund uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r centre_refunds; today date; st text; why text := nullif(btrim(coalesce(p_reason, '')), ''); rule text; perm text;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into r from centre_refunds where id = p_refund;
  if r.id is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := centre_refund_gate(r.org_id, r.kind);
  perform pg_advisory_xact_lock(hashtextextended(p_refund::text, 7));
  st := centre_refund_state(p_refund);
  if st = 'cancelled' then return centre_refund_json(p_refund) || jsonb_build_object('already', true); end if;
  if st = 'paid' then raise exception 'ALREADY_PAID: that refund was already paid, so it can''t be cancelled' using errcode = 'P0001'; end if;
  if why is null then raise exception 'REASON_REQUIRED: say why this refund is being cancelled' using errcode = 'P0001'; end if;
  if length(why) > 300 then raise exception 'TOO_LONG: keep the reason under 300 characters' using errcode = 'P0001'; end if;
  rule := centre_refund_rule(r.org_id, today);
  perm := case r.kind when 'deposit' then 'issue_invoices' else 'record_payments' end;
  if not (org_can(r.org_id, 'owner') or r.requested_by = auth.uid() or (rule <> 'owner' and org_can(r.org_id, perm))) then
    raise exception 'NOT_ALLOWED: only the person who asked, an approver or the owner can cancel this refund' using errcode = '42501'; end if;
  insert into centre_refund_events(org_id, refund_id, kind, event_on, reason) values (r.org_id, r.id, 'cancelled', today, why);
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (r.org_id, auth.uid(), 'centre_refund_cancel', 'centre_refunds', r.id::text, null, jsonb_build_object('kind', r.kind, 'refund_cents', r.refund_cents));
  return centre_refund_json(p_refund) || jsonb_build_object('already', false);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 9. WHAT THE SCREENS READ: the list and one refund's statement
-- ---------------------------------------------------------------------------------------------------
-- p_state: null = everything, 'open' = requested or approved, 'closed' = paid or cancelled. Open ones first, then newest.
create or replace function public.centre_refund_list(p_org uuid, p_state text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := centre_refund_gate(p_org, 'view');
begin
  if p_state is not null and p_state not in ('open', 'closed') then raise exception 'BAD_VALUE: unknown filter' using errcode = 'P0001'; end if;
  return jsonb_build_object('today', today, 'approver_rule', centre_refund_rule(p_org, today),
    'rows', coalesce((select jsonb_agg(x.j order by x.open desc, x.created_at desc, x.id)
      from (select centre_refund_json(r.id) as j, centre_refund_state(r.id) in ('requested', 'approved') as open, r.created_at, r.id
              from centre_refunds r where r.org_id = p_org) x
     where p_state is null or (p_state = 'open' and x.open) or (p_state = 'closed' and not x.open)), '[]'::jsonb));
end $$;

-- the trail of one refund: what was asked and why, who approved, who paid and how, and what the ledgers did
create or replace function public.centre_refund_statement(p_refund uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r centre_refunds; nm text;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into r from centre_refunds where id = p_refund;
  if r.id is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  perform centre_refund_gate(r.org_id, 'view');
  select o.trading_name into nm from organisations o where o.id = r.org_id;
  return centre_refund_json(p_refund) || jsonb_build_object('centre', nm);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 10. the old owner-only "refund family credit" now goes through the same request → approve → pay steps (so no setting can be bypassed)
--     Same name and arguments as S3. Owner only, as before. If the centre's rule needs somebody else to approve, the refund waits as "requested".
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_refund_family_credit(p_org uuid, p_household uuid, p_cents bigint, p_method text, p_reference text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := centre_money_gate(p_org, 'owner'); ref text; j jsonb; rid uuid;
begin
  if p_method is null or p_method not in ('manual_paynow', 'bank', 'cash', 'cheque', 'other') then raise exception 'BAD_VALUE: choose how it was paid back' using errcode = 'P0001'; end if;
  ref := centre_clean_reference(p_reference);
  j := centre_credit_refund_request(p_org, p_household, p_cents, null, p_reason);
  rid := (j->>'id')::uuid;
  if (j->>'can_approve')::boolean then
    j := centre_refund_approve(rid);
    j := centre_refund_pay(rid, p_method, today, ref, null);
  end if;
  return jsonb_build_object('refund_id', rid, 'state', j->>'state', 'refunded_cents', case when j->>'state' = 'paid' then p_cents else 0 end,
                            'balance_cents', centre_credit_balance(p_org, p_household));
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 11. revenue totals that know about refunds (replaces the S4 function; same keys plus the refund figures)
--     received_cents leaves out credit that was merely moved onto an invoice (the cash was counted when it first came in). A deposit KEPT against an
--     invoice does count as received (it has become fees). refund_gst_cents is GST given back with refunded taxable deposits (already taken off gst_cents).
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_revenue_totals(p_org uuid, p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb; dep_in bigint; dep_held bigint; rf_dep bigint; rf_cred bigint; forf bigint; rf_gst bigint;
begin
  if auth.uid() is null or not exists (select 1 from organisations o where o.id = p_org and o.kind = 'centre') or not org_can(p_org, 'view_revenue') then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  select coalesce(sum(r2.refund_cents) filter (where r2.kind = 'deposit'), 0), coalesce(sum(r2.refund_cents) filter (where r2.kind = 'family_credit'), 0),
         coalesce(sum(r2.forfeit_cents), 0), coalesce(sum(r2.gst_cents), 0)
    into rf_dep, rf_cred, forf, rf_gst
    from centre_refunds r2 join centre_refund_events e on e.refund_id = r2.id and e.org_id = r2.org_id and e.kind = 'paid'
   where r2.org_id = p_org and (p_from is null or e.event_on >= p_from) and (p_to is null or e.event_on <= p_to);
  select jsonb_build_object(
    'invoiced_cents',  coalesce(sum(i.total_cents) filter (where i.kind not in ('credit_note', 'deposit')), 0),
    'gst_cents',       coalesce(sum(i.gst_cents) filter (where i.kind <> 'credit_note'), 0) - coalesce(sum(i.gst_cents) filter (where i.kind = 'credit_note'), 0) - rf_gst,
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
  r := r || jsonb_build_object('received_cents', coalesce((select sum(case when p.method = 'family_credit' then 0 when p.kind = 'payment' then p.amount_cents else -p.amount_cents end)
       from centre_payments p where p.org_id = p_org and (p_from is null or p.received_on >= p_from) and (p_to is null or p.received_on <= p_to)), 0) - dep_in,
       'deposits_received_cents', dep_in, 'deposits_held_cents', dep_held,
       'deposits_refunded_cents', rf_dep, 'deposits_forfeited_cents', forf, 'credit_refunded_cents', rf_cred, 'refund_gst_cents', rf_gst);
  return r;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 12. function access
-- ---------------------------------------------------------------------------------------------------
revoke all on function public.centre_refund_guard() from public, anon, authenticated;
revoke all on function public.centre_refund_event_guard() from public, anon, authenticated;
revoke all on function public.centre_internal_method_guard() from public, anon, authenticated;
revoke all on function public.centre_refund_gate(uuid, text) from public, anon, authenticated;
revoke all on function public.centre_refund_can_approve(uuid, text, uuid, text) from public, anon, authenticated;
revoke all on function public.centre_refund_rule(uuid, date) from public, anon, authenticated;
revoke all on function public.centre_refund_state(uuid) from public, anon, authenticated;
revoke all on function public.centre_deposit_reserved(uuid, uuid) from public, anon, authenticated;
revoke all on function public.centre_credit_reserved(uuid, uuid) from public, anon, authenticated;
revoke all on function public.centre_deposit_held_cents(uuid, uuid) from public, anon, authenticated;
revoke all on function public.centre_person_name(uuid, uuid) from public, anon, authenticated;
revoke all on function public.centre_clean_reference(text) from public, anon;
revoke all on function public.centre_deposit_gst_share(uuid, uuid, bigint) from public, anon, authenticated;
revoke all on function public.centre_allocate_held(uuid, uuid, text, bigint, uuid[], uuid, date, text) from public, anon, authenticated;
revoke all on function public.centre_refund_json(uuid) from public, anon, authenticated;
revoke all on function public.centre_refund_settle(centre_refunds, date, text, date, text, text) from public, anon, authenticated;
revoke all on function public.centre_family_credit_status(uuid, uuid) from public, anon;
revoke all on function public.centre_apply_family_credit(uuid, uuid, uuid[], bigint, text) from public, anon;
revoke all on function public.centre_credit_refund_request(uuid, uuid, bigint, text, text, text) from public, anon;
revoke all on function public.centre_deposit_release_proposal(uuid, date) from public, anon;
revoke all on function public.centre_deposit_refund_request(uuid, bigint, bigint, bigint, date, text, text, text) from public, anon;
revoke all on function public.centre_refund_approve(uuid, text) from public, anon;
revoke all on function public.centre_refund_pay(uuid, text, date, text, text) from public, anon;
revoke all on function public.centre_refund_cancel(uuid, text) from public, anon;
revoke all on function public.centre_refund_list(uuid, text) from public, anon;
revoke all on function public.centre_refund_statement(uuid) from public, anon;
revoke all on function public.centre_refund_family_credit(uuid, uuid, bigint, text, text, text) from public, anon;
revoke all on function public.centre_revenue_totals(uuid, date, date) from public, anon;
grant execute on function public.centre_clean_reference(text) to authenticated, service_role;
grant execute on function public.centre_family_credit_status(uuid, uuid), public.centre_apply_family_credit(uuid, uuid, uuid[], bigint, text),
  public.centre_credit_refund_request(uuid, uuid, bigint, text, text, text), public.centre_deposit_release_proposal(uuid, date),
  public.centre_deposit_refund_request(uuid, bigint, bigint, bigint, date, text, text, text), public.centre_refund_approve(uuid, text),
  public.centre_refund_pay(uuid, text, date, text, text), public.centre_refund_cancel(uuid, text), public.centre_refund_list(uuid, text),
  public.centre_refund_statement(uuid), public.centre_refund_family_credit(uuid, uuid, bigint, text, text, text), public.centre_revenue_totals(uuid, date, date)
  to authenticated, service_role;
