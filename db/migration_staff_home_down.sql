-- Undo of migration_staff_home.sql (T3 step 1). Only drops the function; nothing else was changed.
drop function if exists public.staff_home(uuid);
