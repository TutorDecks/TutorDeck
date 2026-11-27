-- Undo of migration_tutor_link_propose.sql (T6 steps 5 + 6): the request table and its functions, the link function, and the step 3 / 4 versions of everything the step reshaped.
-- LOST on undo: the waiting and answered REQUESTS (the table goes) and the per-LESSON links (the column goes; the students' own links stay). Changes that were already APPROVED stay
-- (they are ordinary lessons and slots by then). Audit rows stay (append-only). A centre whose setting is tutors_propose simply gets the old "not built yet" refusal from the old functions.
drop function if exists public.tutor_set_link(uuid, uuid, text);
drop function if exists public.tutor_cancel_request(uuid);
drop function if exists public.tutor_my_requests();
drop function if exists public.staff_schedule_requests(uuid, text);
drop function if exists public.staff_decide_request(uuid, text, text);
drop function if exists public.staff_set_lesson_link(uuid, uuid, text);
drop function if exists public.tutor_submit(text, jsonb);
drop function if exists public.tutor_do(text, jsonb);
drop function if exists public.tutor_set_link_do(uuid, uuid, text);
drop function if exists public.schedule_requests_expire(uuid);
drop function if exists public.schedule_request_reason(text);
drop function if exists public.schedule_target_key(text, jsonb);
-- the public functions go back to being the workers (the step 3 / 4 names), and the step 2 three go back to calling the worker directly
drop function if exists public.tutor_add_lesson(uuid, date, time, time, text, text);
drop function if exists public.tutor_save_slot(uuid, uuid, int, time, time, text);
drop function if exists public.tutor_stop_slot(uuid);
drop function if exists public.tutor_generate_lessons(uuid, date, date);
do $$ begin
  if to_regprocedure('public.tutor_add_lesson_do(uuid,date,time,time,text,text)') is not null then alter function public.tutor_add_lesson_do(uuid, date, time, time, text, text) rename to tutor_add_lesson; end if;
  if to_regprocedure('public.tutor_save_slot_do(uuid,uuid,int,time,time,text)') is not null then alter function public.tutor_save_slot_do(uuid, uuid, int, time, time, text) rename to tutor_save_slot; end if;
  if to_regprocedure('public.tutor_stop_slot_do(uuid)') is not null then alter function public.tutor_stop_slot_do(uuid) rename to tutor_stop_slot; end if;
  if to_regprocedure('public.tutor_generate_lessons_do(uuid,date,date)') is not null then alter function public.tutor_generate_lessons_do(uuid, date, date) rename to tutor_generate_lessons; end if;
end $$;
grant execute on function public.tutor_add_lesson(uuid, date, time, time, text, text) to authenticated;
grant execute on function public.tutor_save_slot(uuid, uuid, int, time, time, text) to authenticated;
grant execute on function public.tutor_stop_slot(uuid) to authenticated;
grant execute on function public.tutor_generate_lessons(uuid, date, date) to authenticated;
create or replace function public.tutor_postpone_lesson(p_lesson uuid, p_date date, p_start time, p_reason text default null) returns jsonb
language sql security definer set search_path = public as $$ select public.tutor_change_apply(p_lesson, 'postpone', p_date, p_start, p_reason) $$;
create or replace function public.tutor_revert_lesson(p_lesson uuid, p_reason text default null) returns jsonb
language sql security definer set search_path = public as $$ select public.tutor_change_apply(p_lesson, 'revert', null, null, p_reason) $$;
create or replace function public.tutor_cancel_lesson(p_lesson uuid, p_reason text default null) returns jsonb
language sql security definer set search_path = public as $$ select public.tutor_change_apply(p_lesson, 'cancel', null, null, p_reason) $$;

drop table if exists public.schedule_requests;
alter table public.lessons drop constraint if exists lessons_online_link_ok;
alter table public.lessons drop column if exists online_link;

-- ---- the functions as they were before this step (word for word)
-- the step 2 validator
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
end $$;

-- the step 3/4 rulebook, gate, lists
create or replace function public.tutor_change_block(p_lesson uuid, p_what text) returns text
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); l lessons; tz text; today date; cfg jsonb; mode text; sw boolean; notice int; mx int; used int; start_ts timestamptz; lk text;
        sl recurring_slots; tdate date;
begin
  if me is null or p_what not in ('postpone', 'revert', 'cancel') then return 'NOT_FOUND'; end if;
  select * into l from lessons where id = p_lesson;
  if not found or l.taught_by is null then return 'NOT_FOUND'; end if;
  select o.timezone into tz from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
   where m.id = l.taught_by and m.org_id = l.org_id and m.user_id = me and m.role = 'tutor' and m.status = 'active';
  if tz is null then return 'NOT_FOUND'; end if;
  if not exists (select 1 from student_tutors st where st.org_id = l.org_id and st.student_id = l.student_id and st.membership_id = l.taught_by and st.active) then
    return 'NOT_FOUND'; end if;
  today := (now() at time zone tz)::date;
  cfg := org_settings_on(l.org_id, today);
  mode := coalesce(cfg #>> '{lessons,timetable_editing}', 'admin_only');
  if mode <> 'tutors_direct' then
    return 'NOT_ALLOWED: at this centre the admins change the timetable. Ask them to change this lesson'; end if;
  sw := case when p_what = 'cancel' then coalesce((cfg #>> '{lessons,tutors_edit,cancel}')::boolean, false)
             else coalesce((cfg #>> '{lessons,tutors_edit,postpone}')::boolean, true) end;
  if not sw then
    return 'SWITCH_OFF: this centre doesn''t let tutors ' || case when p_what = 'cancel' then 'cancel' else 'move' end || ' lessons. Ask an admin'; end if;
  lk := lesson_locked_reason(l.id);
  if lk is not null then
    return case lk when 'MARKED'    then 'ALREADY_MARKED: this lesson is already marked, so it can''t be changed here. Ask an admin'
                   when 'CANCELLED' then 'CANCELLED: this lesson was cancelled'
                   else                  'LOCKED: your centre has already closed this lesson, so it can''t be changed here. Ask an admin' end;   -- one word for every closed reason: a tutor is never told which
  end if;
  if p_what = 'revert' then
    if not l.postponed then return 'NOT_MOVED: this lesson is already at its usual time'; end if;
    select * into sl from recurring_slots x where x.id = l.slot_id and x.org_id = l.org_id;
    if not found or l.slot_date is null or not sl.active then
      return 'NO_SLOT: this lesson has no usual slot to go back to. Ask an admin'; end if;
    if sl.taught_by is distinct from l.taught_by or sl.end_time - sl.start_time <> l.end_time - l.start_time then
      return 'SLOT_CHANGED: the usual slot has changed since this lesson was moved. Ask an admin'; end if;
  end if;
  start_ts := (l.lesson_date + l.start_time) at time zone tz;
  if start_ts <= now() then return 'PAST: this lesson has already started'; end if;
  notice := coalesce((cfg #>> '{lessons,min_notice_hours}')::int, 24);
  if start_ts < now() + make_interval(hours => notice) then
    return 'TOO_LATE: a lesson can only be changed ' || notice || ' hour' || case when notice = 1 then '' else 's' end || ' or more before it starts. Ask an admin'; end if;
  mx := coalesce((cfg #>> '{lessons,max_changes_per_month}')::int, 0);
  if mx > 0 then
    used := public.tutor_changes_used(l.org_id, me, tz);
    if used >= mx then
      return 'LIMIT: you have used your ' || mx || ' schedule change' || case when mx = 1 then '' else 's' end || ' for this month. Ask an admin'; end if;
  end if;
  return null;
end $$;

create or replace function public.tutor_own_gate(p_org uuid, p_student uuid, p_switch text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); mem uuid; tz text; today date; cfg jsonb; mode text; sw boolean;
begin
  if me is null or p_org is null or p_switch not in ('one_off', 'weekly_slots', 'generate') then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select m.id, o.timezone into mem, tz from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
   where m.org_id = p_org and m.user_id = me and m.role = 'tutor' and m.status = 'active';
  if mem is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_student is not null and not exists (select 1 from student_tutors st join students s on s.id = st.student_id and s.org_id = st.org_id
                                            where st.org_id = p_org and st.student_id = p_student and st.membership_id = mem and st.active) then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := (now() at time zone tz)::date;
  cfg := org_settings_on(p_org, today);
  mode := coalesce(cfg #>> '{lessons,timetable_editing}', 'admin_only');
  if mode <> 'tutors_direct' then
    raise exception 'NOT_ALLOWED: at this centre the admins change the timetable. Ask them' using errcode = 'P0001'; end if;
  sw := coalesce((cfg #>> array['lessons', 'tutors_edit', p_switch])::boolean, false);
  if not sw then
    raise exception 'SWITCH_OFF: this centre doesn''t let tutors % . Ask an admin', case p_switch when 'one_off' then 'add lessons' when 'weekly_slots' then 'change their weekly slots' else 'create lessons' end
      using errcode = 'P0001'; end if;
  return jsonb_build_object('mem', mem, 'tz', tz, 'today', today,
                            'notice', coalesce((cfg #>> '{lessons,min_notice_hours}')::int, 24),
                            'mx', coalesce((cfg #>> '{lessons,max_changes_per_month}')::int, 0),
                            'skip_holidays', case when jsonb_typeof(cfg #> '{calendar,skip_holidays}') = 'boolean' then (cfg #>> '{calendar,skip_holidays}')::boolean else true end);
end $$;

create or replace function public.tutor_my_students() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if not exists (select 1 from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
                  where m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active') then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('org_id', o.id, 'org_name', o.trading_name, 'student_id', s.id, 'name', s.name, 'level', s.level,
                                                         'subject', b.v->>'subject', 'awaiting_centre', not (b.v->>'known')::boolean)
                                    order by lower(s.name), s.id)
                     from memberships m
                     join organisations o on o.id = m.org_id and o.kind = 'centre'
                     join student_tutors st on st.org_id = m.org_id and st.membership_id = m.id and st.active
                     join students s on s.id = st.student_id and s.org_id = st.org_id
                    cross join lateral (select public.tutor_basis_for(s.org_id, s.id) as v) b
                    where m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active'
                      and (s.end_date is null or s.end_date >= (now() at time zone o.timezone)::date)), '[]'::jsonb);
end $$;

drop function if exists public.tutor_my_slots();
create or replace function public.tutor_my_slots()
returns table(slot_id uuid, org_id uuid, org_name text, weekday int, start_time time, end_time time, subject text,
              student_id uuid, student_name text, student_level text, session_key uuid, timetable_editing text,
              can_change boolean, is_group boolean, awaiting_centre boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if not exists (select 1 from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
                  where m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active') then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  return query
    select sl.id, sl.org_id, o.trading_name, sl.weekday::int, sl.start_time, sl.end_time, sl.subject,
           s.id, s.name, s.level, sl.session_key,
           c.mode,
           (c.mode = 'tutors_direct' and c.sw_slots and sl.session_key is null
              and exists (select 1 from student_tutors st where st.org_id = sl.org_id and st.student_id = sl.student_id and st.membership_id = m.id and st.active)),
           (sl.session_key is not null), sl.price_pending
      from recurring_slots sl
      join memberships m on m.id = sl.taught_by and m.org_id = sl.org_id and m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active'
      join organisations o on o.id = sl.org_id and o.kind = 'centre'
      join students s on s.id = sl.student_id and s.org_id = sl.org_id
     cross join lateral (select coalesce(org_settings_on(sl.org_id, (now() at time zone o.timezone)::date) #>> '{lessons,timetable_editing}', 'admin_only') as mode,
                                coalesce((org_settings_on(sl.org_id, (now() at time zone o.timezone)::date) #>> '{lessons,tutors_edit,weekly_slots}')::boolean, false) as sw_slots) c
     where sl.active and (s.end_date is null or s.end_date >= (now() at time zone o.timezone)::date)
     order by sl.weekday, sl.start_time, s.name, sl.id;
end $$;

create or replace function public.tutor_my_schedule(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare orgs jsonb; lessons jsonb; hols jsonb; today date;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if not exists (select 1 from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
                  where m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active') then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 62 then
    raise exception 'BAD_RANGE: ask for at most 62 days' using errcode = 'P0001'; end if;

  select jsonb_agg(jsonb_build_object('org_id', o.id, 'name', o.trading_name, 'today', (now() at time zone o.timezone)::date,
                                      'timetable_editing', c.mode,
                                      'can_edit', (c.mode = 'tutors_direct' and (c.sw_postpone or c.sw_cancel)),
                                      'can_postpone', (c.mode = 'tutors_direct' and c.sw_postpone), 'can_cancel', (c.mode = 'tutors_direct' and c.sw_cancel),
                                      'min_notice_hours', c.notice, 'max_changes_per_month', c.mx,
                                      'can_one_off', (c.mode = 'tutors_direct' and c.sw_one_off), 'can_slots', (c.mode = 'tutors_direct' and c.sw_slots),
                                      'can_generate', (c.mode = 'tutors_direct' and c.sw_generate),
                                      'changes_left', case when c.mx > 0 and c.mode = 'tutors_direct' then greatest(0, c.mx - public.tutor_changes_used(o.id, auth.uid(), o.timezone)) end)
                      order by o.trading_name, o.id),
         min((now() at time zone o.timezone)::date)
    into orgs, today
    from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
    cross join lateral (select org_settings_on(o.id, (now() at time zone o.timezone)::date) as s) cfg
    cross join lateral (select coalesce(cfg.s #>> '{lessons,timetable_editing}', 'admin_only') as mode,
                               coalesce((cfg.s #>> '{lessons,tutors_edit,postpone}')::boolean, true) as sw_postpone,
                               coalesce((cfg.s #>> '{lessons,tutors_edit,cancel}')::boolean, false) as sw_cancel,
                               coalesce((cfg.s #>> '{lessons,tutors_edit,one_off}')::boolean, false) as sw_one_off,
                               coalesce((cfg.s #>> '{lessons,tutors_edit,weekly_slots}')::boolean, false) as sw_slots,
                               coalesce((cfg.s #>> '{lessons,tutors_edit,generate}')::boolean, false) as sw_generate,
                               coalesce((cfg.s #>> '{lessons,min_notice_hours}')::int, 24) as notice,
                               coalesce((cfg.s #>> '{lessons,max_changes_per_month}')::int, 0) as mx) c
   where m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active';

  select coalesce(jsonb_agg(jsonb_build_object(
           'lesson_id', l.id, 'org_id', l.org_id, 'org_name', o.trading_name,
           'student_id', s.id, 'student_name', s.name, 'student_level', s.level,
           'parent_contact', case when coalesce((org_settings_on(l.org_id, current_date) #>> '{lessons,tutors_see_parent_contact}')::boolean, false) then s.contact end,
           'lesson_date', l.lesson_date, 'start_time', l.start_time, 'end_time', l.end_time,
           'minutes', (extract(epoch from (l.end_time - l.start_time)) / 60)::int, 'subject', l.subject,
           'trial', l.trial, 'attendance', l.attendance, 'status', l.status, 'cancelled', (l.status = 'cancelled'),
           'postponed', l.postponed, 'covering', (l.covered_for is not null), 'online_link', s.online_link,
           'holiday', (select h.name from holidays h where h.org_id = l.org_id and h.branch_id is null
                        and l.lesson_date between h.starts_on and h.ends_on order by h.starts_on, h.name limit 1),
           'can_postpone', (b.postpone is null), 'can_revert', (b.revert is null), 'can_cancel', (b.cancel is null),
           'change_block', case when b.postpone is null or b.cancel is null then null
                                when b.postpone not like 'NOT_ALLOWED%' and b.postpone not like 'SWITCH_OFF%' then split_part(b.postpone, ':', 1)
                                when b.cancel not like 'NOT_ALLOWED%' and b.cancel not like 'SWITCH_OFF%' then split_part(b.cancel, ':', 1) end,
           'changed_by_you', (l.changed_by_tutor_what), 'awaiting_centre', l.price_pending, 'added_by_you', (l.created_by_tutor is not null), 'class_size', (select count(*)::int from lessons y where l.session_id is not null and y.org_id = l.org_id and y.session_id = l.session_id)
         ) order by l.lesson_date, l.start_time, s.name, l.id), '[]'::jsonb)
    into lessons
    from lessons l
    join memberships m on m.id = l.taught_by and m.org_id = l.org_id and m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active'
    join organisations o on o.id = l.org_id and o.kind = 'centre'
    join students s on s.id = l.student_id and s.org_id = l.org_id
    cross join lateral (select tutor_change_block(l.id, 'postpone') as postpone, tutor_change_block(l.id, 'revert') as revert, tutor_change_block(l.id, 'cancel') as cancel) b
   where l.lesson_date between p_from and p_to;

  select coalesce(jsonb_agg(jsonb_build_object('org_id', h.org_id, 'name', h.name, 'starts_on', h.starts_on, 'ends_on', h.ends_on)
                            order by h.starts_on, h.name, h.id), '[]'::jsonb)
    into hols
    from holidays h
   where h.branch_id is null and h.starts_on <= p_to and h.ends_on >= p_from
     and exists (select 1 from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
                  where m.org_id = h.org_id and m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active');

  return jsonb_build_object('today', today, 'from', p_from, 'to', p_to, 'orgs', orgs, 'lessons', lessons, 'holidays', hols);
end $$;

create or replace function public.tutor_lesson_links(p_from date, p_to date) returns table(lesson_id uuid, online_link text)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 62 then
    raise exception 'BAD_RANGE: ask for at most 62 days' using errcode = 'P0001'; end if;
  return query
    select l.id, s.online_link
      from lessons l
      join memberships m on m.id = l.taught_by and m.org_id = l.org_id and m.user_id = auth.uid() and m.status = 'active'
      join organisations o on o.id = l.org_id and o.kind = 'centre'
      join students s on s.id = l.student_id and s.org_id = l.org_id
     where l.lesson_date between p_from and p_to and s.online_link is not null;
end $$;

create or replace function public.staff_timetable(p_org uuid, p_from date, p_to date, p_tutor uuid default null, p_branch uuid default null,
                                                  p_student uuid default null, p_page int default 1, p_notutor boolean default false,
                                                  p_size int default 50) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_attendance_gate(p_org, false); can_ed boolean := org_can(p_org, 'manage_timetable'); rep_on boolean;
        pg int := coalesce(p_page, 1); sz int := coalesce(p_size, 50); nt boolean := coalesce(p_notutor, false);
        cnt jsonb; rows jsonb; tutors jsonb; branches jsonb; studs jsonb; hols jsonb; total int; n_studs int;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 62 then
    raise exception 'BAD_RANGE: ask for at most 62 days' using errcode = 'P0001'; end if;
  if pg < 1 or pg > 100000 then raise exception 'BAD_PAGE: no such page' using errcode = 'P0001'; end if;
  if sz < 1 or sz > 100 then raise exception 'BAD_PAGE: ask for 1 to 100 lessons at a time' using errcode = 'P0001'; end if;
  if p_tutor is not null and not exists (select 1 from memberships m where m.id = p_tutor and m.org_id = p_org) then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_branch is not null and not exists (select 1 from branches b where b.id = p_branch and b.org_id = p_org) then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_student is not null and not exists (select 1 from students s where s.id = p_student and s.org_id = p_org) then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;

  rep_on := case when jsonb_typeof(org_settings_on(p_org, today) #> '{lessons,replacement_tutors}') = 'boolean'
                 then (org_settings_on(p_org, today) #>> '{lessons,replacement_tutors}')::boolean else true end;      -- missing = on

  -- holidays touching the range (a branch's own holiday is labelled with the branch, so it can't be mistaken for the whole centre's)
  select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'name', h.name, 'starts_on', h.starts_on, 'ends_on', h.ends_on,
                                               'branch_id', h.branch_id, 'branch_name', b.name) order by h.starts_on, h.name, h.id), '[]'::jsonb)
    into hols
    from holidays h left join branches b on b.id = h.branch_id and b.org_id = h.org_id
   where h.org_id = p_org and h.starts_on <= p_to and h.ends_on >= p_from
     and (p_branch is null or h.branch_id is null or h.branch_id = p_branch);

  with base as (
    select l.id, l.lesson_date, l.start_time, l.end_time, l.subject, l.status, l.attendance, l.trial, l.postponed, l.session_id, l.taught_by, l.covered_for,
           s.id as sid, s.name as sname, s.level as slevel, s.online_link as slink, t.status as tstatus, t.display_name as tname, cf.status as cfstatus, cf.display_name as cfname,
           (lesson_locked_reason(l.id) is null) as can_re,
           (l.status = 'cancelled' and l.attendance is null) as closed,
           (l.taught_by is null and l.status <> 'cancelled') as no_tutor,
           (select h.name from holidays h where h.org_id = p_org and l.lesson_date between h.starts_on and h.ends_on
               and (h.branch_id is null or h.branch_id = p_branch) order by h.starts_on, h.name limit 1) as holiday
      from lessons l
      join students s on s.id = l.student_id and s.org_id = l.org_id
      left join memberships t on t.id = l.taught_by and t.org_id = l.org_id
      left join memberships cf on cf.id = l.covered_for and cf.org_id = l.org_id
     where l.org_id = p_org and l.lesson_date between p_from and p_to
       and (p_tutor is null or l.taught_by = p_tutor) and (p_student is null or l.student_id = p_student)),
  d as (
    select base.*, case when closed then 'cancelled' when attendance is not null then 'marked' when lesson_date > today then 'future' else 'open' end as state
      from base),
  c as (select count(*)::int as n_all, (count(*) filter (where no_tutor))::int as n_notutor,
               (count(*) filter (where status = 'cancelled'))::int as n_cancelled, (count(*) filter (where holiday is not null))::int as n_holiday from d),
  pg_rows as (
    select * from d where (not nt or no_tutor)
     order by lesson_date, start_time, sname, id
     limit sz offset (pg - 1) * sz)
  select (select row_to_json(c) from c)::jsonb,
         coalesce((select jsonb_agg(jsonb_build_object(
           'lesson_id', id, 'lesson_date', lesson_date, 'start_time', start_time, 'end_time', end_time,
           'minutes', (extract(epoch from (end_time - start_time)) / 60)::int,
           'student_id', sid, 'student_name', sname, 'student_level', slevel, 'subject', subject,
           'tutor_id', taught_by,
           'tutor_name', case when taught_by is null then null when tstatus is null or tstatus = 'disabled' then 'Former tutor' else coalesce(tname, 'Tutor') end,
           'no_tutor', no_tutor, 'trial', trial, 'attendance', attendance, 'state', state,
           'cancelled', (status = 'cancelled'), 'postponed', postponed, 'holiday', holiday, 'session_id', session_id,
           'online_link', slink,
           'covered_for_id', covered_for,
           'covered_for_name', case when covered_for is null then null when cfstatus is null or cfstatus = 'disabled' then 'Former tutor' else coalesce(cfname, 'Tutor') end,
           'can_reassign', can_re)
           order by lesson_date, start_time, sname, id) from pg_rows), '[]'::jsonb)
    into cnt, rows;
  total := case when nt then (cnt->>'n_notutor')::int else (cnt->>'n_all')::int end;

  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', m.display_name, 'active', (m.status = 'active')) order by m.display_name, m.id), '[]'::jsonb) into tutors
    from memberships m where m.org_id = p_org and m.role = 'tutor' and m.status in ('active', 'invited');
  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name) order by b.name, b.id), '[]'::jsonb) into branches
    from branches b where b.org_id = p_org;
  -- who has a lesson in this range (for the student filter): at most 300 names, and the page says so when there are more
  select count(distinct l.student_id) into n_studs from lessons l where l.org_id = p_org and l.lesson_date between p_from and p_to;
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name) order by x.name, x.id), '[]'::jsonb) into studs
    from (select s.id, s.name from students s
           where s.org_id = p_org and exists (select 1 from lessons l where l.org_id = p_org and l.student_id = s.id and l.lesson_date between p_from and p_to)
           order by s.name, s.id limit 300) x;

  return jsonb_build_object('today', today, 'can_edit', can_ed, 'replacements_allowed', rep_on, 'page', pg, 'size', sz, 'total', total, 'counts', cnt, 'holidays', hols,
                            'tutors', tutors, 'branches', branches, 'students', studs, 'students_more', n_studs > 300, 'rows', rows);
end $$;
