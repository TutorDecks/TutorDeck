-- T35-E tests: the centre owner's data export (db/migration_org_export.sql). Runs after tutor_moves_test.sql in the same throwaway database (reuses the t.* helpers).
-- Covers: the catalogue (every table with an org id is exported or excluded WITH a reason; no secret-looking column; every column exists), the owner-only gate for every
-- other kind of caller, the audited start / finish, job rules, keyset paging, empty tables, isolation between centres, payout masking on and off, secrets scrubbed from the
-- audit copy, "who" columns turned into names, the hourly limit. All names, numbers and tokens below are FAKE.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000ef01', 'ex.ownerA@centre.test'),  ('00000000-0000-0000-0000-00000000ef02', 'ex.staff@centre.test'),
  ('00000000-0000-0000-0000-00000000ef03', 'ex.tutor@centre.test'),   ('00000000-0000-0000-0000-00000000ef04', 'ex.parent@centre.test'),
  ('00000000-0000-0000-0000-00000000ef05', 'ex.ownerB@centre.test'),  ('00000000-0000-0000-0000-00000000ef06', 'ex.solo@centre.test'),
  ('00000000-0000-0000-0000-00000000ef07', 'ex.admin@centre.test'),   ('00000000-0000-0000-0000-00000000ef08', 'ex.co-owner-off@centre.test'),
  ('00000000-0000-0000-0000-00000000ef09', 'ex.gone@centre.test');
\set oa '00000000-0000-0000-0000-00000000ef01'
\set stf '00000000-0000-0000-0000-00000000ef02'
\set tut '00000000-0000-0000-0000-00000000ef03'
\set par '00000000-0000-0000-0000-00000000ef04'
\set ob  '00000000-0000-0000-0000-00000000ef05'
\set solo '00000000-0000-0000-0000-00000000ef06'
\set adm '00000000-0000-0000-0000-00000000ef07'
\set off '00000000-0000-0000-0000-00000000ef08'
\set gone '00000000-0000-0000-0000-00000000ef09'

select t.as(:'oa'); set role authenticated; select t.put('xa', org_create_centre('Export Centre A', t.centre_settings())); reset role;
select t.as(:'ob'); set role authenticated; select t.put('xb', org_create_centre('Export Centre B', t.centre_settings())); reset role;
update memberships set display_name = 'Owner Alpha' where org_id = t.id('xa') and user_id = :'oa';
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('xa'), :'stf', 'Staff Sam', 'staff', array['manage_timetable','manage_students','manage_tutors','issue_invoices','record_payments','view_revenue','run_tutor_pay','view_audit_log','view_payout_details'], 'active'),
  (t.id('xa'), :'tut', 'Tutor Tan', 'tutor', '{}', 'active'),
  (t.id('xa'), :'par', 'Parent Pat', 'parent', '{}', 'active'),
  (t.id('xa'), :'off', 'Old Owner', 'owner', '{}', 'disabled');
select t.put('xtut', (select id from memberships where org_id = t.id('xa') and user_id = :'tut'));
insert into platform_admins(user_id) values (:'adm');
insert into support_access_grants(org_id, granted_by, reason, expires_at) values (t.id('xa'), :'oa', 'support test', now() + interval '1 day');

select t.as(:'oa');   -- the row guard checks the signed-in person even for the superuser
-- ---- centre A's data: odd names on purpose (apostrophe, comma, quote, emoji, Chinese), a phone with a plus, a leaver who recorded a payment
insert into households(org_id, name, phone_key) values (t.id('xa'), 'The O''Neil, Family "Q" 🙂', '91234567'), (t.id('xa'), '陈家', '98765432');
select t.put('xh1', (select id from households where org_id = t.id('xa') and name like 'The O%'));
insert into guardians(org_id, household_id, name, relation, phone, email) values
  (t.id('xa'), t.id('xh1'), 'Mrs O''Neil', 'mother', '+65 9123 4567', 'mrs.oneil@family.test'), (t.id('xa'), t.id('xh1'), '=HYPERLINK("x")', 'father', '98765432', 'fa@family.test');
insert into students(org_id, tutor_id, name, level, household_id, contact, notes) values
  (t.id('xa'), :'oa', 'Ann O''Neil', 'P5', t.id('xh1'), '+65 9123 4567', 'Needs "extra" help, Fridays'), (t.id('xa'), :'oa', '陈小明', 'S1', (select id from households where org_id = t.id('xa') and name = '陈家'), null, null),
  (t.id('xa'), :'oa', 'Zed Zero', 'P6', null, null, null);
select t.put('xs1', (select id from students where org_id = t.id('xa') and name like 'Ann%'));
insert into lessons(org_id, tutor_id, student_id, taught_by, lesson_date, start_time, end_time, subject, rate, amount, status)
  select t.id('xa'), :'oa', t.id('xs1'), t.id('xtut'), date '2026-11-01' + g, '16:00', '17:00', 'Math', 50, 50, 'scheduled' from generate_series(0, 6) g;
insert into recurring_slots(org_id, tutor_id, student_id, taught_by, weekday, start_time, end_time, subject, rate) values (t.id('xa'), :'oa', t.id('xs1'), t.id('xtut'), 2, '16:00', '17:00', 'Math', 50);
insert into exams(org_id, tutor_id, student_id, subject, exam_date, score, max_score) values (t.id('xa'), :'oa', t.id('xs1'), 'Math', '2026-12-01', 80, 100);
insert into invoices(org_id, tutor_id, student_id, invoice_no, total, data) values (t.id('xa'), :'oa', t.id('xs1'), 'LEG-1', 10, '{"html":"<p>BIGHTML</p>","lines":[1]}');
select t.put('xtoken', (select share_token from invoices where org_id = t.id('xa') and invoice_no = 'LEG-1'));
insert into centre_invoices(org_id, kind, status, household_id, total_cents, net_cents, gst_cents, created_by)
  values (t.id('xa'), 'lesson', 'draft', t.id('xh1'), 10900, 10000, 900, :'oa');
insert into centre_invoice_lines(org_id, invoice_id, position, description, qty, unit_cents) select t.id('xa'), id, 1, 'Lesson', 1, 5000 from centre_invoices where org_id = t.id('xa');
insert into centre_payments(org_id, kind, household_id, method, amount_cents, received_on, recorded_by) values
  (t.id('xa'), 'payment', t.id('xh1'), 'cash', 5000, '2026-11-05', :'oa'), (t.id('xa'), 'payment', t.id('xh1'), 'cash', 2500, '2026-11-06', :'gone');
insert into org_subscriptions(org_id, tier, status, stripe_customer_id, stripe_subscription_id) values (t.id('xa'), 'centre', 'active', 'cus_FAKEEXPORT1', 'sub_FAKEEXPORT1')
  on conflict (org_id) do update set stripe_customer_id = 'cus_FAKEEXPORT1', stripe_subscription_id = 'sub_FAKEEXPORT1';
-- the tutor saves a bank account and a PayNow number the proper way (only the tutor can)
select t.as(:'tut'); set role authenticated; select tutor_save_payout(t.id('xtut'), 'bank', '123-456-7890', 'Test Bank', 'Pat Payout', true); reset role;
select t.as(:'ob');
-- centre B: its own data, with markers that must never appear in A's export
insert into households(org_id, name) values (t.id('xb'), 'B-MARKER Family');
insert into students(org_id, tutor_id, name, household_id) values (t.id('xb'), :'ob', 'B-MARKER Student', (select id from households where org_id = t.id('xb')));
insert into centre_payments(org_id, kind, household_id, method, amount_cents, received_on, recorded_by, note) values (t.id('xb'), 'payment', (select id from households where org_id = t.id('xb')), 'cash', 777, '2026-11-05', :'ob', 'B-MARKER note');

select t.as(:'oa');
-- ---- helpers
create function pg_temp.as_user(p_user text, p_sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', case when p_user = '' then '' else json_build_object('sub', p_user, 'role', 'authenticated')::text end, false);
  perform set_config('role', case when p_user = '' then 'anon' else 'authenticated' end, true);
  begin execute p_sql into r; exception when others then perform set_config('role', 'postgres', true); raise; end;
  perform set_config('role', 'postgres', true);
  return r;
end $$;
create function pg_temp.refused(p_user text, p_sql text, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin
  begin perform pg_temp.as_user(p_user, p_sql); exception when others then m := sqlerrm; end;
  if m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS refused: % (%)', p_msg, m;
end $$;
-- one whole export as the given owner: returns {table: [all rows as arrays]} and the job; pages of p_page rows
create function pg_temp.export_all(p_user text, p_org uuid, p_full boolean, p_page int) returns jsonb language plpgsql as $$
declare st jsonb; job bigint; tb jsonb; r jsonb; after text; out jsonb := '{}'::jsonb; cols jsonb := '{}'::jsonb; rows jsonb;
begin
  st := pg_temp.as_user(p_user, format('select org_export_start(%L, %L)', p_org, p_full));
  job := (st->>'job')::bigint;
  for tb in select * from jsonb_array_elements(st->'tables') loop
    after := null; rows := '[]'::jsonb;
    loop
      r := pg_temp.as_user(p_user, format('select org_export_page(%L, %s, %L, %L, %s)', p_org, job, tb->>'tbl', after, p_page));
      rows := rows || (r->'rows'); cols := cols || jsonb_build_object(tb->>'tbl', r->'cols');
      after := r->>'next'; exit when after is null;
    end loop;
    out := out || jsonb_build_object(tb->>'tbl', rows);
  end loop;
  return jsonb_build_object('job', job, 'start', st, 'rows', out, 'cols', cols);
end $$;
-- run a query as the superuser
create function pg_temp.sc(p text) returns text language plpgsql security definer as $$ declare r text; begin execute p into r; return r; end $$;

-- ===================================================================== the catalogue
select t.ok((select count(*) from org_export_catalog() where mode = 'include') >= 30, 'the catalogue exports 30+ tables');
select t.ok(not exists (select 1 from org_owned_columns() o where not exists (select 1 from org_export_catalog() c where c.tbl = o.tbl and c.org_col = o.col)
                          and o.tbl not in (select tbl from org_export_catalog())), 'every table with an organisation column is exported or excluded');
select t.ok((select count(*) from (select tbl from org_export_catalog() group by tbl having count(*) > 1) d) = 0, 'no table is listed twice');
-- the coverage check really goes red: a table nobody listed shows up as missing
create table public.zz_export_dummy(id uuid primary key default gen_random_uuid(), org_id uuid references organisations(id) on delete cascade);
select t.ok(exists (select 1 from org_owned_columns() o where o.tbl = 'zz_export_dummy' and not exists (select 1 from org_export_catalog() c where c.tbl = o.tbl)), 'a new table with an org id is reported as not in the catalogue (the check goes red)');
drop table public.zz_export_dummy;
select t.ok((select bool_and(reason is not null and length(reason) > 20) from org_export_catalog() where mode = 'exclude')
        and (select count(*) from org_export_catalog() where mode = 'exclude') >= 3, 'every excluded table carries a written reason');
select t.ok((select bool_and(mode in ('include', 'exclude')) from org_export_catalog()), 'modes are include / exclude only');
-- every plain column exists; every table has its org column and key; computed columns have unique names
select c.tbl || '.' || x as missing_col from org_export_catalog() c, unnest(c.cols) x
  where c.mode = 'include' and position('=' in x) = 0 and not exists (select 1 from information_schema.columns i where i.table_schema = 'public' and i.table_name = c.tbl and i.column_name = x);
select t.ok(not exists (
  select 1 from org_export_catalog() c, unnest(c.cols) x
  where c.mode = 'include' and position('=' in x) = 0
    and not exists (select 1 from information_schema.columns i where i.table_schema = 'public' and i.table_name = c.tbl and i.column_name = x)), 'every plain catalogue column exists in its table');
select t.ok(not exists (select 1 from org_export_catalog() c where not exists (select 1 from information_schema.columns i where i.table_schema = 'public' and i.table_name = c.tbl and i.column_name = c.org_col)
                          or not exists (select 1 from information_schema.columns i where i.table_schema = 'public' and i.table_name = c.tbl and i.column_name = c.key_col)), 'every table has its org column and its key column');
select t.ok(not exists (select 1 from org_export_catalog() c where c.mode = 'include' and (select count(*) from unnest(c.cols) x) <> (select count(distinct split_part(x, '=', 1)) from unnest(c.cols) x)), 'column names are unique within a table');
select t.ok(not exists (select 1 from org_export_catalog() c where c.mode = 'include' and not (c.key_col = any (select split_part(x, '=', 1) from unnest(c.cols) x)) and c.tbl <> 'organisations'), 'the paging key is itself an exported column');
-- nothing secret-looking is exported: no column NAME or expression mentions token / hash / secret / _enc / stripe / password / refresh / share, and no user id column
select t.ok(not exists (select 1 from org_export_catalog() c, unnest(c.cols) x where c.mode = 'include' and x ~* '(token|hash|secret|_enc|stripe|password|refresh|share|brevo|gcal)'), 'no exported column or expression looks like a secret');
select t.ok(not exists (select 1 from org_export_catalog() c, unnest(c.cols) x where c.mode = 'include' and split_part(x, '=', 1) in ('user_id', 'tutor_id', 'owner_id') ), 'no raw user id column is exported');
select t.ok(not exists (select 1 from org_export_catalog() c, unnest(c.cols) x where c.mode = 'include' and split_part(x, '=', 1) in ('created_by','issued_by','recorded_by','requested_by','actor','decided_by','granted_by','sent_by','attendance_marked_by','changed_by_tutor') and split_part(x, '=', 2) <> '@who'), 'every person-reference column is turned into a name');
select t.ok(exists (select 1 from org_export_catalog() c, unnest(c.cols) x where c.tbl = 'tutor_payout_details' and x = 'paynow_id=@mask') and exists (select 1 from org_export_catalog() c, unnest(c.cols) x where c.tbl = 'tutor_payout_details' and x = 'account_no=@mask')
        and exists (select 1 from org_export_catalog() c, unnest(c.cols) x where c.tbl = 'tutor_payout_details' and x = 'account_holder=@maskname'), 'payout numbers and the holder name are masked columns');
select t.ok(not exists (select 1 from org_export_catalog() c where c.mode = 'include' and c.tbl in ('org_subscriptions', 'centre_invoice_share', 'org_notifications')), 'billing-provider ids, share links and notices are not exported');
select t.ok('share_token' = any (org_export_secret_keys()) and 'stripe_customer_id' = any (org_export_secret_keys()) and 'account_no' = any (org_export_secret_keys()), 'the audit scrub list names the secret keys');

-- ===================================================================== grants
select t.ok(not has_function_privilege('anon', 'public.org_export_start(uuid,boolean)', 'execute') and not has_function_privilege('anon', 'public.org_export_page(uuid,bigint,text,text,int)', 'execute')
        and not has_function_privilege('anon', 'public.org_export_finish(uuid,bigint,jsonb)', 'execute') and not has_function_privilege('anon', 'public.org_export_catalog()', 'execute'), 'anonymous cannot call the export functions');
select t.ok(has_function_privilege('authenticated', 'public.org_export_start(uuid,boolean)', 'execute') and has_function_privilege('authenticated', 'public.org_export_page(uuid,bigint,text,text,int)', 'execute')
        and has_function_privilege('authenticated', 'public.org_export_finish(uuid,bigint,jsonb)', 'execute'), 'signed-in users can call the three (each re-checks the owner)');
select t.ok(not has_function_privilege('authenticated', 'public.org_export_gate(uuid)', 'execute') and not has_function_privilege('authenticated', 'public.org_export_who(uuid,uuid)', 'execute')
        and not has_function_privilege('authenticated', 'public.org_export_job(uuid,bigint)', 'execute') and not has_function_privilege('authenticated', 'public.org_export_secret_keys()', 'execute'), 'the helpers are not an API');

-- ===================================================================== who may start (everyone but an active owner of a centre gets NOT_FOUND)
select pg_temp.refused(:'stf', format('select org_export_start(%L)', t.id('xa')), 'NOT_FOUND', 'staff with every permission');
select pg_temp.refused(:'tut', format('select org_export_start(%L)', t.id('xa')), 'NOT_FOUND', 'a tutor of the centre');
select pg_temp.refused(:'par', format('select org_export_start(%L)', t.id('xa')), 'NOT_FOUND', 'a parent of the centre');
select pg_temp.refused(:'ob',  format('select org_export_start(%L)', t.id('xa')), 'NOT_FOUND', 'the owner of ANOTHER centre');
select pg_temp.refused(:'off', format('select org_export_start(%L)', t.id('xa')), 'NOT_FOUND', 'an owner whose membership is disabled');
select pg_temp.refused(:'adm', format('select org_export_start(%L)', t.id('xa')), 'NOT_FOUND', 'a platform admin, even with a live support grant');
select pg_temp.refused(:'solo', format('select org_export_start(%L)', t.id('xa')), 'NOT_FOUND', 'a stranger');
select pg_temp.refused('00000000-0000-0000-0000-0000000000a1', format('select org_export_start(%L)', t.id('tina_org')), 'NOT_FOUND', 'a solo tutor on their OWN solo organisation');
select pg_temp.refused('00000000-0000-0000-0000-0000000000a1', format('select org_export_start(%L)', t.id('xa')), 'NOT_FOUND', 'a solo tutor on a centre');
select pg_temp.refused('', format('select org_export_start(%L)', t.id('xa')), '', 'an anonymous caller (no execute right at all)');
select pg_temp.refused(:'oa', 'select org_export_start(null)', 'NOT_FOUND', 'a null organisation');
select pg_temp.refused(:'oa', 'select org_export_start(gen_random_uuid())', 'NOT_FOUND', 'an organisation that does not exist');
select t.ok(not exists (select 1 from audit_log where action like 'org_export%' and org_id = t.id('xa')), 'refused callers left no audit row (nothing was started)');

-- ===================================================================== the owner: start
create temp table ex1 as select pg_temp.export_all(:'oa', t.id('xa'), false, 3) j;
select t.ok((select (j->>'job') is not null from ex1), 'the owner gets a job number');
select t.ok((select count(*) from jsonb_array_elements((select j->'start'->'tables' from ex1))) = (select count(*) from org_export_catalog() where mode = 'include'), 'start lists every included table, in the catalogue order');
select t.eq((select (e->>'rows')::numeric from ex1, jsonb_array_elements(j->'start'->'tables') e where e->>'tbl' = 'lessons'), 7, 'start counts A''s lessons (7)');
select t.eq((select (e->>'rows')::numeric from ex1, jsonb_array_elements(j->'start'->'tables') e where e->>'tbl' = 'students'), 3, 'start counts A''s students (3)');
select t.eq((select (e->>'rows')::numeric from ex1, jsonb_array_elements(j->'start'->'tables') e where e->>'tbl' = 'organisations'), 1, 'organisations: exactly the one centre');
select t.ok(exists (select 1 from audit_log where org_id = t.id('xa') and action = 'org_export_started' and actor = :'oa' and (after->>'full_payout')::boolean is false and after->>'payout_numbers' = 'masked'), 'the start is audited: who, masked flag');
select t.ok((select jsonb_typeof(after->'expected') = 'object' and after->'tables' ? 'lessons' and (after->'expected'->>'lessons')::int = 7 from audit_log where action = 'org_export_started' and org_id = t.id('xa') order by id limit 1), 'the audit row holds the table names and the row counts');
select t.ok(not exists (select 1 from audit_log where action like 'org_export%' and (before::text || after::text) ~* '(O.Neil|Fam|Pat Payout|123-456|91234567|mrs\.oneil|Test Bank)'), 'the audit rows hold counts only, never data');

-- ===================================================================== paging
select t.ok((select jsonb_array_length(j->'rows'->'lessons') = 7 from ex1), 'paging by 3 gives all 7 lessons back');
select t.ok((select (select count(distinct r->>0) from jsonb_array_elements(j->'rows'->'lessons') r) = 7 from ex1), 'no lesson appears twice');
select t.ok((select (select array_agg(r->>0 order by ord) from jsonb_array_elements(j->'rows'->'lessons') with ordinality x(r, ord)) = (select array_agg(id::text order by id) from lessons where org_id = t.id('xa')) from ex1), 'lessons come in key order, none missed');
select t.ok((select j->'cols'->'lessons' = (select to_jsonb(array_agg(split_part(x, '=', 1))) from org_export_catalog() c, unnest(c.cols) x where c.tbl = 'lessons') from ex1), 'the page names its columns in catalogue order');
select t.ok(exists (select 1 from ex1, jsonb_array_elements(j->'rows'->'lessons') r where r->>3 = 'Ann O''Neil' or r->>2 = 'Ann O''Neil'), 'a lesson carries the student name');
select t.ok(exists (select 1 from ex1, jsonb_array_elements(j->'rows'->'lessons') r where r::text like '%Tutor Tan%'), 'and the tutor name');
select t.ok((select jsonb_array_length(j->'rows'->'branches') = 0 and jsonb_array_length(j->'rows'->'rooms') = 0 and jsonb_array_length(j->'rows'->'centre_late_fees') = 0 from ex1), 'tables with no rows give an empty page (no error)');
select t.ok((select jsonb_array_length(j->'rows'->'students') = 3 and jsonb_array_length(j->'rows'->'households') = (select count(*) from households where org_id = t.id('xa')) and jsonb_array_length(j->'rows'->'guardians') = (select count(*) from guardians where org_id = t.id('xa')) from ex1), 'households, guardians and students are all there');
-- one page, edge cases of the cursor and limit
create temp table jb as select (j->>'job')::bigint job from ex1;
select t.eq((select jsonb_array_length(pg_temp.as_user(:'oa', format('select org_export_page(%L, %s, ''lessons'', null, 0)', t.id('xa'), (select job from jb)))->'rows')), 1, 'a limit of 0 is raised to 1 row');
select t.eq((select jsonb_array_length(pg_temp.as_user(:'oa', format('select org_export_page(%L, %s, ''lessons'', null, -5)', t.id('xa'), (select job from jb)))->'rows')), 1, 'a negative limit is raised to 1 row');
select t.eq((select jsonb_array_length(pg_temp.as_user(:'oa', format('select org_export_page(%L, %s, ''lessons'', null, 5000000)', t.id('xa'), (select job from jb)))->'rows')), 7, 'a huge limit is capped (all 7 rows, no error)');
select t.ok((select (pg_temp.as_user(:'oa', format('select org_export_page(%L, %s, ''lessons'', null, 7)', t.id('xa'), (select job from jb)))->>'next') is not null), 'a full page returns a cursor (the last page is detected by an empty next page)');
select t.ok((select pg_temp.as_user(:'oa', format('select org_export_page(%L, %s, ''lessons'', %L, 7)', t.id('xa'), (select job from jb), (select id::text from lessons where org_id = t.id('xa') order by id desc limit 1)))->'rows' = '[]'::jsonb), 'a page after the last key is empty and has no cursor');
select pg_temp.refused(:'oa', format('select org_export_page(%L, %s, ''lessons'', ''not-a-uuid'', 10)', t.id('xa'), (select job from jb)), 'NOT_ALLOWED: bad cursor', 'a cursor that is not a key');
select pg_temp.refused(:'oa', format('select org_export_page(%L, %s, ''students; drop table students'', null, 10)', t.id('xa'), (select job from jb)), 'NOT_ALLOWED: unknown table', 'a table name with SQL in it');
select pg_temp.refused(:'oa', format('select org_export_page(%L, %s, ''org_subscriptions'', null, 10)', t.id('xa'), (select job from jb)), 'NOT_ALLOWED: unknown table', 'an excluded table (billing-provider ids)');
select pg_temp.refused(:'oa', format('select org_export_page(%L, %s, ''centre_invoice_share'', null, 10)', t.id('xa'), (select job from jb)), 'NOT_ALLOWED: unknown table', 'an excluded table (share links)');
select pg_temp.refused(:'oa', format('select org_export_page(%L, %s, ''profiles'', null, 10)', t.id('xa'), (select job from jb)), 'NOT_ALLOWED: unknown table', 'a table that is not in the catalogue');
select pg_temp.refused(:'oa', format('select org_export_page(%L, %s, ''users'', null, 10)', t.id('xa'), (select job from jb)), 'NOT_ALLOWED: unknown table', 'auth users');
-- a job number is mandatory and personal
select pg_temp.refused(:'oa', format('select org_export_page(%L, 0, ''lessons'', null, 10)', t.id('xa')), 'NOT_FOUND', 'no job at all');
select pg_temp.refused(:'oa', format('select org_export_page(%L, null, ''lessons'', null, 10)', t.id('xa')), 'NOT_FOUND', 'a null job');
select pg_temp.refused(:'stf', format('select org_export_page(%L, %s, ''lessons'', null, 10)', t.id('xa'), (select job from jb)), 'NOT_FOUND', 'staff cannot ride on the owner''s job');
select pg_temp.refused(:'ob', format('select org_export_page(%L, %s, ''lessons'', null, 10)', t.id('xa'), (select job from jb)), 'NOT_FOUND', 'another centre''s owner cannot use the job');
select pg_temp.refused(:'ob', format('select org_export_page(%L, %s, ''lessons'', null, 10)', t.id('xb'), (select job from jb)), 'NOT_FOUND', 'nor on their own centre (the job belongs to a different centre)');
select pg_temp.refused(:'oa', format('select org_export_page(%L, %s, ''lessons'', null, 10)', t.id('xa'), (select min(id) from audit_log where org_id = t.id('xa'))), 'NOT_FOUND', 'an ordinary audit row is not a job');
-- an old job (4 hours) is not accepted
insert into audit_log(org_id, actor, action, table_name, row_id, after, at) values (t.id('xa'), :'oa', 'org_export_started', 'organisations', t.id('xa')::text, '{"full_payout":false,"expected":{}}', now() - interval '4 hours');
select pg_temp.refused(:'oa', format('select org_export_page(%L, %s, ''lessons'', null, 10)', t.id('xa'), (select max(id) from audit_log where org_id = t.id('xa') and action = 'org_export_started')), 'NOT_FOUND', 'a job older than 3 hours');

-- ===================================================================== isolation: centre B's data never appears in A's export, and A's never in B's
select t.ok(not exists (select 1 from ex1 where j::text like '%B-MARKER%'), 'A''s whole export holds none of B''s marker text');
select t.ok(not exists (select 1 from ex1 where (j->'rows')::text like '%' || t.id('xb')::text || '%'), 'nor B''s organisation id');
create temp table ex2 as select pg_temp.export_all(:'ob', t.id('xb'), false, 50) j;
select t.ok((select (j->'rows')::text like '%B-MARKER Student%' and (j->'rows')::text like '%B-MARKER note%' from ex2), 'B''s own export holds B''s rows');
select t.ok(not exists (select 1 from ex2 where (j->'rows')::text ~ 'Ann O|Neil|陈|Tutor Tan|Pat Payout|LEG-1'), 'and none of A''s');
-- every centre in this database (the earlier test files built plenty, with money tables filled): the export equals the database's own count, row for row, and holds only that centre's ids
create function pg_temp.check_all() returns int language plpgsql as $$
declare o record; ex jsonb; tb record; n int := 0; got bigint; want bigint; bad bigint; ids text[];
begin
  for o in select og.id org, m.user_id usr from organisations og join memberships m on m.org_id = og.id and m.role = 'owner' and m.status = 'active'
            where og.kind = 'centre' and og.id not in (t.id('xa'), t.id('xb')) loop
    ex := pg_temp.export_all(o.usr::text, o.org, false, 40);
    for tb in select * from org_export_catalog() where mode = 'include' loop
      got := jsonb_array_length(ex->'rows'->tb.tbl);
      execute format('select count(*) from %I t where t.%I = $1%s', tb.tbl, tb.org_col, coalesce(' and (' || tb.filter || ')', '')) into want using o.org;
      if got <> want then raise exception 'FAIL: centre % table %: exported % rows, database has %', o.org, tb.tbl, got, want; end if;
      -- ids exported must all be this centre's
      if tb.key_col = 'id' and tb.key_type = 'uuid' and got > 0 then
        select array_agg(r->>0) into ids from jsonb_array_elements(ex->'rows'->tb.tbl) r;
        execute format('select count(*) from %I t where t.id::text = any ($1) and t.%I <> $2', tb.tbl, tb.org_col) into bad using ids, o.org;
        if bad > 0 then raise exception 'FAIL: centre % table %: % exported ids belong to another centre', o.org, tb.tbl, bad; end if;
      end if;
    end loop;
    n := n + 1;
  end loop;
  return n;
end $$;
select t.ok(pg_temp.check_all() >= 3, 'every other centre in the database exports exactly its own rows, table by table');

-- ===================================================================== masking, who names, scrubbing (job from ex1 is a MASKED export)
select t.ok((select r->>5 = '•••••7890' from ex1, jsonb_array_elements(j->'rows'->'tutor_payout_details') r), 'masked: the bank account is •••••7890');
select t.ok((select r->>6 = 'P•••' from ex1, jsonb_array_elements(j->'rows'->'tutor_payout_details') r), 'masked: the holder is shown as the first letter only');
select t.ok((select count(*) = 1 from ex1, jsonb_array_elements(j->'rows'->'tutor_payout_details') r), 'one current payout row (history and cleared rows are not exported)');
select t.ok(not exists (select 1 from ex1 where j::text ~ '1234567890|123-456|Pat Payout'), 'a masked export holds the full number nowhere, not even in the audit copies');
create temp table ex3 as select pg_temp.export_all(:'oa', t.id('xa'), true, 50) j;
select t.ok((select r::text like '%1234567890%' and r::text like '%Pat Payout%' from ex3, jsonb_array_elements(j->'rows'->'tutor_payout_details') r), 'unmasked (explicit tick): the full number and holder are there');
select t.ok(not exists (select 1 from ex3 where (j->'rows'->'audit_log')::text ~ '1234567890|123-456|Pat Payout'), 'even an unmasked export keeps full payout numbers out of the audit copies');
select t.ok((select count(*) = 1 from audit_log where org_id = t.id('xa') and action = 'org_export_payout_full' and actor = :'oa'), 'asking for full numbers wrote its own audit row (once)');
select t.ok(exists (select 1 from audit_log where org_id = t.id('xa') and action = 'org_export_started' and (after->>'full_payout')::boolean is true and after->>'payout_numbers' = 'full'), 'and the start row says full');
select t.ok((select r->>5 = '•••••7890' from ex1, jsonb_array_elements(j->'rows'->'tutor_payout_details') r), 'the earlier masked job stayed masked (the flag comes from its own start row)');
select t.ok(not exists (select 1 from audit_log where action = 'org_export_payout_full' and org_id = t.id('xb')), 'a masked export writes no payout-full row');
-- who → name
select t.ok(exists (select 1 from ex1, jsonb_array_elements(j->'rows'->'centre_payments') r where r::text like '%Owner Alpha%'), 'recorded_by shows the person''s name');
select t.ok(exists (select 1 from ex1, jsonb_array_elements(j->'rows'->'centre_payments') r where r::text like '%Former member%'), 'a person who has left reads "Former member"');
select t.ok(not exists (select 1 from ex1 where (j->'rows')::text like '%' || :'oa' || '%' or (j->'rows')::text like '%' || :'gone' || '%'), 'no user id appears anywhere in the export');
select t.ok(not exists (select 1 from ex1 where (j->'rows')::text ~ ('(' || :'stf' || '|' || :'tut' || '|' || :'par' || '|' || :'ob' || ')')), 'staff, tutor and parent user ids do not appear either');
-- secrets
select t.ok(not exists (select 1 from ex1 where (j->'rows')::text like '%' || t.id('xtoken')::text || '%'), 'the invoice share token is nowhere in the export (not in invoices, not in the audit copy)');
select t.ok(not exists (select 1 from ex1 where (j->'rows')::text ~* 'cus_FAKEEXPORT1|sub_FAKEEXPORT1|cus_|sub_[A-Za-z0-9]{6}'), 'Stripe ids are nowhere (not in the audit copy of the subscription row either)');
select t.ok(exists (select 1 from audit_log where org_id = t.id('xa') and (after::text like '%' || t.id('xtoken')::text || '%')), 'precondition: the raw audit log DOES contain the share token (so the scrub is what hides it)');
select t.ok(exists (select 1 from audit_log where org_id = t.id('xa') and (after::text like '%cus_FAKEEXPORT1%')), 'precondition: and the Stripe id');
select t.ok(not exists (select 1 from ex1, jsonb_array_elements(j->'rows'->'invoices') r where r::text like '%BIGHTML%'), 'legacy invoices: the large html is not exported');
select t.ok(exists (select 1 from ex1, jsonb_array_elements(j->'rows'->'invoices') r where r::text like '%LEG-1%'), 'legacy invoices: the invoice itself is');
select t.ok(not exists (select 1 from ex1 where (j->'cols')::text ~* 'token|stripe|password|hash|_enc'), 'no column name in any page looks like a secret');
select t.ok((select count(*) from ex1, jsonb_array_elements(j->'rows'->'memberships') r) = 5, 'memberships: owner, staff, tutor, parent and the disabled owner');
select t.ok(not exists (select 1 from ex1 where (j->'cols'->'memberships')::text like '%user_id%'), 'memberships carry no user id');
select t.ok(exists (select 1 from ex1, jsonb_array_elements(j->'rows'->'guardians') r where r->>4 = '+65 9123 4567'), 'guardian phone numbers are exported (the screen says so)');
select t.ok(exists (select 1 from ex1, jsonb_array_elements(j->'rows'->'students') r where r->>2 = '陈小明' or r->>3 = '陈小明'), 'Chinese names come through intact');

-- ===================================================================== finish
create temp table cnt as select jsonb_object_agg(e->>'tbl', (e->>'rows')::int) c from ex1, jsonb_array_elements(j->'start'->'tables') e;
select pg_temp.refused(:'stf', format('select org_export_finish(%L, %s, %L)', t.id('xa'), (select job from jb), (select c from cnt)), 'NOT_FOUND', 'staff cannot finish the owner''s export');
select pg_temp.refused(:'oa', format('select org_export_finish(%L, %s, ''[1,2]'')', t.id('xa'), (select job from jb)), 'NOT_ALLOWED: counts must be an object', 'counts must be an object');
select pg_temp.refused(:'oa', format('select org_export_finish(%L, %s, ''{"lessons":"7"}'')', t.id('xa'), (select job from jb)), 'NOT_ALLOWED: bad count', 'a count that is not a number');
select pg_temp.refused(:'oa', format('select org_export_finish(%L, %s, ''{"lessons":-1}'')', t.id('xa'), (select job from jb)), 'NOT_ALLOWED: bad count', 'a negative count');
select pg_temp.refused(:'oa', format('select org_export_finish(%L, %s, ''{"profiles":3}'')', t.id('xa'), (select job from jb)), 'NOT_ALLOWED: unknown table', 'a table that is not in the export');
select t.ok((pg_temp.as_user(:'oa', format('select org_export_finish(%L, %s, %L)', t.id('xa'), (select job from jb), (select c from cnt)))->>'matched')::boolean, 'finish with the right counts: matched');
select t.ok(exists (select 1 from audit_log where org_id = t.id('xa') and action = 'org_export_finished' and actor = :'oa' and (after->>'job')::bigint = (select job from jb) and (after->>'matched')::boolean and after->'counts'->>'lessons' = '7'), 'finish is audited with the counts');
select t.ok(not exists (select 1 from audit_log where action = 'org_export_finished' and (before::text || after::text) ~* '(O.Neil|Fam|Pat Payout|123-456)'), 'the finish row holds counts only');
select pg_temp.refused(:'oa', format('select org_export_finish(%L, %s, %L)', t.id('xa'), (select job from jb), (select c from cnt)), 'NOT_ALLOWED: this export has finished', 'a second finish for the same job');
select pg_temp.refused(:'oa', format('select org_export_page(%L, %s, ''lessons'', null, 10)', t.id('xa'), (select job from jb)), 'NOT_ALLOWED: this export has finished', 'paging after the job has finished');
-- counts that differ are recorded, not hidden (job 3 = the unmasked export; the browser claims 2 students instead of 3)
create temp table jb3 as select (j->>'job')::bigint job from ex3;
create temp table fin3 as select pg_temp.as_user(:'oa', format('select org_export_finish(%L, %s, %L)', t.id('xa'), (select job from jb3), (select jsonb_object_agg(e->>'tbl', (e->>'rows')::int) || '{"students": 2}'::jsonb from ex3, jsonb_array_elements(j->'start'->'tables') e))) j;
select t.ok((select not (j->>'matched')::boolean and j->'differs' = '["students"]'::jsonb from fin3), 'a count that differs from the database''s own is reported (students)');
select t.ok(exists (select 1 from audit_log where org_id = t.id('xa') and action = 'org_export_finished' and (after->>'job')::bigint = (select job from jb3) and not (after->>'matched')::boolean and (after->>'full_payout')::boolean), 'and recorded in the audit row (with the full-payout flag)');
create temp table jb4 as select (pg_temp.as_user(:'oa', format('select org_export_start(%L)', t.id('xa')))->>'job')::bigint job;
select t.ok((pg_temp.as_user(:'oa', format('select org_export_finish(%L, %s, ''{}'')', t.id('xa'), (select job from jb4)))->>'matched')::boolean is false, 'finishing with nothing written is a mismatch, not a success');

-- ===================================================================== the hourly limit (12 starts per centre per hour) and a suspended centre
select t.ok((select count(*) from audit_log where org_id = t.id('xb') and action = 'org_export_started') = 1, 'centre B has started one export so far');
do $$ declare i int; begin for i in 1..11 loop perform pg_temp.as_user('00000000-0000-0000-0000-00000000ef05', format('select org_export_start(%L)', t.id('xb'))); end loop; end $$;
select pg_temp.refused(:'ob', format('select org_export_start(%L)', t.id('xb')), 'NOT_ALLOWED: too many exports', 'the 13th start within the hour');
select t.ok(pg_temp.as_user(:'oa', format('select org_export_start(%L)', t.id('xa'))) is not null, 'the limit is per centre: A can still start');
update organisations set status = 'suspended' where id = t.id('xa');
select t.ok(pg_temp.as_user(:'oa', format('select org_export_start(%L)', t.id('xa'))) is not null, 'a suspended centre''s owner can still export their data');
update organisations set status = 'setup' where id = t.id('xa');

-- ===================================================================== nothing was changed by exporting
select t.ok((select count(*) from students where org_id = t.id('xa')) = 3 and (select count(*) from lessons where org_id = t.id('xa')) = 7, 'exporting changes no business rows');
