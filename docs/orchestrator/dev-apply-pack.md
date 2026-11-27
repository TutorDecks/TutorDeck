# DEV apply pack — test bundle 6 (T46)

**For the DEV Supabase project `tuzxsqkfzrjssnpcoale` only. Never LIVE.** Apply it **before** you test bundle 6 on the `dev` preview: the new pages call database functions that DEV does not have yet.

**What DEV must already have:** the seven standard migrations, **bundle 4's pack** (20 migrations + two demo staff logins) **and bundle 5's pack** (`reassign_link`, `payment_fix`, `centre_deposits`, `centre_refunds`, `centre_late_fees`, `centre_credit_undo`, `slot_changes`, `tutor_moves`). This pack creates **no logins** and changes no row of data.

1. Supabase (DEV project) → SQL Editor → New query.
2. Paste the **pre-check** (the first block of `dev-apply-pack.sql`, from the top down to the line `-- Safety stop`) and Run. You should see:
   - 7 `present` lines for the standard migrations, 20 `bundle 4: … present` lines and 8 `bundle 5: … present` lines (each names one object only that migration creates; `money_settings`, `reassign_link` and `payment_fix` are checked by looking inside the function they replace);
   - `demo logins from bundle 4 (information only) | 7 of 7`;
   - `NEW OBJECTS ALREADY THERE | N of 144 (…)`: only information. On a DEV that has not had this pack it is a small number (6 on the throwaway test); a re-run shows 144;
   - `OVERALL | ready`, or `NOT READY - fix the MISSING lines first`.
3. Paste the **whole** file and Run. The editor runs it as one batch, so it is all-or-nothing: if something fails nothing is kept, and the error line number points into the file; search upwards for the nearest `### PART` line to see which migration it was. A database without the organisation tables (LIVE today) or without bundles 4 and 5 is stopped by the safety stop before anything changes.
4. The last result is the post-check: 144 `present` lines (tables and functions) and `OVERALL | OK - all 144 objects present`.
5. Running it again is safe and changes nothing.

## What is in it (the order is read from `tests/sql/run.sh` by `tools/build-dev-pack.py`)

| Part | Migration | Branch | Size | What it is |
|---|---|---|---|---|
| 1 | tutor_own_lessons | t6-3-tutor-own-lessons | 760 lines | tutors add their own one-off lessons and weekly slots, "Create lessons", price pending (centre option); replaces `centre_invoice_run_rows` (one `when` line) |
| 2 | import | t33-i1-stage-a | 610 lines | centre import stage A: dry run, commit, undo, history, the "billing starts from" setting; adds `students.online_link`, `students.start_date`, `recurring_slots.taught_by` |
| 3 | centre_tutor_pay | t4-s7-tutor-pay | 738 lines | tutor pay: effective-dated rates, monthly pay list, adjustments, payments (owner and staff with *Run tutor pay* only) |
| 4 | statement_matching | t34-m0-matching | 640 lines | bank statement matching: mappings, batches, lines, rules A–D, confirm, undo, payer links |
| 5 | invoice_email | t7-3-invoice-email | 822 lines | invoice / receipt / reminder emails: queue, append-only send log, caps, bounced addresses, billing contacts |
| 6 | makeup_credits | t18-4-makeup-credits | 755 lines | make-up credits: earn once, book, unbook, expiry, price rule; replaces `centre_invoice_run_rows` (skips free make-ups) |
| 7 | org_export | t35-e-export | 284 lines | centre data export (owner only): catalogue of 46 exported tables and 5 excluded ones, each with a reason, paged reads, audit |

Total about 424 KB (4,850 lines). Sizes of the files themselves: 66 KB, 57 KB, 64 KB, 55 KB, 68 KB, 66 KB, 26 KB.

### Order matters (three files replace the settings check, two replace the invoice run)
- `org_validate_settings(jsonb)` is **replaced by `import`, `invoice_email` and `makeup_credits`** (and the organisation-aware wrapper by `statement_matching`). Each of those files, as merged for this bundle, carries the **cumulative** version: `tutor_moves`' check + the import's `billing.starts_from` rule, then + the email rules, then + the make-up credit rules. Applied in the order above nothing is lost; the undo file of each puts the previous link back (so undoing `makeup_credits` leaves the email rules). `tests/sql/bundle6_chain_test.sql` proves this at both ends of the chain.
- `centre_invoice_run_rows` is replaced by `tutor_own_lessons` (the *charge pending* line) and then by `makeup_credits` (the *free make-up* line, built on the first). `makeup_credits` must stay after `tutor_own_lessons`.
- `org_export` goes last; it needs `centre_billing_method` and `centre_billing_start` (bundle 4) and `tutor_payout`'s masking function (bundle 4). Its catalogue lists every table that has an organisation column, so a table nobody lists fails the test.

## How it was tested (throwaway Postgres, never DEV)
- `PGTZ=Asia/Singapore bash tests/sql/run.sh`: baseline → all migrations in order, each applied twice with its own test (4,852 PASS lines), the bundle-6 set undone in reverse (each undo twice), applied again, undone again (the chain test runs at both states), then every undo of the older chain, ending with "undo restores the baseline exactly" and "migration re-applies after undo". (Needs `PGTZ=Asia/Singapore` between 16:00 and 24:00 UTC.)
- **A DEV-equivalent database** (baseline + the 7 standard + all 20 of bundle 4 + all 8 of bundle 5 + the whole `db/seed_dev_demo.sql`, i.e. what DEV holds after bundle 5's pack): pre-check said `ready` (7 + 20 + 8 present, 7 of 7 logins), the pack ran, the post-check said `OVERALL | OK - all 144 objects present`; the pack ran a **second** time with an identical schema fingerprint (columns, policies, triggers, constraints, and every function's full text and grants).
- The same fingerprint was compared with a fresh database where every migration was applied once in `run.sh` order: **identical** (`049f9cda…`).
- A database with only the seven standard migrations: the pre-check lists 28 MISSING lines (the 20 + 8 of bundles 4 and 5) and the pack stops at the safety stop with nothing changed. A LIVE-shaped database (no organisation tables) fails the pre-check on the first line.
- `node --test tests/*.test.js` includes `tests/migrations-safeupdate.test.js` and `tests/sql-safeupdate.test.js` (no `DELETE` or `UPDATE` without `WHERE` inside any migration function: the Supabase API layer refuses it with SQLSTATE 21000) and `tests/dev-pack.test.js` (fails when this file is out of date).
- I did **not** run anything on DEV or LIVE (no tool here reaches project `tuzxsqkfzrjssnpcoale`).

## Undo (newest first; each `_down` file is in `db/`)
`org_export`, `makeup_credits`, `invoice_email`, `statement_matching`, `centre_tutor_pay` (**deletes the pay records**), `import` (imported students, families and lessons **stay**; the import bookkeeping tables, the functions, the two student columns `online_link` / `start_date` and the billing-start rule go), `tutor_own_lessons`. Always strictly newest first.

## Rebuilding the pack
`python3 tools/build-dev-pack.py` (and `node --test tests/dev-pack.test.js` fails when the file is out of date).
