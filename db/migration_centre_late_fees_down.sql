-- Undo of migration_centre_late_fees.sql (T4 S6). Drops the late-fee table and functions and puts the invoice-line check back as the S2 migration made it.
-- Late-fee DOCUMENTS already issued stay: they are ordinary issued invoices (kind 'late_fee' was allowed from S1) and are immutable. Their lines keep the
-- fee_kind 'late_fee', so the restored check is added NOT VALID (it still refuses new rows, but doesn't fail on those).
drop function if exists public.centre_late_fee_invoice_get(uuid);
drop function if exists public.centre_late_fee_list(uuid);
drop function if exists public.centre_late_fee_waive(uuid, text);
drop function if exists public.centre_late_fee_approve_all(uuid);
drop function if exists public.centre_late_fee_approve(uuid);
drop function if exists public.centre_late_fee_note(jsonb);
drop function if exists public.centre_late_fee_gate(uuid);
drop function if exists public.centre_late_fee_scan(uuid, date);
drop function if exists public.centre_invoice_balance_on(uuid, date);
drop table if exists public.centre_late_fees;
drop function if exists public.centre_late_fee_guard();
do $$
declare c record;
begin
  for c in select conname from pg_constraint where conrelid = 'public.centre_invoice_lines'::regclass and contype = 'c'
            and pg_get_constraintdef(oid) like '%fee_kind%' and pg_get_constraintdef(oid) like '%late_fee%' loop
    execute format('alter table public.centre_invoice_lines drop constraint %I', c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conrelid = 'public.centre_invoice_lines'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%fee_kind%') then
    alter table public.centre_invoice_lines add constraint centre_invoice_lines_fee_kind_check
      check (fee_kind is null or fee_kind in ('registration', 'materials', 'sibling_discount')) not valid;
  end if;
end $$;
