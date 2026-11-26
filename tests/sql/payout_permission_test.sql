-- T24c step 4 tests: the centre side of tutor payout details. Permission view_payout_details; org_tutor_payouts (masked list), org_tutor_payout_status (provided / not provided),
-- org_reveal_payout (full value, audited without the number). Runs after tutor_payout_test.sql in the same throwaway database. Fake numbers only.
\set ON_ERROR_STOP on
set client_min_messages = notice;

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000a501', 'pstaff-yes@centre.test'), ('00000000-0000-0000-0000-00000000a502', 'pstaff-no@centre.test'),
  ('00000000-0000-0000-0000-00000000a503', 'powner2@other.test'),     ('00000000-0000-0000-0000-00000000a504', 'ptutor-new@centre.test'),
  ('00000000-0000-0000-0000-00000000a505', 'pstaff-off@centre.test');
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('centre'), '00000000-0000-0000-0000-00000000a501', 'Staff With',    'staff', array['manage_tutors','view_payout_details'], 'active'),
  (t.id('centre'), '00000000-0000-0000-0000-00000000a502', 'Staff Without', 'staff', array['manage_tutors','issue_invoices','view_audit_log'], 'active'),
  (t.id('centre'), '00000000-0000-0000-0000-00000000a504', 'Payout Four',   'tutor', '{}', 'active'),
  (t.id('centre'), '00000000-0000-0000-0000-00000000a505', 'Staff Off',     'staff', array['view_payout_details'], 'disabled');
select t.put('q4', (select id from memberships where user_id = '00000000-0000-0000-0000-00000000a504' and org_id = t.id('centre')));
-- a second, unrelated centre with its own tutor and its own payout details
select t.as('00000000-0000-0000-0000-00000000a503'); set role authenticated;
select t.put('centre2', org_create_centre('Other Centre', t.centre_settings()));
reset role;
insert into auth.users(id, email) values ('00000000-0000-0000-0000-00000000a506', 'ptutor-other@other.test');
insert into memberships(org_id, user_id, display_name, role, permissions, status) values (t.id('centre2'), '00000000-0000-0000-0000-00000000a506', 'Other Tutor', 'tutor', '{}', 'active');
select t.put('q5', (select id from memberships where user_id = '00000000-0000-0000-0000-00000000a506' and org_id = t.id('centre2')));
select t.as('00000000-0000-0000-0000-00000000a506'); set role authenticated;
select tutor_save_payout(t.id('q5'), 'paynow_uen', '53123456K', null, null, true);
reset role;

-- the tutor tests end by erasing the centre's payout rows, so start clean: q1 saves a PayNow mobile and then CHANGES it, q2 saves a bank account, q4 saves for the first
-- time, q3 (a disabled tutor) has nothing. q1 also has a membership in the solo organisation (it must never show up).
create table t.cnt as select count(*)::numeric n from audit_log where action = 'payout_revealed';
select t.as('00000000-0000-0000-0000-000000009001'); set role authenticated;
select tutor_save_payout(t.id('q1'), 'paynow_mobile', '8123 4567', null, null, true);
select tutor_save_payout(t.id('q1'), 'paynow_mobile', '9876 5432', null, null, true);
reset role;
select t.as('00000000-0000-0000-0000-00000000a504'); set role authenticated;
select tutor_save_payout(t.id('q4'), 'paynow_mobile', '9111 2222', null, null, true);
reset role;
select t.as('00000000-0000-0000-0000-000000009002'); set role authenticated;
select tutor_save_payout(t.id('q2'), 'bank', '123-456-7890', 'Test Bank', 'Payout Two', true);
reset role;

-- ===================================================================== permission catalogue
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select org_invite(t.id('centre'), 'newstaff@centre.test', 'New Staff', 'staff', array['view_payout_details'], null);
select t.ok((select 'view_payout_details' = any(permissions) from memberships where invited_email = 'newstaff@centre.test'), 'org_invite accepts the new permission');
select t.fails($q$ select org_invite(t.id('centre'), 'x2@y.test', 'X', 'staff', array['view_payout_detail'], null) $q$, 'org_invite still refuses a misspelt permission');
select org_update_member((select id from memberships where invited_email = 'newstaff@centre.test'), null, array['manage_students','view_payout_details'], null);
select t.ok((select permissions = array['manage_students','view_payout_details'] from memberships where invited_email = 'newstaff@centre.test'), 'org_update_member accepts it too');
select t.fails($q$ select org_update_member((select id from memberships where invited_email = 'newstaff@centre.test'), null, array['view_everything'], null) $q$, 'org_update_member refuses an invented permission');
reset role;
select t.as('00000000-0000-0000-0000-00000000a501'); set role authenticated;
select t.fails($q$ select org_update_member((select id from memberships where invited_email = 'newstaff@centre.test'), null, array['view_payout_details'], null) $q$, 'staff cannot grant the permission (owner only)');
reset role;

-- ===================================================================== the owner: masked list
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select t.eq((select count(*) from org_tutor_payouts(t.id('centre'))), (select count(*) from memberships where org_id = t.id('centre') and role = 'tutor'), 'the owner sees every tutor of the centre (and only those)');
select t.ok((select has_payout and method = 'paynow_mobile' and masked = '•••••5432' and bank_name is null and holder_hint is null from org_tutor_payouts(t.id('centre')) where membership_id = t.id('q1')), 'q1: PayNow mobile masked to the last 4');
select t.ok((select has_payout and method = 'bank' and masked = '•••••7890' and bank_name = 'Test Bank' and holder_hint = 'P•••' from org_tutor_payouts(t.id('centre')) where membership_id = t.id('q2')), 'q2: bank account masked, holder shown as the first letter only');
select t.ok((select not has_payout and method is null and masked is null and not changed_recently from org_tutor_payouts(t.id('centre')) where membership_id = t.id('q3')), 'q3 (nothing saved): not provided');
select t.ok((select bool_and(not (x::text like '%98765432%' or x::text like '%1234567890%' or x::text like '%91112222%' or x::text like '%Payout Two''%')) from org_tutor_payouts(t.id('centre')) x where x.membership_id in (t.id('q1'), t.id('q2'), t.id('q4'))), 'the masked list never contains a full number');
select t.ok((select changed_recently and changed_by_name = 'Payout One' and changed_at > now() - interval '1 minute' from org_tutor_payouts(t.id('centre')) where membership_id = t.id('q1')), 'q1 changed a number just now: flagged, with who and when');
select t.ok((select has_payout and not changed_recently from org_tutor_payouts(t.id('centre')) where membership_id = t.id('q4')), 'q4 saved for the FIRST time: provided, but not a "change", so no flag');
select t.eq((select count(*) from org_tutor_payouts(t.id('centre')) where membership_id = t.id('q5')), 0, 'the other centre''s tutor is not in this centre''s list');
reset role;

-- the 7 days: age the current row (test only: the append-only guard is switched off for that one statement, as the database owner), the flag goes away
alter table tutor_payout_details disable trigger tutor_payout_immutable;
update tutor_payout_details set created_at = now() - interval '8 days' where membership_id = t.id('q1') and superseded_at is null;
alter table tutor_payout_details enable trigger tutor_payout_immutable;
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select t.ok((select has_payout and not changed_recently from org_tutor_payouts(t.id('centre')) where membership_id = t.id('q1')), 'after 7 days the flag is gone');
reset role;
alter table tutor_payout_details disable trigger tutor_payout_immutable;
update tutor_payout_details set created_at = now() - interval '6 days' where membership_id = t.id('q1') and superseded_at is null;
alter table tutor_payout_details enable trigger tutor_payout_immutable;
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select t.ok((select changed_recently from org_tutor_payouts(t.id('centre')) where membership_id = t.id('q1')), 'and 6 days after the change it is still flagged');
reset role;
-- clearing then re-adding counts as a change
select t.as('00000000-0000-0000-0000-00000000a504'); set role authenticated;
select tutor_clear_payout(t.id('q4'));
select tutor_save_payout(t.id('q4'), 'paynow_mobile', '9111 2222', null, null, true);
reset role;
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select t.ok((select changed_recently from org_tutor_payouts(t.id('centre')) where membership_id = t.id('q4')), 'clearing and adding again counts as a change');
reset role;

-- ===================================================================== staff with the permission: same list
select t.as('00000000-0000-0000-0000-00000000a501'); set role authenticated;
select t.eq((select count(*) from org_tutor_payouts(t.id('centre'))), (select count(*) from memberships where org_id = t.id('centre') and role = 'tutor'), 'staff WITH view_payout_details see the masked list');
reset role;

-- ===================================================================== everyone else is refused the list and the reveal
select t.as('00000000-0000-0000-0000-00000000a502'); set role authenticated;
select t.fails($q$ select * from org_tutor_payouts(t.id('centre')) $q$, 'staff WITHOUT the permission reading the list (even with manage_tutors and view_audit_log)');
select t.fails($q$ select * from org_reveal_payout(t.id('q1')) $q$, 'staff WITHOUT the permission revealing');
reset role;
select t.as('00000000-0000-0000-0000-00000000a505'); set role authenticated;
select t.fails($q$ select * from org_tutor_payouts(t.id('centre')) $q$, 'a DISABLED staff member who had the permission');
select t.fails($q$ select * from org_tutor_payout_status(t.id('centre')) $q$, 'and the status list');
reset role;
select t.as('00000000-0000-0000-0000-000000009001'); set role authenticated;
select t.fails($q$ select * from org_tutor_payouts(t.id('centre')) $q$, 'a tutor reading the list');
select t.fails($q$ select * from org_tutor_payout_status(t.id('centre')) $q$, 'a tutor reading the status list');
select t.fails($q$ select * from org_reveal_payout(t.id('q2')) $q$, 'a tutor revealing a colleague''s details');
select t.fails($q$ select * from org_reveal_payout(t.id('q1')) $q$, 'a tutor revealing their OWN details through the centre door (they have tutor_reveal_payout)');
reset role;
select t.as('00000000-0000-0000-0000-00000000a503'); set role authenticated;
select t.fails($q$ select * from org_tutor_payouts(t.id('centre')) $q$, 'another centre''s owner reading the list');
select t.fails($q$ select * from org_tutor_payout_status(t.id('centre')) $q$, 'another centre''s owner reading the status list');
select t.fails($q$ select * from org_reveal_payout(t.id('q1')) $q$, 'another centre''s owner revealing');
select t.eq((select count(*) from org_tutor_payouts(t.id('centre2'))), 1, 'but they do see their own centre''s list');
reset role;
select t.as('00000000-0000-0000-0000-0000000000a1'); set role authenticated;
select t.fails($q$ select * from org_tutor_payouts(t.id('tina_org')) $q$, 'a solo tutor (owner of a SOLO organisation) reading the list of their own organisation');
select t.fails($q$ select * from org_reveal_payout(t.id('q1s')) $q$, 'revealing a membership in a solo organisation');
select t.fails($q$ select * from org_tutor_payouts(t.id('centre')) $q$, 'a solo tutor reading a centre''s list');
reset role;
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select t.fails($q$ select * from org_reveal_payout(t.id('q1s')) $q$, 'the centre owner revealing a membership in someone else''s solo organisation');
select t.fails($q$ select * from org_reveal_payout(t.id('q5')) $q$, 'the centre owner revealing another centre''s tutor');
select t.fails($q$ select * from org_reveal_payout(gen_random_uuid()) $q$, 'revealing a membership that does not exist');
select t.fails($q$ select * from org_reveal_payout((select id from memberships where user_id = '00000000-0000-0000-0000-00000000a501')) $q$, 'revealing a staff member (not a tutor)');
reset role;
set role anon;
select t.fails($q$ select * from org_tutor_payouts(t.id('centre')) $q$, 'anonymous: list');
select t.fails($q$ select * from org_tutor_payout_status(t.id('centre')) $q$, 'anonymous: status');
select t.fails($q$ select * from org_reveal_payout(t.id('q1')) $q$, 'anonymous: reveal');
reset role;
select set_config('request.jwt.claims', '', false);
select t.fails($q$ select * from org_tutor_payouts(t.id('centre')) $q$, 'no login at all (the function itself refuses, not just the grant)');

-- ===================================================================== staff WITHOUT the permission: provided / not provided only
select t.as('00000000-0000-0000-0000-00000000a502'); set role authenticated;
select t.eq((select count(*) from org_tutor_payout_status(t.id('centre'))), (select count(*) from memberships where org_id = t.id('centre') and role = 'tutor'), 'staff without the permission get one yes/no per tutor');
select t.ok((select has_payout from org_tutor_payout_status(t.id('centre')) where membership_id = t.id('q1')) and (select not has_payout from org_tutor_payout_status(t.id('centre')) where membership_id = t.id('q3')), 'provided for q1, not provided for q3');
select t.ok((select pg_get_function_result('public.org_tutor_payout_status(uuid)'::regprocedure) = 'TABLE(membership_id uuid, has_payout boolean)'), 'the status function can only return a membership id and a yes/no');
select t.fails($q$ select count(*) from tutor_payout_details $q$, 'and still no table access');
reset role;
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select t.eq((select count(*) from org_tutor_payout_status(t.id('centre'))), (select count(*) from memberships where org_id = t.id('centre') and role = 'tutor'), 'the owner can read the status list too');
reset role;

-- ===================================================================== reveal: full value, audited, without the number
select t.eq((select count(*) from audit_log where action = 'payout_revealed_by_centre'), 0, 'nothing revealed yet by a centre');
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select t.ok((select method = 'paynow_mobile' and paynow_id = '+6598765432' and bank_name is null from org_reveal_payout(t.id('q1'))), 'the owner reveals q1: the full PayNow mobile');
select t.ok((select method = 'bank' and account_no = '1234567890' and bank_name = 'Test Bank' and account_holder = 'Payout Two' from org_reveal_payout(t.id('q2'))), 'and q2: the full bank details');
select t.fails($q$ select * from org_reveal_payout(t.id('q3')) $q$, 'revealing a tutor with nothing saved says so (and logs nothing)');
reset role;
select t.eq((select count(*) from audit_log where action = 'payout_revealed_by_centre'), 2, 'each reveal wrote exactly one audit row');
select t.ok((select actor = '00000000-0000-0000-0000-0000000000c1' and org_id = t.id('centre') and after->>'membership_id' = t.id('q1')::text and after->>'method' = 'paynow_mobile' and after->>'masked' = '•••••5432' and at > now() - interval '1 minute'
            from audit_log where action = 'payout_revealed_by_centre' and after->>'masked' = '•••••5432'), 'who revealed (actor), whose (membership), when, which method, masked value');
select t.eq((select count(*) from audit_log where action = 'payout_revealed_by_centre' and (after::text like '%98765432%' or before::text like '%98765432%' or after::text like '%1234567890%' or after::text like '%Payout Two%' or after::text like '%Test Bank%')), 0, 'no audit row holds a full number, a bank name or a holder name');
select t.as('00000000-0000-0000-0000-00000000a501'); set role authenticated;
select * from org_reveal_payout(t.id('q4')) \g /dev/null
reset role;
select t.ok((select actor = '00000000-0000-0000-0000-00000000a501' from audit_log where action = 'payout_revealed_by_centre' and after->>'membership_id' = t.id('q4')::text), 'a staff reveal is logged with the STAFF member as actor');
select t.eq((select count(*) from audit_log where action = 'payout_revealed'), (select n from t.cnt), 'the tutors'' own reveals (payout_revealed) are separate and unchanged');
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select t.ok((select count(*) = 3 from audit_log where action = 'payout_revealed_by_centre' and org_id = t.id('centre')), 'the owner can read the reveals in the audit log');
reset role;
select t.as('00000000-0000-0000-0000-00000000a502'); set role authenticated;
select t.ok((select count(*) = 3 from audit_log where action = 'payout_revealed_by_centre'), 'staff with view_audit_log can read them too (they see who revealed whose, never the number)');
reset role;

-- ===================================================================== grants and shape
select t.ok(not has_function_privilege('anon', 'public.org_tutor_payouts(uuid)', 'execute') and not has_function_privilege('anon', 'public.org_tutor_payout_status(uuid)', 'execute')
        and not has_function_privilege('anon', 'public.org_reveal_payout(uuid)', 'execute') and has_function_privilege('authenticated', 'public.org_tutor_payouts(uuid)', 'execute')
        and has_function_privilege('authenticated', 'public.org_tutor_payout_status(uuid)', 'execute') and has_function_privilege('authenticated', 'public.org_reveal_payout(uuid)', 'execute'),
        'anonymous callers have no access to the three functions; signed-in users do (each call checks who they are)');
select t.ok(not has_function_privilege('authenticated', 'public.td_payout_viewer(uuid,boolean)', 'execute') and not has_function_privilege('anon', 'public.td_payout_viewer(uuid,boolean)', 'execute'), 'the internal permission check cannot be called from a browser');
select t.ok(not exists (select 1 from pg_proc p where p.proname in ('org_tutor_payouts', 'org_tutor_payout_status', 'org_reveal_payout', 'td_payout_viewer') and not (p.prosecdef and 'search_path=public' = any(p.proconfig))),
        'all four are security definer with a pinned search_path');

\echo ALL PAYOUT-PERMISSION TESTS PASSED
