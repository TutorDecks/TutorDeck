-- =====================================================================
-- Add a location to each student (where you teach them), shown on the calendar.
-- Run once in the Supabase SQL editor. Additive and backward-compatible —
-- nothing that predates it reads the column, so adding it can't break the app.
-- =====================================================================
alter table public.students add column if not exists location text;
