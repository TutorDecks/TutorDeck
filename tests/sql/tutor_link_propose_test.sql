-- T6 steps 5 and 6 tests: the online lesson link, and tutors who ASK at a tutors_propose centre (db/migration_tutor_link_propose.sql).
-- Link: https only / 500 characters / not 'javascript:', who may set it (staff always, a tutor only with the switch, only their own student / lesson), the effective link everywhere it is shown,
-- a link change is not a counted schedule change. Requests: EVERY tutor action (move, put back, cancel, add a lesson, add / change / stop a slot, create lessons, set a link) becomes a request
-- at tutors_propose and changes nothing; every rule is checked when it is asked for AND again when it is approved; approving twice applies once; declining needs a reason; expiry; the tutor
-- taking a request back; the monthly limit counts waiting requests; who may answer (manage_timetable only; another centre / a tutor / a parent / a solo tutor = NOT_FOUND); no table access;
-- no money anywhere a tutor can read. Runs after tutor_own_lessons_test.sql in the same throwaway database (reuses the t.* helpers). All names are FAKE.
-- (tutor_moves_test.sql and tutor_own_lessons_test.sql still say "tutors_propose is refused": that was true when they ran, before this migration. run.sh runs them in that order.)
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-000000a80001', 'lp.owner@centre.test'),  ('00000000-0000-0000-0000-000000a80002', 'lp.staff@centre.test'),
  ('00000000-0000-0000-0000-000000a80003', 'lp.money@centre.test'),  ('00000000-0000-0000-0000-000000a80004', 'lp.tutor1@centre.test'),
  ('00000000-0000-0000-0000-000000a80005', 'lp.tutor2@centre.test'), ('00000000-0000-0000-0000-000000a80006', 'lp.solo@centre.test'),
  ('00000000-0000-0000-0000-000000a80007', 'lp.off@centre.test'),    ('00000000-0000-0000-0000-000000a80008', 'lp.parent@centre.test'),
  ('00000000-0000-0000-0000-000000a80009', 'lp.owner2@centre.test'), ('00000000-0000-0000-0000-000000a8000a', 'lp.tutor4@centre.test'),
  ('00000000-0000-0000-0000-000000a8000b', 'lp.staff2@centre.test'), ('00000000-0000-0000-0000-000000a8000c', 'lp.tutor5@centre.test');
\set OWNER '00000000-0000-0000-0000-000000a80001'
\set STAFF '00000000-0000-0000-0000-000000a80002'
\set MONEY '00000000-0000-0000-0000-000000a80003'
\set T1 '00000000-0000-0000-0000-000000a80004'
\set T2 '00000000-0000-0000-0000-000000a80005'
\set SOLO '00000000-0000-0000-0000-000000a80006'
\set OFF '00000000-0000-0000-0000-000000a80007'
\set PARENT '00000000-0000-0000-0000-000000a80008'
\set OWNER2 '00000000-0000-0000-0000-000000a80009'
\set T4 '00000000-0000-0000-0000-000000a8000a'
\set STAFF2 '00000000-0000-0000-0000-000000a8000b'
\set T5 '00000000-0000-0000-0000-000000a8000c'

-- the centre's clock is chosen so that LOCAL time of day "now" is about 12:xx all the time (no flakiness around midnight); Etc/GMT-k means UTC+k
create temp table td as select (12 - extract(hour from (now() at time zone 'UTC')))::int as k0;
create temp table tz as
  select case when k > 0 then 'Etc/GMT-' || k when k < 0 then 'Etc/GMT+' || (-k) else 'Etc/GMT' end as name from (select ((k0 + 12 + 24) % 24) - 12 as k from td) x;
grant select on td, tz to authenticated, anon;

set role authenticated; select t.as(:'OWNER');
select t.put('lp', org_create_centre('Link Propose Centre', t.centre_settings()));
select t.as(:'OWNER2');
select t.put('lp2', org_create_centre('Other Propose Centre', t.centre_settings()));
reset role; select set_config('request.jwt.claims', '', false);
select org_personal(:'SOLO');
update organisations set timezone = (select name from tz) where id = t.id('lp');
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('lp'), :'STAFF',  'Staff Sam',   'staff', array['manage_timetable'], 'active'),
  (t.id('lp'), :'MONEY',  'Staff Money', 'staff', array['issue_invoices'], 'active'),
  (t.id('lp'), :'T1',     'Tutor One',   'tutor', '{}', 'active'),
  (t.id('lp'), :'T2',     'Tutor Two',   'tutor', '{}', 'active'),
  (t.id('lp'), :'OFF',    'Switched off', 'tutor', '{}', 'active'),
  (t.id('lp'), :'PARENT', 'A Parent',    'parent', '{}', 'active'),
  (t.id('lp'), :'T5',     'Tutor Five',  'tutor', '{}', 'active'),
  (t.id('lp2'), :'T4',    'Tutor Four elsewhere', 'tutor', '{}', 'active'),
  (t.id('lp2'), :'STAFF2', 'Staff elsewhere', 'staff', array['manage_timetable'], 'active');
select t.put('m1', (select id from memberships where org_id = t.id('lp') and user_id = :'T1'));
select t.put('m2', (select id from memberships where org_id = t.id('lp') and user_id = :'T2'));
select t.put('m5', (select id from memberships where org_id = t.id('lp') and user_id = :'T5'));

insert into students(id, tutor_id, org_id, name, level, contact, online_link) values
  ('00000000-0000-0000-0000-000000a80101', :'OWNER', t.id('lp'), 'Ann',  'P1', '91110001', 'https://meet.example.com/ann-default'),
  ('00000000-0000-0000-0000-000000a80102', :'OWNER', t.id('lp'), 'Ben',  'P2', '91110002', null),
  ('00000000-0000-0000-0000-000000a80103', :'OWNER', t.id('lp'), 'Cal (not assigned)', 'P3', '91110003', null),
  ('00000000-0000-0000-0000-000000a80105', :'OWNER', t.id('lp'), 'Eve (new, no price yet)', 'P5', '91110005', null),
  ('00000000-0000-0000-0000-000000a80106', :'OWNER', t.id('lp'), 'Fay', 'P6', '91110006', null),
  ('00000000-0000-0000-0000-000000a80109', :'OWNER', t.id('lp'), 'Zed (tutor five)', 'S2', '91110009', null),
  ('00000000-0000-0000-0000-000000a801f1', :'OWNER2', t.id('lp2'), 'Kid elsewhere', 'P1', '91119999', null);
insert into student_tutors(org_id, student_id, membership_id) values
  (t.id('lp'), '00000000-0000-0000-0000-000000a80101', t.id('m1')), (t.id('lp'), '00000000-0000-0000-0000-000000a80102', t.id('m2')),
  (t.id('lp'), '00000000-0000-0000-0000-000000a80105', t.id('m1')), (t.id('lp'), '00000000-0000-0000-0000-000000a80106', t.id('m1')),
  (t.id('lp'), '00000000-0000-0000-0000-000000a80109', t.id('m5'));
\set A '00000000-0000-0000-0000-000000a80101'
\set B '00000000-0000-0000-0000-000000a80102'
\set C '00000000-0000-0000-0000-000000a80103'
\set E '00000000-0000-0000-0000-000000a80105'
\set F '00000000-0000-0000-0000-000000a80106'
\set Z '00000000-0000-0000-0000-000000a80109'
\set ELSE '00000000-0000-0000-0000-000000a801f1'
-- a STAFF-made lesson that gives Ann a price to copy (a tutor never types one)
insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, taught_by, created_at) values
  (:'OWNER', t.id('lp'), :'A', current_date - 30, '10:00', '11:00', 12.50, 12.50, 'done', t.id('m1'), now() - interval '10 days');
-- Fay: a staff weekly slot (the generator's source), on the weekday of 8 days from the centre's today
create function pg_temp.lday(n int) returns date language sql stable as $$ select ((now() at time zone (select name from tz))::date + n) $$;
create function pg_temp.wd(n int) returns int language sql stable as $$ select extract(isodow from pg_temp.lday(n))::int - 1 $$;
insert into recurring_slots(id, tutor_id, org_id, student_id, weekday, start_time, end_time, rate, subject, active, taught_by, created_at) values
  ('00000000-0000-0000-0000-000000a80201', :'OWNER', t.id('lp'), :'F', pg_temp.wd(8), '16:00', '17:00', 40.00, 'English', true, t.id('m1'), now() - interval '3 days'),
  ('00000000-0000-0000-0000-000000a80202', :'OWNER', t.id('lp'), :'A', pg_temp.wd(23), '09:00', '10:00', 12.50, 'Maths', true, t.id('m1'), now() - interval '3 days'),
  ('00000000-0000-0000-0000-000000a80203', :'OWNER', t.id('lp'), :'A', pg_temp.wd(60), '07:00', '08:00', 12.50, 'Maths', true, t.id('m1'), now() - interval '3 days');
select t.put('S_F', '00000000-0000-0000-0000-000000a80201'); select t.put('S_R', '00000000-0000-0000-0000-000000a80202'); select t.put('S_X', '00000000-0000-0000-0000-000000a80203');

-- ---- helpers (session-local)
create function pg_temp.ldate(h numeric) returns date language sql stable as $$ select ((now() + h * interval '1 hour') at time zone (select name from tz))::date $$;
create function pg_temp.ltime(h numeric) returns time language sql stable as $$ select date_trunc('minute', ((now() + h * interval '1 hour') at time zone (select name from tz))::time)::time $$;
create function pg_temp.settings(p_org text, p_owner text, p_lessons jsonb, p_calendar jsonb default '{}') returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_owner, 'role', 'authenticated')::text, false);
  set local role authenticated;
  perform org_save_settings(t.id(p_org), jsonb_set(jsonb_set(jsonb_set(t.centre_settings(), '{billing,model}', '"postpaid_lessons"'), '{lessons}', p_lessons), '{calendar}', p_calendar), current_date);
  reset role;
end $$;
create function pg_temp.call(p_user text, p_sql text) returns text language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claims', case when p_user is null then '' else json_build_object('sub', p_user, 'role', 'authenticated')::text end, false);
  set local role authenticated;
  begin execute p_sql into r; exception when others then r := 'ERR:' || sqlerrm; end;
  reset role;
  return r;
end $$;
create function pg_temp.expect(p_user text, p_sql text, p_expect text, p_msg text) returns text language plpgsql as $$
declare r text := pg_temp.call(p_user, p_sql);
begin
  if p_expect = 'ok' then
    if r like 'ERR:%' then raise exception 'FAIL: % (refused: %)', p_msg, r; end if;
  elsif r is null or r not like 'ERR:' || p_expect || '%' then
    raise exception 'FAIL: % (got "%", expected "%...")', p_msg, r, p_expect; end if;
  raise notice 'PASS %: %', case when p_expect = 'ok' then 'allowed' else 'refused ' || p_expect end, p_msg;
  return r;
end $$;
create table pg_temp.said(txt text);
create function pg_temp.say(p text) returns text language plpgsql as $$ begin insert into pg_temp.said values (p); return p; end $$;
create function pg_temp.keys(j jsonb) returns setof text language sql as $$
  with recursive r(v, k) as (
    select j, null::text
    union all
    select c.value, c.key from r, lateral (
      select e.key, e.value from jsonb_each(case when jsonb_typeof(r.v) = 'object' then r.v else '{}'::jsonb end) e
      union all
      select null::text, a.value from jsonb_array_elements(case when jsonb_typeof(r.v) = 'array' then r.v else '[]'::jsonb end) a) c)
  select k from r where k is not null $$;
grant all on pg_temp.said to public;
-- a staff-made lesson for tutor one (superuser insert = what the staff screens make): tag, student, days from the centre's today, start, end
create function pg_temp.mk(p_tag text, p_student text, p_day int, p_start text default '10:00', p_end text default '11:00', p_mem text default null) returns uuid language plpgsql as $$
declare id uuid;
begin
  perform set_config('request.jwt.claims', '', false);        -- a superuser insert, as the staff screens make it
  insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, subject, rate, amount, status, taught_by)
  values ('00000000-0000-0000-0000-000000a80001', t.id('lp'), p_student::uuid, pg_temp.lday(p_day), p_start::time, p_end::time, 'Maths', 12.50, 12.50, 'scheduled', coalesce(p_mem::uuid, t.id('m1')))
  returning lessons.id into id;
  perform t.put(p_tag, id);
  return id;
end $$;
create function pg_temp.lk(p_id uuid) returns lessons language sql as $$ select l from lessons l where l.id = p_id $$;
-- ask (as a tutor) and keep the request id; answer text
create function pg_temp.ask(p_user text, p_tag text, p_sql text) returns text language plpgsql as $$
declare r text := pg_temp.call(p_user, p_sql);
begin
  if r like 'ERR:%' then raise exception 'FAIL: % was refused: %', p_tag, r; end if;
  perform pg_temp.say(r);
  if (r::jsonb->>'requested')::boolean is not true then raise exception 'FAIL: % did not make a request: %', p_tag, r; end if;
  perform t.put(p_tag, (r::jsonb->>'request_id')::uuid);
  raise notice 'PASS requested: %', p_tag;
  return r;
end $$;
create function pg_temp.rq(p_tag text) returns schedule_requests language sql as $$ select r from schedule_requests r where r.id = t.id(p_tag) $$;
create function pg_temp.decide(p_user text, p_tag text, p_decision text, p_reason text default null) returns text language sql as $$
  select pg_temp.call(p_user, format('select staff_decide_request(%L, %L, %L)', t.id(p_tag), p_decision, p_reason)) $$;
create function pg_temp.audits(p_action text) returns bigint language sql as $$ select count(*) from audit_log where org_id = t.id('lp') and action = p_action $$;
grant execute on all functions in schema pg_temp to public;
select set_config('request.jwt.claims', '', false);

-- ===================================================================== 1. the link: validation, who may set it, what is shown (direct centre)
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"postpone":true,"cancel":true,"link":false}}');
select t.put('K1', pg_temp.mk('K1', :'A', 30)); select t.put('K2', pg_temp.mk('K2', :'A', 31));
select pg_temp.expect(:'T1', format('select tutor_set_link(%L, null, ''https://meet.example.com/x'')', :'A'), 'SWITCH_OFF', 'link switch off: a tutor can''t set the student link');
select pg_temp.expect(:'T1', format('select tutor_set_link(null, %L, ''https://meet.example.com/x'')', t.id('K1')), 'SWITCH_OFF', 'link switch off: a tutor can''t set a lesson link');
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"admin_only","tutors_edit":{"link":true}}');
select pg_temp.expect(:'T1', format('select tutor_set_link(%L, null, ''https://meet.example.com/x'')', :'A'), 'NOT_ALLOWED', 'admin_only (link switch on): refused');
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"postpone":true,"cancel":true,"link":true},"max_changes_per_month":1}');
select pg_temp.expect(:'T1', format('select tutor_set_link(%L, null, ''https://meet.example.com/new'')', :'A'), 'ok', 'link on: a tutor sets their student''s link');
select t.ok((select online_link from students where id = :'A'::uuid) = 'https://meet.example.com/new', 'the student''s link is saved');
select t.ok((select (after->>'online_link') = 'https://meet.example.com/new' and before->>'online_link' = 'https://meet.example.com/ann-default' and actor = :'T1'::uuid
               from audit_log where action = 'tutor_set_link' and row_id = :'A' order by id desc limit 1), 'audited with the old and the new link, by the tutor');
select pg_temp.expect(:'T1', format('select tutor_set_link(null, %L, ''https://meet.example.com/lesson-1'')', t.id('K1')), 'ok', 'a tutor sets the link of ONE of their lessons');
select pg_temp.expect(:'T1', format('select tutor_set_link(null, %L, ''https://meet.example.com/lesson-2'')', t.id('K2')), 'ok', 'and of another, with a monthly limit of 1 (a link is not a counted schedule change)');
select pg_temp.expect(:'T1', format('select tutor_cancel_lesson(%L, ''checking the limit still has room'')', t.id('K2')), 'ok', 'the one counted change of the month is still available after four link changes');
select t.ok(pg_temp.audits('tutor_set_link') = 3, 'three link changes audited');
-- what is saved is the effective link
select pg_temp.call(:'T1', format('select tutor_my_schedule(%L, %L)', pg_temp.lday(29), pg_temp.lday(32))) as sch \gset
select t.ok((select e->>'online_link' = 'https://meet.example.com/lesson-1' and e->>'lesson_link' = 'https://meet.example.com/lesson-1' from jsonb_array_elements((:'sch'::jsonb)->'lessons') e where e->>'lesson_id' = t.id('K1')::text),
            'My schedule shows the lesson''s own link, and says it is the lesson''s');
select t.ok((select (o->>'can_link')::boolean and not (o->>'proposes')::boolean from jsonb_array_elements((:'sch'::jsonb)->'orgs') o), 'the centre entry says: you may set links; you act directly');
-- nothing changes when the link is the same
select pg_temp.expect(:'T1', format('select tutor_set_link(null, %L, ''https://meet.example.com/lesson-1'')', t.id('K1')), 'ok', 'the same link again');
select t.ok(pg_temp.audits('tutor_set_link') = 3, 'the same link again writes no audit row');
select t.ok(pg_temp.call(:'T1', format('select (tutor_set_link(null, %L, ''https://meet.example.com/lesson-1''))->>''changed''', t.id('K1'))) = 'false', 'and says changed = false');
select pg_temp.expect(:'T1', format('select tutor_set_link(null, %L, '''')', t.id('K1')), 'ok', 'clearing a lesson''s own link');
select t.ok((select online_link is null from lessons where id = t.id('K1')), 'cleared (the student''s link applies again)');
select pg_temp.call(:'T1', format('select jsonb_agg(to_jsonb(x)) from tutor_lesson_links(%L, %L) x', pg_temp.lday(29), pg_temp.lday(32))) as lks \gset
select t.ok((select bool_or(e->>'lesson_id' = t.id('K1')::text and e->>'online_link' = 'https://meet.example.com/new') and bool_or(e->>'lesson_id' = t.id('K2')::text and e->>'online_link' = 'https://meet.example.com/lesson-2')
               from jsonb_array_elements(:'lks'::jsonb) e), 'tutor_lesson_links: the lesson''s own link where there is one, else the student''s');
-- validation (every refusal says BAD_LINK, nothing is written)
create function pg_temp.bad(p_link text, p_msg text) returns void language plpgsql as $$
begin
  perform pg_temp.expect('00000000-0000-0000-0000-000000a80004', format('select tutor_set_link(%L, null, %L)', '00000000-0000-0000-0000-000000a80101', p_link), 'BAD_LINK', 'a tutor: ' || p_msg);
  perform pg_temp.expect('00000000-0000-0000-0000-000000a80004', format('select tutor_set_link(null, %L, %L)', t.id('K1'), p_link), 'BAD_LINK', 'a tutor, one lesson: ' || p_msg);
  perform pg_temp.expect('00000000-0000-0000-0000-000000a80002', format('select staff_set_lesson_link(%L, %L, %L)', t.id('lp'), t.id('K1'), p_link), 'BAD_LINK', 'staff, one lesson: ' || p_msg);
end $$;
grant execute on all functions in schema pg_temp to public;
select pg_temp.bad('http://meet.example.com/x', 'http:// is refused');
select pg_temp.bad('javascript:alert(1)', 'javascript: is refused');
select pg_temp.bad('JAVASCRIPT:alert(1)', 'JAVASCRIPT: is refused');
select pg_temp.bad('data:text/html,<b>x</b>', 'data: is refused');
select pg_temp.bad('ftp://meet.example.com/x', 'ftp:// is refused');
select pg_temp.bad('//meet.example.com/x', 'a link with no scheme is refused');
select pg_temp.bad('meet.example.com/x', 'a bare address is refused');
select pg_temp.bad('https://meet.example.com/a b', 'a link with a space is refused');
select pg_temp.bad(E'https://meet.example.com/a\nb', 'a link with a line break is refused');
select pg_temp.bad('https://', 'https:// alone is refused');
select pg_temp.bad('https://' || repeat('a', 493), '501 characters is refused');
select pg_temp.expect(:'T1', format('select tutor_set_link(null, %L, %L)', t.id('K1'), 'https://' || repeat('a', 492)), 'ok', 'exactly 500 characters is fine');
select t.ok((select length(online_link) = 500 from lessons where id = t.id('K1')), 'saved in full');
select pg_temp.expect(:'T1', format('select tutor_set_link(null, %L, ''https://meet.example.com/ok?room=7&x=1#top'')', t.id('K1')), 'ok', 'a link with a query and a fragment is fine');
-- the table itself refuses a bad link too (a staff screen that writes the table, or a mistake)
select t.fails(format($q$ update lessons set online_link = 'javascript:alert(1)' where id = %L $q$, t.id('K1')), 'the lessons table refuses a javascript: link');
select t.fails(format($q$ update lessons set online_link = 'http://x.test/y' where id = %L $q$, t.id('K1')), 'the lessons table refuses an http:// link');
select t.fails(format($q$ update students set online_link = 'javascript:alert(1)' where id = %L $q$, :'A'), 'the students table refuses a javascript: link');
-- who is refused: always NOT_FOUND
create function pg_temp.lnf(p_user text, p_who text) returns void language plpgsql as $$
begin
  perform pg_temp.expect(p_user, format('select tutor_set_link(%L, null, ''https://meet.example.com/x'')', '00000000-0000-0000-0000-000000a80101'), 'NOT_FOUND', p_who || ': the student link');
  perform pg_temp.expect(p_user, format('select tutor_set_link(null, %L, ''https://meet.example.com/x'')', t.id('K1')), 'NOT_FOUND', p_who || ': a lesson link');
end $$;
grant execute on all functions in schema pg_temp to public;
select pg_temp.lnf(:'T2', 'another tutor of the same centre');
select pg_temp.lnf(:'T4', 'a tutor of another centre');
select pg_temp.lnf(:'OWNER', 'the centre owner');
select pg_temp.lnf(:'STAFF', 'centre staff');
select pg_temp.lnf(:'PARENT', 'a parent');
select pg_temp.lnf(:'SOLO', 'a solo tutor');
select pg_temp.lnf(null, 'nobody signed in');
update memberships set status = 'disabled' where org_id = t.id('lp') and user_id = :'OFF';
select pg_temp.lnf(:'OFF', 'a switched-off tutor');
select pg_temp.expect(:'T1', format('select tutor_set_link(%L, null, ''https://meet.example.com/x'')', :'C'), 'NOT_FOUND', 'a student not assigned to me');
select pg_temp.expect(:'T1', format('select tutor_set_link(%L, null, ''https://meet.example.com/x'')', :'ELSE'), 'NOT_FOUND', 'a student of another centre');
select pg_temp.expect(:'T1', format('select tutor_set_link(%L, %L, ''https://meet.example.com/x'')', :'A', t.id('K1')), 'NOT_FOUND', 'both a student and a lesson: not understood');
select pg_temp.expect(:'T1', 'select tutor_set_link(null, null, ''https://meet.example.com/x'')', 'NOT_FOUND', 'neither a student nor a lesson');
-- a lesson that is over / cancelled
select t.put('Kpast', pg_temp.mk('Kpast', :'A', -3));
select pg_temp.expect(:'T1', format('select tutor_set_link(null, %L, ''https://meet.example.com/x'')', t.id('Kpast')), 'PAST', 'a lesson that is over');
select pg_temp.expect(:'T1', format('select tutor_set_link(null, %L, ''https://meet.example.com/x'')', t.id('K2')), 'CANCELLED', 'a cancelled lesson');
-- staff
select pg_temp.expect(:'STAFF', format('select staff_set_lesson_link(%L, %L, ''https://meet.example.com/staff'')', t.id('lp'), t.id('K1')), 'ok', 'staff set the link of a lesson (always, whatever the switch)');
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"admin_only","tutors_edit":{"link":false}}');
select pg_temp.expect(:'STAFF', format('select staff_set_lesson_link(%L, %L, ''https://meet.example.com/staff2'')', t.id('lp'), t.id('K1')), 'ok', 'staff set it even at an admin_only centre with the link switch off');
select pg_temp.expect(:'STAFF', format('select staff_set_student_link(%L, %L, ''https://meet.example.com/staff3'')', t.id('lp'), :'A'), 'ok', 'and the student''s default link');
select t.ok(pg_temp.call(:'MONEY', format('select staff_set_lesson_link(%L, %L, ''https://meet.example.com/x'')', t.id('lp'), t.id('K1'))) like 'ERR:NOT_ALLOWED%', 'staff without manage_timetable or manage_students are refused');
select pg_temp.expect(:'STAFF2', format('select staff_set_lesson_link(%L, %L, ''https://meet.example.com/x'')', t.id('lp'), t.id('K1')), 'NOT_FOUND', 'staff of ANOTHER centre');
select pg_temp.expect(:'T1', format('select staff_set_lesson_link(%L, %L, ''https://meet.example.com/x'')', t.id('lp'), t.id('K1')), 'NOT_FOUND', 'a tutor can''t call the staff function');
select pg_temp.expect(:'STAFF', format('select staff_set_lesson_link(%L, %L, ''https://meet.example.com/x'')', t.id('lp'), '00000000-0000-0000-0000-00000000dead'), 'NOT_FOUND', 'an unknown lesson');
select pg_temp.expect(:'STAFF', format('select staff_set_lesson_link(%L, %L, ''https://meet.example.com/x'')', t.id('lp2'), t.id('K1')), 'NOT_FOUND', 'staff can''t reach a lesson through another centre''s id');
select pg_temp.call(:'STAFF', format('select staff_timetable(%L, %L, %L)', t.id('lp'), pg_temp.lday(29), pg_temp.lday(32))) as tt \gset
select t.ok((select e->>'online_link' = 'https://meet.example.com/staff2' and e->>'lesson_link' = 'https://meet.example.com/staff2' from jsonb_array_elements((:'tt'::jsonb)->'rows') e where e->>'lesson_id' = t.id('K1')::text),
            'the staff timetable shows the lesson''s own link');
select pg_temp.expect(:'STAFF', format('select staff_set_lesson_link(%L, %L, '''')', t.id('lp'), t.id('K1')), 'ok', 'staff clear a lesson link');
select pg_temp.call(:'STAFF', format('select staff_timetable(%L, %L, %L)', t.id('lp'), pg_temp.lday(29), pg_temp.lday(32))) as tt \gset
select t.ok((select e->>'online_link' = 'https://meet.example.com/staff3' and e->>'lesson_link' is null from jsonb_array_elements((:'tt'::jsonb)->'rows') e where e->>'lesson_id' = t.id('K1')::text),
            'then the student''s link shows again, and the lesson says it has none of its own');

-- ===================================================================== 2. the settings: request_expiry_days and the two values that are no longer "soon"
select t.ok(pg_temp.call(:'OWNER', format($q$ select org_save_settings(%L, jsonb_set(t.centre_settings(), '{lessons}', '{"timetable_editing":"tutors_propose","request_expiry_days":14}'::jsonb), current_date) is not null $q$, t.id('lp'))) not like 'ERR:%', 'tutors_propose and 14 days are saved');
create function pg_temp.exp(p_days text, p_ok boolean) returns void language plpgsql as $$
declare r text := pg_temp.call('00000000-0000-0000-0000-000000a80001', format($q$ select org_save_settings(%L, jsonb_set(t.centre_settings(), '{lessons}', %L::jsonb), current_date) is not null $q$, t.id('lp'), '{"timetable_editing":"tutors_propose","request_expiry_days":' || p_days || '}'));
begin
  if p_ok and r like 'ERR:%' then raise exception 'FAIL: request_expiry_days % should be accepted: %', p_days, r; end if;
  if not p_ok and (r not like 'ERR:%' or r not like '%1-90 days%') then raise exception 'FAIL: request_expiry_days % should be refused (got %)', p_days, r; end if;
  raise notice 'PASS request_expiry_days % is %', p_days, case when p_ok then 'accepted' else 'refused' end;
end $$;
grant execute on all functions in schema pg_temp to public;
select pg_temp.exp('1', true); select pg_temp.exp('90', true); select pg_temp.exp('0', false); select pg_temp.exp('91', false); select pg_temp.exp('-1', false);
select pg_temp.exp('1.5', false); select pg_temp.exp('"7"', false); select pg_temp.exp('true', false);

-- ===================================================================== 3. every tutor action becomes a request at tutors_propose, and CHANGES NOTHING
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"tutors_propose","tutors_edit":{"postpone":true,"cancel":true,"weekly_slots":true,"generate":true,"one_off":true,"link":true},"min_notice_hours":24,"max_changes_per_month":0}');
select t.put('P1', pg_temp.mk('P1', :'A', 20)); select t.put('P2', pg_temp.mk('P2', :'A', 21)); select t.put('P4', pg_temp.mk('P4', :'A', 24));
-- P3: a moved lesson with its usual slot (S_R, one hour, on the weekday of day 23): put back = day 23, 09:00
insert into lessons(tutor_id, org_id, student_id, lesson_date, slot_date, start_time, end_time, subject, rate, amount, status, taught_by, slot_id, postponed)
values (:'OWNER', t.id('lp'), :'A', pg_temp.lday(25), pg_temp.lday(23), '15:00', '16:00', 'Maths', 12.50, 12.50, 'scheduled', t.id('m1'), t.id('S_R'), true) returning id \gset P3_
select t.put('P3', :'P3_id'::uuid);
select count(*) as before_n from lessons where org_id = t.id('lp') \gset
select count(*) as before_audit from audit_log where org_id = t.id('lp') and action in ('tutor_postpone_lesson', 'tutor_revert_lesson', 'tutor_cancel_lesson', 'tutor_add_lesson', 'tutor_save_slot', 'tutor_stop_slot', 'tutor_generate_lessons') \gset
select count(*) as before_slots from recurring_slots where org_id = t.id('lp') \gset

select pg_temp.ask(:'T1', 'R_post', format('select tutor_postpone_lesson(%L, %L, ''12:00''::time, ''Tutor is away that day'')', t.id('P1'), pg_temp.lday(40)));
select t.ok((select lesson_date = pg_temp.lday(20) and start_time = '10:00' and not postponed and changed_by_tutor_at is null from lessons where id = t.id('P1')), 'move: the lesson did not move');
select pg_temp.ask(:'T1', 'R_cancel', format('select tutor_cancel_lesson(%L, ''Family asked to skip'')', t.id('P2')));
select t.ok((select status = 'scheduled' and changed_by_tutor_at is null from lessons where id = t.id('P2')), 'cancel: the lesson is not cancelled');
select pg_temp.ask(:'T1', 'R_revert', format('select tutor_revert_lesson(%L, ''Back to the usual time'')', t.id('P3')));
select t.ok((select lesson_date = pg_temp.lday(25) and postponed from lessons where id = t.id('P3')), 'put back: the lesson is where it was');
select pg_temp.ask(:'T1', 'R_add', format('select tutor_add_lesson(%L, %L, ''14:00''::time, ''15:00''::time, ''Maths'', ''Extra lesson before the test'')', :'A', pg_temp.lday(45)));
select t.ok((select count(*) = :before_n from lessons where org_id = t.id('lp')), 'add a lesson: no lesson was made');
select pg_temp.ask(:'T1', 'R_slot_add', format('select tutor_save_slot(null, %L, %s, ''13:00''::time, ''14:00''::time, ''Maths'')', :'E', pg_temp.wd(9)));
select pg_temp.ask(:'T1', 'R_slot_chg', format('select tutor_save_slot(%L, null, %s, ''17:00''::time, ''18:00''::time, ''English'')', t.id('S_F'), pg_temp.wd(9)));
select pg_temp.ask(:'T1', 'R_slot_stop', format('select tutor_stop_slot(%L)', t.id('S_X')));
select t.ok((select count(*) = :before_slots from recurring_slots where org_id = t.id('lp')) and (select active and start_time = '16:00' from recurring_slots where id = t.id('S_F')) and (select active from recurring_slots where id = t.id('S_X')),
            'slots: none added, none changed, none stopped');
select pg_temp.ask(:'T1', 'R_gen', format('select tutor_generate_lessons(%L)', t.id('lp')));
select t.ok((select count(*) = :before_n from lessons where org_id = t.id('lp')), 'create lessons: nothing was created');
select pg_temp.ask(:'T1', 'R_link_s', format('select tutor_set_link(%L, null, ''https://meet.example.com/wanted'')', :'F'));
select pg_temp.ask(:'T1', 'R_link_l', format('select tutor_set_link(null, %L, ''https://meet.example.com/wanted-lesson'')', t.id('P4')));
select t.ok((select online_link is null from students where id = :'F'::uuid) and (select online_link is null from lessons where id = t.id('P4')), 'links: nothing was saved');
select t.ok((select count(*) = 10 and bool_and(status = 'pending') from schedule_requests where org_id = t.id('lp')), 'ten requests are waiting, all pending');
select t.ok((select count(*) = 10 and count(distinct kind) = 8 from schedule_requests where org_id = t.id('lp')), 'all eight kinds are there');
select t.ok(pg_temp.audits('schedule_request_created') = 10, 'every request is audited');
select t.ok((select count(*) = :before_audit from audit_log where org_id = t.id('lp') and action in ('tutor_postpone_lesson', 'tutor_revert_lesson', 'tutor_cancel_lesson', 'tutor_add_lesson', 'tutor_save_slot', 'tutor_stop_slot', 'tutor_generate_lessons')), 'and none of the real change audits were written (the dry run left nothing behind)');
select t.ok((select r.reason = 'Tutor is away that day' and r.kind = 'postpone' and r.lesson_id = t.id('P1') and r.student_id = :'A'::uuid and r.expires_at > now() + interval '13 days 23 hours' and r.expires_at < now() + interval '14 days 1 hour'
               from pg_temp.rq('R_post') r), 'the request keeps the tutor''s words, the lesson, the student and expires in 14 days (the default)');
select t.ok((select (payload->>'date')::date = pg_temp.lday(40) from pg_temp.rq('R_post')), 'and exactly what was asked for');
select t.ok((select (payload->>'from')::date = pg_temp.lday(0) and (payload->>'to')::date = pg_temp.lday(27) from pg_temp.rq('R_gen')), 'create lessons: the dates are fixed when it is asked (today + 27 days)');
-- the same thing twice: ALREADY_PENDING (and a different thing about the same lesson too)
select pg_temp.expect(:'T1', format('select tutor_postpone_lesson(%L, %L, ''12:00''::time, ''Tutor is away that day'')', t.id('P1'), pg_temp.lday(40)), 'ALREADY_PENDING', 'the same request twice');
select pg_temp.expect(:'T1', format('select tutor_postpone_lesson(%L, %L, ''13:00''::time, ''A different time please'')', t.id('P1'), pg_temp.lday(41)), 'ALREADY_PENDING', 'a second request about a lesson that already has one waiting');
select pg_temp.expect(:'T1', format('select tutor_cancel_lesson(%L, ''Cancel it instead'')', t.id('P1')), 'ALREADY_PENDING', 'a cancel for a lesson with a move waiting');
select pg_temp.expect(:'T1', format('select tutor_stop_slot(%L)', t.id('S_F')), 'ALREADY_PENDING', 'stop a slot that has a change waiting');
select pg_temp.expect(:'T1', format('select tutor_generate_lessons(%L)', t.id('lp')), 'ALREADY_PENDING', 'create lessons for the same dates twice');
select pg_temp.expect(:'T1', format('select tutor_set_link(%L, null, ''https://meet.example.com/other'')', :'F'), 'ALREADY_PENDING', 'a second link request for the same student');
select t.ok((select count(*) = 10 from schedule_requests where org_id = t.id('lp')), 'still ten requests');

-- ===================================================================== 4. a request that could never work is refused at once, in the same words (and writes nothing)
select pg_temp.expect(:'T1', format('select tutor_postpone_lesson(%L, %L, ''12:00''::time, ''ab'')', t.id('P4'), pg_temp.lday(40)), 'REASON_REQUIRED', 'no reason');
select pg_temp.expect(:'T1', format('select tutor_postpone_lesson(%L, %L, ''12:00''::time, ''A reason'')', t.id('P4'), pg_temp.lday(-1)), 'BAD_DATE', 'a day that has passed');
select pg_temp.expect(:'T1', format('select tutor_postpone_lesson(%L, %L, ''12:00''::time, ''A reason'')', t.id('P4'), pg_temp.lday(500)), 'BAD_DATE', 'more than a year ahead');
select pg_temp.expect(:'T1', format('select tutor_postpone_lesson(%L, %L, ''23:30''::time, ''A reason'')', t.id('P4'), pg_temp.lday(40)), 'BAD_TIME', 'a lesson that would run past midnight');
select pg_temp.expect(:'T1', format('select tutor_postpone_lesson(%L, %L, ''10:00''::time, ''A reason'')', t.id('P4'), pg_temp.lday(24)), 'NO_CHANGE', 'to the time it already has');
select pg_temp.expect(:'T1', format('select tutor_cancel_lesson(%L, ''A reason'')', t.id('P4')), 'ok', 'a good one is allowed: cancel P4');
select t.ok((select count(*) = 11 from schedule_requests where org_id = t.id('lp')), 'the good one made request number eleven; none of the refusals made one');
select t.put('N1', pg_temp.mk('N1', :'A', 29));
select pg_temp.expect(:'T1', format('select tutor_revert_lesson(%L, ''Back to normal'')', t.id('N1')), 'NOT_MOVED', 'put back a lesson that was never moved');
insert into holidays(org_id, name, starts_on, ends_on) values (t.id('lp'), 'Test Holiday', pg_temp.lday(50), pg_temp.lday(50));
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''14:00''::time, ''15:00''::time)', :'A', pg_temp.lday(50)), 'HOLIDAY', 'a holiday');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''14:00''::time, ''15:00''::time)', :'C', pg_temp.lday(46)), 'NOT_FOUND', 'a student who is not mine');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''14:00''::time, ''15:00''::time)', :'A', pg_temp.ldate(2)), 'TOO_LATE', 'a lesson inside the notice time');
select pg_temp.expect(:'T1', format('select tutor_set_link(%L, null, ''http://x.test/'')', :'E'), 'BAD_LINK', 'a bad link is refused before it is a request');
select pg_temp.expect(:'T1', format('select tutor_cancel_lesson(%L, ''A reason'')', t.id('Kpast')), 'PAST', 'a lesson in the past');
select pg_temp.expect(:'T1', format('select tutor_cancel_lesson(%L, ''A reason'')', t.id('K2')), 'CANCELLED', 'a lesson that is already cancelled');
-- marked / paid lessons
select t.put('P5', pg_temp.mk('P5', :'A', 26)); select t.put('P6', pg_temp.mk('P6', :'A', 27));
select set_config('request.jwt.claims', '', false);
update lessons set attendance = 'attended', status = 'done' where id = t.id('P5');
update lessons set paid = true where id = t.id('P6');
select pg_temp.expect(:'T1', format('select tutor_cancel_lesson(%L, ''A reason'')', t.id('P5')), 'ALREADY_MARKED', 'a marked lesson');
select pg_temp.expect(:'T1', format('select tutor_cancel_lesson(%L, ''A reason'')', t.id('P6')), 'LOCKED', 'a paid lesson');
-- the other tutors
select pg_temp.expect(:'T2', format('select tutor_cancel_lesson(%L, ''A reason'')', t.id('P1')), 'NOT_FOUND', 'another tutor''s lesson');
select pg_temp.expect(:'T4', format('select tutor_cancel_lesson(%L, ''A reason'')', t.id('P1')), 'NOT_FOUND', 'a tutor of another centre');
select pg_temp.expect(:'T1', format('select tutor_generate_lessons(%L)', t.id('lp2')), 'NOT_FOUND', 'create lessons for a centre I''m not in');
select pg_temp.expect(:'T4', format('select tutor_generate_lessons(%L)', t.id('lp')), 'NOT_FOUND', 'a tutor of another centre: create lessons here');
select pg_temp.expect(:'OWNER', format('select tutor_cancel_lesson(%L, ''A reason'')', t.id('P1')), 'NOT_FOUND', 'the owner');
select pg_temp.expect(:'STAFF', format('select tutor_cancel_lesson(%L, ''A reason'')', t.id('P1')), 'NOT_FOUND', 'staff');
select pg_temp.expect(:'SOLO', format('select tutor_cancel_lesson(%L, ''A reason'')', t.id('P1')), 'NOT_FOUND', 'a solo tutor');
select pg_temp.expect(:'PARENT', format('select tutor_cancel_lesson(%L, ''A reason'')', t.id('P1')), 'NOT_FOUND', 'a parent');
select pg_temp.expect(null, format('select tutor_cancel_lesson(%L, ''A reason'')', t.id('P1')), 'NOT_FOUND', 'nobody signed in');
select t.ok((select count(*) = 11 from schedule_requests where org_id = t.id('lp')), 'still eleven: no refusal left a request behind');
-- the switches: at tutors_propose every switch means "may ask"
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"tutors_propose","tutors_edit":{"postpone":false,"cancel":false,"weekly_slots":false,"generate":false,"one_off":false,"link":false}}');
select t.put('P7', pg_temp.mk('P7', :'A', 28));
select pg_temp.expect(:'T1', format('select tutor_postpone_lesson(%L, %L, ''12:00''::time, ''A reason'')', t.id('P7'), pg_temp.lday(40)), 'SWITCH_OFF', 'propose, move switch off');
select pg_temp.expect(:'T1', format('select tutor_cancel_lesson(%L, ''A reason'')', t.id('P7')), 'SWITCH_OFF', 'propose, cancel switch off');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''14:00''::time, ''15:00''::time)', :'A', pg_temp.lday(47)), 'SWITCH_OFF', 'propose, one-off switch off');
select pg_temp.expect(:'T1', format('select tutor_save_slot(null, %L, 3, ''13:00''::time, ''14:00''::time)', :'F'), 'SWITCH_OFF', 'propose, slots switch off');
select pg_temp.expect(:'T1', format('select tutor_stop_slot(%L)', t.id('S_R')), 'SWITCH_OFF', 'propose, slots switch off (stop)');
select pg_temp.expect(:'T1', format('select tutor_generate_lessons(%L, %L, %L)', t.id('lp'), pg_temp.lday(1), pg_temp.lday(5)), 'SWITCH_OFF', 'propose, generate switch off');
select pg_temp.expect(:'T1', format('select tutor_set_link(%L, null, ''https://meet.example.com/x'')', :'E'), 'SWITCH_OFF', 'propose, link switch off');
-- admin_only: nothing is a request
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"admin_only","tutors_edit":{"postpone":true,"cancel":true,"weekly_slots":true,"generate":true,"one_off":true,"link":true}}');
select pg_temp.expect(:'T1', format('select tutor_postpone_lesson(%L, %L, ''12:00''::time, ''A reason'')', t.id('P7'), pg_temp.lday(40)), 'NOT_ALLOWED', 'admin_only: move');
select pg_temp.expect(:'T1', format('select tutor_cancel_lesson(%L, ''A reason'')', t.id('P7')), 'NOT_ALLOWED', 'admin_only: cancel');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''14:00''::time, ''15:00''::time)', :'A', pg_temp.lday(47)), 'NOT_ALLOWED', 'admin_only: add a lesson');
select pg_temp.expect(:'T1', format('select tutor_save_slot(null, %L, 3, ''13:00''::time, ''14:00''::time)', :'F'), 'NOT_ALLOWED', 'admin_only: add a slot');
select pg_temp.expect(:'T1', format('select tutor_stop_slot(%L)', t.id('S_R')), 'NOT_ALLOWED', 'admin_only: stop a slot');
select pg_temp.expect(:'T1', format('select tutor_generate_lessons(%L, %L, %L)', t.id('lp'), pg_temp.lday(1), pg_temp.lday(5)), 'NOT_ALLOWED', 'admin_only: create lessons');
select pg_temp.expect(:'T1', format('select tutor_set_link(%L, null, ''https://meet.example.com/x'')', :'E'), 'NOT_ALLOWED', 'admin_only: link');
-- tutors_direct: everything acts at once and no request is made (what steps 2-5 built is unchanged)
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"postpone":true,"cancel":true,"weekly_slots":true,"generate":true,"one_off":true,"link":true}}');
select t.ok((select (r::jsonb->>'requested') is null and (r::jsonb->>'lesson_id') = t.id('P7')::text from (select pg_temp.call(:'T1', format('select tutor_postpone_lesson(%L, %L, ''12:00''::time, ''Direct, at once'')', t.id('P7'), pg_temp.lday(40))) r) x),
            'tutors_direct: a move acts at once and answers as before (no "requested")');
select t.ok((select lesson_date = pg_temp.lday(40) and postponed from lessons where id = t.id('P7')), 'and the lesson moved');
select pg_temp.expect(:'T1', format('select tutor_cancel_lesson(%L, ''Direct cancel'')', t.id('P7')), 'ok', 'direct cancel');
select pg_temp.expect(:'T1', format('select tutor_set_link(%L, null, ''https://meet.example.com/direct'')', :'E'), 'ok', 'direct link');
select pg_temp.expect(:'T1', format('select tutor_add_lesson(%L, %L, ''14:00''::time, ''15:00''::time)', :'A', pg_temp.lday(47)), 'ok', 'direct add');
select t.ok((select count(*) = 11 from schedule_requests where org_id = t.id('lp')), 'at tutors_direct no request was made (still eleven)');

-- back to propose for the rest
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"tutors_propose","tutors_edit":{"postpone":true,"cancel":true,"weekly_slots":true,"generate":true,"one_off":true,"link":true},"min_notice_hours":24,"max_changes_per_month":0}');

-- ===================================================================== 5. who may see and answer requests
select pg_temp.call(:'STAFF', format('select staff_schedule_requests(%L)', t.id('lp'))) as sl \gset
select t.ok((:'sl'::jsonb->>'pending')::int = 11 and jsonb_array_length((:'sl'::jsonb)->'rows') = 11 and (:'sl'::jsonb->>'can_decide')::boolean, 'staff with manage_timetable see the eleven waiting requests');
select t.ok((select bool_and(e->>'tutor_name' = 'Tutor One' and (e->>'can_decide')::boolean) from jsonb_array_elements((:'sl'::jsonb)->'rows') e), 'each says who asked and can be answered');
select t.ok((select e->>'student_name' = 'Ann' and e->>'kind' = 'postpone' and e->>'new_date' = pg_temp.lday(40)::text and e->>'new_start' = '12:00:00' and e->>'lesson_date' = pg_temp.lday(20)::text and e->>'start_time' = '10:00:00'
               and e->>'reason' = 'Tutor is away that day' from jsonb_array_elements((:'sl'::jsonb)->'rows') e where e->>'request_id' = t.id('R_post')::text), 'the list says what is asked: the lesson now and the time asked for');
select pg_temp.expect(:'MONEY', format('select staff_schedule_requests(%L)', t.id('lp')), 'NOT_ALLOWED', 'staff without manage_timetable can''t read them');
select pg_temp.expect(:'STAFF2', format('select staff_schedule_requests(%L)', t.id('lp')), 'NOT_FOUND', 'staff of another centre');
select pg_temp.expect(:'T1', format('select staff_schedule_requests(%L)', t.id('lp')), 'NOT_FOUND', 'a tutor');
select pg_temp.expect(:'PARENT', format('select staff_schedule_requests(%L)', t.id('lp')), 'NOT_FOUND', 'a parent');
select pg_temp.expect(:'SOLO', format('select staff_schedule_requests(%L)', t.id('lp')), 'NOT_FOUND', 'a solo tutor');
select pg_temp.expect(null, format('select staff_schedule_requests(%L)', t.id('lp')), 'NOT_FOUND', 'nobody');
select pg_temp.expect(:'STAFF', format('select staff_schedule_requests(%L, ''everything'')', t.id('lp')), 'BAD_STATUS', 'an unknown status');
select pg_temp.expect(:'OWNER', format('select staff_schedule_requests(%L)', t.id('lp')), 'ok', 'the owner may');
select pg_temp.expect(:'MONEY', format('select staff_decide_request(%L, ''approve'')', t.id('R_post')), 'NOT_ALLOWED', 'staff without manage_timetable can''t answer');
select pg_temp.expect(:'STAFF2', format('select staff_decide_request(%L, ''approve'')', t.id('R_post')), 'NOT_FOUND', 'staff of another centre can''t answer');
select pg_temp.expect(:'T1', format('select staff_decide_request(%L, ''approve'')', t.id('R_post')), 'NOT_FOUND', 'the tutor can''t approve their own request');
select pg_temp.expect(:'T2', format('select staff_decide_request(%L, ''approve'')', t.id('R_post')), 'NOT_FOUND', 'another tutor can''t');
select pg_temp.expect(:'PARENT', format('select staff_decide_request(%L, ''approve'')', t.id('R_post')), 'NOT_FOUND', 'a parent can''t');
select pg_temp.expect(:'SOLO', format('select staff_decide_request(%L, ''approve'')', t.id('R_post')), 'NOT_FOUND', 'a solo tutor can''t');
select pg_temp.expect(null, format('select staff_decide_request(%L, ''approve'')', t.id('R_post')), 'NOT_FOUND', 'nobody can');
select pg_temp.expect(:'STAFF', 'select staff_decide_request(''00000000-0000-0000-0000-00000000dead'', ''approve'')', 'NOT_FOUND', 'an unknown request');
select pg_temp.expect(:'STAFF', format('select staff_decide_request(%L, ''maybe'')', t.id('R_post')), 'BAD_DECISION', 'an unknown decision');
select t.ok((select r.status = 'pending' and l.lesson_date = pg_temp.lday(20) from schedule_requests r, lessons l where r.id = t.id('R_post') and l.id = t.id('P1')), 'after all those refusals nothing changed');

-- ===================================================================== 6. approve: each kind is applied ONCE
-- (a) move
select pg_temp.audits('tutor_postpone_lesson') as ap0, pg_temp.audits('schedule_request_approved') as aa0 \gset
select pg_temp.expect(:'STAFF', format('select staff_decide_request(%L, ''approve'')', t.id('R_post')), 'ok', 'staff approve the move');
select t.ok((select lesson_date = pg_temp.lday(40) and start_time = '12:00' and end_time = '13:00' and postponed and changed_by_tutor_what = 'moved' and changed_by_tutor = t.id('m1') and changed_by_tutor_reason = 'Tutor is away that day'
               and changed_from_date = pg_temp.lday(20) from lessons where id = t.id('P1')), 'the lesson moved (same length), flagged "changed by tutor" with the tutor''s reason');
select t.ok((select status = 'approved' and decided_by = :'STAFF'::uuid and decided_at is not null and result is not null and decision_code = 'APPROVED' from pg_temp.rq('R_post')), 'the request is approved, by the staff member, with the result kept');
select t.ok(pg_temp.audits('tutor_postpone_lesson') = :ap0 + 1 and pg_temp.audits('schedule_request_approved') = :aa0 + 1, 'one change audit row and one approval audit row');
select t.ok((select actor = :'T1'::uuid from audit_log where org_id = t.id('lp') and action = 'tutor_postpone_lesson' order by id desc limit 1), 'the change audit row names the tutor as the actor (so the monthly count is theirs)');
select t.ok((select actor = :'STAFF'::uuid from audit_log where org_id = t.id('lp') and action = 'schedule_request_approved'), 'the approval audit row names the staff member');
-- approving twice: nothing is applied twice
select pg_temp.call(:'STAFF', format('select staff_decide_request(%L, ''approve'')', t.id('R_post'))) as again \gset
select t.ok((:'again'::jsonb->>'already')::boolean and :'again'::jsonb->>'status' = 'approved', 'approving again answers already = true');
select t.ok(pg_temp.audits('tutor_postpone_lesson') = :ap0 + 1 and pg_temp.audits('schedule_request_approved') = :aa0 + 1 and (select lesson_date = pg_temp.lday(40) from lessons where id = t.id('P1')), 'and nothing was applied a second time');
select pg_temp.expect(:'OWNER', format('select staff_decide_request(%L, ''approve'')', t.id('R_post')), 'ok', 'another admin pressing approve too: also harmless');
select t.ok(pg_temp.audits('tutor_postpone_lesson') = :ap0 + 1, 'still one change');
select pg_temp.expect(:'STAFF', format('select staff_decide_request(%L, ''decline'', ''Changed my mind'')', t.id('R_post')), 'ALREADY_DECIDED', 'declining an approved request is refused');
-- the session is back to being the staff member after an approval (no impersonation left behind)
create function pg_temp.whoami_after(p_staff text, p_tag text) returns text language plpgsql as $$
declare before_c text; r text; after_c text; sub_after text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_staff, 'role', 'authenticated')::text, false);
  before_c := current_setting('request.jwt.claims', true);
  set local role authenticated;
  r := (select staff_decide_request(t.id(p_tag), 'approve')::text);
  after_c := current_setting('request.jwt.claims', true); sub_after := auth.uid()::text;
  reset role;
  return case when after_c = before_c and sub_after = p_staff then 'same' else 'CHANGED ' || coalesce(sub_after, '?') end;
end $$;
grant execute on all functions in schema pg_temp to public;
select t.ok(pg_temp.whoami_after(:'STAFF', 'R_cancel') = 'same', 'after an approval the transaction is still the staff member (claims put back)');
-- (b) cancel
select t.ok((select status = 'cancelled' and compensation = 0 and changed_by_tutor_what = 'cancelled' and changed_by_tutor_reason = 'Family asked to skip' from lessons where id = t.id('P2')), 'cancel: cancelled, no charge, flagged, with the reason');
select t.ok((select status = 'approved' from pg_temp.rq('R_cancel')), 'the cancel request is approved');
-- (c) put back
select pg_temp.expect(:'STAFF', format('select staff_decide_request(%L, ''approve'')', t.id('R_revert')), 'ok', 'approve the put-back');
select t.ok((select lesson_date = pg_temp.lday(23) and start_time = '09:00' and not postponed and changed_by_tutor_what = 'reverted' from lessons where id = t.id('P3')), 'put back to the usual slot');
-- (d) add a lesson: Ann has a staff price to copy; the tutor never typed one
select pg_temp.expect(:'STAFF', format('select staff_decide_request(%L, ''approve'')', t.id('R_add')), 'ok', 'approve the new lesson');
select t.ok((select count(*) = 1 and bool_and(created_by_tutor = t.id('m1') and one_off and taught_by = t.id('m1') and rate = 12.50 and not price_pending and status = 'scheduled' and changed_by_tutor_reason = 'Extra lesson before the test')
               from lessons where student_id = :'A' and lesson_date = pg_temp.lday(45)), 'the lesson was made once, the price copied from the centre''s own staff lesson, the note kept');
-- (e) slots
select pg_temp.expect(:'STAFF', format('select staff_decide_request(%L, ''approve'')', t.id('R_slot_add')), 'ok', 'approve the new weekly slot (Eve has no price yet)');
select t.ok((select count(*) = 1 and bool_and(price_pending and created_by_tutor = t.id('m1') and taught_by = t.id('m1') and active) from recurring_slots where student_id = :'E' and weekday = pg_temp.wd(9)), 'a slot was made, waiting for the centre to confirm its price');
select pg_temp.expect(:'STAFF', format('select staff_decide_request(%L, ''approve'')', t.id('R_slot_chg')), 'ok', 'approve the slot change');
select t.ok((select weekday = pg_temp.wd(9) and start_time = '17:00' and end_time = '18:00' and changed_by_tutor_what = 'changed' from recurring_slots where id = t.id('S_F')), 'the slot changed');
select pg_temp.expect(:'STAFF', format('select staff_decide_request(%L, ''approve'')', t.id('R_slot_stop')), 'ok', 'approve stopping the slot');
select t.ok((select not active and changed_by_tutor_what = 'stopped' from recurring_slots where id = t.id('S_X')), 'the slot is stopped');
-- (f) create lessons: made from the tutor's slots; the weekday of S_F moved to wd(9), so the generator works on that
select pg_temp.expect(:'STAFF', format('select staff_decide_request(%L, ''approve'')', t.id('R_gen')), 'ok', 'approve "create lessons"');
select t.ok((select count(*) >= 3 from lessons where org_id = t.id('lp') and student_id = :'F' and created_by_tutor = t.id('m1') and slot_id = t.id('S_F')), 'the lessons were made from the tutor''s own slot (at least three weeks)');
select pg_temp.call(:'STAFF', format('select staff_decide_request(%L, ''approve'')', t.id('R_gen'))) as again \gset
select count(*) as gen_n from lessons where org_id = t.id('lp') and student_id = :'F' and created_by_tutor = t.id('m1') \gset
select t.ok((:'again'::jsonb->>'already')::boolean, 'approving "create lessons" again does nothing');
select t.ok((select count(*) = :gen_n from lessons where org_id = t.id('lp') and student_id = :'F' and created_by_tutor = t.id('m1')), 'and no lesson was made twice');
-- (g) links
select pg_temp.expect(:'STAFF', format('select staff_decide_request(%L, ''approve'')', t.id('R_link_s')), 'ok', 'approve the student link');
select pg_temp.expect(:'STAFF', format('select staff_decide_request(%L, ''approve'')', t.id('R_link_l')), 'ok', 'approve the lesson link');
select t.ok((select online_link = 'https://meet.example.com/wanted' from students where id = :'F'::uuid) and (select online_link = 'https://meet.example.com/wanted-lesson' from lessons where id = t.id('P4')), 'both links are saved');
select t.ok((select count(*) = 10 from schedule_requests where org_id = t.id('lp') and status = 'approved'), 'ten requests are approved');
select t.ok((select count(*) = 1 from schedule_requests where org_id = t.id('lp') and status = 'pending'), 'one is still waiting (the cancel of P4 made in section 4)');
-- an approved add-lesson for a student with no price history waits for the centre, and the tutor is told so without a price
select pg_temp.ask(:'T1', 'R_add_e', format('select tutor_add_lesson(%L, %L, ''16:00''::time, ''17:00''::time)', :'E', pg_temp.lday(46)));
select pg_temp.expect(:'STAFF', format('select staff_decide_request(%L, ''approve'')', t.id('R_add_e')), 'ok', 'approve a lesson for Eve');
select t.ok((select price_pending and rate = 0 from lessons where student_id = :'E' and lesson_date = pg_temp.lday(46)), 'Eve''s lesson is made with its price waiting for the centre (it holds back her invoice, as at tutors_direct)');

-- ===================================================================== 7. approve re-checks EVERY rule when it is approved
select t.put('Q1', pg_temp.mk('Q1', :'A', 33)); select t.put('Q2', pg_temp.mk('Q2', :'A', 34)); select t.put('Q3', pg_temp.mk('Q3', :'A', 35)); select t.put('Q4', pg_temp.mk('Q4', :'A', 36));
select t.put('Q5', pg_temp.mk('Q5', :'A', 37)); select t.put('Q6', pg_temp.mk('Q6', :'A', 38)); select t.put('Q7', pg_temp.mk('Q7', :'A', 39)); select t.put('Q8', pg_temp.mk('Q8', :'A', 42)); select t.put('Q9', pg_temp.mk('Q9', :'A', 43));
select pg_temp.ask(:'T1', 'Rq1', format('select tutor_cancel_lesson(%L, ''Will be marked first'')', t.id('Q1')));
select pg_temp.ask(:'T1', 'Rq2', format('select tutor_cancel_lesson(%L, ''Will be paid first'')', t.id('Q2')));
select pg_temp.ask(:'T1', 'Rq3', format('select tutor_postpone_lesson(%L, %L, ''12:00''::time, ''Into a clash'')', t.id('Q3'), pg_temp.lday(52)));
select pg_temp.ask(:'T1', 'Rq4', format('select tutor_postpone_lesson(%L, %L, ''12:00''::time, ''Into a holiday'')', t.id('Q4'), pg_temp.lday(53)));
select pg_temp.ask(:'T1', 'Rq5', format('select tutor_cancel_lesson(%L, ''Will be too late'')', t.id('Q5')));
select pg_temp.ask(:'T1', 'Rq6', format('select tutor_cancel_lesson(%L, ''Will have started'')', t.id('Q6')));
select pg_temp.ask(:'T1', 'Rq7', format('select tutor_cancel_lesson(%L, ''Tutor will be unassigned'')', t.id('Q7')));
select pg_temp.ask(:'T1', 'Rq8', format('select tutor_cancel_lesson(%L, ''The lesson will be cancelled by staff'')', t.id('Q8')));
select pg_temp.ask(:'T1', 'Rq9', format('select tutor_postpone_lesson(%L, %L, ''12:00''::time, ''Setting changes'')', t.id('Q9'), pg_temp.lday(54)));
-- time passes / staff act in the meantime (superuser edits stand in for those)
select set_config('request.jwt.claims', '', false);
update lessons set attendance = 'attended', status = 'done' where id = t.id('Q1');
update lessons set paid = true where id = t.id('Q2');
select pg_temp.mk('Qc', :'A', 52, '12:30', '13:30');                                                       -- the tutor already teaches at the new time of Q3
insert into holidays(org_id, name, starts_on, ends_on) values (t.id('lp'), 'Sudden Holiday', pg_temp.lday(53), pg_temp.lday(53));
update lessons set lesson_date = pg_temp.ldate(3), start_time = pg_temp.ltime(3), end_time = pg_temp.ltime(3) + interval '1 hour' where id = t.id('Q5');                                     -- now inside the 24 hour notice
update lessons set lesson_date = pg_temp.lday(-1) where id = t.id('Q6');                                     -- now over
update student_tutors set active = false, until = current_date where student_id = :'A' and membership_id = t.id('m1');
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"tutors_propose","tutors_edit":{"postpone":true,"cancel":true,"weekly_slots":true,"generate":true,"one_off":true,"link":true},"min_notice_hours":24}');
-- (Q7's tutor is "unassigned" from Ann: so every Ann request that is still waiting is no longer possible too. Re-assign for the ones that should work, in the loop below.)
create function pg_temp.stays(p_tag text, p_lesson text, p_code text, p_msg text) returns void language plpgsql as $$
declare before_l lessons := (select l from lessons l where l.id = t.id(p_lesson)); r jsonb; after_l lessons;
begin
  r := pg_temp.call('00000000-0000-0000-0000-000000a80002', format('select staff_decide_request(%L, ''approve'')', t.id(p_tag)))::jsonb;
  after_l := (select l from lessons l where l.id = t.id(p_lesson));
  if r->>'status' <> 'no_longer_possible' or r->>'code' <> p_code then raise exception 'FAIL: % (got %)', p_msg, r; end if;
  if before_l is distinct from after_l then raise exception 'FAIL: % changed the lesson anyway', p_msg; end if;
  if not exists (select 1 from schedule_requests where id = t.id(p_tag) and status = 'no_longer_possible' and decision_code = p_code and length(decision_reason) > 10) then raise exception 'FAIL: % was not recorded with a reason', p_msg; end if;
  raise notice 'PASS no longer possible (%): %  -> "%"', p_code, p_msg, r->>'reason';
end $$;
grant execute on all functions in schema pg_temp to public;
update student_tutors set active = true, until = null where student_id = :'A' and membership_id = t.id('m1');
select pg_temp.stays('Rq1', 'Q1', 'ALREADY_MARKED', 'the lesson was marked before the approval');
select pg_temp.stays('Rq2', 'Q2', 'LOCKED', 'the lesson was paid before the approval');
select pg_temp.stays('Rq3', 'Q3', 'CLASH', 'the new time now clashes with another of the tutor''s lessons');
select pg_temp.stays('Rq4', 'Q4', 'HOLIDAY', 'the new day became a holiday');
select pg_temp.stays('Rq5', 'Q5', 'TOO_LATE', 'the lesson is now inside the notice time');
select pg_temp.stays('Rq6', 'Q6', 'PAST', 'the lesson has already happened');
update lessons set status = 'cancelled', compensation = 0 where id = t.id('Q8');
select pg_temp.stays('Rq8', 'Q8', 'CANCELLED', 'the lesson was cancelled by staff in the meantime');
update student_tutors set active = false, until = current_date where student_id = :'A' and membership_id = t.id('m1');
select pg_temp.stays('Rq7', 'Q7', 'NOT_FOUND', 'the student is no longer assigned to the tutor');
update student_tutors set active = true, until = null where student_id = :'A' and membership_id = t.id('m1');
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"admin_only"}');
select pg_temp.stays('Rq9', 'Q9', 'NOT_ALLOWED', 'the centre switched to admin_only after the request');
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"tutors_propose","tutors_edit":{"postpone":true,"cancel":true,"weekly_slots":true,"generate":true,"one_off":true,"link":true},"min_notice_hours":24}');
select t.ok((select count(*) = 9 from schedule_requests where org_id = t.id('lp') and status = 'no_longer_possible'), 'nine requests are recorded as no longer possible, each with a plain reason');
select t.ok((select decision_reason = 'The lesson has been marked since the request was made' from pg_temp.rq('Rq1')) and (select decision_reason ~ 'notice' from pg_temp.rq('Rq5')), 'the reasons are the plain-words ones');
select pg_temp.expect(:'STAFF', format('select staff_decide_request(%L, ''approve'')', t.id('Rq1')), 'ok', 'pressing approve on a "no longer possible" one just says so');
select t.ok((select r::jsonb->>'status' = 'no_longer_possible' and (r::jsonb->>'already')::boolean from (select pg_temp.call(:'STAFF', format('select staff_decide_request(%L, ''approve'')', t.id('Rq1'))) r) x), 'with already = true');
-- a tutor switched off before the approval; a setting switched to tutors_direct before the approval still approves
select pg_temp.ask(:'T2', 'Rt2', format('select tutor_cancel_lesson(%L, ''Tutor two asks'')', pg_temp.mk('Q10', :'B', 44, '10:00', '11:00', t.id('m2')::text)));
update memberships set status = 'disabled' where org_id = t.id('lp') and user_id = :'T2';
select t.ok((select r::jsonb->>'status' = 'no_longer_possible' and r::jsonb->>'code' = 'NOT_FOUND' from (select pg_temp.decide(:'STAFF', 'Rt2', 'approve') r) x), 'a tutor switched off before the approval: no longer possible');
update memberships set status = 'active' where org_id = t.id('lp') and user_id = :'T2';
select t.put('Q11', pg_temp.mk('Q11', :'A', 48)); select pg_temp.ask(:'T1', 'Rd1', format('select tutor_cancel_lesson(%L, ''Setting changes to direct'')', t.id('Q11')));
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"tutors_direct","tutors_edit":{"postpone":true,"cancel":true},"min_notice_hours":24}');
select t.ok((select r::jsonb->>'status' = 'approved' from (select pg_temp.decide(:'STAFF', 'Rd1', 'approve') r) x), 'the centre moved to tutors_direct after the request: it still applies');
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"tutors_propose","tutors_edit":{"postpone":true,"cancel":true,"weekly_slots":true,"generate":true,"one_off":true,"link":true},"min_notice_hours":24}');
-- a switch turned off after the request
select t.put('Q12', pg_temp.mk('Q12', :'A', 49)); select pg_temp.ask(:'T1', 'Rsw', format('select tutor_cancel_lesson(%L, ''The switch goes off'')', t.id('Q12')));
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"tutors_propose","tutors_edit":{"postpone":true,"cancel":false},"min_notice_hours":24}');
select t.ok((select r::jsonb->>'status' = 'no_longer_possible' and r::jsonb->>'code' = 'SWITCH_OFF' from (select pg_temp.decide(:'STAFF', 'Rsw', 'approve') r) x), 'the cancel switch was turned off after the request: no longer possible');
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"tutors_propose","tutors_edit":{"postpone":true,"cancel":true,"weekly_slots":true,"generate":true,"one_off":true,"link":true},"min_notice_hours":24}');

-- ===================================================================== 8. decline
select t.put('D1', pg_temp.mk('D1', :'A', 55));
select pg_temp.ask(:'T1', 'Rdec', format('select tutor_cancel_lesson(%L, ''Please cancel this one'')', t.id('D1')));
select pg_temp.expect(:'STAFF', format('select staff_decide_request(%L, ''decline'')', t.id('Rdec')), 'REASON_REQUIRED', 'declining needs a reason');
select pg_temp.expect(:'STAFF', format('select staff_decide_request(%L, ''decline'', ''no'')', t.id('Rdec')), 'REASON_REQUIRED', 'a reason of two letters is not enough');
select pg_temp.expect(:'STAFF', format('select staff_decide_request(%L, ''decline'', %L)', t.id('Rdec'), repeat('x', 301)), 'TOO_LONG', 'a reason is at most 300 characters');
select t.ok((select status = 'pending' from pg_temp.rq('Rdec')), 'still waiting after those refusals');
select pg_temp.expect(:'MONEY', format('select staff_decide_request(%L, ''decline'', ''Not allowed to'')', t.id('Rdec')), 'NOT_ALLOWED', 'staff without manage_timetable can''t decline');
select pg_temp.expect(:'STAFF', format('select staff_decide_request(%L, ''decline'', ''We need that lesson to go ahead'')', t.id('Rdec')), 'ok', 'staff decline with a reason');
select t.ok((select status = 'declined' and decision_reason = 'We need that lesson to go ahead' and decided_by = :'STAFF'::uuid and decision_code = 'DECLINED' from pg_temp.rq('Rdec')), 'declined, with the reason and who');
select t.ok((select status = 'scheduled' and changed_by_tutor_at is null from lessons where id = t.id('D1')), 'declining changes nothing');
select t.ok((select (pg_temp.decide(:'STAFF', 'Rdec', 'decline', 'We need that lesson to go ahead'))::jsonb->>'already' = 'true'), 'declining again is harmless');
select pg_temp.expect(:'STAFF', format('select staff_decide_request(%L, ''approve'')', t.id('Rdec')), 'ALREADY_DECIDED', 'approving a declined request is refused');
select t.ok((select status = 'scheduled' from lessons where id = t.id('D1')), 'and the lesson is still scheduled');
select t.ok(pg_temp.audits('schedule_request_declined') = 1, 'the decline is audited');
select pg_temp.expect(:'T1', format('select tutor_cancel_lesson(%L, ''Asking again after the decline'')', t.id('D1')), 'ok', 'the tutor may ask again after a decline (a new request)');

-- ===================================================================== 9. the tutor sees their requests, and takes one back
select pg_temp.call(:'T1', 'select tutor_my_requests()') as mine \gset
select pg_temp.say(:'mine');
select t.ok(jsonb_array_length((:'mine'::jsonb)->'rows') >= 20, 'the tutor sees their requests (' || jsonb_array_length((:'mine'::jsonb)->'rows') || ')');
select t.ok((select e->>'status' = 'declined' and e->>'decision_reason' = 'We need that lesson to go ahead' and e->>'student_name' = 'Ann' and e->>'kind' = 'cancel' from jsonb_array_elements((:'mine'::jsonb)->'rows') e where e->>'request_id' = t.id('Rdec')::text),
            'a declined request shows the reason');
select t.ok((select e->>'status' = 'no_longer_possible' and e->>'decision_reason' = 'The lesson has been marked since the request was made' from jsonb_array_elements((:'mine'::jsonb)->'rows') e where e->>'request_id' = t.id('Rq1')::text), 'a no-longer-possible one shows why');
select t.ok((select e->>'status' = 'approved' and e->>'new_date' = pg_temp.lday(40)::text and e->>'lesson_date' = pg_temp.lday(40)::text from jsonb_array_elements((:'mine'::jsonb)->'rows') e where e->>'request_id' = t.id('R_post')::text), 'an approved one says approved');
select t.ok((select e->>'status' = 'pending' and e->>'decision_reason' is null from jsonb_array_elements((:'mine'::jsonb)->'rows') e where e->>'kind' = 'cancel' and e->>'status' = 'pending' limit 1), 'a waiting one has no decision text');
select t.ok((select bool_and(e->>'status' = 'pending') from (select e from jsonb_array_elements((:'mine'::jsonb)->'rows') e limit 1) f(e)), 'waiting requests are listed first');
select pg_temp.call(:'T2', 'select tutor_my_requests()') as mine2 \gset
select t.ok(not exists (select 1 from jsonb_array_elements((:'mine2'::jsonb)->'rows') e where e->>'student_name' = 'Ann'), 'tutor two sees nothing of tutor one''s requests');
select pg_temp.expect(:'OWNER', 'select tutor_my_requests()', 'NOT_FOUND', 'the owner has no "my requests"');
select pg_temp.expect(:'SOLO', 'select tutor_my_requests()', 'NOT_FOUND', 'a solo tutor has none');
select pg_temp.expect(null, 'select tutor_my_requests()', 'NOT_FOUND', 'nobody signed in');
select pg_temp.expect(:'T4', 'select tutor_my_requests()', 'ok', 'a tutor of another centre has their own (empty) list');
select t.ok(jsonb_array_length((pg_temp.call(:'T4', 'select tutor_my_requests()')::jsonb)->'rows') = 0, 'and sees none of ours');
-- take a request back
select t.put('W1', pg_temp.mk('W1', :'A', 56));
select pg_temp.ask(:'T1', 'Rw1', format('select tutor_cancel_lesson(%L, ''I will take this back'')', t.id('W1')));
select pg_temp.expect(:'T2', format('select tutor_cancel_request(%L)', t.id('Rw1')), 'NOT_FOUND', 'another tutor can''t take it back');
select pg_temp.expect(:'T4', format('select tutor_cancel_request(%L)', t.id('Rw1')), 'NOT_FOUND', 'a tutor of another centre can''t');
select pg_temp.expect(:'STAFF', format('select tutor_cancel_request(%L)', t.id('Rw1')), 'NOT_FOUND', 'staff can''t use the tutor''s function');
select pg_temp.expect(:'T1', 'select tutor_cancel_request(''00000000-0000-0000-0000-00000000dead'')', 'NOT_FOUND', 'an unknown request');
select pg_temp.expect(:'T1', format('select tutor_cancel_request(%L)', t.id('Rw1')), 'ok', 'the tutor takes it back');
select t.ok((select status = 'cancelled' and decision_code = 'CANCELLED' from pg_temp.rq('Rw1')), 'cancelled');
select t.ok((select (pg_temp.call(:'T1', format('select tutor_cancel_request(%L)', t.id('Rw1'))))::jsonb->>'already' = 'true'), 'taking it back twice is harmless');
select t.ok((select r::jsonb->>'status' = 'cancelled' and (r::jsonb->>'already')::boolean from (select pg_temp.decide(:'STAFF', 'Rw1', 'approve') r) x), 'staff pressing approve on a request that was taken back: nothing happens');
select t.ok((select status = 'scheduled' from lessons where id = t.id('W1')), 'the lesson is untouched');
select pg_temp.expect(:'T1', format('select tutor_cancel_request(%L)', t.id('R_post')), 'ALREADY_DECIDED', 'an answered request can''t be taken back');
select pg_temp.expect(:'T1', format('select tutor_cancel_request(%L)', t.id('Rdec')), 'ALREADY_DECIDED', 'a declined one neither');
select pg_temp.expect(:'T1', format('select tutor_cancel_lesson(%L, ''Ask again after taking it back'')', t.id('W1')), 'ok', 'after taking one back the tutor can ask again');
select t.ok(pg_temp.audits('schedule_request_cancelled') = 1, 'taking back is audited');

-- ===================================================================== 10. expiry (a setting, default 14 days)
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"tutors_propose","tutors_edit":{"postpone":true,"cancel":true},"min_notice_hours":24,"request_expiry_days":3}');
select t.put('X1', pg_temp.mk('X1', :'A', 57)); select t.put('X2', pg_temp.mk('X2', :'A', 58)); select t.put('X3', pg_temp.mk('X3', :'A', 59));
select pg_temp.ask(:'T1', 'Rx1', format('select tutor_cancel_lesson(%L, ''Will run out'')', t.id('X1')));
select pg_temp.ask(:'T1', 'Rx2', format('select tutor_cancel_lesson(%L, ''Will run out too'')', t.id('X2')));
select t.ok((select expires_at > now() + interval '2 days 23 hours' and expires_at < now() + interval '3 days 1 hour' from pg_temp.rq('Rx1')), 'the setting is used: a request waits 3 days');
select t.ok((select (r::jsonb->>'expires_at')::timestamptz > now() + interval '2 days 23 hours' from (select pg_temp.say(pg_temp.call(:'T1', format('select tutor_cancel_lesson(%L, ''Will not run out yet'')', t.id('X3')))) r) x), 'and the tutor''s answer carries the date');
update schedule_requests set expires_at = now() - interval '1 minute' where id in (t.id('Rx1'), t.id('Rx2'));      -- "three days later"
select pg_temp.call(:'STAFF', format('select staff_schedule_requests(%L)', t.id('lp'))) as sl2 \gset
select t.ok(not exists (select 1 from jsonb_array_elements((:'sl2'::jsonb)->'rows') e where e->>'request_id' in (t.id('Rx1')::text, t.id('Rx2')::text)), 'staff no longer see the expired ones among the waiting');
select t.ok((select count(*) = 2 and bool_and(decision_code = 'EXPIRED' and decided_at is not null) from schedule_requests where id in (t.id('Rx1'), t.id('Rx2')) and status = 'expired'), 'they are marked expired');
select t.ok(pg_temp.audits('schedule_request_expired') = 2, 'expiry is audited');
select t.ok((select r::jsonb->>'status' = 'expired' and (r::jsonb->>'already')::boolean from (select pg_temp.decide(:'STAFF', 'Rx1', 'approve') r) x), 'approving an expired request applies nothing');
select t.ok((select status = 'scheduled' from lessons where id in (t.id('X1'))), 'and the lesson is untouched');
select t.ok((select r::jsonb->>'status' = 'expired' from (select pg_temp.decide(:'STAFF', 'Rx2', 'decline', 'Too late to decline') r) x), 'declining an expired one just says so');
select pg_temp.call(:'T1', 'select tutor_my_requests()') as mine3 \gset
select t.ok((select e->>'status' = 'expired' and e->>'decision_reason' like 'Nobody answered%' from jsonb_array_elements((:'mine3'::jsonb)->'rows') e where e->>'request_id' = t.id('Rx1')::text), 'the tutor sees "expired" and why');
select pg_temp.expect(:'T1', format('select tutor_cancel_lesson(%L, ''Ask again after it ran out'')', t.id('X1')), 'ok', 'after expiry the tutor can ask again for the same lesson');
-- a request that is overdue but not yet marked is marked when staff answer it
select pg_temp.ask(:'T1', 'Rx4', format('select tutor_cancel_lesson(%L, ''Overdue and unmarked'')', t.id('X2')));
update schedule_requests set expires_at = now() - interval '1 second' where id = t.id('Rx4');
select t.ok((select r::jsonb->>'status' = 'expired' from (select pg_temp.decide(:'STAFF', 'Rx4', 'approve') r) x), 'an overdue request is expired when staff try to approve it (no cron needed)');
select t.ok((select status = 'scheduled' from lessons where id = t.id('X2')), 'and nothing was applied');
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"tutors_propose","tutors_edit":{"postpone":true,"cancel":true,"weekly_slots":true,"generate":true,"one_off":true,"link":true},"min_notice_hours":24}');

-- ===================================================================== 11. the monthly limit: waiting requests count, approved ones count, link and "create lessons" do not
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"tutors_propose","tutors_edit":{"postpone":true,"cancel":true,"weekly_slots":true,"generate":true,"one_off":true,"link":true},"min_notice_hours":24,"max_changes_per_month":2}');
insert into recurring_slots(id, tutor_id, org_id, student_id, weekday, start_time, end_time, rate, subject, active, taught_by, created_at) values
  ('00000000-0000-0000-0000-000000a80211', :'OWNER', t.id('lp'), :'Z', pg_temp.wd(10), '10:00', '11:00', 20.00, 'Math', true, t.id('m5'), now() - interval '3 days');
select t.put('S_Z', '00000000-0000-0000-0000-000000a80211');
select t.put('Z1', pg_temp.mk('Z1', :'Z', 20, '10:00', '11:00', t.id('m5')::text)); select t.put('Z2', pg_temp.mk('Z2', :'Z', 21, '10:00', '11:00', t.id('m5')::text));
select t.put('Z3', pg_temp.mk('Z3', :'Z', 22, '10:00', '11:00', t.id('m5')::text)); select t.put('Z4', pg_temp.mk('Z4', :'Z', 23, '10:00', '11:00', t.id('m5')::text));
select pg_temp.ask(:'T5', 'Rz1', format('select tutor_cancel_lesson(%L, ''First change'')', t.id('Z1')));
select pg_temp.ask(:'T5', 'Rz2', format('select tutor_cancel_lesson(%L, ''Second change'')', t.id('Z2')));
select pg_temp.expect(:'T5', format('select tutor_cancel_lesson(%L, ''Third change'')', t.id('Z3')), 'LIMIT', 'two waiting requests use up a limit of two');
select pg_temp.expect(:'T5', format('select tutor_add_lesson(%L, %L, ''14:00''::time, ''15:00''::time)', :'Z', pg_temp.lday(46)), 'LIMIT', 'adding a lesson is counted too');
select pg_temp.expect(:'T5', format('select tutor_stop_slot(%L)', t.id('S_Z')), 'LIMIT', 'stopping a slot is counted too');
select pg_temp.expect(:'T5', format('select tutor_save_slot(null, %L, 3, ''13:00''::time, ''14:00''::time)', :'Z'), 'LIMIT', 'adding a slot is counted too');
select pg_temp.expect(:'T5', format('select tutor_postpone_lesson(%L, %L, ''12:00''::time, ''Another reason'')', t.id('Z3'), pg_temp.lday(60)), 'LIMIT', 'moving is counted too');
select pg_temp.expect(:'T5', format('select tutor_set_link(%L, null, ''https://meet.example.com/zed'')', :'Z'), 'ok', 'a link request is not counted');
select pg_temp.expect(:'T5', format('select tutor_generate_lessons(%L)', t.id('lp')), 'ok', '"create lessons" is not counted (a batch of agreed slots)');
select pg_temp.expect(:'T5', format('select tutor_cancel_request(%L)', t.id('Rz2')), 'ok', 'taking a request back gives the change back');
select pg_temp.expect(:'T5', format('select tutor_cancel_lesson(%L, ''Third change, now allowed'')', t.id('Z3')), 'ok', 'so the next one is allowed');
select pg_temp.call(:'T5', format('select tutor_my_schedule(%L, %L)', pg_temp.lday(0), pg_temp.lday(6))) as zsch \gset
select t.ok((select (o->>'changes_left')::int = 0 and (o->>'requests_pending')::int = 2 and (o->>'proposes')::boolean from jsonb_array_elements((:'zsch'::jsonb)->'orgs') o), 'the centre entry says: no changes left, two counted requests waiting (a link and a create-lessons request are not counted), you ask');
select t.ok((select count(*) = 1 from schedule_requests where id = t.id('Rz1') and status = 'pending'), 'the first request still waits');
-- approving counts as the tutor's change; and the limit is checked again when approving
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"tutors_propose","tutors_edit":{"postpone":true,"cancel":true,"weekly_slots":true,"generate":true,"one_off":true,"link":true},"min_notice_hours":24,"max_changes_per_month":1}');
select t.ok((select r::jsonb->>'status' = 'approved' from (select pg_temp.decide(:'STAFF', 'Rz1', 'approve') r) x), 'the limit was lowered to one: the first approval still works (used 0 of 1)');
select t.ok(public.tutor_changes_used(t.id('lp'), :'T5'::uuid, (select name from tz)) = 1, 'and it counts as one change of the tutor''s month');
select pg_temp.expect(:'T5', format('select tutor_cancel_lesson(%L, ''A change beyond the limit'')', t.id('Z4')), 'LIMIT', 'now the limit is reached for new requests');
select t.put('Rz3', (select id from schedule_requests where org_id = t.id('lp') and membership_id = t.id('m5') and kind = 'cancel' and lesson_id = t.id('Z3') and status = 'pending'));
select t.ok((select r::jsonb->>'status' = 'no_longer_possible' and r::jsonb->>'code' = 'LIMIT' from (select pg_temp.decide(:'STAFF', 'Rz3', 'approve') r) x), 'the second waiting request is no longer possible: the month''s changes are used up');
select t.ok((select status = 'scheduled' from lessons where id = t.id('Z3')), 'and its lesson is untouched');
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"tutors_propose","tutors_edit":{"postpone":true,"cancel":true,"weekly_slots":true,"generate":true,"one_off":true,"link":true},"min_notice_hours":24,"max_changes_per_month":0}');
-- the waiting "link" and "create lessons" requests of tutor five

-- ===================================================================== 12. approving a request whose start date has gone by ("create lessons" asked from a day that has passed starts today)
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"tutors_propose","tutors_edit":{"generate":true},"min_notice_hours":24}');
select t.put('Rg', (select id from schedule_requests where org_id = t.id('lp') and membership_id = t.id('m5') and kind = 'generate' and status = 'pending'));
update schedule_requests set payload = payload || jsonb_build_object('from', pg_temp.lday(-3), 'to', pg_temp.lday(27)) where id = t.id('Rg');
select t.ok((select r::jsonb->>'status' = 'approved' from (select pg_temp.decide(:'STAFF', 'Rg', 'approve') r) x), 'a "create lessons" request whose first day has passed still works (it starts today)');
select t.ok((select count(*) >= 3 and min(lesson_date) >= pg_temp.lday(0) from lessons where org_id = t.id('lp') and student_id = :'Z' and slot_id = t.id('S_Z') and created_by_tutor = t.id('m5')), 'and made no lesson in the past');
select pg_temp.settings('lp', :'OWNER', '{"timetable_editing":"tutors_propose","tutors_edit":{"postpone":true,"cancel":true,"weekly_slots":true,"generate":true,"one_off":true,"link":true},"min_notice_hours":24,"max_changes_per_month":0}');

-- ===================================================================== 13. "create lessons" with nothing to make, a slot already stopped, a link already set: not a request
select pg_temp.expect(:'T5', format('select tutor_generate_lessons(%L)', t.id('lp')), 'NOTHING_TO_DO', 'create lessons when everything is already there');
select pg_temp.expect(:'T1', format('select tutor_stop_slot(%L)', t.id('S_X')), 'NO_CHANGE', 'stop a slot that is already stopped');
select pg_temp.expect(:'T1', format('select tutor_set_link(%L, null, ''https://meet.example.com/wanted'')', :'F'), 'NO_CHANGE', 'a link that is already the link');

-- ===================================================================== 14. the lists a tutor reads show the buttons and the waiting request
select pg_temp.call(:'T1', format('select tutor_my_schedule(%L, %L)', pg_temp.lday(19), pg_temp.lday(60))) as sch2 \gset
select pg_temp.say(:'sch2');
select t.ok((select (o->>'proposes')::boolean and (o->>'can_postpone')::boolean and (o->>'can_cancel')::boolean and (o->>'can_one_off')::boolean and (o->>'can_slots')::boolean and (o->>'can_generate')::boolean and (o->>'can_link')::boolean
               from jsonb_array_elements((:'sch2'::jsonb)->'orgs') o), 'at tutors_propose the centre entry says proposes = true and every switch that is on');
select t.ok((select (e->>'can_cancel')::boolean and (e->>'can_postpone')::boolean from jsonb_array_elements((:'sch2'::jsonb)->'lessons') e where e->>'lesson_id' = t.id('W1')::text), 'a lesson shows its buttons (the dry run says it could be asked for)');
select t.ok((select e->'pending_request'->>'kind' = 'cancel' from jsonb_array_elements((:'sch2'::jsonb)->'lessons') e where e->>'lesson_id' = t.id('W1')::text), 'a lesson with a waiting request says so');
select t.ok((select e->'pending_request' is null or e->'pending_request' = 'null'::jsonb from jsonb_array_elements((:'sch2'::jsonb)->'lessons') e where e->>'lesson_id' = t.id('Q1')::text), 'and one without does not');
select pg_temp.call(:'T1', 'select jsonb_agg(to_jsonb(s)) from tutor_my_slots() s') as sl3 \gset
select t.ok((select s->>'can_change' = 'true' from jsonb_array_elements(:'sl3'::jsonb) s where s->>'slot_id' = t.id('S_F')::text), 'my slots: changeable at tutors_propose');
select pg_temp.ask(:'T1', 'Rslot2', format('select tutor_save_slot(%L, null, %s, ''18:00''::time, ''19:00''::time)', t.id('S_F'), pg_temp.wd(9)));
select pg_temp.call(:'T1', 'select jsonb_agg(to_jsonb(s)) from tutor_my_slots() s') as sl3 \gset
select t.ok((select s->>'pending_kind' = 'save_slot' or s->>'pending_kind' = 'stop_slot' from jsonb_array_elements(:'sl3'::jsonb) s where s->>'slot_id' = t.id('S_F')::text), 'my slots: a slot with a waiting request says so');
select pg_temp.call(:'T1', 'select tutor_my_students()') as ms \gset
select t.ok((select e->>'online_link' is not null from jsonb_array_elements(:'ms'::jsonb) e where e->>'name' = 'Fay'), 'my students: carries each student''s link');

-- ===================================================================== 15. no table access, no money, locked-down functions
select t.ok(pg_temp.call(:'T1', 'select count(*)::text from schedule_requests') like 'ERR:%', 'a tutor can''t read the requests table');
select t.ok(pg_temp.call(:'STAFF', 'select count(*)::text from schedule_requests') like 'ERR:%', 'staff can''t read it either (only the functions do)');
select t.ok(pg_temp.call(:'OWNER', 'select count(*)::text from schedule_requests') like 'ERR:%', 'nor the owner');
select t.ok(pg_temp.call(null, 'select count(*)::text from schedule_requests') like 'ERR:%', 'nor an anonymous visitor');
select t.ok(pg_temp.call(:'T1', format($q$ insert into schedule_requests(org_id, membership_id, kind, payload, target_key, expires_at) values (%L, %L, 'cancel', '{}', 'x', now() + interval '1 day') $q$, t.id('lp'), t.id('m1'))) like 'ERR:%', 'a tutor can''t write a request directly');
select t.ok(pg_temp.call(:'T1', format($q$ update schedule_requests set status = 'approved' where id = %L $q$, t.id('Rw1'))) like 'ERR:%', 'a tutor can''t approve their own request by writing the table');
select t.ok(pg_temp.call(:'STAFF', format($q$ update schedule_requests set status = 'approved' where id = %L $q$, t.id('Rw1'))) like 'ERR:%', 'staff can''t write it directly either');
select t.ok((select c.relrowsecurity from pg_class c where c.oid = 'public.schedule_requests'::regclass) and not has_table_privilege('authenticated', 'public.schedule_requests', 'select') and not has_table_privilege('anon', 'public.schedule_requests', 'select'),
            'row-level security is on and no signed-in or anonymous role has a grant');
select t.ok((select count(*) = 0 from pg_policies where tablename = 'schedule_requests'), 'and there is no policy on it');
select coalesce(string_agg(distinct k, ','), '') as badkeys from pg_temp.said s, lateral pg_temp.keys(case when s.txt like '{%' then s.txt::jsonb else '{}'::jsonb end) k where k ~* '(^|_)(rate|price|amount|paid|compens[a-z]*|charge|fee|cents|cost|fare|owe|balance|invoice)(_|$)' \gset
\echo money-like keys found: :badkeys
select t.ok(not exists (select 1 from pg_temp.said s, lateral pg_temp.keys(case when s.txt like '{%' then s.txt::jsonb else '{}'::jsonb end) k where k ~* '(^|_)(rate|price|amount|paid|compens[a-z]*|charge|fee|cents|cost|fare|owe|balance|invoice)(_|$)'),
            'no key of any answer a tutor received is a money word');
select t.ok(not exists (select 1 from pg_temp.said s where s.txt ~ '(12\.5|40\.0|SECRET)'), 'no price appears in any answer a tutor received');
select t.ok((select count(*) from pg_temp.said) >= 20, 'and there were answers to check (' || (select count(*) from pg_temp.said) || ')');
select pg_temp.call(:'STAFF', format('select staff_schedule_requests(%L, ''all'')', t.id('lp'))) as allr \gset
select t.ok(not exists (select 1 from pg_temp.keys(:'allr'::jsonb) k where k ~* '(^|_)(rate|price|amount|paid|compens[a-z]*|charge|fee|cents|cost|balance|invoice|contact)(_|$)'), 'the staff list has no money word and no phone number');
select t.ok((select count(*) = 100 or count(*) > 30 from jsonb_array_elements((:'allr'::jsonb)->'rows')), 'and it lists many rows (' || jsonb_array_length((:'allr'::jsonb)->'rows') || ')');
select t.ok(not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace
          and p.proname in ('tutor_set_link', 'tutor_cancel_request', 'tutor_my_requests', 'tutor_postpone_lesson', 'tutor_revert_lesson', 'tutor_cancel_lesson', 'tutor_add_lesson', 'tutor_save_slot', 'tutor_stop_slot', 'tutor_generate_lessons',
                            'tutor_submit', 'tutor_do', 'tutor_set_link_do', 'staff_schedule_requests', 'staff_decide_request', 'staff_set_lesson_link', 'tutor_my_schedule', 'tutor_my_slots', 'tutor_my_students', 'tutor_lesson_links')
          and pg_get_functiondef(p.oid) ~* '\m(rate|price|amount|paid|compensation|charge_note|charge|fee|cost|invoice[a-z]*|[a-z_]*_cents)\M'), 'no money word in the text of any function a tutor calls or the request functions use');
select t.ok((select count(*) = 17 and bool_and(p.prosecdef and p.proconfig::text like '%search_path=public%') from pg_proc p
              where p.pronamespace = 'public'::regnamespace and p.proname in ('tutor_set_link', 'tutor_cancel_request', 'tutor_my_requests', 'tutor_submit', 'tutor_do', 'tutor_set_link_do', 'staff_schedule_requests', 'staff_decide_request', 'staff_set_lesson_link',
                  'schedule_requests_expire', 'tutor_add_lesson_do', 'tutor_save_slot_do', 'tutor_stop_slot_do', 'tutor_generate_lessons_do', 'tutor_postpone_lesson', 'tutor_revert_lesson', 'tutor_cancel_lesson')), 'the new functions are SECURITY DEFINER with a pinned search_path');
select t.ok((select count(*) = 8 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('tutor_postpone_lesson', 'tutor_revert_lesson', 'tutor_cancel_lesson', 'tutor_add_lesson', 'tutor_save_slot', 'tutor_stop_slot', 'tutor_generate_lessons', 'tutor_set_link')
              and has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute')), 'the eight tutor actions: signed-in users may call them, anonymous may not');
select t.ok((select count(*) = 3 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('tutor_cancel_request', 'tutor_my_requests', 'staff_schedule_requests') and has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute'))
            and has_function_privilege('authenticated', 'staff_decide_request(uuid,text,text)', 'execute') and not has_function_privilege('anon', 'staff_decide_request(uuid,text,text)', 'execute')
            and has_function_privilege('authenticated', 'staff_set_lesson_link(uuid,uuid,text)', 'execute') and not has_function_privilege('anon', 'staff_set_lesson_link(uuid,uuid,text)', 'execute'), 'the request functions: signed in yes, anonymous no');
select t.ok(not has_function_privilege('authenticated', 'tutor_submit(text,jsonb)', 'execute') and not has_function_privilege('authenticated', 'tutor_do(text,jsonb)', 'execute')
        and not has_function_privilege('authenticated', 'tutor_set_link_do(uuid,uuid,text)', 'execute') and not has_function_privilege('authenticated', 'schedule_requests_expire(uuid)', 'execute')
        and not has_function_privilege('authenticated', 'tutor_add_lesson_do(uuid,date,time,time,text,text)', 'execute') and not has_function_privilege('authenticated', 'tutor_save_slot_do(uuid,uuid,int,time,time,text)', 'execute')
        and not has_function_privilege('authenticated', 'tutor_stop_slot_do(uuid)', 'execute') and not has_function_privilege('authenticated', 'tutor_generate_lessons_do(uuid,date,date)', 'execute')
        and not has_function_privilege('authenticated', 'tutor_change_apply(uuid,text,date,time,text)', 'execute') and not has_function_privilege('anon', 'tutor_do(text,jsonb)', 'execute'),
        'the dispatcher, the workers and the expiry can''t be called from the browser (the only way to a change at a tutors_propose centre is a request)');
select t.ok((select count(*) = 0 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('tutor_my_requests', 'staff_schedule_requests', 'tutor_my_schedule', 'tutor_my_students') and p.prorettype <> 'jsonb'::regtype), 'the lists return jsonb, no typed row');
-- no solo organisation was touched
select t.ok((select count(*) = 0 from schedule_requests r join organisations o on o.id = r.org_id where o.kind <> 'centre'), 'no request exists for a solo organisation');
-- a request disappears with its centre (nothing is left behind by an account deletion): the foreign key cascades
select t.ok((select confdeltype = 'c' from pg_constraint where conrelid = 'public.schedule_requests'::regclass and confrelid = 'public.organisations'::regclass), 'the table is covered by organisation deletion (on delete cascade)');
select t.ok(pg_temp.audits('schedule_request_created') >= 30 and pg_temp.audits('schedule_request_approved') >= 14, 'the audit trail is there (' || pg_temp.audits('schedule_request_created') || ' created, ' || pg_temp.audits('schedule_request_approved') || ' approved)');
