-- Slice C1 tests: centre tutors see and mark ONLY their own lessons, through two functions, and can't reach money.
-- Runs after attendance_test.sql in the same throwaway database (reuses t.*, the 'centre' organisation owned by c1, and Tina's
-- solo organisation). Made-up people only.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

-- ===================================================================== people
-- T1, T2 = tutors of the centre; T3 = a tutor whose membership is switched off; STAFF = staff with the timetable permission
-- INV = an invited tutor who hasn't signed up (no login yet). TINA (a1) = a solo tutor who ALSO becomes a tutor in the centre.
insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-000000007001', 'tutor1@centre.test'), ('00000000-0000-0000-0000-000000007002', 'tutor2@centre.test'),
  ('00000000-0000-0000-0000-000000007003', 'tutor3@centre.test'), ('00000000-0000-0000-0000-000000007004', 'staff@centre.test');
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('centre'), '00000000-0000-0000-0000-000000007001', 'Tutor One',   'tutor', '{}', 'active'),
  (t.id('centre'), '00000000-0000-0000-0000-000000007002', 'Tutor Two',   'tutor', '{}', 'active'),
  (t.id('centre'), '00000000-0000-0000-0000-000000007003', 'Tutor Three', 'tutor', '{}', 'disabled'),
  (t.id('centre'), '00000000-0000-0000-0000-000000007004', 'Staff',       'staff', array['manage_timetable'], 'active'),
  (t.id('centre'), '00000000-0000-0000-0000-0000000000a1', 'Tina (also a solo tutor)', 'tutor', '{}', 'active');
insert into memberships(org_id, invited_email, display_name, role, status) values (t.id('centre'), 'invited@centre.test', 'Invited Tutor', 'tutor', 'invited');
select t.put('m1', (select id from memberships where user_id = '00000000-0000-0000-0000-000000007001' and org_id = t.id('centre')));
select t.put('m2', (select id from memberships where user_id = '00000000-0000-0000-0000-000000007002' and org_id = t.id('centre')));
select t.put('m3', (select id from memberships where user_id = '00000000-0000-0000-0000-000000007003' and org_id = t.id('centre')));
select t.put('minv', (select id from memberships where invited_email = 'invited@centre.test' and org_id = t.id('centre')));
select t.put('mtina', (select id from memberships where user_id = '00000000-0000-0000-0000-0000000000a1' and org_id = t.id('centre')));

-- the centre's calendar day (NOT the server's UTC day): lessons are dated relative to it
create temp table td as select (now() at time zone 'Asia/Singapore')::date as today;
grant select on td to authenticated, service_role, anon;
create temp table stu (k text primary key, id uuid);
insert into stu select 's' || g, gen_random_uuid() from generate_series(1, 4) g;
grant select on stu to authenticated;
insert into students(id, tutor_id, org_id, name, level, contact)
  select id, '00000000-0000-0000-0000-0000000000c1', t.id('centre'), 'Pupil ' || k, 'P' || right(k, 1), '9123400' || right(k, 1) from stu;
create function pg_temp.mk(p_k text, p_off int, p_by uuid, p_status text default 'scheduled') returns uuid language sql as $$
  insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, taught_by, subject)
  select '00000000-0000-0000-0000-0000000000c1', t.id('centre'), stu.id, (select today from td) + p_off, '16:00', '17:00', 55, 123.45, p_status, p_by, 'Math'
  from stu where stu.k = p_k returning id $$;
-- L1/L2 are T1's today; LT2 is T2's today; LF future; LOLD old; LCAN cancelled; LDIS belongs to the disabled tutor; LINV to the invited one
select t.put('L1',   pg_temp.mk('s1', 0, t.id('m1')));
select t.put('L2',   pg_temp.mk('s2', 0, t.id('m1')));
select t.put('LT2',  pg_temp.mk('s3', 0, t.id('m2')));
select t.put('LF',   pg_temp.mk('s1', 1, t.id('m1')));
select t.put('LOLD', pg_temp.mk('s1', -20, t.id('m1')));
select t.put('LCAN', pg_temp.mk('s4', 0, t.id('m1'), 'cancelled'));
select t.put('LDIS', pg_temp.mk('s4', 0, null));          -- (assigned below: the guard must refuse a disabled tutor)
select t.put('LINV', pg_temp.mk('s4', 0, t.id('minv')));  -- an invited tutor can be scheduled before they sign up
select t.put('LTINA', pg_temp.mk('s2', 0, t.id('mtina')));

-- ===================================================================== no table access for a tutor
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
select t.eq((select count(*) from lessons), 0, 'tutor sees no rows in lessons (money columns live there)');
select t.eq((select count(*) from students), 0, 'tutor sees no rows in students');
select t.eq((select count(*) from invoices), 0, 'tutor sees no invoices');
select t.eq((select count(*) from households), 0, 'tutor sees no households (parents'' names and phones)');
select t.eq((select count(*) from guardians), 0, 'tutor sees no guardians');
select t.eq((select count(*) from org_settings where org_id = t.id('centre')), 0, 'tutor can''t read the centre''s settings directly');
select t.fails($q$ insert into lessons(tutor_id, student_id, lesson_date, start_time, end_time, rate, org_id) select '00000000-0000-0000-0000-000000007001', id, current_date, '10:00', '11:00', 1, t.id('centre') from stu limit 1 $q$, 'tutor adding a lesson');
select t.eq(t.rows($q$ update lessons set amount = 0, attendance = 'attended' where id = t.id('L1') $q$), 0, 'tutor updating a lesson directly (no row is even visible)');
select t.eq(t.rows($q$ delete from lessons where id = t.id('L1') $q$), 0, 'tutor deleting a lesson directly');
reset role;

-- ===================================================================== what tutor_my_lessons returns
select t.ok(not exists (select 1 from pg_proc p, unnest(p.proargnames, p.proallargtypes, p.proargmodes) as a(n, ty, m)
                        where p.oid = 'public.tutor_my_lessons(date,date)'::regprocedure and a.m = 't'
                          and (format_type(a.ty, null) in ('numeric', 'real', 'double precision', 'money', 'integer', 'bigint', 'smallint')
                               or a.n in ('rate', 'amount', 'paid', 'compensation', 'charge_note', 'total', 'invoice_id') or a.n ~ '_cents$')),
            'the read function returns no number, money, price or paid column of any kind (checked by type and exact name from the catalog, so a later edit can''t quietly add one; true/false flags like charge_pending are fine)');
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
select t.eq((select count(*) from tutor_my_lessons((select today - 30 from td), (select today + 5 from td))), 5, 'T1 sees exactly their own 5 lessons (not T2''s, not others'')');
select t.eq((select count(*) from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('LT2')), 0, 'T1 can''t see T2''s lesson');
select t.ok((select bool_and(parent_contact is null) from tutor_my_lessons((select today - 30 from td), (select today + 5 from td))), 'parent contact hidden by default (setting missing = off)');
select t.ok((select student_name = 'Pupil s1' and student_level = 'P1' from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('L1')), 'student name and level are shown');
select t.ok((select can_mark and can_note from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('L2')), 'today''s lesson: can mark and can write notes');
select t.ok((select not can_mark and not can_note from tutor_my_lessons((select today + 1 from td), (select today + 1 from td)) where lesson_id = t.id('LF')), 'tomorrow''s lesson: neither yet');
select t.ok((select not can_mark and not can_note from tutor_my_lessons((select today - 20 from td), (select today - 20 from td)) where lesson_id = t.id('LOLD')), 'a 20-day-old lesson: neither (an admin must change it)');
select t.ok((select not can_mark and not can_note from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('LCAN')), 'a cancelled lesson: neither');
select t.fails($q$ select * from tutor_my_lessons(current_date - 100, current_date) $q$, 'asking for more than 62 days');
select t.fails($q$ select * from tutor_my_lessons(current_date, current_date - 1) $q$, 'a backwards date range');
reset role;
select t.as('00000000-0000-0000-0000-000000007002'); set role authenticated;
select t.eq((select count(*) from tutor_my_lessons((select today - 30 from td), (select today + 5 from td))), 1, 'T2 sees only theirs');
reset role;
select t.as('00000000-0000-0000-0000-000000007003'); set role authenticated;
select t.eq((select count(*) from tutor_my_lessons((select today - 30 from td), (select today + 5 from td))), 0, 'a disabled membership sees nothing');
reset role;
select t.as('00000000-0000-0000-0000-000000007004'); set role authenticated;
select t.eq((select count(*) from tutor_my_lessons((select today - 30 from td), (select today + 5 from td))), 0, 'staff with no lessons of their own get none from the tutor function');
reset role;
select t.as('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
select t.eq((select count(*) from tutor_my_lessons((select today - 30 from td), (select today + 5 from td))), 0, 'a tutor from another organisation sees nothing');
reset role;
-- the unclaimed invitation: nobody can read LINV through the function (no login is attached to that membership)
select t.eq((select count(*) from lessons where taught_by = t.id('minv')), 1, 'the invited tutor was scheduled before signing up');
select t.fails($q$ update lessons set taught_by = t.id('m3') where id = t.id('LDIS') $q$, 'scheduling a lesson with a disabled tutor');

-- ===================================================================== marking attendance: the happy path
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
select tutor_mark_attendance(t.id('L1'), 'attended', 'Fractions', 'Worksheet 3', 'Good progress');
reset role;
select t.ok((select attendance = 'attended' and attendance_marked_by = '00000000-0000-0000-0000-000000007001' and attendance_marked_at is not null
             and topics = 'Fractions' and homework = 'Worksheet 3' and remarks = 'Good progress' and remarks_at is not null from lessons where id = t.id('L1')),
            'attendance, notes, who and when are all recorded');
select t.ok((select status = 'done' and amount = 123.45 and rate = 55 and lesson_date = (select today from td) from lessons where id = t.id('L1')),
            'marking attended makes the lesson done (system-driven); amount, rate and date are untouched');
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
select tutor_mark_attendance(t.id('L1'), 'absent');
reset role;
select t.ok((select attendance = 'absent' and remarks = 'Good progress' and status = 'cancelled' and compensation is null from lessons where id = t.id('L1')), 'the same tutor can change their own mark; notes left as they were; absent = cancelled with the charge still pending');
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
select tutor_mark_attendance(t.id('L1'), null, '', null, null);
reset role;
select t.ok((select topics is null and attendance = 'absent' from lessons where id = t.id('L1')), 'empty text clears a note');

-- ===================================================================== refusals
select t.as('00000000-0000-0000-0000-000000007002'); set role authenticated;
select t.fails($q$ select tutor_mark_attendance(t.id('L2'), 'attended') $q$, 'another tutor in the same centre marking T1''s lesson');
reset role;
select t.as('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
select t.fails($q$ select tutor_mark_attendance(t.id('L2'), 'attended') $q$, 'a tutor from another organisation');
reset role;
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
do $$ declare a text; b text; begin
  begin perform tutor_mark_attendance(t.id('LT2'), 'attended'); exception when others then a := sqlerrm; end;
  begin perform tutor_mark_attendance('00000000-0000-0000-0000-00000000dead', 'attended'); exception when others then b := sqlerrm; end;
  if a is distinct from b or a is null then raise exception 'FAIL: "not yours" (%) and "doesn''t exist" (%) must be the same error', a, b; end if;
  raise notice 'PASS "not yours" and "does not exist" give the same answer (%)', a;
end $$;
select t.fails($q$ select tutor_mark_attendance(t.id('LF'), 'attended') $q$, 'marking a future lesson');
select t.fails($q$ select tutor_mark_attendance(t.id('LOLD'), 'attended') $q$, 'marking a lesson from 20 days ago');
select t.fails($q$ select tutor_mark_attendance(t.id('LCAN'), 'attended') $q$, 'marking a cancelled lesson');
select t.fails($q$ select tutor_mark_attendance(t.id('L2'), 'cancelled_early') $q$, 'a tutor setting a cancellation value');
select t.fails($q$ select tutor_mark_attendance(t.id('L2'), 'late_cancelled') $q$, 'a tutor setting late_cancelled');
select t.fails($q$ select tutor_mark_attendance(t.id('L2'), 'maybe') $q$, 'a made-up attendance value');
select t.fails($q$ select tutor_mark_attendance(t.id('L2'), 'attended', repeat('x', 2001)) $q$, 'a 2001-character topic');
reset role;
select t.eq((select count(*) from lessons where attendance is not null and id in (t.id('L1'), t.id('L2'), t.id('LT2'), t.id('LF'), t.id('LOLD'), t.id('LCAN'), t.id('LINV'), t.id('LDIS'))), 1, 'none of the refused calls changed anything (only L1 is marked)');
select t.ok((select not trial from lessons where id = t.id('L1')), 'none of the refused calls changed the trial flag');

-- the disabled tutor and the unclaimed invitation can't mark
insert into auth.users(id, email) values ('00000000-0000-0000-0000-000000007005', 'tutor5@centre.test');
insert into memberships(org_id, user_id, display_name, role, status) values (t.id('centre'), '00000000-0000-0000-0000-000000007005', 'Tutor Five', 'tutor', 'active');
select t.put('m5', (select id from memberships where user_id = '00000000-0000-0000-0000-000000007005' and org_id = t.id('centre')));
select t.put('L5', pg_temp.mk('s3', 0, t.id('m5')));
select t.as('00000000-0000-0000-0000-000000007005'); set role authenticated;
select t.eq((select count(*) from tutor_my_lessons((select today from td), (select today from td))), 1, 'an active tutor sees the lesson they were given');
reset role;
update memberships set status = 'disabled' where id = t.id('m5');                -- the centre switches them off AFTER giving them a lesson
select t.as('00000000-0000-0000-0000-000000007005'); set role authenticated;
select t.fails($q$ select tutor_mark_attendance(t.id('L5'), 'attended') $q$, 'a tutor switched off after being given a lesson can no longer mark it');
select t.eq((select count(*) from tutor_my_lessons((select today from td), (select today from td))), 0, 'and no longer sees it');
reset role;

-- someone else's mark can't be overwritten by the tutor; staff can mark anything and are stamped
select t.as('00000000-0000-0000-0000-000000007004'); set role authenticated;
update lessons set attendance = 'late_cancelled' where id = t.id('L2');
reset role;
select t.ok((select attendance = 'late_cancelled' and attendance_marked_by = '00000000-0000-0000-0000-000000007004' from lessons where id = t.id('L2')), 'staff mark a cancellation and are stamped as the one who did');
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
select t.fails($q$ select tutor_mark_attendance(t.id('L2'), 'attended') $q$, 'a tutor overwriting a mark staff made');
select tutor_mark_attendance(t.id('L2'), null, null, null, 'Parent called to cancel late');
reset role;
select t.ok((select remarks = 'Parent called to cancel late' and attendance = 'late_cancelled' from lessons where id = t.id('L2')), 'but they can still add remarks to it');

-- ===================================================================== reassigning (replacement tutors) and the settings
select t.as('00000000-0000-0000-0000-000000007004'); set role authenticated;
update lessons set taught_by = t.id('m2') where id = t.id('L1');          -- replacement tutor (setting missing = on)
reset role;
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
select t.fails($q$ select tutor_mark_attendance(t.id('L1'), 'attended') $q$, 'the previous tutor after the lesson was reassigned away');
reset role;
select t.as('00000000-0000-0000-0000-000000007002'); set role authenticated;
select t.eq((select count(*) from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('L1')), 1, 'the replacement tutor now sees it');
reset role;
select t.fails($q$ update lessons set taught_by = (select id from memberships where org_id = t.id('tina_org') limit 1) where id = t.id('L2') $q$, 'putting a member of ANOTHER organisation on a lesson');

-- switch settings: attendance by admin, replacement off, parent contact visible
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select org_save_settings(t.id('centre'),
  jsonb_set(jsonb_set(jsonb_set(t.centre_settings(), '{lessons,attendance_by}', '"admin"'), '{lessons,replacement_tutors}', 'false'), '{lessons,tutors_see_parent_contact}', 'true'),
  current_date);
reset role;
select t.as('00000000-0000-0000-0000-000000007002'); set role authenticated;
select t.fails($q$ select tutor_mark_attendance(t.id('LT2'), 'attended') $q$, 'attendance_by = admin: the tutor can''t set attendance');
select tutor_mark_attendance(t.id('LT2'), null, null, null, 'Remarks are still allowed');
select t.ok((select parent_contact = '91234003' from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('LT2')), 'tutors_see_parent_contact = true: the number is shown');
select t.ok((select can_mark = false from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('LT2')), 'and the screen is told it can''t mark attendance');
select t.ok((select can_note from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('LT2')), 'but is told it CAN still write notes (attendance_by = admin only blocks attendance)');
reset role;
select t.ok((select attendance is null and remarks = 'Remarks are still allowed' and remarks_at is not null from lessons where id = t.id('LT2')), 'remarks saved, attendance untouched');
select t.as('00000000-0000-0000-0000-000000007004'); set role authenticated;
select t.fails($q$ update lessons set taught_by = t.id('m1') where id = t.id('LT2') $q$, 'replacement off: moving a lesson from one tutor to another');
update lessons set attendance = 'attended' where id = t.id('LT2');           -- staff can still mark
reset role;
select t.ok((select attendance = 'attended' from lessons where id = t.id('LT2')), 'staff can still mark attendance when it is set to admin');
-- a lesson with no tutor yet can still be assigned (not a replacement)
select t.as('00000000-0000-0000-0000-000000007004'); set role authenticated;
update lessons set taught_by = t.id('m1') where id = t.id('LDIS');
reset role;
select t.ok((select taught_by = t.id('m1') from lessons where id = t.id('LDIS')), 'replacement off: first-time assignment is still allowed');

-- ===================================================================== a solo tutor who is ALSO a centre tutor
select t.as('00000000-0000-0000-0000-0000000000a1'); set role authenticated;
select t.ok((select count(*) from lessons where org_id = t.id('tina_org')) >= 1, 'Tina still reads her own solo lessons exactly as before');
select t.eq((select count(*) from lessons where org_id = t.id('centre')), 0, 'but gets no table access to the centre''s lessons');
select t.eq((select count(*) from tutor_my_lessons((select today - 5 from td), (select today + 5 from td))), 1, 'tutor_my_lessons returns only her centre lesson, never her solo lessons');
select tutor_mark_attendance(t.id('LTINA'), null, null, null, 'Tina''s centre note');
reset role;
-- ... and solo lesson updates are not stamped by the attendance trigger
update lessons set remarks = 'solo note' where org_id = t.id('tina_org') and id = (select id from lessons where org_id = t.id('tina_org') limit 1);
select t.ok((select bool_and(attendance_marked_at is null) from lessons where org_id = t.id('tina_org')), 'solo lessons are untouched by the attendance stamps');
select t.fails($q$ select tutor_mark_attendance((select id from lessons where org_id = t.id('tina_org') limit 1), 'attended') $q$, 'the tutor function refuses a solo lesson');

-- ===================================================================== removing a tutor keeps the lesson
delete from memberships where id = t.id('m2');
select t.ok((select taught_by is null and org_id = t.id('centre') from lessons where id = t.id('LT2')), 'removing a tutor clears taught_by but the lesson stays in its organisation');

-- ===================================================================== "today" is the CENTRE's day, not the server's
-- At any moment at least one of UTC+14 and UTC-12 has a different calendar date from UTC, so a function that used the
-- server's date instead of the centre's timezone fails one of these two rounds.
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{lessons,attendance_by}', '"tutor"'), current_date);   -- tutors mark again
reset role;
insert into auth.users(id, email) values ('00000000-0000-0000-0000-000000007006', 'tutor6@centre.test');
insert into memberships(org_id, user_id, display_name, role, status) values (t.id('centre'), '00000000-0000-0000-0000-000000007006', 'Tutor Six', 'tutor', 'active');
select t.put('m6', (select id from memberships where user_id = '00000000-0000-0000-0000-000000007006' and org_id = t.id('centre')));
do $$
declare tz text; local_today date; ok_l uuid; early_l uuid; late_l uuid; refused boolean;
begin
  foreach tz in array array['Pacific/Kiritimati', 'Etc/GMT+12'] loop       -- UTC+14 and UTC-12
    update organisations set timezone = tz where id = t.id('centre');
    local_today := (now() at time zone tz)::date;
    insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, taught_by)
      select '00000000-0000-0000-0000-0000000000c1', t.id('centre'), (select id from stu where k = 's1'), d, '10:00', '11:00', 50, t.id('m6')
      from unnest(array[local_today, local_today + 1, local_today - 15]) d;
    select id into ok_l    from lessons where taught_by = t.id('m6') and lesson_date = local_today     order by created_at desc limit 1;
    select id into early_l from lessons where taught_by = t.id('m6') and lesson_date = local_today + 1 order by created_at desc limit 1;
    select id into late_l  from lessons where taught_by = t.id('m6') and lesson_date = local_today - 15 order by created_at desc limit 1;
    perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007006","role":"authenticated"}', false);
    execute 'set local role authenticated';
    perform tutor_mark_attendance(ok_l, 'attended');                                  -- the centre's own today: allowed
    refused := false; begin perform tutor_mark_attendance(early_l, 'attended'); exception when others then refused := true; end;
    if not refused then raise exception 'FAIL: % local tomorrow was markable', tz; end if;
    refused := false; begin perform tutor_mark_attendance(late_l, 'attended'); exception when others then refused := true; end;
    if not refused then raise exception 'FAIL: % lesson 15 local days ago was markable (limit is 14)', tz; end if;
    execute 'reset role';
    raise notice 'PASS timezone % (server date %, centre date %): own today markable, tomorrow and 15 days ago refused', tz, current_date, local_today;
  end loop;
end $$;
update organisations set timezone = 'Asia/Singapore' where id = t.id('centre');

-- ===================================================================== the CENTRE's own rules (chosen at sign-up, changed later)
-- Each rule below is a setting of the centre, not something built into TutorDeck. The owner (c1) saves settings; the tutor functions read them as of today.
-- (a) bad values are refused when saving
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select t.fails($q$ select org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{lessons}', '{"attendance_window_days": 0}'), current_date) $q$, 'an attendance window of 0 days');
select t.fails($q$ select org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{lessons}', '{"attendance_window_days": 61}'), current_date) $q$, 'an attendance window of 61 days');
select t.fails($q$ select org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{lessons}', '{"attendance_window_days": "lots"}'), current_date) $q$, 'a non-numeric attendance window');
select t.fails($q$ select org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{lessons}', '{"attendance_by": "nobody"}'), current_date) $q$, 'an unknown attendance_by');
select t.fails($q$ select org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{lessons}', '{"cancellations_marked_by": "everyone"}'), current_date) $q$, 'an unknown cancellations_marked_by');
reset role;

-- (b) the marking window is the centre's choice (default 14 days)
select t.put('LW5',  pg_temp.mk('s2', -5,  t.id('m1')));
select t.put('LW20', pg_temp.mk('s3', -20, t.id('m1')));
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{lessons}', '{"attendance_window_days": 3}'), current_date);
reset role;
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
do $$ declare m text; begin
  begin perform tutor_mark_attendance(t.id('LW5'), 'attended'); exception when others then m := sqlerrm; end;
  if m is null or m not like 'TOO_OLD%3 days%' then raise exception 'FAIL: a 5-day-old lesson with a 3-day window gave: %', m; end if;
  raise notice 'PASS window of 3 days: a 5-day-old lesson is refused, and the message names the centre''s number (%)', m;
end $$;
select t.ok((select not can_mark and not can_note from tutor_my_lessons((select today - 5 from td), (select today - 5 from td)) where lesson_id = t.id('LW5')), 'the screen is told neither marking nor notes are open for it');
reset role;
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{lessons}', '{"attendance_window_days": 30}'), current_date);
reset role;
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
select t.ok((select can_mark and can_note from tutor_my_lessons((select today - 20 from td), (select today - 20 from td)) where lesson_id = t.id('LW20')), 'window of 30 days: a 20-day-old lesson is open (a change applies to lessons already on the calendar)');
select tutor_mark_attendance(t.id('LW20'), 'attended');
reset role;
select t.ok((select attendance = 'attended' from lessons where id = t.id('LW20')), 'and it can be marked');

-- (c) who marks cancellations is the centre's choice (default: an admin)
select t.put('LC1', pg_temp.mk('s3', 0, t.id('m1')));
select t.put('LC2', pg_temp.mk('s4', 0, t.id('m1')));
select t.put('LC3', pg_temp.mk('s1', 0, t.id('m1')));
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{lessons}', '{"cancellations_marked_by": "tutor"}'), current_date);
reset role;
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
select t.ok((select can_cancel from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('LC1')), 'tutors-mark-cancellations: the screen is told the cancellation choices are open');
select tutor_mark_attendance(t.id('LC1'), 'late_cancelled');
select tutor_mark_attendance(t.id('LC2'), 'cancelled_early');
select tutor_mark_attendance(t.id('LC2'), 'absent');
select t.fails($q$ select tutor_mark_attendance(t.id('LC3'), 'maybe') $q$, 'an invented value is still refused');
reset role;
select t.ok((select attendance = 'late_cancelled' and attendance_marked_by = '00000000-0000-0000-0000-000000007001' from lessons where id = t.id('LC1')), 'a tutor can record a late cancellation when the centre allows it, and is stamped');
select t.ok((select attendance = 'absent' from lessons where id = t.id('LC2')), 'and change their own mark');
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{lessons}', '{}'), current_date);          -- back to the defaults
reset role;
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
select t.ok((select not can_cancel from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('LC3')), 'back to the default: cancellations are not the tutor''s to mark');
select t.fails($q$ select tutor_mark_attendance(t.id('LC3'), 'late_cancelled') $q$, 'and the database agrees');
reset role;

-- (d) required remarks are the centre's choice (default: not required)
select t.put('LR1', pg_temp.mk('s1', 0, t.id('m1')));
select t.put('LR2', pg_temp.mk('s2', 0, t.id('m1')));
select t.put('LR3', pg_temp.mk('s3', 0, t.id('m1')));
select t.put('LR4', pg_temp.mk('s4', 0, t.id('m1')));
update lessons set remarks = 'Prepared by the centre' where id in (t.id('LR2'), t.id('LR4'));
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{lessons}', '{"remarks": {"required": true, "deadline_hours": 24}}'), current_date);
reset role;
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
select t.ok((select remarks_required from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('LR1')), 'the screen is told remarks are required');
do $$ declare m text; begin
  begin perform tutor_mark_attendance(t.id('LR1'), 'attended'); exception when others then m := sqlerrm; end;
  if m is null or m not like 'REMARKS_REQUIRED%' then raise exception 'FAIL: attended without remarks gave: %', m; end if;
  raise notice 'PASS remarks required: attended without remarks is refused (%)', m;
end $$;
select t.fails($q$ select tutor_mark_attendance(t.id('LR1'), 'attended', null, null, '   ') $q$, 'remarks required: blank spaces don''t count');
select t.fails($q$ select tutor_mark_attendance(t.id('LR4'), 'attended', null, null, '') $q$, 'remarks required: clearing the existing remarks in the same call is refused');
select tutor_mark_attendance(t.id('LR1'), 'attended', null, null, 'Covered ratios');
select tutor_mark_attendance(t.id('LR2'), 'attended');                              -- remarks already there
select tutor_mark_attendance(t.id('LR3'), 'absent');                                -- a lesson that did not happen needs none
reset role;
select t.ok((select attendance = 'attended' and remarks = 'Covered ratios' from lessons where id = t.id('LR1')), 'with remarks it goes through');
select t.ok((select attendance = 'attended' from lessons where id = t.id('LR2')) and (select attendance = 'absent' and remarks is null from lessons where id = t.id('LR3')), 'existing remarks satisfy the rule; absent never needs remarks');
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{lessons}', '{}'), current_date);          -- defaults again
reset role;

-- ===================================================================== the charge for absent / cancelled lessons, and trial lessons
-- (a) default: an ADMIN enters the charge. The tutor marks; the lesson becomes cancelled with the charge pending (compensation null).
select t.put('LA1', pg_temp.mk('s1', 0, t.id('m1')));
select t.put('LA2', pg_temp.mk('s2', 0, t.id('m1')));
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
select tutor_mark_attendance(t.id('LA1'), 'absent');
select t.fails($q$ select tutor_mark_attendance(t.id('LA2'), 'absent', null, null, null, null, 30) $q$, 'default centre: a tutor typing the charge');
select t.ok((select charge_pending and status = 'cancelled' and not tutor_sets_compensation from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('LA1')), 'the screen is told the charge is pending and an admin sets it');
reset role;
select t.ok((select status = 'cancelled' and compensation is null from lessons where id = t.id('LA1')), 'absent: status cancelled, charge pending (compensation null)');
select t.as('00000000-0000-0000-0000-000000007004'); set role authenticated;
update lessons set compensation = 25 where id = t.id('LA1');            -- staff type the charge, like the app does today
reset role;
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
select t.ok((select not charge_pending from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('LA1')), 'once an admin types it, no longer pending');
select tutor_mark_attendance(t.id('LA1'), 'attended');                     -- the tutor changes their mind
reset role;
select t.ok((select status = 'done' and compensation is null and attendance = 'attended' from lessons where id = t.id('LA1')), 'changing absent to attended makes it done and clears the old charge');
select t.ok((select amount = 123.45 and rate = 55 from lessons where id = t.id('LA1')), 'the lesson''s own price is never touched');

-- (b) the centre lets TUTORS type the charge: a number, 0 if the family isn't charged, never above the lesson's own price
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{lessons}', '{"compensation_entered_by": "tutor"}'), current_date);
reset role;
select t.put('LB1', pg_temp.mk('s1', 0, t.id('m1')));
select t.put('LB2', pg_temp.mk('s2', 0, t.id('m1')));
select t.put('LB3', pg_temp.mk('s3', 0, t.id('m1')));
update lessons set amount = 0 where id = t.id('LB3');                      -- no stored price yet: the cap falls back to rate x hours (55 x 1)
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
select t.ok((select tutor_sets_compensation from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('LB1')), 'the screen is told the tutor types the charge');
do $$ declare m text; begin
  begin perform tutor_mark_attendance(t.id('LB1'), 'absent'); exception when others then m := sqlerrm; end;
  if m is null or m not like 'CHARGE_REQUIRED%' then raise exception 'FAIL: absent without a charge gave: %', m; end if;
  raise notice 'PASS tutors-type-the-charge: absent without a number is refused (%)', m;
end $$;
select t.fails($q$ select tutor_mark_attendance(t.id('LB1'), 'late_cancelled') $q$, 'a cancellation without a number is refused too (even if the centre lets tutors mark it, which it does not here)');
select t.fails($q$ select tutor_mark_attendance(t.id('LB1'), 'absent', null, null, null, null, -1) $q$, 'a negative charge');
select t.fails($q$ select tutor_mark_attendance(t.id('LB1'), 'absent', null, null, null, null, 500) $q$, 'a charge above the lesson''s own price (123.45)');
select t.fails($q$ select tutor_mark_attendance(t.id('LB1'), 'absent', null, null, null, null, 12.345) $q$, 'a charge with more than 2 decimals');
select t.fails($q$ select tutor_mark_attendance(t.id('LB1'), 'attended', null, null, null, null, 10) $q$, 'a charge on an attended lesson');
select tutor_mark_attendance(t.id('LB1'), 'absent', null, null, null, null, 0);                      -- 0 = not charged
select tutor_mark_attendance(t.id('LB2'), 'absent', null, null, null, null, 60.5);
select t.fails($q$ select tutor_mark_attendance(t.id('LB3'), 'absent', null, null, null, null, 56) $q$, 'no stored price: the cap is rate x hours (55)');
select tutor_mark_attendance(t.id('LB3'), 'absent', null, null, null, null, 55);
reset role;
select t.ok((select compensation = 0 and status = 'cancelled' from lessons where id = t.id('LB1')), '0 is recorded as 0 (not charged), not as pending');
select t.ok((select compensation = 60.5 from lessons where id = t.id('LB2')) and (select compensation = 55 from lessons where id = t.id('LB3')), 'a charge up to the price is recorded');
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
select t.ok((select not charge_pending from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('LB1')), '0 is not "pending"');
select tutor_mark_attendance(t.id('LB2'), null, null, null, null, null, 20);                         -- the tutor corrects their own amount
reset role;
select t.ok((select compensation = 20 from lessons where id = t.id('LB2')), 'the tutor can correct the amount they typed');
select t.as('00000000-0000-0000-0000-000000007004'); set role authenticated;
update lessons set compensation = 40 where id = t.id('LB2');                                       -- an admin overrides (normal staff access)
reset role;
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
select tutor_mark_attendance(t.id('LB2'), null, null, null, null, null, 10);                         -- same marker: still theirs to change
reset role;
-- a charge on a lesson someone else marked is not the tutor's to change
update lessons set attendance_marked_by = '00000000-0000-0000-0000-000000007004' where id = t.id('LB2');
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
select t.fails($q$ select tutor_mark_attendance(t.id('LB2'), null, null, null, null, null, 5) $q$, 'changing the charge on a lesson an admin marked');
reset role;
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{lessons}', '{}'), current_date);          -- defaults again
reset role;

-- (c) trial lessons: flagged by an admin by default, by the tutor if the centre chooses
select t.put('LT1', pg_temp.mk('s1', 0, t.id('m1')));
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
select t.fails($q$ select tutor_mark_attendance(t.id('LT1'), null, null, null, null, true) $q$, 'default centre: a tutor flagging a trial');
select tutor_mark_attendance(t.id('LT1'), null, null, null, 'note only', false);                   -- unchanged value is not a flag change
select t.ok(not (select can_flag_trial from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('LT1')), 'the screen is told trials are an admin matter here');
reset role;
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{lessons}', '{"trials_flagged_by": "tutor"}'), current_date);
reset role;
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
select t.ok((select can_flag_trial from tutor_my_lessons((select today from td), (select today from td)) where lesson_id = t.id('LT1')), 'trials-by-tutor: the screen is told it may flag');
select tutor_mark_attendance(t.id('LT1'), null, null, null, null, true);
reset role;
select t.ok((select trial from lessons where id = t.id('LT1')), 'a tutor can flag a trial when the centre allows it');
-- a trial lesson is left out of TutorDeck's active-student count: a brand-new pupil whose only lesson is a trial adds 0, and counts 1 once it is not a trial
select set_config('request.jwt.claims', '', false);
create temp table before_n as select org_active_students_in_month(t.id('centre'), (select today from td)) as n;
insert into students(id, tutor_id, org_id, name) values ('00000000-0000-0000-0000-00000000aaaa', '00000000-0000-0000-0000-0000000000c1', t.id('centre'), 'Trial pupil');
insert into lessons(id, tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, attendance, trial)
  values ('00000000-0000-0000-0000-00000000bbbb', '00000000-0000-0000-0000-0000000000c1', t.id('centre'), '00000000-0000-0000-0000-00000000aaaa', (select today from td), '09:00', '10:00', 50, 'attended', true);
select t.eq(org_active_students_in_month(t.id('centre'), (select today from td)) - (select n from before_n), 0, 'a pupil whose only lesson is a trial adds nothing to the fee count');
update lessons set trial = false where id = '00000000-0000-0000-0000-00000000bbbb';
select t.eq(org_active_students_in_month(t.id('centre'), (select today from td)) - (select n from before_n), 1, 'and counts as active once it is no longer a trial');
select t.as('00000000-0000-0000-0000-000000007001'); set role authenticated;
select tutor_mark_attendance(t.id('LT1'), null, null, null, null, false);
reset role;
select t.ok((select not trial from lessons where id = t.id('LT1')), 'and unflag it');
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{lessons}', '{}'), current_date);
select t.fails($q$ select org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{lessons}', '{"compensation_entered_by": "nobody"}'), current_date) $q$, 'an unknown compensation_entered_by');
select t.fails($q$ select org_save_settings(t.id('centre'), jsonb_set(t.centre_settings(), '{lessons}', '{"trials_flagged_by": "everyone"}'), current_date) $q$, 'an unknown trials_flagged_by');
reset role;

-- (d) solo tutors' lessons never change status just because attendance is set (the status rule is for centres only)
select set_config('request.jwt.claims', '', false);                       -- no signed-in identity: these updates are made as the database owner
insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status)
  select '00000000-0000-0000-0000-0000000000a1', t.id('tina_org'), id, current_date, '10:00', '11:00', 40, 40, 'scheduled' from students where org_id = t.id('tina_org') limit 1;
select t.put('SOLO1', (select id from lessons where org_id = t.id('tina_org') and status = 'scheduled' and lesson_date = current_date and start_time = '10:00' limit 1));
update lessons set attendance = 'attended' where id = t.id('SOLO1');
select t.ok((select status = 'scheduled' and attendance = 'attended' and compensation is null and attendance_marked_at is not null from lessons where id = t.id('SOLO1')), 'a solo lesson keeps its status when attendance is set (the status rule is for centres only)');
update lessons set attendance = 'absent' where id = t.id('SOLO1');
select t.ok((select status = 'scheduled' from lessons where id = t.id('SOLO1')), 'and also for absent: solo flows are unchanged');
update lessons set attendance = null where org_id = t.id('tina_org');

-- ===================================================================== grants
select t.ok(not has_function_privilege('anon', 'public.tutor_my_lessons(date,date)', 'execute')
        and not has_function_privilege('anon', 'public.tutor_mark_attendance(uuid,text,text,text,text,boolean,numeric)', 'execute')
        and has_function_privilege('authenticated', 'public.tutor_my_lessons(date,date)', 'execute')
        and has_function_privilege('authenticated', 'public.tutor_mark_attendance(uuid,text,text,text,text,boolean,numeric)', 'execute'), 'anonymous callers have no access; signed-in users do (each call checks who they are)');
set role anon;
select t.fails($q$ select * from tutor_my_lessons(current_date, current_date) $q$, 'an anonymous call to tutor_my_lessons');
reset role;

\echo ALL TUTOR-ACCESS TESTS PASSED
