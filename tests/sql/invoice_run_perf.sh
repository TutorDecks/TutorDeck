#!/usr/bin/env bash
# Timing of the invoice run at the size of a real centre: ~400 students, ~300 families, ~3,200 lessons in one month, all FAKE names.
# Builds its own throwaway database (td_perf) on the same local Postgres as tests/sql/run.sh; never touches a Supabase project.
#   bash tests/sql/invoice_run_perf.sh        (cluster: /var/lib/postgresql/td16, port 54329)
set -euo pipefail
cd "$(dirname "$0")/../.."
export PGHOST="${PGHOST:-/var/lib/postgresql}" PGPORT="${PGPORT:-54329}" PGUSER="${PGUSER:-postgres}"
DB=td_perf
P="psql -q -v ON_ERROR_STOP=1 -d $DB"
psql -qAt -d postgres -c "drop database if exists $DB" -c "create database $DB"
$P -f tests/sql/supabase_shim.sql
$P -f db/baseline_2026-11.sql
for m in org_foundation billing attendance tutor_access org_delete function_lockdown org_separation staff_home staff_students staff_attendance staff_charges staff_trials staff_timetable centre_money centre_invoice_run; do
  $P -f db/migration_$m.sql >/dev/null 2>&1
done
$P <<'SQL' >/dev/null
insert into auth.users(id, email) values ('00000000-0000-0000-0000-0000000000f1', 'perf.owner@centre.test');
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f1","role":"authenticated"}', false);
create temp table k as select org_create_centre('Perf Centre', '{"schema_version":1,"preset":"centre",
  "profile":{"gst_registered":true,"gst_rate_bp":900,"gst_inclusive":false,"invoice_prefix":"INV","next_invoice_number":1},
  "calendar":{},"billing":{"model":"postpaid_lessons","sibling_discount":{"type":"percent","percent_bp":1000,"fixed_cents":500},"one_off_fees":{"registration_cents":3000,"materials_cents":0,"deposit_cents":0}},
  "invoicing":{"grouping":"family","due_days":7,"review_before_sending":true},
  "payments":{"modes":["manual_paynow"]},"lessons":{},"tutor_pay":{"mode":"report","payable_when":"parent_paid"},"data":{}}'::jsonb) as org;
grant select on k to public;
reset role;
-- 300 families, 400 students (some families have 2-3 children), 8 lessons each in last month, a few absent with no charge yet
insert into households(id, org_id, name) select ('00000000-0000-0000-0001-' || lpad(g::text, 12, '0'))::uuid, (select org from k), 'Fake Family ' || g from generate_series(1, 300) g;
insert into students(id, tutor_id, org_id, name, household_id, created_at)
  select ('00000000-0000-0000-0002-' || lpad(g::text, 12, '0'))::uuid, '00000000-0000-0000-0000-0000000000f1', (select org from k), 'Fake Student ' || g,
         ('00000000-0000-0000-0001-' || lpad((case when g <= 300 then g else (g - 300) * 2 end)::text, 12, '0'))::uuid, '2026-01-01'::timestamptz + (g || ' hours')::interval
    from generate_series(1, 400) g;
insert into lessons(tutor_id, org_id, student_id, lesson_date, start_time, end_time, rate, amount, status, attendance, compensation, subject)
  select '00000000-0000-0000-0000-0000000000f1', (select org from k), ('00000000-0000-0000-0002-' || lpad(s::text, 12, '0'))::uuid,
         date_trunc('month', current_date - interval '1 month')::date + (l % 27), '16:00', '17:00', 50, 50,
         case when l = 7 and s % 25 = 0 then 'cancelled' else 'done' end, case when l = 7 and s % 25 = 0 then 'late_cancelled' end, null, 'Math'
    from generate_series(1, 400) s cross join generate_series(1, 8) l;
analyze;
SQL
echo "students: $(psql -qAt -d $DB -c 'select count(*) from students'), lessons: $(psql -qAt -d $DB -c 'select count(*) from lessons')"
run() { psql -qAt -d $DB -c "set role authenticated" -c "select set_config('request.jwt.claims','{\"sub\":\"00000000-0000-0000-0000-0000000000f1\",\"role\":\"authenticated\"}',false)" -c "\\timing on" -c "$1" 2>&1 | grep -E "^[0-9]|Time:|ERROR|ready" ; }
ORG="(select org from k)"
KEEP=$(psql -qAt -d $DB -c "select id from organisations where kind='centre' limit 1")
M="date_trunc('month', current_date - interval '1 month')::date"
echo "preview:        $(run "select jsonb_array_length(j->'ready') || ' ready, ' || jsonb_array_length(j->'held_back') || ' held back, ' || length(j::text) || ' bytes' from (select centre_invoice_run_preview('$KEEP', $M) j) x" | tr '\n' ' ')"
echo "create drafts:  $(run "select centre_invoice_run_create_drafts('$KEEP', $M)->>'created'" | tr '\n' ' ')"
echo "run again:      $(run "select centre_invoice_run_create_drafts('$KEEP', $M)->>'created'" | tr '\n' ' ')"
echo "approve all:    $(run "select centre_invoice_approve_all('$KEEP', $M)->>'issued'" | tr '\n' ' ')"
echo "preview after:  $(run "select jsonb_array_length(j->'ready') from (select centre_invoice_run_preview('$KEEP', $M) j) x" | tr '\n' ' ')"
