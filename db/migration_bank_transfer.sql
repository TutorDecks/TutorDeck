-- =====================================================================
-- Bank-transfer payment method for overseas clients (no PayNow).
-- Run once in the Supabase SQL editor. Safe to re-run.
--
-- A student can be flagged pay_by_bank; their invoices then show the
-- tutor's bank-transfer details instead of the PayNow QR. Local clients
-- are unaffected (PayNow QR as before).
-- =====================================================================

-- Tutor's bank-transfer details (shown on bank-transfer invoices).
alter table public.profiles
  add column if not exists bank_account_name text,
  add column if not exists bank_name         text,
  add column if not exists bank_account_no   text,
  add column if not exists bank_swift         text;

-- Per-student marker: this client pays by bank transfer (overseas / no PayNow).
alter table public.students
  add column if not exists pay_by_bank boolean not null default false;
