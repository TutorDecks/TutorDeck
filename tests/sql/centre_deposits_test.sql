-- T4 step S4 tests: centre deposits — every deposit mode, the frozen percent, trial students, first run only, liability-not-revenue, the taxable flag,
-- the OPENING invoice kind (keeps its number, bypasses the counter), waive, opening balance, permissions, cross-centre refusals, audit redaction.
-- Runs after centre_payments_test.sql in the same throwaway database (reuses the t.* helpers). Builds its own centres and made-up people.
-- Prices: every lesson is 1 hour at 50 = 5000 cents unless a test says otherwise. All names are FAKE.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000dd01', 'dp.owner@centre.test'),   ('00000000-0000-0000-0000-00000000dd02', 'dp.payments@centre.test'),
  ('00000000-0000-0000-0000-00000000dd03', 'dp.billing@centre.test'), ('00000000-0000-0000-0000-00000000dd04', 'dp.revenue@centre.test'),
  ('00000000-0000-0000-0000-00000000dd05', 'dp.tutor@centre.test'),   ('00000000-0000-0000-0000-00000000dd06', 'dp.parent@centre.test'),
  ('00000000-0000-0000-0000-00000000dd07', 'dp.outsider@centre.test'), ('00000000-0000-0000-0000-00000000dd08', 'dp.off@centre.test'),
  ('00000000-0000-0000-0000-00000000dd09', 'dp.owner2@centre.test'),  ('00000000-0000-0000-0000-00000000dd0a', 'dp.owner3@centre.test'),
  ('00000000-0000-0000-0000-00000000dd0b', 'dp.owner4@centre.test'),  ('00000000-0000-0000-0000-00000000dd0c', 'dp.owner5@centre.test'),
  ('00000000-0000-0000-0000-00000000dd0d', 'dp.solo@centre.test');
\set o1 '00000000-0000-0000-0000-00000000dd01'
\set paym '00000000-0000-0000-0000-00000000dd02'
\set bill '00000000-0000-0000-0000-00000000dd03'
\set rev '00000000-0000-0000-0000-00000000dd04'
\set tut '00000000-0000-0000-0000-00000000dd05'
\set par '00000000-0000-0000-0000-00000000dd06'
\set out '00000000-0000-0000-0000-00000000dd07'
\set off '00000000-0000-0000-0000-00000000dd08'
\set o2 '00000000-0000-0000-0000-00000000dd09'
\set o3 '00000000-0000-0000-0000-00000000dd0a'
\set o4 '00000000-0000-0000-0000-00000000dd0b'
\set o5 '00000000-0000-0000-0000-00000000dd0c'
\set solo '00000000-0000-0000-0000-00000000dd0d'

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today, date_trunc('month', (now() at time zone 'Asia/Singapore')::date - interval '1 month')::date as m,
  date_trunc('month', (now() at time zone 'Asia/Singapore')::date)::date as m2;
grant select on td to authenticated, anon;

-- settings: postpaid, invoice per family, prefix INV, 7 days, review before sending, GST 9% exclusive; the deposit block comes from the caller
create function pg_temp.settings(p_dep jsonb, p_fee bigint default 0, p_review boolean default true) returns jsonb language sql as $$
  select jsonb_set(jsonb_set(jsonb_set(t.centre_settings(), '{profile,invoice_prefix}', '"INV"'),
         '{billing}', jsonb_build_object('model', 'postpaid_lessons', 'deposit', p_dep, 'one_off_fees', jsonb_build_object('registration_cents', 0, 'deposit_cents', p_fee, 'materials_cents', 0),
                                          'absences', '{"mode":"charged","notice_hours":24}'::jsonb)),
         '{invoicing}', jsonb_build_object('grouping', 'family', 'due_days', 7, 'review_before_sending', p_review)) $$;
create function pg_temp.cfg(p_org uuid, p_owner uuid, p_path text[], p_val jsonb) returns void language plpgsql as $$
declare cur jsonb;
begin
  perform t.as(p_owner::text);
  cur := org_settings_on(p_org, current_date);
  perform org_save_settings(p_org, jsonb_set(cur, p_path, p_val, true), current_date);
end $$;
create function pg_temp.refused(p_user text, p_sql text, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  begin execute p_sql; exception when others then m := sqlerrm; end;
  if m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS refused: % (%)', p_msg, m;
end $$;
create function pg_temp.mk(p_org uuid, p_owner uuid, p_stu uuid, p_day int, p_status text, p_att text default null, p_comp numeric default null,
                           p_amount numeric default 50, p_trial boolean default false, p_month date default null) returns uuid language plpgsql as $$
declare lid uuid := gen_random_uuid();
begin
  insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, attendance, compensation, trial, subject)
  values (lid, p_owner, p_org, p_stu, coalesce(p_month, (select m from td)) + (p_day - 1), '16:00', '17:00', 50, p_amount, p_status, p_att, p_comp, p_trial, 'Math');
  return lid;
end $$;
create function pg_temp.pv(p_org uuid, p_user uuid, p_month date default null) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_invoice_run_preview(p_org, coalesce(p_month, (select m from td))); end $$;
create function pg_temp.run(p_org uuid, p_user uuid, p_month date default null) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_invoice_run_create_drafts(p_org, coalesce(p_month, (select m from td))); end $$;
create function pg_temp.approve(p_org uuid, p_user uuid, p_month date default null) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_invoice_approve_all(p_org, coalesce(p_month, (select m from td))); end $$;
create function pg_temp.dep(p_org uuid, p_user uuid, p_student text) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return (select e from jsonb_array_elements(centre_deposit_status(p_org)->'rows') e where e->>'student_id' = t.id(p_student)::text); end $$;
create function pg_temp.held(p_org uuid, p_user uuid) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_deposits_held(p_org); end $$;
create function pg_temp.pay(p_user uuid, p_org uuid, p_hh uuid, p_amt bigint, p_ids uuid[] default null) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_record_payment(p_org, p_hh, 'cash', p_amt, (select today from td), null, p_ids, null, null); end $$;
create function pg_temp.dinv(p_student text) returns uuid language sql security definer as $$ select id from centre_invoices where student_id = t.id(p_student) and kind = 'deposit' and status <> 'void' order by created_at desc limit 1 $$;
create function pg_temp.linv(p_hh text) returns uuid language sql security definer as $$ select id from centre_invoices where household_id = t.id(p_hh) and kind = 'lesson' and status = 'issued' order by created_at limit 1 $$;
create function pg_temp.rev(p_org uuid, p_user uuid) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_revenue_totals(p_org, null, null); end $$;
grant execute on all functions in schema pg_temp to public;

-- A centre with the same cast of made-up students every time (key = a short name; the owner makes the centre):
--   <key>_amy   4 done lessons (S$200.00) + 1 free trial lesson       <key>_ben  her brother, same family, 2 done lessons (S$100.00)
--   <key>_bea   ONLY a trial lesson (a trial student)                 <key>_cal  2 done lessons + a late-cancelled lesson with NO charge yet (held back)
--   <key>_dee   3 done lessons (S$150.00)                             <key>_eli  has never had an invoice either, no lessons this month
create function pg_temp.centre(p_key text, p_owner uuid, p_dep jsonb, p_fee bigint default 0, p_review boolean default true) returns void language plpgsql as $$
declare org uuid; hh_a uuid := gen_random_uuid(); hh_b uuid := gen_random_uuid(); hh_c uuid := gen_random_uuid(); hh_d uuid := gen_random_uuid(); hh_e uuid := gen_random_uuid();
  amy uuid := gen_random_uuid(); ben uuid := gen_random_uuid(); bea uuid := gen_random_uuid(); cal uuid := gen_random_uuid(); dee uuid := gen_random_uuid(); eli uuid := gen_random_uuid();
begin
  perform t.as(p_owner::text);
  set local role authenticated;
  org := org_create_centre('Deposit Centre ' || p_key, pg_temp.settings(p_dep, p_fee, p_review));
  reset role; perform set_config('request.jwt.claims', '', false);
  perform t.put(p_key, org);
  insert into households(id, org_id, name) values (hh_a, org, 'Aw Family'), (hh_b, org, 'Bee Family'), (hh_c, org, 'Chee Family'), (hh_d, org, 'Dee Family'), (hh_e, org, 'Eng Family');
  insert into students(id, tutor_id, org_id, name, household_id, created_at) values
    (amy, p_owner, org, 'Amy Aw', hh_a, '2026-01-01'), (ben, p_owner, org, 'Ben Aw', hh_a, '2026-02-01'), (bea, p_owner, org, 'Bea Bee', hh_b, '2026-01-01'),
    (cal, p_owner, org, 'Cal Chee', hh_c, '2026-01-01'), (dee, p_owner, org, 'Dee Dee', hh_d, '2026-01-01'), (eli, p_owner, org, 'Eli Eng', hh_e, '2026-01-01');
  perform t.put(p_key || '_amy', amy); perform t.put(p_key || '_ben', ben); perform t.put(p_key || '_bea', bea); perform t.put(p_key || '_cal', cal); perform t.put(p_key || '_dee', dee); perform t.put(p_key || '_eli', eli);
  perform t.put(p_key || '_hha', hh_a); perform t.put(p_key || '_hhd', hh_d);
  perform pg_temp.mk(org, p_owner, amy, 3, 'done'); perform pg_temp.mk(org, p_owner, amy, 4, 'done'); perform pg_temp.mk(org, p_owner, amy, 5, 'done'); perform pg_temp.mk(org, p_owner, amy, 6, 'done');
  perform pg_temp.mk(org, p_owner, amy, 2, 'done', 'attended', null, 50, true);
  perform pg_temp.mk(org, p_owner, ben, 3, 'done'); perform pg_temp.mk(org, p_owner, ben, 4, 'done');
  perform pg_temp.mk(org, p_owner, bea, 3, 'done', 'attended', null, 50, true);
  perform pg_temp.mk(org, p_owner, cal, 3, 'done'); perform pg_temp.mk(org, p_owner, cal, 4, 'done'); perform pg_temp.mk(org, p_owner, cal, 6, 'cancelled', 'late_cancelled', null);
  perform pg_temp.mk(org, p_owner, dee, 3, 'done'); perform pg_temp.mk(org, p_owner, dee, 4, 'done'); perform pg_temp.mk(org, p_owner, dee, 5, 'done');
end $$;
select pg_temp.centre('c1', :'o1', '{"mode":"percent_first_month","percent_bp":5000,"taxable":false,"due":"with_first_invoice","waived_by":"owner"}');
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('c1'), :'paym', 'Payments Pat',  'staff',  array['record_payments'], 'active'),
  (t.id('c1'), :'bill', 'Billing Bea',   'staff',  array['issue_invoices'], 'active'),
  (t.id('c1'), :'rev',  'Revenue Rae',   'staff',  array['view_revenue'], 'active'),
  (t.id('c1'), :'tut',  'Tutor Tia',     'tutor',  '{}', 'active'),
  (t.id('c1'), :'par',  'Parent Pia',    'parent', '{}', 'active'),
  (t.id('c1'), :'off',  'Switched off',  'staff',  array['record_payments', 'issue_invoices'], 'disabled');
select pg_temp.centre('c2', :'o2', '{"mode":"fixed","percent_bp":5000,"taxable":false,"due":"with_first_invoice","waived_by":"issue_invoices"}', 12000);
select pg_temp.centre('c3', :'o3', '{"mode":"none","percent_bp":5000,"taxable":false,"due":"with_first_invoice","waived_by":"owner"}', 12000);
select pg_temp.centre('c4', :'o4', '{"mode":"percent_first_month","percent_bp":5000,"taxable":true,"due":"with_first_invoice","waived_by":"nobody"}', 0, false);
select t.put('solo_org', org_personal(:'solo'));
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('c2'), :'bill', 'Billing Bea', 'staff', array['issue_invoices'], 'active'),
  (t.id('c2'), :'paym', 'Payments Pat', 'staff', array['record_payments'], 'active'),
  (t.id('c4'), :'paym', 'Payments Pat', 'staff', array['record_payments'], 'active');
-- the two cancelled-charge lessons: Cal's held back; the rest is marked
select t.ok((select count(*) = 14 * 4 from lessons where org_id in (t.id('c1'), t.id('c2'), t.id('c3'), t.id('c4'))), 'the made-up world: 14 lessons in each of 4 centres');
set role authenticated;

-- ===================================================================== 1. PREVIEW: percent of the first month (50%), trial students and held-back families get none
create temp table p1 as select pg_temp.pv(t.id('c1'), :'o1') as j;
grant select on p1 to authenticated;
select t.ok((select j->>'deposit_mode' = 'percent_first_month' and j->>'deposit_note' is null from p1), 'the preview knows the deposit mode and has nothing to warn about');
select t.eq((select jsonb_array_length(j->'deposits') from p1), 3, 'three deposits would be raised: Amy, Ben and Dee');
select t.ok((select (d->>'amount_cents')::int = 10000 and (d->>'first_month_cents')::int = 20000 and (d->>'percent_bp')::int = 5000 and (d->>'taxable')::boolean = false and (d->>'frozen')::boolean = false
               from p1, lateral (select e d from jsonb_array_elements(j->'deposits') e where e->>'name' = 'Amy Aw') x), 'Amy: 50% of her S$200.00 first month = S$100.00; the free trial lesson is not counted');
select t.ok((select (d->>'amount_cents')::int = 5000 from p1, lateral (select e d from jsonb_array_elements(j->'deposits') e where e->>'name' = 'Ben Aw') x), 'Ben (her brother): 50% of S$100.00 = S$50.00, before any sibling discount');
select t.ok((select (d->>'amount_cents')::int = 7500 from p1, lateral (select e d from jsonb_array_elements(j->'deposits') e where e->>'name' = 'Dee Dee') x), 'Dee: 50% of S$150.00 = S$75.00');
select t.ok((select not exists (select 1 from jsonb_array_elements(j->'deposits') e where e->>'name' in ('Bea Bee', 'Cal Chee', 'Eli Eng')) from p1),
            'NO deposit for a trial student (Bea), for a family held back (Cal: charge pending) or for a student with no lessons (Eli)');
select t.eq((select (j#>>'{totals,deposits}')::int from p1), 3, 'the totals count them');
select t.eq((select (j#>>'{totals,deposit_cents}')::int from p1), 22500, 'and add them up (S$225.00); lesson totals are untouched');
select t.eq((select (j#>>'{totals,ready}')::int from p1), 2, 'the lesson invoices are unchanged: two families ready (Aw, Dee); Bee has only a free trial, Chee is held back');
select t.eq((select count(*) from centre_deposits where org_id = t.id('c1')), 0, 'the preview raised nothing');

-- ===================================================================== 2. CREATE DRAFTS: a separate "Refundable deposit" invoice, frozen, once
select pg_temp.run(t.id('c1'), :'o1');
select t.eq((select count(*) from centre_invoices where org_id = t.id('c1') and kind = 'deposit'), 3, 'three deposit invoices were drafted');
select t.ok((select bool_and(status = 'draft' and number_seq is null and number_text is null) from centre_invoices where org_id = t.id('c1') and kind = 'deposit'), 'they are drafts with no number yet');
select t.ok((select total_cents = 10000 and net_cents = 10000 and gst_cents = 0 and not gst_registered and student_id = t.id('c1_amy')
               and household_id = t.id('c1_hha') from centre_invoices where id = pg_temp.dinv('c1_amy')),
            'Amy''s deposit invoice: S$100.00, NO GST (the centre is GST-registered but a deposit is not taxable by default), for Amy in the Aw family');
select t.ok((select count(*) = 1 and bool_and(description = 'Refundable deposit' and unit_cents = 10000 and qty = 1) from centre_invoice_lines where invoice_id = pg_temp.dinv('c1_amy')),
            'one line, "Refundable deposit"');
select t.ok((select count(*) = 1 from centre_invoices where org_id = t.id('c1') and kind = 'lesson' and household_id = t.id('c1_hha')), 'the family''s lesson invoice is a different document');
select t.ok((select required_cents = 10000 and first_month_cents = 20000 and percent_bp = 5000 and mode = 'percent_first_month' and source = 'invoice_run' and not taxable
               and invoice_id = pg_temp.dinv('c1_amy') from centre_deposits where student_id = t.id('c1_amy')), 'the deposit row is frozen with the amount, the percent and the first month it came from');
select t.eq((select count(*) from centre_invoice_lines l join centre_invoices i on i.id = l.invoice_id where i.org_id = t.id('c1') and i.kind = 'deposit' and l.lesson_id is not null), 0, 'a deposit bills no lesson');
-- second run: nothing new
select t.ok((select (j->>'created')::int = 0 and (j->>'deposits')::int = 0 from (select pg_temp.run(t.id('c1'), :'o1') j) x), 'a second run adds nothing: no lesson draft, no deposit');
select t.eq((select count(*) from centre_invoices where org_id = t.id('c1') and kind = 'deposit'), 3, 'still three deposit invoices');
select t.eq((select count(*) from centre_deposits where org_id = t.id('c1')), 3, 'and three deposit rows');
select t.ok((select jsonb_array_length(j->'deposits') = 0 from (select pg_temp.pv(t.id('c1'), :'o1') j) x), 'the preview no longer offers them');

-- the invoice list shows them, marked
select t.ok((select count(*) filter (where r->>'kind' = 'deposit') = 3 and count(*) filter (where r->>'kind' = 'lesson') = 2
               from (select jsonb_array_elements(centre_invoice_list(t.id('c1'), (select m from td), null)->'rows') r) x), 'the month''s invoice list shows 2 lesson invoices and 3 deposit invoices, each marked with its kind');
select t.ok((select r->>'name' = 'Amy Aw' from (select jsonb_array_elements(centre_invoice_list(t.id('c1'), (select m from td), null)->'rows') r) x where r->>'kind' = 'deposit' order by r->>'name' limit 1), 'a deposit is listed under the student''s name');

-- approve: each family''s lesson invoice first, then its deposit invoices; one gap-free counter
create temp table ap as select pg_temp.approve(t.id('c1'), :'bill') as j;
select t.ok((select (j->>'issued')::int = 5 and (j->>'deposits')::int = 3 from ap), 'approve all issues 5 documents, 3 of them deposits');
select t.ok((select (select number_seq from centre_invoices where id = pg_temp.dinv('c1_amy')) = (select number_seq from centre_invoices where org_id = t.id('c1') and kind = 'lesson' and household_id = t.id('c1_hha')) + 1),
            'the Aw family''s deposit invoice follows its lesson invoice in the SAME number series');
select t.ok((select array_agg(number_seq order by number_seq) = array[1, 2, 3, 4, 5] from centre_invoices where org_id = t.id('c1') and status = 'issued' and kind <> 'credit_note'), 'numbers 1 to 5, no gap');
select t.ok((select due_date = issue_date + 7 and status = 'issued' from centre_invoices where id = pg_temp.dinv('c1_amy')), 'the deposit is due like any invoice (7 days)');
select pg_temp.refused(:'o1', format($q$ update centre_invoices set total_cents = 1, net_cents = 1 where id = %L $q$, pg_temp.dinv('c1_amy')), 'permission denied', 'a browser can''t change a deposit invoice');

-- ===================================================================== 3. LIABILITY, NOT REVENUE: held rises, revenue does not
select t.eq((pg_temp.held(t.id('c1'), :'o1')->>'total_held_cents')::int, 0, 'nothing is held until a deposit is paid');
select t.ok((select (j->>'invoiced_cents')::int = 32700 + 16350 and (j->>'gst_cents')::int = 2700 + 1350 and (j->>'invoices')::int = 2 and (j->>'deposits_invoiced_cents')::int = 22500
               from (select pg_temp.rev(t.id('c1'), :'rev') j) x), 'revenue counts the 2 lesson invoices only; the S$225.00 of deposit invoices is reported on its own line');
select pg_temp.pay(:'paym', t.id('c1'), t.id('c1_hha'), 10000, array[pg_temp.dinv('c1_amy')]);
select t.ok((select kind = 'received' and cents = 10000 and not taxable and entry_date = (select today from td) and invoice_id = pg_temp.dinv('c1_amy') and payment_id is not null and allocation_id is not null
               from centre_deposit_ledger where student_id = t.id('c1_amy')), 'paying the deposit invoice writes ONE ledger row "received", linked to the invoice, the payment and the allocation');
select t.eq((pg_temp.held(t.id('c1'), :'paym')->>'total_held_cents')::int, 10000, 'Deposits held: S$100.00');
select t.ok((select j->>'state' = 'held' and (j->>'held_cents')::int = 10000 and (j->>'short_cents')::int = 0 and j->>'invoice_number' like 'INV-%' from (select pg_temp.dep(t.id('c1'), :'paym', 'c1_amy') j) x), 'Amy''s deposit is "held", nothing short');
select t.ok((select (j->>'received_cents')::int = 0 and (j->>'deposits_received_cents')::int = 10000 and (j->>'deposits_held_cents')::int = 10000 and (j->>'invoiced_cents')::int = 32700 + 16350
               from (select pg_temp.rev(t.id('c1'), :'rev') j) x), 'revenue did NOT rise: cash received for fees is still S$0.00, the S$100.00 is a deposit received');
-- paying a lesson invoice is revenue
select pg_temp.pay(:'paym', t.id('c1'), t.id('c1_hha'), 21800, array[pg_temp.linv('c1_hha')]);
select t.ok((select (j->>'received_cents')::int = 21800 and (j->>'deposits_received_cents')::int = 10000 from (select pg_temp.rev(t.id('c1'), :'rev') j) x), 'fees received S$218.00 (revenue), deposits received S$100.00 (not revenue)');
select t.eq((select count(*) from centre_deposit_ledger where student_id = t.id('c1_amy')), 1, 'the fee payment wrote nothing to the deposit ledger');
-- part paid, short, overpayment on a deposit goes to family credit
select pg_temp.pay(:'paym', t.id('c1'), t.id('c1_hhd'), 3000, array[pg_temp.dinv('c1_dee')]);
select t.ok((select j->>'state' = 'part_paid' and (j->>'held_cents')::int = 3000 and (j->>'short_cents')::int = 4500 and (j->>'required_cents')::int = 7500 from (select pg_temp.dep(t.id('c1'), :'paym', 'c1_dee') j) x), 'Dee part-paid S$30.00 of S$75.00: "part_paid", short by S$45.00');
create temp table op as select pg_temp.pay(:'paym', t.id('c1'), t.id('c1_hhd'), 9000, array[pg_temp.dinv('c1_dee')]) as j;
select t.ok((select (j->>'excess_cents')::int = 4500 from op), 'a payment of S$90.00 on the remaining S$45.00: the extra S$45.00 is not put in the deposit');
select t.ok((select j->>'state' = 'held' and (j->>'held_cents')::int = 7500 from (select pg_temp.dep(t.id('c1'), :'paym', 'c1_dee') j) x), 'the deposit holds exactly its S$75.00');
select t.ok((select cents = 4500 and kind = 'overpayment' from centre_family_credit where household_id = t.id('c1_hhd')), 'the extra went to the family credit ledger (S3), never silently into the deposit');
-- reversing a payment un-receives it
create temp table rv as select (select id from centre_payments where org_id = t.id('c1') and household_id = t.id('c1_hhd') and amount_cents = 3000 and kind = 'payment') as pid;
select t.as(:'paym'); select centre_reverse_payment((select pid from rv), 'paid twice by mistake');
select t.ok((select count(*) filter (where kind = 'reversal' and cents = -3000) = 1 and sum(cents) = 4500 from centre_deposit_ledger where student_id = t.id('c1_dee')), 'reversing the S$30.00 payment writes a "reversal" row (-S$30.00): the ledger holds S$45.00');
select t.eq((select count(*) from centre_deposit_ledger where student_id = t.id('c1_dee') and kind = 'received'), 2, 'the original rows stay (append-only)');

-- ===================================================================== 4. FROZEN: fees change, the deposit does not
reset role;
update lessons set amount = 100, rate = 100 where org_id = t.id('c1') and student_id = t.id('c1_amy');
select pg_temp.mk(t.id('c1'), :'o1', t.id('c1_amy'), 3, 'done', null, null, 100, false, (select m2 from td) - 0);
set role authenticated;
select t.ok((select jsonb_array_length(j->'deposits') = 0 from (select pg_temp.pv(t.id('c1'), :'o1', (select m2 from td)) j) x), 'next month: Amy''s fee doubled, but no new deposit is offered');
select pg_temp.run(t.id('c1'), :'o1', (select m2 from td));
select t.ok((select required_cents = 10000 and first_month_cents = 20000 from centre_deposits where student_id = t.id('c1_amy')), 'the frozen amount (S$100.00 from S$200.00) never moves when the fee changes');
select t.eq((select count(*) from centre_invoices where org_id = t.id('c1') and kind = 'deposit'), 3, 'still one deposit invoice per student');
select pg_temp.refused(:'o1', format($q$ update centre_deposits set required_cents = 99999 where student_id = %L $q$, t.id('c1_amy')), 'permission denied', 'a browser can''t change a deposit amount');
reset role; select set_config('request.jwt.claims', '', false);
select t.fails(format($q$ update centre_deposits set required_cents = 99999 where student_id = %L $q$, t.id('c1_amy')), 'even the database refuses to change a frozen amount');
select t.fails(format($q$ update centre_deposit_ledger set cents = 1 where student_id = %L $q$, t.id('c1_amy')), 'the ledger is append-only: no update');
select t.fails(format($q$ delete from centre_deposit_ledger where student_id = %L $q$, t.id('c1_amy')), 'the ledger is append-only: no delete');
select t.fails(format($q$ delete from centre_deposits where student_id = %L $q$, t.id('c1_amy')), 'a deposit record can''t be deleted');
select t.fails(format($q$ insert into centre_deposit_ledger(org_id, student_id, deposit_id, kind, cents) select org_id, student_id, id, 'refunded', -20000 from centre_deposits where student_id = %L $q$, t.id('c1_amy')),
               'the ledger can''t go below zero (S$200.00 refund of a S$100.00 deposit)');
select t.fails(format($q$ insert into centre_deposit_ledger(org_id, student_id, deposit_id, kind, cents) select org_id, student_id, id, 'received', -5 from centre_deposits where student_id = %L $q$, t.id('c1_amy')),
               'a "received" row must be positive');
set role authenticated;

-- ===================================================================== 5. FIXED mode: the same S$120.00 for everyone with a non-trial lesson, whatever it costs
create temp table f1 as select pg_temp.pv(t.id('c2'), :'o2') as j;
select t.ok((select jsonb_array_length(j->'deposits') = 3 and not exists (select 1 from jsonb_array_elements(j->'deposits') e where (e->>'amount_cents')::int <> 12000 or e->>'mode' <> 'fixed')
               and (j#>>'{totals,deposit_cents}')::int = 36000 from f1), 'fixed S$120.00: Amy, Ben and Dee each get exactly S$120.00 whatever their lessons cost');
select t.ok((select not exists (select 1 from jsonb_array_elements(j->'deposits') e where e->>'name' in ('Bea Bee', 'Cal Chee')) from f1), 'Bea is a trial student and Cal''s family is held back: none');
select t.ok((select (e->>'percent_bp') is null from f1, lateral (select e from jsonb_array_elements(j->'deposits') e limit 1) x), 'a fixed deposit carries no percent');
select pg_temp.run(t.id('c2'), :'o2');
select t.ok((select mode = 'fixed' and required_cents = 12000 and percent_bp is null from centre_deposits where student_id = t.id('c2_amy')), 'the frozen row says fixed, S$120.00');
-- discard a deposit draft: it is raised again with the SAME frozen amount, whatever the setting says now
create temp table dd as select pg_temp.dinv('c2_amy') as inv;
select t.as(:'o2'); select centre_invoice_discard_draft((select inv from dd), 'sent to the wrong family');
select t.ok((select status = 'void' and number_text is null from centre_invoices where id = (select inv from dd)), 'a discarded deposit draft is void and never took a number');
select t.ok((select jsonb_array_length(j->'deposits') = 0 from (select pg_temp.pv(t.id('c2'), :'o2') j) x), 'with the lesson draft still there, the preview doesn''t offer it again yet');
select pg_temp.cfg(t.id('c2'), :'o2', '{billing,one_off_fees,deposit_cents}', '99900');
select t.ok((select jsonb_array_length(j->'deposits') = 0 from (select pg_temp.pv(t.id('c2'), :'o2') j) x), 'and changing the fixed amount doesn''t add one');
select t.ok((select (j->>'deposits')::int = 0 from (select pg_temp.run(t.id('c2'), :'o2') j) x), 'a run only raises a deposit alongside a READY lesson invoice (the family''s draft is already made)');
-- throw the family's lesson draft away too: the run makes both again, and Amy's deposit comes back at the frozen amount
select centre_invoice_discard_draft((select id from centre_invoices where org_id = t.id('c2') and kind = 'lesson' and household_id = t.id('c2_hha') and status = 'draft'), 'redo');
create temp table re as select pg_temp.pv(t.id('c2'), :'o2') as j;
select t.ok((select jsonb_array_length(j->'deposits') = 1 and j#>>'{deposits,0,name}' = 'Amy Aw' and (j#>>'{deposits,0,amount_cents}')::int = 12000 and (j#>>'{deposits,0,frozen}')::boolean from re),
            'Amy''s deposit is offered again at the FROZEN S$120.00, not the S$999.00 the setting says now');
select pg_temp.run(t.id('c2'), :'o2');
select t.ok((select required_cents = 12000 and invoice_id <> (select inv from dd) and invoice_id = pg_temp.dinv('c2_amy') from centre_deposits where student_id = t.id('c2_amy')), 'Amy''s deposit row now points at the new draft; its amount never moved');
select t.eq((select count(*) from centre_deposits where student_id = t.id('c2_amy')), 1, 'still one deposit row per student');
select t.eq((select count(*) from centre_invoices where student_id = t.id('c2_amy') and kind = 'deposit' and status <> 'void'), 1, 'one live deposit invoice per student');
select t.eq((select total_cents from centre_invoices where id = pg_temp.dinv('c2_dee')), 12000, 'Dee''s deposit was raised the first time at S$120.00 and is untouched');
select pg_temp.cfg(t.id('c2'), :'o2', '{billing,one_off_fees,deposit_cents}', '12000');

-- ===================================================================== 6. NONE, "before the first lesson" (coming soon), and a fixed S$0.00
select t.ok((select jsonb_array_length(j->'deposits') = 0 and j->>'deposit_note' is null and j->>'deposit_mode' = 'none' and (j#>>'{totals,ready}')::int = 2 from (select pg_temp.pv(t.id('c3'), :'o3') j) x), 'mode none: two families are ready, nothing is offered and nothing needs explaining');
select pg_temp.cfg(t.id('c3'), :'o3', '{billing,deposit}', '{"mode":"percent_first_month","percent_bp":5000,"taxable":false,"due":"before_first_lesson","waived_by":"owner"}');
select t.ok((select jsonb_array_length(j->'deposits') = 0 and j->>'deposit_note' like 'Deposits invoiced before the first lesson are coming soon%' and (j#>>'{totals,ready}')::int = 2 from (select pg_temp.pv(t.id('c3'), :'o3') j) x), '"before the first lesson" is coming soon: the preview says so and offers nothing');
select pg_temp.cfg(t.id('c3'), :'o3', '{billing,deposit}', '{"mode":"fixed","percent_bp":5000,"taxable":false,"due":"with_first_invoice","waived_by":"owner"}');
select pg_temp.cfg(t.id('c3'), :'o3', '{billing,one_off_fees,deposit_cents}', '0');
select t.ok((select jsonb_array_length(j->'deposits') = 0 and j->>'deposit_note' like 'The deposit is a fixed amount of S$0.00%' from (select pg_temp.pv(t.id('c3'), :'o3') j) x), 'fixed S$0.00: none raised, and the preview says why');
select pg_temp.cfg(t.id('c3'), :'o3', '{billing,deposit,mode}', '"none"');
select t.ok((select (j->>'created')::int = 2 and (j->>'deposits')::int = 0 from (select pg_temp.run(t.id('c3'), :'o3') j) x), 'mode none: the run makes the lesson invoices and no deposit');
select t.eq((select count(*) from centre_invoices where org_id = t.id('c3') and kind = 'deposit'), 0, 'no deposit invoice exists');
select t.eq((select count(*) from centre_deposits where org_id = t.id('c3')), 0, 'no deposit row exists');

-- ===================================================================== 7. TAXABLE flag: off by default; ON charges the centre's GST and marks every row; frozen when raised
create temp table t4 as select pg_temp.run(t.id('c4'), :'o4') as j;
select t.ok((select (j->>'deposits')::int = 3 and (j->>'deposits_issued')::int = 3 and (j->>'issued')::int = 2 from t4), 'centre without a review step: deposits are issued straight away, with the lessons');
select t.ok((select total_cents = 10900 and net_cents = 10000 and gst_cents = 900 and gst_registered and number_seq is not null from centre_invoices where id = pg_temp.dinv('c4_amy')),
            'taxable ON: the deposit carries the centre''s 9% GST (S$100.00 + S$9.00), numbered');
select t.ok((select taxable and required_cents = 10000 from centre_deposits where student_id = t.id('c4_amy')), 'the deposit row remembers it was taxable (required S$100.00 before GST)');
select pg_temp.cfg(t.id('c4'), :'o4', '{billing,deposit,taxable}', 'false');
select t.ok((select taxable from centre_deposits where student_id = t.id('c4_amy')), 'switching the setting off later does not rewrite a deposit already raised');
select pg_temp.pay(:'paym', t.id('c4'), t.id('c4_hha'), 10900, array[pg_temp.dinv('c4_amy')]);
select t.ok((select kind = 'received' and cents = 10900 and taxable from centre_deposit_ledger where student_id = t.id('c4_amy')), 'the ledger row is marked taxable, so the accountant can total the taxable part');
select t.ok((select (j->>'taxable_held_cents')::int = 10900 and (j->>'total_held_cents')::int = 10900 from (select pg_temp.held(t.id('c4'), :'paym') j) x), '"Deposits held" shows the taxable part separately');
select t.ok((select (j->>'invoiced_cents')::int = (select sum(total_cents) from centre_invoices where org_id = t.id('c4') and kind = 'lesson' and status = 'issued')
               and (j->>'gst_cents')::int = (select sum(gst_cents) from centre_invoices where org_id = t.id('c4') and status = 'issued') from (select pg_temp.rev(t.id('c4'), :'o4') j) x),
            'revenue leaves the deposit out, but the GST collected on a taxable deposit is still counted as GST');
-- waived_by nobody
select pg_temp.refused(:'o4', format($q$ select centre_deposit_waive(%L, 'family asked') $q$, t.id('c4_ben')), 'NOT_ALLOWED: this centre doesn''t allow deposits to be waived', 'waived_by = nobody: even the owner is refused');

-- ===================================================================== 8. WAIVE (waived_by = owner in c1; issue_invoices in c2)
select pg_temp.refused(:'o1', format($q$ select centre_deposit_waive(%L, null) $q$, t.id('c1_ben')), 'REASON_REQUIRED', 'a reason is always needed');
select pg_temp.refused(:'o1', format($q$ select centre_deposit_waive(%L, '   ') $q$, t.id('c1_ben')), 'REASON_REQUIRED', 'a blank reason is no reason');
select pg_temp.refused(:'bill', format($q$ select centre_deposit_waive(%L, 'staff discretion') $q$, t.id('c1_ben')), 'NOT_ALLOWED: only the centre owner', 'waived_by = owner: staff who issue invoices are refused');
select pg_temp.refused(:'paym', format($q$ select centre_deposit_waive(%L, 'staff discretion') $q$, t.id('c1_ben')), 'NOT_ALLOWED: only the centre owner', 'waived_by = owner: staff who record payments are refused');
select pg_temp.refused(:'o1', format($q$ select centre_deposit_waive(%L, 'x') $q$, t.id('c1_amy')), 'NOT_ALLOWED: the deposit is already paid in full', 'a deposit paid in full can''t be waived');
select pg_temp.refused(:'o1', format($q$ select centre_deposit_waive(%L, 'x') $q$, t.id('c1_eli')), 'NO_DEPOSIT', 'a student with no deposit has nothing to waive');
select t.as(:'o1');
create temp table wv as select centre_deposit_waive(t.id('c1_ben'), 'family on a hardship plan secret-reason-text') as j;
select t.ok((select (j->>'waived_cents')::int = 5000 and j->>'how' = 'credit_note' from wv), 'Ben''s issued, unpaid S$50.00 deposit is waived with a credit note for the whole S$50.00');
select t.ok((select count(*) = 1 and bool_and(total_cents = 5000 and status = 'issued' and number_text like 'CN-%') from centre_invoices where credits_invoice_id = pg_temp.dinv('c1_ben')), 'the credit note is a numbered S3 document (its own CN series)');
select t.ok((select j->>'state' = 'waived' and (j->>'waived_cents')::int = 5000 and (j->>'short_cents')::int = 0 and (j->>'held_cents')::int = 0 from (select pg_temp.dep(t.id('c1'), :'o1', 'c1_ben') j) x), 'the deposit shows as waived, nothing short, nothing held');
select t.ok((select kind = 'waived' and cents = 5000 and reason like 'family on a hardship%' from centre_deposit_ledger where student_id = t.id('c1_ben')), 'the ledger records the waiver and the reason');
select pg_temp.refused(:'o1', format($q$ select centre_deposit_waive(%L, 'again') $q$, t.id('c1_ben')), 'ALREADY_WAIVED', 'waiving twice is refused');
select t.ok((select (j->>'total_held_cents')::int = 10000 + 4500 from (select pg_temp.held(t.id('c1'), :'o1') j) x), 'a waiver is not cash: Deposits held is only what was received (Amy S$100.00 + Dee S$45.00)');
-- c2: waived_by issue_invoices; the invoices are still DRAFTS here (review is on)
select pg_temp.refused(:'paym', format($q$ select centre_deposit_waive(%L, 'x') $q$, t.id('c2_amy')), 'NOT_ALLOWED: only the owner or staff who issue invoices', 'waived_by = issue_invoices: staff who only record payments are refused');
select t.as(:'bill'); create temp table wv2 as select centre_deposit_waive(t.id('c2_amy'), 'staff child') as j;
select t.ok((select (j->>'waived_cents')::int = 12000 and j->>'how' = 'draft_discarded' from wv2), 'a deposit still in DRAFT is simply discarded when waived: S$120.00 waived');
select t.ok((select status = 'void' and number_text is null and void_reason like 'Deposit waived:%' from centre_invoices where id = (select id from centre_invoices where student_id = t.id('c2_amy') and kind = 'deposit' order by created_at desc limit 1)), 'the draft is voided, never numbered');
select t.ok((select next_number = 1 from org_counters where org_id = t.id('c2') and series = 'invoice') or not exists (select 1 from org_counters where org_id = t.id('c2')), 'no number was burned by waiving a draft');

-- part-paid then waived: only the unpaid rest is waived
select pg_temp.approve(t.id('c2'), :'o2');
select pg_temp.pay(:'paym', t.id('c2'), t.id('c2_hha'), 4000, array[pg_temp.dinv('c2_ben')]);
select t.as(:'bill'); create temp table wv3 as select centre_deposit_waive(t.id('c2_ben'), 'second child') as j;
select t.ok((select (j->>'waived_cents')::int = 8000 and j->>'how' = 'credit_note' from wv3), 'part-paid S$40.00 of S$120.00, then waived: the S$80.00 still unpaid is credited');
select t.ok((select j->>'state' = 'waived' and (j->>'held_cents')::int = 4000 and (j->>'waived_cents')::int = 8000 from (select pg_temp.dep(t.id('c2'), :'o2', 'c2_ben') j) x), 'the S$40.00 already received stays held; S$80.00 is waived');

-- ===================================================================== 9. OPENING BALANCE (owner only; a deposit collected before TutorDeck)
select pg_temp.refused(:'paym', format($q$ select centre_deposit_opening_balance(%L, 5000, current_date, null) $q$, t.id('c1_eli')), 'NOT_ALLOWED: your account can''t do that (only the centre owner can)', 'staff who record payments can''t record an opening balance');
select pg_temp.refused(:'bill', format($q$ select centre_deposit_opening_balance(%L, 5000, current_date, null) $q$, t.id('c1_eli')), 'NOT_ALLOWED', 'staff who issue invoices can''t either');
select pg_temp.refused(:'out',  format($q$ select centre_deposit_opening_balance(%L, 5000, current_date, null) $q$, t.id('c1_eli')), 'NOT_FOUND', 'a stranger gets NOT_FOUND');
select pg_temp.refused(:'o2',   format($q$ select centre_deposit_opening_balance(%L, 5000, current_date, null) $q$, t.id('c1_eli')), 'NOT_FOUND', 'another centre''s owner gets NOT_FOUND');
select pg_temp.refused(:'o1',   format($q$ select centre_deposit_opening_balance(%L, 0, current_date, null) $q$, t.id('c1_eli')), 'BAD_VALUE: the amount', 'zero is refused');
select pg_temp.refused(:'o1',   format($q$ select centre_deposit_opening_balance(%L, -5, current_date, null) $q$, t.id('c1_eli')), 'BAD_VALUE: the amount', 'a negative amount is refused');
select pg_temp.refused(:'o1',   format($q$ select centre_deposit_opening_balance(%L, 5000, current_date + 1, null) $q$, t.id('c1_eli')), 'BAD_VALUE: the date can''t be in the future', 'a future date is refused');
select pg_temp.refused(:'o1',   format($q$ select centre_deposit_opening_balance(%L, 5000, null, null) $q$, t.id('c1_eli')), 'BAD_VALUE: say the date', 'no date is refused');
select pg_temp.refused(:'o1',   format($q$ select centre_deposit_opening_balance(%L, 5000, current_date - 4000, null) $q$, t.id('c1_eli')), 'BAD_VALUE: that date is too far back', 'an absurd date is refused');
select pg_temp.refused(:'o1',   format($q$ select centre_deposit_opening_balance(%L, 5000, current_date, null) $q$, t.id('c1_amy')), 'ALREADY_HAS_DEPOSIT', 'a student who already has a deposit is refused');
select pg_temp.refused(:'o1',   format($q$ select centre_deposit_opening_balance(%L, 5000, current_date, null) $q$, t.id('c2_eli')), 'NOT_FOUND', 'a student of another centre is NOT_FOUND');
select pg_temp.refused(:'solo', format($q$ select centre_deposit_opening_balance(%L, 5000, current_date, null) $q$, t.id('c1_eli')), 'NOT_FOUND', 'a solo tutor is NOT_FOUND');
select t.as(:'o1'); select centre_deposit_opening_balance(t.id('c1_eli'), 15000, (select today from td) - 40, 'sheet 2025');
select t.ok((select source = 'opening_balance' and mode = 'opening' and required_cents = 15000 and invoice_id is null and not taxable from centre_deposits where student_id = t.id('c1_eli')), 'an opening balance is a deposit with no invoice');
select t.ok((select kind = 'opening_balance' and cents = 15000 and entry_date = (select today from td) - 40 and invoice_id is null and payment_id is null from centre_deposit_ledger where student_id = t.id('c1_eli')), 'one ledger row, dated when it was collected');
select t.eq((select count(*) from centre_invoices where student_id = t.id('c1_eli')), 0, 'no invoice was made and no number used');
select t.ok((select (j->>'total_held_cents')::int = 10000 + 4500 + 15000 and (j->>'students_holding')::int = 3 from (select pg_temp.held(t.id('c1'), :'o1') j) x), 'Deposits held: Amy S$100.00 + Dee S$45.00 + Eli S$150.00 = S$295.00, 3 students');
select t.ok((select (j->>'deposits_held_cents')::int = 29500 and (j->>'deposits_received_cents')::int = 10000 + 4500 from (select pg_temp.rev(t.id('c1'), :'rev') j) x), 'the revenue report shows the held total on its own line');
select pg_temp.refused(:'o1', format($q$ select centre_deposit_waive(%L, 'x') $q$, t.id('c1_eli')), 'NOT_ALLOWED: this deposit was collected before TutorDeck', 'an opening balance can''t be waived');
-- Eli now gets lessons: still no deposit invoice (the opening balance counts)
reset role; select pg_temp.mk(t.id('c1'), :'o1', t.id('c1_eli'), 3, 'done'); set role authenticated;
select t.ok((select jsonb_array_length(j->'deposits') = 0 from (select pg_temp.pv(t.id('c1'), :'o1') j) x), 'a student with an opening balance is never raised a second deposit');
select pg_temp.run(t.id('c1'), :'o1');
select t.eq((select count(*) from centre_invoices where student_id = t.id('c1_eli') and kind = 'deposit'), 0, 'and the run raises none');

-- ===================================================================== 10. the ledger screen's data, and who can read what
select t.as(:'paym');
create temp table lg as select centre_deposit_ledger_get(t.id('c1'), t.id('c1_dee')) as j;
select t.ok((select jsonb_array_length(j->'entries') = 3 and j#>>'{entries,0,kind}' = 'received' and (j#>>'{entries,2,balance_cents}')::int = 4500 from lg), 'Dee''s ledger: two receipts and a reversal, with a running balance ending at S$45.00');
select t.ok((select not (j::text ~* '(tutor_id|password|email|"rate")') from lg), 'the ledger carries no tutor id, email or rate');
-- who may read
select t.ok((select (centre_deposit_status(t.id('c1'))#>>'{totals,deposits}')::int = 4 from (select t.as(:'paym')) y), 'staff who record payments read the deposit status');
select t.ok((select (centre_deposits_held(t.id('c1'))->>'total_held_cents')::int = 29500 from (select t.as(:'rev')) y), 'staff with view_revenue read "Deposits held" too');
select t.ok((select (centre_deposits_held(t.id('c1'))->>'total_held_cents')::int = 29500 from (select t.as(:'o1')) y), 'the owner reads it');
select pg_temp.refused(:'bill', format($q$ select centre_deposit_status(%L) $q$, t.id('c1')), 'NOT_ALLOWED: your account can''t see deposits', 'staff who only issue invoices see no deposit ledger');
select pg_temp.refused(:'tut',  format($q$ select centre_deposit_status(%L) $q$, t.id('c1')), 'NOT_FOUND', 'a tutor reads nothing');
select pg_temp.refused(:'par',  format($q$ select centre_deposits_held(%L) $q$, t.id('c1')), 'NOT_FOUND', 'a parent reads nothing');
select pg_temp.refused(:'off',  format($q$ select centre_deposits_held(%L) $q$, t.id('c1')), 'NOT_FOUND', 'switched-off staff read nothing');
select pg_temp.refused(:'out',  format($q$ select centre_deposit_ledger_get(%L, %L) $q$, t.id('c1'), t.id('c1_amy')), 'NOT_FOUND', 'a stranger reads nothing');
select pg_temp.refused(:'o2',   format($q$ select centre_deposits_held(%L) $q$, t.id('c1')), 'NOT_FOUND', 'another centre''s owner can''t read this centre''s deposits');
select pg_temp.refused(:'o1',   format($q$ select centre_deposits_held(%L) $q$, t.id('c2')), 'NOT_FOUND', 'and this centre''s owner can''t read theirs');
select pg_temp.refused(:'o1',   format($q$ select centre_deposit_ledger_get(%L, %L) $q$, t.id('c1'), t.id('c2_amy')), 'NOT_FOUND', 'a student of another centre is not found in this centre''s ledger');
select pg_temp.refused(:'o1',   format($q$ select centre_deposit_waive(%L, 'x') $q$, t.id('c2_dee')), 'NOT_FOUND', 'waive: another centre''s student is NOT_FOUND');
select pg_temp.refused(:'solo', format($q$ select centre_deposit_status(%L) $q$, t.id('solo_org')), 'NOT_FOUND', 'a solo organisation has no deposits');
select pg_temp.refused(:'solo', format($q$ select centre_deposits_held(%L) $q$, t.id('c1')), 'NOT_FOUND', 'a solo tutor reads nothing');
select pg_temp.refused(:'solo', format($q$ select centre_deposit_waive(%L, 'x') $q$, t.id('c1_amy')), 'NOT_FOUND', 'a solo tutor can''t waive');
-- anonymous
set role anon;
select pg_temp.refused('', format($q$ select centre_deposits_held(%L) $q$, t.id('c1')), 'permission denied', 'anonymous callers have no access to the report');
select pg_temp.refused('', format($q$ select centre_deposit_waive(%L, 'x') $q$, t.id('c1_amy')), 'permission denied', 'nor to waive');
select pg_temp.refused('', format($q$ select centre_deposit_opening_balance(%L, 5, current_date, null) $q$, t.id('c1_amy')), 'permission denied', 'nor the opening balance');
reset role;
-- the tables: read by permission, written by nobody in a browser
set role authenticated; select t.as(:'tut');
select t.eq((select count(*) from centre_deposits), 0, 'a tutor reads no deposit row');
select t.eq((select count(*) from centre_deposit_ledger), 0, 'a tutor reads no ledger row');
select t.as(:'par'); select t.eq((select count(*) from centre_deposit_ledger) + (select count(*) from centre_deposits), 0, 'a parent reads none');
select t.as(:'bill'); select t.eq((select count(*) from centre_deposit_ledger) + (select count(*) from centre_deposits), 0, 'staff who only issue invoices read none');
select t.as(:'solo'); select t.eq((select count(*) from centre_deposit_ledger) + (select count(*) from centre_deposits), 0, 'a solo tutor reads none');
select t.as(:'o2'); select t.ok((select count(*) from centre_deposit_ledger where org_id = t.id('c1')) = 0, 'another centre''s owner reads none of this centre''s ledger');
select t.as(:'paym'); select t.ok((select count(*) > 0 from centre_deposit_ledger where org_id = t.id('c1')) and (select count(*) = 4 from centre_deposits where org_id = t.id('c1')), 'staff who record payments read their centre''s rows');
select pg_temp.refused(:'o1', format($q$ insert into centre_deposit_ledger(org_id, student_id, deposit_id, kind, cents) select org_id, student_id, id, 'received', 100 from centre_deposits where student_id = %L $q$, t.id('c1_amy')), 'permission denied', 'a browser can''t write the ledger');
select pg_temp.refused(:'o1', format($q$ insert into centre_deposits(org_id, student_id, source, mode, required_cents) values (%L, %L, 'opening_balance', 'opening', 100) $q$, t.id('c1'), t.id('c1_dee')), 'permission denied', 'nor a deposit row');
reset role;

-- ===================================================================== 11. cross-centre integrity at the table level
reset role; select set_config('request.jwt.claims', '', false);
select t.fails(format($q$ insert into centre_deposits(org_id, student_id, source, mode, required_cents) values (%L, %L, 'opening_balance', 'opening', 100) $q$, t.id('c2'), t.id('c1_dee')),
               'a deposit can''t point at a student of another centre');
select t.fails(format($q$ insert into centre_deposits(org_id, student_id, source, mode, required_cents) values (%L, %L, 'opening_balance', 'opening', 100) $q$, t.id('solo_org'), t.id('c1_dee')),
               'a solo organisation can''t hold deposits');
select t.fails(format($q$ insert into centre_deposit_ledger(org_id, student_id, deposit_id, kind, cents) select %L, %L, id, 'adjusted', 100 from centre_deposits where student_id = %L $q$, t.id('c2'), t.id('c1_amy'), t.id('c1_amy')),
               'a ledger row can''t mix two centres');
select t.fails(format($q$ insert into centre_deposit_ledger(org_id, student_id, deposit_id, kind, cents) select org_id, student_id, id, 'adjusted', 100 from centre_deposits where student_id = %L $q$, t.id('c1_amy')),
               'an adjustment needs a reason');

-- ===================================================================== 12. AUDIT: money rows are copied with free text redacted
select t.ok((select count(*) > 0 from audit_log where table_name = 'centre_deposit_ledger' and org_id = t.id('c1')), 'ledger rows are audited');
select t.ok((select count(*) > 0 from audit_log where table_name = 'centre_deposits' and org_id = t.id('c1')), 'deposit rows are audited');
select t.eq((select count(*) from audit_log where after::text like '%secret-reason-text%' or before::text like '%secret-reason-text%'), 0, 'the words typed as a waiver reason appear nowhere in the audit log');
select t.ok((select bool_and(after->>'reason' = '[redacted]') from audit_log where table_name = 'centre_deposit_ledger' and after->>'reason' is not null), 'ledger reasons are replaced by [redacted]');
select t.ok((select count(*) >= 3 from audit_log where action in ('centre_deposit_waive', 'centre_deposit_opening_balance') and org_id in (t.id('c1'), t.id('c2'))), 'each action leaves a summary row');
select t.ok((select not exists (select 1 from audit_log where action like 'centre_deposit%' and (after::text ~* '(secret|hardship|sheet 2025)')) ), 'the summary rows carry amounts and counts only, never free text');

-- ===================================================================== 13. OPENING INVOICES: keep the old number, never touch the counter
select t.ok((select next_number from org_counters where org_id = t.id('c1') and series = 'invoice') = 6, 'the counter stands at 6 (five numbers used in c1)');
create temp table ctr as select next_number as n from org_counters where org_id = t.id('c1') and series = 'invoice';
insert into centre_invoices(id, org_id, kind, household_id, student_id, imported_number, period_start, period_end, issue_date, due_date, net_cents, gst_cents, total_cents)
values ('00000000-0000-0000-0000-00000000bf01', t.id('c1'), 'opening', t.id('c1_hhd'), null, 'OLD-0042', '2025-11-01', '2025-11-30', '2025-12-01', '2025-12-08', 8000, 0, 8000);
insert into centre_invoice_lines(org_id, invoice_id, position, description, qty, unit_cents) values (t.id('c1'), '00000000-0000-0000-0000-00000000bf01', 1, 'Balance brought forward from the old system', 1, 8000);
select t.ok((select status = 'draft' and number_text is null and number_seq is null and imported_number = 'OLD-0042' from centre_invoices where id = '00000000-0000-0000-0000-00000000bf01'), 'an opening invoice starts as a draft with no number');
update centre_invoices set status = 'issued' where id = '00000000-0000-0000-0000-00000000bf01';
select t.ok((select number_text = 'OLD-0042' and number_seq is null and status = 'issued' and issue_date = '2025-12-01' and issued_at is not null from centre_invoices where id = '00000000-0000-0000-0000-00000000bf01'),
            'issued: it KEEPS its old number "OLD-0042", has no counter number and keeps its own date');
select t.eq((select next_number from org_counters where org_id = t.id('c1') and series = 'invoice'), (select n from ctr), 'the counter did not move');
select t.fails($q$ update centre_invoices set total_cents = 1, net_cents = 1 where id = '00000000-0000-0000-0000-00000000bf01' $q$, 'an issued opening invoice is immutable');
select t.fails($q$ insert into centre_invoices(org_id, kind, household_id, imported_number, net_cents, total_cents) select org_id, 'opening', household_id, 'OLD-0042', 100, 100 from centre_invoices where id = '00000000-0000-0000-0000-00000000bf01' $q$,
               'the same old number can''t be imported twice');
select t.fails(format($q$ insert into centre_invoices(org_id, kind, household_id, net_cents, total_cents) values (%L, 'opening', %L, 100, 100) $q$, t.id('c1'), t.id('c1_hhd')), 'an opening invoice must carry the number it already has');
select t.fails(format($q$ insert into centre_invoices(org_id, kind, household_id, imported_number, net_cents, total_cents) values (%L, 'lesson', %L, 'OLD-1', 100, 100) $q$, t.id('c1'), t.id('c1_hhd')), 'only an opening invoice may carry an imported number');
select t.fails(format($q$ insert into centre_invoices(org_id, kind, household_id, imported_number, net_cents, total_cents) values (%L, 'opening', %L, 'OLD-0043', 100, 100) $q$, t.id('solo_org'), t.id('c1_hhd')), 'a solo organisation can''t have one');
-- a normal invoice after it still gets the next counter number: gap-free
insert into centre_invoices(id, org_id, kind, household_id, period_start, period_end, net_cents, gst_cents, total_cents) values ('00000000-0000-0000-0000-00000000bf02', t.id('c1'), 'lesson', t.id('c1_hhd'), '2025-10-01', '2025-10-31', 1000, 0, 1000);
insert into centre_invoice_lines(org_id, invoice_id, position, description, qty, unit_cents) values (t.id('c1'), '00000000-0000-0000-0000-00000000bf02', 1, 'x', 1, 1000);
update centre_invoices set status = 'issued', gst_registered = false where id = '00000000-0000-0000-0000-00000000bf02';
select t.ok((select number_seq = (select n from ctr) and number_text = 'INV-' || (select n from ctr) from centre_invoices where id = '00000000-0000-0000-0000-00000000bf02'), 'the next normal invoice takes the next counter number: no gap, no clash with the opening one');
-- payable like any invoice
set role authenticated;
select t.ok((select (j->>'amount_cents')::int = 8000 from (select pg_temp.pay(:'paym', t.id('c1'), t.id('c1_hhd'), 8000, array['00000000-0000-0000-0000-00000000bf01'::uuid]) j) x), 'an opening invoice can be paid through the normal payment screen');
select t.ok((select (centre_invoice_account_get('00000000-0000-0000-0000-00000000bf01')->>'pay_status') = 'paid' from (select t.as(:'o1')) y), 'and then shows as paid');
select t.eq((select count(*) from centre_deposit_ledger where invoice_id = '00000000-0000-0000-0000-00000000bf01'), 0, 'a payment on a non-deposit invoice never touches the deposit ledger');
select t.ok((select (j->>'invoices')::int = 4 and (j->>'invoiced_cents')::int = 32700 + 16350 + 8000 + 1000
               from (select pg_temp.rev(t.id('c1'), :'rev') j) x), 'revenue counts the opening invoice like any other fee invoice (it is a fee the centre billed)');

-- ===================================================================== 14. students.start_date exists and is optional
select t.ok((select data_type = 'date' and is_nullable = 'YES' from information_schema.columns where table_schema = 'public' and table_name = 'students' and column_name = 'start_date'), 'students.start_date is a nullable date');
select t.ok((select count(*) = 0 from students where org_id = t.id('solo_org') and start_date is not null), 'solo tutors are unaffected');

select 'ALL DEPOSIT TESTS PASSED';
