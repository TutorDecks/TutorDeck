-- =====================================================================================================
-- T4 step S7b — a centre tutor sees their OWN pay (and only that)                                undo: migration_tutor_own_pay_down.sql
-- =====================================================================================================
-- Run order everywhere: org_foundation → billing → attendance → tutor_access → org_delete → function_lockdown → org_separation →
--   staff_home → staff_students → staff_attendance → staff_charges → staff_trials → staff_timetable → money_settings →
--   centre_money → centre_invoice_run → centre_payments → centre_deposits → centre_refunds → centre_late_fees → centre_credit_undo →
--   centre_tutor_pay → tutor_own_pay.
-- Needs centre_tutor_pay (S7: the pay calculation) and centre_credit_undo (the settings check that knows its organisation). Run on the DEV project
-- first. LIVE only when the owner says ship. Adds four functions and widens one settings check; it reads and changes no existing row. Safe to run twice.
--
-- THE RULE (owner's decision, 2026-11-27): the old rule "tutors never see a price, rate, amount or paid" protects what PARENTS pay. A tutor's own EARNINGS
-- may be shown, if the centre chooses. The centre decides with a NEW setting  tutor_pay.tutors_see_own_pay :
--     off                   a tutor sees nothing about pay
--     monthly_total         a tutor sees the month's total (and its bonus / deduction lines), no per-lesson amounts
--     per_lesson_and_total  (default) the same, plus the amount beside each lesson
--   It only applies when tutor_pay.mode = 'full' (the centre works out pay at all). A missing key means the default.
--
-- WHAT A TUTOR SEES: their own pay and nothing else. NEVER the family's fee, the rate, the percentage or its base, the invoice, another tutor's pay, or
--   anything about whether a family has paid. A lesson whose pay is held (until the parent pays, waiting for an invoice, waiting for a charge, or with no
--   rate set yet) shows only the word "pending": no amount and no reason. Once released it shows the amount. Everything is an estimate until staff
--   record the pay run (run_recorded). A bonus or deduction is one line with the staff-written label and the amount, nothing more.
--
-- HOW: four NEW security-definer functions that return pay FIGURES ONLY, each with an explicit column list (tests/sql/tutor_own_pay_test.sql reads the
--   declared return types and fails if a column named like a fee, rate, percentage, base, amount, paid, invoice, student, household or another person
--   ever appears). They take no organisation id: they answer for the caller's own active memberships (tutor, staff or owner) in CENTRES. A caller with
--   no such membership (a parent, a solo owner, a stranger, switched-off staff, signed-out) gets NOT_FOUND. They never write anything.
--     tutor_my_pay_modes()             one row per centre: org_id, org_name, pay_view (off / monthly_total / per_lesson_and_total)
--     tutor_my_pay(from, to)           one row per lesson that has pay or is pending, for centres whose setting is per_lesson_and_total
--     tutor_my_pay_month(month)        one row per centre whose setting is not off: the pay period's totals (estimate)
--     tutor_my_pay_adjustments(month)  the bonus / deduction lines of that period (label + amount)
--   The figures come from the same calculation staff see (centre_tutor_pay_rows, centre_tutor_monthly): the pay period that ends in the month (the
--   centre's cut-off day), carried-over amounts, released lessons, fixed monthly pay and adjustments. Pending lessons are counted but never valued.
-- =====================================================================================================

-- ---------------------------------------------------------------------------------------------------
-- 1. the setting: checked when a centre saves settings (the 2-argument check is the one org_save_settings and org_create_centre call)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.org_validate_settings(p_org uuid, s jsonb) returns void language plpgsql stable security definer set search_path = public as $$
declare st jsonb;
begin
  perform public.org_validate_settings(s);
  if s #>> '{tutor_pay,tutors_see_own_pay}' is not null and s #>> '{tutor_pay,tutors_see_own_pay}' not in ('off','monthly_total','per_lesson_and_total') then
    raise exception 'Unknown setting for tutors seeing their own pay'; end if;
  if s #>> '{billing,deposit,refund_approved_by}' = 'four_eyes' then
    st := case when p_org is null then jsonb_build_object('owner', true, 'deposit', false, 'credit', false) else public.org_four_eyes_status(p_org) end;
    if not (coalesce((st->>'owner')::boolean, false) and coalesce((st->>'deposit')::boolean, false) and coalesce((st->>'credit')::boolean, false)) then
      raise exception 'FOUR_EYES_UNAVAILABLE: "someone other than the person who asked" needs a second approver: the owner, a staff member who issues invoices (for deposit refunds) and a staff member who records payments (for credit refunds), all active. Add them first, or pick another approver.' using errcode = '42501';
    end if;
  end if;
end $$;
revoke all on function public.org_validate_settings(uuid, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------
-- 2. internal: the caller's own centres, their membership there, the centre's today, and what the centre lets them see
-- ---------------------------------------------------------------------------------------------------
create or replace function public.tutor_own_pay_orgs()
returns table(g_org uuid, g_name text, g_mid uuid, g_today date, g_view text, g_cut int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  return query
  select o.id, o.trading_name, m.id, c.d,
         case when coalesce(cfg.s #>> '{tutor_pay,mode}', 'off') = 'full' and coalesce(cfg.s #>> '{tutor_pay,tutors_see_own_pay}', 'per_lesson_and_total') in ('monthly_total', 'per_lesson_and_total')
              then coalesce(cfg.s #>> '{tutor_pay,tutors_see_own_pay}', 'per_lesson_and_total') else 'off' end,
         case when (cfg.s #>> '{tutor_pay,cycle,cutoff_day}') ~ '^[0-9]{1,2}$' then (cfg.s #>> '{tutor_pay,cycle,cutoff_day}')::int else 31 end
    from memberships m
    join organisations o on o.id = m.org_id and o.kind = 'centre'
    cross join lateral (select (now() at time zone o.timezone)::date as d) c
    cross join lateral (select org_settings_on(o.id, c.d) as s) cfg
   where m.user_id = auth.uid() and m.status = 'active' and m.role in ('tutor', 'staff', 'owner');
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 3. tutor_my_pay_modes(): what each of my centres lets me see (the menu and the settings page ask this)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.tutor_my_pay_modes()
returns table(org_id uuid, org_name text, pay_view text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not exists (select 1 from public.tutor_own_pay_orgs()) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  return query select g.g_org, g.g_name, g.g_view from public.tutor_own_pay_orgs() g order by g.g_name, g.g_org;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 4. tutor_my_pay(from, to): the pay beside each of my lessons (centres set to per_lesson_and_total only)
--    pay_state 'amount' = released: pay_cents is the estimate · 'pending' = held, pay_cents is null (no amount, no reason).
--    A lesson that earns nothing (a free cancellation, a fixed-monthly tutor, "unpaid" scope) has no row: nothing to show.
--    Released as of the centre's today; lessons dated from p_from to p_to.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.tutor_my_pay(p_from date, p_to date)
returns table(org_id uuid, org_name text, lesson_id uuid, lesson_date date, pay_state text, pay_cents bigint)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare g record;
begin
  if not exists (select 1 from public.tutor_own_pay_orgs()) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 62 then
    raise exception 'BAD_RANGE: ask for at most 62 days' using errcode = 'P0001'; end if;
  for g in select * from public.tutor_own_pay_orgs() o where o.g_view = 'per_lesson_and_total' order by o.g_name, o.g_org loop
    return query
      select g.g_org, g.g_name, x.lesson_id, x.lesson_date,
             case when x.state in ('payable', 'part') then 'amount' else 'pending' end,
             case when x.state = 'payable' then x.earn_cents when x.state = 'part' then x.released_to else null end
        from public.centre_tutor_pay_rows(g.g_org, p_from, g.g_today, g.g_mid) x
       where x.lesson_date between p_from and p_to
         and x.state in ('payable', 'part', 'held', 'waiting_invoice', 'waiting_charge', 'no_rate')
       order by x.lesson_date, x.lesson_id;
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 5. tutor_my_pay_month(month): my totals for the pay period that ends in that month (default: this centre's current one)
--    earned_cents      lessons released in the period + fixed monthly pay
--    adjustments_cents bonuses and deductions dated in the period (the lines come from tutor_my_pay_adjustments)
--    carry_cents       released earlier and not yet paid out (a late parent payment, a part payment, a reversed payment)
--    total_cents       carry + earned + adjustments: the estimate
--    pending_lessons   how many lessons are still held; never valued, never explained
--    run_recorded      staff have recorded the pay run for this period (the figures are then final)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.tutor_my_pay_month(p_month date default null)
returns table(org_id uuid, org_name text, period_from date, period_to date, pay_view text, lessons int, earned_cents bigint, adjustments_cents bigint,
              carry_cents bigint, total_cents bigint, pending_lessons int, run_recorded boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare g record; pf date; pt date; rb bigint; ri bigint; nl int; np int; mo record; ab bigint; ai bigint; pb bigint; pn bigint;
begin
  if not exists (select 1 from public.tutor_own_pay_orgs()) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  for g in select * from public.tutor_own_pay_orgs() o where o.g_view <> 'off' order by o.g_name, o.g_org loop
    select x.p_from, x.p_to into pf, pt from public.centre_tutor_period(coalesce(p_month, g.g_today), g.g_cut) x;
    select coalesce(sum(x.released_before), 0), coalesce(sum(x.released_to - x.released_before), 0),
           count(*) filter (where x.lesson_status = 'done' and x.earn_on between pf and pt),
           count(*) filter (where x.state in ('held', 'waiting_invoice', 'waiting_charge', 'no_rate') and x.earn_on <= pt)
      into rb, ri, nl, np
      from public.centre_tutor_pay_rows(g.g_org, pf, pt, g.g_mid) x;
    select * into mo from public.centre_tutor_monthly(g.g_org, g.g_mid, pf, pt, g.g_cut);
    select coalesce(sum(a.amount_cents) filter (where a.effective_on < pf), 0), coalesce(sum(a.amount_cents) filter (where a.effective_on between pf and pt), 0)
      into ab, ai from public.tutor_pay_adjustments a where a.org_id = g.g_org and a.membership_id = g.g_mid;
    select coalesce(sum(case when p.kind = 'payment' then p.amount_cents else -p.amount_cents end) filter (where p.period_to < pf), 0),
           coalesce(sum(case when p.kind = 'payment' then p.amount_cents else -p.amount_cents end) filter (where p.period_to = pt), 0)
      into pb, pn from public.tutor_pay_payments p where p.org_id = g.g_org and p.membership_id = g.g_mid;
    org_id := g.g_org; org_name := g.g_name; period_from := pf; period_to := pt; pay_view := g.g_view; lessons := nl;
    earned_cents := ri + mo.period_cents; adjustments_cents := ai;
    carry_cents := rb + mo.before_cents + ab - pb;
    total_cents := carry_cents + earned_cents + adjustments_cents;
    pending_lessons := np; run_recorded := pn > 0;
    return next;
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 6. tutor_my_pay_adjustments(month): my bonus / deduction lines for that period, with the label staff wrote
-- ---------------------------------------------------------------------------------------------------
create or replace function public.tutor_my_pay_adjustments(p_month date default null)
returns table(org_id uuid, org_name text, effective_on date, kind text, adjustment_cents bigint, label text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare g record; pf date; pt date;
begin
  if not exists (select 1 from public.tutor_own_pay_orgs()) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  for g in select * from public.tutor_own_pay_orgs() o where o.g_view <> 'off' order by o.g_name, o.g_org loop
    select x.p_from, x.p_to into pf, pt from public.centre_tutor_period(coalesce(p_month, g.g_today), g.g_cut) x;
    return query
      select g.g_org, g.g_name, a.effective_on, a.kind, a.amount_cents, a.reason
        from public.tutor_pay_adjustments a
       where a.org_id = g.g_org and a.membership_id = g.g_mid and a.effective_on between pf and pt
       order by a.effective_on, a.created_at, a.id;
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 7. who may call what
-- ---------------------------------------------------------------------------------------------------
revoke all on function public.tutor_own_pay_orgs() from public, anon, authenticated;
revoke all on function public.tutor_my_pay_modes() from public, anon;
revoke all on function public.tutor_my_pay(date, date) from public, anon;
revoke all on function public.tutor_my_pay_month(date) from public, anon;
revoke all on function public.tutor_my_pay_adjustments(date) from public, anon;
grant execute on function public.tutor_my_pay_modes(), public.tutor_my_pay(date, date), public.tutor_my_pay_month(date), public.tutor_my_pay_adjustments(date) to authenticated, service_role;
