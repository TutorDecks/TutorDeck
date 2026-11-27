-- Undo of migration_statement_matching.sql (T34 M0-M2): removes bank statement matching.
-- DESTRUCTIVE: the statement tables are dropped (imported lines still waiting, match records, payer links, saved mappings, batch history). Money is NOT touched:
-- every payment a match created stays (it is an ordinary centre payment), only the link from the payment back to its bank line is lost.
-- Run it BEFORE migration_centre_credit_undo_down.sql (undo chain in reverse order).
drop table if exists public.statement_payer_links cascade;
drop table if exists public.statement_matches cascade;
drop table if exists public.statement_lines cascade;
drop table if exists public.statement_fingerprints cascade;
drop table if exists public.statement_batches cascade;
drop table if exists public.statement_mappings cascade;
drop function if exists public.stmt_queue(uuid);
drop function if exists public.stmt_forget_payer(uuid);
drop function if exists public.stmt_undo(uuid, text);
drop function if exists public.stmt_ignore_out(uuid);
drop function if exists public.stmt_ignore(uuid);
drop function if exists public.stmt_confirm(uuid, uuid[], boolean);
drop function if exists public.stmt_rematch(uuid);
drop function if exists public.stmt_import(uuid, text, uuid, jsonb);
drop function if exists public.stmt_purge(uuid, date);
drop function if exists public.stmt_run_rules(uuid, date, uuid);
drop function if exists public.stmt_apply_match(uuid, uuid, uuid[], text, boolean, boolean, date);
drop function if exists public.stmt_check(uuid, text, jsonb);
drop function if exists public.stmt_fp_rows(uuid, text, jsonb);
drop function if exists public.stmt_save_mapping(uuid, text, jsonb);
drop function if exists public.stmt_gate(uuid);
drop function if exists public.stmt_audit();
drop function if exists public.stmt_subsets(uuid[], bigint[], bigint);
drop function if exists public.stmt_fp(uuid, text, date, bigint, text, text);
drop function if exists public.stmt_number_pattern(text);
drop function if exists public.stmt_norm_ref(text);
drop function if exists public.stmt_norm_payer(text);
drop function if exists public.stmt_mask_digits(text);

-- the settings check as it was before this migration (migration_centre_credit_undo.sql)
create or replace function public.org_validate_settings(p_org uuid, s jsonb) returns void language plpgsql stable security definer set search_path = public as $$
declare st jsonb;
begin
  perform public.org_validate_settings(s);
  if s #>> '{billing,deposit,refund_approved_by}' = 'four_eyes' then
    st := case when p_org is null then jsonb_build_object('owner', true, 'deposit', false, 'credit', false) else public.org_four_eyes_status(p_org) end;
    if not (coalesce((st->>'owner')::boolean, false) and coalesce((st->>'deposit')::boolean, false) and coalesce((st->>'credit')::boolean, false)) then
      raise exception 'FOUR_EYES_UNAVAILABLE: "someone other than the person who asked" needs a second approver: the owner, a staff member who issues invoices (for deposit refunds) and a staff member who records payments (for credit refunds), all active. Add them first, or pick another approver.' using errcode = '42501';
    end if;
  end if;
end $$;
