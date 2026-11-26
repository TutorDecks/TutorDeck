-- T3 step 5 tests: staff_set_trial, the Trial filter of staff_lessons, the fee count, and the tutor setting trials_flagged_by (both values).
-- Runs after staff_charges_test.sql in the same throwaway database (reuses the t.* helpers). Builds its own centre and made-up people.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000a801', 'st.owner@centre.test'),   ('00000000-0000-0000-0000-00000000a802', 'st.staff@centre.test'),
  ('00000000-0000-0000-0000-00000000a803', 'st.look@centre.test'),    ('00000000-0000-0000-0000-00000000a804', 'st.tutor1@centre.test'),
  ('00000000-0000-0000-0000-00000000a806', 'st.outsider@centre.test'),('00000000-0000-0000-0000-00000000a807', 'st.off@centre.test'),
  ('00000000-0000-0000-0000-00000000a809', 'st.owner2@centre.test'),  ('00000000-0000-0000-0000-00000000a80a', 'st.solo@centre.test');
set role authenticated; select t.as('00000000-0000-0000-0000-00000000a801');
select t.put('st', org_create_centre('Trial Centre', t.centre_settings()));
select t.as('00000000-0000-0000-0000-00000000a809');
select t.put('st2', org_create_centre('Other Trial Centre', t.centre_settings()));
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('st'), '00000000-0000-0000-0000-00000000a802', 'Staff Sam',    'staff', array['manage_timetable', 'manage_students'], 'active'),
  (t.id('st'), '00000000-0000-0000-0000-00000000a803', 'Front Desk',   'staff', array['manage_students'], 'active'),
  (t.id('st'), '00000000-0000-0000-0000-00000000a804', 'Tutor One',    'tutor', '{}', 'active'),
  (t.id('st'), '00000000-0000-0000-0000-00000000a807', 'Switched off', 'staff', array['manage_timetable'], 'disabled');
select t.put('m1', (select id from memberships where org_id = t.id('st') and user_id = '00000000-0000-0000-0000-00000000a804'));

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today;
grant select on td to authenticated, anon;
-- Ravi has ONE lesson this month (today, attended). Mei has two (today, attended). Cara has one (today, attended, already a trial).
insert into students(id, tutor_id, org_id, name, level) values
  ('00000000-0000-0000-0000-00000000a8a1', '00000000-0000-0000-0000-00000000a801', t.id('st'), 'Ravi', 'P4'),
  ('00000000-0000-0000-0000-00000000a8a2', '00000000-0000-0000-0000-00000000a801', t.id('st'), 'Mei',  'P5'),
  ('00000000-0000-0000-0000-00000000a8a3', '00000000-0000-0000-0000-00000000a801', t.id('st'), 'Cara', 'P6');
create function pg_temp.mk(p_student uuid, p_off int, p_att text default null, p_trial boolean default false) returns uuid language sql as $$
  insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, taught_by, subject, attendance, trial)
  values ('00000000-0000-0000-0000-00000000a801', t.id('st'), p_student, (select today from td) + p_off, '16:00', '17:00', 55, 55, 'scheduled', t.id('m1'), 'Math', p_att, p_trial)
  returning id $$;
select t.put('LR', pg_temp.mk('00000000-0000-0000-0000-00000000a8a1', 0, 'attended'));
select t.put('LM1', pg_temp.mk('00000000-0000-0000-0000-00000000a8a2', 0, 'attended'));
select t.put('LM2', pg_temp.mk('00000000-0000-0000-0000-00000000a8a2', 0, 'attended'));
select t.put('LC', pg_temp.mk('00000000-0000-0000-0000-00000000a8a3', 0, 'attended', true));
select t.put('LF', pg_temp.mk('00000000-0000-0000-0000-00000000a8a1', 1));          -- tomorrow, unmarked
select t.put('LU', pg_temp.mk('00000000-0000-0000-0000-00000000a8a2', 0));          -- today, unmarked

create function pg_temp.refused(p_user text, p_sql text, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  begin execute p_sql; exception when others then m := sqlerrm; end;
  if m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS refused: % (%)', p_msg, m;
end $$;
create function pg_temp.n_active() returns int language sql as $$ select org_active_students_in_month(t.id('st'), (select today from td)) $$;

-- ===================================================================== the fee count (before any flagging)
select t.eq(pg_temp.n_active(), 2, 'before: Ravi and Mei count (Cara''s only lesson is already a trial)');

-- ===================================================================== staff flag Ravi's lesson
select t.as('00000000-0000-0000-0000-00000000a802'); set role authenticated;
select staff_set_trial(t.id('LR'), true) as r \gset
reset role;
select t.ok((:'r'::jsonb->>'trial')::boolean and (select trial from lessons where id = t.id('LR')), 'staff with manage_timetable flag a lesson as a trial');
select t.eq(pg_temp.n_active(), 1, 'Ravi''s only lesson this month is a trial, so he drops out of the active-student count');
select t.ok((select before->>'trial' = 'false' and after->>'trial' = 'true' and actor = '00000000-0000-0000-0000-00000000a802' and at is not null
               from audit_log where action = 'staff_set_trial' and row_id = t.id('LR')::text), 'an audit entry names who, when, the old and the new value');
select t.as('00000000-0000-0000-0000-00000000a802'); set role authenticated;
select staff_set_trial(t.id('LR'), false);
reset role;
select t.eq(pg_temp.n_active(), 2, 'unflagging puts him back in the count');
select t.eq((select count(*) from audit_log where action = 'staff_set_trial' and row_id = t.id('LR')::text), 2, 'both changes were recorded');
select t.as('00000000-0000-0000-0000-00000000a802'); set role authenticated;
select staff_set_trial(t.id('LR'), true);
-- a student with two lessons stays active when only one is a trial
select staff_set_trial(t.id('LM1'), true);
reset role;
select t.eq(pg_temp.n_active(), 1, 'Mei has a second non-trial lesson, so she stays counted (Ravi does not)');
-- a future or unmarked lesson can be flagged too (it just doesn't count yet either way)
select t.as('00000000-0000-0000-0000-00000000a802'); set role authenticated;
select staff_set_trial(t.id('LF'), true);
reset role;
select t.ok((select trial from lessons where id = t.id('LF')), 'a lesson that has not been marked (or is tomorrow) can be flagged ahead');

-- ===================================================================== the list: Trial filter and count
select t.as('00000000-0000-0000-0000-00000000a802'); set role authenticated;
select staff_lessons(t.id('st'), (select today from td), (select today + 1 from td), null, 'trial') as lt \gset
select staff_lessons(t.id('st'), (select today from td), (select today + 1 from td), null, 'all') as la \gset
reset role;
select t.eq((:'lt'::jsonb->>'total')::int, 4, 'the Trial filter lists the 4 trial lessons (Ravi today, Mei one, Cara, Ravi tomorrow)');
select t.ok(not exists (select 1 from jsonb_array_elements(:'lt'::jsonb->'rows') e where not (e->>'trial')::boolean), 'every row in the Trial filter is a trial');
select t.eq((:'la'::jsonb->'counts'->>'trial')::int, 4, 'the counts carry the trial number');
select t.eq((:'la'::jsonb->>'total')::int, 6, 'the All filter still lists every lesson');
select t.ok(:'lt'::jsonb->'counts' ? 'all' and :'lt'::jsonb->'counts' ? 'unmarked' and :'lt'::jsonb->'counts' ? 'marked', 'the old counts are still there');
select t.ok(not exists (select 1 from jsonb_array_elements(:'la'::jsonb->'rows') e, jsonb_object_keys(e) k where k in ('rate', 'amount', 'paid', 'compensation') or k ~ '_cents$'), 'still no money in the list');
select t.as('00000000-0000-0000-0000-00000000a803'); set role authenticated;
select staff_lessons(t.id('st'), (select today from td), (select today from td), null, 'trial') as lt2 \gset
reset role;
select t.eq((:'lt2'::jsonb->>'total')::int, 3, 'staff without manage_timetable can LOOK at the Trial filter');
select t.ok(not (:'lt2'::jsonb->>'can_mark')::boolean, 'and are still given no buttons');

-- ===================================================================== who may flag
select pg_temp.refused('00000000-0000-0000-0000-00000000a803', format('set role authenticated; select staff_set_trial(%L, true)', t.id('LU')), 'NOT_ALLOWED', 'staff without manage_timetable cannot flag'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a804', format('set role authenticated; select staff_set_trial(%L, true)', t.id('LU')), 'NOT_FOUND', 'a tutor cannot use the staff function'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a806', format('set role authenticated; select staff_set_trial(%L, true)', t.id('LU')), 'NOT_FOUND', 'a stranger cannot'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a807', format('set role authenticated; select staff_set_trial(%L, true)', t.id('LU')), 'NOT_FOUND', 'switched-off staff cannot'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a809', format('set role authenticated; select staff_set_trial(%L, true)', t.id('LU')), 'NOT_FOUND', 'the owner of ANOTHER centre cannot'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a80a', format('set role authenticated; select staff_set_trial(%L, true)', t.id('LU')), 'NOT_FOUND', 'a solo tutor cannot'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a802', format('set role authenticated; select staff_set_trial(%L, true)', gen_random_uuid()), 'NOT_FOUND', 'an unknown lesson'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a802', format('set role authenticated; select staff_set_trial(%L, null)', t.id('LU')), 'BAD_VALUE', 'a missing yes/no'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a802', format('set role authenticated; select staff_set_trial(%L, true)', t.id('LR')), 'NO_CHANGE', 'flagging what is already a trial'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a802', format('set role authenticated; select staff_set_trial(%L, false)', t.id('LU')), 'NO_CHANGE', 'unflagging what is not a trial'); reset role;
select set_config('request.jwt.claims', '', false);
select t.fails($q$ set role anon; select staff_set_trial(t.id('LU'), true) $q$, 'signed-out users cannot call it'); reset role;
select t.ok((select not trial from lessons where id = t.id('LU')), 'none of the refused calls changed the lesson');
select t.eq((select count(*) from audit_log where action = 'staff_set_trial' and row_id = t.id('LU')::text), 0, 'and none wrote an audit entry');
-- the owner may flag too
select t.as('00000000-0000-0000-0000-00000000a801'); set role authenticated;
select staff_set_trial(t.id('LU'), true);
reset role;
select t.ok((select trial from lessons where id = t.id('LU')), 'the owner can flag');
-- the lesson's other fields did not move
select t.ok((select attendance is null and status = 'scheduled' and rate = 55 and amount = 55 and taught_by = t.id('m1') from lessons where id = t.id('LU')), 'flagging changes only the trial flag (no status, price or tutor)');

-- ===================================================================== trials_flagged_by governs TUTORS only; staff are never blocked
-- value admin (the default): the tutor is refused, staff succeed
select t.as('00000000-0000-0000-0000-00000000a804'); set role authenticated;
select t.fails(format($q$ select tutor_mark_attendance(%L, null, null, null, null, true) $q$, t.id('LM2')), 'admin setting: a tutor cannot flag a trial');
select t.fails(format($q$ select tutor_mark_attendance(%L, null, null, null, null, false) $q$, t.id('LC')), 'admin setting: a tutor cannot unflag a trial either');
reset role;
select t.as('00000000-0000-0000-0000-00000000a802'); set role authenticated;
select staff_set_trial(t.id('LC'), false);
select staff_set_trial(t.id('LC'), true);
reset role;
select t.ok((select trial from lessons where id = t.id('LC')), 'admin setting: staff can still flag and unflag');
-- value tutor: the tutor may, and staff still may
select t.as('00000000-0000-0000-0000-00000000a801'); set role authenticated;
select org_save_settings(t.id('st'), jsonb_set(t.centre_settings(), '{lessons}', '{"trials_flagged_by": "tutor"}'), current_date);
reset role;
select t.as('00000000-0000-0000-0000-00000000a804'); set role authenticated;
select tutor_mark_attendance(t.id('LC'), null, null, null, null, false);
reset role;
select t.ok((select not trial from lessons where id = t.id('LC')), 'tutor setting: the tutor can unflag');
select t.as('00000000-0000-0000-0000-00000000a802'); set role authenticated;
select staff_set_trial(t.id('LC'), true);
reset role;
select t.ok((select trial from lessons where id = t.id('LC')), 'tutor setting: staff can flag too');
select t.as('00000000-0000-0000-0000-00000000a804'); set role authenticated;
select tutor_mark_attendance(t.id('LC'), null, null, null, null, false);
reset role;
select t.ok((select not trial from lessons where id = t.id('LC')), 'tutor setting: a tutor''s change is allowed, and staff can flip it back');
-- back to the default
select t.as('00000000-0000-0000-0000-00000000a801'); set role authenticated;
select org_save_settings(t.id('st'), jsonb_set(t.centre_settings(), '{lessons}', '{}'), current_date);
reset role;
select t.as('00000000-0000-0000-0000-00000000a802'); set role authenticated;
select staff_set_trial(t.id('LC'), true);
reset role;
select t.ok((select trial from lessons where id = t.id('LC')), 'back to admin: staff still flag');

-- ===================================================================== trial lessons and the fee count, end to end
select t.eq(pg_temp.n_active(), 1, 'now: Mei still counts (one non-trial lesson); Ravi and Cara do not');
select t.as('00000000-0000-0000-0000-00000000a802'); set role authenticated;
select staff_set_trial(t.id('LM2'), true);
reset role;
select t.eq(pg_temp.n_active(), 0, 'every lesson that month is a trial: nobody counts');
select t.as('00000000-0000-0000-0000-00000000a802'); set role authenticated;
select staff_set_trial(t.id('LM2'), false);
reset role;
select t.eq(pg_temp.n_active(), 1, 'unflag one: Mei counts again');

-- ===================================================================== the sign-in rule: no direct table access for tutors, and the function is not open to the public
select t.ok(not has_function_privilege('anon', 'public.staff_set_trial(uuid, boolean)', 'execute'), 'anonymous users have no execute right');
select t.ok(has_function_privilege('authenticated', 'public.staff_set_trial(uuid, boolean)', 'execute'), 'signed-in users do (each call checks the caller itself)');
