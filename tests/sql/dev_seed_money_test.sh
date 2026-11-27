#!/usr/bin/env bash
# T47: the richer DEV demo seed (db/seed_dev_demo_money.sql) on a THROWAWAY database, so it cannot rot.
#   chain (all migrations + demo seed) -> money seed -> post-check line -> second run changes nothing -> the app's own functions work on the data ->
#   refusals (no centre / a real login in the centre / a Stripe subscription) write nothing -> undo restores the starting counts -> seed again.
# Needs the scratch cluster of tests/sql/run.sh (port 54329). Between 16:00 and 24:00 UTC run it as PGTZ=Asia/Singapore (like run.sh).
set -euo pipefail
cd "$(dirname "$0")/../.."
export PGHOST="${PGHOST:-/var/lib/postgresql}" PGPORT="${PGPORT:-54329}" PGUSER="${PGUSER:-postgres}"
DB=td_seed_test; OWNER=00000000-0000-0000-0000-00000000d101; BILL=00000000-0000-0000-0000-00000000d108; CASH=00000000-0000-0000-0000-00000000d109
T1=00000000-0000-0000-0000-00000000d102
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; exit 1; }
q() { psql -qAt -v ON_ERROR_STOP=1 -d "${DB_USE:-$DB}" -c "$1"; }
as() { psql -qAt -v ON_ERROR_STOP=1 -d "${DB_USE:-$DB}" -c "select set_config('request.jwt.claims', json_build_object('sub', '$1', 'role', 'authenticated')::text, false)" -c "$2" | tail -n +2; }
fp() { q "select (select count(*) from students)||'/'||(select count(*) from lessons)||'/'||(select count(*) from households)||'/'||(select count(*) from memberships)||'/'||(select count(*) from org_settings)||'/'||(select count(*) from centre_invoices)||'/'||(select count(*) from centre_payments)||'/'||(select count(*) from centre_refunds)||'/'||(select count(*) from org_counters)||'/'||(select count(*) from auth.users)||'/'||(select count(*) from organisations)||'/'||(select count(*) from student_tutors)"; }
runseed() { psql -qAt -v ON_ERROR_STOP=1 -d "${DB_USE:-$DB}" -f db/seed_dev_demo_money.sql 2>&1 | grep -v "skipping" ; }
C=""; centre() { q "select id from organisations where kind = 'centre' limit 1"; }

bash tests/sql/build_chain.sh $DB >/dev/null 2>&1
C=$(centre); BEFORE=$(fp)

# ---- refusals first (nothing may be written)
for case in nocentre realmember stripe; do
  DB_USE=td_seed_refuse; export DB_USE
  if [ $case = nocentre ]; then bash tests/sql/build_chain.sh td_seed_refuse noseed >/dev/null 2>&1; else bash tests/sql/build_chain.sh td_seed_refuse >/dev/null 2>&1; fi
  if [ $case = realmember ]; then
    q "insert into auth.users(id, email) values ('00000000-0000-0000-0000-00000000f001', 'real.person@gmail.com')" >/dev/null
    q "insert into memberships(org_id, user_id, display_name, role, status) select id, '00000000-0000-0000-0000-00000000f001', 'Real Person', 'staff', 'active' from organisations where kind = 'centre'" >/dev/null
  fi
  if [ $case = stripe ]; then q "update org_subscriptions set stripe_subscription_id = 'sub_test_not_real' where org_id in (select id from organisations where kind = 'centre')" >/dev/null; fi
  B=$(fp)
  OUT=$(runseed || true)
  echo "$OUT" | grep -q "REFUSED" || fail "seed refuses ($case): $OUT"
  [ "$(fp)" = "$B" ] || fail "seed wrote something although it refused ($case)"
  pass "seed refuses and writes nothing: $case"
  unset DB_USE
done
psql -qAt -d postgres -c "drop database if exists td_seed_refuse" >/dev/null

# ---- the seed
OUT=$(runseed)
LINE=$(echo "$OUT" | grep '^SEED |' | tail -1)
echo "$LINE"
echo "$LINE" | grep -q '^SEED | OK' || fail "post-check line is not OK"
pass "post-check says SEED | OK"
for want in 'never-invoiced students=7' 'sibling-families=2' 'deposit-drafts-due=7' 'issued-unpaid-past-due=4' 'part-paid=1' 'credit-family-with-open-invoice=1' 'late-fee-proposals=4' 'left+paid=5' 'waived=1' 'refunds deposit r/a/p/c=1/1/1/1 credit r/a/p/c=1/1/1/1 four-eyes-ready=true' 'class-sessions=1' 'future-unassigned=1' 'settings=fixed/6000/monthly/1000/7/owner/tutors_direct/24'; do
  echo "$LINE" | grep -qF "$want" || fail "post-check misses: $want"
done
pass "post-check counts per category"
AFTER=$(fp)
OUT2=$(runseed); echo "$OUT2" | grep -q '^SEED | OK' || fail "second run: post-check not OK"
[ "$(fp)" = "$AFTER" ] || fail "second run changed something"
pass "running the seed twice changes nothing"

# ---- undo
psql -q -v ON_ERROR_STOP=1 -d $DB -f db/seed_dev_demo_money_down.sql 2>&1 | grep -v skipping | grep -q "removed" || fail "undo ran"
[ "$(q "select count(*) from students where id::text like '00000000-0000-0000-0000-0000000e01%'")" = 0 ] || fail "undo removed the demo students"
[ "$(fp)" = "$BEFORE" ] || fail "undo restores the starting counts ($BEFORE vs $(fp))"
pass "undo restores the starting counts and leaves the original demo alone"
psql -q -v ON_ERROR_STOP=1 -d $DB -f db/seed_dev_demo_money_down.sql >/dev/null 2>&1 || fail "undo is safe to run twice"
[ "$(fp)" = "$BEFORE" ] || fail "second undo changed something"
pass "undo twice is harmless"
LINE=$(runseed | grep '^SEED |' | tail -1); echo "$LINE" | grep -q '^SEED | OK' || fail "seed again after undo"
[ "$(q "select min(number_text) from centre_invoices where number_seq = 1")" = "DLC-1" ] || fail "numbers start from 1 again"
pass "seed again after undo (numbers start from DLC-1)"

# ---- the data is what the money screens expect
[ "$(q "select count(*) from centre_invoices where status = 'issued' and number_text !~ '^DLC-[0-9]+$'")" = 0 ] || fail "invoice numbers use the centre prefix and counter"
[ "$(q "select count(*) from centre_invoices where status = 'issued' and issue_date >= current_date")" = 0 ] || fail "issued invoices are in the past"
[ "$(q "select count(*) from centre_invoices where status = 'issued' and due_date >= current_date")" = 0 ] || fail "issued invoices are past due"
[ "$(q "select count(*) = max(number_seq) from centre_invoices where number_seq is not null")" = t ] || fail "numbers are gap-free"
pass "invoices: demo prefix, gap-free numbers, past issue and due dates"
PV=$(as $OWNER "select (p->'totals'->>'ready') || '/' || jsonb_array_length(p->'deposits') from (select centre_invoice_run_preview('$C', current_date) p) x")
[ "${PV%%/*}" -ge 5 ] && [ "${PV##*/}" -ge 5 ] || fail "this month's preview shows lesson invoices and deposit drafts ($PV)"
pass "the invoice run preview for this month: $PV (lesson invoices / deposit drafts)"
RUN=$(as $OWNER "select (r->>'created') from (select centre_invoice_run_create_drafts('$C', current_date) r) x")
[ "$RUN" -ge 5 ] || fail "the invoice run creates drafts ($RUN)"
[ "$(q "select count(*) from centre_invoices where kind = 'deposit' and status = 'draft'")" -ge 5 ] || fail "deposit drafts are raised with the run"
pass "the invoice run creates $RUN lesson drafts and the S\$60 deposit drafts"
# family credit: use it on the second unpaid invoice, then undo
HH=$(q "select household_id from students where name = 'Irfan Rahman'")
USED=$(as $OWNER "select centre_apply_family_credit('$C', '$HH')->>'applied_cents'")
[ "$USED" = 2500 ] || fail "use credit applies S\$25 (got $USED)"
PAY=$(q "select id from centre_payments where method = 'family_credit' and household_id = '$HH'")
UND=$(as $OWNER "select centre_undo_application('$PAY', 'test undo')->>'undone_cents'")
[ "$UND" = 2500 ] || fail "undo of the credit (got $UND)"
[ "$(q "select centre_credit_balance('$C', '$HH')")" = 2500 ] || fail "credit is back after the undo"
pass "use family credit and undo it"
# late fee: approve one proposal
FEE=$(q "select id from centre_late_fees where status = 'proposed' order by fee_date limit 1")
as $OWNER "select centre_late_fee_approve('$FEE')" >/dev/null
[ "$(q "select count(*) from centre_invoices where kind = 'late_fee' and status = 'issued'")" = 1 ] || fail "approving a late fee issues its invoice"
pass "approve a late fee proposal"
# a student who has left: the deposit release proposal is ready; the cancelled refund can be asked again; the requested one is open
S1=$(q "select id from students where name = 'Noah Pang'")
[ "$(as $BILL "select centre_deposit_release_proposal('$S1')->>'state'")" = ready ] || fail "left student with a paid deposit: release proposal is ready"
S2=$(q "select id from students where name = 'Olivia Quek'")
[ "$(as $BILL "select centre_deposit_release_proposal('$S2')->>'state'")" = open_refund ] || fail "requested refund shows as open"
pass "deposit release proposals: ready / open refund"
# the owner approves a requested refund; staff can't (rule: owner)
RQ=$(q "select id from centre_refunds where request_key = 't47-dep-requested'")
as $CASH "select centre_refund_approve('$RQ')" >/dev/null 2>&1 && fail "staff approved a refund although the centre says the owner" || true
as $OWNER "select centre_refund_approve('$RQ', 'ok')" >/dev/null
[ "$(q "select centre_refund_state('$RQ')")" = approved ] || fail "the owner approves"
pass "refund approval follows the setting (owner)"
# four-eyes is available, and falls back when the second approver goes
as $OWNER "select org_save_settings('$C', jsonb_set(org_settings_on('$C', current_date), '{billing,deposit,refund_approved_by}', '\"four_eyes\"'), current_date + 1)" >/dev/null
[ "$(q "select org_four_eyes_ready('$C')")" = t ] || fail "four-eyes preconditions are met"
pass "four-eyes can be switched on (owner + staff who issue invoices + staff who record payments)"
# the alternate case written in the guide: remove ONE of the two people who record payments and four-eyes stays; remove both and it falls back to "owner"
as $OWNER "select org_save_settings('$C', jsonb_set(org_settings_on('$C', current_date), '{billing,deposit,refund_approved_by}', '\"four_eyes\"'), current_date)" >/dev/null
[ "$(as $OWNER "select centre_refund_rule('$C', current_date)")" = four_eyes ] || fail "four-eyes is in force once saved"
q "delete from memberships where org_id = '$C' and user_id = '$CASH'" >/dev/null
[ "$(as $OWNER "select centre_refund_rule('$C', current_date)")" = four_eyes ] || fail "one holder of Record payments left: four-eyes stays"
q "delete from memberships where org_id = '$C' and user_id = '00000000-0000-0000-0000-00000000d106'" >/dev/null
[ "$(as $OWNER "select centre_refund_rule('$C', current_date)")" = owner ] || fail "no one else records payments: the rule falls back to the owner"
[ "$(q "select count(*) from org_notifications where org_id = '$C' and kind = 'four_eyes_fallback'")" -ge 1 ] || fail "the owner gets a notice"
pass "four-eyes fallback: removing both holders of Record payments sends refund approval back to the owner (with a notice)"
# tutors: assigned lessons can be cancelled, the unassigned student's lesson is refused
L_OK=$(q "select l.id from lessons l join students s on s.id = l.student_id where s.name = 'Cyrus Ho' and l.lesson_date = current_date + 4")
[ "$(as $T1 "select tutor_cancel_lesson('$L_OK', 'test')->>'cancelled'")" = true ] || fail "tutor cancels an assigned lesson"
L_NO=$(q "select l.id from lessons l join students s on s.id = l.student_id where s.name = 'Evan Soh'")
OUT=$(as $T1 "select tutor_cancel_lesson('$L_NO', 'test')" 2>&1 || true)
echo "$OUT" | grep -q "NOT_FOUND" || fail "the unassigned student's lesson is refused ($OUT)"
pass "tutor.one: assigned lesson can be cancelled; the unassigned student's lesson is refused"

