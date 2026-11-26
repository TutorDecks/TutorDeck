-- =====================================================================================================
-- T3 step 5 — the Trial flag for owners and staff                                 undo: migration_staff_trials_down.sql
-- =====================================================================================================
-- Needs migration_staff_attendance.sql (staff_attendance_gate, staff_lessons). Changes: ONE new function, and staff_lessons is
-- re-created with the same signature so its status filter also accepts 'trial' and its counts gain a 'trial' number. No table, column,
-- policy or trigger is touched.
--
--   staff_set_trial(lesson, trial)   flag or unflag ONE lesson as a trial lesson. Needs manage_timetable (the same permission as marking),
--                                    owners always. Staff can ALWAYS do it: lessons.trials_flagged_by (admin | tutor) only decides whether
--                                    TUTORS may (tutor_mark_attendance, unchanged). Writes a named audit entry: who, when, before, after.
--   A trial lesson does not count towards the centre's fee: org_active_students_in_month() (migration_attendance.sql, unchanged) only
--   counts students with at least one NON-trial lesson marked attended / absent / late cancelled that month. So flagging a student's only
--   lesson of the month takes them out of that month's count, and unflagging puts them back. Nothing here recomputes a fee that was
--   already worked out for a past month (the screen says so).
-- Who may call: not a member / tutor / parent / switched-off staff / solo organisation / unknown id → NOT_FOUND (same words for all);
-- staff WITHOUT manage_timetable → NOT_ALLOWED.
-- Run on the DEV project first. Safe to run twice.
-- =====================================================================================================

-- ---------------------------------------------------------------- the list gains a Trial filter and a trial count
create or replace function public.staff_lessons(p_org uuid, p_from date, p_to date, p_tutor uuid default null,
                                                p_status text default 'all', p_page int default 1, p_size int default 50) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_attendance_gate(p_org, false); can_tt boolean := org_can(p_org, 'manage_timetable');
        st text := coalesce(nullif(p_status, ''), 'all'); pg int := coalesce(p_page, 1); sz int := coalesce(p_size, 50);
        total int; cnt jsonb; rows jsonb; tutors jsonb;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 62 then
    raise exception 'BAD_RANGE: ask for at most 62 days' using errcode = 'P0001'; end if;
  if st not in ('all', 'unmarked', 'marked', 'trial') then raise exception 'BAD_FILTER: unknown filter' using errcode = 'P0001'; end if;
  if pg < 1 or pg > 100000 then raise exception 'BAD_PAGE: no such page' using errcode = 'P0001'; end if;
  if sz < 1 or sz > 100 then raise exception 'BAD_PAGE: ask for 1 to 100 lessons at a time' using errcode = 'P0001'; end if;
  if p_tutor is not null and not exists (select 1 from memberships m where m.id = p_tutor and m.org_id = p_org) then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;

  with base as (
    select l.id, l.lesson_date, l.start_time, l.end_time, l.subject, l.status, l.attendance, l.trial, l.remarks, l.session_id,
           l.attendance_marked_at, l.taught_by, (l.compensation is null) as no_comp,
           s.id as sid, s.name as sname, s.level as slevel, t.display_name as tname, mb.display_name as mname,
           (l.status = 'cancelled' and l.attendance is null) as closed,
           (l.attendance is null and l.status <> 'cancelled' and l.lesson_date <= today) as due
      from lessons l
      join students s on s.id = l.student_id and s.org_id = l.org_id
      left join memberships t  on t.id = l.taught_by and t.org_id = l.org_id
      left join memberships mb on mb.user_id = l.attendance_marked_by and mb.org_id = l.org_id
     where l.org_id = p_org and l.lesson_date between p_from and p_to and (p_tutor is null or l.taught_by = p_tutor)),
  d as (
    select base.*, case when closed then 'cancelled' when attendance is not null then 'marked' when lesson_date > today then 'future' else 'open' end as state
      from base),
  c as (select count(*)::int as n_all, (count(*) filter (where due))::int as n_unmarked, (count(*) filter (where attendance is not null))::int as n_marked,
                                  (count(*) filter (where trial))::int as n_trial from d),
  pg_rows as (
    select * from d
     where st = 'all' or (st = 'unmarked' and due) or (st = 'marked' and attendance is not null) or (st = 'trial' and trial)
     order by lesson_date, start_time, sname, id
     limit sz offset (pg - 1) * sz)
  select (select row_to_json(c) from c)::jsonb,
         coalesce((select jsonb_agg(jsonb_build_object(
           'lesson_id', id, 'lesson_date', lesson_date, 'start_time', start_time, 'end_time', end_time,
           'student_id', sid, 'student_name', sname, 'student_level', slevel, 'subject', subject,
           'tutor_id', taught_by, 'tutor_name', tname,
           'attendance', attendance, 'status', status, 'state', state, 'trial', trial, 'remarks', remarks,
           'marked_at', attendance_marked_at, 'marked_by_name', mname,
           'charge_pending', (attendance in ('absent', 'cancelled_early', 'late_cancelled') and no_comp),
           'session_id', session_id,
           'can_mark', (can_tt and state = 'open'), 'can_correct', (can_tt and state = 'marked'))
           order by lesson_date, start_time, sname, id) from pg_rows), '[]'::jsonb)
    into cnt, rows;

  total := case st when 'unmarked' then (cnt->>'n_unmarked')::int when 'marked' then (cnt->>'n_marked')::int when 'trial' then (cnt->>'n_trial')::int else (cnt->>'n_all')::int end;
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', m.display_name) order by m.display_name, m.id), '[]'::jsonb) into tutors
    from memberships m where m.org_id = p_org and m.role = 'tutor' and m.status in ('active', 'invited');

  return jsonb_build_object('today', today, 'can_mark', can_tt, 'page', pg, 'size', sz, 'total', total,
                            'counts', jsonb_build_object('all', (cnt->>'n_all')::int, 'unmarked', (cnt->>'n_unmarked')::int,
                                                         'marked', (cnt->>'n_marked')::int, 'trial', (cnt->>'n_trial')::int),
                            'tutors', tutors, 'rows', rows);
end $$;

-- ---------------------------------------------------------------- the toggle
create or replace function public.staff_set_trial(p_lesson uuid, p_trial boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l lessons;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into l from lessons where id = p_lesson;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  perform staff_attendance_gate(l.org_id, true);                         -- member of this centre as owner / staff, with manage_timetable
  if p_trial is null then raise exception 'BAD_VALUE: choose trial or not a trial' using errcode = 'P0001'; end if;
  if l.trial = p_trial then
    raise exception 'NO_CHANGE: the lesson is already %', case when p_trial then 'a trial lesson' else 'not a trial lesson' end using errcode = 'P0001'; end if;

  update lessons set trial = p_trial where id = l.id;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (l.org_id, auth.uid(), 'staff_set_trial', 'lessons', l.id::text,
          jsonb_build_object('trial', l.trial), jsonb_build_object('trial', p_trial));
  return jsonb_build_object('lesson_id', l.id, 'trial', p_trial);
end $$;

revoke all on function public.staff_set_trial(uuid, boolean) from public, anon;
grant execute on function public.staff_set_trial(uuid, boolean) to authenticated;
revoke all on function public.staff_lessons(uuid, date, date, uuid, text, int, int) from public, anon;
grant execute on function public.staff_lessons(uuid, date, date, uuid, text, int, int) to authenticated;
