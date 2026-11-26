-- T4 step S1 tests: centre money tables (documents, lines, payments, allocations, numbering, GST function, access, audit).
-- Runs after staff_timetable_test.sql in the same throwaway database (reuses the t.* helpers). Builds its own centres and made-up people.
-- Run from the repository root (it reads tests/gst-vectors.csv, the same file tests/money.test.js uses).
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000b901', 'cm.owner@centre.test'),  ('00000000-0000-0000-0000-00000000b902', 'cm.invoices@centre.test'),
  ('00000000-0000-0000-0000-00000000b903', 'cm.payments@centre.test'), ('00000000-0000-0000-0000-00000000b904', 'cm.revenue@centre.test'),
  ('00000000-0000-0000-0000-00000000b905', 'cm.tutor@centre.test'),   ('00000000-0000-0000-0000-00000000b906', 'cm.parent@centre.test'),
  ('00000000-0000-0000-0000-00000000b907', 'cm.owner2@centre.test'),  ('00000000-0000-0000-0000-00000000b908', 'cm.off@centre.test'),
  ('00000000-0000-0000-0000-00000000b909', 'cm.stranger@centre.test'), ('00000000-0000-0000-0000-00000000b90a', 'cm.nobody@centre.test');

-- centre 1: GST registered, 9%, prices exclude GST, prefix TEST.  centre 2: other centre, not registered, own prefix.
set role authenticated; select t.as('00000000-0000-0000-0000-00000000b901');
select t.put('c1', org_create_centre('Money Centre', t.centre_settings()));
select t.as('00000000-0000-0000-0000-00000000b907');
select t.put('c2', org_create_centre('Other Money Centre',
  jsonb_set(jsonb_set(jsonb_set(t.centre_settings(), '{profile,gst_registered}', 'false'), '{profile,invoice_prefix}', '"ELSE"'), '{profile,gst_inclusive}', 'true')));
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('c1'), '00000000-0000-0000-0000-00000000b902', 'Invoices Only',  'staff', array['issue_invoices'], 'active'),
  (t.id('c1'), '00000000-0000-0000-0000-00000000b903', 'Payments Only',  'staff', array['record_payments'], 'active'),
  (t.id('c1'), '00000000-0000-0000-0000-00000000b904', 'Revenue Only',   'staff', array['view_revenue'], 'active'),
  (t.id('c1'), '00000000-0000-0000-0000-00000000b905', 'A Tutor',        'tutor', '{}', 'active'),
  (t.id('c1'), '00000000-0000-0000-0000-00000000b906', 'A Parent',       'parent', '{}', 'active'),
  (t.id('c1'), '00000000-0000-0000-0000-00000000b908', 'Switched off',   'staff', array['issue_invoices', 'record_payments', 'view_revenue'], 'disabled');

-- households, students, lessons (made up)
insert into households(id, org_id, name) values
  ('00000000-0000-0000-0000-00000000c101', t.id('c1'), 'Household One'), ('00000000-0000-0000-0000-00000000c102', t.id('c1'), 'Household Two'),
  ('00000000-0000-0000-0000-00000000c201', t.id('c2'), 'Elsewhere Household');
insert into students(id, tutor_id, org_id, name, household_id) values
  ('00000000-0000-0000-0000-00000000d4a1', '00000000-0000-0000-0000-00000000b901', t.id('c1'), 'Kid One',  '00000000-0000-0000-0000-00000000c101'),
  ('00000000-0000-0000-0000-00000000d4a2', '00000000-0000-0000-0000-00000000b901', t.id('c1'), 'Kid Two',  '00000000-0000-0000-0000-00000000c102'),
  ('00000000-0000-0000-0000-00000000d4b1', '00000000-0000-0000-0000-00000000b907', t.id('c2'), 'Kid Else', '00000000-0000-0000-0000-00000000c201');
insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status) values
  ('00000000-0000-0000-0000-00000000e101', '00000000-0000-0000-0000-00000000b901', t.id('c1'), '00000000-0000-0000-0000-00000000d4a1', current_date - 3, '16:00', '17:00', 50, 50, 'done'),
  ('00000000-0000-0000-0000-00000000e102', '00000000-0000-0000-0000-00000000b901', t.id('c1'), '00000000-0000-0000-0000-00000000d4a1', current_date - 2, '16:00', '17:00', 50, 50, 'done'),
  ('00000000-0000-0000-0000-00000000e103', '00000000-0000-0000-0000-00000000b901', t.id('c1'), '00000000-0000-0000-0000-00000000d4a2', current_date - 2, '17:00', '18:00', 50, 50, 'done'),
  ('00000000-0000-0000-0000-00000000e201', '00000000-0000-0000-0000-00000000b907', t.id('c2'), '00000000-0000-0000-0000-00000000d4b1', current_date - 2, '17:00', '18:00', 50, 50, 'done');

-- helper: a draft document with lines (totals from the centre's own GST settings), signed in as that centre's owner so the settings can be read
create function pg_temp.mkinv(k text, org uuid, owner uuid, kind text, hh uuid, cents bigint[], credits uuid default null, lesson uuid default null, stu uuid default null) returns uuid
language plpgsql as $$
declare id uuid := gen_random_uuid(); g record; i int;
begin
  perform t.as(owner::text);
  select * into g from centre_invoice_gst(org, (select coalesce(sum(c), 0)::bigint from unnest(cents) c), current_date);
  insert into centre_invoices(id, org_id, kind, household_id, student_id, credits_invoice_id, reason, gst_registered, gst_rate_bp, gst_inclusive, net_cents, gst_cents, total_cents)
  values (id, org, kind, hh, stu, credits, case when kind = 'credit_note' then 'goodwill' end, g.gst_registered, g.gst_rate_bp, g.gst_inclusive, g.net_cents, g.gst_cents, g.total_cents);
  for i in 1 .. array_length(cents, 1) loop
    insert into centre_invoice_lines(org_id, invoice_id, position, lesson_id, description, qty, unit_cents)
    values (org, id, i, case when i = 1 then lesson end, 'Maths lesson', 1, cents[i]);
  end loop;
  perform t.put(k, id);
  return id;
end $$;
create function pg_temp.issue(k text) returns void language sql as $$ update centre_invoices set status = 'issued' where id = t.id(k) $$;
create function pg_temp.pay(k text, org uuid, hh uuid, amt bigint, kind text default 'payment', rev uuid default null) returns uuid language plpgsql as $$
declare id uuid := gen_random_uuid();
begin
  insert into centre_payments(id, org_id, kind, reverses_payment_id, household_id, method, amount_cents, received_on, reference, payer_name)
  values (id, org, kind, rev, hh, 'manual_paynow', amt, current_date, 'PAYNOW 91234567 John Tan', 'John Tan');
  perform t.put(k, id); return id;
end $$;
grant execute on all functions in schema pg_temp to public;
\set o1 '00000000-0000-0000-0000-00000000b901'
\set o2 '00000000-0000-0000-0000-00000000b907'
\set h1 '00000000-0000-0000-0000-00000000c101'
\set h2 '00000000-0000-0000-0000-00000000c102'
\set hx '00000000-0000-0000-0000-00000000c201'

-- ===================================================================== 1. GST: the SQL function equals money.js (same CSV)
create temp table gst_vec(name text, subtotal_cents bigint, rate_bp int, inclusive boolean, registered boolean, net_cents bigint, gst_cents bigint, total_cents bigint);
\copy gst_vec from 'tests/gst-vectors.csv' with (format csv, header true)
select t.ok((select count(*) from gst_vec) >= 16, 'the shared GST vectors loaded (' || (select count(*) from gst_vec) || ' rows)');
select t.ok((select bool_and(g.net_cents = v.net_cents and g.gst_cents = v.gst_cents and g.total_cents = v.total_cents)
               from gst_vec v cross join lateral centre_gst_totals(v.subtotal_cents, v.rate_bp, v.inclusive, v.registered) g),
            'centre_gst_totals equals Money.gstForInvoice on every shared vector (' || (select count(*) from gst_vec) || ')');
select t.eq((select gst_cents from centre_gst_totals(50, 900, false, true)), 5, 'worked example: 50c at 9% = 4.5c rounds half up to 5c');
select t.eq((select gst_cents from centre_gst_totals(-50, 900, false, true)), -5, 'worked example: -50c rounds away from zero, symmetric');
select t.eq((select gst_cents from centre_gst_totals(10900, 900, true, true)), 900, 'worked example: S$109.00 inclusive holds S$9.00 of GST');
select t.eq((select gst_cents from centre_gst_totals(10005, 900, false, true)), 900, 'GST once per invoice: three S$33.35 lessons = S$100.05, GST 900c');
select t.fails($q$ select * from centre_gst_totals(100, 9000, false, true) $q$, 'a GST rate above 50% is refused');
select t.fails($q$ select centre_div_round(5, 0) $q$, 'division by zero is refused');
-- the centre's own settings drive it: centre 1 registered/exclusive, centre 2 not registered
select t.as(:'o1');
select t.eq((select gst_cents from centre_invoice_gst(t.id('c1'), 10005)), 900, 'centre 1 (registered, exclusive): GST 900c on S$100.05');
select t.eq((select total_cents from centre_invoice_gst(t.id('c1'), 10005)), 10905, 'centre 1: total includes the GST');
select t.as(:'o2');
select t.eq((select gst_cents from centre_invoice_gst(t.id('c2'), 10005)), 0, 'centre 2 (not registered): no GST whatever the other flags');
select t.eq((select total_cents from centre_invoice_gst(t.id('c2'), 10005)), 10005, 'centre 2: total = subtotal');
select t.as(:'o1');
select t.fails($q$ select * from centre_invoice_gst(t.id('c2'), 100) $q$, 'a centre can''t read another centre''s GST rules through the function');
select set_config('request.jwt.claims', '', false);

-- ===================================================================== 2. centres only
select t.fails(format($q$ insert into centre_invoices(org_id, kind) values (%L, 'lesson') $q$, org_personal('00000000-0000-0000-0000-0000000000a1')), 'a solo organisation can''t hold a centre invoice');
select t.fails(format($q$ insert into centre_payments(org_id, household_id, method, amount_cents, received_on) values (%L, %L, 'cash', 100, current_date) $q$,
                      org_personal('00000000-0000-0000-0000-0000000000a1'), :'h1'), 'a solo organisation can''t hold a centre payment');
select t.fails(format($q$ insert into org_counters(org_id, series) values (%L, 'invoice') $q$, org_personal('00000000-0000-0000-0000-0000000000a1')), 'a solo organisation can''t hold a counter');

-- ===================================================================== 3. drafts, numbering, immutability
select pg_temp.mkinv('A', t.id('c1'), :'o1', 'lesson', :'h1', array[5000, 5000], null, '00000000-0000-0000-0000-00000000e101', '00000000-0000-0000-0000-00000000d4a1');
select t.ok((select status = 'draft' and number_seq is null and number_text is null and total_cents = 10900 and gst_cents = 900 from centre_invoices where id = t.id('A')),
            'a draft has no number; S$100 + 9% GST = S$109.00');
select t.eq((select count(*) from org_counters where org_id = t.id('c1')), 0, 'drafting takes no number');
select t.fails($q$ update centre_invoices set number_seq = 5, number_text = 'X-5' where id = t.id('A') $q$, 'a number can''t be typed onto a draft');
select t.fails(format($q$ insert into centre_invoices(org_id, kind, status, number_seq, number_text, household_id, issue_date, issued_at, gst_registered)
                         values (%L, 'lesson', 'issued', 1, 'X-1', %L, current_date, now(), false) $q$, t.id('c1'), :'h1'), 'a document can''t be created already issued');
select pg_temp.mkinv('E', t.id('c1'), :'o1', 'lesson', :'h1', array[100]);
select t.fails($q$ update centre_invoices set status = 'issued', total_cents = total_cents + 1, net_cents = net_cents + 1 where id = t.id('E') $q$, 'totals that don''t match the lines are refused at issue (GST check)');
select t.fails($q$ update centre_invoices set status = 'issued', gst_cents = 0, total_cents = 100 where id = t.id('E') $q$, 'GST left out of an invoice that is GST-registered is refused');
delete from centre_invoices where id = t.id('E');
select t.eq((select count(*) from centre_invoice_lines where invoice_id = t.id('E')), 0, 'a draft can be deleted, its lines go with it');
insert into centre_invoices(id, org_id, kind, household_id) values ('00000000-0000-0000-0000-00000000f4a1', t.id('c1'), 'lesson', :'h1');
select t.fails($q$ update centre_invoices set status = 'issued', issue_date = current_date where id = '00000000-0000-0000-0000-00000000f4a1' $q$, 'a document with no lines can''t be issued');
delete from centre_invoices where id = '00000000-0000-0000-0000-00000000f4a1';

select pg_temp.issue('A');
select t.ok((select status = 'issued' and number_seq = 1 and number_text = 'TEST-1' and issued_at is not null and issue_date = current_date from centre_invoices where id = t.id('A')),
            'issuing gives the first number: TEST-1 (prefix from the centre''s settings)');
select pg_temp.mkinv('B', t.id('c1'), :'o1', 'lesson', :'h1', array[4000], null, '00000000-0000-0000-0000-00000000e102');
select pg_temp.issue('B');
select t.eq((select number_seq from centre_invoices where id = t.id('B')), 2, 'second invoice is number 2');
-- gap-free: an issue that fails AFTER the number was taken (the due-date check runs after the trigger) rolls the number back
select pg_temp.mkinv('C', t.id('c1'), :'o1', 'lesson', :'h2', array[3000], null, '00000000-0000-0000-0000-00000000e103');
select t.fails($q$ update centre_invoices set status = 'issued', due_date = date '2000-01-01' where id = t.id('C') $q$, 'an issue that fails half-way is refused');
select t.eq((select next_number from org_counters where org_id = t.id('c1') and series = 'invoice'), 3, 'the failed issue left the counter at 3: no number was burnt');
select t.ok((select status = 'draft' and number_seq is null from centre_invoices where id = t.id('C')), 'and the draft is still an unnumbered draft');
select pg_temp.issue('C');
select t.eq((select number_seq from centre_invoices where id = t.id('C')), 3, 'the next successful issue gets 3: numbers 1, 2, 3 with no gap');
-- a deposit invoice shares the invoice series; a credit note has its own
select pg_temp.mkinv('D', t.id('c1'), :'o1', 'deposit', :'h2', array[6000]);
select pg_temp.issue('D');
select t.ok((select number_seq = 4 and number_text = 'TEST-4' from centre_invoices where id = t.id('D')), 'a deposit invoice takes the same series (TEST-4)');
select pg_temp.mkinv('F', t.id('c1'), :'o1', 'late_fee', :'h2', array[500]);
select pg_temp.issue('F');
select t.eq((select number_seq from centre_invoices where id = t.id('F')), 5, 'a late-fee document takes the same series (5)');
select t.ok((select count(distinct number_seq) = count(*) and max(number_seq) = count(*) from centre_invoices where org_id = t.id('c1') and series = 'invoice' and status = 'issued'),
            'the issued numbers are 1..n with no gap and no repeat');
-- one number can't be used twice (even by a superuser editing the counter or the row)
select t.fails($q$ update org_counters set next_number = 2 where org_id = t.id('c1') and series = 'invoice' $q$, 'the counter can''t go back (a number can''t be reused)');
select t.fails($q$ update org_counters set next_number = 99 where org_id = t.id('c1') and series = 'invoice' $q$, 'the counter can''t skip ahead once numbers are issued');
select t.fails($q$ delete from org_counters where org_id = t.id('c1') $q$, 'the counter can''t be deleted');

-- immutability of an issued document and its lines
select t.fails($q$ update centre_invoices set total_cents = 1, net_cents = 1, gst_cents = 0 where id = t.id('A') $q$, 'issued: the total can''t change');
select t.fails($q$ update centre_invoices set due_date = current_date + 30 where id = t.id('A') $q$, 'issued: even the due date can''t change');
select t.fails($q$ update centre_invoices set status = 'void', void_reason = 'oops', voided_at = now() where id = t.id('A') $q$, 'issued: it can''t be voided (credit note instead)');
select t.fails($q$ update centre_invoices set status = 'draft', number_seq = null, number_text = null where id = t.id('A') $q$, 'issued: it can''t go back to draft');
select t.fails($q$ update centre_invoices set number_seq = 99, number_text = 'TEST-99' where id = t.id('A') $q$, 'issued: its number can''t change');
select t.fails($q$ update centre_invoices set household_id = '00000000-0000-0000-0000-00000000c102' where id = t.id('A') $q$, 'issued: it can''t move to another household');
select t.fails($q$ delete from centre_invoices where id = t.id('A') $q$, 'issued: it can''t be deleted');
select t.fails($q$ update centre_invoice_lines set unit_cents = 1 where invoice_id = t.id('A') $q$, 'issued: a line can''t change');
select t.fails($q$ delete from centre_invoice_lines where invoice_id = t.id('A') $q$, 'issued: a line can''t be deleted');
select t.fails(format($q$ insert into centre_invoice_lines(org_id, invoice_id, description, unit_cents) values (%L, %L, 'sneaky', 100) $q$, t.id('c1'), t.id('A')), 'issued: no line can be added');
select t.ok((select total_cents = 10900 and number_text = 'TEST-1' from centre_invoices where id = t.id('A')), 'and invoice A is exactly as issued');

-- void: only a draft, with a reason; frozen after; its lesson can be billed again
select pg_temp.mkinv('V', t.id('c1'), :'o1', 'lesson', :'h1', array[2000]);
select t.fails($q$ update centre_invoices set status = 'void' where id = t.id('V') $q$, 'voiding needs a reason');
update centre_invoices set status = 'void', void_reason = 'made by mistake' where id = t.id('V');
select t.ok((select status = 'void' and number_seq is null and voided_at is not null from centre_invoices where id = t.id('V')), 'a voided draft has no number (nothing to skip)');
select t.fails($q$ update centre_invoices set status = 'issued' where id = t.id('V') $q$, 'a voided document can''t be issued');
select t.fails($q$ update centre_invoices set void_reason = 'x' where id = t.id('V') $q$, 'a voided document can''t change');

-- a lesson is billed once (A already bills lesson e101)
select t.fails(format($q$ insert into centre_invoice_lines(org_id, invoice_id, lesson_id, description, unit_cents) values (%L, %L, '00000000-0000-0000-0000-00000000e101', 'again', 5000) $q$,
                      t.id('c1'), t.id('V')), 'a lesson already billed on an issued invoice can''t be billed again');
insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status) values
  ('00000000-0000-0000-0000-00000000e104', :'o1', t.id('c1'), '00000000-0000-0000-0000-00000000d4a2', current_date - 1, '17:00', '18:00', 50, 50, 'done');
select pg_temp.mkinv('G', t.id('c1'), :'o1', 'lesson', :'h2', array[5000], null, '00000000-0000-0000-0000-00000000e104');
select pg_temp.mkinv('G2', t.id('c1'), :'o1', 'lesson', :'h2', array[100]);
select t.fails(format($q$ insert into centre_invoice_lines(org_id, invoice_id, lesson_id, description, unit_cents) values (%L, %L, '00000000-0000-0000-0000-00000000e104', 'twice', 5000) $q$,
                      t.id('c1'), t.id('G2')), 'a lesson already on a draft can''t be put on a second draft');
update centre_invoices set status = 'void', void_reason = 'duplicate' where id = t.id('G');
insert into centre_invoice_lines(org_id, invoice_id, lesson_id, description, unit_cents) values (t.id('c1'), t.id('G2'), '00000000-0000-0000-0000-00000000e104', 'after void', 5000);
select t.ok(true, 'once the first draft is voided, the lesson can be billed on another document');
update centre_invoices set status = 'void', void_reason = 'test cleanup' where id = t.id('G2');

-- ===================================================================== 4. credit notes
select pg_temp.mkinv('CN1', t.id('c1'), :'o1', 'credit_note', :'h1', array[3000], t.id('A'), null, '00000000-0000-0000-0000-00000000d4a1');
select pg_temp.issue('CN1');
select t.ok((select number_seq = 1 and number_text = 'CN-TEST-1' and series = 'credit_note' from centre_invoices where id = t.id('CN1')), 'a credit note has its own series: CN-TEST-1');
select t.eq((select number_seq from centre_invoices where id = t.id('F')), 5, 'and the invoice series is untouched by it');
select pg_temp.mkinv('CN2', t.id('c1'), :'o1', 'credit_note', :'h1', array[8000], t.id('A'), null, '00000000-0000-0000-0000-00000000d4a1');
select t.fails($q$ update centre_invoices set status = 'issued' where id = t.id('CN2') $q$, 'credit notes can''t add up to more than the invoice (3000 + 8000 > 10900)');
select pg_temp.mkinv('CN3', t.id('c1'), :'o1', 'credit_note', :'h1', array[7000], t.id('A'), null, '00000000-0000-0000-0000-00000000d4a1');
select pg_temp.issue('CN3');
select t.ok((select number_text = 'CN-TEST-2' from centre_invoices where id = t.id('CN3')), 'a second credit note is CN-TEST-2');
select pg_temp.mkinv('CN4', t.id('c1'), :'o1', 'credit_note', :'h1', array[1], t.id('A'), null, '00000000-0000-0000-0000-00000000d4a1');
select t.fails($q$ update centre_invoices set status = 'issued' where id = t.id('CN4') $q$, 'the invoice is fully credited: not even 1 cent more');
select pg_temp.mkinv('CN5', t.id('c1'), :'o1', 'credit_note', :'h1', array[100], t.id('V'));
select t.fails($q$ update centre_invoices set status = 'issued' where id = t.id('CN5') $q$, 'a credit note must credit an issued invoice (V is void)');
select pg_temp.mkinv('CN6', t.id('c1'), :'o1', 'credit_note', :'h2', array[100], t.id('A'));
select t.fails($q$ update centre_invoices set status = 'issued' where id = t.id('CN6') $q$, 'a credit note must be for the same household as its invoice');
select t.fails(format($q$ insert into centre_invoices(org_id, kind, household_id) values (%L, 'credit_note', %L) $q$, t.id('c1'), :'h1'), 'a credit note without an invoice to credit is refused');
select t.fails(format($q$ insert into centre_invoices(org_id, kind, household_id, credits_invoice_id) values (%L, 'lesson', %L, %L) $q$, t.id('c1'), :'h1', t.id('A')), 'only a credit note may point at an invoice to credit');

-- ===================================================================== 5. opening number
select t.as(:'o2');
select t.fails($q$ select centre_set_opening_number(t.id('c2'), 'invoice', 0) $q$, 'opening number below 1 is refused');
select t.eq(centre_set_opening_number(t.id('c2'), 'invoice', 1000), 1000, 'the owner can set the opening invoice number before anything is issued');
select t.eq(centre_set_opening_number(t.id('c2'), 'invoice', 2500), 2500, 'and change it again while nothing has been issued');
select t.as(:'o2');
select pg_temp.mkinv('X1', t.id('c2'), :'o2', 'lesson', :'hx', array[1000], null, null);
select pg_temp.issue('X1');
select t.ok((select number_seq = 2500 and number_text = 'ELSE-2500' from centre_invoices where id = t.id('X1')), 'the first invoice takes the opening number: ELSE-2500 (that centre''s prefix)');
select t.ok((select gst_cents = 0 and total_cents = 1000 and not gst_registered from centre_invoices where id = t.id('X1')), 'centre 2 is not GST registered: no GST on its invoice');
select pg_temp.mkinv('X2', t.id('c2'), :'o2', 'lesson', :'hx', array[1000]);
select pg_temp.issue('X2');
select t.eq((select number_seq from centre_invoices where id = t.id('X2')), 2501, 'numbers continue from the opening number: 2501');
select t.fails($q$ select centre_set_opening_number(t.id('c2'), 'invoice', 3000) $q$, 'after the first document, the opening number is locked');
select t.eq(centre_set_opening_number(t.id('c2'), 'credit_note', 50), 50, 'the credit-note series has its own opening number');
select t.as(:'o1');
select t.fails($q$ select centre_set_opening_number(t.id('c1'), 'invoice', 1) $q$, 'centre 1 already issued documents: locked');
select t.fails($q$ select centre_set_opening_number(t.id('c2'), 'credit_note', 70) $q$, 'the owner of another centre can''t set this centre''s number (not found)');
select t.as('00000000-0000-0000-0000-00000000b902');
select t.fails($q$ select centre_set_opening_number(t.id('c1'), 'credit_note', 9) $q$, 'staff (even with issue_invoices) can''t set the opening number: owner only');
select t.as('00000000-0000-0000-0000-0000000000a1');
select t.fails($q$ select centre_set_opening_number(org_personal('00000000-0000-0000-0000-0000000000a1'), 'invoice', 5) $q$, 'a solo organisation has no opening number');
select set_config('request.jwt.claims', '', false);

-- ===================================================================== 6. payments and allocations
select pg_temp.pay('P1', t.id('c1'), :'h1', 10000);
select t.fails($q$ update centre_payments set amount_cents = 1 where id = t.id('P1') $q$, 'a payment can''t be edited');
select t.fails($q$ delete from centre_payments where id = t.id('P1') $q$, 'a payment can''t be deleted');
select t.fails(format($q$ insert into centre_payments(org_id, household_id, method, amount_cents, received_on) values (%L, %L, 'cash', 0, current_date) $q$, t.id('c1'), :'h1'), 'a payment of 0 is refused');
select t.fails(format($q$ insert into centre_payments(org_id, household_id, method, amount_cents, received_on) values (%L, %L, 'barter', 100, current_date) $q$, t.id('c1'), :'h1'), 'an unknown payment method is refused');
-- allocate to invoice A (total 10900, credited 10000 net... credit notes 3000+7000 = 10000 + GST? see below)
select t.eq((select sum(total_cents) from centre_invoices where credits_invoice_id = t.id('A') and status = 'issued'), 10000 + 900, 'credit notes on A total 10900 (net 10000 + GST 900): A is fully credited');
select t.fails(format($q$ insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (%L, %L, %L, 100) $q$, t.id('c1'), t.id('P1'), t.id('A')),
               'nothing can be allocated to a fully credited invoice');
select t.fails(format($q$ insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (%L, %L, %L, 100) $q$, t.id('c1'), t.id('P1'), t.id('C')),
               'allocating to an invoice of ANOTHER household is refused (payment is household one, invoice C is household two)');
select t.fails(format($q$ insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (%L, %L, %L, 100) $q$, t.id('c1'), t.id('P1'), t.id('V')),
               'allocating to a voided/draft invoice is refused');
select t.fails(format($q$ insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (%L, %L, %L, 100) $q$, t.id('c1'), t.id('P1'), t.id('CN1')),
               'allocating to a credit note is refused');
select pg_temp.mkinv('H1a', t.id('c1'), :'o1', 'lesson', :'h1', array[6000]);
select pg_temp.issue('H1a');
select pg_temp.mkinv('H1b', t.id('c1'), :'o1', 'lesson', :'h1', array[6000]);
select pg_temp.issue('H1b');
select t.eq((select total_cents from centre_invoices where id = t.id('H1a')), 6540, 'invoice H1a: S$60 + 9% = 6540c');
insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (t.id('c1'), t.id('P1'), t.id('H1a'), 6540);
select t.fails(format($q$ insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (%L, %L, %L, 3461) $q$, t.id('c1'), t.id('P1'), t.id('H1b')),
               'allocations can''t add up to more than the payment (6540 + 3461 > 10000)');
select t.fails(format($q$ insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (%L, %L, %L, 1) $q$, t.id('c1'), t.id('P1'), t.id('H1a')),
               'allocations can''t add up to more than the invoice (6540 already on a 6540 invoice)');
insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (t.id('c1'), t.id('P1'), t.id('H1b'), 3460);
select t.eq((select sum(cents) from centre_payment_allocations where payment_id = t.id('P1')), 10000, 'the whole payment can be allocated, to the cent');
select t.fails(format($q$ insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (%L, %L, %L, 1) $q$, t.id('c1'), t.id('P1'), t.id('H1b')),
               'one cent more than the payment is refused');
select t.fails(format($q$ insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (%L, %L, %L, -100) $q$, t.id('c1'), t.id('P1'), t.id('H1b')),
               'a payment can''t be allocated negatively (only its reversal can)');
select t.fails($q$ update centre_payment_allocations set cents = 1 where payment_id = t.id('P1') $q$, 'an allocation can''t be edited');
select t.fails($q$ delete from centre_payment_allocations where payment_id = t.id('P1') $q$, 'an allocation can''t be deleted');
select t.fails(format($q$ insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (%L, %L, %L, 0) $q$, t.id('c1'), t.id('P1'), t.id('H1b')), 'an allocation of 0 is refused');

-- an invoice is capped across SEVERAL payments too, and a credit note lowers the cap
select pg_temp.pay('P2', t.id('c1'), :'h1', 50000);
select t.fails(format($q$ insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (%L, %L, %L, 3081) $q$, t.id('c1'), t.id('P2'), t.id('H1b')),
               'a second payment can''t push an invoice over its total either (3460 already + 3081 > 6540)');
select pg_temp.mkinv('H1c', t.id('c1'), :'o1', 'lesson', :'h1', array[10000]);       -- total 10900
select pg_temp.issue('H1c');
select pg_temp.mkinv('CN7', t.id('c1'), :'o1', 'credit_note', :'h1', array[1000], t.id('H1c'));   -- credit 1090
select pg_temp.issue('CN7');
select t.fails(format($q$ insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (%L, %L, %L, 9811) $q$, t.id('c1'), t.id('P2'), t.id('H1c')),
               'what is still owed is the total minus credit notes (10900 - 1090 = 9810): 9811 is refused');
insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (t.id('c1'), t.id('P2'), t.id('H1c'), 9810);
select t.ok(true, 'and 9810 is accepted');
-- a payment of another household/organisation can't be used
select pg_temp.pay('PX', t.id('c2'), :'hx', 100);
select t.fails(format($q$ insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (%L, %L, %L, 100) $q$, t.id('c1'), t.id('PX'), t.id('H1c')),
               'another centre''s payment can''t be allocated to this centre''s invoice');
select t.fails(format($q$ insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (%L, %L, %L, 100) $q$, t.id('c2'), t.id('PX'), t.id('H1c')),
               'nor with the other centre''s org id (composite key)');

-- reversals: a new row, matching the payment; negative allocations; nothing left allocated
select t.fails(format($q$ insert into centre_payments(org_id, kind, reverses_payment_id, household_id, method, amount_cents, received_on) values (%L, 'reversal', %L, %L, 'manual_paynow', 9999, current_date) $q$,
                      t.id('c1'), t.id('P1'), :'h1'), 'a reversal must repeat the amount of the payment');
select t.fails(format($q$ insert into centre_payments(org_id, kind, reverses_payment_id, household_id, method, amount_cents, received_on) values (%L, 'reversal', %L, %L, 'manual_paynow', 10000, current_date) $q$,
                      t.id('c1'), t.id('P1'), :'h2'), 'a reversal must repeat the household');
select t.fails(format($q$ insert into centre_payments(org_id, kind, reverses_payment_id, household_id, method, amount_cents, received_on) values (%L, 'reversal', %L, %L, 'manual_paynow', 100, current_date) $q$,
                      t.id('c1'), t.id('PX'), :'h1'), 'a reversal can''t cancel another centre''s payment');
select t.fails(format($q$ insert into centre_payments(org_id, kind, household_id, method, amount_cents, received_on) values (%L, 'reversal', %L, 'cash', 100, current_date) $q$, t.id('c1'), :'h1'), 'a reversal must name a payment');
-- reversing P1 while its money is still allocated: refused when the transaction ends
select t.fails(format($q$ do $x$ begin
    insert into centre_payments(org_id, kind, reverses_payment_id, household_id, method, amount_cents, received_on) values (%L, 'reversal', %L, %L, 'manual_paynow', 10000, current_date);
    set constraints all immediate;
  end $x$ $q$, t.id('c1'), t.id('P1'), :'h1'), 'reversing a payment that still has money allocated is refused');
-- reversing it properly: reversal row first, then the negative allocations
do $x$ declare r uuid := gen_random_uuid(); begin
  insert into centre_payments(id, org_id, kind, reverses_payment_id, household_id, method, amount_cents, received_on)
    values (r, t.id('c1'), 'reversal', t.id('P1'), '00000000-0000-0000-0000-00000000c101', 'manual_paynow', 10000, current_date);
  perform t.put('R1', r);
  insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (t.id('c1'), r, t.id('H1a'), -6540), (t.id('c1'), r, t.id('H1b'), -3460);
  set constraints all immediate;
end $x$;
select t.ok(true, 'a payment is reversed by a new row plus negative allocations');
select t.eq((select coalesce(sum(cents), 0) from centre_payment_allocations where invoice_id in (t.id('H1a'), t.id('H1b'))), 0, 'invoices H1a and H1b are back to nothing allocated');
select t.fails(format($q$ insert into centre_payments(org_id, kind, reverses_payment_id, household_id, method, amount_cents, received_on) values (%L, 'reversal', %L, %L, 'manual_paynow', 10000, current_date) $q$,
                      t.id('c1'), t.id('P1'), :'h1'), 'a payment can be reversed only once');
select t.fails(format($q$ insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (%L, %L, %L, -1) $q$, t.id('c1'), t.id('R1'), t.id('H1a')),
               'a reversal can''t un-allocate more than the payment put there');
select t.fails(format($q$ insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (%L, %L, %L, 100) $q$, t.id('c1'), t.id('R1'), t.id('H1a')),
               'a reversal can''t allocate (positive cents)');
select t.eq((select count(*) from centre_payments where kind = 'reversal' and reverses_payment_id = t.id('P1')), 1, 'P1 has exactly one reversal row, and P1 itself was never touched');
select t.eq((select amount_cents from centre_payments where id = t.id('P1')), 10000, 'the original payment row still reads S$100.00');
-- the freed money can be paid again against the same invoices
select pg_temp.pay('P3', t.id('c1'), :'h1', 6540);
insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (t.id('c1'), t.id('P3'), t.id('H1a'), 6540);
select t.ok(true, 'after the reversal the invoice can be paid in full by a new payment');

-- ===================================================================== 7. cross-organisation refusals
select t.fails(format($q$ insert into centre_invoices(org_id, kind, household_id) values (%L, 'lesson', %L) $q$, t.id('c1'), :'hx'), 'an invoice of centre 1 can''t be for a household of centre 2');
select t.fails(format($q$ insert into centre_invoices(org_id, kind, student_id) values (%L, 'lesson', '00000000-0000-0000-0000-00000000d4b1') $q$, t.id('c1')), 'nor for a student of centre 2');
select pg_temp.mkinv('Y1', t.id('c1'), :'o1', 'lesson', :'h2', array[100]);
select t.fails(format($q$ insert into centre_invoice_lines(org_id, invoice_id, lesson_id, description, unit_cents) values (%L, %L, '00000000-0000-0000-0000-00000000e201', 'x', 100) $q$, t.id('c1'), t.id('Y1')),
               'a line of centre 1 can''t bill a lesson of centre 2');
select t.fails(format($q$ insert into centre_invoice_lines(org_id, invoice_id, description, unit_cents) values (%L, %L, 'x', 100) $q$, t.id('c2'), t.id('Y1')),
               'a line can''t carry another organisation''s id on this invoice (composite key)');
select t.fails(format($q$ insert into centre_payments(org_id, household_id, method, amount_cents, received_on) values (%L, %L, 'cash', 100, current_date) $q$, t.id('c1'), :'hx'),
               'a payment of centre 1 can''t come from a household of centre 2');
select t.fails(format($q$ insert into centre_invoices(org_id, kind, household_id, credits_invoice_id) values (%L, 'credit_note', %L, %L) $q$, t.id('c2'), :'hx', t.id('A')),
               'a credit note of centre 2 can''t credit an invoice of centre 1');
update centre_invoices set status = 'void', void_reason = 'cleanup' where id = t.id('Y1');

-- ===================================================================== 8. who can read what (row-level security)
create temp table cnt (who text, inv int, lines int, pays int, allocs int, ctr int);
grant all on cnt to authenticated, anon;
create function pg_temp.snap(label text) returns void language plpgsql as $$
begin insert into cnt select label, (select count(*) from centre_invoices), (select count(*) from centre_invoice_lines), (select count(*) from centre_payments),
                                    (select count(*) from centre_payment_allocations), (select count(*) from org_counters); end $$;
grant execute on function pg_temp.snap(text) to public;
select t.as(:'o1');                                              set role authenticated; select pg_temp.snap('owner');     reset role;
select t.as('00000000-0000-0000-0000-00000000b902');             set role authenticated; select pg_temp.snap('invoices');  reset role;
select t.as('00000000-0000-0000-0000-00000000b903');             set role authenticated; select pg_temp.snap('payments');  reset role;
select t.as('00000000-0000-0000-0000-00000000b904');             set role authenticated; select pg_temp.snap('revenue');   reset role;
select t.as('00000000-0000-0000-0000-00000000b905');             set role authenticated; select pg_temp.snap('tutor');     reset role;
select t.as('00000000-0000-0000-0000-00000000b906');             set role authenticated; select pg_temp.snap('parent');    reset role;
select t.as('00000000-0000-0000-0000-00000000b908');             set role authenticated; select pg_temp.snap('off');       reset role;
select t.as('00000000-0000-0000-0000-00000000b909');             set role authenticated; select pg_temp.snap('stranger'); reset role;
select t.as('00000000-0000-0000-0000-0000000000a1');             set role authenticated; select pg_temp.snap('solo');      reset role;
select t.as(:'o2');                                              set role authenticated; select pg_temp.snap('owner2');    reset role;
select set_config('request.jwt.claims', '', false);
select t.ok((select inv > 0 and lines > 0 and pays > 0 and allocs > 0 and ctr >= 1 from cnt where who = 'owner'), 'the owner reads documents, lines, payments, allocations and counters');
select t.ok((select inv > 0 and lines > 0 and pays = 0 and allocs = 0 and ctr >= 1 from cnt where who = 'invoices'), 'issue_invoices reads documents and lines, NOT payments');
select t.ok((select inv = 0 and lines = 0 and pays > 0 and allocs > 0 and ctr = 0 from cnt where who = 'payments'), 'record_payments reads payments and allocations, NOT documents');
select t.ok((select inv + lines + pays + allocs + ctr = 0 from cnt where who = 'revenue'), 'view_revenue alone reads no table (it gets totals from the function)');
select t.ok((select inv + lines + pays + allocs + ctr = 0 from cnt where who = 'tutor'),    'a centre tutor reads nothing');
select t.ok((select inv + lines + pays + allocs + ctr = 0 from cnt where who = 'parent'),   'a parent reads nothing');
select t.ok((select inv + lines + pays + allocs + ctr = 0 from cnt where who = 'off'),      'switched-off staff read nothing');
select t.ok((select inv + lines + pays + allocs + ctr = 0 from cnt where who = 'stranger'), 'a signed-in stranger reads nothing');
select t.ok((select inv + lines + pays + allocs + ctr = 0 from cnt where who = 'solo'),     'a solo tutor reads nothing');
select t.ok((select inv = (select count(*) from centre_invoices where org_id = t.id('c2')) and pays = (select count(*) from centre_payments where org_id = t.id('c2')) from cnt where who = 'owner2'),
            'the other centre''s owner reads only their own rows');
set role anon;
select t.fails($q$ select count(*) from centre_invoices $q$, 'anonymous callers can''t read documents');
select t.fails($q$ select count(*) from centre_payments $q$, 'anonymous callers can''t read payments');
select t.fails($q$ select count(*) from org_counters $q$, 'anonymous callers can''t read counters');
reset role;
-- nobody writes from a browser, not even the owner
select t.as(:'o1'); set role authenticated;
select t.fails(format($q$ insert into centre_invoices(org_id, kind, household_id) values (%L, 'lesson', %L) $q$, t.id('c1'), :'h1'), 'the owner can''t insert a document from the browser');
select t.fails($q$ update centre_invoices set due_date = current_date $q$, 'the owner can''t update a document from the browser (no privilege)');
select t.fails($q$ delete from centre_invoices $q$, 'the owner can''t delete a document from the browser');
select t.fails(format($q$ insert into centre_payments(org_id, household_id, method, amount_cents, received_on) values (%L, %L, 'cash', 100, current_date) $q$, t.id('c1'), :'h1'), 'the owner can''t insert a payment from the browser');
select t.fails($q$ update org_counters set next_number = 1 $q$, 'the owner can''t touch a counter from the browser');
select t.fails($q$ select centre_next_number(t.id('c1'), 'invoice') $q$, 'a browser can''t take a document number');
reset role;
select t.ok(not has_function_privilege('anon', 'public.centre_next_number(uuid,text)', 'execute') and not has_function_privilege('authenticated', 'public.centre_next_number(uuid,text)', 'execute'), 'centre_next_number is server-only');
select t.ok(not has_function_privilege('anon', 'public.centre_set_opening_number(uuid,text,int)', 'execute') and has_function_privilege('authenticated', 'public.centre_set_opening_number(uuid,text,int)', 'execute'), 'opening number: signed-in only (the function checks owner)');
select t.ok(not has_function_privilege('anon', 'public.centre_revenue_totals(uuid,date,date)', 'execute') and not has_function_privilege('anon', 'public.centre_invoice_gst(uuid,bigint,date)', 'execute'), 'anon can''t call the totals or GST functions');
select t.ok((select bool_and(not has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute'))
               from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('centre_money_org_guard','centre_counter_guard','centre_invoice_guard','centre_line_guard',
                    'centre_payment_guard','centre_payment_reversal_check','centre_alloc_guard','centre_money_audit')), 'trigger functions are not an API');
select t.ok((select bool_and(c.relrowsecurity) from pg_class c where c.relname in ('org_counters','centre_invoices','centre_invoice_lines','centre_payments','centre_payment_allocations')), 'row-level security is on for every new table');
select t.eq((select count(*) from pg_policies where tablename in ('org_counters','centre_invoices','centre_invoice_lines','centre_payments','centre_payment_allocations') and cmd <> 'SELECT'), 0, 'no table has an insert/update/delete/all policy');

-- totals for view_revenue
select t.as('00000000-0000-0000-0000-00000000b904'); set role authenticated;
select t.ok((select (r->>'invoiced_cents')::bigint > 0 and (r->>'invoices')::int >= 5 from (select centre_revenue_totals(t.id('c1')) r) x), 'view_revenue gets the totals');
select t.eq((select (centre_revenue_totals(t.id('c1'))->>'credited_cents')::bigint), 11990, 'credited total = CN1 3270 + CN3 7630 + CN7 1090 (each with its GST)');
select t.eq((select (centre_revenue_totals(t.id('c1'))->>'received_cents')::bigint),
            56540, 'received total = P1 10000 - its reversal 10000 + P2 50000 + P3 6540');
select t.eq((select (centre_revenue_totals(t.id('c1'), current_date + 1, null)->>'invoiced_cents')::bigint), 0, 'the date range filters');
reset role;
select t.as('00000000-0000-0000-0000-00000000b902'); set role authenticated;
select t.fails($q$ select centre_revenue_totals(t.id('c1')) $q$, 'issue_invoices alone does not give totals');
reset role;
select t.as('00000000-0000-0000-0000-00000000b905'); set role authenticated;
select t.fails($q$ select centre_revenue_totals(t.id('c1')) $q$, 'a tutor gets no totals');
reset role;
select t.as('00000000-0000-0000-0000-0000000000a1'); set role authenticated;
select t.fails($q$ select centre_revenue_totals(org_personal('00000000-0000-0000-0000-0000000000a1')) $q$, 'a solo organisation gets no totals');
reset role;
select t.as(:'o2'); set role authenticated;
select t.fails($q$ select centre_revenue_totals(t.id('c1')) $q$, 'another centre''s owner gets no totals of this centre (not found)');
reset role;
select set_config('request.jwt.claims', '', false); set role anon;
select t.fails($q$ select centre_revenue_totals(t.id('c1')) $q$, 'anonymous gets no totals');
reset role;

-- ===================================================================== 9. audit: written, and free text redacted
select t.ok((select count(*) >= 1 from audit_log where table_name = 'centre_payments' and action = 'insert' and row_id = t.id('P1')::text), 'a payment is audited');
select t.ok((select after->>'reference' = '[redacted]' and after->>'payer_name' = '[redacted]' and (after->>'amount_cents')::bigint = 10000 and after->>'method' = 'manual_paynow'
               from audit_log where table_name = 'centre_payments' and action = 'insert' and row_id = t.id('P1')::text),
            'the audit copy of a payment keeps the amount and method but redacts the reference and payer name');
select t.eq((select count(*) from audit_log where table_name like 'centre\_%' and ((before::text || after::text) like '%91234567%' or (before::text || after::text) like '%John Tan%')), 0, 'the payment reference and payer name appear nowhere in the centre money audit rows');
select t.ok((select after->>'description' = '[redacted]' and (after->>'unit_cents')::bigint = 5000 from audit_log where table_name = 'centre_invoice_lines' and action = 'insert' order by id limit 1), 'a line is audited with its description redacted');
select t.ok((select after->>'reason' = '[redacted]' from audit_log where table_name = 'centre_invoices' and action = 'update' and after->>'kind' = 'credit_note' and after->>'status' = 'issued' order by id limit 1), 'a credit note''s reason is redacted in the audit copy');
select t.ok((select count(*) >= 1 from audit_log where table_name = 'centre_invoices' and action = 'update' and after->>'status' = 'issued' and after->>'number_text' = 'TEST-1'), 'issuing is audited with its number');
select t.ok((select count(*) >= 1 from audit_log where table_name = 'org_counters' and action = 'update' and after->>'series' = 'invoice'), 'counter moves are audited');
select t.ok((select count(*) >= 1 from audit_log where table_name = 'org_counters' and action = 'update' and (after->>'next_number')::int = 2500 and org_id = t.id('c2')), 'setting the opening number is audited (who, when)');
select t.fails($q$ update audit_log set action = 'x' where table_name = 'centre_payments' $q$, 'the audit copy can''t be edited');

-- ===================================================================== 10. the money in a worked example, end to end
select t.eq((select sum(total_cents) from centre_invoices where id in (t.id('A'), t.id('B'), t.id('C'))), 10900 + 4360 + 3270, 'A + B + C = 10900 + 4360 + 3270 (each invoice has its own GST, rounded once per invoice)');
select 'PASS centre_money: all checks' as done;
