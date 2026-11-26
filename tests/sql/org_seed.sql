-- Made-up legacy data, inserted BEFORE the migration (as today's live DB would have it). Fictional people.
insert into auth.users(id, email, created_at) values
  ('00000000-0000-0000-0000-0000000000a1', 'tina@solo.test',   now() - interval '200 days'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@solo.test',    now() - interval '100 days');
insert into public.profiles(id, full_name, business_name, invoice_prefix, paynow_type, paynow_id) values
  ('00000000-0000-0000-0000-0000000000a1', 'Tina Tan', 'Bright Maths', 'BM', 'mobile', '91234567'),
  ('00000000-0000-0000-0000-0000000000b1', 'Ben Ong', null, null, null, null)
  on conflict (id) do update set full_name = excluded.full_name, business_name = excluded.business_name,
     invoice_prefix = excluded.invoice_prefix, paynow_type = excluded.paynow_type, paynow_id = excluded.paynow_id;
-- Tina: two siblings sharing a phone written two ways, one student with no phone
insert into public.students(id, tutor_id, name, level, contact, recipient_name, created_at) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', 'Amy Lim',  'P6',    '+65 9876 5432', 'Mrs Lim', now() - interval '90 days'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000a1', 'Alan Lim', 'Sec 1', '98765432',      null,      now() - interval '80 days'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'Zoe',      'JC1',   null,            null,      now() - interval '70 days'),
  ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000b1', 'Bob Koh',  'P5',    '81112222',      'Mr Koh',  now() - interval '50 days');
insert into public.recurring_slots(id, tutor_id, student_id, weekday, start_time, end_time, subject, rate) values
  ('30000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-000000000001', 1, '16:00', '17:30', 'Math', 60.50),
  ('30000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000b1', '20000000-0000-0000-0000-000000000001', 2, '17:00', '18:00', 'Math', 50);
insert into public.lessons(tutor_id, student_id, slot_id, lesson_date, start_time, end_time, subject, rate, amount, status, compensation) values
  ('00000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', '2026-11-03', '16:00', '17:30', 'Math', 60.50, 90.75, 'done', null),
  ('00000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-000000000002', null, '2026-11-04', '16:00', '17:00', 'Math', 55, 55, 'cancelled', 27.50),
  ('00000000-0000-0000-0000-0000000000b1', '20000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', '2026-11-05', '17:00', '18:00', 'Math', 50, 50, 'done', null);
insert into public.exams(tutor_id, student_id, subject, exam_date) values
  ('00000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-000000000001', 'Math', '2026-12-01');
insert into public.invoices(tutor_id, student_id, invoice_no, total, data) values
  ('00000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-000000000001', 'BM-0001', 146.25, '{"html":"<p>big</p>","lesson_ids":[]}');
insert into public.materials(owner_id, subject, level, topic, title, file_path) values
  ('00000000-0000-0000-0000-0000000000a1', 'Math', 'P6', 'Fractions', 'Worksheet 1', 'a1/w1.pdf');
