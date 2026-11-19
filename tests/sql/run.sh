#!/usr/bin/env bash
# Runs the centre migration + scenario tests on a THROWAWAY local Postgres (never the live Supabase DB).
# Needs a local server; set PGHOST/PGPORT/PGUSER (defaults below match the dev container).
set -euo pipefail
cd "$(dirname "$0")/../.."
export PGHOST="${PGHOST:-/var/lib/postgresql}" PGPORT="${PGPORT:-54329}" PGUSER="${PGUSER:-postgres}"
DB=td_centres_test
psql -qAt -d postgres -c "drop database if exists $DB" -c "create database $DB"
psql -q -v ON_ERROR_STOP=1 -d $DB -f tests/sql/supabase_shim.sql
psql -q -v ON_ERROR_STOP=1 -d $DB -f db/migration_centres.sql
psql -q -v ON_ERROR_STOP=1 -d $DB -f db/migration_centres.sql      # must be safe to run twice
psql -qAt -v ON_ERROR_STOP=1 -d $DB -f tests/sql/centres_test.sql
