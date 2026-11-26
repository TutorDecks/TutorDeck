// node --test tests/   — the words staff read about lessons their tutors changed (assets/js/tutor-changes-core.js).
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const C = require("../assets/js/tutor-changes-core.js");

const R = (o) => Object.assign({ lesson_id: "l1", what: "moved", changed_at: "2026-11-26T08:00:00Z", reason: "school event", tutor_name: "Tutor One", student_name: "Kid One", lesson_date: "2026-12-04",
  start_time: "17:00:00", end_time: "18:00:00", from_date: "2026-12-01", from_start: "16:00:00", cancelled: false, tell_family: true }, o || {});

test("a change is one plain sentence, whoever made it and whatever they did", () => {
  assert.equal(C.headline(R()), "Tutor One moved Kid One");
  assert.equal(C.headline(R({ what: "cancelled" })), "Tutor One cancelled Kid One");
  assert.equal(C.headline(R({ what: "reverted" })), "Tutor One put Kid One back to the usual time");
  assert.equal(C.headline(R({ tutor_name: null, student_name: null })), "A tutor moved a student");
  assert.equal(C.headline(R({ tutor_name: "Former tutor" })), "Former tutor moved Kid One");
});
test("the detail says from where to where, and for a cancel which lesson", () => {
  assert.equal(C.detail(R()), "Tue 1 Dec 4:00 pm → Fri 4 Dec 5:00 pm");
  assert.equal(C.detail(R({ what: "reverted" })), "Tue 1 Dec 4:00 pm → Fri 4 Dec 5:00 pm");
  assert.equal(C.detail(R({ what: "cancelled", lesson_date: "2026-12-04", start_time: "17:00:00" })), "Fri 4 Dec 5:00 pm (cancelled)");
  assert.equal(C.detail(R({ from_date: null, from_start: null })), "Now Fri 4 Dec 5:00 pm");
  assert.equal(C.when("2026-12-04", "00:05:00"), "Fri 4 Dec 12:05 am");
  assert.equal(C.when("2026-12-04", "12:00:00"), "Fri 4 Dec 12:00 pm");
});
test("how long ago uses the centre's own today", () => {
  assert.equal(C.ago(R({ changed_at: "2026-11-26T01:00:00Z" }), "2026-11-26"), "today");
  assert.equal(C.ago(R({ changed_at: "2026-11-25T23:00:00Z" }), "2026-11-26"), "yesterday");
  assert.equal(C.ago(R({ changed_at: "2026-11-20T10:00:00Z" }), "2026-11-26"), "6 days ago");
  assert.equal(C.ago(R({ changed_at: null }), "2026-11-26"), "today");
  assert.equal(C.ago(R({ changed_at: "2026-11-27T01:00:00Z" }), "2026-11-26"), "today", "a clock slightly ahead never says 'in the future'");
});
test("the amber flag and the sheet line", () => {
  assert.deepEqual(C.chip(R()), { text: "Changed by tutor", tone: "warn" });
  assert.equal(C.chip(null), null); assert.equal(C.chip(undefined), null);
  assert.deepEqual(C.sheetFact(R(), "2026-11-26"), ["Moved by", "Tutor One, today. “school event”. Was Tue 1 Dec 4:00 pm"]);
  assert.deepEqual(C.sheetFact(R({ what: "cancelled", reason: null }), "2026-11-26"), ["Cancelled by", "Tutor One, today"]);
  assert.deepEqual(C.sheetFact(R({ what: "reverted" }), "2026-11-26")[0], "Put back by");
  assert.equal(C.sheetFact(null, "2026-11-26"), null);
});
test("rows are found by lesson id; bad input is harmless", () => {
  const m = C.byLesson([R({ lesson_id: "a" }), R({ lesson_id: "b" }), null, {}]);
  assert.deepEqual(Object.keys(m).sort(), ["a", "b"]);
  assert.deepEqual(C.byLesson(null), {}); assert.deepEqual(C.byLesson(undefined), {});
});
test("the note under the Home list follows notify_family, and nothing here says anything about money", () => {
  assert.match(C.homeNote(true), /Tell the family about each change/);
  assert.match(C.homeNote(false), /listed for your information/);
  const all = JSON.stringify([C.headline(R()), C.headline(R({ what: "cancelled" })), C.detail(R()), C.sheetFact(R(), "2026-11-26"), C.homeNote(true), C.homeNote(false), C.chip(R())]);
  assert.ok(!/\b(rate|price|amount|paid|invoice|invoiced|cents|S\$)\b/i.test(all), all);
});
