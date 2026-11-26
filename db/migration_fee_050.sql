-- =====================================================================================================
-- T30 — TutorDeck's centre fee per billable student: S$0.40 → S$0.50          undo: migration_fee_050_down.sql
-- =====================================================================================================
-- Fee = S$100 + S$0.50 × BILLABLE students (owner's decision, 2026-11-26; supersedes S$100 + S$0.40).
-- Needs migration_org_foundation.sql first (any later position in the order is fine; run it last after org_separation).
-- Safe to run twice. DEV first. On LIVE run it at the moment of shipping, after the other migrations.
--
-- What it does (and what it never touches):
--   1. ONE place for the default: org_default_centre_plan() returns the base and per-student price of a new centre.
--      org_create_centre() reads it, so a future price change is one line here, not a hunt through the code.
--   2. Existing centres whose plan row STILL holds the old default (S$100 + 40c) move to 50c.
--      A centre with any other price (custom deal) is NOT touched, and neither is a non-centre (solo) plan.
--   3. platform_fee_snapshots are NOT touched (they are append-only): every month already billed keeps the amounts
--      it was billed at, and the monthly job never recomputes a closed month.
-- Stripe's own price (lookup key centre_student_monthly) is changed by the owner by hand: docs/orchestrator/T30-stripe-steps.md.
-- The monthly job refuses a centre (price_mismatch) whenever Stripe's price differs from this table, so the two must match.
-- =====================================================================================================

create or replace function public.org_default_centre_plan() returns table(base_cents int, per_student_cents int)
language sql immutable set search_path = public as $$ select 10000, 50 $$;
revoke all on function public.org_default_centre_plan() from public, anon, authenticated;

-- Same body as in migration_org_foundation.sql, except the plan row now comes from org_default_centre_plan().
create or replace function public.org_create_centre(p_name text, p_settings jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare o uuid; nm text;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  perform org_validate_settings(p_settings);
  insert into organisations(kind, preset, status, trading_name, created_by) values ('centre', 'centre', 'setup', trim(p_name), auth.uid()) returning id into o;
  select coalesce(nullif(p.full_name, ''), split_part(u.email, '@', 1)) into nm from auth.users u left join profiles p on p.id = u.id where u.id = auth.uid();
  insert into memberships(org_id, user_id, display_name, role) values (o, auth.uid(), coalesce(nm, 'Owner'), 'owner');
  insert into org_settings(org_id, version, schema_version, effective_from, settings, created_by) values (o, 1, 1, current_date, p_settings, auth.uid());
  insert into org_plans(org_id, plan_code, base_cents, per_student_cents, effective_from)
    select o, 'centre', d.base_cents, d.per_student_cents, current_date from org_default_centre_plan() d;
  return o;
end $$;

-- Existing centres still on the OLD default (S$100 + 40c) → the new default. Anything else is left alone.
update public.org_plans p
   set per_student_cents = (select per_student_cents from public.org_default_centre_plan())
 where p.plan_code = 'centre' and p.base_cents = 10000 and p.per_student_cents = 40;
