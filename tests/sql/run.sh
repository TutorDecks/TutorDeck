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
$P -f db/migration_invites.sql
$P -f db/migration_invites.sql                              # safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/invites_test.sql
$P -f db/migration_invites_down.sql
$P -f db/migration_org_separation_down.sql
$P -f db/migration_org_separation.sql                       # and again, so the shipped state is what the undo chain below unwinds
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
