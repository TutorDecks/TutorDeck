-- Undo for migration_payout_permission.sql (run it FIRST, before migration_tutor_payout_down.sql).
-- Puts org_invite / org_update_member back as migration_org_foundation.sql defines them. A staff member who was given view_payout_details keeps that word in
-- their permission list, but nothing reads it any more. Audit rows written by reveals stay (append-only, masked values only).
drop function if exists public.org_tutor_payouts(uuid);
drop function if exists public.org_tutor_payout_status(uuid);
drop function if exists public.org_reveal_payout(uuid);
drop function if exists public.td_payout_viewer(uuid, boolean);

create or replace function public.org_invite(p_org uuid, p_email text, p_name text, p_role text, p_perms text[], p_employment text)
returns uuid language plpgsql security definer set search_path = public as $$
declare m uuid; bad text;
begin
  if not org_can(p_org, 'owner') then raise exception 'Only the owner can add people' using errcode = '42501'; end if;
  if p_role not in ('staff','tutor') then raise exception 'Invite staff or tutors (parents come later)'; end if;
  select x into bad from unnest(coalesce(p_perms, '{}')) x
   where x not in ('manage_timetable','manage_students','manage_tutors','issue_invoices','record_payments','view_revenue','run_tutor_pay','view_audit_log') limit 1;
  if bad is not null then raise exception 'Unknown permission %', bad; end if;
  if exists (select 1 from memberships where org_id = p_org and lower(invited_email) = lower(trim(p_email))) then
    raise exception 'Already invited'; end if;
  insert into memberships(org_id, invited_email, display_name, role, permissions, employment_type, status)
  values (p_org, lower(trim(p_email)), trim(p_name), p_role, case when p_role = 'staff' then coalesce(p_perms, '{}') else '{}' end,
          case when p_role = 'tutor' then p_employment end, 'invited') returning id into m;
  return m;
end $$;

create or replace function public.org_update_member(p_member uuid, p_role text, p_perms text[], p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare mm memberships; owners int;
begin
  select * into mm from memberships where id = p_member;
  if not org_can(mm.org_id, 'owner') then raise exception 'Only the owner can change people' using errcode = '42501'; end if;
  update memberships set role = coalesce(p_role, role), permissions = case when coalesce(p_role, role) = 'staff' then coalesce(p_perms, permissions) else '{}' end,
         status = coalesce(p_status, status) where id = p_member;
  select count(*) into owners from memberships where org_id = mm.org_id and role = 'owner' and status = 'active';
  if owners = 0 then raise exception 'An organisation needs at least one owner'; end if;
end $$;
