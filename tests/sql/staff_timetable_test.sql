-- T3 step 6 tests: staff_timetable (the read-only centre Timetable).
-- Runs after staff_trials_test.sql in the same throwaway database (reuses the t.* helpers). Builds its own centre and made-up people.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-00000000a901', 'tt.owner@centre.test'),   ('00000000-0000-0000-0000-00000000a902', 'tt.staff@centre.test'),
  ('00000000-0000-0000-0000-00000000a903', 'tt.desk@centre.test'),    ('00000000-0000-0000-0000-00000000a904', 'tt.tutor1@centre.test'),
  ('00000000-0000-0000-0000-00000000a905', 'tt.tutor2@centre.test'),  ('00000000-0000-0000-0000-00000000a906', 'tt.outsider@centre.test'),
  ('00000000-0000-0000-0000-00000000a907', 'tt.off@centre.test'),     ('00000000-0000-0000-0000-00000000a908', 'tt.money@centre.test'),
  ('00000000-0000-0000-0000-00000000a909', 'tt.owner2@centre.test');
set role authenticated; select t.as('00000000-0000-0000-0000-00000000a901');
select t.put('tt', org_create_centre('Timetable Centre', t.centre_settings()));
select t.as('00000000-0000-0000-0000-00000000a909');
select t.put('tt2', org_create_centre('Other Timetable Centre', t.centre_settings()));
reset role; select set_config('request.jwt.claims', '', false);
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('tt'), '00000000-0000-0000-0000-00000000a902', 'Staff Sam',    'staff', array['manage_timetable'], 'active'),
  (t.id('tt'), '00000000-0000-0000-0000-00000000a903', 'Front Desk',   'staff', array['manage_students'], 'active'),
  (t.id('tt'), '00000000-0000-0000-0000-00000000a908', 'Money Only',   'staff', array['record_payments', 'view_revenue'], 'active'),
  (t.id('tt'), '00000000-0000-0000-0000-00000000a904', 'Tutor One',    'tutor', '{}', 'active'),
  (t.id('tt'), '00000000-0000-0000-0000-00000000a905', 'Tutor Two',    'tutor', '{}', 'active'),
  (t.id('tt'), '00000000-0000-0000-0000-00000000a907', 'Switched off', 'staff', array['manage_timetable'], 'disabled'),
  (t.id('tt2'), '00000000-0000-0000-0000-00000000a904', 'Tutor One elsewhere', 'tutor', '{}', 'active');
select t.put('m1', (select id from memberships where org_id = t.id('tt') and user_id = '00000000-0000-0000-0000-00000000a904'));
select t.put('m2', (select id from memberships where org_id = t.id('tt') and user_id = '00000000-0000-0000-0000-00000000a905'));
select t.put('mx', (select id from memberships where org_id = t.id('tt2') and user_id = '00000000-0000-0000-0000-00000000a904'));

create temp table td as select (now() at time zone 'Asia/Singapore')::date as today;
grant select on td to authenticated, anon;
create temp table stu (k text primary key, id uuid);
insert into stu select 's' || g, gen_random_uuid() from generate_series(1, 6) g;
grant select on stu to authenticated;
-- A REMOTE 1-to-1 centre: no branch and no room anywhere for now
insert into students(id, tutor_id, org_id, name, level, contact)
  select id, '00000000-0000-0000-0000-00000000a901', t.id('tt'), 'Kid ' || k, 'P' || right(k, 1), '9200000' || right(k, 1) from stu;
create function pg_temp.mk(p_k text, p_off int, p_by uuid, p_status text default 'scheduled') returns uuid language sql as $$
  insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, taught_by, subject)
  select '00000000-0000-0000-0000-00000000a901', t.id('tt'), stu.id, (select today from td) + p_off, '16:00', '17:30', 55, 123.45, p_status, p_by, 'Math'
  from stu where stu.k = p_k returning id $$;
select t.eq((select count(*) from branches where org_id = t.id('tt')) + (select count(*) from rooms where org_id = t.id('tt')), 0, 'the test centre has no branch and no room (remote 1-to-1)');
select t.put('LA', pg_temp.mk('s1', 0, t.id('m1')));            -- today, tutor one
select t.put('LB', pg_temp.mk('s2', 0, t.id('m2')));            -- today, tutor two (will later leave the centre)
select t.put('LC', pg_temp.mk('s3', 0, null));                  -- today, NO TUTOR
select t.put('LD', pg_temp.mk('s3', 5, null));                  -- in 5 days, NO TUTOR
select t.put('LE', pg_temp.mk('s4', 20, null));                 -- in 20 days: outside the 14-day tile
select t.put('LF', pg_temp.mk('s1', 1, t.id('m1')));            -- tomorrow
select t.put('LX', pg_temp.mk('s5', 2, null, 'cancelled'));     -- cancelled with no tutor: NOT a "no tutor" lesson
select t.put('LP', pg_temp.mk('s6', 3, t.id('m1')));            -- will be flagged postponed
select t.put('LT', pg_temp.mk('s6', 4, t.id('m1')));            -- will be flagged trial
select t.put('LM', pg_temp.mk('s2', -2, t.id('m1')));           -- two days ago, will be marked attended
select t.put('LH', pg_temp.mk('s5', 7, t.id('m1')));            -- falls on a whole-centre holiday
select t.put('LBR', pg_temp.mk('s5', 8, t.id('m1')));           -- falls on a holiday of branch Bishan only
update lessons set postponed = true where id = t.id('LP');
update lessons set trial = true where id = t.id('LT');
update lessons set attendance = 'attended' where id = t.id('LM');
-- another centre's lesson: must never show
insert into students(id, tutor_id, org_id, name) values ('00000000-0000-0000-0000-00000000f901', '00000000-0000-0000-0000-00000000a909', t.id('tt2'), 'Kid elsewhere');
insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, taught_by)
  values ('00000000-0000-0000-0000-00000000a909', t.id('tt2'), '00000000-0000-0000-0000-00000000f901', (select today from td), '10:00', '11:00', 50, 50, 'scheduled', t.id('mx'));
create function pg_temp.sess(p_user text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false) $$;
create function pg_temp.refused(p_user text, p_sql text, p_expect text, p_msg text) returns void language plpgsql as $$
declare m text := 'allowed';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  begin execute p_sql; exception when others then m := sqlerrm; end;
  if m not like p_expect || '%' then raise exception 'FAIL: % (got "%", expected "%...")', p_msg, m, p_expect; end if;
  raise notice 'PASS refused: % (%)', p_msg, m;
end $$;
create temp table before_n as select (select count(*) from lessons) as l, (select count(*) from students) as s, (select count(*) from holidays) as h;

-- ===================================================================== no holidays yet: the list
select t.as('00000000-0000-0000-0000-00000000a902'); set role authenticated;
select staff_timetable(t.id('tt'), (select today - 3 from td), (select today + 9 from td)) as r \gset
reset role;
select t.eq((:'r'::jsonb->>'total')::int, 11, 'staff see all 11 lessons of the window (every tutor, no tutor, cancelled), and not the other centre''s lesson or the one in 20 days');
select t.ok((:'r'::jsonb->>'today')::date = (select today from td), 'the response says which day the centre calls today');
select t.eq(jsonb_array_length(:'r'::jsonb->'holidays'), 0, 'no holidays yet: no band');
select t.eq((:'r'::jsonb->'counts'->>'n_notutor')::int, 2, 'no-tutor count: LC and LD (the cancelled no-tutor lesson LX is not counted)');
select t.eq((:'r'::jsonb->'counts'->>'n_cancelled')::int, 1, 'cancelled count: LX');
select t.eq(jsonb_array_length(:'r'::jsonb->'tutors'), 2, 'the tutor filter lists the two tutors');
select t.eq(jsonb_array_length(:'r'::jsonb->'branches'), 0, 'a remote 1-to-1 centre has no branches to list, and everything still works');
select t.ok(not exists (select 1 from jsonb_array_elements(:'r'::jsonb->'rows') e, jsonb_object_keys(e) k
                         where k in ('rate', 'amount', 'paid', 'compensation', 'charge_note', 'total', 'invoice_id', 'contact', 'phone', 'recipient_name') or k ~ '_cents$'),
            'no money field and no contact field in any row');
select t.ok((select e->>'tutor_name' = 'Tutor One' and e->>'student_name' = 'Kid s1' and e->>'student_level' = 'P1' and (e->>'minutes')::int = 90 and e->>'subject' = 'Math'
               and e->>'state' = 'open' and not (e->>'no_tutor')::boolean and e->'online_link' = 'null'::jsonb
               from jsonb_array_elements(:'r'::jsonb->'rows') e where e->>'lesson_id' = t.id('LA')::text),
            'a normal lesson: tutor and student names, level, 90 minutes, state open, online link not set (null)');
select t.ok((select (e->>'no_tutor')::boolean and e->>'tutor_id' is null and e->>'tutor_name' is null
               from jsonb_array_elements(:'r'::jsonb->'rows') e where e->>'lesson_id' = t.id('LC')::text), 'a lesson with nobody teaching it: no_tutor is true, tutor is null');
select t.ok((select (e->>'cancelled')::boolean and not (e->>'no_tutor')::boolean and e->>'state' = 'cancelled'
               from jsonb_array_elements(:'r'::jsonb->'rows') e where e->>'lesson_id' = t.id('LX')::text), 'a cancelled lesson is flagged cancelled and is not "no tutor"');
select t.ok((select (e->>'postponed')::boolean from jsonb_array_elements(:'r'::jsonb->'rows') e where e->>'lesson_id' = t.id('LP')::text), 'a postponed lesson is flagged');
select t.ok((select (e->>'trial')::boolean from jsonb_array_elements(:'r'::jsonb->'rows') e where e->>'lesson_id' = t.id('LT')::text), 'a trial lesson is flagged');
select t.ok((select e->>'attendance' = 'attended' and e->>'state' = 'marked' from jsonb_array_elements(:'r'::jsonb->'rows') e where e->>'lesson_id' = t.id('LM')::text), 'a marked lesson shows its attendance and state marked');
select t.ok((select e->>'state' = 'future' from jsonb_array_elements(:'r'::jsonb->'rows') e where e->>'lesson_id' = t.id('LF')::text), 'tomorrow''s lesson has state future');
select t.ok((select array_agg(e->>'lesson_id' order by ord) = array_agg(e->>'lesson_id' order by (e->>'lesson_date'), (e->>'start_time'), (e->>'student_name'), (e->>'lesson_id'))
               from jsonb_array_elements(:'r'::jsonb->'rows') with ordinality as x(e, ord)), 'rows come back in date, time, name order');

-- who may look: any owner or staff member, whatever their permissions
select t.as('00000000-0000-0000-0000-00000000a901'); set role authenticated;
select t.eq((select (staff_timetable(t.id('tt'), (select today from td), (select today from td)))->>'total')::int, 3, 'the owner sees today''s 3 lessons');
select t.as('00000000-0000-0000-0000-00000000a903');
select t.eq((select (staff_timetable(t.id('tt'), (select today from td), (select today from td)))->>'total')::int, 3, 'front desk (manage_students only) can look at the timetable');
select t.as('00000000-0000-0000-0000-00000000a908');
select t.eq((select (staff_timetable(t.id('tt'), (select today from td), (select today from td)))->>'total')::int, 3, 'staff with only money permissions can look too (plan: "view = any owner / staff"), and still see no money');
reset role;
-- everyone else gets the same NOT_FOUND
select pg_temp.refused('00000000-0000-0000-0000-00000000a904', format('set role authenticated; select staff_timetable(%L, current_date, current_date)', t.id('tt')), 'NOT_FOUND', 'a tutor cannot use the staff timetable'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a906', format('set role authenticated; select staff_timetable(%L, current_date, current_date)', t.id('tt')), 'NOT_FOUND', 'a stranger cannot use it'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a907', format('set role authenticated; select staff_timetable(%L, current_date, current_date)', t.id('tt')), 'NOT_FOUND', 'switched-off staff cannot use it'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a909', format('set role authenticated; select staff_timetable(%L, current_date, current_date)', t.id('tt')), 'NOT_FOUND', 'the owner of ANOTHER centre cannot see this centre''s timetable'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a902', format('set role authenticated; select staff_timetable(%L, current_date, current_date)', gen_random_uuid()), 'NOT_FOUND', 'an unknown organisation id'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-0000000000a1', format('set role authenticated; select staff_timetable(%L, current_date, current_date)', t.id('tt')), 'NOT_FOUND', 'a solo tutor cannot use it'); reset role;
select org_personal('00000000-0000-0000-0000-0000000000a1') as tina_solo \gset
select pg_temp.refused('00000000-0000-0000-0000-0000000000a1', format('set role authenticated; select staff_timetable(%L, current_date, current_date)', :'tina_solo'), 'NOT_FOUND', 'a solo organisation has no staff timetable'); reset role;
select pg_temp.refused('00000000-0000-0000-0000-00000000a902', format('set role anon; select staff_timetable(%L, current_date, current_date)', t.id('tt')), 'permission denied', 'a signed-out visitor cannot call it'); reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.refused('00000000-0000-0000-0000-00000000a902', format('set role authenticated; select set_config(''request.jwt.claims'', '''', false); select staff_timetable(%L, current_date, current_date)', t.id('tt')), 'NOT_FOUND', 'an authenticated role with no user id is refused'); reset role;

-- ===================================================================== filters
select t.as('00000000-0000-0000-0000-00000000a902'); set role authenticated;
select t.eq((select (staff_timetable(t.id('tt'), (select today - 3 from td), (select today + 9 from td), t.id('m2')))->>'total')::int, 1, 'filter by tutor: tutor two has 1 lesson');
select t.eq((select (staff_timetable(t.id('tt'), (select today - 3 from td), (select today + 9 from td), t.id('m1')))->>'total')::int, 7, 'filter by tutor: tutor one has 7 lessons');
select t.eq((select (staff_timetable(t.id('tt'), (select today - 3 from td), (select today + 9 from td), null, null, (select id from stu where k = 's3')))->>'total')::int, 2, 'filter by student: Kid s3 has 2 lessons');
select t.eq((select (staff_timetable(t.id('tt'), (select today - 3 from td), (select today + 9 from td), null, null, null, 1, true))->>'total')::int, 2, 'filter "no tutor": the 2 lessons nobody teaches');
select t.ok((select bool_and((e->>'no_tutor')::boolean) from jsonb_array_elements((staff_timetable(t.id('tt'), (select today - 3 from td), (select today + 9 from td), null, null, null, 1, true))->'rows') e), 'every row of the no-tutor filter is a no-tutor lesson');
select t.eq((select (staff_timetable(t.id('tt'), (select today - 3 from td), (select today + 9 from td), t.id('m1'), null, (select id from stu where k = 's1')))->>'total')::int, 2, 'filters combine: tutor one and Kid s1 = LA and LF');
select t.eq((select (staff_timetable(t.id('tt'), (select today from td), (select today from td), null, null, null, 1, false, 2))->>'total')::int, 3, 'paging: the total stays 3 whatever the page');
select t.eq((select jsonb_array_length((staff_timetable(t.id('tt'), (select today - 3 from td), (select today + 9 from td), null, null, null, 1, false, 4))->'rows')), 4, 'paging: page 1 of size 4 has 4 rows');
select t.eq((select jsonb_array_length((staff_timetable(t.id('tt'), (select today - 3 from td), (select today + 9 from td), null, null, null, 3, false, 4))->'rows')), 3, 'paging: page 3 of size 4 has the last 3 rows');
select t.eq((select jsonb_array_length((staff_timetable(t.id('tt'), (select today - 3 from td), (select today + 9 from td), null, null, null, 9, false, 4))->'rows')), 0, 'paging: a page past the end is empty, not an error');
select t.eq((select jsonb_array_length((staff_timetable(t.id('tt'), (select today - 3 from td), (select today + 9 from td)))->'students')), 5, 'the student filter lists the 5 students who have lessons in the window');
select t.eq((select jsonb_array_length((staff_timetable(t.id('tt'), (select today + 19 from td), (select today + 21 from td)))->'students')), 1, 'the student filter follows the window (only Kid s4 in 20 days)');
select t.fails($q$ select staff_timetable(t.id('tt'), current_date - 100, current_date) $q$, 'asking for more than 62 days');
select t.fails($q$ select staff_timetable(t.id('tt'), current_date, current_date - 1) $q$, 'a backwards range');
select t.fails($q$ select staff_timetable(t.id('tt'), null, current_date) $q$, 'a missing date');
select t.fails($q$ select staff_timetable(t.id('tt'), current_date, current_date, null, null, null, 1, false, 101) $q$, 'a page size over 100');
select t.fails($q$ select staff_timetable(t.id('tt'), current_date, current_date, null, null, null, 0) $q$, 'page 0');
-- another centre's ids are not found, never silently ignored
select t.fails(format($q$ select staff_timetable(%L, current_date, current_date, %L) $q$, t.id('tt'), t.id('mx')), 'a tutor filter naming a tutor of ANOTHER centre');
select t.fails(format($q$ select staff_timetable(%L, current_date, current_date, null, null, %L) $q$, t.id('tt'), '00000000-0000-0000-0000-00000000f901'::uuid), 'a student filter naming a student of ANOTHER centre');
select t.fails($q$ select staff_timetable(t.id('tt'), current_date, current_date, null, gen_random_uuid()) $q$, 'a branch filter naming nothing in this centre');
select t.fails($q$ select staff_timetable(t.id('tt'), current_date, current_date, gen_random_uuid()) $q$, 'a tutor filter naming nobody');
reset role;

-- ===================================================================== a tutor who has left
update memberships set status = 'disabled' where id = t.id('m2');
select t.as('00000000-0000-0000-0000-00000000a902'); set role authenticated;
select staff_timetable(t.id('tt'), (select today from td), (select today from td)) as r3 \gset
reset role;
select t.ok((select e->>'tutor_name' = 'Former tutor' and not (e->>'no_tutor')::boolean from jsonb_array_elements(:'r3'::jsonb->'rows') e where e->>'lesson_id' = t.id('LB')::text),
            'a switched-off tutor''s lesson says "Former tutor" (it is not "no tutor": somebody must still pick a replacement, but it is not unassigned)');
select t.eq(jsonb_array_length(:'r3'::jsonb->'tutors'), 1, 'and the tutor filter no longer offers the person who left');

-- ===================================================================== holidays
insert into branches(id, org_id, name) values ('00000000-0000-0000-0000-00000000b901', t.id('tt'), 'Bishan');
insert into branches(id, org_id, name) values ('00000000-0000-0000-0000-00000000b902', t.id('tt2'), 'Elsewhere');
insert into holidays(org_id, branch_id, name, starts_on, ends_on) values
  (t.id('tt'), null, 'Deepavali', (select today + 7 from td), (select today + 7 from td)),
  (t.id('tt'), '00000000-0000-0000-0000-00000000b901', 'Bishan renovation', (select today + 8 from td), (select today + 9 from td)),
  (t.id('tt'), null, 'Long ago', (select today - 60 from td), (select today - 58 from td)),
  (t.id('tt2'), null, 'Other centre holiday', (select today from td), (select today from td));
select t.as('00000000-0000-0000-0000-00000000a903'); set role authenticated;
select staff_timetable(t.id('tt'), (select today - 3 from td), (select today + 9 from td)) as r4 \gset
select staff_timetable(t.id('tt'), (select today - 3 from td), (select today + 9 from td), null, '00000000-0000-0000-0000-00000000b901') as r5 \gset
select staff_timetable(t.id('tt'), (select today - 3 from td), (select today + 9 from td), null, '00000000-0000-0000-0000-00000000b901', null, 1, true) as r6 \gset
reset role;
select t.eq(jsonb_array_length(:'r4'::jsonb->'holidays'), 2, 'the band lists the 2 holidays in the window (not the one 60 days ago, not the other centre''s)');
select t.ok((select h->>'name' = 'Deepavali' and h->>'branch_id' is null from jsonb_array_elements(:'r4'::jsonb->'holidays') h limit 1), 'a whole-centre holiday has no branch');
select t.ok((select h->>'branch_name' = 'Bishan' from jsonb_array_elements(:'r4'::jsonb->'holidays') h where h->>'name' = 'Bishan renovation'), 'a branch holiday names its branch');
select t.ok((select e->>'holiday' = 'Deepavali' from jsonb_array_elements(:'r4'::jsonb->'rows') e where e->>'lesson_id' = t.id('LH')::text), 'a lesson on a whole-centre holiday is flagged with its name');
select t.ok((select e->>'holiday' is null from jsonb_array_elements(:'r4'::jsonb->'rows') e where e->>'lesson_id' = t.id('LBR')::text), 'with no branch chosen, a branch-only holiday does not flag a lesson (lessons have no branch)');
select t.ok((select e->>'holiday' = 'Bishan renovation' from jsonb_array_elements(:'r5'::jsonb->'rows') e where e->>'lesson_id' = t.id('LBR')::text), 'with that branch chosen, its holiday does flag the lesson');
select t.eq((:'r5'::jsonb->>'total')::int, (:'r4'::jsonb->>'total')::int, 'choosing a branch does not hide lessons (lessons carry no branch yet)');
select t.eq((:'r4'::jsonb->'counts'->>'n_holiday')::int, 1, 'holiday-lesson count: 1 with no branch chosen');
select t.eq((:'r5'::jsonb->'counts'->>'n_holiday')::int, 2, 'holiday-lesson count: 2 with the branch chosen');
select t.eq(jsonb_array_length(:'r4'::jsonb->'branches'), 1, 'the branch list has the one branch of this centre (not Elsewhere)');
select t.eq((:'r6'::jsonb->>'total')::int, 2, 'branch filter and no-tutor filter together still work');
-- a holiday spanning the whole window, starting before it, still shows
insert into holidays(org_id, name, starts_on, ends_on) values (t.id('tt'), 'School break', (select today - 30 from td), (select today + 30 from td));
select t.as('00000000-0000-0000-0000-00000000a902'); set role authenticated;
select t.eq((select jsonb_array_length((staff_timetable(t.id('tt'), (select today from td), (select today from td)))->'holidays')), 1, 'a long holiday that started before the window still shows');
select t.ok((select bool_and(e->>'holiday' = 'School break') from jsonb_array_elements((staff_timetable(t.id('tt'), (select today from td), (select today from td)))->'rows') e), 'and flags every lesson inside it');
reset role;

-- ===================================================================== it agrees with the Home tile, and it only reads
select t.as('00000000-0000-0000-0000-00000000a902'); set role authenticated;
select t.eq((staff_home(t.id('tt'))->>'no_tutor_14d')::int,
            (select (staff_timetable(t.id('tt'), (select today from td), (select today + 13 from td), null, null, null, 1, true))->>'total')::int,
            'the Home "no tutor, next 14 days" number equals the list the tile opens');
reset role;
select t.ok((select l = (select count(*) from lessons) and s = (select count(*) from students) and h + 5 = (select count(*) from holidays) from before_n), 'reading the timetable changed nothing (lessons and students the same)');
select t.ok((select provolatile = 's' and prosecdef from pg_proc where oid = 'public.staff_timetable(uuid,date,date,uuid,uuid,uuid,int,boolean,int)'::regprocedure), 'the function is STABLE (cannot write) and SECURITY DEFINER');
select t.ok(not has_function_privilege('anon', 'public.staff_timetable(uuid,date,date,uuid,uuid,uuid,int,boolean,int)', 'execute'), 'anon has no execute right');
select t.ok(has_function_privilege('authenticated', 'public.staff_timetable(uuid,date,date,uuid,uuid,uuid,int,boolean,int)', 'execute'), 'signed-in users have execute right (the function itself checks membership)');
select 'PASS staff_timetable: all checks' as done;
