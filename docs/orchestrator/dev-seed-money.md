# DEV money demo seed (T47)

**DEV project `tuzxsqkfzrjssnpcoale` only. Never LIVE.** Everything is invented (@example.test logins, `+65 8000 …` numbers, no customer names or prices).
Files: `db/seed_dev_demo_money.sql` (create) · `db/seed_dev_demo_money_down.sql` (undo) · test `tests/sql/dev_seed_money_test.sh` (runs at the end of `bash tests/sql/run.sh`).

## Run it
1. DEV must already have `db/seed_dev_demo.sql` and the bundle 4 + 5 migrations (the seed refuses otherwise).
2. Supabase (DEV) → SQL Editor → paste the whole file → Run. The last result is **one line**: `SEED | OK | …` (or `SEED | FAILED - …`).
3. Running it again changes nothing (marker student *Zoe Lim*, id `…0e0101`) and prints the same line.
4. The seed **refuses** (writes nothing) unless exactly one centre has `centre.owner@` as owner and `tutor.one@` + `tutor.two@` as tutors, every member of it is an `@example.test` login, and it has no Stripe subscription.
5. Undo: run `db/seed_dev_demo_money_down.sql`. It removes only the 26 seed students (ids `…0e0101`–`…0e0135`) and everything hanging from them, the settings versions marked `data.seed_money = "t47"`, the number counters (only if no numbered document is left), and the two extra staff logins. Audit rows stay (append-only). Money rows are removed the way the app removes a whole organisation (session flag `td.deleting_org`), narrowed to those rows. Then you can run the seed again; numbers restart at DLC-1.
   Note: invoices you made yourself for the *old* demo students (Aiden, Mei Ling …) are not touched by the undo.

## Logins (password `Demo-Pass-2026`)
| Login | Use it for |
|---|---|
| `centre.owner@` | everything: invoice run, approve/pay refunds (setting = owner approves), waive, late fees, settings |
| `centre.staff@` | all 8 staff permissions (existing) |
| `centre.billing@` (new) | *Issue invoices* only: asks for deposit refunds |
| `centre.cashier@` (new) | *Record payments* only: asks for family-credit refunds |
| `tutor.one@` | the tutor tests (category 5) |

## What it creates (dates are relative to today, so any day of the month works)
1. **Never invoiced, this month** (attended, non-trial): Lena + Leo Fong (siblings), Anya + Arjun Pillai (siblings), Harpreet Gill, Nadia Hassan, Danish Ismail. Kai Seng Yeo has one *trial* lesson (never billed, no deposit). Run **Invoices → this month**: 7 lesson drafts (5 families) and 7 S$60 deposit drafts for these students (more if the older demo students also have marked lessons).
2. **Issued, unpaid, past due** (issued last month, due 7 days later; late fee S$10/month, grace 0 → **4 late-fee proposals** waiting in Late fees): Lim family (Zoe + Zane, one family invoice 2 × deposit), Caleb Chua, Mia Teo (**part payment**: half paid), Irfan Rahman. Rahman also holds **S$25 family credit** and has this second unpaid invoice → try *Use credit* and its undo. Wendy Wong holds S$90 credit (S$100 less a S$10 paid refund).
3. **Deposits:** *paid + left*: Noah Pang (no refund asked yet: try *Release deposit*), Olivia Quek, Pranav Reddy, Qian Yu Tan, Rina Sim (all left last month, every lesson invoiced). *Part-paid* (S$30 of S$60): Ben Ng. *Invoice unpaid*: the Lims, Caleb Chua, Mia Teo. *Waived*: Uma Varma (waived while still a draft).
4. **Refunds, every stage.** Deposit: Quek = requested, Reddy = approved, Tan = paid, Sim = cancelled (asked by `centre.billing@`). Family credit (Wong): requested S$10, approved S$10, paid S$10, cancelled S$5 (asked by `centre.cashier@`). The setting is **owner approves**; staff are refused when they try.
   **Four-eyes** preconditions hold (owner + staff who issue invoices + staff who record payments). To use it: Settings → refunds approved by → *someone other than the person who asked*.
   **Alternate case (fallback):** with four-eyes saved, remove or switch off **both** people who hold *Record payments*: `centre.cashier@` and `centre.staff@` (removing only one keeps four-eyes). Credit refunds fall back to "owner approves" and the owner gets a notice. (Deposit refunds need *Issue invoices*: `centre.billing@` + `centre.staff@`.)
5. **Tutor tests (`tutor.one@`):** a **class** "P6 Math class" with Aaron Lee + Bella Ng (day +3, +10); future 1-to-1 lessons for assigned Cyrus Ho (+2, +4, +9) and Dina Rao (+6, +13; and tomorrow 06:30, which is inside the 24 h notice most of the day: expect "TOO_LATE"). **Evan Soh** has a lesson (+5) but is *not assigned* to tutor.one: cancelling it is refused ("not found").
6. **Settings** (new effective-dated versions, saved with `org_save_settings`): deposit fixed S$60 with the first lesson invoice, refund approver owner, late fee on (monthly, fixed S$10, grace 0), payment due 7 days, tutors may move and cancel own lessons (`tutors_direct`, notice 24 h, no monthly limit). If bundle 6 is on the database the make-up credit settings (one per missed lesson) are saved too; **bundle 6 is not on DEV yet, so this part was not exercised.**

## How it was made (and the three deliberate differences)
Through the app's own functions as the right demo login (`request.jwt.claims`): `centre_invoice_run_create_drafts`, `centre_deposit_waive`, `centre_record_payment`, `centre_deposit_refund_request`, `centre_credit_refund_request`, `centre_refund_approve/pay/cancel`, `centre_late_fee_list`, `staff_mark_attendance`, `staff_set_student_end`, `org_save_settings`. So numbering (DLC-1…), GST, guards and audit are the app's. Differences: (1) **past invoices** are issued with the guard's own `draft → issued` UPDATE but with `issue_date`/`due_date` given (no app function issues "as of last month"); (2) **settings are back-dated** by putting the centre in setup for the save (the only state that allows it) so the past invoices and late fees read the demo's settings; (3) students and lessons are inserted directly (households from the shared phone number, as the app groups siblings).
