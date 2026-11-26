-- Undo of migration_centre_payments.sql (T4 step S3): the family credit ledger, the share links and every function that migration added.
-- Payments, allocations and credit-note documents made through it stay in the S1 tables (they are money records); undo migration_centre_money_down.sql
-- afterwards to remove those too. Run the undo chain in reverse order.
drop function if exists public.centre_invoice_public(uuid);
drop function if exists public.centre_invoice_whatsapp(uuid);
drop function if exists public.centre_invoice_share_link(uuid, date, boolean);
drop function if exists public.centre_invoice_account_get(uuid);
drop function if exists public.centre_invoice_account_list(uuid, date, text);
drop function if exists public.centre_refund_family_credit(uuid, uuid, bigint, text, text, text);
drop function if exists public.centre_family_credit_get(uuid, uuid);
drop function if exists public.centre_issue_credit_note(uuid, bigint, text, jsonb);
drop function if exists public.centre_reverse_payment(uuid, text);
drop function if exists public.centre_record_payment(uuid, uuid, text, bigint, date, text, uuid[], text, text);
drop function if exists public.centre_credit_subtotal(bigint, int, boolean, boolean);
drop function if exists public.centre_sync_invoice_excess(uuid, text);
drop function if exists public.centre_overpay_mode(jsonb);
drop function if exists public.centre_credit_balance(uuid, uuid);
drop function if exists public.centre_invoice_household(uuid);
drop function if exists public.centre_balance_rows(uuid, uuid[]);
drop function if exists public.centre_pay_status(text, text, bigint, bigint, bigint, date, date);
drop function if exists public.centre_money_gate(uuid, text);
drop function if exists public.centre_fmt_money(bigint);
drop table if exists public.centre_invoice_share;
drop table if exists public.centre_family_credit;
drop function if exists public.centre_share_audit();
drop function if exists public.centre_family_credit_guard();
drop index if exists public.centre_invoices_open;
