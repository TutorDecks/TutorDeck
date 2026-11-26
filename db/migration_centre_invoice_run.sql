-- =====================================================================================================
-- T4 step S2 — centre invoice run: preview, drafts, approve and issue                  undo: migration_centre_invoice_run_down.sql
-- =====================================================================================================
-- Run order everywhere: org_foundation → billing → attendance → tutor_access → org_delete → function_lockdown → org_separation →
--   staff_home → staff_students → staff_attendance → staff_charges → staff_trials → staff_timetable → centre_money → centre_invoice_run.
-- Needs migration_centre_money.sql (S1: the tables, the numbering, the GST function) and migration_staff_charges.sql (lesson_price_cents).
-- Run on the DEV project first. LIVE only when the owner says ship (no existing row is read or changed: two optional columns on the new
-- lines table, one index, new functions). Safe to run twice.
--
-- WHAT IT DOES (database only; the screen is Money > Invoice run, assets/js/centre-money.js)
--   centre_invoice_run_preview(org, period)       read-only: per household (or per student, as `invoicing.grouping` says) the invoice it would make,
--                                                 line by line, and the households HELD BACK with the reason ("charge pending: <student>").
--   centre_invoice_run_create_drafts(org, period) makes the draft documents. Running it twice adds nothing; a lesson is billed once; a lesson on a
--                                                 draft or an issued invoice never appears again. With `invoicing.review_before_sending` OFF the
--                                                 drafts are issued straight away; ON (the default) an admin approves them.
--   centre_invoice_approve(invoice) / centre_invoice_approve_all(org, period)   issue: number from the gap-free counter, issue date today
--                                                 (the centre's day), due date = issue date + `invoicing.due_days`, then frozen for ever (S1 guard).
--   centre_invoice_discard_draft(invoice, reason) throws a DRAFT away (it keeps its record, burns no number) so its lessons can be invoiced again.
--   centre_invoice_list / centre_invoice_get / centre_invoice_numbering   what the screen reads (explicit columns, no table access needed).
--
-- WHO MAY CALL (same rule as Charges): an active OWNER, or STAFF holding `issue_invoices`. A tutor, a parent, switched-off staff, a stranger, a
-- solo organisation and an unknown id all get the same NOT_FOUND; staff without issue_invoices get NOT_ALLOWED in plain words.
--
-- THE RULES (owner-approved T4 decisions, 2026-11-26)
--   BILLING MODELS BUILT NOW   postpaid_lessons (after the month, for lessons held) and fixed_in_advance with fixed_period = month.
--                              prepaid_packages, pay_per_lesson and a fixed TERM are `soon`: the preview says so in words and creates nothing.
--   POSTPAID (billing.model = postpaid_lessons), lessons dated in the month:
--       done lesson                                  → its price (amount, else rate × hours; the same rule as the rest of the app)
--       cancelled lesson with a charge (compensation)→ the charge; compensation 0 → nothing
--       absent / cancelled lesson with NO charge yet → "charge pending": HOLDS BACK THAT INVOICE ONLY (that household, or that student when the
--                                                      centre invoices per student). Every other household is invoiced as normal.
--       scheduled lesson whose day has passed        → not invoiced, counted as "not marked yet" (a warning, not a hold-back: see README)
--       trial lesson                                 → free unless `billing.trials.charged` (not set = free); a free trial never holds anything back
--   FIXED IN ADVANCE (month): every non-cancelled lesson of the month (scheduled or done) at its price; cancelled lessons add nothing (the
--       fee is fixed); nothing is "pending" because no separate charge exists. (Fee plans arrive later; until then the monthly fee IS the
--       month's lessons.)
--   SIBLING DISCOUNT (billing.sibling_discount): the 2nd, 3rd... child of a household BILLED IN THIS RUN (oldest registration first) gets the
--       discount, as one negative line under their lessons: percent of their lessons, or a fixed amount off each lesson (never below 0).
--   ONE-OFF FEES: registration and materials fees (billing.one_off_fees) are added ONCE per student, on the first invoice that bills a
--       non-trial lesson for them. A voided draft frees the fee again. (The deposit is T4 S4 and is not touched here.)
--   GST: once per invoice, half up, from the centre's own settings on the day the draft is made (registered or not, rate, prices inclusive or
--       exclusive) via centre_gst_totals(); the rules used are frozen on the document. Billing settings are read as of the first day of the month
--       billed (money rules follow the settings in force then; if none existed yet, today's).
--   NUMBERING: the document gets its number only when issued, from org_counters (S1); the opening number is settable once, by the owner,
--       before the first issue (centre_set_opening_number, S1).
--
-- PERFORMANCE: one set-based pass over the month's lessons (index lessons_org_date; billed-lesson lookup index centre_invoice_lines_lesson).
--   About 400 students ≈ 3,000 lessons previews in well under a second on a laptop (tests/perf: tests/sql/invoice_run_perf.sql).
-- =====================================================================================================

-- ---------------------------------------------------------------------------------------------------
-- 1. two small additions to the S1 lines table + the "one draft per household and month" rule
-- ---------------------------------------------------------------------------------------------------
alter table public.centre_invoice_lines add column if not exists student_id uuid;      -- whose lesson / fee / discount the line is (for the invoice's grouping by child)
alter table public.centre_invoice_lines add column if not exists fee_kind text;        -- registration | materials | sibling_discount (null for a lesson line)
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'centre_invoice_lines_fee_kind_check') then
    alter table public.centre_invoice_lines add constraint centre_invoice_lines_fee_kind_check
      check (fee_kind is null or fee_kind in ('registration', 'materials', 'sibling_discount'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'centre_invoice_lines_student_fk') then
    alter table public.centre_invoice_lines add constraint centre_invoice_lines_student_fk
      foreign key (student_id, org_id) references public.students(id, org_id);
  end if;
end $$;
create index if not exists centre_invoice_lines_fee on public.centre_invoice_lines(org_id, student_id, fee_kind) where fee_kind in ('registration', 'materials');

-- A household (or student) has ONE draft lesson invoice per month: the database-level backstop for "running twice adds nothing".
create unique index if not exists centre_invoices_one_draft on public.centre_invoices(
  org_id, coalesce(household_id, '00000000-0000-0000-0000-000000000000'::uuid), coalesce(student_id, '00000000-0000-0000-0000-000000000000'::uuid), period_start)
  where status = 'draft' and kind = 'lesson';

-- ---------------------------------------------------------------------------------------------------
-- 2. the gate every function here starts with (internal): returns the centre's own "today"
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_invoicing_gate(p_org uuid) returns date
language plpgsql stable security definer set search_path = public as $$
declare tz text;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select o.timezone into tz from organisations o where o.id = p_org and o.kind = 'centre';
  if tz is null or not exists (select 1 from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active'
                               and m.role in ('owner', 'staff')) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  if not org_can(p_org, 'issue_invoices') then
    raise exception 'NOT_ALLOWED: your account can''t prepare or issue invoices at this centre' using errcode = '42501';
  end if;
  return (now() at time zone tz)::date;
end $$;

-- the month an input date belongs to (first day), refusing the absurd
create or replace function public.centre_invoice_month(p_period date, p_today date) returns date
language plpgsql immutable set search_path = public as $$
declare ms date;
begin
  if p_period is null then raise exception 'BAD_PERIOD: choose a month' using errcode = 'P0001'; end if;
  ms := date_trunc('month', p_period)::date;
  if ms < (date_trunc('month', p_today) - interval '3 years')::date or ms > (date_trunc('month', p_today) + interval '2 months')::date then
    raise exception 'BAD_PERIOD: choose a month from the last 3 years up to two months ahead' using errcode = 'P0001'; end if;
  return ms;
end $$;

-- which billing models are built (the rest are `soon`): returns null when built, else the plain-words reason
create or replace function public.centre_invoice_model_note(p_settings jsonb) returns text
language sql immutable set search_path = public as $$
  select case coalesce(p_settings#>>'{billing,model}', 'postpaid_lessons')
    when 'postpaid_lessons' then null
    when 'fixed_in_advance' then case coalesce(p_settings#>>'{billing,fixed_period}', 'month')
                                   when 'month' then null
                                   else 'Fixed fees per term are coming soon. For now the invoice run works with a fixed fee per month or with postpaid lessons.' end
    when 'prepaid_packages' then 'Prepaid packages are coming soon (they need lesson credits). The invoice run works with postpaid lessons and a fixed monthly fee.'
    when 'pay_per_lesson' then 'Pay per lesson is coming soon. The invoice run works with postpaid lessons and a fixed monthly fee.'
    else 'This billing model isn''t built yet.' end
$$;

-- ---------------------------------------------------------------------------------------------------
-- 3. the calculation (internal; every consumer goes through the gate first)
--    rows: one per invoice line, plus signal rows (state pending / unmarked / no_price / free_trial / draft_exists)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_invoice_run_rows(p_org uuid, p_month date, p_today date)
returns table(unit_key text, household_id uuid, unit_student uuid, unit_name text, student_id uuid, student_name text,
              state text, line_kind text, ord int, lesson_id uuid, lesson_date date, start_time time,
              description text, qty int, unit_cents bigint, ref_id uuid)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare ms date := date_trunc('month', p_month)::date; me date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  s jsonb; v_post boolean; v_stu boolean; v_trials boolean; v_sib text; v_sib_bp bigint; v_sib_fix bigint; v_reg bigint; v_mat bigint; v_pct text;
begin
  s := coalesce(org_settings_on(p_org, ms), org_settings_on(p_org, p_today));
  if s is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  v_post   := coalesce(s#>>'{billing,model}', 'postpaid_lessons') = 'postpaid_lessons';
  v_stu    := coalesce(s#>>'{invoicing,grouping}', 'family') = 'student';
  v_trials := coalesce((s#>>'{billing,trials,charged}')::boolean, false);
  v_sib    := coalesce(s#>>'{billing,sibling_discount,type}', 'none');
  v_sib_bp := coalesce((s#>>'{billing,sibling_discount,percent_bp}')::bigint, 0);
  v_sib_fix:= coalesce((s#>>'{billing,sibling_discount,fixed_cents}')::bigint, 0);
  v_reg    := coalesce((s#>>'{billing,one_off_fees,registration_cents}')::bigint, 0);
  v_mat    := coalesce((s#>>'{billing,one_off_fees,materials_cents}')::bigint, 0);
  v_pct    := regexp_replace(to_char(v_sib_bp / 100.0, 'FM990.00'), '\.?0+$', '');

  return query
  with base as (                                   -- the month's lessons that are not already on a draft or issued document
    select l.id as lid, l.student_id as sid, l.lesson_date as ldate, l.start_time as stime, l.subject as subj,
           l.status as lstatus, l.attendance as att, l.trial as is_trial, l.compensation_cents as comp,
           lesson_price_cents(l.amount, l.rate, l.start_time, l.end_time) as price
      from lessons l
     where l.org_id = p_org and l.lesson_date between ms and me
       and not exists (select 1 from centre_invoice_lines cl join centre_invoices ci on ci.id = cl.invoice_id and ci.org_id = cl.org_id
                        where cl.lesson_id = l.id and cl.org_id = p_org and ci.status <> 'void')
  ), cls as (
    select b.*,
      case
        when b.is_trial and not v_trials then 'free_trial'
        when v_post and b.att in ('absent', 'cancelled_early', 'late_cancelled') and b.comp is null then 'pending'
        when b.lstatus = 'done' or (not v_post and b.lstatus = 'scheduled') then case when b.price > 0 then 'line' else 'no_price' end
        when v_post and b.lstatus = 'cancelled' and coalesce(b.comp, 0) > 0 then 'line'
        when v_post and b.lstatus = 'scheduled' and b.ldate < p_today then 'unmarked'
        else 'skip' end as st,
      case when b.lstatus = 'cancelled' then b.comp else b.price end as cents
      from base b
  ), keyed as (
    select c.*, st8.name as sname, st8.household_id as hid, st8.created_at as screated,
           case when v_stu then c.sid::text else coalesce(st8.household_id::text, c.sid::text) end as ukey,
           case when v_stu or st8.household_id is null then c.sid end as ustu,
           case when v_stu then st8.name else coalesce(h.name, st8.name) end as uname
      from cls c
      join students st8 on st8.id = c.sid and st8.org_id = p_org
      left join households h on h.id = st8.household_id and h.org_id = p_org
     where c.st <> 'skip'
  ), billed as (select * from keyed where st = 'line'),
  stu as (                                          -- per child billed in this run
    select b.sid, b.hid, min(b.screated) as screated, sum(b.cents)::bigint as total, sum(least(v_sib_fix, b.cents))::bigint as fixed_off,
           bool_or(not b.is_trial) as any_nontrial,
           (array_agg(b.ukey))[1] as ukey, (array_agg(b.ustu))[1] as ustu, (array_agg(b.uname))[1] as uname, (array_agg(b.sname))[1] as sname
      from billed b group by b.sid, b.hid
  ), ranked as (
    select st.*, case when st.hid is null then 1 else row_number() over (partition by st.hid order by st.screated, st.sid) end as rn from stu st
  ), disc as (
    select r.*, case v_sib when 'percent' then least(r.total, centre_div_round(r.total * v_sib_bp, 10000))
                           when 'fixed'   then least(r.total, r.fixed_off) else 0 end as off
      from ranked r where r.rn >= 2
  )
  select b.ukey, b.hid, b.ustu, b.uname, b.sid, b.sname, 'line'::text, 'lesson'::text, 0, b.lid, b.ldate, b.stime,
         left(coalesce(nullif(trim(b.subj), ''), 'Lesson'), 60) || case when b.lstatus = 'cancelled' then ' (cancelled, charged)' else '' end
           || ' · ' || to_char(b.ldate, 'Dy DD Mon') || ', ' || to_char(b.stime, 'FMHH12:MIam'),
         1, b.cents, null::uuid
    from billed b
  union all                                         -- signals the screen explains (no money on them)
  select k.ukey, k.hid, k.ustu, k.uname, k.sid, k.sname, k.st, 'lesson', 0, k.lid, k.ldate, k.stime, null::text, 1, 0::bigint, null::uuid
    from keyed k where k.st in ('pending', 'unmarked', 'no_price', 'free_trial')
  union all
  select d.ukey, d.hid, d.ustu, d.uname, d.sid, d.sname, 'line', 'sibling_discount', 1, null::uuid, null::date, null::time,
         case v_sib when 'percent' then 'Sibling discount (' || v_pct || '%)' else 'Sibling discount (S$' || to_char(v_sib_fix / 100.0, 'FM999990.00') || ' off each lesson)' end,
         1, -d.off, null::uuid
    from disc d where d.off > 0
  union all
  select r.ukey, r.hid, r.ustu, r.uname, r.sid, r.sname, 'line', k.kind, case k.kind when 'registration' then 2 else 3 end, null::uuid, null::date, null::time,
         case k.kind when 'registration' then 'Registration fee' else 'Materials fee' end, 1, k.amt, null::uuid
    from stu r cross join lateral (values ('registration', v_reg), ('materials', v_mat)) k(kind, amt)
   where r.any_nontrial and k.amt > 0
     and not exists (select 1 from centre_invoice_lines fl join centre_invoices fi on fi.id = fl.invoice_id and fi.org_id = fl.org_id
                      where fl.org_id = p_org and fl.student_id = r.sid and fl.fee_kind = k.kind and fi.status <> 'void')
  union all                                         -- a draft already exists for this household / student and month
  select coalesce(ci.student_id::text, ci.household_id::text), ci.household_id, ci.student_id,
         case when v_stu then sd.name else coalesce(hd.name, sd.name) end, ci.student_id, sd.name, 'draft_exists', 'invoice', 0,
         null::uuid, null::date, null::time, null::text, 1, ci.total_cents, ci.id
    from centre_invoices ci
    left join households hd on hd.id = ci.household_id and hd.org_id = ci.org_id
    left join students sd on sd.id = ci.student_id and sd.org_id = ci.org_id
   where ci.org_id = p_org and ci.kind = 'lesson' and ci.status = 'draft' and ci.period_start = ms;
end $$;

-- prepares the month for preview / create: two temporary tables (gone at the end of the transaction)
--   _td_run   the rows above;   _td_units  one row per invoice-to-be with its status and totals
create or replace function public.centre_invoice_run_prepare(p_org uuid, p_month date, p_today date) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare p jsonb := org_settings_on(p_org, p_today); reg boolean; rate int; inc boolean;
begin
  reg  := coalesce((p#>>'{profile,gst_registered}')::boolean, false);
  rate := case when reg then coalesce((p#>>'{profile,gst_rate_bp}')::int, 0) else 0 end;
  inc  := coalesce((p#>>'{profile,gst_inclusive}')::boolean, false);
  drop table if exists pg_temp._td_run;
  drop table if exists pg_temp._td_units;
  create temp table _td_run on commit drop as select * from centre_invoice_run_rows(p_org, p_month, p_today);
  create temp table _td_units on commit drop as
    select u.*, g.net_cents as net, g.gst_cents as gst, g.total_cents as total, reg as gst_reg, rate as gst_rate, inc as gst_inc
      from (select r.unit_key, (array_agg(r.household_id))[1] as hid, (array_agg(r.unit_student))[1] as ustu, (array_agg(r.unit_name))[1] as uname,
                   case when bool_or(r.state = 'pending') then 'held'
                        when bool_or(r.state = 'draft_exists') then 'draft'
                        when coalesce(sum(r.qty * r.unit_cents) filter (where r.state = 'line'), 0) <= 0 then 'empty'
                        else 'ready' end as status,
                   (array_agg(r.ref_id) filter (where r.state = 'draft_exists'))[1] as draft_id,
                   coalesce(sum(r.qty * r.unit_cents) filter (where r.state = 'line'), 0)::bigint as subtotal,
                   count(*) filter (where r.state = 'line' and r.line_kind = 'lesson')::int as n_lessons,
                   count(*) filter (where r.state = 'unmarked')::int as n_unmarked,
                   count(*) filter (where r.state = 'no_price')::int as n_no_price,
                   count(*) filter (where r.state = 'free_trial')::int as n_free
              from _td_run r group by r.unit_key) u
     cross join lateral centre_gst_totals(greatest(u.subtotal, 0), rate, inc, reg) g;
  create index on _td_run(unit_key);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 4. PREVIEW (read-only for the books; builds temporary tables only)
-- ---------------------------------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------------------------------
-- 5. issue one draft (internal): the S1 guard takes the number and freezes the row
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_invoice_issue_draft(p_invoice uuid, p_today date) returns centre_invoices
language plpgsql security definer set search_path = public as $$
declare d int; r centre_invoices; org uuid;
begin
  select org_id into org from centre_invoices where id = p_invoice;
  d := coalesce((org_settings_on(org, p_today) #>> '{invoicing,due_days}')::int, 7);
  update centre_invoices set status = 'issued', issue_date = p_today, due_date = p_today + d where id = p_invoice and status = 'draft' returning * into r;
  if r.id is null then raise exception 'NOT_DRAFT: only a draft can be approved' using errcode = 'P0001'; end if;
  return r;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 6. CREATE DRAFTS (idempotent)
-- ---------------------------------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------------------------------
-- 7. APPROVE (issue) one or all drafts of a month
-- ---------------------------------------------------------------------------------------------------
create or replace function public.centre_invoice_approve(p_invoice uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare org uuid; today date; r centre_invoices;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select org_id into org from centre_invoices where id = p_invoice;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := centre_invoicing_gate(org);
  perform 1 from centre_invoices where id = p_invoice and org_id = org for update;
  r := centre_invoice_issue_draft(p_invoice, today);
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (org, auth.uid(), 'centre_invoice_approve', 'centre_invoices', p_invoice::text, jsonb_build_object('status', 'draft'),
          jsonb_build_object('status', 'issued', 'number', r.number_text, 'total_cents', r.total_cents, 'issue_date', r.issue_date, 'due_date', r.due_date));
  return jsonb_build_object('id', r.id, 'number', r.number_text, 'status', r.status, 'issue_date', r.issue_date, 'due_date', r.due_date, 'total_cents', r.total_cents);
end $$;

-- all the drafts of one month, in household-name order (so numbers read alphabetically); all or nothing
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

-- throw a draft away (kept as a voided record with its reason; it never had a number, so no gap); its lessons can be invoiced again
create or replace function public.centre_invoice_discard_draft(p_invoice uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare org uuid; why text := nullif(trim(coalesce(p_reason, '')), ''); st text;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select org_id, status into org, st from centre_invoices where id = p_invoice;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  perform centre_invoicing_gate(org);
  if st <> 'draft' then raise exception 'NOT_DRAFT: only a draft can be discarded (an issued invoice is corrected with a credit note)' using errcode = 'P0001'; end if;
  if why is null then raise exception 'REASON_REQUIRED: say why you are discarding this draft' using errcode = 'P0001'; end if;
  if length(why) > 300 then raise exception 'TOO_LONG: keep the reason under 300 characters' using errcode = 'P0001'; end if;
  update centre_invoices set status = 'void', void_reason = why where id = p_invoice and status = 'draft';
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (org, auth.uid(), 'centre_invoice_discard_draft', 'centre_invoices', p_invoice::text, jsonb_build_object('status', 'draft'), jsonb_build_object('status', 'void'));
  return jsonb_build_object('id', p_invoice, 'status', 'void');
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 8. what the screen reads
-- ---------------------------------------------------------------------------------------------------
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

create or replace function public.centre_invoice_get(p_invoice uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare org uuid; r record;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select org_id into org from centre_invoices where id = p_invoice;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  perform centre_invoicing_gate(org);
  select i.*, coalesce(h.name, st.name) as nm into r from centre_invoices i left join households h on h.id = i.household_id and h.org_id = i.org_id
    left join students st on st.id = i.student_id and st.org_id = i.org_id where i.id = p_invoice;
  return jsonb_build_object('id', r.id, 'status', r.status, 'number', r.number_text, 'name', r.nm, 'household_id', r.household_id, 'student_id', r.student_id,
    'period_start', r.period_start, 'period_end', r.period_end, 'issue_date', r.issue_date, 'due_date', r.due_date,
    'gst_registered', r.gst_registered, 'gst_rate_bp', r.gst_rate_bp, 'gst_inclusive', r.gst_inclusive,
    'net_cents', r.net_cents, 'gst_cents', r.gst_cents, 'total_cents', r.total_cents, 'void_reason', r.void_reason,
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('position', l.position, 'student_name', s2.name, 'description', l.description, 'qty', l.qty,
                'unit_cents', l.unit_cents, 'line_cents', l.line_cents, 'kind', coalesce(l.fee_kind, 'lesson')) order by l.position), '[]'::jsonb)
                from centre_invoice_lines l left join students s2 on s2.id = l.student_id and s2.org_id = l.org_id where l.invoice_id = r.id));
end $$;

-- the next number the centre will hand out, and whether the owner may still set the first one
create or replace function public.centre_invoice_numbering(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := centre_invoicing_gate(p_org); c record; prefix text;
begin
  prefix := coalesce(nullif(trim(org_settings_on(p_org, today) #>> '{profile,invoice_prefix}'), ''), 'INV');
  select * into c from org_counters where org_id = p_org and series = 'invoice';
  return jsonb_build_object('prefix', prefix, 'next_number', coalesce(c.next_number, 1), 'next_text', prefix || '-' || coalesce(c.next_number, 1),
                            'locked', coalesce(c.locked, false) or exists (select 1 from centre_invoices i where i.org_id = p_org and i.series = 'invoice' and i.number_seq is not null),
                            'can_set', org_can(p_org, 'owner'));
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 9. access: signed-in users call the public ones (each starts with the gate); the helpers are server-only
-- ---------------------------------------------------------------------------------------------------
revoke all on function public.centre_invoicing_gate(uuid) from public, anon, authenticated;
revoke all on function public.centre_invoice_run_rows(uuid, date, date) from public, anon, authenticated;
revoke all on function public.centre_invoice_run_prepare(uuid, date, date) from public, anon, authenticated;
revoke all on function public.centre_invoice_issue_draft(uuid, date) from public, anon, authenticated;
revoke all on function public.centre_invoice_month(date, date) from public, anon;
revoke all on function public.centre_invoice_model_note(jsonb) from public, anon;
revoke all on function public.centre_invoice_run_preview(uuid, date) from public, anon;
revoke all on function public.centre_invoice_run_create_drafts(uuid, date) from public, anon;
revoke all on function public.centre_invoice_approve(uuid) from public, anon;
revoke all on function public.centre_invoice_approve_all(uuid, date) from public, anon;
revoke all on function public.centre_invoice_discard_draft(uuid, text) from public, anon;
revoke all on function public.centre_invoice_list(uuid, date, text) from public, anon;
revoke all on function public.centre_invoice_get(uuid) from public, anon;
revoke all on function public.centre_invoice_numbering(uuid) from public, anon;
grant execute on function public.centre_invoice_month(date, date), public.centre_invoice_model_note(jsonb) to authenticated, service_role;
grant execute on function public.centre_invoice_run_preview(uuid, date), public.centre_invoice_run_create_drafts(uuid, date),
  public.centre_invoice_approve(uuid), public.centre_invoice_approve_all(uuid, date), public.centre_invoice_discard_draft(uuid, text),
  public.centre_invoice_list(uuid, date, text), public.centre_invoice_get(uuid), public.centre_invoice_numbering(uuid) to authenticated, service_role;
