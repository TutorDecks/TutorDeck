-- =====================================================================================================
-- Phase 1 — organisations (multi-tenant foundation)                       undo: migration_org_foundation_down.sql
-- =====================================================================================================
-- EXPAND step: adds tables, columns, functions and policies; no existing column or data is changed or removed,
-- so today's pages keep working unchanged:
--   * every business table gets org_id; a trigger fills it in on insert from the user's own organisation,
--     so pages that don't send org_id yet still work
--   * every existing tutor becomes an organisation of one ("Solo tutor" preset, no wizard)
--   * households are created from today's same-parent-phone grouping
--   * two existing things are CHANGED (the undo script restores both): the old tutor_id policies now apply
--     only inside solo organisations (same result for solo tutors), and handle_new_user() also creates the
--     new user's solo organisation
-- Spreadsheet mapping: organisations = the workbook; memberships = the staff list; org_settings = a
-- "Settings" sheet you never overwrite (each change is a new dated row); households = household-id sheet.
-- Run on the DEV project first. Safe to run twice.
-- =====================================================================================================

-- ---------------------------------------------------------------- organisations & people
create table if not exists public.organisations (
  id            uuid primary key default gen_random_uuid(),
  kind          text not null check (kind in ('solo','centre')),
  preset        text not null default 'centre' check (preset in ('solo','centre')),
  status        text not null default 'setup' check (status in ('setup','active','suspended')),
  setup_step    int  not null default 1,
  legal_name    text,
  trading_name  text not null check (length(trim(trading_name)) between 1 and 120),
  uen           text,
  address       text,
  logo_path     text,
  brand_color   text check (brand_color is null or brand_color ~ '^#[0-9A-Fa-f]{6}$'),
  timezone      text not null default 'Asia/Singapore',
  currency      text not null default 'SGD' check (currency = 'SGD'),
  reply_to_email text,
  created_by    uuid references auth.users(id) on delete set null,
  created_at    timestamptz not null default now()
);

create table if not exists public.memberships (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.organisations(id) on delete cascade,
  user_id        uuid references auth.users(id) on delete cascade,     -- null while an invite is pending
  invited_email  text,
  display_name   text not null,
  role           text not null check (role in ('owner','staff','tutor','parent')),
  permissions    text[] not null default '{}',                         -- staff only, see org_can()
  employment_type text check (employment_type in ('employee','freelancer')),
  status         text not null default 'active' check (status in ('invited','active','disabled')),
  created_at     timestamptz not null default now(),
  check (user_id is not null or invited_email is not null)
);
create unique index if not exists memberships_org_user on public.memberships(org_id, user_id) where user_id is not null;
create index if not exists memberships_user on public.memberships(user_id);

create table if not exists public.platform_admins (user_id uuid primary key references auth.users(id) on delete cascade);

create table if not exists public.support_access_grants (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organisations(id) on delete cascade,
  granted_by uuid not null references auth.users(id),
  reason     text,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------- settings (typed, versioned, never edited)
create table if not exists public.org_settings (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.organisations(id) on delete cascade,
  version        int  not null,
  schema_version int  not null,
  effective_from date not null,
  settings       jsonb not null,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  unique (org_id, version)
);

-- ---------------------------------------------------------------- TutorDeck's own plan per organisation
create table if not exists public.org_plans (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organisations(id) on delete cascade,
  plan_code         text not null check (plan_code in ('centre','solo')),
  base_cents        int  not null check (base_cents >= 0),
  per_student_cents int  not null check (per_student_cents >= 0),
  effective_from    date not null,
  created_at        timestamptz not null default now()
);
create table if not exists public.platform_fee_snapshots (
  org_id            uuid not null references public.organisations(id) on delete cascade,
  month             date not null check (extract(day from month) = 1),     -- the month being billed
  active_students   int  not null,                                         -- counted in the previous month
  billable_students int  not null,
  base_cents        int  not null,
  per_student_cents int  not null,
  fee_cents         int  not null,
  computed_at       timestamptz not null default now(),
  primary key (org_id, month)
);

-- ---------------------------------------------------------------- places & calendar
create table if not exists public.branches (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organisations(id) on delete cascade,
  name text not null, address text, created_at timestamptz not null default now(),
  unique (id, org_id)
);
create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organisations(id) on delete cascade,
  branch_id uuid not null,
  name text not null, capacity int check (capacity is null or capacity > 0),
  foreign key (branch_id, org_id) references public.branches(id, org_id) on delete cascade
);
create table if not exists public.terms (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organisations(id) on delete cascade,
  name text not null, starts_on date not null, ends_on date not null, check (ends_on >= starts_on)
);
create table if not exists public.holidays (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organisations(id) on delete cascade,
  branch_id uuid,                                   -- null = whole centre
  name text not null, starts_on date not null, ends_on date not null, check (ends_on >= starts_on),
  foreign key (branch_id, org_id) references public.branches(id, org_id) on delete cascade
);

-- ---------------------------------------------------------------- families
create table if not exists public.households (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organisations(id) on delete cascade,
  name text not null,
  phone_key text,                                   -- normalised phone used for the original grouping
  created_at timestamptz not null default now(),
  unique (id, org_id)
);
create index if not exists households_org_phone on public.households(org_id, phone_key);
create table if not exists public.guardians (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organisations(id) on delete cascade,
  household_id uuid not null,
  name text, relation text, phone text, email text,
  user_id uuid references auth.users(id) on delete set null,     -- parent portal (phase 5)
  created_at timestamptz not null default now(),
  foreign key (household_id, org_id) references public.households(id, org_id) on delete cascade
);

-- ---------------------------------------------------------------- audit log (append-only)
create table if not exists public.audit_log (
  id         bigint generated always as identity primary key,
  org_id     uuid,
  actor      uuid,
  action     text not null,
  table_name text,
  row_id     text,
  before     jsonb,
  after      jsonb,
  at         timestamptz not null default now()
);
create index if not exists audit_log_org_at on public.audit_log(org_id, at desc);

-- ---------------------------------------------------------------- org_id on existing business tables
alter table public.students        add column if not exists org_id uuid references public.organisations(id) on delete cascade;
alter table public.students        add column if not exists household_id uuid;
alter table public.recurring_slots add column if not exists org_id uuid references public.organisations(id) on delete cascade;
alter table public.lessons         add column if not exists org_id uuid references public.organisations(id) on delete cascade;
alter table public.exams           add column if not exists org_id uuid references public.organisations(id) on delete cascade;
alter table public.invoices        add column if not exists org_id uuid references public.organisations(id) on delete cascade;
alter table public.materials       add column if not exists org_id uuid references public.organisations(id) on delete cascade;

-- exact cents alongside today's dollar columns (generated, so they can never disagree)
alter table public.lessons         add column if not exists rate_cents bigint generated always as (round(rate * 100)::bigint) stored;
alter table public.lessons         add column if not exists amount_cents bigint generated always as (round(amount * 100)::bigint) stored;
alter table public.lessons         add column if not exists compensation_cents bigint generated always as (round(compensation * 100)::bigint) stored;
alter table public.recurring_slots add column if not exists rate_cents bigint generated always as (round(rate * 100)::bigint) stored;
alter table public.invoices        add column if not exists total_cents bigint generated always as (round(total * 100)::bigint) stored;

-- rows may only point at rows in the SAME organisation
create unique index if not exists students_id_org on public.students(id, org_id);
create unique index if not exists slots_id_org on public.recurring_slots(id, org_id);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'students_household_same_org') then
    alter table public.students add constraint students_household_same_org
      foreign key (household_id, org_id) references public.households(id, org_id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'lessons_student_same_org') then
    alter table public.lessons add constraint lessons_student_same_org foreign key (student_id, org_id) references public.students(id, org_id);
    alter table public.lessons add constraint lessons_slot_same_org foreign key (slot_id, org_id) references public.recurring_slots(id, org_id);
    alter table public.recurring_slots add constraint slots_student_same_org foreign key (student_id, org_id) references public.students(id, org_id);
    alter table public.exams add constraint exams_student_same_org foreign key (student_id, org_id) references public.students(id, org_id);
    alter table public.invoices add constraint invoices_student_same_org foreign key (student_id, org_id) references public.students(id, org_id);
  end if;
end $$;
create index if not exists students_org on public.students(org_id);
create index if not exists slots_org on public.recurring_slots(org_id);
create index if not exists lessons_org_date on public.lessons(org_id, lesson_date);
create index if not exists exams_org on public.exams(org_id);
create index if not exists invoices_org on public.invoices(org_id, issued_date desc);
create index if not exists materials_org on public.materials(org_id);

-- =====================================================================================================
-- Access helpers
-- =====================================================================================================
-- Staff permission catalogue (keep in sync with OrgSettings.STAFF_PERMISSIONS in assets/js/org-settings.js):
--   manage_timetable manage_students manage_tutors issue_invoices record_payments view_revenue run_tutor_pay view_audit_log
-- Owners can do everything, including settings, billing and users.

create or replace function public.org_role(p_org uuid) returns text
language sql stable security definer set search_path = public as $$
  select m.role from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active' limit 1
$$;

create or replace function public.org_is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from platform_admins where user_id = auth.uid())
$$;

-- Can this user do p_perm in p_org?  ('owner' = owner-only actions such as settings and users)
create or replace function public.org_can(p_org uuid, p_perm text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active'
                   and (m.role = 'owner' or (m.role = 'staff' and p_perm <> 'owner' and p_perm = any(m.permissions))))
$$;

-- Read business data: owners and staff; platform admins only with a live support grant from the owner.
create or replace function public.org_can_read(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active'
                   and m.role in ('owner','staff'))
      or (org_is_platform_admin() and exists (select 1 from support_access_grants g where g.org_id = p_org
                   and g.revoked_at is null and g.expires_at > now()))
$$;

create or replace function public.org_is_member(p_org uuid, p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from memberships m where m.org_id = p_org and m.user_id = p_user and m.status = 'active')
$$;

-- A user's own solo organisation (where today's pages put new rows).
create or replace function public.org_personal(p_user uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select o.id from organisations o join memberships m on m.org_id = o.id
  where o.kind = 'solo' and m.user_id = p_user and m.role = 'owner' order by o.created_at limit 1
$$;

-- =====================================================================================================
-- Row guard on business tables: fills org_id, keeps it fixed, and keeps rows inside one organisation
-- =====================================================================================================
create or replace function public.org_row_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare owner_col text := tg_argv[0]; owner_id uuid; me uuid := auth.uid();
begin
  owner_id := nullif(to_jsonb(new)->>owner_col, '')::uuid;
  if new.org_id is null then
    new.org_id := org_personal(coalesce(me, owner_id));
    if new.org_id is null then raise exception 'No organisation for this user'; end if;
  end if;
  if tg_op = 'UPDATE' and old.org_id is not null and new.org_id is distinct from old.org_id then
    raise exception 'A row can''t move to another organisation';
  end if;
  -- the person the row belongs to (tutor_id / owner_id) must be in the same organisation
  if owner_id is not null and not org_is_member(new.org_id, owner_id) then
    raise exception 'That user is not in this organisation' using errcode = '42501';
  end if;
  -- someone signed in can only write into an organisation they belong to
  if me is not null and not org_is_member(new.org_id, me) then
    raise exception 'You are not in this organisation' using errcode = '42501';
  end if;
  return new;
end $$;

do $$
declare t text; c text;
begin
  for t, c in select * from (values ('students','tutor_id'), ('recurring_slots','tutor_id'), ('lessons','tutor_id'),
                                     ('exams','tutor_id'), ('invoices','tutor_id'), ('materials','owner_id')) v(t, c) loop
    execute format('drop trigger if exists org_row_guard on public.%I', t);
    execute format('create trigger org_row_guard before insert or update on public.%I for each row execute function public.org_row_guard(%L)', t, c);
  end loop;
end $$;

-- =====================================================================================================
-- Audit log: one generic trigger; the log can't be edited or deleted (not even from the SQL editor)
-- =====================================================================================================
create or replace function public.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare b jsonb; a jsonb; org uuid; rid text; ignore text[] := array['gcal_event_id'];
begin
  if coalesce(current_setting('td.skip_audit', true), '') = '1' then return null; end if;   -- the one-off backfill only
  b := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end;
  a := case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end;
  if tg_op = 'UPDATE' and (b - ignore) = (a - ignore) then return null; end if;   -- e.g. Google Calendar ids only
  if b ? 'data' then b := b #- '{data,html}'; end if;                              -- invoice HTML is large; keep the rest
  if a ? 'data' then a := a #- '{data,html}'; end if;
  org := coalesce((a->>'org_id')::uuid, (b->>'org_id')::uuid, case when tg_table_name = 'organisations' then coalesce((a->>'id')::uuid, (b->>'id')::uuid) end);
  rid := coalesce(a->>'id', b->>'id');
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (org, auth.uid(), lower(tg_op), tg_table_name, rid, b, a);
  return null;
end $$;

create or replace function public.audit_immutable() returns trigger language plpgsql as $$
begin raise exception '% is append-only', tg_table_name; end $$;
drop trigger if exists audit_log_immutable on public.audit_log;
create trigger audit_log_immutable before update or delete on public.audit_log for each row execute function public.audit_immutable();
drop trigger if exists org_settings_immutable on public.org_settings;
create trigger org_settings_immutable before update or delete on public.org_settings for each row execute function public.audit_immutable();
drop trigger if exists fee_snapshots_immutable on public.platform_fee_snapshots;
create trigger fee_snapshots_immutable before update or delete on public.platform_fee_snapshots for each row execute function public.audit_immutable();

do $$
declare t text;
begin
  foreach t in array array['organisations','memberships','org_settings','org_plans','support_access_grants','branches','rooms',
                           'terms','holidays','households','guardians','students','recurring_slots','lessons','invoices'] loop
    execute format('drop trigger if exists audit_row on public.%I', t);
    execute format('create trigger audit_row after insert or update or delete on public.%I for each row execute function public.audit_row()', t);
  end loop;
end $$;

-- =====================================================================================================
-- Settings: validated, versioned, effective-dated
-- =====================================================================================================
-- Structural check only; assets/js/org-settings.js holds the full schema, defaults and labels.
create or replace function public.org_validate_settings(s jsonb) returns void language plpgsql immutable as $$
declare k text;
begin
  if coalesce((s->>'schema_version')::int, 0) <> 1 then raise exception 'Unknown settings schema_version'; end if;
  foreach k in array array['profile','calendar','billing','invoicing','payments','lessons','tutor_pay','data'] loop
    if jsonb_typeof(s->k) is distinct from 'object' then raise exception 'Settings section "%" is missing', k; end if;
  end loop;
  if (s#>>'{profile,gst_registered}')::boolean and not ((s#>>'{profile,gst_rate_bp}')::int between 0 and 5000) then
    raise exception 'GST rate must be between 0%% and 50%%'; end if;
  if s#>>'{billing,model}' not in ('prepaid_packages','fixed_in_advance','postpaid_lessons','pay_per_lesson') then
    raise exception 'Unknown billing model'; end if;
  if s#>>'{tutor_pay,mode}' not in ('off','report','full') then raise exception 'Unknown tutor pay mode'; end if;
  if s#>>'{tutor_pay,payable_when}' not in ('taught','parent_paid') then raise exception 'Unknown payable rule'; end if;
  if s#>>'{invoicing,grouping}' not in ('family','student') then raise exception 'Unknown invoice grouping'; end if;
  if s#>>'{lessons,attendance_by}' not in ('tutor','admin') then raise exception 'Unknown attendance setting'; end if;
  if s#>>'{lessons,cancellations_marked_by}' not in ('admin','tutor') then raise exception 'Unknown cancellation setting'; end if;
  if s#>>'{lessons,compensation_entered_by}' not in ('admin','tutor') then raise exception 'Unknown compensation setting'; end if;
  if s#>>'{lessons,trials_flagged_by}' not in ('admin','tutor') then raise exception 'Unknown trial setting'; end if;
  if s#>>'{lessons,attendance_window_days}' is not null and (s#>>'{lessons,attendance_window_days}' !~ '^[0-9]{1,3}$'
     or (s#>>'{lessons,attendance_window_days}')::int not between 1 and 60) then raise exception 'Attendance window must be 1-60 days'; end if;
  if not (s#>'{payments,modes}' ?| array['manual_paynow','statement_matching','hitpay','stripe']) then
    raise exception 'Pick at least one way for parents to pay'; end if;
end $$;

-- The settings in force for an organisation on a date.
create or replace function public.org_settings_on(p_org uuid, p_day date default current_date) returns jsonb
language sql stable security definer set search_path = public as $$
  select s.settings from org_settings s
  where s.org_id = p_org and s.effective_from <= p_day and (org_can_read(p_org) or org_role(p_org) is not null)
  order by s.effective_from desc, s.version desc limit 1
$$;

-- Save a new settings version (owner only). While the org is still in setup, changes apply at once;
-- after launch they can't be back-dated (the screen picks the start of the next billing cycle).
create or replace function public.org_save_settings(p_org uuid, p_settings jsonb, p_effective_from date) returns int
language plpgsql security definer set search_path = public as $$
declare v int; st text;
begin
  if not org_can(p_org, 'owner') then raise exception 'Only the owner can change settings' using errcode = '42501'; end if;
  perform org_validate_settings(p_settings);
  select status into st from organisations where id = p_org;
  if st <> 'setup' and p_effective_from < current_date then raise exception 'Settings can''t be back-dated'; end if;
  select coalesce(max(version), 0) + 1 into v from org_settings where org_id = p_org;
  insert into org_settings(org_id, version, schema_version, effective_from, settings, created_by)
  values (p_org, v, 1, case when st = 'setup' then least(p_effective_from, current_date) else p_effective_from end, p_settings, auth.uid());
  return v;
end $$;

-- =====================================================================================================
-- Creating organisations
-- =====================================================================================================
-- A new tuition centre: the creator becomes owner; the wizard fills in the rest.
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
  insert into org_plans(org_id, plan_code, base_cents, per_student_cents, effective_from) values (o, 'centre', 10000, 40, current_date);
  return o;
end $$;

-- Solo-tutor settings built from today's profile row (what the existing pages already use).
create or replace function public.org_solo_settings(p profiles) returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'schema_version', 1, 'preset', 'solo',
    'profile',   jsonb_build_object('gst_registered', false, 'gst_rate_bp', 900, 'gst_inclusive', false,
                   'invoice_prefix', coalesce(nullif(p.invoice_prefix, ''), 'INV'), 'fy_start_month', p.fy_start_month),
    'calendar',  jsonb_build_object('terms_enabled', false),
    'billing',   jsonb_build_object('model', 'postpaid_lessons'),
    'invoicing', jsonb_build_object('grouping', 'family', 'review_before_sending', false, 'reminder_message', p.reminder_message, 'invoice_message', p.invoice_message),
    'payments',  jsonb_build_object('modes', jsonb_build_array('manual_paynow'),
                   'paynow', jsonb_build_object('type', p.paynow_type, 'id', p.paynow_id),
                   'bank', jsonb_build_object('account_name', p.bank_account_name, 'bank_name', p.bank_name, 'account_no', p.bank_account_no, 'swift', p.bank_swift)),
    'lessons',   jsonb_build_object('timetable_editing', 'admin_only', 'attendance_by', 'admin'),
    'tutor_pay', jsonb_build_object('mode', 'off', 'payable_when', 'parent_paid'),
    'data',      jsonb_build_object())
$$;

-- Give one existing user their solo organisation and move their rows into it. Idempotent.
create or replace function public.org_make_solo(p_user uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare o uuid; p profiles; nm text; em text;
begin
  o := org_personal(p_user);
  if o is null then
    select * into p from profiles where id = p_user;
    select email into em from auth.users where id = p_user;
    nm := coalesce(nullif(trim(p.business_name), ''), nullif(trim(p.full_name), ''), split_part(em, '@', 1), 'My tuition');
    insert into organisations(kind, preset, status, setup_step, trading_name, created_by, created_at)
    values ('solo', 'solo', 'active', 10, left(nm, 120), p_user, coalesce(p.created_at, now())) returning id into o;
    insert into memberships(org_id, user_id, display_name, role)
    values (o, p_user, coalesce(nullif(trim(p.full_name), ''), split_part(em, '@', 1), 'Tutor'), 'owner');
    insert into org_settings(org_id, version, schema_version, effective_from, settings, created_by)
    values (o, 1, 1, coalesce(p.created_at, now())::date, org_solo_settings(p), p_user);
    insert into org_plans(org_id, plan_code, base_cents, per_student_cents, effective_from)
    values (o, 'solo', 0, 0, current_date);           -- solo price to be decided; stored the same way
  end if;
  -- move this tutor's rows in (only rows with no organisation yet)
  update students set org_id = o where tutor_id = p_user and org_id is null;
  update recurring_slots set org_id = o where tutor_id = p_user and org_id is null;
  update lessons set org_id = o where tutor_id = p_user and org_id is null;
  update exams set org_id = o where tutor_id = p_user and org_id is null;
  update invoices set org_id = o where tutor_id = p_user and org_id is null;
  update materials set org_id = o where owner_id = p_user and org_id is null;
  perform org_make_households(o);
  return o;
end $$;

-- Households from today's grouping: same parent phone (digits only, leading 65 dropped from 10 digits).
-- Students without a phone each get their own household. Only fills students with no household yet.
create or replace function public.org_phone_key(c text) returns text language sql immutable as $$
  select nullif(case when length(d) = 10 and left(d, 2) = '65' then substr(d, 3) else d end, '')
  from (select regexp_replace(coalesce(c, ''), '\D', '', 'g') d) x
$$;
create or replace function public.org_make_households(p_org uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s record; h uuid;
begin
  for s in select * from students where org_id = p_org and household_id is null order by created_at, id loop
    h := null;
    if org_phone_key(s.contact) is not null then
      select id into h from households where org_id = p_org and phone_key = org_phone_key(s.contact) limit 1;
    end if;
    if h is null then
      insert into households(org_id, name, phone_key)
      values (p_org, coalesce(nullif(trim(s.recipient_name), ''), s.name || '''s family'), org_phone_key(s.contact)) returning id into h;
      if org_phone_key(s.contact) is not null or nullif(trim(s.recipient_name), '') is not null then
        insert into guardians(org_id, household_id, name, phone) values (p_org, h, nullif(trim(s.recipient_name), ''), nullif(trim(s.contact), ''));
      end if;
    end if;
    update students set household_id = h where id = s.id;
  end loop;
end $$;

-- New sign-ups: same as before, plus their solo organisation.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name) values (new.id, new.raw_user_meta_data->>'full_name');
  perform public.org_make_solo(new.id);
  return new;
end; $$;

-- New students from today's pages land in a household automatically (same phone rule).
create or replace function public.students_household_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.household_id is null then perform org_make_households(new.org_id); end if;
  return null;
end $$;
drop trigger if exists students_household_after on public.students;
create trigger students_household_after after insert on public.students for each row execute function public.students_household_after();

-- Invites: a confirmed email claims its pending membership on sign-in.
create or replace function public.org_claim_invites() returns int
language plpgsql security definer set search_path = public as $$
declare n int; em text;
begin
  select lower(u.email) into em from auth.users u where u.id = auth.uid() and u.email_confirmed_at is not null;
  if em is null then return 0; end if;
  update memberships m set user_id = auth.uid(), status = 'active'
   where m.user_id is null and m.status = 'invited' and lower(m.invited_email) = em
     and not exists (select 1 from memberships x where x.org_id = m.org_id and x.user_id = auth.uid());
  get diagnostics n = row_count;
  return n;
end $$;

-- Owner adds staff / tutors (invite by email). Staff permissions must come from the catalogue.
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

-- Platform admins: organisations, plan and fee only — never student records.
create or replace function public.platform_orgs() returns table(org_id uuid, trading_name text, kind text, status text, plan_code text,
  base_cents int, per_student_cents int, last_month date, active_students int, billable_students int, fee_cents int)
language sql stable security definer set search_path = public as $$
  select o.id, o.trading_name, o.kind, o.status, p.plan_code, p.base_cents, p.per_student_cents,
         s.month, s.active_students, s.billable_students, s.fee_cents
  from organisations o
  left join lateral (select * from org_plans x where x.org_id = o.id and x.effective_from <= current_date order by x.effective_from desc limit 1) p on true
  left join lateral (select * from platform_fee_snapshots y where y.org_id = o.id order by y.month desc limit 1) s on true
  where org_is_platform_admin()
  order by o.created_at
$$;

-- =====================================================================================================
-- Row-level security
-- =====================================================================================================
alter table public.organisations enable row level security;
alter table public.memberships enable row level security;
alter table public.platform_admins enable row level security;
alter table public.support_access_grants enable row level security;
alter table public.org_settings enable row level security;
alter table public.org_plans enable row level security;
alter table public.platform_fee_snapshots enable row level security;
alter table public.branches enable row level security;
alter table public.rooms enable row level security;
alter table public.terms enable row level security;
alter table public.holidays enable row level security;
alter table public.households enable row level security;
alter table public.guardians enable row level security;
alter table public.audit_log enable row level security;

drop policy if exists org_read on public.organisations;
create policy org_read on public.organisations for select using (org_role(id) is not null or org_can_read(id));
drop policy if exists org_owner_update on public.organisations;
create policy org_owner_update on public.organisations for update using (org_can(id, 'owner')) with check (org_can(id, 'owner'));

drop policy if exists members_read on public.memberships;
create policy members_read on public.memberships for select using (user_id = auth.uid() or org_can_read(org_id));

drop policy if exists platform_admins_self on public.platform_admins;
create policy platform_admins_self on public.platform_admins for select using (user_id = auth.uid());

drop policy if exists grants_owner on public.support_access_grants;
create policy grants_owner on public.support_access_grants for all using (org_can(org_id, 'owner'))
  with check (org_can(org_id, 'owner') and granted_by = auth.uid());
drop policy if exists grants_platform_read on public.support_access_grants;
create policy grants_platform_read on public.support_access_grants for select using (org_is_platform_admin());

drop policy if exists settings_read on public.org_settings;
create policy settings_read on public.org_settings for select using (org_can_read(org_id));

drop policy if exists plans_read on public.org_plans;
create policy plans_read on public.org_plans for select using (org_can(org_id, 'owner') or org_is_platform_admin());
drop policy if exists snapshots_read on public.platform_fee_snapshots;
create policy snapshots_read on public.platform_fee_snapshots for select using (org_can(org_id, 'owner') or org_is_platform_admin());

drop policy if exists audit_read on public.audit_log;
create policy audit_read on public.audit_log for select using (org_can(org_id, 'view_audit_log'));

-- calendar & places: members read; owner or timetable staff write
do $$
declare t text;
begin
  foreach t in array array['branches','rooms','terms','holidays'] loop
    execute format('drop policy if exists %1$s_read on public.%1$I', t);
    execute format('create policy %1$s_read on public.%1$I for select using (org_role(org_id) is not null or org_can_read(org_id))', t);
    execute format('drop policy if exists %1$s_write on public.%1$I', t);
    execute format('create policy %1$s_write on public.%1$I for all using (org_can(org_id, ''manage_timetable'')) with check (org_can(org_id, ''manage_timetable''))', t);
  end loop;
  foreach t in array array['households','guardians'] loop
    execute format('drop policy if exists %1$s_read on public.%1$I', t);
    execute format('create policy %1$s_read on public.%1$I for select using (org_can_read(org_id))', t);
    execute format('drop policy if exists %1$s_write on public.%1$I', t);
    execute format('create policy %1$s_write on public.%1$I for all using (org_can(org_id, ''manage_students'')) with check (org_can(org_id, ''manage_students''))', t);
  end loop;
end $$;

-- existing business tables: org policies ADDED next to the old tutor_id ones
do $$
declare t text; p text;
begin
  for t, p in select * from (values ('students','manage_students'), ('exams','manage_students'), ('recurring_slots','manage_timetable'),
                                     ('lessons','manage_timetable'), ('invoices','issue_invoices'), ('materials','manage_students')) v(t, p) loop
    execute format('drop policy if exists org_read on public.%I', t);
    execute format('create policy org_read on public.%I for select using (org_can_read(org_id))', t);
    execute format('drop policy if exists org_write on public.%I', t);
    execute format('create policy org_write on public.%I for all using (org_can(org_id, %L)) with check (org_can(org_id, %L))', t, p, p);
  end loop;
end $$;

-- The old tutor_id policies now apply only to SOLO organisations (and to rows not yet in one), so in a
-- centre only the org policies (staff permissions) decide. For solo tutors nothing changes.
create or replace function public.org_is_solo(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_org is null or exists (select 1 from organisations where id = p_org and kind = 'solo')
$$;
drop policy if exists "tutor rw students" on public.students;
create policy "tutor rw students" on public.students for all using (tutor_id = auth.uid() and org_is_solo(org_id)) with check (tutor_id = auth.uid() and org_is_solo(org_id));
drop policy if exists "tutor rw slots" on public.recurring_slots;
create policy "tutor rw slots" on public.recurring_slots for all using (tutor_id = auth.uid() and org_is_solo(org_id)) with check (tutor_id = auth.uid() and org_is_solo(org_id));
drop policy if exists "tutor rw lessons" on public.lessons;
create policy "tutor rw lessons" on public.lessons for all using (tutor_id = auth.uid() and org_is_solo(org_id)) with check (tutor_id = auth.uid() and org_is_solo(org_id));
drop policy if exists "tutor rw exams" on public.exams;
create policy "tutor rw exams" on public.exams for all using (tutor_id = auth.uid() and org_is_solo(org_id)) with check (tutor_id = auth.uid() and org_is_solo(org_id));
drop policy if exists "own invoices" on public.invoices;
create policy "own invoices" on public.invoices for all using (tutor_id = auth.uid() and org_is_solo(org_id)) with check (tutor_id = auth.uid() and org_is_solo(org_id));
drop policy if exists "materials owner all" on public.materials;
create policy "materials owner all" on public.materials for all using (owner_id = auth.uid() and org_is_solo(org_id)) with check (owner_id = auth.uid() and org_is_solo(org_id));

-- functions: signed-in users only (each checks its own permission); internal ones not callable from the browser
do $$
declare f text;
begin
  foreach f in array array['org_save_settings(uuid,jsonb,date)','org_create_centre(text,jsonb)','org_claim_invites()',
    'org_invite(uuid,text,text,text,text[],text)','org_update_member(uuid,text,text[],text)','platform_orgs()','org_settings_on(uuid,date)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['org_make_solo(uuid)','org_make_households(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;

-- =====================================================================================================
-- Backfill: every existing user becomes an organisation of one (rows, households, settings from profile)
-- =====================================================================================================
do $$
declare u uuid;
begin
  perform set_config('td.skip_audit', '1', true);      -- don't log a row per migrated lesson
  for u in select id from auth.users order by created_at loop
    perform public.org_make_solo(u);
  end loop;
  perform set_config('td.skip_audit', '', true);
  insert into public.audit_log(action, table_name, after)
  select 'migrate', 'organisations', jsonb_build_object('note', 'Phase 1: existing users moved into solo organisations',
          'organisations', (select count(*) from public.organisations))
  where not exists (select 1 from public.audit_log where action = 'migrate');
end $$;

-- Sanity: nothing left without an organisation.
do $$
declare n int;
begin
  select (select count(*) from students where org_id is null) + (select count(*) from recurring_slots where org_id is null)
       + (select count(*) from lessons where org_id is null) + (select count(*) from exams where org_id is null)
       + (select count(*) from invoices where org_id is null) + (select count(*) from materials where org_id is null)
       + (select count(*) from students where household_id is null) into n;
  if n > 0 then raise exception 'Backfill left % rows without an organisation/household', n; end if;
end $$;
