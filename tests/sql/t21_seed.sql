-- DEV-ONLY clean-up rehearsal data (T21). Runs on a THROWAWAY local Postgres after all six migrations (see t21_cleanup_test.sh).
-- Same SHAPE as the real throwaway: one login created 2026-11-24 11:28 UTC owning a solo org + a centre "T2 Test Centre", plus the 5 demo logins
-- (with a centre and a solo tutor with data) and decoys that must NEVER be touched. Everyone here is made up.
\set ON_ERROR_STOP on
\set cs '{"schema_version":1,"preset":"centre","profile":{"gst_registered":true,"gst_rate_bp":900,"gst_inclusive":false,"invoice_prefix":"OPUS","next_invoice_number":1},"calendar":{},"billing":{"model":"prepaid_packages"},"invoicing":{"grouping":"family"},"payments":{"modes":["manual_paynow"]},"lessons":{},"tutor_pay":{"mode":"report","payable_when":"parent_paid"},"data":{}}'
insert into auth.users(id, email, created_at) values
  ('00000000-0000-0000-0000-0000000d0001', 'centre.owner@example.test', '2026-11-01 02:00+00'),
  ('00000000-0000-0000-0000-0000000d0002', 'tutor.one@example.test',    '2026-11-01 02:00+00'),
  ('00000000-0000-0000-0000-0000000d0003', 'tutor.two@example.test',    '2026-11-01 02:00+00'),
  ('00000000-0000-0000-0000-0000000d0004', 'both.tutor@example.test',   '2026-11-01 02:00+00'),
  ('00000000-0000-0000-0000-0000000d0005', 'solo.tutor@example.test',   '2026-11-01 02:00+00'),
  -- decoys: same prefix but another day / another domain / no prefix
  ('00000000-0000-0000-0000-0000000e0001', 't2-throwaway-old@example.test',   '2026-11-20 09:00+00'),
  ('00000000-0000-0000-0000-0000000e0002', 't2-throwaway-next@example.test',  '2026-11-25 01:00+00'),
  ('00000000-0000-0000-0000-0000000e0003', 't2-throwaway-x@example.com',      '2026-11-24 11:30+00'),
  ('00000000-0000-0000-0000-0000000e0004', 'my-t2-throwaway-y@example.test',  '2026-11-24 11:31+00'),
  -- THE throwaway
  ('00000000-0000-0000-0000-0000000a0001', 't2-throwaway-8f3c1d@example.test', '2026-11-24 11:28:03+00');

-- demo data that must survive untouched
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000d0001"}', false);
select org_create_centre('Demo Learning Centre', :'cs'::jsonb) as demo_centre \gset
select set_config('request.jwt.claims', '', false);
insert into students(tutor_id, org_id, name, level, contact, recipient_name) values
  ('00000000-0000-0000-0000-0000000d0001', :'demo_centre', 'Demo Kid', 'P5', '+65 8000 1111', 'Demo Parent');
insert into students(tutor_id, name, level, contact) values ('00000000-0000-0000-0000-0000000d0005', 'Solo Kid', 'Sec 2', '+65 8000 2222');
insert into students(tutor_id, name, level, contact) values ('00000000-0000-0000-0000-0000000e0001', 'Old Decoy Kid', 'P1', '+65 8000 3333');
insert into lessons(tutor_id, student_id, lesson_date, start_time, end_time, subject, rate, amount, status)
  select tutor_id, id, '2026-11-02', '10:00', '11:00', 'Math', 50, 50, 'done' from students where name in ('Solo Kid', 'Old Decoy Kid');
insert into platform_fee_snapshots(org_id, month, active_students, billable_students, base_cents, per_student_cents, fee_cents)
  values (:'demo_centre', '2026-10-01', 1, 1, 10000, 40, 10040);

-- the throwaway: solo org (auto-created) with data
update profiles set business_name = 'T2 Throwaway', full_name = 'T2 Thrower', paynow_id = '90000000' where id = '00000000-0000-0000-0000-0000000a0001';
insert into students(tutor_id, name, level, contact, recipient_name) values ('00000000-0000-0000-0000-0000000a0001', 'Tee Two', 'P6', '+65 8999 0001', 'Mrs Two');
insert into students(tutor_id, name, level, contact) values ('00000000-0000-0000-0000-0000000a0001', 'Tee Three', 'Sec 1', '+65 8999 0002');
insert into recurring_slots(tutor_id, student_id, weekday, start_time, end_time, subject, rate)
  select tutor_id, id, 3, '16:00', '17:00', 'Math', 55 from students where name = 'Tee Two';
insert into lessons(tutor_id, student_id, slot_id, lesson_date, start_time, end_time, subject, rate, amount, status)
  select s.tutor_id, s.id, r.id, '2026-11-25', '16:00', '17:00', 'Math', 55, 55, 'done' from students s join recurring_slots r on r.student_id = s.id where s.name = 'Tee Two';
insert into exams(tutor_id, student_id, subject, exam_date) select tutor_id, id, 'Math', '2026-12-01' from students where name = 'Tee Two';
insert into invoices(tutor_id, student_id, invoice_no, total, data) select tutor_id, id, 'T2-0001', 55, '{"html":"<p>x</p>","lesson_ids":[],"recipient":"Mrs Two"}' from students where name = 'Tee Two';
insert into materials(owner_id, subject, level, topic, title, file_path) values ('00000000-0000-0000-0000-0000000a0001', 'Math', 'P6', 'Fractions', 'T2 sheet', 'none-uploaded.pdf');
insert into client_errors(tutor_id, kind, message) values ('00000000-0000-0000-0000-0000000a0001', 'js', 'boom');
insert into platform_fee_snapshots(org_id, month, active_students, billable_students, base_cents, per_student_cents, fee_cents)
  select org_personal('00000000-0000-0000-0000-0000000a0001'), '2026-11-01', 2, 2, 0, 0, 0;

-- the throwaway's centre, created through the app's own function (so it looks exactly like the real thing), then filled
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000a0001"}', false);
select org_create_centre('T2 Test Centre', :'cs'::jsonb) as t2_centre \gset
select set_config('request.jwt.claims', '', false);
update organisations set created_at = '2026-11-24 11:28:50+00' where id = :'t2_centre';
update organisations set created_at = '2026-11-24 11:28:12+00' where id = org_personal('00000000-0000-0000-0000-0000000a0001');
insert into branches(org_id, name, address) values (:'t2_centre', 'Main', '1 Test Road');
insert into rooms(org_id, branch_id, name) select :'t2_centre', id, 'Room 1' from branches where org_id = :'t2_centre';
insert into terms(org_id, name, starts_on, ends_on) values (:'t2_centre', 'Term 4', '2026-10-01', '2026-12-01');
insert into holidays(org_id, name, starts_on, ends_on) values (:'t2_centre', 'Break', '2026-12-01', '2026-12-05');
insert into students(tutor_id, org_id, name, level, contact, recipient_name) values
  ('00000000-0000-0000-0000-0000000a0001', :'t2_centre', 'Centre Kid', 'P4', '+65 8999 0003', 'Mr Centre');
insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, subject, rate, amount, status, taught_by)
  select s.tutor_id, s.org_id, s.id, '2026-11-26', '10:00', '11:00', 'Math', 60, 60, 'done', (select id from memberships where org_id = :'t2_centre') from students s where s.name = 'Centre Kid';
insert into support_access_grants(org_id, granted_by, reason, expires_at) values (:'t2_centre', '00000000-0000-0000-0000-0000000a0001', 'help', now() + interval '1 day');
insert into org_settings(org_id, version, schema_version, effective_from, settings, created_by)
  select org_id, 2, schema_version, current_date + 1, settings, created_by from org_settings where org_id = :'t2_centre' and version = 1;
insert into platform_fee_snapshots(org_id, month, active_students, billable_students, base_cents, per_student_cents, fee_cents) values (:'t2_centre', '2026-11-01', 1, 1, 10000, 40, 10040);

-- the decoy older throwaway has its own centre too (same name!) and must survive
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000e0001"}', false);
select org_create_centre('T2 Test Centre', :'cs'::jsonb);
select set_config('request.jwt.claims', '', false);
