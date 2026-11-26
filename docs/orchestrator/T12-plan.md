# T12 plan: keep centre data and solo data apart

Branch `claude/t12-plan`. Plan only: no product code, no SQL changed. Written 2026-11-24 from the code and migrations (no DEV queries run).

## Summary
- A centre owner sees the centre's students, lessons and money on the old solo screens because those screens **don't filter by organisation at all**. They ask the database for "all students" and trust it to hand back only the user's own. Since the centre foundation, the database also hands back every centre the person owns or administers. (The T2 report blamed `tutor_id`; that is half right. The seed also stamps centre rows with `tutor_id = owner`, which is why the 4 Calendar queries that do filter on it leak too.)
- Fix: give every login a **current organisation** and make each solo page ask only for that organisation's rows. For nearly everyone (every live solo tutor) that is their one solo organisation, and nothing visibly changes.
- A centre owner gets a **centre menu and a centre landing page** instead of the solo pages. Someone who is both gets a small **switcher**.
- Recommended: ship it in 4 small steps, starting with a pure database safety net that changes nothing for solo tutors.

## 1. Root cause (what is actually happening)
- Every business table has an `org_id`. Read permission is `org_can_read(org_id)`, true for a centre's owner and staff. That is correct for centre screens.
- The old pages (`students.js`, `ledger.js`, `dashboard.js`, `planner.js`, `invoices.js`, `student.js`, `exams.js`, `settings.js`) read with `from("students").select(...)` and no filter. Only 4 Calendar queries filter on `tutor_id`. So an owner's solo pages show solo **plus** centre rows mixed together.
- **Edits are open too, not just views.** The old solo write policy only covers solo organisations, but the centre owner also passes the new centre write policy (`org_write`, `manage_timetable` / `manage_students`). So from the solo Ledger an owner can tick a centre lesson as paid, delete it, or edit it. This bypasses the centre rules (charge pending, immutable invoices, audit by role).
- **New rows from the solo pages land in the owner's *solo* organisation** (the row guard fills a missing `org_id` with `org_personal(me)`). So "Add student" does not pollute the centre. But it can mix the two: Ledger "generate lessons" reads the centre's weekly slots (visible to the owner) and writes lessons with no `org_id`, which become solo-org lessons pointing at a **centre student**. The row guard does not check that the student belongs to the same organisation. This is the worst hidden risk: a solo lesson, solo invoice and WhatsApp reminder about a centre child.
- **Free-plan counter is safe today.** `org_active_students(org)` and the gate trigger count by organisation and only act on solo organisations, so centre students never count and a centre is never blocked. The screen just *shows* the centre's 8 students beside the counter, which is confusing.
- Staff (not only owners) have the same leak. Centre tutors do not: they have no table access.

## 2. Options for the fix
| | What | Verdict |
|---|---|---|
| A | Each page adds `.eq("org_id", currentOrg)` to every query and write | **Recommended** for the pages. Many call sites (about 90 reads/writes), but mechanical and testable. |
| B | Database-side: a "current organisation" the page tells the database (via a setting on the connection), and the solo policies use it | Fewer page edits, but fragile with Supabase's connection pooling. Not recommended as the main fix. |
| C | Tighten the database so solo pages simply can't see centre rows (solo policy reads only when `org_is_solo`) | Not possible alone: the centre read policy is needed by the centre pages, same table. |
| D | Separate table sets for centres | Far too big; breaks "lessons is the ground truth". |

Recommendation: **A, backed by a database safety net** (step 1 below) so a page we forgot to change can never write across organisations.

**Current organisation concept.** `TL.org()` (in `app.js`, next to `roleMode()`), returns `{ id, kind, role }`. Chosen from the user's memberships: remembered choice (`TL.store`, per user) if still valid, else their solo organisation, else the only centre. Detected once in `requireAuth` and cached (12 h like `roleMode`). Any error or doubt = **their solo organisation** (what everyone has today). Solo pages then use `TL.org().id`, never "everything I can see".

**Switcher.** Only shown if the person has more than one organisation (solo + centre, or two centres). A small name chip in the header opens a list; choosing one reloads into that organisation's landing page. Single-organisation users never see it.

## 3. What a centre owner sees instead
- Menu when the current organisation is a centre: **Centre home · Centre (the existing /org page) · Settings**. No Ledger, Students, Planner, Invoices, Exams: those are solo screens.
- Landing page: the existing `/org` page for that centre (setup steps, people, branches, plan, audit). It is the "centre home" for now. Also fixes T2's D5 (no menu entry for the centre).
- **Now (T12):** hide the solo screens and show the centre home. A solo screen opened by typing the address redirects to the centre home when the current organisation is a centre.
- **Later:** T3 adds centre students, timetable, attendance and charge screens to the centre menu. T4 adds centre invoicing and payments. Until then a centre owner can't view or edit centre lessons from the solo screens. **Decision for the owner:** that is a temporary loss for owners who were peeking at the lists; the demo centre is on DEV only, and no live centre exists yet (nothing is on LIVE).
- A solo tutor who is a **tutor** at a centre keeps the existing "My lessons" in More (unchanged).

## 4. Where Add student / lesson / payment write
- In a solo organisation: exactly as today, with `org_id` now filled in by the page explicitly (same value the database filled in before).
- In a centre: the solo forms are not reachable. T3/T4 screens will write with the centre's `org_id`.
- Database safety net: the row guard also refuses a lesson, slot, invoice or exam whose **student belongs to a different organisation**. This closes the cross-organisation pointer, whatever the page does.

## 5. Free-plan counter
No change to the counting rules (already per organisation, solo only, grandfathered tutors unlimited). Plan card and the "5 active students" meter read the **current** solo organisation only. A centre owner who also has a solo organisation sees their solo count in the solo organisation and never the centre's students. Add a test that a centre's students never move a solo tutor's count, and vice versa.

## 6. Database changes (DEV first, never LIVE until the owner ships)
Small and additive, one migration `db/migration_org_separation.sql` (with `_down`):
1. Row guard: a row's student must be in the same organisation (`students.org_id = new.org_id`) for `lessons`, `recurring_slots`, `invoices`, `exams`. Tests: cross-org insert refused; same-org passes; solo tutors' existing flows pass (run on the seeded solo data).
2. Optional: a helper `org_current_ok(org)` only if we later want server-side checks; not needed for step 1.
3. No policy loosening. Do not remove the centre read policy.

Tests: `tests/sql/org_separation_test.sql` (guard cases above; a centre owner cannot create a lesson against a solo student and vice versa); a new `tests/org-current.test.js` (pure logic: choose current org from memberships, remembered choice, fallback to solo on error); browser check as centre.owner on the preview (no student names on any solo page; redirect to centre home), as solo.tutor (unchanged), as both.tutor (switcher shows and works); update `tests/smoke.py` page list.

## 7. Risks to existing solo tutors on LIVE
- Every current live user is a solo organisation of one with no other membership: `TL.org()` returns that organisation and the new `org_id` filter matches every row they have (the migration backfilled all rows). Verify with a SELECT preview on LIVE before shipping: count of rows per table where `org_id` is null or not the user's solo org should be 0. **No change to data.**
- Rows with a null `org_id` would disappear under a strict filter. Mitigation: the filter step ships only after that preview shows zero; code treats null as "mine" until then.
- Any page missed in the sweep keeps working as today (reads still unfiltered, but writes protected by step 1's guard).
- The row-guard change applies to LIVE only when the migration is run there at shipping time (after org foundation). The guard can't break solo rows: their students and lessons are already in the same organisation.
- Mobile and cache: bump `?v=` once per code step; keep the 820px layouts.

## 8. Build order (each step separately shippable)
1. **Safety net in the database** (migration + SQL tests, DEV only). Changes nothing visible for anyone. Stops cross-organisation pointers.
2. **`TL.org()` + `roleMode` update, no page changes yet** (unit tests). Adds the current-organisation concept and switcher widget (hidden unless more than one organisation).
3. **Solo pages filter by current organisation** (students, ledger, calendar, dashboard, planner, invoices, student, exams, settings; one PR per 2–3 pages if easier to review). Browser-check as solo.tutor and centre.owner.
4. **Centre menu and centre home**, solo pages redirect when current org is a centre; centre owner's More/Settings entry for the centre (fixes D5, and D4 for tutor-only logins by sending them to My lessons).
Steps 1–2 are safe to ship together; 3 is the one to test on a preview with all five demo logins; 4 can wait for T3 if the owner wants.

## Decisions needed from the owner
1. Is it OK that, from step 3, a centre owner can't see or edit centre students/lessons on any old screen until T3/T4 provide centre screens (the "different" you asked for)?
2. Switcher: a header chip for people with more than one organisation. OK, or should "both" users sign in to one place at a time?
3. Should centre **staff** (admins, not owners) also land on the centre home (yes recommended)?
4. Ship step 1 alone to `dev` first (invisible), then steps 2–4 together?
