-- =====================================================================================================
-- T6 step 2 — tutors MOVE, REVERT and CANCEL their own lessons (centre option)             undo: migration_tutor_moves_down.sql
-- =====================================================================================================
-- Needs migration_tutor_schedule.sql (T6.1) and, through it, staff_reassign (lesson_locked_reason), staff_slots (student_tutors, recurring_slots.taught_by),
-- staff_attendance (staff_attendance_gate) and money_settings (the settings validator this file replaces). Run on the DEV project first. Safe to run twice.
--
-- THE CENTRE'S CHOICE (owner decisions 2026-11-26, T6 plan sections 1-2). All read as of the centre's TODAY (a process rule), saved under settings.lessons:
--   timetable_editing        admin_only (default, nothing changes) | tutors_direct (BUILT here) | tutors_propose (still "soon": a tutor gets NOT_ALLOWED)
--                            (the old unbuilt key tutors_own is renamed tutors_direct; no saved setting could hold it)
--   tutors_edit.postpone     yes (default) = a tutor may move a lesson and put it back          BUILT
--   tutors_edit.cancel       no  (default) = a tutor may cancel one of their lessons in advance  BUILT
--   tutors_edit.weekly_slots / generate / one_off / link     still "soon" (T6 steps 3-5); validated here so a later step needs no new validator
--   min_notice_hours         0-168, default 24: nothing changes closer than this to its start
--   max_changes_per_month    0-500, default 0 (= no limit): per tutor, per centre month; a move, a revert and a cancel each count as one change
--   notify_family            off | list_for_admin (default): staff see "tell the family" on the Home list. Sending emails is T7, still soon.
--
-- WHAT A TUTOR CAN DO (functions only; tutors still have NO table access, no policy is added anywhere):
--   tutor_postpone_lesson(lesson, date, start, reason)   move one lesson (or its whole class) to another day / start time. THE LENGTH STAYS THE SAME,
--                                                        so the lesson's price never changes and the tutor never touches money. Marks it postponed and
--                                                        keeps slot_date, exactly like the solo Calendar, so no "not logged" lesson appears at the old slot.
--   tutor_revert_lesson(lesson, reason)                  put a moved lesson back to its usual slot (the slot's weekday and time in the lesson's week)
--   tutor_cancel_lesson(lesson, reason)                  cancel in advance with NO CHARGE to the family: status cancelled, charge 0 (= "not charged"; staff
--                                                        may change it later). No make-up credit is created. Staff see an amber "changed by tutor" flag.
--
-- THE RULES (the tutor's function checks them in this order; every refusal says why in plain words, the code before the colon is for the screen):
--   NOT_FOUND       not a lesson of yours, not a student assigned to you, a solo organisation, a parent, a switched-off tutor, an unknown id: all the SAME word,
--                   so ids can't be probed (same as tutor_mark_attendance)
--   NOT_ALLOWED     the centre's setting is admin_only (or tutors_propose, not built yet)
--   SWITCH_OFF      the centre has not switched on this kind of change
--   ALREADY_MARKED / CANCELLED / LOCKED   the lesson is marked, cancelled, or closed by the centre (paid or on a current invoice: ONE word, so a tutor is never
--                   told which; staff keep their own screens for those)
--   NOT_MOVED       revert on a lesson that is at its usual time; NO_SLOT / SLOT_CHANGED: the usual slot is gone or changed (ask an admin)
--   PAST            the lesson has started or is over; TOO_LATE: closer to its start than min_notice_hours
--   LIMIT           max_changes_per_month reached
--   REASON_REQUIRED a reason (3-300 characters) is kept on record with every change
--   BAD_DATE / BAD_TIME / HOLIDAY / CLASH / NO_CHANGE   the NEW time must be in the future, within a year, inside one day, not on a centre holiday,
--                   not overlapping another of YOUR lessons, and not the time it already has (so pressing twice changes nothing twice)
--   GROUP_NOT_YOURS a class (lessons sharing a session_id) moves or cancels together, all or nothing; every lesson of it must be yours and assigned to you
-- Days and times are the centre's own (organisations.timezone), never the server's.
--
-- WHAT IS KEPT: lessons.changed_by_tutor_at / changed_by_tutor (membership) / changed_by_tutor_what (moved | reverted | cancelled) / changed_by_tutor_reason,
-- changed_from_date / changed_from_start (what it was before); one audit_log row per action (action tutor_postpone_lesson | tutor_revert_lesson |
-- tutor_cancel_lesson, with the reason); the lessons table's own audit trigger logs the row change as well. The monthly limit counts those audit rows.
--
-- STAFF SIDE: staff_tutor_changes(org) lists the last 7 days of tutor changes (needs manage_timetable): the amber "changed by tutor" chips on the
-- Timetable and the "Tutor changes" list on Home. No money in it.
-- NO MONEY anywhere a tutor can read: no returned type or key holds rate, amount, paid, compensation or *_cents (tests/sql/tutor_moves_test.sql).
-- The Supabase API refuses a DELETE / UPDATE without WHERE (pg-safeupdate): every statement below has one.
-- =====================================================================================================

-- ---------------------------------------------------------------- 1. the columns
alter table public.lessons add column if not exists changed_by_tutor_at     timestamptz;
alter table public.lessons add column if not exists changed_by_tutor        uuid;
alter table public.lessons add column if not exists changed_by_tutor_what   text;
alter table public.lessons add column if not exists changed_by_tutor_reason text;
alter table public.lessons add column if not exists changed_from_date       date;
alter table public.lessons add column if not exists changed_from_start      time;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'lessons_changed_by_tutor_what_ok') then
    alter table public.lessons add constraint lessons_changed_by_tutor_what_ok check (changed_by_tutor_what is null or changed_by_tutor_what in ('moved', 'reverted', 'cancelled'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'lessons_changed_by_tutor_same_org') then
    alter table public.lessons add constraint lessons_changed_by_tutor_same_org
      foreign key (changed_by_tutor, org_id) references public.memberships(id, org_id) on delete set null (changed_by_tutor);
  end if;
end $$;
create index if not exists lessons_changed_by_tutor on public.lessons(org_id, changed_by_tutor_at desc) where changed_by_tutor_at is not null;

-- ---------------------------------------------------------------- 2. the settings validator (money_settings' version, plus the new keys)
-- Every earlier check is kept word for word; the new block is at the end. Settings saved before this still pass (every new key is optional).
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
end $$;

-- ---------------------------------------------------------------- 3. the one rulebook: why a lesson can't be changed by ITS tutor (null = it can)
-- Internal (the browser can't call it); the three tutor functions and tutor_my_schedule all ask it, so the screen's buttons and the database always agree.
-- p_what: 'postpone' | 'revert' | 'cancel'. Looks at auth.uid() itself. The first word is the code; 'NOT_FOUND' alone = not yours / not assigned / not a centre / unknown.
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
    select count(*) into used from audit_log a
     where a.org_id = l.org_id and a.actor = me and a.action in ('tutor_postpone_lesson', 'tutor_revert_lesson', 'tutor_cancel_lesson')
       and a.at >= date_trunc('month', now() at time zone tz) at time zone tz;
    if used >= mx then
      return 'LIMIT: you have used your ' || mx || ' schedule change' || case when mx = 1 then '' else 's' end || ' for this month. Ask an admin'; end if;
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------- 4. the one worker behind the three tutor functions
-- p_what: 'postpone' | 'revert' | 'cancel'. A class (lessons sharing a session_id) is one action, all or nothing. Internal.
create or replace function public.tutor_change_apply(p_lesson uuid, p_what text, p_date date, p_start time, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); l lessons; x lessons; tz text; today date; why text := nullif(trim(coalesce(p_reason, '')), ''); blk text;
        ids uuid[]; sid uuid; sl recurring_slots; nd date; ns time; ne time; hol text; clash text; before_j jsonb := '[]'::jsonb; after_j jsonb := '[]'::jsonb;
        grp boolean; what_done text := case p_what when 'postpone' then 'moved' when 'revert' then 'reverted' else 'cancelled' end;
begin
  if me is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into l from lessons where id = p_lesson;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  blk := tutor_change_block(l.id, p_what);
  if blk is not null then
    if blk = 'NOT_FOUND' then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    raise exception '%', blk using errcode = 'P0001';
  end if;
  select o.timezone into tz from organisations o where o.id = l.org_id;
  today := (now() at time zone tz)::date;
  if why is null or length(why) < 3 then raise exception 'REASON_REQUIRED: say why (a few words). It is kept on record for the centre' using errcode = 'P0001'; end if;
  if length(why) > 300 then raise exception 'TOO_LONG: keep the reason under 300 characters' using errcode = 'P0001'; end if;
  if p_what = 'postpone' then
    if p_date is null or p_start is null then raise exception 'BAD_DATE: pick a date and a start time' using errcode = 'P0001'; end if;
    if p_date > today + 365 then raise exception 'BAD_DATE: pick a date within the next year' using errcode = 'P0001'; end if;
  end if;

  -- the lesson, or its whole class (same session_id): all or nothing, every one of them must be the caller's own
  select coalesce(array_agg(y.id order by y.id), array[l.id]) into ids from lessons y
   where y.org_id = l.org_id and (y.id = l.id or (l.session_id is not null and y.session_id = l.session_id));
  grp := array_length(ids, 1) > 1;
  perform 1 from lessons y where y.id = any(ids) order by y.id for update;
  foreach sid in array ids loop
    if sid <> l.id then
      blk := tutor_change_block(sid, p_what);
      if blk = 'NOT_FOUND' then
        raise exception 'GROUP_NOT_YOURS: this lesson is part of a class that includes lessons that aren''t yours. Ask an admin' using errcode = 'P0001'; end if;
      if blk is not null then raise exception '% (it is part of a class that changes together)', blk using errcode = 'P0001'; end if;
    end if;
  end loop;

  for x in select * from lessons y where y.id = any(ids) order by y.id loop
    before_j := before_j || jsonb_build_object('lesson_id', x.id, 'lesson_date', x.lesson_date, 'start_time', x.start_time, 'end_time', x.end_time,
                                                'postponed', x.postponed, 'status', x.status);
    if p_what = 'cancel' then
      update lessons set status = 'cancelled', compensation = 0, changed_by_tutor_at = now(), changed_by_tutor = x.taught_by,
             changed_by_tutor_what = 'cancelled', changed_by_tutor_reason = why, changed_from_date = x.lesson_date, changed_from_start = x.start_time
       where id = x.id;
    else
      if p_what = 'postpone' then
        nd := p_date; ns := p_start;
      else
        select * into sl from recurring_slots z where z.id = x.slot_id and z.org_id = x.org_id;
        nd := x.slot_date + (sl.weekday - (extract(isodow from x.slot_date)::int - 1)); ns := sl.start_time;     -- the slot's own day, in the week of the occurrence
      end if;
      if ((nd + ns) + (x.end_time - x.start_time))::date <> nd then
        raise exception 'BAD_TIME: the lesson would run past midnight. Pick an earlier start' using errcode = 'P0001'; end if;
      ne := ns + (x.end_time - x.start_time);
      if nd = x.lesson_date and ns = x.start_time then
        raise exception 'NO_CHANGE: the lesson is already at that time' using errcode = 'P0001'; end if;
      if ((nd + ns) at time zone tz) <= now() then
        raise exception 'BAD_DATE: that time has already passed. Pick a later one' using errcode = 'P0001'; end if;
      select h.name into hol from holidays h where h.org_id = x.org_id and h.branch_id is null and nd between h.starts_on and h.ends_on order by h.starts_on, h.name limit 1;
      if hol is not null then raise exception 'HOLIDAY: % is a holiday at this centre. Pick another day', hol using errcode = 'P0001'; end if;
      select s.name into clash from lessons y join students s on s.id = y.student_id and s.org_id = y.org_id
       where y.org_id = x.org_id and y.taught_by = x.taught_by and not (y.id = any(ids)) and y.status <> 'cancelled'
         and y.lesson_date = nd and y.start_time < ne and y.end_time > ns order by y.start_time, y.id limit 1;
      if clash is not null then raise exception 'CLASH: you already teach % at that time. Pick another time', clash using errcode = 'P0001'; end if;
      update lessons set lesson_date = nd, start_time = ns, end_time = ne, postponed = (p_what = 'postpone'),
             changed_by_tutor_at = now(), changed_by_tutor = x.taught_by, changed_by_tutor_what = what_done, changed_by_tutor_reason = why,
             changed_from_date = x.lesson_date, changed_from_start = x.start_time
       where id = x.id;
    end if;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('lesson_id', y.id, 'lesson_date', y.lesson_date, 'start_time', y.start_time, 'end_time', y.end_time,
                                               'postponed', y.postponed, 'status', y.status) order by y.id), '[]'::jsonb) into after_j from lessons y where y.id = any(ids);
  insert into audit_log(org_id, actor, action, table_name, row_id, before, after)
  values (l.org_id, me, 'tutor_' || p_what || '_lesson', 'lessons', l.id::text, jsonb_build_object('lessons', before_j),
          jsonb_build_object('lessons', after_j, 'reason', why, 'what', what_done));
  select * into x from lessons where id = l.id;
  return jsonb_build_object('lesson_id', l.id, 'lessons', array_length(ids, 1), 'what', what_done, 'lesson_date', x.lesson_date,
                            'start_time', x.start_time, 'end_time', x.end_time, 'cancelled', (x.status = 'cancelled'));
end $$;

-- ---------------------------------------------------------------- 5. the three functions a tutor calls
create or replace function public.tutor_postpone_lesson(p_lesson uuid, p_date date, p_start time, p_reason text default null) returns jsonb
language sql security definer set search_path = public as $$ select public.tutor_change_apply(p_lesson, 'postpone', p_date, p_start, p_reason) $$;
create or replace function public.tutor_revert_lesson(p_lesson uuid, p_reason text default null) returns jsonb
language sql security definer set search_path = public as $$ select public.tutor_change_apply(p_lesson, 'revert', null, null, p_reason) $$;
create or replace function public.tutor_cancel_lesson(p_lesson uuid, p_reason text default null) returns jsonb
language sql security definer set search_path = public as $$ select public.tutor_change_apply(p_lesson, 'cancel', null, null, p_reason) $$;

-- ---------------------------------------------------------------- 6. tutor_my_schedule, now with the buttons a lesson may show
-- Same answer as T6.1 plus, per lesson: can_postpone, can_revert, can_cancel (yes/no, from the same rulebook the functions use) and change_block (the
-- code of the reason a button is missing when the centre HAS switched it on, e.g. TOO_LATE; null otherwise); per centre: editing (the setting),
-- can_postpone / can_cancel (the centre's switches), min_notice_hours, max_changes_per_month and changes_left (null = no limit). No money.
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
                                      'timetable_editing', c.mode,
                                      'can_edit', (c.mode = 'tutors_direct' and (c.sw_postpone or c.sw_cancel)),
                                      'can_postpone', (c.mode = 'tutors_direct' and c.sw_postpone), 'can_cancel', (c.mode = 'tutors_direct' and c.sw_cancel),
                                      'min_notice_hours', c.notice, 'max_changes_per_month', c.mx,
                                      'changes_left', case when c.mx > 0 and c.mode = 'tutors_direct' then greatest(0, c.mx - (
                                          select count(*) from audit_log a where a.org_id = o.id and a.actor = auth.uid()
                                             and a.action in ('tutor_postpone_lesson', 'tutor_revert_lesson', 'tutor_cancel_lesson')
                                             and a.at >= date_trunc('month', now() at time zone o.timezone) at time zone o.timezone)) end)
                      order by o.trading_name, o.id),
         min((now() at time zone o.timezone)::date)
    into orgs, today
    from memberships m join organisations o on o.id = m.org_id and o.kind = 'centre'
    cross join lateral (select org_settings_on(o.id, (now() at time zone o.timezone)::date) as s) cfg
    cross join lateral (select coalesce(cfg.s #>> '{lessons,timetable_editing}', 'admin_only') as mode,
                               coalesce((cfg.s #>> '{lessons,tutors_edit,postpone}')::boolean, true) as sw_postpone,
                               coalesce((cfg.s #>> '{lessons,tutors_edit,cancel}')::boolean, false) as sw_cancel,
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
           'changed_by_you', (l.changed_by_tutor_what), 'class_size', (select count(*)::int from lessons y where l.session_id is not null and y.org_id = l.org_id and y.session_id = l.session_id)
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

-- ---------------------------------------------------------------- 7. staff: what tutors changed in the last 7 days
-- Needs manage_timetable (NOT_FOUND for strangers, tutors, parents, solo organisations; NOT_ALLOWED for staff without that permission).
-- One row per lesson, newest first, at most 100. NO MONEY. `tell_family` = the centre's notify_family is list_for_admin.
create or replace function public.staff_tutor_changes(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare today date := staff_attendance_gate(p_org, false); rows jsonb; tell boolean;
begin
  if not org_can(p_org, 'manage_timetable') then
    raise exception 'NOT_ALLOWED: your account can''t see timetable changes at this centre' using errcode = '42501'; end if;
  tell := coalesce(org_settings_on(p_org, today) #>> '{lessons,notify_family}', 'list_for_admin') = 'list_for_admin';
  select coalesce(jsonb_agg(jsonb_build_object(
           'lesson_id', x.id, 'what', x.changed_by_tutor_what, 'changed_at', x.changed_by_tutor_at, 'reason', x.changed_by_tutor_reason,
           'tutor_id', x.changed_by_tutor,
           'tutor_name', case when t.id is null or t.status = 'disabled' then 'Former tutor' else coalesce(t.display_name, 'Tutor') end,
           'student_id', s.id, 'student_name', s.name, 'subject', x.subject,
           'lesson_date', x.lesson_date, 'start_time', x.start_time, 'end_time', x.end_time,
           'from_date', x.changed_from_date, 'from_start', x.changed_from_start, 'cancelled', (x.status = 'cancelled'), 'tell_family', tell)
           order by x.changed_by_tutor_at desc, x.id), '[]'::jsonb)
    into rows
    from (select * from lessons y where y.org_id = p_org and y.changed_by_tutor_at >= now() - interval '7 days'
           order by y.changed_by_tutor_at desc, y.id limit 100) x
    join students s on s.id = x.student_id and s.org_id = x.org_id
    left join memberships t on t.id = x.changed_by_tutor and t.org_id = x.org_id;
  return jsonb_build_object('today', today, 'days', 7, 'tell_family', tell, 'rows', rows);
end $$;

-- ---------------------------------------------------------------- who may call what
do $$
declare f text;
begin
  foreach f in array array['tutor_postpone_lesson(uuid,date,time,text)', 'tutor_revert_lesson(uuid,text)', 'tutor_cancel_lesson(uuid,text)',
                           'tutor_my_schedule(date,date)', 'staff_tutor_changes(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['tutor_change_block(uuid,text)', 'tutor_change_apply(uuid,text,date,time,text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;
