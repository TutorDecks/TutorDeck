-- T36 tests, run AFTER db/migration_centre_billing_start.sql (and after the centre_billing_method tests, which reuse the same centres).
\set ON_ERROR_STOP on
set client_min_messages = notice;
-- defaults: no restriction anywhere; the October snapshot from the T30 setup is a normal billable month
select t.ok((select bool_and(billing_starts_on is null and first_month_billable_override is null and billing_start_reason is null) from org_plans), 'no plan has a billing start by default (nothing changes for anyone)');
select t.ok((select billable and waived_reason is null and override_students is null from platform_fee_snapshots where org_id = t.id('fee_old') and month = '2026-10-01'), 'an existing snapshot reads as a normal billable month');
-- the table refuses nonsense
select t.fails($q$ update org_plans set billing_starts_on = '2027-02-15' where org_id = t.id('fee_custom_base') $q$, 'a start that is not the 1st');
select t.fails($q$ update org_plans set first_month_billable_override = 80 where org_id = t.id('fee_custom_base') $q$, 'an agreed number without a start date');
select t.fails($q$ update org_plans set billing_starts_on = '2027-02-01', first_month_billable_override = -1 where org_id = t.id('fee_custom_base') $q$, 'a negative agreed number');
-- a centre owner cannot set it, directly or through the function; anonymous cannot call it
select t.as('00000000-0000-0000-0000-0000000000f6'); set role authenticated;
select t.fails($q$ select org_set_billing_start(t.id('fee_custom_rate'), '2027-02-01', 80, 'owner trying') $q$, 'the centre owner setting its own start');
update org_plans set billing_starts_on = '2027-02-01' where org_id = t.id('fee_custom_rate');      -- no update policy: changes nothing
reset role;
select t.ok((select billing_starts_on is null from org_plans where org_id = t.id('fee_custom_rate')), 'still unset after the refused attempts');
select t.ok(not has_function_privilege('anon', 'public.org_set_billing_start(uuid,date,int,text)', 'execute'), 'anonymous cannot call the setter');
-- the platform admin: validation first
select t.as('00000000-0000-0000-0000-0000000000f1'); set role authenticated;
select t.fails($q$ select org_set_billing_start(t.id('fee_custom_base'), '2027-02-01', 85, null) $q$, 'no reason');
select t.fails($q$ select org_set_billing_start(t.id('fee_custom_base'), '2027-02-01', 85, '  ') $q$, 'a blank reason');
select t.fails($q$ select org_set_billing_start(t.id('fee_custom_base'), '2027-02-10', 85, 'agreed start') $q$, 'a start that is not the 1st');
select t.fails($q$ select org_set_billing_start(t.id('fee_custom_base'), null, 85, 'agreed start') $q$, 'an agreed number without a start');
select t.fails($q$ select org_set_billing_start(t.id('fee_custom_base'), '2027-02-01', -5, 'agreed start') $q$, 'a negative agreed number');
select t.fails($q$ select org_set_billing_start((select org_id from org_plans where plan_code = 'solo' limit 1), '2027-02-01', null, 'solo') $q$, 'a solo organisation');
select t.fails($q$ select org_set_billing_start(null, '2027-02-01', null, 'nobody') $q$, 'no organisation');
-- ... then it works, for one centre only
select org_set_billing_start(t.id('fee_custom_base'), '2027-02-01', 85, 'Free pilot until February; agreed starting number');
reset role;
select t.ok((select billing_starts_on = '2027-02-01' and first_month_billable_override = 85 and billing_start_reason like 'Free pilot%' from org_plans where org_id = t.id('fee_custom_base')), 'start, agreed number and reason are saved');
select t.ok((select billing_starts_on is null from org_plans where org_id = t.id('fee_custom_rate')) and (select billing_starts_on is null from org_plans where org_id = t.id('fee_old')), 'other centres untouched');
select t.ok((select count(*) from audit_log where org_id = t.id('fee_custom_base') and table_name = 'org_plans' and action = 'update' and after->>'billing_start_reason' like 'Free pilot%' and before->>'billing_starts_on' is null) = 1, 'the change, with its reason, is in the audit log');
-- the centre owner can read it (the Plan tab needs it)
select t.as('00000000-0000-0000-0000-0000000000f7'); set role authenticated;
select t.ok((select billing_starts_on = '2027-02-01' from org_plans where org_id = t.id('fee_custom_base') and plan_code = 'centre' limit 1), 'the centre owner can read its start date');
reset role;
-- snapshot shapes
insert into platform_fee_snapshots(org_id, month, active_students, billable_students, base_cents, per_student_cents, fee_cents, billable, waived_reason)
  values (t.id('fee_custom_base'), '2027-01-01', 12, 10, 12000, 40, 0, false, 'pilot');
select t.ok((select not billable and waived_reason = 'pilot' and fee_cents = 0 and active_students = 12 from platform_fee_snapshots where org_id = t.id('fee_custom_base') and month = '2027-01-01'), 'a pilot month is recorded for information: counted, not billable, fee 0');
select t.fails($q$ insert into platform_fee_snapshots(org_id, month, active_students, billable_students, base_cents, per_student_cents, fee_cents, billable, waived_reason) values (t.id('fee_custom_base'), '2026-12-01', 12, 10, 12000, 40, 500, false, 'pilot') $q$, 'a waived month cannot carry a fee');
select t.fails($q$ insert into platform_fee_snapshots(org_id, month, active_students, billable_students, base_cents, per_student_cents, fee_cents, billable) values (t.id('fee_custom_base'), '2026-12-01', 12, 10, 12000, 40, 0, false) $q$, 'a non-billable month needs a reason');
select t.fails($q$ insert into platform_fee_snapshots(org_id, month, active_students, billable_students, base_cents, per_student_cents, fee_cents, waived_reason) values (t.id('fee_custom_base'), '2026-12-01', 12, 10, 12000, 40, 12400, 'pilot') $q$, 'a billable month cannot carry a waiver reason');
select t.fails($q$ update platform_fee_snapshots set billable = true, waived_reason = null, fee_cents = 12400 where org_id = t.id('fee_custom_base') and month = '2027-01-01' $q$, 'a closed pilot snapshot cannot be rewritten');
-- the pilot snapshot (a month BEFORE the start) does not block a correction of the agreed number ...
select t.as('00000000-0000-0000-0000-0000000000f1'); set role authenticated;
select org_set_billing_start(t.id('fee_custom_base'), '2027-02-01', 90, 'Agreed number corrected');
reset role;
select t.ok((select first_month_billable_override = 90 from org_plans where org_id = t.id('fee_custom_base')), 'the agreed number can still change while the first billed month is open');
-- ... and the start can still move LATER (pilot extended), but not into a recorded month
select t.as('00000000-0000-0000-0000-0000000000f1'); set role authenticated;
select org_set_billing_start(t.id('fee_custom_base'), '2027-03-01', 90, 'Pilot extended by a month');
reset role;
select t.ok((select billing_starts_on = '2027-03-01' from org_plans where org_id = t.id('fee_custom_base')), 'pilot extended');
insert into platform_fee_snapshots(org_id, month, active_students, billable_students, base_cents, per_student_cents, fee_cents, billable, waived_reason)
  values (t.id('fee_custom_base'), '2027-02-01', 14, 10, 12000, 40, 0, false, 'pilot');
select t.as('00000000-0000-0000-0000-0000000000f1'); set role authenticated;
select t.fails($q$ select org_set_billing_start(t.id('fee_custom_base'), '2027-02-01', 90, 'Start earlier than a recorded month') $q$, 'moving the start back onto a month already recorded as a pilot');
reset role;
-- the first billed month (with the agreed number) gets recorded
insert into platform_fee_snapshots(org_id, month, active_students, billable_students, base_cents, per_student_cents, fee_cents, override_students)
  values (t.id('fee_custom_base'), '2027-03-01', 14, 90, 12000, 40, 12000 + 40 * 90, 90);
select t.ok((select billable and override_students = 90 and active_students = 14 and fee_cents = 15600 from platform_fee_snapshots where org_id = t.id('fee_custom_base') and month = '2027-03-01'), 'the first month stores the real count (14), the agreed number used (90) and the fee on it');
select t.fails($q$ insert into platform_fee_snapshots(org_id, month, active_students, billable_students, base_cents, per_student_cents, fee_cents, billable, waived_reason, override_students) values (t.id('fee_custom_base'), '2027-04-01', 14, 10, 12000, 40, 0, false, 'pilot', 90) $q$, 'an agreed number on a waived month');
-- now the first billed month is closed: nothing can be changed any more (agreed number, date, or clearing it)
select t.as('00000000-0000-0000-0000-0000000000f1'); set role authenticated;
select t.fails($q$ select org_set_billing_start(t.id('fee_custom_base'), '2027-03-01', 40, 'set after the snapshot exists') $q$, 'changing the agreed number after the first month is closed');
select t.fails($q$ select org_set_billing_start(t.id('fee_custom_base'), '2027-05-01', 90, 'moving the start forward') $q$, 'moving the start after its month is closed');
select t.fails($q$ select org_set_billing_start(t.id('fee_custom_base'), null, null, 'clearing it') $q$, 'clearing the start after its month is closed');
reset role;
select t.ok((select billing_starts_on = '2027-03-01' and first_month_billable_override = 90 from org_plans where org_id = t.id('fee_custom_base')), 'the plan is exactly as it was');
-- a centre that already has billed months (fee_old, October) cannot be given a start at or before them, but can get one for the future
select t.as('00000000-0000-0000-0000-0000000000f1'); set role authenticated;
select t.fails($q$ select org_set_billing_start(t.id('fee_old'), '2026-09-01', null, 'back in time') $q$, 'a start before an already-billed month');
select t.fails($q$ select org_set_billing_start(t.id('fee_old'), '2026-10-01', 50, 'onto a billed month') $q$, 'a start ON an already-billed month');
select org_set_billing_start(t.id('fee_old'), '2027-06-01', null, 'future start, no agreed number');
reset role;
select t.ok((select billing_starts_on = '2027-06-01' and first_month_billable_override is null from org_plans where org_id = t.id('fee_old')), 'a future start with no agreed number');
select t.ok((select billable and fee_cents = 26000 from platform_fee_snapshots where org_id = t.id('fee_old') and month = '2026-10-01'), 'October still says S$260.00, billable');
