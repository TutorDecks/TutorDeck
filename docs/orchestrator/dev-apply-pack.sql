-- =====================================================================================================
-- TutorDeck — DEV APPLY PACK (task T26).   PASTE INTO THE SUPABASE SQL EDITOR OF THE **DEV** PROJECT ONLY (tuzxsqkfzrjssnpcoale).
-- NEVER run on LIVE (rnjvswkejbrhbaytutai): PART 9 creates demo logins with a known password.
-- =====================================================================================================
-- Contains, in dependency order (every part is idempotent: run it twice, the second run changes nothing):
--   PART 1  staff_home(org)               claude/t3-1-staff-home    db/migration_staff_home.sql
--   PART 2  invite emails                 claude/t7-2-invites       db/migration_invites.sql
--   PART 3  centre tutor's own profile    claude/t24c-1-profile     db/migration_tutor_profile.sql
--   PART 4  tutor payout details          claude/t24c-2-payout      db/migration_tutor_payout.sql
--   PART 5  payout permission + centre    claude/t24c-3-payout      db/migration_payout_permission.sql
--   PART 6  centre students + households  claude/t3-2-students      db/migration_staff_students.sql
--   PART 7  centre attendance + guard     claude/t3-3-attendance    db/migration_staff_attendance.sql   (before PART 8: charges needs it)
--   PART 8  centre pending charges        claude/t3-4-charges       db/migration_staff_charges.sql
--   PART 9  two demo staff logins         claude/t3-1-staff-home    db/seed_dev_demo.sql (staff block only)
-- NOT included: the tutor-leave migration (db/migration_tutor_leave.sql, task t24c-5): its branch did not exist on origin when this pack was built (T26b).
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
  ('demo seed present (Demo Learning Centre) - needed by PART 9', exists (select 1 from public.organisations where trading_name='Demo Learning Centre' and kind='centre'))
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
-- ### PART 1 of 9 — staff_home(org): the centre Home numbers
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
-- ### PART 2 of 9 — invite emails: send log + reserve + status
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
-- ### PART 3 of 9 — centre tutor's own profile (memberships.phone, tutor_my_profile, tutor_save_profile)
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
-- ### PART 4 of 9 — centre tutor's payout details (PayNow / bank), masked + audited
-- ### source branch: claude/t24c-2-payout   file: db/migration_tutor_payout.sql
-- ### undo: db/migration_tutor_payout_down.sql (drops the 4 functions, helpers and table tutor_payout_details)
-- ### (if an error appears, search this file for the nearest "### PART" line above the error line: that is the part that failed)
-- #####################################################################################################
-- =====================================================================================================
-- T24c step 3 — a centre tutor's payout details (PayNow mobile / PayNow UEN / bank account)     undo: migration_tutor_payout_down.sql
-- =====================================================================================================
-- Needs migration_org_foundation.sql and migration_tutor_access.sql (memberships_id_org). Run it after migration_tutor_profile.sql (the last one in
-- the chain). EXPAND step: one new table and four new functions; nothing existing changes.
--
-- DESIGN (same rule as migration_tutor_access.sql / migration_tutor_profile.sql): a centre tutor has NO table access.
--   * Table tutor_payout_details is append-only (a change adds a row and retires the old one) with row-level security ON and NO policy for anyone, and the
--     browser roles have no table privileges either. Nobody reads or writes it from a browser, whoever they are.
--   * Four SECURITY DEFINER functions are the only way in, each with an explicit column list, each checking that the membership is the caller's own
--     ACTIVE tutor membership in a CENTRE (never a solo organisation, never someone else's, never a disabled one):
--       tutor_my_payout()                 → one row per centre where I am a tutor: whether I have details, the method and a MASKED value (••••• + last 4)
--       tutor_save_payout(...)            → validate in plain words, then store as my current details
--       tutor_clear_payout(membership)    → I no longer have details on file at that centre
--       tutor_reveal_payout(membership)   → the full value, only for me, only on this explicit call, and every call is written to the audit log
--   * The generic audit trigger is NOT attached to this table: it copies whole rows (full numbers, holder names) into the audit log. Instead
--     td_payout_audit() writes its own rows (saved / cleared / revealed) holding only the method and the masked value. A SQL test proves that no full
--     number or name ever appears in audit_log.
--   * Error messages never contain the value that was typed.
-- The centre's own view (permission view_payout_details, list, reveal) is step 4. Nobody but the tutor can read these rows here.
-- Retention (current row erased at removal, old rows 12 months after) is step 5; until then a cleared or replaced row stays, invisible to everyone.
-- Run on the DEV project first. Safe to run twice.
-- =====================================================================================================

create table if not exists public.tutor_payout_details (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.organisations(id) on delete cascade,
  membership_id  uuid not null,
  method         text not null check (method in ('paynow_mobile', 'paynow_uen', 'bank')),
  paynow_id      text,                                  -- paynow_mobile: +65 and 8 digits; paynow_uen: upper-case UEN
  bank_name      text,
  account_no     text,                                  -- digits only
  account_holder text,
  created_at     timestamptz not null default now(),
  created_by     uuid not null,                         -- always the tutor's own login
  superseded_at  timestamptz,                           -- null = the current row
  cleared_at     timestamptz,                           -- set together with superseded_at when the tutor cleared it (nothing replaced it)
  constraint tutor_payout_membership_same_org foreign key (membership_id, org_id) references public.memberships(id, org_id) on delete cascade,
  -- the database has the last word on the shapes (the functions give the friendly messages)
  constraint tutor_payout_mobile_ok check (method <> 'paynow_mobile' or (paynow_id ~ '^\+65[89][0-9]{7}$' and bank_name is null and account_no is null and account_holder is null)),
  constraint tutor_payout_uen_ok    check (method <> 'paynow_uen' or ((paynow_id ~ '^[0-9]{8}[A-Z]$' or paynow_id ~ '^(19|20)[0-9]{2}[0-9]{5}[A-Z]$' or paynow_id ~ '^[TSR][0-9]{2}[A-Z]{2}[0-9]{4}[A-Z]$')
                                         and bank_name is null and account_no is null and account_holder is null)),
  constraint tutor_payout_bank_ok   check (method <> 'bank' or (paynow_id is null and char_length(bank_name) between 2 and 60 and account_no ~ '^[0-9]{7,16}$' and char_length(account_holder) between 2 and 80))
);
create unique index if not exists tutor_payout_one_current on public.tutor_payout_details(membership_id) where superseded_at is null;
create index if not exists tutor_payout_membership on public.tutor_payout_details(membership_id, created_at desc);

-- nobody reaches it from a browser: row-level security on with no policy, and no table privileges for the browser roles
alter table public.tutor_payout_details enable row level security;
revoke all on public.tutor_payout_details from public, anon, authenticated;

-- append-only: the ONLY change ever allowed is retiring a row (superseded_at / cleared_at, once); delete only while a whole solo organisation is being
-- removed (same gate as audit_immutable / org_delete_solo: td.deleting_org equals the row's own org, and never for a browser role)
create or replace function public.tutor_payout_guard() returns trigger language plpgsql set search_path = public as $$
declare gate text := coalesce(current_setting('td.deleting_org', true), '');
begin
  if tg_op = 'DELETE' then
    if gate <> '' and gate = old.org_id::text and current_user not in ('anon', 'authenticated', 'service_role') then return old; end if;
    raise exception 'tutor_payout_details is append-only';
  end if;
  if old.superseded_at is null and new.superseded_at is not null
     and (to_jsonb(new) - 'superseded_at' - 'cleared_at') = (to_jsonb(old) - 'superseded_at' - 'cleared_at') then return new; end if;
  raise exception 'tutor_payout_details is append-only';
end $$;
drop trigger if exists tutor_payout_immutable on public.tutor_payout_details;
create trigger tutor_payout_immutable before update or delete on public.tutor_payout_details for each row execute function public.tutor_payout_guard();

-- ---------------------------------------------------------------- helpers (no browser role may call these)
create or replace function public.td_payout_mask(p_value text) returns text language sql immutable set search_path = public as $$
  select case when p_value is null or p_value = '' then null else '•••••' || right(p_value, 4) end $$;

-- the one place that writes payout audit rows: method + masked value only, never a full number or a name
create or replace function public.td_payout_audit(p_org uuid, p_membership uuid, p_row uuid, p_action text, p_method text, p_masked text) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into audit_log(org_id, actor, action, table_name, row_id, after)
  values (p_org, auth.uid(), p_action, 'tutor_payout_details', p_row::text, jsonb_build_object('membership_id', p_membership, 'method', p_method, 'masked', p_masked));
end $$;

-- is p_membership MY active tutor membership in a CENTRE? (the caller's own row only; solo organisations never qualify)
create or replace function public.td_my_centre_tutor(p_membership uuid) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare o uuid;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select m.org_id into o from memberships m join organisations g on g.id = m.org_id
    where m.id = p_membership and m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active' and g.kind = 'centre';
  if o is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  return o;
end $$;

-- ---------------------------------------------------------------- read mine (masked)
-- One row per centre where I am an active tutor. The holder name is hidden too: first letter only.
create or replace function public.tutor_my_payout()
returns table(membership_id uuid, org_id uuid, org_name text, has_payout boolean, method text, masked text, bank_name text, holder_hint text, updated_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  return query
    select m.id, m.org_id, o.trading_name, p.id is not null, p.method,
           td_payout_mask(case when p.method = 'bank' then p.account_no else p.paynow_id end),
           p.bank_name, case when p.account_holder is null then null else left(p.account_holder, 1) || '•••' end, p.created_at
    from memberships m join organisations o on o.id = m.org_id
    left join tutor_payout_details p on p.membership_id = m.id and p.superseded_at is null
    where m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active' and o.kind = 'centre'
    order by o.trading_name, m.created_at;
end $$;

-- ---------------------------------------------------------------- reveal mine (explicit, audited)
create or replace function public.tutor_reveal_payout(p_membership uuid)
returns table(method text, paynow_id text, bank_name text, account_no text, account_holder text)
language plpgsql security definer set search_path = public as $$
declare o uuid; r tutor_payout_details;
begin
  o := td_my_centre_tutor(p_membership);
  select * into r from tutor_payout_details p where p.membership_id = p_membership and p.superseded_at is null;
  if not found then raise exception 'NO_PAYOUT: you have no payout details saved yet' using errcode = 'P0001'; end if;
  perform td_payout_audit(o, p_membership, r.id, 'payout_revealed', r.method, td_payout_mask(case when r.method = 'bank' then r.account_no else r.paynow_id end));
  return query select r.method, r.paynow_id, r.bank_name, r.account_no, r.account_holder;
end $$;

-- ---------------------------------------------------------------- save mine
-- p_method: paynow_mobile (p_value = the mobile) | paynow_uen (p_value = the UEN) | bank (p_bank_name, p_value = the account number, p_holder).
-- Spaces and dashes are ignored. p_confirm must be true ("these are my own details"). Saving the same details again changes nothing.
create or replace function public.tutor_save_payout(p_membership uuid, p_method text, p_value text, p_bank_name text default null, p_holder text default null, p_confirm boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare o uuid; v text := regexp_replace(coalesce(p_value, ''), '[\s\-]', '', 'g'); bn text := trim(coalesce(p_bank_name, '')); hn text := trim(coalesce(p_holder, ''));
        cur tutor_payout_details; nid uuid;
begin
  o := td_my_centre_tutor(p_membership);
  if p_confirm is not true then raise exception 'NEED_CONFIRM: please tick that these are your own details' using errcode = 'P0001'; end if;
  if p_method = 'paynow_mobile' then
    if v ~ '^[89][0-9]{7}$' then v := '+65' || v; elsif v ~ '^65[89][0-9]{7}$' then v := '+' || v; end if;
    if v !~ '^\+65[89][0-9]{7}$' then raise exception 'BAD_PAYNOW_MOBILE: use a Singapore mobile that starts with 8 or 9, like 8123 4567' using errcode = 'P0001'; end if;
    bn := null; hn := null;
  elsif p_method = 'paynow_uen' then
    v := upper(v);
    if not (v ~ '^[0-9]{8}[A-Z]$' or v ~ '^(19|20)[0-9]{2}[0-9]{5}[A-Z]$' or v ~ '^[TSR][0-9]{2}[A-Z]{2}[0-9]{4}[A-Z]$') then
      raise exception 'BAD_UEN: a UEN has 9 or 10 characters, like 53123456K or 201912345A' using errcode = 'P0001'; end if;
    bn := null; hn := null;
  elsif p_method = 'bank' then
    if char_length(bn) < 2 or char_length(bn) > 60 then raise exception 'BAD_BANK_NAME: choose or type your bank (2 to 60 characters)' using errcode = 'P0001'; end if;
    if v !~ '^[0-9]{7,16}$' then raise exception 'BAD_ACCOUNT: an account number is 7 to 16 digits, with no letters' using errcode = 'P0001'; end if;
    if char_length(hn) < 2 or char_length(hn) > 80 then raise exception 'BAD_HOLDER: type the name on the bank account (2 to 80 characters)' using errcode = 'P0001'; end if;
  else
    raise exception 'BAD_METHOD: choose PayNow mobile, PayNow UEN or bank account' using errcode = 'P0001';
  end if;

  select * into cur from tutor_payout_details p where p.membership_id = p_membership and p.superseded_at is null for update;
  if found and cur.method = p_method
     and coalesce(case when p_method = 'bank' then cur.account_no else cur.paynow_id end, '') = v
     and cur.bank_name is not distinct from bn and cur.account_holder is not distinct from hn then return; end if;   -- nothing changed

  if found then update tutor_payout_details set superseded_at = now() where id = cur.id; end if;
  insert into tutor_payout_details(org_id, membership_id, method, paynow_id, bank_name, account_no, account_holder, created_by)
  values (o, p_membership, p_method, case when p_method = 'bank' then null else v end, bn, case when p_method = 'bank' then v else null end, hn, auth.uid())
  returning id into nid;
  perform td_payout_audit(o, p_membership, nid, 'payout_saved', p_method, td_payout_mask(v));
end $$;

-- ---------------------------------------------------------------- clear mine
create or replace function public.tutor_clear_payout(p_membership uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o uuid; cur tutor_payout_details;
begin
  o := td_my_centre_tutor(p_membership);
  select * into cur from tutor_payout_details p where p.membership_id = p_membership and p.superseded_at is null for update;
  if not found then return; end if;
  update tutor_payout_details set superseded_at = now(), cleared_at = now() where id = cur.id;
  perform td_payout_audit(o, p_membership, cur.id, 'payout_cleared', cur.method, td_payout_mask(case when cur.method = 'bank' then cur.account_no else cur.paynow_id end));
end $$;

-- ---------------------------------------------------------------- who may call what (each function checks the caller itself)
do $$
declare f text;
begin
  foreach f in array array['tutor_my_payout()', 'tutor_reveal_payout(uuid)', 'tutor_save_payout(uuid,text,text,text,text,boolean)', 'tutor_clear_payout(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['td_payout_audit(uuid,uuid,uuid,text,text,text)', 'td_my_centre_tutor(uuid)', 'td_payout_mask(text)', 'tutor_payout_guard()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;

-- #####################################################################################################
-- ### PART 5 of 9 — payout permission view_payout_details + centre list/reveal (redefines org_invite, org_update_member)
-- ### source branch: claude/t24c-3-payout   file: db/migration_payout_permission.sql
-- ### undo: db/migration_payout_permission_down.sql (restores the two functions)
-- ### (if an error appears, search this file for the nearest "### PART" line above the error line: that is the part that failed)
-- #####################################################################################################
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

-- #####################################################################################################
-- ### PART 6 of 9 — centre Students and households (staff_students, staff_student, staff_save_student, staff_set_student_end)
-- ### source branch: claude/t3-2-students   file: db/migration_staff_students.sql
-- ### undo: db/migration_staff_students_down.sql
-- ### (if an error appears, search this file for the nearest "### PART" line above the error line: that is the part that failed)
-- #####################################################################################################
-- =====================================================================================================
-- T3 step 2 — centre Students and households (view + edit): five functions                 undo: migration_staff_students_down.sql
-- =====================================================================================================
-- Needs migration_org_foundation.sql (students.org_id / household_id, households, guardians, audit_row), migration_tutor_access.sql
-- (lessons.taught_by, trial) and migration_staff_home.sql only for the page. ADD-ONLY: five new functions, no table or column is touched.
--
-- WHAT IT IS: the centre's staff screen for students is just these functions. The page never writes a table; every rule is here, so it
-- holds for any caller (the page, a script, someone with their own copy of the app):
--   staff_students(org, q, filter, page, size)       the list: server-side search + paging (a centre can have 400+ students)
--   staff_student(org, student)                      one student's sheet: details, family + guardians (phone, email), subjects, next lessons
--   staff_save_student(org, student, name, level, notes, household, household_name, guardians)
--                                                    add (student = null, creates the household and its guardians in ONE step) or edit
--   staff_set_student_end(org, student, date)        "lessons run until" (same meaning as for solo tutors); date = null brings them back
--
-- WHO MAY CALL (decided for T3.1, 2026-11-25): an active OWNER or STAFF member of this CENTRE with the manage_students permission (owners
-- always). Nothing else:
--   not a member / a tutor / a parent / switched-off staff / a solo organisation / an unknown id  → NOT_FOUND (same words for all, so ids can't be probed)
--   staff of this centre WITHOUT manage_students (e.g. timetable-only)                           → NOT_ALLOWED
-- Centre tutors still have NO table access at all (CLAUDE.md): they never read students, households or guardians, and still see a parent's
-- contact only through tutor_my_lessons, and only when the centre switched on lessons.tutors_see_parent_contact (default off).
--
-- WHAT STAYS FIXED (integrity, not process): students belong to the CENTRE (org_id) and never to a solo organisation; a household, a guardian
-- or a student id from ANOTHER organisation is treated as "doesn't exist"; every write is validated here and leaves an audit_log row (the
-- generic row triggers on students / households / guardians record before + after, and each function adds one named summary entry).
-- NOTHING here needs a class, a room or a branch: a remote 1-to-1 centre adds a student with just a name and a parent's phone or email.
--
-- DATA-MODEL CHOICES (plain words):
--   * A HOUSEHOLD is the family (your "household id" sheet); GUARDIANS are the family's contacts (name, relation, phone, email). Siblings share one
--     household, so a phone number is edited once for all of them.
--   * students.tutor_id is NOT NULL and cascades on delete of that login. A centre's students must not disappear when a staff member's login is
--     removed, so a new student is filed under the centre OWNER's login (the organisation itself goes with the owner anyway).
--   * The MAIN contact of a family is its first guardian (the one added first; the list keeps the order they were typed in).
--   * students.contact and students.recipient_name are the older single-parent fields that tutor_my_lessons / messages / invoices read. They are
--     kept equal to the household's FIRST guardian, so those readers keep working (and a tutor sees the number only if the centre allows it).
--   * Discontinuing = students.end_date ("lessons run until", inclusive), exactly as for solo tutors: after it the student counts as
--     discontinued everywhere (staff_home, the list). Like the solo page it also switches the student's weekly slots off once the date has
--     passed, and back on when the student is brought back. Lessons already made are left alone.
--   * Trial is shown read-only here (a trial lesson in the last 30 days, in the centre's own timezone); flagging a trial is T3 step 5.
-- Run on the DEV project first. Safe to run twice.
-- =====================================================================================================

-- ---------------------------------------------------------------- the gate every function starts with (internal; not callable from the browser)
create or replace function public.staff_students_gate(p_org uuid) returns date
language plpgsql stable security definer set search_path = public as $$
declare tz text;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select o.timezone into tz from organisations o where o.id = p_org and o.kind = 'centre';
  if tz is null or not exists (select 1 from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active'
                               and m.role in ('owner', 'staff')) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if not org_can(p_org, 'manage_students') then
    raise exception 'NOT_ALLOWED: your account can''t manage students at this centre' using errcode = '42501';
  end if;
  return (now() at time zone tz)::date;                       -- the centre's own today
end $$;

-- ---------------------------------------------------------------- contacts: one place that validates and tidies a guardian
create or replace function public.staff_clean_guardian(g jsonb) returns jsonb
language plpgsql immutable set search_path = public as $$
declare nm text; rel text; ph text; em text; digits int;
begin
  if jsonb_typeof(g) is distinct from 'object' then raise exception 'BAD_GUARDIAN: a guardian must be an object' using errcode = 'P0001'; end if;
  nm  := nullif(trim(coalesce(g->>'name', '')), '');
  rel := nullif(trim(coalesce(g->>'relation', '')), '');
  ph  := nullif(trim(coalesce(g->>'phone', '')), '');
  em  := nullif(lower(trim(coalesce(g->>'email', ''))), '');
  if nm is null then raise exception 'BAD_GUARDIAN: give each parent or guardian a name' using errcode = 'P0001'; end if;
  if length(nm) > 120 then raise exception 'BAD_GUARDIAN: a guardian''s name is too long (120 characters at most)' using errcode = 'P0001'; end if;
  if rel is not null and length(rel) > 40 then raise exception 'BAD_GUARDIAN: the relation is too long (40 characters at most)' using errcode = 'P0001'; end if;
  if ph is null and em is null then
    raise exception 'BAD_GUARDIAN: give % a phone number or an email, so the centre can reach the family', nm using errcode = 'P0001'; end if;
  if ph is not null then
    digits := length(regexp_replace(ph, '\D', '', 'g'));
    if ph !~ '^[0-9+()\s-]{6,30}$' or digits < 6 or digits > 15 then
      raise exception 'BAD_GUARDIAN: that phone number doesn''t look right (%)', ph using errcode = 'P0001'; end if;
  end if;
  if em is not null and (length(em) > 254 or em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then
    raise exception 'BAD_GUARDIAN: that email address doesn''t look right (%)', em using errcode = 'P0001'; end if;
  return jsonb_build_object('id', nullif(g->>'id', ''), 'name', nm, 'relation', rel, 'phone', ph, 'email', em);
end $$;

-- ---------------------------------------------------------------- 1. the list
-- p_filter: 'active' (default) | 'ended' | 'trial' (a trial lesson in the last 30 days) | 'all'.  p_q searches the student's name and level, the
-- family's name, and every guardian's name, email and phone (digits only: "9123" finds "+65 9123 4567").  Counts come back for every filter
-- (for the current search) so the tabs can show them.  Names and phone numbers only: never money.
create or replace function public.staff_students(p_org uuid, p_q text default null, p_filter text default 'active', p_page int default 1, p_size int default 25)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare today date := staff_students_gate(p_org); q text := nullif(trim(coalesce(p_q, '')), ''); pat text; dig text; pg int; sz int;
        res jsonb; flt text := coalesce(p_filter, 'active');
begin
  if flt not in ('active', 'ended', 'trial', 'all') then raise exception 'BAD_FILTER: unknown filter' using errcode = 'P0001'; end if;
  if q is not null and length(q) > 100 then raise exception 'BAD_SEARCH: search for at most 100 characters' using errcode = 'P0001'; end if;
  sz := least(greatest(coalesce(p_size, 25), 1), 100);
  pg := greatest(coalesce(p_page, 1), 1);
  if q is not null then
    pat := '%' || replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
    dig := nullif(regexp_replace(q, '\D', '', 'g'), '');
    -- the digits-only match is for something that LOOKS like a phone number (digits, spaces, + - and brackets, at least 3 digits); "Sec 2" is not one
    if q !~ '^[0-9+()\s-]+$' or length(coalesce(dig, '')) < 3 then dig := null; end if;
  end if;
  with matched as (
    select s.id, s.name, s.level, s.end_date, s.household_id, h.name as hname,
           (s.end_date is not null and s.end_date < today) as ended,
           exists (select 1 from lessons l where l.org_id = p_org and l.student_id = s.id and l.trial and l.lesson_date >= today - 30) as trial,
           (select count(*) from guardians gc where gc.org_id = p_org and gc.household_id = s.household_id) as gcount,
           g.name as gname, g.phone as gphone
      from students s
      left join households h on h.id = s.household_id and h.org_id = p_org
      left join lateral (select x.name, x.phone from guardians x where x.org_id = p_org and x.household_id = s.household_id order by x.created_at, x.id limit 1) g on true
     where s.org_id = p_org
       and (q is null or s.name ilike pat or s.level ilike pat or h.name ilike pat
            or exists (select 1 from guardians gg where gg.org_id = p_org and gg.household_id = s.household_id
                         and (gg.name ilike pat or gg.email ilike pat or gg.phone ilike pat
                              or (dig is not null and regexp_replace(coalesce(gg.phone, ''), '\D', '', 'g') like '%' || dig || '%'))))),
  shown as (
    select * from matched m where case flt when 'active' then not m.ended when 'ended' then m.ended when 'trial' then m.trial else true end),
  page as (select * from shown order by lower(name), id limit sz offset (pg - 1) * sz)
  select jsonb_build_object(
    'org_id', p_org, 'today', today, 'filter', flt, 'page', pg, 'size', sz,
    'total', (select count(*) from shown),
    'counts', jsonb_build_object('active', (select count(*) from matched where not ended), 'ended', (select count(*) from matched where ended),
                                 'trial', (select count(*) from matched where trial), 'all', (select count(*) from matched)),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'level', p.level, 'end_date', p.end_date, 'ended', p.ended,
                       'trial', p.trial, 'household_id', p.household_id, 'household_name', p.hname,
                       'guardian_name', p.gname, 'guardian_phone', p.gphone, 'guardians', p.gcount) order by lower(p.name), p.id) from page p), '[]'::jsonb))
    into res;
  return res;
end $$;

-- ---------------------------------------------------------------- 2. one student's sheet
create or replace function public.staff_student(p_org uuid, p_student uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_students_gate(p_org); s students; hh households; res jsonb;
begin
  select * into s from students where id = p_student and org_id = p_org;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into hh from households where id = s.household_id and org_id = p_org;
  select jsonb_build_object(
    'id', s.id, 'org_id', p_org, 'name', s.name, 'level', s.level, 'notes', s.notes, 'end_date', s.end_date,
    'ended', (s.end_date is not null and s.end_date < today), 'created_at', s.created_at, 'today', today,
    'household', case when hh.id is null then null else jsonb_build_object('id', hh.id, 'name', hh.name) end,
    'guardians', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'relation', g.relation, 'phone', g.phone, 'email', g.email)
                                            order by g.created_at, g.id) from guardians g where g.org_id = p_org and g.household_id = s.household_id), '[]'::jsonb),
    'siblings', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'level', x.level,
                                            'ended', (x.end_date is not null and x.end_date < today)) order by lower(x.name), x.id)
                            from students x where x.org_id = p_org and x.household_id = s.household_id and x.id <> s.id), '[]'::jsonb),
    -- the subjects they are taught: what the data model has (a subject lives on the lesson and on the weekly slot, not on the student)
    'subjects', coalesce((select jsonb_agg(sj order by sj) from (
                            select distinct l.subject as sj from lessons l where l.org_id = p_org and l.student_id = s.id and nullif(trim(l.subject), '') is not null
                            union select distinct r.subject from recurring_slots r where r.org_id = p_org and r.student_id = s.id and nullif(trim(r.subject), '') is not null) u), '[]'::jsonb),
    'lessons_total', (select count(*) from lessons l where l.org_id = p_org and l.student_id = s.id),
    'lessons_trial', (select count(*) from lessons l where l.org_id = p_org and l.student_id = s.id and l.trial),
    'trial', exists (select 1 from lessons l where l.org_id = p_org and l.student_id = s.id and l.trial and l.lesson_date >= today - 30),
    -- when and who only; no price, no payment
    'next_lessons', coalesce((select jsonb_agg(jsonb_build_object('date', n.lesson_date, 'start', n.start_time, 'end', n.end_time, 'subject', n.subject,
                                            'tutor', n.tutor) order by n.lesson_date, n.start_time)
                                from (select l.lesson_date, l.start_time, l.end_time, l.subject, m.display_name as tutor
                                        from lessons l left join memberships m on m.id = l.taught_by and m.org_id = l.org_id
                                       where l.org_id = p_org and l.student_id = s.id and l.lesson_date >= today and l.status <> 'cancelled'
                                       order by l.lesson_date, l.start_time limit 5) n), '[]'::jsonb))
    into res;
  return res;
end $$;

-- ---------------------------------------------------------------- 3. add or edit (one atomic step)
-- p_student null = ADD, otherwise EDIT that student.
-- p_household: ADD only. null = a new household (the family) is created, and p_guardians (at least one) are its contacts. A household id = add a
--   sibling to that existing family (p_guardians then optional: null leaves the family's contacts as they are).  Editing never moves a student
--   to another household (merging families is out of scope).
-- p_guardians: a json array of {id?, name, relation, phone, email}. null = leave the family's contacts untouched. Otherwise it is the COMPLETE new
--   list for the household: entries with an id are updated, entries without one are added, and contacts not in the list are removed.
--   (A contact someone has linked to a parent-portal login can't be removed here.) Each needs a name and a phone or an email; at most 6.
-- p_household_name: the family's name; blank = "<student's name>'s family" for a new household, unchanged when editing.
-- Returns {student_id, household_id, created}.
create or replace function public.staff_save_student(p_org uuid, p_student uuid, p_name text, p_level text default null, p_notes text default null,
  p_household uuid default null, p_household_name text default null, p_guardians jsonb default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := staff_students_gate(p_org); s students; hid uuid; nm text := nullif(trim(coalesce(p_name, '')), ''); lv text := nullif(trim(coalesce(p_level, '')), '');
        nt text := nullif(trim(coalesce(p_notes, '')), ''); hn text := nullif(trim(coalesce(p_household_name, '')), ''); owner_uid uuid; created boolean := false;
        clean jsonb := '[]'::jsonb; gj jsonb; c jsonb; gid uuid; first_g record;
begin
  -- ---- validate everything before changing anything
  if nm is null then raise exception 'BAD_STUDENT: give the student a name' using errcode = 'P0001'; end if;
  if length(nm) > 120 then raise exception 'BAD_STUDENT: the name is too long (120 characters at most)' using errcode = 'P0001'; end if;
  if lv is not null and length(lv) > 40 then raise exception 'BAD_STUDENT: the level is too long (40 characters at most)' using errcode = 'P0001'; end if;
  if nt is not null and length(nt) > 1000 then raise exception 'BAD_STUDENT: the notes are too long (1000 characters at most)' using errcode = 'P0001'; end if;
  if hn is not null and length(hn) > 120 then raise exception 'BAD_STUDENT: the family name is too long (120 characters at most)' using errcode = 'P0001'; end if;
  if p_guardians is not null then
    if jsonb_typeof(p_guardians) <> 'array' then raise exception 'BAD_GUARDIAN: guardians must be a list' using errcode = 'P0001'; end if;
    if jsonb_array_length(p_guardians) > 6 then raise exception 'BAD_GUARDIAN: at most 6 parents or guardians per family' using errcode = 'P0001'; end if;
    if jsonb_array_length(p_guardians) = 0 then raise exception 'BAD_GUARDIAN: a family needs at least one parent or guardian to contact' using errcode = 'P0001'; end if;
    for gj in select * from jsonb_array_elements(p_guardians) loop clean := clean || jsonb_build_array(staff_clean_guardian(gj)); end loop;
  end if;

  if p_student is null then                                                      -- ===================== ADD
    if p_household is null then
      if p_guardians is null then
        raise exception 'BAD_GUARDIAN: add a parent or guardian with a phone number or an email, so the centre can reach the family' using errcode = 'P0001'; end if;
    else
      if not exists (select 1 from households h where h.id = p_household and h.org_id = p_org) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
      if exists (select 1 from students x where x.org_id = p_org and x.household_id = p_household and lower(x.name) = lower(nm)) then
        raise exception 'DUPLICATE: % is already in this family', nm using errcode = 'P0001'; end if;
    end if;
    -- filed under the centre owner's login (see the header); the row guard needs them to be in this organisation, which an owner always is
    select m.user_id into owner_uid from memberships m where m.org_id = p_org and m.role = 'owner' and m.status = 'active' and m.user_id is not null
      order by m.created_at limit 1;
    if owner_uid is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    hid := p_household;
    if hid is null then
      insert into households(org_id, name) values (p_org, coalesce(hn, nm || '''s family')) returning id into hid;
    elsif hn is not null then
      update households set name = hn where id = hid and name is distinct from hn;
    end if;
    insert into students(tutor_id, org_id, household_id, name, level, notes) values (owner_uid, p_org, hid, nm, lv, nt) returning * into s;
    created := true;
  else                                                                           -- ===================== EDIT
    select * into s from students where id = p_student and org_id = p_org;
    if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    if p_household is not null and p_household is distinct from s.household_id then
      raise exception 'BAD_STUDENT: moving a student to another family isn''t supported yet' using errcode = 'P0001'; end if;
    hid := s.household_id;
    if hid is null then                                                          -- an older student with no family yet: make one
      insert into households(org_id, name) values (p_org, coalesce(hn, nm || '''s family')) returning id into hid;
    elsif hn is not null then
      update households set name = hn where id = hid and org_id = p_org and name is distinct from hn;
    end if;
    update students set name = nm, level = lv, notes = nt, household_id = hid where id = s.id;
  end if;

  -- ---- the family's contacts
  if p_guardians is not null then
    -- every id must be one of THIS family's contacts (an id from somewhere else is "doesn't exist")
    for c in select * from jsonb_array_elements(clean) loop
      if c->>'id' is not null then
        begin gid := (c->>'id')::uuid; exception when others then raise exception 'NOT_FOUND' using errcode = 'P0001'; end;
        if not exists (select 1 from guardians g where g.id = gid and g.org_id = p_org and g.household_id = hid) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
      end if;
    end loop;
    -- contacts left out of the list are removed, unless a parent-portal login is linked to them
    if exists (select 1 from guardians g where g.org_id = p_org and g.household_id = hid and g.user_id is not null
                 and g.id::text not in (select x->>'id' from jsonb_array_elements(clean) x where x->>'id' is not null)) then
      raise exception 'BAD_GUARDIAN: a contact with a parent login can''t be removed here' using errcode = 'P0001'; end if;
    delete from guardians g where g.org_id = p_org and g.household_id = hid
       and g.id::text not in (select x->>'id' from jsonb_array_elements(clean) x where x->>'id' is not null);
    for c in select * from jsonb_array_elements(clean) loop
      if c->>'id' is not null then
        update guardians set name = c->>'name', relation = c->>'relation', phone = c->>'phone', email = c->>'email' where id = (c->>'id')::uuid;
      else
        insert into guardians(org_id, household_id, name, relation, phone, email, created_at)      -- (clock_timestamp: contacts added in one call keep their order)
        values (p_org, hid, c->>'name', c->>'relation', c->>'phone', c->>'email', clock_timestamp());
      end if;
    end loop;
  end if;

  -- ---- keep the older single-parent fields equal to the family's first contact (what tutor_my_lessons, messages and invoices still read)
  select g.name, g.phone into first_g from guardians g where g.org_id = p_org and g.household_id = hid order by g.created_at, g.id limit 1;
  update households set phone_key = org_phone_key(first_g.phone) where id = hid and phone_key is distinct from org_phone_key(first_g.phone);
  update students set contact = first_g.phone, recipient_name = first_g.name
   where org_id = p_org and household_id = hid and (contact is distinct from first_g.phone or recipient_name is distinct from first_g.name);

  insert into audit_log(org_id, actor, action, table_name, row_id, after)
  values (p_org, auth.uid(), case when created then 'staff_student_add' else 'staff_student_edit' end, 'students', s.id::text,
          jsonb_build_object('name', nm, 'level', lv, 'household_id', hid, 'guardians_replaced', p_guardians is not null));
  return jsonb_build_object('student_id', s.id, 'household_id', hid, 'created', created);
end $$;

-- ---------------------------------------------------------------- 4. discontinue / bring back
-- p_end_date = "lessons run until" (inclusive), today or earlier or later, between 2000 and 2100. null = bring the student back (clears the date).
-- Once the date has passed the student's weekly slots are switched off; bringing them back (or a date still to come) switches them on. Lessons stay.
create or replace function public.staff_set_student_end(p_org uuid, p_student uuid, p_end_date date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := staff_students_gate(p_org); s students; ended boolean;
begin
  select * into s from students where id = p_student and org_id = p_org;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_end_date is not null and (p_end_date < date '2000-01-01' or p_end_date > date '2100-01-01') then
    raise exception 'BAD_DATE: pick a sensible date' using errcode = 'P0001'; end if;
  ended := p_end_date is not null and p_end_date < today;
  update students set end_date = p_end_date, active = not ended where id = s.id;
  update recurring_slots set active = not ended where org_id = p_org and student_id = s.id and active = ended;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), case when p_end_date is null then 'staff_student_reactivate' else 'staff_student_end' end, 'students', s.id::text,
          jsonb_build_object('end_date', s.end_date), jsonb_build_object('end_date', p_end_date));
  return jsonb_build_object('student_id', s.id, 'end_date', p_end_date, 'ended', ended);
end $$;

-- ---------------------------------------------------------------- who may call what
-- The four screens' functions: signed-in users only (each one checks the person itself). The gate and the contact cleaner are internal.
revoke all on function public.staff_students(uuid, text, text, int, int) from public, anon;
revoke all on function public.staff_student(uuid, uuid) from public, anon;
revoke all on function public.staff_save_student(uuid, uuid, text, text, text, uuid, text, jsonb) from public, anon;
revoke all on function public.staff_set_student_end(uuid, uuid, date) from public, anon;
grant execute on function public.staff_students(uuid, text, text, int, int) to authenticated;
grant execute on function public.staff_student(uuid, uuid) to authenticated;
grant execute on function public.staff_save_student(uuid, uuid, text, text, text, uuid, text, jsonb) to authenticated;
grant execute on function public.staff_set_student_end(uuid, uuid, date) to authenticated;
revoke all on function public.staff_students_gate(uuid) from public, anon, authenticated;
revoke all on function public.staff_clean_guardian(jsonb) from public, anon, authenticated;

-- #####################################################################################################
-- ### PART 7 of 9 — centre Attendance (lessons_attendance_guard trigger + staff_lessons / staff_mark_attendance / staff_correct_attendance) — MUST come before PART 8
-- ### source branch: claude/t3-3-attendance   file: db/migration_staff_attendance.sql
-- ### undo: db/migration_staff_attendance_down.sql
-- ### (if an error appears, search this file for the nearest "### PART" line above the error line: that is the part that failed)
-- #####################################################################################################
-- =====================================================================================================
-- T3 step 3 — centre Attendance for owners and staff: view, mark, correct        undo: migration_staff_attendance_down.sql
-- =====================================================================================================
-- Needs migration_org_foundation.sql, migration_attendance.sql and migration_tutor_access.sql (lessons.attendance, taught_by, the stamp trigger).
-- ADD-ONLY: one new trigger on `lessons` and four new functions; no table or column is touched.
--
-- PART 1 — CLOSING THE INTEGRITY HOLE (the rules now live in the table, so they hold for EVERY writer)
--   Until now "not before the lesson's day" and "never over someone else's mark" were only checked inside tutor_mark_attendance. Staff and
--   owners write `lessons` straight through the org_write policy, so a script or a copy of the app could mark tomorrow's lesson, or overwrite a
--   tutor's mark, and nobody would be asked why. The trigger lessons_attendance_guard (centres only) now refuses, for anyone signed in:
--     * setting attendance on a lesson whose day (in the CENTRE's timezone) hasn't started        → TOO_EARLY
--     * changing or clearing a mark that somebody ELSE made                                        → ALREADY_MARKED
--     * editing attendance_marked_by / attendance_marked_at on their own (a back door to the rule above) → LOCKED
--   The ONE way past the second and third rule is staff_correct_attendance(), which sets a transaction-local flag naming that one lesson
--   (td.attendance_override = the lesson id, like td.deleting_org) after checking permission and a written reason. "Too early" has NO way
--   past, not even for the function. Solo tutors' lessons never reach the guard (it returns at once unless the lesson's organisation is a
--   centre) and server jobs with no signed-in user (auth.uid() is null: billing, the account-deletion function) are not "someone marking".
--
-- PART 2 — WHAT STAFF CAN DO (decided by the owner, 2026-11-25)
--   staff_lessons(org, from, to, tutor, status, page, size)   the list for a day or a week (at most 62 days), filters, server-side paging.
--                                                             Any owner / staff member may LOOK. Returns NO money (no rate, amount, paid,
--                                                             compensation or *_cents), only the yes/no "charge pending".
--   staff_mark_attendance(lesson, attendance, remarks)        first mark of a lesson, from its day onward. Needs manage_timetable.
--   staff_correct_attendance(lesson, attendance, reason)      change a mark somebody already made. Needs manage_timetable AND a written
--                                                             reason; writes a named audit entry with the reason. Tutors never.
--   * Staff can ALWAYS mark and correct. lessons.attendance_by (tutor | admin), attendance_window_days and cancellations_marked_by only
--     govern TUTORS (tutor_mark_attendance); they are not consulted here. Staff may set all four values, including both cancellations.
--   * Status follows attendance, set by the existing stamp trigger (never typed): attended = done; absent / cancelled_early / late_cancelled =
--     cancelled. The charge for an absent / cancelled lesson is its COMPENSATION: a number someone types, 0 if the family isn't charged,
--     null = "charge pending". THIS step never types it (that is step 4); marking absent leaves it null, marking attended clears it.
--     lessons.compensation_entered_by (admin | tutor) only decides who types it later; billing.absences.mode only pre-fills the suggestion later.
--   * lessons.remarks.required is the centre's rule for marking ATTENDED (same words as for tutors). Correcting an old mark does not re-require remarks.
--   * A lesson cancelled by staff with no attendance mark is CLOSED: it can't be marked (same as the tutor function).
--   * Nothing needs a class, a room or a branch: a remote 1-to-1 centre marks lessons with just a student and a time.
--
-- WHO MAY CALL
--   not a member / a tutor / a parent / switched-off staff / a solo organisation / an unknown id  → NOT_FOUND (same words for all, so ids can't be probed)
--   staff WITHOUT manage_timetable (look only)                                                   → NOT_ALLOWED when they try to mark or correct
-- Run on the DEV project first. Safe to run twice.
-- =====================================================================================================

-- ---------------------------------------------------------------- PART 1: the guard
create or replace function public.lessons_attendance_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); tz text; today date; override boolean;
begin
  if me is null then return new; end if;                                   -- server jobs, not a person marking
  select o.timezone into tz from organisations o where o.id = new.org_id and o.kind = 'centre';
  if tz is null then return new; end if;                                   -- solo tutors' lessons: nothing changes
  today := (now() at time zone tz)::date;                                  -- the centre's own calendar day, not the server's
  override := coalesce(current_setting('td.attendance_override', true), '') = new.id::text;

  if tg_op = 'INSERT' then
    if new.attendance is not null and new.lesson_date > today then
      raise exception 'TOO_EARLY: a lesson can be marked from its day onward' using errcode = 'P0001'; end if;
    return new;
  end if;

  if new.attendance is not distinct from old.attendance then
    -- the stamp columns are the proof of who marked; they change only together with the mark (the stamp trigger) or by a correction
    if (new.attendance_marked_by is distinct from old.attendance_marked_by or new.attendance_marked_at is distinct from old.attendance_marked_at)
       and not override then
      raise exception 'LOCKED: who marked a lesson and when can''t be edited by hand' using errcode = 'P0001'; end if;
    return new;
  end if;

  if new.attendance is not null and new.lesson_date > today then
    raise exception 'TOO_EARLY: a lesson can be marked from its day onward' using errcode = 'P0001'; end if;
  if old.attendance is not null and old.attendance_marked_by is distinct from me and not override then
    raise exception 'ALREADY_MARKED: someone else already marked this lesson; use Correct (with a reason) to change it' using errcode = 'P0001'; end if;
  return new;
end $$;
-- fires BEFORE the stamp trigger (triggers run in name order), so it sees what the writer asked for, not what the stamp then fills in
drop trigger if exists lessons_attendance_guard on public.lessons;
create trigger lessons_attendance_guard
  before insert or update of attendance, attendance_marked_by, attendance_marked_at on public.lessons
  for each row execute function public.lessons_attendance_guard();

-- ---------------------------------------------------------------- the gate every staff attendance function starts with (internal)
-- Returns the centre's own "today". p_write = the caller must also hold manage_timetable.
create or replace function public.staff_attendance_gate(p_org uuid, p_write boolean) returns date
language plpgsql stable security definer set search_path = public as $$
declare tz text;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select o.timezone into tz from organisations o where o.id = p_org and o.kind = 'centre';
  if tz is null or not exists (select 1 from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active'
                               and m.role in ('owner', 'staff')) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if p_write and not org_can(p_org, 'manage_timetable') then
    raise exception 'NOT_ALLOWED: your account can''t mark attendance at this centre' using errcode = '42501';
  end if;
  return (now() at time zone tz)::date;
end $$;

-- ---------------------------------------------------------------- PART 2a: the list
-- p_status: 'all' | 'unmarked' (due: its day has started, not cancelled by staff, no mark) | 'marked'. p_tutor: a memberships.id, or null for everyone.
-- state of a row: 'future' (its day hasn't started: no buttons) | 'open' (can be marked) | 'marked' (can be corrected) | 'cancelled' (closed by staff).
-- can_mark / can_correct already include the caller's permission, so the screen doesn't guess.
create or replace function public.staff_lessons(p_org uuid, p_from date, p_to date, p_tutor uuid default null,
                                                p_status text default 'all', p_page int default 1, p_size int default 50) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_attendance_gate(p_org, false); can_tt boolean := org_can(p_org, 'manage_timetable');
        st text := coalesce(nullif(p_status, ''), 'all'); pg int := coalesce(p_page, 1); sz int := coalesce(p_size, 50);
        total int; cnt jsonb; rows jsonb; tutors jsonb;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 62 then
    raise exception 'BAD_RANGE: ask for at most 62 days' using errcode = 'P0001'; end if;
  if st not in ('all', 'unmarked', 'marked') then raise exception 'BAD_FILTER: unknown filter' using errcode = 'P0001'; end if;
  if pg < 1 or pg > 100000 then raise exception 'BAD_PAGE: no such page' using errcode = 'P0001'; end if;
  if sz < 1 or sz > 100 then raise exception 'BAD_PAGE: ask for 1 to 100 lessons at a time' using errcode = 'P0001'; end if;
  if p_tutor is not null and not exists (select 1 from memberships m where m.id = p_tutor and m.org_id = p_org) then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;

  with base as (
    select l.id, l.lesson_date, l.start_time, l.end_time, l.subject, l.status, l.attendance, l.trial, l.remarks, l.session_id,
           l.attendance_marked_at, l.taught_by, (l.compensation is null) as no_comp,
           s.id as sid, s.name as sname, s.level as slevel, t.display_name as tname, mb.display_name as mname,
           (l.status = 'cancelled' and l.attendance is null) as closed,
           (l.attendance is null and l.status <> 'cancelled' and l.lesson_date <= today) as due
      from lessons l
      join students s on s.id = l.student_id and s.org_id = l.org_id
      left join memberships t  on t.id = l.taught_by and t.org_id = l.org_id
      left join memberships mb on mb.user_id = l.attendance_marked_by and mb.org_id = l.org_id
     where l.org_id = p_org and l.lesson_date between p_from and p_to and (p_tutor is null or l.taught_by = p_tutor)),
  d as (
    select base.*, case when closed then 'cancelled' when attendance is not null then 'marked' when lesson_date > today then 'future' else 'open' end as state
      from base),
  c as (select count(*)::int as n_all, (count(*) filter (where due))::int as n_unmarked, (count(*) filter (where attendance is not null))::int as n_marked from d),
  pg_rows as (
    select * from d
     where st = 'all' or (st = 'unmarked' and due) or (st = 'marked' and attendance is not null)
     order by lesson_date, start_time, sname, id
     limit sz offset (pg - 1) * sz)
  select (select row_to_json(c) from c)::jsonb,
         coalesce((select jsonb_agg(jsonb_build_object(
           'lesson_id', id, 'lesson_date', lesson_date, 'start_time', start_time, 'end_time', end_time,
           'student_id', sid, 'student_name', sname, 'student_level', slevel, 'subject', subject,
           'tutor_id', taught_by, 'tutor_name', tname,
           'attendance', attendance, 'status', status, 'state', state, 'trial', trial, 'remarks', remarks,
           'marked_at', attendance_marked_at, 'marked_by_name', mname,
           'charge_pending', (attendance in ('absent', 'cancelled_early', 'late_cancelled') and no_comp),
           'session_id', session_id,
           'can_mark', (can_tt and state = 'open'), 'can_correct', (can_tt and state = 'marked'))
           order by lesson_date, start_time, sname, id) from pg_rows), '[]'::jsonb)
    into cnt, rows;

  total := case st when 'unmarked' then (cnt->>'n_unmarked')::int when 'marked' then (cnt->>'n_marked')::int else (cnt->>'n_all')::int end;
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', m.display_name) order by m.display_name, m.id), '[]'::jsonb) into tutors
    from memberships m where m.org_id = p_org and m.role = 'tutor' and m.status in ('active', 'invited');

  return jsonb_build_object('today', today, 'can_mark', can_tt, 'page', pg, 'size', sz, 'total', total,
                            'counts', jsonb_build_object('all', (cnt->>'n_all')::int, 'unmarked', (cnt->>'n_unmarked')::int,
                                                         'marked', (cnt->>'n_marked')::int),
                            'tutors', tutors, 'rows', rows);
end $$;

-- ---------------------------------------------------------------- PART 2b: the first mark
create or replace function public.staff_mark_attendance(p_lesson uuid, p_attendance text, p_remarks text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l lessons; cfg jsonb; today date; new_remarks text; new_status text;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into l from lessons where id = p_lesson;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := staff_attendance_gate(l.org_id, true);
  cfg := org_settings_on(l.org_id, current_date);

  if p_attendance is null or p_attendance not in ('attended', 'absent', 'late_cancelled', 'cancelled_early') then
    raise exception 'BAD_VALUE: choose attended, absent, late cancelled or cancelled in time' using errcode = 'P0001'; end if;
  if l.status = 'cancelled' and l.attendance is null then
    raise exception 'CANCELLED: this lesson was cancelled' using errcode = 'P0001'; end if;
  if l.attendance is not null then
    raise exception 'ALREADY_MARKED: this lesson is already marked; use Correct (with a reason) to change it' using errcode = 'P0001'; end if;
  if l.lesson_date > today then
    raise exception 'TOO_EARLY: a lesson can be marked from its day onward' using errcode = 'P0001'; end if;
  if length(coalesce(p_remarks, '')) > 2000 then
    raise exception 'TOO_LONG: keep the remarks under 2000 characters' using errcode = 'P0001'; end if;

  new_remarks := case when p_remarks is null then l.remarks else nullif(trim(p_remarks), '') end;
  -- the centre's own rule: a lesson that took place needs its remarks
  if p_attendance = 'attended' and coalesce((cfg #>> '{lessons,remarks,required}')::boolean, false) and new_remarks is null then
    raise exception 'REMARKS_REQUIRED: this centre needs remarks before a lesson is marked attended' using errcode = 'P0001'; end if;

  update lessons set attendance = p_attendance, remarks = new_remarks,
                     remarks_at = case when p_remarks is null then remarks_at else now() end
   where id = l.id returning status into new_status;

  insert into audit_log(org_id, actor, action, table_name, row_id, after)
  values (l.org_id, auth.uid(), 'staff_mark_attendance', 'lessons', l.id::text,
          jsonb_build_object('attendance', p_attendance, 'status', new_status, 'remarks_set', p_remarks is not null));
  return jsonb_build_object('lesson_id', l.id, 'attendance', p_attendance, 'status', new_status);
end $$;

-- ---------------------------------------------------------------- PART 2c: the correction (the only way over someone else's mark)
create or replace function public.staff_correct_attendance(p_lesson uuid, p_attendance text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l lessons; today date; why text := nullif(trim(coalesce(p_reason, '')), ''); new_status text;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into l from lessons where id = p_lesson;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := staff_attendance_gate(l.org_id, true);

  if p_attendance is null or p_attendance not in ('attended', 'absent', 'late_cancelled', 'cancelled_early') then
    raise exception 'BAD_VALUE: choose attended, absent, late cancelled or cancelled in time' using errcode = 'P0001'; end if;
  if why is null then raise exception 'REASON_REQUIRED: say why you are changing this mark' using errcode = 'P0001'; end if;
  if length(why) > 500 then raise exception 'TOO_LONG: keep the reason under 500 characters' using errcode = 'P0001'; end if;
  if l.attendance is null then
    raise exception 'NOT_MARKED: this lesson hasn''t been marked yet; mark it instead' using errcode = 'P0001'; end if;
  if l.attendance = p_attendance then
    raise exception 'NO_CHANGE: the lesson is already marked that way' using errcode = 'P0001'; end if;
  if l.lesson_date > today then
    raise exception 'TOO_EARLY: a lesson can be marked from its day onward' using errcode = 'P0001'; end if;

  -- the flag names THIS lesson only and lasts for this transaction; the guard still refuses "too early" even with it
  perform set_config('td.attendance_override', l.id::text, true);
  update lessons set attendance = p_attendance where id = l.id returning status into new_status;
  perform set_config('td.attendance_override', '', true);

  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (l.org_id, auth.uid(), 'staff_correct_attendance', 'lessons', l.id::text,
          jsonb_build_object('attendance', l.attendance, 'status', l.status, 'marked_by', l.attendance_marked_by, 'marked_at', l.attendance_marked_at),
          jsonb_build_object('attendance', p_attendance, 'status', new_status, 'reason', why));
  return jsonb_build_object('lesson_id', l.id, 'attendance', p_attendance, 'status', new_status);
end $$;

-- ---------------------------------------------------------------- who may call what
revoke all on function public.staff_lessons(uuid, date, date, uuid, text, int, int) from public, anon;
revoke all on function public.staff_mark_attendance(uuid, text, text) from public, anon;
revoke all on function public.staff_correct_attendance(uuid, text, text) from public, anon;
grant execute on function public.staff_lessons(uuid, date, date, uuid, text, int, int) to authenticated;
grant execute on function public.staff_mark_attendance(uuid, text, text) to authenticated;
grant execute on function public.staff_correct_attendance(uuid, text, text) to authenticated;
revoke all on function public.staff_attendance_gate(uuid, boolean) from public, anon, authenticated;
revoke all on function public.lessons_attendance_guard() from public, anon, authenticated;

-- #####################################################################################################
-- ### PART 8 of 9 — centre Pending charges (staff_pending_charges, staff_set_charge(s), pending_charge_count) — needs PART 7
-- ### source branch: claude/t3-4-charges   file: db/migration_staff_charges.sql
-- ### undo: db/migration_staff_charges_down.sql
-- ### (if an error appears, search this file for the nearest "### PART" line above the error line: that is the part that failed)
-- #####################################################################################################
-- =====================================================================================================
-- T3 step 4 — centre Pending charges for owners and staff                          undo: migration_staff_charges_down.sql
-- =====================================================================================================
-- Needs migration_org_foundation.sql, migration_attendance.sql, migration_tutor_access.sql and migration_staff_attendance.sql.
-- ADD-ONLY: five new functions; no table, column, policy or trigger is touched. Nothing here creates an invoice (that is T4).
--
-- THE MODEL (unchanged, owner's rule): an absent / cancelled lesson becomes status 'cancelled' and its billable amount is its COMPENSATION,
-- a number someone types: 0 = the family isn't charged, null = "charge pending" (invoicing must wait for it). `lessons.compensation` is
-- numeric DOLLARS (it always was); `compensation_cents` is the generated whole-cents twin. These functions speak INTEGER CENTS at the edge
-- (as assets/js/money.js does) and store cents / 100 exactly, so the two columns can never disagree.
--
-- WHO MAY CALL (owner's decision, 2026-11-25): an active OWNER, or STAFF holding `issue_invoices`. NOT manage_timetable: a receptionist who marks
-- attendance can't set what a family pays. A tutor, a parent, switched-off staff, a stranger, a solo organisation and an unknown id all get
-- the same NOT_FOUND; staff without issue_invoices get NOT_ALLOWED in plain words.
--
-- THE QUEUE = lessons whose attendance is absent / cancelled_early / late_cancelled and whose compensation is null. (The same rule as the
-- "charges to confirm" number on the centre Home.) Which of the two settings puts a lesson in the queue:
--   lessons.compensation_entered_by = admin   (default) every absent / cancelled lesson waits here, whoever marked it
--   lessons.compensation_entered_by = tutor   the tutor must type the charge when marking (CHARGE_REQUIRED, existing tutor function), so the
--                                             queue holds only lessons STAFF marked and old ones. Staff may always type or change a charge
--                                             here, whatever the setting (they are the safety net); changing a charge that already has a
--                                             number needs a written reason.
-- billing.absences.mode only PRE-FILLS a suggestion; a person always confirms (owner's decision). It is a MONEY rule, so it is read as of the
-- lesson's own day (org_settings_on(org, lesson_date)), not as of today (if no version existed yet that day, today's is used):
--   charged                 suggest the full price for absent, late cancelled and cancelled in time
--   not_charged             suggest 0
--   charged_unless_notice   suggest 0 for "cancelled in time" (that mark already means enough notice was given), the full price otherwise
--   (billing.absences.notice_hours is not re-computed: staff choose "cancelled in time" or "late cancelled" when they mark.)
--
-- RULES THAT NEVER BEND: the amount is a whole number of cents from 0 up to the lesson's own price (amount, else rate × hours); only an
-- absent / cancelled lesson has a charge; a paid lesson's charge is locked; every change writes a named audit entry (who, when, before, after).
-- Run on the DEV project first. Safe to run twice.
-- =====================================================================================================

-- ---------------------------------------------------------------- the gate every charge function starts with (internal)
create or replace function public.staff_charges_gate(p_org uuid) returns date
language plpgsql stable security definer set search_path = public as $$
declare tz text;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select o.timezone into tz from organisations o where o.id = p_org and o.kind = 'centre';
  if tz is null or not exists (select 1 from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active'
                               and m.role in ('owner', 'staff')) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if not org_can(p_org, 'issue_invoices') then
    raise exception 'NOT_ALLOWED: your account can''t set charges at this centre' using errcode = '42501';
  end if;
  return (now() at time zone tz)::date;
end $$;

-- ---------------------------------------------------------------- the lesson's own price in cents (internal, pure)
-- amount when set, else rate × hours; the same rule as tutor_mark_attendance; never null.
create or replace function public.lesson_price_cents(p_amount numeric, p_rate numeric, p_start time, p_end time) returns bigint
language sql immutable set search_path = public as $$
  select coalesce(round(nullif(p_amount, 0) * 100)::bigint,
                  round(p_rate * extract(epoch from (p_end - p_start)) / 3600 * 100)::bigint, 0)
$$;

-- ---------------------------------------------------------------- the suggestion from billing.absences.mode (internal, pure)
create or replace function public.charge_suggestion_cents(p_mode text, p_attendance text, p_price bigint) returns bigint
language sql immutable set search_path = public as $$
  select case p_mode
           when 'charged'               then p_price
           when 'not_charged'           then 0
           when 'charged_unless_notice' then case when p_attendance = 'cancelled_early' then 0 else p_price end
         end
$$;

-- ---------------------------------------------------------------- how many charges are waiting (for Home, and for T4: "not ready to invoice")
create or replace function public.pending_charge_count(p_org uuid) returns int
language plpgsql stable security definer set search_path = public as $$
declare n int;
begin
  perform staff_charges_gate(p_org);
  select count(*)::int into n from lessons l
   where l.org_id = p_org and l.attendance in ('absent', 'cancelled_early', 'late_cancelled') and l.compensation is null;
  return n;
end $$;

-- ---------------------------------------------------------------- the queue
-- Newest first, 1..100 per page. Staff with issue_invoices see the lesson's price (that is the point); tutors never reach this.
create or replace function public.staff_pending_charges(p_org uuid, p_page int default 1, p_size int default 50) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_charges_gate(p_org); pg int := coalesce(p_page, 1); sz int := coalesce(p_size, 50); total int; rows jsonb;
begin
  if pg < 1 or pg > 100000 then raise exception 'BAD_PAGE: no such page' using errcode = 'P0001'; end if;
  if sz < 1 or sz > 100 then raise exception 'BAD_PAGE: ask for 1 to 100 lessons at a time' using errcode = 'P0001'; end if;

  select count(*)::int into total from lessons l
   where l.org_id = p_org and l.attendance in ('absent', 'cancelled_early', 'late_cancelled') and l.compensation is null;

  select coalesce(jsonb_agg(jsonb_build_object(
           'lesson_id', q.id, 'lesson_date', q.lesson_date, 'start_time', q.start_time, 'end_time', q.end_time,
           'student_id', q.sid, 'student_name', q.sname, 'student_level', q.slevel, 'subject', q.subject,
           'tutor_name', q.tname, 'attendance', q.attendance, 'remarks', q.remarks,
           'marked_by_name', q.mname, 'marked_at', q.attendance_marked_at, 'session_id', q.session_id,
           'price_cents', q.price, 'suggestion_mode', q.mode,
           'suggested_cents', charge_suggestion_cents(q.mode, q.attendance, q.price))
           order by q.lesson_date desc, q.start_time desc, q.sname, q.id), '[]'::jsonb)
    into rows
    from (select l.id, l.lesson_date, l.start_time, l.end_time, l.subject, l.attendance, l.remarks, l.session_id, l.attendance_marked_at,
                 s.id as sid, s.name as sname, s.level as slevel, t.display_name as tname, mb.display_name as mname,
                 lesson_price_cents(l.amount, l.rate, l.start_time, l.end_time) as price,
                 coalesce(org_settings_on(p_org, l.lesson_date) #>> '{billing,absences,mode}',      -- the rule in force that day,
                          org_settings_on(p_org, today) #>> '{billing,absences,mode}') as mode          -- else today's (no version existed yet)
            from lessons l
            join students s on s.id = l.student_id and s.org_id = l.org_id
            left join memberships t  on t.id = l.taught_by and t.org_id = l.org_id
            left join memberships mb on mb.user_id = l.attendance_marked_by and mb.org_id = l.org_id
           where l.org_id = p_org and l.attendance in ('absent', 'cancelled_early', 'late_cancelled') and l.compensation is null
           order by l.lesson_date desc, l.start_time desc, s.name, l.id
           limit sz offset (pg - 1) * sz) q;

  return jsonb_build_object('today', today, 'page', pg, 'size', sz, 'total', total, 'rows', rows);
end $$;

-- ---------------------------------------------------------------- one charge
-- p_amount_cents: whole cents, 0 = the family isn't charged. p_reason: required only when the lesson ALREADY has a charge (a change).
create or replace function public.staff_set_charge(p_lesson uuid, p_amount_cents bigint, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l lessons; price bigint; old_c bigint; why text := nullif(trim(coalesce(p_reason, '')), '');
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into l from lessons where id = p_lesson for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  perform staff_charges_gate(l.org_id);

  if l.attendance is null or l.attendance not in ('absent', 'cancelled_early', 'late_cancelled') then
    raise exception 'NOT_CANCELLED: only a lesson marked absent or cancelled has a charge' using errcode = 'P0001'; end if;
  price := lesson_price_cents(l.amount, l.rate, l.start_time, l.end_time);
  if p_amount_cents is null or p_amount_cents < 0 or p_amount_cents > price then
    raise exception 'BAD_CHARGE: enter an amount from 0 up to the lesson''s own price (S$%)', to_char(price / 100.0, 'FM999999990.00') using errcode = 'P0001'; end if;
  if l.paid then raise exception 'ALREADY_PAID: this lesson is already paid, so its charge can''t be changed' using errcode = 'P0001'; end if;

  old_c := l.compensation_cents;
  if old_c is not null then
    if old_c = p_amount_cents then raise exception 'NO_CHANGE: the charge is already that amount' using errcode = 'P0001'; end if;
    if why is null then raise exception 'REASON_REQUIRED: this lesson already has a charge; say why you are changing it' using errcode = 'P0001'; end if;
  end if;
  if length(coalesce(why, '')) > 500 then raise exception 'TOO_LONG: keep the reason under 500 characters' using errcode = 'P0001'; end if;

  update lessons set compensation = p_amount_cents / 100.0 where id = l.id;

  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (l.org_id, auth.uid(), 'staff_set_charge', 'lessons', l.id::text,
          jsonb_build_object('compensation_cents', old_c, 'attendance', l.attendance),
          jsonb_build_object('compensation_cents', p_amount_cents, 'price_cents', price, 'reason', why));
  return jsonb_build_object('lesson_id', l.id, 'compensation_cents', p_amount_cents, 'price_cents', price);
end $$;

-- ---------------------------------------------------------------- many charges at once (only lessons still waiting for one)
-- p_mode 'amount': the SAME amount for each (p_amount_cents, 0 = not charged; it may not exceed ANY of the lessons' own prices)
-- p_mode 'full'  : each lesson's own price. All or nothing: one problem and nothing is saved.
create or replace function public.staff_set_charges(p_lessons uuid[], p_mode text, p_amount_cents bigint default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ids uuid[]; org uuid; n int; r record; price bigint; amt bigint; done int := 0; total bigint := 0;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_mode is null or p_mode not in ('amount', 'full') then raise exception 'BAD_VALUE: choose a charge' using errcode = 'P0001'; end if;
  select coalesce(array_agg(distinct x), '{}') into ids from unnest(coalesce(p_lessons, '{}')) x where x is not null;
  n := coalesce(array_length(ids, 1), 0);
  if n = 0 then raise exception 'BAD_VALUE: choose at least one lesson' using errcode = 'P0001'; end if;
  if n > 100 then raise exception 'TOO_MANY: choose up to 100 lessons at a time' using errcode = 'P0001'; end if;

  -- every id must exist and all must belong to ONE centre (anything else: the same NOT_FOUND, so ids can't be probed)
  select (array_agg(l.org_id))[1] into org from lessons l where l.id = any(ids);
  if (select count(*) from lessons l where l.id = any(ids)) <> n or (select count(distinct l.org_id) from lessons l where l.id = any(ids)) <> 1 then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  perform staff_charges_gate(org);

  if p_mode = 'amount' and (p_amount_cents is null or p_amount_cents < 0) then
    raise exception 'BAD_CHARGE: enter an amount of 0 or more' using errcode = 'P0001'; end if;

  -- lock them in a fixed order, then check every one before writing any
  for r in select l.* from lessons l where l.id = any(ids) order by l.id for update loop
    if r.attendance is null or r.attendance not in ('absent', 'cancelled_early', 'late_cancelled') then
      raise exception 'NOT_CANCELLED: only a lesson marked absent or cancelled has a charge' using errcode = 'P0001'; end if;
    if r.compensation is not null then
      raise exception 'ALREADY_SET: someone has already set the charge for one of these lessons. Refresh the list and try again' using errcode = 'P0001'; end if;
    if r.paid then raise exception 'ALREADY_PAID: one of these lessons is already paid' using errcode = 'P0001'; end if;
    price := lesson_price_cents(r.amount, r.rate, r.start_time, r.end_time);
    if p_mode = 'amount' and p_amount_cents > price then
      raise exception 'BAD_CHARGE: that amount is more than one of these lessons costs (S$%). Choose "Charge full price" or a smaller amount', to_char(price / 100.0, 'FM999999990.00') using errcode = 'P0001'; end if;
  end loop;

  for r in select l.* from lessons l where l.id = any(ids) order by l.id loop
    price := lesson_price_cents(r.amount, r.rate, r.start_time, r.end_time);
    amt := case p_mode when 'full' then price else p_amount_cents end;
    update lessons set compensation = amt / 100.0 where id = r.id;
    insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
    values (r.org_id, auth.uid(), 'staff_set_charge', 'lessons', r.id::text,
            jsonb_build_object('compensation_cents', null, 'attendance', r.attendance),
            jsonb_build_object('compensation_cents', amt, 'price_cents', price, 'bulk', n, 'mode', p_mode));
    done := done + 1; total := total + amt;
  end loop;
  return jsonb_build_object('updated', done, 'total_cents', total);
end $$;

-- ---------------------------------------------------------------- who may call what
revoke all on function public.staff_pending_charges(uuid, int, int) from public, anon;
revoke all on function public.staff_set_charge(uuid, bigint, text) from public, anon;
revoke all on function public.staff_set_charges(uuid[], text, bigint) from public, anon;
revoke all on function public.pending_charge_count(uuid) from public, anon;
grant execute on function public.staff_pending_charges(uuid, int, int) to authenticated;
grant execute on function public.staff_set_charge(uuid, bigint, text) to authenticated;
grant execute on function public.staff_set_charges(uuid[], text, bigint) to authenticated;
grant execute on function public.pending_charge_count(uuid) to authenticated;
revoke all on function public.staff_charges_gate(uuid) from public, anon, authenticated;
revoke all on function public.lesson_price_cents(numeric, numeric, time, time) from public, anon, authenticated;
revoke all on function public.charge_suggestion_cents(text, text, bigint) from public, anon, authenticated;

-- #####################################################################################################
-- ### PART 9 of 9 — demo staff logins: centre.staff@ and centre.frontdesk@example.test (DEV dummy data, password in the seed: same as db/seed_dev_demo.sql)
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
  ('PART 4 table tutor_payout_details', to_regclass('public.tutor_payout_details') is not null),
  ('PART 4 function tutor_my_payout()', to_regprocedure('public.tutor_my_payout()') is not null),
  ('PART 4 function tutor_save_payout(uuid,text,text,text,text,boolean)', to_regprocedure('public.tutor_save_payout(uuid,text,text,text,text,boolean)') is not null),
  ('PART 4 function tutor_clear_payout(uuid)', to_regprocedure('public.tutor_clear_payout(uuid)') is not null),
  ('PART 4 function tutor_reveal_payout(uuid)', to_regprocedure('public.tutor_reveal_payout(uuid)') is not null),
  ('PART 5 function org_tutor_payouts(uuid)', to_regprocedure('public.org_tutor_payouts(uuid)') is not null),
  ('PART 5 function org_tutor_payout_status(uuid)', to_regprocedure('public.org_tutor_payout_status(uuid)') is not null),
  ('PART 5 function org_reveal_payout(uuid)', to_regprocedure('public.org_reveal_payout(uuid)') is not null),
  ('PART 5 org_invite accepts view_payout_details', position('view_payout_details' in pg_get_functiondef('public.org_invite(uuid,text,text,text,text[],text)'::regprocedure)) > 0),
  ('PART 6 function staff_students(uuid,text,text,int,int)', to_regprocedure('public.staff_students(uuid,text,text,int,int)') is not null),
  ('PART 6 function staff_student(uuid,uuid)', to_regprocedure('public.staff_student(uuid,uuid)') is not null),
  ('PART 6 function staff_save_student(uuid,uuid,text,text,text,uuid,text,jsonb)', to_regprocedure('public.staff_save_student(uuid,uuid,text,text,text,uuid,text,jsonb)') is not null),
  ('PART 6 function staff_set_student_end(uuid,uuid,date)', to_regprocedure('public.staff_set_student_end(uuid,uuid,date)') is not null),
  ('PART 7 trigger lessons_attendance_guard', exists (select 1 from pg_trigger where tgname='lessons_attendance_guard' and not tgisinternal)),
  ('PART 7 function staff_lessons(uuid,date,date,uuid,text,int,int)', to_regprocedure('public.staff_lessons(uuid,date,date,uuid,text,int,int)') is not null),
  ('PART 7 function staff_mark_attendance(uuid,text,text)', to_regprocedure('public.staff_mark_attendance(uuid,text,text)') is not null),
  ('PART 7 function staff_correct_attendance(uuid,text,text)', to_regprocedure('public.staff_correct_attendance(uuid,text,text)') is not null),
  ('PART 8 function staff_pending_charges(uuid,int,int)', to_regprocedure('public.staff_pending_charges(uuid,int,int)') is not null),
  ('PART 8 function staff_set_charge(uuid,bigint,text)', to_regprocedure('public.staff_set_charge(uuid,bigint,text)') is not null),
  ('PART 8 function staff_set_charges(uuid[],text,bigint)', to_regprocedure('public.staff_set_charges(uuid[],text,bigint)') is not null),
  ('PART 8 function pending_charge_count(uuid)', to_regprocedure('public.pending_charge_count(uuid)') is not null),
  ('PART 9 login centre.staff@example.test + membership',     exists (select 1 from auth.users u join public.memberships m on m.user_id=u.id and m.role='staff' where u.email='centre.staff@example.test')),
  ('PART 9 login centre.frontdesk@example.test + membership', exists (select 1 from auth.users u join public.memberships m on m.user_id=u.id and m.role='staff' where u.email='centre.frontdesk@example.test'))
) as x(item, ok)
union all select 'POST-CHECK', 'OVERALL', 'every line above should say present';
