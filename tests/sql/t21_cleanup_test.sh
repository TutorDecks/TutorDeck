#!/usr/bin/env bash
# DEV-ONLY clean-up rehearsal for T21: tests docs/orchestrator/t21/{preview,delete,postcheck}.sql on a THROWAWAY local Postgres (never DEV or LIVE).
# Usage: bash tests/sql/t21_cleanup_test.sh   (needs the cluster of tests/sql/run.sh: PGHOST=/var/lib/postgresql PGPORT=54329)
set -uo pipefail
cd "$(dirname "$0")/../.."
export PGHOST="${PGHOST:-/var/lib/postgresql}" PGPORT="${PGPORT:-54329}" PGUSER="${PGUSER:-postgres}"
DB=t21_test; D=docs/orchestrator/t21; W=$(mktemp -d); FAILS=0
P="psql -q -v ON_ERROR_STOP=1 -d $DB"
pass() { echo "PASS $1"; }; fail() { echo "FAIL $1"; FAILS=$((FAILS+1)); }
rebuild() {
  psql -qAt -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null 2>&1
  $P -f tests/sql/supabase_shim.sql >/dev/null 2>&1 && $P -f db/baseline_2026-11.sql >/dev/null 2>&1 && $P -f tests/sql/org_seed.sql >/dev/null 2>&1 || { echo "setup failed"; exit 2; }
  for m in org_foundation billing attendance tutor_access org_delete function_lockdown; do $P -f db/migration_$m.sql >/dev/null 2>&1 || { echo "migration $m failed"; exit 2; }; done
  $P -f tests/sql/t21_seed.sql >/dev/null 2>&1 || { echo "seed failed"; $P -f tests/sql/t21_seed.sql 2>&1 | tail -5; exit 2; }
}
# the markdown must carry exactly the tested SQL
for f in preview delete postcheck; do
  python3 - docs/orchestrator/T21-cleanup.md "$D/$f.sql" <<'PY' && pass "T21-cleanup.md contains $f.sql verbatim" || fail "T21-cleanup.md contains $f.sql verbatim"
import sys; md=open(sys.argv[1]).read(); sql=open(sys.argv[2]).read().strip()
sys.exit(0 if sql in md else 1)
PY
done 2>/dev/null
paste_this() { psql -qAt -F'|' -d $DB -f $D/preview.sql | awk -F'|' '$2=="PASTE_THIS"{print $4}'; }
# build a runnable delete script: $1 = out file, $2 = dry_run (true/false), $3 = expected literal
mk() { python3 - "$D/delete.sql" "$1" "$2" "$3" <<'PY'
import sys; s=open(sys.argv[1]).read()
s=s.replace("v_dry_run  boolean := true;","v_dry_run  boolean := %s;" % sys.argv[3])
s=s.replace("v_expected jsonb   := null;","v_expected jsonb   := %s;" % sys.argv[4])
open(sys.argv[2],'w').write(s)
PY
}
# everything of the demo + decoy data, as one fingerprint (rows that must never change)
# the throwaway's two organisation ids are captured after each rebuild (EXC); everything else must never change
fp() { psql -qAt -d $DB -c "
 select md5(string_agg(h, '|' order by h)) from (
  select 'auth:' || md5(a::text) h from auth.users a where a.email not like 't2-throwaway-8f3c1d%'
  union all select 'org:' || md5(o::text) from organisations o where o.id not in ($EXC)
  union all select 'stu:' || md5(s::text) from students s where s.tutor_id <> '00000000-0000-0000-0000-0000000a0001'
  union all select 'les:' || md5(l::text) from lessons l where l.tutor_id <> '00000000-0000-0000-0000-0000000a0001'
  union all select 'slot:' || md5(l::text) from recurring_slots l where l.tutor_id <> '00000000-0000-0000-0000-0000000a0001'
  union all select 'mem:' || md5(m::text) from memberships m where m.org_id not in ($EXC)
  union all select 'prof:' || md5(p::text) from profiles p where p.id <> '00000000-0000-0000-0000-0000000a0001'
  union all select 'fee:' || md5(f::text) from platform_fee_snapshots f where f.org_id not in ($EXC)
  union all select 'set:' || md5(f::text) from org_settings f where f.org_id not in ($EXC)
  union all select 'plan:' || md5(f::text) from org_plans f where f.org_id not in ($EXC)
  union all select 'sub:' || md5(f::text) from org_subscriptions f where f.org_id not in ($EXC)
  union all select 'hh:' || md5(f::text) from households f where f.org_id not in ($EXC)
  union all select 'aud:' || md5(x::text) from audit_log x where x.org_id is not null and x.org_id not in ($EXC)
 ) z"; }
setexc() { EXC=$(psql -qAt -d $DB -c "select string_agg(quote_literal(org_id::text), ',') from memberships where user_id = '00000000-0000-0000-0000-0000000a0001'"); }

# ---------------------------------------------------------------- 1. the preview finds exactly the throwaway
rebuild; setexc
OUT=$(psql -qAt -F'|' -d $DB -f $D/preview.sql)
echo "$OUT" | grep -q '^20|ALL CHECKS|.*|PASS' && pass "preview: all checks PASS on the throwaway" || { fail "preview: all checks PASS"; echo "$OUT"; }
echo "$OUT" | grep -q '8f3c1d' && ! echo "$OUT" | grep -q 't2-throwaway-old\|t2-throwaway-next\|example.com\|my-t2\|centre.owner' && pass "preview names only the throwaway login" || fail "preview names only the throwaway login"
echo "$OUT" | grep '^30|' | tr '\n' ' '; echo
PASTE=$(paste_this); [ -n "$PASTE" ] && pass "preview gives a PASTE_THIS value" || fail "PASTE_THIS"
BEFORE=$(fp)
PRE_COUNTS=$(psql -qAt -d $DB -c "select (select count(*) from auth.users), (select count(*) from organisations), (select count(*) from audit_log)")

# ---------------------------------------------------------------- 2. refusals leave everything untouched
mk $W/noexp.sql true null; R=$($P -f $W/noexp.sql 2>&1); echo "$R" | grep -q "paste the PASTE_THIS" && pass "refuses without a pasted preview" || fail "refuses without a pasted preview"
mk $W/bad.sql true "'{\"user\":\"00000000-0000-0000-0000-0000000a0001\",\"solo_org\":\"00000000-0000-0000-0000-000000000001\",\"centre_org\":\"00000000-0000-0000-0000-000000000002\",\"rows\":{}}'::jsonb"
R=$($P -f $W/bad.sql 2>&1); echo "$R" | grep -q "ids in v_expected do not match" && pass "refuses a preview for other ids" || fail "refuses a preview for other ids"
BADROWS=$(echo "$PASTE" | sed 's/"students": [0-9]*/"students": 99/'); mk $W/rows.sql true "$BADROWS"
R=$($P -f $W/rows.sql 2>&1); echo "$R" | grep -q "differ from the approved preview" && pass "refuses when row counts differ from the preview" || { fail "row-count mismatch refusal"; echo "$R" | tail -3; }
[ "$(fp)" = "$BEFORE" ] && pass "refusals changed nothing" || fail "refusals changed nothing"

# ---------------------------------------------------------------- 3. dry run does everything, then rolls back
mk $W/dry.sql true "$PASTE"; R=$($P -f $W/dry.sql 2>&1)
echo "$R" | grep -q "DRY RUN OK" && pass "dry run reaches the end and reports DRY RUN OK" || { fail "dry run"; echo "$R" | tail -5; }
[ "$(psql -qAt -d $DB -c "select (select count(*) from auth.users), (select count(*) from organisations), (select count(*) from audit_log)")" = "$PRE_COUNTS" ] && [ "$(fp)" = "$BEFORE" ] && pass "dry run rolled everything back" || fail "dry run rolled everything back"
[ "$(paste_this)" = "$PASTE" ] && pass "preview is identical after the dry run" || fail "preview identical after dry run"

# ---------------------------------------------------------------- 4. dangerous situations abort
guard() { # name, setup sql, expected message fragment ; each on a fresh database
  rebuild; local pv; pv=$(paste_this); psql -q -d $DB -c "$2" >/dev/null 2>&1; local b; b=$(psql -qAt -d $DB -c "select (select count(*) from auth.users), (select count(*) from organisations), (select count(*) from audit_log)")
  mk $W/g.sql false "$pv"; local r; r=$($P -f $W/g.sql 2>&1)
  if echo "$r" | grep -q "$3" && [ "$(psql -qAt -d $DB -c "select (select count(*) from auth.users), (select count(*) from organisations), (select count(*) from audit_log)")" = "$b" ]; then pass "aborts, nothing changed: $1"; else fail "$1"; echo "$r" | tail -3; fi; }
T2=00000000-0000-0000-0000-0000000a0001
guard "a second member in the centre" "insert into memberships(org_id, user_id, display_name, role) select o.id, '00000000-0000-0000-0000-0000000d0002', 'Intruder', 'tutor' from organisations o where o.trading_name = 'T2 Test Centre' and o.created_at = '2026-11-24 11:28:50+00'" "someone else"
guard "a pending invite in the centre" "insert into memberships(org_id, invited_email, display_name, role, status) select o.id, 'x@y.test', 'Inv', 'tutor', 'invited' from organisations o where o.created_at = '2026-11-24 11:28:50+00'" "someone else"
guard "a Stripe customer on the solo org" "update org_subscriptions set stripe_customer_id = 'cus_x' where org_id = org_personal('$T2')" "Stripe"
guard "a Google Calendar link" "insert into gcal_links(tutor_id, google_email, refresh_enc) values ('$T2', 'a@b.test', 'x')" "Google Calendar"
guard "a second login matching the pattern" "insert into auth.users(id, email, created_at) values (gen_random_uuid(), 't2-throwaway-dup@example.test', '2026-11-24 12:00+00')" "logins match"
guard "the throwaway is a platform admin" "insert into platform_admins(user_id) values ('$T2')" "platform admin"
guard "the throwaway also created another organisation" "insert into organisations(kind, preset, trading_name, created_by) values ('centre','centre','Other','$T2')" "2 organisations\|created another\|organisations (need exactly 2)\|something"
guard "another organisation's grant points at the login" "insert into support_access_grants(org_id, granted_by, reason, expires_at) select id, '$T2', 'x', now() + interval '1 day' from organisations where trading_name = 'Demo Learning Centre'" "point at the login"
guard "a storage file under the login's folder" "create schema storage; create table storage.objects(name text); insert into storage.objects values ('$T2/receipt.png')" "storage file"
guard "not the DEV project (demo logins missing)" "update auth.users set email = 'zz-' || email where email in ('centre.owner@example.test','tutor.one@example.test','tutor.two@example.test','both.tutor@example.test','solo.tutor@example.test')" "DEV project"
guard "centre renamed (not 'T2 Test Centre')" "update organisations set trading_name = 'Real Centre' where created_at = '2026-11-24 11:28:50+00'" "1 solo + 1 centre"
guard "a student added since the preview" "insert into students(tutor_id, name) values ('$T2', 'Late Kid')" "differ from the approved preview"

# ---------------------------------------------------------------- 5. the real run
rebuild; setexc; PASTE=$(paste_this); BEFORE=$(fp); mk $W/real.sql false "$PASTE"; R=$($P -f $W/real.sql 2>&1)
echo "$R" | grep -q "T21 DONE" && pass "real run completes" || { fail "real run"; echo "$R" | tail -5; }
[ "$(fp)" = "$BEFORE" ] && pass "demo logins, demo centre, solo tutor data and decoys are byte-for-byte unchanged" || fail "demo/decoy data unchanged"
python3 - "$D/postcheck.sql" "$PASTE" "$W/post.sql" <<'PY'
import sys,json,re
sql=open(sys.argv[1]).read(); lit=sys.argv[2]; j=json.loads(lit[1:lit.index("'::jsonb")])
sql=sql.replace("'00000000-0000-0000-0000-000000000000'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'paste-the-email-here'",
  "'%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'" % (j['user'], j['solo_org'], j['centre_org'], j['email']))
open(sys.argv[3],'w').write(sql)
PY
POST=$(psql -qAt -F'|' -d $DB -f $W/post.sql); echo "$POST" | grep -q '|FAIL|' && { fail "postcheck all PASS"; echo "$POST"; } || pass "postcheck: every line PASS"
echo "$POST" | grep -q "ALL CHECKS|.*|PASS" && pass "postcheck summary PASS" || fail "postcheck summary"
[ "$(psql -qAt -d $DB -c "select count(*) from auth.users where email like 't2-throwaway-8f3c1d%'")" = 0 ] && pass "login gone" || fail "login gone"
[ "$(psql -qAt -d $DB -c "select count(*) from audit_log where action='org_deleted' and org_id is null and actor is null")" = 2 ] && pass "two anonymous org_deleted rows kept (solo + centre)" || fail "anonymous audit rows"
R=$($P -f $W/real.sql 2>&1); echo "$R" | grep -q "ABORT" && pass "running it a second time aborts harmlessly" || fail "second run"
psql -qAt -d $DB -c "select 1" >/dev/null; psql -qAt -d $DB -c "set client_min_messages=warning;" >/dev/null
echo; [ $FAILS -eq 0 ] && echo "ALL T21 TESTS PASSED" || { echo "$FAILS FAILED"; exit 1; }
