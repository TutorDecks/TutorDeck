#!/usr/bin/env bash
# Builds a THROWAWAY database (default td_seed_test) = shim + live baseline + every up migration in the shipped order
# (no undo steps), then the demo seed db/seed_dev_demo.sql. Used by dev_seed_money_test.sh. Never a Supabase project.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PGHOST="${PGHOST:-/var/lib/postgresql}" PGPORT="${PGPORT:-54329}" PGUSER="${PGUSER:-postgres}"
DB="${1:-td_seed_test}"; SEED="${2:-seed}"          # second argument "noseed" stops before the demo seed
P="psql -q -v ON_ERROR_STOP=1 -d $DB"
psql -qAt -d postgres -c "drop database if exists $DB" -c "create database $DB"
$P -f tests/sql/supabase_shim.sql
$P -f db/baseline_2026-11.sql
for m in org_foundation billing attendance tutor_access org_delete function_lockdown org_separation staff_home staff_students staff_attendance \
         staff_charges staff_trials staff_timetable staff_slots staff_reassign reassign_link tutor_schedule money_settings centre_money centre_invoice_run \
         centre_payments payment_fix invites fee_050 centre_billing_method centre_billing_start tutor_profile tutor_payout payout_permission \
         centre_deposits centre_refunds centre_late_fees centre_credit_undo slot_changes tutor_moves; do
  $P -f db/migration_$m.sql >/dev/null
done
if [ "$SEED" = noseed ]; then echo "chain ready in $DB (no demo seed)"; exit 0; fi
$P -f tests/sql/pack_shim.sql >/dev/null   # real-shaped auth rows + extensions.crypt for the demo seed
$P -f db/seed_dev_demo.sql >/dev/null
echo "chain ready in $DB"
