-- T3.10 tests: centre staff ADD PAST LESSONS (backfill): staff_past_lessons_options / _pattern / _preview and staff_add_past_lessons.
-- Runs after tutor_moves_test.sql in the same throwaway database (reuses the t.* helpers). Builds its own centre and made-up people (all names FAKE).
-- Covers: who may call; the setting backfill_allowed_days (validator + every value); every refusal rule; all-or-nothing; idempotency; the reason; remarks;
-- prices; audit per lesson; the real flow (a student created today, five past lessons, attended -> invoice preview lines -> deposit raised); solo untouched.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000c101', 'pl.owner@centre.test'),  ('00000000-0000-0000-0000-00000000c102', 'pl.staff@centre.test'),
  ('00000000-0000-0000-0000-00000000c103', 'pl.desk@centre.test'),   ('00000000-0000-0000-0000-00000000c104', 'pl.tutor@centre.test'),
  ('00000000-0000-0000-0000-00000000c105', 'pl.outsider@centre.test'), ('00000000-0000-0000-0000-00000000c106', 'pl.off@centre.test'),
  ('00000000-0000-0000-0000-00000000c107', 'pl.owner2@centre.test'), ('00000000-0000-0000-0000-00000000c108', 'pl.tutor2@centre.test');
\set o1 '00000000-0000-0000-0000-00000000c101'
\set stf '00000000-0000-0000-0000-00000000c102'
\set desk '00000000-0000-0000-0000-00000000c103'
\set tut '00000000-0000-0000-0000-00000000c104'
\set out '00000000-0000-0000-0000-00000000c105'
\set off '00000000-0000-0000-0000-00000000c106'
\set o2 '00000000-0000-0000-0000-00000000c107'
\set tut2 '00000000-0000-0000-0000-00000000c108'
\set solo '00000000-0000-0000-0000-0000000000a1'

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today,
  -- a run of five days inside ONE month, all before today ("last week" without crossing a month end)
  case when extract(day from (now() at time zone 'Asia/Singapore')::date - 1) >= 5 then (now() at time zone 'Asia/Singapore')::date - 1
       else date_trunc('month', (now() at time zone 'Asia/Singapore')::date)::date - 1 end as d0,
  date_trunc('month', (now() at time zone 'Asia/Singapore')::date)::date as m_now;
grant select on td to authenticated, anon;

-- settings: postpaid, per family, a fixed deposit of S$120 with the first invoice, GST 9% exclusive
create function pg_temp.base() returns jsonb language sql as $$
  select jsonb_set(jsonb_set(jsonb_set(t.centre_settings(), '{profile,invoice_prefix}', '"INV"'),
         '{billing}', jsonb_build_object('model', 'postpaid_lessons',
             'deposit', '{"mode":"fixed","percent_bp":5000,"taxable":false,"due":"with_first_invoice","waived_by":"issue_invoices"}'::jsonb,
             'one_off_fees', jsonb_build_object('registration_cents', 0, 'deposit_cents', 12000, 'materials_cents', 0),
             'absences', '{"mode":"charged","notice_hours":24}'::jsonb)),
         '{invoicing}', '{"grouping":"family","due_days":7,"review_before_sending":true}'::jsonb) $$;
-- save one lessons.* value as the owner (null removes the key)
create function pg_temp.lset(p_org uuid, p_owner uuid, p_key text, p_val jsonb) returns void language plpgsql as $$
declare cur jsonb;
begin
  perform t.as(p_owner::text);
  cur := org_settings_on(p_org, current_date);
  if p_val is null then cur := cur #- array['lessons', p_key]; else cur := jsonb_set(cur, array['lessons', p_key], p_val, true); end if;
  perform org_save_settings(p_org, cur, current_date);
end $$;
create function pg_temp.refused(p_user text, p_sql text, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  begin execute p_sql; exception when others then m := sqlerrm; end;
  if m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS refused: % (%)', p_msg, m;
end $$;
-- one list item: `off` days before today, 16:00-17:30 (1.5 hours), rate S$60/hour unless told otherwise (null = let the database pick)
create function pg_temp.it(p_off int, p_start text default '16:00', p_end text default '17:30', p_rate text default '60') returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('date', (select today from td) - p_off, 'start', p_start, 'end', p_end, 'rate', p_rate)) $$;
create function pg_temp.items(variadic p_offs int[]) returns jsonb language sql as $$ select jsonb_agg(pg_temp.it(o)) from unnest(p_offs) o $$;
-- run any staff past-lesson call as a signed-in user: the answer, or the error text
create function pg_temp.call(p_user text, p_sql text) returns text language plpgsql as $$
declare m text; res text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  begin execute 'set role authenticated'; execute 'select (' || p_sql || ')::text' into res; m := res; exception when others then m := sqlerrm; end;
  execute 'reset role'; return m;
end $$;
create function pg_temp.add(p_user text, p_stu text, p_tutor text, p_items jsonb, p_reason text default 'Started last week, taught before we set the timetable up',
                            p_att boolean default false, p_remarks text default null, p_hol boolean default false, p_allow boolean default false, p_org text default 'pl') returns text language sql as $$
  select pg_temp.call(p_user, format('staff_add_past_lessons(%L::uuid, %L::uuid, %L::uuid, %L::jsonb, %L, %L::boolean, %L, %L::boolean, %L::boolean)',
                      t.id(p_org), t.id(p_stu), case when p_tutor is null then null else t.id(p_tutor) end, p_items, p_reason, p_att, p_remarks, p_hol, p_allow)) $$;
create function pg_temp.prev(p_user text, p_stu text, p_tutor text, p_items jsonb, p_hol boolean default false, p_allow boolean default false, p_org text default 'pl') returns text language sql as $$
  select pg_temp.call(p_user, format('staff_past_lessons_preview(%L::uuid, %L::uuid, %L::uuid, %L::jsonb, %L::boolean, %L::boolean)',
                      t.id(p_org), t.id(p_stu), case when p_tutor is null then null else t.id(p_tutor) end, p_items, p_hol, p_allow)) $$;
-- the verdict (code) of row n of a preview
create function pg_temp.code(p_json text, p_n int default 1) returns text language sql as $$ select p_json::jsonb #>> array['rows', (p_n - 1)::text, 'code'] $$;
create function pg_temp.state(p_json text, p_n int default 1) returns text language sql as $$ select p_json::jsonb #>> array['rows', (p_n - 1)::text, 'state'] $$;
create function pg_temp.expect(p_got text, p_expect text, p_msg text) returns void language plpgsql as $$
begin
  if p_got is distinct from p_expect and p_got not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, p_got, p_expect; end if;
  raise notice 'PASS: % (%)', p_msg, left(p_got, 90);
end $$;
create function pg_temp.nles(p_stu text) returns int language sql security definer as $$ select count(*)::int from lessons where student_id = t.id(p_stu) $$;
grant execute on all functions in schema pg_temp to public;

-- ===================================================================== the world
select t.put('solo_org', org_personal(:'solo'));
select count(*) as solo_lessons from lessons where org_id = t.id('solo_org') \gset
set role authenticated; select t.as(:'o1');
select t.put('pl', org_create_centre('Past Lessons Centre', pg_temp.base()));
select t.as(:'o2');
select t.put('pl2', org_create_centre('Other Past Centre', pg_temp.base()));
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('pl'), :'stf',  'Staff Sam',   'staff', array['manage_timetable'], 'active'),
  (t.id('pl'), :'desk', 'Front Desk',  'staff', array['manage_students'], 'active'),
  (t.id('pl'), :'tut',  'Tutor Tia',   'tutor', '{}', 'active'),
  (t.id('pl'), :'off',  'Switched off', 'staff', array['manage_timetable'], 'disabled'),
  (t.id('pl2'), :'tut2', 'Tutor Elsewhere', 'tutor', '{}', 'active');
select t.put('tia', (select id from memberships where org_id = t.id('pl') and user_id = :'tut'));
select t.put('owner_m', (select id from memberships where org_id = t.id('pl') and user_id = :'o1' and role = 'owner'));
select t.put('tia2', (select id from memberships where org_id = t.id('pl2') and user_id = :'tut2'));
insert into memberships(org_id, user_id, display_name, role, permissions, status) values (t.id('pl'), :'tut2', 'Tutor Two', 'tutor', '{}', 'active');
select t.put('tom', (select id from memberships where org_id = t.id('pl') and user_id = :'tut2'));
-- the PRODUCT FLOW student: created today, nothing on the timetable. Others: an older student, one who leaves soon, one of the other centre
insert into students(id, tutor_id, org_id, name, level) values
  (gen_random_uuid(), :'o1', t.id('pl'), 'Newcomer Nia', 'P4'), (gen_random_uuid(), :'o1', t.id('pl'), 'Regular Ray', 'P6'),
  (gen_random_uuid(), :'o1', t.id('pl'), 'Leaver Lou', 'S1'),   (gen_random_uuid(), :'o1', t.id('pl'), 'Closed Cat', 'S2'),
  (gen_random_uuid(), :'o1', t.id('pl'), 'Holiday Hal', 'S3'),  (gen_random_uuid(), :'o1', t.id('pl'), 'Clash Cy', 'S4'),
  (gen_random_uuid(), :'o1', t.id('pl'), 'Plain Pat', 'S4'),    (gen_random_uuid(), :'o1', t.id('pl'), 'Remark Rae', 'S4'),
  (gen_random_uuid(), :'o1', t.id('pl'), 'Billing Bo', 'S4'),   (gen_random_uuid(), :'o1', t.id('pl'), 'Slot Sue', 'S4');
insert into students(id, tutor_id, org_id, name, level) values (gen_random_uuid(), :'o2', t.id('pl2'), 'Elsewhere Eve', 'P1');
do $$ declare n text; begin
  foreach n in array array['Newcomer Nia', 'Regular Ray', 'Leaver Lou', 'Closed Cat', 'Holiday Hal', 'Clash Cy', 'Plain Pat', 'Remark Rae', 'Billing Bo', 'Slot Sue'] loop
    perform t.put(split_part(lower(n), ' ', 1), (select id from students where name = n and org_id = t.id('pl')));
  end loop;
  perform t.put('eve', (select id from students where name = 'Elsewhere Eve'));
end $$;
update students set created_at = now() - interval '200 days' where id = t.id('regular');
update students set end_date = (select today - 3 from td) where id = t.id('leaver');
select t.eq((select count(*) from branches where org_id = t.id('pl')) + (select count(*) from rooms where org_id = t.id('pl')), 0, 'the test centre has no branch and no room (remote 1-to-1)');

-- ===================================================================== 1. who may call what
select pg_temp.expect(pg_temp.call(:'stf', format('staff_past_lessons_options(%L::uuid, %L::uuid)', t.id('pl'), t.id('newcomer'))), '{%', 'staff with manage_timetable can open the form');
select t.ok((pg_temp.call(:'o1', format('staff_past_lessons_options(%L::uuid, %L::uuid)', t.id('pl'), t.id('newcomer')))::jsonb ->> 'can_add')::boolean, 'the owner can add');
select t.ok(not (pg_temp.call(:'desk', format('staff_past_lessons_options(%L::uuid, %L::uuid)', t.id('pl'), t.id('newcomer')))::jsonb ->> 'can_add')::boolean
            and (pg_temp.call(:'desk', format('staff_past_lessons_options(%L::uuid, %L::uuid)', t.id('pl'), t.id('newcomer')))::jsonb -> 'last_rate') = 'null'::jsonb,
            'front desk (manage_students only) can look, but can_add is false and no price is returned');
select pg_temp.expect(pg_temp.add(:'desk', 'newcomer', 'tia', pg_temp.items(1)), 'NOT_ALLOWED', 'front desk cannot add');
select pg_temp.expect(pg_temp.prev(:'desk', 'newcomer', 'tia', pg_temp.items(1)), 'NOT_ALLOWED', 'front desk cannot preview either');
select pg_temp.expect(pg_temp.call(:'desk', format('staff_past_lessons_pattern(%L::uuid, %L::uuid, current_date - 10, current_date - 1)', t.id('pl'), t.id('newcomer'))), 'NOT_ALLOWED', 'front desk cannot ask for the pattern');
do $$ declare u text; begin
  foreach u in array array['00000000-0000-0000-0000-00000000c104', '00000000-0000-0000-0000-00000000c105', '00000000-0000-0000-0000-00000000c106',
                           '00000000-0000-0000-0000-00000000c107', '00000000-0000-0000-0000-0000000000a1'] loop
    perform pg_temp.expect(pg_temp.add(u, 'newcomer', 'tia', pg_temp.items(1)), 'NOT_FOUND', 'not owner/staff here (' || right(u, 4) || '): add');
    perform pg_temp.expect(pg_temp.prev(u, 'newcomer', 'tia', pg_temp.items(1)), 'NOT_FOUND', 'not owner/staff here (' || right(u, 4) || '): preview');
    perform pg_temp.expect(pg_temp.call(u, format('staff_past_lessons_options(%L::uuid, %L::uuid)', t.id('pl'), t.id('newcomer'))), 'NOT_FOUND', 'not owner/staff here (' || right(u, 4) || '): options');
  end loop;
end $$;
select pg_temp.expect(pg_temp.add(:'stf', 'newcomer', 'tia', pg_temp.items(1), p_org => 'solo_org'), 'NOT_FOUND', 'a solo organisation has no such function');
select pg_temp.expect(pg_temp.add(:'solo', 'newcomer', 'tia', pg_temp.items(1), p_org => 'solo_org'), 'NOT_FOUND', 'a solo tutor cannot use it on their own organisation');
select pg_temp.expect(pg_temp.add(:'stf', 'eve', 'tia', pg_temp.items(1)), 'NOT_FOUND', 'a student of ANOTHER centre is NOT_FOUND');
select pg_temp.expect(pg_temp.call(:'stf', format('staff_add_past_lessons(%L::uuid, gen_random_uuid(), %L::uuid, %L::jsonb, ''why'')', t.id('pl'), t.id('tia'), pg_temp.items(1))), 'NOT_FOUND', 'an unknown student');
select pg_temp.refused(:'stf', format('set role anon; select staff_add_past_lessons(%L, %L, %L, %L::jsonb, ''why'')', t.id('pl'), t.id('newcomer'), t.id('tia'), pg_temp.items(1)), 'permission denied', 'a signed-out visitor cannot add'); reset role;
select t.ok(not has_function_privilege('authenticated', 'public.staff_past_lessons_plan(uuid,uuid,uuid,jsonb,boolean,boolean,date)', 'execute')
            and not has_function_privilege('authenticated', 'public.staff_past_lessons_gate(uuid,uuid,uuid,boolean,boolean)', 'execute'), 'the rulebook and the gate are internal: not callable from the browser');
select t.ok((select bool_and(prosecdef and not has_function_privilege('anon', p.oid, 'execute') and has_function_privilege('authenticated', p.oid, 'execute'))
               from pg_proc p where proname in ('staff_past_lessons_options', 'staff_past_lessons_pattern', 'staff_past_lessons_preview', 'staff_add_past_lessons')),
            'the four functions are SECURITY DEFINER, closed to anon, open to signed-in users (who are then checked inside)');
-- the tutor to give the lessons to
select pg_temp.expect(pg_temp.add(:'stf', 'newcomer', null, pg_temp.items(1)), 'BAD_TUTOR', 'a tutor is required');
select pg_temp.expect(pg_temp.add(:'stf', 'newcomer', 'tia2', pg_temp.items(1)), 'NOT_AVAILABLE', 'a tutor of another centre cannot be given lessons here');
update memberships set status = 'disabled' where id = t.id('tom');
select pg_temp.expect(pg_temp.add(:'stf', 'newcomer', 'tom', pg_temp.items(1)), 'NOT_AVAILABLE', 'a switched-off tutor cannot be given lessons');
update memberships set status = 'active' where id = t.id('tom');
select pg_temp.expect(pg_temp.prev(:'stf', 'newcomer', 'owner_m', pg_temp.items(1)), '{%', 'the owner may be the tutor (they teach too)');
select t.eq(pg_temp.nles('newcomer'), 0, 'nothing was created by any of the refusals');

-- ===================================================================== 2. the centre's setting lessons.backfill_allowed_days (validator, then every value)
create function pg_temp.lsave(p_val jsonb) returns text language plpgsql as $$
begin perform pg_temp.lset(t.id('pl'), '00000000-0000-0000-0000-00000000c101', 'backfill_allowed_days', p_val); return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.lsave(jsonb) to public;
select pg_temp.expect(pg_temp.lsave('-1'::jsonb), 'Days staff may add past lessons must be 0-366', 'the setting refuses a negative number');
select pg_temp.expect(pg_temp.lsave('367'::jsonb), 'Days staff may add past lessons must be 0-366', 'the setting refuses 367');
select pg_temp.expect(pg_temp.lsave('"x"'::jsonb), 'Days staff may add past lessons must be 0-366', 'the setting refuses text');
select pg_temp.expect(pg_temp.lsave('1.5'::jsonb), 'Days staff may add past lessons must be 0-366', 'the setting refuses a fraction');
select pg_temp.expect(pg_temp.lsave('true'::jsonb), 'Days staff may add past lessons must be 0-366', 'the setting refuses yes/no');
select pg_temp.expect(pg_temp.lsave('31'::jsonb), 'ok', 'the setting accepts 31');
select pg_temp.expect(pg_temp.lsave('0'::jsonb), 'ok', 'the setting accepts 0 (off)');
select pg_temp.expect(pg_temp.lsave('366'::jsonb), 'ok', 'the setting accepts 366 (the maximum)');
select pg_temp.expect(pg_temp.lsave(null), 'ok', 'the key may be absent (every older centre)');
select pg_temp.expect(pg_temp.lsave('null'::jsonb), 'ok', 'a null value is the same as absent');
select pg_temp.lset(t.id('pl'), :'o1', 'backfill_allowed_days', null);                       -- absent = 31
select t.eq((pg_temp.call(:'stf', format('staff_past_lessons_options(%L::uuid, %L::uuid)', t.id('pl'), t.id('newcomer')))::jsonb ->> 'allowed_days')::int, 31, 'absent means 31 days');
select pg_temp.expect(pg_temp.state(pg_temp.prev(:'stf', 'newcomer', 'tia', pg_temp.items(31))), 'new', '31 days back is allowed by default');
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'newcomer', 'tia', pg_temp.items(32))), 'TOO_OLD', '32 days back is too old by default');
select pg_temp.lset(t.id('pl'), :'o1', 'backfill_allowed_days', '0'::jsonb);
select t.ok(not (pg_temp.call(:'stf', format('staff_past_lessons_options(%L::uuid, %L::uuid)', t.id('pl'), t.id('newcomer')))::jsonb ->> 'enabled')::boolean, '0 = off: the form says the option is switched off');
select pg_temp.expect(pg_temp.prev(:'stf', 'newcomer', 'tia', pg_temp.items(1)), 'BACKFILL_OFF', '0 = off: the preview says so in plain words');
select pg_temp.expect(pg_temp.add(:'stf', 'newcomer', 'tia', pg_temp.items(1)), 'BACKFILL_OFF', '0 = off: nothing can be added, not even by the owner');
select pg_temp.expect(pg_temp.add(:'o1', 'newcomer', 'tia', pg_temp.items(1)), 'BACKFILL_OFF', '0 = off: not even by the owner');
select t.eq(pg_temp.nles('newcomer'), 0, 'and nothing was made');
select pg_temp.lset(t.id('pl'), :'o1', 'backfill_allowed_days', '5'::jsonb);
select pg_temp.expect(pg_temp.state(pg_temp.prev(:'stf', 'newcomer', 'tia', pg_temp.items(5))), 'new', '5 days: 5 days back is allowed');
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'newcomer', 'tia', pg_temp.items(6))), 'TOO_OLD', '5 days: 6 days back is too old');
select t.ok((pg_temp.prev(:'stf', 'newcomer', 'tia', pg_temp.items(6))::jsonb #>> '{rows,0,message}') like '%5 days back%', 'and the message names the centre''s number');
select pg_temp.lset(t.id('pl'), :'o1', 'backfill_allowed_days', '366'::jsonb);
select pg_temp.expect(pg_temp.state(pg_temp.prev(:'stf', 'newcomer', 'tia', pg_temp.items(366))), 'new', '366 days: a year back is allowed');
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'newcomer', 'tia', pg_temp.items(367))), 'TOO_OLD', '366 days: 367 is too old');
select pg_temp.lset(t.id('pl'), :'o1', 'backfill_allowed_days', null);
select t.ok((select count(*) from org_settings where org_id = t.id('pl') and settings #>> '{lessons,backfill_allowed_days}' = '366') >= 1, 'settings stay append-only: the old values are still in the history');

-- ===================================================================== 3. the rules, one at a time (preview says it, add refuses it)
-- not past
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'plain', 'tia', pg_temp.items(0))), 'NOT_PAST', 'today is not a past day (Create lessons makes today)');
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'plain', 'tia', pg_temp.items(-3))), 'NOT_PAST', 'a future day is refused');
-- bad items
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'plain', 'tia', jsonb_build_array(pg_temp.it(2, '17:00', '16:00')))), 'BAD_TIME', 'ends before it starts');
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'plain', 'tia', jsonb_build_array(pg_temp.it(2, '16:00', '16:10')))), 'BAD_TIME', 'under 15 minutes');
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'plain', 'tia', jsonb_build_array(pg_temp.it(2, '08:00', '17:00')))), 'BAD_TIME', 'over 8 hours');
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'plain', 'tia', '[{"start":"16:00","end":"17:00","rate":"50"}]'::jsonb)), 'BAD_ITEM', 'no date');
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'plain', 'tia', '[{"date":"not a date","start":"16:00","end":"17:00","rate":"50"}]'::jsonb)), 'BAD_ITEM', 'a date that is not a date');
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'plain', 'tia', jsonb_build_array(pg_temp.it(2, '16:00', '17:30', '1001')))), 'BAD_RATE', 'a price over S$1000 an hour');
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'plain', 'tia', jsonb_build_array(pg_temp.it(2, '16:00', '17:30', 'abc')))), 'BAD_RATE', 'a price that is not a number');
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'plain', 'tia', jsonb_build_array(pg_temp.it(2, '16:00', '17:30', null)))), 'NO_PRICE', 'no price anywhere (no weekly slot, no earlier lesson): type one');
select pg_temp.expect(pg_temp.prev(:'stf', 'plain', 'tia', '[]'::jsonb), 'BAD_ITEMS', 'an empty list');
select pg_temp.expect(pg_temp.prev(:'stf', 'plain', 'tia', (select jsonb_agg(pg_temp.it(1)) from generate_series(1, 63))), 'BAD_ITEMS', 'more than 62 at a time');
select pg_temp.expect(pg_temp.prev(:'stf', 'plain', 'tia', '{"a":1}'::jsonb), 'BAD_ITEMS', 'not a list');
-- the reason
select pg_temp.expect(pg_temp.add(:'stf', 'plain', 'tia', pg_temp.items(1), p_reason => null), 'REASON_REQUIRED', 'a reason is required');
select pg_temp.expect(pg_temp.add(:'stf', 'plain', 'tia', pg_temp.items(1), p_reason => '   '), 'REASON_REQUIRED', 'a blank reason is no reason');
select pg_temp.expect(pg_temp.add(:'stf', 'plain', 'tia', pg_temp.items(1), p_reason => repeat('x', 501)), 'TOO_LONG', 'a reason over 500 characters');
select t.eq(pg_temp.nles('plain'), 0, 'refusals created nothing');
-- price: typed, from the weekly slot, from the last lesson
select pg_temp.add(:'stf', 'plain', 'tia', jsonb_build_array(pg_temp.it(10, '16:00', '17:30', '60'))) as r \gset
select t.ok((:'r'::jsonb ->> 'created')::int = 1, 'added one lesson at S$60/hour');
select t.ok((select rate = 60 and amount = 90 and status = 'scheduled' and one_off and slot_id is null and not paid and split = 1 and level = 'S4' and subject is null
                    and taught_by = t.id('tia') and org_id = t.id('pl') and tutor_id = '00000000-0000-0000-0000-00000000c101'
               from lessons where student_id = t.id('plain')), 'rate 60 x 1.5 h = S$90.00; a manual lesson, no slot, unpaid, for the tutor, filed under the owner''s login');
select t.ok((select attendance is null and attendance_marked_by is null from lessons where student_id = t.id('plain')), 'not marked attended: no mark and nobody stamped');
select t.ok((pg_temp.prev(:'stf', 'plain', 'tia', jsonb_build_array(pg_temp.it(11, '16:00', '17:30', null)))::jsonb #>> '{rows,0,rate}')::numeric = 60, 'no price typed: the student''s last lesson rate (60) is used');
select t.ok((pg_temp.prev(:'stf', 'plain', 'tia', jsonb_build_array(pg_temp.it(11, '16:00', '17:30', '75')))::jsonb #>> '{rows,0,amount}')::numeric = 112.5, 'a typed price wins: 75 x 1.5 h = S$112.50 (staff can adjust the price)');
insert into recurring_slots(tutor_id, org_id, student_id, weekday, start_time, end_time, subject, rate, level, split, taught_by)
  select '00000000-0000-0000-0000-00000000c101', t.id('pl'), t.id('slot'), (extract(isodow from (select today - 6 from td))::int - 1), '16:00', '17:00', 'Science', 55, 'S4', 1, t.id('tia');
select t.ok((pg_temp.prev(:'stf', 'slot', 'tia', jsonb_build_array(pg_temp.it(6, '16:00', '17:00', null)))::jsonb #>> '{rows,0,rate}')::numeric = 55
            and (pg_temp.prev(:'stf', 'slot', 'tia', jsonb_build_array(pg_temp.it(6, '16:00', '17:00', null)))::jsonb #>> '{rows,0,subject}') = 'Science',
            'no price typed and a weekly slot at that day and time: the slot''s rate (55) and subject (Science)');
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'slot', 'tia', jsonb_build_array(pg_temp.it(6, '10:00', '11:00', null)))), 'NO_PRICE', 'a time that is not the slot''s (and no earlier lesson) has no price to take');
-- the weekly pattern as ready-made items
select t.eq(jsonb_array_length(pg_temp.call(:'stf', format('staff_past_lessons_pattern(%L::uuid, %L::uuid, %L::date, %L::date)', t.id('pl'), t.id('slot'), (select today - 20 from td), (select today - 1 from td)))::jsonb),
            (select count(*)::int from generate_series((select today - 20 from td), (select today - 1 from td), interval '1 day') g where extract(isodow from g)::int - 1 = extract(isodow from (select today - 6 from td))::int - 1),
            'the pattern lists every day of the slot''s weekday in the range');
select t.ok((pg_temp.call(:'stf', format('staff_past_lessons_pattern(%L::uuid, %L::uuid, %L::date, %L::date)', t.id('pl'), t.id('slot'), (select today - 20 from td), (select today - 1 from td)))::jsonb #>> '{0,rate}')::numeric = 55,
            'each item carries the slot''s rate, time, subject and tutor');
select t.ok((select bool_and((e->>'date')::date < (select today from td)) from jsonb_array_elements(pg_temp.call(:'stf', format('staff_past_lessons_pattern(%L::uuid, %L::uuid, %L::date, %L::date)', t.id('pl'), t.id('slot'), (select today - 8 from td), (select today + 10 from td)))::jsonb) e),
            'a range that runs into the future is cut off at yesterday');
select pg_temp.expect(pg_temp.call(:'stf', format('staff_past_lessons_pattern(%L::uuid, %L::uuid, %L::date, %L::date)', t.id('pl'), t.id('slot'), (select today - 70 from td), (select today - 1 from td))), 'BAD_RANGE', 'a range of more than 62 days');
select t.eq(jsonb_array_length(pg_temp.call(:'stf', format('staff_past_lessons_pattern(%L::uuid, %L::uuid, %L::date, %L::date)', t.id('pl'), t.id('plain'), (select today - 20 from td), (select today - 1 from td)))::jsonb), 0, 'a student with no weekly slot has an empty pattern (type the dates)');
-- idempotent
select pg_temp.add(:'stf', 'plain', 'tia', pg_temp.items(1, 2)) as r \gset
select t.ok((:'r'::jsonb ->> 'created')::int = 2 and (:'r'::jsonb ->> 'skipped')::int = 0, 'two new lessons');
select pg_temp.add(:'stf', 'plain', 'tia', pg_temp.items(1, 2)) as r \gset
select t.ok((:'r'::jsonb ->> 'created')::int = 0 and (:'r'::jsonb ->> 'skipped')::int = 2, 'the same call again creates nothing: both are already there');
select t.eq((select count(*) from lessons where student_id = t.id('plain')), 3, 'three lessons in all (offsets 10, 1, 2)');
select pg_temp.add(:'stf', 'plain', 'tia', pg_temp.items(3, 3)) as r \gset
select t.ok((:'r'::jsonb ->> 'created')::int = 1 and (:'r'::jsonb ->> 'skipped')::int = 1, 'the same lesson twice in one list is made once');
select t.eq((select count(*) from lessons where student_id = t.id('plain')), 4, 'four lessons');
-- all or nothing
select pg_temp.expect(pg_temp.add(:'stf', 'plain', 'tia', pg_temp.items(4, 0)), 'REFUSED', 'one refused row (today) stops the whole call');
select t.eq((select count(*) from lessons where student_id = t.id('plain')), 4, 'and nothing was made (still four)');
select t.ok((pg_temp.prev(:'stf', 'plain', 'tia', pg_temp.items(4, 0))::jsonb ->> 'refused')::int = 1 and (pg_temp.prev(:'stf', 'plain', 'tia', pg_temp.items(4, 0))::jsonb ->> 'new')::int = 1,
            'the preview counts them: 1 new, 1 refused');
select t.ok((pg_temp.prev(:'stf', 'plain', 'tia', pg_temp.items(4, 5))::jsonb ->> 'total_cents')::int = 18000, 'the preview adds up the money of the new rows: 2 x S$90.00');
select t.ok((select count(*) from audit_log where org_id = t.id('pl') and action = 'staff_add_past_lesson') = 4, 'one audit row per created lesson');
select t.ok((select bool_and(after->>'reason' like 'Started last week%' and after->>'tutor' = t.id('tia')::text and (after->>'attended')::boolean = false and actor = '00000000-0000-0000-0000-00000000c102')
               from audit_log where org_id = t.id('pl') and action = 'staff_add_past_lesson'), 'each carries the reason, the tutor, who did it');
-- end date (inclusive)
select pg_temp.expect(pg_temp.state(pg_temp.prev(:'stf', 'leaver', 'tia', pg_temp.items(3))), 'new', 'the day lessons run until (inclusive) is allowed');
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'leaver', 'tia', pg_temp.items(2))), 'AFTER_END', 'a day after the student left is refused');
select pg_temp.expect(pg_temp.add(:'stf', 'leaver', 'tia', pg_temp.items(3, 2)), 'REFUSED', 'and the add refuses (all or nothing)');
-- the student's own start: a student created today can go back the centre's full window, no further; the form says where
select t.ok((pg_temp.call(:'stf', format('staff_past_lessons_options(%L::uuid, %L::uuid)', t.id('pl'), t.id('newcomer')))::jsonb ->> 'earliest')::date = (select today - 31 from td), 'the form''s earliest day = today minus the window');
-- clash
select pg_temp.add(:'stf', 'clash', 'tia', jsonb_build_array(pg_temp.it(6, '16:00', '17:30'))) as r \gset
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'clash', 'tia', jsonb_build_array(pg_temp.it(6, '16:30', '18:00')))), 'CLASH', 'overlapping the same student and tutor = clash');
select t.ok((pg_temp.prev(:'stf', 'clash', 'tia', jsonb_build_array(pg_temp.it(6, '16:30', '18:00')))::jsonb #>> '{rows,0,message}') like '%16:00 to 17:30 with Tutor Tia%', 'the clash message says which lesson');
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'clash', 'tom', jsonb_build_array(pg_temp.it(6, '16:30', '18:00')))), 'CLASH', 'another tutor at that time is a clash too: one student cannot be in two lessons at once');
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'clash', 'tom', jsonb_build_array(pg_temp.it(6, '16:00', '17:30')))), 'CLASH', 'the same start with ANOTHER tutor is a clash, not "already there"');
select pg_temp.expect(pg_temp.state(pg_temp.prev(:'stf', 'clash', 'tia', jsonb_build_array(pg_temp.it(6, '16:00', '17:30')))), 'there', 'the same student, tutor, day and start = already there (skipped, not an error)');
select pg_temp.expect(pg_temp.state(pg_temp.prev(:'stf', 'clash', 'tia', jsonb_build_array(pg_temp.it(6, '17:30', '19:00')))), 'new', 'a lesson that starts when the other ends is fine');
select pg_temp.expect(pg_temp.state(pg_temp.prev(:'stf', 'clash', 'tia', jsonb_build_array(pg_temp.it(6, '14:00', '16:00')))), 'new', 'and one that ends when the other starts');
select pg_temp.expect(pg_temp.add(:'stf', 'clash', 'tia', jsonb_build_array(pg_temp.it(6, '16:30', '18:00'))), 'REFUSED', 'the add refuses a clash');
update lessons set status = 'cancelled' where student_id = t.id('clash');
select pg_temp.expect(pg_temp.state(pg_temp.prev(:'stf', 'clash', 'tia', jsonb_build_array(pg_temp.it(6, '16:30', '18:00')))), 'new', 'a lesson cancelled by staff (no mark) is not a clash: that hour is free again');
-- holidays
insert into holidays(org_id, name, starts_on, ends_on) values (t.id('pl'), 'Test Day Holiday', (select today - 2 from td), (select today - 2 from td));
insert into branches(id, org_id, name) values ('00000000-0000-0000-0000-00000000cb01', t.id('pl'), 'North branch');
insert into holidays(org_id, branch_id, name, starts_on, ends_on) values (t.id('pl'), '00000000-0000-0000-0000-00000000cb01', 'Branch Day', (select today - 3 from td), (select today - 3 from td));
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'holiday', 'tia', pg_temp.items(2))), 'HOLIDAY', 'a whole-centre holiday is refused until staff confirm');
select t.ok((pg_temp.prev(:'stf', 'holiday', 'tia', pg_temp.items(2))::jsonb #>> '{rows,0,message}') like '%Test Day Holiday%', 'and the message names the holiday');
select pg_temp.expect(pg_temp.add(:'stf', 'holiday', 'tia', pg_temp.items(2)), 'REFUSED', 'the add refuses it too');
select pg_temp.expect(pg_temp.state(pg_temp.prev(:'stf', 'holiday', 'tia', pg_temp.items(2), p_hol => true)), 'new', 'with the confirmation it is allowed');
select pg_temp.expect(pg_temp.state(pg_temp.prev(:'stf', 'holiday', 'tia', pg_temp.items(3))), 'new', 'a BRANCH holiday does not stop anything (students have no branch)');
select pg_temp.add(:'stf', 'holiday', 'tia', pg_temp.items(2), p_hol => true) as r \gset
select t.ok((:'r'::jsonb ->> 'created')::int = 1, 'added on the holiday after confirming');
select t.ok((select (after->>'holiday_confirmed')::boolean from audit_log where org_id = t.id('pl') and action = 'staff_add_past_lesson' and after->>'student' = t.id('holiday')::text), 'and the audit row records that the holiday was confirmed');
delete from holidays where org_id = t.id('pl') and true;
-- the billing-start cut-off (import stage A): ignored while the function is absent, respected the moment it exists
select pg_temp.expect(pg_temp.state(pg_temp.prev(:'stf', 'billing', 'tia', pg_temp.items(5))), 'new', 'no billing-start function on this database: no cut-off (stage A not applied)');
select format('create function public.org_billing_start(p_org uuid) returns date language sql stable as $f$ select %L::date $f$', (select today - 4 from td)) as ddl \gset
:ddl;
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'billing', 'tia', pg_temp.items(5))), 'BEFORE_BILLING_START', 'billing starts 4 days ago: a lesson 5 days ago is refused');
select t.ok((pg_temp.prev(:'stf', 'billing', 'tia', pg_temp.items(5))::jsonb #>> '{rows,0,message}') like 'Billing for this centre starts from%', 'in plain words');
select pg_temp.expect(pg_temp.state(pg_temp.prev(:'stf', 'billing', 'tia', pg_temp.items(4))), 'new', 'the start day itself is fine');
select pg_temp.expect(pg_temp.add(:'o1', 'billing', 'tia', pg_temp.items(5, 4)), 'REFUSED', 'not even the owner may add before it (all or nothing)');
select t.ok((pg_temp.call(:'stf', format('staff_past_lessons_options(%L::uuid, %L::uuid)', t.id('pl'), t.id('billing')))::jsonb ->> 'billing_start')::date = (select today - 4 from td), 'the form is told where billing starts');
drop function public.org_billing_start(uuid);
select pg_temp.expect(pg_temp.state(pg_temp.prev(:'stf', 'billing', 'tia', pg_temp.items(5))), 'new', 'function gone again: no cut-off');
-- a month whose platform fee is already recorded
select pg_temp.lset(t.id('pl'), :'o1', 'backfill_allowed_days', '120'::jsonb);
select (select today - ((m_now - interval '1 month')::date - 1) from td) as closed_off, (select today - (m_now - 1) from td) as open_off \gset
insert into platform_fee_snapshots(org_id, month, active_students, billable_students, base_cents, per_student_cents, fee_cents)
  values (t.id('pl'), (select (m_now - interval '1 month')::date from td), 3, 3, 10000, 50, 10150);
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'stf', 'closed', 'tia', pg_temp.items(:closed_off))), 'FEE_MONTH_CLOSED', 'a month whose fee is already recorded: refused for staff');
select pg_temp.expect(pg_temp.code(pg_temp.prev(:'o1', 'closed', 'tia', pg_temp.items(:closed_off))), 'FEE_MONTH_CLOSED', 'and for the owner too, until the owner says so on purpose');
select t.ok((pg_temp.prev(:'stf', 'closed', 'tia', pg_temp.items(:closed_off))::jsonb #>> '{rows,0,message}') like '%Only the centre owner can add lessons to it%', 'the message says who can');
select pg_temp.expect(pg_temp.add(:'stf', 'closed', 'tia', pg_temp.items(:closed_off), p_allow => true), 'NOT_ALLOWED', 'staff cannot pass the owner-only override');
select pg_temp.expect(pg_temp.prev(:'stf', 'closed', 'tia', pg_temp.items(:closed_off), p_allow => true), 'NOT_ALLOWED', 'not even in a preview');
select pg_temp.expect(pg_temp.state(pg_temp.prev(:'stf', 'closed', 'tia', pg_temp.items(:open_off))), 'new', 'the month AFTER the recorded one is still open (its fee is counted next month)');
select pg_temp.expect(pg_temp.add(:'o1', 'closed', 'tia', pg_temp.items(:closed_off), p_reason => null, p_allow => true), 'REASON_REQUIRED', 'the owner override still needs a reason');
select pg_temp.add(:'o1', 'closed', 'tia', pg_temp.items(:closed_off), p_allow => true) as r \gset
select t.ok((:'r'::jsonb ->> 'created')::int = 1 and (:'r'::jsonb ->> 'fee_month_closed')::boolean, 'the owner can, and the answer says the fee month was already closed');
select t.ok((select (after->>'fee_month_closed_override')::boolean from audit_log where org_id = t.id('pl') and action = 'staff_add_past_lesson' and after->>'student' = t.id('closed')::text), 'the audit row records the override');
select t.ok((select count(*) = 1 and bool_and(fee_cents = 10150 and active_students = 3) from platform_fee_snapshots where org_id = t.id('pl')), 'the recorded fee itself is never touched');
select pg_temp.lset(t.id('pl'), :'o1', 'backfill_allowed_days', null);

-- ===================================================================== 4. attended in the same step, and the centre's remark rule
select pg_temp.lset(t.id('pl'), :'o1', 'remarks', '{"required": true, "deadline_hours": 24}'::jsonb);
select t.ok((pg_temp.call(:'stf', format('staff_past_lessons_options(%L::uuid, %L::uuid)', t.id('pl'), t.id('remark')))::jsonb ->> 'remarks_required')::boolean, 'the form is told remarks are required');
select pg_temp.expect(pg_temp.add(:'stf', 'remark', 'tia', pg_temp.items(4), p_att => true), 'REMARKS_REQUIRED', 'remarks required by the centre: attended without remarks is refused');
select t.eq(pg_temp.nles('remark'), 0, 'and nothing was made');
select pg_temp.add(:'stf', 'remark', 'tia', pg_temp.items(4), p_att => true, p_remarks => 'Fractions revision, good progress') as r \gset
select t.ok((:'r'::jsonb ->> 'attended')::boolean and (select status = 'done' and attendance = 'attended' and remarks = 'Fractions revision, good progress'
              and attendance_marked_by = '00000000-0000-0000-0000-00000000c102' and attendance_marked_at is not null and compensation is null from lessons where student_id = t.id('remark')),
            'with remarks: status done, attendance attended, remarks kept, stamped with the person who clicked');
select pg_temp.expect(pg_temp.state(pg_temp.prev(:'stf', 'remark', 'tia', pg_temp.items(5))), 'new', 'NOT marking attended does not need remarks');
select pg_temp.lset(t.id('pl'), :'o1', 'remarks', null);
select pg_temp.add(:'stf', 'remark', 'tia', pg_temp.items(5), p_att => true) as r \gset
select t.ok((select attendance = 'attended' and remarks is null from lessons where student_id = t.id('remark') and lesson_date = (select today - 5 from td)), 'remarks not required: attended with none is fine');
-- not marked: it can be marked later like any other lesson of the past
select pg_temp.call(:'stf', format('staff_mark_attendance(%L::uuid, ''attended'', null)', (select id from lessons where student_id = t.id('plain') and lesson_date = (select today - 1 from td)))) as r \gset
select t.ok((:'r'::jsonb ->> 'status') = 'done', 'a past lesson added unmarked can be marked attended afterwards (the normal mark)');

-- ===================================================================== 5. THE OWNER'S FLOW: a student created today, 5 lessons last week, attended -> invoice preview -> deposit
select pg_temp.call(:'stf', format('staff_past_lessons_options(%L::uuid, %L::uuid)', t.id('pl'), t.id('newcomer'))) as o \gset
select t.ok((:'o'::jsonb ->> 'enabled')::boolean and jsonb_array_length(:'o'::jsonb -> 'slots') = 0 and (:'o'::jsonb ->> 'last_rate') is null and (:'o'::jsonb ->> 'default_tutor') is null,
            'the form for a brand-new student: switched on, no weekly slot, no earlier price, no default tutor');
select jsonb_agg(jsonb_build_object('date', d0 - g, 'start', '16:00', 'end', '17:30', 'rate', '60')) as its from td, generate_series(0, 4) g \gset
select pg_temp.prev(:'stf', 'newcomer', 'tia', :'its'::jsonb) as pv \gset
select t.ok((:'pv'::jsonb ->> 'new')::int = 5 and (:'pv'::jsonb ->> 'refused')::int = 0 and (:'pv'::jsonb ->> 'total_cents')::int = 45000, 'the preview: 5 new lessons, S$450.00, nothing refused');
select t.eq(pg_temp.nles('newcomer'), 0, 'the preview wrote nothing');
select pg_temp.add(:'stf', 'newcomer', 'tia', :'its'::jsonb, p_reason => 'Nia started with us last week', p_att => true) as r \gset
select t.ok((:'r'::jsonb ->> 'created')::int = 5 and (:'r'::jsonb ->> 'attended')::boolean and jsonb_array_length(:'r'::jsonb -> 'lesson_ids') = 5 and (:'r'::jsonb -> 'invoiced_months') = '[]'::jsonb, 'five lessons created and marked attended; no month of hers is invoiced yet');
select t.ok((select count(*) = 5 and bool_and(status = 'done' and attendance = 'attended' and amount = 90 and one_off and taught_by = t.id('tia')) from lessons where student_id = t.id('newcomer')), 'all five are done / attended at S$90.00 each');
select t.ok((select count(*) = 5 and bool_and(after->>'reason' = 'Nia started with us last week' and (after->>'attended')::boolean) from audit_log where org_id = t.id('pl') and action = 'staff_add_past_lesson' and after->>'student' = t.id('newcomer')::text), 'five audit rows with the reason');
select (select m from (select date_trunc('month', d0)::date m from td) x) as inv_month \gset
select t.as(:'o1'); select centre_invoice_run_preview(t.id('pl'), :'inv_month'::date) as ip \gset
select t.ok((select (e->>'lessons')::int = 5 and (e->>'subtotal_cents')::int = 45000 from jsonb_array_elements(:'ip'::jsonb -> 'ready') e where e->>'name' = 'Newcomer Nia''s family'),
            'the invoice preview has Nia with 5 lessons, S$450.00 before GST');
select t.ok((select count(*) = 5 and bool_and((l->>'line_cents')::int = 9000 and l->>'kind' = 'lesson' and l->>'lesson_id' is not null) from jsonb_array_elements(:'ip'::jsonb -> 'ready') e, jsonb_array_elements(e->'lines') l where e->>'name' = 'Newcomer Nia''s family'),
            'five lines of S$90.00, each tied to one of the lessons just made');
select t.ok((select count(*) = 5 from jsonb_array_elements(:'ip'::jsonb -> 'ready') e, jsonb_array_elements(e->'lines') l, jsonb_array_elements_text(:'r'::jsonb -> 'lesson_ids') i
             where e->>'name' = 'Newcomer Nia''s family' and l->>'lesson_id' = i), 'and they are exactly the lesson ids the add returned');
select t.ok((select (e->>'amount_cents')::int = 12000 from jsonb_array_elements(:'ip'::jsonb -> 'deposits') e where e->>'name' = 'Newcomer Nia'), 'a deposit (S$120.00, the centre''s fixed deposit) is offered for her: a never-invoiced student');
select t.ok(coalesce((select (e->>'lessons')::int from jsonb_array_elements(:'ip'::jsonb -> 'ready') e where e->>'name' = 'Plain Pat''s family'), 0)
             = (select count(*) from lessons where student_id = t.id('plain') and attendance = 'attended' and date_trunc('month', lesson_date)::date = :'inv_month'::date),
            'only ATTENDED lessons are billed: Pat''s lessons added without a mark wait (just the one marked later is on the invoice)');
select centre_invoice_run_create_drafts(t.id('pl'), :'inv_month'::date) as cr \gset
select t.ok((select count(*) = 1 from centre_invoices where org_id = t.id('pl') and kind = 'deposit' and student_id = t.id('newcomer')), 'creating the drafts raises the deposit invoice for Nia');
select t.ok((select count(*) = 5 from centre_invoice_lines l join centre_invoices i on i.id = l.invoice_id where l.org_id = t.id('pl') and i.kind = 'lesson'
             and l.lesson_id in (select id from lessons where student_id = t.id('newcomer'))), 'and a lesson invoice draft holds her five lessons');
-- invoiced already? a lesson added afterwards goes on the NEXT invoice and the answer says the month already has one
select centre_invoice_approve_all(t.id('pl'), :'inv_month'::date) as ap \gset
select pg_temp.add(:'stf', 'newcomer', 'tia', jsonb_build_array(jsonb_build_object('date', (select d0 - 5 from td), 'start', '09:00', 'end', '10:00', 'rate', '60')), p_att => true) as r2 \gset
select t.ok((:'r2'::jsonb ->> 'created')::int = 1, 'one more lesson for Nia, after her invoice was issued');
select t.ok(case when (select date_trunc('month', d0 - 5) = date_trunc('month', d0) from td) then (:'r2'::jsonb -> 'invoiced_months') <> '[]'::jsonb else true end, 'the answer lists the month that already has an issued invoice, so the screen can say it goes on the next one');
select t.as(:'o1'); select centre_invoice_run_preview(t.id('pl'), :'inv_month'::date) as ip2 \gset
select t.ok(case when (select date_trunc('month', d0 - 5) = date_trunc('month', d0) from td)
                 then (select count(*) = 1 from jsonb_array_elements(:'ip2'::jsonb -> 'ready') e, jsonb_array_elements(e->'lines') l where e->>'name' = 'Newcomer Nia''s family' and l->>'lesson_id' = (:'r2'::jsonb -> 'lesson_ids' ->> 0))
                 else true end, 'the late lesson shows up as a line of the next run, like any other attended lesson');
-- tutors see what they teach (and, as always, no money)
select t.as(:'tut'); set role authenticated;
select t.ok((select count(*) >= 5 from tutor_my_lessons((select today - 40 from td), (select today from td)) where student_name = 'Newcomer Nia'), 'the tutor sees the five lessons in My lessons');
reset role; select set_config('request.jwt.claims', '', false);

-- ===================================================================== 6. nothing else was touched
select t.eq((select count(*) from lessons where org_id = t.id('solo_org')), :solo_lessons, 'a solo organisation''s lessons are exactly as before');
select t.eq((select count(*) from lessons where org_id = t.id('pl2')), 0, 'the other centre has no lessons');
select t.ok((select count(*) from audit_log where org_id = t.id('pl') and action = 'staff_add_past_lesson') = (select count(*) from lessons where org_id = t.id('pl') and one_off and slot_id is null), 'every lesson made here has its own audit row (no more, no fewer)');
\echo PASS past_lessons_test.sql
