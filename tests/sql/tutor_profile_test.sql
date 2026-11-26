-- T24c step 1 tests: a centre tutor reads and edits ONLY their own name and phone, through two functions, with no table access.
-- Runs after org_separation_test.sql in the same throwaway database (reuses t.*, the 'centre' organisation and Tina's solo organisation). Made-up people only.
\set ON_ERROR_STOP on
set client_min_messages = notice;
grant usage on schema t to anon; grant select on t.ids to anon; grant execute on all functions in schema t to anon;   -- test helpers only

insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-000000008001', 'profile1@centre.test'), ('00000000-0000-0000-0000-000000008002', 'profile2@centre.test'),
  ('00000000-0000-0000-0000-000000008003', 'profile3@centre.test');
insert into memberships(org_id, user_id, display_name, role, permissions, status) values
  (t.id('centre'), '00000000-0000-0000-0000-000000008001', 'Profile One', 'tutor', '{}', 'active'),
  (t.id('centre'), '00000000-0000-0000-0000-000000008002', 'Profile Two', 'tutor', '{}', 'active'),
  (t.id('centre'), '00000000-0000-0000-0000-000000008003', 'Profile Three', 'tutor', '{}', 'disabled'),
  (t.id('tina_org'), '00000000-0000-0000-0000-000000008001', 'Profile One (second)', 'tutor', '{}', 'active');
select t.put('p1', (select id from memberships where user_id = '00000000-0000-0000-0000-000000008001' and org_id = t.id('centre')));
select t.put('p1b', (select id from memberships where user_id = '00000000-0000-0000-0000-000000008001' and org_id = t.id('tina_org')));
select t.put('p2', (select id from memberships where user_id = '00000000-0000-0000-0000-000000008002' and org_id = t.id('centre')));
select t.put('p3', (select id from memberships where user_id = '00000000-0000-0000-0000-000000008003' and org_id = t.id('centre')));

-- ===================================================================== reading
select t.as('00000000-0000-0000-0000-000000008001'); set role authenticated;
select t.eq((select count(*) from tutor_my_profile()), 2, 'a tutor sees one row per centre where they are an active tutor');
select t.ok((select email = 'profile1@centre.test' and phone is null from tutor_my_profile() where membership_id = t.id('p1')), 'with their own login email, and no phone yet');
select t.eq((select count(*) from tutor_my_profile() where display_name like 'Profile T%'), 0, 'and never anyone else''s row');
select t.eq((select count(*) from memberships where org_id = t.id('centre') and user_id is distinct from '00000000-0000-0000-0000-000000008001'), 0, 'a tutor can''t read anyone else''s membership in the centre (the old policy only shows their own row)');
select t.eq(t.rows($q$ update memberships set phone = '+6591234567', role = 'owner' where id = t.id('p1') $q$), 0, 'a direct update of memberships by a tutor changes nothing (no write policy)');
reset role;
select t.as('00000000-0000-0000-0000-000000008003'); set role authenticated;
select t.eq((select count(*) from tutor_my_profile()), 0, 'a disabled tutor sees no profile');
select t.fails($q$ select tutor_save_profile(t.id('p3'), 'Hacked', null) $q$, 'a disabled tutor saving');
reset role;

-- ===================================================================== saving
select t.as('00000000-0000-0000-0000-000000008001'); set role authenticated;
select tutor_save_profile(t.id('p1'), '  Pat Tan ', '9123 4567');
reset role;
select t.ok((select display_name = 'Pat Tan' and phone = '+6591234567' from memberships where id = t.id('p1')), 'name is trimmed, phone saved as +65 and 8 digits');
select t.ok((select display_name = 'Profile One (second)' from memberships where id = t.id('p1b')), 'the other centre keeps its own name by default');
select t.ok((select phone = '+6591234567' from memberships where id = t.id('p1b')), 'the phone is one number for the person, on every centre');
select t.ok((select display_name = 'Profile Two' and phone is null from memberships where id = t.id('p2')), 'another tutor in the same centre is untouched');
select t.as('00000000-0000-0000-0000-000000008001'); set role authenticated;
select tutor_save_profile(t.id('p1'), 'Pat Tan', '+65 8765-4321', true);
select tutor_save_profile(t.id('p1'), 'Pat Tan', '6591234567', false);
reset role;
select t.ok((select display_name = 'Pat Tan' from memberships where id = t.id('p1b')), 'with "all my centres" the name goes on every centre');
select t.ok((select phone = '+6591234567' from memberships where id = t.id('p1')), '+65 prefix with or without the plus is accepted');
select t.as('00000000-0000-0000-0000-000000008001'); set role authenticated;
select tutor_save_profile(t.id('p1'), 'Pat Tan', '');
reset role;
select t.ok((select phone is null from memberships where id = t.id('p1')), 'an empty phone clears it');
select t.as('00000000-0000-0000-0000-000000008001'); set role authenticated;
select t.fails($q$ select tutor_save_profile(t.id('p1'), '', null) $q$, 'an empty name');
select t.fails($q$ select tutor_save_profile(t.id('p1'), repeat('x', 81), null) $q$, 'a name over 80 characters');
select t.fails($q$ select tutor_save_profile(t.id('p1'), 'Pat', '12345678') $q$, 'a phone that is not a mobile (starts with 1)');
select t.fails($q$ select tutor_save_profile(t.id('p1'), 'Pat', '9123 456') $q$, 'a phone that is too short');
select t.fails($q$ select tutor_save_profile(t.id('p1'), 'Pat', '+44 7911 123456') $q$, 'a foreign number');
select t.fails($q$ select tutor_save_profile(t.id('p2'), 'Not mine', null) $q$, 'saving onto someone else''s membership');
select t.fails($q$ select tutor_save_profile(gen_random_uuid(), 'Nobody', null) $q$, 'saving onto a membership that does not exist');
reset role;
select t.ok((select display_name = 'Profile Two' from memberships where id = t.id('p2')), 'and the refused attempts changed nothing');

-- a tutor can never use these to change role, permissions or status
select t.ok((select role = 'tutor' and permissions = '{}' and status = 'active' from memberships where id = t.id('p1')), 'role, permissions and status are unchanged by saving a profile');
-- a staff member or owner (not a tutor membership) has no profile through these functions
select t.as('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
select t.eq((select count(*) from tutor_my_profile()), 0, 'the centre owner is not a tutor, so has no tutor profile here');
select t.fails($q$ select tutor_save_profile(t.id('p1'), 'Owner edit', null) $q$, 'the owner using the tutor function on a tutor');
reset role;

-- ===================================================================== grants
select t.ok(not has_function_privilege('anon', 'public.tutor_my_profile()', 'execute')
        and not has_function_privilege('anon', 'public.tutor_save_profile(uuid,text,text,boolean)', 'execute')
        and has_function_privilege('authenticated', 'public.tutor_my_profile()', 'execute')
        and has_function_privilege('authenticated', 'public.tutor_save_profile(uuid,text,text,boolean)', 'execute'), 'anonymous callers have no access; signed-in users do (each call checks who they are)');
set role anon;
select t.fails($q$ select * from tutor_my_profile() $q$, 'an anonymous call to tutor_my_profile');
reset role;
select t.ok(not exists (select 1 from pg_proc p where p.proname in ('tutor_my_profile', 'tutor_save_profile') and not (p.prosecdef and 'search_path=public' = any(p.proconfig))),
            'both functions are security definer with a pinned search_path');

\echo ALL TUTOR-PROFILE TESTS PASSED
