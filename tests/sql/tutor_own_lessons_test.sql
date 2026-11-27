-- T6 steps 3 and 4 tests: tutors add their own one-off lessons, keep their own weekly slots and press "Create lessons" (db/migration_tutor_own_lessons.sql).
-- Every setting value and switch; the notice edges (23 h / 25 h, 0); the monthly limit at and over (it counts the new actions and the step 2 ones together); who is
-- refused (always the same NOT_FOUND); price inherited vs pending; the invoice run holding a pending lesson back; the generator (twice, together with staff, holidays,
-- ended students, not assigned, notice, group classes); audit; the staff list; no money anywhere a tutor can read; no direct table access; undo is checked by run.sh.
-- Runs after tutor_moves_test.sql in the same throwaway database (reuses the t.* helpers). Builds its own centres and made-up people. All names are FAKE.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-000000a70001', 'ol.owner@centre.test'),  ('00000000-0000-0000-0000-000000a70002', 'ol.staff@centre.test'),
  ('00000000-0000-0000-0000-000000a70003', 'ol.money@centre.test'),  ('00000000-0000-0000-0000-000000a70004', 'ol.tutor1@centre.test'),
  ('00000000-0000-0000-0000-000000a70005', 'ol.tutor2@centre.test'), ('00000000-0000-0000-0000-000000a70006', 'ol.solo@centre.test'),
  ('00000000-0000-0000-0000-000000a70007', 'ol.off@centre.test'),    ('00000000-0000-0000-0000-000000a70008', 'ol.parent@centre.test'),
  ('00000000-0000-0000-0000-000000a70009', 'ol.owner2@centre.test'), ('00000000-0000-0000-0000-000000a7000a', 'ol.tutor4@centre.test'),
  ('00000000-0000-0000-0000-000000a7000b', 'ol.ownerk@centre.test'), ('00000000-0000-0000-0000-000000a7000c', 'ol.tutork@centre.test'),
  ('00000000-0000-0000-0000-000000a7000d', 'ol.tutor5@centre.test'), ('00000000-0000-0000-0000-000000a7000e', 'ol.tutor6@centre.test');
\set OWNER '00000000-0000-0000-0000-000000a70001'
\set STAFF '00000000-0000-0000-0000-000000a70002'
\set MONEY '00000000-0000-0000-0000-000000a70003'
\set T1 '00000000-0000-0000-0000-000000a70004'
\set T2 '00000000-0000-0000-0000-000000a70005'
\set SOLO '00000000-0000-0000-0000-000000a70006'
\set OFF '00000000-0000-0000-0000-000000a70007'
\set PARENT '00000000-0000-0000-0000-000000a70008'
\set T4 '00000000-0000-0000-0000-000000a7000a'
\set TK '00000000-0000-0000-0000-000000a7000c'
\set T5 '00000000-0000-0000-0000-000000a7000d'
\set T6 '00000000-0000-0000-0000-000000a7000e'

-- the centre's clock is chosen so that LOCAL time of day "now" is about 12:xx all the time: then "now + 23 hours" and "now + 25 hours" are on one local day, mid-day,
-- whatever the hour the test is run at (no flakiness around midnight). Etc/GMT-k means UTC+k.
create temp table td as
  select (12 - extract(hour from (now() at time zone 'UTC')))::int as k0;
create temp table tz as
  select case when k > 0 then 'Etc/GMT-' || k when k < 0 then 'Etc/GMT+' || (-k) else 'Etc/GMT' end as name
    from (select ((k0 + 12 + 24) % 24) - 12 as k from td) x;
grant select on td, tz to authenticated, anon;

set role authenticated; select t.as(:'OWNER');
select t.put('to', org_create_centre('Own Lessons Centre', t.centre_settings()));
select t.as('00000000-0000-0000-0000-000000a70009');
select t.put('to2', org_create_centre('Other Own Centre', t.centre_settings()));
select t.as('00000000-0000-0000-0000-000000a7000b');
select t.put('tk', org_create_centre('Kiritimati Own Centre', t.centre_settings()));
reset role; select set_config('request.jwt.claims', '', false);
select org_personal(:'SOLO');
update organisations set timezone = (select name from tz) where id = t.id('to');
update organisations set timezone = 'Pacific/Kiritimati' where id = t.id('tk');
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('to'), :'STAFF',  'Staff Sam',   'staff', array['manage_timetable'], 'active'),
  (t.id('to'), :'MONEY',  'Staff Money', 'staff', array['issue_invoices'], 'active'),
  (t.id('to'), :'T1',     'Tutor One',   'tutor', '{}', 'active'),
  (t.id('to'), :'T2',     'Tutor Two',   'tutor', '{}', 'active'),
  (t.id('to'), :'OFF',    'Switched off', 'tutor', '{}', 'active'),
  (t.id('to'), :'PARENT', 'A Parent',    'parent', '{}', 'active'),
  (t.id('to'), :'T5',     'Tutor Five',  'tutor', '{}', 'active'),
  (t.id('to'), '00000000-0000-0000-0000-000000a7000e', 'Tutor Six', 'tutor', '{}', 'active'),
  (t.id('to2'), :'T4',    'Tutor Four elsewhere', 'tutor', '{}', 'active'),
  (t.id('tk'), :'TK',     'Tutor Kiri',  'tutor', '{}', 'active');
select t.put('m1', (select id from memberships where org_id = t.id('to') and user_id = :'T1'));
select t.put('m2', (select id from memberships where org_id = t.id('to') and user_id = :'T2'));
select t.put('m5', (select id from memberships where org_id = t.id('to') and user_id = :'T5'));
select t.put('m6', (select id from memberships where org_id = t.id('to') and user_id = :'T6'));
select t.put('mk', (select id from memberships where org_id = t.id('tk') and user_id = :'TK'));

insert into students(id, tutor_id, org_id, name, level, contact, end_date) values
  ('00000000-0000-0000-0000-000000a70101', :'OWNER', t.id('to'), 'Ann',  'P1', '91110001', null),
  ('00000000-0000-0000-0000-000000a70102', :'OWNER', t.id('to'), 'Ben',  'P2', '91110002', null),
  ('00000000-0000-0000-0000-000000a70103', :'OWNER', t.id('to'), 'Cal (not assigned)', 'P3', '91110003', null),
  ('00000000-0000-0000-0000-000000a70104', :'OWNER', t.id('to'), 'Dee (ended)', 'P4', '91110004', current_date - 1),
  ('00000000-0000-0000-0000-000000a70105', :'OWNER', t.id('to'), 'Eve (new, no price yet)', 'P5', '91110005', null),
  ('00000000-0000-0000-0000-000000a70106', :'OWNER', t.id('to'), 'Fay', 'P6', '91110006', null),
  ('00000000-0000-0000-0000-000000a70107', :'OWNER', t.id('to'), 'Hal (group)', 'S1', '91110007', null),
  ('00000000-0000-0000-0000-000000a70108', :'OWNER', t.id('to'), 'Ivy (group)', 'S1', '91110008', null),
  ('00000000-0000-0000-0000-000000a70109', :'OWNER', t.id('to'), 'Zed (tutor five)', 'S2', '91110009', null),
  ('00000000-0000-0000-0000-000000a7010a', :'OWNER', t.id('to'), 'Kim (tutor six)', 'S2', '91110010', null),
  ('00000000-0000-0000-0000-000000a7010b', :'OWNER', t.id('to'), 'Lee (tutor six)', 'S2', '91110011', null),
  ('00000000-0000-0000-0000-000000a701f1', '00000000-0000-0000-0000-000000a70009', t.id('to2'), 'Kid elsewhere', 'P1', '91119999', null);
insert into students(id, tutor_id, org_id, name, level, contact) values
  ('00000000-0000-0000-0000-000000a70111', '00000000-0000-0000-0000-000000a7000b', t.id('tk'), 'Kid Kiri', 'P5', '91110099');
insert into student_tutors(org_id, student_id, membership_id) values
  (t.id('to'), '00000000-0000-0000-0000-000000a70101', t.id('m1')), (t.id('to'), '00000000-0000-0000-0000-000000a70102', t.id('m2')),
  (t.id('to'), '00000000-0000-0000-0000-000000a70104', t.id('m1')), (t.id('to'), '00000000-0000-0000-0000-000000a70105', t.id('m1')),
  (t.id('to'), '00000000-0000-0000-0000-000000a70106', t.id('m1')), (t.id('to'), '00000000-0000-0000-0000-000000a70107', t.id('m1')),
  (t.id('to'), '00000000-0000-0000-0000-000000a70108', t.id('m1')), (t.id('to'), '00000000-0000-0000-0000-000000a70109', t.id('m5')),
  (t.id('to'), '00000000-0000-0000-0000-000000a7010a', t.id('m6')), (t.id('to'), '00000000-0000-0000-0000-000000a7010b', t.id('m6')),
  (t.id('tk'), '00000000-0000-0000-0000-000000a70111', t.id('mk'));

-- STAFF-made rows that give a price to copy. Ann: an older lesson at 12.50, then a LATER slot at the marker 777.77 (latest wins); then a TUTOR-made lesson at 555.55
-- later still (never a basis). Fay: one staff slot at 40.00. Eve: nothing. Hal and Ivy: a staff group slot at 25.00 with a session key.
insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, taught_by, created_at) values
  (:'OWNER', t.id('to'), '00000000-0000-0000-0000-000000a70101', current_date - 30, '10:00', '11:00', 12.50, 12.50, 'done', t.id('m1'), now() - interval '10 days');
insert into recurring_slots(id, tutor_id, org_id, student_id, weekday, start_time, end_time, rate, active, taught_by, created_at) values
  ('00000000-0000-0000-0000-000000a70201', :'OWNER', t.id('to'), '00000000-0000-0000-0000-000000a70101', 0, '09:00', '10:00', 777.77, false, t.id('m1'), now() - interval '5 days');
insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, taught_by, created_by_tutor, created_at) values
  (:'OWNER', t.id('to'), '00000000-0000-0000-0000-000000a70101', current_date - 20, '10:00', '11:00', 555.55, 555.55, 'done', t.id('m1'), t.id('m1'), now() - interval '1 day');

-- ---- helpers (session-local)
create function pg_temp.lday(n int) returns date language sql stable as $$ select ((now() at time zone (select name from tz))::date + n) $$;
create function pg_temp.ldate(h numeric) returns date language sql stable as $$ select ((now() + h * interval '1 hour') at time zone (select name from tz))::date $$;
create function pg_temp.ltime(h numeric) returns time language sql stable as $$ select date_trunc('minute', ((now() + h * interval '1 hour') at time zone (select name from tz))::time)::time $$;
create function pg_temp.settings(p_org text, p_owner text, p_lessons jsonb, p_calendar jsonb default '{}') returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_owner, 'role', 'authenticated')::text, false);
  set local role authenticated;
  perform org_save_settings(t.id(p_org), jsonb_set(jsonb_set(jsonb_set(t.centre_settings(), '{billing,model}', '"postpaid_lessons"'), '{lessons}', p_lessons), '{calendar}', p_calendar), current_date);
  reset role;
end $$;
create function pg_temp.call(p_user text, p_sql text) returns text language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claims', case when p_user is null then '' else json_build_object('sub', p_user, 'role', 'authenticated')::text end, false);
  set local role authenticated;
  begin execute p_sql into r; exception when others then r := 'ERR:' || sqlerrm; end;
  reset role;
  return r;
end $$;
create function pg_temp.expect(p_user text, p_sql text, p_expect text, p_msg text) returns text language plpgsql as $$
declare r text := pg_temp.call(p_user, p_sql);
begin
  if p_expect = 'ok' then
    if r like 'ERR:%' then raise exception 'FAIL: % (refused: %)', p_msg, r; end if;
  elsif r is null or r not like 'ERR:' || p_expect || '%' then
    raise exception 'FAIL: % (got "%", expected "%...")', p_msg, r, p_expect; end if;
  raise notice 'PASS %: %', case when p_expect = 'ok' then 'allowed' else 'refused ' || p_expect end, p_msg;
  return r;
end $$;
create function pg_temp.keep(p_key text, p_json text, p_field text) returns void language plpgsql as $$
begin perform t.put(p_key, (p_json::jsonb->>p_field)::uuid); end $$;
-- add a lesson (a student by its uuid, a date and "HH:MM"-style times); the answer or ERR:...
create function pg_temp.addl(p_user text, p_student text, p_date date, p_start text, p_end text, p_subject text default null, p_note text default null) returns text language sql as $$
  select pg_temp.call(p_user, format('select tutor_add_lesson(%L, %L, %L::time, %L::time, %L, %L)', p_student, p_date, p_start, p_end, p_subject, p_note)) $$;
-- add a lesson that starts p_h hours from now (centre clock) and lasts p_min minutes
create function pg_temp.addh(p_user text, p_student text, p_h numeric, p_min int default 30) returns text language sql as $$
  select pg_temp.addl(p_user, p_student, pg_temp.ldate(p_h), pg_temp.ltime(p_h)::text, (pg_temp.ltime(p_h) + p_min * interval '1 minute')::time::text) $$;
create function pg_temp.slot(p_user text, p_slot text, p_student text, p_wd int, p_start text, p_end text, p_subject text default null) returns text language sql as $$
  select pg_temp.call(p_user, format('select tutor_save_slot(%L, %L, %s, %L::time, %L::time, %L)', p_slot, p_student, coalesce(p_wd::text, 'null'), p_start, p_end, p_subject)) $$;
create function pg_temp.stop(p_user text, p_slot text) returns text language sql as $$ select pg_temp.call(p_user, format('select tutor_stop_slot(%L)', p_slot)) $$;
create function pg_temp.gen(p_user text, p_org text, p_from date default null, p_to date default null) returns text language sql as $$
  select pg_temp.call(p_user, format('select tutor_generate_lessons(%L, %L, %L)', p_org, p_from, p_to)) $$;
create function pg_temp.lk(p_id uuid) returns lessons language sql as $$ select l from lessons l where l.id = p_id $$;
create function pg_temp.keys(j jsonb) returns setof text language sql as $$
  with recursive r(v, k) as (
    select j, null::text
    union all
    select c.value, c.key from r, lateral (
      select e.key, e.value from jsonb_each(case when jsonb_typeof(r.v) = 'object' then r.v else '{}'::jsonb end) e
      union all
      select null::text, a.value from jsonb_array_elements(case when jsonb_typeof(r.v) = 'array' then r.v else '[]'::jsonb end) a) c)
  select k from r where k is not null $$;
-- every answer and every refusal a tutor receives is kept here, so the money checks at the end read all of them
create function pg_temp.chk(p_res text, p_expect text, p_msg text) returns text language plpgsql as $$
begin
  if p_expect = 'ok' then
    if p_res like 'ERR:%' then raise exception 'FAIL: % (refused: %)', p_msg, p_res; end if;
  elsif p_res is null or p_res not like 'ERR:' || p_expect || '%' then
    raise exception 'FAIL: % (got "%", expected "%...")', p_msg, p_res, p_expect; end if;
  raise notice 'PASS %: %', case when p_expect = 'ok' then 'allowed' else 'refused ' || p_expect end, p_msg;
  return p_res;
end $$;
create table pg_temp.said(txt text);
create function pg_temp.say(p text) returns text language plpgsql as $$ begin insert into pg_temp.said values (p); return p; end $$;
grant all on pg_temp.said to public;
grant execute on all functions in schema pg_temp to public;
select set_config('request.jwt.claims', '', false);

\set A '00000000-0000-0000-0000-000000a70101'
\set B '00000000-0000-0000-0000-000000a70102'
\set C '00000000-0000-0000-0000-000000a70103'
\set D '00000000-0000-0000-0000-000000a70104'
\set E '00000000-0000-0000-0000-000000a70105'
\set F '00000000-0000-0000-0000-000000a70106'
\set H '00000000-0000-0000-0000-000000a70107'
\set I '00000000-0000-0000-0000-000000a70108'
\set Z '00000000-0000-0000-0000-000000a70109'
\set K '00000000-0000-0000-0000-000000a7010a'
\set L '00000000-0000-0000-0000-000000a7010b'
\set KIRI '00000000-0000-0000-0000-000000a70111'
\set ELSE '00000000-0000-0000-0000-000000a701f1'

-- STAFF-made slots (direct inserts = what the staff screens make). Fay: 40.00 on Fridays (wd 4). Ben (tutor two): Saturdays 16:00. Dee (ended) and Cal (not assigned): mine on
-- Tuesday / Thursday mornings (they must never make a lesson). Hal + Ivy: a staff GROUP class on Sundays at 25.00 (a session key). Zed (tutor five), Kim (tutor six).
insert into recurring_slots(id, tutor_id, org_id, student_id, weekday, start_time, end_time, rate, subject, active, taught_by, session_key, created_at) values
  ('00000000-0000-0000-0000-000000a70202', :'OWNER', t.id('to'), :'F', 4, '16:00', '17:00', 40.00, 'English', true, t.id('m1'), null, now() - interval '3 days'),
  ('00000000-0000-0000-0000-000000a70203', :'OWNER', t.id('to'), :'B', 5, '16:00', '17:00', 33.00, 'Math', true, t.id('m2'), null, now() - interval '3 days'),
  ('00000000-0000-0000-0000-000000a70204', :'OWNER', t.id('to'), :'D', 1, '08:00', '09:00', 20.00, 'Math', true, t.id('m1'), null, now() - interval '3 days'),
  ('00000000-0000-0000-0000-000000a70205', :'OWNER', t.id('to'), :'C', 3, '08:00', '09:00', 20.00, 'Math', true, t.id('m1'), null, now() - interval '3 days'),
  ('00000000-0000-0000-0000-000000a70206', :'OWNER', t.id('to'), :'H', 6, '10:00', '11:00', 25.00, 'Math', true, t.id('m1'), '00000000-0000-0000-0000-000000a70301', now() - interval '3 days'),
  ('00000000-0000-0000-0000-000000a70207', :'OWNER', t.id('to'), :'I', 6, '10:00', '11:00', 25.00, 'Math', true, t.id('m1'), '00000000-0000-0000-0000-000000a70301', now() - interval '3 days');
select t.put('S_F', '00000000-0000-0000-0000-000000a70202'); select t.put('S_B', '00000000-0000-0000-0000-000000a70203'); select t.put('S_H', '00000000-0000-0000-0000-000000a70206');
select t.put('S_D', '00000000-0000-0000-0000-000000a70204'); select t.put('S_C', '00000000-0000-0000-0000-000000a70205');

-- ===================================================================== 1. who is refused, whatever the setting (always the same NOT_FOUND)
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":true,"weekly_slots":true,"generate":true}}');
select pg_temp.settings('tk', '00000000-0000-0000-0000-000000a7000b', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":true,"weekly_slots":true,"generate":true},"min_notice_hours":0}');
create function pg_temp.nf(p_user text, p_who text, p_student text, p_slot text, p_org text, p_gen boolean default true) returns void language plpgsql as $$
begin
  perform pg_temp.expect(p_user, format('select tutor_add_lesson(%L, current_date + 300, ''10:00''::time, ''11:00''::time)', p_student), 'NOT_FOUND', p_who || ': add a lesson');
  perform pg_temp.expect(p_user, format('select tutor_save_slot(null, %L, 2, ''10:00''::time, ''11:00''::time)', p_student), 'NOT_FOUND', p_who || ': add a slot');
  perform pg_temp.expect(p_user, format('select tutor_save_slot(%L, null, 2, ''10:00''::time, ''11:00''::time)', p_slot), 'NOT_FOUND', p_who || ': change a slot');
  perform pg_temp.expect(p_user, format('select tutor_stop_slot(%L)', p_slot), 'NOT_FOUND', p_who || ': stop a slot');
  if p_gen then perform pg_temp.expect(p_user, format('select tutor_generate_lessons(%L)', p_org), 'NOT_FOUND', p_who || ': create lessons'); end if;
end $$;
select pg_temp.nf(:'OWNER', 'the centre owner', :'F', t.id('S_F')::text, t.id('to')::text);
select pg_temp.nf(:'STAFF', 'centre staff', :'F', t.id('S_F')::text, t.id('to')::text);
select pg_temp.nf(:'PARENT', 'a parent', :'F', t.id('S_F')::text, t.id('to')::text);
select pg_temp.nf(:'SOLO', 'a solo tutor', :'F', t.id('S_F')::text, t.id('to')::text);
select pg_temp.nf(:'T2', 'another tutor of the same centre', :'F', t.id('S_F')::text, t.id('to')::text, false);   -- (their own "Create lessons" is allowed: it only ever touches their own slots)
select pg_temp.nf(:'T4', 'a tutor of ANOTHER centre', :'F', t.id('S_F')::text, t.id('to')::text);
select pg_temp.nf(:'T1', 'tutor one on a student of tutor two / tutor two''s slot / another centre', :'B', t.id('S_B')::text, t.id('to2')::text);
select pg_temp.nf(:'T1', 'tutor one on a student NOT assigned to anyone / their own slot of that student', :'C', t.id('S_C')::text, t.id('to2')::text);
select pg_temp.nf(:'T1', 'tutor one on a student of ANOTHER centre / an unknown slot', :'ELSE', '00000000-0000-0000-0000-00000000dead', '00000000-0000-0000-0000-00000000dead');
select pg_temp.nf(null, 'nobody signed in', :'F', t.id('S_F')::text, t.id('to')::text);
update memberships set status = 'disabled' where org_id = t.id('to') and user_id = :'OFF';
select pg_temp.nf(:'OFF', 'a switched-off tutor', :'F', t.id('S_F')::text, t.id('to')::text);
-- a tutor whose assignment ended is refused like a stranger
update student_tutors set active = false, until = current_date where student_id = :'F' and membership_id = t.id('m1');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, current_date + 300, ''10:00''::time, ''11:00''::time)', :'F'), 'NOT_FOUND', 'a student no longer assigned: add a lesson');
select pg_temp.expect(:'T1', format('select tutor_stop_slot(%L)', t.id('S_F')), 'NOT_FOUND', 'a student no longer assigned: stop their slot');
update student_tutors set active = true, until = null where student_id = :'F' and membership_id = t.id('m1');
select pg_temp.expect(:'OWNER', 'select tutor_my_students()', 'NOT_FOUND', 'the owner has no list of "my students"');
select pg_temp.expect(:'SOLO', 'select tutor_my_students()', 'NOT_FOUND', 'a solo tutor has no list of "my students"');

-- ===================================================================== 2. every setting value and every switch
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"admin_only","tutors_edit":{"one_off":true,"weekly_slots":true,"generate":true}}');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, current_date + 300, ''10:00''::time, ''11:00''::time)', :'A'), 'NOT_ALLOWED', 'admin_only (switches on): add a lesson');
select pg_temp.expect(:'T1', format('select tutor_save_slot(null, %L, 2, ''10:00''::time, ''11:00''::time)', :'A'), 'NOT_ALLOWED', 'admin_only: add a slot');
select pg_temp.expect(:'T1', format('select tutor_stop_slot(%L)', t.id('S_F')), 'NOT_ALLOWED', 'admin_only: stop a slot');
select pg_temp.expect(:'T1', format('select tutor_generate_lessons(%L)', t.id('to')), 'NOT_ALLOWED', 'admin_only: create lessons');
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_propose","tutors_edit":{"one_off":true,"weekly_slots":true,"generate":true}}');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, current_date + 300, ''10:00''::time, ''11:00''::time)', :'A'), 'NOT_ALLOWED', 'tutors_propose (not built): add a lesson');
select pg_temp.expect(:'T1', format('select tutor_generate_lessons(%L)', t.id('to')), 'NOT_ALLOWED', 'tutors_propose: create lessons');
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct"}');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, current_date + 300, ''10:00''::time, ''11:00''::time)', :'A'), 'SWITCH_OFF', 'tutors_direct, no switches (default): add a lesson');
select pg_temp.expect(:'T1', format('select tutor_save_slot(null, %L, 2, ''10:00''::time, ''11:00''::time)', :'A'), 'SWITCH_OFF', 'default: add a slot');
select pg_temp.expect(:'T1', format('select tutor_save_slot(%L, null, 2, ''10:00''::time, ''11:00''::time)', t.id('S_F')), 'SWITCH_OFF', 'default: change a slot');
select pg_temp.expect(:'T1', format('select tutor_stop_slot(%L)', t.id('S_F')), 'SWITCH_OFF', 'default: stop a slot');
select pg_temp.expect(:'T1', format('select tutor_generate_lessons(%L)', t.id('to')), 'SWITCH_OFF', 'default: create lessons');
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":false,"weekly_slots":false,"generate":false,"postpone":true}}');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, current_date + 300, ''10:00''::time, ''11:00''::time)', :'A'), 'SWITCH_OFF', 'all three switches explicitly off (postpone on does not help)');
-- one switch alone: only its own functions get past the gate (they then fail on purpose-built bad input, so nothing is created)
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":true}}');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, null, null, null)', :'A'), 'BAD_DATE', 'only one_off on: add a lesson passes the gate');
select pg_temp.expect(:'T1', format('select tutor_save_slot(null, %L, 2, ''10:00''::time, ''11:00''::time)', :'A'), 'SWITCH_OFF', 'only one_off on: slots still off');
select pg_temp.expect(:'T1', format('select tutor_generate_lessons(%L)', t.id('to')), 'SWITCH_OFF', 'only one_off on: create lessons still off');
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"weekly_slots":true}}');
select pg_temp.expect(:'T1', format('select tutor_save_slot(null, %L, 9, ''10:00''::time, ''11:00''::time)', :'A'), 'BAD_SLOT', 'only weekly_slots on: add a slot passes the gate');
select pg_temp.expect(:'T1', format('select tutor_stop_slot(%L)', t.id('S_H')), 'GROUP_CLASS', 'only weekly_slots on: stop passes the gate (a group class is staff''s)');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, current_date + 300, ''10:00''::time, ''11:00''::time)', :'A'), 'SWITCH_OFF', 'only weekly_slots on: add a lesson still off');
select pg_temp.expect(:'T1', format('select tutor_generate_lessons(%L)', t.id('to')), 'SWITCH_OFF', 'only weekly_slots on: create lessons still off');
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"generate":true}}');
select pg_temp.expect(:'T1', format('select tutor_generate_lessons(%L, current_date, current_date + 90)', t.id('to')), 'BAD_RANGE', 'only generate on: create lessons passes the gate');
select pg_temp.expect(:'T1', format('select tutor_save_slot(null, %L, 2, ''10:00''::time, ''11:00''::time)', :'A'), 'SWITCH_OFF', 'only generate on: slots still off');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, current_date + 300, ''10:00''::time, ''11:00''::time)', :'A'), 'SWITCH_OFF', 'only generate on: add a lesson still off');
-- an unknown switch value is not accepted by the validator
select t.ok(pg_temp.call(:'OWNER', format($q$ select org_save_settings(%L, jsonb_set(t.centre_settings(), '{lessons}', '{"tutors_edit":{"one_off":"yes"}}'), current_date)::text $q$, t.id('to'))) like 'ERR:%', 'a switch must still be yes or no');

-- ===================================================================== 3. add one lesson
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":true,"weekly_slots":true,"generate":true},"min_notice_hours":24}');
-- the price: Ann's LATEST staff-made row is the slot at the marker 777.77 (the older lesson at 12.50 and the tutor-made one at 555.55 are not used)
select pg_temp.say(pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''16:00''::time, ''16:30''::time)', :'A', pg_temp.lday(100)), 'ok', 'Ann: a one-off 30 minutes, 100 days ahead')) as r1 \gset
select pg_temp.keep('A1', :'r1', 'lesson_id');
select t.ok((pg_temp.lk(t.id('A1'))).rate = 777.77 and (pg_temp.lk(t.id('A1'))).amount = 388.89 and not (pg_temp.lk(t.id('A1'))).price_pending, 'the rate is the latest STAFF-made one (777.77), amount for 30 minutes; nothing waits');
select t.ok((pg_temp.lk(t.id('A1'))).one_off and (pg_temp.lk(t.id('A1'))).taught_by = t.id('m1') and (pg_temp.lk(t.id('A1'))).created_by_tutor = t.id('m1')
        and (pg_temp.lk(t.id('A1'))).status = 'scheduled' and not (pg_temp.lk(t.id('A1'))).paid and (pg_temp.lk(t.id('A1'))).tutor_id = :'OWNER' and (pg_temp.lk(t.id('A1'))).level = 'P1'
        and (pg_temp.lk(t.id('A1'))).changed_by_tutor_what = 'added' and (pg_temp.lk(t.id('A1'))).changed_by_tutor = t.id('m1') and (pg_temp.lk(t.id('A1'))).session_id is null
        and not (pg_temp.lk(t.id('A1'))).trial and (pg_temp.lk(t.id('A1'))).attendance is null and (pg_temp.lk(t.id('A1'))).slot_id is null,
        'one-off, mine, made by me, filed under the centre owner''s login, student''s level, flagged "added", no group, no trial, not marked');
select t.ok((select count(*) = 1 from audit_log where action = 'tutor_add_lesson' and row_id = t.id('A1')::text and actor = :'T1'), 'one audit row, with the tutor as actor');
select t.ok(:'r1'::jsonb->>'awaiting_centre' = 'false' and :'r1'::jsonb->>'lesson_date' = pg_temp.lday(100)::text, 'the answer says nothing waits for the centre');
-- pressed twice: nothing more
select pg_temp.say(pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''16:00''::time, ''16:30''::time)', :'A', pg_temp.lday(100)), 'ALREADY_THERE', 'the same lesson again (a double press)'));
select t.ok((select count(*) = 1 from lessons where student_id = :'A' and lesson_date = pg_temp.lday(100)), 'still exactly one lesson');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''16:15''::time, ''16:45''::time)', :'A', pg_temp.lday(100)), 'ALREADY_THERE', 'an overlapping lesson for the same student');
-- subject and note are kept; a new lesson with no staff row to copy waits for the centre
select pg_temp.say(pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''17:00''::time, ''18:00''::time, ''  Math  '', ''extra revision'')', :'A', pg_temp.lday(100)), 'ok', 'Ann: a second one with a subject and a note')) as r2 \gset
select pg_temp.keep('A2', :'r2', 'lesson_id');
select t.ok((pg_temp.lk(t.id('A2'))).subject = 'Math' and (pg_temp.lk(t.id('A2'))).changed_by_tutor_reason = 'extra revision' and (pg_temp.lk(t.id('A2'))).amount = 777.77, 'subject trimmed, note kept, a full hour = the hourly rate');
select pg_temp.say(pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''10:00''::time, ''11:00''::time)', :'E', pg_temp.lday(101)), 'ok', 'Eve: no earlier staff lesson to copy')) as r3 \gset
select pg_temp.keep('E1', :'r3', 'lesson_id');
select t.ok((pg_temp.lk(t.id('E1'))).price_pending and (pg_temp.lk(t.id('E1'))).rate = 0 and (pg_temp.lk(t.id('E1'))).amount = 0 and :'r3'::jsonb->>'awaiting_centre' = 'true',
        'no staff row to copy: the price is empty and FLAGGED, and the answer says the centre will confirm');
select pg_temp.say(pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''14:00''::time, ''15:00''::time)', :'F', pg_temp.lday(101)), 'ok', 'Fay: has a staff slot at 40')) as r4 \gset
select pg_temp.keep('F1', :'r4', 'lesson_id');
select t.ok((pg_temp.lk(t.id('F1'))).rate = 40 and (pg_temp.lk(t.id('F1'))).amount = 40 and not (pg_temp.lk(t.id('F1'))).price_pending and (pg_temp.lk(t.id('F1'))).subject = 'English',
        'Fay''s lesson copies the staff slot''s 40 per hour and its subject');
-- a waiting tutor-made lesson is never itself used as the basis for another
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''12:00''::time, ''13:00''::time)', :'E', pg_temp.lday(101)), 'ok', 'Eve: a second lesson');
select t.ok((select bool_and(price_pending and rate = 0) from lessons where student_id = :'E' and created_by_tutor is not null), 'both of Eve''s lessons wait (a waiting lesson is not a price to copy)');
-- input checks
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''10:00''::time, ''11:00''::time)', :'D', pg_temp.lday(102)), 'STUDENT_ENDED', 'a student whose lessons have ended');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, null, ''10:00''::time, ''11:00''::time)', :'A'), 'BAD_DATE', 'no date');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, null, ''11:00''::time)', :'A', pg_temp.lday(102)), 'BAD_DATE', 'no start time');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''10:00''::time, ''11:00''::time)', :'A', pg_temp.lday(366)), 'BAD_DATE', 'more than a year ahead');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''10:00''::time, ''11:00''::time)', :'A', pg_temp.lday(365)), 'ok', 'exactly a year ahead is allowed');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''10:00''::time, ''10:00''::time)', :'A', pg_temp.lday(103)), 'BAD_TIME', 'ends when it starts');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''11:00''::time, ''10:00''::time)', :'A', pg_temp.lday(103)), 'BAD_TIME', 'ends before it starts');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''10:00''::time, ''10:14''::time)', :'A', pg_temp.lday(103)), 'BAD_TIME', '14 minutes is too short');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''10:00''::time, ''10:15''::time)', :'A', pg_temp.lday(103)), 'ok', '15 minutes is allowed');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''08:00''::time, ''16:01''::time)', :'A', pg_temp.lday(104)), 'BAD_TIME', 'over 8 hours is too long');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''10:00''::time, ''11:00''::time, %L)', :'A', pg_temp.lday(104), repeat('x', 61)), 'TOO_LONG', 'a subject of 61 characters');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''10:00''::time, ''11:00''::time, null, %L)', :'A', pg_temp.lday(104), repeat('x', 301)), 'TOO_LONG', 'a note of 301 characters');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''10:00''::time, ''11:00''::time, null, %L)', :'A', pg_temp.lday(104), repeat('x', 300)), 'ok', 'a note of 300 characters');
-- the notice: 24 hours (setting above), 0, 168 (the edges)
select pg_temp.chk(pg_temp.addh(:'T1', :'F', 23), 'TOO_LATE', 'notice 24: a lesson 23 hours from now');
select pg_temp.chk(pg_temp.addh(:'T1', :'F', 25), 'ok', 'notice 24: a lesson 25 hours from now');
select pg_temp.chk(pg_temp.addh(:'T1', :'F', -1), 'BAD_DATE', 'a lesson an hour ago is in the past');
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":true},"min_notice_hours":0}');
select pg_temp.chk(pg_temp.addh(:'T1', :'A', 2), 'ok', 'notice 0: a lesson 2 hours from now');
select pg_temp.chk(pg_temp.addh(:'T1', :'A', -0.5), 'BAD_DATE', 'notice 0: still nothing in the past');
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":true},"min_notice_hours":168}');
select pg_temp.chk(pg_temp.addh(:'T1', :'F', 167), 'TOO_LATE', 'notice 168: a lesson 167 hours from now');
select pg_temp.chk(pg_temp.addh(:'T1', :'F', 169), 'ok', 'notice 168: a lesson 169 hours from now');
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":true,"weekly_slots":true,"generate":true},"min_notice_hours":24}');
-- holiday, clashes (YOUR lessons only), cancelled lessons don't clash
insert into holidays(org_id, name, starts_on, ends_on) values (t.id('to'), 'Test Festival', pg_temp.lday(150), pg_temp.lday(150));
select pg_temp.chk(pg_temp.addl(:'T1', :'A', pg_temp.lday(150), '10:00', '11:00'), 'HOLIDAY: Test Festival', 'a whole-centre holiday is refused with its name');
select pg_temp.chk(pg_temp.addl(:'T1', :'F', pg_temp.lday(110), '16:00', '17:00'), 'ok', 'Fay 16:00-17:00 (tutor one''s first lesson that day)');
select pg_temp.say(pg_temp.chk(pg_temp.addl(:'T1', :'A', pg_temp.lday(110), '16:30', '17:30'), 'CLASH: you already teach Fay', 'Ann overlapping my own lesson with Fay')) ;
select pg_temp.chk(pg_temp.addl(:'T1', :'F', pg_temp.lday(110), '16:30', '17:30'), 'ALREADY_THERE: Fay', 'Fay again, overlapping her own lesson (not "clash")');
insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, taught_by) values
  (:'OWNER', t.id('to'), :'B', pg_temp.lday(111), '16:00', '17:00', 33, 33, 'scheduled', t.id('m2'));
select pg_temp.chk(pg_temp.addl(:'T1', :'A', pg_temp.lday(111), '16:00', '17:00'), 'ok', 'another tutor''s lesson at the same time is NOT a clash (and is never named)');
update lessons set status = 'cancelled', compensation = 0 where student_id = :'F' and lesson_date = pg_temp.lday(110);
select pg_temp.chk(pg_temp.addl(:'T1', :'A', pg_temp.lday(110), '16:30', '17:30'), 'ok', 'a cancelled lesson does not clash');
-- the student the tutor is not assigned to, and a student of another centre, were refused in part 1; a group class cannot be added (no such option exists)
select t.ok((select count(*) = 0 from pg_proc p where p.proname = 'tutor_add_lesson' and pg_get_function_arguments(p.oid) ~* '(session|group|trial)'), 'tutor_add_lesson has no group or trial argument');
select t.ok(not exists (select 1 from lessons where created_by_tutor is not null and (session_id is not null or trial)), 'nothing a tutor added is a group lesson or a trial');
-- the centre's own clock (Kiritimati is a day ahead of UTC for part of every day)
select pg_temp.chk(pg_temp.call(:'TK', format('select tutor_add_lesson(%L, (now() at time zone ''Pacific/Kiritimati'')::date, ''00:00''::time, ''00:30''::time)', :'KIRI')), 'BAD_DATE', 'Kiritimati: local midnight today has already passed there');
select pg_temp.chk(pg_temp.call(:'TK', format('select tutor_add_lesson(%L, (now() at time zone ''Pacific/Kiritimati'')::date + 2, ''10:00''::time, ''11:00''::time)', :'KIRI')), 'ok', 'Kiritimati: two local days ahead');
select t.ok((select lesson_date = (now() at time zone 'Pacific/Kiritimati')::date + 2 from lessons where student_id = :'KIRI'), 'the lesson is on the centre''s own day');
select pg_temp.chk(pg_temp.gen(:'TK', t.id('tk')::text), 'ok', 'Kiritimati: create lessons with no dates');
select t.ok(pg_temp.call(:'TK', format('select tutor_generate_lessons(%L)', t.id('tk')))::jsonb->>'from' = ((now() at time zone 'Pacific/Kiritimati')::date)::text, '...starts from the centre''s own today');

-- ===================================================================== 4. the monthly limit (the new actions count, with the step 2 ones)
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":true,"weekly_slots":true,"generate":true,"postpone":true},"min_notice_hours":0,"max_changes_per_month":2}');
insert into recurring_slots(tutor_id, org_id, student_id, weekday, start_time, end_time, rate, active, taught_by) values (:'OWNER', t.id('to'), :'K', 2, '08:00', '09:00', 30, true, t.id('m6'));
select pg_temp.chk(pg_temp.addl('00000000-0000-0000-0000-000000a7000e', :'K', pg_temp.lday(120), '10:00', '11:00'), 'ok', 'limit 2: change 1 (add a lesson)');
select pg_temp.chk(pg_temp.addl('00000000-0000-0000-0000-000000a7000e', :'L', pg_temp.lday(120), '12:00', '13:00'), 'ok', 'limit 2: change 2 (add a lesson)');
select pg_temp.chk(pg_temp.addl('00000000-0000-0000-0000-000000a7000e', :'K', pg_temp.lday(121), '10:00', '11:00'), 'LIMIT: you have used your 2 schedule changes', 'limit 2: a third is refused (one over)');
select pg_temp.chk(pg_temp.slot('00000000-0000-0000-0000-000000a7000e', null, :'K', 3, '10:00', '11:00'), 'LIMIT', 'limit 2: adding a slot counts too');
select pg_temp.chk(pg_temp.stop('00000000-0000-0000-0000-000000a7000e', (select id::text from recurring_slots where student_id = :'K' limit 1)), 'LIMIT', 'limit 2: stopping a slot counts too');
select pg_temp.chk(pg_temp.gen('00000000-0000-0000-0000-000000a7000e', t.id('to')::text, pg_temp.lday(200), pg_temp.lday(206)), 'ok', 'limit 2: "Create lessons" is NOT a change and still works at the limit');
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":true,"weekly_slots":true,"generate":true,"postpone":true},"min_notice_hours":0,"max_changes_per_month":3}');
select pg_temp.chk(pg_temp.addl('00000000-0000-0000-0000-000000a7000e', :'K', pg_temp.lday(121), '10:00', '11:00'), 'ok', 'limit 3: the third is allowed (two used, the edge)');
select pg_temp.chk(pg_temp.addl('00000000-0000-0000-0000-000000a7000e', :'K', pg_temp.lday(122), '10:00', '11:00'), 'LIMIT: you have used your 3', 'limit 3: the fourth is refused');
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":true,"weekly_slots":true,"generate":true,"postpone":true},"min_notice_hours":0,"max_changes_per_month":1}');
select pg_temp.chk(pg_temp.addl('00000000-0000-0000-0000-000000a7000e', :'K', pg_temp.lday(122), '10:00', '11:00'), 'LIMIT: you have used your 1 schedule change for', 'limit 1 reads singular');
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":true,"weekly_slots":true,"generate":true,"postpone":true},"min_notice_hours":0,"max_changes_per_month":0}');
select pg_temp.chk(pg_temp.addl('00000000-0000-0000-0000-000000a7000e', :'K', pg_temp.lday(122), '10:00', '11:00'), 'ok', 'limit 0 = no limit');
-- a step 2 change (a move) counts toward the same limit as an add
insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, taught_by) values
  ('00000000-0000-0000-0000-000000a70401', :'OWNER', t.id('to'), :'Z', pg_temp.lday(60), '10:00', '11:00', 30, 30, 'scheduled', t.id('m5'));
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":true,"postpone":true},"min_notice_hours":0,"max_changes_per_month":1}');
select pg_temp.chk(pg_temp.call(:'T5', format('select tutor_postpone_lesson(%L, %L, ''10:00''::time, ''school event'')', '00000000-0000-0000-0000-000000a70401', pg_temp.lday(61))), 'ok', 'limit 1: a move is the one change');
select pg_temp.chk(pg_temp.addl(:'T5', :'Z', pg_temp.lday(62), '10:00', '11:00'), 'LIMIT', 'limit 1: then an add is refused (the same count)');
select t.ok((pg_temp.call(:'T5', format('select tutor_my_schedule(%L, %L)', pg_temp.lday(0), pg_temp.lday(5)))::jsonb #>> '{orgs,0,changes_left}') = '0', 'the schedule says no changes are left');
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":true,"weekly_slots":true,"generate":true,"postpone":true,"cancel":true},"min_notice_hours":24}');

-- ===================================================================== 5. weekly slots: add, change, stop
-- add: Eve has no staff price to copy, so her slot waits for the centre; Fay's second slot copies 40
select pg_temp.say(pg_temp.chk(pg_temp.slot(:'T1', null, :'E', 1, '16:00', '17:00', 'Science'), 'ok', 'Eve: a weekly slot on Mondays 16:00-17:00')) as s1 \gset
select pg_temp.keep('SE1', :'s1', 'slot_id');
select t.ok(:'s1'::jsonb->>'added' = 'true' and :'s1'::jsonb->>'awaiting_centre' = 'true' and :'s1'::jsonb->>'lessons_left' = '0', 'the answer: added, the centre will confirm, no lessons made yet');
select t.ok((select weekday = 1 and start_time = '16:00' and end_time = '17:00' and subject = 'Science' and rate = 0 and price_pending and active and session_key is null and taught_by = t.id('m1')
                    and created_by_tutor = t.id('m1') and changed_by_tutor_what = 'added' and changed_by_tutor = t.id('m1') and tutor_id = :'OWNER' and level = 'P5' and split = 1
               from recurring_slots where id = t.id('SE1')), 'the slot is mine, one student, price empty and flagged, flagged "added", filed under the owner''s login');
select t.ok((select count(*) = 1 from audit_log where action = 'tutor_save_slot' and row_id = t.id('SE1')::text and actor = :'T1'), 'audited');
select pg_temp.say(pg_temp.chk(pg_temp.slot(:'T1', null, :'A', 2, '15:00', '16:00'), 'ok', 'Ann: a weekly slot (Wednesdays)')) as s2 \gset
select pg_temp.keep('SA1', :'s2', 'slot_id');
select t.ok((select rate = 777.77 and not price_pending from recurring_slots where id = t.id('SA1')), 'Ann''s slot copies the latest staff-made rate');
select pg_temp.chk(pg_temp.slot(:'T1', null, :'F', 4, '16:30', '17:30'), 'SLOT_CLASH: Fay already has a weekly lesson', 'Fay already has a weekly slot then');
select pg_temp.chk(pg_temp.slot(:'T1', null, :'A', 4, '16:30', '17:30'), 'TUTOR_CLASH: you already teach Fay', 'I already teach Fay then (my own slots)');
select pg_temp.chk(pg_temp.slot(:'T1', null, :'A', 5, '16:00', '17:00'), 'ok', 'tutor two''s slot at the same time is not a clash and is not named') as s3 \gset
select pg_temp.chk(pg_temp.slot(:'T1', null, :'D', 3, '12:00', '13:00'), 'STUDENT_ENDED', 'an ended student can''t get a new slot');
select pg_temp.chk(pg_temp.slot(:'T1', null, :'A', 7, '12:00', '13:00'), 'BAD_SLOT', 'weekday 7');
select pg_temp.chk(pg_temp.slot(:'T1', null, :'A', -1, '12:00', '13:00'), 'BAD_SLOT', 'weekday -1');
select pg_temp.chk(pg_temp.slot(:'T1', null, :'A', null, '12:00', '13:00'), 'BAD_SLOT', 'no weekday');
select pg_temp.chk(pg_temp.slot(:'T1', null, :'A', 3, '13:00', '12:00'), 'BAD_TIME', 'ends before it starts');
select pg_temp.chk(pg_temp.slot(:'T1', null, :'A', 3, '12:00', '12:10'), 'BAD_TIME', '10 minutes');
select pg_temp.chk(pg_temp.slot(:'T1', null, :'A', 3, '08:00', '16:30'), 'BAD_TIME', 'over 8 hours');
select pg_temp.chk(pg_temp.slot(:'T1', null, :'A', 3, '12:00', '13:00', repeat('y', 61)), 'TOO_LONG', 'a long subject');
-- change MY slot: day, time, subject; the student and the price never change
select pg_temp.say(pg_temp.chk(pg_temp.slot(:'T1', t.id('SE1')::text, null, 3, '15:00', '16:00', 'Science 2'), 'ok', 'Eve''s slot moved to Thursdays 15:00')) as s4 \gset
select t.ok(:'s4'::jsonb->>'added' = 'false' and :'s4'::jsonb->>'awaiting_centre' = 'true', 'the answer says it was a change, and the centre still has to confirm');
select t.ok((select weekday = 3 and start_time = '15:00' and subject = 'Science 2' and student_id = :'E' and rate = 0 and price_pending and changed_by_tutor_what = 'changed' and created_by_tutor = t.id('m1')
               from recurring_slots where id = t.id('SE1')), 'changed in place, flagged "changed", still made by me, price untouched');
select pg_temp.chk(pg_temp.slot(:'T1', t.id('SE1')::text, :'A', 2, '15:30', '16:30', 'Science 2'), 'TUTOR_CLASH: you already teach Ann', 'a change that would overlap my own other slot (Ann Wednesdays 15:00)');
select t.ok((select student_id = :'E' from recurring_slots where id = t.id('SE1')), 'a student argument on a change is ignored: the slot keeps its student');
select pg_temp.chk(pg_temp.slot(:'T1', t.id('SE1')::text, null, 3, '15:00', '16:00', 'same again'), 'ok', 'saving a slot onto itself is not a clash');
select pg_temp.chk(pg_temp.slot(:'T1', t.id('S_B')::text, null, 2, '15:00', '16:00'), 'NOT_FOUND', 'tutor two''s slot');
select pg_temp.chk(pg_temp.slot(:'T1', t.id('S_H')::text, null, 2, '15:00', '16:00'), 'GROUP_CLASS', 'a staff group class');
select pg_temp.chk(pg_temp.slot(:'T2', t.id('SE1')::text, null, 2, '15:00', '16:00'), 'NOT_FOUND', 'tutor two changing tutor one''s slot');
-- stop
select pg_temp.say(pg_temp.chk(pg_temp.stop(:'T1', t.id('SE1')::text), 'ok', 'stop Eve''s slot')) as st1 \gset
select t.ok(:'st1'::jsonb->>'stopped' = '1' and (select not active and changed_by_tutor_what = 'stopped' from recurring_slots where id = t.id('SE1')), 'stopped (switched off, not deleted), flagged "stopped"');
select pg_temp.chk(pg_temp.stop(:'T1', t.id('SE1')::text), 'ok', 'pressed twice: nothing happens');
select t.ok(pg_temp.stop(:'T1', t.id('SE1')::text)::jsonb->>'stopped' = '0' and (select count(*) = 1 from audit_log where action = 'tutor_stop_slot' and row_id = t.id('SE1')::text), 'the second press stopped nothing and wrote no second audit row');
select pg_temp.chk(pg_temp.slot(:'T1', t.id('SE1')::text, null, 2, '15:00', '16:00'), 'NOT_FOUND', 'a stopped slot can no longer be changed');
select pg_temp.chk(pg_temp.stop(:'T1', t.id('S_B')::text), 'NOT_FOUND', 'tutor two''s slot can''t be stopped');
select pg_temp.chk(pg_temp.stop(:'T1', t.id('S_H')::text), 'GROUP_CLASS', 'a group class can''t be stopped by a tutor');
select t.ok((select active from recurring_slots where id = t.id('S_B')) and (select active from recurring_slots where id = t.id('S_H')), 'and neither was touched');
-- a stopped slot keeps the lessons it already made
insert into lessons(tutor_id, org_id, student_id, slot_id, lesson_date, slot_date, start_time, end_time, rate, amount, status, taught_by, created_by_tutor, price_pending)
select :'OWNER', t.id('to'), :'E', t.id('SE1'), pg_temp.lday(300), pg_temp.lday(300), '15:00', '16:00', 0, 0, 'scheduled', t.id('m1'), t.id('m1'), true;   -- what a tutor's own slot made
select t.ok((select count(*) = 1 from lessons where slot_id = t.id('SE1')), 'the lesson a stopped slot made is still there');
-- a second pending slot for Eve that stays active (Wednesdays 18:00) for the generator
select pg_temp.say(pg_temp.chk(pg_temp.slot(:'T1', null, :'E', 2, '18:00', '19:00', 'Science'), 'ok', 'Eve: a weekly slot that stays, Wednesdays 18:00')) as s5 \gset
select pg_temp.keep('SE2', :'s5', 'slot_id');
-- Ann's slot on Saturdays 16:00 (the one that sits next to tutor two's)
select pg_temp.keep('SA2', :'s3', 'slot_id');

-- ===================================================================== 6. "Create lessons"
-- T1's active slots now: Fay Fri 16:00 (staff, 40) · Ann Wed 15:00 (777.77) and Sat 16:00 (777.77) · Eve Wed 18:00 (waits) · Hal+Ivy Sun 10:00 (staff group, 25)
--   plus Dee Tue 08:00 (ended student) and Cal Thu 08:00 (not assigned): direct staff inserts that must make nothing.
-- A 14-day range (30..43 days ahead) holds every weekday exactly twice. A holiday on the first Friday in it.
create temp table fri as select d from generate_series(pg_temp.lday(30), pg_temp.lday(43), interval '1 day') g(d) where extract(isodow from d) = 5 order by d limit 1;
grant select on fri to authenticated, anon;
insert into holidays(org_id, name, starts_on, ends_on) select t.id('to'), 'Slot Holiday', d::date, d::date from fri;
select pg_temp.say(pg_temp.chk(pg_temp.gen(:'T1', t.id('to')::text, pg_temp.lday(30), pg_temp.lday(43)), 'ok', 'create 14 days of lessons for my slots')) as g1 \gset
select t.ok(:'g1'::jsonb->>'created' = '11' and :'g1'::jsonb->>'skipped' = '0' and :'g1'::jsonb->>'holidays' = '1' and :'g1'::jsonb->>'ended' = '2' and :'g1'::jsonb->>'not_assigned' = '2'
        and :'g1'::jsonb->>'too_soon' = '0' and :'g1'::jsonb->>'awaiting_centre' = '2' and :'g1'::jsonb->>'slots' = '8',
        'created 11 (Fay 1 + Ann 4 + Eve 2 + the group 4), the holiday Friday skipped, the ended student and the unassigned student skipped, Eve''s 2 wait for the centre');
select t.ok((select count(*) = 1 from lessons where student_id = :'F' and slot_id = t.id('S_F') and lesson_date between pg_temp.lday(30) and pg_temp.lday(43))
        and not exists (select 1 from lessons l join fri on l.lesson_date = fri.d where l.student_id = :'F'), 'Fay: one Friday, the holiday Friday has none');
select t.ok((select count(*) = 0 from lessons where student_id in (:'D', :'C') and lesson_date between pg_temp.lday(30) and pg_temp.lday(43)), 'nothing for the ended student or the student not assigned to me');
select t.ok((select count(*) = 0 from lessons where student_id = :'B' and lesson_date between pg_temp.lday(30) and pg_temp.lday(43)), 'nothing for tutor two''s slot');
select t.ok((select bool_and(rate = 40 and amount = 40 and subject = 'English' and slot_id = t.id('S_F') and slot_date = lesson_date and not one_off and status = 'scheduled' and not paid and taught_by = t.id('m1')
                              and created_by_tutor = t.id('m1') and changed_by_tutor_at is null and not price_pending and session_id is null and tutor_id = :'OWNER')
               from lessons where student_id = :'F' and slot_id = t.id('S_F')), 'a generated lesson copies the slot (rate, subject, key), is NOT flagged "changed by tutor", and is not a one-off');
select t.ok((select bool_and(price_pending and rate = 0 and amount = 0) and count(*) = 2 from lessons where student_id = :'E' and slot_id = t.id('SE2')), 'Eve''s two lessons wait for the centre (her slot waits)');
select t.ok((select count(distinct session_id) = 2 and count(*) = 4 and bool_and(session_id is not null and rate = 25) from lessons where student_id in (:'H', :'I') and lesson_date between pg_temp.lday(30) and pg_temp.lday(43)),
        'the group class made 2 days x 2 students with ONE shared session id per day');
select t.ok((select bool_and(session_id = md5('00000000-0000-0000-0000-000000a70301' || lesson_date::text)::uuid) from lessons where student_id in (:'H', :'I') and lesson_date between pg_temp.lday(30) and pg_temp.lday(43)), '...the same id staff''s generator gives (so they never double up)');
select t.ok((select count(*) = 1 from audit_log where action = 'tutor_generate_lessons' and actor = :'T1' and (after->>'created')::int = 11), 'one audit row for the press, with the numbers');
-- pressed twice: nothing more
select pg_temp.say(pg_temp.chk(pg_temp.gen(:'T1', t.id('to')::text, pg_temp.lday(30), pg_temp.lday(43)), 'ok', 'press it again')) as g2 \gset
select t.ok(:'g2'::jsonb->>'created' = '0' and :'g2'::jsonb->>'skipped' = '11' and :'g2'::jsonb->>'ended' = '2', 'the second press creates nothing: 11 already there');
select t.ok((select count(*) = 11 from lessons where created_by_tutor = t.id('m1') and slot_id is not null and lesson_date between pg_temp.lday(30) and pg_temp.lday(43)), 'still 11 lessons');
-- staff pressing the same range makes nothing twice for tutor one, only for the others
select pg_temp.say(pg_temp.call(:'STAFF', format('select staff_generate_lessons(%L, %L, %L)', t.id('to'), pg_temp.lday(30), pg_temp.lday(43)))) as g3 \gset
select t.ok((select count(*) = 11 from lessons where taught_by = t.id('m1') and slot_id is not null and student_id <> :'C' and lesson_date between pg_temp.lday(30) and pg_temp.lday(43)), 'after staff pressed: tutor one still has exactly their 11 (staff''s own button, which ignores "assigned", added Cal''s two)');
select t.ok((select count(*) = 2 from lessons where student_id = :'B' and lesson_date between pg_temp.lday(30) and pg_temp.lday(43)), 'staff''s press made tutor two''s 2 lessons');
select pg_temp.say(pg_temp.chk(pg_temp.gen(:'T2', t.id('to')::text, pg_temp.lday(30), pg_temp.lday(43)), 'ok', 'tutor two presses the same range')) as g4 \gset
select t.ok(:'g4'::jsonb->>'created' = '0' and :'g4'::jsonb->>'skipped' = '2', 'tutor two: staff already made them, nothing twice');
-- the other order: a tutor first, then staff
select pg_temp.say(pg_temp.chk(pg_temp.gen(:'T2', t.id('to')::text, pg_temp.lday(60), pg_temp.lday(73)), 'ok', 'tutor two first, in a fresh range')) as g5 \gset
select t.ok(:'g5'::jsonb->>'created' = '2' and :'g5'::jsonb->>'slots' = '1', 'tutor two made their 2 (and only theirs)');
select pg_temp.call(:'STAFF', format('select staff_generate_lessons(%L, %L, %L)', t.id('to'), pg_temp.lday(60), pg_temp.lday(73))) as g6 \gset
select t.ok((select count(*) >= 2 and bool_and(price_pending and rate = 0) from lessons where student_id = :'E' and slot_id = t.id('SE2') and created_by_tutor is null and lesson_date between pg_temp.lday(60) and pg_temp.lday(73)),
        'STAFF''s own button, pressed on a slot that waits for its price, makes lessons that wait too (a trigger: staff''s function knows nothing of the flag)');
select t.ok((select count(*) = 2 from lessons where student_id = :'B' and lesson_date between pg_temp.lday(60) and pg_temp.lday(73)), 'then staff pressed: tutor two''s lessons are not doubled');
-- and a tutor's press never reaches into another tutor's slots
select pg_temp.chk(pg_temp.gen(:'T1', t.id('to')::text, pg_temp.lday(80), pg_temp.lday(86)), 'ok', 'tutor one, a fresh week');
select t.ok((select count(*) = 0 from lessons where student_id = :'B' and lesson_date between pg_temp.lday(80) and pg_temp.lday(86)), 'tutor two''s slot made nothing');
-- the range rules
select pg_temp.chk(pg_temp.gen(:'T1', t.id('to')::text, pg_temp.lday(-1), pg_temp.lday(3)), 'BAD_RANGE', 'starts yesterday');
select pg_temp.chk(pg_temp.gen(:'T1', t.id('to')::text, pg_temp.lday(5), pg_temp.lday(4)), 'BAD_RANGE', 'ends before it starts');
select pg_temp.chk(pg_temp.gen(:'T1', t.id('to')::text, pg_temp.lday(5), pg_temp.lday(68)), 'BAD_RANGE', '64 days (63 days apart) is too many');
select pg_temp.chk(pg_temp.gen(:'T1', t.id('to')::text, pg_temp.lday(5), pg_temp.lday(67)), 'ok', 'exactly the maximum (62 days apart)');
select t.ok(pg_temp.call(:'T1', format('select tutor_generate_lessons(%L)', t.id('to')))::jsonb->>'from' = pg_temp.lday(0)::text
        and pg_temp.call(:'T1', format('select tutor_generate_lessons(%L)', t.id('to')))::jsonb->>'to' = pg_temp.lday(27)::text, 'no dates: from the centre''s today, four weeks');
-- holidays: with skipping switched off the holiday Friday gets its lesson, and says so
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":true,"weekly_slots":true,"generate":true},"min_notice_hours":24}', '{"skip_holidays":false}');
select pg_temp.say(pg_temp.chk(pg_temp.gen(:'T1', t.id('to')::text, pg_temp.lday(30), pg_temp.lday(43)), 'ok', 'skip_holidays off: the same range again')) as g7 \gset
select t.ok(:'g7'::jsonb->>'created' = '1' and :'g7'::jsonb->>'holidays' = '0', 'one more lesson: the holiday Friday, which the centre chose not to skip');
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":true,"weekly_slots":true,"generate":true},"min_notice_hours":24}');
-- the notice: tutor five has a slot 2 hours from now and one 2 hours ago, both today (the clock of this centre is mid-day)
insert into recurring_slots(tutor_id, org_id, student_id, weekday, start_time, end_time, rate, active, taught_by) values
  (:'OWNER', t.id('to'), :'Z', extract(isodow from pg_temp.lday(0))::int - 1, pg_temp.ltime(2), pg_temp.ltime(2) + interval '1 hour', 30, true, t.id('m5')),
  (:'OWNER', t.id('to'), :'Z', extract(isodow from pg_temp.lday(0))::int - 1, pg_temp.ltime(-3), pg_temp.ltime(-3) + interval '1 hour', 30, true, t.id('m5'));
select pg_temp.say(pg_temp.chk(pg_temp.gen(:'T5', t.id('to')::text, pg_temp.lday(0), pg_temp.lday(0)), 'ok', 'notice 24: today only')) as g8 \gset
select t.ok(:'g8'::jsonb->>'created' = '0' and :'g8'::jsonb->>'too_soon' = '2', 'both lessons start inside the notice (one already passed): none made, both counted as too soon');
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":true,"weekly_slots":true,"generate":true},"min_notice_hours":0}');
select pg_temp.say(pg_temp.chk(pg_temp.gen(:'T5', t.id('to')::text, pg_temp.lday(0), pg_temp.lday(0)), 'ok', 'notice 0: today only')) as g9 \gset
select t.ok(:'g9'::jsonb->>'created' = '1' and :'g9'::jsonb->>'too_soon' = '1', 'notice 0: the lesson 2 hours ahead is made, the one that already started never is');
select t.ok(pg_temp.gen(:'T5', t.id('to')::text, pg_temp.lday(0), pg_temp.lday(0))::jsonb->>'created' = '0', 'and pressing again makes nothing');
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":true,"weekly_slots":true,"generate":true,"postpone":true,"cancel":true},"min_notice_hours":24}');

-- ===================================================================== 7. the invoice run holds a waiting lesson back, and lets it go once the centre confirms
create function pg_temp.preview(p_month date) returns jsonb language plpgsql as $$
declare r text := pg_temp.call('00000000-0000-0000-0000-000000a70001', format('select centre_invoice_run_preview(%L, %L)', (select v from t.ids where k = 'to'), p_month));
begin
  if r like 'ERR:%' then raise exception 'FAIL: the invoice preview was refused (%)', r; end if;
  return r::jsonb;
end $$;
-- two lessons Eve's tutor adds in NEXT month (the invoice run looks at most two months ahead)
select (date_trunc('month', pg_temp.lday(0)) + interval '1 month')::date as nm \gset
select pg_temp.say(pg_temp.chk(pg_temp.addl(:'T1', :'E', :'nm'::date + 20, '19:00', '20:00'), 'ok', 'Eve: a lesson next month')) as ep1 \gset
select pg_temp.say(pg_temp.chk(pg_temp.addl(:'T1', :'E', :'nm'::date + 20, '20:30', '21:30'), 'ok', 'Eve: another lesson next month')) as ep2 \gset
select pg_temp.keep('EP1', :'ep1', 'lesson_id'); select pg_temp.keep('EP2', :'ep2', 'lesson_id');
select pg_temp.preview(:'nm'::date) as pv \gset
select t.ok(exists (select 1 from jsonb_array_elements(:'pv'::jsonb->'held_back') e where e->>'name' like 'Eve%'
                      and e->'reasons'->0->>'reason' like 'charge pending: Eve%'), 'the invoice run holds Eve''s family back: "charge pending: Eve"');
select t.ok(not exists (select 1 from jsonb_array_elements(:'pv'::jsonb->'held_back') e where e->>'name' like 'Ann%' or e->>'name' like 'Fay%'), 'Ann and Fay (price copied from staff) are not held back');
-- a lesson the tutor cancels is not waiting for a price any more
select pg_temp.say(pg_temp.chk(pg_temp.call(:'T1', format('select tutor_cancel_lesson(%L, ''student is unwell'')', t.id('EP1'))), 'ok', 'tutor cancels one of Eve''s waiting lessons (step 2 on a tutor-made lesson)'));
select t.ok((pg_temp.lk(t.id('EP1'))).status = 'cancelled' and (pg_temp.lk(t.id('EP1'))).compensation = 0 and (pg_temp.lk(t.id('EP1'))).created_by_tutor = t.id('m1') and (pg_temp.lk(t.id('EP1'))).changed_by_tutor_what = 'cancelled',
        'it is cancelled with charge 0, still marked as made by the tutor, now flagged "cancelled"');
select pg_temp.preview(:'nm'::date) as pv2 \gset
select t.ok(exists (select 1 from jsonb_array_elements(:'pv2'::jsonb->'held_back') e where e->>'name' like 'Eve%' and e->'lessons' @> jsonb_build_array(jsonb_build_object('lesson_id', t.id('EP2')))) and not exists (
              select 1 from jsonb_array_elements(:'pv2'::jsonb->'held_back') e, jsonb_array_elements(e->'lessons') l where l->>'lesson_id' = t.id('EP1')::text),
        'Eve is still held back for her OTHER lesson; the cancelled one is not what holds her back');
select pg_temp.say(pg_temp.chk(pg_temp.call(:'T1', format('select tutor_postpone_lesson(%L, %L, ''14:00''::time, ''prep clash'')', (select id from lessons where student_id = :'E' and lesson_date = pg_temp.lday(101) and start_time = '12:00'), pg_temp.lday(102))), 'ok', 'a tutor moves a lesson they made (step 2 works on it)'));
-- staff confirm the price: one lesson, then the student's others
select pg_temp.chk(pg_temp.call(:'T1', format('select staff_set_lesson_price(%L, %L, 20)', t.id('to'), t.id('E1'))), 'NOT_FOUND', 'a tutor can''t confirm a price (NOT_FOUND)');
select pg_temp.chk(pg_temp.call(:'STAFF', format('select staff_set_lesson_price(%L, %L, 20)', t.id('to'), t.id('E1'))), 'NOT_ALLOWED', 'staff who only manage the timetable can''t either');
select pg_temp.chk(pg_temp.call('00000000-0000-0000-0000-000000a70008', format('select staff_set_lesson_price(%L, %L, 20)', t.id('to'), t.id('E1'))), 'NOT_FOUND', 'a parent can''t');
select pg_temp.chk(pg_temp.call(:'SOLO', format('select staff_set_lesson_price(%L, %L, 20)', t.id('to'), t.id('E1'))), 'NOT_FOUND', 'a solo tutor can''t');
select pg_temp.chk(pg_temp.call(:'MONEY', format('select staff_set_lesson_price(%L, %L, -1)', t.id('to'), t.id('E1'))), 'BAD_RATE', 'a negative rate');
select pg_temp.chk(pg_temp.call(:'MONEY', format('select staff_set_lesson_price(%L, %L, 1000.01)', t.id('to'), t.id('E1'))), 'BAD_RATE', 'over 1000');
select pg_temp.chk(pg_temp.call(:'MONEY', format('select staff_set_lesson_price(%L, %L, null)', t.id('to'), t.id('E1'))), 'BAD_RATE', 'no rate');
select pg_temp.chk(pg_temp.call(:'MONEY', format('select staff_set_lesson_price(%L, %L, 20)', t.id('to2'), t.id('E1'))), 'NOT_FOUND', 'another centre''s id');
select pg_temp.chk(pg_temp.call(:'MONEY', format('select staff_set_lesson_price(%L, %L, 20)', t.id('to'), t.id('F1'))), 'NOT_WAITING', 'a lesson whose price is already confirmed');
select pg_temp.call(:'MONEY', format('select staff_set_lesson_price(%L, %L, 20)', t.id('to'), t.id('EP2'))) as sp1 \gset
select t.ok(:'sp1'::jsonb->>'lessons' = '1' and :'sp1'::jsonb->>'slots' = '0', 'one lesson confirmed; the slot and the other lessons still wait');
select t.ok((pg_temp.lk(t.id('EP2'))).rate = 20 and (pg_temp.lk(t.id('EP2'))).amount = 20 and not (pg_temp.lk(t.id('EP2'))).price_pending, 'that lesson: rate 20, an hour = 20, nothing waiting');
select t.ok((select count(*) > 1 from lessons where student_id = :'E' and price_pending), 'the others still wait');
update lessons set paid = true where student_id = :'E' and lesson_date = pg_temp.lday(102) and start_time = '14:00';
select pg_temp.call(:'MONEY', format('select staff_set_lesson_price(%L, %L, 25, true)', t.id('to'), (select id from lessons where student_id = :'E' and price_pending and not paid order by lesson_date limit 1))) as sp2 \gset
select t.ok((:'sp2'::jsonb->>'lessons')::int >= 3 and :'sp2'::jsonb->>'slots' = '2', 'for the whole student: the rest of the waiting lessons and both waiting slots (the stopped one too)');
select t.ok((select count(*) = 1 from lessons where student_id = :'E' and price_pending and paid and lesson_date = pg_temp.lday(102)), 'a lesson already paid was not touched');
select t.ok((select rate = 25 and not price_pending from recurring_slots where id = t.id('SE2')), 'the slot has the rate, so lessons made later are not waiting');
select t.ok((select count(*) >= 2 from audit_log where action = 'staff_set_lesson_price' and actor in (:'MONEY')), 'both confirmations are audited');
update lessons set paid = false where student_id = :'E';
select pg_temp.preview(:'nm'::date) as pv3 \gset
select t.ok(not exists (select 1 from jsonb_array_elements(:'pv3'::jsonb->'held_back') e where e->>'name' like 'Eve%'), 'once the centre confirmed, Eve''s family is no longer held back');
-- once the centre has confirmed a price (and staff's own button made lessons at it), a new tutor lesson copies THAT: the latest staff-made row
select pg_temp.say(pg_temp.chk(pg_temp.addl(:'T1', :'E', pg_temp.lday(130), '10:00', '11:00'), 'ok', 'Eve: another lesson after the centre confirmed her price')) as e3 \gset
select pg_temp.keep('E3', :'e3', 'lesson_id');
select t.ok(not (pg_temp.lk(t.id('E3'))).price_pending and (pg_temp.lk(t.id('E3'))).rate = 25, 'it copies the confirmed 25 per hour from the latest staff-made row, and does not wait');
-- a price of 0 is a real answer (a free lesson) and clears the flag too
insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, taught_by, created_by_tutor, price_pending)
  values (:'OWNER', t.id('to'), :'E', pg_temp.lday(132), '10:00', '11:00', 0, 0, 'scheduled', t.id('m1'), t.id('m1'), true);
select pg_temp.call(:'OWNER', format('select staff_set_lesson_price(%L, %L, 0)', t.id('to'), (select id from lessons where student_id = :'E' and lesson_date = pg_temp.lday(132)))) as sp3 \gset
select t.ok((select not price_pending and rate = 0 and amount = 0 from lessons where student_id = :'E' and lesson_date = pg_temp.lday(132)), 'a rate of 0 is accepted and clears the flag');
-- typing a price straight into the row also clears it (the trigger); 0 does not
insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, price_pending) values (:'OWNER', t.id('to'), :'E', pg_temp.lday(131), '10:00', '11:00', 0, 0, 'scheduled', true);
update lessons set rate = 0 where student_id = :'E' and lesson_date = pg_temp.lday(131);
select t.ok((select price_pending from lessons where student_id = :'E' and lesson_date = pg_temp.lday(131)), 'a row edit that leaves the rate at 0 keeps it waiting');
update lessons set rate = 18 where student_id = :'E' and lesson_date = pg_temp.lday(131);
select t.ok((select not price_pending from lessons where student_id = :'E' and lesson_date = pg_temp.lday(131)), 'a real rate typed into the row clears it');

-- ===================================================================== 8. what staff see
create function pg_temp.chg(p_user text) returns jsonb language sql as $$ select pg_temp.call(p_user, format('select staff_tutor_changes(%L)', (select v from t.ids where k = 'to')))::jsonb $$;
insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, taught_by, created_by_tutor, price_pending, changed_by_tutor_at, changed_by_tutor, changed_by_tutor_what)
  values (:'OWNER', t.id('to'), :'E', pg_temp.lday(140), '10:00', '11:00', 0, 0, 'scheduled', t.id('m1'), t.id('m1'), true, now(), t.id('m1'), 'added');   -- a waiting lesson, as a tutor's add makes it
select pg_temp.chg(:'STAFF') as ch \gset
select t.ok(exists (select 1 from jsonb_array_elements(:'ch'::jsonb->'rows') e where e->>'kind' = 'lesson' and e->>'what' = 'added' and e->>'lesson_id' = t.id('A1')::text and e->>'tutor_name' = 'Tutor One'
                      and e->>'student_name' = 'Ann' and e->>'awaiting_centre' = 'false'), 'a lesson a tutor ADDED is on the list (kind lesson, what added)');
select t.ok(exists (select 1 from jsonb_array_elements(:'ch'::jsonb->'rows') e where e->>'kind' = 'lesson' and e->>'what' = 'cancelled' and e->>'lesson_id' = t.id('EP1')::text), 'a cancel of it shows as cancelled');
select t.ok(exists (select 1 from jsonb_array_elements(:'ch'::jsonb->'rows') e where e->>'kind' = 'lesson' and e->>'what' = 'added' and e->>'awaiting_centre' = 'true' and e->>'student_name' like 'Eve%'), 'a lesson whose details the centre must confirm says so');
select t.ok(exists (select 1 from jsonb_array_elements(:'ch'::jsonb->'rows') e where e->>'kind' = 'slot' and e->>'what' = 'added' and e->>'slot_id' = t.id('SA1')::text and e->>'weekday' = '2' and e->>'student_name' = 'Ann'), 'a weekly slot a tutor added is on the list');
select t.ok(exists (select 1 from jsonb_array_elements(:'ch'::jsonb->'rows') e where e->>'kind' = 'slot' and e->>'what' = 'stopped' and e->>'slot_id' = t.id('SE1')::text), '...and one a tutor stopped');
select t.ok(exists (select 1 from jsonb_array_elements(:'ch'::jsonb->'rows') e where e->>'kind' = 'run' and e->>'what' = 'generated' and e->>'tutor_name' = 'Tutor One' and (e->>'created')::int = 11 and e->>'from_date' = pg_temp.lday(30)::text),
        'a "Create lessons" press that made lessons is one line (11 lessons, from when)');
select t.ok(not exists (select 1 from jsonb_array_elements(:'ch'::jsonb->'rows') e where e->>'kind' = 'run' and (e->>'created')::int = 0), 'a press that made nothing is not listed');
select t.ok(not exists (select 1 from jsonb_array_elements(:'ch'::jsonb->'rows') e where e->>'kind' = 'lesson' and e->>'lesson_id' in (select l.id::text from lessons l where l.slot_id is not null and l.changed_by_tutor_at is null)),
        'lessons made by a press are not each flagged (one line per press instead)');
select t.ok((select array_agg((e->>'changed_at')::timestamptz order by ord) = array_agg((e->>'changed_at')::timestamptz order by (e->>'changed_at')::timestamptz desc, ord)
               from jsonb_array_elements(:'ch'::jsonb->'rows') with ordinality x(e, ord)), 'newest first');
select t.ok(not exists (select 1 from pg_temp.keys(:'ch'::jsonb) k where k ~* '(rate|price|amount|paid|compens|charge|fee|cents|cost|balance|invoice)'), 'no key of the staff list is a money word');
select t.ok(:'ch'::text !~ '(777\.77|555\.55|388\.89)', 'no marker price appears in the staff list either');
select pg_temp.chk(pg_temp.call(:'MONEY', format('select staff_tutor_changes(%L)', t.id('to'))), 'NOT_ALLOWED', 'staff who only issue invoices don''t see timetable changes');
select pg_temp.chk(pg_temp.call(:'T1', format('select staff_tutor_changes(%L)', t.id('to'))), 'NOT_FOUND', 'a tutor never sees the list');
select pg_temp.chk(pg_temp.call('00000000-0000-0000-0000-000000a70009', format('select staff_tutor_changes(%L)', t.id('to'))), 'NOT_FOUND', 'another centre''s owner gets nothing of this centre');
select jsonb_array_length(pg_temp.call('00000000-0000-0000-0000-000000a70009', format('select staff_tutor_changes(%L)', t.id('to2')))::jsonb->'rows') = 0 as empty \gset
select t.ok(:'empty', 'the other centre''s own list is empty');
-- only the last 7 days; a switched-off tutor is "Former tutor"
select set_config('request.jwt.claims', '', false);
update recurring_slots set changed_by_tutor_at = now() - interval '8 days' where id = t.id('SA2');
update recurring_slots set changed_by_tutor_at = now() - interval '6 days 23 hours' where id = t.id('SA1');
select pg_temp.chg(:'STAFF') as ch2 \gset
select t.ok(not exists (select 1 from jsonb_array_elements(:'ch2'::jsonb->'rows') e where e->>'slot_id' = t.id('SA2')::text) and exists (select 1 from jsonb_array_elements(:'ch2'::jsonb->'rows') e where e->>'slot_id' = t.id('SA1')::text),
        'a slot change older than 7 days is gone; 6 days 23 hours ago is still there');
update memberships set status = 'disabled' where id = t.id('m1');
select pg_temp.chg(:'STAFF') as ch3 \gset
select t.ok(exists (select 1 from jsonb_array_elements(:'ch3'::jsonb->'rows') e where e->>'kind' = 'run' and e->>'tutor_name' = 'Former tutor') and exists (select 1 from jsonb_array_elements(:'ch3'::jsonb->'rows') e where e->>'kind' = 'slot' and e->>'tutor_name' = 'Former tutor'),
        'after the tutor is switched off their lessons, slots and presses read "Former tutor"');
update memberships set status = 'active' where id = t.id('m1');

-- ===================================================================== 9. the reads
create function pg_temp.sch(p_user text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  set local role authenticated;
  select tutor_my_schedule(pg_temp.lday(95), pg_temp.lday(135)) into r;
  reset role;
  return r;
end $$;
create function pg_temp.slots(p_user text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  set local role authenticated;
  select jsonb_agg(to_jsonb(s)) into r from tutor_my_slots() s;
  reset role;
  return coalesce(r, '[]'::jsonb);
end $$;
select pg_temp.sch(:'T1') as sc \gset
select t.ok((:'sc'::jsonb #>> '{orgs,0,can_one_off}') = 'true' and (:'sc'::jsonb #>> '{orgs,0,can_slots}') = 'true' and (:'sc'::jsonb #>> '{orgs,0,can_generate}') = 'true'
        and (:'sc'::jsonb #>> '{orgs,0,can_postpone}') = 'true' and (:'sc'::jsonb #>> '{orgs,0,can_cancel}') = 'true', 'the schedule says which of the new buttons this centre allows');
select t.ok(exists (select 1 from jsonb_array_elements(:'sc'::jsonb->'lessons') e where e->>'lesson_id' = t.id('A1')::text and e->>'added_by_you' = 'true' and e->>'awaiting_centre' = 'false')
        and exists (select 1 from jsonb_array_elements(:'sc'::jsonb->'lessons') e where e->>'student_name' like 'Eve%' and e->>'awaiting_centre' = 'true'), 'a lesson I added says so; one the centre must confirm says so');
select t.ok(not exists (select 1 from jsonb_array_elements(:'sc'::jsonb->'lessons') e where e->>'student_name' = 'Ben'), 'tutor two''s lessons are not on my schedule');
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":true}}');
select pg_temp.sch(:'T1') as sc2 \gset
select t.ok((:'sc2'::jsonb #>> '{orgs,0,can_one_off}') = 'true' and (:'sc2'::jsonb #>> '{orgs,0,can_slots}') = 'false' and (:'sc2'::jsonb #>> '{orgs,0,can_generate}') = 'false', 'with only one_off on, only that button is offered');
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"admin_only","tutors_edit":{"one_off":true,"weekly_slots":true,"generate":true}}');
select pg_temp.sch(:'T1') as sc3 \gset
select t.ok((:'sc3'::jsonb #>> '{orgs,0,can_one_off}') = 'false' and (:'sc3'::jsonb #>> '{orgs,0,can_slots}') = 'false' and (:'sc3'::jsonb #>> '{orgs,0,can_generate}') = 'false', 'admin_only: no new button even with the switches on');
select pg_temp.slots(:'T1') as sl3 \gset
select t.ok(not exists (select 1 from jsonb_array_elements(:'sl3'::jsonb) e where e->>'can_change' = 'true'), 'admin_only: no slot can be changed');
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":true,"weekly_slots":true,"generate":true}}');
select pg_temp.slots(:'T1') as sl1 \gset
select t.ok(exists (select 1 from jsonb_array_elements(:'sl1'::jsonb) e where e->>'slot_id' = t.id('SA1')::text and e->>'can_change' = 'true' and e->>'is_group' = 'false' and e->>'awaiting_centre' = 'false'), 'my own slot: can be changed');
select t.ok(exists (select 1 from jsonb_array_elements(:'sl1'::jsonb) e where e->>'slot_id' = t.id('S_H')::text and e->>'can_change' = 'false' and e->>'is_group' = 'true'), 'a staff group class: shown, but not changeable');
select t.ok(exists (select 1 from jsonb_array_elements(:'sl1'::jsonb) e where e->>'slot_id' = t.id('SE2')::text and e->>'awaiting_centre' = 'false'), 'Eve''s slot is no longer waiting after the centre confirmed her price');
select t.ok(not exists (select 1 from jsonb_array_elements(:'sl1'::jsonb) e where e->>'slot_id' = t.id('SE1')::text), 'a stopped slot is not listed');
select t.ok(not exists (select 1 from jsonb_array_elements(:'sl1'::jsonb) e where e->>'slot_id' = t.id('S_B')::text), 'tutor two''s slot is not listed');
select set_config('request.jwt.claims', '', false);
insert into students(id, tutor_id, org_id, name, level, contact) values ('00000000-0000-0000-0000-000000a7010c', :'OWNER', t.id('to'), 'Nia (no history)', 'P2', '91110012');
insert into student_tutors(org_id, student_id, membership_id) values (t.id('to'), '00000000-0000-0000-0000-000000a7010c', t.id('m1'));
select pg_temp.call(:'T1', 'select tutor_my_students()') as ms \gset
select t.ok((select array_agg(e->>'name' order by e->>'name') = array['Ann','Eve (new, no price yet)','Fay','Hal (group)','Ivy (group)','Nia (no history)'] from jsonb_array_elements(:'ms'::jsonb) e),
        'my students: the assigned, active ones only (not Ben, Cal, Zed; not Dee, whose lessons ended)');
select t.ok((select bool_and((e->>'awaiting_centre')::boolean = (e->>'name' like 'Nia%')) from jsonb_array_elements(:'ms'::jsonb) e) and (select e->>'subject' from jsonb_array_elements(:'ms'::jsonb) e where e->>'name' = 'Fay') = 'English',
        'only Nia (nothing to copy; Eve''s price was confirmed by the centre) waits for the centre; Fay''s subject is suggested');
select t.ok((select jsonb_array_length(pg_temp.call(:'T2', 'select tutor_my_students()')::jsonb) = 1), 'tutor two sees only Ben');
select t.ok(not exists (select 1 from pg_temp.keys(:'ms'::jsonb) k where k ~* '(rate|price|amount|paid|compens|charge|fee|cents|cost|balance|invoice|contact)') and :'ms'::text !~ '(777\.77|555\.55|9111)', 'the student list has no money word and no phone number');

-- ===================================================================== 10. no money anywhere a tutor can read; no table access; functions locked down
select t.ok(not exists (select 1 from pg_temp.said s, lateral pg_temp.keys(case when s.txt like '{%' then s.txt::jsonb else '{}'::jsonb end) k where k ~* '(rate|price|amount|paid|compens|charge|fee|cents|cost|fare|owe|balance|invoice)'),
        'no key of any answer a tutor received is a money word');
select t.ok(not exists (select 1 from pg_temp.said s where s.txt ~ '(777\.77|555\.55|388\.89|SECRET)'), 'the marker prices appear in no answer a tutor received');
select t.ok((select count(*) from pg_temp.said) >= 15, 'and there were answers to check (' || (select count(*) from pg_temp.said) || ')');
select t.ok(not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace
          and p.proname in ('tutor_my_students', 'tutor_add_lesson', 'tutor_save_slot', 'tutor_stop_slot', 'tutor_generate_lessons', 'tutor_my_schedule', 'tutor_my_slots', 'staff_tutor_changes', 'tutor_own_gate', 'tutor_own_limit_check', 'tutor_changes_used')
          and pg_get_functiondef(p.oid) ~* '\m(rate|price|amount|paid|compensation|charge_note|charge|fee|cost|invoice[a-z]*|[a-z_]*_cents)\M'), 'no money word in the text of any function a tutor calls, the staff list or the gate');
select t.ok(not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace
          and p.proname in ('tutor_my_students', 'tutor_add_lesson', 'tutor_save_slot', 'tutor_stop_slot', 'tutor_generate_lessons', 'tutor_my_schedule', 'tutor_my_slots', 'staff_tutor_changes', 'tutor_own_gate')
          and pg_get_functiondef(p.oid) ~ '\m[a-z]+\.\*'), 'none of them selects a whole row (x.*)');
select t.ok((select count(*) = 4 from pg_proc p where p.proname in ('tutor_basis_for', 'tutor_own_insert_lesson', 'tutor_own_insert_slot', 'tutor_own_generate')
              and pg_get_functiondef(p.oid) ~* '\m(rate|price)\M'), 'the money lives only in the four internal helpers');
select t.ok(not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prorettype = 'record'::regtype and p.proname in ('tutor_add_lesson', 'tutor_save_slot', 'tutor_stop_slot', 'tutor_generate_lessons', 'tutor_my_students')),
        'the new functions return only jsonb (no typed row that could grow a money column)');
select t.ok((select count(*) = 17 and bool_and(p.prosecdef and p.proconfig::text like '%search_path=public%') from pg_proc p
              where p.pronamespace = 'public'::regnamespace and p.proname in ('tutor_my_students', 'tutor_add_lesson', 'tutor_save_slot', 'tutor_stop_slot', 'tutor_generate_lessons', 'tutor_my_schedule', 'tutor_my_slots', 'staff_tutor_changes',
                  'staff_set_lesson_price', 'tutor_own_gate', 'tutor_own_limit_check', 'tutor_changes_used', 'tutor_basis_for', 'tutor_own_insert_lesson', 'tutor_own_insert_slot', 'tutor_own_generate', 'tutor_change_block')),
        'all seventeen are SECURITY DEFINER with a pinned search_path');
select t.ok(has_function_privilege('authenticated', 'tutor_my_students()', 'execute') and has_function_privilege('authenticated', 'tutor_add_lesson(uuid,date,time,time,text,text)', 'execute')
        and has_function_privilege('authenticated', 'tutor_save_slot(uuid,uuid,int,time,time,text)', 'execute') and has_function_privilege('authenticated', 'tutor_stop_slot(uuid)', 'execute')
        and has_function_privilege('authenticated', 'tutor_generate_lessons(uuid,date,date)', 'execute') and has_function_privilege('authenticated', 'staff_set_lesson_price(uuid,uuid,numeric,boolean)', 'execute')
        and not has_function_privilege('anon', 'tutor_add_lesson(uuid,date,time,time,text,text)', 'execute') and not has_function_privilege('anon', 'tutor_save_slot(uuid,uuid,int,time,time,text)', 'execute')
        and not has_function_privilege('anon', 'tutor_stop_slot(uuid)', 'execute') and not has_function_privilege('anon', 'tutor_generate_lessons(uuid,date,date)', 'execute')
        and not has_function_privilege('anon', 'tutor_my_students()', 'execute') and not has_function_privilege('anon', 'staff_set_lesson_price(uuid,uuid,numeric,boolean)', 'execute'), 'signed-in users may call the public ones; anonymous may not');
select t.ok(not has_function_privilege('authenticated', 'tutor_own_gate(uuid,uuid,text)', 'execute') and not has_function_privilege('authenticated', 'tutor_own_limit_check(uuid,jsonb)', 'execute')
        and not has_function_privilege('authenticated', 'tutor_changes_used(uuid,uuid,text)', 'execute') and not has_function_privilege('authenticated', 'tutor_basis_for(uuid,uuid)', 'execute')
        and not has_function_privilege('authenticated', 'tutor_own_insert_lesson(uuid,uuid,uuid,date,time,time,text,text)', 'execute')
        and not has_function_privilege('authenticated', 'tutor_own_insert_slot(uuid,uuid,uuid,int,time,time,text)', 'execute')
        and not has_function_privilege('authenticated', 'tutor_own_generate(uuid,uuid,date,date,boolean,int,text)', 'execute')
        and not has_function_privilege('authenticated', 'centre_invoice_run_rows(uuid,date,date)', 'execute') and not has_function_privilege('anon', 'tutor_basis_for(uuid,uuid)', 'execute'),
        'the gate, the limit check and the money helpers can''t be called from the browser (no way to skip a check or insert a price)');
select pg_temp.settings('to', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"one_off":true,"weekly_slots":true,"generate":true}}');
select pg_temp.call(:'T1', $q$ select count(*)::text from recurring_slots $q$) as n \gset
select t.ok(:'n' = '0' or :'n' like 'ERR:%', 'a tutor reads no row of recurring_slots');
select t.ok(pg_temp.call(:'T1', format($q$ insert into recurring_slots(tutor_id, org_id, student_id, weekday, start_time, end_time, rate, taught_by) values (%L, %L, %L, 1, '10:00', '11:00', 1, %L) $q$, :'T1', t.id('to'), :'A', t.id('m1'))) like 'ERR:%', 'a tutor cannot INSERT a slot directly');
select pg_temp.call(:'T1', format($q$ with u as (update recurring_slots set active = false where id = %L returning 1) select count(*)::text from u $q$, t.id('SA1'))) as n \gset
select t.ok(:'n' = '0' or :'n' like 'ERR:%', 'a tutor cannot UPDATE a slot directly (not even their own)');
select pg_temp.call(:'T1', format($q$ with u as (update lessons set price_pending = false, rate = 99 where id = %L returning 1) select count(*)::text from u $q$, t.id('E3'))) as n \gset
select t.ok(:'n' = '0' or :'n' like 'ERR:%', 'a tutor cannot set a lesson''s price or its waiting flag');
select t.ok(pg_temp.call(:'T1', format($q$ insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, taught_by) values (%L, %L, %L, current_date + 400, '10:00', '11:00', 1, %L) $q$, :'T1', t.id('to'), :'A', t.id('m1'))) like 'ERR:%', 'a tutor cannot INSERT a lesson directly');
select pg_temp.call(:'T1', $q$ with u as (update student_tutors set active = false returning 1) select count(*)::text from u $q$) as n \gset
select t.ok(:'n' = '0' or :'n' like 'ERR:%', 'a tutor cannot change who is assigned to them');
-- the invoice run on a month with no waiting lesson is unchanged in shape (the one patched function still answers), and the audit trigger saw the tutor's slot rows
select t.ok((select count(*) >= 1 from audit_log where table_name = 'recurring_slots' and action = 'insert' and (after->>'created_by_tutor') = t.id('m1')::text), 'the slots table audit trigger logged the tutor-made slot too');
select t.ok((select count(*) = 0 from lessons l join organisations o on o.id = l.org_id where o.kind = 'solo' and (l.created_by_tutor is not null or l.price_pending)), 'no solo organisation''s lesson was touched');
select pg_temp.call(:'SOLO', format('select staff_tutor_changes(%L)', t.id('to'))) like 'ERR:NOT_FOUND%' as solo_nf \gset
select t.ok(:'solo_nf', 'a solo tutor reads nothing of this centre');
