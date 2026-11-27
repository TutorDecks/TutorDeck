-- =====================================================================================================
-- T7.3 — emailing invoices, receipts and overdue reminders to families (centre option)          undo: migration_invoice_email_down.sql
-- =====================================================================================================
-- Run order everywhere: org_foundation → billing → attendance → tutor_access → org_delete → function_lockdown → org_separation → staff_home → staff_students →
--   staff_attendance → staff_charges → staff_trials → staff_timetable → staff_slots → staff_reassign → reassign_link → tutor_schedule → money_settings →
--   centre_money → centre_invoice_run → centre_payments → payment_fix → invites → fee_050 → centre_billing_method → centre_billing_start → tutor_profile →
--   tutor_payout → payout_permission → centre_deposits → centre_refunds → centre_late_fees → centre_credit_undo → slot_changes → tutor_moves → invoice_email.
-- Needs migration_centre_payments.sql (share links, pay status), migration_centre_late_fees.sql (late-fee invoices), migration_staff_students.sql (guardians' emails)
-- and migration_tutor_moves.sql (the settings validator this file replaces). Run on the DEV project first. LIVE only when the owner says ship. Safe to run twice.
--
-- THE OWNER'S RULES (2026-11-27), all built:
--   * Email is a CENTRE OPTION. Default = OFF: invoices are shared by hand (WhatsApp / link) exactly as today. Nothing here changes a centre until it switches it on.
--   * email.mode  off | staff_send (a person with "Issue invoices" presses Send) | auto_on_issue (queued the moment the invoice is issued).
--   * What is sent: the invoice (a secure share link, no PDF), a receipt when a payment is recorded (email.receipts), an overdue reminder (email.reminders:
--     first reminder N days after the due date, repeat every R days, at most M), a notice when a late-fee invoice is issued (email.late_fee_notice).
--     Receipts, reminders and late-fee notices are automatic once their switch is on (that is what they are); the invoice itself follows email.mode.
--   * Who gets it: the family's guardians flagged billing_contact; if none is flagged, the family's FIRST guardian. Never a tutor.
--   * The wording: plain text from the centre's own template (email.templates.<kind>.subject / body) using a limited set of {fields}; blank = our default.
--   * Limits: Brevo's free plan allows 300 a day for the whole platform, so every centre has a daily cap and an hourly cap (email.daily_cap, email.per_hour) and
--     everything goes through a QUEUE ("12 queued, sends over 2 days"). The server (api/email-send.js, api/email-cron.js) also keeps to a platform-wide cap.
--   * A send log, append-only: who, when, the address MASKED (j***@g***.com), which template, the result. Retries: at most 3 attempts (15 min, 1 h, 6 h), then
--     the row is failed and stays failed. A bounce marks the guardian's address 'bad' (staff see it; nothing more is sent to it until the address is fixed).
--   * Tutors and parents have NO access to any of this. Solo organisations are refused. A voided, fully-credited or fully-paid invoice is never mailed, and a reminder
--     that is still queued when the invoice gets paid is cancelled before it goes (the check runs again at send time).
--   * PDPA: the queue and the log hold no address (the address is read from the guardian only at the moment of sending); the log keeps the masked form only.
--
-- WHAT IT ADDS
--   guardians.billing_contact / email_status ('ok' | 'bad') / email_bad_at         (editing a guardian's address clears 'bad')
--   email_queue         one row per message per recipient (state machine)          email_send_log   append-only history
--   triggers: invoice issued → queue the invoice / late-fee notice; payment recorded → queue the receipt (both only if the centre's settings say so)
--   staff functions (issue_invoices; reading also record_payments): email_enqueue, email_enqueue_unsent, email_queue_status, email_queue_list, email_queue_cancel,
--     email_log_list, email_household_contacts, email_set_billing_contacts, email_clear_bad, email_bad_list, email_reminder_preview
--   server-only functions (service role): email_claim, email_complete, email_mark_bounce, email_plan_reminders, email_platform_sent_24h
-- =====================================================================================================

-- ---------------------------------------------------------------------------------------------------
-- 1. billing contacts and bad addresses (on the guardians table)
-- ---------------------------------------------------------------------------------------------------
alter table public.guardians add column if not exists billing_contact boolean not null default false;
alter table public.guardians add column if not exists email_status text not null default 'ok';
alter table public.guardians add column if not exists email_bad_at timestamptz;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'guardians_email_status_check') then
    alter table public.guardians add constraint guardians_email_status_check check (email_status in ('ok', 'bad'));
  end if;
end $$;

-- a new address starts clean: a bounce belongs to the old one
create or replace function public.guardians_email_reset() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.email is distinct from old.email and new.email_status = 'bad' and old.email_status = 'bad' then
    new.email_status := 'ok'; new.email_bad_at := null;
  end if;
  return new;
end $$;
drop trigger if exists guardians_email_reset on public.guardians;
create trigger guardians_email_reset before update of email on public.guardians for each row execute function public.guardians_email_reset();

-- ---------------------------------------------------------------------------------------------------
-- 2. the queue and the send log (server-side tables: nobody reads or writes them from a browser; the screens use the functions below)
-- ---------------------------------------------------------------------------------------------------
create table if not exists public.email_queue (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organisations(id) on delete cascade,
  kind          text not null check (kind in ('invoice', 'receipt', 'reminder', 'late_fee')),
  invoice_id    uuid,
  payment_id    uuid,
  household_id  uuid not null,
  guardian_id   uuid references public.guardians(id) on delete set null,
  reminder_no   int check (reminder_no >= 1),
  status        text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'failed', 'cancelled', 'skipped')),
  reason        text,                                                  -- a short code: why it was skipped / cancelled / failed (never an address)
  attempts      int not null default 0 check (attempts >= 0),
  not_before    timestamptz not null default now(),
  requested_by  uuid,                                                  -- the person who pressed Send; null = the system (automatic)
  requested_at  timestamptz not null default clock_timestamp(),     -- (not now(): messages queued in one call keep the order they were asked in)
  updated_at    timestamptz not null default now(),
  dedupe_key    text,
  unique (id, org_id),
  foreign key (invoice_id, org_id) references public.centre_invoices(id, org_id) on delete cascade,
  foreign key (payment_id, org_id) references public.centre_payments(id, org_id) on delete cascade,
  check ((kind = 'receipt') = (payment_id is not null)),
  check ((kind = 'receipt') = (invoice_id is null)),
  check ((kind = 'reminder') = (reminder_no is not null))
);
create index if not exists email_queue_due on public.email_queue(org_id, status, not_before);
create index if not exists email_queue_invoice on public.email_queue(invoice_id) where invoice_id is not null;
create index if not exists email_queue_guardian on public.email_queue(guardian_id) where guardian_id is not null;
-- the same message to the same person is queued once while it is waiting, being sent or sent (a failed / cancelled / skipped one may be tried again)
create unique index if not exists email_queue_dedupe on public.email_queue(dedupe_key) where dedupe_key is not null and status in ('queued', 'sending', 'sent');

create table if not exists public.email_send_log (
  id               bigint generated always as identity primary key,
  org_id           uuid not null references public.organisations(id) on delete cascade,
  queue_id         uuid,
  kind             text not null,
  invoice_id       uuid,
  guardian_id      uuid,
  to_masked        text,                                               -- j***@g***.com — the only form of the address that is ever kept
  template         text,                                               -- 'invoice' | 'receipt' | 'reminder' | 'late_fee', + ':custom' when the centre's own wording was used
  result           text not null check (result in ('sent', 'retry', 'failed', 'bounced', 'blocked_preview', 'skipped', 'cancelled')),
  detail           text,                                               -- a short code ('http_500', 'invalid_recipient', 'paid', 'no_email' ...)
  attempt          int,
  by_user          uuid,                                               -- who asked; null = automatic
  brevo_message_id text,
  at               timestamptz not null default now()
);
create index if not exists email_send_log_org on public.email_send_log(org_id, id desc);
create index if not exists email_send_log_message on public.email_send_log(brevo_message_id) where brevo_message_id is not null;
create index if not exists email_send_log_sent on public.email_send_log(org_id, at) where result = 'sent';

create or replace function public.email_log_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' and public.centre_money_deleting(old.org_id) then return old; end if;
  raise exception 'The email send log is append-only' using errcode = '42501';
end $$;
drop trigger if exists email_log_guard on public.email_send_log;
create trigger email_log_guard before update or delete on public.email_send_log for each row execute function public.email_log_guard();

create or replace function public.email_queue_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from organisations o where o.id = new.org_id and o.kind = 'centre') then
    raise exception 'Family emails are for centres only' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists email_queue_guard on public.email_queue;
create trigger email_queue_guard before insert on public.email_queue for each row execute function public.email_queue_guard();

alter table public.email_queue enable row level security;
alter table public.email_send_log enable row level security;
revoke all on public.email_queue, public.email_send_log from anon, authenticated;       -- no policies on purpose: functions only
revoke all on function public.email_log_guard() from public, anon, authenticated;
revoke all on function public.email_queue_guard() from public, anon, authenticated;
revoke all on function public.guardians_email_reset() from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------
-- 3. the settings validator (the tutor_moves one, plus the email options)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.org_validate_settings(s jsonb) returns void language plpgsql immutable set search_path = public as $$
declare k text; v jsonb; r record; tp text;
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
end $$;


-- ---------------------------------------------------------------------------------------------------
-- 4. small helpers (internal)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.email_valid(p text) returns boolean
language sql immutable set search_path = public as $$
  select p is not null and length(p) <= 254 and p ~ '^[^@\s<>,;]+@[^@\s<>,;]+\.[^@\s<>,;]{2,}$'
$$;

-- "j***@g***.com": all that is ever written to the log
create or replace function public.email_mask(p text) returns text
language sql immutable set search_path = public as $$
  select case when public.email_valid(trim(p))
    then left(split_part(trim(p), '@', 1), 1) || '***@' || left(split_part(trim(p), '@', 2), 1) || '***.' || regexp_replace(split_part(trim(p), '@', 2), '^.*\.', '')
    else '***' end
$$;

-- the email options with every default filled in (the same defaults as assets/js/org-settings.js)
create or replace function public.email_cfg(s jsonb) returns jsonb
language sql immutable set search_path = public as $$
  select jsonb_build_object(
    'mode',            coalesce(s#>>'{email,mode}', 'off'),
    'receipts',        coalesce((s#>>'{email,receipts}')::boolean, false),
    'late_fee_notice', coalesce((s#>>'{email,late_fee_notice}')::boolean, false),
    'reminders',       jsonb_build_object('enabled', coalesce((s#>>'{email,reminders,enabled}')::boolean, false),
                         'first_after_days', coalesce((s#>>'{email,reminders,first_after_days}')::int, 3),
                         'repeat_days', coalesce((s#>>'{email,reminders,repeat_days}')::int, 7),
                         'max_count', coalesce((s#>>'{email,reminders,max_count}')::int, 3)),
    'daily_cap',       coalesce((s#>>'{email,daily_cap}')::int, 200),
    'per_hour',        coalesce((s#>>'{email,per_hour}')::int, 60),
    'share_link',      coalesce((s#>>'{invoicing,delivery,share_link}')::boolean, true),
    'reply_to',        nullif(trim(coalesce(s#>>'{profile,reply_to_email}', '')), ''),
    'centre_name',     nullif(trim(coalesce(s#>>'{profile,trading_name}', '')), ''),
    'templates',       case when jsonb_typeof(s#>'{email,templates}') = 'object' then s#>'{email,templates}' else '{}'::jsonb end)
$$;

-- a centre's email options as of a day (no caller needed: used by triggers and the server)
create or replace function public.email_org_cfg(p_org uuid, p_day date) returns jsonb
language sql stable security definer set search_path = public as $$
  select public.email_cfg(coalesce((select x.settings from org_settings x where x.org_id = p_org and x.effective_from <= p_day
                                    order by x.effective_from desc, x.version desc limit 1), '{}'::jsonb))
$$;

create or replace function public.email_today(p_org uuid) returns date
language sql stable security definer set search_path = public as $$
  select (now() at time zone o.timezone)::date from organisations o where o.id = p_org and o.kind = 'centre'
$$;

-- Can this invoice be emailed (as an invoice, a reminder or a late-fee notice) right now?  { ok, reason?, ... what the message needs }
create or replace function public.email_invoice_state(p_org uuid, p_invoice uuid, p_today date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare i centre_invoices; b record; hh uuid; ps text;
begin
  select * into i from centre_invoices where id = p_invoice and org_id = p_org;
  if i.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if i.kind not in ('lesson', 'deposit', 'late_fee') then return jsonb_build_object('ok', false, 'reason', 'not_billable'); end if;
  if i.status = 'void' then return jsonb_build_object('ok', false, 'reason', 'void'); end if;
  if i.status <> 'issued' then return jsonb_build_object('ok', false, 'reason', 'not_issued'); end if;
  select * into b from centre_balance_rows(p_org, array[p_invoice]);
  ps := centre_pay_status('issued', i.kind, b.total_cents, b.credited_cents, b.paid_cents, i.due_date, p_today);
  if ps = 'void' then return jsonb_build_object('ok', false, 'reason', 'void'); end if;            -- fully credited
  if ps = 'paid' then return jsonb_build_object('ok', false, 'reason', 'paid'); end if;
  hh := centre_invoice_household(p_invoice);
  if hh is null then return jsonb_build_object('ok', false, 'reason', 'no_household'); end if;
  return jsonb_build_object('ok', true, 'kind', i.kind, 'number', i.number_text, 'household_id', hh, 'due_date', i.due_date, 'issue_date', i.issue_date,
    'total_cents', i.total_cents, 'balance_cents', b.balance_cents, 'pay_status', ps);
end $$;

-- the secret link of an invoice (made if it doesn't exist; renewed if it expired). The same row centre_invoice_share_link() keeps, without needing a browser login.
create or replace function public.email_share_token(p_org uuid, p_invoice uuid, p_today date) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare sh centre_invoice_share;
begin
  select * into sh from centre_invoice_share where invoice_id = p_invoice and org_id = p_org;
  if sh.id is null then
    insert into centre_invoice_share(org_id, invoice_id) values (p_org, p_invoice) returning * into sh;
  elsif sh.expires_on is not null and sh.expires_on < p_today then
    update centre_invoice_share set token = gen_random_uuid(), expires_on = null, rotated_at = now() where id = sh.id returning * into sh;
  end if;
  return sh.token;
end $$;

-- Queue a message for a family's billing contacts. Returns { queued, skipped: [reason, ...] }.
--   p_by null = automatic (a trigger or the reminder planner): problems are recorded as 'skipped' rows so staff can see them.
--   p_by set  = a person pressed Send: problems come back to them in the answer and nothing is written for them.
--   p_resend  = a deliberate second send of the same message (no dedupe key; the caller has already checked the gap and the daily limit).
create or replace function public.email_enqueue_rows(p_org uuid, p_kind text, p_invoice uuid, p_payment uuid, p_household uuid, p_by uuid, p_resend boolean, p_reminder_no int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g record; flagged boolean; any_g boolean := false; why text; key text; n_q int := 0; skipped jsonb := '[]'::jsonb; rows int;
begin
  select exists (select 1 from guardians x where x.org_id = p_org and x.household_id = p_household and x.billing_contact) into flagged;
  for g in select x.id, x.email, x.email_status from guardians x where x.org_id = p_org and x.household_id = p_household and (not flagged or x.billing_contact)
           order by x.created_at, x.id limit (case when flagged then 6 else 1 end) loop
    any_g := true;
    why := case when not email_valid(g.email) then 'no_email' when g.email_status = 'bad' then 'bad_address' end;
    key := case when p_resend then null else p_kind || ':' || coalesce(p_invoice::text, p_payment::text) || ':' || coalesce(p_reminder_no::text, '0') || ':' || g.id::text end;
    if why is not null then
      if p_by is null then
        insert into email_queue(org_id, kind, invoice_id, payment_id, household_id, guardian_id, reminder_no, status, reason, requested_by)
        values (p_org, p_kind, p_invoice, p_payment, p_household, g.id, p_reminder_no, 'skipped', why, null);
        insert into email_send_log(org_id, kind, invoice_id, guardian_id, template, result, detail) values (p_org, p_kind, p_invoice, g.id, p_kind, 'skipped', why);
      end if;
      skipped := skipped || to_jsonb(why);
      continue;
    end if;
    insert into email_queue(org_id, kind, invoice_id, payment_id, household_id, guardian_id, reminder_no, requested_by, dedupe_key)
    values (p_org, p_kind, p_invoice, p_payment, p_household, g.id, p_reminder_no, p_by, key)
    on conflict (dedupe_key) where dedupe_key is not null and status in ('queued', 'sending', 'sent') do nothing;
    get diagnostics rows = row_count;
    if rows = 1 then n_q := n_q + 1; else skipped := skipped || to_jsonb('already_sent'::text); end if;
  end loop;
  if not any_g then
    if p_by is null then
      insert into email_queue(org_id, kind, invoice_id, payment_id, household_id, guardian_id, reminder_no, status, reason, requested_by)
      values (p_org, p_kind, p_invoice, p_payment, p_household, null, p_reminder_no, 'skipped', 'no_contact', null);
      insert into email_send_log(org_id, kind, invoice_id, template, result, detail) values (p_org, p_kind, p_invoice, p_kind, 'skipped', 'no_contact');
    end if;
    skipped := skipped || to_jsonb('no_contact'::text);
  end if;
  return jsonb_build_object('queued', n_q, 'skipped', skipped);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 5. automatic queuing: invoice issued, payment recorded (only when the centre's settings ask for it; never able to stop the invoice or the payment)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.email_on_invoice_issued() returns trigger
language plpgsql security definer set search_path = public as $$
declare cfg jsonb; today date; hh uuid;
begin
  begin
    if new.kind not in ('lesson', 'deposit', 'late_fee') or new.imported_number is not null then return null; end if;
    today := email_today(new.org_id);
    cfg := email_org_cfg(new.org_id, today);
    if cfg->>'mode' = 'off' or not (cfg->>'share_link')::boolean then return null; end if;
    if new.kind = 'late_fee' then
      if not (cfg->>'late_fee_notice')::boolean then return null; end if;
    elsif cfg->>'mode' <> 'auto_on_issue' then return null;
    end if;
    hh := centre_invoice_household(new.id);
    if hh is null then return null; end if;
    perform email_enqueue_rows(new.org_id, case when new.kind = 'late_fee' then 'late_fee' else 'invoice' end, new.id, null, hh, null, false, null);
  exception when others then
    null;                                   -- email trouble must never block an invoice being issued
  end;
  return null;
end $$;
drop trigger if exists email_on_invoice_issued on public.centre_invoices;
create trigger email_on_invoice_issued after update of status on public.centre_invoices for each row
  when (old.status = 'draft' and new.status = 'issued') execute function public.email_on_invoice_issued();

create or replace function public.email_on_payment() returns trigger
language plpgsql security definer set search_path = public as $$
declare cfg jsonb;
begin
  begin
    cfg := email_org_cfg(new.org_id, email_today(new.org_id));
    if cfg->>'mode' = 'off' or not (cfg->>'receipts')::boolean then return null; end if;
    perform email_enqueue_rows(new.org_id, 'receipt', null, new.id, new.household_id, null, false, null);
  exception when others then
    null;                                   -- email trouble must never block a payment being recorded
  end;
  return null;
end $$;
drop trigger if exists email_on_payment on public.centre_payments;
create trigger email_on_payment after insert on public.centre_payments for each row
  when (new.kind = 'payment') execute function public.email_on_payment();

-- ---------------------------------------------------------------------------------------------------
-- 6. the reminder planner (server: daily cron and every drain) — which overdue invoices are due their next reminder
-- ---------------------------------------------------------------------------------------------------
-- Reminder n is due on  due date + first_after_days + (n-1) × repeat_days,  never sooner than repeat_days after the previous one (so a day the job missed
-- doesn't send two at once). Only invoices issued in the last 120 days, so switching reminders on never mails a centre's ancient history.
-- p_dry = count only. Returns how many invoices got (or would get) a reminder now.
create or replace function public.email_plan_reminders(p_org uuid, p_dry boolean default false) returns int
language plpgsql security definer set search_path = public as $$
declare today date; cfg jsonb; inv record; st jsonb; n_prev int; last_day date; n_next int; due_on date; made int := 0; mx int; rep int; first_d int; tz text;
begin
  select timezone into tz from organisations where id = p_org and kind = 'centre';
  if tz is null then return 0; end if;
  today := (now() at time zone tz)::date;
  cfg := email_org_cfg(p_org, today);
  if cfg->>'mode' = 'off' or not (cfg#>>'{reminders,enabled}')::boolean or not (cfg->>'share_link')::boolean then return 0; end if;
  mx := (cfg#>>'{reminders,max_count}')::int; rep := (cfg#>>'{reminders,repeat_days}')::int; first_d := (cfg#>>'{reminders,first_after_days}')::int;
  for inv in select i.id, i.due_date from centre_invoices i
              where i.org_id = p_org and i.status = 'issued' and i.kind in ('lesson', 'deposit', 'late_fee') and i.due_date is not null
                and i.due_date < today and i.issue_date >= today - 120 order by i.due_date, i.id limit 3000 loop
    st := email_invoice_state(p_org, inv.id, today);
    if not (st->>'ok')::boolean then continue; end if;
    select count(distinct q.reminder_no), max((q.requested_at at time zone tz)::date) into n_prev, last_day from email_queue q where q.invoice_id = inv.id and q.kind = 'reminder';
    n_next := n_prev + 1;
    if n_next > mx or (rep = 0 and n_next > 1) then continue; end if;
    due_on := inv.due_date + first_d + (n_next - 1) * rep;
    if last_day is not null then due_on := greatest(due_on, last_day + rep); end if;
    if today < due_on then continue; end if;
    if not p_dry then perform email_enqueue_rows(p_org, 'reminder', inv.id, null, (st->>'household_id')::uuid, null, false, n_next); end if;
    made := made + 1;
  end loop;
  return made;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 7. staff functions (signed in; each starts with the gate: a centre's owner or staff with the permission; everyone else gets NOT_FOUND)
-- ---------------------------------------------------------------------------------------------------
create or replace function public.email_queue_status(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := centre_money_gate(p_org, 'either'); tz text; cfg jsonb; q int; sending int; sent_today int; failed_24h int; cap int; rem int; days int; bad int; last_at timestamptz; skipped_24h int;
begin
  select timezone into tz from organisations where id = p_org;
  cfg := email_org_cfg(p_org, today);
  cap := (cfg->>'daily_cap')::int;
  select count(*) filter (where status = 'queued'), count(*) filter (where status = 'sending') into q, sending from email_queue where org_id = p_org and status in ('queued', 'sending');
  select count(*) filter (where result = 'sent' and (at at time zone tz)::date = today), count(*) filter (where result = 'failed' and at > now() - interval '24 hours'),
         count(*) filter (where result in ('skipped', 'cancelled') and at > now() - interval '24 hours'), max(at) filter (where result = 'sent')
    into sent_today, failed_24h, skipped_24h, last_at from email_send_log where org_id = p_org and at > now() - interval '2 days';
  select count(*) into bad from guardians where org_id = p_org and email_status = 'bad';
  rem := greatest(cap - sent_today, 0);
  days := case when q = 0 then 0 when q <= rem then 1 else 1 + ceil((q - rem)::numeric / cap)::int end;
  return jsonb_build_object('mode', cfg->>'mode', 'queued', q, 'sending', sending, 'sent_today', sent_today, 'failed_24h', failed_24h, 'skipped_24h', skipped_24h,
    'daily_cap', cap, 'per_hour', (cfg->>'per_hour')::int, 'remaining_today', rem, 'sends_over_days', days, 'bad_addresses', bad, 'last_sent_at', last_at,
    'reminders_on', (cfg#>>'{reminders,enabled}')::boolean, 'receipts_on', (cfg->>'receipts')::boolean, 'late_fee_notice_on', (cfg->>'late_fee_notice')::boolean,
    'share_link', (cfg->>'share_link')::boolean, 'today', today);
end $$;

-- Press Send: queue these invoices for their billing contacts. p_resend = send it again on purpose.
create or replace function public.email_enqueue(p_org uuid, p_invoices uuid[], p_resend boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := centre_money_gate(p_org, 'issue_invoices'); cfg jsonb; inv_id uuid; st jsonb; r jsonb; res jsonb := '[]'::jsonb; n_q int := 0; n_s int := 0; mkind text; last_at timestamptz; n_day int; why text;
begin
  if p_invoices is null or coalesce(array_length(p_invoices, 1), 0) = 0 then raise exception 'BAD_VALUE: choose at least one invoice' using errcode = 'P0001'; end if;
  if array_length(p_invoices, 1) > 500 then raise exception 'BAD_VALUE: at most 500 invoices at a time' using errcode = 'P0001'; end if;
  cfg := email_org_cfg(p_org, today);
  if cfg->>'mode' = 'off' then raise exception 'NOT_ALLOWED: emailing invoices is switched off in this centre''s settings (Invoicing > Email)' using errcode = '42501'; end if;
  if not (cfg->>'share_link')::boolean then raise exception 'NOT_ALLOWED: emailing needs the shareable invoice link switched on' using errcode = '42501'; end if;
  foreach inv_id in array p_invoices loop
    st := email_invoice_state(p_org, inv_id, today);
    if not (st->>'ok')::boolean then n_s := n_s + 1; res := res || jsonb_build_object('invoice_id', inv_id, 'reason', st->>'reason'); continue; end if;
    mkind := case when st->>'kind' = 'late_fee' then 'late_fee' else 'invoice' end;
    if p_resend then
      select max(requested_at) into last_at from email_queue where invoice_id = inv_id and kind in ('invoice', 'late_fee') and status in ('queued', 'sending', 'sent');
      select count(*) into n_day from email_queue where invoice_id = inv_id and kind in ('invoice', 'late_fee') and requested_at > now() - interval '24 hours' and status in ('queued', 'sending', 'sent');
      why := case when last_at is not null and last_at > now() - interval '10 minutes' then 'too_soon' when n_day >= 3 then 'daily_limit' end;
      if why is not null then n_s := n_s + 1; res := res || jsonb_build_object('invoice_id', inv_id, 'number', st->>'number', 'reason', why); continue; end if;
    end if;
    r := email_enqueue_rows(p_org, mkind, inv_id, null, (st->>'household_id')::uuid, auth.uid(), p_resend, null);
    n_q := n_q + (r->>'queued')::int;
    if jsonb_array_length(r->'skipped') > 0 then
      n_s := n_s + 1; res := res || jsonb_build_object('invoice_id', inv_id, 'number', st->>'number', 'reason', r#>>'{skipped,0}');
    end if;
  end loop;
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (p_org, auth.uid(), 'email_enqueue', 'email_queue', null, null, jsonb_build_object('invoices', array_length(p_invoices, 1), 'queued', n_q, 'resend', coalesce(p_resend, false)));
  return jsonb_build_object('queued', n_q, 'skipped', n_s, 'problems', res, 'status', email_queue_status(p_org));
end $$;

-- "Send all unsent": every issued invoice of a month (or of the last 45 days when no month is given) that has not been emailed or queued yet
create or replace function public.email_enqueue_unsent(p_org uuid, p_period date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := centre_money_gate(p_org, 'issue_invoices'); ids uuid[]; a date; b date;
begin
  if p_period is null then a := today - 45; b := today; else a := date_trunc('month', p_period)::date; b := (a + interval '1 month - 1 day')::date; end if;
  select coalesce(array_agg(i.id order by i.issue_date, i.id), '{}') into ids from (
    select x.id, x.issue_date from centre_invoices x
     where x.org_id = p_org and x.status = 'issued' and x.kind in ('lesson', 'deposit', 'late_fee') and x.imported_number is null and x.issue_date between a and b
       and not exists (select 1 from email_queue q where q.invoice_id = x.id and q.kind in ('invoice', 'late_fee') and q.status in ('queued', 'sending', 'sent'))
     order by x.issue_date, x.id limit 500) i;
  if coalesce(array_length(ids, 1), 0) = 0 then
    return jsonb_build_object('queued', 0, 'skipped', 0, 'problems', '[]'::jsonb, 'status', email_queue_status(p_org));
  end if;
  return email_enqueue(p_org, ids, false);
end $$;

create or replace function public.email_queue_list(p_org uuid, p_status text default null, p_limit int default 100, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := centre_money_gate(p_org, 'either');
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'status', q.status, 'reason', q.reason, 'attempts', q.attempts, 'not_before', q.not_before,
      'requested_at', q.requested_at, 'reminder_no', q.reminder_no, 'invoice_number', i.number_text, 'family', h.name, 'to_masked', email_mask(g.email),
      'by', (select m.display_name from memberships m where m.org_id = p_org and m.user_id = q.requested_by and m.status = 'active' limit 1), 'automatic', q.requested_by is null)
      order by q.requested_at desc, q.id)
    from (select * from email_queue x where x.org_id = p_org and (p_status is null or x.status = p_status) order by x.requested_at desc, x.id
          limit least(greatest(coalesce(p_limit, 100), 1), 300) offset greatest(coalesce(p_offset, 0), 0)) q
    left join centre_invoices i on i.id = q.invoice_id and i.org_id = p_org
    left join households h on h.id = q.household_id and h.org_id = p_org
    left join guardians g on g.id = q.guardian_id and g.org_id = p_org), '[]'::jsonb);
end $$;

create or replace function public.email_queue_cancel(p_org uuid, p_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := centre_money_gate(p_org, 'issue_invoices'); q record; n int := 0;
begin
  if p_ids is null or coalesce(array_length(p_ids, 1), 0) = 0 then raise exception 'BAD_VALUE: choose at least one message' using errcode = 'P0001'; end if;
  if array_length(p_ids, 1) > 500 then raise exception 'BAD_VALUE: at most 500 at a time' using errcode = 'P0001'; end if;
  for q in select * from email_queue where org_id = p_org and id = any(p_ids) and status = 'queued' order by id for update loop
    update email_queue set status = 'cancelled', reason = 'cancelled_by_staff', updated_at = now() where id = q.id;
    insert into email_send_log(org_id, queue_id, kind, invoice_id, guardian_id, template, result, detail, by_user) values (p_org, q.id, q.kind, q.invoice_id, q.guardian_id, q.kind, 'cancelled', 'cancelled_by_staff', auth.uid());
    n := n + 1;
  end loop;
  if n > 0 then
    insert into audit_log(org_id, actor, action, table_name, row_id, before, after) values (p_org, auth.uid(), 'email_queue_cancel', 'email_queue', null, null, jsonb_build_object('cancelled', n));
  end if;
  return jsonb_build_object('cancelled', n, 'status', email_queue_status(p_org));
end $$;

create or replace function public.email_log_list(p_org uuid, p_limit int default 100, p_before bigint default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := centre_money_gate(p_org, 'either');
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'at', l.at, 'kind', l.kind, 'template', l.template, 'result', l.result, 'detail', l.detail, 'attempt', l.attempt,
      'to_masked', l.to_masked, 'invoice_number', i.number_text,
      'by', case when l.by_user is null then null else (select m.display_name from memberships m where m.org_id = p_org and m.user_id = l.by_user and m.status = 'active' limit 1) end,
      'automatic', l.by_user is null) order by l.id desc)
    from (select * from email_send_log x where x.org_id = p_org and (p_before is null or x.id < p_before) order by x.id desc limit least(greatest(coalesce(p_limit, 100), 1), 300)) l
    left join centre_invoices i on i.id = l.invoice_id and i.org_id = p_org), '[]'::jsonb);
end $$;

-- who would get a family's emails, with addresses masked
create or replace function public.email_household_contacts(p_org uuid, p_household uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := centre_money_gate(p_org, 'either'); flagged boolean;
begin
  if not exists (select 1 from households h where h.id = p_household and h.org_id = p_org) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select exists (select 1 from guardians x where x.org_id = p_org and x.household_id = p_household and x.billing_contact) into flagged;
  return jsonb_build_object('flagged', flagged, 'guardians', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'relation', g.relation, 'has_email', email_valid(g.email),
      'to_masked', case when email_valid(g.email) then email_mask(g.email) else null end, 'billing_contact', g.billing_contact, 'bad', g.email_status = 'bad',
      'receives', (case when flagged then g.billing_contact else g.id = (select y.id from guardians y where y.org_id = p_org and y.household_id = p_household order by y.created_at, y.id limit 1) end)
                  and email_valid(g.email) and g.email_status = 'ok') order by g.created_at, g.id)
    from guardians g where g.org_id = p_org and g.household_id = p_household), '[]'::jsonb));
end $$;

-- choose a family's billing contacts (an empty list = back to "the first guardian")
create or replace function public.email_set_billing_contacts(p_org uuid, p_household uuid, p_guardians uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := centre_money_gate(p_org, 'issue_invoices'); gid uuid; n int;
begin
  if not exists (select 1 from households h where h.id = p_household and h.org_id = p_org) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  p_guardians := coalesce(p_guardians, '{}');
  if array_length(p_guardians, 1) > 6 then raise exception 'BAD_VALUE: at most 6 billing contacts' using errcode = 'P0001'; end if;
  foreach gid in array p_guardians loop
    if not exists (select 1 from guardians g where g.id = gid and g.org_id = p_org and g.household_id = p_household) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  end loop;
  update guardians set billing_contact = (id = any(p_guardians)) where org_id = p_org and household_id = p_household and billing_contact is distinct from (id = any(p_guardians));
  get diagnostics n = row_count;
  return email_household_contacts(p_org, p_household);
end $$;

-- "I fixed it": staff trust the address again (editing the address in the student sheet does this by itself)
create or replace function public.email_clear_bad(p_org uuid, p_guardian uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := centre_money_gate(p_org, 'issue_invoices');
begin
  if not exists (select 1 from guardians g where g.id = p_guardian and g.org_id = p_org) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  update guardians set email_status = 'ok', email_bad_at = null where id = p_guardian and org_id = p_org;
  return jsonb_build_object('ok', true, 'bad_addresses', (select count(*) from guardians where org_id = p_org and email_status = 'bad'));
end $$;

create or replace function public.email_bad_list(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := centre_money_gate(p_org, 'either');
begin
  return coalesce((select jsonb_agg(jsonb_build_object('guardian_id', g.id, 'name', g.name, 'family', h.name, 'household_id', g.household_id, 'to_masked', email_mask(g.email), 'since', g.email_bad_at)
      order by g.email_bad_at desc nulls last, g.id)
    from guardians g left join households h on h.id = g.household_id and h.org_id = p_org where g.org_id = p_org and g.email_status = 'bad'), '[]'::jsonb);
end $$;

-- the reminders screen: what the schedule is and how many invoices would be reminded today
create or replace function public.email_reminder_preview(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := centre_money_gate(p_org, 'either'); cfg jsonb; overdue int; due_now int;
begin
  cfg := email_org_cfg(p_org, today);
  select count(*) into overdue from centre_invoices i where i.org_id = p_org and i.status = 'issued' and i.kind in ('lesson', 'deposit', 'late_fee') and i.due_date is not null and i.due_date < today
     and i.issue_date >= today - 120 and (email_invoice_state(p_org, i.id, today)->>'ok')::boolean;
  due_now := email_plan_reminders(p_org, true);
  return jsonb_build_object('enabled', (cfg#>>'{reminders,enabled}')::boolean and cfg->>'mode' <> 'off', 'mode', cfg->>'mode', 'first_after_days', (cfg#>>'{reminders,first_after_days}')::int,
    'repeat_days', (cfg#>>'{reminders,repeat_days}')::int, 'max_count', (cfg#>>'{reminders,max_count}')::int, 'overdue_invoices', overdue, 'due_now', due_now);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- 8. server functions (service role only: they return real addresses to the sender, so no browser can ever call them)
-- ---------------------------------------------------------------------------------------------------
-- Take up to p_max due messages to send now. Keeps to every limit: the centre's daily cap and per-hour cap (counting what is already being sent), p_platform_left (the
-- platform-wide room the server worked out), and checks everything AGAIN at this moment (paid since? voided? switched off? address fixed or bad?).
-- Returns the messages to send (with the address and the wording); the ones that can no longer go are closed here with a reason.
create or replace function public.email_claim(p_org uuid default null, p_max int default 20, p_platform_left int default 1000) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o record; tz text; today date; cfg jsonb; used_day int; used_hr int; busy int; room int; claimed int; total int := 0; q record; st jsonb; g guardians; why text; pay centre_payments;
  res_list jsonb := '[]'::jsonb; payload jsonb; tok uuid; nums text; centre text; cname text; hname text; vars jsonb; tpl jsonb; n_inv int;
begin
  p_max := least(greatest(coalesce(p_max, 1), 1), 100);
  p_platform_left := coalesce(p_platform_left, 0);
  -- a worker that died mid-send: try again later, or give up after three attempts
  update email_queue set status = case when attempts >= 3 then 'failed' else 'queued' end, reason = case when attempts >= 3 then 'stuck' else reason end,
         not_before = now(), updated_at = now()
   where status = 'sending' and updated_at < now() - interval '15 minutes' and (p_org is null or org_id = p_org);
  for o in select distinct x.org_id from email_queue x where x.status = 'queued' and x.not_before <= now() and (p_org is null or x.org_id = p_org) order by x.org_id loop
    exit when total >= p_max or p_platform_left - total <= 0;
    select timezone, trading_name into tz, centre from organisations where id = o.org_id and kind = 'centre';
    if tz is null then continue; end if;
    today := (now() at time zone tz)::date;
    cfg := email_org_cfg(o.org_id, today);
    select count(*) filter (where result = 'sent' and (at at time zone tz)::date = today), count(*) filter (where result = 'sent' and at > now() - interval '1 hour')
      into used_day, used_hr from email_send_log where org_id = o.org_id and at > now() - interval '2 days';
    select count(*) into busy from email_queue where org_id = o.org_id and status = 'sending';
    room := least((cfg->>'daily_cap')::int - used_day - busy, (cfg->>'per_hour')::int - used_hr - busy, p_max - total, p_platform_left - total);
    continue when room <= 0;
    claimed := 0;
    for q in select * from email_queue where org_id = o.org_id and status = 'queued' and not_before <= now() order by requested_at, id limit 500 for update skip locked loop
      exit when claimed >= room;
      why := null; st := null; g := null; tok := null; nums := null; vars := null;
      if cfg->>'mode' = 'off' then why := 'email_off';
      elsif q.kind = 'receipt' and not (cfg->>'receipts')::boolean then why := 'receipts_off';
      elsif q.kind = 'reminder' and not (cfg#>>'{reminders,enabled}')::boolean then why := 'reminders_off';
      end if;
      if why is null and q.kind in ('invoice', 'late_fee', 'reminder') then
        st := email_invoice_state(q.org_id, q.invoice_id, today);
        if not (st->>'ok')::boolean then why := st->>'reason';
        elsif not (cfg->>'share_link')::boolean then why := 'no_link';
        end if;
      elsif why is null and q.kind = 'receipt' then
        select * into pay from centre_payments where id = q.payment_id and org_id = q.org_id;
        if pay.id is null then why := 'not_found';
        elsif exists (select 1 from centre_payments r where r.reverses_payment_id = pay.id and r.org_id = q.org_id) then why := 'reversed';
        end if;
      end if;
      if why is null then
        select * into g from guardians x where x.id = q.guardian_id and x.org_id = q.org_id;
        why := case when g.id is null then 'no_recipient' when not email_valid(g.email) then 'no_email' when g.email_status = 'bad' then 'bad_address' end;
      end if;
      if why is not null then
        update email_queue set status = case when why in ('no_recipient', 'no_email', 'bad_address') then 'skipped' else 'cancelled' end, reason = why, updated_at = now() where id = q.id;
        insert into email_send_log(org_id, queue_id, kind, invoice_id, guardian_id, to_masked, template, result, detail)
        values (q.org_id, q.id, q.kind, q.invoice_id, q.guardian_id, case when g.id is not null then email_mask(g.email) end, q.kind,
                case when why in ('no_recipient', 'no_email', 'bad_address') then 'skipped' else 'cancelled' end, why);
        continue;
      end if;
      select name into hname from households where id = q.household_id and org_id = q.org_id;
      cname := coalesce(cfg->>'centre_name', centre);
      if q.kind = 'receipt' then
        select string_agg(num, ', ' order by num), count(*) into nums, n_inv from (select distinct i.number_text num from centre_payment_allocations a
          join centre_invoices i on i.id = a.invoice_id and i.org_id = a.org_id where a.payment_id = pay.id and a.org_id = q.org_id limit 3) z;
        vars := jsonb_build_object('number', nums, 'amount_cents', pay.amount_cents, 'paid_on', pay.received_on);
      else
        tok := email_share_token(q.org_id, q.invoice_id, today);
        vars := jsonb_build_object('number', st->>'number', 'amount_cents', (st->>'balance_cents')::bigint, 'total_cents', (st->>'total_cents')::bigint, 'due_date', st->>'due_date',
                  'days_overdue', greatest(today - (st->>'due_date')::date, 0), 'token', tok);
      end if;
      tpl := cfg#>array['templates', q.kind];
      payload := jsonb_build_object('queue_id', q.id, 'org_id', q.org_id, 'kind', q.kind, 'attempt', q.attempts + 1, 'to', trim(g.email), 'name', coalesce(nullif(trim(g.name), ''), hname),
        'centre', cname, 'reply_to', cfg->>'reply_to', 'templates', case when jsonb_typeof(tpl) = 'object' then tpl else '{}'::jsonb end, 'vars', vars);
      update email_queue set status = 'sending', attempts = attempts + 1, updated_at = now() where id = q.id;
      res_list := res_list || payload; claimed := claimed + 1; total := total + 1;
    end loop;
  end loop;
  return res_list;
end $$;

-- The server reports what happened. outcome: sent | retry | failed | invalid | blocked_preview.   Only a message that is 'sending' can be completed (a second report does nothing).
create or replace function public.email_complete(p_queue uuid, p_outcome text, p_detail text default null, p_message_id text default null, p_to text default null, p_delay_minutes int default null)
returns boolean language plpgsql security definer set search_path = public as $$
declare q email_queue; res text; st text; delay int; tpl text; custom boolean := false; cfg jsonb;
begin
  if p_outcome not in ('sent', 'retry', 'failed', 'invalid', 'blocked_preview') then raise exception 'BAD_VALUE: unknown outcome' using errcode = 'P0001'; end if;
  select * into q from email_queue where id = p_queue and status = 'sending' for update;
  if q.id is null then return false; end if;
  cfg := email_org_cfg(q.org_id, coalesce(email_today(q.org_id), current_date));
  custom := coalesce(nullif(trim(cfg#>>array['templates', q.kind, 'subject']), ''), nullif(trim(cfg#>>array['templates', q.kind, 'body']), '')) is not null;
  tpl := q.kind || case when custom then ':custom' else '' end;
  if p_outcome = 'retry' and q.attempts >= 3 then p_outcome := 'failed'; p_detail := coalesce(left(p_detail, 60), 'error'); end if;
  if p_outcome = 'sent' then st := 'sent'; res := 'sent';
  elsif p_outcome = 'blocked_preview' then st := 'skipped'; res := 'blocked_preview'; p_detail := 'preview';
  elsif p_outcome = 'retry' then
    st := 'queued'; res := 'retry';
    delay := coalesce(p_delay_minutes, case q.attempts when 1 then 15 when 2 then 60 else 360 end);
  else
    st := 'failed'; res := 'failed';
    if p_outcome = 'invalid' then
      p_detail := 'invalid_recipient';
      update guardians set email_status = 'bad', email_bad_at = now() where id = q.guardian_id and org_id = q.org_id;
    end if;
  end if;
  update email_queue set status = st, reason = case when st = 'queued' then q.reason else left(coalesce(p_detail, q.reason), 60) end, updated_at = now(),
         not_before = case when st = 'queued' then now() + make_interval(mins => delay) else not_before end where id = q.id;
  insert into email_send_log(org_id, queue_id, kind, invoice_id, guardian_id, to_masked, template, result, detail, attempt, by_user, brevo_message_id)
  values (q.org_id, q.id, q.kind, q.invoice_id, q.guardian_id, email_mask(p_to), tpl, res, left(p_detail, 60), q.attempts, q.requested_by, left(p_message_id, 200));
  return true;
end $$;

-- Brevo tells us an address bounced / was blocked / was reported. Matches the message id; marks the guardian's address bad; adds a 'bounced' line to the log.
-- soft bounces and deferrals are only noted. Unknown ids do nothing.
create or replace function public.email_mark_bounce(p_message_id text, p_kind text) returns boolean
language plpgsql security definer set search_path = public as $$
declare l email_send_log; mid text := regexp_replace(coalesce(p_message_id, ''), '[<>\s]', '', 'g'); bad boolean;
begin
  if length(mid) < 6 then return false; end if;
  select * into l from email_send_log x where x.result = 'sent' and regexp_replace(coalesce(x.brevo_message_id, ''), '[<>\s]', '', 'g') = mid order by x.id desc limit 1;
  if l.id is null then return false; end if;
  bad := p_kind in ('hard_bounce', 'invalid', 'blocked', 'error', 'spam', 'complaint', 'unsubscribed');
  if bad and l.guardian_id is not null then
    update guardians set email_status = 'bad', email_bad_at = now() where id = l.guardian_id and org_id = l.org_id;
  end if;
  insert into email_send_log(org_id, queue_id, kind, invoice_id, guardian_id, to_masked, template, result, detail, brevo_message_id)
  values (l.org_id, l.queue_id, l.kind, l.invoice_id, l.guardian_id, l.to_masked, l.template, 'bounced', left(coalesce(p_kind, 'bounce'), 40), left(p_message_id, 200));
  return true;
end $$;

-- how many emails the platform sent in the last 24 hours (every centre, plus tutor invites): the server keeps this under Brevo's daily limit
create or replace function public.email_platform_sent_24h() returns int
language sql stable security definer set search_path = public as $$
  select ((select count(*) from email_send_log where result = 'sent' and at > now() - interval '24 hours')
        + (select count(*) from org_invite_mail_log where status = 'sent' and sent_at > now() - interval '24 hours'))::int
$$;

-- ---------------------------------------------------------------------------------------------------
-- 9. who may call what
-- ---------------------------------------------------------------------------------------------------
do $$
declare f text;
begin
  -- internal helpers and trigger functions: nobody from a browser
  foreach f in array array['email_valid(text)', 'email_mask(text)', 'email_cfg(jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
  foreach f in array array['email_org_cfg(uuid,date)', 'email_today(uuid)', 'email_invoice_state(uuid,uuid,date)', 'email_share_token(uuid,uuid,date)',
    'email_enqueue_rows(uuid,text,uuid,uuid,uuid,uuid,boolean,int)', 'email_on_invoice_issued()', 'email_on_payment()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  -- staff screens (each function starts with the gate)
  foreach f in array array['email_queue_status(uuid)', 'email_enqueue(uuid,uuid[],boolean)', 'email_enqueue_unsent(uuid,date)', 'email_queue_list(uuid,text,int,int)',
    'email_queue_cancel(uuid,uuid[])', 'email_log_list(uuid,int,bigint)', 'email_household_contacts(uuid,uuid)', 'email_set_billing_contacts(uuid,uuid,uuid[])',
    'email_clear_bad(uuid,uuid)', 'email_bad_list(uuid)', 'email_reminder_preview(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
  -- the server only
  foreach f in array array['email_plan_reminders(uuid,boolean)', 'email_claim(uuid,int,int)', 'email_complete(uuid,text,text,text,text,int)', 'email_mark_bounce(text,text)',
    'email_platform_sent_24h()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
