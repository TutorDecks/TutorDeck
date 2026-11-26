-- Undo of migration_staff_attendance.sql (T3 step 3). Drops the guard trigger and the four functions; nothing else was changed.
drop function if exists public.staff_correct_attendance(uuid, text, text);
drop function if exists public.staff_mark_attendance(uuid, text, text);
drop function if exists public.staff_lessons(uuid, date, date, uuid, text, int, int);
drop function if exists public.staff_attendance_gate(uuid, boolean);
drop trigger if exists lessons_attendance_guard on public.lessons;
drop function if exists public.lessons_attendance_guard();
