-- =====================================================================================================
-- T3.9 — timetable changes and the People list                                           undo: migration_slot_changes_down.sql
-- =====================================================================================================
-- Needs everything before it, in this order: ... staff_slots, staff_reassign, tutor_schedule, centre_money (centre_invoice_lines), invites (the
-- invite send log), payout_permission. Run it LAST of the current migrations. Safe to run twice. DEV first; never on LIVE before the code ships.
--
-- WHAT IT ADDS
--   recurring_slots.starts_on / stopped_from   a weekly slot can start on, and stop from, a chosen day (null = no limit). The slot's `active` flag
--                                              stays true while its stop day is still to come, and the generator and every list honour the dates.
--   lesson_change_blocker(lesson)              internal: why a lesson must not be touched (MARKED, CANCELLED, PAID, INVOICED), null = free to change.
--                                              "Invoiced" means listed on a current solo invoice OR on any centre invoice line (draft, issued or void: a
--                                              lesson that has ever been put on a document is left alone).
--   staff_stop_slot_from(...)                  stop a weekly slot (or the whole class) FROM a day; optionally also remove its later lessons that are not
--                                              marked, paid or invoiced. p_dry = true only COUNTS, so the screen can show the number before confirming.
--   staff_slot_student(...)                    add a student to / remove a student from an existing weekly slot, from a day (p_dry = count only).
--   staff_holiday_cancel(...)                  cancel the lessons already on a holiday's days (not marked, paid or invoiced), no charge (p_dry = count only).
--   staff_people(org)                          the centre's people for the People tab: owner/staff/tutors with role, status and invite state. No money.
--   staff_generate_lessons                     replaced (same arguments): now up to 26 weeks (182 days) at a time instead of 62 days, and the answer
--                                              says how many `days`. Internally split: staff_generate_core does the work for all slots or for a few.
--   staff_slots / staff_save_slot / tutor_my_slots   replaced (same arguments): they leave out a slot once its stop day has come, and saving a slot
--                                              with a tutor now ADDS that tutor to each student's assigned tutors (never removes anyone), and says so.
--
-- WHO MAY CALL (the same words as the rest of the staff screens)
--   writing   an active OWNER or STAFF member of this centre with manage_timetable (owners always)
--   People    the owner (everyone), or staff with manage_tutors (the tutors). Staff without it get NOT_ALLOWED. Never an email, a phone, pay or any money.
--   a tutor / a parent / switched-off staff / a stranger / a solo organisation / an unknown id  →  NOT_FOUND (same words, so ids can't be probed)
--
-- THE RULE FOR EVERY "REMOVE" OR "CANCEL" HERE
--   A lesson that has been MARKED (attendance set), is PAID, or sits on an INVOICE (solo or centre) is never touched. A lesson already cancelled stays
--   as it is. Only lessons nobody has acted on are removed or cancelled. Every call is idempotent: pressing it twice changes nothing the second time.
--   Every real change is written to the audit log with the counts. Lessons in the past are never changed (the days start today at the earliest).
--
-- CENTRE SETTING (product principle: two centres could want this differently)
--   lessons.auto_assign_tutors   boolean, default ON (missing = on). When a weekly slot with a tutor is saved, the tutor is added to the student's
--                                assigned tutors. A centre that wants to assign tutors by hand switches it off in the wizard (assets/js/org-settings.js).
--                                Read as of TODAY (a process rule). Not validated by org_validate_settings (a missing or non-boolean value = on).
-- =====================================================================================================

alter table public.recurring_slots add column if not exists starts_on date;          -- first day the slot runs (null = from the start)
alter table public.recurring_slots add column if not exists stopped_from date;       -- first day it no longer runs (null = until stopped)

-- ---------------------------------------------------------------- why a lesson must be left alone (null = free to change)
create or replace function public.lesson_change_blocker(p_lesson uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(lesson_locked_reason(l.id),
                  case when exists (select 1 from centre_invoice_lines cl where cl.lesson_id = l.id and cl.org_id = l.org_id) then 'INVOICED' end)
    from lessons l where l.id = p_lesson $$;
revoke all on function public.lesson_change_blocker(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- 3. the weekly slots (read): leaves out slots whose stop day has come, and says when one stops

create or replace function public.staff_slots(p_org uuid, p_tutor uuid default null, p_q text default null, p_page int default 1, p_size int default 25)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare today date := staff_slots_gate(p_org, false); can_edit boolean := org_can(p_org, 'manage_timetable');
        q text := nullif(trim(coalesce(p_q, '')), ''); pat text; pg int := coalesce(p_page, 1); sz int := coalesce(p_size, 25);
        rows jsonb; tutors jsonb; total int; gen date;
begin
  if q is not null and length(q) > 100 then raise exception 'BAD_SEARCH: search for at most 100 characters' using errcode = 'P0001'; end if;
  if pg < 1 or pg > 100000 then raise exception 'BAD_PAGE: no such page' using errcode = 'P0001'; end if;
  if sz < 1 or sz > 100 then raise exception 'BAD_PAGE: ask for 1 to 100 slots at a time' using errcode = 'P0001'; end if;
  if p_tutor is not null and not exists (select 1 from memberships m where m.id = p_tutor and m.org_id = p_org) then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if q is not null then pat := '%' || replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;

  with g as (
    select coalesce(sl.session_key, sl.id) as gk, min(sl.id::text)::uuid as first_id, count(*)::int as n,
           min(sl.weekday) as weekday, min(sl.start_time) as start_time, min(sl.end_time) as end_time, min(sl.subject) as subject, min(sl.rate) as rate, case when bool_and(sl.stopped_from is not null) then max(sl.stopped_from) end as stops_on,
           (array_agg(sl.taught_by))[1] as taught_by, bool_or(sl.session_key is not null) as is_group,
           jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'level', s.level,
                       'ended', (s.end_date is not null and s.end_date < today), 'slot_id', sl.id, 'starts_on', sl.starts_on, 'stops_on', sl.stopped_from) order by s.name, s.id) as studs
      from recurring_slots sl join students s on s.id = sl.student_id and s.org_id = sl.org_id
     where sl.org_id = p_org and sl.active and (sl.stopped_from is null or sl.stopped_from > today) and (p_tutor is null or sl.taught_by = p_tutor)
       and (q is null or sl.subject ilike pat or s.name ilike pat)
     group by coalesce(sl.session_key, sl.id)),
  paged as (select * from g order by weekday, start_time, (studs->0->>'name'), gk limit sz offset (pg - 1) * sz)
  select (select count(*) from g)::int,
         coalesce((select jsonb_agg(jsonb_build_object(
           'key', p.gk, 'slot_id', p.first_id, 'weekday', p.weekday, 'start_time', p.start_time, 'end_time', p.end_time,
           'minutes', (extract(epoch from (p.end_time - p.start_time)) / 60)::int, 'subject', p.subject,
           'rate', case when can_edit then p.rate end, 'stops_on', p.stops_on,
           'tutor_id', p.taught_by,
           'tutor_name', case when p.taught_by is null then null when t.status is null or t.status = 'disabled' then 'Former tutor' else coalesce(t.display_name, 'Tutor') end,
           'no_tutor', (p.taught_by is null or t.status is null or t.status = 'disabled'),
           'is_group', p.is_group, 'students', p.studs)
           order by p.weekday, p.start_time, (p.studs->0->>'name'), p.gk)
           from paged p left join memberships t on t.id = p.taught_by and t.org_id = p_org), '[]'::jsonb)
    into total, rows;
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', m.display_name) order by m.display_name, m.id), '[]'::jsonb) into tutors
    from memberships m where m.org_id = p_org and m.role = 'tutor' and m.status in ('active', 'invited');
  select max(l.lesson_date) into gen from lessons l where l.org_id = p_org and l.slot_id is not null;
  return jsonb_build_object('today', today, 'can_edit', can_edit, 'page', pg, 'size', sz, 'total', total, 'generated_until', gen,
                            'tutors', tutors, 'rows', rows);
end $$;
revoke all on function public.staff_slots(uuid, uuid, text, int, int) from public, anon;
grant execute on function public.staff_slots(uuid, uuid, text, int, int) to authenticated;

-- ---------------------------------------------------------------- 4. staff_save_slot: skips ended slots in its clash checks, and adds the tutor to the student's assigned tutors
create or replace function public.staff_save_slot(p_org uuid, p_slot uuid, p_students uuid[], p_weekday int, p_start time, p_end time,
                                                  p_tutor uuid default null, p_subject text default null, p_rate numeric default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare today date := staff_slots_gate(p_org, true); subj text := nullif(trim(coalesce(p_subject, '')), ''); mins int;
        sids uuid[]; sid uuid; sl recurring_slots; key uuid; owner_uid uuid; ids uuid[] := '{}'; sr students; clash text; new_id uuid; made int; r numeric(8,2);
        auto boolean; assigned jsonb := '[]'::jsonb; sname text; tname text;
begin
  if p_weekday is null or p_weekday < 0 or p_weekday > 6 then raise exception 'BAD_SLOT: pick a day of the week' using errcode = 'P0001'; end if;
  if p_start is null or p_end is null then raise exception 'BAD_TIME: give a start and an end time' using errcode = 'P0001'; end if;
  mins := (extract(epoch from (p_end - p_start)) / 60)::int;
  if mins <= 0 then raise exception 'BAD_TIME: the lesson must end after it starts' using errcode = 'P0001'; end if;
  if mins < 15 or mins > 480 then raise exception 'BAD_TIME: a lesson lasts 15 minutes to 8 hours' using errcode = 'P0001'; end if;
  if subj is not null and length(subj) > 60 then raise exception 'BAD_SLOT: the subject is too long (60 characters at most)' using errcode = 'P0001'; end if;
  if p_rate is not null and (p_rate < 0 or p_rate > 1000) then raise exception 'BAD_RATE: the rate per hour must be between 0 and 1000' using errcode = 'P0001'; end if;
  r := round(p_rate, 2);
  if p_tutor is not null and not exists (select 1 from memberships m where m.id = p_tutor and m.org_id = p_org and m.role in ('tutor', 'staff', 'owner') and m.status in ('active', 'invited')) then
    raise exception 'NOT_AVAILABLE: that person can''t be given lessons at this centre' using errcode = 'P0001'; end if;

  if p_slot is null then
    if p_rate is null then raise exception 'BAD_RATE: type the rate per hour' using errcode = 'P0001'; end if;
    select coalesce(array_agg(distinct x), '{}') into sids from unnest(coalesce(p_students, '{}')) x where x is not null;
    if coalesce(array_length(sids, 1), 0) < 1 then raise exception 'BAD_STUDENTS: pick at least one student' using errcode = 'P0001'; end if;
    if array_length(sids, 1) > 30 then raise exception 'BAD_STUDENTS: a class has at most 30 students' using errcode = 'P0001'; end if;
    select m.user_id into owner_uid from memberships m where m.org_id = p_org and m.role = 'owner' and m.status = 'active' and m.user_id is not null order by m.created_at limit 1;
    if owner_uid is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    key := case when array_length(sids, 1) > 1 then gen_random_uuid() end;
    foreach sid in array sids loop
      select * into sr from students where id = sid and org_id = p_org;
      if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
      if sr.end_date is not null and sr.end_date < today then raise exception 'STUDENT_ENDED: %''s lessons have ended', sr.name using errcode = 'P0001'; end if;
      select s2.name into clash from recurring_slots x join students s2 on s2.id = x.student_id
       where x.org_id = p_org and x.active and (x.stopped_from is null or x.stopped_from > today) and x.student_id = sid and x.weekday = p_weekday and x.start_time < p_end and x.end_time > p_start limit 1;
      if found then raise exception 'SLOT_CLASH: % already has a weekly lesson at that time', clash using errcode = 'P0001'; end if;
    end loop;
    foreach sid in array sids loop
      insert into recurring_slots(tutor_id, org_id, student_id, weekday, start_time, end_time, subject, rate, level, split, taught_by, session_key)
      select owner_uid, p_org, s.id, p_weekday, p_start, p_end, subj, r, s.level, 1, p_tutor, key from students s where s.id = sid and s.org_id = p_org
      returning id into new_id;
      ids := ids || new_id;
    end loop;
    insert into audit_log(org_id, actor, action, table_name, row_id, after)
    values (p_org, auth.uid(), 'staff_save_slot', 'recurring_slots', ids[1]::text,
            jsonb_build_object('added', true, 'slot_ids', ids, 'weekday', p_weekday, 'start', p_start, 'end', p_end, 'tutor', p_tutor, 'students', sids));
    -- THE TUTOR JOINS THE STUDENT'S ASSIGNED TUTORS (the centre can switch this off: lessons.auto_assign_tutors, default on, read as of today).
    -- Only ever ADDS: nobody is removed, and a tutor who is already assigned is left alone. The answer lists who was added so staff are told.
    auto := case when jsonb_typeof(org_settings_on(p_org, today) #> '{lessons,auto_assign_tutors}') = 'boolean'
                 then (org_settings_on(p_org, today) #>> '{lessons,auto_assign_tutors}')::boolean else true end;
    if p_tutor is not null and auto then
      select coalesce(m.display_name, 'Tutor') into tname from memberships m where m.id = p_tutor and m.org_id = p_org;
      foreach sid in array sids loop
        if not exists (select 1 from student_tutors x where x.org_id = p_org and x.student_id = sid and x.membership_id = p_tutor and x.active) then
          insert into student_tutors(org_id, student_id, membership_id, since, created_by) values (p_org, sid, p_tutor, today, auth.uid());
          select s.name into sname from students s where s.id = sid;
          assigned := assigned || jsonb_build_object('student_id', sid, 'student_name', sname, 'tutor_name', tname);
        end if;
      end loop;
      if jsonb_array_length(assigned) > 0 then
        insert into audit_log(org_id, actor, action, table_name, row_id, after)
        values (p_org, auth.uid(), 'staff_auto_assign_tutor', 'student_tutors', ids[1]::text, jsonb_build_object('tutor', p_tutor, 'assigned', assigned));
      end if;
    end if;
    return jsonb_build_object('slot_ids', ids, 'added', array_length(ids, 1), 'lessons_left', 0, 'assigned', assigned);
  end if;

  -- change
  if p_students is not null then raise exception 'BAD_STUDENTS: to change who is in a slot, stop it and add a new one' using errcode = 'P0001'; end if;
  select * into sl from recurring_slots where id = p_slot and org_id = p_org and active and (stopped_from is null or stopped_from > today);
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select coalesce(array_agg(x.id), '{}') into ids from recurring_slots x
   where x.org_id = p_org and x.active and (x.stopped_from is null or x.stopped_from > today) and (x.id = sl.id or (sl.session_key is not null and x.session_key = sl.session_key));
  for sid in select x.student_id from recurring_slots x where x.id = any(ids) loop
    select s2.name into clash from recurring_slots x join students s2 on s2.id = x.student_id
     where x.org_id = p_org and x.active and (x.stopped_from is null or x.stopped_from > today) and x.student_id = sid and not (x.id = any(ids)) and x.weekday = p_weekday and x.start_time < p_end and x.end_time > p_start limit 1;
    if found then raise exception 'SLOT_CLASH: % already has a weekly lesson at that time', clash using errcode = 'P0001'; end if;
  end loop;
  update recurring_slots set weekday = p_weekday, start_time = p_start, end_time = p_end, subject = subj, rate = coalesce(r, rate), taught_by = p_tutor
   where id = any(ids);
  select count(*) into made from lessons l where l.org_id = p_org and l.slot_id = any(ids) and l.lesson_date >= today and l.attendance is null and l.status <> 'cancelled';
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), 'staff_save_slot', 'recurring_slots', sl.id::text,
          jsonb_build_object('weekday', sl.weekday, 'start', sl.start_time, 'end', sl.end_time, 'tutor', sl.taught_by),
          jsonb_build_object('slot_ids', ids, 'weekday', p_weekday, 'start', p_start, 'end', p_end, 'tutor', p_tutor, 'rate_changed', p_rate is not null));
  return jsonb_build_object('slot_ids', ids, 'added', 0, 'lessons_left', made);
end $$;
revoke all on function public.staff_save_slot(uuid, uuid, uuid[], int, time, time, uuid, text, numeric) from public, anon;
grant execute on function public.staff_save_slot(uuid, uuid, uuid[], int, time, time, uuid, text, numeric) to authenticated;

-- ---------------------------------------------------------------- 5. the tutor's own weekly slots no longer list a slot once its stop date has come
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
     where sl.active and (sl.stopped_from is null or sl.stopped_from > (now() at time zone o.timezone)::date)
       and (s.end_date is null or s.end_date >= (now() at time zone o.timezone)::date)
     order by sl.weekday, sl.start_time, s.name, sl.id;
end $$;

-- ---------------------------------------------------------------- 6. the lesson generator: one core, 26 weeks at a time, honours each slot's own start / stop date
create or replace function public.staff_generate_core(p_org uuid, f date, t date, skip boolean, p_slots uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare res jsonb;
begin
  with days as (select d::date as d from generate_series(f, t, interval '1 day') d),
  cand as (
    select sl.id as slot_id, sl.session_key, sl.tutor_id, sl.student_id, sl.start_time, sl.end_time, sl.subject, sl.level, sl.rate, sl.split,
           days.d, st.end_date,
           (select m.id from memberships m where m.id = sl.taught_by and m.org_id = p_org and m.status <> 'disabled') as ok_tutor,
           exists (select 1 from holidays h where h.org_id = p_org and h.branch_id is null and days.d between h.starts_on and h.ends_on) as is_hol,
           exists (select 1 from lessons l where l.org_id = p_org
                    and ((l.slot_id = sl.id and l.slot_date = days.d)
                      or (l.student_id = sl.student_id and l.lesson_date = days.d and l.start_time = sl.start_time))) as there
      from recurring_slots sl
      join students st on st.id = sl.student_id and st.org_id = sl.org_id
      join days on (extract(isodow from days.d)::int - 1) = sl.weekday
     where sl.org_id = p_org and sl.active and (p_slots is null or sl.id = any(p_slots))
       and (sl.starts_on is null or days.d >= sl.starts_on) and (sl.stopped_from is null or days.d < sl.stopped_from)),
  cls as (
    select cand.*, case when end_date is not null and d > end_date then 'ended'
                        when there then 'there'
                        when is_hol and skip then 'holiday'
                        else 'new' end as kind
      from cand),
  ins as (
    insert into lessons(tutor_id, org_id, student_id, slot_id, lesson_date, slot_date, start_time, end_time, subject, level, rate, split, amount,
                        status, paid, one_off, taught_by, session_id)
    select tutor_id, p_org, student_id, slot_id, d, d, start_time, end_time, subject, level, rate, coalesce(split, 1),
           round(round(rate * (extract(epoch from (end_time - start_time)) / 3600)::numeric, 2) / greatest(coalesce(split, 1), 1), 2),
           'scheduled', false, false, ok_tutor,
           case when session_key is null then null else md5(session_key::text || d::text)::uuid end     -- the same for every student of the class on that day
      from cls where kind = 'new'
    returning id)
  select jsonb_build_object(
           'from', f, 'to', t,
           'created', (select count(*) from ins),
           'skipped', count(*) filter (where kind = 'there'),
           'holidays', count(distinct d) filter (where kind = 'holiday'),
           'ended', count(*) filter (where kind = 'ended'),
           'no_tutor', count(*) filter (where kind = 'new' and ok_tutor is null),
           'on_holiday', count(*) filter (where kind = 'new' and is_hol),
           'slots', (select count(*) from recurring_slots x where x.org_id = p_org and x.active and (x.stopped_from is null or x.stopped_from > f)))
    into res from cls;
  return res;
end $$;
revoke all on function public.staff_generate_core(uuid, date, date, boolean, uuid[]) from public, anon, authenticated;

create or replace function public.staff_generate_lessons(p_org uuid, p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := staff_slots_gate(p_org, true); f date := coalesce(p_from, today); t date; skip boolean; res jsonb;
begin
  t := coalesce(p_to, f + 27);
  if f < today then raise exception 'BAD_RANGE: lessons can''t be created for days that have passed' using errcode = 'P0001'; end if;
  if t < f or t - f > 181 then raise exception 'BAD_RANGE: create at most 26 weeks (182 days) at a time' using errcode = 'P0001'; end if;
  skip := case when jsonb_typeof(org_settings_on(p_org, today) #> '{calendar,skip_holidays}') = 'boolean'
                then (org_settings_on(p_org, today) #>> '{calendar,skip_holidays}')::boolean else true end;      -- missing = on (the default)
  perform pg_advisory_xact_lock(hashtextextended('staff_generate_lessons:' || p_org::text, 0));        -- two people pressing together: one waits, then finds nothing to add
  res := staff_generate_core(p_org, f, t, skip, null) || jsonb_build_object('days', t - f + 1);
  insert into audit_log(org_id, actor, action, table_name, row_id, after) values (p_org, auth.uid(), 'staff_generate_lessons', 'lessons', null, res);
  return res;
end $$;
revoke all on function public.staff_generate_lessons(uuid, date, date) from public, anon;
grant execute on function public.staff_generate_lessons(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------- 7. stop a weekly slot FROM a chosen day (the whole class if it is one)
-- p_from: today or a day to come (three years at most). The slot (and every student of its class) stops on that day: no lesson is made for it from
-- that day on. With p_remove_future the lessons already made for those days are removed too, but ONLY those nobody has marked, paid or invoiced.
-- p_dry = true changes nothing and answers the counts: removable (not marked, paid or invoiced: what the tick-box would remove), kept (marked, paid or
-- invoiced: always stay), lessons_left (lessons from that day that would remain).
create or replace function public.staff_stop_slot_from(p_org uuid, p_slot uuid, p_from date, p_remove_future boolean default false, p_dry boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare today date := staff_slots_gate(p_org, true); sl recurring_slots; ids uuid[]; allids uuid[]; rm boolean := coalesce(p_remove_future, false);
        n_free int; n_kept int; changed int := 0; removed int := 0; n_left int;
begin
  if p_from is null or p_from < today or p_from > today + 1095 then
    raise exception 'BAD_DATE: pick today or a day to come (within three years)' using errcode = 'P0001'; end if;
  select * into sl from recurring_slots where id = p_slot and org_id = p_org;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended('staff_generate_lessons:' || p_org::text, 0));        -- the generator's lock: a stop and a "create lessons" never interleave
  select coalesce(array_agg(x.id), '{}') into allids from recurring_slots x
   where x.org_id = p_org and (x.id = sl.id or (sl.session_key is not null and x.session_key = sl.session_key));
  select coalesce(array_agg(x.id), '{}') into ids from recurring_slots x
   where x.id = any(allids) and x.active and (x.stopped_from is null or x.stopped_from > today);

  select count(*) filter (where b is null), count(*) filter (where b in ('MARKED', 'PAID', 'INVOICED')) into n_free, n_kept
    from (select lesson_change_blocker(l.id) as b from lessons l
           where l.org_id = p_org and l.slot_id = any(allids) and l.lesson_date >= p_from) z;
  select count(*) into n_left from lessons l where l.org_id = p_org and l.slot_id = any(allids) and l.lesson_date >= p_from;
  if p_dry then
    return jsonb_build_object('dry', true, 'stop_from', p_from, 'stopped', coalesce(array_length(ids, 1), 0), 'removable', n_free, 'kept', n_kept,
                              'lessons_left', n_left - case when rm then n_free else 0 end);
  end if;

  update recurring_slots set stopped_from = p_from, active = (p_from > today)
   where id = any(ids) and (stopped_from is distinct from p_from or active <> (p_from > today));
  get diagnostics changed = row_count;
  if rm then
    with gone as (delete from lessons l where l.org_id = p_org and l.slot_id = any(allids) and l.lesson_date >= p_from and lesson_change_blocker(l.id) is null returning l.id)
    select count(*) into removed from gone;
  end if;
  select count(*) into n_left from lessons l where l.org_id = p_org and l.slot_id = any(allids) and l.lesson_date >= p_from;
  if changed + removed > 0 then
    insert into audit_log(org_id, actor, action, table_name, row_id, after)
    values (p_org, auth.uid(), 'staff_stop_slot_from', 'recurring_slots', sl.id::text,
            jsonb_build_object('slot_ids', allids, 'stop_from', p_from, 'removed_future_lessons', rm, 'lessons_removed', removed, 'lessons_kept', n_kept));
  end if;
  return jsonb_build_object('dry', false, 'stop_from', p_from, 'stopped', changed, 'removed', removed, 'kept', n_kept, 'lessons_left', n_left);
end $$;
revoke all on function public.staff_stop_slot_from(uuid, uuid, date, boolean, boolean) from public, anon;
grant execute on function public.staff_stop_slot_from(uuid, uuid, date, boolean, boolean) to authenticated;

-- ---------------------------------------------------------------- 8. add a student to / remove a student from an existing weekly slot, from a chosen day
-- p_action 'add': the student gets their own weekly row (same day, time, tutor, subject and rate), tied to the class by the slot's session_key (a
--   single slot becomes a class of two). Lessons ALREADY made for the class from that day get a lesson for the student too (through the same last day
--   the class already has), and the class's unmarked lessons share one session_id; marked, paid or invoiced lessons are never changed. The tutor of
--   the slot joins the student's assigned tutors (lessons.auto_assign_tutors). A student already in the class = nothing happens (answered, not an error).
-- p_action 'remove': that student's row stops from the day, and their later lessons nobody has marked, paid or invoiced are removed. The last student of
--   a slot can't be removed (stop the slot instead). Nobody is taken off the assigned tutors.
-- p_dry = true changes nothing and answers the counts for the confirmation. p_from default = today; never earlier than today.
create or replace function public.staff_slot_student(p_org uuid, p_slot uuid, p_student uuid, p_action text, p_from date default null, p_dry boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare today date := staff_slots_gate(p_org, true); f date := coalesce(p_from, today); sl recurring_slots; mine recurring_slots; st students;
        ids uuid[]; key uuid; clash text; new_id uuid; last_d date; skip boolean; auto boolean; assigned jsonb := '[]'::jsonb; tname text;
        n_free int := 0; n_kept int := 0; removed int := 0; made jsonb; n_dates int; owner_uid uuid;
begin
  if p_action is null or p_action not in ('add', 'remove') then raise exception 'BAD_ACTION: choose add or remove' using errcode = 'P0001'; end if;
  if f < today or f > today + 1095 then raise exception 'BAD_DATE: pick today or a day to come (within three years)' using errcode = 'P0001'; end if;
  select * into sl from recurring_slots where id = p_slot and org_id = p_org and active and (stopped_from is null or stopped_from > today);
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended('staff_generate_lessons:' || p_org::text, 0));
  select coalesce(array_agg(x.id), '{}') into ids from recurring_slots x
   where x.org_id = p_org and x.active and (x.stopped_from is null or x.stopped_from > today)
     and (x.id = sl.id or (sl.session_key is not null and x.session_key = sl.session_key));

  if p_action = 'add' then
    select * into st from students where id = p_student and org_id = p_org;
    if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    if st.end_date is not null and st.end_date < today then raise exception 'STUDENT_ENDED: %''s lessons have ended', st.name using errcode = 'P0001'; end if;
    if exists (select 1 from recurring_slots x where x.id = any(ids) and x.student_id = p_student) then
      return jsonb_build_object('dry', coalesce(p_dry, false), 'added', 0, 'already', true, 'created', 0, 'assigned', assigned, 'students', array_length(ids, 1));
    end if;
    if array_length(ids, 1) >= 30 then raise exception 'BAD_STUDENTS: a class has at most 30 students' using errcode = 'P0001'; end if;
    select s2.name into clash from recurring_slots x join students s2 on s2.id = x.student_id
     where x.org_id = p_org and x.active and (x.stopped_from is null or x.stopped_from > today) and x.student_id = p_student
       and x.weekday = sl.weekday and x.start_time < sl.end_time and x.end_time > sl.start_time limit 1;
    if found then raise exception 'SLOT_CLASH: % already has a weekly lesson at that time', clash using errcode = 'P0001'; end if;
    select max(l.lesson_date) into last_d from lessons l where l.org_id = p_org and l.slot_id = any(ids) and l.lesson_date >= f;
    last_d := least(last_d, f + 181);
    select count(distinct l.slot_date) into n_dates from lessons l
     where l.org_id = p_org and l.slot_id = any(ids) and l.lesson_date >= f and l.lesson_date <= coalesce(last_d, f) and l.status <> 'cancelled';
    if p_dry is not false then
      return jsonb_build_object('dry', true, 'added', 0, 'would_create', n_dates, 'students', array_length(ids, 1) + 1);
    end if;
    select m.user_id into owner_uid from memberships m where m.org_id = p_org and m.role = 'owner' and m.status = 'active' and m.user_id is not null order by m.created_at limit 1;
    key := coalesce(sl.session_key, gen_random_uuid());
    if sl.session_key is null then update recurring_slots set session_key = key where id = sl.id; end if;
    insert into recurring_slots(tutor_id, org_id, student_id, weekday, start_time, end_time, subject, rate, level, split, taught_by, session_key, starts_on)
    values (coalesce(owner_uid, sl.tutor_id), p_org, p_student, sl.weekday, sl.start_time, sl.end_time, sl.subject, sl.rate, st.level, 1, sl.taught_by, key,
            case when f > today then f end)
    returning id into new_id;
    -- the lessons already made for the class: the untouched ones share one session id from now on (marked / paid / invoiced ones are left as they are)
    update lessons l set session_id = md5(key::text || l.slot_date::text)::uuid
     where l.org_id = p_org and l.slot_id = any(ids) and l.lesson_date >= f and l.slot_date = l.lesson_date and l.session_id is null
       and lesson_change_blocker(l.id) is null;
    made := jsonb_build_object('created', 0);
    if last_d is not null then
      skip := case when jsonb_typeof(org_settings_on(p_org, today) #> '{calendar,skip_holidays}') = 'boolean'
                   then (org_settings_on(p_org, today) #>> '{calendar,skip_holidays}')::boolean else true end;
      made := staff_generate_core(p_org, f, last_d, skip, array[new_id]);
    end if;
    auto := case when jsonb_typeof(org_settings_on(p_org, today) #> '{lessons,auto_assign_tutors}') = 'boolean'
                 then (org_settings_on(p_org, today) #>> '{lessons,auto_assign_tutors}')::boolean else true end;
    if sl.taught_by is not null and auto
       and not exists (select 1 from student_tutors x where x.org_id = p_org and x.student_id = p_student and x.membership_id = sl.taught_by and x.active)
       and exists (select 1 from memberships m where m.id = sl.taught_by and m.org_id = p_org and m.status in ('active', 'invited')) then
      insert into student_tutors(org_id, student_id, membership_id, since, created_by) values (p_org, p_student, sl.taught_by, today, auth.uid());
      select coalesce(m.display_name, 'Tutor') into tname from memberships m where m.id = sl.taught_by;
      assigned := jsonb_build_array(jsonb_build_object('student_id', p_student, 'student_name', st.name, 'tutor_name', tname));
    end if;
    insert into audit_log(org_id, actor, action, table_name, row_id, after)
    values (p_org, auth.uid(), 'staff_slot_student_add', 'recurring_slots', new_id::text,
            jsonb_build_object('slot_ids', ids, 'student', p_student, 'from', f, 'lessons_created', (made->>'created')::int, 'assigned', assigned));
    return jsonb_build_object('dry', false, 'added', 1, 'slot_id', new_id, 'created', (made->>'created')::int, 'assigned', assigned, 'students', array_length(ids, 1) + 1);
  end if;

  -- remove
  select * into mine from recurring_slots x where x.id = any(ids) and x.student_id = p_student;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if array_length(ids, 1) < 2 then
    raise exception 'BAD_STUDENTS: this is the only student in the slot; stop the slot instead' using errcode = 'P0001'; end if;
  select count(*) filter (where b is null), count(*) filter (where b in ('MARKED', 'PAID', 'INVOICED')) into n_free, n_kept
    from (select lesson_change_blocker(l.id) as b from lessons l where l.org_id = p_org and l.slot_id = mine.id and l.lesson_date >= f) z;
  if p_dry is not false then
    return jsonb_build_object('dry', true, 'removed', 0, 'removable', n_free, 'kept', n_kept, 'students', array_length(ids, 1) - 1);
  end if;
  update recurring_slots set stopped_from = f, active = (f > today) where id = mine.id;
  with gone as (delete from lessons l where l.org_id = p_org and l.slot_id = mine.id and l.lesson_date >= f and lesson_change_blocker(l.id) is null returning l.id)
  select count(*) into removed from gone;
  insert into audit_log(org_id, actor, action, table_name, row_id, after)
  values (p_org, auth.uid(), 'staff_slot_student_remove', 'recurring_slots', mine.id::text,
          jsonb_build_object('slot_ids', ids, 'student', p_student, 'from', f, 'lessons_removed', removed, 'lessons_kept', n_kept));
  return jsonb_build_object('dry', false, 'removed', 1, 'lessons_removed', removed, 'kept', n_kept, 'students', array_length(ids, 1) - 1);
end $$;
revoke all on function public.staff_slot_student(uuid, uuid, uuid, text, date, boolean) from public, anon;
grant execute on function public.staff_slot_student(uuid, uuid, uuid, text, date, boolean) to authenticated;

-- ---------------------------------------------------------------- 9. cancel the lessons already on a holiday's days
-- Whole-centre holidays only (lessons and students carry no branch). p_from..p_to up to a year; days before today are never touched. A lesson that
-- is free (not marked, paid or invoiced, not already cancelled) becomes CANCELLED with a charge of 0 (compensation 0, amount 0: nobody is billed) and the
-- note "Holiday: <name>". Marked, paid, invoiced and already cancelled lessons stay. p_dry (the DEFAULT) only counts: cancel = lessons that would be
-- cancelled, kept = marked / paid / invoiced ones left alone, earlier = free lessons before today that are not touched.
create or replace function public.staff_holiday_cancel(p_org uuid, p_from date, p_to date, p_name text default null, p_dry boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare today date := staff_slots_gate(p_org, true); nm text := left(nullif(trim(coalesce(p_name, '')), ''), 60);
        n_free int; n_kept int; n_early int; ids uuid[]; done int := 0;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    raise exception 'BAD_RANGE: give a start and an end day, a year at most' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended('staff_generate_lessons:' || p_org::text, 0));
  select count(*) filter (where b is null and d >= today), count(*) filter (where b in ('MARKED', 'PAID', 'INVOICED') and d >= today),
         count(*) filter (where b is null and d < today),
         coalesce(array_agg(id) filter (where b is null and d >= today), '{}')
    into n_free, n_kept, n_early, ids
    from (select l.id, l.lesson_date as d, lesson_change_blocker(l.id) as b from lessons l
           where l.org_id = p_org and l.lesson_date between p_from and p_to) z;
  if p_dry is not false then
    return jsonb_build_object('dry', true, 'cancel', n_free, 'kept', n_kept, 'earlier', n_early);
  end if;
  with c as (update lessons set status = 'cancelled', compensation = 0, amount = 0, charge_note = 'Holiday' || coalesce(': ' || nm, '')
              where id = any(ids) and attendance is null and status <> 'cancelled' and not paid returning id)
  select count(*) into done from c;
  if done > 0 then
    insert into audit_log(org_id, actor, action, table_name, row_id, after)
    values (p_org, auth.uid(), 'staff_holiday_cancel', 'lessons', null,
            jsonb_build_object('from', p_from, 'to', p_to, 'holiday', nm, 'lessons_cancelled', done, 'lessons_kept', n_kept));
  end if;
  return jsonb_build_object('dry', false, 'cancel', done, 'kept', n_kept, 'earlier', n_early);
end $$;
revoke all on function public.staff_holiday_cancel(uuid, date, date, text, boolean) from public, anon;
grant execute on function public.staff_holiday_cancel(uuid, date, date, text, boolean) to authenticated;

-- ---------------------------------------------------------------- 10. the People list (read)
-- The owner sees every owner, staff member and tutor; staff with manage_tutors see the tutors. `invited` = invited and not signed in yet; last_emailed_at
-- is when the last invite email went out (never the address). No email, phone, pay, payout or money of any kind. can_users = may open Users and
-- permissions to change things (owners).
create or replace function public.staff_people(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_slots_gate(p_org, false); me uuid := auth.uid(); is_owner boolean; rows jsonb; cname text;
begin
  is_owner := exists (select 1 from memberships m where m.org_id = p_org and m.user_id = me and m.status = 'active' and m.role = 'owner');
  if not (is_owner or org_can(p_org, 'manage_tutors')) then
    raise exception 'NOT_ALLOWED: your account can''t see the people at this centre' using errcode = '42501'; end if;
  select o.trading_name into cname from organisations o where o.id = p_org;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id, 'name', coalesce(nullif(trim(m.display_name), ''), 'Unnamed'), 'role', m.role, 'status', m.status,
           'invited', (m.status = 'invited' and m.user_id is null), 'invited_at', case when m.status = 'invited' and m.user_id is null then m.created_at end,
           'last_emailed_at', case when m.status = 'invited' and m.user_id is null then l.last_sent end, 'you', (m.user_id = me))
         order by case m.role when 'owner' then 0 when 'staff' then 1 else 2 end, case m.status when 'active' then 0 when 'invited' then 1 else 2 end,
                  lower(coalesce(m.display_name, '')), m.id), '[]'::jsonb) into rows
    from memberships m
    left join lateral (select max(x.sent_at) filter (where x.status = 'sent') as last_sent from org_invite_mail_log x where x.membership_id = m.id) l on true
   where m.org_id = p_org and m.role in ('owner', 'staff', 'tutor') and (is_owner or m.role = 'tutor');
  return jsonb_build_object('today', today, 'centre', cname, 'can_users', is_owner, 'rows', rows);
end $$;
revoke all on function public.staff_people(uuid) from public, anon;
grant execute on function public.staff_people(uuid) to authenticated;
