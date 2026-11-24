-- T21 STEP 1 — READ-ONLY PREVIEW (DEV project tuzxsqkfzrjssnpcoale only). Changes nothing: one SELECT.
-- Shows exactly which login, organisations and rows the clean-up would remove, and runs the safety checks.
with
cfg as (select 't2-throwaway-%@example.test'::text as email_like, date '2026-11-24' as day,
        array['centre.owner@example.test','tutor.one@example.test','tutor.two@example.test','both.tutor@example.test','solo.tutor@example.test'] as demo),
u as (   -- the throwaway login: email prefix AND created that day (UTC). Demo logins can never match this pattern.
  select a.id, a.email, a.created_at from auth.users a, cfg
  where a.email like cfg.email_like and (a.created_at at time zone 'UTC')::date = cfg.day),
mem as ( -- its organisations (through its memberships)
  select m.org_id, m.role, m.status, o.kind, o.trading_name, o.created_at as org_created, o.logo_path
  from memberships m join u on u.id = m.user_id join organisations o on o.id = m.org_id),
ids as ( -- literals for the dynamic counts below
  select coalesce((select string_agg(quote_literal(org_id::text) || '::uuid', ',') from mem), 'null::uuid') as orgs,
         (select id from u limit 1) as uid),
cols as (
  select tbl, col, 'org' as k from org_owned_columns()
  union all select 'organisations', 'id', 'org'
  union all select cl.relname::text, a.attname::text, 'user'
    from pg_constraint k join pg_class cl on cl.oid = k.conrelid
    join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any (k.conkey)
    where k.contype = 'f' and k.confrelid = 'auth.users'::regclass and k.confdeltype = 'c' and cl.relnamespace = 'public'::regnamespace),
preds as (
  select tbl, string_agg(case k when 'org' then format('%I in (%s)', col, ids.orgs) else format('%I = %L', col, ids.uid) end, ' or ') as pred
  from cols, ids group by tbl),
cnt as (  -- rows that would be deleted, per table (a row that matches two ways is counted once)
  select tbl, (xpath('/row/c/text()', query_to_xml(format('select count(*) c from public.%I where %s', tbl, pred), false, true, '')))[1]::text::bigint as n
  from preds),
chk(ord, item, ok, detail) as (
  select 1, 'exactly one login matches the email prefix + created day', (select count(*) from u) = 1, (select count(*) || ' match: ' || coalesce(string_agg(email || ' (' || id || ', created ' || created_at || ')', '; '), '-') from u)
  union all select 2, 'it is not one of the 5 demo logins', not exists (select 1 from u, cfg where u.email = any (cfg.demo)), '-'
  union all select 3, 'DEV fingerprint: the demo logins exist here (LIVE has none)', (select count(*) from auth.users a, cfg where a.email = any (cfg.demo)) >= 3,
                (select count(*) from auth.users a, cfg where a.email = any (cfg.demo)) || ' of 5 demo logins found'
  union all select 4, 'exactly 2 organisations: 1 solo + 1 centre "T2 Test Centre"', (select count(*) from mem) = 2 and (select count(*) from mem where kind = 'solo') = 1
                and (select count(*) from mem where kind = 'centre' and trading_name = 'T2 Test Centre') = 1,
                (select coalesce(string_agg(kind || ' "' || trading_name || '" ' || org_id || ' created ' || org_created, '; '), '-') from mem)
  union all select 5, 'both organisations created on the same day', (select count(*) from mem, cfg where (org_created at time zone 'UTC')::date = cfg.day) = 2, '-'
  union all select 6, 'each organisation has exactly 1 member (this login) and no pending invites',
                (select count(*) from memberships where org_id in (select org_id from mem)) = 2, (select count(*) from memberships where org_id in (select org_id from mem)) || ' membership rows in total'
  union all select 7, 'the login is not a platform admin', not exists (select 1 from platform_admins p join u on u.id = p.user_id), '-'
  union all select 8, 'no organisation outside these two was created by this login', not exists (select 1 from organisations o join u on u.id = o.created_by where o.id not in (select org_id from mem)), '-'
  union all select 9, 'no other table points at this login in a way that would block or be orphaned',
                not exists (select 1 from support_access_grants g join u on u.id = g.granted_by where g.org_id not in (select org_id from mem))
                and not exists (select 1 from guardians g join u on u.id = g.user_id where g.org_id not in (select org_id from mem)), '-'
  union all select 10, 'no Stripe customer / subscription on either organisation (would need cancelling in Stripe first)',
                not exists (select 1 from org_subscriptions s where s.org_id in (select org_id from mem) and (s.stripe_customer_id is not null or s.stripe_subscription_id is not null)), '-'
  union all select 11, 'no Google Calendar link (token would need revoking at Google first)', coalesce((select n from cnt where tbl = 'gcal_links'), 0) = 0, '-'
  union all select 12, 'no organisation logo path set', not exists (select 1 from mem where logo_path is not null), '-'
  union all select 13, 'no storage files under the login or organisation folders (the database cannot delete files)',
                case when to_regclass('storage.objects') is null then true
                     else (xpath('/row/c/text()', query_to_xml(format('select count(*) c from storage.objects where name like %L or name like any (array[%s])', ids.uid || '/%',
                          coalesce((select string_agg(quote_literal(org_id::text || '/%'), ',') from mem), 'null')), false, true, '')))[1]::text::bigint = 0 end,
                case when to_regclass('storage.objects') is null then 'no storage schema here' else 'checked storage.objects' end
  from ids),
expected as (
  select jsonb_build_object('user', (select id from u), 'email', (select email from u), 'solo_org', (select org_id from mem where kind = 'solo'), 'centre_org', (select org_id from mem where kind = 'centre'),
         'rows', coalesce((select jsonb_object_agg(tbl, n) filter (where n > 0) from cnt), '{}'::jsonb) || jsonb_build_object('auth.users', (select count(*) from u))) as j)
select ord, 'CHECK' as section, item, case when ok then 'PASS' else 'FAIL' end as result, detail from chk
union all select 20, 'ALL CHECKS', 'every check above must say PASS before you continue', case when bool_and(ok) then 'PASS' else 'FAIL' end, '-' from chk
union all select 30, 'WOULD DELETE', tbl, n::text, '' from cnt where n > 0
union all select 31, 'WOULD DELETE', 'auth.users (the login itself)', (select count(*)::text from u), (select coalesce(string_agg(email || '  ' || id, '; '), '-') from u)
union all select 40, 'PASTE_THIS', 'copy this whole value over  null  in v_expected (step 2)', quote_literal(j::text) || '::jsonb', '' from expected
order by 1, 3;
