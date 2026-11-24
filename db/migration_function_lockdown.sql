-- =====================================================================================================
-- Lock down the organisation helper functions (Supabase security advisor)         undo: migration_function_lockdown_down.sql
-- =====================================================================================================
-- Supabase gives EXECUTE on every new function to anon and authenticated, which turns each one into a public API call
-- (/rest/v1/rpc/<name>). Three kinds of function here, three treatments:
--   1. Row-level-security helpers (org_can, org_can_read, org_role, org_is_platform_admin, org_is_solo): policies run as the
--      caller, so signed-in users KEEP execute (they only ever answer about the caller's own memberships); anonymous callers lose it.
--   2. Functions that take ANY user id (org_personal, org_is_member): a signed-in user could look up someone else's organisation id
--      or probe who belongs where. They are only called from other trusted functions and triggers, so nobody but the server may call them.
--   3. Trigger functions: never meant to be called as an API at all.
-- Also pins search_path on the four functions the advisor flagged (so a look-alike object in another schema can't be picked up).
-- No behaviour change for signed-in pages. Needs migration_org_foundation.sql; run it AFTER migration_org_delete.sql (that one
-- re-creates audit_immutable, which would drop the pinned search_path). Run on the DEV project first. Safe to run twice.
-- =====================================================================================================

-- 1. pinned search_path
alter function public.audit_immutable() set search_path = public;
alter function public.org_phone_key(text) set search_path = public;
alter function public.org_validate_settings(jsonb) set search_path = public;
alter function public.org_solo_settings(public.profiles) set search_path = public;

-- billing functions (only if migration_billing.sql is installed): pin the search_path of org_free_limit, and keep the plain
-- student count server-only (org_plan_status, which checks you belong to the organisation, is what the Plan screen calls;
-- the raw count would tell any signed-in user how big another organisation is)
do $$
begin
  if to_regprocedure('public.org_free_limit()') is not null then
    alter function public.org_free_limit() set search_path = public;
  end if;
  if to_regprocedure('public.org_active_students(uuid)') is not null then
    revoke all on function public.org_active_students(uuid) from public, anon, authenticated;
    grant execute on function public.org_active_students(uuid) to service_role;
  end if;
end $$;

do $$
declare f text;
begin
  -- 2. RLS helpers: signed-in yes, anonymous no
  foreach f in array array['org_can(uuid,text)','org_can_read(uuid)','org_role(uuid)','org_is_platform_admin()','org_is_solo(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
  -- 3. functions that accept any user id: server only
  foreach f in array array['org_personal(uuid)','org_is_member(uuid,uuid)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  -- 4. trigger functions: not an API
  foreach f in array array['audit_row()','audit_immutable()','org_row_guard()','students_household_after()','handle_new_user()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;
