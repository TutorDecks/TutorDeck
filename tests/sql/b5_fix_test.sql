-- B5-FIX tests (db/migration_b5_fix.sql): A deposits follow today's settings and the run says why a student gets none; F a student who is leaving a class can be
-- put back; H1 a changed slot adds the tutor and every save says what happened; H2 the tutor-changes list shows every change. Same throwaway database, own
-- centres and made-up people. Never touches a real project.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000b501', 'bf.owner@centre.test'), ('00000000-0000-0000-0000-00000000b502', 'bf.staff@centre.test'),
  ('00000000-0000-0000-0000-00000000b503', 'bf.tutor1@centre.test'), ('00000000-0000-0000-0000-00000000b504', 'bf.owner2@centre.test'),
  ('00000000-0000-0000-0000-00000000b505', 'bf.view@centre.test'), ('00000000-0000-0000-0000-00000000b506', 'bf.owner3@centre.test');
\set o3 '00000000-0000-0000-0000-00000000b506'
\set o1 '00000000-0000-0000-0000-00000000b501'
\set stf '00000000-0000-0000-0000-00000000b502'
\set tu1 '00000000-0000-0000-0000-00000000b503'
\set o2 '00000000-0000-0000-0000-00000000b504'
\set vw '00000000-0000-0000-0000-00000000b505'

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today, (extract(isodow from (now() at time zone 'Asia/Singapore')::date)::int - 1) as wd,
  date_trunc('month', (now() at time zone 'Asia/Singapore')::date - interval '1 month')::date as m;
grant select on td to authenticated, anon;
create function pg_temp.settings(p_dep jsonb, p_fee bigint) returns jsonb language sql as $$
  select jsonb_set(jsonb_set(jsonb_set(t.centre_settings(), '{profile,invoice_prefix}', '"INV"'),
         '{billing}', jsonb_build_object('model', 'postpaid_lessons', 'deposit', p_dep, 'one_off_fees', jsonb_build_object('registration_cents', 0, 'deposit_cents', p_fee, 'materials_cents', 0),
                                          'absences', '{"mode":"charged","notice_hours":24}'::jsonb)),
         '{invoicing}', jsonb_build_object('grouping', 'family', 'due_days', 7, 'review_before_sending', true)) $$;
create function pg_temp.mk(p_org uuid, p_owner uuid, p_stu uuid, p_day int, p_trial boolean default false) returns void language plpgsql as $$
begin
  insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, attendance, trial, subject)
  values (gen_random_uuid(), p_owner, p_org, p_stu, (select m from td) + (p_day - 1), '16:00', '17:00', 50, 50, 'done', 'attended', p_trial, 'Math');
end $$;
create function pg_temp.pv(p_org uuid, p_user uuid) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_invoice_run_preview(p_org, (select m from td)); end $$;
create function pg_temp.why(p_org uuid, p_user uuid) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_deposit_run_why(p_org, (select m from td)); end $$;
create function pg_temp.run(p_org uuid, p_user uuid) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_invoice_run_create_drafts(p_org, (select m from td)); end $$;
create function pg_temp.save(p_org uuid, p_user uuid, p_settings jsonb, p_from date) returns int language plpgsql as $$
begin perform t.as(p_user::text); return org_save_settings(p_org, p_settings, p_from); end $$;
create function pg_temp.refused(p_user text, p_sql text, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  begin execute p_sql; exception when others then m := sqlerrm; end;
  if m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS refused: % (%)', p_msg, m;
end $$;
grant execute on all functions in schema pg_temp to public;

-- ===================================================================== A. the centre of the bug: an old settings version without a deposit, the deposit saved TODAY
set role authenticated; select t.as(:'o1');
select t.put('a', org_create_centre('B5 Deposit Centre', pg_temp.settings('{"mode":"none","percent_bp":5000,"taxable":false,"due":"with_first_invoice","waived_by":"owner"}', 0)));
reset role; select set_config('request.jwt.claims', '', false);
-- the first settings version is OLD (as on DEV, where the centre was set up days before the deposit was switched on)
alter table org_settings disable trigger user;
update org_settings set effective_from = (select m from td) - 5 where org_id = t.id('a') and version = 1;
alter table org_settings enable trigger user;
insert into households(id, org_id, name) values ('00000000-0000-0000-0000-00000000b5a1', t.id('a'), 'Drafted Family'), ('00000000-0000-0000-0000-00000000b5a2', t.id('a'), 'New Family'),
  ('00000000-0000-0000-0000-00000000b5a3', t.id('a'), 'Trial Family');
insert into students(id, tutor_id, org_id, name, household_id) values
  ('00000000-0000-0000-0000-00000000b5b1', :'o1', t.id('a'), 'Drafted Kid', '00000000-0000-0000-0000-00000000b5a1');
select pg_temp.mk(t.id('a'), :'o1', '00000000-0000-0000-0000-00000000b5b1', 3); select pg_temp.mk(t.id('a'), :'o1', '00000000-0000-0000-0000-00000000b5b1', 4);
set role authenticated;
-- the run before the deposit exists drafts Drafted Kid's lesson invoice
select pg_temp.run(t.id('a'), :'o1') as r0 \gset
select t.eq((:'r0'::jsonb->>'created')::int, 1, 'the first run (no deposit set up yet) drafts the lesson invoice');
select t.eq((select count(*) from centre_deposits where org_id = t.id('a')), 0, '... and raises no deposit');
select t.ok((pg_temp.why(t.id('a'), :'o1')->>'note') like 'No deposit is raised%', 'with no deposit setting the run says so in plain words');
-- today the owner switches the deposit on: fixed S$60, together with the first invoice
select pg_temp.save(t.id('a'), :'o1', pg_temp.settings('{"mode":"fixed","percent_bp":5000,"taxable":false,"due":"with_first_invoice","waived_by":"owner"}', 6000), (select today from td));
reset role; select set_config('request.jwt.claims', '', false);
insert into students(id, tutor_id, org_id, name, household_id) values
  ('00000000-0000-0000-0000-00000000b5b2', :'o1', t.id('a'), 'New Kid', '00000000-0000-0000-0000-00000000b5a2'),
  ('00000000-0000-0000-0000-00000000b5b3', :'o1', t.id('a'), 'Trial Kid', '00000000-0000-0000-0000-00000000b5a3');
select pg_temp.mk(t.id('a'), :'o1', '00000000-0000-0000-0000-00000000b5b2', 3); select pg_temp.mk(t.id('a'), :'o1', '00000000-0000-0000-0000-00000000b5b2', 4);
select pg_temp.mk(t.id('a'), :'o1', '00000000-0000-0000-0000-00000000b5b3', 3, true);
set role authenticated;
create temp table pa as select pg_temp.pv(t.id('a'), :'o1') as j, pg_temp.why(t.id('a'), :'o1') as w;
grant select on pa to authenticated;
select t.eq((select jsonb_array_length(j->'deposits') from pa), 1, 'A: the brand-new student (invoice month = last month, setting saved today) DOES get a deposit in the preview');
select t.eq((select (j->'deposits'->0->>'amount_cents')::int from pa), 6000, 'A: S$60.00, the amount of the setting in force today');
select t.ok((select j->'deposits'->0->>'name' = 'New Kid' from pa), 'A: it is New Kid''s');
select t.ok((select w->>'note' is null from pa), 'A: nothing to warn about in the setting');
select t.ok((select exists (select 1 from jsonb_array_elements(w->'rows') e where e->>'name' = 'Drafted Kid' and e->>'reason' like 'already has a draft invoice from an earlier run%') from pa),
            'A: Drafted Kid (invoiced before the deposit was on) is listed with the plain reason and what to do');
select t.ok((select exists (select 1 from jsonb_array_elements(w->'rows') e where e->>'name' = 'Trial Kid' and e->>'reason' like '%only trial lessons%') from pa), 'A: a trial-only student is explained too');
select t.eq((select jsonb_array_length(w->'rows') from pa), 2, 'A: exactly the two students who get none');
select pg_temp.run(t.id('a'), :'o1') as r1 \gset
select t.eq((:'r1'::jsonb->>'deposits')::int, 1, 'A: Create drafts raises the one deposit draft');
reset role;
select t.eq((select count(*) from centre_invoices where org_id = t.id('a') and kind = 'deposit' and status = 'draft'), 1, 'A: one Refundable deposit draft exists');
select t.eq((select count(*) from centre_deposits where org_id = t.id('a') and student_id = '00000000-0000-0000-0000-00000000b5b2'), 1, 'A: and the deposit row (Money > Deposits)');
set role authenticated;
select pg_temp.run(t.id('a'), :'o1') as r2 \gset
select t.eq((:'r2'::jsonb->>'deposits')::int, 0, 'A: running again adds nothing twice');
select t.ok((pg_temp.why(t.id('a'), :'o1')->'rows') @> '[{"name":"New Kid"}]'::jsonb, 'A: afterwards New Kid is explained as already having a deposit');

-- a deposit setting that starts LATER (next cycle): the run says when
reset role; select set_config('request.jwt.claims', '', false);
set role authenticated; select t.as(:'o2');
select t.put('b', org_create_centre('B5 Later Centre', pg_temp.settings('{"mode":"none","percent_bp":5000,"taxable":false,"due":"with_first_invoice","waived_by":"owner"}', 0)));
reset role; update organisations set status = 'active' where id = t.id('b');
set role authenticated;
select pg_temp.save(t.id('b'), :'o2', pg_temp.settings('{"mode":"fixed","percent_bp":5000,"taxable":false,"due":"with_first_invoice","waived_by":"owner"}', 6000), (select (date_trunc('month', today) + interval '1 month')::date from td));
select t.ok((pg_temp.why(t.id('b'), :'o2')->>'note') like '%starts on%', 'a deposit setting that starts on the next cycle is explained: "starts on <date>"');
select t.eq((select jsonb_array_length(pg_temp.pv(t.id('b'), :'o2')->'deposits')), 0, '... and raises none before then');
select pg_temp.refused(:'tu1', format('set role authenticated; select centre_deposit_run_why(%L, %L)', t.id('a'), (select m from td)), 'NOT_FOUND', 'a stranger cannot ask why'); reset role;
select pg_temp.refused(:'o2', format('set role authenticated; select centre_deposit_run_why(%L, %L)', t.id('a'), (select m from td)), 'NOT_FOUND', 'another centre''s owner cannot ask why'); reset role;

-- ===================================================================== F + H1. a centre with a class
reset role; select set_config('request.jwt.claims', '', false);
set role authenticated; select t.as(:'o3');
select t.put('s', org_create_centre('B5 Class Centre', t.centre_settings()));
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('s'), :'tu1', 'Tutor One', 'tutor', '{}', 'active'), (t.id('s'), :'stf', 'Staff Sam', 'staff', array['manage_timetable'], 'active'),
  (t.id('s'), :'vw', 'Viewer Val', 'staff', array['manage_students'], 'active');
select t.put('m1', (select id from memberships where org_id = t.id('s') and user_id = :'tu1'));
create temp table stu (k text primary key, id uuid);
insert into stu select 'k' || g, gen_random_uuid() from generate_series(1, 4) g;
grant select on stu to authenticated;
insert into students(id, tutor_id, org_id, name, level) select id, :'o3', t.id('s'), 'Kid ' || k, 'P3' from stu;
create function pg_temp.sid(p_k text) returns uuid language sql as $$ select id from stu where k = p_k $$;
select ((select wd from td) + 3) % 7 as wa, ((select wd from td) + 4) % 7 as wb \gset
set role authenticated; select t.as(:'stf');
-- H1: a NEW slot with a tutor: added; then a CHANGE of tutor on an existing slot: the new tutor is added too; no tutor / already assigned / setting off say so
select staff_save_slot(t.id('s'), null, array[pg_temp.sid('k1')], :wa, '10:00', '11:00', null, 'Math', 50) as h0 \gset
select t.ok(:'h0'::jsonb#>>'{assign,state}' = 'no_tutor', 'H1: a slot with no tutor says no_tutor');
select (:'h0'::jsonb->'slot_ids'->>0)::uuid as h0slot \gset
select staff_save_slot(t.id('s'), :'h0slot'::uuid, null, :wa, '10:00', '11:00', t.id('m1'), 'Math', null) as h1 \gset
select t.ok(:'h1'::jsonb#>>'{assign,state}' = 'added' and jsonb_array_length(:'h1'::jsonb->'assigned') = 1, 'H1: CHANGING a slot to give it a tutor adds the tutor to the student''s assigned tutors, and says so');
reset role;
select t.eq((select count(*) from student_tutors where student_id = pg_temp.sid('k1') and membership_id = t.id('m1') and active), 1, 'H1: the assigned-tutor row exists');
set role authenticated; select t.as(:'stf');
select staff_save_slot(t.id('s'), :'h0slot'::uuid, null, :wa, '10:00', '11:00', t.id('m1'), 'Math', null) as h2 \gset
select t.ok(:'h2'::jsonb#>>'{assign,state}' = 'already' and jsonb_array_length(:'h2'::jsonb->'assigned') = 0, 'H1: saving again says the tutor is already assigned (never silent, never doubled)');
select staff_save_slot(t.id('s'), null, array[pg_temp.sid('k2')], :wb, '10:00', '11:00', t.id('m1'), 'Math', 50) as h3 \gset
select t.ok(:'h3'::jsonb#>>'{assign,state}' = 'added', 'H1: a new slot for a brand-new student adds the tutor');
reset role;
select set_config('request.jwt.claims', '', false);
set role authenticated; select t.as(:'o3');
select org_save_settings(t.id('s'), jsonb_set(org_settings_on(t.id('s'), current_date), '{lessons,auto_assign_tutors}', 'false'), current_date);
select t.as(:'stf');
select staff_save_slot(t.id('s'), null, array[pg_temp.sid('k3')], :wb, '12:00', '13:00', t.id('m1'), 'Math', 50) as h4 \gset
select t.ok(:'h4'::jsonb#>>'{assign,state}' = 'off' and jsonb_array_length(:'h4'::jsonb->'assigned') = 0, 'H1: with the setting off the answer says it was not added because the setting is off');
reset role;
select t.eq((select count(*) from student_tutors where student_id = pg_temp.sid('k3') and membership_id = t.id('m1')), 0, 'H1: and nobody was added');

-- F: a class of two (k1 + k4), lessons made, k4 is to leave from a day to come, then comes back
set role authenticated; select t.as(:'stf');
select staff_slot_student(t.id('s'), :'h0slot'::uuid, pg_temp.sid('k4'), 'add') as f0 \gset
select staff_generate_lessons(t.id('s'), (select today from td), (select today + 60 from td)) as fg \gset
select t.ok((:'fg'::jsonb->>'created')::int > 0, 'F: lessons exist for the class');
-- (the class's own lessons run as far as its other student's last one: that is how far a returning student gets them back)
select (select count(*) from lessons where student_id = pg_temp.sid('k4') and lesson_date >= (select today + 21 from td) and lesson_date <= (select max(lesson_date) from lessons where student_id = pg_temp.sid('k1')))::int as k4_before \gset
select (select count(*) from lessons where student_id = pg_temp.sid('k4') and lesson_date >= (select today + 21 from td))::int as k4_all \gset
select staff_slot_student(t.id('s'), :'h0slot'::uuid, pg_temp.sid('k4'), 'remove', (select today + 21 from td)) as f1 \gset
select t.ok((:'f1'::jsonb->>'lessons_removed')::int > 0, 'F: k4 leaves from day 21: later lessons gone');
select t.eq((select count(*) from lessons where student_id = pg_temp.sid('k4') and lesson_date >= (select today + 21 from td)), 0, 'F: none left');
select staff_slot_student(t.id('s'), :'h0slot'::uuid, pg_temp.sid('k4'), 'add', (select today + 21 from td), true) as f2 \gset
select t.ok((:'f2'::jsonb->>'returned')::boolean and (:'f2'::jsonb->>'dry')::boolean and (:'f2'::jsonb->>'would_create')::int = :k4_before, 'F: asking to add k4 back (dry) says it returns and how many lessons come back');
select staff_slot_student(t.id('s'), :'h0slot'::uuid, pg_temp.sid('k4'), 'add', (select today + 21 from td)) as f3 \gset
select t.ok((:'f3'::jsonb->>'returned')::boolean and (:'f3'::jsonb->>'created')::int = :k4_before, 'F: returned: the removed lessons are made again');
reset role;
select t.eq((select count(*) from recurring_slots where student_id = pg_temp.sid('k4') and stopped_from is not null), 0, 'F: the departure is cancelled (no stop date)');
select t.eq((select count(*) from recurring_slots where student_id = pg_temp.sid('k4')), 1, 'F: still ONE row for the student (not a second copy)');
select t.eq((select count(*) from audit_log where org_id = t.id('s') and action = 'staff_slot_student_return'), 1, 'F: audited');
select t.eq((select count(*) from lessons a join lessons b on a.session_id = b.session_id and a.student_id <> b.student_id where a.student_id = pg_temp.sid('k4') and a.lesson_date >= (select today + 21 from td)), :k4_before, 'F: the returned lessons share the class session again');
set role authenticated; select t.as(:'stf');
select staff_slot_student(t.id('s'), :'h0slot'::uuid, pg_temp.sid('k4'), 'add', (select today + 21 from td)) as f4 \gset
select t.ok((:'f4'::jsonb->>'already')::boolean, 'F: asking again says already in this slot (nothing doubled)');
reset role;
select t.eq((select count(*) from lessons where student_id = pg_temp.sid('k4') and lesson_date >= (select today + 21 from td)), :k4_before, 'F: lesson count unchanged by asking again');
select pg_temp.refused(:'vw', format('set role authenticated; select staff_slot_student(%L, %L, %L, ''add'')', t.id('s'), :'h0slot', pg_temp.sid('k4')), 'NOT_ALLOWED', 'front desk still cannot'); reset role;
select pg_temp.refused(:'o2', format('set role authenticated; select staff_slot_student(%L, %L, %L, ''add'')', t.id('s'), :'h0slot', pg_temp.sid('k4')), 'NOT_FOUND', 'another centre''s owner still cannot'); reset role;

-- ===================================================================== H2. tutor changes: every change, newest first, max 50, class = one row per student
select (select id from lessons where student_id = pg_temp.sid('k1') order by lesson_date limit 1) as hl \gset
insert into audit_log(org_id, actor, action, table_name, row_id, before, after, at) values
  (t.id('s'), :'tu1', 'tutor_postpone_lesson', 'lessons', :'hl', jsonb_build_object('lessons', jsonb_build_array(jsonb_build_object('lesson_id', :'hl'::uuid, 'lesson_date', (select today + 5 from td), 'start_time', '10:00'))),
     jsonb_build_object('lessons', jsonb_build_array(jsonb_build_object('lesson_id', :'hl'::uuid, 'lesson_date', (select today + 6 from td), 'start_time', '10:00', 'end_time', '11:00')), 'reason', 'Exam', 'what', 'moved'), now() - interval '2 days'),
  (t.id('s'), :'tu1', 'tutor_revert_lesson', 'lessons', :'hl', jsonb_build_object('lessons', jsonb_build_array(jsonb_build_object('lesson_id', :'hl'::uuid, 'lesson_date', (select today + 6 from td), 'start_time', '10:00'))),
     jsonb_build_object('lessons', jsonb_build_array(jsonb_build_object('lesson_id', :'hl'::uuid, 'lesson_date', (select today + 5 from td), 'start_time', '10:00', 'end_time', '11:00')), 'reason', null, 'what', 'reverted'), now() - interval '1 day'),
  (t.id('s'), :'tu1', 'tutor_cancel_lesson', 'lessons', :'hl', jsonb_build_object('lessons', jsonb_build_array(jsonb_build_object('lesson_id', :'hl'::uuid, 'lesson_date', (select today + 5 from td), 'start_time', '10:00'))),
     jsonb_build_object('lessons', jsonb_build_array(jsonb_build_object('lesson_id', :'hl'::uuid, 'lesson_date', (select today + 5 from td), 'start_time', '10:00', 'end_time', '11:00')), 'reason', 'Unwell', 'what', 'cancelled'), now() - interval '1 hour'),
  (t.id('s'), :'tu1', 'tutor_cancel_lesson', 'lessons', :'hl', '{"lessons":[]}', '{"lessons":[],"what":"cancelled"}', now() - interval '9 days');
set role authenticated; select t.as(:'stf');
create temp table h2 as select staff_tutor_changes(t.id('s')) as j;
grant select on h2 to authenticated;
select t.eq((select jsonb_array_length(j->'rows') from h2), 3, 'H2: all three changes of the SAME lesson are listed (not only the latest), the 9-day-old one is not');
select t.ok((select j->'rows'->0->>'what' = 'cancelled' and j->'rows'->1->>'what' = 'reverted' and j->'rows'->2->>'what' = 'moved' from h2), 'H2: newest first');
select t.ok((select j->'rows'->2->>'reason' = 'Exam' and j->'rows'->2->>'from_date' = (select (today + 5)::text from td) and j->'rows'->2->>'lesson_date' = (select (today + 6)::text from td) and j->'rows'->2->>'tutor_name' = 'Tutor One' and j->'rows'->2->>'student_name' = 'Kid k1' from h2), 'H2: a move shows its reason, where it was and where it went, who and for whom');
select t.ok((select not exists (select 1 from jsonb_object_keys(j->'rows'->0) k where k ~* '(rate|price|amount|paid|compens|charge|fee|cents|cost|balance|invoice)') from h2), 'H2: no money key in a row');
reset role;
insert into audit_log(org_id, actor, action, table_name, row_id, before, after, at)
select t.id('s'), :'tu1', 'tutor_postpone_lesson', 'lessons', :'hl', '{"lessons":[]}',
       jsonb_build_object('lessons', jsonb_build_array(jsonb_build_object('lesson_id', :'hl'::uuid, 'lesson_date', (select today + 7 from td), 'start_time', '10:00', 'end_time', '11:00')), 'what', 'moved'), now() - (g || ' minutes')::interval
  from generate_series(2, 70) g;
set role authenticated; select t.as(:'stf');
select t.eq((select jsonb_array_length(staff_tutor_changes(t.id('s'))->'rows')), 50, 'H2: at most 50 rows');
select pg_temp.refused(:'vw', format('set role authenticated; select staff_tutor_changes(%L)', t.id('s')), 'NOT_ALLOWED', 'staff without Manage timetable still cannot'); reset role;
select pg_temp.refused(:'tu1', format('set role authenticated; select staff_tutor_changes(%L)', t.id('s')), 'NOT_FOUND', 'a tutor still cannot'); reset role;
select pg_temp.refused(:'o2', format('set role authenticated; select staff_tutor_changes(%L)', t.id('s')), 'NOT_FOUND', 'another centre''s owner still cannot'); reset role;
select t.ok(not has_function_privilege('anon', 'staff_save_slot(uuid,uuid,uuid[],int,time,time,uuid,text,numeric)', 'execute') and has_function_privilege('authenticated', 'staff_save_slot(uuid,uuid,uuid[],int,time,time,uuid,text,numeric)', 'execute')
        and not has_function_privilege('authenticated', 'staff_save_slot_core(uuid,uuid,uuid[],int,time,time,uuid,text,numeric)', 'execute') and not has_function_privilege('authenticated', 'staff_slot_student_core(uuid,uuid,uuid,text,date,boolean)', 'execute')
        and not has_function_privilege('anon', 'centre_deposit_run_why(uuid,date)', 'execute'), 'the wrappers are callable, the originals are not, anonymous can call none');
select 'B5 FIX OK' as done;
