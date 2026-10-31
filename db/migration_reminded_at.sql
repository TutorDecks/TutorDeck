-- =====================================================================
-- "Reminded 3 Nov" on the Ledger (v244).
-- Run once in the Supabase SQL editor BEFORE the v244 code reaches dev or main
-- (previews use the same database). Safe to re-run.
--
-- Only ADDS one optional column. It does not change any existing row: it starts empty (null) for every
-- student. It's set when the tutor taps Remind (WhatsApp opens with the reminder). Until this is run,
-- Remind works as before, just without the "Reminded" note. students already has row-level security.
-- =====================================================================
alter table public.students add column if not exists reminded_at timestamptz;
