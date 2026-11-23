# TutorDeck — handoff note (2026-11-23)

## 1. Project & goal
TutorDeck (tutordeck.com.sg, TutorDecks/TutorDeck) is a vanilla HTML/CSS/JS tutor admin app on Supabase + Vercel.
Goal: turn it into a multi-tenant product that tuition centres configure for themselves (first customer ~400 students,
nothing hard-coded for them), while every existing solo tutor keeps working unchanged. The owner's build brief
(uploaded file "tutordeck-centre-build-prompt.md") defines roles, a 10-step setup wizard, billing models, invoicing,
payment modes, tutor pay, platform billing and 5 phases. We are in **Phase 1 (Foundation)**.

## 2. Owner's standing rules
- Read CLAUDE.md in the repo first; it is authoritative (branch workflow, conventions, house style, data warnings).
- `main` = production, protected; never push to main or force-push. Only open dev→main when the owner says "ship".
- There is ONE live Supabase DB with real student/payment data; previews hit it too. Never change live rows without
  showing a SELECT preview and getting a yes. Never run a migration on live without explicit go-ahead.
- Test SQL on a throwaway local Postgres (`bash tests/sql/run.sh`) and on the DEV Supabase project only.
- From the brief: plan → wait for go-ahead per phase; ask when a money rule is ambiguous; money in integer cents;
  all calculations in one tested JS module; issued documents immutable (centres only); secrets server-side; audit log;
  tenant isolation tests; TutorDeck never holds a centre's money.
- Never paste API keys in chat; keys go in Vercel/Supabase secrets. Bump `?v=N` (bump-version.sh) when CSS/JS changes;
  add a README "Raphael's updates" entry per change; keep phone layouts working (820px).
- Commit trailer used: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` + Claude-Session line. No model names elsewhere.

## 3. Key decisions (owner's answers)
1. Paying tutors before parents pay = a question in wizard step 8; pre-selected "after the parent's payment is reconciled"; changes audited.
2. Stripe = TutorDeck charging centres: S$100 base + S$0.40 × billable students (prev month's active students rounded to nearest 10, halves up).
   Parents pay the centre via a per-org choice: manual (PayNow/bank), HitPay (centre's own), or Stripe (centre's own via Connect). Money never passes through TutorDeck.
3. Solo tutors get a separate plan — price NOT yet decided (stored as 0/0 placeholder).
4. Last week's branch work (separate `centre_*` tables, dollars, SQL-side calculations) is superseded by one shared data model with `org_id` everywhere; reuse its role grid/audit/trigger/test ideas only.
5. Immutable invoices + credit notes apply to CENTRES only; solo tutor functionality must not change.
6. Households = existing same-parent-phone grouping (digits, drop leading 65 from 10 digits).
7. GST rounded once per invoice, half up.
8. Billable "active student": any non-trial lesson attended, absent or late-cancelled in the month.
- Pricing research earlier (solo S$15 / Team seats) is superseded by the above.

## 4. Current state
- Branch: `claude/gifted-cori-wssq1j` (session branch; based on main 6862d4a). HEAD = origin = `4ef26af` (pushed; working tree clean except this file).
  - `ebe564e` = last week's v253 centre-mode work (superseded; `db/migration_centres.sql`, `centre.html`, `assets/js/centre.js`, `assets/js/billing-core.js`, `tests/sql/centres_test.sql` still present — to be removed/reworked).
  - `4ef26af` = Phase 1 WIP: `db/baseline_2026-11.sql` (+`_storage.sql`), `db/migration_org_foundation.sql`, `db/migration_org_foundation_down.sql`, `tests/sql/org_seed.sql`, `tests/sql/org_test.sql`, `tests/sql/run.sh`, `tests/sql/supabase_shim.sql`.
- origin/main = 6862d4a (v252), origin/dev = 32926f7. Nothing merged; no PR opened.
- Supabase projects (org "tutordeckadmin"): LIVE `rnjvswkejbrhbaytutai` (TutorDeck, Singapore; 7 tutors, 59 students, 1,378 lessons) —
  NO migrations run on it (only read-only catalog queries). DEV `tuzxsqkfzrjssnpcoale` ("tutordeckadmin-creator's Project", Seoul, empty):
  baseline structure + storage buckets APPLIED; Phase 1 migration NOT applied — the apply call timed out waiting for the owner's approval prompt.
- Stripe connector: only "TutorDeck sandbox" (test). Vercel connector: only MugCorner team (TutorDeck project not visible).
- Checks: `bash tests/sql/run.sh` → 71 PASS + undo restores baseline exactly + re-apply after undo (local Postgres 16 at
  /var/lib/postgresql, port 54329; start with pg_ctl as user postgres). Not yet run: isolation tests on dev project, smoke tests for Phase 1 (no UI yet).

## 5. Open tasks (priority order)
1. Owner: approve re-applying `migration_org_foundation.sql` to DEV (it prompts for confirmation).
2. Run isolation checks on DEV (role authenticated + jwt claims, as in tests/sql/org_test.sql).
3. `assets/js/org-settings.js`: full typed settings schema for wizard steps 1–10 with defaults, "coming soon" flags, validation, solo preset; keep STAFF_PERMISSIONS in sync with the migration.
4. `assets/js/money.js`: integer-cents module (GST per invoice half-up, platform fee) + node tests incl. brief cases: 98→100→S$140; 250→S$200; 398→400→S$260; 403→400→S$260; 405→410→S$264; 500→S$300; 1000→S$500.
5. Setup wizard page (10 steps) + Settings screens (org profile, users & permissions, audit log view, plan/fee shown to owner); "Create a centre" entry from Settings; solo preset skips wizard.
6. Remove superseded v253 centre files from the branch; bump version, README log, CLAUDE.md update; Phase 1 report.
- Waiting on owner: solo plan price; restoring last night's encrypted backup into DEV for a real-data migration dry run (owner holds BACKUP_PASSPHRASE; README → Backups); email provider choice for Phase 2 (none in code; Resend/Brevo connectors available); later, TutorDeck Pte Ltd Stripe live account.

## 6. Paths & gotchas
- `db/schema.sql` is stale; use `db/baseline_2026-11.sql` (rebuilt from the live catalog). Live has `invoices.share_token` + `invoice_by_token()`;
  `public_schedule()` (hard-coded to one account, omitted from baseline).
- Migration design: org_id added + backfilled; `org_row_guard` trigger fills org_id for old pages, forbids moving rows between orgs and
  writing into orgs you aren't in; legacy `tutor_id` policies restricted to solo orgs (otherwise centre staff bypass permissions — found by tests);
  `handle_new_user` now also creates a solo org; cents are generated columns (`*_cents`); `org_settings`, `audit_log`, `platform_fee_snapshots`
  are append-only by trigger; backfill skips per-row audit via `td.skip_audit`.
- Staff permissions: manage_timetable, manage_students, manage_tutors, issue_invoices, record_payments, view_revenue, run_tutor_pay, view_audit_log; owner = all.
- Centre tutors have no business-table access yet (Phase 2 adds own-lesson access via `taught_by`).
- Smoke tests: `tests/smoke.py` (python playwright; here needed a wrapper to use /opt/pw-browsers/chromium). Calendar `/api/gcal` 501s locally are pre-existing.
- No Node on the owner's Mac; Node 22 available in the cloud container.
