# T37 plan: shipping the multi-tenant centre stack to PRODUCTION (LIVE database + www.tutordeck.com.sg)

Branch `claude/t37-plan`. **Plan only**: no code, no SQL written, nothing run, LIVE never touched. Written 2026-11-26 from the repo (`origin/dev`, `origin/main`, `origin/claude/*`) and, for platform limits, the Supabase and Vercel docs (marked "docs"). Anything marked **not verified** was not checked. Goal date: customer setup window opens **Thu 10 Dec 2026**. No customer names or deal terms appear here on purpose.

## Summary
1. Today `main` is v252 and LIVE has **none** of the 7 organisation migrations. `dev` is 68 commits and 134 files ahead of `main`. Nothing from the centre stack is in production.
2. Two things make this safe: the migrations only ADD (tested: undo restores the baseline exactly) and the new pages fall back to today's behaviour when the organisation tables are missing (`T12c-notes.md`). So **database first, code second** are each safe on their own, with a pause between them.
3. Real hazards found in the code: (a) `migration_org_foundation.sql` adds stored generated columns and validated composite foreign keys, so it **rewrites and locks `lessons`, `recurring_slots`, `invoices`** for its whole run; (b) if any lesson, slot, exam or invoice points at a student of a different `tutor_id`, the foreign key fails and the whole run rolls back, so that must be previewed; (c) `migration_billing.sql` **grandfathers every solo tutor that exists at that moment**, so test accounts and new sign-ups must be created *after* it, and it should run the same hour as the foundation or be deliberately deferred (D3).
4. **A throwaway centre cannot be deleted on LIVE.** `org_delete_solo` and `api/delete-account.js` refuse centres, and the T21 clean-up script is DEV-only by design. Section 4 gives the way around it.
5. "Delete my account" has **no browser fallback**; without LIVE `SUPABASE_URL` and the LIVE service key in Vercel **Production** it answers 503 the moment the new code ships. The env split must therefore be done before the merge to `main`.
6. Recommended calendar: freeze `dev` Wed 2 Dec, dry run on a restored backup by Fri 4 Dec, **LIVE migrations Sun 6 Dec 03:00-04:00 SGT**, Production env Mon 7 Dec, **ship `dev` to `main` Tue 8 Dec (owner says "ship")**, verification the same day, spare day Wed 9 Dec, customer setup Thu 10 Dec.
7. Minimum viable subset: `dev` as it is + `t3-1` (centre Home) + `t3-2` (centre Students) + `t7-2` (invites). Attendance, charges, tutor payout and the rest follow after 10 Dec; their migrations only create new tables or functions and are safe to add later (section 6).
8. Six decisions for the owner are in section 7. The two with a date attached: Vercel Pro and Supabase Pro before the ship, and what to do about testing a centre on LIVE.

## 1. End state and order of events
**End state:** LIVE has the seven core migrations plus those of the merged branches; Vercel Production has its own LIVE-only variables; `main` holds the frozen `dev`; every existing solo tutor sees today's app (grandfathered, no student limit), and the owner can create the customer's centre on 10 Dec.

| # | When (SGT) | Step | Approver |
|---|---|---|---|
| 1 | Now to Fri 27 Nov | Owner answers section 7. Start Stripe live-account checks, Pro upgrades decision, create the scratch Supabase project | Owner |
| 2 | Mon 30 Nov - Tue 1 Dec | Merge into `dev`, one flow at a time (rule: only when the owner wants to test): `t3-4-charges` chain only as far as the scope chosen in D1, then `t7-2-invites`, then `t24c-3-payout` if in scope. Fix the version clash (`t7-2` and `t24c-1` both v273), README/CLAUDE.md/`app.js`/`org-scope.js` conflicts (docs/INDEX.md section 2.3: "not verified whether the groups merge cleanly"). Apply the matching SQL to **DEV** with `dev-apply-pack.sql`. Owner tests on the dev preview with the five demo logins | Owner says go per merge |
| 3 | Wed 2 Dec | **Freeze `dev`.** CI green (`.github/workflows/checks.yml`: unit tests, `tests/sql/run.sh`, smoke). The frozen commit and its migration list are written into the go/no-go sheet. Known open item: `tests/sql/staff_charges_test.sql` line 138 fails on `t3-4` (INDEX/dev-apply-pack): either fix it or leave `t3-4` out | Owner |
| 4 | Thu 3 - Fri 4 Dec | SELECT previews on LIVE (read-only, owner runs them); dry run on a restored copy (section 2) | Owner |
| 5 | Sun 6 Dec 03:00 | LIVE migrations (section 2). Old code (v252) keeps running on the migrated database for two days | Owner (explicit yes per step) |
| 6 | Mon 7 Dec | Production env, Stripe live items, LIVE SMTP/Auth settings (section 3). Go/no-go #2 at 18:00 | Owner |
| 7 | Tue 8 Dec, morning | PR `dev` to `main`. **Only with the owner's explicit "ship"** (CLAUDE.md). `bash bump-version.sh` number checked against `main` first. Merge deploys within about a minute | Owner |
| 8 | Tue 8 Dec | Verification script (section 4) | Owner + T-Leng |
| 9 | Wed 9 Dec | Spare day: fix forward, or roll back the deployment | Owner |
| 10 | Thu 10 Dec | Customer setup window | Owner |

Why the two-day gap between 5 and 7: if the migrated database misbehaves under the old code, we learn it with the code that can still be rolled back, before any new code is involved.

## 2. LIVE database migrations
**Order (everywhere):** `org_foundation` then `billing` then `attendance` then `tutor_access` then `org_delete` then `function_lockdown` then `org_separation`, then the merged branch migrations in the order of `dev-apply-pack.md`: staff_home, invites, tutor_profile, tutor_payout, payout_permission, staff_students, staff_attendance, staff_charges (only those in the release). Run **one file at a time** in the Supabase SQL editor, check, then the next. Each file is safe to run twice. The editor runs a pasted file as one batch, so a failure keeps nothing of that file.

**Dependencies found in the files:** `billing` needs only `foundation`. `org_delete` works "with or without billing". `delete-account.js` tolerates missing billing tables (404). So **billing can be deferred** (D3). `function_lockdown` must come after `org_delete` (it re-creates `audit_immutable`).

### 2.1 SELECT previews (read-only, counts only, no names; paste results into the go/no-go sheet)
A worker should write these as one file and test it on the restored copy (follow-up task T37b; none exists yet). What each must count:
- **Baseline per tutor:** users in `auth.users`, rows in `profiles`, and per tutor the number of students, slots, lessons, exams, invoices, materials plus the sum of lesson `amount` and invoice `total`. These are compared after the migration.
- **Cross-tutor pointers (blocks the foundation):** lessons, slots, exams and invoices whose student has a different `tutor_id`; lessons whose slot has a different `tutor_id`. Must be 0 or the composite foreign keys cannot be added.
- **Null `org_id`:** after the foundation, per table, rows with a null `org_id` (the file's own sanity block raises if any) and students without a household. Must be 0. This is also the evidence needed to flip `NULL_IS_MINE` to strict (T12c).
- **Same-organisation preview for `org_separation`:** the six counts already written in the header of `db/migration_org_separation.sql` (the last, invoice `lesson_ids`, is the only one that can be above 0).
- **Grandfathering:** number of solo organisations after the foundation equals the number of tutors; after billing, the number of `grandfathered = true` rows equals the number of solo organisations, and no `centre` row is grandfathered.
- **Users who are not tutors:** any `auth.users` row with no students and no `profiles` row (the migration gives each an organisation anyway; know the number).

### 2.2 Dry run on a restored copy of the live backup (Fri 4 Dec at the latest)
Use a **new scratch Supabase project** (never DEV: it holds demo data). Free plan is enough for this; delete it afterwards.
1. Actions, DB backup, newest successful run: download the artifact. First check the nightly runs have actually been succeeding (**not verified**). Decrypt, restore as in README "How to restore" (public schema, then `auth.users` and `auth.identities` data-only).
2. The dump holds `public` and `auth` only. Re-create what it cannot carry: the `on_auth_user_created` trigger on `auth.users` (it is in `db/baseline_2026-11.sql`, line 177), and the storage buckets (`db/baseline_2026-11_storage.sql`). Storage files are not in the backup; not needed for the dry run.
3. Check the restore: row counts match the preview's baseline.
4. Run the migrations in order, **timing each**. Record the elapsed time of the foundation; the planned window is twice that.
5. Re-run the previews; run `bash tests/sql/run.sh` separately on the throwaway Postgres (CI already does).
6. **Solo smoke on the restored data, at database level:** for every restored tutor (script over all of them), impersonate them with their JWT claims and compare what they can see (counts and money sums, per table) before and after. Must be identical. Then try one insert of each kind as a solo tutor (student, slot, lesson, exam, invoice): all succeed and get the right `org_id`.
7. Browser smoke against the scratch project needs a local, **uncommitted** copy of `config.js` pointing at it (not verified that the pages run this way; a small worker task).
8. Run the undo chain on the scratch copy and compare against the pre-migration shape (`run.sh` does this on test data).
Dry run passes only if every number matches and the timings are acceptable. Otherwise **no-go**.

### 2.3 Locks and timing
- `foundation` adds `rate_cents`, `amount_cents`, `compensation_cents`, `total_cents` as stored generated columns on `lessons`, `recurring_slots`, `invoices`; standard Postgres rewrites a table to add such a column and holds an exclusive lock until the script ends (**timing not measured on LIVE; the dry run measures it**). It also validates five composite foreign keys (a scan of each table) and backfills one organisation per user in the same batch, so locks last for the whole file. Reads and writes to those tables wait meanwhile; expect seconds to a few minutes for a database of this size (**not verified**).
- The other six core migrations only add tables, columns with defaults, functions, triggers and policies: milliseconds each, except `attendance` and `tutor_access` which add columns to `lessons` (fast defaults are standard in Postgres 11+; the server version is not recorded in the repo, the backup workflow prints it).
- Quiet hour: **Sun 6 Dec 03:00-04:00 SGT**, after the nightly dump (02:00 SGT) has finished and long before evening lessons. Suggested wrapper typed by the owner at the top of each pasted file: a transaction with `set local lock_timeout` of about 10 seconds, so a stuck lock fails cleanly instead of queuing every page behind it (to be tested on the scratch project first; whether the SQL editor keeps session settings is **not verified**).
- Tell T-Leng (who uses the app live) the window in advance.

### 2.4 Before, and the go/no-go checklist
- **Backup right before:** run the **DB backup** workflow by hand (Actions needs the owner's approval, standing rule), confirm the artifact is above the size the previous nights had, decrypt a copy once to prove the passphrase. If the project is on Supabase Pro, also note the dashboard backup (docs: daily, 7 days on Pro; free-plan backups cannot be downloaded). Storage files are not in either backup.
- **GO only if all are true:** dry run passed and timed; cross-tutor preview = 0; backup downloaded and decryptable; scratch undo worked; owner awake and reachable; T-Leng told; no deploy in progress; `main` unchanged since the dry run; rollback owner named.
- **After each file:** per-tutor counts unchanged, one sign-in as T-Leng works on the old code, `client_errors` shows nothing new (section 4).

### 2.5 Rollback
Undo files, newest first: `org_separation_down`, `function_lockdown_down`, `org_delete_down`, `tutor_access_down`, `attendance_down`, `billing_down`, `org_foundation_down` (branch migrations' `_down` files go before all of these, newest first). Tested on throwaway data to restore the baseline exactly.
**A down is NOT safe when:**
- any real centre exists: `foundation_down` drops every organisation, membership, setting, household and audit row, and the `org_id` columns, and centre rows (stamped with the owner's `tutor_id`) would merge into the owner's solo data;
- any Stripe live checkout or trial has happened: `billing_down` drops `org_subscriptions`, losing the Stripe ids and grandfather flags (re-running billing would grandfather everybody present at that time, including newcomers);
- attendance or tutor assignments have been entered: `attendance_down` and `tutor_access_down` drop those columns;
- the new code is live: the pages and `delete-account` expect the objects (undo the code first, see 4.6).
So the real window for "down" is the two days between step 5 and step 7, with old code, no centre, no payments. After the first centre exists, **fix forward**. Last resort: restore the pre-migration dump into a new project and repoint the app (loses everything written since; needs `config.js` and Auth changes; not rehearsed).
**Approvals:** owner approves every step above; no step is run by a worker (no LIVE access by design).

## 3. Production environment
| Item | What to do | Notes |
|---|---|---|
| Vercel Production variables (names only) | `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` (LIVE project's own), `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `CRON_SECRET` (16+ chars), `BREVO_API_KEY` (LIVE key), optional `BREVO_INVITE_TEMPLATE_ID`; existing `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GCAL_TOKEN_KEY` stay | Today `STRIPE_*` and the service key are **shared by Production and Preview with sandbox/DEV values**; split them so Production never holds a DEV key and Preview never a LIVE key. `INVITE_TEST_ALLOW` is Preview only. Production has no `SUPABASE_URL` today. Variables are read at build time: set them Mon 7 Dec, the merge on Tue picks them up |
| Preview variables | stay DEV/sandbox | Preview mail is limited to `@tutordeck.com.sg` and the allow-list (T7) |
| Service-role keys | only in Vercel (Sensitive) | Never in the repo, chat or `config.js` (a test already scans for it) |
| Host list | `PRODUCTION_HOSTS` in `assets/js/config.js` and `tests/config.test.js` already hold www, apex, `tutordeck.vercel.app` and the two Vercel aliases. **Add any other production domain in both files** or it shows the test banner and nobody signs in. Run `node tests/config.test.js` and `tests/env-hosts.check.js` before the freeze | DNS for the custom domain: Vodien A record and www CNAME point at Vercel (board) |
| Stripe live (solo only) | Live products and prices with lookup keys `solo_pro_monthly`, `solo_pro_yearly`; live webhook to the production domain with the six events listed in `api/stripe-webhook.js`; customer-portal configuration saved; live account business details and bank account | Start now: Stripe's verification lead time is **not verified**. Centre keys (`centre_base_monthly`, `centre_student_monthly`) and the centre subscription are created **by hand per centre** later |
| Revoke Vercel protection-bypass token | Vercel, Settings, Deployment Protection; delete or replace the sandbox webhook that carries it in its URL | The live webhook must not use it |
| `CRON_SECRET` and the cron | `vercel.json` has one daily cron on `/api/billing-cron`. Without the secret it answers 503 every day (noise only). With it and no centre subscription it does nothing ("skipped:no_subscription"). First real fee run needs a centre subscription; always `?dry=1` first | Hobby plans allow daily crons (not re-checked in docs) |
| LIVE auth emails | Brevo SMTP on LIVE Supabase (`T7-owner-steps.md` section D): write down current settings first, three templates, OTP expiry 24 h, rate limit about 60/h, keep the Turnstile bot check on | Docs: with custom SMTP the default limit is 30 new users per hour. Whether LIVE already uses custom SMTP is **not verified** (CLAUDE.md lists it as "later") |
| LIVE Auth settings | Site URL `https://www.tutordeck.com.sg`; redirect URLs for www, apex, `tutordeck.vercel.app`; password rule lowercase + uppercase + digit + symbol (owner says LIVE already has it); check email confirmation is on | Also check Supabase Authentication has no leftover test users |
| Mail on the custom domain | Sending as `noreply@tutordeck.com.sg` works (Brevo verified 2026-11-25). **The domain cannot receive mail**: MX points at Vercel (board). Reply-To is a Gmail address for launch. Get a real support mailbox or forwarding before the first paying centre | Brevo free tier = 300 emails a day with a "Sent with Brevo" footer |
| Vercel plan | **Pro before the ship.** Docs: on Hobby you can roll back only to the *previous* production deployment; Pro can roll back to any. CLAUDE.md also says Hobby is non-commercial (not re-read in the docs) | See D2 |
| Supabase plan | **Pro before the migration.** Docs: free-plan backups cannot be downloaded and free projects can be paused after 7 low-activity days (production is active, but the dashboard backup is the second copy); Pro keeps daily backups for 7 days. Point-in-time recovery is a paid add-on (docs list it as extra; the price is not needed now) | Our own nightly dump stays as the independent copy |

## 4. Verification script for the day (Tue 8 Dec, after the ship)
Run in this order; stop and decide rollback if any step fails.
1. **Config:** open www, the apex and `tutordeck.vercel.app`: no "Test version" tab, sign-in works. Open one Vercel preview: tab shown. Run `tests/env-hosts.check.js`.
2. **Real solo tutor (T-Leng, existing account):** sign in; Home, Calendar, Ledger, Students, Planner, Invoices, Exams, Settings load with the same numbers as the per-tutor baseline from 2.1; add and then edit one lesson note; no console errors (watch the error log below). Not grandfathered check: Settings shows no student limit.
3. **Dummy solo account on LIVE without touching real data:** create it **after** the billing migration, through the normal sign-up on www, with an email address the owner controls (a plus-address of their own mailbox), name "ZZ TutorDeck smoke". Add 5 dummy students named "Test Student 1-5" with no real phone numbers, a weekly slot and a lesson. Add a sixth: the free-plan prompt must appear (proves the gate for new tutors). Check Plan card text. Optional live Stripe check only with the owner's say (a real small charge refunded, or a 100%-off coupon; **not verified** that the portal supports this). At the end use Settings, "Delete my account" on that account: it runs `delete-account.js` against LIVE and proves the Production env split. Never delete tutor rows by hand.
4. **Centre on LIVE:** a centre cannot be deleted on LIVE (see Summary 4). Two options, owner picks in D4: **(a)** create one permanent, clearly named centre ("TutorDeck Demo Centre") under the owner's own login, with dummy people only; **(b)** first build a reviewed LIVE-safe centre deletion (a T21-style preview, dry-run and post-check, tested on the scratch copy; T21 is DEV-only by design and refuses LIVE). Until (b) exists, do not create a throwaway centre on LIVE. In either case run the full centre flow (wizard, invite, Students, My lessons) on the **scratch project and DEV** first.
5. **Performance seed:** do **not** seed on LIVE. On the scratch copy, load a synthetic centre (a few hundred students, several thousand lessons) with a throwaway script and time the centre Home, Students and My lessons pages. **Not verified** that such a script exists; small worker task.
6. **Error monitoring:** read `client_errors` on LIVE in the Supabase Table Editor (query is at the bottom of `db/migration_client_errors.sql`; the table is already in the baseline) before the ship, 1 h after, and at end of day: any new message from `app_version` of the new release is a stop sign. Also Vercel runtime errors and logs for `/api/*`.
7. **Rollback of the deployment:** Vercel, Deployments, previous production deployment, Promote/Rollback (or `vercel rollback`). Takes effect in seconds without a rebuild (docs). Database stays migrated; the old code tolerates it. Do this before anyone creates a centre; afterwards the old code does not know centres exist, so fix forward unless a solo flow is broken.

## 5. What must NOT happen
- No bulk edit or delete of real rows, no hand-deleting a tutor's rows (it copies their data into the append-only audit log); account removal only via the app or the reviewed script.
- **`db/seed_dev_demo.sql` never runs on LIVE.** None of `centre.owner@`, `tutor.one@`, `tutor.two@`, `both.tutor@`, `solo.tutor@`, `centre.staff@`, `centre.frontdesk@` (`@example.test`, known password) may exist on LIVE: check with a SELECT on `auth.users` after the migrations and again after the ship. `dev-apply-pack.sql` part 9 is DEV only.
- No service-role key, SMTP password, Stripe secret or backup passphrase in the repo, in a PR, in a log or in chat.
- No `dev-apply-pack.sql` or T21 clean-up on LIVE. No migration run on LIVE after the code that needs it. No direct push or force-push to `main`.
- No worker, orchestrator or Claude chat connects to LIVE.
- Nothing in any document about a named customer or their terms.

## 6. Schedule from 10 Dec, decision points, and what can follow later
Dates in section 1. Decision points: **Fri 27 Nov** owner answers D1-D6; **Wed 2 Dec** freeze (scope final); **Fri 4 Dec** dry-run result (go/no-go #1); **Sun 6 Dec** go for migrations (#2); **Mon 7 Dec 18:00** go for the ship (#3); **Tue 8 Dec** verification pass or rollback.
**If things slip:**
- Dry run not clean by Fri 4 Dec: move migrations to Sun 13 Dec and tell the customer; do **not** shorten the dry run.
- Migrations done but ship not ready by Tue 8 Dec: the database stays migrated, old code keeps serving solo tutors; the centre can be created through `/org` only with the new code, so the customer setup moves to the day after the ship.
- Stripe live not ready: defer `billing` (D3).

**Migrations that can safely come later** (each only creates a table, a function, or a nullable column; none rewrites a solo table): `staff_home`, `invites`, `tutor_profile` (one nullable column on `memberships`), `tutor_payout`, `payout_permission` (re-defines `org_invite` and `org_update_member`; needs `invites` first), `staff_students`, `staff_charges` (needs `staff_attendance`). **Take extra care with `staff_attendance`**: it adds a trigger on `lessons`, which solo tutors write all day; run it in a quiet hour and re-run the solo smoke. Rule: a migration reaches LIVE **before** the code that calls it, and only the code of a merged branch needs its migration.
**Must go first, once, in the window:** the seven core ones (`foundation` to `org_separation`). They change existing tables, policies and the sign-up function; doing them piecemeal later would mean a second risky window. `billing` is the one core migration that can wait, at the price in D3. Later centre features also need a centre setting default for each new option (rule: the centre decides).

## 7. Risks and decisions for the owner (recommendation first)
- **D1. Scope for 10 Dec.** Recommend minimum: `dev` + `t3-1` + `t3-2` + `t7-2`; everything else after. Without centre Students the owner cannot add a student to a centre (solo screens are hidden for centre owners). Whether the customer needs attendance on day one is **not verified**; ask them.
- **D2. Upgrade Vercel and Supabase to Pro** by Fri 4 Dec (Supabase) and Mon 7 Dec (Vercel). Rollback beyond one step and downloadable dashboard backups need them; Hobby is non-commercial per CLAUDE.md.
- **D3. Billing migration now or later.** Recommend now, right after the foundation, **if** Stripe live (products, webhook, portal) is ready by Mon 7 Dec; otherwise defer it, accepting that everyone present when it finally runs is grandfathered unlimited (including tutors who sign up in between). Do not ship a visible Plan screen whose checkout cannot complete.
- **D4. How to test a centre on LIVE.** Recommend (a): one permanent labelled demo centre under the owner's login, plus building safe centre deletion as the first task after 10 Dec. (b) costs about a week of work and is not needed for the customer.
- **D5. Mail.** The domain cannot receive mail and Brevo free adds a footer. Recommend a forwarding or Workspace mailbox for support by Mon 7 Dec; Brevo paid plan before the first big centre.
- **D6. Slot of the migration.** Recommend Sun 6 Dec 03:00 SGT with T-Leng informed. The alternative of migrating and shipping on the same day removes the two-day safety gap; not recommended.

**Main risks:** foundation lock time larger than the dry run (mitigation: lock timeout, quiet hour, abort rolls the file back); cross-tutor rows blocking the foreign keys (preview); a DEV/sandbox key left in Production (env split + 2.1/4.3 deletion test); branch merge conflicts eating Mon-Tue (freeze Wed, drop scope per D1); no tested way to remove a LIVE centre (D4); Storage files outside every backup (known gap; do not rely on it for receipts).
