-- T7.3 tests: emailing invoices, receipts and overdue reminders to families (db/migration_invoice_email.sql).
-- Covers: the settings validator (every value of every email option, both edges of every range, the wording rules), who may send and who never may (tutors,
-- parents, switched-off staff, other centres, solo organisations, anonymous), staff_send / auto_on_issue / off, billing contacts and the first-guardian default,
-- duplicates, resend limits, invoices that are never mailed (draft, credit note, imported, voided, credited, paid), receipts, late-fee notices, the daily and hourly
-- caps and the platform cap, retries (3 attempts, backoff, then failed), invalid and bounced addresses (marked bad, not mailed again, cleared by a new address), the
-- reminder schedule (first, repeat, maximum, missed days, paid-before-reminder, old invoices), the append-only log with masked addresses only, and the queue screens.
-- Runs after tutor_moves_test.sql in the same throwaway database (reuses the t.* helpers). All names and addresses are FAKE (@example.test).
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000e701', 'em.owner@centre.test'),  ('00000000-0000-0000-0000-00000000e702', 'em.paym@centre.test'),
  ('00000000-0000-0000-0000-00000000e703', 'em.bill@centre.test'),   ('00000000-0000-0000-0000-00000000e704', 'em.rev@centre.test'),
  ('00000000-0000-0000-0000-00000000e705', 'em.tutor@centre.test'),  ('00000000-0000-0000-0000-00000000e706', 'em.parent@centre.test'),
  ('00000000-0000-0000-0000-00000000e707', 'em.off@centre.test'),    ('00000000-0000-0000-0000-00000000e708', 'em.owner2@centre.test'),
  ('00000000-0000-0000-0000-00000000e709', 'em.solo@centre.test');
\set o1 '00000000-0000-0000-0000-00000000e701'
\set paym '00000000-0000-0000-0000-00000000e702'
\set bill '00000000-0000-0000-0000-00000000e703'
\set rev '00000000-0000-0000-0000-00000000e704'
\set tut '00000000-0000-0000-0000-00000000e705'
\set par '00000000-0000-0000-0000-00000000e706'
\set off '00000000-0000-0000-0000-00000000e707'
\set o2 '00000000-0000-0000-0000-00000000e708'
\set solo '00000000-0000-0000-0000-00000000e709'

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today;
grant select on td to authenticated, anon;

-- ------------------------------------------------------------------ helpers
-- the email options with the defaults, plus what a test changes
create function pg_temp.mail(p jsonb) returns jsonb language sql as $$
  select '{"mode":"staff_send","receipts":false,"late_fee_notice":false,"reminders":{"enabled":false,"first_after_days":3,"repeat_days":7,"max_count":3},"daily_cap":200,"per_hour":60}'::jsonb || p $$;
create function pg_temp.settings(p_email jsonb, p_share boolean default true) returns jsonb language sql as $$
  select t.centre_settings() || jsonb_build_object('email', p_email)
         || jsonb_build_object('invoicing', jsonb_build_object('grouping', 'family', 'due_days', 7, 'delivery', jsonb_build_object('share_link', p_share)))
         || jsonb_build_object('profile', (t.centre_settings()->'profile') || '{"reply_to_email":"office@centre.test","trading_name":"Email Centre"}'::jsonb) $$;
-- another settings version in force from today (a later version wins on the same day)
create function pg_temp.cfg(p_org uuid, p_email jsonb, p_share boolean default true) returns void language plpgsql as $$
begin
  insert into org_settings(org_id, version, schema_version, effective_from, settings)
  values (p_org, (select coalesce(max(version), 0) + 1 from org_settings where org_id = p_org), 1, (select today from td), pg_temp.settings(p_email, p_share));
end $$;
create function pg_temp.inv(p_org uuid, p_hh uuid, p_stu uuid, p_kind text, p_total bigint, p_issue date, p_due date, p_imported text default null) returns uuid language plpgsql as $$
declare i uuid := gen_random_uuid();
begin
  insert into centre_invoices(id, org_id, kind, household_id, student_id, period_start, period_end, imported_number)
  values (i, p_org, p_kind, p_hh, p_stu, date_trunc('month', p_issue)::date, (date_trunc('month', p_issue) + interval '1 month - 1 day')::date, p_imported);
  insert into centre_invoice_lines(org_id, invoice_id, position, description, qty, unit_cents) values (p_org, i, 1, 'Lessons', 1, p_total);
  update centre_invoices set status = 'issued', issue_date = p_issue, due_date = p_due, net_cents = p_total, total_cents = p_total where id = i;
  return i;
end $$;
-- a draft that is not issued yet
create function pg_temp.draft(p_org uuid, p_hh uuid, p_stu uuid, p_total bigint) returns uuid language plpgsql as $$
declare i uuid := gen_random_uuid();
begin
  insert into centre_invoices(id, org_id, kind, household_id, student_id, period_start, period_end) values (i, p_org, 'lesson', p_hh, p_stu, current_date, current_date);
  insert into centre_invoice_lines(org_id, invoice_id, position, description, qty, unit_cents) values (p_org, i, 1, 'Lessons', 1, p_total);
  update centre_invoices set net_cents = p_total, total_cents = p_total where id = i;
  return i;
end $$;
create function pg_temp.pay(p_org uuid, p_hh uuid, p_inv uuid, p_cents bigint, p_on date) returns uuid language plpgsql as $$
declare p uuid := gen_random_uuid();
begin
  insert into centre_payments(id, org_id, household_id, method, amount_cents, received_on) values (p, p_org, p_hh, 'cash', p_cents, p_on);
  insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (p_org, p, p_inv, p_cents);
  return p;
end $$;
create function pg_temp.unpay(p_org uuid, p_pay uuid, p_inv uuid, p_on date) returns void language plpgsql as $$
declare p centre_payments;
begin
  select * into p from centre_payments where id = p_pay;
  insert into centre_payments(id, org_id, kind, reverses_payment_id, household_id, method, amount_cents, received_on)
  values (gen_random_uuid(), p_org, 'reversal', p_pay, p.household_id, p.method, p.amount_cents, p_on);
  insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) select p_org, r.id, p_inv, -p.amount_cents from centre_payments r where r.reverses_payment_id = p_pay;
end $$;
create function pg_temp.credit(p_org uuid, p_inv uuid, p_cents bigint, p_on date) returns uuid language plpgsql as $$
declare c uuid := gen_random_uuid(); v centre_invoices;
begin
  select * into v from centre_invoices where id = p_inv;
  insert into centre_invoices(id, org_id, kind, household_id, student_id, credits_invoice_id, reason) values (c, p_org, 'credit_note', v.household_id, v.student_id, p_inv, 'Test credit');
  insert into centre_invoice_lines(org_id, invoice_id, position, description, qty, unit_cents) values (p_org, c, 1, 'Credit', 1, p_cents);
  update centre_invoices set status = 'issued', issue_date = p_on, net_cents = p_cents, total_cents = p_cents where id = c;
  return c;
end $$;
create function pg_temp.call(p_user text, p_sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  perform set_config('role', 'authenticated', true);
  execute p_sql into r;
  perform set_config('role', 'postgres', true);
  return r;
end $$;
create function pg_temp.refused(p_user text, p_sql text, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  perform set_config('role', case when p_user = '' then 'anon' else 'authenticated' end, true);
  begin execute p_sql; exception when others then m := sqlerrm; end;
  perform set_config('role', 'postgres', true);
  if m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS refused: % (%)', p_msg, m;
end $$;
create function pg_temp.sc(p text) returns text language plpgsql security definer as $$ declare r text; begin execute p into r; return r; end $$;
-- the server's calls (service role)
create function pg_temp.srv(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', '', false);
  perform set_config('role', 'service_role', true);
  execute p_sql into r;
  perform set_config('role', 'postgres', true);
  return r;
end $$;
grant execute on all functions in schema pg_temp to public;

-- a family: household + student + guardians created in the order given (an email of '-' = a guardian with a phone only)
create function pg_temp.fam(p_org text, p_key text, p_owner uuid, p_emails text[]) returns void language plpgsql as $$
declare hid uuid := gen_random_uuid(); sid uuid := gen_random_uuid(); i int := 0; e text;
begin
  insert into households(id, org_id, name) values (hid, t.id(p_org), 'Family ' || p_key);
  insert into students(id, tutor_id, org_id, name, household_id) values (sid, p_owner, t.id(p_org), 'Kid ' || p_key, hid);
  foreach e in array p_emails loop
    i := i + 1;
    insert into guardians(org_id, household_id, name, phone, email, created_at) values (t.id(p_org), hid, 'Guardian ' || p_key || '.' || i, '91234567', case when e = '-' then null else e end, now() - make_interval(secs => 100 - i));
  end loop;
  perform t.put(p_org || '_h_' || p_key, hid); perform t.put(p_org || '_s_' || p_key, sid);
end $$;
create function pg_temp.g(p_org text, p_key text, p_n int) returns uuid language sql as $$
  select id from guardians where org_id = t.id(p_org) and household_id = t.id(p_org || '_h_' || p_key) order by created_at, id offset p_n - 1 limit 1 $$;
create function pg_temp.ai(p_org text, p_key text, p_total bigint, p_issue date, p_due date, p_kind text default 'lesson') returns uuid language sql as $$
  select pg_temp.inv(t.id(p_org), t.id(p_org || '_h_' || p_key), t.id(p_org || '_s_' || p_key), p_kind, p_total, p_issue, p_due) $$;
create function pg_temp.status_of(p_org text) returns jsonb language sql as $$ select pg_temp.call('00000000-0000-0000-0000-00000000e701', format('select email_queue_status(%L)', t.id(p_org))) $$;
create function pg_temp.n(p text) returns int language sql as $$ select pg_temp.sc(p)::int $$;
-- how many queue rows an invoice has in a state
create function pg_temp.qn(p_inv uuid, p_status text default null) returns int language sql as $$
  select pg_temp.sc(format('select count(*) from email_queue where invoice_id = %L and (%L is null or status = %L)', p_inv, p_status, p_status))::int $$;
-- pretend the queue and the log are older (the log refuses edits on purpose: switch its guard off for these test-only time shifts)
create function pg_temp.age_log(p_org uuid, p_interval interval) returns void language plpgsql security definer as $$
begin
  alter table email_send_log disable trigger email_log_guard;
  update email_send_log set at = at - p_interval where org_id = p_org;
  alter table email_send_log enable trigger email_log_guard;
end $$;

-- ------------------------------------------------------------------ the centres
-- A: staff press Send        B: automatic on issue (receipts, late-fee notices, reminders)      C: small caps        D: email off (the default)       N: another centre
select t.as(:'o1'); set role authenticated;
select t.put('A', org_create_centre('Email Centre A', pg_temp.settings(pg_temp.mail('{}'))));
select t.put('B', org_create_centre('Email Centre B', pg_temp.settings(pg_temp.mail('{"mode":"auto_on_issue","receipts":true,"late_fee_notice":true,"reminders":{"enabled":true,"first_after_days":3,"repeat_days":7,"max_count":3}}'))));
select t.put('C', org_create_centre('Email Centre C', pg_temp.settings(pg_temp.mail('{"daily_cap":3,"per_hour":2}'))));
select t.put('D', org_create_centre('Email Centre D', t.centre_settings()));
select t.as(:'o2');
select t.put('N', org_create_centre('Email Centre N', pg_temp.settings(pg_temp.mail('{}'))));
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('A'), :'paym', 'Payments Pat', 'staff', array['record_payments'], 'active'),
  (t.id('A'), :'bill', 'Billing Bea',  'staff', array['issue_invoices'], 'active'),
  (t.id('A'), :'rev',  'Revenue Rae',  'staff', array['view_revenue'], 'active'),
  (t.id('A'), :'tut',  'Tutor Tia',    'tutor', '{}', 'active'),
  (t.id('A'), :'par',  'Parent Pia',   'parent', '{}', 'active'),
  (t.id('A'), :'off',  'Switched off', 'staff', array['record_payments', 'issue_invoices'], 'disabled');
select t.put('SOLO', org_personal(:'solo'));

-- families (all addresses end in @example.test)
select pg_temp.fam('A', '1', :'o1', array['one.a@example.test', 'one.b@example.test']);      -- two guardians, both with an address: only the FIRST gets mail by default
select pg_temp.fam('A', '2', :'o1', array['-', 'two.b@example.test']);                         -- the first guardian has no email: nobody is mailed (we don't skip to the second)
select pg_temp.fam('A', '3', :'o1', array['three@example.test']);
select pg_temp.fam('A', '4', :'o1', array['four@example.test']);
select pg_temp.fam('A', '5', :'o1', array['five@example.test']);
select pg_temp.fam('A', '6', :'o1', array['six@example.test']);
select pg_temp.fam('A', '7', :'o1', array['seven@example.test']);
select pg_temp.fam('A', '8', :'o1', array['not-an-email']);                                    -- an address that is not valid
select pg_temp.fam('N', '1', :'o2', array['other@example.test']);
select pg_temp.fam('B', '1', :'o1', array['b.one@example.test']);
select pg_temp.fam('B', '2', :'o1', array['-']);                                               -- nobody to mail
select pg_temp.fam('B', '3', :'o1', array['b.three@example.test']);
select pg_temp.fam('B', '4', :'o1', array['b.four@example.test']);
select pg_temp.fam('B', '5', :'o1', array['b.five@example.test']);
select pg_temp.fam('B', '6', :'o1', array['b.six@example.test']);
select pg_temp.fam('B', '7', :'o1', array['b.seven@example.test']);
select pg_temp.fam('B', '8', :'o1', array['b.eight@example.test']);
select pg_temp.fam('C', '1', :'o1', array['c.one@example.test']);
select pg_temp.fam('C', '2', :'o1', array['c.two@example.test']);
select pg_temp.fam('C', '3', :'o1', array['c.three@example.test']);
select pg_temp.fam('C', '4', :'o1', array['c.four@example.test']);
select pg_temp.fam('C', '5', :'o1', array['c.five@example.test']);
select pg_temp.fam('D', '1', :'o1', array['d.one@example.test']);
-- a household with no guardian at all
insert into households(id, org_id, name) values ('00000000-0000-0000-0000-00000000e7a1', t.id('B'), 'Family B-empty');
insert into students(id, tutor_id, org_id, name, household_id) values ('00000000-0000-0000-0000-00000000e7a2', :'o1', t.id('B'), 'Kid B-empty', '00000000-0000-0000-0000-00000000e7a1');

-- ================================================================== 1. the settings validator
create function pg_temp.vok(p jsonb, p_msg text) returns void language plpgsql as $$
begin perform org_validate_settings(pg_temp.settings(p)); raise notice 'PASS valid: %', p_msg; exception when others then raise exception 'FAIL: % was refused (%)', p_msg, sqlerrm; end $$;
create function pg_temp.vbad(p jsonb, p_expect text, p_msg text, p_share boolean default true) returns void language plpgsql as $$
declare m text := 'accepted';
begin begin perform org_validate_settings(pg_temp.settings(p, p_share)); exception when others then m := sqlerrm; end;
  if m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if; raise notice 'PASS refused: % (%)', p_msg, m; end $$;
select pg_temp.vok(pg_temp.mail('{"mode":"off"}'), 'mode off');
select pg_temp.vok(pg_temp.mail('{"mode":"staff_send"}'), 'mode staff_send');
select pg_temp.vok(pg_temp.mail('{"mode":"auto_on_issue"}'), 'mode auto_on_issue');
select pg_temp.vbad(pg_temp.mail('{"mode":"whenever"}'), 'Unknown email sending setting', 'unknown mode');
select pg_temp.vok('{}', 'no email section at all (settings saved before this migration)');
select org_validate_settings(t.centre_settings());
select pg_temp.vbad(pg_temp.mail('{"receipts":"yes"}'), 'Setting', 'receipts must be yes or no');
select pg_temp.vbad(pg_temp.mail('{"late_fee_notice":1}'), 'Setting', 'late-fee notice must be yes or no');
select pg_temp.vbad(pg_temp.mail('{"reminders":{"enabled":"x"}}'), 'Setting', 'reminders switch must be yes or no');
select pg_temp.vok(pg_temp.mail('{"receipts":true,"late_fee_notice":true,"reminders":{"enabled":true,"first_after_days":3,"repeat_days":7,"max_count":3}}'), 'everything on');
select pg_temp.vbad(pg_temp.mail('{"reminders":{"first_after_days":0}}'), 'Send the first reminder', 'first reminder: 0 days refused');
select pg_temp.vok(pg_temp.mail('{"reminders":{"first_after_days":1}}'), 'first reminder: 1 day');
select pg_temp.vok(pg_temp.mail('{"reminders":{"first_after_days":90}}'), 'first reminder: 90 days');
select pg_temp.vbad(pg_temp.mail('{"reminders":{"first_after_days":91}}'), 'Send the first reminder', 'first reminder: 91 days refused');
select pg_temp.vok(pg_temp.mail('{"reminders":{"repeat_days":0}}'), 'repeat 0 (one reminder only)');
select pg_temp.vok(pg_temp.mail('{"reminders":{"repeat_days":90}}'), 'repeat 90');
select pg_temp.vbad(pg_temp.mail('{"reminders":{"repeat_days":91}}'), 'Repeat reminders', 'repeat 91 refused');
select pg_temp.vbad(pg_temp.mail('{"reminders":{"repeat_days":-1}}'), 'Repeat reminders', 'repeat -1 refused');
select pg_temp.vbad(pg_temp.mail('{"reminders":{"max_count":0}}'), 'Send 1-10', 'max 0 refused');
select pg_temp.vok(pg_temp.mail('{"reminders":{"max_count":10}}'), 'max 10');
select pg_temp.vbad(pg_temp.mail('{"reminders":{"max_count":11}}'), 'Send 1-10', 'max 11 refused');
select pg_temp.vbad(pg_temp.mail('{"reminders":{"max_count":2.5}}'), 'Send 1-10', 'max 2.5 refused');
select pg_temp.vbad(pg_temp.mail('{"daily_cap":0}'), 'Emails per day', 'daily cap 0 refused');
select pg_temp.vok(pg_temp.mail('{"daily_cap":1}'), 'daily cap 1');
select pg_temp.vok(pg_temp.mail('{"daily_cap":300}'), 'daily cap 300 (Brevo free)');
select pg_temp.vbad(pg_temp.mail('{"daily_cap":301}'), 'Emails per day', 'daily cap 301 refused');
select pg_temp.vbad(pg_temp.mail('{"per_hour":0}'), 'Emails per hour', 'per hour 0 refused');
select pg_temp.vok(pg_temp.mail('{"per_hour":300}'), 'per hour 300');
select pg_temp.vbad(pg_temp.mail('{"per_hour":301}'), 'Emails per hour', 'per hour 301 refused');
select pg_temp.vok(pg_temp.mail('{"templates":{"invoice":{"subject":"Invoice {number} from {centre}","body":"Hi {name}, {amount} is due on {due_date}. {link} {contact}"},"receipt":{"body":"Thanks {name}, received on {paid_on}"},"reminder":{"body":"{days_overdue} days late"},"late_fee":{"subject":"Late fee {number}"}}}'), 'wording with every field');
select pg_temp.vok(pg_temp.mail('{"templates":{"invoice":{"subject":"","body":""}}}'), 'blank wording = our default');
select pg_temp.vbad(pg_temp.mail('{"templates":{"invoice":{"body":"Hi {nam}"}}}'), 'Email wording can only use', 'an unknown field is refused');
select pg_temp.vbad(pg_temp.mail('{"templates":{"invoice":{"body":"Hi {name"}}}'), 'Email wording can only use', 'a stray brace is refused');
select pg_temp.vbad(pg_temp.mail('{"templates":{"reminder":{"subject":"{{name}}"}}}'), 'Email wording can only use', 'double braces are refused');
select pg_temp.vbad(pg_temp.mail(('{"templates":{"receipt":{"subject":' || to_jsonb(repeat('x', 121))::text || '}}}')::jsonb), 'Email wording is too long', 'subject over 120 characters refused');
select pg_temp.vok(pg_temp.mail(('{"templates":{"receipt":{"subject":' || to_jsonb(repeat('x', 120))::text || '}}}')::jsonb), 'subject of exactly 120 characters');
select pg_temp.vbad(pg_temp.mail(('{"templates":{"late_fee":{"body":' || to_jsonb(repeat('x', 1001))::text || '}}}')::jsonb), 'Email wording is too long', 'message over 1000 characters refused');
select pg_temp.vok(pg_temp.mail(('{"templates":{"late_fee":{"body":' || to_jsonb(repeat('x', 1000))::text || '}}}')::jsonb), 'message of exactly 1000 characters');
select pg_temp.vbad(pg_temp.mail('{"templates":{"invoice":{"body":5}}}'), 'Email wording must be text', 'wording must be text');
select pg_temp.vbad(pg_temp.mail('{"mode":"staff_send"}'), 'Emailing invoices needs', 'email needs the shareable link', false);
select pg_temp.vbad(pg_temp.mail('{"mode":"auto_on_issue"}'), 'Emailing invoices needs', 'automatic email needs the shareable link', false);
select org_validate_settings(pg_temp.settings(pg_temp.mail('{"mode":"off"}'), false));
select t.ok(true, 'email off may keep the shareable link switched off');
select t.ok((select (pg_temp.settings(pg_temp.mail('{}')) #>> '{profile,reply_to_email}') = 'office@centre.test'), 'the reply-to address is the centre''s own profile setting');
do $$ begin
  begin perform org_validate_settings(jsonb_set(pg_temp.settings(pg_temp.mail('{}')), '{profile,reply_to_email}', '"not an address"')); raise exception 'FAIL: bad reply-to accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'PASS refused: reply-to that is not an address (%)', sqlerrm; end;
end $$;

-- ================================================================== 2. small helpers
select t.ok(email_valid('a.b@example.test') and email_valid('x@y.co') and not email_valid('x@y') and not email_valid('x y@z.com') and not email_valid('a@b@c.com') and not email_valid('')
            and not email_valid(null) and not email_valid('a@b.c') and not email_valid(repeat('a', 250) || '@b.com'), 'email_valid: ordinary addresses yes, malformed no');
select t.ok(email_mask('jane.tan@gmail.com') = 'j***@g***.com' and email_mask('A@mail.example.test') = 'A***@m***.test' and email_mask('bad') = '***' and email_mask(null) = '***'
            and email_mask('  padded@x.org ') = 'p***@x***.org', 'email_mask: first letters only, junk fully hidden');
select t.ok(email_cfg('{}') = '{"mode":"off","receipts":false,"late_fee_notice":false,"reminders":{"enabled":false,"first_after_days":3,"repeat_days":7,"max_count":3},"daily_cap":200,"per_hour":60,
  "share_link":true,"reply_to":null,"centre_name":null,"templates":{}}'::jsonb, 'email_cfg: defaults (email off, 200 a day, 60 an hour, reminders after 3 days then every 7, at most 3)');

-- ================================================================== 3. email is OFF by default (centre D)
select pg_temp.ai('D', '1', 10000, (select today - 3 from td), (select today + 4 from td)) as d1 \gset
select t.ok(pg_temp.n('select count(*) from email_queue where org_id = ' || quote_literal(t.id('D'))) = 0, 'off: issuing an invoice queues nothing');
select pg_temp.refused(:'o1', format('select email_enqueue(%L, array[%L]::uuid[])', t.id('D'), :'d1'), 'NOT_ALLOWED', 'off: pressing Send is refused');
select pg_temp.refused(:'o1', format('select email_enqueue_unsent(%L)', t.id('D')), 'NOT_ALLOWED', 'off: "send all unsent" is refused');
select pg_temp.pay(t.id('D'), t.id('D_h_1'), :'d1', 1000, (select today from td)) is not null as x \gset
select t.ok(pg_temp.n('select count(*) from email_queue where org_id = ' || quote_literal(t.id('D'))) = 0, 'off: recording a payment queues no receipt');
select t.ok(pg_temp.status_of('D')->>'mode' = 'off' and (pg_temp.status_of('D')->>'queued')::int = 0, 'off: the status screen says so');
select t.ok((pg_temp.srv(format('select email_claim(%L, 20, 1000)', t.id('D')))) = '[]'::jsonb, 'off: nothing to claim');

-- ================================================================== 4. staff presses Send (centre A)
select pg_temp.ai('A', '1', 20000, (select today - 3 from td), (select today + 4 from td)) as a1 \gset
select pg_temp.ai('A', '2', 20000, (select today - 3 from td), (select today + 4 from td)) as a2 \gset
select pg_temp.ai('A', '3', 20000, (select today - 3 from td), (select today + 4 from td)) as a3 \gset
select t.ok(pg_temp.n('select count(*) from email_queue where org_id = ' || quote_literal(t.id('A'))) = 0, 'staff_send: issuing an invoice queues nothing by itself');
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L]::uuid[])', t.id('A'), :'a1')) as r \gset
select t.ok((:'r'::jsonb->>'queued')::int = 1 and (:'r'::jsonb->>'skipped')::int = 0, 'the owner presses Send: ONE message queued for a family with two guardians (the first one only)');
select t.ok((select count(*) = 1 and bool_and(guardian_id = pg_temp.g('A', '1', 1) and status = 'queued' and requested_by = :'o1' and kind = 'invoice' and attempts = 0 and dedupe_key is not null) from email_queue where invoice_id = :'a1'),
            'it is for the first guardian, kept as "queued", records who pressed the button and holds no address');
select t.ok((select count(*) = 0 from information_schema.columns where table_schema = 'public' and table_name in ('email_queue', 'email_send_log') and (column_name ilike '%email%' or column_name ilike '%address%' or column_name ilike '%to_addr%')),
            'neither table has a column for an address (the log keeps a masked form in to_masked)');
select t.ok((:'r'::jsonb#>>'{status,queued}')::int = 1, 'the answer carries the new queue status');
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L]::uuid[])', t.id('A'), :'a1')) as r \gset
select t.ok((:'r'::jsonb->>'queued')::int = 0 and :'r'::jsonb#>>'{problems,0,reason}' = 'already_sent' and pg_temp.qn(:'a1') = 1, 'pressing Send twice does not queue it twice (already_sent)');
-- billing contacts: flagged guardians replace the default
select pg_temp.call(:'o1', format('select email_set_billing_contacts(%L, %L, array[%L]::uuid[])', t.id('A'), t.id('A_h_1'), pg_temp.g('A', '1', 2))) as c \gset
select t.ok((:'c'::jsonb->>'flagged')::boolean and (select count(*) = 1 from jsonb_array_elements(:'c'::jsonb->'guardians') x where (x->>'receives')::boolean and x->>'to_masked' = 'o***@e***.test'),
            'billing contact: choosing the second guardian makes them the only recipient (masked in the screen)');
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L]::uuid[], true)', t.id('A'), :'a1')) as r \gset
select t.ok(:'r'::jsonb#>>'{problems,0,reason}' = 'too_soon' and pg_temp.qn(:'a1') = 1, 'a deliberate resend inside 10 minutes is refused (too_soon)');
update email_queue set requested_at = requested_at - interval '11 minutes' where invoice_id = :'a1';
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L]::uuid[], true)', t.id('A'), :'a1')) as r \gset
select t.ok((:'r'::jsonb->>'queued')::int = 1 and pg_temp.qn(:'a1') = 2
            and (select guardian_id from email_queue where invoice_id = :'a1' order by requested_at desc limit 1) = pg_temp.g('A', '1', 2), 'after the wait the resend goes to the flagged guardian');
update email_queue set requested_at = requested_at - interval '11 minutes' where invoice_id = :'a1';
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L]::uuid[], true)', t.id('A'), :'a1')) as r \gset
update email_queue set requested_at = requested_at - interval '11 minutes' where invoice_id = :'a1';
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L]::uuid[], true)', t.id('A'), :'a1')) as r \gset
select t.ok(:'r'::jsonb#>>'{problems,0,reason}' = 'daily_limit' and pg_temp.qn(:'a1') = 3, 'at most 3 sends of one invoice in 24 hours (daily_limit)');
select pg_temp.call(:'o1', format('select email_set_billing_contacts(%L, %L, array[]::uuid[])', t.id('A'), t.id('A_h_1')))->>'flagged' = 'false' as back \gset
select t.ok(:'back', 'an empty list puts the family back on "the first guardian"');
select pg_temp.refused(:'o1', format('select email_set_billing_contacts(%L, %L, array[%L]::uuid[])', t.id('A'), t.id('A_h_1'), pg_temp.g('A', '3', 1)), 'NOT_FOUND', 'a guardian of another family can''t be made a billing contact');
select pg_temp.refused(:'o1', format('select email_set_billing_contacts(%L, %L, array[%L]::uuid[])', t.id('A'), t.id('N_h_1'), pg_temp.g('N', '1', 1)), 'NOT_FOUND', 'another centre''s family can''t be reached');
-- two flagged guardians: both are mailed
select pg_temp.call(:'o1', format('select email_set_billing_contacts(%L, %L, array[%L, %L]::uuid[])', t.id('A'), t.id('A_h_1'), pg_temp.g('A', '1', 1), pg_temp.g('A', '1', 2))) is not null as x \gset
select pg_temp.ai('A', '1', 15000, (select today - 2 from td), (select today + 5 from td)) as a1b \gset
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L]::uuid[])', t.id('A'), :'a1b')) as r \gset
select t.ok((:'r'::jsonb->>'queued')::int = 2 and pg_temp.qn(:'a1b') = 2, 'two billing contacts: both are mailed');
select pg_temp.call(:'o1', format('select email_set_billing_contacts(%L, %L, array[]::uuid[])', t.id('A'), t.id('A_h_1'))) is not null as x \gset
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L]::uuid[])', t.id('A'), :'a2')) as r \gset
select t.ok((:'r'::jsonb->>'queued')::int = 0 and :'r'::jsonb#>>'{problems,0,reason}' = 'no_email' and pg_temp.qn(:'a2') = 0, 'first guardian without an address: nothing queued, staff are told (no_email)');
select pg_temp.ai('A', '8', 5000, (select today - 1 from td), (select today + 6 from td)) as a8 \gset
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L]::uuid[])', t.id('A'), :'a8')) as r \gset
select t.ok(:'r'::jsonb#>>'{problems,0,reason}' = 'no_email' and pg_temp.qn(:'a8') = 0, 'a malformed address counts as no address');
-- invoices that are never mailed
select pg_temp.draft(t.id('A'), t.id('A_h_3'), t.id('A_s_3'), 5000) as dr \gset
select pg_temp.credit(t.id('A'), :'a3', 1000, (select today from td)) as cn \gset
select pg_temp.ai('A', '4', 10000, (select today - 1 from td), (select today + 6 from td)) as a4 \gset
select pg_temp.ai('A', '5', 10000, (select today - 1 from td), (select today + 6 from td)) as a5 \gset
select pg_temp.credit(t.id('A'), :'a5', 10000, (select today from td)) is not null as x \gset
select pg_temp.ai('A', '6', 10000, (select today - 1 from td), (select today + 6 from td)) as a6 \gset
select pg_temp.pay(t.id('A'), t.id('A_h_6'), :'a6', 10000, (select today from td)) is not null as x \gset
select pg_temp.inv(t.id('A'), t.id('A_h_7'), t.id('A_s_7'), 'opening', 10000, (select today - 1 from td), (select today + 6 from td), 'OLD-1') as a7imp \gset
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L, %L, %L, %L, %L]::uuid[])', t.id('A'), :'dr', :'cn', :'a5', :'a6', :'a7imp')) as r \gset
select t.ok((:'r'::jsonb->>'queued')::int = 0 and (:'r'::jsonb->>'skipped')::int = 5
            and (select array_agg(x->>'reason' order by x->>'reason') from jsonb_array_elements(:'r'::jsonb->'problems') x) = array['not_billable', 'not_billable', 'not_issued', 'paid', 'void'],
            'never mailed: a draft, a credit note, an imported opening balance, a fully credited invoice and a fully paid invoice');
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L]::uuid[])', t.id('A'), (select id from centre_invoices where org_id = t.id('N') limit 1))) as r \gset
select t.ok((:'r'::jsonb->>'queued')::int = 0 and :'r'::jsonb#>>'{problems,0,reason}' = 'not_found', 'another centre''s invoice: not found, nothing queued');
-- a part payment still gets the invoice
select pg_temp.pay(t.id('A'), t.id('A_h_4'), :'a4', 4000, (select today from td)) is not null as x \gset
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L]::uuid[])', t.id('A'), :'a4'))->>'queued' = '1' as ok \gset
select t.ok(:'ok', 'a part-paid invoice can be mailed (the message shows what is still owed)');
-- a late-fee invoice uses the late-fee wording
select pg_temp.ai('A', '3', 1000, (select today - 1 from td), (select today + 6 from td), 'late_fee') as lf3 \gset
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L]::uuid[])', t.id('A'), :'lf3'))->>'queued' = '1' as ok \gset
select t.ok(:'ok' and (select kind = 'late_fee' from email_queue where invoice_id = :'lf3'), 'a late-fee invoice is queued as a late-fee notice');
-- send all unsent
select pg_temp.call(:'o1', format('select email_enqueue_unsent(%L)', t.id('A'))) as r \gset
select t.ok((:'r'::jsonb->>'queued')::int = 1 and pg_temp.qn(:'a3') = 1, '"send all unsent" queues only what was never queued (family 3''s invoice; the rest already were or can''t be mailed)');
select pg_temp.call(:'o1', format('select email_enqueue_unsent(%L)', t.id('A')))->>'queued' = '0' as ok \gset
select t.ok(:'ok', '"send all unsent" a second time queues nothing');
select t.ok((pg_temp.call(:'o1', format('select email_enqueue_unsent(%L, %L)', t.id('A'), (select today from td) - 200))->>'queued')::int = 0, '"send all unsent" for an old month with nothing in it');

-- ================================================================== 5. who may call what
select pg_temp.call(:'bill', format('select email_enqueue(%L, array[%L]::uuid[])', t.id('A'), :'a6')) is not null as x \gset
select t.ok(true, 'staff with "Issue invoices" may press Send');
select pg_temp.refused(:'paym', format('select email_enqueue(%L, array[%L]::uuid[])', t.id('A'), :'a6'), 'NOT_ALLOWED', 'staff with only "Record payments" can''t press Send');
select t.ok(pg_temp.call(:'paym', format('select email_queue_status(%L)', t.id('A')))->>'mode' = 'staff_send', 'but they may read the status');
select pg_temp.refused(:'paym', format('select email_queue_cancel(%L, array[gen_random_uuid()])', t.id('A')), 'NOT_ALLOWED', 'and may not cancel messages');
select pg_temp.refused(:'paym', format('select email_set_billing_contacts(%L, %L, array[]::uuid[])', t.id('A'), t.id('A_h_1')), 'NOT_ALLOWED', 'or choose billing contacts');
select pg_temp.refused(:'rev', format('select email_queue_status(%L)', t.id('A')), 'NOT_ALLOWED', 'staff with only "View revenue" can''t even read it');
select pg_temp.refused(:'tut', format('select email_queue_status(%L)', t.id('A')), 'NOT_FOUND', 'a centre tutor sees nothing');
select pg_temp.refused(:'tut', format('select email_enqueue(%L, array[%L]::uuid[])', t.id('A'), :'a6'), 'NOT_FOUND', 'a tutor can''t send');
select pg_temp.refused(:'par', format('select email_queue_list(%L)', t.id('A')), 'NOT_FOUND', 'a parent sees nothing');
select pg_temp.refused(:'off', format('select email_queue_status(%L)', t.id('A')), 'NOT_FOUND', 'switched-off staff see nothing');
select pg_temp.refused(:'o2', format('select email_queue_status(%L)', t.id('A')), 'NOT_FOUND', 'another centre''s owner sees nothing');
select pg_temp.refused(:'o2', format('select email_enqueue(%L, array[%L]::uuid[])', t.id('A'), :'a6'), 'NOT_FOUND', 'another centre''s owner can''t send');
select pg_temp.refused(:'o1', format('select email_queue_status(%L)', t.id('SOLO')), 'NOT_FOUND', 'a solo organisation is refused');
select pg_temp.refused(:'solo', format('select email_queue_status(%L)', t.id('SOLO')), 'NOT_FOUND', 'a solo tutor is refused on their own organisation');
select pg_temp.refused(:'solo', format('select email_enqueue(%L, array[gen_random_uuid()])', t.id('SOLO')), 'NOT_FOUND', 'a solo tutor can''t send family email');
select pg_temp.refused('', format('select email_queue_status(%L)', t.id('A')), 'permission denied', 'anonymous callers have no access');
select pg_temp.refused(:'o1', 'select * from email_queue', 'permission denied', 'a signed-in owner can''t read the queue table');
select pg_temp.refused(:'o1', 'select * from email_send_log', 'permission denied', 'nor the log table');
select pg_temp.refused(:'o1', format('select email_claim(%L, 5, 100)', t.id('A')), 'permission denied', 'the owner can''t call the server''s claim (it returns addresses)');
select pg_temp.refused(:'o1', format('select email_complete(gen_random_uuid(), %L)', 'sent'), 'permission denied', 'nor report a result');
select pg_temp.refused(:'o1', 'select email_mark_bounce(''abcdefghij'', ''hard_bounce'')', 'permission denied', 'nor mark a bounce');
select pg_temp.refused(:'o1', format('select email_plan_reminders(%L)', t.id('B')), 'permission denied', 'nor run the reminder planner');
select pg_temp.refused(:'o1', 'select email_platform_sent_24h()', 'permission denied', 'nor read the platform count');
select pg_temp.refused('', format('select email_claim(%L, 5, 100)', t.id('A')), 'permission denied', 'anonymous can''t claim either');

-- ================================================================== 6. the queue screens
select t.ok(pg_temp.status_of('A')->>'mode' = 'staff_send' and (pg_temp.status_of('A')->>'queued')::int = (select count(*) from email_queue where org_id = t.id('A') and status = 'queued'), 'status: the queued count is the real one');
select pg_temp.call(:'o1', format('select email_queue_list(%L)', t.id('A'))) as l \gset
select t.ok(jsonb_array_length(:'l'::jsonb) = (select count(*) from email_queue where org_id = t.id('A'))
            and (select bool_and(x->>'to_masked' ~ '^[a-z]\*\*\*@[a-z]\*\*\*\.test$' or x->>'to_masked' is null) from jsonb_array_elements(:'l'::jsonb) x)
            and (:'l'::text !~ '@example\.test'), 'the queue list shows masked addresses only');
select t.ok((select (x->>'by') = 'Owner' or x->>'by' is not null from jsonb_array_elements(:'l'::jsonb) x limit 1), 'the queue list says who pressed Send');
select pg_temp.call(:'o1', format('select email_queue_list(%L, %L)', t.id('A'), 'sent')) = '[]'::jsonb as ok \gset
select t.ok(:'ok', 'filter by state');
select pg_temp.call(:'o1', format('select email_queue_cancel(%L, array[%L]::uuid[])', t.id('A'), (select id from email_queue where invoice_id = :'a4' limit 1))) as r \gset
select t.ok((:'r'::jsonb->>'cancelled')::int = 1 and (select status = 'cancelled' and reason = 'cancelled_by_staff' from email_queue where invoice_id = :'a4')
            and (select count(*) = 1 from email_send_log where invoice_id = :'a4' and result = 'cancelled' and by_user = :'o1'), 'staff can cancel a queued message; it is logged with who did it');
select pg_temp.call(:'o1', format('select email_queue_cancel(%L, array[%L]::uuid[])', t.id('A'), (select id from email_queue where invoice_id = :'a4' limit 1)))->>'cancelled' = '0' as ok \gset
select t.ok(:'ok', 'cancelling twice does nothing');
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L]::uuid[])', t.id('A'), :'a4'))->>'queued' = '1' as ok \gset
select t.ok(:'ok', 'a cancelled message can be queued again');
select t.ok((select count(*) >= 3 from audit_log where org_id = t.id('A') and action in ('email_enqueue', 'email_queue_cancel')), 'every Send and Cancel is in the audit log (counts only)');
select t.ok((select count(*) = 0 from audit_log where org_id = t.id('A') and (before::text ~ '@' or after::text ~ '@') and action like 'email_%'), 'the audit lines hold no address');

-- ================================================================== 7. the server claims, sends and reports (centre A: 200 a day, 60 an hour)
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('A'))) as cl \gset
select t.ok(jsonb_array_length(:'cl'::jsonb) > 0 and (select count(*) = jsonb_array_length(:'cl'::jsonb) from email_queue where org_id = t.id('A') and status = 'sending'), 'claim: what it returns is now "sending"');
select t.ok((select bool_and(x->>'to' ~ '@example\.test$' and x->>'centre' = 'Email Centre' and x->>'reply_to' = 'office@centre.test' and (x#>>'{vars,token}') ~ '^[0-9a-f-]{36}$'
                              and (x#>>'{vars,amount_cents}')::bigint > 0 and x->>'name' is not null and x->>'kind' in ('invoice', 'late_fee') and (x->>'attempt')::int = 1) from jsonb_array_elements(:'cl'::jsonb) x),
            'claim: each message carries the address, the centre''s name and reply-to, the secret link token, what is owed and the attempt number');
select t.ok((select (x#>>'{vars,amount_cents}')::bigint = 6000 and x#>>'{vars,number}' = (select number_text from centre_invoices where id = :'a4') from jsonb_array_elements(:'cl'::jsonb) x where x->>'queue_id' = (select id::text from email_queue where invoice_id = :'a4' and status = 'sending')),
            'claim: a part-paid invoice shows the amount still owed, not the total');
select t.ok((select count(*) = 1 from centre_invoice_share where invoice_id = :'a1'), 'claim: the secret link was made for the invoice (one per invoice)');
select t.ok((select x#>>'{vars,token}' = (select token::text from centre_invoice_share where invoice_id = :'a1') from jsonb_array_elements(:'cl'::jsonb) x where x->>'queue_id' = (select id::text from email_queue where invoice_id = :'a1' limit 1)),
            'claim: the token is the invoice''s own share token (the link the family opens)');
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('A'))) = '[]'::jsonb as ok \gset
select t.ok(:'ok', 'claiming again returns nothing: a message is never handed out twice');
-- report: sent
select (:'cl'::jsonb->0->>'queue_id')::uuid as q1, :'cl'::jsonb->0->>'to' as to1 \gset
select pg_temp.sc(format('select email_complete(%L, %L, null, %L, %L)', :'q1', 'sent', '<2026.msg1@smtp-relay.test>', :'to1')) = 'true' as ok \gset
select t.ok(:'ok' and (select status = 'sent' and attempts = 1 from email_queue where id = :'q1'), 'report sent: the message is sent');
select t.ok((select result = 'sent' and to_masked ~ '^[a-z]\*\*\*@[a-z]\*\*\*\.test$' and brevo_message_id = '<2026.msg1@smtp-relay.test>' and attempt = 1 and template in ('invoice', 'late_fee') and by_user = :'o1'
             from email_send_log where queue_id = :'q1'), 'the log: who, when, a MASKED address, the template, the result, Brevo''s id');
select pg_temp.sc(format('select email_complete(%L, %L, null, null, null)', :'q1', 'sent')) = 'false' as ok \gset
select t.ok(:'ok' and (select count(*) = 1 from email_send_log where queue_id = :'q1'), 'a second report of the same message does nothing');
select t.ok((select count(*) = 0 from email_send_log where org_id = t.id('A') and (coalesce(detail, '') ~ '@' or coalesce(template, '') ~ '@' or coalesce(brevo_message_id, '') ~ 'example\.test$' and false)), 'the log holds no address anywhere');
-- append-only
select pg_temp.refused(:'o1', 'update email_send_log set result = ''sent''', 'permission denied', 'the log can''t be edited from a browser');
do $$ begin
  begin update email_send_log set result = 'sent' where id = (select min(id) from email_send_log); raise exception 'FAIL: log edit allowed';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'PASS the log refuses edits even for the database owner (%)', sqlerrm; end;
  begin delete from email_send_log where id = (select min(id) from email_send_log); raise exception 'FAIL: log delete allowed';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'PASS the log refuses deletes (%)', sqlerrm; end;
end $$;
-- retries: 3 attempts, 15 minutes, 1 hour, 6 hours, then failed for good
select (:'cl'::jsonb->1->>'queue_id')::uuid as q2, :'cl'::jsonb->1->>'to' as to2 \gset
select pg_temp.sc(format('select email_complete(%L, %L, %L, null, %L)', :'q2', 'retry', 'http_503', :'to2')) = 'true' as ok \gset
select t.ok(:'ok' and (select status = 'queued' and attempts = 1 and not_before between now() + interval '14 minutes' and now() + interval '16 minutes' from email_queue where id = :'q2'), 'retry 1: back in the queue, next try in 15 minutes');
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('A')))::text !~ :'q2' as ok \gset
select t.ok(:'ok', 'not handed out before its time');
update email_queue set not_before = now() where id = :'q2';
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('A')))::text ~ :'q2' as ok \gset
select t.ok(:'ok' and (select attempts = 2 from email_queue where id = :'q2'), 'retry 1: handed out again after its time (attempt 2)');
select pg_temp.sc(format('select email_complete(%L, %L, %L, null, %L)', :'q2', 'retry', 'http_503', :'to2')) = 'true' as ok \gset
select t.ok((select status = 'queued' and attempts = 2 and not_before between now() + interval '59 minutes' and now() + interval '61 minutes' from email_queue where id = :'q2'), 'retry 2: next try in 1 hour');
update email_queue set not_before = now() where id = :'q2';
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('A'))) is not null as x \gset
select pg_temp.sc(format('select email_complete(%L, %L, %L, null, %L)', :'q2', 'retry', 'http_503', :'to2')) = 'true' as ok \gset
select t.ok(:'ok' and (select status = 'failed' and attempts = 3 and reason = 'http_503' from email_queue where id = :'q2'), 'retry 3 is the last: after three attempts the message is failed for good');
select t.ok((select array_agg(result order by id) = array['retry', 'retry', 'failed'] from email_send_log where queue_id = :'q2'), 'the log shows every attempt');
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('A')))::text !~ :'q2' as ok \gset
select t.ok(:'ok', 'a failed message is never tried again (no infinite retries)');
-- a delay chosen by the server (rate limit): 12 hours
select (:'cl'::jsonb->2->>'queue_id')::uuid as q3, :'cl'::jsonb->2->>'to' as to3 \gset
select pg_temp.sc(format('select email_complete(%L, %L, %L, null, %L, 720)', :'q3', 'retry', 'http_429', :'to3')) = 'true' as ok \gset
select t.ok((select not_before between now() + interval '11 hours' and now() + interval '13 hours' from email_queue where id = :'q3'), 'the server may ask for a longer wait (a rate limit: 12 hours)');
-- an invalid address: failed, the guardian is marked bad and nothing more goes to it
update email_queue set not_before = now() where id = :'q3';
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('A'))) is not null as x \gset
select pg_temp.sc(format('select email_complete(%L, %L, null, null, %L)', :'q3', 'invalid', :'to3')) = 'true' as ok \gset
select t.ok(:'ok' and (select status = 'failed' and reason = 'invalid_recipient' from email_queue where id = :'q3')
            and (select email_status = 'bad' and email_bad_at is not null from guardians where id = (select guardian_id from email_queue where id = :'q3')), 'an invalid address: failed, and the guardian''s address is marked bad');
select t.ok((pg_temp.status_of('A')->>'bad_addresses')::int = 1 and jsonb_array_length(pg_temp.call(:'o1', format('select email_bad_list(%L)', t.id('A')))) = 1
            and pg_temp.call(:'o1', format('select email_bad_list(%L)', t.id('A')))::text !~ '@example', 'staff see the bad address (masked) on the status and in the list');
select (select guardian_id from email_queue where id = :'q3') as bad_g \gset
select pg_temp.call(:'o1', format('select email_household_contacts(%L, %L)', t.id('A'), (select household_id from guardians where id = :'bad_g'))) as c \gset
select t.ok((select bool_or((x->>'bad')::boolean and not (x->>'receives')::boolean) from jsonb_array_elements(:'c'::jsonb->'guardians') x), 'the family''s contact sheet shows the bad address and that it no longer receives mail');
-- a new message to a bad address is skipped at once
select pg_temp.call(:'o1', format('select email_set_billing_contacts(%L, %L, array[%L]::uuid[])', t.id('A'), (select household_id from guardians where id = :'bad_g'), :'bad_g')) is not null as x \gset
update email_queue set requested_at = requested_at - interval '11 minutes' where invoice_id = (select invoice_id from email_queue where id = :'q3');
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L]::uuid[], true)', t.id('A'), (select invoice_id from email_queue where id = :'q3'))) as r \gset
select t.ok((:'r'::jsonb->>'queued')::int = 0 and :'r'::jsonb#>>'{problems,0,reason}' = 'bad_address', 'pressing Send for a bad address says bad_address and queues nothing');
select pg_temp.call(:'o1', format('select email_set_billing_contacts(%L, %L, array[]::uuid[])', t.id('A'), (select household_id from guardians where id = :'bad_g'))) is not null as x \gset
update guardians set email = 'fixed.' || email where id = :'bad_g';
select t.ok((select email_status = 'ok' and email_bad_at is null from guardians where id = :'bad_g'), 'typing a new address for the guardian clears the "bad" flag');
update guardians set email_status = 'bad', email_bad_at = now() where id = :'bad_g';
select pg_temp.call(:'bill', format('select email_clear_bad(%L, %L)', t.id('A'), :'bad_g'))->>'bad_addresses' = '0' as ok \gset
select t.ok(:'ok' and (select email_status = 'ok' from guardians where id = :'bad_g'), 'staff may also clear the flag by hand ("I fixed it")');
select pg_temp.refused(:'paym', format('select email_clear_bad(%L, %L)', t.id('A'), :'bad_g'), 'NOT_ALLOWED', 'clearing the flag needs "Issue invoices"');
-- bounces from Brevo
select (:'cl'::jsonb->3->>'queue_id')::uuid as q4, :'cl'::jsonb->3->>'to' as to4 \gset
select pg_temp.sc(format('select email_complete(%L, %L, null, %L, %L)', :'q4', 'sent', '<2026.msg4@smtp-relay.test>', :'to4')) = 'true' as ok \gset
select (select guardian_id from email_queue where id = :'q4') as g4 \gset
select pg_temp.sc('select email_mark_bounce(''2026.msg4@smtp-relay.test'', ''soft_bounce'')') = 'true' as ok \gset
select t.ok(:'ok' and (select email_status = 'ok' from guardians where id = :'g4') and (select count(*) = 1 from email_send_log where queue_id = :'q4' and result = 'bounced' and detail = 'soft_bounce'), 'a soft bounce is only noted, the address stays good');
select pg_temp.sc('select email_mark_bounce(''<2026.msg4@smtp-relay.test>'', ''hard_bounce'')') = 'true' as ok \gset
select t.ok(:'ok' and (select email_status = 'bad' from guardians where id = :'g4') and (select count(*) = 2 from email_send_log where queue_id = :'q4' and result = 'bounced'), 'a hard bounce marks the address bad (the message id matches with or without <>) and adds a log line');
select pg_temp.sc('select email_mark_bounce(''unknown.id@nowhere'', ''hard_bounce'')') = 'false' as ok \gset
select t.ok(:'ok', 'a bounce for a message we never sent does nothing');
select pg_temp.sc('select email_mark_bounce(''x'', ''hard_bounce'')') = 'false' as ok \gset
select t.ok(:'ok', 'a too-short id does nothing');
select pg_temp.fam('A', 'z', :'o1', array['zed@example.test']);
select pg_temp.ai('A', 'z', 1000, (select today from td), (select today + 7 from td)) as az \gset
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L]::uuid[])', t.id('A'), :'az')) is not null as x \gset
select (select id from email_queue where invoice_id = :'az') as qz \gset
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('A'))) is not null as x \gset
select pg_temp.sc(format('select email_complete(%L, %L, null, %L, %L)', :'qz', 'sent', '<2026.msgz@smtp-relay.test>', 'zed@example.test')) = 'true' as ok \gset
select pg_temp.sc('select email_mark_bounce(''2026.msgz@smtp-relay.test'', ''spam'')') = 'true' as ok \gset
select t.ok((select email_status = 'bad' from guardians where id = (select guardian_id from email_queue where id = :'qz')), 'a spam complaint also stops mail to that address');
-- queued messages for a guardian who has gone bad are skipped when their turn comes
select pg_temp.fam('A', 'y', :'o1', array['why@example.test']);
select pg_temp.ai('A', 'y', 1000, (select today from td), (select today + 7 from td)) as ay \gset
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L]::uuid[])', t.id('A'), :'ay')) is not null as x \gset
update guardians set email_status = 'bad', email_bad_at = now() where id = pg_temp.g('A', 'y', 1);
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('A'))) is not null as x \gset
select t.ok((select status = 'skipped' and reason = 'bad_address' from email_queue where invoice_id = :'ay') and (select result = 'skipped' and detail = 'bad_address' from email_send_log where invoice_id = :'ay'),
            'a queued message whose address went bad is skipped (not sent), and the log says why');
-- the preview-only rule: the server reports blocked_preview
select pg_temp.fam('A', 'x', :'o1', array['ex@example.test']);
select pg_temp.ai('A', 'x', 1000, (select today from td), (select today + 7 from td)) as ax \gset
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L]::uuid[])', t.id('A'), :'ax')) is not null as x \gset
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('A'))) is not null as x \gset
select pg_temp.sc(format('select email_complete(%L, %L, null, null, %L)', (select id from email_queue where invoice_id = :'ax'), 'blocked_preview', 'ex@example.test')) = 'true' as ok \gset
select t.ok(:'ok' and (select status = 'skipped' and reason = 'preview' from email_queue where invoice_id = :'ax') and (select result = 'blocked_preview' from email_send_log where invoice_id = :'ax'), 'a preview that may not mail this address: skipped, logged as blocked_preview');

-- ================================================================== 8. automatic on issue, receipts and late-fee notices (centre B)
select pg_temp.ai('B', '1', 30000, (select today from td), (select today + 7 from td)) as b1 \gset
select t.ok((select count(*) = 1 and bool_and(kind = 'invoice' and status = 'queued' and requested_by is null and guardian_id = pg_temp.g('B', '1', 1)) from email_queue where invoice_id = :'b1'),
            'auto_on_issue: issuing the invoice queued it for the first guardian, with nobody pressing anything (requested_by is empty = automatic)');
select pg_temp.ai('B', '2', 30000, (select today from td), (select today + 7 from td)) as b2 \gset
select t.ok((select count(*) = 1 and bool_and(status = 'skipped' and reason = 'no_email') from email_queue where invoice_id = :'b2')
            and (select count(*) = 1 from email_send_log where invoice_id = :'b2' and result = 'skipped' and detail = 'no_email' and by_user is null),
            'automatic: a family with no address is recorded as skipped (no_email) and in the log, so staff can see who was missed');
select pg_temp.inv(t.id('B'), '00000000-0000-0000-0000-00000000e7a1', '00000000-0000-0000-0000-00000000e7a2', 'lesson', 5000, (select today from td), (select today + 7 from td)) as be \gset
select t.ok((select count(*) = 1 and bool_and(status = 'skipped' and reason = 'no_contact' and guardian_id is null) from email_queue where invoice_id = :'be'), 'automatic: a household with no guardian at all is skipped (no_contact)');
select pg_temp.inv(t.id('B'), t.id('B_h_8'), t.id('B_s_8'), 'opening', 5000, (select today from td), (select today + 7 from td), 'OLD-9') as bi \gset
select t.ok(pg_temp.qn(:'bi') = 0, 'automatic: an imported opening balance is never mailed');
select pg_temp.credit(t.id('B'), :'b1', 1000, (select today from td)) as bcn \gset
select t.ok(pg_temp.qn(:'bcn') = 0, 'automatic: a credit note is never mailed');
select pg_temp.draft(t.id('B'), t.id('B_h_8'), t.id('B_s_8'), 5000) as bdr \gset
select t.ok(pg_temp.qn(:'bdr') = 0, 'automatic: a draft is not mailed until it is issued');
-- a late-fee invoice sends a late-fee notice (centre B has it on)
select pg_temp.ai('B', '3', 1500, (select today from td), (select today + 7 from td), 'late_fee') as blf \gset
select t.ok((select count(*) = 1 and bool_and(kind = 'late_fee' and requested_by is null) from email_queue where invoice_id = :'blf'), 'late-fee notice: a late-fee invoice queues a late-fee notice');
select pg_temp.cfg(t.id('B'), pg_temp.mail('{"mode":"auto_on_issue","receipts":true,"late_fee_notice":false,"reminders":{"enabled":true,"first_after_days":3,"repeat_days":7,"max_count":3}}'));
select pg_temp.ai('B', '3', 1500, (select today from td), (select today + 7 from td), 'late_fee') as blf2 \gset
select t.ok(pg_temp.qn(:'blf2') = 0, 'late-fee notice off: a late-fee invoice is not mailed');
-- with email on in staff_send mode, a late-fee notice is still automatic once its own switch is on
select pg_temp.cfg(t.id('B'), pg_temp.mail('{"mode":"staff_send","receipts":true,"late_fee_notice":true,"reminders":{"enabled":true,"first_after_days":3,"repeat_days":7,"max_count":3}}'));
select pg_temp.ai('B', '3', 1500, (select today from td), (select today + 7 from td), 'late_fee') as blf3 \gset
select pg_temp.ai('B', '4', 9000, (select today from td), (select today + 7 from td)) as b4s \gset
select t.ok(pg_temp.qn(:'blf3') = 1 and pg_temp.qn(:'b4s') = 0, 'staff_send: the late-fee notice (its own switch) is automatic, the invoice itself still waits for a person');
select pg_temp.cfg(t.id('B'), pg_temp.mail('{"mode":"auto_on_issue","receipts":true,"late_fee_notice":true,"reminders":{"enabled":true,"first_after_days":3,"repeat_days":7,"max_count":3}}'));
-- receipts
select pg_temp.pay(t.id('B'), t.id('B_h_1'), :'b1', 8000, (select today from td)) as pb1 \gset
select t.ok((select count(*) = 1 and bool_and(kind = 'receipt' and payment_id = :'pb1' and invoice_id is null and requested_by is null and guardian_id = pg_temp.g('B', '1', 1)) from email_queue where payment_id = :'pb1'),
            'receipt: recording a payment queues a receipt for the family');
select pg_temp.unpay(t.id('B'), :'pb1', :'b1', (select today from td));
select t.ok((select count(*) = 1 from email_queue where kind = 'receipt' and household_id = t.id('B_h_1')), 'receipt: a reversal does not queue a receipt');
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('B'))) as bcl \gset
select t.ok((select status = 'cancelled' and reason = 'reversed' from email_queue where payment_id = :'pb1') and (select result = 'cancelled' and detail = 'reversed' from email_send_log where queue_id = (select id from email_queue where payment_id = :'pb1')),
            'receipt: a payment reversed before the receipt went out is cancelled (reversed), and the log says so');
select pg_temp.pay(t.id('B'), t.id('B_h_1'), :'b1', 12000, (select today from td)) as pb1b \gset
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('B'))) as bcl2 \gset
select t.ok((select x->>'kind' = 'receipt' and (x#>>'{vars,amount_cents}')::bigint = 12000 and x#>>'{vars,paid_on}' = (select today::text from td) and x#>>'{vars,number}' = (select number_text from centre_invoices where id = :'b1')
                    and x->>'to' = 'b.one@example.test' from jsonb_array_elements(:'bcl2'::jsonb) x where x->>'kind' = 'receipt' limit 1), 'receipt: carries the payment amount, its date and the invoice number it paid');
select pg_temp.ai('B', '5', 8000, (select today from td), (select today + 7 from td)) as b5 \gset
select pg_temp.pay(t.id('B'), t.id('B_h_5'), :'b5', 8000, (select today from td)) as pb5 \gset
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('B'))) as bcl3 \gset
select t.ok((select status = 'cancelled' and reason = 'paid' from email_queue where invoice_id = :'b5' and kind = 'invoice') and (select count(*) = 1 from email_send_log where invoice_id = :'b5' and result = 'cancelled' and detail = 'paid'),
            'paid-before-sent: an invoice that is paid while its email waits is cancelled (paid), never sent');
-- voided (fully credited) before it goes
select pg_temp.ai('B', '6', 8000, (select today from td), (select today + 7 from td)) as b6 \gset
select pg_temp.credit(t.id('B'), :'b6', 8000, (select today from td)) is not null as x \gset
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('B'))) is not null as x \gset
select t.ok((select status = 'cancelled' and reason = 'void' from email_queue where invoice_id = :'b6'), 'voided: a fully credited invoice is cancelled (void) at send time, never sent');
-- switches turned off after queuing
select pg_temp.ai('B', '7', 8000, (select today from td), (select today + 7 from td)) as b7 \gset
select pg_temp.cfg(t.id('B'), pg_temp.mail('{"mode":"off"}'));
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('B'))) is not null as x \gset
select t.ok((select status = 'cancelled' and reason = 'email_off' from email_queue where invoice_id = :'b7'), 'email switched off after queuing: the message is cancelled (email_off) at send time');
select pg_temp.cfg(t.id('B'), pg_temp.mail('{"mode":"auto_on_issue","receipts":true,"late_fee_notice":true,"reminders":{"enabled":true,"first_after_days":3,"repeat_days":7,"max_count":3}}'));
select pg_temp.ai('B', '7', 8000, (select today from td), (select today + 7 from td)) as b7b \gset
select pg_temp.cfg(t.id('B'), pg_temp.mail('{"mode":"auto_on_issue","receipts":false}'), true);
select pg_temp.pay(t.id('B'), t.id('B_h_7'), :'b7b', 1000, (select today from td)) as pb7 \gset
select t.ok(pg_temp.n(format('select count(*) from email_queue where payment_id = %L', :'pb7')) = 0, 'receipts off: no receipt is queued');
select pg_temp.cfg(t.id('B'), pg_temp.mail('{"mode":"auto_on_issue","receipts":true}'), true);
select pg_temp.pay(t.id('B'), t.id('B_h_7'), :'b7b', 1000, (select today from td)) as pb7b \gset
select pg_temp.cfg(t.id('B'), pg_temp.mail('{"mode":"auto_on_issue","receipts":false}'), true);
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('B'))) is not null as x \gset
select t.ok((select status = 'cancelled' and reason = 'receipts_off' from email_queue where payment_id = :'pb7b'), 'receipts switched off after queuing: the receipt is cancelled (receipts_off)');
-- the shareable link switched off after queuing (the validator stops this combination being SAVED; the sender still refuses it)
select pg_temp.cfg(t.id('B'), pg_temp.mail('{"mode":"auto_on_issue","receipts":true}'), true);
select pg_temp.ai('B', '8', 8000, (select today from td), (select today + 7 from td)) as b8 \gset
select pg_temp.cfg(t.id('B'), pg_temp.mail('{"mode":"auto_on_issue","receipts":true}'), false);
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('B'))) is not null as x \gset
select t.ok((select status = 'cancelled' and reason = 'no_link' from email_queue where invoice_id = :'b8'), 'link switched off after queuing: cancelled (no_link), nothing is mailed without the secure link');
select t.ok((select count(*) = 0 from email_queue where org_id = t.id('B') and status = 'sent'), 'nothing in centre B was actually sent (only claimed and cancelled)');
select pg_temp.cfg(t.id('B'), pg_temp.mail('{"mode":"auto_on_issue","receipts":true,"late_fee_notice":true,"reminders":{"enabled":true,"first_after_days":3,"repeat_days":7,"max_count":3}}'), true);
-- email trouble must never stop an invoice being issued or a payment being recorded
alter function public.email_enqueue_rows(uuid, text, uuid, uuid, uuid, uuid, boolean, int) rename to email_enqueue_rows_off;
select pg_temp.ai('B', '8', 7000, (select today from td), (select today + 7 from td)) as bx \gset
select pg_temp.pay(t.id('B'), t.id('B_h_8'), :'bx', 100, (select today from td)) as pbx \gset
alter function public.email_enqueue_rows_off(uuid, text, uuid, uuid, uuid, uuid, boolean, int) rename to email_enqueue_rows;
select t.ok((select status = 'issued' from centre_invoices where id = :'bx') and pg_temp.qn(:'bx') = 0 and exists (select 1 from centre_payments where id = :'pbx'),
            'a failure inside the email code can''t block issuing an invoice or recording a payment');

-- ================================================================== 9. caps, hours, stagger, platform room, stuck messages (centre C: 3 a day, 2 an hour)
select pg_temp.ai('C', '1', 1000, (select today from td), (select today + 7 from td)) as c1 \gset
select pg_temp.ai('C', '2', 1000, (select today from td), (select today + 7 from td)) as c2 \gset
select pg_temp.ai('C', '3', 1000, (select today from td), (select today + 7 from td)) as c3 \gset
select pg_temp.ai('C', '4', 1000, (select today from td), (select today + 7 from td)) as c4 \gset
select pg_temp.ai('C', '5', 1000, (select today from td), (select today + 7 from td)) as c5 \gset
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L,%L,%L,%L,%L]::uuid[])', t.id('C'), :'c1', :'c2', :'c3', :'c4', :'c5')) as r \gset
select t.ok((:'r'::jsonb->>'queued')::int = 5, 'five invoices queued in a centre that may send 3 a day');
select t.ok((:'r'::jsonb#>>'{status,sends_over_days}')::int = 2 and (:'r'::jsonb#>>'{status,remaining_today}')::int = 3 and (:'r'::jsonb#>>'{status,queued}')::int = 5 and (:'r'::jsonb#>>'{status,daily_cap}')::int = 3,
            'status: "5 queued, sends over 2 days" (3 today, 2 tomorrow)');
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('C'))) as cc \gset
select t.ok(jsonb_array_length(:'cc'::jsonb) = 2, 'the hourly cap (2) stops the first run at 2 messages');
select t.ok((select array_agg(x#>>'{vars,number}' order by x#>>'{vars,number}') from jsonb_array_elements(:'cc'::jsonb) x) = (select array_agg(number_text order by number_text) from centre_invoices where id in (:'c1', :'c2')),
            'first in, first out: the two oldest requests go first');
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('C'))) = '[]'::jsonb as ok \gset
select t.ok(:'ok', 'messages being sent count against the cap too: nothing more is handed out while 2 are in flight');
select pg_temp.sc(format('select email_complete(%L, %L, null, %L, %L)', (:'cc'::jsonb->0->>'queue_id')::uuid, 'sent', '<c.m1@smtp>', :'cc'::jsonb->0->>'to')) is not null as x \gset
select pg_temp.sc(format('select email_complete(%L, %L, null, %L, %L)', (:'cc'::jsonb->1->>'queue_id')::uuid, 'sent', '<c.m2@smtp>', :'cc'::jsonb->1->>'to')) is not null as x \gset
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('C'))) = '[]'::jsonb as ok \gset
select t.ok(:'ok', 'two sent in the last hour: the hourly cap holds');
select pg_temp.cfg(t.id('C'), pg_temp.mail('{"daily_cap":3,"per_hour":50}'));
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('C'))) as cc2 \gset
select t.ok(jsonb_array_length(:'cc2'::jsonb) = 1, 'hourly room opened: only ONE more goes, because the daily cap (3) has 2 used');
select pg_temp.sc(format('select email_complete(%L, %L, null, %L, %L)', (:'cc2'::jsonb->0->>'queue_id')::uuid, 'sent', '<c.m3@smtp>', :'cc2'::jsonb->0->>'to')) is not null as x \gset
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('C'))) = '[]'::jsonb as ok \gset
select t.ok(:'ok' and (pg_temp.status_of('C')->>'sent_today')::int = 3 and (pg_temp.status_of('C')->>'remaining_today')::int = 0 and (pg_temp.status_of('C')->>'queued')::int = 2 and (pg_temp.status_of('C')->>'sends_over_days')::int = 2,
            'the daily cap holds: 3 sent today, 2 queued for tomorrow ("sends over 2 days")');
-- tomorrow (the log refuses edits; its test-only time shift moves the 3 sends a day back)
select pg_temp.age_log(t.id('C'), interval '26 hours');
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('C'))) as cc3 \gset
select t.ok(jsonb_array_length(:'cc3'::jsonb) = 2, 'the next day the cap starts again and the rest go');
-- the platform's own room limits what any centre gets
select pg_temp.ai('C', '5', 1000, (select today from td), (select today + 7 from td)) as c5b \gset
select pg_temp.fam('C', 'p', :'o1', array['p@example.test']);
select pg_temp.ai('C', 'p', 1000, (select today from td), (select today + 7 from td)) as cp \gset
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L,%L]::uuid[])', t.id('C'), :'c5b', :'cp')) is not null as x \gset
select pg_temp.cfg(t.id('C'), pg_temp.mail('{"daily_cap":300,"per_hour":300}'));
select jsonb_array_length(pg_temp.srv(format('select email_claim(%L, 100, 1)', t.id('C')))) as n1 \gset
select t.ok(:n1 = 1, 'p_platform_left = 1: only one message is handed out');
select jsonb_array_length(pg_temp.srv(format('select email_claim(%L, 100, 0)', t.id('C')))) as n0 \gset
select t.ok(:n0 = 0, 'p_platform_left = 0: nothing is handed out');
select jsonb_array_length(pg_temp.srv(format('select email_claim(%L, 1, 1000)', t.id('C')))) as nmax \gset
select t.ok(:nmax = 1, 'p_max limits one run');
-- stagger: a message that is not due yet is left alone
select pg_temp.fam('C', 'q', :'o1', array['q@example.test']);
select pg_temp.ai('C', 'q', 1000, (select today from td), (select today + 7 from td)) as cq \gset
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L]::uuid[])', t.id('C'), :'cq')) is not null as x \gset
update email_queue set not_before = now() + interval '2 hours' where invoice_id = :'cq';
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('C')))::text !~ (select id::text from email_queue where invoice_id = :'cq') as ok \gset
select t.ok(:'ok', 'a message whose time has not come (not_before) is not handed out');
-- a worker that died: sending messages older than 15 minutes go back, or fail after 3 attempts
select pg_temp.fam('C', 'r', :'o1', array['r@example.test']);
select pg_temp.ai('C', 'r', 1000, (select today from td), (select today + 7 from td)) as cr \gset
select pg_temp.call(:'o1', format('select email_enqueue(%L, array[%L]::uuid[])', t.id('C'), :'cr')) is not null as x \gset
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('C'))) is not null as x \gset
update email_queue set updated_at = now() - interval '20 minutes' where invoice_id = :'cr';
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('C')))::text ~ (select id::text from email_queue where invoice_id = :'cr') as ok \gset
select t.ok(:'ok' and (select attempts = 2 from email_queue where invoice_id = :'cr'), 'a message stuck in "sending" for 15 minutes is tried again');
update email_queue set updated_at = now() - interval '20 minutes', attempts = 3 where invoice_id = :'cr';
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('C'))) is not null as x \gset
select t.ok((select status = 'failed' and reason = 'stuck' from email_queue where invoice_id = :'cr'), 'a message stuck after 3 attempts is failed (stuck), not retried forever');
select t.ok(pg_temp.n('select email_platform_sent_24h()') = pg_temp.n('select count(*) from email_send_log where result = ''sent'' and at > now() - interval ''24 hours''') + pg_temp.n('select count(*) from org_invite_mail_log where status = ''sent'' and sent_at > now() - interval ''24 hours'''),
            'the platform count = every centre''s sends + tutor invite emails (the server keeps this under the Brevo day limit)');

-- ================================================================== 10. reminders (centre R: staff_send, reminders after 3 days, every 7, at most 3)
select t.as(:'o1'); set role authenticated;
select t.put('R', org_create_centre('Email Centre R', pg_temp.settings(pg_temp.mail('{"reminders":{"enabled":true,"first_after_days":3,"repeat_days":7,"max_count":3}}'))));
reset role; select set_config('request.jwt.claims', '', false);
select pg_temp.fam('R', '1', :'o1', array['r1@example.test']);
select pg_temp.fam('R', '2', :'o1', array['r2@example.test']);
select pg_temp.fam('R', '3', :'o1', array['r3@example.test']);
select pg_temp.fam('R', '4', :'o1', array['r4@example.test']);
select pg_temp.fam('R', '5', :'o1', array['r5@example.test']);
select pg_temp.fam('R', '6', :'o1', array['r6@example.test']);
select pg_temp.fam('R', '7', :'o1', array['r7@example.test']);
select pg_temp.fam('R', '8', :'o1', array['-']);
select pg_temp.fam('R', '9', :'o1', array['r9@example.test']);
select pg_temp.fam('R', '10', :'o1', array['r10@example.test']);
select pg_temp.ai('R', '1', 10000, (select today - 5 from td), (select today - 2 from td)) as r1 \gset
select pg_temp.ai('R', '2', 10000, (select today - 6 from td), (select today - 3 from td)) as r2 \gset
select pg_temp.ai('R', '3', 10000, (select today - 20 from td), (select today - 10 from td)) as r3 \gset
select pg_temp.ai('R', '4', 10000, (select today - 30 from td), (select today - 20 from td)) as r4 \gset
select pg_temp.ai('R', '5', 10000, (select today - 6 from td), (select today - 3 from td)) as r5 \gset
select pg_temp.pay(t.id('R'), t.id('R_h_5'), :'r5', 10000, (select today from td)) is not null as x \gset
select pg_temp.ai('R', '6', 10000, (select today - 6 from td), (select today - 3 from td)) as r6 \gset
select pg_temp.credit(t.id('R'), :'r6', 10000, (select today from td)) is not null as x \gset
select pg_temp.ai('R', '7', 10000, (select today - 6 from td), (select today - 3 from td)) as r7 \gset
select pg_temp.pay(t.id('R'), t.id('R_h_7'), :'r7', 4000, (select today from td)) is not null as x \gset
select pg_temp.ai('R', '8', 10000, (select today - 6 from td), (select today - 3 from td)) as r8 \gset
select pg_temp.ai('R', '9', 10000, (select today - 130 from td), (select today - 125 from td)) as r9 \gset
select pg_temp.ai('R', '10', 10000, (select today from td), (select today + 1 from td)) as r10 \gset
select pg_temp.ai('R', '10', 1000, (select today - 6 from td), (select today - 3 from td), 'late_fee') as r10lf \gset
select pg_temp.call(:'o1', format('select email_reminder_preview(%L)', t.id('R'))) as pv \gset
select t.ok((:'pv'::jsonb->>'enabled')::boolean and (:'pv'::jsonb->>'due_now')::int = 6 and (:'pv'::jsonb->>'overdue_invoices')::int = 7 and (:'pv'::jsonb->>'first_after_days')::int = 3
            and (:'pv'::jsonb->>'repeat_days')::int = 7 and (:'pv'::jsonb->>'max_count')::int = 3,
            'preview: 7 overdue invoices still owed (the paid, credited and too-old ones are left out), 6 due a reminder today');
select t.ok(pg_temp.n('select count(*) from email_queue where kind = ''reminder''') = 0, 'a preview queues nothing');
select pg_temp.srv(format('select email_plan_reminders(%L)', t.id('R')))::int = 6 as ok \gset
select t.ok(:'ok', 'planner, first run: a reminder for every invoice that is 3+ days overdue and still owed');
select t.ok(pg_temp.qn(:'r1') = 0 and pg_temp.qn(:'r5') = 0 and pg_temp.qn(:'r6') = 0 and pg_temp.qn(:'r9') = 0 and pg_temp.qn(:'r10') = 0, 'none for: 2 days overdue, paid, fully credited, issued 130 days ago, not due yet');
select t.ok(pg_temp.qn(:'r2', 'queued') = 1 and pg_temp.qn(:'r3', 'queued') = 1 and pg_temp.qn(:'r4', 'queued') = 1 and pg_temp.qn(:'r7', 'queued') = 1 and pg_temp.qn(:'r10lf', 'queued') = 1,
            'queued for: exactly 3 days overdue, long overdue, part-paid, and the late-fee invoice');
select t.ok((select status = 'skipped' and reason = 'no_email' and reminder_no = 1 from email_queue where invoice_id = :'r8') and (select count(*) = 1 from email_send_log where invoice_id = :'r8' and result = 'skipped'),
            'a family with no address: the reminder is recorded as skipped (and counts as number 1)');
select pg_temp.srv(format('select email_plan_reminders(%L)', t.id('R')))::int = 0 as ok \gset
select t.ok(:'ok' and (select count(*) = 6 from email_queue where kind = 'reminder'), 'the planner runs again the same day: nothing new (no duplicates)');
select (select (e#>>'{vars,days_overdue}')::int from jsonb_array_elements(pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('R')))) e where e->>'kind' = 'reminder' and e#>>'{vars,number}' = (select number_text from centre_invoices where id = :'r3')) as dr3 \gset
select t.ok(:dr3 = 10, 'a reminder carries how many days overdue it is (10)');
update email_queue set status = 'sent' where kind = 'reminder' and status = 'sending';
-- time passes: 8 days later reminder 2 is due where its date has come; a missed day never sends two at once
update email_queue set requested_at = requested_at - interval '8 days' where kind = 'reminder';
select pg_temp.srv(format('select email_plan_reminders(%L)', t.id('R')))::int as n2 \gset
select t.ok(:n2 = 2 and pg_temp.qn(:'r3') = 2 and pg_temp.qn(:'r4') = 2 and pg_temp.qn(:'r2') = 1 and pg_temp.qn(:'r7') = 1,
            'a week later: reminder 2 for the two invoices whose second date has come (long overdue ones catch up by ONE, not by all missed)');
update email_queue set requested_at = requested_at - interval '8 days' where kind = 'reminder';
select pg_temp.srv(format('select email_plan_reminders(%L)', t.id('R')))::int as n3 \gset
select t.ok(pg_temp.qn(:'r4') = 3 and (select max(reminder_no) = 3 from email_queue where invoice_id = :'r4'), 'and reminder 3 comes another week on');
update email_queue set requested_at = requested_at - interval '30 days' where kind = 'reminder';
select pg_temp.srv(format('select email_plan_reminders(%L)', t.id('R'))) is not null as x \gset
select t.ok((select max(reminder_no) from email_queue where invoice_id = :'r4') = 3, 'never more than the maximum (3): no 4th reminder, however late');
-- paid after a reminder was queued but before it went out
select pg_temp.fam('R', 'w', :'o1', array['rw@example.test']);
select pg_temp.ai('R', 'w', 10000, (select today - 8 from td), (select today - 4 from td)) as rw \gset
select pg_temp.srv(format('select email_plan_reminders(%L)', t.id('R'))) is not null as x \gset
select t.ok(pg_temp.qn(:'rw', 'queued') = 1, 'a new overdue invoice gets its reminder');
select pg_temp.pay(t.id('R'), t.id('R_h_w'), :'rw', 10000, (select today from td)) is not null as x \gset
select pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('R'))) is not null as x \gset
select t.ok((select status = 'cancelled' and reason = 'paid' from email_queue where invoice_id = :'rw') and (select count(*) = 1 from email_send_log where invoice_id = :'rw' and result = 'cancelled' and detail = 'paid'),
            'paid before the reminder went out: the reminder is cancelled (paid) and never sent');
-- the schedule options
select pg_temp.cfg(t.id('R'), pg_temp.mail('{"reminders":{"enabled":false,"first_after_days":3,"repeat_days":7,"max_count":3}}'));
select pg_temp.fam('R', 'v', :'o1', array['rv@example.test']);
select pg_temp.ai('R', 'v', 10000, (select today - 8 from td), (select today - 4 from td)) as rv \gset
select pg_temp.srv(format('select email_plan_reminders(%L)', t.id('R')))::int = 0 and pg_temp.qn(:'rv') = 0 as ok \gset
select t.ok(:'ok', 'reminders off: the planner does nothing');
select pg_temp.cfg(t.id('R'), pg_temp.mail('{"mode":"off","reminders":{"enabled":true,"first_after_days":3,"repeat_days":7,"max_count":3}}'));
select pg_temp.srv(format('select email_plan_reminders(%L)', t.id('R')))::int = 0 as ok \gset
select t.ok(:'ok', 'email off: reminders don''t go either, whatever the reminder switch says');
select pg_temp.cfg(t.id('R'), pg_temp.mail('{"reminders":{"enabled":true,"first_after_days":1,"repeat_days":0,"max_count":3}}'));
select pg_temp.srv(format('select email_plan_reminders(%L)', t.id('R')))::int as nrep \gset
select t.ok(pg_temp.qn(:'rv') = 1, 'first reminder after 1 day: the new invoice is reminded at once');
update email_queue set requested_at = requested_at - interval '40 days' where kind = 'reminder';
select pg_temp.srv(format('select email_plan_reminders(%L)', t.id('R')))::int = 0 as ok \gset
select t.ok(:'ok' and pg_temp.qn(:'rv') = 1, 'repeat 0: one reminder only, ever');
select pg_temp.cfg(t.id('R'), pg_temp.mail('{"reminders":{"enabled":true,"first_after_days":3,"repeat_days":7,"max_count":1}}'));
select pg_temp.srv(format('select email_plan_reminders(%L)', t.id('R')))::int = 0 as ok \gset
select t.ok(:'ok', 'maximum 1: no second reminder');
select t.ok(pg_temp.srv(format('select email_plan_reminders(%L, true)', t.id('A')))::int = 0 and pg_temp.srv(format('select email_plan_reminders(%L)', t.id('SOLO')))::int = 0, 'the planner never touches a centre with reminders off, or a solo organisation');

-- ================================================================== 11. isolation and the function surface
select t.ok(pg_temp.srv(format('select email_claim(%L, 100, 1000)', t.id('N'))) = '[]'::jsonb, 'another centre''s queue is separate');
select pg_temp.fam('N', '2', :'o2', array['n2@example.test']);
select pg_temp.ai('N', '2', 1000, (select today from td), (select today + 7 from td)) as n2i \gset
select pg_temp.call(:'o2', format('select email_enqueue(%L, array[%L]::uuid[])', t.id('N'), :'n2i'))->>'queued' = '1' as ok \gset
select t.ok(:'ok' and (select count(*) = 1 from email_queue where invoice_id = :'n2i' and org_id = t.id('N')), 'a second centre''s owner queues for their own centre');
select pg_temp.call(:'o2', format('select email_queue_list(%L)', t.id('N')))::text !~ 'Family A' as ok \gset
select t.ok(:'ok' and jsonb_array_length(pg_temp.call(:'o1', format('select email_queue_list(%L)', t.id('A')))) > 0 and pg_temp.call(:'o1', format('select email_queue_list(%L)', t.id('A')))::text !~ 'Family N', 'each centre sees only its own queue');
select t.ok((select count(*) = 0 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'email\_%' and has_function_privilege('anon', p.oid, 'execute')), 'no email function can be called by an anonymous visitor');
select t.ok((select array_agg(p.proname::text order by p.proname) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'email\_%' and has_function_privilege('authenticated', p.oid, 'execute'))
            = array['email_bad_list', 'email_cfg', 'email_clear_bad', 'email_enqueue', 'email_enqueue_unsent', 'email_household_contacts', 'email_log_list', 'email_mask', 'email_queue_cancel',
                    'email_queue_list', 'email_queue_status', 'email_reminder_preview', 'email_set_billing_contacts', 'email_valid'],
            'a signed-in browser can call exactly the staff functions (each starts with the gate) and the two pure helpers; claim, complete, bounce, planner and platform count are server-only');
select t.ok((select count(*) = 0 from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname in ('email_queue', 'email_send_log') and (has_table_privilege('authenticated', c.oid, 'select') or has_table_privilege('anon', c.oid, 'select'))),
            'neither table can be read by a browser role (functions only)');
select t.ok((select count(*) = 2 from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname in ('email_queue', 'email_send_log') and c.relrowsecurity), 'row-level security is on for both tables');
-- the log, across the whole file: only masked addresses, never a whole one
select t.ok((select count(*) = 0 from email_send_log where to_masked !~ '^([A-Za-z0-9]\*\*\*@[A-Za-z0-9]\*\*\*\.[a-z]+|\*\*\*)$'), 'every address in the send log is masked');
select t.ok((select count(*) = 0 from email_send_log l where l::text ~ 'example\.test'), 'no whole address anywhere in a log row');
select t.ok((select count(*) = 0 from email_queue q where q::text ~ 'example\.test'), 'no address anywhere in a queue row');
select t.ok((select count(*) = 0 from audit_log where (table_name in ('email_queue', 'email_send_log') and action in ('insert', 'update', 'delete')) or (action like 'email\_%' and (before::text ~ '@' or after::text ~ '@'))), 'the audit log has no address and no per-message rows (only the one summary line per action)');
select t.ok((select count(*) >= 1 from information_schema.triggers where trigger_name = 'email_on_invoice_issued' and event_object_table = 'centre_invoices')
            and (select count(*) >= 1 from information_schema.triggers where trigger_name = 'email_on_payment' and event_object_table = 'centre_payments'), 'both automatic triggers are in place');
