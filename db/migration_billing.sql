-- =====================================================================================================
-- Phase 2 — TutorDeck's own billing (Stripe)                               undo: migration_billing_down.sql
-- =====================================================================================================
-- EXPAND step; needs migration_org_foundation.sql first. Adds:
--   * org_subscriptions: one row per organisation = what TutorDeck bills them (written only by the server)
--   * stripe_events: webhook event ids, so a repeated delivery is ignored
--   * org_active_students(org) and org_plan_status(org) for the Plan screen
--   * a gate on solo tutors: free up to 5 ACTIVE students; adding a 6th needs Solo Pro (or a trial)
-- Every solo organisation that exists when this runs is GRANDFATHERED (unlimited, owner's decision).
-- "Active" for the gate = on the roster, not discontinued and past their end date (same rule as the Students page).
-- The monthly bill for centres uses a different count (lessons attended last month, see money.js).
-- Run on the DEV project first. Safe to run twice.
-- =====================================================================================================

create table if not exists public.org_subscriptions (
  org_id                 uuid primary key references public.organisations(id) on delete cascade,
  tier                   text not null default 'free' check (tier in ('free','pro','centre')),
  status                 text not null default 'none' check (status in ('none','trialing','active','past_due','canceled','unpaid')),
  grandfathered          boolean not null default false,
  stripe_customer_id     text,
  stripe_subscription_id text,
  trial_end              timestamptz,
  current_period_end     timestamptz,
  cancel_at_period_end   boolean not null default false,
  updated_at             timestamptz not null default now()
);
create unique index if not exists org_subscriptions_customer on public.org_subscriptions(stripe_customer_id) where stripe_customer_id is not null;
create unique index if not exists org_subscriptions_sub on public.org_subscriptions(stripe_subscription_id) where stripe_subscription_id is not null;

create table if not exists public.stripe_events (
  id          text primary key,                 -- Stripe's evt_...
  type        text not null,
  received_at timestamptz not null default now()
);

alter table public.org_subscriptions enable row level security;
alter table public.stripe_events enable row level security;
-- Owners may read their own row. Nobody signed in can write: only the server (service role) does.
drop policy if exists subs_read on public.org_subscriptions;
create policy subs_read on public.org_subscriptions for select using (org_can(org_id, 'owner') or org_is_platform_admin());
-- stripe_events: no policies at all (service role only)
revoke insert, update, delete on public.org_subscriptions from anon, authenticated;
revoke all on public.stripe_events from anon, authenticated;

drop trigger if exists audit_row on public.org_subscriptions;
create trigger audit_row after insert or update or delete on public.org_subscriptions for each row execute function public.audit_row();

-- ---------------------------------------------------------------- existing solo organisations: grandfathered
-- (runs BEFORE the trigger below exists, so only organisations that exist right now get the flag)
insert into public.org_subscriptions(org_id, tier, status, grandfathered)
select o.id, 'free', 'none', true from public.organisations o where o.kind = 'solo'
on conflict (org_id) do nothing;
insert into public.org_subscriptions(org_id, tier, status)
select o.id, 'centre', 'none' from public.organisations o where o.kind = 'centre'
on conflict (org_id) do nothing;

-- every organisation created from now on gets a row (solo: not grandfathered)
create or replace function public.org_subscription_init() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into org_subscriptions(org_id, tier) values (new.id, case when new.kind = 'centre' then 'centre' else 'free' end)
  on conflict (org_id) do nothing;
  return null;
end $$;
drop trigger if exists org_subscription_init on public.organisations;
create trigger org_subscription_init after insert on public.organisations for each row execute function public.org_subscription_init();

-- ---------------------------------------------------------------- counting and the gate
create or replace function public.org_active_students(p_org uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from students s
  where s.org_id = p_org and s.active is not false and (s.end_date is null or s.end_date >= current_date)
$$;

-- Does this organisation currently have Solo Pro? (trial counts; a failed payment keeps access until Stripe cancels)
create or replace function public.org_has_pro(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select s.tier = 'pro' and s.status in ('trialing','active','past_due')
                   from org_subscriptions s where s.org_id = p_org), false)
$$;

create or replace function public.org_free_limit() returns int language sql immutable as $$ select 5 $$;

create or replace function public.students_solo_limit() returns trigger
language plpgsql security definer set search_path = public as $$
declare solo boolean; gf boolean; n int;
begin
  if new.org_id is null then return new; end if;
  -- only matters when the row is (or becomes) an active student
  if new.active is false or (new.end_date is not null and new.end_date < current_date) then return new; end if;
  if tg_op = 'UPDATE' and old.active is not false and (old.end_date is null or old.end_date >= current_date) then return new; end if;
  select (o.kind = 'solo') into solo from organisations o where o.id = new.org_id;
  if not coalesce(solo, false) then return new; end if;
  select coalesce(s.grandfathered, false) into gf from org_subscriptions s where s.org_id = new.org_id;
  if gf or org_has_pro(new.org_id) then return new; end if;
  n := org_active_students(new.org_id);
  if n >= org_free_limit() then
    raise exception 'FREE_LIMIT: the free plan covers % active students. Upgrade to Solo Pro to add more.', org_free_limit()
      using errcode = 'P0001', hint = 'upgrade';
  end if;
  return new;
end $$;
-- named so it fires after org_row_guard (which fills in org_id)
drop trigger if exists students_solo_limit on public.students;
create trigger students_solo_limit before insert or update on public.students for each row execute function public.students_solo_limit();

-- What the Plan screen shows.
create or replace function public.org_plan_status(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s org_subscriptions; k text; n int;
begin
  if org_role(p_org) is null and not org_is_platform_admin() then raise exception 'Not in this organisation' using errcode = '42501'; end if;
  select * into s from org_subscriptions where org_id = p_org;
  select kind into k from organisations where id = p_org;
  n := org_active_students(p_org);
  return jsonb_build_object(
    'kind', k, 'tier', coalesce(s.tier, 'free'), 'status', coalesce(s.status, 'none'),
    'grandfathered', coalesce(s.grandfathered, false), 'has_pro', org_has_pro(p_org),
    'trial_end', s.trial_end, 'current_period_end', s.current_period_end, 'cancel_at_period_end', coalesce(s.cancel_at_period_end, false),
    'active_students', n, 'free_limit', org_free_limit(),
    'can_add_student', (k <> 'solo' or coalesce(s.grandfathered, false) or org_has_pro(p_org) or n < org_free_limit()));
end $$;

do $$
declare f text;
begin
  foreach f in array array['org_plan_status(uuid)','org_active_students(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['org_has_pro(uuid)','org_free_limit()','org_subscription_init()','students_solo_limit()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;
