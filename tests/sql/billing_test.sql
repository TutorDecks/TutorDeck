-- Billing tests: grandfathering, the 5-active-student gate, who can read/write subscriptions.
-- Runs after org_test.sql in the same throwaway database (reuses its t.* helpers). Made-up people only.
\set ON_ERROR_STOP on
set client_min_messages = notice;

-- ===================================================================== grandfathering
select t.ok((select grandfathered from org_subscriptions where org_id = t.id('tina_org')), 'existing solo tutor (Tina) is grandfathered');
select t.ok((select grandfathered from org_subscriptions where org_id = t.id('ben_org')), 'existing solo tutor (Ben) is grandfathered');
select t.ok((select tier = 'centre' and not grandfathered from org_subscriptions where org_id = t.id('centre')), 'centre gets a centre row, not grandfathered');

-- Tina has 3 students; grandfathered means no limit
create temp table tina_before as select count(*)::int n from students where org_id = t.id('tina_org');
grant select on tina_before to authenticated;
select t.as('00000000-0000-0000-0000-0000000000a1'); set role authenticated;
insert into students(tutor_id, name) select '00000000-0000-0000-0000-0000000000a1', 'Extra ' || g from generate_series(1, 6) g;
select t.ok((select count(*) from students where org_id = t.id('tina_org')) = (select n + 6 from tina_before) and (select n + 6 from tina_before) > 5, 'grandfathered tutor can go past 5 students');
reset role;

-- ===================================================================== a NEW solo tutor gets the free tier
insert into auth.users(id, email) values ('00000000-0000-0000-0000-0000000000e9', 'new@solo.test');
select t.put('nina_org', org_personal('00000000-0000-0000-0000-0000000000e9'));
select t.ok((select tier = 'free' and not grandfathered and status = 'none' from org_subscriptions where org_id = t.id('nina_org')), 'new solo tutor: free tier, not grandfathered');
select t.eq(org_free_limit(), 5, 'free limit is 5');

select t.as('00000000-0000-0000-0000-0000000000e9'); set role authenticated;
insert into students(tutor_id, name) select '00000000-0000-0000-0000-0000000000e9', 'S' || g from generate_series(1, 5) g;
select t.eq(org_active_students(t.id('nina_org')), 5, '5 active students allowed on the free tier');
select t.fails($q$ insert into students(tutor_id, name) values ('00000000-0000-0000-0000-0000000000e9', 'Sixth') $q$, 'adding a 6th active student on the free tier');
select t.ok((org_plan_status(t.id('nina_org'))->>'can_add_student')::boolean = false, 'plan screen says no more students');
reset role;

-- a discontinued / inactive student doesn't count, and can be added at 5
select t.as('00000000-0000-0000-0000-0000000000e9'); set role authenticated;
update students set end_date = current_date - 1 where org_id = t.id('nina_org') and name = 'S5';
select t.eq(org_active_students(t.id('nina_org')), 4, 'a student past their end date is not active');
insert into students(tutor_id, name) values ('00000000-0000-0000-0000-0000000000e9', 'Replacement');
select t.eq(org_active_students(t.id('nina_org')), 5, 'a replacement fits back in');
-- reactivating the discontinued one would be a 6th
select t.fails($q$ update students set end_date = null where org_id = t.id('nina_org') and name = 'S5' $q$, 'reactivating a student beyond the limit');
-- adding an already-inactive student is fine
insert into students(tutor_id, name, active) values ('00000000-0000-0000-0000-0000000000e9', 'Old', false);
reset role;

-- ===================================================================== Solo Pro lifts the limit; cancelling brings it back
update org_subscriptions set tier = 'pro', status = 'trialing', trial_end = now() + interval '30 days' where org_id = t.id('nina_org');
select t.as('00000000-0000-0000-0000-0000000000e9'); set role authenticated;
insert into students(tutor_id, name) values ('00000000-0000-0000-0000-0000000000e9', 'Sixth');
select t.eq(org_active_students(t.id('nina_org')), 6, 'trial of Solo Pro: 6th student allowed');
reset role;
update org_subscriptions set status = 'active' where org_id = t.id('nina_org');
select t.ok(org_has_pro(t.id('nina_org')), 'active subscription = Pro');
update org_subscriptions set status = 'canceled' where org_id = t.id('nina_org');
select t.ok(not org_has_pro(t.id('nina_org')), 'cancelled = not Pro');
select t.as('00000000-0000-0000-0000-0000000000e9'); set role authenticated;
select t.fails($q$ insert into students(tutor_id, name) values ('00000000-0000-0000-0000-0000000000e9', 'Seventh') $q$, 'after cancelling, new students blocked again');
select t.eq((select count(*) from students where org_id = t.id('nina_org')), 8, 'existing students are never deleted or hidden');
reset role;

-- centres are not gated by the solo rule
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select t.ok((org_plan_status(t.id('centre'))->>'can_add_student')::boolean, 'centre is not subject to the solo free limit');
reset role;

-- ===================================================================== who can read / write
select t.as('00000000-0000-0000-0000-0000000000e9'); set role authenticated;
select t.eq((select count(*) from org_subscriptions), 1, 'a tutor sees only their own subscription row');
select t.fails($q$ update org_subscriptions set tier = 'pro', status = 'active' where org_id = t.id('nina_org') $q$, 'tutor upgrading themselves for free');
select t.fails($q$ insert into stripe_events(id, type) values ('evt_x', 'x') $q$, 'tutor writing webhook events');
select t.fails($q$ select count(*) from stripe_events $q$, 'tutor reading webhook events');
select t.fails($q$ select org_plan_status(t.id('tina_org')) $q$, 'reading another organisation''s plan status');
reset role;
select t.as('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
select t.eq((select count(*) from org_subscriptions where org_id = t.id('nina_org')), 0, 'another tutor can''t see Nina''s subscription');
select t.fails($q$ select org_has_pro(t.id('nina_org')) $q$, 'calling the internal helper org_has_pro from the browser');
reset role;
-- the server (service role) can write
set role service_role;
update org_subscriptions set stripe_customer_id = 'cus_test1' where org_id = t.id('nina_org');
insert into stripe_events(id, type) values ('evt_1', 'customer.subscription.updated');
select t.fails($q$ insert into stripe_events(id, type) values ('evt_1', 'customer.subscription.updated') $q$, 'the same webhook event processed twice');
reset role;
select t.fails($q$ update org_subscriptions set stripe_customer_id = 'cus_test1' where org_id = t.id('tina_org') $q$, 'two organisations sharing one Stripe customer');

-- the audit log records changes to subscriptions
select t.ok((select count(*) >= 1 from audit_log where table_name = 'org_subscriptions' and org_id = t.id('nina_org')), 'subscription changes are in the audit log');

-- ===================================================================== one big insert can't slip past the limit
-- (the check counts rows already inserted by the SAME statement, and a refused statement inserts nothing)
insert into auth.users(id, email) values ('00000000-0000-0000-0000-0000000000e8', 'bulk@solo.test');
select t.put('bulk_org', org_personal('00000000-0000-0000-0000-0000000000e8'));
select t.as('00000000-0000-0000-0000-0000000000e8'); set role authenticated;
select t.fails($q$ insert into students(tutor_id, name) select '00000000-0000-0000-0000-0000000000e8', 'B' || g from generate_series(1, 8) g $q$, 'adding 8 students in ONE statement on the free tier');
select t.eq((select count(*) from students where org_id = t.id('bulk_org')), 0, 'the refused statement inserted nothing (all or nothing)');
insert into students(tutor_id, name) select '00000000-0000-0000-0000-0000000000e8', 'B' || g from generate_series(1, 5) g;
select t.eq(org_active_students(t.id('bulk_org')), 5, 'exactly 5 in one statement is fine');
reset role;

\echo ALL BILLING TESTS PASSED
