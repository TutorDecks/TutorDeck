-- =====================================================================================================
-- T6 step 1 — the tutor's read-only Schedule: my week, and my weekly slots                  undo: migration_tutor_schedule_down.sql
-- =====================================================================================================
-- Needs migration_staff_reassign.sql (and everything before it: lessons.taught_by, covered_for, recurring_slots.taught_by, students.online_link, holidays).
-- Adds NO columns and NO tables. Two read-only functions for centre tutors; nothing is written, nothing existing changes.
--
--   tutor_my_schedule(from, to)   read   MY lessons in a date range (at most 62 days), with the whole-centre holidays that fall in it
--   tutor_my_slots()              read   MY weekly slots (day, time, student), the ones staff assigned to me
--
-- WHO MAY CALL: a person with an ACTIVE tutor membership in a CENTRE. Anyone else (staff or owner of a centre, a parent, a solo organisation's
-- owner, a switched-off tutor, a stranger, not signed in) gets NOT_FOUND, the same word as the rest of the tutor functions, so nothing can be
-- probed. A tutor sees ONLY their own membership's rows, in the centre(s) where they are an active tutor.
--
-- WHAT A TUTOR NEVER SEES (the rule of tutor_my_lessons, kept here): no rate, price, amount, paid flag, compensation, charge note or *_cents.
-- The two functions below name every column they return; they never use `l.*` / `sl.*`, and no money column is read at all. tests/sql/tutor_schedule_test.sql
-- checks this three ways: the returned keys, the function text (no money word in it), and a lesson/slot whose money columns hold marker values.
-- The student's parent contact comes back only when the centre's existing setting `lessons.tutors_see_parent_contact` is on (default off).
--
-- WHAT A ROW SAYS (plain words): date, start, end, student name and level, subject, the student's online link (if staff set one), trial, the
-- attendance mark (null = not marked yet), cancelled, postponed (moved from its usual day), covering (someone else's lesson I am covering),
-- and `holiday` = the name of a whole-centre holiday that day. Branch holidays are not shown: slots and students carry no branch.
-- `timetable_editing` is the centre's setting 'who edits the timetable' (admin_only today). In this step it only decides which note the screen
-- shows: nothing here lets a tutor change anything (that is T6 step 2 onward).
-- Run on the DEV project first. Safe to run twice.
-- =====================================================================================================

-- ---------------------------------------------------------------- 1. my lessons in a range, plus holidays
drop function if exists public.tutor_my_schedule(date, date);
create or replace function public.tutor_my_schedule(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare orgs jsonb; lessons jsonb; hols jsonb; today date;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if not exists (select 1 from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
                  where m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active') then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 62 then
    raise exception 'BAD_RANGE: ask for at most 62 days' using errcode = 'P0001'; end if;

  select jsonb_agg(jsonb_build_object('org_id', o.id, 'name', o.trading_name, 'today', (now() at time zone o.timezone)::date,
                                      'timetable_editing', coalesce(org_settings_on(o.id, current_date) #>> '{lessons,timetable_editing}', 'admin_only'),
                                      'can_edit', false) order by o.trading_name, o.id),
         min((now() at time zone o.timezone)::date)
    into orgs, today
    from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
   where m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active';

  select coalesce(jsonb_agg(jsonb_build_object(
           'lesson_id', l.id, 'org_id', l.org_id, 'org_name', o.trading_name,
           'student_id', s.id, 'student_name', s.name, 'student_level', s.level,
           'parent_contact', case when coalesce((org_settings_on(l.org_id, current_date) #>> '{lessons,tutors_see_parent_contact}')::boolean, false) then s.contact end,
           'lesson_date', l.lesson_date, 'start_time', l.start_time, 'end_time', l.end_time,
           'minutes', (extract(epoch from (l.end_time - l.start_time)) / 60)::int, 'subject', l.subject,
           'trial', l.trial, 'attendance', l.attendance, 'status', l.status, 'cancelled', (l.status = 'cancelled'),
           'postponed', l.postponed, 'covering', (l.covered_for is not null), 'online_link', s.online_link,
           'holiday', (select h.name from holidays h where h.org_id = l.org_id and h.branch_id is null
                        and l.lesson_date between h.starts_on and h.ends_on order by h.starts_on, h.name limit 1)
         ) order by l.lesson_date, l.start_time, s.name, l.id), '[]'::jsonb)
    into lessons
    from lessons l
    join memberships m on m.id = l.taught_by and m.org_id = l.org_id and m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active'
    join organisations o on o.id = l.org_id and o.kind = 'centre'
    join students s on s.id = l.student_id and s.org_id = l.org_id
   where l.lesson_date between p_from and p_to;

  select coalesce(jsonb_agg(jsonb_build_object('org_id', h.org_id, 'name', h.name, 'starts_on', h.starts_on, 'ends_on', h.ends_on)
                            order by h.starts_on, h.name, h.id), '[]'::jsonb)
    into hols
    from holidays h
   where h.branch_id is null and h.starts_on <= p_to and h.ends_on >= p_from
     and exists (select 1 from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
                  where m.org_id = h.org_id and m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active');

  return jsonb_build_object('today', today, 'from', p_from, 'to', p_to, 'orgs', orgs, 'lessons', lessons, 'holidays', hols);
end $$;

-- ---------------------------------------------------------------- 2. my weekly slots
-- One row per student of an ACTIVE weekly slot that staff gave to me (a group class is several rows sharing a session_key). weekday 0 = Monday … 6 = Sunday,
-- like the Planner. A student whose lessons have ended (students.end_date, inclusive) is not listed.
drop function if exists public.tutor_my_slots();
create or replace function public.tutor_my_slots()
returns table(slot_id uuid, org_id uuid, org_name text, weekday int, start_time time, end_time time, subject text,
              student_id uuid, student_name text, student_level text, session_key uuid, timetable_editing text)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if not exists (select 1 from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
                  where m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active') then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  return query
    select sl.id, sl.org_id, o.trading_name, sl.weekday::int, sl.start_time, sl.end_time, sl.subject,
           s.id, s.name, s.level, sl.session_key,
           coalesce(org_settings_on(sl.org_id, current_date) #>> '{lessons,timetable_editing}', 'admin_only')
      from recurring_slots sl
      join memberships m on m.id = sl.taught_by and m.org_id = sl.org_id and m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active'
      join organisations o on o.id = sl.org_id and o.kind = 'centre'
      join students s on s.id = sl.student_id and s.org_id = sl.org_id
     where sl.active and (s.end_date is null or s.end_date >= (now() at time zone o.timezone)::date)
     order by sl.weekday, sl.start_time, s.name, sl.id;
end $$;

-- ---------------------------------------------------------------- who may call
do $$
declare f text;
begin
  foreach f in array array['tutor_my_schedule(date,date)', 'tutor_my_slots()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
