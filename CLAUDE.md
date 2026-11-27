# TutorDeck — project context

## What this is
TutorDeck is a tutor admin web app (students, weekly planner, calendar, ledger/payments,
PayNow invoices, WhatsApp reminders, exams, student profiles). It started as
"T-Leng Tuition Dashboard" and is being rebranded to TutorDeck.
Company: TutorDeck Pte. Ltd. (Singapore), founded by Raphael and T-Leng. We are both
developers AND we both use the app live for our own tuition businesses.

## How the work is organised
- An **orchestrator chat** hands tasks to **worker chats** and tracks them in `docs/orchestrator/BOARD.md` (rules and the worker-brief template: `docs/orchestrator/ORCHESTRATOR.md`).
  If you are a worker: do exactly your brief, work and push only on your own branch, finish with an "ORCHESTRATOR SUMMARY" block, and don't edit the board.

## Stack
- Plain HTML/CSS/JS, no build step, no framework (vanilla JS, Chart.js, html2canvas).
- Supabase (Postgres + Auth) for data and accounts. Row-level security on every table
  (tutor_id = auth.uid()). The publishable/anon key in assets/js/config.js is safe to commit.
  NEVER commit service-role keys or SMTP passwords.
- Google Identity Services for Google sign-in (via Supabase) and Google Calendar sync.
- See README.md for the file structure, DB migrations, and the running change log.
- `db/schema.sql` is stale — the live Supabase DB is the source of truth for columns.

## Hosting & deploys
- GitHub repo: TutorDecks/TutorDeck (org "TutorDecks"; moved from tlengengtuition-oss/tuitiondashboard).
- Hosted on Vercel (project "tutordeck"). Live: https://tutordeck.vercel.app
  Custom domain https://www.tutordeck.com.sg is being activated (DNS pending).
- Clean URLs (v213): vercel.json sets `cleanUrls`, so pages live at /home, /calendar, /ledger … and old *.html
  addresses redirect. The Dashboard file is `home.html` (was app.html; /app redirects to /home). Write internal links
  without ".html" ("ledger", "student?id=…"). python http.server can't serve these locally; test on the Vercel preview.
- GitHub Pages is no longer used. Old github.io URLs are dead — flag any hard-coded
  references to tlengengtuition-oss.github.io in the code and replace them.

## Branch workflow (important)
- `main` = PRODUCTION. Every merge to main auto-deploys to the live site within ~1 min.
  `main` is protected: no direct pushes, changes only via pull request.
- `dev` = staging (Vercel preview URL).
- Work on short-lived `feature/<short-name>` branches off `dev` → PR into `dev` → test
  on the preview link → PR `dev` → `main`.
- Never suggest pushing straight to main or force-pushing.
- **CI policy (owner, 2026-11-26: the repo is private, Actions minutes are limited):** `.github/workflows/checks.yml` runs ONLY on pull requests into `main` and by manual
  dispatch (`workflow_dispatch`), never on pushes or on PRs into `dev`. So workers must run `node --test tests/*.test.js`, `bash tests/sql/run.sh`, the static checks and the
  smoke suite LOCALLY before pushing. The orchestrator starts the manual run when an owner-approved bundle is about to merge and for every go-live PR (`dev` → `main`).

## Vercel builds only dev and main (T39, owner's rule 2026-11-26)
- `vercel.json` → `git.deploymentEnabled`: `"**": false, "main": true, "dev": true`. Only `main` (production) and `dev` (staging) are built; `claude/*` and `feature/*`
  branches get no preview and no Vercel comment on their PRs. Review on `dev` only. Workers test locally (`python3 tests/server.py`, `node --test tests/*.test.js`).
  To see a worker's branch on a device, merge it into `dev` in an owner-approved bundle. Anything pointed at a feature-branch preview (the Stripe sandbox webhook)
  must point at the `dev` address. Steps and fallback: `docs/orchestrator/T39-vercel-steps.md`.

## Data warning
There is ONE LIVE Supabase database (project `rnjvswkejbrhbaytutai`), and it holds REAL student/payment data.
- **Only the production addresses use it** (www.tutordeck.com.sg, tutordeck.com.sg, tutordeck.vercel.app and the two other aliases of the production deployment).
  Every Vercel preview (including `dev`), local testing and any address not on that list uses the **DEV project** (`tuzxsqkfzrjssnpcoale`, dummy data only). The choice is made in
  `assets/js/config.js` by hostname, with DEV as the default so a mistake fails on the safe side; non-production pages show a "Test version · dummy data only" tab. Server
  functions in `api/` follow the same rule: Vercel Preview env vars point at DEV, and without settings only `VERCEL_ENV=production` falls back to the live project.
  **A new production domain must be added to `PRODUCTION_HOSTS` in config.js and `tests/config.test.js`**, or that domain would show the test banner and nobody could sign in.
- DEV has demo logins and sample data from `db/seed_dev_demo.sql` (centre owner, two centre tutors, a solo tutor with exactly 5 students, a solo+centre tutor; password
  `Demo-Pass-2026`). It has no Google sign-in, no bot check and its own auth settings, so test sign-in with those email logins.
- Don't write code or run scripts that bulk-delete/modify LIVE data without asking me first. Before running anything that changes real rows in the live project, show the SELECT
  preview first and get a yes. DEV is free to experiment on.
- Any new `db/migration_*.sql`: apply it to DEV first (previews need it there), and run it on LIVE in the Supabase SQL editor BEFORE the code that needs it is merged to `main`,
  or production pages will error with "column does not exist". (Previews no longer touch live, so LIVE only needs it at the moment of shipping to `main`.)
- Nightly encrypted DB backups run via GitHub Actions (.github/workflows/db-backup.yml, 30-day artifacts).
  The repo is PRIVATE (since 2026-11-26), but still never commit dumps, secrets or real student data, and never print data in workflow logs. Restore steps: README → Backups.

## Conventions
- Bump the cache-buster (`?v=N`) in every page when CSS/JS changes: `bash bump-version.sh <N>`.
  Check `main` first so we don't both ship the same number.
- Add an entry to the "Raphael's updates" log in README.md for each change (newest first).
- Keep mobile layouts working (app is heavily used on phones; breakpoint 820px).
- Shared helpers live on `window.TL` in assets/js/app.js; pages call `TL.requireAuth("navId", init)`.
- Saved per-user state goes through `TL.store.get/set/remove` (keys `td:<uid>:<key>`), never raw localStorage —
  several tutors can share a browser. Only device-wide settings (Client view `td_client`) use localStorage directly.
- No Node here. Syntax-check JS with JavaScriptCore by wrapping the file in `new Function`:
  `/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc -e "new Function(readFile('assets/js/ledger.js')); print('ok')"`

## Look & feel (TutorDeck house style, v150+)
- Font: Manrope only. Colours: ink #13233F, accent teal #0F766E (the ONLY accent: primary buttons,
  active tab, paid), owed #B4432F, warning amber #B45309, ground #FAF9F6, lines #E8E5DE.
- Colour = meaning. Don't add new accent colours; neutral greys for everything else.
- One primary action per screen. Lists show info; actions live in the item's detail sheet.
- Use the CSS variables in assets/css/app.css, not hard-coded hex.
- Teaching new features: use `TL.coach(key, el, html)` (one-time tip with "Got it"), not permanent banners.

## Working agreements
- Only open the `dev` → `main` PR when the person you're working with explicitly says to ship.
- Before running anything that changes real rows in Supabase, show the SELECT preview first and
  get a yes.
- Explain data-model choices plainly. Raphael came from a Google Sheets workflow (household id,
  student sheet, lesson master, invoice generator), so mapping onto that helps.

## How the data model behaves (gotchas)
- `lessons` is the ground truth for everything: Ledger, Calendar, student profile, invoices and
  the monthly schedule all read the same table. `recurring_slots` is only the weekly template
  that projects "not logged" blocks and generates lessons.
- `lessons.one_off` (boolean): true = manual ad-hoc lesson, false = generated from a slot. The ✦
  marker reads this column, not `slot_id`. Deleting a slot nulls `slot_id` on its lessons (FK
  `on delete set null`) but leaves `one_off` intact, so Planner "Remove" hard-deletes safely.
- `students.end_date` = "lessons run until" (inclusive). After it, the student counts as
  discontinued everywhere: Ledger generation, Calendar projection, Planner and pickers skip them.
  Shared helpers: `TL.isEnded(end)` and `TL.pastEnd(end, dateISO)`.
- Discontinuing a student sets their `recurring_slots.active=false` (reactivating turns them all
  back on). Planner, Calendar and Ledger only load `active=true` slots.
- A cancelled lesson's billable amount is its `compensation` (0 if none); pages normalise
  `amount` on load.
- Deleting an account = `api/delete-account.js` (Stripe, storage, Google, then `org_delete_solo()` in the DB, then the login). The audit log, `org_settings` and fee snapshots are append-only EXCEPT inside `org_delete_solo` (flag `td.deleting_org`). Never delete a tutor's rows by hand from the browser or SQL editor: it copies their data into the audit log. Any new table with an `org_id` is covered automatically; it just needs `on delete cascade`.
- Invoice "subject" comes from the billed lessons; "level" comes from the student profile.
- Centre billing start (T36): `org_plans.billing_starts_on` (a 1st) + `first_month_billable_override`, set only by a platform admin via `org_set_billing_start` (reason required, refused once a snapshot exists for the start month or later). The monthly job records months BEFORE the start as `platform_fee_snapshots.billable = false`, `waived_reason = 'pilot'`, fee 0 (anything billing downstream, T31b, must skip `billable = false`); the first billed month counts the override (rounded like any count; `active_students` keeps the real count, `override_students` the number used).

## Product principle: the centre decides, we build it (owner's rule, 2026-11-24)
- Anything that depends on a centre's own business process is an **option in the sign-up wizard** (`assets/js/org-settings.js`, saved in `org_settings`), never a
  hard-coded rule: who marks attendance, how long tutors have to mark, who records cancellations, whether remarks are required, who sees parents' contact, who may
  replace a tutor, and so on. We then implement **every** option completely, in the database first, with tests for each value.
- An option that isn't built yet is marked `soon` (or `soonOptions` for one choice of a dropdown) so the wizard never offers something that does nothing.
- What stays fixed is integrity, not process: nobody marks a lesson before its day, nobody overwrites another person's mark, tutors never see or edit a lesson's price,
  date or time, and tutors have no table access at all. (Status follows attendance, set by the system, never typed by a tutor. A tutor can flag trials, or type the charge
  for an absent / cancelled lesson, ONLY if the centre chose that.)
- Before adding a rule, ask: "would two centres reasonably decide this differently?" If yes: a setting, a default, SQL validation in `org_validate_settings`, a JS
  check that the options match (tests/org-settings.test.js), and a test per value. Process rules are read as of TODAY (a change applies to every lesson from then on);
  money rules follow the settings in force when the lesson happened.
- Billing of absent / cancelled lessons works the way the app always has (owner, 2026-11-24): the lesson becomes `cancelled` and its billable amount is its
  **compensation**, a number someone types when marking it, **0 if the family isn't charged**; null = "charge pending" (an admin still has to type it, and invoicing
  must wait for it). Who types it is a centre setting (`lessons.compensation_entered_by`: admin default, or tutor, capped at the lesson's own price). Attended = `done`.
  This status/compensation mapping only applies to centres; solo tutors' lessons never change status just because attendance is set.
- Still to build: tutors editing their own lessons (`timetable_editing = tutors_own`, marked soon); remarks sent to parents (soon); missed-remarks reminders by email
  (soon, needs the email provider); the staff screens (marking and correcting attendance, typing pending charges, flagging trials); centre invoicing, which must treat a
  cancelled lesson with a null compensation as not ready to invoice.

## Organisations (multi-tenant, v253+)
- `db/migration_org_foundation.sql` (undo: `_down.sql`): every business table has `org_id`; each solo tutor is an
  organisation of one (kind 'solo', preset 'solo'); centres are kind 'centre'. Access = `memberships` (owner / staff with
  `permissions[]` / tutor / parent) via `org_can(org, perm)`, `org_can_read(org)`, `org_role(org)`. Old `tutor_id` policies
  apply only inside solo orgs (`org_is_solo`). `org_row_guard` fills org_id for old pages and blocks cross-org writes.
- Settings: `org_settings` rows are append-only and effective-dated; save with `org_save_settings`; read with
  `org_settings_on(org, date)`. Schema/defaults/labels in `assets/js/org-settings.js` (tests check enums match the SQL).
- Money: integer cents only, all maths in `assets/js/money.js` (tested). GST once per invoice, half up.
- Centres: issued invoices immutable (credit notes); solo tutors' flows must not change. Default: tutors paid only after the
  parent's payment is reconciled (wizard question; changes audited). TutorDeck never holds a centre's money.
- Centre tutors (`memberships.role = 'tutor'`) have NO table access on purpose: `lessons` also holds what parents pay, and row-level security can't hide columns.
  They use only `tutor_my_lessons(from, to)` and `tutor_mark_attendance(...)` (db/migration_tutor_access.sql): explicit column list (never `l.*`, never
  rate/amount/paid), attended/absent + notes (and the two cancellations if the centre chooses), on their OWN lesson (`lessons.taught_by` = their membership id), from the lesson's day (the
  centre's timezone) for the centre's own window (`lessons.attendance_window_days`, default 14), never over someone else's mark; these settings are the centre's:
  `lessons.attendance_by`, `attendance_window_days`, `cancellations_marked_by`, `compensation_entered_by`, `trials_flagged_by`, `remarks.required`, `remarks.deadline_hours`, `tutors_see_parent_contact` (default off), `replacement_tutors`. Staff/owners use the
  normal `org_write` policy. Don't add a tutor policy on any table, and don't add a column to `tutor_my_lessons` without checking it isn't money.
- Tutor screen = `tutor.html` + `assets/js/tutor.js` (+ pure logic in `assets/js/tutor-core.js`, unit-tested; browser check: `node tests/tutor-page.check.js` with
  `python3 tests/server.py 8765`). It only calls the two tutor functions. Which menu a login gets is `TL.roleMode()` ("solo" | "both" | "tutor-only", remembered 12 hours,
  decided by `TL.detectRole()` in requireAuth): tutor-only = an active tutor membership in a centre and no students of their own, so they get a one-item menu and Home
  sends them to /tutor; "both" adds My lessons to More. Any doubt or error = "solo" (the usual menu), so nothing solo tutors have can disappear.
- Live schema snapshot: `db/baseline_2026-11.sql`. Test SQL with `bash tests/sql/run.sh` (throwaway Postgres), never live.
- Dev Supabase project: `tuzxsqkfzrjssnpcoale` (baseline + the 7 standard migrations org_foundation … org_separation + bundle 4's pack + payment_fix + bundle 5's pack applied; bundle 6's pack, `docs/orchestrator/dev-apply-pack.sql` (own_lessons, import, tutor pay, statement matching, invoice email, make-up credits, export), is built but NOT yet applied). Live: `rnjvswkejbrhbaytutai`
  (NONE of the org/billing/attendance/delete migrations are on live yet). Migration order everywhere: org_foundation → billing → attendance → tutor_access → org_delete → function_lockdown → org_separation → staff_home → staff_students → staff_attendance → staff_charges → staff_trials → staff_timetable → staff_slots → staff_reassign → reassign_link → tutor_schedule → money_settings → centre_money → centre_invoice_run → centre_payments → payment_fix → invites → fee_050 → centre_billing_method → centre_billing_start → tutor_profile → tutor_payout → payout_permission → centre_deposits → centre_refunds → centre_late_fees → centre_credit_undo → slot_changes → tutor_moves → b5_fix → tutor_own_lessons → import → centre_tutor_pay → statement_matching → invoice_email → makeup_credits → tutor_link_propose → org_export
  (undo in reverse); `bash tests/sql/run.sh` runs all forty-two and the undo checks. Between 16:00 and 24:00 UTC run it as `PGTZ=Asia/Singapore bash tests/sql/run.sh` (an older money test compares with `current_date`). `centre_credit_undo` needs `fee_050` first (it reads `org_default_centre_plan()`). No migration function may contain a DELETE or UPDATE without WHERE (the Supabase API refuses it: tests/migrations-safeupdate.test.js). **Replaced-function chains (bundle 6): `org_validate_settings(jsonb)` is re-created by `import`, `invoice_email` and `makeup_credits` and `centre_invoice_run_rows` by `tutor_own_lessons` and `makeup_credits`; each file carries the CUMULATIVE version of the one before, so the order above is not free, and each `_down` hands back the previous link (`tests/sql/bundle6_chain_test.sql`). Any new migration that replaces one of these two functions must copy the LATEST version (read it from the newest file in that chain), never the version it was written against. A migration's `_down` may only drop what the migration itself created (the import's undo leaves `students.online_link` / `start_date` and `recurring_slots.taught_by`: they belong to `staff_slots` and `centre_deposits`). A table with an `org_id` must be listed in `org_export_catalog()` (exported, or excluded with a reason), and in `assets/js/org-export-core.js`.**
- Centre money tables (`db/migration_centre_money.sql`, T4 S1; `org_counters`, `centre_invoices`, `centre_invoice_lines`, `centre_payments`, `centre_payment_allocations`): centres only, read-only for browsers (NO write policy; writes come only from later SECURITY DEFINER functions). A document is a draft with NO number; the number is taken from `org_counters` by the trigger in the same statement that sets `status='issued'` (gap-free; opening number settable once by the owner via `centre_set_opening_number`). Issued/void documents and their lines never change (corrections = credit notes); payments and allocations are append-only (a mistake = a `reversal` payment row + negative allocations). Totals must equal `centre_gst_totals()`, which shares its vectors with `assets/js/money.js` in `tests/gst-vectors.csv`. Free-text fields are redacted in the audit copy (`centre_money_audit`).

- **Bundle 6 (T46, branch `claude/bundle-6`): what the code now has.** Import stage A (owner-only, create-only, undo for 7 days; `billing.starts_from` is saved but the invoice run does NOT read it yet); tutor pay (`/centre-tutor-pay`, owner + staff with `run_tutor_pay`; tutors never see rates or pay; tables `tutor_pay_*`); tutors adding their own one-off lessons / weekly slots / Create lessons (centre option; a tutor-made lesson for a student with no staff-made price is held as "charge pending", and there is no staff screen for `staff_set_lesson_price` yet); bank statement matching (Money > Statements; custom columns only, DBS/OCBC/UOB marked soon); invoice emails (Money > Email, `email_queue` + append-only `email_send_log`; server `api/email-send.js`, `api/email-cron.js` daily 01:00 UTC, `api/brevo-webhook.js`; previews mail only `@tutordeck.com.sg` + `INVITE_TEST_ALLOW`); make-up credits (Attendance > Make-ups; one missed lesson = one credit; `api/credits-cron.js` exists but is NOT in `vercel.json`: Hobby allows two crons and `billing-cron` + `email-cron` already use them); owner-only data export (Organisation > Data export). Money has seven tabs (Invoice run, Invoices & payments, Deposits, Refunds, Late fees, Statements, Email). Server env for the email jobs: `BREVO_API_KEY`, `BREVO_WEBHOOK_SECRET` (16+ chars), `CRON_SECRET`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` (DEV values on Preview, LIVE on Production), optional `INVITE_TEST_ALLOW`, `EMAIL_LINK_ORIGIN`, `EMAIL_PLATFORM_DAILY_CAP`.

## Open threads
- T-Leng has past lessons wrongly showing ✦ one-off: an old slot deletion (before `one_off`
  existed) nulled their `slot_id`, and the backfill set `one_off=true`. Fix per student with a
  targeted `update lessons set one_off=false …` after previewing the rows with T-Leng.
- Mobile navigation (paused, Oct 2026): idea of a persistent bottom tab bar
  Home · Calendar · Ledger · Students · More, with More holding the rest. The Dashboard has since
  gained a Finance | Teaching toggle, so revisit the plan before building.
- A dummy test account (dummy students only) is planned for testing write flows safely.

## Current to-dos
1. Rebrand "T-Leng Tuition" → "TutorDeck" across the UI — done in feature/rebrand-ui (v145).
   Still outside the repo: Supabase auth email templates / sender name. Landing footer still has
   the "Also by T-Leng Tuition: MugCorner" cross-promo line (decide whether to keep).
2. Find/replace any hard-coded old github.io URLs (Supabase redirectTo, emails, etc.).
   As of 2026-10-17 none remain in the code (last one, the landing footer, removed in v145); check Supabase Auth → URL Configuration
   and email templates, which live outside the repo.
3. Sync `dev` with `main` (done on 2026-10-17 in feature/sync-main-claude-md, v144).
4. Google OAuth app (Calendar sync) is published but unverified (100-user cap, warning screen).
   Google Cloud → Branding links currently point to https://tutordeck.vercel.app (/privacy,
   /terms). Switch them to tutordeck.com.sg once that domain is live (DNS returned NXDOMAIN
   on 2026-10-18), then submit for verification.
5. Later: custom SMTP for auth emails (DEV's sign-up confirmation emails need it too); Vercel Pro before
   charging customers (Hobby plan is non-commercial).
6. **Platform billing (Stripe) — GO-LIVE CHECKLIST. Remind the owner of this whenever billing, Stripe or going live comes up.**
   Built and tested on the DEV Supabase project + Stripe SANDBOX only (branch claude/sleepy-bell-xfr6zb). Before real money:
   - Previews already use DEV (config.js by hostname). Check before shipping that `www.tutordeck.com.sg` still gets the live project (tests/config.test.js and tests/env-hosts.check.js).
   - **"Delete my account" depends on server config** (api/delete-account.js replaced the old Edge Function; there is NO browser fallback). Production has no
     `SUPABASE_URL` today, so the function answers 503 and deletion stops working in Production the moment that code ships. So LIVE `SUPABASE_URL` +
     LIVE `SUPABASE_SERVICE_ROLE_KEY` (+ live `STRIPE_SECRET_KEY` for anyone who ever subscribed) are prerequisites of shipping it, not just of charging.
     Also run `migration_org_delete.sql` on LIVE (the order is foundation → billing → attendance → org_delete) before the code lands on dev/main.
   - Run `db/migration_org_foundation.sql` then `db/migration_billing.sql` on LIVE (SELECT preview + explicit yes first; dry-run on a restored backup;
     the billing one marks every existing solo tutor `grandfathered = true`).
   - Vercel **Production** env: LIVE `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` (LIVE project's own key), LIVE `STRIPE_SECRET_KEY`
     (`sk_live_…`), and a new LIVE webhook secret. Today `STRIPE_SECRET_KEY`/`STRIPE_WEBHOOK_SECRET`/`SUPABASE_SERVICE_ROLE_KEY` are shared by
     Production + Preview with SANDBOX/DEV values — split them. Billing refuses to run without `SUPABASE_URL`, so Production is inert until it is set.
   - Stripe LIVE mode: recreate the products/prices (same lookup keys: solo_pro_monthly S$14.90, solo_pro_yearly S$149, centre_base_monthly,
     centre_student_monthly, **at S$0.50 = 50 cents per billable student**, T30) and a LIVE webhook endpoint for https://tutordeck.vercel.app/api/stripe-webhook (+ www.tutordeck.com.sg) with the 6 events
     listed in api/stripe-webhook.js. Live Stripe account needs business details/bank account (TutorDeck Pte. Ltd.).
   - Stripe LIVE: save a **customer portal configuration** (Settings → Billing → Customer portal): update card, invoice history, switch
     monthly/yearly with proration, cancel at period end (the sandbox one is bpc_1UfDQgCAjCe5dyzzzWFnx8xr). Without it api/billing.js `portal` fails.
   - **Centre fee job** (api/billing-cron.js, daily cron 16:30 UTC = 00:30 SGT, production only): set `CRON_SECRET` (16+ random chars) in Vercel Production;
     run `db/migration_attendance.sql`; create each centre's Stripe subscription BY HAND with both items (centre_base_monthly ×1 and
     centre_student_monthly ×0, billing anchor 12:00 SGT = 04:00 UTC on the 1st, so the job at 00:30 SGT always runs first; if a renewal was already
     invoiced the job refuses with `renewal_already_billed` (HTTP 500) and changes nothing) and save its id in `org_subscriptions.stripe_subscription_id`; use `?dry=1` first. The job
     refuses (price_mismatch) if Stripe's prices differ from the centre's `org_plans`. Needs the Phase 2 attendance/trial screens or counts stay 0.
   - **Centre fee S$0.50 (T30):** run `db/migration_fee_050.sql` on LIVE (after the other migrations, with the SELECT preview + yes first: it changes `org_plans` rows only
     where a centre still holds the old default S$100 + 40c; billed months in `platform_fee_snapshots` are never touched). The LIVE Stripe price `centre_student_monthly`
     must be created at S$0.50 (never at S$0.40). In the Stripe SANDBOX the old S$0.40 price must be replaced by a new S$0.50 price carrying the same lookup key
     (Stripe prices are immutable): click-by-click in `docs/orchestrator/T30-stripe-steps.md`. Until the Stripe price and the table agree the job refuses with `price_mismatch`.
   - **Centre billing method (T31a, owner 2026-11-26):** every centre has `org_plans.billing_method`: `stripe` (default, self-serve as above: items kept) or `invoice` (managed: TutorDeck
     invoices the centre and it pays by PayNow; set ONLY by a platform admin through `org_set_billing_method(org, method)` when a centre contacts us). Run
     `db/migration_centre_billing_method.sql` on LIVE (after fee_050; undo `_down.sql`) BEFORE the code that reads it ships. For `invoice` centres the monthly job only records the fee
     snapshot (never calls Stripe, no Stripe subscription needed), `api/billing.js` answers 403 `centre_invoice` ("contact us") and the webhook ignores their events; the Plan tab says
     "billed by invoice and PayNow". Every centre's Plan tab has a "Want a hand? Contact us for assisted setup, invoicing and PayNow" card (address in ONE constant,
     `assets/js/contact.js`, now tutordeckadmin@gmail.com). Platform invoicing for `invoice` centres is planned separately (T31b). Note: self-serve Stripe CHECKOUT for centres does not exist (never built:
     centre subscriptions are created by hand as above); portal and card work once a centre has a Stripe customer.
   - Vercel Pro before charging (Hobby is non-commercial). Decide GST (TutorDeck is not GST-registered: prices carry no GST, Stripe Tax stays off).
   - Pricing decisions: solo free ≤5 active students, Solo Pro S$14.90/mo or S$149/yr, 30-day trial (once per org), existing solo tutors unlimited.
     Centre S$100 + S$0.50 × billable students (owner, 2026-11-26; was S$0.40, T30) is UNDER REVIEW (SchoolTracs charges ~S$148 per branch at 400 students; owner chose to keep it for now).
   - **REVOKE the Vercel "Protection Bypass for Automation" token** (Vercel → project → Settings → Deployment Protection) created for the Stripe
     SANDBOX webhook (note: "Stripe sandbox webhook testing - REVOKE before going live"), and delete/replace the sandbox webhook endpoint that carries it
     in its URL. The LIVE webhook must point at a custom/production domain (not behind Vercel protection) with no bypass token in the URL.
   - Run `db/migration_tutor_access.sql` on LIVE after attendance (order: foundation → billing → attendance → tutor_access → org_delete → function_lockdown → org_separation → … see the full order above).
   - Run `db/migration_function_lockdown.sql` on LIVE last (after org_delete): pins search_path, takes anonymous/any-user access away from the org helper
     functions and trigger functions. Still flagged by the advisor on the existing live setup and NOT touched here: `invoice_by_token` (intentionally public),
     `client_errors_recent/prune` (only a rate-limit count / a trigger) and `rls_auto_enable` (Supabase-managed event trigger).
