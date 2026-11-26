-- =====================================================================
-- Error log: when a page crashes, a database request fails, or the security policy blocks
-- something on a signed-in tutor's device, the app writes one short row here so we find out
-- before they have to tell us. Run once in the Supabase SQL editor BEFORE the code that
-- writes to it lands on dev (previews share this database).
--
-- Who can see it: nobody through the app. Tutors can only INSERT their own rows (no select,
-- update or delete policy), so one tutor can never read another's errors. Read it yourself in
-- Supabase → Table Editor → client_errors, or with the query at the bottom.
-- Rows older than 90 days are removed automatically (see the trigger), matching the privacy policy.
-- =====================================================================
create table if not exists public.client_errors (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  tutor_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind        text not null check (kind in ('js','promise','db','csp')),
  page        text check (char_length(page) <= 200),
  message     text not null check (char_length(message) <= 500),
  detail      text check (char_length(detail) <= 4000),
  app_version text check (char_length(app_version) <= 20),
  user_agent  text check (char_length(user_agent) <= 300)
);
create index if not exists client_errors_created_idx on public.client_errors (created_at desc);
create index if not exists client_errors_tutor_idx on public.client_errors (tutor_id, created_at desc);

alter table public.client_errors enable row level security;

-- How many rows this tutor wrote in the last hour. SECURITY DEFINER so it can count rows the
-- tutor themselves cannot read (there is deliberately no select policy).
create or replace function public.client_errors_recent()
returns integer language sql stable security definer set search_path = public as $$
  select count(*)::int from public.client_errors
  where tutor_id = auth.uid() and created_at > now() - interval '1 hour';
$$;
revoke all on function public.client_errors_recent() from public;
grant execute on function public.client_errors_recent() to authenticated;

-- Insert only, only as yourself, and at most 30 reports an hour per tutor (stops a broken page
-- in a loop from flooding the table).
drop policy if exists "insert own errors" on public.client_errors;
create policy "insert own errors" on public.client_errors
  for insert to authenticated
  with check (tutor_id = auth.uid() and public.client_errors_recent() < 30);

-- Housekeeping: each insert also clears rows older than 90 days (cheap with the index).
create or replace function public.client_errors_prune()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from public.client_errors where created_at < now() - interval '90 days';
  return null;
end $$;
drop trigger if exists client_errors_prune on public.client_errors;
create trigger client_errors_prune after insert on public.client_errors
  for each statement execute function public.client_errors_prune();

-- ---------------------------------------------------------------------
-- Reading it (run any time): the last 7 days, same error grouped together.
--   select kind, message, page, app_version, count(*) as times,
--          count(distinct tutor_id) as tutors, max(created_at) as last_seen
--   from client_errors
--   where created_at > now() - interval '7 days'
--   group by 1,2,3,4 order by last_seen desc;
-- ---------------------------------------------------------------------
