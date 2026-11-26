-- T4 step S5 tests: centre refunds and family credit — refund a deposit (every value of billing.deposit.refund_approved_by: owner / staff / four_eyes; every
-- value of billing.deposit.release: refund_full / refund_less_unpaid / admin_decides; the forfeit notice rule; taxable and untaxed deposits), refund family
-- credit, apply credit to the next invoice, never over-refund, never a negative balance, double presses, permissions, append-only, audit, revenue.
-- Runs after centre_deposits_test.sql in the same throwaway database (reuses the t.* helpers). Builds its own centres and made-up people. All names are FAKE.
-- Prices: every lesson is 1 hour at 50 = 5000 cents. Each family has 2 lessons = S$100.00 + 9% GST = S$109.00 (10900 cents) per lesson invoice.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000ee01', 'rf.owner1@centre.test'), ('00000000-0000-0000-0000-00000000ee02', 'rf.paym@centre.test'),
  ('00000000-0000-0000-0000-00000000ee03', 'rf.bill@centre.test'),   ('00000000-0000-0000-0000-00000000ee04', 'rf.both@centre.test'),
  ('00000000-0000-0000-0000-00000000ee05', 'rf.rev@centre.test'),    ('00000000-0000-0000-0000-00000000ee06', 'rf.tutor@centre.test'),
  ('00000000-0000-0000-0000-00000000ee07', 'rf.parent@centre.test'), ('00000000-0000-0000-0000-00000000ee08', 'rf.off@centre.test'),
  ('00000000-0000-0000-0000-00000000ee09', 'rf.owner2@centre.test'), ('00000000-0000-0000-0000-00000000ee0a', 'rf.owner3@centre.test'),
  ('00000000-0000-0000-0000-00000000ee0b', 'rf.owner4@centre.test'), ('00000000-0000-0000-0000-00000000ee0c', 'rf.out@centre.test'),
  ('00000000-0000-0000-0000-00000000ee0d', 'rf.solo@centre.test');
\set o1 '00000000-0000-0000-0000-00000000ee01'
\set paym '00000000-0000-0000-0000-00000000ee02'
\set bill '00000000-0000-0000-0000-00000000ee03'
\set both '00000000-0000-0000-0000-00000000ee04'
\set rev '00000000-0000-0000-0000-00000000ee05'
\set tut '00000000-0000-0000-0000-00000000ee06'
\set par '00000000-0000-0000-0000-00000000ee07'
\set off '00000000-0000-0000-0000-00000000ee08'
\set o2 '00000000-0000-0000-0000-00000000ee09'
\set o3 '00000000-0000-0000-0000-00000000ee0a'
\set o4 '00000000-0000-0000-0000-00000000ee0b'
\set out '00000000-0000-0000-0000-00000000ee0c'
\set solo '00000000-0000-0000-0000-00000000ee0d'

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today, date_trunc('month', (now() at time zone 'Asia/Singapore')::date - interval '1 month')::date as m;
grant select on td to authenticated, anon;

create function pg_temp.settings(p_dep jsonb, p_fee bigint, p_gst boolean) returns jsonb language sql as $$
  select jsonb_set(jsonb_set(jsonb_set(jsonb_set(t.centre_settings(), '{profile,invoice_prefix}', '"INV"'), '{profile,gst_registered}', to_jsonb(p_gst)),
         '{billing}', jsonb_build_object('model', 'postpaid_lessons', 'deposit', p_dep, 'one_off_fees', jsonb_build_object('registration_cents', 0, 'deposit_cents', p_fee, 'materials_cents', 0),
                                          'absences', '{"mode":"charged","notice_hours":24}'::jsonb)),
         '{invoicing}', jsonb_build_object('grouping', 'family', 'due_days', 7, 'review_before_sending', true)) $$;
create function pg_temp.refused(p_user text, p_sql text, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  perform set_config('role', case when p_user = '' then 'anon' else 'authenticated' end, true);     -- the browser's role, for this one statement
  begin execute p_sql; exception when others then m := sqlerrm; end;
  perform set_config('role', 'postgres', true);
  if m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS refused: % (%)', p_msg, m;
end $$;
create function pg_temp.cnt(p_user text, p_sql text) returns bigint language plpgsql as $$
declare n bigint;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  perform set_config('role', 'authenticated', true);
  execute p_sql into n;
  perform set_config('role', 'postgres', true);
  return n;
end $$;
create function pg_temp.sc(p text) returns text language plpgsql security definer as $$ declare r text; begin execute p into r; return r; end $$;   -- read as the superuser
create function pg_temp.mk(p_org uuid, p_owner uuid, p_stu uuid, p_day int, p_status text, p_comp numeric default null) returns uuid language plpgsql as $$
declare lid uuid := gen_random_uuid();
begin
  insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, attendance, compensation, trial, subject)
  values (lid, p_owner, p_org, p_stu, (select m from td) + (p_day - 1), '16:00', '17:00', 50, 50, p_status, null, p_comp, false, 'Math');
  return lid;
end $$;
create function pg_temp.run(p_org uuid, p_user uuid) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_invoice_run_create_drafts(p_org, (select m from td)); end $$;
create function pg_temp.approve_all(p_org uuid, p_user uuid) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_invoice_approve_all(p_org, (select m from td)); end $$;
create function pg_temp.pay(p_user uuid, p_org uuid, p_hh uuid, p_amt bigint, p_ids uuid[] default null) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_record_payment(p_org, p_hh, 'cash', p_amt, (select today from td), null, p_ids, null, null); end $$;
create function pg_temp.dinv(p_student text) returns uuid language sql security definer as $$ select id from centre_invoices where student_id = t.id(p_student) and kind = 'deposit' and status = 'issued' limit 1 $$;
create function pg_temp.linv(p_student text) returns uuid language sql security definer as $$ select id from centre_invoices where student_id is not distinct from t.id(p_student) or household_id = (select household_id from students where id = t.id(p_student)) limit 0 $$;
create function pg_temp.hinv(p_student text) returns uuid language sql security definer as $$
  select i.id from centre_invoices i where i.kind = 'lesson' and i.status = 'issued' and i.household_id = (select household_id from students where id = t.id(p_student)) order by i.created_at limit 1 $$;
create function pg_temp.held(p_student text) returns bigint language sql security definer as $$ select coalesce(sum(cents) filter (where kind <> 'waived'), 0) from centre_deposit_ledger where student_id = t.id(p_student) $$;
create function pg_temp.credit(p_hh text) returns bigint language sql security definer as $$ select coalesce(sum(cents), 0) from centre_family_credit where household_id = t.id(p_hh) $$;
create function pg_temp.prop(p_user uuid, p_student text, p_notice date default null) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_deposit_release_proposal(t.id(p_student), p_notice); end $$;
create function pg_temp.dreq(p_user uuid, p_student text, p_refund bigint, p_forfeit bigint, p_setoff bigint, p_notice date default null, p_key text default null) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_deposit_refund_request(t.id(p_student), p_refund, p_forfeit, p_setoff, p_notice, 'Parent Pat', 'Left the centre', p_key); end $$;
create function pg_temp.creq(p_user uuid, p_org uuid, p_hh text, p_cents bigint, p_key text default null) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_credit_refund_request(p_org, t.id(p_hh), p_cents, 'Parent Pat', 'Paid twice', p_key); end $$;
create function pg_temp.appr(p_user uuid, p_refund uuid) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_refund_approve(p_refund, null); end $$;
create function pg_temp.pd(p_user uuid, p_refund uuid, p_ref text default 'DBS ending 6789') returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_refund_pay(p_refund, 'bank', (select today from td), p_ref, null); end $$;
create function pg_temp.rev(p_org uuid, p_user uuid) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_revenue_totals(p_org, null, null); end $$;
create function pg_temp.nref(p_org text) returns bigint language sql security definer as $$ select count(*) from centre_refunds where org_id = t.id(p_org) $$;

-- a centre with four students, each in their own family: amy, ben, cal, dee. Each family has one lesson invoice (S$109.00, UNPAID) and a PAID deposit invoice.
create function pg_temp.world(p_key text, p_owner uuid, p_dep jsonb, p_fee bigint, p_gst boolean) returns void language plpgsql as $$
declare org uuid; n text; sid uuid; hid uuid;
begin
  perform t.as(p_owner::text);
  set local role authenticated;
  org := org_create_centre('Refund Centre ' || p_key, pg_temp.settings(p_dep, p_fee, p_gst));
  reset role; perform set_config('request.jwt.claims', '', false);
  perform t.put(p_key, org);
  foreach n in array array['amy', 'ben', 'cal', 'dee'] loop
    hid := gen_random_uuid(); sid := gen_random_uuid();
    insert into households(id, org_id, name) values (hid, org, initcap(n) || ' Family');
    insert into students(id, tutor_id, org_id, name, household_id, created_at) values (sid, p_owner, org, initcap(n) || ' Test', hid, '2026-01-01');
    perform t.put(p_key || '_' || n, sid); perform t.put(p_key || '_h' || n, hid);
    perform pg_temp.mk(org, p_owner, sid, 3, 'done'); perform pg_temp.mk(org, p_owner, sid, 4, 'done');
  end loop;
end $$;
create function pg_temp.staff(p_key text) returns void language plpgsql as $$
begin
  insert into memberships(org_id, user_id, display_name, role, permissions, status) values
    (t.id(p_key), '00000000-0000-0000-0000-00000000ee02', 'Payments Pat', 'staff', array['record_payments'], 'active'),
    (t.id(p_key), '00000000-0000-0000-0000-00000000ee03', 'Billing Bea',  'staff', array['issue_invoices'], 'active'),
    (t.id(p_key), '00000000-0000-0000-0000-00000000ee04', 'Both Bo',      'staff', array['record_payments', 'issue_invoices'], 'active'),
    (t.id(p_key), '00000000-0000-0000-0000-00000000ee05', 'Revenue Rae',  'staff', array['view_revenue'], 'active'),
    (t.id(p_key), '00000000-0000-0000-0000-00000000ee06', 'Tutor Tia',    'tutor', '{}', 'active'),
    (t.id(p_key), '00000000-0000-0000-0000-00000000ee07', 'Parent Pia',   'parent', '{}', 'active'),
    (t.id(p_key), '00000000-0000-0000-0000-00000000ee08', 'Switched off', 'staff', array['record_payments', 'issue_invoices'], 'disabled');
end $$;
-- invoice run, approve, pay every deposit invoice in full
create function pg_temp.open_books(p_key text, p_owner uuid) returns void language plpgsql as $$
declare n text; amt bigint;
begin
  perform pg_temp.run(t.id(p_key), p_owner); perform pg_temp.approve_all(t.id(p_key), p_owner);
  foreach n in array array['amy', 'ben', 'cal', 'dee'] loop
    select total_cents into amt from centre_invoices where id = pg_temp.dinv(p_key || '_' || n);
    perform pg_temp.pay(p_owner, t.id(p_key), t.id(p_key || '_h' || n), amt, array[pg_temp.dinv(p_key || '_' || n)]);
  end loop;
  update students set end_date = (select today - 1 from td) where org_id = t.id(p_key) and id in (t.id(p_key || '_amy'), t.id(p_key || '_ben'), t.id(p_key || '_cal'));
end $$;
grant execute on all functions in schema pg_temp to public;

-- c1: approver OWNER, release refund_full, no forfeit.   c2: approver STAFF, release refund_less_unpaid, 14 days' notice, deposit S$120.00.
-- c3: approver FOUR_EYES, release admin_decides, deposit S$120.00.   c4: TAXABLE deposit (GST 9%), approver staff, refund_less_unpaid.
select pg_temp.world('c1', :'o1', '{"mode":"fixed","percent_bp":5000,"taxable":false,"due":"with_first_invoice","waived_by":"owner","release":"refund_full","forfeit_notice_days":0,"refund_approved_by":"owner"}', 6000, true);
select pg_temp.world('c2', :'o2', '{"mode":"fixed","percent_bp":5000,"taxable":false,"due":"with_first_invoice","waived_by":"issue_invoices","release":"refund_less_unpaid","forfeit_notice_days":14,"refund_approved_by":"staff"}', 12000, true);
select pg_temp.world('c3', :'o3', '{"mode":"fixed","percent_bp":5000,"taxable":false,"due":"with_first_invoice","waived_by":"owner","release":"admin_decides","forfeit_notice_days":0,"refund_approved_by":"four_eyes"}', 12000, true);
select pg_temp.world('c4', :'o4', '{"mode":"fixed","percent_bp":5000,"taxable":true,"due":"with_first_invoice","waived_by":"owner","release":"refund_less_unpaid","forfeit_notice_days":0,"refund_approved_by":"staff"}', 6000, true);
select pg_temp.staff('c1'); select pg_temp.staff('c2'); select pg_temp.staff('c3'); select pg_temp.staff('c4');
select t.put('solo_org', org_personal(:'solo'));
select pg_temp.open_books('c1', :'o1'); select pg_temp.open_books('c2', :'o2'); select pg_temp.open_books('c3', :'o3'); select pg_temp.open_books('c4', :'o4');
select t.ok((select count(*) = 4 * 4 from centre_deposits where org_id in (t.id('c1'), t.id('c2'), t.id('c3'), t.id('c4'))), 'the made-up world: a deposit for each of 4 students in 4 centres');
select t.eq(pg_temp.held('c1_amy'), 6000, 'c1: Amy''s deposit S$60.00 is held');
select t.eq(pg_temp.held('c2_amy'), 12000, 'c2: S$120.00 held');
select t.eq(pg_temp.held('c4_amy'), 6540, 'c4: a TAXABLE deposit of S$60.00 + 9% GST = S$65.40 is held');
select t.eq((select total_cents from centre_invoices where id = pg_temp.hinv('c1_amy')), 10900, 'every family''s lesson invoice is S$109.00 and still unpaid');

-- ===================================================================== 1. THE RELEASE PROPOSAL waits for the final invoice
select t.ok((select j->>'state' = 'waiting' and j->'waiting'->>0 like 'The student hasn''t been ended%' from (select pg_temp.prop(:'o1', 'c1_dee') j) x), 'a student who has not been ended: the proposal waits');
select t.ok((select j->>'state' = 'ready' and (j->>'held_cents')::int = 6000 and (j->>'available_cents')::int = 6000 and (j->>'unpaid_cents')::int = 10900 from (select pg_temp.prop(:'o1', 'c1_amy') j) x), 'Amy has ended and her final invoice is issued: ready, S$60.00 held, S$109.00 unpaid');
update students set end_date = (select today + 3 from td) where id = t.id('c1_dee');
select t.ok((select j->>'state' = 'waiting' and j->'waiting'->>0 like 'Lessons run until%' from (select pg_temp.prop(:'o1', 'c1_dee') j) x), 'lessons still run: the proposal waits and says until when');
-- two students with an opening deposit: Eve has a lesson that was not invoiced yet, Fay a cancelled lesson with no charge yet
do $$ declare e uuid := gen_random_uuid(); f uuid := gen_random_uuid(); he uuid := gen_random_uuid(); hf uuid := gen_random_uuid(); o uuid := '00000000-0000-0000-0000-00000000ee01';
begin
  insert into households(id, org_id, name) values (he, t.id('c1'), 'Eve Family'), (hf, t.id('c1'), 'Fay Family');
  insert into students(id, tutor_id, org_id, name, household_id, created_at, end_date) values
    (e, o, t.id('c1'), 'Eve Test', he, '2026-01-01', (select today - 1 from td)), (f, o, t.id('c1'), 'Fay Test', hf, '2026-01-01', (select today - 1 from td));
  perform t.put('c1_eve', e); perform t.put('c1_fay', f);
end $$;
select pg_temp.mk(t.id('c1'), :'o1', t.id('c1_eve'), 5, 'done');
select pg_temp.mk(t.id('c1'), :'o1', t.id('c1_fay'), 5, 'cancelled', null);
select t.as(:'o1');
select centre_deposit_opening_balance(t.id('c1_eve'), 5000, (select today - 30 from td), 'Collected before TutorDeck');
select centre_deposit_opening_balance(t.id('c1_fay'), 5000, (select today - 30 from td), 'Collected before TutorDeck');
select t.ok((select j->>'state' = 'waiting' and j->'waiting'->>0 like '1 lesson hasn''t been invoiced yet%' from (select pg_temp.prop(:'o1', 'c1_eve') j) x), 'a lesson that was not invoiced yet: the proposal waits for the invoice run');
select t.ok((select j->>'state' = 'waiting' and j->'waiting'->>0 like 'A cancelled lesson is still waiting for its charge%' from (select pg_temp.prop(:'o1', 'c1_fay') j) x), 'a cancelled lesson with no charge yet: the proposal waits for the charge');
select pg_temp.run(t.id('c1'), :'o1');
select t.ok((select j->>'state' = 'waiting' and j->'waiting'->>0 like 'An invoice for this family is still a draft%' from (select pg_temp.prop(:'o1', 'c1_eve') j) x), 'a draft final invoice: the proposal waits until it is issued');
select pg_temp.approve_all(t.id('c1'), :'o1');
select t.ok((select j->>'state' = 'ready' and (j->>'unpaid_cents')::int = 5450 from (select pg_temp.prop(:'o1', 'c1_eve') j) x), 'the final invoice is issued (S$54.50 unpaid): the proposal is ready');
select pg_temp.refused(:'o1', format($q$ select centre_deposit_refund_request(%L, 5000, 0, 0, null, 'Pat', 'Left', null) $q$, t.id('c1_fay')), 'NOT_READY', 'a refund can''t be asked for while the proposal is waiting');

-- ===================================================================== 2. refund_approved_by = OWNER (c1) + release = refund_full + a taxable-free deposit
select t.ok((select (j->'suggest'->>'refund_cents')::int = 6000 and (j->'suggest'->>'forfeit_cents')::int = 0 and (j->'suggest'->>'set_off_cents')::int = 0 and j->>'release_rule' = 'refund_full' and j->>'approver_rule' = 'owner'
               and (j->>'notice_short') is null from (select pg_temp.prop(:'o1', 'c1_amy') j) x), 'release refund_full suggests refunding the whole S$60.00, nothing kept, nothing set off (forfeit_notice_days 0: never forfeit)');
select t.ok((select (j->'suggest'->>'forfeit_cents')::int = 0 and not coalesce((j->>'notice_short')::boolean, false) from (select pg_temp.prop(:'o1', 'c1_amy', (select today from td)) j) x), 'with notice days 0 even leaving today never suggests keeping the deposit');
-- who may ASK: owner or issue_invoices only
select pg_temp.refused(:'paym', format($q$ select centre_deposit_refund_request(%L, 6000, 0, 0, null, 'Pat', 'Left', null) $q$, t.id('c1_amy')), 'NOT_ALLOWED', 'staff who only record payments can''t refund a deposit');
select pg_temp.refused(:'rev', format($q$ select centre_deposit_refund_request(%L, 6000, 0, 0, null, 'Pat', 'Left', null) $q$, t.id('c1_amy')), 'NOT_ALLOWED', 'view_revenue staff can''t either');
select pg_temp.refused(:'tut', format($q$ select centre_deposit_refund_request(%L, 6000, 0, 0, null, 'Pat', 'Left', null) $q$, t.id('c1_amy')), 'NOT_FOUND', 'a tutor gets NOT_FOUND');
select pg_temp.refused(:'par', format($q$ select centre_deposit_refund_request(%L, 6000, 0, 0, null, 'Pat', 'Left', null) $q$, t.id('c1_amy')), 'NOT_FOUND', 'a parent gets NOT_FOUND');
select pg_temp.refused(:'off', format($q$ select centre_deposit_refund_request(%L, 6000, 0, 0, null, 'Pat', 'Left', null) $q$, t.id('c1_amy')), 'NOT_FOUND', 'switched-off staff get NOT_FOUND');
select pg_temp.refused(:'out', format($q$ select centre_deposit_refund_request(%L, 6000, 0, 0, null, 'Pat', 'Left', null) $q$, t.id('c1_amy')), 'NOT_FOUND', 'a stranger gets NOT_FOUND');
select pg_temp.refused(:'o2', format($q$ select centre_deposit_refund_request(%L, 6000, 0, 0, null, 'Pat', 'Left', null) $q$, t.id('c1_amy')), 'NOT_FOUND', 'another centre''s owner gets NOT_FOUND');
select pg_temp.refused(:'solo', format($q$ select centre_deposit_refund_request(%L, 6000, 0, 0, null, 'Pat', 'Left', null) $q$, t.id('c1_amy')), 'NOT_FOUND', 'a solo tutor gets NOT_FOUND');
select pg_temp.refused(:'bill', format($q$ select centre_deposit_refund_request(%L, 6000, 0, 0, null, 'Pat', '  ', null) $q$, t.id('c1_amy')), 'REASON_REQUIRED', 'a reason is required');
select pg_temp.refused(:'bill', format($q$ select centre_deposit_refund_request(%L, 0, 0, 0, null, 'Pat', 'Left', null) $q$, t.id('c1_amy')), 'BAD_VALUE', 'a request for nothing is refused');
select pg_temp.refused(:'bill', format($q$ select centre_deposit_refund_request(%L, -1, 100, 0, null, 'Pat', 'Left', null) $q$, t.id('c1_amy')), 'BAD_VALUE', 'a negative amount is refused');
-- over-refunding is refused, to the cent
select pg_temp.refused(:'bill', format($q$ select centre_deposit_refund_request(%L, 6001, 0, 0, null, 'Pat', 'Left', null) $q$, t.id('c1_amy')), 'DEPOSIT_SHORT', 'S$60.01 of a S$60.00 deposit is refused');
select pg_temp.refused(:'bill', format($q$ select centre_deposit_refund_request(%L, 5000, 1001, 0, null, 'Pat', 'Left', null) $q$, t.id('c1_amy')), 'DEPOSIT_SHORT', 'refund + kept together can''t pass what is held either');
-- the request: reserved at once, immutable, nothing moved on the ledger yet
create temp table r1 as select pg_temp.dreq(:'bill', 'c1_amy', 6000, 0, 0, null, 'k-amy-1') as j;
select t.ok((select j->>'state' = 'requested' and (j->>'refund_cents')::int = 6000 and not (j->>'already')::boolean and j->>'requested_by_name' = 'Billing Bea' and j->>'release_rule' = 'refund_full'
               and (j->>'gst_cents')::int = 0 and not (j->>'taxable')::boolean from r1), 'Billing Bea asked for S$60.00: state "requested", no GST on an untaxed deposit');
select t.eq(pg_temp.held('c1_amy'), 6000, 'asking moves no money: the deposit ledger still holds S$60.00');
select t.ok((select (j->>'available_cents')::int = 0 and (j->>'reserved_cents')::int = 6000 and j->>'state' = 'open_refund' from (select pg_temp.prop(:'o1', 'c1_amy') j) x), 'but the S$60.00 is RESERVED: nothing is free to ask for again');
-- double press: same key, then no key with the same amounts, then different amounts
select t.ok((select (j->>'already')::boolean and j->>'id' = (select j->>'id' from r1) from (select pg_temp.dreq(:'bill', 'c1_amy', 6000, 0, 0, null, 'k-amy-1') j) x), 'pressing twice (same key) returns the same refund and writes nothing');
select t.ok((select (j->>'already')::boolean and j->>'id' = (select j->>'id' from r1) from (select pg_temp.dreq(:'bill', 'c1_amy', 6000, 0, 0, null, null) j) x), 'pressing twice without a key (same amounts) also does nothing twice');
select t.eq((select count(*) from centre_refunds where student_id = t.id('c1_amy')), 1, 'exactly ONE refund row exists');
select pg_temp.refused(:'bill', format($q$ select centre_deposit_refund_request(%L, 3000, 0, 0, null, 'Pat', 'Left', 'other-key') $q$, t.id('c1_amy')), 'OPEN_REFUND', 'a different request while one is open is refused');
select pg_temp.refused(:'bill', format($q$ select centre_deposit_refund_request(%L, 100, 0, 0, null, 'Pat', 'Left', 'k-amy-1') $q$, t.id('c1_amy')), 'BAD_VALUE', 'a key can''t be reused for something else');
-- immutable and append-only; browsers can't write
select pg_temp.refused(:'o1', format($q$ update centre_refunds set refund_cents = 1 where id = %L $q$, (select j->>'id' from r1)), 'permission denied', 'a browser can''t edit a refund');
select pg_temp.refused(:'o1', format($q$ insert into centre_refund_events(org_id, refund_id, kind, event_on) values (%L, %L, 'approved', current_date) $q$, t.id('c1'), (select j->>'id' from r1)), 'permission denied', 'a browser can''t write an event');
select pg_temp.refused(:'o1', format($q$ delete from centre_refunds where id = %L $q$, (select j->>'id' from r1)), 'permission denied', 'a browser can''t delete a refund');
select t.fails(format($q$ update centre_refunds set refund_cents = 1 where id = %L $q$, (select j->>'id' from r1)), 'even the database refuses to edit a refund row');
select t.fails(format($q$ delete from centre_refunds where id = %L $q$, (select j->>'id' from r1)), 'or delete one');
-- who may APPROVE under "owner": only the owner
select pg_temp.refused(:'paym', format($q$ select centre_refund_approve(%L, null) $q$, (select j->>'id' from r1)), 'NOT_ALLOWED', 'owner rule: staff who record payments can''t approve (and can''t even act on a deposit)');
select pg_temp.refused(:'bill', format($q$ select centre_refund_approve(%L, null) $q$, (select j->>'id' from r1)), 'NOT_ALLOWED: this centre lets only the owner approve', 'owner rule: even the person who asked can''t approve');
select pg_temp.refused(:'both', format($q$ select centre_refund_approve(%L, null) $q$, (select j->>'id' from r1)), 'NOT_ALLOWED: this centre lets only the owner approve', 'owner rule: staff with both permissions can''t approve');
select pg_temp.refused(:'tut', format($q$ select centre_refund_approve(%L, null) $q$, (select j->>'id' from r1)), 'NOT_FOUND', 'a tutor can''t approve (NOT_FOUND)');
select pg_temp.refused(:'o2', format($q$ select centre_refund_approve(%L, null) $q$, (select j->>'id' from r1)), 'NOT_FOUND', 'another centre''s owner can''t approve');
select pg_temp.refused(:'bill', format($q$ select centre_refund_pay(%L, 'bank', current_date, null, null) $q$, (select j->>'id' from r1)), 'NOT_APPROVED', 'a refund can''t be paid before it is approved');
select t.ok((select (j->>'can_approve')::boolean is false and (j->>'can_cancel')::boolean from (select pg_temp.dreq(:'bill', 'c1_amy', 6000, 0, 0, null, 'k-amy-1') j) x), 'the screen is told the requester can cancel but not approve');
select t.as(:'o1');
create temp table a1 as select centre_refund_approve((select (j->>'id')::uuid from r1), 'Checked the invoices') as j;
select t.ok((select j->>'state' = 'approved' and not (j->>'already')::boolean from a1), 'the owner approves');
select t.ok((select (centre_refund_approve((select (j->>'id')::uuid from r1), null)->>'already')::boolean), 'approving twice does nothing twice');
select t.eq((select count(*) from centre_refund_events where refund_id = (select (j->>'id')::uuid from r1) and kind = 'approved'), 1, 'one approval event');
select t.eq(pg_temp.held('c1_amy'), 6000, 'approval moves no money either');
-- pay: who, how, what's typed
select pg_temp.refused(:'paym', format($q$ select centre_refund_pay(%L, 'bank', current_date, 'x', null) $q$, (select j->>'id' from r1)), 'NOT_ALLOWED', 'record_payments alone can''t mark a DEPOSIT refund paid');
select pg_temp.refused(:'bill', format($q$ select centre_refund_pay(%L, 'barter', current_date, 'x', null) $q$, (select j->>'id' from r1)), 'BAD_VALUE', 'a real method is required');
select pg_temp.refused(:'bill', format($q$ select centre_refund_pay(%L, 'bank', null, 'x', null) $q$, (select j->>'id' from r1)), 'BAD_VALUE', 'a paid-on date is required');
select pg_temp.refused(:'bill', format($q$ select centre_refund_pay(%L, 'bank', current_date + 5, 'x', null) $q$, (select j->>'id' from r1)), 'BAD_VALUE', 'the paid-on date can''t be in the future');
select pg_temp.refused(:'bill', format($q$ select centre_refund_pay(%L, 'bank', (select today - 400 from td), 'x', null) $q$, (select j->>'id' from r1)), 'BAD_VALUE', 'or before the refund was asked for');
select pg_temp.refused(:'bill', format($q$ select centre_refund_pay(%L, 'bank', (select today from td), 'DBS 0123456789', null) $q$, (select j->>'id' from r1)), 'BAD_VALUE: don''t type a full bank', 'a full account number in the reference is refused (PDPA)');
select pg_temp.refused(:'bill', format($q$ select centre_refund_pay(%L, 'manual_paynow', (select today from td), '91234567', null) $q$, (select j->>'id' from r1)), 'BAD_VALUE: don''t type a full bank', 'so is a full PayNow mobile number');
select t.eq(pg_temp.held('c1_amy'), 6000, 'every refusal left the deposit untouched');
create temp table p1 as select pg_temp.pd(:'bill', (select (j->>'id')::uuid from r1)) as j;
select t.ok((select j->>'state' = 'paid' and not (j->>'already')::boolean from p1), 'paid');
select t.eq(pg_temp.held('c1_amy'), 0, 'the deposit ledger now holds nothing (S$60.00 refunded)');
select t.ok((select count(*) = 1 and bool_and(kind = 'refunded' and cents = -6000 and refund_id = (select (j->>'id')::uuid from r1)) from centre_deposit_ledger where student_id = t.id('c1_amy') and kind = 'refunded'), 'exactly one "refunded" row, linked to the refund');
select t.ok((select (pg_temp.pd(:'bill', (select (j->>'id')::uuid from r1))->>'already')::boolean), 'pressing "paid" twice answers "already"');
select t.eq((select count(*) from centre_deposit_ledger where student_id = t.id('c1_amy') and kind = 'refunded'), 1, 'and writes no second ledger row');
select t.eq((select count(*) from centre_refund_events where refund_id = (select (j->>'id')::uuid from r1)), 2, 'the trail is two events: approved, paid');
select pg_temp.refused(:'o1', format($q$ select centre_refund_cancel(%L, 'oops') $q$, (select j->>'id' from r1)), 'ALREADY_PAID', 'a paid refund can''t be cancelled');
select pg_temp.refused(:'bill', format($q$ select centre_deposit_refund_request(%L, 100, 0, 0, null, 'Pat', 'Left', null) $q$, t.id('c1_amy')), 'DEPOSIT_SHORT', 'nothing is held now: there is nothing to refund (never a negative balance)');
select t.ok((select j->>'state' = 'nothing_held' from (select pg_temp.prop(:'o1', 'c1_amy') j) x), 'the proposal says nothing is held');
select t.ok((select j->>'state' = 'paid' and j#>>'{events,1,method}' = 'bank' and j#>>'{events,1,reference}' = 'DBS ending 6789' and j#>>'{events,0,by}' = 'Rf Owner' is not null and jsonb_array_length(j->'events') = 2
               from (select centre_refund_statement((select (j->>'id')::uuid from r1)) j) x), 'the statement shows the trail: method, reference, two events');
select t.ok((select j->>'centre' like 'Refund Centre c1%' and j->>'payee' = 'Parent Pat' from (select centre_refund_statement((select (j->>'id')::uuid from r1)) j) x), 'and the centre and the payee');
-- revenue: the refund is reported, never revenue
select t.ok((select (j->>'deposits_refunded_cents')::int = 6000 and (j->>'deposits_held_cents')::int = 28000 and (j->>'refund_gst_cents')::int = 0 from (select pg_temp.rev(t.id('c1'), :'rev') j) x), 'revenue totals: S$60.00 of deposits refunded, S$280.00 still held (Ben, Cal, Dee S$60.00 each + Eve, Fay S$50.00 each), no GST given back');
select pg_temp.refused(:'tut', format($q$ select centre_refund_statement(%L) $q$, (select j->>'id' from r1)), 'NOT_FOUND', 'a tutor can''t read a statement');
select pg_temp.refused(:'rev', format($q$ select centre_refund_approve(%L, null) $q$, (select j->>'id' from r1)), 'NOT_ALLOWED', 'view_revenue staff can read but not act');
select t.ok((select jsonb_array_length(j->'rows') >= 1 from (select (select pg_temp.rev(t.id('c1'), :'rev')) is not null, centre_refund_list(t.id('c1'), null) j from (select t.as(:'rev')) z) x), 'view_revenue staff can read the list');

-- cancel: a requester can cancel their own open refund; it frees the reservation
create temp table r2 as select pg_temp.dreq(:'bill', 'c1_ben', 4000, 0, 0, null, 'k-ben-1') as j;
select pg_temp.refused(:'bill', format($q$ select centre_refund_cancel(%L, '  ') $q$, (select j->>'id' from r2)), 'REASON_REQUIRED', 'cancelling needs a reason');
select pg_temp.refused(:'both', format($q$ select centre_refund_cancel(%L, 'x') $q$, (select j->>'id' from r2)), 'NOT_ALLOWED', 'under the owner rule only the owner or the requester may cancel');
select t.as(:'bill');
select t.ok((select j->>'state' = 'cancelled' from (select centre_refund_cancel((select (j->>'id')::uuid from r2), 'Family changed their mind') j) x), 'the requester cancels (even after the owner approved)');
select t.ok((select (centre_refund_cancel((select (j->>'id')::uuid from r2), 'Family changed their mind')->>'already')::boolean), 'cancelling twice does nothing twice');
select pg_temp.refused(:'o1', format($q$ select centre_refund_approve(%L, null) $q$, (select j->>'id' from r2)), 'ALREADY_CANCELLED', 'a cancelled refund can''t be approved');
select pg_temp.refused(:'bill', format($q$ select centre_refund_pay(%L, 'bank', current_date, null, null) $q$, (select j->>'id' from r2)), 'ALREADY_CANCELLED', 'or paid');
select t.eq(pg_temp.held('c1_ben'), 6000, 'nothing moved when it was cancelled');
select t.ok((select j->>'state' = 'ready' and (j->>'available_cents')::int = 6000 from (select pg_temp.prop(:'o1', 'c1_ben') j) x), 'the reservation is released: the deposit is free to ask for again');

-- ===================================================================== 3. refund_approved_by = STAFF (c2) + release refund_less_unpaid + forfeit notice 14 days
select t.ok((select j->>'approver_rule' = 'staff' and j->>'release_rule' = 'refund_less_unpaid' and (j->>'notice_days')::int = 14 and (j->>'notice_needed')::boolean and (j->>'unpaid_cents')::int = 10900
               and j->>'note' like 'Type the day the family gave notice%' from (select pg_temp.prop(:'bill', 'c2_amy') j) x), 'c2: the rules show, and the screen is told to ask for the day notice was given');
select t.ok((select (j->>'notice_short')::boolean is false and (j->'suggest'->>'forfeit_cents')::int = 0 and (j->'suggest'->>'set_off_cents')::int = 10900 and (j->'suggest'->>'refund_cents')::int = 1100
               from (select pg_temp.prop(:'bill', 'c2_amy', (select today - 20 from td)) j) x), 'notice given 19 days before the last lesson day (not short): refund_less_unpaid suggests keeping S$109.00 against the unpaid invoice and refunding S$11.00');
select pg_temp.refused(:'bill', format($q$ select centre_deposit_release_proposal(%L, current_date + 3) $q$, t.id('c2_amy')), 'BAD_VALUE', 'a notice date in the future is refused');
select pg_temp.refused(:'bill', format($q$ select centre_deposit_refund_request(%L, 1100, 0, 10901, %L, 'Pat', 'Left', null) $q$, t.id('c2_amy'), (select today - 20 from td)), 'DEPOSIT_SHORT', 'too much in total is refused');
select pg_temp.refused(:'bill', format($q$ select centre_deposit_refund_request(%L, 0, 0, 10901, %L, 'Pat', 'Left', null) $q$, t.id('c2_amy'), (select today - 20 from td)), 'NOT_ALLOWED: the family owes only', 'keeping more than the family owes is refused');
create temp table r3 as select pg_temp.dreq(:'bill', 'c2_amy', 1100, 0, 10900, (select today - 20 from td), 'k-c2-amy') as j;
select t.ok((select j->>'state' = 'requested' and (j->>'set_off_cents')::int = 10900 and (j->>'forfeit_cents')::int = 0 and (j->>'notice_days')::int = 14 from r3), 'c2: asked for refund S$11.00 + S$109.00 kept against the invoice');
select t.eq(pg_temp.nref('c2'), 1, 'one refund row');
select pg_temp.refused(:'paym', format($q$ select centre_refund_approve(%L, null) $q$, (select j->>'id' from r3)), 'NOT_ALLOWED', 'staff rule: staff who only record payments still can''t approve a DEPOSIT refund (owner rule: owner or issue_invoices)');
create temp table a3 as select pg_temp.appr(:'bill', (select (j->>'id')::uuid from r3)) as j;
select t.ok((select j->>'state' = 'approved' from a3), 'staff rule: the person who asked CAN approve (a staff member who issues invoices)');
select t.eq((select balance_cents from centre_balance_rows(t.id('c2'), array[pg_temp.hinv('c2_amy')])), 10900, 'approving did not touch the invoice');
select t.eq((select balance_cents from centre_balance_rows(t.id('c2'), array[pg_temp.hinv('c2_amy')])), 10900, 'still S$109.00 owing before it is paid');
select t.ok((select (j->>'set_off_done_cents')::int = 10900 and j->>'state' = 'paid' from (select pg_temp.pd(:'both', (select (j->>'id')::uuid from r3), 'PayNow ending 4567') j) x), 'paying it: S$109.00 is kept against the invoice');
select t.eq((select balance_cents from centre_balance_rows(t.id('c2'), array[pg_temp.hinv('c2_amy')])), 0, 'the unpaid invoice is now PAID by the deposit');
select t.ok((select count(*) = 1 and bool_and(method = 'deposit' and amount_cents = 10900) from centre_payments where org_id = t.id('c2') and method = 'deposit'), 'through one internal payment of method "deposit"');
select t.ok((select array_agg(kind order by kind) = array['applied', 'received', 'refunded'] and sum(cents) = 0 from centre_deposit_ledger where student_id = t.id('c2_amy')), 'the deposit ledger: received 120.00, kept against fees 109.00, refunded 11.00: nothing left');
select t.eq(pg_temp.held('c2_amy'), 0, 'held is exactly zero, never below');
select t.ok((select (j->>'received_cents')::int = 10900 + 0 and (j->>'deposits_refunded_cents')::int = 1100 and (j->>'deposits_held_cents')::int = 12000 * 3 from (select pg_temp.rev(t.id('c2'), :'rev') j) x),
            'revenue: the deposit kept against fees counts as received fees (S$109.00); S$11.00 shows as refunded');
select pg_temp.refused(:'paym', format($q$ select centre_reverse_payment(%L, 'oops') $q$, (select id from centre_payments where org_id = t.id('c2') and method = 'deposit')), 'NOT_ALLOWED', 'a payment that moved deposit onto an invoice can''t be reversed (use Undo on the invoice instead; a credit note cannot give it back)');
-- short notice: the centre's rule suggests keeping the whole deposit; keeping is a refund of S$0.00 that completes when approved
select t.ok((select (j->>'notice_short')::boolean and (j->'suggest'->>'forfeit_cents')::int = 12000 and (j->'suggest'->>'set_off_cents')::int = 0 and (j->'suggest'->>'refund_cents')::int = 0 and j->>'note' like 'Less than 14 days%'
               from (select pg_temp.prop(:'bill', 'c2_ben', (select today - 6 from td)) j) x), 'notice given 5 days before the end: SHORT (14 needed): suggests keeping the whole S$120.00; the note warns a kept deposit becomes income');
select t.ok((select (j->>'notice_short')::boolean is false and (j->'suggest'->>'forfeit_cents')::int = 0 from (select pg_temp.prop(:'bill', 'c2_ben', (select today - 15 from td)) j) x), 'notice given exactly on the edge (14 days before the last lesson day: today-1-14 = today-15) is NOT short');
select t.ok((select (j->>'notice_short')::boolean is true from (select pg_temp.prop(:'bill', 'c2_ben', (select today - 14 from td)) j) x), 'one day less is short');
create temp table r4 as select pg_temp.dreq(:'bill', 'c2_ben', 0, 12000, 0, (select today - 6 from td), 'k-c2-ben') as j;
select t.ok((select j->>'state' = 'requested' and (j->>'forfeit_cents')::int = 12000 and (j->>'refund_cents')::int = 0 and (j->>'gst_cents')::int = 0 from r4), 'keeping the deposit is a request too');
select t.eq(pg_temp.held('c2_ben'), 12000, 'still held until approved');
create temp table a4 as select pg_temp.appr(:'o2', (select (j->>'id')::uuid from r4)) as j;
select t.ok((select j->>'state' = 'paid' and (j#>>'{events,1,kind}') = 'paid' and (j#>>'{events,1,method}') is null from a4), 'approving a kept deposit completes it at once (no cash to pay out): state paid, no method');
select t.eq(pg_temp.held('c2_ben'), 0, 'the ledger moved: held S$0.00');
select t.ok((select count(*) = 1 and bool_and(cents = -12000 and refund_id = (select (j->>'id')::uuid from r4)) from centre_deposit_ledger where student_id = t.id('c2_ben') and kind = 'forfeited'), 'one "forfeited" row');
select t.ok((select (j->>'deposits_forfeited_cents')::int = 12000 from (select pg_temp.rev(t.id('c2'), :'rev') j) x), 'revenue totals report S$120.00 kept, separately');
select t.ok((select (pg_temp.appr(:'o2', (select (j->>'id')::uuid from r4))->>'already')::boolean), 'approving it again does nothing twice');
select t.eq((select count(*) from centre_deposit_ledger where student_id = t.id('c2_ben') and kind = 'forfeited'), 1, 'and writes no second row');

-- ===================================================================== 4. refund_approved_by = FOUR_EYES (c3) + release = admin_decides
select t.ok((select j->'suggest' is null or jsonb_typeof(j->'suggest') = 'null' from (select pg_temp.prop(:'bill', 'c3_amy') j) x), 'admin_decides: no suggestion, the person types the amounts');
select t.ok((select j->>'approver_rule' = 'four_eyes' and j->>'release_rule' = 'admin_decides' and (j->>'available_cents')::int = 12000 from (select pg_temp.prop(:'bill', 'c3_amy') j) x), 'c3 rules show');
create temp table r5 as select pg_temp.dreq(:'bill', 'c3_amy', 5000, 1000, 0, null, 'k-c3-amy') as j;
select t.ok((select (j->>'refund_cents')::int = 5000 and (j->>'forfeit_cents')::int = 1000 from r5), 'the person typed their own split: refund S$50.00, keep S$10.00 (the rest stays held)');
select t.ok((select (j->>'available_cents')::int = 6000 from (select pg_temp.prop(:'bill', 'c3_amy') j) x), 'S$60.00 stays free: S$120.00 − S$60.00 reserved');
select pg_temp.refused(:'bill', format($q$ select centre_refund_approve(%L, null) $q$, (select j->>'id' from r5)), 'NOT_ALLOWED: a refund has to be approved by someone other', 'four_eyes: the person who asked can''t approve');
select pg_temp.refused(:'rev', format($q$ select centre_refund_approve(%L, null) $q$, (select j->>'id' from r5)), 'NOT_ALLOWED', 'four_eyes: view_revenue staff can''t');
select pg_temp.refused(:'paym', format($q$ select centre_refund_approve(%L, null) $q$, (select j->>'id' from r5)), 'NOT_ALLOWED', 'four_eyes: record_payments-only staff can''t approve a deposit');
select t.ok((select j->>'state' = 'approved' from (select pg_temp.appr(:'both', (select (j->>'id')::uuid from r5)) j) x), 'four_eyes: a different person (staff with issue_invoices) can');
select t.ok((select j->>'state' = 'paid' from (select pg_temp.pd(:'bill', (select (j->>'id')::uuid from r5), null) j) x), 'paid with no reference (optional)');
select t.eq(pg_temp.held('c3_amy'), 6000, 'S$120.00 − S$50.00 refunded − S$10.00 kept = S$60.00 still held');
-- the owner as REQUESTER under four_eyes can't approve their own request either
create temp table r6 as select pg_temp.dreq(:'o3', 'c3_ben', 12000, 0, 0, null, 'k-c3-ben') as j;
select pg_temp.refused(:'o3', format($q$ select centre_refund_approve(%L, null) $q$, (select j->>'id' from r6)), 'NOT_ALLOWED: a refund has to be approved by someone other', 'four_eyes applies to the owner too');
select t.ok((select j->>'state' = 'approved' from (select pg_temp.appr(:'bill', (select (j->>'id')::uuid from r6)) j) x), 'a staff member who issues invoices approves the owner''s request');
-- family credit under four_eyes
select pg_temp.pay(:'both', t.id('c3'), t.id('c3_hcal'), 15000, array[pg_temp.hinv('c3_cal')]);
select t.eq(pg_temp.credit('c3_hcal'), 4100, 'Cal''s family paid S$150.00 against S$109.00: S$41.00 is held as credit');
create temp table c1r as select pg_temp.creq(:'paym', t.id('c3'), 'c3_hcal', 4100, 'k-cr-1') as j;
select t.ok((select j->>'kind' = 'family_credit' and (j->>'refund_cents')::int = 4100 and j->>'state' = 'requested' from c1r), 'record_payments staff can ask to refund family credit');
select pg_temp.refused(:'paym', format($q$ select centre_refund_approve(%L, null) $q$, (select j->>'id' from c1r)), 'NOT_ALLOWED: a refund has to be approved by someone other', 'four_eyes: the requester can''t approve a credit refund');
select pg_temp.refused(:'bill', format($q$ select centre_refund_approve(%L, null) $q$, (select j->>'id' from c1r)), 'NOT_ALLOWED', 'issue_invoices alone can''t approve a CREDIT refund (needs record_payments)');
select t.ok((select j->>'state' = 'approved' from (select pg_temp.appr(:'both', (select (j->>'id')::uuid from c1r)) j) x), 'a different record_payments person can');
select pg_temp.refused(:'rev', format($q$ select centre_refund_pay(%L, 'bank', current_date, null, null) $q$, (select j->>'id' from c1r)), 'NOT_ALLOWED', 'view_revenue staff can''t mark it paid');
select pg_temp.refused(:'paym', format($q$ select centre_refund_pay(%L, 'bank', current_date, '98765432109', null) $q$, (select j->>'id' from c1r)), 'BAD_VALUE', 'full numbers are refused here too');
select t.ok((select j->>'state' = 'paid' from (select pg_temp.pd(:'paym', (select (j->>'id')::uuid from c1r)) j) x), 'paid');
select t.eq(pg_temp.credit('c3_hcal'), 0, 'the family credit is now S$0.00 (refunded)');
select t.ok((select kind = 'refund' and cents = -4100 and method = 'bank' and reference = 'DBS ending 6789' and refund_id = (select (j->>'id')::uuid from c1r) from centre_family_credit where household_id = t.id('c3_hcal') and kind = 'refund'), 'one "refund" row with the method and the reference');
select pg_temp.refused(:'paym', format($q$ select centre_credit_refund_request(%L, %L, 1, 'Pat', 'again', null) $q$, t.id('c3'), t.id('c3_hcal')), 'CREDIT_SHORT', 'no credit left: refused (never a negative balance)');

-- ===================================================================== 5. FAMILY CREDIT under OWNER (c1) and STAFF (c2): ask, approve, over-refund, double press
select pg_temp.pay(:'o1', t.id('c1'), t.id('c1_hcal'), 15000, array[pg_temp.hinv('c1_cal')]);
select t.eq(pg_temp.credit('c1_hcal'), 4100, 'c1: Cal''s family holds S$41.00');
select pg_temp.refused(:'tut', format($q$ select centre_credit_refund_request(%L, %L, 100, 'Pat', 'x', null) $q$, t.id('c1'), t.id('c1_hcal')), 'NOT_FOUND', 'a tutor can''t ask for a credit refund');
select pg_temp.refused(:'bill', format($q$ select centre_credit_refund_request(%L, %L, 100, 'Pat', 'x', null) $q$, t.id('c1'), t.id('c1_hcal')), 'NOT_ALLOWED', 'issue_invoices alone can''t refund family credit');
select pg_temp.refused(:'paym', format($q$ select centre_credit_refund_request(%L, %L, 4101, 'Pat', 'x', null) $q$, t.id('c1'), t.id('c1_hcal')), 'CREDIT_SHORT', 'S$41.01 of S$41.00 is refused');
select pg_temp.refused(:'paym', format($q$ select centre_credit_refund_request(%L, %L, 0, 'Pat', 'x', null) $q$, t.id('c1'), t.id('c1_hcal')), 'BAD_VALUE', 'a zero refund is refused');
select pg_temp.refused(:'paym', format($q$ select centre_credit_refund_request(%L, %L, 100, 'Pat', ' ', null) $q$, t.id('c1'), t.id('c1_hcal')), 'REASON_REQUIRED', 'a reason is required');
select pg_temp.refused(:'o2', format($q$ select centre_credit_refund_request(%L, %L, 100, 'Pat', 'x', null) $q$, t.id('c1'), t.id('c1_hcal')), 'NOT_FOUND', 'another centre''s owner can''t');
select pg_temp.refused(:'paym', format($q$ select centre_credit_refund_request(%L, %L, 100, 'Pat', 'x', null) $q$, t.id('c1'), t.id('c3_hcal')), 'NOT_FOUND', 'a family of another centre isn''t found');
create temp table c2r as select pg_temp.creq(:'paym', t.id('c1'), 'c1_hcal', 3000, 'k-cr-2') as j;
select t.ok((select (j->>'refund_cents')::int = 3000 and (j->>'held_cents')::int = 4100 from c2r), 'asked for S$30.00 of S$41.00');
select t.ok((select (j->>'already')::boolean and j->>'id' = (select j->>'id' from c2r) from (select pg_temp.creq(:'paym', t.id('c1'), 'c1_hcal', 3000, 'k-cr-2') j) x), 'pressing twice (same key) is the same refund');
select pg_temp.refused(:'paym', format($q$ select centre_credit_refund_request(%L, %L, 1101, 'Pat', 'x', 'k-cr-3') $q$, t.id('c1'), t.id('c1_hcal')), 'CREDIT_SHORT', 'only S$11.00 is free: the S$30.00 is reserved, so S$11.01 is refused');
select t.ok((select (j->>'available_cents')::int = 1100 and (j->>'reserved_cents')::int = 3000 and (j->>'balance_cents')::int = 4100 from (select centre_family_credit_status(t.id('c1'), t.id('c1_hcal')) j from (select t.as(:'paym')) z) x), 'the credit status shows held 41.00, reserved 30.00, available 11.00');
select pg_temp.refused(:'paym', format($q$ select centre_refund_approve(%L, null) $q$, (select j->>'id' from c2r)), 'NOT_ALLOWED: this centre lets only the owner approve', 'owner rule: the requester (record_payments) can''t approve');
select pg_temp.refused(:'both', format($q$ select centre_refund_approve(%L, null) $q$, (select j->>'id' from c2r)), 'NOT_ALLOWED: this centre lets only the owner approve', 'owner rule: nor can staff with both permissions');
select t.ok((select j->>'state' = 'approved' from (select pg_temp.appr(:'o1', (select (j->>'id')::uuid from c2r)) j) x), 'the owner approves');
select t.ok((select j->>'state' = 'paid' from (select pg_temp.pd(:'o1', (select (j->>'id')::uuid from c2r), 'PayNow ending 4567') j) x), 'and the owner marks it paid');
select t.eq(pg_temp.credit('c1_hcal'), 1100, 'S$41.00 − S$30.00 = S$11.00 left');
-- the old owner-only function now goes through the same steps
select pg_temp.refused(:'paym', format($q$ select centre_refund_family_credit(%L, %L, 100, 'bank', 'ref', 'x') $q$, t.id('c1'), t.id('c1_hcal')), 'NOT_ALLOWED', 'the old owner-only function still refuses staff');
select t.ok((select (j->>'refunded_cents')::int = 1100 and j->>'state' = 'paid' and (j->>'balance_cents')::int = 0 from (select centre_refund_family_credit(t.id('c1'), t.id('c1_hcal'), 1100, 'bank', 'DBS ending 6789', 'Refund to the family') j from (select t.as(:'o1')) z) x),
            'the old function = request + approve + pay in one go (owner rule): the credit is refunded and the refund is tracked');
select t.eq((select count(*) from centre_refunds where org_id = t.id('c1') and kind = 'family_credit'), 2, 'both credit refunds are on the list');
-- under the STAFF rule (c2) the same person asks and approves
select pg_temp.pay(:'o2', t.id('c2'), t.id('c2_hcal'), 15000, array[pg_temp.hinv('c2_cal')]);
create temp table c3r as select pg_temp.creq(:'paym', t.id('c2'), 'c2_hcal', 4100, 'k-cr-4') as j;
select t.ok((select j->>'state' = 'approved' from (select pg_temp.appr(:'paym', (select (j->>'id')::uuid from c3r)) j) x), 'staff rule: a record_payments person approves their own credit refund');
select t.ok((select j->>'state' = 'paid' from (select pg_temp.pd(:'paym', (select (j->>'id')::uuid from c3r)) j) x), 'and pays it');

-- ===================================================================== 6. APPLY credit to the next invoice (so no cash is refunded)
select pg_temp.pay(:'o1', t.id('c1'), t.id('c1_hdee'), 20000, array[pg_temp.hinv('c1_dee')]);
select t.eq(pg_temp.credit('c1_hdee'), 9100, 'c1: Dee''s family paid S$200.00 against S$109.00: S$91.00 credit');
-- Dee's NEXT invoice: another month's lessons, invoiced and issued
select pg_temp.mk(t.id('c1'), :'o1', t.id('c1_dee'), 10, 'done');
select t.as(:'o1');
select centre_invoice_run_create_drafts(t.id('c1'), (select m from td));
select centre_invoice_approve_all(t.id('c1'), (select m from td));
select t.ok((select count(*) = 2 from centre_invoices where org_id = t.id('c1') and household_id = t.id('c1_hdee') and kind = 'lesson' and status = 'issued'), 'Dee''s family now has a second issued invoice');
create temp table ap1 as select centre_family_credit_status(t.id('c1'), t.id('c1_hdee')) as j;
select t.ok((select jsonb_array_length(j->'open_invoices') = 1 and (j#>>'{open_invoices,0,balance_cents}')::int = 5450 and (j->>'available_cents')::int = 9100 from ap1), 'the credit status lists one open invoice (S$54.50) and S$91.00 available');
select pg_temp.refused(:'tut', format($q$ select centre_apply_family_credit(%L, %L, null, null, 'k') $q$, t.id('c1'), t.id('c1_hdee')), 'NOT_FOUND', 'a tutor can''t apply credit');
select pg_temp.refused(:'bill', format($q$ select centre_apply_family_credit(%L, %L, null, null, 'k') $q$, t.id('c1'), t.id('c1_hdee')), 'NOT_ALLOWED', 'issue_invoices alone can''t apply credit (record_payments does)');
select pg_temp.refused(:'paym', format($q$ select centre_apply_family_credit(%L, %L, array[%L]::uuid[], null, 'k') $q$, t.id('c1'), t.id('c1_hdee'), pg_temp.hinv('c1_amy')), 'NOT_ALLOWED', 'credit can''t pay another family''s invoice');
select pg_temp.refused(:'paym', format($q$ select centre_apply_family_credit(%L, %L, array[%L]::uuid[], null, 'k') $q$, t.id('c1'), t.id('c1_hdee'), pg_temp.dinv('c1_dee')), 'NOT_ALLOWED', 'or a deposit invoice');
select pg_temp.refused(:'paym', format($q$ select centre_apply_family_credit(%L, %L, null, 9101, 'k') $q$, t.id('c1'), t.id('c1_hdee')), 'CREDIT_SHORT', 'more than the family holds is refused');
select pg_temp.refused(:'paym', format($q$ select centre_apply_family_credit(%L, %L, null, 0, 'k') $q$, t.id('c1'), t.id('c1_hdee')), 'BAD_VALUE', 'zero is refused');
-- credit that is being refunded can't ALSO be applied
create temp table c4r as select pg_temp.creq(:'paym', t.id('c1'), 'c1_hdee', 4000, 'k-cr-5') as j;
select pg_temp.refused(:'paym', format($q$ select centre_apply_family_credit(%L, %L, null, 5101, 'k2') $q$, t.id('c1'), t.id('c1_hdee')), 'CREDIT_SHORT', 'S$40.00 is reserved for a refund, so only S$51.00 can be applied (S$51.01 refused)');
create temp table ap2 as select centre_apply_family_credit(t.id('c1'), t.id('c1_hdee'), null, null, 'k-apply-1') as j;
select t.ok((select not (j->>'already')::boolean and (j->>'applied_cents')::int = 5100 and (j->>'credit_balance_cents')::int = 4000 from ap2), 'applying with no amount pays what the invoice needs (S$54.50 owing, but only S$51.00 of credit is free): S$51.00 applied; S$40.00 stays held for the refund');
select t.ok((select (centre_apply_family_credit(t.id('c1'), t.id('c1_hdee'), null, null, 'k-apply-1')->>'already')::boolean), 'pressing twice (same key) does nothing twice');
select t.eq((select count(*) from centre_payments where org_id = t.id('c1') and method = 'family_credit'), 1, 'one internal payment');
select t.eq((select count(*) from centre_family_credit where org_id = t.id('c1') and kind = 'applied'), 1, 'one "applied" ledger row');
select t.eq(pg_temp.credit('c1_hdee'), 4000, 'the credit is S$40.00 (reserved for the refund)');
select pg_temp.refused(:'paym', format($q$ select centre_apply_family_credit(%L, %L, null, null, 'k-apply-2') $q$, t.id('c1'), t.id('c1_hdee')), 'CREDIT_SHORT', 'a second press with a new key finds no free credit: nothing happens');
select t.eq((select balance_cents from centre_balance_rows(t.id('c1'), array[(select id from centre_invoices where org_id = t.id('c1') and household_id = t.id('c1_hdee') and kind = 'lesson' and status = 'issued' order by issue_date desc, number_seq desc limit 1)])), 350, 'the invoice still owes S$3.50 (54.50 − 51.00)');
select pg_temp.refused(:'paym', format($q$ select centre_reverse_payment(%L, 'oops') $q$, (select id from centre_payments where org_id = t.id('c1') and method = 'family_credit')), 'NOT_ALLOWED', 'applied credit can''t be reversed (credit-note the invoice instead)');
-- the credit applied is NOT new cash: received_cents counts only real payments (not the moved credit), and not deposit invoices
select t.eq((pg_temp.rev(t.id('c1'), :'rev')->>'received_cents')::bigint,
  pg_temp.sc($s$ select coalesce(sum(case when p.method = 'family_credit' then 0 when p.kind = 'payment' then p.amount_cents else -p.amount_cents end), 0)
                   - coalesce((select sum(a.cents) from centre_payment_allocations a join centre_invoices i on i.id = a.invoice_id and i.kind = 'deposit' where a.org_id = p.org_id), 0)
                   from centre_payments p where p.org_id = $s$ || quote_literal(t.id('c1')) || $s$ group by p.org_id $s$)::bigint,
  'received cash leaves out the moved credit and the deposits (no double counting)');
-- cancel the credit refund: the credit is free again and can be applied to the rest
select t.as(:'o1');
select centre_refund_cancel((select (j->>'id')::uuid from c4r), 'Family prefers to keep it on account');
select t.ok((select (j->>'applied_cents')::int = 350 and (j->>'credit_balance_cents')::int = 3650 from (select centre_apply_family_credit(t.id('c1'), t.id('c1_hdee'), null, null, 'k-apply-3') j) x), 'after cancelling the refund the credit is free: S$3.50 more clears the invoice, S$36.50 stays on account');
select pg_temp.refused(:'paym', format($q$ select centre_apply_family_credit(%L, %L, null, null, 'k-apply-4') $q$, t.id('c1'), t.id('c1_hdee')), 'NOTHING_TO_APPLY', 'with no open invoice there is nothing to pay');

-- ===================================================================== 7. a TAXABLE deposit (c4): GST given back, no keeping against invoices, forfeits carry no extra GST
select t.ok((select (j->>'taxable')::boolean and (j->'suggest'->>'set_off_cents')::int = 0 and (j->'suggest'->>'refund_cents')::int = 6540 and j->>'note' like 'This deposit carried GST%' from (select pg_temp.prop(:'bill', 'c4_amy') j) x),
            'taxable + refund_less_unpaid: nothing is kept against invoices; the note says to refund it');
select pg_temp.refused(:'bill', format($q$ select centre_deposit_refund_request(%L, 0, 0, 6540, null, 'Pat', 'Left', null) $q$, t.id('c4_amy')), 'NOT_ALLOWED: this deposit carried GST', 'a taxable deposit can''t be kept against invoices');
create temp table gst0 as select pg_temp.rev(t.id('c4'), :'rev') as j;
create temp table r7 as select pg_temp.dreq(:'bill', 'c4_amy', 3270, 0, 0, null, 'k-c4-1') as j;
select t.ok((select (j->>'gst_cents')::int = 270 and (j->>'taxable')::boolean from r7), 'refunding S$32.70 of a taxable deposit gives back S$2.70 GST (32.70 − 32.70 ÷ 1.09 = 32.70 − 30.00)');
select pg_temp.appr(:'bill', (select (j->>'id')::uuid from r7));
select t.ok((select j->>'state' = 'paid' from (select pg_temp.pd(:'bill', (select (j->>'id')::uuid from r7)) j) x), 'approved (staff rule) and paid');
select t.eq(pg_temp.held('c4_amy'), 3270, 'S$32.70 of S$65.40 is left');
select t.ok((select (j->>'deposits_refunded_cents')::int = 3270 and (j->>'refund_gst_cents')::int = 270 and (j->>'gst_cents')::int = (select (j->>'gst_cents')::int from gst0) - 270 from (select pg_temp.rev(t.id('c4'), :'rev') j) x),
            'revenue totals: GST for the period fell by S$2.70 (given back) and the refund is reported');
create temp table r8 as select pg_temp.dreq(:'bill', 'c4_amy', 0, 3270, 0, null, 'k-c4-2') as j;
select t.ok((select (j->>'gst_cents')::int = 0 and (j->>'forfeit_cents')::int = 3270 from r8), 'keeping the rest of a taxable deposit adds no GST (it was charged when received)');
select t.ok((select j->>'state' = 'paid' from (select pg_temp.appr(:'bill', (select (j->>'id')::uuid from r8)) j) x), 'kept');
select t.ok((select (j->>'taxable_held_cents')::int = 6540 * 3 and (j->>'total_held_cents')::int = 6540 * 3 from (select centre_deposits_held(t.id('c4')) j from (select t.as(:'paym')) z) x), 'Deposits held: Amy is gone from the taxable total');
select t.ok((select bool_and(taxable) from centre_deposit_ledger where student_id = t.id('c4_amy')), 'every ledger row of a taxable deposit carries the taxable flag');
-- a taxable deposit paid in full (no GST registration at the time of refund doesn't change what was charged): the frozen rate is used
select t.ok((select gst_cents = 540 from centre_deposits d join centre_invoices i on i.id = d.invoice_id where d.student_id = t.id('c4_ben')), 'Ben''s taxable deposit invoice carried S$5.40 GST');
create temp table r9 as select pg_temp.dreq(:'bill', 'c4_ben', 6540, 0, 0, null, 'k-c4-3') as j;
select t.eq((select (j->>'gst_cents')::int from r9), 540, 'a full refund gives back the full S$5.40');

-- ===================================================================== 8. NOTHING IS EDITABLE; tutors and parents see nothing; anonymous callers are refused
select t.eq(pg_temp.cnt(:'tut', 'select count(*) from centre_refunds'), 0, 'a tutor reads no refund rows');
select t.eq(pg_temp.cnt(:'tut', 'select count(*) from centre_refund_events'), 0, 'a tutor reads no events');
select t.eq(pg_temp.cnt(:'par', 'select count(*) from centre_refunds'), 0, 'a parent reads no refund rows');
select t.eq(pg_temp.cnt(:'out', 'select count(*) from centre_refunds'), 0, 'a stranger reads none');
select t.eq(pg_temp.cnt(:'solo', 'select count(*) from centre_refunds'), 0, 'a solo tutor reads none');
select t.eq(pg_temp.cnt(:'off', 'select count(*) from centre_refunds'), 0, 'switched-off staff read none');
select t.ok(pg_temp.cnt(:'paym', format('select count(*) from centre_refunds where org_id = %L', t.id('c1'))) > 0, 'staff with record_payments can read their own centre''s refunds');
select t.eq(pg_temp.cnt(:'o2', format('select count(*) from centre_refunds where org_id = %L', t.id('c1'))), 0, 'but another centre''s owner can''t read them');
select pg_temp.refused(:'tut', format($q$ select centre_refund_list(%L, null) $q$, t.id('c1')), 'NOT_FOUND', 'a tutor can''t list refunds');
select pg_temp.refused(:'par', format($q$ select centre_family_credit_status(%L, %L) $q$, t.id('c1'), t.id('c1_hcal')), 'NOT_FOUND', 'a parent can''t read a family''s credit');
select pg_temp.refused(:'out', format($q$ select centre_deposit_release_proposal(%L) $q$, t.id('c1_amy')), 'NOT_FOUND', 'a stranger can''t read a release proposal');
select pg_temp.refused(:'paym', format($q$ select centre_refund_list(%L, 'weird') $q$, t.id('c1')), 'BAD_VALUE', 'an unknown filter is refused');
select t.ok((select jsonb_array_length(j->'rows') = (select count(*) from centre_refunds where org_id = t.id('c1')) from (select centre_refund_list(t.id('c1'), null) j) x), 'the list shows every refund of the centre');
select t.ok((select jsonb_array_length(j->'rows') = (select count(*) from centre_refunds r where r.org_id = t.id('c1') and centre_refund_state(r.id) in ('requested', 'approved')) from (select centre_refund_list(t.id('c1'), 'open') j) x), 'the open filter shows only requested and approved ones');
select pg_temp.refused('', format($q$ select centre_refund_list(%L, null) $q$, t.id('c1')), 'permission denied', 'an anonymous caller can''t list refunds');
select pg_temp.refused('', format($q$ select centre_refund_approve(%L, null) $q$, gen_random_uuid()), 'permission denied', 'or approve');
select pg_temp.refused('', format($q$ select centre_apply_family_credit(%L, %L, null, null, null) $q$, t.id('c1'), t.id('c1_hcal')), 'permission denied', 'or apply credit');
select pg_temp.refused('', format($q$ select centre_deposit_refund_request(%L, 1, 0, 0, null, 'x', 'y', null) $q$, t.id('c1_amy')), 'permission denied', 'or ask for a deposit refund');
select pg_temp.refused('', format($q$ select centre_refund_settle(null::centre_refunds, current_date, 'bank', current_date, null, null) $q$), 'permission denied', 'the internal settle function is not callable');
select pg_temp.refused('', format($q$ select centre_allocate_held(%L, %L, 'deposit', 100, null, null, current_date, null) $q$, t.id('c1'), t.id('c1_hcal')), 'permission denied', 'nor the internal allocator');
select pg_temp.refused(:'o1', format($q$ select centre_refund_settle(null::centre_refunds, current_date, 'bank', current_date, null, null) $q$), 'permission denied', 'a signed-in browser can''t call the settle function either');
select pg_temp.refused(:'o1', format($q$ select centre_allocate_held(%L, %L, 'deposit', 100, null, null, current_date, null) $q$, t.id('c1'), t.id('c1_hcal')), 'permission denied', 'nor allocate held money');

-- ===================================================================== 9. waiving a deposit needs the owner or issue_invoices (S4 rule, checked here for completeness)
select t.ok((select count(*) from pg_proc where proname = 'centre_deposit_waive') = 1, 'the waive function exists once');
select pg_temp.refused(:'paym', format($q$ select centre_deposit_waive(%L, 'x') $q$, t.id('c2_cal')), 'NOT_ALLOWED', 'c2 (waived_by issue_invoices): record_payments-only staff can''t waive');
select pg_temp.refused(:'bill', format($q$ select centre_deposit_waive(%L, 'x') $q$, t.id('c1_cal')), 'NOT_ALLOWED: only the centre owner', 'c1 (waived_by owner): issue_invoices staff can''t waive');

-- ===================================================================== 10. AUDIT: every step is audited with amounts only; the free text is redacted
select t.ok((select count(*) >= 1 from audit_log where org_id = t.id('c1') and action = 'centre_refund_request' and after->>'kind' = 'deposit'), 'the request is audited (summary row)');
select t.ok((select count(*) >= 1 from audit_log where org_id = t.id('c1') and action = 'centre_refund_approve'), 'the approval is audited');
select t.ok((select count(*) >= 1 from audit_log where org_id = t.id('c1') and action = 'centre_refund_paid'), 'the payment is audited');
select t.ok((select count(*) >= 1 from audit_log where org_id = t.id('c1') and action = 'centre_credit_apply'), 'applying credit is audited');
select t.ok((select count(*) >= 1 from audit_log where org_id = t.id('c1') and action = 'centre_refund_cancel'), 'the cancellation is audited');
select t.ok((select bool_and(after->>'reason' = '[redacted]' and after->>'payer_name' = '[redacted]') from audit_log where org_id = t.id('c1') and table_name = 'centre_refunds' and action = 'insert'),
            'the audit copy of a refund row hides the payee and the reason');
select t.ok((select bool_and(coalesce(after->>'reference', '[redacted]') = '[redacted]' and coalesce(after->>'note', '[redacted]') = '[redacted]') from audit_log where org_id = t.id('c1') and table_name = 'centre_refund_events' and action = 'insert'),
            'and the audit copy of an event hides the reference and note');
select t.ok(not exists (select 1 from audit_log where org_id in (t.id('c1'), t.id('c2'), t.id('c3'), t.id('c4')) and (after::text like '%DBS ending%' or after::text like '%Parent Pat%' or after::text like '%Left the centre%')),
            'no reference, payee or reason text appears anywhere in the audit log');
select t.fails(format($q$ update centre_refund_events set note = 'x' where refund_id = %L $q$, (select j->>'id' from r1)), 'an event can''t be edited, even by the database owner');
select t.fails(format($q$ delete from centre_refund_events where refund_id = %L $q$, (select j->>'id' from r1)), 'or deleted');
select t.fails(format($q$ insert into centre_refund_events(org_id, refund_id, kind, event_on) values (%L, %L, 'paid', current_date) $q$, t.id('c1'), (select j->>'id' from r1)), 'a finished refund can''t get another event');
select t.fails(format($q$ insert into centre_refund_events(org_id, refund_id, kind, event_on, reason) values (%L, %L, 'cancelled', current_date, 'x') $q$, t.id('c1'), (select j->>'id' from r6)), 'an event can''t name another centre''s refund');
select t.fails(format($q$ insert into centre_refunds(org_id, kind, household_id, refund_cents, held_cents, reason, requested_on) values (%L, 'family_credit', %L, 1, 1, 'x', current_date) $q$, t.id('solo_org'), t.id('c1_hamy')), 'a refund row can''t be written in a solo organisation');

-- ===================================================================== 11. ledger invariants after everything above: nothing is negative, nothing is over-refunded
select t.ok((select not exists (select 1 from (select student_id, sum(cents) filter (where kind <> 'waived') s from centre_deposit_ledger group by student_id) x where s < 0)), 'no student''s deposit is held below zero');
select t.ok((select not exists (select 1 from (select household_id, sum(cents) s from centre_family_credit group by household_id) x where s < 0)), 'no family''s credit is below zero');
select t.ok((select not exists (select 1 from centre_refunds r where centre_refund_state(r.id) = 'paid' and r.kind = 'deposit' and
              r.refund_cents <> coalesce((select -sum(cents) from centre_deposit_ledger l where l.refund_id = r.id and l.kind = 'refunded'), 0))), 'every paid deposit refund matches its ledger rows exactly');
select t.ok((select not exists (select 1 from centre_refunds r where centre_refund_state(r.id) = 'paid' and r.kind = 'family_credit' and
              r.refund_cents <> coalesce((select -sum(cents) from centre_family_credit l where l.refund_id = r.id and l.kind = 'refund'), 0))), 'and every paid credit refund matches its ledger row');
select t.ok((select not exists (select 1 from centre_refunds r where centre_refund_state(r.id) in ('requested', 'approved', 'cancelled') and
              exists (select 1 from centre_deposit_ledger l where l.refund_id = r.id) )), 'an unfinished or cancelled refund never touched a ledger');
select t.ok((select (select count(*) from centre_refunds r where kind = 'deposit' and centre_refund_state(r.id) = 'paid' and refund_cents = 0) = 2), 'two kept-deposit refunds completed at approval');

\echo T4 S5 refunds tests finished
