-- =====================================================================================================
-- Phase 2, slice A — attendance + trial flag on lessons, and the monthly "active students" count
--                                                                          undo: migration_attendance_down.sql
-- =====================================================================================================
-- EXPAND step; needs migration_org_foundation.sql first. Nothing existing changes: both new columns are optional /
-- default false, so every page that doesn't know about them keeps working, and solo tutors' lessons stay untouched.
--
-- TutorDeck's fee for centres = S$100 + S$0.40 × BILLABLE students, where billable = the previous month's ACTIVE
-- students rounded to the nearest 10 (halves up; the rounding lives in assets/js/money.js, tested).
-- ACTIVE student in a month (owner's definition): at least one NON-TRIAL lesson that month whose attendance is
--   attended · absent · late_cancelled
-- (cancelled_early and not-yet-marked lessons don't count). Each student counts once however many lessons they had.
-- Run on the DEV project first. Safe to run twice.
-- =====================================================================================================

alter table public.lessons add column if not exists attendance text;
alter table public.lessons add column if not exists trial boolean not null default false;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'lessons_attendance_check') then
    alter table public.lessons add constraint lessons_attendance_check
      check (attendance is null or attendance in ('attended','absent','late_cancelled','cancelled_early'));
  end if;
end $$;

-- Active students of one organisation in the calendar month containing p_month (any day in it will do).
-- Server use only (the monthly billing job runs with the service role); signed-in users can't call it.
create or replace function public.org_active_students_in_month(p_org uuid, p_month date) returns int
language sql stable security definer set search_path = public as $$
  select count(distinct l.student_id)::int
  from lessons l
  where l.org_id = p_org
    and l.lesson_date >= date_trunc('month', p_month)::date
    and l.lesson_date <  (date_trunc('month', p_month) + interval '1 month')::date
    and not l.trial
    and l.attendance in ('attended', 'absent', 'late_cancelled')
$$;
revoke all on function public.org_active_students_in_month(uuid, date) from public, anon, authenticated;
grant execute on function public.org_active_students_in_month(uuid, date) to service_role;
