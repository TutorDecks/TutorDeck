-- =====================================================================
-- Persist business_name from signup metadata onto the new profile.
-- Run once in the Supabase SQL editor. Safe to re-run (create or replace).
--
-- Why: the sidebar brand reads profiles.business_name, and the signup form
-- now sends it as user metadata. The original trigger only copied full_name,
-- so without this the name is saved client-side only — which works when
-- email confirmation is OFF (a session exists at signup) but is skipped when
-- confirmation is ON (no session yet). This makes the trigger persist it
-- server-side in both cases. full_name is kept for backward compatibility.
-- =====================================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, business_name)
  values (new.id,
          new.raw_user_meta_data->>'full_name',
          new.raw_user_meta_data->>'business_name');
  return new;
end; $$;
