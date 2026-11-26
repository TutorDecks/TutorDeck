-- Phase 1 tests: backfill, solo tutors unchanged, tenant isolation, roles, settings, audit, platform admin.
-- Run with: bash tests/sql/run.sh   (throwaway local Postgres only)
\set ON_ERROR_STOP on
set client_min_messages = notice;

create schema t;
grant usage on schema t to authenticated, service_role;
create table t.ids (k text primary key, v uuid);
grant all on t.ids to authenticated, service_role;
create function t.id(p text) returns uuid language sql stable as $$ select v from t.ids where k = p $$;
create function t.put(p text, v uuid) returns uuid language sql as $$ insert into t.ids values (p, v) on conflict (k) do update set v = excluded.v returning v $$;
create function t.ok(c boolean, msg text) returns void language plpgsql as $$
begin if c is distinct from true then raise exception 'FAIL: %', msg; end if; raise notice 'PASS %', msg; end $$;
create function t.eq(a numeric, b numeric, msg text) returns void language plpgsql as $$
begin if a is distinct from b then raise exception 'FAIL: % (got %, expected %)', msg, a, b; end if; raise notice 'PASS % = %', msg, b; end $$;
create function t.fails(q text, msg text) returns void language plpgsql as $$
declare blocked boolean := false; m text;
begin
  begin execute q; exception when others then blocked := true; m := sqlerrm; end;
  if not blocked then raise exception 'FAIL: % was allowed', msg; end if;
  raise notice 'PASS blocked: % (%)', msg, m;
end $$;
-- run a statement and return how many rows it touched (RLS hides rows silently)
create function t.rows(q text) returns int language plpgsql as $$ declare n int; begin execute q; get diagnostics n = row_count; return n; end $$;
create function t.as(u text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, false) $$;
grant execute on all functions in schema t to authenticated, service_role;

-- a valid centre settings document (the wizard builds the full one from assets/js/org-settings.js)
create function t.centre_settings() returns jsonb language sql as $$ select '{
  "schema_version":1,"preset":"centre",
  "profile":{"gst_registered":true,"gst_rate_bp":900,"gst_inclusive":false,"invoice_prefix":"OPUS","next_invoice_number":1},
  "calendar":{},"billing":{"model":"prepaid_packages"},"invoicing":{"grouping":"family"},
  "payments":{"modes":["manual_paynow"]},"lessons":{},"tutor_pay":{"mode":"report","payable_when":"parent_paid"},"data":{}}'::jsonb $$;
grant execute on function t.centre_settings() to authenticated;

-- ===================================================================== backfill
select t.put('tina_org', org_personal('00000000-0000-0000-0000-0000000000a1'));
select t.put('ben_org',  org_personal('00000000-0000-0000-0000-0000000000b1'));
select t.ok(t.id('tina_org') is not null and t.id('ben_org') is not null and t.id('tina_org') <> t.id('ben_org'), 'each existing tutor got their own organisation');
select t.ok((select kind = 'solo' and preset = 'solo' and status = 'active' and trading_name = 'Bright Maths' from organisations where id = t.id('tina_org')), 'solo preset, active (no wizard), named after the business');
select t.ok((select trading_name = 'Ben Ong' from organisations where id = t.id('ben_org')), 'no business name: uses the tutor''s name');
select t.ok((select role = 'owner' from memberships where org_id = t.id('tina_org') and user_id = '00000000-0000-0000-0000-0000000000a1'), 'tutor is owner of their organisation');
select t.ok((select settings#>>'{profile,invoice_prefix}' = 'BM' and settings#>>'{payments,paynow,id}' = '91234567' from org_settings where org_id = t.id('tina_org')), 'settings v1 copied from the profile');
select t.ok((select count(*) = 0 from students where org_id is null) and (select count(*) = 0 from lessons where org_id is null)
        and (select count(*) = 0 from invoices where org_id is null) and (select count(*) = 0 from materials where org_id is null), 'every row has an organisation');
select t.eq((select count(distinct org_id) from lessons where tutor_id = '00000000-0000-0000-0000-0000000000a1'), 1, 'Tina''s lessons all in her org');
select t.ok((select count(distinct household_id) = 1 from students where name in ('Amy Lim','Alan Lim')), 'siblings with the same phone (written two ways) share a household');
select t.ok((select household_id <> (select household_id from students where name = 'Amy Lim') from students where name = 'Zoe'), 'student without a phone gets their own household');
select t.ok((select name = 'Mrs Lim' from households where id = (select household_id from students where name = 'Amy Lim')), 'household named after the parent');
select t.eq((select amount_cents from lessons where amount = 90.75), 9075, 'cents column mirrors dollars exactly');
select t.eq((select compensation_cents from lessons where compensation = 27.50), 2750, 'compensation in cents');
select t.ok((select count(*) = 1 from audit_log where action = 'migrate'), 'backfill logged once, not per row');

-- ===================================================================== solo tutor: today's pages unchanged
select t.as('00000000-0000-0000-0000-0000000000a1'); set role authenticated;
select t.eq((select count(*) from students), 3, 'Tina sees exactly her 3 students');
select t.eq((select count(*) from lessons), 2, 'Tina sees exactly her 2 lessons');
-- the existing pages insert WITHOUT org_id: it must still work
insert into students(tutor_id, name, contact) values ('00000000-0000-0000-0000-0000000000a1', 'New Kid', '9876-5432');
select t.ok((select org_id = t.id('tina_org') and household_id = (select household_id from students where name = 'Amy Lim') from students where name = 'New Kid'), 'old-style insert gets her org and the matching household');
insert into lessons(tutor_id, student_id, lesson_date, start_time, end_time, rate, amount)
select '00000000-0000-0000-0000-0000000000a1', id, '2026-11-10', '10:00', '11:00', 50, 50 from students where name = 'New Kid';
select t.eq(t.rows($q$ update lessons set paid = true, paid_date = '2026-11-12' where lesson_date = '2026-11-10' $q$), 1, 'mark paid works');
select t.eq(t.rows($q$ delete from lessons where lesson_date = '2026-11-10' $q$), 1, 'delete works');
select t.fails($q$ update students set org_id = t.id('ben_org') where name = 'Zoe' $q$, 'moving a row to another organisation');
reset role;

-- ===================================================================== isolation between organisations
select t.as('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
select t.eq((select count(*) from students where org_id = t.id('tina_org')), 0, 'Ben reads none of Tina''s students');
select t.eq((select count(*) from lessons where org_id = t.id('tina_org')), 0, 'Ben reads none of Tina''s lessons');
select t.eq((select count(*) from invoices where org_id = t.id('tina_org')), 0, 'Ben reads none of Tina''s invoices');
select t.eq((select count(*) from households where org_id = t.id('tina_org')), 0, 'Ben reads none of Tina''s households');
select t.eq((select count(*) from guardians where org_id = t.id('tina_org')), 0, 'Ben reads none of Tina''s guardians');
select t.eq((select count(*) from org_settings where org_id = t.id('tina_org')), 0, 'Ben reads none of Tina''s settings');
select t.eq((select count(*) from organisations where id = t.id('tina_org')), 0, 'Ben can''t see Tina''s organisation');
select t.eq((select count(*) from memberships where org_id = t.id('tina_org')), 0, 'Ben can''t see Tina''s members');
select t.eq((select count(*) from audit_log where org_id = t.id('tina_org')), 0, 'Ben can''t see Tina''s audit log');
select t.eq(t.rows($q$ update students set name = 'hacked' where org_id = t.id('tina_org') $q$), 0, 'Ben can''t update Tina''s rows');
select t.eq(t.rows($q$ delete from lessons where org_id = t.id('tina_org') $q$), 0, 'Ben can''t delete Tina''s rows');
select t.fails($q$ insert into students(tutor_id, org_id, name) values ('00000000-0000-0000-0000-0000000000b1', t.id('tina_org'), 'Planted') $q$, 'Ben writing a row into Tina''s org');
select t.fails($q$ insert into students(tutor_id, name) values ('00000000-0000-0000-0000-0000000000a1', 'Planted') $q$, 'Ben writing a row as Tina');
select t.fails($q$ insert into lessons(tutor_id, student_id, lesson_date, start_time, end_time, rate) values ('00000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-000000000001', '2026-11-20', '10:00', '11:00', 1) $q$, 'Ben booking a lesson on Tina''s student');
select t.fails($q$ select org_save_settings(t.id('tina_org'), t.centre_settings(), current_date + 1) $q$, 'Ben changing Tina''s settings');
reset role;

-- ===================================================================== a tuition centre
insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-0000000000c1', 'owner@centre.test'),
  ('00000000-0000-0000-0000-0000000000d1', 'staff@centre.test'),
  ('00000000-0000-0000-0000-0000000000e1', 'tutor@centre.test'),
  ('00000000-0000-0000-0000-0000000000f1', 'admin@tutordeck.test');
select t.ok((select count(*) = 4 from organisations o join memberships m on m.org_id = o.id where o.kind = 'solo'
             and m.user_id in ('00000000-0000-0000-0000-0000000000c1','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000f1')),
            'new sign-ups get a solo organisation automatically');
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select t.put('centre', org_create_centre('Opus Tuition', t.centre_settings()));
select t.ok((select kind = 'centre' and status = 'setup' from organisations where id = t.id('centre')), 'centre created in setup (wizard)');
select t.fails($q$ select org_create_centre('Bad', '{"schema_version":1}') $q$, 'centre with incomplete settings');
select org_invite(t.id('centre'), 'Staff@Centre.test', 'Sam Staff', 'staff', array['manage_students'], null);
select org_invite(t.id('centre'), 'tutor@centre.test', 'Tara Tutor', 'tutor', null, 'freelancer');
select t.fails($q$ select org_invite(t.id('centre'), 'x@y.test', 'X', 'staff', array['delete_everything'], null) $q$, 'unknown staff permission');
select t.fails($q$ select org_invite(t.id('centre'), 'x@y.test', 'X', 'owner', null, null) $q$, 'inviting a second owner');
reset role;
select t.as('00000000-0000-0000-0000-0000000000d1'); set role authenticated;
select t.eq(org_claim_invites(), 1, 'staff claims invite (email case-insensitive)');
insert into students(tutor_id, org_id, name, level) values ('00000000-0000-0000-0000-0000000000d1', t.id('centre'), 'Centre Kid', 'Sec 3');
select t.ok((select org_id = t.id('centre') from students where name = 'Centre Kid'), 'staff with manage_students adds a centre student');
select t.fails($q$ insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate) select '00000000-0000-0000-0000-0000000000d1', t.id('centre'), id, '2026-11-20', '10:00', '11:00', 40 from students where name = 'Centre Kid' $q$, 'staff without manage_timetable adding a lesson');
select t.fails($q$ select org_save_settings(t.id('centre'), t.centre_settings(), current_date) $q$, 'staff changing settings (owner only)');
select t.eq((select count(*) from students where org_id = t.id('tina_org')), 0, 'centre staff can''t see Tina''s solo students');
select t.eq((select count(*) from audit_log where org_id = t.id('centre')), 0, 'staff without view_audit_log sees none of the centre''s audit log');
reset role;
select t.as('00000000-0000-0000-0000-0000000000e1'); set role authenticated;
select org_claim_invites();
select t.eq((select count(*) from students where org_id = t.id('centre')), 0, 'centre tutor can''t read the student list (phase 2 gives own lessons only)');
select t.eq((select count(*) from memberships where org_id = t.id('centre')), 1, 'tutor sees only their own membership');
reset role;
select t.as('00000000-0000-0000-0000-0000000000a1'); set role authenticated;
select t.eq((select count(*) from students where org_id = t.id('centre')), 0, 'solo tutor can''t see centre students');
reset role;

-- ===================================================================== settings: versioned, never edited
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select t.eq(org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{billing,model}', '"postpaid_lessons"'), current_date), 2, 'owner saves settings v2');
select t.fails($q$ select org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{billing,model}', '"barter"'), current_date) $q$, 'invalid billing model');
select t.fails($q$ select org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{payments,modes}', '[]'), current_date) $q$, 'no payment mode');
update organisations set status = 'active' where id = t.id('centre');
select t.fails($q$ select org_save_settings(t.id('centre'), t.centre_settings(), current_date - 1) $q$, 'back-dating settings after launch');
select t.eq(org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{billing,model}', '"fixed_in_advance"'), date_trunc('month', current_date + interval '1 month')::date), 3, 'change from next cycle');
select t.ok(org_settings_on(t.id('centre'))#>>'{billing,model}' = 'postpaid_lessons', 'today still uses v2');
select t.ok(org_settings_on(t.id('centre'), date_trunc('month', current_date + interval '1 month')::date)#>>'{billing,model}' = 'fixed_in_advance', 'next month uses v3');
reset role;
select t.fails($q$ update org_settings set settings = '{}' where org_id = t.id('centre') $q$, 'editing a settings version (even as database owner)');
select t.fails($q$ delete from org_settings where org_id = t.id('centre') $q$, 'deleting a settings version');

-- ===================================================================== audit log
select t.ok((select count(*) >= 1 from audit_log where table_name = 'students' and action = 'insert' and actor = '00000000-0000-0000-0000-0000000000d1'), 'student insert logged with who did it');
select t.ok((select count(*) >= 3 from audit_log where table_name = 'org_settings' and org_id = t.id('centre')), 'settings versions logged');
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select t.ok((select count(*) >= 1 from audit_log where org_id = t.id('centre')), 'owner sees their audit log');
reset role;
select t.fails($q$ delete from audit_log $q$, 'deleting the audit log (even as database owner)');
select t.fails($q$ update audit_log set action = 'x' $q$, 'editing the audit log');
select t.as('00000000-0000-0000-0000-0000000000a1'); set role authenticated;
update lessons set gcal_event_id = 'g1' where org_id = t.id('tina_org');
reset role;
select t.eq((select count(*) from audit_log where table_name = 'lessons' and action = 'update' and after->>'gcal_event_id' = 'g1'), 0, 'Google Calendar id changes are not logged (noise)');

-- ===================================================================== platform admin
insert into platform_admins values ('00000000-0000-0000-0000-0000000000f1');
select t.as('00000000-0000-0000-0000-0000000000f1'); set role authenticated;
select t.ok((select count(*) >= 3 from platform_orgs()), 'platform admin lists organisations');
select t.ok((select plan_code = 'centre' and base_cents = 10000 and per_student_cents = 40 from platform_orgs() where org_id = t.id('centre')), 'centre plan S$100 + 40c (the foundation default; migration_fee_050.sql later moves it to 50c)');
select t.eq((select count(*) from students where org_id = t.id('centre')), 0, 'platform admin can''t read student records without a grant');
reset role;
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
insert into support_access_grants(org_id, granted_by, reason, expires_at) values (t.id('centre'), '00000000-0000-0000-0000-0000000000c1', 'Help with setup', now() + interval '1 day');
reset role;
select t.as('00000000-0000-0000-0000-0000000000f1'); set role authenticated;
select t.eq((select count(*) from students where org_id = t.id('centre')), 1, 'with the owner''s grant: read access');
select t.fails($q$ insert into students(tutor_id, org_id, name) values ('00000000-0000-0000-0000-0000000000f1', t.id('centre'), 'x') $q$, 'support access is read-only');
reset role;
update support_access_grants set revoked_at = now() where org_id = t.id('centre');
select t.as('00000000-0000-0000-0000-0000000000f1'); set role authenticated;
select t.eq((select count(*) from students where org_id = t.id('centre')), 0, 'revoked grant: no access');
reset role;
select t.as('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
select t.eq((select count(*) from platform_orgs()), 0, 'non-admin gets nothing from platform view');
reset role;

\echo ALL ORG TESTS PASSED
