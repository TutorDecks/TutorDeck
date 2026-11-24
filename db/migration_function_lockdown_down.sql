-- Undo for migration_function_lockdown.sql: back to Supabase's default (EXECUTE for anon and authenticated), search_path unpinned.
-- (Run it BEFORE migration_org_delete_down.sql.)
alter function public.audit_immutable() reset search_path;
alter function public.org_phone_key(text) reset search_path;
alter function public.org_validate_settings(jsonb) reset search_path;
alter function public.org_solo_settings(public.profiles) reset search_path;
do $$
declare f text;
begin
  foreach f in array array['org_can(uuid,text)','org_can_read(uuid)','org_role(uuid)','org_is_platform_admin()','org_is_solo(uuid)',
      'org_personal(uuid)','org_is_member(uuid,uuid)','audit_row()','audit_immutable()','org_row_guard()','students_household_after()','handle_new_user()'] loop
    execute format('grant execute on function public.%s to public, anon, authenticated, service_role', f);
  end loop;
end $$;
do $$
begin
  if to_regprocedure('public.org_free_limit()') is not null then alter function public.org_free_limit() reset search_path; end if;
  if to_regprocedure('public.org_active_students(uuid)') is not null then
    grant execute on function public.org_active_students(uuid) to public, anon, authenticated, service_role; end if;
end $$;
