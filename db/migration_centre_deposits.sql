-- =====================================================================================================
-- T4 step S4 — centre deposits: refundable deposit ledger, deposit invoice with the first run, "Deposits held"   undo: migration_centre_deposits_down.sql
-- =====================================================================================================
-- Run order everywhere: org_foundation → billing → attendance → tutor_access → org_delete → function_lockdown → org_separation →
--   staff_home → staff_students → staff_attendance → staff_charges → staff_trials → staff_timetable → money_settings →
--   centre_money → centre_invoice_run → centre_payments → centre_deposits.
-- Needs migration_money_settings.sql (S0: the deposit options), migration_centre_money.sql (S1), migration_centre_invoice_run.sql (S2) and
-- migration_centre_payments.sql (S3: payments, credit notes). Run on the DEV project first. LIVE only when the owner says ship: this migration
-- reads no existing row and changes none (two new tables, two nullable columns, new functions; it REPLACES five S1/S2 functions with versions that
-- also know about deposits, and widens two checks on centre_invoices). Safe to run twice.
--
-- WHAT A DEPOSIT IS HERE (owner-approved T4 decisions, 2026-11-26)
--   A refundable deposit is a LIABILITY: money the centre holds for a family. It lives in its own ledger, is NEVER revenue, carries NO GST when
--   received (a `taxable` flag on every deposit row lets an accountant's answer change the default without a schema change: the setting
--   billing.deposit.taxable, read when the deposit is raised and then frozen on the row), and never appears in a revenue figure
--   (centre_revenue_totals below leaves deposit invoices and the cash that paid them out and reports them separately).
--
-- WHAT THIS ADDS
--   centre_deposits          one row per student: the REQUIRED amount, frozen the first time it is computed (mode, percent used, first month's fee,
--                            taxable flag). Never recomputed when fees change. Only its invoice link may move (a discarded draft is re-raised).
--   centre_deposit_ledger    APPEND-ONLY cents per student: received · reversal · waived · adjusted · applied · forfeited · refunded · transferred_out ·
--                            transferred_in · opening_balance. Held = every row except `waived` (a waiver reduces what is asked, it is not cash).
--                            Never below zero. Refund / release / forfeit / transfer / adjustment are S5; the kinds exist so S5 needs no rewrite.
--   invoice kind 'deposit'   a separate document called "Refundable deposit", raised WITH the student's first invoice run, sharing the one gap-free
--                            counter; a draft until approved (or issued straight away when the centre doesn't review). Paid like any invoice through
--                            S3 payments: the allocation writes the ledger row (trigger below), so there is no second way to "receive" a deposit.
--   invoice kind 'opening'   (T33 plan, decision 3) an old invoice carried over from the centre's previous books. It KEEPS ITS OLD NUMBER
--                            (centre_invoices.imported_number), does NOT use the counter, and is issued, immutable and payable like any other.
--   students.start_date      nullable: the day lessons started (T33 import). Recorded only: it doesn't decide anything about deposits.
--
-- THE RULES
--   mode none                  nothing is raised.
--   mode fixed                 the centre's fixed amount (billing.one_off_fees.deposit_cents) for each student with a non-trial lesson in a ready invoice.
--   mode percent_first_month   percent_bp of THAT student's first month: their non-trial lessons in this run, before sibling discount, fees and GST.
--   FIRST RUN ONLY             a student gets a deposit once: when they have no deposit row yet, no lesson on any earlier invoice of the centre, and
--                              their household's invoice is READY (not held back). A second run adds nothing. A discarded deposit DRAFT is raised
--                              again with the same frozen amount. Trial students (no non-trial lesson) get none. A deposit never gets a late fee.
--   billing.deposit.due        only with_first_invoice is built; before_first_lesson is `soon`: the preview says so and no deposit is raised.
--   billing.deposit.waived_by  owner / issue_invoices / nobody, read as of today. Waiving needs a reason. A draft deposit invoice is discarded; an
--                              issued one is credited for what is still unpaid (a credit note, the S3 way); a fully paid deposit can't be waived.
--   opening balance            OWNER ONLY, one per student, for deposits collected before TutorDeck (no invoice, no number used, no revenue).
--
-- WHO MAY CALL: reading the ledger and "Deposits held": an owner or staff with record_payments OR view_revenue. Opening balance: owner. Waiving: as
--   the waived_by setting says. Everyone else (tutors, parents, switched-off staff, solo owners, strangers, anonymous) gets NOT_FOUND. The two new
--   tables have a read policy by the same rule and NO write policy: browsers never write a deposit.
-- AUDIT: both tables use the S1 audit trigger (free text replaced by "[redacted]"); each function adds a summary row with amounts and counts only.
-- =====================================================================================================

-- ---------------------------------------------------------------------------------------------------
-- 1. small additions to existing tables
-- ---------------------------------------------------------------------------------------------------
alter table public.students add column if not exists start_date date;
alter table public.centre_invoices add column if not exists imported_number text;

do $$
declare c record;
begin
  -- the allowed kinds gain 'opening'
  for c in select conname from pg_constraint where conrelid = 'public.centre_invoices'::regclass and contype = 'c'
            and pg_get_constraintdef(oid) like '%''lesson''%' and pg_get_constraintdef(oid) like '%''credit_note''%' and pg_get_constraintdef(oid) like '%''late_fee''%'
            and pg_get_constraintdef(oid) not like '%opening%' loop
    execute format('alter table public.centre_invoices drop constraint %I', c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname = 'centre_invoices_kind_ck') then
    alter table public.centre_invoices add constraint centre_invoices_kind_ck check (kind in ('lesson', 'deposit', 'late_fee', 'credit_note', 'opening'));
  end if;
  -- "issued ⇔ numbered": an opening invoice keeps its old number as text and has no counter number
  for c in select conname from pg_constraint where conrelid = 'public.centre_invoices'::regclass and contype = 'c'
            and pg_get_constraintdef(oid) like '%number_seq IS NOT NULL) AND (number_text IS NOT NULL)%' loop
    execute format('alter table public.centre_invoices drop constraint %I', c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname = 'centre_invoices_number_ck') then
    alter table public.centre_invoices add constraint centre_invoices_number_ck check (
      ((status = 'issued') = (number_text is not null)) and ((status = 'issued' and kind <> 'opening') = (number_seq is not null)));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'centre_invoices_imported_ck') then
    alter table public.centre_invoices add constraint centre_invoices_imported_ck check ((kind = 'opening') = (imported_number is not null));
  end if;
end $$;
create unique index if not exists centre_invoices_opening_number on public.centre_invoices(org_id, lower(imported_number)) where kind = 'opening' and status <> 'void';
-- one live deposit invoice per student (a discarded draft is void and doesn't count)
create unique index if not exists centre_invoices_one_deposit on public.centre_invoices(org_id, student_id) where kind = 'deposit' and status <> 'void';

-- ---------------------------------------------------------------------------------------------------
-- 2. the tables
-- ---------------------------------------------------------------------------------------------------
create table if not exists public.centre_deposits (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organisations(id) on delete cascade,
  student_id        uuid not null,
  household_id      uuid,                                   -- the family at the time (a snapshot; the student may move later)
  source            text not null check (source in ('invoice_run', 'opening_balance')),
  mode              text not null check (mode in ('fixed', 'percent_first_month', 'opening')),
  percent_bp        int  check (percent_bp between 1 and 10000),
  first_month_cents bigint check (first_month_cents >= 0),  -- the first month's fee the percent was applied to (frozen with the deposit)
  required_cents    bigint not null check (required_cents > 0),
  taxable           boolean not null default false,          -- frozen from billing.deposit.taxable when raised; see the header
  period_start      date,                                    -- the invoice-run month it was raised in
  invoice_id        uuid,                                    -- the deposit invoice (null for an opening balance)
  created_by        uuid default auth.uid(),
  created_at        timestamptz not null default now(),
  unique (id, org_id),
  unique (org_id, student_id),
  foreign key (student_id, org_id)   references public.students(id, org_id),
  foreign key (household_id, org_id) references public.households(id, org_id),
  foreign key (invoice_id, org_id)   references public.centre_invoices(id, org_id),
  check ((source = 'invoice_run') = (mode in ('fixed', 'percent_first_month'))),
  check ((mode = 'percent_first_month') = (percent_bp is not null and first_month_cents is not null)),
  check ((source = 'opening_balance') = (invoice_id is null))
);
create index if not exists centre_deposits_invoice on public.centre_deposits(invoice_id) where invoice_id is not null;

create table if not exists public.centre_deposit_ledger (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organisations(id) on delete cascade,
  student_id    uuid not null,
  deposit_id    uuid not null,
  kind          text not null check (kind in ('received', 'reversal', 'waived', 'adjusted', 'applied', 'forfeited', 'refunded', 'transferred_out', 'transferred_in', 'opening_balance')),
  cents         bigint not null check (cents <> 0),
  taxable       boolean not null default false,             -- copied from the deposit row, so the accountant can total the taxable part
  invoice_id    uuid,
  payment_id    uuid,
  allocation_id uuid unique,                                 -- one ledger row per payment allocation (a payment can't be counted twice)
  entry_date    date not null default current_date,
  reason        text,                                        -- free text; redacted in the audit copy
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  unique (id, org_id),
  foreign key (student_id, org_id) references public.students(id, org_id),
  foreign key (deposit_id, org_id) references public.centre_deposits(id, org_id),
  foreign key (invoice_id, org_id) references public.centre_invoices(id, org_id),
  foreign key (payment_id, org_id) references public.centre_payments(id, org_id),
  foreign key (allocation_id)      references public.centre_payment_allocations(id),
  check (case kind when 'received' then cents > 0 when 'opening_balance' then cents > 0 when 'transferred_in' then cents > 0 when 'waived' then cents > 0
                   when 'reversal' then cents < 0 when 'applied' then cents < 0 when 'forfeited' then cents < 0 when 'refunded' then cents < 0
                   when 'transferred_out' then cents < 0 else true end),
  check (kind not in ('waived', 'adjusted') or length(trim(coalesce(reason, ''))) > 0)
);
create index if not exists centre_deposit_ledger_student on public.centre_deposit_ledger(org_id, student_id, entry_date);
create index if not exists centre_deposit_ledger_invoice on public.centre_deposit_ledger(invoice_id) where invoice_id is not null;

-- ---------------------------------------------------------------------------------------------------
-- 3. guards (same shape as S1: centres only, append-only, the exception for deleting a whole organisation)
-- ---------------------------------------------------------------------------------------------------
-- the deposit row is frozen: only its invoice link may move, and only from "none or discarded" to a new draft deposit invoice of the same student
create or replace function public.centre_deposit_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare cur record; nw record;
begin
  if tg_op = 'DELETE' then
    if centre_money_deleting(old.org_id) then return old; end if;
    raise exception 'A deposit record can''t be deleted (it is a money record)' using errcode = '42501';
  end if;
  if tg_op = 'INSERT' then
    if new.source = 'invoice_run' then
      select * into nw from centre_invoices where id = new.invoice_id and org_id = new.org_id;
      if nw.id is null or nw.kind <> 'deposit' or nw.student_id is distinct from new.student_id then
        raise exception 'A deposit needs its own deposit invoice for the same student' using errcode = '42501'; end if;
    end if;
    return new;
  end if;
  -- UPDATE: nothing but the invoice link
  if (to_jsonb(new) - 'invoice_id') <> (to_jsonb(old) - 'invoice_id') then
    raise exception 'A deposit''s amount and terms are frozen (record an adjustment instead)' using errcode = '42501'; end if;
  if new.invoice_id is distinct from old.invoice_id then
    if old.source <> 'invoice_run' then raise exception 'This deposit has no invoice' using errcode = '42501'; end if;
    if old.invoice_id is not null then
      select * into cur from centre_invoices where id = old.invoice_id and org_id = old.org_id;
      if cur.status <> 'void' then raise exception 'This deposit already has a live invoice' using errcode = '42501'; end if;
    end if;
    select * into nw from centre_invoices where id = new.invoice_id and org_id = new.org_id;
    if nw.id is null or nw.kind <> 'deposit' or nw.status <> 'draft' or nw.student_id is distinct from new.student_id then
      raise exception 'The new invoice must be a draft deposit invoice for the same student' using errcode = '42501'; end if;
  end if;
  return new;
end $$;

-- the ledger is append-only, and what is held for a student never goes below zero (you can't hand back what you don't hold)
create or replace function public.centre_deposit_ledger_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare bal bigint; d record;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    if tg_op = 'DELETE' and centre_money_deleting(old.org_id) then return old; end if;
    raise exception 'The deposit ledger is append-only (a correction is a new row)' using errcode = '42501';
  end if;
  select * into d from centre_deposits where id = new.deposit_id and org_id = new.org_id;
  if d.id is null or d.student_id <> new.student_id then raise exception 'That ledger row doesn''t match its deposit' using errcode = '42501'; end if;
  if new.kind <> 'waived' then
    perform pg_advisory_xact_lock(hashtextextended(new.student_id::text, 6));
    select coalesce(sum(cents), 0) + new.cents into bal from centre_deposit_ledger where org_id = new.org_id and student_id = new.student_id and kind <> 'waived';
    if bal < 0 then
      raise exception 'DEPOSIT_SHORT: that would take the deposit held below zero (% cents held)', bal - new.cents using errcode = '23514'; end if;
  end if;
  return new;
end $$;

-- a payment allocated to a deposit invoice is how a deposit is received (and a reversed payment un-receives it): one row per allocation
create or replace function public.centre_deposit_alloc_hook() returns trigger
language plpgsql security definer set search_path = public as $$
declare d record; pdate date;
begin
  select * into d from centre_deposits where invoice_id = new.invoice_id and org_id = new.org_id;
  if d.id is null then return null; end if;
  select received_on into pdate from centre_payments where id = new.payment_id and org_id = new.org_id;
  insert into centre_deposit_ledger(org_id, student_id, deposit_id, kind, cents, taxable, invoice_id, payment_id, allocation_id, entry_date)
  values (new.org_id, d.student_id, d.id, case when new.cents > 0 then 'received' else 'reversal' end, new.cents, d.taxable, new.invoice_id, new.payment_id, new.id, pdate);
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['centre_deposits', 'centre_deposit_ledger'] loop
    execute format('drop trigger if exists centre_money_org_guard on public.%I', t);
    execute format('create trigger centre_money_org_guard before insert on public.%I for each row execute function public.centre_money_org_guard()', t);
    execute format('drop trigger if exists audit_row on public.%I', t);
    execute format('create trigger audit_row after insert or update or delete on public.%I for each row execute function public.centre_money_audit()', t);
  end loop;
end $$;
drop trigger if exists centre_deposit_guard on public.centre_deposits;
create trigger centre_deposit_guard before insert or update or delete on public.centre_deposits for each row execute function public.centre_deposit_guard();
drop trigger if exists centre_deposit_ledger_guard on public.centre_deposit_ledger;
create trigger centre_deposit_ledger_guard before insert or update or delete on public.centre_deposit_ledger for each row execute function public.centre_deposit_ledger_guard();
drop trigger if exists centre_deposit_alloc_hook on public.centre_payment_allocations;
create trigger centre_deposit_alloc_hook after insert on public.centre_payment_allocations for each row execute function public.centre_deposit_alloc_hook();

-- access: read by permission, written by nobody from a browser
alter table public.centre_deposits enable row level security;
alter table public.centre_deposit_ledger enable row level security;
drop policy if exists money_read on public.centre_deposits;
create policy money_read on public.centre_deposits for select using ((org_can(org_id, 'record_payments') or org_can(org_id, 'view_revenue')) and not org_is_solo(org_id));
drop policy if exists money_read on public.centre_deposit_ledger;
create policy money_read on public.centre_deposit_ledger for select using ((org_can(org_id, 'record_payments') or org_can(org_id, 'view_revenue')) and not org_is_solo(org_id));
revoke all on public.centre_deposits, public.centre_deposit_ledger from anon, authenticated;
grant select on public.centre_deposits, public.centre_deposit_ledger to authenticated;

-- ---------------------------------------------------------------------------------------------------
-- 4. the invoice guard, now also issuing an OPENING invoice under its old number (copy of the S1 function with one branch added)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_invoice_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare s jsonb; prefix text; sub bigint; nlines int; t record; credited bigint; inv record; day date;
begin
  if tg_op = 'DELETE' then
    if old.status = 'draft' or centre_money_deleting(old.org_id) then return old; end if;
    raise exception 'An issued or voided document can''t be deleted (issue a credit note instead)' using errcode = '42501';
  end if;
  if tg_op = 'INSERT' then
    if new.status <> 'draft' or new.number_seq is not null or new.number_text is not null then
      raise exception 'A new document starts as a draft with no number' using errcode = '42501';
    end if;
    return new;
  end if;
  -- UPDATE
  if old.status <> 'draft' then
    raise exception 'An % document can''t be changed (issue a credit note instead)', old.status using errcode = '42501';
  end if;
  if new.org_id <> old.org_id or new.kind <> old.kind then raise exception 'A document''s organisation and kind can''t change'; end if;
  if new.status = 'draft' then
    if new.number_seq is not null or new.number_text is not null then raise exception 'A draft has no number; it is given one when issued' using errcode = '42501'; end if;
    return new;
  end if;
  if new.status = 'void' then
    new.voided_at := coalesce(new.voided_at, now());
    if new.number_seq is not null or new.number_text is not null then raise exception 'A voided draft has no number' using errcode = '42501'; end if;
    return new;
  end if;
  -- issuing: validate, take the number, freeze
  select coalesce(sum(line_cents), 0), count(*) into sub, nlines from centre_invoice_lines where invoice_id = new.id;
  if nlines = 0 then raise exception 'A document needs at least one line before it is issued' using errcode = '42501'; end if;
  select * into t from centre_gst_totals(sub, new.gst_rate_bp, new.gst_inclusive, new.gst_registered);
  if t.net_cents <> new.net_cents or t.gst_cents <> new.gst_cents or t.total_cents <> new.total_cents then
    raise exception 'The totals don''t match the lines (expected net %, GST %, total %)', t.net_cents, t.gst_cents, t.total_cents using errcode = '42501';
  end if;
  if new.total_cents < 0 then raise exception 'A document''s total can''t be negative' using errcode = '42501'; end if;
  if new.kind = 'credit_note' then
    select * into inv from centre_invoices where id = new.credits_invoice_id and org_id = new.org_id;
    if inv.id is null or inv.status <> 'issued' or inv.kind = 'credit_note' then
      raise exception 'A credit note must credit an issued invoice' using errcode = '42501';
    end if;
    if new.reason is null or length(trim(new.reason)) = 0 then raise exception 'A credit note needs a reason' using errcode = '42501'; end if;
    perform pg_advisory_xact_lock(hashtextextended(inv.id::text, 0));
    select coalesce(sum(total_cents), 0) into credited from centre_invoices
     where credits_invoice_id = inv.id and status = 'issued' and id <> new.id;
    if credited + new.total_cents > inv.total_cents then
      raise exception 'Credit notes can''t add up to more than the invoice (invoice %, already credited %, this one %)', inv.total_cents, credited, new.total_cents using errcode = '42501';
    end if;
    if inv.household_id is distinct from new.household_id or inv.student_id is distinct from new.student_id then
      raise exception 'A credit note must be for the same household and student as its invoice' using errcode = '42501';
    end if;
  end if;
  day := coalesce(new.issue_date, (now() at time zone coalesce((select timezone from organisations where id = new.org_id), 'Asia/Singapore'))::date);
  s := org_settings_on(new.org_id, day);
  prefix := coalesce(nullif(trim(s#>>'{profile,invoice_prefix}'), ''), 'INV');
  if new.kind = 'opening' then
    -- an OPENING invoice keeps the number it already had in the centre's old books: it never touches the counter (T33 import)
    new.imported_number := nullif(trim(coalesce(new.imported_number, '')), '');
    if new.imported_number is null then raise exception 'An opening invoice needs the number it already has' using errcode = '42501'; end if;
    if exists (select 1 from centre_invoices x where x.org_id = new.org_id and x.id <> new.id and x.status = 'issued' and lower(x.number_text) = lower(new.imported_number)) then
      raise exception 'Another document already has the number %', new.imported_number using errcode = '23505';
    end if;
    new.number_seq := null;
    new.number_text := new.imported_number;
  else
    new.number_seq := centre_next_number(new.org_id, case when new.kind = 'credit_note' then 'credit_note' else 'invoice' end);   -- (generated columns are not filled yet in a BEFORE trigger)
    new.number_text := case when new.kind = 'credit_note' then 'CN-' else '' end || prefix || '-' || new.number_seq;
  end if;
  new.issue_date := day;
  new.issued_at := now();
  new.issued_by := coalesce(auth.uid(), new.created_by);
  return new;
end $$;


-- ---------------------------------------------------------------------------------------------------
-- 5. deposit helpers (internal)
-- ---------------------------------------------------------------------------------------------------
-- who and when: 'view' = owner or staff with record_payments / view_revenue;  'record' = record_payments;  'owner' = the centre owner.
-- Returns the centre's own "today". Everyone who isn't owner/staff of THIS centre (tutor, parent, solo, stranger, anonymous) gets NOT_FOUND.
create or replace function public.centre_deposit_gate(p_org uuid, p_perm text) returns date
language plpgsql stable security definer set search_path = public as $$
declare tz text; ok boolean;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select o.timezone into tz from organisations o where o.id = p_org and o.kind = 'centre';
  if tz is null or not exists (select 1 from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active' and m.role in ('owner', 'staff')) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  ok := case p_perm when 'member' then true when 'view' then org_can(p_org, 'record_payments') or org_can(p_org, 'view_revenue')
                    when 'owner' then org_can(p_org, 'owner')
                    else org_can(p_org, 'record_payments') end;
  if not ok then
    raise exception 'NOT_ALLOWED: your account can''t % at this centre', case p_perm when 'owner' then 'do that (only the centre owner can)' when 'view' then 'see deposits' else 'record deposits' end using errcode = '42501';
  end if;
  return (now() at time zone tz)::date;
end $$;

-- plain words when the centre's deposit option can't be acted on yet (null = nothing to say)
create or replace function public.centre_deposit_note(p_settings jsonb) returns text
language sql immutable set search_path = public as $$
  select case
    when coalesce(p_settings#>>'{billing,deposit,mode}', 'none') = 'none' then null
    when coalesce(p_settings#>>'{billing,deposit,due}', 'with_first_invoice') <> 'with_first_invoice'
      then 'Deposits invoiced before the first lesson are coming soon. No deposit is raised until the setting says “together with the first lesson invoice”.'
    when p_settings#>>'{billing,deposit,mode}' = 'fixed' and coalesce((p_settings#>>'{billing,one_off_fees,deposit_cents}')::bigint, 0) <= 0
      then 'The deposit is a fixed amount of S$0.00, so none is raised.'
    else null end
$$;

-- the deposits this run would raise (reads the run's temporary tables: call centre_invoice_run_prepare first).
-- NEW  = a student with no deposit row, no lesson on an earlier invoice, and a non-trial lesson in a READY invoice → mode applied to their first month.
-- REUSE = a student whose deposit invoice was discarded as a draft → the SAME frozen amount again.
create or replace function public.centre_deposit_run_candidates(p_org uuid, p_ms date, p_today date)
returns table(d_student_id uuid, d_student_name text, d_household_id uuid, d_unit_key text, d_deposit_id uuid, d_mode text, d_percent_bp int,
              d_first_month_cents bigint, d_amount_cents bigint, d_taxable boolean, d_frozen boolean)
language plpgsql security definer set search_path = public, pg_temp as $$
declare s jsonb := coalesce(org_settings_on(p_org, p_ms), org_settings_on(p_org, p_today)); me date := (p_ms + interval '1 month - 1 day')::date;
  v_mode text; v_due text; v_bp int; v_fix bigint; v_tax boolean;
begin
  if s is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  v_mode := coalesce(s#>>'{billing,deposit,mode}', 'none');
  v_due  := coalesce(s#>>'{billing,deposit,due}', 'with_first_invoice');
  v_bp   := coalesce((s#>>'{billing,deposit,percent_bp}')::int, 0);
  v_fix  := coalesce((s#>>'{billing,one_off_fees,deposit_cents}')::bigint, 0);
  v_tax  := coalesce((s#>>'{billing,deposit,taxable}')::boolean, false);
  return query
  with fm as (                                       -- each student's non-trial lesson fee in an invoice that is READY (before discounts, fees and GST)
    select r.unit_key as ukey, r.student_id as sid, max(r.student_name) as sname, sum(r.qty * r.unit_cents)::bigint as cents
      from _td_run r
      join _td_units u on u.unit_key = r.unit_key and u.status = 'ready'
      join lessons l on l.id = r.lesson_id and l.org_id = p_org
     where r.state = 'line' and r.line_kind = 'lesson' and not coalesce(l.trial, false)
     group by r.unit_key, r.student_id
  )
  select st.id, st.name, st.household_id, fm.ukey, null::uuid,
         case v_mode when 'fixed' then 'fixed' else 'percent_first_month' end,
         case when v_mode = 'percent_first_month' then v_bp end,
         fm.cents,
         case v_mode when 'fixed' then v_fix when 'percent_first_month' then centre_div_round(fm.cents * v_bp, 10000) else 0 end,
         v_tax, false
    from fm join students st on st.id = fm.sid and st.org_id = p_org
   where v_mode in ('fixed', 'percent_first_month') and v_due = 'with_first_invoice'
     and not exists (select 1 from centre_deposits d where d.org_id = p_org and d.student_id = st.id)
     and not exists (select 1 from centre_invoice_lines cl join centre_invoices ci on ci.id = cl.invoice_id and ci.org_id = cl.org_id
                      where cl.org_id = p_org and cl.student_id = st.id and ci.kind in ('lesson', 'opening') and ci.status <> 'void' and ci.period_start <= p_ms)
     and case v_mode when 'fixed' then v_fix when 'percent_first_month' then centre_div_round(fm.cents * v_bp, 10000) else 0 end > 0
  union all
  select st.id, st.name, st.household_id, fm.ukey, d.id, d.mode, d.percent_bp, d.first_month_cents, d.required_cents, d.taxable, true
    from fm join students st on st.id = fm.sid and st.org_id = p_org
    join centre_deposits d on d.org_id = p_org and d.student_id = st.id and d.source = 'invoice_run'
   where d.invoice_id is null or exists (select 1 from centre_invoices i where i.id = d.invoice_id and i.org_id = p_org and i.status = 'void');
end $$;

-- makes ONE deposit draft (internal): the "Refundable deposit" invoice and, for a new deposit, its frozen row. GST only when the deposit is taxable.
create or replace function public.centre_deposit_make_invoice(p_org uuid, p_student uuid, p_deposit uuid, p_amount bigint, p_taxable boolean, p_mode text,
  p_bp int, p_first bigint, p_ms date, p_me date, p_today date) returns uuid
language plpgsql security definer set search_path = public as $$
declare st students; pr jsonb := org_settings_on(p_org, p_today); reg boolean; rate int; inc boolean; g record; inv uuid := gen_random_uuid(); dep uuid := p_deposit;
begin
  select * into st from students where id = p_student and org_id = p_org;
  reg  := coalesce(p_taxable, false) and coalesce((pr#>>'{profile,gst_registered}')::boolean, false);
  rate := case when reg then coalesce((pr#>>'{profile,gst_rate_bp}')::int, 0) else 0 end;
  inc  := reg and coalesce((pr#>>'{profile,gst_inclusive}')::boolean, false);
  select * into g from centre_gst_totals(p_amount, rate, inc, reg);
  insert into centre_invoices(id, org_id, kind, household_id, student_id, period_start, period_end, gst_registered, gst_rate_bp, gst_inclusive, net_cents, gst_cents, total_cents)
  values (inv, p_org, 'deposit', st.household_id, p_student, p_ms, p_me, reg, rate, inc, g.net_cents, g.gst_cents, g.total_cents);
  insert into centre_invoice_lines(org_id, invoice_id, position, student_id, description, qty, unit_cents)
  values (p_org, inv, 1, p_student, 'Refundable deposit', 1, p_amount);
  if dep is null then
    insert into centre_deposits(org_id, student_id, household_id, source, mode, percent_bp, first_month_cents, required_cents, taxable, period_start, invoice_id)
    values (p_org, p_student, st.household_id, 'invoice_run', p_mode, p_bp, p_first, p_amount, coalesce(p_taxable, false), p_ms, inv);
  else
    update centre_deposits set invoice_id = inv where id = dep and org_id = p_org;
  end if;
  return inv;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 6. the invoice run learns about deposits (copies of the S2 functions, each with a small addition; undo restores the originals)
-- ---------------------------------------------------------------------------------------------------
-- preview: adds `deposits` (who would get one, how much, the first month it came from), `deposit_note`, and two totals
create or replace function public.centre_invoice_run_preview(p_org uuid, p_period date) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := centre_invoicing_gate(p_org); ms date := centre_invoice_month(p_period, today); me date := (ms + interval '1 month - 1 day')::date;
  s jsonb := coalesce(org_settings_on(p_org, ms), org_settings_on(p_org, today)); note text; res jsonb; deps jsonb; dcents bigint; dnote text;
begin
  if s is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  note := centre_invoice_model_note(s);
  res := jsonb_build_object('today', today, 'period_start', ms, 'period_end', me, 'model', coalesce(s#>>'{billing,model}', 'postpaid_lessons'),
           'fixed_period', coalesce(s#>>'{billing,fixed_period}', 'month'), 'grouping', coalesce(s#>>'{invoicing,grouping}', 'family'),
           'review_before_sending', coalesce((s#>>'{invoicing,review_before_sending}')::boolean, true),
           'due_days', coalesce((s#>>'{invoicing,due_days}')::int, 7),
           'built', note is null, 'message', note);
  if note is not null then
    return res || jsonb_build_object('ready', '[]'::jsonb, 'held_back', '[]'::jsonb, 'drafts', '[]'::jsonb,
                                     'totals', jsonb_build_object('ready', 0, 'held_back', 0, 'drafts', 0, 'lessons', 0, 'subtotal_cents', 0, 'gst_cents', 0, 'total_cents', 0));
  end if;
  perform centre_invoice_run_prepare(p_org, ms, today);
  select coalesce(jsonb_agg(jsonb_build_object('student_id', c.d_student_id, 'name', c.d_student_name, 'household_id', c.d_household_id, 'key', c.d_unit_key,
           'mode', c.d_mode, 'percent_bp', c.d_percent_bp, 'first_month_cents', c.d_first_month_cents, 'amount_cents', c.d_amount_cents,
           'taxable', c.d_taxable, 'frozen', c.d_frozen) order by c.d_student_name, c.d_student_id), '[]'::jsonb), coalesce(sum(c.d_amount_cents), 0)
    into deps, dcents from centre_deposit_run_candidates(p_org, ms, today) c;
  dnote := centre_deposit_note(s);
  return res || jsonb_build_object('deposits', deps, 'deposit_note', dnote, 'deposit_mode', coalesce(s#>>'{billing,deposit,mode}', 'none'),
    'ready', (select coalesce(jsonb_agg(jsonb_build_object(
        'key', u.unit_key, 'name', u.uname, 'household_id', u.hid, 'student_id', u.ustu, 'lessons', u.n_lessons,
        'subtotal_cents', u.subtotal, 'net_cents', u.net, 'gst_cents', u.gst, 'total_cents', u.total,
        'not_marked', u.n_unmarked, 'no_price', u.n_no_price, 'free_trials', u.n_free,
        'lines', (select jsonb_agg(jsonb_build_object('kind', r.line_kind, 'lesson_id', r.lesson_id, 'student_id', r.student_id, 'student_name', r.student_name,
                                                      'date', r.lesson_date, 'description', r.description, 'qty', r.qty, 'unit_cents', r.unit_cents,
                                                      'line_cents', r.qty * r.unit_cents)
                                       order by r.student_name, r.ord, r.lesson_date, r.start_time, r.lesson_id)
                    from _td_run r where r.unit_key = u.unit_key and r.state = 'line')) order by u.uname, u.unit_key), '[]'::jsonb)
                from _td_units u where u.status = 'ready'),
    'held_back', (select coalesce(jsonb_agg(jsonb_build_object(
        'key', u.unit_key, 'name', u.uname, 'household_id', u.hid, 'student_id', u.ustu, 'not_marked', u.n_unmarked,
        'reasons', (select jsonb_agg(jsonb_build_object('reason', 'charge pending: ' || x.sname, 'student_id', x.sid, 'student_name', x.sname, 'lessons', x.n)
                                    order by x.sname) from (select r.student_name as sname, r.student_id as sid, count(*)::int as n
                                                              from _td_run r where r.unit_key = u.unit_key and r.state = 'pending' group by 1, 2) x),
        'lessons', (select jsonb_agg(jsonb_build_object('lesson_id', r.lesson_id, 'student_name', r.student_name, 'date', r.lesson_date) order by r.lesson_date, r.student_name)
                      from _td_run r where r.unit_key = u.unit_key and r.state = 'pending')) order by u.uname, u.unit_key), '[]'::jsonb)
                from _td_units u where u.status = 'held'),
    'drafts', (select coalesce(jsonb_agg(jsonb_build_object('key', u.unit_key, 'name', u.uname, 'invoice_id', u.draft_id, 'household_id', u.hid, 'student_id', u.ustu,
                                                            'total_cents', (select i.total_cents from centre_invoices i where i.id = u.draft_id), 'new_lessons', u.n_lessons)
                                         order by u.uname, u.unit_key), '[]'::jsonb) from _td_units u where u.status = 'draft'),
    'totals', jsonb_build_object(
        'deposits', jsonb_array_length(deps), 'deposit_cents', dcents,
        'ready',     (select count(*) from _td_units where status = 'ready'),
        'held_back', (select count(*) from _td_units where status = 'held'),
        'drafts',    (select count(*) from _td_units where status = 'draft'),
        'lessons',   (select coalesce(sum(n_lessons), 0) from _td_units where status = 'ready'),
        'not_marked',(select coalesce(sum(n_unmarked), 0) from _td_units),
        'subtotal_cents', (select coalesce(sum(subtotal), 0) from _td_units where status = 'ready'),
        'gst_cents',      (select coalesce(sum(gst), 0) from _td_units where status = 'ready'),
        'total_cents',    (select coalesce(sum(total), 0) from _td_units where status = 'ready')));
end $$;

-- create drafts: after the lesson drafts, one separate 'Refundable deposit' draft per student getting their first deposit (issued straight away when the centre doesn't review)
create or replace function public.centre_invoice_run_create_drafts(p_org uuid, p_period date) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := centre_invoicing_gate(p_org); ms date := centre_invoice_month(p_period, today); me date := (ms + interval '1 month - 1 day')::date;
  s jsonb := coalesce(org_settings_on(p_org, ms), org_settings_on(p_org, today)); note text; review boolean; u record; inv uuid; made jsonb := '[]'::jsonb;
  n_made int := 0; n_issued int := 0; n_held int; n_draft int; n_empty int; iss centre_invoices;
  dep record; dinv uuid; dmade jsonb := '[]'::jsonb; n_dep int := 0; n_dep_issued int := 0;
begin
  if s is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  note := centre_invoice_model_note(s);
  if note is not null then raise exception 'NOT_BUILT: %', note using errcode = 'P0001'; end if;
  review := coalesce((s#>>'{invoicing,review_before_sending}')::boolean, true);
  perform pg_advisory_xact_lock(hashtextextended(p_org::text || ':' || ms::text, 77));      -- two people pressing the button at once: one waits
  perform centre_invoice_run_prepare(p_org, ms, today);
  -- the deposits to raise are decided BEFORE the lesson drafts exist (a student's "first invoice" is judged without the one being made now)
  drop table if exists pg_temp._td_dep;
  create temp table _td_dep on commit drop as select * from centre_deposit_run_candidates(p_org, ms, today);
  for u in select * from _td_units where status = 'ready' order by uname, unit_key loop
    insert into centre_invoices(org_id, kind, household_id, student_id, period_start, period_end, gst_registered, gst_rate_bp, gst_inclusive, net_cents, gst_cents, total_cents)
    values (p_org, 'lesson', u.hid, u.ustu, ms, me, u.gst_reg, u.gst_rate, u.gst_inc, u.net, u.gst, u.total) returning id into inv;
    insert into centre_invoice_lines(org_id, invoice_id, position, lesson_id, student_id, fee_kind, description, qty, unit_cents)
    select p_org, inv, row_number() over (order by r.student_name, r.ord, r.lesson_date, r.start_time, r.lesson_id), r.lesson_id, r.student_id,
           case when r.line_kind in ('registration', 'materials', 'sibling_discount') then r.line_kind end, r.description, r.qty, r.unit_cents
      from _td_run r where r.unit_key = u.unit_key and r.state = 'line';
    n_made := n_made + 1;
    if not review then iss := centre_invoice_issue_draft(inv, today); n_issued := n_issued + 1; end if;
    made := made || jsonb_build_object('id', inv, 'name', u.uname, 'total_cents', u.total);
  end loop;
  -- the refundable deposits: each its own invoice, raised once per student, with the student's first run
  for dep in select * from _td_dep order by d_student_name, d_student_id loop
    dinv := centre_deposit_make_invoice(p_org, dep.d_student_id, dep.d_deposit_id, dep.d_amount_cents, dep.d_taxable, dep.d_mode, dep.d_percent_bp, dep.d_first_month_cents, ms, me, today);
    if not review then iss := centre_invoice_issue_draft(dinv, today); n_dep_issued := n_dep_issued + 1; end if;
    n_dep := n_dep + 1; dmade := dmade || jsonb_build_object('id', dinv, 'name', dep.d_student_name, 'total_cents', dep.d_amount_cents);
  end loop;
  select count(*) into n_held from _td_units where status = 'held';
  select count(*) into n_draft from _td_units where status = 'draft';
  select count(*) into n_empty from _td_units where status = 'empty';
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), 'centre_invoice_run_create', 'centre_invoices', p_org::text || ':' || ms::text, null,
          jsonb_build_object('period_start', ms, 'created', n_made, 'issued_straight_away', n_issued, 'held_back', n_held, 'already_drafted', n_draft, 'deposits', n_dep, 'deposits_issued', n_dep_issued));
  return jsonb_build_object('period_start', ms, 'created', n_made, 'issued', n_issued, 'held_back', n_held, 'already_drafted', n_draft, 'nothing_to_bill', n_empty,
                            'review_before_sending', review, 'invoices', made, 'deposits', n_dep, 'deposits_issued', n_dep_issued, 'deposit_invoices', dmade);
end $$;

-- approve all: the month's deposit drafts are issued with the lesson drafts, each family's lesson invoice first
create or replace function public.centre_invoice_approve_all(p_org uuid, p_period date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := centre_invoicing_gate(p_org); ms date := centre_invoice_month(p_period, today); d record; r centre_invoices; n int := 0; nd int := 0; tot bigint := 0; first_no text; last_no text;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_org::text || ':' || ms::text, 77));
  for d in select i.id from centre_invoices i left join households h on h.id = i.household_id and h.org_id = i.org_id left join students st on st.id = i.student_id and st.org_id = i.org_id
            where i.org_id = p_org and i.kind in ('lesson', 'deposit') and i.status = 'draft' and i.period_start = ms
            order by coalesce(h.name, st.name), (i.kind <> 'lesson'), st.name, i.id for update of i loop
    r := centre_invoice_issue_draft(d.id, today);
    n := n + 1; tot := tot + r.total_cents; if r.kind = 'deposit' then nd := nd + 1; end if; first_no := coalesce(first_no, r.number_text); last_no := r.number_text;
  end loop;
  if n = 0 then raise exception 'NOTHING_TO_APPROVE: there are no drafts for that month' using errcode = 'P0001'; end if;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), 'centre_invoice_approve_all', 'centre_invoices', p_org::text || ':' || ms::text, null,
          jsonb_build_object('period_start', ms, 'issued', n, 'first', first_no, 'last', last_no, 'total_cents', tot, 'deposits', nd));
  return jsonb_build_object('issued', n, 'first_number', first_no, 'last_number', last_no, 'total_cents', tot, 'deposits', nd);
end $$;

-- list: deposit invoices are listed with the month's invoices, marked kind = 'deposit'
create or replace function public.centre_invoice_list(p_org uuid, p_period date default null, p_status text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := centre_invoicing_gate(p_org); ms date := case when p_period is null then null else centre_invoice_month(p_period, today) end;
begin
  if p_status is not null and p_status not in ('draft', 'issued', 'void') then raise exception 'BAD_VALUE: unknown status' using errcode = 'P0001'; end if;
  return jsonb_build_object('today', today, 'rows', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', q.id, 'kind', q.kind, 'status', q.status, 'number', q.number_text, 'name', q.nm, 'household_id', q.household_id, 'student_id', q.student_id,
      'period_start', q.period_start, 'period_end', q.period_end, 'issue_date', q.issue_date, 'due_date', q.due_date,
      'net_cents', q.net_cents, 'gst_cents', q.gst_cents, 'total_cents', q.total_cents, 'lines', q.nl) order by q.ord, q.nm, q.id), '[]'::jsonb)
    from (select i.*, coalesce(case when i.kind = 'deposit' or (i.student_id is not null and i.household_id is null) then st.name end, h.name, st.name) as nm,
                 case i.status when 'draft' then 0 when 'issued' then 1 else 2 end as ord,
                 (select count(*) from centre_invoice_lines l where l.invoice_id = i.id)::int as nl
            from centre_invoices i left join households h on h.id = i.household_id and h.org_id = i.org_id left join students st on st.id = i.student_id and st.org_id = i.org_id
           where i.org_id = p_org and i.kind in ('lesson', 'deposit') and (ms is null or i.period_start = ms) and (p_status is null or i.status = p_status)
           order by case i.status when 'draft' then 0 when 'issued' then 1 else 2 end, coalesce(h.name, st.name), i.id limit 1000) q));
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 7. WHAT THE DEPOSITS SCREEN READS (explicit columns; no table access needed)
-- ---------------------------------------------------------------------------------------------------
-- one row per student with a deposit: required, held, short, waived, state and the invoice. p_student narrows it to one student.
--   state: draft (invoice not approved) · unpaid · part_paid · held · waived
create or replace function public.centre_deposit_status(p_org uuid, p_student uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := centre_deposit_gate(p_org, 'view'); res jsonb;
begin
  with led as (
    select l.student_id, coalesce(sum(l.cents) filter (where l.kind <> 'waived'), 0)::bigint as held,
           coalesce(sum(l.cents) filter (where l.kind = 'waived'), 0)::bigint as waived,
           coalesce(sum(l.cents) filter (where l.kind <> 'waived' and l.taxable), 0)::bigint as taxable_held
      from centre_deposit_ledger l where l.org_id = p_org group by l.student_id
  ), q as (
    select d.id as deposit_id, d.student_id, st.name, h.name as household_name, d.household_id, d.source, d.mode, d.percent_bp, d.first_month_cents,
           d.required_cents, coalesce(i.total_cents, d.required_cents) as due, d.taxable, d.period_start, i.id as invoice_id, i.number_text, i.status as istatus, i.issue_date, i.due_date,
           coalesce((select sum(c.total_cents) from centre_invoices c where c.credits_invoice_id = i.id and c.status = 'issued'), 0)::bigint as credited,
           coalesce(led.held, 0) as held, coalesce(led.waived, 0) as waived, coalesce(led.taxable_held, 0) as taxable_held
      from centre_deposits d
      join students st on st.id = d.student_id and st.org_id = d.org_id
      left join households h on h.id = d.household_id and h.org_id = d.org_id
      left join centre_invoices i on i.id = d.invoice_id and i.org_id = d.org_id
      left join led on led.student_id = d.student_id
     where d.org_id = p_org and (p_student is null or d.student_id = p_student)
  ), r as (
    select q.*, case when q.waived > 0 then 'waived' when q.istatus = 'draft' then 'draft' when q.held >= q.due - q.credited then 'held'
                     when q.held > 0 then 'part_paid' when q.istatus = 'void' then 'draft' else 'unpaid' end as state,
           case when q.waived > 0 or q.istatus in ('draft', 'void') then 0 else greatest(q.due - q.credited - q.held, 0) end as short
      from q
  )
  select jsonb_build_object('today', today,
    'rows', coalesce((select jsonb_agg(jsonb_build_object('deposit_id', r.deposit_id, 'student_id', r.student_id, 'name', r.name, 'household_id', r.household_id,
              'household_name', r.household_name, 'source', r.source, 'mode', r.mode, 'percent_bp', r.percent_bp, 'first_month_cents', r.first_month_cents,
              'required_cents', r.required_cents, 'due_cents', r.due, 'held_cents', r.held, 'waived_cents', r.waived, 'short_cents', r.short, 'state', r.state, 'taxable', r.taxable,
              'period_start', r.period_start, 'invoice_id', r.invoice_id, 'invoice_number', r.number_text, 'invoice_status', r.istatus, 'due_date', r.due_date)
              order by r.name, r.student_id) from r), '[]'::jsonb),
    'totals', jsonb_build_object('held_cents', coalesce((select sum(held) from r), 0), 'taxable_held_cents', coalesce((select sum(taxable_held) from r), 0),
              'students_holding', (select count(*) from r where held > 0), 'required_cents', coalesce((select sum(required_cents) from r where state <> 'waived'), 0),
              'short_cents', coalesce((select sum(short) from r), 0), 'deposits', (select count(*) from r)))
    into res;
  return res;
end $$;

-- the "Deposits held" report: money held for families, per student and in total. NEVER part of a revenue figure.
create or replace function public.centre_deposits_held(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := centre_deposit_gate(p_org, 'view'); res jsonb;
begin
  select jsonb_build_object('today', today,
    'total_held_cents', coalesce(sum(x.held), 0), 'taxable_held_cents', coalesce(sum(x.taxable_held), 0), 'students_holding', count(*),
    'rows', coalesce(jsonb_agg(jsonb_build_object('student_id', x.student_id, 'name', x.name, 'household_name', x.hname, 'held_cents', x.held,
              'required_cents', x.required, 'since', x.since) order by x.name, x.student_id), '[]'::jsonb))
    into res
    from (select l.student_id, st.name, h.name as hname, d.required_cents as required, min(l.entry_date) as since,
                 sum(l.cents) filter (where l.kind <> 'waived') as held, coalesce(sum(l.cents) filter (where l.kind <> 'waived' and l.taxable), 0) as taxable_held
            from centre_deposit_ledger l
            join centre_deposits d on d.id = l.deposit_id and d.org_id = l.org_id
            join students st on st.id = l.student_id and st.org_id = l.org_id
            left join households h on h.id = d.household_id and h.org_id = d.org_id
           where l.org_id = p_org group by l.student_id, st.name, h.name, d.required_cents
          having coalesce(sum(l.cents) filter (where l.kind <> 'waived'), 0) > 0) x;
  return res;
end $$;

-- one student's ledger, oldest first, with the balance after each row
create or replace function public.centre_deposit_ledger_get(p_org uuid, p_student uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := centre_deposit_gate(p_org, 'view'); nm text;
begin
  select st.name into nm from students st where st.id = p_student and st.org_id = p_org;
  if nm is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  return jsonb_build_object('today', today, 'student_id', p_student, 'name', nm,
    'status', (centre_deposit_status(p_org, p_student)->'rows'->0),
    'entries', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'date', e.entry_date, 'kind', e.kind, 'cents', e.cents, 'taxable', e.taxable,
                'invoice_number', e.number_text, 'reason', e.reason, 'balance_cents', e.bal) order by e.entry_date, e.created_at, e.id)
              from (select l.*, i.number_text, sum(l.cents) filter (where l.kind <> 'waived') over (order by l.entry_date, l.created_at, l.id) as bal
                      from centre_deposit_ledger l left join centre_invoices i on i.id = l.invoice_id and i.org_id = l.org_id
                     where l.org_id = p_org and l.student_id = p_student) e), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 8. WAIVE a deposit (a reason is always needed; who may is the centre's choice: billing.deposit.waived_by)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_deposit_waive(p_student uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare org uuid; today date; s jsonb; wb text; d centre_deposits; inv centre_invoices; b record; why text := nullif(trim(coalesce(p_reason, '')), ''); waived bigint; action text; cn jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select st.org_id into org from students st where st.id = p_student;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := centre_deposit_gate(org, 'member');                     -- any owner/staff passes the door; the waived_by rule below decides
  s := org_settings_on(org, today);
  wb := coalesce(s#>>'{billing,deposit,waived_by}', 'owner');
  if wb = 'nobody' then raise exception 'NOT_ALLOWED: this centre doesn''t allow deposits to be waived (see Centre settings)' using errcode = '42501'; end if;
  if wb = 'owner' and not org_can(org, 'owner') then raise exception 'NOT_ALLOWED: only the centre owner can waive a deposit' using errcode = '42501'; end if;
  if wb = 'issue_invoices' and not org_can(org, 'issue_invoices') then raise exception 'NOT_ALLOWED: only the owner or staff who issue invoices can waive a deposit' using errcode = '42501'; end if;
  if why is null then raise exception 'REASON_REQUIRED: say why this deposit is being waived' using errcode = 'P0001'; end if;
  if length(why) > 300 then raise exception 'TOO_LONG: keep the reason under 300 characters' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_student::text, 6));
  select * into d from centre_deposits where org_id = org and student_id = p_student;
  if d.id is null then raise exception 'NO_DEPOSIT: this student has no deposit to waive' using errcode = 'P0001'; end if;
  if exists (select 1 from centre_deposit_ledger where org_id = org and student_id = p_student and kind = 'waived') then
    raise exception 'ALREADY_WAIVED: this deposit has already been waived' using errcode = 'P0001'; end if;
  if d.source <> 'invoice_run' or d.invoice_id is null then
    raise exception 'NOT_ALLOWED: this deposit was collected before TutorDeck, so there is nothing left to waive' using errcode = '42501'; end if;
  select * into inv from centre_invoices where id = d.invoice_id and org_id = org for update;
  if inv.status = 'draft' then
    update centre_invoices set status = 'void', void_reason = 'Deposit waived: ' || why where id = inv.id;       -- never had a number, so no gap
    waived := d.required_cents; action := 'draft_discarded';
  elsif inv.status = 'issued' then
    select * into b from centre_balance_rows(org, array[inv.id]);
    if b.balance_cents <= 0 then raise exception 'NOT_ALLOWED: the deposit is already paid in full, so there is nothing to waive (it can be refunded later)' using errcode = '42501'; end if;
    cn := centre_issue_credit_note(inv.id, b.balance_cents, 'Deposit waived: ' || why);
    waived := b.balance_cents; action := 'credit_note';
  else
    raise exception 'NOT_ALLOWED: that deposit invoice was discarded, so there is nothing to waive' using errcode = '42501';
  end if;
  insert into centre_deposit_ledger(org_id, student_id, deposit_id, kind, cents, taxable, invoice_id, entry_date, reason)
  values (org, p_student, d.id, 'waived', waived, d.taxable, inv.id, today, why);
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (org, auth.uid(), 'centre_deposit_waive', 'centre_deposits', d.id::text, null, jsonb_build_object('waived_cents', waived, 'how', action, 'waived_by_rule', wb));
  return jsonb_build_object('student_id', p_student, 'waived_cents', waived, 'how', action, 'credit_note', cn);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 9. OPENING BALANCE: a deposit collected before TutorDeck (owner only; no invoice, no number, no revenue)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_deposit_opening_balance(p_student uuid, p_amount_cents bigint, p_date date, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare org uuid; today date; st students; did uuid; note text := nullif(trim(coalesce(p_note, '')), '');
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into st from students where id = p_student;
  if st.id is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  org := st.org_id;
  today := centre_deposit_gate(org, 'owner');
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'BAD_VALUE: the amount must be more than S$0.00' using errcode = 'P0001'; end if;
  if p_amount_cents > 100000000 then raise exception 'BAD_VALUE: that amount is too large to be right (over S$1,000,000)' using errcode = 'P0001'; end if;
  if p_date is null then raise exception 'BAD_VALUE: say the date the deposit was collected' using errcode = 'P0001'; end if;
  if p_date > today then raise exception 'BAD_VALUE: the date can''t be in the future' using errcode = 'P0001'; end if;
  if p_date < today - 3650 then raise exception 'BAD_VALUE: that date is too far back (over 10 years)' using errcode = 'P0001'; end if;
  if length(coalesce(note, '')) > 300 then raise exception 'TOO_LONG: keep the note under 300 characters' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_student::text, 6));
  if exists (select 1 from centre_deposits where org_id = org and student_id = p_student) then
    raise exception 'ALREADY_HAS_DEPOSIT: this student already has a deposit record' using errcode = 'P0001'; end if;
  insert into centre_deposits(org_id, student_id, household_id, source, mode, required_cents, taxable, period_start)
  values (org, p_student, st.household_id, 'opening_balance', 'opening', p_amount_cents, false, date_trunc('month', p_date)::date) returning id into did;
  insert into centre_deposit_ledger(org_id, student_id, deposit_id, kind, cents, taxable, entry_date, reason)
  values (org, p_student, did, 'opening_balance', p_amount_cents, false, p_date, coalesce(note, 'Collected before TutorDeck'));
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (org, auth.uid(), 'centre_deposit_opening_balance', 'centre_deposits', did::text, null, jsonb_build_object('amount_cents', p_amount_cents, 'date', p_date));
  return jsonb_build_object('deposit_id', did, 'student_id', p_student, 'held_cents', p_amount_cents);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 10. revenue totals that leave deposits OUT (replaces the S1 function; same keys, plus the deposit figures reported separately)
--     A deposit invoice, a credit note against one, and the cash that paid a deposit are not revenue. GST on a TAXABLE deposit is still counted,
--     because that is tax collected.
-- ---------------------------------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------------------------------
-- 11. function access
-- ---------------------------------------------------------------------------------------------------
revoke all on function public.centre_deposit_guard() from public, anon, authenticated;
revoke all on function public.centre_deposit_ledger_guard() from public, anon, authenticated;
revoke all on function public.centre_deposit_alloc_hook() from public, anon, authenticated;
revoke all on function public.centre_deposit_gate(uuid, text) from public, anon, authenticated;
revoke all on function public.centre_deposit_run_candidates(uuid, date, date) from public, anon, authenticated;
revoke all on function public.centre_deposit_make_invoice(uuid, uuid, uuid, bigint, boolean, text, int, bigint, date, date, date) from public, anon, authenticated;
revoke all on function public.centre_deposit_note(jsonb) from public, anon;
revoke all on function public.centre_deposit_status(uuid, uuid) from public, anon;
revoke all on function public.centre_deposits_held(uuid) from public, anon;
revoke all on function public.centre_deposit_ledger_get(uuid, uuid) from public, anon;
revoke all on function public.centre_deposit_waive(uuid, text) from public, anon;
revoke all on function public.centre_deposit_opening_balance(uuid, bigint, date, text) from public, anon;
revoke all on function public.centre_invoice_guard() from public, anon, authenticated;
revoke all on function public.centre_revenue_totals(uuid, date, date) from public, anon;
revoke all on function public.centre_invoice_run_preview(uuid, date) from public, anon;
revoke all on function public.centre_invoice_run_create_drafts(uuid, date) from public, anon;
revoke all on function public.centre_invoice_approve_all(uuid, date) from public, anon;
revoke all on function public.centre_invoice_list(uuid, date, text) from public, anon;
grant execute on function public.centre_deposit_note(jsonb), public.centre_deposit_status(uuid, uuid), public.centre_deposits_held(uuid), public.centre_deposit_ledger_get(uuid, uuid),
  public.centre_deposit_waive(uuid, text), public.centre_deposit_opening_balance(uuid, bigint, date, text), public.centre_revenue_totals(uuid, date, date),
  public.centre_invoice_run_preview(uuid, date), public.centre_invoice_run_create_drafts(uuid, date), public.centre_invoice_approve_all(uuid, date),
  public.centre_invoice_list(uuid, date, text) to authenticated, service_role;
