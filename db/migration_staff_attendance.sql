-- =====================================================================================================
-- T3 step 3 — centre Attendance for owners and staff: view, mark, correct        undo: migration_staff_attendance_down.sql
-- =====================================================================================================
-- Needs migration_org_foundation.sql, migration_attendance.sql and migration_tutor_access.sql (lessons.attendance, taught_by, the stamp trigger).
-- ADD-ONLY: one new trigger on `lessons` and four new functions; no table or column is touched.
--
-- PART 1 — CLOSING THE INTEGRITY HOLE (the rules now live in the table, so they hold for EVERY writer)
--   Until now "not before the lesson's day" and "never over someone else's mark" were only checked inside tutor_mark_attendance. Staff and
--   owners write `lessons` straight through the org_write policy, so a script or a copy of the app could mark tomorrow's lesson, or overwrite a
--   tutor's mark, and nobody would be asked why. The trigger lessons_attendance_guard (centres only) now refuses, for anyone signed in:
--     * setting attendance on a lesson whose day (in the CENTRE's timezone) hasn't started        → TOO_EARLY
--     * changing or clearing a mark that somebody ELSE made                                        → ALREADY_MARKED
--     * editing attendance_marked_by / attendance_marked_at on their own (a back door to the rule above) → LOCKED
--   The ONE way past the second and third rule is staff_correct_attendance(), which sets a transaction-local flag naming that one lesson
--   (td.attendance_override = the lesson id, like td.deleting_org) after checking permission and a written reason. "Too early" has NO way
--   past, not even for the function. Solo tutors' lessons never reach the guard (it returns at once unless the lesson's organisation is a
--   centre) and server jobs with no signed-in user (auth.uid() is null: billing, the account-deletion function) are not "someone marking".
--
-- PART 2 — WHAT STAFF CAN DO (decided by the owner, 2026-11-25)
--   staff_lessons(org, from, to, tutor, status, page, size)   the list for a day or a week (at most 62 days), filters, server-side paging.
--                                                             Any owner / staff member may LOOK. Returns NO money (no rate, amount, paid,
--                                                             compensation or *_cents), only the yes/no "charge pending".
--   staff_mark_attendance(lesson, attendance, remarks)        first mark of a lesson, from its day onward. Needs manage_timetable.
--   staff_correct_attendance(lesson, attendance, reason)      change a mark somebody already made. Needs manage_timetable AND a written
--                                                             reason; writes a named audit entry with the reason. Tutors never.
--   * Staff can ALWAYS mark and correct. lessons.attendance_by (tutor | admin), attendance_window_days and cancellations_marked_by only
--     govern TUTORS (tutor_mark_attendance); they are not consulted here. Staff may set all four values, including both cancellations.
--   * Status follows attendance, set by the existing stamp trigger (never typed): attended = done; absent / cancelled_early / late_cancelled =
--     cancelled. The charge for an absent / cancelled lesson is its COMPENSATION: a number someone types, 0 if the family isn't charged,
--     null = "charge pending". THIS step never types it (that is step 4); marking absent leaves it null, marking attended clears it.
--     lessons.compensation_entered_by (admin | tutor) only decides who types it later; billing.absences.mode only pre-fills the suggestion later.
--   * lessons.remarks.required is the centre's rule for marking ATTENDED (same words as for tutors). Correcting an old mark does not re-require remarks.
--   * A lesson cancelled by staff with no attendance mark is CLOSED: it can't be marked (same as the tutor function).
--   * Nothing needs a class, a room or a branch: a remote 1-to-1 centre marks lessons with just a student and a time.
--
-- WHO MAY CALL
--   not a member / a tutor / a parent / switched-off staff / a solo organisation / an unknown id  → NOT_FOUND (same words for all, so ids can't be probed)
--   staff WITHOUT manage_timetable (look only)                                                   → NOT_ALLOWED when they try to mark or correct
-- Run on the DEV project first. Safe to run twice.
-- =====================================================================================================

-- ---------------------------------------------------------------- PART 1: the guard
create or replace function public.lessons_attendance_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); tz text; today date; override boolean;
begin
  if me is null then return new; end if;                                   -- server jobs, not a person marking
  select o.timezone into tz from organisations o where o.id = new.org_id and o.kind = 'centre';
  if tz is null then return new; end if;                                   -- solo tutors' lessons: nothing changes
  today := (now() at time zone tz)::date;                                  -- the centre's own calendar day, not the server's
  override := coalesce(current_setting('td.attendance_override', true), '') = new.id::text;

  if tg_op = 'INSERT' then
    if new.attendance is not null and new.lesson_date > today then
      raise exception 'TOO_EARLY: a lesson can be marked from its day onward' using errcode = 'P0001'; end if;
    return new;
  end if;

  if new.attendance is not distinct from old.attendance then
    -- the stamp columns are the proof of who marked; they change only together with the mark (the stamp trigger) or by a correction
    if (new.attendance_marked_by is distinct from old.attendance_marked_by or new.attendance_marked_at is distinct from old.attendance_marked_at)
       and not override then
      raise exception 'LOCKED: who marked a lesson and when can''t be edited by hand' using errcode = 'P0001'; end if;
    return new;
  end if;

  if new.attendance is not null and new.lesson_date > today then
    raise exception 'TOO_EARLY: a lesson can be marked from its day onward' using errcode = 'P0001'; end if;
  if old.attendance is not null and old.attendance_marked_by is distinct from me and not override then
    raise exception 'ALREADY_MARKED: someone else already marked this lesson; use Correct (with a reason) to change it' using errcode = 'P0001'; end if;
  return new;
end $$;
-- fires BEFORE the stamp trigger (triggers run in name order), so it sees what the writer asked for, not what the stamp then fills in
drop trigger if exists lessons_attendance_guard on public.lessons;
create trigger lessons_attendance_guard
  before insert or update of attendance, attendance_marked_by, attendance_marked_at on public.lessons
  for each row execute function public.lessons_attendance_guard();

-- ---------------------------------------------------------------- the gate every staff attendance function starts with (internal)
-- Returns the centre's own "today". p_write = the caller must also hold manage_timetable.
create or replace function public.staff_attendance_gate(p_org uuid, p_write boolean) returns date
language plpgsql stable security definer set search_path = public as $$
declare tz text;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select o.timezone into tz from organisations o where o.id = p_org and o.kind = 'centre';
  if tz is null or not exists (select 1 from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active'
                               and m.role in ('owner', 'staff')) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if p_write and not org_can(p_org, 'manage_timetable') then
    raise exception 'NOT_ALLOWED: your account can''t mark attendance at this centre' using errcode = '42501';
  end if;
  return (now() at time zone tz)::date;
end $$;

-- ---------------------------------------------------------------- PART 2a: the list
-- p_status: 'all' | 'unmarked' (due: its day has started, not cancelled by staff, no mark) | 'marked'. p_tutor: a memberships.id, or null for everyone.
-- state of a row: 'future' (its day hasn't started: no buttons) | 'open' (can be marked) | 'marked' (can be corrected) | 'cancelled' (closed by staff).
-- can_mark / can_correct already include the caller's permission, so the screen doesn't guess.
create or replace function public.staff_lessons(p_org uuid, p_from date, p_to date, p_tutor uuid default null,
                                                p_status text default 'all', p_page int default 1, p_size int default 50) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_attendance_gate(p_org, false); can_tt boolean := org_can(p_org, 'manage_timetable');
        st text := coalesce(nullif(p_status, ''), 'all'); pg int := coalesce(p_page, 1); sz int := coalesce(p_size, 50);
        total int; cnt jsonb; rows jsonb; tutors jsonb;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 62 then
    raise exception 'BAD_RANGE: ask for at most 62 days' using errcode = 'P0001'; end if;
  if st not in ('all', 'unmarked', 'marked') then raise exception 'BAD_FILTER: unknown filter' using errcode = 'P0001'; end if;
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
  c as (select count(*)::int as n_all, (count(*) filter (where due))::int as n_unmarked, (count(*) filter (where attendance is not null))::int as n_marked from d),
  pg_rows as (
    select * from d
     where st = 'all' or (st = 'unmarked' and due) or (st = 'marked' and attendance is not null)
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

  total := case st when 'unmarked' then (cnt->>'n_unmarked')::int when 'marked' then (cnt->>'n_marked')::int else (cnt->>'n_all')::int end;
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', m.display_name) order by m.display_name, m.id), '[]'::jsonb) into tutors
    from memberships m where m.org_id = p_org and m.role = 'tutor' and m.status in ('active', 'invited');

  return jsonb_build_object('today', today, 'can_mark', can_tt, 'page', pg, 'size', sz, 'total', total,
                            'counts', jsonb_build_object('all', (cnt->>'n_all')::int, 'unmarked', (cnt->>'n_unmarked')::int,
                                                         'marked', (cnt->>'n_marked')::int),
                            'tutors', tutors, 'rows', rows);
end $$;

-- ---------------------------------------------------------------- PART 2b: the first mark
create or replace function public.staff_mark_attendance(p_lesson uuid, p_attendance text, p_remarks text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l lessons; cfg jsonb; today date; new_remarks text; new_status text;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into l from lessons where id = p_lesson;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := staff_attendance_gate(l.org_id, true);
  cfg := org_settings_on(l.org_id, current_date);

  if p_attendance is null or p_attendance not in ('attended', 'absent', 'late_cancelled', 'cancelled_early') then
    raise exception 'BAD_VALUE: choose attended, absent, late cancelled or cancelled in time' using errcode = 'P0001'; end if;
  if l.status = 'cancelled' and l.attendance is null then
    raise exception 'CANCELLED: this lesson was cancelled' using errcode = 'P0001'; end if;
  if l.attendance is not null then
    raise exception 'ALREADY_MARKED: this lesson is already marked; use Correct (with a reason) to change it' using errcode = 'P0001'; end if;
  if l.lesson_date > today then
    raise exception 'TOO_EARLY: a lesson can be marked from its day onward' using errcode = 'P0001'; end if;
  if length(coalesce(p_remarks, '')) > 2000 then
    raise exception 'TOO_LONG: keep the remarks under 2000 characters' using errcode = 'P0001'; end if;

  new_remarks := case when p_remarks is null then l.remarks else nullif(trim(p_remarks), '') end;
  -- the centre's own rule: a lesson that took place needs its remarks
  if p_attendance = 'attended' and coalesce((cfg #>> '{lessons,remarks,required}')::boolean, false) and new_remarks is null then
    raise exception 'REMARKS_REQUIRED: this centre needs remarks before a lesson is marked attended' using errcode = 'P0001'; end if;

  update lessons set attendance = p_attendance, remarks = new_remarks,
                     remarks_at = case when p_remarks is null then remarks_at else now() end
   where id = l.id returning status into new_status;

  insert into audit_log(org_id, actor, action, table_name, row_id, after)
  values (l.org_id, auth.uid(), 'staff_mark_attendance', 'lessons', l.id::text,
          jsonb_build_object('attendance', p_attendance, 'status', new_status, 'remarks_set', p_remarks is not null));
  return jsonb_build_object('lesson_id', l.id, 'attendance', p_attendance, 'status', new_status);
end $$;

-- ---------------------------------------------------------------- PART 2c: the correction (the only way over someone else's mark)
create or replace function public.staff_correct_attendance(p_lesson uuid, p_attendance text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l lessons; today date; why text := nullif(trim(coalesce(p_reason, '')), ''); new_status text;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into l from lessons where id = p_lesson;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := staff_attendance_gate(l.org_id, true);

  if p_attendance is null or p_attendance not in ('attended', 'absent', 'late_cancelled', 'cancelled_early') then
    raise exception 'BAD_VALUE: choose attended, absent, late cancelled or cancelled in time' using errcode = 'P0001'; end if;
  if why is null then raise exception 'REASON_REQUIRED: say why you are changing this mark' using errcode = 'P0001'; end if;
  if length(why) > 500 then raise exception 'TOO_LONG: keep the reason under 500 characters' using errcode = 'P0001'; end if;
  if l.attendance is null then
    raise exception 'NOT_MARKED: this lesson hasn''t been marked yet; mark it instead' using errcode = 'P0001'; end if;
  if l.attendance = p_attendance then
    raise exception 'NO_CHANGE: the lesson is already marked that way' using errcode = 'P0001'; end if;
  if l.lesson_date > today then
    raise exception 'TOO_EARLY: a lesson can be marked from its day onward' using errcode = 'P0001'; end if;

  -- the flag names THIS lesson only and lasts for this transaction; the guard still refuses "too early" even with it
  perform set_config('td.attendance_override', l.id::text, true);
  update lessons set attendance = p_attendance where id = l.id returning status into new_status;
  perform set_config('td.attendance_override', '', true);

  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (l.org_id, auth.uid(), 'staff_correct_attendance', 'lessons', l.id::text,
          jsonb_build_object('attendance', l.attendance, 'status', l.status, 'marked_by', l.attendance_marked_by, 'marked_at', l.attendance_marked_at),
          jsonb_build_object('attendance', p_attendance, 'status', new_status, 'reason', why));
  return jsonb_build_object('lesson_id', l.id, 'attendance', p_attendance, 'status', new_status);
end $$;

-- ---------------------------------------------------------------- who may call what
revoke all on function public.staff_lessons(uuid, date, date, uuid, text, int, int) from public, anon;
revoke all on function public.staff_mark_attendance(uuid, text, text) from public, anon;
revoke all on function public.staff_correct_attendance(uuid, text, text) from public, anon;
grant execute on function public.staff_lessons(uuid, date, date, uuid, text, int, int) to authenticated;
grant execute on function public.staff_mark_attendance(uuid, text, text) to authenticated;
grant execute on function public.staff_correct_attendance(uuid, text, text) to authenticated;
revoke all on function public.staff_attendance_gate(uuid, boolean) from public, anon, authenticated;
revoke all on function public.lessons_attendance_guard() from public, anon, authenticated;
