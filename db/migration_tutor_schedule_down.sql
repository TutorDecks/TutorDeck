-- Undo of migration_tutor_schedule.sql (T6 step 1). It only added two read-only functions, so this only drops them. Run BEFORE migration_staff_reassign_down.sql.
drop function if exists public.tutor_my_slots();
drop function if exists public.tutor_my_schedule(date, date);
