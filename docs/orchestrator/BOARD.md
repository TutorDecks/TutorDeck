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

## Owner decisions 2026-11-24 (evening)
- T12 plan approved: centre owner loses solo-screen view of centre data until T3/T4; org switcher for multi-org people; centre staff land on centre home; ship the DB safety net (step 1) to dev first.
- T18: one missed lesson = one credit, make-up never charged twice (centre setting, unbuilt options `soon`); credit earned for notice-given absences, tutor cancellations and holidays; credits never expire by default; centres skip holidays by default; holiday library for solo tutors later; SG holiday dates from MOM, re-check 2027 before shipping; add next year's rows each November.
- ~~Settings stays reachable for tutor-only logins (T15).~~ CHANGED 2026-11-25: Settings is for solo, both and centre owner only, NOT for tutors under an org (T24). My lessons NOT added for solo tutors. DEV Supabase password rules set to match LIVE (lower, upper, digit, symbol).
- Bundle rule: second test bundle proposed = T19 + T15 + T20 + T12a (+T18a); owner says go.

- 2026-11-25 T12b decisions: hide switcher chip + default current org = centre when the person owns a centre and has no solo students; tutor-only never gets a chip; phone chip at top of page; null current org (LIVE today, no org tables) = no filtering.

- 2026-11-25 T3 plan decisions, all six YES (owner replied six yeses; read as the T3 list): admins with manage_timetable may correct any mark with a required reason (audit-logged), tutors never; pending charges typed by `issue_invoices`; staff can always mark/correct (attendance_by only governs tutors); group classes light (shared session_id); absence-charge setting only pre-fills, admin confirms; start only after T12 steps 1-4 are on dev, ship steps 1-5 as "centre staff v1". T3 build NOT started until T12 is on dev.

- 2026-11-25 T7 decisions: all five YES (invite landing = reuse /reset welcome variant; link expiry 24h; Brevo free plan for now (stay on Brevo, Resend not worth switching: Resend free = 100/day, 3000/month, Pro US$20; Brevo free = 300/day); previews only email @tutordeck.com.sg + allow-list; centre name in display name, address stays noreply@). ADDED REQUIREMENT: admin must have a Resend-invite option for invites not accepted in time. REPLY-TO DECIDED 2026-11-25: tutordeckadmin@gmail.com for launch (sender stays noreply@tutordeck.com.sg). DNS facts (Vodien): apex A 216.198.79.1 + www CNAME = Vercel; MX points at the apex (Vercel), so the domain CANNOT receive mail today; mail./ftp. CNAMEs are default leftovers; Brevo DKIM x2, brevo-code TXT and DMARC (p=none) are present. Before the first paying centre: set up a real support@ mailbox (Google Workspace or forwarding service) and replace the MX; do not touch other records.
- 2026-11-25 T24 CHANGED AGAIN: tutors under a centre SHOULD have settings (name, password, payout details bank/PayNow, delete account). Solo Settings page stays closed to tutor-only; a small tutor settings page is planned (T24b). T24 branch (v266 redirect) stays valid.

- 2026-11-25 T24b decisions, all YES: delete = request to centre owner (one-tap approve, auto-OK after 7 days) then erase login+personal data, lessons/attendance stay as "Former tutor"; new permission `view_payout_details` (owner always, staff opt-in); old payout rows erased 12 months after leaving (confirm with the company's adviser); bank-account encryption later (plain+functions+masked+audited now); amber flag for 7 days when payout details change. T12c: menu label "Centre" for one centre, "Centres" for more than one; NULL_IS_MINE=true until a LIVE preview shows zero null org_id rows (on the live-shipping checklist).

- 2026-11-25 OWNER GO: merge bundle 3 (#127) into dev as soon as CI is green (contrast fix in progress), then send the owner the test list. (Owner go given in own words: "fix, deploy and tell me what to test".)

- 2026-11-25 owner: "continue with the rest first, I will test later" => workers continue in parallel; bundle 3 test list already sent; nothing else needs merging until owner tests.

- 2026-11-25 owner "all yes" on T3.1 decisions (tab permissions; centre.staff has 8 perms; past-unmarked = 60 days; distinct icon later) and T7.2 decisions (staff with Manage tutors may resend; welcome page says Welcome to TutorDeck; claim at most every 30 min per login; add the 2 new test files to .github/workflows/checks.yml in a bundle). Owner also asked: app must handle BOTH tuition centres and 1-to-1 (remote) centres such as Opus Tuition: design goal for all centre work: never require class/room/branch; 1-to-1 lessons first-class; add online lesson link + tutor pay per lesson in T4/T3 planning.
- DEV migrations pending apply (owner said all yes; GitHub was 503 so orchestrator could not read files): migration_staff_home.sql then seed_dev_demo.sql (t3-1), migration_invites.sql (t7-2), migration_tutor_profile.sql (t24c-1). Apply order: staff_home, invites, tutor_profile. Via orchestrator's Supabase connector (reaches DEV tuzxsqkfzrjssnpcoale) after GitHub is back.

- 2026-11-25 night: owner asked me to keep working until 10:00 SGT 2026-11-26 and then report. Scheduled check-ins + the 10:00 report (send_later). No merges into dev meanwhile (owner tests later), no LIVE. Orchestrator's Supabase connector is READ-ONLY on DEV (write refused), so DEV SQL is run by the owner.

- Version-number clash to fix when bundling: t7-2-invites v273 and t24c-1-profile v273 (t3-1 v272); the bundle assembler picks one final number.

- 2026-11-26 10:00 SGT report sent. Both T24c.5 sessions (original + restart) sat PENDING for hours and never started: infrastructure issue; recreate from `dev` base if still stuck.

- 2026-11-26 owner approved the docs-only merge into dev (needs: CI green first). Purpose: owner wants a Claude chat to design a Service Agreement proposal etc, so the repo on dev must hold the facts (SERVICE-AGREEMENT-FACTS.md).

- 2026-11-26 T6 decisions: owner YES to 1-5 (tutor-made lesson price = rate of that student's latest staff-made slot/lesson, else price pending and staff must fill before invoicing; assigned students = explicit student_tutors list maintained by staff; build both direct and propose, direct first; tutor cancels in advance = no charge + amber flag for staff, no automatic make-up credit; family notice: build the who-must-be-told list now, emails with T7). #6 time zones: owner asked what it means; recommendation: ask Opus whether any tutors/students are outside Singapore; if yes add per-student time zone BEFORE the tutor scheduling step. T6 build starts after T3 steps 6-8.
- 2026-11-26 T3.4b worker started to fix one failing SQL assertion (charges test ~line 138) on claude/t3-4-charges.

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
| T3 | **Staff screens for centres** (plan first, owner approves the plan): timetable (assign tutors, replacement tutors), mark/correct attendance, type pending charges (cancelled lessons with empty compensation), flag trials, cancellations marking | planning (see T3 row below) | — | Everything driven by the centre settings; solo flows unchanged; tests at DB level first. |
| T4 | **Centre invoicing & payments** (Phase 3): invoice runs from lessons (cancelled + compensation rule; pending charge blocks invoicing), households, GST per centre setting, credit notes, manual PayNow recording | todo | — | Plan first. Money in integer cents via `assets/js/money.js`. |
| T5 | Browser-test the **sign-up password hint** branch and decide on a PR | MERGED into dev 2026-11-24 (#123) | NEW worker session_01CPTfbBbKbHFCNEfzmTTt59 / `claude/modest-hypatia-lxmmks` (old session ...E24 idle) | Independent of the rest. Preview now uses DEV, so test with a fresh sign-up there. |
| T6 | **Tutors manage their own schedule** (centre option; Opus Tuition request 2026-11-26: planner, calendar, logging lessons, postpone, cancel; remote 1-to-1) | planning (plan only) | NEW worker / `claude/t6-plan` | Own-lesson reschedule rules as a setting-driven database function; same no-table-access rule. |
| T7 | **Email via Brevo** (owner chose Brevo, sender noreply@tutordeck.com.sg; domain tutordeck.com.sg verified in Brevo 2026-11-25): Supabase auth emails via SMTP, tutor invite email + set-password landing, later remarks reminders | plan DONE (`claude/t7-plan`), 5 owner decisions pending; owner added sender noreply@tutordeck.com.sg in Brevo (verified 2026-11-25, active) | `claude/t7-plan` |
| T8 | **Go-live execution** (owner-gated, see Waiting #5) | todo | — | Do not start without the owner's explicit word. |
| T9 | Centre pricing review (S$100 + S$0.40 vs competitors) | todo | — | Owner decision; only research if asked. |
| T11 | Stub `/api/gcal` in `tests/server.py` so smoke CI is green | MERGED into dev 2026-11-24 (#125) | session_01CPTfbCu6T7y8P8douwp4Nh / `claude/t11-gcal-test-stub` |
| T12 | D1 (medium): centre owner's solo screens show the centre's data. OWNER DECIDED 2026-11-24: centre and solo must be separate. Plan first. | plan DONE (branch `claude/t12-plan`), waiting on 4 owner decisions | worker / `claude/t12-plan` (docs/orchestrator/T12-plan.md); feeds T3/T4 |
| T13 | D2 (low): step 7 contradictory messages for window -3 | todo | |
| T14 | D3 (low): "remarks due" uses browser time zone, no label; use centre timezone | todo | |
| T15 | D4 (low): redirect tutor-only logins away from solo pages (owner said yes) | DONE on branch (v262, no PR); owner to decide if Settings hidden for tutor-only | `claude/t15-tutor-redirect` |
| T16 | D5 (low): centre owner has no menu entry for /org | todo | |
| T17 | Delete throwaway DEV user `t2-throwaway-...@example.test` (still exists 2026-11-24; its centre owner so app deletion refuses; no password) + its solo org + "T2 Test Centre" | → T21: worker prepares preview + script (not run); owner approves, then run on DEV | |
| T21 | Prepare DEV-only cleanup script + SELECT preview for T17 | DONE: preview/delete/postcheck SQL in docs/orchestrator/t21/, tested on scratch DB; nothing run on DEV; owner runs preview.sql first | `claude/t21-cleanup` |
| T18 | Holidays (selectable Singapore public-holiday library, never auto-applied) + make-up credits (one owed lesson = one credit? explain in app); investigate + plan | plan DONE (`claude/t18-plan`): no credits exist today; owner decisions pending | worker / `claude/t18-plan` |
| T19 | Sign-up password rules: make the hint list the exact rules the backend enforces (capital, number, symbol...) so weak passwords are caught before the backend error. Needs the DEV/LIVE Supabase password-requirement setting from the owner | DONE on branch, no PR (owner: LIVE rule = lowercase, uppercase, digit, symbol; owner sets DEV to match) | NEW worker / `claude/t19-password-rules` |
| T20 | Plan card shows card on file (brand, last4, expiry; "No card on file"; Update card) | DONE on branch, untested vs real Stripe | `claude/t20-card-on-file` |
| T12a | T12 step 1: DB same-organisation guard (migration_org_separation) | DONE on branch (migration + SQL tests; DEV apply status to confirm) | `claude/t12a-org-guard` |
| T18a | T18 step 1: mark unbuilt settings `soon` | DONE on branch (v263, six settings marked soon) | `claude/t18a-honest-settings` |
| T22 | Assemble bundle 2 (T19+T15+T20+T12a+T18a) into one PR to dev; owner approved 2026-11-24; orchestrator merges after CI + owner go | MERGED into dev 2026-11-25 (#126, v264, CI green) | `claude/bundle-2` |
| T23 | Password hint -> checklist, tick turns green (house teal) when met (owner request after testing bundle 2) | DONE on branch | `claude/t23-password-checklist` |
| T24 | Settings CLOSED to tutor-only logins (supersedes earlier decision); open to solo/both/centre owner. Also: how do tutors change password / delete account? | DONE on branch (v266); owner to pick password option: 1 now (Forgot password), 2 later (Account sheet) | `claude/t24-settings-closed` |
| T12b | T12 step 2: TL.org() current organisation + switcher (hidden for single-org users) | DONE on branch (v267), 4 non-blocking decisions | `claude/t12b-current-org` |
| T18b | T18 step 2: SG public holiday library (selectable, never auto-applied; 2026+2027 verified vs MOM) | DONE on branch (v268); 2027 dates re-check before main | `claude/t18b-holiday-library` |
| T3 | Plan for staff screens for centres (plan only, owner approves) | plan DONE (`claude/t3-plan`), 6 owner decisions pending; start only after T12 steps 1-4 on dev | `claude/t3-plan` |
| T12c | T12 steps 3+4: solo pages filter by current org (null = no filter), centre menu + redirect, centre home | doing | NEW worker / `claude/t12c-org-filter` (v269), builds on `claude/t12b-current-org` |
| T24b | Plan: Settings for centre tutors (profile, password, payout details PayNow/bank, delete account) | doing (plan only) | NEW worker / `claude/t24b-plan` |
| T24c | Build tutor settings page per T24b plan (7 steps, DB first). Step 1-2 (page shell, profile, change password) | DONE on branch (v273, migration_tutor_profile.sql NOT yet on DEV, 135 unit tests, smoke+axe pass; phone accepts +65 then 6/8/9 + 7 digits; tutor-settings added to CENTRE_PAGES in org-scope.js) | `claude/t24c-1-profile`; steps 3-8 later. NOTE for step 5: profile saves write name/phone to the generic audit log, the leave-centre step must scrub it |
| T25 | Assemble bundle 3 (T23 + T24 + T12b + T12c + T18b) into one PR to dev; owner OK needed to MERGE | MERGED into dev 2026-11-25 (#127, v271, CI green after contrast fix) | `claude/bundle-3` |
| T3.1 | T3 step 1: staff seed logins + centre Home (staff_home) | doing | NEW worker / `claude/t3-1-staff-home` |
| T7.2 | T7 code: reset page uses password rules (E2), invite email api/send-invite (E4), admin Resend invite button (E5), owner-steps doc; owner does E1/E3 (Supabase SMTP) later | doing | NEW worker / `claude/t7-2-invites` |
| T3.2 | T3 step 2: centre Students + households (view/add/edit/discontinue), 1-to-1 friendly | doing | NEW worker / `claude/t3-2-students` (on t3-1) |
| T24c.2 | Tutor payout details, tutor side (step 3) | DONE on branch (migration_tutor_payout.sql NOT on DEV) | `claude/t24c-2-payout` (on t24c-1) |
| T26 | One combined DEV SQL pack for the owner (staff_home + staff seed + invites + tutor_profile (+ later ones)) | DONE: docs/orchestrator/dev-apply-pack.sql (+ .md), 4 parts (staff_home, staff seed, invites, tutor_profile); payout/students parts to be appended | `claude/t26-dev-pack` |
| Queue | T3.3 attendance (after T3.2), T3.4 pending charges, T3.5 trial flag, T24c.3 payout permission+centre list, then bundle 4 for owner test | queued | |
| T3.2b | T3.2 first session never started (stuck PENDING 2h); restarted as session_01CPTfbDdz9FJJgAAa8kuWYi; old session_01CPTfbBFWEs2Fsxsigsnx6g to archive later | DONE on branch `claude/t3-2-students` (smoke 70 loads green); migration_staff_students.sql NOT on DEV | |
| T24c.3 | Payout permission view_payout_details + centre list/reveal (step 4) | DONE on branch (5 owner decisions pending; migration NOT on DEV) | session_01CPTfbDq6dGgWnAJwiB6aUY / `claude/t24c-3-payout-admin` |
| T3.3 | T3 step 3: staff attendance view/mark/correct + close the integrity hole (trigger) | DONE on branch (v285, 6 owner decisions to collect, migration_staff_attendance.sql NOT on DEV) | `claude/t3-3-attendance` (on t3-2) |
| T24c.5 | T24b step 5: leave-centre / remove tutor, DB only (+ audit scrub, Former tutor) | first session stuck PENDING 2.5h; RESTARTED as new session (see T24c.5r) | `claude/t24c-5-leave` (on t24c-3) |
| T24c.5r | restart of T24c.5 | doing | NEW worker / `claude/t24c-5-leave`; stuck session session_01CPTfbDBuVSpWbTtCfHzUaq to archive |
| T3.4 | T3 step 4: pending charges (issue_invoices, suggested charge pre-fill) | DONE on branch (migration_staff_charges.sql NOT on DEV; decision: does charged mode suggest 0 for in-time cancellations?) | `claude/t3-4-charges` (on t3-3) |
| T26b | Extend DEV apply pack with payout, payout_permission, staff_students, staff_attendance, staff_charges (+ leave if exists) | doing | NEW worker / `claude/t26b-dev-pack` |
| T27 | Product Guide = SPEC OF THE FINAL PRODUCT (owner: "of the final product not what we have now"): all functions/workflows per role + every centre option; one appendix "Build status" | doing | NEW worker / `claude/t27-product-guide` (docs/product/TutorDeck-Product-Guide.md); then offer Docs/Word/PDF version |
| T28 | Docs-only bundle to dev (current board, all plans, Product Guide, docs/INDEX.md of every unmerged branch, docs/business/SERVICE-AGREEMENT-FACTS.md) so any Claude chat can read it; owner approved merge 2026-11-26 once CI green | doing | NEW worker / `claude/docs-bundle` |
| T3.4b | Fix failing assertion in charges SQL test (line 138) | doing | NEW worker / `claude/t3-4-charges` |
| T10 | Keep CI honest: confirm `.github/workflows/checks.yml` passes on the merge PRs (unit + SQL + smoke incl. the new pages `tutor`) | doing | with T1 | Part of T1. |

## Done (newest first)
- 2026-11-25: bundle 3 (#127: T23 password checklist, T24 Settings closed to tutor-only, T12b switcher, T12c centre/solo separation + centre menu, T18b SG holiday library; v271) MERGED into `dev`. Deployment started (verify READY). NULL_IS_MINE=true. No new migrations.
- 2026-11-25: bundle 2 (#126: T19 password rules, T15 tutor redirect, T20 card on plan card, T12a org guard, T18a soon flags; v264) MERGED into `dev`. Migration org_separation applied to DEV only, NOT LIVE.
- 2026-11-24: owner tested Stripe sandbox checkout + portal + account deletion on the integration preview: all work. Finding -> T20 (card on file not shown in app).
- 2026-11-24: #125 and #124 MERGED into `dev` (owner approved; first test bundle, deploys staging). #123 MERGED too (conflict fixed by worker). `dev` now = v260 + sign-up hint + Calendar test stub. Owner told to test (list sent).
- Previews use DEV, production uses LIVE; demo logins + seed (v260).
- Absent/cancelled billing via compensation; trial flag and charge entry as centre settings (v259).
- Centre rules as sign-up settings: attendance window, cancellations, required remarks (v258).
- My lessons page for centre tutors + role-based menu (v257); tutor database functions (no table access).
- Free-plan prompt on adding a 6th student (v256).
- Account deletion that removes everything (session_01CPTfbDuPMU9Rw1Vtm4rsQK, v255, PR #122 open).
- Function lockdown migration; attendance + monthly centre fee job; webhook hardening; billing core (webhook, checkout, portal).
- Stripe sandbox products/prices; competitor price research; solo plan decisions.
