# TutorDeck board

Last updated: 2026-11-24, verified by the orchestrator (written at the end of the "Stripe / centres" chat, session_01CPTfbBm11QDKUJaZDLiBUC). The orchestrator keeps this current.

## Where things are
| Thing | State |
|---|---|
| Integration branch | `claude/sleepy-bell-xfr6zb`, at v260 (code at `ec54aa8`; board/orchestrator files on top, head `2127a02`). Contains: Phase 1 org foundation, Stripe billing (solo plans, webhook, checkout, portal, centre fee job), free-plan gate + prompt, account deletion (merged in), attendance + centre tutors (My lessons page), centre settings (attendance window, cancellations, charges, trials, remarks), previews-on-DEV config. **Not merged to `dev` or `main`.** |
| PR #122 | `claude/cool-archimedes-wmgz77` → `dev`: account deletion + billing steps 1–3 only (v255). Open. My later work is NOT in it. |
| Other TutorDeck branch | `claude/modest-hypatia-lxmmks`: sign-up password hint (session_01CPTfbE24CDWJiiNfzpQBK6, "Cloudflare preview connection issue"). Pushed, **not browser-tested, no PR**. |
| Old branch | `claude/gifted-cori-wssq1j` (Phase 1, v253): already contained in the integration branch; safe to delete later (owner approval needed). |
| Worker sessions (idle) | session_01CPTfbDuPMU9Rw1Vtm4rsQK (deletion; waiting on owner), session_01CPTfbE24CDWJiiNfzpQBK6 (sign-up hint). |
| **Not TutorDeck, do not touch** | MugCorner sessions (Lesson building…, Surd answer format…, IB/IGCSE notes…, etc.). |
| Production | `main` @ v252 (`6862d4a`). Live site: https://www.tutordeck.com.sg (also tutordeck.vercel.app). Hobby plan. |
| Previews | Every preview + `dev` + local use the **DEV** Supabase project `tuzxsqkfzrjssnpcoale` (dummy data); only the production addresses use LIVE `rnjvswkejbrhbaytutai`. See CLAUDE.md "Data warning". Preview address of the integration branch: https://tutordeck-git-claude-sleepy-bell-xfr6zb-longraphaeljames-8916.vercel.app |
| DEV demo logins | `centre.owner@`, `tutor.one@`, `tutor.two@`, `both.tutor@`, `solo.tutor@example.test`, password in `db/seed_dev_demo.sql` (dummy). Seed script is DEV only. |
| Stripe | Sandbox only ("TutorDeck sandbox"). Products/prices exist (solo S$14.90/mo, S$149/yr; centre S$100 + S$0.40 per billable student). Sandbox webhook points at the integration branch preview WITH a Vercel bypass token in the URL (must be revoked before going live). |
| Migrations | On DEV: all of them (org_foundation, billing, attendance, tutor_access, org_delete, function_lockdown). On LIVE: **none**. Order: foundation → billing → attendance → tutor_access → org_delete → function_lockdown. `bash tests/sql/run.sh` tests them all on a throwaway Postgres (start it first: the cluster is `/var/lib/postgresql/td16`, port 54329, runs as user postgres). |
| Tests | `node --test tests/*.test.js` (76 pass); `bash tests/sql/run.sh` (6 suites + undo check); browser checks `node tests/tutor-page.check.js`, `node tests/env-hosts.check.js` (need `python3 tests/server.py 8765`); static checks `cd tests && python3 -c "import smoke; smoke.static_checks()"`. The full Python smoke suite is not runnable in the cloud container (no Python Playwright) — it runs in CI. |

## Owner's decisions (do not re-ask)
- **STANDING RULE (2026-11-24, all of TutorDeck): no Vercel deploys until the owner says so; any GitHub Actions run needs the owner's approval first.** Pushes/merges auto-trigger previews and CI, so ask before pushing where possible and before any merge into `dev`.
- **MERGE RULE (2026-11-24, owner):** merge into `dev` only when the owner needs to test something, and then as one complete user flow (not a single feature, not too much). Orchestrator proposes the bundle; owner says go. #123/#124 stay open until then.
- (superseded by the rule above) 2026-11-24: owner approved merging #123 and #124 into `dev` after T11 (Calendar test stub) finishes — but a merge into `dev` auto-deploys staging, which conflicts with the rule above: HOLD until the owner confirms.
- Solo plan: free ≤ 5 **active students**; Solo Pro S$14.90/mo or S$149/yr; 30-day trial (once per organisation, no card to start); **existing solo tutors keep unlimited** (grandfathered).
- TutorDeck is **not GST-registered** (prices carry no GST); centres choose GST settings themselves.
- Centre fee: S$100 + S$0.40 × billable students (previous month's active students, rounded to nearest 10, halves up). Active = non-trial lesson attended, absent or late-cancelled that month. **Under review** vs SchoolTracs (~S$148/branch at 400 students); owner chose to keep it for now.
- **Product principle:** anything that depends on a centre's own process is a setting at sign-up; we build every option; unbuilt ones are marked "coming soon".
- Absent and cancelled lessons are billed like today: lesson becomes cancelled, billed at its **compensation** (a number; 0 if not charged; empty = charge pending). Who types the charge, who flags trials, who marks cancellations, attendance window, who marks attendance, remarks required: all centre settings (defaults: admin / admin / admin / 14 days / tutor / no).
- Tutors see no parent phone by default (setting); tutors have **no table access**, only two database functions.
- Group classes: one lesson row per student tied by `session_id` (no classes table yet).
- Previews use DEV; production is the only thing on the real database.
- Audit-log retention on account deletion: the worker's choice was "delete all audit rows of the deleted organisation, keep one anonymous marker row" — **owner still to confirm** (see Waiting).

## Waiting on the owner
(2026-11-24: owner approved items 1, 2 and 4 below; item 3, DEV Supabase settings, is still the owner's to do.)
1. Confirm the audit-log retention choice above.
2. Merge strategy: recommendation = merge PR #122 into `dev` first, then open ONE follow-up PR from the integration branch (it will then show only the remainder). Needs the owner's go-ahead; nothing is merged without it.
3. (DONE 2026-11-24) DEV project settings only the owner can change in Supabase: turn off "Confirm email" (or set up SMTP) so sign-ups work on previews; add the preview domain pattern to the redirect/allowed URLs; (optional) Google sign-in for DEV.
4. Whether to give the sign-up password-hint branch a browser test and a PR (it is independent of everything else).
5. Go-live is NOT started. When the owner wants it: the full checklist is CLAUDE.md "Current to-dos" item 6 (LIVE migrations with SELECT preview + dry run on a restored backup, Production env split, Stripe live products + webhook + portal, `CRON_SECRET`, revoke the Vercel bypass token, Vercel Pro, centre price decision).

## Task list
Legend: `todo` · `doing` · `waiting` (on owner) · `blocked` · `done`. Owner sets priority; suggested order below.

| # | Task | Status | Worker / branch | Notes / done means |
|---|---|---|---|---|
| T1 | **Merge plan**: PR #122 → `dev`, then one follow-up PR of the remainder; resolve README/CLAUDE.md/run.sh/vercel.json conflicts; CI green | #122 MERGED into dev. #124 open into dev (`claude/merge-remainder-t1`), only red check = known Calendar `/api/gcal` 501 | session_01CPTfbCvscRa5XGLemp8qip | Needs owner's go-ahead. Do NOT open any PR into `main`. |
| T2 | **End-to-end test on the DEV preview** with the demo logins: sign in (all five), My lessons marking flows, free-plan prompt, plan card → Stripe sandbox checkout → webhook updates DEV, customer portal, centre setup step 7, account deletion on a throwaway demo user; log every defect as a new task | done (local run): all areas pass except not tested: Stripe, account deletion (owner by hand), setting variants, replacement tutors. Report on `claude/t2-report`. Defects → T12-T16 | NEW session (see board) / report on `claude/t2-report` | First real browser test of billing checkout. Use the branch-alias preview address (checkout only accepts it). |
| T3 | **Staff screens for centres** (plan first, owner approves the plan): timetable (assign tutors, replacement tutors), mark/correct attendance, type pending charges (cancelled lessons with empty compensation), flag trials, cancellations marking | todo | — | Everything driven by the centre settings; solo flows unchanged; tests at DB level first. |
| T4 | **Centre invoicing & payments** (Phase 3): invoice runs from lessons (cancelled + compensation rule; pending charge blocks invoicing), households, GST per centre setting, credit notes, manual PayNow recording | todo | — | Plan first. Money in integer cents via `assets/js/money.js`. |
| T5 | Browser-test the **sign-up password hint** branch and decide on a PR | MERGED into dev 2026-11-24 (#123) | NEW worker session_01CPTfbBbKbHFCNEfzmTTt59 / `claude/modest-hypatia-lxmmks` (old session ...E24 idle) | Independent of the rest. Preview now uses DEV, so test with a fresh sign-up there. |
| T6 | **Tutors edit their own lessons** (`timetable_editing = tutors_own`, currently "coming soon") | todo | — | Own-lesson reschedule rules as a setting-driven database function; same no-table-access rule. |
| T7 | **Remarks emails / reminders** (needs an email provider; Resend and Brevo connectors are available) and remarks sent to parents | todo | — | Needs an owner decision on provider before starting. |
| T8 | **Go-live execution** (owner-gated, see Waiting #5) | todo | — | Do not start without the owner's explicit word. |
| T9 | Centre pricing review (S$100 + S$0.40 vs competitors) | todo | — | Owner decision; only research if asked. |
| T11 | Stub `/api/gcal` in `tests/server.py` so smoke CI is green | MERGED into dev 2026-11-24 (#125) | session_01CPTfbCu6T7y8P8douwp4Nh / `claude/t11-gcal-test-stub` |
| T12 | D1 (medium): centre owner's solo screens show the centre's students/lessons/money as their own (rows carry owner's tutor_id); decide what Add student does | todo, needs owner decision | feeds T3/T4 |
| T13 | D2 (low): step 7 contradictory messages for window -3 | todo | |
| T14 | D3 (low): "remarks due" uses browser time zone, no label; use centre timezone | todo | |
| T15 | D4 (low): redirect tutor-only logins away from solo pages (owner said yes) | doing | session_01CPTfbEDw4AWzHoFEvRJePv / `claude/t15-tutor-redirect`, no PR yet |
| T16 | D5 (low): centre owner has no menu entry for /org | todo | |
| T17 | Owner: delete throwaway DEV user `t2-throwaway-mwum2aj0@example.test` + "T2 Test Centre" (DEV only) after testing account deletion on it | waiting | |
| T10 | Keep CI honest: confirm `.github/workflows/checks.yml` passes on the merge PRs (unit + SQL + smoke incl. the new pages `tutor`) | doing | with T1 | Part of T1. |

## Done (newest first)
- 2026-11-24: #125 and #124 MERGED into `dev` (owner approved; first test bundle, deploys staging). #123 MERGED too (conflict fixed by worker). `dev` now = v260 + sign-up hint + Calendar test stub. Owner told to test (list sent).
- Previews use DEV, production uses LIVE; demo logins + seed (v260).
- Absent/cancelled billing via compensation; trial flag and charge entry as centre settings (v259).
- Centre rules as sign-up settings: attendance window, cancellations, required remarks (v258).
- My lessons page for centre tutors + role-based menu (v257); tutor database functions (no table access).
- Free-plan prompt on adding a 6th student (v256).
- Account deletion that removes everything (session_01CPTfbDuPMU9Rw1Vtm4rsQK, v255, PR #122 open).
- Function lockdown migration; attendance + monthly centre fee job; webhook hardening; billing core (webhook, checkout, portal).
- Stripe sandbox products/prices; competitor price research; solo plan decisions.
