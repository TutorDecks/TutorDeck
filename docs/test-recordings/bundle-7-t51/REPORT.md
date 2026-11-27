# Bundle 7 tester T51: results (DEV preview, build v357, dummy data only)

Tester: automated Playwright run as a human would click. Preview: tutordeck-git-dev (DEV Supabase). No LIVE project touched. Date on the app: 28 Nov 2026 (SGT).
Clips (1280x720 MP4, each under 1 MB): `clips/`. Screenshots: `screenshots/`.

## Important context for reading the results
- Billing-type settings only start on the 1st of next month (here 1 Dec 2026). I saved: Tutor pay = Full, Bank statement matching on, Make-up credits earn rule + 30-day expiry, Refunds = four-eyes. Until 1 Dec the screens still behave as before, so those flows could not be run (BLOCKED, not failed).
- This DEV is not the pristine seed: the centre is called "learn w me" (not Demo Learning Centre); Demo Billing Staff and Demo Cashier each hold all 8 permissions (the list says one each); a notice "Refund approval is back to the owner approves" was already showing; extra students (annie, dumbass...) and Nov invoices DLC-1..9 from earlier testing existed. Settings of section A were not applied beforehand (tutor pay was "report only", email off, tutor link/one-off switches off); I applied them.

## Results (PASS / PARTIAL / BLOCKED / NOT RUN), one line of evidence each
| # | Result | Evidence |
|---|---|---|
| 1-4 | PARTIAL | Saved tab 7 switches, email mode "A person sends them", tutor pay Full (starts 1 Dec), receipts + reminders on. Deposit/late-fee settings not re-checked. |
| 5 | PARTIAL | Four-eyes saved and read back as "Someone other than the person who asked". The "0 saves at once" part not run. |
| 6, 7, 9-14 | NOT RUN | |
| 8 | PARTIAL | Box lists plain reasons why students get no deposit (already has one / invoiced before / only trial or unmarked lessons). New-student case not run. |
| 15 | PASS | Invoice run Nov: 5 families + 7 deposits created as drafts, Approve all issued 12; numbers 1-47 all present, no gaps (clips 01, 02). Discard→re-run: see finding 4. |
| 16 | PASS | Mrs Teo DLC-12 owed S$90, recorded the rest, status paid (clip 03). Overpay S$250 on S$210 invoice: "S$40 kept as credit for the family" (clip 05). |
| 17 | PASS | Use S$25 credit on DLC-31 (owed S$180→S$155), undo needs a reason, credit returned, second undo gone (clips 06a, 06). Undo-after-credit-note/payment refusals not run. |
| 18 | PASS (partial) | 4 proposals; paying Teo removed hers (3), reversing the payment brought it back (4); approved Lim (→ own invoice), waived Rahman with a reason (clips 04, 07). Grace/cap not run. |
| 19 | PARTIAL | Deposits tab renders held / to collect / waived chips (see finding 5). Release/waive not run. |
| 20 | PASS (partial) | Quek: Approve → "Approved · to pay" → Mark as paid: 11-digit reference refused ("Never a full bank account or PayNow number"), proper reference accepted → Paid (clips 08, 09). Staff-refusal not run. |
| 21 | BLOCKED | Starts 1 Dec; also staff accounts hold all permissions. |
| 22, 24-30 | NOT RUN | "Add past lessons" button is present on a student's sheet. |
| 23 | PARTIAL | centre.frontdesk menu = Home, Timetable, Students only (no Money). |
| 31 | PARTIAL | Demo Tutor One S$50 per lesson saved (needs confirm "start in the past"); percentage 150% refused: "must be between 0% and 100%" (clip 12). Student rate not run. |
| 32, 33 | BLOCKED | Pay list says "Report only" until Full pay starts 1 Dec. |
| 34 | PARTIAL | tutors have no Tutor pay entry. Direct URL not tried. |
| 35-39 | BLOCKED | Same cause; tutor menu has no "Your pay" yet. |
| 40 | PASS | tutor.one Add a lesson: student list limited to assigned, no price field, 3 Dec added "Lesson added for Thu 3 Dec." (clip 16). The refusal inside 24 h only seen as hint text. |
| 41-50 | NOT RUN | |
| 51 | PARTIAL | Six templates + "Past lessons: Later" listed. Download content not checked. |
| 52 | PASS | Error files: 3 problems, matching planted.json (students L2 family_ref, students L5 start_date, tutors L3 phone), each with fix text. Good files: "All files pass", 8 students/3 tutors/12 weekly lessons/0 emails sent, Import now off until consent. |
| 53 | PASS | Imported ("8 students, 3 tutors, 12 weekly lessons"); choosing the same files again: "Nothing new would be added. 23 rows are already in TutorDeck" (clip 18). |
| 54 | NOT RUN | Undo link is present. |
| 55-57 | BLOCKED | Statements tab says "Bank statement matching is off" until 1 Dec (screenshot stmt-err.png). |
| 58 | PASS | Email mode saved as staff send; Email tab shows counts and limits. |
| 59 | PARTIAL | Guardian email added (example.test, so a preview cannot really send); sheet shows masked "k***@e***.test"; queue returned queued:1. See finding 3. |
| 60 | PARTIAL | Email tab loads (counts, "Queue all unsent invoices"). Cancel/send log not run. |
| 61 | PARTIAL | Earn rule saved; expiry shows "Never expires" until 1 Dec. |
| 62 | PARTIAL | Marked cancelled in time → exactly 1 owed credit; Book make-up works (refuses end before start: "The lesson must end after it starts"), credit → Booked (clips 13, 14). Used/remove/take back not run. |
| 63 | PASS | Export ZIP (48 files) incl. tutor_requests.csv, payout numbers masked (•••••9999), README explains masking (clip 17). Full-number tick not run. |
| 64-66 | NOT RUN | Menus read as text only; icons not compared. Solo/both menus look as expected (Home, Schedule, Students, Money). |
| 67 | PARTIAL | tutor.one Schedule List \| Calendar toggle works; 390 px list view fine (screenshots). Swipe and ?d= link not run (clip 15). |
| 68 | PASS | Search "late", "zoom", "salary", "reminder": each shows the setting, its tab and current value (clip 11). |
| 69 | PARTIAL | Hidden settings say what to turn on first ("Set 'Late fee is' to ..."). Scroll/highlight not checked. |
| 70 | PARTIAL | 19 pages at 390 px (owner, tutor.one, solo.tutor): no horizontal overflow, "Test version" tab on all. Dark mode not run. |
| (extra) | PASS | Credit note: S$20 on DLC-7 (owed S$60→S$40), CN-DLC-3 issued after a confirm (clip 19). |

Counts: PASS 12 (incl. credit note) · PARTIAL 20 · BLOCKED 11 (21, 32, 33, 35-39, 55-57) · NOT RUN the rest.

## Findings (for bundle 8; nothing was fixed)
1. **Statements / Email tab, raw error if clicked too early.** Where: Money → Statements or Email tab clicked right after the page loads. Expected: tab loads or friendly message. Actual: "invalid input syntax for type uuid: "null"" / "Something went wrong". A clean load shows the right message. Severity: cosmetic (race). Screenshot: none (seen in page text).
2. **Undo sheet keeps a stale error.** Where: Invoice → Undo credit or deposit used. I pressed Undo with no reason ("Say why"), then typed a reason: the red "Say why. The reason is kept in the record." stays on screen next to the confirm dialog. Expected: error clears. Severity: cosmetic. Screenshot: f3-f-undone.png.
3. **Email invoice gives no feedback.** Where: invoice → Email invoice. With the only guardian not ticked, pressing "Email invoice DLC-1 to 1 person" did nothing at all (no email queued, no message) although the hint says the first guardian is used if none is ticked. After ticking, the call queued (queued:1) but no "Queued for 1 email" message was visible 1-4 s later and the Email tab showed nothing waiting right after the first press. Severity: should-fix. Clip: 10-invoice-email-queue.mp4.
4. **A discarded deposit draft gets stuck.** Where: Invoice run → open a deposit draft → Discard (reason). Expected (step 15): run again and it comes back. Actual: the header read "0 invoices ready", there was no Create drafts button, and the Deposits tab still lists Anya Pillai as "Invoice not issued yet · Draft invoice S$60"; the Invoice run says every such student "already has a deposit". I could not re-raise it. Severity: should-fix. Clip: 02. Screenshot: f1-e-issued.png.
5. **Deposits tab shows a refunded deposit as "to collect".** Qian Yu Tan's deposit refund is Paid (S$60) but the Deposits tab lists "Mr Tan · S$60.00 to collect · DLC-30 · Not paid yet" while Invoices shows DLC-30 "Paid in full". Expected: refunded / nothing to collect. Severity: should-fix. Screenshot: none (page text).
6. **Make-up credit earned on a trial lesson.** Dina Rao's 6:30 lesson sheet said "This is a trial lesson"; marking it "Cancelled in time" earned a credit. Question for the owner: should trial lessons earn credits? Severity: should-fix (decision). Screenshot: f9-e-refused.png shows the credit card.
7. **Refund rule text vs setting.** Refund sheet said "Keep it against unpaid invoices, refund the rest" while the list (step 1) expects "Refund the whole deposit". DEV setting differs from the list, not necessarily a bug. Severity: info.
8. **Import error wording.** Each problem reads "Error is not a real date." / "Error is not in families.csv.": an "Error" prefix reads oddly. Severity: cosmetic. Screenshot: f13-b-good.png (clean-file view).
9. **Test environment drift.** See context above (centre name, staff permissions, earlier invoices, section A settings not applied). Severity: info; makes steps 21 and 24 impossible as written.
10. **Settings starting next month blocks same-day testing.** Tutor pay, statements, four-eyes and make-up options cannot be tested the day they are saved. Consider a "use a fresh centre in setup mode" shortcut in the seed. Severity: info.

## Not done
No video of steps blocked or not run. Tutor pay, Your pay, bank statements, four-eyes enforcement and email sending need 1 Dec (or a new centre) and, for sending, a Brevo key. Dark mode and swipe not tested.
