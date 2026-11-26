-- Undo of migration_tutor_moves.sql (T6 step 2): the three tutor functions, the staff list, the new columns, and the previous validator and tutor_my_schedule.
-- Lessons a tutor moved keep their new date (that is real data); only the "changed by tutor" marks go. Audit rows stay (append-only).
drop function if exists public.tutor_postpone_lesson(uuid, date, time, text);
drop function if exists public.tutor_revert_lesson(uuid, text);
drop function if exists public.tutor_cancel_lesson(uuid, text);
drop function if exists public.staff_tutor_changes(uuid);
drop function if exists public.tutor_change_apply(uuid, text, date, time, text);
drop function if exists public.tutor_change_block(uuid, text);

-- the T6.1 read-only tutor_my_schedule
drop function if exists public.tutor_my_schedule(date, date);
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
                                      'timetable_editing', coalesce(org_settings_on(o.id, current_date) #>> '{lessons,timetable_editing}', 'admin_only'),
                                      'can_edit', false) order by o.trading_name, o.id),
         min((now() at time zone o.timezone)::date)
    into orgs, today
    from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
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
                        and l.lesson_date between h.starts_on and h.ends_on order by h.starts_on, h.name limit 1)
         ) order by l.lesson_date, l.start_time, s.name, l.id), '[]'::jsonb)
    into lessons
    from lessons l
    join memberships m on m.id = l.taught_by and m.org_id = l.org_id and m.user_id = auth.uid() and m.role = 'tutor' and m.status = 'active'
    join organisations o on o.id = l.org_id and o.kind = 'centre'
    join students s on s.id = l.student_id and s.org_id = l.org_id
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

do $$
declare f text;
begin
  foreach f in array array['tutor_my_schedule(date,date)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- the validator as migration_money_settings.sql left it
create or replace function public.org_validate_settings(s jsonb) returns void language plpgsql immutable set search_path = public as $$
declare k text; v jsonb; r record;
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
end $$;

drop index if exists public.lessons_changed_by_tutor;
alter table public.lessons drop constraint if exists lessons_changed_by_tutor_same_org;
alter table public.lessons drop constraint if exists lessons_changed_by_tutor_what_ok;
alter table public.lessons drop column if exists changed_by_tutor_at;
alter table public.lessons drop column if exists changed_by_tutor;
alter table public.lessons drop column if exists changed_by_tutor_what;
alter table public.lessons drop column if exists changed_by_tutor_reason;
alter table public.lessons drop column if exists changed_from_date;
alter table public.lessons drop column if exists changed_from_start;
