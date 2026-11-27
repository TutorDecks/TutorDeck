-- T4 step S7b tests: a centre tutor sees their OWN pay (tutor_my_pay_modes / tutor_my_pay / tutor_my_pay_month / tutor_my_pay_adjustments) and nothing else.
-- Covers: the setting (off / monthly_total / per_lesson_and_total, missing key = default, pay mode report or off = nothing, bad value refused on save), the figures
-- (released vs held/pending, carried over, class shares, cancelled lessons, fixed monthly pay, a percentage rate, bonus and deduction lines, the pay run recorded),
-- who is refused (parent, solo owner, stranger, switched-off member, signed-out), tutors of two centres, and the guard that fails if ANY column of a parent fee,
-- rate, percentage base, amount, paid, invoice or another person's data can appear in what these functions return (declared return types AND real output).
-- Runs after centre_tutor_pay_test.sql in the same throwaway database (reuses the t.* helpers). All names are FAKE. Dates are relative to today so it keeps passing.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000f801', 'op.owner@centre.test'),  ('00000000-0000-0000-0000-00000000f802', 'op.pay@centre.test'),
  ('00000000-0000-0000-0000-00000000f803', 'op.tia@centre.test'),    ('00000000-0000-0000-0000-00000000f804', 'op.tom@centre.test'),
  ('00000000-0000-0000-0000-00000000f805', 'op.tess@centre.test'),   ('00000000-0000-0000-0000-00000000f806', 'op.parent@centre.test'),
  ('00000000-0000-0000-0000-00000000f807', 'op.off@centre.test'),    ('00000000-0000-0000-0000-00000000f808', 'op.owner2@centre.test'),
  ('00000000-0000-0000-0000-00000000f809', 'op.solo@centre.test'),   ('00000000-0000-0000-0000-00000000f80a', 'op.stranger@centre.test'),
  ('00000000-0000-0000-0000-00000000f80b', 'op.quinn@centre.test');
\set o1 '00000000-0000-0000-0000-00000000f801'
\set payer '00000000-0000-0000-0000-00000000f802'
\set tia '00000000-0000-0000-0000-00000000f803'
\set tom '00000000-0000-0000-0000-00000000f804'
\set tess '00000000-0000-0000-0000-00000000f805'
\set par '00000000-0000-0000-0000-00000000f806'
\set off '00000000-0000-0000-0000-00000000f807'
\set o2 '00000000-0000-0000-0000-00000000f808'
\set solo '00000000-0000-0000-0000-00000000f809'
\set stranger '00000000-0000-0000-0000-00000000f80a'
\set quinn '00000000-0000-0000-0000-00000000f80b'

-- month 1 of the test: the first of the month 2 months ago (all lessons sit on days 1-28, so every month is long enough). Month 2 is the next one.
select date_trunc('month', current_date - interval '2 months')::date as m0 \gset
create temp table td as select :'m0'::date as m0;
grant select on td to authenticated, anon;
create function pg_temp.d1(n int) returns date language sql as $$ select (select m0 from td) + n $$;
create function pg_temp.d2(n int) returns date language sql as $$ select ((select m0 from td) + interval '1 month')::date + n $$;
create function pg_temp.m(n int) returns date language sql as $$ select ((select m0 from td) + make_interval(months => n))::date $$;

-- ------------------------------------------------------------------ helpers
create function pg_temp.base(p_tp jsonb) returns jsonb language sql as $$
  select jsonb_set(t.centre_settings(), '{profile,gst_registered}', 'false') || jsonb_build_object(
    'billing', jsonb_build_object('model', 'postpaid_lessons', 'trials', jsonb_build_object('charged', false)),
    'invoicing', jsonb_build_object('grouping', 'family', 'due_days', 7),
    'lessons', jsonb_build_object('class_type', 'both'),
    'tutor_pay', jsonb_build_object('mode', 'full', 'payable_when', 'parent_paid', 'rate_model', 'per_hour', 'percent_base', 'billed_after_discounts',
                 'part_payments', 'after_full', 'cancelled_lessons', 'pay_if_charged', 'group_count', 'attended', 'adjustments', true,
                 'cycle', jsonb_build_object('cutoff_day', 31, 'pay_day', 7)) || p_tp) $$;
create function pg_temp.cfg(p_org uuid, p_tp jsonb) returns void language plpgsql as $$
begin
  insert into org_settings(org_id, version, schema_version, effective_from, settings)
  values (p_org, (select coalesce(max(version), 0) + 1 from org_settings where org_id = p_org), 1, '2000-01-01', pg_temp.base(p_tp));
  insert into org_settings(org_id, version, schema_version, effective_from, settings)
  values (p_org, (select coalesce(max(version), 0) + 1 from org_settings where org_id = p_org), 1, current_date, pg_temp.base(p_tp));
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
-- what a tutor's browser gets back from a set-returning pay function: a JSON array of its rows
create function pg_temp.rows(p_user text, p_fn text) returns jsonb language sql as $$
  select pg_temp.call(p_user, format('select coalesce(jsonb_agg(to_jsonb(x)), %L::jsonb) from %s x', '[]', p_fn)) $$;
create function pg_temp.lessons(p_user text) returns jsonb language sql as $$ select pg_temp.rows(p_user, format('tutor_my_pay(%L::date, %L::date)', pg_temp.d1(0), pg_temp.d1(40))) $$;
create function pg_temp.month(p_user text, p_month date) returns jsonb language sql as $$ select pg_temp.rows(p_user, format('tutor_my_pay_month(%L::date)', p_month)) $$;
create function pg_temp.adjs(p_user text, p_month date) returns jsonb language sql as $$ select pg_temp.rows(p_user, format('tutor_my_pay_adjustments(%L::date)', p_month)) $$;
-- one field of the row whose org_name is p_org's name (or the only row)
create function pg_temp.f(p_rows jsonb, p_org text, p_key text) returns text language sql as $$
  select e->>p_key from jsonb_array_elements(p_rows) e where p_org is null or e->>'org_name' = p_org limit 1 $$;
create function pg_temp.pay_of(p_rows jsonb, p_label text) returns text language sql as $$
  select coalesce(e->>'pay_cents', 'null') || ':' || (e->>'pay_state') from jsonb_array_elements(p_rows) e where (e->>'lesson_id')::uuid = t.id(p_label) $$;

-- output text with the ids taken out (a random id can contain any digits, so digit checks must not look at them)
create function pg_temp.nouuid(p text) returns text language sql immutable as $$ select regexp_replace(p, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '', 'g') $$;
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
create function pg_temp.les(p_org text, p_label text, p_stu int, p_tutor text, p_date date, p_status text default 'done', p_att text default null,
  p_comp numeric default null, p_sess uuid default null, p_amount numeric default 50) returns uuid language plpgsql as $$
declare i uuid := gen_random_uuid();
begin
  insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, attendance, compensation, session_id, taught_by)
  values (i, (select created_by from organisations where id = t.id(p_org)), t.id(p_org), t.id(p_org || '_s' || p_stu), p_date, '10:00', '11:00', 50, p_amount, p_status, p_att, p_comp, p_sess, t.id(p_tutor));
  perform t.put(p_label, i);
  return i;
end $$;
create function pg_temp.inv(p_org text, p_label text, p_fam int, p_issue date, p_lessons text[], p_cents bigint[]) returns uuid language plpgsql as $$
declare i uuid := gen_random_uuid(); k int; sub bigint := 0;
begin
  insert into centre_invoices(id, org_id, kind, household_id, period_start, period_end) values (i, t.id(p_org), 'lesson', t.id(p_org || '_h' || p_fam), date_trunc('month', p_issue)::date, p_issue);
  for k in 1 .. array_length(p_lessons, 1) loop
    insert into centre_invoice_lines(org_id, invoice_id, position, lesson_id, student_id, description, qty, unit_cents)
    values (t.id(p_org), i, k, t.id(p_lessons[k]), (select student_id from lessons where id = t.id(p_lessons[k])), 'Lesson', 1, p_cents[k]);
    sub := sub + p_cents[k];
  end loop;
  update centre_invoices set status = 'issued', issue_date = p_issue, due_date = p_issue + 7, gst_registered = false, gst_rate_bp = 0, net_cents = sub, gst_cents = 0, total_cents = sub where id = i;
  perform t.put(p_label, i);
  return i;
end $$;
create function pg_temp.pay(p_org text, p_inv text, p_fam int, p_cents bigint, p_on date) returns uuid language plpgsql as $$
declare p uuid := gen_random_uuid();
begin
  insert into centre_payments(id, org_id, household_id, method, amount_cents, received_on) values (p, t.id(p_org), t.id(p_org || '_h' || p_fam), 'cash', p_cents, p_on);
  insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (t.id(p_org), p, t.id(p_inv), p_cents);
  return p;
end $$;
create function pg_temp.owner(p_sql text) returns jsonb language sql as $$ select pg_temp.call('00000000-0000-0000-0000-00000000f801', p_sql) $$;
create function pg_temp.rate(p_org text, p_tutor text, p_method text, p_amount bigint, p_pct int, p_from date) returns jsonb language sql as $$
  select pg_temp.call(case when p_org = 'Q' then '00000000-0000-0000-0000-00000000f808' else '00000000-0000-0000-0000-00000000f801' end, format('select centre_tutor_rate_set(%L, %L, null, null, %L, %L, %L, %L, %L)', t.id(p_org), t.id(p_tutor), p_method, p_amount, p_pct, p_from, 'Test rate')) $$;
grant execute on all functions in schema pg_temp to public;

-- ------------------------------------------------------------------ the centres and their people
set role authenticated; select t.as(:'o1');
select t.put('P', org_create_centre('Own Pay Centre P', pg_temp.base('{}')));
select t.as(:'o2');
select t.put('Q', org_create_centre('Own Pay Centre Q', pg_temp.base('{}')));
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, display_name, role, permissions, status, employment_type) values
  (t.id('P'), :'payer', 'Payroll Pat', 'staff', array['run_tutor_pay'], 'active', null),
  (t.id('P'), :'tia',   'Tutor Tia',   'tutor', '{}', 'active', 'employee'),
  (t.id('P'), :'tom',   'Tutor Tom',   'tutor', '{}', 'active', 'freelancer'),
  (t.id('P'), :'tess',  'Tutor Tess',  'tutor', '{}', 'active', 'freelancer'),
  (t.id('P'), :'par',   'Parent Pia',  'parent', '{}', 'active', null),
  (t.id('P'), :'off',   'Switched off', 'tutor', '{}', 'disabled', 'employee'),
  (t.id('Q'), :'tom',   'Tutor Tom',   'tutor', '{}', 'active', 'freelancer'),
  (t.id('Q'), :'quinn', 'Tutor Quinn', 'tutor', '{}', 'active', 'employee');
select t.put('Tia', id) from memberships where org_id = t.id('P') and user_id = :'tia';
select t.put('TomP', id) from memberships where org_id = t.id('P') and user_id = :'tom';
select t.put('Tess', id) from memberships where org_id = t.id('P') and user_id = :'tess';
select t.put('Off', id) from memberships where org_id = t.id('P') and user_id = :'off';
select t.put('TomQ', id) from memberships where org_id = t.id('Q') and user_id = :'tom';
select t.put('Quinn', id) from memberships where org_id = t.id('Q') and user_id = :'quinn';
select t.put('SOLO', org_personal(:'solo'));
select pg_temp.world('P', 10, :'o1');
select pg_temp.world('Q', 3, :'o2');

-- P: pay is worked out ("full"), tutors are paid after the parent pays. Q: tutors are paid when taught, and tutors see only the month's total.
select pg_temp.cfg(t.id('P'), '{}');
select pg_temp.cfg(t.id('Q'), '{"payable_when":"taught","tutors_see_own_pay":"monthly_total"}');

-- ================================================================== 0. the setting is checked when a centre saves it
select t.ok(true, 'setup done');
do $$
declare v text;
begin
  foreach v in array array['off', 'monthly_total', 'per_lesson_and_total'] loop
    perform org_validate_settings(null::uuid, pg_temp.base(jsonb_build_object('tutors_see_own_pay', v)));
  end loop;
  perform org_validate_settings(null::uuid, pg_temp.base('{}'));
  raise notice 'PASS the three values and a missing key are accepted';
end $$;
do $$
declare m text := 'allowed';
begin
  begin perform org_validate_settings(null::uuid, pg_temp.base('{"tutors_see_own_pay":"everything"}')); exception when others then m := sqlerrm; end;
  if m not like 'Unknown setting for tutors seeing their own pay%' then raise exception 'FAIL: a made-up value was not refused (%)', m; end if;
  m := 'allowed';
  begin perform org_validate_settings(null::uuid, pg_temp.base('{"tutors_see_own_pay":true}')); exception when others then m := sqlerrm; end;
  if m not like 'Unknown setting for tutors seeing their own pay%' then raise exception 'FAIL: a yes/no was not refused (%)', m; end if;
  raise notice 'PASS a made-up value and a yes/no are refused on save';
end $$;
-- ...and the owner's save goes through the same check
set role authenticated; select t.as(:'o1');
select t.fails(format($q$select org_save_settings(%L, pg_temp.base('{"tutors_see_own_pay":"bad"}'), current_date)$q$, t.id('P')), 'org_save_settings refuses a bad tutors_see_own_pay');
reset role; select set_config('request.jwt.claims', '', false);

-- ================================================================== 1. the story at centre P (all figures worked out by hand)
-- Tia: S$40 a lesson. T1 paid by the family in month 1 · T2 invoiced, unpaid · T3 not invoiced yet · T4 cancelled, not charged · T5 cancelled, charged and paid
-- · T6 paid only in month 2 · T7 cancelled, charge not typed yet · a class of three (C1-C3) all paid.
select pg_temp.rate('P', 'Tia', 'per_lesson', 4000, null, pg_temp.d1(0));
select pg_temp.les('P', 'T1', 1, 'Tia', pg_temp.d1(3));
select pg_temp.les('P', 'T2', 2, 'Tia', pg_temp.d1(5));
select pg_temp.les('P', 'T3', 3, 'Tia', pg_temp.d1(7));
select pg_temp.les('P', 'T4', 4, 'Tia', pg_temp.d1(9), 'cancelled', 'late_cancelled', 0);
select pg_temp.les('P', 'T5', 5, 'Tia', pg_temp.d1(11), 'cancelled', 'late_cancelled', 30);
select pg_temp.les('P', 'T6', 1, 'Tia', pg_temp.d1(20));
select pg_temp.les('P', 'T7', 4, 'Tia', pg_temp.d1(13), 'cancelled', 'late_cancelled', null);
select gen_random_uuid() as cls \gset
select pg_temp.les('P', 'C1', 7, 'Tia', pg_temp.d1(25), 'done', null, null, :'cls');
select pg_temp.les('P', 'C2', 8, 'Tia', pg_temp.d1(25), 'done', null, null, :'cls');
select pg_temp.les('P', 'C3', 9, 'Tia', pg_temp.d1(25), 'done', null, null, :'cls');
select pg_temp.inv('P', 'IA', 1, pg_temp.d1(4), array['T1'], array[5000]::bigint[]);   select pg_temp.pay('P', 'IA', 1, 5000, pg_temp.d1(10));
select pg_temp.inv('P', 'IB', 2, pg_temp.d1(6), array['T2'], array[5000]::bigint[]);                                    -- unpaid
select pg_temp.inv('P', 'IC', 5, pg_temp.d1(12), array['T5'], array[3000]::bigint[]);  select pg_temp.pay('P', 'IC', 5, 3000, pg_temp.d1(15));
select pg_temp.inv('P', 'ID', 1, pg_temp.d1(21), array['T6'], array[5000]::bigint[]);  select pg_temp.pay('P', 'ID', 1, 5000, pg_temp.d2(5));   -- paid in month 2
select pg_temp.inv('P', 'IE', 7, pg_temp.d1(26), array['C1'], array[4000]::bigint[]);  select pg_temp.pay('P', 'IE', 7, 4000, pg_temp.d1(27));
select pg_temp.inv('P', 'IF', 8, pg_temp.d1(26), array['C2'], array[4000]::bigint[]);  select pg_temp.pay('P', 'IF', 8, 4000, pg_temp.d1(27));
select pg_temp.inv('P', 'IG', 9, pg_temp.d1(26), array['C3'], array[4000]::bigint[]);  select pg_temp.pay('P', 'IG', 9, 4000, pg_temp.d1(27));

-- Tom: 33.33% of what the family is billed (a sentinel pair: neither the fee 8765 nor the percentage 3333 may ever reach him). Tess: a fixed S$200 a month.
select pg_temp.rate('P', 'TomP', 'percent_of_fee', null, 3333, pg_temp.d1(0));
select pg_temp.les('P', 'M1', 6, 'TomP', pg_temp.d1(12), 'done', null, null, null, 87.65);
select pg_temp.inv('P', 'IH', 6, pg_temp.d1(13), array['M1'], array[8765]::bigint[]);  select pg_temp.pay('P', 'IH', 6, 8765, pg_temp.d1(14));
select pg_temp.rate('P', 'Tess', 'monthly_fixed', 20000, null, pg_temp.d1(0));
select pg_temp.call(:'payer', format('select centre_tutor_pay_adjust(%L, %L, 1500, %L, %L)', t.id('P'), t.id('Tess'), pg_temp.d1(15), 'Great month'));
select pg_temp.call(:'payer', format('select centre_tutor_pay_adjust(%L, %L, -500, %L, %L)', t.id('P'), t.id('Tess'), pg_temp.d1(16), 'Lost textbook'));

-- centre Q: Tom (also a tutor there) S$70 a lesson, Quinn S$10 a lesson, both paid as soon as taught
select pg_temp.rate('Q', 'TomQ', 'per_lesson', 7000, null, pg_temp.d1(0));
select pg_temp.rate('Q', 'Quinn', 'per_lesson', 1000, null, pg_temp.d1(0));
select pg_temp.les('Q', 'Q1', 1, 'TomQ', pg_temp.d1(5));
select pg_temp.les('Q', 'Q2', 2, 'Quinn', pg_temp.d1(6));

-- ------------------------------------------------------------------ 1a. per lesson (setting: default = each lesson and the total)
select pg_temp.lessons(:'tia') as tl \gset
select t.ok(pg_temp.pay_of(:'tl', 'T1') = '4000:amount', 'a lesson the family paid for shows its amount (S$40.00)');
select t.ok(pg_temp.pay_of(:'tl', 'T2') = 'null:pending', 'a lesson whose invoice is unpaid shows "pending" with NO amount');
select t.ok(pg_temp.pay_of(:'tl', 'T3') = 'null:pending', 'a lesson not invoiced yet shows "pending" with NO amount');
select t.ok(pg_temp.pay_of(:'tl', 'T4') is null, 'a free cancellation earns nothing: no row at all');
select t.ok(pg_temp.pay_of(:'tl', 'T5') = '4000:amount', 'a cancellation the family was charged for shows its amount');
select t.ok(pg_temp.pay_of(:'tl', 'T6') = '4000:amount', 'a lesson paid for later shows its amount now (released as of today)');
select t.ok(pg_temp.pay_of(:'tl', 'T7') = 'null:pending', 'a cancellation whose charge is not typed yet shows "pending"');
select t.ok((select array_agg((e->>'pay_cents')::bigint order by (e->>'pay_cents')::bigint) from jsonb_array_elements(:'tl'::jsonb) e where (e->>'lesson_id')::uuid in (t.id('C1'), t.id('C2'), t.id('C3'))) = array[1333, 1333, 1334]::bigint[],
            'a class of three is paid once (S$40.00), shared 13.33 / 13.33 / 13.34 (the spare cent goes to one of them)');
select t.ok((select count(*) = 9 from jsonb_array_elements(:'tl'::jsonb)), 'nine lessons have a pay line (the free cancellation has none)');
select t.ok(not exists (select 1 from jsonb_array_elements(:'tl'::jsonb) e where e->>'pay_state' = 'pending' and e->>'pay_cents' is not null), 'a pending line never carries an amount');
select t.ok(not exists (select 1 from jsonb_array_elements(:'tl'::jsonb) e where (e->>'org_name') <> 'Own Pay Centre P'), 'only the centre this tutor teaches at');
select t.ok((select count(*) = 9 from jsonb_array_elements(:'tl'::jsonb) e where (e->>'lesson_id')::uuid in (select id from lessons where taught_by = t.id('Tia'))), 'every line is one of this tutor''s own lessons');
select t.ok(not exists (select 1 from jsonb_array_elements(:'tl'::jsonb) e where (e->>'lesson_id')::uuid in (t.id('M1'), t.id('Q1'), t.id('Q2'))), 'no other tutor''s lesson appears');

-- ------------------------------------------------------------------ 1b. the month: figures, carried over, pending, and equal to what the centre's own pay list says
select pg_temp.month(:'tia', pg_temp.m(0)) as tm1 \gset
select t.ok(pg_temp.f(:'tm1', null, 'earned_cents') = '12000', 'month 1: earned = T1 + T5 + the class = S$120.00');
select t.ok(pg_temp.f(:'tm1', null, 'total_cents') = '12000' and pg_temp.f(:'tm1', null, 'carry_cents') = '0' and pg_temp.f(:'tm1', null, 'adjustments_cents') = '0', 'month 1: total = earned (nothing carried, no bonus)');
select t.ok(pg_temp.f(:'tm1', null, 'pending_lessons') = '4', 'month 1: four lessons are pending (T2, T3, T6 not yet paid then, T7), counted but never valued');
select t.ok(pg_temp.f(:'tm1', null, 'lessons') = '7', 'month 1: seven lessons taught (T1, T2, T3, T6, C1-C3)');
select t.ok(pg_temp.f(:'tm1', null, 'run_recorded') = 'false', 'month 1: the pay run is not recorded yet');
select t.ok(pg_temp.f(:'tm1', null, 'period_from') = pg_temp.m(0)::text and pg_temp.f(:'tm1', null, 'period_to') = (pg_temp.m(1) - 1)::text, 'month 1: the period is the calendar month (cut-off day 31)');
select t.ok(pg_temp.f(:'tm1', null, 'pay_view') = 'per_lesson_and_total', 'the row says which view this centre gives');
select pg_temp.month(:'tia', pg_temp.m(1)) as tm2 \gset
select t.ok(pg_temp.f(:'tm2', null, 'carry_cents') = '12000' and pg_temp.f(:'tm2', null, 'earned_cents') = '4000' and pg_temp.f(:'tm2', null, 'total_cents') = '16000',
            'month 2: S$120 carried over + T6 released (S$40) = S$160.00');
select t.ok(pg_temp.f(:'tm2', null, 'pending_lessons') = '3', 'month 2: three still pending (T2, T3, T7)');
-- the same numbers the centre's staff see
select pg_temp.owner(format('select centre_tutor_pay_list(%L, %L)', t.id('P'), pg_temp.m(0))) as stl1 \gset
select pg_temp.owner(format('select centre_tutor_pay_list(%L, %L)', t.id('P'), pg_temp.m(1))) as stl2 \gset
select t.ok((select (e->>'due_cents')::bigint from jsonb_array_elements((:'stl1'::jsonb)->'tutors') e where e->>'name' = 'Tutor Tia') = pg_temp.f(:'tm1', null, 'total_cents')::bigint, 'the tutor''s month 1 total equals the pay list''s "due" for them');
select t.ok((select (e->>'due_cents')::bigint from jsonb_array_elements((:'stl2'::jsonb)->'tutors') e where e->>'name' = 'Tutor Tia') = pg_temp.f(:'tm2', null, 'total_cents')::bigint, 'the tutor''s month 2 total equals the pay list''s "due" for them');
-- the lessons' amounts add up to the month's released money (as of today the three months' lessons: T1, T5, T6, class = S$160)
select t.ok((select sum((e->>'pay_cents')::bigint) from jsonb_array_elements(:'tl'::jsonb) e) = 16000, 'the per-lesson amounts add up to the money released so far (S$160.00)');
-- the current period (no month given) answers too, and ends today or later
select pg_temp.month(:'tia', null) as tnow \gset
select t.ok(jsonb_array_length(:'tnow'::jsonb) = 1 and pg_temp.f(:'tnow', null, 'period_to')::date >= current_date - 1, 'with no month given, the current pay period is used');

-- ------------------------------------------------------------------ 1c. percentage pay: Tom gets his share and never learns the fee or the percentage
select pg_temp.lessons(:'tom') as tml \gset
select pg_temp.month(:'tom', pg_temp.m(0)) as tmm \gset
select pg_temp.adjs(:'tom', pg_temp.m(0)) as tma \gset
select t.ok(pg_temp.pay_of(:'tml', 'M1') = '2921:amount', '33.33% of S$87.65 = S$29.21: the amount shows');
select t.ok(strpos(pg_temp.nouuid(:'tml' || :'tmm' || :'tma'), '8765') = 0 and strpos(pg_temp.nouuid(:'tml' || :'tmm' || :'tma'), '3333') = 0 and strpos(pg_temp.nouuid(:'tml' || :'tmm' || :'tma'), '87.65') = 0 and strpos(pg_temp.nouuid(:'tml' || :'tmm' || :'tma'), '33.33') = 0,
            'neither the fee (8765) nor the percentage (3333) appears anywhere in what Tom is sent');
select t.ok(jsonb_array_length(:'tml'::jsonb) = 1, 'Tom sees only his one lesson at the centre that shows lesson lines (Q shows totals only)');
select t.ok(not exists (select 1 from jsonb_array_elements(:'tml'::jsonb) e where e->>'org_name' = 'Own Pay Centre Q'), 'Centre Q set "monthly total": no lesson amounts from it');

-- ------------------------------------------------------------------ 1d. fixed monthly pay, bonus and deduction lines
select pg_temp.month(:'tess', pg_temp.m(0)) as tsm1 \gset
select pg_temp.adjs(:'tess', pg_temp.m(0)) as tsa1 \gset
select t.ok(pg_temp.f(:'tsm1', null, 'earned_cents') = '20000' and pg_temp.f(:'tsm1', null, 'adjustments_cents') = '1000' and pg_temp.f(:'tsm1', null, 'total_cents') = '21000', 'fixed S$200 + bonus S$15 - deduction S$5 = S$210.00');
select t.ok((select count(*) = 2 from jsonb_array_elements(:'tsa1'::jsonb)), 'the bonus and the deduction are one line each');
select t.ok((select count(*) = 1 from jsonb_array_elements(:'tsa1'::jsonb) e where e->>'label' = 'Great month' and e->>'kind' = 'bonus' and (e->>'adjustment_cents')::bigint = 1500 and e->>'effective_on' = pg_temp.d1(15)::text), 'the bonus line: staff''s label, S$15.00, its date');
select t.ok((select count(*) = 1 from jsonb_array_elements(:'tsa1'::jsonb) e where e->>'label' = 'Lost textbook' and e->>'kind' = 'deduction' and (e->>'adjustment_cents')::bigint = -500), 'the deduction line: staff''s label, minus S$5.00');
select pg_temp.month(:'tess', pg_temp.m(1)) as tsm2 \gset
select t.ok(pg_temp.f(:'tsm2', null, 'carry_cents') = '21000' and pg_temp.f(:'tsm2', null, 'earned_cents') = '20000' and pg_temp.f(:'tsm2', null, 'total_cents') = '41000', 'the next month carries the unpaid S$210 and adds the new S$200');
select t.ok(jsonb_array_length(pg_temp.adjs(:'tess', pg_temp.m(1))) = 0, 'a bonus belongs to the month it is dated in');
select t.ok(jsonb_array_length(pg_temp.lessons(:'tess')) = 0, 'a fixed-monthly tutor has no per-lesson amounts');
select t.ok(jsonb_array_length(pg_temp.adjs(:'tia', pg_temp.m(0))) = 0, 'Tia has no bonus lines, and never sees Tess''s');

-- ------------------------------------------------------------------ 1e. a tutor of TWO centres: one row each, each by its own centre's setting
select pg_temp.month(:'tom', pg_temp.m(0)) as tom2 \gset
select t.ok(jsonb_array_length(:'tom2'::jsonb) = 2, 'a tutor at two centres gets one month row for each');
select t.ok(pg_temp.f(:'tom2', 'Own Pay Centre P', 'total_cents') = '2921' and pg_temp.f(:'tom2', 'Own Pay Centre P', 'pay_view') = 'per_lesson_and_total', 'centre P: S$29.21, lesson lines on');
select t.ok(pg_temp.f(:'tom2', 'Own Pay Centre Q', 'total_cents') = '7000' and pg_temp.f(:'tom2', 'Own Pay Centre Q', 'pay_view') = 'monthly_total' and pg_temp.f(:'tom2', 'Own Pay Centre Q', 'pending_lessons') = '0',
            'centre Q (paid when taught, totals only): S$70.00 and nothing pending');
select pg_temp.rows(:'tom', 'tutor_my_pay_modes()') as tmodes \gset
select t.ok(pg_temp.f(:'tmodes', 'Own Pay Centre P', 'pay_view') = 'per_lesson_and_total' and pg_temp.f(:'tmodes', 'Own Pay Centre Q', 'pay_view') = 'monthly_total', 'the modes list shows each centre''s view');
-- Quinn teaches only at Q: sees only Q, and never the S$40 / S$29.21 / S$210 of the other centre
select pg_temp.month(:'quinn', pg_temp.m(0)) as qm \gset
select t.ok(jsonb_array_length(:'qm'::jsonb) = 1 and pg_temp.f(:'qm', null, 'org_name') = 'Own Pay Centre Q' and pg_temp.f(:'qm', null, 'total_cents') = '1000', 'a tutor of another centre sees only their own S$10.00');
select t.ok(jsonb_array_length(pg_temp.lessons(:'quinn')) = 0, 'Q shows totals only, so Quinn gets no lesson lines');
select t.ok(jsonb_array_length(pg_temp.adjs(:'quinn', pg_temp.m(0))) = 0, 'and none of Tess''s adjustment lines');

-- ================================================================== 2. every value of the setting
create function pg_temp.view_is(p_user text, p_exp text, p_msg text) returns void language plpgsql as $$
declare md jsonb := pg_temp.rows(p_user, 'tutor_my_pay_modes()');
begin
  if pg_temp.f(md, 'Own Pay Centre P', 'pay_view') <> p_exp then raise exception 'FAIL: % (modes says %)', p_msg, pg_temp.f(md, 'Own Pay Centre P', 'pay_view'); end if;
  raise notice 'PASS % : modes = %', p_msg, p_exp;
end $$;
grant execute on all functions in schema pg_temp to public;
-- per_lesson_and_total (the default, set above with no key): done in section 1.
select pg_temp.cfg(t.id('P'), '{"tutors_see_own_pay":"monthly_total"}');
select pg_temp.view_is(:'tia', 'monthly_total', 'monthly_total');
select t.ok(jsonb_array_length(pg_temp.lessons(:'tia')) = 0, 'monthly_total: no per-lesson amounts');
select t.ok(pg_temp.f(pg_temp.month(:'tia', pg_temp.m(0)), null, 'total_cents') = '12000' and pg_temp.f(pg_temp.month(:'tia', pg_temp.m(0)), null, 'pay_view') = 'monthly_total', 'monthly_total: the month total is there');
select t.ok(jsonb_array_length(pg_temp.adjs(:'tess', pg_temp.m(0))) = 2, 'monthly_total: the bonus and deduction lines are still shown (they are part of the total)');
select pg_temp.cfg(t.id('P'), '{"tutors_see_own_pay":"off"}');
select pg_temp.view_is(:'tia', 'off', 'off');
select t.ok(jsonb_array_length(pg_temp.lessons(:'tia')) = 0 and jsonb_array_length(pg_temp.month(:'tia', pg_temp.m(0))) = 0 and jsonb_array_length(pg_temp.adjs(:'tess', pg_temp.m(0))) = 0, 'off: nothing at all (no lesson lines, no month, no adjustments)');
select t.ok(jsonb_array_length(pg_temp.month(:'tom', pg_temp.m(0))) = 1 and pg_temp.f(pg_temp.month(:'tom', pg_temp.m(0)), null, 'org_name') = 'Own Pay Centre Q', 'off at P does not switch off Q for a tutor of both');
select pg_temp.cfg(t.id('P'), '{"tutors_see_own_pay":"per_lesson_and_total"}');
select pg_temp.view_is(:'tia', 'per_lesson_and_total', 'per_lesson_and_total');
select t.ok(jsonb_array_length(pg_temp.lessons(:'tia')) = 9 and pg_temp.f(pg_temp.month(:'tia', pg_temp.m(0)), null, 'total_cents') = '12000', 'per_lesson_and_total: lines and total');
-- the centre doesn't work out pay at all (report only or off): tutors see nothing, whatever the choice says
select pg_temp.cfg(t.id('P'), '{"mode":"report","tutors_see_own_pay":"per_lesson_and_total"}');
select pg_temp.view_is(:'tia', 'off', 'tutor_pay.mode = report');
select t.ok(jsonb_array_length(pg_temp.lessons(:'tia')) = 0 and jsonb_array_length(pg_temp.month(:'tia', pg_temp.m(0))) = 0, 'pay mode "report": nothing even if the choice says per lesson');
select pg_temp.cfg(t.id('P'), '{"mode":"off","tutors_see_own_pay":"per_lesson_and_total"}');
select pg_temp.view_is(:'tia', 'off', 'tutor_pay.mode = off');
select pg_temp.cfg(t.id('P'), '{}');
select pg_temp.view_is(:'tia', 'per_lesson_and_total', 'back to full, no key = the default');

-- ================================================================== 3. "held until the parent pays" vs "as soon as taught", and the pay run recorded
select pg_temp.cfg(t.id('P'), '{"payable_when":"taught"}');
select pg_temp.lessons(:'tia') as tl2 \gset
select t.ok(not exists (select 1 from jsonb_array_elements(:'tl2'::jsonb) e where e->>'pay_state' = 'pending' and e->>'lesson_id' in (t.id('T2')::text, t.id('T6')::text)), 'paid-when-taught: an unpaid invoice no longer holds the lesson');
select t.ok(pg_temp.pay_of(:'tl2', 'T2') = '4000:amount' and pg_temp.pay_of(:'tl2', 'T3') = '4000:amount', 'paid-when-taught: T2 and T3 show S$40.00 each');
select t.ok(pg_temp.pay_of(:'tl2', 'T7') = 'null:pending', 'paid-when-taught: a cancellation still waiting for its charge stays pending');
select pg_temp.cfg(t.id('P'), '{}');
select t.ok(pg_temp.pay_of(pg_temp.lessons(:'tia'), 'T2') = 'null:pending', 'back to "after the parent pays": T2 is pending again (money rules follow the settings in force)');
-- staff record the pay run for month 1: the tutor's figures are then marked final, and month 2 no longer carries it
select pg_temp.call(:'payer', format('select centre_tutor_pay_record(%L, %L, %L, 12000, current_date, %L, null, null)', t.id('P'), t.id('Tia'), pg_temp.m(0), 'bank'));
select t.ok(pg_temp.f(pg_temp.month(:'tia', pg_temp.m(0)), null, 'run_recorded') = 'true' and pg_temp.f(pg_temp.month(:'tia', pg_temp.m(0)), null, 'total_cents') = '12000', 'once staff record the pay run, month 1 says so and the total stays S$120.00');
select t.ok(pg_temp.f(pg_temp.month(:'tia', pg_temp.m(1)), null, 'carry_cents') = '0' and pg_temp.f(pg_temp.month(:'tia', pg_temp.m(1)), null, 'total_cents') = '4000', 'month 2 no longer carries what was paid (S$40.00 left: T6)');
select t.ok(strpos(pg_temp.month(:'tia', pg_temp.m(0))::text, 'bank') = 0, 'nothing about how or where it was paid is sent');
select t.ok(pg_temp.f(pg_temp.month(:'tom', pg_temp.m(0)), 'Own Pay Centre P', 'run_recorded') = 'false', 'another tutor''s month is not marked by Tia''s pay run');

-- ================================================================== 4. who is refused
create function pg_temp.calls() returns text[] language sql as $$ select array[
  'select * from tutor_my_pay_modes()',
  format('select * from tutor_my_pay(%L, %L)', current_date - 5, current_date),
  'select * from tutor_my_pay_month(null)',
  'select * from tutor_my_pay_adjustments(null)'] $$;
create function pg_temp.refuse_all(p_user text, p_who text, p_expect text default 'NOT_FOUND') returns void language plpgsql as $$
declare q text; k int := 0;
begin
  foreach q in array pg_temp.calls() loop
    k := k + 1;
    perform pg_temp.refused(p_user, q, p_expect, p_who || ' refused (function ' || k || ')');
  end loop;
end $$;
grant execute on all functions in schema pg_temp to public;
select pg_temp.refuse_all(:'par', 'a parent');
select pg_temp.refuse_all(:'off', 'a switched-off member');
select pg_temp.refuse_all(:'stranger', 'a stranger with no membership');
select pg_temp.refuse_all(:'solo', 'a solo owner (their own organisation is not a centre)');
select pg_temp.refuse_all('', 'a signed-out visitor', 'permission denied');
select pg_temp.refused(:'tia', format('select * from tutor_my_pay(%L, %L)', current_date - 90, current_date), 'BAD_RANGE', 'a range of more than 62 days');
select pg_temp.refused(:'tia', format('select * from tutor_my_pay(%L, %L)', current_date, current_date - 1), 'BAD_RANGE', 'a range that ends before it starts');
select pg_temp.refused(:'tia', 'select * from tutor_my_pay(null, null)', 'BAD_RANGE', 'no range');
select pg_temp.refused(:'tia', 'select * from tutor_own_pay_orgs()', 'permission denied', 'the internal helper can''t be called from a browser');
select pg_temp.refused(:'tia', format('select * from centre_tutor_pay_rows(%L, current_date, current_date, null)', t.id('P')), 'permission denied', 'the raw calculation still can''t be called from a browser');
select pg_temp.refused(:'tia', format('select centre_tutor_pay_list(%L, null)', t.id('P')), 'NOT_FOUND', 'a tutor still can''t open the staff pay list (everyone''s pay)');
select pg_temp.refused(:'tia', format('select centre_tutor_rate_list(%L)', t.id('P')), 'NOT_FOUND', 'a tutor still can''t open the rates');
-- allowed callers: staff and the owner see their OWN (empty) pay, never anyone else's
select t.ok(jsonb_array_length(pg_temp.rows(:'payer', 'tutor_my_pay_modes()')) = 1, 'staff can ask (they get their own centre row)');
select t.ok(pg_temp.f(pg_temp.month(:'payer', pg_temp.m(0)), null, 'total_cents') = '0' and pg_temp.f(pg_temp.month(:'o1', pg_temp.m(0)), null, 'total_cents') = '0', 'staff and the owner see only their own pay (nothing, they taught nothing)');
-- the tables themselves stay closed to tutors
set role authenticated; select t.as(:'tia');
select t.eq((select count(*) from tutor_pay_rates) + (select count(*) from tutor_pay_adjustments) + (select count(*) from tutor_pay_payments), 0, 'a tutor still reads NO pay table directly');
reset role; select set_config('request.jwt.claims', '', false);

-- ================================================================== 5. the guard: nothing about a parent's fee, a rate, a percentage, an amount, paid, an invoice or another person can be returned
create temp table fns(name text);
insert into fns values ('tutor_my_pay_modes'), ('tutor_my_pay'), ('tutor_my_pay_month'), ('tutor_my_pay_adjustments');
grant select on fns to authenticated;
select t.ok((select count(*) = 4 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in (select name from fns)), 'all four functions exist exactly once');
-- every declared output column is on this list ...
select t.ok(not exists (
  select 1 from pg_proc p cross join lateral unnest(p.proargnames, p.proargmodes) as a(nm, md)
   where p.pronamespace = 'public'::regnamespace and p.proname in (select name from fns) and a.md = 't'
     and a.nm not in ('org_id', 'org_name', 'pay_view', 'lesson_id', 'lesson_date', 'pay_state', 'pay_cents', 'period_from', 'period_to', 'lessons', 'earned_cents',
                      'adjustments_cents', 'carry_cents', 'total_cents', 'pending_lessons', 'run_recorded', 'effective_on', 'kind', 'adjustment_cents', 'label')),
  'every returned column is on the allow-list (only pay figures, dates and names)');
-- ... and none is named like something a parent pays, a rate, a percentage, an invoice, a person or anything of another tutor
select t.ok(not exists (
  select 1 from pg_proc p cross join lateral unnest(p.proargnames, p.proargmodes) as a(nm, md)
   where p.pronamespace = 'public'::regnamespace and p.proname in (select name from fns) and a.md = 't'
     and a.nm ~* '(fee|rate|percent|bp\y|base|amount|paid|invoice|price|student|household|parent|compensation|discount|gst|tutor|member|phone|contact|email|balance|owed|outstanding|deposit|credit|payment)'),
  'no returned column is named like a fee, rate, percentage, base, amount, paid, invoice, price, student, parent, tutor or membership');
select t.ok(not exists (select 1 from pg_proc p cross join lateral unnest(p.proallargtypes, p.proargmodes) as a(ty, md)
                         where p.pronamespace = 'public'::regnamespace and p.proname in (select name from fns) and a.md = 't' and a.ty in ('jsonb'::regtype, 'json'::regtype, 'record'::regtype)),
            'no output column is free-form json or a record (every column is declared and checked above)');
-- the function inputs name no organisation, tutor or student: they only ever answer for the caller
select t.ok(not exists (
  select 1 from pg_proc p cross join lateral unnest(p.proargnames, p.proargmodes) as a(nm, md)
   where p.pronamespace = 'public'::regnamespace and p.proname in (select name from fns) and a.md in ('i', 'b') and a.nm not in ('p_from', 'p_to', 'p_month')),
  'the only inputs are dates: no organisation, tutor or student id can be passed to ask about someone else');
select t.ok((select bool_and(p.prosecdef and p.provolatile = 's' and p.proconfig @> array['search_path=public, pg_temp']) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in (select name from fns)),
            'each is security definer, read-only (stable) and has its search_path pinned');
select t.ok((select bool_and(has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute')) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in (select name from fns)),
            'signed-in users may call them, signed-out visitors may not');
select t.ok(not has_function_privilege('authenticated', 'public.tutor_own_pay_orgs()'::regprocedure, 'execute') and not has_function_privilege('anon', 'public.tutor_own_pay_orgs()'::regprocedure, 'execute'), 'the internal helper is closed to browsers');
-- the real output, for everyone, never contains a parent's fee or invoice figure. The fees billed in this test (in cents and dollars) and every invoice / payment id:
select t.ok(not exists (
  select 1 from (select pg_temp.lessons(u)::text || pg_temp.month(u, pg_temp.m(0))::text || pg_temp.month(u, pg_temp.m(1))::text || pg_temp.adjs(u, pg_temp.m(0))::text || pg_temp.rows(u, 'tutor_my_pay_modes()')::text as j
                   from unnest(array[:'tia', :'tom', :'tess', :'quinn', :'payer', :'o1']) u) o
   where pg_temp.nouuid(j) ~ '(8765|87\.65|3333|5000|"fee|"rate|"percent|"invoice|"paid)' or j ~* (select string_agg(id::text, '|') from centre_invoices where org_id in (t.id('P'), t.id('Q')))),
  'the real output for every caller contains no fee (5000, 8765), no percentage (3333), no invoice id and no fee / rate / paid key');
-- a tutor's output names only their own centres and own lessons (no other person's id anywhere)
select t.ok(not exists (select 1 from (select pg_temp.lessons(:'tia')::text || pg_temp.month(:'tia', pg_temp.m(0))::text as j) o where j ~* (t.id('TomP')::text || '|' || t.id('Tess')::text || '|' || t.id('Quinn')::text || '|' || t.id('Tia')::text || '|' || t.id('P_s1')::text || '|' || t.id('P_h1')::text)),
            'no membership, student or household id appears in a tutor''s output');
