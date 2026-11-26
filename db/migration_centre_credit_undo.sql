-- =====================================================================================================
-- T4 step S5b — undo of credit / deposit applied to an invoice, and the four-eyes guard for refund approval          undo: migration_centre_credit_undo_down.sql
-- =====================================================================================================
-- Run order everywhere: org_foundation → billing → attendance → tutor_access → org_delete → function_lockdown → org_separation →
--   staff_home → staff_students → staff_attendance → staff_charges → staff_trials → staff_timetable → money_settings →
--   centre_money → centre_invoice_run → centre_payments → centre_deposits → centre_refunds → centre_late_fees → centre_credit_undo.
-- Needs migration_centre_refunds.sql (S5). Run on the DEV project first. LIVE only when the owner says ship: it reads no existing row and changes none
-- (one new table, two widened checks, two re-created functions, new functions, one trigger on memberships). Safe to run twice.
--
-- PART A. UNDO OF AN APPLICATION (owner decision, 2026-11-27)
--   Credit (or a deposit kept against invoices) that was applied to an invoice is still never EDITED, but it can now be UNDONE as a NEW entry, the same
--   append-only pattern as reversing a payment:  a reversal payment row (method family_credit / deposit, pointing at the application), negative allocations
--   that reopen the invoice(s), and one new ledger row (kind 'application_undone') that gives the money back to the family credit / the deposit held.
--   Nothing is edited or deleted. A credit note only SUBTRACTS from an invoice, so it can never undo an application (that is why this exists).
--   WHO       the owner or staff with issue_invoices.   A REASON is required.   Audited (amounts only; the reason stays in the record, redacted in the copy).
--   ONCE      one reversal per application (unique index since S1): pressing twice answers {already:true} and writes nothing.
--   WHAT BLOCKS IT (stated in plain words on the screen; the application is one payment and can touch several invoices, so EVERY invoice must pass):
--     · the invoice is no longer an open issued invoice (defensive: an issued invoice is never cancelled; fully credited = the credit-note rule below)
--     · a credit note was issued on the invoice after the credit was used (the invoice's figures now depend on it)
--     · money was recorded or reversed on the invoice after the credit was used (a payment that was worked out assuming the credit)
--     · deposit only: the student's deposit changed after the set-off (another refund, adjustment ...)
--     An invoice that the credit itself paid in full CAN be undone: that is the mistake this fixes. (Owner to confirm this reading of "not paid".)
--   NEVER NEGATIVE  undoing only adds back: the invoice's balance goes up, the family credit / deposit held go up. The S1 / S3 / S4 guards still apply.
--   centre_reverse_payment (the cash-payment reversal) still refuses an applied credit / deposit; it now points to Undo instead of a credit note.
--
-- PART B. FOUR-EYES GUARD (owner decision, 2026-11-27)
--   "Refunds are approved by: someone other than the person who asked" (billing.deposit.refund_approved_by = four_eyes) only works when a SECOND person
--   exists. It can now be chosen ONLY while the centre has: the owner, an active staff member who issues invoices (needed for deposit refunds) AND an
--   active staff member who records payments (needed for family-credit refunds; may be the same person). The database enforces it:
--     · org_validate_settings(org, settings) refuses four_eyes when it can't be satisfied; org_save_settings and org_create_centre use it.
--     · if that staff member is later removed, switched off, or loses the permission, a trigger on memberships puts the setting back to the default
--       (owner approves) as a NEW effective-dated settings row (today; and the same day of any future-dated row that says four_eyes), tells every owner
--       in-app (org_notifications; the e-mail comes with the email provider: SOON), and writes the audit log. centre_refund_rule() also reads an
--       unsatisfiable four_eyes as 'owner', so a request that was waiting for a second person becomes approvable by the owner at once, even in the gap.
-- =====================================================================================================

-- ---------------------------------------------------------------------------------------------------
-- 1. the two ledgers learn "application_undone" (a positive row: the money is the family's / the deposit's again)
-- ---------------------------------------------------------------------------------------------------
do $$
declare c record;
begin
  if not exists (select 1 from pg_constraint where conname = 'centre_family_credit_kind_s5b') then
    alter table public.centre_family_credit drop constraint if exists centre_family_credit_kind_s5;
    alter table public.centre_family_credit add constraint centre_family_credit_kind_s5b
      check (kind in ('overpayment', 'credit_note_excess', 'payment_reversal', 'excess_release', 'refund', 'applied', 'application_undone'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'centre_family_credit_sign_s5b') then
    for c in select conname from pg_constraint where conrelid = 'public.centre_family_credit'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%credit_note_excess%' and pg_get_constraintdef(oid) like '%cents > 0%' and pg_get_constraintdef(oid) not like '%payment_reversal%' loop
      execute format('alter table public.centre_family_credit drop constraint %I', c.conname);
    end loop;
    alter table public.centre_family_credit add constraint centre_family_credit_sign_s5b
      check ((kind in ('overpayment', 'credit_note_excess', 'application_undone')) = (cents > 0));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'centre_deposit_ledger_kind_s5b') then
    for c in select conname from pg_constraint where conrelid = 'public.centre_deposit_ledger'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%opening_balance%' and pg_get_constraintdef(oid) like '%transferred_out%' and pg_get_constraintdef(oid) not like '%CASE%' loop
      execute format('alter table public.centre_deposit_ledger drop constraint %I', c.conname);
    end loop;
    alter table public.centre_deposit_ledger add constraint centre_deposit_ledger_kind_s5b
      check (kind in ('received', 'reversal', 'waived', 'adjusted', 'applied', 'forfeited', 'refunded', 'transferred_out', 'transferred_in', 'opening_balance', 'application_undone'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'centre_deposit_ledger_sign_s5b') then
    for c in select conname from pg_constraint where conrelid = 'public.centre_deposit_ledger'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%CASE%' and pg_get_constraintdef(oid) like '%transferred_out%' loop
      execute format('alter table public.centre_deposit_ledger drop constraint %I', c.conname);
    end loop;
    alter table public.centre_deposit_ledger add constraint centre_deposit_ledger_sign_s5b
      check (case kind when 'received' then cents > 0 when 'opening_balance' then cents > 0 when 'transferred_in' then cents > 0 when 'waived' then cents > 0
                       when 'application_undone' then cents > 0
                       when 'reversal' then cents < 0 when 'applied' then cents < 0 when 'forfeited' then cents < 0 when 'refunded' then cents < 0
                       when 'transferred_out' then cents < 0 else true end);
  end if;
end $$;

-- the S5 guard on "internal" reversals: only Undo (which switches the flag on for its own transaction) may write one
create or replace function public.centre_internal_method_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'reversal' and new.method in ('family_credit', 'deposit') and coalesce(current_setting('td.undo_application', true), '') <> '1' then
    raise exception 'NOT_ALLOWED: credit or deposit that was applied to an invoice can''t be reversed like a payment; use Undo on the invoice instead (a credit note can''t give it back)' using errcode = '42501';
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 2. what blocks an undo (internal; plain words, one entry per problem)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_undo_blockers(p_org uuid, p_payment uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p centre_payments; r record; out jsonb := '[]'::jsonb; sid uuid; led centre_deposit_ledger;
begin
  select * into p from centre_payments where id = p_payment and org_id = p_org;
  if p.id is null then return out; end if;
  for r in
    select i.id, i.number_text, i.status
      from centre_invoices i
     where i.org_id = p_org and i.id in (select a.invoice_id from centre_payment_allocations a where a.org_id = p_org and a.payment_id = p.id group by a.invoice_id having sum(a.cents) > 0)
     order by i.issue_date, i.number_seq
  loop
    if r.status <> 'issued' then
      out := out || jsonb_build_object('code', 'invoice_closed', 'invoice_id', r.id, 'text', 'Invoice ' || r.number_text || ' is cancelled, so the money can''t be taken back from it.');
    elsif exists (select 1 from centre_invoices n where n.org_id = p_org and n.credits_invoice_id = r.id and n.status = 'issued') then
      out := out || jsonb_build_object('code', 'credit_note', 'invoice_id', r.id, 'text', 'Invoice ' || r.number_text || ' has a credit note, issued after the credit was used. Its figures now depend on it.');
    elsif (select coalesce(sum(x.cents), 0) from centre_payment_allocations x where x.org_id = p_org and x.invoice_id = r.id and x.payment_id <> p.id and x.created_at > p.created_at) <> 0 then
      out := out || jsonb_build_object('code', 'later_payment', 'invoice_id', r.id, 'text', 'Money was recorded on invoice ' || r.number_text || ' after the credit was used. Reverse that payment first.');
    end if;
  end loop;
  if p.method = 'deposit' then
    select * into led from centre_deposit_ledger where org_id = p_org and payment_id = p.id and kind = 'applied';
    if led.id is not null and exists (select 1 from centre_deposit_ledger d where d.org_id = p_org and d.student_id = led.student_id and d.created_at > led.created_at
                                         and d.refund_id is distinct from led.refund_id and d.kind <> 'application_undone') then
      out := out || jsonb_build_object('code', 'deposit_changed', 'invoice_id', null, 'text', 'The student''s deposit changed after it was kept against the invoice (another refund or adjustment), so this can''t be undone.');
    end if;
  end if;
  return out;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 3. UNDO an application (one payment of method family_credit / deposit) — owner or staff with issue_invoices
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_undo_application(p_payment uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare org uuid; today date; p centre_payments; why text := nullif(btrim(coalesce(p_reason, '')), ''); rid uuid := gen_random_uuid(); a record; bl jsonb; led record;
  nums text; sid uuid;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select org_id into org from centre_payments where id = p_payment;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := centre_money_gate(org, 'issue_invoices');
  select * into p from centre_payments where id = p_payment and org_id = org;
  if p.kind <> 'payment' or p.method not in ('family_credit', 'deposit') then
    raise exception 'NOT_ALLOWED: only credit or a deposit that was applied to an invoice can be undone here' using errcode = '42501'; end if;
  if why is null then raise exception 'REASON_REQUIRED: say why this is being undone' using errcode = 'P0001'; end if;
  if length(why) > 300 then raise exception 'TOO_LONG: keep the reason under 300 characters' using errcode = 'P0001'; end if;
  if p.method = 'deposit' then
    select * into led from centre_deposit_ledger where org_id = org and payment_id = p.id and kind = 'applied';
    if led.id is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    sid := led.student_id;
    perform pg_advisory_xact_lock(hashtextextended(sid::text, 6));
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p.household_id::text, 4));
  if exists (select 1 from centre_payments where reverses_payment_id = p.id and org_id = org) then
    return jsonb_build_object('already', true, 'payment_id', p.id, 'credit_balance_cents', centre_credit_balance(org, p.household_id));
  end if;
  bl := centre_undo_blockers(org, p.id);
  if jsonb_array_length(bl) > 0 then raise exception 'UNDO_BLOCKED: %', bl->0->>'text' using errcode = '42501'; end if;
  perform set_config('td.undo_application', '1', true);
  insert into centre_payments(id, org_id, kind, reverses_payment_id, household_id, method, amount_cents, received_on, note)
  values (rid, org, 'reversal', p.id, p.household_id, p.method, p.amount_cents, greatest(today, p.received_on), why);
  perform set_config('td.undo_application', '', true);
  for a in select invoice_id, sum(cents) as c from centre_payment_allocations where payment_id = p.id and org_id = org group by invoice_id having sum(cents) > 0 loop
    insert into centre_payment_allocations(org_id, payment_id, invoice_id, cents) values (org, rid, a.invoice_id, -a.c);
  end loop;
  select string_agg(i.number_text, ', ' order by i.issue_date, i.number_seq) into nums from centre_invoices i
   where i.org_id = org and i.id in (select invoice_id from centre_payment_allocations where payment_id = rid);
  if p.method = 'family_credit' then
    insert into centre_family_credit(org_id, household_id, kind, cents, payment_id, reason)
    values (org, p.household_id, 'application_undone', p.amount_cents, p.id, 'Undone: ' || why);
  else
    insert into centre_deposit_ledger(org_id, student_id, deposit_id, kind, cents, taxable, payment_id, entry_date, reason, refund_id)
    values (org, led.student_id, led.deposit_id, 'application_undone', p.amount_cents, led.taxable, p.id, today, 'Undone: ' || why, led.refund_id);
  end if;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (org, auth.uid(), 'centre_application_undo', 'centre_payments', p.id::text, jsonb_build_object('method', p.method, 'amount_cents', p.amount_cents),
          jsonb_build_object('reversal_id', rid, 'undone_cents', p.amount_cents, 'invoices', (select count(distinct invoice_id) from centre_payment_allocations where payment_id = rid)));
  return jsonb_build_object('already', false, 'reversal_id', rid, 'payment_id', p.id, 'undone_cents', p.amount_cents, 'invoices', nums,
                            'credit_balance_cents', centre_credit_balance(org, p.household_id));
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 4. what the invoice sheet reads: the applications on one invoice, each with "can it be undone, and if not, why"
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_invoice_applications(p_invoice uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare org uuid; today date; role_ok boolean; res jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select org_id into org from centre_invoices where id = p_invoice;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := centre_money_gate(org, 'either');
  role_ok := org_can(org, 'issue_invoices');
  select coalesce(jsonb_agg(x.j order by x.d, x.id), '[]'::jsonb) into res from (
    select p.id, p.received_on as d, jsonb_build_object(
      'payment_id', p.id, 'method', p.method, 'cents', p.amount_cents, 'date', p.received_on,
      'on_this_invoice_cents', (select coalesce(sum(a.cents), 0) from centre_payment_allocations a where a.org_id = org and a.payment_id = p.id and a.invoice_id = p_invoice),
      'also_invoices', coalesce((select jsonb_agg(i.number_text order by i.issue_date, i.number_seq) from centre_invoices i where i.org_id = org and i.id <> p_invoice
                                   and i.id in (select a.invoice_id from centre_payment_allocations a where a.org_id = org and a.payment_id = p.id)), '[]'::jsonb),
      'by', centre_person_name(org, p.recorded_by),
      'state', case when u.id is null then 'active' else 'undone' end,
      'undone_on', u.received_on, 'undone_by', centre_person_name(org, u.recorded_by), 'undone_reason', case when role_ok then u.note end,
      'blockers', case when u.id is null then centre_undo_blockers(org, p.id) else '[]'::jsonb end,
      'can_undo', role_ok and u.id is null and jsonb_array_length(centre_undo_blockers(org, p.id)) = 0) as j
      from centre_payments p left join centre_payments u on u.reverses_payment_id = p.id and u.org_id = p.org_id
     where p.org_id = org and p.kind = 'payment' and p.method in ('family_credit', 'deposit')
       and exists (select 1 from centre_payment_allocations a where a.org_id = org and a.payment_id = p.id and a.invoice_id = p_invoice)) x;
  return jsonb_build_object('today', today, 'can_undo_role', role_ok, 'rows', res);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 5. FOUR EYES. Is a second approver possible? (internal)
-- ---------------------------------------------------------------------------------------------------
-- the owner, a staff member who issues invoices (deposit refunds) and a staff member who records payments (family-credit refunds), all active
create or replace function public.org_four_eyes_status(p_org uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'owner',   exists (select 1 from memberships m where m.org_id = p_org and m.role = 'owner' and m.status = 'active' and m.user_id is not null),
    'deposit', exists (select 1 from memberships m where m.org_id = p_org and m.role = 'staff' and m.status = 'active' and m.user_id is not null and 'issue_invoices' = any(m.permissions)),
    'credit',  exists (select 1 from memberships m where m.org_id = p_org and m.role = 'staff' and m.status = 'active' and m.user_id is not null and 'record_payments' = any(m.permissions)))
$$;
create or replace function public.org_four_eyes_ready(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(bool_and(v::boolean), false) from jsonb_each_text(public.org_four_eyes_status(p_org)) as t(k, v)
$$;

-- the settings check that knows which organisation it is for (the 1-argument org_validate_settings can't: it only sees the JSON)
create or replace function public.org_validate_settings(p_org uuid, s jsonb) returns void language plpgsql stable security definer set search_path = public as $$
declare st jsonb;
begin
  perform public.org_validate_settings(s);
  if s #>> '{billing,deposit,refund_approved_by}' = 'four_eyes' then
    st := case when p_org is null then jsonb_build_object('owner', true, 'deposit', false, 'credit', false) else public.org_four_eyes_status(p_org) end;
    if not (coalesce((st->>'owner')::boolean, false) and coalesce((st->>'deposit')::boolean, false) and coalesce((st->>'credit')::boolean, false)) then
      raise exception 'FOUR_EYES_UNAVAILABLE: "someone other than the person who asked" needs a second approver: the owner, a staff member who issues invoices (for deposit refunds) and a staff member who records payments (for credit refunds), all active. Add them first, or pick another approver.' using errcode = '42501';
    end if;
  end if;
end $$;

-- same bodies as the foundation versions, with the organisation-aware check
create or replace function public.org_save_settings(p_org uuid, p_settings jsonb, p_effective_from date) returns int
language plpgsql security definer set search_path = public as $$
declare v int; st text;
begin
  if not org_can(p_org, 'owner') then raise exception 'Only the owner can change settings' using errcode = '42501'; end if;
  perform org_validate_settings(p_org, p_settings);
  select status into st from organisations where id = p_org;
  if st <> 'setup' and p_effective_from < current_date then raise exception 'Settings can''t be back-dated'; end if;
  select coalesce(max(version), 0) + 1 into v from org_settings where org_id = p_org;
  insert into org_settings(org_id, version, schema_version, effective_from, settings, created_by)
  values (p_org, v, 1, case when st = 'setup' then least(p_effective_from, current_date) else p_effective_from end, p_settings, auth.uid());
  return v;
end $$;

create or replace function public.org_create_centre(p_name text, p_settings jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare o uuid; nm text;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  perform org_validate_settings(null::uuid, p_settings);
  insert into organisations(kind, preset, status, trading_name, created_by) values ('centre', 'centre', 'setup', trim(p_name), auth.uid()) returning id into o;
  select coalesce(nullif(p.full_name, ''), split_part(u.email, '@', 1)) into nm from auth.users u left join profiles p on p.id = u.id where u.id = auth.uid();
  insert into memberships(org_id, user_id, display_name, role) values (o, auth.uid(), coalesce(nm, 'Owner'), 'owner');
  insert into org_settings(org_id, version, schema_version, effective_from, settings, created_by) values (o, 1, 1, current_date, p_settings, auth.uid());
  insert into org_plans(org_id, plan_code, base_cents, per_student_cents, effective_from) values (o, 'centre', 10000, 40, current_date);
  return o;
end $$;

-- the rule read by the refund screens: four_eyes that can't be satisfied is read as "owner" (so nothing is ever stuck waiting for nobody)
create or replace function public.centre_refund_rule(p_org uuid, p_today date) returns text
language sql stable security definer set search_path = public as $$
  select case coalesce(org_settings_on(p_org, p_today)#>>'{billing,deposit,refund_approved_by}', 'owner')
           when 'staff' then 'staff'
           when 'four_eyes' then case when org_four_eyes_ready(p_org) then 'four_eyes' else 'owner' end
           else 'owner' end
$$;

-- ---------------------------------------------------------------------------------------------------
-- 6. in-app notices (the e-mail copy is SOON: it needs the email provider)
-- ---------------------------------------------------------------------------------------------------
create table if not exists public.org_notifications (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organisations(id) on delete cascade,
  user_id    uuid not null,                                   -- who it is for (an owner)
  kind       text not null,
  title      text not null,
  body       text not null,
  created_at timestamptz not null default now(),
  read_at    timestamptz
);
create index if not exists org_notifications_user on public.org_notifications(user_id, created_at desc);
alter table public.org_notifications enable row level security;
drop policy if exists own_read on public.org_notifications;
create policy own_read on public.org_notifications for select using (user_id = auth.uid());
revoke all on public.org_notifications from anon, authenticated;
grant select on public.org_notifications to authenticated;

create or replace function public.org_notification_dismiss(p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  update org_notifications set read_at = now() where id = p_id and user_id = auth.uid() and read_at is null;
  return found;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 7. the fall-back: when four_eyes stops being possible, the setting goes back to "owner approves" (internal)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.org_four_eyes_enforce(p_org uuid, p_cause text) returns boolean
language plpgsql security definer set search_path = public as $$
declare o record; today date; d date; cur record; changed int := 0; ow record; why text;
begin
  select id, kind, timezone into o from organisations where id = p_org;
  if o.id is null or o.kind <> 'centre' or coalesce(current_setting('td.deleting_org', true), '') = p_org::text then return false; end if;
  if org_four_eyes_ready(p_org) then return false; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_org::text, 11));
  today := (now() at time zone coalesce(o.timezone, 'Asia/Singapore'))::date;
  -- today, then every later day a settings row starts on: whatever is in force that day and still says four_eyes is replaced
  for d in select today union select distinct s.effective_from from org_settings s where s.org_id = p_org and s.effective_from > today order by 1 loop
    select s.* into cur from org_settings s where s.org_id = p_org and s.effective_from <= d order by s.effective_from desc, s.version desc limit 1;
    if cur.id is not null and cur.settings #>> '{billing,deposit,refund_approved_by}' = 'four_eyes' then
      insert into org_settings(org_id, version, schema_version, effective_from, settings, created_by)
      values (p_org, (select max(version) + 1 from org_settings where org_id = p_org), cur.schema_version, d,
              jsonb_set(cur.settings, '{billing,deposit,refund_approved_by}', '"owner"', true), auth.uid());
      changed := changed + 1;
    end if;
  end loop;
  if changed = 0 then return false; end if;
  why := case p_cause when 'removed' then 'a staff member was removed' when 'disabled' then 'a staff member was switched off'
                      when 'permission' then 'a staff member lost the permission it needs' else 'the second approver is no longer available' end;
  for ow in select m.user_id from memberships m where m.org_id = p_org and m.role = 'owner' and m.status = 'active' and m.user_id is not null loop
    insert into org_notifications(org_id, user_id, kind, title, body)
    values (p_org, ow.user_id, 'four_eyes_fallback', 'Refund approval is back to “the owner approves”',
            'The setting “someone other than the person who asked” needs a second approver, and ' || why || '. It has been changed back to “the owner approves”. '
            || 'Refund requests that were waiting for a second person can now be approved by you. Add a staff member who issues invoices and one who records payments, then choose the setting again.');
  end loop;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), 'org_four_eyes_fallback', 'org_settings', p_org::text, jsonb_build_object('refund_approved_by', 'four_eyes'),
          jsonb_build_object('refund_approved_by', 'owner', 'cause', coalesce(p_cause, 'unknown'), 'rows_written', changed));
  return true;
end $$;

create or replace function public.org_four_eyes_watch() returns trigger
language plpgsql security definer set search_path = public as $$
declare cause text;
begin
  if tg_op = 'DELETE' then
    if old.role = 'staff' then perform org_four_eyes_enforce(old.org_id, 'removed'); end if;
    return null;
  end if;
  if old.role = 'staff' then
    cause := case when new.role <> 'staff' or new.user_id is distinct from old.user_id then 'removed'
                  when new.status <> 'active' and old.status = 'active' then 'disabled'
                  when new.permissions is distinct from old.permissions then 'permission' end;
    if cause is not null then perform org_four_eyes_enforce(new.org_id, cause); end if;
  elsif old.role = 'owner' and (new.role <> 'owner' or new.status <> 'active') then
    perform org_four_eyes_enforce(new.org_id, 'removed');
  end if;
  return null;
end $$;
drop trigger if exists org_four_eyes_watch on public.memberships;
create trigger org_four_eyes_watch after update or delete on public.memberships for each row execute function public.org_four_eyes_watch();

-- ---------------------------------------------------------------------------------------------------
-- 8. function access
-- ---------------------------------------------------------------------------------------------------
revoke all on function public.centre_undo_blockers(uuid, uuid) from public, anon, authenticated;
revoke all on function public.org_four_eyes_status(uuid) from public, anon, authenticated;
revoke all on function public.org_four_eyes_ready(uuid) from public, anon, authenticated;
revoke all on function public.org_validate_settings(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.org_four_eyes_enforce(uuid, text) from public, anon, authenticated;
revoke all on function public.org_four_eyes_watch() from public, anon, authenticated;
revoke all on function public.centre_undo_application(uuid, text) from public, anon;
revoke all on function public.centre_invoice_applications(uuid) from public, anon;
revoke all on function public.org_notification_dismiss(uuid) from public, anon;
grant execute on function public.centre_undo_application(uuid, text), public.centre_invoice_applications(uuid), public.org_notification_dismiss(uuid) to authenticated, service_role;
