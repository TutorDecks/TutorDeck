-- =====================================================================================================
-- Phase 2, slice C1 — centre tutors: who teaches a lesson, and a safe way for them to see and mark it
--                                                                        undo: migration_tutor_access_down.sql
-- =====================================================================================================
-- Needs migration_org_foundation.sql and migration_attendance.sql. EXPAND step: new optional columns, nothing existing changes.
--
-- DESIGN: a centre tutor gets NO access to any table (no row-level policy names them), because row-level security
-- can't hide columns and `lessons` also holds what parents pay (rate, amount, paid, compensation). Everything a tutor
-- can do goes through two narrow functions that each check who is calling, return/accept an explicit list of fields,
-- and never touch money, status or the lesson's date and time:
--   tutor_my_lessons(from, to)   → my lessons in a date range, with student name + level (parent contact only if the
--                                  centre's setting `lessons.tutors_see_parent_contact` is on; off when the key is missing),
--                                  plus can_mark (may set attendance) and can_note (may write notes) so the screen needn't guess
--   tutor_mark_attendance(...)   → set attended / absent and write topics, homework, remarks, on MY lesson, from its
--                                  day (centre's own timezone) to 14 days after; never over someone else's mark
-- Staff and owners keep using the existing org_write policy (manage_timetable) to schedule, reassign and mark anything.
--
-- Rules: every business decision is the CENTRE's, chosen at sign-up (assets/js/org-settings.js, step "Tutors and lessons") and read here as of
-- today; a missing key means the default shown with each setting below. What stays fixed is integrity, not process: nobody marks a
-- lesson before its day, a tutor never overwrites another person's mark, tutors never touch money, status, date, time or the trial flag.
--   attendance_by = 'admin' → tutors can still write remarks, but can't set attendance
--   cancellations (cancelled_early / late_cancelled): admins by default; tutors if the centre chooses ('cancellations_marked_by' = 'tutor')
--   whether an "absent" lesson is billable is a money rule, so the lesson's status and amount are left alone here
--   replacement tutors: changing taught_by from one person to another needs the setting `lessons.replacement_tutors`
--     (default on); assigning a lesson that has no tutor yet is always allowed
-- Run on the DEV project first. Safe to run twice.
-- =====================================================================================================

-- ---------------------------------------------------------------- columns
create unique index if not exists memberships_id_org on public.memberships(id, org_id);
alter table public.lessons add column if not exists taught_by uuid;                   -- memberships.id of the tutor teaching it
alter table public.lessons add column if not exists session_id uuid;                  -- lessons of one class share a session_id
alter table public.lessons add column if not exists attendance_marked_at timestamptz;
alter table public.lessons add column if not exists attendance_marked_by uuid;        -- auth user who set the attendance
alter table public.lessons add column if not exists remarks_at timestamptz;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'lessons_taught_by_same_org') then
    -- same organisation only; if the person is removed the lesson keeps its organisation (set null on taught_by ONLY)
    alter table public.lessons add constraint lessons_taught_by_same_org
      foreign key (taught_by, org_id) references public.memberships(id, org_id) on delete set null (taught_by);
  end if;
end $$;
create index if not exists lessons_taught_by on public.lessons(taught_by, lesson_date) where taught_by is not null;
create index if not exists lessons_session on public.lessons(session_id) where session_id is not null;

-- ---------------------------------------------------------------- stamps: when attendance changes, who and when
-- Does nothing unless `attendance` itself changed (it fires on every lesson update, solo tutors' included).
create or replace function public.lessons_attendance_stamp() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.attendance is distinct from old.attendance then
    new.attendance_marked_at := case when new.attendance is null then null else now() end;
    new.attendance_marked_by := case when new.attendance is null then null else auth.uid() end;
  end if;
  return new;
end $$;
drop trigger if exists lessons_attendance_stamp on public.lessons;
create trigger lessons_attendance_stamp before update of attendance on public.lessons for each row execute function public.lessons_attendance_stamp();

-- ---------------------------------------------------------------- who may be put on a lesson, and replacement tutors
create or replace function public.lessons_taught_by_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.taught_by is null then return new; end if;
  if tg_op = 'UPDATE' and new.taught_by is not distinct from old.taught_by then return new; end if;
  -- an invited tutor who hasn't signed up yet can be scheduled; a disabled one can't
  if not exists (select 1 from memberships m where m.id = new.taught_by and m.org_id = new.org_id and m.status <> 'disabled') then
    raise exception 'NOT_AVAILABLE: that person can''t be given lessons in this organisation' using errcode = 'P0001';
  end if;
  if tg_op = 'UPDATE' and old.taught_by is not null
     and coalesce((org_settings_on(new.org_id, current_date) #>> '{lessons,replacement_tutors}')::boolean, true) = false then
    raise exception 'REPLACEMENT_OFF: this centre doesn''t allow replacement tutors' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists lessons_taught_by_guard on public.lessons;
create trigger lessons_taught_by_guard before insert or update of taught_by on public.lessons for each row execute function public.lessons_taught_by_guard();

-- ---------------------------------------------------------------- tutor_my_lessons: read, explicit columns only
-- No rate, amount, paid, compensation, charge_note or *_cents column is returned, and never `l.*` — add a column here deliberately or not at all.
-- Every business rule below comes from the centre's own settings (chosen at sign-up, changeable later), read as of TODAY: these are rules about who
-- may act now, so a change applies to every lesson from then on (fees are different: they follow the settings in force when the lesson happened).
--   lessons.attendance_by            tutor | admin           (default tutor)
--   lessons.attendance_window_days   1-60                    (default 14)
--   lessons.cancellations_marked_by  admin | tutor           (default admin)
--   lessons.remarks.required         true | false            (default false)
--   lessons.remarks.deadline_hours   hours after the lesson  (default 24)
--   lessons.tutors_see_parent_contact true | false           (default false)
-- A missing key means the default in brackets, so older settings keep working.
-- (the return columns changed during development, so drop first; safe on a database that already has an older copy)
drop function if exists public.tutor_my_lessons(date, date);
create or replace function public.tutor_my_lessons(p_from date, p_to date)
returns table(lesson_id uuid, org_id uuid, org_name text, student_id uuid, student_name text, student_level text, parent_contact text,
              lesson_date date, start_time time, end_time time, subject text, status text, attendance text, trial boolean,
              session_id uuid, topics text, homework text, remarks text, remarks_due_at timestamptz,
              can_mark boolean, can_note boolean, can_cancel boolean, remarks_required boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 62 then
    raise exception 'BAD_RANGE: ask for at most 62 days' using errcode = 'P0001'; end if;
  return query
  with mine as (
    select l.id as lid, l.org_id as oid, o.trading_name as oname, o.timezone as tz, l.student_id as sid, s.name as sname, s.level as slevel, s.contact as scontact,
           l.lesson_date as ldate, l.start_time as st, l.end_time as et, l.subject as subj, l.status as stat, l.attendance as att, l.trial as tr,
           l.session_id as sess, l.topics as tp, l.homework as hw, l.remarks as rm, l.attendance_marked_by as mby,
           coalesce((cfg.s #>> '{lessons,attendance_by}'), 'tutor') as att_by,
           coalesce((cfg.s #>> '{lessons,attendance_window_days}')::int, 14) as win,
           coalesce((cfg.s #>> '{lessons,cancellations_marked_by}'), 'admin') as canc_by,
           coalesce((cfg.s #>> '{lessons,remarks,required}')::boolean, false) as rm_req,
           coalesce((cfg.s #>> '{lessons,remarks,deadline_hours}')::int, 24) as rm_hours,
           coalesce((cfg.s #>> '{lessons,tutors_see_parent_contact}')::boolean, false) as see_contact,
           (now() at time zone o.timezone)::date as today
    from lessons l
    join memberships m on m.id = l.taught_by and m.org_id = l.org_id and m.user_id = auth.uid() and m.status = 'active'
    join organisations o on o.id = l.org_id and o.kind = 'centre'
    join students s on s.id = l.student_id and s.org_id = l.org_id
    left join lateral (select org_settings_on(l.org_id, current_date) as s) cfg on true
    where l.lesson_date between p_from and p_to)
  select lid, oid, oname, sid, sname, slevel, case when see_contact then scontact end,
         ldate, st, et, subj, stat, att, tr, sess, tp, hw, rm,
         ((ldate + et) at time zone tz) + make_interval(hours => rm_hours),
         -- can_mark: may set attendance now. can_note: may write notes (doesn't depend on who marks attendance). can_cancel: may also pick a cancellation.
         (stat <> 'cancelled' and ldate <= today and ldate >= today - win and att_by = 'tutor' and (att is null or mby = auth.uid())),
         (stat <> 'cancelled' and ldate <= today and ldate >= today - win),
         (stat <> 'cancelled' and ldate <= today and ldate >= today - win and att_by = 'tutor' and (att is null or mby = auth.uid()) and canc_by = 'tutor'),
         rm_req
  from mine
  order by ldate, st, sname;
end $$;

-- ---------------------------------------------------------------- tutor_mark_attendance: write, narrow
-- p_attendance: 'attended' | 'absent' | null (leave attendance as it is); 'cancelled_early' / 'late_cancelled' only when the centre lets tutors
-- mark cancellations. Text fields: null = leave as it is, '' = clear.
-- Every refusal about "not yours" and "doesn't exist" is the same NOT_FOUND, so lesson ids can't be probed.
create or replace function public.tutor_mark_attendance(p_lesson uuid, p_attendance text default null,
  p_topics text default null, p_homework text default null, p_remarks text default null) returns void
language plpgsql security definer set search_path = public as $$
declare l lessons; o organisations; cfg jsonb; today date; win int; new_remarks text;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into l from lessons where id = p_lesson;
  if not found or l.taught_by is null
     or not exists (select 1 from memberships m where m.id = l.taught_by and m.org_id = l.org_id and m.user_id = auth.uid() and m.status = 'active') then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into o from organisations where id = l.org_id;
  if o.kind <> 'centre' then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;

  cfg := org_settings_on(l.org_id, current_date);
  win := coalesce((cfg #>> '{lessons,attendance_window_days}')::int, 14);
  today := (now() at time zone o.timezone)::date;                       -- the centre's own calendar day, not the server's
  if l.lesson_date > today then raise exception 'TOO_EARLY: you can mark a lesson from its day onward' using errcode = 'P0001'; end if;
  if l.lesson_date < today - win then raise exception 'TOO_OLD: ask an admin to change attendance older than % days', win using errcode = 'P0001'; end if;
  if l.status = 'cancelled' then raise exception 'CANCELLED: this lesson was cancelled' using errcode = 'P0001'; end if;
  if length(coalesce(p_topics, '')) > 2000 or length(coalesce(p_homework, '')) > 2000 or length(coalesce(p_remarks, '')) > 2000 then
    raise exception 'TOO_LONG: keep each note under 2000 characters' using errcode = 'P0001'; end if;

  new_remarks := case when p_remarks is null then l.remarks else nullif(trim(p_remarks), '') end;
  if p_attendance is not null then
    if p_attendance not in ('attended', 'absent')
       and not (p_attendance in ('late_cancelled', 'cancelled_early') and coalesce(cfg #>> '{lessons,cancellations_marked_by}', 'admin') = 'tutor') then
      raise exception 'BAD_VALUE: that isn''t something you can mark at this centre' using errcode = 'P0001'; end if;
    if coalesce(cfg #>> '{lessons,attendance_by}', 'tutor') <> 'tutor' then
      raise exception 'ADMIN_ONLY: attendance is marked by an admin at this centre' using errcode = 'P0001'; end if;
    if l.attendance is not null and l.attendance_marked_by is distinct from auth.uid() then
      raise exception 'ALREADY_MARKED: someone else already marked this lesson; ask an admin to change it' using errcode = 'P0001'; end if;
    -- the centre's own rule: a lesson that took place needs its remarks
    if p_attendance = 'attended' and coalesce((cfg #>> '{lessons,remarks,required}')::boolean, false) and new_remarks is null then
      raise exception 'REMARKS_REQUIRED: this centre needs remarks before a lesson is marked attended' using errcode = 'P0001'; end if;
  end if;

  update lessons set
    attendance = coalesce(p_attendance, attendance),
    topics     = case when p_topics   is null then topics   else nullif(trim(p_topics), '') end,
    homework   = case when p_homework is null then homework else nullif(trim(p_homework), '') end,
    remarks    = new_remarks,
    remarks_at = case when p_remarks  is null then remarks_at else now() end
  where id = p_lesson;
end $$;

-- ---------------------------------------------------------------- who may call what (each function checks the caller itself)
do $$
declare f text;
begin
  foreach f in array array['tutor_my_lessons(date,date)', 'tutor_mark_attendance(uuid,text,text,text,text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['lessons_taught_by_guard()', 'lessons_attendance_stamp()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;
