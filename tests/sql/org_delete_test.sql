-- Account deletion tests (solo tutor): after deletion nothing of theirs is left anywhere in the database,
-- other organisations are untouched, the append-only guarantee still holds, and the browser can't trigger it.
-- Runs after org_test.sql + billing_test.sql (uses their t.* helpers) and migration_org_delete.sql.
-- Everyone here is made up. Run with: bash tests/sql/run.sh   (throwaway local Postgres only)
\set ON_ERROR_STOP on
set client_min_messages = notice;
reset role;

-- ----------------------------------------------------------------- helpers
create table t.snap(k text primary key, v text);
grant all on t.snap to anon, authenticated, service_role;
grant usage on schema t to anon;
create function t.snap_put(p text, p_v text) returns void language sql as $$ insert into t.snap values (p, p_v) on conflict (k) do update set v = excluded.v $$;

-- How many rows, in ANY public table, mention this text anywhere (any column, JSON included)? The strongest "nothing left" check.
create function t.residue(needle text) returns bigint language plpgsql as $$
declare r record; n bigint; total bigint := 0;
begin
  for r in select table_name from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE' loop
    execute format('select count(*) from public.%I x where x::text ilike $1', r.table_name) into n using '%' || needle || '%';
    total := total + n;
  end loop;
  return total;
end $$;

-- A fingerprint of every organisation-owned row EXCEPT those of the given organisations (and the organisations themselves).
create function t.fp(excl uuid[]) returns text language plpgsql as $$
declare r record; acc text := ''; h text;
begin
  for r in select * from public.org_owned_columns() order by 1, 2 loop
    execute format('select coalesce(md5(string_agg(x::text, ''|'' order by x::text)), ''-'') from public.%I x where x.%I is not null and not (x.%I = any($1))', r.tbl, r.col, r.col)
      into h using excl;
    acc := acc || r.tbl || '.' || r.col || ':' || h || ';';
  end loop;
  select coalesce(md5(string_agg(x::text, '|' order by x::text)), '-') into h from public.organisations x where not (x.id = any(excl));
  return md5(acc || h);
end $$;
grant execute on all functions in schema t to anon, authenticated, service_role;

-- ----------------------------------------------------------------- made-up people
-- d1 = the tutor we delete through the server path   d2 = deleted by deleting the login only (safety net)
-- d3 = deletion fails halfway (must roll back)       dc = also owns a tuition centre (must be refused)
-- f1 = used to prove the audit switch is turned back on
insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-000000de0001', 'zed@del.test'), ('00000000-0000-0000-0000-000000de0002', 'dee@del.test'),
  ('00000000-0000-0000-0000-000000de0003', 'dot@del.test'), ('00000000-0000-0000-0000-000000de00c1', 'cee@del.test'),
  ('00000000-0000-0000-0000-000000de00f1', 'flo@del.test');
select t.put('d1_org', org_personal('00000000-0000-0000-0000-000000de0001')) \gset
select t.put('d2_org', org_personal('00000000-0000-0000-0000-000000de0002')) \gset
select t.put('d3_org', org_personal('00000000-0000-0000-0000-000000de0003')) \gset
select t.put('dc_solo', org_personal('00000000-0000-0000-0000-000000de00c1')) \gset
select t.put('f1_org', org_personal('00000000-0000-0000-0000-000000de00f1')) \gset
select t.ok(t.id('d1_org') is not null and t.id('d2_org') is not null and t.id('d3_org') is not null, 'dummy tutors each got a solo organisation');

-- a future table that only has an org_id column (no foreign key), as a later phase might add
create table public.zz_future(id serial primary key, org_id uuid, note text);

-- d1 gets a full set of data, every kind of table
update profiles set business_name = 'Zed Maths Hub', full_name = 'Zed Zhou', paynow_type = 'mobile', paynow_id = '88887777',
  bank_account_name = 'Zed Zhou', bank_account_no = '5550001234' where id = '00000000-0000-0000-0000-000000de0001';
update organisations set trading_name = 'Zed Maths Hub', address = '1 Quill Road' where id = t.id('d1_org');
insert into org_settings(org_id, version, schema_version, effective_from, settings)
  select t.id('d1_org'), 2, 1, current_date, org_solo_settings(p) from profiles p where p.id = '00000000-0000-0000-0000-000000de0001';
insert into org_plans(org_id, plan_code, base_cents, per_student_cents, effective_from) values (t.id('d1_org'), 'solo', 0, 0, current_date + 30);
insert into platform_fee_snapshots(org_id, month, active_students, billable_students, base_cents, per_student_cents, fee_cents)
  values (t.id('d1_org'), '2026-10-01', 3, 3, 0, 0, 0);
insert into students(tutor_id, name, level, contact, recipient_name) values   -- one statement each: the household takes its name from the first
  ('00000000-0000-0000-0000-000000de0001', 'Zara Quill', 'P6', '+65 8123 4455', 'Mrs Quill');
insert into students(tutor_id, name, level, contact, recipient_name) values ('00000000-0000-0000-0000-000000de0001', 'Quin Quill', 'Sec 1', '81234455', null);
insert into students(tutor_id, name, level, contact, recipient_name) values ('00000000-0000-0000-0000-000000de0001', 'Yusuf Zedstudent', 'JC1', null, null);
insert into recurring_slots(tutor_id, student_id, weekday, start_time, end_time, subject, rate)
  select tutor_id, id, 1, '16:00', '17:00', 'Math', 60 from students where name = 'Zara Quill';
insert into lessons(tutor_id, student_id, slot_id, lesson_date, start_time, end_time, subject, rate, amount, status, compensation)
  select s.tutor_id, s.id, r.id, '2026-11-03', '16:00', '17:00', 'Math', 60, 60, 'done', null
  from students s join recurring_slots r on r.student_id = s.id where s.name = 'Zara Quill';
insert into lessons(tutor_id, student_id, lesson_date, start_time, end_time, subject, rate, amount, status, compensation)
  select tutor_id, id, '2026-11-04', '17:00', '18:00', 'Math', 60, 60, 'cancelled', 30 from students where name = 'Quin Quill';
insert into exams(tutor_id, student_id, subject, exam_date) select tutor_id, id, 'Math', '2026-12-01' from students where name = 'Zara Quill';
insert into invoices(tutor_id, student_id, invoice_no, total, data)
  select tutor_id, id, 'ZED-0001', 60, '{"html":"<p>big</p>","lesson_ids":[],"recipient":"Mrs Quill"}' from students where name = 'Zara Quill';
insert into materials(owner_id, subject, level, topic, title, file_path)
  values ('00000000-0000-0000-0000-000000de0001', 'Math', 'P6', 'Fractions', 'Zed Worksheet', '00000000-0000-0000-0000-000000de0001/zed.pdf');
insert into branches(org_id, name, address) values (t.id('d1_org'), 'Home studio', '1 Quill Road');
insert into rooms(org_id, branch_id, name) select t.id('d1_org'), id, 'Front room' from branches where org_id = t.id('d1_org');
insert into terms(org_id, name, starts_on, ends_on) values (t.id('d1_org'), 'Term 4', '2026-10-01', '2026-12-01');
insert into holidays(org_id, name, starts_on, ends_on) values (t.id('d1_org'), 'Zed holiday', '2026-12-01', '2026-12-05');
insert into support_access_grants(org_id, granted_by, reason, expires_at)
  values (t.id('d1_org'), '00000000-0000-0000-0000-000000de0001', 'help me', now() + interval '1 day');
update org_subscriptions set stripe_customer_id = 'cus_del1', stripe_subscription_id = 'sub_del1', tier = 'pro', status = 'active' where org_id = t.id('d1_org');
insert into gcal_links(tutor_id, google_email, refresh_enc) values ('00000000-0000-0000-0000-000000de0001', 'zed@gmail.test', 'sealed');
insert into client_errors(tutor_id, kind, message) values ('00000000-0000-0000-0000-000000de0001', 'js', 'boom');
insert into zz_future(org_id, note) values (t.id('d1_org'), 'future row of d1'), (t.id('ben_org'), 'future row of ben');

-- d2: smaller (for the "delete the login only" path)
update profiles set business_name = 'Dee Tutoring', paynow_id = '99990000' where id = '00000000-0000-0000-0000-000000de0002';
insert into students(tutor_id, name, contact, recipient_name) values ('00000000-0000-0000-0000-000000de0002', 'Dara Deekid', '+65 9000 1122', 'Mr Deekid');
insert into lessons(tutor_id, student_id, lesson_date, start_time, end_time, subject, rate, amount, status)
  select tutor_id, id, '2026-11-05', '10:00', '11:00', 'Math', 40, 40, 'done' from students where name = 'Dara Deekid';
-- d3: for the half-finished deletion
insert into students(tutor_id, name, contact) values ('00000000-0000-0000-0000-000000de0003', 'Dot Kid', '+65 9111 3344');
-- dc: a tutor who is also the owner of a tuition centre
select t.as('00000000-0000-0000-0000-000000de00c1'); set role authenticated;
select t.put('dc_centre', org_create_centre('Quill Centre', t.centre_settings())) \gset
reset role;
-- another organisation with a fee snapshot, for the "append-only still holds for everyone else" checks
insert into platform_fee_snapshots(org_id, month, active_students, billable_students, base_cents, per_student_cents, fee_cents)
  values (t.id('ben_org'), '2026-10-01', 1, 1, 0, 0, 0);

-- ===================================================================== the problem, shown first
select t.ok(t.residue('Zara Quill') >= 2 and t.residue('Mrs Quill') >= 5, 'BEFORE: student and parent names are spread over several tables, audit_log included');
select t.ok((select count(distinct table_name) >= 4 from (select 'households' table_name from households where name like '%Quill%' union all select 'guardians' from guardians where name like '%Quill%'
             union all select 'invoices' from invoices where data::text like '%Mrs Quill%' union all select 'audit_log' from audit_log where after::text like '%Mrs Quill%') x), 'BEFORE: the parent''s name sits in households, guardians, invoices and audit_log');
select t.ok((select count(*) from audit_log where org_id = t.id('d1_org') and (before::text like '%8123 4455%' or after::text like '%8123 4455%')) > 0,
            'BEFORE: the audit log holds a parent''s phone number');
select t.ok((select count(*) >= 14 from org_owned_columns()), 'the catalogue finds every organisation-owned table');
select t.ok((select count(*) = 4 from org_owned_columns() where tbl in ('audit_log', 'org_subscriptions', 'households', 'zz_future')), 'incl. audit_log, org_subscriptions, households and a future table with no foreign key');

-- ===================================================================== who may call it
select t.as('00000000-0000-0000-0000-000000de0001'); set role authenticated;
select t.fails('select org_delete_solo(t.id(''d1_org''), ''00000000-0000-0000-0000-000000de0001'')', 'a signed-in tutor calling org_delete_solo on their own organisation');
select t.fails('select org_delete_solo(t.id(''ben_org''), ''00000000-0000-0000-0000-0000000000b1'')', 'a signed-in tutor calling org_delete_solo on someone else''s');
select t.fails('select * from org_owned_columns()', 'a signed-in tutor calling the internal catalogue helper');
select t.fails('select org_before_user_delete()', 'a signed-in tutor calling the trigger function');
reset role;
set role anon;
select t.fails('select org_delete_solo(t.id(''d1_org''), ''00000000-0000-0000-0000-000000de0001'')', 'a signed-out visitor calling org_delete_solo');
reset role;
select t.ok(not has_function_privilege('authenticated', 'public.org_delete_solo(uuid,uuid)', 'execute')
        and not has_function_privilege('anon', 'public.org_delete_solo(uuid,uuid)', 'execute')
        and has_function_privilege('service_role', 'public.org_delete_solo(uuid,uuid)', 'execute'), 'only the server (service_role) holds EXECUTE');

-- ===================================================================== the exception can't be forged
-- 1. the flag alone does nothing for the browser roles or for the server key used directly
set role service_role;
select set_config('td.deleting_org', t.id('d1_org')::text, false);
select t.fails('delete from audit_log where org_id = ' || quote_literal(t.id('d1_org')), 'service_role deleting audit rows by hand with the flag set');
select t.fails('delete from org_settings where org_id = ' || quote_literal(t.id('d1_org')), 'service_role deleting settings by hand with the flag set');
select t.fails('delete from platform_fee_snapshots where org_id = ' || quote_literal(t.id('d1_org')), 'service_role deleting fee snapshots by hand with the flag set');
select set_config('td.deleting_org', '', false);
reset role;
-- 2. even with the flag, another organisation's rows stay locked, and nothing can ever be edited
select set_config('td.deleting_org', t.id('d1_org')::text, false);
select t.fails('delete from audit_log where org_id = ' || quote_literal(t.id('ben_org')), 'flag for one organisation unlocking another''s audit rows');
select t.fails('delete from platform_fee_snapshots where org_id = ' || quote_literal(t.id('ben_org')), 'flag for one organisation unlocking another''s fee snapshots');
select t.fails('update audit_log set action = ''x'' where org_id = ' || quote_literal(t.id('d1_org')), 'editing the audit log with the flag set');
select t.fails('update org_settings set version = version where org_id = ' || quote_literal(t.id('d1_org')), 'editing settings with the flag set');
select set_config('td.deleting_org', '', false);
select t.fails('delete from audit_log where org_id = ' || quote_literal(t.id('d1_org')), 'deleting audit rows with no flag at all');

-- ===================================================================== refusals leave everything as it was
select t.snap_put('d1_students_before', (select count(*)::text from students where org_id = t.id('d1_org')));
set role service_role;
select t.fails('select org_delete_solo(t.id(''d1_org''), ''00000000-0000-0000-0000-0000000000b1'')', 'deleting an organisation as someone who is not its owner');
select t.fails('select org_delete_solo(t.id(''dc_centre''), ''00000000-0000-0000-0000-000000de00c1'')', 'deleting a centre this way (only solo for now)');
select t.fails('select org_delete_solo(t.id(''dc_solo''), ''00000000-0000-0000-0000-000000de00c1'')', 'deleting the solo organisation of someone who owns a centre');
reset role;
select t.ok((select count(*)::text from students where org_id = t.id('d1_org')) = (select v from t.snap where k = 'd1_students_before'), 'after the refusals the tutor''s data is intact');
select t.ok(exists (select 1 from organisations where id = t.id('dc_solo')) and exists (select 1 from organisations where id = t.id('dc_centre')), 'after the refusals the centre owner''s organisations are intact');

-- ===================================================================== d1: the real deletion, as the server does it
select t.snap_put('fp_before', t.fp(array[t.id('d1_org'), t.id('f1_org')]));
select t.snap_put('orgs_before', (select count(*)::text from organisations));
select t.snap_put('tombstones_before', (select count(*)::text from audit_log where action = 'org_deleted'));
select t.snap_put('f1_audit_before', (select count(*)::text from audit_log where org_id = t.id('f1_org')));

select t.as('00000000-0000-0000-0000-000000de00f1');          -- the "someone else" who works right after (a different tutor's request)
set role service_role;
do $$
declare res jsonb; a bigint; b bigint; f uuid := t.id('f1_org'); s1 bigint; s2 bigint;
begin
  select last_value into s1 from pg_sequences where sequencename = 'audit_log_id_seq';
  res := org_delete_solo(t.id('d1_org'), '00000000-0000-0000-0000-000000de0001');
  select last_value into s2 from pg_sequences where sequencename = 'audit_log_id_seq';
  -- deleting ~30 rows must not copy each one into the audit log on its way out: the only audit row written is the anonymous note
  perform t.eq(s2 - s1, 1, 'the deletion wrote exactly one audit row (the anonymous note), not one per deleted row');
  perform t.ok((res->>'deleted')::boolean, 'org_delete_solo reports it deleted the organisation');
  perform t.eq((res->'rows'->>'students')::numeric, 3, 'it reports how many students went (counts only)');
  perform t.ok((res->'rows'->>'audit_log')::numeric > 10, 'and how many audit rows');
  -- the two switches are back off inside the same transaction
  perform t.ok(coalesce(current_setting('td.deleting_org', true), '') = '', 'the deletion flag is switched off again straight away');
  perform t.ok(coalesce(current_setting('td.skip_audit', true), '') = '', 'audit logging is switched back on straight away');
  select count(*) into a from audit_log where org_id = f;
  insert into students(tutor_id, name) values ('00000000-0000-0000-0000-000000de00f1', 'Flag Check');
  select count(*) into b from audit_log where org_id = f;
  perform t.ok(b > a, 'a change by someone else, right after, IS written to the audit log');
  delete from students where name = 'Flag Check';
end $$;
reset role;

-- nothing of theirs is left, in any table
create function t.rows_for(p_org uuid) returns bigint language plpgsql as $$
declare r record; n bigint; total bigint := 0;
begin
  for r in select * from org_owned_columns() loop
    execute format('select count(*) from public.%I where %I = $1', r.tbl, r.col) into n using p_org;
    total := total + n;
  end loop;
  select total + count(*) into total from organisations where id = p_org;
  return total;
end $$;
select t.eq(t.rows_for(t.id('d1_org')), 0, 'AFTER: no row with that organisation id in ANY table (incl. audit_log, org_settings, fee snapshots, subscriptions, a table with no key)');
select t.eq(t.residue(t.id('d1_org')::text), 0, 'AFTER: the organisation id appears nowhere, in any column or any JSON');
select t.eq(t.residue('Zara Quill'), 0, 'AFTER: student names are gone everywhere, audit_log included');
select t.eq(t.residue('Yusuf Zedstudent'), 0, 'AFTER: every student is gone');
select t.eq(t.residue('Mrs Quill'), 0, 'AFTER: parent names are gone (households, guardians, invoices, audit)');
select t.eq(t.residue('8123 4455') + t.residue('81234455'), 0, 'AFTER: the parent''s phone number is gone, written either way');
select t.eq(t.residue('ZED-0001') + t.residue('Zed Worksheet') + t.residue('Home studio') + t.residue('Zed holiday'), 0, 'AFTER: invoices, materials, branches and holidays are gone');
select t.eq(t.residue('cus_del1') + t.residue('sub_del1'), 0, 'AFTER: the Stripe customer and subscription ids are gone from our database');
select t.eq(t.residue('future row of d1'), 0, 'AFTER: a future table with only an org_id column is cleaned too');
select t.eq(t.residue('future row of ben'), 1, 'but another organisation''s row in that table is untouched');
select t.eq((select count(*) from audit_log where action = 'org_deleted')::numeric - (select v::numeric from t.snap where k = 'tombstones_before'), 1, 'exactly one anonymous "organisation deleted" note was added');
select t.ok((select org_id is null and actor is null and row_id is null and before is null and after = '{"kind":"solo"}'::jsonb from audit_log where action = 'org_deleted' order by id desc limit 1), 'and it says nothing about whose');
select t.eq((select count(*) from organisations)::numeric, (select v::numeric from t.snap where k = 'orgs_before') - 1, 'exactly one organisation went');
select t.ok(t.fp(array[t.id('d1_org'), t.id('f1_org')]) = (select v from t.snap where k = 'fp_before'), 'every other organisation is byte-for-byte untouched (all tables, all rows)');
-- what is left of the person is the login-keyed rows, which go with the login
select t.ok(exists (select 1 from profiles where id = '00000000-0000-0000-0000-000000de0001') and exists (select 1 from gcal_links where tutor_id = '00000000-0000-0000-0000-000000de0001'),
            'until the login is deleted, the profile (PayNow, bank) and Google link still exist: the server deletes the login next');
delete from auth.users where id = '00000000-0000-0000-0000-000000de0001';
select t.eq(t.residue('00000000-0000-0000-0000-000000de0001'), 0, 'AFTER the login is deleted: the user id appears nowhere in the database');
select t.eq(t.residue('88887777') + t.residue('5550001234') + t.residue('Zed Maths Hub') + t.residue('Zed Zhou') + t.residue('zed@gmail.test'), 0, 'AFTER the login is deleted: PayNow, bank, business and Google details are gone');
-- a retry after a half-finished deletion is harmless
set role service_role;
select t.ok(not (org_delete_solo(t.id('d1_org'), '00000000-0000-0000-0000-000000de0001')->>'deleted')::boolean, 'deleting again is harmless (nothing to delete)');
reset role;

-- ===================================================================== append-only still holds for everyone else
select t.fails('delete from audit_log where org_id = ' || quote_literal(t.id('tina_org')), 'deleting another organisation''s audit rows');
select t.fails('update audit_log set action = ''x'' where org_id = ' || quote_literal(t.id('tina_org')), 'editing another organisation''s audit rows');
select t.fails('update org_settings set version = version where org_id = ' || quote_literal(t.id('tina_org')), 'editing another organisation''s settings');
select t.fails('delete from org_settings where org_id = ' || quote_literal(t.id('tina_org')), 'deleting another organisation''s settings');
select t.fails('delete from platform_fee_snapshots where org_id = ' || quote_literal(t.id('ben_org')), 'deleting another organisation''s fee snapshots');
select t.fails('delete from organisations where id = ' || quote_literal(t.id('tina_org')), 'deleting another organisation directly (its settings are append-only)');
select t.ok(coalesce(current_setting('td.deleting_org', true), '') = '', 'no deletion flag is left set on this connection');

-- ===================================================================== d2: deleting only the login must still clean the database
-- (the Supabase dashboard's "Delete user", or the old Edge Function, would do exactly this)
select t.ok(t.residue('Dara Deekid') >= 3, 'BEFORE: the other tutor''s student is in several tables');
select t.snap_put('fp2_before', t.fp(array[t.id('d2_org'), t.id('f1_org')]));
delete from auth.users where id = '00000000-0000-0000-0000-000000de0002';
select t.eq(t.rows_for(t.id('d2_org')), 0, 'deleting just the login removed the whole organisation, audit rows included');
select t.eq(t.residue('Dara Deekid') + t.residue('Mr Deekid') + t.residue('9000 1122') + t.residue('Dee Tutoring') + t.residue('99990000'), 0, 'and every name, phone and PayNow id with it');
select t.eq(t.residue('00000000-0000-0000-0000-000000de0002') + t.residue(t.id('d2_org')::text), 0, 'and every id');
select t.ok(t.fp(array[t.id('d2_org'), t.id('f1_org')]) = (select v from t.snap where k = 'fp2_before'), 'other organisations untouched by that too');
select t.eq((select count(*) from audit_log where action = 'org_deleted')::numeric - (select v::numeric from t.snap where k = 'tombstones_before'), 2, 'one more anonymous note');

-- ===================================================================== a tutor who also owns a centre: deleting the login is refused
select t.fails('delete from auth.users where id = ''00000000-0000-0000-0000-000000de00c1''', 'deleting the login of someone who owns a centre');
select t.ok(exists (select 1 from auth.users where id = '00000000-0000-0000-0000-000000de00c1') and exists (select 1 from organisations where id = t.id('dc_centre')), 'login and centre are still there');

-- ===================================================================== a deletion that can't finish leaves everything as it was
-- A table keyed to the organisation WITHOUT "on delete cascade" (a future mistake) must make the deletion fail loudly,
-- never leave half a tutor behind.
create table public.zz_nocascade(id serial primary key, org_id uuid references organisations(id), note text);
insert into zz_nocascade(org_id, note) values (t.id('d3_org'), 'blocker');
select t.snap_put('d3_audit_before', (select count(*)::text from audit_log where org_id = t.id('d3_org')));
set role service_role;
select t.fails('select org_delete_solo(t.id(''d3_org''), ''00000000-0000-0000-0000-000000de0003'')', 'a deletion blocked by a table with no cascade');
reset role;
select t.ok(exists (select 1 from students where name = 'Dot Kid') and exists (select 1 from organisations where id = t.id('d3_org')), 'rolled back: the student and organisation are still there');
select t.ok((select count(*)::text from audit_log where org_id = t.id('d3_org')) = (select v from t.snap where k = 'd3_audit_before'), 'rolled back: not one audit row was removed');
select t.eq((select count(*) from audit_log where action = 'org_deleted')::numeric - (select v::numeric from t.snap where k = 'tombstones_before'), 2, 'rolled back: no deletion note written for the failed deletion (still just d1 and d2)');
drop table public.zz_nocascade;
set role service_role;
select t.ok((org_delete_solo(t.id('d3_org'), '00000000-0000-0000-0000-000000de0003')->>'deleted')::boolean, 'once the blocker is gone the same call succeeds');
reset role;
select t.eq(t.rows_for(t.id('d3_org')) + t.residue('Dot Kid') + t.residue('9111 3344'), 0, 'and then nothing is left');

-- ===================================================================== clean up what this file created (the undo check compares structure with the live baseline)
drop table public.zz_future;
\echo ALL ACCOUNT-DELETION TESTS PASSED
