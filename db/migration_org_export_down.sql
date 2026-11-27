-- Undo for migration_org_export.sql. It only added functions, so this only drops them.
-- Audit rows written by exports ("org_export_started" / "org_export_finished" / "org_export_payout_full") stay: the audit log is append-only.
drop function if exists public.org_export_finish(uuid, bigint, jsonb);
drop function if exists public.org_export_page(uuid, bigint, text, text, int);
drop function if exists public.org_export_start(uuid, boolean);
drop function if exists public.org_export_job(uuid, bigint);
drop function if exists public.org_export_gate(uuid);
drop function if exists public.org_export_who(uuid, uuid);
drop function if exists public.org_export_catalog();
drop function if exists public.org_export_scrub(jsonb);
drop function if exists public.org_export_secret_keys();
