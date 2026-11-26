-- T3 step 3 tests: staff_lessons / staff_mark_attendance / staff_correct_attendance and the lessons_attendance_guard trigger.
-- Runs after staff_students_test.sql in the same throwaway database (reuses the t.* helpers). Builds its own centre and made-up people.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000a701', 'sa.owner@centre.test'),   ('00000000-0000-0000-0000-00000000a702', 'sa.staff@centre.test'),
  ('00000000-0000-0000-0000-00000000a703', 'sa.look@centre.test'),    ('00000000-0000-0000-0000-00000000a704', 'sa.tutor1@centre.test'),
  ('00000000-0000-0000-0000-00000000a705', 'sa.tutor2@centre.test'),  ('00000000-0000-0000-0000-00000000a706', 'sa.outsider@centre.test'),
  ('00000000-0000-0000-0000-00000000a707', 'sa.off@centre.test'),     ('00000000-0000-0000-0000-00000000a709', 'sa.owner2@centre.test');
set role authenticated; select t.as('00000000-0000-0000-0000-00000000a701');
select t.put('sa', org_create_centre('Attendance Centre', t.centre_settings()));
select t.as('00000000-0000-0000-0000-00000000a709');
select t.put('sa2', org_create_centre('Other Attendance Centre', t.centre_settings()));
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('sa'), '00000000-0000-0000-0000-00000000a702', 'Staff Sam',   'staff', array['manage_timetable', 'manage_students'], 'active'),
  (t.id('sa'), '00000000-0000-0000-0000-00000000a703', 'Look Only',   'staff', array['manage_students'], 'active'),
  (t.id('sa'), '00000000-0000-0000-0000-00000000a704', 'Tutor One',   'tutor', '{}', 'active'),
  (t.id('sa'), '00000000-0000-0000-0000-00000000a705', 'Tutor Two',   'tutor', '{}', 'active'),
  (t.id('sa'), '00000000-0000-0000-0000-00000000a707', 'Switched off','staff', array['manage_timetable'], 'disabled');
select t.put('m1', (select id from memberships where org_id = t.id('sa') and user_id = '00000000-0000-0000-0000-00000000a704'));
select t.put('m2', (select id from memberships where org_id = t.id('sa') and user_id = '00000000-0000-0000-0000-00000000a705'));
select t.put('mstaff', (select id from memberships where org_id = t.id('sa') and user_id = '00000000-0000-0000-0000-00000000a702'));

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today;
grant select on td to authenticated, anon;
create temp table stu (k text primary key, id uuid);
insert into stu select 's' || g, gen_random_uuid() from generate_series(1, 6) g;
grant select on stu to authenticated;
-- A REMOTE 1-to-1 centre: no branch, no room, no class anywhere below
insert into students(id, tutor_id, org_id, name, level, contact)
  select id, '00000000-0000-0000-0000-00000000a701', t.id('sa'), 'Kid ' || k, 'P' || right(k, 1), '9100000' || right(k, 1) from stu;
create function pg_temp.mk(p_k text, p_off int, p_by uuid, p_status text default 'scheduled') returns uuid language sql as $$
  insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, taught_by, subject)
  select '00000000-0000-0000-0000-00000000a701', t.id('sa'), stu.id, (select today from td) + p_off, '16:00', '17:00', 55, 123.45, p_status, p_by, 'Math'
  from stu where stu.k = p_k returning id $$;
select t.eq((select count(*) from branches where org_id = t.id('sa')) + (select count(*) from rooms where org_id = t.id('sa')), 0, 'the test centre has no branch and no room (remote 1-to-1)');
select t.put('LA', pg_temp.mk('s1', 0, t.id('m1')));          -- today, tutor one, unmarked
select t.put('LB', pg_temp.mk('s2', 0, t.id('m2')));          -- today, tutor two, unmarked
select t.put('LC', pg_temp.mk('s3', 0, null));                -- today, no tutor at all
select t.put('LF', pg_temp.mk('s1', 1, t.id('m1')));          -- tomorrow
select t.put('LO', pg_temp.mk('s2', -3, t.id('m1')));         -- three days ago, unmarked
select t.put('LX', pg_temp.mk('s4', 0, t.id('m1'), 'cancelled'));   -- cancelled by staff, no mark = closed
select t.put('LT', pg_temp.mk('s5', 0, t.id('m1')));          -- today, tutor one: will be marked BY THE TUTOR
select t.put('LT2', pg_temp.mk('s6', 0, t.id('m1')));        -- today, tutor one: second tutor mark
select t.put('LCOR', pg_temp.mk('s6', -1, t.id('m1')));       -- yesterday, tutor one

-- the first call by a person must say what went wrong in plain words
create function pg_temp.refused(p_user text, p_sql text, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  begin execute p_sql; exception when others then m := sqlerrm; end;
  if m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS refused: % (%)', p_msg, m;
end $$;
create function pg_temp.sess(p_user text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false) $$;

-- ===================================================================== the list: who may look, what it shows
select t.as('00000000-0000-0000-0000-00000000a702'); set role authenticated;
select staff_lessons(t.id('sa'), (select today - 5 from td), (select today + 2 from td)) as r \gset
reset role;
select t.eq((:'r'::jsonb->>'total')::int, 9, 'staff see all 9 lessons of the week (every tutor, and the one with no tutor)');
select t.ok((:'r'::jsonb->>'can_mark')::boolean, 'staff with manage_timetable are told they can mark');
select t.ok((:'r'::jsonb->>'today')::date = (select today from td), 'the response says which day the centre calls today');
select t.eq((:'r'::jsonb->'counts'->>'unmarked')::int, 7, 'unmarked = due lessons with no mark and not cancelled (LA LB LC LO LT LT2 LCOR; not tomorrow, not the cancelled one)');
select t.eq(jsonb_array_length(:'r'::jsonb->'tutors'), 2, 'the tutor list for the filter has the two tutors');
select t.ok(not exists (select 1 from jsonb_array_elements(:'r'::jsonb->'rows') e, jsonb_object_keys(e) k
                         where k in ('rate', 'amount', 'paid', 'compensation', 'charge_note', 'total', 'invoice_id') or k ~ '_cents$'), 'no money field in any row (rate, amount, paid, compensation, cents)');
select t.ok((select e->>'state' = 'future' and not (e->>'can_mark')::boolean and not (e->>'can_correct')::boolean
               from jsonb_array_elements(:'r'::jsonb->'rows') e where e->>'lesson_id' = t.id('LF')::text), 'tomorrow''s lesson: state future, NO mark and NO correct button');
select t.ok((select e->>'state' = 'open' and (e->>'can_mark')::boolean and e->>'tutor_name' = 'Tutor One' and e->>'student_name' = 'Kid s1'
               from jsonb_array_elements(:'r'::jsonb->'rows') e where e->>'lesson_id' = t.id('LA')::text), 'today''s lesson: state open, can mark, tutor and student names shown');
select t.ok((select e->>'state' = 'cancelled' and not (e->>'can_mark')::boolean from jsonb_array_elements(:'r'::jsonb->'rows') e where e->>'lesson_id' = t.id('LX')::text), 'a lesson cancelled by staff is closed: no buttons');
select t.ok((select e->>'tutor_id' is null and e->>'tutor_name' is null and (e->>'can_mark')::boolean from jsonb_array_elements(:'r'::jsonb->'rows') e where e->>'lesson_id' = t.id('LC')::text), 'a lesson with no tutor is listed and can be marked by staff');

select t.as('00000000-0000-0000-0000-00000000a702'); set role authenticated;
select t.eq((select (staff_lessons(t.id('sa'), (select today from td), (select today from td), t.id('m2')))->>'total')::int, 1, 'filter by tutor: tutor two has 1 lesson today');
select t.eq((select (staff_lessons(t.id('sa'), (select today - 5 from td), (select today + 2 from td), null, 'unmarked'))->>'total')::int, 7, 'filter "not marked": 7');
select t.eq((select (staff_lessons(t.id('sa'), (select today - 5 from td), (select today + 2 from td), null, 'marked'))->>'total')::int, 0, 'filter "marked": none yet');
select t.eq((select jsonb_array_length((staff_lessons(t.id('sa'), (select today - 5 from td), (select today + 2 from td), null, 'all', 1, 4))->'rows')), 4, 'paging: page 1 of size 4 has 4 rows');
select t.eq((select jsonb_array_length((staff_lessons(t.id('sa'), (select today - 5 from td), (select today + 2 from td), null, 'all', 3, 4))->'rows')), 1, 'paging: page 3 of size 4 has the last row');
select t.eq((select (staff_lessons(t.id('sa'), (select today - 5 from td), (select today + 2 from td), null, 'all', 3, 4))->>'total')::int, 9, 'paging: the total stays 9 on every page');
select t.fails($q$ select staff_lessons(t.id('sa'), current_date - 100, current_date) $q$, 'asking for more than 62 days');
select t.fails($q$ select staff_lessons(t.id('sa'), current_date, current_date - 1) $q$, 'a backwards range');
select t.fails($q$ select staff_lessons(t.id('sa'), current_date, current_date, null, 'everything') $q$, 'an unknown filter');
select t.fails($q$ select staff_lessons(t.id('sa'), current_date, current_date, null, 'all', 1, 101) $q$, 'a page size over 100');
select t.fails($q$ select staff_lessons(t.id('sa'), current_date, current_date, gen_random_uuid()) $q$, 'a tutor filter naming nobody in this centre');
reset role;

-- the look-only staff member sees everything but gets no buttons
select t.as('00000000-0000-0000-0000-00000000a703'); set role authenticated;
select staff_lessons(t.id('sa'), (select today from td), (select today from td)) as r2 \gset
reset role;
select t.ok(not (:'r2'::jsonb->>'can_mark')::boolean and not exists (select 1 from jsonb_array_elements(:'r2'::jsonb->'rows') e where (e->>'can_mark')::boolean), 'staff without manage_timetable can look, and are given no mark button');
-- the owner sees it too
select t.as('00000000-0000-0000-0000-00000000a701'); set role authenticated;
select t.eq((select (staff_lessons(t.id('sa'), (select today from td), (select today from td)))->>'total')::int, 6, 'the owner sees today''s 6 lessons');
reset role;
-- everyone else gets the same NOT_FOUND
select pg_temp.refused('00000000-0000-0000-0000-00000000a704', format('set role authenticated; select staff_lessons(%L, current_date, current_date)', t.id('sa')), 'NOT_FOUND', 'a tutor cannot use the staff list'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a706', format('set role authenticated; select staff_lessons(%L, current_date, current_date)', t.id('sa')), 'NOT_FOUND', 'a stranger cannot use the staff list'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a707', format('set role authenticated; select staff_lessons(%L, current_date, current_date)', t.id('sa')), 'NOT_FOUND', 'switched-off staff cannot use the staff list'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a709', format('set role authenticated; select staff_lessons(%L, current_date, current_date)', t.id('sa')), 'NOT_FOUND', 'the owner of ANOTHER centre cannot see this centre''s list'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-0000000000a1', format('set role authenticated; select staff_lessons(%L, current_date, current_date)', t.id('sa')), 'NOT_FOUND', 'a solo tutor cannot use the staff list'); reset role;
select org_personal('00000000-0000-0000-0000-0000000000a1') as tina_solo \gset
select pg_temp.refused('00000000-0000-0000-0000-0000000000a1', format('set role authenticated; select staff_lessons(%L, current_date, current_date)', :'tina_solo'), 'NOT_FOUND', 'a solo organisation has no staff list'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a701', 'set role authenticated; select staff_lessons(gen_random_uuid(), current_date, current_date)', 'NOT_FOUND', 'an unknown organisation id'); reset role;
select set_config('request.jwt.claims', '', false);
select t.fails($q$ set role anon; select staff_lessons(t.id('sa'), current_date, current_date) $q$, 'a signed-out visitor'); reset role;

-- ===================================================================== marking: the first mark of a lesson
select pg_temp.refused('00000000-0000-0000-0000-00000000a702', format('set role authenticated; select staff_mark_attendance(%L, ''attended'')', t.id('LF')), 'TOO_EARLY', 'staff can''t mark tomorrow''s lesson'); reset role;
select t.ok((select attendance is null from lessons where id = t.id('LF')), 'and tomorrow''s lesson is untouched');
select pg_temp.refused('00000000-0000-0000-0000-00000000a702', format('set role authenticated; select staff_mark_attendance(%L, ''maybe'')', t.id('LA')), 'BAD_VALUE', 'an unknown mark'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a702', format('set role authenticated; select staff_mark_attendance(%L, null)', t.id('LA')), 'BAD_VALUE', 'no mark at all'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a702', format('set role authenticated; select staff_mark_attendance(%L, ''attended'')', t.id('LX')), 'CANCELLED', 'a lesson cancelled by staff is closed'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a703', format('set role authenticated; select staff_mark_attendance(%L, ''attended'')', t.id('LA')), 'NOT_ALLOWED', 'staff without manage_timetable can''t mark'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a704', format('set role authenticated; select staff_mark_attendance(%L, ''attended'')', t.id('LB')), 'NOT_FOUND', 'a tutor can''t use the staff function (not even on their own lesson''s neighbour)'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a704', format('set role authenticated; select staff_mark_attendance(%L, ''attended'')', t.id('LA')), 'NOT_FOUND', 'a tutor can''t use the staff function on their OWN lesson either'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a706', format('set role authenticated; select staff_mark_attendance(%L, ''attended'')', t.id('LA')), 'NOT_FOUND', 'a stranger can''t'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a709', format('set role authenticated; select staff_mark_attendance(%L, ''attended'')', t.id('LA')), 'NOT_FOUND', 'another centre''s owner can''t'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a707', format('set role authenticated; select staff_mark_attendance(%L, ''attended'')', t.id('LA')), 'NOT_FOUND', 'switched-off staff can''t'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a702', 'set role authenticated; select staff_mark_attendance(gen_random_uuid(), ''attended'')', 'NOT_FOUND', 'an unknown lesson'); reset role;
select t.ok((select count(*) = 0 from lessons where attendance is not null and org_id = t.id('sa')), 'none of the refused calls marked anything');

select t.as('00000000-0000-0000-0000-00000000a702'); set role authenticated;
select staff_mark_attendance(t.id('LA'), 'attended', '  Did fractions well  ') as m1 \gset
select staff_mark_attendance(t.id('LB'), 'absent') as m2 \gset
select staff_mark_attendance(t.id('LC'), 'late_cancelled') as m3 \gset
select staff_mark_attendance(t.id('LO'), 'cancelled_early') as m4 \gset
reset role;
select t.ok((select attendance = 'attended' and status = 'done' and remarks = 'Did fractions well' and attendance_marked_by = '00000000-0000-0000-0000-00000000a702' and attendance_marked_at is not null and compensation is null
               from lessons where id = t.id('LA')), 'attended: status done, remarks trimmed and saved, stamped with the staff member');
select t.ok((:'m1'::jsonb->>'status') = 'done', 'the function says the new status');
select t.ok((select attendance = 'absent' and status = 'cancelled' and compensation is null from lessons where id = t.id('LB')), 'absent: status cancelled and the charge is PENDING (compensation null; typing it is step 4)');
select t.ok((select attendance = 'late_cancelled' and status = 'cancelled' and compensation is null from lessons where id = t.id('LC')), 'staff can set late cancelled (and mark a lesson that has no tutor)');
select t.ok((select attendance = 'cancelled_early' and status = 'cancelled' from lessons where id = t.id('LO')), 'staff can mark an old lesson (three days ago) with no window limit');
select t.ok(exists (select 1 from audit_log where org_id = t.id('sa') and action = 'staff_mark_attendance' and row_id = t.id('LA')::text and actor = '00000000-0000-0000-0000-00000000a702'
                      and after->>'attendance' = 'attended'), 'a named audit entry says who marked it');
select pg_temp.refused('00000000-0000-0000-0000-00000000a702', format('set role authenticated; select staff_mark_attendance(%L, ''absent'')', t.id('LA')), 'ALREADY_MARKED', 'marking again asks for Correct instead'); reset role;
select t.ok((select attendance = 'attended' from lessons where id = t.id('LA')), 'and the mark stands');

-- ===================================================================== the centre's own rule: remarks
select t.as('00000000-0000-0000-0000-00000000a701'); set role authenticated;
select org_save_settings(t.id('sa'), jsonb_set(t.centre_settings(), '{lessons}', '{"remarks": {"required": true, "deadline_hours": 24}}'), current_date);
reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a702', format('set role authenticated; select staff_mark_attendance(%L, ''attended'')', t.id('LT')), 'REMARKS_REQUIRED', 'remarks.required = on: no attended without remarks'); reset role;
select t.ok((select attendance is null from lessons where id = t.id('LT')), 'and nothing was saved');
select t.as('00000000-0000-0000-0000-00000000a702'); set role authenticated;
select staff_mark_attendance(t.id('LT'), 'absent');     -- absent doesn't need remarks
select t.ok((select attendance = 'absent' from lessons where id = t.id('LT')), 'absent needs no remarks');
reset role;
-- put LT back to unmarked for the tutor tests below (server job: no signed-in user)
select set_config('request.jwt.claims', '', false);
update lessons set attendance = null, status = 'scheduled' where id = t.id('LT');
select t.as('00000000-0000-0000-0000-00000000a702'); set role authenticated;
select staff_mark_attendance(t.id('LT'), 'attended', 'Great session');
select t.ok((select attendance = 'attended' and remarks = 'Great session' from lessons where id = t.id('LT')), 'remarks.required = on: attended with remarks is accepted');
reset role;
select set_config('request.jwt.claims', '', false);
update lessons set attendance = null, status = 'scheduled', remarks = null where id = t.id('LT');
select t.as('00000000-0000-0000-0000-00000000a701'); set role authenticated;
select org_save_settings(t.id('sa'), jsonb_set(t.centre_settings(), '{lessons}', '{}'), current_date);     -- defaults again
reset role;

-- ===================================================================== tutors still mark their own lessons; staff then correct
select t.as('00000000-0000-0000-0000-00000000a704'); set role authenticated;
select tutor_mark_attendance(t.id('LT'), 'attended');
select tutor_mark_attendance(t.id('LT2'), 'absent');
select tutor_mark_attendance(t.id('LCOR'), 'attended');
reset role;
select t.ok((select attendance = 'attended' and status = 'done' and attendance_marked_by = '00000000-0000-0000-0000-00000000a704' from lessons where id = t.id('LT')), 'the tutor function still works (tutor one marked their own lesson)');
select t.as('00000000-0000-0000-0000-00000000a704'); set role authenticated;
select tutor_mark_attendance(t.id('LT'), 'absent');
reset role;
select t.ok((select attendance = 'absent' and attendance_marked_by = '00000000-0000-0000-0000-00000000a704' from lessons where id = t.id('LT')), 'a tutor may still change THEIR OWN mark (the guard allows it: the marker is the same person)');
select pg_temp.refused('00000000-0000-0000-0000-00000000a704', format('set role authenticated; select tutor_mark_attendance(%L, ''attended'')', t.id('LF')), 'TOO_EARLY', 'the tutor function still refuses tomorrow'); reset role;

-- staff mark over tutor one's mark? Only through Correct, and only with a reason
select pg_temp.refused('00000000-0000-0000-0000-00000000a702', format('set role authenticated; select staff_mark_attendance(%L, ''absent'')', t.id('LT2')), 'ALREADY_MARKED', 'staff marking over a tutor''s mark must use Correct'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a702', format('set role authenticated; select staff_correct_attendance(%L, ''attended'', null)', t.id('LT2')), 'REASON_REQUIRED', 'a correction with no reason'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a702', format('set role authenticated; select staff_correct_attendance(%L, ''attended'', ''   '')', t.id('LT2')), 'REASON_REQUIRED', 'a correction with a blank reason'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a702', format('set role authenticated; select staff_correct_attendance(%L, ''attended'', repeat(''x'', 501))', t.id('LT2')), 'TOO_LONG', 'a reason over 500 characters'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a702', format('set role authenticated; select staff_correct_attendance(%L, ''absent'', ''same'')', t.id('LT2')), 'NO_CHANGE', 'correcting to the same mark'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a702', format('set role authenticated; select staff_correct_attendance(%L, ''maybe'', ''typo'')', t.id('LT2')), 'BAD_VALUE', 'an unknown mark'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a702', format('set role authenticated; select staff_correct_attendance(%L, ''attended'', ''typo'')', t.id('LF')), 'NOT_MARKED', 'an unmarked lesson (tomorrow''s) can''t be corrected, only marked'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a703', format('set role authenticated; select staff_correct_attendance(%L, ''attended'', ''typo'')', t.id('LT2')), 'NOT_ALLOWED', 'staff without manage_timetable can''t correct'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a704', format('set role authenticated; select staff_correct_attendance(%L, ''attended'', ''I changed my mind'')', t.id('LT2')), 'NOT_FOUND', 'TUTORS NEVER correct (even their own mark)'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a709', format('set role authenticated; select staff_correct_attendance(%L, ''attended'', ''typo'')', t.id('LT2')), 'NOT_FOUND', 'another centre can''t correct'); reset role;
select t.ok((select attendance = 'absent' and attendance_marked_by = '00000000-0000-0000-0000-00000000a704' from lessons where id = t.id('LT2')), 'every refused attempt left the tutor''s mark exactly as it was');

select t.as('00000000-0000-0000-0000-00000000a702'); set role authenticated;
select staff_correct_attendance(t.id('LT2'), 'attended', '  Parent confirmed the lesson took place  ') as c1 \gset
reset role;
select t.ok((select attendance = 'attended' and status = 'done' and compensation is null and attendance_marked_by = '00000000-0000-0000-0000-00000000a702' from lessons where id = t.id('LT2')),
            'corrected: absent → attended, status follows (done), now stamped with the staff member');
select t.ok((:'c1'::jsonb->>'status') = 'done', 'the function reports the new status');
select t.ok(exists (select 1 from audit_log where org_id = t.id('sa') and action = 'staff_correct_attendance' and row_id = t.id('LT2')::text and actor = '00000000-0000-0000-0000-00000000a702'
                      and before->>'attendance' = 'absent' and before->>'marked_by' = '00000000-0000-0000-0000-00000000a704'
                      and after->>'attendance' = 'attended' and after->>'reason' = 'Parent confirmed the lesson took place'),
            'the audit log shows who corrected it, from what to what, who had marked it before, and the (trimmed) reason');
select t.ok(exists (select 1 from audit_log where org_id = t.id('sa') and table_name = 'lessons' and action = 'update' and row_id = t.id('LT2')::text and after->>'attendance' = 'attended' and before->>'attendance' = 'absent'),
            'and the generic row-level audit entry is there as well');
select pg_temp.refused('00000000-0000-0000-0000-00000000a704', format('set role authenticated; select tutor_mark_attendance(%L, ''absent'')', t.id('LT2')), 'ALREADY_MARKED', 'the tutor can''t undo the staff correction'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a702', format('set role authenticated; select staff_correct_attendance(%L, ''attended'', ''again'')', t.id('LT2')), 'NO_CHANGE', 'correcting to the mark it already has'); reset role;
-- another staff member (the owner) may correct STAFF's mark too: the guard flag names the lesson, not the person
select t.as('00000000-0000-0000-0000-00000000a701'); set role authenticated;
select staff_correct_attendance(t.id('LT2'), 'late_cancelled', 'Owner: it was cancelled by text the morning of');
reset role;
select t.ok((select attendance = 'late_cancelled' and status = 'cancelled' and attendance_marked_by = '00000000-0000-0000-0000-00000000a701' from lessons where id = t.id('LT2')), 'the owner can correct a staff member''s mark; status follows to cancelled, charge pending');
-- the flag is gone after the call
select t.ok(coalesce(current_setting('td.attendance_override', true), '') = '', 'the override flag is cleared after the correction (it never lingers in the session)');

-- ===================================================================== THE HOLE: direct table writes by staff
select t.as('00000000-0000-0000-0000-00000000a702'); set role authenticated;
select t.fails(format($q$ update lessons set attendance = 'attended' where id = %L $q$, t.id('LF')), 'staff updating tomorrow''s lesson directly in the table');
select t.fails(format($q$ update lessons set attendance = 'attended', status = 'done' where id = %L $q$, t.id('LF')), 'staff updating tomorrow''s lesson AND its status directly');
select t.fails(format($q$ update lessons set attendance = 'absent' where id = %L $q$, t.id('LCOR')), 'staff overwriting a TUTOR''s mark directly in the table (without Correct)');
select t.fails(format($q$ update lessons set attendance = null where id = %L $q$, t.id('LCOR')), 'staff CLEARING a tutor''s mark directly');
select t.fails(format($q$ update lessons set attendance_marked_by = auth.uid() where id = %L $q$, t.id('LCOR')), 'staff re-stamping a tutor''s mark as their own (the back door)');
select t.fails(format($q$ update lessons set attendance_marked_at = now() where id = %L $q$, t.id('LCOR')), 'staff editing the "marked at" time directly');
select t.fails(format($q$ update lessons set attendance = 'absent', attendance_marked_by = auth.uid() where id = %L $q$, t.id('LCOR')), 'staff doing both in one statement');
select t.fails($q$ insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, attendance)
                    select '00000000-0000-0000-0000-00000000a701', t.id('sa'), id, (select today + 1 from td), '10:00', '11:00', 1, 'attended' from stu limit 1 $q$, 'staff inserting a lesson in the future that is already marked');
select t.fails(format($q$ update lessons set attendance = 'attended' where org_id = %L $q$, t.id('sa')), 'a bulk update across the whole centre (every row is checked)');
reset role;
select t.ok((select attendance = 'attended' and attendance_marked_by = '00000000-0000-0000-0000-00000000a704' from lessons where id = t.id('LCOR')) and (select attendance is null from lessons where id = t.id('LF')),
            'after all those attempts the tutor''s mark and tomorrow''s lesson are exactly as they were');
-- what staff CAN still do directly: ordinary edits and a first mark that obeys the rules
select t.as('00000000-0000-0000-0000-00000000a702'); set role authenticated;
select t.eq(t.rows(format($q$ update lessons set subject = 'Maths' where id = %L $q$, t.id('LCOR'))), 1, 'ordinary edits to a marked lesson (subject) still work directly');
select t.eq(t.rows(format($q$ update lessons set trial = true where id = %L $q$, t.id('LCOR'))), 1, 'so does the trial flag');
select t.eq(t.rows(format($q$ update lessons set attendance = 'attended' where id = %L and attendance is null $q$, t.id('LCOR'))), 0, 'the old "update where unmarked" pattern simply finds nothing to do');
reset role;
select set_config('request.jwt.claims', '', false);
insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, status, taught_by)
  select '00000000-0000-0000-0000-00000000a701', t.id('sa'), id, (select today from td), '18:00', '19:00', 55, 'scheduled', t.id('m2') from stu where k = 's1';
select id as ldirect from lessons where org_id = t.id('sa') and start_time = '18:00' \gset
select t.as('00000000-0000-0000-0000-00000000a702'); set role authenticated;
update lessons set attendance = 'attended' where id = :'ldirect';
reset role;
select t.ok((select attendance = 'attended' and status = 'done' and attendance_marked_by = '00000000-0000-0000-0000-00000000a702' from lessons where id = :'ldirect'), 'a direct FIRST mark on today''s lesson still passes the rules, and is stamped and status-synced as before');
-- a server job (no signed-in user) is not "someone marking": billing and the delete function keep working
select set_config('request.jwt.claims', '', false);
select t.eq(t.rows(format($q$ update lessons set attendance = 'attended' where id = %L $q$, t.id('LF'))), 1, 'a server job with no signed-in user can still write (documented; the guard is for people)');
update lessons set attendance = null, status = 'scheduled' where id = t.id('LF');

-- ===================================================================== solo tutors are untouched
select t.as('00000000-0000-0000-0000-0000000000a1'); set role authenticated;
insert into students(tutor_id, name) values ('00000000-0000-0000-0000-0000000000a1', 'Solo After Staff Attendance');
insert into lessons(tutor_id, student_id, lesson_date, start_time, end_time, rate, status)
  select '00000000-0000-0000-0000-0000000000a1', id, (select today + 3 from td), '10:00', '11:00', 40, 'scheduled' from students where name = 'Solo After Staff Attendance';
select t.eq(t.rows($q$ update lessons set attendance = 'attended', status = 'done' where student_id = (select id from students where name = 'Solo After Staff Attendance') $q$), 1, 'a solo tutor can still set attendance on a lesson in the future (the guard is for centres only)');
select t.eq(t.rows($q$ update lessons set attendance = 'absent' where student_id = (select id from students where name = 'Solo After Staff Attendance') $q$), 1, 'and change it again');
select t.ok((select status = 'done' from lessons where student_id = (select id from students where name = 'Solo After Staff Attendance')), 'a solo lesson''s status does not follow attendance (as always)');
reset role;

-- ===================================================================== settings: attendance_by governs TUTORS only
select t.as('00000000-0000-0000-0000-00000000a701'); set role authenticated;
select org_save_settings(t.id('sa'), jsonb_set(t.centre_settings(), '{lessons}', '{"attendance_by": "admin"}'), current_date);
reset role;
select t.put('LAD', pg_temp.mk('s3', 0, t.id('m1'))); select t.put('LAD2', pg_temp.mk('s4', 0, t.id('m1')));
select pg_temp.refused('00000000-0000-0000-0000-00000000a704', format('set role authenticated; select tutor_mark_attendance(%L, ''attended'')', t.id('LAD')), 'ADMIN_ONLY', 'attendance_by = admin: tutor one is refused'); reset role;
select t.as('00000000-0000-0000-0000-00000000a702'); set role authenticated;
select staff_mark_attendance(t.id('LAD'), 'attended');
reset role;
select t.ok((select attendance = 'attended' and attendance_marked_by = '00000000-0000-0000-0000-00000000a702' from lessons where id = t.id('LAD')), 'attendance_by = admin: staff mark it fine');
select t.as('00000000-0000-0000-0000-00000000a702'); set role authenticated;
select t.ok((select e->>'can_mark' = 'true' from jsonb_array_elements((staff_lessons(t.id('sa'), (select today from td), (select today from td)))->'rows') e where e->>'lesson_id' = t.id('LAD2')::text), 'and the list still gives staff the mark button');
select staff_correct_attendance(t.id('LAD'), 'absent', 'Parent called to say the child was ill');
reset role;
select t.ok((select attendance = 'absent' from lessons where id = t.id('LAD')), 'attendance_by = admin: staff can correct too');
select t.as('00000000-0000-0000-0000-00000000a701'); set role authenticated;
select org_save_settings(t.id('sa'), jsonb_set(t.centre_settings(), '{lessons}', '{"attendance_by": "tutor"}'), current_date);
reset role;
select t.as('00000000-0000-0000-0000-00000000a704'); set role authenticated;
select tutor_mark_attendance(t.id('LAD2'), 'attended');
reset role;
select t.ok((select attendance = 'attended' and attendance_marked_by = '00000000-0000-0000-0000-00000000a704' from lessons where id = t.id('LAD2')), 'attendance_by = tutor: the tutor marks');
select t.as('00000000-0000-0000-0000-00000000a702'); set role authenticated;
select staff_correct_attendance(t.id('LAD2'), 'absent', 'Mis-tapped by the tutor');
reset role;
select t.ok((select attendance = 'absent' and attendance_marked_by = '00000000-0000-0000-0000-00000000a702' from lessons where id = t.id('LAD2')), 'attendance_by = tutor: staff are still the safety net and correct it');

-- attendance_window_days limits tutors only
select t.as('00000000-0000-0000-0000-00000000a701'); set role authenticated;
select org_save_settings(t.id('sa'), jsonb_set(t.centre_settings(), '{lessons}', '{"attendance_window_days": 1}'), current_date);
reset role;
select t.put('LWIN', pg_temp.mk('s5', -6, t.id('m1')));
select pg_temp.refused('00000000-0000-0000-0000-00000000a704', format('set role authenticated; select tutor_mark_attendance(%L, ''attended'')', t.id('LWIN')), 'TOO_OLD', 'window = 1 day: the tutor can''t mark a lesson from six days ago'); reset role;
select t.as('00000000-0000-0000-0000-00000000a702'); set role authenticated;
select staff_mark_attendance(t.id('LWIN'), 'attended');
reset role;
select t.ok((select attendance = 'attended' from lessons where id = t.id('LWIN')), 'window = 1 day: staff can still mark it (the window is for tutors only)');

-- cancellations_marked_by: both values, staff can always set both cancellations
select t.put('LC1', pg_temp.mk('s3', 0, t.id('m1'))); select t.put('LC2', pg_temp.mk('s4', 0, t.id('m1')));
select t.put('LC3', pg_temp.mk('s5', 0, t.id('m1'))); select t.put('LC4', pg_temp.mk('s6', 0, t.id('m1')));
select t.as('00000000-0000-0000-0000-00000000a701'); set role authenticated;
select org_save_settings(t.id('sa'), jsonb_set(t.centre_settings(), '{lessons}', '{"cancellations_marked_by": "admin"}'), current_date);
reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a704', format('set role authenticated; select tutor_mark_attendance(%L, ''late_cancelled'')', t.id('LC1')), 'BAD_VALUE', 'cancellations_marked_by = admin: the tutor can''t'); reset role;
select t.as('00000000-0000-0000-0000-00000000a702'); set role authenticated;
select staff_mark_attendance(t.id('LC1'), 'late_cancelled'); select staff_mark_attendance(t.id('LC2'), 'cancelled_early');
reset role;
select t.ok((select count(*) = 2 and bool_and(status = 'cancelled' and compensation is null) from lessons where id in (t.id('LC1'), t.id('LC2'))), 'cancellations_marked_by = admin: staff set both cancellations; charge pending');
select t.as('00000000-0000-0000-0000-00000000a701'); set role authenticated;
select org_save_settings(t.id('sa'), jsonb_set(t.centre_settings(), '{lessons}', '{"cancellations_marked_by": "tutor"}'), current_date);
reset role;
select t.as('00000000-0000-0000-0000-00000000a702'); set role authenticated;
select staff_mark_attendance(t.id('LC3'), 'late_cancelled'); select staff_mark_attendance(t.id('LC4'), 'cancelled_early');
reset role;
select t.ok((select count(*) = 2 and bool_and(status = 'cancelled') from lessons where id in (t.id('LC3'), t.id('LC4'))), 'cancellations_marked_by = tutor: staff can still set both cancellations');

-- compensation_entered_by: staff marking never needs to type a charge, whichever the value (typing it is step 4)
select t.put('LK1', pg_temp.mk('s3', 0, t.id('m1'))); select t.put('LK2', pg_temp.mk('s4', 0, t.id('m1')));
select t.as('00000000-0000-0000-0000-00000000a701'); set role authenticated;
select org_save_settings(t.id('sa'), jsonb_set(t.centre_settings(), '{lessons}', '{"compensation_entered_by": "admin"}'), current_date);
reset role;
select t.as('00000000-0000-0000-0000-00000000a702'); set role authenticated;
select staff_mark_attendance(t.id('LK1'), 'absent');
reset role;
select t.ok((select compensation is null and status = 'cancelled' from lessons where id = t.id('LK1')), 'compensation_entered_by = admin: staff mark absent, the charge waits for step 4 (null)');
select t.as('00000000-0000-0000-0000-00000000a701'); set role authenticated;
select org_save_settings(t.id('sa'), jsonb_set(t.centre_settings(), '{lessons}', '{"compensation_entered_by": "tutor"}'), current_date);
reset role;
select t.as('00000000-0000-0000-0000-00000000a702'); set role authenticated;
select staff_mark_attendance(t.id('LK2'), 'absent');
reset role;
select t.ok((select compensation is null and status = 'cancelled' from lessons where id = t.id('LK2')), 'compensation_entered_by = tutor: staff marking absent is NOT forced to type a charge either (null = pending)');
select t.as('00000000-0000-0000-0000-00000000a702'); set role authenticated;
select staff_lessons(t.id('sa'), (select today from td), (select today from td), null, 'marked') as r3 \gset
reset role;
select t.ok((select bool_and((e->>'charge_pending')::boolean) from jsonb_array_elements(:'r3'::jsonb->'rows') e where e->>'lesson_id' in (t.id('LK1')::text, t.id('LK2')::text)), 'the list says "charge pending" (yes/no only, no amount)');
select t.as('00000000-0000-0000-0000-00000000a701'); set role authenticated;
select org_save_settings(t.id('sa'), jsonb_set(t.centre_settings(), '{lessons}', '{}'), current_date);
reset role;

-- ===================================================================== the centre's own calendar day, not the server's
select t.as('00000000-0000-0000-0000-00000000a709'); set role authenticated;
select org_save_settings(t.id('sa2'), t.centre_settings(), current_date);
reset role;
select set_config('request.jwt.claims', '', false);
update organisations set timezone = 'Pacific/Kiritimati' where id = t.id('sa2');      -- UTC+14
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('sa2'), '00000000-0000-0000-0000-00000000a706', 'Far Staff', 'staff', array['manage_timetable'], 'active');
insert into students(id, tutor_id, org_id, name) values ('00000000-0000-0000-0000-00000000a7f1', '00000000-0000-0000-0000-00000000a709', t.id('sa2'), 'Far Kid');
select (now() at time zone 'Pacific/Kiritimati')::date as far_today \gset
insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate)
  values ('00000000-0000-0000-0000-00000000a709', t.id('sa2'), '00000000-0000-0000-0000-00000000a7f1', :'far_today', '09:00', '10:00', 50),
         ('00000000-0000-0000-0000-00000000a709', t.id('sa2'), '00000000-0000-0000-0000-00000000a7f1', (:'far_today'::date + 1), '09:00', '10:00', 50);
select id as far_now from lessons where org_id = t.id('sa2') and lesson_date = :'far_today' \gset
select id as far_next from lessons where org_id = t.id('sa2') and lesson_date = (:'far_today'::date + 1) \gset
select t.as('00000000-0000-0000-0000-00000000a706'); set role authenticated;
select staff_mark_attendance(:'far_now', 'attended');
reset role;
select t.ok((select attendance = 'attended' from lessons where id = :'far_now'), 'the centre''s own timezone decides "today" (a centre at UTC+14 marks its own today)');
select pg_temp.refused('00000000-0000-0000-0000-00000000a706', format('set role authenticated; select staff_mark_attendance(%L, ''attended'')', :'far_next'), 'TOO_EARLY', 'and its tomorrow is still too early'); reset role;
select t.as('00000000-0000-0000-0000-00000000a706'); set role authenticated;
select t.fails(format($q$ update lessons set attendance = 'attended' where id = %L $q$, :'far_next'), 'the table guard uses the same day (direct write refused)');
reset role;
