-- Undo for migration_billing.sql (run it BEFORE migration_org_foundation_down.sql). Drops the billing tables and the gate.
drop trigger if exists students_solo_limit on public.students;
drop trigger if exists org_subscription_init on public.organisations;
drop function if exists public.students_solo_limit();
drop function if exists public.org_subscription_init();
drop function if exists public.org_plan_status(uuid);
drop function if exists public.org_has_pro(uuid);
drop function if exists public.org_free_limit();
drop function if exists public.org_active_students(uuid);
drop table if exists public.stripe_events, public.org_subscriptions cascade;
