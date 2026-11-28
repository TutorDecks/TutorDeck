#!/usr/bin/env bash
# T52: the fresh DEV demo centre (db/seed_dev_demo_fresh.sql) on a THROWAWAY database, so it cannot rot.
#   full chain (every migration incl. bundles 6-7 + the old demo seed) -> fresh seed -> post-check -> second run changes nothing -> centre stays in SETUP and a
#   settings save applies TODAY -> the app's functions work for each login -> refusals write nothing -> undo restores the starting counts -> seed again.
# Needs the scratch cluster of tests/sql/run.sh (port 54329). Between 16:00 and 24:00 UTC run it as PGTZ=Asia/Singapore (like run.sh).
set -euo pipefail
cd "$(dirname "$0")/../.."
export PGHOST="${PGHOST:-/var/lib/postgresql}" PGPORT="${PGPORT:-54329}" PGUSER="${PGUSER:-postgres}"
DB=td_fresh_test; OWNER=00000000-0000-0000-0000-00000000d201; BILL=00000000-0000-0000-0000-00000000d202; CASH=00000000-0000-0000-0000-00000000d203
FRONT=00000000-0000-0000-0000-00000000d204; T1=00000000-0000-0000-0000-00000000d205; OLDOWNER=00000000-0000-0000-0000-00000000d101
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; exit 1; }
q() { psql -qAt -v ON_ERROR_STOP=1 -d "${DB_USE:-$DB}" -c "$1"; }
as() { psql -qAt -v ON_ERROR_STOP=1 -d "${DB_USE:-$DB}" -c "select set_config('request.jwt.claims', json_build_object('sub', '$1', 'role', 'authenticated')::text, false)" -c "$2" | tail -n +2; }
fp() { q "select (select count(*) from students)||'/'||(select count(*) from lessons)||'/'||(select count(*) from recurring_slots)||'/'||(select count(*) from households)||'/'||(select count(*) from memberships)||'/'||(select count(*) from org_settings)||'/'||(select count(*) from auth.users)||'/'||(select count(*) from organisations)||'/'||(select count(*) from student_tutors)||'/'||(select count(*) from org_plans)"; }
runseed() { psql -qAt -v ON_ERROR_STOP=1 -d "${DB_USE:-$DB}" -f db/seed_dev_demo_fresh.sql 2>&1 | grep -v "skipping" ; }
chain() {  # chain <db> [noseed]
  bash tests/sql/build_chain.sh "$1" noseed >/dev/null 2>&1
  P="psql -q -v ON_ERROR_STOP=1 -d $1"
  for m in b5_fix tutor_own_lessons import centre_tutor_pay statement_matching invoice_email makeup_credits tutor_link_propose past_lessons tutor_own_pay org_export; do $P -f db/migration_$m.sql >/dev/null; done
  $P -f tests/sql/pack_shim.sql >/dev/null
  if [ "${2:-}" != noseed ]; then $P -f db/seed_dev_demo.sql >/dev/null; fi
}

chain $DB
BEFORE=$(fp); OLDC=$(q "select o.id from organisations o join memberships m on m.org_id = o.id and m.user_id = '$OLDOWNER' where o.kind = 'centre'")
OLDFP=$(q "select (select count(*) from lessons where org_id = '$OLDC')||'/'||(select count(*) from students where org_id = '$OLDC')||'/'||(select count(*) from org_settings where org_id = '$OLDC')||'/'||(select count(*) from memberships where org_id = '$OLDC')")

# ---- refusals first (nothing may be written)
for case in nodemo realmember stripe halfrun; do
  DB_USE=td_fresh_refuse; export DB_USE
  if [ $case = nodemo ]; then chain td_fresh_refuse noseed; else chain td_fresh_refuse; fi
  if [ $case = realmember ]; then
    q "insert into auth.users(id, email) values ('00000000-0000-0000-0000-00000000f001', 'real.person@gmail.com')" >/dev/null
    q "insert into memberships(org_id, user_id, display_name, role, status) select id, '00000000-0000-0000-0000-00000000f001', 'Real Person', 'staff', 'active' from organisations where kind = 'centre'" >/dev/null
  fi
  if [ $case = stripe ]; then q "update org_subscriptions set stripe_subscription_id = 'sub_test_not_real' where org_id in (select id from organisations where kind = 'centre')" >/dev/null; fi
  if [ $case = halfrun ]; then q "insert into auth.users(id, email) values ('$OWNER', 'fresh.owner@example.test')" >/dev/null; fi
  B=$(fp)
  OUT=$(runseed || true)
  echo "$OUT" | grep -q "REFUSED" || fail "seed refuses ($case): $OUT"
  [ "$(fp)" = "$B" ] || fail "seed wrote something although it refused ($case)"
  pass "seed refuses and writes nothing: $case"
  unset DB_USE
done
psql -qAt -d postgres -c "drop database if exists td_fresh_refuse" >/dev/null

# ---- the seed
OUT=$(runseed)
LINE=$(echo "$OUT" | grep '^SEED FRESH |' | tail -1)
echo "$LINE"
echo "$LINE" | grep -q '^SEED FRESH | OK' || fail "post-check line is not OK ($OUT)"
for want in 'status=setup' 'owner=1 billing-staff=1 cashier=1 frontdesk=1 tutors=2' 'students=8 families=6 slots=8' 'invoices=0 payments=0'; do
  echo "$LINE" | grep -qF "$want" || fail "post-check misses: $want"
done
pass "post-check says SEED FRESH | OK"
C=$(q "select o.id from organisations o join memberships m on m.org_id = o.id and m.user_id = '$OWNER' where o.kind = 'centre'")
[ "$(q "select count(*) from organisations where kind = 'centre'")" = 2 ] || fail "two centres now"
[ "$(q "select count(*) from lessons where org_id = '$OLDC'")/$(q "select count(*) from students where org_id = '$OLDC'")/$(q "select count(*) from org_settings where org_id = '$OLDC'")/$(q "select count(*) from memberships where org_id = '$OLDC'")" = "$OLDFP" ] || fail "the old demo centre changed"
pass "a second centre exists; the old demo centre is untouched"
AFTER=$(fp)
OUT2=$(runseed); echo "$OUT2" | grep -q '^SEED FRESH | OK' || fail "second run: post-check not OK"
[ "$(fp)" = "$AFTER" ] || fail "second run changed something"
pass "running the seed twice changes nothing"

# ---- the centre is in SETUP and a settings save takes effect TODAY (the point of the seed)
[ "$(q "select status from organisations where id = '$C'")" = setup ] || fail "centre is in setup"
V=$(as $OWNER "select org_save_settings('$C', jsonb_set(jsonb_set(org_settings_on('$C', current_date), '{billing,late_fee}', '{\"enabled\":true,\"repeat\":\"monthly\",\"type\":\"fixed\",\"amount_cents\":1000,\"after_days\":0,\"cap_cents\":0,\"show_as\":\"own_invoice\",\"waived_by\":\"owner\"}'::jsonb), '{billing,credit_expiry_days}', '7'::jsonb), current_date)")
[ "$(as $OWNER "select org_settings_on('$C', current_date)#>>'{billing,late_fee,enabled}'")" = true ] || fail "a billing setting saved today is in force today"
as $OWNER "select org_save_settings('$C', org_settings_on('$C', current_date), current_date - 5)" >/dev/null || fail "back-dating is allowed in setup"
[ "$(q "select min(effective_from) from org_settings where org_id = '$C' and version = (select max(version) from org_settings where org_id = '$C')")" = "$(q "select current_date - 5")" ] || fail "back-dated save keeps its past date"
pass "in setup: a billing setting saved today applies today, and back-dating works"
# the same save on the OLD (launched) demo centre is not allowed to take effect today / back-date
as $OLDOWNER "select org_save_settings('$OLDC', org_settings_on('$OLDC', current_date), current_date - 5)" >/dev/null 2>&1 && fail "the launched centre must refuse back-dating" || true
pass "contrast: the launched demo centre refuses back-dating"

# ---- the people and what each may do
q "select permissions from memberships where org_id = '$C' and user_id = '$BILL'" | grep -q '^{issue_invoices}$' || fail "billing staff holds issue_invoices only"
q "select permissions from memberships where org_id = '$C' and user_id = '$CASH'" | grep -q '^{record_payments}$' || fail "cashier holds record_payments only"
[ "$(q "select count(*) from memberships where org_id = '$C' and user_id = '$FRONT' and permissions @> array['manage_students','manage_timetable'] and cardinality(permissions) = 2")" = 1 ] || fail "front desk"
pass "staff permissions are exactly: billing = issue_invoices, cashier = record_payments, front desk = students + timetable"
[ "$(as $OWNER "select (centre_invoice_run_preview('$C', current_date)->'totals'->>'ready')::int")" -ge 1 ] || fail "invoice run preview finds attended lessons"
pass "invoice run preview finds billable (attended) lessons"
RUN=$(as $OWNER "select (r->>'created') from (select centre_invoice_run_create_drafts('$C', current_date) r) x")
[ "$RUN" -ge 1 ] || fail "invoice run makes drafts ($RUN)"
pass "invoice run creates $RUN draft(s)"
# a tutor sees and marks only their own recent lessons
[ "$(as $T1 "select count(*) from tutor_my_lessons(current_date - 14, current_date + 14)")" -ge 3 ] || fail "tutor.one sees their lessons"
L=$(q "select id from lessons where org_id = '$C' and taught_by = (select id from memberships where org_id = '$C' and user_id = '$T1') and attendance is null and lesson_date between current_date - 13 and current_date - 1 order by lesson_date limit 1")
[ -n "$L" ] || fail "tutor.one has an unmarked recent lesson"
as $T1 "select tutor_mark_attendance('$L', 'attended', 'test')" >/dev/null || fail "tutor.one marks a recent lesson"
pass "tutor.one sees own lessons and can mark a recent unmarked one"
[ "$(q "select count(*) from lessons where org_id = '$C' and attendance = 'absent'")" = 1 ] && [ "$(q "select count(*) from lessons where org_id = '$C' and attendance = 'cancelled_early'")" = 1 ] || fail "one absent and one cancelled-in-time lesson are marked"
pass "one absent and one cancelled-in-time lesson are already marked"

# ---- undo
psql -q -v ON_ERROR_STOP=1 -d $DB -f db/seed_dev_demo_fresh_down.sql 2>&1 | grep -v skipping | grep -q "removed" || fail "undo ran"
[ "$(q "select count(*) from auth.users where email like 'fresh.%@example.test'")" = 0 ] || fail "undo removed the logins"
[ "$(q "select count(*) from organisations where kind = 'centre'")" = 1 ] || fail "undo removed the centre (also with invoices a tester made)"
[ "$(fp)" = "$BEFORE" ] || fail "undo restores the starting counts ($BEFORE vs $(fp))"
pass "undo removes the centre (with the tester's invoice drafts) and restores the starting counts"
psql -q -v ON_ERROR_STOP=1 -d $DB -f db/seed_dev_demo_fresh_down.sql >/dev/null 2>&1 || fail "undo is safe to run twice"
[ "$(fp)" = "$BEFORE" ] || fail "second undo changed something"
pass "undo twice is harmless"
LINE=$(runseed | grep '^SEED FRESH |' | tail -1); echo "$LINE" | grep -q '^SEED FRESH | OK' || fail "seed again after undo"
pass "seed again after undo"
psql -qAt -d postgres -c "drop database if exists td_fresh_test" >/dev/null
