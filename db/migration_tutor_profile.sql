-- =====================================================================================================
-- T24c step 1 — a centre tutor's own profile (name, phone)                 undo: migration_tutor_profile_down.sql
-- =====================================================================================================
-- Needs migration_org_foundation.sql. Run it after migration_org_separation.sql (it is the last one in the chain). EXPAND step: one new
-- optional column; nothing existing changes.
--
-- DESIGN (same rule as migration_tutor_access.sql): a centre tutor has NO table access. Two narrow functions are the only way a tutor
-- reads or edits their own profile:
--   tutor_my_profile()          → one row per centre the caller is an ACTIVE tutor in: membership id, centre name, display name, phone, email
--   tutor_save_profile(...)     → change the display name and phone on MY OWN tutor membership(s) — nothing else
-- They read and write only memberships.display_name and memberships.phone of the caller's own tutor memberships. They never return or touch
-- role, permissions, status, employment type, another person's row, lessons or money. Phone is a Singapore mobile, kept as +65 and 8 digits.
-- Run on the DEV project first. Safe to run twice.
-- =====================================================================================================

alter table public.memberships add column if not exists phone text;                      -- +65 + 8 digits, optional
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'memberships_phone_sg') then
    alter table public.memberships add constraint memberships_phone_sg check (phone is null or phone ~ '^\+65[689][0-9]{7}$');
  end if;
end $$;

-- ---------------------------------------------------------------- read my profile
create or replace function public.tutor_my_profile()
returns table(membership_id uuid, org_id uuid, org_name text, display_name text, phone text, email text)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  return query
    select m.id, m.org_id, o.trading_name, m.display_name, m.phone, (select u.email::text from auth.users u where u.id = auth.uid())
    from memberships m join organisations o on o.id = m.org_id
    where m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active'
    order by o.trading_name, m.created_at;
end $$;

-- ---------------------------------------------------------------- save my profile
-- p_membership = which centre's name to change; with p_all_centres the same name goes on every centre where I am an active tutor.
-- The phone is one number for the person, so it is saved on all of my tutor memberships. A null phone or '' clears it.
create or replace function public.tutor_save_profile(p_membership uuid, p_name text, p_phone text, p_all_centres boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare nm text := trim(coalesce(p_name, '')); ph text := regexp_replace(coalesce(p_phone, ''), '[\s\-]', '', 'g');
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if not exists (select 1 from memberships m where m.id = p_membership and m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active') then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if char_length(nm) < 1 or char_length(nm) > 80 then raise exception 'BAD_NAME: use 1 to 80 characters' using errcode = 'P0001'; end if;
  if ph = '' then ph := null;
  else
    if ph ~ '^[689][0-9]{7}$' then ph := '+65' || ph;
    elsif ph ~ '^65[689][0-9]{7}$' then ph := '+' || ph; end if;
    if ph !~ '^\+65[689][0-9]{7}$' then raise exception 'BAD_PHONE: use a Singapore mobile number, like 9123 4567' using errcode = 'P0001'; end if;
  end if;
  update memberships m set phone = ph where m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active' and m.phone is distinct from ph;
  update memberships m set display_name = nm
    where m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active' and (p_all_centres or m.id = p_membership) and m.display_name is distinct from nm;
end $$;

-- ---------------------------------------------------------------- who may call what (each function checks the caller itself)
do $$
declare f text;
begin
  foreach f in array array['tutor_my_profile()', 'tutor_save_profile(uuid,text,text,boolean)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
