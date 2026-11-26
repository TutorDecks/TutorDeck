-- Undo of migration_centre_credit_undo.sql (T4 step S5b): removes Undo for applied credit / deposit, the four-eyes guard and the notices table.
-- DESTRUCTIVE for the notices (org_notifications is dropped). Money records are NOT touched: if any application was ever undone (ledger rows of kind
-- 'application_undone', or reversal payments with method family_credit / deposit) the widened ledger checks are KEPT, because narrowing them would
-- destroy an issued record. Run the undo chain in reverse order (this one comes BEFORE migration_centre_late_fees_down.sql).
drop trigger if exists org_four_eyes_watch on public.memberships;
drop function if exists public.org_four_eyes_watch();
drop function if exists public.org_four_eyes_enforce(uuid, text);
drop function if exists public.org_notification_dismiss(uuid);
drop table if exists public.org_notifications cascade;
drop function if exists public.centre_invoice_applications(uuid);
drop function if exists public.centre_undo_application(uuid, text);
drop function if exists public.centre_undo_blockers(uuid, uuid);

-- the S5 rule reader and the foundation settings functions, as they were
create or replace function public.centre_refund_rule(p_org uuid, p_today date) returns text
language sql stable security definer set search_path = public as $$
  select case coalesce(org_settings_on(p_org, p_today)#>>'{billing,deposit,refund_approved_by}', 'owner') when 'staff' then 'staff' when 'four_eyes' then 'four_eyes' else 'owner' end
$$;
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
drop function if exists public.org_validate_settings(uuid, jsonb);
drop function if exists public.org_four_eyes_ready(uuid);
drop function if exists public.org_four_eyes_status(uuid);

create or replace function public.centre_internal_method_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'reversal' and new.method in ('family_credit', 'deposit') then
    raise exception 'NOT_ALLOWED: credit or deposit that was applied to an invoice can''t be reversed; issue a credit note on the invoice instead (any excess goes back to the family credit)' using errcode = '42501';
  end if;
  return new;
end $$;

do $$ begin
  if exists (select 1 from public.centre_family_credit where kind = 'application_undone') or exists (select 1 from public.centre_deposit_ledger where kind = 'application_undone')
     or exists (select 1 from public.centre_payments where kind = 'reversal' and method in ('family_credit', 'deposit')) then
    raise notice 'Applications were undone: the widened ledger checks are kept';
  else
    alter table public.centre_family_credit drop constraint if exists centre_family_credit_kind_s5b;
    alter table public.centre_family_credit drop constraint if exists centre_family_credit_sign_s5b;
    alter table public.centre_family_credit add constraint centre_family_credit_kind_s5
      check (kind in ('overpayment', 'credit_note_excess', 'payment_reversal', 'excess_release', 'refund', 'applied'));
    alter table public.centre_family_credit add constraint centre_family_credit_sign_s5 check ((kind in ('overpayment', 'credit_note_excess')) = (cents > 0));
    alter table public.centre_deposit_ledger drop constraint if exists centre_deposit_ledger_kind_s5b;
    alter table public.centre_deposit_ledger drop constraint if exists centre_deposit_ledger_sign_s5b;
    alter table public.centre_deposit_ledger add constraint centre_deposit_ledger_kind_s4
      check (kind in ('received', 'reversal', 'waived', 'adjusted', 'applied', 'forfeited', 'refunded', 'transferred_out', 'transferred_in', 'opening_balance'));
    alter table public.centre_deposit_ledger add constraint centre_deposit_ledger_sign_s4
      check (case kind when 'received' then cents > 0 when 'opening_balance' then cents > 0 when 'transferred_in' then cents > 0 when 'waived' then cents > 0
                       when 'reversal' then cents < 0 when 'applied' then cents < 0 when 'forfeited' then cents < 0 when 'refunded' then cents < 0
                       when 'transferred_out' then cents < 0 else true end);
  end if;
end $$;
