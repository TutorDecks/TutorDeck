-- Function lockdown tests. Runs after org_delete_test.sql in the same throwaway database (reuses t.* and the organisations there).
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

-- ===================================================================== who may execute what
select t.ok(not has_function_privilege('anon', 'public.org_can(uuid,text)', 'execute'), 'anonymous cannot call org_can');
select t.ok(not has_function_privilege('anon', 'public.org_role(uuid)', 'execute'), 'anonymous cannot call org_role');
select t.ok(not has_function_privilege('anon', 'public.org_is_solo(uuid)', 'execute'), 'anonymous cannot call org_is_solo');
select t.ok(has_function_privilege('authenticated', 'public.org_can(uuid,text)', 'execute')
        and has_function_privilege('authenticated', 'public.org_can_read(uuid)', 'execute')
        and has_function_privilege('authenticated', 'public.org_role(uuid)', 'execute')
        and has_function_privilege('authenticated', 'public.org_is_platform_admin()', 'execute')
        and has_function_privilege('authenticated', 'public.org_is_solo(uuid)', 'execute'), 'signed-in users keep the helpers row-level security needs');
select t.ok(not has_function_privilege('authenticated', 'public.org_personal(uuid)', 'execute'), 'signed-in users cannot look up anyone''s organisation (org_personal)');
select t.ok(not has_function_privilege('authenticated', 'public.org_is_member(uuid,uuid)', 'execute'), 'signed-in users cannot probe memberships (org_is_member)');
select t.ok(has_function_privilege('service_role', 'public.org_personal(uuid)', 'execute') and has_function_privilege('service_role', 'public.org_is_member(uuid,uuid)', 'execute'), 'the server still can');
select t.ok(not has_function_privilege('anon', 'public.audit_row()', 'execute') and not has_function_privilege('authenticated', 'public.audit_row()', 'execute')
        and not has_function_privilege('authenticated', 'public.org_row_guard()', 'execute') and not has_function_privilege('authenticated', 'public.handle_new_user()', 'execute')
        and not has_function_privilege('authenticated', 'public.students_household_after()', 'execute'), 'trigger functions are not callable as an API');

select t.ok(not has_function_privilege('authenticated', 'public.org_active_students(uuid)', 'execute')
        and not has_function_privilege('anon', 'public.org_active_students(uuid)', 'execute')
        and has_function_privilege('service_role', 'public.org_active_students(uuid)', 'execute'), 'the raw student count is server-only (no peeking at other organisations)');
select t.ok(has_function_privilege('authenticated', 'public.org_plan_status(uuid)', 'execute'), 'but the Plan screen''s org_plan_status is still available to signed-in users');

-- the calls themselves are refused (not just the privilege flag)
select t.as('00000000-0000-0000-0000-0000000000a1'); set role authenticated;
select t.fails($q$ select org_personal('00000000-0000-0000-0000-0000000000b1') $q$, 'a signed-in tutor looking up another tutor''s organisation');
select t.fails($q$ select org_is_member(t.id('ben_org'), '00000000-0000-0000-0000-0000000000b1') $q$, 'a signed-in tutor probing someone''s membership');
select t.fails($q$ select org_active_students(t.id('centre')) $q$, 'a signed-in tutor reading another organisation''s student count');
reset role;
set role anon;
select t.fails($q$ select org_can(t.id('centre'), 'owner') $q$, 'an anonymous call to org_can');
reset role;

-- ===================================================================== pinned search_path
select t.ok((select bool_and(coalesce(p.proconfig::text, '') like '%search_path=public%') from pg_proc p
             where p.pronamespace = 'public'::regnamespace and p.proname in ('audit_immutable', 'org_phone_key', 'org_validate_settings', 'org_solo_settings', 'org_free_limit')),
            'the five flagged functions have a pinned search_path');

-- ===================================================================== signed-in pages still work (row-level security uses the helpers)
select t.as('00000000-0000-0000-0000-0000000000a1'); set role authenticated;
select t.ok((select count(*) from organisations where kind = 'solo') = 1, 'a solo tutor still sees exactly their own solo organisation (plus any centre they belong to, never anyone else''s)');
select t.ok(not exists (select 1 from organisations where id = t.id('ben_org')), 'and not another tutor''s');
select t.ok((select count(*) from students) >= 1, 'and their students');
insert into students(tutor_id, name) values ('00000000-0000-0000-0000-0000000000a1', 'After lockdown');
select t.ok(exists (select 1 from students where name = 'After lockdown'), 'a tutor can still add a student (the row guard and triggers still run)');
select t.ok((select org_role(t.id('tina_org'))) = 'owner', 'org_role still answers for the caller');
select t.ok((org_plan_status(t.id('tina_org'))->>'active_students')::int >= 1, 'the Plan screen''s org_plan_status still works for your own organisation');
reset role;
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select t.ok(org_can(t.id('centre'), 'owner'), 'a centre owner is still recognised as owner');
select t.eq((select count(*) from students where org_id = t.id('tina_org')), 0, 'and still can''t see another organisation''s students');
reset role;
-- anonymous reads get nothing (either an empty result or a refusal, never data)
set role anon;
do $$ declare n int; begin
  begin select count(*) into n from students; exception when others then n := 0; end;
  if n <> 0 then raise exception 'FAIL: anonymous read of students returned % rows', n; end if;
  raise notice 'PASS anonymous gets no student rows';
end $$;
reset role;

\echo ALL LOCKDOWN TESTS PASSED
