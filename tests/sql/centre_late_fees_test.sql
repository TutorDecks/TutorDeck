-- T4 step S6 tests: centre late fees — proposals, every value of every late-fee setting (enabled / repeat none-once-monthly / type fixed-percent / cap /
-- grace / show_as / waived_by), the grace boundary, month ends and a leap year in the centre's timezone, part payments, credit notes, a payment reversed,
-- the cap and a waived fee, settings in force on the DUE date, only lesson invoices, approve (own numbered document with GST frozen, paid like any invoice),
-- waive with a reason, idempotence (scan twice, approve twice), permissions, append-only, audit.
-- Runs after centre_refunds_test.sql in the same throwaway database (reuses the t.* helpers). All names are FAKE.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000f601', 'lf.owner@centre.test'),  ('00000000-0000-0000-0000-00000000f602', 'lf.paym@centre.test'),
  ('00000000-0000-0000-0000-00000000f603', 'lf.bill@centre.test'),   ('00000000-0000-0000-0000-00000000f604', 'lf.rev@centre.test'),
  ('00000000-0000-0000-0000-00000000f605', 'lf.tutor@centre.test'),  ('00000000-0000-0000-0000-00000000f606', 'lf.parent@centre.test'),
  ('00000000-0000-0000-0000-00000000f607', 'lf.off@centre.test'),    ('00000000-0000-0000-0000-00000000f608', 'lf.owner2@centre.test'),
  ('00000000-0000-0000-0000-00000000f609', 'lf.solo@centre.test');
\set o1 '00000000-0000-0000-0000-00000000f601'
\set paym '00000000-0000-0000-0000-00000000f602'
\set bill '00000000-0000-0000-0000-00000000f603'
\set rev '00000000-0000-0000-0000-00000000f604'
\set tut '00000000-0000-0000-0000-00000000f605'
\set par '00000000-0000-0000-0000-00000000f606'
\set off '00000000-0000-0000-0000-00000000f607'
\set o2 '00000000-0000-0000-0000-00000000f608'
\set solo '00000000-0000-0000-0000-00000000f609'

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today;
grant select on td to authenticated, anon;

-- ------------------------------------------------------------------ helpers
create function pg_temp.lf(p jsonb) returns jsonb language sql as $$     -- a late-fee rule: defaults plus what the test changes
  select '{"enabled":true,"repeat":"monthly","type":"fixed","amount_cents":1000,"percent_bp":500,"after_days":7,"cap_cents":0,"show_as":"own_invoice","waived_by":"owner"}'::jsonb || p $$;
create function pg_temp.settings(p_late jsonb, p_gst boolean) returns jsonb language sql as $$
  select jsonb_set(jsonb_set(jsonb_set(t.centre_settings(), '{profile,invoice_prefix}', '"LF"'), '{profile,gst_registered}', to_jsonb(p_gst)),
         '{billing}', jsonb_build_object('model', 'postpaid_lessons', 'late_fee', pg_temp.lf(p_late)))
         || jsonb_build_object('invoicing', jsonb_build_object('grouping', 'family', 'due_days', 7)) $$;
-- another settings version in force from a given day (settings rows are append-only; a later version is how a centre changes its rules)
create function pg_temp.rule(p_org uuid, p_from date, p_late jsonb, p_gst boolean default false) returns void language plpgsql as $$
begin
  insert into org_settings(org_id, version, schema_version, effective_from, settings)
  values (p_org, (select coalesce(max(version), 0) + 1 from org_settings where org_id = p_org), 1, p_from, pg_temp.settings(p_late, p_gst));
end $$;
-- the scan reads the centre's settings, which only a member may do: run it as that centre's owner (it is the list function that calls it in real life)
create function pg_temp.scan(p_org uuid, p_day date) returns int language plpgsql security definer as $$
declare n int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', (select user_id from memberships where org_id = p_org and role = 'owner' limit 1), 'role', 'authenticated')::text, false);
  n := centre_late_fee_scan(p_org, p_day);
  perform set_config('request.jwt.claims', '', false);
  return n;
end $$;
-- an issued invoice (any kind) with the dates the test wants; no GST; one line
create function pg_temp.inv(p_org uuid, p_hh uuid, p_stu uuid, p_kind text, p_total bigint, p_issue date, p_due date, p_imported text default null) returns uuid language plpgsql as $$
declare i uuid := gen_random_uuid();
begin
  insert into centre_invoices(id, org_id, kind, household_id, student_id, period_start, period_end, imported_number)
  values (i, p_org, p_kind, p_hh, p_stu, date_trunc('month', p_issue)::date, (date_trunc('month', p_issue) + interval '1 month - 1 day')::date, p_imported);
  insert into centre_invoice_lines(org_id, invoice_id, position, description, qty, unit_cents) values (p_org, i, 1, 'Lessons', 1, p_total);
  update centre_invoices set status = 'issued', issue_date = p_issue, due_date = p_due, net_cents = p_total, total_cents = p_total where id = i;
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
  insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents)
  select p_org, r.id, p_inv, -p.amount_cents from centre_payments r where r.reverses_payment_id = p_pay;
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
-- "m1:1000:proposed m2:1000:stopped" for an invoice
create function pg_temp.fees(p_inv uuid) returns text language sql security definer as $$
  select coalesce(string_agg('m' || month_no || ':' || fee_cents || ':' || status || ':' || fee_date, ' ' order by month_no), '') from centre_late_fees where invoice_id = p_inv $$;
create function pg_temp.nfees(p_inv uuid) returns int language sql security definer as $$ select count(*)::int from centre_late_fees where invoice_id = p_inv $$;
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
grant execute on all functions in schema pg_temp to public;

-- ------------------------------------------------------------------ the centres
-- L: where every rule is tried on made-up dates in the future (one settings version per year, so each invoice meets the rule of its due-date year).
-- M: GST-registered, rules in force now, used with the centre's real "today" for list / approve / waive / permissions.
-- N: another centre (cross-centre checks).
select t.as(:'o1'); set role authenticated;
select t.put('L', org_create_centre('Late Fee Centre L', pg_temp.settings('{}', false)));
select t.put('M', org_create_centre('Late Fee Centre M', pg_temp.settings('{}', true)));
select t.as(:'o2');
select t.put('N', org_create_centre('Late Fee Centre N', pg_temp.settings('{}', false)));
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('M'), :'paym', 'Payments Pat', 'staff', array['record_payments'], 'active'),
  (t.id('M'), :'bill', 'Billing Bea',  'staff', array['issue_invoices'], 'active'),
  (t.id('M'), :'rev',  'Revenue Rae',  'staff', array['view_revenue'], 'active'),
  (t.id('M'), :'tut',  'Tutor Tia',    'tutor', '{}', 'active'),
  (t.id('M'), :'par',  'Parent Pia',   'parent', '{}', 'active'),
  (t.id('M'), :'off',  'Switched off', 'staff', array['record_payments', 'issue_invoices'], 'disabled');
select t.put('SOLO', org_personal(:'solo'));

create function pg_temp.world(p_org text, p_n int, p_owner uuid) returns void language plpgsql as $$
declare i int; hid uuid; sid uuid;
begin
  for i in 1 .. p_n loop
    hid := gen_random_uuid(); sid := gen_random_uuid();
    insert into households(id, org_id, name) values (hid, t.id(p_org), 'Family ' || i);
    insert into students(id, tutor_id, org_id, name, household_id) values (sid, p_owner, t.id(p_org), 'Kid ' || i, hid);
    perform t.put(p_org || '_h' || i, hid); perform t.put(p_org || '_s' || i, sid);
  end loop;
end $$;
select pg_temp.world('L', 40, :'o1');
select pg_temp.world('M', 8, :'o1');
select pg_temp.world('N', 1, :'o2');
-- the invoice on family i of centre L
create function pg_temp.linv(p_i int, p_total bigint, p_issue date, p_due date, p_kind text default 'lesson') returns uuid language sql as $$
  select pg_temp.inv(t.id('L'), t.id('L_h' || p_i), t.id('L_s' || p_i), p_kind, p_total, p_issue, p_due) $$;

-- one rule per year, from 1 January of that year
select pg_temp.rule(t.id('L'), '2030-01-01', '{"repeat":"once","after_days":7}');                                     -- 2030: once, S$10.00, grace 7
select pg_temp.rule(t.id('L'), '2031-01-01', '{"repeat":"monthly","after_days":6}');                                  -- 2031: monthly, grace 6 (due 24 Jan → first fee 31 Jan)
select pg_temp.rule(t.id('L'), '2032-01-01', '{"repeat":"monthly","after_days":6}');                                  -- 2032: a leap year
select pg_temp.rule(t.id('L'), '2033-01-01', '{"repeat":"monthly","type":"percent","percent_bp":500,"after_days":6}'); -- 2033: 5% of what is still unpaid
select pg_temp.rule(t.id('L'), '2035-01-01', '{"repeat":"monthly","cap_cents":2500,"after_days":6}');                 -- 2035: at most S$25.00 per invoice
select pg_temp.rule(t.id('L'), '2036-01-01', '{"repeat":"monthly","cap_cents":2000,"after_days":6}');                 -- 2036: cap, with a waived fee
select pg_temp.rule(t.id('L'), '2037-01-01', '{"enabled":false}');                                                    -- 2037: switched off
select pg_temp.rule(t.id('L'), '2038-01-01', '{"repeat":"none"}');                                                    -- 2038: never
select pg_temp.rule(t.id('L'), '2039-01-01', '{"repeat":"monthly","show_as":"next_invoice_line","after_days":6}');    -- 2039: placement not built yet
select pg_temp.rule(t.id('L'), '2040-01-01', '{"type":"percent","percent_bp":50,"repeat":"once"}');                    -- 2040: 0.5% (rounding half up)
select pg_temp.rule(t.id('L'), '2042-01-01', '{"repeat":"monthly","after_days":0}');                                  -- 2042: no grace
select pg_temp.rule(t.id('L'), '2043-01-01', '{"repeat":"monthly","type":"percent","percent_bp":1000,"after_days":6}');-- 2043: 10%, credit notes
select pg_temp.rule(t.id('L'), '2044-01-01', '{"repeat":"monthly","after_days":6}');                                  -- 2044: paid / reversed
-- 2031-12-31 onwards the rule changes to something else: an invoice that fell due in 2030 must NOT follow it
select pg_temp.rule(t.id('L'), '2046-01-01', '{"repeat":"monthly","amount_cents":9999}');

-- ================================================================== 1. the grace boundary (rule 2030: once, grace 7)
-- due 10 Jan 2030 → paying up to and including 17 Jan is on time; the first fee falls due on 18 Jan
select pg_temp.linv(1, 20000, '2030-01-03', '2030-01-10') as i1 \gset
select t.ok(pg_temp.scan(t.id('L'), '2030-01-17') = 0 and pg_temp.nfees(:'i1') = 0, 'grace: still on time on due date + grace (17 Jan): no proposal');
select t.ok(pg_temp.scan(t.id('L'), '2030-01-18') = 1 and pg_temp.fees(:'i1') = 'm1:1000:proposed:2030-01-18', 'grace: the day after the grace ends (18 Jan) a S$10.00 fee is proposed');
select t.ok(pg_temp.scan(t.id('L'), '2030-01-18') = 0 and pg_temp.scan(t.id('L'), '2030-02-18') = 0 and pg_temp.nfees(:'i1') = 1, 'once: scanning again, even a month later, adds nothing (idempotent, and "once" is once)');
-- paid ON the last on-time day: no fee
select pg_temp.linv(2, 20000, '2030-01-03', '2030-01-10') as i2 \gset
select pg_temp.pay(t.id('L'), t.id('L_h2'), :'i2', 20000, '2030-01-17') as p2 \gset
select t.ok(pg_temp.scan(t.id('L'), '2030-03-01') >= 0 and pg_temp.nfees(:'i2') = 0, 'paying on the last on-time day (due + grace) leaves no fee');
-- paid one day too late, but before anyone looked: it was unpaid on 18 Jan, yet it is settled NOW, so nothing waits (a fee stops when the invoice is paid)
select pg_temp.linv(3, 20000, '2030-01-03', '2030-01-10') as i3 \gset
select pg_temp.pay(t.id('L'), t.id('L_h3'), :'i3', 20000, '2030-01-18') as p3 \gset
select t.ok(pg_temp.scan(t.id('L'), '2030-03-01') >= 0 and pg_temp.nfees(:'i3') = 0, 'an invoice settled before the scan has no waiting fee');
-- a proposal made while it was unpaid STOPS when the invoice is then paid, and comes back if that payment is reversed
select pg_temp.linv(4, 20000, '2030-01-03', '2030-01-10') as i4 \gset
select t.ok(pg_temp.scan(t.id('L'), '2030-01-20') = 1 and pg_temp.fees(:'i4') = 'm1:1000:proposed:2030-01-18', 'proposal made while unpaid');
select pg_temp.pay(t.id('L'), t.id('L_h4'), :'i4', 20000, '2030-01-21') as p4 \gset
select t.ok(pg_temp.scan(t.id('L'), '2030-01-22') = 0 and pg_temp.fees(:'i4') = 'm1:1000:stopped:2030-01-18', 'paid in full: the waiting proposal stops');
select pg_temp.unpay(t.id('L'), :'p4', :'i4', '2030-01-25');
select t.ok(pg_temp.scan(t.id('L'), '2030-01-26') = 0 and pg_temp.fees(:'i4') = 'm1:1000:proposed:2030-01-18', 'payment reversed: the proposal is back');
-- the rule in force on the DUE date decides, not the rule of today: due 20 Dec 2030 (once) stays once while 2031 is monthly
select pg_temp.linv(5, 20000, '2030-12-10', '2030-12-20') as i5 \gset
select pg_temp.scan(t.id('L'), '2031-06-30');
select t.ok(pg_temp.fees(:'i5') = 'm1:1000:proposed:2030-12-28', 'money rule follows the settings in force when the invoice fell due: a 2030 invoice is "once" even in 2031');
select t.ok(pg_temp.nfees(:'i5') = 1, 'one fee only, though the invoice stayed unpaid for six more months under a monthly rule');

-- ================================================================== 2. monthly: the same day each month; month ends; a leap year (rule 2031/2032: monthly, grace 6)
select pg_temp.linv(6, 20000, '2031-01-10', '2031-01-24') as i6 \gset
select pg_temp.scan(t.id('L'), '2031-01-30');
select t.ok(pg_temp.nfees(:'i6') = 0, 'monthly: nothing on 30 Jan (grace ends on the 30th)');
select pg_temp.scan(t.id('L'), '2031-02-27');
select t.ok(pg_temp.fees(:'i6') = 'm1:1000:proposed:2031-01-31', 'monthly: first fee on 31 Jan; none yet on 27 Feb');
select pg_temp.scan(t.id('L'), '2031-02-28');
select t.ok(pg_temp.fees(:'i6') = 'm1:1000:proposed:2031-01-31 m2:1000:proposed:2031-02-28', 'month end: the 31st clamps to 28 Feb 2031 (not 3 Mar)');
select pg_temp.scan(t.id('L'), '2031-03-30');
select t.ok(pg_temp.nfees(:'i6') = 2, 'month end: no third fee on 30 Mar');
select pg_temp.scan(t.id('L'), '2031-03-31');
select pg_temp.scan(t.id('L'), '2031-04-29');
select t.ok(pg_temp.nfees(:'i6') = 3 and pg_temp.fees(:'i6') like '%m3:1000:proposed:2031-03-31', 'month end: the third fee is back on the 31st (31 Mar), it did not drift to the 28th');
select pg_temp.scan(t.id('L'), '2031-04-30');
select t.ok(pg_temp.fees(:'i6') like '%m4:1000:proposed:2031-04-30', 'month end: fourth fee on 30 Apr (the last day of a 30-day month)');
-- a scan that was not run for a while catches up, once per month, never twice
select pg_temp.linv(7, 20000, '2031-01-10', '2031-01-24') as i7 \gset
select t.ok(pg_temp.scan(t.id('L'), '2031-06-30') >= 5 and pg_temp.fees(:'i7') = 'm1:1000:proposed:2031-01-31 m2:1000:proposed:2031-02-28 m3:1000:proposed:2031-03-31 m4:1000:proposed:2031-04-30 m5:1000:proposed:2031-05-31 m6:1000:proposed:2031-06-30',
            'a late scan catches up all six months in one go');
select t.ok(pg_temp.scan(t.id('L'), '2031-06-30') = 0 and pg_temp.nfees(:'i7') = 6, 'scanning twice never doubles anything');
-- leap year
select pg_temp.linv(8, 20000, '2032-01-10', '2032-01-24') as i8 \gset
select pg_temp.scan(t.id('L'), '2032-02-28');
select t.ok(pg_temp.nfees(:'i8') = 1, 'leap year: no second fee on 28 Feb 2032');
select pg_temp.scan(t.id('L'), '2032-02-29');
select t.ok(pg_temp.fees(:'i8') = 'm1:1000:proposed:2032-01-31 m2:1000:proposed:2032-02-29', 'leap year: second fee on 29 Feb 2032');
-- a family paying part way: fees follow the months it was unpaid
select pg_temp.linv(9, 20000, '2031-01-10', '2031-01-24') as i9 \gset
select pg_temp.pay(t.id('L'), t.id('L_h9'), :'i9', 20000, '2031-03-10') as p9 \gset
select t.ok(pg_temp.scan(t.id('L'), '2031-06-30') >= 0 and pg_temp.nfees(:'i9') = 0, 'paid in full before the scan: no fees at all (stops when paid)');

-- ================================================================== 3. percent of the UNPAID balance (rule 2033), part payments, credit notes
select pg_temp.linv(10, 20000, '2033-01-10', '2033-01-24') as i10 \gset
select pg_temp.pay(t.id('L'), t.id('L_h10'), :'i10', 5000, '2033-01-20');                                          -- S$50.00 paid on time: S$150.00 still unpaid
select pg_temp.scan(t.id('L'), '2033-01-31');
select t.ok(pg_temp.fees(:'i10') = 'm1:750:proposed:2033-01-31', 'percent: 5% of the S$150.00 still unpaid = S$7.50 (not of the whole S$200.00)');
select t.ok((select base_cents from centre_late_fees where invoice_id = :'i10' and month_no = 1) = 15000, 'percent: the unpaid balance used is kept on the proposal');
select pg_temp.pay(t.id('L'), t.id('L_h10'), :'i10', 5000, '2033-02-10');                                          -- another S$50.00 before the second fee
select pg_temp.scan(t.id('L'), '2033-02-28');
select t.ok(pg_temp.fees(:'i10') = 'm1:750:proposed:2033-01-31 m2:500:proposed:2033-02-28', 'percent: month 2 is 5% of the S$100.00 then unpaid = S$5.00; month 1 stays as proposed');
-- fixed fee on a part-paid invoice stays flat
select pg_temp.linv(11, 20000, '2031-01-10', '2031-01-24') as i11 \gset
select pg_temp.pay(t.id('L'), t.id('L_h11'), :'i11', 15000, '2031-01-20');
select pg_temp.scan(t.id('L'), '2031-01-31');
select t.ok(pg_temp.fees(:'i11') = 'm1:1000:proposed:2031-01-31', 'fixed: a part-paid invoice is charged the flat amount');
-- percent rounding: 0.5% of S$101.00 = S$0.505 → half up to S$0.51 (rule 2040, once, grace 7)
select pg_temp.linv(12, 10100, '2040-01-01', '2040-01-10') as i12 \gset
select pg_temp.scan(t.id('L'), '2040-01-18');
select t.ok(pg_temp.fees(:'i12') = 'm1:51:proposed:2040-01-18', 'percent: 0.5% of S$101.00 = 50.5 cents rounds half up to 51');
-- a credit note reduces the balance the percentage is taken on (credit issued before the fee date); one issued after doesn't
select pg_temp.linv(13, 20000, '2043-01-10', '2043-01-24') as i13 \gset
select pg_temp.credit(t.id('L'), :'i13', 5000, '2043-01-28');                                                        -- credit before 31 Jan
select pg_temp.scan(t.id('L'), '2043-01-31');
select t.ok(pg_temp.fees(:'i13') = 'm1:1500:proposed:2043-01-31', 'credit note: 10% of S$150.00 (S$200.00 less the S$50.00 credit) = S$15.00');
select pg_temp.credit(t.id('L'), :'i13', 5000, '2043-03-20');                                                       -- a second credit, after the 28 Feb fee date
select pg_temp.scan(t.id('L'), '2043-02-28');
select t.ok(pg_temp.fees(:'i13') = 'm1:1500:proposed:2043-01-31 m2:1500:proposed:2043-02-28', 'credit note issued later does not change an earlier month');
select pg_temp.scan(t.id('L'), '2043-03-31');
select t.ok(pg_temp.fees(:'i13') like '%m3:1000:proposed:2043-03-31', 'credit note: month 3 is 10% of the S$100.00 then owed');
-- an invoice credited in full: nothing, and a waiting proposal stops
select pg_temp.linv(14, 20000, '2043-01-10', '2043-01-24') as i14 \gset
select pg_temp.scan(t.id('L'), '2043-01-31');
select t.ok(pg_temp.fees(:'i14') = 'm1:2000:proposed:2043-01-31', 'before the credit: 10% of S$200.00');
select pg_temp.credit(t.id('L'), :'i14', 20000, '2043-02-03');
select pg_temp.scan(t.id('L'), '2043-02-28');
select t.ok(pg_temp.fees(:'i14') = 'm1:2000:stopped:2043-01-31', 'credited in full: the waiting proposal stops and no month 2 is made');

-- ================================================================== 4. the cap (rule 2035: monthly S$10.00, at most S$25.00 per invoice)
select pg_temp.linv(15, 20000, '2035-01-10', '2035-01-24') as i15 \gset
select pg_temp.scan(t.id('L'), '2035-05-31');
select t.ok(pg_temp.fees(:'i15') = 'm1:1000:proposed:2035-01-31 m2:1000:proposed:2035-02-28 m3:500:proposed:2035-03-31', 'cap: S$10 + S$10 + S$5.00 (cut to what is left of S$25.00), then no more');
select t.ok((select sum(fee_cents) from centre_late_fees where invoice_id = :'i15') = 2500, 'cap: the total never passes the limit');
-- waived fees don't use up the cap (rule 2036: cap S$20.00)
select pg_temp.linv(16, 20000, '2036-01-10', '2036-01-24') as i16 \gset
select pg_temp.scan(t.id('L'), '2036-01-31');
update centre_late_fees set status = 'waived', reason = 'Family hardship', decided_at = now() where invoice_id = :'i16' and month_no = 1;
select pg_temp.scan(t.id('L'), '2036-04-30');
select t.ok(pg_temp.fees(:'i16') = 'm1:1000:waived:2036-01-31 m2:1000:proposed:2036-02-29 m3:1000:proposed:2036-03-31', 'cap: a waived fee collected nothing, so S$20.00 is still available (two more fees, then the cap is reached)');

-- ================================================================== 5. switched off / never / placement not built
select pg_temp.linv(17, 20000, '2037-01-10', '2037-01-24') as i17 \gset
select pg_temp.linv(18, 20000, '2038-01-10', '2038-01-24') as i18 \gset
select pg_temp.linv(19, 20000, '2039-01-10', '2039-01-24') as i19 \gset
select pg_temp.scan(t.id('L'), '2037-06-30'); select pg_temp.scan(t.id('L'), '2038-06-30'); select pg_temp.scan(t.id('L'), '2039-03-31');
select t.ok(pg_temp.nfees(:'i17') = 0, 'enabled = false: no proposals');
select t.ok(pg_temp.nfees(:'i18') = 0, 'repeat = none: no proposals');
select t.ok(pg_temp.nfees(:'i19') = 3, 'show_as next_invoice_line (not built): proposals are still made, each will be its own invoice');
select pg_temp.linv(20, 20000, '2042-01-10', '2042-01-24') as i20 \gset
select pg_temp.scan(t.id('L'), '2042-01-24');
select t.ok(pg_temp.nfees(:'i20') = 0, 'grace 0: paying on the due date is on time');
select pg_temp.scan(t.id('L'), '2042-01-25');
select t.ok(pg_temp.fees(:'i20') = 'm1:1000:proposed:2042-01-25', 'grace 0: the first fee falls due the very next day');

-- ================================================================== 6. only LESSON invoices; a late fee never gets a late fee
select pg_temp.inv(t.id('L'), t.id('L_h21'), t.id('L_s21'), 'deposit', 30000, '2044-01-03', '2044-01-10') as d1 \gset
select pg_temp.inv(t.id('L'), t.id('L_h22'), t.id('L_s22'), 'opening', 30000, '2044-01-03', '2044-01-10', 'OLD-77') as op1 \gset
select pg_temp.inv(t.id('L'), t.id('L_h23'), t.id('L_s23'), 'late_fee', 1000, '2044-01-03', '2044-01-10') as l1 \gset
select pg_temp.scan(t.id('L'), '2044-12-31');
select t.ok(pg_temp.nfees(:'d1') = 0, 'a deposit invoice never gets a late fee');
select t.ok(pg_temp.nfees(:'op1') = 0, 'an opening invoice (carried over from old books) never gets a late fee');
select t.ok(pg_temp.nfees(:'l1') = 0, 'a late-fee document never gets a late fee (no compounding)');
select pg_temp.inv(t.id('L'), t.id('L_h24'), t.id('L_s24'), 'lesson', 20000, '2044-01-03', '2044-01-10') as j1 \gset
select t.ok(pg_temp.scan(t.id('L'), '2044-01-18') = 1 and pg_temp.nfees(:'j1') = 1, 'the same dates on a lesson invoice do get one');
select t.ok(not exists (select 1 from centre_late_fees where invoice_id in (select id from centre_invoices where status <> 'issued')), 'drafts never get a fee');
-- a draft invoice: not scanned
insert into centre_invoices(id, org_id, kind, household_id, due_date) values ('00000000-0000-0000-0000-00000000f6d1', t.id('L'), 'lesson', t.id('L_h25'), '2044-01-10');
select pg_temp.scan(t.id('L'), '2044-06-30');
select t.ok(pg_temp.nfees('00000000-0000-0000-0000-00000000f6d1') = 0, 'a draft invoice (no number, not issued) is never charged');
select t.ok(pg_temp.scan(t.id('SOLO'), '2044-06-30') = 0 and pg_temp.scan(t.id('N'), '2044-06-30') = 0, 'a solo organisation and a centre with no invoices: the scan makes nothing');

-- ================================================================== 7. REAL TODAY: list, approve, waive, permissions (centre M: GST 9%, monthly S$10.00, grace 7, owner waives)
select pg_temp.rule(t.id('M'), '2026-01-01', '{}', true);       -- (the same rule applies to invoices that fell due before today)
select (select today from td) as today \gset
select pg_temp.inv(t.id('M'), t.id('M_h1'), t.id('M_s1'), 'lesson', 20000, :'today'::date - 40, :'today'::date - 20) as ia \gset
select pg_temp.inv(t.id('M'), t.id('M_h2'), t.id('M_s2'), 'lesson', 20000, :'today'::date - 70, :'today'::date - 50) as ib \gset
select pg_temp.inv(t.id('M'), t.id('M_h3'), t.id('M_s3'), 'lesson', 20000, :'today'::date - 15, :'today'::date - 5)  as ic \gset
select pg_temp.inv(t.id('M'), t.id('M_h4'), t.id('M_s4'), 'lesson', 20000, :'today'::date - 20, :'today'::date - 8)  as id_ \gset
select pg_temp.inv(t.id('M'), t.id('M_h5'), t.id('M_s5'), 'lesson', 20000, :'today'::date - 20, :'today'::date - 7)  as ie \gset
select pg_temp.inv(t.id('M'), t.id('M_h6'), t.id('M_s6'), 'deposit', 20000, :'today'::date - 60, :'today'::date - 40) as idp \gset
-- the screens' list: a door for people with issue_invoices only
select pg_temp.refused(:'paym', format($q$select centre_late_fee_list(%L)$q$, t.id('M')), 'NOT_ALLOWED', 'staff with only record_payments can''t open Late fees');
select pg_temp.refused(:'rev',  format($q$select centre_late_fee_list(%L)$q$, t.id('M')), 'NOT_ALLOWED', 'view_revenue alone can''t open Late fees');
select pg_temp.refused(:'tut',  format($q$select centre_late_fee_list(%L)$q$, t.id('M')), 'NOT_FOUND', 'a tutor gets nothing');
select pg_temp.refused(:'par',  format($q$select centre_late_fee_list(%L)$q$, t.id('M')), 'NOT_FOUND', 'a parent gets nothing');
select pg_temp.refused(:'off',  format($q$select centre_late_fee_list(%L)$q$, t.id('M')), 'NOT_FOUND', 'switched-off staff get nothing');
select pg_temp.refused(:'solo', format($q$select centre_late_fee_list(%L)$q$, t.id('M')), 'NOT_FOUND', 'a stranger gets nothing');
select pg_temp.refused(:'o2',   format($q$select centre_late_fee_list(%L)$q$, t.id('M')), 'NOT_FOUND', 'another centre''s owner gets nothing');
select pg_temp.refused('',      format($q$select centre_late_fee_list(%L)$q$, t.id('M')), 'permission denied', 'anonymous can''t call it');
select pg_temp.refused(:'solo', format($q$select centre_late_fee_list(%L)$q$, t.id('SOLO')), 'NOT_FOUND', 'solo organisations have no late fees');
select pg_temp.call(:'bill', format($q$select centre_late_fee_list(%L)$q$, t.id('M'))) as lst \gset
select t.ok((:'lst'::jsonb->>'waiting_count')::int = 4, 'list: four fees are waiting (A once, B twice, D today); C and E are inside the grace; the deposit is never charged');
select t.ok(pg_temp.nfees(:'idp') = 0 and pg_temp.nfees(:'ic') = 0 and pg_temp.nfees(:'ie') = 0, 'grace boundary at the real today: due−7 gets none, due−8 gets one');
select t.ok(pg_temp.nfees(:'id_') = 1 and pg_temp.nfees(:'ib') = 2 and pg_temp.nfees(:'ia') = 1, 'A one fee, B two, D one');
select t.ok((:'lst'::jsonb->>'waiting_cents')::bigint = 4000, 'list: S$40.00 waiting in total (4 × S$10.00)');
select t.ok((select (w->>'gst_cents')::int = 90 and (w->>'total_cents')::int = 1090 from jsonb_array_elements(:'lst'::jsonb->'waiting') w limit 1), 'list: GST 9% shown on each proposal (S$0.90, S$10.90 in all)');
select t.ok((:'lst'::jsonb->'can'->>'waive')::boolean = false and (:'lst'::jsonb->'can'->>'waived_by') = 'owner', 'list: staff who issue invoices can''t waive when the centre says owner only');
select t.ok((select pg_temp.call(:'o1', format($q$select centre_late_fee_list(%L)$q$, t.id('M')))->'can'->>'waive')::boolean, 'list: the owner can');
select t.ok(pg_temp.call(:'bill', format($q$select centre_late_fee_list(%L)$q$, t.id('M')))->>'note' is null, 'list: no note when everything is built');
-- the invoice detail's fees
select t.ok(jsonb_array_length(pg_temp.call(:'bill', format($q$select centre_late_fee_invoice_get(%L)$q$, :'ib'))) = 2, 'one invoice''s fees: both months of B');
select pg_temp.refused(:'paym', format($q$select centre_late_fee_invoice_get(%L)$q$, :'ib'), 'NOT_ALLOWED', 'the per-invoice list needs issue_invoices too');

-- approving
select id as fa from centre_late_fees where invoice_id = :'ia' and month_no = 1 \gset
select pg_temp.refused(:'paym', format($q$select centre_late_fee_approve(%L)$q$, :'fa'), 'NOT_ALLOWED', 'record_payments alone can''t approve');
select pg_temp.refused(:'tut',  format($q$select centre_late_fee_approve(%L)$q$, :'fa'), 'NOT_FOUND', 'a tutor can''t approve');
select pg_temp.refused(:'o2',   format($q$select centre_late_fee_approve(%L)$q$, :'fa'), 'NOT_FOUND', 'another centre''s owner can''t approve');
select pg_temp.refused('',      format($q$select centre_late_fee_approve(%L)$q$, :'fa'), 'permission denied', 'anonymous can''t approve');
select max(number_seq) as last_seq from centre_invoices where org_id = t.id('M') and series = 'invoice' \gset
select pg_temp.call(:'bill', format($q$select centre_late_fee_approve(%L)$q$, :'fa')) as ap1 \gset
select t.ok((:'ap1'::jsonb->>'already')::boolean = false and (:'ap1'::jsonb->>'total_cents')::int = 1090 and (:'ap1'::jsonb->>'gst_cents')::int = 90, 'approve: S$10.00 + 9% GST = S$10.90');
select t.ok((select kind = 'late_fee' and status = 'issued' and number_seq = :'last_seq'::int + 1 and number_text = 'LF-' || (:'last_seq'::int + 1) and gst_registered and gst_rate_bp = 900
                    and net_cents = 1000 and gst_cents = 90 and total_cents = 1090 and household_id = t.id('M_h1') and due_date = :'today'::date + 7 and issue_date = :'today'::date
               from centre_invoices where id = (:'ap1'::jsonb->>'document_id')::uuid), 'approve: its own issued document in the shared invoice series (next number), GST frozen, due in 7 days, on the family');
select t.ok((select count(*) = 1 and bool_and(fee_kind = 'late_fee') and sum(line_cents) = 1000 from centre_invoice_lines where invoice_id = (:'ap1'::jsonb->>'document_id')::uuid), 'approve: one line "Late fee" of S$10.00');
select t.ok((select description like 'Late fee: invoice INV-%' from centre_invoice_lines where invoice_id = (:'ap1'::jsonb->>'document_id')::uuid), 'approve: the line names the invoice it is for');
select t.ok((select status = 'approved' and document_id = (:'ap1'::jsonb->>'document_id')::uuid and decided_by = :'bill' from centre_late_fees where id = :'fa'), 'approve: the proposal records who and which document');
-- pressing approve twice: the same document, nothing new
select count(*) as n_docs_before from centre_invoices where org_id = t.id('M') and kind = 'late_fee' \gset
select pg_temp.call(:'bill', format($q$select centre_late_fee_approve(%L)$q$, :'fa')) as ap2 \gset
select t.ok((:'ap2'::jsonb->>'already')::boolean and (:'ap2'::jsonb->>'document_id') = (:'ap1'::jsonb->>'document_id')
        and (select count(*) from centre_invoices where org_id = t.id('M') and kind = 'late_fee') = :'n_docs_before'::int, 'approve twice: the same document comes back, no second invoice');
-- it is on the family's account: the Money > Invoices list shows it and a payment pays it
select t.ok((select count(*) = 1 from jsonb_array_elements(pg_temp.call(:'bill', format($q$select centre_invoice_account_list(%L)$q$, t.id('M')))->'rows') r
              where r->>'kind' = 'late_fee' and (r->>'balance_cents')::int = 1090), 'the Money > Invoices list shows the late-fee document with its S$10.90 balance');
select pg_temp.call(:'o1', format($q$select centre_record_payment(%L, %L, 'cash', 1090, %L, null, array[%L]::uuid[], null, null)$q$, t.id('M'), t.id('M_h1'), :'today', (:'ap1'::jsonb->>'document_id')))
  as pay1 \gset
select t.ok((select balance_cents = 0 from centre_balance_rows(t.id('M'), array[(:'ap1'::jsonb->>'document_id')::uuid])), 'a payment can pay the late fee, like any invoice');
-- paying the family's invoice with no invoices chosen (oldest first) covers the invoice before the late fee on it
select pg_temp.call(:'o1', format($q$select centre_record_payment(%L, %L, 'cash', 5000, %L, null, null, null, null)$q$, t.id('M'), t.id('M_h1'), :'today')) as pay2 \gset
select t.ok((select balance_cents = 15000 from centre_balance_rows(t.id('M'), array[:'ia'::uuid])), 'oldest first: a payment with no invoice chosen goes to the lesson invoice');
-- month 2 of B approved later in bulk; approve all
select pg_temp.refused(:'paym', format($q$select centre_late_fee_approve_all(%L)$q$, t.id('M')), 'NOT_ALLOWED', 'approve all needs issue_invoices');
select pg_temp.call(:'bill', format($q$select centre_late_fee_approve_all(%L)$q$, t.id('M'))) as aa \gset
select t.ok((:'aa'::jsonb->>'approved')::int = 3 and (:'aa'::jsonb->>'skipped')::int = 0 and (:'aa'::jsonb->>'total_cents')::int = 3270, 'approve all: the three remaining fees (B twice, D) become documents, S$32.70 with GST');
select t.ok((select count(*) = 4 from centre_invoices where org_id = t.id('M') and kind = 'late_fee'), 'approve all: four late-fee documents in all (1 + 3)');
select pg_temp.call(:'bill', format($q$select centre_late_fee_approve_all(%L)$q$, t.id('M'))) as aa2 \gset
select t.ok((:'aa2'::jsonb->>'approved')::int = 0 and (select count(*) = 4 from centre_invoices where org_id = t.id('M') and kind = 'late_fee'), 'approve all twice: nothing more is created');
select t.ok((select count(distinct number_seq) = count(*) from centre_invoices where org_id = t.id('M') and series = 'invoice' and status = 'issued'), 'every document keeps a distinct number: one gap-free series');
select t.ok((select max(number_seq) - min(number_seq) + 1 = count(*) from centre_invoices where org_id = t.id('M') and series = 'invoice' and status = 'issued'), 'the invoice numbers have no gaps after the late fees');

-- waiting count falls
select t.ok((pg_temp.call(:'bill', format($q$select centre_late_fee_list(%L)$q$, t.id('M')))->>'waiting_count')::int = 0, 'nothing waits after approving everything');
select t.ok(jsonb_array_length(pg_temp.call(:'bill', format($q$select centre_late_fee_list(%L)$q$, t.id('M')))->'recent') = 4, 'recent decisions list the four approved fees');

-- waiving: a new family so the fee is waiting; the rule is the centre's; a reason is required
select pg_temp.inv(t.id('M'), t.id('M_h7'), t.id('M_s7'), 'lesson', 20000, :'today'::date - 40, :'today'::date - 20) as iw \gset
select pg_temp.inv(t.id('M'), t.id('M_h8'), t.id('M_s8'), 'lesson', 20000, :'today'::date - 40, :'today'::date - 20) as iw2 \gset
select pg_temp.call(:'bill', format($q$select centre_late_fee_list(%L)$q$, t.id('M'))) as lst2 \gset
select id as fw from centre_late_fees where invoice_id = :'iw' \gset
select id as fw2 from centre_late_fees where invoice_id = :'iw2' \gset
select pg_temp.refused(:'bill', format($q$select centre_late_fee_waive(%L, 'Family hardship')$q$, :'fw'), 'NOT_ALLOWED: only the centre owner', 'waived_by = owner: staff who issue invoices can''t waive');
select pg_temp.refused(:'o1', format($q$select centre_late_fee_waive(%L, '   ')$q$, :'fw'), 'REASON_REQUIRED', 'waive needs a reason');
select pg_temp.refused(:'o1', format($q$select centre_late_fee_waive(%L, null)$q$, :'fw'), 'REASON_REQUIRED', 'waive needs a reason (null)');
select pg_temp.refused(:'o1', format($q$select centre_late_fee_waive(%L, %L)$q$, :'fw', repeat('x', 301)), 'TOO_LONG', 'the reason is kept short');
select pg_temp.refused(:'paym', format($q$select centre_late_fee_waive(%L, 'x')$q$, :'fw'), 'NOT_ALLOWED', 'record_payments alone can''t waive');
select pg_temp.refused(:'tut', format($q$select centre_late_fee_waive(%L, 'x')$q$, :'fw'), 'NOT_FOUND', 'a tutor can''t waive');
select pg_temp.refused('', format($q$select centre_late_fee_waive(%L, 'x')$q$, :'fw'), 'permission denied', 'anonymous can''t waive');
select pg_temp.call(:'o1', format($q$select centre_late_fee_waive(%L, 'Family hardship')$q$, :'fw')) as w1 \gset
select t.ok((:'w1'::jsonb->>'status') = 'waived' and (select status = 'waived' and reason = 'Family hardship' and decided_by = :'o1' and document_id is null from centre_late_fees where id = :'fw'), 'the owner waives with a reason: no document is made');
select t.ok((pg_temp.call(:'o1', format($q$select centre_late_fee_waive(%L, 'again')$q$, :'fw'))->>'already')::boolean, 'waive twice: still waived, no error, nothing doubled');
select pg_temp.refused(:'bill', format($q$select centre_late_fee_approve(%L)$q$, :'fw'), 'NOT_ALLOWED: this late fee was waived', 'a waived fee can''t be approved');
select pg_temp.refused(:'o1', format($q$select centre_late_fee_waive(%L, 'too late')$q$, :'fa'), 'NOT_ALLOWED: this late fee is already on the family', 'an approved fee can''t be waived (a credit note takes it off)');
select t.ok(pg_temp.scan(t.id('M'), :'today'::date) = 0 and (select status from centre_late_fees where id = :'fw') = 'waived', 'a waived fee is not proposed again by the next scan');
-- waived_by = issue_invoices (read as of today)
select pg_temp.rule(t.id('M'), :'today'::date, '{"waived_by":"issue_invoices"}', true);
select t.ok((pg_temp.call(:'bill', format($q$select centre_late_fee_list(%L)$q$, t.id('M')))->'can'->>'waive')::boolean, 'waived_by = issue_invoices: staff who issue invoices can waive');
select pg_temp.refused(:'paym', format($q$select centre_late_fee_waive(%L, 'x')$q$, :'fw2'), 'NOT_ALLOWED', 'waived_by = issue_invoices: record_payments alone still can''t');
select pg_temp.call(:'bill', format($q$select centre_late_fee_waive(%L, 'Sibling discount agreed')$q$, :'fw2')) as w2 \gset
select t.ok((:'w2'::jsonb->>'status') = 'waived', 'waived_by = issue_invoices: Billing Bea waives with a reason');
select t.ok((select count(*) = 2 from jsonb_array_elements(pg_temp.call(:'bill', format($q$select centre_late_fee_list(%L)$q$, t.id('M')))->'recent') r where r->>'status' = 'waived'), 'recent decisions show both waived fees with their reasons');
select t.ok(pg_temp.call(:'bill', format($q$select centre_late_fee_list(%L)$q$, t.id('M')))::text like '%Sibling discount agreed%', 'the waive reason is shown to the people who may decide');

-- an invoice paid before approval: the proposal can't be approved any more
select pg_temp.inv(t.id('M'), t.id('M_h6'), t.id('M_s6'), 'lesson', 20000, :'today'::date - 40, :'today'::date - 20) as is1 \gset
select pg_temp.call(:'bill', format($q$select centre_late_fee_list(%L)$q$, t.id('M'))) as lst3 \gset
select id as fs from centre_late_fees where invoice_id = :'is1' \gset
select pg_temp.pay(t.id('M'), t.id('M_h6'), :'is1', 20000, :'today'::date);
select pg_temp.refused(:'bill', format($q$select centre_late_fee_approve(%L)$q$, :'fs'), 'INVOICE_SETTLED', 'approving a fee whose invoice has since been paid is refused');
select pg_temp.call(:'bill', format($q$select centre_late_fee_list(%L)$q$, t.id('M'))) as lst4 \gset
select t.ok((select status = 'stopped' from centre_late_fees where id = :'fs') and (:'lst4'::jsonb->>'waiting_count')::int = 0, 'and the next list shows it stopped, nothing waiting');

-- ================================================================== 8. a note when the setting asks for something not built, and when switched off
select t.ok(centre_late_fee_note(pg_temp.settings('{"show_as":"next_invoice_line"}', false)) like '%not built yet%', 'note: placement option not built is said plainly');
select t.ok(centre_late_fee_note(pg_temp.settings('{"enabled":false}', false)) like '%switched off%', 'note: switched off is said plainly');
select t.ok(centre_late_fee_note(pg_temp.settings('{"repeat":"none"}', false)) like '%never%', 'note: repeat none is said plainly');
select t.ok(centre_late_fee_note(pg_temp.settings('{}', false)) is null, 'note: nothing to say when all is built');

-- ================================================================== 9. nobody writes the table from a browser; append-only; audit; delete the centre
select pg_temp.refused(:'o1', format($q$update centre_late_fees set status = 'waived' where id = %L$q$, :'fa'), 'permission denied', 'no browser can update a late fee');
select pg_temp.refused(:'o1', format($q$insert into centre_late_fees(org_id, invoice_id, month_no, fee_date, fee_cents, rule) values (%L, %L, 9, current_date, 5, '{}')$q$, t.id('M'), :'ia'), 'permission denied', 'no browser can insert a late fee');
select pg_temp.refused(:'o1', format($q$delete from centre_late_fees where id = %L$q$, :'fa'), 'permission denied', 'no browser can delete a late fee');
select t.fails(format($q$update centre_late_fees set fee_cents = 1 where id = %L$q$, :'fa'), 'an approved fee''s amount can''t change');
select t.fails(format($q$update centre_late_fees set status = 'proposed', document_id = null where id = %L$q$, :'fa'), 'an approved fee can''t go back');
select t.fails(format($q$update centre_late_fees set status = 'approved', document_id = %L, decided_at = now() where id = %L$q$, :'ia', :'fw'), 'a waived fee can''t be approved by a direct update');
select t.fails(format($q$delete from centre_late_fees where id = %L$q$, :'fa'), 'a late fee can''t be deleted');
select t.fails(format($q$insert into centre_late_fees(org_id, invoice_id, month_no, fee_date, fee_cents, rule) values (%L, %L, 1, current_date, 5, '{}')$q$, t.id('M'), :'ia'), 'one fee per invoice and month: a duplicate is refused');
select t.fails(format($q$insert into centre_late_fees(org_id, invoice_id, month_no, fee_date, fee_cents, rule, status) values (%L, %L, 8, current_date, 5, '{}', 'approved')$q$, t.id('M'), :'ia'), 'a fee can''t start approved');
select t.fails(format($q$insert into centre_late_fees(org_id, invoice_id, month_no, fee_date, fee_cents, rule) values (%L, %L, 8, current_date, 5, '{}')$q$, t.id('M'), :'idp'), 'a fee can''t be put on a deposit invoice by hand either');
select t.fails(format($q$insert into centre_late_fees(org_id, invoice_id, month_no, fee_date, fee_cents, rule) values (%L, %L, 1, current_date, 5, '{}')$q$, t.id('N'), :'ia'), 'a fee can''t point at another centre''s invoice');
select t.ok((select count(*) >= 1 from audit_log where table_name = 'centre_late_fees' and action = 'insert' and org_id = t.id('M')), 'audit: every proposal is in the audit log');
select t.ok((select count(*) = 1 from audit_log where action = 'centre_late_fee_approve' and row_id = :'fa'), 'audit: a summary row for the approval');
select t.ok((select count(*) >= 2 from audit_log where action = 'centre_late_fee_waive' and org_id = t.id('M')), 'audit: a summary row for each waiver');
select t.ok(not exists (select 1 from audit_log where table_name = 'centre_late_fees' and (after::text like '%Family hardship%' or after::text like '%Sibling discount agreed%')), 'audit: the waive reason is redacted (free text can hold names)');
select t.ok((select after->>'reason' = '[redacted]' from audit_log where table_name = 'centre_late_fees' and action = 'update' and after->>'status' = 'waived' order by at desc limit 1), 'audit: the redaction marker is there instead');
select t.ok(not exists (select 1 from audit_log where action like 'centre_late_fee_%' and (after::text ~* 'hardship|discount agreed')), 'audit: the summary rows carry amounts and counts only');
-- read policy: only people who can issue invoices
create function pg_temp.cnt(p_user text) returns bigint language plpgsql as $$
declare n bigint;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  perform set_config('role', 'authenticated', true);
  select count(*) into n from centre_late_fees;
  perform set_config('role', 'postgres', true);
  return n;
end $$;
grant execute on function pg_temp.cnt(text) to public;
select t.ok(pg_temp.cnt(:'bill') > 0 and pg_temp.cnt(:'o1') > 0, 'staff who issue invoices and the owner can read the table');
select t.ok(pg_temp.cnt(:'paym') = 0 and pg_temp.cnt(:'rev') = 0 and pg_temp.cnt(:'tut') = 0 and pg_temp.cnt(:'par') = 0 and pg_temp.cnt(:'off') = 0 and pg_temp.cnt(:'solo') = 0 and pg_temp.cnt(:'o2') = 0,
            'payments-only, revenue-only, tutor, parent, switched-off staff, a solo owner and another centre''s owner read no late fee');
