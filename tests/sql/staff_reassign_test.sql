-- T3 step 8 tests: staff_reassign_lesson (cover / reassign), the centre's replacement_tutors rule, who may call it, what is never allowed,
-- the tutor lists after a cover, the audit trail and the Timetable's "covered by".
-- Runs after staff_slots_test.sql in the same throwaway database (reuses the t.* helpers). Builds its own centre and made-up people.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000d001', 'ra.owner@centre.test'),   ('00000000-0000-0000-0000-00000000d002', 'ra.staff@centre.test'),
  ('00000000-0000-0000-0000-00000000d003', 'ra.desk@centre.test'),    ('00000000-0000-0000-0000-00000000d004', 'ra.tutor1@centre.test'),
  ('00000000-0000-0000-0000-00000000d005', 'ra.tutor2@centre.test'),  ('00000000-0000-0000-0000-00000000d006', 'ra.outsider@centre.test'),
  ('00000000-0000-0000-0000-00000000d007', 'ra.off@centre.test'),     ('00000000-0000-0000-0000-00000000d008', 'ra.money@centre.test'),
  ('00000000-0000-0000-0000-00000000d009', 'ra.owner2@centre.test'),  ('00000000-0000-0000-0000-00000000d00a', 'ra.tutor3@centre.test'),
  ('00000000-0000-0000-0000-00000000d00b', 'ra.tutor4@centre.test');
set role authenticated; select t.as('00000000-0000-0000-0000-00000000d001');
select t.put('ra', org_create_centre('Reassign Centre', t.centre_settings()));
select t.as('00000000-0000-0000-0000-00000000d009');
select t.put('ra2', org_create_centre('Other Reassign Centre', t.centre_settings()));
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, invited_email, display_name, role, permissions, status) values
  (t.id('ra'), '00000000-0000-0000-0000-00000000d002', null, 'Staff Sam',    'staff', array['manage_timetable'], 'active'),
  (t.id('ra'), '00000000-0000-0000-0000-00000000d003', null, 'Front Desk',   'staff', array['manage_students'], 'active'),
  (t.id('ra'), '00000000-0000-0000-0000-00000000d008', null, 'Money Only',   'staff', array['record_payments', 'view_revenue'], 'active'),
  (t.id('ra'), '00000000-0000-0000-0000-00000000d004', null, 'Tutor One',    'tutor', '{}', 'active'),
  (t.id('ra'), '00000000-0000-0000-0000-00000000d005', null, 'Tutor Two',    'tutor', '{}', 'active'),
  (t.id('ra'), '00000000-0000-0000-0000-00000000d00a', null, 'Tutor Three',  'tutor', '{}', 'active'),
  (t.id('ra'), '00000000-0000-0000-0000-00000000d007', null, 'Switched off', 'tutor', '{}', 'disabled'),
  (t.id('ra'), null, 'new.tutor@centre.test', 'Not yet here', 'tutor', '{}', 'invited'),
  (t.id('ra2'), '00000000-0000-0000-0000-00000000d00b', null, 'Tutor Four elsewhere', 'tutor', '{}', 'active');
select t.put('m1', (select id from memberships where org_id = t.id('ra') and user_id = '00000000-0000-0000-0000-00000000d004'));
select t.put('m2', (select id from memberships where org_id = t.id('ra') and user_id = '00000000-0000-0000-0000-00000000d005'));
select t.put('m3', (select id from memberships where org_id = t.id('ra') and user_id = '00000000-0000-0000-0000-00000000d00a'));
select t.put('moff', (select id from memberships where org_id = t.id('ra') and user_id = '00000000-0000-0000-0000-00000000d007'));
select t.put('minv', (select id from memberships where org_id = t.id('ra') and status = 'invited'));
select t.put('mx', (select id from memberships where org_id = t.id('ra2') and user_id = '00000000-0000-0000-0000-00000000d00b'));
select t.put('mstaff', (select id from memberships where org_id = t.id('ra') and user_id = '00000000-0000-0000-0000-00000000d002'));

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today;
grant select on td to authenticated, anon;
insert into students(id, tutor_id, org_id, name, level) values
  ('00000000-0000-0000-0000-00000000d101', '00000000-0000-0000-0000-00000000d001', t.id('ra'), 'Kid One', 'P1'),
  ('00000000-0000-0000-0000-00000000d102', '00000000-0000-0000-0000-00000000d001', t.id('ra'), 'Kid Two', 'P2'),
  ('00000000-0000-0000-0000-00000000d103', '00000000-0000-0000-0000-00000000d001', t.id('ra'), 'Kid Three', 'P3');
-- a weekly slot of Kid One with tutor one, and tutor one assigned to Kid One (what a cover must NOT touch)
insert into recurring_slots(id, tutor_id, org_id, student_id, weekday, start_time, end_time, rate, taught_by)
  values ('00000000-0000-0000-0000-00000000d201', '00000000-0000-0000-0000-00000000d001', t.id('ra'), '00000000-0000-0000-0000-00000000d101', 1, '15:00', '16:00', 60, t.id('m1'));
insert into student_tutors(org_id, student_id, membership_id) values (t.id('ra'), '00000000-0000-0000-0000-00000000d101', t.id('m1'));
create function pg_temp.mk(p_key text, p_student uuid, p_day int, p_tutor text, p_sess uuid default null) returns void language plpgsql as $$
begin
  insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, taught_by, session_id)
  values (gen_random_uuid(), '00000000-0000-0000-0000-00000000d001', t.id('ra'), p_student, (select today + p_day from td), '10:00', '11:00', 60, 60, 'scheduled',
          case when p_tutor is null then null else t.id(p_tutor) end, p_sess);
  perform t.put(p_key, (select id from lessons order by created_at desc, id limit 1));
end $$;
select pg_temp.mk('A', '00000000-0000-0000-0000-00000000d101', 2, 'm1');
select pg_temp.mk('B', '00000000-0000-0000-0000-00000000d102', 2, 'm1');
select pg_temp.mk('C', '00000000-0000-0000-0000-00000000d103', 2, 'm1');
select pg_temp.mk('N', '00000000-0000-0000-0000-00000000d101', 5, null);
select pg_temp.mk('K1', '00000000-0000-0000-0000-00000000d101', 0, 'm1');
select pg_temp.mk('K2', '00000000-0000-0000-0000-00000000d102', 0, 'm1');
-- test set-up only: mark a lesson on its (future) day, the way the staff correction does
create function pg_temp.mark(p_key text, p_att text) returns void language plpgsql as $$
begin
  perform set_config('td.attendance_override', t.id(p_key)::text, true);
  update lessons set attendance = p_att where id = t.id(p_key);
  perform set_config('td.attendance_override', '', true);
end $$;
create function pg_temp.refused(p_user text, p_sql text, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  begin execute p_sql; exception when others then m := sqlerrm; end;
  if m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS refused: % (%)', p_msg, m;
end $$;
-- run staff_reassign_lesson as a user: 'allowed' or the error text. p_args is the SQL after the lesson key.
create function pg_temp.re(p_user text, p_lesson text, p_tutor text, p_mode text, p_reason text default null, p_links text default 'false') returns text language plpgsql as $$
declare m text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  begin execute 'set role authenticated';
        execute format('select staff_reassign_lesson(%L::uuid, %s, %L, %L, %s)', t.id(p_lesson), case when p_tutor is null then 'null::uuid' else format('%L::uuid', t.id(p_tutor)) end, p_mode, p_reason, p_links);
        m := 'allowed'; exception when others then m := sqlerrm; end;
  execute 'reset role'; return m;
end $$;
create function pg_temp.expect(p_got text, p_expect text, p_msg text) returns void language plpgsql as $$
begin
  if p_got not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, p_got, p_expect; end if;
  raise notice 'PASS: % (%)', p_msg, p_got;
end $$;
create function pg_temp.mine(p_user text) returns int language plpgsql as $$
declare n int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  execute 'set role authenticated';
  select count(*) into n from tutor_my_lessons((select today from td), (select today + 30 from td)) where lesson_id in (t.id('A'), t.id('B'), t.id('C'), t.id('N'), t.id('K1'), t.id('K2'));
  execute 'reset role'; return n;
end $$;
\set u_owner '''00000000-0000-0000-0000-00000000d001'''
\set u_staff '''00000000-0000-0000-0000-00000000d002'''
\set u_desk  '''00000000-0000-0000-0000-00000000d003'''
\set u_t1    '''00000000-0000-0000-0000-00000000d004'''
\set u_t2    '''00000000-0000-0000-0000-00000000d005'''

-- ===================================================================== who may call it
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d003', 'A', 'm2', 'cover', 'x'), 'NOT_ALLOWED', 'staff without manage_timetable (front desk)');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d008', 'A', 'm2', 'cover', 'x'), 'NOT_ALLOWED', 'staff with only money permissions');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d004', 'A', 'm2', 'cover', 'x'), 'NOT_FOUND', 'a tutor of this centre can''t give their own lesson away');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d005', 'A', 'm2', 'cover', 'x'), 'NOT_FOUND', 'the tutor who would receive it can''t take it either');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d006', 'A', 'm2', 'cover', 'x'), 'NOT_FOUND', 'a stranger');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d007', 'A', 'm2', 'cover', 'x'), 'NOT_FOUND', 'switched-off member');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d009', 'A', 'm2', 'cover', 'x'), 'NOT_FOUND', 'the owner of ANOTHER centre');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-0000000000a1', 'A', 'm2', 'cover', 'x'), 'NOT_FOUND', 'a solo tutor');
select pg_temp.refused('00000000-0000-0000-0000-00000000d002', format('set role authenticated; select staff_reassign_lesson(%L, %L, ''cover'', ''x'')', gen_random_uuid(), t.id('m2')), 'NOT_FOUND', 'an unknown lesson');
reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000d002', format('set role anon; select staff_reassign_lesson(%L, %L, ''cover'', ''x'')', t.id('A'), t.id('m2')), 'permission denied', 'a signed-out visitor'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000d002', format('set role authenticated; select set_config(''request.jwt.claims'', '''', false); select staff_reassign_lesson(%L, %L, ''cover'', ''x'')', t.id('A'), t.id('m2')), 'NOT_FOUND', 'no user id'); reset role;
select t.ok((select bool_and(prosecdef) from pg_proc where proname in ('staff_reassign_lesson', 'lesson_locked_reason')), 'both new functions are SECURITY DEFINER');
select t.ok(has_function_privilege('authenticated', 'public.staff_reassign_lesson(uuid,uuid,text,text,boolean)', 'execute') and not has_function_privilege('anon', 'public.staff_reassign_lesson(uuid,uuid,text,text,boolean)', 'execute'), 'signed-in users can call it, anon can''t');
select t.ok(not has_function_privilege('authenticated', 'public.lesson_locked_reason(uuid)', 'execute'), 'the helper is internal');
select t.eq((select count(*) from lessons where org_id = t.id('ra') and taught_by = t.id('m1')), 5, 'nothing moved during the refusals (A, B, C, K1, K2 are still tutor one''s)');
select t.eq((select count(*) from audit_log where action = 'staff_reassign_lesson' and org_id = t.id('ra')), 0, 'refusals write no audit entry');

-- ===================================================================== validation (plain messages)
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'A', 'm2', 'swap', 'x'), 'BAD_MODE', 'an unknown mode');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'A', null, 'cover', 'x'), 'PICK_TUTOR', 'no tutor chosen');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'A', 'm2', 'cover', null), 'REASON_REQUIRED', 'a replacement needs a reason');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'A', 'm2', 'cover', '   '), 'REASON_REQUIRED', 'a blank reason is no reason');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'A', 'm2', 'cover', repeat('x', 501)), 'TOO_LONG', 'a reason over 500 characters');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'A', 'm1', 'cover', 'x'), 'NO_CHANGE', 'the same tutor');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'A', 'mx', 'cover', 'x'), 'NOT_AVAILABLE', 'a tutor of ANOTHER centre');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'A', 'moff', 'cover', 'x'), 'NOT_AVAILABLE', 'a switched-off tutor');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'A', 'minv', 'cover', 'x'), 'NOT_AVAILABLE', 'a tutor who has not joined yet (invited): not active');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'A', 'm2', 'cover', 'x', 'true'), 'LINK_NOT_FOR_COVER', 'a cover refuses the assigned-tutor choice');
select t.ok((select taught_by = t.id('m1') and covered_for is null from lessons where id = t.id('A')), 'lesson A is untouched after all those refusals');

-- ===================================================================== a COVER (replacement_tutors missing = on, the default)
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'A', 'm2', 'cover', 'Tutor One is unwell'), 'allowed', 'staff with manage_timetable covers a lesson with tutor two');
select t.ok((select taught_by = t.id('m2') and covered_for = t.id('m1') and status = 'scheduled' and attendance is null from lessons where id = t.id('A')), 'taught_by is tutor two, covered_for remembers tutor one');
select t.eq(pg_temp.mine('00000000-0000-0000-0000-00000000d004'), 4, 'tutor one no longer sees it (4 left: B, C, K1, K2)');
select t.eq(pg_temp.mine('00000000-0000-0000-0000-00000000d005'), 1, 'tutor two sees it');
select t.ok((select taught_by = t.id('m1') and active from recurring_slots rs where id = '00000000-0000-0000-0000-00000000d201'), 'the weekly slot still belongs to tutor one');
select t.ok((select count(*) = 1 and bool_and(membership_id = t.id('m1') and active) from student_tutors where student_id = '00000000-0000-0000-0000-00000000d101'), 'the student''s assigned tutor is still tutor one (a cover never changes it)');
select t.ok((select count(*) = 1 and bool_and(before #>> '{lessons,0,taught_by}' = t.id('m1')::text and after->>'mode' = 'cover' and after->>'reason' = 'Tutor One is unwell'
                                               and after->>'new_tutor' = t.id('m2')::text and after->>'covered_for' = t.id('m1')::text and actor = '00000000-0000-0000-0000-00000000d002')
              from audit_log where action = 'staff_reassign_lesson' and row_id = t.id('A')::text), 'the audit log says who, from whom, to whom, the mode and the reason');
-- the Timetable shows it
select t.as('00000000-0000-0000-0000-00000000d002'); set role authenticated;
select staff_timetable(t.id('ra'), (select today from td), (select today + 30 from td)) as tt \gset
reset role;
select t.ok((select e->>'tutor_name' = 'Tutor Two' and e->>'covered_for_name' = 'Tutor One' and (e->>'can_reassign')::boolean from jsonb_array_elements(:'tt'::jsonb->'rows') e where e->>'lesson_id' = t.id('A')::text), 'the Timetable row: Tutor Two, covering for Tutor One, can still be changed');
select t.ok((select e->>'covered_for_name' is null from jsonb_array_elements(:'tt'::jsonb->'rows') e where e->>'lesson_id' = t.id('B')::text), 'an ordinary lesson has no covered_for_name');
select t.ok((:'tt'::jsonb->>'can_edit')::boolean and (:'tt'::jsonb->>'replacements_allowed')::boolean, 'the answer says the caller can edit and that replacements are allowed');
select t.ok(exists (select 1 from jsonb_array_elements(:'tt'::jsonb->'tutors') e where e->>'name' = 'Tutor Two' and (e->>'active')::boolean), 'tutors say whether they are active');
select t.ok(not exists (select 1 from jsonb_array_elements(:'tt'::jsonb->'rows') e, jsonb_object_keys(e) k where k in ('rate', 'amount', 'paid', 'compensation') or k ~ '_cents$'), 'still no money in any timetable row');
select t.as('00000000-0000-0000-0000-00000000d003'); set role authenticated;
select staff_timetable(t.id('ra'), (select today from td), (select today + 30 from td)) as ttd \gset
reset role;
select t.ok(not (:'ttd'::jsonb->>'can_edit')::boolean, 'the front desk is told it can''t edit (the page hides the button)');
-- covering a covered lesson keeps the original; handing it back clears the cover
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'A', 'm3', 'cover', 'Tutor Two is away too'), 'allowed', 'a second cover');
select t.ok((select taught_by = t.id('m3') and covered_for = t.id('m1') from lessons where id = t.id('A')), 'it is still "meant for" tutor one, not tutor two');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'A', 'm1', 'cover', 'Tutor One is back'), 'allowed', 'handing it back to tutor one');
select t.ok((select taught_by = t.id('m1') and covered_for is null from lessons where id = t.id('A')), 'no cover any more');
select t.eq(pg_temp.mine('00000000-0000-0000-0000-00000000d004'), 5, 'tutor one sees all five again');
select t.eq((select count(*) from audit_log where action = 'staff_reassign_lesson' and org_id = t.id('ra')), 3, 'three audit entries so far (one per successful change)');

-- ===================================================================== REASSIGN, with and without the assigned-tutor choice
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'B', 'm2', 'reassign', 'Tutor Two now teaches Kid Two'), 'allowed', 'reassign without touching the assigned tutors');
select t.ok((select taught_by = t.id('m2') and covered_for is null from lessons where id = t.id('B')), 'the lesson is tutor two''s, with nobody "covering"');
select t.ok((select count(*) = 1 and bool_and(membership_id = t.id('m1') and active) from student_tutors where student_id = '00000000-0000-0000-0000-00000000d101'), 'link left alone by default');
select t.ok((select taught_by = t.id('m1') from recurring_slots where id = '00000000-0000-0000-0000-00000000d201'), 'a reassign leaves the weekly slot alone');
select t.eq(pg_temp.mine('00000000-0000-0000-0000-00000000d004'), 4, 'tutor one no longer sees B');
-- the explicit second choice: Kid One's tutor link moves too
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'A', 'm2', 'reassign', 'Kid One moves to tutor two', 'true'), 'allowed', 'reassign AND update the assigned tutor');
select t.ok((select count(*) filter (where membership_id = t.id('m1') and not active and until = (select today from td)) = 1
                and count(*) filter (where membership_id = t.id('m2') and active) = 1 and count(*) filter (where active) = 1
              from student_tutors where student_id = '00000000-0000-0000-0000-00000000d101'), 'tutor one''s link is ended (kept as history), tutor two''s starts');
select t.ok((select (after->>'links_updated')::boolean and (after->>'links_ended')::int = 1 and (after->>'links_added')::int = 1 from audit_log where action = 'staff_reassign_lesson' and row_id = t.id('A')::text order by at desc limit 1), 'and the audit entry records the link change');
-- reassigning again with the choice: nothing to end, nothing to add twice
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'A', 'm3', 'reassign', 'again', 'true'), 'allowed', 'a second reassign with the choice');
select t.ok((select count(*) filter (where active) = 1 and count(*) filter (where active and membership_id = t.id('m3')) = 1 from student_tutors where student_id = '00000000-0000-0000-0000-00000000d101'), 'exactly one active tutor link, the newest');
select t.ok((select taught_by = t.id('m3') and covered_for is null from lessons where id = t.id('A')), 'reassign clears any cover');

-- ===================================================================== never on a lesson that is marked, cancelled, paid or invoiced
select pg_temp.mk('M', '00000000-0000-0000-0000-00000000d103', -1, 'm1');
select pg_temp.mk('X', '00000000-0000-0000-0000-00000000d103', 4, 'm1');
select pg_temp.mk('P', '00000000-0000-0000-0000-00000000d103', 7, 'm1');
select pg_temp.mk('I', '00000000-0000-0000-0000-00000000d103', 8, 'm1');
select pg_temp.mk('R', '00000000-0000-0000-0000-00000000d103', 9, 'm1');
select pg_temp.mark('M', 'attended');
update lessons set status = 'cancelled' where id = t.id('X');
update lessons set paid = true where id = t.id('P');
insert into invoices(tutor_id, org_id, student_id, invoice_no, total, data) values
  ('00000000-0000-0000-0000-00000000d001', t.id('ra'), '00000000-0000-0000-0000-00000000d103', 'RA-1', 60, jsonb_build_object('lesson_ids', jsonb_build_array(t.id('I')::text))),
  ('00000000-0000-0000-0000-00000000d001', t.id('ra'), '00000000-0000-0000-0000-00000000d103', 'RA-2', 60, jsonb_build_object('lesson_ids', jsonb_build_array(t.id('R')::text), 'replaced_by', 'RA-3'));
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'M', 'm2', 'cover', 'x'), 'ALREADY_MARKED', 'a marked lesson stays with the tutor who taught it');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'M', 'm2', 'reassign', 'x'), 'ALREADY_MARKED', '...also for reassign');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'X', 'm2', 'cover', 'x'), 'CANCELLED', 'a cancelled lesson');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'P', 'm2', 'cover', 'x'), 'PAID', 'a paid lesson');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'I', 'm2', 'cover', 'x'), 'INVOICED', 'a lesson on an invoice');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'R', 'm2', 'cover', 'x'), 'allowed', 'but an invoice that was replaced by a newer one no longer holds the lesson');
select t.eq((select count(*) from lessons where id in (t.id('M'), t.id('X'), t.id('P'), t.id('I')) and taught_by = t.id('m1')), 4, 'the four locked lessons did not move');
select t.as('00000000-0000-0000-0000-00000000d002'); set role authenticated;
select staff_timetable(t.id('ra'), (select today from td), (select today + 30 from td)) as ttl \gset
reset role;
select t.ok((select bool_and(not (e->>'can_reassign')::boolean) from jsonb_array_elements(:'ttl'::jsonb->'rows') e where e->>'lesson_id' in (t.id('M')::text, t.id('X')::text, t.id('P')::text, t.id('I')::text)), 'the Timetable says can_reassign = false for each of them');
-- a lesson cannot be marked and THEN given away, and the mark by the covering tutor is theirs
select pg_temp.mk('Z', '00000000-0000-0000-0000-00000000d103', 0, 'm1');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'Z', 'm2', 'cover', 'Tutor One is stuck'), 'allowed', 'a lesson of TODAY can be covered');
select t.as('00000000-0000-0000-0000-00000000d005'); set role authenticated;
select tutor_mark_attendance(t.id('Z'), 'attended');
reset role;
select t.ok((select attendance = 'attended' and attendance_marked_by = '00000000-0000-0000-0000-00000000d005' from lessons where id = t.id('Z')), 'the covering tutor marks it: attendance follows the tutor who taught it');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'Z', 'm1', 'cover', 'x'), 'ALREADY_MARKED', 'and now it can''t be moved again');

-- ===================================================================== a class moves together, all or nothing
select gen_random_uuid() as sess \gset
update lessons set session_id = :'sess' where id in (t.id('K1'), t.id('K2'));
select pg_temp.mark('K2', 'attended');          -- one student of the class is already marked
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'K1', 'm2', 'cover', 'x'), 'ALREADY_MARKED', 'a class with a marked lesson does not move');
select t.ok((select bool_and(taught_by = t.id('m1')) from lessons where id in (t.id('K1'), t.id('K2'))), 'neither lesson of the class moved');
update lessons set attendance = null, attendance_marked_at = null, attendance_marked_by = null where id = t.id('K2');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'K1', 'm2', 'cover', 'Tutor One is away'), 'allowed', 'with nothing marked the whole class is covered');
select t.ok((select bool_and(taught_by = t.id('m2') and covered_for = t.id('m1')) from lessons where id in (t.id('K1'), t.id('K2'))), 'both students'' lessons moved together');
select t.ok((select jsonb_array_length(after->'lessons') = 2 from audit_log where action = 'staff_reassign_lesson' and row_id = t.id('K1')::text), 'one audit entry names both lessons');

-- ===================================================================== a lesson with no tutor yet: assigning is not a replacement
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'N', 'm2', 'cover', 'x'), 'NO_TUTOR_TO_COVER', 'nobody to cover for');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'N', 'm2', 'reassign', null), 'allowed', 'but it can be given its first tutor, with no reason needed');
select t.ok((select taught_by = t.id('m2') and covered_for is null from lessons where id = t.id('N')), 'first tutor set, nobody covering');

-- ===================================================================== the centre's rule: lessons.replacement_tutors
select pg_temp.mk('S1', '00000000-0000-0000-0000-00000000d102', 11, 'm1');
select pg_temp.mk('S2', '00000000-0000-0000-0000-00000000d102', 12, 'm1');
select pg_temp.mk('S3', '00000000-0000-0000-0000-00000000d102', 13, null);
select t.as('00000000-0000-0000-0000-00000000d001'); set role authenticated;
select org_save_settings(t.id('ra'), jsonb_set(t.centre_settings(), '{lessons}', '{"replacement_tutors": false}'), current_date);
reset role;
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'S1', 'm2', 'cover', 'Sick'), 'REPLACEMENT_OFF: this centre doesn''t allow replacement tutors', 'OFF: a cover is refused with the plain message');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'S1', 'm2', 'reassign', 'Sick'), 'REPLACEMENT_OFF', 'OFF: a reassign of a lesson that has a tutor is refused too');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d001', 'S1', 'm2', 'cover', 'Sick'), 'REPLACEMENT_OFF', 'OFF: even the owner is refused (it is the centre''s own rule)');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'S1', 'm2', 'reassign', 'Sick', 'true'), 'REPLACEMENT_OFF', 'OFF: and with the assigned-tutor choice');
select t.ok((select taught_by = t.id('m1') and covered_for is null from lessons where id = t.id('S1')), 'OFF: nothing moved');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'S3', 'm3', 'reassign', null), 'allowed', 'OFF: a lesson with no tutor can still be given its first tutor');
select t.as('00000000-0000-0000-0000-00000000d002'); set role authenticated;
select staff_timetable(t.id('ra'), (select today from td), (select today + 30 from td)) as tto \gset
reset role;
select t.ok(not (:'tto'::jsonb->>'replacements_allowed')::boolean, 'OFF: the Timetable answer says replacements are not allowed (the page explains instead of offering the form)');
-- ON, spelled out
select t.as('00000000-0000-0000-0000-00000000d001'); set role authenticated;
select org_save_settings(t.id('ra'), jsonb_set(t.centre_settings(), '{lessons}', '{"replacement_tutors": true}'), current_date);
reset role;
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'S1', 'm2', 'cover', 'Sick'), 'allowed', 'ON: the same cover now works');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'S2', 'm2', 'reassign', 'Moved'), 'allowed', 'ON: and so does a reassign');
select t.as('00000000-0000-0000-0000-00000000d002'); set role authenticated;
select staff_timetable(t.id('ra'), (select today from td), (select today + 30 from td)) as ttn \gset
reset role;
select t.ok((:'ttn'::jsonb->>'replacements_allowed')::boolean, 'ON: the Timetable answer says so');
-- the key missing altogether = on (older centres keep working)
select t.as('00000000-0000-0000-0000-00000000d001'); set role authenticated;
select org_save_settings(t.id('ra'), jsonb_set(t.centre_settings(), '{lessons}', '{}'), current_date);
reset role;
select pg_temp.mk('S4', '00000000-0000-0000-0000-00000000d102', 14, 'm1');
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'S4', 'm3', 'cover', 'Default'), 'allowed', 'missing key: the default is on');
-- the rule is read as of TODAY: switching off blocks lessons that were already scheduled
select t.as('00000000-0000-0000-0000-00000000d001'); set role authenticated;
select org_save_settings(t.id('ra'), jsonb_set(t.centre_settings(), '{lessons}', '{"replacement_tutors": false}'), current_date);
reset role;
select pg_temp.expect(pg_temp.re('00000000-0000-0000-0000-00000000d002', 'S4', 'm1', 'cover', 'back'), 'REPLACEMENT_OFF', 'switching it off applies to lessons that are already covered too (a hand-back is a replacement)');
-- direct table writes by staff follow the same rule (the existing guard), so the function is not a back door either way
select t.as('00000000-0000-0000-0000-00000000d002'); set role authenticated;
select t.fails($q$ update lessons set taught_by = t.id('m2') where id = t.id('S4') $q$, 'OFF: a direct table update is refused by the guard too');
reset role;

-- ===================================================================== data integrity of covered_for itself
select t.fails($q$ update lessons set covered_for = t.id('mx') where id = t.id('S4') $q$, 'covered_for must be a member of the SAME centre');
select t.ok((select count(*) = 0 from tutor_my_lessons((select today from td), (select today from td)) where false), 'tutor_my_lessons is unchanged: it has no covered_for column');
select t.ok(not exists (select 1 from pg_proc p, unnest(p.proargnames) n where p.proname = 'tutor_my_lessons' and n ~* 'covered'), 'tutors are not told who they are covering for');
update memberships set status = 'disabled' where id = t.id('m1');
select t.as('00000000-0000-0000-0000-00000000d002'); set role authenticated;
select staff_timetable(t.id('ra'), (select today from td), (select today + 30 from td)) as ttf \gset
reset role;
select t.ok((select e->>'covered_for_name' = 'Former tutor' from jsonb_array_elements(:'ttf'::jsonb->'rows') e where e->>'lesson_id' = t.id('S4')::text), 'a cover for someone since switched off says "Former tutor"');
update memberships set status = 'active' where id = t.id('m1');

-- ===================================================================== the solo side is untouched
select t.ok(not exists (select 1 from lessons where org_id in (org_personal('00000000-0000-0000-0000-0000000000a1'), org_personal('00000000-0000-0000-0000-0000000000b1')) and covered_for is not null), 'no solo lesson has a covered_for');
select 'PASS staff_reassign: all checks' as done;
