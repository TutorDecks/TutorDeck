-- =====================================================================================================
-- T34 M0-M2 — bank statement matching for centres (engine + custom column mapping)       undo: migration_statement_matching_down.sql
-- =====================================================================================================
-- Run order everywhere: org_foundation → billing → attendance → tutor_access → org_delete → function_lockdown → org_separation →
--   staff_home → staff_students → staff_attendance → staff_charges → staff_trials → staff_timetable → money_settings → centre_money →
--   centre_invoice_run → centre_payments → centre_deposits → centre_refunds → centre_late_fees → centre_credit_undo → statement_matching.
-- Needs migration_centre_payments.sql (centre_record_payment / centre_reverse_payment: the ONLY way money is written here) and
-- migration_centre_credit_undo.sql (the organisation-aware settings check, which this file extends).
-- Run on the DEV project first. LIVE only when the owner says ship (six new tables, new functions, one re-created function; it reads and changes no
-- existing row). Safe to run twice. Plan: docs/orchestrator/T34-plan.md (branch claude/t34-plan).
--
-- WHAT IT DOES
--   An owner (or staff with record_payments) uploads a bank statement. The BROWSER parses the file with a saved column mapping and sends only the
--   mapped fields (date, signed cents, reference text, payer text, the bank's own reference), account numbers cut to their last 4 digits. The database
--   stores the lines, drops the ones it has seen before (a fingerprint per line), runs the matching rules, and puts what it cannot settle in a
--   REVIEW QUEUE. Nothing is edited: a wrong match is UNDONE through the same reversal as any payment.
--
-- RULES (credit lines only; "open" = an issued, non-credit-note invoice with a balance; the date window applies to every rule)
--   A  the centre's own invoice number is found in the reference (case, spacing and punctuation ignored) AND the amount equals that invoice's balance
--      → EXACT.  A number found with another amount, an invoice already paid, or two numbers → review, with the reason in plain words.
--   B  a remembered payer (normalised name → household) AND exactly one open invoice of that household has exactly this balance → EXACT.
--   C  amount only: exactly one open invoice in the whole centre has this balance → SUGGESTION ONLY (never automatic).
--   D  the line equals everything one family owes (or, for a known payer, exactly one combination of at most 10 open invoices) → SUGGESTION ONLY.
--   Exact cents only: S$0.01 off goes to review, showing the difference. Money out (debits) is never matched; a person marks it "not ours".
--   Auto-confirm is the centre's choice (payments.statement.auto_confirm): exact_only (rules A and B pay by themselves) or never (every line waits).
--
-- SETTINGS (org_validate_settings; the labels and defaults are in assets/js/org-settings.js, tests/org-settings.test.js compares the values)
--   payments.modes ∋ statement_matching     every function below refuses a centre that has not switched it on
--   payments.statement.auto_confirm         exact_only (default) | never
--   payments.statement.window_before_days   0-30 (default 7)   payment date may be this many days BEFORE the invoice was issued
--   payments.statement.window_after_days    0-365 (default 90) ... and this many days AFTER it was due
--   payments.statement_bank                 DBS | OCBC | UOB | custom. The three banks are UNVERIFIED (no real sample file yet): only "custom" works.
--   Process rules are read as of TODAY (CLAUDE.md); the money rules (partial payments, overpayments) are those of centre_record_payment.
--
-- WHO MAY CALL  an active owner or staff with record_payments (and the mode switched on). Tutors, parents, solo organisations, other centres,
--   switched-off staff and strangers all get NOT_FOUND / NOT_ALLOWED. The tables have NO write policy: only these SECURITY DEFINER functions write.
-- MONEY PATH    a confirmed match calls centre_record_payment (method 'bank'); an undo calls centre_reverse_payment. No second way to write money.
--   The payment gets the bank's own reference only: never the payer's name, never the statement text.
-- RETENTION     a raw line is DELETED the moment it is resolved; an unresolved one 60 days after it was imported (purged inside import / confirm /
--   undo, no cron). Kept: the fingerprint (a hash, no text), a name-free match record (date, cents, rule, payment, who, when), and payer links
--   (normalised names, listed and forgettable on the screen).
-- AUDIT         match / link / mapping / batch rows are copied to the audit log with every text field replaced by "[redacted]"; the raw lines are
--   never copied (each function writes one summary line with counts only).
-- IDEMPOTENT    the same file twice adds nothing: a line is its fingerprint (centre + account label + date + signed cents + normalised reference +
--   bank reference) PLUS an occurrence number, so two real identical payments in one file are both kept but the second upload adds none.
-- =====================================================================================================

-- ---------------------------------------------------------------------------------------------------
-- 1. small pure helpers (the JS twin is assets/js/statement-core.js; tests/statement-vectors.csv holds the shared examples)
-- ---------------------------------------------------------------------------------------------------
-- a run of 9 or more digits keeps only its last 4 (account numbers must never be stored in full)
create or replace function public.stmt_mask_digits(t text) returns text language sql immutable set search_path = public as $$
  select regexp_replace(t, '[0-9]{5,}([0-9]{4})', '****\1', 'g') $$;
-- "Mr  TAN, Ah-Kow" → "mr tan ah kow"  (the key of a payer link)
create or replace function public.stmt_norm_payer(t text) returns text language sql immutable set search_path = public as $$
  select trim(regexp_replace(regexp_replace(lower(coalesce(t, '')), '[^a-z0-9]+', ' ', 'g'), '\s+', ' ', 'g')) $$;
-- the reference text as it goes into a fingerprint: same rule as a payer
create or replace function public.stmt_norm_ref(t text) returns text language sql immutable set search_path = public as $$
  select public.stmt_norm_payer(public.stmt_mask_digits(t)) $$;
-- the regular expression that finds an invoice number in lower-cased reference text: INV-12 matches "inv 12", "INV-12", "inv12" but NOT "inv123" or "inv-1"
create or replace function public.stmt_number_pattern(n text) returns text language sql immutable set search_path = public as $$
  select '(^|[^a-z0-9])' || (select string_agg(m[1], '[^a-z0-9]*') from regexp_matches(lower(n), '([a-z]+|[0-9]+)', 'g') m) || '([^a-z0-9]|$)' $$;
create or replace function public.stmt_fp(p_org uuid, p_account text, p_date date, p_cents bigint, p_ref_norm text, p_bank_ref text) returns text
language sql immutable set search_path = public as $$
  select encode(sha256(convert_to(concat_ws('|', p_org::text, lower(trim(coalesce(p_account, ''))), p_date::text, p_cents::text, coalesce(p_ref_norm, ''),
                                            lower(trim(coalesce(p_bank_ref, '')))), 'UTF8')), 'hex') $$;
-- how many of p_bals' combinations add up to p_target, and which one if there is exactly one (at most 10 invoices; the whole set counts as one combination)
create or replace function public.stmt_subsets(p_ids uuid[], p_bals bigint[], p_target bigint) returns jsonb
language plpgsql immutable set search_path = public as $$
declare n int := coalesce(cardinality(p_ids), 0); mask int; i int; tot bigint; cnt int := 0; hit int := 0;
begin
  if n < 1 or n > 10 then return jsonb_build_object('count', 0, 'ids', '[]'::jsonb); end if;
  for mask in 1 .. (1 << n) - 1 loop
    tot := 0;
    for i in 0 .. n - 1 loop if (mask & (1 << i)) <> 0 then tot := tot + p_bals[i + 1]; end if; end loop;
    if tot = p_target then cnt := cnt + 1; hit := mask; end if;
  end loop;
  return jsonb_build_object('count', cnt, 'ids', case when cnt = 1 then (select coalesce(jsonb_agg(p_ids[g.k + 1]), '[]'::jsonb) from generate_series(0, n - 1) g(k) where (hit & (1 << g.k)) <> 0) else '[]'::jsonb end);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 2. tables (centres only; read by record_payments; NO write policy)
-- ---------------------------------------------------------------------------------------------------
create table if not exists public.statement_mappings (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organisations(id) on delete cascade,
  name        text not null check (length(trim(name)) between 1 and 60),
  version     int not null default 1 check (version >= 1),
  mapping     jsonb not null,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  unique (org_id, name, version),
  unique (id, org_id)
);
create table if not exists public.statement_batches (       -- no file name: names can sit in file names
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organisations(id) on delete cascade,
  account_label text not null check (length(trim(account_label)) between 1 and 40),
  mapping_id  uuid,
  date_from   date, date_to date,
  n_lines int not null default 0, n_new int not null default 0, n_duplicate int not null default 0, n_skipped int not null default 0,
  n_auto int not null default 0, n_review int not null default 0,
  imported_by uuid default auth.uid(),
  imported_at timestamptz not null default now(),
  unique (id, org_id),
  foreign key (mapping_id, org_id) references public.statement_mappings(id, org_id)
);
create table if not exists public.statement_fingerprints (  -- kept: a hash, no text
  org_id      uuid not null references public.organisations(id) on delete cascade,
  fp          text not null,
  occ         int not null check (occ >= 1),
  batch_id    uuid,
  first_seen  date not null default current_date,
  primary key (org_id, fp, occ)
);
create table if not exists public.statement_lines (          -- DELETED when resolved (or 60 days after import)
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organisations(id) on delete cascade,
  batch_id    uuid,
  row_no      int not null default 0,
  line_date   date not null,
  cents       bigint not null check (cents <> 0 and abs(cents) <= 100000000000),
  ref_text    text,
  payer_text  text,
  bank_ref    text,
  fp          text not null,
  occ         int not null check (occ >= 1),
  stub        boolean not null default false,                 -- put back after an undo: date and amount only
  sugg_rule   text check (sugg_rule in ('invoice_no', 'payer_link', 'amount_only', 'household_total')),
  sugg_exact  boolean not null default false,                 -- the amount equals what is owed on the suggested invoice(s)
  sugg_invoice_ids uuid[] not null default '{}',
  sugg_household uuid,
  reason      text,                                           -- plain words, shown on the screen
  purge_after date not null,
  created_at  timestamptz not null default now(),
  unique (id, org_id),
  unique (org_id, fp, occ),
  foreign key (batch_id, org_id) references public.statement_batches(id, org_id) on delete cascade
);
create index if not exists statement_lines_org on public.statement_lines(org_id, line_date, row_no);
create table if not exists public.statement_matches (        -- kept, NO names
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organisations(id) on delete cascade,
  batch_id    uuid,
  fp          text not null,
  occ         int not null,
  line_date   date not null,
  cents       bigint not null,
  kind        text not null check (kind in ('invoice', 'ignored')),
  rule        text not null check (rule in ('invoice_no', 'payer_link', 'amount_only', 'household_total', 'manual')),
  household_id uuid,
  payment_id  uuid,
  auto        boolean not null default false,
  confirmed_by uuid,
  confirmed_at timestamptz not null default now(),
  reversed_at timestamptz, reversed_by uuid, reverse_reason text,
  unique (id, org_id),
  foreign key (payment_id, org_id) references public.centre_payments(id, org_id),
  check ((kind = 'invoice') = (payment_id is not null)),
  check ((reversed_at is null) = (reversed_by is null))
);
create unique index if not exists statement_matches_live on public.statement_matches(org_id, fp, occ) where reversed_at is null;
create unique index if not exists statement_matches_payment on public.statement_matches(payment_id) where payment_id is not null;
create index if not exists statement_matches_org on public.statement_matches(org_id, confirmed_at desc);
create table if not exists public.statement_payer_links (    -- a normalised NAME: listed on the screen, forgettable
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organisations(id) on delete cascade,
  payer_key   text not null check (length(payer_key) between 1 and 120),
  household_id uuid not null,
  times_used  int not null default 1,
  last_used   date not null default current_date,
  created_at  timestamptz not null default now(),
  unique (org_id, payer_key),
  unique (id, org_id),
  foreign key (household_id, org_id) references public.households(id, org_id) on delete cascade
);

-- audit: match / link / mapping / batch rows only, text fields redacted. The raw lines and fingerprints are never copied.
create or replace function public.stmt_audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare b jsonb; a jsonb; k text; redact text[] := array['payer_key', 'reverse_reason', 'reason', 'ref_text', 'payer_text', 'bank_ref', 'name'];
begin
  if coalesce(current_setting('td.skip_audit', true), '') = '1' then return null; end if;
  b := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  a := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  foreach k in array redact loop
    if b ? k and b->>k is not null then b := jsonb_set(b, array[k], '"[redacted]"'); end if;
    if a ? k and a->>k is not null then a := jsonb_set(a, array[k], '"[redacted]"'); end if;
  end loop;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (coalesce((a->>'org_id')::uuid, (b->>'org_id')::uuid), auth.uid(), lower(tg_op), tg_table_name, coalesce(a->>'id', b->>'id'), b, a);
  return null;
end $$;
do $$
declare t text;
begin
  foreach t in array array['statement_mappings', 'statement_batches', 'statement_matches', 'statement_payer_links'] loop
    execute format('drop trigger if exists audit_row on public.%I', t);
    execute format('create trigger audit_row after insert or update or delete on public.%I for each row execute function public.stmt_audit()', t);
  end loop;
end $$;

alter table public.statement_mappings enable row level security;
alter table public.statement_batches enable row level security;
alter table public.statement_fingerprints enable row level security;
alter table public.statement_lines enable row level security;
alter table public.statement_matches enable row level security;
alter table public.statement_payer_links enable row level security;
do $$
declare t text;
begin
  foreach t in array array['statement_mappings', 'statement_batches', 'statement_lines', 'statement_matches', 'statement_payer_links'] loop
    execute format('drop policy if exists money_read on public.%I', t);
    execute format('create policy money_read on public.%I for select using (org_can(org_id, ''record_payments'') and not org_is_solo(org_id))', t);
  end loop;
end $$;
revoke all on public.statement_mappings, public.statement_batches, public.statement_fingerprints, public.statement_lines, public.statement_matches, public.statement_payer_links from anon, authenticated;
grant select on public.statement_mappings, public.statement_batches, public.statement_lines, public.statement_matches, public.statement_payer_links to authenticated;

-- ---------------------------------------------------------------------------------------------------
-- 3. the gate, the settings, the mapping
-- ---------------------------------------------------------------------------------------------------
create or replace function public.stmt_gate(p_org uuid) returns date
language plpgsql stable security definer set search_path = public as $$
declare today date := centre_money_gate(p_org, 'record_payments'); s jsonb;
begin
  s := org_settings_on(p_org, today);
  if s is null or not ((coalesce(s#>'{payments,modes}', '[]'::jsonb)) ? 'statement_matching') then
    raise exception 'NOT_ALLOWED: bank statement matching isn''t switched on in this centre''s payment settings' using errcode = '42501'; end if;
  return today;
end $$;

-- a mapping is a small document; the browser checks it too (statement-core.js validateMapping)
create or replace function public.stmt_save_mapping(p_org uuid, p_name text, p_mapping jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := stmt_gate(p_org); nm text := nullif(trim(coalesce(p_name, '')), ''); m jsonb := p_mapping; v int; mid uuid := gen_random_uuid(); k text; c jsonb;
begin
  if nm is null or length(nm) > 60 then raise exception 'BAD_VALUE: give the mapping a name (up to 60 characters)' using errcode = 'P0001'; end if;
  if jsonb_typeof(m) is distinct from 'object' then raise exception 'BAD_VALUE: the mapping is missing' using errcode = 'P0001'; end if;
  if m->>'delimiter' is null or m->>'delimiter' not in (',', ';', E'\t', '|') then raise exception 'BAD_VALUE: pick the column separator' using errcode = 'P0001'; end if;
  if m->>'header_rows' is null or m->>'header_rows' !~ '^[0-9]{1,2}$' then raise exception 'BAD_VALUE: say how many rows to skip above the table (0-99)' using errcode = 'P0001'; end if;
  if m->>'date_format' is null or m->>'date_format' not in ('dmy_slash', 'dmy_dash', 'dmy_text', 'iso', 'mdy_slash') then raise exception 'BAD_VALUE: pick the date format' using errcode = 'P0001'; end if;
  if m->>'amount_mode' is null or m->>'amount_mode' not in ('signed', 'debit_credit', 'amount_drcr') then raise exception 'BAD_VALUE: pick how amounts are laid out' using errcode = 'P0001'; end if;
  foreach k in array array['date_col'] || case m->>'amount_mode' when 'signed' then array['amount_col'] when 'debit_credit' then array['debit_col', 'credit_col'] else array['amount_col', 'drcr_col'] end loop
    if m->>k is null or m->>k !~ '^[0-9]{1,3}$' then raise exception 'BAD_VALUE: pick the % column', k using errcode = 'P0001'; end if;
  end loop;
  if jsonb_typeof(m->'ref_cols') is distinct from 'array' or jsonb_array_length(m->'ref_cols') > 6 then raise exception 'BAD_VALUE: pick the reference column(s), at most 6' using errcode = 'P0001'; end if;
  for c in select * from jsonb_array_elements(m->'ref_cols') loop
    if c#>>'{}' !~ '^[0-9]{1,3}$' then raise exception 'BAD_VALUE: a reference column is not a number' using errcode = 'P0001'; end if;
  end loop;
  foreach k in array array['payer_col', 'bank_ref_col'] loop
    if m->>k is not null and m->>k !~ '^[0-9]{1,3}$' then raise exception 'BAD_VALUE: % must be a column number or empty', k using errcode = 'P0001'; end if;
  end loop;
  if length(m::text) > 2000 then raise exception 'TOO_LONG: that mapping is too big' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_org::text || nm, 7));
  select coalesce(max(version), 0) + 1 into v from statement_mappings where org_id = p_org and name = nm;
  insert into statement_mappings(id, org_id, name, version, mapping) values (mid, p_org, nm, v, m);
  return jsonb_build_object('mapping_id', mid, 'name', nm, 'version', v);
end $$;

-- the lines as they will be stored (masked, fingerprinted, numbered), computed once for check and import
create or replace function public.stmt_fp_rows(p_org uuid, p_account text, p_lines jsonb)
returns table(row_no int, line_date date, cents bigint, ref_text text, payer_text text, bank_ref text, fp text, occ int)
language plpgsql security definer set search_path = public, pg_temp as $$
declare x jsonb; i int := 0;
begin
  if jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'BAD_VALUE: no lines to import' using errcode = 'P0001'; end if;
  if jsonb_array_length(p_lines) > 20000 then raise exception 'TOO_LONG: up to 20,000 lines at a time' using errcode = 'P0001'; end if;
  create temp table if not exists _stmt_raw(row_no int, line_date date, cents bigint, ref_text text, payer_text text, bank_ref text) on commit drop;
  delete from _stmt_raw where true;
  for x in select * from jsonb_array_elements(p_lines) loop
    i := i + 1;
    if x->>'date' is null or x->>'date' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'BAD_VALUE: line % has no valid date (the browser sends yyyy-mm-dd)', i using errcode = 'P0001'; end if;
    if x->>'cents' is null or x->>'cents' !~ '^-?[0-9]{1,12}$' then raise exception 'BAD_VALUE: line % has no valid amount (whole cents)', i using errcode = 'P0001'; end if;
    insert into _stmt_raw values (coalesce(nullif(x->>'row', '')::int, i), (x->>'date')::date, (x->>'cents')::bigint,
      nullif(left(public.stmt_mask_digits(trim(coalesce(x->>'ref', ''))), 400), ''), nullif(left(public.stmt_mask_digits(trim(coalesce(x->>'payer', ''))), 120), ''),
      nullif(left(public.stmt_mask_digits(trim(coalesce(x->>'bank_ref', ''))), 120), ''));
  end loop;
  return query
    select r.row_no, r.line_date, r.cents, r.ref_text, r.payer_text, r.bank_ref, f.fp, (row_number() over (partition by f.fp order by r.row_no))::int
      from _stmt_raw r, lateral (select public.stmt_fp(p_org, p_account, r.line_date, r.cents, public.stmt_norm_ref(r.ref_text), r.bank_ref) as fp) f
     where r.cents <> 0;
end $$;

-- "will this file add anything?": counts only, writes nothing (the upload screen shows it before the person presses Import)
create or replace function public.stmt_check(p_org uuid, p_account text, p_lines jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := stmt_gate(p_org); r jsonb;
begin
  if nullif(trim(coalesce(p_account, '')), '') is null then raise exception 'BAD_VALUE: give the account a label' using errcode = 'P0001'; end if;
  select jsonb_build_object('lines', count(*), 'known', count(*) filter (where exists (select 1 from statement_fingerprints f where f.org_id = p_org and f.fp = x.fp and f.occ = x.occ)),
         'new', count(*) filter (where not exists (select 1 from statement_fingerprints f where f.org_id = p_org and f.fp = x.fp and f.occ = x.occ)),
         'from', min(x.line_date), 'to', max(x.line_date),
         'credits_cents', coalesce(sum(x.cents) filter (where x.cents > 0), 0), 'debits_cents', coalesce(-sum(x.cents) filter (where x.cents < 0), 0))
    into r from stmt_fp_rows(p_org, p_account, p_lines) x;
  return r;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 4. one confirmed match: the payment, the match record, the payer link, the line removed
-- ---------------------------------------------------------------------------------------------------
create or replace function public.stmt_apply_match(p_org uuid, p_line uuid, p_ids uuid[], p_rule text, p_auto boolean, p_remember boolean, p_today date) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare ln statement_lines; res jsonb; hh uuid; pk text; mid uuid := gen_random_uuid();
begin
  select * into ln from statement_lines where id = p_line and org_id = p_org for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if ln.cents <= 0 then raise exception 'NOT_ALLOWED: only money received can be matched to an invoice' using errcode = '42501'; end if;
  if coalesce(cardinality(p_ids), 0) = 0 then raise exception 'BAD_VALUE: choose the invoice this payment is for' using errcode = 'P0001'; end if;
  res := centre_record_payment(p_org, null, 'bank', ln.cents, ln.line_date, ln.bank_ref, p_ids, null, 'Matched from a bank statement');
  hh := (res->>'household_id')::uuid;
  pk := stmt_norm_payer(ln.payer_text);
  insert into statement_matches(id, org_id, batch_id, fp, occ, line_date, cents, kind, rule, household_id, payment_id, auto, confirmed_by)
  values (mid, p_org, ln.batch_id, ln.fp, ln.occ, ln.line_date, ln.cents, 'invoice', p_rule, hh, (res->>'payment_id')::uuid, p_auto, auth.uid());
  if pk <> '' and (p_remember or (p_auto and p_rule = 'payer_link')) then
    insert into statement_payer_links(org_id, payer_key, household_id, times_used, last_used) values (p_org, left(pk, 120), hh, 1, p_today)
    on conflict (org_id, payer_key) do update set household_id = excluded.household_id, times_used = statement_payer_links.times_used + 1, last_used = excluded.last_used;
  end if;
  delete from statement_lines where id = ln.id and org_id = p_org;
  return res || jsonb_build_object('match_id', mid, 'rule', p_rule, 'auto', p_auto);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 5. THE RULES. Runs over a batch (or every line waiting in the queue) and settles what it can.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.stmt_run_rules(p_org uuid, p_today date, p_batch uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare s jsonb := org_settings_on(p_org, p_today); auto text := coalesce(s#>>'{payments,statement,auto_confirm}', 'exact_only');
  wb int := coalesce((s#>>'{payments,statement,window_before_days}')::int, 7); wa int := coalesce((s#>>'{payments,statement,window_after_days}')::int, 90);
  ln statement_lines; o record; lk statement_payer_links; pk text; rn text; ids uuid[]; bals bigint[]; cnt int; tot bigint; list text; sub jsonb; hhs uuid[];
  r_rule text; r_exact boolean; r_ids uuid[]; r_hh uuid; r_reason text; res jsonb; a jsonb; n_auto int := 0; n_review int := 0; amt text;
begin
  create temp table if not exists _stmt_open(invoice_id uuid, number_text text, pat text, hid uuid, issue_date date, due_date date, bal bigint) on commit drop;
  delete from _stmt_open where true;
  insert into _stmt_open
    select b.invoice_id, i.number_text, stmt_number_pattern(i.number_text), centre_invoice_household(i.id), i.issue_date, i.due_date, b.balance_cents
      from centre_balance_rows(p_org, array(select id from centre_invoices where org_id = p_org and status = 'issued' and kind <> 'credit_note')) b
      join centre_invoices i on i.id = b.invoice_id and i.org_id = p_org;
  for ln in select * from statement_lines where org_id = p_org and (p_batch is null or batch_id = p_batch) order by line_date, row_no, id loop
    r_rule := null; r_exact := false; r_ids := '{}'; r_hh := null; r_reason := null; lk := null;
    pk := stmt_norm_payer(ln.payer_text); rn := lower(coalesce(ln.ref_text, '')); amt := centre_fmt_money(abs(ln.cents));
    <<d>> begin
      if ln.cents < 0 then r_reason := 'Money out, so it is never matched automatically. Mark it "not ours" unless it is a refund.'; exit d; end if;
      if ln.line_date > p_today then r_reason := 'Dated in the future: wait until that day.'; exit d; end if;
      if ln.line_date < p_today - 1825 then r_reason := 'Too old to record (over 5 years).'; exit d; end if;
      -- A: the invoice number is in the reference
      select array_agg(x.invoice_id order by x.number_text), count(*) into ids, cnt from _stmt_open x where rn ~ x.pat;
      if cnt >= 2 then
        select string_agg(x.number_text, ', ' order by x.number_text), coalesce(sum(x.bal), 0) into list, tot from _stmt_open x where x.invoice_id = any(ids);
        r_rule := 'household_total'; r_ids := ids; r_exact := (tot = ln.cents);      -- two numbers: a suggestion, never automatic
        r_reason := 'More than one invoice number found (' || list || ')' || case when tot = ln.cents then ', and together they come to exactly ' || amt || '. Check and confirm.' else '. Choose which one this is for.' end; exit d;
      elsif cnt = 1 then
        select * into o from _stmt_open x where x.invoice_id = ids[1];
        r_rule := 'invoice_no'; r_ids := ids; r_hh := o.hid;
        if o.bal = 0 then r_reason := o.number_text || ' found, but it is already paid.';
        elsif ln.line_date < o.issue_date - wb or ln.line_date > coalesce(o.due_date, o.issue_date) + wa then
          r_reason := o.number_text || ' found, but the date is outside the allowed window (' || wb || ' days before it was issued to ' || wa || ' days after it was due).';
        elsif ln.cents = o.bal then r_exact := true; r_reason := o.number_text || ' found, exact amount.';
        elsif ln.cents < o.bal then r_reason := o.number_text || ' found, but ' || centre_fmt_money(o.bal - ln.cents) || ' short.';
        else r_reason := o.number_text || ' found, but ' || centre_fmt_money(ln.cents - o.bal) || ' over.'; end if;
        exit d;
      end if;
      -- B: a remembered payer
      if pk <> '' then select * into lk from statement_payer_links where org_id = p_org and payer_key = left(pk, 120); end if;
      if lk.id is not null then
        r_hh := lk.household_id;
        select array_agg(x.invoice_id order by x.issue_date, x.number_text), count(*) into ids, cnt from _stmt_open x
          where x.hid = lk.household_id and x.bal = ln.cents and ln.line_date between x.issue_date - wb and coalesce(x.due_date, x.issue_date) + wa;
        if cnt = 1 then r_rule := 'payer_link'; r_exact := true; r_ids := ids; r_reason := 'Known payer, exact amount.'; exit d;
        elsif cnt >= 2 then r_rule := 'payer_link'; r_ids := ids; r_reason := 'Known payer, but ' || cnt || ' invoices of this family are exactly ' || amt || '. Choose one.'; exit d; end if;
        select array_agg(x.invoice_id order by x.issue_date, x.number_text), array_agg(x.bal order by x.issue_date, x.number_text), count(*) into ids, bals, cnt from _stmt_open x
          where x.hid = lk.household_id and x.bal > 0 and ln.line_date between x.issue_date - wb and coalesce(x.due_date, x.issue_date) + wa;
        if cnt = 1 then
          r_rule := 'payer_link'; r_ids := ids;
          r_reason := 'Known payer. Their open invoice is ' || centre_fmt_money(bals[1]) || ', this is ' || case when ln.cents < bals[1] then centre_fmt_money(bals[1] - ln.cents) || ' short.' else centre_fmt_money(ln.cents - bals[1]) || ' over.' end; exit d;
        elsif cnt > 10 then r_reason := 'Known payer, but the family has more than 10 open invoices. Choose by hand.'; exit d;
        elsif cnt >= 2 then
          sub := stmt_subsets(ids, bals, ln.cents);
          if (sub->>'count')::int = 1 then
            r_rule := 'household_total'; r_exact := true; r_ids := array(select (e#>>'{}')::uuid from jsonb_array_elements(sub->'ids') e);
            r_reason := 'Known payer. This equals ' || cardinality(r_ids) || ' of the family''s open invoices. Check and confirm.'; exit d;
          elsif (sub->>'count')::int > 1 then r_reason := 'Known payer, but several combinations of the family''s invoices come to ' || amt || '. Choose by hand.'; exit d; end if;
        end if;
        r_reason := 'Known payer, but no open invoice of exactly ' || amt || '.'; exit d;
      end if;
      -- C: amount only (suggestion, never automatic)
      select array_agg(x.invoice_id order by x.issue_date, x.number_text), count(*) into ids, cnt from _stmt_open x
        where x.bal = ln.cents and ln.line_date between x.issue_date - wb and coalesce(x.due_date, x.issue_date) + wa;
      if cnt = 1 then
        select x.hid into r_hh from _stmt_open x where x.invoice_id = ids[1];
        r_rule := 'amount_only'; r_exact := true; r_ids := ids;
        r_reason := 'Only one invoice is owed for exactly ' || amt || ', but there is no invoice number or known payer. Check and confirm.'; exit d;
      elsif cnt >= 2 then r_rule := 'amount_only'; r_ids := ids[1:10]; r_reason := cnt || ' invoices are owed for exactly ' || amt || '. Choose which family this is.'; exit d; end if;
      -- D: everything one family owes
      select array_agg(g.hid), count(*) into hhs, cnt from (
        select x.hid from _stmt_open x where x.bal > 0 and x.hid is not null and ln.line_date between x.issue_date - wb and coalesce(x.due_date, x.issue_date) + wa
         group by x.hid having count(*) between 2 and 10 and sum(x.bal) = ln.cents) g;
      if cnt = 1 then
        r_rule := 'household_total'; r_exact := true; r_hh := hhs[1];
        select array_agg(x.invoice_id order by x.issue_date, x.number_text) into r_ids from _stmt_open x where x.hid = hhs[1] and x.bal > 0 and ln.line_date between x.issue_date - wb and coalesce(x.due_date, x.issue_date) + wa;
        r_reason := 'This equals everything one family owes (' || cardinality(r_ids) || ' invoices). Check and confirm.'; exit d;
      elsif cnt >= 2 then r_reason := 'More than one family owes a total of exactly ' || amt || '. Choose which.'; exit d; end if;
      select count(*) into cnt from _stmt_open x where x.bal > 0;
      r_reason := case when cnt = 0 then 'No open invoice yet.' else 'No invoice matches ' || amt || '. Add the invoice number to the reference, or choose the invoice.' end;
    end d;
    if r_exact and r_rule in ('invoice_no', 'payer_link') and auto = 'exact_only' then
      begin
        res := stmt_apply_match(p_org, ln.id, r_ids, r_rule, true, false, p_today);
        for a in select * from jsonb_array_elements(res->'allocated') loop
          update _stmt_open set bal = (a->>'balance_after_cents')::bigint where invoice_id = (a->>'invoice_id')::uuid;
        end loop;
        n_auto := n_auto + 1;
        continue;
      exception when others then
        r_reason := 'Could not be recorded automatically: ' || regexp_replace(sqlerrm, '^[A-Z_]+: ', '');
        r_exact := false;
      end;
    elsif r_exact and r_rule in ('invoice_no', 'payer_link') then
      r_reason := r_reason || ' Auto-confirm is off, so a person confirms.';
    end if;
    update statement_lines set sugg_rule = r_rule, sugg_exact = r_exact, sugg_invoice_ids = coalesce(r_ids, '{}'), sugg_household = r_hh, reason = r_reason
     where id = ln.id and org_id = p_org;
    n_review := n_review + 1;
  end loop;
  return jsonb_build_object('auto', n_auto, 'review', n_review);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 6. IMPORT (the browser sends the parsed lines) and RE-RUN the rules on what is waiting
-- ---------------------------------------------------------------------------------------------------
create or replace function public.stmt_purge(p_org uuid, p_today date) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin delete from statement_lines where org_id = p_org and purge_after < p_today; get diagnostics n = row_count; return n; end $$;

create or replace function public.stmt_import(p_org uuid, p_account text, p_mapping uuid, p_lines jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := stmt_gate(p_org); acct text := nullif(trim(coalesce(p_account, '')), ''); bid uuid := gen_random_uuid(); v_all int; v_new int; v_skip int; run jsonb;
  d1 date; d2 date; purged int;
begin
  if acct is null or length(acct) > 40 then raise exception 'BAD_VALUE: give the account a label (up to 40 characters, for example "Main account")' using errcode = 'P0001'; end if;
  if p_mapping is not null and not exists (select 1 from statement_mappings where id = p_mapping and org_id = p_org) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_org::text, 9));
  purged := stmt_purge(p_org, today);
  create temp table if not exists _stmt_in(row_no int, line_date date, cents bigint, ref_text text, payer_text text, bank_ref text, fp text, occ int) on commit drop;
  delete from _stmt_in where true;
  insert into _stmt_in select * from stmt_fp_rows(p_org, acct, p_lines);
  select count(*), min(line_date), max(line_date) into v_all, d1, d2 from _stmt_in;
  v_skip := jsonb_array_length(p_lines) - v_all;
  insert into statement_batches(id, org_id, account_label, mapping_id, date_from, date_to, n_lines) values (bid, p_org, acct, p_mapping, d1, d2, jsonb_array_length(p_lines));
  with ins as (insert into statement_fingerprints(org_id, fp, occ, batch_id, first_seen) select p_org, i.fp, i.occ, bid, today from _stmt_in i on conflict do nothing returning fp, occ)
  insert into statement_lines(org_id, batch_id, row_no, line_date, cents, ref_text, payer_text, bank_ref, fp, occ, purge_after)
  select p_org, bid, i.row_no, i.line_date, i.cents, i.ref_text, i.payer_text, i.bank_ref, i.fp, i.occ, today + 60 from _stmt_in i join ins using (fp, occ);
  get diagnostics v_new = row_count;
  run := stmt_run_rules(p_org, today, bid);
  update statement_batches set n_new = v_new, n_duplicate = v_all - v_new, n_skipped = v_skip, n_auto = (run->>'auto')::int, n_review = (run->>'review')::int where id = bid;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), 'statement_import', 'statement_batches', bid::text, null,
          jsonb_build_object('lines', v_all, 'new', v_new, 'duplicates', v_all - v_new, 'skipped_zero', v_skip, 'auto_matched', (run->>'auto')::int, 'to_review', (run->>'review')::int, 'purged', purged));
  return jsonb_build_object('batch_id', bid, 'lines', v_all, 'new', v_new, 'duplicates', v_all - v_new, 'skipped', v_skip, 'auto_matched', (run->>'auto')::int, 'to_review', (run->>'review')::int);
end $$;

create or replace function public.stmt_rematch(p_org uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := stmt_gate(p_org); run jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_org::text, 9));
  perform stmt_purge(p_org, today);
  run := stmt_run_rules(p_org, today, null);
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), 'statement_rematch', 'statement_lines', p_org::text, null, jsonb_build_object('auto_matched', (run->>'auto')::int, 'to_review', (run->>'review')::int));
  return jsonb_build_object('auto_matched', (run->>'auto')::int, 'to_review', (run->>'review')::int);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 7. WHAT A PERSON DOES: confirm, "not ours", undo, forget a payer
-- ---------------------------------------------------------------------------------------------------
create or replace function public.stmt_confirm(p_line uuid, p_invoice_ids uuid[] default null, p_remember boolean default true) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare org uuid; today date; ln statement_lines; ids uuid[]; rule text; res jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select org_id into org from statement_lines where id = p_line;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := stmt_gate(org);
  perform pg_advisory_xact_lock(hashtextextended(p_line::text, 11));
  select * into ln from statement_lines where id = p_line and org_id = org for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;      -- already handled (a second press)
  ids := coalesce(nullif(p_invoice_ids, '{}'), ln.sugg_invoice_ids);
  if coalesce(cardinality(ids), 0) = 0 then raise exception 'BAD_VALUE: choose the invoice this payment is for' using errcode = 'P0001'; end if;
  rule := case when ln.sugg_rule is not null and (select array(select unnest(ids) order by 1)) = (select array(select unnest(ln.sugg_invoice_ids) order by 1)) then ln.sugg_rule else 'manual' end;
  res := stmt_apply_match(org, ln.id, ids, rule, false, coalesce(p_remember, false), today);
  perform stmt_purge(org, today);
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (org, auth.uid(), 'statement_confirm', 'statement_matches', res->>'match_id', null, jsonb_build_object('rule', rule, 'amount_cents', ln.cents, 'payment_id', res->>'payment_id'));
  return res;
end $$;

create or replace function public.stmt_ignore(p_line uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare org uuid; today date; ln statement_lines; mid uuid := gen_random_uuid();
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select org_id into org from statement_lines where id = p_line;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := stmt_gate(org);
  select * into ln from statement_lines where id = p_line and org_id = org for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  insert into statement_matches(id, org_id, batch_id, fp, occ, line_date, cents, kind, rule, auto, confirmed_by) values (mid, org, ln.batch_id, ln.fp, ln.occ, ln.line_date, ln.cents, 'ignored', 'manual', false, auth.uid());
  delete from statement_lines where id = ln.id and org_id = org;
  return jsonb_build_object('match_id', mid);
end $$;

-- every line of money OUT that is still waiting becomes "not ours" at once
create or replace function public.stmt_ignore_out(p_org uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := stmt_gate(p_org); n int;
begin
  with gone as (delete from statement_lines where org_id = p_org and cents < 0 returning *)
  insert into statement_matches(org_id, batch_id, fp, occ, line_date, cents, kind, rule, auto, confirmed_by)
  select p_org, batch_id, fp, occ, line_date, cents, 'ignored', 'manual', false, auth.uid() from gone;
  get diagnostics n = row_count;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after) values (p_org, auth.uid(), 'statement_ignore_out', 'statement_matches', p_org::text, null, jsonb_build_object('lines', n));
  return jsonb_build_object('ignored', n);
end $$;

create or replace function public.stmt_undo(p_match uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare org uuid; today date; m statement_matches; why text := nullif(trim(coalesce(p_reason, '')), ''); rev jsonb; already boolean := false;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select org_id into org from statement_matches where id = p_match;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := stmt_gate(org);
  select * into m from statement_matches where id = p_match and org_id = org for update;
  if m.reversed_at is not null then return jsonb_build_object('already', true); end if;
  if why is null then raise exception 'REASON_REQUIRED: say why you are undoing this match' using errcode = 'P0001'; end if;
  if length(why) > 300 then raise exception 'TOO_LONG: keep the reason under 300 characters' using errcode = 'P0001'; end if;
  if m.kind = 'invoice' then
    if exists (select 1 from centre_payments where reverses_payment_id = m.payment_id and org_id = org) then already := true;          -- reversed on the Invoices screen already
    else rev := centre_reverse_payment(m.payment_id, why); end if;
  end if;
  update statement_matches set reversed_at = now(), reversed_by = auth.uid(), reverse_reason = why where id = m.id and org_id = org;
  insert into statement_lines(org_id, batch_id, row_no, line_date, cents, fp, occ, stub, reason, purge_after)
  values (org, m.batch_id, 0, m.line_date, m.cents, m.fp, m.occ, true, 'Put back after an undo: only the date and amount are kept.', today + 60);
  perform stmt_purge(org, today);
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (org, auth.uid(), 'statement_undo', 'statement_matches', m.id::text, null, jsonb_build_object('kind', m.kind, 'amount_cents', m.cents, 'payment_already_reversed', already));
  return jsonb_build_object('match_id', m.id, 'payment_already_reversed', already, 'reversal', rev);
end $$;

create or replace function public.stmt_forget_payer(p_link uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare org uuid;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select org_id into org from statement_payer_links where id = p_link;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  perform stmt_gate(org);
  delete from statement_payer_links where id = p_link and org_id = org;
  return jsonb_build_object('forgotten', true);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 8. WHAT THE SCREEN READS (one call)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.stmt_queue(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare today date := stmt_gate(p_org); s jsonb := org_settings_on(p_org, today);
begin
  return jsonb_build_object(
    'settings', jsonb_build_object('auto_confirm', coalesce(s#>>'{payments,statement,auto_confirm}', 'exact_only'),
      'window_before_days', coalesce((s#>>'{payments,statement,window_before_days}')::int, 7), 'window_after_days', coalesce((s#>>'{payments,statement,window_after_days}')::int, 90),
      'partial_payments', coalesce((s#>>'{payments,partial_payments}')::boolean, true), 'overpayments', centre_overpay_mode(s)),
    'review_total', (select count(*) from statement_lines where org_id = p_org),
    'review', coalesce((select jsonb_agg(r order by r->>'line_date', (r->>'row_no')::int) from (
        select jsonb_build_object('id', l.id, 'line_date', l.line_date, 'row_no', l.row_no, 'cents', l.cents, 'ref_text', l.ref_text, 'payer_text', l.payer_text, 'bank_ref', l.bank_ref, 'stub', l.stub,
          'rule', l.sugg_rule, 'exact', l.sugg_exact, 'reason', l.reason, 'purge_after', l.purge_after,
          'household', (select h.name from households h where h.id = l.sugg_household and h.org_id = p_org),
          'invoices', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'number', i.number_text, 'balance_cents', b.balance_cents, 'due_date', i.due_date) order by i.issue_date, i.number_seq)
                                 from centre_invoices i, lateral centre_balance_rows(p_org, array[i.id]) b where i.org_id = p_org and i.id = any(l.sugg_invoice_ids)), '[]'::jsonb)) r
          from statement_lines l where l.org_id = p_org order by l.line_date, l.row_no limit 500) q), '[]'::jsonb),
    'matched', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'line_date', m.line_date, 'cents', m.cents, 'kind', m.kind, 'rule', m.rule, 'auto', m.auto, 'confirmed_at', m.confirmed_at,
          'payment_id', m.payment_id, 'reversed', m.reversed_at is not null,
          'payment_reversed', m.payment_id is not null and exists (select 1 from centre_payments x where x.reverses_payment_id = m.payment_id and x.org_id = p_org),
          'household', (select h.name from households h where h.id = m.household_id and h.org_id = p_org),
          'invoices', coalesce((select jsonb_agg(i.number_text order by i.issue_date, i.number_seq) from centre_payment_allocations a join centre_invoices i on i.id = a.invoice_id and i.org_id = p_org
                                 where a.payment_id = m.payment_id and a.org_id = p_org and a.cents > 0), '[]'::jsonb)) order by m.confirmed_at desc)
        from (select * from statement_matches where org_id = p_org order by confirmed_at desc limit 200) m), '[]'::jsonb),
    'batches', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'account', b.account_label, 'date_from', b.date_from, 'date_to', b.date_to, 'lines', b.n_lines, 'new', b.n_new,
          'duplicates', b.n_duplicate, 'skipped', b.n_skipped, 'auto', b.n_auto, 'review', b.n_review, 'imported_at', b.imported_at) order by b.imported_at desc)
        from (select * from statement_batches where org_id = p_org order by imported_at desc limit 50) b), '[]'::jsonb),
    'payers', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'payer', p.payer_key, 'household', h.name, 'times_used', p.times_used, 'last_used', p.last_used) order by p.last_used desc)
        from statement_payer_links p join households h on h.id = p.household_id and h.org_id = p_org where p.org_id = p_org), '[]'::jsonb),
    'mappings', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'version', x.version, 'mapping', x.mapping) order by x.name)
        from (select distinct on (name) * from statement_mappings where org_id = p_org order by name, version desc) x), '[]'::jsonb),
    'open_invoices', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'number', i.number_text, 'household', h.name, 'balance_cents', b.balance_cents, 'due_date', i.due_date) order by i.issue_date, i.number_seq)
        from centre_invoices i left join households h on h.id = centre_invoice_household(i.id) and h.org_id = p_org,
             lateral centre_balance_rows(p_org, array[i.id]) b
        where i.org_id = p_org and i.status = 'issued' and i.kind <> 'credit_note' and b.balance_cents > 0), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 9. the settings check learns the three statement options (the 1-argument base check from money_settings stays as it is)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.org_validate_settings(p_org uuid, s jsonb) returns void language plpgsql stable security definer set search_path = public as $$
declare st jsonb; v jsonb;
begin
  perform public.org_validate_settings(s);
  if s #>> '{billing,deposit,refund_approved_by}' = 'four_eyes' then
    st := case when p_org is null then jsonb_build_object('owner', true, 'deposit', false, 'credit', false) else public.org_four_eyes_status(p_org) end;
    if not (coalesce((st->>'owner')::boolean, false) and coalesce((st->>'deposit')::boolean, false) and coalesce((st->>'credit')::boolean, false)) then
      raise exception 'FOUR_EYES_UNAVAILABLE: "someone other than the person who asked" needs a second approver: the owner, a staff member who issues invoices (for deposit refunds) and a staff member who records payments (for credit refunds), all active. Add them first, or pick another approver.' using errcode = '42501';
    end if;
  end if;
  -- T34: bank statement matching. Every key is optional (settings saved before this stay valid); a key that is present must be right.
  if s#>>'{payments,statement,auto_confirm}' is not null and s#>>'{payments,statement,auto_confirm}' not in ('exact_only','never') then raise exception 'Unknown statement auto-confirm setting'; end if;
  if s#>>'{payments,statement_bank}' is not null and s#>>'{payments,statement_bank}' not in ('DBS','OCBC','UOB','custom') then raise exception 'Unknown bank for statement matching'; end if;
  v := s #> '{payments,statement,window_before_days}';
  if v is not null and jsonb_typeof(v) <> 'null' and not (case when jsonb_typeof(v) = 'number' and v::text ~ '^[0-9]{1,3}$' then (v#>>'{}')::int between 0 and 30 else false end) then
    raise exception 'Statement matching window before the invoice date must be 0-30 days'; end if;
  v := s #> '{payments,statement,window_after_days}';
  if v is not null and jsonb_typeof(v) <> 'null' and not (case when jsonb_typeof(v) = 'number' and v::text ~ '^[0-9]{1,3}$' then (v#>>'{}')::int between 0 and 365 else false end) then
    raise exception 'Statement matching window after the due date must be 0-365 days'; end if;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 10. who can call what (the SQL helpers and rule functions are internal: server only)
-- ---------------------------------------------------------------------------------------------------
revoke all on function public.stmt_audit() from public, anon, authenticated;
revoke all on function public.stmt_mask_digits(text), public.stmt_norm_payer(text), public.stmt_norm_ref(text), public.stmt_number_pattern(text),
  public.stmt_fp(uuid, text, date, bigint, text, text), public.stmt_subsets(uuid[], bigint[], bigint),
  public.stmt_fp_rows(uuid, text, jsonb), public.stmt_apply_match(uuid, uuid, uuid[], text, boolean, boolean, date), public.stmt_run_rules(uuid, date, uuid),
  public.stmt_purge(uuid, date), public.stmt_gate(uuid) from public, anon, authenticated;
grant execute on function public.stmt_mask_digits(text), public.stmt_norm_payer(text), public.stmt_norm_ref(text), public.stmt_number_pattern(text),
  public.stmt_fp(uuid, text, date, bigint, text, text), public.stmt_subsets(uuid[], bigint[], bigint) to service_role;
revoke all on function public.stmt_save_mapping(uuid, text, jsonb), public.stmt_check(uuid, text, jsonb), public.stmt_import(uuid, text, uuid, jsonb), public.stmt_rematch(uuid),
  public.stmt_confirm(uuid, uuid[], boolean), public.stmt_ignore(uuid), public.stmt_ignore_out(uuid), public.stmt_undo(uuid, text), public.stmt_forget_payer(uuid), public.stmt_queue(uuid) from public, anon;
grant execute on function public.stmt_save_mapping(uuid, text, jsonb), public.stmt_check(uuid, text, jsonb), public.stmt_import(uuid, text, uuid, jsonb), public.stmt_rematch(uuid),
  public.stmt_confirm(uuid, uuid[], boolean), public.stmt_ignore(uuid), public.stmt_ignore_out(uuid), public.stmt_undo(uuid, text), public.stmt_forget_payer(uuid), public.stmt_queue(uuid) to authenticated, service_role;
