# DEV fresh demo centre (T52)

**DEV project `tuzxsqkfzrjssnpcoale` only. Never LIVE.** Everything is invented (`@example.test` logins, `+65 8000 41xx` numbers).
Files: `db/seed_dev_demo_fresh.sql` (create) · `db/seed_dev_demo_fresh_down.sql` (undo) · test `tests/sql/dev_seed_fresh_test.sh` (runs at the end of `bash tests/sql/run.sh`).

## Why it exists
The first demo centre drifts (renamed, staff hold every permission, old invoices), and **once a centre is launched, billing-type settings only start on the 1st of next month**. Testers could not try tutor pay, statement matching, four-eyes refunds or make-up credit expiry the same day. "Demo Fresh Centre" is a **second** centre, left in **setup** (the one state where a settings save applies today and may be back-dated), with nothing invoiced yet.

## Run it
1. DEV needs the whole migration chain (bundle 7 pack applied) and `db/seed_dev_demo.sql` (the seed uses the old demo centre only as proof "this is DEV").
2. Supabase (DEV) → SQL Editor → paste the whole file → Run. The last result is **one line**: `SEED FRESH | OK | status=setup … students=8 families=6 slots=8 lessons=… marked=… to-mark=… invoices=0 payments=0` (or `SEED FRESH | FAILED - …`).
3. Running it again changes nothing (the centre is found by its owner login `fresh.owner@`, never by name, so renaming it is fine).
4. It **refuses** (writes nothing) unless the old demo centre exists with only `@example.test` members and no Stripe subscription, and none of the six fresh logins exists already. After creating, if the new centre had a non-`@example.test` member or a Stripe subscription, the whole run rolls back.
5. Undo: `db/seed_dev_demo_fresh_down.sql` removes the whole fresh centre (including anything testers added: invoices, payments, refunds, settings) and the six logins. The old demo centre is not touched. Audit rows stay. Then you can seed again (numbers restart at FRS-1).

## Logins (password `Demo-Pass-2026`)
| Login | Role / permission | Use it for |
|---|---|---|
| `fresh.owner@` | owner | settings, invoice run, approve/pay refunds, tutor pay, statements, launch |
| `fresh.billing@` | staff: **Issue invoices** only | asks for deposit refunds; four-eyes "second person" (invoices side) |
| `fresh.cashier@` | staff: **Record payments** only | records payments, asks for family-credit refunds; four-eyes "second person" (payments side) |
| `fresh.frontdesk@` | staff: Manage students + Manage timetable | students, timetable, make-up bookings/grants |
| `fresh.tutor.one@`, `fresh.tutor.two@` | centre tutors | tutor screen, marking, own pay (if the centre allows) |

## What is in it (dates relative to today)
8 students in 6 families (Foo and Ito are sibling pairs sharing a phone number), each with one weekly slot and assigned to a tutor (tutor.one: Ivy, Isaac, Jasmine, Marcus; tutor.two: Kenji, Kaito, Leah, Nora). Weekly lessons from 6 weeks ago to 2 weeks ahead. Lessons **older than 14 days are marked** (attended; one *absent*, one *cancelled in time*). The **last 14 days and today are unmarked** so tutors/staff mark them after you switch a setting on. No invoices, payments, deposits or refunds. Starting settings: postpaid lessons, family invoices, PayNow, tutor pay "lessons report", prefix `FRS`, no deposit, no late fee, no credits.

## How to launch it, and the setup-mode rule
Sign in as `fresh.owner@` → Organisation / Settings. The centre is in **setup** with every wizard step open. **While it stays in setup every save applies from today** (back-dated saves are allowed, there is no "from the 1st of next month"). Change what you want to test, try it, and only press **Launch** (last step, "Review and launch") if you want to see the launched behaviour; after launch, billing changes wait for the next cycle and the centre can no longer be put back (reset with the undo + seed instead). Invoice runs for a past month read the settings in force on those days: the seed's starting version covers the last 90 days, your saves apply from today.

## Which bundle-7 steps it unlocks
- **Tutor pay** (owner / run_tutor_pay): Settings → Tutor pay → *Full*, add rates, then Money / Tutor pay for this and last month (marked lessons exist; mark the recent ones as the tutors for more).
- **Statement matching**: Settings → Payments → add *Bank statement matching* (custom columns), run Invoices for this month, then upload a made-up CSV in Money → Statements.
- **Four-eyes refunds**: Settings → refunds approved by → *someone other than the person who asked*. The preconditions hold from the start: owner + `fresh.billing@` (issues invoices) + `fresh.cashier@` (records payments). Make a deposit/credit, ask as billing/cashier, approve as the other person. To see the fallback, remove the only holder of *Record payments* (`fresh.cashier@`).
- **Make-up credits and expiry**: Settings → Billing → Make-up credits (*one per missed lesson*) and *credits expire after N days* (say 7). Then, as the owner or the tutor, mark an unmarked lesson from 8–13 days ago *absent*: its credit is earned and already expired the same day. Mark a lesson from 1–6 days ago absent for a live one. (The two lessons already marked absent/cancelled earned nothing because credits were off then.)
- **Deposits, late fees, invoice email, own-pay, data export**: all start from empty, switch on in Settings and they act at once.

## Not covered
No Stripe subscription (by design: the seed refuses one). Parent portal logins are not created. Google sign-in does not exist on DEV: use these email logins.
