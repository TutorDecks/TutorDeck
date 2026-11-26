-- =====================================================================================================
-- T3 step 6 — the centre Timetable, READ ONLY: staff_timetable(...)                undo: migration_staff_timetable_down.sql
-- =====================================================================================================
-- Needs migration_staff_attendance.sql (it reuses staff_attendance_gate) and everything before it (lessons.taught_by, attendance, trial, holidays).
-- ADD-ONLY: one new function; no table, column, trigger or policy is touched. Nothing here writes. (Weekly slots, the generator and moving a
-- lesson are step 7+.)
--
-- WHAT IT IS: the lessons of a date range (at most 62 days; the page asks for one week), as a list the phone can show day by day, plus the
-- holidays that fall in the range. One call returns everything the screen draws.
--
-- WHO MAY CALL (decided in the T3 plan, section 1: "Timetable: view = any owner / staff")
--   an active OWNER or STAFF member of this centre, whatever their permissions. A tutor, a parent, switched-off staff, a stranger, a solo
--   organisation, an unknown id: the same NOT_FOUND, so ids can't be probed. A tutor never gets this (they have only tutor_my_lessons).
--
-- WHAT COMES BACK (explicit columns, never l.*): NO MONEY (no rate, amount, paid, compensation, *_cents; a lesson's price is not needed to read
--   a timetable) and no phone numbers or guardians. Per lesson: date, time, duration, student name and level, subject, tutor (name, or
--   'Former tutor' when the person has since been switched off, or null = NO TUTOR), trial, attendance state, cancelled, postponed, holiday
--   (name) and the class (session_id) it belongs to.
--   * no_tutor is true for a lesson with no tutor that is NOT cancelled: exactly the lessons staff_home counts as "no tutor, next 14 days",
--     so the Home tile and this list always agree.
--   * online_link: there is no such column yet (the lesson link arrives with T6 / step 7), so it is always null and the page says "Not set".
--   * Nothing needs a room or a branch: a remote 1-to-1 centre has neither, and every filter below is optional.
--
-- FILTERS (all optional, all checked to belong to THIS centre, else NOT_FOUND)
--   p_tutor     a memberships.id
--   p_student   a students.id
--   p_notutor   true = only lessons nobody teaches yet (what the Home tile links to)
--   p_branch    a branches.id. LESSONS DO NOT CARRY A BRANCH TODAY (no column on lessons, students or weekly slots), so this can't narrow the
--               lessons; it chooses which HOLIDAYS apply: the whole-centre ones plus that branch's. With no branch chosen every holiday shows
--               (a branch's own holiday is named after its branch) but only whole-centre holidays flag a lesson. Real branch filtering of
--               lessons arrives with rooms in step 7.
--   paging      p_page / p_size (1..100, default 50), server-side, so a 400-student centre never sends a month of lessons at once.
--
-- DAYS are the centre's own calendar days (organisations.timezone). Run on the DEV project first. Safe to run twice.
-- =====================================================================================================
create or replace function public.staff_timetable(p_org uuid, p_from date, p_to date, p_tutor uuid default null, p_branch uuid default null,
                                                  p_student uuid default null, p_page int default 1, p_notutor boolean default false,
                                                  p_size int default 50) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_attendance_gate(p_org, false);
        pg int := coalesce(p_page, 1); sz int := coalesce(p_size, 50); nt boolean := coalesce(p_notutor, false);
        cnt jsonb; rows jsonb; tutors jsonb; branches jsonb; studs jsonb; hols jsonb; total int; n_studs int;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 62 then
    raise exception 'BAD_RANGE: ask for at most 62 days' using errcode = 'P0001'; end if;
  if pg < 1 or pg > 100000 then raise exception 'BAD_PAGE: no such page' using errcode = 'P0001'; end if;
  if sz < 1 or sz > 100 then raise exception 'BAD_PAGE: ask for 1 to 100 lessons at a time' using errcode = 'P0001'; end if;
  if p_tutor is not null and not exists (select 1 from memberships m where m.id = p_tutor and m.org_id = p_org) then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_branch is not null and not exists (select 1 from branches b where b.id = p_branch and b.org_id = p_org) then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_student is not null and not exists (select 1 from students s where s.id = p_student and s.org_id = p_org) then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;

  -- holidays touching the range (a branch's own holiday is labelled with the branch, so it can't be mistaken for the whole centre's)
  select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'name', h.name, 'starts_on', h.starts_on, 'ends_on', h.ends_on,
                                               'branch_id', h.branch_id, 'branch_name', b.name) order by h.starts_on, h.name, h.id), '[]'::jsonb)
    into hols
    from holidays h left join branches b on b.id = h.branch_id and b.org_id = h.org_id
   where h.org_id = p_org and h.starts_on <= p_to and h.ends_on >= p_from
     and (p_branch is null or h.branch_id is null or h.branch_id = p_branch);

  with base as (
    select l.id, l.lesson_date, l.start_time, l.end_time, l.subject, l.status, l.attendance, l.trial, l.postponed, l.session_id, l.taught_by,
           s.id as sid, s.name as sname, s.level as slevel, t.status as tstatus, t.display_name as tname,
           (l.status = 'cancelled' and l.attendance is null) as closed,
           (l.taught_by is null and l.status <> 'cancelled') as no_tutor,
           (select h.name from holidays h where h.org_id = p_org and l.lesson_date between h.starts_on and h.ends_on
               and (h.branch_id is null or h.branch_id = p_branch) order by h.starts_on, h.name limit 1) as holiday
      from lessons l
      join students s on s.id = l.student_id and s.org_id = l.org_id
      left join memberships t on t.id = l.taught_by and t.org_id = l.org_id
     where l.org_id = p_org and l.lesson_date between p_from and p_to
       and (p_tutor is null or l.taught_by = p_tutor) and (p_student is null or l.student_id = p_student)),
  d as (
    select base.*, case when closed then 'cancelled' when attendance is not null then 'marked' when lesson_date > today then 'future' else 'open' end as state
      from base),
  c as (select count(*)::int as n_all, (count(*) filter (where no_tutor))::int as n_notutor,
               (count(*) filter (where status = 'cancelled'))::int as n_cancelled, (count(*) filter (where holiday is not null))::int as n_holiday from d),
  pg_rows as (
    select * from d where (not nt or no_tutor)
     order by lesson_date, start_time, sname, id
     limit sz offset (pg - 1) * sz)
  select (select row_to_json(c) from c)::jsonb,
         coalesce((select jsonb_agg(jsonb_build_object(
           'lesson_id', id, 'lesson_date', lesson_date, 'start_time', start_time, 'end_time', end_time,
           'minutes', (extract(epoch from (end_time - start_time)) / 60)::int,
           'student_id', sid, 'student_name', sname, 'student_level', slevel, 'subject', subject,
           'tutor_id', taught_by,
           'tutor_name', case when taught_by is null then null when tstatus is null or tstatus = 'disabled' then 'Former tutor' else coalesce(tname, 'Tutor') end,
           'no_tutor', no_tutor, 'trial', trial, 'attendance', attendance, 'state', state,
           'cancelled', (status = 'cancelled'), 'postponed', postponed, 'holiday', holiday, 'session_id', session_id,
           'online_link', null)
           order by lesson_date, start_time, sname, id) from pg_rows), '[]'::jsonb)
    into cnt, rows;
  total := case when nt then (cnt->>'n_notutor')::int else (cnt->>'n_all')::int end;

  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', m.display_name) order by m.display_name, m.id), '[]'::jsonb) into tutors
    from memberships m where m.org_id = p_org and m.role = 'tutor' and m.status in ('active', 'invited');
  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name) order by b.name, b.id), '[]'::jsonb) into branches
    from branches b where b.org_id = p_org;
  -- who has a lesson in this range (for the student filter): at most 300 names, and the page says so when there are more
  select count(distinct l.student_id) into n_studs from lessons l where l.org_id = p_org and l.lesson_date between p_from and p_to;
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name) order by x.name, x.id), '[]'::jsonb) into studs
    from (select s.id, s.name from students s
           where s.org_id = p_org and exists (select 1 from lessons l where l.org_id = p_org and l.student_id = s.id and l.lesson_date between p_from and p_to)
           order by s.name, s.id limit 300) x;

  return jsonb_build_object('today', today, 'page', pg, 'size', sz, 'total', total, 'counts', cnt, 'holidays', hols,
                            'tutors', tutors, 'branches', branches, 'students', studs, 'students_more', n_studs > 300, 'rows', rows);
end $$;

revoke all on function public.staff_timetable(uuid, date, date, uuid, uuid, uuid, int, boolean, int) from public, anon;
grant execute on function public.staff_timetable(uuid, date, date, uuid, uuid, uuid, int, boolean, int) to authenticated;
