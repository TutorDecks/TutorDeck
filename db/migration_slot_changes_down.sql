-- Undo of migration_slot_changes.sql (T3.9). Run it BEFORE migration_payout_permission_down.sql's chain starts (i.e. first of all the undos).
-- Puts the earlier staff_slots, staff_save_slot, staff_generate_lessons (62 days) and tutor_my_slots back, drops the new functions and the two columns.
-- Slots that were given a stop day keep their `active` flag; lessons removed or cancelled by these functions stay removed / cancelled (real data).
drop function if exists public.staff_people(uuid);
drop function if exists public.staff_holiday_cancel(uuid, date, date, text, boolean);
drop function if exists public.staff_slot_student(uuid, uuid, uuid, text, date, boolean);
drop function if exists public.staff_stop_slot_from(uuid, uuid, date, boolean, boolean);

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

drop function if exists public.staff_generate_core(uuid, date, date, boolean, uuid[]);

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

drop function if exists public.lesson_change_blocker(uuid);
alter table public.recurring_slots drop column if exists stopped_from;
alter table public.recurring_slots drop column if exists starts_on;
