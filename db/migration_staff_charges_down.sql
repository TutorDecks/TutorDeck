-- Undo of migration_staff_charges.sql (T3 step 4). Drops the five new functions and the three helpers; nothing else was changed.
-- Charges already typed stay on the lessons (they are ordinary compensation values); the audit entries stay too (the log is append-only).
drop function if exists public.staff_set_charges(uuid[], text, bigint);
drop function if exists public.staff_set_charge(uuid, bigint, text);
drop function if exists public.staff_pending_charges(uuid, int, int);
drop function if exists public.pending_charge_count(uuid);
drop function if exists public.charge_suggestion_cents(text, text, bigint);
drop function if exists public.lesson_price_cents(numeric, numeric, time, time);
drop function if exists public.staff_charges_gate(uuid);
