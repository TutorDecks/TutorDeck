# T35 plan: centre data export, closing a centre, and the backup story

Branch `claude/t35-plan`. Plan only: no code, no SQL, no workflow run, nothing touched on LIVE or DEV. Written 2026-11-26 from CLAUDE.md, README (Backups, How to restore), `.github/workflows/db-backup.yml`, `exportData` in `assets/js/settings.js`, `db/migration_org_foundation.sql`, `_org_delete.sql` (`org_owned_columns()`), `_billing.sql`, `_gcal_links.sql`, `baseline_2026-11*.sql`, the T24b plan and Product Guide section 5. T4 and T33 plans are not on `dev`, so tutor pay is planned from the Guide and T24b only. Anything I could not read is marked **not verified**. No customer name or deal term appears here.

## Summary
- **Export:** the **owner** (only) taps "Export my centre's data" and gets a **ZIP of CSV files, one per table, plus a README with a plain-words data dictionary**. A server function builds it for ONE organisation id, in small resumable chunks, stores it in a private bucket, and gives a **download link that expires in 15 minutes**; the file itself is deleted after **24 hours**. Every export writes an audit row (who, when, tables, row counts, never data).
- **Nothing is forgotten:** the list of tables to export comes from `org_owned_columns()` (the same catalogue that makes account deletion complete). A SQL test fails if any table with an org id is neither "exported" nor "excluded with a written reason".
- **Never exported:** other organisations, password hashes, login tokens, Google refresh keys, Stripe ids, invoice share links, and full payout numbers (masked by default).
- **Closing a centre** = the same export as a mandatory step, then a 30-day read-only grace, then deletion. Centre deletion itself is **not built** (`org_delete_solo` refuses centres: `ONLY_SOLO`).
- **Backups, truthfully:** a nightly encrypted dump of the `public` + `auth` schemas is kept 30 days as a GitHub artifact. It is real and well designed, but **no restore into Supabase has ever been done**, **nobody is alerted beyond GitHub's default failure email**, **files in Storage are not covered**, and the Supabase plan-level backups are **not verified**. Do not promise "daily backups" to a paying customer until the three checklist items in section 4 are done.

## 1. The export

**Who:** the centre **owner** only (`org_role(org) = 'owner'`). Staff (even with every permission), tutors, parents and platform admins cannot. Support staff get nothing unless the owner exports. Before it starts, the owner re-types their password (and MFA if enabled), because the file holds every family's contact details.

**Included** (one CSV per table; ids kept so rows can be joined; money in cents plus a dollars column):

| File | Contents (plain words) |
|---|---|
| `students` | name, level, subjects, school, start / "lessons until" date, fee, notes, household link |
| `households`, `guardians` | family, parent names, phone, email, relationship (the owner already sees these) |
| `memberships` | people at the centre: name, role, staff permissions, employment type, status, invite email. **No user id, no password, no login data** |
| `lessons` | date, time, student, tutor (name), subject, status, attendance, notes, price, compensation, paid flag, one-off flag, cancelled-by |
| `recurring_slots` | the weekly template: day, time, student, tutor, active |
| `exams` | student, subject, date, mark |
| `invoices` and invoice lines | number, student/household, issue date, items (unpacked from `data`), total, status, paid date. **Not** `share_token` |
| payments, deposits ledger, credits / credit notes | **not built yet on `dev` (not verified where planned)**; each is added to the export set the day its table exists, enforced by the test below |
| `org_settings` (all versions) | the centre's rules with effective dates, so history is kept |
| `org_plans`, `platform_fee_snapshots` | the fee terms and monthly fee records TutorDeck charged this centre |
| `branches`, `rooms`, `terms`, `holidays` | as entered |
| `support_access_grants` | who at TutorDeck was ever given access, when, until when |
| tutor rates and pay | **only if** pay tables exist and the owner has `run_tutor_pay` (owners always do); gated again inside the function |
| `audit_log` | the centre's own audit trail (largest table; see limits) |
| `tutor_payout_details` (planned, T24b) | **masked** (`•••••1234`) by default |
| `materials`, `receipts` (Storage files) | **phase 2**, as a separate ZIP; see section 4 |

**Excluded, with the reason written in the README:** other organisations (one org id, section below); `auth.users` and everything in `auth` (hashes, tokens); `gcal_links` (`refresh_enc`); `org_subscriptions`, `stripe_events` and any `stripe_*` column (billing-provider ids; the owner can see them in Stripe); `invoices.share_token` (a bearer link: anyone holding it reads the invoice); `platform_admins`; `client_errors` (no org, not the customer's data); full payout numbers unless the owner ticks "include full payout numbers" (off by default; writes its own audit row). Column names in the CSVs are plain words ("Student name", not `student_id`) with the technical name in the dictionary.

**How it is built (the safe pattern):**
1. New function `org_export_catalog()` returns one row per table in `org_owned_columns()`: table, org column, mode (`include` / `exclude`), allowed column list, reason. Included tables use an **explicit column list** (never `select *`), the same discipline as `tutor_my_lessons`. A new column is therefore NOT exported until someone adds it, and the data dictionary is generated from the same list and the column comments.
2. `api/export-org.js` (Vercel, server side, same style as `api/delete-account.js`): reads the signed-in user's token, asks the database "is this user owner of org X?" (server never trusts the request body), then reads **only** with `where org_id = X` per table.
3. **Chunking:** keyset pages of ~5,000 rows per table, appended to the CSV; each call does a bounded slice and the page polls until `status = done`, so no single call runs long. The Vercel function time limit on our plan is **not verified**; the design assumes a short one. The ZIP is assembled from the finished CSV parts into a private bucket `exports/<org>/<job>.zip`.
4. CSV rules: UTF-8 with BOM (Excel), quotes and newlines escaped, and any cell starting with `= + - @` is prefixed with `'` so a malicious student name cannot run as a spreadsheet formula.
5. New append-only `export_jobs` (org id, requested by, status, tables, row counts, created, expires). Every request and every download inserts an `audit_log` row (`org_export_requested`, `org_export_downloaded`, counts only).
6. **Limits:** one export running per organisation; at most 3 per rolling 24 h, 1 per hour; link valid 15 minutes (a fresh one can be issued from the job page for 24 h); a cron step deletes expired files hourly (a bucket lifecycle setting is **not verified**). Size estimate (assumption, to be measured on DEV): 400 students, 3,000 lessons a month for 5 years is about 180,000 lesson rows; at roughly 300 bytes a row that is on the order of 50 MB of CSV, a few MB zipped, and the audit log is likely bigger than lessons. The target is "done in under 2 minutes, no step over 8 seconds".
7. **PDPA:** the file is personal data (parents' phone numbers and emails). In transit: HTTPS only (Vercel and Supabase terminate TLS; the signed link is HTTPS). At rest: private bucket, no public URL, no policy for any browser user, access only through the signed link; Supabase's own at-rest disk encryption is **not verified** (read its docs before stating it to a customer). Not kept longer than 24 h; link valid 15 min; the audit row proves who exported. Once downloaded it is in the owner's hands, so the page says "This file contains families' contact details. Store it somewhere private." Optional hardening: AES-256 password on the ZIP (decision 1).

## 2. The same export as the offboarding step
Closing a centre is a plain-words route: (1) **owner confirms** and runs the export (the "Close centre" button stays disabled until an export of that day is `done` and downloaded, or the owner types an explicit "I don't want one"); (2) centre goes **read-only for 30 days** (owner can still re-download; Stripe subscription cancelled at period end); (3) after 30 days a new `org_delete_centre()` (modelled on `org_delete_solo`: count, delete through cascade, prove nothing is left, keep one anonymous marker row) removes everything. **Truth to tell the customer:** a deleted centre's data stays inside our encrypted nightly backups for up to **30 more days**, then ages out; we do not edit old backups. Ownership transfer is offered before closure (Guide section 7, item 10).

## 3. Backups: what actually exists (read from the workflow and README)

| Question | Answer |
|---|---|
| What | `pg_dump -Fc` of the **`public` and `auth` schemas**, structure and data, of the **LIVE** project only (DEV is not backed up; it holds dummy data) |
| When | every night 18:00 UTC (02:00 Singapore), plus manual "Run workflow" |
| Encrypted how | `gpg --symmetric --cipher-algo AES256` with the `BACKUP_PASSPHRASE` secret; the plain dump is shredded on the runner |
| Where / how long | GitHub Actions artifact, `retention-days: 30`, in a **public** repo (anyone signed in to GitHub can download the encrypted file; useless without the passphrase) |
| Self-checks | fails if secrets missing, URL not the session pooler, dump under 20 KB, or no data section for `students`, `lessons`, `recurring_slots`, `invoices`, `auth.users`. It does **not** check the organisation tables (`memberships`, `org_settings`, `audit_log`) that arrive when the org migrations reach LIVE |
| Restore tested? | README: encrypt, decrypt, restore were tested on a **local** Postgres on 2026-10-20 and "do one real practice restore into a throwaway Supabase project once the first backup exists". **No record anywhere that this was done. Treat as never tested against Supabase.** Whether any nightly run has actually succeeded lately: **not verified** (I have no access to Actions history) |
| Alerting | only GitHub's default "workflow failed" email to repo admins (README claim; **not verified** for who receives it). A silent stop (disabled schedule after 60 days without commits, deleted secret, expired DB password) needs someone to notice |
| Not covered | **Supabase Storage files** (`receipts` payment screenshots, `materials`); the dump has only their paths. Point-in-time recovery (restore to a minute): none. Anything between two nightly runs (up to 24 h of lost work). `storage` and other Supabase-internal schemas |
| Single points of failure | one passphrase (lose it = lose every backup); one place (GitHub); GitHub must also keep the schedule enabled |
| Supabase's own backups | Free vs paid plan daily backups, retention and PITR add-on: **not verified** (docs not read in this task). Read the current Supabase pricing and backup pages before choosing a plan |

## 4. Checklist for the owner (backups)
1. **Restore drill (do first):** download last night's artifact, decrypt, restore into a scratch Supabase project with the README steps, count `students`/`lessons`/users, sign in as a demo user, then delete the scratch project. Write the date and result in the README. Takes about an hour; nobody's real data is exposed beyond your own machine.
2. **Alerting:** add a "heartbeat" so a missed backup is noticed: either a final workflow step that pings a monitoring address (a non-secret ping URL, no data), or a second tiny workflow that checks the newest artifact is under 26 hours old and fails (emailing you) if not. Confirm which email addresses GitHub notifies.
3. **Plan tier:** read Supabase's current backup terms and move LIVE to a plan with its own daily backups (and decide on point-in-time recovery) **before the first paying centre goes live**. Our dump then becomes the second, independent copy, not the only one.
4. Second copy of the passphrase (second password manager entry or printed in a safe), and one trusted person who knows where it is.
5. Storage files: decide a separate job (phase 2) or accept "payment screenshots are not backed up" in writing.
6. When the org migrations reach LIVE, add the org tables to the dump's sanity check.

## 5. Tests
- **SQL `tests/sql/org_export_test.sql`** (throwaway Postgres): (a) every row of `org_owned_columns()` appears in `org_export_catalog()` as `include` or `exclude-with-reason`: add a dummy table with an org id inside the test and prove the test goes red; (b) no included column name contains `token`, `hash`, `secret`, `_enc`, `stripe`, `password`, and payout columns are masked by default; (c) isolation: two orgs, export of A returns zero rows owned by B, including through foreign keys; (d) denied: staff with all permissions, tutor, parent, other org's owner, anonymous, solo of another org; (e) audit row written with counts and no values; (f) rate limit and "one running job"; (g) `exclude` reasons are non-empty.
- **Unit tests (`node --test`)** for the CSV writer: quotes, commas, newlines, emoji and Chinese names, formula-prefix guard, BOM, header names.
- **Synthetic fixture:** generated (no real data) with 400 students in 200 households (my reading of "400/200"), 4 tutors per 100 students, 24 months of lessons (about 3,000 a month), 100,000 audit rows. Checks: CSV row counts equal `select count(*)`; export completes under the time target on DEV; no chunk exceeds the step limit; ZIP opens; README lists every file.
- **Browser check** `tests/export-page.check.js` for the owner-only button and the expiring link.

## 6. Build order (small steps, DEV only)
| Step | What | Done means |
|---|---|---|
| E1 | `org_export_catalog()` + the SQL test (a), (b), (g); no behaviour yet | `bash tests/sql/run.sh` green; adding a table makes it red |
| E2 | `export_jobs` table, `org_export_request(org)` (owner check, rate limit, audit), tests (c)(d)(e)(f) | SQL tests green on the fixture; undo script tested |
| E3 | pure CSV and dictionary builder in a `*-core.js` file + unit tests | `node --test` green |
| E4 | `api/export-org.js` chunked, ZIP to private bucket, signed link, hourly cleanup | 400-student fixture exports in under 2 min on DEV; expired file gone after 24 h |
| E5 | Settings screen, owner-only, password re-check, plain-words warning, one teal button | **Owner click-through on DEV:** log in as the demo centre owner (`Demo-Pass-2026`), run an export, open the ZIP in Excel/Numbers, check names with an apostrophe or comma, wait 16 min and see the link refuse, then log in as a demo tutor and see no button |
| E6 | closure route: required export, read-only grace, `org_delete_centre()` with its tests | closure refused without an export; deletion proves empty; marker row only |
| E7 | phase 2: Storage files ZIP; README data-dictionary polish | owner opens a payment screenshot from the ZIP |
Backup items 1 to 6 run in parallel and need no code except item 2.

## 7. Decisions for the owner (recommendation first)
1. **Wording of the promise.** Recommend: "Self-service export of all your centre's records (CSV, within minutes, owner only; excludes passwords and billing-provider ids)" and "nightly encrypted backups kept 30 days", and say it in writing **only after** the restore drill, alerting and plan tier (section 4) are done. Alternative: promise "full export at any time" including files, which needs phase 2 first.
2. **Supabase plan.** Recommend moving LIVE to a paid plan with its own daily backups before the first paying centre; price and exact terms **not verified**, check the pricing page. Point-in-time recovery can wait unless the customer asks.
3. **Payout numbers in the export.** Recommend masked by default, full numbers only on an explicit tick, owner only, audited. Alternative: never export them.
4. **Closure grace.** Recommend 30 days read-only then deletion, telling the customer backups keep it up to 30 more days. Alternative: immediate deletion (cannot be undone, riskier).
5. **Password on the ZIP.** Recommend yes later (E7+), not at launch: it adds support load; the 15-minute link, 24-hour deletion and re-authentication already cover the main risks. Alternative: do it from day one if the customer's own data-protection review asks.

Files touched: `docs/orchestrator/T35-plan.md` only.
