"use strict";
const test = require("node:test"), assert = require("node:assert");
const T = require("../assets/js/tutor-core.js");

const TODAY = "2026-11-24";
const L = (o) => Object.assign({ lesson_id: "x", lesson_date: TODAY, start_time: "16:00:00", end_time: "17:00:00", status: "scheduled", attendance: null,
  can_mark: true, can_note: true, topics: null, homework: null, remarks: null, remarks_due_at: null }, o || {});

test("dates and times read naturally", () => {
  assert.strictEqual(T.addDays("2026-11-30", 1), "2026-12-01"); assert.strictEqual(T.addDays("2026-01-01", -1), "2025-12-31");
  assert.strictEqual(T.dateLabel(TODAY, TODAY), "Today"); assert.strictEqual(T.dateLabel("2026-11-25", TODAY), "Tomorrow");
  assert.strictEqual(T.dateLabel("2026-11-23", TODAY), "Yesterday"); assert.strictEqual(T.dateLabel("2026-11-27", TODAY), "Fri 27 Nov");
  assert.strictEqual(T.timeLabel("16:00:00"), "4:00 pm"); assert.strictEqual(T.timeLabel("00:30:00"), "12:30 am"); assert.strictEqual(T.timeLabel("12:00:00"), "12:00 pm");
  assert.strictEqual(T.timeRange(L()), "4:00 pm – 5:00 pm"); assert.strictEqual(T.timeLabel(null), "");
});

test("badge on each kind of row", () => {
  assert.deepStrictEqual(T.chip(L({ status: "cancelled", can_mark: false, can_note: false }), TODAY), { text: "Cancelled", tone: "muted" });
  assert.deepStrictEqual(T.chip(L({ attendance: "attended" }), TODAY), { text: "Attended", tone: "ok" });
  assert.deepStrictEqual(T.chip(L({ attendance: "absent" }), TODAY), { text: "Absent", tone: "muted" });
  assert.strictEqual(T.chip(L({ attendance: "late_cancelled", can_mark: false }), TODAY).text, "Late cancellation");
  assert.strictEqual(T.chip(L({ attendance: "cancelled_early", can_mark: false }), TODAY).text, "Cancelled in time");
  assert.strictEqual(T.chip(L({ lesson_date: "2026-11-25", can_mark: false, can_note: false }), TODAY).text, "Upcoming");
  assert.deepStrictEqual(T.chip(L(), TODAY), { text: "Mark", tone: "action" });
  assert.deepStrictEqual(T.chip(L({ lesson_date: "2026-11-20" }), TODAY), { text: "To mark", tone: "warn" });
  assert.strictEqual(T.chip(L({ lesson_date: "2026-11-01", can_mark: false, can_note: false }), TODAY).text, "Ask an admin");
  assert.strictEqual(T.chip(L({ can_mark: false }), TODAY).text, "Admin marks");
});

test("why a lesson is locked", () => {
  assert.strictEqual(T.lockReason(L(), TODAY), null);
  assert.match(T.lockReason(L({ status: "cancelled", can_mark: false, can_note: false }), TODAY), /cancelled/);
  assert.match(T.lockReason(L({ lesson_date: "2026-11-25", can_mark: false, can_note: false }), TODAY), /from its day/);
  assert.match(T.lockReason(L({ lesson_date: "2026-11-01", can_mark: false, can_note: false }), TODAY), /too long ago/);
  assert.match(T.lockReason(L({ attendance: "late_cancelled", can_mark: false }), TODAY), /late cancellation.*someone else/);
  assert.match(T.lockReason(L({ attendance: "attended", can_mark: false }), TODAY), /Someone else/);
  assert.match(T.lockReason(L({ can_mark: false }), TODAY), /admin marks attendance.*notes/);
});

test("remarks reminder only when notes are open and still empty", () => {
  const due = "2026-11-25T09:00:00Z", now = Date.parse("2026-11-25T08:00:00Z");
  assert.deepStrictEqual(T.remarksDue(L({ remarks_due_at: due }), now), { overdue: false, at: Date.parse(due) });
  assert.strictEqual(T.remarksDue(L({ remarks_due_at: due }), Date.parse("2026-11-25T10:00:00Z")).overdue, true);
  assert.strictEqual(T.remarksDue(L({ remarks_due_at: due, remarks: "Done" }), now), null, "already written");
  assert.strictEqual(T.remarksDue(L({ remarks_due_at: due, remarks: "   " }), now).overdue, false, "blank counts as empty");
  assert.strictEqual(T.remarksDue(L({ remarks_due_at: due, can_note: false }), now), null, "notes closed");
  assert.strictEqual(T.remarksDue(L({ remarks_due_at: null }), now), null);
});

test("sections and their order", () => {
  const rows = [
    L({ lesson_id: "a", lesson_date: "2026-11-20" }),                                              // overdue, unmarked → To mark
    L({ lesson_id: "b", lesson_date: "2026-11-22" }),                                              // overdue, unmarked → To mark
    L({ lesson_id: "c", lesson_date: "2026-11-23", attendance: "attended" }),                      // earlier, done
    L({ lesson_id: "d", lesson_date: "2026-11-21", status: "cancelled", can_mark: false, can_note: false }), // earlier, cancelled
    L({ lesson_id: "e" }), L({ lesson_id: "f", attendance: "attended" }),                          // today (all of them, marked or not)
    L({ lesson_id: "g", lesson_date: "2026-11-26", can_mark: false, can_note: false }),            // coming up
    L({ lesson_id: "h", lesson_date: "2026-11-05", can_mark: false, can_note: false })             // too old, unmarked → Earlier
  ];
  rows.sort((x, y) => x.lesson_date.localeCompare(y.lesson_date));            // the database returns them in date order
  const g = T.group(rows, TODAY), ids = (k) => (g.find((s) => s.key === k) || { rows: [] }).rows.map((r) => r.lesson_id);
  assert.deepStrictEqual(g.map((s) => s.key), ["toMark", "today", "upcoming", "earlier"]);
  assert.deepStrictEqual(ids("toMark"), ["a", "b"], "overdue: oldest first, so the longest-waiting is on top");
  assert.deepStrictEqual(ids("today"), ["e", "f"]);
  assert.deepStrictEqual(ids("upcoming"), ["g"]);
  assert.deepStrictEqual(ids("earlier"), ["c", "d", "h"], "earlier: newest first");
  assert.deepStrictEqual(T.group([], TODAY), [], "no lessons, no sections");
  assert.deepStrictEqual(T.group([L()], TODAY).map((s) => s.key), ["today"], "empty sections are left out");
});

test("database refusals become kind sentences, and unknown ones never leak", () => {
  assert.match(T.errorText({ message: "TOO_OLD: ask an admin to change attendance older than 14 days" }), /too old/);
  assert.match(T.errorText({ message: "ALREADY_MARKED: someone else already marked this lesson; ask an admin to change it" }), /Someone else/);
  assert.match(T.errorText({ message: "NOT_FOUND" }), /isn't assigned/);
  assert.match(T.errorText({ message: "TOO_LONG: keep each note under 2000 characters" }), /2000/);
  const unknown = T.errorText({ message: "permission denied for table lessons (secret detail)" });
  assert.ok(!/permission|secret|lessons/.test(unknown)); assert.match(unknown, /try again/);
  assert.match(T.errorText(null), /try again/);
  assert.match(T.errorText({ message: "ADMIN_ONLY: attendance is marked by an admin at this centre" }), /admin marks attendance/);
});

test("only changed fields are sent", () => {
  const l = L({ attendance: null, topics: "Fractions", remarks: "Good" });
  assert.deepStrictEqual(T.changes(l, { attendance: "attended", topics: "Fractions", homework: "", remarks: "Good" }),
    { attendance: "attended", topics: null, homework: null, remarks: null, trial: null, compensation: null, chargeError: false, any: true });
  assert.deepStrictEqual(T.changes(l, { attendance: null, topics: "Fractions ", homework: "", remarks: "Good" }).any, false, "trailing space is not a change");
  const c = T.changes(l, { attendance: null, topics: "", homework: "Page 4", remarks: "Good" });
  assert.strictEqual(c.topics, "", "emptying a note sends an empty string (clears it)"); assert.strictEqual(c.homework, "Page 4"); assert.strictEqual(c.attendance, null);
  assert.strictEqual(T.changes(L({ attendance: "attended" }), { attendance: "attended", topics: "", homework: "", remarks: "" }).any, false, "same attendance again is not a change");
});

test("cancellation choices appear only when the centre lets tutors mark them", () => {
  assert.deepStrictEqual(T.attendanceOptions(L()).map((o) => o.value), ["attended", "absent"]);
  assert.deepStrictEqual(T.attendanceOptions(L({ can_cancel: true })).map((o) => o.value), ["attended", "absent", "cancelled_early", "late_cancelled"]);
  assert.strictEqual(T.attendanceOptions(L({ can_cancel: true })).find((o) => o.value === "late_cancelled").label, "Late cancellation");
});
test("the centre's remarks rule and refusals are explained", () => {
  assert.match(T.errorText({ message: "REMARKS_REQUIRED: this centre needs remarks before a lesson is marked attended" }), /needs remarks/);
  assert.match(T.errorText({ message: "BAD_VALUE: that isn't something you can mark at this centre" }), /at this centre/);
  assert.match(T.errorText({ message: "TOO_OLD: ask an admin to change attendance older than 3 days" }), /too old/);
});

test("the charge for an absent or cancelled lesson: a number, 0 if not charged", () => {
  assert.deepStrictEqual(T.parseCharge("0"), { ok: true, value: 0 });
  assert.deepStrictEqual(T.parseCharge("25"), { ok: true, value: 25 });
  assert.deepStrictEqual(T.parseCharge(" 12.5 "), { ok: true, value: 12.5 });
  assert.deepStrictEqual(T.parseCharge("S$12.50"), { ok: true, value: 12.5 });
  assert.deepStrictEqual(T.parseCharge("$7"), { ok: true, value: 7 });
  ["", "  ", "-1", "12.345", "abc", "1e3", "12,50", "S$", null].forEach((x) => assert.strictEqual(T.parseCharge(x).ok, false, JSON.stringify(x)));
});

test("charge box and note only where the centre's setting says so", () => {
  const byTutor = L({ tutor_sets_compensation: true }), byAdmin = L({ tutor_sets_compensation: false });
  assert.strictEqual(T.needsCharge(byTutor, "absent"), true); assert.strictEqual(T.needsCharge(byTutor, "late_cancelled"), true);
  assert.strictEqual(T.needsCharge(byTutor, "attended"), false); assert.strictEqual(T.needsCharge(byTutor, null), false);
  assert.strictEqual(T.needsCharge(byAdmin, "absent"), false);
  assert.strictEqual(T.adminChargeNote(byAdmin, "absent"), true); assert.strictEqual(T.adminChargeNote(byAdmin, "attended"), false);
  assert.strictEqual(T.adminChargeNote(byTutor, "absent"), false);
});

test("what is sent when the tutor types the charge, or an admin does", () => {
  const byTutor = L({ tutor_sets_compensation: true }), form = (o) => Object.assign({ attendance: null, topics: "", homework: "", remarks: "", trial: null, compensation: "" }, o);
  // choosing Absent needs a number
  let c = T.changes(byTutor, form({ attendance: "absent" })); assert.strictEqual(c.chargeError, true, "blank charge when marking absent");
  c = T.changes(byTutor, form({ attendance: "absent", compensation: "abc" })); assert.strictEqual(c.chargeError, true);
  c = T.changes(byTutor, form({ attendance: "absent", compensation: "0" })); assert.deepStrictEqual([c.attendance, c.compensation, c.chargeError, c.any], ["absent", 0, false, true], "0 = not charged");
  c = T.changes(byTutor, form({ attendance: "late_cancelled", compensation: "S$30" })); assert.strictEqual(c.compensation, 30);
  // already absent: blank leaves the charge alone, a typed amount changes it
  const already = L({ tutor_sets_compensation: true, attendance: "absent" });
  c = T.changes(already, form({ attendance: "absent" })); assert.deepStrictEqual([c.compensation, c.chargeError, c.any], [null, false, false]);
  c = T.changes(already, form({ attendance: "absent", compensation: "10" })); assert.deepStrictEqual([c.compensation, c.any], [10, true]);
  // attended never sends a charge, even if one was typed earlier
  c = T.changes(byTutor, form({ attendance: "attended", compensation: "99" })); assert.strictEqual(c.compensation, null);
  // when an admin sets the charge the tutor sends none
  c = T.changes(L({ tutor_sets_compensation: false }), form({ attendance: "absent", compensation: "20" }));
  assert.deepStrictEqual([c.attendance, c.compensation, c.chargeError], ["absent", null, false]);
});

test("trial flag is sent only when the centre lets the tutor flag it and it changed", () => {
  const form = (o) => Object.assign({ attendance: null, topics: "", homework: "", remarks: "", trial: null, compensation: "" }, o);
  assert.deepStrictEqual([T.changes(L({ can_flag_trial: true, trial: false }), form({ trial: true })).trial, T.changes(L({ can_flag_trial: true, trial: false }), form({ trial: true })).any], [true, true]);
  assert.strictEqual(T.changes(L({ can_flag_trial: true, trial: true }), form({ trial: false })).trial, false, "unflagging is sent as false");
  assert.strictEqual(T.changes(L({ can_flag_trial: true, trial: true }), form({ trial: true })).any, false, "unchanged is not sent");
  assert.strictEqual(T.changes(L({ can_flag_trial: false, trial: false }), form({ trial: true })).trial, null, "admin-only centre: ignored");
});

test("new refusals are explained", () => {
  assert.match(T.errorText({ message: "CHARGE_REQUIRED: enter the amount" }), /charge/);
  assert.match(T.errorText({ message: "BAD_CHARGE: enter an amount from 0 up to the lesson's own price" }), /up to the lesson/);
  assert.match(T.errorText({ message: "CHARGE_ADMIN_ONLY: x" }), /admin enters the charge/);
  assert.match(T.errorText({ message: "TRIAL_ADMIN_ONLY: x" }), /admin flags trial/);
});

// ---------------- T6 step 1: the read-only Schedule ----------------
test("schedule: weeks start on Monday and are titled plainly", () => {
  assert.strictEqual(T.weekStart("2026-11-26"), "2026-11-23");   // Thursday → Monday
  assert.strictEqual(T.weekStart("2026-11-23"), "2026-11-23");
  assert.strictEqual(T.weekStart("2026-11-29"), "2026-11-23");   // Sunday belongs to the week before the next Monday
  assert.strictEqual(T.weekStart("2026-11-30"), "2026-11-30");
  assert.strictEqual(T.weekTitle("2026-11-23", "2026-11-26"), "This week");
  assert.strictEqual(T.weekTitle("2026-11-30", "2026-11-26"), "Next week");
  assert.strictEqual(T.weekTitle("2026-11-16", "2026-11-26"), "Last week");
  assert.strictEqual(T.weekTitle("2026-12-07", "2026-11-26"), "7 Dec – 13 Dec");
  assert.strictEqual(T.rangeLabel("2026-11-23", "2026-11-29"), "23 Nov – 29 Nov");
});
test("schedule: days with a lesson or a holiday are listed in order; a holiday band shows even with no lesson", () => {
  const data = {
    lessons: [{ lesson_id: "a", lesson_date: "2026-11-25" }, { lesson_id: "b", lesson_date: "2026-11-25" }, { lesson_id: "c", lesson_date: "2026-11-27" }],
    holidays: [{ name: "Deepavali", starts_on: "2026-11-26", ends_on: "2026-11-27" }, { name: "Before", starts_on: "2026-11-01", ends_on: "2026-11-02" }] };
  const d = T.scheduleDays(data, "2026-11-23", "2026-11-29");
  assert.deepStrictEqual(d.map((x) => x.date), ["2026-11-25", "2026-11-26", "2026-11-27"]);
  assert.deepStrictEqual(d.map((x) => x.lessons.length), [2, 0, 1]);
  assert.deepStrictEqual(d.map((x) => x.holidays), [[], ["Deepavali"], ["Deepavali"]]);
  assert.deepStrictEqual(T.scheduleDays({ lessons: [], holidays: [] }, "2026-11-23", "2026-11-29"), []);
  assert.deepStrictEqual(T.scheduleDays(null, "2026-11-23", "2026-11-29"), []);
  // a long holiday is clipped to the week, never loops forever
  assert.strictEqual(T.scheduleDays({ holidays: [{ name: "Long", starts_on: "2026-01-01", ends_on: "2027-12-31" }] }, "2026-11-23", "2026-11-29").length, 7);
});
test("schedule: the badge and the small facts say what the database flagged, and never anything about money", () => {
  assert.strictEqual(T.scheduleChip({}), null);
  assert.deepStrictEqual(T.scheduleChip({ cancelled: true, attendance: "attended" }), { text: "Cancelled", tone: "muted" });
  assert.strictEqual(T.scheduleChip({ attendance: "attended" }).tone, "ok");
  assert.strictEqual(T.scheduleChip({ attendance: "absent" }).text, "Absent");
  assert.strictEqual(T.scheduleChip({ attendance: "late_cancelled" }).text, "Late cancellation");
  assert.strictEqual(T.scheduleChip({ postponed: true }).text, "Moved");
  assert.strictEqual(T.scheduleChip({ covering: true }).text, "Covering");
  assert.strictEqual(T.scheduleChip({ trial: true }).text, "Trial");
  assert.deepStrictEqual(T.scheduleFacts({ student_level: "P5", subject: "Math", trial: true, covering: true, postponed: true, org_name: "Test" }, true),
    ["P5", "Math", "Trial", "Covering for another tutor", "Moved from its usual day", "Test"]);
  assert.deepStrictEqual(T.scheduleFacts({ student_level: null, subject: null }, false), []);
  const everything = JSON.stringify([T.scheduleChip({ cancelled: true }), T.scheduleFacts({ trial: true, covering: true, postponed: true }, false), T.editNote("admin_only"), T.editNote("tutors_propose"), T.editNote("tutors_direct", { can_postpone: true, can_cancel: true, min_notice_hours: 24, changes_left: 3 }), T.scheduleErrorText({ message: "NOT_FOUND" })]);
  assert.ok(!/\b(rate|price|amount|paid|compensation|charge|fee|cents)\b/i.test(everything), "no money word in anything the Schedule says");
});
test("schedule: the note about changes, the weekly slots and the plain error words", () => {
  assert.strictEqual(T.editNote("admin_only"), "Your centre handles changes: ask an admin.");
  assert.strictEqual(T.editNote(undefined), "Your centre handles changes: ask an admin.");
  assert.ok(/not switched on/.test(T.editNote("tutors_propose")), "T6.4: tutors_propose with nothing switched on says so (it is built, so never 'coming soon')");
  assert.ok(/ask an admin/.test(T.editNote("tutors_own")), "the old unbuilt key falls back to the safe note");
  assert.strictEqual(T.weekdayName(0), "Monday"); assert.strictEqual(T.weekdayName(6), "Sunday"); assert.strictEqual(T.weekdayName(9), "");
  const rows = [
    { slot_id: "s3", weekday: 3, start_time: "17:00:00", end_time: "18:00:00", student_name: "C", student_level: "P3", subject: "Sci", org_name: "O" },
    { slot_id: "s1", weekday: 1, start_time: "15:00:00", end_time: "16:00:00", student_name: "A", student_level: "P1", session_key: "g", subject: "Math", org_name: "O" },
    { slot_id: "s2", weekday: 1, start_time: "15:00:00", end_time: "16:00:00", student_name: "B", student_level: "P2", session_key: "g", subject: "Math", org_name: "O" }];
  const l = T.slotList(rows);
  assert.strictEqual(l.length, 2); assert.strictEqual(l[0].weekday, 1); assert.deepStrictEqual(l[0].students.map((x) => x.name), ["A", "B"]); assert.strictEqual(l[1].weekday, 3);
  assert.deepStrictEqual(T.slotList(null), []);
  assert.ok(/for tutors at a centre/.test(T.scheduleErrorText({ message: "NOT_FOUND" })));
  assert.ok(/isn't available right now/.test(T.scheduleErrorText({ message: "boom" })));
  assert.ok(/isn't available right now/.test(T.scheduleErrorText(null)));
});

test("T6.2 the note under the week says what THIS centre lets a tutor do, in plain words", () => {
  const both = T.editNote("tutors_direct", { can_postpone: true, can_cancel: true, min_notice_hours: 24, changes_left: null });
  assert.ok(/move or cancel your own lessons/.test(both) && /at least 24 hours before it starts/.test(both) && !/more change/.test(both), both);
  assert.ok(/You can move your own lessons/.test(T.editNote("tutors_direct", { can_postpone: true, can_cancel: false, min_notice_hours: 1 })) && /at least 1 hour before/.test(T.editNote("tutors_direct", { can_postpone: true, min_notice_hours: 1 })));
  assert.ok(/You can cancel your own lessons/.test(T.editNote("tutors_direct", { can_postpone: false, can_cancel: true })));
  assert.ok(!/at least/.test(T.editNote("tutors_direct", { can_postpone: true, min_notice_hours: 0 })), "no notice = no sentence about it");
  assert.ok(/make 1 more change this month/.test(T.editNote("tutors_direct", { can_postpone: true, changes_left: 1 })));
  assert.ok(/make 0 more changes this month/.test(T.editNote("tutors_direct", { can_postpone: true, changes_left: 0 })));
  assert.ok(/not switched on/.test(T.editNote("tutors_direct", { can_postpone: false, can_cancel: false })), "tutors_direct with both switches off");
  assert.ok(/ask an admin/i.test(T.editNote("admin_only", { can_postpone: true })), "admin_only never offers anything, whatever else arrives");
});
test("T6.2 every refusal of a move, put-back or cancel is said in plain words; nothing raw is shown; no money word", () => {
  const codes = ["NOT_FOUND", "NOT_ALLOWED", "SWITCH_OFF", "ALREADY_MARKED", "CANCELLED", "LOCKED", "NOT_MOVED", "NO_SLOT", "SLOT_CHANGED", "PAST", "REASON_REQUIRED", "TOO_LONG",
    "BAD_DATE", "BAD_TIME", "NO_CHANGE", "GROUP_NOT_YOURS"];
  const seen = new Set();
  for (const c of codes) {
    const t = T.changeErrorText({ message: c + ": raw database words that must not be shown" });
    assert.ok(t && !/raw database|[A-Z]{3,}_[A-Z]+/.test(t), c + " -> " + t);
    assert.ok(!/\b(rate|price|amount|paid|compensation|charge|fee|cents|invoice|invoiced)\b/i.test(t), c + " says no money word: " + t);
    seen.add(t);
  }
  assert.strictEqual(seen.size, codes.length, "each code has its own words");
  // four carry a detail the database knows, so its own sentence is used
  assert.strictEqual(T.changeErrorText({ message: "TOO_LATE: a lesson can only be changed 24 hours or more before it starts. Ask an admin" }), "A lesson can only be changed 24 hours or more before it starts. Ask an admin.");
  assert.ok(/Founders' Day is a holiday/.test(T.changeErrorText({ message: "HOLIDAY: Founders' Day is a holiday at this centre. Pick another day" })));
  assert.ok(/already teach Kid Four at that time/.test(T.changeErrorText({ message: "CLASH: you already teach Kid Four at that time. Pick another time" })));
  assert.ok(/used your 2 schedule changes/.test(T.changeErrorText({ message: "LIMIT: you have used your 2 schedule changes for this month. Ask an admin" })));
  // a lesson in a class: the note is added to the fixed words, and stripped from the detail ones
  assert.ok(/part of a class that changes together/.test(T.changeErrorText({ message: "LOCKED: closed (it is part of a class that changes together)" })));
  assert.ok(!/class that changes together/.test(T.changeErrorText({ message: "TOO_LATE: a lesson can only be changed 24 hours or more before it starts. Ask an admin (it is part of a class that changes together)" })));
  assert.ok(/couldn't change that just now/.test(T.changeErrorText({ message: "boom" })) && /couldn't change that just now/.test(T.changeErrorText(null)) && /couldn't change/.test(T.changeErrorText({ message: "" })));
  assert.ok(!/boom/.test(T.changeErrorText({ message: "boom" })));
});
test("T6.2 why a lesson shows no button, and the end of a moved lesson", () => {
  assert.ok(/less than 24 hours/.test(T.blockText("TOO_LATE", { min_notice_hours: 24 })) && /less than 1 hour,/.test(T.blockText("TOO_LATE", { min_notice_hours: 1 })));
  assert.ok(/already marked/.test(T.blockText("ALREADY_MARKED")) && /closed/.test(T.blockText("LOCKED")) && /already started/.test(T.blockText("PAST")) && /all the changes/.test(T.blockText("LIMIT")));
  assert.strictEqual(T.blockText("NOT_FOUND"), "Ask an admin to assign this student to you before you can change this lesson."); assert.strictEqual(T.blockText("SOMETHING_ELSE"), ""); assert.strictEqual(T.blockText(null), "");
  for (const c of ["TOO_LATE", "PAST", "ALREADY_MARKED", "CANCELLED", "LOCKED", "LIMIT"]) assert.ok(!/\b(rate|price|amount|paid|compensation|charge|fee|cents|invoice|invoiced)\b/i.test(T.blockText(c, { min_notice_hours: 24 })), c);
  assert.strictEqual(T.endTime("16:30:00", 90), "18:00"); assert.strictEqual(T.endTime("09:00", 60), "10:00"); assert.strictEqual(T.endTime("22:59", 60), "23:59");
  assert.strictEqual(T.endTime("23:30", 60), null, "past midnight"); assert.strictEqual(T.endTime("", 60), null); assert.strictEqual(T.endTime("10:00", 0), null); assert.strictEqual(T.endTime("nope", 60), null);
});

// ================= T6 steps 3 and 4: add a lesson, weekly slots, Create lessons =================
const MONEY = /\b(rate|price|amount|paid|compensation|charge|fee|cents|invoice|invoiced|cost|bill|billed)\b/i;
test("T6.3 every refusal of the four new functions is said in plain words; nothing raw is shown; no money word", () => {
  const codes = ["NOT_FOUND", "NOT_ALLOWED", "SWITCH_OFF", "LIMIT", "STUDENT_ENDED", "BAD_DATE", "BAD_TIME", "BAD_SLOT", "TOO_LONG", "TOO_LATE", "HOLIDAY", "ALREADY_THERE", "CLASH", "SLOT_CLASH", "TUTOR_CLASH", "GROUP_CLASS", "BAD_RANGE"];
  const seen = new Set();
  for (const c of codes) {
    const t = T.ownErrorText({ message: c });                                    // the bare code, as a fixed sentence
    assert.ok(t && !/[A-Z]{3,}_[A-Z]+|database|undefined/.test(t), c + " -> " + t);
    assert.ok(!MONEY.test(t), c + " has no money word: " + t);
    seen.add(t);
  }
  assert.strictEqual(seen.size, codes.length, "each code has its own words");
  // the ones with a detail use the database's own sentence
  assert.strictEqual(T.ownErrorText({ message: "TOO_LATE: a new lesson must start 24 hours or more from now. Ask an admin" }), "A new lesson must start 24 hours or more from now. Ask an admin.");
  assert.ok(/Test Festival is a holiday/.test(T.ownErrorText({ message: "HOLIDAY: Test Festival is a holiday at this centre. Pick another day" })));
  assert.ok(/already teach Fay at that time/.test(T.ownErrorText({ message: "CLASH: you already teach Fay at that time. Pick another time" })));
  assert.ok(/Ann already has a lesson at that time/.test(T.ownErrorText({ message: "ALREADY_THERE: Ann already has a lesson at that time" })));
  assert.ok(/already teach Fay at that time every week/.test(T.ownErrorText({ message: "TUTOR_CLASH: you already teach Fay at that time every week. Pick another time" })));
  assert.ok(/used your 2 schedule changes/.test(T.ownErrorText({ message: "LIMIT: you have used your 2 schedule changes for this month. Ask an admin" })));
  assert.ok(/Dee's lessons have ended/.test(T.ownErrorText({ message: "STUDENT_ENDED: Dee's lessons have ended" })));
  // anything unknown is a calm generic line, never the raw words
  for (const bad of [{ message: "boom" }, null, undefined, { message: "" }, { message: "ERROR: syntax error at or near" }]) {
    const t = T.ownErrorText(bad); assert.ok(/couldn't save that just now/.test(t) && !/boom|syntax/.test(t), String(t));
  }
  // a database sentence with a money word would not be shown if the database ever sent one: the functions don't, and these fixed words don't either
  assert.ok(!MONEY.test(JSON.stringify(codes.map((c) => T.ownErrorText({ message: c })))));
});
test("T6.3 the form checks before it asks the database (the database still checks everything)", () => {
  const today = "2026-11-27", ok = { student: "s1", date: "2026-12-01", start: "16:00", end: "17:00", subject: " Math ", note: "" };
  assert.deepStrictEqual(T.addLessonCheck(ok, today), { args: { p_student: "s1", p_date: "2026-12-01", p_start: "16:00", p_end: "17:00", p_subject: "Math", p_note: null } });
  assert.deepStrictEqual(Object.keys(T.addLessonCheck(ok, today).args), ["p_student", "p_date", "p_start", "p_end", "p_subject", "p_note"], "exactly the function's arguments: nothing money-like can be sent");
  const bad = (o) => T.addLessonCheck(Object.assign({}, ok, o), today).error;
  assert.match(bad({ student: "" }), /choose a student/); assert.match(bad({ date: "" }), /pick a day/); assert.match(bad({ date: "2026-11-26" }), /already passed/);
  assert.strictEqual(T.addLessonCheck(Object.assign({}, ok, { date: "2026-11-27" }), today).args.p_date, "2026-11-27", "today itself is allowed (the database decides about the time)");
  assert.match(bad({ date: "2027-11-29" }), /within the next year/); assert.strictEqual(T.addLessonCheck(Object.assign({}, ok, { date: "2027-11-27" }), today).args.p_date, "2027-11-27");
  assert.match(bad({ start: "", end: "" }), /start and an end/); assert.match(bad({ start: "17:00", end: "16:00" }), /end after it starts/); assert.match(bad({ start: "17:00", end: "17:00" }), /end after it starts/);
  assert.match(bad({ start: "16:00", end: "16:10" }), /15 minutes to 8 hours/); assert.match(bad({ start: "08:00", end: "16:30" }), /15 minutes to 8 hours/);
  assert.strictEqual(T.addLessonCheck(Object.assign({}, ok, { start: "16:00", end: "16:15" }), today).args.p_end, "16:15"); assert.strictEqual(T.addLessonCheck(Object.assign({}, ok, { start: "08:00", end: "16:00" }), today).args.p_end, "16:00");
  assert.match(bad({ subject: "x".repeat(61) }), /under 60/); assert.match(bad({ note: "x".repeat(301) }), /under 300/);
  assert.strictEqual(T.addLessonCheck(null, today).error, "Please choose a student.");
  // slots
  const s = { student: "s1", weekday: "2", start: "15:00", end: "16:00", subject: "" };
  assert.deepStrictEqual(T.slotCheck(s), { args: { p_slot: null, p_student: "s1", p_weekday: 2, p_start: "15:00", p_end: "16:00", p_subject: null } });
  assert.deepStrictEqual(T.slotCheck({ slot: "sl", student: "ignored", weekday: 0, start: "09:00", end: "10:00" }).args, { p_slot: "sl", p_student: null, p_weekday: 0, p_start: "09:00", p_end: "10:00", p_subject: null }, "a change never sends a student");
  const sb = (o) => T.slotCheck(Object.assign({}, s, o)).error;
  assert.match(sb({ student: "" }), /choose a student/); assert.match(sb({ weekday: "" }), /day of the week/); assert.match(sb({ weekday: 7 }), /day of the week/); assert.match(sb({ weekday: -1 }), /day of the week/); assert.match(sb({ weekday: 1.5 }), /day of the week/);
  assert.strictEqual(T.slotCheck(Object.assign({}, s, { weekday: 6 })).args.p_weekday, 6); assert.strictEqual(T.slotCheck(Object.assign({}, s, { weekday: "0" })).args.p_weekday, 0);
  assert.match(sb({ end: "14:00" }), /end after/); assert.match(sb({ subject: "y".repeat(61) }), /under 60/);
  assert.strictEqual(T.weekdayOptions().length, 7); assert.deepStrictEqual(T.weekdayOptions()[0], { value: 0, label: "Monday" }); assert.strictEqual(T.weekdayOptions()[6].label, "Sunday");
});
test("T6.3 Create lessons: the range, and what the answer says", () => {
  const today = "2026-11-27";
  assert.strictEqual(T.generateEnd(today), "2026-12-24");
  assert.deepStrictEqual(T.generateCheck({ org: "o1", to: "2026-12-24" }, today), { args: { p_org: "o1", p_from: today, p_to: "2026-12-24" } });
  assert.strictEqual(T.generateCheck({ org: "o1", to: "2026-11-27" }, today).args.p_to, "2026-11-27", "one day is allowed");
  assert.strictEqual(T.generateCheck({ org: "o1", to: "2027-01-28" }, today).args.p_to, "2027-01-28", "62 days is the maximum");
  assert.match(T.generateCheck({ org: "o1", to: "2027-01-29" }, today).error, /within 62 days/); assert.match(T.generateCheck({ org: "o1", to: "2026-11-26" }, today).error, /can't be in the past/);
  assert.match(T.generateCheck({ org: "o1", to: "" }, today).error, /pick the last day/); assert.match(T.generateCheck(null, today).error, /pick the last day/);
  assert.strictEqual(T.generateSummary({ created: 0, skipped: 7 }), "No new lessons were needed. 7 were already there.");
  assert.strictEqual(T.generateSummary({ created: 1 }), "1 new lesson created.");
  assert.strictEqual(T.generateSummary({ created: 11, skipped: 1, holidays: 1, too_soon: 2, ended: 2, not_assigned: 1, awaiting_centre: 2 }),
    "11 new lessons created. 1 was already there. 1 holiday day was skipped. 2 start too soon for your centre's notice, or already started, so were left out. 2 for students whose lessons have ended were left out. 1 for students not assigned to you was left out. Your centre will confirm the details of 2 of them.");
  assert.strictEqual(T.generateSummary(null), "No new lessons were needed.");
  assert.ok(!MONEY.test(T.generateSummary({ created: 5, skipped: 2, holidays: 2, too_soon: 1, ended: 1, not_assigned: 1, awaiting_centre: 3 }) + T.AWAITING_NOTE));
});
test("T6.3 the note, the badge and the slot rows with the new abilities", () => {
  const o = (x) => Object.assign({ min_notice_hours: 24 }, x);
  assert.match(T.editNote("tutors_direct", o({ can_one_off: true })), /^You can add a one-off lesson\. A change must be at least 24 hours before it starts\. Your centre is told about every change\.$/);
  assert.match(T.editNote("tutors_direct", o({ can_postpone: true, can_one_off: true, can_slots: true, can_generate: true, changes_left: 2 })), /You can move your own lessons: tap a lesson\. You can also add a one-off lesson, keep your own weekly slots and create your lessons from them\..*make 2 more changes this month/);
  assert.match(T.editNote("tutors_direct", o({ can_slots: true, can_generate: true })), /^You can keep your own weekly slots and create your lessons from them\./);
  assert.match(T.editNote("tutors_direct", o({ can_generate: true, min_notice_hours: 0 })), /^You can create your lessons from them\. Your centre is told/);
  assert.match(T.editNote("tutors_direct", {}), /not switched on/);
  assert.match(T.editNote("admin_only", o({ can_one_off: true, can_slots: true, can_generate: true })), /ask an admin/i, "admin_only offers nothing, whatever else arrives");
  assert.match(T.editNote("tutors_propose", o({ can_one_off: true })), /^At your centre you ask and an admin approves: nothing changes until they do\. You can ask to add a one-off lesson\. A change must be at least 24 hours/);
  assert.deepStrictEqual(T.scheduleChip({ awaiting_centre: true }), { text: "To confirm", tone: "muted" });
  assert.deepStrictEqual(T.scheduleChip({ awaiting_centre: true, cancelled: true }), { text: "Cancelled", tone: "muted" }, "a cancelled lesson says cancelled first");
  assert.strictEqual(T.scheduleChip({}), null);
  const rows = [{ slot_id: "a", org_id: "o", weekday: 2, start_time: "15:00:00", end_time: "16:00:00", student_id: "s1", student_name: "Ann", student_level: "P1", can_change: true, is_group: false, awaiting_centre: true },
                { slot_id: "g1", org_id: "o", weekday: 6, start_time: "10:00:00", end_time: "11:00:00", student_id: "s2", student_name: "Hal", session_key: "k", can_change: false, is_group: true },
                { slot_id: "g2", org_id: "o", weekday: 6, start_time: "10:00:00", end_time: "11:00:00", student_id: "s3", student_name: "Ivy", session_key: "k", can_change: false, is_group: true }];
  const l = T.slotList(rows);
  assert.strictEqual(l.length, 2); assert.strictEqual(l[0].slot_id, "a"); assert.strictEqual(l[0].can_change, true); assert.strictEqual(l[0].awaiting_centre, true); assert.strictEqual(l[0].students[0].id, "s1");
  assert.strictEqual(l[1].is_group, true); assert.strictEqual(l[1].can_change, false); assert.strictEqual(l[1].students.length, 2);
  assert.deepStrictEqual(T.slotList([{ slot_id: "x", weekday: 1, start_time: "09:00:00", student_name: "Z" }])[0].can_change, false, "no flag from the database = no button");
  const opts = T.studentOptions([{ org_id: "o1", student_id: "s1", name: "Ann", level: "P1", subject: "Math", awaiting_centre: false }, { org_id: "o2", student_id: "s2", name: "Bo", awaiting_centre: true }], "o1");
  assert.deepStrictEqual(opts, [{ id: "s1", org_id: "o1", name: "Ann", level: "P1", subject: "Math", awaiting_centre: false }]);
  assert.strictEqual(T.studentOptions([{ org_id: "o1", student_id: "s1", name: "A" }, { org_id: "o2", student_id: "s2", name: "B" }]).length, 2); assert.deepStrictEqual(T.studentOptions(null), []);
  const say = JSON.stringify([T.editNote("tutors_direct", o({ can_postpone: true, can_cancel: true, can_one_off: true, can_slots: true, can_generate: true, changes_left: 3 })), T.scheduleChip({ awaiting_centre: true }), T.AWAITING_NOTE]);
  assert.ok(!MONEY.test(say), "no money word in anything the Schedule says: " + say);
});

// ---- T6 steps 5-6: the online link and requests (tutors_propose)
test("T6.4: tutors_propose note: ask, wait for approval, the notice, what is left (waiting requests count)", () => {
  const o = (x) => Object.assign({ min_notice_hours: 24 }, x);
  const n = T.editNote("tutors_propose", o({ can_postpone: true, can_cancel: true, can_one_off: true, can_slots: true, can_generate: true, can_link: true, changes_left: 1 }));
  assert.match(n, /^At your centre you ask and an admin approves: nothing changes until they do\. You can ask to move or cancel your own lessons: tap a lesson\. You can also ask to add a one-off lesson, change your weekly slots, create your lessons or set the online link\./);
  assert.match(n, /at least 24 hours before the lesson starts/);
  assert.match(n, /You can ask for 1 more change this month \(waiting requests count\)\.$/);
  assert.match(T.editNote("tutors_propose", o({ can_postpone: true, min_notice_hours: 1 })), /at least 1 hour before/);
  assert.doesNotMatch(T.editNote("tutors_propose", o({ can_postpone: true, min_notice_hours: 0 })), /at least/);
  assert.match(T.editNote("tutors_propose", {}), /not switched on/);
  assert.match(T.editNote("tutors_direct", o({ can_postpone: true })), /Your centre is told about every change/, "direct is unchanged");
});
test("T6.4: a lesson with a waiting request says so first; slots carry their waiting request", () => {
  assert.deepStrictEqual(T.scheduleChip({ pending_request: { request_id: "r", kind: "cancel" }, cancelled: false }), { text: "Waiting for approval", tone: "warn" });
  assert.deepStrictEqual(T.scheduleChip({ pending_request: null, postponed: true }), { text: "Moved", tone: "muted" });
  const rows = [{ slot_id: "s1", session_key: null, org_id: "o", weekday: 1, start_time: "16:00:00", end_time: "17:00:00", student_id: "a", student_name: "Ann", can_change: true, pending_request: "r1", pending_kind: "stop_slot" }];
  const l = T.slotList(rows); assert.strictEqual(l[0].pending_request, "r1"); assert.strictEqual(l[0].pending_kind, "stop_slot");
  assert.strictEqual(T.slotList([{ slot_id: "s2", weekday: 0, start_time: "10:00:00", student_id: "b", student_name: "Ben" }])[0].pending_request, null);
});
test("T6.4: plain words for the new refusals (never the raw code)", () => {
  for (const [code, re] of [["ALREADY_PENDING", /already asked/], ["ALREADY_DECIDED", /already answered/], ["NOTHING_TO_DO", /no new lessons/], ["BAD_LINK", /https:\/\//], ["NO_CHANGE", /already like that/]]) {
    assert.match(T.ownErrorText({ message: code + ": whatever the database said" }), re, code);
  }
  assert.match(T.changeErrorText({ message: "ALREADY_PENDING: you have already asked" }), /already asked for this/);
  assert.match(T.changeErrorText({ message: "ALREADY_DECIDED: an admin" }), /already answered/);
  assert.doesNotMatch(T.ownErrorText({ message: "BAD_LINK: the link must start" }), /BAD_LINK/);
  assert.match(T.ownErrorText({ message: "WHATEVER_NEW: x" }), /couldn't save that just now/);
});
