# TutorDeck Product Guide

*The product specification: how TutorDeck works for every role when it is complete.*

**Written:** 2026-11-26 · **For:** the owners of TutorDeck Pte. Ltd. (Raphael and T-Leng) · **Basis:** the code in `TutorDecks/TutorDeck` and its branches, the plans in `docs/orchestrator/` (T3, T4, T7, T12, T18, T24b), and the owner's decisions in `docs/orchestrator/BOARD.md`.

This guide is written in the present tense as the finished product. **Appendix A (Build status)** says which parts are built, on a branch, or still planned. Where the owner has not decided something, the guide describes the **recommended** behaviour and lists it in **Open decisions** (section 7). It is plain-words, not legal advice.

---

## Table of contents

- [0. How to read this guide](#0-how-to-read-this-guide)
- [1. What TutorDeck is](#1-what-tutordeck-is)
- [2. The roles, one by one](#2-the-roles-one-by-one)
  - [2.1 Solo tutor](#21-solo-tutor) · [2.2 Centre tutor](#22-centre-tutor) · [2.3 Centre staff](#23-centre-staff) · [2.4 Centre admin / owner](#24-centre-admin--owner) · [2.5 Parent / student](#25-parent--student) · [2.6 Platform admin](#26-platform-admin) · [2.7 Accounts: sign-up, invites, log-in, password, deletion](#27-accounts-sign-up-invites-log-in-password-deletion)
- [3. Centre options reference](#3-centre-options-reference)
- [4. Key workflows end to end](#4-key-workflows-end-to-end)
- [5. Data and privacy](#5-data-and-privacy)
- [6. Environments and release](#6-environments-and-release)
- [7. Open decisions](#7-open-decisions)
- [Glossary](#glossary)
- [Appendix A: Build status](#appendix-a-build-status)
- [Appendix B: Where to find things in the code](#appendix-b-where-to-find-things-in-the-code)

---

## 0. How to read this guide

- Sections 1–6 describe the **finished product**. Nothing in the body is tagged by build state.
- **Appendix A** maps every feature to **Built** (on the `dev` staging site; the solo tutor app is also on production), **On a branch** (built and tested, not merged), or **Planned**.
- **Appendix A.4** records the owner's decisions so far.
- **"The centre chooses"** means a setting in the setup wizard (section 3). The rule behind it (CLAUDE.md, owner, 2026-11-24): anything that depends on a centre's own business process is a **centre option**; what stays fixed is **integrity** (nobody marks a lesson before its day, nobody silently overwrites another person's mark, tutors never see a lesson's price or date or time, tutors have no table access).
- Amounts are Singapore dollars; money is kept in whole cents.

---

## 1. What TutorDeck is

TutorDeck is a web app (phone and computer, no app-store install) for people who run tuition in Singapore, made by **TutorDeck Pte. Ltd.** It began as one tutor's dashboard and now serves solo tutors and tuition centres.

### 1.1 Who it is for

| Customer | What they get |
|---|---|
| **Solo tutor** | Students, weekly planner, calendar, ledger of who owes what, PayNow invoices, WhatsApp reminders, exams, student profiles, insights, Google Calendar sync |
| **Class-based tuition centre** | A centre account with owners, staff and tutors; a setup wizard where the centre chooses its own rules; timetable with rooms and branches; attendance; charges; invoicing and payments; tutor pay; parent portal |
| **Remote / 1-to-1 centre** (for example an online agency where each student has one tutor) | The same centre account. **Nothing requires a class, a room or a branch.** One-to-one lessons are first-class, each lesson can carry an **online lesson link**, and tutor pay can be **per lesson** |
| **Parent / student** | A parent portal: invoices, payment, attendance, remarks, schedule. (Solo tutors' families are served through the tutor's invoices and WhatsApp messages.) |

### 1.2 The organisation model

Everything belongs to an **organisation**; people belong through **memberships**.

| Concept | Meaning |
|---|---|
| **Organisation (solo)** | "An organisation of one", created automatically at sign-up for every solo tutor (kind `solo`, preset `solo`). |
| **Organisation (centre)** | A tuition centre (kind `centre`). Created when a person presses "Set up a tuition centre"; that person becomes an owner. Its status goes `setup` → `active` (launched). |
| **Membership** | One person in one organisation, with a **role**, a **status** (invited / active / disabled) and, for staff, **permissions**. |
| **Roles** | **Owner**, **staff**, **tutor**, **parent**. |
| **Household** | A family. Siblings share one household and its **guardians** (name, relation, phone, email) so a phone number is edited once. This is the old "household id" sheet. |

| Role | Per centre | What they are |
|---|---|---|
| Owner | One or more (at least one always) | Everything: settings, people, billing, plan |
| Staff | Any number | Admins with a chosen list of permissions |
| Tutor | Any number | Teaches lessons; no table access; sees only their own lessons |
| Parent | Any number | Sees their own family's records through the portal |

A person can hold several memberships (a solo tutor who also teaches at a centre; an owner of one centre who is a tutor at another).

**The organisation switcher.** A person with more than one organisation sees a small name chip (top bar on desktop, top of the page on phones) to choose which one they are working in; the choice is remembered. People with one organisation never see it. A centre owner with no students of their own is not shown an empty solo organisation, so the centre is their default. The centre menu label reads "Centre" for one centre and "Centres" for more.

**Which menu a person gets** (any doubt falls back to the normal solo menu, so a solo tutor can never lose anything):

| Situation | Menu |
|---|---|
| Solo tutor | Home · Schedule · Students · Money, and More (Materials, Settings) |
| Tutor only (a centre tutor with no students of their own) | One item: **My lessons** (with a small Settings link) |
| Both (own students plus a centre tutor role) | The solo menu, with **My lessons** in More |
| Centre owner / staff | **Home · Timetable · Students · Attendance · More** (Charges is a tab inside Attendance; More holds Centre settings, People, Plan, Sign out). Staff see only the tabs they can use |
| Parent | The parent portal |

### 1.3 Centre and solo are kept apart

The owner decided that **a centre's data and a solo tutor's data never mix.**

- Each solo page reads and writes only the current solo organisation's rows.
- While the current organisation is a centre, the solo pages (Students, Ledger, Planner, Invoices, Exams) are not shown; typing their address redirects to the centre's pages (a centre tutor goes to My lessons).
- The database refuses any lesson, slot, invoice or exam whose student belongs to a different organisation, whatever the page does.

### 1.4 Plans and billing (TutorDeck's own fees)

**Solo tutors**

| Item | Rule |
|---|---|
| Free plan | Up to **5 active students** (on the roster, not discontinued, not past their end date) |
| Solo Pro | **S$14.90 a month** or **S$149 a year** |
| Free trial | **30 days**, once per organisation, **no card needed to start** |
| Existing solo tutors | **Grandfathered**: unlimited students, free ("Early tutor") |
| The 6th student | A friendly prompt ("Your free plan is full…") with a link to the plan card |
| Plan card (Settings → Your plan) | Usage meter, start trial, checkout, **card on file** (brand, last four digits, expiry; amber if expired or within 60 days), "Update card" via Stripe's customer portal, switch monthly/yearly, cancel at period end |
| Who can buy | Only the organisation's owner |
| GST | TutorDeck is **not GST-registered**; prices carry no GST |

**Tuition centres**

| Item | Rule |
|---|---|
| Monthly fee | **S$100 + S$0.40 × billable students** (the owner is keeping this price for now; a competitor review is open) |
| Billable students | Last month's **active** students rounded to the **nearest 10** (halves up). Examples: 98 → 100 → S$140; 250 → S$200; 405 → 410 → S$264 |
| Active student | A student with at least one **non-trial** lesson that month marked **attended**, **absent** or **late cancelled**; each student counts once. "Cancelled in time" and unmarked lessons do not count |
| The monthly job | Every day at 00:30 Singapore time a server job finds each active centre without a snapshot for the month, counts last month's active students, sets the quantity on the centre's Stripe subscription and records a **fee snapshot** (written last, so a failed run is retried; a second run does nothing; it refuses if Stripe already invoiced the renewal or prices differ) |
| Payment | Stripe subscription, charged to the card on file; card details live at Stripe only |
| TutorDeck never holds a centre's money | Parents pay the centre directly |

Source: `db/migration_billing.sql`, `db/migration_attendance.sql`, `api/billing.js`, `api/stripe-webhook.js`, `api/billing-cron.js`, `assets/js/money.js`, `assets/js/plan.js`, `CLAUDE.md`.

---

## 2. The roles, one by one

### 2.1 Solo tutor

*A private tutor running their own students.*

**What they see**

| Menu | Page | Purpose |
|---|---|---|
| Home | Dashboard | Greeting; **Money** card (pending, collected, projected) and **Teaching** section (Today, Tomorrow, "Needs notes", upcoming exams); first-time **Set up TutorDeck** checklist and "Get paid faster" card |
| Schedule | Calendar | Day / Week / Month; lessons coloured paid / unpaid / postponed / one-off (✦); exams; clash warnings; add a lesson in place; Google Calendar |
| Schedule | Weekly planner | The repeating week: day, time, subject(s), rate, student |
| Students | Roster | Active / Discontinued, add, edit, discontinue, remove; each student has a **profile** |
| Students | Exams | Assessments with type (WA1–3, SA1–2, CA1–2, Mid-Year, End-Year, Prelim, PSLE, N/O/A-Level, Class Test, Common Test), date, subject, marks, countdown |
| Money | Ledger | **Outstanding** (who owes you, by student) and **Records** (every lesson) |
| Money | Invoices | Saved → Sent → Paid |
| Money | Insights | Income by month, across the year, by student, by subject and level |
| More | Materials, Settings | Materials opens the MugCorner site; Settings: business, getting paid, WhatsApp messages, two-factor sign-in, your data, plan, "Run a tuition centre?", "Know another tutor?" |
| Buttons | Client view (eye), dark mode | Client view hides every amount (`$•••`) so a student can see the screen during a lesson; both are per device |

**What they can do**

- **Students:** add a student (name, level as a year, WhatsApp number, "name in messages" for the greeting, location with postal-code lookup, "lessons run until", notes, "pays by bank transfer"); **discontinue** (or set an end date; slots switch off, history stays) and **reactivate**; **remove** (deletes the student and their lessons); open the **profile** (Progress, Lessons, Notes, Schedule; totals, history, slots, exams, per-lesson notes; a copy-ready monthly schedule text).
- **Schedule:** weekly slots (several subjects each with its own G-level); **Log this week / month** generates lessons from the slots (skipping what exists); **Add lesson** for one-offs and trials; **postpone** (same lesson moves; "Revert to slot" undoes), edit, cancel, delete; clash warning for real overlapping lessons (siblings overlapping is not a clash); a holiday library of Singapore public holidays so holiday lessons are not generated.
- **Money:** lessons become **done** when their day passes and pile up under Outstanding; **Cancel lesson** with an optional **cancellation fee** (compensation); **$0 lessons** count as settled; **Record payment** in one payment window (date, optional screenshot) from the Ledger, the Invoices tab or the student page; **Invoices** with a **PayNow QR** or bank-transfer details (for overseas clients), **PDF**, **Send on WhatsApp**, a copyable covering **Message**; **WhatsApp reminders** from editable templates (placeholders `{name}` `{student}` `{business}` `{amount}` `{count}` `{month}` `{invoice}` `{paynow}` `{date}` `{year}`); **Insights**.
- **Google Calendar:** connect once, choose a calendar, **Sync now** runs on the server. One-way (TutorDeck → Google).
- **Account:** business name, PayNow ID, invoice prefix, bank details, templates; two-factor sign-in; **Download my data** (JSON); **Delete my account**; share TutorDeck with another tutor.

**Step by step: from nothing to getting paid**

1. Sign up and fill Settings (business name, PayNow, invoice prefix).
2. Add students.
3. Add each student's weekly slot(s) in the Planner.
4. Ledger → **Log this week / month**.
5. Run the week: postpone, edit or cancel as plans change; write notes after each lesson.
6. On an outstanding balance press **Invoice** → **Send on WhatsApp**, or **Remind**. When paid, **Mark paid**.
7. Add exams so the countdown shows them.

**What they can not do**
- Parents have no login in a solo tutor's practice; there is no online payment for solo tutors (the tutor marks payments by hand); no email sending from the app; Calendar sync is one-way; a free-plan tutor (not grandfathered) cannot go past 5 active students without Solo Pro.

Source: `README.md`, the solo pages (`home.html`, `ledger.html`, `calendar.html`, …) and `assets/js/*.js`, `api/gcal.js`.

---

### 2.2 Centre tutor

*A person who teaches at a centre, invited by the owner.*

**Design rule:** a centre tutor has **no access to any database table**. A lesson row also holds what parents pay, so tutors use **narrow database functions only**, each with an explicit list of fields, never rate, amount, paid or compensation. Source: `db/migration_tutor_access.sql`, `assets/js/tutor.js`, `assets/js/tutor-core.js`.

**What they see:** the **My lessons** page. Lessons are grouped **To mark** (earlier days still waiting, oldest first), **Today**, **Coming up**, **Earlier**. Each row has time, student (a group class appears as one), a chip (Mark, To mark, Attended, Absent, Cancelled, Upcoming, Ask an admin, Admin marks) and "Remarks due" (red when overdue). A lesson shows its **online lesson link** when the centre is remote. The tutor sees student names and levels; **parent contact only if the centre allows it**.

**What they can do** (every rule is a centre option in section 3)

| Action | Rule |
|---|---|
| Mark **attended** or **absent** | On their **own** lesson, from the lesson's day (the centre's time zone) up to **N days after** (default 14; 1–60), only if the centre says tutors mark attendance, never over someone else's mark |
| Mark **cancelled in time** / **late cancellation** | Only if the centre lets tutors |
| Type the **charge** for an absent/cancelled lesson | Only if the centre has tutors type it; 0 up to the lesson's own price (the tutor never sees the price); 0 = family not charged |
| **Flag a trial** | Only if the centre lets tutors |
| Write **topics, homework, remarks** | Always, on their own lessons within the window (up to 2,000 characters each); remarks can be **required** before "attended" |
| **Edit their own timetable** | Only if the centre chooses "tutors may edit their own lessons" |
| See their **pay** | Only if tutor pay is on; running earnings or closed statements, as the centre chooses |

**What marking does:** the lesson's **status follows attendance**, set by the system, never typed: attended = **done**; absent, cancelled in time, late cancelled = **cancelled**, billed at its **compensation** (a number; 0 = not charged; blank = **charge pending**). See 4.2.

**Step by step: marking a lesson**
1. Sign in; you land on My lessons.
2. Under Today, tap the lesson (chip: Mark).
3. Choose Attended or Absent (cancellation choices appear only if the centre allows them).
4. If absent/cancelled and the centre has tutors type the charge, enter the amount (0 if not charged); otherwise the sheet says an admin will decide the charge.
5. Add topics, homework, remarks.
6. Save. The chip changes.

If a lesson is locked the page says why: "You can mark a lesson from its day onward.", "That's too long ago to change here. Please ask an admin.", "Someone else already marked this lesson. Ask an admin to change it.", "At this centre an admin marks attendance. You can still add notes."

**Tutor settings** (page `/tutor-settings`, linked from My lessons; the solo Settings page is closed to tutor-only logins)

| Block | What it does |
|---|---|
| **Profile** | Display name (for one centre or all) and optional Singapore mobile (`+65` then 8 digits starting 6, 8 or 9); email read-only (it is the login); sign out |
| **Change password** | Same rules as sign-up; asks for the current password |
| **Payout details** | One method at a time: **PayNow mobile**, **PayNow UEN** or **bank account** (bank, number 7–16 digits, holder name). Shown **masked** (`•••••1234`); **Show** reveals it to the tutor only, and every reveal is logged. The centre sees a 7-day amber flag when details change |
| **Leave this centre / delete my account** | The tutor asks; the centre owner approves in one tap (**auto-approved after 7 days**); then the tutor's login, name, phone, email and current payout details are erased while lessons and attendance stay as **"Former tutor"**. A person who is also a solo tutor can leave the centre and keep their solo account |

**What they can not do:** see any price or invoice; see other tutors' lessons; mark before the day, mark a cancelled lesson, overwrite another's mark; open any solo page; open the solo Settings page.

Source: `docs/orchestrator/T24b-plan.md`, `db/migration_tutor_profile.sql`, `migration_tutor_payout.sql`.

---

### 2.3 Centre staff

*Admin people (receptionist, coordinator, accountant) invited by the owner with the permissions they need.*

#### Permissions

The owner always has everything. The menu hides what a person cannot use, and **the database refuses it anyway.**

| Permission | What it unlocks |
|---|---|
| **Manage timetable** (`manage_timetable`) | Branches, rooms, terms, holidays; weekly slots and lessons; assign tutors, cover a lesson, create group lessons; **mark** attendance and **correct** a mark (with a reason); flag trials; Home's timetable counts |
| **Manage students & families** (`manage_students`) | Students, households, guardians, exams; the Students screen; the student count on Home |
| **Manage tutors** (`manage_tutors`) | Resend a tutor's or staff member's invite; remove a tutor from the centre; approve a tutor's request to leave. (Inviting is owner-only) |
| **Issue invoices** (`issue_invoices`) | Create, approve and issue invoices and credit notes; type the **charge** for absent/cancelled lessons (the Charges queue); the pending-charge count on Home |
| **Record payments** (`record_payments`) | Record payments (manual PayNow, cash, bank transfer, cheque), match bank statements, record refunds |
| **View revenue** (`view_revenue`) | Revenue and outstanding reports |
| **Run tutor pay** (`run_tutor_pay`) | Lessons-taught reports, pay statements, adjustments, pay lists and bank files |
| **View the audit log** (`view_audit_log`) | The Audit log tab |
| **View payout details** (`view_payout_details`) | The masked list of tutors' payout details and an audited **Reveal**. Never given by default; staff without it see "provided / not provided" |

Every staff member can **read** business data of their centre; permissions decide who can **write**. Staff see parents' contact and lesson prices by design.

#### Staff screens

| Screen | What it does | Needs |
|---|---|---|
| **Home** | Today's date and centre. Tiles (counts only, **no money, no names**): lessons today / marked / still to mark; past lessons not marked (up to 60 days); lessons with no tutor in the next 14 days; charges to confirm; active students; trials this month. A tile the person may not see is **left out**, never shown as 0. A setup checklist shows while the centre is in setup | Any staff; sections by permission |
| **Timetable** | The week as a day-by-day list (phone-friendly, filters by tutor and branch), holidays as a grey band, "no tutor" lessons flagged amber. **Edit:** add, change or stop a weekly slot with its **tutor**, student(s), room and time; one-off lessons; move a lesson; **cover** a lesson with a replacement tutor; **group lessons** (several students created together); a **"Create lessons for the next 4 weeks"** button (skips holidays and ended students; running it twice changes nothing) | View: any; edit: `manage_timetable` |
| **Students** | Search and paging for 400+ students; filters Active / Ended / Trial; the student sheet with family, guardians (phone, email), level, notes, "lessons run until", next lessons, trial badge. **Add** a student with a guardian in one step (creates the household), **edit**, **discontinue / bring back**, an online lesson link for remote centres. Nothing needs a class, room or branch | View: any; change: `manage_students` |
| **Attendance** | A day or week of lessons (filters: not marked, by tutor, by student). Tap a lesson to **mark** attended / absent / late cancelled / cancelled in time, with remarks and a trial flag. **Correct** a mark: needs a **written reason**, recorded in the audit log. Staff can **always** mark and correct whatever `attendance_by` says; the window applies to tutors only | Look: any; mark/correct: `manage_timetable` |
| **Charges** (tab in Attendance) | The queue of absent/cancelled lessons whose **charge is pending**: student, date, the lesson's full price, a **suggested** charge, buttons **Not charged (0)** / **Full price**, and bulk "Not charged". Saving sets the compensation (0 to the lesson's own price); changing a typed charge needs a reason; a paid lesson's charge is locked | `issue_invoices` |
| **Invoices and payments** | Invoice runs, drafts to approve, credit notes, payment recording (see 4.9–4.10) | `issue_invoices`, `record_payments` |
| **Reports** | Revenue, outstanding, lessons taught per tutor, pay statements | `view_revenue`, `run_tutor_pay` |
| **People** (More) | See who is in the centre; resend invites; payout list | `manage_tutors`, `view_payout_details` |
| **Centre settings** (More) | Read-only for staff; only owners change them | — |

**Integrity rules enforced by the database for everyone:** no attendance before the lesson's day; no overwriting another person's mark except through **Correct** with a reason; the "marked by / marked at" fields cannot be edited directly.

**What staff can not do:** change settings or people; mark without `manage_timetable`, type charges without `issue_invoices`, edit students without `manage_students`; see another centre or any solo organisation.

---

### 2.4 Centre admin / owner

*The person who created the centre. A centre can have several owners.*

**Where they work:** the centre's pages. Before launch, the Centre page is the 10-step **setup wizard**; after launch the same steps are **Settings** tabs, plus **Plan** and **Audit log**.

**Create and launch**
1. Settings → **Run a tuition centre?** → **Set up a tuition centre**, type the name, **Create and start setup**. You become the owner; TutorDeck's centre plan (S$100 + S$0.40 per billable student) is attached.
2. Walk the 10 steps (every step has sensible defaults): 1 Organisation profile · 2 Branches, rooms and calendar · 3 Users and permissions · 4 How lessons are billed · 5 Invoicing · 6 How parents pay · 7 Tutors and lessons · 8 Tutor pay · 9 Import data · 10 Review and launch. All options: section 3.
3. Steps 4–5 show a **sample invoice** (a family of two children, four S$40 lessons each) and step 8 a **sample pay statement** so you see the effect of your choices.
4. Step 10 shows a summary with Edit links and **Launch**; the settings go live today.

**Settings after launch:** settings are **versioned and effective-dated** (each save is a new row; they cannot be back-dated). **Billing, invoicing, payments and tutor-pay** changes apply **from the 1st of next month**; everything else applies **today**. Issued invoices are never rewritten. Only owners save settings.

**People (step 3):**
- **Invite** staff or a tutor: email, name, role; for staff tick permissions; for a tutor choose **employee** or **freelancer**. The person starts **invited** and is linked when they sign in with that email. TutorDeck **emails the invite** with a one-time set-password link (valid 24 hours).
- **Resend invite** for invites not accepted in time (owner, or staff with Manage tutors). Limits: 1 email per invite per 10 minutes, 5 per invite per 24 hours, 30 per centre per hour. The list shows when each was invited and last emailed.
- **Change permissions** with ticks; **turn off** a person's access (they keep their history; an organisation always keeps one active owner); **remove a tutor** from the centre; **approve a tutor's request to leave**.
- **Payout list:** each tutor's payout method, masked value and "changed on" flag; **Reveal** is audited. Needs `view_payout_details` (owner always).

**Branches, rooms, terms and holidays (step 2):** optional. Branches (name, address), rooms inside a branch (name, capacity), terms and holidays (name, start, end). A **Singapore public holiday library** (2026–2027, from the Ministry of Manpower list) lets the owner tick which holidays to add; nothing is ever applied automatically; Monday "substitute" days are separate unticked rows. With "skip holidays" on, no lessons are generated on those days.

**Plan tab (owner only):** the fee formula, worked examples and the last six monthly fee snapshots (active → billable → fee).
**Audit log tab (owner, or staff with `view_audit_log`):** the latest changes (settings, people, students, lessons, invoices): who and when; it cannot be edited or deleted. Support access granted to TutorDeck appears here.

**Other owner abilities:** grant and revoke time-limited **support access** to TutorDeck; import data from CSV (step 9: templates for tutors, students with level, subjects, class and fee plan, parents and households); upload a logo; transfer ownership; close the centre (a plain-words route with a data export first).

Source: `org.html`, `assets/js/org.js`, `assets/js/org-settings.js`, `docs/orchestrator/T7-plan.md`, `T18-plan.md`.

---

### 2.5 Parent / student

**Parents of a centre** log in to the **parent portal** (role `parent`, one login per guardian, covering every child in the household).

| Area | What the parent sees and does |
|---|---|
| **Home** | Each child, next lessons (with the online link for remote lessons), a "what needs your attention" list |
| **Attendance and remarks** | Attendance per lesson. **Remarks** appear only if the centre chose to send them (automatically, or after admin approval) |
| **Invoices** | Every invoice with status; open an invoice (tax invoice if the centre is GST registered); credit notes |
| **Pay** | PayNow QR with the invoice number as reference; or a "Pay now" link when the centre uses HitPay or Stripe; partial payments only if the centre allows them |
| **Credits** | Make-up credits earned, used and their expiry; low-balance warning for prepaid packages |
| **Emails** | Secure invoice link, payment reminders (on the centre's schedule), remarks |
| **Contact** | Update their own phone and email |

**Solo tutors' families** are served by the tutor: an **invoice** (PayNow QR or bank details) sent by WhatsApp or PDF, **WhatsApp reminders**, and a copy-ready monthly schedule. **Client view** is not a parent login: it is a button the tutor presses to hide money while a student looks at the tutor's screen.

**Parents can not:** see another family; see a tutor's pay or other children; change a lesson's price; see remarks unless the centre sends them.

---

### 2.6 Platform admin

TutorDeck's own team (Raphael and T-Leng).

| Capability | Detail |
|---|---|
| **Platform admin role** | A login on the platform-admin list |
| **Organisations console** | Per organisation: name, kind, status, plan, base and per-student fee, last month, active and billable students, fee. **Never student records** |
| **Support access** | A centre owner grants time-limited, revocable read access (with a reason); only with a live grant can a platform admin read that centre's business data; every grant is audit-logged |
| **Billing** | Subscriptions, webhooks, customer portal and monthly fee job health, in Stripe and the console |
| **Error log** | Crash and failed-request reports from signed-in tutors' browsers (at most 5 per page load, kept 90 days) |
| **Backups** | Nightly encrypted database dumps kept 30 days; restore steps in README → Backups |
| **Support mailbox** | A real support address that can receive mail |

---

### 2.7 Accounts: sign-up, invites, log-in, password, deletion

| Topic | How it works |
|---|---|
| **Solo sign-up** | Create account with email + password, or **Continue with Google**. Password: **8+ characters, a lowercase letter, an uppercase letter, a number and a symbol** (a checklist ticks green as each is met). Consent is required; a bot check runs on the real domain. A new account gets a solo organisation, a free-plan record and the "Set up TutorDeck" checklist |
| **Email** | Confirmation, reset and magic-link emails come from `noreply@tutordeck.com.sg` through Brevo, with TutorDeck's own templates; reply-to is a TutorDeck address |
| **Centre owner** | Signs up like anyone, then "Set up a tuition centre" |
| **Invite (tutor/staff)** | The owner invites by email; TutorDeck emails a welcome link to `/reset?welcome=1` ("Welcome to TutorDeck") where the person sets a password using the sign-up rules. Signing in with that email claims the invite (checked at most every 30 minutes per login). Preview/staging sites only email `@tutordeck.com.sg` addresses and an allow-list |
| **Parent invite** | A guardian is invited from the household by email or phone; same welcome page |
| **Log in** | Email + password or Google; tutor-only lands on My lessons, owner/staff on the centre, solo on Home, parents on the portal |
| **Two-factor** | Optional six-digit code; offered to every role |
| **Forgot password** | "Forgot password?" emails a reset link; the reset page enforces the same password rules |
| **Delete — solo** | Settings → Your data → Delete my account, type `DELETE`. The server cancels the Stripe subscription and deletes the Stripe customer, deletes stored files, revokes the Google link, then removes the organisation and **everything** of theirs in one transaction (audit trail included), then the login. If a step fails nothing later runs and pressing Delete again continues; a subscription that cannot be cancelled blocks deletion |
| **Delete — centre tutor / parent** | Tutor: see 2.2 (request, approval, erase, "Former tutor"). Parent: a request to the centre; their login is erased and the family's records stay with the centre |
| **Centre owner / staff** | Staff leave by the owner turning them off or removing them; owners transfer ownership first; closing a centre is a separate owner flow |
| **Download my data** | JSON of the account |

Source: `login.html`, `reset.html`, `assets/js/password-rules.js`, `api/delete-account.js`, `api/send-invite.js`, `db/migration_org_delete.sql`.

---
## 3. Centre options reference

Every choice a centre makes in the setup wizard (and later in Settings), with every allowed value and what it does. The tables are **generated from `assets/js/org-settings.js`** by `docs/product/build-options.js`, so no setting can be missing (`node docs/product/build-options.js --check` proves it).

- **Setting** = the label the owner sees, then the technical name.
- **Allowed values**: for a choice, the stored value in `code` then its label. Money is in **cents**; rates in **basis points** (100 = 1%).
- **Default (centre)** is what a new centre starts with. The `solo` preset differs only where listed at the end.
- **What the database checks on every save:** settings version 1; all eight sections present; GST rate 0–50% when GST registered; the billing model, tutor-pay mode, payable-when, invoice grouping, attendance-by, cancellations-by, charge-by and trial-by values are from their lists; attendance window 1–60 days; at least one way to pay. The page also requires a trading name, a GST number when registered, a `#RRGGBB` brand colour, a valid reply-to email, an invoice prefix of 1–8 letters/numbers/hyphens, a next invoice number ≥ 1, an **invoice day of 1–28**, pay days 1–31 and a sibling discount of at most 100%.
- **Step 2** also holds data the owner edits on the same tab: **branches**, **rooms** (name, capacity), **terms**, **holidays** and the **Singapore public holiday library**. **Step 3** is the people list (2.4) and the permission catalogue (2.3).
- **When a change applies:** billing, invoicing, payments and tutor-pay changes from the **1st of next month**; everything else **today**; in setup mode at once. Process rules are read as of today; money rules follow the settings in force **when the lesson happened**.
- Choices that depend on features arriving later behave as described here when the feature is available; Appendix A lists which are available now.

<!-- OPTIONS:START (generated by docs/product/build-options.js; edit the notes in that script, not here) -->

#### Step 1 — Organisation profile

| Setting (`path`) | What it does | Allowed values | Default (centre) |
|---|---|---|---|
| Legal name (`profile.legal_name`) | The registered company name; printed on invoices and credit notes. | any text | (empty) |
| Trading name (`profile.trading_name`) | The name families know; the centre's display name in menus, the switcher, invite emails and invoices. **Required.** | any text | (empty) |
| UEN (`profile.uen`) | Singapore business registration number; printed on invoices. | any text | (empty) |
| Address (`profile.address`) | Business address; printed on invoices. | any text | (empty) |
| Logo (`profile.logo_path`) | Logo shown on invoices and the parents' pages. Upload arrives with branded invoices. | any text | `null` |
| Brand colour (invoices and your pages) (`profile.brand_color`) | Colour bar and accents on invoices and the centre's parent pages. Format `#RRGGBB`. | `#RRGGBB` | `#0F766E` |
| GST registered (`profile.gst_registered`) | Whether the centre charges GST. When on, invoices are titled 'Tax invoice' and GST is worked out **once per invoice** on the total, rounded half up. | Yes / No | No |
| GST registration number (`profile.gst_number`) | GST registration number, printed on tax invoices. Required when GST registered. | any text | (empty) |
| GST rate (`profile.gst_rate_bp`) | GST rate in basis points (900 = 9%). Allowed 0–50%. Shown only when GST registered. | whole basis points ≥ 0 (100 = 1%) | `900` |
| Prices are entered (`profile.gst_inclusive`) | Whether the fees the centre types already include GST (the invoice then shows 'Includes GST') or GST is added on top. | `false` Excluding GST<br>`true` Including GST | `false` |
| Timezone (`profile.timezone`) | The centre's time zone: decides what 'today' is, when a lesson's day starts, attendance windows and remark deadlines. Singapore is the only choice. | `Asia/Singapore` Singapore (GMT+8) | `Asia/Singapore` |
| Currency (`profile.currency`) | Currency of every fee and invoice. SGD is the only choice. | `SGD` SGD | `SGD` |
| Invoice number prefix (`profile.invoice_prefix`) | Letters at the start of invoice numbers (1–8 letters, numbers or hyphens), e.g. INV-00001. | any text | `INV` |
| Next invoice number (`profile.next_invoice_number`) | The number the next invoice gets (whole number ≥ 1). Numbers are never reused. | whole number ≥ 0 | `1` |
| Reply-to email for parent emails (`profile.reply_to_email`) | Where a parent's reply to a TutorDeck email about this centre goes. | an email address | (empty) |

#### Step 2 — Branches, rooms and calendar

| Setting (`path`) | What it does | Allowed values | Default (centre) |
|---|---|---|---|
| Don't generate lessons on centre holidays (`calendar.skip_holidays`) | When on, lessons are **not generated** on the centre's holidays and the timetable shows a grey holiday band. Lessons already generated on a day later marked as a holiday are never deleted automatically: the admin gets a list and a one-tap 'Cancel with no charge'. (A second choice, 'generate and flag', is planned.) | Yes / No | Yes |

#### Step 3 — Users and permissions

People are invited here, not saved as settings. See 2.4: invite, permissions, switch off. The permission catalogue (`manage_timetable`, `manage_students`, `manage_tutors`, `issue_invoices`, `record_payments`, `view_revenue`, `run_tutor_pay`, `view_audit_log`) is in 2.3.

#### Step 4 — How lessons are billed

| Setting (`path`) | What it does | Allowed values | Default (centre) |
|---|---|---|---|
| Default billing model (`billing.model`) | How the centre bills by default. **Prepaid packages:** parents buy lessons in advance and each taught lesson uses one. **Fixed fee in advance:** a flat fee per month or term, invoiced before it starts. **Postpaid:** after each month, for lessons held. **Pay per lesson:** an invoice per lesson or week. Individual fee plans can override it. | `prepaid_packages` Prepaid packages<br>`fixed_in_advance` Fixed fee in advance<br>`postpaid_lessons` Postpaid<br>`pay_per_lesson` Pay per lesson | `postpaid_lessons` |
| Fixed fee period (`billing.fixed_period`) | For 'fixed fee in advance': one fee per month or per term. | `month` Per month<br>`term` Per term | `month` |
| Invoice (`billing.pay_per_lesson_grouping`) | For 'pay per lesson': one invoice for every lesson or one per week. | `lesson` Every lesson<br>`week` Every week | `lesson` |
| Warn parents when credits fall to (`billing.low_balance_credits`) | For prepaid packages: when a family's remaining credits fall to this number, the parent is warned (portal and email). | whole number ≥ 0 | `2` |
| Credits expire after (days, 0 = never) (`billing.credit_expiry_days`) | For prepaid packages: credits expire after this many days; 0 = never (the default). | whole number ≥ 0 (days) | `0` |
| Fee plans (per lesson / month / term, by level, subject, class type or duration) (`billing.fee_plans_note`) | Fee plans (per lesson, month or term; by level, subject, class type or duration) are set up with the centre's classes. | (a note, nothing to choose) | — |
| Absent lessons (`billing.absences.mode`) | Whether an absent lesson is charged. **Charged:** the full lesson price is suggested. **Not charged:** 0 is suggested. **Charged unless notice:** 0 is suggested for 'cancelled in time', the full price otherwise. It only **pre-fills the suggested charge**; a person with the right permission always confirms it. Read as of the lesson's own day. | `charged` Charged<br>`not_charged` Not charged<br>`charged_unless_notice` Charged unless notice was given | `charged_unless_notice` |
| Notice needed (hours before) (`billing.absences.notice_hours`) | For 'charged unless notice': how many hours before the lesson counts as enough notice. The person marking the lesson chooses 'cancelled in time' or 'late cancelled'. | whole number ≥ 0 | `24` |
| Makeup lessons allowed (`billing.makeups.allowed`) | Whether make-up lessons are offered. When on, a missed lesson that is not charged earns the family one make-up credit. | Yes / No | Yes |
| Makeups per period (`billing.makeups.per_period`) | A cap on make-ups a family may take per period. | whole number ≥ 0 | `2` |
| A makeup uses a credit (`billing.makeups.uses_credit`) | Planned to become the 'credit rule'. The rule the owner decided: **one missed lesson = one credit; the make-up uses that same credit and is never charged twice.** Credits are earned for absences with notice, tutor cancellations and holidays, and never expire by default. | Yes / No | No |
| Joining or leaving mid-period (`billing.proration`) | A student who joins or leaves mid-period: charge **by remaining lessons**, charge the **full period**, or **skip** the partial period. | `by_remaining` Prorate by remaining lessons<br>`full` Charge the full period<br>`skip` Skip the partial period | `by_remaining` |
| Sibling discount (2nd child onwards) (`billing.sibling_discount.type`) | Discount for the second child onwards in a household: none, a percentage, or a fixed amount per lesson. | `none` None<br>`percent` Percentage<br>`fixed` Fixed amount per lesson | `none` |
| Discount (`billing.sibling_discount.percent_bp`) | The percentage, in basis points (1000 = 10%); not over 100%. Shown only for 'percentage'. | whole basis points ≥ 0 (100 = 1%) | `1000` |
| Discount (`billing.sibling_discount.fixed_cents`) | The fixed discount per lesson, in cents (500 = S$5.00). Shown only for 'fixed'. | whole cents ≥ 0 | `500` |
| Allow one-off discounts (with a reason) (`billing.adhoc_discounts`) | Whether an admin may give a one-off discount on an invoice line (a reason is required and recorded). | Yes / No | Yes |
| Registration fee (`billing.one_off_fees.registration_cents`) | Registration fee added to a new student's first invoice, in cents. | whole cents ≥ 0 | `0` |
| Deposit (`billing.one_off_fees.deposit_cents`) | Deposit added to a new student's first invoice, in cents. | whole cents ≥ 0 | `0` |
| Materials fee (`billing.one_off_fees.materials_cents`) | Materials fee added to a new student's first invoice, in cents. | whole cents ≥ 0 | `0` |
| Late fee (`billing.late_fee.enabled`) | Whether an overdue invoice gets a late fee. | Yes / No | No |
| Late fee amount (`billing.late_fee.amount_cents`) | The late fee, in cents (1000 = S$10.00). Shown only when late fees are on. | whole cents ≥ 0 | `1000` |
| After overdue (days) (`billing.late_fee.after_days`) | How many days overdue before the late fee is added. Shown only when late fees are on. | whole number ≥ 0 (days) | `7` |

#### Step 5 — Invoicing

| Setting (`path`) | What it does | Allowed values | Default (centre) |
|---|---|---|---|
| One invoice per (`invoicing.grouping`) | One invoice per **family** (household, all siblings together) or per **student**. | `family` Family (household)<br>`student` Student | `family` |
| Create invoices (`invoicing.generate.mode`) | When invoices are created: on a fixed day of the month, or a number of days before each period. | `day_of_month` On a day of the month<br>`days_before` Some days before each period | `day_of_month` |
| Day of month (`invoicing.generate.day`) | The day of the month (1–28, so it exists in every month). Shown only for 'on a day of the month'. | whole number ≥ 0 | `1` |
| Days before the period (`invoicing.generate.days_before`) | Days before the period starts. Shown only for 'some days before'. | whole number ≥ 0 (days) | `7` |
| Payment due (days after the invoice date) (`invoicing.due_days`) | Payment is due this many days after the invoice date. | whole number ≥ 0 (days) | `7` |
| Create as drafts for an admin to approve (`invoicing.review_before_sending`) | On: invoices are created as **drafts** and an admin approves them before families see them. Off: they go out when created. Once issued an invoice is never edited; corrections are credit notes. | Yes / No | Yes |
| Email parents a secure link (`invoicing.delivery.email`) | Email the parent a secure link to the invoice. | Yes / No | No |
| Shareable link for WhatsApp (`invoicing.delivery.share_link`) | Give the admin a shareable link to the invoice to send on WhatsApp. | Yes / No | Yes |
| Payment reminders (`invoicing.reminders.enabled`) | Send automatic payment reminders. | Yes / No | No |
| Remind (days from due date, e.g. -3, 0, 7) (`invoicing.reminders.schedule`) | When to remind, in days from the due date, e.g. -3, 0, 7 (three days before, on the day, a week after). Shown only when reminders are on. | numbers separated by commas | -3, 0, 7 |

#### Step 6 — How parents pay

| Setting (`path`) | What it does | Allowed values | Default (centre) |
|---|---|---|---|
| Ways to pay (`payments.modes`) | How parents can pay (at least one). **Manual PayNow:** the parent pays by PayNow with the invoice number as reference and an admin records it. **Bank statement matching:** an uploaded statement is matched to invoices automatically. **HitPay / Stripe:** a 'Pay now' link on the centre's own gateway account. Money always goes straight to the centre. Cash, bank transfer and cheque can always be recorded by hand. | `manual_paynow` Manual PayNow<br>`statement_matching` Bank statement matching<br>`hitpay` HitPay<br>`stripe` Stripe | manual_paynow |
| PayNow to (`payments.paynow.type`) | PayNow to a UEN or to a mobile number. | `uen` UEN<br>`mobile` Mobile number | `uen` |
| PayNow UEN or number (`payments.paynow.id`) | The PayNow UEN or number shown on the invoice's QR code. | any text | (empty) |
| Bank for statement matching (`payments.statement_bank`) | Which bank's statement format is read for matching, or custom CSV columns. | `DBS` DBS<br>`OCBC` OCBC<br>`UOB` UOB<br>`custom` Custom CSV columns | `DBS` |
| HitPay: PayNow (`payments.hitpay.paynow`) | On the HitPay link, offer PayNow. | Yes / No | Yes |
| HitPay: cards (higher fees) (`payments.hitpay.cards`) | On the HitPay link, offer cards (higher fees). | Yes / No | No |
| Gateway fees (`payments.gateway_fees`) | Who bears gateway fees: the centre, or passed on as a separate invoice line. | `absorb` Absorbed by the centre<br>`pass_on` Passed on as a separate line | `absorb` |
| Allow partial payments (`payments.partial_payments`) | Whether a family may pay an invoice in parts. | Yes / No | Yes |
| Overpayments (`payments.overpayments`) | An overpayment is kept as credit for the family or refunded manually. | `credit` Kept as credit for the family<br>`refund` Refunded manually | `credit` |

#### Step 7 — Tutors and lessons

| Setting (`path`) | What it does | Allowed values | Default (centre) |
|---|---|---|---|
| Who edits the timetable (`lessons.timetable_editing`) | Who edits the timetable. **Admins only:** staff with the timetable permission. **Tutors may change their own lessons:** a tutor can move, put back or cancel (if switched on) their own lessons for students assigned to them, within the notice and limits below; never a lesson that is marked, paid or invoiced, never in the past, and a tutor never sees a price. Staff see an amber 'changed by tutor' flag for 7 days and a Tutor changes list on Home. **Tutors ask, an admin approves:** coming soon. | `admin_only` Admins only<br>`tutors_direct` Tutors may change their own lessons (staff are told)<br>`tutors_propose` Tutors ask, and an admin approves (coming soon) | `admin_only` |
| A tutor may move a lesson (and put it back) (`lessons.tutors_edit.postpone`) | Only with 'Tutors may change their own lessons'. A tutor may move a lesson to another day or start time (the length, and so the price, stays the same) and put it back to its usual slot. The lesson is marked moved, like the solo Calendar's postpone. | Yes / No | Yes |
| A tutor may cancel a lesson in advance, at no charge to the family (`lessons.tutors_edit.cancel`) | Only with 'Tutors may change their own lessons'. A tutor may cancel a lesson in advance. It is cancelled at no charge to the family (charge 0); no make-up credit is created by the tutor, staff decide that. | Yes / No | No |
| A tutor may add, change or stop their own weekly slots (`lessons.tutors_edit.weekly_slots`) | Coming soon: a tutor adds, changes or stops their own weekly slots. | Yes / No (coming soon) | No |
| A tutor may create their own lessons from their weekly slots (`lessons.tutors_edit.generate`) | Coming soon: a tutor creates their own lessons from their own weekly slots. | Yes / No (coming soon) | No |
| A tutor may add a one-off lesson (`lessons.tutors_edit.one_off`) | Coming soon: a tutor adds a one-off lesson for a student assigned to them. | Yes / No (coming soon) | No |
| A tutor may set the online lesson link (`lessons.tutors_edit.link`) | Coming soon: a tutor sets the online lesson link. | Yes / No (coming soon) | No |
| A tutor can change a lesson only if it starts in at least (hours, 0-168) (`lessons.min_notice_hours`) | How many hours before a lesson starts a tutor can still move or cancel it (0–168, default 24). Closer than that, only an admin can. Uses the centre's own clock. | Whole number 0–168 | 24 |
| Most changes one tutor can make in a month (0 = no limit) (`lessons.max_changes_per_month`) | Most schedule changes one tutor can make in a calendar month of the centre (0 = no limit, the default). A move, a put-back and a cancel each count as one. | Whole number 0–500 | 0 |
| When a tutor changes a lesson (`lessons.notify_family`) | What staff are shown when a tutor changes a lesson. **List:** the Tutor changes list on Home says the family needs telling. **Off:** the change is still listed, with nothing for staff to do. TutorDeck does not email the family yet. | `list_for_admin` Show staff a list, so they can tell the family<br>`off` Don't add anything for staff to do | `list_for_admin` |
| Attendance is marked by (`lessons.attendance_by`) | Who marks attendance. **Tutor:** tutors mark; staff can still mark and correct as the safety net. **Admin:** tutors can write remarks but cannot set attendance. Staff are never blocked by this setting. | `tutor` The tutor<br>`admin` An admin | `tutor` |
| Tutors can mark or change attendance for (days after the lesson) (`lessons.attendance_window_days`) | How many days after the lesson a **tutor** may still mark or change attendance (whole number 1–60), counted from the lesson's day. After that only an admin can. Staff are not limited. | whole number ≥ 0 | `14` |
| Cancellations (in time or late) are marked by (`lessons.cancellations_marked_by`) | Who may mark 'cancelled in time' and 'late cancellation'. Governs tutors only; staff can always set both. Whether a cancellation is late is the centre's own policy, so most centres let an admin decide. | `admin` An admin<br>`tutor` The tutor | `admin` |
| For an absent or cancelled lesson, the charge (compensation) is entered by (`lessons.compensation_entered_by`) | Who types the charge (compensation) for an absent or cancelled lesson. **Admin:** every absent/cancelled lesson waits in the Charges queue. **Tutor:** the tutor must type it when marking (0 if not charged), never above the lesson's price, and staff can still override with a reason. | `admin` An admin<br>`tutor` The tutor | `admin` |
| Trial lessons are flagged by (`lessons.trials_flagged_by`) | Who flags a lesson as a trial. A trial lesson does not count as an active student for TutorDeck's fee. Governs tutors only; staff can always flag. | `admin` An admin<br>`tutor` The tutor | `admin` |
| Lesson remarks are required (`lessons.remarks.required`) | Remarks must be written before a lesson can be marked attended. Correcting an old mark does not re-require them. | Yes / No | No |
| Remarks due within (hours after the lesson) (`lessons.remarks.deadline_hours`) | Hours after the lesson that remarks are due; the tutor's page shows 'Remarks due' and turns red when overdue. | whole number ≥ 0 | `24` |
| Who sees remarks (`lessons.remarks.visibility`) | Who sees remarks. **Admins only.** **Sent to parents automatically:** each remark appears in the parent's portal and email. **Sent after admin approval:** an admin reviews it first. | `admin_only` Admins only<br>`parents_auto` Sent to parents automatically<br>`parents_after_approval` Sent to parents after admin approval | `admin_only` |
| Remind tutors about missing remarks (`lessons.missed_remarks_reminders`) | Email tutors who have not written remarks by the deadline. Until emails exist the tutor's page shows what is overdue. | Yes / No | Yes |
| Admins can give one lesson to a replacement tutor (`lessons.replacement_tutors`) | On: an admin may change one lesson's tutor to another active tutor of the centre ('Cover by…'). Off: only a lesson with no tutor can be given one. Enforced by the database. | Yes / No | Yes |
| Tutors can see parents' contact details (`lessons.tutors_see_parent_contact`) | Whether tutors see parents' phone and email. Off by default. Tutors always see student names and levels. | Yes / No | No |

#### Step 8 — Tutor pay

| Setting (`path`) | What it does | Allowed values | Default (centre) |
|---|---|---|---|
| Tutor pay (`tutor_pay.mode`) | How tutor pay is handled. **Off.** **Lessons-taught report only:** a report of lessons per tutor and month. **Full pay calculation:** pay statements with rates, adjustments and pay days. | `off` Off<br>`report` Lessons-taught report only<br>`full` Full pay calculation | `report` |
| Pay tutors for a lesson (`tutor_pay.payable_when`) | When a taught lesson becomes payable. **Only after the parent's payment is received and reconciled** (default; unpaid lessons roll into the next period and show as pending), or **as soon as it is taught**. Changing it later is recorded in the audit log. | `parent_paid` Only after the parent's payment is received and reconciled<br>`taught` As soon as it is taught | `parent_paid` |
| Pay rate (`tutor_pay.rate_model`) | How a tutor's pay is worked out: per lesson, per hour, per student per lesson, or a fixed monthly amount. | `per_lesson` Per lesson<br>`per_hour` Per hour<br>`per_student_lesson` Per student per lesson<br>`monthly_fixed` Fixed monthly amount | `per_hour` |
| Bonuses and deductions (with a reason) (`tutor_pay.adjustments`) | Whether admins can add bonuses and deductions to a pay statement (a reason is required). Shown only for full pay. | Yes / No | Yes |
| Pay period ends on day (`tutor_pay.cycle.cutoff_day`) | The pay period ends on this day of the month (1–31). | whole number ≥ 0 | `31` |
| Pay day (`tutor_pay.cycle.pay_day`) | The day tutors are paid (1–31). Shown only for full pay. | whole number ≥ 0 | `7` |
| Paying tutors (`tutor_pay.payout_method`) | How tutors are paid: a list for manual transfers (using each tutor's own payout details), or a bulk payment file for the centre's bank. | `manual_list` A list for manual transfers<br>`bank_file` Bulk payment file for your bank | `manual_list` |
| Tutors see (`tutor_pay.tutor_visibility`) | What tutors see of their pay: running earnings during the month, or only closed pay statements. | `running` Running earnings during the month<br>`closed_only` Only closed pay statements | `closed_only` |
| (note) (`tutor_pay.employment_note`) | A reminder that each tutor is an employee or a freelancer (set when invited); employees may need itemised payslips and CPF. The centre confirms its obligations with its accountant. | (a note, nothing to choose) | — |

#### Step 9 — Import data

CSV import: templates for tutors, students (level, subjects, class, fee plan), parents and households. Nothing to choose; the owner uploads files.

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

**Lesson-rule defaults** (owner, 2026-11-24): attendance marked by the **tutor**; window **14 days**; cancellations marked by an **admin**; the charge typed by an **admin**; trials flagged by an **admin**; remarks **not** required; tutors do **not** see parent contact.

Source: `assets/js/org-settings.js`, `db/migration_org_foundation.sql` (`org_validate_settings`), `db/migration_tutor_access.sql`, `tests/org-settings.test.js`.

---

## 4. Key workflows end to end

### 4.1 A lesson's life

**Solo tutor**

| Step | Who | What happens |
|---|---|---|
| 1 | Tutor | A **weekly slot** (student, day, time, subject(s), rate) is only a template; it projects "not logged" blocks on the Calendar |
| 2 | Tutor | **Log this week / month** creates real **lessons** from the slots (skipping what exists); **+ Add lesson** for one-offs (✦). Status **scheduled** |
| 3 | System | When the day passes the lesson becomes **done** |
| 4 | Tutor | Notes: topics, homework, plan |
| 5 | System | A done, unpaid lesson appears under **Outstanding** |
| 6 | Tutor, parent | Invoice and payment (4.9, 4.10) |

The lessons table is the ground truth: Ledger, Calendar, profile, invoices and the monthly schedule all read it.

**Centre**

| Step | Who | What happens |
|---|---|---|
| 1 | Staff | A **weekly slot with a tutor** (and room, online link if remote) is added in the Timetable |
| 2 | System / staff | **Create lessons for the next 4 weeks** generates lessons carrying the tutor and, for groups, a shared session id; it skips holidays (if the centre chose) and ended students; running it twice changes nothing |
| 3 | Tutor or staff | **Attendance** is marked from the lesson's day, never before. Tutor: within the centre's window. Staff: any day, and can correct with a reason |
| 4 | System | **Status follows attendance**: attended = done; absent, cancelled in time, late cancelled = cancelled |
| 5 | Admin or tutor | The absent/cancelled lesson's **compensation** is typed (0 = not charged); blank = pending |
| 6 | Staff | **Invoice run**; a cancelled lesson with a blank charge blocks its invoice |
| 7 | Staff | Payment recorded; tutor pay follows |
| 8 | System | TutorDeck's monthly fee counts active students (4.15) |

### 4.2 Absent and cancelled lessons: the charge (compensation)

- An **absent** or **cancelled** lesson gets status `cancelled`; what the family owes is its **compensation**, a number someone types: **0** = not charged; a positive number = charged that much (never above the lesson's price at a centre); **blank = "charge pending"**, an admin must type it and **invoicing waits**. **Attended = done**, billed at the lesson's amount.
- Solo tutors: **Cancel lesson** offers an optional **cancellation fee**; without it the lesson earns nothing. Setting attendance never changes a solo lesson's status.
- Centres: who types the charge is `lessons.compensation_entered_by` (admin default, or tutor). The staff **Charges** queue suggests a value from `billing.absences.mode`, and a person always confirms. Changing a typed charge needs a reason; a paid lesson's charge is locked; every change is audited.

### 4.3 Postponing and make-ups

- **Postpone:** the same lesson moves to a new date/time and is flagged *postponed*; its original slot date is kept so no phantom block appears; "Revert to slot" undoes it. It is **one lesson, billed once**; no credit is used.
- **Make-up credits (centre setting):** **one missed lesson owed = one credit; the make-up fulfils that same credit and is never charged twice.** A credit is earned when a lesson is not charged: an absence with notice, a tutor cancellation, a holiday. **Credits never expire by default** (the centre may set an expiry). A cap on make-ups per period is optional. A planned `billing.makeups.credit_rule` offers `none` (make-ups are ordinary extra lessons), `one_per_missed` (the default above) and `charged_missed_free_makeup` (the missed lesson stays charged; the make-up is free). The family sees the credit in the portal ("Using 1 credit from the lesson missed on {date}"). Credits are recorded in a table of their own, created by the same step that marks the lesson not charged.
- **Solo tutors** keep postpone-moves-the-lesson and add a make-up as a normal one-off lesson.

### 4.4 Trials

A lesson can be flagged **trial**. A trial **does not count** as an active student for TutorDeck's fee. The centre chooses who may flag (`trials_flagged_by`); staff always can. The Students list shows a **Trial** badge (a trial lesson in the last 30 days) and filters by it. Changing a flag after that month's fee snapshot exists does not change the snapshot; the screen says so. For solo tutors a trial is simply a lesson, often $0, which counts as settled.

### 4.5 Group lessons

A group lesson is **one lesson row per student sharing a session id**. Staff create a group from the Timetable ("Group lesson": several students at once). The tutor sees it as one class; staff mark each student separately. Solo: each student's lesson is its own row; siblings overlapping in time is not a clash. A fuller **classes** record (rosters, fee plans) can come with invoicing if centres need it. Nothing requires a class, room or branch.

### 4.6 Holidays

The centre ticks Singapore public holidays from the library (never automatic) and adds its own. With **skip holidays** on (default), lessons are not generated on holiday days and the timetable shows a grey band. A planned second choice, `generate_and_flag`, still generates the lesson but marks it for an admin. Lessons already on a newly added holiday are never deleted; the wizard lists them ("3 lessons already fall on this day") with a one-tap "Cancel with no charge". Whether a holiday earns a make-up credit follows 4.3. Solo tutors can use the same library from Settings and tick the holidays they observe. Dates come from the Ministry of Manpower list; **2027 is re-checked before shipping and next year's rows are added each November.**

### 4.7 Replacing a tutor

A lesson's tutor can be changed by an admin ("Cover by…") to any **active tutor of the same centre**. The centre option `replacement_tutors` (default on) decides whether an existing tutor can be replaced; if off, only a lesson with no tutor can be given one. The covering tutor sees the lesson; the original no longer does. Removing a tutor from the centre leaves their past lessons shown as **"Former tutor"**.

### 4.8 Discontinuing a student

Set **Lessons run until** (inclusive) or press **Discontinue**. After that date no lessons are generated, the student is hidden in pickers and the Planner/Timetable, their weekly slots are switched off, and history stays. **Reactivate / bring back** switches the slots on again. Solo free-plan tutors count active students, so a reactivation can hit the 5-student limit.

### 4.9 Invoicing and PayNow

**Solo:** Ledger → Outstanding → pick a student or tick lessons → **Invoice**. It shows student, subject (from the billed lessons) and level (from the profile), lines, total and a **PayNow QR** (or bank details for a student flagged "pays by bank transfer"; a household uses bank if any member is flagged). **Send on WhatsApp** (image attached; marks it sent), **PDF** download ("Did you send this invoice?"), or copy the **Message**. Invoices save themselves the first time they are downloaded, sent or marked sent and move **Saved → Sent → Paid**.

**Centre:**
1. **Invoice run** from lessons, one invoice per **family** or per **student** (centre's choice), on the centre's schedule (a day of the month or days before the period), following the **billing model** (prepaid packages, fixed fee, postpaid, pay per lesson), the fee plans, sibling discount, one-off fees (registration, deposit, materials), proration for mid-period joiners/leavers and the late fee.
2. A cancelled lesson bills its compensation; **one with a blank charge is "not ready"** and holds its invoice.
3. **GST** follows the centre's settings and is worked out **once per invoice**, rounded half up (inclusive or exclusive as chosen). Invoice numbers use the prefix and counter.
4. With **review before sending** on, invoices are **drafts** until an admin approves them. Once **issued**, an invoice is **never edited**; corrections are **credit notes** with a reason.
5. **Delivery:** a secure link by email to the parent, a shareable link for WhatsApp, and the portal.
6. **Reminders** go out on the centre's schedule (for example 3 days before, on the day, a week after).
7. The invoice's QR code and reference use the centre's PayNow UEN or mobile number; the **invoice number is the payment reference**.

### 4.10 Recording a payment

**Solo:** one pay window (payment date, optional screenshot kept privately). It opens from the Ledger's **Mark paid**, the Invoices tab's **Mark as paid** and the student page's **Mark paid**. Marking all of an invoice's lessons paid marks the invoice **Paid**; unticking one reopens it.

**Centre:** staff with `record_payments` record a payment against the invoice by hand (**manual PayNow**, cash, bank transfer, cheque), or the system matches an uploaded **bank statement** (DBS, OCBC, UOB or custom CSV), or a **HitPay / Stripe** payment arrives with its reference. **Partial payments** are accepted only if the centre allows them. An **overpayment** becomes credit for the family or is refunded by hand, as the centre chose. **Gateway fees** are absorbed or shown as a separate invoice line. TutorDeck never holds the money; it goes to the centre's own account.

### 4.11 WhatsApp reminders and email

Solo: one tap on an outstanding balance opens WhatsApp with the **reminder template** (editable in Settings); invoices use the **invoice template**. Centres: payment reminders and missed-remarks reminders are sent by **email** on the centre's schedule; remarks reach parents in the portal and by email if the centre chose that; every email comes from `noreply@tutordeck.com.sg` with the centre's name in the display name.

### 4.12 Google Calendar sync

A solo tutor connects once (Google consent is asked once; the long-lived key is stored encrypted on the server), picks a calendar and presses **Sync now**; the server brings Google up to date so the page can be closed. One-way, TutorDeck → Google. (Google sync for centres is out of scope.)

### 4.13 Exams

Add an exam (type, subject, date, topics, marks) from the Exams page or a student's profile. A **countdown** appears on Home and exams show on the Calendar; scores feed the student's Progress tab with an arrow against the previous exam. Exams are hidden in Client view. Centres' exams use the same records (`manage_students`).

### 4.14 Ledger, Calendar, Planner and Insights (solo)

**Planner** defines the repeating week. **Calendar** shows the real week/month, exams and clashes and lets the tutor add, postpone or edit a lesson in place ("Edit in Ledger" opens the exact lesson). **Ledger** is the money truth (Outstanding by student, Records, bulk select and delete, log week/month, pay window, invoices). **Insights** charts income by month, across the year, by student and by subject and level. **Home** summarises Money and Teaching.

### 4.15 TutorDeck's monthly fee for a centre

1. Through the month tutors and staff mark attendance and flag trials.
2. After the month ends (daily job, 00:30 Singapore time) the system counts last month's **active students** (non-trial; attended, absent or late cancelled; each once).
3. Round to the nearest 10 (halves up) → **billable**. Fee = S$100 + S$0.40 × billable.
4. The quantity is set on the centre's Stripe subscription and a **snapshot** is written last. The owner sees it on the Plan tab.
Each centre's Stripe subscription has two items: the base fee and the per-student quantity.

### 4.16 Tutor pay

The centre chooses **Off**, a **lessons-taught report**, or **full pay**. A lesson is payable **after the parent's payment is reconciled** (default) or **as soon as it is taught**; unpaid lessons roll into the next period and show as **pending**. Rates: **per lesson** (also for remote 1-to-1 centres), **per hour**, **per student per lesson**, or a **fixed monthly amount**. The period ends on the cut-off day; pay day follows. Admins may add **bonuses and deductions** with a reason. Each tutor is an **employee** or **freelancer** (set when invited); employees may need itemised payslips and CPF, which the centre confirms with its accountant. Payment is a **list for manual transfers** using each tutor's own payout details (revealed with an audited step) or a **bulk bank file**. Tutors see **running earnings** or only **closed statements**, as chosen.

### 4.17 Onboarding a tutor at a centre

1. Owner creates the centre, walks the wizard, **Launch**.
2. Owner invites the tutor (name, email, employee/freelancer); TutorDeck emails a link.
3. The tutor sets a password and lands on My lessons.
4. Staff give them lessons in the Timetable.
5. The tutor sets payout details, marks attendance, writes remarks.
6. Admin types pending charges; the owner can resend an unaccepted invite.

### 4.18 Parent journey at a centre

Guardian invited from the household → sets a password → sees each child → receives an invoice link and reminders → pays by PayNow (or gateway link) → the admin (or the system) records it → the parent sees status Paid and any credits and remarks.

---

## 5. Data and privacy

### 5.1 What is stored

| Data | Where | Notes |
|---|---|---|
| Login, email, password hash | Supabase Auth | Passwords never reach TutorDeck's code |
| Tutor profile, business settings | `profiles` | Business name, PayNow ID, bank details, templates |
| Students, guardians, households, lessons, slots, exams, invoices, credits | Postgres | Every row carries `org_id` |
| Payment screenshots, materials | Private storage buckets | |
| Google Calendar link | `gcal_links` | Key encrypted; only the server decrypts |
| Organisation settings | `org_settings` | Append-only, effective-dated |
| Subscriptions, fee snapshots | `org_subscriptions`, `platform_fee_snapshots` | Stripe ids and status; **no card numbers** |
| Audit log | `audit_log` | Append-only |
| Tutor payout details | `tutor_payout_details` | Append-only; no browser access |
| Invite email log | `org_invite_mail_log` | Ids, times, status only: **no address, no link** |
| Error reports | `client_errors` | Short messages; 90 days |
| Backups | Encrypted GitHub artifacts | 30 days; the repository is public, so dumps are never committed |

### 5.2 Who can see what

| Who | Sees | Does not see |
|---|---|---|
| Solo tutor | Their own organisation | Anyone else's |
| Centre owner | The whole centre incl. prices, parents' contact, audit log, plan | Other centres; solo data |
| Centre staff | All business data of the centre to read; write per permission; audit log with `view_audit_log` | Settings changes, billing and plan (owner only); payout numbers without `view_payout_details` |
| Centre tutor | Own lessons via narrow functions; student **name and level**; parent contact **only if the centre allows** | **Any price, rate, amount, paid state, compensation, invoice, other tutors' data** |
| Parent | Their own family's records | Other families, tutor pay |
| Platform admin | Organisation, plan and fee numbers | Student records, unless the owner grants time-limited support access |

- **Money is hidden from tutors by design:** their lesson function has an explicit column list with no money; a test keeps it so, and any new column is checked first.
- **Parent contact** setting: `tutors_see_parent_contact`, default off.
- **Payout details** are shown masked (`•••••1234`); a full value shows only on an explicit **Reveal** that writes an audit row (who, whose, when, method and the masked value, never the number).
- **Audit log:** append-only for everyone signed in. Narrow, flag-controlled exceptions exist only inside solo account deletion, tutor removal and the attendance **Correct** step.
- **Row-level security** is on every table; the access helper functions are locked down.

### 5.3 Account deletion and retention

- **Solo account:** removes the organisation, students, guardians' contacts, lessons, invoices, files, settings, the audit trail, the Stripe customer and subscription and the Google link, then the login. Never delete a tutor's rows by hand: that copies their data into the audit log.
- **Audit rows of a deleted organisation:** recommended: delete them and keep one anonymous marker row (see Open decisions).
- **Centre tutor leaving:** login, name, phone, email and current payout details erased at once; lessons and attendance stay as "Former tutor"; older payout rows are erased **12 months** after leaving (to confirm with the company's adviser).
- **PDPA:** TutorDeck acts as the data intermediary and each centre as the organisation responsible; collect only what is needed (no NRIC, no bank statements for payouts); a significant breach is reported to the PDPC within 3 days. Not legal advice; the owner confirms with the company's adviser.
- **Legal pages:** `privacy.html`, `terms.html`.

### 5.4 Secrets

The Supabase **publishable** key in `config.js` is safe to commit. **Service-role keys, SMTP passwords, Stripe secret keys, Brevo keys, the Google client secret and `CRON_SECRET` never enter the repository**; they are server-side environment variables. This guide contains none.

---

## 6. Environments and release

| | Production | Everything else |
|---|---|---|
| Addresses | `www.tutordeck.com.sg`, `tutordeck.com.sg`, `tutordeck.vercel.app` and two aliases of the production deployment | Every preview, the `dev` staging site, local testing, any unlisted address |
| Database | **LIVE** (real data) | **DEV** (dummy data only) |
| Marker | none | "Test version · dummy data only" tab |
| Server functions | Production variables | Preview variables point at DEV |

The choice is made in `assets/js/config.js` **by hostname, defaulting to DEV**. A new production domain must be added to `PRODUCTION_HOSTS` and `tests/config.test.js`.

**DEV demo logins** (`db/seed_dev_demo.sql`; password in that file; DEV only): `centre.owner@`, `tutor.one@`, `tutor.two@`, `both.tutor@`, `solo.tutor@` (5 active students), plus `centre.staff@` (all permissions) and `centre.frontdesk@` (students only), all `@example.test`.

**How a change ships**
1. Work on a short-lived branch **off `dev`** → pull request into `dev` → checks run → the **Vercel preview** (DEV data) is tested.
2. Only when the owner says ship, open `dev` → **`main`**. `main` is protected; every merge **auto-deploys to production within about a minute**.
3. Each change bumps the `?v=N` cache-buster (`bash bump-version.sh N`), adds a README log entry and keeps phone layouts working (820px).
4. **Database migrations:** apply to DEV first; run on **LIVE in the Supabase SQL editor before** the code that needs it reaches `main`, after a SELECT preview and a yes. Order: **org_foundation → billing → attendance → tutor_access → org_delete → function_lockdown → org_separation**, then the staff, invite and tutor-settings migrations; undo in reverse.
5. **Standing rules (owner):** no deploys until the owner says; any GitHub Actions run needs approval; merge into `dev` only as one complete user flow when the owner needs to test.

**Checks:** unit tests (`node --test tests/*.test.js`), database tests on a throwaway Postgres (`bash tests/sql/run.sh`, with an undo check), browser checks (`tests/*.check.js`), smoke tests in CI on every pull request into `dev` or `main` (made-up data, no outside requests), and a nightly encrypted backup.

**Go-live checklist** (not started; owner-gated): run the migrations on LIVE with previews; split Vercel Production and Preview settings; Stripe live products, webhook and customer-portal configuration; `CRON_SECRET`; revoke the Vercel sandbox bypass token; Vercel Pro (Hobby is non-commercial); a real support mailbox; Google OAuth verification.

---

## 7. Open decisions

Each decision shows the **recommendation first**. Items the owner has already decided are in Appendix A.4.

| # | Decision | Recommendation (first) | Alternative |
|---|---|---|---|
| 1 | Parent portal sign-in and scope | Email + password (or emailed link), one login per guardian covering the household; invoices, attendance, schedule, credits, pay; remarks only if the centre chose | Invoice link only, no login |
| 2 | Online lesson link for remote 1-to-1 centres | One link per student (overridable per lesson), shown to the tutor and the parent | A field only on the lesson |
| 3 | Tutor pay per lesson for 1-to-1 centres | A rate per lesson stored on the tutor, overridable per student | Per hour only |
| 4 | Audit rows when an organisation is deleted | Delete them, keep one anonymous marker row | Keep all, anonymised |
| 5 | Does "charged" mode suggest 0 for an in-time cancellation? | Yes, suggest 0 (the mark already means enough notice was given) | Suggest the full price |
| 6 | Centre price S$100 + S$0.40 | Keep for launch, review after the first paying centres | Lower base fee |
| 7 | Retention of old payout rows | Erase 12 months after leaving | Shorter, or on request |
| 8 | Bank-account encryption | Plain behind functions now, encrypt later | Encrypt from day one |
| 9 | Solo tutors' own holiday library and optional family link | Library in Settings now; a family link later | Not at all |
| 10 | Centre closure and ownership transfer | Transfer first; closure only after an export, owner confirmed | Support-only |
| 11 | Mobile bottom tab bar | Revisit with the Finance/Teaching toggle in mind | Keep the current menu |
| 12 | Landing-page cross-promotion line for MugCorner | Keep for now | Remove |
| 13 | Leave-request wait before auto-approval | 7 days (decided) | — |
| 14 | Other items still open on the board | T3.3 six decisions and T24c.3 five decisions: not listed in the plans, **not verified** | — |

---

## Glossary

| Term | Meaning |
|---|---|
| Active student (platform fee) | A student with at least one non-trial lesson in the month marked attended, absent or late cancelled |
| Active student (free plan) | A solo student on the roster, not discontinued, not past their end date |
| Attendance | `attended`, `absent`, `late_cancelled`, `cancelled_early` ("cancelled in time"), or blank |
| Audit log | The tamper-proof list of who changed what |
| Billable students | Last month's active students rounded to the nearest 10 |
| Both (mode) | A login with students of their own and a centre tutor role |
| Compensation | The amount billed for an absent or cancelled lesson: 0 = not charged, blank = pending |
| Credit (make-up) | One credit per missed, not-charged lesson; a make-up uses it |
| Credit note | A document that corrects an issued invoice |
| DEV / LIVE | The test database / the real database |
| Grandfathered | A solo tutor who joined before billing: unlimited and free |
| Household | A family: siblings and their guardians |
| Membership | A person's role in one organisation |
| Organisation | `solo` or `centre` |
| Permission | A staff ability such as `manage_students` |
| Preset | `solo` or `centre`: the starting settings |
| Row-level security | The database rule deciding which rows a login may read or write |
| Session id | Shared id making several students' lessons one group class |
| Slot | A weekly template of a lesson |
| Status (lesson) | `scheduled`, `done`, `cancelled` |
| Trial | A lesson flagged as a trial; free of TutorDeck's fee |
| ✦ | Marker for a one-off (manually added) lesson |

---

## Appendix A: Build status

Legend: **Built** = on the `dev` staging site (the solo tutor app is also on production, version v252); **On a branch** = built and tested on the named branch, not merged; **Planned** = designed, not built.

### A.1 By section

| Feature | Status | Where |
|---|---|---|
| **Solo tutor app** (2.1: students, planner, calendar, ledger, invoices, WhatsApp, exams, insights, client view, Google sync, export, delete) | Built, **on production** | v252 |
| Solo: organisation scoping, plan card, free-plan gate, card on file, grandfathering, Stripe checkout/portal | Built on `dev` (sandbox Stripe); **not on production** | needs LIVE migrations |
| Solo: holiday library in Settings | Planned | |
| Organisations, memberships, roles, permissions (8), settings versions, audit log, switcher, centre/solo separation (1.2, 1.3) | Built on `dev` | |
| Centre setup wizard, branches/rooms/terms/holidays, SG holiday library, Plan tab, Audit tab, people (invite in-app, permissions, turn off) | Built on `dev` | |
| Invite email (Brevo), welcome page, Resend invite, branded auth emails | On a branch | `claude/t7-2-invites` + owner's Brevo/Supabase steps |
| Centre tutor My lessons, marking rules, centre options for lessons | Built on `dev` | |
| Tutor settings: profile, phone, change password | On a branch | `claude/t24c-1-profile` |
| Tutor payout details (masked, reveal, audited) | On a branch | `claude/t24c-2-payout` |
| `view_payout_details` permission, centre payout list, reveal | On a branch | `claude/t24c-3-payout` |
| Tutor leave / delete, centre removes a tutor, "Former tutor" | Planned | T24c.5–7 (branch `claude/t24c-5-leave` is not on origin) |
| Staff Home (counts) | On a branch | `claude/t3-1-staff-home` |
| Staff Students and households | On a branch | `claude/t3-2-students` |
| Staff Attendance, correct with reason, integrity guard | On a branch | `claude/t3-3-attendance` |
| Charges queue with suggested charge | On a branch | `claude/t3-4-charges` |
| Trial flag in the sheet and filter (T3.5) | Planned (badge read-only is on a branch) | |
| Timetable view, slots with tutors, generator, cover, group lessons, permission sweep (T3.6–T3.10) | Planned | |
| Centre invoicing, credit notes, payment recording, statement matching, gateways, reminders, reports (T4) | Planned | |
| Tutor pay (report, full, payout list, bank file) (T4) | Planned | |
| Tutors edit their own lessons (T6) | Planned | |
| Make-up credits, holiday skipping (T18 steps 3–4) | Planned | |
| Parent portal, remarks to parents, emails to parents | Planned | |
| Online lesson links, per-lesson tutor pay | Planned | |
| CSV import, logo upload | Planned | |
| TutorDeck monthly centre fee job and plan snapshots | Built on `dev`; never run for real money | |
| Platform admin: admin list, `platform_orgs()`, support-access grants (database only) | Built on `dev` | |
| Platform admin console, support-access screen, support mailbox | Planned | |
| Account deletion (solo, full) | Built on `dev`; production uses the older function that removes the login | |
| Error log, nightly backups | Built, on production | |

### A.2 Centre options (section 3) that are available now

| Available now (read by the app or database) | Not yet available (the wizard shows them as "Coming soon", or they depend on planned features) |
|---|---|
| `lessons.attendance_by`, `attendance_window_days`, `cancellations_marked_by`, `compensation_entered_by`, `trials_flagged_by`, `remarks.required`, `remarks.deadline_hours`, `tutors_see_parent_contact`, `replacement_tutors`, `timetable_editing` = admin_only / tutors_direct, `tutors_edit.postpone`, `tutors_edit.cancel`, `min_notice_hours`, `max_changes_per_month`, `notify_family`; `profile.trading_name`; `payments.modes` = manual PayNow; `billing.absences.mode` suggests charges on branch `claude/t3-4-charges` | **Coming soon in the wizard:** `calendar.skip_holidays`, `profile.logo_path`, `billing.low_balance_credits`, `billing.credit_expiry_days`, `billing.fee_plans_note`, `billing.makeups.*`, `invoicing.delivery.email`, `invoicing.reminders.*`, `payments.statement_bank`, `payments.hitpay.*`, `payments.modes` (statement matching, HitPay, Stripe), `lessons.timetable_editing` = tutors_propose, `lessons.tutors_edit.weekly_slots` / `generate` / `one_off` / `link`, `lessons.remarks.visibility` (parents), `lessons.missed_remarks_reminders`, `tutor_pay.mode` = full, `tutor_pay.payout_method` = bank_file |
| | **Saved and shown in the wizard's samples, but no screen uses them until centre invoicing and tutor pay (T4) exist:** the rest of `profile.*`, `billing.*`, `invoicing.*`, `payments.*`, `tutor_pay.*` (these are **not** marked "Coming soon" today) |

### A.3 Branches awaiting a merge

| Branch | Adds | DEV database script |
|---|---|---|
| `claude/t3-1-staff-home` | Centre Home, two staff demo logins | `migration_staff_home.sql` + seed |
| `claude/t3-2-students` | Staff Students | `migration_staff_students.sql` |
| `claude/t3-3-attendance` | Staff Attendance | `migration_staff_attendance.sql` |
| `claude/t3-4-charges` | Charges queue | `migration_staff_charges.sql` (one assertion in its SQL test currently fails, line 138) |
| `claude/t7-2-invites` | Invite email, resend, welcome page | `migration_invites.sql` |
| `claude/t24c-1-profile`, `t24c-2-payout`, `t24c-3-payout` | Tutor settings, payout, payout permission | `migration_tutor_profile.sql`, `migration_tutor_payout.sql`, `migration_payout_permission.sql` |
| `claude/t26b-dev-pack` | One combined DEV SQL pack for the above | — |

Each T3 branch is built on the one before it (the last contains all four). `t7-2-invites` and `t24c-1-profile` both use cache version v273.

### A.4 Owner's decisions so far

| Date | Decision |
|---|---|
| 2026-11-24 | Solo plan: free ≤ 5 active students; Solo Pro S$14.90/month or S$149/year; 30-day trial once per organisation, no card; existing solo tutors unlimited |
| 2026-11-24 | TutorDeck is not GST-registered; centres choose their own GST settings |
| 2026-11-24 | Centre fee S$100 + S$0.40 × billable students (rounded to nearest 10, trials excluded); under review, kept for now |
| 2026-11-24 | Product principle: centre-specific process = wizard option; build every option; unbuilt = "coming soon" |
| 2026-11-24 | Absent/cancelled billing = compensation (0 / number / blank = pending); who types it, flags trials, marks cancellations, the window, who marks, remarks required are centre settings (defaults admin / admin / admin / 14 days / tutor / no) |
| 2026-11-24 | Tutors see no parent phone by default; tutors have no table access; group classes = one row per student with a session id; previews use DEV |
| 2026-11-24 | Centre and solo are separate; switcher for multi-org people; staff land on the centre home |
| 2026-11-24 | Make-ups: one missed lesson = one credit, never charged twice; credit for notice-given absences, tutor cancellations, holidays; never expire by default; centres skip holidays by default; SG dates from MOM, re-check 2027, add next year each November |
| 2026-11-24 | Standing rules: no deploys until the owner says; Actions need approval; merge to `dev` only as one complete flow when the owner needs to test |
| 2026-11-25 | Settings is for solo, both and centre owner, not tutor-only; tutors get a small tutor-settings page |
| 2026-11-25 | T3 (all yes): staff with `manage_timetable` may correct any mark with a required reason (audited); pending charges typed by `issue_invoices`; staff can always mark/correct; group classes light; absence setting only pre-fills; past-unmarked window 60 days; centre staff have 8 permissions |
| 2026-11-25 | T7 (all yes): welcome page reuses `/reset`; link life 24 h; Brevo free plan; previews email only `@tutordeck.com.sg` + allow-list; centre name in the display name; Resend invite for admins and staff with Manage tutors; claim at most every 30 min per login; reply-to address set for launch |
| 2026-11-25 | T24b (all yes): leaving = request, one-tap approval, auto-OK after 7 days, "Former tutor"; new `view_payout_details` permission; old payout rows erased after 12 months (confirm with adviser); bank-account encryption later; 7-day amber flag on payout changes |
| 2026-11-25 | Menu label "Centre" for one centre, "Centres" for more |
| 2026-11-25 | 1-to-1 / remote centres are first-class: no class, room or branch required; add online lesson link and per-lesson tutor pay |

---

## Appendix B: Where to find things in the code

| Topic | Files |
|---|---|
| Every centre option | `assets/js/org-settings.js`, `db/migration_org_foundation.sql` |
| Wizard / centre page | `org.html`, `assets/js/org.js` |
| Organisations, roles, permissions, audit | `db/migration_org_foundation.sql` |
| Billing and plan | `db/migration_billing.sql`, `api/billing.js`, `api/stripe-webhook.js`, `api/billing-cron.js`, `assets/js/plan.js`, `assets/js/money.js` |
| Attendance and fee count | `db/migration_attendance.sql`, `db/migration_tutor_access.sql` |
| Tutor page | `tutor.html`, `assets/js/tutor.js`, `assets/js/tutor-core.js` |
| Menus, roles, switcher | `assets/js/app.js`, `assets/js/org-current.js`, `assets/js/org-scope.js` |
| Account deletion | `api/delete-account.js`, `db/migration_org_delete.sql` |
| Google Calendar | `api/gcal.js`, `api/gcal-callback.js`, `api/_gcal-lib.js`, `assets/js/gcal-core.js` |
| Environments | `assets/js/config.js`, `tests/config.test.js` |
| Demo data | `db/seed_dev_demo.sql` |
| Plans | `docs/orchestrator/` (`BOARD.md`, `T12-plan.md`, `T12c-notes.md`, `T18-plan.md`); on branches `T3-plan.md`, `T7-plan.md`, `T24b-plan.md`, `T2-report.md` |
| Staff screens (branches) | `centre*.html`, `assets/js/centre*.js`, `db/migration_staff_*.sql` |
| Invites (branch) | `api/send-invite.js`, `api/_brevo-lib.js`, `db/migration_invites.sql` |
| Tutor settings (branches) | `tutor-settings.html`, `db/migration_tutor_profile.sql`, `migration_tutor_payout.sql`, `migration_payout_permission.sql` |
| This guide's checker | `docs/product/build-options.js` |

*End of guide.*
