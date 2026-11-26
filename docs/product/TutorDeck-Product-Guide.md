# TutorDeck Product Guide

*What TutorDeck does, for whom, how it works, and what every organisation can choose.*

**Written:** 2026-11-26 · **For:** the owners of TutorDeck Pte. Ltd. (Raphael and T-Leng) · **Source of truth:** the code and database files in the repository `TutorDecks/TutorDeck` and the unmerged branches named below. Nothing here is guessed; where I could not confirm something it says **not verified**.

**What this is not:** a legal document, a price list for customers, or a developer manual. It is written in plain words so a non-developer can answer "can a tutor do X?" without opening the code.

---

## Table of contents

- [0. How to read this guide](#0-how-to-read-this-guide)
- [1. What TutorDeck is](#1-what-tutordeck-is)
  - [1.1 Who it is for](#11-who-it-is-for)
  - [1.2 The organisation model](#12-the-organisation-model)
  - [1.3 Centre and solo are kept apart](#13-centre-and-solo-are-kept-apart)
  - [1.4 Plans and billing](#14-plans-and-billing)
- [2. The roles, one by one](#2-the-roles-one-by-one)
  - [2.1 Solo tutor](#21-solo-tutor)
  - [2.2 Centre tutor](#22-centre-tutor)
  - [2.3 Centre staff](#23-centre-staff)
  - [2.4 Centre admin / owner](#24-centre-admin--owner)
  - [2.5 Parent / student](#25-parent--student)
  - [2.6 Platform admin (TutorDeck's own team)](#26-platform-admin-tutordecks-own-team)
  - [2.7 Sign-up, invites, log-in, password and account deletion (all roles)](#27-sign-up-invites-log-in-password-and-account-deletion-all-roles)
- [3. Centre options reference](#3-centre-options-reference)
- [4. Key workflows end to end](#4-key-workflows-end-to-end)
- [5. Data and privacy](#5-data-and-privacy)
- [6. Environments and release](#6-environments-and-release)
- [7. Roadmap](#7-roadmap)
- [8. Known gaps and open decisions](#8-known-gaps-and-open-decisions)
- [Glossary](#glossary)
- [Appendix: where to find things in the code](#appendix-where-to-find-things-in-the-code)

---

## 0. How to read this guide

### 0.1 Status tags

Every claim carries a tag saying **where it works today**. Please read the tag before you promise anything to a customer.

| Tag | Meaning | Who can use it right now |
|---|---|---|
| **[LIVE]** | Works today for solo tutors on the production site (`www.tutordeck.com.sg`, `tutordeck.vercel.app`). Production runs the code on branch `main`, version **v252**, on the **real** database. | Real solo tutors |
| **[DEV]** | Built and merged into the `dev` branch (version **v271**). Runs on the preview/staging site against the **DEV** test database (dummy data only). Not on production yet. | Owners testing with the demo logins |
| **[BRANCH]** | Built and tested on its own branch, **not merged** into `dev`. The branch name is given. | Nobody yet (needs a merge and, usually, a DEV database script) |
| **[PLANNED]** | Designed or decided, not built. | Nobody |
| **[SOON]** | Shown in the centre setup wizard as "Coming soon" (greyed). The wizard shows it so centres know it is coming, but it does nothing yet. | Nobody |

**Extra note, "saved only":** many centre options (billing, invoicing, payments, tutor pay) are **saved** by the wizard on DEV and appear in the wizard's *sample invoice / sample pay statement*, but **no screen or database rule reads them yet** because centre invoicing and tutor pay (T4) are not built. These are tagged **[DEV · saved only]**. They are not marked "Coming soon" in the wizard today; see section 8.

### 0.2 Where the five "worlds" are

| World | Branch / site | Database | Contains |
|---|---|---|---|
| Production | `main` @ v252 | LIVE (real tutors, real money) | The solo-tutor app as it was before organisations existed |
| Staging | `dev` @ v271 | DEV (dummy data) | Solo app **plus** organisations, billing gate, centre setup, My lessons, switcher, holiday library, password rules |
| Unmerged work | named `claude/…` branches | DEV when tested | Centre staff screens, invite emails, tutor settings and payout details |
| Plans | `docs/orchestrator/*.md` on plan branches | none | T3 staff screens, T7 email, T12 separation, T18 holidays and credits, T24b tutor settings |
| Future | not written down in code | none | Centre invoicing, tutor pay, parent portal, credits, email reminders |

### 0.3 How "centre decides" works

TutorDeck follows the owner's rule (CLAUDE.md, 2026-11-24): **anything that depends on a centre's own business process is an option the centre chooses in the setup wizard**, not a fixed rule. What stays fixed is *integrity*: nobody marks a lesson before its day, nobody silently overwrites someone else's mark, tutors never see a lesson's price, and tutors have no direct table access.

Source: `CLAUDE.md` ("Product principle"), `assets/js/org-settings.js`.

### 0.4 Demo logins (DEV only)

On the DEV database there are demo people so the owners can click through every role. The password is in `db/seed_dev_demo.sql` (dummy data, DEV only; not repeated here).

| Login (email) | Role | Lands on | Status |
|---|---|---|---|
| `centre.owner@example.test` | Owner of "Demo Learning Centre" | The centre page | [DEV] |
| `tutor.one@example.test`, `tutor.two@example.test` | Centre tutors | My lessons | [DEV] |
| `both.tutor@example.test` | Solo tutor (2 students) who also teaches at the centre | Home; "My lessons" under More | [DEV] |
| `solo.tutor@example.test` | Solo tutor with exactly 5 active students (free-plan limit) | Home | [DEV] |
| `centre.staff@example.test` | Centre staff with all 8 permissions | Centre Home | [BRANCH] `claude/t3-1-staff-home` |
| `centre.frontdesk@example.test` | Centre staff with **students only** | Centre Home (students count only) | [BRANCH] `claude/t3-1-staff-home` |

Source: `db/seed_dev_demo.sql`; the two staff logins are added on `origin/claude/t3-1-staff-home`.

---

## 1. What TutorDeck is

TutorDeck is a web app (works on phones and computers; no app-store install) for people who run tuition in Singapore. It started as one tutor's dashboard (the original single-tutor dashboard) and is being widened so that **tuition centres** can use it too. It is run by **TutorDeck Pte. Ltd.** (founded by Raphael and T-Leng, who also use it live for their own tuition).

### 1.1 Who it is for

| Customer | What they get | Status |
|---|---|---|
| **Solo tutor** (one person, own students) | Students, weekly planner, calendar, ledger (who owes what), PayNow invoices, WhatsApp reminders, exams, student profiles, insights, Google Calendar sync | **[LIVE]** |
| **Tuition centre, class-based** (rooms, branches, several tutors, groups) | A centre account with an owner, staff, tutors; setup wizard; attendance by tutors and staff; pending charges; later invoicing and tutor pay | Setup, tutors' screen: **[DEV]**. Staff screens: **[BRANCH]**. Timetable, invoicing, pay: **[PLANNED]** |
| **Remote / 1-to-1 centre** (e.g. an online agency where each student has one tutor; no rooms or classes) | The same centre account. The owner has asked that **nothing requires a class, room or branch** and that 1-to-1 lessons are first-class | Design goal applied to staff Students and Attendance **[BRANCH]**; online lesson link and tutor pay per lesson **[PLANNED]** |
| **Parent / student** | Today: they receive invoices (image/PDF) and WhatsApp messages from the tutor. No login | See 2.5 |

Source: `README.md`, `CLAUDE.md`, `docs/orchestrator/BOARD.md` (owner decision 2026-11-25 about 1-to-1 centres, e.g. Opus Tuition).

### 1.2 The organisation model

Everything in TutorDeck belongs to an **organisation**. People belong to organisations through **memberships**.

| Concept | Plain meaning | Status |
|---|---|---|
| **Organisation (solo)** | "An organisation of one": every solo tutor automatically has one, created at sign-up. Their students, lessons, invoices belong to it. Kind `solo`, preset `solo`. | **[DEV]** (LIVE has no organisation tables yet: there, a solo tutor is just a login with their rows) |
| **Organisation (centre)** | A tuition centre. Kind `centre`, preset `centre`. Created by a person pressing "Set up a tuition centre"; that person becomes the owner. Status goes `setup` → `active` (launched). | **[DEV]** |
| **Membership** | One person in one organisation with a **role**, a **status** (invited / active / disabled) and, for staff, a list of **permissions**. | **[DEV]** |
| **Roles** | `owner`, `staff`, `tutor`, `parent` (the database allows these four) | owner, staff, tutor: **[DEV]**; parent: exists in the database only, no screens (**[PLANNED]**) |
| **Household** | The family: groups siblings and their guardians (like the owner's old "household id" sheet) | **[DEV]** tables; staff screen **[BRANCH]** |
| **Guardian** | A parent's contact (name, relation, phone, email) | **[DEV]** table; staff screen **[BRANCH]** |

**Who is what**

| Role | Can be several per centre? | What they are |
|---|---|---|
| Owner | Yes (an organisation needs at least one) | Everything: settings, people, billing, plan |
| Staff | Yes | "Admin" people with a chosen list of permissions (8 on `dev`, a 9th on a branch, see 2.3) |
| Tutor | Yes | Teaches lessons; no table access; sees only their own lessons |
| Parent | — | Reserved; not built |

A person can hold **several** memberships (for example a solo tutor who also teaches at a centre, or someone who owns one centre and is a tutor at another).

**The organisation switcher.** If a person belongs to more than one organisation, a small name chip (top bar on desktop, top of the page on phones) lets them pick the one they are working in. The choice is remembered per person. People with one organisation never see it. A centre owner with no students of their own is not shown their empty solo organisation, so the centre is their default. **[DEV]** Source: `assets/js/org-current.js`, `assets/js/app.js` (`TL.org()`), tests `tests/org-current.test.js`, `tests/org-switcher.check.js`.

**Which menu a person gets** (decided at sign-in, remembered 12 hours; any doubt falls back to the normal solo menu so no solo tutor can lose anything):

| Situation | Menu | Status |
|---|---|---|
| Solo tutor | Home · Schedule · Students · Money, More (Materials, Settings) | **[LIVE]** |
| Tutor only (active tutor at a centre, no students of their own) | One item: **My lessons** | **[DEV]** |
| "Both" (own students and a centre tutor role) | Solo menu plus **My lessons** inside More | **[DEV]** |
| Centre owner / staff, centre selected | **Centre home**, **Centre(s)**, Settings (solo screens redirect to the centre page) | **[DEV]** |
| Centre staff on the branch build | Centre tabs Home · Students · Attendance (Timetable shows "coming next") | **[BRANCH]** |

Source: `assets/js/app.js` (`GROUPS`, `TUTOR_GROUPS`, `CENTRE_GROUPS`, `roleMode`, `detectRole`), `assets/js/org-scope.js`.

### 1.3 Centre and solo are kept apart

The owner decided (2026-11-24) that **a centre's data and a solo tutor's data must never mix**.

- Each solo page reads and writes **only the current solo organisation's rows** (59 places changed). If the app cannot work out the organisation (for example on LIVE today, which has no organisation tables), it does exactly what it always did. **[DEV]** (T12c)
- While the current organisation is a centre, the solo pages (Students, Ledger, Planner, Invoices, Exams…) are not shown; typing their address redirects to the centre page (a centre tutor goes to My lessons). Allowed on a centre: Organisation page, Settings, My lessons. **[DEV]**
- A **database safety net** refuses any lesson, slot, invoice or exam whose student belongs to a different organisation, whatever the page does. **[DEV]** (`db/migration_org_separation.sql`, applied to DEV only)
- Consequence the owner accepted: until the centre staff screens are merged, a centre owner **cannot** view or edit centre students/lessons from the old solo screens.
- One safety flag: until a LIVE check shows zero rows without an organisation, an empty organisation on a row counts as "mine" (`NULL_IS_MINE = true`). This is on the go-live checklist.

Source: `docs/orchestrator/T12-plan.md`, `docs/orchestrator/T12c-notes.md`, `assets/js/org-scope.js`.

### 1.4 Plans and billing

TutorDeck's **own** billing (what TutorDeck charges its customers) is separate from the money flowing between tutors and parents.

**Solo tutors** (decided by the owner) — built and tested against a **Stripe sandbox** and the DEV database; nothing is live:

| Item | Rule | Status |
|---|---|---|
| Free plan | Up to **5 active students** (on the roster, not discontinued, not past their end date) | **[DEV]** |
| Solo Pro | **S$14.90 per month** or **S$149 per year** | **[DEV]** (Stripe sandbox) |
| Free trial | **30 days**, once per organisation, **no card needed to start** | **[DEV]** |
| Existing solo tutors | **Grandfathered**: unlimited students, free ("Early tutor"). The billing migration marks every solo organisation that exists when it runs. | **[DEV]**; not yet run on LIVE |
| 6th student | A friendly prompt ("Your free plan is full…") on Add, Edit or Reactivate, with a link to the plan card | **[DEV]** |
| Plan card | Settings → Your plan: usage meter, start trial, checkout, **card on file** (brand, last 4, expiry; amber if expired or within 60 days), "Update card" link to Stripe's customer portal, switch monthly/yearly, cancel | **[DEV]** |
| Who can buy | Only the organisation's **owner** | **[DEV]** |
| GST | TutorDeck is **not GST-registered**; prices carry no GST; Stripe Tax is off | decided |

**Tuition centres:**

| Item | Rule | Status |
|---|---|---|
| Monthly fee | **S$100 + S$0.40 × billable students** | **[DEV]** (job built; Stripe subscriptions made by hand; never run for real) |
| Billable students | Previous month's **active** students, **rounded to the nearest 10** (halves up) | **[DEV]** |
| Active student (a month) | At least one **non-trial** lesson that month marked **attended**, **absent** or **late cancelled** (cancelled-in-time and unmarked lessons do not count); each student counts once | **[DEV]** |
| The fee job | `api/billing-cron.js`: daily at 16:30 UTC (00:30 Singapore time), production only; writes a fee snapshot per centre per month; refuses if prices differ or a renewal was already invoiced; `?dry=1` shows what it would do | **[DEV]** |
| Price status | **Under review** against competitors (SchoolTracs about S$148 per branch at 400 students); owner chose to keep it for now | decision pending |
| Trials | A trial lesson does not count towards the fee | **[DEV]** |

**How it is paid:** Stripe subscriptions (Checkout, customer portal, webhook). Card details are entered at Stripe, never stored by TutorDeck; the app only reads brand/last 4/expiry back for display. The Stripe webhook is the only thing that writes subscription state, never the browser.

**Go-live reminder (CLAUDE.md to-do 6):** before real money, the owner must: run the organisation, billing, attendance, tutor-access, delete and lock-down migrations on LIVE (with a SELECT preview and a yes first), split Vercel Production vs Preview settings, recreate Stripe products in live mode, add a live webhook, save a live customer-portal configuration, set `CRON_SECRET`, revoke the Vercel "Protection Bypass" token created for sandbox testing, and move to Vercel Pro (the Hobby plan is non-commercial). Not started.

Source: `db/migration_billing.sql`, `db/migration_attendance.sql`, `api/billing.js`, `api/stripe-webhook.js`, `api/billing-cron.js`, `assets/js/money.js`, `assets/js/plan.js`, `CLAUDE.md`.

---
## 2. The roles, one by one

Each role has: what they can see, what they can do, step-by-step workflows, what they can **not** do, and how they get in. Sign-up, invites, log-in, password reset and account deletion are shared by all roles and are in 2.7.

---

### 2.1 Solo tutor

*A private tutor (or small agency of one) who runs their own students. This is the only role on the live site today.*

**Status:** everything in this section marked **[LIVE]** works on production at v252. The same screens exist on `dev` with organisation scoping added.

#### What a solo tutor sees (menu)

| Menu | Page | Purpose |
|---|---|---|
| Home | **Home** (Dashboard) | A greeting, a **Money** card (pending, collected, projected) and a **Teaching** section (Today, Tomorrow, "Needs notes" for finished lessons without notes, upcoming exams). First-time **Set up TutorDeck** checklist and a "Get paid faster" card. **[LIVE]** |
| Schedule | **Calendar** | Day / Week / Month, lessons coloured by paid / unpaid / postponed / one-off, exams, clash highlighting, "Log lessons", Google Calendar connect and sync. **[LIVE]** |
| Schedule | **Weekly planner** | The repeating timetable: one slot = day, start/end time, subject(s), rate, student. **[LIVE]** |
| Students | **Roster** | List with Active / Discontinued filter, add, edit, discontinue, remove; each student opens a **profile**. **[LIVE]** |
| Students | **Exams** | Assessments with type (WA1–3, SA1–2, CA1–2, Mid-Year, End-Year, Prelim, PSLE, N/O/A-Level, Class Test, Common Test), date, subject, marks, countdown. **[LIVE]** |
| Money | **Ledger** | Two tabs: **Outstanding** ("Who owes you", grouped by student) and **Records** (every lesson, filter, select, bulk delete). Log the week or month, add lesson, cancel, postpone, record payment. **[LIVE]** |
| Money | **Invoices** | Saved invoices list and detail sheet: Saved → Sent → Paid. **[LIVE]** |
| Money | **Insights** | Income by month, across the year, by student, by subject and level. **[LIVE]** |
| More | **Materials** | Opens the separate MugCorner materials site in a new tab. **[LIVE]** |
| More | **Settings** | Business name, getting paid (PayNow, bank transfer), WhatsApp templates, two-factor sign-in, your data, plan, "Run a tuition centre?", "Know another tutor?" **[LIVE]** (the Plan and "Run a tuition centre?" cards are **[DEV]**) |
| (button) | **Client view** (eye) | Hides every amount on screen (shown as `$•••`) so a student can see the screen during a lesson; per device. **[LIVE]** |
| (button) | **Dark mode** (sun/moon) | Per device. **[LIVE]** |

#### What a solo tutor can do

**Students and profile**
- Add a student: name, level (just the year; G1/G2/G3 is set per subject on the weekly slot), WhatsApp number, "name in messages" (who the greeting names, e.g. the parent), location (with a postal-code lookup that fills the address), "lessons run until" date, notes, "pays by bank transfer" flag. **[LIVE]**
- **Discontinue** a student (or give a "lessons run until" date, inclusive). After that date they count as discontinued everywhere: no new lessons, hidden from Planner and pickers, their weekly slots are switched off; **Reactivate** turns them back on. History is kept. **[LIVE]**
- **Remove** a student deletes the student **and** their lessons (use Discontinue to keep history). **[LIVE]**
- Student profile tabs: **Progress**, **Lessons**, **Notes**, **Schedule**: totals, full lesson history (editable), recurring slots, exams (editable), and per-lesson notes (topics covered, homework, plan for next time). A copy-ready **monthly schedule** text can be sent to the family. **[LIVE]**

**Schedule**
- Add weekly slots in the Planner (a slot may cover several subjects, each with its own G-level, v249). "Remove" a slot hard-deletes it; lessons already made keep their ✦ flag correctly. **[LIVE]**
- **Log the week / month**: generates lessons from the slots (skips anything already logged). **+ Add lesson** for one-offs and trials (✦ = one-off). **[LIVE]**
- **Postpone** a lesson (moves the same lesson to a new date/time, flagged *postponed*; "Revert to slot" puts it back), **edit**, **cancel** or **delete**. **[LIVE]**
- **Calendar clash** warning only for real, non-cancelled lessons at overlapping times (siblings of one household overlapping is not a clash). **[LIVE]**
- **Google Calendar sync**: connect once (Google sign-in is only needed once; the long-lived key is stored encrypted on the server), choose which Google calendar, then "Sync now" runs on the server so the tutor can leave the page. One-way: TutorDeck → Google. The Google app is published but **unverified** (100-user cap, warning screen). **[LIVE]**

**Money**
- Lessons go **scheduled → done** automatically when their day has passed; unpaid done lessons pile up under **Outstanding by student**. **[LIVE]**
- **Record payment** (the one payment window): payment date, optional screenshot. The Invoices tab's "Mark as paid" and the student page's "Mark paid" open the same window. **[LIVE]**
- **Cancel a lesson** with an optional **cancellation fee (compensation)**: without a fee a cancelled lesson earns nothing; with a fee only that amount counts as income. **[LIVE]**
- **$0 lessons** (e.g. a free trial or an agency's first lessons) count as settled. **[LIVE]**
- **Invoices**: build an invoice from outstanding lessons (one student or a household); shows a **PayNow QR** (or **bank-transfer details** for overseas clients flagged "pays by bank transfer"); **PDF** download, **Send on WhatsApp** (image attached; marks it sent), **Message** bubble to copy the covering text, edit the text for this invoice only. Statuses **Saved → Sent → Paid**; a PDF download asks "Did you send this invoice?". An invoice saves itself the first time it is downloaded, sent or marked sent. **[LIVE]**
- **WhatsApp reminders**: one-tap reminder per outstanding balance, built from editable templates with placeholders `{name}` `{student}` `{business}` `{amount}` `{count}` `{month}` `{invoice}` `{paynow}` `{date}` `{year}`. **[LIVE]**
- **Insights**: charts of income. **[LIVE]**
- **Client view**: hides money everywhere so lessons can be run with the screen visible. **[LIVE]**

**Settings and account**
- Business name, full name, invoice prefix, PayNow ID (mobile or UEN), bank-transfer details, WhatsApp templates (reminder and invoice). **[LIVE]**
- **Two-factor sign-in** (six-digit code). Exact app type **not verified**. **[LIVE]**
- **Download my data (JSON)**, and **Delete my account** (type `DELETE`). **[LIVE]**
- **Know another tutor?** share link by WhatsApp or copy. **[LIVE]**
- **Plan card** (free ≤ 5 active students, Solo Pro, trial, card on file). **[DEV]**

#### Step-by-step: from nothing to getting paid (the order the README recommends)

1. **Sign up** (email + password, or Google). Fill **Settings**: business name, PayNow ID, invoice prefix. **[LIVE]**
2. **Students**: add everyone (name, level, WhatsApp number, who the message greets). **[LIVE]**
3. **Planner**: add each student's weekly slot(s) (day, time, subject, rate). **[LIVE]**
4. **Ledger → Log this week / Log this month** to create lessons from the slots. **[LIVE]**
5. **Run the week**: lessons flip to done; postpone, edit or cancel as plans change. Add notes (topics, homework, plan) after each lesson. **[LIVE]**
6. **Get paid**: on an outstanding balance press **Invoice** (PayNow QR) → **Send on WhatsApp**, or **Remind**. When money arrives press **Mark paid** (one window; optional screenshot). **[LIVE]**
7. **Exams**: add assessments so the countdown shows them. **[LIVE]**

#### What a solo tutor can **not** do

- There is **no parent login**: parents cannot log in, pay online, or see their child's record. **[LIVE]** (see 2.5)
- No automatic online payment, no automatic payment matching: the tutor marks payments paid by hand. **[LIVE]**
- No email sending from the app (invoices and reminders go through WhatsApp; the tutor can copy text). **[LIVE]**
- With more than 5 active students on **DEV**: a free-plan tutor needs Solo Pro (grandfathered early tutors excluded). **[DEV]**
- A solo tutor who is also a centre tutor works in one organisation at a time (switcher). **[DEV]**
- Calendar sync is one-way (changes made in Google are not read back). **[LIVE]**

Source: `README.md` (Everyday reference and change log), `home.html`, `ledger.html`, `calendar.html`, `planner.html`, `students.html`, `student.html`, `exams.html`, `invoices.html`, `insights.html`, `settings.html`, `assets/js/*.js`, `api/gcal.js`.

---

### 2.2 Centre tutor

*A person who teaches lessons at a tuition centre. They are invited by the centre owner.*

**Status:** **[DEV]** (My lessons page). Tutor settings, profile and payout details: **[BRANCH]**. Leave-centre: **[PLANNED]** (its branch `claude/t24c-5-leave` was never pushed; **not verified**).

#### Design rule (important)

A centre tutor has **no access to any database table**. A lesson row also holds what parents pay (rate, amount, paid, compensation), and row-level security cannot hide columns, so tutors use **two narrow database functions only**:

- `tutor_my_lessons(from, to)`: their own lessons with student name and level; **parent contact only if the centre switched it on**; never rate, amount, paid or compensation. **[DEV]**
- `tutor_mark_attendance(...)`: set attendance and write notes on **their own** lesson. **[DEV]**

Source: `db/migration_tutor_access.sql`, `assets/js/tutor.js`, `assets/js/tutor-core.js`, `tutor.html`.

#### What a tutor sees

The **My lessons** page: lessons grouped into **To mark** (earlier days still waiting, oldest first), **Today**, **Coming up**, **Earlier**. Each row shows time, student (classes sharing one session appear together), a chip (**Mark**, **To mark**, **Attended**, **Absent**, **Cancelled**, **Upcoming**, **Ask an admin**, **Admin marks**), and "Remarks due" (turns red when overdue). The menu is a single item. **[DEV]**

A "both" person (own students plus tutor role) gets **My lessons** inside More. **[DEV]**

#### What a tutor can do

| Action | Rule (all set by the centre's options in section 3) | Status |
|---|---|---|
| Mark a lesson **attended** or **absent** | Only on their **own** lesson; **from the lesson's day** (centre's time zone) up to **N days after** (default 14, 1–60); only if the centre says **tutors mark attendance** (`lessons.attendance_by = tutor`); never over someone else's mark | **[DEV]** |
| Mark **cancelled in time** / **late cancellation** | Only if the centre lets tutors mark cancellations | **[DEV]** |
| Type the **charge** for an absent/cancelled lesson | Only if the centre chose "tutor enters the charge"; between 0 and the lesson's own price; 0 = not charged. The tutor never sees the price | **[DEV]** |
| **Flag a trial lesson** | Only if the centre chose "tutor flags trials" | **[DEV]** |
| Write **topics, homework, remarks** | Always, on their own lessons within the window, up to 2,000 characters each; remarks can be **required** before "attended" if the centre says so | **[DEV]** |
| See **parent contact** | Only if the centre switched on `tutors_see_parent_contact` (default **off**) | **[DEV]** |

What marking does: the lesson's **status follows attendance** (set by the system, never typed): attended = **done**; absent / cancelled in time / late cancelled = **cancelled**, billed at its **compensation** (a number someone types; 0 = family not charged; blank = **charge pending**). Details in section 4.2.

#### Step-by-step: marking a lesson

1. Sign in; you land on **My lessons**.
2. Under **Today**, tap the lesson (chip says **Mark**).
3. Choose **Attended** or **Absent** (the cancellation choices appear only if your centre allows them).
4. If absent/cancelled and your centre has tutors type the charge, enter the amount (0 if the family is not charged); otherwise the sheet says "An admin will decide what this lesson is charged."
5. Add topics, homework, remarks (remarks may be mandatory for "attended").
6. Save. The chip changes; the lesson becomes done or cancelled.

If a lesson is locked you see why: "You can mark a lesson from its day onward.", "That's too long ago to change here. Please ask an admin.", "Someone else already marked this lesson. Ask an admin to change it.", "At this centre an admin marks attendance. You can still add notes."

#### What a tutor can **not** do

- See any price, rate, amount, paid state, invoice, other tutors' lessons, or other students' records. **[DEV]**
- Mark before the lesson's day, mark a lesson that was cancelled, overwrite another person's mark, or edit a lesson's date/time/price. **[DEV]**
- Edit their own timetable: "tutors may edit their own lessons" is **[SOON]**.
- Open any solo page (Students, Ledger, …): such addresses redirect to My lessons. **[DEV]**
- Open the solo **Settings** page (Settings is for solo, "both" and centre owners; a tutor-only login is redirected). **[DEV]** (owner decision T24, 2026-11-25)

#### Tutor settings page (profile, password, payout details, leave) — **[BRANCH]**

Owner decided on 2026-11-25 that tutors under a centre **should** have settings. A small page `/tutor-settings` (separate from the solo Settings page), reached from a link on My lessons.

| Block | What it does | Branch | Status |
|---|---|---|---|
| **Profile** | Display name (per centre, optionally for all centres) and an optional Singapore mobile (`+65` then 8 digits starting 6, 8 or 9); email is read-only (it is the login); sign out | `claude/t24c-1-profile`, `migration_tutor_profile.sql` | **[BRANCH]** |
| **Change password** | Same password rules as sign-up; asks for the current password first | `claude/t24c-1-profile` | **[BRANCH]** |
| **Payout details** | One method at a time: **PayNow mobile**, **PayNow UEN**, or **bank account** (bank name, number 7–16 digits, holder name). Shown **masked** by default (`•••••1234`); **Show** reveals it to the tutor only, and every reveal is logged. A change tells the centre ("Your centre will see this change") | `claude/t24c-2-payout`, `migration_tutor_payout.sql` | **[BRANCH]** |
| **Leave this centre / delete my account** | A request to the centre owner (one tap to approve; **auto-approved after 7 days**), then the tutor's login and personal data are erased while lessons and attendance stay as **"Former tutor"**. A "both" person can leave the centre and keep their solo account | planned in `T24b-plan.md`; database part (`migration_tutor_leave.sql`) not on origin | **[PLANNED]** |

Payout details are saved in a separate append-only table that **nobody can read from a browser**; only database functions touch it. The audit log stores only the **masked** value. Source: `docs/orchestrator/T24b-plan.md`, branches above.

Today (DEV) a centre tutor can only change their password with **Forgot password** on the login page.

---

### 2.3 Centre staff

*Admin people employed by the centre (receptionist, coordinator, accountant). The owner invites them and ticks the permissions they need.*

**Status:** on `dev` the staff role, permissions and the Centre page exist **[DEV]**, but the daily staff screens (Home, Students, Attendance, Charges) are **[BRANCH]** (`claude/t3-1-staff-home` → `t3-2-students` → `t3-3-attendance` → `t3-4-charges`; each is built on the one before, so the last contains all four). Merging is waiting for the owner's test round.

#### Permissions (the catalogue)

Staff get only what is ticked. The owner always has everything. The menu hides what a person cannot use, and the **database refuses it anyway**.

| Permission (key) | What it lets staff do **today** | Status |
|---|---|---|
| **Manage timetable** (`manage_timetable`) | Write branches, rooms, terms, holidays, weekly slots and lessons (database policy). On the branch screens: see "today / not marked / no tutor / trials" on Home, **mark** attendance and **correct** a mark with a reason | policy **[DEV]**; screens **[BRANCH]** |
| **Manage students & families** (`manage_students`) | Write students, exams, materials, households, guardians. On the branch: the **Students** screen (list, search, sheet, add, edit, discontinue, guardians) and the student count on Home | policy **[DEV]**; screens **[BRANCH]** |
| **Manage tutors** (`manage_tutors`) | In the catalogue; on the invite branch it lets staff **resend** a tutor's/staff invite email. Inviting itself is owner-only. Tutor removal is planned | **[BRANCH]** / **[PLANNED]** |
| **Issue invoices** (`issue_invoices`) | Write the `invoices` table (database policy). On the branch: **type the charge** for absent/cancelled lessons (the **Charges** tab) and see the pending-charge count on Home. (Owner's rule: this, not timetable, decides what a family pays) | policy **[DEV]**; screen **[BRANCH]** |
| **Record payments** (`record_payments`) | In the catalogue. **No screen or rule uses it yet** (T4) | **[DEV · saved only]** |
| **View revenue** (`view_revenue`) | In the catalogue. **Nothing uses it yet** (T4) | **[DEV · saved only]** |
| **Run tutor pay** (`run_tutor_pay`) | In the catalogue. **Nothing uses it yet** (T4) | **[DEV · saved only]** |
| **View the audit log** (`view_audit_log`) | Read the audit log tab on the Centre page | **[DEV]** |
| **View payout details** (`view_payout_details`) | A **ninth** permission: see the masked list of tutors' payout details and an audited **Reveal**. Not given by default; the owner always has it. Staff without it only see "provided / not provided" | **[BRANCH]** `claude/t24c-3-payout` (`migration_payout_permission.sql`) |

Source: `assets/js/org-settings.js` (`STAFF_PERMISSIONS`), `db/migration_org_foundation.sql` (policies), `org_invite()`, branches named above.

Every centre staff member can **read** business data (students, lessons, invoices, households) in their centre; the permissions decide who can **write**. Staff see parents' contact and lesson prices by design.

#### Staff screens on the branch build — **[BRANCH]**

Tabs: **Home · Students · Attendance** (with a **Charges** tab inside Attendance), More. **Timetable** shows a "Coming next" page, not a dead link.

| Screen | What it shows / does | Needs | Source |
|---|---|---|---|
| **Home** (`centre?id=…`) | Date and centre name. Tiles (counts only, **no money, no names**): lessons today / marked / still to mark; past lessons not marked; lessons with no tutor in the next 14 days; charges to confirm; active students. A tile you may not see is **left out** (never shown as 0) | any owner or staff; sections by permission | `migration_staff_home.sql`, `centre.js` |
| **Students** (`centre-students?id=…`) | Server-side **search and paging** (400+ students), filters Active / Ended / Trial; student sheet with family, guardians (name, relation, phone, email), level, notes, "lessons run until", next lessons, trial badge. **Add** a student with a guardian in one step (creates the household), **edit**, **discontinue / bring back**. Nothing needs a class, room or branch | view: any staff; change: `manage_students` | `migration_staff_students.sql` |
| **Attendance** (`centre-attendance?id=…`) | A **day or week** (up to 62 days) of lessons with filters (not marked, marked, by tutor). Tap a lesson → **mark** attended / absent / late cancelled / cancelled in time, with remarks. **Correct** an existing mark (needs a **written reason**, logged in the audit log). Staff can **always** mark and correct whatever `attendance_by` says (that setting only governs tutors) | look: any staff; mark/correct: `manage_timetable` | `migration_staff_attendance.sql` |
| **Charges** (`centre-attendance?id=…&tab=charges`) | The queue of absent/cancelled lessons whose **charge is pending**. Each row shows the lesson's full price (staff see price), a **suggested** charge, quick buttons **Not charged (0)** / **Full price**, and bulk "Not charged". Saving sets the compensation (0 up to the lesson's own price); changing an already-typed charge needs a reason; paid lessons are locked | `issue_invoices` | `migration_staff_charges.sql` |
| **Timetable** | "Coming next" | — | **[PLANNED]** (T3.6) |

**How the charge suggestion works** (`billing.absences.mode`, read as of the lesson's own day): *Charged* suggests the full price for absent, late-cancelled and cancelled-in-time; *Not charged* suggests 0; *Charged unless notice* suggests 0 for "cancelled in time" and full price otherwise. It only **pre-fills**: a person always confirms.

**Integrity fix shipped with Attendance** (**[BRANCH]**): a database rule on the lessons table now refuses, for *everyone* signed in, marking a lesson before its day, overwriting somebody else's mark, or editing the "marked by / marked at" fields. The one way past the second rule is the **Correct** function with a reason; "too early" has no way past.

#### What staff can **not** do

- Change centre **settings** or **people** (owner only; staff can look). **[DEV]**
- Mark attendance without `manage_timetable`, type charges without `issue_invoices`, edit students without `manage_students`. **[BRANCH]**
- See anything in another centre; see a solo organisation; staff who are "switched off" are refused everywhere (the screens answer "not found"). **[DEV]**
- Issue invoices, record payments, see revenue or run tutor pay from a screen: those permissions exist but have **no screens yet** (T4). **[PLANNED]**
- Edit the timetable (weekly slots with tutors, replacement cover, group lessons): **[PLANNED]** (T3.6–T3.9). **Important:** today there is no way, in the app, to give a centre's weekly slot a tutor or to generate a centre's lessons, because the solo Ledger generator is hidden from centres (see 8).

---

### 2.4 Centre admin / owner

*The person who created the centre. A centre can have several owners.*

**Status:** setup wizard, settings, people, holidays, plan tab and audit log **[DEV]**. Invite email with resend **[BRANCH]** `claude/t7-2-invites`. Payout list **[BRANCH]** `claude/t24c-3-payout`.

#### Where the owner works

The **Centre page** (`/org?id=…`; menu "Centre home"). Before launch it is the 10-step **setup wizard**; after launch the same steps become **Settings** tabs, plus two extra tabs **Plan** and **Audit log**. **[DEV]**

#### Create and launch a centre

1. Solo or new users: Settings → **Run a tuition centre?** → **Set up a tuition centre** (or `/org`). Type the centre name → **Create and start setup**. You become the owner; the centre starts in status **setup** with TutorDeck's centre plan attached (S$100 + S$0.40 per billable student). **[DEV]**
2. Walk the 10 steps (every step has sensible defaults, so you can skip ahead): **1 Organisation profile · 2 Branches, rooms and calendar · 3 Users and permissions · 4 How lessons are billed · 5 Invoicing · 6 How parents pay · 7 Tutors and lessons · 8 Tutor pay · 9 Import data · 10 Review and launch**. Every option is listed in section 3. **[DEV]**
3. Step 4 and 5 show a **sample invoice** (a family of two children, four S$40 lessons each) and step 8 a **sample pay statement**, so you see the effect of your choices. **[DEV]**
4. Step 10 **Review and launch**: a summary with "Edit" links; **Launch** puts the settings live from today. **[DEV]**

#### Settings changes after launch

- Settings are **versioned and effective-dated**: each save is a new row, never an edit. They cannot be back-dated.
- **Billing, invoicing, payments and tutor-pay** changes apply **from the 1st of next month**; everything else applies **today**. Issued invoices are never rewritten. (In setup mode everything applies immediately.)
- Process rules (marking, window, cancellations, remarks…) are read **as of today**; money rules follow the settings in force **when the lesson happened**.
- Only the owner can save settings.

Source: `assets/js/org-settings.js` (`effectiveFrom`), `org_save_settings()` in `db/migration_org_foundation.sql`.

#### People (step 3) — invite, permissions, switch off

| Action | How | Status |
|---|---|---|
| **Invite** staff or a tutor | Enter email, name, role. For staff, tick permissions. For a tutor, choose **employee** or **freelancer**. The person is created as **invited** and linked automatically when they sign in with that email. Only the **owner** can invite | **[DEV]** |
| **Change permissions** | Tick or untick on a staff row; saved at once | **[DEV]** |
| **Turn off access** | A confirm dialog ("they keep their history; they just can't sign in to this centre"); can be turned back on. An organisation always needs at least one active owner | **[DEV]** |
| **Invite email** | The branch sends a welcome email through Brevo (sender `noreply@tutordeck.com.sg`) with a one-time set-password link that lands on `/reset?welcome=1` ("Welcome to TutorDeck"); the link lives 24 hours. On DEV today the page says invite emails are "coming soon" | **[BRANCH]** `claude/t7-2-invites` |
| **Resend invite** | A button in the people list for invites not accepted in time; allowed for the owner and staff with **manage_tutors**; limits: 1 mail per invite per 10 minutes, 5 per invite per 24 hours, 30 per centre per hour; the list shows when it was invited and last emailed | **[BRANCH]** |
| **Preview safety** | Preview/staging sites only email `@tutordeck.com.sg` addresses and an allow-list; any other is saved but not emailed | **[BRANCH]** |
| **Remove a tutor from the centre** | Requires the tutor-leave migration | **[PLANNED]** |
| **Approve a tutor's "ask to leave"** | One tap; auto-OK after 7 days | **[PLANNED]** |

#### Branches, rooms, terms and holidays (step 2)

- Add **branches** (name, address), **rooms** inside a branch (name, capacity), **terms** and **holidays** (name, start, end). Delete with ×. **[DEV]** These are optional: a remote 1-to-1 centre can skip all of them.
- **Singapore public holidays library**: a list for 2026 and 2027 (data file `assets/data/sg-public-holidays.json`, from the Ministry of Manpower's published list; **2027 dates should be re-checked before shipping**; next year's rows are added each November). Tick the ones that apply to add them as normal holiday rows; nothing is ever applied automatically. Official "Monday substitute" days are separate unticked rows. **[DEV]**
- **Not built:** skipping lessons on holidays (`calendar.skip_holidays` is **[SOON]**). Today holidays are only a list; a holiday lesson must be cancelled or deleted by hand. **[SOON]**

#### Plan and audit

- **Plan tab** (owner only): "S$100 a month + S$0.40 per billable student", worked examples (98 → 100 → S$140; 250 → S$200; 405 → 410 → S$264), and the last six monthly **fee snapshots** (active → billable → fee). The first count appears after the first full month. **[DEV]**
- **Audit log tab** (owner, or staff with **view_audit_log**): the latest 200 changes: settings, people, students, lessons, invoices; who and when; cannot be edited or deleted. **[DEV]**
- **Payout list** (step 4 of the tutor-settings plan): a "Payout details" column in the tutors list with masked values and **Reveal** (audited). **[BRANCH]** `claude/t24c-3-payout`

#### What an owner can **not** do (yet)

- **Timetable**, **centre invoicing**, **payment recording**, **revenue**, **tutor pay**, **CSV import** (wizard step 9 is **[SOON]**), **parent communication**, **logo upload** ([SOON]). **[PLANNED]**
- **Delete the centre** or **transfer ownership**: the account-deletion function refuses anyone who belongs to a centre ("has other orgs"); a plain-words route is not built. **[PLANNED]**
- Choose a time zone or currency other than Singapore / SGD (one option each). **[DEV]**
- Charge parents through TutorDeck: TutorDeck **never holds a centre's money**; parents pay the centre directly. **[DEV]**

Source: `org.html`, `assets/js/org.js`, `assets/js/org-settings.js`, `docs/orchestrator/T7-plan.md`, `T7-owner-steps.md` (branch), `T18-plan.md`.

---

### 2.5 Parent / student

*Exactly what exists today and what does not.*

**What exists today (all through the tutor; the parent has no account):**

| Thing | What the parent gets | Status |
|---|---|---|
| **Invoice** | An image or PDF made by the tutor, with a **PayNow QR** (or bank-transfer details), sent by **WhatsApp** (image attached) or by the tutor emailing the PDF. The parent pays by PayNow/bank and tells the tutor; the tutor marks it paid | **[LIVE]** |
| **WhatsApp reminders** | A text from the tutor built from a template ("Hi {name}! … fees for {month} come to {amount} … PayNow to {paynow}") | **[LIVE]** |
| **Monthly schedule** | A copy-ready text of the student's lessons for the month | **[LIVE]** |
| **Client view** | Not a parent login: a button the **tutor** presses so money is hidden while a student looks at the tutor's screen. The older "Parent view" of a student's progress was folded into Client view | **[LIVE]** |
| **Shareable invoice link / "I've paid" button** | An earlier experiment was **removed** (August 2026). Its database function `invoice_by_token` still exists (intentionally public) but no page uses it | removed |

**What does not exist:**
- No parent or student log-in, no portal, no online payment, no payment link, no notifications by email, no parent sees remarks or attendance. The database already allows the role `parent` but no screen uses it. **[PLANNED]**
- A centre's setting "**remarks sent to parents**" (automatically, or after admin approval) is **[SOON]**.
- A centre invoice **link/email to parents** (`invoicing.delivery.email`) is **[SOON]**; the share-link setting is saved only.

**Planned parent portal (nothing decided about screens):** the owner's notes and the T3/T7 plans name it as out of scope for now. When it is designed it must respect the centre options (who sees remarks, who sees contact). **[PLANNED]**

---

### 2.6 Platform admin (TutorDeck's own team)

*What exists for Raphael and T-Leng as owners of the platform.*

| Capability | What exists | Status |
|---|---|---|
| **Platform admin role** | A table `platform_admins` (a list of login ids) and the helper `org_is_platform_admin()`. Added by hand in the database; no screen | **[DEV]** (database only) |
| **See organisations, plan and fee** | Function `platform_orgs()` returns, per organisation: name, kind, status, plan, base fee, per-student fee, last month, active and billable students, fee. **Never student records.** No page calls it, so there is **no admin console** | **[DEV]** (database only) |
| **Support access** | A centre **owner** can grant TutorDeck time-limited read access (`support_access_grants`: reason, expiry, revocable). Only with a live grant can a platform admin read that centre's business data. No screen creates grants yet; the audit log labels them "Support access" | **[DEV]** (database only) |
| **Fee snapshots and plans** | Readable by the owner or a platform admin | **[DEV]** |
| **Error log** | Signed-in tutors' browsers report script crashes, failed database requests and similar to a `client_errors` table (at most 5 per page load, kept 90 days, rate-limited) which the owners read in the Supabase Table Editor | **[LIVE]** |
| **Nightly backups** | GitHub Action `db-backup.yml`: encrypted database dumps, 30-day artifacts; restore steps are in README → Backups | **[LIVE]** |
| **Stripe dashboard** | Subscriptions, webhooks, customer portal are managed in Stripe | sandbox only |

**Not built:** an admin dashboard, impersonation, a screen to grant support access, customer-support tooling, a billing console. A real support mailbox does not exist yet (the domain's mail records point at the web host, so the domain cannot receive mail today; **owner action before the first paying centre**). **[PLANNED]**

Source: `db/migration_org_foundation.sql` (`platform_admins`, `platform_orgs`, `support_access_grants`), `db/migration_client_errors.sql`, `.github/workflows/db-backup.yml`.

---

### 2.7 Sign-up, invites, log-in, password and account deletion (all roles)

| Topic | How it works | Status |
|---|---|---|
| **Solo sign-up** | `login.html`: **Create account** with email + password, or **Continue with Google**. A password must have **at least 8 characters, a lowercase letter, an uppercase letter, a number and a symbol** (a checklist beneath the box ticks green as each is met). Sign-up asks for consent. A **bot check** (Cloudflare Turnstile) runs on the real domain only. A new account gets a "Set up TutorDeck" checklist; on DEV it also gets a solo organisation and a free-plan row | **[LIVE]** (password checklist, organisation and plan row: **[DEV]**) |
| **Email confirmation** | The confirmation email comes from Supabase's own sender today (rate-limited). Moving to the company sender `noreply@tutordeck.com.sg` (Brevo SMTP + three branded templates) is **owner steps E1/E3**, not done | **[PLANNED]** (docs on `claude/t7-2-invites`) |
| **Centre owner sign-up** | Same as solo; then Settings → "Run a tuition centre?" | **[DEV]** |
| **Invite (tutor / staff)** | Owner adds name + email + role. The person becomes a **membership with status invited**. When they sign in (or create an account) with **that email**, the app claims the invite and they become **active** (`org_claim_invites()` is called when they open the Centre page; the invite branch also claims on other pages, at most once per 30 minutes per login). Email delivery: **[BRANCH]**; until then the owner must tell them to sign up with that address | **[DEV]** / **[BRANCH]** |
| **Welcome page** | `/reset?welcome=1`: a "Welcome to TutorDeck" page where the invited person sets their password using the same rules as sign-up | **[BRANCH]** |
| **Log in** | Email + password (or Google). A tutor-only login lands on My lessons; a centre owner or staff on the centre page; a solo tutor on Home; a "both" person on their remembered organisation | **[LIVE]** / **[DEV]** |
| **Two-factor** | Solo Settings → Two-factor sign-in (six-digit code). Centre tutors cannot reach that page; tutor-settings does not include it | **[LIVE]** (solo) |
| **Forgot / reset password** | "Forgot password?" on the login page sends a Supabase reset email → `/reset`. The reset page today accepts six or more characters (on `main` and `dev`); the branch applies the full rules | **[LIVE]**; stronger rules **[BRANCH]** |
| **Change password (centre tutor)** | Via the tutor settings page (asks for current password) | **[BRANCH]** |
| **Delete account — solo** | Settings → Your data → **Delete my account**, type `DELETE`. On **LIVE** the code on `main` calls a Supabase Edge Function that deletes the login (database rows cascade; whether that function is deployed on the live project is **not verified**). On **DEV** it calls `api/delete-account.js`, which in order: cancels the Stripe subscription and deletes the Stripe customer, deletes files in the receipts and materials buckets, revokes the Google link, runs `org_delete_solo()` (removes the organisation and **everything** of theirs, audit log included, in one transaction), then deletes the login. If a step fails nothing later runs and pressing Delete again continues. A tutor whose subscription cannot be cancelled is **never** deleted | LIVE: **[LIVE]** (older route); full: **[DEV]** |
| **Delete account — centre member** | `api/delete-account.js` refuses anyone who also belongs to a centre (`409 has_other_orgs`) | **[DEV]** |
| **Delete — centre tutor** | Request to the centre, owner approves, personal data erased, lessons kept as "Former tutor" | **[PLANNED]** |
| **Download my data** | Settings → Your data → JSON of the account | **[LIVE]** |

Source: `login.html`, `reset.html`, `assets/js/password-rules.js`, `api/delete-account.js`, `supabase/functions/delete-account/index.ts` (retired), `db/migration_org_delete.sql`, `docs/orchestrator/T7-plan.md`, `T24b-plan.md`.

---
## 3. Centre options reference

Everything a centre can choose in the setup wizard (and later in Settings). The tables below are **generated from `assets/js/org-settings.js`** by `docs/product/build-options.js`, so every setting in the code is listed; run `node docs/product/build-options.js --check` to prove it.

**How to read the columns**
- **Setting** = the label the owner sees, then the technical name in `code font`.
- **Allowed values**: for a choice the stored value is in `code`, followed by its label. Money is stored in **cents** and rates in **basis points** (100 = 1%).
- **Default (centre)** is what a new centre starts with; the `solo` preset differs only where shown at the end.
- **Status**: **[DEV]** = something in the app or database reads it today; **[DEV · saved only]** = saved and validated, shown in the wizard's sample invoice or pay statement, but no screen or rule uses it yet; **[SOON]** = greyed "coming soon" in the wizard; **[BRANCH]** = used on an unmerged branch.
- A **[SOON]** choice inside a dropdown cannot be picked.

**What the database checks on every save** (`org_validate_settings` in `db/migration_org_foundation.sql`, mirrored in the JavaScript): settings version is 1; all eight sections present; GST rate 0–50% when GST registered; billing model, tutor-pay mode, "payable when", invoice grouping, attendance-by, cancellations-by, charge-by and trial-by are from their lists; attendance window 1–60 days; at least one way to pay. The page adds: a trading name, GST number when registered, brand colour `#RRGGBB`, reply-to looks like an email, invoice prefix 1–8 letters/numbers/hyphens, next invoice number ≥ 1, **invoice day 1–28**, pay days 1–31, sibling discount ≤ 100%.

**Step 2 (Branches, rooms and calendar)** also has non-setting data the owner edits on the same tab: **branches** (name, address), **rooms** (name, capacity, inside a branch), **terms** and **holidays** (name, start, end), and the **Singapore public-holiday library** (2026, 2027). All **[DEV]**; none is required, and none is read by any lesson rule yet.

**Step 3 (Users and permissions)** is the people list (2.4) and the permission catalogue (2.3).

<!-- OPTIONS:START (generated by docs/product/build-options.js; edit the notes in that script, not here) -->

#### Step 1 — Organisation profile

| Setting (`path`) | Plain meaning | Allowed values | Default (centre) | Status and notes |
|---|---|---|---|---|
| Legal name (`profile.legal_name`) | The registered company name, for invoices | any text | (empty) | **[DEV · saved only]** Copied to the organisation record; shown on the sample invoice. |
| Trading name (`profile.trading_name`) | The name families know (also the centre's display name). **Required** | any text | (empty) | **[DEV]** built Copied to the organisation record; shown in menus, switcher and invites. |
| UEN (`profile.uen`) | Singapore business registration number | any text | (empty) | **[DEV · saved only]** Shown on the sample invoice. |
| Address (`profile.address`) | Business address | any text | (empty) | **[DEV · saved only]** |
| Logo (`profile.logo_path`) | Centre logo for invoices | any text | `null` | **[SOON]** Wizard says logo upload comes with branded invoices. |
| Brand colour (invoices and your pages) (`profile.brand_color`) | Colour used on invoices and the centre's pages | `#RRGGBB` | `#0F766E` | **[DEV · saved only]** Format `#RRGGBB`. Used on the sample invoice only. |
| GST registered (`profile.gst_registered`) | Is the centre registered for GST? | Yes / No | No | **[DEV · saved only]** Used by the sample invoice maths (GST once per invoice, half up). |
| GST registration number (`profile.gst_number`) | GST registration number | any text | (empty) | **[DEV · saved only]** Shown only when GST registered; required then. |
| GST rate (`profile.gst_rate_bp`) | GST rate, stored in basis points (900 = 9%) | whole basis points ≥ 0 (100 = 1%) | `900` | **[DEV · saved only]** Shown only when GST registered; 0–50%. |
| Prices are entered (`profile.gst_inclusive`) | Are fees you type already including GST? | `false` Excluding GST<br>`true` Including GST | `false` | **[DEV · saved only]** Shown only when GST registered. |
| Timezone (`profile.timezone`) | The centre's time zone for 'today', lesson days and deadlines | `Asia/Singapore` Singapore (GMT+8) | `Asia/Singapore` | **[DEV · saved only]** Only Singapore is offered. The database uses the organisation's own time-zone column (Singapore). |
| Currency (`profile.currency`) | Currency | `SGD` SGD | `SGD` | **[DEV · saved only]** Only SGD is offered. |
| Invoice number prefix (`profile.invoice_prefix`) | Letters at the start of invoice numbers | any text | `INV` | **[DEV · saved only]** 1–8 letters, numbers or hyphens. |
| Next invoice number (`profile.next_invoice_number`) | The number the next invoice will get | whole number ≥ 0 | `1` | **[DEV · saved only]** Whole number ≥ 1. Centre invoicing is not built (T4). |
| Reply-to email for parent emails (`profile.reply_to_email`) | Where parents' replies to TutorDeck emails go | an email address | (empty) | **[DEV · saved only]** Parent emails themselves are not built. |

#### Step 2 — Branches, rooms and calendar

| Setting (`path`) | Plain meaning | Allowed values | Default (centre) | Status and notes |
|---|---|---|---|---|
| Don't generate lessons on centre holidays (`calendar.skip_holidays`) | Do not generate lessons on the centre's holidays | Yes / No | Yes | **[SOON]** Nothing reads it today; holidays are only a list. Cancel or delete holiday lessons by hand. |

#### Step 3 — Users and permissions

People are invited here, not saved as settings. See 2.4: invite, permissions, switch off. The permission catalogue (`manage_timetable`, `manage_students`, `manage_tutors`, `issue_invoices`, `record_payments`, `view_revenue`, `run_tutor_pay`, `view_audit_log`) is in 2.3.

#### Step 4 — How lessons are billed

| Setting (`path`) | Plain meaning | Allowed values | Default (centre) | Status and notes |
|---|---|---|---|---|
| Default billing model (`billing.model`) | How the centre bills by default | `prepaid_packages` Prepaid packages<br>`fixed_in_advance` Fixed fee in advance<br>`postpaid_lessons` Postpaid<br>`pay_per_lesson` Pay per lesson | `postpaid_lessons` | **[DEV · saved only]** The four choices are validated by the database; no screen bills by them yet (T4). |
| Fixed fee period (`billing.fixed_period`) | Fixed fee: per month or per term | `month` Per month<br>`term` Per term | `month` | **[DEV · saved only]** Shown only for 'fixed fee in advance'. |
| Invoice (`billing.pay_per_lesson_grouping`) | Pay-per-lesson: one invoice per lesson or per week | `lesson` Every lesson<br>`week` Every week | `lesson` | **[DEV · saved only]** Shown only for 'pay per lesson'. |
| Warn parents when credits fall to (`billing.low_balance_credits`) | Warn parents when prepaid credits drop to this number | whole number ≥ 0 | `2` | **[SOON]** No credit model exists yet (T18). |
| Credits expire after (days, 0 = never) (`billing.credit_expiry_days`) | Prepaid credits expire after this many days (0 = never) | whole number ≥ 0 (days) | `0` | **[SOON]** No credit model exists yet (T18). |
| Fee plans (per lesson / month / term, by level, subject, class type or duration) (`billing.fee_plans_note`) | Fee plans by level, subject, class type or duration | (a note, nothing to choose) | — | **[SOON]** Shown as a note: 'You'll set up fee plans with your classes.' |
| Absent lessons (`billing.absences.mode`) | Are absent lessons charged? | `charged` Charged<br>`not_charged` Not charged<br>`charged_unless_notice` Charged unless notice was given | `charged_unless_notice` | **[BRANCH]** `claude/t3-4-charges`, otherwise **[DEV · saved only]** On branch `claude/t3-4-charges` it **pre-fills the suggested charge** (charged: full price; not charged: 0; unless notice: 0 for 'cancelled in time', full price otherwise). A person always confirms. Read as of the lesson's own day. |
| Notice needed (hours before) (`billing.absences.notice_hours`) | Hours of notice that avoid the charge | whole number ≥ 0 | `24` | **[DEV · saved only]** Not recomputed anywhere: staff choose 'cancelled in time' or 'late cancelled' when marking. Shown only for 'unless notice'. |
| Makeup lessons allowed (`billing.makeups.allowed`) | Make-up lessons allowed | Yes / No | Yes | **[SOON]** No make-up object exists; a make-up is a normal one-off lesson (T18). |
| Makeups per period (`billing.makeups.per_period`) | How many make-ups per period | whole number ≥ 0 | `2` | **[SOON]** Shown only if make-ups allowed. |
| A makeup uses a credit (`billing.makeups.uses_credit`) | A make-up uses a credit | Yes / No | No | **[SOON]** Shown only if make-ups allowed. |
| Joining or leaving mid-period (`billing.proration`) | A student joining or leaving mid-period | `by_remaining` Prorate by remaining lessons<br>`full` Charge the full period<br>`skip` Skip the partial period | `by_remaining` | **[DEV · saved only]** Not used yet. |
| Sibling discount (2nd child onwards) (`billing.sibling_discount.type`) | Discount for the second child onwards | `none` None<br>`percent` Percentage<br>`fixed` Fixed amount per lesson | `none` | **[DEV · saved only]** Used by the sample invoice maths only. |
| Discount (`billing.sibling_discount.percent_bp`) | Percentage discount (basis points: 1000 = 10%) | whole basis points ≥ 0 (100 = 1%) | `1000` | **[DEV · saved only]** Shown only for 'percentage'; not over 100%. |
| Discount (`billing.sibling_discount.fixed_cents`) | Fixed discount per lesson, in cents (500 = S$5.00) | whole cents ≥ 0 | `500` | **[DEV · saved only]** Shown only for 'fixed'. |
| Allow one-off discounts (with a reason) (`billing.adhoc_discounts`) | Allow one-off discounts (with a reason) | Yes / No | Yes | **[DEV · saved only]** |
| Registration fee (`billing.one_off_fees.registration_cents`) | Registration fee, in cents | whole cents ≥ 0 | `0` | **[DEV · saved only]** Whole number ≥ 0. |
| Deposit (`billing.one_off_fees.deposit_cents`) | Deposit, in cents | whole cents ≥ 0 | `0` | **[DEV · saved only]** Whole number ≥ 0. |
| Materials fee (`billing.one_off_fees.materials_cents`) | Materials fee, in cents | whole cents ≥ 0 | `0` | **[DEV · saved only]** Whole number ≥ 0. |
| Late fee (`billing.late_fee.enabled`) | Charge a late fee on overdue invoices | Yes / No | No | **[DEV · saved only]** |
| Late fee amount (`billing.late_fee.amount_cents`) | Late fee amount, in cents (1000 = S$10.00) | whole cents ≥ 0 | `1000` | **[DEV · saved only]** Shown only if late fee is on. |
| After overdue (days) (`billing.late_fee.after_days`) | Days overdue before the late fee applies | whole number ≥ 0 (days) | `7` | **[DEV · saved only]** Shown only if late fee is on. |

#### Step 5 — Invoicing

| Setting (`path`) | Plain meaning | Allowed values | Default (centre) | Status and notes |
|---|---|---|---|---|
| One invoice per (`invoicing.grouping`) | One invoice per family or per student | `family` Family (household)<br>`student` Student | `family` | **[DEV · saved only]** Used by the sample invoice; validated by the database. |
| Create invoices (`invoicing.generate.mode`) | When invoices are created | `day_of_month` On a day of the month<br>`days_before` Some days before each period | `day_of_month` | **[DEV · saved only]** Not used yet. |
| Day of month (`invoicing.generate.day`) | Day of the month (1–28 so it exists every month) | whole number ≥ 0 | `1` | **[DEV · saved only]** Shown only for 'on a day of the month'. |
| Days before the period (`invoicing.generate.days_before`) | Days before the period starts | whole number ≥ 0 (days) | `7` | **[DEV · saved only]** Shown only for 'days before'. |
| Payment due (days after the invoice date) (`invoicing.due_days`) | Days after the invoice date that payment is due | whole number ≥ 0 (days) | `7` | **[DEV · saved only]** Used by the sample invoice's due date. |
| Create as drafts for an admin to approve (`invoicing.review_before_sending`) | Create invoices as drafts for an admin to approve | Yes / No | Yes | **[DEV · saved only]** Sample invoice says 'draft until approved'. Solo preset: off. |
| Email parents a secure link (`invoicing.delivery.email`) | Email parents a secure link to the invoice | Yes / No | No | **[SOON]** Needs the email provider and centre invoicing. |
| Shareable link for WhatsApp (`invoicing.delivery.share_link`) | Shareable link for WhatsApp | Yes / No | Yes | **[DEV · saved only]** Not marked soon, but no centre invoice screen or link page exists yet; the older solo link route was removed. |
| Payment reminders (`invoicing.reminders.enabled`) | Payment reminders | Yes / No | No | **[SOON]** |
| Remind (days from due date, e.g. -3, 0, 7) (`invoicing.reminders.schedule`) | Days from the due date to remind, e.g. -3, 0, 7 | numbers separated by commas | -3, 0, 7 | **[SOON]** Shown only if reminders are on. |

#### Step 6 — How parents pay

| Setting (`path`) | Plain meaning | Allowed values | Default (centre) | Status and notes |
|---|---|---|---|---|
| Ways to pay (`payments.modes`) | Ways parents can pay (tick one or more; at least one) | `manual_paynow` Manual PayNow<br>`statement_matching` Bank statement matching **[SOON]**<br>`hitpay` HitPay **[SOON]**<br>`stripe` Stripe **[SOON]** | manual_paynow | **[DEV]** built Only **manual PayNow** is built as a choice; the other three are 'coming soon' and cannot be ticked. Cash, bank transfer and cheque can always be recorded by hand (T4). Choices marked [SOON] cannot be picked yet. |
| PayNow to (`payments.paynow.type`) | PayNow to a UEN or a mobile number | `uen` UEN<br>`mobile` Mobile number | `uen` | **[DEV · saved only]** Used by the sample invoice. |
| PayNow UEN or number (`payments.paynow.id`) | The PayNow UEN or number | any text | (empty) | **[DEV · saved only]** Used by the sample invoice. |
| Bank for statement matching (`payments.statement_bank`) | Bank for statement matching | `DBS` DBS<br>`OCBC` OCBC<br>`UOB` UOB<br>`custom` Custom CSV columns | `DBS` | **[SOON]** |
| HitPay: PayNow (`payments.hitpay.paynow`) | HitPay: offer PayNow | Yes / No | Yes | **[SOON]** |
| HitPay: cards (higher fees) (`payments.hitpay.cards`) | HitPay: offer cards (higher fees) | Yes / No | No | **[SOON]** |
| Gateway fees (`payments.gateway_fees`) | Who pays payment-gateway fees | `absorb` Absorbed by the centre<br>`pass_on` Passed on as a separate line | `absorb` | **[DEV · saved only]** No gateway is built. |
| Allow partial payments (`payments.partial_payments`) | Allow partial payments | Yes / No | Yes | **[DEV · saved only]** |
| Overpayments (`payments.overpayments`) | What to do with an overpayment | `credit` Kept as credit for the family<br>`refund` Refunded manually | `credit` | **[DEV · saved only]** 'Kept as credit' has no credit model behind it yet. |

#### Step 7 — Tutors and lessons

| Setting (`path`) | Plain meaning | Allowed values | Default (centre) | Status and notes |
|---|---|---|---|---|
| Who edits the timetable (`lessons.timetable_editing`) | Who edits the timetable | `admin_only` Admins only<br>`tutors_own` Tutors may edit their own lessons **[SOON]** | `admin_only` | **[DEV]** built Staff with `manage_timetable` edit it (the weekly-slot editor itself is [PLANNED]). 'Tutors may edit their own' is coming soon. Choices marked [SOON] cannot be picked yet. |
| Attendance is marked by (`lessons.attendance_by`) | Who marks attendance | `tutor` The tutor<br>`admin` An admin | `tutor` | **[DEV]** built **Tutor:** tutors mark; staff can still mark/correct. **Admin:** tutors can write remarks but cannot set attendance. Staff are never blocked by this setting. Solo preset default: admin. |
| Tutors can mark or change attendance for (days after the lesson) (`lessons.attendance_window_days`) | How many days after the lesson a **tutor** may still mark or change attendance | whole number ≥ 0 | `14` | **[DEV]** built Whole number 1–60. Counted from the lesson's day in the centre's time zone. After that only an admin can. Staff are not limited. |
| Cancellations (in time or late) are marked by (`lessons.cancellations_marked_by`) | Who may mark 'cancelled in time' and 'late cancellation' | `admin` An admin<br>`tutor` The tutor | `admin` | **[DEV]** built Governs tutors only; staff can always set both. Whether a cancellation is late is the centre's own policy, so most let an admin decide. |
| For an absent or cancelled lesson, the charge (compensation) is entered by (`lessons.compensation_entered_by`) | Who types the charge (compensation) for an absent or cancelled lesson | `admin` An admin<br>`tutor` The tutor | `admin` | **[DEV]** built **Admin:** every absent/cancelled lesson waits in the Charges queue. **Tutor:** the tutor must type it when marking (0 if not charged), capped at the lesson's own price; staff can still override. |
| Trial lessons are flagged by (`lessons.trials_flagged_by`) | Who flags a lesson as a trial | `admin` An admin<br>`tutor` The tutor | `admin` | **[DEV]** built A trial lesson is not counted as an active student for TutorDeck's fee. Governs tutors only; staff can always flag. |
| Lesson remarks are required (`lessons.remarks.required`) | Remarks must be written before a lesson is marked attended | Yes / No | No | **[DEV]** built Applies to tutors, and to staff on the branch screens. Correcting an old mark does not re-require remarks. |
| Remarks due within (hours after the lesson) (`lessons.remarks.deadline_hours`) | Hours after the lesson that remarks are due | whole number ≥ 0 | `24` | **[DEV]** built Drives the 'Remarks due / overdue' line on My lessons. Whole number ≥ 0. (Known defect T14: the due time is shown in the browser's time zone, unlabelled, not the centre's.) |
| Who sees remarks (`lessons.remarks.visibility`) | Who sees remarks | `admin_only` Admins only<br>`parents_auto` Sent to parents automatically **[SOON]**<br>`parents_after_approval` Sent to parents after admin approval **[SOON]** | `admin_only` | **[DEV]** built Only 'admins only' works. Sending remarks to parents is coming soon. Choices marked [SOON] cannot be picked yet. |
| Remind tutors about missing remarks (`lessons.missed_remarks_reminders`) | Remind tutors by email about missing remarks | Yes / No | Yes | **[SOON]** Needs the email provider; until then My lessons shows what is overdue. |
| Admins can give one lesson to a replacement tutor (`lessons.replacement_tutors`) | Admins can change a lesson's tutor to a replacement | Yes / No | Yes | **[DEV]** built On: a lesson's tutor can be changed to another active tutor of the same centre. Off: only a lesson with **no** tutor can be given one. Enforced by a database rule. |
| Tutors can see parents' contact details (`lessons.tutors_see_parent_contact`) | Tutors can see parents' contact details | Yes / No | No | **[DEV]** built Off by default. Tutors always see student names and levels. Contact comes only through `tutor_my_lessons`. |

#### Step 8 — Tutor pay

| Setting (`path`) | Plain meaning | Allowed values | Default (centre) | Status and notes |
|---|---|---|---|---|
| Tutor pay (`tutor_pay.mode`) | How tutor pay is handled | `off` Off<br>`report` Lessons-taught report only<br>`full` Full pay calculation **[SOON]** | `report` | **[DEV]** built 'Off' and 'lessons-taught report only' are choices; 'full pay calculation' is coming soon. No report or pay screen exists yet (T4). Solo preset: off. Choices marked [SOON] cannot be picked yet. |
| Pay tutors for a lesson (`tutor_pay.payable_when`) | When a taught lesson becomes payable to the tutor | `parent_paid` Only after the parent's payment is received and reconciled<br>`taught` As soon as it is taught | `parent_paid` | **[DEV · saved only]** Default: only after the parent's payment is reconciled. Changing it later is recorded in the audit log. |
| Pay rate (`tutor_pay.rate_model`) | How tutors are paid | `per_lesson` Per lesson<br>`per_hour` Per hour<br>`per_student_lesson` Per student per lesson<br>`monthly_fixed` Fixed monthly amount | `per_hour` | **[DEV · saved only]** Shown unless pay is off. |
| Bonuses and deductions (with a reason) (`tutor_pay.adjustments`) | Bonuses and deductions with a reason | Yes / No | Yes | **[DEV · saved only]** Shown only for 'full'. |
| Pay period ends on day (`tutor_pay.cycle.cutoff_day`) | Pay period ends on this day of the month (1–31) | whole number ≥ 0 | `31` | **[DEV · saved only]** Shown unless pay is off. |
| Pay day (`tutor_pay.cycle.pay_day`) | Pay day (1–31) | whole number ≥ 0 | `7` | **[DEV · saved only]** Shown only for 'full'. |
| Paying tutors (`tutor_pay.payout_method`) | How tutors are paid out | `manual_list` A list for manual transfers<br>`bank_file` Bulk payment file for your bank **[SOON]** | `manual_list` | **[DEV · saved only]** 'Bulk bank file' is coming soon. Tutors' own payout details are a separate branch feature. Choices marked [SOON] cannot be picked yet. |
| Tutors see (`tutor_pay.tutor_visibility`) | What tutors see of their pay | `running` Running earnings during the month<br>`closed_only` Only closed pay statements | `closed_only` | **[DEV · saved only]** Shown unless pay is off. |
| (note) (`tutor_pay.employment_note`) | A reminder that employees may need payslips and CPF | (a note, nothing to choose) | — | **[DEV]** built A note, not a setting; confirm obligations with your accountant. |

#### Step 9 — Import data

**[SOON]** CSV import: templates for tutors, students (level, subjects, class, fee plan), parents and households. Nothing to choose yet.

#### Step 10 — Review and launch

A read-only summary of every step with 'Edit' links, a sample invoice and a sample pay statement, then **Launch**.

#### The `solo` preset

A solo tutor is an organisation of one created with preset `solo`: the same settings, defaults changed where a one-person business differs. A solo tutor never sees this wizard; the preset only fills the stored defaults.

| Setting | Centre default | `solo` default |
|---|---|---|
| `invoicing.review_before_sending` | Yes | No |
| `lessons.attendance_by` | `tutor` | `admin` |
| `tutor_pay.mode` | `report` | `off` |

Also stored for every organisation: `schema_version` = 1, `preset`, and an empty `data` section (reserved for imported data, step 9).

<!-- OPTIONS:END -->

**When a change takes effect.** Billing, invoicing, payments and tutor-pay settings apply **from the 1st of next month**; everything else applies **today**. Setup mode applies at once. A version's effective date can never be in the past after launch. **[DEV]**

**Defaults worth remembering for the lesson rules** (the owner's decision, 2026-11-24): attendance marked by the **tutor**; window **14 days**; cancellations marked by an **admin**; the charge typed by an **admin**; trials flagged by an **admin**; remarks **not** required; tutors do **not** see parent contact.

Source: `assets/js/org-settings.js`, `db/migration_org_foundation.sql`, `db/migration_tutor_access.sql`, `tests/org-settings.test.js`, `tests/org-soon.check.js`.

---

## 4. Key workflows end to end

For each: **who does what**, and the status of each step.

### 4.1 A lesson's life

**Solo tutor [LIVE]**

| Step | Who | What happens |
|---|---|---|
| 1. Weekly slot | Tutor (Planner) | A **recurring slot** is a template: student, day, time, subject(s), rate. It only *projects* "not logged" blocks on the Calendar |
| 2. Lesson | Tutor | **Log this week / month** creates real **lessons** from the slots (skipping what is already logged); or **+ Add lesson** for a one-off (✦). Status **scheduled** |
| 3. Taught | System | When the day passes the lesson becomes **done** (promoted when the Ledger or Home next opens) |
| 4. Notes | Tutor | Topics, homework, plan for next time |
| 5. Unpaid | System | A done lesson with no payment appears under **Outstanding by student** |
| 6. Invoice and pay | Tutor, parent | See 4.9 and 4.10 |

The `lessons` table is the ground truth: Ledger, Calendar, student profile, invoices and the monthly schedule all read it.

**Centre**

| Step | Who | What happens | Status |
|---|---|---|---|
| 1. Weekly slot with a tutor | Staff (`manage_timetable`) | A slot needs a **tutor** and a lesson generator for centres | **[PLANNED]** T3.7 (`recurring_slots` has no tutor column yet) |
| 2. Lesson | System | Lessons carry `taught_by` (the tutor's membership id) and, for groups, a shared `session_id`. Today they exist only from the demo seed | **[DEV]** columns; **[PLANNED]** generator |
| 3. Attendance | Tutor or staff | Marked from the lesson's day (never before). Tutor: within the centre's window. Staff: any day from the lesson's day, and can **correct** with a reason | tutor **[DEV]**; staff **[BRANCH]** |
| 4. Status follows attendance | System | **attended = done**; **absent / cancelled in time / late cancelled = cancelled** | **[DEV]** |
| 5. Charge | Admin or tutor (centre's choice) | Absent/cancelled lesson's **compensation** is typed (0 = not charged); blank = **pending** | tutor **[DEV]**; staff queue **[BRANCH]** |
| 6. Invoice | Staff | Invoice run from lessons; **a cancelled lesson with a blank charge blocks invoicing** | **[PLANNED]** T4 |
| 7. Payment | Staff | Record payment against the invoice; tutor pay later | **[PLANNED]** T4 |
| 8. TutorDeck's fee | System | Counts last month's active students (4.15) | **[DEV]** |

### 4.2 Absent and cancelled lessons: the charge (compensation)

The owner's rule (2026-11-24) is the way the app has always billed:

- When a lesson is **absent** or **cancelled**, the lesson's **status becomes `cancelled`** and what the family owes is its **compensation**, a number someone types.
  - **0** = the family is **not charged**.
  - A positive number = charged that much (never more than the lesson's own price for centres).
  - **blank (null) = "charge pending"**: an admin still has to type it, and **invoicing must wait**.
- **Attended = done**, billed at the lesson's amount.
- Solo tutors: pressing **Cancel lesson** shows "Won't count toward income unless you add a compensation amount" with an optional **Cancellation fee**. The lesson's status changes only when the tutor cancels; setting attendance never changes a solo lesson's status. **[LIVE]**
- Centres: this status/compensation mapping **only applies to centres**. Who types the charge is the centre's choice (`lessons.compensation_entered_by`): **admin** (default) or **tutor** (capped at the lesson's price). **[DEV]**
- The **suggested** charge in the staff Charges queue follows `billing.absences.mode` (see 2.3) and always needs a person's confirmation. **[BRANCH]**
- Amounts are whole cents at the edge (`compensation_cents`); a paid lesson's charge is locked; every change writes an audit entry. **[BRANCH]**
- Open question on the branch: does "charged" mode suggest 0 for **in-time cancellations**? (owner decision pending, see 8)

### 4.3 Postponing and make-ups

**Today's behaviour [LIVE]**

- **Postpone** (Calendar): the *same lesson row* moves to a new date/time and is flagged *postponed*; its original slot date is kept so no phantom "not logged" block appears; "Revert to slot" undoes it. It is **one lesson, billed once**. No credits exist.
- **Make-up**: there is no such object. A tutor adds a normal **one-off lesson** (✦), billed like any lesson. Nothing links it to the missed lesson.
- **The hazard** (T18 finding): if the missed lesson is marked absent/cancelled (billed at its compensation) **and** a separate make-up is added, a family can be charged twice.

**Planned rule (owner decisions 2026-11-24) [PLANNED]**
- **One missed lesson owed = one credit; a make-up never costs a second credit.** The make-up *fulfils* the same credit.
- A credit is earned for **notice-given absences, tutor cancellations and holidays**.
- **Credits never expire by default.** A centre setting `billing.makeups.credit_rule` is planned with options `none`, `one_per_missed` (default), `charged_missed_free_makeup`; every option is to be fully built with a test per value. A `makeup_credits` table is planned. Solo tutors keep today's behaviour.
- Until built, the wizard's make-up and credit options are **[SOON]**.

### 4.4 Trials

- A **trial lesson** is flagged on the lesson (`trial`). A trial is **not counted** as an active student for TutorDeck's centre fee. **[DEV]**
- Who may flag: `lessons.trials_flagged_by` (admin default, or tutor). On My lessons a tutor sees the toggle only if allowed. **[DEV]**
- Staff can always flag. Student list shows a "Trial" badge (a trial lesson in the last 30 days). The staff **flagging screen** is **[PLANNED]** T3.5; read-only badge **[BRANCH]**.
- Solo tutors: a trial is just a lesson (often $0, which counts as settled). **[LIVE]**
- Changing the flag after that month's fee snapshot exists does **not** change the snapshot (the screen is to say so). **[PLANNED]**

### 4.5 Group lessons

- **Centre:** a group lesson is *one lesson row per student* sharing the same `session_id` (no `classes` table yet). Tutors see them as one class on My lessons; staff mark each student separately. **[DEV]** grouping; creating a group from a screen is **[PLANNED]** T3.9. A real classes table with rosters and fee plans may come with T4.
- **Solo:** each student's lesson is its own row; siblings overlapping in time is not a clash. **[LIVE]**
- Nothing in the staff screens needs a class, a room or a branch (1-to-1 centres are first-class). **[BRANCH]**

### 4.6 Holidays

- **Centre:** holidays are a list per centre (name, start, end, optional branch). The **Singapore public holiday library** lets the owner tick which to add (never auto-applied). **[DEV]**
- **Skipping lessons on holidays** is **[SOON]**: planned option `calendar.holiday_action` = `skip_generation` (default, not generated; grey band on the timetable) or `generate_and_flag` ([SOON]). Lessons already generated on a newly ticked day are **not** deleted; the wizard will offer a one-tap "Cancel with no charge". A holiday earning a make-up credit follows the credit rule (4.3). **[PLANNED]**
- **Solo tutors** have no holiday screen; a holiday library for solo tutors is planned. Today they cancel or delete holiday lessons by hand. **[LIVE]**
- Date source: Ministry of Manpower public holiday page (last updated 19 June 2026), read 2026-11-24; **2027 re-check before shipping; add the next year each November**.

### 4.7 Replacing a tutor

- A lesson's tutor is `taught_by`. A database rule requires the new tutor to be an **active tutor in the same centre**.
- Centre setting `lessons.replacement_tutors` (default **on**): on = an admin may change a lesson's tutor to another tutor; off = only a lesson with **no** tutor may be given one. Both enforced by a database rule. **[DEV]**
- There is **no screen yet** to cover a lesson ("Cover by…"); it is **[PLANNED]** T3.8. Removing a tutor from the centre (so their lessons show "Former tutor") is **[PLANNED]** T24c.5/7.

### 4.8 Discontinuing a student

- **Solo [LIVE]:** Students → student → **Discontinue** or set **Lessons run until** (inclusive). After that date: no lessons are generated, the student is hidden in Planner and pickers, their weekly slots are turned off (**Reactivate** turns them back on); history stays. On DEV, reactivating counts against the 5-student free limit.
- **Centre [BRANCH]:** the Students sheet has the same "lessons run until" and bring back; it also switches the weekly slots off once the date has passed.
- Anywhere "ended" is decided by the same helper (`TL.isEnded`, `TL.pastEnd`).

### 4.9 Invoicing and PayNow

**Solo [LIVE]**
1. Ledger → Outstanding → pick a student (or tick several lessons) → **Invoice**.
2. The invoice shows the student, subject and level (subject from the billed lessons, level from the profile), lines, total and a **PayNow QR** (SGQR payload built in `assets/js/paynow.js`), or **bank-transfer details** if the student is flagged "pays by bank transfer" (a household invoice uses bank if any member is flagged).
3. **Send on WhatsApp** (image attached; marks it sent) or **PDF** (then "Did you send this invoice?") or **Message** to copy the covering text.
4. Invoices live on the **Invoices** page: **Saved → Sent → Paid**; "Not invoiced" rows are outlined in amber on Who owes you.

**Centre [PLANNED] T4:** invoice runs from lessons, one per **family** or per **student** (centre's choice), GST per the centre's setting **once per invoice, half up**, a cancelled lesson with blank compensation is "not ready", drafts approved by an admin if chosen, **issued invoices are immutable** (changes by credit note), manual PayNow recording, shareable link/email later. Money maths is already in `assets/js/money.js` (tested). The wizard's sample invoice previews it.

### 4.10 Recording a payment

- **Solo [LIVE]:** one pay window (payment date, optional screenshot stored in a private "receipts" bucket). It is reached from the Ledger's **Mark paid**, the Invoices tab's **Mark as paid**, and the student page's **Mark paid**. Marking all of an invoice's lessons paid marks the invoice **Paid**; unticking one puts it back. A $0 lesson is settled.
- **Centre [PLANNED] T4:** staff with `record_payments`; tutors are paid only after the parent's payment is reconciled by default (`tutor_pay.payable_when`). **TutorDeck never holds a centre's money.**

### 4.11 WhatsApp reminders

- **[LIVE]** One tap on an outstanding balance opens WhatsApp with the **reminder template** (editable in Settings; placeholders in 2.1). Invoices use the **invoice template**. The greeting names the "name in messages" (usually the parent). On macOS the app skips the system share sheet; elsewhere the share sheet attaches the invoice image.
- **Not built:** any automatic or email reminder. Centre "payment reminders" and "missed-remarks reminders" are **[SOON]** and depend on the email provider.

### 4.12 Google Calendar sync

- **[LIVE]** Calendar → **Connect Google Calendar** → choose which calendar → **Sync now**. Google consent is asked once; afterwards the server holds an encrypted key and syncs lessons so the tutor may close the page. One-way only (details of how cancelled lessons are treated in Google: **not verified**). The Google app is published but unverified (limit of 100 users and a warning screen) until the owner submits it for verification.
- Centres: Google sync for centres is not planned (T3 plan, "out of scope").

### 4.13 Exams

- **[LIVE]** Exams page or the student profile: add an exam with type, subject, date, topics and marks; a **countdown** shows upcoming exams on Home; scores feed the student's Progress tab and show on the Calendar. Exams are hidden in Client view.
- Centres: exams are not a centre feature yet; `manage_students` can write the table.

### 4.14 Ledger, Calendar, Planner and Insights (solo)

| Page | Use it to | Status |
|---|---|---|
| **Planner** | Define the repeating week | **[LIVE]** |
| **Calendar** | See the real week/month, lessons, exams, clashes; add/postpone/edit a lesson in place; link "Edit in Ledger" opens the exact lesson | **[LIVE]** |
| **Ledger** | Money truth: Outstanding by student, Records, bulk select/delete, log week/month, record payment, invoices | **[LIVE]** |
| **Insights** | Income by month and across the year, by student, by subject and level | **[LIVE]** |
| **Home** | Money card and Teaching section; first-run checklist | **[LIVE]** |

### 4.15 TutorDeck's monthly fee for a centre

1. All month: tutors/staff mark attendance; trials are flagged.
2. On the 1st (daily cron 00:30 Singapore time), for every **active** centre without a snapshot for the month: count last month's **active students** (non-trial; attended, absent or late-cancelled; each student once).
3. Round to the nearest 10 (halves up) → **billable students**. Fee = S$100 + S$0.40 × billable.
4. Set the quantity on the centre's per-student Stripe item and write the snapshot (last, so a failed run is retried). A re-run does nothing. If Stripe already invoiced the renewal, the job refuses.
5. The owner sees the snapshots on the Plan tab.
Status: **[DEV]** (never run against real money). Each centre's Stripe subscription is created **by hand** with both items before it works.

### 4.16 End to end: onboarding a tutor at a centre

| # | Who | Step | Status |
|---|---|---|---|
| 1 | Owner | Create the centre, walk the wizard, **Launch** | **[DEV]** |
| 2 | Owner | People → invite tutor (name, email, employee/freelancer) | **[DEV]** |
| 3 | System | Email with a set-password link (24 hours) | **[BRANCH]** (today: the owner tells the tutor to sign up with that email) |
| 4 | Tutor | Opens link or signs up with that email → invite is claimed → lands on **My lessons** | **[DEV]** |
| 5 | Staff | Give them lessons (weekly slot with tutor) | **[PLANNED]** T3.7 (today: seed data only) |
| 6 | Tutor | Marks attendance, writes remarks; sets payout details | **[DEV]**; payout **[BRANCH]** |
| 7 | Admin | Types pending charges | **[BRANCH]** |
| 8 | Owner | Resends an unaccepted invite | **[BRANCH]** |

### 4.17 Switching between your own tuition and a centre

A person with a solo practice and a centre role sees the **switcher chip**; choosing an organisation reloads into that organisation's landing page (solo: Home; centre: the centre page; centre tutor: My lessons). The solo pages and the centre pages never show each other's data (1.3). **[DEV]**

---

## 5. Data and privacy

### 5.1 What is stored

| Data | Where | Notes |
|---|---|---|
| Login, email, password hash | Supabase Auth | Passwords never reach TutorDeck's code |
| Tutor profile and business settings | `profiles` | Business name, PayNow ID, bank details, message templates |
| Students, guardians, households, lessons, slots, exams, invoices | Supabase Postgres | Every row carries `org_id` |
| Payment screenshots, materials | Private storage buckets `receipts`, `materials` | |
| Google Calendar link | `gcal_links` | The long-lived key is **encrypted** and only the server can decrypt it |
| Organisation settings | `org_settings` | Append-only, effective-dated versions |
| Subscriptions | `org_subscriptions` | Stripe customer and subscription ids, status, trial end; **no card numbers** |
| Fee snapshots | `platform_fee_snapshots` | Append-only |
| Audit log | `audit_log` | Who changed what; append-only |
| Tutor payout details | `tutor_payout_details` | **[BRANCH]**; append-only, no browser access |
| Error reports | `client_errors` | Short crash/request-failure messages; 90 days |
| Invite email log | `org_invite_mail_log` | **[BRANCH]**; ids, time, status only: **no address, no link** |
| Backups | GitHub Actions artifacts | Encrypted, 30 days. The repository is **public**, so dumps are never committed |

### 5.2 Who can see what

| Who | Sees | Does not see |
|---|---|---|
| **Solo tutor** | Their own organisation's rows only (row-level security `tutor_id = their login` inside solo organisations) | Anyone else's |
| **Centre owner** | Their centre: everything including prices, parents' contact, audit log, plan | Other centres; a solo tutor's data |
| **Centre staff** | Read all business data of their centre; write what their permissions allow; audit log only with `view_audit_log` | Settings changes, billing and plan (owner only); payout numbers (unless `view_payout_details`) |
| **Centre tutor** | Only their own lessons, via two functions; student **name and level**; **parent contact only if the centre allows** | **Any price, rate, amount, paid, compensation, invoice, other tutors' data**; they have **no table access at all** |
| **Parent** | Nothing (no login) | — |
| **Platform admin** | Organisations, plan and fee numbers via one function; **never** student records unless the owner grants time-limited support access | — |

- **Money is hidden from tutors by design:** `tutor_my_lessons` has an explicit column list with no money (only a yes/no "tutor sets the charge"); a test checks this stays true. Any new column needs a check that it is not money.
- **Parent contact setting:** `lessons.tutors_see_parent_contact`, default **off**.
- **Payout masking [BRANCH]:** tutors and the centre see `•••••1234`; the full value is only shown on an explicit **Reveal**, which writes an audit row (who, whose, when, method, masked value, never the number). The centre sees a 7-day amber flag when details change. Staff without the permission see only "provided / not provided".
- **Audit log:** a trigger copies before/after of important tables; the table cannot be edited or deleted by anyone signed in. Exceptions are narrow and flag-controlled: `td.deleting_org` (solo account deletion), and, planned, `td.removing_member` (removing a tutor) and the attendance override.
- **Row-level security** is on every table. Functions that help with access (`org_can`, `org_role`…) were locked down so anonymous users cannot call them.

### 5.3 Account deletion and retention

- **Solo account [DEV route]:** removes everything of theirs: organisation, students, guardians' contact details, lessons, invoices, files, settings, the audit trail, the Stripe customer and subscription, and the Google link, then the login. **Do not delete a tutor's rows by hand** in the browser or SQL editor: that would copy their data into the audit log.
- **Audit rows when an organisation is deleted:** the worker's choice was "delete all audit rows of that organisation and keep one anonymous marker row". **Owner has not confirmed** this yet.
- **Centre members:** cannot use the self-service route yet (refused with "other organisations"). The plan for tutors: erase login, name, phone, email and current payout details at once; lessons and attendance stay as "Former tutor"; old payout rows erased **12 months** after leaving (owner to confirm with the company's adviser). **[PLANNED]**
- **PDPA (Singapore):** the plan treats TutorDeck as a data intermediary and the centre as the organisation responsible. This is **not legal advice**; the owner must confirm with the company's adviser. Minimum collection for payouts (no NRIC, no statements). Breach duty: tell the PDPC within 3 days if significant harm.
- **Legal pages:** `privacy.html` and `terms.html` exist; the Google OAuth branding links point at `tutordeck.vercel.app` and should switch to `tutordeck.com.sg` once that domain is confirmed live.

### 5.4 Secrets

The Supabase **publishable** key in `assets/js/config.js` is safe to commit. **Service-role keys, SMTP passwords, Stripe secret keys, Brevo keys, the Google client secret and `CRON_SECRET` are never in the repository**; they are Vercel environment variables, server side only. This guide contains none.

Source: `db/migration_org_foundation.sql`, `db/migration_tutor_access.sql`, `db/migration_org_delete.sql`, `docs/orchestrator/T24b-plan.md`, `README.md` (Backups), `CLAUDE.md` (Data warning).

---

## 6. Environments and release

### 6.1 Two databases

| | Production | Everything else |
|---|---|---|
| Addresses | `www.tutordeck.com.sg`, `tutordeck.com.sg`, `tutordeck.vercel.app` and the two other aliases of the production deployment | Every Vercel preview, the `dev` staging site, local testing, any unlisted address |
| Database | **LIVE** project (real students, real payments) | **DEV** project (dummy data only) |
| Marker | none | A "Test version · dummy data only" tab at the top of every page |
| Server functions (`api/`) | Production environment variables | Preview variables point at DEV; with no settings only the production deployment falls back to the live project |

The choice is made in `assets/js/config.js` **by hostname, defaulting to DEV**, so a mistake fails on the safe side. A **new production domain must be added** to `PRODUCTION_HOSTS` in `config.js` and to `tests/config.test.js`, or that domain would show the test banner and nobody could sign in.

### 6.2 DEV demo data

`db/seed_dev_demo.sql` (DEV only; never LIVE) creates the demo logins in 0.4 and a centre with lessons. DEV has no Google sign-in, no bot check and its own auth settings, so test sign-in with the email logins.

### 6.3 How a change ships

1. Work on a short-lived `feature/<name>` (or `claude/<task>`) branch **off `dev`**.
2. Pull request into **`dev`** → checks run → the **Vercel preview** (DEV data) is tested by the owners.
3. Only when the owner says **ship**, open the `dev` → **`main`** pull request. `main` is protected (no direct pushes, no force-push); every merge to `main` **auto-deploys to production within about a minute**.
4. Each change bumps the **cache-buster** `?v=N` in every page (`bash bump-version.sh <N>`), adds an entry to the "Raphael's updates" log in `README.md`, and keeps the phone layout working (breakpoint 820px).
5. **Database migrations** (`db/migration_*.sql`): apply to **DEV first**; run on **LIVE in the Supabase SQL editor before the code that needs it reaches `main`** (otherwise production errors with "column does not exist"). Before any statement that changes real rows: show a SELECT preview and get a yes. Order everywhere: **org_foundation → billing → attendance → tutor_access → org_delete → function_lockdown → org_separation**, undo in reverse; unmerged branches add staff_home, invites, tutor_profile, tutor_payout, payout_permission, staff_students, staff_attendance, staff_charges. `docs/orchestrator/dev-apply-pack.sql` (branch `claude/t26b-dev-pack`) bundles the branch migrations into one DEV script with a post-check.
6. **Standing rules (owner, 2026-11-24):** no Vercel deploys until the owner says so; any GitHub Actions run needs the owner's approval; merge into `dev` only when the owner needs to test, and then as **one complete user flow**.

### 6.4 Checks

| Check | What it covers |
|---|---|
| Unit tests (`node --test tests/*.test.js`) | Money maths, settings schema vs the database list, billing, config, password rules, tutor logic, org scoping |
| Database tests (`bash tests/sql/run.sh`) | Runs all seven standard migrations plus branch ones on a **throwaway** Postgres, each with its own test and an undo check, never on a real database |
| Browser checks (`tests/*.check.js`) | Tutor page, switcher, plan card, password hint, holiday library, "soon" settings, host/database choice |
| Smoke tests in CI (`.github/workflows/checks.yml`) | On every pull request into `dev` or `main`, with made-up data and no outside requests |
| Nightly backup (`.github/workflows/db-backup.yml`) | Encrypted dump, 30-day artifacts |

Source: `CLAUDE.md`, `assets/js/config.js`, `bump-version.sh`, `.github/workflows/`, `tests/`, `docs/orchestrator/ORCHESTRATOR.md`.

---

## 7. Roadmap

### 7.1 Built but not merged (waiting for the owner's test round)

| Branch (all on `origin`) | What it adds | DEV script needed |
|---|---|---|
| `claude/t3-1-staff-home` | Centre Home (counts), two staff demo logins | `migration_staff_home.sql` + seed |
| `claude/t3-2-students` (on t3-1) | Staff Students and households | `migration_staff_students.sql` |
| `claude/t3-3-attendance` (on t3-2) | Staff Attendance, correction with reason, integrity guard | `migration_staff_attendance.sql` |
| `claude/t3-4-charges` (on t3-3) | Pending charges queue with suggested charge | `migration_staff_charges.sql` |
| `claude/t7-2-invites` | Invite email through Brevo, welcome page, Resend invite, reset page uses the full password rules | `migration_invites.sql` + owner's Brevo/Supabase steps |
| `claude/t24c-1-profile` | Tutor settings page: name, phone, change password | `migration_tutor_profile.sql` |
| `claude/t24c-2-payout` (on t24c-1) | Tutor payout details (masked, reveal, audited) | `migration_tutor_payout.sql` |
| `claude/t24c-3-payout` (on t24c-2) | `view_payout_details` permission, centre payout list and audited reveal | `migration_payout_permission.sql` |
| `claude/t26b-dev-pack` | One combined DEV SQL pack for the above (30 post-check rows) | — |
| Not on origin | `claude/t24c-5-leave` (leave-centre, DB only): its sessions never started | — |

Known test note: the branch `t3-4-charges` has one failing assertion in `tests/sql/staff_charges_test.sql` (line 138, "rule in force on the lesson's own day"); the pack author ran the other 92 assertions and flagged it for a look.

### 7.2 Planned (in the owner's order of need; not yet built)

| Item | What | Notes |
|---|---|---|
| **T3.5** | Trial flag in the attendance/lesson sheet and Students filter | Counts drop from the monthly active total |
| **T3.6** | Timetable read-only: week list by day, tutor filter, holiday band, "no tutor" flags | Phone-first list, not a grid |
| **T3.7** | Weekly slots with a tutor + a centre lesson generator (skips holidays and ended students; safe to run twice) | Needs `recurring_slots.taught_by` and `session_key` |
| **T3.8** | Reassign and replacement ("Cover by…") | Uses `lessons.replacement_tutors` |
| **T3.9** | Group lessons (several students, one `session_id`) | |
| **T3.10** | Permission sweep: one matrix test over every function and screen | |
| **T4** | **Centre invoicing and tutor pay**: invoice runs from lessons, households, GST per centre setting, credit notes, manual PayNow recording, tutor pay (report then full; "per lesson", "per hour", "per student per lesson", "fixed monthly"), pending-charge blocking | Plan first. Needs online lesson link and tutor pay **per lesson** for 1-to-1 centres |
| **T6** | Tutors edit their own lessons (`timetable_editing = tutors_own`) | Setting-driven database function; same no-table-access rule |
| **T7 (rest)** | Supabase auth emails and the invite email through Brevo (owner steps E0–E3), later remarks reminders; a real support mailbox | Free Brevo plan ≈ 300 mails/day with a "Sent with Brevo" footer; upgrade before a big centre |
| **T18 (rest)** | Holidays skipping lessons, make-up credits ledger | See 4.3, 4.6 |
| **T24c rest** | Leave centre / remove tutor, tutor "ask to leave" flow, centre removal, optional bank-number encryption, "Download my data" for tutors | |
| **Parent portal** | Parent/student log-in, see invoices/remarks/attendance subject to centre options, pay | Not designed |
| **CSV import** | Tutors, students (level, subjects, class, fee plan), parents, households | wizard step 9 |
| **Logo upload and branded invoices** | | |
| **Payment gateways** | HitPay, Stripe for centres' parents, bank-statement matching (DBS, OCBC, UOB, custom CSV) | **[SOON]** in the wizard |
| **T8 Go-live** | The checklist in 1.4 | Owner-gated; not started |
| **Fixes** | T13 contradictory message for a window of -3; T14 remarks due shown in browser time zone; T16 owner menu entry (done by T12c); delete throwaway DEV user (T17/T21 script ready, not run) | |
| **Mobile bottom tab bar** | Idea paused (Oct 2026) | |
| **Dummy test account** | A safe account for testing write flows | |

### 7.3 Owner's decisions recorded so far (do not re-ask)

| Date | Decision |
|---|---|
| 2026-11-24 | **Solo plan:** free for up to 5 **active students**; Solo Pro **S$14.90/month or S$149/year**; **30-day trial**, once per organisation, **no card to start**; **existing solo tutors stay unlimited (grandfathered)**. |
| 2026-11-24 | **TutorDeck is not GST-registered**; prices carry no GST. Centres choose their own GST settings. |
| 2026-11-24 | **Centre fee** S$100 + S$0.40 × billable students; billable = last month's active, rounded to nearest 10 (halves up); trials excluded. Under review against SchoolTracs; **kept for now**. |
| 2026-11-24 | **Product principle:** anything depending on a centre's own process is a wizard option; build every option; unbuilt ones are marked "coming soon". |
| 2026-11-24 | **Absent/cancelled billing = compensation** (0, a number, or blank = pending). Who types it, flags trials, marks cancellations, attendance window, who marks attendance, remarks required: all centre settings. Defaults: admin / admin / admin / 14 days / tutor / no. |
| 2026-11-24 | Tutors see no parent phone by default; tutors have **no table access**, only two database functions. Group classes: one lesson row per student tied by `session_id`. **Previews use DEV; only production uses the real database.** |
| 2026-11-24 | **Centre and solo must be separate** (T12): centre owner loses solo-screen view of centre data until staff screens exist; switcher for multi-org people; centre staff land on centre home. |
| 2026-11-24 | **Make-ups (T18):** one missed lesson = one credit, make-up never charged twice; credit for notice-given absences, tutor cancellations, holidays; credits never expire by default; centres skip holidays by default; holiday library for solo tutors later; SG dates from MOM, re-check 2027, add next year each November. |
| 2026-11-24 | **Standing rules:** no Vercel deploys until the owner says; any GitHub Action needs approval; merge to `dev` only as one complete flow when the owner needs to test. |
| 2026-11-25 | **Settings** are for solo, "both" and centre owner only, **not** for tutor-only logins; but tutors under a centre **should** have a small tutor-settings page (name, password, payout details, delete account). |
| 2026-11-25 | **T3 (all six yes):** staff with `manage_timetable` may correct any mark with a **required reason** (audit-logged), tutors never; pending charges typed by `issue_invoices`; staff can always mark/correct (`attendance_by` governs tutors only); group classes light (shared `session_id`); absence-charge setting only **pre-fills**, an admin confirms; centre staff v1 = steps 1–5. Past-unmarked = 60 days; centre staff have 8 permissions. |
| 2026-11-25 | **T7 (all five yes):** invite landing = reuse `/reset` welcome variant; link expiry 24 h; **Brevo free plan** for now; previews only email `@tutordeck.com.sg` + allow-list; centre name in the display name, sender stays `noreply@tutordeck.com.sg`; admin must have a **Resend invite** option; reply-to set for launch (a team address). Staff with Manage tutors may resend; welcome page says "Welcome to TutorDeck"; claim at most every 30 min per login. |
| 2026-11-25 | **T24b (all yes):** leaving = request to the centre owner (one tap, **auto-OK after 7 days**), then erase login and personal data, lessons/attendance stay as "Former tutor"; new permission `view_payout_details` (owner always, staff opt-in); old payout rows erased 12 months after leaving (confirm with the adviser); bank-account encryption later; amber flag for 7 days when payout details change. |
| 2026-11-25 | **T12c:** menu label "Centre" for one centre, "Centres" for more than one. **Bundle 3** merged into `dev`. |
| 2026-11-25 | **1-to-1 / remote centres** (e.g. Opus Tuition) are first-class: never require class/room/branch; add online lesson link and tutor pay per lesson in T4/T3 planning. |
| 2026-11-26 | Owner asked for a report at 10:00 Singapore time; no merges into `dev` meanwhile; no LIVE changes. |

---

## 8. Known gaps and open decisions

### 8.1 Gaps (things a customer would hit)

1. **A centre cannot schedule lessons in the app yet.** The solo Planner/Ledger generator is hidden from centres, weekly slots have no tutor, and the centre generator is T3.7. Today centre lessons exist only from the demo seed. This is the biggest gap for a real centre.
2. **No centre invoicing, payment recording, revenue view or tutor pay** (T4). Permissions `record_payments`, `view_revenue`, `run_tutor_pay` exist but do nothing.
3. **Many wizard options are saved but read by nothing** (`[DEV · saved only]` in section 3): the billing, invoicing, payments and most tutor-pay options. They are **not** marked "Coming soon", so the wizard may promise more than the app does. The product principle says unbuilt options should be `soon`; the owner may want a second honesty pass like T18a.
4. **Holidays do not skip lessons** (`calendar.skip_holidays` is [SOON]) and solo tutors have no holiday screen.
5. **No make-up credits.** A make-up is a normal lesson and a family can be charged twice if it is also marked absent (4.3).
6. **No parent or student login**, no portal, no email to parents. The "share link / I've paid" route was removed in August 2026.
7. **No email at all from the app** except Supabase's built-in auth emails; invite email and branded auth emails are on a branch plus owner steps. The company domain **cannot receive mail** today (mail records point at the web host): a real support mailbox is needed before the first paying centre.
8. **Centre owners cannot delete the centre or transfer ownership**; centre tutors cannot leave or delete themselves (planned T24c.5–6).
9. **No admin console for TutorDeck's own team**; no screen to grant support access.
10. **Remarks to parents, tutors editing their own lessons, bank-statement matching, HitPay/Stripe for parents, CSV import, logo upload, bulk bank file** are all [SOON].
11. **Time zone and currency** are fixed to Singapore and SGD.
12. **Remarks "due" time** is shown in the browser's time zone, unlabelled (T14).
13. **Two-factor** exists only on the solo Settings page.
14. The **reset-password page** on `dev` and LIVE accepts six-character passwords (the branch fixes it).
15. **LIVE has none of the organisation, billing, attendance, tutor, delete or lock-down migrations.** Production is still the solo app at v252.

### 8.2 Open decisions for the owner

| # | Decision | Recommendation / state |
|---|---|---|
| 1 | **Audit rows when an account is deleted** | Worker chose "delete the organisation's audit rows, keep one anonymous marker row": **confirm** |
| 2 | **T3.3 attendance:** six decisions still to collect | Not recorded in the board; see `claude/t3-3-attendance` |
| 3 | **T3.4 charges:** does "charged" mode suggest 0 for an in-time cancellation? | Open |
| 4 | **T24c.3 payout admin:** five decisions pending | Not recorded here; **not verified** what they are |
| 5 | **Centre price** S$100 + S$0.40 | Under review vs competitors; kept for now |
| 6 | **Retention** of old payout rows (12 months) | Confirm with the company's adviser |
| 7 | **Bank-account encryption** now or later | Recommended later |
| 8 | **Version-number clash**: `t7-2-invites` and `t24c-1-profile` both use v273 (`t3-1` used v272) | The bundle assembler picks one number when merging |
| 9 | **Go-live** | Checklist in 1.4; owner must say go |
| 10 | **Google OAuth verification** and moving legal-page links to `tutordeck.com.sg` | After the domain is live |
| 11 | **Cross-promotion line** for MugCorner in the landing-page footer | Keep or remove: undecided |
| 12 | **Supabase auth email templates / sender** | Outside the repo; owner steps E1/E3 |
| 13 | **Vercel Pro** before charging; Hobby is non-commercial | Needed before go-live |
| 14 | **NULL_IS_MINE** flag | Flip to strict once LIVE shows no rows without an organisation |
| 15 | **T-Leng's old ✦ one-off lessons** on past lessons wrongly flagged | Fix per student after previewing the rows with T-Leng |
| 16 | **Delete the old integration branch** `claude/gifted-cori-wssq1j` and others | Safe, needs the owner's approval |
| 17 | **Mobile bottom tab bar** | Paused; revisit with the Finance/Teaching toggle in mind |

---

## Glossary

| Term | Meaning |
|---|---|
| **Active student (platform fee)** | A student with at least one non-trial lesson in the month marked attended, absent or late cancelled |
| **Active student (free-plan gate)** | A solo student on the roster who is not discontinued and not past their end date |
| **Attendance** | `attended`, `absent`, `late_cancelled`, `cancelled_early` ("cancelled in time"), or blank (not marked) |
| **Audit log** | The tamper-proof list of who changed what |
| **Billable students** | Last month's active students rounded to the nearest 10 |
| **Both (mode)** | A login with students of their own and a centre tutor role |
| **Branch** | (a) a centre's physical site; (b) a Git branch of the code, shown as `claude/…` in this guide |
| **Centre** | A tuition centre organisation |
| **Compensation** | The number that is billed for an absent or cancelled lesson: 0 = not charged, blank = pending |
| **DEV / LIVE** | The test database / the real database |
| **Grandfathered** | A solo tutor who joined before billing: unlimited free students |
| **Household** | A family: siblings and their guardians |
| **Membership** | A person's role in one organisation |
| **Organisation** | The container for people and data: `solo` or `centre` |
| **Owner** | The centre's top role |
| **Permission** | A staff ability, e.g. `manage_students` |
| **Planner / slot** | The weekly template of lessons |
| **Preset** | `solo` or `centre`: the starting settings |
| **Row-level security (RLS)** | The database rule that decides which rows a login may read or write |
| **Session id** | The shared id that makes several students' lesson rows one group class |
| **Status** (lesson) | `scheduled`, `done`, `cancelled` |
| **Trial** | A lesson flagged as a first/trial lesson; free of TutorDeck's fee |
| **Tutor-only / both / solo (mode)** | Which menu a login gets |
| **✦** | The marker for a one-off (manually added) lesson |

---

## Appendix: where to find things in the code

| Topic | Files |
|---|---|
| Every centre option | `assets/js/org-settings.js`, `db/migration_org_foundation.sql` (`org_validate_settings`) |
| Wizard / centre page | `org.html`, `assets/js/org.js` |
| Organisations, roles, permissions, audit | `db/migration_org_foundation.sql` |
| Billing and plan | `db/migration_billing.sql`, `api/billing.js`, `api/stripe-webhook.js`, `api/billing-cron.js`, `assets/js/plan.js`, `assets/js/money.js` |
| Attendance and the fee count | `db/migration_attendance.sql`, `db/migration_tutor_access.sql` |
| Tutor page | `tutor.html`, `assets/js/tutor.js`, `assets/js/tutor-core.js` |
| Menus, roles, switcher | `assets/js/app.js`, `assets/js/org-current.js`, `assets/js/org-scope.js` |
| Account deletion | `api/delete-account.js`, `db/migration_org_delete.sql` |
| Google Calendar | `api/gcal.js`, `api/gcal-callback.js`, `api/_gcal-lib.js`, `assets/js/gcal-core.js` |
| Environments | `assets/js/config.js`, `tests/config.test.js` |
| Demo data | `db/seed_dev_demo.sql` |
| Plans and notes | `docs/orchestrator/` (`BOARD.md`, `ORCHESTRATOR.md`, `T12-plan.md`, `T12c-notes.md`, `T18-plan.md`) and on branches `T3-plan.md`, `T7-plan.md`, `T24b-plan.md`, `T2-report.md` |
| Staff screens (branches) | `centre.html`, `centre-students.html`, `centre-attendance.html`, `assets/js/centre*.js`, `db/migration_staff_*.sql` |
| Invites (branch) | `api/send-invite.js`, `api/_brevo-lib.js`, `db/migration_invites.sql`, `docs/orchestrator/T7-owner-steps.md` |
| Tutor settings (branches) | `tutor-settings.html`, `db/migration_tutor_profile.sql`, `migration_tutor_payout.sql`, `migration_payout_permission.sql` |
| This guide's checker | `docs/product/build-options.js` |

*End of guide.*
