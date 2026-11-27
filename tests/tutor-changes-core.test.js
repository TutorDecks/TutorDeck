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

// ---- T6 steps 3-4: a lesson ADDED, a weekly slot added / changed / stopped, one line per "Create lessons" press
const SLOT = (o) => Object.assign({ kind: "slot", slot_id: "s1", what: "added", changed_at: "2026-11-26T08:00:00Z", tutor_name: "Tutor One", student_name: "Kid One", weekday: 1, start_time: "16:00:00", end_time: "17:00:00", subject: "Math", awaiting_centre: false, tell_family: true }, o || {});
const RUN = (o) => Object.assign({ kind: "run", what: "generated", changed_at: "2026-11-26T08:00:00Z", tutor_name: "Tutor One", created: 11, from_date: "2026-11-27", to_date: "2026-12-24", awaiting_centre: false, tell_family: true }, o || {});
test("T6.3 an added lesson, a slot and a press are each one plain sentence", () => {
  assert.equal(C.headline(R({ what: "added" })), "Tutor One added a lesson for Kid One");
  assert.equal(C.detail(R({ what: "added", lesson_date: "2026-12-04", start_time: "17:00:00", subject: "Math" })), "Fri 4 Dec 5:00 pm · Math");
  assert.equal(C.detail(R({ what: "added", lesson_date: "2026-12-04", start_time: "17:00:00", subject: null })), "Fri 4 Dec 5:00 pm");
  assert.equal(C.headline(SLOT()), "Tutor One added a weekly slot for Kid One");
  assert.equal(C.headline(SLOT({ what: "changed" })), "Tutor One changed the weekly slot of Kid One");
  assert.equal(C.headline(SLOT({ what: "stopped" })), "Tutor One stopped the weekly slot of Kid One");
  assert.equal(C.detail(SLOT()), "Every Tuesday 4:00 pm – 5:00 pm");
  assert.equal(C.detail(SLOT({ weekday: 6, start_time: "10:00:00", end_time: null })), "Every Sunday 10:00 am");
  assert.equal(C.headline(RUN()), "Tutor One created 11 lessons from their weekly slots");
  assert.equal(C.headline(RUN({ created: 1 })), "Tutor One created 1 lesson from their weekly slots");
  assert.equal(C.detail(RUN()), "Lessons from Fri 27 Nov to Thu 24 Dec");
  assert.equal(C.headline(SLOT({ tutor_name: "Former tutor" })), "Former tutor added a weekly slot for Kid One");
  assert.deepEqual(C.sheetFact(R({ what: "added", reason: "extra revision" }), "2026-11-26"), ["Added by", "Tutor One, today. “extra revision”"]);
});
test("T6.3 only lessons are looked up by lesson id (a slot or a press never lands on a Timetable row)", () => {
  const m = C.byLesson([R({ lesson_id: "a" }), SLOT({ lesson_id: "x" }), RUN({ lesson_id: "y" }), R({ lesson_id: "b", what: "added" })]);
  assert.deepEqual(Object.keys(m).sort(), ["a", "b"]);
});
test("T6.3 the amber chip says when the centre still has to confirm the price, and nothing else says anything about money", () => {
  assert.deepEqual(C.confirmChip(R({ awaiting_centre: true })), { text: "Price to confirm", tone: "warn" });
  assert.equal(C.confirmChip(R({ awaiting_centre: false })), null); assert.equal(C.confirmChip(null), null); assert.equal(C.confirmChip(undefined), null);
  const all = JSON.stringify([C.headline(R({ what: "added" })), C.headline(SLOT()), C.headline(SLOT({ what: "stopped" })), C.headline(RUN()), C.detail(SLOT()), C.detail(RUN()), C.detail(R({ what: "added" }))]);
  assert.ok(!/\b(rate|price|amount|paid|invoice|invoiced|cents|S\$)\b/i.test(all), all);
});
test("B5-FIX H2: when a lesson changed more than once the newest change (first in the list) is the one its row shows", () => {
  const m = C.byLesson([R({ lesson_id: "a", what: "cancelled" }), R({ lesson_id: "a", what: "moved" }), R({ lesson_id: "b", what: "moved" })]);
  assert.equal(m.a.what, "cancelled"); assert.equal(m.b.what, "moved");
});
