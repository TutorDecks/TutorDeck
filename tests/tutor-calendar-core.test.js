"use strict";
// UX1: the centre tutor's week grid and the read-only overlay on the solo calendar. Pure logic, no browser.
const test = require("node:test"), assert = require("node:assert");
const T = require("../assets/js/tutor-calendar-core.js");

const L = (id, date, a, b, extra) => Object.assign({ lesson_id: id, lesson_date: date, start_time: a + ":00", end_time: b + ":00", student_name: "S" + id, subject: "Maths" }, extra || {});

test("weekDays / weekStart: Monday to Sunday", () => {
  assert.deepStrictEqual(T.weekDays("2026-11-23"), ["2026-11-23", "2026-11-24", "2026-11-25", "2026-11-26", "2026-11-27", "2026-11-28", "2026-11-29"]);
  assert.strictEqual(T.weekStart("2026-11-29"), "2026-11-23");
  assert.strictEqual(T.weekStart("2026-11-23"), "2026-11-23");
});
test("chips: the same words as the List view, cancelled beats everything", () => {
  assert.strictEqual(T.chip(L(1, "d", "16:00", "17:00")), null);
  assert.deepStrictEqual(T.chip(L(1, "d", "16:00", "17:00", { cancelled: true, attendance: "attended", postponed: true })), { text: "Cancelled", key: "cancelled" });
  assert.deepStrictEqual(T.chip(L(1, "d", "16:00", "17:00", { attendance: "attended" })), { text: "Attended", key: "attended" });
  assert.deepStrictEqual(T.chip(L(1, "d", "16:00", "17:00", { attendance: "late_cancelled" })), { text: "Late cancellation", key: "absent" });
  assert.deepStrictEqual(T.chip(L(1, "d", "16:00", "17:00", { postponed: true })), { text: "Moved", key: "moved" });
  assert.deepStrictEqual(T.chip(L(1, "d", "16:00", "17:00", { covering: true })), { text: "Covering", key: "covering" });
  assert.deepStrictEqual(T.chip(L(1, "d", "16:00", "17:00", { trial: true })), { text: "Trial", key: "trial" });
  assert.deepStrictEqual(T.chip({ status: "cancelled" }), { text: "Cancelled", key: "cancelled" });   // a tutor_my_lessons row
});
test("layoutDay: overlapping lessons sit side by side, others get the full width", () => {
  const out = T.layoutDay([L(3, "d", "17:00", "18:00"), L(1, "d", "16:00", "17:30"), L(2, "d", "16:30", "17:30")]);
  assert.deepStrictEqual(out.map((b) => [b.l.lesson_id, b.lane, b.lanes]), [[1, 0, 3], [2, 1, 3], [3, 2, 3]], "3 starts at 17:00 while 1 and 2 still run");
  const two = T.layoutDay([L(1, "d", "16:00", "17:00"), L(2, "d", "16:30", "17:30"), L(3, "d", "17:00", "18:00")]);
  assert.deepStrictEqual(two.map((b) => [b.l.lesson_id, b.lane, b.lanes]), [[1, 0, 2], [2, 1, 2], [3, 0, 2]]);
  const alone = T.layoutDay([L(1, "d", "09:00", "10:00"), L(2, "d", "10:00", "11:00")]);
  assert.deepStrictEqual(alone.map((b) => [b.lane, b.lanes]), [[0, 1], [0, 1]]);
  assert.strictEqual(T.layoutDay([L(1, "d", "09:00", "09:00")])[0].endMin, 9 * 60 + 60, "a zero-length lesson is drawn one hour long");
});
test("bounds: whole hours around the lessons, at least six, 15:00-21:00 when empty", () => {
  assert.deepStrictEqual(T.bounds([]), { start: 900, end: 1260 });
  assert.deepStrictEqual(T.bounds([L(1, "d", "16:30", "18:00")]), { start: 960, end: 1320 });
  assert.deepStrictEqual(T.bounds([L(1, "d", "08:00", "09:00"), L(2, "d", "20:30", "22:15")]), { start: 480, end: 1380 });
  assert.deepStrictEqual(T.bounds([L(1, "d", "22:00", "23:30")]), { start: 1080, end: 1440 }, "never past midnight");
});
test("week: every day listed, holidays across the range, lessons sorted", () => {
  const data = { holidays: [{ name: "Deepavali", starts_on: "2026-11-24", ends_on: "2026-11-25" }, { name: "Away", starts_on: "2026-11-20", ends_on: "2026-11-23" }],
                 lessons: [L(2, "2026-11-24", "17:00", "18:00"), L(1, "2026-11-24", "15:00", "16:00"), L(3, "2026-12-30", "15:00", "16:00")] };
  const w = T.week(data, "2026-11-23");
  assert.strictEqual(w.length, 7);
  assert.deepStrictEqual(w[0].holidays, ["Away"]);
  assert.deepStrictEqual(w[1].holidays, ["Deepavali"]);
  assert.deepStrictEqual(w[2].holidays, ["Deepavali"]);
  assert.deepStrictEqual(w[1].lessons.map((l) => l.lesson_id), [1, 2]);
  assert.strictEqual(w.reduce((n, d) => n + d.lessons.length, 0), 2, "a lesson outside the week is not drawn");
});
test("pickDay: remembered day, else today, else Monday", () => {
  assert.strictEqual(T.pickDay("2026-11-23", "2026-11-25", "2026-11-27"), "2026-11-27");
  assert.strictEqual(T.pickDay("2026-11-23", "2026-11-25", "2026-12-27"), "2026-11-25");
  assert.strictEqual(T.pickDay("2026-11-30", "2026-11-25", null), "2026-11-30");
});
test("overlay block: facts only, labelled with the centre, no money field at all", () => {
  const row = { lesson_id: "x1", org_id: "o1", org_name: "Demo Centre", student_name: "Mei", student_level: "Sec 3", subject: "Physics", lesson_date: "2026-11-24",
                start_time: "16:00:00", end_time: "17:30:00", status: "scheduled", attendance: null, trial: false };
  const b = T.overlayBlock(row);
  assert.deepStrictEqual([b.kind, b.state, b.dateISO, b.startMin, b.endMin, b.name, b.centre], ["centre", "centre", "2026-11-24", 960, 1050, "Mei", "Demo Centre"]);
  assert.strictEqual(T.overlayLabel(b), "Demo Centre · Physics");
  assert.ok(!Object.keys(b).some((k) => /amount|rate|paid|price|compens|cents|fee/i.test(k)), Object.keys(b).join());
  assert.strictEqual(T.overlayBlock(Object.assign({}, row, { status: "cancelled" })).cancelled, true);
  assert.strictEqual(T.overlayBlock(Object.assign({}, row, { attendance: "attended" })).tag, "Attended");
});
test("overlay toggle: only for a both-role tutor on their solo calendar", () => {
  const solo = { id: "s1", kind: "solo" }, centre = { id: "c1", kind: "centre", role: "tutor" };
  assert.strictEqual(T.overlayAvailable("both", solo), true);
  assert.strictEqual(T.overlayAvailable("both", { id: null, kind: "solo" }), true);
  assert.strictEqual(T.overlayAvailable("solo", solo), false, "a solo tutor with no centre never sees it");
  assert.strictEqual(T.overlayAvailable(null, solo), false);
  assert.strictEqual(T.overlayAvailable("tutor-only", solo), false);
  assert.strictEqual(T.overlayAvailable("both", centre), false);
});
