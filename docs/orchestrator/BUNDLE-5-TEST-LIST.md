# Bundle 5 — click-through for the owner (DEV preview only)

Only the **new** things since bundle 4: deposits, refunds and family credit (with undo and the four-eyes guard), late fees, slot changes and the People tab, the tutor Settings menu, and tutors moving / cancelling their own lessons. Bundle 4's list (`BUNDLE-4-TEST-LIST.md`) still applies to everything not repeated here. Plus a re-test of **Record payment** (fixed in this bundle).

**Before you start:** the DEV SQL pack for bundle 5 (`docs/orchestrator/dev-apply-pack.sql`, steps in `dev-apply-pack.md`) must be applied to the DEV project (bundle 4's pack must already be there), and the `dev` preview must have redeployed (page version v354). This is the **Test version · dummy data only** site; never use the live address.

**Logins** (same as bundle 4; email + password on the preview's sign-in page; the password is at the top of `db/seed_dev_demo.sql`; no Google sign-in on DEV):

| Login | Who they are | What you use them for here |
|---|---|---|
| `centre.owner@example.test` | Owner of Demo Learning Centre | settings, approving refunds, opening balance, People |
| `centre.staff@example.test` | Staff with every permission | issuing invoices, recording payments, requesting refunds, four-eyes second person |
| `centre.frontdesk@example.test` | Staff with only "Manage students" | proving they see none of the new money screens |
| `tutor.one@example.test` | Centre tutor (Aiden, Mei Ling, Ravi, Sophie) | moving / cancelling lessons, Settings menu |
| `tutor.two@example.test` | Second centre tutor | can't touch tutor one's lessons |
| `both.tutor@example.test` | Solo tutor who also teaches at the centre | menu check |
| `solo.tutor@example.test` | Solo tutor, exactly 5 students | nothing changed for them |

Use a private window per login. One line per step: **where → what to do → what should happen.** Tick `[ ]` as you go; write any surprise next to the number. Money is in **Singapore dollars**, GST in the demo centre is off (unless you switch it on).

## A. Switch the new options on (owner) — do this first
1. [ ] `centre.owner@` → More → **Centre settings** → section for deposits (Money / Billing). Set **Deposit** = *A fixed amount*, **Deposit amount** = S$60, GST on the deposit **off**, **Deposit is invoiced** = *Together with the first lesson invoice* (*Before the first lesson* is greyed "coming soon"), **A deposit can be waived by** = *Staff who issue invoices*, **When a student leaves, TutorDeck suggests** = *Refunding the whole deposit*, **Notice needed** = 0, **Refunds are approved by** = *The owner*. Save → "Saved". The four "top-up / use against unpaid fees / final month" switches stay "coming soon".
2. [ ] Same page, **Late fees**: Late fee **on**, **How often** = *Every month the invoice stays unpaid*, **Late fee is** = *A fixed amount*, amount S$10, **Grace period** = 0 days, **Most late fees one invoice can collect** = 0, **A late fee is added as** = *Its own small invoice* (*A line on the family's next invoice* is greyed "coming soon"), **waived by** = *The owner*. Save.
3. [ ] **Payment due (days after the invoice date)** = 7 (or 0 if you want to see late fees tomorrow; see step 28). Save.
4. [ ] Tutors and lessons: **Who edits the timetable** = *Tutors may change their own lessons (staff are told)*. Underneath appear: *A tutor may move a lesson* (on), *may cancel a lesson in advance* (off, turn it **on**), minimum notice (24 hours), most changes per tutor per month (0 = no limit), *When a tutor changes a lesson* = *Show staff a list*. The four other switches (weekly slots, create lessons, one-off lesson, online link) and *Tutors ask, and an admin approves* are greyed "coming soon". Save.
5. [ ] Choosing *Admins only* again hides all those extra switches; switch back to *Tutors may change…* before section K.

## B. Money: five tabs, deposits, and re-test of Record payment
6. [ ] Owner → **Money** → tabs **Invoice run · Invoices & payments · Deposits · Refunds · Late fees**. The small subtitle under the page name follows the open tab. Left / right arrow keys move between tabs. On a phone (390 px) the tab row scrolls sideways with no vertical scrollbar.
7. [ ] Money → **Invoice run** → pick this month → **Create drafts**. Every student who has **never been invoiced before** gets, besides the lesson invoice, a separate **Refundable deposit** draft of S$60 with **no GST**. (If bundle-4 testing already invoiced everybody, first add a new student in Students with a lesson this month, then run again.) Run again → nothing is added twice. Discard one deposit draft, run again → it comes back at the same S$60.
8. [ ] **Approve** a lesson draft and a deposit draft (or **approve all**) → numbers come from the one gap-free series (prefix DLC), a due date appears; both show in **Invoices & payments**.
9. [ ] Re-test of **Record payment** (the bug fixed in this bundle). Open the deposit invoice → **Record payment** S$20 → status **part-paid**, no "Something went wrong". Record the remaining S$40 → **paid**.
10. [ ] On a lesson invoice: record a part payment → part-paid; record the rest → paid; record **more than is owed** (e.g. S$100 on S$54.50) → the extra is kept as **family credit** for that family. Record two payments one straight after the other without reloading → both work.
11. [ ] **Reverse** one payment → the original stays, a reversal entry appears, the invoice goes back to owing that amount (nothing was edited).
12. [ ] Money → **Deposits**: **Deposits held** counts only money actually received (S$60 once fully paid; a part-paid deposit shows what came in); one row per student with a chip (*held / part-paid / not paid yet / draft / waived*); tap a student → their ledger.
13. [ ] On a student whose deposit invoice is still unpaid → **Waive this deposit** → a reason is required → an unpaid draft is discarded, an issued one is credited for the unpaid rest; the row says *waived*. Sign in as `centre.staff@` → can waive too (Issue invoices); set **can be waived by** = *Nobody* in settings → the button goes. Put it back.
14. [ ] Owner only: Deposits → a student → **Record opening balance** (a deposit collected before TutorDeck) → it appears in Deposits held. `centre.staff@` does **not** see that button.
15. [ ] `centre.frontdesk@` → no Money tab at all; typing `/centre-money` gives a plain "not available".

## C. Refunds and family credit
16. [ ] An invoice of a family that has credit (from step 10) → **Use or refund the family's credit** → **Use credit on an invoice** → pick the amount (up to the invoice's open amount) → **Use credit** → the invoice is paid / part-paid from credit, the family's credit goes down, **no cash** is refunded and it isn't counted as received twice.
17. [ ] Same place → **Refund credit to the family** → amount (more than the family has is refused), a reference (a whole account number, 8+ digits in a row, is refused), a reason → **Ask for approval** → Money → **Refunds** shows it under **Needs action** as *Waiting for approval*. Press the button twice quickly → only one request.
18. [ ] While it waits, the amount is **reserved**: asking to refund or use more than is free is refused with a plain message.
19. [ ] As `centre.owner@` (approver = owner) → Refunds → open it → **Approve** → status *Waiting for someone to pay the family and mark it as paid*. Then **Mark as paid** with a reference → it moves to **Finished**, the family's credit drops only now, the statement shows asked → approved → paid with names and times. A paid refund can't be edited (cancel is only before it is paid).
20. [ ] A student who leaves: Students → pick a student with a paid deposit → **Discontinue** with "lessons run until" = yesterday (all their lessons invoiced, none left as draft or "charge pending"). Deposits → student → **Release or refund the deposit** → the suggestion says *Refund the whole deposit*; change the amounts if you like → **Ask for approval**. If the student isn't ready yet, the message says in plain words what is still waiting (last lesson day not passed / final invoice not issued).
21. [ ] Settings: **Notice needed to get the deposit back** = 14 days, then a student who left with less notice → the suggestion says to keep the deposit; keep it (or part of it, against an unpaid invoice) → a kept deposit is complete when approved and needs no payment. A deposit that carried GST can't be kept against invoices (try with *GST on the deposit* on for a new deposit).
22. [ ] Four-eyes: settings **Refunds are approved by** = *Someone other than the person who asked* → as `centre.staff@` ask for a refund → `centre.staff@` can **not** approve their own request; the owner can. Then the owner asks and `centre.staff@` approves. With *Any staff member who handles that kind of refund* (deposit refunds: staff who issue invoices; family-credit refunds: staff who record payments) that staff member can approve.
23. [ ] `centre.frontdesk@`, tutors and solo tutors see no Refunds tab.

## D. Undo credit or a deposit used on an invoice, and the four-eyes guard
24. [ ] Use credit on an invoice (step 16) → open that invoice → **Undo credit or deposit used** → a reason is required → the credit comes back to the family, the invoice owes the amount again, a new reversal entry appears (nothing edited). Press twice → nothing happens a second time (one reversal per application).
25. [ ] Try to undo when it is not allowed, each with a plain-words reason: a **credit note** was issued on that invoice afterwards; **money was recorded** on it afterwards (reverse that first); for a deposit, the deposit changed afterwards. An invoice that the credit itself paid in full **can** be undone.
26. [ ] Four-eyes guard: owner → Users and permissions → take **Issue invoices** away from every staff member who has it (or switch `centre.staff@` off) while **Refunds are approved by** = *Someone other than the person who asked*. The setting goes back to **The owner** by itself, the owner sees a **Got it** card on Money explaining why (the e-mail copy is "coming soon"), and requests that were waiting can now be approved by the owner. Put the permission back.
27. [ ] With no second approver available the option *Someone other than the person who asked* is greyed with "(needs a second approver)" and the reason under it; the database refuses it too.

## E. Late fees
28. [ ] Money → **Late fees** (owner or staff with Issue invoices): *Late fees waiting for you* lists proposals for lesson invoices that are past their due date (plus the grace). Anything already overdue from bundle-4 testing shows straight away; otherwise come back after the due date (see step 3). Opening the tab twice adds nothing twice.
29. [ ] Open one → shows the invoice, the due date, the amount (S$10, or a percentage of what is **still unpaid** if you switch the type) → **Approve and add to the account** → it becomes its own numbered invoice (late-fee kind) with the day's GST rule, paid like any invoice and counted in the family's balance. **Approve all N** does the rest. Approving twice returns the same invoice.
30. [ ] Another proposal → **Waive this late fee** → a reason is required; it leaves the list; waiving is allowed only for who the setting names (owner / staff who issue invoices).
31. [ ] Pay an invoice that has a proposal → the proposal disappears; reverse that payment → it comes back. Late fees are never proposed on deposit, opening, late-fee or credit-note documents (no compounding).
32. [ ] Set **Grace period** = 30 days → proposals vanish; set a **cap** of S$10 → a second fee on the same invoice is not proposed. Set the repeat to *Never* → none.
33. [ ] `centre.frontdesk@`, tutors, parents see nothing of late fees.

## F. Timetable: slot changes and holidays (owner / staff with Manage timetable)
34. [ ] Timetable → **Weekly slots** → a slot → **Stop this weekly slot** → **Stop from** = a day next week → tick *also remove its future lessons that are not marked, paid or invoiced* → the screen shows **how many lessons will go** before you confirm. After confirming, lessons from that day on that are unmarked / unpaid / uninvoiced are gone; marked, paid or invoiced ones stay.
35. [ ] A one-student slot → **Add a student…** → **Joins from** a day → it becomes a class (one session, all students at the same time). On a class → **Remove…** a student → **Leaves from** a day → their later unmarked lessons go; the others stay.
36. [ ] Save a slot with a tutor for a student who doesn't have that tutor yet → the message says the tutor was **added to the student's assigned tutors**; check the student's sheet → Assigned tutors. Nobody is ever removed. In settings switch off *A weekly slot with a tutor also adds that tutor…* → saving no longer adds them.
37. [ ] **Create lessons**: choose the last day up to **26 weeks** ahead; the button and the message say how many weeks ("… for the next N weeks"). Press it again → "0 created" (safe to repeat).
38. [ ] Holidays: add one **by hand** (a day with lessons on it) → it offers to **cancel the lessons already on those days** (no charge, only unmarked / unpaid / uninvoiced; the count is shown first) → accept → they show cancelled; the marked ones stay.
39. [ ] **People** (owner, or staff with Manage tutors; in the centre's tab row / Organisation area): names, roles, status (active / invited / expired), invite state, and a link to Users and permissions. **No** phone, email or pay shown. `centre.frontdesk@` has no People tab. Old links to `/centre?tab=people` land on the People page.
40. [ ] Sign in as `tutor.one@` → the menu now has **Settings** (opens `/tutor-settings`: profile, password, payout). Sign in as `both.tutor@`: while in the **centre** the menu shows Settings; while in their own solo organisation the menu is exactly as before ("My tutor profile" under More). `solo.tutor@` sees no change at all.

## G. Tutors move, put back and cancel their own lessons
41. [ ] `tutor.one@` → **Schedule** → tap a lesson that starts **more than 24 hours** from now → the sheet shows **Move** and **Cancel lesson** (Cancel only because you switched it on in step 4). No price anywhere.
42. [ ] **Move** → pick another day and a start time → give a reason → **Move lesson** → "Moved to …"; the length is unchanged (so is the price); the lesson shows a *moved* badge. **Put back to usual time** → "Put back to …".
43. [ ] Refusals in plain words (the tutor is never told *why* something is closed beyond "closed"): a lesson **today or inside 24 hours**; one already **marked**, **cancelled**, **paid or invoiced**; one **in the past**; a day that is a **centre holiday**; a time that **clashes with the tutor's own lessons**; and, after setting *Most changes per tutor per month* = 2, the **third** change. (Move + put back + cancel each count as one.)
44. [ ] **Cancel lesson** with a reason → it shows cancelled; **no charge** to the family and **no make-up credit** created. With *A tutor may cancel…* off the button isn't there.
45. [ ] A group lesson moves or cancels **as one**: all students or none (a clash for any student refuses the whole thing).
46. [ ] `tutor.two@` can't move or cancel `tutor.one@`'s lessons and doesn't see them. A lesson of a student who isn't assigned to the tutor is "not found".
47. [ ] As `centre.owner@` or `centre.staff@` → **Timetable** → the lesson carries an amber **Changed by tutor** flag for 7 days → **Home** shows a **Tutor changes** list (needs Manage timetable). `centre.frontdesk@` sees neither. Setting *When a tutor changes a lesson* = off adds nothing for staff to do.
48. [ ] Settings back to *Admins only* → the tutor's Move / Cancel buttons disappear (reload Schedule).

## H. Safety and looks (a quick pass)
49. [ ] At 390 px (phone width): Money (all five tabs), Deposits, Refunds with the refund sheet, Late fees, Weekly slots (stop / add student sheets), People, the tutor's Schedule sheet with Move: nothing overlaps, buttons are tappable, no sideways scroll except the tab row.
50. [ ] Dark mode: Money tabs, Deposits, Refunds, Late fees, People, Schedule sheet are readable.
51. [ ] The "Test version · dummy data only" tab shows on every page.
52. [ ] Solo tutors (`solo.tutor@`, `both.tutor@` in their own organisation) see Home, Calendar, Planner, Ledger, Invoices, Students exactly as before.

## What to expect and not to worry about
- **Deposits are money held for the family, not income**: no revenue figure includes them; they carry no GST unless you switch it on.
- A refund is never one click and never an edit: asked → approved → marked paid. **TutorDeck never sends the money**; it only records it.
- Still marked **coming soon** on purpose: deposit invoiced *before the first lesson*, deposit top-up, using a deposit against unpaid fees at the owner's request, deposit as the final month, late fee as *a line on the next invoice*, *Tutors ask, and an admin approves*, tutors editing weekly slots / creating lessons / one-off lessons / the online link, e-mail to the family about a tutor's change, e-mail to the owner when four-eyes falls back (the in-app card works), moving or adjusting a deposit between students, a numbered refund statement document.
- Late fees need an overdue invoice: with the default 7-day due date you will mostly see them a week after you issue invoices. To see them tomorrow set **Payment due** to 0 days (step 3) and issue invoices today.
- Anything that looks wrong: note the step number, the login, and a screenshot.
