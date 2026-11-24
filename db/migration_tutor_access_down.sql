-- Undo for migration_tutor_access.sql (run it BEFORE migration_org_delete_down.sql / migration_billing_down.sql / migration_org_foundation_down.sql).
-- WARNING: drops who-teaches-what, session ids, attendance stamps and the remarks timestamp entered since.
drop trigger if exists lessons_taught_by_guard on public.lessons;
drop trigger if exists lessons_attendance_stamp on public.lessons;
drop function if exists public.tutor_my_lessons(date, date);
drop function if exists public.tutor_mark_attendance(uuid, text, text, text, text);
drop function if exists public.lessons_taught_by_guard();
drop function if exists public.lessons_attendance_stamp();
alter table public.lessons drop constraint if exists lessons_taught_by_same_org;
alter table public.lessons drop column if exists taught_by;
alter table public.lessons drop column if exists session_id;
alter table public.lessons drop column if exists attendance_marked_at;
alter table public.lessons drop column if exists attendance_marked_by;
alter table public.lessons drop column if exists remarks_at;
drop index if exists public.memberships_id_org;
