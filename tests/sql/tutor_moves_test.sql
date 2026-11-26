-- T6 step 2 tests: tutors move, revert and cancel their own lessons (db/migration_tutor_moves.sql).
-- Every setting value, switch and limit; the notice edges (0 / 24 / 168 h); the limit at and over; who is refused (all the same NOT_FOUND); locked lessons;
-- the centre's time zone; classes (all or nothing); audit; staff list; no money anywhere; no direct table access; the validator.
-- Runs last in the same throwaway database (reuses the t.* helpers). Builds its own centres and made-up people.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-000000a60001', 'tm.owner@centre.test'),  ('00000000-0000-0000-0000-000000a60002', 'tm.staff@centre.test'),
  ('00000000-0000-0000-0000-000000a60003', 'tm.viewer@centre.test'), ('00000000-0000-0000-0000-000000a60004', 'tm.tutor1@centre.test'),
  ('00000000-0000-0000-0000-000000a60005', 'tm.tutor2@centre.test'), ('00000000-0000-0000-0000-000000a60006', 'tm.solo@centre.test'),
  ('00000000-0000-0000-0000-000000a60007', 'tm.off@centre.test'),    ('00000000-0000-0000-0000-000000a60008', 'tm.parent@centre.test'),
  ('00000000-0000-0000-0000-000000a60009', 'tm.owner2@centre.test'), ('00000000-0000-0000-0000-000000a6000b', 'tm.tutor4@centre.test'),
  ('00000000-0000-0000-0000-000000a6000c', 'tm.ownerk@centre.test'), ('00000000-0000-0000-0000-000000a6000d', 'tm.tutork@centre.test');
set role authenticated; select t.as('00000000-0000-0000-0000-000000a60001');
select t.put('tm', org_create_centre('Moves Centre', t.centre_settings()));
select t.as('00000000-0000-0000-0000-000000a60009');
select t.put('tm2', org_create_centre('Other Moves Centre', t.centre_settings()));
select t.as('00000000-0000-0000-0000-000000a6000c');
select t.put('tk', org_create_centre('Kiritimati Centre', t.centre_settings()));
reset role; select set_config('request.jwt.claims', '', false);
select org_personal('00000000-0000-0000-0000-000000a60006');
update organisations set timezone = 'Pacific/Kiritimati' where id = t.id('tk');        -- UTC+14: its calendar day is often a day AHEAD of the server's
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('tm'), '00000000-0000-0000-0000-000000a60002', 'Staff Sam',    'staff', array['manage_timetable'], 'active'),
  (t.id('tm'), '00000000-0000-0000-0000-000000a60003', 'Staff Viewer', 'staff', '{}', 'active'),
  (t.id('tm'), '00000000-0000-0000-0000-000000a60004', 'Tutor One',    'tutor', '{}', 'active'),
  (t.id('tm'), '00000000-0000-0000-0000-000000a60005', 'Tutor Two',    'tutor', '{}', 'active'),
  (t.id('tm'), '00000000-0000-0000-0000-000000a60007', 'Switched off', 'tutor', '{}', 'active'),
  (t.id('tm'), '00000000-0000-0000-0000-000000a60008', 'A Parent',     'parent', '{}', 'active'),
  (t.id('tm2'), '00000000-0000-0000-0000-000000a6000b', 'Tutor Four elsewhere', 'tutor', '{}', 'active'),
  (t.id('tk'), '00000000-0000-0000-0000-000000a6000d', 'Tutor Kiri', 'tutor', '{}', 'active');
select t.put('m1', (select id from memberships where org_id = t.id('tm') and user_id = '00000000-0000-0000-0000-000000a60004'));
select t.put('m2', (select id from memberships where org_id = t.id('tm') and user_id = '00000000-0000-0000-0000-000000a60005'));
select t.put('moff', (select id from memberships where org_id = t.id('tm') and user_id = '00000000-0000-0000-0000-000000a60007'));
select t.put('mx', (select id from memberships where org_id = t.id('tm2') and user_id = '00000000-0000-0000-0000-000000a6000b'));
select t.put('mk', (select id from memberships where org_id = t.id('tk') and user_id = '00000000-0000-0000-0000-000000a6000d'));

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today;
grant select on td to authenticated, anon;
insert into students(id, tutor_id, org_id, name, level, contact) values
  ('00000000-0000-0000-0000-000000a60101', '00000000-0000-0000-0000-000000a60001', t.id('tm'), 'Kid One',   'P1', '91110001'),
  ('00000000-0000-0000-0000-000000a60102', '00000000-0000-0000-0000-000000a60001', t.id('tm'), 'Kid Two',   'P2', '91110002'),
  ('00000000-0000-0000-0000-000000a60103', '00000000-0000-0000-0000-000000a60001', t.id('tm'), 'Kid Three (not assigned)', 'P3', '91110003'),
  ('00000000-0000-0000-0000-000000a60104', '00000000-0000-0000-0000-000000a60001', t.id('tm'), 'Kid Four',  'P4', '91110004'),
  ('00000000-0000-0000-0000-000000a60105', '00000000-0000-0000-0000-000000a6000c', t.id('tk'), 'Kid Kiri',  'P5', '91110005'),
  ('00000000-0000-0000-0000-000000a601f1', '00000000-0000-0000-0000-000000a60009', t.id('tm2'), 'Kid elsewhere', 'P1', '91119999');
insert into student_tutors(org_id, student_id, membership_id) values
  (t.id('tm'), '00000000-0000-0000-0000-000000a60101', t.id('m1')), (t.id('tm'), '00000000-0000-0000-0000-000000a60102', t.id('m2')),
  (t.id('tm'), '00000000-0000-0000-0000-000000a60104', t.id('m1')), (t.id('tk'), '00000000-0000-0000-0000-000000a60105', t.id('mk'));

-- ---- helpers (session-local)
-- a lesson at an exact moment (the CENTRE's clock), 5 minutes long; MARKER money values so a leak anywhere is found by text search
create function pg_temp.mk(p_key text, p_student uuid, p_ts timestamptz, p_tutor text, p_org text default 'tm', p_tz text default 'Asia/Singapore') returns void language plpgsql as $$
declare ld date := (p_ts at time zone p_tz)::date; st time := date_trunc('minute', p_ts at time zone p_tz)::time; v uuid;
begin
  if st > '23:50' then st := '23:50'; end if;
  insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, paid, charge_note, status, taught_by)
  values (gen_random_uuid(), case when p_org = 'tk' then '00000000-0000-0000-0000-000000a6000c'::uuid else '00000000-0000-0000-0000-000000a60001'::uuid end, t.id(p_org), p_student, ld, st, st + interval '5 minutes', 777.77, 888.88, false, 'SECRETNOTE', 'scheduled',
          case when p_tutor is null then null else t.id(p_tutor) end) returning id into v;
  perform t.put(p_key, v);
end $$;
-- a lesson on a given day and time (Singapore), an hour long unless said
create function pg_temp.mkd(p_key text, p_student uuid, p_day int, p_start time, p_tutor text, p_len interval default '1 hour') returns void language plpgsql as $$
declare v uuid;
begin
  insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, paid, charge_note, status, taught_by)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000a60001', t.id('tm'), p_student, (select today + p_day from td), p_start, p_start + p_len, 777.77, 888.88, false, 'SECRETNOTE', 'scheduled', t.id(p_tutor)) returning id into v;
  perform t.put(p_key, v);
end $$;
create function pg_temp.settings(p_org text, p_owner text, p_lessons jsonb) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_owner, 'role', 'authenticated')::text, false);
  set local role authenticated;
  perform org_save_settings(t.id(p_org), jsonb_set(t.centre_settings(), '{lessons}', p_lessons), current_date);
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
create function pg_temp.postpone(p_user text, p_key text, p_day int, p_start text, p_reason text default 'student has a school event') returns text language sql as $$
  select pg_temp.call(p_user, format('select tutor_postpone_lesson(%L, (select today + %s from td), %L::time, %L)', t.id(p_key), p_day, p_start, p_reason)) $$;
create function pg_temp.revert(p_user text, p_key text, p_reason text default 'back to the usual time') returns text language sql as $$
  select pg_temp.call(p_user, format('select tutor_revert_lesson(%L, %L)', t.id(p_key), p_reason)) $$;
create function pg_temp.cancel(p_user text, p_key text, p_reason text default 'tutor is unwell') returns text language sql as $$
  select pg_temp.call(p_user, format('select tutor_cancel_lesson(%L, %L)', t.id(p_key), p_reason)) $$;
create function pg_temp.lk(p_key text) returns lessons language sql as $$ select l from lessons l where l.id = t.id(p_key) $$;
create function pg_temp.keys(j jsonb) returns setof text language sql as $$
  with recursive r(v, k) as (
    select j, null::text
    union all
    select c.value, c.key from r, lateral (
      select e.key, e.value from jsonb_each(case when jsonb_typeof(r.v) = 'object' then r.v else '{}'::jsonb end) e
      union all
      select null::text, a.value from jsonb_array_elements(case when jsonb_typeof(r.v) = 'array' then r.v else '[]'::jsonb end) a) c)
  select k from r where k is not null $$;
create function pg_temp.sch(p_user text, p_from int, p_to int) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  set local role authenticated;
  select tutor_my_schedule((select today + p_from from td), (select today + p_to from td)) into r;
  reset role;
  return r;
end $$;
select set_config('request.jwt.claims', '', false);

\set T1 '00000000-0000-0000-0000-000000a60004'
\set T2 '00000000-0000-0000-0000-000000a60005'
\set OWNER '00000000-0000-0000-0000-000000a60001'
\set STAFF '00000000-0000-0000-0000-000000a60002'
\set VIEWER '00000000-0000-0000-0000-000000a60003'

-- ===================================================================== 0. the settings validator (every value, good and bad)
create function pg_temp.save(p_lessons jsonb, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'ok';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-000000a60001', 'role', 'authenticated')::text, false);
  set local role authenticated;
  begin perform org_save_settings(t.id('tm'), jsonb_set(t.centre_settings(), '{lessons}', p_lessons), current_date); exception when others then m := sqlerrm; end;
  reset role;
  if p_expect = 'ok' and m <> 'ok' then raise exception 'FAIL: % was refused (%)', p_msg, m; end if;
  if p_expect <> 'ok' and m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS %: %', case when p_expect = 'ok' then 'saved' else 'refused' end, p_msg;
end $$;
select pg_temp.save('{}', 'ok', 'settings saved before this step (no new keys)');
select pg_temp.save('{"timetable_editing":"admin_only"}', 'ok', 'timetable_editing admin_only');
select pg_temp.save('{"timetable_editing":"tutors_direct"}', 'ok', 'timetable_editing tutors_direct');
select pg_temp.save('{"timetable_editing":"tutors_propose"}', 'ok', 'timetable_editing tutors_propose (still soon in the form, but a valid value)');
select pg_temp.save('{"timetable_editing":"tutors_own"}', 'Unknown timetable editing', 'the old unbuilt key tutors_own is gone');
select pg_temp.save('{"timetable_editing":"bogus"}', 'Unknown timetable editing', 'an unknown timetable_editing');
select pg_temp.save('{"notify_family":"off"}', 'ok', 'notify_family off');
select pg_temp.save('{"notify_family":"list_for_admin"}', 'ok', 'notify_family list_for_admin');
select pg_temp.save('{"notify_family":"email"}', 'Unknown family notice', 'notify_family email is not built');
select pg_temp.save('{"min_notice_hours":0}', 'ok', 'notice 0');
select pg_temp.save('{"min_notice_hours":24}', 'ok', 'notice 24');
select pg_temp.save('{"min_notice_hours":168}', 'ok', 'notice 168');
select pg_temp.save('{"min_notice_hours":169}', 'Notice before a change', 'notice 169 is too long');
select pg_temp.save('{"min_notice_hours":-1}', 'Notice before a change', 'a negative notice');
select pg_temp.save('{"min_notice_hours":1.5}', 'Notice before a change', 'a fractional notice');
select pg_temp.save('{"min_notice_hours":"24"}', 'Notice before a change', 'a text notice');
select pg_temp.save('{"max_changes_per_month":0}', 'ok', 'limit 0 = no limit');
select pg_temp.save('{"max_changes_per_month":500}', 'ok', 'limit 500');
select pg_temp.save('{"max_changes_per_month":501}', 'Changes per tutor', 'limit 501 is too high');
select pg_temp.save('{"max_changes_per_month":-3}', 'Changes per tutor', 'a negative limit');
select pg_temp.save('{"tutors_edit":{"postpone":true,"cancel":false,"weekly_slots":false,"generate":false,"one_off":false,"link":false}}', 'ok', 'all six switches');
select pg_temp.save('{"tutors_edit":{"postpone":"yes"}}', 'Setting {lessons,tutors_edit,postpone} must be yes or no', 'a switch must be yes or no');
select pg_temp.save('{"tutors_edit":{"cancel":1}}', 'Setting {lessons,tutors_edit,cancel} must be yes or no', 'a number is not a switch');
select pg_temp.save('{"tutors_edit":"all"}', 'Tutor editing switches are malformed', 'the switches must be an object');

-- ===================================================================== 1. who is refused (always the same word)
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"postpone":true,"cancel":true}}');
select pg_temp.mkd('A', '00000000-0000-0000-0000-000000a60101', 5, '10:00', 'm1');
select pg_temp.mkd('NA', '00000000-0000-0000-0000-000000a60103', 5, '12:00', 'm1');          -- tutor one teaches it but the student is not assigned to them
select pg_temp.mkd('B', '00000000-0000-0000-0000-000000a60102', 5, '14:00', 'm2');
select pg_temp.mkd('OFF', '00000000-0000-0000-0000-000000a60101', 6, '14:00', 'moff');       -- a switched-off tutor's lesson
update memberships set status = 'disabled' where id = t.id('moff');
select pg_temp.mkd('NOBODY', '00000000-0000-0000-0000-000000a60101', 6, '15:00', 'm1'); update lessons set taught_by = null where id = t.id('NOBODY');
create function pg_temp.nf(p_user text, p_key text, p_who text) returns void language plpgsql as $$
begin
  perform pg_temp.expect(p_user, format('select tutor_postpone_lesson(%L, current_date + 30, %L::time, ''a reason'')', t.id(p_key), '10:00'), 'NOT_FOUND', p_who || ': move');
  perform pg_temp.expect(p_user, format('select tutor_revert_lesson(%L, ''a reason'')', t.id(p_key)), 'NOT_FOUND', p_who || ': revert');
  perform pg_temp.expect(p_user, format('select tutor_cancel_lesson(%L, ''a reason'')', t.id(p_key)), 'NOT_FOUND', p_who || ': cancel');
end $$;
select pg_temp.nf(:'OWNER', 'A', 'the centre owner');
select pg_temp.nf(:'STAFF', 'A', 'centre staff');
select pg_temp.nf('00000000-0000-0000-0000-000000a60008', 'A', 'a parent');
select pg_temp.nf('00000000-0000-0000-0000-000000a60007', 'OFF', 'a switched-off tutor (their own old lesson)');
select pg_temp.nf('00000000-0000-0000-0000-000000a60006', 'A', 'a solo tutor');
select pg_temp.nf(:'T2', 'A', 'another tutor of the same centre');
select pg_temp.nf('00000000-0000-0000-0000-000000a6000b', 'A', 'a tutor of ANOTHER centre');
select pg_temp.nf(:'T1', 'B', 'tutor one on tutor two''s lesson');
select pg_temp.nf(:'T1', 'NA', 'tutor one on a lesson of a student NOT assigned to them');
select pg_temp.nf(:'T1', 'NOBODY', 'a lesson with no tutor');
select pg_temp.expect(:'T1', format('select tutor_postpone_lesson(%L, current_date + 30, ''10:00''::time, ''a reason'')', gen_random_uuid()), 'NOT_FOUND', 'an id that does not exist');
select pg_temp.expect(null, format('select tutor_cancel_lesson(%L, ''a reason'')', t.id('A')), 'NOT_FOUND', 'a token with no user');
reset role; set role anon;
select t.fails(format('select tutor_cancel_lesson(%L, ''x'')', t.id('A')), 'anon cannot call tutor_cancel_lesson');
select t.fails(format('select tutor_postpone_lesson(%L, current_date + 30, ''10:00''::time, ''x'')', t.id('A')), 'anon cannot call tutor_postpone_lesson');
select t.fails(format('select tutor_revert_lesson(%L, ''x'')', t.id('A')), 'anon cannot call tutor_revert_lesson');
select t.fails($q$ select staff_tutor_changes(null) $q$, 'anon cannot call staff_tutor_changes');
reset role;
select t.ok((select count(*) = 0 from audit_log where action like 'tutor\_%\_lesson'), 'nothing above wrote an audit row (every refusal changes nothing)');
select t.ok((pg_temp.lk('A')).lesson_date = (select today + 5 from td) and not (pg_temp.lk('A')).postponed and (pg_temp.lk('A')).changed_by_tutor_at is null, 'and the lesson is untouched');

-- ===================================================================== 2. the centre's setting and switches, every value
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"admin_only"}');
select t.ok(left(pg_temp.postpone(:'T1', 'A', 20, '10:00'), 20) = 'ERR:NOT_ALLOWED: at ', 'admin_only (the default today): a move is refused');
select t.ok(pg_temp.revert(:'T1', 'A') like 'ERR:NOT_ALLOWED%' and pg_temp.cancel(:'T1', 'A') like 'ERR:NOT_ALLOWED%', 'admin_only: revert and cancel are refused too');
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"tutors_propose","tutors_edit":{"postpone":true,"cancel":true}}');
select t.ok(pg_temp.postpone(:'T1', 'A', 20, '10:00') like 'ERR:NOT_ALLOWED%' and pg_temp.cancel(:'T1', 'A') like 'ERR:NOT_ALLOWED%', 'tutors_propose (not built yet): refused, nothing happens');
select pg_temp.settings('tm', :'OWNER', '{}');
select t.ok(pg_temp.postpone(:'T1', 'A', 20, '10:00') like 'ERR:NOT_ALLOWED%', 'no setting at all = admin_only');
-- tutors_direct: the switches. Missing = postpone ON, cancel OFF.
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"tutors_direct"}');
select t.ok(pg_temp.cancel(:'T1', 'A') like 'ERR:SWITCH_OFF%', 'tutors_direct with no switches: cancel is OFF by default');
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"postpone":false,"cancel":true}}');
select t.ok(pg_temp.postpone(:'T1', 'A', 20, '10:00') like 'ERR:SWITCH_OFF%', 'postpone switch OFF: a move is refused');
select t.ok(pg_temp.revert(:'T1', 'A') like 'ERR:SWITCH_OFF%', '...and so is a revert (it belongs to the same switch)');
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"postpone":true,"cancel":false}}');
select t.ok(pg_temp.cancel(:'T1', 'A') like 'ERR:SWITCH_OFF%', 'cancel switch OFF: a cancel is refused');
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"postpone":true,"cancel":true,"weekly_slots":false,"generate":false,"one_off":false,"link":false}}');
select t.ok((select count(*) = 0 from audit_log where action like 'tutor\_%\_lesson'), 'no refusal wrote anything');

-- ===================================================================== 3. a move: what it does, and what it never touches
select pg_temp.mkd('P1', '00000000-0000-0000-0000-000000a60101', 6, '09:00', 'm1', '90 minutes');
update lessons set slot_date = (select today + 6 from td) where id = t.id('P1');
select pg_temp.postpone(:'T1', 'P1', 8, '16:30', 'student has a school event') as r \gset
select t.ok(:'r'::jsonb->>'what' = 'moved' and (:'r'::jsonb->>'lessons')::int = 1 and (:'r'::jsonb->>'lesson_date')::date = (select today + 8 from td) and :'r'::jsonb->>'start_time' = '16:30:00' and :'r'::jsonb->>'end_time' = '18:00:00', 'a move answers what happened');
select t.ok((pg_temp.lk('P1')).lesson_date = (select today + 8 from td) and (pg_temp.lk('P1')).start_time = '16:30' and (pg_temp.lk('P1')).end_time = '18:00'
        and (pg_temp.lk('P1')).postponed and (pg_temp.lk('P1')).slot_date = (select today + 6 from td), 'the lesson moved, kept its LENGTH (90 minutes), is marked postponed and KEEPS slot_date (so no phantom lesson at the old slot)');
select t.ok((pg_temp.lk('P1')).rate = 777.77 and (pg_temp.lk('P1')).amount = 888.88 and (pg_temp.lk('P1')).paid = false and (pg_temp.lk('P1')).compensation is null
        and (pg_temp.lk('P1')).charge_note = 'SECRETNOTE' and (pg_temp.lk('P1')).status = 'scheduled', 'rate, amount, paid, charge note, compensation and status are exactly as before');
select t.ok((pg_temp.lk('P1')).changed_by_tutor_what = 'moved' and (pg_temp.lk('P1')).changed_by_tutor = t.id('m1') and (pg_temp.lk('P1')).changed_by_tutor_reason = 'student has a school event'
        and (pg_temp.lk('P1')).changed_by_tutor_at > now() - interval '1 minute' and (pg_temp.lk('P1')).changed_from_date = (select today + 6 from td) and (pg_temp.lk('P1')).changed_from_start = '09:00', 'who, what, why, when and from where are kept on the lesson');
select t.ok((select count(*) = 1 and bool_and(actor = '00000000-0000-0000-0000-000000a60004' and org_id = t.id('tm') and after->>'reason' = 'student has a school event' and before->'lessons'->0->>'start_time' = '09:00:00')
               from audit_log where action = 'tutor_postpone_lesson' and row_id = t.id('P1')::text), 'one audit row, with the actor and the reason, and what it was before');
-- pressing it twice changes nothing twice
select t.ok(pg_temp.postpone(:'T1', 'P1', 8, '16:30') like 'ERR:NO_CHANGE%', 'the same move again is refused (nothing is done twice)');
select t.ok((select count(*) = 1 from audit_log where action = 'tutor_postpone_lesson' and row_id = t.id('P1')::text), '...and there is still exactly one audit row');
-- the staff chip
select pg_temp.call(:'STAFF', format('select staff_tutor_changes(%L)', t.id('tm'))) as sc \gset
select t.ok((select count(*) = 1 from jsonb_array_elements(:'sc'::jsonb->'rows') e where e->>'lesson_id' = t.id('P1')::text and e->>'what' = 'moved' and e->>'tutor_name' = 'Tutor One'
               and e->>'student_name' = 'Kid One' and e->>'from_start' = '09:00:00' and e->>'reason' = 'student has a school event'), 'staff see the move, who made it, the old time and the reason');

-- ===================================================================== 4. revert: back to the usual slot
-- slot: the weekday of today+10, 10:00-11:00, tutor one, student one. The lesson was moved from that slot to the next day at 15:00.
insert into recurring_slots(id, tutor_id, org_id, student_id, weekday, start_time, end_time, subject, rate, active, taught_by) values
  ('00000000-0000-0000-0000-000000a60201', '00000000-0000-0000-0000-000000a60001', t.id('tm'), '00000000-0000-0000-0000-000000a60101',
   (select extract(isodow from today + 10)::int - 1 from td), '10:00', '11:00', 'Maths', 666.66, true, t.id('m1'));
select pg_temp.mkd('R1', '00000000-0000-0000-0000-000000a60101', 11, '15:00', 'm1');
update lessons set slot_id = '00000000-0000-0000-0000-000000a60201', slot_date = (select today + 10 from td), postponed = true where id = t.id('R1');
select pg_temp.revert(:'T1', 'R1', 'the parent changed their mind') as r \gset
select t.ok(:'r'::jsonb->>'what' = 'reverted' and (pg_temp.lk('R1')).lesson_date = (select today + 10 from td) and (pg_temp.lk('R1')).start_time = '10:00' and (pg_temp.lk('R1')).end_time = '11:00'
        and not (pg_temp.lk('R1')).postponed and (pg_temp.lk('R1')).changed_by_tutor_what = 'reverted' and (pg_temp.lk('R1')).changed_from_date = (select today + 11 from td),
        'revert puts the lesson back on the slot''s own day and time and clears the postponed mark');
select t.ok((pg_temp.lk('R1')).rate = 777.77 and (pg_temp.lk('R1')).amount = 888.88 and not (pg_temp.lk('R1')).paid, 'money untouched by a revert');
select t.ok(pg_temp.revert(:'T1', 'R1') like 'ERR:NOT_MOVED%', 'reverting a lesson that is already at its usual time is refused (pressing twice changes nothing)');
select pg_temp.mkd('R2', '00000000-0000-0000-0000-000000a60101', 12, '15:00', 'm1');
select t.ok(pg_temp.revert(:'T1', 'R2') like 'ERR:NOT_MOVED%', 'a lesson that was never moved can''t be reverted');
select pg_temp.mkd('R3', '00000000-0000-0000-0000-000000a60101', 12, '16:30', 'm1'); update lessons set postponed = true where id = t.id('R3');
select t.ok(pg_temp.revert(:'T1', 'R3') like 'ERR:NO_SLOT%', 'a moved one-off lesson (no slot) has nothing to go back to');
select pg_temp.mkd('R4', '00000000-0000-0000-0000-000000a60101', 12, '17:30', 'm1', '2 hours');
update lessons set slot_id = '00000000-0000-0000-0000-000000a60201', slot_date = (select today + 10 from td), postponed = true where id = t.id('R4');
select t.ok(pg_temp.revert(:'T1', 'R4') like 'ERR:SLOT_CHANGED%', 'a slot that has since changed length: ask an admin');
select pg_temp.mkd('R5', '00000000-0000-0000-0000-000000a60101', 12, '19:00', 'm1');
update lessons set slot_id = '00000000-0000-0000-0000-000000a60201', slot_date = (select today + 10 from td), postponed = true where id = t.id('R5');
update recurring_slots set active = false where id = '00000000-0000-0000-0000-000000a60201';
select t.ok(pg_temp.revert(:'T1', 'R5') like 'ERR:NO_SLOT%', 'a stopped slot: nothing to go back to');
update recurring_slots set active = true, taught_by = t.id('m2') where id = '00000000-0000-0000-0000-000000a60201';
select t.ok(pg_temp.revert(:'T1', 'R5') like 'ERR:SLOT_CHANGED%', 'a slot now given to another tutor: ask an admin');
update recurring_slots set taught_by = t.id('m1') where id = '00000000-0000-0000-0000-000000a60201';

-- ===================================================================== 5. a cancel: no charge, nothing else
select pg_temp.mkd('C1', '00000000-0000-0000-0000-000000a60101', 9, '10:00', 'm1');
select pg_temp.cancel(:'T1', 'C1', 'tutor is unwell') as r \gset
select t.ok(:'r'::jsonb->>'what' = 'cancelled' and (:'r'::jsonb->>'cancelled')::boolean, 'a cancel answers what happened');
select t.ok((pg_temp.lk('C1')).status = 'cancelled' and (pg_temp.lk('C1')).compensation = 0 and (pg_temp.lk('C1')).attendance is null
        and (pg_temp.lk('C1')).rate = 777.77 and (pg_temp.lk('C1')).amount = 888.88 and not (pg_temp.lk('C1')).paid, 'cancelled, charge 0 = NOT charged (not pending), no attendance mark, rate and amount untouched');
select t.ok((pg_temp.lk('C1')).lesson_date = (select today + 9 from td) and (pg_temp.lk('C1')).start_time = '10:00', 'the lesson keeps its date and time (the record of what was cancelled)');
select t.ok((pg_temp.lk('C1')).changed_by_tutor_what = 'cancelled' and (pg_temp.lk('C1')).changed_by_tutor_reason = 'tutor is unwell', 'who/what/why kept');
select t.ok(pg_temp.cancel(:'T1', 'C1') like 'ERR:CANCELLED%', 'cancelling again is refused (nothing is done twice)');
select t.ok(pg_temp.postpone(:'T1', 'C1', 20, '10:00') like 'ERR:CANCELLED%' and pg_temp.revert(:'T1', 'C1') like 'ERR:CANCELLED%', 'a cancelled lesson can''t be moved or reverted by the tutor either');
select t.ok((select count(*) = 1 from audit_log where action = 'tutor_cancel_lesson' and row_id = t.id('C1')::text and after->>'what' = 'cancelled'), 'one audit row for the cancel');
select t.ok((select count(*) = 0 from public.centre_family_credit where org_id in (t.id('tm'), t.id('tm2'), t.id('tk'))), 'a tutor''s cancel creates no family credit (staff decide, T18): this centre has none');

-- ===================================================================== 6. locked lessons
select pg_temp.mkd('L1', '00000000-0000-0000-0000-000000a60101', 13, '10:00', 'm1');
select set_config('request.jwt.claims', '', false);                 -- a server job, not a person: it may write a mark the guard would refuse a person
insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, taught_by, attendance)
  values ('00000000-0000-0000-0000-000000a60301', '00000000-0000-0000-0000-000000a60001', t.id('tm'), '00000000-0000-0000-0000-000000a60101', (select today + 13 from td), '12:00', '13:00', 777.77, 888.88, 'done', t.id('m1'), 'attended');
select t.put('MK', '00000000-0000-0000-0000-000000a60301');
select pg_temp.mkd('L2', '00000000-0000-0000-0000-000000a60101', 13, '13:30', 'm1'); update lessons set paid = true where id = t.id('L2');
select pg_temp.mkd('L3', '00000000-0000-0000-0000-000000a60101', 13, '14:30', 'm1');
insert into invoices(tutor_id, org_id, student_id, invoice_no, total, data) values
  ('00000000-0000-0000-0000-000000a60001', t.id('tm'), '00000000-0000-0000-0000-000000a60101', 'TM-1', 60, jsonb_build_object('lesson_ids', jsonb_build_array(t.id('L3')::text)));
select pg_temp.mkd('L4', '00000000-0000-0000-0000-000000a60101', 13, '15:30', 'm1');
insert into invoices(tutor_id, org_id, student_id, invoice_no, total, data) values
  ('00000000-0000-0000-0000-000000a60001', t.id('tm'), '00000000-0000-0000-0000-000000a60101', 'TM-2', 60, jsonb_build_object('lesson_ids', jsonb_build_array(t.id('L4')::text), 'replaced_by', 'TM-3'));
select t.ok(pg_temp.postpone(:'T1', 'MK', 20, '10:00') like 'ERR:ALREADY_MARKED%' and pg_temp.cancel(:'T1', 'MK') like 'ERR:ALREADY_MARKED%' and pg_temp.revert(:'T1', 'MK') like 'ERR:ALREADY_MARKED%', 'a MARKED lesson: all three refused');
select t.ok(pg_temp.postpone(:'T1', 'L2', 20, '10:00') like 'ERR:LOCKED%' and pg_temp.cancel(:'T1', 'L2') like 'ERR:LOCKED%', 'a PAID lesson: refused as LOCKED (a tutor is never told it is paid)');
select t.ok(pg_temp.postpone(:'T1', 'L3', 20, '10:00') like 'ERR:LOCKED%' and pg_temp.cancel(:'T1', 'L3') like 'ERR:LOCKED%', 'an INVOICED lesson: refused as LOCKED too');
select t.ok(pg_temp.postpone(:'T1', 'L4', 20, '07:00') not like 'ERR:%', 'a lesson on a REPLACED (no longer current) invoice is not locked by it');
select t.ok(pg_temp.postpone(:'T1', 'L1', 20, '10:00') not like 'ERR:%', 'an ordinary lesson of the same day is fine');
select t.ok((pg_temp.lk('MK')).lesson_date = (select today + 13 from td) and (pg_temp.lk('L2')).lesson_date = (select today + 13 from td) and (pg_temp.lk('L3')).lesson_date = (select today + 13 from td), 'the locked lessons did not move');

-- ===================================================================== 7. the notice window: 0 / 24 / 168 hours, at the edge (the centre's clock)
-- a lesson 20 minutes either side of the notice, a lesson that has started, and one in the past. The move target is always far away.
create function pg_temp.edge(p_notice int, p_label text) returns void language plpgsql as $$
declare k1 text := 'N' || p_notice || 'a'; k2 text := 'N' || p_notice || 'b'; k3 text := 'N' || p_notice || 'c';
begin
  perform pg_temp.settings('tm', '00000000-0000-0000-0000-000000a60001', jsonb_build_object('timetable_editing', 'tutors_direct', 'min_notice_hours', p_notice, 'tutors_edit', '{"postpone":true,"cancel":true}'::jsonb));
  perform pg_temp.mk(k1, '00000000-0000-0000-0000-000000a60101', now() + make_interval(hours => p_notice) - interval '20 minutes', 'm1');      -- too close
  perform pg_temp.mk(k2, '00000000-0000-0000-0000-000000a60101', now() + make_interval(hours => p_notice) + interval '20 minutes', 'm1');      -- far enough
  perform pg_temp.mk(k3, '00000000-0000-0000-0000-000000a60101', now() - interval '30 minutes', 'm1');                                          -- already started
  if p_notice > 0 then
    perform pg_temp.expect('00000000-0000-0000-0000-000000a60004', format('select tutor_postpone_lesson(%L, current_date + 40, ''10:00''::time, ''edge test'')', t.id(k1)), 'TOO_LATE', p_label || ': 20 minutes inside the notice: move refused');
    perform pg_temp.expect('00000000-0000-0000-0000-000000a60004', format('select tutor_cancel_lesson(%L, ''edge test'')', t.id(k1)), 'TOO_LATE', p_label || ': 20 minutes inside the notice: cancel refused');
  else
    perform pg_temp.expect('00000000-0000-0000-0000-000000a60004', format('select tutor_cancel_lesson(%L, ''edge test'')', t.id(k1)), 'PAST', p_label || ': a lesson 20 minutes ago is past');
  end if;
  perform pg_temp.expect('00000000-0000-0000-0000-000000a60004', format('select tutor_postpone_lesson(%L, current_date + 40, ''10:00''::time, ''edge test'')', t.id(k2)), 'ok', p_label || ': 20 minutes outside the notice: move allowed');
  perform pg_temp.expect('00000000-0000-0000-0000-000000a60004', format('select tutor_cancel_lesson(%L, ''edge test'')', t.id(k2)), 'ok', p_label || ': ...and, now moved far away, it can be cancelled');
  perform pg_temp.expect('00000000-0000-0000-0000-000000a60004', format('select tutor_postpone_lesson(%L, current_date + 40, ''10:00''::time, ''edge test'')', t.id(k3)), 'PAST', p_label || ': a lesson that has already started is refused whatever the notice');
end $$;
select pg_temp.edge(0, 'notice 0 h');
select pg_temp.edge(24, 'notice 24 h');
select pg_temp.edge(168, 'notice 168 h');
-- notice 0 and a lesson only 20 minutes away is allowed (nothing in the way but the clock)
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"tutors_direct","min_notice_hours":0}');
select pg_temp.mk('N0near', '00000000-0000-0000-0000-000000a60101', now() + interval '20 minutes', 'm1');
select t.ok(pg_temp.postpone(:'T1', 'N0near', 40, '11:00') not like 'ERR:%', 'notice 0: a lesson starting in 20 minutes can still be moved');
-- no notice setting = 24 hours
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"tutors_direct"}');
select pg_temp.mk('Ndef1', '00000000-0000-0000-0000-000000a60101', now() + interval '23 hours 40 minutes', 'm1');
select pg_temp.mk('Ndef2', '00000000-0000-0000-0000-000000a60101', now() + interval '24 hours 20 minutes', 'm1');
select t.ok(pg_temp.postpone(:'T1', 'Ndef1', 41, '11:00') like 'ERR:TOO_LATE%' and pg_temp.postpone(:'T1', 'Ndef2', 41, '11:00') not like 'ERR:%', 'no notice setting = 24 hours');
select t.ok(pg_temp.postpone(:'T1', 'Ndef1', 41, '11:00') like 'ERR:TOO_LATE: a lesson can only be changed 24 hours or more before it starts%', 'the refusal says the number of hours in plain words');

-- ===================================================================== 8. the monthly limit: at it, and one over
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"tutors_direct","max_changes_per_month":2,"tutors_edit":{"postpone":true,"cancel":true}}');
alter table audit_log disable trigger audit_log_immutable; delete from audit_log where actor = '00000000-0000-0000-0000-000000a60004' and action like 'tutor\_%\_lesson'; alter table audit_log enable trigger audit_log_immutable;     -- test data only (superuser)        -- start this tutor's month clean (test data only)
select pg_temp.mkd('X1', '00000000-0000-0000-0000-000000a60101', 14, '09:00', 'm1');
select pg_temp.mkd('X2', '00000000-0000-0000-0000-000000a60101', 14, '10:00', 'm1');
select pg_temp.mkd('X3', '00000000-0000-0000-0000-000000a60101', 14, '11:00', 'm1');
select pg_temp.mkd('X4', '00000000-0000-0000-0000-000000a60102', 14, '12:00', 'm2');
select t.ok(pg_temp.sch(:'T1', 13, 16)#>>'{orgs,0,changes_left}' = '2', 'two changes left');
select t.ok(pg_temp.postpone(:'T1', 'X1', 21, '09:00') not like 'ERR:%', 'change 1 of 2 is allowed');
select t.ok(pg_temp.sch(:'T1', 13, 16)#>>'{orgs,0,changes_left}' = '1', 'one change left');
select t.ok(pg_temp.cancel(:'T1', 'X2') not like 'ERR:%', 'change 2 of 2 (a cancel counts like a move) is allowed: exactly AT the limit');
select t.ok(pg_temp.sch(:'T1', 13, 16)#>>'{orgs,0,changes_left}' = '0', 'none left');
select t.ok(pg_temp.postpone(:'T1', 'X3', 21, '11:00') like 'ERR:LIMIT: you have used your 2 schedule changes for this month%', 'change 3: one OVER the limit is refused, in plain words');
select pg_temp.mkd('X5', '00000000-0000-0000-0000-000000a60101', 14, '16:00', 'm1');
update lessons set slot_id = '00000000-0000-0000-0000-000000a60201', slot_date = (select today + 10 from td), postponed = true where id = t.id('X5');
select t.ok(pg_temp.revert(:'T1', 'X5') like 'ERR:LIMIT%', 'a revert counts too, so it is refused as well');
select t.ok((select count(*) = 2 from audit_log where actor = '00000000-0000-0000-0000-000000a60004' and action like 'tutor\_%\_lesson'), 'refusals do not count: still two changes');
select t.ok(pg_temp.postpone(:'T2', 'X4', 21, '12:00') not like 'ERR:%', 'the limit is per tutor: tutor two is unaffected');
-- last month's changes don't count
alter table audit_log disable trigger audit_log_immutable; update audit_log set at = at - interval '40 days' where actor = '00000000-0000-0000-0000-000000a60004' and action like 'tutor\_%\_lesson'; alter table audit_log enable trigger audit_log_immutable;
select t.ok(pg_temp.postpone(:'T1', 'X3', 21, '11:00') not like 'ERR:%', 'changes of an earlier month do not count against this month');
-- 0 = no limit, and a missing key = no limit
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"tutors_direct","max_changes_per_month":0}');
select pg_temp.mkd('Y1', '00000000-0000-0000-0000-000000a60101', 15, '09:00', 'm1'); select pg_temp.mkd('Y2', '00000000-0000-0000-0000-000000a60101', 15, '10:00', 'm1');
select pg_temp.mkd('Y3', '00000000-0000-0000-0000-000000a60101', 15, '11:00', 'm1'); select pg_temp.mkd('Y4', '00000000-0000-0000-0000-000000a60101', 15, '12:00', 'm1');
select t.ok(pg_temp.postpone(:'T1', 'Y1', 22, '09:00') not like 'ERR:%' and pg_temp.postpone(:'T1', 'Y2', 22, '10:00') not like 'ERR:%' and pg_temp.postpone(:'T1', 'Y3', 22, '11:00') not like 'ERR:%'
        and pg_temp.postpone(:'T1', 'Y4', 22, '12:00') not like 'ERR:%', '0 = no limit: any number of changes');
select t.ok(pg_temp.sch(:'T1', 13, 16)#>'{orgs,0,changes_left}' = 'null'::jsonb, '...and the screen is told "no limit" (null)');
-- the limit of one
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"tutors_direct","max_changes_per_month":1}');
alter table audit_log disable trigger audit_log_immutable; delete from audit_log where actor = '00000000-0000-0000-0000-000000a60004' and action like 'tutor\_%\_lesson'; alter table audit_log enable trigger audit_log_immutable;     -- test data only (superuser)
select pg_temp.mkd('Z1', '00000000-0000-0000-0000-000000a60101', 16, '09:00', 'm1'); select pg_temp.mkd('Z2', '00000000-0000-0000-0000-000000a60101', 16, '10:00', 'm1');
select t.ok(pg_temp.postpone(:'T1', 'Z1', 23, '09:00') not like 'ERR:%' and pg_temp.postpone(:'T1', 'Z2', 23, '10:00') like 'ERR:LIMIT: you have used your 1 schedule change for this month%', 'a limit of 1: the second is refused ("1 schedule change", singular)');

-- ===================================================================== 9. validations of the new time
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"postpone":true,"cancel":true}}');
select pg_temp.mkd('V1', '00000000-0000-0000-0000-000000a60101', 17, '09:00', 'm1');
select t.ok(pg_temp.postpone(:'T1', 'V1', 24, '10:00', null) like 'ERR:REASON_REQUIRED%' and pg_temp.postpone(:'T1', 'V1', 24, '10:00', '  ') like 'ERR:REASON_REQUIRED%' and pg_temp.postpone(:'T1', 'V1', 24, '10:00', 'ab') like 'ERR:REASON_REQUIRED%'
        and pg_temp.cancel(:'T1', 'V1', null) like 'ERR:REASON_REQUIRED%', 'a reason is required for a move and a cancel (missing, blank, too short)');
select pg_temp.mkd('V1r', '00000000-0000-0000-0000-000000a60101', 17, '18:00', 'm1');
update lessons set slot_id = '00000000-0000-0000-0000-000000a60201', slot_date = (select today + 10 from td), postponed = true where id = t.id('V1r');
select t.ok(pg_temp.revert(:'T1', 'V1r', '') like 'ERR:REASON_REQUIRED%' and pg_temp.revert(:'T1', 'V1r', null) like 'ERR:REASON_REQUIRED%', 'a reason is required for a revert too');
select t.ok(pg_temp.postpone(:'T1', 'V1', 24, '10:00', repeat('x', 301)) like 'ERR:TOO_LONG%', 'a reason over 300 characters is refused');
select t.ok(pg_temp.postpone(:'T1', 'V1', 24, '10:00', repeat('x', 300)) not like 'ERR:%', 'a reason of exactly 300 is fine');
select pg_temp.mkd('V2', '00000000-0000-0000-0000-000000a60101', 17, '10:00', 'm1');
select t.ok(pg_temp.call(:'T1', format('select tutor_postpone_lesson(%L, null, ''10:00''::time, ''a reason'')', t.id('V2'))) like 'ERR:BAD_DATE%'
        and pg_temp.call(:'T1', format('select tutor_postpone_lesson(%L, current_date + 30, null, ''a reason'')', t.id('V2'))) like 'ERR:BAD_DATE%', 'a missing date or start time');
select t.ok(pg_temp.postpone(:'T1', 'V2', -1, '10:00') like 'ERR:BAD_DATE%', 'a day in the past is refused');
select t.ok(pg_temp.postpone(:'T1', 'V2', 366, '10:00') like 'ERR:BAD_DATE%' and pg_temp.postpone(:'T1', 'V2', 365, '10:00') not like 'ERR:%', 'more than a year ahead is refused; exactly a year is fine');
select pg_temp.mkd('V3', '00000000-0000-0000-0000-000000a60101', 17, '11:00', 'm1');
select t.ok(pg_temp.postpone(:'T1', 'V3', 25, '23:30') like 'ERR:BAD_TIME%', 'a 1-hour lesson starting 23:30 would run past midnight');
select t.ok(pg_temp.postpone(:'T1', 'V3', 25, '22:59') not like 'ERR:%', 'one that ends before midnight is fine');
-- today, later than now (inside the day)
select pg_temp.mkd('V4', '00000000-0000-0000-0000-000000a60101', 17, '12:00', 'm1');
select t.ok(pg_temp.postpone(:'T1', 'V4', 0, '00:01') like 'ERR:BAD_DATE: that time has already passed%' or (select extract(epoch from (now() at time zone 'Asia/Singapore')::time) < 60 from (select 1) x), 'a time earlier today has passed (the centre''s clock)');
-- holidays
insert into holidays(org_id, name, starts_on, ends_on) values (t.id('tm'), 'Founders'' Day', (select today + 26 from td), (select today + 27 from td));
insert into branches(id, org_id, name) values ('00000000-0000-0000-0000-000000a60951', t.id('tm'), 'Bishan');
insert into holidays(org_id, branch_id, name, starts_on, ends_on) values (t.id('tm'), '00000000-0000-0000-0000-000000a60951', 'Bishan only', (select today + 28 from td), (select today + 28 from td));
select t.ok(pg_temp.postpone(:'T1', 'V4', 26, '10:00') like 'ERR:HOLIDAY: Founders'' Day is a holiday at this centre%' and pg_temp.postpone(:'T1', 'V4', 27, '10:00') like 'ERR:HOLIDAY%', 'a whole-centre holiday (first and last day) is refused, naming it');
select t.ok(pg_temp.postpone(:'T1', 'V4', 28, '10:00') not like 'ERR:%', 'a branch-only holiday does not block (lessons carry no branch)');
-- a clash with the tutor's OWN other lesson (names only their own student); another tutor's lesson at that time is not a clash
select pg_temp.mkd('K1', '00000000-0000-0000-0000-000000a60104', 18, '10:00', 'm1');          -- Kid Four 10:00-11:00 with tutor one
select pg_temp.mkd('K2', '00000000-0000-0000-0000-000000a60101', 19, '09:00', 'm1');
select pg_temp.mkd('K3', '00000000-0000-0000-0000-000000a60102', 18, '10:00', 'm2');          -- tutor two teaches at the same time: no clash for tutor one
select t.ok(pg_temp.postpone(:'T1', 'K2', 18, '10:30') like 'ERR:CLASH: you already teach Kid Four at that time%', 'moving onto another of YOUR lessons is refused, naming your own student');
select t.ok(pg_temp.postpone(:'T1', 'K2', 18, '11:00') not like 'ERR:%', 'back-to-back (11:00 right after 10:00-11:00) is fine');
update lessons set status = 'cancelled' where id = t.id('K1');
select pg_temp.mkd('K4', '00000000-0000-0000-0000-000000a60101', 19, '09:00', 'm1');
select t.ok(pg_temp.postpone(:'T1', 'K4', 18, '10:00') not like 'ERR:%', 'a cancelled lesson of yours does not clash, and another tutor''s lesson never does');

-- ===================================================================== 10. classes move together, all or nothing
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"postpone":true,"cancel":true}}');
select pg_temp.mkd('G1', '00000000-0000-0000-0000-000000a60101', 20, '11:00', 'm1'); select pg_temp.mkd('G2', '00000000-0000-0000-0000-000000a60104', 20, '11:00', 'm1');
update lessons set session_id = '00000000-0000-0000-0000-000000a60401' where id in (t.id('G1'), t.id('G2'));
select pg_temp.postpone(:'T1', 'G1', 32, '14:00', 'class moved') as r \gset
select t.ok((:'r'::jsonb->>'lessons')::int = 2 and (pg_temp.lk('G1')).lesson_date = (select today + 32 from td) and (pg_temp.lk('G2')).lesson_date = (select today + 32 from td)
        and (pg_temp.lk('G2')).start_time = '14:00' and (pg_temp.lk('G2')).postponed, 'a class moves together: both lessons, one action');
select t.ok((select count(*) = 1 from audit_log where action = 'tutor_postpone_lesson' and org_id = t.id('tm') and after->>'reason' = 'class moved' and jsonb_array_length(after->'lessons') = 2), 'one audit row for the class, listing both lessons');
select pg_temp.mkd('G3', '00000000-0000-0000-0000-000000a60101', 21, '11:00', 'm1'); select pg_temp.mkd('G4', '00000000-0000-0000-0000-000000a60104', 21, '11:00', 'm1');
update lessons set session_id = '00000000-0000-0000-0000-000000a60402' where id in (t.id('G3'), t.id('G4'));
update lessons set paid = true where id = t.id('G4');
select t.ok(pg_temp.postpone(:'T1', 'G3', 28, '14:00') like 'ERR:LOCKED%(it is part of a class that changes together)%' and pg_temp.cancel(:'T1', 'G3') like 'ERR:LOCKED%', 'a class with one PAID lesson: the whole class is refused');
select t.ok((pg_temp.lk('G3')).lesson_date = (select today + 21 from td) and not (pg_temp.lk('G3')).postponed and (pg_temp.lk('G3')).status = 'scheduled', 'and nothing of it moved or was cancelled');
select pg_temp.mkd('G5', '00000000-0000-0000-0000-000000a60101', 22, '11:00', 'm1'); select pg_temp.mkd('G6', '00000000-0000-0000-0000-000000a60102', 22, '11:00', 'm2');
update lessons set session_id = '00000000-0000-0000-0000-000000a60403' where id in (t.id('G5'), t.id('G6'));
select t.ok(pg_temp.postpone(:'T1', 'G5', 29, '14:00') like 'ERR:GROUP_NOT_YOURS%' and pg_temp.cancel(:'T1', 'G5') like 'ERR:GROUP_NOT_YOURS%', 'a class that includes another tutor''s lesson: refused, nothing moves');
select t.ok((pg_temp.lk('G5')).lesson_date = (select today + 22 from td) and (pg_temp.lk('G6')).lesson_date = (select today + 22 from td), '...for either lesson');
select pg_temp.mkd('G7', '00000000-0000-0000-0000-000000a60101', 23, '11:00', 'm1'); select pg_temp.mkd('G8', '00000000-0000-0000-0000-000000a60104', 23, '11:00', 'm1');
update lessons set session_id = '00000000-0000-0000-0000-000000a60404' where id in (t.id('G7'), t.id('G8'));
select pg_temp.cancel(:'T1', 'G7', 'class cancelled') as r \gset
select t.ok((:'r'::jsonb->>'lessons')::int = 2 and (pg_temp.lk('G7')).status = 'cancelled' and (pg_temp.lk('G8')).status = 'cancelled' and (pg_temp.lk('G8')).compensation = 0, 'a class is cancelled together, each lesson at no charge');

-- ===================================================================== 11. the centre's time zone (UTC+14: its day is ahead of the server's)
select pg_temp.settings('tk', '00000000-0000-0000-0000-000000a6000c', '{"timetable_editing":"tutors_direct","min_notice_hours":1,"tutors_edit":{"postpone":true,"cancel":true}}');
select pg_temp.mk('KA', '00000000-0000-0000-0000-000000a60105', now() + interval '30 minutes', 'mk', 'tk', 'Pacific/Kiritimati');
select pg_temp.mk('KB', '00000000-0000-0000-0000-000000a60105', now() + interval '80 minutes', 'mk', 'tk', 'Pacific/Kiritimati');
select pg_temp.mk('KC', '00000000-0000-0000-0000-000000a60105', now() - interval '30 minutes', 'mk', 'tk', 'Pacific/Kiritimati');
select t.ok((pg_temp.lk('KA')).lesson_date = (now() at time zone 'Pacific/Kiritimati')::date, 'the test lesson is on the centre''s own calendar day');
select pg_temp.call('00000000-0000-0000-0000-000000a6000d', format('select tutor_postpone_lesson(%L, (now() at time zone ''Pacific/Kiritimati'')::date + 5, ''10:00''::time, ''zone test'')', t.id('KA'))) as ka \gset
select pg_temp.call('00000000-0000-0000-0000-000000a6000d', format('select tutor_postpone_lesson(%L, (now() at time zone ''Pacific/Kiritimati'')::date + 5, ''10:00''::time, ''zone test'')', t.id('KB'))) as kb \gset
select pg_temp.call('00000000-0000-0000-0000-000000a6000d', format('select tutor_postpone_lesson(%L, (now() at time zone ''Pacific/Kiritimati'')::date + 5, ''10:00''::time, ''zone test'')', t.id('KC'))) as kc \gset
select t.ok(:'ka' like 'ERR:TOO_LATE%', 'in a UTC+14 centre, a lesson 30 minutes away (its own clock) is inside a 1-hour notice');
select t.ok(:'kb' not like 'ERR:%', 'one 80 minutes away is fine');
select t.ok(:'kc' like 'ERR:PAST%', 'one that started 30 minutes ago is past, whatever the server''s date says');
select t.ok((pg_temp.lk('KB')).lesson_date = (now() at time zone 'Pacific/Kiritimati')::date + 5, 'it moved to the centre''s own day');
select t.ok(pg_temp.sch('00000000-0000-0000-0000-000000a6000d', 0, 6)#>>'{orgs,0,today}' = ((now() at time zone 'Pacific/Kiritimati')::date)::text, 'the screen is told the centre''s own today');

-- ===================================================================== 12. what the schedule screen is told
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"tutors_direct","min_notice_hours":24,"max_changes_per_month":0,"tutors_edit":{"postpone":true,"cancel":false}}');
select pg_temp.mkd('S1', '00000000-0000-0000-0000-000000a60101', 30, '10:00', 'm1');
select pg_temp.mk('S2', '00000000-0000-0000-0000-000000a60101', now() + interval '3 hours', 'm1');
select pg_temp.sch(:'T1', 0, 31) as one \gset
select t.ok((:'one'::jsonb#>>'{orgs,0,timetable_editing}') = 'tutors_direct' and (:'one'::jsonb#>>'{orgs,0,can_edit}')::boolean and (:'one'::jsonb#>>'{orgs,0,can_postpone}')::boolean
        and not (:'one'::jsonb#>>'{orgs,0,can_cancel}')::boolean and (:'one'::jsonb#>>'{orgs,0,min_notice_hours}') = '24', 'the centre part says what is switched on and the notice');
select t.ok((select (e->>'can_postpone')::boolean and not (e->>'can_cancel')::boolean and e->>'change_block' is null from jsonb_array_elements(:'one'::jsonb->'lessons') e where e->>'lesson_id' = t.id('S1')::text), 'a lesson far away: Move yes, Cancel no (switch off), nothing to explain');
select t.ok((select not (e->>'can_postpone')::boolean and e->>'change_block' = 'TOO_LATE' from jsonb_array_elements(:'one'::jsonb->'lessons') e where e->>'lesson_id' = t.id('S2')::text), 'a lesson in 3 hours: no buttons, and the screen is told TOO_LATE');
select t.ok((select not (e->>'can_postpone')::boolean and not (e->>'can_revert')::boolean and not (e->>'can_cancel')::boolean from jsonb_array_elements(:'one'::jsonb->'lessons') e where e->>'lesson_id' = t.id('MK')::text), 'a marked lesson: no buttons');
select t.ok((select (e->>'can_revert')::boolean from jsonb_array_elements(pg_temp.sch(:'T1', 0, 31)->'lessons') e where e->>'lesson_id' = t.id('Y1')::text) is not true, 'a moved one-off lesson has no Revert');
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"admin_only"}');
select t.ok(not exists (select 1 from jsonb_array_elements(pg_temp.sch(:'T1', 0, 31)->'lessons') e where (e->>'can_postpone')::boolean or (e->>'can_revert')::boolean or (e->>'can_cancel')::boolean)
        and (pg_temp.sch(:'T1', 0, 31)#>>'{orgs,0,can_edit}') = 'false', 'admin_only: no lesson offers any button');
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"postpone":true,"cancel":true}}');
select t.ok((select (e->>'can_cancel')::boolean from jsonb_array_elements(pg_temp.sch(:'T1', 0, 31)->'lessons') e where e->>'lesson_id' = t.id('S1')::text), 'with the cancel switch on, Cancel is offered');
select t.ok(not exists (select 1 from jsonb_array_elements(pg_temp.sch(:'T2', 0, 31)->'lessons') e where e->>'lesson_id' in (t.id('A')::text, t.id('S1')::text)), 'tutor two''s week holds none of tutor one''s lessons');

-- ===================================================================== 13. staff: the Tutor changes list
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"tutors_direct","notify_family":"list_for_admin","tutors_edit":{"postpone":true,"cancel":true}}');
select pg_temp.mkd('F1', '00000000-0000-0000-0000-000000a60101', 31, '10:00', 'm1');
select pg_temp.cancel(:'T1', 'F1', 'tutor has a clash') as r \gset
select pg_temp.call(:'STAFF', format('select staff_tutor_changes(%L)', t.id('tm'))) as sc \gset
select t.ok((:'sc'::jsonb->>'tell_family')::boolean and (select bool_and((e->>'tell_family')::boolean) from jsonb_array_elements(:'sc'::jsonb->'rows') e), 'list_for_admin: staff are told the family needs telling');
select t.ok((select count(*) = 1 from jsonb_array_elements(:'sc'::jsonb->'rows') e where e->>'lesson_id' = t.id('F1')::text and e->>'what' = 'cancelled' and (e->>'cancelled')::boolean and e->>'reason' = 'tutor has a clash'
               and e->>'tutor_name' = 'Tutor One'), 'the cancel is listed with the tutor and the reason');
select t.ok((:'sc'::jsonb->'rows'->0->>'changed_at')::timestamptz >= all (select (e->>'changed_at')::timestamptz from jsonb_array_elements(:'sc'::jsonb->'rows') e), 'newest first');
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"tutors_direct","notify_family":"off"}');
select pg_temp.call(:'OWNER', format('select staff_tutor_changes(%L)', t.id('tm'))) as sc \gset
select t.ok(not (:'sc'::jsonb->>'tell_family')::boolean and jsonb_array_length(:'sc'::jsonb->'rows') > 0 and (select bool_and(not (e->>'tell_family')::boolean) from jsonb_array_elements(:'sc'::jsonb->'rows') e), 'notify_family off: the list is still shown, but without "tell the family"');
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"tutors_direct"}');
select t.ok((pg_temp.call(:'OWNER', format('select staff_tutor_changes(%L)', t.id('tm')))::jsonb->>'tell_family')::boolean, 'no notify_family key = list_for_admin (the default)');
select pg_temp.expect(:'VIEWER', format('select staff_tutor_changes(%L)', t.id('tm')), 'NOT_ALLOWED', 'staff WITHOUT manage_timetable');
select pg_temp.expect(:'T1', format('select staff_tutor_changes(%L)', t.id('tm')), 'NOT_FOUND', 'a tutor');
select pg_temp.expect('00000000-0000-0000-0000-000000a60008', format('select staff_tutor_changes(%L)', t.id('tm')), 'NOT_FOUND', 'a parent');
select pg_temp.expect('00000000-0000-0000-0000-000000a60006', format('select staff_tutor_changes(%L)', t.id('tm')), 'NOT_FOUND', 'a solo tutor');
select pg_temp.expect('00000000-0000-0000-0000-000000a60009', format('select staff_tutor_changes(%L)', t.id('tm')), 'NOT_FOUND', 'the owner of ANOTHER centre');
select pg_temp.expect(:'OWNER', format('select staff_tutor_changes(%L)', t.id('tm2')), 'NOT_FOUND', 'this owner asking about ANOTHER centre');
select pg_temp.expect(:'OWNER', 'select staff_tutor_changes(null)', 'NOT_FOUND', 'no centre given');
select t.ok(not exists (select 1 from jsonb_array_elements(pg_temp.call('00000000-0000-0000-0000-000000a60009', format('select staff_tutor_changes(%L)', t.id('tm2')))::jsonb->'rows') e), 'the other centre''s list is empty (nothing of this centre leaks)');
-- only the last 7 days, newest first
select set_config('request.jwt.claims', '', false);
update lessons set changed_by_tutor_at = now() - interval '8 days' where id = t.id('F1');
select t.ok(not exists (select 1 from jsonb_array_elements(pg_temp.call(:'STAFF', format('select staff_tutor_changes(%L)', t.id('tm')))::jsonb->'rows') e where e->>'lesson_id' = t.id('F1')::text), 'a change older than 7 days is no longer listed');
select set_config('request.jwt.claims', '', false);
update lessons set changed_by_tutor_at = now() - interval '6 days 23 hours' where id = t.id('F1');
select t.ok(exists (select 1 from jsonb_array_elements(pg_temp.call(:'STAFF', format('select staff_tutor_changes(%L)', t.id('tm')))::jsonb->'rows') e where e->>'lesson_id' = t.id('F1')::text), '...but one from 6 days 23 hours ago still is');
-- a tutor who has since been switched off is named 'Former tutor'
update memberships set status = 'disabled' where id = t.id('m1');
select t.ok(exists (select 1 from jsonb_array_elements(pg_temp.call(:'STAFF', format('select staff_tutor_changes(%L)', t.id('tm')))::jsonb->'rows') e where e->>'lesson_id' = t.id('F1')::text and e->>'tutor_name' = 'Former tutor'), 'a switched-off tutor shows as Former tutor');
update memberships set status = 'active' where id = t.id('m1');
-- a change made by a tutor shows no money
select t.ok(not exists (select 1 from pg_temp.keys(pg_temp.call(:'STAFF', format('select staff_tutor_changes(%L)', t.id('tm')))::jsonb) k where k ~* '(rate|price|amount|paid|compens|charge|fee|cents|cost|balance|invoice)'), 'no key of the staff list is a money word');

-- ===================================================================== 14. no money anywhere a tutor can read, no table access
select pg_temp.settings('tm', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"postpone":true,"cancel":true}}');
select pg_temp.mkd('M1', '00000000-0000-0000-0000-000000a60101', 33, '10:00', 'm1');
select pg_temp.postpone(:'T1', 'M1', 34, '10:00') as pr \gset
select pg_temp.sch(:'T1', 0, 40) as one \gset
select t.ok(not exists (select 1 from pg_temp.keys(:'one'::jsonb) k where k ~* '(rate|price|amount|paid|compens|charge|fee|cents|cost|fare|owe|balance|invoice)'), 'tutor_my_schedule: no returned key is a money word');
select t.ok(not exists (select 1 from pg_temp.keys(:'pr'::jsonb) k where k ~* '(rate|price|amount|paid|compens|charge|fee|cents|cost|fare|owe|balance|invoice)'), 'a move''s answer: no key is a money word');
select t.ok(:'one'::text !~ '(777\.77|888\.88|555\.55|666\.66|SECRETNOTE)' and :'pr'::text !~ '(777\.77|888\.88|555\.55|666\.66|SECRETNOTE)', 'the marker money values appear nowhere in what a tutor receives');
select t.ok(pg_temp.postpone(:'T1', 'M1', 34, '10:00') like 'ERR:NO_CHANGE%' and pg_temp.postpone(:'T1', 'M1', 34, '10:00') !~ '(777\.77|888\.88|SECRETNOTE)', 'refusals carry no money either');
select t.ok(not exists (select 1 from pg_proc p where p.proname in ('tutor_postpone_lesson', 'tutor_revert_lesson', 'tutor_cancel_lesson', 'tutor_my_schedule', 'staff_tutor_changes', 'tutor_change_block')
                         and pg_get_functiondef(p.oid) ~* '\m(rate|price|amount|paid|compensation|charge_note|charge|fee|cost|invoice[a-z]*|[a-z_]*_cents)\M'), 'no money word (not even paid or invoiced) in the text of the tutor functions, the staff list or the rulebook');
select t.ok(not exists (select 1 from pg_proc p where p.proname in ('tutor_postpone_lesson', 'tutor_revert_lesson', 'tutor_cancel_lesson', 'tutor_my_schedule', 'staff_tutor_changes', 'tutor_change_block', 'tutor_change_apply')
                         and pg_get_functiondef(p.oid) ~ '\m[a-z]+\.\*'), 'none of them selects a whole row (no x.*) except by name');
select t.ok((select count(*) = 1 from regexp_matches((select pg_get_functiondef(oid) from pg_proc where proname = 'tutor_change_apply'), 'compensation', 'g'))
        and (select pg_get_functiondef(oid) from pg_proc where proname = 'tutor_change_apply') !~* '\m(rate|price|amount|paid|charge_note|[a-z_]*_cents)\M', 'the only money column a function WRITES is the cancel''s "charge 0", once');
select t.ok(not exists (select 1 from pg_proc p where p.proname in ('tutor_postpone_lesson', 'tutor_revert_lesson', 'tutor_cancel_lesson', 'tutor_my_schedule', 'staff_tutor_changes', 'tutor_change_block', 'tutor_change_apply')
                         and (not p.prosecdef or p.proconfig::text not like '%search_path=public%')), 'all are SECURITY DEFINER with a pinned search_path');
select t.ok(has_function_privilege('authenticated', 'tutor_postpone_lesson(uuid,date,time,text)', 'execute') and has_function_privilege('authenticated', 'tutor_revert_lesson(uuid,text)', 'execute')
        and has_function_privilege('authenticated', 'tutor_cancel_lesson(uuid,text)', 'execute') and has_function_privilege('authenticated', 'staff_tutor_changes(uuid)', 'execute')
        and not has_function_privilege('anon', 'tutor_postpone_lesson(uuid,date,time,text)', 'execute') and not has_function_privilege('anon', 'tutor_cancel_lesson(uuid,text)', 'execute')
        and not has_function_privilege('anon', 'staff_tutor_changes(uuid)', 'execute'), 'signed-in users may call the four; anonymous may not');
select t.ok(not has_function_privilege('authenticated', 'tutor_change_apply(uuid,text,date,time,text)', 'execute') and not has_function_privilege('authenticated', 'tutor_change_block(uuid,text)', 'execute')
        and not has_function_privilege('anon', 'tutor_change_apply(uuid,text,date,time,text)', 'execute'), 'the worker and the rulebook can''t be called from the browser (a tutor can''t skip the checks)');
-- a tutor still has NO table access (rows hidden / writes impossible)
select pg_temp.call(:'T1', $q$ select count(*)::text from lessons $q$) as n \gset
select t.ok(:'n' = '0' or :'n' like 'ERR:%', 'a tutor reads no row of lessons');
select pg_temp.call(:'T1', format($q$ with u as (update lessons set lesson_date = lesson_date + 1 where id = %L returning 1) select count(*)::text from u $q$, t.id('M1'))) as n \gset
select t.ok(:'n' = '0' or :'n' like 'ERR:%', 'a tutor cannot UPDATE a lesson directly (not even their own)');
select pg_temp.call(:'T1', format($q$ with u as (update lessons set status = 'cancelled' where id = %L returning 1) select count(*)::text from u $q$, t.id('M1'))) as n \gset
select t.ok(:'n' = '0' or :'n' like 'ERR:%', '...nor cancel it directly');
select pg_temp.call(:'T1', format($q$ with d as (delete from lessons where id = %L returning 1) select count(*)::text from d $q$, t.id('M1'))) as n \gset
select t.ok(:'n' = '0' or :'n' like 'ERR:%', '...nor delete it');
select t.ok(pg_temp.call(:'T1', format($q$ insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, taught_by) values (%L, %L, %L, current_date + 50, '10:00', '11:00', 1, %L) $q$,
        :'T1', t.id('tm'), '00000000-0000-0000-0000-000000a60101', t.id('m1'))) like 'ERR:%', 'a tutor cannot INSERT a lesson directly');
select pg_temp.call(:'T1', $q$ with u as (update student_tutors set active = false returning 1) select count(*)::text from u $q$) as n \gset
select t.ok(:'n' = '0' or :'n' like 'ERR:%', 'a tutor cannot change who is assigned to them');
select pg_temp.call(:'T1', $q$ with u as (update audit_log set action = 'x' returning 1) select count(*)::text from u $q$) as n \gset
select t.ok(:'n' = '0' or :'n' like 'ERR:%', 'a tutor cannot touch the audit log');
select t.ok((select count(*) = 0 from audit_log where action = 'x'), 'and it is intact');
-- the tutor's moved lesson really is where the function put it, and the solo organisation's rows were never involved
select t.ok((pg_temp.lk('M1')).lesson_date = (select today + 34 from td), 'the one lesson that was moved is on its new day');
select t.ok((select count(*) = 0 from lessons l join organisations o on o.id = l.org_id where o.kind = 'solo' and l.changed_by_tutor_at is not null), 'no solo organisation''s lesson was changed by any of this');
-- the lesson row the audit trigger saw: the function's change is logged by the table trigger as well
select t.ok((select count(*) >= 1 from audit_log where table_name = 'lessons' and action = 'update' and row_id = t.id('M1')::text and (after->>'changed_by_tutor_what') = 'moved'), 'the lessons table audit trigger logged the row change too');
