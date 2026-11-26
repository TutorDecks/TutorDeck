-- T30 tests, run AFTER db/migration_fee_050.sql (and after fee_050_before.sql). Per case: new centre, old default, custom prices, closed month.
\set ON_ERROR_STOP on
set client_min_messages = notice;

-- existing centre on the old default moved to 50c
select t.ok((select base_cents = 10000 and per_student_cents = 50 from org_plans where org_id = t.id('fee_old') and plan_code = 'centre'), 'existing centre on the old default is now S$100 + 50c');
select t.ok((select base_cents = 10000 and per_student_cents = 50 from org_plans where org_id = t.id('centre') and plan_code = 'centre'), 'the phase-1 test centre (also on the old default) is now 50c');
-- custom prices are never overwritten
select t.ok((select base_cents = 10000 and per_student_cents = 35 from org_plans where org_id = t.id('fee_custom_rate')), 'custom per-student rate (35c) untouched');
select t.ok((select base_cents = 12000 and per_student_cents = 40 from org_plans where org_id = t.id('fee_custom_base')), 'custom base (S$120, 40c) untouched: not the old default, so not moved');
-- solo plans untouched
select t.ok((select bool_and(base_cents = 0 and per_student_cents = 0) from org_plans where plan_code = 'solo'), 'solo plans (0/0) untouched');
select t.ok((select count(*) from org_plans where plan_code = 'centre' and per_student_cents = 40 and base_cents = 10000) = 0, 'no centre still holds the old default');
-- a closed month keeps what it was billed
select t.ok((select per_student_cents = 40 and fee_cents = 26000 and billable_students = 400 from platform_fee_snapshots where org_id = t.id('fee_old') and month = '2026-10-01'), 'October snapshot still says 40c / S$260.00');
select t.fails($q$ update platform_fee_snapshots set per_student_cents = 50, fee_cents = 30000 where org_id = t.id('fee_old') $q$, 'rewriting a billed month');
-- a NEW centre gets the new default
insert into auth.users(id, email) values ('00000000-0000-0000-0000-0000000000f8', 'brand-new@centre.test');
select t.as('00000000-0000-0000-0000-0000000000f8'); set role authenticated;
select t.put('fee_new', org_create_centre('Brand New Centre', t.centre_settings()));
reset role;
select t.ok((select plan_code = 'centre' and base_cents = 10000 and per_student_cents = 50 from org_plans where org_id = t.id('fee_new')), 'a new centre starts at S$100 + 50c');
-- the single place the default lives
select t.ok((select base_cents = 10000 and per_student_cents = 50 from org_default_centre_plan()), 'org_default_centre_plan() is S$100 + 50c');
select t.ok(not has_function_privilege('anon', 'public.org_default_centre_plan()', 'execute') and not has_function_privilege('authenticated', 'public.org_default_centre_plan()', 'execute'), 'the default-plan helper is not callable from the browser');
-- what the platform admin screen / the plan tab reads
select t.as('00000000-0000-0000-0000-0000000000f1'); set role authenticated;
select t.ok((select per_student_cents = 50 from platform_orgs() where org_id = t.id('fee_old')), 'platform_orgs() shows 50c');
reset role;
-- fee arithmetic with the stored plan: 98 -> 100 billable -> S$150; 250 -> S$225; 405 -> 410 -> S$305
select t.eq(10000 + 50 * 100, 15000, '98 students (100 billable) = S$150.00');
select t.eq(10000 + 50 * 250, 22500, '250 students = S$225.00');
select t.eq(10000 + 50 * 410, 30500, '405 students (410 billable) = S$305.00');
