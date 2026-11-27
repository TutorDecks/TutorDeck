#!/usr/bin/env python3
"""Builds docs/orchestrator/dev-apply-pack.sql: every migration that is not yet on the DEV project, in the exact order
tests/sql/run.sh applies them, plus the demo staff logins and a read-only pre-check / post-check.

    python3 tools/build-dev-pack.py            # writes the file
    python3 tools/build-dev-pack.py --check    # exits 1 if the file on disk is out of date

The order is READ FROM tests/sql/run.sh so the pack can never drift from what the tests prove.
DEV already has (do not list here): the migrations in ON_DEV below. Everything else in run.sh goes into the pack.

Bundle 7 (T49): DEV already has the seven standard migrations, bundle 4's pack (BUNDLE4 below, plus its two demo staff logins) AND bundle 5's pack
(BUNDLE5 below). Not on DEV yet and therefore in this pack: b5_fix, tutor_own_lessons, import (stage A), centre_tutor_pay, statement_matching, invoice_email,
makeup_credits, tutor_link_propose, past_lessons, tutor_own_pay and org_export, in the order tests/sql/run.sh proves (five of them replace org_validate_settings (the one-argument check, or the organisation-aware wrapper) and two replace centre_invoice_run_rows,
each file carrying the cumulative version of the one before it, so the order is not free)."""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs/orchestrator/dev-apply-pack.sql")
STANDARD = ["org_foundation", "billing", "attendance", "tutor_access", "org_delete", "function_lockdown", "org_separation"]
BUNDLE4 = ["staff_home", "staff_students", "staff_attendance", "staff_charges", "staff_trials", "staff_timetable", "staff_slots", "staff_reassign",
           "tutor_schedule", "money_settings", "centre_money", "centre_invoice_run", "centre_payments", "invites", "fee_050", "centre_billing_method",
           "centre_billing_start", "tutor_profile", "tutor_payout", "payout_permission"]
BUNDLE5 = ["reassign_link", "payment_fix", "centre_deposits", "centre_refunds", "centre_late_fees", "centre_credit_undo", "slot_changes", "tutor_moves"]
ON_DEV = STANDARD + BUNDLE4 + BUNDLE5
LATER = set()                      # nothing is held back for a later bundle

# which branch each file came from (for the headers only)
BRANCH = {
    "staff_home": "t3-1-staff-home", "staff_students": "t3-2-students", "staff_attendance": "t3-3-attendance", "staff_charges": "t3-4-charges",
    "staff_trials": "t3-5-trials", "staff_timetable": "t3-6-timetable", "staff_slots": "t3-7-slots", "staff_reassign": "t3-8-reassign",
    "tutor_schedule": "t6-1-tutor-schedule", "money_settings": "t4-s0-settings", "centre_money": "t4-s1-tables",
    "centre_invoice_run": "t4-s2-invoice-run", "centre_payments": "t4-s3-payments", "invites": "t7-2-invites", "fee_050": "t30-fee-050",
    "centre_billing_method": "t31a-centre-invoice-billing", "centre_billing_start": "t36-billing-start", "tutor_profile": "t24c-1-profile",
    "tutor_payout": "t24c-2-payout", "payout_permission": "t24c-3-payout", "slot_changes": "t3-9-timetable-nav",
    "reassign_link": "b4-fix", "payment_fix": "b4-fix",
    "tutor_moves": "t6-2-tutor-moves", "tutor_own_lessons": "t6-3-tutor-own-lessons", "tutor_link_propose": "t6-4-link-propose", "tutor_own_pay": "t4-s7b-own-pay", "past_lessons": "t3-10-past-lessons", "b5_fix": "b5-fix", "import": "t33-i1-stage-a", "centre_tutor_pay": "t4-s7-tutor-pay",
    "statement_matching": "t34-m0-matching", "invoice_email": "t7-3-invoice-email", "makeup_credits": "t18-4-makeup-credits", "org_export": "t35-e-export",
    "centre_deposits": "t4-s4-deposits", "centre_refunds": "t4-s5-refunds", "centre_late_fees": "t4-s6-late-fees",
    "centre_credit_undo": "t4-s5b-credit-undo",
}
WHAT = {
    "staff_home": "centre Home numbers", "staff_students": "centre students, households, tutor links", "staff_attendance": "centre attendance + guard",
    "staff_charges": "pending charges for absent / cancelled lessons", "staff_trials": "trial flag", "staff_timetable": "centre timetable + holiday band",
    "staff_slots": "weekly slots with tutors, lesson generator", "staff_reassign": "reassign / cover a lesson", "tutor_schedule": "tutor Schedule tab (read only)",
    "money_settings": "centre money settings + validator", "centre_money": "centre invoice / payment tables", "centre_invoice_run": "Money > Invoice run",
    "centre_payments": "payments, credit notes, invoice link", "invites": "invite email log + status", "fee_050": "centre fee S$0.50 per student",
    "centre_billing_method": "how a centre pays TutorDeck", "centre_billing_start": "centre billing start date + agreed first-month count",
    "tutor_profile": "tutor's own profile", "tutor_payout": "tutor payout details (masked, audited)", "payout_permission": "payout permission + centre list/reveal",
    "reassign_link": "reassign keeps the old tutor's link when they still teach the student", "payment_fix": "Record payment fix (DELETE without WHERE refused by Supabase)",
    "slot_changes": "slot stop dates, class members, 26-week lessons, holiday cancel, People list",
    "tutor_moves": "tutors move, put back and cancel their own lessons (centre option)",
    "b5_fix": "follow-up fixes to bundle 5: deposit run, settings page, class share, tutor changes list",
    "tutor_link_propose": "the online lesson link, and tutors who ask (tutors_propose): requests staff approve or decline",
    "tutor_own_lessons": "tutors add their own one-off lessons and weekly slots, Create lessons, price pending (centre option)",
    "import": "centre import stage A: dry run, commit, undo, history, billing-start setting", "centre_tutor_pay": "tutor pay: rates, monthly pay list, adjustments, payments (owner / staff only)",
    "statement_matching": "bank statement matching: upload, rules, review queue, confirm, undo", "invoice_email": "invoice / receipt / reminder emails: queue, send log, caps, bounces",
    "makeup_credits": "make-up credits: owed list, booking, expiry, invoice skip", "org_export": "centre data export (owner only): catalogue, paged reads, audit",
    "centre_deposits": "refundable deposits: ledger, deposit invoice, waive, opening balance", "centre_refunds": "refunds + family credit (request, approve, pay, apply)",
    "centre_late_fees": "late fee proposals (approve / waive, monthly repeat)", "centre_credit_undo": "undo of applied credit / deposit, four-eyes guard, notices",
    "tutor_own_pay": "tutors see their own pay: monthly total or per lesson, if the centre allows it (tutor_pay.tutors_see_own_pay)",
    "past_lessons": "staff add past lessons (backfill), centre setting lessons.backfill_allowed_days",
}


def order():
    seen = []
    for line in open(os.path.join(ROOT, "tests/sql/run.sh")):
        m = re.match(r"\$P -f db/migration_([a-z0-9_]+)\.sql\b", line)
        if m and not m.group(1).endswith("_down") and m.group(1) not in seen and m.group(1) not in LATER:
            seen.append(m.group(1))
    return seen


def read(path):
    return open(os.path.join(ROOT, path)).read().rstrip("\n") + "\n"


def names(sql):
    """tables and functions a migration creates in the public schema (for the post-check)"""
    t = set(re.findall(r"create\s+table\s+(?:if\s+not\s+exists\s+)?(?:public\.)?([a-z_0-9]+)", sql, re.I))
    f = set(re.findall(r"create\s+(?:or\s+replace\s+)?function\s+(?:public\.)?([a-z_0-9]+)\s*\(", sql, re.I))
    return t, f


# migrations that only REPLACE existing functions create nothing new: the pre-check looks inside the function body instead
PROBE = {"reassign_link": "exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname='staff_reassign_lesson' and prosrc like '%links_kept%')",
         "payment_fix": "exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname='centre_record_payment' and prosrc like '%where true%')",
         "money_settings": "exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname='org_validate_settings' and pronargs=1 and prosrc like '%rate_model%')"}


def key_object(m, allm):
    """one object that only this migration introduces (a table if it creates one, else a function): the pre-check uses it to say whether the migration is on DEV"""
    mine_t, mine_f = names(read("db/migration_%s.sql" % m))
    earlier_t, earlier_f = set(), set()
    for e in allm[:allm.index(m)]:
        t, f = names(read("db/migration_%s.sql" % e)); earlier_t |= t; earlier_f |= f
    ts = sorted(mine_t - earlier_t)
    if ts: return ("table", ts[0])
    fs = sorted(mine_f - earlier_f)
    return ("function", fs[0]) if fs else None


def main():
    allm = order()
    for m in ON_DEV:
        assert m in allm, "run.sh no longer lists " + m
    assert allm[:len(STANDARD)] == STANDARD, "the standard migrations must come first in run.sh: %s" % allm[:len(STANDARD)]
    new = [m for m in allm if m not in ON_DEV and m not in LATER]
    assert new == ["b5_fix", "tutor_own_lessons", "import", "centre_tutor_pay", "statement_matching", "invoice_email", "makeup_credits", "tutor_link_propose", "past_lessons", "tutor_own_pay", "org_export"], "unexpected pack order: %s" % new
    tables, funcs = [], []
    for m in new:
        t, f = names(read("db/migration_%s.sql" % m))
        for x in sorted(t):
            if x not in tables: tables.append(x)
        for x in sorted(f):
            if x not in funcs: funcs.append(x)
    keys = []
    for m in BUNDLE4:
        k = key_object(m, allm) or ("probe", PROBE.get(m))
        assert k[1], "no key object (and no PROBE) for " + m
        keys.append((m, k))
    n = len(new)

    def exists_sql(kind, name):
        if kind == "probe": return name
        if kind == "table": return "exists (select 1 from pg_class c where c.relnamespace='public'::regnamespace and c.relname='%s' and c.relkind='r')" % name
        return "exists (select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='%s')" % name
    std_checks = [
        ("org_foundation (memberships, org_can)", "to_regclass('public.memberships') is not null and to_regprocedure('public.org_can(uuid,text)') is not null"),
        ("billing (org_subscriptions)", "to_regclass('public.org_subscriptions') is not null"),
        ("attendance (lessons.attendance)", "exists (select 1 from information_schema.columns where table_schema='public' and table_name='lessons' and column_name='attendance')"),
        ("tutor_access (tutor_my_lessons)", exists_sql("function", "tutor_my_lessons")),
        ("org_delete (org_delete_solo)", exists_sql("function", "org_delete_solo")),
        ("function_lockdown (pinned search_path)", "exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname='audit_immutable' and proconfig is not null)"),
        ("org_separation (org_same_org_guard)", exists_sql("function", "org_same_org_guard")),
    ]
    b4_checks = [("bundle 4: %s (%s)" % (m, k[1] if k[0] == "probe" and False else (k[0] + " " + k[1] if k[0] != "probe" else "function body")), exists_sql(*k)) for m, k in keys]
    keys5 = []
    for m in BUNDLE5:
        k = key_object(m, allm) or ("probe", PROBE.get(m))
        assert k[1], "no key object (and no PROBE) for " + m
        keys5.append((m, k))
    b5_checks = [("bundle 5: %s (%s)" % (m, (k[0] + " " + k[1]) if k[0] != "probe" else "function body"), exists_sql(*k)) for m, k in keys5]
    b4_checks = b4_checks + b5_checks

    o = []
    w = o.append
    w("""-- =====================================================================================================
-- TutorDeck — DEV APPLY PACK, test bundle 7 (task T49).   PASTE INTO THE SUPABASE SQL EDITOR OF THE **DEV** PROJECT ONLY (tuzxsqkfzrjssnpcoale).
-- NEVER run on LIVE (rnjvswkejbrhbaytutai). (On LIVE the pre-check below also stops the pack: LIVE has no organisation tables yet.)
-- GENERATED by tools/build-dev-pack.py from tests/sql/run.sh: do not edit by hand; re-run the script.
-- =====================================================================================================
-- DEV already has the seven standard migrations, bundle 4's pack and bundle 5's pack (see the pre-check). This pack adds, in dependency order (the same order
-- tests/sql/run.sh proves; every part is idempotent: run it twice, the second changes nothing):""")
    for k, m in enumerate(new, 1):
        w("--   PART %-2d %-24s %-30s db/migration_%s.sql  (%s)" % (k, m, "claude/" + BRANCH[m], m, WHAT[m]))
    w("""-- Needs on DEV first: the seven standard migrations (%s) every migration of bundle 4 (%s) and every migration of bundle 5 (%s).
--
-- TRANSACTIONS: the Supabase SQL editor runs everything you paste as ONE batch, so the pack is all-or-nothing in practice: if any
-- statement fails, nothing from this paste is kept and the error shows the failing line. The pack has no BEGIN/COMMIT of its own.
-- It changes no existing row of real data (it is made for DEV, which holds dummy data only).
-- The result you see is the LAST query (the post-check). To see the pre-check alone, run just the first block.
-- =====================================================================================================
""" % (", ".join(STANDARD), ", ".join(BUNDLE4), ", ".join(BUNDLE5)))

    # ---------------- pre-check
    w("-- ####################################### PRE-CHECK (read-only) #######################################")
    w("-- 'ready' = the seven standard migrations, all of bundle 4 and all of bundle 5 are present. 'NEW OBJECTS ALREADY THERE' only says how much of THIS pack DEV already has:")
    w("-- parts already applied are fine, the pack is safe to re-run (DEV already has payment_fix: it is repeated harmlessly).")
    w("-- The demo logins line is information only: the logins come from bundle 4's pack, this pack creates none.")
    rows = ",\n".join("  ('%s', %s)" % (label.replace("'", "''"), cond) for label, cond in std_checks + b4_checks)
    w("""select 'PRE-CHECK' as step, m.migration, case when m.ok then 'present' else 'MISSING' end as state
from (values
ROWS_HERE
) as m(migration, ok)
union all
select 'PRE-CHECK', 'demo logins from bundle 4 (information only)', (select count(*) from auth.users where email in ('centre.owner@example.test','centre.staff@example.test','centre.frontdesk@example.test','tutor.one@example.test','tutor.two@example.test','both.tutor@example.test','solo.tutor@example.test'))::text || ' of 7'
union all
select 'PRE-CHECK', 'NEW OBJECTS ALREADY THERE', ((
    (select count(*) from (values NEW_T) v(n) where exists (select 1 from pg_class c where c.relnamespace='public'::regnamespace and c.relname=v.n and c.relkind='r'))
  + (select count(*) from (values NEW_F) v(n) where exists (select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname=v.n)))::text
  || ' of NEW_N (already applied parts are fine: the pack is safe to re-run)')
union all
select 'PRE-CHECK', 'OVERALL', case when
    ALL_OK
  then 'ready' else 'NOT READY - fix the MISSING lines first (apply the standard migrations, then bundle 4''s and bundle 5''s packs, before this one)' end;
""".replace("ALL_OK", "\n    and ".join("(" + c + ")" for _, c in std_checks + b4_checks)).replace("NEW_T", ",".join("('%s')" % x for x in tables)).replace("NEW_F", ",".join("('%s')" % x for x in funcs))
   .replace("NEW_N", str(len(tables) + len(funcs))).replace("ROWS_HERE", rows))

    # ---------------- guard (stops the whole paste on a database that is not DEV-shaped)
    w("""-- Safety stop: this whole paste fails here, before changing anything, on a database that does not have the organisation tables
-- (that is what LIVE looks like today) or that lacks bundles 4 and 5 (the parts below build on them).
do $$
begin
  if to_regclass('public.organisations') is null or to_regclass('public.memberships') is null then
    raise exception 'STOP: this database has no organisation tables. The pack is for the DEV project only, after the seven standard migrations, bundle 4 and bundle 5.';
  end if;
  if not (GUARD_COND) then
    raise exception 'STOP: bundle 4 or bundle 5 is not (fully) on this database. Apply their packs first (see the PRE-CHECK MISSING lines).';
  end if;
end $$;
""".replace("GUARD_COND", "\n    and ".join("(" + c + ")" for _, c in b4_checks)))

    for k, m in enumerate(new, 1):
        w("""-- #####################################################################################################
-- ### PART %d of %d — %s
-- ### source branch: claude/%s   file: db/migration_%s.sql   undo: db/migration_%s_down.sql
-- ### (if an error appears, search this file for the nearest "### PART" line above the error line: that is the part that failed)
-- #####################################################################################################""" % (k, n, WHAT[m], BRANCH[m], m, m))
        w(read("db/migration_%s.sql" % m))

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
)
select step, item, case when ok then 'present' else 'MISSING' end as state from seen
union all
select 'POST-CHECK', 'OVERALL', case when (select bool_and(ok) from seen) then 'OK - all %d objects present' else 'NOT OK - see the MISSING lines above' end
order by 1, 3 desc, 2;""" % (",\n".join("  " + ",".join(["('table','%s')" % x for x in tables][i:i + 4] ) for i in range(0, len(tables), 4)) + ",\n" +
                              ",\n".join("  " + ",".join(["('function','%s')" % x for x in funcs][i:i + 4]) for i in range(0, len(funcs), 4)),
                              len(tables) + len(funcs)))
    return "\n".join(o) + "\n"


if __name__ == "__main__":
    text = main()
    if "--check" in sys.argv:
        sys.exit(0 if os.path.exists(OUT) and open(OUT).read() == text else 1)
    open(OUT, "w").write(text)
    print("wrote", OUT, len(text.splitlines()), "lines")
