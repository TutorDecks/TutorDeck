-- Undo db/migration_org_foundation.sql: back to the 2026-11 baseline. The original columns were never
-- changed, so nothing of the tutors' data is lost; only the new organisation tables/columns go.
-- WARNING: deletes every organisation, setting, membership, household and audit row created since.

drop trigger if exists students_household_after on public.students;
do $$
declare t text;
begin
  foreach t in array array['students','recurring_slots','lessons','exams','invoices','materials'] loop
    execute format('drop trigger if exists org_row_guard on public.%I', t);
    execute format('drop policy if exists org_read on public.%I', t);
    execute format('drop policy if exists org_write on public.%I', t);
  end loop;
  foreach t in array array['students','recurring_slots','lessons','invoices'] loop
    execute format('drop trigger if exists audit_row on public.%I', t);
  end loop;
end $$;

-- original tutor_id policies (before the org_id columns go)
drop policy if exists "tutor rw students" on public.students;
create policy "tutor rw students" on public.students for all using (tutor_id = auth.uid()) with check (tutor_id = auth.uid());
drop policy if exists "tutor rw slots" on public.recurring_slots;
create policy "tutor rw slots" on public.recurring_slots for all using (tutor_id = auth.uid()) with check (tutor_id = auth.uid());
drop policy if exists "tutor rw lessons" on public.lessons;
create policy "tutor rw lessons" on public.lessons for all using (tutor_id = auth.uid()) with check (tutor_id = auth.uid());
drop policy if exists "tutor rw exams" on public.exams;
create policy "tutor rw exams" on public.exams for all using (tutor_id = auth.uid()) with check (tutor_id = auth.uid());
drop policy if exists "own invoices" on public.invoices;
create policy "own invoices" on public.invoices for all using (tutor_id = auth.uid()) with check (tutor_id = auth.uid());
drop policy if exists "materials owner all" on public.materials;
create policy "materials owner all" on public.materials for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop function if exists public.org_is_solo(uuid);

alter table public.lessons drop constraint if exists lessons_student_same_org;
alter table public.lessons drop constraint if exists lessons_slot_same_org;
alter table public.recurring_slots drop constraint if exists slots_student_same_org;
alter table public.exams drop constraint if exists exams_student_same_org;
alter table public.invoices drop constraint if exists invoices_student_same_org;
alter table public.students drop constraint if exists students_household_same_org;
drop index if exists public.students_id_org;
drop index if exists public.slots_id_org;

alter table public.lessons drop column if exists rate_cents, drop column if exists amount_cents, drop column if exists compensation_cents, drop column if exists org_id;
alter table public.recurring_slots drop column if exists rate_cents, drop column if exists org_id;
alter table public.invoices drop column if exists total_cents, drop column if exists org_id;
alter table public.students drop column if exists household_id, drop column if exists org_id;
alter table public.exams drop column if exists org_id;
alter table public.materials drop column if exists org_id;

-- original sign-up function
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name) values (new.id, new.raw_user_meta_data->>'full_name');
  return new;
end; $$;

drop function if exists public.platform_orgs();
drop function if exists public.org_update_member(uuid, text, text[], text);
drop function if exists public.org_invite(uuid, text, text, text, text[], text);
drop function if exists public.org_claim_invites();
drop function if exists public.students_household_after();
drop function if exists public.org_make_households(uuid);
drop function if exists public.org_phone_key(text);
drop function if exists public.org_make_solo(uuid);
drop function if exists public.org_solo_settings(public.profiles);
drop function if exists public.org_create_centre(text, jsonb);
drop function if exists public.org_save_settings(uuid, jsonb, date);
drop function if exists public.org_settings_on(uuid, date);
drop function if exists public.org_validate_settings(jsonb);
drop function if exists public.org_row_guard() cascade;

-- tables (audit log & settings are append-only by trigger: drop the table, not the rows)
drop table if exists public.guardians, public.households, public.holidays, public.rooms, public.terms, public.branches,
  public.platform_fee_snapshots, public.org_plans, public.org_settings, public.support_access_grants, public.platform_admins,
  public.memberships, public.audit_log, public.organisations cascade;

drop function if exists public.audit_row() cascade;
drop function if exists public.audit_immutable() cascade;
drop function if exists public.org_personal(uuid);
drop function if exists public.org_is_member(uuid, uuid);
drop function if exists public.org_can_read(uuid);
drop function if exists public.org_can(uuid, text);
drop function if exists public.org_is_platform_admin();
drop function if exists public.org_role(uuid);
