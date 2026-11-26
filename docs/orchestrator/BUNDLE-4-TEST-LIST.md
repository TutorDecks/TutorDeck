# Bundle 4 — click-through for the owner (DEV preview only)

**Before you start:** the DEV SQL pack (`docs/orchestrator/dev-apply-pack.sql`, steps in `dev-apply-pack.md`) must be applied to the DEV project, and the `dev` preview must have redeployed. This is the **Test version · dummy data only** site; never use the live address.

**Logins** (all on the preview's sign-in page, email + password; the password is at the top of `db/seed_dev_demo.sql`; there is no Google sign-in on DEV):

| Login | Who they are |
|---|---|
| `centre.owner@example.test` | Owner of Demo Learning Centre |
| `centre.staff@example.test` | Staff with every permission |
| `centre.frontdesk@example.test` | Staff with only "Manage students" |
| `tutor.one@example.test` | Centre tutor (lessons today, to mark, cancelled, old, upcoming) |
| `tutor.two@example.test` | Second centre tutor |
| `both.tutor@example.test` | Solo tutor with 2 students who also teaches at the centre |
| `solo.tutor@example.test` | Solo tutor, free plan, exactly 5 students |

Use a private window per login (or sign out in between). One line per step: **where → what to do → what should happen.** Tick `[ ]` as you go; write any surprise next to the number.

## A. Centre Home and menu (owner, staff, front desk)
1. [ ] Sign in as `centre.owner@` → you land on the **Centre home**. Menu: Home · Timetable · Students · Attendance · Money, then More. Tiles show counts only (lessons today, marked, to mark, no tutor next 14 days, charges to confirm, trials this month, active students). No money amounts on Home.
2. [ ] More → **Centre settings** and **Your centres** are there.
3. [ ] Sign in as `centre.frontdesk@` → Home shows only the student count; the menu is Home · Timetable (look only, no editing) · Students. **No Attendance, no Money.** Typing the Attendance address gives a plain "not available".
4. [ ] Sign in as `centre.staff@` → every tab is there, including Money.
5. [ ] As `centre.staff@` → More → **Your centres** lists Demo Learning Centre; opening it works.

## B. Students (owner / staff / front desk)
6. [ ] Students → search a name (e.g. "Aiden") → results narrow as you type; tabs Active / Ended / Trial / All show counts.
7. [ ] Tap a student → sheet shows details, family, parents with tap-to-call, brothers and sisters, subjects, next lessons. **No money** anywhere on it.
8. [ ] Add student → name, level, a parent's name and phone → Save → the student and their family appear.
9. [ ] On that family add a brother or sister → they appear under the same family.
10. [ ] Edit the student, then **Discontinue** with a "lessons run until" date → moves to Ended. **Bring back** → Active again.
11. [ ] As `centre.frontdesk@` do steps 8–10 → works (they have Manage students).

## C. Attendance (owner / staff)
12. [ ] Attendance → today's lessons; filters Not marked / Marked, by tutor; Day / Week / Month views.
13. [ ] Tap a lesson from **tomorrow** → no marking buttons. Tap one from **today** → Attended / Absent / Late cancelled / Cancelled in time, with optional remarks.
14. [ ] Mark one **Attended** → badge appears. Tap it again → **Correct** needs a reason; the correction saves.
15. [ ] Mark one **Absent** → it now waits in **Charges** (next section) instead of being priced.
16. [ ] Trial: open a lesson sheet → turn on **This is a trial lesson** → Trial badge shows; the **Trial** filter finds it; Home "trial lessons this month" rises.
17. [ ] As `centre.frontdesk@` (no Manage timetable) → can't reach Attendance.

## D. Charges (owner, or staff with Issue invoices)
18. [ ] Attendance → **Charges** tab → lists absent / cancelled lessons that have no charge yet (the demo has some).
19. [ ] Open one → centre's suggestion pre-filled; press **Not charged** (0) or **Full price** → it leaves the queue. Try a figure above the lesson's own price → refused with a plain message.
20. [ ] Tick several → bulk **Not charged** → they all leave. Home "charges to confirm" drops by the same number.

## E. Timetable, weekly slots, reassign (owner / staff with Manage timetable)
21. [ ] Timetable → week view day by day; switch Day / 14-day; filter by tutor and by student. Whole-centre holidays show as a grey band. Lessons with no tutor are amber.
22. [ ] **Weekly slots** view → add a slot (day, time, tutor, student, subject, hourly rate) → it appears. Edit it. Add a second student to make a class.
23. [ ] Press **Create lessons for the next 4 weeks** → a sentence like "12 created, 0 skipped, 2 holidays". Press it again → "0 created" (safe to repeat).
24. [ ] Stop a slot → it leaves the list; lessons already made stay.
25. [ ] A student's sheet → **Assigned tutors** panel: add and remove a tutor; **Online lesson link** can be saved.
26. [ ] Timetable → tap a lesson → **Reassign or cover** → pick another tutor → "Cover this lesson only" → the lesson shows **Covered by …**; a reason is required.
27. [ ] Repeat with "Give this lesson to them" → the lesson moves for good. Try it on a lesson that is already marked → refused.
28. [ ] Organisation settings → turn **Admins can give one lesson to a replacement tutor** off → reassigning is now refused with a plain message. Turn it back on.

## F. Tutor screens (no prices, ever)
29. [ ] Sign in as `tutor.one@` → lands on **My lessons**; menu has just that (plus **Schedule**). **No rate, amount, paid or price anywhere.**
30. [ ] Mark a lesson attended → saved. A tomorrow lesson has no buttons. You can't change someone else's mark.
31. [ ] Open **Schedule** → your own week, ‹ Today › moves between weeks, holidays as a grey band, badges (cancelled / moved / covering / trial / attended). Tap a lesson for its facts and online link. It says "Your centre handles changes: ask an admin". Your weekly slots are listed below. Nothing is editable; no prices.
32. [ ] Sign in as `tutor.two@` → sees only their own lessons and slots, not tutor one's.
33. [ ] Sign in as `both.tutor@` → normal solo menu; **My lessons** and **Schedule** appear under More; the solo pages still show their own 2 students only.
34. [ ] Sign in as `solo.tutor@` → no tutor menu items, no Schedule tab; adding a 6th student shows the upgrade prompt.
35. [ ] As `tutor.one@` open `/settings` → refused (closed to tutor-only logins) but `/tutor-settings` works.

## G. Tutor profile and payout details
36. [ ] `tutor.one@` → My lessons → **Profile & password** → change the display name (try "this centre only" and "all my centres"), add a Singapore mobile number (a bad number is refused), see the login email read-only.
37. [ ] Change password: wrong current password refused; a new one that fails the checklist shows "Still needed …"; a good one works. Sign out and in with it. **Change it back / note it** for later steps.
38. [ ] Payout details: choose PayNow mobile → save → shows masked (•••••4567) with Show / Change / Clear. Try PayNow UEN and bank transfer. A bad number is refused.
39. [ ] **Show** reveals it; Clear removes it.
40. [ ] Sign in as `centre.owner@` → Organisation → Users and permissions → each tutor has a **Payout** line: method and last four digits only; an amber "Changed …" chip for 7 days after the tutor changed it.
41. [ ] **Reveal** asks first, then shows the full number. (It is written to the audit log: who revealed whose.)
42. [ ] Edit `centre.staff@`'s permissions: untick **See tutors' payout details** → sign in as `centre.staff@` → People shows only "provided / not provided", no Reveal. Tick it again.
43. [ ] `tutor.two@` can't see tutor one's payout; tutors see nothing of each other.

## H. Invites (email through Brevo)
44. [ ] Owner → Users and permissions → **Invite someone** with a name and an email at `@tutordeck.com.sg` (previews only email that domain) → the person shows as **Invited just now**.
45. [ ] An invite to any other address is saved but **not emailed** (it is logged "blocked in preview"): that is correct on DEV.
46. [ ] After 24 hours the row shows an amber **Link expired**; **Resend invite** works once, then is greyed out for 10 minutes (and 5 a day).
47. [ ] Open the invite link (when one arrives) → `/reset?welcome=1` uses the sign-up password checklist; a weak or leaked password is refused; a good one signs you in as the new person and links them to the centre.
48. [ ] Needs the Brevo key in the Vercel Preview settings (steps: `docs/orchestrator/T7-owner-steps.md`); without it the invite is saved and no email goes out.

## I. Centre money settings (all "Coming soon" except what is built)
49. [ ] Owner → Centre settings → every money option is there: Deposit (none / fixed / percent …), Late fees, Percentage tutor pay, Charge for trials, **Classes you run**. **Deposit, late fee, percentage pay, make-up credits stay marked "Coming soon"** and can't be switched on to do anything.
50. [ ] Set "Classes you run" to 1-to-1 → group-only options disappear; set to group → they come back. Save a normal setting → saves; an invalid value is refused with a plain message.
51. [ ] **Admins can give one lesson to a replacement tutor** and **Don't generate lessons on centre holidays** work (steps 23, 28); tutors editing their own timetable stays "Coming soon".

## J. Money: Invoice run, payments, credit notes, invoice link (owner, or staff with Issue invoices / Record payments)
52. [ ] Money tab → **Invoice run** → pick a month → preview: who is ready, who is held back ("charge pending: <student>" holds back only that family).
53. [ ] Create drafts → run it again → nothing is added twice. Open a draft → lines, GST once per invoice, discounts/fees from the centre's settings.
54. [ ] **Approve** one, then **approve all** → each gets a gap-free number (prefix DLC) and a due date; an approved invoice can't be edited.
55. [ ] Money → **Invoices & payments** → chips (issued / part-paid / paid / overdue / void) and filters; search works.
56. [ ] Open an invoice → **Record payment** (part payment) → status goes part-paid; pay the rest → paid. Pay too much → kept as family credit (or marked to refund) per the setting.
57. [ ] **Reverse** a wrong payment → the original stays, a reversal appears (never edited).
58. [ ] **Issue credit note** → CN- number, GST by the same rule, reduces what is owed.
59. [ ] **Copy link** → open it in a private window with no login → the public invoice page shows the centre's PayNow QR, lines and total. **Send on WhatsApp** opens WhatsApp with the centre's wording.
60. [ ] Sign in as `centre.staff@` → Money works. Take away **Issue invoices** from a staff member → their Money tab disappears and the page refuses them. Take away **Record payments** → they can see invoices but the payment buttons are gone.
61. [ ] A tutor, a parent or a solo tutor can't open Money or the invoice list at all.

## K. Organisation → Plan (billing; mostly read-only for you)
62. [ ] Owner → Organisation → **Plan** → fee reads **S$100 + S$0.50 per billable student** with examples (98 students = S$150, 250 = S$225, 405 = S$305).
63. [ ] A centre on invoice billing says "Your account is billed by invoice and PayNow"; every centre sees a **Want a hand? Contact us** card with a Contact button.
64. [ ] Plan shows "Billing starts on …", "Pilot: not charged", "Agreed starting number" when set. Setting these (`org_set_billing_method`, `org_set_billing_start`) needs a **TutorDeck platform admin** (a row in `platform_admins` on DEV); skip unless you have one.
65. [ ] The monthly fee job and Stripe are **not** part of this test (production-only job; the Stripe price `centre_student_monthly` needs a S$0.50 replacement before going live: `docs/orchestrator/T30-stripe-steps.md`).

## L. Safety and looks (a quick pass)
66. [ ] On a phone-width window (or your phone) open Home, Students, Attendance, Timetable, Money, My lessons, Schedule: nothing overlaps, buttons are tappable.
67. [ ] Dark mode (More → theme): Home, Students, Money, invoice link look right, text readable.
68. [ ] The "Test version · dummy data only" tab shows on every page.
69. [ ] Solo tutors (`solo.tutor@`, `both.tutor@`) still see Home, Calendar, Planner, Ledger, Invoices, Students exactly as before.

## What to expect and not to worry about
- Tutor sees **no price** anywhere; staff **without Issue invoices** have **no Money tab**; a front-desk login has no Attendance and no Money (Timetable is look-only).
- Still marked **soon** on purpose: deposits, late fees, percentage tutor pay, make-up credits, tutors editing their own timetable, remarks sent to parents, reminders by email, statement matching.
- Anything that looks wrong: note the step number, the login, and a screenshot.
