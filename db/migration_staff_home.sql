-- =====================================================================================================
-- T3 step 1 — the centre Home for owners and staff: staff_home(org)                undo: migration_staff_home_down.sql
-- =====================================================================================================
-- Needs migration_org_foundation.sql, migration_attendance.sql and migration_tutor_access.sql (lessons.taught_by, attendance, trial).
-- ADD-ONLY: one new function, no table or column is touched.
--
-- WHAT IT IS: ONE call returns the numbers the centre Home shows, as COUNTS ONLY. No money (no rate, amount, paid, compensation,
-- *_cents), no names, no phone numbers: the page links through to the real screens (built in later steps), which have their own checks.
--
-- WHO MAY SEE WHAT (the menu hides what a person can't use; this function refuses it anyway; a section the caller isn't allowed to see comes
-- back as null, never as 0, so "no permission" can't be mistaken for "nothing to do"):
--   the caller must be an active OWNER or STAFF member of this centre (anything else, a tutor, a parent, a stranger, a solo organisation,
--   an unknown id: the same NOT_FOUND, so ids can't be probed)
--   students section               manage_students   (owner always)
--   today / not marked / no tutor / trials   manage_timetable
--   pending charges                issue_invoices    (a count only; the amounts are step 4)
--   `can` tells the page which sections the caller has, so it doesn't have to guess
--
-- DAYS are the centre's own calendar days (organisations.timezone), not the server's.
-- Run on the DEV project first. Safe to run twice.
-- =====================================================================================================
create or replace function public.staff_home(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  o organisations; today date; can_st boolean; can_tt boolean; can_ch boolean; res jsonb;
  c_students int; c_today int; c_today_marked int; c_today_open int; c_unmarked int; c_notutor int; c_trials int; c_pending int;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into o from organisations where id = p_org and kind = 'centre';
  if not found or not exists (select 1 from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active'
                              and m.role in ('owner', 'staff')) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  today := (now() at time zone o.timezone)::date;
  can_st := org_can(p_org, 'manage_students');
  can_tt := org_can(p_org, 'manage_timetable');
  can_ch := org_can(p_org, 'issue_invoices');

  if can_st then      -- students whose "lessons run until" date hasn't passed (the same rule as TL.isEnded)
    select count(*) into c_students from students s where s.org_id = p_org and (s.end_date is null or s.end_date >= today);
  end if;
  if can_tt then
    -- a lesson cancelled by staff with no attendance mark is closed: it is neither "to mark" nor "marked"
    select count(*) filter (where l.status <> 'cancelled' or l.attendance is not null),
           count(*) filter (where l.attendance is not null),
           count(*) filter (where l.attendance is null and l.status <> 'cancelled')
      into c_today, c_today_marked, c_today_open from lessons l where l.org_id = p_org and l.lesson_date = today;
    -- days gone by with no mark: the last 60 days (the longest window a centre can choose), so old history doesn't count forever
    select count(*) into c_unmarked from lessons l
      where l.org_id = p_org and l.lesson_date < today and l.lesson_date >= today - 60 and l.attendance is null and l.status <> 'cancelled';
    select count(*) into c_notutor from lessons l
      where l.org_id = p_org and l.lesson_date >= today and l.lesson_date < today + 14 and l.taught_by is null and l.status <> 'cancelled';
    select count(*) into c_trials from lessons l
      where l.org_id = p_org and l.trial and date_trunc('month', l.lesson_date) = date_trunc('month', today);
  end if;
  if can_ch then      -- absent / cancelled lessons whose charge hasn't been typed yet (invoicing must wait for these)
    select count(*) into c_pending from lessons l
      where l.org_id = p_org and l.attendance in ('absent', 'cancelled_early', 'late_cancelled') and l.compensation is null;
  end if;

  res := jsonb_build_object(
    'org_id', p_org, 'org_name', o.trading_name, 'status', o.status, 'today', today,
    'can', jsonb_build_object('students', can_st, 'timetable', can_tt, 'charges', can_ch),
    'students_active', c_students,
    'today_lessons', c_today, 'today_marked', c_today_marked, 'today_to_mark', c_today_open,
    'unmarked_past', c_unmarked, 'no_tutor_14d', c_notutor, 'trials_this_month', c_trials,
    'pending_charges', c_pending);
  return res;
end $$;

revoke all on function public.staff_home(uuid) from public, anon;
grant execute on function public.staff_home(uuid) to authenticated;
