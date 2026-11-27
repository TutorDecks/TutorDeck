-- T3.9 tests: stop a weekly slot from a day, add / remove a student on a slot, auto-assigned tutors, lessons up to 26 weeks,
-- cancelling the lessons on a holiday, the People list. Runs LAST (after payout_permission_test.sql) in the same throwaway database and
-- reuses the t.* helpers. Builds its own centre and made-up people. Never touches a real project.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000c001', 'sc.owner@centre.test'),   ('00000000-0000-0000-0000-00000000c002', 'sc.staff@centre.test'),
  ('00000000-0000-0000-0000-00000000c003', 'sc.desk@centre.test'),    ('00000000-0000-0000-0000-00000000c004', 'sc.tutor1@centre.test'),
  ('00000000-0000-0000-0000-00000000c005', 'sc.tutor2@centre.test'),  ('00000000-0000-0000-0000-00000000c006', 'sc.hr@centre.test'),
  ('00000000-0000-0000-0000-00000000c007', 'sc.outsider@centre.test'),('00000000-0000-0000-0000-00000000c009', 'sc.owner2@centre.test'),
  ('00000000-0000-0000-0000-00000000c00a', 'sc.off@centre.test');
set role authenticated; select t.as('00000000-0000-0000-0000-00000000c001');
select t.put('sc', org_create_centre('Changes Centre', t.centre_settings()));
select t.as('00000000-0000-0000-0000-00000000c009');
select t.put('sc2', org_create_centre('Other Changes Centre', t.centre_settings()));
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('sc'), '00000000-0000-0000-0000-00000000c002', 'Staff Sam',  'staff', array['manage_timetable'], 'active'),
  (t.id('sc'), '00000000-0000-0000-0000-00000000c003', 'Front Desk', 'staff', array['manage_students'], 'active'),
  (t.id('sc'), '00000000-0000-0000-0000-00000000c006', 'People Pat', 'staff', array['manage_tutors'], 'active'),
  (t.id('sc'), '00000000-0000-0000-0000-00000000c004', 'Tutor One',  'tutor', '{}', 'active'),
  (t.id('sc'), '00000000-0000-0000-0000-00000000c005', 'Tutor Two',  'tutor', '{}', 'active'),
  (t.id('sc'), '00000000-0000-0000-0000-00000000c00a', 'Switched off', 'tutor', '{}', 'disabled');
insert into memberships(org_id, user_id, display_name, role, status, invited_email) values (t.id('sc'), null, 'Waiting Wen', 'tutor', 'invited', 'wen@private.test');
select t.put('m1', (select id from memberships where org_id = t.id('sc') and user_id = '00000000-0000-0000-0000-00000000c004'));
select t.put('m2', (select id from memberships where org_id = t.id('sc') and user_id = '00000000-0000-0000-0000-00000000c005'));
select t.put('mwen', (select id from memberships where org_id = t.id('sc') and display_name = 'Waiting Wen'));
select t.put('owner_m', (select id from memberships where org_id = t.id('sc') and role = 'owner'));

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today, (extract(isodow from (now() at time zone 'Asia/Singapore')::date)::int - 1) as wd;
grant select on td to authenticated, anon;
create temp table stu (k text primary key, id uuid);
insert into stu select 'k' || g, gen_random_uuid() from generate_series(1, 12) g;
grant select on stu to authenticated;
insert into students(id, tutor_id, org_id, name, level) select id, '00000000-0000-0000-0000-00000000c001', t.id('sc'), 'Kid ' || k, 'P' || (right(k, 1)) from stu;
update students set end_date = (select today - 5 from td) where id = (select id from stu where k = 'k12');
create function pg_temp.sid(p_k text) returns uuid language sql as $$ select id from stu where k = p_k $$;
create function pg_temp.slot_of(p_k text) returns uuid language sql as $$ select (array_agg(id order by active desc, created_at))[1] from recurring_slots where student_id = (select id from stu where k = p_k) $$;
create function pg_temp.refused(p_user text, p_sql text, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  begin execute p_sql; exception when others then m := sqlerrm; end;
  if m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS refused: % (%)', p_msg, m;
end $$;
-- a day N days from today that falls on the weekday W of the weekly slot, at least N days away
create function pg_temp.dow(p_wd int, p_min int) returns date language sql as $$
  select (select today from td) + p_min + (((p_wd - ((select wd from td) + p_min)) % 7) + 7) % 7 $$;
select ((select wd from td) + 3) % 7 as wa, ((select wd from td) + 4) % 7 as wb, ((select wd from td) + 5) % 7 as wc, ((select wd from td) + 2) % 7 as wd2 \gset

-- ===================================================================== 3. AUTO-ASSIGNED TUTORS
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_save_slot(t.id('sc'), null, array[pg_temp.sid('k1')], :wa, '10:00', '11:00', t.id('m1'), 'Math', 50) as a1 \gset
reset role;
select t.ok(jsonb_array_length(:'a1'::jsonb->'assigned') = 1 and :'a1'::jsonb->'assigned'->0->>'tutor_name' = 'Tutor One' and :'a1'::jsonb->'assigned'->0->>'student_name' = 'Kid k1',
            'a new slot with a tutor adds the tutor to the student''s assigned tutors, and the answer says who');
select t.eq((select count(*) from student_tutors where student_id = pg_temp.sid('k1') and membership_id = t.id('m1') and active), 1, 'the assigned-tutor row exists and is active');
select t.ok((select created_by = '00000000-0000-0000-0000-00000000c002' and since = (select today from td) from student_tutors where student_id = pg_temp.sid('k1') and membership_id = t.id('m1')), 'it records who and when');
select t.ok(exists (select 1 from audit_log where org_id = t.id('sc') and action = 'staff_auto_assign_tutor'), 'the automatic assignment is audited');
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_save_slot(t.id('sc'), null, array[pg_temp.sid('k1')], :wc, '10:00', '11:00', t.id('m1'), 'Science', 50) as a2 \gset
reset role;
select t.ok(jsonb_array_length(:'a2'::jsonb->'assigned') = 0, 'a tutor who is already assigned is not added twice, and nothing is said');
select t.eq((select count(*) from student_tutors where student_id = pg_temp.sid('k1') and membership_id = t.id('m1')), 1, 'still one row for the pair');
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_save_slot(t.id('sc'), null, array[pg_temp.sid('k1')], :wd2, '10:00', '11:00', t.id('m2'), 'English', 50) as a3 \gset
reset role;
select t.ok((select count(*) = 2 from student_tutors where student_id = pg_temp.sid('k1') and active), 'a second tutor is ADDED: nobody is ever removed');
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_save_slot(t.id('sc'), null, array[pg_temp.sid('k2')], :wa, '12:00', '13:00', null, 'Math', 50) as a4 \gset
reset role;
select t.ok(jsonb_array_length(:'a4'::jsonb->'assigned') = 0 and not exists (select 1 from student_tutors where student_id = pg_temp.sid('k2')), 'a slot with no tutor assigns nobody');
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_save_slot(t.id('sc'), null, array[pg_temp.sid('k3'), pg_temp.sid('k4')], :wb, '14:00', '15:00', t.id('m1'), 'Math', 50) as a5 \gset
reset role;
select t.ok(jsonb_array_length(:'a5'::jsonb->'assigned') = 2 and (select count(*) = 2 from student_tutors where membership_id = t.id('m1') and student_id in (pg_temp.sid('k3'), pg_temp.sid('k4')) and active),
            'a class adds the tutor to every student of the class');
-- changing an existing slot's tutor is not "creating a slot": it does not assign
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select (staff_slots(t.id('sc'), null, 'k2')->'rows'->0->>'slot_id')::uuid as k2slot \gset
select staff_save_slot(t.id('sc'), :'k2slot'::uuid, null, :wa, '12:00', '13:00', t.id('m2'), 'Math', null) as a6 \gset
reset role;
select t.ok(not exists (select 1 from student_tutors where student_id = pg_temp.sid('k2')), 'changing a slot''s tutor does not touch assigned tutors');
-- the centre can switch it off (a setting, default on); a value that is not a yes/no counts as the default (on)
select t.as('00000000-0000-0000-0000-00000000c001'); set role authenticated;
select org_save_settings(t.id('sc'), jsonb_set(t.centre_settings(), '{lessons}', '{"auto_assign_tutors": false}'), (select today from td));
select t.as('00000000-0000-0000-0000-00000000c002');
select staff_save_slot(t.id('sc'), null, array[pg_temp.sid('k5')], :wa, '16:00', '17:00', t.id('m2'), 'Math', 50) as a7 \gset
reset role;
select t.ok(jsonb_array_length(:'a7'::jsonb->'assigned') = 0 and not exists (select 1 from student_tutors where student_id = pg_temp.sid('k5')), 'setting OFF: the slot is made and nobody is assigned');
select t.as('00000000-0000-0000-0000-00000000c001'); set role authenticated;
select org_save_settings(t.id('sc'), jsonb_set(t.centre_settings(), '{lessons}', '{"auto_assign_tutors": "maybe"}'), (select today from td));
select t.as('00000000-0000-0000-0000-00000000c002');
select staff_save_slot(t.id('sc'), null, array[pg_temp.sid('k6')], :wa, '16:00', '17:00', t.id('m2'), 'Math', 50) as a8 \gset
reset role;
select t.ok(jsonb_array_length(:'a8'::jsonb->'assigned') = 1, 'a setting that is not a yes/no counts as the default: on');
select t.as('00000000-0000-0000-0000-00000000c001'); set role authenticated;
select org_save_settings(t.id('sc'), jsonb_set(t.centre_settings(), '{lessons}', '{"auto_assign_tutors": true}'), (select today from td));
reset role;

-- ===================================================================== 4. LESSONS UP TO 26 WEEKS
-- (k5's slot is on weekday wa; its tutor is Tutor Two.) A holiday on one of its days inside the range is skipped.
select pg_temp.dow(:wa, 70) as holday \gset
select set_config('request.jwt.claims', '', false);
insert into holidays(org_id, name, starts_on, ends_on) values (t.id('sc'), 'Long range holiday', :'holday'::date, :'holday'::date);
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_generate_lessons(t.id('sc'), (select today from td), (select today + 181 from td)) as g1 \gset
reset role;
select t.eq((:'g1'::jsonb->>'days')::int, 182, 'the answer says how many days were covered (26 weeks)');
select t.eq((select count(*) from lessons where student_id = pg_temp.sid('k5') and slot_id is not null), 25, '26 weeks make 26 lessons for a weekly slot, minus the one on the holiday');
select t.eq((:'g1'::jsonb->>'holidays')::int, 1, 'one holiday day was skipped');
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_generate_lessons(t.id('sc'), (select today from td), (select today + 181 from td)) as g2 \gset
reset role;
select t.ok((:'g2'::jsonb->>'created')::int = 0 and (:'g2'::jsonb->>'skipped')::int > 0, 'pressing it again creates nothing: still idempotent over 26 weeks');
select pg_temp.refused('00000000-0000-0000-0000-00000000c002', format('set role authenticated; select staff_generate_lessons(%L, %L, %L)', t.id('sc'), (select today from td), (select today + 182 from td)), 'BAD_RANGE', 'more than 26 weeks is refused');
reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c002', format('set role authenticated; select staff_generate_lessons(%L, %L, %L)', t.id('sc'), (select today + 3 from td), (select today + 2 from td)), 'BAD_RANGE', 'an end before the start is refused');
reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c002', format('set role authenticated; select staff_generate_lessons(%L, %L, %L)', t.id('sc'), (select today - 2 from td), (select today + 20 from td)), 'BAD_RANGE', 'a start in the past is refused');
reset role;
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select (staff_generate_lessons(t.id('sc'))->>'days')::int as dflt \gset
reset role;
select t.eq(:dflt, 28, 'with no dates it is still the next 4 weeks');
-- every weekly lesson of the centre's other slots was created too; no slot ran outside its dates
select t.ok(not exists (select 1 from lessons l where l.org_id = t.id('sc') and l.slot_id is not null and l.lesson_date < (select today from td)), 'nothing was created in the past');

-- ===================================================================== 1. STOP A WEEKLY SLOT FROM A DAY
-- k6's slot: lessons for 26 weeks exist (made above for every slot). Give the lessons of the stop window every kind of state.
select pg_temp.slot_of('k6') as k6slot \gset
select pg_temp.dow(:wa, 14) as d14 \gset
create temp table k6l as select l.id, l.lesson_date, row_number() over (order by l.lesson_date) as n from lessons l
  where l.student_id = pg_temp.sid('k6') and l.slot_id = :'k6slot'::uuid and l.lesson_date >= :'d14'::date order by l.lesson_date limit 8;
select count(*) as k6n from lessons where slot_id = :'k6slot'::uuid \gset
select t.eq((select count(*) from k6l), 8, 'eight lessons of the slot are in the window');
select set_config('request.jwt.claims', '', false);   -- the test acts as the database owner here (the attendance guard only watches signed-in people)
update lessons set attendance = 'attended' where id = (select id from k6l where n = 1);                       -- MARKED
select set_config('request.jwt.claims', '', false);
update lessons set paid = true where id = (select id from k6l where n = 2);                                    -- PAID
select set_config('request.jwt.claims', '', false);
insert into invoices(tutor_id, org_id, student_id, invoice_no, total, data) values
  ('00000000-0000-0000-0000-00000000c001', t.id('sc'), pg_temp.sid('k6'), 'SC-1', 50, jsonb_build_object('lesson_ids', jsonb_build_array((select id::text from k6l where n = 3))));   -- INVOICED (solo-style)
select set_config('request.jwt.claims', '', false);
insert into centre_invoices(id, org_id, kind) values ('00000000-0000-0000-0000-00000000c1a1', t.id('sc'), 'lesson');
insert into centre_invoice_lines(org_id, invoice_id, lesson_id, description, qty, unit_cents) values (t.id('sc'), '00000000-0000-0000-0000-00000000c1a1', (select id from k6l where n = 4), 'Maths lesson', 1, 5000);   -- INVOICED (centre)
select set_config('request.jwt.claims', '', false);
update lessons set status = 'cancelled' where id = (select id from k6l where n = 5);                          -- already cancelled
select t.eq((select count(*) from k6l where lesson_change_blocker((select id from k6l k where k.n = k6l.n)) is null), 3, 'the helper sees exactly 3 free lessons of the 8 (marked, paid, 2 invoiced, cancelled are not free)');
-- who may
select pg_temp.refused('00000000-0000-0000-0000-00000000c003', format('set role authenticated; select staff_stop_slot_from(%L, %L, %L)', t.id('sc'), :'k6slot', :'d14'), 'NOT_ALLOWED', 'front desk (no manage_timetable) cannot stop a slot'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c004', format('set role authenticated; select staff_stop_slot_from(%L, %L, %L)', t.id('sc'), :'k6slot', :'d14'), 'NOT_FOUND', 'a tutor cannot'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c007', format('set role authenticated; select staff_stop_slot_from(%L, %L, %L)', t.id('sc'), :'k6slot', :'d14'), 'NOT_FOUND', 'a stranger cannot'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c009', format('set role authenticated; select staff_stop_slot_from(%L, %L, %L)', t.id('sc'), :'k6slot', :'d14'), 'NOT_FOUND', 'the owner of ANOTHER centre cannot'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-0000000000a1', format('set role authenticated; select staff_stop_slot_from(%L, %L, %L)', t.id('sc'), :'k6slot', :'d14'), 'NOT_FOUND', 'a solo tutor cannot'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c002', format('set role authenticated; select staff_stop_slot_from(%L, %L, %L)', t.id('sc2'), :'k6slot', :'d14'), 'NOT_FOUND', 'a slot of another centre is not found even for an authorised person elsewhere'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c002', format('set role authenticated; select staff_stop_slot_from(%L, %L, %L)', t.id('sc'), :'k6slot', (select today - 1 from td)), 'BAD_DATE', 'a day in the past is refused'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c002', format('set role authenticated; select staff_stop_slot_from(%L, %L, null)', t.id('sc'), :'k6slot'), 'BAD_DATE', 'no day is refused'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c002', format('set role authenticated; select staff_stop_slot_from(%L, %L, %L)', t.id('sc'), :'k6slot', (select today + 1200 from td)), 'BAD_DATE', 'more than three years ahead is refused'); reset role;
-- the preview counts, changing nothing
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_stop_slot_from(t.id('sc'), :'k6slot'::uuid, :'d14'::date, true, true) as sd1 \gset
reset role;
select t.ok((:'sd1'::jsonb->>'dry')::boolean and (:'sd1'::jsonb->>'removable')::int >= 3 and (:'sd1'::jsonb->>'kept')::int = 4, 'the preview says how many would go (not marked, paid or invoiced) and how many stay (marked, paid, 2 invoiced)');
select t.ok((select stopped_from is null and active from recurring_slots where id = :'k6slot'::uuid), 'a preview changes nothing');
select t.eq((select count(*) from lessons where slot_id = :'k6slot'::uuid), :k6n, 'no lesson was removed by the preview');
-- stop WITHOUT the tick-box: the slot ends on that day, lessons stay
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_stop_slot_from(t.id('sc'), :'k6slot'::uuid, :'d14'::date) as sd2 \gset
reset role;
select t.ok((:'sd2'::jsonb->>'stopped')::int = 1 and (:'sd2'::jsonb->>'removed')::int = 0, 'stopped from a future day, nothing removed');
select t.ok((select stopped_from = :'d14'::date and active from recurring_slots where id = :'k6slot'::uuid), 'the slot is still active until its stop day, with the stop day stored');
select t.eq((select count(*) from lessons where slot_id = :'k6slot'::uuid), :k6n, 'lessons stay without the tick-box');
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select (staff_slots(t.id('sc'), null, 'Kid k6')->'rows'->0->>'stops_on')::date as shown \gset
reset role;
select t.ok(:'shown'::date = :'d14'::date, 'the slot list says when it stops');
-- the generator makes no lesson from the stop day on (a fresh slot with no lessons yet, stopped from today + 21)
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_save_slot(t.id('sc'), null, array[pg_temp.sid('k11')], :wb, '22:00', '23:00', null, 'Math', 45) as g3 \gset
reset role;
select pg_temp.slot_of('k11') as k11slot \gset
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_stop_slot_from(t.id('sc'), :'k11slot'::uuid, (select today + 21 from td)) as g4 \gset
select staff_generate_lessons(t.id('sc'), (select today from td), (select today + 100 from td)) as g5 \gset
reset role;
select t.ok(exists (select 1 from lessons where student_id = pg_temp.sid('k11') and slot_id = :'k11slot'::uuid), 'lessons are made up to the stop day');
select t.ok(not exists (select 1 from lessons where student_id = pg_temp.sid('k11') and slot_id = :'k11slot'::uuid and lesson_date >= (select today + 21 from td)), 'and none from the stop day on, even when asked for 100 days');
select t.eq((select count(*) from lessons where student_id = pg_temp.sid('k11') and slot_id = :'k11slot'::uuid), 3, 'three weekly lessons before the stop day 21 days away');
-- stop again, WITH the tick-box: only the free lessons go
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_stop_slot_from(t.id('sc'), :'k6slot'::uuid, :'d14'::date, true) as sd4 \gset
reset role;
select t.ok((:'sd4'::jsonb->>'removed')::int >= 3 and (:'sd4'::jsonb->>'kept')::int = 4, 'with the tick-box the free lessons are removed; marked, paid and both invoiced stay');
select t.ok((select count(*) = 5 from lessons where slot_id = :'k6slot'::uuid and lesson_date >= :'d14'::date), 'what is left from the stop day: marked, paid, invoiced twice, and the cancelled one');
select t.ok(exists (select 1 from lessons where id = (select id from k6l where n = 1) and attendance = 'attended') and exists (select 1 from lessons where id = (select id from k6l where n = 2) and paid)
        and exists (select 1 from lessons where id = (select id from k6l where n = 3)) and exists (select 1 from lessons where id = (select id from k6l where n = 4)), 'the marked, paid and invoiced lessons were not touched');
select t.ok(exists (select 1 from lessons where slot_id = :'k6slot'::uuid and lesson_date < :'d14'::date), 'lessons before the stop day are untouched');
select t.ok(exists (select 1 from audit_log where org_id = t.id('sc') and action = 'staff_stop_slot_from' and (after->>'lessons_removed')::int >= 3), 'the removal is audited with the count');
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_stop_slot_from(t.id('sc'), :'k6slot'::uuid, :'d14'::date, true) as sd5 \gset
reset role;
select t.ok((:'sd5'::jsonb->>'stopped')::int = 0 and (:'sd5'::jsonb->>'removed')::int = 0, 'pressing it again changes nothing (idempotent)');
-- a stop day of today switches the slot off at once and it leaves the list; lessons in the past are never touched
select set_config('request.jwt.claims', '', false);
insert into lessons(tutor_id, org_id, student_id, slot_id, lesson_date, slot_date, start_time, end_time, rate, amount, status, taught_by)
  values ('00000000-0000-0000-0000-00000000c001', t.id('sc'), pg_temp.sid('k5'), pg_temp.slot_of('k5'), (select today - 3 from td), (select today - 3 from td), '16:00', '17:00', 50, 50, 'scheduled', t.id('m2'));
select pg_temp.slot_of('k5') as k5slot \gset
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_stop_slot_from(t.id('sc'), :'k5slot'::uuid, (select today from td), true) as sd6 \gset
select (staff_slots(t.id('sc'), null, 'Kid k5')->>'total')::int as k5total \gset
reset role;
select t.ok(not (select active from recurring_slots where id = :'k5slot'::uuid), 'a stop day of today switches the slot off now');
select t.eq(:k5total, 0, 'and it leaves the list of weekly slots');
select t.ok(exists (select 1 from lessons where slot_id = :'k5slot'::uuid and lesson_date = (select today - 3 from td)), 'a lesson in the past is never removed');
select t.ok(not exists (select 1 from lessons where slot_id = :'k5slot'::uuid and lesson_date >= (select today from td) and attendance is null and not paid), 'the later free lessons are gone');
-- a class: stopping one member's slot stops the whole class
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select (staff_slots(t.id('sc'), null, 'Kid k3')->'rows'->0->>'slot_id')::uuid as clsslot \gset
select staff_stop_slot_from(t.id('sc'), :'clsslot'::uuid, (select today + 60 from td)) as sd7 \gset
reset role;
select t.eq((:'sd7'::jsonb->>'stopped')::int, 2, 'a class: both students'' slots stop together');
select t.eq((select count(*) from recurring_slots where student_id in (pg_temp.sid('k3'), pg_temp.sid('k4')) and stopped_from = (select today + 60 from td)), 2, 'both rows carry the stop day');
-- a tutor's own weekly slots follow the stop day too
select t.as('00000000-0000-0000-0000-00000000c004'); set role authenticated;
select count(*) as tslots_before from tutor_my_slots() where student_name = 'Kid k3' \gset
reset role;
select t.eq(:tslots_before, 1, 'the tutor still sees a slot whose stop day is to come');
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_stop_slot_from(t.id('sc'), :'clsslot'::uuid, (select today from td)) as sd8 \gset
reset role;
select t.as('00000000-0000-0000-0000-00000000c004'); set role authenticated;
select count(*) as tslots_after from tutor_my_slots() where student_name in ('Kid k3', 'Kid k4') \gset
reset role;
select t.eq(:tslots_after, 0, 'and not once it has stopped');

-- ===================================================================== 2. ADD / REMOVE A STUDENT ON AN EXISTING SLOT
-- a fresh single slot for k7 with Tutor Two, lessons for 6 weeks
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_save_slot(t.id('sc'), null, array[pg_temp.sid('k7')], :wc, '18:00', '19:00', t.id('m2'), 'Math', 45) as b1 \gset
select staff_generate_lessons(t.id('sc'), (select today from td), (select today + 41 from td)) as b2 \gset
reset role;
select pg_temp.slot_of('k7') as k7slot \gset
select t.ok((select count(*) = 6 from lessons where student_id = pg_temp.sid('k7') and slot_id = :'k7slot'::uuid), 'k7 has 6 weekly lessons');
-- who may
select pg_temp.refused('00000000-0000-0000-0000-00000000c003', format('set role authenticated; select staff_slot_student(%L, %L, %L, ''add'')', t.id('sc'), :'k7slot', pg_temp.sid('k8')), 'NOT_ALLOWED', 'front desk cannot add a student to a slot'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c004', format('set role authenticated; select staff_slot_student(%L, %L, %L, ''add'')', t.id('sc'), :'k7slot', pg_temp.sid('k8')), 'NOT_FOUND', 'a tutor cannot'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c009', format('set role authenticated; select staff_slot_student(%L, %L, %L, ''add'')', t.id('sc'), :'k7slot', pg_temp.sid('k8')), 'NOT_FOUND', 'another centre''s owner cannot'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c002', format('set role authenticated; select staff_slot_student(%L, %L, %L, ''swap'')', t.id('sc'), :'k7slot', pg_temp.sid('k8')), 'BAD_ACTION', 'an unknown action is refused'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c002', format('set role authenticated; select staff_slot_student(%L, %L, %L, ''add'', %L)', t.id('sc'), :'k7slot', pg_temp.sid('k8'), (select today - 1 from td)), 'BAD_DATE', 'a day in the past is refused'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c002', format('set role authenticated; select staff_slot_student(%L, %L, gen_random_uuid(), ''add'')', t.id('sc'), :'k7slot'), 'NOT_FOUND', 'an unknown student is refused'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c002', format('set role authenticated; select staff_slot_student(%L, %L, %L, ''add'')', t.id('sc'), :'k7slot', pg_temp.sid('k12')), 'STUDENT_ENDED', 'a student whose lessons have ended is refused'); reset role;
select set_config('request.jwt.claims', '', false);
insert into students(id, tutor_id, org_id, name, level) values ('00000000-0000-0000-0000-00000000c9f1', '00000000-0000-0000-0000-00000000c009', t.id('sc2'), 'Kid elsewhere', 'P1');
select pg_temp.refused('00000000-0000-0000-0000-00000000c002', format('set role authenticated; select staff_slot_student(%L, %L, %L, ''add'')', t.id('sc'), :'k7slot', '00000000-0000-0000-0000-00000000c9f1'::uuid), 'NOT_FOUND', 'a student of ANOTHER centre is refused'); reset role;
-- a student with a clashing weekly lesson at that time: k1 has weekday wc 10:00-11:00 (Science); a slot at 10:30 would clash
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_save_slot(t.id('sc'), null, array[pg_temp.sid('k9')], :wc, '10:30', '11:30', null, 'Math', 45) as b3 \gset
reset role;
select pg_temp.slot_of('k9') as k9slot \gset
select pg_temp.refused('00000000-0000-0000-0000-00000000c002', format('set role authenticated; select staff_slot_student(%L, %L, %L, ''add'')', t.id('sc'), :'k9slot', pg_temp.sid('k1')), 'SLOT_CLASH', 'a student who already has a weekly lesson at that time is refused'); reset role;
-- mark one of k7's lessons first, so we can see it is left alone
select set_config('request.jwt.claims', '', false);   -- the test acts as the database owner here (the attendance guard only watches signed-in people)
select set_config('request.jwt.claims', '', false);
update lessons set attendance = 'attended' where id = (select id from lessons where student_id = pg_temp.sid('k7') and slot_id = :'k7slot'::uuid order by lesson_date limit 1);
select lesson_date as marked_day from lessons where student_id = pg_temp.sid('k7') and attendance = 'attended' and slot_id = :'k7slot'::uuid \gset
-- the preview
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_slot_student(t.id('sc'), :'k7slot'::uuid, pg_temp.sid('k8'), 'add', null, true) as ad0 \gset
reset role;
select t.ok((:'ad0'::jsonb->>'dry')::boolean and (:'ad0'::jsonb->>'would_create')::int = 6 and not exists (select 1 from recurring_slots where student_id = pg_temp.sid('k8')), 'the preview of an add counts lessons and changes nothing');
-- add k8 to the single slot from today: it becomes a class of two
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_slot_student(t.id('sc'), :'k7slot'::uuid, pg_temp.sid('k8'), 'add') as ad1 \gset
reset role;
select t.ok((:'ad1'::jsonb->>'added')::int = 1 and (:'ad1'::jsonb->>'created')::int = 6 and (:'ad1'::jsonb->>'students')::int = 2, 'k8 joined: 6 lessons made for them, a class of 2');
select t.ok((select count(distinct session_key) = 1 and bool_and(session_key is not null) from recurring_slots where student_id in (pg_temp.sid('k7'), pg_temp.sid('k8')) and active), 'both rows now share one session key (the existing group design)');
select t.ok((select weekday = :wc and start_time = '18:00' and end_time = '19:00' and rate = 45 and taught_by = t.id('m2') and subject = 'Math' from recurring_slots where student_id = pg_temp.sid('k8') and active), 'the new row has the slot''s day, time, rate, subject and tutor');
select t.ok((select count(*) = 5 from lessons a join lessons b on b.student_id = pg_temp.sid('k8') and b.lesson_date = a.lesson_date and b.session_id = a.session_id
                 where a.student_id = pg_temp.sid('k7') and a.session_id is not null), 'on the 5 days k7 had not been marked, the two students share one session id');
select t.ok((select session_id is null from lessons where student_id = pg_temp.sid('k7') and lesson_date = :'marked_day'::date and slot_id = :'k7slot'::uuid), 'the already-marked lesson was left exactly as it was');
select t.ok(exists (select 1 from student_tutors where student_id = pg_temp.sid('k8') and membership_id = t.id('m2') and active) and jsonb_array_length(:'ad1'::jsonb->'assigned') = 1, 'the slot''s tutor joined k8''s assigned tutors and the answer says so');
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_slot_student(t.id('sc'), :'k7slot'::uuid, pg_temp.sid('k8'), 'add') as ad2 \gset
reset role;
select t.ok((:'ad2'::jsonb->>'already')::boolean and (:'ad2'::jsonb->>'added')::int = 0, 'adding the same student again does nothing');
select t.eq((select count(*) from lessons where student_id = pg_temp.sid('k8')), 6, 'and creates no extra lessons');
select t.eq((select count(*) from recurring_slots where student_id = pg_temp.sid('k8')), 1, 'nor a second row');
-- generating again does not duplicate; a student added from a later day only gets lessons from then
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_generate_lessons(t.id('sc'), (select today from td), (select today + 41 from td)) as ad3 \gset
select staff_slot_student(t.id('sc'), :'k7slot'::uuid, pg_temp.sid('k10'), 'add', (select today + 14 from td)) as ad4 \gset
reset role;
select t.ok((select count(*) = 6 from lessons where student_id = pg_temp.sid('k8')) and (select count(*) = 6 from lessons where student_id = pg_temp.sid('k7')), 'creating lessons again after an add makes nothing twice for the class (the 6 new ones are k9''s own slot)');
select t.ok((select min(lesson_date) >= (select today + 14 from td) and count(*) > 0 from lessons where student_id = pg_temp.sid('k10')), 'a student added from a later day gets lessons only from that day');
select t.ok((select starts_on = (select today + 14 from td) from recurring_slots where student_id = pg_temp.sid('k10') and active), 'and their row remembers the day they start');
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_generate_lessons(t.id('sc'), (select today from td), (select today + 60 from td)) as ad5 \gset
reset role;
select t.ok(not exists (select 1 from lessons where student_id = pg_temp.sid('k10') and lesson_date < (select today + 14 from td)), 'the generator honours the start day too');
-- remove: the preview, then the removal from a day
select count(*) as k8n from lessons where student_id = pg_temp.sid('k8') \gset
select count(*) as k7n from lessons where student_id = pg_temp.sid('k7') \gset
select count(*) as k8late from lessons where student_id = pg_temp.sid('k8') and lesson_date >= (select today + 14 from td) \gset
select count(*) as k8early from lessons where student_id = pg_temp.sid('k8') and lesson_date < (select today + 14 from td) \gset
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_slot_student(t.id('sc'), :'k7slot'::uuid, pg_temp.sid('k8'), 'remove', (select today + 14 from td), true) as rm0 \gset
reset role;
select t.ok((:'rm0'::jsonb->>'dry')::boolean and (:'rm0'::jsonb->>'removable')::int = :k8late and (:'rm0'::jsonb->>'kept')::int = 0, 'the preview of a removal says how many lessons would go');
select t.eq((select count(*) from lessons where student_id = pg_temp.sid('k8')), :k8n, 'the preview removed nothing');
select set_config('request.jwt.claims', '', false);
update lessons set paid = true where id = (select id from lessons where student_id = pg_temp.sid('k8') order by lesson_date desc limit 1);
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_slot_student(t.id('sc'), :'k7slot'::uuid, pg_temp.sid('k8'), 'remove', (select today + 14 from td)) as rm1 \gset
reset role;
select t.ok((:'rm1'::jsonb->>'removed')::int = 1 and (:'rm1'::jsonb->>'lessons_removed')::int = :k8late - 1 and (:'rm1'::jsonb->>'kept')::int = 1, 'removed from a day: free later lessons go, the paid one stays');
select t.eq((select count(*) from lessons where student_id = pg_temp.sid('k8') and lesson_date < (select today + 14 from td)), :k8early, 'k8''s earlier lessons stay');
select t.ok((select stopped_from = (select today + 14 from td) and active from recurring_slots where student_id = pg_temp.sid('k8') and stopped_from is not null), 'their row stops on that day');
select t.eq((select count(*) from lessons where student_id = pg_temp.sid('k7') and slot_id = :'k7slot'::uuid), :k7n, 'k7 still has all their lessons');
select t.ok(exists (select 1 from student_tutors where student_id = pg_temp.sid('k8') and membership_id = t.id('m2') and active), 'nobody is taken off the assigned tutors');
select t.ok(exists (select 1 from audit_log where org_id = t.id('sc') and action = 'staff_slot_student_remove') and exists (select 1 from audit_log where org_id = t.id('sc') and action = 'staff_slot_student_add'), 'add and remove are audited');
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_slot_student(t.id('sc'), :'k7slot'::uuid, pg_temp.sid('k8'), 'remove', (select today + 14 from td)) as rm2 \gset
reset role;
select t.eq((:'rm2'::jsonb->>'lessons_removed')::int, 0, 'removing again removes no further lessons (idempotent)');
-- the last student of a slot cannot be removed
select pg_temp.refused('00000000-0000-0000-0000-00000000c002', format('set role authenticated; select staff_slot_student(%L, %L, %L, ''remove'')', t.id('sc'), :'k9slot', pg_temp.sid('k9')), 'BAD_STUDENTS', 'the only student of a slot can''t be removed (stop the slot instead)'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c002', format('set role authenticated; select staff_slot_student(%L, %L, %L, ''remove'')', t.id('sc'), :'k7slot', pg_temp.sid('k9')), 'NOT_FOUND', 'a student who is not in the slot is not found'); reset role;
-- a class of 30 is full
select set_config('request.jwt.claims', '', false);
insert into students(id, tutor_id, org_id, name) select gen_random_uuid(), '00000000-0000-0000-0000-00000000c001', t.id('sc'), 'Full ' || g from generate_series(1, 30) g;
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_save_slot(t.id('sc'), null, (select array_agg(id) from (select id from students where name like 'Full %' order by name limit 30) z), :wb, '20:00', '21:00', null, 'Math', 40) as full1 \gset
reset role;
select (select (array_agg(id))[1] from recurring_slots where student_id = (select id from students where name = 'Full 1') and active) as fullslot \gset
select pg_temp.refused('00000000-0000-0000-0000-00000000c002', format('set role authenticated; select staff_slot_student(%L, %L, %L, ''add'')', t.id('sc'), :'fullslot', pg_temp.sid('k11')), 'BAD_STUDENTS', 'a class has at most 30 students'); reset role;
-- adding to a stopped slot is refused
select pg_temp.refused('00000000-0000-0000-0000-00000000c002', format('set role authenticated; select staff_slot_student(%L, %L, %L, ''add'')', t.id('sc'), :'k5slot', pg_temp.sid('k11')), 'NOT_FOUND', 'a slot that has stopped can''t take a new student'); reset role;

-- ===================================================================== 5. HOLIDAYS: CANCEL THE LESSONS ALREADY ON THE DAY
select pg_temp.dow(:wc, 21) as hd \gset
-- lessons on that day: k7 (slot wc 18:00), k8 (until stop day), k1 (wc 10:00), and k5 (stopped). Protect k1's with a mark and k7's with a payment.
select set_config('request.jwt.claims', '', false);   -- the test acts as the database owner here (the attendance guard only watches signed-in people)
select set_config('request.jwt.claims', '', false);
update lessons set attendance = 'attended' where student_id = pg_temp.sid('k1') and lesson_date = :'hd'::date;
select set_config('request.jwt.claims', '', false);
update lessons set paid = true where student_id = pg_temp.sid('k7') and lesson_date = :'hd'::date;
select count(*) as on_day from lessons where org_id = t.id('sc') and lesson_date = :'hd'::date \gset
select t.ok(:on_day >= 3, 'there are lessons on the holiday''s day');
select count(*) filter (where lesson_change_blocker(id) is null) as free_on_day, count(*) filter (where lesson_change_blocker(id) in ('MARKED', 'PAID', 'INVOICED')) as kept_on_day from lessons where org_id = t.id('sc') and lesson_date = :'hd'::date \gset
-- who may
select pg_temp.refused('00000000-0000-0000-0000-00000000c003', format('set role authenticated; select staff_holiday_cancel(%L, %L, %L)', t.id('sc'), :'hd', :'hd'), 'NOT_ALLOWED', 'front desk cannot'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c004', format('set role authenticated; select staff_holiday_cancel(%L, %L, %L)', t.id('sc'), :'hd', :'hd'), 'NOT_FOUND', 'a tutor cannot'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c009', format('set role authenticated; select staff_holiday_cancel(%L, %L, %L)', t.id('sc'), :'hd', :'hd'), 'NOT_FOUND', 'another centre''s owner cannot'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c002', format('set role authenticated; select staff_holiday_cancel(%L, %L, %L)', t.id('sc'), :'hd', (select today from td)), 'BAD_RANGE', 'an end before the start is refused'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c002', format('set role authenticated; select staff_holiday_cancel(%L, %L, %L)', t.id('sc'), (select today from td), (select today + 400 from td)), 'BAD_RANGE', 'more than a year is refused'); reset role;
-- the default is a preview
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_holiday_cancel(t.id('sc'), :'hd'::date, :'hd'::date, 'Founders Day') as hc0 \gset
reset role;
select t.ok((:'hc0'::jsonb->>'dry')::boolean and (:'hc0'::jsonb->>'cancel')::int = :free_on_day and (:'hc0'::jsonb->>'kept')::int = :kept_on_day, 'with no 5th argument it only counts (free lessons and kept ones)');
select t.eq((select count(*) from lessons where org_id = t.id('sc') and lesson_date = :'hd'::date and status = 'cancelled'), 0, 'and cancels nothing');
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_holiday_cancel(t.id('sc'), :'hd'::date, :'hd'::date, 'Founders Day', false) as hc1 \gset
reset role;
select t.ok((:'hc1'::jsonb->>'cancel')::int = :free_on_day and not (:'hc1'::jsonb->>'dry')::boolean, 'the free lessons were cancelled');
select t.ok((select bool_and(status = 'cancelled' and compensation = 0 and amount = 0 and attendance is null and charge_note = 'Holiday: Founders Day') from lessons where id in (select id from lessons where org_id = t.id('sc') and lesson_date = :'hd'::date and charge_note = 'Holiday: Founders Day')), 'cancelled with NO charge (compensation 0, amount 0) and a note naming the holiday');
select t.ok((select attendance = 'attended' and status <> 'cancelled' from lessons where student_id = pg_temp.sid('k1') and lesson_date = :'hd'::date), 'a marked lesson on that day is untouched');
select t.ok((select paid and status <> 'cancelled' from lessons where student_id = pg_temp.sid('k7') and lesson_date = :'hd'::date), 'a paid lesson on that day is untouched');
select t.ok(exists (select 1 from audit_log where org_id = t.id('sc') and action = 'staff_holiday_cancel' and (after->>'lessons_cancelled')::int = :free_on_day), 'audited with the count');
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_holiday_cancel(t.id('sc'), :'hd'::date, :'hd'::date, 'Founders Day', false) as hc2 \gset
reset role;
select t.eq((:'hc2'::jsonb->>'cancel')::int, 0, 'pressing it again cancels nothing (idempotent)');
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_generate_lessons(t.id('sc'), :'hd'::date, :'hd'::date) as hc3 \gset
reset role;
select t.eq((:'hc3'::jsonb->>'created')::int, 0, 'the generator does not bring the cancelled lessons back');
-- days before today are never touched, and another centre's lessons never are
select set_config('request.jwt.claims', '', false);
insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status)
  values ('00000000-0000-0000-0000-00000000c001', t.id('sc'), pg_temp.sid('k9'), (select today - 2 from td), '09:00', '10:00', 40, 40, 'scheduled'),
         ('00000000-0000-0000-0000-00000000c009', t.id('sc2'), '00000000-0000-0000-0000-00000000c9f1', :'hd'::date, '09:00', '10:00', 40, 40, 'scheduled');
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_holiday_cancel(t.id('sc'), (select today - 2 from td), (select today - 2 from td), 'Past', false) as hc4 \gset
reset role;
select t.ok((:'hc4'::jsonb->>'cancel')::int = 0 and (:'hc4'::jsonb->>'earlier')::int = 1, 'a lesson in the past is not touched, and the preview says one earlier lesson was left');
select t.ok((select status = 'scheduled' from lessons where student_id = pg_temp.sid('k9') and lesson_date = (select today - 2 from td)), 'it is still scheduled');
select t.ok((select status = 'scheduled' from lessons where student_id = '00000000-0000-0000-0000-00000000c9f1'), 'another centre''s lesson on the same day is untouched');
-- a centre invoice line protects a lesson on the holiday
select pg_temp.dow(:wc, 40) as hd2 \gset
select set_config('request.jwt.claims', '', false);
insert into centre_invoice_lines(org_id, invoice_id, lesson_id, description, qty, unit_cents)
  select t.id('sc'), '00000000-0000-0000-0000-00000000c1a1', id, 'Maths lesson', 1, 4500 from lessons where student_id = pg_temp.sid('k7') and lesson_date = :'hd2'::date;
select t.as('00000000-0000-0000-0000-00000000c002'); set role authenticated;
select staff_holiday_cancel(t.id('sc'), :'hd2'::date, :'hd2'::date, 'Second', false) as hc5 \gset
reset role;
select t.ok((select status <> 'cancelled' from lessons where student_id = pg_temp.sid('k7') and lesson_date = :'hd2'::date), 'a lesson on a centre invoice is not cancelled');
select t.ok((:'hc5'::jsonb->>'kept')::int >= 1, 'and is counted as kept');

-- ===================================================================== 6. THE PEOPLE LIST
select t.as('00000000-0000-0000-0000-00000000c001'); set role authenticated;
select staff_people(t.id('sc')) as pp \gset
reset role;
select t.ok((:'pp'::jsonb->>'can_users')::boolean, 'the owner may open Users and permissions');
select t.ok(jsonb_array_length(:'pp'::jsonb->'rows') = 8, 'the owner sees every owner, staff member and tutor (8 here, including the switched-off one and the pending invite)');
select t.ok((:'pp'::jsonb->'rows'->0->>'role') = 'owner' and (:'pp'::jsonb->'rows'->0->>'you')::boolean, 'the owner comes first, and is marked as you');
select t.ok(exists (select 1 from jsonb_array_elements(:'pp'::jsonb->'rows') e where e->>'name' = 'Waiting Wen' and e->>'status' = 'invited' and (e->>'invited')::boolean and e->>'invited_at' is not null), 'a pending invite shows as invited, with when');
select t.ok(exists (select 1 from jsonb_array_elements(:'pp'::jsonb->'rows') e where e->>'name' = 'Switched off' and e->>'status' = 'disabled'), 'a switched-off person shows as off');
select t.ok((select bool_and(k in ('id', 'name', 'role', 'status', 'invited', 'invited_at', 'last_emailed_at', 'you')) from jsonb_array_elements(:'pp'::jsonb->'rows') e, jsonb_object_keys(e) k), 'a row has only those fields: no email, phone, pay, payout or money');
select t.ok(position('private.test' in :'pp'::text) = 0, 'the invited person''s email address is never returned');
select set_config('request.jwt.claims', '', false);
insert into org_invite_mail_log(membership_id, org_id, status, sent_at) values (t.id('mwen'), t.id('sc'), 'sent', now() - interval '2 hours');
select t.as('00000000-0000-0000-0000-00000000c006'); set role authenticated;
select staff_people(t.id('sc')) as pp2 \gset
reset role;
select t.ok(not (:'pp2'::jsonb->>'can_users')::boolean, 'staff with manage_tutors may not change users');
select t.ok((select bool_and(e->>'role' = 'tutor') from jsonb_array_elements(:'pp2'::jsonb->'rows') e) and jsonb_array_length(:'pp2'::jsonb->'rows') = 4, 'staff with manage_tutors see only the tutors (4)');
select t.ok(exists (select 1 from jsonb_array_elements(:'pp2'::jsonb->'rows') e where e->>'name' = 'Waiting Wen' and e->>'last_emailed_at' is not null), 'and when the last invite email went out');
select pg_temp.refused('00000000-0000-0000-0000-00000000c002', format('set role authenticated; select staff_people(%L)', t.id('sc')), 'NOT_ALLOWED', 'staff without manage_tutors get nothing'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c003', format('set role authenticated; select staff_people(%L)', t.id('sc')), 'NOT_ALLOWED', 'the front desk too'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c004', format('set role authenticated; select staff_people(%L)', t.id('sc')), 'NOT_FOUND', 'a tutor gets NOT_FOUND'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c007', format('set role authenticated; select staff_people(%L)', t.id('sc')), 'NOT_FOUND', 'a stranger gets NOT_FOUND'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c009', format('set role authenticated; select staff_people(%L)', t.id('sc')), 'NOT_FOUND', 'another centre''s owner gets NOT_FOUND'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c00a', format('set role authenticated; select staff_people(%L)', t.id('sc')), 'NOT_FOUND', 'a switched-off person gets NOT_FOUND'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-0000000000a1', format('set role authenticated; select staff_people(%L)', t.id('tina_org')), 'NOT_FOUND', 'a solo tutor''s own organisation is not a centre'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c001', 'set role authenticated; select staff_people(null)', 'NOT_FOUND', 'no organisation'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000c001', 'set role authenticated; select staff_people(gen_random_uuid())', 'NOT_FOUND', 'an unknown organisation'); reset role;

-- ===================================================================== solo tutors and the browser's reach
select t.ok((select bool_and(prosecdef and exists (select 1 from unnest(proconfig) c where c like 'search_path=%'))
               from pg_proc where proname in ('staff_stop_slot_from', 'staff_slot_student', 'staff_holiday_cancel', 'staff_people', 'staff_generate_core', 'lesson_change_blocker', 'staff_generate_lessons')),
            'every new or replaced function is security definer with a pinned search_path');
select t.ok(not has_function_privilege('anon', 'staff_stop_slot_from(uuid, uuid, date, boolean, boolean)', 'execute') and not has_function_privilege('anon', 'staff_slot_student(uuid, uuid, uuid, text, date, boolean)', 'execute')
        and not has_function_privilege('anon', 'staff_holiday_cancel(uuid, date, date, text, boolean)', 'execute') and not has_function_privilege('anon', 'staff_people(uuid)', 'execute'), 'anonymous visitors can call none of them');
select t.ok(not has_function_privilege('authenticated', 'staff_generate_core(uuid, date, date, boolean, uuid[])', 'execute') and not has_function_privilege('authenticated', 'lesson_change_blocker(uuid)', 'execute'), 'the two internal helpers are not callable from the browser');
select t.ok(not exists (select 1 from recurring_slots where org_id in (org_personal('00000000-0000-0000-0000-0000000000a1'), org_personal('00000000-0000-0000-0000-0000000000b1')) and (starts_on is not null or stopped_from is not null)), 'solo tutors'' slots are untouched (no start or stop day)');
select t.as('00000000-0000-0000-0000-0000000000a1'); set role authenticated;
select t.eq((select count(*) from recurring_slots), (select count(*) from recurring_slots where tutor_id = '00000000-0000-0000-0000-0000000000a1'), 'a solo tutor still sees only their own slots');
reset role;

\echo
\echo ALL SLOT-CHANGES TESTS PASSED
