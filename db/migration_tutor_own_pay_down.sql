-- Undo of migration_tutor_own_pay.sql (T4 S7b): removes the four tutor-facing pay functions and the internal helper, and puts back the settings check
-- from migration_centre_credit_undo.sql (a saved tutor_pay.tutors_see_own_pay stays in org_settings, which is append-only, and is simply no longer
-- checked or read). Changes no data. Safe to run twice.
drop function if exists public.tutor_my_pay_adjustments(date);
drop function if exists public.tutor_my_pay_month(date);
drop function if exists public.tutor_my_pay(date, date);
drop function if exists public.tutor_my_pay_modes();
drop function if exists public.tutor_own_pay_orgs();
create or replace function public.org_validate_settings(p_org uuid, s jsonb) returns void language plpgsql stable security definer set search_path = public as $$
declare st jsonb; v jsonb;
begin
  perform public.org_validate_settings(s);
  if s #>> '{billing,deposit,refund_approved_by}' = 'four_eyes' then
    st := case when p_org is null then jsonb_build_object('owner', true, 'deposit', false, 'credit', false) else public.org_four_eyes_status(p_org) end;
    if not (coalesce((st->>'owner')::boolean, false) and coalesce((st->>'deposit')::boolean, false) and coalesce((st->>'credit')::boolean, false)) then
      raise exception 'FOUR_EYES_UNAVAILABLE: "someone other than the person who asked" needs a second approver: the owner, a staff member who issues invoices (for deposit refunds) and a staff member who records payments (for credit refunds), all active. Add them first, or pick another approver.' using errcode = '42501';
    end if;
  end if;
  -- T34: bank statement matching. Every key is optional (settings saved before this stay valid); a key that is present must be right.
  if s#>>'{payments,statement,auto_confirm}' is not null and s#>>'{payments,statement,auto_confirm}' not in ('exact_only','never') then raise exception 'Unknown statement auto-confirm setting'; end if;
  if s#>>'{payments,statement_bank}' is not null and s#>>'{payments,statement_bank}' not in ('DBS','OCBC','UOB','custom') then raise exception 'Unknown bank for statement matching'; end if;
  v := s #> '{payments,statement,window_before_days}';
  if v is not null and jsonb_typeof(v) <> 'null' and not (case when jsonb_typeof(v) = 'number' and v::text ~ '^[0-9]{1,3}$' then (v#>>'{}')::int between 0 and 30 else false end) then
    raise exception 'Statement matching window before the invoice date must be 0-30 days'; end if;
  v := s #> '{payments,statement,window_after_days}';
  if v is not null and jsonb_typeof(v) <> 'null' and not (case when jsonb_typeof(v) = 'number' and v::text ~ '^[0-9]{1,3}$' then (v#>>'{}')::int between 0 and 365 else false end) then
    raise exception 'Statement matching window after the due date must be 0-365 days'; end if;
end $$;
revoke all on function public.org_validate_settings(uuid, jsonb) from public, anon, authenticated;
