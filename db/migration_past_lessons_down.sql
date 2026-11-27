-- Undo of migration_past_lessons.sql: the four functions and their helpers go; the settings validator goes back to tutor_moves' version
-- (a saved backfill_allowed_days key is then simply never read: settings rows are append-only and are not touched).
drop function if exists public.staff_add_past_lessons(uuid, uuid, uuid, jsonb, text, boolean, text, boolean, boolean);
drop function if exists public.staff_past_lessons_preview(uuid, uuid, uuid, jsonb, boolean, boolean);
drop function if exists public.staff_past_lessons_pattern(uuid, uuid, date, date);
drop function if exists public.staff_past_lessons_options(uuid, uuid);
drop function if exists public.staff_past_lessons_gate(uuid, uuid, uuid, boolean, boolean);
drop function if exists public.staff_past_lessons_plan(uuid, uuid, uuid, jsonb, boolean, boolean, date);

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
end $$;
