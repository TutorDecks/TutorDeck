# docs/ index: where things are

Written 2026-11-26 (task T28) from `origin/dev` and every `origin/claude/*` branch. Plain map for a new Claude chat. Anything marked **not verified** was not checked in code or on a running site.

## 1. The docs folder in plain words

| Path | What it is |
|---|---|
| `docs/INDEX.md` | This file |
| `docs/orchestrator/BOARD.md` | The current task board and the owner's decisions. Start here to see what is done, doing and waiting. Written by the orchestrator chat; workers do not edit it |
| `docs/orchestrator/ORCHESTRATOR.md`, `START_PROMPT.md` | How the orchestrator and worker chats work together; the worker brief template |
| `docs/orchestrator/T2-report.md` | End-to-end test report on the DEV logins (local run) |
| `docs/orchestrator/T3-plan.md` | Plan: staff screens for centres |
| `docs/orchestrator/T6-plan.md` | Plan: tutors manage their own schedule (centre option) |
| `docs/orchestrator/T7-plan.md`, `T7-owner-steps.md`, `t7/` | Plan and owner steps for email through Brevo; `t7/` holds the email HTML templates |
| `docs/orchestrator/T12-plan.md`, `T12c-notes.md`, `T18-plan.md` | Plans already on `dev`: separate centre from solo data; holidays and make-up credits |
| `docs/orchestrator/T21-cleanup.md`, `t21/` | DEV-only clean-up SQL (preview, delete, post-check) for the throwaway test login. Nothing here has been run on any database |
| `docs/orchestrator/T24b-plan.md` | Plan: Settings for centre tutors (profile, payout details, leave or delete) |
| `docs/orchestrator/dev-apply-pack.md`, `.sql` | One combined SQL pack for the owner to apply to the DEV database (from the latest pack branch, `claude/t26b-dev-pack`) |
| `docs/product/TutorDeck-Product-Guide.md` | The product specification: every role, every centre option, workflows, data and privacy, plans, open decisions. Appendix A = what is built vs planned. Read this first for any product or business question |
| `docs/product/build-options.js` | Helper used to build the guide's centre-options table (not verified how it is run) |
| `docs/business/SERVICE-AGREEMENT-FACTS.md` | Facts for drafting a Service Agreement, Terms or proposal. Not legal advice |
| `docs/business/PRICING-AND-PLANS.md` | Not written: the facts sheet already holds the prices |

Also useful outside `docs/`: `CLAUDE.md` (project rules, data warning, go-live checklist), `README.md` (file map, migrations, change log), `privacy.html` and `terms.html` (the public legal pages as they stand).

## 2. Unmerged work

`git branch -r | grep origin/claude/` lists **38** branches. 19 of them are already inside `dev` (nothing to merge). The other 19 hold work that is **not on `dev`** (section 2.2). "Ahead" means commits not on `origin/dev` when this was written. Branch tips move, so re-check with `git log origin/dev..origin/claude/<name>`.

### 2.1 Already in `dev` (0 commits ahead)

Nothing to do. Read them through `dev`.

| Branch | What it was |
|---|---|
| `bundle-2`, `bundle-3` | Test bundles merged to `dev` (PR #126, #127) |
| `cool-archimedes-wmgz77` | Account deletion and billing steps 1-3 (PR #122) |
| `gifted-cori-wssq1j` | Old Phase 1 organisation setup (v253), contained in later work |
| `merge-remainder-t1` | Rest of the integration branch (PR #124) |
| `modest-hypatia-lxmmks` | Sign-up password hint (PR #123) |
| `sleepy-bell-xfr6zb` | The old integration branch (Stripe billing, org foundation, My lessons). Its tip is an ancestor of `dev` |
| `t11-gcal-test-stub` | Test-server stub for `/api/gcal` (PR #125) |
| `t12-plan`, `t18-plan` | Plans (files are in `docs/orchestrator/` on `dev`) |
| `t12a-org-guard`, `t12b-current-org` | Database same-organisation guard; current-organisation switcher |
| `t15-tutor-redirect`, `t18a-honest-settings`, `t18b-holiday-library` | Tutor redirect; "coming soon" flags; Singapore holiday library |
| `t19-password-rules`, `t20-card-on-file`, `t23-password-checklist`, `t24-settings-closed` | Password rules and checklist; card on the plan card; Settings closed to tutor-only logins |

### 2.2 Not in `dev`

Status: **built** = code, migration and tests on the branch; **plan only** = a document; **docs** = documents only. All "built" branches use the DEV database only so far; none of their SQL has been run on LIVE.

| Branch | What it holds | Status | Depends on | Notes |
|---|---|---|---|---|
| `brave-archimedes-uxps0b` | The orchestrator's own branch: `docs/orchestrator/BOARD.md` (the current board; 45 board-update commits) | docs | none | Only the board file differs from `dev`. This bundle copies it into `dev` |
| `t2-report` | `docs/orchestrator/T2-report.md` | docs | none | In this bundle |
| `t3-plan` | `docs/orchestrator/T3-plan.md` | plan only | none | In this bundle |
| `t6-plan` | `docs/orchestrator/T6-plan.md` | plan only | none | Branch existed when this bundle was made; in this bundle |
| `t7-plan` | `docs/orchestrator/T7-plan.md` | plan only | none | In this bundle |
| `t7-2-invites` | Invite email through Brevo (`api/send-invite.js`, `api/_brevo-lib.js`), Resend invite, welcome page, branded email templates, `db/migration_invites.sql`, `docs/orchestrator/T7-owner-steps.md`, `t7/` | built (docs copied here) | Owner does the Brevo and Supabase SMTP steps in `T7-owner-steps.md` | Uses cache version v273, same as `t24c-1-profile`: pick one final number when bundling |
| `t21-cleanup` | `docs/orchestrator/T21-cleanup.md`, `t21/*.sql`, plus `tests/sql/t21_*` | docs and scripts (docs copied here; the two test files are not) | none | DEV only. For the owner to run `preview.sql` first |
| `t24b-plan` | `docs/orchestrator/T24b-plan.md` | plan only | none | In this bundle |
| `t12c-org-filter` | One extra commit: menu label "Centre" for one centre, "Centres" for more (`T12c-notes.md` is already on `dev`) | built (small) | `dev` | `dev` still has the fixed label "Centres" in `assets/js/app.js`, so this label change looks unmerged (not verified in a browser) |
| `t24c-1-profile` | Tutor settings page: profile and change password for centre tutors; `db/migration_tutor_profile.sql` | built | `dev` | v273 |
| `t24c-2-payout` | Adds tutor payout details (masked, audited, tutor-only); `db/migration_tutor_payout.sql` | built | `t24c-1-profile` | v274. Contains `t24c-1` |
| `t24c-3-payout` | Adds the centre side: `view_payout_details` permission, masked list, audited reveal; `db/migration_payout_permission.sql` | built | `t24c-2-payout` | v281. Contains `t24c-1` and `t24c-2`. Owner decisions pending (see board) |
| `t3-1-staff-home` | Centre Home for owners and staff (`staff_home()`), demo staff logins; `db/migration_staff_home.sql` | built | `dev` | v272 |
| `t3-2-students` | Centre Students (list, add, edit, discontinue) by four database functions; `db/migration_staff_students.sql` | built | `t3-1-staff-home` | v280. Contains `t3-1` |
| `t3-3-attendance` | Centre Attendance (view, mark, correct), integrity rules moved into the lessons table; `db/migration_staff_attendance.sql` | built | `t3-2-students` | v285. Contains `t3-1` and `t3-2`. Six owner decisions to collect (board) |
| `t3-4-charges` | Centre Charges tab (pending charges queue); `db/migration_staff_charges.sql` | built | `t3-3-attendance` | v290. Contains the whole T3 chain. The Product Guide says one assertion in its SQL test fails (line 138): **not verified** |
| `t26-dev-pack` | First combined DEV SQL pack (staff_home, invites, tutor profile, demo staff logins) | docs (SQL for the owner) | the migrations it combines | Superseded by `t26b-dev-pack` |
| `t26b-dev-pack` | Extended DEV SQL pack: adds payout, payout permission, staff students, attendance, charges | docs (SQL for the owner) | the migrations it combines | Latest pack. In this bundle |
| `t27-product-guide` | `docs/product/TutorDeck-Product-Guide.md`, `build-options.js` | docs | none | In this bundle |

The board also names `claude/t24c-5-leave` (leave-centre and remove tutor, database only). **No such branch exists on `origin`** at the time of writing, so that work, if any, is not available. The matching pending items are in the board's task list.

### 2.3 Suggested merge order

Suggestion only. The owner decides, and the standing rules apply: merge into `dev` only as one complete user flow when the owner wants to test; no deploys or Actions runs without the owner's word; never straight to `main`.

1. **Docs** (this bundle): board, plans, Product Guide, DEV pack. No code.
2. **Small and independent:** `t12c-org-filter` (menu label).
3. **Centre staff v1 (one flow):** `t3-4-charges` carries `t3-1`, `t3-2`, `t3-3` and `t3-4` together. Apply the SQL in order `staff_home`, `staff_students`, `staff_attendance`, `staff_charges` to DEV first (the `t26b` pack does this).
4. **Invites:** `t7-2-invites`, after the owner finishes the Brevo and Supabase steps. It touches the same shared files as the others; resolve the v273 clash and README/CLAUDE.md conflicts when merging.
5. **Tutor settings and payout:** `t24c-3-payout` carries `t24c-1`, `t24c-2` and `t24c-3`. SQL order: `tutor_profile`, `tutor_payout`, `payout_permission`.
6. **Cleanup scripts** (`t21-cleanup`): only the docs part is needed in the repo; the owner runs the SQL on DEV when ready.
7. **Before anything reaches `main`:** run every new migration on LIVE first, after a SELECT preview and a yes. Migration order: org_foundation, billing, attendance, tutor_access, org_delete, function_lockdown, org_separation, then the staff, invite and tutor migrations above. See `CLAUDE.md` go-live checklist.

Each of the three groups (t3, t24c, t7) changes shared files (`app.js`, `org-scope.js`, `README.md`, `CLAUDE.md`, the cache-buster in every page), so expect merge conflicts between groups. **Not verified:** whether the groups merge cleanly together.

### 2.4 Where to read what

- Staff attendance code: `origin/claude/t3-3-attendance` (`assets/js/centre-attendance*.js`, `db/migration_staff_attendance.sql`).
- Staff charges: `origin/claude/t3-4-charges` (`assets/js/centre-charges*.js`).
- Staff Students: `origin/claude/t3-2-students`.
- Invite emails: `origin/claude/t7-2-invites` (`api/send-invite.js`).
- Tutor payout details: `origin/claude/t24c-3-payout`.
- Plans for work not started: `T6-plan.md` (tutors manage their own schedule), `T18-plan.md` (credits).

Example: `git show origin/claude/t3-3-attendance:assets/js/centre-attendance.js`.
