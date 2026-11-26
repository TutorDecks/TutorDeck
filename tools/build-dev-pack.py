#!/usr/bin/env python3
"""Builds docs/orchestrator/dev-apply-pack.sql: every migration that is not yet on the DEV project, in the exact order
tests/sql/run.sh applies them, plus the demo staff logins and a read-only pre-check / post-check.

    python3 tools/build-dev-pack.py            # writes the file
    python3 tools/build-dev-pack.py --check    # exits 1 if the file on disk is out of date

The order is READ FROM tests/sql/run.sh so the pack can never drift from what the tests prove.
DEV already has (do not list here): the migrations in ON_DEV below. Everything after them in run.sh goes into the pack."""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs/orchestrator/dev-apply-pack.sql")
ON_DEV = ["org_foundation", "billing", "attendance", "tutor_access", "org_delete", "function_lockdown", "org_separation"]

# which branch each file came from (for the headers only)
BRANCH = {
    "staff_home": "t3-1-staff-home", "staff_students": "t3-2-students", "staff_attendance": "t3-3-attendance", "staff_charges": "t3-4-charges",
    "staff_trials": "t3-5-trials", "staff_timetable": "t3-6-timetable", "staff_slots": "t3-7-slots", "staff_reassign": "t3-8-reassign",
    "tutor_schedule": "t6-1-tutor-schedule", "money_settings": "t4-s0-settings", "centre_money": "t4-s1-tables",
    "centre_invoice_run": "t4-s2-invoice-run", "centre_payments": "t4-s3-payments", "invites": "t7-2-invites", "fee_050": "t30-fee-050",
    "centre_billing_method": "t31a-centre-invoice-billing", "centre_billing_start": "t36-billing-start", "tutor_profile": "t24c-1-profile",
    "tutor_payout": "t24c-2-payout", "payout_permission": "t24c-3-payout", "slot_changes": "t3-9-timetable-nav",
}
WHAT = {
    "staff_home": "centre Home numbers", "staff_students": "centre students, households, tutor links", "staff_attendance": "centre attendance + guard",
    "staff_charges": "pending charges for absent / cancelled lessons", "staff_trials": "trial flag", "staff_timetable": "centre timetable + holiday band",
    "staff_slots": "weekly slots with tutors, lesson generator", "staff_reassign": "reassign / cover a lesson", "tutor_schedule": "tutor Schedule tab (read only)",
    "money_settings": "centre money settings + validator", "centre_money": "centre invoice / payment tables", "centre_invoice_run": "Money > Invoice run",
    "centre_payments": "payments, credit notes, invoice link", "invites": "invite email log + status", "fee_050": "centre fee S$0.50 per student",
    "centre_billing_method": "how a centre pays TutorDeck", "centre_billing_start": "centre billing start date + agreed first-month count",
    "tutor_profile": "tutor's own profile", "tutor_payout": "tutor payout details (masked, audited)", "payout_permission": "payout permission + centre list/reveal",
    "slot_changes": "slot stop dates, class members, 26-week lessons, holiday cancel, People list",
}


# The demo centre is found by its MEMBERS, never by its name (the owner may have renamed it): the centre in which tutor.one@ and tutor.two@
# are active tutors and centre.owner@ is an active owner. The same rule is in db/seed_dev_demo.sql (staff block).
def _has(role, email):
    return ("exists (select 1 from public.memberships m join auth.users u on u.id = m.user_id where m.org_id = o.id and m.role = '%s' "
            "and m.status = 'active' and u.email = '%s')" % (role, email))
DEMO_WHERE = ("o.kind = 'centre'\n      and " + _has("owner", "centre.owner@example.test") + "\n      and " + _has("tutor", "tutor.one@example.test")
              + "\n      and " + _has("tutor", "tutor.two@example.test"))


def order():
    seen = []
    for line in open(os.path.join(ROOT, "tests/sql/run.sh")):
        m = re.match(r"\$P -f db/migration_([a-z0-9_]+)\.sql\b", line)
        if m and not m.group(1).endswith("_down") and m.group(1) not in seen:
            seen.append(m.group(1))
    return seen


def read(path):
    return open(os.path.join(ROOT, path)).read().rstrip("\n") + "\n"


def names(sql):
    """tables and functions a migration creates in the public schema (for the post-check)"""
    t = set(re.findall(r"create\s+table\s+(?:if\s+not\s+exists\s+)?(?:public\.)?([a-z_0-9]+)", sql, re.I))
    f = set(re.findall(r"create\s+(?:or\s+replace\s+)?function\s+(?:public\.)?([a-z_0-9]+)\s*\(", sql, re.I))
    return t, f


def main():
    allm = order()
    for m in ON_DEV:
        assert m in allm, "run.sh no longer lists " + m
    new = [m for m in allm if m not in ON_DEV]
    assert allm[:len(ON_DEV)] == ON_DEV, "the DEV migrations must come first in run.sh: %s" % allm[:len(ON_DEV)]
    tables, funcs = [], []
    for m in new:
        t, f = names(read("db/migration_%s.sql" % m))
        for x in sorted(t):
            if x not in tables: tables.append(x)
        for x in sorted(f):
            if x not in funcs: funcs.append(x)

    seed = read("db/seed_dev_demo.sql")
    marker = "-- T3 step 1: two staff logins for the demo centre."
    i = seed.index(marker)
    staff_block = "-- =====================================================================================================\n" + seed[i:]
    n = len(new) + 1

    o = []
    w = o.append
    w("""-- =====================================================================================================
-- TutorDeck — DEV APPLY PACK, test bundle 4 (task T40).   PASTE INTO THE SUPABASE SQL EDITOR OF THE **DEV** PROJECT ONLY (tuzxsqkfzrjssnpcoale).
-- NEVER run on LIVE (rnjvswkejbrhbaytutai): the last part creates demo logins with a known password. (On LIVE the pre-check below also
-- stops the pack: LIVE has no organisation tables yet.)
-- GENERATED by tools/build-dev-pack.py from tests/sql/run.sh: do not edit by hand; re-run the script.
-- =====================================================================================================
-- Contains, in dependency order (the same order tests/sql/run.sh proves; every part is idempotent: run it twice, the second changes nothing):""")
    for k, m in enumerate(new, 1):
        w("--   PART %-2d %-24s %-30s db/migration_%s.sql  (%s)" % (k, m, "claude/" + BRANCH[m], m, WHAT[m]))
    w("--   PART %-2d %-24s %-30s db/seed_dev_demo.sql (staff block only: centre.staff@ and centre.frontdesk@example.test)" % (n, "demo staff logins", "claude/t3-1-staff-home"))
    w("""-- Needs the seven standard migrations already on DEV: %s.
--
-- TRANSACTIONS: the Supabase SQL editor runs everything you paste as ONE batch, so the pack is all-or-nothing in practice: if any
-- statement fails, nothing from this paste is kept and the error shows the failing line. The pack has no BEGIN/COMMIT of its own.
-- It changes no existing row of real data (it is made for DEV, which holds dummy data only).
-- The result you see is the LAST query (the post-check). To see the pre-check alone, run just the first block.
-- =====================================================================================================
""" % ", ".join(ON_DEV))

    # ---------------- pre-check
    w("-- ####################################### PRE-CHECK (read-only) #######################################")
    w("-- 'ready' = the seven standard migrations are present and the demo centre is found. The demo centre is found by its MEMBERS (tutor.one@, tutor.two@ and")
    w("-- centre.owner@example.test), not by its name, so a renamed centre is fine; the 'demo centre' line prints the name and id it will use.")
    w("-- 'NEW OBJECTS ALREADY THERE' only says how much of this pack DEV already has: parts already applied are fine, the pack is safe to re-run.")
    w("""with demo as (
  select o.id, o.trading_name, o.created_at from public.organisations o
  where DEMO_WHERE
)
select 'PRE-CHECK' as step, m.migration, case when m.ok then 'present' else 'MISSING' end as state
from (values
  ('org_foundation (memberships, org_can)',  to_regclass('public.memberships') is not null and to_regprocedure('public.org_can(uuid,text)') is not null),
  ('billing (org_subscriptions)',            to_regclass('public.org_subscriptions') is not null),
  ('attendance (lessons.attendance)',        exists (select 1 from information_schema.columns where table_schema='public' and table_name='lessons' and column_name='attendance')),
  ('tutor_access (tutor_my_lessons)',        exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname='tutor_my_lessons')),
  ('org_delete (org_delete_solo)',           exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname='org_delete_solo')),
  ('function_lockdown (pinned search_path)', exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname='audit_immutable' and proconfig is not null)),
  ('org_separation (org_same_org_guard)',    exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname='org_same_org_guard'))
) as m(migration, ok)
union all
select 'PRE-CHECK', 'demo centre (found by its members; needed by the last part)',
  case (select count(*) from demo)
    when 1 then 'present: ' || (select trading_name from demo) || ' (' || (select id::text from demo) || ')'
    when 0 then 'MISSING demo centre (run db/seed_dev_demo.sql)'
    else 'AMBIGUOUS: ' || (select count(*) from demo) || ' centres match (' || (select string_agg(trading_name || ' ' || id, '; ' order by created_at) from demo) || ') - ask the project owner which one to use'
  end
union all
select 'PRE-CHECK', 'NEW OBJECTS ALREADY THERE', ((
    (select count(*) from (values NEW_T) v(n) where exists (select 1 from pg_class c where c.relnamespace='public'::regnamespace and c.relname=v.n and c.relkind='r'))
  + (select count(*) from (values NEW_F) v(n) where exists (select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname=v.n)))::text
  || ' of NEW_N (already applied parts are fine: the pack is safe to re-run)')
union all
select 'PRE-CHECK', 'OVERALL', case when
    to_regclass('public.memberships') is not null and to_regprocedure('public.org_can(uuid,text)') is not null
    and to_regclass('public.org_subscriptions') is not null
    and exists (select 1 from information_schema.columns where table_schema='public' and table_name='lessons' and column_name='attendance')
    and exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname='tutor_my_lessons')
    and exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname='org_delete_solo')
    and exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname='audit_immutable' and proconfig is not null)
    and exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname='org_same_org_guard')
    and (select count(*) from demo) = 1
  then 'ready' else 'NOT READY - fix the MISSING / AMBIGUOUS lines first (migration order: ON_DEV_LIST; demo seed: db/seed_dev_demo.sql)' end;
""".replace("DEMO_WHERE", DEMO_WHERE).replace("NEW_T", ",".join("('%s')" % x for x in tables)).replace("NEW_F", ",".join("('%s')" % x for x in funcs))
   .replace("NEW_N", str(len(tables) + len(funcs))).replace("ON_DEV_LIST", ", ".join(ON_DEV)))

    # ---------------- guard (stops the whole paste on a database that is not DEV-shaped)
    w("""-- Safety stop: this whole paste fails here, before changing anything, on a database that does not have the organisation tables
-- (that is what LIVE looks like today), or has no demo centre, or has several (the demo centre is found by its members, not its name).
do $$
declare n int; found_list text;
begin
  if to_regclass('public.organisations') is null or to_regclass('public.memberships') is null then
    raise exception 'STOP: this database has no organisation tables. The pack is for the DEV project only, after the seven standard migrations.';
  end if;
  select count(*), string_agg(o.trading_name || ' (' || o.id || ')', '; ' order by o.created_at) into n, found_list from public.organisations o
  where DEMO_WHERE;
  if n = 0 then
    raise exception 'STOP: MISSING demo centre (no centre has tutor.one@ and tutor.two@ as tutors and centre.owner@ as owner). Run db/seed_dev_demo.sql on DEV first (DEV only).';
  end if;
  if n > 1 then
    raise exception using message = 'STOP: AMBIGUOUS: ' || n || ' centres match the demo centre (' || found_list || '). Not guessing: ask the project owner which one the demo staff logins belong to.';
  end if;
  raise notice 'Demo centre used: %', found_list;
end $$;
""".replace("DEMO_WHERE", DEMO_WHERE))

    for k, m in enumerate(new, 1):
        w("""-- #####################################################################################################
-- ### PART %d of %d — %s
-- ### source branch: claude/%s   file: db/migration_%s.sql   undo: db/migration_%s_down.sql
-- ### (if an error appears, search this file for the nearest "### PART" line above the error line: that is the part that failed)
-- #####################################################################################################""" % (k, n, WHAT[m], BRANCH[m], m, m))
        w(read("db/migration_%s.sql" % m))
    w("""-- #####################################################################################################
-- ### PART %d of %d — two demo staff logins (centre.staff@ and centre.frontdesk@example.test; password in db/seed_dev_demo.sql)
-- ### source branch: claude/t3-1-staff-home   file: db/seed_dev_demo.sql (staff block only)   DEV ONLY
-- ### undo: delete from auth.users where email in ('centre.staff@example.test','centre.frontdesk@example.test')
-- #####################################################################################################""" % (n, n))
    w(staff_block)

    # ---------------- post-check
    w("-- ####################################### POST-CHECK (read-only; this is the result you see) #######################################")
    w("-- Every line should say 'present'; the last line says OVERALL OK.")
    w("""with want(kind, name) as (values
%s
), seen as (
  select 'POST-CHECK'::text as step, w.kind || ' ' || w.name as item,
         case when w.kind = 'table' then exists (select 1 from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname = w.name and c.relkind = 'r')
              else exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = w.name) end as ok
  from want w
  union all
  select 'POST-CHECK', 'demo login ' || e, exists (select 1 from auth.users where email = e)
  from unnest(array['centre.owner@example.test','centre.staff@example.test','centre.frontdesk@example.test','tutor.one@example.test','tutor.two@example.test','both.tutor@example.test','solo.tutor@example.test']) e
  union all
  select 'POST-CHECK', 'demo centre used: ' || o.trading_name || ' (' || o.id || ')', true from public.organisations o
  where %s
)
select step, item, case when ok then 'present' else 'MISSING' end as state from seen
union all
select 'POST-CHECK', 'OVERALL', case when (select bool_and(ok) from seen) then 'OK - all %d objects and 7 demo logins present' else 'NOT OK - see the MISSING lines above' end
order by 1, 3 desc, 2;""" % (",\n".join("  " + ",".join(["('table','%s')" % x for x in tables][i:i + 4] ) for i in range(0, len(tables), 4)) + ",\n" +
                              ",\n".join("  " + ",".join(["('function','%s')" % x for x in funcs][i:i + 4]) for i in range(0, len(funcs), 4)),
                              DEMO_WHERE, len(tables) + len(funcs)))
    return "\n".join(o) + "\n"


if __name__ == "__main__":
    text = main()
    if "--check" in sys.argv:
        sys.exit(0 if os.path.exists(OUT) and open(OUT).read() == text else 1)
    open(OUT, "w").write(text)
    print("wrote", OUT, len(text.splitlines()), "lines")
