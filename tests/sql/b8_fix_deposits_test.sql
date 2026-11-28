-- B8-FIX F4 + F5 tests (db/migration_b8_fix.sql): a discarded deposit draft comes back (even when the lesson invoice stayed), a waived one does not;
-- a refunded deposit is "refunded", not "to collect".
-- Runs after migration_b8_fix.sql in the same throwaway database (reuses the t.* helpers). Made-up centre, made-up people. Prices: 1 hour at 50 = 5000 cents.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000e801', 'b8d.owner@centre.test'),   ('00000000-0000-0000-0000-00000000e802', 'b8d.payments@centre.test'),
  ('00000000-0000-0000-0000-00000000e803', 'b8d.billing@centre.test'), ('00000000-0000-0000-0000-00000000e804', 'b8d.revenue@centre.test'),
  ('00000000-0000-0000-0000-00000000e805', 'b8d.tutor@centre.test'),   ('00000000-0000-0000-0000-00000000e806', 'b8d.parent@centre.test'),
  ('00000000-0000-0000-0000-00000000e807', 'b8d.outsider@centre.test'), ('00000000-0000-0000-0000-00000000e808', 'b8d.off@centre.test'),
  ('00000000-0000-0000-0000-00000000e809', 'b8d.owner2@centre.test'),  ('00000000-0000-0000-0000-00000000e80a', 'b8d.owner3@centre.test'),
  ('00000000-0000-0000-0000-00000000e80b', 'b8d.owner4@centre.test'),  ('00000000-0000-0000-0000-00000000e80c', 'b8d.owner5@centre.test'),
  ('00000000-0000-0000-0000-00000000e80d', 'b8d.solo@centre.test');
\set o1 '00000000-0000-0000-0000-00000000e801'
\set paym '00000000-0000-0000-0000-00000000e802'
\set bill '00000000-0000-0000-0000-00000000e803'
\set rev '00000000-0000-0000-0000-00000000e804'
\set tut '00000000-0000-0000-0000-00000000e805'
\set par '00000000-0000-0000-0000-00000000e806'
\set out '00000000-0000-0000-0000-00000000e807'
\set off '00000000-0000-0000-0000-00000000e808'
\set o2 '00000000-0000-0000-0000-00000000e809'
\set o3 '00000000-0000-0000-0000-00000000e80a'
\set o4 '00000000-0000-0000-0000-00000000e80b'
\set o5 '00000000-0000-0000-0000-00000000e80c'
\set solo '00000000-0000-0000-0000-00000000e80d'

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

-- a deposit's row in the Deposits tab, and every deposit invoice (any status) of a student
create function pg_temp.dinvs(p_student text, p_status text default null) returns uuid language sql security definer as $$
  select id from centre_invoices where student_id = t.id(p_student) and kind = 'deposit' and (p_status is null or status = p_status) order by created_at desc limit 1 $$;
grant execute on function pg_temp.dinvs(text, text) to public;
create function pg_temp.ndraft(p_org uuid) returns int language sql security definer as $$ select count(*)::int from centre_invoices where org_id = p_org and kind = 'deposit' and status = 'draft' $$;
grant execute on function pg_temp.ndraft(uuid) to public;

create function pg_temp.dreq(p_user uuid, p_student text, p_refund bigint, p_forfeit bigint, p_setoff bigint) returns jsonb language plpgsql as $$
begin perform t.as(p_user::text); return centre_deposit_refund_request(t.id(p_student), p_refund, p_forfeit, p_setoff, null, 'Parent Pat', 'Left the centre', null); end $$;
grant execute on function pg_temp.dreq(uuid, text, bigint, bigint, bigint) to public;

-- a centre: deposit S$120.00 fixed, review before sending; three families (amy, ben, cal) with three 1-hour lessons each last month
create function pg_temp.world() returns void language plpgsql as $$
declare org uuid; s text; sid uuid; hid uuid;
begin
  perform t.as('00000000-0000-0000-0000-00000000e801');
  set local role authenticated;
  org := org_create_centre('B8 Deposit Centre', pg_temp.settings('{"mode":"fixed","percent_bp":5000,"taxable":false,"due":"with_first_invoice","waived_by":"owner"}'::jsonb, 12000, true));
  reset role; perform set_config('request.jwt.claims', '', false);
  perform t.put('b8', org);
  foreach s in array array['amy', 'ben', 'cal'] loop
    hid := gen_random_uuid(); sid := gen_random_uuid();
    insert into households(id, org_id, name) values (hid, org, initcap(s) || ' Family');
    insert into students(id, tutor_id, org_id, name, household_id, created_at) values (sid, '00000000-0000-0000-0000-00000000e801', org, initcap(s) || ' Test', hid, '2026-01-01');
    perform t.put('b8_' || s, sid); perform t.put('b8_hh' || s, hid);
    perform pg_temp.mk(org, '00000000-0000-0000-0000-00000000e801', sid, 3, 'done');
    perform pg_temp.mk(org, '00000000-0000-0000-0000-00000000e801', sid, 4, 'done');
    perform pg_temp.mk(org, '00000000-0000-0000-0000-00000000e801', sid, 5, 'done');
  end loop;
end $$;
select pg_temp.world();
set role authenticated;

-- ===================================================================== F4. a discarded deposit draft is raised again
create temp table r1 as select pg_temp.run(t.id('b8'), :'o1') as j;
grant select on r1 to authenticated;
select t.eq((select (j->>'created')::int from r1), 3, 'first run: three lesson drafts');
select t.eq((select (j->>'deposits')::int from r1), 3, 'first run: three deposit drafts');
select t.ok((select pg_temp.dep(t.id('b8'), :'o1', 'b8_amy')->>'state' = 'draft'), 'Amy''s deposit is a draft');
-- discard ONLY Amy's deposit draft (her lesson invoice stays: this is the stuck case)
select t.as(:'o1'); select centre_invoice_discard_draft(pg_temp.dinvs('b8_amy', 'draft'), 'wrong amount');
select t.ok((select pg_temp.dep(t.id('b8'), :'o1', 'b8_amy')->>'state' = 'discarded'), 'after Discard the Deposits tab says "discarded" (not "draft", not "Invoice not issued yet")');
select t.eq((select (pg_temp.dep(t.id('b8'), :'o1', 'b8_amy')->>'short_cents')::int), 0, 'a discarded deposit has nothing "to collect"');
create temp table p2 as select pg_temp.pv(t.id('b8'), :'o1') as j;
grant select on p2 to authenticated;
select t.eq((select jsonb_array_length(j->'deposits') from p2), 1, 'the preview offers the discarded deposit again, with her lesson invoice still a draft');
select t.ok((select j#>>'{deposits,0,name}' = 'Amy Test' and (j#>>'{deposits,0,amount_cents}')::int = 12000 and (j#>>'{deposits,0,frozen}')::boolean from p2), 'same frozen amount (S$120.00)');
select t.eq((select (j#>>'{totals,deposits}')::int from p2), 1, 'the totals count it (so the Create button appears)');
select t.eq((select (j#>>'{totals,ready}')::int from p2), 0, '... although no lesson invoice is ready');
create temp table r2 as select pg_temp.run(t.id('b8'), :'o1') as j;
grant select on r2 to authenticated;
select t.ok((select (j->>'deposits')::int = 1 and (j->>'created')::int = 0 from r2), 'the run raises just the deposit draft');
select t.ok((select pg_temp.dep(t.id('b8'), :'o1', 'b8_amy')->>'state' = 'draft'), 'Amy''s deposit is a draft again');
select t.eq((select count(*)::int from centre_deposits where org_id = t.id('b8') and student_id = t.id('b8_amy')), 1, 'still ONE deposit row for her (the same one, new invoice)');
select t.eq(pg_temp.ndraft(t.id('b8')), 3, 'three deposit drafts again');
select t.ok((select (j->>'deposits')::int = 0 from (select pg_temp.run(t.id('b8'), :'o1') j) x), 'running again adds nothing (no double deposit)');
-- the run explains nothing is "already there" for a student whose deposit is live
-- a WAIVED deposit does not come back: Ben's draft is waived (the invoice goes void), the run leaves him alone
select t.as(:'o1'); select centre_deposit_waive(t.id('b8_ben'), 'the centre waives it');
select t.ok((select pg_temp.dep(t.id('b8'), :'o1', 'b8_ben')->>'state' = 'waived'), 'Ben''s deposit is waived');
select t.ok((select not exists (select 1 from jsonb_array_elements(j->'deposits') e where e->>'name' = 'Ben Test') from (select pg_temp.pv(t.id('b8'), :'o1') j) x), 'a waived deposit is not offered again');
select t.ok((select (j->>'deposits')::int = 0 from (select pg_temp.run(t.id('b8'), :'o1') j) x), 'and the run does not raise it');
-- a student with a LIVE (issued) deposit invoice is not offered a second one
select t.as(:'o1'); select centre_invoice_approve_all(t.id('b8'), (select m from td));
select t.ok((select pg_temp.dep(t.id('b8'), :'o1', 'b8_amy')->>'state' = 'unpaid'), 'Amy''s deposit is issued and unpaid');
select t.ok((select (j->>'deposits')::int = 0 from (select pg_temp.run(t.id('b8'), :'o1') j) x), 'an issued deposit is never raised twice');

-- ===================================================================== F5. a refunded deposit is not "to collect"
create temp table pay1 as select pg_temp.pay(:'o1', t.id('b8'), t.id('b8_hhcal'), 12000, array[pg_temp.dinvs('b8_cal', 'issued')]) as j;
select t.ok((select pg_temp.dep(t.id('b8'), :'o1', 'b8_cal')->>'state' = 'held'), 'Cal paid the deposit: held');
select t.eq((select (pg_temp.dep(t.id('b8'), :'o1', 'b8_cal')->>'held_cents')::int), 12000, 'S$120.00 held');
reset role; update students set end_date = (select today - 1 from td) where id = t.id('b8_cal'); set role authenticated;   -- the refund needs the student to have left
create temp table rf as select pg_temp.dreq(:'o1', 'b8_cal', 12000, 0, 0) as j;
select t.as(:'o1'); select centre_refund_approve((select (j->>'id')::uuid from rf), null);
select t.ok((select pg_temp.dep(t.id('b8'), :'o1', 'b8_cal')->>'state' = 'held'), 'refund approved but not paid yet: still held');
select centre_refund_pay((select (j->>'id')::uuid from rf), 'bank', (select today from td), 'DBS ending 6789', null);
select t.ok((select pg_temp.dep(t.id('b8'), :'o1', 'b8_cal')->>'state' = 'refunded'), 'refund paid: the deposit is "refunded"');
select t.eq((select (pg_temp.dep(t.id('b8'), :'o1', 'b8_cal')->>'short_cents')::int), 0, 'nothing to collect on a refunded deposit');
select t.eq((select (pg_temp.dep(t.id('b8'), :'o1', 'b8_cal')->>'held_cents')::int), 0, 'nothing held either');
select t.ok((select (centre_deposit_status(t.id('b8'))#>>'{totals,short_cents}')::bigint = 12000 from (select 1) z), 'the tab total still counts only Amy''s unpaid S$120.00 (Cal''s refunded deposit adds nothing)');
select 'b8 deposits ok';
