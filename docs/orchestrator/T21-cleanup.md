# T21 — remove the throwaway test login and its test centre (DEV only)

**DEV-ONLY.** Project `tuzxsqkfzrjssnpcoale` (dummy data). Nothing here may ever run on LIVE (`rnjvswkejbrhbaytutai`). Nothing in this branch is a migration;
the scripts live in `docs/orchestrator/t21/`, create no functions or tables, and are tested by `bash tests/sql/t21_cleanup_test.sh` (throwaway local Postgres).

## What goes, and why it needs its own script

| What | Match rule |
|---|---|
| The login | `auth.users.email like 't2-throwaway-%@example.test'` **and** created on 2026-11-24 (UTC), **exactly one** match |
| Its solo organisation | kind `solo`, created 2026-11-24, reached through the login's membership |
| Its centre | kind `centre`, trading name `T2 Test Centre`, created 2026-11-24, reached through the login's membership |
| Everything inside them | every row of every table that points at either organisation (found from the catalogue, like `org_delete_solo`), plus the login's own profile / Google link / error log |

The five demo logins (`centre.owner@`, `tutor.one@`, `tutor.two@`, `both.tutor@`, `solo.tutor@` `example.test`) cannot match the pattern, and the script also refuses if the match is one of them.

* **Solo organisation:** the app's own `org_delete_solo(org, user)` is reused. It refuses while the login still belongs to a centre, so the centre goes first.
* **Centre:** `org_delete_solo` and `api/delete-account.js` both refuse centres, and there is no centre deletion yet. The script does the same steps by hand, inside one transaction: unlock the append-only guard for exactly that organisation id (`td.deleting_org`, transaction-local, only works for non-browser roles and never for UPDATE), switch off audit copying (`td.skip_audit`) so the deleted rows are not copied into the audit log, `delete from organisations` (cascades), delete the leftovers with no key (`audit_log`), prove nothing points at it, then add **one anonymous** `org_deleted` audit row (`kind: centre`), the same as the owner's rule for solo deletion.
* **The login:** `delete from auth.users` last. The existing `org_before_user_delete` trigger finds no organisation left, and profile, Google link, error log, identities and sessions cascade.
* **Not done by SQL (the script aborts if any exists):** Stripe customer / subscription (cancel in the Stripe sandbox first), storage files (the database cannot delete them), a Google Calendar link (revoke at Google first), an organisation logo. A throwaway that never subscribed or uploaded has none.
* **Never hand-delete the rows** from the SQL editor: with the audit trigger on, that copies names and phone numbers into the append-only audit log, which is exactly what the flags above avoid.
* No password is needed or created. Nobody signs in as the throwaway.

## How the script protects the other data

Before deleting: DEV fingerprint (at least 3 of the 5 demo logins exist; LIVE has none); exactly one login; exactly two organisations (1 solo + 1 centre named `T2 Test Centre`); each has only this login as a member (no invites); not a platform admin; created no other organisation; no other organisation's grants/guardians point at it; no Stripe ids, Google link, logo or storage files; the ids and **per-table row counts must equal the pasted preview** exactly.
After deleting, still inside the same transaction: the size of **every** public table (and `auth.users`) is compared with its size before. Only the expected rows may have gone (`audit_log` is expected to be `-deleted + 2` anonymous rows). No row in any public table may still mention the login id, either organisation id or the login's email. The demo logins must be unchanged. Any failed check raises an error and **rolls everything back**.
`v_dry_run := true` (the default) does the whole job and then raises `DRY RUN OK` so it is always rolled back: a rehearsal on DEV itself.

## Steps (owner approves after step 1)

1. **Preview** (read-only): run `preview.sql` below. Every CHECK must say PASS. Review the `WOULD DELETE` rows and the login/organisation ids. Copy the `PASTE_THIS` value (it already includes the quotes and `::jsonb`).
2. **Rehearsal**: paste the `delete.sql` below in the Supabase SQL editor (DEV project), replace `null` after `v_expected jsonb   :=` with the `PASTE_THIS` value, leave `v_dry_run := true`, run. The expected result is an error whose text starts with `DRY RUN OK`. Anything else (`ABORT` / `ROLLED BACK`) is a real finding: nothing changed, read the message.
3. **Real run**: only after the owner says yes, set `v_dry_run := false` and run again. Expected result: success (`T21 DONE` notice, which the editor may not show).
4. **Post-check** (read-only): paste the three ids and the email from `PASTE_THIS` (`user`, `solo_org`, `centre_org`, `email`) into `postcheck.sql` and run it. All CHECKs PASS.
If the preview counts changed between steps (someone used the account), step 2/3 abort: re-run the preview and paste again. A rare abort on "rows outside the expected set moved" can also be someone using DEV during the run: just run again.

## 1 · `preview.sql` (read-only)

```sql
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
```

## 2 · `delete.sql` (transaction; DEV only)

```sql
-- T21 STEP 2 — DELETE (DEV project tuzxsqkfzrjssnpcoale ONLY. NEVER run on LIVE.)
-- One DO block = one transaction: any failed check raises an error and EVERYTHING is rolled back.
-- Creates no functions or tables, so nothing stays behind. Re-uses the app's own org_delete_solo() for the solo organisation.
--
-- BEFORE RUNNING: (1) run preview.sql, every CHECK says PASS; (2) paste its PASTE_THIS value into v_expected below;
-- (3) leave v_dry_run := true for a rehearsal (does the whole job, then rolls back with a "DRY RUN OK" message);
--     set it to false for the real thing.
do $t21$
declare
  v_dry_run  boolean := true;          -- true = rehearsal: all checks run, then everything is rolled back
  v_expected jsonb   := null;          -- paste the PASTE_THIS value from preview.sql here, between the quotes:  '...'::jsonb

  c_email_like constant text   := 't2-throwaway-%@example.test';
  c_day        constant date   := date '2026-11-24';
  c_demo       constant text[] := array['centre.owner@example.test','tutor.one@example.test','tutor.two@example.test','both.tutor@example.test','solo.tutor@example.test'];
  u uuid; u_email text; solo uuid; centre uuid; orgs uuid[]; orgs_lit text; n bigint;
  r record; preds jsonb; del_rows jsonb := '{}'; before_c jsonb := '{}'; after_c jsonb := '{}'; want jsonb := '{}'; sol jsonb; needle text; bad text := '';
  demo_before bigint;
begin
  -- ---------------------------------------------------------------- 0. is this DEV, and was the preview pasted?
  select count(*) into demo_before from auth.users where email = any (c_demo);
  if demo_before < 3 then raise exception 'ABORT: this does not look like the DEV project (only % of the 5 demo logins exist). Nothing was changed.', demo_before; end if;
  if v_expected is null or jsonb_typeof(v_expected) <> 'object' or v_expected->'rows' is null then
    raise exception 'ABORT: paste the PASTE_THIS value from preview.sql into v_expected first. Nothing was changed.'; end if;

  -- ---------------------------------------------------------------- 1. find exactly the throwaway login and its two organisations
  select count(*) into n from auth.users where email like c_email_like and (created_at at time zone 'UTC')::date = c_day;
  if n <> 1 then raise exception 'ABORT: % logins match the throwaway pattern (need exactly 1). Nothing was changed.', n; end if;
  select id, email into u, u_email from auth.users where email like c_email_like and (created_at at time zone 'UTC')::date = c_day;
  if exists (select 1 from auth.users where id = u and email = any (c_demo)) then raise exception 'ABORT: that is a demo login'; end if;
  select array_agg(m.org_id order by m.org_id) into orgs from memberships m where m.user_id = u;
  if coalesce(cardinality(orgs), 0) <> 2 then raise exception 'ABORT: the login belongs to % organisations (need exactly 2)', coalesce(cardinality(orgs), 0); end if;
  select o.id into solo   from organisations o where o.id = any (orgs) and o.kind = 'solo'   and (o.created_at at time zone 'UTC')::date = c_day;
  select o.id into centre from organisations o where o.id = any (orgs) and o.kind = 'centre' and o.trading_name = 'T2 Test Centre' and (o.created_at at time zone 'UTC')::date = c_day;
  if solo is null or centre is null then raise exception 'ABORT: the two organisations are not 1 solo + 1 centre "T2 Test Centre" created on %', c_day; end if;
  if (select count(*) from memberships where org_id = any (orgs)) <> 2 then raise exception 'ABORT: someone else (or a pending invite) is in one of the organisations'; end if;
  if (v_expected->>'user')::uuid is distinct from u or v_expected->>'email' is distinct from u_email or (v_expected->>'solo_org')::uuid is distinct from solo or (v_expected->>'centre_org')::uuid is distinct from centre then
    raise exception 'ABORT: the ids in v_expected do not match what was found now (user %, solo %, centre %)', u, solo, centre; end if;

  -- ---------------------------------------------------------------- 2. nothing unexpected hangs off the login or the organisations
  if exists (select 1 from platform_admins where user_id = u) then raise exception 'ABORT: the login is a platform admin'; end if;
  if exists (select 1 from organisations where created_by = u and id <> all (orgs)) then raise exception 'ABORT: the login created another organisation'; end if;
  if exists (select 1 from support_access_grants where granted_by = u and org_id <> all (orgs))
     or exists (select 1 from guardians where user_id = u and org_id <> all (orgs)) then raise exception 'ABORT: another organisation''s rows point at the login'; end if;
  if exists (select 1 from org_subscriptions where org_id = any (orgs) and (stripe_customer_id is not null or stripe_subscription_id is not null)) then
    raise exception 'ABORT: a Stripe customer/subscription is attached: cancel it in Stripe (sandbox) first'; end if;
  if exists (select 1 from gcal_links where tutor_id = u) then raise exception 'ABORT: a Google Calendar link exists: revoke it at Google first'; end if;
  if exists (select 1 from organisations where id = any (orgs) and logo_path is not null) then raise exception 'ABORT: an organisation has a logo file in storage'; end if;
  if to_regclass('storage.objects') is not null then
    execute 'select count(*) from storage.objects where name like $1 or name like any ($2)' into n using u::text || '/%', array[solo::text || '/%', centre::text || '/%'];
    if n > 0 then raise exception 'ABORT: % storage file(s) belong to this login/organisations; delete them in the dashboard (Storage) or via the API first', n; end if;
  end if;

  -- ---------------------------------------------------------------- 3. count what is about to go, and compare it with the approved preview
  select string_agg(quote_literal(x::text) || '::uuid', ',') into orgs_lit from unnest(orgs) x;
  select coalesce(jsonb_object_agg(tbl, pred), '{}') into preds from (
    select tbl, string_agg(case k when 'org' then format('%I in (%s)', col, orgs_lit) else format('%I = %L', col, u) end, ' or ') as pred
    from (select tbl, col, 'org' as k from org_owned_columns()
          union all select 'organisations', 'id', 'org'
          union all select cl.relname::text, a.attname::text, 'user'
            from pg_constraint k join pg_class cl on cl.oid = k.conrelid
            join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any (k.conkey)
            where k.contype = 'f' and k.confrelid = 'auth.users'::regclass and k.confdeltype = 'c' and cl.relnamespace = 'public'::regnamespace) c
    group by tbl) x;
  for r in select key as tbl, value #>> '{}' as pred from jsonb_each(preds) loop
    execute format('select count(*) from public.%I where %s', r.tbl, r.pred) into n;
    if n > 0 then del_rows := del_rows || jsonb_build_object(r.tbl, n); end if;
  end loop;
  del_rows := del_rows || jsonb_build_object('auth.users', 1);
  if del_rows is distinct from (v_expected->'rows') then
    raise exception E'ABORT: the rows to delete differ from the approved preview (the account may have been used since).\nnow:      %\npreview:  %', del_rows, v_expected->'rows'; end if;

  -- snapshot of every public table's size (and auth.users), to prove afterwards that ONLY the expected rows moved
  for r in select table_name from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE' loop
    execute format('select count(*) from public.%I', r.table_name) into n;
    before_c := before_c || jsonb_build_object(r.table_name, n);
  end loop;
  select count(*) into n from auth.users; before_c := before_c || jsonb_build_object('auth.users', n);

  -- ---------------------------------------------------------------- 4. the centre (org_delete_solo refuses centres, so the same steps are done here)
  perform set_config('td.deleting_org', centre::text, true);   -- the append-only guard lets exactly this organisation's rows go (transaction-local)
  perform set_config('td.skip_audit', '1', true);              -- don't copy the deleted rows into the audit log
  delete from organisations where id = centre;                 -- cascades through every table that has an on-delete-cascade key
  for r in select * from org_owned_columns() loop              -- whatever has no key (audit_log, org-less future tables)
    execute format('delete from public.%I where %I = $1', r.tbl, r.col) using centre;
  end loop;
  for r in select * from org_owned_columns() loop
    execute format('select count(*) from public.%I where %I = $1', r.tbl, r.col) into n using centre;
    if n > 0 then raise exception 'INCOMPLETE: % row(s) in % still point at the centre', n, r.tbl; end if;
  end loop;
  perform set_config('td.deleting_org', '', true);
  perform set_config('td.skip_audit', '', true);
  insert into audit_log(org_id, actor, action, table_name, after)   -- like org_delete_solo: keep only the fact that a deletion happened
  values (null, null, 'org_deleted', 'organisations', jsonb_build_object('kind', 'centre'));

  -- ---------------------------------------------------------------- 5. the solo organisation: the app's own function (checks owner, sole member, no other org, then proves nothing is left)
  sol := org_delete_solo(solo, u);
  if coalesce((sol->>'deleted')::boolean, false) is not true then raise exception 'org_delete_solo did not delete: %', sol; end if;

  -- ---------------------------------------------------------------- 6. the login (profile, Google link, error log, auth identities/sessions cascade from it)
  perform set_config('td.skip_audit', '1', true);
  delete from auth.users where id = u;
  perform set_config('td.skip_audit', '', true);

  -- ---------------------------------------------------------------- 7. prove it: only the expected rows moved, and nothing mentions the login or organisations any more
  for r in select table_name from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE' loop
    execute format('select count(*) from public.%I', r.table_name) into n;
    after_c := after_c || jsonb_build_object(r.table_name, n);
  end loop;
  select count(*) into n from auth.users; after_c := after_c || jsonb_build_object('auth.users', n);
  for r in select key as tbl, (value #>> '{}')::bigint as n from jsonb_each(before_c) loop
    want := want || jsonb_build_object(r.tbl, r.n - coalesce((del_rows->>r.tbl)::bigint, 0) + case when r.tbl = 'audit_log' then 2 else 0 end);   -- +2 = the two anonymous "org_deleted" rows
  end loop;
  if after_c is distinct from want then
    for r in select key as tbl from jsonb_each(want) where want->key is distinct from after_c->key loop
      bad := bad || format(E'\n  %s: expected %s, found %s', r.tbl, want->r.tbl, after_c->r.tbl);
    end loop;
    raise exception 'ROLLED BACK: rows outside the expected set moved:%', bad;
  end if;
  foreach needle in array array[u::text, solo::text, centre::text, u_email] loop
    for r in select table_name from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE' loop
      execute format('select count(*) from public.%I x where x::text ilike $1', r.table_name) into n using '%' || needle || '%';
      if n > 0 then raise exception 'ROLLED BACK: % row(s) in % still mention %', n, r.table_name, needle; end if;
    end loop;
  end loop;
  if exists (select 1 from auth.users where id = u) or exists (select 1 from organisations where id = any (orgs)) then raise exception 'ROLLED BACK: the login or an organisation is still there'; end if;
  select count(*) into n from auth.users where email = any (c_demo);
  if n <> demo_before then raise exception 'ROLLED BACK: demo logins changed (% -> %)', demo_before, n; end if;

  -- ---------------------------------------------------------------- 8. rehearsal or the real thing
  if v_dry_run then
    raise exception E'DRY RUN OK: every check passed and EVERYTHING WAS ROLLED BACK (this "error" is the rehearsal succeeding).\nIt would delete: %', del_rows;
  end if;
  raise notice 'T21 DONE. Deleted: %', del_rows;
end
$t21$;
```

## 3 · `postcheck.sql` (read-only)

```sql
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
```

## Tests

`bash tests/sql/t21_cleanup_test.sh` (needs the scratch cluster of `tests/sql/run.sh`, port 54329) builds a throwaway database with all six migrations, seeds the **same shape** of data (a login created 2026-11-24 11:28 UTC with a solo organisation and a centre `T2 Test Centre`, data in every kind of table, the five demo logins, a demo centre and decoys that look alike: an older throwaway with its own `T2 Test Centre`, a pattern match on another day, another domain, another prefix) and checks: the preview finds only the throwaway; refusals (no preview pasted, other ids, changed counts) change nothing; the dry run rolls back completely; twelve dangerous situations abort with nothing changed (extra member, pending invite, Stripe id, Google link, second matching login, platform admin, other organisation created by the login, another organisation's grant, storage file, not DEV, centre renamed, row added since the preview); the real run leaves demo and decoy data byte-for-byte unchanged, the post-check passes, two anonymous audit rows remain, and a second run aborts harmlessly.
