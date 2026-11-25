-- =====================================================================================================
-- TutorDeck — DEV APPLY PACK (task T26).   PASTE INTO THE SUPABASE SQL EDITOR OF THE **DEV** PROJECT ONLY (tuzxsqkfzrjssnpcoale).
-- NEVER run on LIVE (rnjvswkejbrhbaytutai): part 4 creates demo logins with a known password.
-- =====================================================================================================
-- Contains, in dependency order (every part is idempotent: run it twice, the second run changes nothing):
--   PART 1  staff_home(org)               claude/t3-1-staff-home    db/migration_staff_home.sql
--   PART 2  invite emails                 claude/t7-2-invites       db/migration_invites.sql
--   PART 3  centre tutor's own profile    claude/t24c-1-profile     db/migration_tutor_profile.sql
--   PART 4  two demo staff logins         claude/t3-1-staff-home    db/seed_dev_demo.sql (staff block only)
-- NOT included (branches did not exist when this pack was built): t3-2-students (migration_staff_students.sql),
--   t24c-2-payout (migration_tutor_payout.sql). Rebuild the pack when they land.
-- Needs the six standard migrations already on DEV: org_foundation, billing, attendance, tutor_access, org_delete, function_lockdown
--   (org_separation is recommended: PART 3 says it should come after it). The pre-check below lists which are present.
--
-- TRANSACTIONS: the Supabase SQL editor runs everything you paste as ONE batch, so the pack is all-or-nothing in practice: if any
-- statement fails, nothing from this paste is kept and the error shows the failing line. No part needs to run outside a transaction.
-- The pack deliberately has no BEGIN/COMMIT of its own (the editor manages that); it does not change any existing table's data.
-- The result you see is the LAST query (the post-check). Re-run the pre-check on its own (first block) any time.
-- =====================================================================================================

-- ####################################### PRE-CHECK (read-only) #######################################
-- Shown only if you run just this block. 'ready' = every required earlier migration is present.
select 'PRE-CHECK' as step, m.migration, case when m.ok then 'present' else 'MISSING' end as state
from (values
  ('org_foundation (memberships, org_can)',  to_regclass('public.memberships') is not null and to_regprocedure('public.org_can(uuid,text)') is not null),
  ('billing (org_subscriptions)',            to_regclass('public.org_subscriptions') is not null),
  ('attendance (lessons.attendance)',        exists (select 1 from information_schema.columns where table_schema='public' and table_name='lessons' and column_name='attendance')),
  ('tutor_access (tutor_my_lessons)',        exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname='tutor_my_lessons')),
  ('org_delete (org_delete_solo)',           exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname='org_delete_solo')),
  ('function_lockdown (pinned search_path)', exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname='audit_immutable' and proconfig is not null)),
  ('org_separation (org_same_org_guard) - recommended', exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname='org_same_org_guard')),
  ('demo seed present (Demo Learning Centre) - needed by PART 4', exists (select 1 from public.organisations where trading_name='Demo Learning Centre' and kind='centre'))
) as m(migration, ok)
union all
select 'PRE-CHECK', 'OVERALL', case when
    to_regclass('public.memberships') is not null and to_regprocedure('public.org_can(uuid,text)') is not null
    and to_regclass('public.org_subscriptions') is not null
    and exists (select 1 from information_schema.columns where table_schema='public' and table_name='lessons' and column_name='attendance')
    and exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname='tutor_my_lessons')
    and exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname='org_delete_solo')
    and exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname='audit_immutable' and proconfig is not null)
  then 'ready' else 'NOT READY - apply the MISSING migrations first (order: foundation, billing, attendance, tutor_access, org_delete, function_lockdown, org_separation)' end;

-- #####################################################################################################
-- ### PART 1 of 4 — staff_home(org): the centre Home numbers
-- ### source branch: claude/t3-1-staff-home   file: db/migration_staff_home.sql
-- ### undo: db/migration_staff_home_down.sql (drops the function)
-- ### (if an error appears, search this file for the nearest "### PART" line above the error line: that is the part that failed)
-- #####################################################################################################
-- =====================================================================================================
-- T3 step 1 — the centre Home for owners and staff: staff_home(org)                undo: migration_staff_home_down.sql
-- =====================================================================================================
-- Needs migration_org_foundation.sql, migration_attendance.sql and migration_tutor_access.sql (lessons.taught_by, attendance, trial).
-- ADD-ONLY: one new function, no table or column is touched.
--
-- WHAT IT IS: ONE call returns the numbers the centre Home shows, as COUNTS ONLY. No money (no rate, amount, paid, compensation,
-- *_cents), no names, no phone numbers: the page links through to the real screens (built in later steps), which have their own checks.
--
-- WHO MAY SEE WHAT (the menu hides what a person can't use; this function refuses it anyway; a section the caller isn't allowed to see comes
-- back as null, never as 0, so "no permission" can't be mistaken for "nothing to do"):
--   the caller must be an active OWNER or STAFF member of this centre (anything else, a tutor, a parent, a stranger, a solo organisation,
--   an unknown id: the same NOT_FOUND, so ids can't be probed)
--   students section               manage_students   (owner always)
--   today / not marked / no tutor / trials   manage_timetable
--   pending charges                issue_invoices    (a count only; the amounts are step 4)
--   `can` tells the page which sections the caller has, so it doesn't have to guess
--
-- DAYS are the centre's own calendar days (organisations.timezone), not the server's.
-- Run on the DEV project first. Safe to run twice.
-- =====================================================================================================
create or replace function public.staff_home(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  o organisations; today date; can_st boolean; can_tt boolean; can_ch boolean; res jsonb;
  c_students int; c_today int; c_today_marked int; c_today_open int; c_unmarked int; c_notutor int; c_trials int; c_pending int;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into o from organisations where id = p_org and kind = 'centre';
  if not found or not exists (select 1 from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active'
                              and m.role in ('owner', 'staff')) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  today := (now() at time zone o.timezone)::date;
  can_st := org_can(p_org, 'manage_students');
  can_tt := org_can(p_org, 'manage_timetable');
  can_ch := org_can(p_org, 'issue_invoices');

  if can_st then      -- students whose "lessons run until" date hasn't passed (the same rule as TL.isEnded)
    select count(*) into c_students from students s where s.org_id = p_org and (s.end_date is null or s.end_date >= today);
  end if;
  if can_tt then
    -- a lesson cancelled by staff with no attendance mark is closed: it is neither "to mark" nor "marked"
    select count(*) filter (where l.status <> 'cancelled' or l.attendance is not null),
           count(*) filter (where l.attendance is not null),
           count(*) filter (where l.attendance is null and l.status <> 'cancelled')
      into c_today, c_today_marked, c_today_open from lessons l where l.org_id = p_org and l.lesson_date = today;
    -- days gone by with no mark: the last 60 days (the longest window a centre can choose), so old history doesn't count forever
    select count(*) into c_unmarked from lessons l
      where l.org_id = p_org and l.lesson_date < today and l.lesson_date >= today - 60 and l.attendance is null and l.status <> 'cancelled';
    select count(*) into c_notutor from lessons l
      where l.org_id = p_org and l.lesson_date >= today and l.lesson_date < today + 14 and l.taught_by is null and l.status <> 'cancelled';
    select count(*) into c_trials from lessons l
      where l.org_id = p_org and l.trial and date_trunc('month', l.lesson_date) = date_trunc('month', today);
  end if;
  if can_ch then      -- absent / cancelled lessons whose charge hasn't been typed yet (invoicing must wait for these)
    select count(*) into c_pending from lessons l
      where l.org_id = p_org and l.attendance in ('absent', 'cancelled_early', 'late_cancelled') and l.compensation is null;
  end if;

  res := jsonb_build_object(
    'org_id', p_org, 'org_name', o.trading_name, 'status', o.status, 'today', today,
    'can', jsonb_build_object('students', can_st, 'timetable', can_tt, 'charges', can_ch),
    'students_active', c_students,
    'today_lessons', c_today, 'today_marked', c_today_marked, 'today_to_mark', c_today_open,
    'unmarked_past', c_unmarked, 'no_tutor_14d', c_notutor, 'trials_this_month', c_trials,
    'pending_charges', c_pending);
  return res;
end $$;

revoke all on function public.staff_home(uuid) from public, anon;
grant execute on function public.staff_home(uuid) to authenticated;

-- #####################################################################################################
-- ### PART 2 of 4 — invite emails: send log + reserve + status
-- ### source branch: claude/t7-2-invites   file: db/migration_invites.sql
-- ### undo: db/migration_invites_down.sql
-- ### (if an error appears, search this file for the nearest "### PART" line above the error line: that is the part that failed)
-- #####################################################################################################
-- T7: invite emails. Needs db/migration_org_foundation.sql (memberships, org_can, audit_row).
-- Adds ONLY: a send log (server-only), a reserve step that enforces the rate limit in SQL, and a status read for the people list.
-- Safe to run twice. Undo: db/migration_invites_down.sql.
--
-- How a send works (api/send-invite.js):
--   1. the browser asks the server to email membership X; the server calls org_invite_mail_reserve(X) AS THE CALLER (their token), so the
--      permission check and the limits below run in SQL, not in JS: the owner or a staff admin with manage_tutors, an invite that is still
--      'invited', at most 1 mail per invite per 10 minutes, at most 5 per invite per 24 hours, at most 30 per organisation per hour.
--   2. a successful reserve writes a 'pending' log row and returns what the email needs (address, name, role, centre, inviter).
--   3. the server (service role) then sends the mail and marks the row 'sent' / 'failed' / 'blocked_preview'.
-- Nobody but the server reads or writes the log table directly (row-level security on, no policies). The log holds NO address and
-- NO link: only ids, times, Brevo's message id and a status. It is audited like every other table.

create table if not exists public.org_invite_mail_log (
  id               uuid primary key default gen_random_uuid(),
  membership_id    uuid not null references public.memberships(id) on delete cascade,
  org_id           uuid not null references public.organisations(id) on delete cascade,
  sent_by          uuid,                                    -- the signed-in person who pressed Send / Resend
  sent_at          timestamptz not null default now(),
  status           text not null default 'pending' check (status in ('pending','sent','failed','blocked_preview')),
  brevo_message_id text
);
create index if not exists org_invite_mail_log_member on public.org_invite_mail_log(membership_id, sent_at desc);
create index if not exists org_invite_mail_log_org on public.org_invite_mail_log(org_id, sent_at desc);
alter table public.org_invite_mail_log enable row level security;       -- no policies on purpose: only the service role (server) can touch it
revoke all on public.org_invite_mail_log from anon, authenticated;

drop trigger if exists audit_row on public.org_invite_mail_log;
create trigger audit_row after insert or update or delete on public.org_invite_mail_log for each row execute function public.audit_row();

-- Reserve one send. Returns { ok: true, log_id, email, name, role, centre, inviter } or { ok: false, reason, retry_minutes? }.
-- Refusals about WHO you are raise 42501 (the server answers 403); refusals about the invite's state come back as data.
create or replace function public.org_invite_mail_reserve(p_member uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare mm memberships; last_at timestamptz; n_day int; n_org int; lid uuid; who text; centre text;
begin
  select * into mm from memberships where id = p_member for update;           -- the lock makes two quick presses count one after the other
  if not found or not org_can(mm.org_id, 'manage_tutors') then raise exception 'Not allowed' using errcode = '42501'; end if;
  if mm.status <> 'invited' or mm.user_id is not null or mm.invited_email is null then return jsonb_build_object('ok', false, 'reason', 'not_invited'); end if;
  select max(sent_at), count(*) filter (where sent_at > now() - interval '24 hours') into last_at, n_day
    from org_invite_mail_log where membership_id = p_member and status in ('pending','sent');
  if last_at is not null and last_at > now() - interval '10 minutes' then
    return jsonb_build_object('ok', false, 'reason', 'too_soon', 'retry_minutes', greatest(1, ceil(extract(epoch from (last_at + interval '10 minutes' - now())) / 60)::int));
  end if;
  if n_day >= 5 then return jsonb_build_object('ok', false, 'reason', 'daily_limit'); end if;
  select count(*) into n_org from org_invite_mail_log where org_id = mm.org_id and sent_at > now() - interval '1 hour' and status in ('pending','sent');
  if n_org >= 30 then return jsonb_build_object('ok', false, 'reason', 'org_limit'); end if;
  insert into org_invite_mail_log(membership_id, org_id, sent_by) values (p_member, mm.org_id, auth.uid()) returning id into lid;
  select display_name into who from memberships where org_id = mm.org_id and user_id = auth.uid() and status = 'active' limit 1;
  select trading_name into centre from organisations where id = mm.org_id;
  return jsonb_build_object('ok', true, 'log_id', lid, 'email', mm.invited_email, 'name', mm.display_name, 'role', mm.role,
                            'centre', centre, 'inviter', coalesce(who, centre));
end $$;

-- For the people list: when each pending invite was created / last emailed and how many mails went out in the last 24 hours
-- (never the address or the link).
create or replace function public.org_invite_mail_status(p_org uuid)
returns table(member_id uuid, invited_at timestamptz, last_sent_at timestamptz, sent_24h int, can_resend_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not org_can(p_org, 'manage_tutors') then raise exception 'Not allowed' using errcode = '42501'; end if;
  return query
    select m.id, m.created_at, l.last_at, coalesce(l.n_day, 0)::int, case when l.last_any is null then null else l.last_any + interval '10 minutes' end
    from memberships m
    left join lateral (select max(sent_at) filter (where status = 'sent') last_at,
                              max(sent_at) filter (where status in ('pending','sent')) last_any,
                              count(*) filter (where sent_at > now() - interval '24 hours' and status in ('pending','sent')) n_day
                         from org_invite_mail_log x where x.membership_id = m.id) l on true
    where m.org_id = p_org and m.status = 'invited' and m.user_id is null;
end $$;

-- who may call what
do $$
declare f text;
begin
  foreach f in array array['org_invite_mail_reserve(uuid)','org_invite_mail_status(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- #####################################################################################################
-- ### PART 3 of 4 — centre tutor's own profile (memberships.phone, tutor_my_profile, tutor_save_profile)
-- ### source branch: claude/t24c-1-profile   file: db/migration_tutor_profile.sql
-- ### undo: db/migration_tutor_profile_down.sql
-- ### (if an error appears, search this file for the nearest "### PART" line above the error line: that is the part that failed)
-- #####################################################################################################
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

-- #####################################################################################################
-- ### PART 4 of 4 — demo staff logins: centre.staff@ and centre.frontdesk@example.test (DEV dummy data, password in the seed: Demo-Pass-2026)
-- ### source branch: claude/t3-1-staff-home   file: db/seed_dev_demo.sql (only the 'T3 step 1' block)
-- ### undo: delete the two rows from auth.users (email in the two addresses) on DEV; their memberships go with them. Needs the Demo Learning Centre from the original seed.
-- ### ADDS ONLY the two logins + their memberships; skips anything already there. Fails with a clear message if the demo centre is missing.
-- ### (if an error appears, search this file for the nearest "### PART" line above the error line: that is the part that failed)
-- #####################################################################################################
-- =====================================================================================================
-- T3 step 1: two staff logins for the demo centre. Runs on its own and only adds what is missing, so it is safe to run again.
--   centre.staff     every permission in the catalogue (assets/js/org-settings.js)
--   centre.frontdesk manage_students only: the person who answers the phone and adds students, nothing about the timetable or money
-- =====================================================================================================
do $$
declare
  staff_id uuid := '00000000-0000-0000-0000-00000000d106';
  front_id uuid := '00000000-0000-0000-0000-00000000d107';
  c uuid;
  r record;
begin
  select o.id into c from organisations o join memberships m on m.org_id = o.id and m.role = 'owner'
    where o.kind = 'centre' and o.trading_name = 'Demo Learning Centre' order by o.created_at limit 1;
  if c is null then raise exception 'Run the demo seed above first: the Demo Learning Centre does not exist yet.'; end if;
  for r in select * from (values (staff_id, 'centre.staff@example.test', 'Demo Centre Staff'), (front_id, 'centre.frontdesk@example.test', 'Demo Front Desk')) v(id, email, name) loop
    if not exists (select 1 from auth.users where email = r.email) then
      insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, confirmation_token, recovery_token, email_change_token_new,
          email_change, email_change_token_current, reauthentication_token, phone_change, phone_change_token, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
      values ('00000000-0000-0000-0000-000000000000', r.id, 'authenticated', 'authenticated', r.email, extensions.crypt('Demo-Pass-2026', extensions.gen_salt('bf')), now(),
          '', '', '', '', '', '', '', '', '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name', r.name, 'email_verified', true), now(), now());
      insert into auth.identities(id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
      values (gen_random_uuid(), r.id, jsonb_build_object('sub', r.id::text, 'email', r.email, 'email_verified', true, 'phone_verified', false), 'email', r.id::text, now(), now(), now());
    end if;
  end loop;
  insert into memberships(org_id, user_id, display_name, role, permissions, status)
    select c, u.id, v.name, 'staff', v.perms, 'active'
    from (values ('centre.staff@example.test', 'Demo Centre Staff',
                  array['manage_timetable','manage_students','manage_tutors','issue_invoices','record_payments','view_revenue','run_tutor_pay','view_audit_log']),
                 ('centre.frontdesk@example.test', 'Demo Front Desk', array['manage_students'])) v(email, name, perms)
    join auth.users u on u.email = v.email
    where not exists (select 1 from memberships m where m.org_id = c and m.user_id = u.id);
end $$;

-- ####################################### POST-CHECK (read-only) #######################################
select 'POST-CHECK' as step, x.item, case when x.ok then 'present' else 'MISSING' end as state from (values
  ('PART 1 function staff_home(uuid)',               to_regprocedure('public.staff_home(uuid)') is not null),
  ('PART 2 table org_invite_mail_log',               to_regclass('public.org_invite_mail_log') is not null),
  ('PART 2 function org_invite_mail_reserve(uuid)',  to_regprocedure('public.org_invite_mail_reserve(uuid)') is not null),
  ('PART 2 function org_invite_mail_status(uuid)',   to_regprocedure('public.org_invite_mail_status(uuid)') is not null),
  ('PART 3 column memberships.phone',                exists (select 1 from information_schema.columns where table_schema='public' and table_name='memberships' and column_name='phone')),
  ('PART 3 function tutor_my_profile()',             to_regprocedure('public.tutor_my_profile()') is not null),
  ('PART 3 function tutor_save_profile(uuid,text,text,boolean)', to_regprocedure('public.tutor_save_profile(uuid,text,text,boolean)') is not null),
  ('PART 4 login centre.staff@example.test + membership',     exists (select 1 from auth.users u join public.memberships m on m.user_id=u.id and m.role='staff' where u.email='centre.staff@example.test')),
  ('PART 4 login centre.frontdesk@example.test + membership', exists (select 1 from auth.users u join public.memberships m on m.user_id=u.id and m.role='staff' where u.email='centre.frontdesk@example.test'))
) as x(item, ok)
union all select 'POST-CHECK', 'OVERALL', 'every line above should say present';
