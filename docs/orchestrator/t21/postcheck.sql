-- T21 STEP 3 — POST-CHECK (read-only, DEV only). Shows that nothing of the throwaway is left.
-- Replace the three zero-uuids and the email with "user", "solo_org", "centre_org" and "email" from the preview's PASTE_THIS value.
with
p(u, solo, centre, email) as (values ('00000000-0000-0000-0000-000000000000'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'paste-the-email-here')),
tbls as (select table_name::text as t from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE'),
mention as (   -- rows in ANY public table that mention the login id, either org id, or the email prefix, in any column (JSON included)
  select t, (xpath('/row/c/text()', query_to_xml(format('select count(*) c from public.%I x where x::text ilike any (array[%L, %L, %L, %L])', t,
         '%' || p.u || '%', '%' || p.solo || '%', '%' || p.centre || '%', '%' || p.email || '%'), false, true, '')))[1]::text::bigint as n
  from tbls, p),
chk(ord, item, ok, detail) as (
  select 1, 'login is gone from auth.users (by id)', not exists (select 1 from auth.users a, p where a.id = p.u), '-'
  union all select 2, 'no login has the throwaway email', not exists (select 1 from auth.users a, p where a.email = p.email), '-'
  union all select 3, 'both organisations are gone', not exists (select 1 from organisations o, p where o.id in (p.solo, p.centre)), '-'
  union all select 4, 'no memberships for the login or the organisations', not exists (select 1 from memberships m, p where m.user_id = p.u or m.org_id in (p.solo, p.centre)), '-'
  union all select 5, 'no row in any public table mentions the login, the organisations or the email', coalesce((select sum(n) from mention), 0) = 0,
                coalesce((select string_agg(t || ': ' || n, ', ') from mention where n > 0), 'nothing found in ' || (select count(*) from tbls) || ' tables')
  union all select 6, 'the demo logins are still there', (select count(*) from auth.users where email in ('centre.owner@example.test','tutor.one@example.test','tutor.two@example.test','both.tutor@example.test','solo.tutor@example.test')) >= 3,
                (select count(*) from auth.users where email like '%@example.test') || ' @example.test logins remain'
  union all select 7, 'the only trace left is anonymous: org_deleted audit rows (no organisation, no person, no ids)', not exists (select 1 from audit_log where action = 'org_deleted' and (org_id is not null or actor is not null)),
                (select count(*) || ' anonymous org_deleted rows in total' from audit_log where action = 'org_deleted'))
select ord, 'CHECK' as section, item, case when ok then 'PASS' else 'FAIL' end as result, detail from chk
union all select 20, 'ALL CHECKS', 'every check above must say PASS', case when bool_and(ok) then 'PASS' else 'FAIL' end, '-' from chk
order by 1, 3;
