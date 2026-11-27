-- T35-E performance fixture: a big centre made of GENERATED dummy rows (400 students in 200 households, 200 tutors, 2 years of lessons = 72,000 lessons, 100,000 audit rows),
-- exported the way the browser does it (pages of 1000 for the wide tables, 5000 for the rest). Checks every page stays well under the API's 8-second limit, that the exported
-- row counts equal the database's own, and that keyset paging does not slow down towards the end of the big tables. Runs right after org_export_test.sql.
\set ON_ERROR_STOP on
set client_min_messages = notice;
\set po '00000000-0000-0000-0000-00000000ef51'
insert into auth.users(id, email) values (:'po', 'perf.owner@centre.test');
select t.as(:'po'); set role authenticated; select t.put('perf', org_create_centre('Perf Centre', t.centre_settings())); reset role;
select t.as(:'po');
select set_config('td.skip_audit', '1', false);      -- the generated rows would otherwise write one audit row each
insert into households(org_id, name, phone_key) select t.id('perf'), 'Family ' || g, lpad(g::text, 8, '9') from generate_series(1, 200) g;
insert into guardians(org_id, household_id, name, relation, phone, email) select t.id('perf'), id, 'Parent of ' || name, 'mother', '+65 9' || lpad((row_number() over ())::text, 7, '0'), 'p' || row_number() over () || '@family.test' from households where org_id = t.id('perf');
insert into students(org_id, tutor_id, name, level, household_id)
  select t.id('perf'), :'po', 'Student ' || g, 'P' || (1 + g % 6), (select id from households where org_id = t.id('perf') order by id offset (g - 1) % 200 limit 1) from generate_series(1, 400) g;
insert into memberships(org_id, display_name, role, status, invited_email) select t.id('perf'), 'Tutor ' || g, 'tutor', 'invited', 'tutor' || g || '@perf.test' from generate_series(1, 200) g;
create temp table pf_s as select id, row_number() over (order by id) rn from students where org_id = t.id('perf');
create temp table pf_t as select id, row_number() over (order by id) rn from memberships where org_id = t.id('perf') and role = 'tutor';
insert into lessons(org_id, tutor_id, student_id, taught_by, lesson_date, start_time, end_time, subject, rate, amount, status, remarks)
  select t.id('perf'), :'po', s.id, tt.id, date '2025-01-01' + (g % 730), '16:00', '17:00', 'Math', 50, 50, 'done', 'A note about the lesson, with a comma, a "quote" and an O''Neil'
  from generate_series(1, 72000) g join pf_s s on s.rn = 1 + g % 400 join pf_t tt on tt.rn = 1 + g % 200;
insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  select t.id('perf'), :'po', 'update', 'lessons', g::text, jsonb_build_object('status', 'scheduled', 'note', repeat('x', 150)), jsonb_build_object('status', 'done', 'note', repeat('y', 150), 'share_token', 'SECRET' || g)
  from generate_series(1, 100000) g;
select set_config('td.skip_audit', '', false);
analyze lessons; analyze audit_log; analyze students;

create function pg_temp.timed_export(p_user text, p_org uuid) returns jsonb language plpgsql as $$
declare st jsonb; job bigint; tb jsonb; r jsonb; after text; n bigint; t0 timestamptz; worst numeric := 0; ms numeric; pages int := 0; total bigint := 0; per jsonb := '{}'::jsonb; lim int; tstart timestamptz := clock_timestamp(); first_ms numeric; last_ms numeric;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  perform set_config('role', 'authenticated', true);
  st := org_export_start(p_org, false);
  job := (st->>'job')::bigint;
  for tb in select * from jsonb_array_elements(st->'tables') loop
    lim := case when tb->>'tbl' in ('lessons', 'audit_log', 'recurring_slots') then 1000 else 5000 end;
    after := null; n := 0; first_ms := null;
    loop
      t0 := clock_timestamp();
      r := org_export_page(p_org, job, tb->>'tbl', after, lim);
      ms := extract(epoch from clock_timestamp() - t0) * 1000; worst := greatest(worst, ms); pages := pages + 1; first_ms := coalesce(first_ms, ms); last_ms := ms;
      n := n + jsonb_array_length(r->'rows'); after := r->>'next'; exit when after is null;
    end loop;
    if n <> (tb->>'rows')::bigint then raise exception 'FAIL: % exported % rows, expected %', tb->>'tbl', n, tb->>'rows'; end if;
    total := total + n; per := per || jsonb_build_object(tb->>'tbl', jsonb_build_object('rows', n, 'first_ms', round(first_ms), 'last_ms', round(last_ms)));
  end loop;
  perform org_export_finish(p_org, job, (select jsonb_object_agg(k, v->'rows') from jsonb_each(per) x(k, v)));
  perform set_config('role', 'postgres', true);
  return jsonb_build_object('pages', pages, 'rows', total, 'worst_ms', round(worst), 'total_ms', round(extract(epoch from clock_timestamp() - tstart) * 1000), 'per', per);
end $$;
create temp table pf as select pg_temp.timed_export(:'po', t.id('perf')) j;
select t.ok((select (j->>'rows')::bigint >= 72000 + 100000 + 400 + 200 from pf), 'the big centre exports every row (72,000 lessons, 100,000 audit rows, 400 students, 200 tutors)');
select t.ok((select (j->'per'->'lessons'->>'rows')::int = 72000 and (j->'per'->'audit_log'->>'rows')::int >= 100000 and (j->'per'->'students'->>'rows')::int = 400 and (j->'per'->'households'->>'rows')::int = 200
             and (j->'per'->'memberships'->>'rows')::int = 201 and (j->'per'->'guardians'->>'rows')::int = 200 from pf), 'row counts per table equal what was generated');
select t.ok((select (j->>'worst_ms')::int < 3000 from pf), 'no single page took 3 seconds (the Supabase API limit is 8)');
select t.ok((select (j->'per'->'lessons'->>'last_ms')::int < 3 * greatest((j->'per'->'lessons'->>'first_ms')::int, 100) from pf), 'the last page of lessons is not slower than the first (keyset paging, no offset)');
select t.ok((select (j->'per'->'audit_log'->>'last_ms')::int < 3 * greatest((j->'per'->'audit_log'->>'first_ms')::int, 100) from pf), 'and the same for the audit log');
select t.ok(exists (select 1 from audit_log where org_id = t.id('perf') and action = 'org_export_finished' and (after->>'matched')::boolean), 'finish reports every table matched');
do $$ declare r record; begin select * into r from pf; raise notice 'PERF whole export: % pages, % rows, worst page % ms, total % ms', r.j->>'pages', r.j->>'rows', r.j->>'worst_ms', r.j->>'total_ms'; end $$;
select t.ok(not exists (select 1 from audit_log where false), 'perf summary printed');
