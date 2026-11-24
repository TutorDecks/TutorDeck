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
    { attendance: "attended", topics: null, homework: null, remarks: null, any: true });
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
