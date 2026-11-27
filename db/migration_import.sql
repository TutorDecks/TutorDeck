-- =====================================================================================================
-- T33 I1 — centre import, stage A (families, students, tutors, weekly lessons)        undo: migration_import_down.sql
-- =====================================================================================================
-- Run order everywhere: org_foundation → billing → attendance → tutor_access → org_delete → function_lockdown → org_separation → import.
-- Needs migration_tutor_access.sql (memberships.id + organisation key). Run on the DEV project first. Safe to run twice.
--
-- WHAT THIS ADDS
--   1. Import bookkeeping: import_batches (one row per committed import) and import_items (one row per record an import created,
--      with the owner's own code for it and a fingerprint of the row as it was created). No cell values are kept: ids, codes, counts.
--   2. import_dry_run(org, payload)            check everything, write NOTHING (works on any centre the caller owns)
--      import_commit(org, payload, hashes)     the same checks, then ONE all-or-nothing transaction that creates the records
--      import_existing(org)                    the owner's codes already imported (so a later file can point at them)
--      import_history(org)                     batches, newest first, with "can be undone until"
--      import_undo_preview(batch) / import_undo(batch)   remove what a batch created, but ONLY rows nobody has since edited, marked or
--                                              invoiced; everything else is kept and reported
--   3. A centre setting billing.starts_from (a date): the invoice run ignores lessons before it (org_billing_start(org) reads it).
--   4. Three optional columns the import fills: students.online_link, students.start_date, recurring_slots.taught_by (the tutor of
--      a weekly lesson: memberships.id, same organisation only; a removed tutor leaves the slot with no tutor).
--
-- RULES (owner's decisions, 2026-11-26)
--   * OWNER ONLY, CENTRES ONLY. Anyone else (staff, tutor, parent, anonymous, a solo tutor, a non-member) gets NOT_FOUND, same as a
--     missing organisation, so nothing can be probed.
--   * CREATE-ONLY: never updates or deletes existing rows (undo deletes only rows its own batch created). A row whose code already
--     exists is skipped; if its content differs it is skipped with a warning (the import never overwrites).
--   * IDEMPOTENT: the match key is the owner's own code per row: family_ref, student_ref, tutor email, student+tutor+day+start.
--     The same file twice creates nothing the second time and records no batch.
--   * The browser is never trusted: every rule is checked again here, and problems come back as DATA (file, line, column, code),
--     never as an exception message, so no cell value can land in a database log.
--   * No email, no queue, no login is created. Tutors become memberships with status 'invited' and no user (org_invite, the screen's rule).
--     Lessons are not created either (the weekly lesson is the recurring slot; lessons come from the usual generation). Past lessons,
--     deposits, unpaid invoices and pay rates are NOT part of stage A.
--   * Per-row audit rows are switched off while an import or its undo runs (a batch of 3,000 rows would copy every name into the
--     audit log, which an undo could never remove). Instead ONE audit row per commit and per undo: who, when, counts, file hashes.
-- =====================================================================================================

-- ---------------------------------------------------------------- columns the import fills
alter table public.students add column if not exists online_link text;
alter table public.students add column if not exists start_date date;
alter table public.recurring_slots add column if not exists taught_by uuid;
create unique index if not exists memberships_id_org on public.memberships(id, org_id);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'recurring_slots_taught_by_same_org') then
    alter table public.recurring_slots add constraint recurring_slots_taught_by_same_org
      foreign key (taught_by, org_id) references public.memberships(id, org_id) on delete set null (taught_by);
  end if;
end $$;
create index if not exists recurring_slots_taught_by on public.recurring_slots(taught_by) where taught_by is not null;

-- ---------------------------------------------------------------- bookkeeping tables (no browser write policy at all)
create table if not exists public.import_batches (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organisations(id) on delete cascade,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  stage        text not null default 'A',
  status       text not null default 'committed' check (status in ('committed','partly_undone','undone')),
  counts       jsonb not null default '{}',
  file_hashes  jsonb not null default '{}',
  undo_until   timestamptz not null,
  undone_at    timestamptz,
  undo_report  jsonb,
  unique (id, org_id)
);
create index if not exists import_batches_org on public.import_batches(org_id, created_at desc);

create table if not exists public.import_items (
  org_id       uuid not null references public.organisations(id) on delete cascade,
  batch_id     uuid not null,
  kind         text not null check (kind in ('family','guardian','student','tutor','slot')),
  key          text,                                    -- the owner's own code, lowercased; null for guardians
  tbl          text not null check (tbl in ('households','guardians','students','memberships','recurring_slots')),
  row_id       uuid not null,
  fp           text not null,                           -- fingerprint of the row as the import created it
  kept_reason  text,                                    -- set by an undo that could not remove it
  primary key (batch_id, tbl, row_id),
  foreign key (batch_id, org_id) references public.import_batches(id, org_id) on delete cascade
);
create unique index if not exists import_items_key on public.import_items(org_id, kind, key) where key is not null;
create index if not exists import_items_row on public.import_items(tbl, row_id);

alter table public.import_batches enable row level security;
alter table public.import_items enable row level security;
drop policy if exists import_batches_read on public.import_batches;
create policy import_batches_read on public.import_batches for select using (org_can(org_id, 'owner'));
-- import_items: no policy (the owner reads history through import_history); nobody writes either table except the functions below
revoke all on public.import_batches, public.import_items from anon, authenticated;
grant select on public.import_batches to authenticated;

-- ---------------------------------------------------------------- the billing start setting
-- billing.starts_from = a date (YYYY-MM-DD) or empty/null. The invoice run ignores lessons dated before it.
create or replace function public.org_validate_settings(s jsonb) returns void language plpgsql immutable set search_path = public as $$
declare k text; v jsonb; r record; bs text;
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
  -- T4 S0 (centre money options). Every new key is optional, so settings saved before this migration stay valid;
  -- a key that is present must be right. assets/js/org-settings.js holds the labels and defaults (tests/org-settings.test.js compares the enums).
  if s#>>'{tutor_pay,rate_model}' is not null and s#>>'{tutor_pay,rate_model}' not in ('per_lesson','per_hour','per_student_lesson','monthly_fixed','percent_of_fee') then raise exception 'Unknown tutor pay rate'; end if;
  if s#>>'{tutor_pay,percent_base}' is not null and s#>>'{tutor_pay,percent_base}' not in ('billed_after_discounts','list_price') then raise exception 'Unknown percentage pay base'; end if;
  if s#>>'{tutor_pay,part_payments}' is not null and s#>>'{tutor_pay,part_payments}' not in ('after_full','pro_rata') then raise exception 'Unknown part-payment pay rule'; end if;
  if s#>>'{tutor_pay,cancelled_lessons}' is not null and s#>>'{tutor_pay,cancelled_lessons}' not in ('pay_if_charged','pay_rate','pay_nothing') then raise exception 'Unknown cancelled-lesson pay rule'; end if;
  if s#>>'{tutor_pay,group_count}' is not null and s#>>'{tutor_pay,group_count}' not in ('attended','enrolled') then raise exception 'Unknown group pay count'; end if;
  if s#>>'{billing,deposit,mode}' is not null and s#>>'{billing,deposit,mode}' not in ('none','fixed','percent_first_month') then raise exception 'Unknown deposit mode'; end if;
  if s#>>'{billing,deposit,due}' is not null and s#>>'{billing,deposit,due}' not in ('with_first_invoice','before_first_lesson') then raise exception 'Unknown deposit due rule'; end if;
  if s#>>'{billing,deposit,waived_by}' is not null and s#>>'{billing,deposit,waived_by}' not in ('owner','issue_invoices','nobody') then raise exception 'Unknown deposit waiver rule'; end if;
  if s#>>'{billing,deposit,release}' is not null and s#>>'{billing,deposit,release}' not in ('refund_full','refund_less_unpaid','admin_decides') then raise exception 'Unknown deposit release rule'; end if;
  if s#>>'{billing,deposit,refund_approved_by}' is not null and s#>>'{billing,deposit,refund_approved_by}' not in ('owner','staff','four_eyes') then raise exception 'Unknown deposit refund approver'; end if;
  if s#>>'{billing,late_fee,repeat}' is not null and s#>>'{billing,late_fee,repeat}' not in ('none','once','monthly') then raise exception 'Unknown late fee repeat'; end if;
  if s#>>'{billing,late_fee,type}' is not null and s#>>'{billing,late_fee,type}' not in ('fixed','percent') then raise exception 'Unknown late fee type'; end if;
  if s#>>'{billing,late_fee,show_as}' is not null and s#>>'{billing,late_fee,show_as}' not in ('next_invoice_line','own_invoice') then raise exception 'Unknown late fee placement'; end if;
  if s#>>'{billing,late_fee,waived_by}' is not null and s#>>'{billing,late_fee,waived_by}' not in ('owner','issue_invoices') then raise exception 'Unknown late fee waiver rule'; end if;
  if s#>>'{lessons,class_type}' is not null and s#>>'{lessons,class_type}' not in ('one_to_one','group','both') then raise exception 'Unknown class type'; end if;
  foreach k in array array['{billing,deposit,taxable}','{billing,deposit,top_up}','{billing,deposit,set_off_unpaid}','{billing,deposit,final_month}','{billing,trials,charged}'] loop
    v := s #> k::text[];
    if v is not null and jsonb_typeof(v) not in ('boolean','null') then raise exception 'Setting % must be yes or no', k; end if;
  end loop;
  for r in select * from (values
    ('{billing,deposit,percent_bp}', 0, 10000, 'Deposit percentage must be between 0% and 100%'),
    ('{billing,deposit,forfeit_notice_days}', 0, 90, 'Deposit notice must be 0-90 days'),
    ('{billing,late_fee,percent_bp}', 0, 10000, 'Late fee percentage must be between 0% and 100%'),
    ('{billing,late_fee,after_days}', 0, 365, 'Late fee grace period must be 0-365 days'),
    ('{billing,late_fee,cap_cents}', 0, 100000000, 'Late fee limit must be a whole number of cents, 0 to 100000000'),
    ('{billing,late_fee,amount_cents}', 0, 100000000, 'Late fee amount must be a whole number of cents, 0 to 100000000'),
    ('{billing,one_off_fees,deposit_cents}', 0, 100000000, 'Deposit amount must be a whole number of cents, 0 to 100000000'),
    ('{profile,next_invoice_number}', 1, 999999999, 'Next invoice number must be a whole number, 1 or more')
  ) as c(p, lo, hi, msg) loop
    v := s #> r.p::text[];
    if v is not null and jsonb_typeof(v) <> 'null' and not (case when jsonb_typeof(v) = 'number' and v::text ~ '^[0-9]{1,12}$'
         then (v#>>'{}')::bigint between r.lo and r.hi else false end) then
      raise exception '%', r.msg; end if;
  end loop;
  -- a percentage mode needs a real percentage (1 = 0.01%)
  if s#>>'{billing,deposit,mode}' = 'percent_first_month' and coalesce((s#>>'{billing,deposit,percent_bp}')::int, 0) < 1 then
    raise exception 'Deposit percentage must be between 0.01%% and 100%%'; end if;
  if s#>>'{billing,late_fee,type}' = 'percent' and coalesce((s#>>'{billing,late_fee,percent_bp}')::int, 0) < 1 then
    raise exception 'Late fee percentage must be between 0.01%% and 100%%'; end if;
  -- T6 step 2 (tutors change their own lessons). Every key is optional; a key that is present must be right. assets/js/org-settings.js has the labels and defaults.
  if s#>>'{lessons,timetable_editing}' is not null and s#>>'{lessons,timetable_editing}' not in ('admin_only','tutors_direct','tutors_propose') then raise exception 'Unknown timetable editing setting'; end if;
  if s#>>'{lessons,notify_family}' is not null and s#>>'{lessons,notify_family}' not in ('off','list_for_admin') then raise exception 'Unknown family notice setting'; end if;
  if s#>'{lessons,tutors_edit}' is not null and jsonb_typeof(s#>'{lessons,tutors_edit}') not in ('object','null') then raise exception 'Tutor editing switches are malformed'; end if;
  foreach k in array array['{lessons,tutors_edit,postpone}','{lessons,tutors_edit,cancel}','{lessons,tutors_edit,weekly_slots}','{lessons,tutors_edit,generate}','{lessons,tutors_edit,one_off}','{lessons,tutors_edit,link}'] loop
    v := s #> k::text[];
    if v is not null and jsonb_typeof(v) not in ('boolean','null') then raise exception 'Setting % must be yes or no', k; end if;
  end loop;
  for r in select * from (values
    ('{lessons,min_notice_hours}', 0, 168, 'Notice before a change must be 0-168 hours'),
    ('{lessons,max_changes_per_month}', 0, 500, 'Changes per tutor per month must be 0-500 (0 = no limit)')
  ) as c(p, lo, hi, msg) loop
    v := s #> r.p::text[];
    if v is not null and jsonb_typeof(v) <> 'null' and not (case when jsonb_typeof(v) = 'number' and v::text ~ '^[0-9]{1,4}$'
         then (v#>>'{}')::bigint between r.lo and r.hi else false end) then
      raise exception '%', r.msg; end if;
  end loop;
  -- billing starts from: empty, or a real date between 2020-01-01 and 2100-01-01
  if s#>'{billing,starts_from}' is not null and jsonb_typeof(s#>'{billing,starts_from}') <> 'null' then
    if jsonb_typeof(s#>'{billing,starts_from}') <> 'string' then raise exception 'Billing start must be a date'; end if;
    bs := s#>>'{billing,starts_from}';
    if bs <> '' then
      if bs !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Billing start must be a date (YYYY-MM-DD)'; end if;
      begin perform make_date(substr(bs,1,4)::int, substr(bs,6,2)::int, substr(bs,9,2)::int);
      exception when others then raise exception 'Billing start must be a real date'; end;
      if bs < '2020-01-01' or bs > '2100-01-01' then raise exception 'Billing start must be between 2020 and 2100'; end if;
    end if;
  end if;
end $$;

-- The date billing starts from, as of today (null = every lesson can be billed). Read as of TODAY: it is a cut-off, not a fee rule.
create or replace function public.org_billing_start(p_org uuid) returns date
language plpgsql stable security definer set search_path = public as $$
declare v text;
begin
  v := org_settings_on(p_org, current_date) #>> '{billing,starts_from}';
  if v is null or v = '' or v !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then return null; end if;
  return v::date;
end $$;
revoke all on function public.org_billing_start(uuid) from public, anon;
grant execute on function public.org_billing_start(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------- small internal helpers
create or replace function public.import_fp(j jsonb) returns text language sql immutable set search_path = public as $$
  select md5((j - 'gcal_event_id')::text) $$;
create or replace function public.import_try_date(s text) returns date language plpgsql immutable set search_path = public as $$
begin
  if s is null or s !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then return null; end if;
  return make_date(substr(s,1,4)::int, substr(s,6,2)::int, substr(s,9,2)::int);
exception when others then return null; end $$;
create or replace function public.import_minutes(s text) returns int language sql immutable set search_path = public as $$
  select case when s ~ '^([01]?[0-9]|2[0-3]):[0-5][0-9]$' then split_part(s, ':', 1)::int * 60 + split_part(s, ':', 2)::int end $$;
create or replace function public.import_row_exists(p_tbl text, p_id uuid) returns boolean language sql stable set search_path = public as $$
  select case p_tbl when 'households' then exists (select 1 from households where id = p_id)
                    when 'guardians' then exists (select 1 from guardians where id = p_id)
                    when 'students' then exists (select 1 from students where id = p_id)
                    when 'memberships' then exists (select 1 from memberships where id = p_id)
                    when 'recurring_slots' then exists (select 1 from recurring_slots where id = p_id) else false end $$;
-- a lesson somebody has worked on: marked, charged, paid, noted, moved, hand-added or on an invoice
create or replace function public.import_lesson_touched(l lessons) returns boolean language sql stable set search_path = public as $$
  select l.status <> 'scheduled' or l.attendance is not null or l.paid or l.compensation is not null or l.postponed or l.one_off or l.trial
      or l.topics is not null or l.homework is not null or l.remarks is not null
      or exists (select 1 from invoices i where i.org_id = l.org_id and jsonb_typeof(i.data->'lesson_ids') = 'array' and i.data->'lesson_ids' ? l.id::text) $$;

-- ---------------------------------------------------------------- the run: check everything, and (commit) write it, in ONE call
-- p_payload = { families:[…], students:[…], tutors:[…], weekly_lessons:[…] }, built by assets/js/import-core.js (buildPayload).
-- Returns jsonb { ok, errors:[{file,line,column,code}] (first 300), error_count, warnings, created:{…}, skipped:{…}, batch_id, undo_until }.
create or replace function public.import_run_a(p_org uuid, p_payload jsonb, p_commit boolean, p_hashes jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid(); v_n int; v_errs jsonb; v_warn jsonb; v_batch uuid := gen_random_uuid(); v_until timestamptz := now() + interval '7 days';
  v_created jsonb; v_skipped jsonb; v_hashes jsonb; tr record; m uuid; tn text;
begin
  if me is null or not org_can(p_org, 'owner')
     or not exists (select 1 from organisations o where o.id = p_org and o.kind = 'centre' and o.status <> 'suspended') then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('import:' || p_org::text, 0));    -- one import per centre at a time

  -- (only drop what an earlier call in this same transaction left: DROP is refused in a read-only transaction, CREATE TEMP is not)
  foreach tn in array array['imp_f','imp_s','imp_t','imp_w','imp_err','imp_live','imp_tut','imp_nf','imp_ng','imp_ns','imp_nt','imp_nw','imp_wres'] loop
    if to_regclass('pg_temp.' || tn) is not null then execute 'drop table pg_temp.' || tn; end if;
  end loop;
  create temp table imp_err(file text, line int, col text, code text) on commit drop;
  if jsonb_typeof(p_payload) is distinct from 'object' then
    return jsonb_build_object('ok', false, 'errors', jsonb_build_array(jsonb_build_object('file','payload','line',0,'column','','code','BAD_PAYLOAD')), 'error_count', 1);
  end if;
  if coalesce(jsonb_array_length(p_payload->'families'), 0) > 18000 or coalesce(jsonb_array_length(p_payload->'students'), 0) > 3000
     or coalesce(jsonb_array_length(p_payload->'tutors'), 0) > 1500 or coalesce(jsonb_array_length(p_payload->'weekly_lessons'), 0) > 20000 then
    return jsonb_build_object('ok', false, 'errors', jsonb_build_array(jsonb_build_object('file','payload','line',0,'column','','code','TOO_MANY_ROWS')), 'error_count', 1);
  end if;

  -- ---- load (all cells as trimmed text; empty = null). A payload of the wrong shape is refused as data.
  begin
    create temp table imp_f on commit drop as
      select r.line, nullif(btrim(r.family_ref), '') family_ref, lower(nullif(btrim(r.family_ref), '')) fk, nullif(btrim(r.family_name), '') family_name,
             nullif(btrim(r.guardian_name), '') guardian_name, nullif(btrim(r.relation), '') relation, nullif(btrim(r.phone), '') phone,
             lower(nullif(btrim(r.email), '')) email, r.main
      from jsonb_to_recordset(coalesce(p_payload->'families', '[]'::jsonb)) as r(line int, family_ref text, family_name text, guardian_name text, relation text, phone text, email text, main boolean);
    create temp table imp_s on commit drop as
      select r.line, nullif(btrim(r.student_ref), '') student_ref, lower(nullif(btrim(r.student_ref), '')) sk, nullif(btrim(r.family_ref), '') family_ref,
             lower(nullif(btrim(r.family_ref), '')) fk, nullif(btrim(r.student_name), '') student_name, nullif(btrim(r.level), '') level,
             nullif(btrim(r.lesson_location), '') location, nullif(btrim(r.online_link), '') online_link, nullif(btrim(r.start_date), '') start_date,
             nullif(btrim(r.notes), '') notes
      from jsonb_to_recordset(coalesce(p_payload->'students', '[]'::jsonb)) as r(line int, student_ref text, family_ref text, student_name text, level text, lesson_location text, online_link text, start_date text, notes text);
    create temp table imp_t on commit drop as
      select r.line, lower(nullif(btrim(r.tutor_email), '')) email, nullif(btrim(r.tutor_name), '') tutor_name, nullif(btrim(r.phone), '') phone,
             nullif(btrim(r.subjects), '') subjects, nullif(btrim(r.employment), '') employment
      from jsonb_to_recordset(coalesce(p_payload->'tutors', '[]'::jsonb)) as r(line int, tutor_email text, tutor_name text, phone text, subjects text, employment text);
    create temp table imp_w on commit drop as
      select r.line, nullif(btrim(r.student_ref), '') student_ref, lower(nullif(btrim(r.student_ref), '')) sk, lower(nullif(btrim(r.tutor_email), '')) email,
             r.day, import_minutes(nullif(btrim(r.start), '')) smin, import_minutes(nullif(btrim(r."end"), '')) emin,
             nullif(btrim(r.subject), '') subject, nullif(btrim(r.level), '') level, r.rate_cents
      from jsonb_to_recordset(coalesce(p_payload->'weekly_lessons', '[]'::jsonb)) as r(line int, student_ref text, tutor_email text, day int, start text, "end" text, subject text, level text, rate_cents int);
  exception when others then
    return jsonb_build_object('ok', false, 'errors', jsonb_build_array(jsonb_build_object('file','payload','line',0,'column','','code','BAD_PAYLOAD')), 'error_count', 1);
  end;

  -- ---- what is already in this centre (live = the imported row still exists)
  create temp table imp_live on commit drop as
    select i.kind, i.key, i.tbl, i.row_id from import_items i
    where i.org_id = p_org and i.key is not null and import_row_exists(i.tbl, i.row_id);
  create temp table imp_tut on commit drop as
    select m.id, m.role, m.status, lower(coalesce(m.invited_email, (select u.email from auth.users u where u.id = m.user_id))) em
    from memberships m where m.org_id = p_org;
  create index on imp_tut(em);

  -- =========================================================== validation (set-based; every rule the page also checks)
  -- families.csv
  insert into imp_err select 'families', line, 'family_ref', 'REQUIRED' from imp_f where family_ref is null;
  insert into imp_err select 'families', line, 'family_ref', 'TOO_LONG' from imp_f where char_length(family_ref) > 40;
  insert into imp_err select 'families', line, 'family_name', 'REQUIRED' from imp_f where family_name is null;
  insert into imp_err select 'families', line, 'family_name', 'TOO_LONG' from imp_f where char_length(family_name) > 120;
  insert into imp_err select 'families', line, 'guardian_name', 'REQUIRED' from imp_f where guardian_name is null;
  insert into imp_err select 'families', line, 'guardian_name', 'TOO_LONG' from imp_f where char_length(guardian_name) > 120;
  insert into imp_err select 'families', line, 'relation', 'TOO_LONG' from imp_f where char_length(relation) > 40;
  insert into imp_err select 'families', line, 'phone', 'BAD_PHONE' from imp_f where phone is not null and regexp_replace(phone, '[\s\-()]', '', 'g') !~ '^\+?[0-9]{6,15}$';
  insert into imp_err select 'families', line, 'email', 'BAD_EMAIL' from imp_f where email is not null and (email !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' or char_length(email) > 254);
  insert into imp_err select 'families', line, 'phone', 'NEED_CONTACT' from imp_f where phone is null and email is null and guardian_name is not null;
  insert into imp_err select 'families', f.line, 'family_name', 'FAMILY_NAME_MISMATCH' from imp_f f
    where f.fk is not null and f.family_name is not null and f.family_name <> (select x.family_name from imp_f x where x.fk = f.fk and x.family_name is not null order by x.line limit 1);
  insert into imp_err select 'families', line, 'guardian_name', 'TOO_MANY_GUARDIANS' from
    (select line, row_number() over (partition by fk order by line) n from imp_f where fk is not null) q where n > 6;
  insert into imp_err select 'families', line, 'main', 'MULTIPLE_MAIN' from
    (select line, row_number() over (partition by fk order by line) n from imp_f where fk is not null and main) q where n > 1;
  insert into imp_err select 'families', line, 'guardian_name', 'DUPLICATE_ROW' from
    (select line, row_number() over (partition by fk, lower(guardian_name), phone, email order by line) n from imp_f where fk is not null and guardian_name is not null) q where n > 1;

  -- students.csv
  insert into imp_err select 'students', line, 'student_ref', 'REQUIRED' from imp_s where student_ref is null;
  insert into imp_err select 'students', line, 'student_ref', 'TOO_LONG' from imp_s where char_length(student_ref) > 40;
  insert into imp_err select 'students', line, 'family_ref', 'REQUIRED' from imp_s where family_ref is null;
  insert into imp_err select 'students', line, 'student_name', 'REQUIRED' from imp_s where student_name is null;
  insert into imp_err select 'students', line, 'student_name', 'TOO_LONG' from imp_s where char_length(student_name) > 120;
  insert into imp_err select 'students', line, 'level', 'TOO_LONG' from imp_s where char_length(level) > 40;
  insert into imp_err select 'students', line, 'lesson_location', 'TOO_LONG' from imp_s where char_length(location) > 120;
  insert into imp_err select 'students', line, 'online_link', 'BAD_URL' from imp_s where online_link is not null and (online_link !~* '^https://[^\s/]+\.[^\s/]+\S*$' or char_length(online_link) > 300);
  insert into imp_err select 'students', line, 'start_date', 'REQUIRED' from imp_s where start_date is null;
  insert into imp_err select 'students', line, 'start_date', 'BAD_DATE' from imp_s where start_date is not null and import_try_date(start_date) is null;
  insert into imp_err select 'students', line, 'start_date', 'FUTURE_DATE' from imp_s where import_try_date(start_date) > current_date + 365;
  insert into imp_err select 'students', line, 'notes', 'TOO_LONG' from imp_s where char_length(notes) > 1000;
  insert into imp_err select 'students', line, 'student_ref', 'DUPLICATE_KEY' from
    (select line, row_number() over (partition by sk order by line) n from imp_s where sk is not null) q where n > 1;
  insert into imp_err select 'students', s.line, 'family_ref', 'UNKNOWN_FAMILY' from imp_s s
    where s.fk is not null and not exists (select 1 from imp_f f where f.fk = s.fk) and not exists (select 1 from imp_live l where l.kind = 'family' and l.key = s.fk);
  insert into imp_err select 'students', line, 'student_name', 'DUPLICATE_STUDENT_NAME' from
    (select line, row_number() over (partition by fk, lower(student_name) order by line) n from imp_s where fk is not null and student_name is not null) q where n > 1;

  -- tutors.csv
  insert into imp_err select 'tutors', line, 'tutor_email', 'REQUIRED' from imp_t where email is null;
  insert into imp_err select 'tutors', line, 'tutor_email', 'BAD_EMAIL' from imp_t where email is not null and (email !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' or char_length(email) > 254);
  insert into imp_err select 'tutors', line, 'tutor_name', 'REQUIRED' from imp_t where tutor_name is null;
  insert into imp_err select 'tutors', line, 'tutor_name', 'TOO_LONG' from imp_t where char_length(tutor_name) > 120;
  insert into imp_err select 'tutors', line, 'phone', 'BAD_PHONE' from imp_t where phone is not null and regexp_replace(phone, '[\s\-()]', '', 'g') !~ '^(\+?65)?[689][0-9]{7}$';
  insert into imp_err select 'tutors', line, 'subjects', 'TOO_LONG' from imp_t where char_length(subjects) > 200;
  insert into imp_err select 'tutors', line, 'employment', 'REQUIRED' from imp_t where employment is null;
  insert into imp_err select 'tutors', line, 'employment', 'BAD_VALUE' from imp_t where employment is not null and employment not in ('employee', 'freelancer');
  insert into imp_err select 'tutors', line, 'tutor_email', 'DUPLICATE_KEY' from
    (select line, row_number() over (partition by email order by line) n from imp_t where email is not null) q where n > 1;
  insert into imp_err select 'tutors', t.line, 'tutor_email', 'TUTOR_OTHER_ROLE' from imp_t t
    where t.email is not null and exists (select 1 from imp_tut x where x.em = t.email and x.role <> 'tutor');

  -- weekly_lessons.csv
  insert into imp_err select 'weekly_lessons', line, 'student_ref', 'REQUIRED' from imp_w where student_ref is null;
  insert into imp_err select 'weekly_lessons', line, 'tutor_email', 'REQUIRED' from imp_w where email is null;
  insert into imp_err select 'weekly_lessons', line, 'tutor_email', 'BAD_EMAIL' from imp_w where email is not null and (email !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' or char_length(email) > 254);
  insert into imp_err select 'weekly_lessons', line, 'day', 'BAD_VALUE' from imp_w where day is null or day not between 0 and 6;
  insert into imp_err select 'weekly_lessons', line, 'start', 'BAD_TIME' from imp_w where smin is null;
  insert into imp_err select 'weekly_lessons', line, 'end', 'BAD_TIME' from imp_w where emin is null;
  insert into imp_err select 'weekly_lessons', line, 'end', 'END_BEFORE_START' from imp_w where smin is not null and emin is not null and emin <= smin;
  insert into imp_err select 'weekly_lessons', line, 'end', 'BAD_DURATION' from imp_w where smin is not null and emin is not null and emin > smin and (emin - smin < 15 or emin - smin > 480);
  insert into imp_err select 'weekly_lessons', line, 'subject', 'TOO_LONG' from imp_w where char_length(subject) > 60;
  insert into imp_err select 'weekly_lessons', line, 'level', 'TOO_LONG' from imp_w where char_length(level) > 40;
  insert into imp_err select 'weekly_lessons', line, 'family_rate_per_hour', 'REQUIRED' from imp_w where rate_cents is null;
  insert into imp_err select 'weekly_lessons', line, 'family_rate_per_hour', 'OUT_OF_RANGE' from imp_w where rate_cents is not null and rate_cents not between 0 and 100000;
  insert into imp_err select 'weekly_lessons', w.line, 'student_ref', 'UNKNOWN_STUDENT' from imp_w w
    where w.sk is not null and not exists (select 1 from imp_s s where s.sk = w.sk) and not exists (select 1 from imp_live l where l.kind = 'student' and l.key = w.sk);
  insert into imp_err select 'weekly_lessons', w.line, 'tutor_email', 'UNKNOWN_TUTOR' from imp_w w
    where w.email is not null and not exists (select 1 from imp_t t where t.email = w.email) and not exists (select 1 from imp_tut x where x.em = w.email and x.role = 'tutor');
  insert into imp_err select 'weekly_lessons', w.line, 'tutor_email', 'TUTOR_NOT_AVAILABLE' from imp_w w
    where w.email is not null and exists (select 1 from imp_tut x where x.em = w.email and x.role = 'tutor' and x.status = 'disabled');
  insert into imp_err select 'weekly_lessons', line, 'start', 'DUPLICATE_KEY' from
    (select line, row_number() over (partition by sk, email, day, smin order by line) n from imp_w where sk is not null and email is not null and day is not null and smin is not null) q where n > 1;
  -- a student cannot have two overlapping lessons: inside the file, and against weekly lessons already in the centre
  insert into imp_err select 'weekly_lessons', b.line, 'start', 'SLOT_CLASH' from imp_w a join imp_w b
    on a.sk = b.sk and a.day = b.day and a.line < b.line and a.smin < b.emin and b.smin < a.emin and not (a.email = b.email and a.smin = b.smin)
    where a.smin is not null and b.smin is not null and a.emin > a.smin and b.emin > b.smin;
  insert into imp_err select 'weekly_lessons', w.line, 'start', 'SLOT_CLASH' from imp_w w
    join imp_live l on l.kind = 'student' and l.key = w.sk
    join recurring_slots x on x.student_id = l.row_id and x.active and x.weekday = w.day
    where w.smin is not null and w.emin > w.smin and x.start_time < (w.emin || ' minutes')::interval + time '00:00' and (w.smin || ' minutes')::interval + time '00:00' < x.end_time
      and not exists (select 1 from import_items it where it.kind = 'slot' and it.row_id = x.id and it.key = w.sk || '|' || w.email || '|' || w.day || '|' || lpad((w.smin / 60)::text, 2, '0') || ':' || lpad((w.smin % 60)::text, 2, '0'));

  select count(*) into v_n from (select distinct file, line, col, code from imp_err) e;
  select coalesce(jsonb_agg(jsonb_build_object('file', file, 'line', line, 'column', col, 'code', code) order by file, line, code), '[]') into v_errs
    from (select distinct file, line, col, code from imp_err order by file, line, code limit 300) e;
  if v_n > 0 then
    return jsonb_build_object('ok', false, 'errors', v_errs, 'error_count', v_n);
  end if;

  -- =========================================================== what would be created (the same lists the commit uses)
  create temp table imp_nf on commit drop as
    select distinct on (f.fk) f.fk, f.family_name, gen_random_uuid() hid from imp_f f
    where not exists (select 1 from imp_live l where l.kind = 'family' and l.key = f.fk) order by f.fk, f.line;
  create temp table imp_ng on commit drop as
    select f.line, f.fk, f.guardian_name, f.relation, f.phone, f.email, nf.hid, gen_random_uuid() gid,
           row_number() over (partition by f.fk order by (not coalesce(f.main, false)), f.line) rn
    from imp_f f join imp_nf nf on nf.fk = f.fk;
  create temp table imp_ns on commit drop as
    select s.*, gen_random_uuid() sid, coalesce(nf.hid, (select l.row_id from imp_live l where l.kind = 'family' and l.key = s.fk)) hid
    from imp_s s left join imp_nf nf on nf.fk = s.fk
    where not exists (select 1 from imp_live l where l.kind = 'student' and l.key = s.sk);
  create temp table imp_nt on commit drop as
    select t.*, gen_random_uuid() mid from imp_t t where not exists (select 1 from imp_tut x where x.em = t.email);
  create temp table imp_wres on commit drop as
    select w.line, w.sk, w.email, w.day, w.smin, w.emin, w.subject, w.level, w.rate_cents,
           w.sk || '|' || w.email || '|' || w.day || '|' || lpad((w.smin / 60)::text, 2, '0') || ':' || lpad((w.smin % 60)::text, 2, '0') wkey,
           coalesce(ns.sid, (select l.row_id from imp_live l where l.kind = 'student' and l.key = w.sk)) sid,
           coalesce(ns.level, (select s2.level from students s2 where s2.id = (select l.row_id from imp_live l where l.kind = 'student' and l.key = w.sk))) slevel,
           coalesce(nt.mid, (select x.id from imp_tut x where x.em = w.email and x.role = 'tutor' limit 1)) tid
    from imp_w w left join imp_ns ns on ns.sk = w.sk left join imp_nt nt on nt.email = w.email;
  create temp table imp_nw on commit drop as
    select r.*, gen_random_uuid() slid from imp_wres r where not exists (select 1 from imp_live l where l.kind = 'slot' and l.key = r.wkey);

  -- rows that exist already but whose content differs: skipped, and the owner is told (the import never overwrites)
  select coalesce(jsonb_agg(jsonb_build_object('file', file, 'line', line, 'code', 'DIFFERS') order by file, line), '[]') into v_warn from (
    select 'students' file, s.line from imp_s s join imp_live l on l.kind = 'student' and l.key = s.sk join students x on x.id = l.row_id
      where x.name is distinct from s.student_name or x.level is distinct from s.level or x.location is distinct from s.location
         or x.online_link is distinct from s.online_link or x.start_date is distinct from import_try_date(s.start_date) or x.notes is distinct from s.notes
    union all
    select 'families', f.line from imp_f f join imp_live l on l.kind = 'family' and l.key = f.fk join households h on h.id = l.row_id
      where h.name is distinct from f.family_name
    union all
    select 'weekly_lessons', w.line from imp_wres w join imp_live l on l.kind = 'slot' and l.key = w.wkey join recurring_slots x on x.id = l.row_id
      where x.end_time is distinct from ((w.emin || ' minutes')::interval + time '00:00') or x.rate is distinct from (w.rate_cents / 100.0)::numeric(8,2)
         or x.subject is distinct from w.subject or x.level is distinct from coalesce(w.level, w.slevel)
    limit 200) d;

  v_created := jsonb_build_object('families', (select count(*) from imp_nf), 'guardians', (select count(*) from imp_ng), 'students', (select count(*) from imp_ns),
                                  'tutors', (select count(*) from imp_nt), 'weekly_lessons', (select count(*) from imp_nw));
  v_skipped := jsonb_build_object('families', (select count(distinct fk) from imp_f) - (select count(*) from imp_nf),
                                  'guardians', (select count(*) from imp_f) - (select count(*) from imp_ng),
                                  'students', (select count(*) from imp_s) - (select count(*) from imp_ns),
                                  'tutors', (select count(*) from imp_t) - (select count(*) from imp_nt),
                                  'weekly_lessons', (select count(*) from imp_w) - (select count(*) from imp_nw));

  if not p_commit then
    return jsonb_build_object('ok', true, 'dry_run', true, 'errors', '[]'::jsonb, 'error_count', 0, 'warnings', v_warn, 'created', v_created, 'skipped', v_skipped);
  end if;

  -- =========================================================== commit: one transaction (a failure anywhere undoes the lot)
  if (select count(*) from imp_ng) + (select count(*) from imp_ns) + (select count(*) from imp_nt) + (select count(*) from imp_nw) = 0 then
    return jsonb_build_object('ok', true, 'dry_run', false, 'errors', '[]'::jsonb, 'error_count', 0, 'warnings', v_warn, 'created', v_created, 'skipped', v_skipped, 'batch_id', null);
  end if;
  perform set_config('td.skip_audit', '1', true);
  -- forget keys whose rows have since been removed by hand (so the code can be imported again)
  delete from import_items i where i.org_id = p_org and not import_row_exists(i.tbl, i.row_id);
  v_hashes := case when jsonb_typeof(p_hashes) = 'object' and length(p_hashes::text) <= 2000 then p_hashes else '{}'::jsonb end;
  insert into import_batches(id, org_id, created_by, stage, counts, file_hashes, undo_until)
  values (v_batch, p_org, me, 'A', jsonb_build_object('created', v_created, 'skipped', v_skipped), v_hashes, v_until);

  insert into households(id, org_id, name, phone_key)
    select nf.hid, p_org, nf.family_name, (select org_phone_key(g.phone) from imp_ng g where g.hid = nf.hid and g.rn = 1) from imp_nf nf;
  -- created_at is staggered by a millisecond so "the first guardian of a family" (the main contact) stays the first, in any later query
  insert into guardians(id, org_id, household_id, name, relation, phone, email, created_at)
    select g.gid, p_org, g.hid, g.guardian_name, g.relation, g.phone, g.email, now() + g.rn * interval '1 millisecond' from imp_ng g order by g.fk, g.rn;

  insert into students(id, tutor_id, org_id, household_id, name, level, contact, recipient_name, notes, location, online_link, start_date)
    select s.sid, me, p_org, s.hid, s.student_name, s.level, coalesce(ng.phone, eg.phone), coalesce(ng.guardian_name, eg.name),
           s.notes, s.location, s.online_link, import_try_date(s.start_date)
    from imp_ns s
    left join lateral (select g.phone, g.guardian_name from imp_ng g where g.hid = s.hid and g.rn = 1) ng on true
    left join lateral (select x.phone, x.name from guardians x where x.household_id = s.hid order by x.created_at, x.id limit 1) eg on true;

  -- tutors go in through the same function as the Users screen (owner check, invited status, no email)
  for tr in select * from imp_nt order by line loop
    m := org_invite(p_org, tr.email, tr.tutor_name, 'tutor', '{}', tr.employment);
    update imp_nt set mid = m where email = tr.email;
    update imp_nw set tid = m where tid = tr.mid;
  end loop;

  insert into recurring_slots(id, tutor_id, org_id, student_id, weekday, start_time, end_time, subject, rate, level, taught_by)
    select w.slid, me, p_org, w.sid, w.day, (w.smin || ' minutes')::interval + time '00:00', (w.emin || ' minutes')::interval + time '00:00',
           w.subject, (w.rate_cents / 100.0)::numeric(8,2), coalesce(w.level, w.slevel), w.tid
    from imp_nw w order by w.line;

  insert into import_items(org_id, batch_id, kind, key, tbl, row_id, fp)
    select p_org, v_batch, 'family', nf.fk, 'households', h.id, import_fp(to_jsonb(h)) from imp_nf nf join households h on h.id = nf.hid
    union all select p_org, v_batch, 'guardian', null, 'guardians', g.id, import_fp(to_jsonb(g)) from imp_ng x join guardians g on g.id = x.gid
    union all select p_org, v_batch, 'student', ns.sk, 'students', s.id, import_fp(to_jsonb(s)) from imp_ns ns join students s on s.id = ns.sid
    union all select p_org, v_batch, 'tutor', nt.email, 'memberships', mm.id, import_fp(to_jsonb(mm)) from imp_nt nt join memberships mm on mm.id = nt.mid
    union all select p_org, v_batch, 'slot', w.wkey, 'recurring_slots', sl.id, import_fp(to_jsonb(sl)) from imp_nw w join recurring_slots sl on sl.id = w.slid;

  insert into audit_log(org_id, actor, action, table_name, row_id, after)
  values (p_org, me, 'import_commit', 'import_batches', v_batch::text, jsonb_build_object('stage', 'A', 'created', v_created, 'skipped', v_skipped, 'files', v_hashes));
  perform set_config('td.skip_audit', '', true);

  return jsonb_build_object('ok', true, 'dry_run', false, 'errors', '[]'::jsonb, 'error_count', 0, 'warnings', v_warn, 'created', v_created, 'skipped', v_skipped,
                            'batch_id', v_batch, 'undo_until', v_until);
end $$;

-- ---------------------------------------------------------------- the public entry points
create or replace function public.import_dry_run(p_org uuid, p_payload jsonb) returns jsonb
language sql security definer set search_path = public as $$ select import_run_a(p_org, p_payload, false, null) $$;
create or replace function public.import_commit(p_org uuid, p_payload jsonb, p_hashes jsonb default '{}') returns jsonb
language sql security definer set search_path = public as $$ select import_run_a(p_org, p_payload, true, p_hashes) $$;

-- the owner's codes already in the centre (families, students, tutors), for the page's own checks
create or replace function public.import_existing(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not org_can(p_org, 'owner') or not exists (select 1 from organisations o where o.id = p_org and o.kind = 'centre') then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  return jsonb_build_object(
    'families', coalesce((select jsonb_agg(i.key order by i.key) from import_items i where i.org_id = p_org and i.kind = 'family' and import_row_exists(i.tbl, i.row_id)), '[]'),
    'students', coalesce((select jsonb_agg(i.key order by i.key) from import_items i where i.org_id = p_org and i.kind = 'student' and import_row_exists(i.tbl, i.row_id)), '[]'),
    'tutors', coalesce((select jsonb_agg(lower(coalesce(m.invited_email, u.email)) order by m.created_at) from memberships m left join auth.users u on u.id = m.user_id
                         where m.org_id = p_org and m.role = 'tutor'), '[]'));
end $$;

create or replace function public.import_history(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not org_can(p_org, 'owner') or not exists (select 1 from organisations o where o.id = p_org and o.kind = 'centre') then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'created_at', b.created_at, 'stage', b.stage, 'status', b.status, 'counts', b.counts, 'file_hashes', b.file_hashes,
           'undo_until', b.undo_until, 'can_undo', (b.status <> 'undone' and now() <= b.undo_until), 'undone_at', b.undone_at, 'undo_report', b.undo_report) order by b.created_at desc)
     from import_batches b where b.org_id = p_org), '[]');
end $$;

-- ---------------------------------------------------------------- undo
-- Removes what the batch created, EXCEPT anything someone has since edited, marked or invoiced. Everything kept is reported with a reason:
--   EDITED  a person changed the row after the import (a name, a rate, a tutor accepted the invitation…)
--   ACTIVITY  lessons of it were marked, charged, paid, noted or invoiced, or it has exams or invoices
--   IN_USE  something added later (a lesson, a student, a weekly lesson) still depends on it
create or replace function public.import_undo_run(p_batch uuid, p_do boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b import_batches; me uuid := auth.uid(); v_del jsonb; v_kept jsonb; v_gone int; v_left int; v_status text;
begin
  select * into b from import_batches where id = p_batch;
  if me is null or not found or not org_can(b.org_id, 'owner') then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended('import:' || b.org_id::text, 0));
  if b.status = 'undone' then return jsonb_build_object('ok', false, 'code', 'ALREADY_UNDONE'); end if;
  if now() > b.undo_until then return jsonb_build_object('ok', false, 'code', 'UNDO_EXPIRED', 'undo_until', b.undo_until); end if;

  if to_regclass('pg_temp.imp_u') is not null then drop table pg_temp.imp_u; end if;
  -- one row per record of the batch that still exists, with its verdict
  create temp table imp_u on commit drop as
    select i.tbl, i.kind, i.key, i.row_id, i.fp, false keep, null::text reason,
           case i.tbl when 'households' then (select import_fp(to_jsonb(h)) from households h where h.id = i.row_id)
                      when 'guardians' then (select import_fp(to_jsonb(g)) from guardians g where g.id = i.row_id)
                      when 'students' then (select import_fp(to_jsonb(s)) from students s where s.id = i.row_id)
                      when 'memberships' then (select import_fp(to_jsonb(m)) from memberships m where m.id = i.row_id)
                      when 'recurring_slots' then (select import_fp(to_jsonb(x)) from recurring_slots x where x.id = i.row_id) end now_fp
    from import_items i where i.batch_id = p_batch and import_row_exists(i.tbl, i.row_id);
  create index on imp_u(tbl, row_id);
  select count(*) into v_gone from import_items i where i.batch_id = p_batch and not import_row_exists(i.tbl, i.row_id);

  -- weekly lessons: kept if changed, or any lesson of it has been worked on
  update imp_u u set keep = true, reason = 'EDITED' where u.tbl = 'recurring_slots' and u.now_fp is distinct from u.fp;
  update imp_u u set keep = true, reason = 'ACTIVITY' where u.tbl = 'recurring_slots' and not u.keep
    and exists (select 1 from lessons l where l.slot_id = u.row_id and import_lesson_touched(l));
  -- students: kept if changed, if they have worked-on lessons / exams / invoices, or a weekly lesson that is staying
  update imp_u u set keep = true, reason = 'EDITED' where u.tbl = 'students' and u.now_fp is distinct from u.fp;
  update imp_u u set keep = true, reason = 'ACTIVITY' where u.tbl = 'students' and not u.keep and (
      exists (select 1 from lessons l where l.student_id = u.row_id and import_lesson_touched(l))
      or exists (select 1 from exams e where e.student_id = u.row_id) or exists (select 1 from invoices v where v.student_id = u.row_id));
  update imp_u u set keep = true, reason = 'IN_USE' where u.tbl = 'students' and not u.keep and (
      exists (select 1 from recurring_slots x where x.student_id = u.row_id and not exists (select 1 from imp_u y where y.tbl = 'recurring_slots' and y.row_id = x.id and not y.keep)));
  -- a kept student keeps the weekly lessons it has (they would otherwise be deleted with it)
  update imp_u u set keep = true, reason = 'IN_USE' where u.tbl = 'recurring_slots' and not u.keep
    and exists (select 1 from imp_u s where s.tbl = 'students' and s.keep and s.row_id = (select x.student_id from recurring_slots x where x.id = u.row_id));
  -- families: kept if changed, if any guardian was changed or added by a person, or if a student stays in it
  update imp_u u set keep = true, reason = 'EDITED' where u.tbl = 'households' and u.now_fp is distinct from u.fp;
  update imp_u u set keep = true, reason = 'EDITED' where u.tbl = 'households' and not u.keep and exists (
      select 1 from guardians g where g.household_id = u.row_id and not exists (select 1 from imp_u y where y.tbl = 'guardians' and y.row_id = g.id and y.now_fp is not distinct from y.fp));
  update imp_u u set keep = true, reason = 'IN_USE' where u.tbl = 'households' and not u.keep and exists (
      select 1 from students s where s.household_id = u.row_id and not exists (select 1 from imp_u y where y.tbl = 'students' and y.row_id = s.id and not y.keep));
  update imp_u u set keep = true, reason = 'IN_USE' where u.tbl = 'guardians' and exists (
      select 1 from imp_u h where h.tbl = 'households' and h.keep and h.row_id = (select g.household_id from guardians g where g.id = u.row_id));
  -- tutors: kept if the person accepted or was edited, or a weekly lesson / lesson of someone still there is theirs
  update imp_u u set keep = true, reason = case when (select m.user_id from memberships m where m.id = u.row_id) is not null then 'ACCEPTED' else 'EDITED' end
    where u.tbl = 'memberships' and u.now_fp is distinct from u.fp;
  update imp_u u set keep = true, reason = 'IN_USE' where u.tbl = 'memberships' and not u.keep and (
      exists (select 1 from recurring_slots x where x.taught_by = u.row_id and not exists (select 1 from imp_u y where y.tbl = 'recurring_slots' and y.row_id = x.id and not y.keep))
      or exists (select 1 from lessons l where l.taught_by = u.row_id and not exists (select 1 from imp_u y where y.tbl = 'students' and y.row_id = l.student_id and not y.keep)));

  select coalesce(jsonb_object_agg(tbl, n), '{}') into v_del from (select tbl, count(*) n from imp_u where not keep group by tbl) q;
  select coalesce(jsonb_agg(jsonb_build_object('type', kind, 'code', key, 'reason', reason) order by kind, key) filter (where kind <> 'guardian'), '[]') into v_kept from (select * from imp_u where keep limit 500) q;
  select count(*) into v_left from imp_u where keep;

  if not p_do then
    return jsonb_build_object('ok', true, 'preview', true, 'would_delete', v_del, 'kept', v_kept, 'kept_count', v_left, 'already_gone', v_gone);
  end if;

  perform set_config('td.skip_audit', '1', true);
  -- lessons first (untouched ones only: a worked-on lesson always keeps its weekly lesson and its student), then the rest, children before parents
  delete from lessons l where l.org_id = b.org_id and (
        l.slot_id in (select row_id from imp_u where tbl = 'recurring_slots' and not keep)
     or l.student_id in (select row_id from imp_u where tbl = 'students' and not keep));
  delete from recurring_slots x where x.id in (select row_id from imp_u where tbl = 'recurring_slots' and not keep);
  delete from students s where s.id in (select row_id from imp_u where tbl = 'students' and not keep);
  delete from guardians g where g.id in (select row_id from imp_u where tbl = 'guardians' and not keep);
  delete from households h where h.id in (select row_id from imp_u where tbl = 'households' and not keep);
  delete from memberships m where m.id in (select row_id from imp_u where tbl = 'memberships' and not keep) and m.org_id = b.org_id;
  delete from import_items i where i.batch_id = p_batch and (not import_row_exists(i.tbl, i.row_id));
  update import_items i set kept_reason = u.reason from imp_u u where i.batch_id = p_batch and i.tbl = u.tbl and i.row_id = u.row_id and u.keep;

  v_status := case when v_left = 0 then 'undone' else 'partly_undone' end;
  update import_batches set status = v_status, undone_at = case when v_left = 0 then now() else undone_at end,
         undo_report = jsonb_build_object('deleted', v_del, 'kept', v_kept, 'kept_count', v_left, 'at', now())
   where id = p_batch;
  insert into audit_log(org_id, actor, action, table_name, row_id, after)
  values (b.org_id, me, 'import_undo', 'import_batches', p_batch::text, jsonb_build_object('deleted', v_del, 'kept_count', v_left));
  perform set_config('td.skip_audit', '', true);
  return jsonb_build_object('ok', true, 'preview', false, 'deleted', v_del, 'kept', v_kept, 'kept_count', v_left, 'already_gone', v_gone, 'status', v_status);
end $$;

create or replace function public.import_undo_preview(p_batch uuid) returns jsonb
language sql security definer set search_path = public as $$ select import_undo_run(p_batch, false) $$;
create or replace function public.import_undo(p_batch uuid) returns jsonb
language sql security definer set search_path = public as $$ select import_undo_run(p_batch, true) $$;

-- ---------------------------------------------------------------- who may call what
do $$
declare f text;
begin
  foreach f in array array['import_dry_run(uuid,jsonb)','import_commit(uuid,jsonb,jsonb)','import_existing(uuid)','import_history(uuid)',
                           'import_undo_preview(uuid)','import_undo(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['import_run_a(uuid,jsonb,boolean,jsonb)','import_undo_run(uuid,boolean)','import_fp(jsonb)','import_try_date(text)','import_minutes(text)',
                           'import_row_exists(text,uuid)','import_lesson_touched(lessons)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;
