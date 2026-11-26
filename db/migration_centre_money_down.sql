-- Undo of migration_centre_money.sql (T4 step S1). Drops the five tables, their triggers and functions, and the one index it added.
-- ONLY safe while nothing real has been written to these tables (it deletes them). On LIVE there is nothing to lose until S2 ships.
drop table if exists public.centre_payment_allocations cascade;
drop table if exists public.centre_payments cascade;
drop table if exists public.centre_invoice_lines cascade;
drop table if exists public.centre_invoices cascade;
drop table if exists public.org_counters cascade;
drop function if exists public.centre_revenue_totals(uuid, date, date);
drop function if exists public.centre_set_opening_number(uuid, text, int);
drop function if exists public.centre_invoice_gst(uuid, bigint, date);
drop function if exists public.centre_next_number(uuid, text);
drop function if exists public.centre_gst_totals(bigint, int, boolean, boolean);
drop function if exists public.centre_div_round(bigint, bigint);
drop function if exists public.centre_counter_guard();
drop function if exists public.centre_invoice_guard();
drop function if exists public.centre_line_guard();
drop function if exists public.centre_payment_guard();
drop function if exists public.centre_payment_reversal_check();
drop function if exists public.centre_alloc_guard();
drop function if exists public.centre_money_audit();
drop function if exists public.centre_money_org_guard();
drop function if exists public.centre_money_deleting(uuid);
drop index if exists public.lessons_id_org;
