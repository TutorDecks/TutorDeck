# TutorDeck: facts for drafting a Service Agreement, Terms or proposal

**NOT LEGAL ADVICE.** This is a sheet of facts taken from the code, `CLAUDE.md`, the Product Guide and the board's recorded owner decisions, as of 2026-11-26. It is meant to feed a drafter (a Claude chat, then the owner's lawyer). Every legal choice is for the owner and the owner's lawyer. Where a fact is a plan, not something running, it says so. "Not verified" means nobody checked it in code or on the live system.

Source short names: **Guide** = `docs/product/TutorDeck-Product-Guide.md`; **Board** = `docs/orchestrator/BOARD.md`; **CLAUDE** = `CLAUDE.md`; **Privacy** = `privacy.html`; **Terms** = `terms.html` (version v1, 18 Oct 2026).

## 1. Parties

| Role | Fact | Source |
|---|---|---|
| Provider | **TutorDeck Pte. Ltd.**, Singapore. Founded by Raphael and T-Leng, who also use the product for their own tuition businesses | CLAUDE, Terms |
| Customer type A | **Solo tutor**: one person, an organisation of one (kind `solo`) | Guide 1.2 |
| Customer type B | **Tuition centre**: an organisation (kind `centre`) with an owner, optional staff and tutors | Guide 1.2 |
| End users who are not customers | Centre tutors, centre staff, parents/guardians and students. They use the product under a centre's account | Guide 2 |
| Contact | `tutordeckadmin@gmail.com` is the address in Privacy and Terms (data protection officer contact, requests, questions). A real support mailbox is **not yet set up** (go-live checklist) | Privacy, Guide 6 |
| Governing law in the live Terms | Laws of Singapore, exclusive jurisdiction of the Singapore courts | Terms s.9 |

## 2. What the service is

A web app (no installed software; works on phones) for tutors and tuition centres. Plain list of what it does:

- Students, weekly planner, calendar, lessons ledger, invoices with PayNow details, payment records, exams, WhatsApp reminder text, Google Calendar sync (solo).
- For centres: organisation setup wizard (every process rule is the centre's setting), staff screens (Home, Students, Attendance, Charges; see Guide Appendix A for which are built), tutor access to their own lessons only, parent invoicing and payments (planned), tutor pay (planned), TutorDeck's monthly fee job.
- Built vs planned is in Guide Appendix A. **Do not describe a planned feature as available** in an agreement. Examples still planned: centre invoicing and payments, parent portal, tutor pay, remarks to parents, make-up credits, the platform admin console, support mailbox.
- The product is used on the live site `https://www.tutordeck.com.sg` (also `tutordeck.vercel.app`). The custom domain was being activated in CLAUDE (DNS then pending); the Board lists it as live. Not verified today.

Source: Guide 1-4, Appendix A; CLAUDE.

## 3. Plans, prices and billing (TutorDeck's own fees)

### 3.1 Solo tutors

| Item | Fact |
|---|---|
| Free plan | Up to **5 active students** (on the roster, not discontinued, not past their end date) |
| Solo Pro | **S$14.90 per month** or **S$149 per year** |
| Free trial | **30 days**, **once per organisation**, **no card needed** to start |
| Early / existing solo tutors | **Grandfathered**: unlimited students, free ("Early tutor"). The billing migration marks every existing solo organisation `grandfathered = true` |
| 6th student | Prompt "Your free plan is full" with a link to upgrade |
| Who can buy | Only the organisation's owner |
| Taking payment | Stripe (checkout and customer portal). Card details are held by **Stripe**, not TutorDeck; TutorDeck stores Stripe ids and status only |
| Changing plan | Switch monthly/yearly with proration and cancel at period end through Stripe's customer portal (the portal configuration must be saved in Stripe LIVE first) |
| Cancelling | Cancel at **period end** (through the portal). Behaviour of access after a failed payment: access is kept while Stripe status is trialing, active or past_due; ends when Stripe cancels |
| Refunds | **No refund policy exists.** Terms s.5 says fees, billing cycle and refund terms will be told before any charge |

### 3.2 Centres

| Item | Fact |
|---|---|
| Monthly fee | **S$100 + S$0.40 × billable students** |
| Billable students | Last month's **active students**, **rounded to the nearest 10, halves up** (98 → 100 → S$140; 250 → S$200; 405 → 410 → S$264) |
| Active student | A student with at least **one non-trial lesson in that month** marked **attended**, **absent** or **late cancelled**. Each student counts once. Lessons cancelled in time and unmarked lessons do not count |
| How it is charged | A daily server job (00:30 Singapore time, production only) counts last month, sets the quantity on the centre's Stripe subscription and writes a fee snapshot. **Each centre's Stripe subscription is created by hand today** with two items (base fee and per-student quantity) |
| Price status | **Under review** against a competitor (about S$148 per branch at 400 students). Owner chose to keep it for now. Not final |
| Attendance data needed | The fee is only correct once the staff screens for attendance and trial flags are in use; otherwise counts stay 0 |

### 3.3 Both

| Item | Fact |
|---|---|
| GST | TutorDeck is **not GST-registered**: prices carry **no GST**, and Stripe Tax stays off. A centre sets its own GST handling for its parent invoices |
| Currency | Singapore dollars |
| Price changes | Not decided. The Terms only promise notice before introducing paid plans |
| Plans in force today | **Not verified.** Billing runs on the Stripe **sandbox** and the DEV database only. Nothing has been charged to a real customer. The Terms on the live site still say the service is free of charge (s.5) |

Source: Guide 1.4, 4.15; Board (owner's decisions); CLAUDE to-do 6; `db/migration_billing.sql`; `api/billing.js`, `api/billing-cron.js`, `api/stripe-webhook.js`; `assets/js/money.js`.

## 4. What TutorDeck does not do

- **Never holds a centre's money.** Parents pay the centre directly (PayNow or the centre's chosen methods). TutorDeck only charges its own fee to the centre (CLAUDE; Guide 1.4).
- **The centre decides the rules** about its own business: parent fees, GST, who marks attendance, how long tutors have to mark, who records cancellations and charges, whether remarks are required, who sees parents' contact, tutor replacement, tutor pay. TutorDeck builds each option; it does not impose them (CLAUDE "Product principle").
- TutorDeck does not set tutors' pay, does not employ the centre's tutors and does not collect parents' payments (Guide 4.16: payment lists are for the centre's own manual transfers).
- No NRIC and no bank statements are collected for payouts (Guide 5.3).
- Legal and tax questions about the centre's own business (employee vs freelancer, CPF, payslips) are for the centre and its accountant (Guide 4.16).

## 5. Roles and who decides what

| Role | Can do | Cannot |
|---|---|---|
| **Centre owner** | Everything in the centre: settings, plan and billing, people, prices, audit log, support-access grants, transfer ownership, close the centre (with data export first, planned) | See other centres or solo data |
| **Centre staff** | Read all business data; write only what their permissions allow (eight permissions such as manage students, timetable, tutors, issue invoices, view audit log, view payout details) | Change settings, billing or plan (owner only). See payout numbers without the permission |
| **Centre tutor** | Own lessons only; mark attendance and notes when the centre allows; see student name and level; parent contact only if the centre chooses | See any price, rate, amount, paid state, compensation, invoice or another tutor's data. Edit a lesson's price, date or time |
| **Parent / student** | See own family's records; pay (planned, not built) | See other families or tutor pay |
| **Platform admin (TutorDeck)** | See organisation, plan and fee numbers | Read student records, unless the owner grants time-limited support access |
| **Solo tutor** | Everything in their own organisation | Anyone else's data |

Fixed rules (integrity, not process): nobody marks a lesson before its day; nobody overwrites another person's mark; tutors never see or edit a lesson's price, date or time; tutors have no table access at all, only two database functions.

Source: Guide 2, 5.2; CLAUDE "Organisations"; `db/migration_org_foundation.sql`, `db/migration_tutor_access.sql`.

## 6. Data

### 6.1 What is stored

Account (email, password hash held by Supabase Auth); profile and business settings (business name, PayNow ID, bank details, message templates); students, guardians and households (names, contact numbers, levels, lesson notes, payment records, exam details; **some data concerns minors**); lessons, slots, invoices, credits; uploaded files (payment screenshots, teaching materials) in private storage; organisation settings (append-only, effective-dated); subscriptions and fee snapshots (Stripe ids and status; **no card numbers**); audit log; tutor payout details; invite email log (ids, times and status only, no address or link); error reports (messages with emails and phone numbers removed, **deleted after 90 days**); Google Calendar link (the refresh token is **encrypted**, with a key held only by the server).

Source: Guide 5.1; Privacy s.1, s.6.

### 6.2 Who sees what

See section 5 and Guide 5.2. Highlights:

- Row-level security is on every table; each solo organisation is separated from every other.
- **Tutors have no table access.** They use two narrow database functions with an explicit column list that never includes money; a test keeps it that way.
- **Payout details** are shown masked (last four digits). A full value shows only after an explicit **Reveal** that writes an audit row (who, whose, when, method, masked value; never the number). Bank accounts are stored in plain text behind functions today; **encryption is deferred** (owner decision, to revisit).
- **Audit log:** append-only for everyone signed in; the only deletions are inside solo account deletion, tutor removal and the attendance Correct step, and are flag-controlled.
- **Support access:** TutorDeck staff can read a centre's business data only while a **time-limited, revocable grant** from the centre owner is in force, with a reason; every grant is audit-logged. The database part exists (table `support_access_grants`); the screen to grant it is **planned**.
- **Parent contact** is hidden from tutors unless the centre turns it on.

### 6.3 Retention and deletion (decided so far)

| Case | What happens | Status |
|---|---|---|
| Solo tutor deletes their account | Server function removes the organisation, students, contacts, lessons, invoices, files, settings, audit trail, the Stripe customer and subscription and the Google link, then the login. Needs live server settings to work (Production does not have them yet) | Built; go-live prerequisite |
| Organisation deletion: audit rows | Recommendation: delete them, keep one anonymous marker row. **Owner still to confirm** | Open |
| Centre tutor leaves a centre | Leaving is a **request** to the centre owner; one-tap approval; **auto-approved after 7 days**. Then login, name, phone, email and current payout details are erased at once; lessons and attendance stay as "Former tutor" | Decided; build **not on `dev`** (plan `docs/orchestrator/T24b-plan.md`; branch not found) |
| Old payout rows | Erased **12 months** after the person leaves, or earlier on request. To confirm with the company's adviser | Decided in principle; not built |
| Leave-centre request | A tutor may ask to leave; the centre owner approves | Same as above |
| Error reports | Deleted after 90 days | Stated in Privacy |
| Terms: closing an account | The user can stop and close the account at any time; "subject to any records we must keep by law" | Terms s.8, Privacy s.4 |
| Centre closure / ownership transfer | Recommendation: transfer first; closure only after a data export, owner confirmed | **Open** (Guide 7 #10) |
| Data export | A solo "export my data" button exists in Settings (`exportData` in `assets/js/settings.js`). A centre export is **planned**, with closure | Partly built |
| Retention rule for everything else | Privacy says data is kept "as long as your account is active or as needed" then deleted or anonymised. No fixed periods | Not decided |

### 6.4 Backups

A nightly **encrypted** database backup runs through GitHub Actions; artifacts are kept **30 days**. The repository is public, so dumps are never committed and data is never printed in logs. Restore steps are in the README. The Terms tell the user to keep their own backups of important records. Source: CLAUDE; Terms s.7.

### 6.5 Where data lives

Privacy says the database is hosted by Supabase on servers in **Singapore**. Region of the **live** project was not checked here (**not verified**). The website is served by Vercel; some providers (Vercel, Google) may process limited data outside Singapore (Privacy s.7). There is one live Supabase project (real data) and one dev project (dummy data only, used by every preview and all testing).

## 7. Sub-processors in use

| Provider | Used for | Data it sees | Source |
|---|---|---|---|
| **Supabase** | Database, login (Auth), file storage | All stored data, hosted in Singapore (per Privacy) | Privacy s.5; CLAUDE |
| **Vercel** | Serves the website; runs server functions (billing, deletion, Google Calendar, invites) | Web requests and the server functions' traffic. Hobby plan today (see 8) | Privacy s.5; CLAUDE |
| **Stripe** | TutorDeck's own subscription billing and customer portal | Customer email and billing identity, card details (held by Stripe only), subscription status. Sandbox only today | CLAUDE; Guide 1.4 |
| **Brevo** | Sends sign-up, reset and magic-link emails and tutor invite emails from `noreply@tutordeck.com.sg`; free plan. Planned later: reminders | Recipient email and name, the message (the invite says the centre's name; no student or fee data) | `T7-plan.md`; Guide 2.7. Auth emails and invites are **not live** (branch `t7-2-invites`; owner steps pending). Today Supabase's built-in sender is used |
| **Google** | Sign-in with Google, and Google Calendar sync | Name, email, picture at sign-in; calendar events TutorDeck creates (student name, subject, level, time, fee, paid state). The Google refresh token is encrypted | Privacy s.6 |
| **WhatsApp** (links only) | "Send reminder" opens a WhatsApp link with prefilled text; the user sends it from their own phone | The message text, in the user's own WhatsApp. TutorDeck does not send WhatsApp messages | `assets/js/student.js`; Privacy s.5 |
| **GitHub** | Hosts the code; runs the nightly encrypted backup | Encrypted backup file only, kept 30 days | CLAUDE |
| **Google Fonts** | Loads the Manrope typeface in the browser | The visitor's IP address as part of a font request | `index.html` and other pages (not verified whether this matters to the owner) |
| Cloudflare Turnstile (bot check) | Mentioned as the sign-up bot check on LIVE | Visitor browser signals | `T7-plan.md` mentions it; **not verified in code** |

## 8. Environments, availability and support

| Fact | Detail |
|---|---|
| Hosting plan | Vercel **Hobby**, which is **non-commercial**. **Vercel Pro is a go-live prerequisite before charging customers** (CLAUDE to-do 5 and 6) |
| Production vs test | Only production addresses use the live database. Every preview, `dev`, and local test uses the dev database with dummy data and shows a "Test version · dummy data only" tab |
| Deploys | Every merge to `main` goes live within about a minute. `main` is protected |
| Checks | Unit tests, database tests, browser checks and smoke tests run in CI; a nightly encrypted backup |
| Uptime | **No uptime target exists.** Terms s.6: "We aim to keep the Service running but do not guarantee uninterrupted or error-free operation", "as is" |
| Support | **No support hours, response times or channel are defined.** A support mailbox is a go-live item. Contact today: `tutordeckadmin@gmail.com` |
| Incident process | **No documented incident or outage process.** A data breach likely to cause significant harm is reported to the PDPC (the guide says within 3 days) and to affected people (Privacy s.10) |

**Commitments that do not yet exist (list as "to decide"):** uptime or availability percentage, support hours, response and resolution times, maintenance windows, status page, service credits, disaster-recovery targets (recovery point and time), data-restore promise, notice period for outages.

## 9. PDPA considerations the documents mention

- **Roles:** the Privacy page says the customer (tutor or centre) is the organisation responsible for the personal data of its students, and TutorDeck is a **service provider (data intermediary)**. TutorDeck is the organisation responsible for its own account data. **This allocation is for the owner's lawyer to confirm** (see section 11).
- The customer must have a proper basis to collect data, including **a parent or guardian's consent where the student is a minor** (Privacy s.2; Terms s.3).
- TutorDeck collects only what it needs: no NRIC; no bank statements for payouts.
- Consent: by creating an account the user consents to the use of account and business data as described (Privacy s.4). Withdrawal by deleting the account or emailing.
- Access and correction requests go to the Data Protection Officer contact (Privacy s.9, s.11).
- Overseas transfer: Privacy s.7 says protection is intended to be comparable to the PDPA.
- Breach notification: PDPC and affected individuals where significant harm is likely (Privacy s.10).
- The privacy page itself carries a note in its source asking for review by a lawyer or PDPA consultant before going public. **Not known whether that review happened.**
- Tutor payout details, audit-log contents and leave/retention rules were designed with PDPA in mind (`T24b-plan.md`), with the 12-month look-back to be confirmed with the company's adviser.

## 10. Acceptable use and obligations implied by the documents

From the live Terms: keep credentials secure and answer for activity under the account; give accurate information and be legally able to contract; use the service lawfully and within the PDPA; do not misuse the service, attempt to breach security or access data that is not yours; do not upload unlawful, infringing or harmful content; teaching materials supplied by others stay their owner's property and may not be redistributed or resold. Provider rights: may change features, may suspend or terminate for breach, may change the Terms (continued use means acceptance).

Implied by the product but **not written in the Terms**: a centre is responsible for the accuracy of what its staff and tutors enter and for lawful use of parents' contact details; only the owner may buy or cancel plans and grant support access; a centre must tell its tutors and parents how their data is used. Suggestions for the drafter, not facts.

## 11. Cancellation, termination and export: what exists

| Mechanism | Today |
|---|---|
| Solo cancels the paid plan | Stripe portal, cancel at period end (live portal config pending) |
| Solo deletes account | Built (go-live prerequisites apply); removes data and the Stripe customer |
| Solo exports data | Settings "export" button exists |
| Centre cancels or closes | **Not defined.** Planned: plain-words route with a data export first; ownership transfer first |
| Centre subscription | Created and managed by hand in Stripe today |
| TutorDeck suspends or terminates | Terms s.8: for breach. No notice or cure period written |
| What happens to data after termination | Deletion by account deletion; no fixed grace period; no promise on how long data is kept after a centre stops paying |
| Free-plan limit exceeded (e.g. downgrade) | Not decided. **Not verified** in code |

## 12. DECISIONS THE OWNER MUST MAKE for the agreement

Nothing below is decided in the repository. Where the documents hold a recommendation, it is noted. The owner should take these to the company's lawyer.

1. **Support:** hours, channel (a real support mailbox is a go-live item), target response times, who answers.
2. **Service levels (SLA):** an uptime target or none; maintenance windows; service credits; or "reasonable endeavours" only (the Terms today say "aim to keep running, no guarantee").
3. **Liability cap** and exclusions. The Terms today exclude indirect loss and loss of data, and tell users to keep their own backups.
4. **Data export and closure terms:** what a customer can export, in what format, for how long after closing; the centre closure route (Guide 7 #10); what happens to data when a centre stops paying.
5. **Refund policy** for the solo plans (monthly and annual), the 30-day trial and centre fees (not defined).
6. **Price-change notice:** how much notice before fees change, and whether existing customers keep a price.
7. **Centre price:** S$100 + S$0.40 per billable student is under review; confirm before it goes in a contract.
8. **Grandfathered tutors:** whether "unlimited and free" is for life, or may change with notice.
9. **Governing law and disputes:** the Terms say Singapore law and the Singapore courts; confirm.
10. **Data roles under the PDPA:** who is the data controller (organisation responsible) and who is the data intermediary for each type of data (the Privacy page says customers are responsible and TutorDeck is the intermediary for student records). **For the owner's lawyer.** Include whether a separate data processing agreement is needed.
11. **Sub-processor list and change notice:** whether the agreement names them (section 7) and how customers are told about changes.
12. **Data location:** whether to promise Singapore hosting (Privacy says so; confirm for the live project) and how to describe overseas processing by Vercel and Google.
13. **Retention periods:** payout rows (12 months, to confirm with the adviser), audit rows after organisation deletion, backups (30 days), data after closure.
14. **Support access:** the terms on which TutorDeck staff may access a centre's data (time-limited, owner-granted, audited) and for what purposes.
15. **Security commitments:** whether to describe row-level security, encryption in transit, encrypted token storage and nightly encrypted backups, and the breach notification promise (the guide says 3 days to the PDPC).
16. **Plain-words Terms refresh:** the live Terms say the service is free; they need updating before charging, together with Privacy (adds Stripe, Brevo, tutors, parents).
17. **Whether tutors, staff and parents** must accept anything (they use the centre's account): who takes their consent and who tells them.
18. **GST:** TutorDeck is not GST-registered; what to say when it registers.
19. **Hosting:** upgrading from Vercel Hobby to Pro before charging (go-live checklist).
20. **Who signs:** the individual tutor or the business, and for centres, the authorised person.

## 13. Not verified, and flagged gaps

- Whether the live site is already on the custom domain, and the region of the live database.
- Whether a lawyer has reviewed `privacy.html` or `terms.html`.
- The details of the Stripe LIVE setup (not started).
- Whether the invite and payout features described here have been tested on DEV by the owner (several are on unmerged branches; see `docs/INDEX.md`).
- Everything the Guide marks "Planned" (parent portal, centre invoicing, tutor pay, platform admin console, support-access screen) is not available to sign up for yet.
