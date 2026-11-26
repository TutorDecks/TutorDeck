-- Undo of migration_staff_students.sql (T3 step 2). Only drops the functions; no table, column or row was changed by the migration.
-- (Students, households and guardians that staff added stay: they are the centre's data.)
drop function if exists public.staff_set_student_end(uuid, uuid, date);
drop function if exists public.staff_save_student(uuid, uuid, text, text, text, uuid, text, jsonb);
drop function if exists public.staff_student(uuid, uuid);
drop function if exists public.staff_students(uuid, text, text, int, int);
drop function if exists public.staff_clean_guardian(jsonb);
drop function if exists public.staff_students_gate(uuid);
