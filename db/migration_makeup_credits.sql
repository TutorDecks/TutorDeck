-- =====================================================================================================
-- T18 step 4 — MAKE-UP CREDITS for centres                                              undo: migration_makeup_credits_down.sql
-- =====================================================================================================
-- Needs everything before it, in this order: ... slot_changes (lesson_change_blocker, holidays, staff_holiday_cancel), tutor_moves (the settings
-- validator this file replaces, tutor_cancel_lesson). Run it LAST of the current migrations. Safe to run twice. DEV first; LIVE only when the code ships.
--
-- THE RULE (owner decisions, T18, 2026-11-24..27): ONE MISSED LESSON = ONE CREDIT, and a make-up lesson is NEVER charged twice.
--   A credit is earned when a centre lesson is missed in a way the centre has chosen to credit. It is spent by BOOKING a make-up lesson (an ordinary
--   one-off lesson linked to the credit) and used up when somebody MARKS ATTENDANCE on that make-up. Taking the make-up away (unbook) gives the credit back.
--   Solo tutors are untouched: every function below refuses a solo organisation, and the triggers do nothing for one.
--
-- THE CENTRE'S CHOICES (saved under settings.billing; read as of the centre's TODAY, they are process rules; the price rule is frozen on the lesson):
--   billing.credits.rule              none (default when the key is missing: nothing changes for a centre that saved settings before) | one_per_missed
--   billing.credits.earn_absences     notice_only (default: marked "cancelled in time") | notice_and_late (+ late cancelled) | all_missed (+ absent) | none
--   billing.credits.earn_tutor_cancel staff_decide (default: a tutor's own cancel earns NOTHING, staff grant one if they decide) | automatic
--   billing.credits.earn_holiday      false (default) | true: a lesson cancelled for a whole-centre holiday (staff_holiday_cancel) earns a credit
--   billing.credit_expiry_days        0 = never (default) .. 3650. Fixed on the credit the day it is earned: expires_on = earned_on + days, usable THROUGH that day
--   billing.credits.grant_by          manage_timetable (default) | owner: who may grant and revoke a credit by hand
--   billing.credits.book_by           manage_timetable (default) | owner: who may book and unbook the make-up lesson
--   billing.credits.makeup_price      free (default) | if_missed_not_charged
--        free                         the make-up is never billed (the missed lesson was billed or waived already)
--        if_missed_not_charged        the make-up is billed at its normal price ONLY when the missed lesson was NOT charged (compensation 0); when the
--                                     missed lesson was charged, the make-up is free: the family never pays twice. A credit with no missed lesson (a
--                                     manual grant) books at the normal price. Booking is refused (CHARGE_PENDING) while the missed lesson's charge is still untyped.
--   Tutors never see credits or money: no tutor function is added or changed and tutors have no table access.
--
-- WHAT IS KEPT (tables are read ONLY through the functions below: row-level security is on with no policy, and browsers have no table privileges)
--   makeup_credits         one row per credit: who, why (source: absence | tutor_cancel | holiday | manual), the missed lesson, earned_on, expires_on,
--                          status open | booked | used | expired | revoked. Only `status` ever changes, only by the functions here; never deleted
--                          (except while a whole organisation is removed). ONE credit per missed lesson, ever (unique index): marking twice earns once.
--   makeup_credit_events   append-only history: earned, booked, returned, used, expired, revoked (who, when, which lesson, why). A superset of the owner's
--                          five (earned, used, returned, expired, revoked): `booked` records the link, `used` the attendance mark. Simple columns, ready to export.
--   lessons.makeup_credit_id / makeup_billing   the make-up lesson's link to its credit (one credit, one lesson: unique) and how it is billed (free | normal).
--                          Written only by the functions here (a trigger refuses anyone else), so nobody can mark a normal lesson "free" to dodge billing.
--   audit_log              one row per grant, revoke, book, unbook, earn, use and expiry.
--
-- INVOICING: centre_invoice_run_rows is replaced (the same function, one added line): a lesson with makeup_billing = 'free' is never put on an invoice.
--   (lesson_price_cents treats amount 0 as "not set" and falls back to rate x hours, so a free make-up can't rely on a zero amount: it is skipped by flag.)
--
-- WHO MAY CALL (same words as the other staff screens): an active OWNER or STAFF member of this centre may LOOK; GRANT / REVOKE and BOOK / UNBOOK need
--   manage_timetable (owners always) or the owner only, per the two settings above. A tutor / parent / switched-off staff / stranger / solo organisation /
--   unknown id all get the same NOT_FOUND, so ids can't be probed. The Supabase API refuses a DELETE or UPDATE with no WHERE: every statement here has one.
-- =====================================================================================================

-- ---------------------------------------------------------------- 1. the two tables
create table if not exists public.makeup_credits (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references public.organisations(id) on delete cascade,
  student_id       uuid not null,
  source           text not null check (source in ('absence', 'tutor_cancel', 'holiday', 'manual')),
  source_lesson_id uuid,
  reason           text check (reason is null or char_length(reason) between 3 and 300),
  earned_on        date not null,
  expires_on       date,
  status           text not null default 'open' check (status in ('open', 'booked', 'used', 'expired', 'revoked')),
  created_by       uuid,
  created_at       timestamptz not null default now(),
  constraint makeup_credits_student_same_org foreign key (student_id, org_id) references public.students(id, org_id),
  constraint makeup_credits_lesson_same_org  foreign key (source_lesson_id, org_id) references public.lessons(id, org_id) on delete set null (source_lesson_id),
  constraint makeup_credits_manual_has_reason check (source <> 'manual' or reason is not null),
  constraint makeup_credits_expiry_after_earned check (expires_on is null or expires_on >= earned_on)
);
create unique index if not exists makeup_credits_one_per_lesson on public.makeup_credits(source_lesson_id) where source_lesson_id is not null;
create index if not exists makeup_credits_org_status on public.makeup_credits(org_id, status, earned_on);
create index if not exists makeup_credits_student on public.makeup_credits(org_id, student_id, status);
create index if not exists makeup_credits_expiry on public.makeup_credits(expires_on) where status = 'open' and expires_on is not null;
create unique index if not exists makeup_credits_id_org on public.makeup_credits(id, org_id);

create table if not exists public.makeup_credit_events (
  id        bigint generated always as identity primary key,
  org_id    uuid not null references public.organisations(id) on delete cascade,
  credit_id uuid not null references public.makeup_credits(id) on delete cascade,
  kind      text not null check (kind in ('earned', 'booked', 'returned', 'used', 'expired', 'revoked')),
  lesson_id uuid,                                  -- the make-up lesson for booked / returned / used (no foreign key: the lesson may be deleted later)
  actor     uuid,                                  -- null = the system (expiry job)
  reason    text,
  at        timestamptz not null default now()
);
create index if not exists makeup_credit_events_credit on public.makeup_credit_events(credit_id, at);
create index if not exists makeup_credit_events_org on public.makeup_credit_events(org_id, at desc);

-- nobody reaches the tables from a browser: row-level security on with no policy, and no table privileges for the browser roles
alter table public.makeup_credits enable row level security;
alter table public.makeup_credit_events enable row level security;
revoke all on public.makeup_credits from public, anon, authenticated;
revoke all on public.makeup_credit_events from public, anon, authenticated;

-- append-only. A credit's ONLY change is `status`, and only while a function of this file holds the flag td.credit_write; the other allowed change is the
-- foreign key emptying source_lesson_id when the missed lesson itself is deleted. Deletes only while a whole organisation is being removed (td.deleting_org).
create or replace function public.makeup_credits_guard() returns trigger language plpgsql set search_path = public as $$
declare gate text := coalesce(current_setting('td.deleting_org', true), '');
begin
  if tg_op = 'DELETE' then
    if gate <> '' and gate = old.org_id::text and current_user not in ('anon', 'authenticated', 'service_role') then return old; end if;
    raise exception 'makeup_credits is append-only';
  end if;
  if coalesce(current_setting('td.credit_write', true), '') = 'on'
     and (to_jsonb(new) - 'status') = (to_jsonb(old) - 'status') then return new; end if;
  if old.source_lesson_id is not null and new.source_lesson_id is null
     and (to_jsonb(new) - 'source_lesson_id') = (to_jsonb(old) - 'source_lesson_id') then return new; end if;
  raise exception 'makeup_credits is append-only';
end $$;
drop trigger if exists makeup_credits_immutable on public.makeup_credits;
create trigger makeup_credits_immutable before update or delete on public.makeup_credits for each row execute function public.makeup_credits_guard();

create or replace function public.makeup_credit_events_guard() returns trigger language plpgsql set search_path = public as $$
declare gate text := coalesce(current_setting('td.deleting_org', true), '');
begin
  if tg_op = 'DELETE' and gate <> '' and gate = old.org_id::text and current_user not in ('anon', 'authenticated', 'service_role') then return old; end if;
  raise exception 'makeup_credit_events is append-only';
end $$;
drop trigger if exists makeup_credit_events_immutable on public.makeup_credit_events;
create trigger makeup_credit_events_immutable before update or delete on public.makeup_credit_events for each row execute function public.makeup_credit_events_guard();

-- ---------------------------------------------------------------- 2. the make-up lesson's link (on lessons)
alter table public.lessons add column if not exists makeup_credit_id uuid;
alter table public.lessons add column if not exists makeup_billing   text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'lessons_makeup_billing_ok') then
    alter table public.lessons add constraint lessons_makeup_billing_ok check (makeup_billing is null or makeup_billing in ('free', 'normal'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'lessons_makeup_credit_same_org') then
    alter table public.lessons add constraint lessons_makeup_credit_same_org
      foreign key (makeup_credit_id, org_id) references public.makeup_credits(id, org_id) on delete set null (makeup_credit_id);
  end if;
end $$;
create unique index if not exists lessons_one_per_credit on public.lessons(makeup_credit_id) where makeup_credit_id is not null;

-- only the functions of this file may set, change or clear the link or the billing flag (a person with table access could otherwise tag a normal lesson
-- "free" to dodge billing, or untag a make-up to bill it twice, or point it at somebody else's credit)
create or replace function public.lessons_makeup_guard() returns trigger language plpgsql set search_path = public as $$
declare gate text := coalesce(current_setting('td.deleting_org', true), '');
begin
  if coalesce(current_setting('td.credit_write', true), '') = 'on' then return new; end if;
  if gate <> '' and gate = new.org_id::text and current_user not in ('anon', 'authenticated', 'service_role') then return new; end if;
  if tg_op = 'INSERT' then
    if new.makeup_credit_id is not null or new.makeup_billing is not null then
      raise exception 'LOCKED: a make-up lesson is made by booking a credit' using errcode = 'P0001'; end if;
    return new;
  end if;
  if new.makeup_credit_id is distinct from old.makeup_credit_id or new.makeup_billing is distinct from old.makeup_billing then
    raise exception 'LOCKED: a make-up lesson''s credit link can''t be edited by hand' using errcode = 'P0001'; end if;
  return new;
end $$;
drop trigger if exists lessons_makeup_guard on public.lessons;
create trigger lessons_makeup_guard before insert or update of makeup_credit_id, makeup_billing on public.lessons for each row execute function public.lessons_makeup_guard();

-- ---------------------------------------------------------------- 3. the settings validator (tutor_moves' version, plus the new keys at the end)
-- Every earlier check is kept word for word. Settings saved before this still pass (every new key is optional).
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

-- ---------------------------------------------------------------- 3b. the invoice run (centre_invoice_run_rows, one added line: a free make-up is never billed)
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
       and l.makeup_billing is distinct from 'free'            -- T18-4: a make-up booked free is never billed (its missed lesson was already billed, or waived by the centre's choice)
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

-- ---------------------------------------------------------------- 4. internal helpers (no browser role may call these)
-- the centre's own settings as of today, with the credit keys read once
create or replace function public.credit_cfg(p_org uuid, p_today date) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'rule',              coalesce(s #>> '{billing,credits,rule}', 'none'),
    'earn_absences',     coalesce(s #>> '{billing,credits,earn_absences}', 'notice_only'),
    'earn_tutor_cancel', coalesce(s #>> '{billing,credits,earn_tutor_cancel}', 'staff_decide'),
    'earn_holiday',      coalesce((s #>> '{billing,credits,earn_holiday}')::boolean, false),
    'grant_by',          coalesce(s #>> '{billing,credits,grant_by}', 'manage_timetable'),
    'book_by',           coalesce(s #>> '{billing,credits,book_by}', 'manage_timetable'),
    'makeup_price',      coalesce(s #>> '{billing,credits,makeup_price}', 'free'),
    'expiry_days',       coalesce(nullif(s #>> '{billing,credit_expiry_days}', '')::int, 0))
    from (select org_settings_on(p_org, p_today) as s) x $$;

-- the one place that writes a credit event and its audit row (the caller holds td.credit_write for status changes)
create or replace function public.credit_event(p_credit uuid, p_kind text, p_lesson uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare c makeup_credits;
begin
  select * into c from makeup_credits where id = p_credit;
  insert into makeup_credit_events(org_id, credit_id, kind, lesson_id, actor, reason) values (c.org_id, c.id, p_kind, p_lesson, auth.uid(), p_reason);
  insert into audit_log(org_id, actor, action, table_name, row_id, after)
  values (c.org_id, auth.uid(), 'credit_' || p_kind, 'makeup_credits', c.id::text,
          jsonb_build_object('student', c.student_id, 'source', c.source, 'source_lesson', c.source_lesson_id, 'lesson', p_lesson, 'reason', p_reason, 'expires_on', c.expires_on));
end $$;
revoke all on function public.credit_event(uuid, text, uuid, text) from public, anon, authenticated;
revoke all on function public.credit_cfg(uuid, date) from public, anon, authenticated;

-- one status change under the flag: p_from must be the credit's current status (so a double press changes nothing the second time); true = it changed
create or replace function public.credit_move(p_credit uuid, p_from text, p_to text, p_kind text, p_lesson uuid, p_reason text) returns boolean
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform set_config('td.credit_write', 'on', true);
  update makeup_credits set status = p_to where id = p_credit and status = p_from;
  get diagnostics n = row_count;
  perform set_config('td.credit_write', '', true);
  if n = 0 then return false; end if;
  perform credit_event(p_credit, p_kind, p_lesson, p_reason);
  return true;
end $$;
revoke all on function public.credit_move(uuid, text, text, text, uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------- 5. earning: when a lesson becomes a missed lesson the centre credits
-- Called by the lesson trigger after a mark / cancel. Does nothing for a solo organisation, for a make-up lesson (a missed make-up never earns a second
-- credit: one missed lesson = one credit; staff may grant one by hand), or when the centre's rule is `none`.
create or replace function public.credit_consider(l lessons) returns void
language plpgsql security definer set search_path = public as $$
declare tz text; today date; cfg jsonb; src text; why text; days int; cid uuid; c makeup_credits; absences text[];
begin
  select o.timezone into tz from organisations o where o.id = l.org_id and o.kind = 'centre';
  if tz is null or l.makeup_credit_id is not null then return; end if;
  today := (now() at time zone tz)::date;
  cfg := credit_cfg(l.org_id, today);
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
revoke all on function public.credit_consider(lessons) from public, anon, authenticated;

-- ---------------------------------------------------------------- 6. the lesson triggers
-- after a mark / cancel on a lesson: (a) a make-up that has been marked uses its credit up; (b) a missed lesson may earn a credit
create or replace function public.lessons_credit_after() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('td.deleting_org', true), '') <> '' then return new; end if;
  if new.makeup_credit_id is not null then
    if new.attendance is not null and new.attendance is distinct from old.attendance then
      perform credit_move(new.makeup_credit_id, 'booked', 'used', 'used', new.id, 'Make-up lesson marked ' || replace(new.attendance, '_', ' '));
    end if;
    return new;
  end if;
  perform credit_consider(new);
  return new;
end $$;
drop trigger if exists lessons_credit_after on public.lessons;
create trigger lessons_credit_after after update of attendance, status, changed_by_tutor_what, charge_note on public.lessons
  for each row when (old.attendance is distinct from new.attendance or old.status is distinct from new.status
                  or old.changed_by_tutor_what is distinct from new.changed_by_tutor_what or old.charge_note is distinct from new.charge_note)
  execute function public.lessons_credit_after();

-- a make-up lesson that is deleted while its credit is booked gives the credit back (so a credit can never be left booked to a lesson that is gone)
create or replace function public.lessons_credit_before_delete() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.makeup_credit_id is not null and coalesce(current_setting('td.deleting_org', true), '') = '' then
    perform credit_move(old.makeup_credit_id, 'booked', 'open', 'returned', old.id, coalesce(nullif(current_setting('td.credit_reason', true), ''), 'The make-up lesson was removed'));
  end if;
  return old;
end $$;
drop trigger if exists lessons_credit_before_delete on public.lessons;
create trigger lessons_credit_before_delete before delete on public.lessons for each row when (old.makeup_credit_id is not null) execute function public.lessons_credit_before_delete();

-- ---------------------------------------------------------------- 7. the gate every credit function starts with (internal)
-- p_need: 'look' (any owner / staff) | 'grant' (grant + revoke) | 'book' (book + unbook). Returns the centre's own "today".
-- A write also needs the feature switched on: rule <> 'none' (NOT_ENABLED), so a centre that never chose credits is never changed by a stray call.
create or replace function public.credit_gate(p_org uuid, p_need text) returns date
language plpgsql stable security definer set search_path = public as $$
declare tz text; today date; cfg jsonb; who text;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select o.timezone into tz from organisations o where o.id = p_org and o.kind = 'centre';
  if tz is null or not exists (select 1 from memberships m where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active'
                               and m.role in ('owner', 'staff')) then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;
  today := (now() at time zone tz)::date;
  if p_need = 'look' then return today; end if;
  cfg := credit_cfg(p_org, today);
  who := case p_need when 'grant' then cfg ->> 'grant_by' else cfg ->> 'book_by' end;
  if who = 'owner' then
    if not org_can(p_org, 'owner') then raise exception 'NOT_ALLOWED: at this centre only the owner can do this' using errcode = '42501'; end if;
  elsif not org_can(p_org, 'manage_timetable') then
    raise exception 'NOT_ALLOWED: your account can''t change make-up credits at this centre' using errcode = '42501';
  end if;
  if cfg ->> 'rule' = 'none' then
    raise exception 'NOT_ENABLED: make-up credits are switched off at this centre (Settings, How lessons are billed)' using errcode = 'P0001'; end if;
  return today;
end $$;
revoke all on function public.credit_gate(uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------- 8. THE OWED LIST (read)
-- p_status: open (default: what the centre still owes) | booked | used | expired | revoked | all. p_student: only that student (the chip on the student sheet).
-- Every row carries the missed lesson (when, with whom, how it was marked) and, once booked, the make-up lesson. NO money: no rate, amount, charge or cents.
-- can_grant / can_book already include the caller's permission and the centre's settings, so the screen doesn't guess.
create or replace function public.staff_credit_list(p_org uuid, p_status text default 'open', p_student uuid default null, p_page int default 1, p_size int default 25)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare today date := credit_gate(p_org, 'look'); cfg jsonb := credit_cfg(p_org, today); pg int := coalesce(p_page, 1); sz int := coalesce(p_size, 25);
        can_g boolean; can_b boolean; rows jsonb; total int; cnt jsonb;
begin
  if p_status is null or p_status not in ('open', 'booked', 'used', 'expired', 'revoked', 'all') then
    raise exception 'BAD_FILTER: choose open, booked, used, expired, revoked or all' using errcode = 'P0001'; end if;
  if pg < 1 or pg > 100000 then raise exception 'BAD_PAGE: no such page' using errcode = 'P0001'; end if;
  if sz < 1 or sz > 100 then raise exception 'BAD_PAGE: ask for 1 to 100 credits at a time' using errcode = 'P0001'; end if;
  if p_student is not null and not exists (select 1 from students s where s.id = p_student and s.org_id = p_org) then
    raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  can_g := cfg ->> 'rule' <> 'none' and case cfg ->> 'grant_by' when 'owner' then org_can(p_org, 'owner') else org_can(p_org, 'manage_timetable') end;
  can_b := cfg ->> 'rule' <> 'none' and case cfg ->> 'book_by' when 'owner' then org_can(p_org, 'owner') else org_can(p_org, 'manage_timetable') end;

  select jsonb_build_object('open', count(*) filter (where status = 'open'), 'booked', count(*) filter (where status = 'booked'),
                            'used', count(*) filter (where status = 'used'), 'expired', count(*) filter (where status = 'expired'),
                            'revoked', count(*) filter (where status = 'revoked'))
    into cnt from makeup_credits where org_id = p_org and (p_student is null or student_id = p_student);
  select count(*) into total from makeup_credits c where c.org_id = p_org and (p_student is null or c.student_id = p_student) and (p_status = 'all' or c.status = p_status);

  select coalesce(jsonb_agg(r order by r_ord, r_id), '[]'::jsonb) into rows from (
    select jsonb_build_object(
             'credit_id', c.id, 'student_id', c.student_id, 'student_name', st.name, 'status', c.status, 'source', c.source, 'reason', c.reason,
             'earned_on', c.earned_on, 'expires_on', c.expires_on,
             'days_left', case when c.expires_on is not null and c.status = 'open' then c.expires_on - today end,
             'expired_by_date', (c.status = 'open' and c.expires_on is not null and c.expires_on < today),
             'missed', case when sl.id is null then null else jsonb_build_object('lesson_id', sl.id, 'date', sl.lesson_date, 'start_time', sl.start_time,
                         'subject', sl.subject, 'attendance', sl.attendance, 'tutor_name', stm.display_name) end,
             'makeup', case when ml.id is null then null else jsonb_build_object('lesson_id', ml.id, 'date', ml.lesson_date, 'start_time', ml.start_time,
                         'end_time', ml.end_time, 'attendance', ml.attendance, 'billing', ml.makeup_billing, 'tutor_name', mtm.display_name) end,
             'can_revoke', (c.status = 'open' and can_g),
             'can_book', (c.status = 'open' and can_b and not (c.expires_on is not null and c.expires_on < today)),
             'can_unbook', (c.status = 'booked' and can_b and ml.id is not null and ml.attendance is null and lesson_change_blocker(ml.id) is null)
           ) as r, c.earned_on as r_ord, c.id as r_id
      from makeup_credits c
      join students st on st.id = c.student_id and st.org_id = c.org_id
      left join lessons sl on sl.id = c.source_lesson_id and sl.org_id = c.org_id
      left join memberships stm on stm.id = sl.taught_by and stm.org_id = sl.org_id
      left join lessons ml on ml.makeup_credit_id = c.id and ml.org_id = c.org_id
      left join memberships mtm on mtm.id = ml.taught_by and mtm.org_id = ml.org_id
     where c.org_id = p_org and (p_student is null or c.student_id = p_student) and (p_status = 'all' or c.status = p_status)
     order by c.earned_on, c.id offset (pg - 1) * sz limit sz) z;

  return jsonb_build_object('today', today, 'page', pg, 'size', sz, 'total', total, 'counts', cnt, 'rows', rows,
                            'enabled', cfg ->> 'rule' <> 'none', 'can_grant', can_g, 'can_book', can_b,
                            'makeup_price', cfg ->> 'makeup_price', 'expiry_days', (cfg ->> 'expiry_days')::int);
end $$;

-- ---------------------------------------------------------------- 9. GRANT by hand (a tutor's cancel, a goodwill make-up, a missed lesson the rules didn't credit)
-- p_lesson (optional) = the missed lesson it is for: it must be this student's, and a lesson earns ONE credit ever (ALREADY_HAS_CREDIT).
-- A reason (3-300 characters) is always required and is kept on record. The same student and reason within a minute is refused (DUPLICATE: a double press).
create or replace function public.staff_grant_credit(p_org uuid, p_student uuid, p_reason text, p_lesson uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := credit_gate(p_org, 'grant'); cfg jsonb := credit_cfg(p_org, today); why text := nullif(trim(coalesce(p_reason, '')), ''); l lessons; cid uuid; days int;
begin
  if not exists (select 1 from students s where s.id = p_student and s.org_id = p_org) then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  if why is null then raise exception 'REASON_REQUIRED: say why this credit is given' using errcode = 'P0001'; end if;
  if char_length(why) < 3 or char_length(why) > 300 then raise exception 'BAD_REASON: the reason must be 3-300 characters' using errcode = 'P0001'; end if;
  if p_lesson is not null then
    select * into l from lessons where id = p_lesson and org_id = p_org and student_id = p_student;
    if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
    if l.makeup_credit_id is not null then raise exception 'IS_MAKEUP: a make-up lesson can''t earn another credit' using errcode = 'P0001'; end if;
    if exists (select 1 from makeup_credits c where c.source_lesson_id = p_lesson) then
      raise exception 'ALREADY_HAS_CREDIT: this lesson already has its credit' using errcode = 'P0001'; end if;
  end if;
  if exists (select 1 from makeup_credits c where c.org_id = p_org and c.student_id = p_student and c.source = 'manual' and c.reason = why
               and c.created_at > now() - interval '1 minute') then
    raise exception 'DUPLICATE: this credit was just given' using errcode = 'P0001'; end if;
  days := (cfg ->> 'expiry_days')::int;
  insert into makeup_credits(org_id, student_id, source, source_lesson_id, reason, earned_on, expires_on, created_by)
  values (p_org, p_student, 'manual', p_lesson, why, today, case when days > 0 then today + days end, auth.uid())
  returning id into cid;
  perform credit_event(cid, 'earned', p_lesson, why);
  return jsonb_build_object('credit_id', cid, 'expires_on', case when days > 0 then today + days end);
end $$;

-- ---------------------------------------------------------------- 10. REVOKE (only an unused credit; a booked or used one is refused)
create or replace function public.staff_revoke_credit(p_credit uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c makeup_credits; today date; why text := nullif(trim(coalesce(p_reason, '')), '');
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into c from makeup_credits where id = p_credit;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := credit_gate(c.org_id, 'grant');
  if why is null then raise exception 'REASON_REQUIRED: say why this credit is taken back' using errcode = 'P0001'; end if;
  if char_length(why) < 3 or char_length(why) > 300 then raise exception 'BAD_REASON: the reason must be 3-300 characters' using errcode = 'P0001'; end if;
  select * into c from makeup_credits where id = p_credit for update;
  if c.status in ('booked', 'used') then
    raise exception 'IN_USE: a make-up lesson is already booked or taught with this credit; remove the make-up first' using errcode = 'P0001'; end if;
  if c.status <> 'open' then raise exception 'NO_CHANGE: this credit is already %', c.status using errcode = 'P0001'; end if;
  perform credit_move(c.id, 'open', 'revoked', 'revoked', null, why);
  return jsonb_build_object('credit_id', c.id, 'status', 'revoked');
end $$;

-- ---------------------------------------------------------------- 11. BOOK the make-up lesson
-- Creates an ordinary one-off lesson (the tick-star kind) for the credit's student, copying subject, level, rate and tutor from the missed lesson (or, for a credit
-- with none, from the student's latest lesson), and links it to the credit. The date is today or later, within a year, and not after the credit's last day.
-- p_end is the end time; p_tutor (a memberships.id) defaults to the missed lesson's tutor when that person is still active, else nobody.
-- PRICE (frozen on the lesson as makeup_billing): see the header. 'free' lessons are skipped by the invoice run; 'normal' ones are billed like any lesson, once.
create or replace function public.staff_book_makeup(p_credit uuid, p_date date, p_start time, p_end time, p_tutor uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c makeup_credits; today date; cfg jsonb; t lessons; src lessons; tut uuid; bill text; lid uuid; hours numeric; amt numeric; pending boolean; charged boolean;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into c from makeup_credits where id = p_credit;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := credit_gate(c.org_id, 'book');
  cfg := credit_cfg(c.org_id, today);
  select * into c from makeup_credits where id = p_credit for update;                 -- two people pressing together: one waits, then finds it booked
  if c.status = 'booked' then raise exception 'ALREADY_BOOKED: a make-up lesson is already booked with this credit' using errcode = 'P0001'; end if;
  if c.status <> 'open' then raise exception 'NOT_OPEN: this credit is %', c.status using errcode = 'P0001'; end if;
  if c.expires_on is not null and c.expires_on < today then
    raise exception 'EXPIRED: this credit ended on %', to_char(c.expires_on, 'DD Mon YYYY') using errcode = 'P0001'; end if;
  if p_date is null or p_start is null or p_end is null then raise exception 'BAD_TIME: choose a day, a start and an end time' using errcode = 'P0001'; end if;
  if p_end <= p_start then raise exception 'BAD_TIME: the lesson must end after it starts' using errcode = 'P0001'; end if;
  if p_date < today or p_date > today + 365 then raise exception 'BAD_DATE: choose a day from today to a year ahead' using errcode = 'P0001'; end if;
  if c.expires_on is not null and p_date > c.expires_on then
    raise exception 'TOO_LATE: this credit can only be used up to %', to_char(c.expires_on, 'DD Mon YYYY') using errcode = 'P0001'; end if;
  if exists (select 1 from students s where s.id = c.student_id and s.org_id = c.org_id and s.end_date is not null and s.end_date < p_date) then
    raise exception 'ENDED: this student''s lessons end before that day' using errcode = 'P0001'; end if;

  select * into src from lessons where id = c.source_lesson_id and org_id = c.org_id;
  select * into t from lessons where org_id = c.org_id and student_id = c.student_id and makeup_credit_id is null and trial is not true
   order by lesson_date desc, start_time desc limit 1;
  if src.id is not null then t := src; end if;
  if t.id is null then raise exception 'NO_TEMPLATE: add one lesson for this student first, so the make-up knows the subject and rate' using errcode = 'P0001'; end if;

  tut := coalesce(p_tutor, t.taught_by);
  if tut is not null and not exists (select 1 from memberships m where m.id = tut and m.org_id = c.org_id and m.status <> 'disabled' and m.role = 'tutor') then
    if p_tutor is not null then raise exception 'NOT_AVAILABLE: that person can''t be given lessons here' using errcode = 'P0001'; end if;
    tut := null;
  end if;
  if exists (select 1 from lessons x where x.org_id = c.org_id and x.student_id = c.student_id and x.lesson_date = p_date and x.start_time = p_start) then
    raise exception 'DUPLICATE: this student already has a lesson at that time' using errcode = 'P0001'; end if;

  -- the price rule
  if cfg ->> 'makeup_price' = 'free' then bill := 'free';
  elsif src.id is null then bill := 'normal';
  else
    pending := src.status = 'cancelled' and src.compensation is null;
    charged := src.status = 'done' or coalesce(src.compensation, 0) > 0;
    if pending then raise exception 'CHARGE_PENDING: type the charge for the missed lesson first, so the family isn''t charged twice' using errcode = 'P0001'; end if;
    bill := case when charged then 'free' else 'normal' end;
  end if;
  hours := extract(epoch from (p_end - p_start)) / 3600;
  amt := case when bill = 'free' then 0 else round(round(t.rate * hours, 2) / greatest(coalesce(t.split, 1), 1), 2) end;

  perform set_config('td.credit_write', 'on', true);
  insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, subject, level, rate, split, amount, status, paid, one_off, taught_by,
                      makeup_credit_id, makeup_billing)
  values (t.tutor_id, c.org_id, c.student_id, p_date, p_start, p_end, t.subject, t.level, t.rate, coalesce(t.split, 1), amt, 'scheduled', false, true, tut, c.id, bill)
  returning id into lid;
  perform set_config('td.credit_write', '', true);
  perform credit_move(c.id, 'open', 'booked', 'booked', lid, 'Make-up booked for ' || to_char(p_date, 'DD Mon YYYY') || ' (' || bill || ')');
  return jsonb_build_object('credit_id', c.id, 'lesson_id', lid, 'billing', bill, 'date', p_date);
end $$;

-- ---------------------------------------------------------------- 12. UNBOOK: take the make-up away and give the credit back
-- Only a make-up nobody has marked, that isn't paid or invoiced (lesson_change_blocker). The lesson is REMOVED (it existed only for this credit); the credit
-- goes back to open with a "returned" event (the delete trigger does that, so a lesson deleted any other way returns its credit too).
create or replace function public.staff_unbook_makeup(p_credit uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c makeup_credits; today date; why text := nullif(trim(coalesce(p_reason, '')), ''); l lessons; blocker text;
begin
  if auth.uid() is null then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  select * into c from makeup_credits where id = p_credit;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  today := credit_gate(c.org_id, 'book');
  if why is null then raise exception 'REASON_REQUIRED: say why the make-up is taken away' using errcode = 'P0001'; end if;
  if char_length(why) < 3 or char_length(why) > 300 then raise exception 'BAD_REASON: the reason must be 3-300 characters' using errcode = 'P0001'; end if;
  select * into c from makeup_credits where id = p_credit for update;
  if c.status = 'open' then raise exception 'NO_CHANGE: no make-up is booked with this credit' using errcode = 'P0001'; end if;
  if c.status = 'used' then raise exception 'IN_USE: the make-up was already marked, so the credit is used up' using errcode = 'P0001'; end if;
  if c.status <> 'booked' then raise exception 'NO_CHANGE: this credit is %', c.status using errcode = 'P0001'; end if;
  select * into l from lessons where makeup_credit_id = c.id and org_id = c.org_id;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0001'; end if;
  blocker := lesson_change_blocker(l.id);
  if blocker is not null then
    raise exception 'LOCKED: this make-up can''t be removed (%)', lower(blocker) using errcode = 'P0001'; end if;
  perform set_config('td.credit_write', 'on', true);
  perform set_config('td.credit_reason', why, true);
  delete from lessons where id = l.id and org_id = c.org_id;
  perform set_config('td.credit_reason', '', true);
  perform set_config('td.credit_write', '', true);
  return jsonb_build_object('credit_id', c.id, 'status', (select status from makeup_credits where id = c.id));
end $$;

-- ---------------------------------------------------------------- 13. EXPIRY (a job: no signed-in person may call it)
-- Open credits whose last day (expires_on) is BEFORE the given day become expired, with an event and an audit row each. A credit expires the day AFTER its last
-- day: on expires_on itself it is still usable. A booked credit never expires (its make-up is already arranged). Safe to run any number of times.
-- The day defaults to today in Singapore (the only time zone). Called by api/credits-cron.js with the service key; NOT scheduled by this migration.
create or replace function public.credits_expire_due(p_today date default null) returns int
language plpgsql security definer set search_path = public as $$
declare d date := coalesce(p_today, (now() at time zone 'Asia/Singapore')::date); r record; n int := 0;
begin
  for r in select id from makeup_credits where status = 'open' and expires_on is not null and expires_on < d order by expires_on, id loop
    if credit_move(r.id, 'open', 'expired', 'expired', null, 'Passed its last day') then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- who may call what
revoke all on function public.staff_credit_list(uuid, text, uuid, int, int) from public, anon;
revoke all on function public.staff_grant_credit(uuid, uuid, text, uuid) from public, anon;
revoke all on function public.staff_revoke_credit(uuid, text) from public, anon;
revoke all on function public.staff_book_makeup(uuid, date, time, time, uuid) from public, anon;
revoke all on function public.staff_unbook_makeup(uuid, text) from public, anon;
grant execute on function public.staff_credit_list(uuid, text, uuid, int, int) to authenticated;
grant execute on function public.staff_grant_credit(uuid, uuid, text, uuid) to authenticated;
grant execute on function public.staff_revoke_credit(uuid, text) to authenticated;
grant execute on function public.staff_book_makeup(uuid, date, time, time, uuid) to authenticated;
grant execute on function public.staff_unbook_makeup(uuid, text) to authenticated;
revoke all on function public.credits_expire_due(date) from public, anon, authenticated;
grant execute on function public.credits_expire_due(date) to service_role;
revoke all on function public.makeup_credits_guard() from public, anon, authenticated;
revoke all on function public.makeup_credit_events_guard() from public, anon, authenticated;
revoke all on function public.lessons_makeup_guard() from public, anon, authenticated;
revoke all on function public.lessons_credit_after() from public, anon, authenticated;
revoke all on function public.lessons_credit_before_delete() from public, anon, authenticated;
