-- Undo of migration_centre_invoice_run.sql (T4 S2). Drops the invoice-run functions, the one-draft index and the two optional line columns.
-- Drafts and issued invoices already made stay in centre_invoices (they are S1 data); this only removes the S2 code.
drop function if exists public.centre_invoice_numbering(uuid);
drop function if exists public.centre_invoice_get(uuid);
drop function if exists public.centre_invoice_list(uuid, date, text);
drop function if exists public.centre_invoice_discard_draft(uuid, text);
drop function if exists public.centre_invoice_approve_all(uuid, date);
drop function if exists public.centre_invoice_approve(uuid);
drop function if exists public.centre_invoice_run_create_drafts(uuid, date);
drop function if exists public.centre_invoice_run_preview(uuid, date);
drop function if exists public.centre_invoice_issue_draft(uuid, date);
drop function if exists public.centre_invoice_run_prepare(uuid, date, date);
drop function if exists public.centre_invoice_run_rows(uuid, date, date);
drop function if exists public.centre_invoice_model_note(jsonb);
drop function if exists public.centre_invoice_month(date, date);
drop function if exists public.centre_invoicing_gate(uuid);
drop index if exists public.centre_invoices_one_draft;
drop index if exists public.centre_invoice_lines_fee;
alter table public.centre_invoice_lines drop constraint if exists centre_invoice_lines_student_fk;
alter table public.centre_invoice_lines drop constraint if exists centre_invoice_lines_fee_kind_check;
alter table public.centre_invoice_lines drop column if exists fee_kind;
alter table public.centre_invoice_lines drop column if exists student_id;
