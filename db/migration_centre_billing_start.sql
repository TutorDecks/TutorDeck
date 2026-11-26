-- =====================================================================================================
-- T36 — billing start date + first-month student count, per centre          undo: migration_centre_billing_start_down.sql
-- =====================================================================================================
-- Problem: the monthly job records a fee snapshot for every active centre from LAST month's active students. A centre in a free
-- pilot, or in its first billed month, would be charged wrongly. Two optional settings on the centre's plan fix that:
--   org_plans.billing_starts_on              date (always the 1st of a month; null = no restriction, exactly as before)
--   org_plans.first_month_billable_override  int  (>= 0; null = none): the agreed student count for the FIRST billed month only
--   org_plans.billing_start_reason           text (why; also visible in the audit log, which copies the whole plan row)
-- What the monthly job does with them (api/_billing-job-core.js, tested):
--   month BEFORE billing_starts_on  → a snapshot is still recorded, for information, with billable = false, waived_reason = 'pilot', fee 0
--   FIRST billed month + override   → the count used is the override (rounded to the nearest 10, halves up, like any count);
--                                     the snapshot keeps the REAL count in active_students and the number used in override_students
--   every later month               → the normal rule
-- Snapshots gain three columns (billable, waived_reason, override_students). Existing rows default to billable = true / nulls. They stay
-- append-only: nothing here rewrites a closed month. Only a PLATFORM ADMIN can change the settings (org_set_billing_start), always
-- with a reason, and never once a snapshot exists for the first billed month or any later month (a closed month is never reinterpreted).
-- Needs migration_org_foundation.sql + migration_centre_billing_method.sql. Safe to run twice. DEV first, LIVE before the code ships.
-- =====================================================================================================
alter table public.org_plans add column if not exists billing_starts_on date;
alter table public.org_plans add column if not exists first_month_billable_override int;
alter table public.org_plans add column if not exists billing_start_reason text;
alter table public.org_plans drop constraint if exists org_plans_billing_start_check;
alter table public.org_plans add constraint org_plans_billing_start_check check (
  (billing_starts_on is null or extract(day from billing_starts_on) = 1)
  and (first_month_billable_override is null or (first_month_billable_override >= 0 and billing_starts_on is not null)));

alter table public.platform_fee_snapshots add column if not exists billable boolean not null default true;
alter table public.platform_fee_snapshots add column if not exists waived_reason text;
alter table public.platform_fee_snapshots add column if not exists override_students int;
alter table public.platform_fee_snapshots drop constraint if exists platform_fee_snapshots_waived_check;
alter table public.platform_fee_snapshots add constraint platform_fee_snapshots_waived_check check (
  (billable and waived_reason is null) or (not billable and coalesce(waived_reason, '') = 'pilot' and fee_cents = 0));
alter table public.platform_fee_snapshots drop constraint if exists platform_fee_snapshots_override_check;
alter table public.platform_fee_snapshots add constraint platform_fee_snapshots_override_check check (
  override_students is null or (override_students >= 0 and billable));

-- Set (or clear, with nulls) a centre's billing start. Platform admin only; a reason is required. Applies to every plan row of the centre.
create or replace function public.org_set_billing_start(p_org uuid, p_starts_on date, p_override int, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare cur date; earliest date;
begin
  if auth.uid() is null or not org_is_platform_admin() then raise exception 'Only a TutorDeck administrator can change the billing start'; end if;
  if p_reason is null or length(btrim(p_reason)) < 3 then raise exception 'A reason is required'; end if;
  if not exists (select 1 from organisations where id = p_org and kind = 'centre') then raise exception 'Only a centre has a billing start'; end if;
  if p_starts_on is not null and extract(day from p_starts_on) <> 1 then raise exception 'Billing starts on the 1st of a month'; end if;
  if p_override is not null and (p_override < 0 or p_starts_on is null) then raise exception 'The first-month number needs a start date and cannot be negative'; end if;
  select billing_starts_on into cur from org_plans where org_id = p_org and plan_code = 'centre' order by effective_from desc limit 1;
  earliest := least(coalesce(cur, p_starts_on), coalesce(p_starts_on, cur));
  -- closed months are never reinterpreted: nothing may change once a snapshot exists for the first billed month (old or new) or later
  if earliest is not null and exists (select 1 from platform_fee_snapshots where org_id = p_org and month >= earliest) then
    raise exception 'A month from the billing start onwards is already closed; it cannot be changed';
  end if;
  update org_plans set billing_starts_on = p_starts_on, first_month_billable_override = p_override, billing_start_reason = btrim(p_reason)
    where org_id = p_org and plan_code = 'centre'
      and (billing_starts_on is distinct from p_starts_on or first_month_billable_override is distinct from p_override or billing_start_reason is distinct from btrim(p_reason));
end $$;
revoke all on function public.org_set_billing_start(uuid, date, int, text) from public, anon;
grant execute on function public.org_set_billing_start(uuid, date, int, text) to authenticated;
