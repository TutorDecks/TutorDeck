-- Undo for migration_tutor_profile.sql (run it FIRST, before migration_org_separation_down.sql).
-- WARNING: drops the phone numbers tutors entered.
drop function if exists public.tutor_my_profile();
drop function if exists public.tutor_save_profile(uuid, text, text, boolean);
alter table public.memberships drop constraint if exists memberships_phone_sg;
alter table public.memberships drop column if exists phone;
