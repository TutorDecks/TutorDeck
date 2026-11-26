#!/usr/bin/env bash
# Phase 1 database tests on a THROWAWAY local Postgres (never a Supabase project):
#   live baseline → made-up legacy data → migration → tests → undo → structure equals baseline → migrate again.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PGHOST="${PGHOST:-/var/lib/postgresql}" PGPORT="${PGPORT:-54329}" PGUSER="${PGUSER:-postgres}"
DB=td_org_test
P="psql -q -v ON_ERROR_STOP=1 -d $DB"
shape() { psql -qAt -d $DB -c "select string_agg(x, E'\n' order by x) from (
  select 'col '||table_name||'.'||column_name||' '||data_type x from information_schema.columns where table_schema='public'
  union all select 'pol '||tablename||'.'||policyname from pg_policies where schemaname='public'
  union all select 'trg '||event_object_table||'.'||trigger_name from information_schema.triggers where trigger_schema='public'
  union all select 'fn '||p.oid::regprocedure::text from pg_proc p where pronamespace='public'::regnamespace
  union all select 'con '||conname from pg_constraint where connamespace='public'::regnamespace) s"; }
psql -qAt -d postgres -c "drop database if exists $DB" -c "create database $DB"
$P -f tests/sql/supabase_shim.sql
$P -f db/baseline_2026-11.sql
$P -f tests/sql/org_seed.sql
BEFORE=$(shape)
$P -f db/migration_org_foundation.sql
$P -f db/migration_org_foundation.sql                     # must be safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/org_test.sql
$P -f db/migration_billing.sql
$P -f db/migration_billing.sql                            # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/billing_test.sql
$P -f db/migration_attendance.sql
$P -f db/migration_attendance.sql                         # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/attendance_test.sql
$P -f db/migration_tutor_access.sql
$P -f db/migration_tutor_access.sql                      # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/tutor_access_test.sql
$P -f db/migration_org_delete.sql
$P -f db/migration_org_delete.sql                         # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/org_delete_test.sql
$P -f db/migration_function_lockdown.sql
$P -f db/migration_function_lockdown.sql                  # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/lockdown_test.sql
$P -f db/migration_org_separation.sql
$P -f db/migration_org_separation.sql                       # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/org_separation_test.sql
$P -f db/migration_staff_home.sql
$P -f db/migration_staff_home.sql                           # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/staff_home_test.sql
$P -f db/migration_staff_students.sql
$P -f db/migration_staff_students.sql                       # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/staff_students_test.sql
$P -f db/migration_staff_attendance.sql
$P -f db/migration_staff_attendance.sql                     # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/staff_attendance_test.sql
$P -f db/migration_staff_charges.sql
$P -f db/migration_staff_charges.sql                        # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/staff_charges_test.sql
$P -f db/migration_staff_trials.sql
$P -f db/migration_staff_trials.sql                         # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/staff_trials_test.sql
$P -f db/migration_staff_timetable.sql
$P -f db/migration_staff_timetable.sql                      # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/staff_timetable_test.sql
$P -f db/migration_staff_slots.sql
$P -f db/migration_staff_slots.sql                          # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/staff_slots_test.sql
$P -f db/migration_staff_reassign.sql
$P -f db/migration_staff_reassign.sql                       # safe to run twice
$P -f db/migration_reassign_link.sql                         # B4-FIX: replaces staff_reassign_lesson; the reassign tests below cover it
$P -f db/migration_reassign_link.sql                         # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/staff_reassign_test.sql
$P -f db/migration_tutor_schedule.sql
$P -f db/migration_tutor_schedule.sql                       # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/tutor_schedule_test.sql
$P -f db/migration_money_settings.sql
$P -f db/migration_money_settings.sql                         # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/money_settings_test.sql
$P -f db/migration_centre_money.sql
$P -f db/migration_centre_money.sql                         # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/centre_money_test.sql
$P -f db/migration_centre_invoice_run.sql
$P -f db/migration_centre_invoice_run.sql                   # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/centre_invoice_run_test.sql
$P -f db/migration_centre_payments.sql
$P -f db/migration_centre_payments.sql                      # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/centre_payments_test.sql
$P -f db/migration_payment_fix.sql
$P -f db/migration_payment_fix.sql                           # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/payment_fix_test.sql
$P -f db/migration_invites.sql
$P -f db/migration_invites.sql                              # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/invites_test.sql
$P -f db/migration_invites_down.sql
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/fee_050_before.sql
$P -f db/migration_fee_050.sql
$P -f db/migration_fee_050.sql                              # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/fee_050_test.sql
$P -f db/migration_centre_billing_method.sql
$P -f db/migration_centre_billing_method.sql                # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/centre_billing_method_test.sql
$P -f db/migration_centre_billing_start.sql
$P -f db/migration_centre_billing_start.sql                 # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/centre_billing_start_test.sql
$P -f db/migration_centre_billing_start_down.sql
$P -f db/migration_centre_billing_start.sql                 # and again, so the shipped state is what the undo chain unwinds
$P -f db/migration_centre_billing_start_down.sql
$P -f db/migration_centre_billing_method_down.sql
$P -f db/migration_centre_billing_method.sql                # and again, so the shipped state is what the undo chain unwinds
$P -f db/migration_centre_billing_method_down.sql
$P -f db/migration_fee_050_down.sql
$P -f db/migration_org_separation_down.sql
$P -f db/migration_org_separation.sql                       # and again, so the shipped state is what the undo chain below unwinds
$P -f db/migration_tutor_profile.sql
$P -f db/migration_tutor_profile.sql                        # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/tutor_profile_test.sql
$P -f db/migration_tutor_payout.sql
$P -f db/migration_tutor_payout.sql                         # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/tutor_payout_test.sql
$P -f db/migration_payout_permission.sql
$P -f db/migration_payout_permission.sql                    # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/payout_permission_test.sql
$P -f db/migration_fee_050.sql                              # re-apply: credit_undo (below) re-creates org_create_centre on top of the fee_050 body
$P -f db/migration_centre_deposits.sql
$P -f db/migration_centre_deposits.sql                      # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/centre_deposits_test.sql
$P -f db/migration_centre_refunds.sql
$P -f db/migration_centre_refunds.sql                       # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/centre_refunds_test.sql
$P -f db/migration_centre_late_fees.sql
$P -f db/migration_centre_late_fees.sql                     # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/centre_late_fees_test.sql
$P -f db/migration_centre_credit_undo.sql
$P -f db/migration_centre_credit_undo.sql                   # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/centre_credit_undo_test.sql
$P -f db/migration_centre_credit_undo_down.sql
$P -f db/migration_centre_late_fees_down.sql
$P -f db/migration_centre_refunds_down.sql
$P -f db/migration_centre_deposits_down.sql
$P -f db/migration_fee_050_down.sql                         # fee_050 is unwound here (it was already undone once above; safe to repeat)
$P -f db/migration_invites.sql                              # (the People list reads the invite send log; the invites test above undid it)
$P -f db/migration_slot_changes.sql
$P -f db/migration_slot_changes.sql                         # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/slot_changes_test.sql
$P -f db/migration_slot_changes_down.sql
$P -f db/migration_slot_changes.sql                         # and again, so the undo chain below starts from the shipped state
$P -f db/migration_slot_changes_down.sql
$P -f db/migration_invites_down.sql
$P -f db/migration_payout_permission_down.sql
$P -f db/migration_payout_permission.sql                    # and again, so the undo chain below starts from the shipped state
$P -f db/migration_payout_permission_down.sql
$P -f db/migration_tutor_payout_down.sql
$P -f db/migration_tutor_payout.sql                         # and again, so the undo chain below starts from the shipped state
$P -f db/migration_tutor_payout_down.sql
$P -f db/migration_tutor_profile_down.sql
$P -f db/migration_tutor_profile.sql                        # and again, so the undo chain below starts from the shipped state
$P -f db/migration_tutor_profile_down.sql
$P -f db/migration_payment_fix_down.sql
$P -f db/migration_centre_payments_down.sql
$P -f db/migration_centre_invoice_run_down.sql
$P -f db/migration_centre_money_down.sql
$P -f db/migration_money_settings_down.sql
$P -f db/migration_tutor_schedule_down.sql
$P -f db/migration_reassign_link_down.sql
$P -f db/migration_staff_reassign_down.sql
$P -f db/migration_staff_slots_down.sql
$P -f db/migration_staff_timetable_down.sql
$P -f db/migration_staff_trials_down.sql
$P -f db/migration_staff_charges_down.sql
$P -f db/migration_staff_attendance_down.sql
$P -f db/migration_staff_students_down.sql
$P -f db/migration_staff_home_down.sql
$P -f db/migration_org_separation_down.sql
$P -f db/migration_function_lockdown_down.sql
$P -f db/migration_org_delete_down.sql
$P -f db/migration_tutor_access_down.sql
$P -f db/migration_attendance_down.sql
$P -f db/migration_billing_down.sql
$P -f db/migration_org_foundation_down.sql
AFTER=$(shape)
if [ "$BEFORE" != "$AFTER" ]; then echo "FAIL: undo did not restore the baseline"; diff <(echo "$BEFORE") <(echo "$AFTER") | head -20; exit 1; fi
echo "PASS undo restores the baseline exactly"
$P -f db/migration_org_foundation.sql                     # and it can be applied again after an undo
echo "PASS migration re-applies after undo"
