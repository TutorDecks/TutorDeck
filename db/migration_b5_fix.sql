-- B5-FIX (bundle 5 test findings A, F, H1, H2). Needs migration_tutor_moves.sql and everything before it. Safe to run twice. Undo: migration_b5_fix_down.sql.
--
-- A  A brand-new student got no deposit. The deposit candidates read the settings in force on the 1st of the invoice month. A centre that saved its deposit
--    setting today (it starts today, or on the next cycle) has no deposit in the settings of the 1st, so the run said nothing and raised nothing.
--    A deposit is a one-off charge raised NOW, so it follows the settings in force TODAY (the 1st only if today has none). New:
--    centre_deposit_run_why(org, period) answers, in plain words, why a student who is in the run gets no deposit (and what to do), and
--    when the setting simply starts later.
-- F  A student who is leaving a class on a future day ("Leaves from") could not be put back: the picker hid them and the database said "already in this slot".
--    staff_slot_student(... 'add') now cancels a pending departure (the student stays, lessons that were removed are made again from the chosen day).
-- H1 staff_save_slot also adds the tutor to the student's assigned tutors when an existing slot is CHANGED (it did so only for a new slot), and the answer
--    always says what happened: assign.state = added | already | off | no_tutor.
-- H2 staff_tutor_changes lists every change (move / put back / cancel), newest first, at most 50, not only the latest change of each lesson.

-- ---------------------------------------------------------------- A. deposits follow today's settings
create or replace function public.centre_deposit_run_candidates(p_org uuid, p_ms date, p_today date)
returns table(d_student_id uuid, d_student_name text, d_household_id uuid, d_unit_key text, d_deposit_id uuid, d_mode text, d_percent_bp int,
              d_first_month_cents bigint, d_amount_cents bigint, d_taxable boolean, d_frozen boolean)
language plpgsql security definer set search_path = public, pg_temp as $$
declare s jsonb := coalesce(org_settings_on(p_org, p_today), org_settings_on(p_org, p_ms)); me date := (p_ms + interval '1 month - 1 day')::date;
  v_mode text; v_due text; v_bp int; v_fix bigint; v_tax boolean;
begin
  if s is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  v_mode := coalesce(s#>>'{billing,deposit,mode}', 'none');
  v_due  := coalesce(s#>>'{billing,deposit,due}', 'with_first_invoice');
  v_bp   := coalesce((s#>>'{billing,deposit,percent_bp}')::int, 0);
  v_fix  := coalesce((s#>>'{billing,one_off_fees,deposit_cents}')::bigint, 0);
  v_tax  := coalesce((s#>>'{billing,deposit,taxable}')::boolean, false);
  return query
  with fm as (                                       -- each student's non-trial lesson fee in an invoice that is READY (before discounts, fees and GST)
    select r.unit_key as ukey, r.student_id as sid, max(r.student_name) as sname, sum(r.qty * r.unit_cents)::bigint as cents
      from _td_run r
      join _td_units u on u.unit_key = r.unit_key and u.status = 'ready'
      join lessons l on l.id = r.lesson_id and l.org_id = p_org
     where r.state = 'line' and r.line_kind = 'lesson' and not coalesce(l.trial, false)
     group by r.unit_key, r.student_id
  )
  select st.id, st.name, st.household_id, fm.ukey, null::uuid,
         case v_mode when 'fixed' then 'fixed' else 'percent_first_month' end,
         case when v_mode = 'percent_first_month' then v_bp end,
         fm.cents,
         case v_mode when 'fixed' then v_fix when 'percent_first_month' then centre_div_round(fm.cents * v_bp, 10000) else 0 end,
         v_tax, false
    from fm join students st on st.id = fm.sid and st.org_id = p_org
   where v_mode in ('fixed', 'percent_first_month') and v_due = 'with_first_invoice'
     and not exists (select 1 from centre_deposits d where d.org_id = p_org and d.student_id = st.id)
     and not exists (select 1 from centre_invoice_lines cl join centre_invoices ci on ci.id = cl.invoice_id and ci.org_id = cl.org_id
                      where cl.org_id = p_org and cl.student_id = st.id and ci.kind in ('lesson', 'opening') and ci.status <> 'void' and ci.period_start <= p_ms)
     and case v_mode when 'fixed' then v_fix when 'percent_first_month' then centre_div_round(fm.cents * v_bp, 10000) else 0 end > 0
  union all
  select st.id, st.name, st.household_id, fm.ukey, d.id, d.mode, d.percent_bp, d.first_month_cents, d.required_cents, d.taxable, true
    from fm join students st on st.id = fm.sid and st.org_id = p_org
    join centre_deposits d on d.org_id = p_org and d.student_id = st.id and d.source = 'invoice_run'
   where d.invoice_id is null or exists (select 1 from centre_invoices i where i.id = d.invoice_id and i.org_id = p_org and i.status = 'void');
end $$;

-- why a student in the run gets no deposit. Needs issue_invoices (same as the run). No money other than the deposit's own amount.
-- note = a sentence about the setting itself (null when nothing to say); rows = one per student who is in the run and gets none, with a plain reason.
create or replace function public.centre_deposit_run_why(p_org uuid, p_period date) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := centre_invoicing_gate(p_org); ms date := centre_invoice_month(p_period, today);
  s jsonb := coalesce(org_settings_on(p_org, today), org_settings_on(p_org, ms)); v_mode text; v_due text; v_fix bigint; v_bp int; note text; later date; got uuid[];
  rows jsonb := '[]'::jsonb; r record; why text; lbl text := to_char(ms, 'FMMonth YYYY');
begin
  if s is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  v_mode := coalesce(s#>>'{billing,deposit,mode}', 'none'); v_due := coalesce(s#>>'{billing,deposit,due}', 'with_first_invoice');
  v_fix := coalesce((s#>>'{billing,one_off_fees,deposit_cents}')::bigint, 0); v_bp := coalesce((s#>>'{billing,deposit,percent_bp}')::int, 0);
  note := centre_deposit_note(s);
  if v_mode = 'none' then
    select min(x.effective_from) into later from org_settings x
     where x.org_id = p_org and x.effective_from > today and coalesce(x.settings#>>'{billing,deposit,mode}', 'none') <> 'none';
    note := case when later is not null then 'No deposit is raised today: the deposit setting you saved starts on ' || to_char(later, 'FMDD FMMonth YYYY') || ' (billing settings change from the next cycle). Run again from then.'
                 else 'No deposit is raised: the deposit setting is “No deposit”.' end;
  end if;
  if v_mode in ('fixed', 'percent_first_month') and v_due = 'with_first_invoice' and note is null then
    perform centre_invoice_run_prepare(p_org, ms, today);
    select coalesce(array_agg(c.d_student_id), '{}') into got from centre_deposit_run_candidates(p_org, ms, today) c;
    for r in select st.id as sid, st.name as sname, (select min(q.unit_key) from _td_run q where q.student_id = st.id) as ukey
               from students st where st.org_id = p_org and exists (select 1 from lessons l where l.org_id = p_org and l.student_id = st.id and l.lesson_date between ms and (ms + interval '1 month - 1 day')::date)
              order by st.name, st.id loop
      continue when r.sid = any(got);
      why := null;
      if exists (select 1 from centre_deposits d where d.org_id = p_org and d.student_id = r.sid) then
        why := 'already has a deposit (see Money > Deposits). A student has one deposit.';
      elsif exists (select 1 from centre_invoice_lines cl join centre_invoices ci on ci.id = cl.invoice_id and ci.org_id = cl.org_id
                     where cl.org_id = p_org and cl.student_id = r.sid and ci.kind in ('lesson', 'opening') and ci.status = 'issued' and ci.period_start <= ms) then
        why := 'was already invoiced before this run. A deposit is raised only with a student’s first lesson invoice.';
      elsif exists (select 1 from centre_invoice_lines cl join centre_invoices ci on ci.id = cl.invoice_id and ci.org_id = cl.org_id
                     where cl.org_id = p_org and cl.student_id = r.sid and ci.kind in ('lesson', 'opening') and ci.status = 'draft' and ci.period_start <= ms) then
        why := 'already has a draft invoice from an earlier run. A deposit is raised only when the first lesson invoice is made. Discard that draft and run again to get one.';
      elsif exists (select 1 from _td_units u where u.unit_key = r.ukey and u.status = 'held') then
        why := 'is held back (a lesson is waiting for its charge or a mark). The deposit comes with the first invoice.';
      elsif not exists (select 1 from _td_run q join lessons l on l.id = q.lesson_id and l.org_id = p_org
                         where q.student_id = r.sid and q.state = 'line' and q.line_kind = 'lesson' and not coalesce(l.trial, false)) then
        why := 'has no lesson ready to invoice yet, only trial lessons or lessons not marked yet.';
      elsif (case v_mode when 'fixed' then v_fix else 0 end) <= 0 and v_mode = 'fixed' then
        why := 'would get a deposit of S$0.00.';
      end if;
      if why is not null then rows := rows || jsonb_build_object('student_id', r.sid, 'name', r.sname, 'reason', why); end if;
    end loop;
  end if;
  return jsonb_build_object('period_start', ms, 'month', lbl, 'mode', v_mode, 'note', note, 'rows', rows);
end $$;
revoke all on function public.centre_deposit_run_why(uuid, date) from public, anon;
grant execute on function public.centre_deposit_run_why(uuid, date) to authenticated;

-- ---------------------------------------------------------------- F + H1. slot functions (wrappers around the originals, renamed *_core)
do $$ begin
  if to_regprocedure('public.staff_save_slot_core(uuid,uuid,uuid[],integer,time without time zone,time without time zone,uuid,text,numeric)') is null then
    alter function public.staff_save_slot(uuid, uuid, uuid[], int, time, time, uuid, text, numeric) rename to staff_save_slot_core;
  end if;
  if to_regprocedure('public.staff_slot_student_core(uuid,uuid,uuid,text,date,boolean)') is null then
    alter function public.staff_slot_student(uuid, uuid, uuid, text, date, boolean) rename to staff_slot_student_core;
  end if;
end $$;
revoke all on function public.staff_save_slot_core(uuid, uuid, uuid[], int, time, time, uuid, text, numeric) from public, anon, authenticated;
revoke all on function public.staff_slot_student_core(uuid, uuid, uuid, text, date, boolean) from public, anon, authenticated;

create or replace function public.staff_save_slot(p_org uuid, p_slot uuid, p_students uuid[], p_weekday int, p_start time, p_end time,
                                                  p_tutor uuid default null, p_subject text default null, p_rate numeric default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare res jsonb; today date; auto boolean; ids uuid[]; sid uuid; tname text; sname text; assigned jsonb; n_already int := 0; n_missing int := 0; state text;
begin
  res := staff_save_slot_core(p_org, p_slot, p_students, p_weekday, p_start, p_end, p_tutor, p_subject, p_rate);       -- every check, and a new slot's own auto-assign, happen there
  today := staff_slots_gate(p_org, true);
  if p_tutor is null then return res || jsonb_build_object('assign', jsonb_build_object('state', 'no_tutor')); end if;
  auto := case when jsonb_typeof(org_settings_on(p_org, today) #> '{lessons,auto_assign_tutors}') = 'boolean'
               then (org_settings_on(p_org, today) #>> '{lessons,auto_assign_tutors}')::boolean else true end;
  select coalesce(m.display_name, 'Tutor') into tname from memberships m where m.id = p_tutor and m.org_id = p_org;
  assigned := coalesce(res->'assigned', '[]'::jsonb);
  select coalesce(array_agg(x::uuid), '{}') into ids from jsonb_array_elements_text(coalesce(res->'slot_ids', '[]'::jsonb)) x;
  if p_slot is not null and auto then                                         -- a CHANGED slot: the new tutor joins the students' assigned tutors too (never removes anyone)
    for sid in select distinct x.student_id from recurring_slots x where x.id = any(ids) loop
      if not exists (select 1 from student_tutors x where x.org_id = p_org and x.student_id = sid and x.membership_id = p_tutor and x.active) then
        insert into student_tutors(org_id, student_id, membership_id, since, created_by) values (p_org, sid, p_tutor, today, auth.uid());
        select s.name into sname from students s where s.id = sid;
        assigned := assigned || jsonb_build_object('student_id', sid, 'student_name', sname, 'tutor_name', tname);
      end if;
    end loop;
    if jsonb_array_length(assigned) > 0 then
      insert into audit_log(org_id, actor, action, table_name, row_id, after)
      values (p_org, auth.uid(), 'staff_auto_assign_tutor', 'student_tutors', ids[1]::text, jsonb_build_object('tutor', p_tutor, 'assigned', assigned, 'on_change', true));
    end if;
  end if;
  select count(*) filter (where exists (select 1 from student_tutors x where x.org_id = p_org and x.student_id = z.student_id and x.membership_id = p_tutor and x.active)),
         count(*) filter (where not exists (select 1 from student_tutors x where x.org_id = p_org and x.student_id = z.student_id and x.membership_id = p_tutor and x.active))
    into n_already, n_missing from (select distinct x.student_id from recurring_slots x where x.id = any(ids)) z;
  n_already := greatest(n_already - jsonb_array_length(assigned), 0);
  state := case when jsonb_array_length(assigned) > 0 then 'added' when n_missing > 0 and not auto then 'off' when n_already > 0 then 'already' else 'none' end;
  return res || jsonb_build_object('assigned', assigned, 'assign', jsonb_build_object('state', state, 'tutor_name', tname, 'already', n_already, 'missing', n_missing));
end $$;
revoke all on function public.staff_save_slot(uuid, uuid, uuid[], int, time, time, uuid, text, numeric) from public, anon;
grant execute on function public.staff_save_slot(uuid, uuid, uuid[], int, time, time, uuid, text, numeric) to authenticated;

create or replace function public.staff_slot_student(p_org uuid, p_slot uuid, p_student uuid, p_action text, p_from date default null, p_dry boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare today date := staff_slots_gate(p_org, true); f date := coalesce(p_from, today); sl recurring_slots; mine recurring_slots; ids uuid[]; last_d date; skip boolean;
        n int := 0; made jsonb := jsonb_build_object('created', 0);
begin
  if p_action = 'add' and f >= today and f <= today + 1095 then
    select * into sl from recurring_slots where id = p_slot and org_id = p_org and active and (stopped_from is null or stopped_from > today);
    if found then
      select coalesce(array_agg(x.id), '{}') into ids from recurring_slots x
       where x.org_id = p_org and x.active and (x.stopped_from is null or x.stopped_from > today) and (x.id = sl.id or (sl.session_key is not null and x.session_key = sl.session_key));
      select * into mine from recurring_slots x where x.id = any(ids) and x.student_id = p_student and x.stopped_from is not null;
      if found then                                                         -- the student is leaving on a day to come: they stay
        select max(l.lesson_date) into last_d from lessons l where l.org_id = p_org and l.slot_id = any(ids) and l.student_id <> p_student and l.lesson_date >= f;
        last_d := least(last_d, f + 181);
        skip := case when jsonb_typeof(org_settings_on(p_org, today) #> '{calendar,skip_holidays}') = 'boolean'
                     then (org_settings_on(p_org, today) #>> '{calendar,skip_holidays}')::boolean else true end;
        if p_dry is not false then
          if last_d is not null then
            select count(*) into n from generate_series(f, last_d, interval '1 day') d
             where (extract(isodow from d)::int - 1) = mine.weekday
               and not (skip and exists (select 1 from holidays h where h.org_id = p_org and h.branch_id is null and d::date between h.starts_on and h.ends_on))
               and not exists (select 1 from lessons l where l.org_id = p_org and l.student_id = p_student and l.lesson_date = d::date and l.start_time = mine.start_time);
          end if;
          return jsonb_build_object('dry', true, 'returned', true, 'added', 0, 'would_create', n, 'students', array_length(ids, 1));
        end if;
        perform pg_advisory_xact_lock(hashtextextended('staff_generate_lessons:' || p_org::text, 0));
        update recurring_slots set stopped_from = null, active = true where id = mine.id;
        if last_d is not null then made := staff_generate_core(p_org, f, last_d, skip, array[mine.id]); end if;
        insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
        values (p_org, auth.uid(), 'staff_slot_student_return', 'recurring_slots', mine.id::text, jsonb_build_object('stopped_from', mine.stopped_from),
                jsonb_build_object('slot_ids', ids, 'student', p_student, 'from', f, 'lessons_created', (made->>'created')::int));
        return jsonb_build_object('dry', false, 'returned', true, 'added', 0, 'slot_id', mine.id, 'created', (made->>'created')::int, 'assigned', '[]'::jsonb, 'students', array_length(ids, 1));
      end if;
    end if;
  end if;
  return staff_slot_student_core(p_org, p_slot, p_student, p_action, p_from, p_dry);
end $$;
revoke all on function public.staff_slot_student(uuid, uuid, uuid, text, date, boolean) from public, anon;
grant execute on function public.staff_slot_student(uuid, uuid, uuid, text, date, boolean) to authenticated;

-- ---------------------------------------------------------------- H2. tutor changes: one row per change
-- Needs manage_timetable. The last 7 days of the audit log (move / put back / cancel by a tutor), newest first, at most 50 rows; a class change gives one row per student's lesson.
create or replace function public.staff_tutor_changes(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_attendance_gate(p_org, false); rows jsonb; tell boolean;
begin
  if not org_can(p_org, 'manage_timetable') then
    raise exception 'NOT_ALLOWED: your account can''t see timetable changes at this centre' using errcode = '42501'; end if;
  tell := coalesce(org_settings_on(p_org, today) #>> '{lessons,notify_family}', 'list_for_admin') = 'list_for_admin';
  select coalesce(jsonb_agg(jsonb_build_object(
           'lesson_id', y.id, 'what', c.what, 'changed_at', c.at, 'reason', c.reason, 'tutor_id', t.id,
           'tutor_name', case when t.id is null or t.status = 'disabled' then 'Former tutor' else coalesce(t.display_name, 'Tutor') end,
           'student_id', s.id, 'student_name', s.name, 'subject', y.subject,
           'lesson_date', coalesce((c.after_e->>'lesson_date')::date, y.lesson_date), 'start_time', coalesce((c.after_e->>'start_time')::time, y.start_time),
           'end_time', coalesce((c.after_e->>'end_time')::time, y.end_time),
           'from_date', (c.before_e->>'lesson_date')::date, 'from_start', (c.before_e->>'start_time')::time,
           'cancelled', (c.what = 'cancelled'), 'tell_family', tell) order by c.at desc, c.aid, y.id), '[]'::jsonb)
    into rows
    from (select z.* from (
            select a.id as aid, a.at, a.actor, a.after->>'what' as what, a.after->>'reason' as reason, ae.e as after_e,
                   (select b.e from jsonb_array_elements(coalesce(a.before->'lessons', '[]'::jsonb)) b(e) where b.e->>'lesson_id' = ae.e->>'lesson_id' limit 1) as before_e,
                   (ae.e->>'lesson_id')::uuid as lid
              from audit_log a cross join lateral jsonb_array_elements(coalesce(a.after->'lessons', '[]'::jsonb)) ae(e)
             where a.org_id = p_org and a.action in ('tutor_postpone_lesson', 'tutor_revert_lesson', 'tutor_cancel_lesson') and a.at >= now() - interval '7 days') z
           order by z.at desc, z.aid limit 50) c
    join lessons y on y.id = c.lid and y.org_id = p_org
    join students s on s.id = y.student_id and s.org_id = y.org_id
    left join memberships t on t.user_id = c.actor and t.org_id = p_org and t.role = 'tutor';
  return jsonb_build_object('today', today, 'days', 7, 'tell_family', tell, 'rows', rows);
end $$;
