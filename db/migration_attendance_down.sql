-- Undo for migration_attendance.sql (run it BEFORE migration_billing_down.sql / migration_org_foundation_down.sql).
-- WARNING: drops the attendance and trial values entered since.
drop function if exists public.org_active_students_in_month(uuid, date);
alter table public.lessons drop constraint if exists lessons_attendance_check;
alter table public.lessons drop column if exists attendance;
alter table public.lessons drop column if exists trial;
