-- =====================================================================================================
-- T31a — two billing methods per centre                          undo: migration_centre_billing_method_down.sql
-- =====================================================================================================
-- org_plans.billing_method: 'stripe' (DEFAULT: the centre pays through Stripe, self-serve, as before) or
--                           'invoice' (managed: TutorDeck invoices the centre, the centre pays by PayNow).
-- Only a PLATFORM ADMIN can switch it (org_set_billing_method), normally after a centre contacts us. Nobody else can: the browser
-- has no write access to org_plans. Every change is audited by the existing audit_row trigger on org_plans.
-- Solo plans keep the default and the setter refuses them. Needs migration_org_foundation.sql. Safe to run twice. DEV first.
-- =====================================================================================================
alter table public.org_plans add column if not exists billing_method text not null default 'stripe';
alter table public.org_plans drop constraint if exists org_plans_billing_method_check;
alter table public.org_plans add constraint org_plans_billing_method_check check (billing_method in ('stripe','invoice'));

-- The method belongs to the centre, so it is set on every plan row of that centre (past and future price changes keep it).
create or replace function public.org_set_billing_method(p_org uuid, p_method text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not org_is_platform_admin() then raise exception 'Only a TutorDeck administrator can change the billing method'; end if;
  if p_method is null or p_method not in ('stripe','invoice') then raise exception 'Billing method must be stripe or invoice'; end if;
  if not exists (select 1 from organisations where id = p_org and kind = 'centre') then raise exception 'Only a centre has a billing method'; end if;
  update org_plans set billing_method = p_method where org_id = p_org and plan_code = 'centre' and billing_method <> p_method;
end $$;
revoke all on function public.org_set_billing_method(uuid, text) from public, anon;
grant execute on function public.org_set_billing_method(uuid, text) to authenticated;
