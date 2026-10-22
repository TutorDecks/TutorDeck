-- =====================================================================
-- Onboarding + get-paid flow (v226).
-- Run once in the Supabase SQL editor BEFORE the v226 code reaches dev or main
-- (previews use the same database). Safe to re-run.
--
-- Only ADDS columns. It does not change any existing row: every new column starts
-- empty (null) for everyone.
--
--   full_name            the tutor's own name ("What should we call you?"). Already
--                        exists on most projects (the signup trigger fills it from
--                        Google); "if not exists" makes this a no-op then.
--   welcomed_at          set when the tutor finishes or skips the Welcome screen.
--                        The Welcome screen only shows when this is empty AND the
--                        account has no students yet, so existing tutors never see it.
--   reminder_checked_at  set when the tutor opens the WhatsApp message templates in
--                        Settings ("Check your WhatsApp reminder message" ticks off).
--   getpaid_dismissed_at set when the tutor dismisses the "Get paid faster" card on Home
--                        (per account, so it stays dismissed on every device).
--
-- profiles already has row-level security ("own profile"), so each tutor can only
-- read and write these on their own row.
-- =====================================================================
alter table public.profiles
  add column if not exists full_name            text,
  add column if not exists welcomed_at          timestamptz,
  add column if not exists reminder_checked_at  timestamptz,
  add column if not exists getpaid_dismissed_at timestamptz;
