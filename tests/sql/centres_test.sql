-- Scenario tests for db/migration_centres.sql. Run on a THROWAWAY local Postgres only:
--   bash tests/sql/run.sh
-- Every check prints PASS; the first failure stops the run.
\set ON_ERROR_STOP on
\set QUIET on
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
create function t.as(u text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, false) $$;
grant execute on all functions in schema t to authenticated, service_role;

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'owner@opus.test'),
  ('00000000-0000-0000-0000-00000000000b', 'staff@opus.test'),
  ('00000000-0000-0000-0000-00000000000c', 'tutor1@opus.test'),
  ('00000000-0000-0000-0000-00000000000d', 'tutor2@opus.test'),
  ('00000000-0000-0000-0000-00000000000e', 'outsider@other.test');
insert into auth.users(id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-00000000000f', 'newtutor@opus.test', now()),
  ('00000000-0000-0000-0000-000000000010', 'faker@opus.test', null);
insert into public.profiles(id, full_name) values ('00000000-0000-0000-0000-00000000000a', 'Olivia Owner');

-- ======================================================================= setup as the owner
select t.as('00000000-0000-0000-0000-00000000000a');
set role authenticated;
select t.put('centre', td_create_centre('Opus Tuition'));
select t.ok((select count(*) = 5 from centre_roles where centre_id = t.id('centre')), 'centre seeded with 5 roles');
select t.ok((select display_name = 'Olivia Owner' from centre_members where user_id = auth.uid()), 'creator is the owner member');

-- GST registered, 9%, prices exclusive
update centres set gst_registered = true, gst_rate = 9, gst_inclusive = false, invoice_prefix = 'OPUS' where id = t.id('centre');
select t.ok((select count(*) >= 1 from centre_audit_log where action = 'settings.update'), 'settings change audited');

-- members
insert into centre_members(centre_id, user_id, email, display_name, role_id)
select t.id('centre'), '00000000-0000-0000-0000-00000000000b', 'staff@opus.test', 'Sam Staff', id from centre_roles where centre_id = t.id('centre') and key = 'staff';
insert into centre_members(centre_id, user_id, email, display_name, role_id)
select t.id('centre'), '00000000-0000-0000-0000-00000000000c', 'tutor1@opus.test', 'Tina Tutor', id from centre_roles where centre_id = t.id('centre') and key = 'tutor';
insert into centre_members(centre_id, user_id, email, display_name, role_id)
select t.id('centre'), '00000000-0000-0000-0000-00000000000d', 'tutor2@opus.test', 'Tom Tutor', id from centre_roles where centre_id = t.id('centre') and key = 'tutor';
select t.put('t1', (select id from centre_members where display_name = 'Tina Tutor'));
select t.put('t2', (select id from centre_members where display_name = 'Tom Tutor'));
select t.fails($q$ insert into centre_members(centre_id, display_name, role_id)
  select t.id('centre'), 'Sneaky', id from centre_roles where centre_id = t.id('centre') and key = 'owner' $q$, 'adding a second owner by insert');

-- policies: default postpay gets a 10% sibling discount, late cancel 50%, late fee $10 after 7 days
update billing_policies set config = '{"cycle":"monthly","due_days":7,
  "sibling_discount":{"type":"percent","value":10},
  "cancellation":{"late_charge_pct":50,"pay_tutor_late_cancel":false,"no_show_charge_pct":100},
  "late_fee":{"type":"fixed","value":10,"after_days":7,"max_times":2}}'
 where centre_id = t.id('centre') and is_default;
insert into billing_policies(centre_id, name, model, config) values (t.id('centre'), 'Prepaid packages', 'prepay',
  '{"due_days":3,"no_balance":"charge","unused":{"action":"credit"},"cancellation":{"late_charge_pct":50},
    "late_fee":{"type":"fixed","value":10,"after_days":7,"max_times":2}}');
select t.put('prepay', (select id from billing_policies where name = 'Prepaid packages'));

-- tutor pay: centre default $30/h; Tom gets 50% of fee
insert into tutor_pay_rules(centre_id, basis, rate) values (t.id('centre'), 'per_hour', 30);
insert into tutor_pay_rules(centre_id, tutor_member_id, basis, rate) values (t.id('centre'), t.id('t2'), 'percent_of_fee', 50);
select t.eq((select rate from td_pay_rule_for(t.id('centre'), t.id('t2'), null, 'Maths', 'Sec 3')), 50, 'most specific pay rule wins for Tom');
select t.eq((select rate from td_pay_rule_for(t.id('centre'), t.id('t1'), null, 'Maths', 'Sec 3')), 30, 'centre default pay rule for Tina');

-- households & students
insert into households(centre_id, name) values (t.id('centre'), 'Tan family'), (t.id('centre'), 'Lim family');
select t.put('h1', (select id from households where name = 'Tan family'));
select t.put('h2', (select id from households where name = 'Lim family'));
insert into centre_students(centre_id, household_id, name, level, created_at) values
  (t.id('centre'), t.id('h1'), 'Alice Tan', 'Sec 3', now() - interval '2 days'),
  (t.id('centre'), t.id('h1'), 'Ben Tan', 'Sec 3', now() - interval '1 day');
insert into centre_students(centre_id, household_id, name, level, billing_policy_id) values
  (t.id('centre'), t.id('h2'), 'Chloe Lim', 'Sec 3', t.id('prepay'));
select t.put('s1', (select id from centre_students where name = 'Alice Tan'));
select t.put('s2', (select id from centre_students where name = 'Ben Tan'));
select t.put('s3', (select id from centre_students where name = 'Chloe Lim'));

-- classes: group Maths $40/h by Tina; 1-to-1 $60/lesson by Tom
insert into centre_classes(centre_id, name, kind, subject, level, tutor_member_id, fee_amount, fee_unit)
values (t.id('centre'), 'Sec 3 Maths (group)', 'group', 'Maths', 'Sec 3', t.id('t1'), 40, 'per_hour');
insert into centre_classes(centre_id, name, kind, subject, level, tutor_member_id, fee_amount, fee_unit)
values (t.id('centre'), 'Chloe 1-to-1 Physics', 'individual', 'Physics', 'Sec 3', t.id('t2'), 60, 'per_lesson');
select t.put('c1', (select id from centre_classes where kind = 'group'));
select t.put('c2', (select id from centre_classes where kind = 'individual'));
insert into centre_enrolments(centre_id, class_id, student_id) values
  (t.id('centre'), t.id('c1'), t.id('s1')), (t.id('centre'), t.id('c1'), t.id('s2')), (t.id('centre'), t.id('c1'), t.id('s3')),
  (t.id('centre'), t.id('c2'), t.id('s3'));

-- lesson 1: 2-hour group lesson; Chloe cancels late
insert into centre_lessons(centre_id, class_id, tutor_member_id, lesson_date, start_time, end_time)
values (t.id('centre'), t.id('c1'), t.id('t1'), '2026-11-02', '16:00', '18:00');
select t.put('l1', (select id from centre_lessons where lesson_date = '2026-11-02'));
insert into centre_lesson_attendees(centre_id, lesson_id, student_id, status) values
  (t.id('centre'), t.id('l1'), t.id('s1'), 'present'), (t.id('centre'), t.id('l1'), t.id('s2'), 'present'),
  (t.id('centre'), t.id('l1'), t.id('s3'), 'late_cancel');

-- ======================================================================= tutors
reset role; select t.as('00000000-0000-0000-0000-00000000000c'); set role authenticated;
select t.ok((select count(*) = 1 from centre_lessons), 'Tina sees her own lesson');
select td_submit_remarks(t.id('l1'), 'Covered quadratics; Ben needs practice on factorising.');
select t.ok((select remarks like 'Covered%' from centre_lessons where id = t.id('l1')), 'Tina saved remarks');
select t.fails($q$ select td_deliver_lesson(t.id('l1')) $q$, 'tutor delivering (billing) a lesson');
update centre_lessons set start_time = '15:00' where id = t.id('l1');
reset role; select t.ok((select start_time = '16:00' from centre_lessons where id = t.id('l1')), 'tutor UPDATE on lessons changes nothing (no policy)');
select t.as('00000000-0000-0000-0000-00000000000c'); set role authenticated;
select t.ok((select count(*) = 0 from centre_charges), 'tutor cannot read charges');
select t.ok((select count(*) = 0 from households), 'tutor cannot read households');
reset role; select t.as('00000000-0000-0000-0000-00000000000d'); set role authenticated;
select t.ok((select count(*) = 0 from centre_lessons), 'Tom cannot see Tina''s lesson');
select t.fails($q$ select td_submit_remarks(t.id('l1'), 'hi') $q$, 'remarks on someone else''s lesson');
reset role; select t.as('00000000-0000-0000-0000-00000000000e'); set role authenticated;
select t.ok((select count(*) = 0 from centres), 'outsider sees no centre');
select t.fails($q$ select td_create_payout_batch(t.id('centre'), '2026-12-31') $q$, 'outsider making a payout batch');

-- ======================================================================= deliver (staff)
reset role; select t.as('00000000-0000-0000-0000-00000000000b'); set role authenticated;
select td_deliver_lesson(t.id('l1'));
-- Alice: 2h x $40 = 80 + 9% = 87.20 ; Ben: 80 - 10% sibling = 72 + 6.48 = 78.48 ; Chloe late cancel 50% = 40 + 3.60
select t.eq((select total from centre_charges where student_id = t.id('s1')), 87.20, 'Alice lesson total incl GST');
select t.eq((select total from centre_charges where student_id = t.id('s2')), 78.48, 'Ben total after sibling discount + GST');
select t.eq((select discount from centre_charges where student_id = t.id('s2')), 8.00, 'Ben sibling discount');
select t.eq((select total from centre_charges where student_id = t.id('s3')), 43.60, 'Chloe late-cancel charge (50%) incl GST');
reset role;
select t.eq((select sum(amount) from centre_earnings where lesson_id = t.id('l1')), 60, 'Tina earns 2h x $30 (late cancel not paid)');
select t.ok((select count(*) = 2 and bool_and(status = 'pending') from centre_earnings where lesson_id = t.id('l1')), 'earnings start pending');
select t.put('e_alice', (select e.id from centre_earnings e join centre_charges c on c.id = e.charge_id where c.student_id = t.id('s1')));
select t.put('e_ben', (select e.id from centre_earnings e join centre_charges c on c.id = e.charge_id where c.student_id = t.id('s2')));

-- ======================================================================= the rule can't be bypassed
select t.fails($q$ update centre_earnings set status = 'payable' where id = t.id('e_alice') $q$, 'SQL editor forcing an unpaid earning to payable');
select t.fails($q$ update centres set payout_rule = 'on_delivery' where id = t.id('centre') $q$, 'SQL editor flipping the payout rule');
select t.fails($q$ delete from centre_audit_log $q$, 'deleting the audit log');
select t.fails($q$ update centre_audit_log set reason = 'x' $q$, 'editing the audit log');
select t.fails($q$ update centre_earnings set status = 'batched' where id = t.id('e_alice') $q$, 'batching a pending earning');
select t.fails($q$ insert into centre_earnings(centre_id, tutor_member_id, kind, amount, status) values (t.id('centre'), t.id('t1'), 'adjustment', 500, 'payable') $q$, 'unaudited manual bonus');
select t.as('00000000-0000-0000-0000-00000000000a'); set role authenticated;
update centre_earnings set status = 'payable' where id = t.id('e_alice');
reset role; select t.ok((select status = 'pending' from centre_earnings where id = t.id('e_alice')), 'admin UPDATE on earnings changes nothing (no policy)');

-- ======================================================================= invoices + partial payment
select t.as('00000000-0000-0000-0000-00000000000a'); set role authenticated;
select t.eq(td_generate_invoices(t.id('centre'), '2026-11-30'), 2, 'one invoice per household');
select t.put('inv1', (select id from centre_invoices where household_id = t.id('h1')));
select t.put('inv2', (select id from centre_invoices where household_id = t.id('h2')));
select t.eq((select total from centre_invoices where id = t.id('inv1')), 165.68, 'Tan invoice total');
select t.ok((select number like 'OPUS-%' from centre_invoices where id = t.id('inv1')), 'invoice uses centre prefix');

reset role; select t.as('00000000-0000-0000-0000-00000000000b'); set role authenticated;
select t.fails($q$ select td_record_payment(t.id('centre'), t.id('h1'), t.id('inv1'), 'bank', 100, '2026-12-03', 'x', true) $q$, 'staff marking a payment reconciled');
select t.put('pay1', td_record_payment(t.id('centre'), t.id('h1'), t.id('inv1'), 'bank', 100, '2026-12-03', 'DBS 123', false));
reset role;
select t.ok((select status = 'pending' from centre_earnings where id = t.id('e_alice')), 'recorded-but-unreconciled payment does not release pay');
select t.as('00000000-0000-0000-0000-00000000000a'); set role authenticated;
select td_reconcile_payment(t.id('pay1'));
reset role;
select t.ok((select status = 'payable' from centre_earnings where id = t.id('e_alice')), 'partial payment covers the oldest line: Alice payable');
select t.ok((select status = 'pending' from centre_earnings where id = t.id('e_ben')), 'Ben line only part-paid: still pending');
select t.ok((select status = 'partially_paid' and paid = 100 from centre_invoices where id = t.id('inv1')), 'invoice partially paid');

-- ======================================================================= payout batch 1
select t.as('00000000-0000-0000-0000-00000000000a'); set role authenticated;
select t.put('b1', td_create_payout_batch(t.id('centre'), '2026-11-30'));
select t.eq((select total from centre_payout_batches where id = t.id('b1')), 30, 'batch 1 holds only the payable $30');
select td_mark_batch_paid(t.id('b1'), 'PayNow batch Nov');
reset role;
select t.ok((select status = 'paid' from centre_earnings where id = t.id('e_alice')), 'Alice earning paid');
select t.fails($q$ update centre_earnings set status = 'pending' where id = t.id('e_alice') $q$, 're-opening a paid earning');

-- ======================================================================= dispute holds pay
select t.as('00000000-0000-0000-0000-00000000000a'); set role authenticated;
select td_set_dispute(t.id('inv1'), true, 'Parent says Ben was absent');
reset role; select t.ok((select status = 'held' from centre_earnings where id = t.id('e_ben')), 'disputed invoice holds Ben''s earning');
select t.as('00000000-0000-0000-0000-00000000000a'); set role authenticated;
select td_record_payment(t.id('centre'), t.id('h1'), t.id('inv1'), 'paynow', 65.68, '2026-12-05', 'PN 77', true);
reset role; select t.ok((select status = 'held' from centre_earnings where id = t.id('e_ben')), 'still held while disputed, even when paid');
select t.as('00000000-0000-0000-0000-00000000000a'); set role authenticated;
select td_set_dispute(t.id('inv1'), false, 'Resolved: attendance confirmed');
reset role;
select t.ok((select status = 'payable' from centre_earnings where id = t.id('e_ben')), 'dispute resolved + fully paid: Ben payable');
select t.ok((select status = 'paid' from centre_invoices where id = t.id('inv1')), 'invoice paid');

-- ======================================================================= refund after payout
select t.as('00000000-0000-0000-0000-00000000000a'); set role authenticated;
select td_refund_payment(t.id('pay1'), 100, 'Bank transfer bounced');
reset role;
select t.ok((select clawed_back from centre_earnings where id = t.id('e_alice')), 'paid earning marked clawed back');
select t.eq((select amount from centre_earnings where adjusts_earning_id = t.id('e_alice')), -30, 'negative adjustment created');
select t.ok((select status = 'payable' from centre_earnings where adjusts_earning_id = t.id('e_alice')), 'adjustment is payable (carried)');
-- refund takes newest lines first: Ben's line lost 12.80 from pay1, still has 65.68 → not fully covered
select t.ok((select status = 'pending' from centre_earnings where id = t.id('e_ben')), 'Ben back to pending after refund');
select t.as('00000000-0000-0000-0000-00000000000a'); set role authenticated;
select t.put('b2', td_create_payout_batch(t.id('centre'), '2026-12-31'));
reset role;
select t.eq((select total from centre_payout_batches where id = t.id('b2')), 0, 'Tina net negative: deduction carried, not paid out');
select t.ok((select status = 'payable' and batch_id is null from centre_earnings where adjusts_earning_id = t.id('e_alice')), 'deduction still waiting for next batch');

-- ======================================================================= audited override
select t.as('00000000-0000-0000-0000-00000000000b'); set role authenticated;
select t.fails($q$ select td_override_earning(t.id('e_ben'), 'Pay Tina anyway') $q$, 'staff overriding the payout rule');
reset role; select t.as('00000000-0000-0000-0000-00000000000a'); set role authenticated;
select t.fails($q$ select td_override_earning(t.id('e_ben'), 'ok') $q$, 'override without a proper reason');
select td_override_earning(t.id('e_ben'), 'Parent paid in cash at the desk, receipt #551');
reset role;
select t.ok((select status = 'payable' and override_audit_id is not null from centre_earnings where id = t.id('e_ben')), 'override makes it payable');
select t.ok((select count(*) = 1 from centre_audit_log where action = 'earning.override' and target_id = t.id('e_ben')), 'override is in the audit log');
select t.as('00000000-0000-0000-0000-00000000000a'); set role authenticated;
select td_cancel_batch(t.id('b2'));
select t.put('b3', td_create_payout_batch(t.id('centre'), '2026-12-31'));
reset role;
select t.eq((select total from centre_payout_batches where id = t.id('b3')), 0, 'batch nets Ben $30 against the -$30 deduction (=0, so held over)');

-- ======================================================================= prepaid package (Chloe, Tom 50% of fee)
insert into centre_lessons(centre_id, class_id, tutor_member_id, lesson_date, start_time, end_time)
values (t.id('centre'), t.id('c2'), t.id('t2'), '2026-11-05', '10:00', '11:30');
select t.put('l2', (select id from centre_lessons where lesson_date = '2026-11-05'));
insert into centre_lesson_attendees(centre_id, lesson_id, student_id) values (t.id('centre'), t.id('l2'), t.id('s3'));
select t.as('00000000-0000-0000-0000-00000000000a'); set role authenticated;
select t.put('pkinv', td_sell_package(t.id('s3'), 4, 220, 90));
select t.eq((select total from centre_invoices where id = t.id('pkinv')), 239.80, 'package invoice incl GST');
select td_deliver_lesson(t.id('l2'));
reset role;
select t.ok((select lessons_used = 1 from centre_packages where student_id = t.id('s3')), 'lesson drew down the package');
select t.eq((select amount from centre_earnings where lesson_id = t.id('l2')), 27.50, 'Tom earns 50% of $55 lesson value');
select t.ok((select status = 'pending' from centre_earnings where lesson_id = t.id('l2')), 'package unpaid: Tom pending');
select t.as('00000000-0000-0000-0000-00000000000a'); set role authenticated;
select td_record_payment(t.id('centre'), t.id('h2'), t.id('pkinv'), 'paynow', 239.80, '2026-11-06', 'PN pkg', true);
reset role;
select t.ok((select status = 'payable' from centre_earnings where lesson_id = t.id('l2')), 'package reconciled: delivered lesson payable');
select t.eq((select coalesce(sum(amount),0) from centre_charges where invoice_id = t.id('inv2')), 40, 'Chloe''s late-cancel line untouched by package payment');

-- ======================================================================= late fees & package expiry
select t.as('00000000-0000-0000-0000-00000000000a'); set role authenticated;
select t.eq(td_apply_late_fees(t.id('centre'), (select due_on + 8 from centre_invoices where id = t.id('inv2'))), 1, 'late fee added once overdue');
select t.eq(td_apply_late_fees(t.id('centre'), (select due_on + 8 from centre_invoices where id = t.id('inv2'))), 0, 'not added twice the same day');
select t.eq((select total from centre_invoices where id = t.id('inv2')), 54.50, 'invoice total includes $10 + GST late fee');
select t.eq(td_expire_packages(t.id('centre'), current_date + 120), 1, 'expired package handled');
reset role;
select t.eq((select total from centre_charges where kind = 'credit'), -179.85, 'credit for 3 unused lessons (net -165, GST -14.85)');

-- ======================================================================= payout rule change is audited
select t.as('00000000-0000-0000-0000-00000000000b'); set role authenticated;
select t.fails($q$ select td_set_payout_rule(t.id('centre'), 'on_delivery', 'because') $q$, 'staff changing the payout rule');
reset role; select t.as('00000000-0000-0000-0000-00000000000a'); set role authenticated;
select td_set_payout_rule(t.id('centre'), 'on_delivery', 'Trial month: pay tutors on delivery');
reset role;
select t.ok((select payout_rule = 'on_delivery' from centres where id = t.id('centre')), 'rule changed via audited function');
select t.ok((select count(*) = 1 from centre_audit_log where action = 'payout_rule.change'), 'rule change in the audit log');

-- ======================================================================= roles
select t.as('00000000-0000-0000-0000-00000000000a'); set role authenticated;
select t.fails($q$ select td_save_role(t.id('centre'), (select id from centre_roles where key = 'owner' and centre_id = t.id('centre')), 'owner', 'Boss', '{}') $q$, 'editing the owner role');
select td_save_role(t.id('centre'), null, 'senior_tutor', 'Senior tutor', array['lessons.remarks','payouts.view_own','schedule.view_all']);
select t.fails($q$ update centre_members set role_id = (select id from centre_roles where key = 'admin' and centre_id = t.id('centre')) where id = t.id('t1') $q$, 'changing a role by plain UPDATE');
select td_set_member_role(t.id('t1'), (select id from centre_roles where key = 'senior_tutor'));
select t.fails($q$ select td_set_member_role((select id from centre_members where user_id = auth.uid()), (select id from centre_roles where key = 'staff' and centre_id = t.id('centre'))) $q$, 'removing the last owner');
reset role; select t.as('00000000-0000-0000-0000-00000000000c'); set role authenticated;
select t.ok((select count(*) = 2 from centre_lessons), 'senior tutor now sees the whole schedule');
select t.ok((select count(*) >= 1 from centre_earnings) and (select bool_and(tutor_member_id = t.id('t1')) from centre_earnings), 'tutor sees only own earnings');
reset role;

-- ======================================================================= invites
select t.as('00000000-0000-0000-0000-00000000000a'); set role authenticated;
insert into centre_members(centre_id, email, display_name, role_id)
select t.id('centre'), 'NewTutor@opus.test', 'Nina New', id from centre_roles where centre_id = t.id('centre') and key = 'tutor';
insert into centre_members(centre_id, email, display_name, role_id)
select t.id('centre'), 'faker@opus.test', 'Unconfirmed', id from centre_roles where centre_id = t.id('centre') and key = 'tutor';
reset role; select t.as('00000000-0000-0000-0000-00000000000f'); set role authenticated;
select t.eq(td_claim_invites(), 1, 'confirmed email claims its invite (case-insensitive)');
select t.ok((select count(*) = 1 from centres), 'new tutor now sees the centre');
reset role; select t.as('00000000-0000-0000-0000-000000000010'); set role authenticated;
select t.eq(td_claim_invites(), 0, 'unconfirmed email cannot claim an invite');
reset role;

-- ======================================================================= maths parity cases (also in tests/billing-core.test.js)
select t.eq(td_pay_amount('per_hour', 30, 90, 3, 0, null, null), 45, 'pay per_hour');
select t.eq(td_pay_amount('per_lesson', 50, 90, 3, 0, null, null), 50, 'pay per_lesson');
select t.eq(td_pay_amount('per_student', 12, 90, 3, 0, null, null), 36, 'pay per_student');
select t.eq(td_pay_amount('per_student_hour', 8, 90, 3, 0, null, null), 36, 'pay per_student_hour');
select t.eq(td_pay_amount('percent_of_fee', 45, 90, 3, 180, null, null), 81, 'pay percent_of_fee');
select t.eq(td_pay_amount('per_student', 12, 90, 1, 0, 25, null), 25, 'pay min applies');
select t.eq(td_pay_amount('per_student', 12, 90, 10, 0, null, 100), 100, 'pay max applies');
select t.eq((select total from td_gst(100, 9, false, true)), 109, 'gst exclusive total');
select t.eq((select gst from td_gst(109, 9, true, true)), 9, 'gst inclusive portion');
select t.eq((select total from td_gst(100, 9, false, false)), 100, 'not registered: no gst');

\echo ALL CENTRE TESTS PASSED
