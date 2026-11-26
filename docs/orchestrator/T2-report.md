# T2 — end-to-end test report (local run against the DEV project)

Tested: integration branch `claude/sleepy-bell-xfr6zb` @ `2127a02` (v260), served locally with `python3 tests/server.py 8765`, driven by Playwright (Chromium) at 1280px and 390px.
Date: 2026-11-24. Project used: **DEV** `tuzxsqkfzrjssnpcoale` only (dummy data). LIVE, Stripe, Vercel settings and secrets were not touched.

## Why a local run
The Vercel preview is behind Vercel Authentication (302 to SSO). By the owner's decision (option 1) T2 ran locally instead. No token, bypass link or Vercel tool was used.
**LIVE-safety check:** `assets/js/config.js` returns LIVE only for the five listed production hosts. On `localhost:8765` the page reported `ENV=dev`, `SUPABASE_URL=https://tuzxsqkfzrjssnpcoale.supabase.co` and showed the "Test version · dummy data only" tab on every page. PASS.

## Results by area
| # | Area | Result |
|---|---|---|
| 1 | Five demo logins, landing and menu | **PASS** |
| 2 | Tutor My lessons: marking, window, rules | **PASS** (default settings only; see "Not tested") |
| 3 | Free-plan prompt on the 6th active student | **PASS** (desktop and phone) |
| 4 | Stripe sandbox checkout, webhook, portal | **NOT TESTED** (needs Vercel server functions) |
| 5 | Centre setup step 7 | **PASS** with 2 low findings |
| 6 | Fresh sign-up | **PASS** |
| 6 | Account deletion | **NOT TESTED** (needs `api/delete-account`); throwaway user left behind |
| – | Phone width (390px) | **PASS**, no horizontal overflow on any page tested |

### 1. Logins and menus
| Login | Landing | Menu |
|---|---|---|
| centre.owner | /home | Home, Schedule, Students, Money, More (Materials, Settings) |
| tutor.one | /tutor | My lessons only; More = sign out |
| tutor.two | /tutor | My lessons only; More = sign out |
| both.tutor | /home | Home, Schedule, Students, Money; More adds **My lessons** |
| solo.tutor | /home | Home, Schedule, Students, Money, More (Materials, Settings) |

No console or JS errors on any landing page.

### 2. My lessons (tutor.one / tutor.two, defaults: attendance by tutor, window 14 days, cancellations/charge/trial by admin, remarks not required)
Through the UI (390px):
- Mark attended with topics, homework, remarks: saved, chip becomes Attended.
- Mark attended with empty remarks (remarks not required): saved.
- Mark absent: sheet says "An admin will decide what this lesson is charged."; no charge box; row becomes Cancelled (status follows attendance).
- Reopen own absent mark and correct to attended: allowed.
- Only Attended and Absent are offered (no late/in-time cancellation options).
- Future lessons: no buttons, "You can mark a lesson from its day onward." Cancelled lesson: "This lesson was cancelled."

Server rules (called directly through `tutor_mark_attendance` as a signed-in tutor, bypassing the UI), all refused correctly:
- future lesson: `TOO_EARLY`; 20 days old: `TOO_OLD`; cancelled lesson: `CANCELLED`
- late_cancelled or an unknown value: `BAD_VALUE`; trial flag: `TRIAL_ADMIN_ONLY`; typed charge: `CHARGE_ADMIN_ONLY`
- another tutor's lesson (marking or notes): `NOT_FOUND`; random id: `NOT_FOUND`
- tutor overwriting an admin's mark: `ALREADY_MARKED`
- Each tutor's list contains only their own lessons. `tutor_my_lessons` has no rate/amount/paid columns (only the boolean `tutor_sets_compensation`); `parent_contact` was empty for every row (setting off).
- Direct table reads as a tutor: `lessons` 0 rows, `students` 0, `invoices` 0, `recurring_slots` 0. (`org_settings`, `org_subscriptions`, `org_plans`, `memberships` returned rows, but only the tutor's own *solo* organisation; the centre's rows were not visible.)

### 3. Free plan
solo.tutor has exactly 5 active students. Add student, name "ZZ Limit Probe", Save: dialog "Your free plan is full … S$14.90 a month, with a 30-day free trial and no card needed to start." Student count stayed 5. "See plans" goes to `/settings#plan-card`, which shows "5 of 5 used" and "Start 30-day free trial". Same on phone through the floating + button.
A brand-new account's plan card reads "0 of 5 used".

### 5. Centre setup step 7
- Settings mode (centre.owner, Demo Learning Centre, 390 and 1280): all fields show the seeded values; "Tutors may edit their own lessons", the two "sent to parents" options and the missed-remarks reminder are marked coming soon and disabled.
- Setup mode (throwaway user, "T2 Test Centre"): walked steps 1 to 7. Defaults are as expected. Changed cancellations, charge and trial to Tutor, remarks required, window 7, deadline 48, parent contact on. Save and continue reached step 8, and `org_settings_on` returned exactly those values. A window of -3 or blank is rejected. 

### 6. Sign-up
Throwaway `t2-throwaway-mwum2aj0@example.test` (dummy). Short password and missing consent are refused with clear messages. Account created, signed in straight to /home with the "Set up TutorDeck" checklist. Database state: one `solo` organisation, one owner membership, `org_subscriptions` tier free / status none / not grandfathered, 0 students.

### Page sweep
Home, Calendar, Planner, Students, Ledger, Invoices, Insights, Exams, Settings, Org, Tutor and Materials, for solo.tutor, centre.owner, both.tutor and tutor.one, at 1280 and 390: no horizontal overflow, no JS errors. Only HTTP failure: `/api/gcal` 501, which is the local server having no Vercel functions (not a product defect).

## Defects (ranked)
**D1 — Medium — A centre owner's solo screens show the centre's students, lessons and money as if they were the owner's own business.**
- Steps: sign in as centre.owner. Home shows today's lessons for Aiden Tan, Mei Ling Koh and others, "Owed to you $300.00", "$930.00 booked". Students shows "8 active students". Querying as the owner: students 8 and lessons 17, all with the *centre* org id; none are solo.
- Expected: solo screens show only the owner's own solo organisation (CLAUDE.md: "solo tutors' flows must not change", centre money is invoiced by the centre flow). Centre data should not be editable or payable through the solo ledger, WhatsApp reminders or solo invoices.
- Actual: legacy pages filter by `tutor_id`, and centre rows carry `tutor_id = owner`, so they leak into the solo UI. Not tested: whether "Add student" there lands in the centre or the solo org, and whether the free-plan count includes them.
- Screenshots: `centre.owner-land.png`, `owner-students.png` (scratchpad, not committed).

**D2 — Low — Step 7 validation messages contradict each other.** Steps: window days = -3, Save and continue. Expected: one message. Actual: "…must be a whole number, 0 or more. Attendance window must be 1–60 days." (0 allowed vs 1–60). Blank gives only the 1–60 message.

**D3 — Low — Remarks "due" time is shown in the viewer's browser time zone, with no zone label.** The centre's lesson ending 5:00 pm Sat shows "Sun, 22 Nov, 5:00 pm" in Singapore but "1:00 am" in Los Angeles. Expected: the centre's time zone (or a label).

**D4 — Low / design question — A tutor-only login can open the full solo pages by typing the address.** tutor.one has a one-item menu, but /students, /ledger, /settings, /planner, /invoices, /exams and /org open (empty, "No students yet", an invoice-settings form). Only /home and /insights redirect to /tutor. They have their own empty solo organisation, so nothing leaks, but the pages look like a half-set-up solo account.

**D5 — Low / discoverability — A centre owner has no menu entry for their centre.** More shows only Materials and Settings; /org is reached from Settings via a button labelled "Set up a tuition centre" (`settings.html:210`), which is the label for creating a centre, not opening an existing one. (Found from the menu probe and the source, not a screenshot of the Settings page.)

No high-severity defect found.

## Not tested, and why
- Stripe checkout, webhook updating the DEV subscription, customer portal, plan switching: need `api/billing` and `api/stripe-webhook` (Vercel functions); the preview is behind Vercel login. The owner tests these by hand.
- Account deletion and "nothing left" check: needs `api/delete-account`. **The throwaway user and its centre are still in DEV** (see below).
- Centre-setting variants in the My lessons UI: tutors marking late/in-time cancellations, typing a charge, flagging trials, and remarks required. These need a tutor login in a centre configured that way; the only centre tutors are in the demo centre (defaults). I did not change the demo centre's settings. Covered at database level by `tests/sql`; the UI path for those options is untested. The step 7 save/persist of those values was verified in the throwaway centre.
- Replacement-tutor assignment (no screen yet, T3), and parent-contact visibility to tutors (only the default "off" was seen).
- Phone checks beyond the pages swept; Google sign-in and Calendar sync (not on DEV / needs `/api/gcal`).

## Changes I made in DEV (dummy data)
- tutor.one: Aiden Tan lessons today and yesterday marked attended (today's with topics, homework, remarks); Ravi Menon today marked absent, then corrected to attended. Mei Ling Koh Sat 21 Nov left unmarked.
- tutor.two: remarks on the admin-marked Hannah Wee lesson set to "tutor note on admin-marked lesson".
- Throwaway user `t2-throwaway-mwum2aj0@example.test` (dummy; its password is kept out of this public repo and is in the tester's chat only) with its solo organisation and a centre "T2 Test Centre" (setup at step 8, step 7 values changed). **Needs deleting by the owner** (delete from the app on the preview once it can be reached, or per the deletion procedure in the README).
- Nothing else; no demo login was deleted or had its settings changed.

## Decisions needed from the owner
1. D1: should a centre owner's solo screens exclude the centre's data (and what should "Add student" do there)? This affects T3 (staff screens) and T4 (centre invoicing).
2. D4: should tutor-only logins be redirected away from solo pages?
3. Run the Stripe checkout/portal/webhook and account-deletion checks by hand, and remove the throwaway user and "T2 Test Centre".
