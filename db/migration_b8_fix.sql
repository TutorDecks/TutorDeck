-- B8-FIX (bundle 7 test findings F4, F5, F6; see docs/test-recordings/bundle-7-t51/REPORT.md). Needs migration_org_export.sql and everything before it. Safe to run twice.
-- Undo: migration_b8_fix_down.sql (hands back the previous version of each function; settings rows are append-only and are not touched).
--
-- F4 A discarded deposit draft got stuck. When only the DEPOSIT draft was discarded (the lesson invoice stayed), nothing was ready to invoice, so the run
--    said "0 invoices ready" and the Deposits tab said "Invoice not issued yet". centre_deposit_run_candidates now raises a discarded deposit again (same frozen
--    amount) even when the student's lessons are not waiting in this run (not when it was waived, when a live deposit invoice exists, or without a lesson this month).
--    centre_deposit_status says state 'discarded' for it (was 'draft').
-- F5 A deposit that was refunded (or applied / kept / moved to another student) showed "to collect". centre_deposit_status now says 'refunded' or 'settled'
--    and its short amount is 0.
-- F6 Trial lessons earn no make-up credit unless the centre chooses it: new setting billing.credits.earn_trials (default false), validated in
--    org_validate_settings and read by credit_cfg / credit_consider.
-- The copies below are the NEWEST of each chain: org_validate_settings(jsonb) = past_lessons, credit_cfg / credit_consider = makeup_credits,
-- centre_deposit_run_candidates = b5_fix, centre_deposit_status = centre_deposits.

create or replace function public.org_validate_settings(s jsonb) returns void language plpgsql immutable set search_path = public as $$
declare k text; v jsonb; r record; bs text; tp text;
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
  -- T7.3 (invoice, receipt and reminder emails to families). Every key is optional; a key that is present must be right. assets/js/org-settings.js has the labels and
  -- defaults and assets/js/invoice-email-core.js the placeholder list (tests/org-settings.test.js and tests/invoice-email-core.test.js compare them with this).
  if s#>'{email}' is not null and jsonb_typeof(s#>'{email}') not in ('object','null') then raise exception 'Email settings are malformed'; end if;
  if s#>>'{email,mode}' is not null and s#>>'{email,mode}' not in ('off','staff_send','auto_on_issue') then raise exception 'Unknown email sending setting'; end if;
  foreach k in array array['{email,receipts}','{email,late_fee_notice}','{email,reminders,enabled}'] loop
    v := s #> k::text[];
    if v is not null and jsonb_typeof(v) not in ('boolean','null') then raise exception 'Setting % must be yes or no', k; end if;
  end loop;
  for r in select * from (values
    ('{email,reminders,first_after_days}', 1, 90, 'Send the first reminder 1-90 days after the due date'),
    ('{email,reminders,repeat_days}', 0, 90, 'Repeat reminders every 0-90 days (0 = only one reminder)'),
    ('{email,reminders,max_count}', 1, 10, 'Send 1-10 reminders at most'),
    ('{email,daily_cap}', 1, 300, 'Emails per day must be 1-300'),
    ('{email,per_hour}', 1, 300, 'Emails per hour must be 1-300')
  ) as c(p, lo, hi, msg) loop
    v := s #> r.p::text[];
    if v is not null and jsonb_typeof(v) <> 'null' and not (case when jsonb_typeof(v) = 'number' and v::text ~ '^[0-9]{1,4}$'
         then (v#>>'{}')::bigint between r.lo and r.hi else false end) then
      raise exception '%', r.msg; end if;
  end loop;
  -- the wording: plain text, a limited set of fields in {braces}
  if s#>'{email,templates}' is not null and jsonb_typeof(s#>'{email,templates}') not in ('object','null') then raise exception 'Email wording is malformed'; end if;
  foreach k in array array['invoice','receipt','reminder','late_fee'] loop
    foreach tp in array array['subject','body'] loop
      v := s #> array['email','templates',k,tp];
      if v is not null and jsonb_typeof(v) <> 'null' then
        if jsonb_typeof(v) <> 'string' then raise exception 'Email wording must be text'; end if;
        if length(v#>>'{}') > (case tp when 'subject' then 120 else 1000 end) then raise exception 'Email wording is too long (subject 120, message 1000 characters)'; end if;
        if regexp_replace(v#>>'{}', '\{(name|centre|number|amount|due_date|link|contact|paid_on|days_overdue)\}', '', 'g') ~ '[{}]' then
          raise exception 'Email wording can only use {name} {centre} {number} {amount} {due_date} {link} {contact} {paid_on} {days_overdue}'; end if;
      end if;
    end loop;
  end loop;
  if s#>>'{email,mode}' is not null and s#>>'{email,mode}' <> 'off' and coalesce((s#>>'{invoicing,delivery,share_link}')::boolean, true) = false then
    raise exception 'Emailing invoices needs the shareable invoice link switched on'; end if;
  if nullif(trim(coalesce(s#>>'{profile,reply_to_email}', '')), '') is not null and trim(s#>>'{profile,reply_to_email}') !~ '^[^@\s<>,;]+@[^@\s<>,;]+\.[^@\s<>,;]+$' then
    raise exception 'The reply-to email address doesn''t look right'; end if;
  -- T18 step 4 (make-up credits). Every key is optional; a key that is present must be right. assets/js/org-settings.js has the labels and defaults.
  if s#>>'{billing,credits,rule}' is not null and s#>>'{billing,credits,rule}' not in ('none','one_per_missed') then raise exception 'Unknown make-up credit rule'; end if;
  if s#>>'{billing,credits,earn_absences}' is not null and s#>>'{billing,credits,earn_absences}' not in ('none','notice_only','notice_and_late','all_missed') then raise exception 'Unknown rule for credits from absences'; end if;
  if s#>>'{billing,credits,earn_tutor_cancel}' is not null and s#>>'{billing,credits,earn_tutor_cancel}' not in ('staff_decide','automatic') then raise exception 'Unknown rule for credits from tutor cancellations'; end if;
  if s#>>'{billing,credits,grant_by}' is not null and s#>>'{billing,credits,grant_by}' not in ('manage_timetable','owner') then raise exception 'Unknown rule for who grants credits'; end if;
  if s#>>'{billing,credits,book_by}' is not null and s#>>'{billing,credits,book_by}' not in ('manage_timetable','owner') then raise exception 'Unknown rule for who books make-ups'; end if;
  if s#>>'{billing,credits,makeup_price}' is not null and s#>>'{billing,credits,makeup_price}' not in ('free','if_missed_not_charged') then raise exception 'Unknown make-up price rule'; end if;
  v := s #> '{billing,credits,earn_trials}';
  if v is not null and jsonb_typeof(v) not in ('boolean','null') then raise exception 'Setting {billing,credits,earn_trials} must be yes or no'; end if;
  v := s #> '{billing,credits,earn_holiday}';
  if v is not null and jsonb_typeof(v) not in ('boolean','null') then raise exception 'Setting {billing,credits,earn_holiday} must be yes or no'; end if;
  v := s #> '{billing,credit_expiry_days}';
  if v is not null and jsonb_typeof(v) <> 'null' and not (case when jsonb_typeof(v) = 'number' and v::text ~ '^[0-9]{1,4}$' then (v#>>'{}')::bigint between 0 and 3650 else false end) then
    raise exception 'Credits must expire after 0-3650 days (0 = never)'; end if;
  -- T6 step 6: how many days a tutor's request waits for an answer (optional, default 14). assets/js/org-settings.js has the label.
  v := s #> '{lessons,request_expiry_days}';
  if v is not null and jsonb_typeof(v) <> 'null' and not (case when jsonb_typeof(v) = 'number' and v::text ~ '^[0-9]{1,3}$'
       then (v#>>'{}')::bigint between 1 and 90 else false end) then
    raise exception 'A request must wait 1-90 days for an answer'; end if;
  -- T3.10 (staff add PAST lessons). Optional; a key that is present must be right. assets/js/org-settings.js has the label and default (31).
  v := s #> '{lessons,backfill_allowed_days}';
  if v is not null and jsonb_typeof(v) <> 'null' and not (case when jsonb_typeof(v) = 'number' and v::text ~ '^[0-9]{1,3}$'
       then (v#>>'{}')::bigint between 0 and 366 else false end) then
    raise exception 'Days staff may add past lessons must be 0-366 (0 = off)'; end if;
end $$;

create or replace function public.credit_cfg(p_org uuid, p_today date) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'rule',              coalesce(s #>> '{billing,credits,rule}', 'none'),
    'earn_absences',     coalesce(s #>> '{billing,credits,earn_absences}', 'notice_only'),
    'earn_tutor_cancel', coalesce(s #>> '{billing,credits,earn_tutor_cancel}', 'staff_decide'),
    'earn_holiday',      coalesce((s #>> '{billing,credits,earn_holiday}')::boolean, false),
    'earn_trials',       coalesce((s #>> '{billing,credits,earn_trials}')::boolean, false),
    'grant_by',          coalesce(s #>> '{billing,credits,grant_by}', 'manage_timetable'),
    'book_by',           coalesce(s #>> '{billing,credits,book_by}', 'manage_timetable'),
    'makeup_price',      coalesce(s #>> '{billing,credits,makeup_price}', 'free'),
    'expiry_days',       coalesce(nullif(s #>> '{billing,credit_expiry_days}', '')::int, 0))
    from (select org_settings_on(p_org, p_today) as s) x $$;

create or replace function public.credit_consider(l lessons) returns void
language plpgsql security definer set search_path = public as $$
declare tz text; today date; cfg jsonb; src text; why text; days int; cid uuid; c makeup_credits; absences text[];
begin
  select o.timezone into tz from organisations o where o.id = l.org_id and o.kind = 'centre';
  if tz is null or l.makeup_credit_id is not null then return; end if;
  today := (now() at time zone tz)::date;
  cfg := credit_cfg(l.org_id, today);
  -- B8-FIX F6: a trial lesson earns no credit unless the centre chose that (billing.credits.earn_trials, default off)
  if coalesce(l.trial, false) and not (cfg ->> 'earn_trials')::boolean then return; end if;
  select * into c from makeup_credits where source_lesson_id = l.id;

  absences := case cfg ->> 'earn_absences' when 'notice_only' then array['cancelled_early']
                                           when 'notice_and_late' then array['cancelled_early', 'late_cancelled']
                                           when 'all_missed' then array['cancelled_early', 'late_cancelled', 'absent']
                                           else '{}'::text[] end;
  if cfg ->> 'rule' = 'one_per_missed' then
    if l.attendance = any(absences) then src := 'absence'; why := 'Missed lesson: ' || replace(l.attendance, '_', ' ');
    elsif l.status = 'cancelled' and l.attendance is null and l.changed_by_tutor_what = 'cancelled' and cfg ->> 'earn_tutor_cancel' = 'automatic' then
      src := 'tutor_cancel'; why := 'Cancelled by the tutor';
    elsif l.status = 'cancelled' and l.attendance is null and (cfg ->> 'earn_holiday')::boolean and coalesce(l.charge_note, '') like 'Holiday%'
          and exists (select 1 from holidays h where h.org_id = l.org_id and h.branch_id is null and l.lesson_date between h.starts_on and h.ends_on) then
      src := 'holiday'; why := 'Cancelled for a holiday';
    end if;
  end if;

  if src is not null and c.id is null then
    days := (cfg ->> 'expiry_days')::int;
    insert into makeup_credits(org_id, student_id, source, source_lesson_id, reason, earned_on, expires_on, created_by)
    values (l.org_id, l.student_id, src, l.id, why, today, case when days > 0 then today + days end, auth.uid())
    on conflict (source_lesson_id) where source_lesson_id is not null do nothing
    returning id into cid;
    if cid is not null then perform credit_event(cid, 'earned', l.id, why); end if;
  elsif src is null and c.id is not null and c.status = 'open' and c.source = 'absence' and cfg ->> 'rule' = 'one_per_missed'
        and (l.attendance is null or l.attendance = 'attended') then
    -- the mark was corrected to "attended" (or cleared): the lesson was not missed after all, so its UNUSED credit goes (a booked or used one stays)
    perform credit_move(c.id, 'open', 'revoked', 'revoked', null, 'The lesson''s mark was corrected, so it no longer earns a credit');
  end if;
end $$;

create or replace function public.centre_deposit_run_candidates(p_org uuid, p_ms date, p_today date)
returns table(d_student_id uuid, d_student_name text, d_household_id uuid, d_unit_key text, d_deposit_id uuid, d_mode text, d_percent_bp int,
              d_first_month_cents bigint, d_amount_cents bigint, d_taxable boolean, d_frozen boolean)
language plpgsql security definer set search_path = public, pg_temp as $$
declare s jsonb := coalesce(org_settings_on(p_org, p_today), org_settings_on(p_org, p_ms)); me date := (p_ms + interval '1 month - 1 day')::date;
  v_mode text; v_due text; v_bp int; v_fix bigint; v_tax boolean;
begin
  if s is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  v_mode := coalesce(s#>>'{billing,deposit,mode}', 'none');
  v_due  := coalesce(s#>>'{billing,deposit,due}', 'with_first_invoice');
  v_bp   := coalesce((s#>>'{billing,deposit,percent_bp}')::int, 0);
  v_fix  := coalesce((s#>>'{billing,one_off_fees,deposit_cents}')::bigint, 0);
  v_tax  := coalesce((s#>>'{billing,deposit,taxable}')::boolean, false);
  return query
  with fm as (                                       -- each student's non-trial lesson fee in an invoice that is READY (before discounts, fees and GST)
    select r.unit_key as ukey, r.student_id as sid, max(r.student_name) as sname, sum(r.qty * r.unit_cents)::bigint as cents
      from _td_run r
      join _td_units u on u.unit_key = r.unit_key and u.status = 'ready'
      join lessons l on l.id = r.lesson_id and l.org_id = p_org
     where r.state = 'line' and r.line_kind = 'lesson' and not coalesce(l.trial, false)
     group by r.unit_key, r.student_id
  )
  select st.id, st.name, st.household_id, fm.ukey, null::uuid,
         case v_mode when 'fixed' then 'fixed' else 'percent_first_month' end,
         case when v_mode = 'percent_first_month' then v_bp end,
         fm.cents,
         case v_mode when 'fixed' then v_fix when 'percent_first_month' then centre_div_round(fm.cents * v_bp, 10000) else 0 end,
         v_tax, false
    from fm join students st on st.id = fm.sid and st.org_id = p_org
   where v_mode in ('fixed', 'percent_first_month') and v_due = 'with_first_invoice'
     and not exists (select 1 from centre_deposits d where d.org_id = p_org and d.student_id = st.id)
     and not exists (select 1 from centre_invoice_lines cl join centre_invoices ci on ci.id = cl.invoice_id and ci.org_id = cl.org_id
                      where cl.org_id = p_org and cl.student_id = st.id and ci.kind in ('lesson', 'opening') and ci.status <> 'void' and ci.period_start <= p_ms)
     and case v_mode when 'fixed' then v_fix when 'percent_first_month' then centre_div_round(fm.cents * v_bp, 10000) else 0 end > 0
  union all
  select st.id, st.name, st.household_id, (select min(r.unit_key) from _td_run r where r.student_id = st.id), d.id, d.mode, d.percent_bp, d.first_month_cents,
         d.required_cents, d.taxable, true
    from centre_deposits d
    join students st on st.id = d.student_id and st.org_id = p_org
   where d.org_id = p_org and d.source = 'invoice_run'
     and (d.invoice_id is null or exists (select 1 from centre_invoices i where i.id = d.invoice_id and i.org_id = p_org and i.status = 'void'))
     -- B8-FIX F4: a discarded deposit draft is raised again whether or not the student's lessons are still waiting in this run
     -- (the lesson invoice may already be a draft or issued). Not when it was waived, when a live deposit invoice exists, or when the student has no lesson this month.
     and not exists (select 1 from centre_deposit_ledger w where w.org_id = p_org and w.student_id = st.id and w.kind = 'waived')
     and not exists (select 1 from centre_invoices x where x.org_id = p_org and x.student_id = st.id and x.kind = 'deposit' and x.status in ('draft', 'issued'))
     and exists (select 1 from lessons l where l.org_id = p_org and l.student_id = st.id and not coalesce(l.trial, false) and l.lesson_date between p_ms and me);
end $$;

create or replace function public.centre_deposit_status(p_org uuid, p_student uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := centre_deposit_gate(p_org, 'view'); res jsonb;
begin
  with led as (
    select l.student_id, coalesce(sum(l.cents) filter (where l.kind <> 'waived'), 0)::bigint as held,
           coalesce(sum(l.cents) filter (where l.kind = 'waived'), 0)::bigint as waived,
           coalesce(sum(l.cents) filter (where l.kind <> 'waived' and l.taxable), 0)::bigint as taxable_held,
           coalesce(-sum(l.cents) filter (where l.kind = 'refunded'), 0)::bigint as refunded,
           coalesce(-sum(l.cents) filter (where l.kind in ('applied', 'forfeited', 'transferred_out')), 0)::bigint as used
      from centre_deposit_ledger l where l.org_id = p_org group by l.student_id
  ), q as (
    select d.id as deposit_id, d.student_id, st.name, h.name as household_name, d.household_id, d.source, d.mode, d.percent_bp, d.first_month_cents,
           d.required_cents, coalesce(i.total_cents, d.required_cents) as due, d.taxable, d.period_start, i.id as invoice_id, i.number_text, i.status as istatus, i.issue_date, i.due_date,
           coalesce((select sum(c.total_cents) from centre_invoices c where c.credits_invoice_id = i.id and c.status = 'issued'), 0)::bigint as credited,
           coalesce(led.held, 0) as held, coalesce(led.waived, 0) as waived, coalesce(led.taxable_held, 0) as taxable_held,
           coalesce(led.refunded, 0) as refunded, coalesce(led.used, 0) as used
      from centre_deposits d
      join students st on st.id = d.student_id and st.org_id = d.org_id
      left join households h on h.id = d.household_id and h.org_id = d.org_id
      left join centre_invoices i on i.id = d.invoice_id and i.org_id = d.org_id
      left join led on led.student_id = d.student_id
     where d.org_id = p_org and (p_student is null or d.student_id = p_student)
  ), r as (
    select q.*, case when q.waived > 0 then 'waived' when q.istatus = 'draft' then 'draft' when q.held >= q.due - q.credited then 'held'
                     when q.held > 0 then 'part_paid'
                     when q.refunded > 0 then 'refunded' when q.used > 0 then 'settled'      -- B8-FIX F5: money that came back is not "to collect"
                     when q.istatus = 'void' then 'discarded' else 'unpaid' end as state,   -- B8-FIX F4: a discarded draft says so (it was shown as "Invoice not issued yet")
           case when q.waived > 0 or q.istatus in ('draft', 'void') or q.refunded > 0 or q.used > 0 then 0 else greatest(q.due - q.credited - q.held, 0) end as short
      from q
  )
  select jsonb_build_object('today', today,
    'rows', coalesce((select jsonb_agg(jsonb_build_object('deposit_id', r.deposit_id, 'student_id', r.student_id, 'name', r.name, 'household_id', r.household_id,
              'household_name', r.household_name, 'source', r.source, 'mode', r.mode, 'percent_bp', r.percent_bp, 'first_month_cents', r.first_month_cents,
              'required_cents', r.required_cents, 'due_cents', r.due, 'held_cents', r.held, 'waived_cents', r.waived, 'short_cents', r.short, 'state', r.state, 'taxable', r.taxable,
              'period_start', r.period_start, 'invoice_id', r.invoice_id, 'invoice_number', r.number_text, 'invoice_status', r.istatus, 'due_date', r.due_date)
              order by r.name, r.student_id) from r), '[]'::jsonb),
    'totals', jsonb_build_object('held_cents', coalesce((select sum(held) from r), 0), 'taxable_held_cents', coalesce((select sum(taxable_held) from r), 0),
              'students_holding', (select count(*) from r where held > 0), 'required_cents', coalesce((select sum(required_cents) from r where state <> 'waived'), 0),
              'short_cents', coalesce((select sum(short) from r), 0), 'deposits', (select count(*) from r)))
    into res;
  return res;
end $$;

-- grants are unchanged by "create or replace"; say it again so a fresh database is certain
revoke all on function public.credit_cfg(uuid, date) from public, anon, authenticated;
revoke all on function public.credit_consider(lessons) from public, anon, authenticated;
