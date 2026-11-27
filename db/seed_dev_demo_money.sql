-- =====================================================================================================
-- T47: RICH MONEY DEMO DATA FOR THE DEV DATABASE ONLY (project tuzxsqkfzrjssnpcoale). NEVER run this on the live project.
-- Run db/seed_dev_demo.sql first (it makes the demo centre, its tutors and the staff logins). This file adds everything a tester needs
-- to try the money screens without first having to invent data. Everything is invented dummy data (@example.test, made-up numbers).
-- Undo: db/seed_dev_demo_money_down.sql. Guide: docs/orchestrator/dev-seed-money.md.
--
-- Safe to run twice: the second run sees the marker student (…0e0101) and does nothing but print the post-check line.
-- It REFUSES to run (nothing is written) unless:
--   * exactly one centre has centre.owner@, tutor.one@ and tutor.two@example.test as its owner / tutors (found by MEMBERS, never by name), and
--   * every login that belongs to that centre is an @example.test address, and the centre has no Stripe subscription.
-- That is the "this is the DEV demo centre" proof: the live project has no such centre.
--
-- HOW THE DATA IS MADE: through the app's own functions wherever they accept it (centre_invoice_run_create_drafts, centre_deposit_waive,
-- centre_record_payment, centre_deposit_refund_request, centre_credit_refund_request, centre_refund_approve / _pay / _cancel,
-- centre_late_fee_list, staff_mark_attendance, staff_set_student_end, org_save_settings), with the session signed in as the right demo
-- login (request.jwt.claims), so numbering, GST, audit rows and every guard behave exactly as in the app. THREE places differ, each on purpose:
--   1. ISSUING A PAST INVOICE. centre_invoice_approve issues with today's date and there is no app function to "issue as of last month".
--      A drafted invoice is issued with the same single UPDATE the app uses (status draft -> issued), but with issue_date / due_date set
--      in that statement. The invoice guard (centre_invoice_guard) accepts a given issue_date, takes the gap-free number, checks the totals
--      against the lines and freezes the row. Only the demo families' own drafts are touched.
--   2. BACK-DATED SETTINGS. A launched centre cannot back-date a settings change, but the past invoices and the late-fee rule read the
--      settings that were in force on THEIR dates. The centre is put back into "setup" for the moment of saving (the one state in which
--      org_save_settings allows back-dating), the same settings are saved once per distinct effective date, and the status is put back.
--   3. STUDENTS AND LESSONS are inserted directly (as db/seed_dev_demo.sql does) with deterministic ids; lessons are then MARKED through
--      staff_mark_attendance. Households come from the shared phone number, exactly as the app groups siblings.
-- Dates are relative to today in the centre's time zone, so the seed works on any day of the month.
-- =====================================================================================================
do $seed$
declare
  owner_id   constant uuid := '00000000-0000-0000-0000-00000000d101';
  billing_id constant uuid := '00000000-0000-0000-0000-00000000d108';    -- staff: issue_invoices (asks for deposit refunds)
  cashier_id constant uuid := '00000000-0000-0000-0000-00000000d109';    -- staff: record_payments (asks for family-credit refunds)
  marker_id  constant uuid := '00000000-0000-0000-0000-0000000e0101';
  class_sess constant uuid := '00000000-0000-0000-0000-0000000e0f01';
  c uuid; n int; found_list text; tz text; today date; cm date; pm date; ppm date; last_pm date; setup_before text; s jsonb; v int;
  m1 uuid; m2 uuid; r record; l record; res jsonb; ids uuid[]; amt bigint; hh uuid; i_l record; i_d record; mth text; rid uuid; first_ef date;
begin
  -- ---------------------------------------------------------------- 1. pre-check: refuse unless this is the DEV demo centre
  select count(*), string_agg(o.trading_name || ' (' || o.id || ')', '; ' order by o.created_at), (array_agg(o.id order by o.created_at))[1], (array_agg(o.timezone))[1]
    into n, found_list, c, tz
    from organisations o
    where o.kind = 'centre'
      and exists (select 1 from memberships m join auth.users u on u.id = m.user_id where m.org_id = o.id and m.role = 'owner' and m.status = 'active' and u.email = 'centre.owner@example.test')
      and exists (select 1 from memberships m join auth.users u on u.id = m.user_id where m.org_id = o.id and m.role = 'tutor' and m.status = 'active' and u.email = 'tutor.one@example.test')
      and exists (select 1 from memberships m join auth.users u on u.id = m.user_id where m.org_id = o.id and m.role = 'tutor' and m.status = 'active' and u.email = 'tutor.two@example.test');
  if n = 0 then raise exception 'REFUSED: no centre has centre.owner@ as owner and tutor.one@ + tutor.two@ as tutors (run db/seed_dev_demo.sql first). This is not the DEV demo database.'; end if;
  if n > 1 then raise exception using message = 'REFUSED: ' || n || ' centres match the demo centre (' || found_list || '). Not guessing: ask the project owner.'; end if;
  if exists (select 1 from memberships m join auth.users u on u.id = m.user_id where m.org_id = c and u.email not like '%@example.test') then
    raise exception 'REFUSED: the centre has a member whose login is not an @example.test address. This does not look like the DEV demo data.'; end if;
  if exists (select 1 from org_subscriptions x where x.org_id = c and x.stripe_subscription_id is not null) then
    raise exception 'REFUSED: the centre has a Stripe subscription. This does not look like the DEV demo data.'; end if;
  if exists (select 1 from students where id = marker_id) then
    raise notice 'The money demo data is already there (marker student found): nothing changed.'; return; end if;
  raise notice 'Demo centre used for the money seed: % (%)', (select trading_name from organisations where id = c), c;

  today := (now() at time zone tz)::date;
  cm := date_trunc('month', today)::date; pm := (cm - interval '1 month')::date; ppm := (cm - interval '2 months')::date; last_pm := cm - 1;
  select id into m1 from memberships where org_id = c and user_id = '00000000-0000-0000-0000-00000000d102';
  select id into m2 from memberships where org_id = c and user_id = '00000000-0000-0000-0000-00000000d103';

  -- ---------------------------------------------------------------- 2. two more staff logins (four-eyes needs one staff who issues invoices and one who records payments)
  for r in select * from (values (billing_id, 'centre.billing@example.test', 'Demo Billing Staff'), (cashier_id, 'centre.cashier@example.test', 'Demo Cashier')) v(id, email, name) loop
    if not exists (select 1 from auth.users where email = r.email) then
      insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, confirmation_token, recovery_token, email_change_token_new,
          email_change, email_change_token_current, reauthentication_token, phone_change, phone_change_token, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
      values ('00000000-0000-0000-0000-000000000000', r.id, 'authenticated', 'authenticated', r.email, extensions.crypt('Demo-Pass-2026', extensions.gen_salt('bf')), now(),
          '', '', '', '', '', '', '', '', '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name', r.name, 'email_verified', true), now(), now());
      insert into auth.identities(id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
      values (gen_random_uuid(), r.id, jsonb_build_object('sub', r.id::text, 'email', r.email, 'email_verified', true, 'phone_verified', false), 'email', r.id::text, now(), now(), now());
    end if;
  end loop;
  insert into memberships(org_id, user_id, display_name, role, permissions, status)
    select c, u.id, v.name, 'staff', v.perms, 'active'
    from (values ('centre.billing@example.test', 'Demo Billing Staff', array['issue_invoices','view_revenue']),
                 ('centre.cashier@example.test', 'Demo Cashier', array['record_payments','view_revenue'])) v(email, name, perms)
    join auth.users u on u.email = v.email
    where not exists (select 1 from memberships m where m.org_id = c and m.user_id = u.id);

  -- ---------------------------------------------------------------- 3. settings (saved with org_save_settings, as the owner)
  perform set_config('request.jwt.claims', json_build_object('sub', owner_id, 'role', 'authenticated')::text, false);
  s := org_settings_on(c, today);
  if s is null then raise exception 'The centre has no settings in force today.'; end if;
  s := jsonb_set(s, '{billing,deposit}', coalesce(s#>'{billing,deposit}', '{}'::jsonb) || jsonb_build_object('mode', 'fixed', 'due', 'with_first_invoice', 'taxable', false,
         'waived_by', 'owner', 'release', 'refund_less_unpaid', 'forfeit_notice_days', 0, 'refund_approved_by', 'owner'), true);        -- "owner approves"; four_eyes is available (see the guide)
  s := jsonb_set(s, '{billing,one_off_fees}', coalesce(s#>'{billing,one_off_fees}', '{}'::jsonb) || jsonb_build_object('deposit_cents', 6000), true);   -- S$60
  s := jsonb_set(s, '{billing,late_fee}', coalesce(s#>'{billing,late_fee}', '{}'::jsonb) || jsonb_build_object('enabled', true, 'repeat', 'monthly', 'type', 'fixed',
         'amount_cents', 1000, 'after_days', 0, 'cap_cents', 0, 'show_as', 'own_invoice', 'waived_by', 'owner'), true);                  -- S$10 a month, grace 0
  s := jsonb_set(s, '{invoicing,due_days}', '7'::jsonb, true);
  s := jsonb_set(s, '{lessons}', (s->'lessons') || jsonb_build_object('timetable_editing', 'tutors_direct', 'min_notice_hours', 24, 'max_changes_per_month', 0,
         'tutors_edit', coalesce(s#>'{lessons,tutors_edit}', '{}'::jsonb) || jsonb_build_object('postpone', true, 'cancel', true)), true);  -- tutors move + cancel own lessons
  if to_regclass('public.makeup_credits') is not null then      -- bundle 6 (make-up credits) is on this database
    s := jsonb_set(s, '{billing,credits}', coalesce(s#>'{billing,credits}', '{}'::jsonb) || jsonb_build_object('rule', 'one_per_missed', 'earn_absences', 'notice_only',
           'earn_tutor_cancel', 'staff_decide', 'earn_holiday', false, 'grant_by', 'manage_timetable', 'book_by', 'manage_timetable', 'makeup_price', 'free'), true);
  end if;
  s := jsonb_set(s, '{data}', coalesce(s->'data', '{}'::jsonb) || jsonb_build_object('seed_money', 't47'), true);          -- marker: the undo removes exactly these versions
  -- The same settings are saved once for every date a settings version already starts on (and once far back), so that on every past day the
  -- demo needs, the version in force is this one (a later version with the same start date wins). Needs the centre in "setup" for the moment.
  select status into setup_before from organisations where id = c;
  update organisations set status = 'setup' where id = c;
  for r in select ef from (select distinct effective_from as ef from org_settings where org_id = c and effective_from <= current_date
                           union select (date_trunc('month', current_date) - interval '6 months')::date) x order by ef loop
    v := org_save_settings(c, s, r.ef);
  end loop;
  update organisations set status = setup_before where id = c;

  -- ---------------------------------------------------------------- 4. the students (one table of plan, used by every step below)
  drop table if exists pg_temp.td_stu;
  create temp table td_stu(seq int primary key, k text unique, sid uuid, name text, lvl text, contact text, parent text, rate numeric, grp text, tut uuid, assigned boolean) on commit drop;
  insert into td_stu(seq, k, name, lvl, contact, parent, rate, grp, tut, assigned) values
    ( 1, 'marker', 'Zoe Lim',       'P4',    '+65 8000 3101', 'Mrs Lim',    55, 'A', m1, true),    -- (Zoe is the marker student)
    ( 2, 'lim2',   'Zane Lim',      'P6',    '+65 8000 3101', 'Mrs Lim',    60, 'A', m1, true),    -- sibling of Zoe: one family invoice
    ( 3, 'chua',   'Caleb Chua',    'Sec 1', '+65 8000 3102', 'Mr Chua',    70, 'A', m2, true),
    ( 4, 'teo',    'Mia Teo',       'P5',    '+65 8000 3103', 'Mrs Teo',    60, 'A', m1, true),
    ( 5, 'ng',     'Ben Ng',        'Sec 2', '+65 8000 3104', 'Mr Ng',      70, 'A', m2, true),
    ( 6, 'rah',    'Irfan Rahman',  'P6',    '+65 8000 3105', 'Mrs Rahman', 60, 'R', m1, true),    -- two past invoices + family credit
    ( 7, 'wong',   'Wendy Wong',    'Sec 3', '+65 8000 3106', 'Mr Wong',    75, 'A', m2, true),    -- big family credit for the refund stages
    ( 8, 'varma',  'Uma Varma',     'P3',    '+65 8000 3107', 'Mrs Varma',  55, 'A', m1, true),    -- deposit waived
    ( 9, 'd1',     'Noah Pang',     'P5',    '+65 8000 3108', 'Mrs Pang',   60, 'L', m1, true),    -- left, deposit paid, no refund asked yet
    (10, 'd2',     'Olivia Quek',   'P4',    '+65 8000 3109', 'Mr Quek',    55, 'L', m2, true),    -- left: deposit refund REQUESTED
    (11, 'd3',     'Pranav Reddy',  'Sec 1', '+65 8000 3110', 'Mrs Reddy',  70, 'L', m1, true),    -- left: deposit refund APPROVED
    (12, 'd4',     'Qian Yu Tan',   'P6',    '+65 8000 3111', 'Mr Tan',     60, 'L', m2, true),    -- left: deposit refund PAID
    (13, 'd5',     'Rina Sim',      'Sec 2', '+65 8000 3112', 'Mrs Sim',    70, 'L', m1, true),    -- left: deposit refund CANCELLED
    (21, 'fong1',  'Lena Fong',     'P3',    '+65 8000 3201', 'Mrs Fong',   55, 'B', m1, true),    -- never invoiced, siblings
    (22, 'fong2',  'Leo Fong',      'P5',    '+65 8000 3201', 'Mrs Fong',   60, 'B', m1, true),
    (23, 'pil1',   'Anya Pillai',   'Sec 1', '+65 8000 3202', 'Mr Pillai',  70, 'B', m2, true),    -- never invoiced, siblings
    (24, 'pil2',   'Arjun Pillai',  'Sec 3', '+65 8000 3202', 'Mr Pillai',  75, 'B', m2, true),
    (25, 'gill',   'Harpreet Gill', 'P6',    '+65 8000 3203', 'Mrs Gill',   60, 'B', m1, true),
    (26, 'hassan', 'Nadia Hassan',  'Sec 2', '+65 8000 3204', 'Mr Hassan',  70, 'B', m2, true),
    (27, 'ismail', 'Danish Ismail', 'P4',    '+65 8000 3205', 'Mrs Ismail', 55, 'B', m1, true),
    (28, 'trial',  'Kai Seng Yeo',  'P2',    '+65 8000 3206', 'Mrs Yeo',    55, 'B', m2, true),    -- one TRIAL lesson only: never billed, no deposit
    (31, 'aaron',  'Aaron Lee',     'P6',    '+65 8000 3301', 'Mrs Lee',    45, 'T', m1, true),    -- class of two
    (32, 'bella',  'Bella Ng',      'P6',    '+65 8000 3302', 'Mr Ng',      45, 'T', m1, true),
    (33, 'cyrus',  'Cyrus Ho',      'Sec 1', '+65 8000 3303', 'Mrs Ho',     70, 'T', m1, true),
    (34, 'dina',   'Dina Rao',      'P5',    '+65 8000 3304', 'Mr Rao',     60, 'T', m1, true),
    (35, 'evan',   'Evan Soh',      'Sec 2', '+65 8000 3305', 'Mrs Soh',    70, 'T', m1, false);   -- NOT assigned to tutor.one: the refusal line
  update td_stu set sid = ('00000000-0000-0000-0000-0000000e01' || lpad(seq::text, 2, '0'))::uuid where seq >= 1;
  update td_stu set sid = marker_id where k = 'marker';
  insert into students(id, tutor_id, org_id, name, level, contact, recipient_name, start_date)
    select sid, owner_id, c, name, lvl, contact, parent, case grp when 'R' then ppm + 1 when 'B' then cm else pm + 1 end from td_stu order by seq;
  insert into student_tutors(org_id, student_id, membership_id, since, created_by)
    select c, sid, tut, least(pm, today), owner_id from td_stu where assigned order by seq;

  -- ---------------------------------------------------------------- 5. lessons: past months (to invoice and issue), this month (never invoiced), the future (tutor tests)
  insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, subject, rate, amount, status, taught_by, trial)
    select owner_id, c, t.sid, mstart + d, make_time(14 + (t.seq % 5), 0, 0), make_time(15 + (t.seq % 5), 0, 0),
           case t.seq % 3 when 0 then 'Math' when 1 then 'English' else 'Science' end, t.rate, t.rate, 'scheduled', t.tut, false
      from td_stu t cross join lateral (values (pm, 2), (pm, 9), (pm, 16)) x(mstart, d)
     where t.grp in ('A', 'L', 'R');
  insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, subject, rate, amount, status, taught_by, trial)
    select owner_id, c, t.sid, ppm + d, make_time(16, 0, 0), make_time(17, 0, 0), 'Math', t.rate, t.rate, 'scheduled', t.tut, false
      from td_stu t cross join (values (3), (10), (17)) x(d) where t.grp = 'R';
  insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, subject, rate, amount, status, taught_by, trial)
    select owner_id, c, t.sid, greatest(cm, today - x.back - (t.seq % 3)), make_time(15 + (t.seq % 4), 0, 0), make_time(16 + (t.seq % 4), 0, 0),
           case t.seq % 3 when 0 then 'Math' when 1 then 'English' else 'Science' end, t.rate, t.rate, 'scheduled', t.tut, t.k = 'trial'
      from td_stu t cross join (values (5), (3), (0)) x(back) where t.grp = 'B' and (t.k <> 'trial' or x.back = 3);
  -- the tutor tests: a class of two (one lesson row per student, tied by session_id) and 1-to-1 lessons, all in the future, taught by tutor.one
  insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, subject, rate, amount, status, taught_by, session_id)
    select owner_id, c, t.sid, today + d, '17:00', '18:30', 'P6 Math class', t.rate, round(t.rate * 1.5, 2), 'scheduled', m1, class_sess
      from td_stu t cross join (values (3), (10)) x(d) where t.k in ('aaron', 'bella');
  insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, subject, rate, amount, status, taught_by)
    select owner_id, c, t.sid, today + x.d, x.st, x.et, x.subj, t.rate, t.rate, 'scheduled', m1
      from td_stu t join (values ('cyrus', 2, '15:00'::time, '16:00'::time, 'Math'), ('cyrus', 4, '16:00', '17:00', 'Math'), ('cyrus', 9, '16:00', '17:00', 'Math'),
                                 ('dina', 1, '06:30', '07:30', 'English'), ('dina', 6, '10:00', '11:00', 'English'), ('dina', 13, '10:00', '11:00', 'English'),
                                 ('evan', 5, '15:00', '16:00', 'Science')) x(k, d, st, et, subj) on x.k = t.k;

  -- ---------------------------------------------------------------- 6. mark every past lesson "attended" (the app's own function, as the owner)
  for l in select id from lessons where org_id = c and student_id in (select sid from td_stu) and lesson_date <= today and attendance is null order by lesson_date, start_time, id loop
    perform staff_mark_attendance(l.id, 'attended', 'Demo lesson (seed)');
  end loop;

  -- ---------------------------------------------------------------- 7. invoice runs for the two PAST months, issued with past dates
  -- 7a. two months ago: only Irfan Rahman has lessons there. Draft with the app's run, then issue (past date, due 7 days later).
  res := centre_invoice_run_create_drafts(c, ppm);
  update centre_invoices set status = 'issued', issue_date = ppm + 20, due_date = ppm + 27
   where org_id = c and status = 'draft' and period_start = ppm
     and (student_id in (select sid from td_stu) or household_id in (select household_id from students where id in (select sid from td_stu)));
  -- 7b. last month: everybody else. The deposit of Uma Varma is waived while it is still a draft (the app's function discards the draft).
  res := centre_invoice_run_create_drafts(c, pm);
  perform centre_deposit_waive((select sid from td_stu where k = 'varma'), 'Demo: deposit waived for a staff member''s family');
  update centre_invoices set status = 'issued', issue_date = pm + 20, due_date = pm + 27
   where org_id = c and status = 'draft' and period_start = pm
     and (student_id in (select sid from td_stu) or household_id in (select household_id from students where id in (select sid from td_stu)));

  -- ---------------------------------------------------------------- 8. payments (centre_record_payment, past dates), as the owner
  -- plan: who | month | lesson invoice: full / half / none | deposit invoice: full / part (S$30) / none | extra cents paid on top (becomes family credit)
  for r in select * from (values
      ('rah',   'ppm', 'full', 'full', 2500),      -- pays everything of two months ago + S$25 extra = family credit; last month's invoice stays unpaid
      ('teo',   'pm',  'half', 'none', 0),         -- PART payment on the lesson invoice
      ('ng',    'pm',  'full', 'part', 0),         -- lesson invoice paid; deposit PART-PAID (S$30 of S$60)
      ('wong',  'pm',  'full', 'full', 10000),     -- S$100 family credit (the refund stages use it)
      ('varma', 'pm',  'full', 'none', 0),
      ('d1',    'pm',  'full', 'full', 0), ('d2', 'pm', 'full', 'full', 0), ('d3', 'pm', 'full', 'full', 0), ('d4', 'pm', 'full', 'full', 0), ('d5', 'pm', 'full', 'full', 0)
    ) p(k, mth, lp, dp, extra) loop
    select household_id into hh from students where id = (select sid from td_stu where k = r.k);
    select id, total_cents, issue_date into i_l from centre_invoices where org_id = c and kind = 'lesson' and status = 'issued' and household_id = hh and period_start = case r.mth when 'ppm' then ppm else pm end;
    select id, total_cents into i_d from centre_invoices where org_id = c and kind = 'deposit' and status = 'issued' and student_id = (select sid from td_stu where k = r.k);
    ids := '{}'; amt := 0;
    if r.lp in ('full', 'half') and i_l.id is not null then ids := ids || i_l.id; amt := amt + case r.lp when 'half' then i_l.total_cents / 2 else i_l.total_cents end; end if;
    if r.dp = 'full' and i_d.id is not null then ids := ids || i_d.id; amt := amt + i_d.total_cents;
    elsif r.dp = 'part' and i_d.id is not null then ids := ids || i_d.id; amt := amt + 3000; end if;
    amt := amt + r.extra;
    if amt > 0 then
      res := centre_record_payment(c, hh, case when r.k in ('d1', 'd3', 'd5') then 'bank' else 'manual_paynow' end, amt, i_l.issue_date + 3, 'DEMO-' || upper(r.k), ids, (select parent from td_stu where k = r.k), 'Demo payment (seed)');
    end if;
  end loop;

  -- ---------------------------------------------------------------- 9. five students have LEFT (lessons ended last month, all invoiced)
  for r in select sid from td_stu where grp = 'L' order by seq loop
    res := staff_set_student_end(c, r.sid, last_pm);
  end loop;

  -- ---------------------------------------------------------------- 10. refunds at every stage (deposit: asked by the billing staff; family credit: asked by the cashier; the owner approves and pays)
  -- deposit refunds
  perform set_config('request.jwt.claims', json_build_object('sub', billing_id, 'role', 'authenticated')::text, false);
  res := centre_deposit_refund_request((select sid from td_stu where k = 'd2'), 6000, 0, 0, null, 'Mr Quek', 'Demo: student left, refund asked', 't47-dep-requested');          -- stays REQUESTED
  res := centre_deposit_refund_request((select sid from td_stu where k = 'd3'), 6000, 0, 0, null, 'Mrs Reddy', 'Demo: student left, refund asked', 't47-dep-approved');
  res := centre_deposit_refund_request((select sid from td_stu where k = 'd4'), 6000, 0, 0, null, 'Mr Tan', 'Demo: student left, refund asked', 't47-dep-paid');
  res := centre_deposit_refund_request((select sid from td_stu where k = 'd5'), 6000, 0, 0, null, 'Mrs Sim', 'Demo: student left, refund asked', 't47-dep-cancelled');
  res := centre_refund_cancel((select id from centre_refunds where org_id = c and request_key = 't47-dep-cancelled'), 'Demo: the family changed their mind');                           -- CANCELLED (by the person who asked)
  -- family-credit refunds (the Wong family holds S$100)
  perform set_config('request.jwt.claims', json_build_object('sub', cashier_id, 'role', 'authenticated')::text, false);
  select household_id into hh from students where id = (select sid from td_stu where k = 'wong');
  res := centre_credit_refund_request(c, hh, 1000, 'Mr Wong', 'Demo: credit refund asked', 't47-cred-requested');                                                                       -- stays REQUESTED
  res := centre_credit_refund_request(c, hh, 1000, 'Mr Wong', 'Demo: credit refund asked', 't47-cred-approved');
  res := centre_credit_refund_request(c, hh, 1000, 'Mr Wong', 'Demo: credit refund asked', 't47-cred-paid');
  res := centre_credit_refund_request(c, hh,  500, 'Mr Wong', 'Demo: credit refund asked', 't47-cred-cancelled');
  res := centre_refund_cancel((select id from centre_refunds where org_id = c and request_key = 't47-cred-cancelled'), 'Demo: asked twice by mistake');                                  -- CANCELLED
  -- the owner approves (the setting says the owner) and pays
  perform set_config('request.jwt.claims', json_build_object('sub', owner_id, 'role', 'authenticated')::text, false);
  for r in select id, request_key from centre_refunds where org_id = c and request_key in ('t47-dep-approved', 't47-dep-paid', 't47-cred-approved', 't47-cred-paid') order by request_key loop
    res := centre_refund_approve(r.id, 'Demo approval');
    if r.request_key in ('t47-dep-paid', 't47-cred-paid') then res := centre_refund_pay(r.id, 'bank', today, 'DEMO-REFUND', 'Demo payout (seed)'); end if;      -- PAID
  end loop;

  -- ---------------------------------------------------------------- 11. late fees: open the app's own list once, which makes the proposals for the overdue invoices
  res := centre_late_fee_list(c);

  perform set_config('request.jwt.claims', '', false);
  raise notice 'Money demo data created. Run the post-check below.';
end $seed$;

-- =====================================================================================================
-- POST-CHECK: one line. "SEED | OK ..." when every category has what the guide promises, otherwise "SEED | FAILED - <what is missing>".
-- Reads only; counts are taken straight from the tables (the demo centre is found by its members, as above).
-- =====================================================================================================
with ctx as (
  select o.id as c, (now() at time zone o.timezone)::date as today, date_trunc('month', (now() at time zone o.timezone)::date)::date as cm
    from organisations o
   where o.kind = 'centre'
     and exists (select 1 from memberships m join auth.users u on u.id = m.user_id where m.org_id = o.id and m.role = 'owner' and m.status = 'active' and u.email = 'centre.owner@example.test')
     and exists (select 1 from memberships m join auth.users u on u.id = m.user_id where m.org_id = o.id and m.role = 'tutor' and m.status = 'active' and u.email = 'tutor.one@example.test')
     and exists (select 1 from memberships m join auth.users u on u.id = m.user_id where m.org_id = o.id and m.role = 'tutor' and m.status = 'active' and u.email = 'tutor.two@example.test')
   limit 1
), seed as (select s.id, s.household_id, s.name, s.end_date from students s, ctx where s.org_id = ctx.c and s.id::text like '00000000-0000-0000-0000-0000000e01%'),
never as (                                        -- 1. attended, non-trial lessons this month that are on no invoice
  select distinct st.id, st.household_id from seed st cross join ctx join lessons l on l.student_id = st.id and l.org_id = ctx.c
   where l.attendance = 'attended' and l.status = 'done' and not l.trial and l.lesson_date >= ctx.cm
     and not exists (select 1 from centre_invoice_lines cl join centre_invoices ci on ci.id = cl.invoice_id where cl.lesson_id = l.id and ci.status <> 'void')
), bal as (
  select i.id, i.kind, i.due_date, i.total_cents, b.paid_cents, b.balance_cents, i.household_id, i.student_id
    from centre_invoices i, ctx, lateral centre_balance_rows(ctx.c, array[i.id]) b where i.org_id = ctx.c and i.status = 'issued' and i.kind in ('lesson', 'deposit')
), credit as (select f.household_id, sum(f.cents) as cents from centre_family_credit f, ctx where f.org_id = ctx.c group by f.household_id),
refs as (select r.kind, centre_refund_state(r.id) as st from centre_refunds r, ctx where r.org_id = ctx.c and r.request_key like 't47-%'),
fut as (select l.* from lessons l, ctx where l.org_id = ctx.c and l.lesson_date > ctx.today and l.student_id in (select id from seed)),
chk as (
  select
    (select count(*) from never) as never_students, (select count(distinct household_id) from never) as never_households,
    (select count(*) from (select household_id from never group by household_id having count(*) > 1) x) as sibling_households,
    (select count(*) from never n where not exists (select 1 from centre_deposits d where d.student_id = n.id)) as deposit_drafts_due,
    (select count(*) from bal, ctx where kind = 'lesson' and due_date < ctx.today and balance_cents > 0) as unpaid_past_due,
    (select count(*) from bal where kind = 'lesson' and paid_cents > 0 and balance_cents > 0) as part_paid_lesson,
    (select count(*) from credit c2 where c2.cents >= 1000 and exists (select 1 from bal where bal.household_id = c2.household_id and bal.kind = 'lesson' and bal.balance_cents > 0)) as credit_with_open_invoice,
    (select count(*) from centre_late_fees f, ctx where f.org_id = ctx.c and f.status = 'proposed') as late_fee_proposals,
    (select count(*) from seed st join bal on bal.student_id = st.id and bal.kind = 'deposit' and bal.balance_cents = 0 where st.end_date < (select today from ctx)) as left_deposit_paid,
    (select count(*) from bal where kind = 'deposit' and paid_cents > 0 and balance_cents > 0) as deposit_part_paid,
    (select count(*) from bal where kind = 'deposit' and paid_cents = 0) as deposit_unpaid,
    (select count(*) from centre_deposit_ledger g, ctx where g.org_id = ctx.c and g.kind = 'waived') as deposit_waived,
    (select count(*) from refs where kind = 'deposit' and st = 'requested') as dep_req, (select count(*) from refs where kind = 'deposit' and st = 'approved') as dep_app,
    (select count(*) from refs where kind = 'deposit' and st = 'paid') as dep_paid, (select count(*) from refs where kind = 'deposit' and st = 'cancelled') as dep_can,
    (select count(*) from refs where kind = 'family_credit' and st = 'requested') as cr_req, (select count(*) from refs where kind = 'family_credit' and st = 'approved') as cr_app,
    (select count(*) from refs where kind = 'family_credit' and st = 'paid') as cr_paid, (select count(*) from refs where kind = 'family_credit' and st = 'cancelled') as cr_can,
    (org_four_eyes_ready((select c from ctx))) as four_eyes_ready,
    (select count(*) from (select session_id from fut where session_id is not null group by session_id having count(distinct student_id) = 2) x) as class_sessions,
    (select count(*) from fut f where f.session_id is null and exists (select 1 from student_tutors t where t.student_id = f.student_id and t.membership_id = f.taught_by and t.active)) as future_assigned,
    (select count(*) from fut f where not exists (select 1 from student_tutors t where t.student_id = f.student_id and t.membership_id = f.taught_by and t.active)) as future_unassigned,
    (select settings #>> '{billing,deposit,mode}' || '/' || (settings #>> '{billing,one_off_fees,deposit_cents}') || '/' || (settings #>> '{billing,late_fee,repeat}') || '/' || (settings #>> '{billing,late_fee,amount_cents}')
            || '/' || (settings #>> '{invoicing,due_days}') || '/' || (settings #>> '{billing,deposit,refund_approved_by}') || '/' || (settings #>> '{lessons,timetable_editing}') || '/' || (settings #>> '{lessons,min_notice_hours}')
       from org_settings, ctx where org_id = ctx.c and effective_from <= current_date order by effective_from desc, version desc limit 1) as settings_now
)
select case when (select c from ctx) is null then 'SEED | FAILED - the demo centre was not found (run db/seed_dev_demo.sql first)'
  when never_students < 5 or sibling_households < 1 or deposit_drafts_due < 5 then 'SEED | FAILED - never-invoiced students: ' || never_students || ', sibling families: ' || sibling_households || ', deposits due: ' || deposit_drafts_due
  when unpaid_past_due < 3 or part_paid_lesson < 1 or credit_with_open_invoice < 1 or late_fee_proposals < 1 then 'SEED | FAILED - unpaid past due: ' || unpaid_past_due || ', part paid: ' || part_paid_lesson || ', credit + open invoice: ' || credit_with_open_invoice || ', late fees: ' || late_fee_proposals
  when left_deposit_paid < 1 or deposit_part_paid < 1 or deposit_unpaid < 1 or deposit_waived < 1 then 'SEED | FAILED - left+paid deposit: ' || left_deposit_paid || ', part-paid: ' || deposit_part_paid || ', unpaid: ' || deposit_unpaid || ', waived: ' || deposit_waived
  when dep_req < 1 or dep_app < 1 or dep_paid < 1 or dep_can < 1 or cr_req < 1 or cr_app < 1 or cr_paid < 1 or cr_can < 1 or not four_eyes_ready then 'SEED | FAILED - refunds deposit r/a/p/c ' || dep_req || '/' || dep_app || '/' || dep_paid || '/' || dep_can || ', credit r/a/p/c ' || cr_req || '/' || cr_app || '/' || cr_paid || '/' || cr_can || ', four-eyes ready: ' || four_eyes_ready
  when class_sessions < 1 or future_assigned < 3 or future_unassigned < 1 then 'SEED | FAILED - class sessions: ' || class_sessions || ', future assigned: ' || future_assigned || ', future unassigned: ' || future_unassigned
  when settings_now is distinct from 'fixed/6000/monthly/1000/7/owner/tutors_direct/24' then 'SEED | FAILED - settings in force: ' || coalesce(settings_now, 'none')
  else 'SEED | OK'
    || ' | never-invoiced students=' || never_students || ' families=' || never_households || ' sibling-families=' || sibling_households || ' deposit-drafts-due=' || deposit_drafts_due
    || ' | issued-unpaid-past-due=' || unpaid_past_due || ' part-paid=' || part_paid_lesson || ' credit-family-with-open-invoice=' || credit_with_open_invoice || ' late-fee-proposals=' || late_fee_proposals
    || ' | deposits: left+paid=' || left_deposit_paid || ' part-paid=' || deposit_part_paid || ' unpaid=' || deposit_unpaid || ' waived=' || deposit_waived
    || ' | refunds deposit r/a/p/c=' || dep_req || '/' || dep_app || '/' || dep_paid || '/' || dep_can || ' credit r/a/p/c=' || cr_req || '/' || cr_app || '/' || cr_paid || '/' || cr_can || ' four-eyes-ready=' || four_eyes_ready
    || ' | tutor: class-sessions=' || class_sessions || ' future-assigned=' || future_assigned || ' future-unassigned=' || future_unassigned
    || ' | settings=' || settings_now end as seed_result
from chk;
