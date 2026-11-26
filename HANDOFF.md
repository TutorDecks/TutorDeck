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
2. Stripe = TutorDeck charging centres: S$100 base + S$0.50 × billable students (was S$0.40 until 2026-11-26, T30) (prev month's active students rounded to nearest 10, halves up).
   Parents pay the centre via a per-org choice: manual (PayNow/bank), HitPay (centre's own), or Stripe (centre's own via Connect). Money never passes through TutorDeck.
3. Solo tutors get a separate plan — price NOT yet decided (stored as 0/0 placeholder).
4. Last week's branch work (separate `centre_*` tables, dollars, SQL-side calculations) is superseded by one shared data model with `org_id` everywhere; reuse its role grid/audit/trigger/test ideas only.
5. Immutable invoices + credit notes apply to CENTRES only; solo tutor functionality must not change.
6. Households = existing same-parent-phone grouping (digits, drop leading 65 from 10 digits).
7. GST rounded once per invoice, half up.
8. Billable "active student": any non-trial lesson attended, absent or late-cancelled in the month.
- Pricing research earlier (solo S$15 / Team seats) is superseded by the above.

## 4. Current state (Phase 1 complete in code; Phase 2 is for the next chat)
- Branch `claude/gifted-cori-wssq1j` (based on main 6862d4a); see `git log` for the latest commit. Nothing merged, no PR.
- Built: `db/migration_org_foundation.sql` (+ `_down.sql`), `db/baseline_2026-11.sql` (+ `_storage.sql`), `assets/js/money.js`,
  `assets/js/org-settings.js`, `org.html` + `assets/js/org.js` (wizard steps 1–10 → Settings + Plan + Audit log after launch),
  Settings link "Set up a tuition centre" → `org`. Last week's `centre_*` design removed. Version v253 everywhere.
- Tests: `bash tests/sql/run.sh` = 71 PASS + undo restores baseline + re-apply; `node --test tests/money.test.js tests/org-settings.test.js`
  = 12 PASS; `tests/smoke.py` passes for `org` (phone/desktop, light/dark, axe). Pre-existing: calendar `/api/gcal` 501 locally.
  CI (.github/workflows/checks.yml) now also runs the unit + database tests.
- Supabase: LIVE `rnjvswkejbrhbaytutai` untouched (read-only catalog queries only). DEV `tuzxsqkfzrjssnpcoale`: baseline + storage
  APPLIED; org migration NOT applied (first attempt timed out on the owner's approval prompt; after a restart the connector only
  showed MugCorner projects — owner must reconnect Supabase to the TutorDeck org, then re-apply and run isolation checks there).
- Stripe connector: "TutorDeck sandbox" only. Vercel connector: MugCorner team only.

## 5. Open tasks
Phase 1 leftovers (need the owner):
1. Reconnect Supabase connector to the TutorDeck organisation; apply `migration_org_foundation.sql` to DEV; run isolation checks there.
2. Restore last night's encrypted backup into DEV (owner has BACKUP_PASSPHRASE; README → Backups) and dry-run the migration on real data.
3. Decide the solo plan price (stored as 0/0 in `org_plans` for solo orgs).
4. Only then: run the migration on LIVE (with explicit go-ahead), before this code lands on dev/main.
Phase 2 (per the brief; plan → wait for go-ahead first): centre admin screens (tutors, students, households, classes, branches/rooms,
term calendar, timetable); tutor view (own schedule, attendance, remarks + deadlines; needs `lessons.taught_by`, attendance status,
`trial` flag, `session_id`); billing engine for the four models in money.js; invoice runs/drafts/approval/branded pages/links/reminders/
credit notes/overdue/CSV; manual PayNow + payment recording; platform billing snapshot job + platform admin view (`platform_orgs()` exists);
data export; email provider (none in code yet; Resend/Brevo connectors available).

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
