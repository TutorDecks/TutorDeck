-- T3 step 1 tests: staff_home(org) — counts only, per-permission sections, no leaks. Runs after org_separation_test.sql in the same
-- throwaway database (reuses the t.* helpers). Builds its own centre and made-up people, so it doesn't depend on earlier fixtures.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000e001', 'sh.owner@centre.test'), ('00000000-0000-0000-0000-00000000e002', 'sh.full@centre.test'),
  ('00000000-0000-0000-0000-00000000e003', 'sh.front@centre.test'), ('00000000-0000-0000-0000-00000000e004', 'sh.timetable@centre.test'),
  ('00000000-0000-0000-0000-00000000e005', 'sh.billing@centre.test'), ('00000000-0000-0000-0000-00000000e006', 'sh.tutor@centre.test'),
  ('00000000-0000-0000-0000-00000000e007', 'sh.outsider@centre.test'), ('00000000-0000-0000-0000-00000000e008', 'sh.nobody@centre.test'),
  ('00000000-0000-0000-0000-00000000e009', 'sh.owner2@centre.test'), ('00000000-0000-0000-0000-00000000e00a', 'sh.off@centre.test');
set role authenticated; select t.as('00000000-0000-0000-0000-00000000e001');
select t.put('sh', org_create_centre('Staff Home Centre', t.centre_settings()));
select t.as('00000000-0000-0000-0000-00000000e009');
select t.put('sh2', org_create_centre('Other Centre', t.centre_settings()));
reset role; select set_config('request.jwt.claims', '', false);      -- (setup below runs as the database owner, not as the last person)
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('sh'), '00000000-0000-0000-0000-00000000e002', 'Full staff',   'staff', array['manage_students','manage_timetable','issue_invoices'], 'active'),
  (t.id('sh'), '00000000-0000-0000-0000-00000000e003', 'Front desk',   'staff', array['manage_students'], 'active'),
  (t.id('sh'), '00000000-0000-0000-0000-00000000e004', 'Timetable',    'staff', array['manage_timetable'], 'active'),
  (t.id('sh'), '00000000-0000-0000-0000-00000000e005', 'Billing',      'staff', array['issue_invoices'], 'active'),
  (t.id('sh'), '00000000-0000-0000-0000-00000000e006', 'A tutor',      'tutor', '{}', 'active'),
  (t.id('sh'), '00000000-0000-0000-0000-00000000e00a', 'Switched off', 'staff', array['manage_students','manage_timetable','issue_invoices'], 'disabled');
select t.put('mt', (select id from memberships where org_id = t.id('sh') and user_id = '00000000-0000-0000-0000-00000000e006'));

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today;
grant select on td to authenticated, anon;
-- 5 students: 4 active (one with a future end date), 1 ended yesterday
insert into students(id, tutor_id, org_id, name, level, end_date) values
  ('e1000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000e001', t.id('sh'), 'Sh A', 'P1', null),
  ('e1000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000e001', t.id('sh'), 'Sh B', 'P2', null),
  ('e1000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-00000000e001', t.id('sh'), 'Sh C', 'P3', (select today + 30 from td)),
  ('e1000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-00000000e001', t.id('sh'), 'Sh D', 'P4', (select today from td)),
  ('e1000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-00000000e001', t.id('sh'), 'Sh E', 'P5', (select today - 1 from td));
-- a student of ANOTHER centre must never be counted
insert into students(tutor_id, org_id, name) values ('00000000-0000-0000-0000-00000000e009', t.id('sh2'), 'Other centre kid');
insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status)
  select '00000000-0000-0000-0000-00000000e009', t.id('sh2'), id, (select today from td), '15:00', '16:00', 50, 50, 'scheduled' from students where name = 'Other centre kid';

create function pg_temp.mk(p_s text, p_off int, p_by uuid, p_status text default 'scheduled', p_trial boolean default false) returns uuid language sql as $$
  insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, taught_by, trial, subject)
  values ('00000000-0000-0000-0000-00000000e001', t.id('sh'), p_s::uuid, (select today from td) + p_off, '16:00', '17:00', 99, 99, p_status, p_by, p_trial, 'Math') returning id $$;
-- TODAY (3 counted: two open, one will be marked; one more cancelled by staff = closed)
select t.put('T1', pg_temp.mk('e1000000-0000-0000-0000-000000000001', 0, t.id('mt')));
select t.put('T2', pg_temp.mk('e1000000-0000-0000-0000-000000000002', 0, t.id('mt')));
select t.put('T3', pg_temp.mk('e1000000-0000-0000-0000-000000000003', 0, null));                       -- today, no tutor
select t.put('TX', pg_temp.mk('e1000000-0000-0000-0000-000000000001', 0, t.id('mt'), 'cancelled'));   -- cancelled by staff, unmarked
-- PAST: two unmarked, one cancelled (closed), one marked absent (charge pending), one marked late-cancelled with its charge typed, one older than 60 days
select t.put('P1', pg_temp.mk('e1000000-0000-0000-0000-000000000001', -1, t.id('mt')));
select t.put('P2', pg_temp.mk('e1000000-0000-0000-0000-000000000002', -3, t.id('mt')));
select t.put('PX', pg_temp.mk('e1000000-0000-0000-0000-000000000002', -4, t.id('mt'), 'cancelled'));
select t.put('PA', pg_temp.mk('e1000000-0000-0000-0000-000000000003', -2, t.id('mt')));
select t.put('PL', pg_temp.mk('e1000000-0000-0000-0000-000000000003', -5, t.id('mt')));
select t.put('PO', pg_temp.mk('e1000000-0000-0000-0000-000000000003', -61, t.id('mt')));
-- FUTURE: next 14 days: two without a tutor (one cancelled doesn't count), one with; day 14 is outside the window
select t.put('F1', pg_temp.mk('e1000000-0000-0000-0000-000000000001', 3, null));
select t.put('F2', pg_temp.mk('e1000000-0000-0000-0000-000000000002', 13, null));
select t.put('F3', pg_temp.mk('e1000000-0000-0000-0000-000000000002', 14, null));
select t.put('F4', pg_temp.mk('e1000000-0000-0000-0000-000000000002', 5, null, 'cancelled'));
select t.put('F5', pg_temp.mk('e1000000-0000-0000-0000-000000000003', 4, t.id('mt')));
-- a trial this month (today's lesson, flagged)
update lessons set trial = true where id = t.id('T2');
-- marks go through the real mechanism: an owner marks (admin marks are allowed for any lesson)
select t.as('00000000-0000-0000-0000-00000000e001'); set role authenticated;
update lessons set attendance = 'attended' where id = t.id('T1');
update lessons set attendance = 'absent' where id = t.id('PA');
update lessons set attendance = 'late_cancelled', compensation = 0 where id = t.id('PL');
reset role;

-- ===================================================================== the owner sees every section, with the right numbers
select t.as('00000000-0000-0000-0000-00000000e001'); set role authenticated;
select staff_home(t.id('sh')) as h \gset
select t.ok((:'h'::jsonb->'can') = '{"students":true,"timetable":true,"charges":true}'::jsonb, 'owner can see every section');
select t.eq((:'h'::jsonb->>'students_active')::int, 4, 'active students: ended yesterday is out; ends today and ends in the future are in; other centre not counted');
select t.eq((:'h'::jsonb->>'today_lessons')::int, 3, 'today: 3 lessons (the one cancelled by staff is closed and not counted)');
select t.eq((:'h'::jsonb->>'today_marked')::int, 1, 'today: 1 marked');
select t.eq((:'h'::jsonb->>'today_to_mark')::int, 2, 'today: 2 still to mark');
select t.eq((:'h'::jsonb->>'unmarked_past')::int, 2, 'past, unmarked: 2 (cancelled-by-staff, marked and older-than-60-days ones are out)');
select t.eq((:'h'::jsonb->>'no_tutor_14d')::int, 3, 'no tutor in the next 14 days: today + day 3 + day 13 (day 14 and the cancelled one are out)');
select t.eq((:'h'::jsonb->>'trials_this_month')::int, 1, 'trials this month: 1');
select t.eq((:'h'::jsonb->>'pending_charges')::int, 1, 'pending charges: only the absent lesson with no charge typed (late-cancelled with 0 typed is done)');
select t.ok(:'h'::jsonb->>'org_name' = 'Staff Home Centre' and (:'h'::jsonb->>'today')::date = (select today from td), 'names the centre and its own today');
reset role;

-- ===================================================================== full staff = same numbers
select t.as('00000000-0000-0000-0000-00000000e002'); set role authenticated;
select staff_home(t.id('sh')) as h2 \gset
select t.ok(:'h2'::jsonb - 'can' = :'h'::jsonb - 'can' and (:'h2'::jsonb->'can') = '{"students":true,"timetable":true,"charges":true}'::jsonb, 'staff with all three permissions sees what the owner sees');
reset role;

-- ===================================================================== front desk (manage_students only): students, nothing else
select t.as('00000000-0000-0000-0000-00000000e003'); set role authenticated;
select staff_home(t.id('sh')) as h3 \gset
select t.ok((:'h3'::jsonb->'can') = '{"students":true,"timetable":false,"charges":false}'::jsonb, 'front desk: students only');
select t.eq((:'h3'::jsonb->>'students_active')::int, 4, 'front desk sees the student count');
select t.ok((:'h3'::jsonb->'today_lessons') = 'null'::jsonb and (:'h3'::jsonb->'today_marked') = 'null'::jsonb and (:'h3'::jsonb->'unmarked_past') = 'null'::jsonb
        and (:'h3'::jsonb->'no_tutor_14d') = 'null'::jsonb and (:'h3'::jsonb->'trials_this_month') = 'null'::jsonb and (:'h3'::jsonb->'pending_charges') = 'null'::jsonb,
        'front desk gets null (not 0) for every section they may not see');
reset role;

-- ===================================================================== timetable-only staff
select t.as('00000000-0000-0000-0000-00000000e004'); set role authenticated;
select staff_home(t.id('sh')) as h4 \gset
select t.ok((:'h4'::jsonb->'can') = '{"students":false,"timetable":true,"charges":false}'::jsonb, 'timetable-only: timetable section only');
select t.ok((:'h4'::jsonb->'students_active') = 'null'::jsonb and (:'h4'::jsonb->'pending_charges') = 'null'::jsonb and (:'h4'::jsonb->>'today_lessons')::int = 3, 'timetable-only: lessons yes, students and charges null');
reset role;

-- ===================================================================== billing-only staff
select t.as('00000000-0000-0000-0000-00000000e005'); set role authenticated;
select staff_home(t.id('sh')) as h5 \gset
select t.ok((:'h5'::jsonb->'can') = '{"students":false,"timetable":false,"charges":true}'::jsonb and (:'h5'::jsonb->>'pending_charges')::int = 1
        and (:'h5'::jsonb->'today_lessons') = 'null'::jsonb and (:'h5'::jsonb->'students_active') = 'null'::jsonb, 'billing-only: the charges count only');
reset role;

-- ===================================================================== everyone else gets NOT_FOUND (all the same message)
create function pg_temp.expect_nf(p_user text, p_org uuid, p_msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  begin perform staff_home(p_org); exception when others then m := sqlerrm; end;
  if m <> 'NOT_FOUND' then raise exception 'FAIL: % (got %)', p_msg, m; end if;
  raise notice 'PASS refused: %', p_msg;
end $$;
-- (looked up as the database owner: signed-in users can't call org_personal)
select org_personal('00000000-0000-0000-0000-00000000e001') as solo_org \gset
set role authenticated;
select pg_temp.expect_nf('00000000-0000-0000-0000-00000000e006', t.id('sh'), 'a tutor of the centre');
select pg_temp.expect_nf('00000000-0000-0000-0000-00000000e00a', t.id('sh'), 'staff whose membership is switched off');
select pg_temp.expect_nf('00000000-0000-0000-0000-00000000e007', t.id('sh'), 'someone with no membership');
select pg_temp.expect_nf('00000000-0000-0000-0000-00000000e009', t.id('sh'), 'the owner of a DIFFERENT centre');
select pg_temp.expect_nf('00000000-0000-0000-0000-00000000e001', t.id('sh2'), 'the owner asking about someone else''s centre');
select pg_temp.expect_nf('00000000-0000-0000-0000-00000000e001', (:'solo_org')::uuid, 'a solo organisation (even their own)');
select pg_temp.expect_nf('00000000-0000-0000-0000-00000000e001', gen_random_uuid(), 'an id that doesn''t exist (same answer as "not yours")');
select pg_temp.expect_nf('00000000-0000-0000-0000-0000000000a1', t.id('sh'), 'a solo tutor with no link to this centre');
reset role;
set role anon;
select t.fails($q$ select staff_home(t.id('sh')) $q$, 'an anonymous call');
reset role;
select t.ok(not has_function_privilege('anon', 'public.staff_home(uuid)', 'execute') and not has_function_privilege('public', 'public.staff_home(uuid)', 'execute')
        and has_function_privilege('authenticated', 'public.staff_home(uuid)', 'execute'), 'only signed-in users may call staff_home');

-- ===================================================================== counts only: no money, no names, no contacts in the answer
select t.ok(not (:'h'::jsonb::text ~* '(rate|amount|paid|compensation|cents|contact|phone|email)'), 'the answer carries no money, contact or name field');
select t.ok((select array_agg(k order by k) from jsonb_object_keys(:'h'::jsonb) k) =
  array['can','no_tutor_14d','org_id','org_name','pending_charges','status','students_active','today','today_lessons','today_marked','today_to_mark','trials_this_month','unmarked_past'],
  'the answer has exactly the documented fields (adding one is a deliberate decision)');
