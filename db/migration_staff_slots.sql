-- =====================================================================================================
-- T3 step 7 — centre weekly slots with tutors, the lesson generator, and who teaches whom          undo: migration_staff_slots_down.sql
-- =====================================================================================================
-- Needs migration_staff_timetable.sql (and everything before it: lessons.taught_by / session_id, attendance, org settings, holidays).
--
-- WHAT IT ADDS
--   recurring_slots.taught_by    the tutor (memberships.id) who teaches the weekly slot; null = no tutor yet (flagged amber on the Timetable)
--   recurring_slots.session_key  slots of one GROUP class share a key (one row per student, like lessons share a session_id)
--   students.online_link         optional https:// lesson link, per student (centre students only; see staff_set_student_link)
--   student_tutors               the students each tutor is ASSIGNED to; staff keep it, tutors never read or write it (T6 reads it)
--   staff_slots                  read   the weekly slots (rate only for people who may edit)
--   staff_pick_students          read   a name search for the slot form (names and levels only)
--   staff_save_slot              write  add / change a weekly slot (one student, or several = a group class)
--   staff_stop_slot              write  stop a weekly slot (it is switched off, never deleted: history stays)
--   staff_generate_lessons       write  create the lessons of the next N weeks from the active slots; safe to press twice
--   staff_student_tutors         read   a student's assigned tutors + history + online link (for the student sheet)
--   staff_set_student_tutors     write  set the students' assigned tutors
--   staff_set_student_link       write  set / clear a student's online link
--   tutor_lesson_links           read   a tutor's own lessons' online links (the tutor's other function is unchanged: it never has to change)
--   staff_timetable              replaced (same arguments): its 'online_link' is now the student's link instead of always null
--
-- WHO MAY CALL (same words as the rest of the staff screens)
--   reading   an active OWNER or STAFF member of this CENTRE, whatever their permissions
--   writing   the same, with manage_timetable (owners always). The link may also be set by manage_students.
--   a tutor / a parent / switched-off staff / a stranger / a solo organisation / an unknown id  →  NOT_FOUND (same words, so ids can't be probed)
--   staff of this centre without the permission                                                 →  NOT_ALLOWED
-- Tutors still have NO table access: they read neither slots nor student_tutors, and never see a rate. A slot's rate is the lesson's price
-- (staff only); tutor_my_lessons and tutor_lesson_links never return money.
--
-- THE GENERATOR (staff_generate_lessons) in plain words
--   * For every ACTIVE weekly slot and every day in the range that falls on the slot's weekday it makes one lesson per student (a group class
--     gets one lesson row per student, tied by the same session_id), with the slot's tutor, time, subject and rate. Lessons start as
--     'scheduled'; for a centre the status follows attendance, set when someone marks it.
--   * IDEMPOTENT: a lesson is keyed on slot + date (lessons.slot_id + slot_date, exactly the key the solo pages use), and a hand-made lesson for
--     the same student, day and start time counts too. Pressing it twice, or two people pressing it together, creates nothing twice (the call
--     takes a per-centre lock). A lesson that was moved keeps its slot_date, so the original day is not made again.
--   * SKIPS a day covered by a whole-centre holiday when the centre's setting calendar.skip_holidays is on (default on). Branch holidays do not
--     skip anything: slots and students carry no branch. SKIPS a student whose lessons have ended (students.end_date, inclusive).
--   * Never makes a lesson in the past (the range starts today at the earliest), and at most 62 days at a time. Default: today + 4 weeks.
--   * Nothing needs a room, a class or a branch: a remote 1-to-1 centre has none.
--
-- DATA-MODEL CHOICES (plain words)
--   * recurring_slots.tutor_id and lessons.tutor_id are NOT NULL logins; as in staff_save_student a centre's rows are filed under the centre
--     OWNER's login, so removing a staff login can't make the centre's timetable disappear. The person who TEACHES is taught_by.
--   * A stopped slot is active = false (like solo tutors' Planner). Lessons it already made are left alone (real data); the answer says how many.
--   * student_tutors is append-only history: removing a tutor from a student ends that row (active = false, until = today) and never deletes it;
--     adding them again later starts a new row. Only the functions write it (there is no write policy), and the audit log records every change.
--   * "A tutor and a student must belong to the same centre" is a trigger (org_tutor_same_org_guard, the same pattern as org_same_org_guard)
--     on student_tutors and on recurring_slots.taught_by, on top of the composite foreign keys.
-- Run on the DEV project first. Safe to run twice.
-- =====================================================================================================

-- ---------------------------------------------------------------- columns
alter table public.recurring_slots add column if not exists taught_by uuid;                 -- memberships.id of the tutor
alter table public.recurring_slots add column if not exists session_key uuid;               -- slots of one group class share a key
alter table public.students        add column if not exists online_link text;               -- optional https:// lesson link
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'slots_taught_by_same_org') then
    -- same organisation only; if the person is removed the slot keeps its organisation (set null on taught_by ONLY)
    alter table public.recurring_slots add constraint slots_taught_by_same_org
      foreign key (taught_by, org_id) references public.memberships(id, org_id) on delete set null (taught_by);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'students_online_link_ok') then
    alter table public.students add constraint students_online_link_ok
      check (online_link is null or (online_link ~ '^https://[^[:space:]]+$' and length(online_link) <= 500));
  end if;
end $$;
create index if not exists slots_taught_by on public.recurring_slots(taught_by) where taught_by is not null;
create index if not exists slots_session_key on public.recurring_slots(session_key) where session_key is not null;

-- ---------------------------------------------------------------- who teaches whom (assigned students): staff keep it, tutors never touch it
create table if not exists public.student_tutors (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organisations(id) on delete cascade,
  student_id    uuid not null,
  membership_id uuid not null,                                   -- the tutor (memberships.id)
  since         date not null default current_date,
  until         date,                                            -- set when the assignment ends (the row is kept as history)
  active        boolean not null default true,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  check (active or until is not null),
  foreign key (student_id, org_id)    references public.students(id, org_id)    on delete cascade,
  foreign key (membership_id, org_id) references public.memberships(id, org_id) on delete cascade
);
create unique index if not exists student_tutors_one_active on public.student_tutors(student_id, membership_id) where active;
create index if not exists student_tutors_org_student on public.student_tutors(org_id, student_id);
create index if not exists student_tutors_tutor on public.student_tutors(membership_id) where active;

-- a tutor and a student (or a slot's tutor and its student) must belong to the same centre: a plain message, on top of the composite keys
create or replace function public.org_tutor_same_org_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare n jsonb := to_jsonb(new); o jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) end;
        mem uuid := coalesce(nullif(n->>'membership_id', ''), nullif(n->>'taught_by', ''))::uuid;
        omem text := case when o is null then null else coalesce(nullif(o->>'membership_id', ''), nullif(o->>'taught_by', '')) end;
        stu uuid := nullif(n->>'student_id', '')::uuid;
begin
  if mem is not null and (o is null or mem::text is distinct from omem or n->>'org_id' is distinct from o->>'org_id') then
    if not exists (select 1 from memberships m where m.id = mem and m.org_id = new.org_id and m.status <> 'disabled') then
      raise exception 'A tutor and a student must belong to the same centre (that person isn''t an active member here)' using errcode = '42501';
    end if;
  end if;
  if tg_table_name = 'student_tutors' and stu is not null and (o is null or n->>'student_id' is distinct from o->>'student_id' or n->>'org_id' is distinct from o->>'org_id') then
    if not exists (select 1 from students s join organisations g on g.id = s.org_id and g.kind = 'centre' where s.id = stu and s.org_id = new.org_id) then
      raise exception 'A tutor and a student must belong to the same centre (that student isn''t one of this centre''s)' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists org_tutor_same_org_guard on public.student_tutors;
create trigger org_tutor_same_org_guard before insert or update on public.student_tutors for each row execute function public.org_tutor_same_org_guard();
drop trigger if exists org_tutor_same_org_guard on public.recurring_slots;
create trigger org_tutor_same_org_guard before insert or update on public.recurring_slots for each row execute function public.org_tutor_same_org_guard();
revoke all on function public.org_tutor_same_org_guard() from public, anon, authenticated;

alter table public.student_tutors enable row level security;
drop policy if exists org_read on public.student_tutors;
create policy org_read on public.student_tutors for select using (org_can_read(org_id));           -- owners and staff read; there is NO write policy (functions only)
drop trigger if exists audit_row on public.student_tutors;
create trigger audit_row after insert or update or delete on public.student_tutors for each row execute function public.audit_row();
revoke all on public.student_tutors from anon, authenticated;
grant select on public.student_tutors to authenticated;

-- ---------------------------------------------------------------- the gate every function starts with (internal; not callable from the browser)
-- p_write false: any active owner / staff member.  true: also needs manage_timetable.  Returns the centre's own today.
create or replace function public.staff_slots_gate(p_org uuid, p_write boolean) returns date
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
    raise exception 'NOT_ALLOWED: your account can''t change the timetable at this centre' using errcode = '42501';
  end if;
  return (now() at time zone tz)::date;
end $$;
revoke all on function public.staff_slots_gate(uuid, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------- 1. the weekly slots (read)
-- A row is one slot, or one GROUP class (the slots sharing a session_key, with all its students). Only ACTIVE slots. weekday 0 = Monday … 6 = Sunday,
-- like the Planner. `rate` (S$ per hour) comes back ONLY to someone who may edit the timetable; everyone else gets null. p_q searches student names
-- and subjects. generated_until = the last day a slot has already made a lesson for (null = none yet).
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
           min(sl.weekday) as weekday, min(sl.start_time) as start_time, min(sl.end_time) as end_time, min(sl.subject) as subject, min(sl.rate) as rate,
           (array_agg(sl.taught_by))[1] as taught_by, bool_or(sl.session_key is not null) as is_group,
           jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'level', s.level,
                       'ended', (s.end_date is not null and s.end_date < today), 'slot_id', sl.id) order by s.name, s.id) as studs
      from recurring_slots sl join students s on s.id = sl.student_id and s.org_id = sl.org_id
     where sl.org_id = p_org and sl.active and (p_tutor is null or sl.taught_by = p_tutor)
       and (q is null or sl.subject ilike pat or s.name ilike pat)
     group by coalesce(sl.session_key, sl.id)),
  paged as (select * from g order by weekday, start_time, (studs->0->>'name'), gk limit sz offset (pg - 1) * sz)
  select (select count(*) from g)::int,
         coalesce((select jsonb_agg(jsonb_build_object(
           'key', p.gk, 'slot_id', p.first_id, 'weekday', p.weekday, 'start_time', p.start_time, 'end_time', p.end_time,
           'minutes', (extract(epoch from (p.end_time - p.start_time)) / 60)::int, 'subject', p.subject,
           'rate', case when can_edit then p.rate end,
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

-- ---------------------------------------------------------------- 2. find students for the slot form (names and levels only; active, lessons not ended)
create or replace function public.staff_pick_students(p_org uuid, p_q text default null, p_limit int default 20)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare today date := staff_slots_gate(p_org, true); q text := nullif(trim(coalesce(p_q, '')), ''); pat text; lim int := least(greatest(coalesce(p_limit, 20), 1), 50);
begin
  if q is not null and length(q) > 100 then raise exception 'BAD_SEARCH: search for at most 100 characters' using errcode = 'P0001'; end if;
  if q is not null then pat := '%' || replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'level', x.level) order by lower(x.name), x.id)
                     from (select s.id, s.name, s.level from students s
                            where s.org_id = p_org and (s.end_date is null or s.end_date >= today) and (q is null or s.name ilike pat)
                            order by lower(s.name), s.id limit lim) x), '[]'::jsonb);
end $$;
revoke all on function public.staff_pick_students(uuid, text, int) from public, anon;
grant execute on function public.staff_pick_students(uuid, text, int) to authenticated;

-- ---------------------------------------------------------------- 3. add / change a weekly slot
-- p_slot null = ADD one slot per student in p_students (1 to 30; two or more = a group class, tied by a session_key).
-- p_slot set = CHANGE that slot (and the rest of its group): weekday, time, tutor (null = no tutor yet), subject, rate (null = keep). The students
--   of a slot can't be changed (stop it and add a new one), so p_students must be null.
-- Checks: weekday 0-6; start before end, 15 minutes to 8 hours, same day; rate 0 to 1000 per hour (needed when adding); tutor an active or invited
--   member of this centre; every student in this centre and not ended; a student can't have two weekly slots that overlap.
-- Lessons ALREADY made from the slot are not rewritten (real data, maybe already marked); the answer says how many upcoming ones are left.
create or replace function public.staff_save_slot(p_org uuid, p_slot uuid, p_students uuid[], p_weekday int, p_start time, p_end time,
                                                  p_tutor uuid default null, p_subject text default null, p_rate numeric default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare today date := staff_slots_gate(p_org, true); subj text := nullif(trim(coalesce(p_subject, '')), ''); mins int;
        sids uuid[]; sid uuid; sl recurring_slots; key uuid; owner_uid uuid; ids uuid[] := '{}'; sr students; clash text; new_id uuid; made int; r numeric(8,2);
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
       where x.org_id = p_org and x.active and x.student_id = sid and x.weekday = p_weekday and x.start_time < p_end and x.end_time > p_start limit 1;
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
    return jsonb_build_object('slot_ids', ids, 'added', array_length(ids, 1), 'lessons_left', 0);
  end if;

  -- change
  if p_students is not null then raise exception 'BAD_STUDENTS: to change who is in a slot, stop it and add a new one' using errcode = 'P0001'; end if;
  select * into sl from recurring_slots where id = p_slot and org_id = p_org and active;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select coalesce(array_agg(x.id), '{}') into ids from recurring_slots x
   where x.org_id = p_org and x.active and (x.id = sl.id or (sl.session_key is not null and x.session_key = sl.session_key));
  for sid in select x.student_id from recurring_slots x where x.id = any(ids) loop
    select s2.name into clash from recurring_slots x join students s2 on s2.id = x.student_id
     where x.org_id = p_org and x.active and x.student_id = sid and not (x.id = any(ids)) and x.weekday = p_weekday and x.start_time < p_end and x.end_time > p_start limit 1;
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

-- ---------------------------------------------------------------- 4. stop a weekly slot (the whole group class if it is one)
create or replace function public.staff_stop_slot(p_org uuid, p_slot uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := staff_slots_gate(p_org, true); sl recurring_slots; ids uuid[]; made int;
begin
  select * into sl from recurring_slots where id = p_slot and org_id = p_org;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select coalesce(array_agg(x.id), '{}') into ids from recurring_slots x
   where x.org_id = p_org and x.active and (x.id = sl.id or (sl.session_key is not null and x.session_key = sl.session_key));
  update recurring_slots set active = false where id = any(ids);
  select count(*) into made from lessons l where l.org_id = p_org and l.slot_id = any(ids) and l.lesson_date >= today and l.attendance is null and l.status <> 'cancelled';
  if coalesce(array_length(ids, 1), 0) > 0 then
    insert into audit_log(org_id, actor, action, table_name, row_id, after)
    values (p_org, auth.uid(), 'staff_stop_slot', 'recurring_slots', sl.id::text, jsonb_build_object('slot_ids', ids, 'lessons_left', made));
  end if;
  return jsonb_build_object('stopped', coalesce(array_length(ids, 1), 0), 'lessons_left', made);
end $$;
revoke all on function public.staff_stop_slot(uuid, uuid) from public, anon;
grant execute on function public.staff_stop_slot(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------- 5. create the lessons of the next weeks from the active slots
-- p_from default = the centre's today (never earlier); p_to default = p_from + 27 days (4 weeks); at most 62 days.
-- Answer: created (new lessons), skipped (already there: same slot and day, or a lesson for that student, day and start time), holidays (days
-- skipped because of a whole-centre holiday, when calendar.skip_holidays is on), ended (students whose lessons had ended), no_tutor (new lessons
-- made with no tutor: the slot has none, or its tutor has since been switched off), on_holiday (new lessons that fall on a holiday because the
-- centre switched skipping off), slots (active slots looked at). The settings are read as of TODAY (a process rule).
create or replace function public.staff_generate_lessons(p_org uuid, p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := staff_slots_gate(p_org, true); f date := coalesce(p_from, today); t date; skip boolean; res jsonb;
begin
  t := coalesce(p_to, f + 27);
  if f < today then raise exception 'BAD_RANGE: lessons can''t be created for days that have passed' using errcode = 'P0001'; end if;
  if t < f or t - f > 62 then raise exception 'BAD_RANGE: create at most 62 days at a time' using errcode = 'P0001'; end if;
  skip := case when jsonb_typeof(org_settings_on(p_org, today) #> '{calendar,skip_holidays}') = 'boolean'
                then (org_settings_on(p_org, today) #>> '{calendar,skip_holidays}')::boolean else true end;      -- missing = on (the default)
  perform pg_advisory_xact_lock(hashtextextended('staff_generate_lessons:' || p_org::text, 0));        -- two people pressing together: one waits, then finds nothing to add

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
     where sl.org_id = p_org and sl.active),
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
           'slots', (select count(*) from recurring_slots x where x.org_id = p_org and x.active))
    into res from cls;
  insert into audit_log(org_id, actor, action, table_name, row_id, after) values (p_org, auth.uid(), 'staff_generate_lessons', 'lessons', null, res);
  return res;
end $$;
revoke all on function public.staff_generate_lessons(uuid, date, date) from public, anon;
grant execute on function public.staff_generate_lessons(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------- 6. a student's assigned tutors, history and online link (for the student sheet)
-- can_edit = may change the assigned tutors (manage_timetable); can_link = may change the link (manage_timetable or manage_students).
create or replace function public.staff_student_tutors(p_org uuid, p_student uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_slots_gate(p_org, false); s students; assigned jsonb; hist jsonb; opts jsonb;
begin
  select * into s from students where id = p_student and org_id = p_org;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', coalesce(m.display_name, 'Tutor'), 'since', x.since) order by m.display_name, m.id), '[]'::jsonb) into assigned
    from student_tutors x join memberships m on m.id = x.membership_id and m.org_id = x.org_id
   where x.org_id = p_org and x.student_id = p_student and x.active;
  select coalesce(jsonb_agg(jsonb_build_object('name', coalesce(m.display_name, 'Tutor'), 'since', y.since, 'until', y.until) order by y.until desc, y.since desc), '[]'::jsonb) into hist
    from (select * from student_tutors z where z.org_id = p_org and z.student_id = p_student and not z.active order by z.until desc, z.since desc limit 10) y
    join memberships m on m.id = y.membership_id and m.org_id = y.org_id;
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', coalesce(m.display_name, 'Tutor')) order by m.display_name, m.id), '[]'::jsonb) into opts
    from memberships m where m.org_id = p_org and m.role = 'tutor' and m.status in ('active', 'invited');
  return jsonb_build_object('student_id', s.id, 'student_name', s.name, 'can_edit', org_can(p_org, 'manage_timetable'),
                            'can_link', org_can(p_org, 'manage_timetable') or org_can(p_org, 'manage_students'),
                            'online_link', s.online_link, 'assigned', assigned, 'history', hist, 'options', opts);
end $$;
revoke all on function public.staff_student_tutors(uuid, uuid) from public, anon;
grant execute on function public.staff_student_tutors(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------- 7. set a student's assigned tutors
-- p_tutors = the full list wanted now (up to 20; empty = none). Tutors no longer on the list get their row ENDED (active false, until today),
-- new ones get a new row (since today). Nothing is deleted. Who is assigned decides which students a tutor may schedule for themselves (T6).
create or replace function public.staff_set_student_tutors(p_org uuid, p_student uuid, p_tutors uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := staff_slots_gate(p_org, true); want uuid[]; mid uuid; added int := 0; removed int := 0; n int;
begin
  if not exists (select 1 from students s where s.id = p_student and s.org_id = p_org) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select coalesce(array_agg(distinct x), '{}') into want from unnest(coalesce(p_tutors, '{}')) x where x is not null;
  if coalesce(array_length(want, 1), 0) > 20 then raise exception 'BAD_TUTORS: a student has at most 20 assigned tutors' using errcode = 'P0001'; end if;
  foreach mid in array want loop
    if not exists (select 1 from memberships m where m.id = mid and m.org_id = p_org and m.status in ('active', 'invited')) then
      raise exception 'NOT_AVAILABLE: that person can''t be given students at this centre' using errcode = 'P0001'; end if;
  end loop;
  update student_tutors set active = false, until = today
   where org_id = p_org and student_id = p_student and active and not (membership_id = any(want));
  get diagnostics removed = row_count;
  foreach mid in array want loop
    if not exists (select 1 from student_tutors x where x.org_id = p_org and x.student_id = p_student and x.membership_id = mid and x.active) then
      insert into student_tutors(org_id, student_id, membership_id, since, created_by) values (p_org, p_student, mid, today, auth.uid());
      added := added + 1;
    end if;
  end loop;
  select count(*) into n from student_tutors where org_id = p_org and student_id = p_student and active;
  if added + removed > 0 then
    insert into audit_log(org_id, actor, action, table_name, row_id, after)
    values (p_org, auth.uid(), 'staff_set_student_tutors', 'student_tutors', p_student::text, jsonb_build_object('added', added, 'removed', removed, 'tutors', want));
  end if;
  return jsonb_build_object('added', added, 'removed', removed, 'assigned', n);
end $$;
revoke all on function public.staff_set_student_tutors(uuid, uuid, uuid[]) from public, anon;
grant execute on function public.staff_set_student_tutors(uuid, uuid, uuid[]) to authenticated;

-- ---------------------------------------------------------------- 8. set or clear a student's online lesson link
-- https:// only, no spaces, 500 characters at most ('javascript:' and friends are refused). '' or null clears it. Not money.
create or replace function public.staff_set_student_link(p_org uuid, p_student uuid, p_link text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := staff_slots_gate(p_org, false); lk text := nullif(trim(coalesce(p_link, '')), ''); old text;
begin
  if not (org_can(p_org, 'manage_timetable') or org_can(p_org, 'manage_students')) then
    raise exception 'NOT_ALLOWED: your account can''t change students or the timetable at this centre' using errcode = '42501'; end if;
  select s.online_link into old from students s where s.id = p_student and s.org_id = p_org;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if lk is not null and (length(lk) > 500 or lk !~ '^https://[^[:space:]]+$') then
    raise exception 'BAD_LINK: the link must start with https:// and have no spaces (500 characters at most)' using errcode = 'P0001'; end if;
  update students set online_link = lk where id = p_student and org_id = p_org;
  if lk is distinct from old then
    insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
    values (p_org, auth.uid(), 'staff_set_student_link', 'students', p_student::text, jsonb_build_object('online_link', old), jsonb_build_object('online_link', lk));
  end if;
  return jsonb_build_object('online_link', lk);
end $$;
revoke all on function public.staff_set_student_link(uuid, uuid, text) from public, anon;
grant execute on function public.staff_set_student_link(uuid, uuid, text) to authenticated;

-- ---------------------------------------------------------------- 9. a tutor's own lessons' online links (tutor side; no money, no parent contact)
-- Only the caller's OWN lessons (taught_by is their active membership) in a centre, for at most 62 days. A tutor with no lessons in the range, a
-- parent or a stranger gets an empty list, never an error that would show whether a lesson exists.
create or replace function public.tutor_lesson_links(p_from date, p_to date) returns table(lesson_id uuid, online_link text)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 62 then
    raise exception 'BAD_RANGE: ask for at most 62 days' using errcode = 'P0001'; end if;
  return query
    select l.id, s.online_link
      from lessons l
      join memberships m on m.id = l.taught_by and m.org_id = l.org_id and m.user_id = auth.uid() and m.status = 'active'
      join organisations o on o.id = l.org_id and o.kind = 'centre'
      join students s on s.id = l.student_id and s.org_id = l.org_id
     where l.lesson_date between p_from and p_to and s.online_link is not null;
end $$;
revoke all on function public.tutor_lesson_links(date, date) from public, anon;
grant execute on function public.tutor_lesson_links(date, date) to authenticated;

-- ---------------------------------------------------------------- 10. staff_timetable: the lesson's online link is now the student's link (it was always null)
-- Same arguments, same columns, same rules as migration_staff_timetable.sql; only 'online_link' changed. Undo puts the earlier text back.
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
           s.id as sid, s.name as sname, s.level as slevel, s.online_link as slink, t.status as tstatus, t.display_name as tname,
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
           'online_link', slink)
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
