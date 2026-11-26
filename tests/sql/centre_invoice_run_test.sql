-- T4 step S2 tests: the invoice run (preview, drafts, approve and issue) — idempotency, hold-back scoped to one household, sibling discount,
-- GST on the shared vectors, immutability after issue, numbering, permissions and cross-centre refusals, solo / tutors read nothing.
-- Runs after centre_money_test.sql in the same throwaway database (reuses the t.* helpers). Builds its own centres and made-up people.
-- Run from the repository root (it reads tests/gst-vectors.csv, the same file tests/money.test.js and the S1 tests use).
-- Prices: every lesson is 1 hour at rate 50 = 5000 cents unless a test says otherwise. All names are FAKE.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000ba01', 'ir.owner@centre.test'),   ('00000000-0000-0000-0000-00000000ba02', 'ir.billing@centre.test'),
  ('00000000-0000-0000-0000-00000000ba03', 'ir.payments@centre.test'), ('00000000-0000-0000-0000-00000000ba04', 'ir.tutor@centre.test'),
  ('00000000-0000-0000-0000-00000000ba05', 'ir.parent@centre.test'),   ('00000000-0000-0000-0000-00000000ba06', 'ir.outsider@centre.test'),
  ('00000000-0000-0000-0000-00000000ba07', 'ir.off@centre.test'),      ('00000000-0000-0000-0000-00000000ba08', 'ir.owner2@centre.test'),
  ('00000000-0000-0000-0000-00000000ba09', 'ir.gst@centre.test'),      ('00000000-0000-0000-0000-00000000ba0a', 'ir.numbering@centre.test');
\set o1 '00000000-0000-0000-0000-00000000ba01'
\set bill '00000000-0000-0000-0000-00000000ba02'
\set paym '00000000-0000-0000-0000-00000000ba03'
\set tut '00000000-0000-0000-0000-00000000ba04'
\set par '00000000-0000-0000-0000-00000000ba05'
\set out '00000000-0000-0000-0000-00000000ba06'
\set off '00000000-0000-0000-0000-00000000ba07'
\set o2 '00000000-0000-0000-0000-00000000ba08'
\set o3 '00000000-0000-0000-0000-00000000ba09'
\set o4 '00000000-0000-0000-0000-00000000ba0a'
\set solo '00000000-0000-0000-0000-0000000000a1'

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today, date_trunc('month', (now() at time zone 'Asia/Singapore')::date - interval '1 month')::date as m;
grant select on td to authenticated, anon;

-- base settings: postpaid, invoice per family, prefix INV, 7 days to pay, review before sending, GST 9% exclusive
create function pg_temp.base_settings() returns jsonb language sql as $$
  select jsonb_set(jsonb_set(jsonb_set(jsonb_set(t.centre_settings(), '{profile,invoice_prefix}', '"INV"'), '{billing,model}', '"postpaid_lessons"'),
         '{invoicing}', '{"grouping":"family","due_days":7,"review_before_sending":true}'::jsonb), '{billing,absences}', '{"mode":"charged","notice_hours":24}'::jsonb) $$;
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
create function pg_temp.pv(p_org uuid, p_owner uuid, p_month date default null) returns jsonb language plpgsql as $$
begin perform t.as(p_owner::text); return centre_invoice_run_preview(p_org, coalesce(p_month, (select m from td))); end $$;
create function pg_temp.mk(p_org uuid, p_owner uuid, p_stu uuid, p_day int, p_status text, p_att text default null, p_comp numeric default null,
                           p_amount numeric default 50, p_trial boolean default false, p_month date default null) returns uuid language plpgsql as $$
declare lid uuid := gen_random_uuid();
begin
  insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, attendance, compensation, trial, subject)
  values (lid, p_owner, p_org, p_stu, coalesce(p_month, (select m from td)) + (p_day - 1), '16:00', '17:00', 50, p_amount, p_status, p_att, p_comp, p_trial, 'Math');
  return lid;
end $$;
-- one element of a preview list, by household / student name
create function pg_temp.unit(p jsonb, arr text, nm text) returns jsonb language sql as $$
  select e from jsonb_array_elements(p->arr) e where e->>'name' = nm limit 1 $$;
grant execute on all functions in schema pg_temp to public;

select t.put('solo_org', org_personal(:'solo'));
-- ===================================================================== the world: centre 1 (GST 9%, family invoices), centre 2 (somebody else's)
set role authenticated; select t.as(:'o1');
select t.put('c1', org_create_centre('Invoice Run Centre', pg_temp.base_settings()));
select t.as(:'o2');
select t.put('c2', org_create_centre('Other Run Centre', pg_temp.base_settings()));
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('c1'), :'bill', 'Billing Bea',   'staff',  array['issue_invoices'], 'active'),
  (t.id('c1'), :'paym', 'Payments Pat',  'staff',  array['record_payments', 'view_revenue', 'manage_students', 'manage_timetable'], 'active'),
  (t.id('c1'), :'tut',  'Tutor Tia',     'tutor',  '{}', 'active'),
  (t.id('c1'), :'par',  'Parent Pia',    'parent', '{}', 'active'),
  (t.id('c1'), :'off',  'Switched off',  'staff',  array['issue_invoices'], 'disabled');

insert into households(id, org_id, name) values
  ('00000000-0000-0000-0000-00000000ca01', t.id('c1'), 'Lim Family'),  ('00000000-0000-0000-0000-00000000ca02', t.id('c1'), 'Tan Family'),
  ('00000000-0000-0000-0000-00000000ca03', t.id('c1'), 'Ong Family'),  ('00000000-0000-0000-0000-00000000ca04', t.id('c1'), 'Goh Family'),
  ('00000000-0000-0000-0000-00000000ca05', t.id('c1'), 'Empty Family'), ('00000000-0000-0000-0000-00000000ca09', t.id('c2'), 'Elsewhere Family');
insert into students(id, tutor_id, org_id, name, household_id, created_at) values
  ('00000000-0000-0000-0000-00000000da01', :'o1', t.id('c1'), 'Sophie Lim', '00000000-0000-0000-0000-00000000ca01', '2026-01-01'),
  ('00000000-0000-0000-0000-00000000da02', :'o1', t.id('c1'), 'Sam Lim',    '00000000-0000-0000-0000-00000000ca01', '2026-02-01'),
  ('00000000-0000-0000-0000-00000000da03', :'o1', t.id('c1'), 'Tara Tan',   '00000000-0000-0000-0000-00000000ca02', '2026-01-01'),
  ('00000000-0000-0000-0000-00000000da04', :'o1', t.id('c1'), 'Oscar Ong',  '00000000-0000-0000-0000-00000000ca03', '2026-01-01'),
  ('00000000-0000-0000-0000-00000000da05', :'o1', t.id('c1'), 'Gina Goh',   '00000000-0000-0000-0000-00000000ca04', '2026-01-01'),
  ('00000000-0000-0000-0000-00000000da06', :'o1', t.id('c1'), 'Gus Goh',    '00000000-0000-0000-0000-00000000ca04', '2026-03-01'),
  ('00000000-0000-0000-0000-00000000da07', :'o1', t.id('c1'), 'Eve Empty',  '00000000-0000-0000-0000-00000000ca05', '2026-01-01'),
  ('00000000-0000-0000-0000-00000000da09', :'o2', t.id('c2'), 'Ellie Else', '00000000-0000-0000-0000-00000000ca09', '2026-01-01');
\set s1 '00000000-0000-0000-0000-00000000da01'
\set s2 '00000000-0000-0000-0000-00000000da02'
\set s3 '00000000-0000-0000-0000-00000000da03'
\set s4 '00000000-0000-0000-0000-00000000da04'
\set s5 '00000000-0000-0000-0000-00000000da05'
\set s6 '00000000-0000-0000-0000-00000000da06'
\set s7 '00000000-0000-0000-0000-00000000da07'
-- Lim family: Sophie 2 done (10000) + 1 late-cancelled with NO charge yet (pending); Sam 1 done (5000)
select pg_temp.mk(t.id('c1'), :'o1', :'s1', 3, 'done');
select pg_temp.mk(t.id('c1'), :'o1', :'s1', 4, 'done');
select t.put('pending', pg_temp.mk(t.id('c1'), :'o1', :'s1', 6, 'cancelled', 'late_cancelled', null));
select pg_temp.mk(t.id('c1'), :'o1', :'s2', 5, 'done');
-- Tan family (Tara): 2 done (10000), a cancelled lesson charged S$25 (2500), a cancelled one NOT charged (0), a past lesson never marked, a free trial
select pg_temp.mk(t.id('c1'), :'o1', :'s3', 3, 'done');
select pg_temp.mk(t.id('c1'), :'o1', :'s3', 4, 'done');
select t.put('tan_charged', pg_temp.mk(t.id('c1'), :'o1', :'s3', 7, 'cancelled', 'late_cancelled', 25));
select pg_temp.mk(t.id('c1'), :'o1', :'s3', 8, 'cancelled', 'cancelled_early', 0);
select pg_temp.mk(t.id('c1'), :'o1', :'s3', 9, 'scheduled');
select t.put('trial', pg_temp.mk(t.id('c1'), :'o1', :'s3', 10, 'done', 'attended', null, 50, true));
-- Ong family (Oscar): 3 done
select pg_temp.mk(t.id('c1'), :'o1', :'s4', 3, 'done'); select pg_temp.mk(t.id('c1'), :'o1', :'s4', 4, 'done'); select pg_temp.mk(t.id('c1'), :'o1', :'s4', 5, 'done');
-- Goh family (two children, everything marked): Gina 2 done (10000), Gus 3 done (15000)
select pg_temp.mk(t.id('c1'), :'o1', :'s5', 3, 'done'); select pg_temp.mk(t.id('c1'), :'o1', :'s5', 4, 'done');
select pg_temp.mk(t.id('c1'), :'o1', :'s6', 3, 'done'); select pg_temp.mk(t.id('c1'), :'o1', :'s6', 4, 'done'); select pg_temp.mk(t.id('c1'), :'o1', :'s6', 5, 'done');
-- Eve Empty has no lessons; Ellie Else (centre 2) has one
select pg_temp.mk(t.id('c2'), :'o2', '00000000-0000-0000-0000-00000000da09', 3, 'done');
select t.ok((select count(*) = 19 from lessons where org_id in (t.id('c1'), t.id('c2'))), 'the made-up month has 19 lessons');

-- ===================================================================== 1. PREVIEW: who is ready, who is held back, and why
set role authenticated;
select t.put('dummy', t.id('c1'));
create temp table p1 as select pg_temp.pv(t.id('c1'), :'o1') as j;
grant select on p1 to authenticated;
select t.ok((select (j->>'built')::boolean and j->>'model' = 'postpaid_lessons' and j->>'grouping' = 'family' from p1), 'the model is built (postpaid) and invoices are per family');
select t.eq((select (j#>>'{totals,ready}')::int from p1), 3, 'three families are ready: Tan, Ong and Goh');
select t.eq((select (j#>>'{totals,held_back}')::int from p1), 1, 'one family is held back: Lim');
select t.ok((select (pg_temp.unit(j, 'held_back', 'Lim Family')#>>'{reasons,0,reason}') = 'charge pending: Sophie Lim' from p1), 'the reason reads "charge pending: Sophie Lim"');
select t.ok((select pg_temp.unit(j, 'ready', 'Lim Family') is null from p1), 'the held-back family is not in the ready list at all');
select t.ok((select pg_temp.unit(j, 'ready', 'Empty Family') is null and pg_temp.unit(j, 'held_back', 'Empty Family') is null from p1), 'a family with no lessons is not listed');
-- Ong: 3 lessons = 15000 + 9% = 1350 → 16350
select t.ok((select (u->>'subtotal_cents')::int = 15000 and (u->>'gst_cents')::int = 1350 and (u->>'total_cents')::int = 16350 and (u->>'lessons')::int = 3
               from p1, lateral (select pg_temp.unit(j, 'ready', 'Ong Family') u) x), 'Ong: 3 lessons S$150.00 + GST S$13.50 = S$163.50');
-- Tan: 2 done (10000) + the charged cancellation (2500); not-charged cancellation adds nothing; unmarked lesson and free trial only counted
select t.ok((select (u->>'subtotal_cents')::int = 12500 and (u->>'gst_cents')::int = 1125 and (u->>'total_cents')::int = 13625 and (u->>'lessons')::int = 3
               and (u->>'not_marked')::int = 1 and (u->>'free_trials')::int = 1 from p1, lateral (select pg_temp.unit(j, 'ready', 'Tan Family') u) x),
            'Tan: S$125.00 (2 lessons + S$25.00 charged cancellation); a charge of 0 adds nothing; 1 not marked and 1 free trial are only counted');
select t.ok((select jsonb_array_length(u->'lines') = 3 and (u#>>'{lines,2,description}') like 'Math (cancelled, charged)%' from p1, lateral (select pg_temp.unit(j, 'ready', 'Tan Family') u) x),
            'Tan: the charged cancellation is its own line, labelled');
select t.ok((select (j#>>'{totals,subtotal_cents}')::int = 15000 + 12500 + 25000 and (j#>>'{totals,total_cents}')::int = 16350 + 13625 + 27250 from p1), 'totals add up: all integer cents');
-- the preview wrote nothing
select t.eq((select count(*) from centre_invoices where org_id = t.id('c1')), 0, 'the preview creates no document');
select t.eq((select count(*) from org_counters where org_id = t.id('c1')), 0, 'and takes no number');
-- the shape of a preview: no tutor, no rate, no id of anything but what the screen needs
select t.ok((select not (j::text ~* '(tutor_id|"rate"|password|email)') from p1), 'the preview carries no tutor id, rate or email');

-- ===================================================================== 2. a bad month, and a model that is not built
select pg_temp.refused(:'o1', format($q$ select centre_invoice_run_preview(%L, date '1999-01-01') $q$, t.id('c1')), 'BAD_PERIOD', 'a month 27 years ago');
select pg_temp.refused(:'o1', format($q$ select centre_invoice_run_preview(%L, date '2099-01-01') $q$, t.id('c1')), 'BAD_PERIOD', 'a month far in the future');
select pg_temp.refused(:'o1', format($q$ select centre_invoice_run_preview(%L, null) $q$, t.id('c1')), 'BAD_PERIOD', 'no month at all');
select pg_temp.cfg(t.id('c1'), :'o1', '{billing,model}', '"prepaid_packages"');
select t.ok((select not (j->>'built')::boolean and j->>'message' like 'Prepaid packages are coming soon%' and j#>>'{totals,ready}' = '0' from (select pg_temp.pv(t.id('c1'), :'o1') j) x), 'prepaid packages: the preview says "coming soon" and lists nothing');
select pg_temp.refused(:'o1', format($q$ select centre_invoice_run_create_drafts(%L, (select m from td)) $q$, t.id('c1')), 'NOT_BUILT', 'prepaid packages: creating drafts is refused');
select pg_temp.cfg(t.id('c1'), :'o1', '{billing,model}', '"pay_per_lesson"');
select t.ok((select not (j->>'built')::boolean and j->>'message' like 'Pay per lesson is coming soon%' from (select pg_temp.pv(t.id('c1'), :'o1') j) x), 'pay per lesson: "coming soon"');
select pg_temp.cfg(t.id('c1'), :'o1', '{billing,model}', '"fixed_in_advance"');
select pg_temp.cfg(t.id('c1'), :'o1', '{billing,fixed_period}', '"term"');
select t.ok((select not (j->>'built')::boolean and j->>'message' like 'Fixed fees per term are coming soon%' from (select pg_temp.pv(t.id('c1'), :'o1') j) x), 'a fixed fee per TERM: "coming soon"');
select pg_temp.cfg(t.id('c1'), :'o1', '{billing,fixed_period}', '"month"');
select t.ok((select (j->>'built')::boolean from (select pg_temp.pv(t.id('c1'), :'o1') j) x), 'a fixed fee per MONTH is built');

-- ===================================================================== 3. fixed monthly fee: every non-cancelled lesson of the month; nothing is "pending"
select t.ok((select (j#>>'{totals,held_back}')::int = 0 from (select pg_temp.pv(t.id('c1'), :'o1') j) x), 'fixed monthly: the pending charge holds nothing back (no separate charge exists)');
select t.ok((select (u->>'subtotal_cents')::int = 15000 and (u->>'lessons')::int = 3 from (select pg_temp.pv(t.id('c1'), :'o1') j) x,
               lateral (select pg_temp.unit(j, 'ready', 'Lim Family') u) y), 'fixed monthly: Lim = Sophie 2 + Sam 1 (the cancelled lesson adds nothing) = S$150.00');
select t.ok((select (u->>'subtotal_cents')::int = 15000 + 5000 - 5000 and (u->>'not_marked')::int = 0 from (select pg_temp.pv(t.id('c1'), :'o1') j) x,
               lateral (select pg_temp.unit(j, 'ready', 'Tan Family') u) y), 'fixed monthly: Tan = 2 done + the scheduled one (S$150.00); a free trial and both cancelled lessons add nothing');
select pg_temp.cfg(t.id('c1'), :'o1', '{billing,model}', '"postpaid_lessons"');

-- ===================================================================== 4. trials: free unless the centre charges for them
select pg_temp.cfg(t.id('c1'), :'o1', '{billing,trials}', '{"charged":true}');
select t.ok((select (u->>'subtotal_cents')::int = 17500 and (u->>'free_trials')::int = 0 from (select pg_temp.pv(t.id('c1'), :'o1') j) x,
               lateral (select pg_temp.unit(j, 'ready', 'Tan Family') u) y), 'trials charged: the trial lesson is billed (S$125.00 + S$50.00)');
select pg_temp.cfg(t.id('c1'), :'o1', '{billing,trials}', '{"charged":false}');
select t.ok((select (u->>'subtotal_cents')::int = 12500 from (select pg_temp.pv(t.id('c1'), :'o1') j) x, lateral (select pg_temp.unit(j, 'ready', 'Tan Family') u) y), 'trials not charged: free again');

-- ===================================================================== 5. sibling discount (percent, fixed, none) — Goh family: Gina first (10000), Gus second (15000)
select t.ok((select (u->>'subtotal_cents')::int = 25000 and (u->>'lessons')::int = 5 and jsonb_array_length(u->'lines') = 5 from (select pg_temp.pv(t.id('c1'), :'o1') j) x,
               lateral (select pg_temp.unit(j, 'ready', 'Goh Family') u) y), 'no sibling discount: Goh = S$250.00 over 5 lines');
select pg_temp.cfg(t.id('c1'), :'o1', '{billing,sibling_discount}', '{"type":"percent","percent_bp":1000,"fixed_cents":500}');
select t.ok((select (u->>'subtotal_cents')::int = 25000 - 1500 and jsonb_array_length(u->'lines') = 6 and (u#>>'{lines,5,description}') = 'Sibling discount (10%)'
               and (u#>>'{lines,5,student_name}') = 'Gus Goh' and (u#>>'{lines,5,unit_cents}')::int = -1500
               from (select pg_temp.pv(t.id('c1'), :'o1') j) x, lateral (select pg_temp.unit(j, 'ready', 'Goh Family') u) y),
            'percent 10%: the 2nd child (Gus, registered later) gets S$15.00 off his S$150.00; Gina pays in full');
select t.ok((select (u->>'subtotal_cents')::int = 15000 and jsonb_array_length(u->'lines') = 3 from (select pg_temp.pv(t.id('c1'), :'o1') j) x, lateral (select pg_temp.unit(j, 'ready', 'Ong Family') u) y),
            'a family with one child gets no discount');
select pg_temp.cfg(t.id('c1'), :'o1', '{billing,sibling_discount}', '{"type":"fixed","percent_bp":1000,"fixed_cents":500}');
select t.ok((select (u->>'subtotal_cents')::int = 25000 - 3 * 500 and (u#>>'{lines,5,description}') = 'Sibling discount (S$5.00 off each lesson)'
               from (select pg_temp.pv(t.id('c1'), :'o1') j) x, lateral (select pg_temp.unit(j, 'ready', 'Goh Family') u) y), 'fixed S$5.00 per lesson: 3 lessons = S$15.00 off');
select pg_temp.cfg(t.id('c1'), :'o1', '{billing,sibling_discount}', '{"type":"fixed","percent_bp":1000,"fixed_cents":9000}');
select t.ok((select (u->>'subtotal_cents')::int = 10000 from (select pg_temp.pv(t.id('c1'), :'o1') j) x, lateral (select pg_temp.unit(j, 'ready', 'Goh Family') u) y),
            'a fixed discount bigger than the lessons is capped: the 2nd child pays 0, never a negative line');
select pg_temp.cfg(t.id('c1'), :'o1', '{billing,sibling_discount}', '{"type":"none","percent_bp":1000,"fixed_cents":500}');

-- ===================================================================== 6. one-off fees: once per student, on the first invoice that bills them
select pg_temp.cfg(t.id('c1'), :'o1', '{billing,one_off_fees}', '{"registration_cents":3000,"deposit_cents":0,"materials_cents":1500}');
select t.ok((select (u->>'subtotal_cents')::int = 15000 + 3000 + 1500 and (u#>>'{lines,3,description}') = 'Registration fee' and (u#>>'{lines,4,description}') = 'Materials fee'
               from (select pg_temp.pv(t.id('c1'), :'o1') j) x, lateral (select pg_temp.unit(j, 'ready', 'Ong Family') u) y), 'registration S$30.00 and materials S$15.00 are added after the lessons');
select t.ok((select (u->>'subtotal_cents')::int = 25000 + 2 * 4500 from (select pg_temp.pv(t.id('c1'), :'o1') j) x, lateral (select pg_temp.unit(j, 'ready', 'Goh Family') u) y), 'each child pays the fees once (two children, two sets)');
select pg_temp.cfg(t.id('c1'), :'o1', '{billing,one_off_fees}', '{"registration_cents":0,"deposit_cents":0,"materials_cents":0}');

-- ===================================================================== 7. invoices per STUDENT: the hold-back is that student's only
select pg_temp.cfg(t.id('c1'), :'o1', '{invoicing,grouping}', '"student"');
select t.ok((select (j#>>'{totals,ready}')::int = 5 and (j#>>'{totals,held_back}')::int = 1 from (select pg_temp.pv(t.id('c1'), :'o1') j) x),
            'per student: 5 invoices ready (Sam, Tara, Oscar, Gina, Gus) and only SOPHIE is held back');
select t.ok((select pg_temp.unit(j, 'held_back', 'Sophie Lim') is not null and pg_temp.unit(j, 'ready', 'Sam Lim') is not null from (select pg_temp.pv(t.id('c1'), :'o1') j) x),
            'per student: Sophie is held, her brother Sam is invoiced');
select pg_temp.cfg(t.id('c1'), :'o1', '{invoicing,grouping}', '"family"');

-- ===================================================================== 8. CREATE DRAFTS: idempotent, one lesson once, only the ready households
select t.as(:'o1');
create temp table r1 as select centre_invoice_run_create_drafts(t.id('c1'), (select m from td)) as j;
grant select on r1 to authenticated;
select t.ok((select (j->>'created')::int = 3 and (j->>'held_back')::int = 1 and (j->>'already_drafted')::int = 0 and (j->>'issued')::int = 0 and (j->>'review_before_sending')::boolean from r1),
            'first run: 3 drafts made, 1 household held back, nothing issued (the centre reviews before sending)');
reset role;
select t.eq((select count(*) from centre_invoices where org_id = t.id('c1') and status = 'draft'), 3, '3 draft documents exist');
select t.ok((select bool_and(number_seq is null and number_text is null and issue_date is null and due_date is null and kind = 'lesson'
                             and period_start = (select m from td) and period_end = ((select m from td) + interval '1 month - 1 day')::date) from centre_invoices where org_id = t.id('c1')),
            'drafts have no number and no dates; they carry the month');
select t.ok((select i.total_cents = 13625 and i.net_cents = 12500 and i.gst_cents = 1125 and i.gst_registered and i.gst_rate_bp = 900 and not i.gst_inclusive
               from centre_invoices i where i.org_id = t.id('c1') and i.household_id = '00000000-0000-0000-0000-00000000ca02'), 'Tan''s draft: S$125.00 + GST S$11.25 = S$136.25, GST rules frozen on the document');
select t.ok((select (select sum(line_cents) from centre_invoice_lines l where l.invoice_id = i.id) = i.net_cents from centre_invoices i where i.org_id = t.id('c1') and i.household_id = '00000000-0000-0000-0000-00000000ca02'),
            'the lines add up to the net amount');
select t.eq((select count(*) from centre_invoice_lines where org_id = t.id('c1') and lesson_id is not null), 3 + 3 + 5, '11 lesson lines: Tan 3, Ong 3, Goh 5');
select t.ok((select count(*) = count(distinct lesson_id) from centre_invoice_lines where org_id = t.id('c1') and lesson_id is not null), 'a lesson is on one line only');
select t.ok((select not exists (select 1 from centre_invoice_lines where lesson_id = t.id('pending')) and not exists (select 1 from centre_invoice_lines where lesson_id = t.id('trial'))),
            'the pending-charge lesson and the free trial are on no invoice');
select t.ok((select not exists (select 1 from centre_invoice_lines l join lessons x on x.id = l.lesson_id where x.student_id in ('00000000-0000-0000-0000-00000000da01', '00000000-0000-0000-0000-00000000da02'))), 'nothing of the Lim family was invoiced');
-- run it again, and again: nothing is added
set role authenticated; select t.as(:'o1');
create temp table r2 as select centre_invoice_run_create_drafts(t.id('c1'), (select m from td)) as j;
grant select on r2 to authenticated;
select t.ok((select (j->>'created')::int = 0 and (j->>'already_drafted')::int = 3 and (j->>'held_back')::int = 1 from r2), 'second run: 0 created, 3 households already have a draft, 1 still held back');
select centre_invoice_run_create_drafts(t.id('c1'), (select m from td));
reset role;
select t.eq((select count(*) from centre_invoices where org_id = t.id('c1')), 3, 'running three times left exactly 3 documents');
select t.eq((select count(*) from centre_invoice_lines where org_id = t.id('c1')), 11, 'and exactly 11 lines');
-- the backstop under it: the database refuses a second draft for the same household and month
select t.fails(format($q$ insert into centre_invoices(org_id, kind, household_id, period_start, period_end) values (%L, 'lesson', '00000000-0000-0000-0000-00000000ca02', %L, %L) $q$,
                      t.id('c1'), (select m from td), (select m + 27 from td)), 'a second draft for the same household and month is refused by the database itself');
-- the preview now shows them as drafts, not as ready
set role authenticated;
select t.ok((select (j#>>'{totals,ready}')::int = 0 and (j#>>'{totals,drafts}')::int = 3 and pg_temp.unit(j, 'drafts', 'Tan Family') is not null from (select pg_temp.pv(t.id('c1'), :'o1') j) x),
            'the preview now lists the 3 drafts and nothing as ready');

-- ===================================================================== 9. the pending charge is settled → ONLY the Lim family becomes ready
select t.as(:'o1');
select staff_set_charge(t.id('pending'), 0, null);
select t.ok((select (j#>>'{totals,ready}')::int = 1 and (j#>>'{totals,held_back}')::int = 0 and (pg_temp.unit(j, 'ready', 'Lim Family')->>'subtotal_cents')::int = 15000 from (select pg_temp.pv(t.id('c1'), :'o1') j) x),
            'charge set to 0 in Charges: Lim is ready at S$150.00 (the 0-charge lesson adds no line), the other three are untouched');
select t.ok((select jsonb_array_length(pg_temp.unit(j, 'ready', 'Lim Family')->'lines') = 3 from (select pg_temp.pv(t.id('c1'), :'o1') j) x), 'Lim has 3 lines: Sophie 2 + Sam 1');
select t.ok((select (j->>'created')::int = 1 and (j->>'already_drafted')::int = 3 from (select centre_invoice_run_create_drafts(t.id('c1'), (select m from td)) j) x), 'creating drafts again adds exactly one: Lim');
select t.ok((select (j#>>'{totals,drafts}')::int = 4 and (j#>>'{totals,ready}')::int = 0 from (select pg_temp.pv(t.id('c1'), :'o1') j) x), 'now four drafts');

-- ===================================================================== 10. APPROVE: number from the counter, dates from the settings, then frozen
select t.as(:'o1');
create temp table lst as select centre_invoice_list(t.id('c1'), (select m from td), 'draft') as j;
grant select on lst to authenticated;
select t.eq((select jsonb_array_length(j->'rows') from lst), 4, 'the list shows 4 drafts');
select t.ok((select j#>>'{rows,0,name}' = 'Goh Family' and j#>>'{rows,3,name}' = 'Tan Family' and j#>>'{rows,0,number}' is null from lst), 'the list is by family name and drafts have no number');
select t.put('tan_inv', (select (e->>'id')::uuid from lst, jsonb_array_elements(j->'rows') e where e->>'name' = 'Tan Family'));
select t.ok((select (centre_invoice_numbering(t.id('c1'))->>'next_text') = 'INV-1' and not (centre_invoice_numbering(t.id('c1'))->>'locked')::boolean), 'before anything is issued: next number INV-1, not locked');
create temp table ap as select centre_invoice_approve(t.id('tan_inv')) as j;
grant select on ap to authenticated;
select t.ok((select j->>'number' = 'INV-1' and j->>'status' = 'issued' and (j->>'issue_date')::date = (select today from td) and (j->>'due_date')::date = (select today + 7 from td) and (j->>'total_cents')::int = 13625 from ap),
            'approving the first draft: INV-1, issued today, due in 7 days (the centre''s setting), S$136.25');
select t.ok((centre_invoice_numbering(t.id('c1'))->>'next_text') = 'INV-2' and (centre_invoice_numbering(t.id('c1'))->>'locked')::boolean, 'the counter moved to INV-2 and is locked');
select pg_temp.refused(:'o1', format($q$ select centre_invoice_approve(%L) $q$, t.id('tan_inv')), 'NOT_DRAFT', 'approving the same invoice twice');
reset role;
select t.fails(format($q$ update centre_invoices set total_cents = 1, net_cents = 1, gst_cents = 0 where id = %L $q$, t.id('tan_inv')), 'an issued invoice''s total can''t be edited');
select t.fails(format($q$ update centre_invoices set due_date = current_date + 90 where id = %L $q$, t.id('tan_inv')), 'an issued invoice''s due date can''t be edited');
select t.fails(format($q$ update centre_invoices set status = 'draft', number_seq = null, number_text = null where id = %L $q$, t.id('tan_inv')), 'an issued invoice can''t go back to draft');
select t.fails(format($q$ update centre_invoices set household_id = '00000000-0000-0000-0000-00000000ca03' where id = %L $q$, t.id('tan_inv')), 'an issued invoice can''t move to another household');
select t.fails(format($q$ update centre_invoice_lines set unit_cents = 1 where invoice_id = %L $q$, t.id('tan_inv')), 'the lines of an issued invoice can''t be edited');
select t.fails(format($q$ delete from centre_invoice_lines where invoice_id = %L $q$, t.id('tan_inv')), 'the lines of an issued invoice can''t be deleted');
select t.fails(format($q$ delete from centre_invoices where id = %L $q$, t.id('tan_inv')), 'an issued invoice can''t be deleted');
select t.ok((select number_text = 'INV-1' and total_cents = 13625 from centre_invoices where id = t.id('tan_inv')), 'and it is exactly as issued');
set role authenticated; select t.as(:'o1');
select pg_temp.refused(:'o1', format($q$ select centre_invoice_discard_draft(%L, 'oops') $q$, t.id('tan_inv')), 'NOT_DRAFT', 'an issued invoice can''t be discarded');
-- the lessons on an issued invoice never come back
select t.ok((select (j#>>'{totals,ready}')::int = 0 and pg_temp.unit(j, 'ready', 'Tan Family') is null and pg_temp.unit(j, 'drafts', 'Tan Family') is null from (select pg_temp.pv(t.id('c1'), :'o1') j) x),
            'the preview no longer offers Tan: their lessons are on an issued invoice');
create temp table apa as select centre_invoice_approve_all(t.id('c1'), (select m from td)) as j;
grant select on apa to authenticated;
select t.ok((select (j->>'issued')::int = 3 and j->>'first_number' = 'INV-2' and j->>'last_number' = 'INV-4' from apa), 'approve all: the other 3 get INV-2..INV-4 with no gap');
select pg_temp.refused(:'o1', format($q$ select centre_invoice_approve_all(%L, (select m from td)) $q$, t.id('c1')), 'NOTHING_TO_APPROVE', 'approve all with no drafts left');
reset role;
select t.ok((select count(distinct number_seq) = 4 and min(number_seq) = 1 and max(number_seq) = 4 from centre_invoices where org_id = t.id('c1') and status = 'issued'), 'the four numbers are 1..4, no gap, no repeat');
select t.ok((select bool_and(due_date = issue_date + 7 and issue_date = (select today from td)) from centre_invoices where org_id = t.id('c1')), 'every invoice is due 7 days after its issue date');
select t.ok((select number_text = 'INV-2' from centre_invoices where org_id = t.id('c1') and household_id = '00000000-0000-0000-0000-00000000ca04'), 'numbers follow the family-name order (Goh = INV-2)');
-- everything is already invoiced: a fresh run finds nothing
set role authenticated; select t.as(:'o1');
select t.ok((select (j->>'created')::int = 0 and (j->>'held_back')::int = 0 and (j->>'already_drafted')::int = 0 from (select centre_invoice_run_create_drafts(t.id('c1'), (select m from td)) j) x), 'a run after everything is issued creates nothing');
select t.ok((select count(*) = 4 from centre_invoices where org_id = t.id('c1')), 'still exactly 4 documents');
-- the audit trail names who did what
reset role;
select t.ok((select count(*) >= 3 from audit_log where org_id = t.id('c1') and action in ('centre_invoice_run_create', 'centre_invoice_approve', 'centre_invoice_approve_all')), 'the run, the approval and approve-all are in the audit log');
select t.ok((select actor = :'o1' and (after->>'number') = 'INV-1' from audit_log where org_id = t.id('c1') and action = 'centre_invoice_approve' order by id limit 1), 'the approval audit row says who and which number');

-- ===================================================================== 11. discard a draft: its lessons can be invoiced again
set role authenticated; select t.as(:'o1');
select pg_temp.mk(t.id('c1'), :'o1', :'s7', 3, 'done');          -- Eve Empty gets a lesson after the run
select t.ok((select (j->>'created')::int = 1 from (select centre_invoice_run_create_drafts(t.id('c1'), (select m from td)) j) x), 'a late lesson: the run makes a draft for Eve');
select t.put('eve', (select id from centre_invoices where org_id = t.id('c1') and status = 'draft'));
select pg_temp.refused(:'o1', format($q$ select centre_invoice_discard_draft(%L, '   ') $q$, t.id('eve')), 'REASON_REQUIRED', 'discarding needs a reason');
select centre_invoice_discard_draft(t.id('eve'), 'wrong month');
reset role;
select t.ok((select status = 'void' and number_seq is null and void_reason = 'wrong month' from centre_invoices where id = t.id('eve')), 'the draft is voided with its reason and never had a number');
select t.eq((select next_number from org_counters where org_id = t.id('c1') and series = 'invoice'), 5, 'no number was burnt: the next is still 5');
set role authenticated; select t.as(:'o1');
select t.ok((select (u->>'subtotal_cents')::int = 5000 from (select pg_temp.pv(t.id('c1'), :'o1') j) x, lateral (select pg_temp.unit(j, 'ready', 'Empty Family') u) y), 'after discarding, Eve''s lesson is ready to invoice again');
select centre_invoice_run_create_drafts(t.id('c1'), (select m from td));
select t.eq((select count(*) from centre_invoices where org_id = t.id('c1') and status = 'draft'), 1, 'and a new draft exists');
select t.ok((select jsonb_array_length(centre_invoice_get((select id from centre_invoices where org_id = t.id('c1') and status = 'draft'))->'lines') = 1), 'a draft can be opened: 1 line');

-- ===================================================================== 12. review_before_sending = OFF: drafts are issued straight away
select pg_temp.cfg(t.id('c1'), :'o1', '{invoicing,review_before_sending}', 'false');
select pg_temp.cfg(t.id('c1'), :'o1', '{invoicing,due_days}', '14');
reset role;
-- a month ahead of the existing ones (the current month): one lesson for Ong, the first day of the month
insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, subject)
  values (gen_random_uuid(), :'o1', t.id('c1'), :'s4', date_trunc('month', (select today from td))::date, '16:00', '17:00', 50, 50, 'done', 'Math');
set role authenticated; select t.as(:'o1');
-- (the Eve draft of last month has no bearing on this month)
create temp table r3 as select centre_invoice_run_create_drafts(t.id('c1'), (select today from td)) as j;
grant select on r3 to authenticated;
select t.ok((select (j->>'created')::int = 1 and (j->>'issued')::int = 1 and not (j->>'review_before_sending')::boolean from r3), 'review OFF: the run issues the invoice straight away');
reset role;
select t.ok((select status = 'issued' and number_text = 'INV-5' and due_date = issue_date + 14 and total_cents = 5450 from centre_invoices where org_id = t.id('c1') and period_start = date_trunc('month', (select today from td))::date),
            'review OFF: INV-5, due in 14 days (the new setting), S$54.50 with GST');
select t.eq((select count(*) from centre_invoices where org_id = t.id('c1') and status = 'draft'), 1, 'the other month''s draft (Eve) is untouched');

-- ===================================================================== 13. GST: every shared vector (tests/gst-vectors.csv, the file money.js is tested with) through the real invoice run
create temp table gst_vec(name text, subtotal_cents bigint, rate_bp int, inclusive boolean, registered boolean, net_cents bigint, gst_cents bigint, total_cents bigint);
\copy gst_vec from 'tests/gst-vectors.csv' with (format csv, header true)
set role authenticated; select t.as(:'o3');
select t.put('c3', org_create_centre('GST Vector Centre', pg_temp.base_settings()));
reset role;
insert into households(id, org_id, name) values ('00000000-0000-0000-0000-00000000ca31', t.id('c3'), 'Vector Family');
insert into students(id, tutor_id, org_id, name, household_id) values ('00000000-0000-0000-0000-00000000da31', :'o3', t.id('c3'), 'Vera Vector', '00000000-0000-0000-0000-00000000ca31');
create function pg_temp.vec(p_gst_bp int, p_inc boolean, p_reg boolean, p_cents bigint) returns jsonb language plpgsql as $$
declare cur jsonb; lid uuid; j jsonb;
begin
  perform t.as('00000000-0000-0000-0000-00000000ba09');
  cur := org_settings_on(t.id('c3'), current_date);
  cur := jsonb_set(cur, '{profile}', cur->'profile' || jsonb_build_object('gst_registered', p_reg, 'gst_rate_bp', p_gst_bp, 'gst_inclusive', p_inc, 'gst_number', 'M2-0000000-0'));
  perform org_save_settings(t.id('c3'), cur, current_date);
  return null;
end $$;
grant execute on function pg_temp.vec(int, boolean, boolean, bigint) to public;
do $$
declare v record; n int := 0; lid uuid; pvj jsonb; u jsonb; bad text := '';
begin
  for v in select * from gst_vec where subtotal_cents > 0 order by name loop
    perform set_config('request.jwt.claims', '', false);
    delete from lessons where org_id = t.id('c3');
    lid := gen_random_uuid();
    insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, subject)
      values (lid, '00000000-0000-0000-0000-00000000ba09', t.id('c3'), '00000000-0000-0000-0000-00000000da31', (select m from td) + 2, '16:00', '17:00', 50, v.subtotal_cents / 100.0, 'done', 'Math');
    set local role authenticated;
    perform pg_temp.vec(v.rate_bp, v.inclusive, v.registered, v.subtotal_cents);
    pvj := centre_invoice_run_preview(t.id('c3'), (select m from td));
    reset role;
    u := (pvj->'ready'->0);
    if u is null or (u->>'subtotal_cents')::bigint <> v.subtotal_cents or (u->>'net_cents')::bigint <> v.net_cents
       or (u->>'gst_cents')::bigint <> v.gst_cents or (u->>'total_cents')::bigint <> v.total_cents then
      bad := bad || v.name || ' (got ' || coalesce(u::text, 'null') || '); ';
    end if;
    n := n + 1;
  end loop;
  if bad <> '' then raise exception 'FAIL: GST vectors differ from money.js: %', bad; end if;
  raise notice 'PASS the invoice run reproduces all % shared GST vectors (net, GST and total) through real lessons', n;
end $$;
select set_config('request.jwt.claims', '', false); reset role;
-- and a real draft keeps the rules it was made with, whatever the settings say later
delete from lessons where org_id = t.id('c3');
insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, subject)
  values (gen_random_uuid(), :'o3', t.id('c3'), '00000000-0000-0000-0000-00000000da31', (select m from td) + 2, '16:00', '17:00', 50, 111.11, 'done', 'Math');
set role authenticated;
select pg_temp.vec(900, false, true, 0);
select t.as(:'o3'); select centre_invoice_run_create_drafts(t.id('c3'), (select m from td));
select pg_temp.vec(0, false, false, 0);
select t.as(:'o3'); select centre_invoice_approve((select id from centre_invoices where org_id = t.id('c3') and status = 'draft'));
reset role;
select t.ok((select gst_registered and gst_rate_bp = 900 and gst_cents = 1000 and total_cents = 12111 and net_cents = 11111 from centre_invoices where org_id = t.id('c3')), 'GST is frozen at the draft: S$111.11 + 9% = S$10.00 GST even though the centre un-registered before approving');

-- ===================================================================== 14. numbering: an opening number set by the owner, once
set role authenticated; select t.as(:'o4');
select t.put('c4', org_create_centre('Numbering Centre', jsonb_set(pg_temp.base_settings(), '{profile,gst_registered}', 'false')));
reset role;
insert into households(id, org_id, name) values ('00000000-0000-0000-0000-00000000ca41', t.id('c4'), 'Opening Family');
insert into students(id, tutor_id, org_id, name, household_id) values ('00000000-0000-0000-0000-00000000da41', :'o4', t.id('c4'), 'Opie Opening', '00000000-0000-0000-0000-00000000ca41');
select pg_temp.mk(t.id('c4'), :'o4', '00000000-0000-0000-0000-00000000da41', 3, 'done');
set role authenticated; select t.as(:'o4');
select t.ok((select (j->>'can_set')::boolean and (j->>'next_text') = 'INV-1' from (select centre_invoice_numbering(t.id('c4')) j) x), 'the owner may still set the opening number (next INV-1)');
select centre_set_opening_number(t.id('c4'), 'invoice', 1000);
select centre_invoice_run_create_drafts(t.id('c4'), (select m from td));
select t.ok((select j->>'number' = 'INV-1000' and (j->>'total_cents')::int = 5000 from (select centre_invoice_approve((select id from centre_invoices where org_id = t.id('c4') and status = 'draft')) j) x), 'with opening number 1000 the first approved invoice is INV-1000 (no GST: this centre is not registered)');
select t.ok((select (j->>'locked')::boolean and j->>'next_text' = 'INV-1001' from (select centre_invoice_numbering(t.id('c4')) j) x), 'then the number is locked and the next is INV-1001');
select pg_temp.refused(:'o4', format($q$ select centre_set_opening_number(%L, 'invoice', 5) $q$, t.id('c4')), 'NOT_ALLOWED', 'the opening number can''t be changed after the first issue');
select t.as(:'bill');
select pg_temp.refused(:'bill', format($q$ select centre_set_opening_number(%L, 'invoice', 5) $q$, t.id('c1')), 'NOT_FOUND', 'staff can''t set the opening number (owner only)');
select t.ok((select not (centre_invoice_numbering(t.id('c1'))->>'can_set')::boolean from (select 1) y), 'staff are told they can''t set it');

-- ===================================================================== 15. WHO MAY: staff with issue_invoices yes; everyone else, plainly no
reset role; select set_config('request.jwt.claims', '', false);
select pg_temp.mk(t.id('c1'), :'o1', :'s7', 12, 'done', null, null, 50, false, (select m + interval '1 month' from td)::date);     -- a lesson in the current month, for the staff run below
set role authenticated;
select pg_temp.cfg(t.id('c1'), :'o1', '{invoicing,review_before_sending}', 'true');
select t.ok((select jsonb_typeof(pg_temp.pv(t.id('c1'), :'bill')->'ready') = 'array'), 'staff with issue_invoices can preview');
select t.as(:'bill');
select t.ok((select (j->>'created')::int = 1 and (j->>'issued')::int = 0 from (select centre_invoice_run_create_drafts(t.id('c1'), (select today from td)) j) x), 'staff with issue_invoices can create drafts');
select t.ok((select (j->>'issued')::int >= 1 from (select centre_invoice_approve_all(t.id('c1'), (select today from td)) j) x), 'staff with issue_invoices can approve');
select t.eq((select count(*) from centre_invoices where org_id = t.id('c1') and status = 'issued' and issued_by = :'bill'), 1, 'and the invoice records who issued it');
select pg_temp.refused(:'paym', format($q$ select centre_invoice_run_preview(%L, (select m from td)) $q$, t.id('c1')), 'NOT_ALLOWED', 'staff with only record_payments / view_revenue / manage_* can''t preview');
select pg_temp.refused(:'paym', format($q$ select centre_invoice_run_create_drafts(%L, (select m from td)) $q$, t.id('c1')), 'NOT_ALLOWED', '... can''t create drafts');
select pg_temp.refused(:'paym', format($q$ select centre_invoice_approve_all(%L, (select m from td)) $q$, t.id('c1')), 'NOT_ALLOWED', '... can''t approve all');
select pg_temp.refused(:'paym', format($q$ select centre_invoice_list(%L) $q$, t.id('c1')), 'NOT_ALLOWED', '... can''t list');
select pg_temp.refused(:'paym', format($q$ select centre_invoice_numbering(%L) $q$, t.id('c1')), 'NOT_ALLOWED', '... can''t read the numbering');
reset role; select t.put('one_inv', (select id from centre_invoices where org_id = t.id('c1') and number_seq = 1)); select t.put('a_draft', (select id from centre_invoices where org_id = t.id('c1') and status = 'draft' limit 1));
set role authenticated;
select pg_temp.refused(:'paym', format($q$ select centre_invoice_get(%L) $q$, t.id('one_inv')), 'NOT_ALLOWED', '... can''t open an invoice');
select pg_temp.refused(:'paym', format($q$ select centre_invoice_approve(%L) $q$, coalesce(t.id('a_draft'), t.id('one_inv'))), 'NOT_ALLOWED', '... can''t approve one');
select pg_temp.refused(:'paym', format($q$ select centre_invoice_discard_draft(%L, 'x') $q$, coalesce(t.id('a_draft'), t.id('one_inv'))), 'NOT_ALLOWED', '... can''t discard one');
-- people with no standing at this centre all get the same plain NOT_FOUND
select pg_temp.refused(:'tut', format($q$ select centre_invoice_run_preview(%L, (select m from td)) $q$, t.id('c1')), 'NOT_FOUND', 'a tutor of the centre');
select pg_temp.refused(:'tut', format($q$ select centre_invoice_run_create_drafts(%L, (select m from td)) $q$, t.id('c1')), 'NOT_FOUND', 'a tutor can''t create drafts');
select pg_temp.refused(:'tut', format($q$ select centre_invoice_approve(%L) $q$, t.id('one_inv')), 'NOT_FOUND', 'a tutor can''t approve');
select pg_temp.refused(:'tut', format($q$ select centre_invoice_get(%L) $q$, t.id('one_inv')), 'NOT_FOUND', 'a tutor can''t open an invoice');
select pg_temp.refused(:'par', format($q$ select centre_invoice_run_preview(%L, (select m from td)) $q$, t.id('c1')), 'NOT_FOUND', 'a parent');
select pg_temp.refused(:'par', format($q$ select centre_invoice_list(%L) $q$, t.id('c1')), 'NOT_FOUND', 'a parent can''t list invoices');
select pg_temp.refused(:'off', format($q$ select centre_invoice_run_preview(%L, (select m from td)) $q$, t.id('c1')), 'NOT_FOUND', 'switched-off staff');
select pg_temp.refused(:'out', format($q$ select centre_invoice_run_preview(%L, (select m from td)) $q$, t.id('c1')), 'NOT_FOUND', 'a stranger');
select pg_temp.refused(:'o2', format($q$ select centre_invoice_run_preview(%L, (select m from td)) $q$, t.id('c1')), 'NOT_FOUND', 'the owner of ANOTHER centre previewing this one');
select pg_temp.refused(:'o2', format($q$ select centre_invoice_run_create_drafts(%L, (select m from td)) $q$, t.id('c1')), 'NOT_FOUND', 'the owner of another centre creating drafts here');
select pg_temp.refused(:'o2', format($q$ select centre_invoice_approve(%L) $q$, t.id('one_inv')), 'NOT_FOUND', 'the owner of another centre approving this centre''s invoice');
select pg_temp.refused(:'o2', format($q$ select centre_invoice_get(%L) $q$, t.id('one_inv')), 'NOT_FOUND', 'the owner of another centre opening this centre''s invoice');
select pg_temp.refused(:'o2', format($q$ select centre_invoice_discard_draft(%L, 'x') $q$, t.id('one_inv')), 'NOT_FOUND', 'the owner of another centre discarding here');
select pg_temp.refused(:'solo', format($q$ select centre_invoice_run_preview(%L, (select m from td)) $q$, t.id('solo_org')), 'NOT_FOUND', 'a solo tutor previewing their own organisation');
select pg_temp.refused(:'solo', format($q$ select centre_invoice_run_create_drafts(%L, (select m from td)) $q$, t.id('solo_org')), 'NOT_FOUND', 'a solo tutor creating drafts');
select pg_temp.refused(:'solo', format($q$ select centre_invoice_numbering(%L) $q$, t.id('solo_org')), 'NOT_FOUND', 'a solo tutor reading numbering');
select pg_temp.refused(:'o1', format($q$ select centre_invoice_run_preview(%L, (select m from td)) $q$, '00000000-0000-0000-0000-0000000000ff'), 'NOT_FOUND', 'an organisation that does not exist');
reset role; select set_config('request.jwt.claims', '', false);

-- ===================================================================== 16. nobody else READS the documents either (row-level security), and anonymous callers can't call anything
set role authenticated;
select t.as(:'tut');  select t.eq((select count(*) from centre_invoices), 0, 'a tutor reads no invoice');
select t.eq((select count(*) from centre_invoice_lines), 0, 'a tutor reads no invoice line');
select t.as(:'par');  select t.eq((select count(*) from centre_invoices), 0, 'a parent reads no invoice');
select t.as(:'paym'); select t.eq((select count(*) from centre_invoices), 0, 'staff without issue_invoices read no invoice');
select t.as(:'off');  select t.eq((select count(*) from centre_invoices), 0, 'switched-off staff read no invoice');
select t.as(:'solo'); select t.eq((select count(*) from centre_invoices), 0, 'a solo tutor reads no centre invoice');
select t.as(:'o2');   select t.eq((select count(*) from centre_invoices where org_id = t.id('c1')), 0, 'another centre''s owner reads none of this centre''s invoices');
select t.as(:'bill'); select t.ok((select count(*) > 0 from centre_invoices where org_id = t.id('c1')), 'staff with issue_invoices read their own centre''s invoices');
select t.fails(format($q$ insert into centre_invoices(org_id, kind, household_id) values (%L, 'lesson', '00000000-0000-0000-0000-00000000ca01') $q$, t.id('c1')), 'and still can''t write one directly (no write policy)');
reset role; select set_config('request.jwt.claims', '', false);
set role anon;
select t.fails(format($q$ select centre_invoice_run_preview(%L, current_date) $q$, t.id('c1')), 'an anonymous caller can''t preview');
select t.fails(format($q$ select centre_invoice_approve(%L) $q$, t.id('one_inv')), 'an anonymous caller can''t approve');
select t.fails(format($q$ select centre_invoice_run_rows(%L, current_date, current_date) $q$, t.id('c1')), 'the internal calculation is not callable by anonymous callers');
reset role;
set role authenticated; select t.as(:'o1');
select t.fails(format($q$ select centre_invoice_run_rows(%L, current_date, current_date) $q$, t.id('c1')), 'nor by a signed-in browser (internal only)');
select t.fails(format($q$ select centre_invoice_issue_draft(%L, current_date) $q$, t.id('a_draft')), 'nor can a browser issue a draft without the gate');
reset role;
