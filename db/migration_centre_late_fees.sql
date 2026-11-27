-- =====================================================================================================
-- T4 step S6 — centre late fees: proposals a person approves or waives, recurring each month an invoice stays unpaid   undo: migration_centre_late_fees_down.sql
-- =====================================================================================================
-- Run order everywhere: org_foundation → billing → attendance → tutor_access → org_delete → function_lockdown → org_separation →
--   staff_home → staff_students → staff_attendance → staff_charges → staff_trials → staff_timetable → money_settings →
--   centre_money → centre_invoice_run → centre_payments → centre_deposits → centre_refunds → centre_late_fees.
-- Needs migration_money_settings.sql (S0: the late-fee options), migration_centre_money.sql (S1), migration_centre_invoice_run.sql (S2: issuing),
-- migration_centre_payments.sql (S3: balances). Run on the DEV project first. LIVE only when the owner says ship: this migration reads and changes
-- no existing row (one new table, one widened check on invoice lines, new functions). Safe to run twice.
--
-- WHAT A LATE FEE IS HERE (owner-approved T4 decisions)
--   A late fee is a PROPOSAL first. TutorDeck lists "late fee due" items; a person with issue_invoices (or the owner) APPROVES each one, or WAIVES it
--   with a reason. Nothing is ever added to a family's bill silently, and nothing changes an issued invoice. An approved fee becomes its OWN document
--   (invoice kind 'late_fee', S1), numbered from the one shared invoice series, issued with the usual due days, GST frozen on it per the centre's GST
--   settings of the day it is approved. Because it is an ordinary issued invoice of the family, a payment pays it (oldest first, like any invoice) and it
--   counts in the family's balance, the Money > Invoices list and the revenue totals.
--
-- THE RULES (every value of every late-fee setting is built; money rules read the settings IN FORCE ON THE INVOICE'S DUE DATE, process rules as of TODAY)
--   billing.late_fee.enabled      false → no proposals are made (proposals made earlier stay).
--   billing.late_fee.repeat       none → never · once → one fee per invoice · monthly → AGAIN each month the invoice stays unpaid, on the same day of
--                                 the month as the first fee (the 31st clamps to the last day of shorter months, never drifts: month n is the first
--                                 fee date plus n−1 whole months).
--   billing.late_fee.after_days   the GRACE period. Paying on the due date, or within this many days after it, is on time. The first fee falls due on the
--                                 day AFTER the grace ends (due date + grace + 1). It is unpaid "on" a fee date when nothing had been paid or credited to
--                                 clear it by the END OF THE DAY BEFORE (payments count by the date they were received, credit notes by their issue date).
--   billing.late_fee.type         fixed   → amount_cents, flat, even when the invoice is part-paid.
--                                 percent → percent_bp of the UNPAID BALANCE of that invoice on that date (a part-paid invoice is charged on what is still
--                                           unpaid; half up to the cent).
--   billing.late_fee.cap_cents    0 = no limit; otherwise the most late fees ONE invoice can collect: a fee that would go over is cut to what is left,
--                                 and no more are proposed once it is used up. Waived fees don't count (nothing was collected).
--   billing.late_fee.show_as      own_invoice is built. next_invoice_line (a line on the family's next invoice) is `soon`: until it is built the fee is
--                                 still its own small invoice, and the screen says so.
--   billing.late_fee.waived_by    owner → only the centre owner can waive · issue_invoices → the owner and staff who issue invoices. A reason is always required.
--   FIXED (integrity, not process): lesson invoices only (a deposit, opening, late-fee or credit-note document never gets a late fee, so no compounding);
--   a fee is never proposed on an invoice that is paid, credited in full, or still a draft; a pending proposal STOPS when the invoice is settled
--   (paid or credited) and comes back if a payment is reversed; one fee per invoice per month number (unique), so scanning twice or pressing approve
--   twice never creates twice; an approved or waived fee never changes (a mistake in an approved fee is a credit note on its document).
--
-- HOW: there is no cron. Opening Money > Late fees (centre_late_fee_list) first SCANS the centre (centre_late_fee_scan, idempotent) and then lists what
--   is waiting. The fee amount is frozen on the proposal the day it is first proposed (with a snapshot of the rule) so later settings changes never rewrite it.
--
-- WHO MAY CALL: list / approve / approve all / waive / one invoice's fees: the centre OWNER or STAFF with issue_invoices (waive: see waived_by).
--   Tutors, parents, switched-off staff, staff without issue_invoices, solo owners, strangers and anonymous callers get NOT_FOUND / NOT_ALLOWED. The
--   table can be READ by the same people and has NO write policy: browsers never write a late fee. The scan is server-only.
-- AUDIT: the S1 audit trigger copies every row (free text, i.e. the waive reason, replaced by "[redacted]"); each function adds a summary row with amounts and counts only.
-- =====================================================================================================

-- ---------------------------------------------------------------------------------------------------
-- 1. lines of a late-fee document may say what they are
-- ---------------------------------------------------------------------------------------------------
do $$
declare c record;
begin
  for c in select conname from pg_constraint where conrelid = 'public.centre_invoice_lines'::regclass and contype = 'c'
            and pg_get_constraintdef(oid) like '%fee_kind%' and pg_get_constraintdef(oid) not like '%late_fee%' loop
    execute format('alter table public.centre_invoice_lines drop constraint %I', c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conrelid = 'public.centre_invoice_lines'::regclass and contype = 'c'
                  and pg_get_constraintdef(oid) like '%fee_kind%' and pg_get_constraintdef(oid) like '%late_fee%') then
    alter table public.centre_invoice_lines add constraint centre_invoice_lines_fee_kind_check
      check (fee_kind is null or fee_kind in ('registration', 'materials', 'sibling_discount', 'late_fee'));
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 2. the table: one row per (lesson invoice, month number)
-- ---------------------------------------------------------------------------------------------------
create table if not exists public.centre_late_fees (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organisations(id) on delete cascade,
  invoice_id   uuid not null,                                -- the lesson invoice that is late
  month_no     int  not null check (month_no between 1 and 120),
  fee_date     date not null,                                -- the day this fee fell due: first fee = due date + grace + 1 day, then +1 month each
  status       text not null default 'proposed' check (status in ('proposed', 'approved', 'waived', 'stopped')),
  fee_cents    bigint not null check (fee_cents > 0),        -- frozen when first proposed (before GST handling: GST is worked out when it is approved)
  base_cents   bigint,                                       -- percent fees: the unpaid balance the percentage was taken on (null for a fixed fee)
  rule         jsonb not null,                               -- snapshot of the rule used (repeat, type, amount, percent, grace, cap, show_as)
  household_id uuid,
  student_id   uuid,
  document_id  uuid,                                         -- the late-fee document, once approved
  decided_by   uuid,
  decided_at   timestamptz,
  reason       text,                                         -- waive reason (free text: redacted in the audit copy)
  created_at   timestamptz not null default now(),
  unique (id, org_id),
  unique (invoice_id, month_no),
  unique (document_id),
  foreign key (invoice_id, org_id)  references public.centre_invoices(id, org_id),
  foreign key (document_id, org_id) references public.centre_invoices(id, org_id),
  foreign key (household_id, org_id) references public.households(id, org_id),
  foreign key (student_id, org_id)   references public.students(id, org_id),
  check ((status = 'approved') = (document_id is not null)),
  check (status <> 'waived' or (reason is not null and length(trim(reason)) > 0 and decided_at is not null)),
  check (status not in ('approved', 'waived') or decided_at is not null)
);
create index if not exists centre_late_fees_org on public.centre_late_fees(org_id, status, fee_date);

-- ---------------------------------------------------------------------------------------------------
-- 3. guard: what may change
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_late_fee_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare inv record;
begin
  if tg_op = 'DELETE' then
    if centre_money_deleting(old.org_id) then return old; end if;
    raise exception 'A late fee can''t be deleted (waive it instead)' using errcode = '42501';
  end if;
  if tg_op = 'INSERT' then
    if new.status <> 'proposed' or new.document_id is not null or new.decided_at is not null then
      raise exception 'A late fee starts as a proposal' using errcode = '42501';
    end if;
    select * into inv from centre_invoices where id = new.invoice_id and org_id = new.org_id;
    if inv.id is null or inv.kind <> 'lesson' or inv.status <> 'issued' then
      raise exception 'A late fee can only be proposed on an issued lesson invoice' using errcode = '42501';
    end if;
    return new;
  end if;
  -- UPDATE
  if new.org_id <> old.org_id or new.invoice_id <> old.invoice_id or new.month_no <> old.month_no or new.fee_date <> old.fee_date
     or new.fee_cents <> old.fee_cents or new.base_cents is distinct from old.base_cents or new.rule <> old.rule
     or new.household_id is distinct from old.household_id or new.student_id is distinct from old.student_id then
    raise exception 'A late fee''s amount and invoice never change' using errcode = '42501';
  end if;
  if old.status in ('approved', 'waived') then
    raise exception 'A % late fee can''t be changed (a mistake is corrected with a credit note)', old.status using errcode = '42501';
  end if;
  if new.status = old.status then return new; end if;          -- (a no-op update)
  if old.status = 'proposed' and new.status in ('approved', 'waived', 'stopped') then return new; end if;
  if old.status = 'stopped' and new.status = 'proposed' then return new; end if;
  raise exception 'A late fee can''t go from % to %', old.status, new.status using errcode = '42501';
end $$;

-- the S1 triggers: centres only, audit with redaction
drop trigger if exists centre_money_org_guard on public.centre_late_fees;
create trigger centre_money_org_guard before insert on public.centre_late_fees for each row execute function public.centre_money_org_guard();
drop trigger if exists audit_row on public.centre_late_fees;
create trigger audit_row after insert or update or delete on public.centre_late_fees for each row execute function public.centre_money_audit();
drop trigger if exists centre_late_fee_guard on public.centre_late_fees;
create trigger centre_late_fee_guard before insert or update or delete on public.centre_late_fees for each row execute function public.centre_late_fee_guard();

alter table public.centre_late_fees enable row level security;
drop policy if exists money_read on public.centre_late_fees;
create policy money_read on public.centre_late_fees for select using (org_can(org_id, 'issue_invoices') and not org_is_solo(org_id));
revoke all on public.centre_late_fees from anon, authenticated;
grant select on public.centre_late_fees to authenticated;

-- ---------------------------------------------------------------------------------------------------
-- 4. internal helpers
-- ---------------------------------------------------------------------------------------------------
-- What an invoice still owes at the END of a given day: total − credit notes issued by then − payments received by then (reversals count by their own
-- date). Never below zero. INTERNAL.
create or replace function public.centre_invoice_balance_on(p_invoice uuid, p_day date) returns bigint
language sql stable security definer set search_path = public as $$
  select greatest(i.total_cents
    - coalesce((select sum(n.total_cents) from centre_invoices n where n.credits_invoice_id = i.id and n.status = 'issued' and n.issue_date <= p_day), 0)
    - coalesce((select sum(a.cents) from centre_payment_allocations a join centre_payments p on p.id = a.payment_id and p.org_id = a.org_id
                 where a.invoice_id = i.id and p.received_on <= p_day), 0), 0)::bigint
    from centre_invoices i where i.id = p_invoice
$$;

-- The scan. For every issued lesson invoice that is STILL UNPAID, makes the proposals that have fallen due by p_today and are not made yet, in month
-- order (so the cap is used up in order), then stops proposals whose invoice has been settled and revives them if it is owed again. Returns how many
-- proposals it made. INTERNAL (the list function calls it with the centre's own today; tests call it with any day). Safe to run twice and concurrently.
create or replace function public.centre_late_fee_scan(p_org uuid, p_today date) returns int
language plpgsql security definer set search_path = public as $$
declare inv record; s jsonb; lf jsonb; lastd date := null; rep text; typ text; grace int; amt bigint; bp int; cap bigint; f1 date; fn date; n int; maxn int;
        bal bigint; fee bigint; used bigint; made int := 0; skip boolean := false; rl jsonb; hh uuid;
begin
  if not exists (select 1 from organisations o where o.id = p_org and o.kind = 'centre') then return 0; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_org::text, 11));
  for inv in
    select i.id, i.number_text, i.due_date, i.household_id, i.student_id, i.total_cents
      from centre_invoices i
     where i.org_id = p_org and i.kind = 'lesson' and i.status = 'issued' and i.due_date is not null and i.due_date < p_today
       and centre_invoice_balance_on(i.id, p_today) > 0
     order by i.due_date, i.number_seq
  loop
    if lastd is distinct from inv.due_date then          -- the settings in force on the day the invoice fell due (cached: the loop is ordered by due date)
      s := org_settings_on(p_org, inv.due_date); lf := s #> '{billing,late_fee}'; lastd := inv.due_date;
      rep := coalesce(lf->>'repeat', 'once'); typ := coalesce(lf->>'type', 'fixed'); grace := coalesce((lf->>'after_days')::int, 7);
      amt := coalesce((lf->>'amount_cents')::bigint, 0); bp := coalesce((lf->>'percent_bp')::int, 0); cap := coalesce((lf->>'cap_cents')::bigint, 0);
      skip := not coalesce((lf->>'enabled')::boolean, false) or rep not in ('once', 'monthly');
      rl := jsonb_build_object('repeat', rep, 'type', typ, 'amount_cents', amt, 'percent_bp', bp, 'after_days', grace, 'cap_cents', cap,
                               'show_as', coalesce(lf->>'show_as', 'own_invoice'));
    end if;
    if skip then continue; end if;
    f1 := inv.due_date + grace + 1;
    maxn := case rep when 'once' then 1 else 120 end;
    hh := coalesce(inv.household_id, centre_invoice_household(inv.id));
    for n in 1 .. maxn loop
      fn := (f1 + make_interval(months => n - 1))::date;
      exit when fn > p_today;
      continue when exists (select 1 from centre_late_fees f where f.invoice_id = inv.id and f.month_no = n);
      bal := centre_invoice_balance_on(inv.id, fn - 1);        -- unpaid at the end of the day before the fee date
      continue when bal <= 0;
      fee := case typ when 'percent' then centre_div_round(bal * bp, 10000) else amt end;
      if cap > 0 then
        select coalesce(sum(f.fee_cents), 0) into used from centre_late_fees f where f.invoice_id = inv.id and f.status in ('proposed', 'approved');
        fee := least(fee, cap - used);
      end if;
      continue when fee <= 0;
      insert into centre_late_fees(org_id, invoice_id, month_no, fee_date, fee_cents, base_cents, rule, household_id, student_id)
      values (p_org, inv.id, n, fn, fee, case when typ = 'percent' then bal end, rl, hh, inv.student_id)
      on conflict (invoice_id, month_no) do nothing;
      if found then made := made + 1; end if;
    end loop;
  end loop;
  -- stop / revive: a proposal waits only while its invoice is still owed
  update centre_late_fees f set status = case when b.balance_cents > 0 then 'proposed' else 'stopped' end
    from centre_balance_rows(p_org, (select coalesce(array_agg(distinct x.invoice_id), '{}') from centre_late_fees x where x.org_id = p_org and x.status in ('proposed', 'stopped'))) b
   where f.org_id = p_org and f.invoice_id = b.invoice_id and f.status in ('proposed', 'stopped')
     and f.status <> case when b.balance_cents > 0 then 'proposed' else 'stopped' end;
  return made;
end $$;

-- "who and when" for the screens: owner or staff with issue_invoices; returns the centre's own today
create or replace function public.centre_late_fee_gate(p_org uuid) returns date
language plpgsql stable security definer set search_path = public as $$
begin
  return centre_money_gate(p_org, 'issue_invoices');
end $$;

-- plain words when the centre's option can't be fully acted on (null = nothing to say)
create or replace function public.centre_late_fee_note(p_settings jsonb) returns text
language sql immutable set search_path = public as $$
  select case
    when not coalesce((p_settings #>> '{billing,late_fee,enabled}')::boolean, false) then 'Late fees are switched off for this centre (Centre settings). Proposals made earlier still wait here.'
    when coalesce(p_settings #>> '{billing,late_fee,repeat}', 'once') = 'none' then 'Late fees are set to "never" (Centre settings). Proposals made earlier still wait here.'
    when p_settings #>> '{billing,late_fee,show_as}' = 'next_invoice_line' then 'Your settings ask for a line on the family''s next invoice. That is not built yet: each late fee is its own small invoice for now.'
    end
$$;

-- ---------------------------------------------------------------------------------------------------
-- 5. APPROVE: the fee becomes its own issued document (idempotent)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_late_fee_approve(p_fee uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare org uuid; today date; f centre_late_fees; inv centre_invoices; b record; g record; doc uuid := gen_random_uuid(); d centre_invoices; txt text;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select x.org_id into org from centre_late_fees x where x.id = p_fee;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := centre_late_fee_gate(org);
  perform pg_advisory_xact_lock(hashtextextended(p_fee::text, 12));
  select * into f from centre_late_fees where id = p_fee and org_id = org for update;
  if f.status = 'approved' then                                          -- pressed twice: the same document, nothing new
    select * into d from centre_invoices where id = f.document_id;
    return jsonb_build_object('id', f.id, 'status', 'approved', 'already', true, 'document_id', d.id, 'number', d.number_text, 'total_cents', d.total_cents);
  end if;
  if f.status = 'waived' then raise exception 'NOT_ALLOWED: this late fee was waived' using errcode = '42501'; end if;
  if f.status <> 'proposed' then raise exception 'INVOICE_SETTLED: that invoice has been paid or credited, so no late fee is due' using errcode = 'P0001'; end if;
  select * into inv from centre_invoices where id = f.invoice_id and org_id = org for update;
  select * into b from centre_balance_rows(org, array[f.invoice_id]);
  if b.balance_cents <= 0 then raise exception 'INVOICE_SETTLED: that invoice has been paid or credited, so no late fee is due' using errcode = 'P0001'; end if;
  select * into g from centre_invoice_gst(org, f.fee_cents, today);       -- GST per the centre's settings today, frozen on the document
  txt := 'Late fee: invoice ' || inv.number_text || case when (f.rule->>'repeat') = 'monthly' then ' (month ' || f.month_no || ')' else '' end;
  insert into centre_invoices(id, org_id, kind, household_id, student_id, period_start, period_end, gst_registered, gst_rate_bp, gst_inclusive, net_cents, gst_cents, total_cents)
  values (doc, org, 'late_fee', coalesce(f.household_id, inv.household_id), f.student_id, inv.period_start, inv.period_end, g.gst_registered, g.gst_rate_bp, g.gst_inclusive,
          g.net_cents, g.gst_cents, g.total_cents);
  insert into centre_invoice_lines(org_id, invoice_id, position, student_id, fee_kind, description, qty, unit_cents)
  values (org, doc, 1, f.student_id, 'late_fee', txt, 1, f.fee_cents);
  d := centre_invoice_issue_draft(doc, today);
  update centre_late_fees set status = 'approved', document_id = doc, decided_by = auth.uid(), decided_at = now() where id = f.id;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (org, auth.uid(), 'centre_late_fee_approve', 'centre_late_fees', f.id::text, null,
          jsonb_build_object('fee_cents', f.fee_cents, 'total_cents', d.total_cents, 'gst_cents', d.gst_cents, 'month_no', f.month_no));
  return jsonb_build_object('id', f.id, 'status', 'approved', 'already', false, 'document_id', d.id, 'number', d.number_text, 'total_cents', d.total_cents,
                            'gst_cents', d.gst_cents, 'due_date', d.due_date);
end $$;

-- approve everything that is waiting (each one exactly as above; one that can't be approved is skipped and counted)
create or replace function public.centre_late_fee_approve_all(p_org uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date; r record; ok int := 0; skipped int := 0; cents bigint := 0; res jsonb;
begin
  today := centre_late_fee_gate(p_org);
  perform centre_late_fee_scan(p_org, today);
  for r in select f.id from centre_late_fees f where f.org_id = p_org and f.status = 'proposed' order by f.fee_date, f.created_at, f.id loop
    begin
      res := centre_late_fee_approve(r.id);
      if not coalesce((res->>'already')::boolean, false) then ok := ok + 1; cents := cents + (res->>'total_cents')::bigint; end if;
    exception when others then skipped := skipped + 1; end;
  end loop;
  return jsonb_build_object('approved', ok, 'skipped', skipped, 'total_cents', cents);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 6. WAIVE: needs a reason; who may is the centre's setting
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_late_fee_waive(p_fee uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare org uuid; today date; f centre_late_fees; wb text; why text := nullif(trim(coalesce(p_reason, '')), '');
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select x.org_id into org from centre_late_fees x where x.id = p_fee;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := centre_late_fee_gate(org);
  wb := coalesce(org_settings_on(org, today) #>> '{billing,late_fee,waived_by}', 'owner');
  if wb = 'owner' and not org_can(org, 'owner') then raise exception 'NOT_ALLOWED: only the centre owner can waive a late fee' using errcode = '42501'; end if;
  if why is null then raise exception 'REASON_REQUIRED: say why this late fee is being waived' using errcode = 'P0001'; end if;
  if length(why) > 300 then raise exception 'TOO_LONG: keep the reason under 300 characters' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_fee::text, 12));
  select * into f from centre_late_fees where id = p_fee and org_id = org for update;
  if f.status = 'waived' then return jsonb_build_object('id', f.id, 'status', 'waived', 'already', true); end if;
  if f.status = 'approved' then raise exception 'NOT_ALLOWED: this late fee is already on the family''s account; to take it off, issue a credit note on its invoice' using errcode = '42501'; end if;
  if f.status <> 'proposed' then raise exception 'INVOICE_SETTLED: that invoice has been paid or credited, so there is nothing to waive' using errcode = 'P0001'; end if;
  update centre_late_fees set status = 'waived', reason = why, decided_by = auth.uid(), decided_at = now() where id = f.id;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (org, auth.uid(), 'centre_late_fee_waive', 'centre_late_fees', f.id::text, null, jsonb_build_object('fee_cents', f.fee_cents, 'month_no', f.month_no, 'waived_by_rule', wb));
  return jsonb_build_object('id', f.id, 'status', 'waived', 'already', false, 'fee_cents', f.fee_cents);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 7. WHAT THE SCREENS READ
-- ---------------------------------------------------------------------------------------------------
-- Money > Late fees: scans, then lists "Late fees waiting for you" and the recent decisions.
create or replace function public.centre_late_fee_list(p_org uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := centre_late_fee_gate(p_org); s jsonb := org_settings_on(p_org, today); wb text := coalesce(s #>> '{billing,late_fee,waived_by}', 'owner'); r jsonb;
begin
  perform centre_late_fee_scan(p_org, today);
  with fee as (
    select f.*, i.number_text as inv_number, i.due_date as inv_due, i.total_cents as inv_total, coalesce(h.name, st.name) as nm,
           (select b.balance_cents from centre_balance_rows(p_org, array[f.invoice_id]) b) as bal,
           (select d.number_text from centre_invoices d where d.id = f.document_id) as doc_number
      from centre_late_fees f join centre_invoices i on i.id = f.invoice_id and i.org_id = f.org_id
      left join households h on h.id = coalesce(f.household_id, i.household_id) and h.org_id = f.org_id
      left join students st on st.id = f.student_id and st.org_id = f.org_id
     where f.org_id = p_org
  )
  select jsonb_build_object(
    'today', today, 'enabled', coalesce((s #>> '{billing,late_fee,enabled}')::boolean, false), 'note', centre_late_fee_note(s),
    'repeat', coalesce(s #>> '{billing,late_fee,repeat}', 'once'),
    'can', jsonb_build_object('approve', true, 'waive', wb <> 'owner' or org_can(p_org, 'owner'), 'waived_by', wb),
    'waiting_count', (select count(*) from fee where status = 'proposed'),
    'waiting_cents', (select coalesce(sum(fee_cents), 0) from fee where status = 'proposed'),
    'waiting', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'invoice_id', x.invoice_id, 'invoice_number', x.inv_number, 'name', x.nm, 'household_id', x.household_id,
                 'student_id', x.student_id, 'month_no', x.month_no, 'fee_date', x.fee_date, 'fee_cents', x.fee_cents, 'base_cents', x.base_cents, 'type', x.rule->>'type',
                 'repeat', x.rule->>'repeat', 'invoice_due_date', x.inv_due, 'invoice_total_cents', x.inv_total, 'balance_cents', x.bal, 'days_late', today - x.inv_due,
                 'gst_cents', (select g.gst_cents from centre_invoice_gst(p_org, x.fee_cents, today) g), 'total_cents', (select g.total_cents from centre_invoice_gst(p_org, x.fee_cents, today) g))
                 order by x.fee_date, x.inv_number, x.month_no), '[]'::jsonb) from fee x where x.status = 'proposed'),
    'recent', (select coalesce(jsonb_agg(jsonb_build_object('id', y.id, 'invoice_number', y.inv_number, 'name', y.nm, 'month_no', y.month_no, 'status', y.status, 'fee_cents', y.fee_cents,
                 'decided_at', y.decided_at, 'document_id', y.document_id, 'document_number', y.doc_number, 'reason', y.reason) order by y.decided_at desc), '[]'::jsonb)
                 from (select * from fee where status in ('approved', 'waived') order by decided_at desc limit 50) y))
    into r;
  return r;
end $$;

-- the late fees of ONE invoice (for its detail sheet): waiting, approved (with the document), waived
create or replace function public.centre_late_fee_invoice_get(p_invoice uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare org uuid; r jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select i.org_id into org from centre_invoices i where i.id = p_invoice;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  perform centre_late_fee_gate(org);
  select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'month_no', f.month_no, 'fee_date', f.fee_date, 'status', f.status, 'fee_cents', f.fee_cents,
         'document_id', f.document_id, 'document_number', d.number_text, 'reason', f.reason) order by f.month_no), '[]'::jsonb) into r
    from centre_late_fees f left join centre_invoices d on d.id = f.document_id where f.invoice_id = p_invoice and f.org_id = org and f.status <> 'stopped';
  return r;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 8. function access: signed-in users call the public ones (each starts with the gate); helpers are server-only
-- ---------------------------------------------------------------------------------------------------
revoke all on function public.centre_late_fee_guard() from public, anon, authenticated;
revoke all on function public.centre_invoice_balance_on(uuid, date) from public, anon, authenticated;
revoke all on function public.centre_late_fee_scan(uuid, date) from public, anon, authenticated;
revoke all on function public.centre_late_fee_gate(uuid) from public, anon, authenticated;
revoke all on function public.centre_late_fee_note(jsonb) from public, anon;
revoke all on function public.centre_late_fee_list(uuid) from public, anon;
revoke all on function public.centre_late_fee_approve(uuid) from public, anon;
revoke all on function public.centre_late_fee_approve_all(uuid) from public, anon;
revoke all on function public.centre_late_fee_waive(uuid, text) from public, anon;
revoke all on function public.centre_late_fee_invoice_get(uuid) from public, anon;
grant execute on function public.centre_late_fee_note(jsonb), public.centre_late_fee_list(uuid), public.centre_late_fee_approve(uuid), public.centre_late_fee_approve_all(uuid),
  public.centre_late_fee_waive(uuid, text), public.centre_late_fee_invoice_get(uuid) to authenticated, service_role;
grant execute on function public.centre_invoice_balance_on(uuid, date), public.centre_late_fee_scan(uuid, date) to service_role;
