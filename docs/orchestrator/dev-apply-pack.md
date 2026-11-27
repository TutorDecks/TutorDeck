# DEV apply pack — test bundle 7 (T49)

**For the DEV Supabase project `tuzxsqkfzrjssnpcoale` only. Never LIVE.** Apply it **before** you test bundle 7 on the `dev` preview: the new pages call database functions that DEV does not have yet. It contains **everything bundle 6 needed plus the new bundle-7 migrations** (bundle 6's pack was never applied to DEV, so it was folded in; this file replaces it).

**What DEV must already have:** the seven standard migrations, **bundle 4's pack** (20 migrations + two demo staff logins) **and bundle 5's pack** (`reassign_link`, `payment_fix`, `centre_deposits`, `centre_refunds`, `centre_late_fees`, `centre_credit_undo`, `slot_changes`, `tutor_moves`). This pack creates **no logins** and changes no row of data. (`b5_fix` may already have been applied by hand: that is fine, it is repeated harmlessly.)

1. Supabase (DEV project) → SQL Editor → New query.
2. Paste the **pre-check** (the first block of `dev-apply-pack.sql`, from the top down to the line `-- Safety stop`) and Run. You should see:
   - 7 `present` lines for the standard migrations, 20 `bundle 4: … present` lines and 8 `bundle 5: … present` lines;
   - `demo logins from bundle 4 (information only) | 7 of 7`;
   - `NEW OBJECTS ALREADY THERE | N of 177 (…)`: only information. On a DEV that has not had this pack it is a small number (14 on the throwaway test, from `b5_fix` parts already there); a re-run shows 177;
   - `OVERALL | ready`, or `NOT READY - fix the MISSING lines first`.
3. Paste the **whole** file and Run. The editor runs it as one batch, so it is all-or-nothing: if something fails nothing is kept, and the error line number points into the file; search upwards for the nearest `### PART` line to see which migration it was. A database without the organisation tables (LIVE today) or without bundles 4 and 5 is stopped by the safety stop before anything changes.
4. The last result is the post-check: 177 `present` lines (tables and functions) and `OVERALL | OK - all 177 objects present`.
5. Running it again is safe and changes nothing.

The file is about 600 KB (6,700 lines). If the SQL editor is slow to paste, run it in two halves **at a `### PART` line, in order** (parts 1–7, then 8–11); each part is a complete, idempotent migration.

**Separate and optional (already applied to DEV, per its README):** `db/seed_dev_demo_money.sql` (T47, rich money demo data; guide `docs/orchestrator/dev-seed-money.md`). It is **not** in this pack. It needs bundles 4 and 5 and `db/seed_dev_demo.sql`, and refuses on anything but the demo centre. Not for LIVE.

## What is in it (the order is read from `tests/sql/run.sh` by `tools/build-dev-pack.py`)

| Part | Migration | Branch | Size | What it is |
|---|---|---|---|---|
| 1 | b5_fix | b5-fix | 223 lines, 20 KB | bundle 5 fixes: the deposit run follows today's settings and says why a student gets none; staff slots add the tutor on change; class share; tutor-change list |
| 2 | tutor_own_lessons | t6-3-tutor-own-lessons | 760 lines, 66 KB | tutors add their own one-off lessons and weekly slots, "Create lessons", price pending (centre option); replaces `staff_tutor_changes` and `centre_invoice_run_rows` |
| 3 | import | t33-i1-stage-a | 610 lines, 57 KB | centre import stage A: dry run, commit, undo, history, "billing starts from" setting; adds `students.online_link` / `start_date`, `recurring_slots.taught_by` |
| 4 | centre_tutor_pay | t4-s7-tutor-pay | 738 lines, 64 KB | tutor pay: effective-dated rates, monthly pay list, adjustments, payments (owner and staff with *Run tutor pay*) |
| 5 | statement_matching | t34-m0-matching | 640 lines, 55 KB | bank statement matching: mappings, batches, lines, rules A–D, confirm, undo, payer links |
| 6 | invoice_email | t7-3-invoice-email | 822 lines, 68 KB | invoice / receipt / reminder emails: queue, append-only send log, caps, bounced addresses, billing contacts |
| 7 | makeup_credits | t18-4-makeup-credits | 755 lines, 66 KB | make-up credits: earn once, book, unbook, expiry, price rule; replaces `centre_invoice_run_rows` |
| 8 | tutor_link_propose | t6-4-link-propose | 960 lines, 88 KB | online lesson link and tutors who ask (`tutors_propose`): `schedule_requests`, approve / decline, expiry; `lessons.online_link` |
| 9 | past_lessons | t3-10-past-lessons | 453 lines, 44 KB | staff add past lessons (backfill), setting `lessons.backfill_allowed_days` |
| 10 | tutor_own_pay | t4-s7b-own-pay | 185 lines, 16 KB | tutors see their own pay: four read-only functions and the setting `tutor_pay.tutors_see_own_pay` |
| 11 | org_export | t35-e-export | 286 lines, 27 KB | centre data export (owner only): catalogue of 47 exported tables (new: `schedule_requests`) and 5 excluded ones, paged reads, audit |

### Order matters (the settings check is replaced by six files, the invoice run by two)
- `org_validate_settings(jsonb)` is replaced by **`import`, `invoice_email`, `makeup_credits`, `tutor_link_propose` and `past_lessons`**, and the organisation-aware wrapper `org_validate_settings(uuid, jsonb)` by **`statement_matching` and `tutor_own_pay`**. Each file carries the **cumulative** version of the one before it (the later ones were rewritten while assembling this bundle), so applied in this order nothing is lost; each undo file hands back the previous link. `tests/sql/bundle6_chain_test.sql` proves both ends of the chain, now including the request-expiry and own-pay rules.
- `centre_invoice_run_rows` is replaced by `tutor_own_lessons` and then by `makeup_credits` (built on the first). `staff_tutor_changes` by `b5_fix`, then `tutor_own_lessons` (whose lesson-based version supersedes the audit-log one).
- `org_export` goes last; its catalogue lists every table with an organisation column, so a table nobody lists fails the test.

## How it was tested (throwaway Postgres, never DEV)
- `PGTZ=Asia/Singapore bash tests/sql/run.sh`: baseline → all migrations in order, each applied twice with its own test, each also undone and re-applied (and every undo run twice), the bundle-6/7 set undone in reverse and applied again, the chain test at both states, then every undo of the older chain, ending with "undo restores the baseline exactly" (and the T47 seed test).
- **A DEV-equivalent database** (`tests/sql/build_chain.sh td_pack_test seed`: baseline + the 7 standard + all 20 of bundle 4 + all 8 of bundle 5 + `db/seed_dev_demo.sql`): the pre-check said `ready` (7 of 7 logins, `14 of 177` new objects there), the whole pack ran in one transaction (`psql -1`), the post-check said `OVERALL | OK - all 177 objects present`, and it ran a **second** time with an identical schema fingerprint (columns, policies, triggers, constraints, indexes, every function's full text and grants).
- The same fingerprint was compared with a database where the bundle-5 chain was built and then each of the eleven migrations applied once in `run.sh` order: **identical** (`923eba9d…`).
- `node --test tests/*.test.js` includes `tests/migrations-safeupdate.test.js` and `tests/sql-safeupdate.test.js` (no `DELETE` or `UPDATE` without `WHERE` inside any migration function: the Supabase API layer refuses it with SQLSTATE 21000) and `tests/dev-pack.test.js` (fails when this file is out of date).
- I did **not** run anything on DEV or LIVE (no tool here reaches project `tuzxsqkfzrjssnpcoale`).

## Undo (newest first; each `_down` file is in `db/`)
`org_export`, `tutor_own_pay`, `past_lessons` (the lessons it added **stay**), `tutor_link_propose` (**deletes the tutor requests**, the lesson links), `makeup_credits`, `invoice_email`, `statement_matching`, `centre_tutor_pay` (**deletes the pay records**), `import` (imported students, families and lessons **stay**), `tutor_own_lessons`, `b5_fix`. Always strictly newest first.

## Rebuilding the pack
`python3 tools/build-dev-pack.py` (and `node --test tests/dev-pack.test.js` fails when the file is out of date).
