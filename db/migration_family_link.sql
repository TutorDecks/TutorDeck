-- =====================================================================
-- Family invoice link (v235): each saved invoice gets a long random code, so
-- the parent can open "tutordeck.vercel.app/pay?t=<code>" with no login and
-- see that one invoice (lessons, total, PayNow QR, paid or not).
--
-- Run once in the Supabase SQL editor BEFORE the v235 code reaches dev
-- (previews use the same database). Safe to re-run.
--
-- What it changes:
--   * invoices.share_token — a new column, filled with a random code for every
--     invoice (existing ones too). Nothing else on any row changes.
--   * invoice_by_token(t) — READ-ONLY lookup. Given one exact code it returns that
--     one invoice's number, dates, total, status and its saved invoice picture.
--     It can't list invoices, can't search, and can't change anything. Without
--     the exact code (122 random bits) there is nothing to find.
-- Row-level security on invoices is unchanged: tutors still only see their own.
-- =====================================================================

alter table public.invoices
  add column if not exists share_token uuid not null default gen_random_uuid();

create unique index if not exists invoices_share_token_idx
  on public.invoices (share_token);

create or replace function public.invoice_by_token(t uuid)
returns table (invoice_no text, issued_date date, total numeric, status text, paid_date date,
               html text, replaced_by text)
language sql
security definer
stable
set search_path = public
as $$
  select i.invoice_no, i.issued_date, i.total, i.status, i.paid_date,
         i.data->>'html', i.data->>'replaced_by'
  from public.invoices i
  where i.share_token = t
  limit 1;
$$;

revoke all on function public.invoice_by_token(uuid) from public;
grant execute on function public.invoice_by_token(uuid) to anon, authenticated;
