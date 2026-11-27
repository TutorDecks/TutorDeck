-- T33 I1: the page's OWN payload (made by assets/js/import-core.js from the generated fake fixture) goes through the database's checks and commit,
-- so the two validators are proved to agree on the same data in the same shape. Runs after import_test.sql (same throwaway database).
-- Needs the env var IMPORT_PAYLOAD_FILE (a JSON file made by tests/fixtures/make-import-payload.js); run.sh sets it and skips this when node is missing.
\set ON_ERROR_STOP on
set client_min_messages = notice;
\set pl `cat "$IMPORT_PAYLOAD_FILE"`
select t.as('00000000-0000-0000-0000-0000000e0001');
select t.put('imp4', (select org_create_centre('Payload Centre', t.centre_settings())));
set role authenticated;
select t.ok((select (r->>'ok')::boolean from (select import_dry_run(t.id('imp4'), :'pl'::jsonb) r) x), 'the page''s payload passes the database''s checks (dry run)');
select t.ok((select (r->'created'->>'students')::int = 400 and (r->'created'->>'tutors')::int = 200 and (r->'created'->>'weekly_lessons')::int = 1640
              from (select import_dry_run(t.id('imp4'), :'pl'::jsonb) r) x), 'the dry run counts what the page counted (400 students, 200 tutors, 1,640 weekly lessons)');
reset role;
select t.as('00000000-0000-0000-0000-0000000e0001');
set role authenticated;
select t.put('pc1', (select (import_commit(t.id('imp4'), :'pl'::jsonb, '{}')->>'batch_id')::uuid));
reset role;
select t.ok((select count(*) = 400 from students where org_id = t.id('imp4')) and (select count(*) = 1640 from recurring_slots where org_id = t.id('imp4'))
        and (select count(*) = 200 from memberships where org_id = t.id('imp4') and role = 'tutor' and status = 'invited'), 'the page''s payload commits: 400 students, 1,640 weekly lessons, 200 invited tutors');
select t.as('00000000-0000-0000-0000-0000000e0001'); set role authenticated;
select t.ok((import_commit(t.id('imp4'), :'pl'::jsonb, '{}')->'created'->>'students')::int = 0, 'importing the page''s payload again creates nothing');
select t.ok((import_undo(t.id('pc1'))->>'status') = 'undone', 'and its undo removes it all');
reset role;
