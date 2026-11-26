-- =====================================================================================================
-- DEMO DATA FOR THE DEV DATABASE ONLY (project tuzxsqkfzrjssnpcoale). NEVER run this on the live project.
-- Fictional people and made-up phone numbers. Gives previews something to click through:
--   centre.owner@example.test   owner of "Demo Learning Centre" (a launched tuition centre)
--   centre.staff@example.test   centre staff with every staff permission (students, timetable, tutors, invoices, payments, revenue, tutor pay, audit log)  → centre Home, all tabs
--   centre.frontdesk@example.test  centre staff with students only (manage_students)                        → centre Home shows only the student count; only Students in the menu
--   tutor.one@example.test      centre tutor with lessons today, to mark, cancelled, old and upcoming  → lands on My lessons (tutor-only menu)
--   tutor.two@example.test      second centre tutor (sees only their own lessons)
--   both.tutor@example.test     a solo tutor (2 students) who ALSO teaches at the centre              → My lessons appears in More
--   solo.tutor@example.test     a solo tutor on the free plan with exactly 5 active students           → adding a 6th shows the upgrade prompt
-- All seven sign in with the password  Demo-Pass-2026
-- Needs every migration applied first (org_foundation, billing, attendance, tutor_access, org_delete, function_lockdown, staff_home).
-- Safe to run twice: the first block does nothing when the demo is already there, and the staff block at the end only adds what is missing
-- (so a DEV database seeded before the two staff logins existed just gets them). To start completely fresh, first remove the demo users
-- (delete from auth.users where email like '%@example.test').
-- =====================================================================================================
do $$
declare
  owner_id  uuid := '00000000-0000-0000-0000-00000000d101';
  tutor1_id uuid := '00000000-0000-0000-0000-00000000d102';
  tutor2_id uuid := '00000000-0000-0000-0000-00000000d103';
  solo_id   uuid := '00000000-0000-0000-0000-00000000d104';
  both_id   uuid := '00000000-0000-0000-0000-00000000d105';
  c uuid; m1 uuid; m2 uuid; mb uuid;
  today date := (now() at time zone 'Asia/Singapore')::date;
  settings jsonb := '{"schema_version":1,"preset":"centre",
    "profile":{"trading_name":"Demo Learning Centre","gst_registered":false,"gst_rate_bp":900,"gst_inclusive":false,"invoice_prefix":"DLC","next_invoice_number":1},
    "calendar":{},"billing":{"model":"postpaid_lessons"},"invoicing":{"grouping":"family"},"payments":{"modes":["manual_paynow"]},
    "lessons":{"timetable_editing":"admin_only","attendance_by":"tutor","attendance_window_days":14,"cancellations_marked_by":"admin",
               "compensation_entered_by":"admin","trials_flagged_by":"admin","remarks":{"required":false,"deadline_hours":24,"visibility":"admin_only"},
               "replacement_tutors":true,"tutors_see_parent_contact":false},
    "tutor_pay":{"mode":"report","payable_when":"parent_paid"},"data":{}}';
  r record;
begin
  if exists (select 1 from auth.users where email = 'centre.owner@example.test') then
    raise notice 'Demo data is already there; only the staff logins below are added if missing.';
    return;
  end if;
  -- ---------------------------------------------------------------- five confirmed email logins
  for r in select * from (values (owner_id, 'centre.owner@example.test', 'Demo Centre Owner'), (tutor1_id, 'tutor.one@example.test', 'Demo Tutor One'),
      (tutor2_id, 'tutor.two@example.test', 'Demo Tutor Two'), (solo_id, 'solo.tutor@example.test', 'Demo Solo Tutor'), (both_id, 'both.tutor@example.test', 'Demo Both Tutor')) v(id, email, name) loop
    insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, confirmation_token, recovery_token, email_change_token_new,
        email_change, email_change_token_current, reauthentication_token, phone_change, phone_change_token, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values ('00000000-0000-0000-0000-000000000000', r.id, 'authenticated', 'authenticated', r.email, extensions.crypt('Demo-Pass-2026', extensions.gen_salt('bf')), now(),
        '', '', '', '', '', '', '', '', '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name', r.name, 'email_verified', true), now(), now());
    insert into auth.identities(id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), r.id, jsonb_build_object('sub', r.id::text, 'email', r.email, 'email_verified', true, 'phone_verified', false), 'email', r.id::text, now(), now(), now());
  end loop;                                  -- (the sign-up trigger gave each one a profile and a solo organisation)

  -- ---------------------------------------------------------------- the centre, launched, with its two tutors (and the "both" login as a third)
  perform set_config('request.jwt.claims', json_build_object('sub', owner_id, 'role', 'authenticated')::text, false);
  c := public.org_create_centre('Demo Learning Centre', settings);
  update organisations set status = 'active', setup_step = 10 where id = c;
  insert into memberships(org_id, user_id, display_name, role, status) values
    (c, tutor1_id, 'Demo Tutor One', 'tutor', 'active'), (c, tutor2_id, 'Demo Tutor Two', 'tutor', 'active'), (c, both_id, 'Demo Both Tutor', 'tutor', 'active');
  select id into m1 from memberships where org_id = c and user_id = tutor1_id;
  select id into m2 from memberships where org_id = c and user_id = tutor2_id;
  select id into mb from memberships where org_id = c and user_id = both_id;

  insert into students(tutor_id, org_id, name, level, contact, recipient_name) values
    (owner_id, c, 'Aiden Tan', 'P5', '+65 8000 0001', 'Mrs Tan'), (owner_id, c, 'Mei Ling Koh', 'P6', '+65 8000 0002', 'Mr Koh'),
    (owner_id, c, 'Ravi Menon', 'Sec 1', '+65 8000 0003', 'Mrs Menon'), (owner_id, c, 'Sophie Lim', 'Sec 2', '+65 8000 0004', 'Mr Lim'),
    (owner_id, c, 'Daniel Ong', 'P4', '+65 8000 0005', 'Mrs Ong'), (owner_id, c, 'Priya Nair', 'Sec 3', '+65 8000 0006', 'Mr Nair'),
    (owner_id, c, 'Ethan Goh', 'P5', '+65 8000 0007', 'Mrs Goh'), (owner_id, c, 'Hannah Wee', 'Sec 1', '+65 8000 0008', 'Mr Wee');

  -- lessons: who teaches what, relative to today (so the demo is always "current")
  create temp table seed_l(sname text, who text, off int, st time, et time, subj text) on commit drop;
  insert into seed_l values
    ('Aiden Tan','t1',0,'15:00','16:00','Math'), ('Mei Ling Koh','t1',0,'16:00','17:00','Math'), ('Ravi Menon','t1',0,'17:00','18:00','Science'),
    ('Aiden Tan','t1',-1,'15:00','16:00','Math'), ('Mei Ling Koh','t1',-3,'16:00','17:00','Math'), ('Ravi Menon','t1',-5,'17:00','18:00','Science'),
    ('Sophie Lim','t1',-2,'15:00','16:00','English'), ('Sophie Lim','t1',-20,'15:00','16:00','English'),
    ('Aiden Tan','t1',2,'15:00','16:00','Math'), ('Mei Ling Koh','t1',3,'16:00','17:00','Math'), ('Ravi Menon','t1',5,'17:00','18:00','Science'),
    ('Daniel Ong','t2',0,'15:00','16:30','Math'), ('Priya Nair','t2',0,'17:00','18:00','Math'), ('Ethan Goh','t2',1,'15:00','16:00','Science'), ('Hannah Wee','t2',-1,'16:00','17:00','English'),
    ('Hannah Wee','tb',0,'18:00','19:00','English'), ('Ethan Goh','tb',2,'18:00','19:00','Science');
  insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, subject, rate, amount, status, taught_by)
    select owner_id, c, s.id, today + l.off, l.st, l.et, l.subj, 60, round(60 * extract(epoch from (l.et - l.st)) / 3600, 2), 'scheduled',
           case l.who when 't1' then m1 when 't2' then m2 else mb end
    from seed_l l join students s on s.org_id = c and s.name = l.sname;
  -- a few already marked, so every badge is on show
  perform set_config('request.jwt.claims', json_build_object('sub', tutor1_id, 'role', 'authenticated')::text, false);
  update lessons set attendance = 'attended', remarks = 'Fractions revision done'
    where org_id = c and taught_by = m1 and ((lesson_date = today - 5) or (lesson_date = today and start_time = '16:00'));
  perform set_config('request.jwt.claims', json_build_object('sub', owner_id, 'role', 'authenticated')::text, false);
  update lessons set attendance = 'late_cancelled' where org_id = c and taught_by = m2 and lesson_date = today - 1;     -- an admin marked it; the charge is still pending
  update lessons set status = 'cancelled' where org_id = c and taught_by = m1 and lesson_date = today - 2;               -- cancelled by an admin, no attendance mark

  -- ---------------------------------------------------------------- the solo tutors
  perform set_config('request.jwt.claims', json_build_object('sub', solo_id, 'role', 'authenticated')::text, false);
  insert into students(tutor_id, name, level, contact) values
    (solo_id, 'Olivia Chen', 'P3', '+65 8000 1001'), (solo_id, 'Marcus Lee', 'P5', '+65 8000 1002'), (solo_id, 'Nur Aisyah', 'Sec 1', '+65 8000 1003'),
    (solo_id, 'Jun Wei Teo', 'Sec 3', '+65 8000 1004'), (solo_id, 'Chloe Sim', 'P6', '+65 8000 1005');
  insert into lessons(tutor_id, student_id, lesson_date, start_time, end_time, subject, rate, amount, status, paid)
    select solo_id, s.id, today - d, '16:00', '17:00', 'Math', 55, 55, 'done', (d > 6)
    from students s, generate_series(2, 9, 7) d where s.tutor_id = solo_id;
  perform set_config('request.jwt.claims', json_build_object('sub', both_id, 'role', 'authenticated')::text, false);
  insert into students(tutor_id, name, level, contact) values (both_id, 'Isaac Yeo', 'P4', '+65 8000 2001'), (both_id, 'Grace Ho', 'Sec 2', '+65 8000 2002');
  insert into lessons(tutor_id, student_id, lesson_date, start_time, end_time, subject, rate, amount, status, paid)
    select both_id, s.id, today - 3, '10:00', '11:00', 'English', 50, 50, 'done', false from students s where s.tutor_id = both_id;

  perform set_config('request.jwt.claims', '', false);
end $$;

-- =====================================================================================================
-- T3 step 1: two staff logins for the demo centre. Runs on its own and only adds what is missing, so it is safe to run again.
--   centre.staff     every permission in the catalogue (assets/js/org-settings.js)
--   centre.frontdesk manage_students only: the person who answers the phone and adds students, nothing about the timetable or money
-- =====================================================================================================
do $$
declare
  staff_id uuid := '00000000-0000-0000-0000-00000000d106';
  front_id uuid := '00000000-0000-0000-0000-00000000d107';
  c uuid;
  n int;
  found_list text;
  r record;
begin
  -- The demo centre is found by its MEMBERS, never by its name (it may have been renamed): the centre where tutor.one@ and tutor.two@
  -- are active tutors and centre.owner@ is an active owner. Exactly one must match; several = stop and ask, never guess.
  select count(*), string_agg(o.trading_name || ' (' || o.id || ')', '; ' order by o.created_at), (array_agg(o.id order by o.created_at))[1]
    into n, found_list, c
    from organisations o
    where o.kind = 'centre'
      and exists (select 1 from memberships m join auth.users u on u.id = m.user_id where m.org_id = o.id and m.role = 'owner' and m.status = 'active' and u.email = 'centre.owner@example.test')
      and exists (select 1 from memberships m join auth.users u on u.id = m.user_id where m.org_id = o.id and m.role = 'tutor' and m.status = 'active' and u.email = 'tutor.one@example.test')
      and exists (select 1 from memberships m join auth.users u on u.id = m.user_id where m.org_id = o.id and m.role = 'tutor' and m.status = 'active' and u.email = 'tutor.two@example.test');
  if n = 0 then raise exception 'MISSING demo centre: no centre has tutor.one@ and tutor.two@ as tutors and centre.owner@ as owner (run the demo seed above, db/seed_dev_demo.sql, first).'; end if;
  if n > 1 then raise exception using message = 'AMBIGUOUS: ' || n || ' centres match the demo centre (' || found_list || '). Not guessing: ask the project owner which one the demo staff logins belong to.'; end if;
  raise notice 'Demo centre used for the staff logins: % (%)', (select trading_name from organisations where id = c), c;
  for r in select * from (values (staff_id, 'centre.staff@example.test', 'Demo Centre Staff'), (front_id, 'centre.frontdesk@example.test', 'Demo Front Desk')) v(id, email, name) loop
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
    from (values ('centre.staff@example.test', 'Demo Centre Staff',
                  array['manage_timetable','manage_students','manage_tutors','issue_invoices','record_payments','view_revenue','run_tutor_pay','view_audit_log']),
                 ('centre.frontdesk@example.test', 'Demo Front Desk', array['manage_students'])) v(email, name, perms)
    join auth.users u on u.email = v.email
    where not exists (select 1 from memberships m where m.org_id = c and m.user_id = u.id);
end $$;
