# DEV apply pack — test bundle 4 (T40)

**For the DEV Supabase project `tuzxsqkfzrjssnpcoale` only. Never LIVE** (it creates two demo logins with a known password). Apply it **before** you test the bundle on the `dev` preview: the pages call database functions that do not exist on DEV yet.

1. Supabase (DEV project) → SQL Editor → New query.
2. Paste the **pre-check** (the first block of `dev-apply-pack.sql`, from the top down to the line `-- Safety stop`) and Run. Every line should say `present`, and the last line `ready`. The line "NEW OBJECTS ALREADY THERE (of 119)" shows `4` on a normal DEV: four existing functions that the pack replaces (`org_validate_settings`, `org_create_centre`, `org_invite`, `org_update_member`). Anything `MISSING` has to be fixed first.
3. Paste the **whole** file and Run. The editor runs it as one batch, so it is all-or-nothing: if something fails nothing is kept, and the error line number points into the file; search upwards for the nearest `### PART` line to see which migration it was.
4. The last result is the post-check: 119 `present` lines (tables and functions) and 7 demo-login lines, then `OVERALL | OK - all 119 objects and 7 demo logins present`.
5. Running it again is safe and changes nothing.

## What is in it (the order is read from `tests/sql/run.sh` by `tools/build-dev-pack.py`)
DEV already has: baseline, org_foundation, billing, attendance, tutor_access, org_delete, function_lockdown, org_separation. The pack adds, in this order:

| Part | Migration | Branch |
|---|---|---|
| 1 | staff_home | t3-1-staff-home |
| 2 | staff_students | t3-2-students |
| 3 | staff_attendance | t3-3-attendance |
| 4 | staff_charges | t3-4-charges |
| 5 | staff_trials | t3-5-trials |
| 6 | staff_timetable | t3-6-timetable |
| 7 | staff_slots | t3-7-slots |
| 8 | staff_reassign | t3-8-reassign |
| 9 | tutor_schedule | t6-1-tutor-schedule |
| 10 | money_settings | t4-s0-settings |
| 11 | centre_money | t4-s1-tables |
| 12 | centre_invoice_run | t4-s2-invoice-run |
| 13 | centre_payments | t4-s3-payments |
| 14 | invites | t7-2-invites |
| 15 | fee_050 | t30-fee-050 |
| 16 | centre_billing_method | t31a-centre-invoice-billing |
| 17 | centre_billing_start | t36-billing-start |
| 18 | tutor_profile | t24c-1-profile |
| 19 | tutor_payout | t24c-2-payout |
| 20 | payout_permission | t24c-3-payout (the "payout-admin" branch) |
| 21 | demo staff logins `centre.staff@` and `centre.frontdesk@example.test` | db/seed_dev_demo.sql (staff block only; needs the Demo Learning Centre already on DEV, which it is) |

Not in the pack: the tutor-leave migration (t24c-5, never built).

## How it was tested (throwaway Postgres, never DEV)
- Rebuilt a "DEV-equivalent" database: baseline + the 7 standard migrations + the demo seed as it was before the staff logins (5 demo users). Pre-check said `ready`. Applied the pack **twice**: the second run changed nothing (schema fingerprint identical), post-check `OK`, 119 objects and 7 logins.
- Same again on a database where every migration had already been applied one by one (the pack on top of everything): identical fingerprint, post-check `OK`.
- A fresh database with all migrations, then the **whole** `db/seed_dev_demo.sql` twice: 7 demo users, no error.
- Then the complete `bash tests/sql/run.sh` (all 27 migrations, each applied twice, each with its own test, then every undo, ending with "undo restores the baseline exactly"), and all node tests.
- Test-only extra shim `tests/sql/pack_shim.sql` (not used by `run.sh`): gives the throwaway database the Supabase auth columns and `extensions.crypt` that the demo seed needs.
- I did **not** run anything on DEV or LIVE (no tool here reaches project `tuzxsqkfzrjssnpcoale`).

## Undo (newest first; each `_down` file is in `db/`)
`payout_permission`, `tutor_payout`, `tutor_profile`, `centre_billing_start`, `centre_billing_method`, `fee_050`, `invites`, `centre_payments`, `centre_invoice_run`, `centre_money`, `money_settings`, `tutor_schedule`, `staff_reassign`, `staff_slots`, `staff_timetable`, `staff_trials`, `staff_charges`, `staff_attendance`, `staff_students`, `staff_home`. Demo logins: `delete from auth.users where email in ('centre.staff@example.test','centre.frontdesk@example.test')`.

## Rebuilding the pack
`python3 tools/build-dev-pack.py` (and `node --test tests/dev-pack.test.js` fails when the file is out of date).
