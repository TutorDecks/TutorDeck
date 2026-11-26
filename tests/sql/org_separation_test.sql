-- T12a: rows can't point at another organisation's student / slot / lessons. Run by tests/sql/run.sh (throwaway Postgres only).
\set ON_ERROR_STOP on
set client_min_messages = notice;
-- reuses the t.* helpers created by org_test.sql (same throwaway database); adds one that also checks the message
create function t.fails(q text, msg text, expect text) returns void language plpgsql as $$
declare blocked boolean := false; m text;
begin
  begin execute q; exception when others then blocked := true; m := sqlerrm; end;
  if not blocked then raise exception 'FAIL: % was allowed', msg; end if;
  if m not like '%'||expect||'%' then raise exception 'FAIL: % refused with the wrong message: %', msg, m; end if;
  raise notice 'PASS blocked: % (%)', msg, m;
end $$;
grant execute on function t.fails(text,text,text) to authenticated;

-- a tutor (Tina, from the seed) who ALSO owns a centre: the exact mix the plan worries about
select org_personal('00000000-0000-0000-0000-0000000000a1') as solo \gset
set role authenticated; select t.as('00000000-0000-0000-0000-0000000000a1');
select org_create_centre('Mix Centre', t.centre_settings()) as centre \gset
reset role;
insert into students(id, tutor_id, org_id, name) values ('c0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', :'centre', 'Centre Kid');
insert into recurring_slots(id, tutor_id, org_id, student_id, weekday, start_time, end_time, subject, rate)
  values ('c0000000-0000-0000-0000-000000000051', '00000000-0000-0000-0000-0000000000a1', :'centre', 'c0000000-0000-0000-0000-000000000001', 3, '15:00', '16:00', 'Math', 50);
-- Amy Lim (solo student) is 10000000-…-0001, her slot 30000000-…-0001, her invoice BM-0001, her lesson 2026-11-03
select t.ok((select org_id = :'solo' from students where id = '10000000-0000-0000-0000-000000000001'), 'seed: Amy is in Tina''s solo organisation');

-- same organisation passes (centre rows against the centre student; solo rows against the solo student)
insert into lessons(tutor_id, org_id, student_id, slot_id, lesson_date, start_time, end_time, subject, rate, amount, status)
  values ('00000000-0000-0000-0000-0000000000a1', :'centre', 'c0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000051', '2026-11-10', '15:00', '16:00', 'Math', 50, 50, 'scheduled');
insert into lessons(tutor_id, org_id, student_id, slot_id, lesson_date, start_time, end_time, subject, rate, amount, status)
  values ('00000000-0000-0000-0000-0000000000a1', :'solo', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', '2026-11-10', '16:00', '17:30', 'Math', 60, 90, 'scheduled');
insert into exams(tutor_id, org_id, student_id, subject, exam_date) values ('00000000-0000-0000-0000-0000000000a1', :'centre', 'c0000000-0000-0000-0000-000000000001', 'Math', '2026-12-02');
insert into invoices(tutor_id, org_id, student_id, invoice_no, total, data) values ('00000000-0000-0000-0000-0000000000a1', :'centre', 'c0000000-0000-0000-0000-000000000001', 'MX-1', 50, '{"lesson_ids":[]}');
select t.ok(true, 'same-organisation lesson, slot, exam and invoice are accepted');

-- cross-organisation refused, with the plain message, for each table
select t.fails($q$insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, subject, rate, amount, status)
  values ('00000000-0000-0000-0000-0000000000a1', '$q$||:'solo'||$q$', 'c0000000-0000-0000-0000-000000000001', '2026-11-11', '10:00', '11:00', 'Math', 1, 1, 'scheduled')$q$,
  'solo lesson about a centre student', 'different organisation');
select t.fails($q$insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, subject, rate, amount, status)
  values ('00000000-0000-0000-0000-0000000000a1', '$q$||:'centre'||$q$', '10000000-0000-0000-0000-000000000001', '2026-11-11', '10:00', '11:00', 'Math', 1, 1, 'scheduled')$q$,
  'centre lesson about a solo student', 'different organisation');
select t.fails($q$insert into recurring_slots(tutor_id, org_id, student_id, weekday, start_time, end_time, subject, rate)
  values ('00000000-0000-0000-0000-0000000000a1', '$q$||:'solo'||$q$', 'c0000000-0000-0000-0000-000000000001', 1, '10:00', '11:00', 'Math', 1)$q$, 'solo slot for a centre student', 'different organisation');
select t.fails($q$insert into recurring_slots(tutor_id, org_id, student_id, weekday, start_time, end_time, subject, rate)
  values ('00000000-0000-0000-0000-0000000000a1', '$q$||:'centre'||$q$', '10000000-0000-0000-0000-000000000001', 1, '10:00', '11:00', 'Math', 1)$q$, 'centre slot for a solo student', 'different organisation');
select t.fails($q$insert into exams(tutor_id, org_id, student_id, subject, exam_date)
  values ('00000000-0000-0000-0000-0000000000a1', '$q$||:'solo'||$q$', 'c0000000-0000-0000-0000-000000000001', 'Math', '2026-12-03')$q$, 'solo exam for a centre student', 'different organisation');
select t.fails($q$insert into invoices(tutor_id, org_id, student_id, invoice_no, total)
  values ('00000000-0000-0000-0000-0000000000a1', '$q$||:'centre'||$q$', '10000000-0000-0000-0000-000000000001', 'MX-2', 1)$q$, 'centre invoice for a solo student', 'different organisation');
-- the page-style insert with NO org_id (guard fills the solo org) against a centre student
select t.fails($q$insert into lessons(tutor_id, student_id, lesson_date, start_time, end_time, subject, rate, amount, status)
  values ('00000000-0000-0000-0000-0000000000a1', 'c0000000-0000-0000-0000-000000000001', '2026-11-12', '10:00', '11:00', 'Math', 1, 1, 'scheduled')$q$,
  'Ledger-style lesson with no org_id for a centre student (the worst hidden risk in the plan)', 'different organisation');
-- the slot pointer and the invoice's lesson list
select t.fails($q$insert into lessons(tutor_id, org_id, student_id, slot_id, lesson_date, start_time, end_time, subject, rate, amount, status)
  values ('00000000-0000-0000-0000-0000000000a1', '$q$||:'solo'||$q$', '10000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000051', '2026-11-13', '10:00', '11:00', 'Math', 1, 1, 'scheduled')$q$,
  'lesson pointing at another organisation''s weekly slot', 'different organisation');
select l.id::text as clid from lessons l where l.org_id = :'centre' limit 1 \gset
select t.fails($q$insert into invoices(tutor_id, org_id, student_id, invoice_no, total, data)
  values ('00000000-0000-0000-0000-0000000000a1', '$q$||:'solo'||$q$', '10000000-0000-0000-0000-000000000001', 'BM-9', 1, '{"lesson_ids":["$q$||:'clid'||$q$"]}')$q$,
  'solo invoice listing a centre lesson', 'different organisation');
insert into invoices(tutor_id, org_id, student_id, invoice_no, total, data)
  values ('00000000-0000-0000-0000-0000000000a1', :'solo', '10000000-0000-0000-0000-000000000001', 'BM-8', 1, '{"lesson_ids":["99999999-9999-9999-9999-999999999999","not-a-uuid"]}');
select t.ok(true, 'unknown / deleted lesson ids on an invoice are ignored, as the pages already do');
-- updates can't re-point either
select t.fails($q$update lessons set student_id = 'c0000000-0000-0000-0000-000000000001' where org_id = '$q$||:'solo'||$q$' and lesson_date = '2026-11-10'$q$, 'moving a solo lesson onto a centre student', 'different organisation');
select t.fails($q$update invoices set data = '{"lesson_ids":["$q$||:'clid'||$q$"]}' where invoice_no = 'BM-0001'$q$, 'editing a solo invoice to list a centre lesson', 'different organisation');

-- solo flows untouched: normal updates (mark paid, change amount) still pass, as signed-in Tina
set role authenticated; select t.as('00000000-0000-0000-0000-0000000000a1');
update invoices set status = 'paid', paid_date = current_date where invoice_no = 'BM-0001';
update lessons set amount = amount where org_id = :'solo';
insert into lessons(tutor_id, student_id, lesson_date, start_time, end_time, subject, rate, amount, status)
  values ('00000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-000000000002', '2026-11-14', '10:00', '11:00', 'Math', 55, 55, 'scheduled');
reset role;
select t.ok(true, 'signed-in solo tutor: page-style insert (no org_id), mark paid, update all still work');
select t.ok((select count(*) = 0 from lessons l join students s on s.id = l.student_id where s.org_id is distinct from l.org_id), 'no lesson anywhere points at another organisation''s student');
\echo ORG SEPARATION TESTS PASSED
