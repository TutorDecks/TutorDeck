# Bundle 8 test list (T53) — branch `claude/bundle-8`, `?v=359`

Bundle 8 = bundle 7 + **Raphael's calendar CSS fix** (`feature/schedule-css-fix`) + **b8-fix** (F1–F6, F8 from the T51 report). Apply `docs/orchestrator/dev-apply-pack-b8.sql` to DEV first (needs bundle 7's pack). Only one thing changed in the database: three functions (F4, F5, F6).

Use the demo centre owner for the money steps and a centre tutor for the calendar (`Demo-Pass-2026`; see `db/seed_dev_demo.sql`). Try each step on a phone width (390 px) too.

| # | Check | Steps | Expected |
|---|---|---|---|
| F1 | Early tab click | Open Money, click **Statements** or **Email** straight away, before the page has loaded | "Loading your centre…", never a database error |
| F2 | Undo reason | Money > an applied credit/deposit > Undo; leave "Say why" empty, press the button, then type a reason | The red "Say why" message disappears as soon as you type |
| F3 | Email invoice feedback | Issue an invoice, open it, **Email invoice** > Send | At once "Queued for N emails"; if none can be queued it says why (e.g. no billing contact); the button is never stuck; Money > Email then lists it waiting |
| F4 | Discarded deposit comes back | Invoice run: raise a deposit + lesson invoice, discard only the **deposit** draft, keep the lesson invoice | The deposit is offered again at the same amount (Invoice run has a Create button; Deposits tab says "Draft discarded", not "Invoice not issued yet"). A **waived** deposit does NOT come back |
| F5 | Refunded deposit | Refund (or apply / keep / move) a paid deposit | Deposits tab says **Refunded** / **Settled**, never "to collect"; the short amount is 0 |
| F6 | Trial lessons earn no credit | Mark a lesson **Trial**, then mark it cancelled-early / absent (any rule that normally earns a credit) | No make-up credit appears under Attendance > Make-ups. A normal lesson with the same mark still does. Staff can still grant one by hand. There is no setting for this (check Settings: no "trial" credit option) |
| F8 | Import wording | Import a file whose start date is not a real date | The problem reads "Start date is not a real date." (no "Error" label in front) |
| Cal | Calendar on a phone | Sign in as a centre tutor, open **Schedule**, width 390 px, switch to **Calendar** | Styled week: List \| Calendar toggle, a day strip you can tap, hour labels small, lesson blocks shown (the page counts the same lessons as the List), "No lessons" note on an empty day. Also check dark mode, and the page at desktop width (week grid with all 7 days) |

Also re-check once: the other pages still look right at v359 (hard refresh, no stale CSS).
