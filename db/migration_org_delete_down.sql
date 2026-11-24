-- Undo for migration_org_delete.sql (run it BEFORE migration_billing_down.sql / migration_org_foundation_down.sql).
-- Puts the append-only guard back exactly as migration_org_foundation.sql made it (no exception for deletion).
drop trigger if exists org_before_user_delete on auth.users;
drop function if exists public.org_before_user_delete();
drop function if exists public.org_delete_solo(uuid, uuid);
drop function if exists public.org_owned_columns();
create or replace function public.audit_immutable() returns trigger language plpgsql as $$
begin raise exception '% is append-only', tg_table_name; end $$;
