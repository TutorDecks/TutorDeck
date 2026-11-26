-- Undo of migration_centre_deposits.sql (T4 step S4): puts back the S1 / S2 functions it replaced, drops the deposit tables, functions and columns.
-- DESTRUCTIVE: it deletes the deposit ledger (a money record). Only for DEV and the test database; on a centre that holds real deposits, don't.
-- If an OPENING invoice exists, the widened checks and the imported_number column are KEPT (they would otherwise destroy an issued invoice); everything else is undone.
-- Deposit invoices already issued stay (kind 'deposit' was always allowed by S1). Run the undo chain in reverse order.
-- The functions at the end are the exact S1 / S2 versions.
drop trigger if exists centre_deposit_alloc_hook on public.centre_payment_allocations;
drop table if exists public.centre_deposit_ledger cascade;
drop table if exists public.centre_deposits cascade;
drop function if exists public.centre_deposit_alloc_hook();
drop function if exists public.centre_deposit_ledger_guard();
drop function if exists public.centre_deposit_guard();
drop function if exists public.centre_deposit_opening_balance(uuid, bigint, date, text);
drop function if exists public.centre_deposit_waive(uuid, text);
drop function if exists public.centre_deposit_ledger_get(uuid, uuid);
drop function if exists public.centre_deposits_held(uuid);
drop function if exists public.centre_deposit_status(uuid, uuid);
drop function if exists public.centre_deposit_make_invoice(uuid, uuid, uuid, bigint, boolean, text, int, bigint, date, date, date);
drop function if exists public.centre_deposit_run_candidates(uuid, date, date);
drop function if exists public.centre_deposit_note(jsonb);
drop function if exists public.centre_deposit_gate(uuid, text);
drop index if exists public.centre_invoices_one_deposit;
do $$ begin
  if exists (select 1 from public.centre_invoices where kind = 'opening') then
    raise notice 'Opening invoices exist: the widened kind / number checks and centre_invoices.imported_number are kept';
  else
    drop index if exists public.centre_invoices_opening_number;
    alter table public.centre_invoices drop constraint if exists centre_invoices_imported_ck;
    alter table public.centre_invoices drop constraint if exists centre_invoices_number_ck;
    alter table public.centre_invoices drop constraint if exists centre_invoices_kind_ck;
    alter table public.centre_invoices drop column if exists imported_number;
    alter table public.centre_invoices add constraint centre_invoices_kind_check check (kind in ('lesson', 'deposit', 'late_fee', 'credit_note'));
    alter table public.centre_invoices add constraint centre_invoices_number_orig check ((status = 'issued') = (number_seq is not null and number_text is not null));
  end if;
end $$;
alter table public.students drop column if exists start_date;

-- the S1 / S2 functions, as they were
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

create or replace function public.centre_invoice_run_preview(p_org uuid, p_period date) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := centre_invoicing_gate(p_org); ms date := centre_invoice_month(p_period, today); me date := (ms + interval '1 month - 1 day')::date;
  s jsonb := coalesce(org_settings_on(p_org, ms), org_settings_on(p_org, today)); note text; res jsonb;
begin
  if s is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  note := centre_invoice_model_note(s);
  res := jsonb_build_object('today', today, 'period_start', ms, 'period_end', me, 'model', coalesce(s#>>'{billing,model}', 'postpaid_lessons'),
           'fixed_period', coalesce(s#>>'{billing,fixed_period}', 'month'), 'grouping', coalesce(s#>>'{invoicing,grouping}', 'family'),
           'review_before_sending', coalesce((s#>>'{invoicing,review_before_sending}')::boolean, true),
           'due_days', coalesce((s#>>'{invoicing,due_days}')::int, 7),
           'built', note is null, 'message', note);
  if note is not null then
    return res || jsonb_build_object('ready', '[]'::jsonb, 'held_back', '[]'::jsonb, 'drafts', '[]'::jsonb,
                                     'totals', jsonb_build_object('ready', 0, 'held_back', 0, 'drafts', 0, 'lessons', 0, 'subtotal_cents', 0, 'gst_cents', 0, 'total_cents', 0));
  end if;
  perform centre_invoice_run_prepare(p_org, ms, today);
  return res || jsonb_build_object(
    'ready', (select coalesce(jsonb_agg(jsonb_build_object(
        'key', u.unit_key, 'name', u.uname, 'household_id', u.hid, 'student_id', u.ustu, 'lessons', u.n_lessons,
        'subtotal_cents', u.subtotal, 'net_cents', u.net, 'gst_cents', u.gst, 'total_cents', u.total,
        'not_marked', u.n_unmarked, 'no_price', u.n_no_price, 'free_trials', u.n_free,
        'lines', (select jsonb_agg(jsonb_build_object('kind', r.line_kind, 'lesson_id', r.lesson_id, 'student_id', r.student_id, 'student_name', r.student_name,
                                                      'date', r.lesson_date, 'description', r.description, 'qty', r.qty, 'unit_cents', r.unit_cents,
                                                      'line_cents', r.qty * r.unit_cents)
                                       order by r.student_name, r.ord, r.lesson_date, r.start_time, r.lesson_id)
                    from _td_run r where r.unit_key = u.unit_key and r.state = 'line')) order by u.uname, u.unit_key), '[]'::jsonb)
                from _td_units u where u.status = 'ready'),
    'held_back', (select coalesce(jsonb_agg(jsonb_build_object(
        'key', u.unit_key, 'name', u.uname, 'household_id', u.hid, 'student_id', u.ustu, 'not_marked', u.n_unmarked,
        'reasons', (select jsonb_agg(jsonb_build_object('reason', 'charge pending: ' || x.sname, 'student_id', x.sid, 'student_name', x.sname, 'lessons', x.n)
                                    order by x.sname) from (select r.student_name as sname, r.student_id as sid, count(*)::int as n
                                                              from _td_run r where r.unit_key = u.unit_key and r.state = 'pending' group by 1, 2) x),
        'lessons', (select jsonb_agg(jsonb_build_object('lesson_id', r.lesson_id, 'student_name', r.student_name, 'date', r.lesson_date) order by r.lesson_date, r.student_name)
                      from _td_run r where r.unit_key = u.unit_key and r.state = 'pending')) order by u.uname, u.unit_key), '[]'::jsonb)
                from _td_units u where u.status = 'held'),
    'drafts', (select coalesce(jsonb_agg(jsonb_build_object('key', u.unit_key, 'name', u.uname, 'invoice_id', u.draft_id, 'household_id', u.hid, 'student_id', u.ustu,
                                                            'total_cents', (select i.total_cents from centre_invoices i where i.id = u.draft_id), 'new_lessons', u.n_lessons)
                                         order by u.uname, u.unit_key), '[]'::jsonb) from _td_units u where u.status = 'draft'),
    'totals', jsonb_build_object(
        'ready',     (select count(*) from _td_units where status = 'ready'),
        'held_back', (select count(*) from _td_units where status = 'held'),
        'drafts',    (select count(*) from _td_units where status = 'draft'),
        'lessons',   (select coalesce(sum(n_lessons), 0) from _td_units where status = 'ready'),
        'not_marked',(select coalesce(sum(n_unmarked), 0) from _td_units),
        'subtotal_cents', (select coalesce(sum(subtotal), 0) from _td_units where status = 'ready'),
        'gst_cents',      (select coalesce(sum(gst), 0) from _td_units where status = 'ready'),
        'total_cents',    (select coalesce(sum(total), 0) from _td_units where status = 'ready')));
end $$;

create or replace function public.centre_invoice_run_create_drafts(p_org uuid, p_period date) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := centre_invoicing_gate(p_org); ms date := centre_invoice_month(p_period, today); me date := (ms + interval '1 month - 1 day')::date;
  s jsonb := coalesce(org_settings_on(p_org, ms), org_settings_on(p_org, today)); note text; review boolean; u record; inv uuid; made jsonb := '[]'::jsonb;
  n_made int := 0; n_issued int := 0; n_held int; n_draft int; n_empty int; iss centre_invoices;
begin
  if s is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  note := centre_invoice_model_note(s);
  if note is not null then raise exception 'NOT_BUILT: %', note using errcode = 'P0001'; end if;
  review := coalesce((s#>>'{invoicing,review_before_sending}')::boolean, true);
  perform pg_advisory_xact_lock(hashtextextended(p_org::text || ':' || ms::text, 77));      -- two people pressing the button at once: one waits
  perform centre_invoice_run_prepare(p_org, ms, today);
  for u in select * from _td_units where status = 'ready' order by uname, unit_key loop
    insert into centre_invoices(org_id, kind, household_id, student_id, period_start, period_end, gst_registered, gst_rate_bp, gst_inclusive, net_cents, gst_cents, total_cents)
    values (p_org, 'lesson', u.hid, u.ustu, ms, me, u.gst_reg, u.gst_rate, u.gst_inc, u.net, u.gst, u.total) returning id into inv;
    insert into centre_invoice_lines(org_id, invoice_id, position, lesson_id, student_id, fee_kind, description, qty, unit_cents)
    select p_org, inv, row_number() over (order by r.student_name, r.ord, r.lesson_date, r.start_time, r.lesson_id), r.lesson_id, r.student_id,
           case when r.line_kind in ('registration', 'materials', 'sibling_discount') then r.line_kind end, r.description, r.qty, r.unit_cents
      from _td_run r where r.unit_key = u.unit_key and r.state = 'line';
    n_made := n_made + 1;
    if not review then iss := centre_invoice_issue_draft(inv, today); n_issued := n_issued + 1; end if;
    made := made || jsonb_build_object('id', inv, 'name', u.uname, 'total_cents', u.total);
  end loop;
  select count(*) into n_held from _td_units where status = 'held';
  select count(*) into n_draft from _td_units where status = 'draft';
  select count(*) into n_empty from _td_units where status = 'empty';
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), 'centre_invoice_run_create', 'centre_invoices', p_org::text || ':' || ms::text, null,
          jsonb_build_object('period_start', ms, 'created', n_made, 'issued_straight_away', n_issued, 'held_back', n_held, 'already_drafted', n_draft));
  return jsonb_build_object('period_start', ms, 'created', n_made, 'issued', n_issued, 'held_back', n_held, 'already_drafted', n_draft, 'nothing_to_bill', n_empty,
                            'review_before_sending', review, 'invoices', made);
end $$;

create or replace function public.centre_invoice_approve_all(p_org uuid, p_period date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := centre_invoicing_gate(p_org); ms date := centre_invoice_month(p_period, today); d record; r centre_invoices; n int := 0; tot bigint := 0; first_no text; last_no text;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_org::text || ':' || ms::text, 77));
  for d in select i.id from centre_invoices i left join households h on h.id = i.household_id and h.org_id = i.org_id left join students st on st.id = i.student_id and st.org_id = i.org_id
            where i.org_id = p_org and i.kind = 'lesson' and i.status = 'draft' and i.period_start = ms
            order by coalesce(h.name, st.name), st.name, i.id for update of i loop
    r := centre_invoice_issue_draft(d.id, today);
    n := n + 1; tot := tot + r.total_cents; first_no := coalesce(first_no, r.number_text); last_no := r.number_text;
  end loop;
  if n = 0 then raise exception 'NOTHING_TO_APPROVE: there are no drafts for that month' using errcode = 'P0001'; end if;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), 'centre_invoice_approve_all', 'centre_invoices', p_org::text || ':' || ms::text, null,
          jsonb_build_object('period_start', ms, 'issued', n, 'first', first_no, 'last', last_no, 'total_cents', tot));
  return jsonb_build_object('issued', n, 'first_number', first_no, 'last_number', last_no, 'total_cents', tot);
end $$;

create or replace function public.centre_invoice_list(p_org uuid, p_period date default null, p_status text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := centre_invoicing_gate(p_org); ms date := case when p_period is null then null else centre_invoice_month(p_period, today) end;
begin
  if p_status is not null and p_status not in ('draft', 'issued', 'void') then raise exception 'BAD_VALUE: unknown status' using errcode = 'P0001'; end if;
  return jsonb_build_object('today', today, 'rows', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', q.id, 'status', q.status, 'number', q.number_text, 'name', q.nm, 'household_id', q.household_id, 'student_id', q.student_id,
      'period_start', q.period_start, 'period_end', q.period_end, 'issue_date', q.issue_date, 'due_date', q.due_date,
      'net_cents', q.net_cents, 'gst_cents', q.gst_cents, 'total_cents', q.total_cents, 'lines', q.nl) order by q.ord, q.nm, q.id), '[]'::jsonb)
    from (select i.*, coalesce(case when i.student_id is not null and i.household_id is null then st.name end, h.name, st.name) as nm,
                 case i.status when 'draft' then 0 when 'issued' then 1 else 2 end as ord,
                 (select count(*) from centre_invoice_lines l where l.invoice_id = i.id)::int as nl
            from centre_invoices i left join households h on h.id = i.household_id and h.org_id = i.org_id left join students st on st.id = i.student_id and st.org_id = i.org_id
           where i.org_id = p_org and i.kind = 'lesson' and (ms is null or i.period_start = ms) and (p_status is null or i.status = p_status)
           order by case i.status when 'draft' then 0 when 'issued' then 1 else 2 end, coalesce(h.name, st.name), i.id limit 1000) q));
end $$;
