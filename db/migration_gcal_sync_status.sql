-- =====================================================================
-- Google Calendar: sync on the server (v251).
-- Run once in the Supabase SQL editor BEFORE the v251 code reaches dev or main
-- (previews use the same database). Safe to re-run.
--
-- Includes the "connect once" table from migration_gcal_links.sql (skipped if it already exists),
-- then ADDS four empty columns to it. It does not read or change any lesson, student or payment row.
--
--   sync_state       'running' | 'ok' | 'error'  — so you can leave the page while the server syncs
--   sync_note        what to show, e.g. "Synced ✓ 42 lessons in 6s · 3 added"
--   sync_started_at  when the current sync began (a 'running' older than 6 minutes counts as stopped)
--   sync_at          when the last sync finished
-- =====================================================================
create table if not exists public.gcal_links (
  tutor_id     uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  google_email text not null default '',
  calendar_id  text,
  refresh_enc  text not null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
alter table public.gcal_links enable row level security;
drop policy if exists "own gcal link" on public.gcal_links;
create policy "own gcal link" on public.gcal_links
  for all to authenticated
  using (tutor_id = auth.uid())
  with check (tutor_id = auth.uid());
alter table public.gcal_links add column if not exists calendar_id     text;
alter table public.gcal_links add column if not exists sync_state      text;
alter table public.gcal_links add column if not exists sync_note       text;
alter table public.gcal_links add column if not exists sync_started_at timestamptz;
alter table public.gcal_links add column if not exists sync_at         timestamptz;

-- Check (should list 10 columns, and rowsecurity = true):
-- select column_name from information_schema.columns where table_name = 'gcal_links' order by ordinal_position;
-- select relrowsecurity from pg_class where relname = 'gcal_links';
