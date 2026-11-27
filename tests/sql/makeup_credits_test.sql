-- T18 step 4 tests: make-up credits (db/migration_makeup_credits.sql).
-- Every setting value; earn once only (double press); expiry boundary; revoke after use refused; booking, unbooking, marking a make-up uses the credit up; the
-- invoice run skips a make-up that is already paid for; permissions (each grant_by / book_by value); solo organisations, tutors, parents and strangers refused;
-- no money anywhere in what staff read; no direct table access; the settings validator.
-- Runs last in the same throwaway database (reuses the t.* helpers). Builds its own centres and made-up people.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-000000b18001', 'mc.owner@centre.test'),  ('00000000-0000-0000-0000-000000b18002', 'mc.staff@centre.test'),
  ('00000000-0000-0000-0000-000000b18003', 'mc.viewer@centre.test'), ('00000000-0000-0000-0000-000000b18004', 'mc.tutor1@centre.test'),
  ('00000000-0000-0000-0000-000000b18005', 'mc.tutor2@centre.test'), ('00000000-0000-0000-0000-000000b18006', 'mc.solo@centre.test'),
  ('00000000-0000-0000-0000-000000b18007', 'mc.off@centre.test'),   ('00000000-0000-0000-0000-000000b18008', 'mc.parent@centre.test'),
  ('00000000-0000-0000-0000-000000b18009', 'mc.owner2@centre.test'), ('00000000-0000-0000-0000-000000b1800a', 'mc.outsider@centre.test'),
  ('00000000-0000-0000-0000-000000b1800b', 'mc.invoicer@centre.test');
set role authenticated; select t.as('00000000-0000-0000-0000-000000b18001');
select t.put('mc', org_create_centre('Credits Centre', t.centre_settings()));
select t.as('00000000-0000-0000-0000-000000b18009');
select t.put('mc2', org_create_centre('Other Credits Centre', t.centre_settings()));
reset role; select set_config('request.jwt.claims', '', false);
select t.put('solo', org_personal('00000000-0000-0000-0000-000000b18006'));
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('mc'), '00000000-0000-0000-0000-000000b18002', 'Staff Sam',    'staff', array['manage_timetable'], 'active'),
  (t.id('mc'), '00000000-0000-0000-0000-000000b18003', 'Staff Viewer', 'staff', '{}', 'active'),
  (t.id('mc'), '00000000-0000-0000-0000-000000b18004', 'Tutor One',    'tutor', '{}', 'active'),
  (t.id('mc'), '00000000-0000-0000-0000-000000b18005', 'Tutor Two',    'tutor', '{}', 'active'),
  (t.id('mc'), '00000000-0000-0000-0000-000000b18007', 'Switched off', 'staff', array['manage_timetable'], 'disabled'),
  (t.id('mc'), '00000000-0000-0000-0000-000000b18008', 'A Parent',     'parent', '{}', 'active'),
  (t.id('mc'), '00000000-0000-0000-0000-000000b1800b', 'Invoicer',     'staff', array['issue_invoices'], 'active');
select t.put('m1', (select id from memberships where org_id = t.id('mc') and user_id = '00000000-0000-0000-0000-000000b18004'));
select t.put('m2', (select id from memberships where org_id = t.id('mc') and user_id = '00000000-0000-0000-0000-000000b18005'));
select t.put('ms', (select id from memberships where org_id = t.id('mc') and user_id = '00000000-0000-0000-0000-000000b18002'));

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today;
grant select on td to authenticated, anon;
insert into students(id, tutor_id, org_id, name, level, contact) values
  ('00000000-0000-0000-0000-000000b18101', '00000000-0000-0000-0000-000000b18001', t.id('mc'), 'Kid One',   'P1', '91110001'),
  ('00000000-0000-0000-0000-000000b18102', '00000000-0000-0000-0000-000000b18001', t.id('mc'), 'Kid Two',   'P2', '91110002'),
  ('00000000-0000-0000-0000-000000b18103', '00000000-0000-0000-0000-000000b18001', t.id('mc'), 'Kid Three', 'P3', '91110003'),
  ('00000000-0000-0000-0000-000000b18104', '00000000-0000-0000-0000-000000b18001', t.id('mc'), 'Kid Four (no lessons yet)', 'P4', '91110004'),
  ('00000000-0000-0000-0000-000000b18105', '00000000-0000-0000-0000-000000b18001', t.id('mc'), 'Kid Five',  'P5', '91110005'),
  ('00000000-0000-0000-0000-000000b18106', '00000000-0000-0000-0000-000000b18001', t.id('mc'), 'Kid Six (invoice tests)', 'P6', '91110006'),
  ('00000000-0000-0000-0000-000000b181f1', '00000000-0000-0000-0000-000000b18009', t.id('mc2'), 'Kid elsewhere', 'P1', '91119999');
insert into student_tutors(org_id, student_id, membership_id) values
  (t.id('mc'), '00000000-0000-0000-0000-000000b18101', t.id('m1')), (t.id('mc'), '00000000-0000-0000-0000-000000b18102', t.id('m1')),
  (t.id('mc'), '00000000-0000-0000-0000-000000b18103', t.id('m2'));
select t.eq((select count(*) from branches where org_id = t.id('mc')) + (select count(*) from rooms where org_id = t.id('mc')), 0, 'the test centre has no branch and no room (remote 1-to-1)');

\set OWN '00000000-0000-0000-0000-000000b18001'
\set STF '00000000-0000-0000-0000-000000b18002'
\set VIEW '00000000-0000-0000-0000-000000b18003'
\set TU1 '00000000-0000-0000-0000-000000b18004'
\set TU2 '00000000-0000-0000-0000-000000b18005'
\set SOLO '00000000-0000-0000-0000-000000b18006'
\set OFF '00000000-0000-0000-0000-000000b18007'
\set PAR '00000000-0000-0000-0000-000000b18008'
\set OWN2 '00000000-0000-0000-0000-000000b18009'
\set OUT '00000000-0000-0000-0000-000000b1800a'
\set INV '00000000-0000-0000-0000-000000b1800b'
\set K1 '00000000-0000-0000-0000-000000b18101'
\set K2 '00000000-0000-0000-0000-000000b18102'
\set K3 '00000000-0000-0000-0000-000000b18103'
\set K4 '00000000-0000-0000-0000-000000b18104'
\set K5 '00000000-0000-0000-0000-000000b18105'
\set K6 '00000000-0000-0000-0000-000000b18106'
\set KX '00000000-0000-0000-0000-000000b181f1'

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
                            p_lessons jsonb default '{}', p_org text default 'mc', p_owner text default '00000000-0000-0000-0000-000000b18001') returns void language plpgsql as $$
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
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000b18001', t.id('mc'), p_student::uuid, (select today + p_day from td), p_start, p_start + interval '1 hour',
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
  return (pg_temp.call('00000000-0000-0000-0000-000000b18002', format('select (staff_grant_credit(%L, %L, %L)->>%L)', t.id('mc'), p_student, p_reason, 'credit_id')))::uuid;
end $$;
select set_config('request.jwt.claims', '', false);

-- ===================================================================== 0. the settings validator (every value, good and bad)
create function pg_temp.save(p_billing jsonb, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'ok';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-000000b18001', 'role', 'authenticated')::text, false);
  set local role authenticated;
  begin perform org_save_settings(t.id('mc'), jsonb_set(t.centre_settings(), '{billing}', jsonb_build_object('model', 'postpaid_lessons') || p_billing), current_date);
  exception when others then m := sqlerrm; end;
  reset role;
  if p_expect = 'ok' and m <> 'ok' then raise exception 'FAIL: % (refused: %)', p_msg, m; end if;
  if p_expect <> 'ok' and m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS %: %', case when p_expect = 'ok' then 'saved' else 'refused' end, p_msg;
end $$;
select pg_temp.save('{}', 'ok', 'no credit keys at all (a centre that saved before this migration)');
select pg_temp.save(format('{"credits":{"rule":"%s"}}', v)::jsonb, 'ok', 'rule = ' || v) from unnest(array['none', 'one_per_missed']) v;
select pg_temp.save(format('{"credits":{"earn_absences":"%s"}}', v)::jsonb, 'ok', 'earn_absences = ' || v) from unnest(array['none', 'notice_only', 'notice_and_late', 'all_missed']) v;
select pg_temp.save(format('{"credits":{"earn_tutor_cancel":"%s"}}', v)::jsonb, 'ok', 'earn_tutor_cancel = ' || v) from unnest(array['staff_decide', 'automatic']) v;
select pg_temp.save(format('{"credits":{"grant_by":"%s"}}', v)::jsonb, 'ok', 'grant_by = ' || v) from unnest(array['manage_timetable', 'owner']) v;
select pg_temp.save(format('{"credits":{"book_by":"%s"}}', v)::jsonb, 'ok', 'book_by = ' || v) from unnest(array['manage_timetable', 'owner']) v;
select pg_temp.save(format('{"credits":{"makeup_price":"%s"}}', v)::jsonb, 'ok', 'makeup_price = ' || v) from unnest(array['free', 'if_missed_not_charged']) v;
select pg_temp.save(format('{"credits":{"earn_holiday":%s}}', v)::jsonb, 'ok', 'earn_holiday = ' || v) from unnest(array['true', 'false']) v;
select pg_temp.save(format('{"credit_expiry_days":%s}', v)::jsonb, 'ok', 'credit_expiry_days = ' || v) from unnest(array['0', '1', '30', '3650']) v;
select pg_temp.save('{"credits":{"rule":"barter"}}', 'Unknown make-up credit rule', 'unknown rule');
select pg_temp.save('{"credits":{"earn_absences":"always"}}', 'Unknown rule for credits from absences', 'unknown earn_absences');
select pg_temp.save('{"credits":{"earn_tutor_cancel":"maybe"}}', 'Unknown rule for credits from tutor', 'unknown earn_tutor_cancel');
select pg_temp.save('{"credits":{"grant_by":"tutor"}}', 'Unknown rule for who grants', 'a tutor can never be made the one who grants');
select pg_temp.save('{"credits":{"book_by":"parent"}}', 'Unknown rule for who books', 'unknown book_by');
select pg_temp.save('{"credits":{"makeup_price":"half"}}', 'Unknown make-up price rule', 'unknown makeup_price');
select pg_temp.save('{"credits":{"earn_holiday":"yes"}}', 'Setting', 'earn_holiday must be a real yes/no');
select pg_temp.save('{"credit_expiry_days":-1}', 'Credits must expire', 'a negative expiry');
select pg_temp.save('{"credit_expiry_days":3651}', 'Credits must expire', 'an expiry over ten years');
select pg_temp.save('{"credit_expiry_days":"30"}', 'Credits must expire', 'an expiry typed as text');
select pg_temp.save('{"credit_expiry_days":2.5}', 'Credits must expire', 'a fractional expiry');

-- ===================================================================== 1. the feature is OFF until the centre turns it on (rule none / missing)
select pg_temp.cfg(p_rule => 'none', p_abs => 'all_missed');
select pg_temp.les('A0', :'K1', -1, '08:00', 'm1');
select pg_temp.expect(:'STF', format('select staff_mark_attendance(%L, %L)', t.id('A0'), 'cancelled_early'), 'ok', 'staff mark a lesson cancelled in time');
select t.eq(pg_temp.ncred('A0'), 0, 'rule none: a missed lesson earns nothing, whatever earn_absences says');
select pg_temp.expect(:'STF', format('select staff_grant_credit(%L, %L, %L)', t.id('mc'), :'K1', 'goodwill'), 'NOT_ENABLED', 'rule none: granting by hand says the feature is off');
select pg_temp.expect(:'OWN', format('select staff_book_makeup(%L, current_date, %L, %L)', gen_random_uuid(), '10:00', '11:00'), 'NOT_FOUND', 'booking an unknown credit');
select t.ok((pg_temp.call(:'STF', format('select staff_credit_list(%L)', t.id('mc')))::jsonb->>'enabled')::boolean = false, 'the list still works and says the feature is off');
-- a centre that saved settings WITHOUT any credit key behaves the same (missing = none)
select pg_temp.save('{}', 'ok', 'settings with no credit key');
select pg_temp.les('A0b', :'K1', -1, '09:00', 'm1');
select pg_temp.mark(:'STF', 'A0b', 'cancelled_early');
select t.eq(pg_temp.ncred('A0b'), 0, 'no credit key at all: nothing is earned');

-- ===================================================================== 2. EARNING from absences: every earn_absences value x every mark
do $$
declare ab text; att text; n int := 0; want int; got int; k text; sk text;
begin
  foreach ab in array array['none', 'notice_only', 'notice_and_late', 'all_missed'] loop
    perform pg_temp.cfg(p_abs => ab);
    foreach att in array array['cancelled_early', 'late_cancelled', 'absent', 'attended'] loop
      n := n + 1; k := 'E' || n;
      perform pg_temp.les(k, '00000000-0000-0000-0000-000000b18102', -2, ('07:00'::time + (n || ' hours')::interval)::time, 'm1');
      perform pg_temp.mark('00000000-0000-0000-0000-000000b18002', k, att);
      want := case when att = 'attended' then 0
                   when ab = 'none' then 0
                   when att = 'cancelled_early' then 1
                   when att = 'late_cancelled' then case when ab in ('notice_and_late', 'all_missed') then 1 else 0 end
                   else case when ab = 'all_missed' then 1 else 0 end end;
      got := pg_temp.ncred(k);
      if got <> want then raise exception 'FAIL: earn_absences=% mark=% earned % credit(s), expected %', ab, att, got, want; end if;
      raise notice 'PASS earn_absences = % , marked % -> % credit(s)', ab, att, got;
    end loop;
  end loop;
end $$;

-- ===================================================================== 3. EARN ONCE ONLY (double press, re-marking, correcting, touching the lesson again)
select pg_temp.cfg(p_abs => 'all_missed');
select pg_temp.les('B1', :'K2', -3, '10:00', 'm1');
select pg_temp.mark(:'STF', 'B1', 'cancelled_early');
select t.eq(pg_temp.ncred('B1'), 1, 'marked cancelled in time: one credit');
select pg_temp.expect(:'STF', format('select staff_mark_attendance(%L, %L)', t.id('B1'), 'cancelled_early'), 'ALREADY_MARKED', 'pressing Mark a second time is refused');
select t.eq(pg_temp.ncred('B1'), 1, 'double press: still one credit');
select pg_temp.expect(:'STF', format('select staff_correct_attendance(%L, %L, %L)', t.id('B1'), 'late_cancelled', 'it was a late call'), 'ok', 'corrected to late cancelled (still a missed lesson)');
select t.eq(pg_temp.ncred('B1'), 1, 'correcting from one missed mark to another keeps ONE credit');
update lessons set charge_note = 'edited note' where id = t.id('B1');
update lessons set status = 'cancelled' where id = t.id('B1');
select t.eq(pg_temp.ncred('B1'), 1, 'touching the lesson again (note, status) earns nothing more');
select t.eq(pg_temp.nev(pg_temp.cid('B1'), 'earned'), 1, 'and records ONE earned event');
select t.ok((select source = 'absence' and status = 'open' and earned_on = (select today from td) and expires_on is null and student_id = :'K2'::uuid and org_id = t.id('mc')
               from makeup_credits where source_lesson_id = t.id('B1')), 'the credit: source absence, open, earned today, never expires, the right student and centre');
select t.ok((select count(*) = 1 from audit_log where action = 'credit_earned' and row_id = pg_temp.cid('B1')::text), 'an audit row says it was earned');
select t.fails($q$ insert into makeup_credits(org_id, student_id, source, source_lesson_id, earned_on) select org_id, student_id, 'absence', source_lesson_id, earned_on from makeup_credits limit 1 $q$, 'a second credit for the same missed lesson (unique index)');

-- correcting to ATTENDED: an unused automatic credit goes with it; a booked one stays
select pg_temp.les('B2', :'K2', -3, '11:00', 'm1');
select pg_temp.mark(:'STF', 'B2', 'absent');
select t.eq(pg_temp.ncred('B2'), 1, 'absent under all_missed: a credit');
select pg_temp.expect(:'STF', format('select staff_correct_attendance(%L, %L, %L)', t.id('B2'), 'attended', 'they did come'), 'ok', 'corrected to attended');
select t.ok(pg_temp.cst(pg_temp.cid('B2')) = 'revoked', 'the unused credit was taken back automatically');
select t.eq(pg_temp.nev(pg_temp.cid('B2'), 'revoked'), 1, 'with a revoked event');
select pg_temp.expect(:'STF', format('select staff_correct_attendance(%L, %L, %L)', t.id('B2'), 'absent', 'sorry, they were absent'), 'ok', 'corrected back to absent');
select t.eq(pg_temp.ncred('B2'), 1, 'a revoked credit is NOT earned again for the same lesson (one credit per lesson, ever)');

-- ===================================================================== 4. TUTOR CANCELS (staff_decide earns nothing; automatic earns one)
select pg_temp.cfg(p_tc => 'staff_decide', p_lessons => '{"timetable_editing":"tutors_direct","tutors_edit":{"cancel":true},"min_notice_hours":0}');
select pg_temp.les('T1', :'K1', 3, '15:00', 'm1');
select pg_temp.expect(:'TU1', format('select tutor_cancel_lesson(%L, %L)', t.id('T1'), 'tutor is unwell'), 'ok', 'a tutor cancels in advance (staff_decide)');
select t.ok((select status = 'cancelled' and compensation = 0 from lessons where id = t.id('T1')), 'the tutor cancel is cancelled with charge 0');
select t.eq(pg_temp.ncred('T1'), 0, 'staff_decide: a tutor''s cancel creates NO credit by itself');
select pg_temp.cfg(p_tc => 'automatic', p_lessons => '{"timetable_editing":"tutors_direct","tutors_edit":{"cancel":true},"min_notice_hours":0}');
select pg_temp.les('T2', :'K1', 4, '15:00', 'm1');
select pg_temp.expect(:'TU1', format('select tutor_cancel_lesson(%L, %L)', t.id('T2'), 'tutor is unwell'), 'ok', 'a tutor cancels in advance (automatic)');
select t.ok((select source = 'tutor_cancel' and status = 'open' from makeup_credits where source_lesson_id = t.id('T2')), 'automatic: a tutor_cancel credit exists');
select t.eq(pg_temp.ncred('T2'), 1, 'exactly one');
-- the staff decide on the earlier one: they can grant it by hand
select pg_temp.expect(:'STF', format('select staff_grant_credit(%L, %L, %L, %L)', t.id('mc'), :'K1', 'Tutor cancelled, family keeps the lesson', t.id('T1')), 'ok', 'staff grant the credit for the tutor-cancelled lesson by hand');
select t.ok((select source = 'manual' from makeup_credits where source_lesson_id = t.id('T1')), 'it is a manual credit, linked to that lesson');
-- a tutor sees no credit anywhere (no function, no table)
select pg_temp.expect(:'TU1', format('select staff_credit_list(%L)', t.id('mc')), 'NOT_FOUND', 'a tutor cannot list credits');
select pg_temp.expect(:'TU1', 'select count(*) from makeup_credits', 'permission denied', 'a tutor has no table access to credits');
select pg_temp.expect(:'TU1', 'select count(*) from makeup_credit_events', 'permission denied', 'nor to credit events');

-- ===================================================================== 5. HOLIDAYS (earn_holiday false / true)
select pg_temp.cfg(p_hol => false);
insert into holidays(org_id, name, starts_on, ends_on) values (t.id('mc'), 'Test Holiday One', (select today + 5 from td), (select today + 5 from td));
select pg_temp.les('H1', :'K1', 5, '16:00', 'm1');
select pg_temp.expect(:'STF', format('select staff_holiday_cancel(%L, (select today + 5 from td), (select today + 5 from td), %L, false)', t.id('mc'), 'Test Holiday One'), 'ok', 'staff cancel the lessons on a holiday');
select t.ok((select status = 'cancelled' from lessons where id = t.id('H1')), 'the holiday lesson is cancelled');
select t.eq(pg_temp.ncred('H1'), 0, 'earn_holiday false: no credit');
select pg_temp.cfg(p_hol => true);
insert into holidays(org_id, name, starts_on, ends_on) values (t.id('mc'), 'Test Holiday Two', (select today + 6 from td), (select today + 6 from td));
select pg_temp.les('H2', :'K1', 6, '16:00', 'm1');
select pg_temp.les('H3', :'K2', 6, '16:00', 'm1');
select pg_temp.les('H4', :'K3', 7, '16:00', 'm2');     -- not on a holiday
select pg_temp.expect(:'STF', format('select staff_holiday_cancel(%L, (select today + 6 from td), (select today + 6 from td), %L, false)', t.id('mc'), 'Test Holiday Two'), 'ok', 'staff cancel the lessons on the second holiday');
select t.eq(pg_temp.ncred('H2') + pg_temp.ncred('H3'), 2, 'earn_holiday true: one credit for each lesson cancelled for the holiday');
select t.ok((select bool_and(source = 'holiday') from makeup_credits where source_lesson_id in (t.id('H2'), t.id('H3'))), 'their source is holiday');
select pg_temp.expect(:'STF', format('select staff_holiday_cancel(%L, (select today + 6 from td), (select today + 6 from td), %L, false)', t.id('mc'), 'Test Holiday Two'), 'ok', 'pressing the holiday cancel again');
select t.eq(pg_temp.ncred('H2') + pg_temp.ncred('H3'), 2, 'pressed twice: still one credit each');
-- a lesson cancelled with a note that merely starts with "Holiday" but is NOT on a holiday earns nothing
update lessons set status = 'cancelled', compensation = 0, charge_note = 'Holiday trip' where id = t.id('H4');
select t.eq(pg_temp.ncred('H4'), 0, 'a cancel outside a holiday day earns nothing even with a "Holiday" note');

-- ===================================================================== 6. GRANT by hand (and who may)
select pg_temp.cfg();
select pg_temp.expect(:'STF', format('select staff_grant_credit(%L, %L, %L)', t.id('mc'), :'K3', ''), 'REASON_REQUIRED', 'a grant needs a reason');
select pg_temp.expect(:'STF', format('select staff_grant_credit(%L, %L, %L)', t.id('mc'), :'K3', 'ab'), 'BAD_REASON', 'a two-letter reason is too short');
select pg_temp.expect(:'STF', format('select staff_grant_credit(%L, %L, %L)', t.id('mc'), :'K3', repeat('x', 301)), 'BAD_REASON', 'a 301-letter reason is too long');
select pg_temp.expect(:'STF', format('select staff_grant_credit(%L, %L, %L)', t.id('mc'), :'KX', 'wrong centre student'), 'NOT_FOUND', 'a student of another centre');
select pg_temp.expect(:'STF', format('select staff_grant_credit(%L, %L, %L, %L)', t.id('mc'), :'K3', 'wrong lesson', t.id('B1')), 'NOT_FOUND', 'a lesson that belongs to another student');
select pg_temp.expect(:'STF', format('select staff_grant_credit(%L, %L, %L, %L)', t.id('mc'), :'K2', 'again', t.id('B1')), 'ALREADY_HAS_CREDIT', 'a lesson that already has its credit');
select pg_temp.expect(:'STF', format('select staff_grant_credit(%L, %L, %L)', t.id('mc'), :'K3', 'Goodwill make-up'), 'ok', 'staff with manage_timetable grant one');
select pg_temp.expect(:'STF', format('select staff_grant_credit(%L, %L, %L)', t.id('mc'), :'K3', 'Goodwill make-up'), 'DUPLICATE', 'the same grant pressed twice');
select t.ok((select source = 'manual' and reason = 'Goodwill make-up' and created_by = :'STF'::uuid and expires_on is null from makeup_credits where student_id = :'K3'::uuid and source = 'manual' limit 1), 'a manual credit with its reason and who gave it');
select pg_temp.expect(:'VIEW', format('select staff_grant_credit(%L, %L, %L)', t.id('mc'), :'K3', 'Look-only staff'), 'NOT_ALLOWED', 'staff without manage_timetable can look but not grant');
select pg_temp.expect(:'INV', format('select staff_grant_credit(%L, %L, %L)', t.id('mc'), :'K3', 'Invoicing staff'), 'NOT_ALLOWED', 'staff who only issue invoices cannot grant');
select pg_temp.expect(:'OWN', format('select staff_grant_credit(%L, %L, %L)', t.id('mc'), :'K3', 'Owner grants'), 'ok', 'the owner grants (grant_by = manage_timetable, owners always can)');
select pg_temp.cfg(p_grant => 'owner');
select pg_temp.expect(:'STF', format('select staff_grant_credit(%L, %L, %L)', t.id('mc'), :'K3', 'Staff when owner only'), 'NOT_ALLOWED: at this centre only the owner', 'grant_by = owner: staff with manage_timetable are refused');
select pg_temp.expect(:'OWN', format('select staff_grant_credit(%L, %L, %L)', t.id('mc'), :'K3', 'Owner when owner only'), 'ok', 'grant_by = owner: the owner may');
select t.ok((pg_temp.call(:'STF', format('select staff_credit_list(%L)', t.id('mc')))::jsonb->>'can_grant')::boolean = false, 'grant_by = owner: the list tells staff they cannot grant');
select t.ok((pg_temp.call(:'OWN', format('select staff_credit_list(%L)', t.id('mc')))::jsonb->>'can_grant')::boolean, 'and tells the owner they can');
select pg_temp.cfg();

-- the same NOT_FOUND for everyone who has no business here
select pg_temp.expect(:'PAR', format('select staff_credit_list(%L)', t.id('mc')), 'NOT_FOUND', 'a parent cannot list credits');
select pg_temp.expect(:'OUT', format('select staff_credit_list(%L)', t.id('mc')), 'NOT_FOUND', 'a stranger cannot list credits');
select pg_temp.expect(:'OFF', format('select staff_credit_list(%L)', t.id('mc')), 'NOT_FOUND', 'switched-off staff cannot list credits');
select pg_temp.expect(:'OWN2', format('select staff_credit_list(%L)', t.id('mc')), 'NOT_FOUND', 'another centre''s owner cannot list this centre''s credits');
select pg_temp.expect(:'OWN2', format('select staff_grant_credit(%L, %L, %L)', t.id('mc'), :'K3', 'from elsewhere'), 'NOT_FOUND', 'another centre''s owner cannot grant here');
select pg_temp.expect(null, format('select staff_credit_list(%L)', t.id('mc')), 'NOT_FOUND', 'nobody signed in');
select pg_temp.expect(:'SOLO', format('select staff_credit_list(%L)', t.id('solo')), 'NOT_FOUND', 'a solo organisation has no credits');
select pg_temp.expect(:'SOLO', format('select staff_grant_credit(%L, %L, %L)', t.id('solo'), :'K3', 'solo'), 'NOT_FOUND', 'a solo tutor cannot grant');

-- ===================================================================== 7. REVOKE

-- ===================================================================== 7. REVOKE (an unused credit; never one that is booked or used)
create function pg_temp.book(p_user text, p_credit uuid, p_day int, p_start text, p_end text, p_tutor text default null) returns text language sql as $$
  select pg_temp.call(p_user, format('select staff_book_makeup(%L, (select today + %s from td), %L::time, %L::time, %L)', p_credit, p_day, p_start, p_end,
                                     case when p_tutor is null then null else t.id(p_tutor)::text end)) $$;
create function pg_temp.bkid(p_json text) returns uuid language plpgsql as $$
begin
  if p_json like 'ERR:%' then raise exception 'FAIL: booking was refused: %', p_json; end if;
  return (p_json::jsonb->>'lesson_id')::uuid;
end $$;
select t.put('R1', pg_temp.grant_for(:'K3', 'to be revoked'));
select pg_temp.expect(:'STF', format('select staff_revoke_credit(%L, %L)', t.id('R1'), ''), 'REASON_REQUIRED', 'revoking needs a reason');
select pg_temp.expect(:'VIEW', format('select staff_revoke_credit(%L, %L)', t.id('R1'), 'no permission'), 'NOT_ALLOWED', 'staff without manage_timetable cannot revoke');
select pg_temp.expect(:'OWN2', format('select staff_revoke_credit(%L, %L)', t.id('R1'), 'other centre'), 'NOT_FOUND', 'another centre cannot revoke it');
select pg_temp.expect(:'TU1', format('select staff_revoke_credit(%L, %L)', t.id('R1'), 'a tutor'), 'NOT_FOUND', 'a tutor cannot revoke');
select pg_temp.expect(:'STF', format('select staff_revoke_credit(%L, %L)', gen_random_uuid(), 'nothing there'), 'NOT_FOUND', 'an unknown credit');
select pg_temp.expect(:'STF', format('select staff_revoke_credit(%L, %L)', t.id('R1'), 'given by mistake'), 'ok', 'staff revoke an open credit');
select t.ok(pg_temp.cst(t.id('R1')) = 'revoked' and pg_temp.nev(t.id('R1'), 'revoked') = 1, 'status revoked, one revoked event');
select pg_temp.expect(:'STF', format('select staff_revoke_credit(%L, %L)', t.id('R1'), 'again'), 'NO_CHANGE', 'revoking twice');
select t.eq(pg_temp.nev(t.id('R1'), 'revoked'), 1, 'double press: still one revoked event');
select t.ok(pg_temp.book(:'STF', t.id('R1'), 2, '17:00', '18:00') like 'ERR:NOT_OPEN%', 'a revoked credit cannot be booked');

-- ===================================================================== 8. BOOK the make-up (free)
select pg_temp.cfg(p_abs => 'all_missed', p_price => 'free');
select pg_temp.les('C1', :'K2', -4, '10:00', 'm1');
select pg_temp.mark(:'STF', 'C1', 'cancelled_early');
select t.put('CR1', pg_temp.cid('C1'));
select pg_temp.expect(:'VIEW', format('select staff_book_makeup(%L, current_date + 2, %L, %L)', t.id('CR1'), '17:00', '18:00'), 'NOT_ALLOWED', 'staff without manage_timetable cannot book');
select pg_temp.expect(:'TU1', format('select staff_book_makeup(%L, current_date + 2, %L, %L)', t.id('CR1'), '17:00', '18:00'), 'NOT_FOUND', 'a tutor cannot book');
select pg_temp.expect(:'OWN2', format('select staff_book_makeup(%L, current_date + 2, %L, %L)', t.id('CR1'), '17:00', '18:00'), 'NOT_FOUND', 'another centre cannot book');
select t.ok(pg_temp.book(:'STF', t.id('CR1'), -1, '17:00', '18:00') like 'ERR:BAD_DATE%', 'yesterday is refused');
select t.ok(pg_temp.book(:'STF', t.id('CR1'), 366, '17:00', '18:00') like 'ERR:BAD_DATE%', 'more than a year ahead is refused');
select t.ok(pg_temp.book(:'STF', t.id('CR1'), 2, '18:00', '17:00') like 'ERR:BAD_TIME%', 'ending before it starts is refused');
select t.ok(pg_temp.book(:'STF', t.id('CR1'), 2, '17:00', '17:00') like 'ERR:BAD_TIME%', 'a zero-length lesson is refused');
select t.ok(pg_temp.call(:'STF', format('select staff_book_makeup(%L, null, %L, %L)', t.id('CR1'), '17:00', '18:00')) like 'ERR:BAD_TIME%', 'no date is refused');
select pg_temp.expect(:'STF', format('select staff_book_makeup(%L, (select today + 2 from td), %L, %L, %L)', t.id('CR1'), '17:00', '18:00', gen_random_uuid()), 'NOT_AVAILABLE', 'a tutor id that is not in this centre');
select t.put('MK1', pg_temp.bkid(pg_temp.expect(:'STF', format('select staff_book_makeup(%L, (select today + 2 from td), %L, %L)', t.id('CR1'), '17:00', '18:00'), 'ok', 'staff book the make-up')));
select t.ok((select l.org_id = t.id('mc') and l.student_id = :'K2'::uuid and l.lesson_date = (select today + 2 from td) and l.start_time = '17:00' and l.end_time = '18:00'
                and l.one_off and l.status = 'scheduled' and l.attendance is null and not l.paid and l.makeup_credit_id = t.id('CR1') and l.makeup_billing = 'free'
                and l.amount = 0 and l.rate = 60 and l.taught_by = t.id('m1') and l.subject = 'Math' and l.level = 'P1' and l.slot_id is null
             from lessons l where l.id = t.id('MK1')), 'the make-up is an ordinary one-off lesson: right student, day, times, copied tutor / subject / rate, free, linked to its credit');
select t.ok(pg_temp.cst(t.id('CR1')) = 'booked' and pg_temp.nev(t.id('CR1'), 'booked') = 1, 'the credit is booked with a booked event');
select t.ok((select count(*) = 1 from audit_log where action = 'credit_booked' and row_id = t.id('CR1')::text), 'and an audit row');
select pg_temp.expect(:'STF', format('select staff_book_makeup(%L, (select today + 3 from td), %L, %L)', t.id('CR1'), '17:00', '18:00'), 'ALREADY_BOOKED', 'booking the same credit again (double press)');
select t.eq((select count(*) from lessons where makeup_credit_id = t.id('CR1')), 1, 'one credit, one make-up lesson');
select pg_temp.expect(:'STF', format('select staff_revoke_credit(%L, %L)', t.id('CR1'), 'changed my mind'), 'IN_USE', 'a booked credit cannot be revoked');
-- same student, same day and time as an existing lesson
select t.put('CR2', pg_temp.grant_for(:'K2', 'second credit for the clash test'));
select pg_temp.expect(:'STF', format('select staff_book_makeup(%L, (select today + 2 from td), %L, %L)', t.id('CR2'), '17:00', '18:00'), 'DUPLICATE', 'the student already has a lesson at that time');
select t.put('MK2', pg_temp.bkid(pg_temp.expect(:'STF', format('select staff_book_makeup(%L, (select today + 2 from td), %L, %L, %L)', t.id('CR2'), '19:00', '20:30', t.id('m2')), 'ok', 'booking with another tutor and a 90-minute lesson')));
select t.ok((select taught_by = t.id('m2') and end_time - start_time = interval '90 minutes' from lessons where id = t.id('MK2')), 'the chosen tutor and length are used');
select t.put('CR3', pg_temp.grant_for(:'K4', 'student with no lessons at all'));
select pg_temp.expect(:'STF', format('select staff_book_makeup(%L, (select today + 2 from td), %L, %L)', t.id('CR3'), '17:00', '18:00'), 'NO_TEMPLATE', 'a student with no lesson to copy the subject and rate from');
-- a student whose lessons end before the day
update students set end_date = (select today + 1 from td) where id = :'K2'::uuid;
select t.put('CR4', pg_temp.grant_for(:'K2', 'student leaving soon'));
select pg_temp.expect(:'STF', format('select staff_book_makeup(%L, (select today + 5 from td), %L, %L)', t.id('CR4'), '12:00', '13:00'), 'ENDED', 'a make-up after the student''s last day');
update students set end_date = null where id = :'K2'::uuid;
-- book_by = owner
select pg_temp.cfg(p_book => 'owner');
select pg_temp.expect(:'STF', format('select staff_book_makeup(%L, (select today + 5 from td), %L, %L)', t.id('CR4'), '12:00', '13:00'), 'NOT_ALLOWED: at this centre only the owner', 'book_by = owner: staff are refused');
select pg_temp.expect(:'OWN', format('select staff_book_makeup(%L, (select today + 5 from td), %L, %L)', t.id('CR4'), '12:00', '13:00'), 'ok', 'book_by = owner: the owner books');
select t.ok((pg_temp.call(:'STF', format('select staff_credit_list(%L, %L)', t.id('mc'), 'booked'))::jsonb->>'can_book')::boolean = false, 'book_by = owner: the list tells staff they cannot book');
select pg_temp.expect(:'STF', format('select staff_unbook_makeup(%L, %L)', t.id('CR4'), 'staff when owner only'), 'NOT_ALLOWED', 'book_by = owner: staff cannot unbook either');
select pg_temp.expect(:'OWN', format('select staff_unbook_makeup(%L, %L)', t.id('CR4'), 'owner takes it back'), 'ok', 'book_by = owner: the owner unbooks');
select pg_temp.cfg(p_abs => 'all_missed', p_price => 'free');

-- ===================================================================== 9. UNBOOK gives the credit back
select pg_temp.expect(:'STF', format('select staff_unbook_makeup(%L, %L)', t.id('CR2'), ''), 'REASON_REQUIRED', 'unbooking needs a reason');
select pg_temp.expect(:'VIEW', format('select staff_unbook_makeup(%L, %L)', t.id('CR2'), 'no permission'), 'NOT_ALLOWED', 'staff without manage_timetable cannot unbook');
select pg_temp.expect(:'STF', format('select staff_unbook_makeup(%L, %L)', t.id('CR3'), 'nothing booked'), 'NO_CHANGE', 'unbooking an open credit');
select pg_temp.expect(:'STF', format('select staff_unbook_makeup(%L, %L)', t.id('CR2'), 'family cannot come'), 'ok', 'staff unbook a make-up');
select t.ok(pg_temp.cst(t.id('CR2')) = 'open' and pg_temp.nev(t.id('CR2'), 'returned') = 1, 'the credit is open again with one returned event');
select t.eq((select count(*) from lessons where id = t.id('MK2')), 0, 'and the make-up lesson is gone');
select t.ok((select count(*) = 1 from audit_log where action = 'credit_returned' and row_id = t.id('CR2')::text), 'with an audit row');
select pg_temp.expect(:'STF', format('select staff_unbook_makeup(%L, %L)', t.id('CR2'), 'again'), 'NO_CHANGE', 'unbooking twice (double press)');
select t.eq(pg_temp.nev(t.id('CR2'), 'returned'), 1, 'still one returned event');
select t.ok(pg_temp.book(:'STF', t.id('CR2'), 3, '19:00', '20:00') like '{%', 'the returned credit can be booked again');
-- a paid make-up is locked; so is one that has been marked
select t.put('CR5', pg_temp.grant_for(:'K1', 'paid make-up test'));
select t.put('MK5', pg_temp.bkid(pg_temp.book(:'STF', t.id('CR5'), 6, '09:00', '10:00')));
update lessons set paid = true where id = t.id('MK5');
select pg_temp.expect(:'STF', format('select staff_unbook_makeup(%L, %L)', t.id('CR5'), 'it is paid'), 'LOCKED', 'a paid make-up cannot be removed');
update lessons set paid = false where id = t.id('MK5');
-- a make-up deleted any other way gives its credit back (no credit left booked to nothing)
delete from lessons where id = t.id('MK5');
select t.ok(pg_temp.cst(t.id('CR5')) = 'open' and pg_temp.nev(t.id('CR5'), 'returned') = 1, 'deleting the make-up lesson directly returns its credit');
-- deleting the MISSED lesson keeps the credit (it only forgets which lesson)
select pg_temp.les('C9', :'K5', -9, '10:00', 'm1');
select pg_temp.mark(:'STF', 'C9', 'cancelled_early');
select t.put('CR9', pg_temp.cid('C9'));
select t.eq(pg_temp.ncred('C9'), 1, 'a credit for the lesson to be deleted');
delete from lessons where id = t.id('C9');
select t.ok(pg_temp.cst(t.id('CR9')) = 'open' and (select source_lesson_id is null from makeup_credits where id = t.id('CR9')), 'the missed lesson was deleted: the credit stays open, with no lesson link');

-- ===================================================================== 10. MARKING the make-up uses the credit up
select pg_temp.les('C2', :'K1', -5, '10:00', 'm1');
select pg_temp.mark(:'STF', 'C2', 'cancelled_early');
select t.put('CR6', pg_temp.cid('C2'));
select t.put('MK6', pg_temp.bkid(pg_temp.book(:'STF', t.id('CR6'), 0, '12:00', '13:00')));
select t.ok(pg_temp.cst(t.id('CR6')) = 'booked', 'booked for today: not used up until somebody marks it');
select pg_temp.expect(:'STF', format('select staff_mark_attendance(%L, %L)', t.id('MK6'), 'attended'), 'ok', 'staff mark the make-up attended');
select t.ok(pg_temp.cst(t.id('CR6')) = 'used' and pg_temp.nev(t.id('CR6'), 'used') = 1, 'the credit is used up, with one used event');
select t.ok((select status = 'done' from lessons where id = t.id('MK6')), 'the make-up lesson is done');
select pg_temp.expect(:'STF', format('select staff_revoke_credit(%L, %L)', t.id('CR6'), 'after use'), 'IN_USE', 'revoking AFTER use is refused');
select pg_temp.expect(:'STF', format('select staff_unbook_makeup(%L, %L)', t.id('CR6'), 'after use'), 'IN_USE', 'unbooking AFTER use is refused');
select pg_temp.expect(:'STF', format('select staff_correct_attendance(%L, %L, %L)', t.id('MK6'), 'absent', 'they did not come after all'), 'ok', 'the make-up''s mark is corrected later');
select t.ok(pg_temp.cst(t.id('CR6')) = 'used' and pg_temp.nev(t.id('CR6'), 'used') = 1, 'correcting the make-up''s mark changes nothing: still used, still one used event');
select t.eq(pg_temp.ncred('MK6'), 0, 'a make-up that was then marked absent earns NO new credit (one missed lesson = one credit)');
select pg_temp.expect(:'STF', format('select staff_grant_credit(%L, %L, %L, %L)', t.id('mc'), :'K1', 'for the make-up', t.id('MK6')), 'IS_MAKEUP', 'a credit cannot be granted for a make-up lesson');
-- the other marks on a make-up use the credit up too (literal owner rule: marking attendance uses it up)
select pg_temp.les('C3', :'K1', -5, '11:00', 'm1');
select pg_temp.mark(:'STF', 'C3', 'cancelled_early');
select t.put('MK7', pg_temp.bkid(pg_temp.book(:'STF', pg_temp.cid('C3'), 0, '14:00', '15:00')));
select pg_temp.expect(:'STF', format('select staff_mark_attendance(%L, %L)', t.id('MK7'), 'cancelled_early'), 'ok', 'a make-up is cancelled in time');
select t.ok(pg_temp.cst(pg_temp.cid('C3')) = 'used', 'marked (even cancelled in time): the credit is used up (decision for the owner, see summary)');
select t.eq((select count(*) from makeup_credits where source_lesson_id = t.id('MK7')), 0, 'and still no credit is earned by the make-up itself');
-- marking an ordinary lesson never touches a credit
select t.ok(pg_temp.cst(pg_temp.cid('B1')) = 'open', 'an unrelated open credit is untouched by all of this');

-- ===================================================================== 11. THE PRICE of the make-up (every makeup_price value and every case)
select pg_temp.cfg(p_abs => 'all_missed', p_price => 'free');
select pg_temp.les('F1', :'K3', -6, '10:00', 'm2');
select pg_temp.mark(:'STF', 'F1', 'absent');
update lessons set compensation = 0 where id = t.id('F1');
select t.put('ZB1', pg_temp.bkid(pg_temp.book(:'STF', pg_temp.cid('F1'), 7, '10:00', '11:00')));
select t.ok((select makeup_billing = 'free' and amount = 0 from lessons where id = t.id('ZB1')), 'makeup_price = free: free even when the missed lesson was NOT charged');
select pg_temp.cfg(p_abs => 'all_missed', p_price => 'if_missed_not_charged');
select pg_temp.les('F2', :'K3', -6, '11:00', 'm2');
select pg_temp.mark(:'STF', 'F2', 'cancelled_early');
update lessons set compensation = 0 where id = t.id('F2');
select t.put('ZB2', pg_temp.bkid(pg_temp.book(:'STF', pg_temp.cid('F2'), 7, '11:00', '13:00')));
select t.ok((select makeup_billing = 'normal' and amount = 120 from lessons where id = t.id('ZB2')),
            'if_missed_not_charged, missed lesson not charged (0): the make-up is billed at the normal price (2 hours x S$60 = 120)');
select pg_temp.les('F3', :'K3', -6, '12:00', 'm2');
select pg_temp.mark(:'STF', 'F3', 'late_cancelled');
update lessons set compensation = 40 where id = t.id('F3');
select t.put('ZB3', pg_temp.bkid(pg_temp.book(:'STF', pg_temp.cid('F3'), 8, '10:00', '11:00')));
select t.ok((select makeup_billing = 'free' and amount = 0 from lessons where id = t.id('ZB3')),
            'if_missed_not_charged, missed lesson CHARGED (40): the make-up is free, so the family never pays twice');
select pg_temp.les('F4', :'K3', -6, '13:00', 'm2');
select pg_temp.mark(:'STF', 'F4', 'absent');
select t.ok(pg_temp.book(:'STF', pg_temp.cid('F4'), 8, '11:00', '12:00') like 'ERR:CHARGE_PENDING%', 'if_missed_not_charged, charge still pending: booking waits');
update lessons set compensation = 0 where id = t.id('F4');
select t.put('ZB4', pg_temp.bkid(pg_temp.book(:'STF', pg_temp.cid('F4'), 8, '11:00', '12:00')));
select t.ok((select makeup_billing = 'normal' from lessons where id = t.id('ZB4')), 'once the charge is typed (0) the make-up can be booked, billed normally');
select pg_temp.les('F5', :'K3', -6, '14:00', 'm2');
select pg_temp.mark(:'STF', 'F5', 'attended');
select pg_temp.expect(:'STF', format('select staff_grant_credit(%L, %L, %L, %L)', t.id('mc'), :'K3', 'goodwill for a lesson that was taught and billed', t.id('F5')), 'ok', 'a credit by hand for a lesson that was taught (and billed)');
select t.put('ZB5', pg_temp.bkid(pg_temp.book(:'STF', pg_temp.cid('F5'), 9, '10:00', '11:00')));
select t.ok((select makeup_billing = 'free' from lessons where id = t.id('ZB5')), 'the missed lesson was billed: the make-up is free');
select t.put('CR7', pg_temp.grant_for(:'K3', 'no missed lesson behind this one'));
select t.put('ZB6', pg_temp.bkid(pg_temp.book(:'STF', t.id('CR7'), 9, '11:00', '12:00')));
select t.ok((select makeup_billing = 'normal' and amount = 60 from lessons where id = t.id('ZB6')), 'a credit with no missed lesson books at the normal price (60)');
select pg_temp.cfg(p_abs => 'all_missed', p_price => 'free');

-- ===================================================================== 12. EXPIRY (earned with a number of days; the boundary; the job)
select pg_temp.cfg(p_abs => 'all_missed', p_exp => 30);
select pg_temp.les('X0', :'K5', -2, '10:00', 'm1');
select pg_temp.mark(:'STF', 'X0', 'cancelled_early');
select t.ok((select expires_on = (select today + 30 from td) from makeup_credits where source_lesson_id = t.id('X0')), 'earned with 30 days: expires_on = today + 30');
select t.ok((select expires_on is null from makeup_credits where id = pg_temp.cid('B1')), 'a credit earned before the setting changed keeps its own (no) expiry');
select t.ok(pg_temp.book(:'STF', pg_temp.cid('X0'), 30, '10:00', '11:00') like '{%', 'booking ON the last day (today + 30) works');
select t.put('CRX0', pg_temp.cid('X0'));
select pg_temp.expect(:'STF', format('select staff_unbook_makeup(%L, %L)', t.id('CRX0'), 'testing the other side of the edge'), 'ok', 'unbook it again');
select t.ok(pg_temp.book(:'STF', t.id('CRX0'), 31, '10:00', '11:00') like 'ERR:TOO_LATE%', 'booking the day AFTER the last day is refused (TOO_LATE)');
select pg_temp.expect(:'STF', format('select staff_grant_credit(%L, %L, %L)', t.id('mc'), :'K5', 'manual credit gets the expiry too'), 'ok', 'a manual grant');
select t.ok((select expires_on = (select today + 30 from td) from makeup_credits where student_id = :'K5'::uuid and source = 'manual' and reason = 'manual credit gets the expiry too'), 'a manual credit expires too');
select pg_temp.cfg(p_abs => 'all_missed', p_exp => 0);
-- credits at the edge (inserted directly: the job only reads dates)
insert into makeup_credits(id, org_id, student_id, source, reason, earned_on, expires_on, status) values
  (gen_random_uuid(), t.id('mc'), :'K5'::uuid, 'manual', 'edge past', (select today - 40 from td), (select today - 1 from td), 'open'),
  (gen_random_uuid(), t.id('mc'), :'K5'::uuid, 'manual', 'edge today', (select today - 40 from td), (select today from td), 'open'),
  (gen_random_uuid(), t.id('mc'), :'K5'::uuid, 'manual', 'edge later', (select today - 40 from td), (select today + 5 from td), 'open'),
  (gen_random_uuid(), t.id('mc'), :'K5'::uuid, 'manual', 'edge never', (select today - 40 from td), null, 'open'),
  (gen_random_uuid(), t.id('mc'), :'K5'::uuid, 'manual', 'edge revoked', (select today - 40 from td), (select today - 3 from td), 'revoked'),
  (gen_random_uuid(), t.id('mc'), :'K5'::uuid, 'manual', 'edge booked soon', (select today - 40 from td), (select today + 2 from td), 'open');
create function pg_temp.edge(p_reason text) returns uuid language sql as $$ select id from makeup_credits where reason = p_reason $$;
select t.put('EB', pg_temp.edge('edge booked soon'));
select t.ok(pg_temp.book(:'STF', t.id('EB'), 1, '08:00', '09:00') like '{%', 'a credit about to end is booked');
create function pg_temp.job(p_day int) returns int language plpgsql as $$
declare r int; d date := (select today + p_day from td);
begin
  set local role service_role;
  select credits_expire_due(d) into r;
  reset role;
  return r;
end $$;
select pg_temp.expect(:'OWN', 'select credits_expire_due(current_date)', 'permission denied', 'the owner cannot run the expiry job');
select pg_temp.expect(:'STF', 'select credits_expire_due(current_date)', 'permission denied', 'staff cannot run the expiry job');
select t.eq(pg_temp.job(0), 1, 'the job on the last day: only the credit that ended YESTERDAY expires (one)');
select t.ok(pg_temp.cst(pg_temp.edge('edge past')) = 'expired' and pg_temp.cst(pg_temp.edge('edge today')) = 'open', 'a credit is still open ON its last day');
select t.eq(pg_temp.job(0), 0, 'running the job again changes nothing');
select t.eq(pg_temp.nev(pg_temp.edge('edge past'), 'expired'), 1, 'one expired event');
select t.eq(pg_temp.job(1), 1, 'the day after the last day it expires');
select t.ok(pg_temp.cst(pg_temp.edge('edge today')) = 'expired' and pg_temp.cst(pg_temp.edge('edge later')) = 'open', 'and the one ending later is still open');
select t.eq(pg_temp.job(10), 1, 'ten days on: the "later" credit expires (the only open one that has ended)');
select t.ok(pg_temp.cst(pg_temp.edge('edge never')) = 'open', 'a credit that never expires is never touched');
select t.ok(pg_temp.cst(pg_temp.edge('edge revoked')) = 'revoked', 'a revoked credit is never touched');
select t.ok(pg_temp.cst(t.id('EB')) = 'booked', 'a BOOKED credit never expires (its make-up is arranged)');
select t.ok((select count(*) >= 3 from audit_log where action = 'credit_expired'), 'each expiry is audited');
select pg_temp.expect(:'STF', format('select staff_revoke_credit(%L, %L)', pg_temp.edge('edge past'), 'too late'), 'NO_CHANGE', 'revoking an expired credit');
select t.ok(pg_temp.call(:'STF', format('select staff_book_makeup(%L, (select today + 1 from td), %L, %L)', pg_temp.edge('edge past'), '08:00', '09:00')) like 'ERR:NOT_OPEN%', 'booking an expired credit');
-- a credit whose last day has passed but the job has not run yet is already unusable
insert into makeup_credits(id, org_id, student_id, source, reason, earned_on, expires_on, status)
  values (gen_random_uuid(), t.id('mc'), :'K5'::uuid, 'manual', 'ended not yet swept', (select today - 40 from td), (select today - 1 from td), 'open');
select t.ok(pg_temp.book(:'STF', pg_temp.edge('ended not yet swept'), 1, '08:00', '09:00') like 'ERR:EXPIRED%', 'a credit past its last day is refused even before the job has run');
select t.ok((select (e->>'expired_by_date')::boolean and not (e->>'can_book')::boolean from jsonb_array_elements(
              (pg_temp.call(:'STF', format('select staff_credit_list(%L, %L, %L)', t.id('mc'), 'open', :'K5'))::jsonb)->'rows') e where e->>'reason' = 'ended not yet swept'),
            'the list marks it expired_by_date with no book button');

-- ===================================================================== 13. THE INVOICE RUN never bills a make-up twice
create function pg_temp.preview(p_user text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  set local role authenticated;
  select centre_invoice_run_preview(t.id('mc'), date_trunc('month', (select today from td))::date) into r;
  reset role;
  return r;
end $$;
create function pg_temp.nlines(p jsonb, p_lesson uuid) returns int language sql as $$
  select count(*)::int from jsonb_path_query(p, '$.ready[*].lines[*]') l where l->>'lesson_id' = p_lesson::text $$;
create function pg_temp.cents(p jsonb, p_lesson uuid) returns bigint language sql as $$
  select coalesce(sum((l->>'line_cents')::bigint), 0) from jsonb_path_query(p, '$.ready[*].lines[*]') l where l->>'lesson_id' = p_lesson::text $$;
-- a normal lesson with amount 0 is priced at rate x hours: the very reason a free make-up must be skipped by its flag
select pg_temp.les('I0', :'K6', 0, '06:00', 'm1', 'done');
update lessons set amount = 0 where id = t.id('I0');
-- 1. FREE make-up whose missed lesson was charged (compensation 40)
select pg_temp.cfg(p_abs => 'all_missed', p_price => 'if_missed_not_charged', p_exp => 0);
select pg_temp.les('I1', :'K6', -1, '07:00', 'm1');
select pg_temp.mark(:'STF', 'I1', 'late_cancelled');
update lessons set compensation = 40 where id = t.id('I1');
select t.put('MI1', pg_temp.bkid(pg_temp.book(:'STF', pg_temp.cid('I1'), 0, '08:00', '09:00')));
select pg_temp.mark(:'STF', 'MI1', 'attended');
-- 2. NORMAL make-up whose missed lesson was not charged (compensation 0)
select pg_temp.les('I2', :'K6', -1, '08:00', 'm1');
select pg_temp.mark(:'STF', 'I2', 'cancelled_early');
update lessons set compensation = 0 where id = t.id('I2');
select t.put('MI2', pg_temp.bkid(pg_temp.book(:'STF', pg_temp.cid('I2'), 0, '09:00', '10:00')));
select pg_temp.mark(:'STF', 'MI2', 'attended');
select pg_temp.preview(:'OWN') as pv \gset
select t.ok((:'pv'::jsonb->>'built')::boolean, 'the month''s invoice run is built for this centre');
select t.eq(pg_temp.nlines(:'pv'::jsonb, t.id('I1')), 1, 'the missed lesson that was charged appears once');
select t.eq(pg_temp.cents(:'pv'::jsonb, t.id('I1')), 4000, 'at its charge of S$40');
select t.eq(pg_temp.nlines(:'pv'::jsonb, t.id('MI1')), 0, 'its make-up (free) is NOT on the invoice: nobody pays twice');
select t.eq(pg_temp.nlines(:'pv'::jsonb, t.id('I2')), 0, 'a missed lesson with no charge adds nothing');
select t.eq(pg_temp.nlines(:'pv'::jsonb, t.id('MI2')), 1, 'its make-up (normal) is on the invoice exactly once');
select t.eq(pg_temp.cents(:'pv'::jsonb, t.id('MI2')), 6000, 'at the normal price S$60');
select t.eq(pg_temp.nlines(:'pv'::jsonb, t.id('I0')), 1, 'control: a plain lesson with amount 0 IS billed (rate x hours), which is why the make-up flag is needed');
select t.eq(pg_temp.cents(:'pv'::jsonb, t.id('I0')), 6000, 'at S$60');
-- 3. FREE under makeup_price = free even though the missed lesson was not charged
select pg_temp.cfg(p_abs => 'all_missed', p_price => 'free');
select pg_temp.les('I3', :'K6', -1, '10:00', 'm1');
select pg_temp.mark(:'STF', 'I3', 'cancelled_early');
update lessons set compensation = 0 where id = t.id('I3');
select t.put('MI3', pg_temp.bkid(pg_temp.book(:'STF', pg_temp.cid('I3'), 0, '10:00', '11:00')));
select pg_temp.mark(:'STF', 'MI3', 'attended');
select pg_temp.preview(:'OWN') as pv \gset
select t.eq(pg_temp.nlines(:'pv'::jsonb, t.id('MI3')), 0, 'makeup_price = free: not billed');
select t.eq(pg_temp.nlines(:'pv'::jsonb, t.id('MI2')), 1, 'the earlier normal make-up is still billed once');
-- once a draft exists the lines are on a document: a second run does not bill them again
select pg_temp.call(:'OWN', format('select centre_invoice_run_create_drafts(%L, date_trunc(%L, current_date)::date)', t.id('mc'), 'month')) as cd \gset
select pg_temp.preview(:'OWN') as pv2 \gset
select t.eq(pg_temp.nlines(:'pv2'::jsonb, t.id('MI2')), 0, 'after the drafts are made the normal make-up is not offered a second time');
select t.ok((select count(*) = 1 from centre_invoice_lines where lesson_id = t.id('MI2')), 'it is on exactly one invoice line');
select t.ok((select count(*) = 0 from centre_invoice_lines where lesson_id in (t.id('MI1'), t.id('MI3'))), 'the free make-ups are on no invoice line at all');
-- an invoiced make-up cannot be unbooked
select pg_temp.expect(:'STF', format('select staff_unbook_makeup(%L, %L)', pg_temp.cid('I2'), 'it is invoiced'), 'IN_USE', 'a used credit cannot be unbooked (the make-up is marked and invoiced)');

-- ===================================================================== 14. NOBODY WRITES THE TABLES OR THE LINK BY HAND
select set_config('request.jwt.claims', '', false);
create function pg_temp.dbfails(p_sql text, p_like text, p_msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin
  begin execute p_sql; exception when others then m := sqlerrm; end;
  if m not like p_like then raise exception 'FAIL: % (got "%", expected "%")', p_msg, m, p_like; end if;
  raise notice 'PASS refused: % (%)', p_msg, m;
end $$;
select pg_temp.expect(:'OWN', 'select count(*) from makeup_credits', 'permission denied', 'a signed-in owner has no table access to credits');
select pg_temp.expect(:'OWN', 'select count(*) from makeup_credit_events', 'permission denied', 'nor to events');
select pg_temp.expect(:'OWN', format('insert into makeup_credits(org_id, student_id, source, reason, earned_on) values (%L, %L, %L, %L, current_date)', t.id('mc'), :'K1', 'manual', 'sneaky'), 'permission denied', 'a signed-in owner cannot insert a credit');
select pg_temp.expect(:'OWN', 'update makeup_credits set status = ''open''', 'permission denied', 'nor change one');
select pg_temp.dbfails($q$ update makeup_credits set status = 'open' where id = (select id from makeup_credits where status = 'used' limit 1) $q$, '%append-only', 'changing a credit''s status outside the functions (even as the database owner)');
select pg_temp.dbfails($q$ update makeup_credits set reason = 'rewritten' where id = (select id from makeup_credits limit 1) $q$, '%append-only', 'rewriting a credit''s reason');
select pg_temp.dbfails($q$ delete from makeup_credits where id = (select id from makeup_credits limit 1) $q$, '%append-only', 'deleting a credit');
select pg_temp.dbfails($q$ update makeup_credit_events set reason = 'rewritten' where id = (select min(id) from makeup_credit_events) $q$, '%append-only', 'rewriting history');
select pg_temp.dbfails($q$ delete from makeup_credit_events where id = (select min(id) from makeup_credit_events) $q$, '%append-only', 'deleting history');
select pg_temp.les('N1', :'K1', 12, '10:00', 'm1');
select t.ok(pg_temp.call(:'OWN', format('with u as (update lessons set makeup_billing = %L where id = %L returning 1) select count(*) from u', 'free', t.id('N1'))) like 'ERR:LOCKED%',
            'marking a normal lesson "free" by hand (to dodge billing) is refused');
select t.ok(pg_temp.call(:'OWN', format('with u as (update lessons set makeup_credit_id = %L where id = %L returning 1) select count(*) from u', t.id('CR1'), t.id('N1'))) like 'ERR:LOCKED%',
            'pointing a lesson at somebody''s credit by hand is refused');
select t.ok(pg_temp.call(:'OWN', format('with u as (update lessons set makeup_credit_id = null where id = %L returning 1) select count(*) from u', t.id('MK1'))) like 'ERR:LOCKED%',
            'unlinking a make-up by hand (to bill it twice) is refused');
select t.ok(pg_temp.call(:'OWN', format('with u as (update lessons set makeup_billing = %L where id = %L returning 1) select count(*) from u', 'normal', t.id('MK1'))) like 'ERR:LOCKED%',
            'switching a free make-up to normal by hand is refused');
select t.ok(pg_temp.call(:'OWN', format($q$insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, makeup_credit_id, makeup_billing)
              values (%L, %L, %L, current_date + 20, '10:00', '11:00', 60, %L, 'free')$q$, :'OWN', t.id('mc'), :'K1', t.id('CR1'))) like 'ERR:LOCKED%', 'inserting a lesson with a make-up link by hand is refused');
select t.ok(pg_temp.call(:'OWN', format('with u as (update lessons set subject = %L, amount = 61 where id = %L returning 1) select count(*) from u', 'Science', t.id('MK1'))) = '1',
            'everything else about a make-up lesson can still be edited normally (subject, price)');

-- ===================================================================== 15. SOLO TUTORS ARE UNTOUCHED
select set_config('request.jwt.claims', '', false);
insert into students(id, tutor_id, org_id, name, level, contact) values ('00000000-0000-0000-0000-000000b18171', :'SOLO', t.id('solo'), 'Solo Kid', 'P3', '91117777');
insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status)
  values ('00000000-0000-0000-0000-000000b18172', :'SOLO', t.id('solo'), '00000000-0000-0000-0000-000000b18171', (select today - 1 from td), '10:00', '11:00', 50, 50, 'scheduled');
update lessons set attendance = 'cancelled_early' where id = '00000000-0000-0000-0000-000000b18172';
update lessons set status = 'cancelled', changed_by_tutor_what = 'cancelled' where id = '00000000-0000-0000-0000-000000b18172';
select t.eq((select count(*) from makeup_credits where org_id = t.id('solo')), 0, 'a solo tutor''s missed lesson earns no credit, whatever happens to it');
select t.eq((select count(*) from lessons where org_id = t.id('solo') and (makeup_credit_id is not null or makeup_billing is not null)), 0, 'and has no make-up links');

-- ===================================================================== 16. THE OWED LIST (what staff read)
select pg_temp.cfg(p_abs => 'all_missed');
select pg_temp.call(:'STF', format('select staff_credit_list(%L, %L, null, 1, 100)', t.id('mc'), 'all')) as lj \gset
select t.eq((:'lj'::jsonb->'counts'->>'open')::int, (select count(*) from makeup_credits where org_id = t.id('mc') and status = 'open'), 'counts.open matches the table');
select t.eq((:'lj'::jsonb->'counts'->>'booked')::int, (select count(*) from makeup_credits where org_id = t.id('mc') and status = 'booked'), 'counts.booked matches');
select t.eq((:'lj'::jsonb->'counts'->>'used')::int, (select count(*) from makeup_credits where org_id = t.id('mc') and status = 'used'), 'counts.used matches');
select t.eq((:'lj'::jsonb->'counts'->>'expired')::int, (select count(*) from makeup_credits where org_id = t.id('mc') and status = 'expired'), 'counts.expired matches');
select t.eq((:'lj'::jsonb->'counts'->>'revoked')::int, (select count(*) from makeup_credits where org_id = t.id('mc') and status = 'revoked'), 'counts.revoked matches');
select t.eq((:'lj'::jsonb->>'total')::int, (select count(*) from makeup_credits where org_id = t.id('mc')), 'status all: every credit');
select t.ok(not exists (select 1 from pg_temp.keys(:'lj'::jsonb) k where k in ('rate', 'amount', 'paid', 'compensation', 'charge_note', 'total_cents') or k ~ '_cents$'), 'no money field anywhere in the list');
select t.ok((select e->>'student_name' = 'Kid Two' and e->'missed'->>'attendance' = 'cancelled_early' and e->'missed'->>'tutor_name' = 'Tutor One' and e->>'status' = 'booked'
                    and e->'makeup'->>'billing' = 'free' and e->'makeup'->>'date' is not null
               from jsonb_array_elements(:'lj'::jsonb->'rows') e where e->>'credit_id' = t.id('CR1')::text), 'a booked row shows the student, the missed lesson with its tutor and mark, and the make-up');
select t.ok((select (e->>'can_unbook')::boolean and not (e->>'can_revoke')::boolean and not (e->>'can_book')::boolean
               from jsonb_array_elements(:'lj'::jsonb->'rows') e where e->>'credit_id' = t.id('CR1')::text), 'booked: can unbook, cannot revoke or book');
select t.ok((select not (e->>'can_unbook')::boolean from jsonb_array_elements(:'lj'::jsonb->'rows') e where e->>'credit_id' = t.id('CR6')::text), 'used: no unbook');
select t.ok((select (e->>'can_revoke')::boolean and (e->>'can_book')::boolean from jsonb_array_elements(:'lj'::jsonb->'rows') e where e->>'credit_id' = pg_temp.cid('B1')::text), 'open: can revoke and book');
select t.ok((pg_temp.call(:'VIEW', format('select staff_credit_list(%L)', t.id('mc')))::jsonb->>'can_grant')::boolean = false, 'look-only staff: can_grant false');
select t.ok((select bool_and(not (e->>'can_revoke')::boolean and not (e->>'can_book')::boolean) from jsonb_array_elements(pg_temp.call(:'VIEW', format('select staff_credit_list(%L)', t.id('mc')))::jsonb->'rows') e), 'look-only staff: no revoke or book buttons on any row');
select t.eq((pg_temp.call(:'STF', format('select staff_credit_list(%L, %L, %L)', t.id('mc'), 'all', :'K2'))::jsonb->>'total')::int, (select count(*) from makeup_credits where student_id = :'K2'::uuid), 'filter by student (the chip on the student sheet)');
select t.eq((pg_temp.call(:'STF', format('select staff_credit_list(%L, %L)', t.id('mc'), 'open'))::jsonb->>'total')::int, (select count(*) from makeup_credits where org_id = t.id('mc') and status = 'open'), 'filter open');
select t.eq(jsonb_array_length(pg_temp.call(:'STF', format('select staff_credit_list(%L, %L, null, 1, 2)', t.id('mc'), 'all'))::jsonb->'rows'), 2, 'paging: page 1 of size 2 has 2 rows');
select t.eq((pg_temp.call(:'STF', format('select staff_credit_list(%L, %L, null, 2, 2)', t.id('mc'), 'all'))::jsonb->>'total')::int, (select count(*) from makeup_credits where org_id = t.id('mc')), 'paging: the total stays the same on page 2');
select t.ok(pg_temp.call(:'STF', format('select staff_credit_list(%L, %L)', t.id('mc'), 'everything')) like 'ERR:BAD_FILTER%', 'an unknown filter');
select t.ok(pg_temp.call(:'STF', format('select staff_credit_list(%L, %L, null, 1, 101)', t.id('mc'), 'all')) like 'ERR:BAD_PAGE%', 'a page size over 100');
select t.ok(pg_temp.call(:'STF', format('select staff_credit_list(%L, %L, %L)', t.id('mc'), 'all', :'KX')) like 'ERR:NOT_FOUND%', 'a student of another centre');
select t.ok(pg_temp.call(:'STF', format('select staff_credit_list(%L, %L)', t.id('mc'), 'all')) <> pg_temp.call(:'OWN2', format('select staff_credit_list(%L, %L)', t.id('mc2'), 'all')), 'two centres never see each other''s credits');
select t.eq((pg_temp.call(:'OWN2', format('select staff_credit_list(%L, %L)', t.id('mc2'), 'all'))::jsonb->>'total')::int, 0, 'the other centre has none');

-- ===================================================================== 17. the audit trail and the undo
select t.ok((select count(distinct action) >= 6 from audit_log where action in ('credit_earned', 'credit_booked', 'credit_returned', 'credit_used', 'credit_revoked', 'credit_expired')),
            'every kind of change is in the audit log (earned, booked, returned, used, revoked, expired)');
select t.ok((select count(*) = 0 from audit_log where action like 'credit_%' and (after ? 'amount' or after ? 'rate' or after ? 'compensation')), 'and the audit rows carry no money');
select t.eq((select count(distinct kind) from makeup_credit_events), 6, 'the events table has all six kinds');
select t.ok(not exists (select 1 from makeup_credit_events e where e.actor is null and e.kind <> 'expired'), 'every event has a person, except the expiry job');
