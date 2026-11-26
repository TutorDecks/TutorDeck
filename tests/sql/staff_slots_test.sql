-- T3 step 7 tests: weekly slots with tutors, the lesson generator, assigned tutors (student_tutors), the online link, tutor visibility.
-- Runs after staff_timetable_test.sql in the same throwaway database (reuses the t.* helpers). Builds its own centre and made-up people.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000b001', 'sl.owner@centre.test'),   ('00000000-0000-0000-0000-00000000b002', 'sl.staff@centre.test'),
  ('00000000-0000-0000-0000-00000000b003', 'sl.desk@centre.test'),    ('00000000-0000-0000-0000-00000000b004', 'sl.tutor1@centre.test'),
  ('00000000-0000-0000-0000-00000000b005', 'sl.tutor2@centre.test'),  ('00000000-0000-0000-0000-00000000b006', 'sl.outsider@centre.test'),
  ('00000000-0000-0000-0000-00000000b007', 'sl.off@centre.test'),     ('00000000-0000-0000-0000-00000000b008', 'sl.money@centre.test'),
  ('00000000-0000-0000-0000-00000000b009', 'sl.owner2@centre.test'),  ('00000000-0000-0000-0000-00000000b00a', 'sl.tutor3@centre.test');
set role authenticated; select t.as('00000000-0000-0000-0000-00000000b001');
select t.put('sl', org_create_centre('Slots Centre', t.centre_settings()));
select t.as('00000000-0000-0000-0000-00000000b009');
select t.put('sl2', org_create_centre('Other Slots Centre', t.centre_settings()));
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('sl'), '00000000-0000-0000-0000-00000000b002', 'Staff Sam',    'staff', array['manage_timetable'], 'active'),
  (t.id('sl'), '00000000-0000-0000-0000-00000000b003', 'Front Desk',   'staff', array['manage_students'], 'active'),
  (t.id('sl'), '00000000-0000-0000-0000-00000000b008', 'Money Only',   'staff', array['record_payments', 'view_revenue'], 'active'),
  (t.id('sl'), '00000000-0000-0000-0000-00000000b004', 'Tutor One',    'tutor', '{}', 'active'),
  (t.id('sl'), '00000000-0000-0000-0000-00000000b005', 'Tutor Two',    'tutor', '{}', 'active'),
  (t.id('sl'), '00000000-0000-0000-0000-00000000b00a', 'Tutor Three',  'tutor', '{}', 'active'),
  (t.id('sl'), '00000000-0000-0000-0000-00000000b007', 'Switched off', 'staff', array['manage_timetable'], 'disabled'),
  (t.id('sl2'), '00000000-0000-0000-0000-00000000b004', 'Tutor One elsewhere', 'tutor', '{}', 'active'),
  (t.id('sl2'), '00000000-0000-0000-0000-00000000b00a', 'Tutor Three elsewhere', 'tutor', '{}', 'active');
select t.put('m1', (select id from memberships where org_id = t.id('sl') and user_id = '00000000-0000-0000-0000-00000000b004'));
select t.put('m2', (select id from memberships where org_id = t.id('sl') and user_id = '00000000-0000-0000-0000-00000000b005'));
select t.put('m3', (select id from memberships where org_id = t.id('sl') and user_id = '00000000-0000-0000-0000-00000000b00a'));
select t.put('mx', (select id from memberships where org_id = t.id('sl2') and user_id = '00000000-0000-0000-0000-00000000b004'));
select t.put('mstaff', (select id from memberships where org_id = t.id('sl') and user_id = '00000000-0000-0000-0000-00000000b002'));
select t.put('moff', (select id from memberships where org_id = t.id('sl') and user_id = '00000000-0000-0000-0000-00000000b007'));

select count(*) as solo_l, count(*) filter (where slot_id is not null) as solo_ls from lessons where org_id in (org_personal('00000000-0000-0000-0000-0000000000a1'), org_personal('00000000-0000-0000-0000-0000000000b1')) \gset
create temp table td as select (now() at time zone 'Asia/Singapore')::date as today, (extract(isodow from (now() at time zone 'Asia/Singapore')::date)::int - 1) as wd;
grant select on td to authenticated, anon;
create temp table stu (k text primary key, id uuid);
insert into stu select 's' || g, gen_random_uuid() from generate_series(1, 8) g;
grant select on stu to authenticated;
-- A REMOTE 1-to-1 centre: no branch and no room anywhere
insert into students(id, tutor_id, org_id, name, level, contact)
  select id, '00000000-0000-0000-0000-00000000b001', t.id('sl'), 'Kid ' || k, 'P' || right(k, 1), '9300000' || right(k, 1) from stu;
-- one student who has already left, one who leaves in 10 days, and a student of the OTHER centre
update students set end_date = (select today - 5 from td) where id = (select id from stu where k = 's7');
update students set end_date = (select today + 10 from td) where id = (select id from stu where k = 's6');
insert into students(id, tutor_id, org_id, name, level) values ('00000000-0000-0000-0000-00000000f951', '00000000-0000-0000-0000-00000000b009', t.id('sl2'), 'Kid elsewhere', 'P1');
select t.put('kid_x', '00000000-0000-0000-0000-00000000f951');
select t.eq((select count(*) from branches where org_id = t.id('sl')) + (select count(*) from rooms where org_id = t.id('sl')), 0, 'the test centre has no branch and no room (remote 1-to-1)');
create function pg_temp.sid(p_k text) returns uuid language sql as $$ select id from stu where k = p_k $$;
create function pg_temp.sess(p_user text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false) $$;
create function pg_temp.refused(p_user text, p_sql text, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  begin execute p_sql; exception when others then m := sqlerrm; end;
  if m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS refused: % (%)', p_msg, m;
end $$;
-- run something as a user and give back whether it worked or the error text
create function pg_temp.save(p_user text, p_args text) returns text language plpgsql as $$
declare m text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  begin execute 'set role authenticated'; execute 'select staff_save_slot(' || p_args || ')'; m := 'allowed'; exception when others then m := sqlerrm; end;
  execute 'reset role'; return m;
end $$;
create function pg_temp.expect(p_got text, p_expect text, p_msg text) returns void language plpgsql as $$
begin
  if p_got not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, p_got, p_expect; end if;
  raise notice 'PASS: % (%)', p_msg, p_got;
end $$;
-- the organisation id and a student list in the form staff_save_slot wants
create function pg_temp.args(p_slot text, p_studs text, p_wd text, p_start text, p_end text, p_tutor text, p_subj text, p_rate text, p_org text default 'sl') returns text language sql as $$
  select format('%L::uuid, %s, %s, %s, %L::time, %L::time, %s, %L, %s', t.id(p_org), p_slot, p_studs, p_wd, p_start, p_end, p_tutor, p_subj, p_rate) $$;
create function pg_temp.arr(variadic ks text[]) returns text language sql as $$
  select 'array[' || (select string_agg(quote_literal(id::text) || '::uuid', ',') from stu where k = any(ks)) || ']::uuid[]' $$;

-- the weekday three days from now (so a slot made today has real days in front of it), and today's
select ((select wd from td) + 3) % 7 as wa, ((select wd from td) + 4) % 7 as wb, ((select wd from td) + 5) % 7 as wc, (select wd from td) as wt \gset

-- ===================================================================== who may do what
-- reading: any owner or staff member, whatever their permissions
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select t.eq((staff_slots(t.id('sl'))->>'total')::int, 0, 'no weekly slots yet; staff can ask');
reset role;
select t.as('00000000-0000-0000-0000-00000000b003'); set role authenticated;
select t.ok((staff_slots(t.id('sl'))->>'can_edit')::boolean = false, 'front desk (manage_students only) can look at the weekly slots, but can_edit is false');
select t.as('00000000-0000-0000-0000-00000000b008');
select t.ok((staff_slots(t.id('sl'))->>'can_edit')::boolean = false, 'staff with only money permissions can look too, and cannot edit');
reset role;
-- writing needs manage_timetable: the desk and the money-only staff get NOT_ALLOWED from every write function
do $$ declare u text; f text; fn text[] := array[
    'staff_save_slot(%L::uuid, null, array[]::uuid[], 1, ''10:00''::time, ''11:00''::time, null, null, 50)',
    'staff_stop_slot(%L::uuid, gen_random_uuid())',
    'staff_generate_lessons(%L::uuid)',
    'staff_pick_students(%L::uuid)',
    'staff_set_student_tutors(%L::uuid, gen_random_uuid(), array[]::uuid[])'];
begin
  foreach u in array array['00000000-0000-0000-0000-00000000b003', '00000000-0000-0000-0000-00000000b008'] loop
    foreach f in array fn loop
      perform pg_temp.refused(u, format('set role authenticated; select ' || f, t.id('sl')), 'NOT_ALLOWED', 'no manage_timetable: ' || split_part(f, '(', 1)); reset role;
    end loop;
  end loop;
  -- NOT_FOUND for everyone who is not owner/staff here
  foreach u in array array['00000000-0000-0000-0000-00000000b004', '00000000-0000-0000-0000-00000000b006', '00000000-0000-0000-0000-00000000b007',
                           '00000000-0000-0000-0000-00000000b009', '00000000-0000-0000-0000-0000000000a1'] loop
    foreach f in array fn || array['staff_slots(%L::uuid)', 'staff_student_tutors(%L::uuid, gen_random_uuid())', 'staff_set_student_link(%L::uuid, gen_random_uuid(), null)'] loop
      perform pg_temp.refused(u, format('set role authenticated; select ' || f, t.id('sl')), 'NOT_FOUND', 'not owner/staff here (' || right(u, 4) || '): ' || split_part(f, '(', 1)); reset role;
    end loop;
  end loop;
end $$;
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; select staff_slots(%L)', gen_random_uuid()), 'NOT_FOUND', 'an unknown organisation id'); reset role;
select org_personal('00000000-0000-0000-0000-0000000000a1') as tina_solo \gset
select pg_temp.refused('00000000-0000-0000-0000-0000000000a1', format('set role authenticated; select staff_generate_lessons(%L)', :'tina_solo'), 'NOT_FOUND', 'a solo organisation has no centre generator'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-0000000000a1', format('set role authenticated; select staff_slots(%L)', :'tina_solo'), 'NOT_FOUND', 'a solo organisation has no centre slots'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role anon; select staff_generate_lessons(%L)', t.id('sl')), 'permission denied', 'a signed-out visitor cannot call the generator'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role anon; select staff_save_slot(%L, null, array[]::uuid[], 1, ''10:00'', ''11:00'', null, null, 5)', t.id('sl')), 'permission denied', 'a signed-out visitor cannot save a slot'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; select set_config(''request.jwt.claims'', '''', false); select staff_generate_lessons(%L)', t.id('sl')), 'NOT_FOUND', 'an authenticated role with no user id is refused'); reset role;
select t.ok(not has_function_privilege('authenticated', 'public.staff_slots_gate(uuid,boolean)', 'execute') and not has_function_privilege('authenticated', 'public.org_tutor_same_org_guard()', 'execute'),
            'the gate and the guard are internal: not callable from the browser');
select t.ok((select bool_and(prosecdef) from pg_proc where proname in ('staff_slots','staff_pick_students','staff_save_slot','staff_stop_slot','staff_generate_lessons','staff_student_tutors','staff_set_student_tutors','staff_set_student_link','tutor_lesson_links')), 'every new function is SECURITY DEFINER');
select t.ok((select bool_and(not has_function_privilege('anon', p.oid, 'execute') and has_function_privilege('authenticated', p.oid, 'execute')) from pg_proc p
              where proname in ('staff_slots','staff_pick_students','staff_save_slot','staff_stop_slot','staff_generate_lessons','staff_student_tutors','staff_set_student_tutors','staff_set_student_link','tutor_lesson_links')), 'anon has no execute right on any of them; signed-in users do');

-- ===================================================================== add a weekly slot (remote 1-to-1: no room, no class, no branch)
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', pg_temp.arr('s1'), :'wa', '16:00', '17:30', format('%L::uuid', t.id('m1')), 'Math', '60')), 'allowed', 'staff with manage_timetable adds a 1-to-1 slot with a tutor');
select t.eq((select count(*) from recurring_slots where org_id = t.id('sl') and active), 1, 'one slot exists');
select t.ok((select weekday = :wa and start_time = '16:00' and end_time = '17:30' and rate = 60 and taught_by = t.id('m1') and session_key is null and level = 'P1' and split = 1
              and tutor_id = '00000000-0000-0000-0000-00000000b001' from recurring_slots where org_id = t.id('sl')),
            'the slot has the day, time, rate, tutor, the student''s level, no session key, and is filed under the OWNER''s login');
select t.put('slotA', (select id from recurring_slots where org_id = t.id('sl')));
-- validation
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', pg_temp.arr('s2'), '7', '16:00', '17:00', 'null', null, '50')), 'BAD_SLOT', 'weekday 7 is refused');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', pg_temp.arr('s2'), '-1', '16:00', '17:00', 'null', null, '50')), 'BAD_SLOT', 'weekday -1 is refused');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', pg_temp.arr('s2'), '1', '17:00', '16:00', 'null', null, '50')), 'BAD_TIME', 'end before start is refused');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', pg_temp.arr('s2'), '1', '17:00', '17:00', 'null', null, '50')), 'BAD_TIME', 'a lesson of zero length is refused');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', pg_temp.arr('s2'), '1', '17:00', '17:10', 'null', null, '50')), 'BAD_TIME', '10 minutes is too short');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', pg_temp.arr('s2'), '1', '08:00', '16:01', 'null', null, '50')), 'BAD_TIME', 'more than 8 hours is too long');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', pg_temp.arr('s2'), '1', '08:00', '16:00', 'null', null, '50')), 'allowed', 'exactly 8 hours is fine');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', pg_temp.arr('s2'), '2', '17:00', '17:15', 'null', null, '0')), 'allowed', '15 minutes and a rate of 0 (a free lesson) are fine');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', pg_temp.arr('s3'), '1', '10:00', '11:00', 'null', null, '-5')), 'BAD_RATE', 'a negative rate is refused');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', pg_temp.arr('s3'), '1', '10:00', '11:00', 'null', null, '1000.01')), 'BAD_RATE', 'a rate above 1000 is refused');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', pg_temp.arr('s3'), '1', '10:00', '11:00', 'null', null, 'null')), 'BAD_RATE', 'adding a slot needs a rate');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', pg_temp.arr('s3'), '1', '10:00', '11:00', 'null', repeat('x', 61), '50')), 'BAD_SLOT', 'a 61-character subject is refused');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', 'array[]::uuid[]', '1', '10:00', '11:00', 'null', null, '50')), 'BAD_STUDENTS', 'a slot needs a student');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', 'null', '1', '10:00', '11:00', 'null', null, '50')), 'BAD_STUDENTS', 'a null student list is refused');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', 'array[''00000000-0000-0000-0000-00000000f951'']::uuid[]', '1', '10:00', '11:00', 'null', null, '50')), 'NOT_FOUND', 'a student of ANOTHER centre is "not found"');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', pg_temp.arr('s7'), '1', '10:00', '11:00', 'null', null, '50')), 'STUDENT_ENDED', 'a student whose lessons have ended can''t get a slot');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', pg_temp.arr('s3'), '1', '10:00', '11:00', format('%L::uuid', t.id('mx')), null, '50')), 'NOT_AVAILABLE', 'a tutor of ANOTHER centre can''t be put on a slot');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', pg_temp.arr('s3'), '1', '10:00', '11:00', format('%L::uuid', t.id('moff')), null, '50')), 'NOT_AVAILABLE', 'a switched-off person can''t be put on a slot');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', pg_temp.arr('s3'), '1', '10:00', '11:00', 'gen_random_uuid()', null, '50')), 'NOT_AVAILABLE', 'an unknown tutor id is refused');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', pg_temp.arr('s1'), :'wa', '17:00', '18:00', 'null', null, '50')), 'SLOT_CLASH', 'the same student can''t have two overlapping weekly slots');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', pg_temp.arr('s1'), :'wa', '17:30', '18:30', 'null', null, '50')), 'allowed', 'back-to-back (17:30 right after 17:30) is not a clash');
select t.eq((select count(*) from recurring_slots where org_id = t.id('sl') and active and student_id = pg_temp.sid('s3')), 0, 'refused calls left nothing behind');
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; select staff_save_slot(%L, null, (select array_agg(gen_random_uuid()) from generate_series(1,31)), 1, ''10:00'', ''11:00'', null, null, 50)', t.id('sl')), 'BAD_STUDENTS', 'more than 30 students in one class is refused'); reset role;
-- a slot with no tutor yet is allowed (it is flagged on the Timetable)
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b001', pg_temp.args('null', pg_temp.arr('s4'), :'wb', '10:00', '11:00', 'null', 'Science', '45.50')), 'allowed', 'the OWNER can add a slot with no tutor yet');
select t.put('slotB', (select id from recurring_slots where org_id = t.id('sl') and student_id = pg_temp.sid('s4')));
select t.ok((select rate = 45.50 and taught_by is null from recurring_slots where id = t.id('slotB')), 'rate kept to the cent, no tutor');
-- a GROUP class: two students, one tutor, tied by a session key
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args('null', pg_temp.arr('s5', 's6'), :'wc', '09:00', '10:30', format('%L::uuid', t.id('m2')), 'English', '40')), 'allowed', 'a group class of two students is added in one call');
select t.eq((select count(*) from recurring_slots where org_id = t.id('sl') and student_id in (pg_temp.sid('s5'), pg_temp.sid('s6'))), 2, 'a group class makes one slot per student');
select t.ok((select count(distinct session_key) = 1 and bool_and(session_key is not null) from recurring_slots where student_id in (pg_temp.sid('s5'), pg_temp.sid('s6'))), 'the two slots share one session_key');
select t.put('slotG', (select id from recurring_slots where student_id = pg_temp.sid('s5')));
-- the other centre sees none of this
select t.as('00000000-0000-0000-0000-00000000b009'); set role authenticated;
select t.eq((staff_slots(t.id('sl2'))->>'total')::int, 0, 'the other centre''s owner sees no slots of this centre');
reset role;

-- ===================================================================== the list
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_slots(t.id('sl')) as sl \gset
reset role;
select t.eq((:'sl'::jsonb->>'total')::int, 6, 'the list has 6 rows: 4 single slots, the 8-hour one, the 15-minute one... (a group class is ONE row)');
select t.ok((:'sl'::jsonb->>'can_edit')::boolean, 'staff with manage_timetable can edit');
select t.ok(exists (select 1 from jsonb_array_elements(:'sl'::jsonb->'rows') e where (e->>'is_group')::boolean and jsonb_array_length(e->'students') = 2 and e->>'tutor_name' = 'Tutor Two' and (e->>'rate')::numeric = 40),
            'the group class is one row with both students, its tutor and (for an editor) its rate');
select t.ok(exists (select 1 from jsonb_array_elements(:'sl'::jsonb->'rows') e where (e->>'no_tutor')::boolean and e->>'tutor_name' is null), 'the slot with no tutor is flagged no_tutor');
select t.eq(jsonb_array_length(:'sl'::jsonb->'tutors'), 3, 'the tutor list has the 3 tutors');
select t.ok(:'sl'::jsonb->'generated_until' = 'null'::jsonb, 'nothing generated yet');
select t.as('00000000-0000-0000-0000-00000000b003'); set role authenticated;
select staff_slots(t.id('sl')) as sl2 \gset
select t.eq((staff_slots(t.id('sl'), null, 'Kid s5')->>'total')::int, 1, 'search by student name finds the group class');
select t.eq((staff_slots(t.id('sl'), null, 'science')->>'total')::int, 1, 'search by subject (any case)');
select t.eq((staff_slots(t.id('sl'), t.id('m1'))->>'total')::int, 1, 'filter by tutor one (slot A only)');
reset role;
select t.ok(not exists (select 1 from jsonb_array_elements(:'sl2'::jsonb->'rows') e where e->'rate' <> 'null'::jsonb), 'the front desk (cannot edit) gets NO rate on any row');
select t.eq((:'sl2'::jsonb->>'total')::int, 6, 'and still sees all 6 rows');
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; select staff_slots(%L, %L)', t.id('sl'), t.id('mx')), 'NOT_FOUND', 'filtering by another centre''s tutor is "not found"'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; select staff_slots(%L, null, null, 1, 101)', t.id('sl')), 'BAD_PAGE', 'a page of more than 100 is refused'); reset role;

-- ===================================================================== change a weekly slot
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args(format('%L::uuid', t.id('slotB')), 'null', :'wb', '10:30', '11:30', format('%L::uuid', t.id('m1')), 'Science', 'null')), 'allowed', 'change a slot: new time and a tutor; rate left empty keeps the old rate');
select t.ok((select start_time = '10:30' and end_time = '11:30' and taught_by = t.id('m1') and rate = 45.50 from recurring_slots where id = t.id('slotB')), 'the change was applied and the rate was kept');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args(format('%L::uuid', t.id('slotB')), 'null', :'wb', '10:30', '11:30', 'null', 'Science', '50')), 'allowed', 'a change can take the tutor away again (null = no tutor) and set a new rate');
select t.ok((select taught_by is null and rate = 50 from recurring_slots where id = t.id('slotB')), 'no tutor again, rate 50');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args(format('%L::uuid', t.id('slotB')), pg_temp.arr('s2'), :'wb', '10:30', '11:30', 'null', null, 'null')), 'BAD_STUDENTS', 'the students of an existing slot can''t be changed');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args(format('%L::uuid', gen_random_uuid()), 'null', :'wb', '10:30', '11:30', 'null', null, 'null')), 'NOT_FOUND', 'an unknown slot id');
select pg_temp.refused('00000000-0000-0000-0000-00000000b009', format('set role authenticated; select staff_save_slot(%L, %L, null, 1, ''10:00'', ''11:00'', null, null, 5)', t.id('sl2'), t.id('slotB')), 'NOT_FOUND', 'the OTHER centre''s owner can''t change this centre''s slot, even naming their own centre'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b009', format('set role authenticated; select staff_stop_slot(%L, %L)', t.id('sl2'), t.id('slotB')), 'NOT_FOUND', 'nor stop it'); reset role;
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args(format('%L::uuid', t.id('slotB')), 'null', :'wa', '16:30', '17:00', 'null', null, 'null')), 'allowed', 'a change to a time that does not touch another slot of that student is fine (Kid s4 has only this slot)');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args(format('%L::uuid', t.id('slotB')), 'null', :'wb', '10:30', '11:30', 'null', 'Science', 'null')), 'allowed', 'moved back');
-- changing a GROUP class changes every student's slot
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args(format('%L::uuid', t.id('slotG')), 'null', :'wc', '09:30', '11:00', format('%L::uuid', t.id('m3')), 'English', '42')), 'allowed', 'change a group class');
select t.ok((select bool_and(start_time = '09:30' and end_time = '11:00' and taught_by = t.id('m3') and rate = 42) and count(*) = 2 from recurring_slots where student_id in (pg_temp.sid('s5'), pg_temp.sid('s6'))), 'both students'' slots moved together');
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args(format('%L::uuid', t.id('slotG')), 'null', :'wc', '09:30', '11:00', format('%L::uuid', t.id('m2')), 'English', '42')), 'allowed', 'and the tutor of a group can change');
-- a clash on a change is caught too
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args(format('%L::uuid', t.id('slotA')), 'null', :'wa', '16:00', '17:30', format('%L::uuid', t.id('m1')), 'Math', 'null')), 'allowed', 'saving a slot unchanged is fine (it does not clash with itself)');

-- ===================================================================== the generator
-- slotA: Kid s1, weekday A, tutor one, 16:00-17:30, rate 60;  s1's second slot (17:30-18:30, no tutor); slotB: Kid s4, weekday B, no tutor;
-- group: s5 + s6 (s6 leaves in 10 days), weekday C, tutor two.  Also s2 has two odd slots (8 hours weekday 1, 15 min weekday 2).
-- Make the odd ones go away so the numbers below are plain.
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_stop_slot(t.id('sl'), (select id from recurring_slots where student_id = pg_temp.sid('s2') and weekday = 1)) as x1 \gset
select staff_stop_slot(t.id('sl'), (select id from recurring_slots where student_id = pg_temp.sid('s2') and weekday = 2)) as x2 \gset
select t.ok((:'x1'::jsonb->>'stopped')::int = 1 and (:'x1'::jsonb->>'lessons_left')::int = 0, 'stopping a slot reports 1 stopped and no lessons left behind');
select staff_stop_slot(t.id('sl'), (select id from recurring_slots where student_id = pg_temp.sid('s2') and weekday = 1)) as x1b \gset
select t.eq((:'x1b'::jsonb->>'stopped')::int, 0, 'stopping it again changes nothing');
select staff_generate_lessons(t.id('sl')) as g1 \gset
reset role;
select t.ok(:'g1'::jsonb->>'from' = (select today::text from td) and :'g1'::jsonb->>'to' = (select (today + 27)::text from td), 'the default range is today and the next 27 days (4 weeks)');
-- slots: slotA (1) + s1 second (1) + slotB (1) + group (2) = 5 active slots; each weekday occurs exactly 4 times in 28 days.
select t.eq((:'g1'::jsonb->>'slots')::int, 5, 'five active slots');
-- s6 leaves in 10 days (inclusive): weekday C's dates inside the window up to today+10 count, the rest are "ended"
select count(*) filter (where (select today from td) + g <= (select today + 10 from td)) as c_before, count(*) filter (where (select today from td) + g > (select today + 10 from td)) as c_after
  from generate_series(0, 27) g where ((select wd from td) + g) % 7 = :wc \gset
select t.eq((:'g1'::jsonb->>'created')::int, 4 + 4 + 4 + 4 + :c_before, 'created = 4 (slot A) + 4 (s1 second) + 4 (slot B) + 4 (s5) + the days s6 is still a student');
select t.eq((:'g1'::jsonb->>'ended')::int, :c_after, 'the days after the student''s last day are skipped as "ended"');
select t.eq((:'g1'::jsonb->>'skipped')::int, 0, 'nothing was there before');
select t.eq((:'g1'::jsonb->>'no_tutor')::int, 8, 'the two slots with no tutor made 8 lessons with no tutor');
select t.eq((select count(*) from lessons where org_id = t.id('sl') and slot_id is not null), 4 + 4 + 4 + 4 + :c_before, 'the lessons really exist');
select t.ok((select bool_and(lesson_date >= (select today from td) and lesson_date <= (select today + 27 from td)) from lessons where slot_id is not null and org_id = t.id('sl')), 'all inside the window, none in the past');
select t.ok((select bool_and(status = 'scheduled' and not paid and not one_off and slot_date = lesson_date and attendance is null and org_id = t.id('sl')) from lessons where slot_id is not null and org_id = t.id('sl')),
            'new lessons are scheduled, unpaid, not one-off, unmarked, with slot_date = their day');
select t.ok((select bool_and(taught_by = t.id('m1') and amount = 90 and rate = 60 and start_time = '16:00' and end_time = '17:30' and subject = 'Math')
               from lessons where slot_id = t.id('slotA')), 'slot A''s lessons: tutor one, rate 60, 90 minutes = amount 90.00, Math');
select t.ok((select bool_and(taught_by is null) from lessons where slot_id = t.id('slotB')) and (select bool_and(amount = 50 and rate = 50) from lessons where slot_id = t.id('slotB')), 'slot B''s lessons have no tutor yet, 1 hour at 50');
select t.ok((select bool_and(amount = 63.00 and rate = 42 and taught_by = t.id('m2')) from lessons where student_id = pg_temp.sid('s5')), 'group lessons: 90 minutes at 42 = 63.00, tutor two');
select t.ok((select bool_and(a.session_id = b.session_id) from lessons a join lessons b on b.slot_date = a.slot_date and b.student_id = pg_temp.sid('s6') where a.student_id = pg_temp.sid('s5')), 'the two students of a class on the same day share a session_id');
select t.ok((select count(distinct session_id) = count(distinct lesson_date) and bool_and(session_id is not null) from lessons where student_id = pg_temp.sid('s5')), 'different days of the class have different session ids');
select t.ok((select bool_and(session_id is null) from lessons where slot_id in (t.id('slotA'), t.id('slotB'))), 'a 1-to-1 slot makes lessons with no session id');
-- who made them
select t.ok(exists (select 1 from audit_log where org_id = t.id('sl') and action = 'staff_generate_lessons' and (after->>'created')::int = (:'g1'::jsonb->>'created')::int and actor = '00000000-0000-0000-0000-00000000b002'),
            'the audit log records who pressed it and the result');
select t.ok(exists (select 1 from audit_log where org_id = t.id('sl') and action = 'staff_save_slot' and table_name = 'recurring_slots') and exists (select 1 from audit_log where org_id = t.id('sl') and action = 'staff_stop_slot'), 'adding and stopping slots are in the audit log');
select t.ok(exists (select 1 from audit_log where org_id = t.id('sl') and action = 'insert' and table_name = 'recurring_slots') and exists (select 1 from audit_log where org_id = t.id('sl') and action = 'insert' and table_name = 'lessons'), 'the row-level audit sees the new slots and lessons too');

-- ---- IDEMPOTENT: press it again, and again from a different person
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_generate_lessons(t.id('sl')) as g2 \gset
select t.as('00000000-0000-0000-0000-00000000b001');
select staff_generate_lessons(t.id('sl')) as g3 \gset
reset role;
select t.eq((:'g2'::jsonb->>'created')::int, 0, 'pressing it twice creates NOTHING new');
select t.eq((:'g2'::jsonb->>'skipped')::int, (:'g1'::jsonb->>'created')::int, 'every lesson is reported as already there');
select t.eq((:'g3'::jsonb->>'created')::int, 0, 'and the owner pressing it too creates nothing either');
select t.eq((select count(*) from lessons where org_id = t.id('sl') and slot_id is not null), (:'g1'::jsonb->>'created')::int, 'the number of lessons is unchanged');
-- a moved lesson keeps its slot_date: its original day is not made again
update lessons set lesson_date = lesson_date + 1, postponed = true where id = (select id from lessons where slot_id = t.id('slotA') order by lesson_date limit 1);
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_generate_lessons(t.id('sl')) as g4 \gset
reset role;
select t.eq((:'g4'::jsonb->>'created')::int, 0, 'a lesson that was moved a day later does not come back on its original day');
-- a lesson that is DELETED does come back on the next run (same as the solo Planner)
delete from lessons where id = (select id from lessons where slot_id = t.id('slotB') order by lesson_date desc limit 1);
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_generate_lessons(t.id('sl')) as g5 \gset
reset role;
select t.eq((:'g5'::jsonb->>'created')::int, 1, 'a deleted lesson is made again (and only that one)');
-- a hand-made lesson at the same time for the same student counts as already there
insert into students(id, tutor_id, org_id, name, level) values ('00000000-0000-0000-0000-00000000f952', '00000000-0000-0000-0000-00000000b001', t.id('sl'), 'Kid hand', 'P2');
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_save_slot(t.id('sl'), null, array['00000000-0000-0000-0000-00000000f952']::uuid[], (select wd from td), '23:00', '23:45', null, 'Math', 30) as hs \gset
reset role;
insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, one_off, subject)
  values ('00000000-0000-0000-0000-00000000b001', t.id('sl'), '00000000-0000-0000-0000-00000000f952', (select today from td), '23:00', '23:45', 30, 22.5, 'scheduled', true, 'Math');
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_generate_lessons(t.id('sl')) as g6 \gset
reset role;
select t.eq((:'g6'::jsonb->>'created')::int, 3, 'a slot of today with a hand-made lesson the same day: that day is skipped, the other 3 weeks are made');

-- ===================================================================== tutors see their lessons (tutor two, tutor one, tutor three)
select count(*) as n_m2 from lessons where taught_by = t.id('m2') and lesson_date between (select today from td) and (select today + 27 from td) \gset
select t.as('00000000-0000-0000-0000-00000000b005'); set role authenticated;
select t.eq((select count(*) from tutor_my_lessons((select today from td), (select today + 27 from td)) where student_name in ('Kid s5', 'Kid s6')), :n_m2,
            'tutor two sees the new group lessons on My lessons (one row per student)');
select t.ok((select count(*) > 0 and bool_and(session_id is not null) from tutor_my_lessons((select today from td), (select today + 27 from td)) where student_name = 'Kid s5'), 'and they come with their class id so My lessons groups them');
select t.eq((select count(*) from tutor_my_lessons((select today from td), (select today + 27 from td)) where student_name in ('Kid s1', 'Kid s4')), 0, 'tutor two does not see tutor one''s lessons or the no-tutor ones');
select t.ok(not exists (select 1 from pg_proc p, unnest(p.proargnames) n where p.proname = 'tutor_my_lessons' and (n ~* '^(rate|amount|paid|price|compensation|charge_note|total)$' or n ~* '_cents$')), 'tutor_my_lessons still returns no money column (its charge flags are yes/no, not amounts)');
select t.ok(not exists (select 1 from pg_proc p, unnest(p.proargnames) n where p.proname = 'tutor_lesson_links' and (n ~* 'rate|amount|paid|price|compens|cents|contact|phone')), 'tutor_lesson_links returns no money or contact column');
select t.eq((select count(*) from recurring_slots), 0, 'a tutor reads no weekly slots (no table access: rate stays hidden)');
select t.eq((select count(*) from student_tutors), 0, 'a tutor reads no assigned-student list');
reset role;
select t.as('00000000-0000-0000-0000-00000000b004'); set role authenticated;
select t.eq((select count(*) from tutor_my_lessons((select today from td), (select today + 27 from td)) where student_name = 'Kid s1'), 4 + 0, 'tutor one sees their 4 weeks of Kid s1');
select pg_temp.refused('00000000-0000-0000-0000-00000000b004', format('set role authenticated; insert into recurring_slots(tutor_id, student_id, weekday, start_time, end_time, rate, org_id) values (%L, %L, 1, ''10:00'', ''11:00'', 1, %L)', '00000000-0000-0000-0000-00000000b004', pg_temp.sid('s1'), t.id('sl')), 'new row violates row-level security', 'a tutor cannot write a slot directly'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b004', format('set role authenticated; insert into student_tutors(org_id, student_id, membership_id) values (%L, %L, %L)', t.id('sl'), pg_temp.sid('s1'), t.id('m1')), 'permission denied', 'a tutor cannot assign themselves a student'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; insert into student_tutors(org_id, student_id, membership_id) values (%L, %L, %L)', t.id('sl'), pg_temp.sid('s1'), t.id('m1')), 'permission denied', 'not even staff can write the table directly (functions only)'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; update student_tutors set active = false'), 'permission denied', 'nor update it'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; delete from student_tutors'), 'permission denied', 'nor delete from it'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b004', 'set role authenticated; select tutor_lesson_links(current_date, current_date + 100)', 'BAD_RANGE', 'the link list asks for at most 62 days'); reset role;

-- ===================================================================== holidays: calendar.skip_holidays on (the default) and off
-- a fresh weekly slot for tutor three on weekday T (today's weekday): 4 occurrences in the window (today ... today + 21)
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_save_slot(t.id('sl'), null, array[pg_temp.sid('s8')], (select wd from td), '13:00', '14:00', t.id('m3'), 'Math', 55) as hs2 \gset
reset role;
-- a whole-centre holiday on the 2nd occurrence (today + 7), a BRANCH holiday on the 3rd (today + 14: must not skip anything), a holiday far outside
insert into branches(id, org_id, name) values ('00000000-0000-0000-0000-00000000c951', t.id('sl'), 'Bishan');
insert into holidays(org_id, name, starts_on, ends_on) values (t.id('sl'), 'Teachers'' Day', (select today + 7 from td), (select today + 7 from td));
insert into holidays(org_id, branch_id, name, starts_on, ends_on) values (t.id('sl'), '00000000-0000-0000-0000-00000000c951', 'Bishan only', (select today + 14 from td), (select today + 14 from td));
insert into holidays(org_id, name, starts_on, ends_on) values (t.id('sl'), 'Far away', (select today + 100 from td), (select today + 101 from td));
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_generate_lessons(t.id('sl')) as h1 \gset
reset role;
select t.eq((:'h1'::jsonb->>'created')::int, 3, 'skip_holidays is ON by default: slot of Kid s8 makes 3 of its 4 lessons (the whole-centre holiday is skipped)');
select t.eq((:'h1'::jsonb->>'holidays')::int, 1, 'one holiday day was skipped');
select t.ok(not exists (select 1 from lessons where student_id = pg_temp.sid('s8') and lesson_date = (select today + 7 from td)), 'no lesson on the holiday');
select t.ok(exists (select 1 from lessons where student_id = pg_temp.sid('s8') and lesson_date = (select today + 14 from td)), 'a BRANCH holiday does not skip a lesson (slots carry no branch)');
select t.eq((:'h1'::jsonb->>'on_holiday')::int, 0, 'nothing was made on a holiday');
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_generate_lessons(t.id('sl')) as h2 \gset
reset role;
select t.ok((:'h2'::jsonb->>'created')::int = 0 and (:'h2'::jsonb->>'holidays')::int = 1, 'pressing again: still nothing new, the holiday is still skipped');
-- now the centre switches skipping OFF (owner, effective today): the holiday lesson is made on the next press
select t.as('00000000-0000-0000-0000-00000000b001'); set role authenticated;
select org_save_settings(t.id('sl'), jsonb_set(t.centre_settings(), '{calendar}', '{"skip_holidays": false}'), (select today from td));
select staff_generate_lessons(t.id('sl')) as h3 \gset
reset role;
select t.eq((:'h3'::jsonb->>'created')::int, 1, 'skip_holidays OFF: the holiday''s lesson is made now (and only it)');
select t.eq((:'h3'::jsonb->>'on_holiday')::int, 1, 'and reported as made on a holiday');
select t.eq((:'h3'::jsonb->>'holidays')::int, 0, 'no holiday day is skipped');
select t.ok(exists (select 1 from lessons where student_id = pg_temp.sid('s8') and lesson_date = (select today + 7 from td)), 'the lesson on the holiday exists');
-- a settings document where the key is not a yes/no falls back to the default (on)
select t.as('00000000-0000-0000-0000-00000000b001'); set role authenticated;
select org_save_settings(t.id('sl'), jsonb_set(t.centre_settings(), '{calendar}', '{"skip_holidays": true}'), (select today from td));
reset role;
-- ON again, and a second holiday over a slot with no lessons yet
insert into students(id, tutor_id, org_id, name, level) values ('00000000-0000-0000-0000-00000000f953', '00000000-0000-0000-0000-00000000b001', t.id('sl'), 'Kid holiday', 'P3');
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_save_slot(t.id('sl'), null, array['00000000-0000-0000-0000-00000000f953']::uuid[], (select wd from td), '14:00', '15:00', null, 'Math', 55) as hs3 \gset
select staff_generate_lessons(t.id('sl'), (select today + 7 from td), (select today + 7 from td)) as h4 \gset
reset role;
select t.ok((:'h4'::jsonb->>'created')::int = 0 and (:'h4'::jsonb->>'holidays')::int = 1, 'skip_holidays back ON: a one-day range that is a holiday makes nothing and says 1 holiday');
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_generate_lessons(t.id('sl'), (select today from td), (select today + 6 from td)) as h5 \gset
reset role;
select t.ok((:'h5'::jsonb->>'created')::int = 1, 'a range of one week makes one lesson for the new weekly slot');
-- a holiday spanning several days skips every matching day
insert into holidays(org_id, name, starts_on, ends_on) values (t.id('sl'), 'School break', (select today + 28 from td), (select today + 35 from td));
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_generate_lessons(t.id('sl'), (select today + 28 from td), (select today + 34 from td)) as h6 \gset
reset role;
select t.ok((:'h6'::jsonb->>'created')::int = 0 and (:'h6'::jsonb->>'holidays')::int >= 4 and not exists (select 1 from lessons l where l.org_id = t.id('sl') and l.student_id = pg_temp.sid('s8') and l.lesson_date between (select today + 28 from td) and (select today + 34 from td)),
            'a multi-day holiday skips the weekly lesson inside it');

-- ===================================================================== ranges
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; select staff_generate_lessons(%L, current_date - 40, current_date - 38)', t.id('sl')), 'BAD_RANGE', 'a range in the past is refused'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; select staff_generate_lessons(%L, %L, %L)', t.id('sl'), (select today from td), (select today + 63 from td)), 'BAD_RANGE', 'more than 62 days is refused'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; select staff_generate_lessons(%L, %L, %L)', t.id('sl'), (select today + 5 from td), (select today + 4 from td)), 'BAD_RANGE', 'an end before the start is refused'); reset role;
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select t.ok((staff_generate_lessons(t.id('sl'), (select today + 40 from td), (select today + 41 from td))->>'created')::int >= 0, 'a range later on is allowed');
reset role;

-- ===================================================================== a tutor who is switched off later: their lessons are made with no tutor
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_save_slot(t.id('sl'), null, array[pg_temp.sid('s2')], (select (wd + 1) % 7 from td), '19:00', '20:00', t.id('m3'), 'Math', 40) as ds \gset
reset role;
update memberships set status = 'disabled' where id = t.id('m3');
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_generate_lessons(t.id('sl')) as d1 \gset
select staff_slots(t.id('sl')) as sl3 \gset
reset role;
select t.ok((select bool_and(taught_by is null) and count(*) >= 4 from lessons where student_id = pg_temp.sid('s2') and slot_id is not null), 'a slot whose tutor was switched off makes lessons with NO tutor (flagged), not an error');
select t.ok(exists (select 1 from jsonb_array_elements(:'sl3'::jsonb->'rows') e where e->>'tutor_name' = 'Former tutor' and (e->>'no_tutor')::boolean), 'and the slot list shows "Former tutor" flagged');
update memberships set status = 'active' where id = t.id('m3');

-- ===================================================================== stopping a slot
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_stop_slot(t.id('sl'), t.id('slotA')) as st1 \gset
reset role;
select t.ok((:'st1'::jsonb->>'stopped')::int = 1 and (:'st1'::jsonb->>'lessons_left')::int >= 3, 'stopping slot A says 1 stopped and that its upcoming lessons are still there');
select t.ok((select count(*) from lessons where slot_id = t.id('slotA')) >= 4, 'its lessons are kept (real data)');
update lessons set status = 'cancelled' where slot_id = t.id('slotA');
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_generate_lessons(t.id('sl'), (select today + 28 from td), (select today + 34 from td)) as st2 \gset
select staff_slots(t.id('sl'), null, 'Kid s1') as sl4 \gset
reset role;
select t.ok(not exists (select 1 from lessons where slot_id = t.id('slotA') and lesson_date >= (select today + 28 from td)), 'a stopped slot makes no more lessons');
select t.ok(not exists (select 1 from jsonb_array_elements(:'sl4'::jsonb->'rows') e where e->>'slot_id' = t.id('slotA')::text), 'and drops off the list');
-- stopping a GROUP class stops every student's slot
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_stop_slot(t.id('sl'), t.id('slotG')) as st3 \gset
reset role;
select t.ok((:'st3'::jsonb->>'stopped')::int = 2 and not exists (select 1 from recurring_slots where student_id in (pg_temp.sid('s5'), pg_temp.sid('s6')) and active), 'stopping a group class stops both students''s slots');
-- editing a stopped slot: it is gone from the point of view of the screen
select pg_temp.expect(pg_temp.save('00000000-0000-0000-0000-00000000b002', pg_temp.args(format('%L::uuid', t.id('slotA')), 'null', '1', '10:00', '11:00', 'null', null, '10')), 'NOT_FOUND', 'a stopped slot can''t be edited');

-- ===================================================================== settings that do not change a slot (documented): attendance and charges are untouched
select t.ok(not exists (select 1 from lessons where org_id = t.id('sl') and slot_id is not null and (attendance is not null or compensation is not null or paid)), 'generating never marks attendance, sets a charge or marks paid');

-- ===================================================================== assigned tutors (student_tutors)
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_set_student_tutors(t.id('sl'), pg_temp.sid('s1'), array[t.id('m1'), t.id('m2')]) as a1 \gset
select staff_student_tutors(t.id('sl'), pg_temp.sid('s1')) as v1 \gset
reset role;
select t.ok((:'a1'::jsonb->>'added')::int = 2 and (:'a1'::jsonb->>'removed')::int = 0 and (:'a1'::jsonb->>'assigned')::int = 2, 'two tutors assigned');
select t.ok(jsonb_array_length(:'v1'::jsonb->'assigned') = 2 and (:'v1'::jsonb->>'can_edit')::boolean and (:'v1'::jsonb->>'can_link')::boolean and jsonb_array_length(:'v1'::jsonb->'options') = 3, 'the student sheet reads them back, with the 3 tutors as options');
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_set_student_tutors(t.id('sl'), pg_temp.sid('s1'), array[t.id('m2'), t.id('m3')]) as a2 \gset
reset role;
select t.ok((:'a2'::jsonb->>'added')::int = 1 and (:'a2'::jsonb->>'removed')::int = 1 and (:'a2'::jsonb->>'assigned')::int = 2, 'swap: one added, one removed');
select t.ok((select count(*) = 3 from student_tutors where student_id = pg_temp.sid('s1')) and (select count(*) = 2 from student_tutors where student_id = pg_temp.sid('s1') and active), 'the removed tutor''s row is KEPT as history (3 rows, 2 active)');
select t.ok((select active = false and until = (select today from td) and since is not null from student_tutors where student_id = pg_temp.sid('s1') and membership_id = t.id('m1')), 'the ended row says until today');
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_set_student_tutors(t.id('sl'), pg_temp.sid('s1'), array[t.id('m1'), t.id('m2'), t.id('m3')]) as a3 \gset
select staff_set_student_tutors(t.id('sl'), pg_temp.sid('s1'), array[t.id('m1'), t.id('m2'), t.id('m3')]) as a4 \gset
select staff_student_tutors(t.id('sl'), pg_temp.sid('s1')) as v2 \gset
reset role;
select t.ok((:'a3'::jsonb->>'added')::int = 1 and (:'a4'::jsonb->>'added')::int = 0 and (:'a4'::jsonb->>'removed')::int = 0, 're-adding a tutor starts a NEW row; saving the same list again changes nothing');
select t.eq((select count(*) from student_tutors where student_id = pg_temp.sid('s1') and membership_id = t.id('m1')), 2, 'tutor one now has two rows for Kid s1: the old ended one and the new one');
select t.ok(jsonb_array_length(:'v2'::jsonb->'history') = 1 and jsonb_array_length(:'v2'::jsonb->'assigned') = 3, 'the sheet shows 3 assigned and 1 history line');
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_set_student_tutors(t.id('sl'), pg_temp.sid('s1'), array[]::uuid[]) as a5 \gset
reset role;
select t.ok((:'a5'::jsonb->>'removed')::int = 3 and (:'a5'::jsonb->>'assigned')::int = 0 and (select count(*) = 4 from student_tutors where student_id = pg_temp.sid('s1')), 'an empty list ends everyone, and nothing is deleted');
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; select staff_set_student_tutors(%L, %L, array[%L]::uuid[])', t.id('sl'), pg_temp.sid('s1'), t.id('mx')), 'NOT_AVAILABLE', 'a tutor of ANOTHER centre can''t be assigned'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; select staff_set_student_tutors(%L, %L, array[%L]::uuid[])', t.id('sl'), pg_temp.sid('s1'), t.id('moff')), 'NOT_AVAILABLE', 'a switched-off person can''t be assigned'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; select staff_set_student_tutors(%L, %L, array[%L]::uuid[])', t.id('sl'), t.id('kid_x'), t.id('m1')), 'NOT_FOUND', 'a student of ANOTHER centre is not found'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b009', format('set role authenticated; select staff_set_student_tutors(%L, %L, array[%L]::uuid[])', t.id('sl2'), pg_temp.sid('s1'), t.id('mx')), 'NOT_FOUND', 'the other centre''s owner can''t assign this centre''s student, even naming their own centre'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; select staff_set_student_tutors(%L, %L, (select array_agg(gen_random_uuid()) from generate_series(1, 21)))', t.id('sl'), pg_temp.sid('s1')), 'BAD_TUTORS', 'more than 20 assigned tutors is refused'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; select staff_student_tutors(%L, %L)', t.id('sl'), t.id('kid_x')), 'NOT_FOUND', 'reading another centre''s student is not found'); reset role;
-- the same-centre rule holds even for a direct write that skips the functions (the service role / SQL editor / a bug)
select t.fails(format('insert into student_tutors(org_id, student_id, membership_id) values (%L, %L, %L)', t.id('sl'), pg_temp.sid('s1'), t.id('mx')), 'a tutor of another centre cannot be tied to this centre''s student, even directly');
select t.fails(format('insert into student_tutors(org_id, student_id, membership_id) values (%L, %L, %L)', t.id('sl2'), t.id('kid_x'), t.id('m1')), 'nor can this centre''s tutor be tied to the other centre''s student');
select t.fails(format('insert into student_tutors(org_id, student_id, membership_id) values (%L, %L, %L)', t.id('sl'), t.id('kid_x'), t.id('m1')), 'nor a student of another centre in this centre''s list');
select t.fails(format('insert into student_tutors(org_id, student_id, membership_id) values (%L, %L, %L)', (select org_personal('00000000-0000-0000-0000-0000000000a1')), '10000000-0000-0000-0000-000000000001', t.id('m1')), 'a solo organisation''s student can''t have an assigned centre tutor');
select t.fails(format('update recurring_slots set taught_by = %L where id = %L', t.id('mx'), (select id from recurring_slots where org_id = t.id('sl') limit 1)), 'a slot can''t be given to a tutor of another centre, even directly');
select t.fails(format('insert into student_tutors(org_id, student_id, membership_id, active) values (%L, %L, %L, false)', t.id('sl'), pg_temp.sid('s2'), t.id('m1')), 'an ended assignment must say when it ended (check constraint)');
select t.fails(format('insert into student_tutors(org_id, student_id, membership_id) values (%L, %L, %L), (%L, %L, %L)', t.id('sl'), pg_temp.sid('s2'), t.id('m1'), t.id('sl'), pg_temp.sid('s2'), t.id('m1')), 'the same tutor can''t be active twice for one student');
select t.ok(exists (select 1 from audit_log where org_id = t.id('sl') and action = 'staff_set_student_tutors' and actor = '00000000-0000-0000-0000-00000000b002' and row_id = pg_temp.sid('s1')::text), 'assigning tutors is in the audit log with who did it');
select t.ok((select count(*) >= 7 from audit_log where org_id = t.id('sl') and table_name = 'student_tutors'), 'and so is every row change of the table');
-- the desk (manage_students only) may read the assigned tutors, but not change them
select t.as('00000000-0000-0000-0000-00000000b003'); set role authenticated;
select staff_student_tutors(t.id('sl'), pg_temp.sid('s1')) as v3 \gset
reset role;
select t.ok(not (:'v3'::jsonb->>'can_edit')::boolean and (:'v3'::jsonb->>'can_link')::boolean, 'the front desk reads the panel: cannot edit tutors, can edit the link');
select pg_temp.refused('00000000-0000-0000-0000-00000000b003', format('set role authenticated; select staff_set_student_tutors(%L, %L, array[%L]::uuid[])', t.id('sl'), pg_temp.sid('s1'), t.id('m1')), 'NOT_ALLOWED', 'the front desk can''t assign tutors'); reset role;

-- ===================================================================== the online link
select t.as('00000000-0000-0000-0000-00000000b003'); set role authenticated;
select staff_set_student_link(t.id('sl'), pg_temp.sid('s5'), '  https://meet.example.com/abc-123?x=1  ') as k1 \gset
reset role;
select t.ok(:'k1'::jsonb->>'online_link' = 'https://meet.example.com/abc-123?x=1' and (select online_link from students where id = pg_temp.sid('s5')) = 'https://meet.example.com/abc-123?x=1', 'the front desk (manage_students) can set a link; spaces around it are trimmed');
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; select staff_set_student_link(%L, %L, %L)', t.id('sl'), pg_temp.sid('s5'), 'http://meet.example.com/x'), 'BAD_LINK', 'http:// is refused'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; select staff_set_student_link(%L, %L, %L)', t.id('sl'), pg_temp.sid('s5'), 'javascript:alert(1)'), 'BAD_LINK', 'javascript: is refused'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; select staff_set_student_link(%L, %L, %L)', t.id('sl'), pg_temp.sid('s5'), 'https://a.example.com/x y'), 'BAD_LINK', 'a link with a space is refused'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; select staff_set_student_link(%L, %L, %L)', t.id('sl'), pg_temp.sid('s5'), 'https://a.example.com/' || repeat('x', 500)), 'BAD_LINK', 'a link over 500 characters is refused'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b008', format('set role authenticated; select staff_set_student_link(%L, %L, %L)', t.id('sl'), pg_temp.sid('s5'), 'https://a.example.com/x'), 'NOT_ALLOWED', 'money-only staff can''t set a link'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000b002', format('set role authenticated; select staff_set_student_link(%L, %L, %L)', t.id('sl'), t.id('kid_x'), 'https://a.example.com/x'), 'NOT_FOUND', 'another centre''s student is not found'); reset role;
select t.fails(format('update students set online_link = %L where id = %L', 'ftp://x.example.com/a', pg_temp.sid('s5')), 'the table itself also refuses a link that is not https:// (check constraint)');
select t.ok(exists (select 1 from audit_log where org_id = t.id('sl') and action = 'staff_set_student_link' and actor = '00000000-0000-0000-0000-00000000b003'), 'setting a link is in the audit log');
-- new lessons of that class: the link reaches the tutor through the tutor function (tutor three is the class tutor in this run: tutor two had it, tutor three was set above)
update lessons set taught_by = t.id('m2') where student_id = pg_temp.sid('s5') and taught_by is distinct from t.id('m2');
select t.as('00000000-0000-0000-0000-00000000b005'); set role authenticated;
select t.ok((select count(*) > 0 and bool_and(online_link = 'https://meet.example.com/abc-123?x=1') from tutor_lesson_links((select today from td), (select today + 27 from td))), 'the assigned tutor gets the link of THEIR lessons');
select t.as('00000000-0000-0000-0000-00000000b004');
select t.eq((select count(*) from tutor_lesson_links((select today from td), (select today + 27 from td)) where lesson_id in (select id from lessons where student_id = pg_temp.sid('s5'))), 0, 'another tutor does not get a link of lessons that are not theirs');
reset role;
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_timetable(t.id('sl'), (select today from td), (select today + 27 from td), null, null, pg_temp.sid('s5')) as tt \gset
reset role;
select t.ok(exists (select 1 from jsonb_array_elements(:'tt'::jsonb->'rows') e where e->>'online_link' = 'https://meet.example.com/abc-123?x=1'), 'the staff Timetable shows the student''s link on the lesson');
select t.ok(not exists (select 1 from jsonb_array_elements(:'tt'::jsonb->'rows') e, jsonb_object_keys(e) k where k in ('rate', 'amount', 'paid', 'compensation') or k ~ '_cents$'), 'and still no money in any timetable row');
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_set_student_link(t.id('sl'), pg_temp.sid('s5'), '') as k2 \gset
reset role;
select t.ok((select online_link is null from students where id = pg_temp.sid('s5')), 'an empty link clears it');

-- ===================================================================== search for students in the slot form
select t.as('00000000-0000-0000-0000-00000000b002'); set role authenticated;
select staff_pick_students(t.id('sl'), 'kid s') as pk \gset
select staff_pick_students(t.id('sl'), 'Kid s7') as pk7 \gset
reset role;
select t.ok(jsonb_array_length(:'pk'::jsonb) >= 5 and not exists (select 1 from jsonb_array_elements(:'pk'::jsonb) e where e->>'id' = t.id('kid_x')::text), 'the picker finds this centre''s students (and never the other centre''s)');
select t.eq(jsonb_array_length(:'pk7'::jsonb), 0, 'a student whose lessons have ended is not offered');
select t.ok(not exists (select 1 from jsonb_array_elements(:'pk'::jsonb) e, jsonb_object_keys(e) k where k not in ('id', 'name', 'level')), 'the picker returns names and levels only: no contact');

-- ===================================================================== the solo side is untouched
select t.ok(not exists (select 1 from recurring_slots where org_id in (org_personal('00000000-0000-0000-0000-0000000000a1'), org_personal('00000000-0000-0000-0000-0000000000b1')) and (taught_by is not null or session_key is not null)), 'solo tutors'' slots have no tutor and no session key (nothing here touched them)');
select t.eq((select count(*) from lessons where org_id in (org_personal('00000000-0000-0000-0000-0000000000a1'), org_personal('00000000-0000-0000-0000-0000000000b1'))), :solo_l, 'the solo tutors'' lessons are exactly as they were (the generator only ever touches the centre it is asked about)');
select 'PASS staff_slots: all checks' as done;
