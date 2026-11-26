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
