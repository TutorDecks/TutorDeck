-- =====================================================================================================
-- TutorDeck for centres (multi-tenant) — v1 schema
-- =====================================================================================================
-- ADDITIVE ONLY: creates new tables/functions; does not touch students / lessons / invoices / profiles,
-- so solo tutors' pages keep working exactly as before. Safe to run more than once.
--
-- Run in the Supabase SQL editor (DEV project first) BEFORE merging the code that uses it.
--
-- Spreadsheet mapping (for the Google-Sheets brain):
--   centres              = one tuition business (the whole workbook)
--   centre_members       = staff list; each has a role (centre_roles = the permission matrix)
--   households           = "household id" sheet: who gets the invoice
--   centre_students      = student sheet (household, level, custom fields)
--   centre_classes       = a recurring class (1-to-1 or group) with its fee
--   centre_lessons       = lesson master; centre_lesson_attendees = one row per student in that lesson
--   billing_policies     = the billing rules (prepay / postpay / hybrid + all knobs), as data
--   centre_charges       = invoice lines (lesson, package, deposit, late fee, discount, credit)
--   centre_invoices      = invoice generator output
--   centre_payments      = money in; centre_allocations = which lines each payment paid (oldest first)
--   centre_packages      = prepaid lesson balances; centre_package_draws = lessons taken from them
--   tutor_pay_rules      = tutor pay rates (any basis), most specific rule wins
--   centre_earnings      = what each tutor earned per lesson+student, with its status
--   centre_payout_batches= a pay run; only "payable" earnings can join
--   centre_audit_log     = append-only; every override / sensitive change lands here
--
-- THE PAYOUT RULE (default, enforced by triggers, not just by the UI):
--   an earning becomes "payable" only when the charge it belongs to is covered by RECONCILED payments
--   (walking the charge's lessons in date order, so partial payments release the oldest lessons first).
--   Changing the rule or forcing one earning needs td_set_payout_rule / td_override_earning, which write
--   an audit row; the triggers refuse anything else, even from the SQL editor or the service role.
-- =====================================================================================================

-- ---------- tenancy ----------
create table if not exists public.centres (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (length(trim(name)) between 1 and 80),
  created_by    uuid references auth.users(id) on delete set null,
  created_at    timestamptz not null default now(),
  settings      jsonb not null default '{}'::jsonb,          -- branding, invoice template, contact, PayNow/bank
  gst_registered boolean not null default false,
  gst_rate      numeric(5,2) not null default 9 check (gst_rate >= 0 and gst_rate < 100),
  gst_inclusive boolean not null default false,              -- true = listed prices already include GST
  gst_reg_no    text,
  invoice_prefix text not null default 'INV',
  invoice_seq   integer not null default 0,
  payout_rule   text not null default 'paid_reconciled' check (payout_rule in ('paid_reconciled','on_delivery')),
  stripe_account_id text                                     -- Stripe Connect (later)
);

create table if not exists public.centre_roles (
  id          uuid primary key default gen_random_uuid(),
  centre_id   uuid not null references public.centres(id) on delete cascade,
  key         text not null check (key ~ '^[a-z][a-z0-9_]{0,30}$'),
  name        text not null,
  permissions text[] not null default '{}',
  is_system   boolean not null default false,
  sort        int not null default 100,
  unique (centre_id, key)
);

create table if not exists public.centre_members (
  id          uuid primary key default gen_random_uuid(),
  centre_id   uuid not null references public.centres(id) on delete cascade,
  user_id     uuid references auth.users(id) on delete set null,   -- null until the invite is accepted
  email       text,
  display_name text not null,
  role_id     uuid not null references public.centre_roles(id),
  active      boolean not null default true,
  custom      jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create unique index if not exists centre_members_user on public.centre_members(centre_id, user_id) where user_id is not null;

-- Custom fields each centre collects (student / guardian / household / class / tutor)
create table if not exists public.centre_fields (
  id        uuid primary key default gen_random_uuid(),
  centre_id uuid not null references public.centres(id) on delete cascade,
  entity    text not null check (entity in ('student','guardian','household','class','tutor')),
  key       text not null check (key ~ '^[a-z][a-z0-9_]{0,40}$'),
  label     text not null,
  type      text not null default 'text' check (type in ('text','number','date','select','checkbox','phone','email')),
  options   text[] not null default '{}',
  required  boolean not null default false,
  sort      int not null default 100,
  active    boolean not null default true,
  unique (centre_id, entity, key)
);

-- ---------- audit log (append-only) ----------
create table if not exists public.centre_audit_log (
  id          bigserial primary key,
  centre_id   uuid not null,
  actor       uuid,
  action      text not null,
  target_type text,
  target_id   uuid,
  reason      text,
  details     jsonb not null default '{}'::jsonb,
  at          timestamptz not null default now()
);
create index if not exists centre_audit_centre on public.centre_audit_log(centre_id, at desc);

-- ---------- rules as data ----------
create table if not exists public.billing_policies (
  id         uuid primary key default gen_random_uuid(),
  centre_id  uuid not null references public.centres(id) on delete cascade,
  name       text not null,
  model      text not null check (model in ('prepay','postpay','hybrid')),
  config     jsonb not null default '{}'::jsonb,   -- see BillingCore.DEFAULT_POLICY for every key
  is_default boolean not null default false,
  archived   boolean not null default false,
  created_at timestamptz not null default now()
);
create unique index if not exists billing_policies_one_default on public.billing_policies(centre_id) where is_default and not archived;

create table if not exists public.centre_price_list (
  id        uuid primary key default gen_random_uuid(),
  centre_id uuid not null references public.centres(id) on delete cascade,
  subject   text,                 -- null = any subject
  level     text,                 -- null = any level
  kind      text check (kind in ('individual','group')),   -- null = either
  unit      text not null default 'per_hour' check (unit in ('per_hour','per_lesson')),
  amount    numeric(10,2) not null check (amount >= 0)
);

create table if not exists public.tutor_pay_rules (
  id        uuid primary key default gen_random_uuid(),
  centre_id uuid not null references public.centres(id) on delete cascade,
  tutor_member_id uuid references public.centre_members(id) on delete cascade,  -- null = every tutor
  class_id  uuid,                                                               -- null = every class
  subject   text,
  level     text,
  basis     text not null check (basis in ('per_hour','per_lesson','per_student','per_student_hour','percent_of_fee')),
  rate      numeric(10,2) not null check (rate >= 0),
  min_pay   numeric(10,2),
  max_pay   numeric(10,2),
  created_at timestamptz not null default now()
);

-- ---------- people & classes ----------
create table if not exists public.households (
  id        uuid primary key default gen_random_uuid(),
  centre_id uuid not null references public.centres(id) on delete cascade,
  name      text not null,
  email     text,
  phone     text,
  custom    jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.guardians (
  id           uuid primary key default gen_random_uuid(),
  centre_id    uuid not null references public.centres(id) on delete cascade,
  household_id uuid not null references public.households(id) on delete cascade,
  name         text not null,
  relation     text,
  phone        text,
  email        text,
  user_id      uuid references auth.users(id) on delete set null,   -- parent portal (later)
  custom       jsonb not null default '{}'::jsonb
);

create table if not exists public.centre_students (
  id           uuid primary key default gen_random_uuid(),
  centre_id    uuid not null references public.centres(id) on delete cascade,
  household_id uuid not null references public.households(id) on delete restrict,
  name         text not null,
  level        text,
  status       text not null default 'active' check (status in ('active','paused','left')),
  billing_policy_id uuid references public.billing_policies(id),   -- per-student override
  custom       jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now()
);

create table if not exists public.centre_classes (
  id        uuid primary key default gen_random_uuid(),
  centre_id uuid not null references public.centres(id) on delete cascade,
  name      text not null,
  kind      text not null default 'group' check (kind in ('individual','group')),
  subject   text,
  level     text,
  capacity  int,
  tutor_member_id uuid references public.centre_members(id),
  fee_amount numeric(10,2),                                   -- null = use the price list
  fee_unit   text check (fee_unit in ('per_hour','per_lesson')),
  billing_policy_id uuid references public.billing_policies(id),   -- per-class override
  custom    jsonb not null default '{}'::jsonb,
  active    boolean not null default true
);

create table if not exists public.centre_enrolments (
  id         uuid primary key default gen_random_uuid(),
  centre_id  uuid not null references public.centres(id) on delete cascade,
  class_id   uuid not null references public.centre_classes(id) on delete cascade,
  student_id uuid not null references public.centre_students(id) on delete cascade,
  starts_on  date not null default current_date,
  ends_on    date,
  fee_override numeric(10,2),
  unique (class_id, student_id)
);

create table if not exists public.centre_lessons (
  id         uuid primary key default gen_random_uuid(),
  centre_id  uuid not null references public.centres(id) on delete cascade,
  class_id   uuid not null references public.centre_classes(id) on delete cascade,
  tutor_member_id uuid references public.centre_members(id),
  lesson_date date not null,
  start_time time not null,
  end_time   time not null,
  status     text not null default 'scheduled' check (status in ('scheduled','delivered','cancelled')),
  remarks    text,
  remarks_by uuid,
  remarks_at timestamptz,
  delivered_at timestamptz,
  check (end_time > start_time)
);
create index if not exists centre_lessons_tutor on public.centre_lessons(tutor_member_id, lesson_date);

create table if not exists public.centre_lesson_attendees (
  id         uuid primary key default gen_random_uuid(),
  centre_id  uuid not null references public.centres(id) on delete cascade,
  lesson_id  uuid not null references public.centre_lessons(id) on delete cascade,
  student_id uuid not null references public.centre_students(id) on delete cascade,
  status     text not null default 'present' check (status in ('present','absent','cancelled','late_cancel')),
  makeup_of  uuid references public.centre_lesson_attendees(id),   -- this seat is a make-up for that one
  charge_id  uuid,
  unique (lesson_id, student_id)
);

-- ---------- money ----------
create table if not exists public.centre_invoices (
  id           uuid primary key default gen_random_uuid(),
  centre_id    uuid not null references public.centres(id) on delete cascade,
  household_id uuid not null references public.households(id),
  number       text not null,
  issued_on    date not null default current_date,
  due_on       date not null,
  status       text not null default 'issued' check (status in ('issued','partially_paid','paid','disputed','void')),
  subtotal     numeric(12,2) not null default 0,
  gst          numeric(12,2) not null default 0,
  total        numeric(12,2) not null default 0,
  paid         numeric(12,2) not null default 0,
  template     jsonb not null default '{}'::jsonb,     -- snapshot of the invoice template used
  dispute_reason text,
  stripe_invoice_id text,
  created_at   timestamptz not null default now(),
  unique (centre_id, number)
);

create table if not exists public.centre_charges (
  id           uuid primary key default gen_random_uuid(),
  centre_id    uuid not null references public.centres(id) on delete cascade,
  household_id uuid not null references public.households(id),
  student_id   uuid references public.centre_students(id),
  lesson_id    uuid references public.centre_lessons(id),
  invoice_id   uuid references public.centre_invoices(id),
  kind         text not null check (kind in ('lesson','package','deposit','late_fee','credit','adjustment')),
  description  text not null,
  charge_date  date not null,                       -- lesson date (or purchase/issue date): drives "oldest first"
  amount       numeric(12,2) not null,             -- before GST, after discount
  discount     numeric(12,2) not null default 0,
  gst          numeric(12,2) not null default 0,
  total        numeric(12,2) not null,             -- what the parent owes for this line
  status       text not null default 'open' check (status in ('open','void')),
  policy       jsonb not null default '{}'::jsonb, -- snapshot of the billing policy used
  seq          bigint generated always as identity,  -- stable "oldest first" tie-break
  created_at   timestamptz not null default now()
);
create index if not exists centre_charges_household on public.centre_charges(household_id, charge_date);

create table if not exists public.centre_packages (
  id           uuid primary key default gen_random_uuid(),
  centre_id    uuid not null references public.centres(id) on delete cascade,
  household_id uuid not null references public.households(id),
  student_id   uuid not null references public.centre_students(id),
  charge_id    uuid not null references public.centre_charges(id),
  lessons_total int not null check (lessons_total > 0),
  lessons_used  int not null default 0,
  expires_on   date,
  extended     int not null default 0,
  status       text not null default 'active' check (status in ('active','exhausted','expired','refund_due','credited')),
  created_at   timestamptz not null default now()
);

create table if not exists public.centre_package_draws (
  id          uuid primary key default gen_random_uuid(),
  package_id  uuid not null references public.centre_packages(id),
  attendee_id uuid not null unique references public.centre_lesson_attendees(id)
);

create table if not exists public.centre_payments (
  id           uuid primary key default gen_random_uuid(),
  centre_id    uuid not null references public.centres(id) on delete cascade,
  household_id uuid not null references public.households(id),
  invoice_id   uuid references public.centre_invoices(id),
  method       text not null check (method in ('stripe','paynow','bank','cash','other')),
  amount       numeric(12,2) not null check (amount > 0),
  refunded     numeric(12,2) not null default 0,
  received_on  date not null default current_date,
  reference    text,
  status       text not null default 'recorded' check (status in ('recorded','reconciled','void')),
  recorded_by  uuid,
  reconciled_by uuid,
  reconciled_at timestamptz,
  stripe_payment_intent_id text,
  created_at   timestamptz not null default now()
);

create table if not exists public.centre_allocations (
  id         uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.centre_payments(id),
  charge_id  uuid not null references public.centre_charges(id),
  amount     numeric(12,2) not null,              -- negative rows = refunds taken back
  created_at timestamptz not null default now()
);
create index if not exists centre_alloc_charge on public.centre_allocations(charge_id);

create table if not exists public.centre_payout_batches (
  id         uuid primary key default gen_random_uuid(),
  centre_id  uuid not null references public.centres(id) on delete cascade,
  status     text not null default 'draft' check (status in ('draft','paid','cancelled')),
  up_to      date not null,
  total      numeric(12,2) not null default 0,
  reference  text,
  created_by uuid,
  created_at timestamptz not null default now(),
  paid_at    timestamptz
);

create table if not exists public.centre_earnings (
  id           uuid primary key default gen_random_uuid(),
  centre_id    uuid not null references public.centres(id) on delete cascade,
  tutor_member_id uuid not null references public.centre_members(id),
  kind         text not null default 'lesson' check (kind in ('lesson','adjustment')),
  lesson_id    uuid references public.centre_lessons(id),
  attendee_id  uuid references public.centre_lesson_attendees(id),
  charge_id    uuid references public.centre_charges(id),   -- the parent's charge this pay depends on
  lesson_date  date,
  fee_share    numeric(12,2) not null default 0,             -- how much of that charge this lesson represents
  amount       numeric(12,2) not null,
  status       text not null default 'pending' check (status in ('pending','payable','held','batched','paid','reversed')),
  batch_id     uuid references public.centre_payout_batches(id),
  adjusts_earning_id uuid references public.centre_earnings(id),
  clawed_back  boolean not null default false,
  basis        jsonb not null default '{}'::jsonb,           -- snapshot of the pay rule used
  override_audit_id bigint references public.centre_audit_log(id),
  note         text,
  seq          bigint generated always as identity,
  created_at   timestamptz not null default now(),
  payable_at   timestamptz
);
create index if not exists centre_earnings_charge on public.centre_earnings(charge_id, lesson_date);
create index if not exists centre_earnings_tutor on public.centre_earnings(tutor_member_id, status);

create table if not exists public.stripe_events (           -- webhook idempotency (Stripe phase)
  id          text primary key,
  centre_id   uuid,
  type        text not null,
  received_at timestamptz not null default now()
);

-- =====================================================================================================
-- Permission helpers
-- =====================================================================================================
-- Permission catalogue (keep in sync with BillingCore.PERMISSIONS in assets/js/billing-core.js):
--   students.view students.edit classes.edit schedule.view_all lessons.deliver lessons.remarks
--   billing.view billing.edit payments.record payments.reconcile payouts.view payouts.view_own
--   payouts.manage payouts.override settings.edit roles.manage audit.view

create or replace function public.td_is_service() returns boolean language sql stable as $$
  select coalesce(current_setting('request.jwt.claim.role', true), '') = 'service_role'
      or coalesce((nullif(current_setting('request.jwt.claims', true), '')::jsonb)->>'role', '') = 'service_role'
$$;

create or replace function public.td_my_member(p_centre uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select m.id from centre_members m where m.centre_id = p_centre and m.user_id = auth.uid() and m.active limit 1
$$;

create or replace function public.td_is_member(p_centre uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select td_is_service() or exists (select 1 from centre_members m where m.centre_id = p_centre and m.user_id = auth.uid() and m.active)
$$;

create or replace function public.td_has_perm(p_centre uuid, p_perm text) returns boolean
language sql stable security definer set search_path = public as $$
  select td_is_service() or exists (
    select 1 from centre_members m join centre_roles r on r.id = m.role_id
    where m.centre_id = p_centre and m.user_id = auth.uid() and m.active
      and (r.key = 'owner' or p_perm = any(r.permissions)))
$$;

create or replace function public.td_require(p_centre uuid, p_perm text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not td_has_perm(p_centre, p_perm) then
    raise exception 'Not allowed: % (ask a centre admin)', p_perm using errcode = '42501';
  end if;
end $$;

create or replace function public.td_audit(p_centre uuid, p_action text, p_type text, p_target uuid, p_reason text, p_details jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  insert into centre_audit_log(centre_id, actor, action, target_type, target_id, reason, details)
  values (p_centre, auth.uid(), p_action, p_type, p_target, p_reason, coalesce(p_details, '{}'::jsonb)) returning id into v;
  return v;
end $$;

-- Audit rows can never be edited or deleted (also blocks the service role and the SQL editor).
create or replace function public.td_audit_immutable() returns trigger language plpgsql as $$
begin raise exception 'centre_audit_log is append-only'; end $$;
drop trigger if exists centre_audit_immutable on public.centre_audit_log;
create trigger centre_audit_immutable before update or delete on public.centre_audit_log
  for each row execute function public.td_audit_immutable();

-- =====================================================================================================
-- Centre creation (seeds roles + a default policy)
-- =====================================================================================================
create or replace function public.td_create_centre(p_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare c uuid; owner_role uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  insert into centres(name, created_by) values (trim(p_name), auth.uid()) returning id into c;
  insert into centre_roles(centre_id, key, name, permissions, is_system, sort) values
    (c, 'owner', 'Owner', '{}', true, 0),
    (c, 'admin', 'Centre admin', array['students.view','students.edit','classes.edit','schedule.view_all','lessons.deliver',
       'lessons.remarks','billing.view','billing.edit','payments.record','payments.reconcile','payouts.view','payouts.view_own',
       'payouts.manage','payouts.override','settings.edit','roles.manage','audit.view'], true, 10),
    (c, 'staff', 'Staff', array['students.view','students.edit','classes.edit','schedule.view_all','lessons.deliver',
       'billing.view','payments.record','payouts.view'], true, 20),
    (c, 'tutor', 'Tutor', array['lessons.remarks','payouts.view_own'], true, 30),
    (c, 'parent', 'Parent', '{}', true, 40);
  select id into owner_role from centre_roles where centre_id = c and key = 'owner';
  insert into centre_members(centre_id, user_id, email, display_name, role_id)
  select c, u.id, u.email, coalesce(nullif(p.full_name, ''), split_part(u.email, '@', 1), 'Owner'), owner_role
  from auth.users u left join profiles p on p.id = u.id where u.id = auth.uid();
  insert into billing_policies(centre_id, name, model, config, is_default)
  values (c, 'Monthly, after lessons', 'postpay', '{"cycle":"monthly","due_days":7}'::jsonb, true);
  perform td_audit(c, 'centre.create', 'centre', c, null, jsonb_build_object('name', p_name));
  return c;
end $$;

-- payout_rule / created_by / stripe_account_id can't be changed by a plain UPDATE.
create or replace function public.td_centres_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare a bigint;
begin
  if new.payout_rule is distinct from old.payout_rule then
    a := nullif(current_setting('td.payout_rule_audit', true), '')::bigint;
    if a is null or not exists (select 1 from centre_audit_log l where l.id = a and l.centre_id = new.id
                                 and l.action = 'payout_rule.change' and l.details->>'to' = new.payout_rule) then
      raise exception 'Payout rule can only be changed with td_set_payout_rule (it is audited)';
    end if;
  end if;
  if new.created_by is distinct from old.created_by then raise exception 'created_by is fixed'; end if;
  if new.stripe_account_id is distinct from old.stripe_account_id and not td_is_service() then
    raise exception 'Stripe account is set by the server';
  end if;
  if (new.settings, new.gst_registered, new.gst_rate, new.gst_inclusive, new.gst_reg_no, new.invoice_prefix, new.name)
     is distinct from (old.settings, old.gst_registered, old.gst_rate, old.gst_inclusive, old.gst_reg_no, old.invoice_prefix, old.name) then
    insert into centre_audit_log(centre_id, actor, action, target_type, target_id, details)
    values (new.id, auth.uid(), 'settings.update', 'centre', new.id,
            jsonb_build_object('gst_registered', new.gst_registered, 'gst_rate', new.gst_rate, 'gst_inclusive', new.gst_inclusive));
  end if;
  return new;
end $$;
drop trigger if exists centres_guard on public.centres;
create trigger centres_guard before update on public.centres for each row execute function public.td_centres_guard();

create or replace function public.td_set_payout_rule(p_centre uuid, p_rule text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare a bigint; old_rule text;
begin
  perform td_require(p_centre, 'payouts.override');
  if coalesce(length(trim(p_reason)), 0) < 5 then raise exception 'Give a reason (at least 5 characters)'; end if;
  select payout_rule into old_rule from centres where id = p_centre;
  a := td_audit(p_centre, 'payout_rule.change', 'centre', p_centre, p_reason, jsonb_build_object('from', old_rule, 'to', p_rule));
  perform set_config('td.payout_rule_audit', a::text, true);
  update centres set payout_rule = p_rule where id = p_centre;
  perform set_config('td.payout_rule_audit', '', true);
  perform td_refresh_earnings(p_centre);
end $$;

-- Roles: owner is locked; every change is audited.
create or replace function public.td_save_role(p_centre uuid, p_role uuid, p_key text, p_name text, p_perms text[]) returns uuid
language plpgsql security definer set search_path = public as $$
declare r uuid; k text;
begin
  perform td_require(p_centre, 'roles.manage');
  if p_role is not null then
    select key into k from centre_roles where id = p_role and centre_id = p_centre;
    if k is null then raise exception 'Role not found'; end if;
    if k = 'owner' then raise exception 'The owner role always has every permission'; end if;
    update centre_roles set name = p_name, permissions = coalesce(p_perms, '{}') where id = p_role returning id into r;
  else
    insert into centre_roles(centre_id, key, name, permissions) values (p_centre, p_key, p_name, coalesce(p_perms, '{}')) returning id into r;
  end if;
  perform td_audit(p_centre, 'role.save', 'role', r, null, jsonb_build_object('name', p_name, 'permissions', p_perms));
  return r;
end $$;

create or replace function public.td_set_member_role(p_member uuid, p_role uuid) returns void
language plpgsql security definer set search_path = public as $$
declare c uuid; owners int; was_owner boolean;
begin
  select centre_id into c from centre_members where id = p_member;
  perform td_require(c, 'roles.manage');
  if not exists (select 1 from centre_roles where id = p_role and centre_id = c) then raise exception 'Role not in this centre'; end if;
  select r.key = 'owner' into was_owner from centre_members m join centre_roles r on r.id = m.role_id where m.id = p_member;
  perform set_config('td.role_change', '1', true);
  update centre_members set role_id = p_role where id = p_member;
  perform set_config('td.role_change', '', true);
  select count(*) into owners from centre_members m join centre_roles r on r.id = m.role_id where m.centre_id = c and r.key = 'owner' and m.active;
  if owners = 0 then raise exception 'A centre needs at least one owner'; end if;
  perform td_audit(c, 'member.role', 'member', p_member, null, jsonb_build_object('role', p_role, 'was_owner', was_owner));
end $$;

-- Invites: an admin adds a member with an email; when that person signs in with the SAME, CONFIRMED email,
-- this links the invite to their login. Called by the Centre page on load.
create or replace function public.td_claim_invites() returns int
language plpgsql security definer set search_path = public as $$
declare n int; em text;
begin
  select lower(u.email) into em from auth.users u where u.id = auth.uid() and u.email_confirmed_at is not null;
  if em is null then return 0; end if;
  update centre_members m set user_id = auth.uid()
   where m.user_id is null and m.active and lower(m.email) = em
     and not exists (select 1 from centre_members x where x.centre_id = m.centre_id and x.user_id = auth.uid());
  get diagnostics n = row_count;
  return n;
end $$;

-- =====================================================================================================
-- Pure maths (mirrored in assets/js/billing-core.js; tests check both agree)
-- =====================================================================================================
create or replace function public.td_round(n numeric) returns numeric language sql immutable as $$ select round(n, 2) $$;

-- (net, gst, total) for an amount. Inclusive: amount already contains GST.
create or replace function public.td_gst(p_amount numeric, p_rate numeric, p_inclusive boolean, p_registered boolean,
  out net numeric, out gst numeric, out total numeric) language plpgsql immutable as $$
begin
  if not p_registered or p_rate = 0 then net := td_round(p_amount); gst := 0; total := net; return; end if;
  if p_inclusive then
    total := td_round(p_amount); gst := td_round(p_amount * p_rate / (100 + p_rate)); net := total - gst;
  else
    net := td_round(p_amount); gst := td_round(p_amount * p_rate / 100); total := net + gst;
  end if;
end $$;

-- Tutor pay for one lesson. heads = students who count; fee = their total fee (pre-GST); minutes = lesson length.
create or replace function public.td_pay_amount(p_basis text, p_rate numeric, p_minutes int, p_heads int, p_fee numeric,
  p_min numeric, p_max numeric) returns numeric language plpgsql immutable as $$
declare v numeric;
begin
  v := case p_basis
    when 'per_hour'         then p_rate * p_minutes / 60.0
    when 'per_lesson'       then p_rate
    when 'per_student'      then p_rate * p_heads
    when 'per_student_hour' then p_rate * p_heads * p_minutes / 60.0
    when 'percent_of_fee'   then p_fee * p_rate / 100.0
    else 0 end;
  if p_heads = 0 then v := 0; end if;
  if p_min is not null and v < p_min and p_heads > 0 then v := p_min; end if;
  if p_max is not null and v > p_max then v := p_max; end if;
  return td_round(v);
end $$;

-- =====================================================================================================
-- Rule lookup: most specific wins
-- =====================================================================================================
create or replace function public.td_policy_for(p_student uuid, p_class uuid) returns public.billing_policies
language sql stable security definer set search_path = public as $$
  select bp.* from billing_policies bp
  where bp.id = coalesce(
    (select billing_policy_id from centre_students where id = p_student),
    (select billing_policy_id from centre_classes where id = p_class),
    (select b.id from billing_policies b join centre_students s on s.centre_id = b.centre_id
      where s.id = p_student and b.is_default and not b.archived limit 1))
$$;

create or replace function public.td_pay_rule_for(p_centre uuid, p_tutor uuid, p_class uuid, p_subject text, p_level text)
returns public.tutor_pay_rules language sql stable security definer set search_path = public as $$
  select r.* from tutor_pay_rules r
  where r.centre_id = p_centre
    and (r.tutor_member_id is null or r.tutor_member_id = p_tutor)
    and (r.class_id is null or r.class_id = p_class)
    and (r.subject is null or lower(r.subject) = lower(coalesce(p_subject, '')))
    and (r.level is null or lower(r.level) = lower(coalesce(p_level, '')))
  order by (case when r.tutor_member_id is not null then 8 else 0 end + case when r.class_id is not null then 4 else 0 end
          + case when r.subject is not null then 2 else 0 end + case when r.level is not null then 1 else 0 end) desc,
           r.created_at desc
  limit 1
$$;

-- Fee for one student in one lesson, before discount & GST.
create or replace function public.td_lesson_fee(p_lesson uuid, p_student uuid) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare l centre_lessons; k centre_classes; e centre_enrolments; amt numeric; unit text; mins int;
begin
  select * into l from centre_lessons where id = p_lesson;
  select * into k from centre_classes where id = l.class_id;
  select * into e from centre_enrolments where class_id = k.id and student_id = p_student;
  mins := extract(epoch from (l.end_time - l.start_time)) / 60;
  if e.fee_override is not null then amt := e.fee_override; unit := coalesce(k.fee_unit, 'per_lesson');
  elsif k.fee_amount is not null then amt := k.fee_amount; unit := coalesce(k.fee_unit, 'per_lesson');
  else
    select p.amount, p.unit into amt, unit from centre_price_list p
    where p.centre_id = k.centre_id
      and (p.subject is null or lower(p.subject) = lower(coalesce(k.subject, '')))
      and (p.level is null or lower(p.level) = lower(coalesce(k.level, '')))
      and (p.kind is null or p.kind = k.kind)
    order by (case when p.subject is not null then 4 else 0 end + case when p.level is not null then 2 else 0 end
            + case when p.kind is not null then 1 else 0 end) desc limit 1;
  end if;
  if amt is null then raise exception 'No fee for class "%": set a class fee or a price-list row', k.name; end if;
  return td_round(case when unit = 'per_hour' then amt * mins / 60.0 else amt end);
end $$;

-- Sibling discount for this student (0 if the policy has none or they're the first child).
create or replace function public.td_sibling_discount(p_student uuid, p_fee numeric, p_cfg jsonb) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare d jsonb := p_cfg->'sibling_discount'; rnk int;
begin
  if d is null or coalesce((d->>'value')::numeric, 0) = 0 then return 0; end if;
  select x.r into rnk from (
    select s.id, row_number() over (order by s.created_at, s.id) r from centre_students s
    where s.household_id = (select household_id from centre_students where id = p_student) and s.status = 'active') x
  where x.id = p_student;
  if coalesce(rnk, 1) < 2 then return 0; end if;
  return least(p_fee, td_round(case when d->>'type' = 'fixed' then (d->>'value')::numeric else p_fee * (d->>'value')::numeric / 100 end));
end $$;

-- =====================================================================================================
-- Coverage & the payout rule
-- =====================================================================================================
-- Money from RECONCILED payments sitting on a charge (refunds are negative allocations).
create or replace function public.td_charge_covered(p_charge uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(a.amount), 0) from centre_allocations a join centre_payments p on p.id = a.payment_id
  where a.charge_id = p_charge and p.status = 'reconciled'
$$;

-- Is this lesson earning's slice of its charge paid? Walk the charge's lessons oldest first.
create or replace function public.td_earning_covered(p_earning uuid) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare e centre_earnings; covered numeric; upto numeric; disputed boolean;
begin
  select * into e from centre_earnings where id = p_earning;
  if e.kind = 'adjustment' then return true; end if;
  if e.charge_id is null then return false; end if;
  select coalesce(i.status = 'disputed', false) into disputed
    from centre_charges c left join centre_invoices i on i.id = c.invoice_id where c.id = e.charge_id;
  if disputed then return false; end if;
  covered := td_charge_covered(e.charge_id);
  -- the slices of every other lesson on this charge that come first, plus this one
  select coalesce(sum(fee_share), 0) into upto from centre_earnings
   where charge_id = e.charge_id and kind = 'lesson' and status <> 'reversed'
     and (lesson_date, seq) <= (e.lesson_date, e.seq);
  return upto <= covered + 0.005;
end $$;

-- Guard: an earning can't become payable / batched unless the rules allow it.
create or replace function public.td_earnings_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare rule text; ok boolean;
begin
  if tg_op = 'UPDATE' and old.status = 'paid' and new.status <> 'paid' then
    raise exception 'A paid earning is final; refunds create a negative adjustment instead';
  end if;
  if tg_op = 'UPDATE' and (new.amount, new.charge_id, new.fee_share, new.tutor_member_id) is distinct from
                          (old.amount, old.charge_id, old.fee_share, old.tutor_member_id) and old.status in ('batched','paid') then
    raise exception 'Earnings in a batch can''t be edited';
  end if;
  if new.status = 'batched' and (tg_op = 'INSERT' or old.status not in ('payable','batched')) then
    raise exception 'Only payable earnings can join a payout batch';
  end if;
  if new.status = 'paid' and (tg_op = 'INSERT' or old.status not in ('batched','paid')) then
    raise exception 'Earnings are paid through a payout batch';
  end if;
  if new.status = 'payable' and (tg_op = 'INSERT' or old.status <> 'payable') and new.kind = 'lesson' then
    select payout_rule into rule from centres where id = new.centre_id;
    ok := rule = 'on_delivery' and tg_op = 'UPDATE';
    if not ok and tg_op = 'UPDATE' then ok := td_earning_covered(new.id); end if;
    if not ok and new.override_audit_id is not null then
      ok := exists (select 1 from centre_audit_log l where l.id = new.override_audit_id and l.centre_id = new.centre_id
                     and l.action = 'earning.override' and l.target_id = new.id);
    end if;
    if not ok then raise exception 'Earning % is not covered by a reconciled parent payment', new.id; end if;
    new.payable_at := now();
  end if;
  if new.kind = 'adjustment' and tg_op = 'INSERT' and new.adjusts_earning_id is null and new.override_audit_id is null then
    raise exception 'Manual adjustments must be audited';
  end if;
  return new;
end $$;
drop trigger if exists centre_earnings_guard on public.centre_earnings;
create trigger centre_earnings_guard before insert or update on public.centre_earnings
  for each row execute function public.td_earnings_guard();

-- Re-evaluate every open earning of a centre. Call after any payment / refund / dispute / rule change.
create or replace function public.td_refresh_earnings(p_centre uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e record; rule text; ok boolean; disputed boolean;
begin
  select payout_rule into rule from centres where id = p_centre;
  for e in select x.* from centre_earnings x
           where x.centre_id = p_centre and x.kind = 'lesson' and x.status in ('pending','payable','held','batched','paid')
             and not x.clawed_back
           order by x.lesson_date, x.seq loop
    select coalesce(i.status = 'disputed', false) into disputed
      from centre_charges c left join centre_invoices i on i.id = c.invoice_id where c.id = e.charge_id;
    disputed := coalesce(disputed, false);
    if disputed then
      if e.status in ('pending','payable','batched') then
        update centre_earnings set status = 'held', batch_id = null where id = e.id;
      end if;
      continue;
    end if;
    ok := rule = 'on_delivery' or td_earning_covered(e.id) or e.override_audit_id is not null;
    if ok and e.status in ('pending','held') then
      update centre_earnings set status = 'payable' where id = e.id;
    elsif not ok and e.status in ('payable','held','batched') then
      update centre_earnings set status = 'pending', batch_id = null where id = e.id;
    elsif not ok and e.status = 'paid' then
      -- refunded after the tutor was paid: carry a deduction into the next batch
      insert into centre_earnings(centre_id, tutor_member_id, kind, lesson_id, charge_id, lesson_date, amount, status, adjusts_earning_id, note)
      values (e.centre_id, e.tutor_member_id, 'adjustment', e.lesson_id, e.charge_id, current_date, -e.amount, 'payable', e.id,
              'Parent payment refunded after payout');
      update centre_earnings set clawed_back = true where id = e.id;
    end if;
  end loop;
  update centre_payout_batches b set total = coalesce((select sum(amount) from centre_earnings where batch_id = b.id), 0)
   where b.centre_id = p_centre and b.status = 'draft';
end $$;

create or replace function public.td_override_earning(p_earning uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare c uuid; a bigint;
begin
  select centre_id into c from centre_earnings where id = p_earning;
  perform td_require(c, 'payouts.override');
  if coalesce(length(trim(p_reason)), 0) < 5 then raise exception 'Give a reason (at least 5 characters)'; end if;
  a := td_audit(c, 'earning.override', 'earning', p_earning, p_reason, '{}'::jsonb);
  update centre_earnings set override_audit_id = a where id = p_earning;
  update centre_earnings set status = 'payable' where id = p_earning and status in ('pending','held');
end $$;

-- =====================================================================================================
-- Lessons
-- =====================================================================================================
-- Tutors: remarks on their own lessons only (they have no direct UPDATE on lessons).
create or replace function public.td_submit_remarks(p_lesson uuid, p_remarks text) returns void
language plpgsql security definer set search_path = public as $$
declare l centre_lessons;
begin
  select * into l from centre_lessons where id = p_lesson;
  if l.id is null then raise exception 'Lesson not found'; end if;
  if not (td_has_perm(l.centre_id, 'lessons.deliver')
          or (td_has_perm(l.centre_id, 'lessons.remarks') and l.tutor_member_id = td_my_member(l.centre_id))) then
    raise exception 'You can only add remarks to your own lessons' using errcode = '42501';
  end if;
  update centre_lessons set remarks = left(p_remarks, 4000), remarks_by = auth.uid(), remarks_at = now() where id = p_lesson;
end $$;

-- Next invoice number for a centre.
create or replace function public.td_next_invoice_no(p_centre uuid) returns text
language plpgsql security definer set search_path = public as $$
declare n int; pre text;
begin
  update centres set invoice_seq = invoice_seq + 1 where id = p_centre returning invoice_seq, invoice_prefix into n, pre;
  return pre || '-' || lpad(n::text, 5, '0');
end $$;

-- Recompute an invoice's totals and status from its lines and reconciled payments.
create or replace function public.td_invoice_recalc(p_invoice uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s numeric; g numeric; t numeric; pd numeric; st text;
begin
  select coalesce(sum(amount), 0), coalesce(sum(gst), 0), coalesce(sum(total), 0) into s, g, t
    from centre_charges where invoice_id = p_invoice and status = 'open';
  select coalesce(sum(td_charge_covered(id)), 0) into pd from centre_charges where invoice_id = p_invoice and status = 'open';
  select status into st from centre_invoices where id = p_invoice;
  if st not in ('disputed','void') then
    st := case when pd >= t and t > 0 then 'paid' when pd > 0 then 'partially_paid' else 'issued' end;
  end if;
  update centre_invoices set subtotal = s, gst = g, total = t, paid = pd, status = st where id = p_invoice;
end $$;

create or replace function public.td_make_invoice(p_centre uuid, p_household uuid, p_charges uuid[], p_due_days int) returns uuid
language plpgsql security definer set search_path = public as $$
declare i uuid; tpl jsonb;
begin
  select coalesce(settings->'invoice', '{}'::jsonb) into tpl from centres where id = p_centre;
  insert into centre_invoices(centre_id, household_id, number, due_on, template)
  values (p_centre, p_household, td_next_invoice_no(p_centre), current_date + coalesce(p_due_days, 7), tpl) returning id into i;
  update centre_charges set invoice_id = i where id = any(p_charges);
  perform td_invoice_recalc(i);
  return i;
end $$;

-- Create a charge line with discount + GST applied.
create or replace function public.td_add_charge(p_centre uuid, p_household uuid, p_student uuid, p_lesson uuid, p_kind text,
  p_desc text, p_date date, p_amount numeric, p_discount numeric, p_policy jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare c centres; g record; v_id uuid;
begin
  select * into c from centres where id = p_centre;
  select * into g from td_gst(p_amount - coalesce(p_discount, 0), c.gst_rate, c.gst_inclusive, c.gst_registered);
  insert into centre_charges(centre_id, household_id, student_id, lesson_id, kind, description, charge_date, amount, discount, gst, total, policy)
  values (p_centre, p_household, p_student, p_lesson, p_kind, p_desc, p_date, g.net, coalesce(p_discount, 0), g.gst, g.total, coalesce(p_policy, '{}'))
  returning centre_charges.id into v_id;
  return v_id;
end $$;

-- Mark a lesson delivered: bill each student per their policy and create the tutor's earnings (pending).
create or replace function public.td_deliver_lesson(p_lesson uuid) returns void
language plpgsql security definer set search_path = public as $$
declare l centre_lessons; k centre_classes; a record; pol billing_policies; cfg jsonb; fee numeric; disc numeric;
  pct numeric; hh uuid; ch uuid; pk centre_packages; share numeric; mins int; rule tutor_pay_rules;
  heads int := 0; fee_sum numeric := 0; total_pay numeric; paid_so_far numeric := 0; n int := 0; part numeric;
  pay_late boolean; inv uuid;
begin
  select * into l from centre_lessons where id = p_lesson for update;
  if l.id is null then raise exception 'Lesson not found'; end if;
  perform td_require(l.centre_id, 'lessons.deliver');
  if l.status <> 'scheduled' then raise exception 'Lesson is already %', l.status; end if;
  select * into k from centre_classes where id = l.class_id;
  mins := extract(epoch from (l.end_time - l.start_time)) / 60;

  create temp table if not exists td_tmp_seats(attendee uuid, charge uuid, share numeric, fee numeric) on commit drop;
  delete from td_tmp_seats;

  for a in select x.* from centre_lesson_attendees x join centre_students s on s.id = x.student_id
           where x.lesson_id = l.id order by s.created_at, s.id loop
    select * into pol from td_policy_for(a.student_id, k.id);
    cfg := coalesce(pol.config, '{}'::jsonb) || jsonb_build_object('model', pol.model, 'policy_id', pol.id, 'policy_name', pol.name);
    select household_id into hh from centre_students where id = a.student_id;
    pay_late := coalesce((cfg->'cancellation'->>'pay_tutor_late_cancel')::boolean, false);
    if a.status = 'cancelled' then continue; end if;                                   -- early cancel: free, make-up allowed
    pct := case when a.status = 'late_cancel' then coalesce((cfg->'cancellation'->>'late_charge_pct')::numeric, 100) / 100.0
                when a.status = 'absent' then coalesce((cfg->'cancellation'->>'no_show_charge_pct')::numeric, 100) / 100.0
                else 1 end;
    fee := td_round(td_lesson_fee(l.id, a.student_id) * pct);
    ch := null; share := 0;

    if pol.model = 'prepay' and pct > 0 then
      select * into pk from centre_packages p where p.student_id = a.student_id and p.status = 'active'
        and p.lessons_used < p.lessons_total and (p.expires_on is null or p.expires_on >= l.lesson_date)
        order by p.created_at limit 1 for update;
      if pk.id is not null then
        insert into centre_package_draws(package_id, attendee_id) values (pk.id, a.id);
        update centre_packages set lessons_used = lessons_used + 1,
               status = case when lessons_used + 1 >= lessons_total then 'exhausted' else status end where id = pk.id;
        ch := pk.charge_id;
        select td_round(c.total / pk.lessons_total) into share from centre_charges c where c.id = pk.charge_id;
        select td_round(c.amount / pk.lessons_total) into fee from centre_charges c where c.id = pk.charge_id;
      elsif coalesce(cfg->>'no_balance', 'charge') = 'block' then
        raise exception 'Student has no prepaid lessons left (policy: block)';
      end if;
    end if;

    if ch is null and fee > 0 then
      disc := td_sibling_discount(a.student_id, fee, cfg);
      ch := td_add_charge(l.centre_id, hh, a.student_id, l.id, 'lesson',
              coalesce(k.name, 'Lesson') || ' · ' || to_char(l.lesson_date, 'DD Mon YYYY')
                || case when a.status = 'late_cancel' then ' (late cancellation)' when a.status = 'absent' then ' (absent)' else '' end,
              l.lesson_date, fee, disc, cfg);
      select total, amount into share, fee from centre_charges where id = ch;
      if coalesce(cfg->>'cycle', 'monthly') = 'per_lesson' then
        inv := td_make_invoice(l.centre_id, hh, array[ch], coalesce((cfg->>'due_days')::int, 7));
      end if;
    end if;
    update centre_lesson_attendees set charge_id = ch where id = a.id;
    if ch is not null and (a.status <> 'late_cancel' or pay_late) then
      insert into td_tmp_seats values (a.id, ch, share, fee);
      heads := heads + 1; fee_sum := fee_sum + fee;
    end if;
  end loop;

  -- tutor pay: one earning per paying student, so each depends only on that student's payment
  if l.tutor_member_id is not null and heads > 0 then
    select * into rule from td_pay_rule_for(l.centre_id, l.tutor_member_id, k.id, k.subject, k.level);
    if rule.id is null then raise exception 'No tutor pay rule matches this lesson: add one in Centre settings → Tutor pay'; end if;
    total_pay := td_pay_amount(rule.basis, rule.rate, mins, heads, fee_sum, rule.min_pay, rule.max_pay);
    for a in select t.* from td_tmp_seats t order by t.attendee loop
      n := n + 1;
      if n = heads then part := total_pay - paid_so_far;                          -- last one takes the rounding
      elsif rule.basis = 'percent_of_fee' and fee_sum > 0 then part := td_round(total_pay * a.fee / fee_sum);
      else part := td_round(total_pay / heads); end if;
      paid_so_far := paid_so_far + part;
      insert into centre_earnings(centre_id, tutor_member_id, lesson_id, attendee_id, charge_id, lesson_date, fee_share, amount, basis)
      values (l.centre_id, l.tutor_member_id, l.id, a.attendee, a.charge, l.lesson_date, a.share, part,
              jsonb_build_object('rule_id', rule.id, 'basis', rule.basis, 'rate', rule.rate, 'minutes', mins, 'heads', heads));
    end loop;
  end if;

  update centre_lessons set status = 'delivered', delivered_at = now() where id = l.id;
  perform td_refresh_earnings(l.centre_id);   -- package lessons already paid for become payable straight away
end $$;

-- Cancel one student's seat (late = inside the notice window, charged per policy).
create or replace function public.td_cancel_seat(p_attendee uuid, p_late boolean) returns void
language plpgsql security definer set search_path = public as $$
declare a centre_lesson_attendees;
begin
  select * into a from centre_lesson_attendees where id = p_attendee;
  perform td_require(a.centre_id, 'lessons.deliver');
  update centre_lesson_attendees set status = case when p_late then 'late_cancel' else 'cancelled' end where id = p_attendee;
end $$;

-- =====================================================================================================
-- Billing runs
-- =====================================================================================================
-- Prepaid package: charge + invoice now; lessons draw it down as they're delivered.
create or replace function public.td_sell_package(p_student uuid, p_lessons int, p_price numeric, p_expiry_days int) returns uuid
language plpgsql security definer set search_path = public as $$
declare s centre_students; ch uuid; pol billing_policies; inv uuid;
begin
  select * into s from centre_students where id = p_student;
  perform td_require(s.centre_id, 'billing.edit');
  select * into pol from td_policy_for(p_student, null);
  ch := td_add_charge(s.centre_id, s.household_id, s.id, null, 'package', p_lessons || '-lesson package · ' || s.name,
                      current_date, p_price, td_sibling_discount(s.id, p_price, pol.config), pol.config);
  insert into centre_packages(centre_id, household_id, student_id, charge_id, lessons_total, expires_on)
  values (s.centre_id, s.household_id, s.id, ch, p_lessons, case when p_expiry_days > 0 then current_date + p_expiry_days end);
  inv := td_make_invoice(s.centre_id, s.household_id, array[ch], coalesce((pol.config->>'due_days')::int, 7));
  perform td_audit(s.centre_id, 'package.sell', 'student', s.id, null, jsonb_build_object('lessons', p_lessons, 'price', p_price));
  return inv;
end $$;

-- Hybrid: deposit up front (refundable or not, per policy).
create or replace function public.td_charge_deposit(p_student uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare s centre_students; pol billing_policies; amt numeric; ch uuid;
begin
  select * into s from centre_students where id = p_student;
  perform td_require(s.centre_id, 'billing.edit');
  select * into pol from td_policy_for(p_student, null);
  amt := coalesce((pol.config->'deposit'->>'amount')::numeric, 0);
  if amt <= 0 then raise exception 'This student''s billing policy has no deposit'; end if;
  ch := td_add_charge(s.centre_id, s.household_id, s.id, null, 'deposit', 'Deposit · ' || s.name, current_date, amt, 0, pol.config);
  return td_make_invoice(s.centre_id, s.household_id, array[ch], coalesce((pol.config->>'due_days')::int, 7));
end $$;

-- Postpay: one invoice per household for everything not yet invoiced up to p_upto.
create or replace function public.td_generate_invoices(p_centre uuid, p_upto date) returns int
language plpgsql security definer set search_path = public as $$
declare h record; n int := 0; due int;
begin
  perform td_require(p_centre, 'billing.edit');
  for h in select household_id, array_agg(id order by charge_date, seq) ids, min(charge_date) first_day
           from centre_charges where centre_id = p_centre and invoice_id is null and status = 'open' and charge_date <= p_upto
           group by household_id loop
    select coalesce((policy->>'due_days')::int, 7) into due from centre_charges where id = h.ids[1];
    perform td_make_invoice(p_centre, h.household_id, h.ids, due);
    n := n + 1;
  end loop;
  perform td_audit(p_centre, 'invoices.generate', 'centre', p_centre, null, jsonb_build_object('upto', p_upto, 'count', n));
  return n;
end $$;

-- Late fees on overdue invoices, per the policy snapshot on their first line.
create or replace function public.td_apply_late_fees(p_centre uuid, p_asof date) returns int
language plpgsql security definer set search_path = public as $$
declare i record; cfg jsonb; fee numeric; times int; n int := 0; ch uuid;
begin
  perform td_require(p_centre, 'billing.edit');
  for i in select * from centre_invoices where centre_id = p_centre and status in ('issued','partially_paid') loop
    select policy->'late_fee' into cfg from centre_charges where invoice_id = i.id and kind <> 'late_fee' order by charge_date limit 1;
    if cfg is null or coalesce((cfg->>'value')::numeric, 0) = 0 then continue; end if;
    if p_asof <= i.due_on + coalesce((cfg->>'after_days')::int, 0) then continue; end if;
    select count(*) into times from centre_charges where invoice_id = i.id and kind = 'late_fee' and status = 'open';
    if times >= coalesce((cfg->>'max_times')::int, 1) then continue; end if;
    -- one fee per period of after_days (at least 1 day apart)
    if times > 0 and p_asof <= i.due_on + (times + 1) * greatest(coalesce((cfg->>'after_days')::int, 0), 1) then continue; end if;
    fee := case when cfg->>'type' = 'percent' then td_round((i.total - i.paid) * (cfg->>'value')::numeric / 100) else (cfg->>'value')::numeric end;
    if fee <= 0 then continue; end if;
    ch := td_add_charge(p_centre, i.household_id, null, null, 'late_fee', 'Late fee · ' || i.number, p_asof, fee, 0, jsonb_build_object('late_fee', cfg));
    update centre_charges set invoice_id = i.id where id = ch;
    perform td_invoice_recalc(i.id);
    n := n + 1;
  end loop;
  return n;
end $$;

-- Expired packages with lessons left: forfeit / extend / credit / refund-due, per policy.
create or replace function public.td_expire_packages(p_centre uuid, p_asof date) returns int
language plpgsql security definer set search_path = public as $$
declare p record; cfg jsonb; act text; n int := 0; left_n int; unit_net numeric;
begin
  perform td_require(p_centre, 'billing.edit');
  for p in select pk.*, c.policy, c.amount from centre_packages pk join centre_charges c on c.id = pk.charge_id
           where pk.centre_id = p_centre and pk.status = 'active' and pk.expires_on < p_asof loop
    cfg := coalesce(p.policy->'unused', '{}'::jsonb);
    act := coalesce(cfg->>'action', 'forfeit');
    left_n := p.lessons_total - p.lessons_used;
    if act = 'carry_forward' and p.extended < coalesce((cfg->>'max_extensions')::int, 1) then
      update centre_packages set expires_on = expires_on + coalesce((cfg->>'extend_days')::int, 30), extended = extended + 1 where id = p.id;
    elsif act = 'credit' then
      unit_net := td_round(p.amount / p.lessons_total * left_n);
      perform td_add_charge(p_centre, p.household_id, p.student_id, null, 'credit', 'Credit for ' || left_n || ' unused lessons',
                            p_asof, -unit_net, 0, p.policy);
      update centre_packages set status = 'credited' where id = p.id;
    elsif act = 'refund' then
      update centre_packages set status = 'refund_due' where id = p.id;
    else
      update centre_packages set status = 'expired' where id = p.id;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- =====================================================================================================
-- Payments, reconciliation, refunds, disputes
-- =====================================================================================================
-- Record money in. Allocated to the oldest unpaid lines (of that invoice, or of the household).
-- p_reconciled = true needs payments.reconcile (Stripe webhooks run as the service role).
create or replace function public.td_record_payment(p_centre uuid, p_household uuid, p_invoice uuid, p_method text,
  p_amount numeric, p_received date, p_reference text, p_reconciled boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare pay uuid; left_amt numeric := p_amount; c record; take numeric; inv uuid;
begin
  perform td_require(p_centre, 'payments.record');
  if p_reconciled then perform td_require(p_centre, 'payments.reconcile'); end if;
  insert into centre_payments(centre_id, household_id, invoice_id, method, amount, received_on, reference, status, recorded_by,
                              reconciled_by, reconciled_at)
  values (p_centre, p_household, p_invoice, p_method, p_amount, coalesce(p_received, current_date), p_reference,
          case when p_reconciled then 'reconciled' else 'recorded' end, auth.uid(),
          case when p_reconciled then auth.uid() end, case when p_reconciled then now() end) returning id into pay;
  for c in select ch.id, ch.total - coalesce((select sum(a.amount) from centre_allocations a join centre_payments p on p.id = a.payment_id
                                               where a.charge_id = ch.id and p.status <> 'void'), 0) as owing
           from centre_charges ch left join centre_invoices i on i.id = ch.invoice_id
           where ch.household_id = p_household and ch.status = 'open' and ch.total > 0
             and (p_invoice is null or ch.invoice_id = p_invoice) and coalesce(i.status, 'issued') <> 'void'
           order by ch.charge_date, ch.seq loop
    exit when left_amt <= 0;
    continue when c.owing <= 0;
    take := least(left_amt, c.owing);
    insert into centre_allocations(payment_id, charge_id, amount) values (pay, c.id, take);
    left_amt := left_amt - take;
  end loop;
  for inv in select distinct ch.invoice_id from centre_allocations a join centre_charges ch on ch.id = a.charge_id
             where a.payment_id = pay and ch.invoice_id is not null loop
    perform td_invoice_recalc(inv);
  end loop;
  perform td_audit(p_centre, 'payment.record', 'payment', pay, null,
                   jsonb_build_object('amount', p_amount, 'method', p_method, 'reconciled', p_reconciled, 'unallocated', left_amt));
  perform td_refresh_earnings(p_centre);
  return pay;
end $$;

create or replace function public.td_reconcile_payment(p_payment uuid) returns void
language plpgsql security definer set search_path = public as $$
declare p centre_payments; inv uuid;
begin
  select * into p from centre_payments where id = p_payment;
  perform td_require(p.centre_id, 'payments.reconcile');
  if p.status <> 'recorded' then raise exception 'Payment is %', p.status; end if;
  update centre_payments set status = 'reconciled', reconciled_by = auth.uid(), reconciled_at = now() where id = p_payment;
  for inv in select distinct ch.invoice_id from centre_allocations a join centre_charges ch on ch.id = a.charge_id
             where a.payment_id = p_payment and ch.invoice_id is not null loop
    perform td_invoice_recalc(inv);
  end loop;
  perform td_audit(p.centre_id, 'payment.reconcile', 'payment', p_payment, null, jsonb_build_object('amount', p.amount));
  perform td_refresh_earnings(p.centre_id);
end $$;

-- Refund (part of) a payment: takes money back from the NEWEST lines first, so the oldest stay paid.
create or replace function public.td_refund_payment(p_payment uuid, p_amount numeric, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare p centre_payments; left_amt numeric := p_amount; a record; take numeric; inv uuid;
begin
  select * into p from centre_payments where id = p_payment for update;
  perform td_require(p.centre_id, 'payments.reconcile');
  if p_amount <= 0 or p_amount > p.amount - p.refunded then raise exception 'Refund must be between 0 and %', p.amount - p.refunded; end if;
  for a in select x.charge_id, sum(x.amount) net
           from centre_allocations x join centre_charges ch on ch.id = x.charge_id
           where x.payment_id = p_payment group by x.charge_id having sum(x.amount) > 0
           order by max(ch.charge_date) desc, max(ch.seq) desc loop
    exit when left_amt <= 0;
    take := least(left_amt, a.net);
    insert into centre_allocations(payment_id, charge_id, amount) values (p_payment, a.charge_id, -take);
    left_amt := left_amt - take;
  end loop;
  update centre_payments set refunded = refunded + p_amount where id = p_payment;
  for inv in select distinct ch.invoice_id from centre_allocations x join centre_charges ch on ch.id = x.charge_id
             where x.payment_id = p_payment and ch.invoice_id is not null loop
    perform td_invoice_recalc(inv);
  end loop;
  perform td_audit(p.centre_id, 'payment.refund', 'payment', p_payment, p_reason, jsonb_build_object('amount', p_amount));
  perform td_refresh_earnings(p.centre_id);
end $$;

create or replace function public.td_set_dispute(p_invoice uuid, p_disputed boolean, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare i centre_invoices;
begin
  select * into i from centre_invoices where id = p_invoice;
  perform td_require(i.centre_id, 'payments.reconcile');
  if p_disputed then
    update centre_invoices set status = 'disputed', dispute_reason = p_reason where id = p_invoice;
  else
    update centre_invoices set status = 'issued', dispute_reason = null where id = p_invoice;
    perform td_invoice_recalc(p_invoice);
  end if;
  perform td_audit(i.centre_id, case when p_disputed then 'invoice.dispute' else 'invoice.dispute_resolved' end, 'invoice', p_invoice, p_reason, '{}');
  perform td_refresh_earnings(i.centre_id);
end $$;

-- =====================================================================================================
-- Payout batches
-- =====================================================================================================
-- Takes every payable earning up to p_upto. A tutor whose net total isn't positive (deductions bigger than
-- earnings) is left out, so their deduction carries into the next batch.
create or replace function public.td_create_payout_batch(p_centre uuid, p_upto date) returns uuid
language plpgsql security definer set search_path = public as $$
declare b uuid; t record;
begin
  perform td_require(p_centre, 'payouts.manage');
  perform td_refresh_earnings(p_centre);
  insert into centre_payout_batches(centre_id, up_to, created_by) values (p_centre, p_upto, auth.uid()) returning id into b;
  for t in select tutor_member_id, sum(amount) net from centre_earnings
           where centre_id = p_centre and status = 'payable' and coalesce(lesson_date, current_date) <= p_upto
           group by tutor_member_id loop
    if t.net > 0 then
      update centre_earnings set status = 'batched', batch_id = b
       where centre_id = p_centre and tutor_member_id = t.tutor_member_id and status = 'payable'
         and coalesce(lesson_date, current_date) <= p_upto;
    end if;
  end loop;
  update centre_payout_batches set total = coalesce((select sum(amount) from centre_earnings where batch_id = b), 0) where id = b;
  perform td_audit(p_centre, 'payout.batch_create', 'batch', b, null, jsonb_build_object('upto', p_upto));
  return b;
end $$;

create or replace function public.td_mark_batch_paid(p_batch uuid, p_reference text) returns void
language plpgsql security definer set search_path = public as $$
declare bt centre_payout_batches;
begin
  select * into bt from centre_payout_batches where id = p_batch for update;
  perform td_require(bt.centre_id, 'payouts.manage');
  if bt.status <> 'draft' then raise exception 'Batch is %', bt.status; end if;
  perform td_refresh_earnings(bt.centre_id);      -- last check: anything refunded/disputed since drops out
  update centre_earnings set status = 'paid' where batch_id = p_batch and status = 'batched';
  update centre_payout_batches set status = 'paid', paid_at = now(), reference = p_reference,
         total = coalesce((select sum(amount) from centre_earnings where batch_id = p_batch), 0) where id = p_batch;
  perform td_audit(bt.centre_id, 'payout.batch_paid', 'batch', p_batch, null, jsonb_build_object('reference', p_reference));
end $$;

create or replace function public.td_cancel_batch(p_batch uuid) returns void
language plpgsql security definer set search_path = public as $$
declare bt centre_payout_batches;
begin
  select * into bt from centre_payout_batches where id = p_batch;
  perform td_require(bt.centre_id, 'payouts.manage');
  if bt.status <> 'draft' then raise exception 'Only a draft batch can be cancelled'; end if;
  -- back to pending; the refresh below re-checks coverage and makes them payable again
  update centre_earnings set status = 'pending', batch_id = null where batch_id = p_batch;
  update centre_payout_batches set status = 'cancelled' where id = p_batch;
  perform td_audit(bt.centre_id, 'payout.batch_cancel', 'batch', p_batch, null, '{}');
  perform td_refresh_earnings(bt.centre_id);
end $$;

-- =====================================================================================================
-- Row-level security
-- =====================================================================================================
-- Reads are by permission; writes to money tables go ONLY through the td_* functions above.
do $$
declare t text;
begin
  foreach t in array array['centres','centre_roles','centre_members','centre_fields','centre_audit_log','billing_policies',
    'centre_price_list','tutor_pay_rules','households','guardians','centre_students','centre_classes','centre_enrolments',
    'centre_lessons','centre_lesson_attendees','centre_invoices','centre_charges','centre_packages','centre_package_draws',
    'centre_payments','centre_allocations','centre_payout_batches','centre_earnings','stripe_events'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

drop policy if exists centres_read on public.centres;
create policy centres_read on public.centres for select using (td_is_member(id));
drop policy if exists centres_write on public.centres;
create policy centres_write on public.centres for update using (td_has_perm(id, 'settings.edit')) with check (td_has_perm(id, 'settings.edit'));

drop policy if exists roles_read on public.centre_roles;
create policy roles_read on public.centre_roles for select using (td_is_member(centre_id));

drop policy if exists members_read on public.centre_members;
create policy members_read on public.centre_members for select using (td_is_member(centre_id));
drop policy if exists members_add on public.centre_members;
create policy members_add on public.centre_members for insert with check (td_has_perm(centre_id, 'roles.manage')
  and not exists (select 1 from centre_roles r where r.id = role_id and r.key = 'owner'));
drop policy if exists members_edit on public.centre_members;
create policy members_edit on public.centre_members for update using (td_has_perm(centre_id, 'roles.manage'));

-- role_id changes must go through td_set_member_role (owner checks + audit)
create or replace function public.td_members_guard() returns trigger language plpgsql as $$
begin
  if new.role_id is distinct from old.role_id and coalesce(current_setting('td.role_change', true), '') <> '1' then
    raise exception 'Change roles with td_set_member_role (it is audited)';
  end if;
  if new.user_id is distinct from old.user_id and old.user_id is not null then raise exception 'A member''s login is fixed'; end if;
  return new;
end $$;
drop trigger if exists centre_members_guard on public.centre_members;
create trigger centre_members_guard before update on public.centre_members for each row execute function public.td_members_guard();

drop policy if exists fields_read on public.centre_fields;
create policy fields_read on public.centre_fields for select using (td_is_member(centre_id));
drop policy if exists fields_write on public.centre_fields;
create policy fields_write on public.centre_fields for all using (td_has_perm(centre_id, 'settings.edit')) with check (td_has_perm(centre_id, 'settings.edit'));

drop policy if exists audit_read on public.centre_audit_log;
create policy audit_read on public.centre_audit_log for select using (td_has_perm(centre_id, 'audit.view'));

do $$
declare t text;
begin
  foreach t in array array['billing_policies','centre_price_list','tutor_pay_rules'] loop
    execute format('drop policy if exists %1$s_read on public.%1$I', t);
    execute format('create policy %1$s_read on public.%1$I for select using (td_has_perm(centre_id, ''billing.view'') or td_has_perm(centre_id, ''settings.edit''))', t);
    execute format('drop policy if exists %1$s_write on public.%1$I', t);
    execute format('create policy %1$s_write on public.%1$I for all using (td_has_perm(centre_id, ''billing.edit'') or td_has_perm(centre_id, ''settings.edit'')) with check (td_has_perm(centre_id, ''billing.edit'') or td_has_perm(centre_id, ''settings.edit''))', t);
  end loop;
  foreach t in array array['households','guardians','centre_students'] loop
    execute format('drop policy if exists %1$s_read on public.%1$I', t);
    execute format('create policy %1$s_read on public.%1$I for select using (td_has_perm(centre_id, ''students.view''))', t);
    execute format('drop policy if exists %1$s_write on public.%1$I', t);
    execute format('create policy %1$s_write on public.%1$I for all using (td_has_perm(centre_id, ''students.edit'')) with check (td_has_perm(centre_id, ''students.edit''))', t);
  end loop;
  foreach t in array array['centre_classes','centre_enrolments'] loop
    execute format('drop policy if exists %1$s_read on public.%1$I', t);
    execute format('create policy %1$s_read on public.%1$I for select using (td_is_member(centre_id))', t);
    execute format('drop policy if exists %1$s_write on public.%1$I', t);
    execute format('create policy %1$s_write on public.%1$I for all using (td_has_perm(centre_id, ''classes.edit'')) with check (td_has_perm(centre_id, ''classes.edit''))', t);
  end loop;
  foreach t in array array['centre_invoices','centre_charges','centre_packages','centre_payments'] loop
    execute format('drop policy if exists %1$s_read on public.%1$I', t);
    execute format('create policy %1$s_read on public.%1$I for select using (td_has_perm(centre_id, ''billing.view''))', t);
  end loop;
end $$;

-- Tutors see students in their own lessons (name/level only is the UI's job; RLS is per row).
drop policy if exists students_tutor_read on public.centre_students;
create policy students_tutor_read on public.centre_students for select using (exists (
  select 1 from centre_lesson_attendees a join centre_lessons l on l.id = a.lesson_id
  where a.student_id = centre_students.id and l.tutor_member_id = td_my_member(centre_students.centre_id)));

drop policy if exists lessons_read on public.centre_lessons;
create policy lessons_read on public.centre_lessons for select using (
  td_has_perm(centre_id, 'schedule.view_all') or tutor_member_id = td_my_member(centre_id));
drop policy if exists lessons_write on public.centre_lessons;
create policy lessons_write on public.centre_lessons for insert with check (td_has_perm(centre_id, 'classes.edit') and status = 'scheduled');
drop policy if exists lessons_edit on public.centre_lessons;
create policy lessons_edit on public.centre_lessons for update using (td_has_perm(centre_id, 'classes.edit') and status = 'scheduled')
  with check (status = 'scheduled');
drop policy if exists lessons_del on public.centre_lessons;
create policy lessons_del on public.centre_lessons for delete using (td_has_perm(centre_id, 'classes.edit') and status = 'scheduled');

drop policy if exists att_read on public.centre_lesson_attendees;
create policy att_read on public.centre_lesson_attendees for select using (
  td_has_perm(centre_id, 'schedule.view_all') or exists (select 1 from centre_lessons l where l.id = lesson_id and l.tutor_member_id = td_my_member(l.centre_id)));
drop policy if exists att_write on public.centre_lesson_attendees;
create policy att_write on public.centre_lesson_attendees for insert with check (td_has_perm(centre_id, 'classes.edit') and charge_id is null);
drop policy if exists att_del on public.centre_lesson_attendees;
create policy att_del on public.centre_lesson_attendees for delete using (td_has_perm(centre_id, 'classes.edit') and charge_id is null);

drop policy if exists alloc_read on public.centre_allocations;
create policy alloc_read on public.centre_allocations for select using (exists (
  select 1 from centre_payments p where p.id = payment_id and td_has_perm(p.centre_id, 'billing.view')));
drop policy if exists draws_read on public.centre_package_draws;
create policy draws_read on public.centre_package_draws for select using (exists (
  select 1 from centre_packages p where p.id = package_id and td_has_perm(p.centre_id, 'billing.view')));

drop policy if exists batches_read on public.centre_payout_batches;
create policy batches_read on public.centre_payout_batches for select using (td_has_perm(centre_id, 'payouts.view'));
drop policy if exists earnings_read on public.centre_earnings;
create policy earnings_read on public.centre_earnings for select using (
  td_has_perm(centre_id, 'payouts.view')
  or (td_has_perm(centre_id, 'payouts.view_own') and tutor_member_id = td_my_member(centre_id)));
-- stripe_events: no client policies at all (server only).

-- Functions: signed-in users only (each checks its own permission).
do $$
declare f text;
begin
  foreach f in array array['td_create_centre(text)','td_claim_invites()','td_set_payout_rule(uuid,text,text)','td_save_role(uuid,uuid,text,text,text[])',
    'td_set_member_role(uuid,uuid)','td_override_earning(uuid,text)','td_submit_remarks(uuid,text)','td_deliver_lesson(uuid)',
    'td_cancel_seat(uuid,boolean)','td_sell_package(uuid,int,numeric,int)','td_charge_deposit(uuid)','td_generate_invoices(uuid,date)',
    'td_apply_late_fees(uuid,date)','td_expire_packages(uuid,date)','td_record_payment(uuid,uuid,uuid,text,numeric,date,text,boolean)',
    'td_reconcile_payment(uuid)','td_refund_payment(uuid,numeric,text)','td_set_dispute(uuid,boolean,text)',
    'td_create_payout_batch(uuid,date)','td_mark_batch_paid(uuid,text)','td_cancel_batch(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  -- internal helpers: not callable from the browser
  foreach f in array array['td_audit(uuid,text,text,uuid,text,jsonb)','td_add_charge(uuid,uuid,uuid,uuid,text,text,date,numeric,numeric,jsonb)',
    'td_make_invoice(uuid,uuid,uuid[],int)','td_invoice_recalc(uuid)','td_next_invoice_no(uuid)','td_refresh_earnings(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;
