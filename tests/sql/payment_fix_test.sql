-- B4-FIX tests: "Record payment" failed on Supabase with PostgREST error 21000 ("DELETE requires a WHERE clause").
-- Supabase's API layer loads pg-safeupdate, which refuses any DELETE / UPDATE without WHERE; the throwaway Postgres here does not, so the
-- first part emulates that rule by reading the source of every function in `public` (it FAILS on the pre-fix centre_record_payment). The second
-- part records payments in the demo shape (one family with several invoices, one invoice, part payment, exact payment, overpayment into credit).
-- Runs after centre_payments_test.sql and migration_payment_fix.sql in the same throwaway database. All names are FAKE.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000be01', 'p2.owner@centre.test'),   ('00000000-0000-0000-0000-00000000be02', 'p2.invoices@centre.test'),
  ('00000000-0000-0000-0000-00000000be03', 'p2.payments@centre.test'), ('00000000-0000-0000-0000-00000000be04', 'p2.tutor@centre.test'),
  ('00000000-0000-0000-0000-00000000be05', 'p2.parent@centre.test'),   ('00000000-0000-0000-0000-00000000be06', 'p2.outsider@centre.test'),
  ('00000000-0000-0000-0000-00000000be07', 'p2.off@centre.test'),      ('00000000-0000-0000-0000-00000000be08', 'p2.owner2@centre.test'),
  ('00000000-0000-0000-0000-00000000be09', 'p2.revenue@centre.test'),  ('00000000-0000-0000-0000-00000000be0a', 'p2.both@centre.test');
\set o1 '00000000-0000-0000-0000-00000000be01'
\set inv '00000000-0000-0000-0000-00000000be02'
\set paym '00000000-0000-0000-0000-00000000be03'
\set tut '00000000-0000-0000-0000-00000000be04'
\set par '00000000-0000-0000-0000-00000000be05'
\set out '00000000-0000-0000-0000-00000000be06'
\set off '00000000-0000-0000-0000-00000000be07'
\set o2 '00000000-0000-0000-0000-00000000be08'
\set rev '00000000-0000-0000-0000-00000000be09'
\set both '00000000-0000-0000-0000-00000000be0a'
\set solo '00000000-0000-0000-0000-0000000000a1'
\set h1 '00000000-0000-0000-0000-00000000ce01'
\set h2 '00000000-0000-0000-0000-00000000ce02'
\set h3 '00000000-0000-0000-0000-00000000ce03'
\set h4 '00000000-0000-0000-0000-00000000ce04'
\set hx '00000000-0000-0000-0000-00000000ce09'
\set s1 '00000000-0000-0000-0000-00000000de01'
\set s2 '00000000-0000-0000-0000-00000000de02'
\set s3 '00000000-0000-0000-0000-00000000de03'
\set s4 '00000000-0000-0000-0000-00000000de04'
\set sx '00000000-0000-0000-0000-00000000de09'

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
select t.put('q1', org_create_centre('Pay Test Centre', pg_temp.settings_base()));
select org_save_settings(t.id('q1'), pg_temp.settings_base(), date '2000-01-01');      -- the centre is still in setup: its settings apply from the start of time, so an invoice back-dated for the test uses them
select t.as(:'o2');
select t.put('q2', org_create_centre('Other Pay Centre', jsonb_set(pg_temp.settings_base(), '{profile,invoice_prefix}', '"OTH"')));
select org_save_settings(t.id('q2'), jsonb_set(pg_temp.settings_base(), '{profile,invoice_prefix}', '"OTH"'), date '2000-01-01');
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('q1'), :'inv',  'Invoices Ivy',  'staff',  array['issue_invoices'], 'active'),
  (t.id('q1'), :'paym', 'Payments Pat',  'staff',  array['record_payments'], 'active'),
  (t.id('q1'), :'rev',  'Revenue Ray',   'staff',  array['view_revenue'], 'active'),
  (t.id('q1'), :'both', 'Both Beth',     'staff',  array['issue_invoices', 'record_payments'], 'active'),
  (t.id('q1'), :'tut',  'Tutor Tia',     'tutor',  '{}', 'active'),
  (t.id('q1'), :'par',  'Parent Pia',    'parent', '{}', 'active'),
  (t.id('q1'), :'off',  'Switched off',  'staff',  array['issue_invoices', 'record_payments'], 'disabled');
insert into households(id, org_id, name) values
  (:'h1', t.id('q1'), 'Lim Family'), (:'h2', t.id('q1'), 'Tan Family'), (:'h3', t.id('q1'), 'Ong Family'), (:'h4', t.id('q1'), 'Goh Family'), (:'hx', t.id('q2'), 'Elsewhere Family');
insert into students(id, tutor_id, org_id, name, household_id) values
  (:'s1', :'o1', t.id('q1'), 'Sophie Lim', :'h1'), (:'s2', :'o1', t.id('q1'), 'Tara Tan', :'h2'), (:'s3', :'o1', t.id('q1'), 'Oscar Ong', :'h3'),
  (:'s4', :'o1', t.id('q1'), 'Gina Goh', :'h4'), (:'sx', :'o2', t.id('q2'), 'Ellie Else', :'hx');
insert into guardians(org_id, household_id, name, phone) values (t.id('q1'), :'h1', 'Mrs Lim', '9123 4567'), (t.id('q1'), :'h3', 'Mr Ong', null);

-- Lim: I1 S$100 + GST = 10900 (due in 7 days), I2 S$50 + GST = 5450 (OVERDUE, due 5 days ago)   Tan: I3 S$30 + GST = 3270
-- Ong: I4 S$40 (4360, issued 10 days ago) and I5 S$40 (4360, issued 3 days ago, but numbered AFTER it) → oldest-first order is by issue date
select pg_temp.inv('QI1', t.id('q1'), :'o1', :'h1', :'s1', 10000, 0, 7);
select pg_temp.inv('QI2', t.id('q1'), :'o1', :'h1', :'s1', 5000, 20, -5);
select pg_temp.inv('QI3', t.id('q1'), :'o1', :'h2', :'s2', 3000, 0, 7);
select pg_temp.inv('QI5', t.id('q1'), :'o1', :'h3', :'s3', 4000, 3, 7);        -- numbered 4 but issued later than I4? (I4 below is numbered 5)
select pg_temp.inv('QI4', t.id('q1'), :'o1', :'h3', :'s3', 4000, 10, 7);       -- numbered 5, issued 10 days ago → it is the OLDEST
select pg_temp.inv('QX1', t.id('q2'), :'o2', :'hx', :'sx', 1000, 0, 7);
select t.ok((select total_cents = 10900 and number_text = 'PAY-1' from centre_invoices where id = t.id('QI1')), 'the made-up invoices exist: I1 = PAY-1 = S$109.00');
select t.ok((select total_cents = 5450 and due_date < (select today from td) from centre_invoices where id = t.id('QI2')), 'I2 = S$54.50, already past its due date');
select t.ok((select number_text = 'PAY-4' from centre_invoices where id = t.id('QI5')) and (select number_text = 'PAY-5' from centre_invoices where id = t.id('QI4')), 'I5 is PAY-4 (issued later) and I4 is PAY-5 (issued earlier)');

-- ===================================================================== 1. no function runs a DELETE / UPDATE without a WHERE (the pg-safeupdate rule)
reset role; select set_config('request.jwt.claims', '', false);
create temp table unsafe_dml as
  select p.proname, btrim(stmt, E' \n\r\t') as stmt
    from pg_proc p, lateral regexp_split_to_table(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '/\*.*?\*/', '', 'g'), ';') stmt
   where p.pronamespace = 'public'::regnamespace and p.prolang = (select oid from pg_language where lanname = 'plpgsql')
     and btrim(stmt, E' \n\r\t') ~* '^(delete\s+from|update\s)'
     and btrim(stmt, E' \n\r\t') !~* '\mwhere\M'
     and btrim(stmt, E' \n\r\t') !~* '\mcurrent\s+of\M';
select t.ok((select count(*) = 0 from unsafe_dml), 'no plpgsql function in public has a DELETE or UPDATE without WHERE (Supabase would refuse it with 21000)' ||
            coalesce(': ' || (select string_agg(proname || ' [' || left(stmt, 40) || ']', ', ') from unsafe_dml), ''));

-- ===================================================================== 2. recording a payment in the demo shape
-- Lim family (h1): QI1 = 10900 (S$109.00), QI2 = 5450.  Tan family (h2): QI3 = 3270.
select t.ok((select balance_cents = 10900 from centre_balance_rows(t.id('q1'), array[t.id('QI1')])), 'the family has two open invoices: QI1 owes S$109.00');
-- a part payment on ONE invoice (the way the screen sends it: the family and one invoice id)
select t.ok((pg_temp.pay(:'o1', t.id('q1'), :'h1', 'bank', 5000, 'ref-1', array[t.id('QI1')], null)->>'excess_cents')::bigint = 0, 'part payment on one invoice: nothing left over');
select t.ok(pg_temp.ps(:'o1', 'QI1') = 'part_paid', 'QI1 is now part-paid');
select t.ok((select balance_cents = 5900 from centre_balance_rows(t.id('q1'), array[t.id('QI1')])), 'QI1 still owes S$59.00');
-- an exact payment on the other invoice
select t.ok(jsonb_array_length(pg_temp.pay(:'o1', t.id('q1'), :'h1', 'manual_paynow', 5450, null, array[t.id('QI2')], null)->'allocated') = 1, 'exact payment covers QI2');
select t.ok(pg_temp.ps(:'o1', 'QI2') = 'paid', 'QI2 is paid');
-- a payment with no invoice chosen, bigger than what is owed: the extra goes to the family credit
select t.ok((pg_temp.pay(:'o1', t.id('q1'), :'h1', 'cash', 6900, null, null, null)->>'excess_cents')::bigint = 1000, 'overpayment of S$10.00 is kept as family credit, not lost');
select t.ok(pg_temp.ps(:'o1', 'QI1') = 'paid', 'QI1 is paid after the third payment');
select t.ok((select centre_credit_balance(t.id('q1'), :'h1')) = 1000, 'the family holds S$10.00 credit');
-- the same by a person who only records payments, on a different family, exact
select t.ok((pg_temp.pay(:'paym', t.id('q1'), :'h2', 'bank', 3270, null, array[t.id('QI3')], null)->>'excess_cents')::bigint = 0, 'staff with record_payments can record an exact payment');
select t.ok(pg_temp.ps(:'o1', 'QI3') = 'paid', 'QI3 is paid');
-- two payments in ONE transaction (the scratch table must be reusable inside it)
begin;
  select pg_temp.inv('QI6', t.id('q1'), :'o1', :'h4', :'s4', 1000, 0, 7);
  select pg_temp.inv('QI7', t.id('q1'), :'o1', :'h4', :'s4', 1000, 0, 7);
  select pg_temp.pay(:'o1', t.id('q1'), :'h4', 'bank', 500, null, array[t.id('QI6')], null);
  select t.ok((pg_temp.pay(:'o1', t.id('q1'), :'h4', 'bank', 500, null, array[t.id('QI7')], null)->>'amount_cents')::bigint = 500, 'two payments in one transaction both work');
commit;
\echo ALL DONE
