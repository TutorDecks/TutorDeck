-- =====================================================================================================
-- T6 steps 5 + 6 — the online lesson link, and tutors who ASK (tutors_propose)              undo: migration_tutor_link_propose_down.sql
-- =====================================================================================================
-- Needs migration_tutor_own_lessons.sql (T6 steps 3-4) and, through it, tutor_moves, tutor_schedule, staff_slots (students.online_link, staff_set_student_link) and staff_reassign
-- (the staff_timetable this file patches). Run on the DEV project first. Safe to run twice.
--
-- THE CENTRE'S CHOICE (owner decisions 2026-11-27; all read as of the centre's TODAY, all under settings.lessons)
--   tutors_edit.link            a tutor may set the online lesson link                            BUILT here (no longer "soon")
--   timetable_editing =
--     tutors_propose            EVERY tutor action becomes a REQUEST that staff approve or decline  BUILT here (no longer "soon")
--   request_expiry_days         1-90, default 14: a request nobody answers in that time expires     BUILT here (new)
--   max_changes_per_month       now also counts a tutor's WAITING requests (so one tutor can't queue up more changes than the month allows); an approved request counts as the tutor's
--                               change like any other. notify_family = list_for_admin: an approved change shows in the same staff "Tutor changes" list with "Tell the family".
--
-- THE ONLINE LINK
--   students.online_link (existing: the default link of a student) and lessons.online_link (NEW: the link of one lesson; it wins over the student's). https:// only, no spaces,
--   at most 500 characters ('javascript:' and anything else is refused, by a table check and by every function). Empty = no link. NOT MONEY.
--   Staff set either one always (staff_set_student_link existed; staff_set_lesson_link is new). A tutor sets either one ONLY when tutors_edit.link is on, and only for a student
--   assigned to them / a lesson of theirs that is still to come: tutor_set_link(student, lesson, link) (exactly one of the first two). Setting a link is not a schedule change:
--   it is not counted in max_changes_per_month (a broken meeting link must be fixable), but it is audited, and with tutors_propose it is a request like everything else.
--   Tutors and staff both see the effective link (the lesson's own, else the student's): tutor_my_schedule, tutor_lesson_links, staff_timetable ('lesson_link' says whether it is the lesson's own).
--
-- TUTORS_PROPOSE (how a request works)
--   The tutor calls the SAME functions as before (tutor_postpone_lesson, tutor_revert_lesson, tutor_cancel_lesson, tutor_add_lesson, tutor_save_slot, tutor_stop_slot,
--   tutor_generate_lessons, tutor_set_link). At a tutors_direct centre they act at once (nothing changed). At a tutors_propose centre they check EVERY rule exactly as if they were
--   going to act (the same code runs and is then rolled back, so a request that could never work is refused at once, in the same plain words) and, if all is well, write a
--   schedule_requests row and answer {"requested": true, "request_id": ...}. NOTHING else changes. One waiting request per thing (per lesson, per slot, per new lesson time):
--   ALREADY_PENDING. The tutor sees their requests (tutor_my_requests: pending, approved, declined with the reason, cancelled, expired, no longer possible) and may take back a
--   waiting one (tutor_cancel_request).
--   Staff with manage_timetable see them (staff_schedule_requests: "Waiting for you" on Home and the Requests list) and answer: staff_decide_request(request, 'approve' | 'decline', reason).
--     decline            needs a reason (3-300 characters); the tutor sees it. Nothing else changes.
--     approve            applies the change ONCE and re-checks EVERY rule at that moment (the tutor's own lesson and student, still allowed by the setting and the switch, not marked,
--                        paid or invoiced, not past, no clash, the notice, the monthly limit, the holiday). It does so by running the tutor's own function AS the tutor for that one call
--                        (the transaction's JWT claims are switched to the tutor and put back), so the rules, the audit rows (action tutor_*, the actor = the tutor) and the monthly count
--                        are exactly the ones a direct change makes. If it no longer applies the request becomes 'no_longer_possible' with a plain reason and NOTHING changes.
--     pressing approve twice is harmless: the second answer says already = true and nothing is applied twice. Approving a request that was declined, or declining an approved one,
--                        is refused (ALREADY_DECIDED). Expired / cancelled: the answer says so.
--     expiry             lazily: every function that lists or answers requests first marks the centre's overdue waiting requests 'expired' (audited). No timer is needed.
--   A tutor cancelling in advance = no charge to the family + the amber "changed by tutor" flag + NO automatic make-up credit (owner decision, as at tutors_direct). Tutors never see or
--   set a price; the price of a lesson a tutor adds is filled by the database when staff approve it, exactly as at tutors_direct (step 3). Same NOT_FOUND for "not yours / doesn't exist";
--   solo organisations always NOT_FOUND. Every create / answer / expiry / cancel writes an audit_log row (schedule_request_*), and the approved change writes its usual rows.
--   schedule_requests has NO browser access at all (row-level security on, no policy, no grant): only the functions below read or write it.
--
-- HOW THE EXISTING FUNCTIONS WERE RESHAPED
--   tutor_add_lesson / tutor_save_slot / tutor_stop_slot / tutor_generate_lessons (step 3-4) are RENAMED to *_do (internal, not callable by a browser) and replaced by thin public
--   functions of the same name and arguments that go through tutor_submit. tutor_postpone / revert / cancel keep tutor_change_apply as their worker. tutor_do() is the one place that
--   maps a request kind to its worker. tutor_change_block and tutor_own_gate now let tutors_propose through (the public functions decide what to do with it).
--
-- NO MONEY in anything a tutor can read: the new functions return no rate / amount / paid / compensation / *_cents (tests/sql/tutor_link_propose_test.sql reads their text and every answer).
-- The Supabase API refuses a DELETE / UPDATE without WHERE (pg-safeupdate): every statement below has one.
-- =====================================================================================================

-- ---------------------------------------------------------------- 1. the lesson link column, and the requests table
alter table public.lessons add column if not exists online_link text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'lessons_online_link_ok') then
    alter table public.lessons add constraint lessons_online_link_ok
      check (online_link is null or (online_link ~ '^https://[^[:space:]]+$' and length(online_link) <= 500));
  end if;
end $$;

create table if not exists public.schedule_requests (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.organisations(id) on delete cascade,
  membership_id   uuid,                                     -- the tutor who asked (memberships.id); null if that membership was deleted
  kind            text not null check (kind in ('postpone', 'revert', 'cancel', 'add_lesson', 'save_slot', 'stop_slot', 'generate', 'link')),
  payload         jsonb not null,                           -- exactly what the tutor asked for (no money can be in it: no function takes one)
  target_key      text not null,                            -- what it is about, so there is only ever ONE waiting request per thing
  lesson_id       uuid,                                     -- plain ids (no foreign keys): the history must survive a lesson being removed
  slot_id         uuid,
  student_id      uuid,
  reason          text,                                     -- the tutor's own words
  status          text not null default 'pending' check (status in ('pending', 'approved', 'declined', 'cancelled', 'expired', 'no_longer_possible')),
  decision_code   text,                                     -- declined: DECLINED; no_longer_possible: the rule that now refuses (TOO_LATE, ALREADY_MARKED ...); expired: EXPIRED
  decision_reason text,                                     -- the words the tutor and staff read
  decided_by      uuid,                                     -- auth user of the staff member who answered
  decided_at      timestamptz,
  result          jsonb,                                    -- what the worker answered when it was approved
  created_at      timestamptz not null default now(),
  expires_at      timestamptz not null,
  foreign key (membership_id, org_id) references public.memberships(id, org_id) on delete set null (membership_id)
);
create unique index if not exists schedule_requests_one_waiting on public.schedule_requests(org_id, membership_id, target_key) where status = 'pending';
create index if not exists schedule_requests_org_status on public.schedule_requests(org_id, status, created_at desc);
create index if not exists schedule_requests_tutor on public.schedule_requests(membership_id, created_at desc);
alter table public.schedule_requests enable row level security;                  -- no policy on purpose: browsers never touch this table
revoke all on public.schedule_requests from public, anon, authenticated;

-- ---------------------------------------------------------------- 2. the settings validator (step 2's, plus request_expiry_days)
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

-- ---------------------------------------------------------------- 3. the rulebook and the gate now let a tutor through at a centre that asks for requests
-- Both are the step 3 / 4 text word for word; the only changes are that tutors_propose passes the mode check (the public functions below turn the action into a request)
-- and that the gate knows the 'link' switch.
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
  if mode not in ('tutors_direct', 'tutors_propose') then
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
  if me is null or p_org is null or p_switch not in ('one_off', 'weekly_slots', 'generate', 'link') then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select m.id, o.timezone into mem, tz from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
   where m.org_id = p_org and m.user_id = me and m.role = 'tutor' and m.status = 'active';
  if mem is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_student is not null and not exists (select 1 from student_tutors st join students s on s.id = st.student_id and s.org_id = st.org_id
                                            where st.org_id = p_org and st.student_id = p_student and st.membership_id = mem and st.active) then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := (now() at time zone tz)::date;
  cfg := org_settings_on(p_org, today);
  mode := coalesce(cfg #>> '{lessons,timetable_editing}', 'admin_only');
  if mode not in ('tutors_direct', 'tutors_propose') then
    raise exception 'NOT_ALLOWED: at this centre the admins change the timetable. Ask them' using errcode = 'P0001'; end if;
  sw := coalesce((cfg #>> array['lessons', 'tutors_edit', p_switch])::boolean, false);
  if not sw then
    raise exception 'SWITCH_OFF: this centre doesn''t let tutors % . Ask an admin', case p_switch when 'one_off' then 'add lessons' when 'weekly_slots' then 'change their weekly slots' when 'link' then 'set the online lesson link' else 'create lessons' end
      using errcode = 'P0001'; end if;
  return jsonb_build_object('mem', mem, 'tz', tz, 'today', today,
                            'notice', coalesce((cfg #>> '{lessons,min_notice_hours}')::int, 24),
                            'mx', coalesce((cfg #>> '{lessons,max_changes_per_month}')::int, 0),
                            'skip_holidays', case when jsonb_typeof(cfg #> '{calendar,skip_holidays}') = 'boolean' then (cfg #>> '{calendar,skip_holidays}')::boolean else true end);
end $$;

-- ---------------------------------------------------------------- 4. the old workers become internal (renamed once; safe to run twice)
do $$ begin
  if to_regprocedure('public.tutor_add_lesson_do(uuid,date,time,time,text,text)') is null then
    alter function public.tutor_add_lesson(uuid, date, time, time, text, text) rename to tutor_add_lesson_do; end if;
  if to_regprocedure('public.tutor_save_slot_do(uuid,uuid,int,time,time,text)') is null then
    alter function public.tutor_save_slot(uuid, uuid, int, time, time, text) rename to tutor_save_slot_do; end if;
  if to_regprocedure('public.tutor_stop_slot_do(uuid)') is null then
    alter function public.tutor_stop_slot(uuid) rename to tutor_stop_slot_do; end if;
  if to_regprocedure('public.tutor_generate_lessons_do(uuid,date,date)') is null then
    alter function public.tutor_generate_lessons(uuid, date, date) rename to tutor_generate_lessons_do; end if;
end $$;
revoke all on function public.tutor_add_lesson_do(uuid, date, time, time, text, text) from public, anon, authenticated;
revoke all on function public.tutor_save_slot_do(uuid, uuid, int, time, time, text) from public, anon, authenticated;
revoke all on function public.tutor_stop_slot_do(uuid) from public, anon, authenticated;
revoke all on function public.tutor_generate_lessons_do(uuid, date, date) from public, anon, authenticated;

-- ---------------------------------------------------------------- 5. set a link (the worker; internal)
-- Exactly one of p_student / p_lesson. The student's DEFAULT link needs a student assigned to the caller; a lesson's own link needs the caller's own lesson that is still to come
-- (not cancelled, not over). Empty = clear (a lesson then falls back to the student's link). Answer changed = false when nothing differs (nothing written, nothing audited).
create or replace function public.tutor_set_link_do(p_student uuid, p_lesson uuid, p_link text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare org uuid; sid uuid := p_student; l lessons; g jsonb; mem uuid; today date; old text; lk text := nullif(trim(coalesce(p_link, '')), '');
begin
  if auth.uid() is null or (p_student is null) = (p_lesson is null) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_lesson is not null then
    select * into l from lessons where id = p_lesson;
    if not found or l.taught_by is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    org := l.org_id; sid := l.student_id;
  else
    select s.org_id into org from students s where s.id = p_student;
    if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  end if;
  g := public.tutor_own_gate(org, sid, 'link');
  mem := (g->>'mem')::uuid; today := (g->>'today')::date;
  if p_lesson is not null and l.taught_by is distinct from mem then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if lk is not null and (length(lk) > 500 or lk !~ '^https://[^[:space:]]+$') then
    raise exception 'BAD_LINK: the link must start with https:// and have no spaces (500 characters at most)' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended('tutor_own:' || mem::text, 0));
  if p_lesson is not null then
    select * into l from lessons where id = p_lesson;
    if l.status = 'cancelled' then raise exception 'CANCELLED: this lesson was cancelled' using errcode = 'P0001'; end if;
    if l.lesson_date < today then raise exception 'PAST: this lesson is over' using errcode = 'P0001'; end if;
    old := l.online_link;
    if lk is not distinct from old then return jsonb_build_object('changed', false, 'scope', 'lesson', 'online_link', lk); end if;
    update lessons set online_link = lk where id = p_lesson;
  else
    select s.online_link into old from students s where s.id = sid and s.org_id = org;
    if lk is not distinct from old then return jsonb_build_object('changed', false, 'scope', 'student', 'online_link', lk); end if;
    update students set online_link = lk where id = sid and org_id = org;
  end if;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (org, auth.uid(), 'tutor_set_link', case when p_lesson is not null then 'lessons' else 'students' end, coalesce(p_lesson, sid)::text,
          jsonb_build_object('online_link', old), jsonb_build_object('online_link', lk, 'student_id', sid));
  return jsonb_build_object('changed', true, 'scope', case when p_lesson is not null then 'lesson' else 'student' end, 'online_link', lk);
end $$;

-- ---------------------------------------------------------------- 6. the one dispatcher: which worker does which kind (internal)
-- p_kind: postpone | revert | cancel | add_lesson | save_slot | stop_slot | generate | link. a = the arguments as jsonb (the keys are the ones the public functions build).
create or replace function public.tutor_do(p_kind text, a jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  return case p_kind
    when 'postpone'   then public.tutor_change_apply((a->>'lesson')::uuid, 'postpone', (a->>'date')::date, (a->>'start')::time, a->>'reason')
    when 'revert'     then public.tutor_change_apply((a->>'lesson')::uuid, 'revert', null, null, a->>'reason')
    when 'cancel'     then public.tutor_change_apply((a->>'lesson')::uuid, 'cancel', null, null, a->>'reason')
    when 'add_lesson' then public.tutor_add_lesson_do((a->>'student')::uuid, (a->>'date')::date, (a->>'start')::time, (a->>'end')::time, a->>'subject', a->>'note')
    when 'save_slot'  then public.tutor_save_slot_do((a->>'slot')::uuid, (a->>'student')::uuid, (a->>'weekday')::int, (a->>'start')::time, (a->>'end')::time, a->>'subject')
    when 'stop_slot'  then public.tutor_stop_slot_do((a->>'slot')::uuid)
    when 'generate'   then public.tutor_generate_lessons_do((a->>'org')::uuid, (a->>'from')::date, (a->>'to')::date)
    when 'link'       then public.tutor_set_link_do((a->>'student')::uuid, (a->>'lesson')::uuid, a->>'link')
    else null end;
end $$;

-- what a request is ABOUT, so two of them about the same thing can't both be waiting
create or replace function public.schedule_target_key(p_kind text, a jsonb) returns text
language sql immutable set search_path = public as $$
  select case
    when p_kind in ('postpone', 'revert', 'cancel') then 'lesson:' || coalesce(a->>'lesson', '')
    when p_kind = 'add_lesson' then 'add:' || coalesce(a->>'student', '') || ':' || coalesce(a->>'date', '') || ':' || coalesce(a->>'start', '')
    when p_kind = 'save_slot' and a->>'slot' is null then 'newslot:' || coalesce(a->>'student', '') || ':' || coalesce(a->>'weekday', '') || ':' || coalesce(a->>'start', '')
    when p_kind in ('save_slot', 'stop_slot') then 'slot:' || coalesce(a->>'slot', '')
    when p_kind = 'generate' then 'gen:' || coalesce(a->>'org', '') || ':' || coalesce(a->>'from', '') || ':' || coalesce(a->>'to', '')
    when p_kind = 'link' then 'link:' || case when a->>'lesson' is not null then 'lesson:' || (a->>'lesson') else 'student:' || coalesce(a->>'student', '') end
    else p_kind end
$$;

-- the words staff and the tutor read when an approval no longer works (the code is the first word of the worker's refusal)
create or replace function public.schedule_request_reason(p_code text) returns text
language sql immutable set search_path = public as $$
  select case p_code
    when 'NOT_FOUND'       then 'The lesson or student is no longer this tutor''s, or no longer exists'
    when 'NOT_ALLOWED'     then 'Your centre no longer lets tutors change the timetable'
    when 'SWITCH_OFF'      then 'Your centre has switched this kind of change off since the request was made'
    when 'ALREADY_MARKED'  then 'The lesson has been marked since the request was made'
    when 'CANCELLED'       then 'The lesson has been cancelled since the request was made'
    when 'LOCKED'          then 'The lesson has been paid or put on an invoice since the request was made'
    when 'NOT_MOVED'       then 'The lesson is already at its usual time'
    when 'NO_SLOT'         then 'The lesson no longer has a usual slot to go back to'
    when 'SLOT_CHANGED'    then 'The usual slot has changed since the request was made'
    when 'PAST'            then 'The lesson has already started or is over'
    when 'TOO_LATE'        then 'It is now too close to the lesson: your centre''s notice time has passed'
    when 'LIMIT'           then 'The tutor has used all their schedule changes for this month'
    when 'BAD_DATE'        then 'The day or time asked for has passed or is out of range'
    when 'BAD_TIME'        then 'The time asked for is not possible'
    when 'BAD_RANGE'       then 'The dates asked for are no longer possible'
    when 'HOLIDAY'         then 'The day asked for is now a centre holiday'
    when 'CLASH'           then 'The tutor already has a lesson at that time'
    when 'ALREADY_THERE'   then 'The student already has a lesson at that time'
    when 'SLOT_CLASH'      then 'The student already has a weekly lesson at that time'
    when 'TUTOR_CLASH'     then 'The tutor already has a weekly lesson at that time'
    when 'NO_CHANGE'       then 'It is already the way the tutor asked for'
    when 'STUDENT_ENDED'   then 'The student''s lessons have ended'
    when 'GROUP_CLASS'     then 'This is a group class, which only an admin changes'
    when 'GROUP_NOT_YOURS' then 'The lesson is part of a class that includes other tutors'' lessons'
    when 'BAD_LINK'        then 'The link is not a valid https:// link'
    when 'REASON_REQUIRED' then 'The reason is missing or too short'
    when 'TOO_LONG'        then 'A text in the request is too long'
    else 'It can no longer be done'
  end
$$;

-- ---------------------------------------------------------------- 7. overdue waiting requests become 'expired' (internal; every function that lists or answers requests calls it first)
create or replace function public.schedule_requests_expire(p_org uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; r record;
begin
  for r in select x.id, x.org_id, x.kind from schedule_requests x where x.org_id = p_org and x.status = 'pending' and x.expires_at <= now() order by x.id for update loop
    update schedule_requests set status = 'expired', decided_at = now(), decision_code = 'EXPIRED', decision_reason = 'Nobody answered in time, so the request ran out' where id = r.id;
    insert into audit_log(org_id, actor, action, table_name, row_id, after)
    values (r.org_id, null, 'schedule_request_expired', 'schedule_requests', r.id::text, jsonb_build_object('kind', r.kind));
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- 8. what every tutor action goes through
-- act at once (tutors_direct, or admin_only / anything else: the worker says NOT_ALLOWED), or at tutors_propose: check every rule for real, roll that back, and write the request.
create or replace function public.tutor_submit(p_kind text, a jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); org uuid; mem uuid; tz text; today date; cfg jsonb; mode text; days int; mx int; used int; pend int; key text; res jsonb := null; rid uuid; sid uuid; lid uuid; slid uuid;
        f date; t date; nxt jsonb := a;
begin
  if me is null or p_kind not in ('postpone', 'revert', 'cancel', 'add_lesson', 'save_slot', 'stop_slot', 'generate', 'link') then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  lid := (a->>'lesson')::uuid; slid := (a->>'slot')::uuid; sid := (a->>'student')::uuid;
  org := case
    when p_kind in ('postpone', 'revert', 'cancel') then (select l.org_id from lessons l where l.id = lid)
    when p_kind = 'add_lesson' then (select s.org_id from students s where s.id = sid)
    when p_kind in ('save_slot', 'stop_slot') then case when slid is not null then (select x.org_id from recurring_slots x where x.id = slid) else (select s.org_id from students s where s.id = sid) end
    when p_kind = 'generate' then (a->>'org')::uuid
    else case when lid is not null then (select l.org_id from lessons l where l.id = lid) else (select s.org_id from students s where s.id = sid) end end;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select m.id, o.timezone into mem, tz from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
   where m.org_id = org and m.user_id = me and m.role = 'tutor' and m.status = 'active';
  if mem is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := (now() at time zone tz)::date;
  cfg := org_settings_on(org, today);
  mode := coalesce(cfg #>> '{lessons,timetable_editing}', 'admin_only');
  if mode <> 'tutors_propose' then return public.tutor_do(p_kind, a); end if;           -- direct (or refused by the worker, in its own words)

  -- ---- tutors_propose: a request
  perform public.schedule_requests_expire(org);
  perform pg_advisory_xact_lock(hashtextextended('tutor_own:' || mem::text, 0));          -- two presses together: the second sees the first one's request
  if p_kind = 'generate' then                                                              -- fix the dates now, so approving later means what the tutor saw
    f := coalesce((a->>'from')::date, today); t := coalesce((a->>'to')::date, f + 27);
    nxt := a || jsonb_build_object('from', f, 'to', t);
  end if;
  key := public.schedule_target_key(p_kind, nxt);
  if exists (select 1 from schedule_requests r where r.org_id = org and r.membership_id = mem and r.target_key = key and r.status = 'pending') then
    raise exception 'ALREADY_PENDING: you have already asked for this and an admin hasn''t answered yet. Take that request back first if you want to change it' using errcode = 'P0001'; end if;
  mx := coalesce((cfg #>> '{lessons,max_changes_per_month}')::int, 0);
  if mx > 0 and p_kind not in ('generate', 'link') then                                    -- waiting requests use up the month's changes too (the worker below counts the done ones)
    used := public.tutor_changes_used(org, me, tz);
    select count(*)::int into pend from schedule_requests r where r.org_id = org and r.membership_id = mem and r.status = 'pending' and r.kind not in ('generate', 'link');
    if used + pend >= mx then
      raise exception 'LIMIT: you have used your % schedule change% for this month, counting the requests that are still waiting. Ask an admin', mx, case when mx = 1 then '' else 's' end using errcode = 'P0001'; end if;
  end if;
  begin                                                                                    -- every rule, for real, then undo it all
    res := public.tutor_do(p_kind, nxt);
    raise exception 'dry run' using errcode = 'TD001';
  exception when sqlstate 'TD001' then null;                                               -- (any other error is a real refusal and goes to the tutor as it is)
  end;
  if p_kind = 'stop_slot' and coalesce((res->>'stopped')::int, 0) = 0 then raise exception 'NO_CHANGE: that weekly slot is already stopped' using errcode = 'P0001'; end if;
  if p_kind = 'link' and not coalesce((res->>'changed')::boolean, false) then raise exception 'NO_CHANGE: that is already the link' using errcode = 'P0001'; end if;
  if p_kind = 'generate' and coalesce((res->>'created')::int, 0) = 0 then raise exception 'NOTHING_TO_DO: there are no new lessons to create in those dates' using errcode = 'P0001'; end if;
  if sid is null then sid := coalesce((select l.student_id from lessons l where l.id = lid), (select x.student_id from recurring_slots x where x.id = slid)); end if;
  days := coalesce((cfg #>> '{lessons,request_expiry_days}')::int, 14);
  insert into schedule_requests(org_id, membership_id, kind, payload, target_key, lesson_id, slot_id, student_id, reason, expires_at)
  values (org, mem, p_kind, nxt, key, lid, slid, sid, nullif(trim(coalesce(a->>'reason', '')), ''), now() + make_interval(days => days))
  returning id into rid;
  insert into audit_log(org_id, actor, action, table_name, row_id, after)
  values (org, me, 'schedule_request_created', 'schedule_requests', rid::text, jsonb_build_object('kind', p_kind, 'student_id', sid, 'lesson_id', lid, 'slot_id', slid));
  return jsonb_build_object('requested', true, 'request_id', rid, 'kind', p_kind, 'status', 'pending', 'expires_at', now() + make_interval(days => days));
end $$;

-- ---------------------------------------------------------------- 9. the public functions a tutor calls (same names and arguments as before)
create or replace function public.tutor_postpone_lesson(p_lesson uuid, p_date date, p_start time, p_reason text default null) returns jsonb
language sql security definer set search_path = public as $$
  select public.tutor_submit('postpone', jsonb_build_object('lesson', p_lesson, 'date', p_date, 'start', p_start, 'reason', p_reason)) $$;
create or replace function public.tutor_revert_lesson(p_lesson uuid, p_reason text default null) returns jsonb
language sql security definer set search_path = public as $$
  select public.tutor_submit('revert', jsonb_build_object('lesson', p_lesson, 'reason', p_reason)) $$;
create or replace function public.tutor_cancel_lesson(p_lesson uuid, p_reason text default null) returns jsonb
language sql security definer set search_path = public as $$
  select public.tutor_submit('cancel', jsonb_build_object('lesson', p_lesson, 'reason', p_reason)) $$;
create or replace function public.tutor_add_lesson(p_student uuid, p_date date, p_start time, p_end time, p_subject text default null, p_note text default null) returns jsonb
language sql security definer set search_path = public as $$
  select public.tutor_submit('add_lesson', jsonb_build_object('student', p_student, 'date', p_date, 'start', p_start, 'end', p_end, 'subject', p_subject, 'note', p_note, 'reason', p_note)) $$;
create or replace function public.tutor_save_slot(p_slot uuid, p_student uuid, p_weekday int, p_start time, p_end time, p_subject text default null) returns jsonb
language sql security definer set search_path = public as $$
  select public.tutor_submit('save_slot', jsonb_build_object('slot', p_slot, 'student', p_student, 'weekday', p_weekday, 'start', p_start, 'end', p_end, 'subject', p_subject)) $$;
create or replace function public.tutor_stop_slot(p_slot uuid) returns jsonb
language sql security definer set search_path = public as $$
  select public.tutor_submit('stop_slot', jsonb_build_object('slot', p_slot)) $$;
create or replace function public.tutor_generate_lessons(p_org uuid, p_from date default null, p_to date default null) returns jsonb
language sql security definer set search_path = public as $$
  select public.tutor_submit('generate', jsonb_build_object('org', p_org, 'from', p_from, 'to', p_to)) $$;
create or replace function public.tutor_set_link(p_student uuid, p_lesson uuid, p_link text) returns jsonb
language sql security definer set search_path = public as $$
  select public.tutor_submit('link', jsonb_build_object('student', p_student, 'lesson', p_lesson, 'link', p_link)) $$;

-- ---------------------------------------------------------------- 10. the tutor takes a waiting request back
create or replace function public.tutor_cancel_request(p_request uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r schedule_requests; me uuid := auth.uid();
begin
  if me is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select x.* into r from schedule_requests x join memberships m on m.id = x.membership_id and m.org_id = x.org_id and m.user_id = me and m.role = 'tutor' and m.status = 'active'
   where x.id = p_request;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;           -- someone else's request, or none: the same word
  perform public.schedule_requests_expire(r.org_id);
  select * into r from schedule_requests where id = p_request for update;
  if r.status = 'cancelled' then return jsonb_build_object('request_id', r.id, 'status', 'cancelled', 'already', true); end if;
  if r.status = 'expired' then return jsonb_build_object('request_id', r.id, 'status', 'expired', 'already', true); end if;
  if r.status <> 'pending' then
    raise exception 'ALREADY_DECIDED: an admin has already answered this request' using errcode = 'P0001'; end if;
  update schedule_requests set status = 'cancelled', decided_at = now(), decision_code = 'CANCELLED', decision_reason = 'The tutor took the request back' where id = r.id;
  insert into audit_log(org_id, actor, action, table_name, row_id, after)
  values (r.org_id, me, 'schedule_request_cancelled', 'schedule_requests', r.id::text, jsonb_build_object('kind', r.kind));
  return jsonb_build_object('request_id', r.id, 'status', 'cancelled', 'already', false);
end $$;

-- ---------------------------------------------------------------- 11. staff answer: approve (apply once, every rule re-checked) or decline (a reason)
create or replace function public.staff_decide_request(p_request uuid, p_decision text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r schedule_requests; org uuid; today date; why text := nullif(trim(coalesce(p_reason, '')), ''); uid uuid; tz text; a jsonb; res jsonb; err text; code text; plain text;
        old_claims text; old_sub text; me uuid := auth.uid();
begin
  select x.org_id into org from schedule_requests x where x.id = p_request;
  if org is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := staff_attendance_gate(org, false);                                              -- an owner or staff member of THIS centre, else NOT_FOUND
  if not org_can(org, 'manage_timetable') then
    raise exception 'NOT_ALLOWED: your account can''t answer timetable requests at this centre' using errcode = '42501'; end if;
  if p_decision is null or p_decision not in ('approve', 'decline') then raise exception 'BAD_DECISION: approve or decline' using errcode = 'P0001'; end if;
  select * into r from schedule_requests where id = p_request for update;
  if r.status = 'pending' and r.expires_at <= now() then
    update schedule_requests set status = 'expired', decided_at = now(), decision_code = 'EXPIRED', decision_reason = 'Nobody answered in time, so the request ran out' where id = r.id;
    insert into audit_log(org_id, actor, action, table_name, row_id, after) values (r.org_id, null, 'schedule_request_expired', 'schedule_requests', r.id::text, jsonb_build_object('kind', r.kind));
    r.status := 'expired';
  end if;
  if r.status <> 'pending' then
    if (p_decision = 'approve' and r.status = 'approved') or (p_decision = 'decline' and r.status = 'declined') or r.status in ('expired', 'cancelled', 'no_longer_possible') then
      return jsonb_build_object('request_id', r.id, 'status', r.status, 'already', true, 'reason', r.decision_reason);   -- a repeat press, or it has run out: nothing is applied twice
    end if;
    raise exception 'ALREADY_DECIDED: this request has already been %', case r.status when 'approved' then 'approved' else 'declined' end using errcode = 'P0001';
  end if;

  if p_decision = 'decline' then
    if why is null or length(why) < 3 then raise exception 'REASON_REQUIRED: say why (a few words). The tutor will read it' using errcode = 'P0001'; end if;
    if length(why) > 300 then raise exception 'TOO_LONG: keep the reason under 300 characters' using errcode = 'P0001'; end if;
    update schedule_requests set status = 'declined', decision_code = 'DECLINED', decision_reason = why, decided_by = me, decided_at = now() where id = r.id;
    insert into audit_log(org_id, actor, action, table_name, row_id, after)
    values (r.org_id, me, 'schedule_request_declined', 'schedule_requests', r.id::text, jsonb_build_object('kind', r.kind, 'reason', why));
    return jsonb_build_object('request_id', r.id, 'status', 'declined', 'already', false);
  end if;

  -- approve: be the tutor for this one call
  select m.user_id, o.timezone into uid, tz from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
   where m.id = r.membership_id and m.org_id = r.org_id and m.role = 'tutor' and m.status = 'active' and m.user_id is not null;
  if uid is null then
    err := 'NOT_FOUND'; code := 'NOT_FOUND';
  else
    a := r.payload;
    if r.kind = 'generate' then a := a || jsonb_build_object('from', greatest((a->>'from')::date, today)); end if;     -- the day the tutor asked from may have passed: start today
    old_claims := current_setting('request.jwt.claims', true); old_sub := current_setting('request.jwt.claim.sub', true);
    perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', uid::text, true);
    begin
      res := public.tutor_do(r.kind, a);
    exception when others then
      err := sqlerrm; code := coalesce(substring(sqlerrm from '^([A-Z_]+)'), '');          -- the worker's changes are rolled back with this block
    end;
    perform set_config('request.jwt.claims', coalesce(old_claims, ''), true);
    perform set_config('request.jwt.claim.sub', coalesce(old_sub, ''), true);
  end if;
  if err is not null then
    plain := public.schedule_request_reason(code);
    update schedule_requests set status = 'no_longer_possible', decision_code = nullif(code, ''), decision_reason = plain, decided_by = me, decided_at = now() where id = r.id;
    insert into audit_log(org_id, actor, action, table_name, row_id, after)
    values (r.org_id, me, 'schedule_request_no_longer_possible', 'schedule_requests', r.id::text, jsonb_build_object('kind', r.kind, 'code', code, 'reason', plain));
    return jsonb_build_object('request_id', r.id, 'status', 'no_longer_possible', 'already', false, 'reason', plain, 'code', code);
  end if;
  update schedule_requests set status = 'approved', decided_by = me, decided_at = now(), result = res, decision_code = 'APPROVED' where id = r.id;
  insert into audit_log(org_id, actor, action, table_name, row_id, after)
  values (r.org_id, me, 'schedule_request_approved', 'schedule_requests', r.id::text, jsonb_build_object('kind', r.kind, 'tutor', r.membership_id, 'result', res));
  return jsonb_build_object('request_id', r.id, 'status', 'approved', 'already', false, 'result', res);
end $$;

-- ---------------------------------------------------------------- 12. the tutor's own requests (waiting ones, and the last 30 days of answered ones). No money.
create or replace function public.tutor_my_requests() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); o record; rows jsonb; today date;
begin
  if me is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if not exists (select 1 from memberships m join organisations x on x.id = m.org_id and x.kind = 'centre' where m.user_id = me and m.role = 'tutor' and m.status = 'active') then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  for o in select m.org_id from memberships m join organisations x on x.id = m.org_id and x.kind = 'centre' where m.user_id = me and m.role = 'tutor' and m.status = 'active' loop
    perform public.schedule_requests_expire(o.org_id);
  end loop;
  select min((now() at time zone x.timezone)::date) into today from memberships m join organisations x on x.id = m.org_id and x.kind = 'centre' where m.user_id = me and m.role = 'tutor' and m.status = 'active';
  select coalesce(jsonb_agg(jsonb_build_object(
           'request_id', r.id, 'org_id', r.org_id, 'org_name', org.trading_name, 'kind', r.kind, 'status', r.status,
           'created_at', r.created_at, 'expires_at', r.expires_at, 'decided_at', r.decided_at,
           'reason', r.reason, 'decision_reason', case when r.status in ('declined', 'no_longer_possible', 'expired', 'cancelled') then r.decision_reason end, 'decision_code', r.decision_code,
           'student_id', r.student_id, 'student_name', s.name, 'subject', coalesce(r.payload->>'subject', l.subject, sl.subject),
           'lesson_id', r.lesson_id, 'slot_id', r.slot_id, 'lesson_date', l.lesson_date, 'start_time', l.start_time, 'end_time', l.end_time,
           'new_date', r.payload->>'date', 'new_start', r.payload->>'start', 'new_end', r.payload->>'end',
           'weekday', coalesce(r.payload->>'weekday', sl.weekday::text), 'slot_start', sl.start_time, 'slot_end', sl.end_time,
           'from_date', r.payload->>'from', 'to_date', r.payload->>'to',
           'link', case when r.kind = 'link' then r.payload->>'link' end, 'link_scope', case when r.kind = 'link' then case when r.payload->>'lesson' is not null then 'lesson' else 'student' end end
         ) order by (r.status = 'pending') desc, r.created_at desc, r.id), '[]'::jsonb)
    into rows
    from schedule_requests r
    join memberships m on m.id = r.membership_id and m.org_id = r.org_id and m.user_id = me and m.role = 'tutor' and m.status = 'active'
    join organisations org on org.id = r.org_id and org.kind = 'centre'
    left join students s on s.id = r.student_id and s.org_id = r.org_id
    left join lessons l on l.id = r.lesson_id and l.org_id = r.org_id
    left join recurring_slots sl on sl.id = r.slot_id and sl.org_id = r.org_id
   where r.status = 'pending' or r.created_at >= now() - interval '30 days';
  return jsonb_build_object('today', today, 'rows', rows);
end $$;

-- ---------------------------------------------------------------- 13. staff: the requests ("Waiting for you" on Home, and the Requests list). Needs manage_timetable. No money.
-- p_status: 'pending' (the default: waiting, not yet expired) | 'answered' (everything else, last 60 days) | 'all'. At most 100 rows, waiting ones first, oldest waiting first.
create or replace function public.staff_schedule_requests(p_org uuid, p_status text default 'pending') returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := staff_attendance_gate(p_org, false); st text := coalesce(nullif(p_status, ''), 'pending'); rows jsonb; npend int; can boolean := org_can(p_org, 'manage_timetable');
begin
  if not can then raise exception 'NOT_ALLOWED: your account can''t see timetable requests at this centre' using errcode = '42501'; end if;
  if st not in ('pending', 'answered', 'all') then raise exception 'BAD_STATUS: pending, answered or all' using errcode = 'P0001'; end if;
  perform public.schedule_requests_expire(p_org);
  select count(*)::int into npend from schedule_requests r where r.org_id = p_org and r.status = 'pending';
  select coalesce(jsonb_agg(jsonb_build_object(
           'request_id', r.id, 'kind', r.kind, 'status', r.status, 'can_decide', (r.status = 'pending'),
           'tutor_id', r.membership_id, 'tutor_name', case when t.id is null or t.status = 'disabled' then 'Former tutor' else coalesce(t.display_name, 'Tutor') end,
           'student_id', r.student_id, 'student_name', s.name, 'subject', coalesce(r.payload->>'subject', l.subject, sl.subject),
           'lesson_id', r.lesson_id, 'slot_id', r.slot_id, 'lesson_date', l.lesson_date, 'start_time', l.start_time, 'end_time', l.end_time, 'cancelled_now', (l.status = 'cancelled'),
           'new_date', r.payload->>'date', 'new_start', r.payload->>'start', 'new_end', r.payload->>'end',
           'weekday', coalesce(r.payload->>'weekday', sl.weekday::text), 'slot_start', sl.start_time, 'slot_end', sl.end_time,
           'from_date', r.payload->>'from', 'to_date', r.payload->>'to',
           'link', case when r.kind = 'link' then r.payload->>'link' end, 'link_scope', case when r.kind = 'link' then case when r.payload->>'lesson' is not null then 'lesson' else 'student' end end,
           'reason', r.reason, 'decision_reason', r.decision_reason, 'decision_code', r.decision_code,
           'created_at', r.created_at, 'expires_at', r.expires_at, 'decided_at', r.decided_at,
           'decided_by_name', d.display_name
         ) order by (r.status = 'pending') desc, case when r.status = 'pending' then r.created_at end asc, r.created_at desc, r.id), '[]'::jsonb)
    into rows
    from (select * from schedule_requests y
           where y.org_id = p_org and case st when 'pending' then y.status = 'pending'
                                              when 'answered' then y.status <> 'pending' and y.created_at >= now() - interval '60 days'
                                              else (y.status = 'pending' or y.created_at >= now() - interval '60 days') end
           order by (y.status = 'pending') desc, y.created_at desc, y.id limit 100) r
    left join memberships t on t.id = r.membership_id and t.org_id = r.org_id
    left join memberships d on d.user_id = r.decided_by and d.org_id = r.org_id
    left join students s on s.id = r.student_id and s.org_id = r.org_id
    left join lessons l on l.id = r.lesson_id and l.org_id = r.org_id
    left join recurring_slots sl on sl.id = r.slot_id and sl.org_id = r.org_id;
  return jsonb_build_object('today', today, 'pending', npend, 'can_decide', can, 'status', st, 'rows', rows);
end $$;

-- ---------------------------------------------------------------- 10. the read functions the tutor and staff screens use
-- tutor_my_students / tutor_my_schedule / tutor_my_slots: the step 3 / 4 text with the buttons the centre allows (propose counts), the effective link, and the waiting request.
create or replace function public.tutor_my_students() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if not exists (select 1 from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
                  where m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active') then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('org_id', o.id, 'org_name', o.trading_name, 'student_id', s.id, 'name', s.name, 'level', s.level,
                                                         'subject', b.v->>'subject', 'awaiting_centre', not (b.v->>'known')::boolean, 'online_link', s.online_link)
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
              can_change boolean, is_group boolean, awaiting_centre boolean, pending_request uuid, pending_kind text)
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
           (c.mode in ('tutors_direct', 'tutors_propose') and c.sw_slots and sl.session_key is null
              and exists (select 1 from student_tutors st where st.org_id = sl.org_id and st.student_id = sl.student_id and st.membership_id = m.id and st.active)),
           (sl.session_key is not null), sl.price_pending,
           (select r.id from schedule_requests r where r.slot_id = sl.id and r.membership_id = m.id and r.status = 'pending' and r.expires_at > now() order by r.created_at, r.id limit 1),
           (select r.kind from schedule_requests r where r.slot_id = sl.id and r.membership_id = m.id and r.status = 'pending' and r.expires_at > now() order by r.created_at, r.id limit 1)
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
                                      'timetable_editing', c.mode, 'proposes', (c.mode = 'tutors_propose'), 'can_link', (c.mode in ('tutors_direct', 'tutors_propose') and c.sw_link),
                                      'requests_pending', c.pend, 'request_expiry_days', c.expiry,
                                      'can_edit', (c.mode in ('tutors_direct', 'tutors_propose') and (c.sw_postpone or c.sw_cancel)),
                                      'can_postpone', (c.mode in ('tutors_direct', 'tutors_propose') and c.sw_postpone), 'can_cancel', (c.mode in ('tutors_direct', 'tutors_propose') and c.sw_cancel),
                                      'min_notice_hours', c.notice, 'max_changes_per_month', c.mx,
                                      'can_one_off', (c.mode in ('tutors_direct', 'tutors_propose') and c.sw_one_off), 'can_slots', (c.mode in ('tutors_direct', 'tutors_propose') and c.sw_slots),
                                      'can_generate', (c.mode in ('tutors_direct', 'tutors_propose') and c.sw_generate),
                                      'changes_left', case when c.mx > 0 and c.mode in ('tutors_direct', 'tutors_propose') then greatest(0, c.mx - public.tutor_changes_used(o.id, auth.uid(), o.timezone) - c.pend) end)
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
                               coalesce((cfg.s #>> '{lessons,tutors_edit,link}')::boolean, false) as sw_link,
                               coalesce((cfg.s #>> '{lessons,request_expiry_days}')::int, 14) as expiry,
                               (select count(*)::int from schedule_requests r where r.org_id = o.id and r.membership_id = m.id and r.status = 'pending'
                                   and r.expires_at > now() and r.kind not in ('generate', 'link')) as pend,
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
           'postponed', l.postponed, 'covering', (l.covered_for is not null), 'online_link', coalesce(l.online_link, s.online_link), 'lesson_link', l.online_link, 'student_link', s.online_link,
           'pending_request', (select jsonb_build_object('request_id', r.id, 'kind', r.kind) from schedule_requests r where r.lesson_id = l.id and r.membership_id = m.id and r.status = 'pending' and r.expires_at > now() order by r.created_at, r.id limit 1),
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

-- the link a tutor sees on My lessons: the lesson's own link, else the student's
create or replace function public.tutor_lesson_links(p_from date, p_to date) returns table(lesson_id uuid, online_link text)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 62 then
    raise exception 'BAD_RANGE: ask for at most 62 days' using errcode = 'P0001'; end if;
  return query
    select l.id, coalesce(l.online_link, s.online_link)
      from lessons l
      join memberships m on m.id = l.taught_by and m.org_id = l.org_id and m.user_id = auth.uid() and m.status = 'active'
      join organisations o on o.id = l.org_id and o.kind = 'centre'
      join students s on s.id = l.student_id and s.org_id = l.org_id
     where l.lesson_date between p_from and p_to and coalesce(l.online_link, s.online_link) is not null;
end $$;

-- staff_timetable (step T3/6 text; two lines changed: the lesson's own link wins over the student's, and lesson_link says whether it is the lesson's own)
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
           s.id as sid, s.name as sname, s.level as slevel, s.online_link as slink, l.online_link as llink, t.status as tstatus, t.display_name as tname, cf.status as cfstatus, cf.display_name as cfname,
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
           'online_link', coalesce(llink, slink), 'lesson_link', llink,
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

-- ---------------------------------------------------------------- 14. staff: set (or clear) the link of ONE lesson (the student's default link is staff_set_student_link, step 4)
-- Same rules as the student link: https:// only, no spaces, 500 characters at most. Needs manage_timetable or manage_students. Not money. '' or null clears it (the lesson then uses the student's link).
create or replace function public.staff_set_lesson_link(p_org uuid, p_lesson uuid, p_link text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := staff_attendance_gate(p_org, false); lk text := nullif(trim(coalesce(p_link, '')), ''); old text; stu text;
begin
  if not (org_can(p_org, 'manage_timetable') or org_can(p_org, 'manage_students')) then
    raise exception 'NOT_ALLOWED: your account can''t change students or the timetable at this centre' using errcode = '42501'; end if;
  select l.online_link, s.online_link into old, stu from lessons l join students s on s.id = l.student_id and s.org_id = l.org_id where l.id = p_lesson and l.org_id = p_org;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if lk is not null and (length(lk) > 500 or lk !~ '^https://[^[:space:]]+$') then
    raise exception 'BAD_LINK: the link must start with https:// and have no spaces (500 characters at most)' using errcode = 'P0001'; end if;
  update lessons set online_link = lk where id = p_lesson and org_id = p_org;
  if lk is distinct from old then
    insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
    values (p_org, auth.uid(), 'staff_set_lesson_link', 'lessons', p_lesson::text, jsonb_build_object('online_link', old), jsonb_build_object('online_link', lk));
  end if;
  return jsonb_build_object('online_link', coalesce(lk, stu), 'lesson_link', lk);
end $$;

-- ---------------------------------------------------------------- who may call what
do $$
declare f text;
begin
  foreach f in array array['tutor_postpone_lesson(uuid,date,time,text)', 'tutor_revert_lesson(uuid,text)', 'tutor_cancel_lesson(uuid,text)',
                           'tutor_add_lesson(uuid,date,time,time,text,text)', 'tutor_save_slot(uuid,uuid,int,time,time,text)', 'tutor_stop_slot(uuid)',
                           'tutor_generate_lessons(uuid,date,date)', 'tutor_set_link(uuid,uuid,text)', 'tutor_cancel_request(uuid)', 'tutor_my_requests()',
                           'tutor_my_students()', 'tutor_my_schedule(date,date)', 'tutor_my_slots()', 'tutor_lesson_links(date,date)',
                           'staff_decide_request(uuid,text,text)', 'staff_schedule_requests(uuid,text)', 'staff_set_lesson_link(uuid,uuid,text)',
                           'staff_timetable(uuid,date,date,uuid,uuid,uuid,int,boolean,int)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['tutor_submit(text,jsonb)', 'tutor_do(text,jsonb)', 'tutor_set_link_do(uuid,uuid,text)', 'schedule_target_key(text,jsonb)', 'schedule_request_reason(text)',
                           'schedule_requests_expire(uuid)', 'tutor_add_lesson_do(uuid,date,time,time,text,text)', 'tutor_save_slot_do(uuid,uuid,int,time,time,text)',
                           'tutor_stop_slot_do(uuid)', 'tutor_generate_lessons_do(uuid,date,date)', 'tutor_change_block(uuid,text)', 'tutor_own_gate(uuid,uuid,text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;
