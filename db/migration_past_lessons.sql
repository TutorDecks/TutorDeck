-- =====================================================================================================
-- T3.10 — centre staff ADD PAST LESSONS (backfill)                                          undo: migration_past_lessons_down.sql
-- =====================================================================================================
-- Needs migration_tutor_moves.sql (the settings validator this file replaces) and, through the chain, staff_slots (staff_slots_gate,
-- recurring_slots.taught_by), staff_attendance (the attendance guard and stamp), centre_invoice_run (how attended lessons are invoiced).
-- Run on the DEV project first. Safe to run twice. ADD-ONLY apart from the validator: four functions, no table or column is touched.
--
-- THE PROBLEM. "Create lessons" (staff_generate_lessons) only builds lessons from today on, so a student who started last week can't be invoiced for
-- lessons already taught. Staff now add them by hand, with a reason, and mark them attended in the same step; attended lessons are what the
-- invoice run bills, so they flow into the next run like any other lesson (and a deposit is raised for a never-invoiced student as designed).
--
-- THE CENTRE'S CHOICE (a process rule, read as of the centre's TODAY; saved under settings.lessons):
--   backfill_allowed_days   0-366, default 31: how far back staff may add. 0 = switched off (the functions say so in plain words).
-- Settings saved before this stay valid: the key is optional and a missing key means 31.
--
-- WHO MAY CALL (same words as the other staff screens)
--   an active OWNER, or STAFF with manage_timetable.  A tutor, a parent, switched-off staff, a stranger, a solo organisation and an unknown id all get
--   the SAME word, NOT_FOUND, so ids can't be probed; staff WITHOUT manage_timetable get NOT_ALLOWED. Solo tutors never reach these functions.
--
-- THE FOUR FUNCTIONS
--   staff_past_lessons_options(org, student)                      what the form needs: the window, the student's weekly pattern, tutors, last price, closed fee months
--   staff_past_lessons_pattern(org, student, from, to)            the dates of the student's weekly slots in a past range, as ready-made items (one per lesson)
--   staff_past_lessons_preview(org, student, tutor, items, confirm_holidays, allow_closed_month)   the list with a verdict per row and a count; writes NOTHING
--   staff_add_past_lessons(org, student, tutor, items, reason, mark_attended, remarks, confirm_holidays, allow_closed_month)   creates them
--   An item is {date, start, end, rate?, subject?} (rate = S$ per hour; missing = the student's weekly slot at that time, else their latest lesson's rate;
--   staff can always type another price, since staff already set prices). At most 62 lessons at a time, ONE student per call.
--
-- THE RULES (the same checks run in the preview and in the add; the add is ALL OR NOTHING: if one row is refused nothing is made)
--   BACKFILL_OFF         the centre's setting is 0
--   NOT_PAST             only days BEFORE today (the centre's own calendar day): today and later are made by "Create lessons"
--   TOO_OLD              older than today minus backfill_allowed_days
--   BEFORE_STUDENT_START older than the day the student was added minus backfill_allowed_days
--   AFTER_END            after the student's "lessons run until" date
--   BEFORE_BILLING_START before the centre's "billing starts from" date (setting billing.starts_from, import stage A). That setting isn't on this database
--                        until stage A is applied: this file looks for org_billing_start(org) at run time and ignores it when absent, then respects it
--                        the moment it exists. No change is needed here when stage A is applied.
--   FEE_MONTH_CLOSED     the month's platform fee is already recorded (a fee snapshot exists for any LATER month, because the fee of month M+1 is
--                        counted from the students of month M). Staff are refused; the OWNER may pass allow_closed_month (a reason is always needed),
--                        and the answer says the fee month was already closed (its fee is never recomputed).
--   HOLIDAY              a whole-centre holiday: refused unless staff confirm (confirm_holidays). Branch holidays are ignored (students carry no branch).
--   CLASH                the student already has a lesson at an overlapping time (a lesson cancelled by staff with no mark doesn't count). Stricter than "same
--                        student and tutor": one student can't be in two lessons at once, so a different tutor clashes too.
--   (already there)      the same student, tutor, day and start time = skipped, never an error and never doubled: calling twice creates nothing twice,
--                        and the same row twice in one call counts once. The call takes a per-centre lock like the generator.
--   REASON_REQUIRED      a written reason (1-500 characters) on every add.
--   REMARKS_REQUIRED     marking attended follows the centre's lessons.remarks.required, exactly like staff_mark_attendance.
-- A lesson made here is a manual lesson (one_off true, no weekly slot), filed under the centre owner's login like every centre row, scheduled for the
-- chosen tutor; when marked attended in the same step it goes through the normal stamp (status done, marked by the person who clicked, at the time they
-- clicked). Prices follow the generator: amount = rate x hours, rounded to the cent. Each lesson gets its own audit row (action staff_add_past_lesson)
-- carrying the reason. Money is returned only to people who may add (manage_timetable), as everywhere on the staff screens.
-- =====================================================================================================

-- ---------------------------------------------------------------- 1. the settings validator (tutor_moves' version, plus the new key at the end)
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

-- ---------------------------------------------------------------- 2. the one rulebook (internal): a verdict for every item
-- p_today is the centre's own today (from the gate). Returns {"allowed_days": n, "rows": [ {idx, date, start, end, minutes, rate, amount, amount_cents,
-- subject, state: new|there|refused, code, message, holiday, fee_month_closed} ]}. The caller has already checked who the person is and the tutor.
create or replace function public.staff_past_lessons_plan(p_org uuid, p_student uuid, p_tutor uuid, p_items jsonb, p_confirm_holidays boolean,
                                                          p_allow_closed boolean, p_today date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare cfg jsonb := org_settings_on(p_org, p_today); allowed int; st students; tz text; created date; bstart date; lastl lessons; sl recurring_slots;
        it jsonb; i int := 0; d date; s time; e time; mins int; v_rate numeric; subj text; amt numeric; code text; msg text; hol boolean; closed boolean;
        ex_id uuid; ex_start time; ex_end time; ex_tname text; ex_exact boolean; seen text[] := '{}'; k text; rows jsonb := '[]'::jsonb; stt text; raw text; hname text;
begin
  allowed := coalesce((cfg #>> '{lessons,backfill_allowed_days}')::int, 31);
  if allowed < 1 then
    raise exception 'BACKFILL_OFF: this centre hasn''t switched on adding past lessons (Settings, Lessons: "days staff may add past lessons")' using errcode = 'P0001'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) < 1 then
    raise exception 'BAD_ITEMS: pick at least one lesson' using errcode = 'P0001'; end if;
  if jsonb_array_length(p_items) > 62 then
    raise exception 'BAD_ITEMS: add at most 62 lessons at a time' using errcode = 'P0001'; end if;
  select * into st from students where id = p_student and org_id = p_org;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select o.timezone into tz from organisations o where o.id = p_org;
  created := (st.created_at at time zone tz)::date;
  if to_regprocedure('public.org_billing_start(uuid)') is not null then
    execute 'select public.org_billing_start($1)' into bstart using p_org;                    -- import stage A; absent = no cut-off
  end if;
  select * into lastl from lessons where org_id = p_org and student_id = p_student and rate is not null order by lesson_date desc, start_time desc limit 1;

  for it in select value from jsonb_array_elements(p_items) loop
    i := i + 1; code := null; msg := null; hol := false; closed := false; stt := 'new'; v_rate := null; subj := null; amt := null; d := null; s := null; e := null; mins := null;
    sl := null; ex_id := null; ex_start := null; ex_end := null; ex_tname := null; ex_exact := null;
    begin
      d := (it->>'date')::date; s := (it->>'start')::time; e := (it->>'end')::time;
      if d is null or s is null or e is null then raise exception 'x'; end if;
    exception when others then
      code := 'BAD_ITEM'; msg := 'Each lesson needs a date, a start time and an end time.';
    end;
    if code is null then
      mins := (extract(epoch from (e - s)) / 60)::int;
      if mins < 15 or mins > 480 then code := 'BAD_TIME'; msg := 'A lesson lasts 15 minutes to 8 hours, and ends after it starts.'; end if;
    end if;
    if code is null then                                                                        -- price per hour: typed, else the weekly slot, else the last lesson
      raw := nullif(trim(coalesce(it->>'rate', '')), '');
      if raw is not null then
        begin v_rate := raw::numeric; exception when others then code := 'BAD_RATE'; msg := 'The price per hour must be a number between 0 and 1000.'; end;
      else
        select x.* into sl from recurring_slots x where x.org_id = p_org and x.student_id = p_student and x.active
           and x.weekday = extract(isodow from d)::int - 1 and x.start_time = s limit 1;
        v_rate := coalesce(sl.rate, lastl.rate);
        if v_rate is null then code := 'NO_PRICE'; msg := 'Type the price per hour: this student has no weekly lesson or earlier lesson to take it from.'; end if;
      end if;
      if code is null and (v_rate < 0 or v_rate > 1000) then code := 'BAD_RATE'; msg := 'The price per hour must be a number between 0 and 1000.'; end if;
    end if;
    if code is null then
      subj := nullif(trim(coalesce(it->>'subject', '')), '');
      if subj is null then
        if sl.id is null then select x.* into sl from recurring_slots x where x.org_id = p_org and x.student_id = p_student and x.active
                                 and x.weekday = extract(isodow from d)::int - 1 and x.start_time = s limit 1; end if;
        subj := coalesce(sl.subject, lastl.subject);
      end if;
      if length(coalesce(subj, '')) > 60 then code := 'BAD_ITEM'; msg := 'The subject is too long (60 characters at most).'; end if;
      v_rate := round(v_rate, 2); amt := round(v_rate * mins / 60.0, 2);
    end if;

    if code is null and d >= p_today then
      code := 'NOT_PAST'; msg := 'Only days before today can be added here. Today and later lessons come from "Create lessons".';
    end if;
    if code is null then
      k := d::text || ' ' || s::text;
      if k = any(seen) then stt := 'there'; code := 'DUPLICATE'; msg := 'The same lesson is in the list twice; it is made once.';
      else seen := seen || k; end if;
    end if;
    if code is null then                                                                         -- an existing lesson of this student at an overlapping time
      select l.id, l.start_time, l.end_time, m.display_name, (l.start_time = s and l.taught_by is not distinct from p_tutor)
        into ex_id, ex_start, ex_end, ex_tname, ex_exact
        from lessons l left join memberships m on m.id = l.taught_by and m.org_id = l.org_id
       where l.org_id = p_org and l.student_id = p_student and l.lesson_date = d and not (l.status = 'cancelled' and l.attendance is null)
         and l.start_time < e and l.end_time > s
       order by (l.start_time = s and l.taught_by is not distinct from p_tutor) desc, l.start_time limit 1;
      if ex_id is not null and ex_exact then stt := 'there'; code := 'THERE'; msg := 'Already on the timetable: nothing to add.'; end if;
    end if;
    if code is null then
      if d < p_today - allowed then
        code := 'TOO_OLD'; msg := 'This centre lets staff add lessons up to ' || allowed || ' days back (' || to_char(p_today - allowed, 'DD Mon YYYY') || ' onward).';
      elsif d < created - allowed then
        code := 'BEFORE_STUDENT_START'; msg := 'This is too long before the student was added on ' || to_char(created, 'DD Mon YYYY') || ' (the limit is ' || allowed || ' days before).';
      elsif st.end_date is not null and d > st.end_date then
        code := 'AFTER_END'; msg := 'The student''s lessons ended on ' || to_char(st.end_date, 'DD Mon YYYY') || '.';
      elsif bstart is not null and d < bstart then
        code := 'BEFORE_BILLING_START'; msg := 'Billing for this centre starts from ' || to_char(bstart, 'DD Mon YYYY') || ', so earlier lessons can''t be added.';
      end if;
    end if;
    if code is null then
      closed := exists (select 1 from platform_fee_snapshots f where f.org_id = p_org and f.month > date_trunc('month', d)::date);
      if closed and not p_allow_closed then
        code := 'FEE_MONTH_CLOSED'; msg := 'The fee for ' || to_char(d, 'FMMonth YYYY') || ' is already closed. Only the centre owner can add lessons to it.';
      end if;
    end if;
    if code is null then
      select h.name into hname from holidays h where h.org_id = p_org and h.branch_id is null and d between h.starts_on and h.ends_on order by h.starts_on limit 1;
      hol := found;
      if hol and not coalesce(p_confirm_holidays, false) then
        code := 'HOLIDAY'; msg := 'That day is a centre holiday (' || hname || '). Confirm to add it anyway.';
      end if;
    end if;
    if code is null and ex_id is not null and not coalesce(ex_exact, false) then
      code := 'CLASH'; msg := 'This student already has a lesson then (' || to_char(ex_start, 'HH24:MI') || ' to ' || to_char(ex_end, 'HH24:MI')
                                || case when ex_tname is not null then ' with ' || ex_tname else '' end || ').';
    end if;
    if code is not null and stt = 'new' then stt := 'refused'; end if;
    rows := rows || jsonb_build_object('idx', i, 'date', d, 'start', s, 'end', e, 'minutes', mins, 'rate', v_rate, 'amount', amt,
              'amount_cents', case when amt is null then null else round(amt * 100)::bigint end, 'subject', subj, 'state', stt, 'code', code, 'message', msg,
              'holiday', hol, 'fee_month_closed', closed);
  end loop;
  return jsonb_build_object('allowed_days', allowed, 'rows', rows);
end $$;
revoke all on function public.staff_past_lessons_plan(uuid, uuid, uuid, jsonb, boolean, boolean, date) from public, anon, authenticated;

-- the checks every public function shares: the gate (owner / staff with manage_timetable), the owner-only override, the tutor. Returns the centre's today.
create or replace function public.staff_past_lessons_gate(p_org uuid, p_student uuid, p_tutor uuid, p_allow_closed boolean, p_need_tutor boolean) returns date
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_slots_gate(p_org, true);
begin
  if not exists (select 1 from students s where s.id = p_student and s.org_id = p_org) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if coalesce(p_allow_closed, false) and not exists (select 1 from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active' and m.role = 'owner') then
    raise exception 'NOT_ALLOWED: only the centre owner can add lessons to a month whose fee is already closed' using errcode = '42501'; end if;
  if p_need_tutor then
    if p_tutor is null then raise exception 'BAD_TUTOR: pick the tutor who taught these lessons' using errcode = 'P0001'; end if;
    if not exists (select 1 from memberships m where m.id = p_tutor and m.org_id = p_org and m.role in ('tutor', 'staff', 'owner') and m.status in ('active', 'invited')) then
      raise exception 'NOT_AVAILABLE: that person can''t be given lessons at this centre' using errcode = 'P0001'; end if;
  end if;
  return today;
end $$;
revoke all on function public.staff_past_lessons_gate(uuid, uuid, uuid, boolean, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------- 3. what the form needs
create or replace function public.staff_past_lessons_options(p_org uuid, p_student uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_slots_gate(p_org, false); can_add boolean := org_can(p_org, 'manage_timetable'); cfg jsonb := org_settings_on(p_org, today);
        allowed int; st students; tz text; created date; bstart date; lastl lessons; slots jsonb; tutors jsonb; deftutor uuid; closed_before date; is_owner boolean;
begin
  select * into st from students where id = p_student and org_id = p_org;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  allowed := coalesce((cfg #>> '{lessons,backfill_allowed_days}')::int, 31);
  select o.timezone into tz from organisations o where o.id = p_org;
  created := (st.created_at at time zone tz)::date;
  if to_regprocedure('public.org_billing_start(uuid)') is not null then execute 'select public.org_billing_start($1)' into bstart using p_org; end if;
  select * into lastl from lessons where org_id = p_org and student_id = p_student and rate is not null order by lesson_date desc, start_time desc limit 1;
  select max(f.month) into closed_before from platform_fee_snapshots f where f.org_id = p_org;
  is_owner := exists (select 1 from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active' and m.role = 'owner');
  select coalesce(jsonb_agg(jsonb_build_object('weekday', x.weekday, 'start', x.start_time, 'end', x.end_time, 'subject', x.subject,
                                               'rate', case when can_add then x.rate end, 'tutor_id', x.taught_by) order by x.weekday, x.start_time), '[]'::jsonb) into slots
    from recurring_slots x where x.org_id = p_org and x.student_id = p_student and x.active;
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', coalesce(m.display_name, 'Tutor')) order by m.display_name, m.id), '[]'::jsonb) into tutors
    from memberships m where m.org_id = p_org and m.role in ('tutor', 'staff', 'owner') and m.status in ('active', 'invited');
  select coalesce((select x.taught_by from recurring_slots x where x.org_id = p_org and x.student_id = p_student and x.active and x.taught_by is not null order by x.created_at limit 1),
                  (select st2.membership_id from student_tutors st2 where st2.org_id = p_org and st2.student_id = p_student and st2.active order by st2.since limit 1),
                  lastl.taught_by) into deftutor;
  return jsonb_build_object('today', today, 'enabled', allowed >= 1, 'allowed_days', allowed, 'can_add', can_add, 'is_owner', is_owner,
    'earliest', greatest(today - allowed, created - allowed, coalesce(bstart, date '1900-01-01')), 'billing_start', bstart,
    'student', jsonb_build_object('id', st.id, 'name', st.name, 'level', st.level, 'created', created, 'end_date', st.end_date),
    'slots', slots, 'tutors', tutors, 'default_tutor', deftutor,
    'last_rate', case when can_add then lastl.rate end, 'last_subject', lastl.subject, 'fee_closed_before', closed_before,
    'remarks_required', coalesce((cfg #>> '{lessons,remarks,required}')::boolean, false));
end $$;
revoke all on function public.staff_past_lessons_options(uuid, uuid) from public, anon;
grant execute on function public.staff_past_lessons_options(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------- 4. the student's weekly pattern over a past range, as ready-made items
create or replace function public.staff_past_lessons_pattern(p_org uuid, p_student uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_past_lessons_gate(p_org, p_student, null, false, false); t date;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 61 then
    raise exception 'BAD_RANGE: pick a range of at most 62 days' using errcode = 'P0001'; end if;
  t := least(p_to, today - 1);
  return coalesce((select jsonb_agg(jsonb_build_object('date', g.d, 'start', x.start_time, 'end', x.end_time, 'subject', x.subject, 'rate', x.rate, 'tutor_id', x.taught_by)
                          order by g.d, x.start_time)
                     from generate_series(p_from, t, interval '1 day') as g(d)
                     join recurring_slots x on x.org_id = p_org and x.student_id = p_student and x.active and x.weekday = extract(isodow from g.d)::int - 1), '[]'::jsonb);
end $$;
revoke all on function public.staff_past_lessons_pattern(uuid, uuid, date, date) from public, anon;
grant execute on function public.staff_past_lessons_pattern(uuid, uuid, date, date) to authenticated;

-- ---------------------------------------------------------------- 5. the preview (writes nothing)
create or replace function public.staff_past_lessons_preview(p_org uuid, p_student uuid, p_tutor uuid, p_items jsonb,
                                                             p_confirm_holidays boolean default false, p_allow_closed_month boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_past_lessons_gate(p_org, p_student, p_tutor, p_allow_closed_month, true); plan jsonb; rows jsonb;
begin
  plan := staff_past_lessons_plan(p_org, p_student, p_tutor, p_items, p_confirm_holidays, p_allow_closed_month, today);
  rows := plan->'rows';
  return jsonb_build_object('today', today, 'allowed_days', plan->'allowed_days', 'rows', rows,
    'new', (select count(*) from jsonb_array_elements(rows) r where r->>'state' = 'new'),
    'there', (select count(*) from jsonb_array_elements(rows) r where r->>'state' = 'there'),
    'refused', (select count(*) from jsonb_array_elements(rows) r where r->>'state' = 'refused'),
    'total_cents', (select coalesce(sum((r->>'amount_cents')::bigint), 0) from jsonb_array_elements(rows) r where r->>'state' = 'new'),
    'fee_month_closed', exists (select 1 from jsonb_array_elements(rows) r where r->>'state' = 'new' and (r->>'fee_month_closed')::boolean));
end $$;
revoke all on function public.staff_past_lessons_preview(uuid, uuid, uuid, jsonb, boolean, boolean) from public, anon;
grant execute on function public.staff_past_lessons_preview(uuid, uuid, uuid, jsonb, boolean, boolean) to authenticated;

-- ---------------------------------------------------------------- 6. add them
-- All or nothing. Answer: created, skipped (already there), lesson_ids, attended (true when marked in the same step), fee_month_closed (the owner passed
-- a closed fee month: say so on screen), invoiced_months (months that already have an issued invoice for this family: the new lessons go on the next one).
create or replace function public.staff_add_past_lessons(p_org uuid, p_student uuid, p_tutor uuid, p_items jsonb, p_reason text,
                                                         p_mark_attended boolean default false, p_remarks text default null,
                                                         p_confirm_holidays boolean default false, p_allow_closed_month boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := staff_past_lessons_gate(p_org, p_student, p_tutor, p_allow_closed_month, true); why text := nullif(trim(coalesce(p_reason, '')), '');
        rem text := nullif(trim(coalesce(p_remarks, '')), ''); cfg jsonb := org_settings_on(p_org, today); plan jsonb; r jsonb; nbad int; owner_uid uuid;
        st students; lid uuid; ids uuid[] := '{}'; n_new int := 0; n_there int := 0; any_closed boolean := false; months date[]; att boolean := coalesce(p_mark_attended, false);
begin
  if why is null then raise exception 'REASON_REQUIRED: say why these lessons are being added now' using errcode = 'P0001'; end if;
  if length(why) > 500 then raise exception 'TOO_LONG: keep the reason under 500 characters' using errcode = 'P0001'; end if;
  if length(coalesce(p_remarks, '')) > 2000 then raise exception 'TOO_LONG: keep the remarks under 2000 characters' using errcode = 'P0001'; end if;
  if att and coalesce((cfg #>> '{lessons,remarks,required}')::boolean, false) and rem is null then
    raise exception 'REMARKS_REQUIRED: this centre needs remarks before a lesson is marked attended' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended('staff_add_past_lessons:' || p_org::text, 0));          -- two people at once: one waits, then finds the lessons already there
  plan := staff_past_lessons_plan(p_org, p_student, p_tutor, p_items, p_confirm_holidays, p_allow_closed_month, today);
  select count(*) into nbad from jsonb_array_elements(plan->'rows') r2 where r2->>'state' = 'refused';
  if nbad > 0 then
    raise exception 'REFUSED: % of these lessons can''t be added, so none were. First problem: %', nbad, (select r2->>'message' from jsonb_array_elements(plan->'rows') r2 where r2->>'state' = 'refused' limit 1)
      using errcode = 'P0001'; end if;
  select m.user_id into owner_uid from memberships m where m.org_id = p_org and m.role = 'owner' and m.status = 'active' and m.user_id is not null order by m.created_at limit 1;
  if owner_uid is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into st from students where id = p_student and org_id = p_org;

  for r in select value from jsonb_array_elements(plan->'rows') loop
    if r->>'state' = 'there' then n_there := n_there + 1; continue; end if;
    insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, subject, level, rate, split, amount, status, paid, one_off, taught_by)
    values (owner_uid, p_org, p_student, (r->>'date')::date, (r->>'start')::time, (r->>'end')::time, r->>'subject', st.level, (r->>'rate')::numeric, 1,
            (r->>'amount')::numeric, 'scheduled', false, true, p_tutor)
    returning id into lid;
    if att then update lessons set attendance = 'attended', remarks = rem, remarks_at = case when rem is null then null else now() end where id = lid; end if;
    ids := ids || lid; n_new := n_new + 1;
    if (r->>'fee_month_closed')::boolean then any_closed := true; end if;
    insert into audit_log(org_id, actor, action, table_name, row_id, after)
    values (p_org, auth.uid(), 'staff_add_past_lesson', 'lessons', lid::text,
            jsonb_build_object('student', p_student, 'tutor', p_tutor, 'date', r->>'date', 'start', r->>'start', 'end', r->>'end', 'rate', r->'rate', 'amount', r->'amount',
                               'attended', att, 'reason', why, 'holiday_confirmed', (r->>'holiday')::boolean, 'fee_month_closed_override', (r->>'fee_month_closed')::boolean));
  end loop;
  select coalesce(array_agg(distinct ci.period_start), '{}') into months from centre_invoices ci
   where ci.org_id = p_org and ci.kind = 'lesson' and ci.status = 'issued' and (ci.student_id = p_student or (st.household_id is not null and ci.household_id = st.household_id))
     and ci.period_start in (select date_trunc('month', (x->>'date')::date)::date from jsonb_array_elements(plan->'rows') x where x->>'state' = 'new');
  return jsonb_build_object('created', n_new, 'skipped', n_there, 'lesson_ids', to_jsonb(ids), 'attended', att and n_new > 0, 'fee_month_closed', any_closed,
                            'invoiced_months', to_jsonb(months));
end $$;
revoke all on function public.staff_add_past_lessons(uuid, uuid, uuid, jsonb, text, boolean, text, boolean, boolean) from public, anon;
grant execute on function public.staff_add_past_lessons(uuid, uuid, uuid, jsonb, text, boolean, text, boolean, boolean) to authenticated;
