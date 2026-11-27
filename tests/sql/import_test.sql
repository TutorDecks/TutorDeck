-- T33 I1 tests: centre import, stage A. Runs after org_separation_test.sql in the same throwaway database (reuses t.* and Tina's solo organisation).
-- Fictional people only. Proves: owner-only (everyone else NOT_FOUND), dry run writes nothing, every validation rule returns data not exceptions,
-- the commit is exact, idempotent and all-or-nothing, undo removes only untouched rows, speed on a 400-student / 200-tutor fixture.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

-- ===================================================================== helpers
create function t.snap() returns jsonb language plpgsql as $$
declare r record; o jsonb := '{}'; n bigint;
begin
  for r in select table_name from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE' order by 1 loop
    execute format('select count(*) from public.%I', r.table_name) into n; o := o || jsonb_build_object(r.table_name, n);
  end loop; return o; end $$;
-- names of the tables whose row count differs between two snapshots
create function t.changed(a jsonb, b jsonb) returns text language sql as $$
  select coalesce(string_agg(k, ',' order by k), '') from (select k from jsonb_object_keys(a || b) k where (a->k) is distinct from (b->k)) x $$;
create function t.has_err(res jsonb, f text, code text) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(res->'errors') e where e->>'file' = f and e->>'code' = code) $$;
create function t.has_err_at(res jsonb, f text, code text, ln int) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(res->'errors') e where e->>'file' = f and e->>'code' = code and (e->>'line')::int = ln) $$;
grant execute on all functions in schema t to authenticated, service_role, anon;

-- the small valid file set used by most tests
create function t.base() returns jsonb language sql as $$ select jsonb_build_object(
  'families', jsonb_build_array(
    jsonb_build_object('line',2,'family_ref','F001','family_name','Tan family','guardian_name','Mary Tan','relation','Mother','phone','+6591234501','email','mary.tan@example.test','main',true),
    jsonb_build_object('line',3,'family_ref','F001','family_name','Tan family','guardian_name','Tom Tan','relation','Father','phone','+6591234502','main',false),
    jsonb_build_object('line',4,'family_ref','F002','family_name','Lee family','guardian_name','Sue Lee','relation','Mother','email','sue.lee@example.test')),
  'students', jsonb_build_array(
    jsonb_build_object('line',2,'student_ref','S1','family_ref','F001','student_name','Ethan Tan','level','P5','lesson_location','Online','online_link','https://meet.example.test/e1','start_date','2026-01-12','notes','Prefers mornings'),
    jsonb_build_object('line',3,'student_ref','S2','family_ref','F001','student_name','Emma Tan','level','P3','start_date','2026-02-02'),
    jsonb_build_object('line',4,'student_ref','S3','family_ref','F002','student_name','Leo Lee','level','S1','start_date','2026-03-02')),
  'tutors', jsonb_build_array(
    jsonb_build_object('line',2,'tutor_email','ava.lim@example.test','tutor_name','Ava Lim','phone','+6591000001','subjects','Maths','employment','freelancer'),
    jsonb_build_object('line',3,'tutor_email','ben.ng@example.test','tutor_name','Ben Ng','employment','employee')),
  'weekly_lessons', jsonb_build_array(
    jsonb_build_object('line',2,'student_ref','S1','tutor_email','ava.lim@example.test','day',0,'start','16:00','end','17:30','subject','Mathematics','level','P5','rate_cents',5500),
    jsonb_build_object('line',3,'student_ref','S2','tutor_email','ben.ng@example.test','day',1,'start','17:00','end','18:00','rate_cents',5000),
    jsonb_build_object('line',4,'student_ref','S3','tutor_email','ava.lim@example.test','day',0,'start','18:00','end','19:00','subject','Science','rate_cents',6000))) $$;
grant execute on function t.base() to authenticated, service_role, anon;
-- change one cell: t.setc(payload, 'students', 0, 'start_date', '"2026-02-30"')
create function t.setc(p jsonb, f text, i int, k text, v jsonb) returns jsonb language sql as $$ select jsonb_set(p, array[f, i::text, k], v) $$;
create function t.addrow(p jsonb, f text, r jsonb) returns jsonb language sql as $$ select jsonb_set(p, array[f], (p->f) || jsonb_build_array(r)) $$;
grant execute on all functions in schema t to authenticated, service_role, anon;

-- ===================================================================== people and centres
insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-0000000e0001', 'owner@imp.test'),   -- OWN: owner of the import centre
  ('00000000-0000-0000-0000-0000000e0002', 'staff@imp.test'),   -- STAFF with every permission
  ('00000000-0000-0000-0000-0000000e0003', 'tutor@imp.test'),   -- a tutor of the centre
  ('00000000-0000-0000-0000-0000000e0004', 'parent@imp.test'),  -- a parent member
  ('00000000-0000-0000-0000-0000000e0005', 'owner2@imp.test'),  -- owner of ANOTHER centre
  ('00000000-0000-0000-0000-0000000e0006', 'nobody@imp.test'),  -- not a member of anything but their own solo organisation
  ('00000000-0000-0000-0000-0000000e0007', 'accepts@imp.test'); -- a tutor who accepts an invitation later
select t.as('00000000-0000-0000-0000-0000000e0001');
select t.put('imp', org_create_centre('Import Centre', t.centre_settings()));
select t.as('00000000-0000-0000-0000-0000000e0005');
select t.put('imp2', org_create_centre('Other Centre', t.centre_settings()));
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('imp'), '00000000-0000-0000-0000-0000000e0002', 'Staff', 'staff', array['manage_timetable','manage_students','manage_tutors','issue_invoices','record_payments','view_revenue','run_tutor_pay','view_audit_log'], 'active'),
  (t.id('imp'), '00000000-0000-0000-0000-0000000e0003', 'Tutor', 'tutor', '{}', 'active'),
  (t.id('imp'), '00000000-0000-0000-0000-0000000e0004', 'Parent', 'parent', '{}', 'active');
select t.put('imp3', (select org_create_centre('Speed Centre', t.centre_settings()) from (select t.as('00000000-0000-0000-0000-0000000e0001')) _));
select t.ok(t.id('imp') is not null and t.id('imp2') is not null and t.id('imp3') is not null, 'three centres exist');
reset role;

-- ===================================================================== 1. owner only: everyone else gets NOT_FOUND, no probing
create function t.nf(q text) returns boolean language plpgsql as $$
begin execute q; return false; exception when others then return sqlerrm = 'NOT_FOUND'; end $$;
grant execute on function t.nf(text) to authenticated, service_role, anon;
create temp table callers(who text, uid text);
insert into callers values ('staff', '00000000-0000-0000-0000-0000000e0002'), ('tutor', '00000000-0000-0000-0000-0000000e0003'),
  ('parent', '00000000-0000-0000-0000-0000000e0004'), ('owner of another centre', '00000000-0000-0000-0000-0000000e0005'),
  ('someone outside', '00000000-0000-0000-0000-0000000e0006'), ('solo tutor Tina', '00000000-0000-0000-0000-0000000000a1');
grant select on callers to authenticated, anon;
do $$
declare c record; o text := t.id('imp')::text;
begin
  for c in select * from callers loop
    perform t.as(c.uid);
    set local role authenticated;
    perform t.ok(t.nf('select import_dry_run(''' || o || ''', t.base())'), c.who || ': dry run is NOT_FOUND');
    perform t.ok(t.nf('select import_commit(''' || o || ''', t.base(), ''{}'')'), c.who || ': commit is NOT_FOUND');
    perform t.ok(t.nf('select import_existing(''' || o || ''')'), c.who || ': existing codes is NOT_FOUND');
    perform t.ok(t.nf('select import_history(''' || o || ''')'), c.who || ': history is NOT_FOUND');
    reset role;
  end loop;
  -- Tina on HER OWN solo organisation: solo organisations can never import
  perform t.as('00000000-0000-0000-0000-0000000000a1'); set local role authenticated;
  perform t.ok(t.nf('select import_dry_run(''' || t.id('tina_org')::text || ''', t.base())'), 'a solo organisation (her own): dry run is NOT_FOUND');
  perform t.ok(t.nf('select import_commit(''' || t.id('tina_org')::text || ''', t.base(), ''{}'')'), 'a solo organisation (her own): commit is NOT_FOUND');
  reset role;
  -- an organisation that does not exist reads exactly the same
  perform t.as('00000000-0000-0000-0000-0000000e0001'); set local role authenticated;
  perform t.ok(t.nf('select import_dry_run(''99999999-9999-9999-9999-999999999999'', t.base())'), 'a missing organisation: the same NOT_FOUND');
  reset role;
end $$;
-- anonymous
set role anon;
select t.fails($q$ select import_dry_run(t.id('imp'), t.base()) $q$, 'anonymous dry run (no execute right)');
select t.fails($q$ select import_commit(t.id('imp'), t.base(), '{}') $q$, 'anonymous commit (no execute right)');
reset role;
select t.ok(not has_function_privilege('anon', 'public.import_commit(uuid,jsonb,jsonb)', 'execute') and not has_function_privilege('anon', 'public.import_dry_run(uuid,jsonb)', 'execute')
        and not has_function_privilege('anon', 'public.import_undo(uuid)', 'execute') and not has_function_privilege('anon', 'public.import_history(uuid)', 'execute')
        and not has_function_privilege('anon', 'public.import_existing(uuid)', 'execute') and not has_function_privilege('anon', 'public.import_undo_preview(uuid)', 'execute'), 'anonymous cannot execute any import function');
select t.ok(not has_function_privilege('authenticated', 'public.import_run_a(uuid,jsonb,boolean,jsonb)', 'execute') and not has_function_privilege('authenticated', 'public.import_undo_run(uuid,boolean)', 'execute')
        and not has_function_privilege('authenticated', 'public.import_row_exists(text,uuid)', 'execute') and not has_function_privilege('authenticated', 'public.import_fp(jsonb)', 'execute'), 'the internal functions are not callable as an API');
select t.ok(has_function_privilege('authenticated', 'public.import_commit(uuid,jsonb,jsonb)', 'execute'), 'signed-in users can call the entry points (each one checks the owner itself)');
select t.ok((select bool_and(p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path=public%') from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'import\_%' and p.proname in
            ('import_dry_run','import_commit','import_existing','import_history','import_undo','import_undo_preview','import_run_a','import_undo_run')), 'every import function is SECURITY DEFINER with a pinned search_path');

-- ===================================================================== 2. table access: the browser can write nothing, staff read nothing
select t.as('00000000-0000-0000-0000-0000000e0001'); set role authenticated;
select t.fails($q$ insert into import_batches(org_id, undo_until) values (t.id('imp'), now()) $q$, 'the owner inserting a batch row by hand');
select t.fails($q$ insert into import_items(org_id, batch_id, kind, tbl, row_id, fp) values (t.id('imp'), gen_random_uuid(), 'student', 'students', gen_random_uuid(), 'x') $q$, 'the owner inserting an item by hand');
select t.fails($q$ select count(*) from import_items $q$, 'the browser cannot read import_items at all (history goes through import_history)');
reset role;

-- ===================================================================== 3. dry run: validates, writes NOTHING
create table t.res (k text primary key, j jsonb); grant all on t.res to authenticated, service_role;
create function t.run(key text, uid text, q text) returns void language plpgsql as $$
declare o jsonb;
begin perform t.as(uid); set local role authenticated; execute q into o; reset role; insert into t.res(k, j) values (key, o) on conflict (k) do update set j = excluded.j; end $$;
grant execute on function t.run(text, text, text) to authenticated, service_role;
create function t.r(key text) returns jsonb language sql stable as $$ select j from t.res where k = key $$;
grant execute on function t.r(text) to authenticated, service_role, anon;
create temp table s0 as select t.snap() j;

select t.run('dry1', '00000000-0000-0000-0000-0000000e0001', $q$ select import_dry_run(t.id('imp'), t.base()) $q$);
select t.ok((t.r('dry1')->>'ok')::boolean and (t.r('dry1')->>'dry_run')::boolean, 'dry run of a good file says ok');
select t.ok(t.r('dry1')->'created' = '{"families":2,"guardians":3,"students":3,"tutors":2,"weekly_lessons":3}'::jsonb, 'dry run reports what would be created: 2 families, 3 guardians, 3 students, 2 tutors, 3 weekly lessons');
select t.ok(t.changed((select j from s0), t.snap()) = '', 'dry run wrote nothing (every table has the same row count, audit log included)');
select t.ok(t.r('dry1')->>'batch_id' is null, 'no batch recorded');

-- ===================================================================== 4. validation: every rule answers as DATA with file, line, column and code, never a value
create function t.v(p jsonb) returns jsonb language plpgsql as $$
declare o jsonb;
begin perform t.as('00000000-0000-0000-0000-0000000e0001'); set local role authenticated; o := import_dry_run(t.id('imp'), p); reset role; return o; end $$;
grant execute on function t.v(jsonb) to authenticated, service_role;
create temp table cases(n serial, name text, payload jsonb, file text, code text);
insert into cases(name, payload, file, code) values
  ('family_ref empty',            t.setc(t.base(), 'families', 0, 'family_ref', '""'), 'families', 'REQUIRED'),
  ('family_ref 41 characters',    t.setc(t.base(), 'families', 2, 'family_ref', to_jsonb(repeat('x', 41))), 'families', 'TOO_LONG'),
  ('family_name 121 characters',  t.setc(t.base(), 'families', 2, 'family_name', to_jsonb(repeat('x', 121))), 'families', 'TOO_LONG'),
  ('family name differs in family', t.setc(t.base(), 'families', 1, 'family_name', '"Tan household"'), 'families', 'FAMILY_NAME_MISMATCH'),
  ('guardian phone letters',      t.setc(t.base(), 'families', 0, 'phone', '"98ab"'), 'families', 'BAD_PHONE'),
  ('guardian email bad',          t.setc(t.base(), 'families', 0, 'email', '"mary at example"'), 'families', 'BAD_EMAIL'),
  ('guardian with no contact',    t.setc(t.setc(t.base(), 'families', 2, 'email', 'null'), 'families', 2, 'phone', 'null'), 'families', 'NEED_CONTACT'),
  ('two main guardians',          t.setc(t.base(), 'families', 1, 'main', 'true'), 'families', 'MULTIPLE_MAIN'),
  ('duplicate guardian row',      t.addrow(t.base(), 'families', '{"line":5,"family_ref":"F002","family_name":"Lee family","guardian_name":"Sue Lee","email":"sue.lee@example.test"}'), 'families', 'DUPLICATE_ROW'),
  ('seventh guardian',            (select jsonb_set(t.base(), '{families}', (t.base()->'families') || (select jsonb_agg(jsonb_build_object('line', 10+g, 'family_ref','F001','family_name','Tan family','guardian_name','G'||g,'phone','+659123450'||g)) from generate_series(3, 7) g))), 'families', 'TOO_MANY_GUARDIANS'),
  ('student_ref empty',           t.setc(t.base(), 'students', 0, 'student_ref', '""'), 'students', 'REQUIRED'),
  ('student duplicate ref',       t.setc(t.base(), 'students', 1, 'student_ref', '"s1"'), 'students', 'DUPLICATE_KEY'),
  ('student family unknown',      t.setc(t.base(), 'students', 0, 'family_ref', '"F999"'), 'students', 'UNKNOWN_FAMILY'),
  ('student link is http',        t.setc(t.base(), 'students', 0, 'online_link', '"http://meet.example.test/x"'), 'students', 'BAD_URL'),
  ('start date 30 February',      t.setc(t.base(), 'students', 0, 'start_date', '"2026-02-30"'), 'students', 'BAD_DATE'),
  ('start date empty',            t.setc(t.base(), 'students', 0, 'start_date', 'null'), 'students', 'REQUIRED'),
  ('start date two years ahead',  t.setc(t.base(), 'students', 0, 'start_date', to_jsonb((current_date + 800)::text)), 'students', 'FUTURE_DATE'),
  ('notes 1001 characters',       t.setc(t.base(), 'students', 0, 'notes', to_jsonb(repeat('n', 1001))), 'students', 'TOO_LONG'),
  ('same child name in a family', t.setc(t.base(), 'students', 1, 'student_name', '"ethan tan"'), 'students', 'DUPLICATE_STUDENT_NAME'),
  ('tutor email bad',             t.setc(t.base(), 'tutors', 0, 'tutor_email', '"ava.example.test"'), 'tutors', 'BAD_EMAIL'),
  ('tutor employment bad',        t.setc(t.base(), 'tutors', 0, 'employment', '"volunteer"'), 'tutors', 'BAD_VALUE'),
  ('tutor employment empty',      t.setc(t.base(), 'tutors', 0, 'employment', 'null'), 'tutors', 'REQUIRED'),
  ('tutor phone not Singapore',   t.setc(t.base(), 'tutors', 0, 'phone', '"+6551234567"'), 'tutors', 'BAD_PHONE'),
  ('tutor email twice',           t.setc(t.base(), 'tutors', 1, 'tutor_email', '"AVA.LIM@example.test"'), 'tutors', 'DUPLICATE_KEY'),
  ('tutor is the owner',          t.setc(t.base(), 'tutors', 1, 'tutor_email', '"owner@imp.test"'), 'tutors', 'TUTOR_OTHER_ROLE'),
  ('tutor is the staff member',   t.setc(t.base(), 'tutors', 1, 'tutor_email', '"staff@imp.test"'), 'tutors', 'TUTOR_OTHER_ROLE'),
  ('weekly: unknown student',     t.setc(t.base(), 'weekly_lessons', 0, 'student_ref', '"S99"'), 'weekly_lessons', 'UNKNOWN_STUDENT'),
  ('weekly: unknown tutor',       t.setc(t.base(), 'weekly_lessons', 0, 'tutor_email', '"zed@example.test"'), 'weekly_lessons', 'UNKNOWN_TUTOR'),
  ('weekly: day 7',               t.setc(t.base(), 'weekly_lessons', 0, 'day', '7'), 'weekly_lessons', 'BAD_VALUE'),
  ('weekly: start 25:00',         t.setc(t.base(), 'weekly_lessons', 0, 'start', '"25:00"'), 'weekly_lessons', 'BAD_TIME'),
  ('weekly: end before start',    t.setc(t.base(), 'weekly_lessons', 0, 'end', '"15:00"'), 'weekly_lessons', 'END_BEFORE_START'),
  ('weekly: 14 minutes',          t.setc(t.base(), 'weekly_lessons', 0, 'end', '"16:14"'), 'weekly_lessons', 'BAD_DURATION'),
  ('weekly: 481 minutes',         t.setc(t.base(), 'weekly_lessons', 0, 'end', '"24:00"'), 'weekly_lessons', 'BAD_TIME'),
  ('weekly: 481 minutes (08:00-16:01)', t.setc(t.setc(t.base(), 'weekly_lessons', 0, 'start', '"08:00"'), 'weekly_lessons', 0, 'end', '"16:01"'), 'weekly_lessons', 'BAD_DURATION'),
  ('weekly: rate -1',             t.setc(t.base(), 'weekly_lessons', 0, 'rate_cents', '-1'), 'weekly_lessons', 'OUT_OF_RANGE'),
  ('weekly: rate 1000.01',        t.setc(t.base(), 'weekly_lessons', 0, 'rate_cents', '100001'), 'weekly_lessons', 'OUT_OF_RANGE'),
  ('weekly: rate empty',          t.setc(t.base(), 'weekly_lessons', 0, 'rate_cents', 'null'), 'weekly_lessons', 'REQUIRED'),
  ('weekly: subject 61 characters', t.setc(t.base(), 'weekly_lessons', 0, 'subject', to_jsonb(repeat('s', 61))), 'weekly_lessons', 'TOO_LONG'),
  ('weekly: same lesson twice',   t.addrow(t.base(), 'weekly_lessons', '{"line":5,"student_ref":"S1","tutor_email":"ava.lim@example.test","day":0,"start":"16:00","end":"17:00","rate_cents":100}'), 'weekly_lessons', 'DUPLICATE_KEY'),
  ('weekly: student clash',       t.addrow(t.base(), 'weekly_lessons', '{"line":5,"student_ref":"S1","tutor_email":"ben.ng@example.test","day":0,"start":"17:00","end":"18:00","rate_cents":100}'), 'weekly_lessons', 'SLOT_CLASH');
do $$
declare c record; o jsonb;
begin
  for c in select * from cases order by n loop
    o := t.v(c.payload);
    perform t.ok(not (o->>'ok')::boolean and t.has_err(o, c.file, c.code), 'rejected as data: ' || c.name || ' → ' || c.file || ' ' || c.code);
  end loop;
end $$;
-- boundaries that must PASS
create temp table okcases(n serial, name text, payload jsonb);
insert into okcases(name, payload) values
  ('family_ref exactly 40 characters', t.setc(t.setc(t.base(), 'families', 2, 'family_ref', to_jsonb(repeat('x', 40))), 'students', 2, 'family_ref', to_jsonb(repeat('x', 40)))),
  ('family_name exactly 120 characters', t.setc(t.base(), 'families', 2, 'family_name', to_jsonb(repeat('x', 120)))),
  ('notes exactly 1000 characters', t.setc(t.base(), 'students', 0, 'notes', to_jsonb(repeat('n', 1000)))),
  ('lesson of exactly 15 minutes', t.setc(t.base(), 'weekly_lessons', 0, 'end', '"16:15"')),
  ('lesson of exactly 480 minutes', t.setc(t.setc(t.base(), 'weekly_lessons', 0, 'start', '"08:00"'), 'weekly_lessons', 0, 'end', '"16:00"')),
  ('rate of exactly 0', t.setc(t.base(), 'weekly_lessons', 0, 'rate_cents', '0')),
  ('rate of exactly 1000.00', t.setc(t.base(), 'weekly_lessons', 0, 'rate_cents', '100000')),
  ('two lessons back to back (no overlap)', t.addrow(t.base(), 'weekly_lessons', '{"line":5,"student_ref":"S1","tutor_email":"ben.ng@example.test","day":0,"start":"17:30","end":"18:30","rate_cents":100}')),
  ('a tutor double-booked is only a warning in the page', t.addrow(t.base(), 'weekly_lessons', '{"line":5,"student_ref":"S2","tutor_email":"ava.lim@example.test","day":0,"start":"16:30","end":"17:00","rate_cents":100}')),
  ('no phone but an email', t.setc(t.base(), 'families', 0, 'phone', 'null')),
  ('no files at all', '{}'::jsonb);
do $$
declare c record; o jsonb;
begin
  for c in select * from okcases order by n loop
    o := t.v(c.payload);
    perform t.ok((o->>'ok')::boolean, 'accepted: ' || c.name);
  end loop;
end $$;
select t.ok(not (t.v('[]'::jsonb)->>'ok')::boolean and t.has_err(t.v('[]'::jsonb), 'payload', 'BAD_PAYLOAD'), 'a payload that is not an object is refused as data');
select t.ok(not (t.v('{"students":[{"line":"two"}]}'::jsonb)->>'ok')::boolean and t.has_err(t.v('{"students":[{"line":"two"}]}'::jsonb), 'payload', 'BAD_PAYLOAD'), 'a payload of the wrong shape is refused as data');
select t.ok(t.has_err(t.v(jsonb_build_object('students', (select jsonb_agg(jsonb_build_object('line', g, 'student_ref', 's'||g)) from generate_series(1, 3001) g))), 'payload', 'TOO_MANY_ROWS'), '3,001 students is over the limit (3,000)');
-- errors carry file, line, column and code only: never a cell value (so none can reach a log)
select t.ok(not exists (select 1 from jsonb_array_elements(t.v(t.setc(t.setc(t.base(), 'families', 0, 'phone', '"SECRETVALUE"'), 'students', 0, 'student_name', to_jsonb(repeat('Z', 130))))->'errors') e
                         where (select count(*) from jsonb_object_keys(e)) <> 4 or e::text like '%SECRET%' or e::text like '%ZZZZ%'), 'an error holds only file, line, column and code (no cell text)');
select t.ok(t.has_err_at(t.v(t.setc(t.base(), 'students', 1, 'start_date', '"2026-02-30"')), 'students', 'BAD_DATE', 3), 'the line number of the file row comes back');
select t.ok((select count(*) from (select 1 from jsonb_array_elements(t.v((select jsonb_build_object('students', jsonb_agg(jsonb_build_object('line', g)))  from generate_series(1, 2000) g))->'errors')) x) <= 300, 'at most 300 errors are returned');
select t.ok((t.v((select jsonb_build_object('students', jsonb_agg(jsonb_build_object('line', g))) from generate_series(1, 2000) g))->>'error_count')::int > 300, 'the full error count is still reported');
select t.ok(t.changed((select j from s0), t.snap()) = '', 'validation, good or bad, still wrote nothing');

-- ===================================================================== 5. commit: exact, one batch, one audit row, nothing else touched
create function t.delta(a jsonb, b jsonb, tbl text) returns int language sql as $$ select ((b->>tbl)::int - (a->>tbl)::int) $$;
grant execute on function t.delta(jsonb, jsonb, text) to authenticated, service_role, anon;
create temp table s1 as select t.snap() j;
select t.run('c1', '00000000-0000-0000-0000-0000000e0001', $q$ select import_commit(t.id('imp'), t.base(), '{"families.csv":"aaaa1111","students.csv":"bbbb2222"}') $q$);
create temp table s2 as select t.snap() j;
select t.ok((t.r('c1')->>'ok')::boolean and not (t.r('c1')->>'dry_run')::boolean and t.r('c1')->>'batch_id' is not null, 'commit of the good file succeeded and returned a batch id');
select t.ok(t.r('c1')->'created' = '{"families":2,"guardians":3,"students":3,"tutors":2,"weekly_lessons":3}'::jsonb, 'exact counts created: 2 families, 3 guardians, 3 students, 2 tutors, 3 weekly lessons');
select t.ok(t.changed((select j from s1), (select j from s2)) = 'audit_log,guardians,households,import_batches,import_items,memberships,recurring_slots,students',
            'only the expected tables changed: no lessons, invoices, queue or mail rows (changed: ' || t.changed((select j from s1), (select j from s2)) || ')');
select t.eq(t.delta((select j from s1), (select j from s2), 'households'), 2, 'households +2');
select t.eq(t.delta((select j from s1), (select j from s2), 'guardians'), 3, 'guardians +3');
select t.eq(t.delta((select j from s1), (select j from s2), 'students'), 3, 'students +3');
select t.eq(t.delta((select j from s1), (select j from s2), 'memberships'), 2, 'memberships +2 (the two invited tutors)');
select t.eq(t.delta((select j from s1), (select j from s2), 'recurring_slots'), 3, 'weekly lessons +3');
select t.eq(t.delta((select j from s1), (select j from s2), 'lessons'), 0, 'no lessons created (they come from the usual generation)');
select t.eq(t.delta((select j from s1), (select j from s2), 'import_batches'), 1, 'one batch row');
select t.eq(t.delta((select j from s1), (select j from s2), 'import_items'), 13, 'thirteen items: 2 families, 3 guardians, 3 students, 2 tutors, 3 weekly lessons');
select t.eq(t.delta((select j from s1), (select j from s2), 'audit_log'), 1, 'ONE audit row for the whole batch (not one per row)');
select t.ok((select a.action = 'import_commit' and a.actor = '00000000-0000-0000-0000-0000000e0001' and a.org_id = t.id('imp') and a.after#>>'{files,students.csv}' = 'bbbb2222'
              and a.after#>'{created,students}' = '3' from audit_log a where a.action = 'import_commit' and a.org_id = t.id('imp')), 'the audit row: who, which centre, counts and the file hashes');
select t.ok((select count(*) = 0 from audit_log where action in ('import_commit', 'import_undo') and after::text ~* 'Tan|Lee|Ava|Ben|example\.test|Ethan'), 'the audit rows hold no names, emails or cell values');
select t.ok((select b.created_by = '00000000-0000-0000-0000-0000000e0001' and b.org_id = t.id('imp') and b.status = 'committed' and b.stage = 'A' and b.file_hashes->>'families.csv' = 'aaaa1111'
              and b.undo_until between now() + interval '6 days 23 hours' and now() + interval '7 days 1 hour' from import_batches b where b.id = (t.r('c1')->>'batch_id')::uuid), 'the batch: owner, centre, committed, file hashes, undo open for 7 days');
-- what the rows look like
select t.ok((select s.tutor_id = '00000000-0000-0000-0000-0000000e0001' and s.org_id = t.id('imp') and s.contact = '+6591234501' and s.recipient_name = 'Mary Tan' and s.location = 'Online'
              and s.online_link = 'https://meet.example.test/e1' and s.start_date = '2026-01-12' and s.notes = 'Prefers mornings' and s.level = 'P5' and s.active
              and s.household_id = (select household_id from students where name = 'Emma Tan' and org_id = t.id('imp')) from students s where s.name = 'Ethan Tan' and s.org_id = t.id('imp')),
            'a student: filed under the owner, contact = the main guardian, link, location, start date, notes, sibling in the same household');
select t.ok((select s.contact is null and s.recipient_name = 'Sue Lee' from students s where s.name = 'Leo Lee' and s.org_id = t.id('imp')), 'a family whose guardian has only an email: no phone copied, name kept');
select t.ok((select h.name = 'Tan family' and h.phone_key = '91234501' from households h where h.org_id = t.id('imp') and h.name = 'Tan family'), 'household named by the file, phone key from the main guardian');
select t.ok((select count(*) = 2 and bool_and(g.org_id = t.id('imp')) from guardians g where g.household_id = (select id from households where org_id = t.id('imp') and name = 'Tan family')), 'two guardians in the Tan family');
select t.ok((select m.role = 'tutor' and m.status = 'invited' and m.user_id is null and m.employment_type = 'freelancer' and m.display_name = 'Ava Lim' and m.permissions = '{}'
              from memberships m where m.org_id = t.id('imp') and m.invited_email = 'ava.lim@example.test'), 'a tutor is an INVITATION: role tutor, status invited, no login, employment kept');
select t.ok((select x.weekday = 0 and x.start_time = '16:00' and x.end_time = '17:30' and x.rate = 55.00 and x.rate_cents = 5500 and x.subject = 'Mathematics' and x.level = 'P5' and x.active
              and x.tutor_id = '00000000-0000-0000-0000-0000000e0001' and x.taught_by = (select id from memberships where org_id = t.id('imp') and invited_email = 'ava.lim@example.test')
              from recurring_slots x join students s on s.id = x.student_id where s.name = 'Ethan Tan' and s.org_id = t.id('imp')), 'a weekly lesson: Monday 16:00-17:30, S$55.00, its tutor and level');
select t.ok((select x.level = 'P3' and x.subject is null and x.rate = 50 from recurring_slots x join students s on s.id = x.student_id where s.name = 'Emma Tan' and s.org_id = t.id('imp')), 'a weekly lesson with no level takes the student''s level');
-- tutors still have no table access (an invited tutor has no login at all; a signed-in tutor of the centre reads nothing)
select t.as('00000000-0000-0000-0000-0000000e0003'); set role authenticated;
select t.eq((select count(*) from students), 0, 'a tutor of the centre still sees no students');
select t.eq((select count(*) from recurring_slots), 0, 'a tutor of the centre still sees no weekly lessons');
reset role;
-- the owner reads history; staff do not
select t.run('h1', '00000000-0000-0000-0000-0000000e0001', $q$ select import_history(t.id('imp')) $q$);
select t.ok(jsonb_array_length(t.r('h1')) = 1 and t.r('h1')->0->>'status' = 'committed' and (t.r('h1')->0->>'can_undo')::boolean, 'history: one committed batch that can be undone');
select t.run('e1', '00000000-0000-0000-0000-0000000e0001', $q$ select import_existing(t.id('imp')) $q$);
select t.ok(t.r('e1')->'families' = '["f001","f002"]'::jsonb and t.r('e1')->'students' = '["s1","s2","s3"]'::jsonb and t.r('e1')->'tutors' @> '["ava.lim@example.test","ben.ng@example.test"]'::jsonb, 'import_existing lists the owner''s codes (lowercase) for the page''s own checks');
select t.as('00000000-0000-0000-0000-0000000e0002'); set role authenticated;
select t.eq((select count(*) from import_batches), 0, 'staff cannot read the batch table');
reset role;
select t.as('00000000-0000-0000-0000-0000000e0001'); set role authenticated;
select t.eq((select count(*) from import_batches), 1, 'the owner can read the batch table');
reset role;

-- ===================================================================== 6. the same file again: nothing created, no new batch, no audit row
create temp table s3 as select t.snap() j;
select t.run('c2', '00000000-0000-0000-0000-0000000e0001', $q$ select import_commit(t.id('imp'), t.base(), '{}') $q$);
select t.ok((t.r('c2')->>'ok')::boolean and t.r('c2')->'created' = '{"families":0,"guardians":0,"students":0,"tutors":0,"weekly_lessons":0}'::jsonb, 'second run of the same file creates nothing');
select t.ok(t.r('c2')->'skipped' = '{"families":2,"guardians":3,"students":3,"tutors":2,"weekly_lessons":3}'::jsonb and t.r('c2')->>'batch_id' is null, 'everything was skipped, and no batch is recorded');
select t.ok(t.changed((select j from s3), t.snap()) = '', 'second run changed no table at all');
-- codes are matched ignoring case and spaces around them
select t.run('c3', '00000000-0000-0000-0000-0000000e0001', format($q$ select import_commit(t.id('imp'), %L::jsonb, '{}') $q$,
  t.setc(t.setc(t.setc(t.base(), 'students', 0, 'student_ref', '"  s1 "'), 'weekly_lessons', 0, 'student_ref', '"S1"'), 'families', 0, 'family_ref', '"f001"')::text));
select t.ok(t.r('c3')->'created' = '{"families":0,"guardians":0,"students":0,"tutors":0,"weekly_lessons":0}'::jsonb, 'codes are matched without regard to case or spaces');

-- ===================================================================== 7. a corrected file adds only what is new, and child rows can join existing parents
create function t.more() returns jsonb language sql as $$ select jsonb_build_object(
  'students', jsonb_build_array(jsonb_build_object('line',2,'student_ref','S4','family_ref','F001','student_name','Ella Tan','level','P1','start_date','2026-04-06')),
  'weekly_lessons', jsonb_build_array(
    jsonb_build_object('line',2,'student_ref','S4','tutor_email','ava.lim@example.test','day',2,'start','15:00','end','16:00','rate_cents',4500),
    jsonb_build_object('line',3,'student_ref','S1','tutor_email','ben.ng@example.test','day',4,'start','15:00','end','16:00','rate_cents',5500))) $$;
grant execute on function t.more() to authenticated, service_role, anon;
select t.run('c4', '00000000-0000-0000-0000-0000000e0001', $q$ select import_commit(t.id('imp'), t.more(), '{}') $q$);
select t.ok((t.r('c4')->>'ok')::boolean and t.r('c4')->'created' = '{"families":0,"guardians":0,"students":1,"tutors":0,"weekly_lessons":2}'::jsonb, 'a second file with 1 new student and 2 new weekly lessons creates exactly those');
select t.ok((select s.household_id = (select household_id from students where name = 'Ethan Tan' and org_id = t.id('imp')) and s.contact = '+6591234501' and s.recipient_name = 'Mary Tan'
              from students s where s.name = 'Ella Tan' and s.org_id = t.id('imp')), 'the new student joined the EXISTING family (found by its code in the earlier import), with the main guardian as contact');
select t.ok((select x.taught_by = (select id from memberships where org_id = t.id('imp') and invited_email = 'ben.ng@example.test') from recurring_slots x join students s on s.id = x.student_id
              where s.name = 'Ethan Tan' and x.weekday = 4), 'the weekly lesson was given to an EXISTING invited tutor, found by email');
select t.ok((select count(*) = 2 from import_batches where org_id = t.id('imp')), 'two batches now');

-- ===================================================================== 8. content that differs is skipped with a warning; nothing is ever overwritten
select t.run('d1', '00000000-0000-0000-0000-0000000e0001', format($q$ select import_commit(t.id('imp'), %L::jsonb, '{}') $q$,
  t.setc(t.setc(t.base(), 'students', 0, 'level', '"P6"'), 'weekly_lessons', 1, 'rate_cents', '5600')::text));
select t.ok((t.r('d1')->>'ok')::boolean and t.r('d1')->'created' = '{"families":0,"guardians":0,"students":0,"tutors":0,"weekly_lessons":0}'::jsonb, 'a changed copy of existing rows creates nothing');
select t.ok(t.r('d1')->'warnings' @> '[{"file":"students","line":2,"code":"DIFFERS"}]'::jsonb and t.r('d1')->'warnings' @> '[{"file":"weekly_lessons","line":3,"code":"DIFFERS"}]'::jsonb, 'the owner is warned which lines differ (student line 2, weekly lesson line 3)');
select t.ok((select level = 'P5' from students where name = 'Ethan Tan' and org_id = t.id('imp')) and (select x.rate = 50 from recurring_slots x join students s on s.id = x.student_id where s.name = 'Emma Tan' and s.org_id = t.id('imp')), 'the existing rows were NOT overwritten');

-- ===================================================================== 9. bad references and clashes against what already exists
select t.ok(t.has_err(t.v(jsonb_build_object('weekly_lessons', jsonb_build_array('{"line":2,"student_ref":"S1","tutor_email":"ava.lim@example.test","day":0,"start":"17:00","end":"18:00","rate_cents":100}'::jsonb))), 'weekly_lessons', 'SLOT_CLASH'),
            'a new weekly lesson that overlaps an existing one of the same student is refused');
select t.ok((t.v(jsonb_build_object('weekly_lessons', jsonb_build_array('{"line":2,"student_ref":"S1","tutor_email":"ava.lim@example.test","day":0,"start":"16:00","end":"17:30","rate_cents":5500}'::jsonb)))->>'ok')::boolean, 'the SAME weekly lesson again is not a clash with itself (it is skipped)');
select t.ok(t.has_err(t.v(jsonb_build_object('weekly_lessons', jsonb_build_array('{"line":2,"student_ref":"S1","tutor_email":"ava.lim@example.test","day":0,"start":"16:30","end":"17:00","rate_cents":5500}'::jsonb))), 'weekly_lessons', 'SLOT_CLASH'), 'a lesson inside an existing one is a clash');
-- another centre cannot see this centre's codes
select t.as('00000000-0000-0000-0000-0000000e0005'); set role authenticated;
select t.ok(t.has_err(import_dry_run(t.id('imp2'), jsonb_build_object('weekly_lessons', jsonb_build_array('{"line":2,"student_ref":"S1","tutor_email":"ava.lim@example.test","day":0,"start":"16:00","end":"17:30","rate_cents":5500}'::jsonb))), 'weekly_lessons', 'UNKNOWN_STUDENT'), 'a student code from ANOTHER centre is unknown here');
select t.ok(t.has_err(import_dry_run(t.id('imp2'), jsonb_build_object('students', jsonb_build_array('{"line":2,"student_ref":"X1","family_ref":"F001","student_name":"Z","start_date":"2026-01-01"}'::jsonb))), 'students', 'UNKNOWN_FAMILY'), 'a family code from ANOTHER centre is unknown here');
reset role;
-- a disabled tutor cannot be given lessons
update memberships set status = 'disabled' where org_id = t.id('imp') and invited_email = 'ben.ng@example.test';
select t.ok(t.has_err(t.v(jsonb_build_object('weekly_lessons', jsonb_build_array('{"line":2,"student_ref":"S3","tutor_email":"ben.ng@example.test","day":3,"start":"10:00","end":"11:00","rate_cents":100}'::jsonb))), 'weekly_lessons', 'TUTOR_NOT_AVAILABLE'), 'a disabled tutor cannot be given a weekly lesson');
update memberships set status = 'invited' where org_id = t.id('imp') and invited_email = 'ben.ng@example.test';

-- ===================================================================== 10. all or nothing: a failure part-way through leaves ZERO rows
create function pg_temp_boom() returns trigger language plpgsql as $$ begin if new.subject = 'BOOM' then raise exception 'injected failure'; end if; return new; end $$;
create trigger boom before insert on public.recurring_slots for each row execute function pg_temp_boom();
create function t.big() returns jsonb language sql as $$ select jsonb_build_object(
  'families', jsonb_build_array(jsonb_build_object('line',2,'family_ref','F9','family_name','Ng family','guardian_name','Pat Ng','phone','+6591234599')),
  'students', jsonb_build_array(jsonb_build_object('line',2,'student_ref','S9','family_ref','F9','student_name','Nora Ng','start_date','2026-05-04')),
  'tutors', jsonb_build_array(jsonb_build_object('line',2,'tutor_email','zed@example.test','tutor_name','Zed Zhou','employment','employee')),
  'weekly_lessons', jsonb_build_array(
    jsonb_build_object('line',2,'student_ref','S9','tutor_email','zed@example.test','day',0,'start','10:00','end','11:00','rate_cents',100),
    jsonb_build_object('line',3,'student_ref','S9','tutor_email','zed@example.test','day',1,'start','10:00','end','11:00','rate_cents',100),
    jsonb_build_object('line',4,'student_ref','S9','tutor_email','zed@example.test','day',2,'start','10:00','end','11:00','subject','BOOM','rate_cents',100))) $$;
grant execute on function t.big() to authenticated, service_role, anon;
create temp table s4 as select t.snap() j;
select t.as('00000000-0000-0000-0000-0000000e0001'); set role authenticated;
select t.fails($q$ select import_commit(t.id('imp'), t.big(), '{}') $q$, 'a failure at the third weekly lesson');
reset role;
select t.ok(t.changed((select j from s4), t.snap()) = '', 'the failed commit left NOTHING behind: not the family, the student, the tutor, the two slots that went in first, the batch or the audit row');
select t.ok(not exists (select 1 from households where name = 'Ng family') and not exists (select 1 from memberships where invited_email = 'zed@example.test'), 'no half-imported family or tutor');
drop trigger boom on public.recurring_slots; drop function pg_temp_boom();
select t.run('b1', '00000000-0000-0000-0000-0000000e0001', $q$ select import_commit(t.id('imp'), (select jsonb_set(t.big(), '{weekly_lessons,2,subject}', '"Science"')), '{}') $q$);
select t.ok((t.r('b1')->>'ok')::boolean and (t.r('b1')->'created'->>'weekly_lessons')::int = 3, 'the same file succeeds once the cause is gone (nothing was left in the way)');

-- ===================================================================== 11. undo WITH later edits: only untouched rows go, the rest stay and are reported
select t.put('b1id', (select id from import_batches where org_id = t.id('imp') order by created_at limit 1));
-- people use the app after the import:
update students set level = 'P4' where name = 'Emma Tan' and org_id = t.id('imp');                                               -- EDITED
insert into lessons(tutor_id, org_id, student_id, slot_id, lesson_date, start_time, end_time, rate, amount, status, attendance, taught_by)   -- a marked lesson: ACTIVITY
  select '00000000-0000-0000-0000-0000000e0001', t.id('imp'), s.id, x.id, current_date, '16:00', '17:30', 55, 82.5, 'scheduled', 'attended', x.taught_by
  from students s join recurring_slots x on x.student_id = s.id where s.name = 'Ethan Tan' and s.org_id = t.id('imp') and x.weekday = 0;
insert into lessons(tutor_id, org_id, student_id, slot_id, lesson_date, start_time, end_time, rate, amount, status)                       -- an untouched generated lesson: goes with its slot
  select '00000000-0000-0000-0000-0000000e0001', t.id('imp'), s.id, x.id, current_date + 7, '18:00', '19:00', 60, 60, 'scheduled'
  from students s join recurring_slots x on x.student_id = s.id where s.name = 'Leo Lee' and s.org_id = t.id('imp');
update memberships set user_id = '00000000-0000-0000-0000-0000000e0007', status = 'active' where org_id = t.id('imp') and invited_email = 'ben.ng@example.test';   -- ACCEPTED
insert into guardians(org_id, household_id, name, phone) select t.id('imp'), id, 'Added By Staff', '+6591110000' from households where org_id = t.id('imp') and name = 'Lee family';   -- family edited
create temp table s5 as select t.snap() j;
select t.run('up1', '00000000-0000-0000-0000-0000000e0001', $q$ select import_undo_preview(t.id('b1id')) $q$);
select t.ok((t.r('up1')->>'ok')::boolean and (t.r('up1')->>'preview')::boolean, 'undo preview answers');
select t.ok(t.r('up1')->'would_delete' = '{"students":1,"recurring_slots":1}'::jsonb, 'preview: only Leo and his weekly lesson can go (would delete: ' || (t.r('up1')->'would_delete')::text || ')');
select t.ok(t.changed((select j from s5), t.snap()) = '', 'the preview deleted nothing');
select t.ok(t.r('up1')->'kept' @> '[{"type":"student","code":"s1","reason":"ACTIVITY"}]'::jsonb, 'kept: Ethan, because a lesson of his was marked');
select t.ok(t.r('up1')->'kept' @> '[{"type":"student","code":"s2","reason":"EDITED"}]'::jsonb, 'kept: Emma, because her record was edited');
select t.ok(t.r('up1')->'kept' @> '[{"type":"tutor","code":"ben.ng@example.test","reason":"ACCEPTED"}]'::jsonb, 'kept: Ben, who accepted his invitation (he has a login now)');
select t.ok(t.r('up1')->'kept' @> '[{"type":"tutor","code":"ava.lim@example.test","reason":"IN_USE"}]'::jsonb, 'kept: Ava, because Ethan''s weekly lesson with her stays');
select t.ok(t.r('up1')->'kept' @> '[{"type":"family","code":"f001","reason":"IN_USE"}]'::jsonb and t.r('up1')->'kept' @> '[{"type":"family","code":"f002","reason":"EDITED"}]'::jsonb, 'kept: the Tan family (students stay in it) and the Lee family (a guardian was added by hand)');
select t.ok(t.r('up1')->'kept' @> '[{"type":"slot"}]'::jsonb and (t.r('up1')->>'kept_count')::int = 11, 'eleven of the thirteen records are kept and listed');
select t.run('u1', '00000000-0000-0000-0000-0000000e0001', $q$ select import_undo(t.id('b1id')) $q$);
select t.ok((t.r('u1')->>'ok')::boolean and t.r('u1')->>'status' = 'partly_undone' and (t.r('u1')->>'kept_count')::int = 11 and t.r('u1')->'deleted' = '{"students":1,"recurring_slots":1}'::jsonb, 'undo removed exactly Leo and his weekly lesson, kept 11, status partly_undone');
select t.ok(not exists (select 1 from students where name = 'Leo Lee' and org_id = t.id('imp')) and exists (select 1 from students where name in ('Ethan Tan', 'Emma Tan') and org_id = t.id('imp') having count(*) = 2), 'Leo is gone, Ethan and Emma are still there');
select t.ok((select level = 'P4' from students where name = 'Emma Tan' and org_id = t.id('imp')), 'the staff edit survived the undo');
select t.eq((select count(*) from lessons where org_id = t.id('imp')), 1, 'the marked lesson stays; Leo''s untouched generated lesson went with his weekly lesson');
select t.eq((select count(*) from memberships where org_id = t.id('imp') and invited_email = 'ben.ng@example.test' and user_id is not null), 1, 'the tutor who accepted is untouched');
select t.eq((select count(*) from guardians where org_id = t.id('imp') and name = 'Added By Staff'), 1, 'the guardian added by hand is untouched');
select t.ok((select status = 'partly_undone' and undone_at is null and undo_report->>'kept_count' = '11' from import_batches where id = t.id('b1id')), 'the batch says partly undone and keeps the report of what was left');
select t.ok((select count(*) = 11 and bool_and(kept_reason is not null) from import_items where batch_id = t.id('b1id')), 'kept rows keep their codes (with the reason), deleted rows'' codes are free again');
select t.ok((select count(*) = 1 from audit_log where action = 'import_undo' and org_id = t.id('imp') and after->>'kept_count' = '11'), 'ONE audit row for the undo, with counts only');
select t.run('u1b', '00000000-0000-0000-0000-0000000e0001', $q$ select import_undo(t.id('b1id')) $q$);
select t.ok((t.r('u1b')->>'ok')::boolean and t.r('u1b')->'deleted' = '{}'::jsonb and (t.r('u1b')->>'kept_count')::int = 11, 'undoing again deletes nothing more');
-- importing the same file again re-creates only what the undo removed
select t.run('c5', '00000000-0000-0000-0000-0000000e0001', $q$ select import_commit(t.id('imp'), t.base(), '{}') $q$);
select t.ok(t.r('c5')->'created' = '{"families":0,"guardians":0,"students":1,"tutors":0,"weekly_lessons":1}'::jsonb, 'after the undo the same file creates only Leo and his weekly lesson again (the kept rows still hold their codes)');
-- stale codes: a student removed by hand frees its code
select t.put('ella', (select id from students where name = 'Ella Tan' and org_id = t.id('imp')));
delete from recurring_slots where student_id = t.id('ella'); delete from students where id = t.id('ella');
select t.run('c6', '00000000-0000-0000-0000-0000000e0001', $q$ select import_commit(t.id('imp'), t.more(), '{}') $q$);
select t.ok(t.r('c6')->'created' = '{"families":0,"guardians":0,"students":1,"tutors":0,"weekly_lessons":1}'::jsonb, 'a student deleted by hand can be imported again: the stale code is not remembered (the weekly lesson of the existing student stays skipped)');

-- ===================================================================== 12. undo with NO later edits: the centre is exactly as before
select t.as('00000000-0000-0000-0000-0000000e0005');
create temp table s6 as select t.snap() j;
select t.run('c7', '00000000-0000-0000-0000-0000000e0005', $q$ select import_commit(t.id('imp2'), t.base(), '{"families.csv":"cccc3333"}') $q$);
select t.ok((t.r('c7')->>'ok')::boolean and (t.r('c7')->'created'->>'students')::int = 3, 'the other centre imports the same file (codes are per centre)');
insert into lessons(tutor_id, org_id, student_id, slot_id, lesson_date, start_time, end_time, rate, amount, status)                       -- generated, untouched
  select '00000000-0000-0000-0000-0000000e0005', t.id('imp2'), x.student_id, x.id, current_date + g, x.start_time, x.end_time, x.rate, x.rate, 'scheduled' from recurring_slots x, generate_series(1, 3) g where x.org_id = t.id('imp2');
select t.eq((select count(*) from lessons where org_id = t.id('imp2')), 9, 'nine untouched generated lessons exist before the undo');
select t.put('b2id', (t.r('c7')->>'batch_id')::uuid);
select t.run('u2', '00000000-0000-0000-0000-0000000e0005', $q$ select import_undo(t.id('b2id')) $q$);
select t.ok((t.r('u2')->>'ok')::boolean and t.r('u2')->>'status' = 'undone' and (t.r('u2')->>'kept_count')::int = 0, 'undo with no later edits removes everything: status undone, nothing kept');
select t.ok(t.r('u2')->'deleted' = '{"guardians":3,"households":2,"memberships":2,"recurring_slots":3,"students":3}'::jsonb, 'deleted: 3 guardians, 2 families, 2 tutors, 3 weekly lessons, 3 students');
select t.ok(t.changed((select j from s6), t.snap()) = 'audit_log,import_batches', 'every other table is back to its exact earlier row count (only the audit log and the batch history remain)');
select t.eq((select count(*) from import_items where org_id = t.id('imp2')), 0, 'no item rows are left for an undone batch');
select t.run('u2b', '00000000-0000-0000-0000-0000000e0005', $q$ select import_undo(t.id('b2id')) $q$);
select t.ok(not (t.r('u2b')->>'ok')::boolean and t.r('u2b')->>'code' = 'ALREADY_UNDONE', 'a batch can be undone only once');
select t.run('h2', '00000000-0000-0000-0000-0000000e0005', $q$ select import_history(t.id('imp2')) $q$);
select t.ok(t.r('h2')->0->>'status' = 'undone' and not (t.r('h2')->0->>'can_undo')::boolean, 'history shows the batch as undone, no Undo button');
-- import again (codes are free), then let the 7 days run out
select t.run('c8', '00000000-0000-0000-0000-0000000e0005', $q$ select import_commit(t.id('imp2'), t.base(), '{}') $q$);
select t.ok((t.r('c8')->'created'->>'students')::int = 3, 'after an undo the file imports again from scratch');
update import_batches set undo_until = now() - interval '1 minute' where id = (t.r('c8')->>'batch_id')::uuid;
create temp table s7 as select t.snap() j;
select t.run('u3', '00000000-0000-0000-0000-0000000e0005', format($q$ select import_undo(%L::uuid) $q$, t.r('c8')->>'batch_id'));
select t.ok(not (t.r('u3')->>'ok')::boolean and t.r('u3')->>'code' = 'UNDO_EXPIRED' and t.changed((select j from s7), t.snap()) = '', 'after 7 days undo is refused and nothing changes');
-- nobody else can undo
select t.ok(t.nf(format('select import_undo(%L)', t.id('b1id'))) or true, '(helper loaded)');
do $$
declare c record;
begin
  for c in select * from callers where who <> 'owner of another centre' loop
    perform t.as(c.uid); set local role authenticated;
    perform t.ok(t.nf(format('select import_undo(%L)', t.id('b1id'))), c.who || ': undo is NOT_FOUND');
    perform t.ok(t.nf(format('select import_undo_preview(%L)', t.id('b1id'))), c.who || ': undo preview is NOT_FOUND');
    reset role;
  end loop;
  perform t.as('00000000-0000-0000-0000-0000000e0005'); set local role authenticated;
  perform t.ok(t.nf(format('select import_undo(%L)', t.id('b1id'))), 'the owner of ANOTHER centre cannot undo this centre''s batch');
  reset role;
end $$;

-- ===================================================================== 13. the settings: billing starts from
select t.ok(true, '--- billing starts from');
create function t.st(v jsonb) returns jsonb language sql as $$ select jsonb_set(t.centre_settings(), '{billing,starts_from}', v) $$;
grant execute on function t.st(jsonb) to authenticated, service_role, anon;
select org_validate_settings(t.st('"2026-12-01"')); select t.ok(true, 'a date is accepted');
select org_validate_settings(t.st('""')); select t.ok(true, 'empty is accepted (bill every lesson)');
select org_validate_settings(t.st('null')); select t.ok(true, 'null is accepted');
select org_validate_settings(t.centre_settings()); select t.ok(true, 'a settings document without the key is accepted (older centres)');
select t.fails($q$ select org_validate_settings(t.st('"2026-13-01"')) $q$, 'month 13');
select t.fails($q$ select org_validate_settings(t.st('"2026-02-30"')) $q$, '30 February');
select t.fails($q$ select org_validate_settings(t.st('"01/12/2026"')) $q$, 'day-first text is not stored (the page converts it)');
select t.fails($q$ select org_validate_settings(t.st('20261201')) $q$, 'a number');
select t.fails($q$ select org_validate_settings(t.st('"2019-12-31"')) $q$, 'a date before 2020');
select t.fails($q$ select org_validate_settings(t.st('"2100-01-02"')) $q$, 'a date after 2100');
select t.as('00000000-0000-0000-0000-0000000e0001'); set role authenticated;
select org_save_settings(t.id('imp'), t.st('"2026-12-01"'), current_date);
select t.ok(org_billing_start(t.id('imp')) = date '2026-12-01', 'the saved date is read back by org_billing_start');
select t.ok(org_billing_start(t.id('imp2')) is null, 'a centre you are not in reads as null (no date, no information)');
select t.fails($q$ select org_save_settings(t.id('imp'), t.st('"2026-02-31"'), current_date) $q$, 'saving a bad date is refused');
select org_save_settings(t.id('imp'), t.st('""'), current_date);
select t.ok(org_billing_start(t.id('imp')) is null, 'an empty value means every lesson can be billed');
reset role;
select t.as('00000000-0000-0000-0000-0000000e0002'); set role authenticated;
select t.fails($q$ select org_save_settings(t.id('imp'), t.st('"2026-12-01"'), current_date) $q$, 'staff cannot change the date (owner only, as every setting)');
reset role;

-- ===================================================================== 14. cleanup bookkeeping rules
select t.ok(exists (select 1 from org_owned_columns() where tbl = 'import_batches' and col = 'org_id') and exists (select 1 from org_owned_columns() where tbl = 'import_items' and col = 'org_id'),
            'deleting an organisation covers the import tables automatically (org_id with on delete cascade)');
select t.ok((select bool_and(confdeltype = 'c') from pg_constraint where conrelid in ('public.import_items'::regclass, 'public.import_batches'::regclass) and contype = 'f' and confrelid in ('public.organisations'::regclass, 'public.import_batches'::regclass)),
            'import tables cascade from the organisation and the batch');
select t.ok(not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name in ('import_batches', 'import_items') and column_name ~* 'name|email|phone|note|cell|value|text'),
            'no import table has a column that could hold a name, email, phone or cell value');
select t.ok(not exists (select 1 from audit_log where action like 'import\_%' and after::text ~* 'Tan|Lee|Ava|Ben|example\.test|Ethan|Emma'), 'no audit row of an import or undo holds a name');
select t.ok(not exists (select 1 from information_schema.tables where table_schema = 'public' and table_name ~* 'mail|queue|outbox|notification' and table_name not in ('org_notifications', 'org_invite_mail_log')), 'no outbound mail or queue table exists for an import to write to (the owner-notice list and the invite send log, from earlier bundles, are the only ones)');
select t.ok((select count(*) from memberships where org_id = t.id('imp') and role = 'tutor' and status = 'invited' and user_id is null) >= 1, 'imported tutors are invitations (no login created)');

-- ===================================================================== 15. speed: 400 students, 200 tutors, about 600 guardians, 1,640 weekly lessons
create function t.fixture() returns jsonb language sql as $$ select jsonb_build_object(
  'families', (select jsonb_agg(jsonb_build_object('line', g + 1, 'family_ref', 'F' || lpad(g::text, 4, '0'), 'family_name', 'Family ' || g, 'guardian_name', 'Guardian ' || g || '-' || k, 'relation', case k when 1 then 'Mother' else 'Father' end,
                 'phone', '+659' || lpad((1000000 + g * 2 + k)::text, 7, '0'), 'main', k = 1)) from generate_series(1, 300) g, generate_series(1, 2) k),
  'students', (select jsonb_agg(jsonb_build_object('line', i + 1, 'student_ref', 'S' || lpad(i::text, 4, '0'), 'family_ref', 'F' || lpad((((i - 1) % 300) + 1)::text, 4, '0'), 'student_name', 'Student ' || i,
                 'level', 'P' || ((i % 6) + 1), 'lesson_location', 'Online', 'online_link', 'https://meet.example.test/s' || i, 'start_date', '2026-01-12')) from generate_series(1, 400) i),
  'tutors', (select jsonb_agg(jsonb_build_object('line', j + 1, 'tutor_email', 'tutor' || j || '@example.test', 'tutor_name', 'Tutor ' || j, 'subjects', 'Maths', 'employment', case when j % 2 = 0 then 'employee' else 'freelancer' end)) from generate_series(1, 200) j),
  'weekly_lessons', (select jsonb_agg(jsonb_build_object('line', n + 1, 'student_ref', 'S' || lpad((((n - 1) % 400) + 1)::text, 4, '0'), 'tutor_email', 'tutor' || (((n * 7) % 200) + 1) || '@example.test',
                 'day', ((((n - 1) % 400) + 1) + ((n - 1) / 400) * 2) % 7, 'start', lpad((15 + (n - 1) / 400)::text, 2, '0') || ':00', 'end', lpad((16 + (n - 1) / 400)::text, 2, '0') || ':00',
                 'subject', 'Maths', 'rate_cents', 5000 + (n % 20) * 100)) from generate_series(1, 1640) n)) $$;
grant execute on function t.fixture() to authenticated, service_role;
create temp table fx as select t.fixture() p; grant select on fx to authenticated;
select t.ok((select jsonb_array_length(p->'families') = 600 and jsonb_array_length(p->'students') = 400 and jsonb_array_length(p->'tutors') = 200 and jsonb_array_length(p->'weekly_lessons') = 1640 from fx), 'fixture: 600 guardians in 300 families, 400 students, 200 tutors, 1,640 weekly lessons');
create temp table timing(step text, ms numeric);
grant all on timing to authenticated;
create function t.timed(step_name text, uid text, q text, key text) returns void language plpgsql as $$
declare t0 timestamptz; o jsonb;
begin perform t.as(uid); set local role authenticated; t0 := clock_timestamp(); execute q into o; reset role;
  insert into timing values (step_name, round(extract(epoch from clock_timestamp() - t0) * 1000)); insert into t.res(k, j) values (key, o) on conflict (k) do update set j = excluded.j; end $$;
grant execute on function t.timed(text, text, text, text) to authenticated, service_role;
create temp table s8 as select t.snap() j;
select t.timed('dry run', '00000000-0000-0000-0000-0000000e0001', $q$ select import_dry_run(t.id('imp3'), (select p from fx)) $q$, 'f0');
select t.ok((t.r('f0')->>'ok')::boolean and t.r('f0')->'created' = '{"families":300,"guardians":600,"students":400,"tutors":200,"weekly_lessons":1640}'::jsonb, 'the fixture passes every check with no clash (400 students, 200 tutors)');
select t.ok(t.changed((select j from s8), t.snap()) = '', 'the 400/200 dry run wrote nothing');
select t.timed('commit', '00000000-0000-0000-0000-0000000e0001', $q$ select import_commit(t.id('imp3'), (select p from fx), '{}') $q$, 'f1');
select t.ok((t.r('f1')->>'ok')::boolean and t.r('f1')->'created' = '{"families":300,"guardians":600,"students":400,"tutors":200,"weekly_lessons":1640}'::jsonb, 'the fixture commits: 300 families, 600 guardians, 400 students, 200 tutors, 1,640 weekly lessons');
select t.ok((select ms from timing where step = 'commit') < 5000, 'commit of the 400/200 fixture takes under 5 seconds (took ' || (select ms from timing where step = 'commit') || ' ms; dry run ' || (select ms from timing where step = 'dry run') || ' ms)');
select t.timed('second run', '00000000-0000-0000-0000-0000000e0001', $q$ select import_commit(t.id('imp3'), (select p from fx), '{}') $q$, 'f2');
select t.ok((t.r('f2')->>'ok')::boolean and t.r('f2')->'created' = '{"families":0,"guardians":0,"students":0,"tutors":0,"weekly_lessons":0}'::jsonb and (select ms from timing where step = 'second run') < 5000, 'a second run creates nothing, in ' || (select ms from timing where step = 'second run') || ' ms');
select t.ok((select count(*) = 400 from students where org_id = t.id('imp3')) and (select count(*) = 1640 from recurring_slots where org_id = t.id('imp3')) and (select count(*) = 200 from memberships where org_id = t.id('imp3') and role = 'tutor' and status = 'invited'), 'the centre holds 400 students, 1,640 weekly lessons and 200 invited tutors');
select t.ok((select count(*) = 0 from recurring_slots x where x.org_id = t.id('imp3') and x.taught_by is null), 'every weekly lesson has its tutor');
select t.timed('undo', '00000000-0000-0000-0000-0000000e0001', format($q$ select import_undo(%L::uuid) $q$, t.r('f1')->>'batch_id'), 'f3');
select t.ok(t.r('f3')->>'status' = 'undone' and (select count(*) = 0 from students where org_id = t.id('imp3')) and (select count(*) = 0 from recurring_slots where org_id = t.id('imp3')), 'undo of the whole fixture removes it all, in ' || (select ms from timing where step = 'undo') || ' ms');
select t.ok((select ms from timing where step = 'undo') < 8000, 'undo is also well inside the 8-second statement limit');
