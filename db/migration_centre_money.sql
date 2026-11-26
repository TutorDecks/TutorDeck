-- =====================================================================================================
-- T4 step S1 — centre money: document, payment and numbering TABLES (database only, no screens)     undo: migration_centre_money_down.sql
-- =====================================================================================================
-- Run order everywhere: org_foundation → billing → attendance → tutor_access → org_delete → function_lockdown → org_separation →
--   staff_home → staff_students → staff_attendance → staff_charges → staff_trials → staff_timetable → centre_money.
-- Run on the DEV project first. LIVE only when the owner says ship (SELECT preview not needed: this adds tables and functions and reads or
-- changes no existing row; its only touch on an existing table is one unique index on lessons(id, org_id), where id is already the key).
-- Safe to run twice.
--
-- WHY NEW TABLES: the solo `invoices` table has tutor_id not null and keeps HTML in `data`, so it stays untouched (solo flows must not change).
-- Everything here lives in centres only: a row for a solo organisation is refused.
--
-- THE TABLES (all have org_id; every link to another table is a composite (id, org_id) key, so a row can never point at another centre's data)
--   org_counters               one counter per organisation and series ('invoice' = lesson + deposit + late-fee documents, ONE gap-free series;
--                              'credit_note' = its own series). The first number can be set once, before anything is issued.
--   centre_invoices            one table for the four kinds of document: lesson / deposit / late_fee / credit_note. draft → issued (or void,
--                              only from draft). A draft has NO number; the number is taken from the counter in the very statement that issues
--                              the document, so a failed issue leaves no gap. Once issued, nothing about it can change (corrections are credit
--                              notes). Money columns are whole cents; the totals must equal centre_gst_totals(...) of the lines.
--   centre_invoice_lines       lines of a DRAFT only (frozen with the invoice); a lesson can be billed once.
--   centre_payments            append-only. A payment is never edited or deleted: a mistake is a REVERSAL row (kind 'reversal', reverses_payment_id).
--   centre_payment_allocations append-only. Which payment covers which invoice, in cents. A reversal's allocations are negative.
--
-- WHO CAN READ (row-level security; centres only, solo owners read nothing): invoices, lines, counters = issue_invoices;
--   payments, allocations = record_payments; totals = centre_revenue_totals() for view_revenue. Owners can do everything. Tutors, parents,
--   switched-off staff, strangers and anonymous callers read nothing. NO table has an insert/update/delete policy: browsers write nothing here;
--   writes come only from functions added in the next steps (S2+). The two functions below that browsers may call do not write money.
--
-- AUDIT: every table has an audit trigger like the rest of the app, but free-text fields (payment reference, payer name, notes, reasons,
--   line descriptions) are replaced by "[redacted]" in the audit copy, because they can hold names and account fragments (PDPA).
-- =====================================================================================================

create unique index if not exists lessons_id_org on public.lessons(id, org_id);

-- ---------------------------------------------------------------------------------------------------
-- 1. whole-cent arithmetic in SQL (the source for issued documents; assets/js/money.js is the same maths in the browser)
-- ---------------------------------------------------------------------------------------------------
-- a / b rounded half AWAY from zero, integers only (b > 0). Mirrors Money.divRound.
create or replace function public.centre_div_round(a bigint, b bigint) returns bigint
language plpgsql immutable set search_path = public as $$
declare x bigint; q bigint;
begin
  if b is null or b <= 0 then raise exception 'denominator must be positive'; end if;
  if a is null then return null; end if;
  x := abs(a); q := x / b;
  if (x - q * b) * 2 >= b then q := q + 1; end if;
  return case when a < 0 then -q else q end;
end $$;

-- GST once per invoice, half up. Mirrors Money.gstForInvoice(subtotal, rateBp, inclusive, registered).
--   exclusive: gst = pct(subtotal), total = subtotal + gst        inclusive: gst = subtotal·rate / (10000 + rate), net = subtotal − gst
--   not registered (or rate 0): no GST.      p_subtotal is the sum of the lines (an inclusive price list sums to the total).
create or replace function public.centre_gst_totals(p_subtotal bigint, p_rate_bp int, p_inclusive boolean, p_registered boolean)
returns table(net_cents bigint, gst_cents bigint, total_cents bigint)
language plpgsql immutable set search_path = public as $$
declare g bigint;
begin
  if p_subtotal is null then raise exception 'subtotal is required'; end if;
  if not coalesce(p_registered, false) or coalesce(p_rate_bp, 0) = 0 then
    return query select p_subtotal, 0::bigint, p_subtotal; return;
  end if;
  if p_rate_bp < 0 or p_rate_bp > 5000 then raise exception 'GST rate must be between 0 and 5000 basis points'; end if;
  if coalesce(p_inclusive, false) then
    g := centre_div_round(p_subtotal * p_rate_bp, 10000 + p_rate_bp);
    return query select p_subtotal - g, g, p_subtotal;
  else
    g := centre_div_round(p_subtotal * p_rate_bp, 10000);
    return query select p_subtotal, g, p_subtotal + g;
  end if;
end $$;

-- The GST rules a centre has on a day (from its settings) applied to a subtotal: what S2 will copy onto a draft before issuing it.
-- Registered or not, rate, and whether prices are entered including GST all come from org_settings_on(org, day).
create or replace function public.centre_invoice_gst(p_org uuid, p_subtotal bigint, p_day date default current_date)
returns table(gst_registered boolean, gst_rate_bp int, gst_inclusive boolean, net_cents bigint, gst_cents bigint, total_cents bigint)
language plpgsql stable security definer set search_path = public as $$
declare s jsonb := org_settings_on(p_org, p_day); reg boolean; rate int; inc boolean;
begin
  if s is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  reg  := coalesce((s#>>'{profile,gst_registered}')::boolean, false);
  rate := case when reg then coalesce((s#>>'{profile,gst_rate_bp}')::int, 0) else 0 end;
  inc  := coalesce((s#>>'{profile,gst_inclusive}')::boolean, false);
  return query select reg, rate, inc, t.net_cents, t.gst_cents, t.total_cents from centre_gst_totals(p_subtotal, rate, inc, reg) t;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 2. the tables
-- ---------------------------------------------------------------------------------------------------
create table if not exists public.org_counters (
  org_id      uuid not null references public.organisations(id) on delete cascade,
  series      text not null check (series in ('invoice', 'credit_note')),
  next_number int  not null default 1 check (next_number >= 1),
  locked      boolean not null default false,        -- true from the first number handed out: the opening number can't be changed any more
  created_at  timestamptz not null default now(),
  primary key (org_id, series)
);

create table if not exists public.centre_invoices (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organisations(id) on delete cascade,
  kind          text not null check (kind in ('lesson', 'deposit', 'late_fee', 'credit_note')),
  series        text generated always as (case when kind = 'credit_note' then 'credit_note' else 'invoice' end) stored,
  status        text not null default 'draft' check (status in ('draft', 'issued', 'void')),
  number_seq    int check (number_seq >= 1),
  number_text   text,
  household_id  uuid,
  student_id    uuid,
  credits_invoice_id uuid,                            -- credit notes only: the invoice being credited
  period_start  date,
  period_end    date,
  issue_date    date,
  due_date      date,
  gst_registered boolean not null default false,      -- the GST rules the totals were computed with (frozen on the document)
  gst_rate_bp   int not null default 0 check (gst_rate_bp between 0 and 5000),
  gst_inclusive boolean not null default false,
  net_cents     bigint not null default 0,            -- before GST (inclusive pricing: the total minus the GST inside it)
  gst_cents     bigint not null default 0,
  total_cents   bigint not null default 0,
  reason        text,                                  -- credit notes: why (free text, redacted in the audit copy)
  void_reason   text,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  issued_by     uuid,
  issued_at     timestamptz,
  voided_at     timestamptz,
  unique (id, org_id),
  foreign key (household_id, org_id) references public.households(id, org_id),
  foreign key (student_id, org_id)   references public.students(id, org_id),
  foreign key (credits_invoice_id, org_id) references public.centre_invoices(id, org_id),
  check (total_cents = net_cents + gst_cents),
  check (net_cents >= 0 and gst_cents >= 0),
  check ((status = 'issued') = (number_seq is not null and number_text is not null)),
  check (status <> 'issued' or (household_id is not null or student_id is not null)),
  check ((kind = 'credit_note') = (credits_invoice_id is not null)),
  check (status <> 'issued' or (issue_date is not null and issued_at is not null)),
  check (period_start is null or period_end is null or period_end >= period_start),
  check (due_date is null or issue_date is null or due_date >= issue_date),
  check (status <> 'void' or (void_reason is not null and voided_at is not null))
);
create unique index if not exists centre_invoices_number on public.centre_invoices(org_id, series, number_seq) where number_seq is not null;
create index if not exists centre_invoices_org on public.centre_invoices(org_id, status, issue_date desc);
create index if not exists centre_invoices_household on public.centre_invoices(org_id, household_id);
create index if not exists centre_invoices_credits on public.centre_invoices(credits_invoice_id) where credits_invoice_id is not null;

create table if not exists public.centre_invoice_lines (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organisations(id) on delete cascade,
  invoice_id  uuid not null,
  position    int  not null default 1 check (position >= 1),
  lesson_id   uuid,                                    -- the lesson this line bills (lesson invoices); a lesson is billed once
  description text not null check (length(trim(description)) between 1 and 300),
  qty         int  not null default 1 check (qty >= 1),
  unit_cents  bigint not null,                         -- negative = a discount line
  line_cents  bigint generated always as (qty * unit_cents) stored,
  created_at  timestamptz not null default now(),
  unique (id, org_id),
  foreign key (invoice_id, org_id) references public.centre_invoices(id, org_id) on delete cascade,
  foreign key (lesson_id, org_id)  references public.lessons(id, org_id)
);
create index if not exists centre_invoice_lines_invoice on public.centre_invoice_lines(invoice_id);
create index if not exists centre_invoice_lines_lesson on public.centre_invoice_lines(lesson_id) where lesson_id is not null;

create table if not exists public.centre_payments (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organisations(id) on delete cascade,
  kind          text not null default 'payment' check (kind in ('payment', 'reversal')),
  reverses_payment_id uuid,                            -- a reversal row points at the payment it cancels (that payment is "reversed by" this row)
  household_id  uuid not null,
  method        text not null check (method in ('manual_paynow', 'bank', 'cash', 'cheque', 'other')),
  amount_cents  bigint not null check (amount_cents > 0),
  received_on   date not null,
  reference     text,                                  -- free text (invoice number, bank reference...). Never a full account number. Redacted in audit.
  payer_name    text,
  note          text,
  recorded_by   uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  unique (id, org_id),
  foreign key (household_id, org_id) references public.households(id, org_id),
  foreign key (reverses_payment_id, org_id) references public.centre_payments(id, org_id),
  check ((kind = 'reversal') = (reverses_payment_id is not null))
);
create unique index if not exists centre_payments_one_reversal on public.centre_payments(reverses_payment_id) where reverses_payment_id is not null;
create index if not exists centre_payments_org on public.centre_payments(org_id, received_on desc);
create index if not exists centre_payments_household on public.centre_payments(org_id, household_id);

create table if not exists public.centre_payment_allocations (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organisations(id) on delete cascade,
  payment_id  uuid not null,
  invoice_id  uuid not null,
  cents       bigint not null check (cents <> 0),      -- positive on a payment, negative on its reversal
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  unique (id, org_id),
  foreign key (payment_id, org_id) references public.centre_payments(id, org_id),
  foreign key (invoice_id, org_id) references public.centre_invoices(id, org_id)
);
create index if not exists centre_alloc_payment on public.centre_payment_allocations(payment_id);
create index if not exists centre_alloc_invoice on public.centre_payment_allocations(invoice_id);

-- ---------------------------------------------------------------------------------------------------
-- 3. guards
-- ---------------------------------------------------------------------------------------------------
-- 3a. centres only
create or replace function public.centre_money_org_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from organisations o where o.id = new.org_id and o.kind = 'centre') then
    raise exception 'Centre money tables are for centres only' using errcode = '42501';
  end if;
  return new;
end $$;

-- the shared exception for deleting a whole organisation (same rule as audit_immutable: only inside org_delete_solo, never a browser role)
create or replace function public.centre_money_deleting(p_org uuid) returns boolean
language sql stable set search_path = public as $$
  select coalesce(current_setting('td.deleting_org', true), '') <> '' and coalesce(current_setting('td.deleting_org', true), '') = p_org::text
         and current_user not in ('anon', 'authenticated', 'service_role')
$$;

-- 3b. numbering: take the next number of a series. INTERNAL (no browser may call it). Gap-free because the counter row is locked and
--     incremented inside the transaction that issues the document: if that transaction fails, the increment is rolled back with it.
create or replace function public.centre_next_number(p_org uuid, p_series text) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if p_series not in ('invoice', 'credit_note') then raise exception 'Unknown number series'; end if;
  insert into org_counters(org_id, series) values (p_org, p_series) on conflict (org_id, series) do nothing;
  update org_counters set next_number = next_number + 1, locked = true
   where org_id = p_org and series = p_series returning next_number - 1 into n;
  return n;
end $$;

-- the opening number: "the next document will be number p_next". Owner only, centres only, only before the first number was handed out.
create or replace function public.centre_set_opening_number(p_org uuid, p_series text, p_next int) returns int
language plpgsql security definer set search_path = public as $$
declare cur record;
begin
  if auth.uid() is null or not exists (select 1 from organisations o where o.id = p_org and o.kind = 'centre') or not org_can(p_org, 'owner') then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if p_series not in ('invoice', 'credit_note') then raise exception 'NOT_ALLOWED: unknown number series' using errcode = '42501'; end if;
  if p_next is null or p_next < 1 or p_next > 999999999 then raise exception 'NOT_ALLOWED: the opening number must be a whole number from 1' using errcode = '42501'; end if;
  insert into org_counters(org_id, series) values (p_org, p_series) on conflict (org_id, series) do nothing;
  select * into cur from org_counters where org_id = p_org and series = p_series for update;
  if cur.locked or exists (select 1 from centre_invoices i where i.org_id = p_org and i.series = p_series and i.number_seq is not null) then
    raise exception 'NOT_ALLOWED: numbers have already been issued, so the opening number can''t be changed' using errcode = '42501';
  end if;
  update org_counters set next_number = p_next where org_id = p_org and series = p_series;
  return p_next;
end $$;

-- counters only ever go forward by one, and only once locked; the opening number may move freely before that
create or replace function public.centre_counter_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    if centre_money_deleting(old.org_id) then return old; end if;
    raise exception 'org_counters is append-only';
  end if;
  if new.org_id <> old.org_id or new.series <> old.series then raise exception 'A counter can''t move'; end if;
  if old.locked and (not new.locked or new.next_number <> old.next_number + 1) then
    raise exception 'A document number can only go forward by one (numbers are never reused or skipped)';
  end if;
  if not old.locked and new.locked and new.next_number <> old.next_number + 1 then
    raise exception 'A document number can only go forward by one (numbers are never reused or skipped)';
  end if;
  return new;
end $$;

-- 3c. the invoice: draft → issued (number + frozen totals checked) | void; nothing else; issued and void rows never change
create or replace function public.centre_invoice_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare s jsonb; prefix text; sub bigint; nlines int; t record; credited bigint; inv record; day date;
begin
  if tg_op = 'DELETE' then
    if old.status = 'draft' or centre_money_deleting(old.org_id) then return old; end if;
    raise exception 'An issued or voided document can''t be deleted (issue a credit note instead)' using errcode = '42501';
  end if;
  if tg_op = 'INSERT' then
    if new.status <> 'draft' or new.number_seq is not null or new.number_text is not null then
      raise exception 'A new document starts as a draft with no number' using errcode = '42501';
    end if;
    return new;
  end if;
  -- UPDATE
  if old.status <> 'draft' then
    raise exception 'An % document can''t be changed (issue a credit note instead)', old.status using errcode = '42501';
  end if;
  if new.org_id <> old.org_id or new.kind <> old.kind then raise exception 'A document''s organisation and kind can''t change'; end if;
  if new.status = 'draft' then
    if new.number_seq is not null or new.number_text is not null then raise exception 'A draft has no number; it is given one when issued' using errcode = '42501'; end if;
    return new;
  end if;
  if new.status = 'void' then
    new.voided_at := coalesce(new.voided_at, now());
    if new.number_seq is not null or new.number_text is not null then raise exception 'A voided draft has no number' using errcode = '42501'; end if;
    return new;
  end if;
  -- issuing: validate, take the number, freeze
  select coalesce(sum(line_cents), 0), count(*) into sub, nlines from centre_invoice_lines where invoice_id = new.id;
  if nlines = 0 then raise exception 'A document needs at least one line before it is issued' using errcode = '42501'; end if;
  select * into t from centre_gst_totals(sub, new.gst_rate_bp, new.gst_inclusive, new.gst_registered);
  if t.net_cents <> new.net_cents or t.gst_cents <> new.gst_cents or t.total_cents <> new.total_cents then
    raise exception 'The totals don''t match the lines (expected net %, GST %, total %)', t.net_cents, t.gst_cents, t.total_cents using errcode = '42501';
  end if;
  if new.total_cents < 0 then raise exception 'A document''s total can''t be negative' using errcode = '42501'; end if;
  if new.kind = 'credit_note' then
    select * into inv from centre_invoices where id = new.credits_invoice_id and org_id = new.org_id;
    if inv.id is null or inv.status <> 'issued' or inv.kind = 'credit_note' then
      raise exception 'A credit note must credit an issued invoice' using errcode = '42501';
    end if;
    if new.reason is null or length(trim(new.reason)) = 0 then raise exception 'A credit note needs a reason' using errcode = '42501'; end if;
    perform pg_advisory_xact_lock(hashtextextended(inv.id::text, 0));
    select coalesce(sum(total_cents), 0) into credited from centre_invoices
     where credits_invoice_id = inv.id and status = 'issued' and id <> new.id;
    if credited + new.total_cents > inv.total_cents then
      raise exception 'Credit notes can''t add up to more than the invoice (invoice %, already credited %, this one %)', inv.total_cents, credited, new.total_cents using errcode = '42501';
    end if;
    if inv.household_id is distinct from new.household_id or inv.student_id is distinct from new.student_id then
      raise exception 'A credit note must be for the same household and student as its invoice' using errcode = '42501';
    end if;
  end if;
  day := coalesce(new.issue_date, (now() at time zone coalesce((select timezone from organisations where id = new.org_id), 'Asia/Singapore'))::date);
  s := org_settings_on(new.org_id, day);
  prefix := coalesce(nullif(trim(s#>>'{profile,invoice_prefix}'), ''), 'INV');
  new.number_seq := centre_next_number(new.org_id, case when new.kind = 'credit_note' then 'credit_note' else 'invoice' end);   -- (generated columns are not filled yet in a BEFORE trigger)
  new.number_text := case when new.kind = 'credit_note' then 'CN-' else '' end || prefix || '-' || new.number_seq;
  new.issue_date := day;
  new.issued_at := now();
  new.issued_by := coalesce(auth.uid(), new.created_by);
  return new;
end $$;

-- 3d. lines: only while the invoice is a draft; a lesson is billed once
create or replace function public.centre_line_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare inv record; r record := case when tg_op = 'DELETE' then old else new end;
begin
  select * into inv from centre_invoices where id = r.invoice_id and org_id = r.org_id;
  if inv.id is null then
    if tg_op = 'DELETE' then return old; end if;            -- the draft itself is being deleted (cascade)
    raise exception 'Unknown document';
  end if;
  if inv.status <> 'draft' then
    raise exception 'The lines of an % document can''t be changed (issue a credit note instead)', inv.status using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if tg_op = 'UPDATE' and (new.invoice_id <> old.invoice_id or new.org_id <> old.org_id) then raise exception 'A line can''t move to another document'; end if;
  if new.lesson_id is not null and (inv.kind = 'credit_note') then
    raise exception 'A credit note can''t bill a lesson' using errcode = '42501';
  end if;
  if new.lesson_id is not null and (tg_op = 'INSERT' or new.lesson_id is distinct from old.lesson_id) then
    perform pg_advisory_xact_lock(hashtextextended(new.lesson_id::text, 1));
    if exists (select 1 from centre_invoice_lines l join centre_invoices i on i.id = l.invoice_id and i.org_id = l.org_id
                where l.lesson_id = new.lesson_id and l.id <> new.id and i.status <> 'void') then
      raise exception 'That lesson is already billed on another document' using errcode = '23505';
    end if;
  end if;
  return new;
end $$;

-- 3e. payments: append-only; a reversal must match what it cancels. The household must own... (the household of the payment is checked by the FK)
create or replace function public.centre_payment_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare p record;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    if tg_op = 'DELETE' and centre_money_deleting(old.org_id) then return old; end if;
    raise exception '% is append-only (record a reversal instead)', tg_table_name using errcode = '42501';
  end if;
  if new.kind = 'reversal' then
    select * into p from centre_payments where id = new.reverses_payment_id and org_id = new.org_id;
    if p.id is null or p.kind <> 'payment' then raise exception 'A reversal must cancel a payment of this centre' using errcode = '42501'; end if;
    if new.amount_cents <> p.amount_cents or new.household_id <> p.household_id or new.method <> p.method then
      raise exception 'A reversal must repeat the payment it cancels (same household, method and amount)' using errcode = '42501';
    end if;
    if new.received_on < p.received_on then raise exception 'A reversal can''t be dated before the payment' using errcode = '42501'; end if;
  end if;
  return new;
end $$;

-- a reversed payment must not keep money allocated: checked when the transaction commits, so the reversal and its negative allocations can be
-- written in either order inside one transaction
create or replace function public.centre_payment_reversal_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare net bigint;
begin
  select coalesce(sum(a.cents), 0) into net from centre_payment_allocations a
   where a.org_id = new.org_id and a.payment_id in (new.id, new.reverses_payment_id);
  if net <> 0 then
    raise exception 'A reversed payment can''t keep money allocated to invoices (still allocated: % cents)', net using errcode = '23514';
  end if;
  return null;
end $$;

-- 3f. allocations: append-only; never more than the payment, never more than the invoice
create or replace function public.centre_alloc_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare p record; inv record; root uuid; pay_total bigint; chain_inv bigint; inv_total bigint; credited bigint;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    if tg_op = 'DELETE' and centre_money_deleting(old.org_id) then return old; end if;
    raise exception '% is append-only (reverse the payment instead)', tg_table_name using errcode = '42501';
  end if;
  select * into p from centre_payments where id = new.payment_id and org_id = new.org_id;
  select * into inv from centre_invoices where id = new.invoice_id and org_id = new.org_id;
  if p.id is null or inv.id is null then raise exception 'Unknown payment or invoice'; end if;
  if inv.status <> 'issued' or inv.kind = 'credit_note' then raise exception 'Money can only be allocated to an issued invoice' using errcode = '42501'; end if;
  if inv.household_id is distinct from p.household_id and not exists (select 1 from students s where s.id = inv.student_id and s.org_id = inv.org_id and s.household_id = p.household_id) then
    raise exception 'The payment and the invoice belong to different households' using errcode = '42501';
  end if;
  if p.kind = 'payment' and new.cents < 0 then raise exception 'A payment can only be allocated, not negatively' using errcode = '42501'; end if;
  if p.kind = 'reversal' and new.cents > 0 then raise exception 'A reversal can only un-allocate (negative cents)' using errcode = '42501'; end if;
  root := coalesce(p.reverses_payment_id, p.id);
  perform pg_advisory_xact_lock(hashtextextended(root::text, 2));
  perform pg_advisory_xact_lock(hashtextextended(inv.id::text, 3));
  -- per payment (with its reversal): between 0 and the amount
  select coalesce(sum(a.cents), 0) + new.cents into pay_total from centre_payment_allocations a
   where a.org_id = new.org_id and a.payment_id in (select id from centre_payments where org_id = new.org_id and (id = root or reverses_payment_id = root));
  if pay_total > (select amount_cents from centre_payments where id = root and org_id = new.org_id) then
    raise exception 'Allocations can''t add up to more than the payment' using errcode = '23514';
  end if;
  if pay_total < 0 then raise exception 'Allocations can''t go below zero' using errcode = '23514'; end if;
  -- this payment's share of this invoice stays between 0 and what it put there
  select coalesce(sum(a.cents), 0) + new.cents into chain_inv from centre_payment_allocations a
   where a.org_id = new.org_id and a.invoice_id = new.invoice_id
     and a.payment_id in (select id from centre_payments where org_id = new.org_id and (id = root or reverses_payment_id = root));
  if chain_inv < 0 then raise exception 'Can''t un-allocate more than was allocated to that invoice' using errcode = '23514'; end if;
  -- per invoice: never more than what is still owed after credit notes
  select coalesce(sum(a.cents), 0) + new.cents into inv_total from centre_payment_allocations a where a.org_id = new.org_id and a.invoice_id = new.invoice_id;
  select coalesce(sum(c.total_cents), 0) into credited from centre_invoices c where c.credits_invoice_id = inv.id and c.status = 'issued';
  if inv_total > inv.total_cents - credited then
    raise exception 'Allocations can''t add up to more than the invoice (invoice %, credited %, allocated would be %)', inv.total_cents, credited, inv_total using errcode = '23514';
  end if;
  return new;
end $$;

-- 3g. audit with redaction (same shape as audit_row, plus free-text fields replaced)
create or replace function public.centre_money_audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare b jsonb; a jsonb; k text; redact text[] := array['reference', 'payer_name', 'note', 'reason', 'void_reason', 'description'];
begin
  if coalesce(current_setting('td.skip_audit', true), '') = '1' then return null; end if;
  b := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  a := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  foreach k in array redact loop
    if b ? k and b->>k is not null then b := jsonb_set(b, array[k], '"[redacted]"'); end if;
    if a ? k and a->>k is not null then a := jsonb_set(a, array[k], '"[redacted]"'); end if;
  end loop;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (coalesce((a->>'org_id')::uuid, (b->>'org_id')::uuid), auth.uid(), lower(tg_op), tg_table_name,
          coalesce(a->>'id', b->>'id', coalesce(a->>'org_id', b->>'org_id') || ':' || coalesce(a->>'series', b->>'series')), b, a);
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['org_counters', 'centre_invoices', 'centre_invoice_lines', 'centre_payments', 'centre_payment_allocations'] loop
    execute format('drop trigger if exists centre_money_org_guard on public.%I', t);
    execute format('create trigger centre_money_org_guard before insert on public.%I for each row execute function public.centre_money_org_guard()', t);
    execute format('drop trigger if exists audit_row on public.%I', t);
    execute format('create trigger audit_row after insert or update or delete on public.%I for each row execute function public.centre_money_audit()', t);
  end loop;
end $$;
drop trigger if exists centre_counter_guard on public.org_counters;
create trigger centre_counter_guard before update or delete on public.org_counters for each row execute function public.centre_counter_guard();
drop trigger if exists centre_invoice_guard on public.centre_invoices;
create trigger centre_invoice_guard before insert or update or delete on public.centre_invoices for each row execute function public.centre_invoice_guard();
drop trigger if exists centre_line_guard on public.centre_invoice_lines;
create trigger centre_line_guard before insert or update or delete on public.centre_invoice_lines for each row execute function public.centre_line_guard();
drop trigger if exists centre_payment_guard on public.centre_payments;
create trigger centre_payment_guard before insert or update or delete on public.centre_payments for each row execute function public.centre_payment_guard();
drop trigger if exists centre_payment_reversal_check on public.centre_payments;
create constraint trigger centre_payment_reversal_check after insert on public.centre_payments deferrable initially deferred
  for each row when (new.kind = 'reversal') execute function public.centre_payment_reversal_check();
drop trigger if exists centre_alloc_guard on public.centre_payment_allocations;
create trigger centre_alloc_guard before insert or update or delete on public.centre_payment_allocations for each row execute function public.centre_alloc_guard();

-- ---------------------------------------------------------------------------------------------------
-- 4. access: read only, by permission; nobody writes from a browser
-- ---------------------------------------------------------------------------------------------------
alter table public.org_counters enable row level security;
alter table public.centre_invoices enable row level security;
alter table public.centre_invoice_lines enable row level security;
alter table public.centre_payments enable row level security;
alter table public.centre_payment_allocations enable row level security;

drop policy if exists money_read on public.org_counters;
create policy money_read on public.org_counters for select using (org_can(org_id, 'issue_invoices') and not org_is_solo(org_id));
drop policy if exists money_read on public.centre_invoices;
create policy money_read on public.centre_invoices for select using (org_can(org_id, 'issue_invoices') and not org_is_solo(org_id));
drop policy if exists money_read on public.centre_invoice_lines;
create policy money_read on public.centre_invoice_lines for select using (org_can(org_id, 'issue_invoices') and not org_is_solo(org_id));
drop policy if exists money_read on public.centre_payments;
create policy money_read on public.centre_payments for select using (org_can(org_id, 'record_payments') and not org_is_solo(org_id));
drop policy if exists money_read on public.centre_payment_allocations;
create policy money_read on public.centre_payment_allocations for select using (org_can(org_id, 'record_payments') and not org_is_solo(org_id));

-- Supabase hands every new table to anon and authenticated: take everything back, then give signed-in users SELECT only (RLS filters the rows)
revoke all on public.org_counters, public.centre_invoices, public.centre_invoice_lines, public.centre_payments, public.centre_payment_allocations from anon, authenticated;
grant select on public.org_counters, public.centre_invoices, public.centre_invoice_lines, public.centre_payments, public.centre_payment_allocations to authenticated;

-- totals for people with view_revenue (the money screens in S3+ read this, not the tables)
create or replace function public.centre_revenue_totals(p_org uuid, p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if auth.uid() is null or not exists (select 1 from organisations o where o.id = p_org and o.kind = 'centre') or not org_can(p_org, 'view_revenue') then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  select jsonb_build_object(
    'invoiced_cents',  coalesce(sum(i.total_cents) filter (where i.kind <> 'credit_note'), 0),
    'gst_cents',       coalesce(sum(i.gst_cents) filter (where i.kind <> 'credit_note'), 0) - coalesce(sum(i.gst_cents) filter (where i.kind = 'credit_note'), 0),
    'credited_cents',  coalesce(sum(i.total_cents) filter (where i.kind = 'credit_note'), 0),
    'invoices',        count(*) filter (where i.kind <> 'credit_note'))
    into r from centre_invoices i
   where i.org_id = p_org and i.status = 'issued' and (p_from is null or i.issue_date >= p_from) and (p_to is null or i.issue_date <= p_to);
  r := r || jsonb_build_object('received_cents', coalesce((select sum(case when p.kind = 'payment' then p.amount_cents else -p.amount_cents end)
       from centre_payments p where p.org_id = p_org and (p_from is null or p.received_on >= p_from) and (p_to is null or p.received_on <= p_to)), 0));
  return r;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 5. function access: internal ones are server-only; trigger functions are not an API
-- ---------------------------------------------------------------------------------------------------
revoke all on function public.centre_next_number(uuid, text) from public, anon, authenticated;
revoke all on function public.centre_money_org_guard() from public, anon, authenticated;
revoke all on function public.centre_counter_guard() from public, anon, authenticated;
revoke all on function public.centre_invoice_guard() from public, anon, authenticated;
revoke all on function public.centre_line_guard() from public, anon, authenticated;
revoke all on function public.centre_payment_guard() from public, anon, authenticated;
revoke all on function public.centre_payment_reversal_check() from public, anon, authenticated;
revoke all on function public.centre_alloc_guard() from public, anon, authenticated;
revoke all on function public.centre_money_audit() from public, anon, authenticated;
revoke all on function public.centre_money_deleting(uuid) from public, anon;
revoke all on function public.centre_div_round(bigint, bigint) from public, anon;
revoke all on function public.centre_gst_totals(bigint, int, boolean, boolean) from public, anon;
revoke all on function public.centre_set_opening_number(uuid, text, int) from public, anon;
revoke all on function public.centre_revenue_totals(uuid, date, date) from public, anon;
revoke all on function public.centre_invoice_gst(uuid, bigint, date) from public, anon;
grant execute on function public.centre_invoice_gst(uuid, bigint, date) to authenticated, service_role;
grant execute on function public.centre_div_round(bigint, bigint), public.centre_gst_totals(bigint, int, boolean, boolean) to authenticated, service_role;
grant execute on function public.centre_set_opening_number(uuid, text, int), public.centre_revenue_totals(uuid, date, date) to authenticated, service_role;
grant execute on function public.centre_next_number(uuid, text) to service_role;
