-- T4 step S7 tests: centre tutor pay — effective-dated rates (default / level / student, inherit, none), every rate method (per lesson, per hour, per student,
-- monthly fixed, percentage of the fee with both bases), cancelled-lesson rules, classes, replacement tutors, "held until the parent pays" (taught vs
-- parent_paid, after_full vs pro_rata, part payments, GST, reversals, credit notes), the monthly pay list (carried over, paid, outstanding), adjustments,
-- recording and reversing payments, the freeze of paid periods, the three modes, the cut-off day, permissions (tutors NEVER see rates or pay), append-only, audit.
-- Runs after centre_credit_undo_test.sql in the same throwaway database (reuses the t.* helpers). All names are FAKE. Dates are relative to today so it keeps passing.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000f701', 'tp.owner@centre.test'),  ('00000000-0000-0000-0000-00000000f702', 'tp.pay@centre.test'),
  ('00000000-0000-0000-0000-00000000f703', 'tp.inv@centre.test'),    ('00000000-0000-0000-0000-00000000f704', 'tp.tia@centre.test'),
  ('00000000-0000-0000-0000-00000000f705', 'tp.tom@centre.test'),    ('00000000-0000-0000-0000-00000000f706', 'tp.tess@centre.test'),
  ('00000000-0000-0000-0000-00000000f707', 'tp.parent@centre.test'), ('00000000-0000-0000-0000-00000000f708', 'tp.off@centre.test'),
  ('00000000-0000-0000-0000-00000000f709', 'tp.owner2@centre.test'), ('00000000-0000-0000-0000-00000000f70a', 'tp.solo@centre.test'),
  ('00000000-0000-0000-0000-00000000f70b', 'tp.stranger@centre.test');
\set o1 '00000000-0000-0000-0000-00000000f701'
\set payer '00000000-0000-0000-0000-00000000f702'
\set invr '00000000-0000-0000-0000-00000000f703'
\set tia '00000000-0000-0000-0000-00000000f704'
\set tom '00000000-0000-0000-0000-00000000f705'
\set tess '00000000-0000-0000-0000-00000000f706'
\set par '00000000-0000-0000-0000-00000000f707'
\set off '00000000-0000-0000-0000-00000000f708'
\set o2 '00000000-0000-0000-0000-00000000f709'
\set solo '00000000-0000-0000-0000-00000000f70a'
\set stranger '00000000-0000-0000-0000-00000000f70b'

-- the first of the month 4 months ago: month 1 of the test (all lessons sit on days 1-27 so every month is long enough)
select date_trunc('month', current_date - interval '4 months')::date as m0 \gset
create temp table td as select :'m0'::date as m0;
grant select on td to authenticated, anon;
create function pg_temp.d1(n int) returns date language sql as $$ select (select m0 from td) + n $$;
create function pg_temp.d2(n int) returns date language sql as $$ select ((select m0 from td) + interval '1 month')::date + n $$;
create function pg_temp.d3(n int) returns date language sql as $$ select ((select m0 from td) + interval '2 months')::date + n $$;
create function pg_temp.m(n int) returns date language sql as $$ select ((select m0 from td) + make_interval(months => n))::date $$;   -- first of month n (0 = month 1)
create function pg_temp.eom(n int) returns date language sql as $$ select ((select m0 from td) + make_interval(months => n + 1))::date - 1 $$;

-- ------------------------------------------------------------------ helpers
-- a centre's settings: tutor pay options plus what else the tests change
create function pg_temp.base(p_tp jsonb, p_extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_set(t.centre_settings(), '{profile,gst_registered}', 'false') || jsonb_build_object(
    'billing', jsonb_build_object('model', 'postpaid_lessons', 'trials', jsonb_build_object('charged', coalesce((p_extra #>> '{trials}')::boolean, false))),
    'invoicing', jsonb_build_object('grouping', 'family', 'due_days', 7),
    'lessons', jsonb_build_object('class_type', coalesce(p_extra #>> '{class_type}', 'both')),
    'tutor_pay', jsonb_build_object('mode', 'full', 'payable_when', 'taught', 'rate_model', 'per_hour', 'percent_base', 'billed_after_discounts',
                 'part_payments', 'after_full', 'cancelled_lessons', 'pay_if_charged', 'group_count', 'attended', 'adjustments', true,
                 'cycle', jsonb_build_object('cutoff_day', 31, 'pay_day', 7)) || p_tp) $$;
-- a settings version for a centre: one row in force for every past lesson date and one in force today (so the screens' own "today" reads it too)
create function pg_temp.cfg(p_org uuid, p_tp jsonb, p_extra jsonb default '{}') returns void language plpgsql as $$
begin
  insert into org_settings(org_id, version, schema_version, effective_from, settings)
  values (p_org, (select coalesce(max(version), 0) + 1 from org_settings where org_id = p_org), 1, '2000-01-01', pg_temp.base(p_tp, p_extra));
  insert into org_settings(org_id, version, schema_version, effective_from, settings)
  values (p_org, (select coalesce(max(version), 0) + 1 from org_settings where org_id = p_org), 1, current_date, pg_temp.base(p_tp, p_extra));
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
-- the calculation as the owner of centre P sees it ("state:earn:released-before:released-to" for a labelled lesson)
create function pg_temp.r(p_label text, p_from date, p_to date) returns text language plpgsql security definer as $$
declare x record;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-00000000f701', 'role', 'authenticated')::text, false);
  select * into x from centre_tutor_pay_rows(t.id('P'), p_from, p_to) where lesson_id = t.id(p_label);
  perform set_config('request.jwt.claims', '', false);
  if x.lesson_id is null then return 'none'; end if;
  return x.state || ':' || coalesce(x.earn_cents::text, 'null') || ':' || x.released_before || ':' || x.released_to;
end $$;
create function pg_temp.o(p_sql text) returns jsonb language sql as $$ select pg_temp.call('00000000-0000-0000-0000-00000000f701', p_sql) $$;
grant execute on all functions in schema pg_temp to public;

-- ------------------------------------------------------------------ the centres
set role authenticated; select t.as(:'o1');
select t.put('P', org_create_centre('Pay Centre P', pg_temp.base('{}')));
select t.as(:'o2');
select t.put('Q', org_create_centre('Pay Centre Q', pg_temp.base('{}')));
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, display_name, role, permissions, status, employment_type) values
  (t.id('P'), :'payer', 'Payroll Pat', 'staff', array['run_tutor_pay'], 'active', null),
  (t.id('P'), :'invr',  'Invoices Ian', 'staff', array['issue_invoices', 'record_payments', 'view_revenue'], 'active', null),
  (t.id('P'), :'tia',   'Tutor Tia',    'tutor', '{}', 'active', 'employee'),
  (t.id('P'), :'tom',   'Tutor Tom',    'tutor', '{}', 'active', 'freelancer'),
  (t.id('P'), :'tess',  'Tutor Tess',   'tutor', '{}', 'active', 'freelancer'),
  (t.id('P'), :'par',   'Parent Pia',   'parent', '{}', 'active', null),
  (t.id('P'), :'off',   'Switched off', 'staff', array['run_tutor_pay'], 'disabled', null);
select t.put('Tia', id) from memberships where org_id = t.id('P') and user_id = :'tia';
select t.put('Tom', id) from memberships where org_id = t.id('P') and user_id = :'tom';
select t.put('Tess', id) from memberships where org_id = t.id('P') and user_id = :'tess';
select t.put('OwnerP', id) from memberships where org_id = t.id('P') and user_id = :'o1';
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
select pg_temp.world('P', 12, :'o1');
-- one lesson. p_amount in dollars (the lesson's price); the tutor is a membership label.
create function pg_temp.les(p_label text, p_stu int, p_tutor text, p_date date, p_mins int default 60, p_status text default 'done', p_att text default null,
  p_comp numeric default null, p_trial boolean default false, p_level text default null, p_sess uuid default null, p_amount numeric default 50, p_marked timestamptz default null) returns uuid language plpgsql as $$
declare i uuid := gen_random_uuid();
begin
  insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, attendance, compensation, trial, level, session_id, taught_by, attendance_marked_at)
  values (i, '00000000-0000-0000-0000-00000000f701', t.id('P'), t.id('P_s' || p_stu), p_date, '10:00', ('10:00'::time + make_interval(mins => p_mins)), 50, p_amount, p_status, p_att, p_comp, p_trial,
          p_level, p_sess, t.id(p_tutor), p_marked);
  perform t.put(p_label, i);
  return i;
end $$;
-- an issued lesson invoice for one family with one line per lesson (labels), optionally a sibling discount (negative cents, for a student), GST on/off
create function pg_temp.inv(p_label text, p_fam int, p_issue date, p_lessons text[], p_cents bigint[], p_disc_stu int default null, p_disc bigint default null, p_gst boolean default false) returns uuid language plpgsql as $$
declare i uuid := gen_random_uuid(); k int; sub bigint := 0; g bigint := 0;
begin
  insert into centre_invoices(id, org_id, kind, household_id, period_start, period_end) values (i, t.id('P'), 'lesson', t.id('P_h' || p_fam), date_trunc('month', p_issue)::date, p_issue);
  for k in 1 .. array_length(p_lessons, 1) loop
    insert into centre_invoice_lines(org_id, invoice_id, position, lesson_id, student_id, description, qty, unit_cents)
    values (t.id('P'), i, k, t.id(p_lessons[k]), (select student_id from lessons where id = t.id(p_lessons[k])), 'Lesson', 1, p_cents[k]);
    sub := sub + p_cents[k];
  end loop;
  if p_disc is not null then
    insert into centre_invoice_lines(org_id, invoice_id, position, student_id, fee_kind, description, qty, unit_cents)
    values (t.id('P'), i, 50, t.id('P_s' || p_disc_stu), 'sibling_discount', 'Sibling discount', 1, p_disc);
    sub := sub + p_disc;
  end if;
  if p_gst then g := centre_div_round(sub * 900, 10000); end if;
  update centre_invoices set status = 'issued', issue_date = p_issue, due_date = p_issue + 7, gst_registered = p_gst, gst_rate_bp = case when p_gst then 900 else 0 end,
         net_cents = sub, gst_cents = g, total_cents = sub + g where id = i;
  perform t.put(p_label, i);
  return i;
end $$;
create function pg_temp.pay(p_inv text, p_fam int, p_cents bigint, p_on date) returns uuid language plpgsql as $$
declare p uuid := gen_random_uuid();
begin
  insert into centre_payments(id, org_id, household_id, method, amount_cents, received_on) values (p, t.id('P'), t.id('P_h' || p_fam), 'cash', p_cents, p_on);
  insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (t.id('P'), p, t.id(p_inv), p_cents);
  return p;
end $$;
create function pg_temp.unpay(p_pay uuid, p_inv text, p_on date) returns void language plpgsql as $$
declare p centre_payments;
begin
  select * into p from centre_payments where id = p_pay;
  insert into centre_payments(id, org_id, kind, reverses_payment_id, household_id, method, amount_cents, received_on)
  values (gen_random_uuid(), t.id('P'), 'reversal', p_pay, p.household_id, p.method, p.amount_cents, p_on);
  insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents)
  select t.id('P'), r.id, t.id(p_inv), -p.amount_cents from centre_payments r where r.reverses_payment_id = p_pay;
end $$;
create function pg_temp.credit(p_inv text, p_cents bigint, p_on date) returns uuid language plpgsql as $$
declare c uuid := gen_random_uuid(); v centre_invoices;
begin
  select * into v from centre_invoices where id = t.id(p_inv);
  insert into centre_invoices(id, org_id, kind, household_id, student_id, credits_invoice_id, reason) values (c, t.id('P'), 'credit_note', v.household_id, v.student_id, v.id, 'Test credit');
  insert into centre_invoice_lines(org_id, invoice_id, position, description, qty, unit_cents) values (t.id('P'), c, 1, 'Credit', 1, p_cents);
  update centre_invoices set status = 'issued', issue_date = p_on, net_cents = p_cents, total_cents = p_cents where id = c;
  return c;
end $$;
-- rate as the owner: ('Tia', null student, null level, method, amount, percent, from, reason)
create function pg_temp.rate(p_tutor text, p_stu int, p_level text, p_method text, p_amount bigint, p_pct int, p_from date, p_reason text default 'Test rate') returns jsonb language sql as $$
  select pg_temp.o(format('select centre_tutor_rate_set(%L, %L, %L, %L, %L, %L, %L, %L, %L)', t.id('P'), t.id(p_tutor), case when p_stu is null then null else t.id('P_s' || p_stu) end,
                          p_level, p_method, p_amount, p_pct, p_from, p_reason)) $$;
grant execute on all functions in schema pg_temp to public;

-- ================================================================== 1. rates: validation and effective dates
select pg_temp.cfg(t.id('P'), '{}');
select pg_temp.rate('Tia', null, null, 'per_lesson', 4000, null, pg_temp.d1(0), 'Starting rate');
select t.ok((select count(*) = 1 from tutor_pay_rates where org_id = t.id('P')), 'a rate is stored as one row');
select pg_temp.refused(:'o1', format('select centre_tutor_rate_set(%L,%L,null,null,%L,4000,null,%L,%L)', t.id('P'), t.id('Tia'), 'per_lesson', pg_temp.d1(0), ''), 'REASON_REQUIRED', 'a rate needs a reason');
select pg_temp.refused(:'o1', format('select centre_tutor_rate_set(%L,%L,null,null,%L,null,10001,%L,%L)', t.id('P'), t.id('Tia'), 'percent_of_fee', pg_temp.d1(0), 'x'), 'BAD_RATE', 'a percentage above 100% is refused');
select pg_temp.refused(:'o1', format('select centre_tutor_rate_set(%L,%L,null,null,%L,4000,null,%L,%L)', t.id('P'), t.id('Tia'), 'percent_of_fee', pg_temp.d1(0), 'x'), 'BAD_RATE', 'a percentage rate with an amount is refused');
select pg_temp.refused(:'o1', format('select centre_tutor_rate_set(%L,%L,null,null,%L,null,500,%L,%L)', t.id('P'), t.id('Tia'), 'per_lesson', pg_temp.d1(0), 'x'), 'BAD_RATE', 'a fixed rate without an amount is refused');
select pg_temp.refused(:'o1', format('select centre_tutor_rate_set(%L,%L,null,null,%L,-1,null,%L,%L)', t.id('P'), t.id('Tia'), 'per_lesson', pg_temp.d1(0), 'x'), 'BAD_RATE', 'a negative amount is refused');
select pg_temp.refused(:'o1', format('select centre_tutor_rate_set(%L,%L,null,null,%L,100000001,null,%L,%L)', t.id('P'), t.id('Tia'), 'per_lesson', pg_temp.d1(0), 'x'), 'BAD_RATE', 'an absurd amount is refused');
select pg_temp.refused(:'o1', format('select centre_tutor_rate_set(%L,%L,null,null,%L,4000,null,%L,%L)', t.id('P'), t.id('Tia'), 'per_week', pg_temp.d1(0), 'x'), 'BAD_RATE', 'an unknown method is refused');
select pg_temp.refused(:'o1', format('select centre_tutor_rate_set(%L,%L,%L,%L,%L,4000,null,%L,%L)', t.id('P'), t.id('Tia'), t.id('P_s1'), 'Sec 3', 'per_lesson', pg_temp.d1(0), 'x'), 'BAD_RATE', 'a student and a level together are refused');
select pg_temp.refused(:'o1', format('select centre_tutor_rate_set(%L,%L,%L,null,%L,4000,null,%L,%L)', t.id('P'), t.id('Tia'), t.id('P_s1'), 'monthly_fixed', pg_temp.d1(0), 'x'), 'BAD_RATE', 'a monthly amount is for the tutor, not one student');
select pg_temp.refused(:'o1', format('select centre_tutor_rate_set(%L,%L,null,null,%L,null,null,%L,%L)', t.id('P'), t.id('Tia'), 'inherit', pg_temp.d1(0), 'x'), 'BAD_RATE', '"back to the usual rate" needs a student or level');
select pg_temp.refused(:'o1', format('select centre_tutor_rate_set(%L,%L,null,null,%L,4000,null,%L,%L)', t.id('P'), t.id('Tia'), 'per_lesson', current_date + 400, 'x'), 'BAD_RATE', 'a start date more than a year ahead is refused');
select pg_temp.refused(:'o1', format('select centre_tutor_rate_set(%L,%L,null,null,%L,4000,null,null,%L)', t.id('P'), t.id('Tia'), 'per_lesson', 'x'), 'BAD_RATE', 'a start date is needed');
select pg_temp.refused(:'o1', format('select centre_tutor_rate_set(%L,%L,null,null,%L,4000,null,%L,%L)', t.id('P'), gen_random_uuid(), 'per_lesson', pg_temp.d1(0), 'x'), 'NOT_FOUND', 'a made-up tutor is refused');
select pg_temp.refused(:'o1', format('select centre_tutor_rate_set(%L,%L,null,null,%L,4000,null,%L,%L)', t.id('P'), (select id from memberships where org_id = t.id('P') and role = 'parent'), 'per_lesson', pg_temp.d1(0), 'x'), 'NOT_FOUND', 'a parent can''t be given a rate');
select t.ok((select count(*) = 1 from tutor_pay_rates where org_id = t.id('P')), 'none of the refused rates was stored');

-- rate change mid-month: 4000 per lesson until the 9th, 5000 from the 10th. A later change never rewrites an earlier lesson.
select pg_temp.rate('Tia', null, null, 'per_lesson', 5000, null, pg_temp.d1(9), 'Annual review');
select pg_temp.les('A1', 1, 'Tia', pg_temp.d1(4));  select pg_temp.les('A2', 1, 'Tia', pg_temp.d1(9));  select pg_temp.les('A3', 1, 'Tia', pg_temp.d1(14));
select t.ok(pg_temp.r('A1', pg_temp.m(0), pg_temp.eom(0)) = 'payable:4000:0:4000', 'rate change: a lesson the day before the change keeps the old rate (4000)');
select t.ok(pg_temp.r('A2', pg_temp.m(0), pg_temp.eom(0)) = 'payable:5000:0:5000', 'rate change: a lesson ON the effective date gets the new rate (5000)');
select t.ok(pg_temp.r('A3', pg_temp.m(0), pg_temp.eom(0)) = 'payable:5000:0:5000', 'rate change: later lessons get the new rate');
-- a rate that starts later does not touch what was taught before it (and one dated in the future does nothing yet)
select pg_temp.rate('Tia', null, null, 'per_lesson', 9000, null, current_date + 30, 'Future raise');
select t.ok(pg_temp.r('A3', pg_temp.m(0), pg_temp.eom(0)) = 'payable:5000:0:5000', 'a rate dated in the future changes nothing taught before it');
-- same-day correction: the newest row wins
select pg_temp.rate('Tom', null, null, 'per_lesson', 1000, null, pg_temp.d1(0), 'Typo');
select pg_temp.rate('Tom', null, null, 'per_lesson', 3000, null, pg_temp.d1(0), 'Typo fixed');
select pg_temp.les('A4', 1, 'Tom', pg_temp.d1(5));
select t.ok(pg_temp.r('A4', pg_temp.m(0), pg_temp.eom(0)) = 'payable:3000:0:3000', 'two rates from the same day: the newest entry wins');
-- a lesson with no rate is not paid and says so
select pg_temp.les('A5', 1, 'Tess', pg_temp.d1(5));
select t.ok(pg_temp.r('A5', pg_temp.m(0), pg_temp.eom(0)) = 'no_rate:null:0:0', 'a tutor with no rate: state no_rate, nothing earned');
-- and a lesson before the rate existed has no rate either (the rate starts on its date)
select pg_temp.rate('Tess', null, null, 'per_lesson', 2500, null, pg_temp.d1(6));
select t.ok(pg_temp.r('A5', pg_temp.m(0), pg_temp.eom(0)) = 'no_rate:null:0:0', 'a lesson before the first rate began has no rate');
select pg_temp.les('A6', 1, 'Tess', pg_temp.d1(6));
select t.ok(pg_temp.r('A6', pg_temp.m(0), pg_temp.eom(0)) = 'payable:2500:0:2500', 'the first lesson on the first rate''s date is paid at it');

-- ================================================================== 2. per hour: minutes, half up
select pg_temp.rate('Tom', 2, null, 'per_hour', 6000, null, pg_temp.d1(0));                                -- Tom, student 2: S$60 an hour
select pg_temp.les('H90', 2, 'Tom', pg_temp.d1(3), 90);  select pg_temp.les('H45', 2, 'Tom', pg_temp.d1(4), 45);
select t.ok(pg_temp.r('H90', pg_temp.m(0), pg_temp.eom(0)) = 'payable:9000:0:9000', 'per hour: 90 minutes at S$60 = S$90');
select t.ok(pg_temp.r('H45', pg_temp.m(0), pg_temp.eom(0)) = 'payable:4500:0:4500', 'per hour: 45 minutes at S$60 = S$45');
select pg_temp.rate('Tom', 3, null, 'per_hour', 5001, null, pg_temp.d1(0));
select pg_temp.les('H50', 3, 'Tom', pg_temp.d1(5), 50);
select t.ok(pg_temp.r('H50', pg_temp.m(0), pg_temp.eom(0)) = 'payable:4168:0:4168', 'per hour: 50 minutes at 5001 per hour = 4167.5 rounds half up to 4168');

-- ================================================================== 3. student and level overrides, inherit, none
select pg_temp.rate('Tia', null, 'Sec 3', 'per_lesson', 7000, null, pg_temp.d1(0), 'Level rate');
select pg_temp.rate('Tia', 4, null, 'per_lesson', 9500, null, pg_temp.d1(0), 'Student rate');
select pg_temp.les('O1', 4, 'Tia', pg_temp.d1(7), 60, 'done', null, null, false, 'Sec 3');           -- student 4 has a student rate (beats the level's)
select pg_temp.les('O2', 5, 'Tia', pg_temp.d1(7), 60, 'done', null, null, false, 'sec 3');           -- student 5: the level rate (case does not matter)
select pg_temp.les('O3', 6, 'Tia', pg_temp.d1(10), 60, 'done', null, null, false, 'Pri 5');          -- student 6: the tutor's default (5000 from the 10th)
select t.ok(pg_temp.r('O1', pg_temp.m(0), pg_temp.eom(0)) = 'payable:9500:0:9500', 'a student rate beats the level rate');
select t.ok(pg_temp.r('O2', pg_temp.m(0), pg_temp.eom(0)) = 'payable:7000:0:7000', 'a level rate beats the default (level names match whatever the capitals)');
select t.ok(pg_temp.r('O3', pg_temp.m(0), pg_temp.eom(0)) = 'payable:5000:0:5000', 'no override: the tutor''s default');
-- "back to the usual rate" for the student from the 20th: earlier lessons keep 9500, later ones follow the level (Sec 3) rate
select pg_temp.rate('Tia', 4, null, 'inherit', null, null, pg_temp.d1(20), 'Back to level rate');
select pg_temp.les('O4', 4, 'Tia', pg_temp.d1(21), 60, 'done', null, null, false, 'Sec 3');
select pg_temp.les('O5', 4, 'Tia', pg_temp.d1(21), 60, 'done', null, null, false, null);
select t.ok(pg_temp.r('O4', pg_temp.m(0), pg_temp.eom(0)) = 'payable:7000:0:7000', 'inherit: after the date the student follows the level rate');
select t.ok(pg_temp.r('O5', pg_temp.m(0), pg_temp.eom(0)) = 'payable:5000:0:5000', 'inherit: with no level, the tutor''s default');
select t.ok(pg_temp.r('O1', pg_temp.m(0), pg_temp.eom(0)) = 'payable:9500:0:9500', 'inherit never rewrites the earlier lesson');
-- a deliberate "not paid" for one student
select pg_temp.rate('Tia', 7, null, 'none', null, null, pg_temp.d1(0), 'Volunteer lessons');
select pg_temp.les('O6', 7, 'Tia', pg_temp.d1(12));
select t.ok(pg_temp.r('O6', pg_temp.m(0), pg_temp.eom(0)) = 'unpaid:0:0:0', 'method none: shown as unpaid, earns nothing');
-- a replacement tutor is paid at THEIR OWN rate, never the original tutor's student override
select pg_temp.les('O7', 4, 'Tom', pg_temp.d1(7));
select t.ok(pg_temp.r('O7', pg_temp.m(0), pg_temp.eom(0)) = 'payable:3000:0:3000', 'replacement tutor (Tom) on Tia''s student: Tom''s default 3000, not Tia''s 9500');

-- ================================================================== 4. cancelled lessons with fixed rates (every value of tutor_pay.cancelled_lessons)
select pg_temp.les('C1', 8, 'Tia', pg_temp.d1(15), 60, 'cancelled', 'late_cancelled', 50);    -- charged
select pg_temp.les('C2', 8, 'Tia', pg_temp.d1(16), 60, 'cancelled', 'late_cancelled', 0);     -- not charged
select pg_temp.les('C3', 8, 'Tia', pg_temp.d1(17), 60, 'cancelled', 'absent', null);          -- charge not typed yet
select t.ok(pg_temp.r('C1', pg_temp.m(0), pg_temp.eom(0)) = 'payable:5000:0:5000' and pg_temp.r('C2', pg_temp.m(0), pg_temp.eom(0)) = 'zero:0:0:0'
        and pg_temp.r('C3', pg_temp.m(0), pg_temp.eom(0)) = 'waiting_charge:null:0:0', 'pay_if_charged: charged = usual rate, not charged = 0, charge not typed = waiting for the charge');
select pg_temp.cfg(t.id('P'), '{"cancelled_lessons":"pay_rate"}');
select t.ok(pg_temp.r('C1', pg_temp.m(0), pg_temp.eom(0)) = 'payable:5000:0:5000' and pg_temp.r('C2', pg_temp.m(0), pg_temp.eom(0)) = 'payable:5000:0:5000'
        and pg_temp.r('C3', pg_temp.m(0), pg_temp.eom(0)) = 'payable:5000:0:5000', 'pay_rate: every cancelled lesson is paid at the usual rate, even before the charge is typed');
select pg_temp.cfg(t.id('P'), '{"cancelled_lessons":"pay_nothing"}');
select t.ok(pg_temp.r('C1', pg_temp.m(0), pg_temp.eom(0)) = 'zero:0:0:0' and pg_temp.r('C2', pg_temp.m(0), pg_temp.eom(0)) = 'zero:0:0:0'
        and pg_temp.r('C3', pg_temp.m(0), pg_temp.eom(0)) = 'zero:0:0:0', 'pay_nothing: cancelled lessons earn 0');
select pg_temp.cfg(t.id('P'), '{}');

-- ================================================================== 5. percentage of the fee (both bases), rounding, cancelled, trials
create function pg_temp.tutor(p_label text, p_name text) returns void language plpgsql as $$
begin
  insert into memberships(org_id, user_id, invited_email, display_name, role, permissions, status, employment_type)
  values (t.id('P'), null, lower(p_label) || '@tutors.test', p_name, 'tutor', '{}', 'invited', 'freelancer');
  perform t.put(p_label, (select id from memberships where org_id = t.id('P') and invited_email = lower(p_label) || '@tutors.test'));
end $$;
grant execute on all functions in schema pg_temp to public;
select pg_temp.tutor('Tara', 'Tutor Tara'); select pg_temp.tutor('Tobi', 'Tutor Tobi'); select pg_temp.tutor('Tina', 'Tutor Tina'); select pg_temp.tutor('Tula', 'Tutor Tula');
select pg_temp.tutor('Tito', 'Tutor Tito'); select pg_temp.tutor('Tali', 'Tutor Tali'); select pg_temp.tutor('Tomo', 'Tutor Tomo'); select pg_temp.tutor('Tiko', 'Tutor Tiko');
select pg_temp.rate('Tara', null, null, 'percent_of_fee', null, 6000, pg_temp.d1(0), '60 percent');
select pg_temp.les('PA', 9, 'Tara', pg_temp.d1(3));
select t.ok(pg_temp.r('PA', pg_temp.m(0), pg_temp.eom(0)) = 'waiting_invoice:null:0:0', 'percent of the fee: before the lesson is invoiced the pay is "waiting for the invoice", nothing counted');
select pg_temp.inv('IPA', 9, pg_temp.d2(1), array['PA'], array[5000]::bigint[]);
select t.ok(pg_temp.r('PA', pg_temp.m(0), pg_temp.eom(0)) = 'payable:3000:0:3000', 'percent of the fee: 60% of S$50.00 = S$30.00 once invoiced');
select pg_temp.rate('Tobi', null, null, 'percent_of_fee', null, 5000, pg_temp.d1(0), '50 percent');
select pg_temp.les('PR', 9, 'Tobi', pg_temp.d1(4), 60, 'done', null, null, false, null, null, 12.55);
select pg_temp.inv('IPR', 9, pg_temp.d2(1), array['PR'], array[1255]::bigint[]);
select t.ok(pg_temp.r('PR', pg_temp.m(0), pg_temp.eom(0)) = 'payable:628:0:628', 'percentage rounds half up: 50% of S$12.55 = 627.5 → S$6.28');
-- sibling discount: student 10 has two lessons on one invoice and a discount line (-S$10.00): billed after discounts = S$45.00 each; list price = S$50.00
select pg_temp.les('SD1', 10, 'Tara', pg_temp.d1(5));  select pg_temp.les('SD2', 10, 'Tara', pg_temp.d1(6));
select pg_temp.inv('ISD', 10, pg_temp.d2(1), array['SD1', 'SD2'], array[5000, 5000]::bigint[], 10, -1000);
select t.ok(pg_temp.r('SD1', pg_temp.m(0), pg_temp.eom(0)) = 'payable:2700:0:2700' and pg_temp.r('SD2', pg_temp.m(0), pg_temp.eom(0)) = 'payable:2700:0:2700',
            'percent_base billed_after_discounts: 60% of (S$50.00 less its S$5.00 share of the sibling discount) = S$27.00');
select pg_temp.cfg(t.id('P'), '{"percent_base":"list_price"}');
select t.ok(pg_temp.r('SD1', pg_temp.m(0), pg_temp.eom(0)) = 'payable:3000:0:3000', 'percent_base list_price: 60% of S$50.00 = S$30.00 whatever the discount');
select pg_temp.cfg(t.id('P'), '{}');
-- an odd discount splits to the cent and adds up exactly (-S$10.01 over two S$50.00 lessons: -501 and -500)
select pg_temp.les('SO1', 11, 'Tara', pg_temp.d1(5));  select pg_temp.les('SO2', 11, 'Tara', pg_temp.d1(6));
select pg_temp.inv('ISO', 11, pg_temp.d2(1), array['SO1', 'SO2'], array[5000, 5000]::bigint[], 11, -1001);
select t.ok(pg_temp.r('SO1', pg_temp.m(0), pg_temp.eom(0)) = 'payable:2699:0:2699' and pg_temp.r('SO2', pg_temp.m(0), pg_temp.eom(0)) = 'payable:2700:0:2700',
            'an odd discount splits to the cent (-501 / -500) and the two lessons'' bases add up to the invoice (4499 + 4500)');
-- cancelled lessons under a percentage: the billed amount is the compensation
select pg_temp.les('PC1', 9, 'Tara', pg_temp.d1(7), 60, 'cancelled', 'late_cancelled', 25);
select pg_temp.les('PC2', 9, 'Tara', pg_temp.d1(8), 60, 'cancelled', 'late_cancelled', 0);
select pg_temp.les('PC3', 9, 'Tara', pg_temp.d1(9), 60, 'cancelled', 'absent', null);
select pg_temp.inv('IPC', 9, pg_temp.d2(2), array['PC1'], array[2500]::bigint[]);
select t.ok(pg_temp.r('PC1', pg_temp.m(0), pg_temp.eom(0)) = 'payable:1500:0:1500', 'percentage of a charged cancellation: 60% of the S$25.00 charge');
select t.ok(pg_temp.r('PC2', pg_temp.m(0), pg_temp.eom(0)) = 'zero:0:0:0', 'percentage of a free cancellation (charge 0) = 0');
select t.ok(pg_temp.r('PC3', pg_temp.m(0), pg_temp.eom(0)) = 'waiting_charge:null:0:0', 'percentage with the charge not typed yet: waiting for the charge');
-- trials: an uncharged trial has no fee, so a percentage gives 0; charged trials (a setting) follow their invoice line
select pg_temp.les('PT1', 9, 'Tara', pg_temp.d1(10), 60, 'done', 'attended', null, true);
select t.ok(pg_temp.r('PT1', pg_temp.m(0), pg_temp.eom(0)) = 'zero:0:0:0', 'an uncharged trial earns a percentage of nothing = 0');
select pg_temp.cfg(t.id('P'), '{}', '{"trials":true}');
select t.ok(pg_temp.r('PT1', pg_temp.m(0), pg_temp.eom(0)) = 'waiting_invoice:null:0:0', 'a charged trial waits for its invoice like any lesson');
select pg_temp.inv('IPT', 9, pg_temp.d2(2), array['PT1'], array[5000]::bigint[]);
select t.ok(pg_temp.r('PT1', pg_temp.m(0), pg_temp.eom(0)) = 'payable:3000:0:3000', 'a charged trial: 60% of its invoice line');
select pg_temp.cfg(t.id('P'), '{}');

-- ================================================================== 6. classes: one session pays once; per student; absent students
-- what one class (session) earns in total, its largest and smallest share among the taught students, and what an absent student earns
create function pg_temp.cls(p_sess uuid, p_from date, p_to date) returns text language plpgsql security definer as $$
declare x record;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-00000000f701', 'role', 'authenticated')::text, false);
  select coalesce(sum(earn_cents), 0) as total, max(earn_cents) filter (where lesson_status = 'done') as top, min(earn_cents) filter (where lesson_status = 'done') as lowest,
         coalesce(max(earn_cents) filter (where lesson_status = 'cancelled'), 0) as absent into x
    from centre_tutor_pay_rows(t.id('P'), p_from, p_to) where session_key = p_sess;
  perform set_config('request.jwt.claims', '', false);
  return x.total || ':' || x.top || ':' || x.lowest || ':' || x.absent;
end $$;
grant execute on all functions in schema pg_temp to public;
select pg_temp.rate('Tina', null, null, 'per_lesson', 5000, null, pg_temp.d1(0), 'Class rate');
select gen_random_uuid() as cls1 \gset
select pg_temp.les('G1', 1, 'Tina', pg_temp.d1(13), 60, 'done', 'attended', null, false, null, :'cls1');
select pg_temp.les('G2', 2, 'Tina', pg_temp.d1(13), 60, 'done', 'attended', null, false, null, :'cls1');
select pg_temp.les('G3', 3, 'Tina', pg_temp.d1(13), 60, 'done', 'attended', null, false, null, :'cls1');
select pg_temp.les('G4', 5, 'Tina', pg_temp.d1(13), 60, 'cancelled', 'absent', 0, false, null, :'cls1');
select t.ok(pg_temp.cls(:'cls1', pg_temp.m(0), pg_temp.eom(0)) = '5000:1668:1666:0',
  'a class of three taught by one tutor at S$50.00 a lesson pays S$50.00 ONCE (16.66 + 16.66 + 16.68, remainder on one), not S$150.00; the absent student adds nothing');
-- per hour, a 90-minute class of three at S$60 an hour = S$90 once = 3000 each
select pg_temp.rate('Tina', null, null, 'per_hour', 6000, null, pg_temp.d1(14), 'Hourly from the 15th');
select gen_random_uuid() as cls2 \gset
select pg_temp.les('G5', 1, 'Tina', pg_temp.d1(15), 90, 'done', 'attended', null, false, null, :'cls2');
select pg_temp.les('G6', 2, 'Tina', pg_temp.d1(15), 90, 'done', 'attended', null, false, null, :'cls2');
select pg_temp.les('G7', 3, 'Tina', pg_temp.d1(15), 90, 'done', 'attended', null, false, null, :'cls2');
select t.ok(pg_temp.r('G5', pg_temp.m(0), pg_temp.eom(0)) = 'payable:3000:0:3000' and pg_temp.r('G6', pg_temp.m(0), pg_temp.eom(0)) = 'payable:3000:0:3000'
        and pg_temp.r('G7', pg_temp.m(0), pg_temp.eom(0)) = 'payable:3000:0:3000', 'a 90-minute class at S$60 an hour pays S$90 once: S$30.00 each');
-- a class where nobody came and every student is charged: the cancelled rule applies ONCE (pay_if_charged: the usual rate, shared); pay_nothing: 0
select gen_random_uuid() as cls3 \gset
select pg_temp.les('G8', 1, 'Tina', pg_temp.d1(16), 60, 'cancelled', 'late_cancelled', 50, false, null, :'cls3');
select pg_temp.les('G9', 2, 'Tina', pg_temp.d1(16), 60, 'cancelled', 'late_cancelled', 50, false, null, :'cls3');
select t.ok(pg_temp.r('G8', pg_temp.m(0), pg_temp.eom(0)) = 'payable:3000:0:3000' and pg_temp.r('G9', pg_temp.m(0), pg_temp.eom(0)) = 'payable:3000:0:3000',
            'a class cancelled for everyone but charged: paid once (S$60 an hour for 1 hour, shared by two students)');
select pg_temp.cfg(t.id('P'), '{"cancelled_lessons":"pay_nothing"}');
select t.ok(pg_temp.r('G8', pg_temp.m(0), pg_temp.eom(0)) = 'zero:0:0:0', 'the same class under pay_nothing: 0');
select pg_temp.cfg(t.id('P'), '{}');
-- per student per lesson: attended vs enrolled
select pg_temp.rate('Tula', null, null, 'per_student_lesson', 1500, null, pg_temp.d1(0), 'Per student');
select gen_random_uuid() as cls4 \gset
select pg_temp.les('S1', 1, 'Tula', pg_temp.d1(17), 60, 'done', 'attended', null, false, null, :'cls4');
select pg_temp.les('S2', 2, 'Tula', pg_temp.d1(17), 60, 'done', 'attended', null, false, null, :'cls4');
select pg_temp.les('S3', 3, 'Tula', pg_temp.d1(17), 60, 'done', 'attended', null, false, null, :'cls4');
select pg_temp.les('S4', 5, 'Tula', pg_temp.d1(17), 60, 'cancelled', 'absent', 20, false, null, :'cls4');
select t.ok(pg_temp.r('S1', pg_temp.m(0), pg_temp.eom(0)) = 'payable:1500:0:1500' and pg_temp.r('S3', pg_temp.m(0), pg_temp.eom(0)) = 'payable:1500:0:1500'
        and pg_temp.r('S4', pg_temp.m(0), pg_temp.eom(0)) = 'zero:0:0:0', 'per student, group_count = attended: three attended students × S$15.00; the absent one is not counted');
select pg_temp.cfg(t.id('P'), '{"group_count":"enrolled"}');
select t.ok(pg_temp.r('S4', pg_temp.m(0), pg_temp.eom(0)) = 'payable:1500:0:1500', 'group_count = enrolled: the absent but charged student is counted too');
select pg_temp.cfg(t.id('P'), '{"group_count":"enrolled","cancelled_lessons":"pay_nothing"}');
select t.ok(pg_temp.r('S4', pg_temp.m(0), pg_temp.eom(0)) = 'zero:0:0:0', 'group_count = enrolled but cancelled lessons pay nothing: not counted');
select pg_temp.cfg(t.id('P'), '{}');
-- per student per lesson needs a centre that runs classes
select pg_temp.cfg(t.id('P'), '{}', '{"class_type":"one_to_one"}');
select pg_temp.refused(:'o1', format('select centre_tutor_rate_set(%L,%L,null,null,%L,1500,null,%L,%L)', t.id('P'), t.id('Tula'), 'per_student_lesson', pg_temp.d1(0), 'x'), 'BAD_RATE', 'one-to-one centres can''t use per-student-per-lesson');
select pg_temp.cfg(t.id('P'), '{}');

-- ================================================================== 7. held until the parent pays (payable_when = parent_paid)
select pg_temp.rate('Tito', null, null, 'per_lesson', 4000, null, pg_temp.d1(0), 'Tito rate');
select pg_temp.cfg(t.id('P'), '{"payable_when":"parent_paid"}');
-- two lessons, one invoice of S$80.00 issued in month 2
select pg_temp.les('W1', 1, 'Tito', pg_temp.d1(2), 60, 'done', null, null, false, null, null, 40);
select pg_temp.les('W2', 1, 'Tito', pg_temp.d1(3), 60, 'done', null, null, false, null, null, 40);
select t.ok(pg_temp.r('W1', pg_temp.m(0), pg_temp.eom(0)) = 'held:4000:0:0', 'parent_paid: taught but not invoiced yet = HELD (earned S$40.00, released 0)');
select pg_temp.inv('IW', 1, pg_temp.d2(1), array['W1', 'W2'], array[4000, 4000]::bigint[]);
select t.ok(pg_temp.r('W1', pg_temp.m(0), pg_temp.eom(0)) = 'held:4000:0:0' and pg_temp.r('W2', pg_temp.m(0), pg_temp.eom(0)) = 'held:4000:0:0', 'invoiced but unpaid: still held');
select pg_temp.pay('IW', 1, 4000, pg_temp.d2(5)) as pw1 \gset
select t.ok(pg_temp.r('W1', pg_temp.m(0), pg_temp.eom(0)) = 'held:4000:0:0', 'a payment received in month 2 does not release month 1''s pay');
select t.ok(pg_temp.r('W1', pg_temp.m(1), pg_temp.eom(1)) = 'payable:4000:0:4000' and pg_temp.r('W2', pg_temp.m(1), pg_temp.eom(1)) = 'held:4000:0:0',
            'after_full: S$40.00 of S$80.00 paid fills the OLDEST line first: lesson 1 released in the month the payment arrived, lesson 2 still held');
select pg_temp.pay('IW', 1, 4000, pg_temp.d3(2)) as pw2 \gset
select t.ok(pg_temp.r('W2', pg_temp.m(1), pg_temp.eom(1)) = 'held:4000:0:0', 'month 2 is unchanged by a later payment (past figures do not move)');
select t.ok(pg_temp.r('W2', pg_temp.m(2), pg_temp.eom(2)) = 'payable:4000:0:4000' and pg_temp.r('W1', pg_temp.m(2), pg_temp.eom(2)) = 'payable:4000:4000:4000',
            'the rest of the family''s payment arrives in month 3: lesson 2 is released THEN (rolls into that period); lesson 1 was already released before');
-- a reversal takes it away again from the day it is recorded
select pg_temp.unpay(:'pw2', 'IW', pg_temp.d3(9));
select t.ok(pg_temp.r('W2', pg_temp.m(2), pg_temp.d3(5)) = 'payable:4000:0:4000' and pg_temp.r('W2', pg_temp.m(2), pg_temp.d3(12)) = 'held:4000:0:0',
            'a reversed payment holds the pay again from the reversal date (not before)');
-- part payment, pro_rata: S$40.00 of S$80.00 released in proportion
select pg_temp.les('W3', 2, 'Tito', pg_temp.d1(2), 60, 'done', null, null, false, null, null, 40);  select pg_temp.les('W4', 2, 'Tito', pg_temp.d1(3), 60, 'done', null, null, false, null, null, 40);
select pg_temp.inv('IW2', 2, pg_temp.d2(1), array['W3', 'W4'], array[4000, 4000]::bigint[]);
select pg_temp.pay('IW2', 2, 4000, pg_temp.d2(5)) as pw3 \gset
select t.ok(pg_temp.r('W3', pg_temp.m(1), pg_temp.eom(1)) = 'payable:4000:0:4000' and pg_temp.r('W4', pg_temp.m(1), pg_temp.eom(1)) = 'held:4000:0:0', 'after_full (the default): half paid releases one lesson fully, the other nothing');
select pg_temp.cfg(t.id('P'), '{"payable_when":"parent_paid","part_payments":"pro_rata"}');
select t.ok(pg_temp.r('W3', pg_temp.m(1), pg_temp.eom(1)) = 'part:4000:0:2000' and pg_temp.r('W4', pg_temp.m(1), pg_temp.eom(1)) = 'part:4000:0:2000', 'pro_rata: half paid releases half of each lesson''s pay');
select pg_temp.pay('IW2', 2, 4000, pg_temp.d3(2));
select t.ok(pg_temp.r('W4', pg_temp.m(2), pg_temp.eom(2)) = 'payable:4000:2000:4000', 'pro_rata: once paid in full, the rest is released (S$20.00 earlier, S$20.00 now)');
select pg_temp.cfg(t.id('P'), '{"payable_when":"parent_paid"}');
-- GST: S$80.00 + 9% = S$87.20. Half of the TOTAL (S$43.60) pays exactly the first S$40.00 line; one cent less pays neither
select pg_temp.les('W5', 3, 'Tito', pg_temp.d1(2), 60, 'done', null, null, false, null, null, 40);  select pg_temp.les('W6', 3, 'Tito', pg_temp.d1(3), 60, 'done', null, null, false, null, null, 40);
select pg_temp.les('W7', 4, 'Tito', pg_temp.d1(2), 60, 'done', null, null, false, null, null, 40);  select pg_temp.les('W8', 4, 'Tito', pg_temp.d1(3), 60, 'done', null, null, false, null, null, 40);
select pg_temp.inv('IW3', 3, pg_temp.d2(1), array['W5', 'W6'], array[4000, 4000]::bigint[], null, null, true);
select pg_temp.inv('IW4', 4, pg_temp.d2(1), array['W7', 'W8'], array[4000, 4000]::bigint[], null, null, true);
select t.ok((select total_cents from centre_invoices where id = t.id('IW3')) = 8720, 'the GST invoice totals S$87.20');
select pg_temp.pay('IW3', 3, 4360, pg_temp.d2(5));  select pg_temp.pay('IW4', 4, 4359, pg_temp.d2(5));
select t.ok(pg_temp.r('W5', pg_temp.m(1), pg_temp.eom(1)) = 'payable:4000:0:4000' and pg_temp.r('W6', pg_temp.m(1), pg_temp.eom(1)) = 'held:4000:0:0',
            'GST: S$43.60 of S$87.20 covers the first S$40.00 line exactly (GST is spread across the lines)');
select t.ok(pg_temp.r('W7', pg_temp.m(1), pg_temp.eom(1)) = 'held:4000:0:0', 'GST: one cent short of that: the first lesson is still held');
-- a credit note counts as the family being cleared of that amount
select pg_temp.les('W9', 5, 'Tito', pg_temp.d1(2), 60, 'done', null, null, false, null, null, 40);
select pg_temp.inv('IW5', 5, pg_temp.d2(1), array['W9'], array[4000]::bigint[]);
select pg_temp.credit('IW5', 4000, pg_temp.d2(4));
select t.ok(pg_temp.r('W9', pg_temp.m(1), pg_temp.eom(1)) = 'payable:4000:0:4000', 'a credit note that clears the invoice releases the pay (nothing left for the family to pay)');
-- nothing for the family to pay: an uncharged trial and a free cancellation are released at once; a lesson that will be invoiced is held
select pg_temp.les('W10', 6, 'Tito', pg_temp.d1(2), 60, 'done', 'attended', null, true);
select t.ok(pg_temp.r('W10', pg_temp.m(0), pg_temp.eom(0)) = 'payable:4000:0:4000', 'an uncharged trial has no family payment to wait for: released at once');
select pg_temp.cfg(t.id('P'), '{"payable_when":"parent_paid","cancelled_lessons":"pay_rate"}');
select pg_temp.les('W11', 6, 'Tito', pg_temp.d1(3), 60, 'cancelled', 'late_cancelled', 0);
select t.ok(pg_temp.r('W11', pg_temp.m(0), pg_temp.eom(0)) = 'payable:4000:0:4000', 'a free cancellation paid at the usual rate: nothing for the family to pay, so released at once');
select pg_temp.les('W12', 6, 'Tito', pg_temp.d1(4), 60, 'cancelled', 'late_cancelled', 20);
select t.ok(pg_temp.r('W12', pg_temp.m(0), pg_temp.eom(0)) = 'held:4000:0:0', 'a charged cancellation not yet invoiced: held');
select pg_temp.cfg(t.id('P'), '{"payable_when":"parent_paid"}');
-- the percentage of a fee held until paid, GST never in the base: Tara 60% of S$80.00 (+GST) with the family paying half the total
select pg_temp.les('W13', 7, 'Tara', pg_temp.d1(2), 60, 'done', null, null, false, null, null, 80);
select pg_temp.inv('IW6', 7, pg_temp.d2(1), array['W13'], array[8000]::bigint[], null, null, true);
select t.ok(pg_temp.r('W13', pg_temp.m(0), pg_temp.eom(0)) = 'held:4800:0:0', 'percentage + GST: 60% of the S$80.00 fee (not of S$87.20), held while unpaid');
select pg_temp.pay('IW6', 7, 4360, pg_temp.d2(6)) as pw6 \gset
select t.ok(pg_temp.r('W13', pg_temp.m(1), pg_temp.eom(1)) = 'held:4800:0:0', 'half the total paid does not cover a single S$80.00 line');
select pg_temp.pay('IW6', 7, 4360, pg_temp.d2(7));
select t.ok(pg_temp.r('W13', pg_temp.m(1), pg_temp.eom(1)) = 'payable:4800:0:4800', 'paid in full (S$87.20): released');
-- a lesson marked late is counted on the day it was marked, so a past period does not change
select pg_temp.cfg(t.id('P'), '{}');
select pg_temp.les('LM', 8, 'Tito', pg_temp.d1(25), 60, 'done', 'attended', null, false, null, null, 40, (pg_temp.d2(3)::text || ' 12:00+08')::timestamptz);
select t.ok(pg_temp.r('LM', pg_temp.m(0), pg_temp.eom(0)) = 'none', 'a lesson marked in month 2 is not in month 1''s figures, though it was taught in month 1');
select t.ok(pg_temp.r('LM', pg_temp.m(1), pg_temp.eom(1)) = 'payable:4000:0:4000', 'it is counted in month 2, the day it was marked');

-- ================================================================== 8. the pay list: due, carried over, adjustments, recording, freeze, reversal
select pg_temp.rate('Tali', null, null, 'per_lesson', 10000, null, pg_temp.d1(0), 'Tali rate');
select pg_temp.les('ML1', 12, 'Tali', pg_temp.d1(3), 60, 'done', null, null, false, null, null, 100);  select pg_temp.les('ML2', 12, 'Tali', pg_temp.d1(4), 60, 'done', null, null, false, null, null, 100);
select pg_temp.o(format('select centre_tutor_pay_adjust(%L,%L,2500,%L,%L)', t.id('P'), t.id('Tali'), pg_temp.d1(20), 'Great month'));
select pg_temp.o(format('select centre_tutor_pay_adjust(%L,%L,-500,%L,%L)', t.id('P'), t.id('Tali'), pg_temp.d1(21), 'Lost textbook'));
create function pg_temp.tut(p_json jsonb, p_label text, p_key text) returns text language sql as $$
  select (e->>p_key) from jsonb_array_elements(p_json->'tutors') e where (e->>'membership_id')::uuid = t.id(p_label) $$;
grant execute on all functions in schema pg_temp to public;
select pg_temp.o(format('select centre_tutor_pay_list(%L, %L)', t.id('P'), pg_temp.d1(10))) as l1 \gset
select t.ok(pg_temp.tut(:'l1', 'Tali', 'lessons') = '2' and pg_temp.tut(:'l1', 'Tali', 'minutes') = '120' and pg_temp.tut(:'l1', 'Tali', 'released_cents') = '20000'
        and pg_temp.tut(:'l1', 'Tali', 'adjustments_cents') = '2000' and pg_temp.tut(:'l1', 'Tali', 'due_cents') = '22000' and pg_temp.tut(:'l1', 'Tali', 'carry_cents') = '0'
        and pg_temp.tut(:'l1', 'Tali', 'outstanding_cents') = '22000' and pg_temp.tut(:'l1', 'Tali', 'pay_state') = 'unpaid', 'pay list: 2 lessons S$200.00 + bonus S$25.00 - deduction S$5.00 = S$220.00 due, nothing carried');
select t.ok((:'l1'::jsonb->>'period_from') = pg_temp.m(0)::text and (:'l1'::jsonb->>'period_to') = pg_temp.eom(0)::text and (:'l1'::jsonb->>'payable_when') = 'taught', 'pay list: the period is the whole calendar month (cut-off day 31)');
select pg_temp.refused(:'o1', format('select centre_tutor_pay_adjust(%L,%L,100,%L,%L)', t.id('P'), t.id('Tali'), pg_temp.d1(5), ''), 'REASON_REQUIRED', 'an adjustment needs a reason');
select pg_temp.refused(:'o1', format('select centre_tutor_pay_adjust(%L,%L,0,%L,%L)', t.id('P'), t.id('Tali'), pg_temp.d1(5), 'x'), 'BAD_AMOUNT', 'an adjustment of 0 is refused');
select pg_temp.refused(:'o1', format('select centre_tutor_pay_adjust(%L,%L,100,%L,%L)', t.id('P'), t.id('Tali'), current_date + 90, 'x'), 'BAD_DATE', 'an adjustment more than two months ahead is refused');
-- recording payments: a part payment, too much, bad method, a future date
select pg_temp.refused(:'o1', format('select centre_tutor_pay_record(%L,%L,%L,22001,%L,%L)', t.id('P'), t.id('Tali'), pg_temp.d1(10), current_date, 'bank'), 'TOO_MUCH', 'paying more than is due for the period is refused');
select pg_temp.refused(:'o1', format('select centre_tutor_pay_record(%L,%L,%L,100,%L,%L)', t.id('P'), t.id('Tali'), pg_temp.d1(10), current_date, 'barter'), 'BAD_METHOD', 'an unknown payment method is refused');
select pg_temp.refused(:'o1', format('select centre_tutor_pay_record(%L,%L,%L,100,%L,%L)', t.id('P'), t.id('Tali'), pg_temp.d1(10), current_date + 2, 'bank'), 'BAD_DATE', 'a payment dated in the future is refused');
select pg_temp.refused(:'o1', format('select centre_tutor_pay_record(%L,%L,%L,100,%L,%L,%L)', t.id('P'), t.id('Tali'), pg_temp.d1(10), current_date, 'bank', 'DBS 123456789012'), 'BAD_REFERENCE', 'a whole account number in the reference is refused (PDPA)');
select pg_temp.refused(:'o1', format('select centre_tutor_pay_record(%L,%L,%L,0,%L,%L)', t.id('P'), t.id('Tali'), pg_temp.d1(10), current_date, 'bank'), 'BAD_AMOUNT', 'a payment of 0 is refused');
select pg_temp.o(format('select centre_tutor_pay_record(%L,%L,%L,10000,%L,%L,%L)', t.id('P'), t.id('Tali'), pg_temp.d1(10), current_date, 'paynow', 'Pay run 1')) as pr1 \gset
select pg_temp.o(format('select centre_tutor_pay_list(%L, %L)', t.id('P'), pg_temp.d1(10))) as l2 \gset
select t.ok(pg_temp.tut(:'l2', 'Tali', 'paid_cents') = '10000' and pg_temp.tut(:'l2', 'Tali', 'outstanding_cents') = '12000' and pg_temp.tut(:'l2', 'Tali', 'pay_state') = 'part_paid', 'a part payment: S$100.00 paid, S$120.00 still to pay, state part_paid');
-- the period is now frozen for Tali: nothing can be dated inside it
select pg_temp.refused(:'o1', format('select centre_tutor_rate_set(%L,%L,null,null,%L,12000,null,%L,%L)', t.id('P'), t.id('Tali'), 'per_lesson', pg_temp.d1(5), 'Back-dated raise'), 'PERIOD_PAID', 'a rate can''t start inside a period that is recorded as paid');
select pg_temp.refused(:'o1', format('select centre_tutor_pay_adjust(%L,%L,100,%L,%L)', t.id('P'), t.id('Tali'), pg_temp.d1(25), 'Late bonus'), 'PERIOD_PAID', 'an adjustment can''t be dated inside a period that is recorded as paid');
select pg_temp.rate('Tali', null, null, 'per_lesson', 12000, null, pg_temp.d2(0), 'Raise from next month');
select t.ok(true, 'a rate starting after the paid period is fine');
select pg_temp.o(format('select centre_tutor_pay_record(%L,%L,%L,12000,%L,%L,%L)', t.id('P'), t.id('Tali'), pg_temp.d1(10), current_date, 'bank', 'Pay run 1b'));
select pg_temp.o(format('select centre_tutor_pay_list(%L, %L)', t.id('P'), pg_temp.d1(10))) as l3 \gset
select t.ok(pg_temp.tut(:'l3', 'Tali', 'outstanding_cents') = '0' and pg_temp.tut(:'l3', 'Tali', 'pay_state') = 'paid', 'paid in full: nothing outstanding, state paid');
-- the next month: nothing carried over, new rate applies, a month-2 adjustment is allowed
select pg_temp.les('ML3', 12, 'Tali', pg_temp.d2(3), 60, 'done', null, null, false, null, null, 100);
select pg_temp.o(format('select centre_tutor_pay_adjust(%L,%L,300,%L,%L)', t.id('P'), t.id('Tali'), pg_temp.d2(1), 'Cover bonus'));
select pg_temp.o(format('select centre_tutor_pay_list(%L, %L)', t.id('P'), pg_temp.d2(10))) as l4 \gset
select t.ok(pg_temp.tut(:'l4', 'Tali', 'carry_cents') = '0' and pg_temp.tut(:'l4', 'Tali', 'released_cents') = '12000' and pg_temp.tut(:'l4', 'Tali', 'due_cents') = '12300',
            'next month: nothing carried over, the new rate (S$120.00) applies from its date, the month-2 bonus is included');
-- a mistake: reverse the part payment; it is a new row, the original stays; the period stays frozen while another payment stands
select pg_temp.refused(:'o1', format('select centre_tutor_pay_reverse(%L, %L)', (:'pr1'::jsonb->>'id')::uuid, ''), 'REASON_REQUIRED', 'reversing a payment needs a reason');
select pg_temp.o(format('select centre_tutor_pay_reverse(%L, %L)', (:'pr1'::jsonb->>'id')::uuid, 'Paid to the wrong tutor')) as rv \gset
select t.ok((select count(*) = 2 from tutor_pay_payments where org_id = t.id('P') and period_to = pg_temp.eom(0) and membership_id = t.id('Tali') and kind = 'payment')
        and (select count(*) = 1 from tutor_pay_payments where kind = 'reversal' and membership_id = t.id('Tali')), 'a reversal is a new row; both payments stay on record');
select t.ok((pg_temp.o(format('select centre_tutor_pay_reverse(%L, %L)', (:'pr1'::jsonb->>'id')::uuid, 'again'))->>'already') = 'true', 'reversing twice does nothing the second time');
select pg_temp.o(format('select centre_tutor_pay_list(%L, %L)', t.id('P'), pg_temp.d1(10))) as l5 \gset
select t.ok(pg_temp.tut(:'l5', 'Tali', 'paid_cents') = '12000' and pg_temp.tut(:'l5', 'Tali', 'outstanding_cents') = '10000', 'after the reversal S$120.00 is recorded as paid and S$100.00 is outstanding again');
select pg_temp.o(format('select centre_tutor_pay_detail(%L, %L, %L)', t.id('P'), t.id('Tali'), pg_temp.d1(10))) as dt \gset
select t.ok(jsonb_array_length(:'dt'::jsonb->'lines') = 2 and jsonb_array_length(:'dt'::jsonb->'adjustments') = 2 and jsonb_array_length(:'dt'::jsonb->'payments') = 3, 'detail: 2 lessons, 2 adjustments, 3 payment rows (2 payments + 1 reversal)');
-- carried over: the March-style case: a month nobody paid shows up in the next month
select pg_temp.rate('Tomo', null, null, 'monthly_fixed', 300000, null, pg_temp.d1(0), 'Salary');
select pg_temp.o(format('select centre_tutor_pay_list(%L, %L)', t.id('P'), pg_temp.d1(10))) as m1 \gset
select pg_temp.o(format('select centre_tutor_pay_list(%L, %L)', t.id('P'), pg_temp.d2(10))) as m2 \gset
select t.ok(pg_temp.tut(:'m1', 'Tomo', 'monthly_cents') = '300000' and pg_temp.tut(:'m1', 'Tomo', 'due_cents') = '300000', 'monthly fixed: S$3,000.00 for the month, no lessons needed');
select t.ok(pg_temp.tut(:'m2', 'Tomo', 'carry_cents') = '300000' and pg_temp.tut(:'m2', 'Tomo', 'due_cents') = '600000', 'an unpaid month is carried over: month 2 shows S$3,000.00 carried + S$3,000.00 = S$6,000.00 due');
select pg_temp.o(format('select centre_tutor_pay_record(%L,%L,%L,300000,%L,%L)', t.id('P'), t.id('Tomo'), pg_temp.d1(10), current_date, 'bank'));
select pg_temp.o(format('select centre_tutor_pay_list(%L, %L)', t.id('P'), pg_temp.d2(10))) as m3 \gset
select t.ok(pg_temp.tut(:'m3', 'Tomo', 'carry_cents') = '0' and pg_temp.tut(:'m3', 'Tomo', 'due_cents') = '300000', 'once month 1 is paid, nothing is carried into month 2');
-- monthly fixed is never held by a parent's payment (parent_paid is on for the centre here)
select pg_temp.cfg(t.id('P'), '{"payable_when":"parent_paid"}');
select pg_temp.o(format('select centre_tutor_pay_list(%L, %L)', t.id('P'), pg_temp.d2(10))) as m4 \gset
select t.ok(pg_temp.tut(:'m4', 'Tomo', 'due_cents') = '300000' and pg_temp.tut(:'m4', 'Tomo', 'held_cents') = '0', 'monthly fixed pay is not held back by payable_when = parent_paid');
select pg_temp.cfg(t.id('P'), '{}');
-- held lessons show on the list (Tito has several held lessons under parent_paid in the earlier checks; here under "taught" they are all payable)
select pg_temp.cfg(t.id('P'), '{"payable_when":"parent_paid"}');
select pg_temp.o(format('select centre_tutor_pay_list(%L, %L)', t.id('P'), pg_temp.d1(10))) as h1 \gset
select t.ok((pg_temp.tut(:'h1', 'Tito', 'held_cents'))::bigint > 0 and (pg_temp.tut(:'h1', 'Tito', 'held_lessons'))::int > 0, 'the pay list shows what is held until parents pay');
select t.ok((pg_temp.tut(:'h1', 'Tito', 'due_cents'))::bigint < (pg_temp.tut(:'h1', 'Tito', 'held_cents'))::bigint + (pg_temp.tut(:'h1', 'Tito', 'due_cents'))::bigint, 'held money is not part of what is due');
select pg_temp.cfg(t.id('P'), '{}');
-- unassigned lessons (no tutor) are counted, never paid
insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status) values
  ('00000000-0000-0000-0000-00000000f701', t.id('P'), t.id('P_s1'), pg_temp.d1(9), '15:00', '16:00', 50, 50, 'done');
select t.ok((pg_temp.o(format('select centre_tutor_pay_list(%L, %L)', t.id('P'), pg_temp.d1(10)))->>'unassigned_lessons')::int = 1, 'a lesson with no tutor is counted as unassigned and paid to nobody');

-- ================================================================== 9. the cut-off day moves the period
select pg_temp.rate('Tiko', null, null, 'per_lesson', 1000, null, pg_temp.d1(0), 'Tiko rate');
select pg_temp.les('CU1', 12, 'Tiko', pg_temp.d1(10));  select pg_temp.les('CU2', 12, 'Tiko', pg_temp.d1(20));
select pg_temp.cfg(t.id('P'), '{"cycle":{"cutoff_day":15,"pay_day":20}}');
select pg_temp.o(format('select centre_tutor_pay_list(%L, %L)', t.id('P'), pg_temp.d1(5))) as c1 \gset
select pg_temp.o(format('select centre_tutor_pay_list(%L, %L)', t.id('P'), pg_temp.d2(5))) as c2 \gset
select t.ok((:'c1'::jsonb->>'period_to') = (pg_temp.m(0) + 14)::text and (:'c1'::jsonb->>'period_from') = (pg_temp.m(-1) + 15)::text and (:'c1'::jsonb->>'pay_day') = '20',
            'cut-off day 15: the period ends on the 15th and starts the day after the previous 15th');
select t.ok(pg_temp.tut(:'c1', 'Tiko', 'lessons') = '1' and pg_temp.tut(:'c2', 'Tiko', 'lessons') = '1', 'cut-off day 15: the lesson on the 11th is in this period, the lesson on the 21st in the next');
select pg_temp.cfg(t.id('P'), '{"cycle":{"cutoff_day":28,"pay_day":7}}');
select pg_temp.o(format('select centre_tutor_pay_list(%L, %L)', t.id('P'), pg_temp.d1(5))) as c3 \gset
select t.ok((:'c3'::jsonb->>'period_to') = (pg_temp.m(0) + 27)::text, 'cut-off day 28 ends on the 28th');
select pg_temp.cfg(t.id('P'), '{"cycle":{"cutoff_day":31,"pay_day":7}}');
select pg_temp.o(format('select centre_tutor_pay_list(%L, %L)', t.id('P'), pg_temp.m(1) - 1)) as c4 \gset
select t.ok((:'c4'::jsonb->>'period_to') = pg_temp.eom(0)::text, 'cut-off day 31 = the last day of the month, whatever its length');
select pg_temp.cfg(t.id('P'), '{}');
select t.eq((select count(*) from centre_tutor_period(date '2027-02-10', 31) where p_to = date '2027-02-28' and p_from = date '2027-02-01'), 1, 'cut-off 31 in February 2027 ends on the 28th');
select t.eq((select count(*) from centre_tutor_period(date '2028-02-10', 30) where p_to = date '2028-02-29' and p_from = date '2028-01-31'), 1, 'cut-off 30: a leap February ends on the 29th, and starts the day after January''s period ended (the 30th)');
select t.eq((select count(*) from centre_tutor_period(date '2026-03-10', 29) where p_to = date '2026-03-29' and p_from = date '2026-03-01'), 1, 'cut-off 29 after February 2026 (28 days) starts on 1 March');

-- ================================================================== 10. the lessons-taught report: counts and hours, never money
select pg_temp.o(format('select centre_tutor_taught_report(%L, %L)', t.id('P'), pg_temp.d1(10))) as rp \gset
select t.ok((select (e->>'lessons')::int = 2 and (e->>'minutes')::int = 120 and (e->>'students')::int = 1 from jsonb_array_elements(:'rp'::jsonb->'tutors') e where (e->>'membership_id')::uuid = t.id('Tiko')),
            'report: Tiko taught 2 lessons, 120 minutes, 1 student');
select t.ok(:'rp'::text !~* '(cents|rate|pay_|amount|fee|price|paid)', 'the lessons-taught report carries no money and no rate fields at all');

-- ================================================================== 11. the three modes
select pg_temp.cfg(t.id('P'), '{"mode":"report"}');
select t.ok(jsonb_typeof(pg_temp.o(format('select centre_tutor_taught_report(%L, null)', t.id('P')))) = 'object', 'mode report: the report works');
select t.ok(jsonb_typeof(pg_temp.o(format('select centre_tutor_rate_list(%L)', t.id('P')))) = 'object', 'mode report: the rates screen works (rates can be set up before pay is switched on)');
select t.ok(pg_temp.rate('Tess', null, null, 'per_lesson', 2600, null, pg_temp.d2(5), 'Report mode raise') is not null, 'mode report: a rate can be set');
select pg_temp.refused(:'o1', format('select centre_tutor_pay_list(%L, null)', t.id('P')), 'PAY_REPORT_ONLY', 'mode report: the money list is refused');
select pg_temp.refused(:'o1', format('select centre_tutor_pay_detail(%L, %L, null)', t.id('P'), t.id('Tali')), 'PAY_REPORT_ONLY', 'mode report: a tutor''s pay lines are refused');
select pg_temp.refused(:'o1', format('select centre_tutor_pay_adjust(%L, %L, 100, null, %L)', t.id('P'), t.id('Tali'), 'x'), 'PAY_REPORT_ONLY', 'mode report: adjustments are refused');
select pg_temp.refused(:'o1', format('select centre_tutor_pay_record(%L, %L, null, 100, %L, %L)', t.id('P'), t.id('Tali'), current_date, 'bank'), 'PAY_REPORT_ONLY', 'mode report: recording pay is refused');
select pg_temp.refused(:'o1', format('select centre_tutor_pay_export_log(%L, null, 1, 1)', t.id('P')), 'PAY_REPORT_ONLY', 'mode report: exporting is refused');
select pg_temp.cfg(t.id('P'), '{"mode":"off"}');
select pg_temp.refused(:'o1', format('select centre_tutor_taught_report(%L, null)', t.id('P')), 'PAY_OFF', 'mode off: the report is refused');
select pg_temp.refused(:'o1', format('select centre_tutor_rate_list(%L)', t.id('P')), 'PAY_OFF', 'mode off: the rates screen is refused');
select pg_temp.refused(:'o1', format('select centre_tutor_rate_set(%L,%L,null,null,%L,1,null,%L,%L)', t.id('P'), t.id('Tess'), 'per_lesson', pg_temp.d2(6), 'x'), 'PAY_OFF', 'mode off: setting a rate is refused');
select pg_temp.refused(:'o1', format('select centre_tutor_pay_list(%L, null)', t.id('P')), 'PAY_OFF', 'mode off: the pay list is refused');
select pg_temp.cfg(t.id('P'), '{"adjustments":false}');
select pg_temp.refused(:'o1', format('select centre_tutor_pay_adjust(%L, %L, 100, null, %L)', t.id('P'), t.id('Tali'), 'x'), 'ADJUSTMENTS_OFF', 'adjustments switched off in the settings: refused');
select t.ok(jsonb_typeof(pg_temp.o(format('select centre_tutor_pay_list(%L, null)', t.id('P')))) = 'object', 'adjustments off does not stop the pay list');
select pg_temp.cfg(t.id('P'), '{}');

-- ================================================================== 12. settings are read as of the LESSON's date (a later change never rewrites earlier pay)
insert into org_settings(org_id, version, schema_version, effective_from, settings)
values (t.id('P'), (select max(version) + 1 from org_settings where org_id = t.id('P')), 1, pg_temp.d3(20),
        pg_temp.base('{"payable_when":"parent_paid","cancelled_lessons":"pay_nothing"}'));
select pg_temp.rate('Tiko', null, null, 'per_lesson', 1000, null, pg_temp.d3(0), 'Tiko again');
select pg_temp.les('SB1', 12, 'Tiko', pg_temp.d3(18), 60, 'cancelled', 'late_cancelled', 20);    -- before the change: pay_if_charged, taught
select pg_temp.les('SB2', 12, 'Tiko', pg_temp.d3(22), 60, 'cancelled', 'late_cancelled', 20);    -- after: pay_nothing
select pg_temp.les('SB3', 12, 'Tiko', pg_temp.d3(19));                                           -- before: pays at once (taught)
select pg_temp.les('SB4', 12, 'Tiko', pg_temp.d3(23));                                           -- after: held until the parent pays
select t.ok(pg_temp.r('SB1', pg_temp.m(2), pg_temp.eom(2)) = 'payable:1000:0:1000' and pg_temp.r('SB2', pg_temp.m(2), pg_temp.eom(2)) = 'zero:0:0:0',
            'a cancelled lesson follows the cancelled-lesson rule in force on ITS date (before vs after the change)');
select t.ok(pg_temp.r('SB3', pg_temp.m(2), pg_temp.eom(2)) = 'payable:1000:0:1000' and pg_temp.r('SB4', pg_temp.m(2), pg_temp.eom(2)) = 'held:1000:0:0',
            'payable_when follows the lesson''s date too: the earlier lesson pays at once, the later one waits for the parent');

-- ================================================================== 13. who may call what
create function pg_temp.calls() returns text[] language sql as $$ select array[
  format('select centre_tutor_rate_list(%L)', t.id('P')),
  format('select centre_tutor_rate_set(%L,%L,null,null,%L,100,null,%L,%L)', t.id('P'), t.id('Tess'), 'per_lesson', current_date, 'x'),
  format('select centre_tutor_pay_list(%L, null)', t.id('P')),
  format('select centre_tutor_pay_detail(%L, %L, null)', t.id('P'), t.id('Tali')),
  format('select centre_tutor_pay_adjust(%L,%L,100,null,%L)', t.id('P'), t.id('Tali'), 'x'),
  format('select centre_tutor_pay_record(%L,%L,null,100,%L,%L)', t.id('P'), t.id('Tali'), current_date, 'bank'),
  format('select centre_tutor_pay_reverse(%L,%L)', (select id from tutor_pay_payments limit 1), 'x'),
  format('select centre_tutor_pay_export_log(%L,null,1,1)', t.id('P')),
  format('select centre_tutor_taught_report(%L,null)', t.id('P'))] $$;
grant execute on all functions in schema pg_temp to public;
-- people who must be refused with NOT_FOUND: tutors, parents, switched-off staff, strangers, solo owners, another centre's owner
create function pg_temp.refuse_all(p_user text, p_who text, p_expect text default 'NOT_FOUND') returns void language plpgsql as $$
declare q text; k int := 0;
begin
  foreach q in array pg_temp.calls() loop
    k := k + 1;
    perform pg_temp.refused(p_user, q, p_expect, p_who || ' refused (function ' || k || ')');
  end loop;
end $$;
grant execute on all functions in schema pg_temp to public;
select pg_temp.refuse_all(:'tia', 'a TUTOR (the owner''s rule: tutors never see rates or pay)');
select pg_temp.refuse_all(:'par', 'a parent');
select pg_temp.refuse_all(:'off', 'switched-off staff');
select pg_temp.refuse_all(:'stranger', 'a stranger');
select pg_temp.refuse_all(:'solo', 'a solo owner');
select pg_temp.refuse_all(:'o2', 'the owner of ANOTHER centre');
select pg_temp.refuse_all(:'invr', 'staff without run_tutor_pay (invoices, payments and revenue only)', 'NOT_ALLOWED');
-- anonymous callers can't even reach the functions
select pg_temp.refused('', format('select centre_tutor_pay_list(%L, null)', t.id('P')), 'permission denied', 'anonymous: pay list');
select pg_temp.refused('', format('select centre_tutor_rate_list(%L)', t.id('P')), 'permission denied', 'anonymous: rates');
select pg_temp.refused('', format('select centre_tutor_pay_rows(%L, current_date, current_date, null)', t.id('P')), 'permission denied', 'anonymous: the calculation itself');
select pg_temp.refused(:'o1', format('select centre_tutor_pay_rows(%L, current_date, current_date, null)', t.id('P')), 'permission denied', 'even the owner can''t call the raw calculation from a browser (it has no gate of its own)');
select pg_temp.refused(:'tia', format('select centre_tutor_rate_for(%L, %L, null, null, current_date)', t.id('P'), t.id('Tia')), 'permission denied', 'a tutor can''t call the rate lookup directly');
-- allowed: the owner, and staff with run_tutor_pay
select t.ok(jsonb_typeof(pg_temp.call(:'payer', format('select centre_tutor_rate_list(%L)', t.id('P')))) = 'object', 'staff with run_tutor_pay can open the rates');
select t.ok(jsonb_typeof(pg_temp.call(:'payer', format('select centre_tutor_pay_list(%L, null)', t.id('P')))) = 'object', 'staff with run_tutor_pay can open the pay list');
select t.ok(jsonb_typeof(pg_temp.call(:'o1', format('select centre_tutor_pay_list(%L, null)', t.id('P')))) = 'object', 'the owner can open the pay list');
select t.ok((pg_temp.call(:'payer', format('select centre_tutor_pay_export_log(%L, %L, 3, 12345)', t.id('P'), pg_temp.d1(5)))->>'logged') = 'true', 'exporting the list is logged');
-- the tables: tutors, parents, other staff and strangers read nothing; nobody writes from a browser
set role authenticated;
select t.as(:'tia');
select t.eq((select count(*) from tutor_pay_rates), 0, 'a tutor reads NO rate rows');
select t.eq((select count(*) from tutor_pay_adjustments), 0, 'a tutor reads no adjustments');
select t.eq((select count(*) from tutor_pay_payments), 0, 'a tutor reads no pay records');
select t.as(:'par');  select t.eq((select count(*) from tutor_pay_rates) + (select count(*) from tutor_pay_payments), 0, 'a parent reads nothing');
select t.as(:'invr'); select t.eq((select count(*) from tutor_pay_rates) + (select count(*) from tutor_pay_adjustments) + (select count(*) from tutor_pay_payments), 0, 'staff without run_tutor_pay read nothing');
select t.as(:'o2');   select t.eq((select count(*) from tutor_pay_rates), 0, 'another centre''s owner reads nothing');
select t.as(:'payer'); select t.ok((select count(*) from tutor_pay_rates) > 10 and (select count(*) from tutor_pay_adjustments) > 0 and (select count(*) from tutor_pay_payments) > 0, 'staff with run_tutor_pay read the rows of their centre');
select t.as(:'o1');
select t.fails(format($q$insert into tutor_pay_rates(org_id, membership_id, method, amount_cents, effective_from, reason) values (%L, %L, 'per_lesson', 1, current_date, 'x')$q$, t.id('P'), t.id('Tia')), 'the owner can''t insert a rate straight into the table');
select t.fails(format($q$update tutor_pay_rates set amount_cents = 1 where org_id = %L$q$, t.id('P')), 'the owner can''t edit a rate');
select t.fails(format($q$delete from tutor_pay_adjustments where org_id = %L$q$, t.id('P')), 'the owner can''t delete an adjustment');
select t.fails(format($q$insert into tutor_pay_payments(org_id, membership_id, tutor_name, period_from, period_to, amount_cents, paid_on, method) values (%L, %L, 'x', current_date, current_date, 1, current_date, 'bank')$q$, t.id('P'), t.id('Tia')), 'the owner can''t record pay straight into the table');
reset role; select set_config('request.jwt.claims', '', false);
-- append-only even for the database owner (only deleting the whole organisation is allowed)
select t.fails($q$update tutor_pay_rates set amount_cents = amount_cents + 1$q$, 'a rate row can''t be updated, even by the database owner');
select t.fails($q$delete from tutor_pay_rates where true$q$, 'a rate row can''t be deleted');
select t.fails($q$update tutor_pay_adjustments set reason = 'edited' where true$q$, 'an adjustment can''t be edited');
select t.fails($q$delete from tutor_pay_adjustments where true$q$, 'an adjustment can''t be deleted');
select t.fails($q$update tutor_pay_payments set amount_cents = 1 where true$q$, 'a pay record can''t be edited');
select t.fails($q$delete from tutor_pay_payments where true$q$, 'a pay record can''t be deleted');
select t.fails(format($q$insert into tutor_pay_payments(org_id, kind, reverses_payment_id, membership_id, tutor_name, period_from, period_to, amount_cents, paid_on, method)
  select org_id, 'reversal', id, membership_id, tutor_name, period_from, period_to, amount_cents + 1, paid_on, method from tutor_pay_payments where kind = 'payment' limit 1$q$), 'a reversal for a different amount is refused');
select t.fails(format($q$insert into tutor_pay_rates(org_id, membership_id, method, amount_cents, percent_bp, effective_from, reason) values (%L, %L, 'per_lesson', 5, 5, current_date, 'x')$q$, t.id('P'), t.id('Tia')), 'a rate with both an amount and a percentage is refused by the table itself');
select t.fails(format($q$insert into tutor_pay_rates(org_id, membership_id, method, amount_cents, effective_from, reason) values (%L, %L, 'per_lesson', 5, current_date, 'x')$q$, t.id('SOLO'), t.id('Tia')), 'a solo organisation can''t have tutor pay rows');
-- a removed person's id becomes null; the row (the centre's record) stays and the rest never changes
insert into memberships(org_id, user_id, invited_email, display_name, role, permissions, status) values (t.id('P'), null, 'gone@tutors.test', 'Gone Tutor', 'tutor', '{}', 'invited');
insert into tutor_pay_rates(org_id, membership_id, method, amount_cents, effective_from, reason)
  values (t.id('P'), (select id from memberships where invited_email = 'gone@tutors.test'), 'per_lesson', 100, current_date, 'x');
delete from memberships where invited_email = 'gone@tutors.test';
select t.ok((select count(*) = 1 from tutor_pay_rates where membership_id is null and amount_cents = 100), 'deleting a tutor''s membership keeps their rate rows (membership cleared, nothing else changes)');

-- ================================================================== 14. tutors never see rates, fees or pay through ANY function they may call
select t.ok(not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname ~ '^tutor_my_(pay|rates)'), 'there is no tutor-facing pay or rate function (the plan''s tutor_my_pay / tutor_my_rates are deliberately not built)');
select t.ok(not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname ~ '^tutor_pay_' and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))),
            'the internal tutor_pay_* trigger and helper functions can''t be called from a browser at all');
select t.ok(not exists (
  select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('tutor_my_lessons', 'tutor_mark_attendance')
     and pg_get_function_result(p.oid) ~* '(^|[ ,(_])(rate|pay|paid|payout|fee|fees|price|amount|cents|invoice|percent|salary|earn)([ ,)_]|$)'),
  'the two functions tutors can call return no rate, pay, fee, price, amount, cents or invoice column (grep of the declared return types)');
select t.ok((select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('tutor_my_lessons', 'tutor_mark_attendance')) = 2, 'the grep really looked at the two tutor functions');
select t.ok((select pg_get_function_result(p.oid) from pg_proc p where p.proname = 'centre_tutor_pay_list') = 'jsonb', 'the pay functions return jsonb to staff only (their gate refuses tutors)');
-- what tutor_my_lessons actually returns for a tutor of this centre carries no money keys
select t.ok(not exists (select 1 from information_schema.routines r where r.routine_schema = 'public' and r.routine_name like 'tutor\_my\_%' and r.routine_name not in ('tutor_my_lessons')),
            'no other tutor_my_* function exists');

-- ================================================================== 15. audit
select t.ok((select count(*) >= 10 from audit_log where org_id = t.id('P') and action = 'centre_tutor_rate_set'), 'every rate change has a summary line in the audit log');
select t.ok((select count(*) >= 3 from audit_log where org_id = t.id('P') and action = 'centre_tutor_pay_adjust'), 'adjustments are in the audit log');
select t.ok((select count(*) = 3 from audit_log where org_id = t.id('P') and action = 'centre_tutor_pay_record'), 'every recorded payment is in the audit log (3)');
select t.ok((select count(*) = 1 from audit_log where org_id = t.id('P') and action = 'centre_tutor_pay_reverse'), 'the reversal is in the audit log');
select t.ok((select count(*) = 1 from audit_log where org_id = t.id('P') and action = 'centre_tutor_pay_export' and (after->>'rows')::int = 3 and (after->>'total_cents')::bigint = 12345), 'the export is logged with counts and total only');
select t.ok((select count(*) > 10 from audit_log where org_id = t.id('P') and table_name = 'tutor_pay_rates' and action = 'insert' and after->>'reason' = '[redacted]'), 'the row copies in the audit log have the free-text reason redacted');
select t.ok(not exists (select 1 from audit_log where org_id = t.id('P') and action like 'centre_tutor_%' and (after::text ~* 'Tutor Tali|Pay run|Great month|Lost textbook')), 'the summary lines carry no names, references or reasons');
select t.ok((select count(*) >= 1 from audit_log where org_id = t.id('P') and table_name = 'tutor_pay_payments' and action = 'insert' and after->>'reference' = '[redacted]'), 'payment references are redacted in the audit copy');

-- ================================================================== 16. the tables are covered by the whole-organisation delete (cascade)
select t.ok((select count(*) = 3 from pg_constraint c where c.contype = 'f' and c.confdeltype = 'c' and c.conrelid in ('tutor_pay_rates'::regclass, 'tutor_pay_adjustments'::regclass, 'tutor_pay_payments'::regclass)
              and c.confrelid = 'organisations'::regclass), 'each pay table cascades with its organisation');
