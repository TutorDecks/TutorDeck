-- =====================================================================
-- Invoice proof-of-payment: store the path to a transaction screenshot
-- attached to each invoice (the receipt that proves the paid date/amount).
-- Run once in the Supabase SQL editor. Additive and backward-compatible.
-- =====================================================================
alter table public.invoices add column if not exists proof_path text;
