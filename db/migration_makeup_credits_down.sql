-- =====================================================================================================
-- UNDO for migration_makeup_credits.sql (T18 step 4). Safe to run twice. Every credit, event and make-up link is removed; the make-up LESSONS themselves stay
-- as ordinary one-off lessons (a free one keeps its amount of 0 and, with the flag gone, would be billed at rate x hours: remove or price them first if any exist).
-- Restores the settings validator and the invoice run to the versions before this migration.
-- =====================================================================================================
drop trigger if exists lessons_credit_after on public.lessons;
drop trigger if exists lessons_credit_before_delete on public.lessons;
drop trigger if exists lessons_makeup_guard on public.lessons;
drop function if exists public.lessons_credit_after();
drop function if exists public.lessons_credit_before_delete();
drop function if exists public.lessons_makeup_guard();
drop function if exists public.staff_credit_list(uuid, text, uuid, int, int);
drop function if exists public.staff_grant_credit(uuid, uuid, text, uuid);
drop function if exists public.staff_revoke_credit(uuid, text);
drop function if exists public.staff_book_makeup(uuid, date, time, time, uuid);
drop function if exists public.staff_unbook_makeup(uuid, text);
drop function if exists public.credits_expire_due(date);
drop function if exists public.credit_gate(uuid, text);
drop function if exists public.credit_consider(lessons);
drop function if exists public.credit_move(uuid, text, text, text, uuid, text);
drop function if exists public.credit_event(uuid, text, uuid, text);
drop function if exists public.credit_cfg(uuid, date);
alter table public.lessons drop constraint if exists lessons_makeup_credit_same_org;
alter table public.lessons drop constraint if exists lessons_makeup_billing_ok;
drop index if exists public.lessons_one_per_credit;
alter table public.lessons drop column if exists makeup_credit_id;
alter table public.lessons drop column if exists makeup_billing;
drop table if exists public.makeup_credit_events;
drop table if exists public.makeup_credits;
drop function if exists public.makeup_credits_guard();
drop function if exists public.makeup_credit_events_guard();

-- the settings validator as tutor_moves left it
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
end $$;

-- the invoice run as centre_invoice_run left it
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
           l.status as lstatus, l.attendance as att, l.trial as is_trial, l.compensation_cents as comp, l.price_pending as ppend,
           lesson_price_cents(l.amount, l.rate, l.start_time, l.end_time) as price
      from lessons l
     where l.org_id = p_org and l.lesson_date between ms and me
       and not exists (select 1 from centre_invoice_lines cl join centre_invoices ci on ci.id = cl.invoice_id and ci.org_id = cl.org_id
                        where cl.lesson_id = l.id and cl.org_id = p_org and ci.status <> 'void')
  ), cls as (
    select b.*,
      case
        when b.is_trial and not v_trials then 'free_trial'
        when b.ppend and b.lstatus <> 'cancelled' then 'pending'             -- T6 step 3: a tutor-made lesson whose price the centre has not confirmed yet
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
