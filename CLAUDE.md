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
There is only ONE Supabase database, and it holds REAL student/payment data.
Preview and dev deployments also hit this live DB. So:
- Don't write code or run scripts that bulk-delete/modify data without asking me first.
- Test with dummy students.
- Any new `db/migration_*.sql` must be run in the Supabase SQL editor BEFORE the code that
  needs it is merged to main, or pages will error with "column does not exist". Because
  previews hit the same DB, run it before the code lands on `dev` too.
- A separate dev Supabase project is planned but not set up yet.

## Conventions
- Bump the cache-buster (`?v=N`) in every page when CSS/JS changes: `bash bump-version.sh <N>`.
  Check `main` first so we don't both ship the same number.
- Add an entry to the "Raphael's updates" log in README.md for each change (newest first).
- Keep mobile layouts working (app is heavily used on phones; breakpoint 820px).
- Shared helpers live on `window.TL` in assets/js/app.js; pages call `TL.requireAuth("navId", init)`.
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
- Invoice "subject" comes from the billed lessons; "level" comes from the student profile.

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
   Google Cloud → Branding links currently point to https://tutordeck.vercel.app (/privacy.html,
   /terms.html). Switch them to tutordeck.com.sg once that domain is live (DNS returned NXDOMAIN
   on 2026-10-18), then submit for verification.
5. Later: separate dev Supabase project; custom SMTP for auth emails; Vercel Pro before
   charging customers (Hobby plan is non-commercial).
