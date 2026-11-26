-- =====================================================================
-- Google Calendar sync: remember which Google event each lesson created,
-- so the app can update it when the lesson changes and delete it if cancelled.
-- Run once in the Supabase SQL editor. Additive and backward-compatible.
-- =====================================================================
alter table public.lessons add column if not exists gcal_event_id text;
