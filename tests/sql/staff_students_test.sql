-- T3 step 2 tests: staff_students / staff_student / staff_save_student / staff_set_student_end.
-- Runs after staff_home_test.sql in the same throwaway database (reuses the t.* helpers). Builds its own centres and made-up people.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000f001', 'ss.owner@centre.test'),     ('00000000-0000-0000-0000-00000000f002', 'ss.full@centre.test'),
  ('00000000-0000-0000-0000-00000000f003', 'ss.front@centre.test'),     ('00000000-0000-0000-0000-00000000f004', 'ss.timetable@centre.test'),
  ('00000000-0000-0000-0000-00000000f005', 'ss.billing@centre.test'),   ('00000000-0000-0000-0000-00000000f006', 'ss.tutor@centre.test'),
  ('00000000-0000-0000-0000-00000000f007', 'ss.outsider@centre.test'),  ('00000000-0000-0000-0000-00000000f009', 'ss.owner2@centre.test'),
  ('00000000-0000-0000-0000-00000000f00a', 'ss.off@centre.test');
set role authenticated; select t.as('00000000-0000-0000-0000-00000000f001');
select t.put('ss', org_create_centre('Students Centre', t.centre_settings()));
select t.as('00000000-0000-0000-0000-00000000f009');
select t.put('ss2', org_create_centre('Other Students Centre', t.centre_settings()));
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('ss'), '00000000-0000-0000-0000-00000000f002', 'Full staff',  'staff', array['manage_students','manage_timetable','issue_invoices'], 'active'),
  (t.id('ss'), '00000000-0000-0000-0000-00000000f003', 'Front desk',  'staff', array['manage_students'], 'active'),
  (t.id('ss'), '00000000-0000-0000-0000-00000000f004', 'Timetable',   'staff', array['manage_timetable'], 'active'),
  (t.id('ss'), '00000000-0000-0000-0000-00000000f005', 'Billing',     'staff', array['issue_invoices'], 'active'),
  (t.id('ss'), '00000000-0000-0000-0000-00000000f006', 'A tutor',     'tutor', '{}', 'active'),
  (t.id('ss'), '00000000-0000-0000-0000-00000000f00a', 'Switched off','staff', array['manage_students','manage_timetable','issue_invoices'], 'disabled');
select t.put('ss_tutor_m', (select id from memberships where org_id = t.id('ss') and user_id = '00000000-0000-0000-0000-00000000f006'));
create temp table td as select (now() at time zone 'Asia/Singapore')::date as today;
grant select on td to authenticated, anon;

-- the first call by a person must say what went wrong in plain words
create function pg_temp.refused(p_user text, p_sql text, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  begin execute p_sql; exception when others then m := sqlerrm; end;
  if m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS refused: % (%)', p_msg, m;
end $$;

-- ===================================================================== a remote 1-to-1 centre: no branch, no room, no class
select t.eq((select count(*) from branches where org_id = t.id('ss')), 0, 'the test centre has no branch');
select t.eq((select count(*) from rooms where org_id = t.id('ss')), 0, 'and no room');

-- ===================================================================== front desk (manage_students only) adds "Test Child" with a parent
select t.as('00000000-0000-0000-0000-00000000f003'); set role authenticated;
select staff_save_student(t.id('ss'), null, '  Test Child ', 'Sec 2', 'Prefers worked examples', null, null,
  '[{"name":"Mrs Test","relation":"Mother","phone":"+65 9123 4567","email":"Mrs.Test@Example.com"}]'::jsonb) as r1 \gset
reset role;
select t.ok((:'r1'::jsonb->>'created')::boolean and (:'r1'::jsonb->>'student_id') is not null and (:'r1'::jsonb->>'household_id') is not null, 'front desk adds a student with a parent: student + household created');
select t.put('kid', (:'r1'::jsonb->>'student_id')::uuid); select t.put('kid_h', (:'r1'::jsonb->>'household_id')::uuid);
select t.ok((select s.org_id = t.id('ss') and s.name = 'Test Child' and s.level = 'Sec 2' and s.notes = 'Prefers worked examples' and s.household_id = t.id('kid_h')
               from students s where s.id = t.id('kid')), 'the student belongs to the CENTRE, name trimmed, household set');
select t.ok((select s.tutor_id = '00000000-0000-0000-0000-00000000f001' from students s where s.id = t.id('kid')), 'filed under the centre owner''s login, not the staff member''s (so removing a staff login never removes students)');
select t.ok((select h.name = 'Test Child''s family' and h.org_id = t.id('ss') and h.phone_key = '91234567' from households h where h.id = t.id('kid_h')), 'the household is named after the student and keeps the phone key');
select t.ok((select count(*) = 1 and bool_and(g.org_id = t.id('ss') and g.name = 'Mrs Test' and g.relation = 'Mother' and g.phone = '+65 9123 4567' and g.email = 'mrs.test@example.com')
               from guardians g where g.household_id = t.id('kid_h')), 'the guardian has name, relation, phone and a lower-cased email');
select t.ok((select s.contact = '+65 9123 4567' and s.recipient_name = 'Mrs Test' from students s where s.id = t.id('kid')), 'the older single-parent fields follow the first guardian');
select t.ok(not exists (select 1 from students s join organisations o on o.id = s.org_id where o.kind = 'solo' and s.name = 'Test Child'), 'no copy of the student exists in any solo organisation');
select t.ok(exists (select 1 from audit_log where org_id = t.id('ss') and action = 'staff_student_add' and row_id = t.id('kid')::text and actor = '00000000-0000-0000-0000-00000000f003'), 'a named audit entry says who added the student');
select t.ok(exists (select 1 from audit_log where org_id = t.id('ss') and table_name = 'guardians' and action = 'insert') and exists (select 1 from audit_log where org_id = t.id('ss') and table_name = 'households' and action = 'insert'),
            'and the row-level audit entries for the household and the guardian exist');

-- full staff adds another family, with two guardians and a household name
select t.as('00000000-0000-0000-0000-00000000f002'); set role authenticated;
select staff_save_student(t.id('ss'), null, 'Mei Tan', 'P6', null, null, 'The Tan family',
  '[{"name":"Mr Tan","relation":"Father","phone":"81112222"},{"name":"Mrs Tan","email":"tan@example.com"}]'::jsonb) as r2 \gset
reset role;
select t.put('mei', (:'r2'::jsonb->>'student_id')::uuid); select t.put('mei_h', (:'r2'::jsonb->>'household_id')::uuid);
select t.ok((select h.name = 'The Tan family' and (select count(*) from guardians where household_id = h.id) = 2 from households h where h.id = t.id('mei_h')), 'staff with every permission adds a family with two guardians and a chosen family name');
select t.ok((select s.contact = '81112222' and s.recipient_name = 'Mr Tan' from students s where s.id = t.id('mei')), 'the FIRST guardian is the main contact');

-- the owner sees both
select t.as('00000000-0000-0000-0000-00000000f001'); set role authenticated;
select staff_students(t.id('ss')) as l1 \gset
select t.eq((:'l1'::jsonb->>'total')::int, 2, 'owner sees both students in the list');
select t.ok((select array_agg(r->>'name' order by r->>'name') from jsonb_array_elements(:'l1'::jsonb->'rows') r) = array['Mei Tan','Test Child'], 'the rows are the two students, by name');
select t.ok((select r->>'guardian_name' = 'Mrs Test' and r->>'guardian_phone' = '+65 9123 4567' and r->>'household_name' = 'Test Child''s family' and (r->>'trial')::boolean = false and (r->>'ended')::boolean = false
               from jsonb_array_elements(:'l1'::jsonb->'rows') r where r->>'name' = 'Test Child'), 'a row carries the family, the main contact, and the read-only trial / ended flags');
select t.ok((:'l1'::jsonb->'counts') = '{"active":2,"ended":0,"trial":0,"all":2}'::jsonb, 'counts for every filter');
reset role;

-- ===================================================================== search: name, level, family, guardian name / email / phone digits; wildcards are literal
create function pg_temp.found(p_q text) returns text language sql as $$
  select coalesce(string_agg(r->>'name', ',' order by r->>'name'), '-') from jsonb_array_elements(staff_students(t.id('ss'), p_q)->'rows') r $$;
select t.as('00000000-0000-0000-0000-00000000f001'); set role authenticated;
select t.ok(pg_temp.found('test chi') = 'Test Child', 'search by part of the name, any case');
select t.ok(pg_temp.found('sec 2') = 'Test Child', 'search by level');
select t.ok(pg_temp.found('tan family') = 'Mei Tan', 'search by family name');
select t.ok(pg_temp.found('mrs tan') = 'Mei Tan', 'search by a guardian''s name (the second one)');
select t.ok(pg_temp.found('MRS.TEST@example') = 'Test Child', 'search by email');
select t.ok(pg_temp.found('9123 4567') = 'Test Child' and pg_temp.found('91234567') = 'Test Child' and pg_temp.found('+65 9123') = 'Test Child', 'search by phone, however it was typed');
select t.ok(pg_temp.found('8111') = 'Mei Tan', 'search by part of a phone number');
select t.ok(pg_temp.found('sec 2') = 'Test Child' and pg_temp.found('p6') = 'Mei Tan', 'a word with a digit in it (a level) is not mistaken for a phone number');
select t.ok(pg_temp.found('zzz') = '-', 'no match = empty list');
select t.ok(pg_temp.found('%') = '-' and pg_temp.found('_') = '-' and pg_temp.found('\') = '-', 'wildcard characters are searched for literally');
select t.fails($q$ select staff_students(t.id('ss'), repeat('x', 101)) $q$, 'a search longer than 100 characters');
select t.fails($q$ select staff_students(t.id('ss'), null, 'bogus') $q$, 'an unknown filter');
reset role;

-- ===================================================================== paging at scale (made-up students inserted directly as the database owner)
insert into households(id, org_id, name) select gen_random_uuid(), t.id('ss'), 'Pg family ' || i from generate_series(1, 60) i;
insert into students(tutor_id, org_id, name, level, household_id)
  select '00000000-0000-0000-0000-00000000f001', t.id('ss'), 'Pg ' || lpad(i::text, 2, '0'), 'P' || (1 + i % 6), (select id from households where org_id = t.id('ss') and name = 'Pg family ' || i)
  from generate_series(1, 60) i;
select t.as('00000000-0000-0000-0000-00000000f001'); set role authenticated;
select staff_students(t.id('ss'), null, 'active', 3, 25) as pg3 \gset
select t.ok((:'pg3'::jsonb->>'total')::int = 62 and jsonb_array_length(:'pg3'::jsonb->'rows') = 12 and (:'pg3'::jsonb->>'page')::int = 3, '62 students: page 3 of 25 holds the last 12');
select staff_students(t.id('ss'), null, 'active', 1, 25) as pg1 \gset
select staff_students(t.id('ss'), null, 'active', 2, 25) as pg2 \gset
select t.ok((select count(distinct r->>'id') from (select * from jsonb_array_elements(:'pg1'::jsonb->'rows') union all select * from jsonb_array_elements(:'pg2'::jsonb->'rows') union all select * from jsonb_array_elements(:'pg3'::jsonb->'rows')) x(r)) = 62,
            'the three pages together hold every student exactly once');
select t.ok((:'pg1'::jsonb->'rows'->0->>'name') = 'Mei Tan' and (:'pg1'::jsonb->'rows'->1->>'name') = 'Pg 01', 'sorted by name, case-insensitive');
select t.eq(jsonb_array_length(staff_students(t.id('ss'), null, 'active', 1, 100000)->'rows'), 62, 'a huge page size is capped at 100 (62 fit)');
select t.eq(jsonb_array_length(staff_students(t.id('ss'), null, 'active', 1, 0)->'rows'), 1, 'page size below 1 becomes 1');
select t.eq(jsonb_array_length(staff_students(t.id('ss'), null, 'active', 99, 25)->'rows'), 0, 'a page past the end is empty, not an error');
select t.eq((staff_students(t.id('ss'), 'Pg 0', 'active', 1, 5)->>'total')::int, 9, 'search + paging: "Pg 0" finds Pg 01..09, 5 per page');
reset role;
delete from students where name like 'Pg %' and org_id = t.id('ss'); delete from households where name like 'Pg family %' and org_id = t.id('ss');

-- ===================================================================== the student's sheet
insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, subject, rate, amount, status, taught_by, trial) values
  ('00000000-0000-0000-0000-00000000f001', t.id('ss'), t.id('kid'), (select today + 2 from td), '15:00', '16:00', 'Math', 99, 99, 'scheduled', t.id('ss_tutor_m'), false),
  ('00000000-0000-0000-0000-00000000f001', t.id('ss'), t.id('kid'), (select today + 1 from td), '15:00', '16:00', 'Science', 99, 99, 'scheduled', null, false),
  ('00000000-0000-0000-0000-00000000f001', t.id('ss'), t.id('kid'), (select today + 3 from td), '15:00', '16:00', 'Math', 99, 99, 'cancelled', null, false),
  ('00000000-0000-0000-0000-00000000f001', t.id('ss'), t.id('kid'), (select today - 5 from td), '15:00', '16:00', 'Math', 99, 99, 'done', t.id('ss_tutor_m'), true);
insert into recurring_slots(tutor_id, org_id, student_id, weekday, start_time, end_time, subject, rate)
  values ('00000000-0000-0000-0000-00000000f001', t.id('ss'), t.id('kid'), 2, '15:00', '16:00', 'English', 99);
select t.as('00000000-0000-0000-0000-00000000f003'); set role authenticated;
select staff_student(t.id('ss'), t.id('kid')) as sh \gset
reset role;
select t.ok((:'sh'::jsonb->>'name') = 'Test Child' and (:'sh'::jsonb->>'level') = 'Sec 2' and (:'sh'::jsonb->>'notes') = 'Prefers worked examples' and (:'sh'::jsonb->'household'->>'name') = 'Test Child''s family', 'the sheet has details and the family');
select t.ok((:'sh'::jsonb->'guardians'->0->>'phone') = '+65 9123 4567' and (:'sh'::jsonb->'guardians'->0->>'email') = 'mrs.test@example.com' and jsonb_array_length(:'sh'::jsonb->'guardians') = 1, 'the sheet has the guardian''s phone and email');
select t.ok((:'sh'::jsonb->'subjects') = '["English","Math","Science"]'::jsonb, 'subjects come from the lessons and the weekly slot');
select t.ok((:'sh'::jsonb->>'lessons_total')::int = 4 and (:'sh'::jsonb->>'lessons_trial')::int = 1 and (:'sh'::jsonb->>'trial')::boolean, 'trial is shown read-only: one trial lesson in the last 30 days');
select t.ok(jsonb_array_length(:'sh'::jsonb->'next_lessons') = 2 and (:'sh'::jsonb->'next_lessons'->0->>'subject') = 'Science' and (:'sh'::jsonb->'next_lessons'->1->>'tutor') = 'A tutor'
            and (:'sh'::jsonb->'next_lessons'->0->'tutor') = 'null'::jsonb, 'next lessons: upcoming only, cancelled left out, in date order, with the tutor''s name (null while there is none)');
select t.ok(not (:'sh'::jsonb::text ~* '(rate|amount|paid|compensation|cents|price)'), 'the sheet carries no money field');
select t.ok((select array_agg(k order by k) from jsonb_object_keys(:'sh'::jsonb) k) =
  array['created_at','end_date','ended','guardians','household','id','lessons_total','lessons_trial','level','name','next_lessons','notes','org_id','siblings','subjects','today','trial'],
  'the sheet has exactly the documented fields (adding one is a deliberate decision)');
select t.as('00000000-0000-0000-0000-00000000f001'); set role authenticated;
select t.ok((select (r->>'trial')::boolean from jsonb_array_elements(staff_students(t.id('ss'), null, 'all')->'rows') r where r->>'name' = 'Test Child'), 'the list shows the trial flag');
select t.ok(pg_temp.found('x') is not null and (select count(*) from jsonb_array_elements(staff_students(t.id('ss'), null, 'trial')->'rows')) = 1, 'the Trial filter finds the one student with a recent trial lesson');
reset role;

-- ===================================================================== edit: details, then a guardian's phone (family-wide)
select t.as('00000000-0000-0000-0000-00000000f002'); set role authenticated;
select staff_save_student(t.id('ss'), t.id('kid'), 'Test Child', 'Sec 3', null, null, null, null) as e1 \gset
reset role;
select t.ok(not (:'e1'::jsonb->>'created')::boolean and (select level = 'Sec 3' and notes is null from students where id = t.id('kid')), 'edit: level changed, a blank note clears it');
select t.ok((select count(*) = 1 and bool_and(phone = '+65 9123 4567') from guardians where household_id = t.id('kid_h')), 'guardians = null leaves the family''s contacts untouched');
-- add a sibling to the same family (no guardians needed: they are the family's)
select t.as('00000000-0000-0000-0000-00000000f003'); set role authenticated;
select staff_save_student(t.id('ss'), null, 'Test Sibling', 'P4', null, t.id('kid_h'), null, null) as r3 \gset
reset role;
select t.put('sib', (:'r3'::jsonb->>'student_id')::uuid);
select t.ok((:'r3'::jsonb->>'household_id')::uuid = t.id('kid_h') and (select household_id = t.id('kid_h') and contact = '+65 9123 4567' and recipient_name = 'Mrs Test' from students where id = t.id('sib')),
            'a sibling joins the existing family and gets the family''s main contact');
select t.ok((select count(*) from households where org_id = t.id('ss') and name like 'Test Child%') = 1, 'and no second household was made');
select t.fails($q$ select staff_save_student(t.id('ss'), null, 'test sibling', null, null, t.id('kid_h'), null, null) $q$, 'the same name twice in one family');
-- change the phone through the guardian's id; the whole family follows
select t.as('00000000-0000-0000-0000-00000000f003'); set role authenticated;
select (staff_student(t.id('ss'), t.id('kid'))->'guardians'->0->>'id')::uuid as gid1 \gset
select staff_save_student(t.id('ss'), t.id('kid'), 'Test Child', 'Sec 3', null, null, 'The Test family',
  jsonb_build_array(jsonb_build_object('id', :'gid1', 'name', 'Mrs Test', 'relation', 'Mother', 'phone', '+65 9000 1111', 'email', 'mrs.test@example.com'),
                    jsonb_build_object('name', 'Mr Test', 'relation', 'Father', 'phone', '90002222')));
reset role;
select t.ok((select count(*) = 2 and bool_or(id = :'gid1'::uuid and phone = '+65 9000 1111') and bool_or(name = 'Mr Test' and phone = '90002222') from guardians where household_id = t.id('kid_h')),
            'edit: one guardian updated in place (same id), one added');
select t.ok((select bool_and(contact = '+65 9000 1111') from students where household_id = t.id('kid_h')) and (select name = 'The Test family' and phone_key = '90001111' from households where id = t.id('kid_h')),
            'both siblings'' main contact and the family''s phone key follow the change; the family was renamed');
-- remove the second guardian
select t.as('00000000-0000-0000-0000-00000000f003'); set role authenticated;
select staff_save_student(t.id('ss'), t.id('kid'), 'Test Child', 'Sec 3', null, null, null,
  jsonb_build_array(jsonb_build_object('id', :'gid1', 'name', 'Mrs Test', 'phone', '+65 9000 1111')));
reset role;
select t.ok((select count(*) = 1 and bool_and(id = :'gid1'::uuid) from guardians where household_id = t.id('kid_h')), 'a guardian left out of the list is removed');
select t.ok(exists (select 1 from audit_log where org_id = t.id('ss') and table_name = 'guardians' and action = 'delete' and before->>'name' = 'Mr Test'), 'and the removal is in the audit log with what was removed');
select t.ok((select sum(case when action = 'staff_student_edit' then 1 else 0 end) >= 3 from audit_log where org_id = t.id('ss')), 'every edit leaves a named audit entry');

-- ===================================================================== validation (nothing half-saved)
select t.as('00000000-0000-0000-0000-00000000f003'); set role authenticated;
select t.fails($q$ select staff_save_student(t.id('ss'), null, '   ', null, null, null, null, '[{"name":"A","phone":"91112222"}]') $q$, 'a blank name', 'BAD_STUDENT');
select t.fails($q$ select staff_save_student(t.id('ss'), null, repeat('n', 121), null, null, null, null, '[{"name":"A","phone":"91112222"}]') $q$, 'a 121-character name', 'BAD_STUDENT');
select t.fails($q$ select staff_save_student(t.id('ss'), null, 'V1', repeat('l', 41), null, null, null, '[{"name":"A","phone":"91112222"}]') $q$, 'a 41-character level', 'BAD_STUDENT');
select t.fails($q$ select staff_save_student(t.id('ss'), null, 'V2', null, repeat('n', 1001), null, null, '[{"name":"A","phone":"91112222"}]') $q$, 'notes over 1000 characters', 'BAD_STUDENT');
select t.fails($q$ select staff_save_student(t.id('ss'), null, 'V3', null, null, null, null, null) $q$, 'a new family with no guardian at all', 'BAD_GUARDIAN');
select t.fails($q$ select staff_save_student(t.id('ss'), null, 'V4', null, null, null, null, '[]') $q$, 'an empty guardian list', 'BAD_GUARDIAN');
select t.fails($q$ select staff_save_student(t.id('ss'), null, 'V5', null, null, null, null, '[{"name":"A"}]') $q$, 'a guardian with neither phone nor email', 'BAD_GUARDIAN');
select t.fails($q$ select staff_save_student(t.id('ss'), null, 'V6', null, null, null, null, '[{"phone":"91112222"}]') $q$, 'a guardian with no name', 'BAD_GUARDIAN');
select t.fails($q$ select staff_save_student(t.id('ss'), null, 'V7', null, null, null, null, '[{"name":"A","phone":"abc"}]') $q$, 'a phone number that is letters', 'BAD_GUARDIAN');
select t.fails($q$ select staff_save_student(t.id('ss'), null, 'V8', null, null, null, null, '[{"name":"A","phone":"123"}]') $q$, 'a phone number with too few digits', 'BAD_GUARDIAN');
select t.fails($q$ select staff_save_student(t.id('ss'), null, 'V9', null, null, null, null, '[{"name":"A","email":"not-an-email"}]') $q$, 'a bad email', 'BAD_GUARDIAN');
select t.fails($q$ select staff_save_student(t.id('ss'), null, 'V10', null, null, null, null, '[1]') $q$, 'a guardian that is not an object', 'BAD_GUARDIAN');
select t.fails($q$ select staff_save_student(t.id('ss'), null, 'V11', null, null, null, null, '{"name":"A"}') $q$, 'guardians that are not a list', 'BAD_GUARDIAN');
select t.fails($q$ select staff_save_student(t.id('ss'), null, 'V12', null, null, null, null,
  (select jsonb_agg(jsonb_build_object('name', 'G' || i, 'phone', '9111000' || i)) from generate_series(1, 7) i)) $q$, 'seven guardians', 'BAD_GUARDIAN');
select t.fails($q$ select staff_save_student(t.id('ss'), t.id('kid'), 'Test Child', null, null, null, null, '[]') $q$, 'editing a family down to no contact at all', 'BAD_GUARDIAN');
select t.fails($q$ select staff_save_student(t.id('ss'), null, 'V13', null, null, null, repeat('h', 121), '[{"name":"A","phone":"91112222"}]') $q$, 'a 121-character family name', 'BAD_STUDENT');
reset role;
select t.ok(not exists (select 1 from students where org_id = t.id('ss') and name ~ '^V[0-9]+$') and not exists (select 1 from households where org_id = t.id('ss') and name like 'V%'), 'none of the refused saves left a student or household behind');

-- ===================================================================== other organisations' ids are "doesn't exist"
select set_config('request.jwt.claims', '', false);      -- (fixtures are inserted as the database owner, not as the last person)
insert into households(id, org_id, name) values ('f1000000-0000-0000-0000-000000000001', t.id('ss2'), 'Other family');
insert into guardians(id, org_id, household_id, name, phone) values ('f1000000-0000-0000-0000-000000000002', t.id('ss2'), 'f1000000-0000-0000-0000-000000000001', 'Other parent', '97778888');
insert into students(id, tutor_id, org_id, name, household_id) values ('f1000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-00000000f009', t.id('ss2'), 'Other Kid', 'f1000000-0000-0000-0000-000000000001');
select org_personal('00000000-0000-0000-0000-00000000f001') as solo_org \gset
select t.as('00000000-0000-0000-0000-00000000f003'); set role authenticated;
select t.fails($q$ select staff_save_student(t.id('ss'), null, 'X1', null, null, 'f1000000-0000-0000-0000-000000000001', null, null) $q$, 'adding a sibling to ANOTHER centre''s family', 'NOT_FOUND');
select t.fails($q$ select staff_save_student(t.id('ss'), t.id('kid'), 'Test Child', null, null, null, null, '[{"id":"f1000000-0000-0000-0000-000000000002","name":"Hijack","phone":"91112222"}]') $q$, 'editing ANOTHER centre''s guardian through my own student', 'NOT_FOUND');
select t.fails($q$ select staff_save_student(t.id('ss'), t.id('kid'), 'Test Child', null, null, null, null, '[{"id":"not-a-uuid","name":"Hijack","phone":"91112222"}]') $q$, 'a guardian id that is not an id', 'NOT_FOUND');
select t.fails($q$ select staff_student(t.id('ss'), 'f1000000-0000-0000-0000-000000000003') $q$, 'reading ANOTHER centre''s student through my own centre', 'NOT_FOUND');
select t.fails($q$ select staff_save_student(t.id('ss'), 'f1000000-0000-0000-0000-000000000003', 'Renamed', null, null, null, null, null) $q$, 'editing ANOTHER centre''s student through my own centre', 'NOT_FOUND');
select t.fails($q$ select staff_set_student_end(t.id('ss'), 'f1000000-0000-0000-0000-000000000003', current_date) $q$, 'discontinuing ANOTHER centre''s student through my own centre', 'NOT_FOUND');
select t.fails($q$ select staff_save_student(t.id('ss'), t.id('kid'), 'Test Child', null, null, 'f1000000-0000-0000-0000-000000000001', null, null) $q$, 'moving a student to another centre''s family', 'BAD_STUDENT');
select t.fails($q$ select staff_save_student(t.id('ss'), t.id('kid'), 'Test Child', null, null, t.id('mei_h'), null, null) $q$, 'moving a student to another family of the same centre (not supported yet)', 'BAD_STUDENT');
reset role;
select t.ok((select name = 'Other Kid' from students where id = 'f1000000-0000-0000-0000-000000000003') and (select name = 'Other parent' from guardians where id = 'f1000000-0000-0000-0000-000000000002'), 'the other centre''s rows are untouched');

-- ===================================================================== discontinue / bring back (lessons run until)
select t.as('00000000-0000-0000-0000-00000000f003'); set role authenticated;
select staff_set_student_end(t.id('ss'), t.id('sib'), (select today - 1 from td)) as d1 \gset
select t.ok((:'d1'::jsonb->>'ended')::boolean, 'a date in the past: the student is discontinued');
reset role;
select t.ok((select end_date = (select today - 1 from td) and active = false from students where id = t.id('sib')), 'end_date set, active off');
select t.as('00000000-0000-0000-0000-00000000f001'); set role authenticated;
select t.ok((staff_students(t.id('ss'), null, 'active')->'counts') = '{"active":2,"ended":1,"trial":1,"all":3}'::jsonb, 'counts: the ended student moved from active to ended');
select t.ok((select array_agg(r->>'name' order by r->>'name') from jsonb_array_elements(staff_students(t.id('ss'), null, 'ended')->'rows') r) = array['Test Sibling'], 'the Ended filter lists them');
select t.ok(not exists (select 1 from jsonb_array_elements(staff_students(t.id('ss'), null, 'active')->'rows') r where r->>'name' = 'Test Sibling'), 'and the Active list no longer does');
select t.ok((staff_student(t.id('ss'), t.id('sib'))->>'ended')::boolean, 'the sheet says ended');
select t.eq((staff_home(t.id('ss'))->>'students_active')::int, 2, 'the centre Home counts the same active students');
reset role;
insert into recurring_slots(id, tutor_id, org_id, student_id, weekday, start_time, end_time, subject, rate)
  values ('f1000000-0000-0000-0000-000000000051', '00000000-0000-0000-0000-00000000f001', t.id('ss'), t.id('sib'), 4, '15:00', '16:00', 'Math', 50);
select t.as('00000000-0000-0000-0000-00000000f003'); set role authenticated;
select staff_set_student_end(t.id('ss'), t.id('sib'), (select today - 2 from td));
reset role;
select t.ok((select active = false from recurring_slots where id = 'f1000000-0000-0000-0000-000000000051'), 'discontinuing switches the student''s weekly slots off');
select t.ok((select active = true from recurring_slots where student_id = t.id('kid') limit 1), 'and only theirs (a sibling''s slot stays on)');
select t.as('00000000-0000-0000-0000-00000000f003'); set role authenticated;
select staff_set_student_end(t.id('ss'), t.id('sib'), null);
reset role;
select t.ok((select end_date is null and active = true from students where id = t.id('sib')) and (select active = true from recurring_slots where id = 'f1000000-0000-0000-0000-000000000051'), 'null brings them back: date cleared, active, slots on again');
select t.as('00000000-0000-0000-0000-00000000f003'); set role authenticated;
select staff_set_student_end(t.id('ss'), t.id('sib'), (select today + 30 from td)) as d2 \gset
reset role;
select t.ok(not (:'d2'::jsonb->>'ended')::boolean and (select end_date = (select today + 30 from td) and active = true from students where id = t.id('sib')) and (select active = true from recurring_slots where id = 'f1000000-0000-0000-0000-000000000051'),
            'a date still to come: not ended yet, slots stay on');
select t.as('00000000-0000-0000-0000-00000000f003'); set role authenticated;
select staff_set_student_end(t.id('ss'), t.id('sib'), (select today from td)) as d3 \gset
reset role;
select t.ok(not (:'d3'::jsonb->>'ended')::boolean, 'today is the last day: still active today (inclusive), the same rule as the Home count');
select t.fails($q$ select staff_set_student_end(t.id('ss'), t.id('sib'), date '1999-12-31') $q$, 'a date before 2000', 'BAD_DATE');
select t.fails($q$ select staff_set_student_end(t.id('ss'), t.id('sib'), date '2101-01-01') $q$, 'a date after 2100', 'BAD_DATE');
select t.ok(exists (select 1 from audit_log where org_id = t.id('ss') and action = 'staff_student_end' and row_id = t.id('sib')::text) and exists (select 1 from audit_log where org_id = t.id('ss') and action = 'staff_student_reactivate' and row_id = t.id('sib')::text),
            'ending and bringing back both leave named audit entries');
select staff_set_student_end(t.id('ss'), t.id('sib'), null) from (select 1) x where false;
select t.eq((select count(*) from lessons where student_id = t.id('kid')), 4, 'lessons are never touched by any of this');

-- ===================================================================== who may call: every function, every kind of person
create function pg_temp.matrix(p_fn text, p_sql text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-00000000f004', 'role', 'authenticated')::text, false);
  perform pg_temp.refused('00000000-0000-0000-0000-00000000f004', p_sql, 'NOT_ALLOWED', p_fn || ': staff with only manage_timetable');
  perform pg_temp.refused('00000000-0000-0000-0000-00000000f005', p_sql, 'NOT_ALLOWED', p_fn || ': staff with only issue_invoices');
  perform pg_temp.refused('00000000-0000-0000-0000-00000000f006', p_sql, 'NOT_FOUND', p_fn || ': a tutor of the centre');
  perform pg_temp.refused('00000000-0000-0000-0000-00000000f00a', p_sql, 'NOT_FOUND', p_fn || ': staff whose membership is switched off');
  perform pg_temp.refused('00000000-0000-0000-0000-00000000f007', p_sql, 'NOT_FOUND', p_fn || ': someone with no membership');
  perform pg_temp.refused('00000000-0000-0000-0000-00000000f009', p_sql, 'NOT_FOUND', p_fn || ': the owner of a DIFFERENT centre');
end $$;
set role authenticated;
select pg_temp.matrix('staff_students', $q$ select staff_students(t.id('ss')) $q$);
select pg_temp.matrix('staff_student', $q$ select staff_student(t.id('ss'), t.id('kid')) $q$);
select pg_temp.matrix('staff_save_student (add)', $q$ select staff_save_student(t.id('ss'), null, 'Nope', null, null, null, null, '[{"name":"A","phone":"91112222"}]') $q$);
select pg_temp.matrix('staff_save_student (edit)', $q$ select staff_save_student(t.id('ss'), t.id('kid'), 'Nope', null, null, null, null, null) $q$);
select pg_temp.matrix('staff_set_student_end', $q$ select staff_set_student_end(t.id('ss'), t.id('kid'), current_date) $q$);
-- the same answer for "no such centre", "a solo organisation" and "someone else's centre"
select pg_temp.refused('00000000-0000-0000-0000-00000000f001', $q$ select staff_students(gen_random_uuid()) $q$, 'NOT_FOUND', 'an id that doesn''t exist');
select pg_temp.refused('00000000-0000-0000-0000-00000000f001', format($q$ select staff_students(%L) $q$, :'solo_org'), 'NOT_FOUND', 'the owner''s own SOLO organisation (students never go there)');
select pg_temp.refused('00000000-0000-0000-0000-00000000f001', format($q$ select staff_save_student(%L, null, 'Solo kid', null, null, null, null, '[{"name":"A","phone":"91112222"}]') $q$, :'solo_org'), 'NOT_FOUND', 'adding a centre-style student to a solo organisation');
select pg_temp.refused('00000000-0000-0000-0000-00000000f001', $q$ select staff_students(t.id('ss2')) $q$, 'NOT_FOUND', 'the owner asking about someone else''s centre');
select pg_temp.refused('00000000-0000-0000-0000-0000000000a1', $q$ select staff_students(t.id('ss')) $q$, 'NOT_FOUND', 'a solo tutor with no link to this centre');
select pg_temp.refused('00000000-0000-0000-0000-00000000f001', $q$ select staff_students(null) $q$, 'NOT_FOUND', 'no centre given');
reset role;
select t.ok(not exists (select 1 from students where org_id = :'solo_org') or not exists (select 1 from students where org_id = :'solo_org' and name = 'Solo kid'), 'nothing was written to the solo organisation');
select t.ok(not exists (select 1 from students where name in ('Nope', 'Solo kid')), 'and none of the refused calls wrote anything');
set role anon;
select t.fails($q$ select staff_students(t.id('ss')) $q$, 'an anonymous list');
select t.fails($q$ select staff_save_student(t.id('ss'), null, 'Anon', null, null, null, null, '[{"name":"A","phone":"91112222"}]') $q$, 'an anonymous add');
reset role;
select t.ok(not has_function_privilege('anon', 'public.staff_students(uuid,text,text,int,int)', 'execute') and not has_function_privilege('anon', 'public.staff_student(uuid,uuid)', 'execute')
        and not has_function_privilege('anon', 'public.staff_save_student(uuid,uuid,text,text,text,uuid,text,jsonb)', 'execute') and not has_function_privilege('anon', 'public.staff_set_student_end(uuid,uuid,date)', 'execute')
        and has_function_privilege('authenticated', 'public.staff_students(uuid,text,text,int,int)', 'execute') and has_function_privilege('authenticated', 'public.staff_student(uuid,uuid)', 'execute')
        and has_function_privilege('authenticated', 'public.staff_save_student(uuid,uuid,text,text,text,uuid,text,jsonb)', 'execute') and has_function_privilege('authenticated', 'public.staff_set_student_end(uuid,uuid,date)', 'execute'),
        'only signed-in users may call the four functions');
select t.ok(not has_function_privilege('authenticated', 'public.staff_students_gate(uuid)', 'execute') and not has_function_privilege('authenticated', 'public.staff_clean_guardian(jsonb)', 'execute'), 'the gate and the contact cleaner are internal');

-- ===================================================================== tutors: still NO table access to students, families or contacts
select t.as('00000000-0000-0000-0000-00000000f006'); set role authenticated;
select t.eq((select count(*) from students), 0, 'tutor: students table = 0 rows');
select t.eq((select count(*) from households), 0, 'tutor: households table = 0 rows');
select t.eq((select count(*) from guardians), 0, 'tutor: guardians table = 0 rows');
select t.eq((select count(*) from students where org_id = t.id('ss')), 0, 'tutor: still 0 rows when asking for the centre by id');
select t.fails($q$ insert into students(tutor_id, org_id, name) values ('00000000-0000-0000-0000-00000000f006', t.id('ss'), 'Tutor-made') $q$, 'a tutor adding a student by writing the table');
select t.fails($q$ insert into guardians(org_id, household_id, name, phone) values (t.id('ss'), t.id('kid_h'), 'Tutor-made', '91112222') $q$, 'a tutor adding a guardian by writing the table');
select t.eq(t.rows($q$ update guardians set phone = '90000000' where household_id = t.id('kid_h') $q$), 0, 'a tutor changing a parent''s phone by writing the table touches nothing');
reset role;
-- staff with other permissions can READ the tables (the existing read policy), but only manage_students may WRITE them
select t.as('00000000-0000-0000-0000-00000000f004'); set role authenticated;
select t.eq(t.rows($q$ update guardians set phone = '90000000' where household_id = t.id('kid_h') $q$), 0, 'timetable-only staff changing a phone by writing the table touches nothing');
reset role;
select t.ok((select bool_and(phone = '+65 9000 1111') from guardians where household_id = t.id('kid_h')), 'the number is as staff left it');

-- ===================================================================== the setting that matters: lessons.tutors_see_parent_contact (default off)
insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, subject, rate, amount, status, taught_by)
  values ('00000000-0000-0000-0000-00000000f001', t.id('ss'), t.id('kid'), (select today from td), '17:00', '18:00', 'Math', 99, 99, 'scheduled', t.id('ss_tutor_m'));
select t.put('ctl', (select id from lessons where student_id = t.id('kid') and start_time = '17:00'));
select t.as('00000000-0000-0000-0000-00000000f006'); set role authenticated;
select t.ok((select parent_contact is null from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('ctl')), 'default (off): the tutor sees NO parent contact on a staff-added student');
select t.ok((select student_name = 'Test Child' from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('ctl')), 'but still sees the student''s name');
reset role;
select t.as('00000000-0000-0000-0000-00000000f001'); set role authenticated;
select org_save_settings(t.id('ss'), jsonb_set(t.centre_settings(), '{lessons,tutors_see_parent_contact}', 'true'), current_date);
reset role;
select t.as('00000000-0000-0000-0000-00000000f006'); set role authenticated;
select t.ok((select parent_contact = '+65 9000 1111' from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('ctl')), 'switched ON: the tutor sees the number staff entered (kept in step with the family''s first contact)');
reset role;
select t.as('00000000-0000-0000-0000-00000000f003'); set role authenticated;
select staff_save_student(t.id('ss'), t.id('kid'), 'Test Child', 'Sec 3', null, null, null,
  jsonb_build_array(jsonb_build_object('id', :'gid1', 'name', 'Mrs Test', 'phone', '+65 9555 0000')));
reset role;
select t.as('00000000-0000-0000-0000-00000000f006'); set role authenticated;
select t.ok((select parent_contact = '+65 9555 0000' from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('ctl')), 'and a later change by staff reaches the tutor too');
select t.eq((select count(*) from students), 0, 'even with the setting on, the tutor still has no table access');
reset role;

-- ===================================================================== solo tutors are untouched
select org_personal('00000000-0000-0000-0000-0000000000a1') as tina_solo \gset
select t.as('00000000-0000-0000-0000-0000000000a1'); set role authenticated;
insert into students(tutor_id, name) values ('00000000-0000-0000-0000-0000000000a1', 'Solo After Staff Students');
select t.ok(exists (select 1 from students where name = 'Solo After Staff Students' and org_id = :'tina_solo'), 'a solo tutor can still add a student the old way, into their own solo organisation');
select t.eq((select count(*) from students where org_id = t.id('ss')), 0, 'and still cannot see a centre''s students');
reset role;
