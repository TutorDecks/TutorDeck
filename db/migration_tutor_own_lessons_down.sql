-- Undo of migration_tutor_own_lessons.sql (T6 steps 3 and 4): the new tutor functions and helpers, the new columns, and the step 1 / step 2 versions of the functions it replaced
-- (tutor_change_block, tutor_my_schedule, tutor_my_slots, staff_tutor_changes) and of the invoice run's row function.
-- KEPT (real data): lessons and slots a tutor made stay; they simply lose their "made by a tutor" and "price waiting" marks. A lesson that was waiting for its price keeps price
-- 0, so the invoice run then reports it as "no price" instead of holding the invoice back. Audit rows stay (append-only).

drop function if exists public.tutor_my_students();
drop function if exists public.tutor_add_lesson(uuid, date, time, time, text, text);
drop function if exists public.tutor_save_slot(uuid, uuid, int, time, time, text);
drop function if exists public.tutor_stop_slot(uuid);
drop function if exists public.tutor_generate_lessons(uuid, date, date);
drop function if exists public.staff_set_lesson_price(uuid, uuid, numeric, boolean);
drop function if exists public.tutor_own_generate(uuid, uuid, date, date, boolean, int, text);
drop function if exists public.tutor_own_insert_slot(uuid, uuid, uuid, int, time, time, text);
drop function if exists public.tutor_own_insert_lesson(uuid, uuid, uuid, date, time, time, text, text);
drop function if exists public.tutor_basis_for(uuid, uuid);
drop function if exists public.tutor_own_limit_check(uuid, jsonb);
drop function if exists public.tutor_own_gate(uuid, uuid, text);

-- the step 2 rulebook (counts only the three step 2 actions again)
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
    select count(*) into used from audit_log a
     where a.org_id = l.org_id and a.actor = me and a.action in ('tutor_postpone_lesson', 'tutor_revert_lesson', 'tutor_cancel_lesson')
       and a.at >= date_trunc('month', now() at time zone tz) at time zone tz;
    if used >= mx then
      return 'LIMIT: you have used your ' || mx || ' schedule change' || case when mx = 1 then '' else 's' end || ' for this month. Ask an admin'; end if;
  end if;
  return null;
end $$;

-- the step 2 tutor_my_schedule and staff_tutor_changes
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
                                      'changes_left', case when c.mx > 0 and c.mode = 'tutors_direct' then greatest(0, c.mx - (
                                          select count(*) from audit_log a where a.org_id = o.id and a.actor = auth.uid()
                                             and a.action in ('tutor_postpone_lesson', 'tutor_revert_lesson', 'tutor_cancel_lesson')
                                             and a.at >= date_trunc('month', now() at time zone o.timezone) at time zone o.timezone)) end)
                      order by o.trading_name, o.id),
         min((now() at time zone o.timezone)::date)
    into orgs, today
    from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
    cross join lateral (select org_settings_on(o.id, (now() at time zone o.timezone)::date) as s) cfg
    cross join lateral (select coalesce(cfg.s #>> '{lessons,timetable_editing}', 'admin_only') as mode,
                               coalesce((cfg.s #>> '{lessons,tutors_edit,postpone}')::boolean, true) as sw_postpone,
                               coalesce((cfg.s #>> '{lessons,tutors_edit,cancel}')::boolean, false) as sw_cancel,
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
           'changed_by_you', (l.changed_by_tutor_what), 'class_size', (select count(*)::int from lessons y where l.session_id is not null and y.org_id = l.org_id and y.session_id = l.session_id)
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

create or replace function public.staff_tutor_changes(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_attendance_gate(p_org, false); rows jsonb; tell boolean;
begin
  if not org_can(p_org, 'manage_timetable') then
    raise exception 'NOT_ALLOWED: your account can''t see timetable changes at this centre' using errcode = '42501'; end if;
  tell := coalesce(org_settings_on(p_org, today) #>> '{lessons,notify_family}', 'list_for_admin') = 'list_for_admin';
  select coalesce(jsonb_agg(jsonb_build_object(
           'lesson_id', x.id, 'what', x.changed_by_tutor_what, 'changed_at', x.changed_by_tutor_at, 'reason', x.changed_by_tutor_reason,
           'tutor_id', x.changed_by_tutor,
           'tutor_name', case when t.id is null or t.status = 'disabled' then 'Former tutor' else coalesce(t.display_name, 'Tutor') end,
           'student_id', s.id, 'student_name', s.name, 'subject', x.subject,
           'lesson_date', x.lesson_date, 'start_time', x.start_time, 'end_time', x.end_time,
           'from_date', x.changed_from_date, 'from_start', x.changed_from_start, 'cancelled', (x.status = 'cancelled'), 'tell_family', tell)
           order by x.changed_by_tutor_at desc, x.id), '[]'::jsonb)
    into rows
    from (select * from lessons y where y.org_id = p_org and y.changed_by_tutor_at >= now() - interval '7 days'
           order by y.changed_by_tutor_at desc, y.id limit 100) x
    join students s on s.id = x.student_id and s.org_id = x.org_id
    left join memberships t on t.id = x.changed_by_tutor and t.org_id = x.org_id;
  return jsonb_build_object('today', today, 'days', 7, 'tell_family', tell, 'rows', rows);
end $$;

-- the step 1 tutor_my_slots
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


-- the invoice run's row function exactly as migration_centre_invoice_run.sql made it
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
           l.status as lstatus, l.attendance as att, l.trial as is_trial, l.compensation_cents as comp,
           lesson_price_cents(l.amount, l.rate, l.start_time, l.end_time) as price
      from lessons l
     where l.org_id = p_org and l.lesson_date between ms and me
       and not exists (select 1 from centre_invoice_lines cl join centre_invoices ci on ci.id = cl.invoice_id and ci.org_id = cl.org_id
                        where cl.lesson_id = l.id and cl.org_id = p_org and ci.status <> 'void')
  ), cls as (
    select b.*,
      case
        when b.is_trial and not v_trials then 'free_trial'
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


drop function if exists public.tutor_changes_used(uuid, uuid, text);
drop trigger if exists price_pending_guard on public.lessons;
drop trigger if exists price_pending_guard on public.recurring_slots;
drop function if exists public.price_pending_guard();

-- the columns: a lesson a tutor ADDED loses that mark (step 2's check allows only moved | reverted | cancelled)
update public.lessons set changed_by_tutor_what = null, changed_by_tutor_at = null, changed_by_tutor = null, changed_by_tutor_reason = null where changed_by_tutor_what = 'added';
alter table public.lessons drop constraint if exists lessons_changed_by_tutor_what_ok;
alter table public.lessons add constraint lessons_changed_by_tutor_what_ok check (changed_by_tutor_what is null or changed_by_tutor_what in ('moved', 'reverted', 'cancelled'));
alter table public.lessons drop constraint if exists lessons_created_by_tutor_same_org;
alter table public.recurring_slots drop constraint if exists slots_created_by_tutor_same_org;
alter table public.recurring_slots drop constraint if exists slots_changed_by_tutor_same_org;
alter table public.recurring_slots drop constraint if exists slots_changed_by_tutor_what_ok;
drop index if exists public.slots_changed_by_tutor;
drop index if exists public.lessons_price_pending;
alter table public.lessons drop column if exists price_pending;
alter table public.lessons drop column if exists created_by_tutor;
alter table public.recurring_slots drop column if exists price_pending;
alter table public.recurring_slots drop column if exists created_by_tutor;
alter table public.recurring_slots drop column if exists changed_by_tutor_at;
alter table public.recurring_slots drop column if exists changed_by_tutor;
alter table public.recurring_slots drop column if exists changed_by_tutor_what;
alter table public.recurring_slots drop column if exists changed_by_tutor_reason;

do $$
declare f text;
begin
  foreach f in array array['tutor_my_schedule(date,date)', 'tutor_my_slots()', 'staff_tutor_changes(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['tutor_change_block(uuid,text)', 'centre_invoice_run_rows(uuid,date,date)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;
