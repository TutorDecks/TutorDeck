-- T31a tests, run AFTER db/migration_centre_billing_method.sql (and after the fee_050 tests, which created the centres used here).
\set ON_ERROR_STOP on
set client_min_messages = notice;
-- every existing centre defaults to stripe; solo plans too (the column exists everywhere, only centres can change it)
select t.ok((select bool_and(billing_method = 'stripe') from org_plans), 'every existing plan defaults to stripe');
select t.ok((select billing_method = 'stripe' from org_plans where org_id = t.id('fee_new')), 'a new centre starts on stripe');
select t.fails($q$ update org_plans set billing_method = 'cash' where org_id = t.id('fee_old') $q$, 'an unknown method is refused by the table');
-- a centre owner (and a plain user) cannot change it, directly or through the function
select t.as('00000000-0000-0000-0000-0000000000f5'); set role authenticated;
select t.fails($q$ select org_set_billing_method(t.id('fee_old'), 'invoice') $q$, 'the centre owner switching the method');
update org_plans set billing_method = 'invoice' where org_id = t.id('fee_old');      -- row-level security: no update policy, so this changes nothing
reset role;
select t.ok((select billing_method = 'stripe' from org_plans where org_id = t.id('fee_old')), 'still stripe after the refused attempts (function refused, direct update changed nothing)');
select t.ok(not has_function_privilege('anon', 'public.org_set_billing_method(uuid,text)', 'execute'), 'anonymous cannot call the setter');
-- a platform admin can
select t.as('00000000-0000-0000-0000-0000000000f1'); set role authenticated;
select org_set_billing_method(t.id('fee_old'), 'invoice');
select t.fails($q$ select org_set_billing_method(t.id('fee_old'), 'paypal') $q$, 'admin setting an unknown method');
select t.fails($q$ select org_set_billing_method(null, 'invoice') $q$, 'admin setting it on no organisation');
reset role;
select t.ok((select billing_method = 'invoice' from org_plans where org_id = t.id('fee_old')), 'the platform admin switched the centre to invoice');
select t.ok((select billing_method = 'stripe' from org_plans where org_id = t.id('fee_custom_rate')), 'other centres are untouched');
select t.ok((select count(*) from audit_log where org_id = t.id('fee_old') and table_name = 'org_plans' and action = 'update') >= 1, 'the change is in the audit log');
-- the owner can READ it (the Plan tab needs it) but only its own centre's
select t.as('00000000-0000-0000-0000-0000000000f5'); set role authenticated;
select t.ok((select billing_method = 'invoice' from org_plans where org_id = t.id('fee_old') and plan_code = 'centre' limit 1), 'the centre owner can read the method');
select t.ok((select count(*) from org_plans where plan_code = 'centre' and org_id <> t.id('fee_old')) = 0, 'and sees no other organisation''s plan');
reset role;
-- switching back, and a solo organisation has no billing method to set
select t.as('00000000-0000-0000-0000-0000000000f1'); set role authenticated;
select org_set_billing_method(t.id('fee_old'), 'stripe');
select t.fails($q$ select org_set_billing_method((select org_id from org_plans where plan_code = 'solo' limit 1), 'invoice') $q$, 'admin switching a solo organisation');
reset role;
select t.ok((select billing_method = 'stripe' from org_plans where org_id = t.id('fee_old')), 'switched back to stripe');
-- a closed month is not affected by the method (snapshots are append-only and have no method column)
select t.ok((select count(*) from platform_fee_snapshots where org_id = t.id('fee_old') and month = '2026-10-01') = 1, 'billed month still there');
