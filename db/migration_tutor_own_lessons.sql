-- =====================================================================================================
-- T6 step 3 + 4 — tutors add their OWN one-off lessons, keep their OWN weekly slots and press "Create lessons"      undo: migration_tutor_own_lessons_down.sql
-- =====================================================================================================
-- Needs migration_tutor_moves.sql (T6 step 2) and, through it, tutor_schedule, staff_slots (student_tutors, the slot columns, the generator's key), staff_reassign
-- (lesson_locked_reason), staff_charges (the gate the price function reuses) and centre_invoice_run (the one function this file patches). Run on DEV first. Safe to run twice.
--
-- THE CENTRE'S CHOICE (owner decisions 2026-11-27). Three more of the six switches become BUILT (all under lessons.tutors_edit, read as of the centre's TODAY, all off
-- by default; each needs lessons.timetable_editing = tutors_direct):
--   tutors_edit.one_off       a tutor may add a one-off lesson for a student ASSIGNED to them          tutor_add_lesson
--   tutors_edit.weekly_slots  a tutor may add, change or stop their OWN weekly slots                    tutor_save_slot, tutor_stop_slot
--   tutors_edit.generate      a tutor may press "Create lessons" for their OWN slots                    tutor_generate_lessons
--   (tutors_edit.link stays "soon" until step 5; tutors_propose stays "soon" until step 6.)
-- The existing limits apply where they mean something: the NOTICE (a new lesson, or a generated one, must start min_notice_hours or more from now; nothing in the
-- past) and max_changes_per_month (adding a lesson, adding / changing / stopping a slot each count as one change, like a move or a cancel; "Create lessons" is a
-- batch of already-agreed slots and does not count).
--
-- WHAT A TUTOR CAN DO (functions only; tutors still have NO table access, no policy is added anywhere)
--   tutor_my_students()                                       read   the students assigned to me (name, level, a suggested subject) for the Add lesson form
--   tutor_add_lesson(student, date, start, end, subject, note) one lesson for ONE assigned student. Never a group class, never a trial (trials_flagged_by is the centre's).
--   tutor_save_slot(slot, student, weekday, start, end, subject)  slot null = add (one student); slot set = change my own slot (day, time, subject; not the student)
--   tutor_stop_slot(slot)                                     stop my own slot (switched off, never deleted; lessons it already made stay)
--   tutor_generate_lessons(org, from, to)                     the SAME generator as staff (same key: slot + day, skips whole-centre holidays when calendar.skip_holidays is on,
--                                                             skips ended students, never the past), for MY slots and MY assigned students only. Default today + 4 weeks, at most 62 days
--   tutor_my_schedule / tutor_my_slots (replaced)             the same answers plus the new buttons the centre allows and "awaiting_centre" (the centre will confirm the lesson's details)
--
-- THE PRICE OF A LESSON A TUTOR MADE (owner decision). A tutor never sees, types or receives a price. The database fills it in:
--   * the rate per hour of that student's LATEST staff-made weekly slot or lesson (not one a tutor made, not one still waiting) is copied, or
--   * if the student has none, the lesson / slot is created with the price EMPTY and flagged `price_pending`: it HOLDS BACK that family's invoice, like a pending charge
--     (centre_invoice_run_rows, patched below: the invoice screen says "charge pending: <student>") until staff type it with staff_set_lesson_price (needs issue_invoices,
--     the same gate as the pending charges). Any non-zero rate or amount typed straight into the table clears the flag too (trigger), so no path leaves it stuck.
--   Every money word in this file lives in the INTERNAL helpers below (tutor_basis_for, tutor_own_insert_lesson, tutor_own_insert_slot, tutor_own_generate,
--   staff_set_lesson_price, the invoice run); the functions a tutor calls contain none (tests/sql/tutor_own_lessons_test.sql greps their text and their answers).
--
-- THE RULES (the first word of a refusal is the code for the screen; the same order as the step-2 functions)
--   NOT_FOUND       not a student assigned to you, not your slot, a solo organisation, a parent, staff, a switched-off tutor, another centre, an unknown id: ALL the same word
--   NOT_ALLOWED     the centre's setting is admin_only (or tutors_propose, not built yet)         SWITCH_OFF the centre hasn't switched this on
--   LIMIT           max_changes_per_month reached                                                  STUDENT_ENDED that student's lessons have ended
--   BAD_DATE / BAD_TIME / TOO_LONG   a date still to come within a year, a start and end on one day (15 minutes to 8 hours), short texts
--   TOO_LATE        closer to its start than min_notice_hours     HOLIDAY  a whole-centre holiday     ALREADY_THERE  that student already has a lesson then (so a double press adds nothing)
--   CLASH           you already teach someone at that time (YOUR lessons only, never another tutor's students)
--   SLOT_CLASH / TUTOR_CLASH   the same student, or you, already have a weekly slot at that time        GROUP_CLASS  a group class is changed by an admin
-- Days and times are the centre's own (organisations.timezone). Every write has an audit_log row (tutor_add_lesson | tutor_save_slot | tutor_stop_slot | tutor_generate_lessons).
--
-- WHAT STAFF SEE: the amber "changed by tutor" flag and the Home "Tutor changes" list now also show lessons a tutor ADDED, slots a tutor added / changed / stopped, and one
-- line per "Create lessons" run (staff_tutor_changes, replaced). lessons.created_by_tutor / recurring_slots.created_by_tutor remember WHO made a row for good (the
-- "changed_by_tutor_*" fields describe the latest change and are overwritten by the next one).
-- The Supabase API refuses a DELETE / UPDATE without WHERE (pg-safeupdate): every statement below has one.
-- =====================================================================================================

-- ---------------------------------------------------------------- 1. the columns
alter table public.lessons add column if not exists price_pending    boolean not null default false;   -- a tutor made it and the centre has not confirmed its price
alter table public.lessons add column if not exists created_by_tutor uuid;                              -- memberships.id of the tutor who made this lesson (never changes)
alter table public.recurring_slots add column if not exists price_pending         boolean not null default false;
alter table public.recurring_slots add column if not exists created_by_tutor      uuid;
alter table public.recurring_slots add column if not exists changed_by_tutor_at   timestamptz;
alter table public.recurring_slots add column if not exists changed_by_tutor      uuid;
alter table public.recurring_slots add column if not exists changed_by_tutor_what text;                 -- added | changed | stopped
alter table public.recurring_slots add column if not exists changed_by_tutor_reason text;
do $$ begin
  -- lessons: a tutor can now also ADD one (T6 step 2 allowed moved | reverted | cancelled)
  alter table public.lessons drop constraint if exists lessons_changed_by_tutor_what_ok;
  alter table public.lessons add constraint lessons_changed_by_tutor_what_ok check (changed_by_tutor_what is null or changed_by_tutor_what in ('moved', 'reverted', 'cancelled', 'added'));
  if not exists (select 1 from pg_constraint where conname = 'lessons_created_by_tutor_same_org') then
    alter table public.lessons add constraint lessons_created_by_tutor_same_org
      foreign key (created_by_tutor, org_id) references public.memberships(id, org_id) on delete set null (created_by_tutor);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'slots_created_by_tutor_same_org') then
    alter table public.recurring_slots add constraint slots_created_by_tutor_same_org
      foreign key (created_by_tutor, org_id) references public.memberships(id, org_id) on delete set null (created_by_tutor);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'slots_changed_by_tutor_same_org') then
    alter table public.recurring_slots add constraint slots_changed_by_tutor_same_org
      foreign key (changed_by_tutor, org_id) references public.memberships(id, org_id) on delete set null (changed_by_tutor);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'slots_changed_by_tutor_what_ok') then
    alter table public.recurring_slots add constraint slots_changed_by_tutor_what_ok check (changed_by_tutor_what is null or changed_by_tutor_what in ('added', 'changed', 'stopped'));
  end if;
end $$;
create index if not exists slots_changed_by_tutor on public.recurring_slots(org_id, changed_by_tutor_at desc) where changed_by_tutor_at is not null;
create index if not exists lessons_price_pending on public.lessons(org_id) where price_pending;

-- Two rules, in one trigger on lessons and slots:
--  * the flag CLEARS when anyone types a real price straight into the row (staff_set_lesson_price clears it explicitly, also for a price of 0);
--  * a lesson that is made from a slot that is still waiting for its price (by the STAFF "Create lessons" button too, which knows nothing of this flag) is born waiting.
--    Without this a waiting slot would make zero-price lessons that no invoice ever noticed.
create or replace function public.price_pending_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare j jsonb := to_jsonb(new);
begin
  if new.price_pending and (coalesce((j->>'rate')::numeric, 0) > 0 or coalesce((j->>'amount')::numeric, 0) > 0) then new.price_pending := false; end if;
  if tg_op = 'INSERT' and tg_table_name = 'lessons' and not new.price_pending and nullif(j->>'slot_id', '') is not null
     and coalesce((j->>'rate')::numeric, 0) = 0 and coalesce((j->>'amount')::numeric, 0) = 0
     and exists (select 1 from recurring_slots s where s.id = (j->>'slot_id')::uuid and s.price_pending) then
    new.price_pending := true;
  end if;
  return new;
end $$;
revoke all on function public.price_pending_guard() from public, anon, authenticated;
drop trigger if exists price_pending_guard on public.lessons;
create trigger price_pending_guard before insert or update on public.lessons for each row execute function public.price_pending_guard();
drop trigger if exists price_pending_guard on public.recurring_slots;
create trigger price_pending_guard before insert or update on public.recurring_slots for each row execute function public.price_pending_guard();

-- ---------------------------------------------------------------- 2. what counts toward max_changes_per_month (internal)
-- One place, so tutor_change_block, tutor_my_schedule and the new functions can't disagree. Counts this tutor's audit rows since the 1st (centre time).
create or replace function public.tutor_changes_used(p_org uuid, p_user uuid, p_tz text) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from audit_log a
   where a.org_id = p_org and a.actor = p_user
     and a.action in ('tutor_postpone_lesson', 'tutor_revert_lesson', 'tutor_cancel_lesson', 'tutor_add_lesson', 'tutor_save_slot', 'tutor_stop_slot')
     and a.at >= date_trunc('month', now() at time zone p_tz) at time zone p_tz
$$;

-- ---------------------------------------------------------------- 3. step 2's rulebook, now counting every kind of change (the rest is word for word)
create or replace function public.tutor_change_block(p_lesson uuid, p_what text) returns text
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); l lessons; tz text; today date; cfg jsonb; mode text; sw boolean; notice int; mx int; used int; start_ts timestamptz; lk text;
        sl recurring_slots; tdate date;
begin
  if me is null or p_what not in ('postpone', 'revert', 'cancel') then return 'NOT_FOUND'; end if;
  select * into l from lessons where id = p_lesson;
  if not found or l.taught_by is null then return 'NOT_FOUND'; end if;
  select o.timezone into tz from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
   where m.id = l.taught_by and m.org_id = l.org_id and m.user_id = me and m.role = 'tutor' and m.status = 'active';
  if tz is null then return 'NOT_FOUND'; end if;
  if not exists (select 1 from student_tutors st where st.org_id = l.org_id and st.student_id = l.student_id and st.membership_id = l.taught_by and st.active) then
    return 'NOT_FOUND'; end if;
  today := (now() at time zone tz)::date;
  cfg := org_settings_on(l.org_id, today);
  mode := coalesce(cfg #>> '{lessons,timetable_editing}', 'admin_only');
  if mode <> 'tutors_direct' then
    return 'NOT_ALLOWED: at this centre the admins change the timetable. Ask them to change this lesson'; end if;
  sw := case when p_what = 'cancel' then coalesce((cfg #>> '{lessons,tutors_edit,cancel}')::boolean, false)
             else coalesce((cfg #>> '{lessons,tutors_edit,postpone}')::boolean, true) end;
  if not sw then
    return 'SWITCH_OFF: this centre doesn''t let tutors ' || case when p_what = 'cancel' then 'cancel' else 'move' end || ' lessons. Ask an admin'; end if;
  lk := lesson_locked_reason(l.id);
  if lk is not null then
    return case lk when 'MARKED'    then 'ALREADY_MARKED: this lesson is already marked, so it can''t be changed here. Ask an admin'
                   when 'CANCELLED' then 'CANCELLED: this lesson was cancelled'
                   else                  'LOCKED: your centre has already closed this lesson, so it can''t be changed here. Ask an admin' end;   -- one word for every closed reason: a tutor is never told which
  end if;
  if p_what = 'revert' then
    if not l.postponed then return 'NOT_MOVED: this lesson is already at its usual time'; end if;
    select * into sl from recurring_slots x where x.id = l.slot_id and x.org_id = l.org_id;
    if not found or l.slot_date is null or not sl.active then
      return 'NO_SLOT: this lesson has no usual slot to go back to. Ask an admin'; end if;
    if sl.taught_by is distinct from l.taught_by or sl.end_time - sl.start_time <> l.end_time - l.start_time then
      return 'SLOT_CHANGED: the usual slot has changed since this lesson was moved. Ask an admin'; end if;
  end if;
  start_ts := (l.lesson_date + l.start_time) at time zone tz;
  if start_ts <= now() then return 'PAST: this lesson has already started'; end if;
  notice := coalesce((cfg #>> '{lessons,min_notice_hours}')::int, 24);
  if start_ts < now() + make_interval(hours => notice) then
    return 'TOO_LATE: a lesson can only be changed ' || notice || ' hour' || case when notice = 1 then '' else 's' end || ' or more before it starts. Ask an admin'; end if;
  mx := coalesce((cfg #>> '{lessons,max_changes_per_month}')::int, 0);
  if mx > 0 then
    used := public.tutor_changes_used(l.org_id, me, tz);
    if used >= mx then
      return 'LIMIT: you have used your ' || mx || ' schedule change' || case when mx = 1 then '' else 's' end || ' for this month. Ask an admin'; end if;
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------- 4. the gate every new tutor function starts with (internal; reads no money)
-- p_switch: one_off | weekly_slots | generate. p_student null = no student to check (the generator, a slot's own checks). The first refusal wins, in the order of the
-- list in the header; "not yours" and "no such thing" are the same NOT_FOUND. Returns what the caller needs as jsonb: mem (my membership), tz, today, notice, mx, skip_holidays.
create or replace function public.tutor_own_gate(p_org uuid, p_student uuid, p_switch text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); mem uuid; tz text; today date; cfg jsonb; mode text; sw boolean;
begin
  if me is null or p_org is null or p_switch not in ('one_off', 'weekly_slots', 'generate') then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select m.id, o.timezone into mem, tz from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
   where m.org_id = p_org and m.user_id = me and m.role = 'tutor' and m.status = 'active';
  if mem is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_student is not null and not exists (select 1 from student_tutors st join students s on s.id = st.student_id and s.org_id = st.org_id
                                            where st.org_id = p_org and st.student_id = p_student and st.membership_id = mem and st.active) then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := (now() at time zone tz)::date;
  cfg := org_settings_on(p_org, today);
  mode := coalesce(cfg #>> '{lessons,timetable_editing}', 'admin_only');
  if mode <> 'tutors_direct' then
    raise exception 'NOT_ALLOWED: at this centre the admins change the timetable. Ask them' using errcode = 'P0001'; end if;
  sw := coalesce((cfg #>> array['lessons', 'tutors_edit', p_switch])::boolean, false);
  if not sw then
    raise exception 'SWITCH_OFF: this centre doesn''t let tutors % . Ask an admin', case p_switch when 'one_off' then 'add lessons' when 'weekly_slots' then 'change their weekly slots' else 'create lessons' end
      using errcode = 'P0001'; end if;
  return jsonb_build_object('mem', mem, 'tz', tz, 'today', today,
                            'notice', coalesce((cfg #>> '{lessons,min_notice_hours}')::int, 24),
                            'mx', coalesce((cfg #>> '{lessons,max_changes_per_month}')::int, 0),
                            'skip_holidays', case when jsonb_typeof(cfg #> '{calendar,skip_holidays}') = 'boolean' then (cfg #>> '{calendar,skip_holidays}')::boolean else true end);
end $$;

-- the monthly limit, for the functions that count as one change
create or replace function public.tutor_own_limit_check(p_org uuid, p_gate jsonb) returns void
language plpgsql stable security definer set search_path = public as $$
declare mx int := (p_gate->>'mx')::int; used int;
begin
  if mx > 0 then
    used := public.tutor_changes_used(p_org, auth.uid(), p_gate->>'tz');
    if used >= mx then
      raise exception 'LIMIT: you have used your % schedule change% for this month. Ask an admin', mx, case when mx = 1 then '' else 's' end using errcode = 'P0001'; end if;
  end if;
end $$;

-- ---------------------------------------------------------------- 5. the money helpers (INTERNAL: the browser can't call them; the only place a tutor's action touches a price)
-- tutor_basis_for: the rate of the student's LATEST staff-made slot or lesson (not tutor-made, not still waiting) and its subject, with known = true; {"known": false} when there is none.
create or replace function public.tutor_basis_for(p_org uuid, p_student uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('known', true, 'rate', x.rate, 'subject', x.subject)
                     from (select s.rate, s.subject, s.created_at, s.id::text as k from recurring_slots s
                            where s.org_id = p_org and s.student_id = p_student and s.created_by_tutor is null and not s.price_pending
                           union all
                           select l.rate, l.subject, l.created_at, l.id::text from lessons l
                            where l.org_id = p_org and l.student_id = p_student and l.created_by_tutor is null and not l.price_pending) x
                    order by x.created_at desc, x.k desc limit 1), '{"known": false}'::jsonb)
$$;

-- one lesson, made for a tutor: the rate comes from the basis, or the price is left empty and flagged. Returns the id and whether the centre must confirm.
create or replace function public.tutor_own_insert_lesson(p_org uuid, p_student uuid, p_mem uuid, p_date date, p_start time, p_end time, p_subject text, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b jsonb := public.tutor_basis_for(p_org, p_student); r numeric(8,2) := coalesce((b->>'rate')::numeric, 0); known boolean := (b->>'known')::boolean;
        owner_uid uuid; st students; new_id uuid;
begin
  select m.user_id into owner_uid from memberships m where m.org_id = p_org and m.role = 'owner' and m.status = 'active' and m.user_id is not null order by m.created_at limit 1;
  select * into st from students where id = p_student and org_id = p_org;
  if owner_uid is null or not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, subject, level, rate, amount, split, status, paid, one_off, taught_by,
                      price_pending, created_by_tutor, changed_by_tutor_at, changed_by_tutor, changed_by_tutor_what, changed_by_tutor_reason)
  values (owner_uid, p_org, p_student, p_date, p_start, p_end, coalesce(p_subject, b->>'subject'), st.level, r,
          round(r * (extract(epoch from (p_end - p_start)) / 3600)::numeric, 2), 1, 'scheduled', false, true, p_mem,
          not known, p_mem, now(), p_mem, 'added', p_note)
  returning id into new_id;
  return jsonb_build_object('id', new_id, 'awaiting_centre', not known);
end $$;

-- one weekly slot, made for a tutor (same rule for the rate)
create or replace function public.tutor_own_insert_slot(p_org uuid, p_student uuid, p_mem uuid, p_weekday int, p_start time, p_end time, p_subject text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b jsonb := public.tutor_basis_for(p_org, p_student); r numeric(8,2) := coalesce((b->>'rate')::numeric, 0); known boolean := (b->>'known')::boolean;
        owner_uid uuid; st students; new_id uuid;
begin
  select m.user_id into owner_uid from memberships m where m.org_id = p_org and m.role = 'owner' and m.status = 'active' and m.user_id is not null order by m.created_at limit 1;
  select * into st from students where id = p_student and org_id = p_org;
  if owner_uid is null or not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  insert into recurring_slots(tutor_id, org_id, student_id, weekday, start_time, end_time, subject, rate, level, split, taught_by,
                              price_pending, created_by_tutor, changed_by_tutor_at, changed_by_tutor, changed_by_tutor_what)
  values (owner_uid, p_org, p_student, p_weekday, p_start, p_end, coalesce(p_subject, b->>'subject'), r, st.level, 1, p_mem,
          not known, p_mem, now(), p_mem, 'added')
  returning id into new_id;
  return jsonb_build_object('id', new_id, 'awaiting_centre', not known);
end $$;

-- the generator for ONE tutor's slots: staff_generate_lessons' own statement (same key = slot + day, a hand-made lesson for the same student, day and start counts),
-- restricted to the tutor's slots and assigned students, and skipping what starts inside the notice. A group class gets the same session_id staff would give it.
create or replace function public.tutor_own_generate(p_org uuid, p_mem uuid, p_from date, p_to date, p_skip boolean, p_notice int, p_tz text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare res jsonb;
begin
  with days as (select d::date as d from generate_series(p_from, p_to, interval '1 day') d),
  cand as (
    select sl.id as slot_id, sl.session_key, sl.tutor_id, sl.student_id, sl.start_time, sl.end_time, sl.subject, sl.level, sl.rate, sl.split, sl.price_pending as ppend,
           days.d, st.end_date,
           exists (select 1 from student_tutors x where x.org_id = p_org and x.student_id = sl.student_id and x.membership_id = p_mem and x.active) as assigned,
           exists (select 1 from holidays h where h.org_id = p_org and h.branch_id is null and days.d between h.starts_on and h.ends_on) as is_hol,
           exists (select 1 from lessons l where l.org_id = p_org
                    and ((l.slot_id = sl.id and l.slot_date = days.d)
                      or (l.student_id = sl.student_id and l.lesson_date = days.d and l.start_time = sl.start_time))) as there
      from recurring_slots sl
      join students st on st.id = sl.student_id and st.org_id = sl.org_id
      join days on (extract(isodow from days.d)::int - 1) = sl.weekday
     where sl.org_id = p_org and sl.active and sl.taught_by = p_mem),
  cls as (
    select cand.*, case when end_date is not null and d > end_date then 'ended'
                        when not assigned then 'not_assigned'
                        when there then 'there'
                        when is_hol and p_skip then 'holiday'
                        when ((d + start_time) at time zone p_tz) < now() + make_interval(hours => p_notice) then 'soon'
                        else 'new' end as kind
      from cand),
  ins as (
    insert into lessons(tutor_id, org_id, student_id, slot_id, lesson_date, slot_date, start_time, end_time, subject, level, rate, split, amount,
                        status, paid, one_off, taught_by, session_id, price_pending, created_by_tutor)
    select tutor_id, p_org, student_id, slot_id, d, d, start_time, end_time, subject, level, rate, coalesce(split, 1),
           round(round(rate * (extract(epoch from (end_time - start_time)) / 3600)::numeric, 2) / greatest(coalesce(split, 1), 1), 2),
           'scheduled', false, false, p_mem,
           case when session_key is null then null else md5(session_key::text || d::text)::uuid end,
           ppend, p_mem
      from cls where kind = 'new'
    returning id)
  select jsonb_build_object(
           'from', p_from, 'to', p_to,
           'created', (select count(*) from ins),
           'skipped', count(*) filter (where kind = 'there'),
           'holidays', count(distinct d) filter (where kind = 'holiday'),
           'ended', count(*) filter (where kind = 'ended'),
           'too_soon', count(*) filter (where kind = 'soon'),
           'not_assigned', count(*) filter (where kind = 'not_assigned'),
           'awaiting_centre', count(*) filter (where kind = 'new' and ppend),
           'slots', (select count(*) from recurring_slots x where x.org_id = p_org and x.active and x.taught_by = p_mem))
    into res from cls;
  return res;
end $$;

-- ---------------------------------------------------------------- 6. my assigned students (for the Add lesson and weekly slot forms)
-- Active students assigned to me whose lessons haven't ended; name, level and a suggested subject only. awaiting_centre = the centre has no earlier lesson of theirs to
-- copy the details from, so a lesson made now is confirmed by the centre first.
create or replace function public.tutor_my_students() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if not exists (select 1 from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
                  where m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active') then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('org_id', o.id, 'org_name', o.trading_name, 'student_id', s.id, 'name', s.name, 'level', s.level,
                                                         'subject', b.v->>'subject', 'awaiting_centre', not (b.v->>'known')::boolean)
                                    order by lower(s.name), s.id)
                     from memberships m
                     join organisations o on o.id = m.org_id and o.kind = 'centre'
                     join student_tutors st on st.org_id = m.org_id and st.membership_id = m.id and st.active
                     join students s on s.id = st.student_id and s.org_id = st.org_id
                    cross join lateral (select public.tutor_basis_for(s.org_id, s.id) as v) b
                    where m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active'
                      and (s.end_date is null or s.end_date >= (now() at time zone o.timezone)::date)), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- 7. add one lesson
create or replace function public.tutor_add_lesson(p_student uuid, p_date date, p_start time, p_end time, p_subject text default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare org uuid; g jsonb; mem uuid; tz text; today date; notice int; st students; mins int; start_ts timestamptz; hol text; same text; clash text; made jsonb;
        subj text := nullif(trim(coalesce(p_subject, '')), ''); note text := nullif(trim(coalesce(p_note, '')), '');
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select s.org_id into org from students s where s.id = p_student;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  g := public.tutor_own_gate(org, p_student, 'one_off');
  mem := (g->>'mem')::uuid; tz := g->>'tz'; today := (g->>'today')::date; notice := (g->>'notice')::int;
  perform pg_advisory_xact_lock(hashtextextended('tutor_own:' || mem::text, 0));                  -- two presses together: the second one finds the first one's lesson
  perform public.tutor_own_limit_check(org, g);
  select * into st from students where id = p_student and org_id = org;
  if st.end_date is not null and st.end_date < today then raise exception 'STUDENT_ENDED: %''s lessons have ended', st.name using errcode = 'P0001'; end if;
  if p_date is null or p_start is null or p_end is null then raise exception 'BAD_DATE: pick a day, a start time and an end time' using errcode = 'P0001'; end if;
  if p_date > today + 365 then raise exception 'BAD_DATE: pick a date within the next year' using errcode = 'P0001'; end if;
  mins := (extract(epoch from (p_end - p_start)) / 60)::int;
  if mins <= 0 then raise exception 'BAD_TIME: the lesson must end after it starts' using errcode = 'P0001'; end if;
  if mins < 15 or mins > 480 then raise exception 'BAD_TIME: a lesson lasts 15 minutes to 8 hours' using errcode = 'P0001'; end if;
  if subj is not null and length(subj) > 60 then raise exception 'TOO_LONG: keep the subject under 60 characters' using errcode = 'P0001'; end if;
  if note is not null and length(note) > 300 then raise exception 'TOO_LONG: keep the note under 300 characters' using errcode = 'P0001'; end if;
  start_ts := (p_date + p_start) at time zone tz;
  if start_ts <= now() then raise exception 'BAD_DATE: that time has already passed. Pick a later one' using errcode = 'P0001'; end if;
  if start_ts < now() + make_interval(hours => notice) then
    raise exception 'TOO_LATE: a new lesson must start % hour% or more from now. Ask an admin', notice, case when notice = 1 then '' else 's' end using errcode = 'P0001'; end if;
  select h.name into hol from holidays h where h.org_id = org and h.branch_id is null and p_date between h.starts_on and h.ends_on order by h.starts_on, h.name limit 1;
  if hol is not null then raise exception 'HOLIDAY: % is a holiday at this centre. Pick another day', hol using errcode = 'P0001'; end if;
  select s.name into same from lessons y join students s on s.id = y.student_id and s.org_id = y.org_id
   where y.org_id = org and y.student_id = p_student and y.status <> 'cancelled' and y.lesson_date = p_date and y.start_time < p_end and y.end_time > p_start limit 1;
  if same is not null then raise exception 'ALREADY_THERE: % already has a lesson at that time', same using errcode = 'P0001'; end if;
  select s.name into clash from lessons y join students s on s.id = y.student_id and s.org_id = y.org_id
   where y.org_id = org and y.taught_by = mem and y.status <> 'cancelled' and y.lesson_date = p_date and y.start_time < p_end and y.end_time > p_start
   order by y.start_time, y.id limit 1;
  if clash is not null then raise exception 'CLASH: you already teach % at that time. Pick another time', clash using errcode = 'P0001'; end if;

  made := public.tutor_own_insert_lesson(org, p_student, mem, p_date, p_start, p_end, subj, note);
  insert into audit_log(org_id, actor, action, table_name, row_id, after)
  values (org, auth.uid(), 'tutor_add_lesson', 'lessons', made->>'id',
          jsonb_build_object('student_id', p_student, 'lesson_date', p_date, 'start_time', p_start, 'end_time', p_end, 'note', note, 'awaiting_centre', (made->>'awaiting_centre')::boolean));
  return jsonb_build_object('lesson_id', (made->>'id')::uuid, 'lesson_date', p_date, 'start_time', p_start, 'end_time', p_end,
                            'awaiting_centre', (made->>'awaiting_centre')::boolean);
end $$;

-- ---------------------------------------------------------------- 8. add / change one of my weekly slots
-- p_slot null = add a slot for p_student (one student; a group class is staff's). p_slot set = change MY slot's day, time and subject (the student can't be changed:
-- stop it and add a new one, as staff do). Lessons already made from a slot are never rewritten; the answer says how many upcoming ones are left.
create or replace function public.tutor_save_slot(p_slot uuid, p_student uuid, p_weekday int, p_start time, p_end time, p_subject text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare org uuid; sid uuid := p_student; sl recurring_slots; g jsonb; mem uuid; today date; st students; mins int; clash text; made jsonb; left_n int; new_id uuid; aw boolean := false;
        subj text := nullif(trim(coalesce(p_subject, '')), '');
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_slot is not null then
    select * into sl from recurring_slots where id = p_slot;
    if not found or sl.taught_by is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    org := sl.org_id; sid := sl.student_id;
  else
    select s.org_id into org from students s where s.id = p_student;
    if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  end if;
  g := public.tutor_own_gate(org, sid, 'weekly_slots');
  mem := (g->>'mem')::uuid; today := (g->>'today')::date;
  if p_slot is not null and (sl.taught_by is distinct from mem or not sl.active) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_slot is not null and sl.session_key is not null then
    raise exception 'GROUP_CLASS: this is a group class. Ask an admin to change it' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended('tutor_own:' || mem::text, 0));
  perform public.tutor_own_limit_check(org, g);
  select * into st from students where id = sid and org_id = org;
  if p_slot is null and st.end_date is not null and st.end_date < today then raise exception 'STUDENT_ENDED: %''s lessons have ended', st.name using errcode = 'P0001'; end if;
  if p_weekday is null or p_weekday < 0 or p_weekday > 6 then raise exception 'BAD_SLOT: pick a day of the week' using errcode = 'P0001'; end if;
  if p_start is null or p_end is null then raise exception 'BAD_TIME: give a start and an end time' using errcode = 'P0001'; end if;
  mins := (extract(epoch from (p_end - p_start)) / 60)::int;
  if mins <= 0 then raise exception 'BAD_TIME: the lesson must end after it starts' using errcode = 'P0001'; end if;
  if mins < 15 or mins > 480 then raise exception 'BAD_TIME: a lesson lasts 15 minutes to 8 hours' using errcode = 'P0001'; end if;
  if subj is not null and length(subj) > 60 then raise exception 'TOO_LONG: keep the subject under 60 characters' using errcode = 'P0001'; end if;
  select s.name into clash from recurring_slots x join students s on s.id = x.student_id and s.org_id = x.org_id
   where x.org_id = org and x.active and x.student_id = sid and (p_slot is null or x.id <> p_slot) and x.weekday = p_weekday and x.start_time < p_end and x.end_time > p_start limit 1;
  if clash is not null then raise exception 'SLOT_CLASH: % already has a weekly lesson at that time', clash using errcode = 'P0001'; end if;
  select s.name into clash from recurring_slots x join students s on s.id = x.student_id and s.org_id = x.org_id
   where x.org_id = org and x.active and x.taught_by = mem and (p_slot is null or x.id <> p_slot) and x.weekday = p_weekday and x.start_time < p_end and x.end_time > p_start
   order by x.start_time, x.id limit 1;
  if clash is not null then raise exception 'TUTOR_CLASH: you already teach % at that time every week. Pick another time', clash using errcode = 'P0001'; end if;

  if p_slot is null then
    made := public.tutor_own_insert_slot(org, sid, mem, p_weekday, p_start, p_end, subj);
    new_id := (made->>'id')::uuid; aw := (made->>'awaiting_centre')::boolean; left_n := 0;
  else
    update recurring_slots set weekday = p_weekday, start_time = p_start, end_time = p_end, subject = subj,
           changed_by_tutor_at = now(), changed_by_tutor = mem, changed_by_tutor_what = 'changed'
     where id = p_slot;
    new_id := p_slot; aw := sl.price_pending;
    select count(*) into left_n from lessons l where l.org_id = org and l.slot_id = p_slot and l.lesson_date >= today and l.attendance is null and l.status <> 'cancelled';
  end if;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (org, auth.uid(), 'tutor_save_slot', 'recurring_slots', new_id::text,
          case when p_slot is null then null else jsonb_build_object('weekday', sl.weekday, 'start', sl.start_time, 'end', sl.end_time, 'subject', sl.subject) end,
          jsonb_build_object('added', p_slot is null, 'student_id', sid, 'weekday', p_weekday, 'start', p_start, 'end', p_end, 'subject', subj));
  return jsonb_build_object('slot_id', new_id, 'added', p_slot is null, 'lessons_left', left_n, 'awaiting_centre', aw);
end $$;

-- ---------------------------------------------------------------- 9. stop one of my weekly slots
create or replace function public.tutor_stop_slot(p_slot uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sl recurring_slots; g jsonb; mem uuid; today date; left_n int;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into sl from recurring_slots where id = p_slot;
  if not found or sl.taught_by is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  g := public.tutor_own_gate(sl.org_id, sl.student_id, 'weekly_slots');
  mem := (g->>'mem')::uuid; today := (g->>'today')::date;
  if sl.taught_by is distinct from mem then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if sl.session_key is not null then raise exception 'GROUP_CLASS: this is a group class. Ask an admin to change it' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended('tutor_own:' || mem::text, 0));
  select * into sl from recurring_slots where id = p_slot;
  select count(*) into left_n from lessons l where l.org_id = sl.org_id and l.slot_id = p_slot and l.lesson_date >= today and l.attendance is null and l.status <> 'cancelled';
  if not sl.active then return jsonb_build_object('stopped', 0, 'lessons_left', left_n); end if;      -- pressed twice: nothing more happens, nothing is counted
  perform public.tutor_own_limit_check(sl.org_id, g);
  update recurring_slots set active = false, changed_by_tutor_at = now(), changed_by_tutor = mem, changed_by_tutor_what = 'stopped' where id = p_slot;
  insert into audit_log(org_id, actor, action, table_name, row_id, after)
  values (sl.org_id, auth.uid(), 'tutor_stop_slot', 'recurring_slots', p_slot::text, jsonb_build_object('lessons_left', left_n, 'student_id', sl.student_id));
  return jsonb_build_object('stopped', 1, 'lessons_left', left_n);
end $$;

-- ---------------------------------------------------------------- 10. "Create lessons" for my own slots
-- p_from default = the centre's today (never earlier); p_to default = p_from + 27 days; at most 62 days. Answer: created, skipped (already there), holidays (days skipped),
-- ended, too_soon (inside the notice), not_assigned (a slot of mine for a student not assigned to me), awaiting_centre (new lessons the centre must confirm), slots.
create or replace function public.tutor_generate_lessons(p_org uuid, p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g jsonb := public.tutor_own_gate(p_org, null, 'generate'); mem uuid := (g->>'mem')::uuid; today date := (g->>'today')::date; f date; t date; res jsonb;
begin
  f := coalesce(p_from, today); t := coalesce(p_to, f + 27);
  if f < today then raise exception 'BAD_RANGE: lessons can''t be created for days that have passed' using errcode = 'P0001'; end if;
  if t < f or t - f > 62 then raise exception 'BAD_RANGE: create at most 62 days at a time' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended('staff_generate_lessons:' || p_org::text, 0));    -- the same lock as the staff button: together they can't make a lesson twice
  res := public.tutor_own_generate(p_org, mem, f, t, (g->>'skip_holidays')::boolean, (g->>'notice')::int, g->>'tz');
  insert into audit_log(org_id, actor, action, table_name, row_id, after)
  values (p_org, auth.uid(), 'tutor_generate_lessons', 'lessons', null, res || jsonb_build_object('tutor_id', mem));
  return res;
end $$;

-- ---------------------------------------------------------------- 11. tutor_my_schedule: same answer as step 2, plus the new buttons the centre allows (can_one_off, can_slots,
--     can_generate) and, per lesson, awaiting_centre (the centre will confirm its details) and added_by_you. The monthly count comes from the shared helper. No money.
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
                                      'timetable_editing', c.mode,
                                      'can_edit', (c.mode = 'tutors_direct' and (c.sw_postpone or c.sw_cancel)),
                                      'can_postpone', (c.mode = 'tutors_direct' and c.sw_postpone), 'can_cancel', (c.mode = 'tutors_direct' and c.sw_cancel),
                                      'min_notice_hours', c.notice, 'max_changes_per_month', c.mx,
                                      'can_one_off', (c.mode = 'tutors_direct' and c.sw_one_off), 'can_slots', (c.mode = 'tutors_direct' and c.sw_slots),
                                      'can_generate', (c.mode = 'tutors_direct' and c.sw_generate),
                                      'changes_left', case when c.mx > 0 and c.mode = 'tutors_direct' then greatest(0, c.mx - public.tutor_changes_used(o.id, auth.uid(), o.timezone)) end)
                      order by o.trading_name, o.id),
         min((now() at time zone o.timezone)::date)
    into orgs, today
    from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
    cross join lateral (select org_settings_on(o.id, (now() at time zone o.timezone)::date) as s) cfg
    cross join lateral (select coalesce(cfg.s #>> '{lessons,timetable_editing}', 'admin_only') as mode,
                               coalesce((cfg.s #>> '{lessons,tutors_edit,postpone}')::boolean, true) as sw_postpone,
                               coalesce((cfg.s #>> '{lessons,tutors_edit,cancel}')::boolean, false) as sw_cancel,
                               coalesce((cfg.s #>> '{lessons,tutors_edit,one_off}')::boolean, false) as sw_one_off,
                               coalesce((cfg.s #>> '{lessons,tutors_edit,weekly_slots}')::boolean, false) as sw_slots,
                               coalesce((cfg.s #>> '{lessons,tutors_edit,generate}')::boolean, false) as sw_generate,
                               coalesce((cfg.s #>> '{lessons,min_notice_hours}')::int, 24) as notice,
                               coalesce((cfg.s #>> '{lessons,max_changes_per_month}')::int, 0) as mx) c
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
                        and l.lesson_date between h.starts_on and h.ends_on order by h.starts_on, h.name limit 1),
           'can_postpone', (b.postpone is null), 'can_revert', (b.revert is null), 'can_cancel', (b.cancel is null),
           'change_block', case when b.postpone is null or b.cancel is null then null
                                when b.postpone not like 'NOT_ALLOWED%' and b.postpone not like 'SWITCH_OFF%' then split_part(b.postpone, ':', 1)
                                when b.cancel not like 'NOT_ALLOWED%' and b.cancel not like 'SWITCH_OFF%' then split_part(b.cancel, ':', 1) end,
           'changed_by_you', (l.changed_by_tutor_what), 'awaiting_centre', l.price_pending, 'added_by_you', (l.created_by_tutor is not null), 'class_size', (select count(*)::int from lessons y where l.session_id is not null and y.org_id = l.org_id and y.session_id = l.session_id)
         ) order by l.lesson_date, l.start_time, s.name, l.id), '[]'::jsonb)
    into lessons
    from lessons l
    join memberships m on m.id = l.taught_by and m.org_id = l.org_id and m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active'
    join organisations o on o.id = l.org_id and o.kind = 'centre'
    join students s on s.id = l.student_id and s.org_id = l.org_id
    cross join lateral (select tutor_change_block(l.id, 'postpone') as postpone, tutor_change_block(l.id, 'revert') as revert, tutor_change_block(l.id, 'cancel') as cancel) b
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

-- ---------------------------------------------------------------- 12. tutor_my_slots: same rows as step 1, plus can_change (this centre lets me change this slot), is_group, awaiting_centre
drop function if exists public.tutor_my_slots();
create or replace function public.tutor_my_slots()
returns table(slot_id uuid, org_id uuid, org_name text, weekday int, start_time time, end_time time, subject text,
              student_id uuid, student_name text, student_level text, session_key uuid, timetable_editing text,
              can_change boolean, is_group boolean, awaiting_centre boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if not exists (select 1 from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
                  where m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active') then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  return query
    select sl.id, sl.org_id, o.trading_name, sl.weekday::int, sl.start_time, sl.end_time, sl.subject,
           s.id, s.name, s.level, sl.session_key,
           c.mode,
           (c.mode = 'tutors_direct' and c.sw_slots and sl.session_key is null
              and exists (select 1 from student_tutors st where st.org_id = sl.org_id and st.student_id = sl.student_id and st.membership_id = m.id and st.active)),
           (sl.session_key is not null), sl.price_pending
      from recurring_slots sl
      join memberships m on m.id = sl.taught_by and m.org_id = sl.org_id and m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active'
      join organisations o on o.id = sl.org_id and o.kind = 'centre'
      join students s on s.id = sl.student_id and s.org_id = sl.org_id
     cross join lateral (select coalesce(org_settings_on(sl.org_id, (now() at time zone o.timezone)::date) #>> '{lessons,timetable_editing}', 'admin_only') as mode,
                                coalesce((org_settings_on(sl.org_id, (now() at time zone o.timezone)::date) #>> '{lessons,tutors_edit,weekly_slots}')::boolean, false) as sw_slots) c
     where sl.active and (s.end_date is null or s.end_date >= (now() at time zone o.timezone)::date)
     order by sl.weekday, sl.start_time, s.name, sl.id;
end $$;

-- ---------------------------------------------------------------- 13. staff: what tutors did in the last 7 days (replaces step 2's list; the lesson rows are unchanged)
-- `rows` is now ONE list, newest first, at most 100, each with kind: 'lesson' (a lesson a tutor moved, put back, cancelled or ADDED), 'slot' (a weekly slot a tutor added,
-- changed or stopped) or 'run' (a "Create lessons" press that made lessons). Needs manage_timetable. NO MONEY: awaiting_centre only says the lesson's details need the centre.
create or replace function public.staff_tutor_changes(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_attendance_gate(p_org, false); rows jsonb; tell boolean;
begin
  if not org_can(p_org, 'manage_timetable') then
    raise exception 'NOT_ALLOWED: your account can''t see timetable changes at this centre' using errcode = '42501'; end if;
  tell := coalesce(org_settings_on(p_org, today) #>> '{lessons,notify_family}', 'list_for_admin') = 'list_for_admin';
  select coalesce(jsonb_agg(u.j order by u.at desc, u.k), '[]'::jsonb) into rows from (
    select * from (
      select x.changed_by_tutor_at as at, x.id::text as k,
             jsonb_build_object(
               'kind', 'lesson', 'lesson_id', x.id, 'what', x.changed_by_tutor_what, 'changed_at', x.changed_by_tutor_at, 'reason', x.changed_by_tutor_reason,
               'tutor_id', x.changed_by_tutor,
               'tutor_name', case when t.id is null or t.status = 'disabled' then 'Former tutor' else coalesce(t.display_name, 'Tutor') end,
               'student_id', s.id, 'student_name', s.name, 'subject', x.subject,
               'lesson_date', x.lesson_date, 'start_time', x.start_time, 'end_time', x.end_time,
               'from_date', x.changed_from_date, 'from_start', x.changed_from_start, 'cancelled', (x.status = 'cancelled'), 'awaiting_centre', x.price_pending,
               'tell_family', tell) as j
        from lessons x
        join students s on s.id = x.student_id and s.org_id = x.org_id
        left join memberships t on t.id = x.changed_by_tutor and t.org_id = x.org_id
       where x.org_id = p_org and x.changed_by_tutor_at >= now() - interval '7 days'
      union all
      select x.changed_by_tutor_at, x.id::text,
             jsonb_build_object(
               'kind', 'slot', 'slot_id', x.id, 'what', x.changed_by_tutor_what, 'changed_at', x.changed_by_tutor_at, 'tutor_id', x.changed_by_tutor,
               'tutor_name', case when t.id is null or t.status = 'disabled' then 'Former tutor' else coalesce(t.display_name, 'Tutor') end,
               'student_id', s.id, 'student_name', s.name, 'subject', x.subject, 'weekday', x.weekday, 'start_time', x.start_time, 'end_time', x.end_time,
               'awaiting_centre', x.price_pending, 'tell_family', tell) as j
        from recurring_slots x
        join students s on s.id = x.student_id and s.org_id = x.org_id
        left join memberships t on t.id = x.changed_by_tutor and t.org_id = x.org_id
       where x.org_id = p_org and x.changed_by_tutor_at >= now() - interval '7 days'
      union all
      select a.at, a.id::text,
             jsonb_build_object(
               'kind', 'run', 'what', 'generated', 'changed_at', a.at, 'tutor_id', (a.after->>'tutor_id')::uuid,
               'tutor_name', case when t.id is null or t.status = 'disabled' then 'Former tutor' else coalesce(t.display_name, 'Tutor') end,
               'created', (a.after->>'created')::int, 'from_date', a.after->>'from', 'to_date', a.after->>'to', 'awaiting_centre', coalesce((a.after->>'awaiting_centre')::int, 0) > 0,
               'tell_family', tell) as j
        from audit_log a
        left join memberships t on t.id = (a.after->>'tutor_id')::uuid and t.org_id = a.org_id
       where a.org_id = p_org and a.action = 'tutor_generate_lessons' and a.at >= now() - interval '7 days' and coalesce((a.after->>'created')::int, 0) > 0
    ) z order by z.at desc, z.k limit 100) u;
  return jsonb_build_object('today', today, 'days', 7, 'tell_family', tell, 'rows', rows);
end $$;

-- ---------------------------------------------------------------- 14. staff: confirm the price of a lesson a tutor made (the one place the price is typed)
-- Needs issue_invoices (owner always): the same people who confirm pending charges. p_rate = S$ per hour, 0 to 1000 (0 = a free lesson, which is a valid answer).
-- p_same_student true = every still-waiting lesson and weekly slot of that student gets the same rate (a tutor's slot makes many lessons). A lesson that is paid, or already
-- on a draft or issued invoice, is not touched. Each lesson is audited with its before and after.
create or replace function public.staff_set_lesson_price(p_org uuid, p_lesson uuid, p_rate numeric, p_same_student boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := staff_charges_gate(p_org); l lessons; r numeric(8,2); n int := 0; ns int := 0; ids uuid[];
begin
  if p_rate is null or p_rate < 0 or p_rate > 1000 then raise exception 'BAD_RATE: the rate per hour must be between 0 and 1000' using errcode = 'P0001'; end if;
  r := round(p_rate, 2);
  select * into l from lessons where id = p_lesson and org_id = p_org;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if not l.price_pending then raise exception 'NOT_WAITING: this lesson''s price has already been confirmed' using errcode = 'P0001'; end if;
  select coalesce(array_agg(y.id), '{}') into ids from lessons y
   where y.org_id = p_org and y.price_pending and not y.paid
     and (y.id = l.id or (p_same_student and y.student_id = l.student_id))
     and not exists (select 1 from centre_invoice_lines cl join centre_invoices ci on ci.id = cl.invoice_id and ci.org_id = cl.org_id
                      where cl.lesson_id = y.id and cl.org_id = p_org and ci.status <> 'void');
  update lessons set rate = r, amount = round(round(r * (extract(epoch from (end_time - start_time)) / 3600)::numeric, 2) / greatest(coalesce(split, 1), 1), 2), price_pending = false
   where id = any(ids);
  get diagnostics n = row_count;
  if p_same_student then
    update recurring_slots set rate = r, price_pending = false where org_id = p_org and student_id = l.student_id and price_pending;
    get diagnostics ns = row_count;
  end if;
  insert into audit_log(org_id, actor, action, table_name, row_id, after)
  values (p_org, auth.uid(), 'staff_set_lesson_price', 'lessons', l.id::text, jsonb_build_object('rate', r, 'lessons', n, 'slots', ns, 'student_id', l.student_id));
  return jsonb_build_object('lessons', n, 'slots', ns, 'rate', r);
end $$;

-- ---------------------------------------------------------------- 15. the invoice run: a lesson whose price is not confirmed holds that family's invoice back
-- centre_invoice_run_rows is migration_centre_invoice_run.sql's function with TWO lines added (marked T6 step 3): the column in `base` and one `when` in `cls` that makes a
-- not-yet-confirmed, not-cancelled lesson state 'pending' (the existing held-back state: "charge pending: <student>"). Nothing else in it changes.
create or replace function public.centre_invoice_run_rows(p_org uuid, p_month date, p_today date)
returns table(unit_key text, household_id uuid, unit_student uuid, unit_name text, student_id uuid, student_name text,
              state text, line_kind text, ord int, lesson_id uuid, lesson_date date, start_time time,
              description text, qty int, unit_cents bigint, ref_id uuid)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare ms date := date_trunc('month', p_month)::date; me date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  s jsonb; v_post boolean; v_stu boolean; v_trials boolean; v_sib text; v_sib_bp bigint; v_sib_fix bigint; v_reg bigint; v_mat bigint; v_pct text;
begin
  s := coalesce(org_settings_on(p_org, ms), org_settings_on(p_org, p_today));
  if s is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  v_post   := coalesce(s#>>'{billing,model}', 'postpaid_lessons') = 'postpaid_lessons';
  v_stu    := coalesce(s#>>'{invoicing,grouping}', 'family') = 'student';
  v_trials := coalesce((s#>>'{billing,trials,charged}')::boolean, false);
  v_sib    := coalesce(s#>>'{billing,sibling_discount,type}', 'none');
  v_sib_bp := coalesce((s#>>'{billing,sibling_discount,percent_bp}')::bigint, 0);
  v_sib_fix:= coalesce((s#>>'{billing,sibling_discount,fixed_cents}')::bigint, 0);
  v_reg    := coalesce((s#>>'{billing,one_off_fees,registration_cents}')::bigint, 0);
  v_mat    := coalesce((s#>>'{billing,one_off_fees,materials_cents}')::bigint, 0);
  v_pct    := regexp_replace(to_char(v_sib_bp / 100.0, 'FM990.00'), '\.?0+$', '');

  return query
  with base as (                                   -- the month's lessons that are not already on a draft or issued document
    select l.id as lid, l.student_id as sid, l.lesson_date as ldate, l.start_time as stime, l.subject as subj,
           l.status as lstatus, l.attendance as att, l.trial as is_trial, l.compensation_cents as comp, l.price_pending as ppend,
           lesson_price_cents(l.amount, l.rate, l.start_time, l.end_time) as price
      from lessons l
     where l.org_id = p_org and l.lesson_date between ms and me
       and not exists (select 1 from centre_invoice_lines cl join centre_invoices ci on ci.id = cl.invoice_id and ci.org_id = cl.org_id
                        where cl.lesson_id = l.id and cl.org_id = p_org and ci.status <> 'void')
  ), cls as (
    select b.*,
      case
        when b.is_trial and not v_trials then 'free_trial'
        when b.ppend and b.lstatus <> 'cancelled' then 'pending'             -- T6 step 3: a tutor-made lesson whose price the centre has not confirmed yet
        when v_post and b.att in ('absent', 'cancelled_early', 'late_cancelled') and b.comp is null then 'pending'
        when b.lstatus = 'done' or (not v_post and b.lstatus = 'scheduled') then case when b.price > 0 then 'line' else 'no_price' end
        when v_post and b.lstatus = 'cancelled' and coalesce(b.comp, 0) > 0 then 'line'
        when v_post and b.lstatus = 'scheduled' and b.ldate < p_today then 'unmarked'
        else 'skip' end as st,
      case when b.lstatus = 'cancelled' then b.comp else b.price end as cents
      from base b
  ), keyed as (
    select c.*, st8.name as sname, st8.household_id as hid, st8.created_at as screated,
           case when v_stu then c.sid::text else coalesce(st8.household_id::text, c.sid::text) end as ukey,
           case when v_stu or st8.household_id is null then c.sid end as ustu,
           case when v_stu then st8.name else coalesce(h.name, st8.name) end as uname
      from cls c
      join students st8 on st8.id = c.sid and st8.org_id = p_org
      left join households h on h.id = st8.household_id and h.org_id = p_org
     where c.st <> 'skip'
  ), billed as (select * from keyed where st = 'line'),
  stu as (                                          -- per child billed in this run
    select b.sid, b.hid, min(b.screated) as screated, sum(b.cents)::bigint as total, sum(least(v_sib_fix, b.cents))::bigint as fixed_off,
           bool_or(not b.is_trial) as any_nontrial,
           (array_agg(b.ukey))[1] as ukey, (array_agg(b.ustu))[1] as ustu, (array_agg(b.uname))[1] as uname, (array_agg(b.sname))[1] as sname
      from billed b group by b.sid, b.hid
  ), ranked as (
    select st.*, case when st.hid is null then 1 else row_number() over (partition by st.hid order by st.screated, st.sid) end as rn from stu st
  ), disc as (
    select r.*, case v_sib when 'percent' then least(r.total, centre_div_round(r.total * v_sib_bp, 10000))
                           when 'fixed'   then least(r.total, r.fixed_off) else 0 end as off
      from ranked r where r.rn >= 2
  )
  select b.ukey, b.hid, b.ustu, b.uname, b.sid, b.sname, 'line'::text, 'lesson'::text, 0, b.lid, b.ldate, b.stime,
         left(coalesce(nullif(trim(b.subj), ''), 'Lesson'), 60) || case when b.lstatus = 'cancelled' then ' (cancelled, charged)' else '' end
           || ' · ' || to_char(b.ldate, 'Dy DD Mon') || ', ' || to_char(b.stime, 'FMHH12:MIam'),
         1, b.cents, null::uuid
    from billed b
  union all                                         -- signals the screen explains (no money on them)
  select k.ukey, k.hid, k.ustu, k.uname, k.sid, k.sname, k.st, 'lesson', 0, k.lid, k.ldate, k.stime, null::text, 1, 0::bigint, null::uuid
    from keyed k where k.st in ('pending', 'unmarked', 'no_price', 'free_trial')
  union all
  select d.ukey, d.hid, d.ustu, d.uname, d.sid, d.sname, 'line', 'sibling_discount', 1, null::uuid, null::date, null::time,
         case v_sib when 'percent' then 'Sibling discount (' || v_pct || '%)' else 'Sibling discount (S$' || to_char(v_sib_fix / 100.0, 'FM999990.00') || ' off each lesson)' end,
         1, -d.off, null::uuid
    from disc d where d.off > 0
  union all
  select r.ukey, r.hid, r.ustu, r.uname, r.sid, r.sname, 'line', k.kind, case k.kind when 'registration' then 2 else 3 end, null::uuid, null::date, null::time,
         case k.kind when 'registration' then 'Registration fee' else 'Materials fee' end, 1, k.amt, null::uuid
    from stu r cross join lateral (values ('registration', v_reg), ('materials', v_mat)) k(kind, amt)
   where r.any_nontrial and k.amt > 0
     and not exists (select 1 from centre_invoice_lines fl join centre_invoices fi on fi.id = fl.invoice_id and fi.org_id = fl.org_id
                      where fl.org_id = p_org and fl.student_id = r.sid and fl.fee_kind = k.kind and fi.status <> 'void')
  union all                                         -- a draft already exists for this household / student and month
  select coalesce(ci.student_id::text, ci.household_id::text), ci.household_id, ci.student_id,
         case when v_stu then sd.name else coalesce(hd.name, sd.name) end, ci.student_id, sd.name, 'draft_exists', 'invoice', 0,
         null::uuid, null::date, null::time, null::text, 1, ci.total_cents, ci.id
    from centre_invoices ci
    left join households hd on hd.id = ci.household_id and hd.org_id = ci.org_id
    left join students sd on sd.id = ci.student_id and sd.org_id = ci.org_id
   where ci.org_id = p_org and ci.kind = 'lesson' and ci.status = 'draft' and ci.period_start = ms;
end $$;

-- ---------------------------------------------------------------- who may call what
do $$
declare f text;
begin
  foreach f in array array['tutor_my_students()', 'tutor_add_lesson(uuid,date,time,time,text,text)', 'tutor_save_slot(uuid,uuid,int,time,time,text)', 'tutor_stop_slot(uuid)',
                           'tutor_generate_lessons(uuid,date,date)', 'tutor_my_schedule(date,date)', 'tutor_my_slots()', 'staff_tutor_changes(uuid)',
                           'staff_set_lesson_price(uuid,uuid,numeric,boolean)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['tutor_own_gate(uuid,uuid,text)', 'tutor_own_limit_check(uuid,jsonb)', 'tutor_changes_used(uuid,uuid,text)', 'tutor_basis_for(uuid,uuid)',
                           'tutor_own_insert_lesson(uuid,uuid,uuid,date,time,time,text,text)', 'tutor_own_insert_slot(uuid,uuid,uuid,int,time,time,text)',
                           'tutor_own_generate(uuid,uuid,date,date,boolean,int,text)', 'centre_invoice_run_rows(uuid,date,date)', 'tutor_change_block(uuid,text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;
