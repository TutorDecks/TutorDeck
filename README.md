# TutorDeck

*(formerly the T-Leng Tuition Dashboard — TutorDeck Pte. Ltd., Singapore)*

A password-protected dashboard for running a private tutoring business: students,
weekly schedule, lessons, payments, PayNow invoices, WhatsApp reminders, exams and
per-student profiles. Static frontend on **Vercel**, real accounts + database
on **Supabase**. No build step — plain HTML/CSS/JS.

---

## What it does

- **Dashboard** — KPIs (pending, collected, projected, lessons this week), income
  chart, exam countdown.
- **Planner** — Mon–Sun grid of recurring weekly slots (time, subject, rate).
- **Ledger** — lessons paid/unpaid/scheduled, outstanding-by-student, total pending,
  projected income; log a week or a whole month from the schedule; edit / postpone /
  cancel / delete lessons; mark paid.
- **Students** — roster with add / edit / **merge** (de-dupe safely) / discontinue /
  remove, plus a per-student **Profile** page.
- **Profile** — one page per student: totals, full lesson history (editable),
  recurring slots, exams (editable), and lesson notes (topics / homework / plan).
- **Invoices** — PayNow QR invoices you can print, **save to the app**, or
  **send on WhatsApp** (image attached); a saved-invoices page.
- **WhatsApp reminders** — one-tap reminders with editable, placeholder-driven
  message templates.
- **Exams** — track assessments with type (WA1, SA2, Prelim, PSLE…) and a countdown.
- **Settings** — business name, PayNow ID, invoice prefix, message templates.

---

## Part 1 · One-time setup (~10 min)

### a. Supabase database
1. Create a free project at **supabase.com**.
2. Open **SQL Editor → New query** and run these files **in order** (paste contents, Run):
   1. `db/schema.sql`            — tables + row-level security (the foundation)
   2. `db/migration_paynow.sql`  — PayNow fields on your profile
   3. `db/migration_exam_type.sql` — assessment type on exams
   4. `db/migration_invoices.sql`  — saved invoices table
   5. `db/migration_messages.sql`  — WhatsApp message templates
   6. `db/migration_recipient.sql` — recipient (parent) name on students
   Each is safe to re-run. *(Going forward: any file under `db/…migration….sql` must
   be run once in the SQL editor before its feature works — a
   `column … does not exist` error always means a migration hasn't been run yet.)*
3. *(Optional)* `db/seed.sql` imports the original spreadsheet data. Run it **after**
   you've created your account (it assigns data to the first user).
4. **Sign-in emails:** for a single-user tool, the simplest path is
   **Authentication → Providers → Email → turn off "Confirm email"** so you can sign in
   instantly. (To send real confirmation/reset emails instead, set up custom SMTP —
   see "Email / SMTP" below.)

### b. Credentials
**Project Settings → API**, copy the **Project URL** and the **publishable (anon)** key
into `assets/js/config.js`. The publishable key is safe to commit — RLS protects the
data, not the secrecy of the key.

### c. Deploy on Vercel
The repo (**TutorDecks/TutorDeck** on GitHub) is connected to the Vercel project **tutordeck**.
No build step — Vercel serves the files as-is.
- **`main` → production:** https://tutordeck.vercel.app (custom domain
  **www.tutordeck.com.sg** being activated). Every merge to `main` deploys within ~1 min.
- **`dev` and feature branches → preview URLs** (see the PR / Vercel dashboard).
- GitHub Pages is no longer used — the old `github.io` URLs are dead. If you add the site URL
  anywhere (Supabase **Auth → URL Configuration** redirect URLs, email templates), use the Vercel
  / custom domain.

### d. Create your account
Open the site → **Create account** → you're in.

---

## Part 2 · After setup — getting your dashboard running

A fresh account starts empty (the dashboard shows zeros). Build it up in this order —
each step feeds the next:

1. **Settings** — enter your **business name**, **PayNow ID** (mobile or UEN) and
   **invoice prefix**. Optionally customise the **WhatsApp message templates**. Do this
   first so invoices and reminders work later.

2. **Students** — add everyone. For each: name, type (individual / pair / centre),
   level, **contact number** (needed for WhatsApp), and **message recipient** (the
   parent's name, if you message a parent rather than the student).

3. **Planner** — for each student, add their **recurring weekly slot(s)**: day,
   start/end time, subject and rate. This builds your repeating timetable.

4. **Ledger → Log the week or month** — press **"Log this week (dates)"** or
   **"Log this month"** to generate lessons from your slots (it skips anything already
   logged). Use **+ Add lesson** for one-offs and trials.

5. **Run the week** — as lessons happen, **mark paid** when money comes in, or
   **Postpone / edit** / **Cancel** as plans change. Finished lessons flip to
   "done / unpaid" automatically when you next open the Ledger or Dashboard, and pile up
   under **Outstanding by student**.

6. **Get paid** — on an outstanding balance: **Invoice** generates a PayNow QR (then
   **Save to app** and/or **Send on WhatsApp** with the invoice attached), or **Remind**
   sends a quick WhatsApp nudge. Saved invoices live on the **Invoices** page.

7. **Exams** — add assessments (with type, e.g. WA1 / PSLE) so the countdown surfaces
   them. You can also add/edit exams straight from a student's Profile.

8. **Profiles & notes** — open a student's **Profile** to see totals and history, edit
   their details/lessons/exams, and after each lesson jot **topics covered, homework,
   and a plan for next time** under Lesson notes.

9. **Dashboard** — once data exists it fills in on its own: pending, collected,
   projected, lessons this week, income chart and exam countdown.

> **Minimum to a working dashboard:** Students → Planner slots → "Log this week".
> Everything else layers on top.

---

## Everyday reference

- **Projected this month** = the sum of this month's ledger lessons (scheduled + done,
  paid + unpaid), excluding cancelled. Fill the month (step 4) to see the full figure.
- **De-duplicating students:** (Merge is hidden from the roster menu since v160 — see that entry) use **Merge** (moves lessons/slots/exams onto the kept
  student), never **Remove** — Remove deletes the student *and* their lessons.
- **Stopped lessons:** use **Discontinue** to hide a student from the slot/lesson
  pickers while keeping their history; Reactivate anytime.
- **WhatsApp templates** (Settings) understand these placeholders:
  `{name}` (recipient — parent if set, else student) · `{student}` · `{business}` ·
  `{amount}` · `{count}` · `{month}` · `{invoice}` · `{paynow}` · `{date}` · `{year}`.

---

## Updating the app (important for deploys)

- **Branch workflow:** `main` is production and **protected** (PR only, no direct pushes, no
  force-push). Work on a short-lived `feature/<short-name>` branch off `dev` → PR into `dev` →
  test on the preview URL → PR `dev` → `main`.
- **One live database:** previews and `dev` hit the **same Supabase DB as production**, with real
  student and payment data. Test with dummy students, and never bulk-modify data from a script.
- **Migrations first:** run any new `db/migration_*.sql` in the Supabase SQL editor **before**
  the code that needs it reaches any deployed branch (`dev` included), or pages error with
  `column … does not exist`.
- **Cache-busting:** every page links `assets/css/app.css?v=N` (and the JS with the same `?v=N`).
  After a change, run `bash bump-version.sh <N>` to bump it everywhere so browsers fetch fresh
  files. Check `main` first so two people don't ship the same number. The current version
  is marked at the top of `app.css` (e.g. `/* v9 */`); you can confirm the live file by
  opening `…/assets/css/app.css?v=N` and checking the first line.
- **Deploys vs. cache:** wait for the Vercel deployment to show **Ready**, then hard-refresh
  (or DevTools → Network → Disable cache) when iterating.
- **Email / SMTP (optional):** Supabase's built-in email is rate-limited (testing only).
  To send real confirmation/reset emails, set up **custom SMTP** (e.g. Brevo or Resend)
  under **Authentication → SMTP Settings**, then raise the limit under Rate Limits.

---

## Project structure

```
login.html              Sign in / create account (public)
index.html              Dashboard — KPIs, income chart, exam countdown
planner.html            Weekly Mon–Sun planner (recurring slots)
ledger.html             Lessons, payments, outstanding, projections, invoices
students.html           Roster (add / edit / merge / discontinue)
student.html            Per-student profile (history, slots, exams, notes)
exams.html              Exam tracker (with assessment type)
invoices.html           Saved invoices
settings.html           Business / PayNow / message templates

assets/css/app.css      House style (navy / gold / cream / teal); ?v= cache-bust
assets/js/
  config.js             Supabase URL + publishable key (the only credentials)
  supabase.js           Creates the Supabase client
  app.js                Shell, nav, auth guard, shared helpers
  dashboard.js planner.js ledger.js students.js student.js
  exams.js invoices.js settings.js
  paynow.js             PayNow / SGQR QR payload builder
  (qrlib.js)            Optional self-hosted QR library (if the CDN is ad-blocked)

db/
  schema.sql            Tables + row-level security
  migration_*.sql       Incremental schema additions (run in the SQL editor)
  seed.sql              Optional import of the original spreadsheet
  restore_*.sql         One-off recovery scripts
```

---

## Tech notes

- **Stack:** vanilla HTML/CSS/JS, Supabase (Postgres + Auth), Chart.js, a PayNow QR
  builder, and html2canvas (loaded on demand) for the WhatsApp invoice image.
- **Security:** every table is isolated by row-level security (`tutor_id = auth.uid()`),
  so the publishable key is safe in the repo. Never put service-role keys or SMTP
  passwords in any committed file — those belong only in the Supabase dashboard.
- **Multi-tutor ready:** the schema is keyed per tutor, so additional accounts each get
  their own isolated data.

---
## Raphael's updates

A running log of Raphael's changes, newest first.

### 2026-10-17 — Invoices: Saved → Sent → Paid; "Payment screenshot" (v170)

**Needs `db/migration_invoice_sent.sql`** (adds nullable `invoices.sent_at`). The pages work before it's run:
Invoices detects the missing column and simply hides the Sent bits.
- Tapping **Send on WhatsApp** in the Ledger now stamps `sent_at` on the saved invoice ("Save to app" alone
  does not). Invoices shows **Not sent** (amber) / **Sent <date>** / **Paid <date>**, a **Not sent** filter,
  a "Not sent yet" count in the summary strip, and **Mark as sent** / Undo in the sheet for invoices sent
  some other way. CSV export gains a Sent column.
- "Proof" is now called **Payment screenshot** in the UI (the stored field is still `proof_path`).

### 2026-10-17 — Invoices redesign: list + detail sheet (v169)

- Summary strip: **Paid** · **Awaiting payment** · **Proof attached (x / y)** for the chosen period.
- One control row: **All | Awaiting · N | Paid**, a period picker (This year / Last year / All time /
  Custom dates…) and ⋯ → Export CSV. Period now counts paid invoices by paid date and awaiting ones by
  issue date (previously any date range silently hid every unpaid invoice).
- Each invoice is one row (initials, student, invoice no · issued date, amount, Paid <date> / Awaiting chip,
  📎 when proof is attached). Tap → sheet (bottom on phones, right panel on desktop) with **Mark as paid**
  (primary) / Mark as unpaid, Print / Save PDF, Open Ledger, paid date, proof attach/view/remove, the invoice
  preview, and Delete. All actions reuse the existing functions (togglePaid still syncs lessons).

### 2026-10-17 — Needs notes above Today on phones (v168)

Phone order is now Needs notes (only shown when something is missing notes) → Today → Tomorrow → Exams.

### 2026-10-17 — Shorter Home on phones (v167)

Phone-only (≤820px): Money card drops the bar legend; **Needs notes** collapses to one tappable line
("Needs notes · 3 ▾", `#yd-toggle`); an empty **Tomorrow** shrinks to one slim line; Today's lessons are
flat rows; Upcoming exams shows the next 3 (All → Exams). Desktop unchanged. Roughly 30% less scrolling.

### 2026-10-17 — Home: one Money card + labelled Money / Teaching sections (v166)

The four stat tiles and the separate "This month" bar repeated the same numbers, so they became one
**Money** card: Collected (with "26% of $X booked") beside Owed to you (all-time, links to the Ledger), the
month's collected / unpaid / upcoming bar underneath, and "See income ›" to Insights. Below it, a
**Teaching** section (header shows lessons this week) holds Today, Needs notes, Tomorrow and Upcoming exams
("N in the next 14 days" now sits in the exams card). Today no longer repeats the date.

### 2026-10-17 — No full stop after the business name on Home (v165)

Avoids "Ltd.." on names ending in "Pte. Ltd." and reads less like a slogan.

### 2026-10-17 — Home greeting toned down (v163)

Dropped the handwritten Sacramento script (too loud next to the rest of the app). The greeting is back
to a small grey Manrope line over the business name, now 40px desktop / 32px phone (was 64 / 44).

### 2026-10-17 — Handwritten Home greeting (v162)

The greeting line is now a teal handwritten script (Google Font **Sacramento**, the closest free match
to the Mac's "hello"), over a bigger business name (64px desktop / 44px phone). Sacramento is only used
here; it's loaded via a second `@import` at the top of app.css.

### 2026-10-17 — Apple-style Home headline (v161)

Home's title is now two lines instead of "Good afternoon, Raphael Tuition": a small grey greeting
("Good afternoon") over the business name in large, heavy, tightly-tracked type with a full stop
("Raphael Tuition."), then the date. Classes `.hi-eyebrow` / `.hi-name` in app.css; built in
`requireAuth()` (app.js). Falls back to just the greeting if no business name is set.

### 2026-10-17 — Merge removed from the roster menu (v160)

The ⋯ menu is now Edit details / Discontinue (or Reactivate) / Remove. The merge code (`openMerge`, `doMerge`,
`#merge-modal`) is left in place, unused; to bring it back, re-add the `data-merge` button in `rowHtml()`
(students.js — there's a comment with the exact line).

### 2026-10-17 — Cleaner Students roster (v159)

- Rows: initials avatar, name, level chip, parent, contact. The whole row opens the profile (desktop too),
  so the "Profile" button is gone; Edit details / Merge with… / Discontinue (or Reactivate) / Remove moved
  into one **⋯** menu per row.
- **Active | Discontinued · N | All** toggle replaces the status dropdown (default Active; the hidden
  `#s-status` select still drives `renderRoster()`). Level/Parent filters stay on desktop and fold behind a
  **Filter** button on phones. Search also matches parent names in the placeholder copy.
- Phones: a single white list with "level · parent" under each name.

### 2026-10-17 — Quieter "Exit parent view" pill (v158)

The pill is now frosted white with grey text and a thin border (was solid navy), smaller, and sits
bottom-right on desktop / centred above the tab bar on phones. Extra bottom padding in Parent view so it
never covers the last row.

### 2026-10-17 — First-time tips; Parent view exit pill (v157)

- New helper **`TL.coach(key, anchorEl, html)`** (app.js): a small dark tip under an element, shown ONCE
  per browser until the tutor taps **Got it** (remembered in localStorage as `td_tip_<key>`). Use it to
  introduce new / non-obvious features instead of permanent banners.
- First use: the student page's **Parent view** button explains itself once.
- Parent view no longer shows the "fees and editing are hidden" banner (the parent saw it too). Instead a
  neutral floating **Exit parent view** pill sits at the bottom of the screen (above the phone tab bar).

### 2026-10-17 — Parent view rebuilt around progress (v156)

The Tutor | Parent toggle became one **Parent view** button (eye icon). In Parent view:
- a slim teal banner "Parent view · fees and editing are hidden" with **Exit** sits above the card;
- the money strip is replaced by parent-friendly stats — lessons attended, latest score per subject
  (up to two, with ▲/▼ vs the previous exam) and the next exam (`renderParentKpis()` in student.js);
- the Progress tab opens first (tabs: Progress · Lessons · Schedule); Edit, Ledger, contact details and
  the Notes tab are hidden; Lessons shows past lessons only (no empty "No notes recorded" future rows).
Also fixes the card losing its bottom padding (clipped avatar) when the money strip was hidden.

### 2026-10-17 — Cleaner student profile header; "More info" on phones (v155)

The header's label wall (LEVEL / CONTACT / LOCATION / MESSAGES TO) became a level chip (plus
Discontinued / "Until <date>" chips when relevant) and icon lines: phone (tap → WhatsApp chat via wa.me),
location, "Messages to <name>", notes. Desktop shows the lines inline; phones hide them behind a
**More info ▾** toggle so the card is just initials, level, buttons and totals.

### 2026-10-17 — Student profile redesign; named greeting on Home (v154)

- **Student page** (`student.html`): a profile card (initials avatar, level/contact/location/messages-to,
  Edit + Ledger, Tutor | Parent view) with the four totals in one strip, then tabs
  **Lessons · Notes · Progress · Schedule** instead of one long scroll (last tab remembered per browser).
  Parent view (was "Client view") hides money/editing as before and folds Notes into Lessons.
- **Progress chart:** fixed a bug where the first two subjects were both teal. Subjects now get a fixed,
  colour-blind-checked order (blue `#2a78d6`, orange `#eb6834`, violet `#6250d6`, pink `#e87ba4`,
  yellow `#eda100`, aqua `#1baf7a`; validated with the dataviz palette checker) and each line ends in a
  direct label with its latest %. Phones get a smaller canvas so labels stay readable.
- Group sub-tabs (Roster | Exams) no longer show on the student page, where neither applies.
- **Home** greets by business name: "Good afternoon, Raphael Tuition" (falls back to just the greeting).

### 2026-10-17 — TutorDeck logo (v153)

New product mark: a small stack of cards in white on a teal rounded square (`assets/img/logo.svg`, also
inlined as `LOGO` in app.js). Desktop top bar now shows the logo + "TutorDeck" on the left; the round
avatar on the right keeps the tutor's own business initials, and its menu shows the business name + email.
The phone More sheet shows the logo with the tutor's business name. Every page uses the logo as its
browser-tab icon (favicon).

### 2026-10-17 — Outstanding: plain list + slide-up detail sheet (v152)

"Who owes you" is now a clean list — avatar, name, lesson count, how old the oldest debt is (amber ≥7 days,
red ≥14) and the amount. Tap a row (student or household) to open its **sheet**: a bottom sheet on phones,
a right-hand panel on desktop. The sheet holds everything the old card had: tick lessons, **Mark all paid**
(primary), Remind, Invoice, per-lesson Mark paid, and the household "together" actions. Ticking lessons
swaps the whole-balance buttons for "… selected" ones. The sheet re-renders from fresh data after each
action and closes itself once that balance is cleared.
Implementation: `renderOutstanding()` builds `outBlocks` (one HTML card per student/household, same
markup and data-attributes as before) and wires the existing handlers on `#owe-body` instead of
`#outstanding`; `openOwe(key)` / `closeOwe()` manage the sheet. No payment/invoice logic changed.

### 2026-10-17 — Top navigation bar on desktop; sidebar removed (v151)

Desktop now has a slim sticky bar across the top: brand · Home · Schedule · Students · Money, with
Materials/Settings as icon buttons and an account avatar (email + Sign out) on the right. Page content
is centred (max 1240px). Under 1000px the nav shows icons only; phones (≤820px) keep the bottom tab bar.
The old `.sidebar` markup is no longer rendered (`mountShell()` in app.js builds `.topnav`).

### 2026-10-17 — New TutorDeck look: ink + teal, Manrope (v150)

Picked from three mocked directions (canvas "TutorDeck visual directions", option B with C's font).
- **Font:** Manrope everywhere (headings, body, numbers; tabular figures). `--serif` now points at the
  same family so older rules keep working.
- **Colours:** ink `#13233F` (text, sidebar), one accent teal `#0F766E` (primary actions, active tab, paid),
  owed `#B4432F`, warning amber `#B45309`, warm-white ground `#FAF9F6`, lines `#E8E5DE`. The old gold and
  cream are gone; the var names (`--gold`, `--cream`, `--navy`) still exist but now hold the new values.
- Phone tab bar is white with a teal active tab; desktop sidebar stays ink with a teal active item.
- Overdue tags are amber (a warning), not the accent.
- Marketing pages (index/landing/privacy/terms) not restyled yet.

### 2026-10-17 — Ledger declutter (v149)

- The three big KPI cards became one slim summary strip: **Owed** · **Collected** · **Booked** for the
  selected month (same ids, so `ledger.js` logic is unchanged).
- One control row: Outstanding | Records + a compact month navigator. "This month" only appears when
  you've moved off the current month; "All" is now an "All time" chip.
- Records toolbar: **+ Add lesson** is the one primary button. Log this week / Log this month / custom
  range live in a **Log lessons ▾** menu; Export CSV moved into **⋯**.
- Desktop rows: actions ("Edit", Cancel, Delete) stay hidden until you hover the row. "Postpone / edit"
  is now just "Edit" (the form still handles postponing).
- Phones: Records filters fold behind a **Filter** button next to search; the Outstanding cards make
  **Mark all paid** the solid primary button with Remind / Invoice as quiet text buttons.

### 2026-10-17 — Home redesign; finance moves to Money → Insights (v148)

The Dashboard's Finance | Teaching and Month | Year toggles are gone from Home.
- **Home** (`app.html`): greeting + date, four small tap-through tiles (Owed to you → Ledger, Collected
  this month → Insights, Lessons this week → Calendar, Exams in the next 14 days → Exams), then Today,
  Needs notes, Tomorrow, Upcoming exams and a slim "This month" collection bar. Desktop is two columns
  (Today/Tomorrow left; Needs notes/Exams/This month right); phones stack them in that priority order.
- **Insights** (`insights.html`, new Money sub-tab): the old Finance view unchanged (month KPIs,
  collection bar, income chart, Year view with by-student / by-subject breakdowns).
- `dashboard.js` serves both pages: it reads the page id from `#view[data-page]` and skips any element a
  page doesn't have (`setText`, guarded chart/teaching/toggle code).
- KPI tiles are 2-per-row and smaller on phones everywhere.

### 2026-10-17 — New navigation: 5 grouped tabs with icons (v147)

Nine equal nav items became four groups plus "More", so it's clearer where things live:
**Home** (Dashboard) · **Schedule** (Calendar, Weekly planner) · **Students** (Roster, Exams, student
profiles) · **Money** (Ledger, Invoices) · **More** (Materials, Settings, Sign out).
- Phones: a fixed bottom tab bar (icon + label) replaces the ☰ drawer; More opens a bottom sheet with
  Settings, Materials and Sign out.
- Desktop: the sidebar shows the four groups; Materials/Settings/Sign out sit at the foot.
- Pages inside a group show as underline sub-tabs under the title (e.g. Calendar | Weekly planner).
- Proper line icons (Lucide paths, inline SVG) replace the old text symbols. All in `mountShell()` in
  `assets/js/app.js` (`GROUPS` / `EXTRA`) and the "Navigation v2" block at the end of `app.css`.

### 2026-10-17 — Sign out always visible in the phone menu (v146)

On iPhone the ☰ drawer was sized with `100vh`, which is taller than the visible screen when Safari's
toolbar is showing, so the Sign out button at the bottom sat hidden behind it. The drawer now uses
`100dvh` (the visible height) plus the safe-area inset, and Sign out has a bigger tap target.

### 2026-10-17 — Rebrand "T-Leng Tuition" → TutorDeck across the UI (v145)

Every page title, the login / email-confirmed / password-reset cards, the landing page header and
footer, and the Privacy/Terms pages now say **TutorDeck** (monogram **TD**). Privacy/Terms name
**TutorDeck Pte. Ltd.** as the provider. The sidebar still shows each tutor's own business name; only
its fallback (no business name set) changed to TutorDeck. Reminder messages with no business name now
say "from your tutor" instead of "from T-Leng Tuition". Business-name placeholders read
"e.g. Bright Minds Tuition". Data export downloads as `tutordeck-data-YYYY-MM-DD.json`. Removed the dead
`tlengengtuition-oss.github.io` link from the landing footer. Internal identifiers (`TLENG_CONFIG`,
the `tlengSync` Google Calendar tag) are unchanged on purpose — renaming the tag would orphan
already-synced calendar events.

### 2026-10-17 — Sync `dev` with `main`, add CLAUDE.md, README for Vercel (v144)

Merged `main` into `dev` (T-Leng's Teaching "needs notes" + Planner-names change and the landing
footer), which had also been numbered v143, so this bumps to **v144** to keep the cache-buster
unique. Added `CLAUDE.md` (project context, protected-`main` branch workflow, live-DB warnings,
conventions) so every Claude session loads it. README now documents the Vercel hosting and the
feature-branch → PR workflow instead of GitHub Pages.

### 2026-10-02 — Explicit `one_off` flag on lessons; Planner can hard-delete slots again (v143)

The ✦ "one-off" status used to be *inferred* from `slot_id IS NULL`, which was fragile: deleting a
weekly slot nulled `slot_id` on its past lessons (DB `on delete set null`) and silently mislabelled
real recurring lessons as one-off. Now each lesson stores its own `one_off boolean` — set at creation
(generated / logged-from-slot → false; manual ad-hoc adds in the Ledger or Calendar → true) — and every
✦ display (calendar block, detail tag, CSV/Google-Calendar sync) reads that column instead of
`slot_id`. Because the label no longer depends on the slot existing, **Planner "Remove" hard-deletes
again** (reverting v142's retire-only rule) — a slot is just a template, and binning it loses no lesson
history. (Rationale corrected from v142: slots hold no analytic data the Ledger doesn't already have;
the real risk was the mislabelling, which the explicit flag removes.)

**Requires a one-time migration** — run `db/migration_lesson_one_off.sql` in Supabase (adds the
`one_off` column and backfills it from `slot_id`) **before** this ships to main, or the Calendar loads
and lesson inserts will error on the missing column.

### 2026-10-02 — Planner "Remove" retires a slot instead of deleting it (v142)

Deleting a weekly slot from the Planner used to wipe `slot_id` off every lesson it had generated
(the DB's `on delete set null` rule on `lessons.slot_id`), so all that student's logged lessons lost
their recurring link and showed as **✦ one-off**. `removeSlot` now **never hard-deletes** — it always
**deactivates** the slot (`active:false`): it leaves the Planner, stops projecting on the Calendar, and
stops generating new lessons, while the slot and its lessons stay stored and linked (kept for data /
analytics). It comes back by re-adding the slot or reactivating the student. The Planner query now also
filters `active=true` so a deactivated slot disappears from the grid. (Discontinuing a student was never
the cause of the one-off relabelling — that only deactivates slots, keeping `slot_id` intact.)
Pre-existing behaviour, now fixed going forward; lessons orphaned by past hard deletions can't be
auto-relinked (their slot is gone).

### 2026-10-01 — Scheduled discontinuation: a "lessons run until" date per student (v137)

Students can now be given an optional **end date** (e.g. after O-Levels) so logging stops automatically
instead of relying on remembering to discontinue them. Lessons run through the end date **inclusive**;
after it the student is treated as discontinued everywhere, with no new lessons generated and no phantom
projections:

- **Students form** — new "Lessons run until" field; passed the date, a student shows an `ended …` badge
  and moves to the Discontinued section automatically (computed from the date — nothing is deleted).
  Reactivating a past-end student also clears the stale end date. A future date shows an `ends …` badge.
- **Ledger** — Log week / Log month / custom range all skip any date past a student's end date.
- **Calendar** — no projected ("not logged") blocks appear for a student after their end date.
- **Planner & add-lesson pickers** — an ended student drops off the Planner and the manual
  add-lesson student dropdowns, same as a discontinued one.
- One shared definition in `TL` (`isEnded` / `pastEnd`, end date inclusive) so every surface agrees.

**Requires a one-time migration** — run `db/migration_student_end_date.sql` in Supabase (adds the
`end_date` column to `students`) **before** this ships to main, or the student/ledger/calendar/planner
loads will error on the missing column.

### 2026-09-30 — Invoice subject: from the billed lessons (not all Planner slots)

Refined the previous change: sourcing subjects from the Planner slots meant a student with e.g. Math
AND Chinese slots showed *both* on every invoice, even a month where only Math was taught. `subjLevel`
now takes **subjects from the invoiced lessons themselves** (only what's actually billed appears) and
keeps **level from the student profile**. So a Math-only month reads "Math · Sec 3", a mixed month
"Math, Chinese · Sec 3", and a lesson's stale level is still ignored. Verified in a rendered invoice.

### 2026-09-30 — Invoice subject/level: subjects from Planner, level from profile

An invoice read its "Bill to" subject/level from each lesson's own stored fields, so a lesson saved
with a stale subject/level (e.g. the student was switched on the add form without the subject
updating) mislabelled the invoice — one student showing another's level. Rewrote the invoice's
`subjLevel` to source **subjects from the student's active Planner slots** (a student can take several)
and **level from their profile** (one grade across subjects), never from the lesson fields; falls back
to the lessons only when a student has no active slot / no profile level. Ledger now loads student
`level` into `levelById`. Fixes wrong levels on invoices without needing to correct old lesson rows.

### 2026-09-30 — Monthly schedule: logged lessons only (no phantom projections)

Reversed the v133 "project like the calendar" approach — it re-projected the weekly slot onto every
matching weekday and only suppressed a day if a lesson *claimed* that exact occurrence (slot_id|
slot_date). When a lesson was moved by adding a new day rather than postponing (leaving the original
slot occurrence un-resolved), the projection filled the old day back in — a phantom (e.g. a Friday
2–3:30pm showing on 16/10 when that lesson had moved to Thu 15/10). `schedFor` now: if the month has
any logged lessons, show only those real rows (cancelled omitted) — never re-project; only a month
with nothing logged yet falls back to previewing the weekly slots. So a logged month is exactly your
real lessons, phantom-free.

### 2026-09-29 — Monthly schedule now matches the Calendar exactly

The schedule projected from weekly slots but skipped projection per-*date*, so a lesson postponed to
a different day printed a phantom line on its original slot day (the Calendar removes it). Rewrote
`schedFor` to use the Calendar's own claiming logic (calendar.js buildBlocks): a lesson claims its
slot occurrence by `slot_id|slot_date` (so a postponed lesson vacates its original day) plus a
date+time claim; cancelled lessons are omitted. Fetches `slot_id`/`slot_date` on the profile's
lessons now. Verified against postpone-across-dates, time-edit, cancel, and one-off cases.

### 2026-09-29 — Monthly schedule: drop the greeting + WhatsApp contact picker

Removed the "Hi {name}!" line from the schedule message (now opens straight with "Here are your
lessons for {month}:"). Since student/parent numbers aren't linked yet, `sendScheduleWA` no longer
dials a saved contact — it opens WhatsApp with the text so the tutor picks who to send to.

### 2026-09-29 — Student profile: copy-ready "Monthly schedule" to send

Added a **Monthly schedule** card to the student profile (tutor-only) so you can mass-send a student
their month at a glance instead of counting off the calendar. A ‹ month › picker builds an editable
message — greeting + one line per lesson formatted `7/10 (Wed) 4–6pm` + a total — with **Copy** and
**Send on WhatsApp** (opens `wa.me` to the student's contact) buttons and a live count. Occurrences
come from the student's weekly slots projected across the month; a logged lesson wins for its date
(so a postponed/edited-time lesson shows once at its real time and a cancelled one drops out).
`student.js` gains the schedule helpers (`schedFor`/`scheduleMsg`/`timeRange`), stores `slots`
module-level, and only fetches **active** slots now. No schema change.

### 2026-09-27 — Discontinuing a student drops them from the Planner (and Calendar)

Discontinuing a student in the Students tab only flipped `students.active` — their recurring slots
lingered on the Planner and kept projecting lessons on the Calendar/Ledger. Now `setActive` also flips
those slots' `active` flag (Calendar/Ledger already filter active slots, so projections stop and
return on reactivate; logged lessons untouched), and the Planner's `load()` filters slots to active
students — which also hides any already-discontinued students immediately. Reactivating restores the
slots everywhere. (Students discontinued before this shipped: their slots are still `active` in the DB
so the Calendar may still project them until you toggle them off/on once — the Planner already hides
them via the student filter.)

### 2026-09-27 — Calendar Add-lesson: fix student defaults not populating

Choosing a student in the calendar's Add-lesson modal didn't fill in subject/rate — `applyStudentDefaults`
only filled *blank* fields, so once the first student pre-filled, switching to another student did
nothing. Rewrote it to **overwrite** from the chosen student's recurring slot (subject/rate/split) and
their record's `level` (now fetched in `loadStatic`); a student with no recurring slot clears
subject/rate and still fills level. Note: rate/subject come from the recurring **slot** (Planner), not
the student record — a student with no slot has nothing to auto-fill beyond level.

### 2026-09-23 — Calendar: recompute the amount when a lesson's duration changes

Postponing/editing a lesson's times on the calendar (or reverting to slot) updated `start_time`/
`end_time` but never `amount`, so the earned figure stayed stale until you reopened the lesson in the
Ledger and saved. Fixed: the month fetch + calendar block now carry `rate`/`split`, and `savePostpone`
/`doRevert` recompute `amount` via a new `amtFor()` helper — `splitAmt(rate,start,end,split)` when a
rate is stored (matches the Ledger), else the old amount scaled by the new/old duration ratio so it
never drops to zero. Verified the math (5 cases) and a Chrome parse (JSC still throws a false syntax
error on this file). No schema change.

### 2026-08-29 — Calendar: add a lesson without leaving the page

Added a gold **+ Add lesson** button to the calendar toolbar and an add-lesson modal
(`#add-modal`, `ca-*` fields) so a one-off lesson can be logged straight from the calendar instead of
going to the Ledger. `openAdd`/`saveAdd` reuse the calendar's existing helpers (`splitAmt`,
`statusFor`, `refreshAfterMutation`) and insert a lesson with `slot_id` null (shows as a ✦ one-off);
picking a student auto-fills blank subject/level/rate/split from their recurring slot
(`applyStudentDefaults`). No schema change. (Chrome-verified parse — JSC gave a false syntax error
on this file.)

### 2026-08-25 — Mobile: fix white-on-white cards (roster + profile lessons)

The phone list cards (white `.tbl tr`) sat inside a white `.card` container, so they blended together.
Made the container transparent on mobile (`background/border/box-shadow: none`) for the students
roster (`.card:has(#s-table)`, `#disc-card`) and the profile's lesson-history
(`#p-lhist-sec .card:has(#p-ltable)`), so each white card now stands out on the cream page. (Left the
Ledger Records card alone for now — its "today" row is cream-highlighted and would blend on a cream
page; that one wants a flat-list treatment instead.)

### 2026-08-25 — Students roster: clean tappable list on mobile

The roster table became a tall stacked card per student on phones — four labelled lines (Name /
Parent / Level / Contact) plus a five-button action strip, ~one screen each. Added a mobile block in
students.html: each row is now a compact 2-line card (Name + Level on top, Parent + Contact muted
below); the per-row action buttons are hidden on phones (manage from the profile / on desktop), and
tapping a row opens that student's profile (`wire()` adds a `matchMedia`-gated row click; rows carry
`data-id`). Applies to the active and Discontinued tables. Desktop table unchanged.

### 2026-08-25 — Student page: clean mobile layout

The phone view was dominated by four full-width tall KPI blocks (endless scroll) and tall 5-row
lesson-history cards. Added a mobile block in student.html: KPIs become a compact **2×2 grid** with
tightened padding and uppercase labels; **lesson history** becomes compact tappable rows
(date+amount / subject+status) — tapping a row opens the existing edit sheet (`openLesson`, gated to
≤820px via matchMedia; row gets a `data-lid`), matching the Records pattern; and the toolbar controls
align left and wrap cleanly instead of right-floating over three rows.

### 2026-08-25 — Stop iOS auto-zoom on inputs (Records search etc.)

iOS Safari zooms into any focused input smaller than 16px and doesn't zoom back out — the Records
search (14px) and filter selects (13.5px) triggered it. Rather than force a zoom-out (only possible
by disabling pinch-zoom, which harms accessibility), keep controls at 16px on phones so Safari never
zooms: added a `@media(max-width:820px){ input,select,textarea{font-size:16px} }` rule (plus the
`.filters` selectors explicitly, to beat their smaller sizes). Verified computed size is 16px.

### 2026-08-25 — Outstanding collapses by default; Calendar legend back on mobile

Two things. (1) **Outstanding** student cards are now **collapsed by default** — each shows just its
header (name, days overdue, amount, and the Remind/Invoice/Mark-all-paid actions) with a caret;
tapping the header (ignoring its buttons/checkbox/link) toggles the lesson list. Much easier to scan
students; expand only when you want to see or pick individual lessons. (2) **Calendar**: the category
legend/toggles (Paid / Unpaid / Scheduled / Not logged / Cancelled) were `display:none` below 820px —
now shown as a full-width wrapping row under the Week/Month control, so the filters are usable on
phones again.

### 2026-08-25 — Mobile Records: compact tappable rows + lesson detail sheet

Reworked the Records list on phones from tall stacked cards into **compact, scannable rows** — date +
amount on the top line, student + status badge below (subject/level/checkbox/action-buttons hidden).
Each row now carries `data-lid`; tapping one (anywhere but the student link) opens a new **detail
sheet** (`#rec-detail`) showing the full lesson — student, subject, level, time, amount, status — with
the row's actions relocated there (Postpone/edit, Cancel/Restore, Delete) plus Close. The tap is gated
to ≤820px via `matchMedia`, so desktop keeps its inline table + action buttons. Fixed a specificity
trap where the generic phone-table `td{display:block}` rule outranked the per-cell hide rules.

### 2026-08-25 — Mobile: tidy the Ledger's Outstanding + Records

On phones the Outstanding action buttons (Remind / Invoice / Mark all paid) and per-lesson "Mark
paid" ran off the right edge because their rows didn't wrap — the group/household containers weren't
width-capped, so the flex rows sized to content and spilled (then got clipped). Added a mobile block
in ledger.html: cap `#outstanding`/`.hh-block`/`.card.group` to the screen, stack each group/household
header, and let the action rows wrap to full-width (with `min-width:0` children so wrapping actually
kicks in); lesson rows stay one line with the subject shrinking. Records: the filter selects now form
a 2×2 grid under a full-width search (they were stretching the whole card wide), cards are denser, and
the low-value Level row is hidden on mobile. Desktop unchanged.

### 2026-08-25 — Mobile: move the nav bar to the bottom, hamburger on the right

Relocated the mobile nav bar from the top to a fixed **bottom** bar with the hamburger on the
**right** (thumb-reachable for one-handed use), and flipped the drawer to slide in from the right to
match the trigger. Content gets `padding-bottom` (incl. `env(safe-area-inset-bottom)` for the iOS
home indicator) instead of top padding; the bar itself is safe-area-padded with a top shadow. The
mobile boot skeleton now paints a navy strip along the **bottom**. Brand stays on the left of the
bar. Desktop unchanged.

### 2026-08-25 — Mobile: top bar + hamburger + slide-in nav drawer

Replaced the cramped wrap-around row of nav pills on phones with a proper mobile pattern. `mountShell`
now renders a fixed navy **top bar** (`.mnav`: hamburger + monogram + brand) and a `.nav-scrim`
backdrop; the hamburger toggles a `nav-open` class on `.app`. Below 820px the sidebar becomes an
off-canvas **drawer** that slides in from the left (full vertical nav + email + sign-out) over a
dimmed scrim; tapping the scrim, a tab, or pressing Esc closes it, and the page is locked from
scrolling while open. The authoritative mobile block sits at the end of app.css so it overrides the
old pill-row rules. The mobile boot skeleton now shows a matching navy top strip. Desktop unchanged.

### 2026-08-07 — Loading skeleton matches the shell (no sidebar flash)

The earlier optimistic-mount + `@view-transition` attempt still flashed a white sidebar between
pages, so it was reverted (requireAuth/mountShell back to their simple form). Instead the boot state
is now a CSS-only **skeleton that mirrors the mounted layout**: `body:has(#view)::before` paints a
steady navy sidebar strip (matching `.sidebar`'s 236px) with `::after` a spinner centred in the
content area. So during load the sidebar reads as constant navy and only the content shows a
spinner; the moment `mountShell` swaps `#view` for `.app`, the strip becomes the real sidebar and the
spinner becomes the content — no white flash. Mobile (top-bar nav) falls back to plain bg + centred
spinner. `html{background}` set to the app bg to kill any inter-page white.

### 2026-08-07 — No more flash of raw markup while a page loads

Shell pages render `<div id="view">` immediately, but `requireAuth` does a few async round-trips
(session, MFA, profile) before `mountShell` swaps `#view` for the `.app` shell — so the bare,
sidebar-less markup flashed the whole time. Added a CSS-only boot state in app.css: `#view` is hidden
and a centred gold spinner shows over a clean background via `body:has(#view)::before/::after`. Both
clear automatically the moment the shell mounts (`#view` is replaced, so the selector stops
matching), and `.app` fades in. Scoped with `:has(#view)` so the auth/landing pages are untouched;
degrades to a plain background on browsers without `:has`. Honors `prefers-reduced-motion`.

### 2026-08-07 — Record-payment modal: flag an already-attached screenshot

Marking a lesson paid always showed an empty screenshot upload, even when the covering invoice
already had a proof attached (e.g. uploaded earlier from the Invoices tab, then un-paid/re-paid for
testing). `openPayModal` is now async and calls `existingProofFor(ids)` — if a covering invoice has
a `proof_path`, it shows a teal "✓ A screenshot is already attached — leave blank to keep it, or
choose a file to replace it" note and relabels the field as optional-replace. Leaving it blank never
touches the existing `proof_path`, so the original attachment is preserved. Guarded against a stale
note if the modal is reopened for different lessons mid-lookup.

### 2026-08-07 — Ledger ⇄ Invoices: keep invoice paid-status in sync from every path

Marking a lesson paid didn't reliably update its invoice. `syncInvoiceOnPaid` only ever set an
invoice to *paid* (never reverted) and was called from the Outstanding "Mark paid" flow but **not**
from the Records add/edit modal's "already paid" checkbox. Replaced it with
`reconcileInvoicesForLessons(ids, date, {create})`: for every invoice covering those lessons it sets
status *paid* when all its lessons are paid, else *issued* (reverting a previously-settled invoice) —
and it now runs from both `doMarkPaid` (Outstanding, `create:true` so a receipt is still generated
when no invoice exists) and `saveLesson` (Records edit, `create:false`). The reverse direction
(Invoices tab → lessons) already existed in invoices.js, so the two stay consistent. Note: a
multi-lesson (e.g. whole-month) invoice only flips to paid once **every** lesson on it is paid.

### 2026-08-06 — Invoices: bank-transfer payment method for overseas clients (no PayNow)

Overseas clients can't use PayNow, so an invoice can now show **bank-transfer details instead of the
PayNow QR**. New `db/migration_bank_transfer.sql` adds bank fields to `profiles`
(`bank_account_name`, `bank_name`, `bank_account_no`, `bank_swift`) and a `pay_by_bank` flag to
`students` — **run it before this deploys or the Ledger/Settings/Student pages error on the missing
columns.** Settings gained a "Bank transfer" section; the student edit modal gained a "Pays by bank
transfer" toggle. In the Ledger, `openInvoice`/`openInvoiceMany` branch on the student's flag: bank
clients get a bank-details block (`invoiceHTML` `d.bank`, no QR, no QR library load), everyone else
keeps the PayNow QR. Combined household invoices use bank if any member is flagged. The paid-receipt
"Paid to" and the WhatsApp caption (new `DEFAULT_INVOICE_BANK`, points to on-invoice details) follow
the same flag.

### 2026-08-04 — Invoice WhatsApp: pick the send flow by OS (restore friend's share sheet)

The v81 Mac fix gated the native share sheet to `isMobileLike()`, which also knocked **Windows
desktop** off the share sheet (onto download+wa.me) — breaking the flow for the friend on
Windows/Android. Replaced `isMobileLike()` with `isMacDesktop()` and inverted the gate: the OS
share sheet (image attached — the original flow) now runs on **everything except macOS desktop**
(Windows/Linux desktop, Android, iOS), and **only macOS desktop** skips it for the download + wa.me
+ clipboard flow (where the Mac share sheet has no WhatsApp target). `isMacDesktop` = Mac platform
with no touch points, so iPad/iPhone (Mac-ish UA but touch) correctly stay on the share sheet.

### 2026-08-04 — Calendar: "Revert to slot" follows the planner's current day + time

Revert used to take the **date** from the lesson's stored `slot_date` but the **time** from the live
recurring slot — so after you edited a student's slot day/time on the planner, a revert put the new
time on the old date (and lessons postponed before the `slot_date` migration, whose original date was
backfilled to their postponed date, wouldn't move the date at all). `doRevert` now derives *both* from
the recurring slot: it anchors on the occurrence week (`slot_date`) and lands on the slot's **current
weekday** at its **current time**. No change when the slot weekday is unchanged (it already equals
`slot_date`'s weekday); when the planner day moved, revert tracks it, and old stuck-date lessons snap
back onto the real slot day.

### 2026-08-03 — Student page: Tutor / Client view toggle

Added a **Tutor / Client** segmented toggle to the student page so a profile can be shown to a
parent without exposing money or edit controls. Client view adds a `.client` class to `#view`; CSS
then hides the KPI row (Outstanding/Collected/Total billed), per-slot rates, and every edit
affordance (Exams "+ Add", the header actions). It also **swaps the two tutor sections — the
lesson-history table and the separate Lesson-notes list — for one combined "Lessons & notes" list**
(`#p-lessons-sec`, `renderClientLessons`): each live lesson as date · subject with its topics /
homework / next-lesson notes underneath, no amounts and no buttons. Tutor view keeps the original
table + notes list untouched. Everything else client-facing stays: particulars (location, contact,
level), progress, exams with topics/marks, weekly slots. Defaults to Tutor and isn't persisted, so
money shows by default on load. The toggle is pinned to the right edge of the toolbar (placed after
the action buttons) so it stays put when client view hides "Edit details / Open ledger"; the
combined list has the same inset padding as the notes/slots cards.

### 2026-08-03 — Ledger: one shared period navigator in the header (both tabs)

Unified the Outstanding month-picker and the Records period nav into a single **‹ month › · This
month · All** control in the header (under the 3 KPIs, above the tabs). One `period` state
(`{mode,y,m}`, persisted as `tl_period`) now drives the KPIs, the Outstanding list, and the Records
table together — switch tabs and the same navigator applies. Dropped `outPeriod`, the per-view
controls, and `toggleAll`; `refreshPeriod()` re-renders everything on change.

### 2026-08-03 — Ledger: outstanding period → month picker + All (superseded the toggle)

Replaced the Overdue/This month/All toggle with a **‹ month › navigator + All** control above the
outstanding list. `outPeriod` is now `"all"` or a `"YYYY-MM"` month; the arrows step months (with
year rollover), "All" shows everything. It scopes the whole view (counts, invoicing, marking) and
the pending KPI: All → "Total pending" (all-time), a month → "Pending · <Month Year>". Persisted in
localStorage.

### 2026-08-03 — Ledger: Overdue / This month / All filter + split pending KPI

For monthly (bulk) billers, "Outstanding" mixed genuinely-overdue lessons with the current month
still accruing. Added an **Overdue / This month / All** toggle above the outstanding list
(persisted in localStorage, default All) that scopes the whole view — counts, invoicing, and
marking paid — to the chosen period. "Overdue" = lessons before this month; "This month" = current.
Also split the **"Total pending"** KPI into **"Overdue"** (headline = before-this-month unpaid) with
a "N overdue · $X this month" note, so the number isn't inflated by the accruing month. Collected /
Projected KPIs unchanged.

### 2026-08-03 — Outstanding: name checkbox = "select all this student's lessons"

Removed the "select students to bill together" combine feature (redundant with household grouping)
— dropped `selectedStudents`, the combine bar, and its CSS. Repurposed the checkbox by the student
name into a **master toggle** that ticks/unticks all that student's outstanding lessons (shows a dash
when only some are ticked); the household checkbox does the same across the whole household. Drives
the existing "Invoice/Mark N selected" buttons. Household ⌂ grouping + "Invoice together" untouched.

### 2026-08-03 — Remove the abandoned payment-link / self-report route

Dropped the unfinished "send a link" route (went back to the simple WhatsApp image send). Deleted
`pay.html`, `assets/js/pay.js`, `db/migration_invoice_share.sql`, `db/migration_invoice_selfpay.sql`,
`ledger.js#sendInvoiceLink`, the `_invShareToken` plumbing, `config.SITE_URL`, and the
`self_reported` badge/column in `invoices.js`. Kept the income record + transaction-screenshot
feature (`proof_path` + receipts bucket). The now-unused DB objects (`share_token`, `self_reported`
columns; `invoice_by_token` / `mark_invoice_paid_by_token` / `is_valid_share_token` functions; the
`shared/` storage policies) are harmless but can be dropped — see the cleanup SQL if desired.

### 2026-08-01 — Self-reported payment: parent taps "I've paid" (`v83`)

The parent can record their own payment from the pay link — no gateway, no fees, no manual editing.
On `pay.html` an **"I've paid"** button opens a small form (date, defaulted to today, + optional
transaction screenshot). Submitting uploads the screenshot to `shared/<token>/…` and calls a
security-definer `mark_invoice_paid_by_token(t, date, proof)` that marks the invoice **and its
lessons** paid on that date, flags it `self_reported`, and stores the proof — so the Ledger stays
consistent. Tutor's Invoices page shows a **"reported by parent"** badge (glance-and-verify).
Storage: an anon insert policy scoped to `shared/<valid-token>/` (via `is_valid_share_token`), plus
a tutor read policy for their own invoices' shared proofs. Run `db/migration_invoice_selfpay.sql`
(needs `migration_invoice_share.sql` + the receipts bucket first).

### 2026-08-01 — Shareable invoice payment link (send a link, not an image) (`v82`)

Sidesteps WhatsApp's image/text quirks: instead of attaching an image, send a **link** to a public
pay page. Each invoice gets an unguessable `share_token`; a security-definer `invoice_by_token(t)`
function returns just that one invoice's rendered HTML to `anon` (no login, no enumeration). New
public **`pay.html`** (`?t=<token>`) renders the invoice with its embedded PayNow QR + a
**Save to Photos** button (share-sheet "Save Image" on mobile, download on desktop). Ledger invoice
modal gains **🔗 Send payment link** — saves the invoice (captures the token via `.select()`), builds
`pay.html?t=…`, and opens WhatsApp with the message + link as plain text (copied to clipboard too).
Also: WhatsApp image send now copies the message to the clipboard and skips the dead-end macOS share
sheet (desktop → WhatsApp Web). Run `db/migration_invoice_share.sql`.

### 2026-07-25 — Invoice history / income record + transaction screenshots (`v66`)

Turned the invoices flow into a tax/claims-ready income record.
- **Accurate paid date + proof at mark-paid.** Every "Mark paid" trigger in the Ledger now opens
  a **Record payment** modal capturing the *actual* payment date (default today, editable to match
  the transaction) and an optional **transaction screenshot**. `doMarkPaid` marks the lessons on
  that date, settles/creates the invoice, and uploads the screenshot to it.
- **Invoice creation dated to payment.** `createPaidInvoice`/`syncInvoiceOnPaid` take a paid date
  (sets `issued_date` + `paid_date`) and return the invoice id so proof can attach. Paying without
  an invoice still auto-generates a paid one (pre-existing behaviour), now with the right date.
- **Invoices page = income record.** Added a paid-date range filter (+ "This year"), a running
  **income total** for the range, **CSV export** (paid date, student, invoice no., total, proof
  y/n), and a **Proof** column to attach/view/remove the screenshot per invoice.
- **Storage.** New private `receipts` bucket (per-tutor folder RLS) + `invoices.proof_path` column.
  Run `db/migration_invoice_proof.sql` and `db/migration_receipts_bucket.sql`.

### 2026-07-25 — Google sync: diff-based reconcile + one-off/postponed symbols (`v62`)

Replaced the wholesale month-replace with a **diff/reconcile** (the app stays source of truth).
Each event is stamped with its `tlLessonId` in `extendedProperties`; each sync lists the month's
app events, matches them to current lessons, and only acts on differences: create missing, **update
drift (including Google-side edits, compared via a fingerprint of title/time/location/description)**,
skip unchanged (zero API calls), delete orphans/duplicates/legacy-untagged. Re-syncing an unchanged
month now costs one list call instead of 2×N writes. Status reports the breakdown + elapsed time
(e.g. "Synced ✓ 34 lessons in 4s · 2 added, 1 updated" or "already up to date"). Event titles now
carry the ↻ (postponed) and ✦ (one-off) symbols, matching the in-app calendar; the description
spells them out too. `listAppEvents` returns full event objects; `setGcalTarget` updated for that.

### 2026-07-25 — Google sync: calendar picker survives reloads (`v54`)

The calendar dropdown was empty after every reload — the "connected" flag persisted but the list
of calendars was only fetched with a live token and never cached, so there was nothing to pick.
Now the list is cached (`tl_gcal_cals`) and the dropdown is refilled from cache on load (before
any token exists). `populateCalendars` caches on success and, on a 403, clears the list flag and
tells the user to reconnect to grant the calendar-list scope. `setGcalTarget` no longer dead-ends
when re-picking without a live token — it remembers the choice, connects, then syncs to it.

### 2026-07-25 — Google sync: "Sync now" covers current + future logged months (`v53`)

Follow-on to v52. Instead of syncing only the *viewed* month, **Sync now** (and picking a
calendar) rebuilds **every month from the current one through the last month that has a lesson**
(capped at +6 months). So lessons logged for future months sync without navigating to each; past
months are still never touched. `syncMonth(when)` now returns counts and throws on 401;
`syncNow()` finds the range (max future `lesson_date`, capped) and loops it, reporting one
aggregate status (e.g. "Synced ✓ 34 lessons across 3 months").

### 2026-07-25 — Google sync: month-replace instead of per-lesson diff (`v52`)

Reworked the sync to **rebuild one month wholesale** instead of diffing every lesson across a
rolling window. Each sync targets the **currently-viewed month** (`anchor`'s month): it deletes
all the app's events in that month on the target calendar, then recreates them from the current
non-cancelled lessons. Other months are left untouched — so past months stop being re-churned
every sync.

- Events are tagged with `extendedProperties.private.tlengSync=1` (found via
  `privateExtendedProperty` on list) and created with reminders off, so delete+recreate causes no
  notification spam. `gcal_event_id` is no longer used (column harmless).
- Sync is now a **deliberate action** — the "↻ Sync now" button and picking a calendar trigger it;
  silent page-load reconnect no longer auto-syncs (avoids churning the month on every open).
- Switching calendars wipes *all* app events off the old calendar, then rebuilds the current month
  on the new one.
- To sync a different month, view it and hit Sync now.

### 2026-07-25 — Google sync: connect → choose → sync, moved to a footer (`v51`)

UX pass on the sync controls.

- **Flow:** connecting no longer auto-syncs. You Connect, then the dropdown shows "Choose a
  calendar…" and you must pick one; picking is what starts the sync. A `tl_gcal_chosen` flag gates
  this — once chosen, later page loads silently reconnect and re-sync (and a "↻ Sync now" button
  appears). The connect button is hidden in the "connected but not chosen" state so the dropdown
  is the obvious next step.
- **Layout:** moved Connect / calendar dropdown / status out of the crowded top bar into a footer
  under the calendar — keys on the left, Google controls on the right (`.cal-foot`).

### 2026-07-25 — Google sync: pick calendar from a dropdown (`v50`)

Replaced the paste-a-calendar-ID field with a **dropdown** of the user's own calendars. Adds the
`calendar.calendarlist.readonly` scope so the app can read the calendar list (names only) and
populate the picker after connecting; writable calendars only (owner/writer), primary shown as
"Main calendar". Picking one calls `setGcalTarget` (moves already-synced events). Needs a
one-time re-consent for the new read scope — `connectGcal` forces the consent prompt until a
successful `calendarList` fetch sets `tl_gcal_list`, then later syncs are silent.

### 2026-07-24 — Google sync: choose which calendar (`v49`)

Sync no longer hardcodes the primary calendar. When connected, a field lets you paste a
**calendar ID** (e.g. your "Tuition" calendar) and syncs there instead. Stored in `localStorage`
(`tl_gcal_calendar`, default `primary`). Changing it **moves** what's already synced — deletes
the events from the old calendar, clears their ids, then re-syncs into the new one (no orphans /
duplicates). Uses the same `calendar.events` scope, so no re-consent needed to write to a
secondary calendar.

### 2026-07-24 — Remove the Export .ics button (`v48`)

Dropped the "Export .ics" button (and its code) now that real Google Calendar sync exists — the
download was a stepping stone and just clutter next to Connect. (The Planner still has its own
recurring-slots ICS export.)

### 2026-07-24 — Google Calendar sync (OAuth, one-way) (`v47`) — NEEDS MIGRATION + GOOGLE SETUP

A **Connect Google Calendar** button on the Calendar that pushes your lessons into your Google
Calendar. Client-side OAuth via Google Identity Services (no backend, no client secret) + direct
Calendar API calls.

- **Connect** → Google consent popup (`calendar.events` scope) → syncs. Reconnects silently on
  later page loads and re-syncs, so opening the app keeps Google up to date. One-way (app→Google).
- **Sync** creates an event per lesson (rolling window: ~2 months back to ~6 months ahead),
  updates it on change, deletes it when the lesson is cancelled. Stores the Google event id in
  `lessons.gcal_event_id` so it doesn't duplicate.
- `db/migration_gcal.sql` — adds `gcal_event_id text` to `lessons`. **Run it before using Connect**
  (the sync query selects that column).
- `GOOGLE_CLIENT_ID` added to `config.js` (public, safe — like the anon key). A separate OAuth
  client from the "Continue with Google" login, in the same Google Cloud project.
- Setup needed once: a Google Cloud OAuth client (Web app) with `calendar.events` scope and the
  app origins as authorized JS origins; the tutor's Gmail added as a test user (unverified app →
  "Advanced → proceed" on first connect).

Snapshot-vs-live note: this syncs when you open/use the app (client-side), not via a 24/7 server.
The always-on version would be a Supabase Edge Function — not needed for one tutor.

### 2026-07-24 — Calendar: same-household overlaps aren't a clash (`v46`)

Two lessons from the **same household** at the same time are an intentional group (e.g.
siblings), not a double-booking — so they no longer flag red. Clash now = overlapping a real
lesson from a *different* household. Household is derived from the normalised phone number, same
as the Ledger (`hhKey`, matching `ledger.js`); the calendar now loads `contact` for this. No
migration.

Note: if two siblings overlap AND an unrelated student also overlaps that time, all three still
flag — because the unrelated one is a genuine conflict. Students with no phone number on file are
treated as a clash (can't confirm household without a number).

### 2026-07-23 — Calendar: export to .ics (Google/Apple Calendar) (`v45`)

An **Export .ics** button on the Calendar that downloads your lessons as a standard iCalendar
file to import into Google or Apple Calendar. Client-side, no backend — same mechanism the
Planner already uses for recurring slots.

- Exports real logged lessons (each a dated `VEVENT`) from ~2 months ago onward; excludes
  cancelled. Floating local time (keeps clock time), stable `UID` per lesson id.
- `SUMMARY` = "Student · Subject", `LOCATION` = the student's location, `DESCRIPTION` = level /
  amount / status, with Postponed / One-off noted.
- This is Phase-2 **step 1** (a snapshot — re-export after changes). The live auto-updating
  version is a Supabase **Edge Function** serving a subscribable `.ics` URL (Google "From URL"),
  which is the proper endgame for one-way app→Google sync but needs deploying that function —
  planned as a follow-up if the snapshot isn't enough.

### 2026-07-23 — Calendar: split the legend by clickable vs reference (`v44`)

The status filters (Paid/Unpaid/Scheduled/Not logged/Cancelled — clickable to show/hide) stay
in the top bar with the Week/Month toggle. The **non-clickable symbol keys** (Clash, ✦ One-off,
↻ Postponed) moved to a small caption line **below the calendar** — so it's clear which items
are controls and which are just a key. The caption also shows on mobile, where the top legend
is hidden.

### 2026-07-23 — Calendar: legend keys for postponed + one-off lessons (`v43`)

- Added a **↻ Postponed** key to the legend (the ↻ marker on postponed lessons was previously
  unexplained).
- **One-off / ad-hoc lessons** (added by hand, `slot_id = null`, i.e. not from the recurring
  template) now carry a **✦** marker on the block and a "✦ One-off" tag in the popover, with a
  matching legend key — so trials/makeups stand out from regular recurring lessons. Both are
  plain legend keys (attributes, not filterable categories).

### 2026-07-23 — Postal lookup moves inside the location bar (`v42`)

Dropped the separate postal input. The magnifying glass now sits **inside the Location field**;
you type a 6-digit postal code right in the bar and tap it, and it **expands the postal to the
full address in place** — keeping any building name you typed before it (so "Bishan tuition
centre 579837" → "Bishan tuition centre 9 Bishan Place … 579837"), then you add the unit number.
`wirePostal` now finds the `\d{6}` in the field and replaces it via `postalLookup`. (Fixed an
`all:unset` ordering bug that had knocked the icon out of the input.)

### 2026-07-23 — Postal lookup as a magnifying-glass icon; location truncates on calendar (`v41`)

- The "Find & add address" button is now a **magnifying-glass icon** (inline SVG, icon-only,
  with title/aria-label), on both the student form and profile edit.
- On the calendar, a long location no longer wraps and blows up the block: the `◍ location`
  line now **truncates to one line** with an ellipsis. The **full** location still shows
  (wrapped) in the click popover.

### 2026-07-23 — Postal-code → address lookup on the location field (`v40`)

On the student add/edit form and the profile edit, a **Postal code** box + **Find & add
address** button next to Location. It looks the code up via **OneMap** (Singapore's gov map API)
and **appends** the address to whatever's in Location — so you keep the building name and add
the unit number yourself. No key/backend: OneMap's search is CORS-open and works client-side
(verified in-browser). Best-effort — if it's blocked or finds nothing, you just type the address
manually (the field is still free text). No migration (uses the existing `location` column).

- `app.js`: `postalLookup(code)` (6-digit → title-cased address, `{address}`/`{error}`) and
  `wirePostal(...)`, both shared by the two forms.
- Note: OneMap now nags for an API token but still returns data token-less; if that path ever
  closes, the proper fix is a token via a Supabase Edge Function (tokens expire every 3 days),
  or just keep typing addresses by hand.

### 2026-07-23 — Student location, shown on the calendar (`v39`) — migration DONE (run 2026-07-23)

Each student gets a **location** (where you teach them — Home, a centre, Online). It's on the
Students add/edit form and the Profile, and appears on the calendar: a dim `◍ <location>` line
on each event block and a row in the details popover, so you can glance at the week and know
where to go.

- `db/migration_student_location.sql` — `alter table students add column location text`.
  Additive/backward-compatible.
- Wired through `students.js`, `student.js` (profile display + edit), and `calendar.js`
  (loaded into a `locById` map, shown on blocks + popover, for real and projected lessons).

**Deploy order:** run the migration in Supabase FIRST — the students query and calendar now
`select` `location`, so without the column those pages throw "column does not exist".

### 2026-07-23 — Calendar: event text wraps instead of truncating (`v38`)

Week-view blocks truncated the name/subject to an ellipsis ("Gra…"). They now wrap onto new
lines — time, bold name, then subject · level, each on its own line — so long names/subjects
are fully readable within the block. Tiny blocks still compact (time + name, subject hidden).
Month chips keep their single-line style (the grid is dense; click for full detail).

### 2026-07-23 — Calendar: gold circle on today's date (`v37`)

Today's date now sits in a filled **gold circle** (white number), week + month, like
Google/Apple — but gold rather than red, since red is reserved for "owed/unpaid" here and a red
ring would read as an alert. The circle replaces the old "TODAY" text label (the circle is the
signal); a faint cream column/cell tint stays.

### 2026-07-23 — Calendar: only real lessons clash (`v36`)

A clash now requires two **real** lessons to overlap. Projected ("not logged") blocks are only
a preview of the template, so they never flag red — not against each other, not against a real
lesson. (Cancelled was already excluded.) A clash means an actual double-booking; the warning
appears the moment you *log* the second lesson, when it becomes real. This also clears the
July-19-type artifact where an unpaid lesson flagged against a phantom projection left over from
a pre-migration `slot_date`.

### 2026-07-23 — Fix: a lesson later today showed as unpaid, not scheduled (`v35`)

Status was decided by a **date-only** comparison (`date > todayISO() ? "scheduled" : "done"`),
so any lesson on *today's* date was marked `done` immediately — even one hours away. A future
lesson then rendered as "unpaid" (done + not paid) instead of "scheduled". Hit by postponing a
lesson to later today.

New `statusFor(dateISO, endHM)` compares the lesson's **end time** to now — matching what
`promotePastLessons` already does — so a lesson stays `scheduled` until its end passes. Applied
in all four spots that set status: `saveLesson`, `restoreLesson`, and the three generate
functions. Existing rows already stamped `done` need a re-save (or self-correct once their time
passes); everything from here is correct.

### 2026-07-23 — slot_date: precise per-occurrence "not logged" (`v34`) — migration DONE (run 2026-07-23)

The endgame for the postpone/projection edge cases. Adds a `slot_date` column to `lessons`:
the recurring occurrence a lesson fulfils, fixed at generation and never moved by postpone
(vs `lesson_date`, which is when it actually happens). One-off lessons have `slot_date = NULL`.

The calendar now projects a slot on a date **iff no lesson claims that exact occurrence**
(`slot_id | slot_date`) — replacing the week+month heuristic entirely. This is precise, so it
resolves *every* case: postpone within/across weeks, the single-lesson-week edge, and month
boundaries. Verified across all four in the harness.

- `db/migration_slot_date.sql` — adds the column + backfills existing generated lessons
  (`slot_date = lesson_date`). Additive and backward-compatible: the current live app ignores
  the column, so adding it breaks nothing.
- `ledger.js` generate (week/month/range) now stamps `slot_date = di` on new lessons.
  `saveLesson` needs no change — it doesn't touch `slot_date`, so postpone/edit preserve it and
  manual adds leave it NULL.
- `calendar.js` selects `slot_date`; keeps the exact-time match as a fallback for one-offs and
  any pre-backfill rows.

**Deploy order (mandatory):** run the migration in Supabase FIRST, then load/deploy this code.
The code `select`s `slot_date`, so without the column every calendar/ledger load throws
"column does not exist". Our local dev also hits the live DB, so don't open the new calendar
locally until the migration is run.

Still open (separate, higher-risk): the Ledger's "Log this month" double-count-on-re-log. It
could now dedup by `(slot_id, slot_date)` too, but that touches money logic and needs a careful
two-range fetch — left for its own change.

### 2026-07-23 — Calendar: fix projections on month-boundary weeks (`v33`)

The v32 "logged week → no projections" rule was too coarse at month boundaries: the last week
of July also holds Aug 1–2, so July's lessons marked the whole week logged and Aug 1–2 wouldn't
project even though August is unlogged. Now "logged" is keyed by **week + month**, so a
straddling week counts as logged only for the month whose lessons it actually holds — the other
month's days still project if unlogged.

Deeper still on the wishlist (needs a shared-DB migration, so it's your friend's call): tag each
generated lesson with the **occurrence date it fulfils** (`occurrence_date`). That makes "is this
slot-occurrence logged?" a precise per-day fact — immune to both postpone and month boundaries —
and would also fix the Ledger's double-count-on-re-log. Not built yet.

### 2026-07-23 — Calendar: logged weeks show only real lessons (`v32`)

Supersedes v31's approach with a simpler rule that matches the actual workflow. Projections
("not logged" blocks) exist only to preview periods you *haven't* logged yet. So: **once a
week has been logged from the template (any lesson with a `slot_id`), the calendar shows only
real lessons for that week — no projections at all.**

That fully resolves the postpone edge case, including cross-week: a logged week never
projects, so postponing within it leaves no phantom; and the week you move a lesson *into*
keeps its own recurring session because that's a real logged row, not a projection. Week-level
(not month-level) so "Log this week" only suppresses that week — the rest of the month still
projects for planning.

Rare remaining edge: postponing the *only* lesson out of a week makes that week look unlogged
again (it then projects). With multiple students per week — the normal case — it can't happen.

### 2026-07-23 — Calendar: postponed lessons no longer leave a phantom slot (`v31`)

Bug: the calendar decided "not logged" by matching `student | date | start_time`. Postponing a
lesson changes its date/time, so it stopped matching its recurring slot — and a phantom
"not logged" block reappeared at the slot's original time, alongside the real postponed lesson.

Fix: a lesson now **claims its slot's occurrence for the whole week** via `slot_id` (which
postpone preserves). So the projected block is suppressed wherever in that week the lesson
now sits. Added `slot_id` to the calendar's lessons query; deduped projected slots by
`(slot_id, week-Monday)` with the exact time-match kept as a fallback for one-offs.

Edge: postponing *across* weeks is inherently ambiguous (the lesson claims its new week); the
common same-week postpone is fully fixed. The Ledger's "Log this month" generator has the same
time-based key and could adopt slot_id dedup too — separate change, not touched here.

### 2026-07-23 — Calendar: legend items filter the view (`v30`)

The legend is now interactive — click **Paid / Unpaid / Scheduled / Not logged / Cancelled**
to show or hide that category. Off items dim + strike-through; the blocks disappear from both
week and month views. Choice persists in `localStorage` (`tl_cal_hidden`). "Cancelled" was
added to the legend (it wasn't shown before); "Clash" stays a plain key (it's an attribute,
not a filterable category). Filtering happens before lane/clash layout, so hiding a category
also drops any clash it was part of.

Note: the legend is hidden on mobile (`max-width:820px`), so the filters are desktop-only for
now — a mobile control can come later if needed.

### 2026-07-23 — Calendar: cancelled lessons don't count as clashes (`v29`)

A clash now needs two *active* lessons to overlap. A cancelled lesson isn't happening, so
overlapping it (on either side) no longer flags red or shows the ⚠. Overlapping blocks still
render side-by-side; only the red warning is suppressed when a cancelled lesson is involved.

### 2026-07-23 — Calendar: "Today" label on the week column (`v28`)

Small touch: the week view now shows a gold **TODAY** label above the highlighted current-day
column. Every header cell reserves the same slot so only today's fills — the row stays aligned.

### 2026-07-23 — Calendar: prefetch adjacent months (`v27`)

Follow-on to the month cache. Before, a month was only fetched when you first navigated to
it — so the *first* ‹ / › into a new month waited on one query. Now, after painting the
current view, the calendar **warms the neighbouring months in the background** (one step
back and forward, week or month), so paging is instant in both directions from the first
navigation on.

- `fetchMonth` is now deduped (a cached month no-ops; a month a prefetch and a visible load
  request at the same time shares one query) — no double fetches.
- `prefetchAdjacent()` fires after each render, fire-and-forget; each navigation re-warms
  ±1 from the new position, so continuous paging stays ahead of you.
- Cache still grows unbounded across a session, but a month is tiny — no eviction needed at
  this scale.

Verified with a mock-Supabase query counter: after the first load, the visible months for
both the next and previous step are already cached, so navigation does zero render-blocking
fetches.

### 2026-07-22 — Calendar: month view + faster loads (`v26`)

Two things on the Calendar: a **month view** and a fix for slow loading.

- **Week / Month toggle** (segmented control, same as the dashboard; remembered in
  `localStorage` as `tl_cal_mode`). Month view is a day-cell grid — each day shows compact
  lesson chips coloured by status, dashed for projected, ⚠ + red for clashes. Recurring
  lessons project across every future week, so you can page months ahead and see the whole
  plan. Click a day → jumps into that week. Leading/trailing days from adjacent months are
  greyed.
- **Faster loading.** The old path was a 6-round-trip serial waterfall. Now: `students` +
  `recurring_slots` load in parallel (one `Promise.all`), and **lessons are fetched a whole
  month at a time and cached in memory** keyed `YYYY-MM`. Paging or toggling back to a month
  already seen does **zero** network — instant. This is the proportional slice of what
  Google/Apple calendars do (range prefetch + stale cache); the heavier machinery they use
  (on-device DB, delta-sync tokens, webhooks) is overkill at one tutor's data volume.

Still read-only — creating/editing lessons stays in the Ledger. Click-to-add-on-calendar
was considered and deferred.

### 2026-07-22 — Calendar tab, phase 1 (`v25`)

New **Calendar** nav item (between Planner and Ledger) — a week time-grid of the schedule,
Google-Calendar style. New `calendar.html` + `assets/js/calendar.js`, plus a NAV/meta entry
in `app.js`. No schema change; same three reads (`students`, `recurring_slots`, `lessons`)
the rest of the app already uses.

- **Shows both** real logged lessons *and* faded "projected" blocks from the recurring
  template for occurrences not yet logged — so future weeks aren't blank. Uses the
  generator's dedup key (`student_id | date | start_time`) to decide which is which.
- **Colour by state:** paid (teal), done-unpaid (red), scheduled (navy), cancelled (grey,
  struck), projected (dashed gold). Postponed lessons carry a ↻ marker.
- **Overlap = clash.** Since pairs/orgs are a single row, any two blocks that overlap are a
  real double-booking. They render side-by-side with a red outline + ⚠, and the popover
  says "Overlaps another lesson". (Flags *all* overlaps — the app can't tell intentional
  from accidental; a "known-OK" suppression can come later.)
- **Read-only.** Clicking a block opens a details popover with an "Open in Ledger" link —
  editing / paying / logging all stay in the Ledger. The calendar visualises and navigates.
- Week ‹ › nav + Today button; time range auto-fits the week's earliest/latest lesson.

**Phase 2 (Google Calendar sync) — not built.** Two paths, very different sizes: a
downloadable `.ics` (planner.js already exports slots as `RRULE` events — easy, client-side)
vs. true Google Calendar API sync (OAuth + storing refresh tokens → needs a Supabase Edge
Function; can't be pure static). Decide when we get there.


### 2026-07-17 — Per-tutor sidebar brand (`v23`)

The sidebar brand used to hardcode the string `"T-Leng Tuition"` in `app.js`, so every
account showed the same name. It now reads each tutor's **`business_name`** (the field
already set in Settings and already used for invoices / reminders / PayNow) and falls back
to `"T-Leng Tuition"` when blank.

- `requireAuth()` fetches `business_name` once after auth and brands the shell with it.
- The `TL` monogram badge is now derived from the name — initials of the first two words
  (`T-Leng Tuition` → `TL`, `Raphael Tuition` → `RT`), so it stays in step.
- Shown possessive — "Raphael Tuition" → "Raphael Tuition’s Dashboard" (a name ending in s
  takes just an apostrophe). Public pages (`index`, `landing`) keep the plain product name,
  since they render before anyone logs in.
- **Note:** the sidebar picks up a Settings change on next page load, not live.

**Captured at registration too.** The signup form's old "Your name" field (which fed
`full_name`, a column nothing in the app ever read) is now **"Business name"** and feeds
`business_name` — so a new tutor's sidebar is branded from the moment they sign up, no
Settings visit needed.

- Sent as signup metadata, and written to the profile client-side right after signup.
- That client-side write only runs when a session exists at signup, i.e. **email
  confirmation OFF** (the current setup). For the confirmation-ON case, run
  **`db/migration_business_name.sql`** once in the Supabase SQL editor — it updates the
  `handle_new_user` trigger to persist `business_name` from the metadata server-side, so it
  works either way. (Coordinate with the DB owner before running — it's the shared project.)

### 2026-07-15 — Ledger UI pass (`v19` → `v22`)

Made the Ledger quicker to read and act on. Three commits, all **presentation only** — no
schema change, no new queries, and no change to how any amount is calculated. Same data,
better arranged.

**1 · The Records table is scannable** (`87d8f3a`, `v20`)

- **Weekday on every date** — `Tue 15 Jul` instead of `15 Jul`, so a row ties back to its
  recurring slot without doing date maths. New `recDate()`; scoped to Records, so
  `prettyDate()` and the outstanding cards are untouched.
- **Today's row is highlighted** — cream with a gold left border; a gold-edged cream card
  on mobile, where rows collapse to cards.
- **A "Today" button** in the period bar scrolls today into view with a brief pulse, and
  snaps back to the current month first so it always lands somewhere. Respects
  `prefers-reduced-motion`.
- **A "Today · <date>" divider** appears on days with no lessons, at the past/future
  boundary (rows sort newest-first). It anchors the button and separates booked from done.
- **Cancelled rows dim** to 55% with the amount struck through — legible but clearly inert.

**2 · Outstanding and Records became tabs** (`e6d20b8`, `v21`)

The page was very long: KPIs, a card per owing student plus household blocks, filters, then
a month of rows. Outstanding ("chase the money") and Records ("fix the lesson log") are
different jobs.

- **Segmented control** reusing the Dashboard's `.seg` pattern — `setLedgerMode()` mirrors
  `setDashMode()`. Defaults to Outstanding, then remembers your last tab in `localStorage`
  (`tl_ledger_mode`).
- **KPIs stay above the tabs** — they summarize the whole page, so they belong to neither.
- **The owing count rides on the tab** (`Outstanding · 3`) and stays readable while
  inactive, so tabbing never hides the fact that someone owes you. `setOutCount()` is
  called from both exits of `renderOutstanding()` so it can't drift out of sync.
- **`.seg` moved from `app.html`'s inline `<style>` into `app.css`** now that two pages use
  it. Rules are byte-identical; the Dashboard is unaffected.

**3 · Lesson-creating actions moved into Records** (`2a60ff3`, `v22`)

- `Log this week` / `Log this month` / `Log custom range` / `+ Add lesson` now live in the
  **Records** tab. Nothing in that toolbar ever served Outstanding — every button creates
  lesson rows, while Outstanding has its own verbs (Remind, Invoice, Mark paid, combine
  bar). It was never a page-level toolbar; it was the Records toolbar sitting at page level.
- This also closes a feedback gap: logging from Outstanding used to be mostly invisible,
  since generated future lessons are stamped `scheduled` and Outstanding only lists `done`
  + unpaid. The new rows now land in the table you're already looking at.
- Dropped the `led-sub` "Lessons & payments" line with the old bar — it duplicated the
  subtitle `mountShell()` already renders in the topbar, and no JS referenced it.

**Verification.** The Records anchor logic was tested across seven cases (today has
lessons / no lessons today / all-future / all-past / another month / all-time / cancelled
today) to confirm exactly one anchor lands in the right place. Both tabs were rendered in
headless Chrome at desktop and mobile widths against the real stylesheet. That caught one
bug worth noting: today's mobile card had a *lighter* actions strip than its cream body,
inverting how white cards look — fixed in `v21`.

**Note on `?v=`.** Every commit here bumps the cache-busting number across all pages via
`bump-version.sh`, which is why 13 HTML files show up in each diff with no real change.
Only `ledger.html`, `ledger.js`, `app.css` and `app.html` carry actual edits.

### Notes for future work

- **Households aren't a real concept.** `ledger.js` derives them at render time by
  string-matching normalised phone numbers — there's no `household_id` anywhere in the
  schema. Siblings on different parents' numbers silently don't group, and combined
  invoices are saved with `student_id = null` and recover the name by parsing `data.title`.
  Promoting household to a real column/table is the obvious first structural improvement —
  and unlike everything above, it's a data-model change: a migration against the live
  database, a backfill, and no staging copy to rehearse on.
- **`db/schema.sql` is frozen at the first commit.** The live Supabase database is well
  ahead of it — `invoices` and `materials` tables, plus many columns, exist live but aren't
  in the file, and the `migration_*.sql` files this README references were never committed.
  Harmless day-to-day (the live DB is the source of truth), but it means the repo can't
  rebuild the database, and Part 1's setup instructions would produce a broken app for
  anyone deploying fresh.