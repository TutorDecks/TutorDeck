-- T6 step 1 tests: tutor_my_schedule + tutor_my_slots (the tutor's read-only Schedule): who may call, own rows only, no money anywhere, holidays,
-- flags (cancelled / postponed / covering / trial / marked), the parent-contact setting, the editing note, the weekly slots.
-- Runs after staff_reassign_test.sql in the same throwaway database (reuses the t.* helpers). Builds its own centre and made-up people.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-000000a50001', 'ts.owner@centre.test'),   ('00000000-0000-0000-0000-000000a50002', 'ts.staff@centre.test'),
  ('00000000-0000-0000-0000-000000a50004', 'ts.tutor1@centre.test'),  ('00000000-0000-0000-0000-000000a50005', 'ts.tutor2@centre.test'),
  ('00000000-0000-0000-0000-000000a50006', 'ts.outsider@centre.test'),('00000000-0000-0000-0000-000000a50007', 'ts.off@centre.test'),
  ('00000000-0000-0000-0000-000000a50009', 'ts.owner2@centre.test'),  ('00000000-0000-0000-0000-000000a5000a', 'ts.parent@centre.test'),
  ('00000000-0000-0000-0000-000000a5000b', 'ts.tutor4@centre.test');
set role authenticated; select t.as('00000000-0000-0000-0000-000000a50001');
select t.put('ts', org_create_centre('Schedule Centre', t.centre_settings()));
select t.as('00000000-0000-0000-0000-000000a50009');
select t.put('ts2', org_create_centre('Other Schedule Centre', t.centre_settings()));
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('ts'), '00000000-0000-0000-0000-000000a50002', 'Staff Sam',    'staff', array['manage_timetable'], 'active'),
  (t.id('ts'), '00000000-0000-0000-0000-000000a50004', 'Tutor One',    'tutor', '{}', 'active'),
  (t.id('ts'), '00000000-0000-0000-0000-000000a50005', 'Tutor Two',    'tutor', '{}', 'active'),
  (t.id('ts'), '00000000-0000-0000-0000-000000a50007', 'Switched off', 'tutor', '{}', 'active'),
  (t.id('ts'), '00000000-0000-0000-0000-000000a5000a', 'A Parent',     'parent', '{}', 'active'),
  (t.id('ts2'), '00000000-0000-0000-0000-000000a5000b', 'Tutor Four elsewhere', 'tutor', '{}', 'active');
select t.put('m1', (select id from memberships where org_id = t.id('ts') and user_id = '00000000-0000-0000-0000-000000a50004'));
select t.put('m2', (select id from memberships where org_id = t.id('ts') and user_id = '00000000-0000-0000-0000-000000a50005'));
select t.put('moff', (select id from memberships where org_id = t.id('ts') and user_id = '00000000-0000-0000-0000-000000a50007'));
select t.put('mx', (select id from memberships where org_id = t.id('ts2') and user_id = '00000000-0000-0000-0000-000000a5000b'));

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today;
grant select on td to authenticated, anon;
insert into students(id, tutor_id, org_id, name, level, contact, online_link) values
  ('00000000-0000-0000-0000-000000a50101', '00000000-0000-0000-0000-000000a50001', t.id('ts'), 'Kid One',   'P1', '91110001', 'https://meet.example.com/kid-one'),
  ('00000000-0000-0000-0000-000000a50102', '00000000-0000-0000-0000-000000a50001', t.id('ts'), 'Kid Two',   'P2', '91110002', null),
  ('00000000-0000-0000-0000-000000a50103', '00000000-0000-0000-0000-000000a50001', t.id('ts'), 'Kid Three', 'P3', '91110003', null),
  ('00000000-0000-0000-0000-000000a50104', '00000000-0000-0000-0000-000000a50001', t.id('ts'), 'Kid Gone',  'P4', '91110004', null);
update students set end_date = (select today - 3 from td) where id = '00000000-0000-0000-0000-000000a50104';
insert into students(id, tutor_id, org_id, name, level, contact) values ('00000000-0000-0000-0000-000000a501f1', '00000000-0000-0000-0000-000000a50009', t.id('ts2'), 'Kid elsewhere', 'P1', '91119999');

-- lessons carry MARKER money values so a leak anywhere is found by text search (777.77 rate, 888.88 amount, 555.55 compensation, SECRETNOTE charge note)
create function pg_temp.mk(p_key text, p_student uuid, p_day int, p_tutor text, p_start time default '10:00') returns void language plpgsql as $$
begin
  insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, paid, compensation, charge_note, status, taught_by)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000a50001', t.id('ts'), p_student, (select today + p_day from td), p_start, p_start + interval '1 hour',
          777.77, 888.88, true, 555.55, 'SECRETNOTE', 'scheduled', case when p_tutor is null then null else t.id(p_tutor) end);
  perform t.put(p_key, (select id from lessons order by created_at desc, id limit 1));
end $$;
select pg_temp.mk('A', '00000000-0000-0000-0000-000000a50101', 1, 'm1');            -- tutor one, tomorrow
select pg_temp.mk('B', '00000000-0000-0000-0000-000000a50102', 1, 'm2');            -- tutor two, tomorrow
select pg_temp.mk('C', '00000000-0000-0000-0000-000000a50103', 2, 'm1', '16:00');   -- tutor one, a holiday
select pg_temp.mk('D', '00000000-0000-0000-0000-000000a50101', 3, 'm1');            -- cancelled
select pg_temp.mk('E', '00000000-0000-0000-0000-000000a50102', 4, 'm1');            -- postponed
select pg_temp.mk('F', '00000000-0000-0000-0000-000000a50103', 5, 'm1');            -- covering
select pg_temp.mk('G', '00000000-0000-0000-0000-000000a50101', 6, 'm1');            -- trial
select pg_temp.mk('H', '00000000-0000-0000-0000-000000a50101', 7, null);            -- nobody's lesson
select pg_temp.mk('I', '00000000-0000-0000-0000-000000a50101', 8, 'moff');          -- a switched-off tutor's lesson
select pg_temp.mk('Z', '00000000-0000-0000-0000-000000a50101', 200, 'm1');          -- far outside the range
update memberships set status = 'disabled' where id = t.id('moff');            -- switched off AFTER being given a lesson
update lessons set status = 'cancelled' where id = t.id('D');
update lessons set postponed = true where id = t.id('E');
update lessons set covered_for = t.id('m2') where id = t.id('F');
update lessons set trial = true where id = t.id('G');
select set_config('td.attendance_override', t.id('A')::text, true);
-- a past lesson already marked attended (marked flag)
insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, taught_by, attendance)
  values ('00000000-0000-0000-0000-000000a50301', '00000000-0000-0000-0000-000000a50001', t.id('ts'), '00000000-0000-0000-0000-000000a50103', (select today - 1 from td), '09:00', '10:00', 777.77, 888.88, 'done', t.id('m1'), 'attended');
insert into holidays(org_id, name, starts_on, ends_on) values (t.id('ts'), 'Teachers'' Day', (select today + 2 from td), (select today + 2 from td));
insert into branches(id, org_id, name) values ('00000000-0000-0000-0000-000000a50951', t.id('ts'), 'Bishan');
insert into holidays(org_id, branch_id, name, starts_on, ends_on) values (t.id('ts'), '00000000-0000-0000-0000-000000a50951', 'Bishan only', (select today + 3 from td), (select today + 3 from td));
-- weekly slots: two of tutor one (one for an ended student), one stopped, one of tutor two, one of the other centre; all with a marker rate
insert into recurring_slots(id, tutor_id, org_id, student_id, weekday, start_time, end_time, subject, rate, active, taught_by) values
  ('00000000-0000-0000-0000-000000a50201', '00000000-0000-0000-0000-000000a50001', t.id('ts'), '00000000-0000-0000-0000-000000a50101', 1, '15:00', '16:00', 'Maths', 666.66, true,  t.id('m1')),
  ('00000000-0000-0000-0000-000000a50202', '00000000-0000-0000-0000-000000a50001', t.id('ts'), '00000000-0000-0000-0000-000000a50103', 3, '17:00', '18:00', 'Science', 666.66, true, t.id('m1')),
  ('00000000-0000-0000-0000-000000a50203', '00000000-0000-0000-0000-000000a50001', t.id('ts'), '00000000-0000-0000-0000-000000a50104', 4, '17:00', '18:00', 'Maths', 666.66, true, t.id('m1')),
  ('00000000-0000-0000-0000-000000a50204', '00000000-0000-0000-0000-000000a50001', t.id('ts'), '00000000-0000-0000-0000-000000a50102', 2, '15:00', '16:00', 'Maths', 666.66, false, t.id('m1')),
  ('00000000-0000-0000-0000-000000a50205', '00000000-0000-0000-0000-000000a50001', t.id('ts'), '00000000-0000-0000-0000-000000a50102', 5, '11:00', '12:00', 'English', 666.66, true, t.id('m2'));

create function pg_temp.sch(p_user text, p_from int, p_to int) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  set local role authenticated;
  select tutor_my_schedule((select today + p_from from td), (select today + p_to from td)) into r;
  reset role;
  return r;
end $$;
create function pg_temp.refused(p_user text, p_sql text, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  set local role authenticated;
  begin execute p_sql; exception when others then m := sqlerrm; end;
  reset role;
  if m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS refused: % (%)', p_msg, m;
end $$;
create function pg_temp.ids(j jsonb) returns text[] language sql as $$ select coalesce(array_agg(e->>'lesson_id'), '{}') from jsonb_array_elements(j->'lessons') e $$;

-- ===================================================================== who may call
select pg_temp.refused('00000000-0000-0000-0000-000000a50001', $q$ select tutor_my_schedule(current_date, current_date) $q$, 'NOT_FOUND', 'the centre OWNER (not a tutor)');
select pg_temp.refused('00000000-0000-0000-0000-000000a50002', $q$ select tutor_my_schedule(current_date, current_date) $q$, 'NOT_FOUND', 'centre STAFF (not a tutor)');
select pg_temp.refused('00000000-0000-0000-0000-000000a5000a', $q$ select tutor_my_schedule(current_date, current_date) $q$, 'NOT_FOUND', 'a parent');
select pg_temp.refused('00000000-0000-0000-0000-000000a50007', $q$ select tutor_my_schedule(current_date, current_date) $q$, 'NOT_FOUND', 'a switched-off tutor');
select pg_temp.refused('00000000-0000-0000-0000-000000a50006', $q$ select tutor_my_schedule(current_date, current_date) $q$, 'NOT_FOUND', 'a solo tutor (their only organisation is their own solo one)');
select pg_temp.refused('00000000-0000-0000-0000-000000a50001', $q$ select * from tutor_my_slots() $q$, 'NOT_FOUND', 'slots: the centre owner');
select pg_temp.refused('00000000-0000-0000-0000-000000a50002', $q$ select * from tutor_my_slots() $q$, 'NOT_FOUND', 'slots: centre staff');
select pg_temp.refused('00000000-0000-0000-0000-000000a5000a', $q$ select * from tutor_my_slots() $q$, 'NOT_FOUND', 'slots: a parent');
select pg_temp.refused('00000000-0000-0000-0000-000000a50007', $q$ select * from tutor_my_slots() $q$, 'NOT_FOUND', 'slots: a switched-off tutor');
select pg_temp.refused('00000000-0000-0000-0000-000000a50006', $q$ select * from tutor_my_slots() $q$, 'NOT_FOUND', 'slots: a solo tutor');
-- not signed in
reset role; select set_config('request.jwt.claims', '', false); set role anon;
select t.fails($q$ select tutor_my_schedule(current_date, current_date) $q$, 'anon cannot call tutor_my_schedule');
select t.fails($q$ select * from tutor_my_slots() $q$, 'anon cannot call tutor_my_slots');
reset role;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, false); set role authenticated;
select t.fails($q$ select tutor_my_schedule(current_date, current_date) $q$, 'a token with no user is refused');
reset role;
-- bad ranges (a tutor)
select pg_temp.refused('00000000-0000-0000-0000-000000a50004', $q$ select tutor_my_schedule(current_date + 5, current_date) $q$, 'BAD_RANGE', 'to before from');
select pg_temp.refused('00000000-0000-0000-0000-000000a50004', $q$ select tutor_my_schedule(current_date, current_date + 63) $q$, 'BAD_RANGE', 'more than 62 days');
select pg_temp.refused('00000000-0000-0000-0000-000000a50004', $q$ select tutor_my_schedule(null, current_date) $q$, 'BAD_RANGE', 'a missing date');

-- ===================================================================== my week: own lessons only
select pg_temp.sch('00000000-0000-0000-0000-000000a50004', 0, 14) as one \gset
select pg_temp.sch('00000000-0000-0000-0000-000000a50005', 0, 14) as two \gset
select t.ok(pg_temp.ids(:'one'::jsonb) @> array[t.id('A')::text, t.id('C')::text, t.id('D')::text, t.id('E')::text, t.id('F')::text, t.id('G')::text], 'tutor one sees their own lessons');
select t.ok(not (pg_temp.ids(:'one'::jsonb) && array[t.id('B')::text, t.id('H')::text, t.id('I')::text]), 'tutor one sees none of tutor two''s, an unassigned or a switched-off tutor''s lessons');
select t.ok(not (pg_temp.ids(:'one'::jsonb) && array[t.id('Z')::text]), 'a lesson outside the range is not returned');
select t.ok(pg_temp.ids(:'two'::jsonb) = array[t.id('B')::text], 'tutor two sees only their own lesson');
select pg_temp.sch('00000000-0000-0000-0000-000000a5000b', 0, 14) as four \gset
select t.ok(jsonb_array_length(:'four'::jsonb->'lessons') = 0, 'a tutor of ANOTHER centre sees nothing of this centre');
select t.ok((:'four'::jsonb#>>'{orgs,0,org_id}') = t.id('ts2')::text and jsonb_array_length(:'four'::jsonb->'orgs') = 1, 'and only their own centre is listed');
select t.ok(pg_temp.ids(pg_temp.sch('00000000-0000-0000-0000-000000a50004', -3, 0)) = array['00000000-0000-0000-0000-000000a50301'], 'the range works backwards too (yesterday''s attended lesson)');
select t.ok(((:'one'::jsonb->'lessons')->0->>'lesson_date')::date <= ((:'one'::jsonb->'lessons')->1->>'lesson_date')::date, 'sorted by date');

-- ===================================================================== flags and fields
select t.ok((select e->>'student_name' = 'Kid One' and e->>'student_level' = 'P1' and e->>'start_time' = '10:00:00' and e->>'minutes' = '60'
               and e->>'online_link' = 'https://meet.example.com/kid-one' and e->>'org_name' = 'Schedule Centre'
               from jsonb_array_elements(:'one'::jsonb->'lessons') e where e->>'lesson_id' = t.id('A')::text), 'name, level, time, length, online link and centre');
select t.ok((select (e->>'cancelled')::boolean from jsonb_array_elements(:'one'::jsonb->'lessons') e where e->>'lesson_id' = t.id('D')::text), 'cancelled flag');
select t.ok((select (e->>'postponed')::boolean from jsonb_array_elements(:'one'::jsonb->'lessons') e where e->>'lesson_id' = t.id('E')::text), 'postponed flag');
select t.ok((select (e->>'covering')::boolean from jsonb_array_elements(:'one'::jsonb->'lessons') e where e->>'lesson_id' = t.id('F')::text), 'covering flag (someone else''s lesson)');
select t.ok((select (e->>'trial')::boolean from jsonb_array_elements(:'one'::jsonb->'lessons') e where e->>'lesson_id' = t.id('G')::text), 'trial flag');
select t.ok((select not (e->>'covering')::boolean and not (e->>'cancelled')::boolean and not (e->>'postponed')::boolean and not (e->>'trial')::boolean and e->>'attendance' is null
               from jsonb_array_elements(:'one'::jsonb->'lessons') e where e->>'lesson_id' = t.id('A')::text), 'an ordinary lesson has no flags');
select t.ok((select e->>'attendance' = 'attended' from jsonb_array_elements(pg_temp.sch('00000000-0000-0000-0000-000000a50004', -3, 0)->'lessons') e), 'the attendance state is shown');
-- holidays: the whole-centre one flags the lesson that day and is listed; a branch holiday is neither
select t.ok((select e->>'holiday' = 'Teachers'' Day' from jsonb_array_elements(:'one'::jsonb->'lessons') e where e->>'lesson_id' = t.id('C')::text), 'a whole-centre holiday flags that day''s lesson');
select t.ok((select e->>'holiday' is null from jsonb_array_elements(:'one'::jsonb->'lessons') e where e->>'lesson_id' = t.id('D')::text), 'a branch-only holiday does not');
select t.ok(jsonb_array_length(:'one'::jsonb->'holidays') = 1 and (:'one'::jsonb#>>'{holidays,0,name}') = 'Teachers'' Day', 'only the whole-centre holiday is listed');
select t.ok(jsonb_array_length(:'four'::jsonb->'holidays') = 0, 'another centre''s tutor does not see this centre''s holiday');
-- the editing note
select t.ok((:'one'::jsonb#>>'{orgs,0,timetable_editing}') = 'admin_only' and (:'one'::jsonb#>>'{orgs,0,can_edit}') = 'false', 'timetable_editing is admin_only and nothing can be edited yet');
select t.ok((:'one'::jsonb->>'today')::date = (select today from td), 'today is the centre''s own day');

-- ===================================================================== no money, three ways
select t.ok(not exists (select 1 from jsonb_array_elements(:'one'::jsonb->'lessons') e, jsonb_object_keys(e) k
                         where k ~* '(rate|price|amount|paid|compens|charge|fee|cents|cost|fare|owe|balance|invoice)'), 'no returned key is a money word');
select t.ok(:'one'::text !~ '(777\.77|888\.88|555\.55|666\.66|SECRETNOTE)' and :'two'::text !~ '(777\.77|888\.88|555\.55|666\.66|SECRETNOTE)', 'the marker money values appear nowhere in the answer');
select t.ok(not exists (select 1 from pg_proc p where p.proname in ('tutor_my_schedule', 'tutor_my_slots')
                         and pg_get_functiondef(p.oid) ~* '\m(rate|price|amount|paid|compensation|charge_note|charge|fee|cost|[a-z_]*_cents)\M'), 'no money word in the text of either function (it never reads a money column)');
select t.ok(not exists (select 1 from pg_proc p where p.proname in ('tutor_my_schedule', 'tutor_my_slots') and pg_get_functiondef(p.oid) ~ '\m[a-z]+\.\*'), 'neither function selects a whole row (no x.*)');
select t.ok(not exists (select 1 from pg_proc p, unnest(p.proargnames) n where p.proname = 'tutor_my_slots' and n ~* '(rate|price|amount|paid|compens|charge|fee|cents)'), 'tutor_my_slots has no money column');
select t.ok((select prosecdef from pg_proc where proname = 'tutor_my_schedule') and (select prosecdef from pg_proc where proname = 'tutor_my_slots'), 'both are SECURITY DEFINER');
select t.ok((select proconfig::text like '%search_path=public%' from pg_proc where proname = 'tutor_my_schedule') and (select proconfig::text like '%search_path=public%' from pg_proc where proname = 'tutor_my_slots'), 'search_path is pinned');
select t.ok(not has_function_privilege('anon', 'tutor_my_schedule(date,date)', 'execute') and not has_function_privilege('anon', 'tutor_my_slots()', 'execute')
        and has_function_privilege('authenticated', 'tutor_my_schedule(date,date)', 'execute') and has_function_privilege('authenticated', 'tutor_my_slots()', 'execute'), 'only signed-in users can call them');

-- ===================================================================== parent contact follows the centre's existing setting
select t.ok((select bool_and(e->>'parent_contact' is null) from jsonb_array_elements(:'one'::jsonb->'lessons') e), 'parent contact is not returned by default');
select t.as('00000000-0000-0000-0000-000000a50001'); set role authenticated;
select org_save_settings(t.id('ts'), jsonb_set(t.centre_settings(), '{lessons}', '{"tutors_see_parent_contact": true}'), current_date);
reset role;
select t.ok((select e->>'parent_contact' = '91110001' from jsonb_array_elements(pg_temp.sch('00000000-0000-0000-0000-000000a50004', 0, 14)->'lessons') e where e->>'lesson_id' = t.id('A')::text), 'with the setting on, the parent contact is returned');
select t.ok(not (pg_temp.sch('00000000-0000-0000-0000-000000a50004', 0, 14))::text ~ '91119999', 'but never another centre''s family');
select t.as('00000000-0000-0000-0000-000000a50001'); set role authenticated;
select org_save_settings(t.id('ts'), jsonb_set(t.centre_settings(), '{lessons}', '{"timetable_editing": "tutors_own"}'), current_date);
reset role;
select t.ok((pg_temp.sch('00000000-0000-0000-0000-000000a50004', 0, 14)#>>'{orgs,0,timetable_editing}') = 'tutors_own' and (pg_temp.sch('00000000-0000-0000-0000-000000a50004', 0, 14)#>>'{orgs,0,can_edit}') = 'false',
            'a centre that picks another value is reported, but this step still allows no editing');

-- ===================================================================== my weekly slots
select pg_temp.refused('00000000-0000-0000-0000-000000a50004', $q$ select 1 from tutor_my_slots() $q$, 'allowed', 'a tutor may call it');
set role authenticated; select t.as('00000000-0000-0000-0000-000000a50004');
select count(*) as n1, string_agg(student_name || ':' || weekday || ':' || start_time, ',' order by weekday) as l1 from tutor_my_slots() \gset
reset role;
select t.ok(:n1 = 2 and :'l1' = 'Kid One:1:15:00:00,Kid Three:3:17:00:00', 'tutor one sees their two active slots, not the stopped one or the ended student''s');
set role authenticated; select t.as('00000000-0000-0000-0000-000000a50005');
select count(*) as n2, min(student_name) as s2, min(timetable_editing) as te2 from tutor_my_slots() \gset
reset role;
select t.ok(:n2 = 1 and :'s2' = 'Kid Two', 'tutor two sees only their own slot');
select t.ok(:'te2' = 'tutors_own', 'a slot row carries the centre''s editing setting');
set role authenticated; select t.as('00000000-0000-0000-0000-000000a5000b');
select count(*) as n4 from tutor_my_slots() \gset
reset role;
select t.ok(:n4 = 0, 'a tutor of another centre sees none of these slots');

-- ===================================================================== tutors still have no table access, and nothing changed
set role authenticated; select t.as('00000000-0000-0000-0000-000000a50004');
select t.ok((select count(*) from lessons) = 0 and (select count(*) from recurring_slots) = 0 and (select count(*) from student_tutors) = 0, 'a tutor still reads no lessons, slots or student assignments directly (holidays, names and dates only, were already readable to members)');
reset role;
select t.ok(not exists (select 1 from lessons where org_id in (org_personal('00000000-0000-0000-0000-0000000000a1'), org_personal('00000000-0000-0000-0000-0000000000b1')) and covered_for is not null), 'the solo side is untouched');
select 'PASS tutor_schedule: all checks' as done;
