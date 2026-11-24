# TutorDeck — project context

## What this is
TutorDeck is a tutor admin web app (students, weekly planner, calendar, ledger/payments,
PayNow invoices, WhatsApp reminders, exams, student profiles). It started as
"T-Leng Tuition Dashboard" and is being rebranded to TutorDeck.
Company: TutorDeck Pte. Ltd. (Singapore), founded by Raphael and T-Leng. We are both
developers AND we both use the app live for our own tuition businesses.

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

## Data warning
There is ONE LIVE Supabase database (project `rnjvswkejbrhbaytutai`), and it holds REAL student/payment data.
Preview and dev deployments also hit this live DB. So:
- Don't write code or run scripts that bulk-delete/modify data without asking me first.
- Test with dummy students.
- Any new `db/migration_*.sql` must be run in the Supabase SQL editor BEFORE the code that
  needs it is merged to main, or pages will error with "column does not exist". Because
  previews hit the same DB, run it before the code lands on `dev` too.
- A separate DEV Supabase project exists (`tuzxsqkfzrjssnpcoale`, dummy data only) and is where migrations get tried first. But the site's
  `assets/js/config.js` still points at LIVE, so every Vercel preview still reads and writes LIVE data, except the server functions in `api/`
  on a branch that has its own `SUPABASE_URL` Preview variable (billing branch only). Don't point `config.js` at DEV without asking.
- Nightly encrypted DB backups run via GitHub Actions (.github/workflows/db-backup.yml, 30-day artifacts).
  The repo is PUBLIC: never commit dumps, never print data in workflow logs. Restore steps: README → Backups.

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
- Live schema snapshot: `db/baseline_2026-11.sql`. Test SQL with `bash tests/sql/run.sh` (throwaway Postgres), never live.
- Dev Supabase project: `tuzxsqkfzrjssnpcoale` (baseline + org_foundation + billing + attendance + org_delete + function_lockdown migrations applied). Live: `rnjvswkejbrhbaytutai`
  (NONE of the org/billing/attendance/delete migrations are on live yet). Migration order everywhere: org_foundation → billing → attendance → org_delete → function_lockdown
  (undo in reverse); `bash tests/sql/run.sh` runs all five and the undo checks.

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
5. Later: point a DEV build's `config.js` at the DEV project so previews stop touching live data; custom SMTP for auth emails; Vercel Pro before
   charging customers (Hobby plan is non-commercial).
6. **Platform billing (Stripe) — GO-LIVE CHECKLIST. Remind the owner of this whenever billing, Stripe or going live comes up.**
   Built and tested on the DEV Supabase project + Stripe SANDBOX only (branch claude/sleepy-bell-xfr6zb). Before real money:
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
     centre_student_monthly) and a LIVE webhook endpoint for https://tutordeck.vercel.app/api/stripe-webhook (+ www.tutordeck.com.sg) with the 6 events
     listed in api/stripe-webhook.js. Live Stripe account needs business details/bank account (TutorDeck Pte. Ltd.).
   - Stripe LIVE: save a **customer portal configuration** (Settings → Billing → Customer portal): update card, invoice history, switch
     monthly/yearly with proration, cancel at period end (the sandbox one is bpc_1UfDQgCAjCe5dyzzzWFnx8xr). Without it api/billing.js `portal` fails.
   - **Centre fee job** (api/billing-cron.js, daily cron 16:30 UTC = 00:30 SGT, production only): set `CRON_SECRET` (16+ random chars) in Vercel Production;
     run `db/migration_attendance.sql`; create each centre's Stripe subscription BY HAND with both items (centre_base_monthly ×1 and
     centre_student_monthly ×0, billing anchor 12:00 SGT = 04:00 UTC on the 1st, so the job at 00:30 SGT always runs first; if a renewal was already
     invoiced the job refuses with `renewal_already_billed` (HTTP 500) and changes nothing) and save its id in `org_subscriptions.stripe_subscription_id`; use `?dry=1` first. The job
     refuses (price_mismatch) if Stripe's prices differ from the centre's `org_plans`. Needs the Phase 2 attendance/trial screens or counts stay 0.
   - Vercel Pro before charging (Hobby is non-commercial). Decide GST (TutorDeck is not GST-registered: prices carry no GST, Stripe Tax stays off).
   - Pricing decisions: solo free ≤5 active students, Solo Pro S$14.90/mo or S$149/yr, 30-day trial (once per org), existing solo tutors unlimited.
     Centre S$100 + S$0.40 × billable students is UNDER REVIEW (SchoolTracs charges ~S$148 per branch at 400 students; owner chose to keep it for now).
   - **REVOKE the Vercel "Protection Bypass for Automation" token** (Vercel → project → Settings → Deployment Protection) created for the Stripe
     SANDBOX webhook (note: "Stripe sandbox webhook testing - REVOKE before going live"), and delete/replace the sandbox webhook endpoint that carries it
     in its URL. The LIVE webhook must point at a custom/production domain (not behind Vercel protection) with no bypass token in the URL.
   - Run `db/migration_function_lockdown.sql` on LIVE last (after org_delete): pins search_path, takes anonymous/any-user access away from the org helper
     functions and trigger functions. Still flagged by the advisor on the existing live setup and NOT touched here: `invoice_by_token` (intentionally public),
     `client_errors_recent/prune` (only a rate-limit count / a trigger) and `rls_auto_enable` (Supabase-managed event trigger).
