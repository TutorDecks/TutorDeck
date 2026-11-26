-- =====================================================================
-- Google Calendar "connect once" (v237).
-- Run once in the Supabase SQL editor BEFORE the v237 code reaches dev or main
-- (previews use the same database). Safe to re-run.
--
-- Only ADDS one new, empty table. It does not read or change any existing row.
--
-- One row per tutor who has connected Google Calendar:
--   google_email  which Google account they connected (shown as "… · Change account")
--   refresh_enc   their long-lived Google key, ENCRYPTED by the server (api/gcal.js) with a key that
--                 lives only in Vercel's environment variables. Without that key it is unreadable,
--                 so even the tutor's own browser can't use it; only the server function can.
--
-- Row-level security: each tutor can only see, add, change or delete their OWN row, same as every
-- other table (tutor_id = auth.uid()). The server function talks to Supabase as the signed-in tutor,
-- so no service-role key is needed anywhere. Deleting the TutorDeck account deletes the row.
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

alter table public.gcal_links add column if not exists calendar_id text;   -- for anyone who ran an earlier draft

-- Check (should return the 6 columns above, and rowsecurity = true):
-- select column_name from information_schema.columns where table_name = 'gcal_links';
-- select relrowsecurity from pg_class where relname = 'gcal_links';
