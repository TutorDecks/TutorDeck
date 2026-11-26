-- T24c step 3 tests: a centre tutor saves, reads (masked), reveals and clears ONLY their own payout details, through four functions, with no table access,
-- and no full number or name ever reaches the audit log or an error message. Fake numbers only (+65 8123 4567 style).
-- Runs after tutor_profile_test.sql in the same throwaway database (reuses t.*, the 'centre' organisation and Tina's solo organisation).
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-000000009001', 'payout1@centre.test'), ('00000000-0000-0000-0000-000000009002', 'payout2@centre.test'),
  ('00000000-0000-0000-0000-000000009003', 'payout3@centre.test'), ('00000000-0000-0000-0000-000000009004', 'payout4@nowhere.test');
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('centre'),   '00000000-0000-0000-0000-000000009001', 'Payout One', 'tutor', '{}', 'active'),
  (t.id('centre'),   '00000000-0000-0000-0000-000000009002', 'Payout Two', 'tutor', '{}', 'active'),
  (t.id('centre'),   '00000000-0000-0000-0000-000000009003', 'Payout Three', 'tutor', '{}', 'disabled'),
  (t.id('tina_org'), '00000000-0000-0000-0000-000000009001', 'Payout One (solo org)', 'tutor', '{}', 'active');
select t.put('q1',  (select id from memberships where user_id = '00000000-0000-0000-0000-000000009001' and org_id = t.id('centre')));
select t.put('q1s', (select id from memberships where user_id = '00000000-0000-0000-0000-000000009001' and org_id = t.id('tina_org')));
select t.put('q2',  (select id from memberships where user_id = '00000000-0000-0000-0000-000000009002' and org_id = t.id('centre')));
select t.put('q3',  (select id from memberships where user_id = '00000000-0000-0000-0000-000000009003' and org_id = t.id('centre')));
select t.ok((select kind = 'centre' from organisations where id = t.id('centre')) and (select kind = 'solo' from organisations where id = t.id('tina_org')), 'setup: one centre, one solo organisation');

-- ===================================================================== the table itself: nobody reaches it from a browser
select t.ok((select relrowsecurity from pg_class where oid = 'public.tutor_payout_details'::regclass), 'row-level security is on');
select t.eq((select count(*) from pg_policies where tablename = 'tutor_payout_details'), 0, 'and there is no policy for anyone');
select t.ok(not has_table_privilege('authenticated', 'public.tutor_payout_details', 'select') and not has_table_privilege('anon', 'public.tutor_payout_details', 'select')
        and not has_table_privilege('authenticated', 'public.tutor_payout_details', 'insert') and not has_table_privilege('authenticated', 'public.tutor_payout_details', 'update')
        and not has_table_privilege('authenticated', 'public.tutor_payout_details', 'delete'), 'the browser roles have no table privileges at all');
select t.eq((select count(*) from pg_trigger where tgrelid = 'public.tutor_payout_details'::regclass and tgname = 'audit_row'), 0, 'the generic audit trigger (which copies whole rows) is not attached');
select t.as('00000000-0000-0000-0000-000000009001'); set role authenticated;
select t.fails($q$ select count(*) from tutor_payout_details $q$, 'a tutor reading the table directly');
select t.fails($q$ insert into tutor_payout_details(org_id, membership_id, method, paynow_id, created_by) values (t.id('centre'), t.id('q1'), 'paynow_mobile', '+6581234567', '00000000-0000-0000-0000-000000009001') $q$, 'a tutor writing the table directly');
reset role;

-- ===================================================================== reading before anything is saved
select t.as('00000000-0000-0000-0000-000000009001'); set role authenticated;
select t.eq((select count(*) from tutor_my_payout()), 1, 'a tutor sees one row per CENTRE where they are an active tutor (the solo organisation does not count)');
select t.ok((select not has_payout and method is null and masked is null from tutor_my_payout() where membership_id = t.id('q1')), 'nothing saved yet');
reset role;

-- ===================================================================== PayNow mobile
select t.as('00000000-0000-0000-0000-000000009001'); set role authenticated;
select tutor_save_payout(t.id('q1'), 'paynow_mobile', '8123 4567', null, null, true);
select t.ok((select has_payout and method = 'paynow_mobile' and masked = '•••••4567' and bank_name is null and holder_hint is null from tutor_my_payout() where membership_id = t.id('q1')), 'saved: shown masked as •••••4567');
select t.ok((select not (x::text like '%81234567%' or x::text like '%8123%') from tutor_my_payout() x), 'the masked read never contains the full number');
select t.ok((select method = 'paynow_mobile' and paynow_id = '+6581234567' and bank_name is null and account_no is null and account_holder is null from tutor_reveal_payout(t.id('q1'))), 'reveal returns the full number, normalised to +65 and 8 digits');
reset role;
select t.eq((select count(*) from audit_log where action = 'payout_revealed' and after->>'masked' = '•••••4567'), 1, 'the reveal wrote one audit row (masked value only)');
select t.ok((select actor = '00000000-0000-0000-0000-000000009001' and org_id = t.id('centre') and after->>'method' = 'paynow_mobile' and after->>'membership_id' = t.id('q1')::text
            from audit_log where action = 'payout_revealed'), 'with who, which centre, which person and the method');
select t.as('00000000-0000-0000-0000-000000009001'); set role authenticated;
select * from tutor_reveal_payout(t.id('q1')) \g /dev/null
reset role;
select t.eq((select count(*) from audit_log where action = 'payout_revealed'), 2, 'every reveal is logged, not just the first');
select t.as('00000000-0000-0000-0000-000000009001'); set role authenticated;
select tutor_save_payout(t.id('q1'), 'paynow_mobile', '+65-9876-5432', null, null, true);
select tutor_save_payout(t.id('q1'), 'paynow_mobile', '6598765432', null, null, true);                  -- same number written another way: no change
reset role;
select t.eq((select count(*) from tutor_payout_details where membership_id = t.id('q1')), 2, 'a change adds a row and keeps the old one (append-only); saving the same number again adds nothing');
select t.eq((select count(*) from tutor_payout_details where membership_id = t.id('q1') and superseded_at is null), 1, 'exactly one current row');
select t.ok((select paynow_id = '+6598765432' from tutor_payout_details where membership_id = t.id('q1') and superseded_at is null), 'the new number is the current one');
select t.eq((select count(*) from audit_log where action = 'payout_saved' and after->>'membership_id' = t.id('q1')::text), 2, 'each real change is audited once');

-- ===================================================================== PayNow UEN (three shapes, lower case is fixed up)
select t.as('00000000-0000-0000-0000-000000009001'); set role authenticated;
select tutor_save_payout(t.id('q1'), 'paynow_uen', '53123456k', null, null, true);
select t.ok((select method = 'paynow_uen' and paynow_id = '53123456K' from tutor_reveal_payout(t.id('q1'))), 'business UEN 8 digits + letter, stored upper-case');
select tutor_save_payout(t.id('q1'), 'paynow_uen', '2019 12345 a', null, null, true);
select t.ok((select paynow_id = '201912345A' from tutor_reveal_payout(t.id('q1'))), 'local company UEN, spaces ignored');
select tutor_save_payout(t.id('q1'), 'paynow_uen', 'T08LL1234H', null, null, true);
select t.ok((select paynow_id = 'T08LL1234H' and (select masked = '•••••234H' from tutor_my_payout() where membership_id = t.id('q1')) from tutor_reveal_payout(t.id('q1'))), 'other-entity UEN, masked to its last 4');
reset role;

-- ===================================================================== bank account
select t.as('00000000-0000-0000-0000-000000009001'); set role authenticated;
select tutor_save_payout(t.id('q1'), 'bank', '123-456-789-0', 'Example Bank', 'Quentin Tan Wei Ling', true);
select t.ok((select method = 'bank' and masked = '•••••7890' and bank_name = 'Example Bank' and holder_hint = 'Q•••' from tutor_my_payout() where membership_id = t.id('q1')), 'saved: account masked to the last 4, holder name reduced to its first letter');
select t.ok((select not (x::text like '%1234567890%' or x::text like '%Quentin%' or x::text like '%Wei Ling%') from tutor_my_payout() x), 'the masked read has no account number and no holder name');
select t.ok((select method = 'bank' and account_no = '1234567890' and account_holder = 'Quentin Tan Wei Ling' and bank_name = 'Example Bank' and paynow_id is null from tutor_reveal_payout(t.id('q1'))), 'reveal returns everything for a bank account');
reset role;

-- ===================================================================== nothing full or personal in the audit log
select t.eq((select count(*) from audit_log where (coalesce(before::text, '') || coalesce(after::text, '')) ~ '(81234567|98765432|53123456|201912345|08LL1234|1234567890|Quentin|Wei Ling|Example Bank)'), 0,
            'no full number, UEN, account number, holder name or bank name appears anywhere in audit_log');
select t.ok((select count(*) >= 6 from audit_log where table_name = 'tutor_payout_details'), 'but the saves and reveals ARE logged (method + masked value)');
select t.eq((select count(*) from audit_log where table_name = 'tutor_payout_details' and (after - 'membership_id' - 'method' - 'masked') <> '{}'::jsonb), 0, 'audit rows hold only membership, method and masked value');

-- ===================================================================== another tutor sees nothing of it
select t.as('00000000-0000-0000-0000-000000009002'); set role authenticated;
select t.ok((select not has_payout and masked is null and method is null from tutor_my_payout() where membership_id = t.id('q2')), 'tutor two has no details of their own');
select t.eq((select count(*) from tutor_my_payout() where membership_id = t.id('q1')), 0, 'and cannot see tutor one''s row');
select t.fails($q$ select * from tutor_reveal_payout(t.id('q1')) $q$, 'tutor two revealing tutor one''s details');
select t.fails($q$ select tutor_save_payout(t.id('q1'), 'paynow_mobile', '81234567', null, null, true) $q$, 'tutor two saving onto tutor one''s membership');
select t.fails($q$ select tutor_clear_payout(t.id('q1')) $q$, 'tutor two clearing tutor one''s details');
select t.fails($q$ select * from tutor_reveal_payout(t.id('q2')) $q$, 'revealing when nothing is saved');
reset role;
select t.ok((select method = 'bank' and account_no = '1234567890' from tutor_payout_details where membership_id = t.id('q1') and superseded_at is null), 'and tutor one''s details are untouched');

-- ===================================================================== who may not use it at all
select t.as('00000000-0000-0000-0000-000000009001'); set role authenticated;
select t.fails($q$ select tutor_save_payout(t.id('q1s'), 'paynow_mobile', '81234567', null, null, true) $q$, 'a tutor membership in a SOLO organisation');
select t.fails($q$ select * from tutor_reveal_payout(t.id('q1s')) $q$, 'revealing on a solo organisation''s membership');
reset role;
select t.as('00000000-0000-0000-0000-000000009003'); set role authenticated;
select t.eq((select count(*) from tutor_my_payout()), 0, 'a disabled tutor sees nothing');
select t.fails($q$ select tutor_save_payout(t.id('q3'), 'paynow_mobile', '81234567', null, null, true) $q$, 'a disabled tutor saving');
reset role;
select t.as('00000000-0000-0000-0000-000000009004'); set role authenticated;
select t.eq((select count(*) from tutor_my_payout()), 0, 'someone who is a member of nothing sees nothing');
select t.fails($q$ select tutor_save_payout(t.id('q1'), 'paynow_mobile', '81234567', null, null, true) $q$, 'a non-member saving');
select t.fails($q$ select * from tutor_reveal_payout(t.id('q1')) $q$, 'a non-member revealing');
reset role;
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select t.eq((select count(*) from tutor_my_payout()), 0, 'the centre owner is not a tutor, so has no payout details here');
select t.fails($q$ select * from tutor_reveal_payout(t.id('q1')) $q$, 'the centre owner revealing a tutor''s details (that is step 4, behind a permission)');
select t.fails($q$ select tutor_save_payout(t.id('q1'), 'paynow_mobile', '81234567', null, null, true) $q$, 'the centre owner saving onto a tutor''s membership');
reset role;
set role anon;
select t.fails($q$ select * from tutor_my_payout() $q$, 'an anonymous read');
select t.fails($q$ select tutor_save_payout(t.id('q1'), 'paynow_mobile', '81234567', null, null, true) $q$, 'an anonymous save');
select t.fails($q$ select * from tutor_reveal_payout(t.id('q1')) $q$, 'an anonymous reveal');
select t.fails($q$ select tutor_clear_payout(t.id('q1')) $q$, 'an anonymous clear');
reset role;

-- ===================================================================== bad input, in plain words, and the value is never echoed back
select t.as('00000000-0000-0000-0000-000000009002'); set role authenticated;
select t.fails($q$ select tutor_save_payout(t.id('q2'), 'paynow_mobile', '71234567', null, null, true) $q$, 'a mobile starting with 7', 'BAD_PAYNOW_MOBILE');
select t.fails($q$ select tutor_save_payout(t.id('q2'), 'paynow_mobile', '6123 4567', null, null, true) $q$, 'a landline starting with 6 (PayNow needs a mobile)', 'BAD_PAYNOW_MOBILE');
select t.fails($q$ select tutor_save_payout(t.id('q2'), 'paynow_mobile', '8123456', null, null, true) $q$, 'a mobile with 7 digits', 'BAD_PAYNOW_MOBILE');
select t.fails($q$ select tutor_save_payout(t.id('q2'), 'paynow_mobile', '+44 7911 123456', null, null, true) $q$, 'a foreign number', 'BAD_PAYNOW_MOBILE');
select t.fails($q$ select tutor_save_payout(t.id('q2'), 'paynow_mobile', '81x34567', null, null, true) $q$, 'letters in a mobile', 'BAD_PAYNOW_MOBILE');
select t.fails($q$ select tutor_save_payout(t.id('q2'), 'paynow_mobile', '', null, null, true) $q$, 'an empty mobile', 'BAD_PAYNOW_MOBILE');
select t.fails($q$ select tutor_save_payout(t.id('q2'), 'paynow_uen', '1234', null, null, true) $q$, 'a UEN that is too short', 'BAD_UEN');
select t.fails($q$ select tutor_save_payout(t.id('q2'), 'paynow_uen', '531234567', null, null, true) $q$, 'a UEN with no closing letter', 'BAD_UEN');
select t.fails($q$ select tutor_save_payout(t.id('q2'), 'paynow_uen', '30191234AA', null, null, true) $q$, 'a 10-character UEN of the wrong shape', 'BAD_UEN');
select t.fails($q$ select tutor_save_payout(t.id('q2'), 'bank', '123456', 'Example Bank', 'Pat Tan', true) $q$, 'an account number of 6 digits', 'BAD_ACCOUNT');
select t.fails($q$ select tutor_save_payout(t.id('q2'), 'bank', '12345678901234567', 'Example Bank', 'Pat Tan', true) $q$, 'an account number of 17 digits', 'BAD_ACCOUNT');
select t.fails($q$ select tutor_save_payout(t.id('q2'), 'bank', '12345X78', 'Example Bank', 'Pat Tan', true) $q$, 'letters in an account number', 'BAD_ACCOUNT');
select t.fails($q$ select tutor_save_payout(t.id('q2'), 'bank', '12345678', '', 'Pat Tan', true) $q$, 'no bank name', 'BAD_BANK_NAME');
select t.fails($q$ select tutor_save_payout(t.id('q2'), 'bank', '12345678', null, 'Pat Tan', true) $q$, 'a null bank name', 'BAD_BANK_NAME');
select t.fails($q$ select tutor_save_payout(t.id('q2'), 'bank', '12345678', 'Example Bank', 'P', true) $q$, 'a holder name of one character', 'BAD_HOLDER');
select t.fails($q$ select tutor_save_payout(t.id('q2'), 'bank', '12345678', 'Example Bank', repeat('x', 81), true) $q$, 'a holder name over 80 characters', 'BAD_HOLDER');
select t.fails($q$ select tutor_save_payout(t.id('q2'), 'cheque', '81234567', null, null, true) $q$, 'an unknown method', 'BAD_METHOD');
select t.fails($q$ select tutor_save_payout(t.id('q2'), null, '81234567', null, null, true) $q$, 'no method', 'BAD_METHOD');
select t.fails($q$ select tutor_save_payout(t.id('q2'), 'paynow_mobile', '81234567', null, null, false) $q$, 'saving without the "my own details" tick', 'NEED_CONFIRM');
select t.fails($q$ select tutor_save_payout(t.id('q2'), 'paynow_mobile', '81234567') $q$, 'saving with the tick left out entirely', 'NEED_CONFIRM');
select t.fails($q$ select tutor_save_payout(gen_random_uuid(), 'paynow_mobile', '81234567', null, null, true) $q$, 'a membership that does not exist', 'NOT_FOUND');
reset role;
select t.eq((select count(*) from tutor_payout_details where membership_id = t.id('q2')), 0, 'none of the refused attempts left a row');
-- the typed value must not come back in the error text (error text can end up in logs and screens)
do $$
declare m text; probe text[] := array['91234560', '12345X78', 'ZZSECRETZZ'];
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-000000009002', 'role', 'authenticated')::text, false);
  set local role authenticated;
  begin perform tutor_save_payout(t.id('q2'), 'paynow_mobile', '71234560', null, null, true); exception when others then m := coalesce(m, '') || sqlerrm; end;
  begin perform tutor_save_payout(t.id('q2'), 'bank', '12345X78', 'ZZSECRETZZ', 'Pat Tan', true); exception when others then m := coalesce(m, '') || sqlerrm; end;
  begin perform tutor_save_payout(t.id('q2'), 'paynow_uen', 'ZZSECRETZZ', null, null, true); exception when others then m := coalesce(m, '') || sqlerrm; end;
  begin perform tutor_save_payout(t.id('q2'), 'bank', '12345678', 'ZZSECRETZZ', 'ZZSECRETZZ' || repeat('x', 90), true); exception when others then m := coalesce(m, '') || sqlerrm; end;
  reset role;
  if m is null or m ~ '(71234560|12345X78|ZZSECRETZZ|1234560)' then raise exception 'FAIL: an error message echoed the typed value: %', m; end if;
  raise notice 'PASS error messages never contain what was typed';
end $$;

-- ===================================================================== clear
select t.as('00000000-0000-0000-0000-000000009001'); set role authenticated;
select tutor_clear_payout(t.id('q1'));
select tutor_clear_payout(t.id('q1'));                                                                   -- clearing nothing is harmless
select t.ok((select not has_payout and method is null and masked is null from tutor_my_payout() where membership_id = t.id('q1')), 'cleared: nothing on file any more');
select t.fails($q$ select * from tutor_reveal_payout(t.id('q1')) $q$, 'revealing after clearing');
reset role;
select t.eq((select count(*) from tutor_payout_details where membership_id = t.id('q1') and superseded_at is null), 0, 'no current row');
select t.eq((select count(*) from audit_log where action = 'payout_cleared'), 1, 'one clear is audited (and the empty second clear is not)');
select t.eq((select count(*) from audit_log where (coalesce(before::text, '') || coalesce(after::text, '')) ~ '(1234567890|Quentin|Example Bank|53123456)'), 0, 'still nothing full in the audit log after clearing');
select t.as('00000000-0000-0000-0000-000000009001'); set role authenticated;
select tutor_save_payout(t.id('q1'), 'paynow_mobile', '8123 4567', null, null, true);
select t.ok((select has_payout and masked = '•••••4567' from tutor_my_payout() where membership_id = t.id('q1')), 'and a new set of details can be saved after clearing');
reset role;

-- ===================================================================== append-only (even for the owner of the database) and the table's own checks
select t.fails($q$ update tutor_payout_details set account_no = '99999999' where membership_id = (select t.id('q1')) $q$, 'editing a stored row');
select t.fails($q$ update tutor_payout_details set paynow_id = '+6591111111', superseded_at = now() where superseded_at is null and membership_id = (select t.id('q1')) $q$, 'editing a value while retiring a row');
select t.fails($q$ update tutor_payout_details set superseded_at = null where superseded_at is not null $q$, 'bringing a retired row back');
select t.fails($q$ delete from tutor_payout_details where membership_id = (select t.id('q1')) $q$, 'deleting a row');
select t.fails($q$ select set_config('td.deleting_org', t.id('tina_org')::text, true) where false; delete from tutor_payout_details where org_id = (select t.id('centre')) $q$, 'deleting a centre''s row without the flag');
select t.fails($q$ insert into tutor_payout_details(org_id, membership_id, method, paynow_id, created_by) values (t.id('centre'), t.id('q2'), 'paynow_mobile', '+6571234567', '00000000-0000-0000-0000-000000009002') $q$, 'the table itself refuses a mobile that does not start with 8 or 9');
select t.fails($q$ insert into tutor_payout_details(org_id, membership_id, method, paynow_id, bank_name, created_by) values (t.id('centre'), t.id('q2'), 'paynow_mobile', '+6581234567', 'Example Bank', '00000000-0000-0000-0000-000000009002') $q$, 'the table refuses a PayNow row carrying bank fields');
select t.fails($q$ insert into tutor_payout_details(org_id, membership_id, method, account_no, bank_name, account_holder, created_by) values (t.id('centre'), t.id('q2'), 'bank', '12', 'Example Bank', 'Pat Tan', '00000000-0000-0000-0000-000000009002') $q$, 'the table refuses a short account number');
select t.fails($q$ insert into tutor_payout_details(org_id, membership_id, method, paynow_id, created_by) values (t.id('tina_org'), t.id('q1'), 'paynow_mobile', '+6581234567', '00000000-0000-0000-0000-000000009001') $q$, 'a row pointing at another organisation''s membership');
select t.fails($q$ insert into tutor_payout_details(org_id, membership_id, method, paynow_id, created_by) values (t.id('centre'), t.id('q1'), 'paynow_mobile', '+6581111111', '00000000-0000-0000-0000-000000009001') $q$, 'a second CURRENT row for the same person');
-- the one door for deletion: a whole organisation being removed (flag for THAT organisation, never from a browser role)
set role authenticated;
select t.fails($q$ select set_config('td.deleting_org', t.id('centre')::text, true); delete from tutor_payout_details where org_id = t.id('centre') $q$, 'a browser role deleting with the flag set');
reset role;
select t.fails($q$ select set_config('td.deleting_org', t.id('tina_org')::text, true); delete from tutor_payout_details where org_id = t.id('centre') $q$, 'the flag for one organisation unlocking another''s rows');
select set_config('td.deleting_org', t.id('centre')::text, false);
select t.ok((select count(*) from tutor_payout_details where org_id = t.id('centre')) > 0, 'rows exist before the organisation-removal path');
delete from tutor_payout_details where org_id = t.id('centre');
select set_config('td.deleting_org', '', false);
select t.eq((select count(*) from tutor_payout_details where org_id = t.id('centre')), 0, 'while an organisation is being removed (flag set to that organisation) its rows can go');

-- ===================================================================== grants
select t.ok(not has_function_privilege('anon', 'public.tutor_my_payout()', 'execute') and not has_function_privilege('anon', 'public.tutor_reveal_payout(uuid)', 'execute')
        and not has_function_privilege('anon', 'public.tutor_save_payout(uuid,text,text,text,text,boolean)', 'execute') and not has_function_privilege('anon', 'public.tutor_clear_payout(uuid)', 'execute')
        and has_function_privilege('authenticated', 'public.tutor_my_payout()', 'execute') and has_function_privilege('authenticated', 'public.tutor_reveal_payout(uuid)', 'execute')
        and has_function_privilege('authenticated', 'public.tutor_save_payout(uuid,text,text,text,text,boolean)', 'execute') and has_function_privilege('authenticated', 'public.tutor_clear_payout(uuid)', 'execute'),
        'anonymous callers have no access to the four functions; signed-in users do (each call checks who they are)');
select t.ok(not has_function_privilege('authenticated', 'public.td_payout_audit(uuid,uuid,uuid,text,text,text)', 'execute') and not has_function_privilege('authenticated', 'public.td_my_centre_tutor(uuid)', 'execute')
        and not has_function_privilege('authenticated', 'public.td_payout_mask(text)', 'execute') and not has_function_privilege('anon', 'public.td_payout_audit(uuid,uuid,uuid,text,text,text)', 'execute'),
        'the internal helpers (audit writer, centre check, mask) cannot be called from a browser');
select t.ok(not exists (select 1 from pg_proc p where p.proname in ('tutor_my_payout', 'tutor_reveal_payout', 'tutor_save_payout', 'tutor_clear_payout', 'td_payout_audit', 'td_my_centre_tutor')
                        and not (p.prosecdef and 'search_path=public' = any(p.proconfig))), 'all the security functions are security definer with a pinned search_path');

\echo ALL TUTOR-PAYOUT TESTS PASSED
