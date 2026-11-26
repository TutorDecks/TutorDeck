-- =====================================================================================================
-- Deleting a solo tutor's account: remove EVERYTHING of theirs in the database      undo: migration_org_delete_down.sql
-- =====================================================================================================
-- Why: after migration_org_foundation.sql, deleting the login (auth.users) no longer removes all of a tutor's data.
-- Their organisation, settings (PayNow / bank details), parents' names and phone numbers (households, guardians),
-- Stripe ids and the audit log hang off `organisations`, which only does `on delete set null` for created_by.
-- Worse, the audit log copies student / lesson / invoice rows (names, phones) and can't be deleted.
--
-- What this adds (needs migration_org_foundation.sql; works with or without migration_billing.sql):
--   1. org_delete_solo(org, user): deletes the whole organisation and every row that belongs to it, in ONE
--      transaction, then checks that nothing is left (if anything is, everything is rolled back).
--      Callable by the server (service_role) only. Solo organisations only (centres come later).
--   2. The ONE exception to "the audit log, settings and fee snapshots are append-only": a DELETE is allowed
--      when org_delete_solo has set the session flag td.deleting_org to that exact organisation id, and only
--      for rows of that organisation, and never for the browser roles. Updates stay blocked for everyone.
--   3. A safety net: deleting a user from auth.users (Supabase dashboard, the old Edge Function, anything)
--      now removes their solo organisation first, so the cascade can never again leave their data behind.
--      A user who belongs to a centre is refused until centre deletion exists.
-- Audit log (owner's decision, 2026-11-24): every audit row of the deleted organisation is deleted, and ONE
-- anonymous row is added (action 'org_deleted', no organisation, no person, no ids) saying a deletion happened.
-- Not in the database (done by api/delete-account.js): Stripe subscription + customer, storage files, Google token.
-- Run on the DEV project first. Safe to run twice.
-- =====================================================================================================

-- ---------------------------------------------------------------- the append-only guard, with ONE narrow exception
-- Originally: any update or delete raises "<table> is append-only".
-- Now: a DELETE of a row is allowed only while td.deleting_org equals that row's own org_id and the caller is
-- not one of the browser roles. td.deleting_org is set (transaction-local) by org_delete_solo and nothing else;
-- even if someone set it by hand, it unlocks a single organisation's rows and never UPDATE.
create or replace function public.audit_immutable() returns trigger language plpgsql as $$
declare gate text := coalesce(current_setting('td.deleting_org', true), '');
begin
  if tg_op = 'DELETE' and gate <> '' and gate = coalesce(to_jsonb(old)->>'org_id', '')
     and current_user not in ('anon', 'authenticated', 'service_role') then
    return old;
  end if;
  raise exception '% is append-only', tg_table_name;
end $$;

-- ---------------------------------------------------------------- the deletion
-- Every (table, column) that points at an organisation: a column called org_id, or a foreign key to organisations.
-- Catalog-driven, so a table added in a later phase is covered (and checked) without anyone remembering to edit this.
create or replace function public.org_owned_columns() returns table(tbl text, col text)
language sql stable set search_path = public as $$
  select c.table_name::text, c.column_name::text
  from information_schema.columns c join information_schema.tables t
    on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
  where c.table_schema = 'public' and c.column_name = 'org_id' and c.table_name <> 'organisations'
  union
  select cl.relname::text, a.attname::text
  from pg_constraint k join pg_class cl on cl.oid = k.conrelid
  join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any (k.conkey)
  where k.contype = 'f' and k.confrelid = 'public.organisations'::regclass and cl.relnamespace = 'public'::regnamespace
    and cl.relname <> 'organisations'
$$;

-- p_user must be the owner of p_org (the server takes it from the signed-in token, never from the request body).
-- Returns how many rows went from each table (counts only, no content), or {deleted:false} if the organisation is
-- already gone, so a retry after a half-finished deletion is harmless.
create or replace function public.org_delete_solo(p_org uuid, p_user uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o organisations; r record; n bigint; counts jsonb := '{}'::jsonb;
begin
  select * into o from organisations where id = p_org;
  if not found then return jsonb_build_object('deleted', false, 'reason', 'not_found'); end if;
  if o.kind <> 'solo' then raise exception 'ONLY_SOLO: only a solo organisation can be deleted this way' using errcode = '42501'; end if;
  if not exists (select 1 from memberships where org_id = p_org and user_id = p_user and role = 'owner') then
    raise exception 'NOT_OWNER: this user does not own that organisation' using errcode = '42501'; end if;
  if exists (select 1 from memberships where org_id = p_org and user_id is distinct from p_user) then
    raise exception 'HAS_MEMBERS: the organisation has other people in it' using errcode = '42501'; end if;
  if exists (select 1 from memberships where user_id = p_user and org_id <> p_org) then
    raise exception 'HAS_OTHER_ORGS: this person also belongs to a tuition centre; leave it first' using errcode = '42501'; end if;

  -- count first (so the caller can log "N students, M lessons" without ever seeing the data)
  for r in select * from org_owned_columns() loop
    execute format('select count(*) from public.%I where %I = $1', r.tbl, r.col) into n using p_org;
    if n > 0 then counts := counts || jsonb_build_object(r.tbl, coalesce((counts->>r.tbl)::bigint, 0) + n); end if;
  end loop;

  -- unlock exactly this organisation, and don't write new audit rows (each deleted row would otherwise be copied
  -- into the audit log, with its names and phone numbers, as it is deleted). Both flags are transaction-local.
  perform set_config('td.deleting_org', p_org::text, true);
  perform set_config('td.skip_audit', '1', true);

  delete from organisations where id = p_org;             -- cascades through every table that has an on-delete-cascade key

  -- whatever has no key to organisations (audit_log, and any future table that only has an org_id column)
  for r in select * from org_owned_columns() loop
    execute format('delete from public.%I where %I = $1', r.tbl, r.col) using p_org;
  end loop;

  -- prove it: nothing may point at this organisation any more, otherwise undo the lot
  for r in select * from org_owned_columns() loop
    execute format('select count(*) from public.%I where %I = $1', r.tbl, r.col) into n using p_org;
    if n > 0 then raise exception 'INCOMPLETE: % row(s) in % still point at the organisation', n, r.tbl; end if;
  end loop;

  perform set_config('td.deleting_org', '', true);
  perform set_config('td.skip_audit', '', true);

  -- the one thing we keep: that a deletion happened. No organisation, no person, no ids.
  insert into audit_log(org_id, actor, action, table_name, after)
  values (null, null, 'org_deleted', 'organisations', jsonb_build_object('kind', 'solo'));

  return jsonb_build_object('deleted', true, 'rows', counts);
end $$;

-- ---------------------------------------------------------------- safety net: deleting a user deletes their solo organisation first
create or replace function public.org_before_user_delete() returns trigger
language plpgsql security definer set search_path = public as $$
declare o uuid;
begin
  o := org_personal(old.id);
  if o is not null then perform org_delete_solo(o, old.id); end if;
  return old;
end $$;
drop trigger if exists org_before_user_delete on auth.users;
create trigger org_before_user_delete before delete on auth.users for each row execute function public.org_before_user_delete();

-- ---------------------------------------------------------------- who may call what
-- Supabase grants EXECUTE on new functions to anon and authenticated by default, so take it away explicitly.
do $$
declare f text;
begin
  foreach f in array array['org_delete_solo(uuid,uuid)', 'org_before_user_delete()', 'org_owned_columns()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  execute 'grant execute on function public.org_delete_solo(uuid, uuid) to service_role';
  execute 'grant execute on function public.org_personal(uuid) to service_role';
end $$;
