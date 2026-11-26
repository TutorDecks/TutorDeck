-- Undo of migration_staff_timetable.sql (T3 step 6). Only drops the function; nothing else was changed.
drop function if exists public.staff_timetable(uuid, date, date, uuid, uuid, uuid, int, boolean, int);
