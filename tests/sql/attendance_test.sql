-- Slice A tests: attendance/trial columns and the monthly active-student count. Runs after org_test.sql in the same
-- throwaway database (reuses its t.* helpers and the 'centre' / 'tina_org' organisations). Made-up people only.
\set ON_ERROR_STOP on
set client_min_messages = notice;

-- ===================================================================== a centre with one student per situation
-- (inserted as the database owner; org_id is given explicitly, tutor = the centre owner c1)
create temp table sx (k text primary key, id uuid);
grant all on sx to authenticated, service_role;
insert into sx select 's' || g, gen_random_uuid() from generate_series(1, 7) g;
insert into students(id, tutor_id, org_id, name) select id, '00000000-0000-0000-0000-0000000000c1', t.id('centre'), 'Att ' || k from sx;
create function pg_temp.lesson(p_k text, p_date date, p_att text, p_trial boolean default false) returns void language sql as $$
  insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, attendance, trial)
  select '00000000-0000-0000-0000-0000000000c1', t.id('centre'), sx.id, p_date, '16:00', '17:00', 50, p_att, p_trial from sx where sx.k = p_k $$;
select pg_temp.lesson('s1', '2026-11-03', 'attended');
select pg_temp.lesson('s1', '2026-11-10', 'attended');                  -- same student again: counted once
select pg_temp.lesson('s2', '2026-11-30', 'absent');                    -- last day of the month: counts
select pg_temp.lesson('s3', '2026-11-15', 'late_cancelled');            -- late cancellation: counts
select pg_temp.lesson('s4', '2026-11-10', 'cancelled_early');           -- cancelled in good time: doesn't count
select pg_temp.lesson('s5', '2026-11-05', 'attended', true);            -- trial lesson: doesn't count
select pg_temp.lesson('s6', '2026-10-31', 'attended');                  -- the day before the month
select pg_temp.lesson('s6', '2026-12-01', 'attended');                  -- the day after the month
select pg_temp.lesson('s7', '2026-11-08', null);                        -- attendance not marked yet: doesn't count

select t.eq(org_active_students_in_month(t.id('centre'), '2026-11-01'), 3, 'November: attended + absent + late-cancelled, each student once');
select t.eq(org_active_students_in_month(t.id('centre'), '2026-11-17'), 3, 'any day in the month picks the same month');
select t.eq(org_active_students_in_month(t.id('centre'), '2026-10-01'), 1, 'October: only the 31st counts (month boundary)');
select t.eq(org_active_students_in_month(t.id('centre'), '2026-12-25'), 1, 'December: only the 1st counts (month boundary)');
select t.eq(org_active_students_in_month(t.id('centre'), '2027-01-01'), 0, 'a month with no lessons = 0');

-- a trial student who attends a second, non-trial lesson becomes active
select pg_temp.lesson('s5', '2026-11-20', 'attended');
select t.eq(org_active_students_in_month(t.id('centre'), '2026-11-01'), 4, 'trial student with a later real lesson counts');

-- ===================================================================== organisations are separate
select t.ok(org_active_students_in_month(t.id('tina_org'), '2026-11-01') = 0, 'solo tutor lessons (no attendance) aren''t counted and never leak into the centre');
select t.eq(org_active_students_in_month('00000000-0000-0000-0000-00000000dead', '2026-11-01'), 0, 'unknown organisation = 0');

-- ===================================================================== values and permissions
select t.fails($q$ update lessons set attendance = 'maybe' where org_id = t.id('centre') $q$, 'an attendance value outside the list');
select t.as('00000000-0000-0000-0000-0000000000a1'); set role authenticated;
select t.fails($q$ select org_active_students_in_month(t.id('tina_org'), '2026-11-01') $q$, 'a signed-in tutor calling the count directly');
reset role;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only
set role anon;
select t.fails($q$ select org_active_students_in_month(t.id('centre'), '2026-11-01') $q$, 'an anonymous caller');
reset role;
set role service_role;
select t.eq(org_active_students_in_month(t.id('centre'), '2026-11-01'), 4, 'the server (service role) can call it');
reset role;

-- solo pages that don't know about the new columns still work: an insert without them, trial defaults to false
select t.as('00000000-0000-0000-0000-0000000000a1'); set role authenticated;
insert into lessons(tutor_id, student_id, lesson_date, start_time, end_time, rate)
  select '00000000-0000-0000-0000-0000000000a1', id, '2026-11-12', '10:00', '11:00', 40 from students where org_id = t.id('tina_org') limit 1;
reset role;
select t.ok((select not trial and attendance is null from lessons where org_id = t.id('tina_org') and lesson_date = '2026-11-12'), 'old-style lesson insert: trial = false, attendance empty');

\echo ALL ATTENDANCE TESTS PASSED
