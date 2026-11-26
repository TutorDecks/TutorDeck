-- T30 setup, run BEFORE db/migration_fee_050.sql: centres on the old default (S$100 + 40c), two custom deals, and a billed month.
-- Reuses the t.* helpers from org_test.sql (same throwaway database). Made-up people only.
\set ON_ERROR_STOP on
set client_min_messages = notice;
insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-0000000000f5', 'old-default@centre.test'),
  ('00000000-0000-0000-0000-0000000000f6', 'custom-rate@centre.test'),
  ('00000000-0000-0000-0000-0000000000f7', 'custom-base@centre.test');
select t.as('00000000-0000-0000-0000-0000000000f5'); set role authenticated;
select t.put('fee_old', org_create_centre('Old Default Centre', t.centre_settings()));
reset role;
select t.as('00000000-0000-0000-0000-0000000000f6'); set role authenticated;
select t.put('fee_custom_rate', org_create_centre('Custom Rate Centre', t.centre_settings()));
reset role;
select t.as('00000000-0000-0000-0000-0000000000f7'); set role authenticated;
select t.put('fee_custom_base', org_create_centre('Custom Base Centre', t.centre_settings()));
reset role;
update org_plans set per_student_cents = 35 where org_id = t.id('fee_custom_rate');                  -- a negotiated rate
update org_plans set base_cents = 12000 where org_id = t.id('fee_custom_base');                      -- a negotiated base, still 40c
-- a month already billed at 40c (append-only)
insert into platform_fee_snapshots(org_id, month, active_students, billable_students, base_cents, per_student_cents, fee_cents)
  values (t.id('fee_old'), '2026-10-01', 403, 400, 10000, 40, 26000);
select t.ok((select base_cents = 10000 and per_student_cents = 40 from org_plans where org_id = t.id('fee_old')), 'before: a new centre starts at S$100 + 40c');
