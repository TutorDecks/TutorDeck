-- T4 step S3 tests: record a payment (exact, part, over, oldest-first, partial switched off, overpayments credit / refund), reverse a payment, credit notes
-- (own series, GST on the shared vectors, caps, excess), computed status (issued / part-paid / paid / overdue / void), the account list and its speed,
-- the share link (token isolation, expiry, rotation, setting off), the public view, the WhatsApp message, the family credit ledger, permissions and
-- cross-centre refusals, tutors / parents / solo read nothing, audit redaction.
-- Runs after centre_invoice_run_test.sql in the same throwaway database (reuses the t.* helpers). Builds its own centres and made-up people.
-- Run from the repository root (it reads tests/gst-vectors.csv, the same file tests/money.test.js and the S1 tests use). All names are FAKE.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000bb01', 'pay.owner@centre.test'),   ('00000000-0000-0000-0000-00000000bb02', 'pay.invoices@centre.test'),
  ('00000000-0000-0000-0000-00000000bb03', 'pay.payments@centre.test'), ('00000000-0000-0000-0000-00000000bb04', 'pay.tutor@centre.test'),
  ('00000000-0000-0000-0000-00000000bb05', 'pay.parent@centre.test'),   ('00000000-0000-0000-0000-00000000bb06', 'pay.outsider@centre.test'),
  ('00000000-0000-0000-0000-00000000bb07', 'pay.off@centre.test'),      ('00000000-0000-0000-0000-00000000bb08', 'pay.owner2@centre.test'),
  ('00000000-0000-0000-0000-00000000bb09', 'pay.revenue@centre.test'),  ('00000000-0000-0000-0000-00000000bb0a', 'pay.both@centre.test');
\set o1 '00000000-0000-0000-0000-00000000bb01'
\set inv '00000000-0000-0000-0000-00000000bb02'
\set paym '00000000-0000-0000-0000-00000000bb03'
\set tut '00000000-0000-0000-0000-00000000bb04'
\set par '00000000-0000-0000-0000-00000000bb05'
\set out '00000000-0000-0000-0000-00000000bb06'
\set off '00000000-0000-0000-0000-00000000bb07'
\set o2 '00000000-0000-0000-0000-00000000bb08'
\set rev '00000000-0000-0000-0000-00000000bb09'
\set both '00000000-0000-0000-0000-00000000bb0a'
\set solo '00000000-0000-0000-0000-0000000000a1'
\set h1 '00000000-0000-0000-0000-00000000cb01'
\set h2 '00000000-0000-0000-0000-00000000cb02'
\set h3 '00000000-0000-0000-0000-00000000cb03'
\set h4 '00000000-0000-0000-0000-00000000cb04'
\set hx '00000000-0000-0000-0000-00000000cb09'
\set s1 '00000000-0000-0000-0000-00000000db01'
\set s2 '00000000-0000-0000-0000-00000000db02'
\set s3 '00000000-0000-0000-0000-00000000db03'
\set s4 '00000000-0000-0000-0000-00000000db04'
\set sx '00000000-0000-0000-0000-00000000db09'

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today;
grant select on td to authenticated, anon;

create function pg_temp.settings_base() returns jsonb language sql as $$
  select jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(t.centre_settings(), '{profile,invoice_prefix}', '"PAY"'), '{profile,gst_rate_bp}', '900'),
         '{invoicing}', '{"grouping":"family","due_days":7,"review_before_sending":true,"delivery":{"share_link":true}}'::jsonb),
         '{payments}', '{"modes":["manual_paynow"],"paynow":{"type":"uen","id":"200812345K"},"partial_payments":true,"overpayments":"credit"}'::jsonb),
         '{profile,trading_name}', '"Pay Test Centre"') $$;
create function pg_temp.cfg(p_org uuid, p_owner uuid, p_path text[], p_val jsonb) returns void language plpgsql as $$
declare cur jsonb;
begin
  perform t.as(p_owner::text);
  cur := org_settings_on(p_org, current_date + 1);
  perform org_save_settings(p_org, jsonb_set(cur, p_path, p_val, true), current_date);
end $$;
-- the call must be refused with a message that starts with p_expect
create function pg_temp.refused(p_user text, p_sql text, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  begin execute p_sql; exception when others then m := sqlerrm; end;
  if m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS refused: % (%)', p_msg, m;
end $$;
-- an ISSUED invoice: sub = before GST. issued_ago days ago; due p_due days from TODAY (negative = already overdue)
create function pg_temp.inv(k text, org uuid, owner uuid, hh uuid, stu uuid, sub bigint, issued_ago int default 0, p_due int default 7, p_kind text default 'lesson') returns uuid
language plpgsql as $$
declare iid uuid := gen_random_uuid(); g record; tdy date := (select today from td);
begin
  perform t.as(owner::text);
  select * into g from centre_invoice_gst(org, sub, tdy);
  insert into centre_invoices(id, org_id, kind, household_id, student_id, period_start, period_end, gst_registered, gst_rate_bp, gst_inclusive, net_cents, gst_cents, total_cents)
  values (iid, org, p_kind, hh, stu, date_trunc('month', tdy)::date, date_trunc('month', tdy)::date + 27, g.gst_registered, g.gst_rate_bp, g.gst_inclusive, g.net_cents, g.gst_cents, g.total_cents);
  insert into centre_invoice_lines(org_id, invoice_id, position, student_id, description, qty, unit_cents) values (org, iid, 1, stu, 'Maths lessons', 1, sub);
  update centre_invoices set status = 'issued', issue_date = tdy - issued_ago, due_date = tdy + p_due where centre_invoices.id = iid;
  perform t.put(k, iid);
  return iid;
end $$;
create function pg_temp.pay(p_user uuid, p_org uuid, p_hh uuid, p_method text, p_amt bigint, p_ref text default null, p_ids uuid[] default null, p_payer text default null) returns jsonb
language plpgsql as $$
begin perform t.as(p_user::text); return centre_record_payment(p_org, p_hh, p_method, p_amt, (select today from td), p_ref, p_ids, p_payer, null); end $$;
create function pg_temp.acct(p_user uuid, k text) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_invoice_account_get(t.id(k)); end $$;
create function pg_temp.ps(p_user uuid, k text) returns text language sql as $$ select pg_temp.acct(p_user, k)->>'pay_status' $$;
create function pg_temp.cn(p_user uuid, k text, p_amt bigint, p_reason text, p_lines jsonb default null) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_issue_credit_note(t.id(k), p_amt, p_reason, p_lines); end $$;
create function pg_temp.reverse(p_user uuid, p_pay uuid, p_reason text) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_reverse_payment(p_pay, p_reason); end $$;
grant execute on all functions in schema pg_temp to public;

-- ===================================================================== the world: centre 1 (GST 9%, prefix PAY), centre 2 (somebody else's)
select t.put('solo_org', org_personal(:'solo'));
set role authenticated; select t.as(:'o1');
select t.put('c1', org_create_centre('Pay Test Centre', pg_temp.settings_base()));
select org_save_settings(t.id('c1'), pg_temp.settings_base(), date '2000-01-01');      -- the centre is still in setup: its settings apply from the start of time, so an invoice back-dated for the test uses them
select t.as(:'o2');
select t.put('c2', org_create_centre('Other Pay Centre', jsonb_set(pg_temp.settings_base(), '{profile,invoice_prefix}', '"OTH"')));
select org_save_settings(t.id('c2'), jsonb_set(pg_temp.settings_base(), '{profile,invoice_prefix}', '"OTH"'), date '2000-01-01');
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('c1'), :'inv',  'Invoices Ivy',  'staff',  array['issue_invoices'], 'active'),
  (t.id('c1'), :'paym', 'Payments Pat',  'staff',  array['record_payments'], 'active'),
  (t.id('c1'), :'rev',  'Revenue Ray',   'staff',  array['view_revenue'], 'active'),
  (t.id('c1'), :'both', 'Both Beth',     'staff',  array['issue_invoices', 'record_payments'], 'active'),
  (t.id('c1'), :'tut',  'Tutor Tia',     'tutor',  '{}', 'active'),
  (t.id('c1'), :'par',  'Parent Pia',    'parent', '{}', 'active'),
  (t.id('c1'), :'off',  'Switched off',  'staff',  array['issue_invoices', 'record_payments'], 'disabled');
insert into households(id, org_id, name) values
  (:'h1', t.id('c1'), 'Lim Family'), (:'h2', t.id('c1'), 'Tan Family'), (:'h3', t.id('c1'), 'Ong Family'), (:'h4', t.id('c1'), 'Goh Family'), (:'hx', t.id('c2'), 'Elsewhere Family');
insert into students(id, tutor_id, org_id, name, household_id) values
  (:'s1', :'o1', t.id('c1'), 'Sophie Lim', :'h1'), (:'s2', :'o1', t.id('c1'), 'Tara Tan', :'h2'), (:'s3', :'o1', t.id('c1'), 'Oscar Ong', :'h3'),
  (:'s4', :'o1', t.id('c1'), 'Gina Goh', :'h4'), (:'sx', :'o2', t.id('c2'), 'Ellie Else', :'hx');
insert into guardians(org_id, household_id, name, phone) values (t.id('c1'), :'h1', 'Mrs Lim', '9123 4567'), (t.id('c1'), :'h3', 'Mr Ong', null);

-- Lim: I1 S$100 + GST = 10900 (due in 7 days), I2 S$50 + GST = 5450 (OVERDUE, due 5 days ago)   Tan: I3 S$30 + GST = 3270
-- Ong: I4 S$40 (4360, issued 10 days ago) and I5 S$40 (4360, issued 3 days ago, but numbered AFTER it) → oldest-first order is by issue date
select pg_temp.inv('I1', t.id('c1'), :'o1', :'h1', :'s1', 10000, 0, 7);
select pg_temp.inv('I2', t.id('c1'), :'o1', :'h1', :'s1', 5000, 20, -5);
select pg_temp.inv('I3', t.id('c1'), :'o1', :'h2', :'s2', 3000, 0, 7);
select pg_temp.inv('I5', t.id('c1'), :'o1', :'h3', :'s3', 4000, 3, 7);        -- numbered 4 but issued later than I4? (I4 below is numbered 5)
select pg_temp.inv('I4', t.id('c1'), :'o1', :'h3', :'s3', 4000, 10, 7);       -- numbered 5, issued 10 days ago → it is the OLDEST
select pg_temp.inv('X1', t.id('c2'), :'o2', :'hx', :'sx', 1000, 0, 7);
select t.ok((select total_cents = 10900 and number_text = 'PAY-1' from centre_invoices where id = t.id('I1')), 'the made-up invoices exist: I1 = PAY-1 = S$109.00');
select t.ok((select total_cents = 5450 and due_date < (select today from td) from centre_invoices where id = t.id('I2')), 'I2 = S$54.50, already past its due date');
select t.ok((select number_text = 'PAY-4' from centre_invoices where id = t.id('I5')) and (select number_text = 'PAY-5' from centre_invoices where id = t.id('I4')), 'I5 is PAY-4 (issued later) and I4 is PAY-5 (issued earlier)');

-- ===================================================================== 1. who may record a payment
select pg_temp.refused(:'tut',  format($q$ select centre_record_payment(%L, %L, 'cash', 100, current_date, null) $q$, t.id('c1'), :'h1'), 'NOT_FOUND', 'a tutor can''t record a payment');
select pg_temp.refused(:'par',  format($q$ select centre_record_payment(%L, %L, 'cash', 100, current_date, null) $q$, t.id('c1'), :'h1'), 'NOT_FOUND', 'a parent can''t record a payment');
select pg_temp.refused(:'off',  format($q$ select centre_record_payment(%L, %L, 'cash', 100, current_date, null) $q$, t.id('c1'), :'h1'), 'NOT_FOUND', 'switched-off staff can''t');
select pg_temp.refused(:'out',  format($q$ select centre_record_payment(%L, %L, 'cash', 100, current_date, null) $q$, t.id('c1'), :'h1'), 'NOT_FOUND', 'a stranger can''t');
select pg_temp.refused(:'solo', format($q$ select centre_record_payment(%L, %L, 'cash', 100, current_date, null) $q$, t.id('c1'), :'h1'), 'NOT_FOUND', 'a solo tutor can''t record on someone else''s centre');
select pg_temp.refused(:'solo', format($q$ select centre_record_payment(%L, %L, 'cash', 100, current_date, null) $q$, t.id('solo_org'), :'h1'), 'NOT_FOUND', 'a solo organisation has no centre payments');
select pg_temp.refused(:'o2',   format($q$ select centre_record_payment(%L, %L, 'cash', 100, current_date, null) $q$, t.id('c1'), :'h1'), 'NOT_FOUND', 'another centre''s owner can''t');
select pg_temp.refused(:'o1',   format($q$ select centre_record_payment(%L, %L, 'cash', 100, current_date, null) $q$, gen_random_uuid(), :'h1'), 'NOT_FOUND', 'an unknown centre is not found');
select pg_temp.refused(:'inv',  format($q$ select centre_record_payment(%L, %L, 'cash', 100, current_date, null) $q$, t.id('c1'), :'h1'), 'NOT_ALLOWED', 'staff with only issue_invoices can''t record payments');
select pg_temp.refused(:'rev',  format($q$ select centre_record_payment(%L, %L, 'cash', 100, current_date, null) $q$, t.id('c1'), :'h1'), 'NOT_ALLOWED', 'staff with only view_revenue can''t');
select set_config('request.jwt.claims', '', false); set role anon;
select t.fails(format($q$ select centre_record_payment(%L, %L, 'cash', 100, current_date, null) $q$, t.id('c1'), :'h1'), 'a signed-out visitor can''t record a payment (no execute right)');
select t.fails(format($q$ select centre_issue_credit_note(%L, 100, 'x') $q$, t.id('I1')), 'a signed-out visitor can''t issue a credit note');
select t.fails(format($q$ select centre_invoice_account_list(%L) $q$, t.id('c1')), 'a signed-out visitor can''t list invoices');
reset role;
select t.eq((select count(*) from centre_payments where org_id = t.id('c1')), 0, 'none of the refused calls recorded anything');

-- ===================================================================== 2. bad values
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'cash', 0, current_date, null) $q$, t.id('c1'), :'h1'), 'BAD_VALUE: the amount', 'an amount of 0');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'cash', -500, current_date, null) $q$, t.id('c1'), :'h1'), 'BAD_VALUE: the amount', 'a negative amount');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'cash', null, current_date, null) $q$, t.id('c1'), :'h1'), 'BAD_VALUE: the amount', 'no amount');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'cash', 100000001, current_date, null) $q$, t.id('c1'), :'h1'), 'BAD_VALUE: that amount is too large', 'an absurd amount');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'bitcoin', 100, current_date, null) $q$, t.id('c1'), :'h1'), 'BAD_VALUE: choose how', 'an unknown method');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, null, 100, current_date, null) $q$, t.id('c1'), :'h1'), 'BAD_VALUE: choose how', 'no method');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'cash', 100, (select today + 1 from td), null) $q$, t.id('c1'), :'h1'), 'BAD_VALUE: the date received can''t be in the future', 'a date tomorrow');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'cash', 100, (select today - 1900 from td), null) $q$, t.id('c1'), :'h1'), 'BAD_VALUE: the date received is too far back', 'a date over 5 years ago');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'cash', 100, null, null) $q$, t.id('c1'), :'h1'), 'BAD_VALUE: say the date', 'no date');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'cash', 100, current_date, %L) $q$, t.id('c1'), :'h1', repeat('x', 121)), 'TOO_LONG', 'a reference over 120 characters');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, null, 'cash', 100, current_date, null) $q$, t.id('c1')), 'BAD_VALUE: choose which family', 'no family and no invoice');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'cash', 100, current_date, null) $q$, t.id('c1'), :'hx'), 'NOT_FOUND', 'a family of ANOTHER centre');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'cash', 100, current_date, null, array[%L]::uuid[]) $q$, t.id('c1'), :'h1', t.id('X1')), 'NOT_FOUND', 'another centre''s invoice id');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'cash', 100, current_date, null, array[%L]::uuid[]) $q$, t.id('c1'), :'h1', t.id('I3')), 'NOT_ALLOWED: those invoices belong to different families', 'an invoice of a different family');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'cash', 100, current_date, null, array[%L, %L]::uuid[]) $q$, t.id('c1'), :'h1', t.id('I1'), t.id('I3')), 'NOT_ALLOWED: those invoices belong to different families', 'two families in one payment');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'cash', 100, current_date, null, array[%L]::uuid[]) $q$, t.id('c1'), :'h1', gen_random_uuid()), 'NOT_FOUND', 'an unknown invoice id');
select t.eq((select count(*) from centre_payments where org_id = t.id('c1')), 0, 'no bad call recorded anything');

-- ===================================================================== 3. EXACT payment (I3 = 3270): paid, with the reference kept in the payment but out of the audit log
create temp table r_exact as select pg_temp.pay(:'paym', t.id('c1'), :'h2', 'manual_paynow', 3270, 'PAYNOW 91234567 John Tan', array[t.id('I3')], 'John Tan') as j;
grant select on r_exact to authenticated;
select t.ok((select (j->>'excess_cents')::int = 0 and jsonb_array_length(j->'allocated') = 1 and (j#>>'{allocated,0,balance_after_cents}')::int = 0 from r_exact), 'exact payment: one invoice covered, nothing left over');
select t.eq((select count(*) from centre_payments where org_id = t.id('c1') and kind = 'payment' and household_id = :'h2' and amount_cents = 3270 and reference = 'PAYNOW 91234567 John Tan'), 1, 'the payment row keeps the reference and amount');
select t.eq((select sum(cents) from centre_payment_allocations where invoice_id = t.id('I3')), 3270, 'its allocation covers the invoice to the cent');
select t.eq((select count(*) from centre_family_credit where org_id = t.id('c1')), 0, 'an exact payment creates no credit');
select t.ok(pg_temp.ps(:'paym', 'I3') = 'paid', 'status: paid');
select t.ok((select paid_cents = 3270 and balance_cents = 0 from (select (pg_temp.acct(:'paym', 'I3')->>'paid_cents')::bigint paid_cents, (pg_temp.acct(:'paym', 'I3')->>'balance_cents')::bigint balance_cents) x), 'paid 3270, balance 0');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'cash', 100, current_date, null, array[%L]::uuid[]) $q$, t.id('c1'), :'h2', t.id('I3')), 'NOT_ALLOWED: PAY-3 is already paid in full', 'paying an invoice that is already paid in full, by name');
-- AUDIT REDACTION: nothing that identifies the payer, no reference, no account fragment is in any audit row
select t.eq((select count(*) from audit_log where org_id = t.id('c1') and (coalesce(before::text, '') || coalesce(after::text, '')) ~* '(John Tan|91234567|PAYNOW 9)'), 0, 'AUDIT: neither the reference nor the payer''s name appears anywhere in the audit log');
select t.ok((select count(*) >= 1 from audit_log where org_id = t.id('c1') and table_name = 'centre_payments' and action = 'insert' and after->>'reference' = '[redacted]' and after->>'payer_name' = '[redacted]'), 'AUDIT: the payment row is audited with its reference and payer shown as [redacted]');
select t.ok((select count(*) = 1 from audit_log where org_id = t.id('c1') and action = 'centre_payment_record' and (after->>'amount_cents')::int = 3270 and after->>'method' = 'manual_paynow'), 'AUDIT: a summary line is written with the amount and method');

-- ===================================================================== 4. PART payment (I1 = 10900): part-paid
create temp table r_part as select pg_temp.pay(:'paym', t.id('c1'), :'h1', 'bank', 4000, 'bank ref 5551', array[t.id('I1')]) as j;
grant select on r_part to authenticated;
select t.ok((select (j#>>'{allocated,0,balance_after_cents}')::int = 6900 and (j->>'excess_cents')::int = 0 from r_part), 'a part payment of S$40.00 leaves S$69.00 owing');
select t.ok(pg_temp.ps(:'paym', 'I1') = 'part_paid', 'status: part-paid (not yet due)');
select t.ok((select (j->>'paid_cents')::int = 4000 and (j->>'balance_cents')::int = 6900 and (j->>'credited_cents')::int = 0 from (select pg_temp.acct(:'paym', 'I1') j) x), 'I1: paid 4000, balance 6900');
select t.ok((select jsonb_array_length(j->'payments') = 1 and j#>>'{payments,0,method}' = 'bank' and j#>>'{payments,0,reference}' = 'bank ref 5551' and (j#>>'{payments,0,cents}')::int = 4000
              from (select pg_temp.acct(:'paym', 'I1') j) x), 'the invoice shows its payment, with the reference, to staff who record payments');
select t.ok((select jsonb_array_length(j->'payments') = 0 and (j->>'paid_cents')::int = 4000 from (select pg_temp.acct(:'inv', 'I1') j) x), 'staff who only issue invoices see the amounts but not the payment rows (no references)');
select t.ok((select j->'credit_balance_cents' = 'null'::jsonb from (select pg_temp.acct(:'inv', 'I1') j) x), 'nor the family credit');
select pg_temp.refused(:'rev', format($q$ select centre_invoice_account_get(%L) $q$, t.id('I1')), 'NOT_ALLOWED', 'view_revenue alone can''t open an invoice''s account');

-- OLDEST FIRST: Ong has I4 (issued 10 days ago, PAY-5) and I5 (issued 3 days ago, PAY-4). 6000 pays I4 in full (4360) and 1640 of I5.
create temp table r_old as select pg_temp.pay(:'paym', t.id('c1'), :'h3', 'cash', 6000) as j;
grant select on r_old to authenticated;
select t.ok((select j#>>'{allocated,0,number}' = 'PAY-5' and (j#>>'{allocated,0,cents}')::int = 4360 and j#>>'{allocated,1,number}' = 'PAY-4' and (j#>>'{allocated,1,cents}')::int = 1640 from r_old),
            'oldest first: the earlier-ISSUED invoice (PAY-5) is covered before the later one (PAY-4), not by number');
select t.ok(pg_temp.ps(:'paym', 'I4') = 'paid' and pg_temp.ps(:'paym', 'I5') = 'part_paid', 'I4 paid, I5 part-paid');

-- OVERPAYMENT, centre keeps it as credit: Tan paid I3 in full already; 5000 more with nothing owing = paid in advance → family credit
create temp table r_adv as select pg_temp.pay(:'paym', t.id('c1'), :'h2', 'cash', 5000) as j;
grant select on r_adv to authenticated;
select t.ok((select jsonb_array_length(j->'allocated') = 0 and (j->>'excess_cents')::int = 5000 and j->>'excess_handling' = 'credit' and (j->>'credit_balance_cents')::int = 5000 from r_adv), 'paid in advance with nothing owing: all S$50.00 held as family credit');
-- over an invoice: Lim's I2 (5450) with 7000
create temp table r_over as select pg_temp.pay(:'paym', t.id('c1'), :'h1', 'cheque', 7000, null, array[t.id('I2')]) as j;
grant select on r_over to authenticated;
select t.ok((select (j#>>'{allocated,0,cents}')::int = 5450 and (j->>'excess_cents')::int = 1550 and j->>'excess_handling' = 'credit' and (j->>'credit_balance_cents')::int = 1550 from r_over), 'S$70.00 on a S$54.50 invoice: it is paid and S$15.50 is held as credit');
select t.ok(pg_temp.ps(:'paym', 'I2') = 'paid', 'I2 is paid (even though it was overdue)');
select t.eq((select sum(cents) from centre_payment_allocations a join centre_payments p on p.id = a.payment_id where p.household_id = :'h1' and p.org_id = t.id('c1'))
          + (select coalesce(sum(cents), 0) from centre_family_credit where household_id = :'h1' and org_id = t.id('c1')),
          (select sum(amount_cents) from centre_payments where household_id = :'h1' and org_id = t.id('c1') and kind = 'payment'), 'NEVER LOST: invoices covered + family credit = every cent received from the Lim family');

-- ===================================================================== 5. payments.partial_payments = false
select pg_temp.cfg(t.id('c1'), :'o1', '{payments,partial_payments}', 'false');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'cash', 1000, (select today from td), null, array[%L]::uuid[]) $q$, t.id('c1'), :'h1', t.id('I1')), 'PART_NOT_ALLOWED', 'partial payments off: S$10.00 on a S$69.00 balance is refused');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'cash', 6899, (select today from td), null, array[%L]::uuid[]) $q$, t.id('c1'), :'h1', t.id('I1')), 'PART_NOT_ALLOWED: this centre doesn''t accept part payments, so a payment has to cover whole invoices. PAY-1 still owes S$69.00', 'partial payments off: one cent short is refused and the message names the invoice and what it owes');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'cash', 1000, (select today from td), null) $q$, t.id('c1'), :'h1'), 'PART_NOT_ALLOWED', 'partial payments off: with no invoice chosen, a payment that can''t finish the oldest is refused');
select t.eq((select count(*) from centre_payments where org_id = t.id('c1') and received_on = (select today from td) and amount_cents in (1000, 6899)), 0, 'the refused part payments left nothing behind');
-- Ong has I5 (balance 2720) only: 3000 covers it with 280 over → allowed (nothing is left part-paid)
create temp table r_off1 as select pg_temp.pay(:'paym', t.id('c1'), :'h3', 'cash', 3000) as j;
select t.ok((select (j#>>'{allocated,0,cents}')::int = 2720 and (j->>'excess_cents')::int = 280 from r_off1), 'partial off: a payment that covers the whole invoice is accepted, the extra goes to credit');
-- exact balance on Lim's I1
create temp table r_off2 as select pg_temp.pay(:'paym', t.id('c1'), :'h1', 'bank', 6900, null, array[t.id('I1')]) as j;
select t.ok(pg_temp.ps(:'paym', 'I1') = 'paid', 'partial off: paying the exact remaining balance is accepted and the invoice is paid');
-- two invoices, money for one and a half
select pg_temp.inv('J1', t.id('c1'), :'o1', :'h4', :'s4', 1000, 0, 7);   -- 1090
select pg_temp.inv('J2', t.id('c1'), :'o1', :'h4', :'s4', 1000, 0, 7);   -- 1090
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'cash', 1500, (select today from td), null) $q$, t.id('c1'), :'h4'), 'PART_NOT_ALLOWED', 'partial off: S$15.00 over two S$10.90 invoices would leave the second part-paid: refused');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'cash', 1500, (select today from td), null, array[%L, %L]::uuid[]) $q$, t.id('c1'), :'h4', t.id('J1'), t.id('J2')), 'PART_NOT_ALLOWED', 'partial off: the same with both invoices chosen by hand');
select t.ok((select (j->>'excess_cents')::int = 0 and jsonb_array_length(j->'allocated') = 2 from (select pg_temp.pay(:'paym', t.id('c1'), :'h4', 'cash', 2180) j) x), 'partial off: S$21.80 covers both whole invoices');
select pg_temp.cfg(t.id('c1'), :'o1', '{payments,partial_payments}', 'true');

-- ===================================================================== 6. payments.overpayments = refund
select pg_temp.cfg(t.id('c1'), :'o1', '{payments,overpayments}', '"refund"');
select pg_temp.inv('K1', t.id('c1'), :'o1', :'h4', :'s4', 1000, 0, 7);   -- 1090
select t.ok((select j->>'excess_handling' = 'refund' and (j->>'excess_cents')::int = 410 from (select pg_temp.pay(:'paym', t.id('c1'), :'h4', 'cash', 1500, null, array[t.id('K1')]) j) x), 'overpayments = refund: the S$4.10 extra is marked "to refund", not quietly kept as credit');
select t.eq((select count(*) from centre_family_credit where household_id = :'h4' and handling = 'refund' and cents = 410), 1, 'the ledger row says refund');
select t.ok((select j->>'overpayments' = 'refund' from (select pg_temp.acct(:'paym', 'K1')->'rules' j) x), 'the invoice screen is told the rule (refund)');
select pg_temp.cfg(t.id('c1'), :'o1', '{payments,overpayments}', '"surprise"');
select pg_temp.inv('K2', t.id('c1'), :'o1', :'h4', :'s4', 1000, 0, 7);
select t.ok((select j->>'excess_handling' = 'credit' from (select pg_temp.pay(:'paym', t.id('c1'), :'h4', 'cash', 1100, null, array[t.id('K2')]) j) x), 'an unexpected overpayments value is read as the safe default: held as credit, never lost');
select pg_temp.cfg(t.id('c1'), :'o1', '{payments,overpayments}', '"credit"');

-- ===================================================================== 7. payments.modes: manual PayNow only when switched on
select pg_temp.cfg(t.id('c1'), :'o1', '{payments,modes}', '["statement_matching"]');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'manual_paynow', 100, (select today from td), null) $q$, t.id('c1'), :'h4'), 'NOT_ALLOWED: manual PayNow', 'manual PayNow off: refused');
select t.ok((select (j->>'amount_cents')::int = 100 from (select pg_temp.pay(:'paym', t.id('c1'), :'h4', 'cash', 100) j) x), 'cash is always allowed');
select pg_temp.cfg(t.id('c1'), :'o1', '{payments,modes}', '["manual_paynow"]');

-- ===================================================================== 8. REVERSE a payment: the original row never changes
select t.put('pay_part', (select id from centre_payments where org_id = t.id('c1') and amount_cents = 4000));
create temp table orig as select * from centre_payments where id = t.id('pay_part');
select pg_temp.refused(:'inv',  format($q$ select centre_reverse_payment(%L, 'typo') $q$, t.id('pay_part')), 'NOT_ALLOWED', 'staff who only issue invoices can''t reverse a payment');
select pg_temp.refused(:'tut',  format($q$ select centre_reverse_payment(%L, 'typo') $q$, t.id('pay_part')), 'NOT_FOUND', 'a tutor can''t');
select pg_temp.refused(:'o2',   format($q$ select centre_reverse_payment(%L, 'typo') $q$, t.id('pay_part')), 'NOT_FOUND', 'another centre''s owner can''t');
select pg_temp.refused(:'paym', format($q$ select centre_reverse_payment(%L, '   ') $q$, t.id('pay_part')), 'REASON_REQUIRED', 'a reason is required');
select pg_temp.refused(:'paym', format($q$ select centre_reverse_payment(%L, 'x') $q$, gen_random_uuid()), 'NOT_FOUND', 'an unknown payment');
select t.ok(pg_temp.ps(:'paym', 'I1') = 'paid', 'before: I1 is paid (4000 part + 6900 balance)');
create temp table r_rev as select pg_temp.reverse(:'paym', t.id('pay_part'), 'Entered against the wrong family') as j;
select t.ok((select count(*) = 1 from centre_payments where reverses_payment_id = t.id('pay_part') and kind = 'reversal' and amount_cents = 4000 and household_id = :'h1'), 'a reversing row was added (same amount, same family)');
select t.ok((select o.* is not distinct from p.* from orig o, centre_payments p where p.id = t.id('pay_part')), 'the ORIGINAL payment row is byte-for-byte unchanged');
select t.eq((select coalesce(sum(cents), 0) from centre_payment_allocations where invoice_id = t.id('I1') and payment_id in (select id from centre_payments where id = t.id('pay_part') or reverses_payment_id = t.id('pay_part'))), 0, 'the money the payment covered was released from the invoice (negative allocation)');
select t.ok(pg_temp.ps(:'paym', 'I1') = 'part_paid', 'I1 is back to part-paid (the S$69.00 balance payment still stands)');
select t.ok((select (j->>'paid_cents')::int = 6900 and (j->>'balance_cents')::int = 4000 from (select pg_temp.acct(:'paym', 'I1') j) x), 'recalculated: paid 6900, balance 4000');
select t.ok((select exists (select 1 from jsonb_array_elements(j->'payments') e where (e->>'reversed')::boolean and (e->>'cents')::int = 4000 and e->>'kind' = 'payment')
                    and exists (select 1 from jsonb_array_elements(j->'payments') e where e->>'kind' = 'reversal' and (e->>'cents')::int = -4000) from (select pg_temp.acct(:'paym', 'I1') j) x),
            'the invoice shows the payment as reversed and the reversing row');
select pg_temp.refused(:'paym', format($q$ select centre_reverse_payment(%L, 'again') $q$, t.id('pay_part')), 'ALREADY_REVERSED', 'a payment can only be reversed once');
select pg_temp.refused(:'paym', format($q$ select centre_reverse_payment(%L, 'undo the undo') $q$, (select id from centre_payments where reverses_payment_id = t.id('pay_part'))), 'NOT_ALLOWED: that is already a reversal', 'a reversal can''t be reversed (record the payment again instead)');
select t.fails($q$ update centre_payments set amount_cents = 1 where id = t.id('pay_part') $q$, 'the original payment can''t be edited even by the database owner');
select t.fails($q$ delete from centre_payments where id = t.id('pay_part') $q$, 'nor deleted');
select t.eq((select count(*) from audit_log where org_id = t.id('c1') and action = 'centre_payment_reverse'), 1, 'AUDIT: the reversal is audited');
select t.eq((select count(*) from audit_log where org_id = t.id('c1') and (coalesce(before::text, '') || coalesce(after::text, '')) ~* 'wrong family'), 0, 'AUDIT: the reason text is redacted too');
-- reversing a payment that created credit takes the credit back
select t.put('pay_adv', (select id from centre_payments where org_id = t.id('c1') and amount_cents = 5000));
select t.eq(centre_credit_balance(t.id('c1'), :'h2'), 5000, 'Tan holds S$50.00 credit from paying in advance');
select pg_temp.reverse(:'paym', t.id('pay_adv'), 'Cash was never handed over');
select t.eq(centre_credit_balance(t.id('c1'), :'h2'), 0, 'reversing the advance payment takes the credit back out');
-- ... unless the family has already been paid it back
select t.put('pay_over', (select id from centre_payments where org_id = t.id('c1') and amount_cents = 7000));
select t.eq(centre_credit_balance(t.id('c1'), :'h1'), 1550, 'Lim holds S$15.50 credit from the 7000 payment');
select t.as(:'paym');
select pg_temp.refused(:'paym', format($q$ select centre_refund_family_credit(%L, %L, 500, 'bank', 'ref', 'refund') $q$, t.id('c1'), :'h1'), 'NOT_ALLOWED', 'staff can''t refund family credit: owner only');
select pg_temp.refused(:'o1', format($q$ select centre_refund_family_credit(%L, %L, 1551, 'bank', 'ref', 'refund') $q$, t.id('c1'), :'h1'), 'CREDIT_SHORT', 'can''t refund more than the family holds');
select pg_temp.refused(:'o1', format($q$ select centre_refund_family_credit(%L, %L, 500, 'bank', 'ref', '') $q$, t.id('c1'), :'h1'), 'REASON_REQUIRED', 'a refund needs a reason');
select pg_temp.refused(:'o1', format($q$ select centre_refund_family_credit(%L, %L, 500, 'barter', 'ref', 'x') $q$, t.id('c1'), :'h1'), 'BAD_VALUE', 'a refund needs a real method');
select t.as(:'o1'); select centre_refund_family_credit(t.id('c1'), :'h1', 1000, 'bank', 'DBS 0123456789 ref', 'Refund to the family');
select t.eq(centre_credit_balance(t.id('c1'), :'h1'), 550, 'the owner recorded a S$10.00 refund: S$5.50 still held');
select pg_temp.refused(:'paym', format($q$ select centre_reverse_payment(%L, 'Cheque bounced') $q$, t.id('pay_over')), 'CREDIT_SHORT', 'the 7000 payment can''t be reversed once its credit was partly paid back');
select t.eq((select count(*) from centre_payments where reverses_payment_id = t.id('pay_over')), 0, 'and nothing was half-reversed');
select t.eq((select count(*) from audit_log where org_id = t.id('c1') and (coalesce(before::text, '') || coalesce(after::text, '')) ~* '0123456789'), 0, 'AUDIT: a refund''s bank reference is redacted');
select t.fails($q$ update centre_family_credit set cents = 1 where org_id = t.id('c1') $q$, 'the credit ledger can''t be edited');
select t.fails($q$ delete from centre_family_credit where org_id = t.id('c1') $q$, 'nor deleted');
select t.fails(format($q$ insert into centre_family_credit(org_id, household_id, kind, cents) values (%L, %L, 'refund', -9999999) $q$, t.id('c1'), :'h1'), 'a family''s credit can never be taken below zero');

-- ===================================================================== 9. CREDIT NOTES
-- I2 is paid (5450). Credit S$10.00 INCLUDING GST: subtotal 917 + GST 83 = 1000, numbered CN-PAY-1, in its own series
create temp table ctr0 as select next_number as n from org_counters where org_id = t.id('c1') and series = 'invoice';
select t.eq((select n from ctr0), 10, 'the invoice counter stands at 10 before any credit note (nine invoices so far)');
select pg_temp.refused(:'paym', format($q$ select centre_issue_credit_note(%L, 1000, 'goodwill') $q$, t.id('I1')), 'NOT_ALLOWED', 'staff who only record payments can''t issue a credit note');
select pg_temp.refused(:'tut',  format($q$ select centre_issue_credit_note(%L, 1000, 'goodwill') $q$, t.id('I1')), 'NOT_FOUND', 'a tutor can''t');
select pg_temp.refused(:'par',  format($q$ select centre_issue_credit_note(%L, 1000, 'goodwill') $q$, t.id('I1')), 'NOT_FOUND', 'a parent can''t');
select pg_temp.refused(:'o2',   format($q$ select centre_issue_credit_note(%L, 1000, 'goodwill') $q$, t.id('I1')), 'NOT_FOUND', 'another centre''s owner can''t');
select pg_temp.refused(:'inv',  format($q$ select centre_issue_credit_note(%L, 1000, '   ') $q$, t.id('I1')), 'REASON_REQUIRED', 'a reason is required');
select pg_temp.refused(:'inv',  format($q$ select centre_issue_credit_note(%L, 0, 'x') $q$, t.id('I1')), 'BAD_VALUE', 'an amount of 0');
select pg_temp.refused(:'inv',  format($q$ select centre_issue_credit_note(%L, -5, 'x') $q$, t.id('I1')), 'BAD_VALUE', 'a negative amount');
select pg_temp.refused(:'inv',  format($q$ select centre_issue_credit_note(%L, 10901, 'x') $q$, t.id('I1')), 'TOO_MUCH: you can credit at most S$109.00 more', 'more than the invoice');
select pg_temp.refused(:'inv',  format($q$ select centre_issue_credit_note(%L, 100, 'x') $q$, gen_random_uuid()), 'NOT_FOUND', 'an unknown invoice');
create temp table r_cn1 as select pg_temp.cn(:'inv', 'I2', 1000, 'Lesson cancelled by the centre') as j;
select t.ok((select j->>'number' = 'CN-PAY-1' and (j->>'total_cents')::int = 1000 and (j->>'gst_cents')::int = 83 and (j->>'net_cents')::int = 917 from r_cn1), 'S$10.00 credit = S$9.17 + S$0.83 GST, numbered CN-PAY-1');
select t.eq((select next_number from org_counters where org_id = t.id('c1') and series = 'invoice'), (select n from ctr0), 'credit notes do NOT use the invoice counter');
select t.eq((select next_number from org_counters where org_id = t.id('c1') and series = 'credit_note'), 2, 'they have their own: the next credit note is 2');
select t.put('cn1', (select (j->>'id')::uuid from r_cn1));
select t.ok((select kind = 'credit_note' and status = 'issued' and credits_invoice_id = t.id('I2') and household_id = :'h1' and reason = 'Lesson cancelled by the centre' and issue_date = (select today from td) from centre_invoices where id = t.id('cn1')), 'a credit note is its own issued document: kind, link to the invoice, family, reason, date');
select t.fails($q$ update centre_invoices set total_cents = 1, net_cents = 1, gst_cents = 0 where id = t.id('cn1') $q$, 'an issued credit note can''t be changed');
select t.fails($q$ delete from centre_invoices where id = t.id('cn1') $q$, 'nor deleted');
select t.fails($q$ update centre_invoice_lines set unit_cents = 5 where invoice_id = t.id('cn1') $q$, 'nor its lines');
-- I2 had been paid in full (5450) so the S$10.00 credit is now an excess: held for the family (credit mode)
select t.ok((select (j->>'excess_to_family_cents')::int = 1000 and (j->>'balance_cents')::int = 0 from r_cn1), 'the invoice was already paid, so the credit goes to the family: S$10.00 excess');
select t.eq(centre_credit_balance(t.id('c1'), :'h1'), 1550 + 1000 - 1000, 'the family''s credit went up by S$10.00 (1550 + 1000 − the 1000 refunded earlier)');
select t.ok(pg_temp.ps(:'inv', 'I2') = 'paid', 'I2 stays paid');
select t.ok((select jsonb_array_length(j->'credit_notes') = 1 and j#>>'{credit_notes,0,number}' = 'CN-PAY-1' and (j->>'credited_cents')::int = 1000 from (select pg_temp.acct(:'inv', 'I2') j) x), 'the invoice lists its credit note');
select t.eq((select count(*) from audit_log where org_id = t.id('c1') and action = 'centre_credit_note_issue' and (after->>'total_cents')::int = 1000), 1, 'AUDIT: the credit note issue is audited');
select t.eq((select count(*) from audit_log where org_id = t.id('c1') and (coalesce(before::text, '') || coalesce(after::text, '')) ~* 'cancelled by the centre'), 0, 'AUDIT: the reason is redacted');
-- a credit note on an UNPAID invoice reduces the balance (I1 was paid; use a fresh one)
select pg_temp.inv('L1', t.id('c1'), :'o1', :'h4', :'s4', 10000, 0, 7);        -- 10900
create temp table r_cn2 as select pg_temp.cn(:'inv', 'L1', 1000, 'Price correction') as j;
select t.ok((select j->>'number' = 'CN-PAY-2' and (j->>'excess_to_family_cents')::int = 0 and (j->>'balance_cents')::int = 9900 and j->>'pay_status' = 'issued' from r_cn2), 'on an unpaid invoice: balance 10900 − 1000 = 9900, no excess, still "issued"; the second credit note is CN-PAY-2');
select t.ok((select (j->>'credited_cents')::int = 1000 and (j->>'balance_cents')::int = 9900 from (select pg_temp.acct(:'inv', 'L1') j) x), 'the account shows credited 1000, balance 9900');
-- caps: can't credit more than what is left
select pg_temp.refused(:'inv', format($q$ select centre_issue_credit_note(%L, 9901, 'x') $q$, t.id('L1')), 'TOO_MUCH: you can credit at most S$99.00 more', 'more than what is left to credit');
select t.ok((select j->>'pay_status' = 'void' and (j->>'balance_cents')::int = 0 from (select pg_temp.cn(:'inv', 'L1', 9900, 'Cancelled in full') j) x), 'crediting the rest voids the invoice: status void, balance 0');
select t.ok(pg_temp.ps(:'inv', 'L1') = 'void', 'status: void (a credit note covers it all)');
select pg_temp.refused(:'inv', format($q$ select centre_issue_credit_note(%L, 100, 'x') $q$, t.id('L1')), 'NOT_ALLOWED: that invoice is already credited in full', 'a fully credited invoice takes no more credit notes');
select pg_temp.refused(:'paym', format($q$ select centre_record_payment(%L, %L, 'cash', 100, (select today from td), null, array[%L]::uuid[]) $q$, t.id('c1'), :'h4', t.id('L1')), 'NOT_ALLOWED: PAY-', 'a fully credited invoice can''t be paid');
select pg_temp.refused(:'inv', format($q$ select centre_issue_credit_note(%L, 100, 'x') $q$, t.id('cn1')), 'NOT_ALLOWED: only an issued invoice', 'a credit note can''t be credited');
-- credit notes by lines (before GST): 2 x S$15.00 = S$30.00 + 9% GST = S$32.70
select pg_temp.inv('L2', t.id('c1'), :'o1', :'h4', :'s4', 10000, 0, 7);        -- 10900
select t.ok((select (j->>'net_cents')::int = 3000 and (j->>'gst_cents')::int = 270 and (j->>'total_cents')::int = 3270
             from (select pg_temp.cn(:'inv', 'L2', null, 'Two lessons not held', '[{"description":"Maths 3 Nov","qty":2,"unit_cents":1500}]'::jsonb) j) x), 'by lines: 2 × S$15.00 + 9% GST = S$32.70');
select pg_temp.refused(:'inv', format($q$ select centre_issue_credit_note(%L, null, 'x', '[{"description":"","qty":1,"unit_cents":100}]'::jsonb) $q$, t.id('L2')), 'BAD_VALUE', 'a line with no description');
select pg_temp.refused(:'inv', format($q$ select centre_issue_credit_note(%L, null, 'x', '[{"description":"A","qty":1,"unit_cents":-100}]'::jsonb) $q$, t.id('L2')), 'BAD_VALUE', 'a line with a negative amount');
select pg_temp.refused(:'inv', format($q$ select centre_issue_credit_note(%L, null, 'x', '[{"description":"A","qty":1,"unit_cents":999999}]'::jsonb) $q$, t.id('L2')), 'TOO_MUCH', 'lines adding up to more than the invoice');
-- a total that no subtotal can make exactly at 9% (6c: 5c gives 5, 6c gives 7): refused with the two nearest that work
select pg_temp.refused(:'inv', format($q$ select centre_issue_credit_note(%L, 6, 'x') $q$, t.id('L2')), 'NOT_ALLOWED: with GST that exact amount can''t be made; try S$0.05 or S$0.08', 'an amount GST can''t split exactly');

-- ===================================================================== 10. GST on credit notes = the shared vectors (assets/js/money.js reads the same CSV)
create temp table gst_vec(name text, subtotal_cents bigint, rate_bp int, inclusive boolean, registered boolean, net_cents bigint, gst_cents bigint, total_cents bigint);
\copy gst_vec from 'tests/gst-vectors.csv' with (format csv, header true)
do $$
declare v record; iid uuid; cn jsonb; n int := 0; big bigint := 500000000; g record; tdy date := (select today from td);
begin
  perform t.as('00000000-0000-0000-0000-00000000bb01');
  for v in select * from gst_vec where subtotal_cents > 0 order by name loop
    iid := gen_random_uuid(); n := n + 1;
    select * into g from centre_gst_totals(big, v.rate_bp, v.inclusive, v.registered);
    insert into centre_invoices(id, org_id, kind, household_id, student_id, gst_registered, gst_rate_bp, gst_inclusive, net_cents, gst_cents, total_cents)
      values (iid, t.id('c1'), 'lesson', '00000000-0000-0000-0000-00000000cb01', '00000000-0000-0000-0000-00000000db01', v.registered, case when v.registered then v.rate_bp else 0 end, v.inclusive, g.net_cents, g.gst_cents, g.total_cents);
    insert into centre_invoice_lines(org_id, invoice_id, position, description, qty, unit_cents) values (t.id('c1'), iid, 1, 'Big one', 1, big);
    update centre_invoices set status = 'issued', issue_date = tdy, due_date = tdy + 7 where id = iid;
    -- by lines: the credit note's GST is the shared function applied to the vector's subtotal, at the rate FROZEN on the invoice
    cn := centre_issue_credit_note(iid, null, 'vector ' || v.name, jsonb_build_array(jsonb_build_object('description', 'Vector', 'qty', 1, 'unit_cents', v.subtotal_cents)));
    if (cn->>'net_cents')::bigint <> v.net_cents or (cn->>'gst_cents')::bigint <> v.gst_cents or (cn->>'total_cents')::bigint <> v.total_cents then
      raise exception 'FAIL: credit note for vector "%" gave net %, GST %, total % (expected %, %, %)', v.name, cn->>'net_cents', cn->>'gst_cents', cn->>'total_cents', v.net_cents, v.gst_cents, v.total_cents;
    end if;
    -- by amount: whatever total the family is credited is exactly what was typed (or the person is told the nearest amounts that work)
    begin
      cn := centre_issue_credit_note(iid, v.total_cents, 'vector amount ' || v.name);
      if (cn->>'total_cents')::bigint <> v.total_cents then raise exception 'FAIL: crediting S$% by amount gave %', v.total_cents, cn->>'total_cents'; end if;
    exception when others then
      if sqlerrm not like 'NOT_ALLOWED: with GST that exact amount%' then raise; end if;
    end;
  end loop;
  raise notice 'PASS credit notes use centre_gst_totals on all % positive shared vectors, at the rate frozen on the invoice', n;
end $$;

-- ===================================================================== 11. STATUS TRANSITIONS (a fresh family: Wu)
insert into households(id, org_id, name) values ('00000000-0000-0000-0000-00000000cb05', t.id('c1'), 'Wu Family');
insert into students(id, tutor_id, org_id, name, household_id) values ('00000000-0000-0000-0000-00000000db05', :'o1', t.id('c1'), 'Wendy Wu', '00000000-0000-0000-0000-00000000cb05');
\set h5 '00000000-0000-0000-0000-00000000cb05'
\set s5 '00000000-0000-0000-0000-00000000db05'
select pg_temp.inv('M1', t.id('c1'), :'o1', :'h5', :'s5', 1000, 0, 7);        -- 1090 due in 7 days
select t.ok(pg_temp.ps(:'paym', 'M1') = 'issued', 'unpaid and not due yet: issued');
select pg_temp.pay(:'paym', t.id('c1'), :'h5', 'cash', 500, null, array[t.id('M1')]);
select t.ok(pg_temp.ps(:'paym', 'M1') = 'part_paid', 'a part payment: part-paid');
select t.put('M1a', (select id from centre_payments where org_id = t.id('c1') and household_id = :'h5' and amount_cents = 500));
select pg_temp.pay(:'paym', t.id('c1'), :'h5', 'cash', 590, null, array[t.id('M1')]);
select t.put('M1b', (select id from centre_payments where org_id = t.id('c1') and household_id = :'h5' and amount_cents = 590));
select t.ok(pg_temp.ps(:'paym', 'M1') = 'paid', 'the rest paid: paid');
select pg_temp.reverse(:'paym', t.id('M1b'), 'Wrong invoice');
select t.ok(pg_temp.ps(:'paym', 'M1') = 'part_paid', 'reverse the last payment: back to part-paid');
select pg_temp.reverse(:'paym', t.id('M1a'), 'Wrong invoice');
select t.ok(pg_temp.ps(:'paym', 'M1') = 'issued', 'reverse the first too: back to issued (nothing paid)');
select pg_temp.inv('M2', t.id('c1'), :'o1', :'h5', :'s5', 1000, 10, -1);       -- due yesterday
select t.ok(pg_temp.ps(:'paym', 'M2') = 'overdue', 'the due date has passed and money is owed: overdue');
select pg_temp.pay(:'paym', t.id('c1'), :'h5', 'cash', 100, null, array[t.id('M2')]);
select t.ok(pg_temp.ps(:'paym', 'M2') = 'overdue', 'part-paid but past due: still shown as overdue (the more urgent word)');
select pg_temp.pay(:'paym', t.id('c1'), :'h5', 'cash', 990, null, array[t.id('M2')]);
select t.ok(pg_temp.ps(:'paym', 'M2') = 'paid', 'paid in full after the due date: paid');
select pg_temp.inv('M3', t.id('c1'), :'o1', :'h5', :'s5', 1000, 7, 0);         -- due TODAY
select t.ok(pg_temp.ps(:'paym', 'M3') = 'issued', 'paying on the due date is on time: not overdue until the day after');
select pg_temp.inv('M4', t.id('c1'), :'o1', :'h5', :'s5', 1000, 1, 0 - 1);
select t.ok(pg_temp.ps(:'paym', 'M4') = 'overdue', 'one day after the due date: overdue');
select pg_temp.cn(:'inv', 'M4', 1090, 'Cancelled');
select t.ok(pg_temp.ps(:'paym', 'M4') = 'void', 'fully credited: void (even though it was overdue)');
-- the pure rule, edge by edge
select t.ok(centre_pay_status('draft', 'lesson', 100, 0, 0, null, current_date) = 'draft' and centre_pay_status('void', 'lesson', 0, 0, 0, null, current_date) = 'discarded'
        and centre_pay_status('issued', 'lesson', 0, 0, 0, current_date + 1, current_date) = 'paid' and centre_pay_status('issued', 'credit_note', 100, 0, 0, null, current_date) = 'credit_note'
        and centre_pay_status('issued', 'lesson', 100, 100, 0, current_date - 5, current_date) = 'void' and centre_pay_status('issued', 'lesson', 100, 60, 40, current_date - 5, current_date) = 'paid'
        and centre_pay_status('issued', 'lesson', 100, 60, 0, current_date - 5, current_date) = 'overdue' and centre_pay_status('issued', 'lesson', 100, 60, 0, current_date + 5, current_date) = 'issued'
        and centre_pay_status('issued', 'lesson', 100, 0, 1, null, current_date) = 'part_paid', 'centre_pay_status: draft / discarded / zero-total paid / credit note / void / paid after credit / overdue / issued / part_paid');

-- ===================================================================== 12. THE LIST: filters, counts, who may see it
create temp table l_all as select pg_temp.acct(:'paym', 'I1') as dummy;      -- (just to leave the claims as the payments clerk)
create function pg_temp.lst(p_user uuid, p_filter text default null, p_period date default null) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_invoice_account_list(t.id('c1'), p_period, p_filter); end $$;
grant execute on function pg_temp.lst(uuid, text, date) to public;
select t.ok((select (j#>>'{counts,all}')::int = (select count(*) from centre_invoices where org_id = t.id('c1') and status = 'issued' and kind <> 'credit_note') from (select pg_temp.lst(:'paym') j) x),
            'the list counts every issued invoice of this centre and no credit note');
select t.ok((select (j#>>'{counts,all}')::int = (j#>>'{counts,unpaid}')::int + (j#>>'{counts,paid}')::int + (j#>>'{counts,void}')::int from (select pg_temp.lst(:'paym') j) x), 'unpaid + paid + void = all (every invoice is in exactly one of them)');
select t.ok((select bool_and(r->>'pay_status' = 'paid' and (r->>'balance_cents')::int = 0) and count(*) = (j#>>'{counts,paid}')::int from (select pg_temp.lst(:'paym', 'paid') j) x, jsonb_array_elements(j->'rows') r group by j), 'filter paid: only paid rows, as many as the chip says');
select t.ok((select bool_and((r->>'balance_cents')::int > 0 and r->>'pay_status' <> 'void') and count(*) = (j#>>'{counts,unpaid}')::int from (select pg_temp.lst(:'paym', 'unpaid') j) x, jsonb_array_elements(j->'rows') r group by j), 'filter unpaid: only rows that still owe');
select t.ok((select bool_and(r->>'pay_status' = 'void') and count(*) = (j#>>'{counts,void}')::int and count(*) >= 2 from (select pg_temp.lst(:'paym', 'void') j) x, jsonb_array_elements(j->'rows') r group by j), 'filter void: the fully credited invoices (L1, M4 and the vectors)');
select t.ok((select exists (select 1 from jsonb_array_elements(j->'rows') r where r->>'number' = (select number_text from centre_invoices where id = t.id('M3'))) and
                    not exists (select 1 from jsonb_array_elements(j->'rows') r where r->>'number' = (select number_text from centre_invoices where id = t.id('M3')) and r->>'pay_status' = 'overdue')
               from (select pg_temp.lst(:'paym', 'unpaid') j) x), 'M3 (due today) is listed as unpaid but not overdue');
-- make an overdue part-paid one
select pg_temp.inv('M5', t.id('c1'), :'o1', :'h5', :'s5', 2000, 15, -3);   -- 2180 due 3 days ago
select pg_temp.pay(:'paym', t.id('c1'), :'h5', 'cash', 1000, null, array[t.id('M5')]);
select t.ok((select exists (select 1 from jsonb_array_elements(j->'rows') r where r->>'number' = (select number_text from centre_invoices where id = t.id('M5')) and r->>'pay_status' = 'overdue' and (r->>'paid_cents')::int = 1000 and (r->>'balance_cents')::int = 1180)
               from (select pg_temp.lst(:'paym', 'overdue') j) x), 'filter overdue: M5 (part-paid but past due) is there, paid 1000, balance 1180');
select t.ok((select exists (select 1 from jsonb_array_elements(j->'rows') r where r->>'number' = (select number_text from centre_invoices where id = t.id('M5')))
               from (select pg_temp.lst(:'paym', 'part_paid') j) x), 'filter part-paid: M5 is there too (part-paid and overdue are not exclusive in the filters)');
select t.ok((select (j->>'outstanding_cents')::bigint = (select sum((r->>'balance_cents')::bigint) from jsonb_array_elements(j->'rows') r where r->>'pay_status' <> 'void')
                 and (j->>'overdue_cents')::bigint = (select coalesce(sum((r->>'balance_cents')::bigint), 0) from jsonb_array_elements(j->'rows') r where r->>'pay_status' = 'overdue') from (select pg_temp.lst(:'paym') j) x), 'the outstanding and overdue totals add up from the rows');
select t.ok((select not (j::text ~* '(Elsewhere|OTH-|Ellie)') from (select pg_temp.lst(:'paym') j) x), 'the list never shows another centre''s invoices');
select t.ok((select jsonb_array_length(j->'rows') = 0 from (select pg_temp.lst(:'paym', 'all', date '2001-01-01') j) x), 'a month with nothing in it lists nothing');
select t.ok((select jsonb_array_length(j->'rows') > 0 from (select pg_temp.lst(:'paym', 'all', (select today from td)) j) x), 'the month filter finds this month''s invoices');
select pg_temp.refused(:'paym', format($q$ select centre_invoice_account_list(%L, null, 'everything') $q$, t.id('c1')), 'BAD_VALUE', 'an unknown filter');
select t.ok((select jsonb_array_length(j->'rows') > 0 from (select pg_temp.lst(:'inv') j) x), 'staff who only issue invoices can list them');
select t.ok((select jsonb_array_length(j->'rows') > 0 from (select pg_temp.lst(:'both') j) x) and (select jsonb_array_length(j->'rows') > 0 from (select pg_temp.lst(:'o1') j) x), 'so can staff with both, and the owner');
select pg_temp.refused(:'rev',  format($q$ select centre_invoice_account_list(%L) $q$, t.id('c1')), 'NOT_ALLOWED', 'view_revenue alone can''t list invoices');
select pg_temp.refused(:'tut',  format($q$ select centre_invoice_account_list(%L) $q$, t.id('c1')), 'NOT_FOUND', 'a tutor sees no invoice list');
select pg_temp.refused(:'par',  format($q$ select centre_invoice_account_list(%L) $q$, t.id('c1')), 'NOT_FOUND', 'a parent sees no invoice list');
select pg_temp.refused(:'off',  format($q$ select centre_invoice_account_list(%L) $q$, t.id('c1')), 'NOT_FOUND', 'switched-off staff see nothing');
select pg_temp.refused(:'out',  format($q$ select centre_invoice_account_list(%L) $q$, t.id('c1')), 'NOT_FOUND', 'a stranger sees nothing');
select pg_temp.refused(:'solo', format($q$ select centre_invoice_account_list(%L) $q$, t.id('c1')), 'NOT_FOUND', 'a solo tutor sees nothing of a centre');
select pg_temp.refused(:'solo', format($q$ select centre_invoice_account_list(%L) $q$, t.id('solo_org')), 'NOT_FOUND', 'a solo organisation has no centre invoice list');
select pg_temp.refused(:'o2',   format($q$ select centre_invoice_account_list(%L) $q$, t.id('c1')), 'NOT_FOUND', 'another centre''s owner sees nothing');
select pg_temp.refused(:'o2',   format($q$ select centre_invoice_account_get(%L) $q$, t.id('I1')), 'NOT_FOUND', 'nor one invoice');
select pg_temp.refused(:'tut',  format($q$ select centre_invoice_account_get(%L) $q$, t.id('I1')), 'NOT_FOUND', 'a tutor can''t open one invoice''s account');
select pg_temp.refused(:'paym', format($q$ select centre_invoice_account_get(%L) $q$, t.id('cn1')), 'NOT_FOUND', 'a credit note isn''t an invoice account');
select pg_temp.refused(:'paym', format($q$ select centre_invoice_account_get(%L) $q$, gen_random_uuid()), 'NOT_FOUND', 'an unknown invoice');

-- ===================================================================== 13. THE SHARE LINK and the public view
select pg_temp.inv('P1', t.id('c1'), :'o1', :'h1', :'s1', 20000, 0, 7);          -- 21800, unpaid, Lim family
create function pg_temp.share(p_user uuid, k text, p_exp date default null, p_rot boolean default false) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_invoice_share_link(t.id(k), p_exp, p_rot); end $$;
create function pg_temp.pub(tok uuid) returns jsonb language plpgsql as $$
begin perform set_config('request.jwt.claims', '', false); set role anon; begin return centre_invoice_public(tok); exception when others then reset role; raise; end; end $$;
grant execute on function pg_temp.share(uuid, text, date, boolean), pg_temp.pub(uuid) to public;
select pg_temp.refused(:'paym', format($q$ select centre_invoice_share_link(%L) $q$, t.id('P1')), 'NOT_ALLOWED', 'staff who only record payments can''t make a link');
select pg_temp.refused(:'rev',  format($q$ select centre_invoice_share_link(%L) $q$, t.id('P1')), 'NOT_ALLOWED', 'view_revenue alone can''t');
select pg_temp.refused(:'tut',  format($q$ select centre_invoice_share_link(%L) $q$, t.id('P1')), 'NOT_FOUND', 'a tutor can''t');
select pg_temp.refused(:'par',  format($q$ select centre_invoice_share_link(%L) $q$, t.id('P1')), 'NOT_FOUND', 'a parent can''t');
select pg_temp.refused(:'off',  format($q$ select centre_invoice_share_link(%L) $q$, t.id('P1')), 'NOT_FOUND', 'switched-off staff can''t');
select pg_temp.refused(:'o2',   format($q$ select centre_invoice_share_link(%L) $q$, t.id('P1')), 'NOT_FOUND', 'another centre''s owner can''t make a link to this centre''s invoice');
select pg_temp.refused(:'solo', format($q$ select centre_invoice_share_link(%L) $q$, t.id('P1')), 'NOT_FOUND', 'a solo tutor can''t');
select pg_temp.refused(:'inv',  format($q$ select centre_invoice_share_link(%L) $q$, t.id('cn1')), 'NOT_ALLOWED: only an issued invoice', 'a credit note has no link');
insert into centre_invoices(id, org_id, kind, household_id) values ('00000000-0000-0000-0000-00000000f0d1', t.id('c1'), 'lesson', :'h1');
select pg_temp.refused(:'inv',  $q$ select centre_invoice_share_link('00000000-0000-0000-0000-00000000f0d1') $q$, 'NOT_ALLOWED: only an issued invoice', 'a draft has no link');
delete from centre_invoices where id = '00000000-0000-0000-0000-00000000f0d1';
select pg_temp.refused(:'inv',  format($q$ select centre_invoice_share_link(%L, (select today - 1 from td)) $q$, t.id('P1')), 'BAD_VALUE', 'an expiry date in the past');
select pg_temp.refused(:'inv',  format($q$ select centre_invoice_share_link(%L, (select today + 4000 from td)) $q$, t.id('P1')), 'BAD_VALUE', 'an expiry date over ten years away');
create temp table tok as select (pg_temp.share(:'inv', 'P1')->>'token')::uuid as t1;
select t.ok((select t1 is not null from tok), 'staff who issue invoices get a secret link');
select t.ok((select (pg_temp.share(:'both', 'P1')->>'token')::uuid = t1 from tok), 'asking again returns the SAME link (so the one already sent keeps working)');
select t.eq((select count(*) from centre_invoice_share where invoice_id = t.id('P1')), 1, 'one link row per invoice');
-- the public view
create temp table pub1 as select pg_temp.pub((select t1 from tok)) as j;
reset role;
select t.ok((select j#>>'{centre,name}' = 'Pay Test Centre' and j#>>'{invoice,number}' = (select number_text from centre_invoices where id = t.id('P1')) and (j#>>'{invoice,total_cents}')::int = 21800
              and (j#>>'{invoice,balance_cents}')::int = 21800 and j#>>'{invoice,pay_status}' = 'issued' and j#>>'{invoice,bill_to}' = 'Lim Family' from pub1), 'the link shows the centre name, the invoice number, the total and what is owed');
select t.ok((select jsonb_array_length(j#>'{invoice,lines}') = 1 and j#>>'{invoice,lines,0,student_name}' = 'Sophie Lim' from pub1), 'and its lines');
select t.ok((select j#>>'{centre,brand_color}' ~ '^#[0-9A-Fa-f]{6}$' from pub1), 'and the centre''s brand colour');
select t.ok((select j#>>'{paynow,type}' = 'uen' and j#>>'{paynow,id}' = '200812345K' and j#>>'{paynow,reference}' = (select number_text from centre_invoices where id = t.id('P1')) and (j#>>'{paynow,amount_cents}')::int = 21800 from pub1),
            'a PayNow target using the centre''s own UEN, the invoice number as the reference and the amount outstanding');
select t.ok((select not (j::text ~* '(Tan Family|Ong Family|Goh Family|Wu Family|Elsewhere|Ellie|Tara|Oscar|Gina|Wendy|@|tutor|password)') from pub1), 'ISOLATION: no other family, no other centre, no email, no tutor appears in the public view');
select t.ok((select not (j::text like '%' || t.id('c1')::text || '%' or j::text like '%' || :'h1' || '%' or j::text like '%' || :'s1' || '%' or j::text like '%' || t.id('P1')::text || '%') from pub1), 'ISOLATION: none of the internal ids (centre, family, student, invoice) is in the public view');
select t.ok((select j - 'centre' - 'invoice' - 'paynow' - 'expires_on' = '{}'::jsonb from pub1), 'nothing else is in it: centre, invoice, paynow, expiry');
-- wrong tokens
select t.ok(pg_temp.pub(gen_random_uuid()) is null, 'WRONG TOKEN: a random token returns nothing');
select t.ok(pg_temp.pub(null) is null, 'no token returns nothing');
select t.ok(pg_temp.pub(t.id('P1')) is null, 'the invoice''s own id is not a token: nothing');
reset role;
-- another invoice's token shows only THAT invoice
select pg_temp.share(:'inv', 'I3');
select t.ok((select pg_temp.pub((select token from centre_invoice_share where invoice_id = t.id('I3')))#>>'{invoice,number}' = (select number_text from centre_invoices where id = t.id('I3'))), 'a token opens only the invoice it was made for');
reset role;
select t.ok((select pg_temp.pub((select token from centre_invoice_share where invoice_id = t.id('I3')))#>'{paynow}' = 'null'::jsonb), 'a paid invoice shows no PayNow QR (nothing to pay)');
reset role;
-- the table is closed to every browser role
select t.fails($q$ set role authenticated; select t.as('00000000-0000-0000-0000-00000000bb01'); select * from centre_invoice_share $q$, 'the owner can''t read the share table (tokens are secrets; only the functions use it)');
reset role;
select t.fails($q$ set role anon; select * from centre_invoice_share $q$, 'a signed-out visitor can''t read it');
reset role;
select t.fails($q$ set role authenticated; select t.as('00000000-0000-0000-0000-00000000bb01'); insert into centre_invoice_share(org_id, invoice_id) values (t.id('c1'), t.id('I1')) $q$, 'nor write to it');
reset role;
select t.eq((select count(*) from audit_log where org_id = t.id('c1') and exists (select 1 from centre_invoice_share s where (coalesce(before::text, '') || coalesce(after::text, '')) like '%' || s.token::text || '%')), 0, 'AUDIT: no share token is in the audit log');
select t.ok((select count(*) >= 1 from audit_log where org_id = t.id('c1') and table_name = 'centre_invoice_share' and action = 'insert' and not (after ? 'token')), 'AUDIT: making a link is still audited (without the token)');
-- rotating: a NEW link, the old one stops working
select t.ok((select (pg_temp.share(:'inv', 'P1', null, true)->>'token')::uuid <> t1 from tok), 'rotating gives a different token');
reset role;
select t.ok(pg_temp.pub((select t1 from tok)) is null, 'the OLD link stops working at once');
reset role;
select t.ok((select pg_temp.pub((select token from centre_invoice_share where invoice_id = t.id('P1'))) is not null), 'the new one works');
reset role;
-- expiry
update centre_invoice_share set expires_on = (select today from td) where invoice_id = t.id('P1');
select t.ok((select pg_temp.pub((select token from centre_invoice_share where invoice_id = t.id('P1'))) is not null), 'a link that expires TODAY still works today');
reset role;
update centre_invoice_share set expires_on = (select today - 1 from td) where invoice_id = t.id('P1');
select t.ok((select pg_temp.pub((select token from centre_invoice_share where invoice_id = t.id('P1'))) is null), 'EXPIRED: yesterday''s expiry returns nothing');
reset role;
create temp table tok2 as select (select token from centre_invoice_share where invoice_id = t.id('P1')) as old;
select t.ok((select (pg_temp.share(:'inv', 'P1', (select today + 30 from td))->>'token')::uuid <> old from tok2), 'asking for the link of an expired one makes a fresh token (with the new expiry)');
select t.ok((select pg_temp.pub(old) is null from tok2), 'and the expired token stays dead');
reset role;
select t.ok((select (pg_temp.pub((select token from centre_invoice_share where invoice_id = t.id('P1')))->>'expires_on')::date = (select today + 30 from td)), 'the public view says when the link expires');
reset role;
-- the centre can switch links off
select pg_temp.cfg(t.id('c1'), :'o1', '{invoicing,delivery,share_link}', 'false');
select pg_temp.refused(:'inv', format($q$ select centre_invoice_share_link(%L) $q$, t.id('I1')), 'NOT_ALLOWED: shareable links are switched off', 'share_link = false: no link can be made');
select t.ok((select pg_temp.pub((select token from centre_invoice_share where invoice_id = t.id('P1'))) is null), 'share_link = false: links already sent stop showing anything');
reset role;
select pg_temp.cfg(t.id('c1'), :'o1', '{invoicing,delivery,share_link}', 'true');
select t.ok((select pg_temp.pub((select token from centre_invoice_share where invoice_id = t.id('P1'))) is not null), 'switched back on: the same link works again');
reset role;
-- PayNow section follows the payment settings
select pg_temp.cfg(t.id('c1'), :'o1', '{payments,paynow,id}', '""');
select t.ok((select pg_temp.pub((select token from centre_invoice_share where invoice_id = t.id('P1')))->'paynow' = 'null'::jsonb), 'no PayNow id in the settings: no PayNow section');
reset role;
select pg_temp.cfg(t.id('c1'), :'o1', '{payments,paynow,id}', '"200812345K"');
select pg_temp.cfg(t.id('c1'), :'o1', '{payments,modes}', '["statement_matching"]');
select t.ok((select pg_temp.pub((select token from centre_invoice_share where invoice_id = t.id('P1')))->'paynow' = 'null'::jsonb), 'manual PayNow switched off: no PayNow section');
reset role;
select pg_temp.cfg(t.id('c1'), :'o1', '{payments,modes}', '["manual_paynow"]');
-- a fully credited invoice: still opens (it tells the family it is cancelled) but asks for no money
select pg_temp.share(:'inv', 'L1');
select t.ok((select j#>>'{invoice,pay_status}' = 'void' and j->'paynow' = 'null'::jsonb and (j#>>'{invoice,balance_cents}')::int = 0 from (select pg_temp.pub((select token from centre_invoice_share where invoice_id = t.id('L1'))) j) x), 'a fully credited invoice shows as void with no PayNow');
reset role;
-- a payment moves the public numbers
select pg_temp.pay(:'paym', t.id('c1'), :'h1', 'cash', 8000, null, array[t.id('P1')]);
select t.ok((select (j#>>'{invoice,paid_cents}')::int = 8000 and (j#>>'{invoice,balance_cents}')::int = 13800 and j#>>'{invoice,pay_status}' = 'part_paid' and (j#>>'{paynow,amount_cents}')::int = 13800
               from (select pg_temp.pub((select token from centre_invoice_share where invoice_id = t.id('P1'))) j) x), 'after a part payment the link shows part-paid and the PayNow amount drops to what is left');
reset role;

-- ===================================================================== 14. WHATSAPP message
create function pg_temp.wa(p_user uuid, k text) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_invoice_whatsapp(t.id(k)); end $$;
grant execute on function pg_temp.wa(uuid, text) to public;
select pg_temp.refused(:'paym', format($q$ select centre_invoice_whatsapp(%L) $q$, t.id('P1')), 'NOT_ALLOWED', 'staff who only record payments can''t build the message');
select pg_temp.refused(:'tut',  format($q$ select centre_invoice_whatsapp(%L) $q$, t.id('P1')), 'NOT_FOUND', 'a tutor can''t');
select pg_temp.refused(:'o2',   format($q$ select centre_invoice_whatsapp(%L) $q$, t.id('P1')), 'NOT_FOUND', 'another centre''s owner can''t');
select t.ok((select j->>'phone' = '6591234567' and (j#>>'{vars,amount_cents}')::int = 13800 and j#>>'{vars,name}' = 'Lim Family' and j#>>'{vars,centre}' = 'Pay Test Centre'
              and j#>>'{vars,number}' = (select number_text from centre_invoices where id = t.id('P1')) and j->>'token' is not null and j->>'template' like '%{link}%' and j->>'template' like 'Hi {name}%'
              from (select pg_temp.wa(:'inv', 'P1') j) x), 'default wording; phone cleaned to digits with 65 added; amount = what is still owed; the link token is there');
select t.ok((select j->>'token' = (select token::text from centre_invoice_share where invoice_id = t.id('P1')) from (select pg_temp.wa(:'inv', 'P1') j) x), 'the message points at the invoice''s own link');
select pg_temp.cfg(t.id('c1'), :'o1', '{invoicing,whatsapp_template}', '"Dear {name}, {centre} here: {number} {amount} by {due_date} {link}"');
select t.ok((select j->>'template' = 'Dear {name}, {centre} here: {number} {amount} by {due_date} {link}' from (select pg_temp.wa(:'inv', 'P1') j) x), 'the centre''s own wording is used');
select pg_temp.cfg(t.id('c1'), :'o1', '{invoicing,whatsapp_template}', to_jsonb(repeat('x', 1500)));
select t.eq((select length(pg_temp.wa(:'inv', 'P1')->>'template')), 1000, 'a runaway template is cut to 1,000 characters');
select pg_temp.cfg(t.id('c1'), :'o1', '{invoicing,whatsapp_template}', '"   "');
select t.ok((select j->>'template' like 'Hi {name}%' from (select pg_temp.wa(:'inv', 'P1') j) x), 'a blank template falls back to the default');
select t.ok((select j->>'phone' is null from (select pg_temp.wa(:'inv', 'I4') j) x), 'a family whose guardian has no number: no phone (the message can still be sent by choosing a contact)');
select t.ok((select j->>'phone' is null from (select pg_temp.wa(:'inv', 'I3') j) x), 'a family with no guardian on file: no phone');
select pg_temp.cfg(t.id('c1'), :'o1', '{invoicing,delivery,share_link}', 'false');
select t.ok((select j->>'token' is null from (select pg_temp.wa(:'inv', 'P1') j) x), 'share links off: the message carries no link');
select pg_temp.cfg(t.id('c1'), :'o1', '{invoicing,delivery,share_link}', 'true');
select pg_temp.refused(:'inv', format($q$ select centre_invoice_whatsapp(%L) $q$, t.id('cn1')), 'NOT_ALLOWED', 'a credit note has no WhatsApp message');

-- ===================================================================== 15. who reads the new tables and the family credit
select t.as(:'paym'); set role authenticated;
select t.ok((select count(*) > 0 from centre_family_credit), 'staff with record_payments read the credit ledger');
select t.as(:'inv');   select t.eq((select count(*) from centre_family_credit), 0, 'staff who only issue invoices read none of it');
select t.as(:'rev');   select t.eq((select count(*) from centre_family_credit), 0, 'view_revenue alone: none');
select t.as(:'tut');   select t.eq((select count(*) from centre_family_credit), 0, 'a tutor reads none');
select t.as(:'par');   select t.eq((select count(*) from centre_family_credit), 0, 'a parent reads none');
select t.as(:'off');   select t.eq((select count(*) from centre_family_credit), 0, 'switched-off staff read none');
select t.as(:'out');   select t.eq((select count(*) from centre_family_credit), 0, 'a stranger reads none');
select t.as(:'solo');  select t.eq((select count(*) from centre_family_credit), 0, 'a solo tutor reads none');
select t.as(:'o2');    select t.eq((select count(*) from centre_family_credit), 0, 'another centre''s owner reads none');
select t.as(:'o1');    select t.ok((select count(*) > 0 from centre_family_credit), 'the owner reads it');
select t.fails(format($q$ insert into centre_family_credit(org_id, household_id, kind, cents) values (%L, %L, 'overpayment', 100) $q$, t.id('c1'), :'h1'), 'nobody can write to the credit ledger from a browser');
reset role;
create function pg_temp.fcg(p_user uuid, p_org uuid, p_hh uuid) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_family_credit_get(p_org, p_hh); end $$;
grant execute on function pg_temp.fcg(uuid, uuid, uuid) to public;
select t.ok((select (j->>'balance_cents')::bigint = (select sum(cents) from centre_family_credit where household_id = :'h1') and jsonb_array_length(j->'rows') = (select count(*) from centre_family_credit where household_id = :'h1')
              from (select pg_temp.fcg(:'paym', t.id('c1'), :'h1') j) x), 'the credit read shows the balance and every ledger row for the family');
select t.ok((select not (j::text ~* '(reference|DBS|0123456789)') from (select pg_temp.fcg(:'paym', t.id('c1'), :'h1') j) x), 'and never a refund''s reference');
select pg_temp.refused(:'inv',  format($q$ select centre_family_credit_get(%L, %L) $q$, t.id('c1'), :'h1'), 'NOT_ALLOWED', 'staff who only issue invoices can''t read a family''s credit');
select pg_temp.refused(:'tut',  format($q$ select centre_family_credit_get(%L, %L) $q$, t.id('c1'), :'h1'), 'NOT_FOUND', 'a tutor can''t');
select pg_temp.refused(:'o2',   format($q$ select centre_family_credit_get(%L, %L) $q$, t.id('c1'), :'h1'), 'NOT_FOUND', 'another centre''s owner can''t');
select pg_temp.refused(:'paym', format($q$ select centre_family_credit_get(%L, %L) $q$, t.id('c1'), :'hx'), 'NOT_FOUND', 'a family of another centre isn''t found');
select pg_temp.refused(:'o1',   format($q$ select centre_refund_family_credit(%L, %L, 100, 'bank', null, 'x') $q$, t.id('c1'), :'hx'), 'NOT_FOUND', 'nor can its credit be refunded');

-- ===================================================================== 16. FINAL SWEEP: nothing that identifies a payer or an account is anywhere in the audit log
reset role; select set_config('request.jwt.claims', '', false);
select t.eq((select count(*) from audit_log where org_id = t.id('c1') and (table_name in ('centre_payments', 'centre_payment_allocations', 'centre_family_credit', 'centre_invoice_share', 'centre_invoices', 'centre_invoice_lines') or action like 'centre\_%')
                    and (coalesce(before::text, '') || coalesce(after::text, '')) ~* '(John Tan|91234567|bank ref 5551|0123456789|reference": "[^\[])'), 0,
            'FINAL AUDIT SWEEP: no payment reference, payer name or account number in any audit row of the money tables or the money actions');
select t.ok((select count(*) > 20 from audit_log where org_id = t.id('c1') and table_name in ('centre_payments', 'centre_payment_allocations', 'centre_family_credit', 'centre_invoice_share')), 'but the money rows themselves are audited (amounts, who, when)');
select t.eq((select count(*) from centre_payment_allocations a join centre_invoices i on i.id = a.invoice_id where a.org_id <> i.org_id), 0, 'no allocation crosses centres');
select t.eq((select count(*) from centre_payments where org_id = t.id('c2')) + (select count(*) from centre_family_credit where org_id = t.id('c2')), 0, 'the other centre has no payments or credit from any of this');

-- ===================================================================== 17. SPEED: a list of ~400 families (1,600 invoices, half of them paid) comes back fast
insert into households(id, org_id, name) select gen_random_uuid(), t.id('c1'), 'Perf Family ' || g from generate_series(1, 400) g;
create temp table perf_h as select id, row_number() over (order by name) as n from households where org_id = t.id('c1') and name like 'Perf Family %';
do $$
declare tdy date := (select today from td); big record;
begin
  perform t.as('00000000-0000-0000-0000-00000000bb01');
  insert into centre_invoices(org_id, kind, household_id, period_start, period_end, gst_registered, gst_rate_bp, gst_inclusive, net_cents, gst_cents, total_cents)
    select t.id('c1'), 'lesson', h.id, date_trunc('month', tdy)::date - (m * 30), date_trunc('month', tdy)::date - (m * 30) + 27, true, 900, false, 10000, 900, 10900
      from perf_h h cross join generate_series(0, 3) m;
  insert into centre_invoice_lines(org_id, invoice_id, position, description, qty, unit_cents)
    select org_id, id, 1, 'Maths', 1, 10000 from centre_invoices where org_id = t.id('c1') and status = 'draft' and household_id in (select id from perf_h);
  update centre_invoices set status = 'issued', issue_date = tdy - 5, due_date = tdy + (period_start - date_trunc('month', tdy)::date) / 30 + 20
   where org_id = t.id('c1') and status = 'draft' and household_id in (select id from perf_h);
end $$;
create temp table pp as select i.id as invoice_id, i.household_id, gen_random_uuid() as payment_id from centre_invoices i
 where i.org_id = t.id('c1') and i.household_id in (select id from perf_h) and i.status = 'issued' and i.number_seq % 2 = 0;
insert into centre_payments(id, org_id, kind, household_id, method, amount_cents, received_on) select payment_id, t.id('c1'), 'payment', household_id, 'cash', 10900, current_date from pp;
insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) select t.id('c1'), payment_id, invoice_id, 10900 from pp;
select t.ok((select count(*) >= 1600 from centre_invoices where org_id = t.id('c1') and status = 'issued'), 'the busy centre has over 1,600 issued invoices (' || (select count(*) from centre_invoices where org_id = t.id('c1') and status = 'issued') || ')');
analyze centre_invoices; analyze centre_payment_allocations; analyze centre_payments;
create temp table timing(ms numeric, what text);
do $$
declare a timestamptz; j jsonb; f text;
begin
  perform t.as('00000000-0000-0000-0000-00000000bb03');
  foreach f in array array['all', 'unpaid', 'overdue', 'part_paid', 'paid'] loop
    a := clock_timestamp();
    j := centre_invoice_account_list(t.id('c1'), null, f);
    insert into timing values (extract(milliseconds from clock_timestamp() - a), f || ' (' || jsonb_array_length(j->'rows') || ' rows)');
  end loop;
end $$;
select t.ok((select max(ms) < 1500 from timing), 'every filter over ~1,700 invoices answers in under 1.5 s (slowest ' || (select round(max(ms)) from timing) || ' ms: ' || (select string_agg(what || ' ' || round(ms) || ' ms', ', ') from timing) || ')');
select t.ok((select (centre_invoice_account_list(t.id('c1'), null, 'all')->'rows') is not null), 'the list is capped at 1,000 rows and says how many there are in its counts');
select t.ok((select jsonb_array_length(j->'rows') = 1000 and (j#>>'{counts,all}')::int > 1000 from (select centre_invoice_account_list(t.id('c1'), null, 'all') j) x), 'over 1,000 invoices: 1,000 rows come back and the count shows the real total');
