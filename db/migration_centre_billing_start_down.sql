-- Undo of migration_centre_billing_start.sql (run it BEFORE migration_centre_billing_method_down.sql).
-- WARNING: forgets billing start dates / first-month numbers, and the pilot flag on snapshots (pilot months would then look like normal
-- months with fee 0). Only run it if no pilot snapshot exists.
drop function if exists public.org_set_billing_start(uuid, date, int, text);
alter table public.platform_fee_snapshots drop constraint if exists platform_fee_snapshots_override_check;
alter table public.platform_fee_snapshots drop constraint if exists platform_fee_snapshots_waived_check;
alter table public.platform_fee_snapshots drop column if exists override_students;
alter table public.platform_fee_snapshots drop column if exists waived_reason;
alter table public.platform_fee_snapshots drop column if exists billable;
alter table public.org_plans drop constraint if exists org_plans_billing_start_check;
alter table public.org_plans drop column if exists billing_start_reason;
alter table public.org_plans drop column if exists first_month_billable_override;
alter table public.org_plans drop column if exists billing_starts_on;
