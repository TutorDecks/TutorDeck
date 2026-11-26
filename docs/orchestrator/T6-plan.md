# T6 plan: tutors schedule their own lessons (centre option)

Branch `claude/t6-plan`. Plan only: no product code, no SQL. Written 2026-11-26 from `CLAUDE.md`, `assets/js/org-settings.js`, `tutor.js`, `tutor-core.js`, `db/migration_tutor_access.sql`, `db/migration_org_foundation.sql`, `calendar.js` / `planner.js` / `ledger.js`, the T3 / T18 / T24b plans, and the branches `claude/t3-1-staff-home` … `t3-4-charges`. "Not verified" = I did not check it in code.

## Summary
- **Yes, it can be an option.** Opus Tuition (remote 1-to-1) needs nothing the product principle forbids: it is a centre process choice, so it is a setting, built completely, with a test per value. The setting already exists as `lessons.timetable_editing` with `tutors_own` marked `soon` (`org-settings.js` l.122).
- **Design:** the setting gets three values (`admin_only` built; `tutors_direct`; `tutors_propose`), plus a list of **switches** (which abilities) and **limits** (notice, max changes, notify family, lock marked/invoiced lessons). All `soon` until built.
- **Fixed for integrity:** tutors never see or set price, rate, amount, paid; only their OWN lessons and ASSIGNED students; nothing on a marked, paid or invoiced lesson; every change audited; centre timezone; no table access, only new `SECURITY DEFINER` functions.
- **Money problem to solve first:** `lessons.rate` and `recurring_slots.rate` are `not null`, and a tutor must not type them. A tutor-made lesson needs a price source chosen by the centre (decision 1).
- **Two gaps in the database today:** no `recurring_slots.taught_by` and no student-to-tutor assignment (both planned in T3 step 7, not built; `lessons.taught_by` is the only link). T6 builds on T3 step 7, so **start after T3 steps 6-8.**
- **UI:** a new tutor tab **Schedule** (week list, same bottom-sheet style as My lessons), no money anywhere.
- Six small steps (section 6); step 1 is read-only and risk-free. DEV only until the owner says ship.

## 1. The setting (what the centre chooses)
`lessons.timetable_editing`:

| Value | Meaning | Status |
|---|---|---|
| `admin_only` | Tutors cannot change the timetable (today) | built |
| `tutors_direct` | Tutors change their own lessons themselves; staff are told | `soon` |
| `tutors_propose` | Tutors send a request; staff approve or decline; nothing changes until approved | `soon` |

`tutors_own` (the current key) is renamed `tutors_direct`; nothing reads it today and no saved setting can hold it (it is `soonOptions`; SQL default is `admin_only`, `migration_org_foundation.sql` l.403). Whether `org_validate_settings` (l.325) checks this key: not verified; it must, after the change.

**Switches** (shown only when the value is not `admin_only`; each is its own toggle, all `soon`): `tutors_edit.weekly_slots` (add / change / stop own weekly slots), `tutors_edit.generate` (create own lessons from own slots), `tutors_edit.one_off` (add one-off lesson), `tutors_edit.postpone` (move a lesson, and revert it), `tutors_edit.cancel` (cancel with no charge; see 2), `tutors_edit.link` (set the online lesson link). Marking attendance is NOT here; it stays under `attendance_by` (built).

**Limits** (all `soon`): `min_notice_hours` (0-168, default 24: a lesson can't be moved or cancelled closer than this to its start), `max_changes_per_month` (0 = no limit, per tutor), `notify_family` (`off` / `list_for_admin`; sending to parents is `soon` until the email provider, T7), `lock_marked` (always on, see 2), `students` (`assigned_only`, fixed; not a setting).

Defaults when the value is first switched on: all switches off except postpone; notice 24h. A centre turns on only what it wants. If the value is `tutors_propose`, every switch means "may request this".

## 2. What stays fixed (integrity, never a setting)
- Tutors have **no table access**. Every action is a new function that checks caller, centre, setting, switch, limit, then writes; same `NOT_FOUND` for "not yours / doesn't exist" so ids can't be probed (as `tutor_mark_attendance`, `migration_tutor_access.sql`).
- **No money:** no function returns or accepts rate, amount, paid, compensation, `*_cents` (explicit column lists, never `l.*`; a test greps the return columns). A tutor cancelling a lesson never types a charge: the cancel is "cancelled in advance, charge decided by staff" (null compensation = pending, the existing meaning); a tutor who may type a charge today (`compensation_entered_by = tutor`) keeps that only on the attendance screen, unchanged.
- **Own lessons, assigned students only.** Own = `lessons.taught_by` is the caller's active membership. Assigned = see decision 2.
- **Not on a lesson that is marked, paid or invoiced.** `attendance is not null`, `paid = true`, or its id inside `invoices.data.lesson_ids` (`migration_org_separation.sql` l.8 shows that is where invoices list lessons; whether centre invoices will use the same field: not verified, T4 not built). Staff keep their own screens for corrections.
- **No change in the past**, nor inside the notice window; dates are the centre's day (`organisations.timezone`, as `tutor_mark_attendance` does).
- **Audit:** `lessons` and `recurring_slots` already have the `audit_row` trigger (l.311-318), so every write is logged with the actor. T6 adds a reason text and a "who changed it" flag the staff list can read (section 4).
- **Solo tutors:** all functions return `NOT_FOUND` for a solo org; solo Planner/Calendar are untouched.

## 3. Tutor screen
- **Where:** tutor menu gets a second item **Schedule** next to My lessons (`TUTOR_GROUPS` in `app.js` l.36 has one item today; "both" logins get it through the More sheet). Shown only when the centre's setting is not `admin_only`; My lessons stays the daily screen. Tutor-only logins are redirected to `tutor` only (`app.js` l.312): the allowed-pages list must add `tutor-schedule`.
- **Week list, not a grid** (phone-first, same as T3 timetable): days, each lesson a row (time, student, subject, chip). Tap = bottom sheet with the allowed actions only: **Move** (date + start + end), **Revert to original slot**, **Cancel**, **Online link**. Same words and behaviour as solo Calendar: Move marks the lesson `postponed` and keeps `slot_date` so no phantom "not logged" lesson appears (`calendar.js` `savePostpone` l.833; revert l.815-832).
- **My weekly slots:** a list (day, time, student) with Add / Change / Stop; the form has student, day, start, end, subject, link. **No rate field, no split, no ledger, no invoice.** (Solo planner has rate and split; they are removed, not hidden.)
- **Clash warning:** the same rule as solo (`calendar.js` l.204-230: overlap with another real lesson), but against the tutor's OWN lessons only; the function returns a plain "you already teach X then" without naming other tutors' students.
- **Holidays** are shown as a grey band, and a Move to a holiday is refused with the holiday's name (T18 step 3 supplies the helper; until then holidays are display-only).
- **Differences from solo:** no price, no ledger/invoice/paid chips, no Google Calendar sync, no "log lessons for a range" button (that is "Create lessons" for own slots only, 4 weeks max), every action has a plain refusal message from the same error words the database raises (as `TC.errorText`, `tutor-core.js`).

## 4. How it fits with the rest
| Area | Rule |
|---|---|
| Staff timetable (T3) | Staff see everything and can override. A change by a tutor is shown with an **amber "changed by tutor"** chip for 7 days and listed in a **"Tutor changes"** list on staff Home (read from `audit_log` via a small staff function, permission `manage_timetable`; `view_audit_log` is not required). `tutors_propose`: requests appear there as "Waiting for you" with Approve / Decline. |
| Generator (T3 step 7) | Tutor's "Create lessons" calls the same generator for ONE tutor's slots, with the same key (slot + date) so pressing it twice, or staff pressing it too, creates nothing twice. |
| Holidays (T18) | Generator and Move skip/refuse holiday dates once T18 step 3 is built; before that, nothing is skipped (say so). |
| Replacement / cover | A tutor cannot give a lesson to another tutor (that is `replacement_tutors`, staff only). If the original tutor cancels, staff see it and may cover. |
| Make-up credits (T18) | A postponed lesson is the same row moved: no credit used, no second charge. A **cancel by the tutor** creates no credit by itself; staff decide (when T18 step 4 exists). Tutors never see credits. |
| Attendance | Unchanged. "Marked" locks scheduling; a move or cancel before the day is the tutor's, marking on or after the day is `tutor_mark_attendance`. |
| Trials | A tutor adding a one-off lesson for a student cannot set the trial flag (still `trials_flagged_by`). |
| Group lessons | Tutor may move/cancel a whole `session_id` group of their own only as one action (all or nothing); adding a student to a group: not in T6 (staff only). |
| Invoicing (T4) | Not touched; a lesson with null price (decision 1) must block invoicing like a pending charge. |

## 5. Remote 1-to-1 (Opus)
- **No rooms, branches or classes needed:** staff attendance already states a remote centre works with just student + time (`migration_staff_attendance.sql` header, branch `t3-3`); T6 does the same.
- **Online link:** there is no link field anywhere (grep of `assets/js`, `db`: none; `students.location` exists but is free text for where you teach). Needs `students.online_link` (default per student, staff-set or tutor-set if `tutors_edit.link`) and `lessons.online_link` (override for one lesson). Tutors and staff see it; it is not money. Link must be `https://`, max 500 characters (rejects `javascript:` etc.).
- **Time zones:** the whole app is Singapore time: `organisations.timezone` default `Asia/Singapore` and the wizard offers only that value (`org-settings.js` l.43); calendar Google sync is hard-coded `Asia/Singapore` (`calendar.js`). If Opus has tutors or students abroad, T6 needs **a time zone per student** (display "their time" next to ours) and a per-centre rule that lesson times are stored in the centre's zone. Not needed for step 1-4; ask Opus where their people are (decision 6).

## 6. Database, tests and build order
All on DEV first; LIVE only when the owner says ship, before the code that needs it (CLAUDE.md data warning). New file `db/migration_tutor_schedule.sql` + `_down.sql`; order after the T3 migrations (staff_home / students / attendance) and the T3 step-7 slot migration. **Needs from T3 step 7:** `recurring_slots.taught_by`, `session_key`, `org_generate_lessons`. **New in T6:** `students.online_link`, `lessons.online_link`, `lessons.changed_by_tutor_at`, a `student_tutors(student_id, membership_id, org_id)` table (decision 2), a `schedule_requests` table (only for `tutors_propose`), the settings above in `org_validate_settings`, and these functions: `tutor_my_slots`, `tutor_save_slot`, `tutor_stop_slot`, `tutor_generate_lessons`, `tutor_add_lesson`, `tutor_postpone_lesson`, `tutor_revert_lesson`, `tutor_cancel_lesson`, `tutor_request_change` + `staff_decide_request`. `tutor_my_lessons` gets a wider range only for the schedule screen (it stops at 62 days already).

**Tests (SQL, `tests/sql/`, one file `tutor_schedule_test.sql`):** for EACH setting value and switch: allowed, refused with the exact error word; limits at the edges (notice 0 / 24 / 168 h; max changes at the limit and one over); not own lesson, not assigned student, solo org, parent, disabled member, other centre: all `NOT_FOUND`; marked / paid / invoiced lessons refused; past date and today inside notice refused; centre timezone around midnight; result columns contain no money (a query on `pg_proc` return types); direct table writes by a tutor still impossible; audit row written; `tutors_propose` approve writes once, decline writes nothing; running generate twice creates nothing twice. JS: `tests/org-settings.test.js` checks the new options match the SQL; `tutor-core` unit tests for the plain-words errors; a browser check `tests/tutor-schedule.check.js` (390px) like `tutor-page.check.js`.

**Build order (each its own branch, shippable alone):**
1. **Read-only Schedule + setting plumbing.** Settings and `org_validate_settings`; `tutor_my_slots`; Schedule tab shows own slots and 4 weeks of own lessons; value `admin_only` hides the tab. *Done =* centre.owner sets the value, tutor.one sees the tab with no buttons; `admin_only` hides it. *Click:* centre.owner Settings → Tutors and lessons → "Who edits the timetable"; tutor.one signs in, sees Schedule.
2. **Move, revert, cancel** (`tutors_direct`). *Done =* moves a future lesson; refused inside the notice window; refused on a marked lesson; a staff list shows it amber. *Click:* tutor.one moves tomorrow's Aiden lesson; centre.staff opens the timetable and sees "changed by tutor"; try today's marked lesson: refused.
3. **Own one-off lessons** (with the price source from decision 1, assigned students). *Click:* tutor.one adds a one-off for Aiden; tutor.two cannot find Aiden.
4. **Weekly slots + create lessons.** *Click:* tutor.one adds a slot, presses Create; pressing twice adds nothing; tutor.two's My lessons unchanged.
5. **Online link + limits** (max changes, notify list). *Click:* set max 1 per month; second move refused with a plain message.
6. **Propose and approve** (`tutors_propose`). *Click:* tutor.one asks to move; centre.staff approves; the lesson moves once.
Logins: `centre.owner@`, `tutor.one@`, `tutor.two@example.test` (in `db/seed_dev_demo.sql`, password in that seed file); `centre.staff@example.test` exists only on the T3 branches until they merge (its line is in that branch's seed). Every step: `?v=` bump, README log, mobile check at 390px.

## 7. Risks and decisions for the owner (recommendation first)
1. **Price of a tutor-made lesson.** Recommend: a tutor's lesson takes the rate of that student's latest staff-made slot or lesson; if none, it is created with **price pending** and staff must fill it before invoicing (blocks invoicing, like a pending charge). Alternative: a per-student fee set by staff (needs fee plans, still `soon`) or tutors may only schedule students who already have a staff price.
2. **Which students are "assigned".** Recommend: an explicit `student_tutors` list staff maintain (clear, auditable). Alternative: derived from "has a lesson with me in the last 90 days", cheaper but a tutor with no lesson yet can never be given a student.
3. **Direct vs propose.** Recommend building **both**, direct first (steps 2-5) then propose (step 6): Opus asked for "handle scheduling", and direct is far less work for them; propose is what a stricter centre will ask next.
4. **Cancel by a tutor.** Recommend: tutor cancels in advance with no charge to the family and staff see an amber flag; no automatic make-up credit. Alternative: tutor cancel = "needs staff approval" always.
5. **Family notice.** Recommend: build the staff list now (who must be told), send emails only with T7. Alternative: wait for the email provider before shipping any tutor change.
6. **Time zones (Opus).** Recommend: ask Opus first; if all in Singapore, defer. If not, add per-student time zone before step 3. I did not verify what Opus needs.
