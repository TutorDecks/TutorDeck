-- B8-FIX F6 tests: trial lessons earn no make-up credit unless the centre chose it (billing.credits.earn_trials, db/migration_b8_fix.sql).
-- Every value of the setting (missing, false, true, and bad ones) x a trial and an ordinary lesson; the validator. Runs after migration_b8_fix.sql in the same throwaway database (reuses t.* helpers).
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-000000b88001', 'b8c.owner@centre.test'),  ('00000000-0000-0000-0000-000000b88002', 'b8c.staff@centre.test'),
  ('00000000-0000-0000-0000-000000b88003', 'b8c.viewer@centre.test'), ('00000000-0000-0000-0000-000000b88004', 'b8c.tutor1@centre.test'),
  ('00000000-0000-0000-0000-000000b88005', 'b8c.tutor2@centre.test'), ('00000000-0000-0000-0000-000000b88006', 'b8c.solo@centre.test'),
  ('00000000-0000-0000-0000-000000b88007', 'b8c.off@centre.test'),   ('00000000-0000-0000-0000-000000b88008', 'b8c.parent@centre.test'),
  ('00000000-0000-0000-0000-000000b88009', 'b8c.owner2@centre.test'), ('00000000-0000-0000-0000-000000b8800a', 'b8c.outsider@centre.test'),
  ('00000000-0000-0000-0000-000000b8800b', 'b8c.invoicer@centre.test');
set role authenticated; select t.as('00000000-0000-0000-0000-000000b88001');
select t.put('mc', org_create_centre('B8 Credits Centre', t.centre_settings()));
select t.as('00000000-0000-0000-0000-000000b88009');
select t.put('mc2', org_create_centre('Other B8 Credits Centre', t.centre_settings()));
reset role; select set_config('request.jwt.claims', '', false);
select t.put('solo', org_personal('00000000-0000-0000-0000-000000b88006'));
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('mc'), '00000000-0000-0000-0000-000000b88002', 'Staff Sam',    'staff', array['manage_timetable'], 'active'),
  (t.id('mc'), '00000000-0000-0000-0000-000000b88003', 'Staff Viewer', 'staff', '{}', 'active'),
  (t.id('mc'), '00000000-0000-0000-0000-000000b88004', 'Tutor One',    'tutor', '{}', 'active'),
  (t.id('mc'), '00000000-0000-0000-0000-000000b88005', 'Tutor Two',    'tutor', '{}', 'active'),
  (t.id('mc'), '00000000-0000-0000-0000-000000b88007', 'Switched off', 'staff', array['manage_timetable'], 'disabled'),
  (t.id('mc'), '00000000-0000-0000-0000-000000b88008', 'A Parent',     'parent', '{}', 'active'),
  (t.id('mc'), '00000000-0000-0000-0000-000000b8800b', 'Invoicer',     'staff', array['issue_invoices'], 'active');
select t.put('m1', (select id from memberships where org_id = t.id('mc') and user_id = '00000000-0000-0000-0000-000000b88004'));
select t.put('m2', (select id from memberships where org_id = t.id('mc') and user_id = '00000000-0000-0000-0000-000000b88005'));
select t.put('ms', (select id from memberships where org_id = t.id('mc') and user_id = '00000000-0000-0000-0000-000000b88002'));

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today;
grant select on td to authenticated, anon;
insert into students(id, tutor_id, org_id, name, level, contact) values
  ('00000000-0000-0000-0000-000000b88101', '00000000-0000-0000-0000-000000b88001', t.id('mc'), 'Kid One',   'P1', '91110001'),
  ('00000000-0000-0000-0000-000000b88102', '00000000-0000-0000-0000-000000b88001', t.id('mc'), 'Kid Two',   'P2', '91110002'),
  ('00000000-0000-0000-0000-000000b88103', '00000000-0000-0000-0000-000000b88001', t.id('mc'), 'Kid Three', 'P3', '91110003'),
  ('00000000-0000-0000-0000-000000b88104', '00000000-0000-0000-0000-000000b88001', t.id('mc'), 'Kid Four (no lessons yet)', 'P4', '91110004'),
  ('00000000-0000-0000-0000-000000b88105', '00000000-0000-0000-0000-000000b88001', t.id('mc'), 'Kid Five',  'P5', '91110005'),
  ('00000000-0000-0000-0000-000000b88106', '00000000-0000-0000-0000-000000b88001', t.id('mc'), 'Kid Six (invoice tests)', 'P6', '91110006'),
  ('00000000-0000-0000-0000-000000b881f1', '00000000-0000-0000-0000-000000b88009', t.id('mc2'), 'Kid elsewhere', 'P1', '91119999');
insert into student_tutors(org_id, student_id, membership_id) values
  (t.id('mc'), '00000000-0000-0000-0000-000000b88101', t.id('m1')), (t.id('mc'), '00000000-0000-0000-0000-000000b88102', t.id('m1')),
  (t.id('mc'), '00000000-0000-0000-0000-000000b88103', t.id('m2'));
select t.eq((select count(*) from branches where org_id = t.id('mc')) + (select count(*) from rooms where org_id = t.id('mc')), 0, 'the test centre has no branch and no room (remote 1-to-1)');

\set OWN '00000000-0000-0000-0000-000000b88001'
\set STF '00000000-0000-0000-0000-000000b88002'
\set VIEW '00000000-0000-0000-0000-000000b88003'
\set TU1 '00000000-0000-0000-0000-000000b88004'
\set TU2 '00000000-0000-0000-0000-000000b88005'
\set SOLO '00000000-0000-0000-0000-000000b88006'
\set OFF '00000000-0000-0000-0000-000000b88007'
\set PAR '00000000-0000-0000-0000-000000b88008'
\set OWN2 '00000000-0000-0000-0000-000000b88009'
\set OUT '00000000-0000-0000-0000-000000b8800a'
\set INV '00000000-0000-0000-0000-000000b8800b'
\set K1 '00000000-0000-0000-0000-000000b88101'
\set K2 '00000000-0000-0000-0000-000000b88102'
\set K3 '00000000-0000-0000-0000-000000b88103'
\set K4 '00000000-0000-0000-0000-000000b88104'
\set K5 '00000000-0000-0000-0000-000000b88105'
\set K6 '00000000-0000-0000-0000-000000b88106'
\set KX '00000000-0000-0000-0000-000000b881f1'

-- ---- helpers (session-local)
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
-- save the centre's settings as its owner (every credit key is a parameter)
create function pg_temp.cfg(p_rule text default 'one_per_missed', p_abs text default 'notice_only', p_tc text default 'staff_decide', p_hol boolean default false,
                            p_grant text default 'manage_timetable', p_book text default 'manage_timetable', p_price text default 'free', p_exp int default 0,
                            p_lessons jsonb default '{}', p_org text default 'mc', p_owner text default '00000000-0000-0000-0000-000000b88001') returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_owner, 'role', 'authenticated')::text, false);
  set local role authenticated;
  perform org_save_settings(t.id(p_org), jsonb_set(jsonb_set(t.centre_settings(), '{lessons}', p_lessons), '{billing}',
            jsonb_build_object('model', 'postpaid_lessons', 'credit_expiry_days', p_exp,
              'credits', jsonb_build_object('rule', p_rule, 'earn_absences', p_abs, 'earn_tutor_cancel', p_tc, 'earn_holiday', p_hol,
                                            'grant_by', p_grant, 'book_by', p_book, 'makeup_price', p_price))), current_date);
  reset role;
end $$;
-- a one-hour lesson at S$60 on a day (relative to today) and start time
create function pg_temp.les(p_key text, p_student text, p_day int, p_start time, p_tutor text default null, p_status text default 'scheduled') returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, paid, status, taught_by, subject, level)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000b88001', t.id('mc'), p_student::uuid, (select today + p_day from td), p_start, p_start + interval '1 hour',
          60, 60, false, p_status, case when p_tutor is null then null else t.id(p_tutor) end, 'Math', 'P1') returning id into v;
  perform t.put(p_key, v);
  return v;
end $$;
create function pg_temp.mark(p_user text, p_key text, p_att text) returns text language sql as $$
  select pg_temp.call(p_user, format('select staff_mark_attendance(%L, %L)', t.id(p_key), p_att)) $$;
create function pg_temp.ncred(p_key text) returns int language sql as $$ select count(*)::int from makeup_credits where source_lesson_id = t.id(p_key) $$;
create function pg_temp.cid(p_key text) returns uuid language sql as $$ select id from makeup_credits where source_lesson_id = t.id(p_key) $$;
create function pg_temp.cst(p_credit uuid) returns text language sql as $$ select status from makeup_credits where id = p_credit $$;
create function pg_temp.nev(p_credit uuid, p_kind text) returns int language sql as $$ select count(*)::int from makeup_credit_events where credit_id = p_credit and kind = p_kind $$;
create function pg_temp.keys(j jsonb) returns setof text language sql as $$
  with recursive r(v, k) as (
    select j, null::text
    union all
    select c.value, c.key from r, lateral (
      select e.key, e.value from jsonb_each(case when jsonb_typeof(r.v) = 'object' then r.v else '{}'::jsonb end) e
      union all
      select null::text, a.value from jsonb_array_elements(case when jsonb_typeof(r.v) = 'array' then r.v else '[]'::jsonb end) a) c)
  select k from r where k is not null $$;
-- a credit, granted by hand, for a student (returns its id)
create function pg_temp.grant_for(p_student text, p_reason text) returns uuid language plpgsql as $$
begin
  return (pg_temp.call('00000000-0000-0000-0000-000000b88002', format('select (staff_grant_credit(%L, %L, %L)->>%L)', t.id('mc'), p_student, p_reason, 'credit_id')))::uuid;
end $$;
select set_config('request.jwt.claims', '', false);


-- ===================================================================== F6. trial lessons and make-up credits
-- the settings with an earn_trials value (null = the key is missing); the rest is the usual one-credit-per-missed-lesson centre
create function pg_temp.cfg_trials(p_val jsonb) returns void language plpgsql as $$
declare c jsonb := jsonb_build_object('rule', 'one_per_missed', 'earn_absences', 'all_missed', 'earn_tutor_cancel', 'staff_decide', 'earn_holiday', false,
                                      'grant_by', 'manage_timetable', 'book_by', 'manage_timetable', 'makeup_price', 'free');
begin
  if p_val is not null then c := c || jsonb_build_object('earn_trials', p_val); end if;
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-000000b88001', 'role', 'authenticated')::text, false);
  set local role authenticated;
  perform org_save_settings(t.id('mc'), jsonb_set(t.centre_settings(), '{billing}', jsonb_build_object('model', 'postpaid_lessons', 'credit_expiry_days', 0, 'credits', c)), current_date);
  reset role;
end $$;
-- a lesson (trial or not) marked with a missed-lesson mark; returns how many credits it earned
create function pg_temp.missed(p_key text, p_trial boolean, p_n int) returns int language plpgsql as $$
begin
  perform pg_temp.les(p_key, '00000000-0000-0000-0000-000000b88102', -2, ('06:00'::time + (p_n || ' hours')::interval)::time, 'm1');
  update lessons set trial = p_trial where id = t.id(p_key);
  perform pg_temp.mark('00000000-0000-0000-0000-000000b88002', p_key, 'cancelled_early');
  return pg_temp.ncred(p_key);
end $$;

create function pg_temp.save(p_billing jsonb, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'ok';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-000000b88001', 'role', 'authenticated')::text, false);
  set local role authenticated;
  begin perform org_save_settings(t.id('mc'), jsonb_set(t.centre_settings(), '{billing}', jsonb_build_object('model', 'postpaid_lessons') || p_billing), current_date);
  exception when others then m := sqlerrm; end;
  reset role;
  if p_expect = 'ok' and m <> 'ok' then raise exception 'FAIL: % (refused: %)', p_msg, m; end if;
  if p_expect <> 'ok' and m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS %: %', case when p_expect = 'ok' then 'saved' else 'refused' end, p_msg;
end $$;
-- the validator: both values save; anything that is not a real yes/no is refused; a centre that never saved the key is fine
select pg_temp.save('{}', 'ok', 'no earn_trials key at all (a centre that saved before this migration)');
select pg_temp.save(format('{"credits":{"earn_trials":%s}}', v)::jsonb, 'ok', 'earn_trials = ' || v) from unnest(array['true', 'false']) v;
select pg_temp.save('{"credits":{"earn_trials":"yes"}}', 'Setting {billing,credits,earn_trials} must be yes or no', 'earn_trials as text is refused');
select pg_temp.save('{"credits":{"earn_trials":1}}', 'Setting {billing,credits,earn_trials} must be yes or no', 'earn_trials as a number is refused');

-- missing key = the default = OFF
select pg_temp.cfg_trials(null);
select t.eq(pg_temp.missed('T1', true, 1), 0, 'earn_trials missing (default off): a missed TRIAL lesson earns no credit');
select t.eq(pg_temp.missed('T2', false, 2), 1, 'earn_trials missing: an ordinary missed lesson still earns its credit');
-- false
select pg_temp.cfg_trials('false'::jsonb);
select t.eq(pg_temp.missed('T3', true, 3), 0, 'earn_trials = false: a missed trial lesson earns no credit');
select t.eq(pg_temp.missed('T4', false, 4), 1, 'earn_trials = false: an ordinary missed lesson earns its credit');
-- true
select pg_temp.cfg_trials('true'::jsonb);
select t.eq(pg_temp.missed('T5', true, 5), 1, 'earn_trials = true: a missed trial lesson earns a credit');
select t.eq(pg_temp.missed('T6', false, 6), 1, 'earn_trials = true: an ordinary missed lesson earns its credit');
-- the rule "none" still earns nothing, trial or not
select pg_temp.cfg(p_rule => 'none');
select t.eq(pg_temp.missed('T7', true, 7) + pg_temp.missed('T8', false, 8), 0, 'rule none earns nothing, trial or not (earn_trials does not switch credits on)');
select t.eq((select count(*)::int from makeup_credits c where c.source_lesson_id in (t.id('T1'), t.id('T3'))), 0, 'no credit rows exist for the refused trial lessons');
select 'b8 credits ok';
