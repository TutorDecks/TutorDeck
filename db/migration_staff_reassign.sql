-- =====================================================================================================
-- T3 step 8 — reassign a lesson to another tutor, or cover it with a replacement          undo: migration_staff_reassign_down.sql
-- =====================================================================================================
-- Needs migration_staff_slots.sql (it reuses staff_slots_gate and student_tutors) and everything before it (lessons.taught_by / session_id, org settings).
--
-- WHAT IT ADDS
--   lessons.covered_for            who the lesson was MEANT for (memberships.id) when someone else is covering it; null = nobody is covering
--   lesson_locked_reason           internal: why a lesson can no longer change hands (marked / cancelled / paid / invoiced), or null
--   staff_reassign_lesson          write  give one lesson (or the whole class of that day) to another tutor: mode 'reassign' or 'cover'
--   staff_timetable                replaced (same arguments): rows gain covered_for_id / covered_for_name / can_reassign, the answer gains can_edit,
--                                  replacements_allowed, and each tutor says whether they are active
--
-- THE TWO MODES, in plain words
--   cover      a ONE-OFF replacement. The lesson's tutor changes; the weekly slot and the student's assigned tutors do NOT, so next week's lesson is
--              still the original tutor's. lessons.covered_for keeps who it was meant for, so the Timetable says "Covered by X" and the audit log says
--              who covered for whom and why. Handing it back to the original tutor clears covered_for.
--   reassign   the lesson permanently goes to the new tutor (covered_for is cleared: nobody is "covering"). The weekly slot is left alone (change it
--              in Weekly slots). The caller may ALSO choose, as an explicit second choice, to move the student's assigned-tutor link
--              (student_tutors) from the old tutor to the new one. A cover never touches that link and refuses the choice.
--   Either way the lesson moves from the original tutor's tutor_my_lessons list to the new tutor's (that function reads lessons.taught_by and is
--   unchanged), and attendance and pay follow the tutor who taught it.
--
-- THE CENTRE'S OWN RULE: lessons.replacement_tutors (a toggle in the sign-up wizard, default ON, read as of TODAY, a process rule)
--   on   staff may give a lesson that already has a tutor to someone else.
--   off  that is refused with a plain message ("this centre doesn't allow replacement tutors"). A lesson with NO tutor yet can still be given its
--        first tutor: that is not a replacement (the same line lessons_taught_by_guard already draws for anyone writing the table).
--   There is no third value today (the wizard offers a toggle). Nothing is marked "soon": both values are built.
--
-- WHO MAY CALL: an active OWNER or STAFF member of this centre with manage_timetable (owners always). Staff without it: NOT_ALLOWED. A tutor, a
--   parent, switched-off staff, a stranger, a solo organisation, an unknown id: the same NOT_FOUND, so ids can't be probed. Tutors have no
--   function that moves a lesson to another tutor (T6 tutors only schedule their own).
--
-- INTEGRITY (fixed, not a centre choice)
--   * never a lesson that is already marked (it stays with the tutor who taught it), cancelled, paid, or on an invoice;
--   * the new tutor must be an ACTIVE member of THIS centre (owner, staff or tutor);
--   * a class (lessons sharing a session_id) moves together, all or nothing; if any lesson of it is locked nothing moves;
--   * a reason (up to 500 characters) is required whenever a lesson that already has a tutor changes hands; it goes in the audit log.
-- Run on the DEV project first. Safe to run twice.
-- =====================================================================================================

-- ---------------------------------------------------------------- the column
alter table public.lessons add column if not exists covered_for uuid;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'lessons_covered_for_same_org') then
    -- same organisation only; if that person is removed the lesson keeps its organisation (set null on covered_for ONLY)
    alter table public.lessons add constraint lessons_covered_for_same_org
      foreign key (covered_for, org_id) references public.memberships(id, org_id) on delete set null (covered_for);
  end if;
end $$;
create index if not exists lessons_covered_for on public.lessons(covered_for) where covered_for is not null;

-- ---------------------------------------------------------------- why a lesson can't change hands (null = it can)
-- Internal helper; the browser can't call it. Paid is the Ledger's flag; "invoiced" = a current (not replaced) invoice lists the lesson.
create or replace function public.lesson_locked_reason(p_lesson uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when l.attendance is not null then 'MARKED'
    when l.status = 'cancelled' then 'CANCELLED'
    when l.paid then 'PAID'
    when exists (select 1 from invoices i where i.org_id = l.org_id and jsonb_typeof(i.data -> 'lesson_ids') = 'array'
                    and i.data -> 'lesson_ids' @> to_jsonb(l.id::text) and (i.data ->> 'replaced_by') is null) then 'INVOICED'
  end from lessons l where l.id = p_lesson $$;
revoke all on function public.lesson_locked_reason(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- staff_reassign_lesson
create or replace function public.staff_reassign_lesson(p_lesson uuid, p_new_tutor uuid, p_mode text, p_reason text default null,
                                                        p_update_links boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l lessons; cl lessons; today date; md text := lower(trim(coalesce(p_mode, ''))); why text := nullif(trim(coalesce(p_reason, '')), '');
        nt memberships; cfg jsonb; allowed boolean; ids uuid[]; locked text; orig uuid; new_cf uuid; old_tutor uuid;
        sid uuid; ended int := 0; added int := 0; n_ended int; before_j jsonb := '[]'::jsonb; link_ids uuid[];
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into l from lessons where id = p_lesson;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := staff_slots_gate(l.org_id, true);                                            -- NOT_FOUND for strangers, NOT_ALLOWED without manage_timetable

  if md not in ('reassign', 'cover') then raise exception 'BAD_MODE: choose cover or reassign' using errcode = 'P0001'; end if;
  if p_new_tutor is null then raise exception 'PICK_TUTOR: choose who will teach this lesson' using errcode = 'P0001'; end if;
  if why is not null and length(why) > 500 then raise exception 'TOO_LONG: keep the reason under 500 characters' using errcode = 'P0001'; end if;
  if coalesce(p_update_links, false) and md = 'cover' then
    raise exception 'LINK_NOT_FOR_COVER: a cover is one lesson only, so it never changes who a student is assigned to' using errcode = 'P0001'; end if;

  select * into nt from memberships m where m.id = p_new_tutor and m.org_id = l.org_id and m.role in ('tutor', 'staff', 'owner') and m.status = 'active';
  if not found then raise exception 'NOT_AVAILABLE: that person can''t be given lessons at this centre (they must be an active member here)' using errcode = 'P0001'; end if;
  if l.taught_by is not distinct from p_new_tutor then
    raise exception 'NO_CHANGE: that tutor already teaches this lesson' using errcode = 'P0001'; end if;

  if l.taught_by is null then
    if md = 'cover' then raise exception 'NO_TUTOR_TO_COVER: this lesson has no tutor yet, so there is nobody to cover for. Use Assign instead' using errcode = 'P0001'; end if;
  else
    -- a lesson that already has a tutor changing hands is a replacement: the centre's own rule decides (read as of today)
    cfg := org_settings_on(l.org_id, today) #> '{lessons,replacement_tutors}';
    allowed := case when jsonb_typeof(cfg) = 'boolean' then (cfg #>> '{}')::boolean else true end;      -- missing = on (the default)
    if not allowed then
      raise exception 'REPLACEMENT_OFF: this centre doesn''t allow replacement tutors. An owner can switch this on in the centre settings' using errcode = 'P0001'; end if;
    if why is null then raise exception 'REASON_REQUIRED: say why this lesson is changing tutor. It is kept on record' using errcode = 'P0001'; end if;
  end if;

  -- the lesson, or the whole class of that day (lessons sharing a session_id): all or nothing
  select coalesce(array_agg(x.id order by x.id), array[l.id]) into ids from lessons x
   where x.org_id = l.org_id and (x.id = l.id or (l.session_id is not null and x.session_id = l.session_id));
  perform 1 from lessons x where x.id = any(ids) order by x.id for update;
  foreach sid in array ids loop
    locked := lesson_locked_reason(sid);
    if locked is not null then
      raise exception '%', case locked
        when 'MARKED'    then 'ALREADY_MARKED: this lesson is already marked, so it stays with the tutor who taught it'
        when 'CANCELLED' then 'CANCELLED: this lesson was cancelled'
        when 'PAID'      then 'PAID: this lesson is already paid, so it can''t change hands'
        else                  'INVOICED: this lesson is on an invoice, so it can''t change hands' end
        || case when array_length(ids, 1) > 1 then ' (it is part of a class that moves together)' else '' end using errcode = 'P0001';
    end if;
  end loop;

  -- move them
  for cl in select * from lessons x where x.id = any(ids) order by x.id loop
    before_j := before_j || jsonb_build_object('lesson_id', cl.id, 'taught_by', cl.taught_by, 'covered_for', cl.covered_for);
    if md = 'cover' then
      orig := coalesce(cl.covered_for, cl.taught_by);                                    -- who it was meant for stays the same however often it is covered
      new_cf := case when orig is distinct from p_new_tutor then orig end;              -- handed back to the original tutor = nobody is covering
    else new_cf := null; end if;
    update lessons set taught_by = p_new_tutor, covered_for = new_cf where id = cl.id;
  end loop;

  -- reassign only, and only when asked: the student's assigned-tutor link follows (the old tutor's ends, the new tutor's starts)
  if coalesce(p_update_links, false) then
    for sid in select distinct x.student_id from lessons x where x.id = any(ids) loop
      old_tutor := (select (e ->> 'taught_by')::uuid from jsonb_array_elements(before_j) e
                     join lessons y on y.id = (e ->> 'lesson_id')::uuid where y.student_id = sid limit 1);
      if old_tutor is not null then
        update student_tutors set active = false, until = today where org_id = l.org_id and student_id = sid and membership_id = old_tutor and active;
        get diagnostics n_ended = row_count; ended := ended + n_ended;
      end if;
      if not exists (select 1 from student_tutors x where x.org_id = l.org_id and x.student_id = sid and x.membership_id = p_new_tutor and x.active) then
        insert into student_tutors(org_id, student_id, membership_id, since, created_by) values (l.org_id, sid, p_new_tutor, today, auth.uid());
        added := added + 1;
      end if;
    end loop;
  end if;

  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (l.org_id, auth.uid(), 'staff_reassign_lesson', 'lessons', l.id::text,
          jsonb_build_object('lessons', before_j),
          jsonb_build_object('mode', md, 'new_tutor', p_new_tutor, 'new_tutor_name', nt.display_name, 'lessons', to_jsonb(ids), 'reason', why,
                             'covered_for', (select covered_for from lessons where id = l.id),
                             'links_updated', coalesce(p_update_links, false), 'links_ended', ended, 'links_added', added));
  return jsonb_build_object('lesson_id', l.id, 'lessons', array_length(ids, 1), 'mode', md, 'tutor_id', p_new_tutor,
                            'tutor_name', coalesce(nt.display_name, 'Tutor'), 'covered_for', (select covered_for from lessons where id = l.id),
                            'links_ended', ended, 'links_added', added);
end $$;
revoke all on function public.staff_reassign_lesson(uuid, uuid, text, text, boolean) from public, anon;
grant execute on function public.staff_reassign_lesson(uuid, uuid, text, text, boolean) to authenticated;

-- ---------------------------------------------------------------- staff_timetable: who is covering, and whether the lesson can still change hands
-- Same arguments and rules as migration_staff_slots.sql. New: per row covered_for_id / covered_for_name ('Former tutor' when that person has been
-- switched off) and can_reassign (not marked, cancelled, paid or invoiced: a yes/no, no money); on the answer can_edit (the caller has
-- manage_timetable) and replacements_allowed (the centre's lessons.replacement_tutors, as of today); each tutor says whether they are active.
create or replace function public.staff_timetable(p_org uuid, p_from date, p_to date, p_tutor uuid default null, p_branch uuid default null,
                                                  p_student uuid default null, p_page int default 1, p_notutor boolean default false,
                                                  p_size int default 50) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_attendance_gate(p_org, false); can_ed boolean := org_can(p_org, 'manage_timetable'); rep_on boolean;
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

  rep_on := case when jsonb_typeof(org_settings_on(p_org, today) #> '{lessons,replacement_tutors}') = 'boolean'
                 then (org_settings_on(p_org, today) #>> '{lessons,replacement_tutors}')::boolean else true end;      -- missing = on

  -- holidays touching the range (a branch's own holiday is labelled with the branch, so it can't be mistaken for the whole centre's)
  select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'name', h.name, 'starts_on', h.starts_on, 'ends_on', h.ends_on,
                                               'branch_id', h.branch_id, 'branch_name', b.name) order by h.starts_on, h.name, h.id), '[]'::jsonb)
    into hols
    from holidays h left join branches b on b.id = h.branch_id and b.org_id = h.org_id
   where h.org_id = p_org and h.starts_on <= p_to and h.ends_on >= p_from
     and (p_branch is null or h.branch_id is null or h.branch_id = p_branch);

  with base as (
    select l.id, l.lesson_date, l.start_time, l.end_time, l.subject, l.status, l.attendance, l.trial, l.postponed, l.session_id, l.taught_by, l.covered_for,
           s.id as sid, s.name as sname, s.level as slevel, s.online_link as slink, t.status as tstatus, t.display_name as tname, cf.status as cfstatus, cf.display_name as cfname,
           (lesson_locked_reason(l.id) is null) as can_re,
           (l.status = 'cancelled' and l.attendance is null) as closed,
           (l.taught_by is null and l.status <> 'cancelled') as no_tutor,
           (select h.name from holidays h where h.org_id = p_org and l.lesson_date between h.starts_on and h.ends_on
               and (h.branch_id is null or h.branch_id = p_branch) order by h.starts_on, h.name limit 1) as holiday
      from lessons l
      join students s on s.id = l.student_id and s.org_id = l.org_id
      left join memberships t on t.id = l.taught_by and t.org_id = l.org_id
      left join memberships cf on cf.id = l.covered_for and cf.org_id = l.org_id
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
           'online_link', slink,
           'covered_for_id', covered_for,
           'covered_for_name', case when covered_for is null then null when cfstatus is null or cfstatus = 'disabled' then 'Former tutor' else coalesce(cfname, 'Tutor') end,
           'can_reassign', can_re)
           order by lesson_date, start_time, sname, id) from pg_rows), '[]'::jsonb)
    into cnt, rows;
  total := case when nt then (cnt->>'n_notutor')::int else (cnt->>'n_all')::int end;

  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', m.display_name, 'active', (m.status = 'active')) order by m.display_name, m.id), '[]'::jsonb) into tutors
    from memberships m where m.org_id = p_org and m.role = 'tutor' and m.status in ('active', 'invited');
  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name) order by b.name, b.id), '[]'::jsonb) into branches
    from branches b where b.org_id = p_org;
  -- who has a lesson in this range (for the student filter): at most 300 names, and the page says so when there are more
  select count(distinct l.student_id) into n_studs from lessons l where l.org_id = p_org and l.lesson_date between p_from and p_to;
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name) order by x.name, x.id), '[]'::jsonb) into studs
    from (select s.id, s.name from students s
           where s.org_id = p_org and exists (select 1 from lessons l where l.org_id = p_org and l.student_id = s.id and l.lesson_date between p_from and p_to)
           order by s.name, s.id limit 300) x;

  return jsonb_build_object('today', today, 'can_edit', can_ed, 'replacements_allowed', rep_on, 'page', pg, 'size', sz, 'total', total, 'counts', cnt, 'holidays', hols,
                            'tutors', tutors, 'branches', branches, 'students', studs, 'students_more', n_studs > 300, 'rows', rows);
end $$;

revoke all on function public.staff_timetable(uuid, date, date, uuid, uuid, uuid, int, boolean, int) from public, anon;
grant execute on function public.staff_timetable(uuid, date, date, uuid, uuid, uuid, int, boolean, int) to authenticated;
