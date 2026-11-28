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
fdefs() { psql -qAt -d $DB -c "select md5(string_agg(pg_get_functiondef(p.oid), '' order by p.oid::regprocedure::text)) from pg_proc p where pronamespace='public'::regnamespace and prokind='f'"; }
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
$P -f db/migration_invites.sql                              # (the People list reads the invite send log; the invites test above undid it)
$P -f db/migration_slot_changes.sql
$P -f db/migration_slot_changes.sql                         # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/slot_changes_test.sql
$P -f db/migration_tutor_moves.sql
$P -f db/migration_tutor_moves.sql                          # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/tutor_moves_test.sql
$P -f db/migration_b5_fix.sql
$P -f db/migration_b5_fix.sql                               # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/b5_fix_test.sql
$P -f db/migration_tutor_own_lessons.sql
$P -f db/migration_tutor_own_lessons.sql                    # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/tutor_own_lessons_test.sql
# ---- bundle 6 (T44-style assembly, T46): import, tutor pay, statements, invoice email, make-up credits, data export. ORDER MATTERS: three of them replace
#      org_validate_settings() and two replace centre_invoice_run_rows(); each file carries the cumulative version of the one before it (see CLAUDE.md).
$P -f db/migration_import.sql
$P -f db/migration_import.sql                               # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/import_test.sql
if command -v node >/dev/null 2>&1; then                    # the page's own payload through the database (JS and SQL checks agree)
  export IMPORT_PAYLOAD_FILE="$(mktemp)"; node tests/fixtures/make-import-payload.js > "$IMPORT_PAYLOAD_FILE"
  psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/import_payload_test.sql; rm -f "$IMPORT_PAYLOAD_FILE"
else echo "SKIP import payload test (node not installed)"; fi
$P -f db/migration_centre_tutor_pay.sql
$P -f db/migration_centre_tutor_pay.sql                     # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/centre_tutor_pay_test.sql
$P -f db/migration_statement_matching.sql
$P -f db/migration_statement_matching.sql                   # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/statement_matching_test.sql
$P -f db/migration_invoice_email.sql
$P -f db/migration_invoice_email.sql                        # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/invoice_email_test.sql
$P -f db/migration_makeup_credits.sql
$P -f db/migration_makeup_credits.sql                       # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/makeup_credits_test.sql
FDEFS_BEFORE=$(fdefs)
$P -f db/migration_tutor_link_propose.sql
$P -f db/migration_tutor_link_propose.sql                   # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/tutor_link_propose_test.sql
$P -f db/migration_tutor_link_propose_down.sql
if [ "$FDEFS_BEFORE" != "$(fdefs)" ]; then echo "FAIL: undoing tutor_link_propose did not put every function back exactly"; exit 1; fi
echo "PASS undoing tutor_link_propose puts every function back exactly"
$P -f db/migration_tutor_link_propose.sql                   # and again: the shipped state
FDEFS_BEFORE=$(fdefs)
$P -f db/migration_past_lessons.sql
$P -f db/migration_past_lessons.sql                         # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/past_lessons_test.sql
$P -f db/migration_past_lessons_down.sql
if [ "$FDEFS_BEFORE" != "$(fdefs)" ]; then echo "FAIL: undoing past_lessons did not put every function back exactly"; exit 1; fi
echo "PASS undoing past_lessons puts every function back exactly"
$P -f db/migration_past_lessons.sql                         # and again: the shipped state
FDEFS_BEFORE=$(fdefs)
$P -f db/migration_tutor_own_pay.sql
$P -f db/migration_tutor_own_pay.sql                        # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/tutor_own_pay_test.sql
$P -f db/migration_tutor_own_pay_down.sql
if [ "$FDEFS_BEFORE" != "$(fdefs)" ]; then echo "FAIL: undoing tutor_own_pay did not put every function back exactly"; exit 1; fi
echo "PASS undoing tutor_own_pay puts every function back exactly"
$P -f db/migration_tutor_own_pay.sql                        # and again: the shipped state
$P -f db/migration_centre_billing_method.sql                # the export reads the billing-method and billing-start columns (the chain above had undone them)
$P -f db/migration_centre_billing_start.sql
$P -f db/migration_org_export.sql
$P -f db/migration_org_export.sql                           # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/org_export_test.sql
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/org_export_perf_test.sql
psql -qAt -v ON_ERROR_STOP=1 -d $DB -v stage=full -f tests/sql/bundle6_chain_test.sql   # the settings check and the invoice run carry EVERY rule of the chain
FDEFS_BEFORE=$(fdefs)
$P -f db/migration_b8_fix.sql                               # B8-FIX (F4 deposits raised again, F5 refunded state, F6 trial lessons never earn credits)
$P -f db/migration_b8_fix.sql                               # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/b8_fix_credits_test.sql
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/b8_fix_deposits_test.sql
$P -f db/migration_b8_fix_down.sql
if [ "$FDEFS_BEFORE" != "$(fdefs)" ]; then echo "FAIL: undoing b8_fix did not put every function back exactly"; exit 1; fi
echo "PASS undoing b8_fix puts every function back exactly"
# undo in reverse, twice each (safe to run twice), then the whole set again, then undo again: undo + re-apply are proven on the shipped state
for round in 1 2; do
  for m in org_export tutor_own_pay past_lessons tutor_link_propose makeup_credits invoice_email statement_matching centre_tutor_pay import; do $P -f db/migration_${m}_down.sql; $P -f db/migration_${m}_down.sql; done
  psql -qAt -v ON_ERROR_STOP=1 -d $DB -v stage=undone -f tests/sql/bundle6_chain_test.sql
  if [ "$round" = 1 ]; then
    for m in import centre_tutor_pay statement_matching invoice_email makeup_credits tutor_link_propose past_lessons tutor_own_pay; do $P -f db/migration_${m}.sql; done
    $P -f db/migration_org_export.sql
    psql -qAt -v ON_ERROR_STOP=1 -d $DB -v stage=full -f tests/sql/bundle6_chain_test.sql
  fi
done
$P -f db/migration_centre_billing_start_down.sql            # (back to how the chain was before the export block)
$P -f db/migration_centre_billing_method_down.sql
$P -f db/migration_tutor_own_lessons_down.sql
$P -f db/migration_tutor_own_lessons.sql                    # and again, so the undo chain below starts from the shipped state
$P -f db/migration_tutor_own_lessons_down.sql
$P -f db/migration_b5_fix_down.sql
$P -f db/migration_b5_fix.sql                               # and again, so the undo chain below starts from the shipped state
$P -f db/migration_b5_fix_down.sql
$P -f db/migration_tutor_moves_down.sql
$P -f db/migration_tutor_moves.sql                          # and again, so the undo chain below starts from the shipped state
$P -f db/migration_tutor_moves_down.sql
$P -f db/migration_slot_changes_down.sql
$P -f db/migration_slot_changes.sql                         # and again, so the undo chain below starts from the shipped state
$P -f db/migration_slot_changes_down.sql
$P -f db/migration_invites_down.sql
$P -f db/migration_centre_credit_undo_down.sql
$P -f db/migration_centre_late_fees_down.sql
$P -f db/migration_centre_refunds_down.sql
$P -f db/migration_centre_deposits_down.sql
$P -f db/migration_fee_050_down.sql                         # fee_050 is unwound here (it was already undone once above; safe to repeat)
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
bash tests/sql/dev_seed_money_test.sh                         # T47: the rich DEV money demo seed on its own throwaway database (builds the chain itself, so it cannot rot)
