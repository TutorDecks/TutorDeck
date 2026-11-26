# T3 plan: staff screens for centres

Branch `claude/t3-plan`. Plan only: no product code, no SQL. Written 2026-11-25 from `org.js`, `tutor.js`, `org-settings.js`, `migration_attendance.sql`, `migration_tutor_access.sql`, `migration_org_foundation.sql`, `seed_dev_demo.sql`, and the T2 / T12 / T18 notes.

## Summary
- A centre owner or staff member gets **5 tabs**: **Home · Timetable · Students · Attendance · More**. "Charges" (pending charges) is a second tab inside Attendance. No solo screens (T12).
- **What exists:** the centre settings page (`/org`), the tables (households, guardians, branches, rooms, terms, holidays, lessons with `taught_by`, `session_id`, `attendance`, `trial`), staff permissions, and the **tutor** side (My lessons and its two functions). **What does not exist:** every staff screen, any staff attendance function, a way to give a weekly slot a tutor, and a centre lesson generator.
- **Three database gaps to close first:** (1) `recurring_slots` has no tutor, so generated lessons have no `taught_by`; (2) staff mark lessons by writing the table directly, which skips the "not before its day / not over someone else's mark" rules; (3) lesson generation only exists in the solo Ledger page.
- **Approach:** database first. Every staff action is one function that checks `org_can(...)`, the centre's settings and the integrity rules, with a test per setting value. Screens only call those functions.
- Ten small steps (section 4). Steps 1–5 give the owner a working daily routine: see the day, mark, fix, type charges. Timetable editing comes after.
- Out of scope: invoices, payments, revenue, tutor pay (T4), make-up credits (T18 step 4), remarks to parents (soon), parent portal.
- Depends on T12 (current organisation, centre menu). Do not start step 1 until T12 steps 1–4 are on `dev`.

## 1. Who sees what (permissions)
Owner = everything. Staff = only what their `permissions[]` allow. The menu hides what a person can't use; the database refuses it anyway.

| Screen / action | Needs |
|---|---|
| Home (counts only, no money) | any owner / staff |
| Students & households: view | any owner / staff (read policy) |
| Students & households: add, edit, discontinue | `manage_students` |
| Timetable: view | any owner / staff |
| Timetable: slots, assign tutors, replacements, holidays | `manage_timetable` |
| Attendance: view | any owner / staff |
| Attendance: mark, correct, flag trial | `manage_timetable` |
| Pending charges: type the amount | `issue_invoices` (money decision; see decision 2) |
| Centre settings, people | owner only (existing) |
| Revenue, invoices, payments | T4 |

No new permission names (the catalogue in `org-settings.js` and `org_invite()` stays as is). Tutors never see any of this; they keep only My lessons.

## 2. Screens
Common to all: **mobile first** (820px breakpoint; lists are single-column cards, actions live in a bottom sheet, one primary button per screen); solo tutors and their pages are untouched; every function returns `NOT_FOUND` for a solo org or a non-member.

### 2.1 Centre menu and Home
- **Menu:** Home · Timetable · Students · Attendance · More (Centre settings = the existing `/org`, People, Plan, Sign out). Staff see only the tabs they can use; More always has Settings (view-only unless owner).
- **Home** (`staff_home(org)`): today's lessons, **lessons not marked yet** (days past), **pending charges**, **lessons with no tutor** (next 14 days), trials this month. Each is a tap-through to the filtered list. Setup checklist while the centre is still in setup. No money here.
- Exists: `/org`. Build: tab bar, Home, `staff_home`. Settings that change it: none.

### 2.2 Students and households
- **List:** search (server-side, 400+ students), filters Active / Ended / Trial, one row = name · level · guardian · tutor(s) this month. **Student sheet:** guardians (name, relation, phone, email), household, level, notes, "lessons run until" (reuses `TL.isEnded`; discontinuing stops their slots), their next lessons, a "Trial" badge if every lesson so far is a trial.
- **Group classes:** a class is the lessons sharing one `session_id` (one row per student, like `tutor_my_lessons` already groups). Button **"Group lesson"** on the timetable adds the lessons for several students at once. No `classes` table now (decision 4).
- Trial is per lesson, not per student; the Students filter "Trial" means "has a trial lesson in the last 30 days".
- Exists: tables, `org_make_households`, `manage_students` policy. Build: `org_save_student(org, student, guardians jsonb, ...)` (atomic), `staff_students(org, q, filter, page)`.
- Settings: none new. `lessons.tutors_see_parent_contact` stays tutor-only; staff always see contact.
- Out of scope: import (wizard step 9 stays), merging households, parent portal.

### 2.3 Timetable
- **View:** day list for the week (not a grid, for phones), filter by tutor / branch, holidays shown as a grey band (existing `holidays` rows), "No tutor" lessons flagged amber.
- **Edit** (`manage_timetable`): add / change / stop a weekly slot with **tutor**, student(s), room, time; one-off lesson; move a lesson; **replacement tutor** for one lesson ("Cover by…").
- Needs: `recurring_slots.taught_by` (+ `session_key` so group slots stay together); `org_generate_lessons(org, from, to)` (skips holidays, ended students, copies tutor and session, safe to run twice, keyed on slot + date). Exists: `lessons_taught_by_guard` (tutor must be active in the same centre; replacement check).
- **Settings:**
  - `lessons.timetable_editing`: `admin_only` (built). `tutors_own` stays `soon` (tutors' own edits are a separate project).
  - `lessons.replacement_tutors`: on (default) = staff can change a lesson's tutor; off = only a lesson with no tutor can be assigned. Both built in the guard; both tested.
  - `calendar.skip_holidays` / `holiday_action` (T18 step 3): `skip_generation` (built with T18), `generate_and_flag` stays `soon`. This plan only shows holidays; skipping is T18.
- Out of scope: Google Calendar sync for centres, rooms clash checks (later), tutor availability.

### 2.4 Attendance (staff)
- **List:** a day or week, filters **Not marked**, by tutor, by student. Row = time · student · tutor · chip. Tap = sheet: attended / absent / late cancelled / cancelled in time, remarks, trial flag, "Correct".
- **Function `staff_mark_attendance(lesson, attendance, remarks…, trial, reason)`:** same field list as the tutor function, plus: staff may mark any lesson of the centre, **any day from the lesson's day (never before it), with no window limit**. Correcting an existing mark needs a **reason** and writes the audit log. Tutors can't use it.
- **Settings and how each value behaves:**
  - `lessons.attendance_by` = `tutor`: tutors mark; staff can still mark or correct (they are the safety net). = `admin`: tutors can't; staff do. Both tested on the staff function and on `tutor_mark_attendance` (already tested).
  - `lessons.attendance_window_days` (1–60): limits tutors only; staff are not limited.
  - `lessons.cancellations_marked_by`: staff can always set the two cancellations; the value only governs tutors.
  - `lessons.remarks.required` = on: staff can't mark **attended** without remarks (same as tutors); off: optional. Correcting an old mark does not re-require them.
  - `billing.absences.mode` (`charged` / `not_charged` / `charged_unless_notice` + `notice_hours`): not a rule here, it pre-fills the **suggested** charge on the Charges tab (decision 5).
  - `lessons.remarks.visibility` (parents see remarks): `soon`, unchanged.
- Status follows attendance (already the trigger's job for centres). Integrity fix: see risk 1.

### 2.5 Pending charges
- **Charges tab:** the queue of lessons with `attendance` in absent / cancelled and `compensation is null`, newest first. Row: student · date · the lesson's full price **(staff see price)** · field "Charge S$" with quick buttons **Not charged (0)** and **Full price**, and the suggested value from `billing.absences.mode`. Save sets `compensation` (0 up to the lesson's own price, same rule as the tutor function). **Bulk:** tick several, "Not charged" for all.
- **Function `staff_set_charge(lesson, amount)`** (needs `issue_invoices`).
- **Setting `lessons.compensation_entered_by`:** `admin` (default): the queue is staff's job. `tutor`: the tutor must type it when marking (`CHARGE_REQUIRED`), so the queue holds only lessons staff marked or old ones; staff can always override with a reason. Tested for both values.
- T4 invoicing must treat `compensation is null` on a cancelled lesson as "not ready". This plan exposes `pending_charge_count(org)` for that.

### 2.6 Trial flagging
- Inside the attendance sheet and the lesson sheet (toggle "Trial lesson"); staff can always flag or unflag. `lessons.trials_flagged_by` (`admin` / `tutor`) only decides whether **tutors** may; both values already tested for tutors, add the staff cases.
- A trial lesson does not count towards the centre's active-student fee (`org_active_students_in_month`). Changing a trial flag or attendance in a month whose fee snapshot already exists does not change that snapshot; the screen says so (risk 4).

## 3. What is built vs must be built
| Already there | Must be built |
|---|---|
| `/org` wizard and settings, people, holidays/branches/rooms (manual) | Centre tab bar, Home, `staff_home` (T12 step 4 supplies the menu switch) |
| Tables: households, guardians, students, lessons columns | Staff Students screen, `org_save_student`, `staff_students` |
| `memberships.permissions[]`, `org_can()`, `org_write` policies | Menu and buttons gated per permission; staff test matrix |
| Tutor functions, `lessons_attendance_stamp`, `lessons_taught_by_guard` | `staff_mark_attendance`, `staff_set_charge`, attendance guard for everyone |
| `holidays` table | Show on timetable; skipping = T18 |
| Seed: owner, 2 tutors, both-tutor, solo | **A staff login** (none today): add `centre.staff@` (manage_students + manage_timetable) and `centre.frontdesk@` (manage_students only) to `seed_dev_demo.sql` |

## 4. Build order (each step is its own branch, tested on its own, shippable alone)
Every step: DEV migration + `tests/sql/*` test per setting value first, then the page; `?v=` bump, README log, mobile check at 390px. LIVE only when the owner says ship.
1. **Staff seed + centre Home.** Staff logins in the seed; menu tabs; `staff_home`. *Done =* centre.owner sees Home with the demo counts (3 today for tutor.one, etc.), centre.staff sees the same, centre.frontdesk sees Students only, a solo login is unchanged. *Test:* sign in as each; counts match Aiden/Mei Ling/Ravi lessons in the seed.
2. **Students and households (view + edit).** *Done =* list, search, sheet, add a student with a guardian, discontinue. *Test:* centre.staff adds "Test Child" with a parent; centre.frontdesk can too; centre.owner sees it; tutor.one still cannot see it (tutor tables 0 rows).
3. **Attendance (view + mark + correct).** `staff_mark_attendance` and the guard. *Done =* mark a today lesson as staff; correct tutor.one's mark with a reason; future lesson refused; audit row written. *Test:* centre.staff opens tomorrow's lesson (no buttons), marks Mei Ling today, then corrects tutor.one's Aiden mark; log shows it. With `attendance_by = admin`, tutor.one is refused and staff succeeds.
4. **Pending charges.** *Done =* queue, single and bulk set, validation 0..price. *Test:* demo has "Sophie Lim late cancelled, charge pending": type 0, it leaves the queue; with `compensation_entered_by = tutor`, tutor must type it when marking.
5. **Trial flag.** Both in sheet and in the Students filter. *Test:* flag Ravi's lesson; Students filter shows it; counts of active students drop by it for the month.
6. **Timetable: read.** Week list, tutor filter, holidays band, "no tutor" flags. *Test:* add a holiday on `/org`, see the band; seed lessons without tutor show amber.
7. **Slots with tutors + generator.** Migration for `recurring_slots.taught_by`/`session_key`, `org_generate_lessons`. *Done =* add a weekly slot, press "Create lessons for the next 4 weeks", they appear once even when pressed twice. *Test:* tutor.two sees the new lessons on My lessons.
8. **Reassign and replacement.** *Test:* with `replacement_tutors` on, cover a lesson by tutor.two (tutor.one no longer sees it); switch off in Settings, the same action is refused with the plain message.
9. **Group lessons.** Several students, one `session_id`. *Test:* tutor sees them as one class in My lessons (existing grouping); staff marks each student separately.
10. **Permission sweep.** One matrix test (owner / staff full / staff students-only / staff timetable-only / tutor) over every function and screen; fix gaps. *Done =* matrix test green, all demo logins checked.
Steps 1–5 are the minimum a centre needs to run attendance day to day. 6–9 can follow.

## 5. Risks
1. **Integrity hole today:** staff writing `lessons` directly bypass "not before its day" and "not over another's mark". Fix: move those two rules into the table trigger so they hold for everyone; a staff **correction** is only possible through the function (it sets a flag the trigger accepts, like `td.deleting_org`). Needs a SQL test that a direct update by staff is refused.
2. **Generator duplicates:** the solo Ledger also generates lessons. T12 hides it from centres; the new function keys on slot + date so a second run does nothing.
3. **Staff see prices and contacts** (by design). Tutors still never do; tests keep checking `tutor_my_lessons` has no money column.
4. **Corrections after a billing snapshot** (fee month already closed): the fee does not change. Show a plain warning; no recompute (T4 / billing owner to confirm).
5. **Scale and phones:** 400 students means paging and server-side search; the week view is a list, not a grid.
6. **Rule drift:** each new option needs `org_validate_settings`, `tests/org-settings.test.js`, and a test per value, or the wizard promises something unbuilt. Anything not built stays `soon`.

## 6. Decisions needed from the owner
1. **Staff correcting a mark.** Recommend: staff with `manage_timetable` may correct anyone's mark through "Correct" with a required reason, logged in the audit log; tutors never. (CLAUDE.md says nobody overwrites another's mark; this is a deliberate exception for admins. OK?)
2. **Who types pending charges.** Recommend: `issue_invoices` (not `manage_timetable`), so a timetable-only receptionist cannot set what a family pays. Alternative: `manage_timetable`.
3. **Does `attendance_by = tutor` stop staff marking?** Recommend no: staff can always mark and correct; the setting only governs tutors.
4. **Group classes.** Recommend the light version now (lessons sharing a `session_id`, created together). A real `classes` table with rosters and fee plans can come with T4 if centres need it.
5. **Charge suggestion.** Recommend `billing.absences.mode` only **pre-fills** the suggested charge and an admin confirms (the queue stays a human decision). Alternative: set it automatically.
6. **Order and seed.** Recommend: start only after T12 steps 1–4 are on `dev`, add two staff logins to the DEV seed (step 1), and ship steps 1–5 together as "centre staff v1".
