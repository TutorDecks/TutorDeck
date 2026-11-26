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
