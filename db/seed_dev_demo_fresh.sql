-- =====================================================================================================
-- T52: A SECOND, PRISTINE DEMO CENTRE ("Demo Fresh Centre") FOR THE DEV DATABASE ONLY (project tuzxsqkfzrjssnpcoale).
-- NEVER run this on the live project. Everything is invented (@example.test logins, +65 8000 41xx numbers).
-- Undo: db/seed_dev_demo_fresh_down.sql. Guide: docs/orchestrator/dev-seed-fresh.md.
--
-- WHY: the first demo centre drifts (renamed, staff hold every permission, old invoices) and, once a centre is launched, billing-type
-- settings only start on the 1st of next month. This centre is created and then LEFT IN SETUP, the one state in which org_save_settings
-- applies a settings change immediately (and allows back-dating), so a tester can try tutor pay, statement matching, four-eyes refunds,
-- make-up credit expiry … the same day. No invoices, payments, deposits or refunds exist: the tester makes them.
--
-- WHAT IT CREATES (logins all use the password  Demo-Pass-2026):
--   fresh.owner@example.test      owner
--   fresh.billing@example.test    staff: issue_invoices only
--   fresh.cashier@example.test    staff: record_payments only
--   fresh.frontdesk@example.test  staff: manage_students + manage_timetable
--   fresh.tutor.one@example.test  centre tutor        fresh.tutor.two@example.test  centre tutor
--   8 students in 6 families (two sibling pairs share a phone number), each with a weekly slot and assigned to a tutor; weekly lessons from
--   6 weeks ago to 2 weeks ahead. Lessons older than 14 days are MARKED (attended, one absent, one cancelled in time); the last 14 days and today
--   are left UNMARKED, so tutors and staff can mark them AFTER switching the settings they want to try.
--
-- SAFE TO RUN TWICE: the second run sees the centre (found by its owner login, never by name: it may be renamed) and only prints the post-check.
-- It REFUSES to run (nothing is written) unless ALL of these hold ("this is the DEV project" proof):
--   * exactly one centre is the old demo centre: centre.owner@ owner, tutor.one@ + tutor.two@ tutors (the live project has no such centre),
--     every member of it is an @example.test login and it has no Stripe subscription;
--   * none of the six fresh logins exists already outside a fresh centre (a half-run or a real person is never adopted);
--   * (after creating) every member of the new centre is an @example.test login and it has no Stripe subscription. If not, the whole run rolls back.
-- Dates are relative to today in the centre's time zone, so it works on any day.
-- Needs every migration applied first (the whole chain in CLAUDE.md, incl. bundle 7) and db/seed_dev_demo.sql.
-- =====================================================================================================
do $seed$
declare
  owner_id    constant uuid := '00000000-0000-0000-0000-00000000d201';
  billing_id  constant uuid := '00000000-0000-0000-0000-00000000d202';
  cashier_id  constant uuid := '00000000-0000-0000-0000-00000000d203';
  front_id    constant uuid := '00000000-0000-0000-0000-00000000d204';
  tutor1_id   constant uuid := '00000000-0000-0000-0000-00000000d205';
  tutor2_id   constant uuid := '00000000-0000-0000-0000-00000000d206';
  n int; found_list text; old_c uuid; c uuid; tz text; today date; m1 uuid; m2 uuid; r record; s jsonb; bad int;
begin
  -- ---------------------------------------------------------------- 1. pre-checks: refuse unless this is the DEV project
  select count(*), string_agg(o.trading_name || ' (' || o.id || ')', '; ' order by o.created_at), (array_agg(o.id order by o.created_at))[1]
    into n, found_list, old_c
    from organisations o
    where o.kind = 'centre'
      and exists (select 1 from memberships m join auth.users u on u.id = m.user_id where m.org_id = o.id and m.role = 'owner' and m.status = 'active' and u.email = 'centre.owner@example.test')
      and exists (select 1 from memberships m join auth.users u on u.id = m.user_id where m.org_id = o.id and m.role = 'tutor' and m.status = 'active' and u.email = 'tutor.one@example.test')
      and exists (select 1 from memberships m join auth.users u on u.id = m.user_id where m.org_id = o.id and m.role = 'tutor' and m.status = 'active' and u.email = 'tutor.two@example.test');
  if n = 0 then raise exception 'REFUSED: no centre has centre.owner@ as owner and tutor.one@ + tutor.two@ as tutors (run db/seed_dev_demo.sql first). This is not the DEV demo database.'; end if;
  if n > 1 then raise exception using message = 'REFUSED: ' || n || ' centres match the old demo centre (' || found_list || '). Not guessing: ask the project owner.'; end if;
  if exists (select 1 from memberships m join auth.users u on u.id = m.user_id where m.org_id = old_c and u.email not like '%@example.test') then
    raise exception 'REFUSED: the old demo centre has a member whose login is not an @example.test address. This does not look like the DEV demo data.'; end if;
  if exists (select 1 from org_subscriptions x where x.org_id = old_c and x.stripe_subscription_id is not null) then
    raise exception 'REFUSED: the old demo centre has a Stripe subscription. This does not look like the DEV demo data.'; end if;

  -- already there? (found by its owner login)
  select o.id into c from organisations o join memberships m on m.org_id = o.id and m.role = 'owner' and m.user_id = owner_id where o.kind = 'centre' limit 1;
  if c is not null then
    raise notice 'The fresh demo centre is already there (%): nothing changed.', c; return; end if;
  if exists (select 1 from auth.users where id in (owner_id, billing_id, cashier_id, front_id, tutor1_id, tutor2_id) or email like 'fresh.%@example.test') then
    raise exception 'REFUSED: one of the fresh demo logins exists already but there is no fresh centre (a half-finished earlier run?). Run db/seed_dev_demo_fresh_down.sql first.'; end if;

  -- ---------------------------------------------------------------- 2. six confirmed email logins (the sign-up trigger gives each a profile and a solo organisation)
  for r in select * from (values (owner_id, 'fresh.owner@example.test', 'Fresh Owner'), (billing_id, 'fresh.billing@example.test', 'Fresh Billing Staff'),
      (cashier_id, 'fresh.cashier@example.test', 'Fresh Cashier'), (front_id, 'fresh.frontdesk@example.test', 'Fresh Front Desk'),
      (tutor1_id, 'fresh.tutor.one@example.test', 'Fresh Tutor One'), (tutor2_id, 'fresh.tutor.two@example.test', 'Fresh Tutor Two')) v(id, email, name) loop
    insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, confirmation_token, recovery_token, email_change_token_new,
        email_change, email_change_token_current, reauthentication_token, phone_change, phone_change_token, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values ('00000000-0000-0000-0000-000000000000', r.id, 'authenticated', 'authenticated', r.email, extensions.crypt('Demo-Pass-2026', extensions.gen_salt('bf')), now(),
        '', '', '', '', '', '', '', '', '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name', r.name, 'email_verified', true), now(), now());
    insert into auth.identities(id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), r.id, jsonb_build_object('sub', r.id::text, 'email', r.email, 'email_verified', true, 'phone_verified', false), 'email', r.id::text, now(), now(), now());
  end loop;

  -- ---------------------------------------------------------------- 3. the centre: created through the app's own function, then LEFT IN SETUP
  -- Plain starting settings (postpaid lessons, no deposit, no late fee, no credits, tutor pay "report"): the tester switches on what they want to try.
  s := '{"schema_version":1,"preset":"centre",
    "profile":{"trading_name":"Demo Fresh Centre","gst_registered":false,"gst_rate_bp":900,"gst_inclusive":false,"invoice_prefix":"FRS","next_invoice_number":1},
    "calendar":{},"billing":{"model":"postpaid_lessons"},"invoicing":{"grouping":"family"},"payments":{"modes":["manual_paynow"]},
    "lessons":{"timetable_editing":"admin_only","attendance_by":"tutor","attendance_window_days":14,"cancellations_marked_by":"admin",
               "compensation_entered_by":"admin","trials_flagged_by":"admin","remarks":{"required":false,"deadline_hours":24,"visibility":"admin_only"},
               "replacement_tutors":true,"tutors_see_parent_contact":false},
    "tutor_pay":{"mode":"report","payable_when":"parent_paid"},"data":{"seed_fresh":"t52"}}'::jsonb;
  perform set_config('request.jwt.claims', json_build_object('sub', owner_id, 'role', 'authenticated')::text, false);
  c := public.org_create_centre('Demo Fresh Centre', s);                    -- status 'setup'; setup_step is raised to the last wizard step so every step is open
  update organisations set setup_step = 10 where id = c;
  select timezone into tz from organisations where id = c;
  today := (now() at time zone tz)::date;
  -- the same settings once more, effective 90 days back (setup allows it), so every past day the demo needs reads settings too
  perform org_save_settings(c, s, today - 90);

  insert into memberships(org_id, user_id, display_name, role, permissions, status) values
    (c, billing_id, 'Fresh Billing Staff', 'staff', array['issue_invoices'], 'active'),
    (c, cashier_id, 'Fresh Cashier', 'staff', array['record_payments'], 'active'),
    (c, front_id, 'Fresh Front Desk', 'staff', array['manage_students','manage_timetable'], 'active'),
    (c, tutor1_id, 'Fresh Tutor One', 'tutor', '{}', 'active'),
    (c, tutor2_id, 'Fresh Tutor Two', 'tutor', '{}', 'active');
  select id into m1 from memberships where org_id = c and user_id = tutor1_id;
  select id into m2 from memberships where org_id = c and user_id = tutor2_id;

  -- ---------------------------------------------------------------- 4. eight students in six families (siblings share the phone number, as the app groups them)
  create temp table td_fr(seq int primary key, k text, sid uuid, name text, lvl text, contact text, parent text, rate numeric, tut uuid, wd int, st time, et time, subj text) on commit drop;
  insert into td_fr values
    (1, 'ivy',   '00000000-0000-0000-0000-0000000e0201', 'Ivy Foo',       'P4',    '+65 8000 4101', 'Mrs Foo',   55, m1, 0, '15:00', '16:00', 'Math'),
    (2, 'isaac', '00000000-0000-0000-0000-0000000e0202', 'Isaac Foo',     'P6',    '+65 8000 4101', 'Mrs Foo',   60, m1, 2, '16:00', '17:00', 'English'),
    (3, 'jas',   '00000000-0000-0000-0000-0000000e0203', 'Jasmine Kwek',  'Sec 1', '+65 8000 4102', 'Mr Kwek',   70, m1, 1, '17:00', '18:00', 'Science'),
    (4, 'kenji', '00000000-0000-0000-0000-0000000e0204', 'Kenji Ito',     'P5',    '+65 8000 4103', 'Mrs Ito',   60, m2, 0, '16:00', '17:00', 'Math'),
    (5, 'kaito', '00000000-0000-0000-0000-0000000e0205', 'Kaito Ito',     'Sec 2', '+65 8000 4103', 'Mrs Ito',   70, m2, 3, '17:00', '18:00', 'Science'),
    (6, 'leah',  '00000000-0000-0000-0000-0000000e0206', 'Leah Mohan',    'P3',    '+65 8000 4104', 'Mr Mohan',  55, m2, 1, '15:00', '16:00', 'English'),
    (7, 'marcus','00000000-0000-0000-0000-0000000e0207', 'Marcus Neo',    'Sec 3', '+65 8000 4105', 'Mrs Neo',   75, m1, 4, '16:00', '17:30', 'Math'),
    (8, 'nora',  '00000000-0000-0000-0000-0000000e0208', 'Nora Ong',      'P6',    '+65 8000 4106', 'Mr Ong',    60, m2, 2, '15:00', '16:00', 'Math');
  insert into students(id, tutor_id, org_id, name, level, contact, recipient_name, start_date)
    select sid, owner_id, c, name, lvl, contact, parent, today - 60 from td_fr order by seq;
  insert into student_tutors(org_id, student_id, membership_id, since, created_by) select c, sid, tut, today - 60, owner_id from td_fr order by seq;

  -- ---------------------------------------------------------------- 5. weekly slots and the lessons they made (6 weeks back to 2 weeks ahead)
  insert into recurring_slots(tutor_id, org_id, student_id, weekday, start_time, end_time, subject, rate, active, taught_by)
    select owner_id, c, sid, wd, st, et, subj, rate, true, tut from td_fr order by seq;
  insert into lessons(tutor_id, org_id, student_id, slot_id, lesson_date, start_time, end_time, subject, rate, amount, status, taught_by)
    select owner_id, c, f.sid, sl.id, d::date, f.st, f.et, f.subj, f.rate, round(f.rate * extract(epoch from (f.et - f.st)) / 3600, 2), 'scheduled', f.tut
      from td_fr f join recurring_slots sl on sl.org_id = c and sl.student_id = f.sid
      cross join generate_series(today - 42, today + 14, interval '1 day') d
     where extract(isodow from d)::int - 1 = f.wd;

  -- ---------------------------------------------------------------- 6. mark every lesson older than 14 days (the app's own function, as the owner); the recent ones stay unmarked
  for r in select l.id, row_number() over (order by l.lesson_date, l.start_time, l.id) rn
             from lessons l where l.org_id = c and l.lesson_date < today - 14 order by l.lesson_date, l.start_time, l.id loop
    perform staff_mark_attendance(r.id, case when r.rn = 7 then 'absent' when r.rn = 12 then 'cancelled_early' else 'attended' end, 'Demo lesson (seed)');
  end loop;

  -- ---------------------------------------------------------------- 7. the "still the DEV demo" proof for the NEW centre, or roll everything back
  select count(*) into bad from memberships m join auth.users u on u.id = m.user_id where m.org_id = c and u.email not like '%@example.test';
  if bad > 0 then raise exception 'REFUSED (rolled back): the new centre has a member whose login is not an @example.test address.'; end if;
  if exists (select 1 from org_subscriptions x where x.org_id = c and x.stripe_subscription_id is not null) then
    raise exception 'REFUSED (rolled back): the new centre has a Stripe subscription.'; end if;
  perform set_config('request.jwt.claims', '', false);
  raise notice 'Demo Fresh Centre created (%), left in setup. Run the post-check below.', c;
end $seed$;

-- =====================================================================================================
-- POST-CHECK: one line. "SEED FRESH | OK ..." when the centre is as the guide promises, otherwise "SEED FRESH | FAILED - <what is wrong>". Reads only.
-- =====================================================================================================
with ctx as (
  select o.id c, o.status, o.setup_step from organisations o join memberships m on m.org_id = o.id and m.role = 'owner' and m.status = 'active'
    join auth.users u on u.id = m.user_id and u.email = 'fresh.owner@example.test' where o.kind = 'centre'
), k as (
  select ctx.c, ctx.status, ctx.setup_step,
    (select count(*) from memberships where org_id = ctx.c and role = 'owner' and status = 'active') owners,
    (select count(*) from memberships m where m.org_id = ctx.c and m.role = 'staff' and m.status = 'active' and m.permissions = array['issue_invoices']) billing,
    (select count(*) from memberships m where m.org_id = ctx.c and m.role = 'staff' and m.status = 'active' and m.permissions = array['record_payments']) cashiers,
    (select count(*) from memberships m where m.org_id = ctx.c and m.role = 'staff' and m.status = 'active' and m.permissions @> array['manage_students'] and cardinality(m.permissions) = 2) frontdesk,
    (select count(*) from memberships where org_id = ctx.c and role = 'tutor' and status = 'active') tutors,
    (select count(*) from memberships m join auth.users u on u.id = m.user_id where m.org_id = ctx.c and u.email not like '%@example.test') real_members,
    (select count(*) from org_subscriptions x where x.org_id = ctx.c and x.stripe_subscription_id is not null) stripe,
    (select count(*) from students where org_id = ctx.c) students,
    (select count(distinct household_id) from students where org_id = ctx.c) families,
    (select count(*) from recurring_slots where org_id = ctx.c and active) slots,
    (select count(*) from lessons where org_id = ctx.c) lessons,
    (select count(*) from lessons where org_id = ctx.c and attendance is not null) marked,
    (select count(*) from lessons where org_id = ctx.c and attendance is null and lesson_date <= (now() at time zone 'Asia/Singapore')::date) to_mark,
    (select count(*) from lessons where org_id = ctx.c and lesson_date > (now() at time zone 'Asia/Singapore')::date) future,
    (select count(*) from centre_invoices where org_id = ctx.c) invoices,
    (select count(*) from centre_payments where org_id = ctx.c) payments
  from ctx)
select case
  when not exists (select 1 from ctx) then 'SEED FRESH | FAILED - the fresh centre was not found'
  when (select status from k) <> 'setup' then 'SEED FRESH | FAILED - the centre is not in setup (status ' || (select status from k) || '): settings would not take effect at once'
  when (select owners <> 1 or billing <> 1 or cashiers <> 1 or frontdesk <> 1 or tutors <> 2 from k) then 'SEED FRESH | FAILED - wrong people: owners/billing/cashier/frontdesk/tutors = ' || (select owners || '/' || billing || '/' || cashiers || '/' || frontdesk || '/' || tutors from k)
  when (select real_members > 0 or stripe > 0 from k) then 'SEED FRESH | FAILED - a member is not @example.test or a Stripe subscription exists'
  when (select students <> 8 or families <> 6 or slots <> 8 or marked = 0 or to_mark = 0 or future = 0 from k) then 'SEED FRESH | FAILED - students/families/slots/marked/to-mark/future = ' || (select students || '/' || families || '/' || slots || '/' || marked || '/' || to_mark || '/' || future from k)
  when (select invoices > 0 or payments > 0 from k) then 'SEED FRESH | NOTE - this centre already holds invoices or payments (a tester has used it); the pristine counts below are no longer zero'
  else 'SEED FRESH | OK | status=setup setup-step=' || (select setup_step from k) || ' owner=1 billing-staff=1 cashier=1 frontdesk=1 tutors=2 students=' || (select students from k) || ' families=' || (select families from k)
       || ' slots=' || (select slots from k) || ' lessons=' || (select lessons from k) || ' marked=' || (select marked from k) || ' to-mark=' || (select to_mark from k) || ' future=' || (select future from k)
       || ' invoices=0 payments=0 settings-versions=' || (select count(*) from org_settings where org_id = (select c from k))
end as seed_fresh_check;
