-- Undo of migration_centre_billing_method.sql (run it BEFORE migration_fee_050_down.sql / the foundation undo).
-- WARNING: forgets which centres were switched to 'invoice' (they go back to Stripe billing).
drop function if exists public.org_set_billing_method(uuid, text);
alter table public.org_plans drop constraint if exists org_plans_billing_method_check;
alter table public.org_plans drop column if exists billing_method;
