-- Invite-email tests (db/migration_invites.sql). Runs in the same throwaway database after org_separation_test.sql (reuses the t.* helpers).
-- Covers: who may send/resend, the 10-minute / 5-a-day / 30-an-hour limits, disabled invites, the status read for the people list,
-- the log table being server-only, cascade delete, the audit log, and org_claim_invites() (the link that makes an invited login a member).
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000a0001', 'owner@invite.test',   now()),
  ('00000000-0000-0000-0000-0000000a0002', 'staffmt@invite.test', now()),
  ('00000000-0000-0000-0000-0000000a0003', 'staffno@invite.test', now()),
  ('00000000-0000-0000-0000-0000000a0004', 'other@invite.test',   now()),
  ('00000000-0000-0000-0000-0000000a0005', 'tutor@invite.test',   now()),
  ('00000000-0000-0000-0000-0000000a0006', 'unconfirmed@invite.test', null),
  ('00000000-0000-0000-0000-0000000a0007', 'someoneelse@invite.test', now());

-- a centre with: a staff admin who may manage tutors, a staff admin who may not, two pending tutors, one pending address nobody has confirmed
select t.as('00000000-0000-0000-0000-0000000a0001'); set role authenticated;
select t.put('mail', org_create_centre('Alpha Tuition', t.centre_settings()));
select t.put('m_tutor', org_invite(t.id('mail'), 'tutor@invite.test', 'Tara Tutor', 'tutor', null, 'freelancer'));
select t.put('m_staffmt', org_invite(t.id('mail'), 'staffmt@invite.test', 'Sam Manager', 'staff', array['manage_tutors'], null));
select t.put('m_staffno', org_invite(t.id('mail'), 'staffno@invite.test', 'Sue Clerk', 'staff', array['manage_students'], null));
select t.put('m_unconf', org_invite(t.id('mail'), 'unconfirmed@invite.test', 'Una Unconfirmed', 'tutor', null, 'freelancer'));
select t.put('m_other', org_invite(t.id('mail'), 'nobody@invite.test', 'Nobody Yet', 'tutor', null, 'freelancer'));
reset role;

-- ===================================================================== a first send
select t.as('00000000-0000-0000-0000-0000000a0001'); set role authenticated;
select org_invite_mail_reserve(t.id('m_tutor')) as r \gset
reset role;
select t.ok((:'r'::jsonb->>'ok')::boolean and :'r'::jsonb->>'email' = 'tutor@invite.test' and :'r'::jsonb->>'centre' = 'Alpha Tuition'
            and :'r'::jsonb->>'name' = 'Tara Tutor' and :'r'::jsonb->>'role' = 'tutor' and :'r'::jsonb->>'inviter' is not null and :'r'::jsonb->>'log_id' is not null,
            'the owner can send; the answer carries what the email needs (address, name, role, centre, inviter)');
select t.ok((select status = 'pending' and sent_by = '00000000-0000-0000-0000-0000000a0001' from org_invite_mail_log where id = (:'r'::jsonb->>'log_id')::uuid),
            'a pending log row records who pressed the button');
select t.ok((select count(*) = 0 from information_schema.columns where table_schema = 'public' and table_name = 'org_invite_mail_log'
               and (column_name ilike '%mail' or column_name ilike '%link%' or column_name ilike '%url%' or column_name ilike '%token%') and column_name <> 'brevo_message_id'),
            'the log has no address, link or token column');
select t.ok((select count(*) >= 1 from audit_log where table_name = 'org_invite_mail_log' and action = 'insert' and org_id = t.id('mail')), 'the send is in the audit log');

-- ===================================================================== limits
select t.as('00000000-0000-0000-0000-0000000a0001'); set role authenticated;
select org_invite_mail_reserve(t.id('m_tutor')) as r2 \gset
reset role;
select t.ok(:'r2'::jsonb->>'reason' = 'too_soon' and (:'r2'::jsonb->>'ok')::boolean = false and (:'r2'::jsonb->>'retry_minutes')::int between 1 and 10,
            'a second mail inside 10 minutes is refused, with the minutes left');
select t.eq((select count(*) from org_invite_mail_log where membership_id = t.id('m_tutor')), 1, 'and it wrote nothing');

-- Resend after the wait: mails 2..5 go through, the 6th (inside 24 hours) does not
do $$ declare i int; r jsonb; begin
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000a0001', 'role', 'authenticated')::text, false);
  for i in 2..5 loop
    update org_invite_mail_log set sent_at = sent_at - interval '11 minutes' where membership_id = (select v from t.ids where k = 'm_tutor');
    execute 'set local role authenticated'; r := org_invite_mail_reserve((select v from t.ids where k = 'm_tutor')); execute 'reset role';
    if not (r->>'ok')::boolean then raise exception 'FAIL: mail % refused: %', i, r; end if;
  end loop;
  update org_invite_mail_log set sent_at = sent_at - interval '11 minutes' where membership_id = (select v from t.ids where k = 'm_tutor');
  execute 'set local role authenticated'; r := org_invite_mail_reserve((select v from t.ids where k = 'm_tutor')); execute 'reset role';
  if r->>'reason' is distinct from 'daily_limit' then raise exception 'FAIL: 6th mail in a day was not refused: %', r; end if;
  raise notice 'PASS resends work up to 5 mails in 24 hours; the 6th is refused (daily_limit)';
end $$;
update org_invite_mail_log set sent_at = now() - interval '25 hours' where membership_id = t.id('m_tutor');
select t.as('00000000-0000-0000-0000-0000000a0001'); set role authenticated;
select t.ok((org_invite_mail_reserve(t.id('m_tutor'))->>'ok')::boolean, 'a day later the invite can be sent again');
reset role;

-- failed and preview-blocked attempts do not use up the allowance
update org_invite_mail_log set status = 'failed' where membership_id = t.id('m_tutor');
select t.as('00000000-0000-0000-0000-0000000a0001'); set role authenticated;
select t.ok((org_invite_mail_reserve(t.id('m_tutor'))->>'ok')::boolean, 'after a failed send the owner can try again at once');
reset role;
update org_invite_mail_log set status = 'blocked_preview' where membership_id = t.id('m_tutor');

-- ===================================================================== who may
select t.as('00000000-0000-0000-0000-0000000a0001'); set role authenticated;
select org_update_member(t.id('m_staffmt'), null, null, null);   -- no-op: keeps the call path honest
reset role;
-- Sam claims the invite, so he is an active staff admin with manage_tutors; Sue has no such permission
select t.as('00000000-0000-0000-0000-0000000a0002'); set role authenticated;
select t.eq(org_claim_invites(), 1, 'Sam claims his invite');
select t.ok((org_invite_mail_reserve(t.id('m_other'))->>'ok')::boolean, 'a staff admin with manage_tutors can send a (re)invite');
select t.ok(exists (select 1 from org_invite_mail_status(t.id('mail'))), 'and read the people-list status');
reset role;
select t.as('00000000-0000-0000-0000-0000000a0003'); set role authenticated;
select t.eq(org_claim_invites(), 1, 'Sue claims her invite');
select t.fails($q$ select org_invite_mail_reserve(t.id('m_unconf')) $q$, 'a staff admin WITHOUT manage_tutors sending an invite');
select t.fails($q$ select * from org_invite_mail_status(t.id('mail')) $q$, 'a staff admin WITHOUT manage_tutors reading the invite status');
reset role;
select t.as('00000000-0000-0000-0000-0000000a0004'); set role authenticated;
select t.put('other_org', org_create_centre('Beta Tuition', t.centre_settings()));
select t.fails($q$ select org_invite_mail_reserve(t.id('m_unconf')) $q$, 'the owner of ANOTHER centre sending this centre''s invite');
select t.fails($q$ select * from org_invite_mail_status(t.id('mail')) $q$, 'the owner of another centre reading this centre''s invite status');
reset role;
select t.as('00000000-0000-0000-0000-0000000a0005'); set role authenticated;
select t.eq(org_claim_invites(), 1, 'Tara (the invited tutor) claims her invite');
select t.fails($q$ select org_invite_mail_reserve(t.id('m_unconf')) $q$, 'a centre tutor sending an invite');
reset role;
set role anon;
select t.fails($q$ select org_invite_mail_reserve(t.id('m_unconf')) $q$, 'a signed-out visitor sending an invite');
select t.fails($q$ select * from org_invite_mail_status(t.id('mail')) $q$, 'a signed-out visitor reading invite status');
reset role;
select t.ok(not has_function_privilege('anon', 'public.org_invite_mail_reserve(uuid)', 'execute') and has_function_privilege('authenticated', 'public.org_invite_mail_reserve(uuid)', 'execute')
        and not has_function_privilege('anon', 'public.org_invite_mail_status(uuid)', 'execute') and has_function_privilege('authenticated', 'public.org_invite_mail_status(uuid)', 'execute'),
        'only signed-in users can call the two functions');

-- the log table itself is the server's (service role) alone
select t.as('00000000-0000-0000-0000-0000000a0001'); set role authenticated;
select t.fails($q$ select count(*) from org_invite_mail_log $q$, 'the owner reading the log table directly');
select t.fails($q$ insert into org_invite_mail_log(membership_id, org_id) values (t.id('m_unconf'), t.id('mail')) $q$, 'the owner writing the log table directly (to dodge the limit)');
reset role;
set role anon; select t.fails($q$ select count(*) from org_invite_mail_log $q$, 'a visitor reading the log table'); reset role;
select t.ok(has_table_privilege('service_role', 'public.org_invite_mail_log', 'select, insert, update'), 'the server (service role) can read and write it');
select t.ok((select relrowsecurity from pg_class where oid = 'public.org_invite_mail_log'::regclass) and not exists (select 1 from pg_policies where tablename = 'org_invite_mail_log'),
            'row-level security is on, with no policies for anyone');

-- ===================================================================== disabled / accepted invites are not mailed
select t.as('00000000-0000-0000-0000-0000000a0001'); set role authenticated;
select t.ok(org_invite_mail_reserve(t.id('m_tutor'))->>'reason' = 'not_invited', 'an invite already accepted (Tara is active) is not mailed again');
select org_update_member(t.id('m_unconf'), null, null, 'disabled');
select t.ok(org_invite_mail_reserve(t.id('m_unconf'))->>'reason' = 'not_invited', 'a turned-off invite is not mailed');
reset role;

-- ===================================================================== status for the people list
select t.as('00000000-0000-0000-0000-0000000a0001'); set role authenticated;
select t.ok((select count(*) from org_invite_mail_status(t.id('mail'))) = 1 and (select member_id from org_invite_mail_status(t.id('mail'))) = t.id('m_other'),
            'the status lists only invites still waiting (Nobody Yet; Una is turned off; the rest accepted)');
reset role;
update org_invite_mail_log set status = 'sent', brevo_message_id = 'fake', sent_at = now() - interval '3 days' where membership_id = t.id('m_other');
select t.as('00000000-0000-0000-0000-0000000a0001'); set role authenticated;
select t.ok((select last_sent_at < now() - interval '2 days' and sent_24h = 0 and invited_at is not null from org_invite_mail_status(t.id('mail')) where member_id = t.id('m_other')),
            'status gives the last sent time (3 days ago) and 0 mails in the last 24 hours');
reset role;

-- ===================================================================== the organisation-wide cap, and cascade delete
insert into org_invite_mail_log(membership_id, org_id, status, sent_at) select t.id('m_tutor'), t.id('mail'), 'sent', now() - interval '30 minutes' from generate_series(1, 30);   -- 30 mails in the hour
select t.as('00000000-0000-0000-0000-0000000a0001'); set role authenticated;
select t.ok(org_invite_mail_reserve(t.id('m_other'))->>'reason' = 'org_limit', 'a runaway session cannot mail more than 30 an hour from one centre');
reset role;
delete from memberships where id = t.id('m_other');
select t.eq((select count(*) from org_invite_mail_log where membership_id = t.id('m_other')), 0, 'deleting an invite deletes its log rows');

-- ===================================================================== org_claim_invites(): the link between an email and its pending invite
select t.ok((select user_id = '00000000-0000-0000-0000-0000000a0005' and status = 'active' from memberships where id = t.id('m_tutor')), 'the confirmed email owner is now the active member');
select t.as('00000000-0000-0000-0000-0000000a0006'); set role authenticated;
select t.eq(org_claim_invites(), 0, 'an UNCONFIRMED email claims nothing');
reset role;
select t.ok((select user_id is null from memberships where id = t.id('m_unconf')), 'and the invite stays unclaimed');
update memberships set status = 'invited' where id = t.id('m_unconf');
select t.as('00000000-0000-0000-0000-0000000a0007'); set role authenticated;
select t.eq(org_claim_invites(), 0, 'a login with a DIFFERENT email claims nothing');
reset role;
-- already a member of that centre: the second pending row is skipped, not duplicated
insert into memberships(org_id, invited_email, display_name, role, status) values (t.id('mail'), 'owner@invite.test', 'Owner again', 'tutor', 'invited');
select t.as('00000000-0000-0000-0000-0000000a0001'); set role authenticated;
select t.eq(org_claim_invites(), 0, 'a person who already belongs to the centre does not claim a second invite');
select t.eq(org_claim_invites(), 0, 'and claiming twice is harmless (idempotent)');
reset role;
