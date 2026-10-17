-- v170: track when an invoice was sent to the parent (Saved → Sent → Paid).
-- Safe: adds one empty, nullable column. No existing rows are changed.
alter table public.invoices add column if not exists sent_at timestamptz;
