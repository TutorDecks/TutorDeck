# DEV apply pack — test bundle 5 (T44)

**For the DEV Supabase project `tuzxsqkfzrjssnpcoale` only. Never LIVE.** Apply it **before** you test bundle 5 on the `dev` preview: the new pages call database functions that DEV does not have yet.

**What DEV must already have:** the seven standard migrations **and bundle 4's pack** (the 20 migrations of `dev-apply-pack` for bundle 4, plus its two demo staff logins). The orchestrator also applied `migration_payment_fix.sql` by hand; this pack repeats it harmlessly (every part is idempotent). This pack creates **no logins** and needs no demo-centre lookup any more.

1. Supabase (DEV project) → SQL Editor → New query.
2. Paste the **pre-check** (the first block of `dev-apply-pack.sql`, from the top down to the line `-- Safety stop`) and Run. You should see:
   - 7 `present` lines for the standard migrations and 20 `bundle 4: … present` lines (one per bundle-4 migration, each naming one object only that migration creates; `money_settings` is checked by looking inside the `org_validate_settings` function, because it only replaces it);
   - `demo logins from bundle 4 (information only) | 7 of 7`;
   - `NEW OBJECTS ALREADY THERE | N of 91 (…)`: only information. The orchestrator's `payment_fix` already counts, so a DEV that has not had the rest shows a small number (about 17 on the throwaway test); a re-run shows 91;
   - `OVERALL | ready`, or `NOT READY - fix the MISSING lines first`.
3. Paste the **whole** file and Run. The editor runs it as one batch, so it is all-or-nothing: if something fails nothing is kept, and the error line number points into the file; search upwards for the nearest `### PART` line to see which migration it was. A database without the organisation tables (LIVE today) or without bundle 4 is stopped by the safety stop before anything changes.
4. The last result is the post-check: 91 `present` lines (tables and functions) and `OVERALL | OK - all 91 objects present`.
5. Running it again is safe and changes nothing.

## What is in it (the order is read from `tests/sql/run.sh` by `tools/build-dev-pack.py`)

| Part | Migration | Branch | Size | What it is |
|---|---|---|---|---|
| 1 | reassign_link | b4-fix | 108 lines | reassign keeps the old tutor's link when they still teach the student (B4-FIX) |
| 2 | payment_fix | b4-fix | 102 lines | "Record payment" fix: `delete … where true` (already on DEV; repeated harmlessly) |
| 3 | centre_deposits | t4-s4-deposits | 770 lines | refundable deposits: ledger, deposit invoice with the first run, waive, opening balance, opening invoice kind, `students.start_date` |
| 4 | centre_refunds | t4-s5-refunds | 817 lines | refunds and family credit: request / approve / pay, use credit on an invoice, forfeit rule, GST |
| 5 | centre_late_fees | t4-s6-late-fees | 380 lines | late-fee proposals (approve / waive, monthly repeat) |
| 6 | centre_credit_undo | t4-s5b-credit-undo | 368 lines | undo of credit or deposit used on an invoice, four-eyes guard with automatic fall-back, notices |
| 7 | slot_changes | t3-9-timetable-nav | 474 lines | stop a slot from a day, class members, 26-week lessons, cancel lessons on a holiday, People list |
| 8 | tutor_moves | t6-2-tutor-moves | 409 lines | tutors move, put back and cancel their own lessons (centre option) + "Tutor changes" list |

Total about 325 KB (3,640 lines). Money settings (`money_settings`) are already on DEV from bundle 4, so there is nothing to add for them; the pre-check proves it.

### Order matters in two places (both are handled)
- `centre_credit_undo` re-creates `org_create_centre`. Its first version hard-coded the old **S$0.40** fee and would have undone `fee_050` on DEV. **Fixed in this bundle:** it now reads `org_default_centre_plan()` (the S$0.50 default from `fee_050`), so it must come after `fee_050`, which DEV has. Its undo file puts the `fee_050` version back, not the 40c one.
- `tutor_moves` goes last (it replaces the one-argument `org_validate_settings` that `centre_credit_undo`'s organisation-aware validator calls) and the `slot_changes` People list reads the invite send log from `invites` (already on DEV).

## How it was tested (throwaway Postgres, never DEV)
- Database clock: `tests/sql/run.sh` needs `PGTZ=Asia/Singapore` when run between 16:00 and 24:00 UTC (an older money test compares with `current_date`). This applies to every earlier bundle too; it passes without it before 16:00 UTC.
- `PGTZ=Asia/Singapore bash tests/sql/run.sh`: baseline → all 35 migrations in order, each applied twice with its own test (3,326 PASS lines), then every undo, ending with "undo restores the baseline exactly" and "migration re-applies after undo".
- **A DEV-equivalent database** (baseline + the 7 standard + all 20 of bundle 4 + `payment_fix` + the whole `db/seed_dev_demo.sql`, i.e. exactly what DEV holds, without `reassign_link`): pre-check said `ready` (7 + 20 present, 7 of 7 logins), the pack ran, the post-check said `OVERALL | OK - all 91 objects present`; the pack ran a **second** time with an identical schema fingerprint (columns, policies, triggers, constraints and the md5 of every function body).
- The same fingerprint was compared with a fresh database where all 35 migrations were applied once in `run.sh` order: **identical**. So the order on DEV (bundle 4, then this pack) gives the same functions as the tested order.
- A database with only the seven standard migrations: the pre-check lists 21 MISSING lines and the pack stops at the safety stop with nothing changed.
- `node --test tests/*.test.js` includes `tests/migrations-safeupdate.test.js` and `tests/sql-safeupdate.test.js` (no `DELETE` or `UPDATE` without `WHERE` inside any migration function: the Supabase API layer refuses it with SQLSTATE 21000) and `tests/dev-pack.test.js` (fails when this file is out of date).
- I did **not** run anything on DEV or LIVE (no tool here reaches project `tuzxsqkfzrjssnpcoale`).

## Undo (newest first; each `_down` file is in `db/`)
`tutor_moves`, `slot_changes`, `centre_credit_undo`, `centre_late_fees`, `centre_refunds`, `centre_deposits`, `payment_fix`, `reassign_link`. (`centre_credit_undo_down` drops the notices table; money records are never touched, see the file header.)

## Rebuilding the pack
`python3 tools/build-dev-pack.py` (and `node --test tests/dev-pack.test.js` fails when the file is out of date).
