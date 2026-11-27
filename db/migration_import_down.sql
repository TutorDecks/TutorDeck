-- Undo for migration_import.sql (T33 I1): removes the import tables, functions, columns and the billing-start check.
-- Run it BEFORE migration_org_separation_down.sql (reverse order of the migrations). Imported data (students, families, tutors' invitations,
-- weekly lessons) is NOT touched: only the bookkeeping that says "this came from an import" goes, and the two student columns the import filled
-- (online_link, start_date) are dropped with their values. Safe to run twice.
drop function if exists public.import_undo(uuid);
drop function if exists public.import_undo_preview(uuid);
drop function if exists public.import_undo_run(uuid, boolean);
drop function if exists public.import_history(uuid);
drop function if exists public.import_existing(uuid);
drop function if exists public.import_commit(uuid, jsonb, jsonb);
drop function if exists public.import_dry_run(uuid, jsonb);
drop function if exists public.import_run_a(uuid, jsonb, boolean, jsonb);
drop function if exists public.import_lesson_touched(lessons);
drop function if exists public.import_row_exists(text, uuid);
drop function if exists public.import_minutes(text);
drop function if exists public.import_try_date(text);
drop function if exists public.import_fp(jsonb);
drop function if exists public.org_billing_start(uuid);
drop table if exists public.import_items;
drop table if exists public.import_batches;
drop index if exists public.recurring_slots_taught_by;
alter table public.recurring_slots drop constraint if exists recurring_slots_taught_by_same_org;
alter table public.recurring_slots drop column if exists taught_by;
alter table public.students drop column if exists online_link;
alter table public.students drop column if exists start_date;
-- (memberships_id_org belongs to migration_tutor_access.sql and stays)

-- the settings check as it was before: no billing.starts_from rule
create or replace function public.org_validate_settings(s jsonb) returns void language plpgsql immutable as $$
declare k text;
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
end $$;
alter function public.org_validate_settings(jsonb) set search_path = public;
