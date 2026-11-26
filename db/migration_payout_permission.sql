-- =====================================================================================================
-- T24c step 4 — the CENTRE side of tutor payout details: permission view_payout_details, the list, and an audited Reveal     undo: migration_payout_permission_down.sql
-- =====================================================================================================
-- Needs migration_tutor_payout.sql (the table and td_payout_audit / td_payout_mask). Run it after that one (last in the chain). EXPAND step: three new functions and two
-- redefined ones; no table changes.
--
-- DECISIONS (owner, 2026-11-25): payout details are a staff-opt-in permission, never given by default; the owner always has it. Full numbers only through an explicit,
-- audited Reveal. A change by the tutor is flagged amber for 7 days. Tutors never see other tutors' details (they have no access at all, see migration_tutor_payout.sql).
--
--   * Permission catalogue (keep in sync with OrgSettings.STAFF_PERMISSIONS in assets/js/org-settings.js; tests/org-settings.test.js reads THIS file):
--       manage_timetable manage_students manage_tutors issue_invoices record_payments view_revenue run_tutor_pay view_audit_log view_payout_details
--     org_invite() already checked the list; org_update_member() did not, so it checks it now (a typo or an invented name is refused).
--   * org_tutor_payouts(org)         owner, or staff WITH view_payout_details: one row per tutor, MASKED value (•••••1234), method, who changed it last and when,
--                                    changed_recently (true for 7 days after a CHANGE or a re-add; the first time a tutor saves is not a change).
--   * org_tutor_payout_status(org)   owner or ANY active staff: one row per tutor with a yes/no only (has_payout). Never a number, method or name on the account.
--   * org_reveal_payout(membership)  owner, or staff WITH view_payout_details: the full value, and its own audit row (action payout_revealed_by_centre: who revealed whose
--                                    and when; the method and the masked value, never the number).
--   Every function checks the caller itself; centres only (a solo organisation, another centre, a tutor, a parent or an anonymous caller get NOT_FOUND).
-- Run on the DEV project first. Safe to run twice.
-- =====================================================================================================

create or replace function public.org_invite(p_org uuid, p_email text, p_name text, p_role text, p_perms text[], p_employment text)
returns uuid language plpgsql security definer set search_path = public as $$
declare m uuid; bad text;
begin
  if not org_can(p_org, 'owner') then raise exception 'Only the owner can add people' using errcode = '42501'; end if;
  if p_role not in ('staff','tutor') then raise exception 'Invite staff or tutors (parents come later)'; end if;
  select x into bad from unnest(coalesce(p_perms, '{}')) x
   where x not in ('manage_timetable','manage_students','manage_tutors','issue_invoices','record_payments','view_revenue','run_tutor_pay','view_audit_log','view_payout_details') limit 1;
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
declare mm memberships; owners int; bad text;
begin
  select * into mm from memberships where id = p_member;
  if not org_can(mm.org_id, 'owner') then raise exception 'Only the owner can change people' using errcode = '42501'; end if;
  select x into bad from unnest(coalesce(p_perms, '{}')) x
   where x not in ('manage_timetable','manage_students','manage_tutors','issue_invoices','record_payments','view_revenue','run_tutor_pay','view_audit_log','view_payout_details') limit 1;
  if bad is not null then raise exception 'Unknown permission %', bad; end if;
  update memberships set role = coalesce(p_role, role), permissions = case when coalesce(p_role, role) = 'staff' then coalesce(p_perms, permissions) else '{}' end,
         status = coalesce(p_status, status) where id = p_member;
  select count(*) into owners from memberships where org_id = mm.org_id and role = 'owner' and status = 'active';
  if owners = 0 then raise exception 'An organisation needs at least one owner'; end if;
end $$;

-- ---------------------------------------------------------------- who is asking? (internal: no browser role may call these)
-- Is the caller an active owner, or an active staff member WITH the permission, of this CENTRE?  p_need_perm false = any active owner/staff.
create or replace function public.td_payout_viewer(p_org uuid, p_need_perm boolean) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if not exists (select 1 from organisations g where g.id = p_org and g.kind = 'centre')
     or not exists (select 1 from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active'
                      and (m.role = 'owner' or (m.role = 'staff' and (not p_need_perm or 'view_payout_details' = any(m.permissions))))) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
end $$;

-- ---------------------------------------------------------------- the list (masked)
create or replace function public.org_tutor_payouts(p_org uuid)
returns table(membership_id uuid, display_name text, member_status text, has_payout boolean, method text, masked text, bank_name text, holder_hint text,
              changed_by_name text, changed_at timestamptz, changed_recently boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform td_payout_viewer(p_org, true);
  return query
    select m.id, m.display_name, m.status, p.id is not null, p.method,
           td_payout_mask(case when p.method = 'bank' then p.account_no else p.paynow_id end),
           p.bank_name, case when p.account_holder is null then null else left(p.account_holder, 1) || '•••' end,
           (select x.display_name from memberships x where x.org_id = p_org and x.user_id = p.created_by limit 1), p.created_at,
           p.id is not null and p.created_at > now() - interval '7 days'
             and exists (select 1 from tutor_payout_details o where o.membership_id = m.id and o.id <> p.id)
    from memberships m
    left join tutor_payout_details p on p.membership_id = m.id and p.superseded_at is null
    where m.org_id = p_org and m.role = 'tutor'
    order by m.display_name, m.created_at;
end $$;

-- ---------------------------------------------------------------- provided / not provided (no value, no method)
create or replace function public.org_tutor_payout_status(p_org uuid)
returns table(membership_id uuid, has_payout boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform td_payout_viewer(p_org, false);
  return query
    select m.id, exists (select 1 from tutor_payout_details p where p.membership_id = m.id and p.superseded_at is null)
    from memberships m where m.org_id = p_org and m.role = 'tutor' order by m.display_name, m.created_at;
end $$;

-- ---------------------------------------------------------------- reveal (explicit, audited)
create or replace function public.org_reveal_payout(p_membership uuid)
returns table(method text, paynow_id text, bank_name text, account_no text, account_holder text)
language plpgsql security definer set search_path = public as $$
declare o uuid; r tutor_payout_details;
begin
  select m.org_id into o from memberships m where m.id = p_membership and m.role = 'tutor';
  if o is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  perform td_payout_viewer(o, true);
  select * into r from tutor_payout_details p where p.membership_id = p_membership and p.superseded_at is null;
  if not found then raise exception 'NO_PAYOUT: this tutor has not added payout details' using errcode = 'P0001'; end if;
  perform td_payout_audit(o, p_membership, r.id, 'payout_revealed_by_centre', r.method, td_payout_mask(case when r.method = 'bank' then r.account_no else r.paynow_id end));
  return query select r.method, r.paynow_id, r.bank_name, r.account_no, r.account_holder;
end $$;

-- ---------------------------------------------------------------- who may call what
do $$
declare f text;
begin
  foreach f in array array['org_tutor_payouts(uuid)', 'org_tutor_payout_status(uuid)', 'org_reveal_payout(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  revoke all on function public.td_payout_viewer(uuid, boolean) from public, anon, authenticated;
end $$;
