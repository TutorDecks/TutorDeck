-- =====================================================================================================
-- T4 step S7 — centre tutor pay: effective-dated rates, the monthly pay list, "held until the parent pays", adjustments   undo: migration_centre_tutor_pay_down.sql
-- =====================================================================================================
-- Run order everywhere: org_foundation → billing → attendance → tutor_access → org_delete → function_lockdown → org_separation →
--   staff_home → staff_students → staff_attendance → staff_charges → staff_trials → staff_timetable → money_settings →
--   centre_money → centre_invoice_run → centre_payments → centre_deposits → centre_refunds → centre_late_fees → centre_credit_undo → centre_tutor_pay.
-- Needs money_settings (S0: the tutor_pay options), centre_money (S1), centre_invoice_run (S2: invoice lines), centre_payments (S3: allocations),
-- tutor_access (lessons.taught_by, session_id). Run on the DEV project first. LIVE only when the owner says ship: this migration adds three tables and
-- functions; it reads and changes no existing row. Safe to run twice.
--
-- WHO SEES WHAT (owner's rule): rates, pay and the pay list are for the centre OWNER and STAFF who have the permission `run_tutor_pay`. A TUTOR
--   NEVER sees a rate, a fee or any pay, not even their own: tutors have no table access and there is NO tutor-facing pay function (the plan's
--   tutor_my_pay / tutor_my_rates are deliberately NOT built; the setting tutor_pay.tutor_visibility is marked "soon"). Parents, switched-off staff,
--   staff without the permission, solo owners, strangers and anonymous callers get NOT_FOUND / NOT_ALLOWED. The three tables can be READ by the
--   same people and have NO write policy: browsers write nothing here, only the functions below do.
--
-- THE TABLES (all append-only: a change is a NEW row, nothing is edited or deleted; only deleting the whole organisation removes them)
--   tutor_pay_rates        one row per rate change. Scope: the tutor's DEFAULT, or one STUDENT, or one LEVEL. In force for a lesson = the newest row with
--                          effective_from on or before the LESSON DATE (money rules follow what was in force when the lesson happened), looking first at
--                          the student's rows, then the level's, then the tutor's default. method 'inherit' on a student/level scope = "back to the next
--                          level down"; 'none' = deliberately unpaid. A lesson with no rate at all shows as "no rate" and is NOT paid until staff set one.
--   tutor_pay_adjustments  a bonus (+) or deduction (−) in cents with a REASON, dated; a mistake is corrected by another adjustment.
--   tutor_pay_payments     "the centre paid this tutor S$x for the pay period ending d" (manual list: method, date, reference). A mistake is a REVERSAL row.
--                          Once a period is recorded as paid for a tutor, nothing dated inside it can be added for that tutor (no new rate effective on
--                          or before it, no adjustment dated in it): past pay is never rewritten. A late correction goes into the next period.
--
-- THE RATE METHODS (tutor_pay.rate_model only PRE-FILLS the form; every tutor can differ)
--   per_lesson          a fixed amount for each lesson taught.
--   per_hour            a fixed amount per hour × the lesson's minutes ÷ 60, half up to the cent.
--   per_student_lesson  classes only (refused when the centre runs one-to-one only): a fixed amount for each student in the class, counted per
--                       tutor_pay.group_count (attended = students marked attended · enrolled = also students who were absent or cancelled late,
--                       if tutor_pay.cancelled_lessons would pay for that cancelled lesson).
--   monthly_fixed       a fixed amount for each pay period, whatever was taught (default scope only). Never held back by a parent's payment: it does
--                       not belong to any family's invoice. It counts for the whole period even if the rate starts part-way through it.
--   percent_of_fee      percent_bp of what the family was BILLED for that lesson: tutor_pay.percent_base = billed_after_discounts (the lesson's invoice
--                       line plus its share of the student's sibling discount, before GST) or list_price (the line before discounts). GST, late fees and
--                       deposits are never in the base. A cancelled lesson's billed amount is its compensation, so a free cancellation gives 0 and an
--                       uncharged trial gives 0. Half up to the cent.
-- CLASSES (lessons of one class share session_id): per_lesson and per_hour pay the tutor ONCE for the class, not once per student: the class amount
--   (the average of the students' rates, half up) is shared between the students taught, remainder on the first, so each share can wait for its own family.
--   A student who was absent or cancelled earns nothing extra when the class was taught. A class where nobody was taught follows the cancelled rule once.
-- CANCELLED LESSONS (tutor_pay.cancelled_lessons, for the fixed methods): pay_if_charged = the usual rate only when the family is charged
--   (compensation above 0) · pay_rate = the usual rate · pay_nothing = 0. A cancelled lesson whose charge has not been typed yet (compensation empty)
--   is "waiting for the charge" and is not counted until it is. percent_of_fee needs the charge in every case.
-- WHEN IT BECOMES PAYABLE (tutor_pay.payable_when, read as of the LESSON'S date)
--   taught       the day it was marked taught (the lesson date, or the day attendance was marked if later).
--   parent_paid  only when the invoice line it sits on is paid for. Money received on the invoice (payments by their received date, minus reversals,
--                plus credit notes by their issue date) fills the invoice's lines OLDEST LINE FIRST, in proportion to its total (so GST is handled).
--                tutor_pay.part_payments: after_full (default) = the lesson is released only when its line is fully covered · pro_rata = released
--                in proportion to what is paid. A lesson that has no invoice line yet but WILL have one ("not invoiced") is held; one that never will
--                (an uncharged trial, a free cancellation) has no family to wait for and is released at once.
--   A held lesson shows as HELD and rolls into whichever pay period the parent's payment arrives in.
-- THE PAY LIST (one month, one tutor per row; period end = tutor_pay.cycle.cutoff_day, 31 = month end)
--   due = carried over + released in this period + monthly fixed + adjustments in this period
--   carried over = everything released and adjusted before the period − everything recorded as paid for earlier periods, so a payment that came in
--   late, a reversed payment or a part payment is never lost: it appears as "carried over". Figures are worked "as of" a date from the dated events
--   (lesson dates, marks, payments by received date) so a past period's figures do not move when later events arrive; they show up in a later one.
--   A credit note issued after the parent paid is NOT clawed back by itself: staff enter a negative adjustment with a reason if they want one.
-- MODES (tutor_pay.mode): off = nothing here works · report = the lessons-taught report and the rates screen (no money list) · full = everything.
--   Adjustments also need tutor_pay.adjustments on. bank_file payout stays "soon": this is the manual list only.
--
-- AUDIT: every row is copied to the audit log by the S1 trigger (free text — reasons, references, notes — replaced by "[redacted]"); each function adds a
--   summary row with amounts and counts only (never names). Exporting the pay list is logged too.
-- =====================================================================================================

-- ---------------------------------------------------------------------------------------------------
-- 1. tables
-- ---------------------------------------------------------------------------------------------------
create table if not exists public.tutor_pay_rates (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organisations(id) on delete cascade,
  membership_id uuid,                                    -- the tutor; becomes null if the person is removed (the row stays: it is the centre's record)
  student_id    uuid,                                    -- set = an override for this student only
  level         text,                                    -- set = an override for this level only (never together with student_id)
  method        text not null check (method in ('per_lesson', 'per_hour', 'per_student_lesson', 'monthly_fixed', 'percent_of_fee', 'none', 'inherit')),
  amount_cents  bigint check (amount_cents between 0 and 100000000),
  percent_bp    int check (percent_bp between 0 and 10000),
  effective_from date not null,
  reason        text not null check (length(trim(reason)) between 1 and 300),
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  unique (id, org_id),
  foreign key (membership_id, org_id) references public.memberships(id, org_id) on delete set null (membership_id),
  foreign key (student_id, org_id)    references public.students(id, org_id),
  check (student_id is null or level is null),
  check (level is null or length(trim(level)) between 1 and 60),
  check ((method in ('per_lesson', 'per_hour', 'per_student_lesson', 'monthly_fixed') and amount_cents is not null and percent_bp is null)
      or (method = 'percent_of_fee' and percent_bp is not null and amount_cents is null)
      or (method in ('none', 'inherit') and amount_cents is null and percent_bp is null)),
  check (method <> 'monthly_fixed' or (student_id is null and level is null)),
  check (method <> 'inherit' or student_id is not null or level is not null)
);
create index if not exists tutor_pay_rates_lookup on public.tutor_pay_rates(org_id, membership_id, effective_from desc);

create table if not exists public.tutor_pay_adjustments (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organisations(id) on delete cascade,
  membership_id uuid,
  kind          text not null check (kind in ('bonus', 'deduction')),
  amount_cents  bigint not null check (amount_cents <> 0 and amount_cents between -100000000 and 100000000),
  effective_on  date not null,
  reason        text not null check (length(trim(reason)) between 1 and 300),
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  unique (id, org_id),
  foreign key (membership_id, org_id) references public.memberships(id, org_id) on delete set null (membership_id),
  check ((kind = 'bonus') = (amount_cents > 0))
);
create index if not exists tutor_pay_adjustments_lookup on public.tutor_pay_adjustments(org_id, membership_id, effective_on);

create table if not exists public.tutor_pay_payments (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organisations(id) on delete cascade,
  kind          text not null default 'payment' check (kind in ('payment', 'reversal')),
  reverses_payment_id uuid,
  membership_id uuid,
  tutor_name    text not null,                           -- a copy of the name at the time (the centre's record survives the person leaving)
  period_from   date not null,
  period_to     date not null,
  amount_cents  bigint not null check (amount_cents > 0 and amount_cents <= 100000000),
  paid_on       date not null,
  method        text not null check (method in ('paynow', 'bank', 'cash', 'cheque', 'other')),
  reference     text,
  note          text,
  recorded_by   uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  unique (id, org_id),
  foreign key (membership_id, org_id) references public.memberships(id, org_id) on delete set null (membership_id),
  foreign key (reverses_payment_id, org_id) references public.tutor_pay_payments(id, org_id),
  check (period_to >= period_from),
  check ((kind = 'reversal') = (reverses_payment_id is not null))
);
create unique index if not exists tutor_pay_payments_one_reversal on public.tutor_pay_payments(reverses_payment_id) where reverses_payment_id is not null;
create index if not exists tutor_pay_payments_lookup on public.tutor_pay_payments(org_id, membership_id, period_to);

-- ---------------------------------------------------------------------------------------------------
-- 2. guards: centres only, append-only, past pay is never rewritten
-- ---------------------------------------------------------------------------------------------------
-- append-only (the only change allowed is the database setting a removed person's id to null; deleting the whole organisation is allowed)
create or replace function public.tutor_pay_appendonly() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    if centre_money_deleting(old.org_id) then return old; end if;
    raise exception '% is append-only (add a correcting row instead)', tg_table_name using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and old.membership_id is not null and new.membership_id is null
     and (to_jsonb(new) - 'membership_id') = (to_jsonb(old) - 'membership_id') then
    return new;
  end if;
  raise exception '% is append-only (add a correcting row instead)', tg_table_name using errcode = '42501';
end $$;

-- The last day of the newest period recorded as paid (and not reversed) for a tutor; null if none.
create or replace function public.tutor_pay_frozen_to(p_org uuid, p_membership uuid) returns date
language sql stable security definer set search_path = public as $$
  select max(p.period_to) from tutor_pay_payments p
   where p.org_id = p_org and p.membership_id = p_membership and p.kind = 'payment'
     and not exists (select 1 from tutor_pay_payments r where r.reverses_payment_id = p.id)
$$;

create or replace function public.tutor_pay_freeze_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare f date; d date; m uuid;
begin
  m := new.membership_id; if m is null then return new; end if;
  d := coalesce((to_jsonb(new) ->> 'effective_from')::date, (to_jsonb(new) ->> 'effective_on')::date);
  f := tutor_pay_frozen_to(new.org_id, m);
  if f is not null and d <= f then
    raise exception 'PERIOD_PAID: pay for the period ending % is already recorded for this tutor, so nothing can be dated on or before then; use a later date', f using errcode = 'P0001';
  end if;
  return new;
end $$;

-- a payment: a reversal must repeat what it cancels; the tutor must be someone of this centre
create or replace function public.tutor_pay_payment_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare p record;
begin
  if new.kind = 'reversal' then
    select * into p from tutor_pay_payments where id = new.reverses_payment_id and org_id = new.org_id;
    if p.id is null or p.kind <> 'payment' then raise exception 'A reversal must cancel a payment of this centre' using errcode = '42501'; end if;
    if new.amount_cents <> p.amount_cents or new.membership_id is distinct from p.membership_id or new.period_to <> p.period_to or new.period_from <> p.period_from then
      raise exception 'A reversal must repeat the payment it cancels' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['tutor_pay_rates', 'tutor_pay_adjustments', 'tutor_pay_payments'] loop
    execute format('drop trigger if exists centre_money_org_guard on public.%I', t);
    execute format('create trigger centre_money_org_guard before insert on public.%I for each row execute function public.centre_money_org_guard()', t);
    execute format('drop trigger if exists audit_row on public.%I', t);
    execute format('create trigger audit_row after insert or update or delete on public.%I for each row execute function public.centre_money_audit()', t);
    execute format('drop trigger if exists tutor_pay_appendonly on public.%I', t);
    execute format('create trigger tutor_pay_appendonly before update or delete on public.%I for each row execute function public.tutor_pay_appendonly()', t);
  end loop;
end $$;
drop trigger if exists tutor_pay_freeze_guard on public.tutor_pay_rates;
create trigger tutor_pay_freeze_guard before insert on public.tutor_pay_rates for each row execute function public.tutor_pay_freeze_guard();
drop trigger if exists tutor_pay_freeze_guard on public.tutor_pay_adjustments;
create trigger tutor_pay_freeze_guard before insert on public.tutor_pay_adjustments for each row execute function public.tutor_pay_freeze_guard();
drop trigger if exists tutor_pay_payment_guard on public.tutor_pay_payments;
create trigger tutor_pay_payment_guard before insert on public.tutor_pay_payments for each row execute function public.tutor_pay_payment_guard();

-- row-level security: readable by the owner and staff with run_tutor_pay, in centres only; NO write policy
alter table public.tutor_pay_rates enable row level security;
alter table public.tutor_pay_adjustments enable row level security;
alter table public.tutor_pay_payments enable row level security;
drop policy if exists pay_read on public.tutor_pay_rates;
create policy pay_read on public.tutor_pay_rates for select using (org_can(org_id, 'run_tutor_pay') and not org_is_solo(org_id));
drop policy if exists pay_read on public.tutor_pay_adjustments;
create policy pay_read on public.tutor_pay_adjustments for select using (org_can(org_id, 'run_tutor_pay') and not org_is_solo(org_id));
drop policy if exists pay_read on public.tutor_pay_payments;
create policy pay_read on public.tutor_pay_payments for select using (org_can(org_id, 'run_tutor_pay') and not org_is_solo(org_id));
revoke all on public.tutor_pay_rates, public.tutor_pay_adjustments, public.tutor_pay_payments from anon, authenticated;
grant select on public.tutor_pay_rates, public.tutor_pay_adjustments, public.tutor_pay_payments to authenticated;

-- ---------------------------------------------------------------------------------------------------
-- 3. internal helpers
-- ---------------------------------------------------------------------------------------------------
-- the gate every screen function starts with. p_need: 'rates' / 'report' (mode report or full) · 'full' (mode full). Returns the centre's own today.
create or replace function public.centre_tutor_pay_gate(p_org uuid, p_need text) returns date
language plpgsql stable security definer set search_path = public as $$
declare tz text; mode text; today date;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select o.timezone into tz from organisations o where o.id = p_org and o.kind = 'centre';
  if tz is null or not exists (select 1 from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active' and m.role in ('owner', 'staff')) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if not org_can(p_org, 'run_tutor_pay') then
    raise exception 'NOT_ALLOWED: your account can''t see or change tutor pay at this centre' using errcode = '42501';
  end if;
  today := (now() at time zone tz)::date;
  mode := coalesce(org_settings_on(p_org, today) #>> '{tutor_pay,mode}', 'off');
  if mode = 'off' then raise exception 'PAY_OFF: tutor pay is switched off in Centre settings' using errcode = 'P0001'; end if;
  if p_need = 'full' and mode <> 'full' then
    raise exception 'PAY_REPORT_ONLY: this centre uses the lessons-taught report only; switch Tutor pay to "Full pay calculation" in Centre settings to work out pay' using errcode = 'P0001';
  end if;
  return today;
end $$;

-- the pay period that ends in a calendar month: the day after the previous period's end up to the cut-off day (31 = the month's last day)
create or replace function public.centre_tutor_period(p_month date, p_cutoff int) returns table(p_from date, p_to date)
language plpgsql immutable set search_path = public as $$
declare m0 date := date_trunc('month', p_month)::date; c int := case when p_cutoff between 1 and 31 then p_cutoff else 31 end; pm date; dm int; dp int;
begin
  dm := extract(day from (m0 + interval '1 month' - interval '1 day'))::int;
  pm := (m0 - interval '1 month')::date;
  dp := extract(day from (m0 - interval '1 day'))::int;
  p_to := m0 + (least(c, dm) - 1);
  p_from := pm + least(c, dp);
  return next;
end $$;

-- the rate in force for one lesson: the student's newest row, else the level's, else the tutor's default; 'inherit' means "look at the next level down".
-- No row at all = no rows returned (the lesson has no rate).
create or replace function public.centre_tutor_rate_for(p_org uuid, p_membership uuid, p_student uuid, p_level text, p_day date)
returns table(method text, amount_cents bigint, percent_bp int, rate_id uuid, scope text)
language plpgsql stable security definer set search_path = public as $$
declare r tutor_pay_rates;
begin
  select * into r from tutor_pay_rates x where x.org_id = p_org and x.membership_id = p_membership and x.student_id = p_student and x.effective_from <= p_day
   order by x.effective_from desc, x.created_at desc, x.id desc limit 1;
  if found and r.method <> 'inherit' then return query select r.method, r.amount_cents, r.percent_bp, r.id, 'student'::text; return; end if;
  if p_level is not null then
    select * into r from tutor_pay_rates x where x.org_id = p_org and x.membership_id = p_membership and x.student_id is null and lower(x.level) = lower(p_level)
       and x.effective_from <= p_day order by x.effective_from desc, x.created_at desc, x.id desc limit 1;
    if found and r.method <> 'inherit' then return query select r.method, r.amount_cents, r.percent_bp, r.id, 'level'::text; return; end if;
  end if;
  select * into r from tutor_pay_rates x where x.org_id = p_org and x.membership_id = p_membership and x.student_id is null and x.level is null and x.effective_from <= p_day
   order by x.effective_from desc, x.created_at desc, x.id desc limit 1;
  if found then return query select r.method, r.amount_cents, r.percent_bp, r.id, 'default'::text; end if;
end $$;

-- fixed monthly pay: one amount per pay period, from the month of the tutor's first rate to the period ending in p_to's month.
-- Returns (before, in_period): the sum for periods that ended before p_from, and the one that ends at p_to.
create or replace function public.centre_tutor_monthly(p_org uuid, p_membership uuid, p_from date, p_to date, p_cutoff int)
returns table(before_cents bigint, period_cents bigint)
language plpgsql stable security definer set search_path = public as $$
declare first_m date; m date; pe date; r record; b bigint := 0; i bigint := 0;
begin
  select date_trunc('month', min(effective_from))::date into first_m from tutor_pay_rates where org_id = p_org and membership_id = p_membership and method = 'monthly_fixed';
  if first_m is not null then
    m := first_m;
    while m <= date_trunc('month', p_to)::date loop
      select pp.p_to into pe from centre_tutor_period(m, p_cutoff) pp;
      select * into r from centre_tutor_rate_for(p_org, p_membership, null, null, pe);
      if r.method = 'monthly_fixed' then
        if pe < p_from then b := b + r.amount_cents; elsif pe = p_to then i := i + r.amount_cents; end if;
      end if;
      m := (m + interval '1 month')::date;
    end loop;
  end if;
  before_cents := b; period_cents := i; return next;
end $$;

-- THE CALCULATION. One row per lesson a tutor taught or was cancelled with, up to p_to, with what the tutor earns for it and what has been RELEASED
-- (made payable) as of the day before p_from and as of p_to. INTERNAL: only the screen functions below call it (they check who is asking).
create or replace function public.centre_tutor_pay_rows(p_org uuid, p_from date, p_to date, p_membership uuid default null)
returns table(lesson_id uuid, membership_id uuid, student_id uuid, lesson_date date, minutes int, lesson_status text, is_trial boolean, session_key uuid,
              method text, rate_scope text, earn_cents bigint, earn_on date, base_cents bigint, invoice_id uuid, state text, released_before bigint, released_to bigint)
language plpgsql stable security definer set search_path = public as $$
declare tz text; bef date := p_from - 1;
begin
  select o.timezone into tz from organisations o where o.id = p_org;
  return query
  with b as (
    select l.id as lid, l.taught_by as mid, l.student_id as sid, l.lesson_date as ld, l.start_time as st, l.status as stt, l.attendance as att,
           coalesce(l.trial, false) as trial, l.compensation_cents as comp, nullif(trim(l.level), '') as lvl, coalesce(l.session_id, l.id) as sk,
           greatest(l.lesson_date, coalesce((l.attendance_marked_at at time zone coalesce(tz, 'Asia/Singapore'))::date, l.lesson_date)) as eo,
           greatest((extract(epoch from (l.end_time - l.start_time)) / 60)::int, 0) as mins,
           lesson_price_cents(l.amount, l.rate, l.start_time, l.end_time) as price
      from lessons l
     where l.org_id = p_org and l.taught_by is not null and l.status in ('done', 'cancelled') and l.lesson_date <= p_to
       and (p_membership is null or l.taught_by = p_membership)
  ), sd as materialized (
    select x.d, org_settings_on(p_org, x.d) as s from (select distinct ld as d from b) x
  ), c as (
    select b.*,
           coalesce(sd.s #>> '{tutor_pay,payable_when}', 'parent_paid') as pw,
           coalesce(sd.s #>> '{tutor_pay,part_payments}', 'after_full') as pp,
           coalesce(sd.s #>> '{tutor_pay,cancelled_lessons}', 'pay_if_charged') as cr,
           coalesce(sd.s #>> '{tutor_pay,percent_base}', 'billed_after_discounts') as pb,
           coalesce(sd.s #>> '{tutor_pay,group_count}', 'attended') as gc,
           coalesce((sd.s #>> '{billing,trials,charged}')::boolean, false) as trials_charged
      from b join sd on sd.d = b.ld where b.eo <= p_to
  ), cand as (                                              -- every rate row that could apply to a lesson, keeping the NEWEST (by start date) of each kind: student, level, default
    select distinct on (x.clid, x.tier) x.*
      from (select c.lid as clid, case when r.student_id is not null then 1 when r.level is not null then 2 else 3 end as tier,
                   r.method as cm, r.amount_cents as ca, r.percent_bp as cp, r.effective_from as cf, r.created_at as cc, r.id as cid
              from c join tutor_pay_rates r on r.org_id = p_org and r.membership_id = c.mid and r.effective_from <= c.ld
               and (r.student_id = c.sid or (r.student_id is null and r.level is not null and lower(r.level) = lower(c.lvl)) or (r.student_id is null and r.level is null))) x
     order by x.clid, x.tier, x.cf desc, x.cc desc, x.cid desc
  ), pick as (                                              -- the first kind whose newest row is not "back to the usual rate"
    select distinct on (cand.clid) cand.clid, cand.tier, cand.cm, cand.ca, cand.cp from cand where cand.cm <> 'inherit' order by cand.clid, cand.tier
  ), u as (                                                 -- the rate in force on the lesson date, and the fixed amount it gives
    select c.*, p.cm as rm, p.ca as ra, p.cp as rp, case p.tier when 1 then 'student' when 2 then 'level' when 3 then 'default' end as rsc,
           case p.cm when 'per_lesson' then p.ca when 'per_hour' then centre_div_round(p.ca * c.mins, 60) when 'per_student_lesson' then p.ca else 0 end as unit
      from c left join pick p on p.clid = c.lid
  ), il as (                                                -- the issued lesson invoices these lessons sit on, with every line, in order
    select ln.id as line_id, ln.invoice_id as inv, ln.position as pos, ln.lesson_id as llid, ln.student_id as lsid, ln.fee_kind as fk, ln.line_cents as lc
      from centre_invoice_lines ln join centre_invoices ci on ci.id = ln.invoice_id and ci.org_id = ln.org_id
     where ln.org_id = p_org and ci.status = 'issued' and ci.kind = 'lesson'
       and ln.invoice_id in (select ln2.invoice_id from centre_invoice_lines ln2 where ln2.org_id = p_org and ln2.lesson_id in (select lid from c))
  ), il2 as (
    select il.*,
           (sum(lc) filter (where fk = 'sibling_discount') over (partition by inv, lsid))::bigint as dsum,
           (sum(lc) filter (where llid is not null) over (partition by inv, lsid))::bigint as lsum,
           (sum(lc) filter (where llid is not null) over (partition by inv, lsid order by pos, line_id))::bigint as lcum
      from il
  ), il3 as (                                               -- each lesson line's share of its student's sibling discount (telescoping, so the shares add up exactly)
    select il2.*, case when llid is not null and coalesce(lsum, 0) > 0 and dsum is not null
                       then centre_div_round(dsum * lcum, lsum) - centre_div_round(dsum * (lcum - lc), lsum) else 0 end as share
      from il2
  ), il4 as (
    select il3.*, case when fk = 'sibling_discount' and coalesce(lsum, 0) > 0 then 0 else lc + share end as net
      from il3
  ), il5 as (
    select il4.*, (sum(net) over (partition by inv order by pos, line_id))::bigint as cumnet, (sum(net) over (partition by inv))::bigint as subtotal
      from il4
  ), fund as (                                              -- money received on each invoice (payments by received date, plus credit notes by issue date) as of two days
    select ci.id as inv, ci.total_cents as tot,
           (coalesce((select sum(a.cents) from centre_payment_allocations a join centre_payments p on p.id = a.payment_id and p.org_id = a.org_id
                      where a.invoice_id = ci.id and p.received_on <= p_to), 0)
         + coalesce((select sum(n.total_cents) from centre_invoices n where n.credits_invoice_id = ci.id and n.status = 'issued' and n.issue_date <= p_to), 0))::bigint as f_to,
           (coalesce((select sum(a.cents) from centre_payment_allocations a join centre_payments p on p.id = a.payment_id and p.org_id = a.org_id
                      where a.invoice_id = ci.id and p.received_on <= bef), 0)
         + coalesce((select sum(n.total_cents) from centre_invoices n where n.credits_invoice_id = ci.id and n.status = 'issued' and n.issue_date <= bef), 0))::bigint as f_bef
      from centre_invoices ci where ci.id in (select inv from il)
  ), j as (
    select u.*, i5.inv as inv, i5.lc as lcents, i5.share as dshare, i5.cumnet, i5.subtotal, f.tot, f.f_to, f.f_bef,
           (i5.inv is null) as noline,
           -- will this lesson have an invoice line once it is invoiced?
           case when u.trial and not u.trials_charged then false
                when u.stt = 'done' then coalesce(u.price, 0) > 0
                else coalesce(u.comp, 0) > 0 end as expects_line,
           -- cancelled with the charge not typed yet (only matters when the rule needs the charge)
           (u.stt = 'cancelled' and u.comp is null and u.att in ('absent', 'cancelled_early', 'late_cancelled')) as charge_pending,
           (u.stt = 'cancelled' and (u.cr = 'pay_rate' or (u.cr = 'pay_if_charged' and coalesce(u.comp, 0) > 0))) as canc_paid
      from u left join il5 i5 on i5.llid = u.lid
           left join fund f on f.inv = i5.inv
  ), k as (
    select j.*,
           count(*) filter (where stt = 'done') over (partition by sk, mid) as n_done,
           (case when rm = 'percent_of_fee' then coalesce(case pb when 'list_price' then lcents else lcents + dshare end, 0) end) as pbase
      from j
  ), pm as (                                                -- members of a class's shared pot (per_lesson / per_hour only)
    select k.*, (rm in ('per_lesson', 'per_hour') and (stt = 'done' or (n_done = 0 and canc_paid and not (charge_pending and cr = 'pay_if_charged')))) as inpot
      from k
  ), pot as (
    select pm.*,
           count(*) filter (where inpot) over (partition by sk, mid) as n_pot,
           (sum(unit) filter (where inpot) over (partition by sk, mid))::bigint as s_pot,
           row_number() over (partition by sk, mid, inpot order by ld, st, lid) as rn_pot
      from pm
  ), e as (
    select pot.*,
      case
        when rm is null then null
        when rm in ('none', 'monthly_fixed', 'inherit') then 0
        when rm = 'percent_of_fee' then
          case when stt = 'cancelled' and charge_pending then null
               when noline and expects_line then null
               else centre_div_round(coalesce(pbase, 0) * rp, 10000) end
        when rm = 'per_student_lesson' then
          case when stt = 'done' then unit
               when stt = 'cancelled' and gc = 'enrolled' and canc_paid then unit
               when stt = 'cancelled' and gc = 'enrolled' and charge_pending and cr = 'pay_if_charged' then null
               else 0 end
        else   -- per_lesson / per_hour
          case when stt = 'cancelled' and n_done = 0 and charge_pending and cr = 'pay_if_charged' then null
               when not inpot then 0
               else (centre_div_round(s_pot, n_pot::bigint) / n_pot::bigint) + case when rn_pot = 1 then centre_div_round(s_pot, n_pot::bigint) - (centre_div_round(s_pot, n_pot::bigint) / n_pot::bigint) * n_pot::bigint else 0 end end
      end as earn
      from pot
  ), rel as (
    select e.*,
      -- released as of p_to
      case when earn is null or eo > p_to then 0
           when pw = 'taught' then earn
           when noline then case when expects_line then 0 else earn end
           when pp = 'pro_rata' then case when tot > 0 then centre_div_round(earn * least(f_to, tot), tot) else earn end
           else case when tot = 0 or subtotal = 0 or f_to * subtotal >= cumnet * tot then earn else 0 end end as r_to,
      -- released as of the day before the period
      case when earn is null or eo > bef then 0
           when pw = 'taught' then earn
           when noline then case when expects_line then 0 else earn end
           when pp = 'pro_rata' then case when tot > 0 then centre_div_round(earn * least(f_bef, tot), tot) else earn end
           else case when tot = 0 or subtotal = 0 or f_bef * subtotal >= cumnet * tot then earn else 0 end end as r_bef
      from e
  )
  select rel.lid, rel.mid, rel.sid, rel.ld, rel.mins, rel.stt, rel.trial, rel.sk, rel.rm, rel.rsc, rel.earn, rel.eo,
         case when rel.rm = 'percent_of_fee' then rel.pbase end, rel.inv,
         case when rel.rm is null then 'no_rate'
              when rel.rm in ('none', 'inherit') then 'unpaid'
              when rel.rm = 'monthly_fixed' then 'monthly'
              when rel.earn is null then case when rel.charge_pending then 'waiting_charge' else 'waiting_invoice' end
              when rel.earn = 0 then 'zero'
              when rel.r_to >= rel.earn then 'payable'
              when rel.r_to > 0 then 'part'
              else 'held' end,
         rel.r_bef::bigint, rel.r_to::bigint
    from rel;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 4. RATES: list and set
-- ---------------------------------------------------------------------------------------------------
-- Everything the rates screen needs: the centre's people who teach, each with their full rate history (newest first) and which rows are in force today.
create or replace function public.centre_tutor_rate_list(p_org uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := centre_tutor_pay_gate(p_org, 'rates'); s jsonb := org_settings_on(p_org, today); r jsonb;
begin
  select jsonb_build_object(
    'today', today, 'mode', coalesce(s #>> '{tutor_pay,mode}', 'off'), 'default_method', coalesce(s #>> '{tutor_pay,rate_model}', 'per_hour'),
    'class_type', coalesce(s #>> '{lessons,class_type}', 'both'),
    'tutors', coalesce((select jsonb_agg(jsonb_build_object(
        'membership_id', m.id, 'name', m.display_name, 'role', m.role, 'employment_type', m.employment_type, 'status', m.status,
        'frozen_to', tutor_pay_frozen_to(p_org, m.id),
        'rates', coalesce((select jsonb_agg(jsonb_build_object(
            'id', x.id, 'student_id', x.student_id, 'student_name', st.name, 'level', x.level, 'method', x.method, 'amount_cents', x.amount_cents,
            'percent_bp', x.percent_bp, 'effective_from', x.effective_from, 'reason', x.reason, 'created_at', x.created_at,
            'in_force', x.id = (select y.id from tutor_pay_rates y where y.org_id = p_org and y.membership_id = m.id
                                  and y.student_id is not distinct from x.student_id and lower(coalesce(y.level, '')) = lower(coalesce(x.level, ''))
                                  and y.effective_from <= today order by y.effective_from desc, y.created_at desc, y.id desc limit 1))
            order by x.student_id is not null, x.level is not null, x.effective_from desc, x.created_at desc)
          from tutor_pay_rates x left join students st on st.id = x.student_id and st.org_id = x.org_id
         where x.org_id = p_org and x.membership_id = m.id), '[]'::jsonb))
        order by (m.role = 'tutor') desc, m.display_name)
      from memberships m where m.org_id = p_org and m.status <> 'disabled' and m.role in ('tutor', 'staff', 'owner')
        and (m.role = 'tutor' or exists (select 1 from lessons l where l.org_id = p_org and l.taught_by = m.id)
             or exists (select 1 from tutor_pay_rates x where x.org_id = p_org and x.membership_id = m.id))), '[]'::jsonb),
    'students', coalesce((select jsonb_agg(jsonb_build_object('id', st.id, 'name', st.name) order by st.name) from students st where st.org_id = p_org
                           and (st.end_date is null or st.end_date >= today)), '[]'::jsonb),
    'levels', coalesce((select jsonb_agg(distinct lv order by lv) from (select nullif(trim(l.level), '') lv from lessons l where l.org_id = p_org
                          union select nullif(trim(x.level), '') from tutor_pay_rates x where x.org_id = p_org) q where lv is not null), '[]'::jsonb)
  ) into r;
  return r;
end $$;

-- Add a rate (a new row; nothing is edited). p_student / p_level: leave both null for the tutor's default.
create or replace function public.centre_tutor_rate_set(p_org uuid, p_membership uuid, p_student uuid, p_level text, p_method text,
  p_amount_cents bigint, p_percent_bp int, p_effective_from date, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := centre_tutor_pay_gate(p_org, 'rates'); s jsonb := org_settings_on(p_org, today); m memberships; lv text := nullif(trim(coalesce(p_level, '')), '');
        why text := nullif(trim(coalesce(p_reason, '')), ''); nid uuid := gen_random_uuid();
begin
  select * into m from memberships where id = p_membership and org_id = p_org and status <> 'disabled' and role in ('tutor', 'staff', 'owner');
  if m.id is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_method is null or p_method not in ('per_lesson', 'per_hour', 'per_student_lesson', 'monthly_fixed', 'percent_of_fee', 'none', 'inherit') then
    raise exception 'BAD_RATE: pick how this tutor is paid' using errcode = 'P0001'; end if;
  if p_student is not null and lv is not null then raise exception 'BAD_RATE: a rate is for one student or one level, not both' using errcode = 'P0001'; end if;
  if p_student is not null and not exists (select 1 from students st where st.id = p_student and st.org_id = p_org) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if lv is not null and length(lv) > 60 then raise exception 'BAD_RATE: the level name is too long' using errcode = 'P0001'; end if;
  if p_method = 'monthly_fixed' and (p_student is not null or lv is not null) then raise exception 'BAD_RATE: a fixed monthly amount is for the tutor, not one student or level' using errcode = 'P0001'; end if;
  if p_method = 'inherit' and p_student is null and lv is null then raise exception 'BAD_RATE: "back to the tutor''s usual rate" is only for a student or level' using errcode = 'P0001'; end if;
  if p_method = 'per_student_lesson' and coalesce(s #>> '{lessons,class_type}', 'both') = 'one_to_one' then
    raise exception 'BAD_RATE: "per student per lesson" is for centres that run group classes' using errcode = 'P0001'; end if;
  if p_method in ('per_lesson', 'per_hour', 'per_student_lesson', 'monthly_fixed') then
    if p_amount_cents is null or p_amount_cents < 0 or p_amount_cents > 100000000 or p_percent_bp is not null then raise exception 'BAD_RATE: enter the amount as dollars and cents (0 to 1,000,000)' using errcode = 'P0001'; end if;
  elsif p_method = 'percent_of_fee' then
    if p_percent_bp is null or p_percent_bp < 0 or p_percent_bp > 10000 or p_amount_cents is not null then raise exception 'BAD_RATE: the percentage must be between 0%% and 100%%' using errcode = 'P0001'; end if;
  elsif p_amount_cents is not null or p_percent_bp is not null then raise exception 'BAD_RATE: this choice has no amount' using errcode = 'P0001'; end if;
  if p_effective_from is null then raise exception 'BAD_RATE: choose the date the rate starts' using errcode = 'P0001'; end if;
  if p_effective_from < date '2000-01-01' or p_effective_from > today + 366 then raise exception 'BAD_RATE: choose a start date within the next year' using errcode = 'P0001'; end if;
  if why is null then raise exception 'REASON_REQUIRED: say why (for example "Starting rate" or "Annual review")' using errcode = 'P0001'; end if;
  if length(why) > 300 then raise exception 'TOO_LONG: keep the reason under 300 characters' using errcode = 'P0001'; end if;
  insert into tutor_pay_rates(id, org_id, membership_id, student_id, level, method, amount_cents, percent_bp, effective_from, reason)
  values (nid, p_org, p_membership, p_student, lv, p_method, p_amount_cents, p_percent_bp, p_effective_from, why);
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), 'centre_tutor_rate_set', 'tutor_pay_rates', nid::text, null,
          jsonb_build_object('method', p_method, 'amount_cents', p_amount_cents, 'percent_bp', p_percent_bp, 'effective_from', p_effective_from,
                             'scope', case when p_student is not null then 'student' when lv is not null then 'level' else 'default' end));
  return jsonb_build_object('id', nid, 'effective_from', p_effective_from, 'method', p_method);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 5. THE PAY LIST
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_tutor_pay_list(p_org uuid, p_month date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := centre_tutor_pay_gate(p_org, 'full'); s jsonb := org_settings_on(p_org, today); cut int := coalesce((s #>> '{tutor_pay,cycle,cutoff_day}')::int, 31);
        pf date; pt date; r jsonb; unassigned int;
begin
  select x.p_from, x.p_to into pf, pt from centre_tutor_period(coalesce(p_month, today), cut) x;
  select count(*) into unassigned from lessons l where l.org_id = p_org and l.taught_by is null and l.status = 'done' and l.lesson_date between pf and pt;
  with rows as (select * from centre_tutor_pay_rows(p_org, pf, pt)),
  rg as (
    select x.membership_id as mid, sum(x.released_before) as rel_before, sum(x.released_to - x.released_before) as rel_in,
           coalesce(sum(x.earn_cents - x.released_to) filter (where x.earn_cents is not null and x.earn_on <= pt), 0) as held,
           count(*) filter (where x.earn_on between pf and pt) as lessons,
           coalesce(sum(x.minutes) filter (where x.earn_on between pf and pt and x.lesson_status = 'done'), 0) as mins,
           count(*) filter (where x.state = 'waiting_invoice') as w_inv, count(*) filter (where x.state = 'waiting_charge') as w_chg,
           count(*) filter (where x.state = 'no_rate' and x.earn_on <= pt) as no_rate, count(*) filter (where x.state in ('held', 'part')) as n_held
      from rows x group by x.membership_id
  ), who as (
    select m.id as mid, m.display_name as nm, m.employment_type as et, m.status as st from memberships m
     where m.org_id = p_org and m.role in ('tutor', 'staff', 'owner')
       and (m.status <> 'disabled' or m.id in (select mid from rg) or m.id in (select membership_id from tutor_pay_payments where org_id = p_org))
       and (m.role = 'tutor' or m.id in (select mid from rg) or exists (select 1 from tutor_pay_rates x where x.org_id = p_org and x.membership_id = m.id))
  ), agg as (
    select w.mid, w.nm, w.et, w.st,
      coalesce(g.rel_before, 0) as rel_before, coalesce(g.rel_in, 0) as rel_in, coalesce(g.held, 0) as held, coalesce(g.lessons, 0) as lessons, coalesce(g.mins, 0) as mins,
      coalesce(g.w_inv, 0) as w_inv, coalesce(g.w_chg, 0) as w_chg, coalesce(g.no_rate, 0) as no_rate, coalesce(g.n_held, 0) as n_held,
      mo.before_cents as mo_before, mo.period_cents as mo_in,
      coalesce((select sum(a.amount_cents) from tutor_pay_adjustments a where a.org_id = p_org and a.membership_id = w.mid and a.effective_on < pf), 0) as adj_before,
      coalesce((select sum(a.amount_cents) from tutor_pay_adjustments a where a.org_id = p_org and a.membership_id = w.mid and a.effective_on between pf and pt), 0) as adj_in,
      coalesce((select sum(case when p.kind = 'payment' then p.amount_cents else -p.amount_cents end) from tutor_pay_payments p
                 where p.org_id = p_org and p.membership_id = w.mid and p.period_to < pf), 0) as paid_before,
      coalesce((select sum(case when p.kind = 'payment' then p.amount_cents else -p.amount_cents end) from tutor_pay_payments p
                 where p.org_id = p_org and p.membership_id = w.mid and p.period_to = pt), 0) as paid_now
      from who w left join rg g on g.mid = w.mid cross join lateral centre_tutor_monthly(p_org, w.mid, pf, pt, cut) mo
  ), fin as (
    select agg.*, (rel_before + mo_before + adj_before - paid_before) as carry,
           (rel_before + mo_before + adj_before - paid_before) + rel_in + mo_in + adj_in as due from agg
  )
  select jsonb_build_object(
    'period_from', pf, 'period_to', pt, 'month', date_trunc('month', pt)::date, 'cutoff_day', cut, 'pay_day', coalesce((s #>> '{tutor_pay,cycle,pay_day}')::int, 7),
    'payable_when', coalesce(s #>> '{tutor_pay,payable_when}', 'parent_paid'), 'adjustments_on', coalesce((s #>> '{tutor_pay,adjustments}')::boolean, false),
    'unassigned_lessons', unassigned, 'today', today,
    'tutors', coalesce(jsonb_agg(jsonb_build_object(
        'membership_id', f.mid, 'name', f.nm, 'employment_type', f.et, 'status', f.st, 'lessons', f.lessons, 'minutes', f.mins,
        'carry_cents', f.carry, 'released_cents', f.rel_in, 'monthly_cents', f.mo_in, 'adjustments_cents', f.adj_in, 'due_cents', f.due,
        'paid_cents', f.paid_now, 'outstanding_cents', f.due - f.paid_now, 'held_cents', f.held, 'held_lessons', f.n_held,
        'waiting_invoice', f.w_inv, 'waiting_charge', f.w_chg, 'no_rate', f.no_rate, 'frozen_to', tutor_pay_frozen_to(p_org, f.mid),
        'pay_state', case when f.due - f.paid_now <= 0 and f.paid_now > 0 then 'paid' when f.paid_now > 0 then 'part_paid'
                          when f.due <= 0 then 'nothing_due' else 'unpaid' end) order by f.nm), '[]'::jsonb),
    'totals', jsonb_build_object('due_cents', coalesce(sum(greatest(f.due, 0)), 0), 'paid_cents', coalesce(sum(f.paid_now), 0),
                                 'outstanding_cents', coalesce(sum(greatest(f.due - f.paid_now, 0)), 0), 'held_cents', coalesce(sum(f.held), 0))
  ) into r from fin f;
  return r;
end $$;

-- One tutor's lines for the period: lessons counted in it (by the day they became countable), lessons still held from earlier, adjustments and payments.
create or replace function public.centre_tutor_pay_detail(p_org uuid, p_membership uuid, p_month date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := centre_tutor_pay_gate(p_org, 'full'); s jsonb := org_settings_on(p_org, today); cut int := coalesce((s #>> '{tutor_pay,cycle,cutoff_day}')::int, 31);
        pf date; pt date; r jsonb; m memberships;
begin
  select * into m from memberships where id = p_membership and org_id = p_org and role in ('tutor', 'staff', 'owner');
  if m.id is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select x.p_from, x.p_to into pf, pt from centre_tutor_period(coalesce(p_month, today), cut) x;
  select jsonb_build_object(
    'membership_id', m.id, 'name', m.display_name, 'period_from', pf, 'period_to', pt,
    'lines', coalesce((select jsonb_agg(jsonb_build_object(
        'lesson_id', x.lesson_id, 'date', x.lesson_date, 'student', st.name, 'minutes', x.minutes, 'lesson_status', x.lesson_status, 'trial', x.is_trial,
        'method', x.method, 'scope', x.rate_scope, 'earn_cents', x.earn_cents, 'base_cents', x.base_cents, 'state', x.state,
        'released_cents', x.released_to - x.released_before, 'held_cents', case when x.earn_cents is null then null else x.earn_cents - x.released_to end,
        'in_period', x.earn_on between pf and pt) order by x.lesson_date, x.lesson_id)
      from centre_tutor_pay_rows(p_org, pf, pt, p_membership) x left join students st on st.id = x.student_id and st.org_id = p_org
     where (x.earn_on between pf and pt or (x.released_to - x.released_before) <> 0
            or (x.earn_on <= pt and x.state in ('held', 'part', 'waiting_invoice', 'waiting_charge', 'no_rate')))), '[]'::jsonb),
    'adjustments', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'kind', a.kind, 'amount_cents', a.amount_cents, 'effective_on', a.effective_on, 'reason', a.reason) order by a.effective_on, a.created_at)
        from tutor_pay_adjustments a where a.org_id = p_org and a.membership_id = p_membership and a.effective_on between pf and pt), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'kind', p.kind, 'amount_cents', p.amount_cents, 'paid_on', p.paid_on, 'method', p.method,
                                                              'reference', p.reference, 'reversed', exists (select 1 from tutor_pay_payments v where v.reverses_payment_id = p.id)) order by p.paid_on, p.created_at)
        from tutor_pay_payments p where p.org_id = p_org and p.membership_id = p_membership and p.period_to = pt), '[]'::jsonb)
  ) into r;
  return r;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 6. ADJUSTMENTS and RECORDING PAYMENTS
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_tutor_pay_adjust(p_org uuid, p_membership uuid, p_amount_cents bigint, p_on date, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := centre_tutor_pay_gate(p_org, 'full'); s jsonb := org_settings_on(p_org, today); why text := nullif(trim(coalesce(p_reason, '')), ''); nid uuid := gen_random_uuid(); d date := coalesce(p_on, today);
begin
  if not coalesce((s #>> '{tutor_pay,adjustments}')::boolean, false) then
    raise exception 'ADJUSTMENTS_OFF: bonuses and deductions are switched off in Centre settings' using errcode = 'P0001'; end if;
  if not exists (select 1 from memberships m where m.id = p_membership and m.org_id = p_org and m.role in ('tutor', 'staff', 'owner') and m.status <> 'disabled') then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_amount_cents is null or p_amount_cents = 0 or abs(p_amount_cents) > 100000000 then raise exception 'BAD_AMOUNT: enter an amount (plus for a bonus, minus for a deduction)' using errcode = 'P0001'; end if;
  if why is null then raise exception 'REASON_REQUIRED: say why this bonus or deduction is being made' using errcode = 'P0001'; end if;
  if length(why) > 300 then raise exception 'TOO_LONG: keep the reason under 300 characters' using errcode = 'P0001'; end if;
  if d < today - 400 or d > today + 62 then raise exception 'BAD_DATE: choose a date within the last year or the next two months' using errcode = 'P0001'; end if;
  insert into tutor_pay_adjustments(id, org_id, membership_id, kind, amount_cents, effective_on, reason)
  values (nid, p_org, p_membership, case when p_amount_cents > 0 then 'bonus' else 'deduction' end, p_amount_cents, d, why);
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), 'centre_tutor_pay_adjust', 'tutor_pay_adjustments', nid::text, null, jsonb_build_object('amount_cents', p_amount_cents, 'effective_on', d));
  return jsonb_build_object('id', nid, 'kind', case when p_amount_cents > 0 then 'bonus' else 'deduction' end, 'amount_cents', p_amount_cents, 'effective_on', d);
end $$;

-- "the centre paid this tutor" for the period of p_month. Never more than what is still outstanding for that period.
create or replace function public.centre_tutor_pay_record(p_org uuid, p_membership uuid, p_month date, p_amount_cents bigint, p_paid_on date,
  p_method text, p_reference text default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := centre_tutor_pay_gate(p_org, 'full'); s jsonb := org_settings_on(p_org, today); cut int := coalesce((s #>> '{tutor_pay,cycle,cutoff_day}')::int, 31);
        pf date; pt date; m memberships; lst jsonb; t jsonb; out_c bigint; nid uuid := gen_random_uuid();
begin
  select * into m from memberships where id = p_membership and org_id = p_org and role in ('tutor', 'staff', 'owner');
  if m.id is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_method is null or p_method not in ('paynow', 'bank', 'cash', 'cheque', 'other') then raise exception 'BAD_METHOD: pick how you paid' using errcode = 'P0001'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'BAD_AMOUNT: enter the amount paid' using errcode = 'P0001'; end if;
  if p_paid_on is null or p_paid_on > today or p_paid_on < today - 400 then raise exception 'BAD_DATE: choose the day you paid (not in the future)' using errcode = 'P0001'; end if;
  if length(coalesce(p_reference, '')) > 100 or length(coalesce(p_note, '')) > 300 then raise exception 'TOO_LONG: shorten the reference or note' using errcode = 'P0001'; end if;
  if coalesce(p_reference, '') ~ '[0-9]{8,}' or coalesce(p_note, '') ~ '[0-9]{8,}' then
    raise exception 'BAD_REFERENCE: don''t type a whole bank or PayNow number (it is kept in the record); the last 4 digits are enough' using errcode = 'P0001'; end if;
  select x.p_from, x.p_to into pf, pt from centre_tutor_period(coalesce(p_month, today), cut) x;
  perform pg_advisory_xact_lock(hashtextextended(p_membership::text, 21));
  lst := centre_tutor_pay_list(p_org, pt);
  select e into t from jsonb_array_elements(lst->'tutors') e where (e->>'membership_id')::uuid = p_membership;
  out_c := coalesce((t->>'outstanding_cents')::bigint, 0);
  if p_amount_cents > out_c then
    raise exception 'TOO_MUCH: only % is still to pay for this period', centre_fmt_money(greatest(out_c, 0)) using errcode = 'P0001'; end if;
  insert into tutor_pay_payments(id, org_id, membership_id, tutor_name, period_from, period_to, amount_cents, paid_on, method, reference, note)
  values (nid, p_org, p_membership, m.display_name, pf, pt, p_amount_cents, p_paid_on, p_method, nullif(trim(coalesce(p_reference, '')), ''), nullif(trim(coalesce(p_note, '')), ''));
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), 'centre_tutor_pay_record', 'tutor_pay_payments', nid::text, null,
          jsonb_build_object('amount_cents', p_amount_cents, 'period_to', pt, 'method', p_method, 'paid_on', p_paid_on));
  return jsonb_build_object('id', nid, 'amount_cents', p_amount_cents, 'period_from', pf, 'period_to', pt, 'outstanding_cents', out_c - p_amount_cents);
end $$;

-- a mistake in a recorded payment: a REVERSAL row (the original stays). The period is open again if nothing else is recorded for it.
create or replace function public.centre_tutor_pay_reverse(p_payment uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare org uuid; today date; p tutor_pay_payments; why text := nullif(trim(coalesce(p_reason, '')), ''); nid uuid := gen_random_uuid();
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select x.org_id into org from tutor_pay_payments x where x.id = p_payment;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := centre_tutor_pay_gate(org, 'full');
  perform pg_advisory_xact_lock(hashtextextended(p_payment::text, 22));
  select * into p from tutor_pay_payments where id = p_payment and org_id = org;
  if p.kind <> 'payment' then raise exception 'NOT_ALLOWED: that is already a reversal' using errcode = '42501'; end if;
  if exists (select 1 from tutor_pay_payments r where r.reverses_payment_id = p.id) then
    return jsonb_build_object('id', p.id, 'already', true); end if;
  if why is null then raise exception 'REASON_REQUIRED: say why this payment is being reversed' using errcode = 'P0001'; end if;
  if length(why) > 300 then raise exception 'TOO_LONG: keep the reason under 300 characters' using errcode = 'P0001'; end if;
  insert into tutor_pay_payments(id, org_id, kind, reverses_payment_id, membership_id, tutor_name, period_from, period_to, amount_cents, paid_on, method, note)
  values (nid, org, 'reversal', p.id, p.membership_id, p.tutor_name, p.period_from, p.period_to, p.amount_cents, greatest(today, p.paid_on), p.method, why);
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (org, auth.uid(), 'centre_tutor_pay_reverse', 'tutor_pay_payments', nid::text, null, jsonb_build_object('amount_cents', p.amount_cents, 'period_to', p.period_to));
  return jsonb_build_object('id', nid, 'already', false, 'amount_cents', p.amount_cents);
end $$;

-- writes the "pay list exported" line of the audit log (counts and totals only, never names or bank details)
create or replace function public.centre_tutor_pay_export_log(p_org uuid, p_month date, p_rows int, p_total_cents bigint) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := centre_tutor_pay_gate(p_org, 'full');
begin
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), 'centre_tutor_pay_export', 'tutor_pay_payments', coalesce(p_org::text, '') || ':' || coalesce(date_trunc('month', p_month)::date::text, today::text), null,
          jsonb_build_object('month', date_trunc('month', coalesce(p_month, today))::date, 'rows', coalesce(p_rows, 0), 'total_cents', coalesce(p_total_cents, 0)));
  return jsonb_build_object('logged', true);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 7. THE LESSONS-TAUGHT REPORT (mode report or full): counts and hours per tutor, NO money
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_tutor_taught_report(p_org uuid, p_month date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := centre_tutor_pay_gate(p_org, 'report'); m0 date := date_trunc('month', coalesce(p_month, today))::date; m1 date := (date_trunc('month', coalesce(p_month, today)) + interval '1 month - 1 day')::date; r jsonb; unassigned int;
begin
  select count(*) into unassigned from lessons l where l.org_id = p_org and l.taught_by is null and l.status = 'done' and l.lesson_date between m0 and m1;
  select jsonb_build_object('month', m0, 'unassigned_lessons', unassigned, 'tutors', coalesce(jsonb_agg(jsonb_build_object(
      'membership_id', q.mid, 'name', q.nm, 'employment_type', q.et, 'lessons', q.n, 'minutes', q.mins, 'students', q.stu, 'cancelled', q.canc, 'trials', q.trials) order by q.nm), '[]'::jsonb))
    into r
    from (select m.id as mid, m.display_name as nm, m.employment_type as et,
                 count(*) filter (where l.status = 'done') as n,
                 coalesce(sum(greatest((extract(epoch from (l.end_time - l.start_time)) / 60)::int, 0)) filter (where l.status = 'done'), 0) as mins,
                 count(distinct l.student_id) filter (where l.status = 'done') as stu,
                 count(*) filter (where l.status = 'cancelled') as canc,
                 count(*) filter (where l.status = 'done' and l.trial) as trials
            from memberships m join lessons l on l.taught_by = m.id and l.org_id = m.org_id and l.lesson_date between m0 and m1 and l.status in ('done', 'cancelled')
           where m.org_id = p_org group by m.id, m.display_name, m.employment_type) q;
  return r;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 8. who may call what: browsers get only the screen functions; the helpers and the calculation are internal
-- ---------------------------------------------------------------------------------------------------
revoke all on function public.tutor_pay_appendonly() from public, anon, authenticated;
revoke all on function public.tutor_pay_frozen_to(uuid, uuid) from public, anon, authenticated;
revoke all on function public.tutor_pay_freeze_guard() from public, anon, authenticated;
revoke all on function public.tutor_pay_payment_guard() from public, anon, authenticated;
revoke all on function public.centre_tutor_pay_gate(uuid, text) from public, anon, authenticated;
revoke all on function public.centre_tutor_period(date, int) from public, anon, authenticated;
revoke all on function public.centre_tutor_rate_for(uuid, uuid, uuid, text, date) from public, anon, authenticated;
revoke all on function public.centre_tutor_monthly(uuid, uuid, date, date, int) from public, anon, authenticated;
revoke all on function public.centre_tutor_pay_rows(uuid, date, date, uuid) from public, anon, authenticated;
revoke all on function public.centre_tutor_rate_list(uuid) from public, anon;
revoke all on function public.centre_tutor_rate_set(uuid, uuid, uuid, text, text, bigint, int, date, text) from public, anon;
revoke all on function public.centre_tutor_pay_list(uuid, date) from public, anon;
revoke all on function public.centre_tutor_pay_detail(uuid, uuid, date) from public, anon;
revoke all on function public.centre_tutor_pay_adjust(uuid, uuid, bigint, date, text) from public, anon;
revoke all on function public.centre_tutor_pay_record(uuid, uuid, date, bigint, date, text, text, text) from public, anon;
revoke all on function public.centre_tutor_pay_reverse(uuid, text) from public, anon;
revoke all on function public.centre_tutor_pay_export_log(uuid, date, int, bigint) from public, anon;
revoke all on function public.centre_tutor_taught_report(uuid, date) from public, anon;
grant execute on function public.centre_tutor_rate_list(uuid), public.centre_tutor_rate_set(uuid, uuid, uuid, text, text, bigint, int, date, text),
  public.centre_tutor_pay_list(uuid, date), public.centre_tutor_pay_detail(uuid, uuid, date), public.centre_tutor_pay_adjust(uuid, uuid, bigint, date, text),
  public.centre_tutor_pay_record(uuid, uuid, date, bigint, date, text, text, text), public.centre_tutor_pay_reverse(uuid, text),
  public.centre_tutor_pay_export_log(uuid, date, int, bigint), public.centre_tutor_taught_report(uuid, date) to authenticated, service_role;
