"use strict";
const test = require("node:test"), assert = require("node:assert");
const C = require("../assets/js/centre-attendance-core.js");

const R = (o) => Object.assign({ lesson_id: "l1", lesson_date: "2026-11-25", start_time: "16:00:00", end_time: "17:00:00", student_name: "Aiden Tan", attendance: null,
  state: "open", can_mark: true, can_correct: false, marked_by_name: null, marked_at: null }, o || {});

test("a day is itself; a week runs Monday to Sunday whichever day inside it you start from", () => {
  assert.deepStrictEqual(C.range("day", "2026-11-25"), { from: "2026-11-25", to: "2026-11-25" });
  for (const d of ["2026-11-23", "2026-11-25", "2026-11-29"]) assert.deepStrictEqual(C.range("week", d), { from: "2026-11-23", to: "2026-11-29" }, d);   // 23 Nov 2026 is a Monday
  assert.strictEqual(C.weekStart("2026-11-29"), "2026-11-23");                                    // a Sunday belongs to the week BEFORE the next Monday
  assert.strictEqual(C.weekStart("2026-11-30"), "2026-11-30");
  assert.strictEqual(C.range("week", "2026-11-25").to < "2026-11-30", true);
});
test("stepping moves by a day or by a week, across month and year ends", () => {
  assert.strictEqual(C.shift("day", "2026-11-30", 1), "2026-12-01");
  assert.strictEqual(C.shift("week", "2026-12-28", 1), "2027-01-04");
  assert.strictEqual(C.shift("week", "2026-01-03", -1), "2025-12-27");
  assert.strictEqual(C.shift("day", "2026-03-01", -1), "2026-02-28");
});
test("a week never asks the database for more than its 62-day limit", () => {
  const r = C.range("week", "2026-11-25"); assert.ok((Date.parse(r.to) - Date.parse(r.from)) / 864e5 <= 62);
});
test("day labels use the centre's own today, and ranges read plainly", () => {
  assert.strictEqual(C.dayLabel("2026-11-25", "2026-11-25"), "Today · Wed 25 Nov");
  assert.strictEqual(C.dayLabel("2026-11-26", "2026-11-25"), "Tomorrow · Thu 26 Nov");
  assert.strictEqual(C.dayLabel("2026-11-24", "2026-11-25"), "Yesterday · Tue 24 Nov");
  assert.strictEqual(C.dayLabel("2026-12-02", "2026-11-25"), "Wed 2 Dec");
  assert.strictEqual(C.rangeLabel("week", "2026-11-25", "2026-11-25"), "23 Nov – 29 Nov");
  assert.strictEqual(C.rangeLabel("week", "2026-12-30", "2026-11-25"), "28 Dec – 3 Jan 2027");
  assert.strictEqual(C.rangeLabel("day", "2026-11-25", "2026-11-25"), "Today · Wed 25 Nov");
});
test("dates from the address are checked", () => {
  assert.ok(C.validISO("2026-11-25")); assert.ok(!C.validISO("2026-02-30")); assert.ok(!C.validISO("tomorrow")); assert.ok(!C.validISO(null)); assert.ok(!C.validISO("2026-1-5"));
});
test("times read as the tutor screen does", () => {
  assert.strictEqual(C.timeLabel("16:00:00"), "4:00 pm"); assert.strictEqual(C.timeLabel("09:30:00"), "9:30 am"); assert.strictEqual(C.timeLabel("12:05:00"), "12:05 pm");
  assert.strictEqual(C.timeLabel(null), ""); assert.strictEqual(C.timeRange(R()), "4:00 pm – 5:00 pm");
});

test("the chip follows the database's state; every mark has a chip", () => {
  assert.deepStrictEqual(C.chip(R()), { text: "Not marked", tone: "warn" });
  assert.deepStrictEqual(C.chip(R({ state: "future" })), { text: "Upcoming", tone: "muted" });
  assert.deepStrictEqual(C.chip(R({ state: "cancelled" })), { text: "Cancelled", tone: "muted" });
  assert.deepStrictEqual(C.chip(R({ state: "marked", attendance: "attended" })), { text: "Attended", tone: "ok" });
  assert.strictEqual(C.chip(R({ state: "marked", attendance: "absent" })).text, "Absent");
  assert.strictEqual(C.chip(R({ state: "marked", attendance: "late_cancelled" })).text, "Late cancelled");
  assert.strictEqual(C.chip(R({ state: "marked", attendance: "cancelled_early" })).text, "Cancelled");
});
test("buttons: mark on an open lesson, Correct on a marked one, NONE on tomorrow's, a closed one, or for look-only staff", () => {
  assert.deepStrictEqual(C.actions(R(), true), { mark: true, correct: false, note: "" });
  assert.deepStrictEqual(C.actions(R({ state: "marked", attendance: "absent", can_mark: false, can_correct: true }), true), { mark: false, correct: true, note: "" });
  const fut = C.actions(R({ state: "future", can_mark: false }), true); assert.strictEqual(fut.mark || fut.correct, false); assert.match(fut.note, /hasn’t started/);
  const can = C.actions(R({ state: "cancelled", can_mark: false }), true); assert.strictEqual(can.mark || can.correct, false); assert.match(can.note, /cancelled/);
  const look = C.actions(R({ can_mark: false }), false); assert.strictEqual(look.mark || look.correct, false); assert.match(look.note, /look at attendance but not change/);
  const lookMarked = C.actions(R({ state: "marked", attendance: "absent", can_mark: false, can_correct: false }), false); assert.match(lookMarked.note, /not change/);
});
test("who marked it, in words (the person may have been removed)", () => {
  assert.strictEqual(C.markedLine(R()), "");
  assert.strictEqual(C.markedLine(R({ attendance: "absent", marked_by_name: "Sam", marked_at: "2026-11-24T08:30:00+00:00" })), "Marked by Sam on Tue 24 Nov");
  assert.strictEqual(C.markedLine(R({ attendance: "absent", marked_by_name: null, marked_at: null })), "Marked");
});
test("rows are grouped by day in the order the database gave", () => {
  const g = C.byDay([R({ lesson_id: "a", lesson_date: "2026-11-24" }), R({ lesson_id: "b", lesson_date: "2026-11-24" }), R({ lesson_id: "c", lesson_date: "2026-11-25" })]);
  assert.deepStrictEqual(g.map((d) => [d.date, d.rows.length]), [["2026-11-24", 2], ["2026-11-25", 1]]);
  assert.deepStrictEqual(C.byDay(null), []);
});

test("a first mark: one of the four values; remarks not absurdly long", () => {
  for (const k of ["attended", "absent", "late_cancelled", "cancelled_early"]) assert.ok(C.checkMark(k, "").ok, k);
  assert.ok(!C.checkMark("maybe", "").ok); assert.ok(!C.checkMark(null, "").ok);
  assert.ok(!C.checkMark("attended", "x".repeat(2001)).ok); assert.ok(C.checkMark("attended", "x".repeat(2000)).ok);
});
test("a correction needs a different mark AND a reason, trimmed, under 500 characters", () => {
  assert.ok(!C.checkCorrection("absent", "absent", "typo").ok);
  assert.match(C.checkCorrection("absent", "absent", "typo").error, /already marked that way/);
  assert.ok(!C.checkCorrection("absent", "attended", "").ok); assert.ok(!C.checkCorrection("absent", "attended", "   ").ok); assert.ok(!C.checkCorrection("absent", "attended", null).ok);
  assert.match(C.checkCorrection("absent", "attended", " ").error, /Say why/);
  assert.ok(!C.checkCorrection("absent", "attended", "x".repeat(501)).ok);
  assert.ok(!C.checkCorrection("absent", "nonsense", "why").ok);
  const ok = C.checkCorrection("absent", "attended", "  Parent confirmed  "); assert.ok(ok.ok); assert.strictEqual(ok.reason, "Parent confirmed");
});
test("a correction can change to any mark except the current one", () => {
  assert.deepStrictEqual(C.otherMarks("absent").map((m) => m.key), ["attended", "late_cancelled", "cancelled_early"]);
  assert.strictEqual(C.otherMarks("zzz").length, 4);
});

test("every database refusal is worded plainly, and none leaks a code", () => {
  const e = (m) => C.errorText({ message: m });
  assert.match(e("TOO_EARLY: a lesson can be marked from its day onward"), /from its day onward/);
  assert.match(e("ALREADY_MARKED: someone else already marked this lesson; use Correct (with a reason) to change it"), /Use Correct/);
  assert.match(e("REMARKS_REQUIRED: this centre needs remarks before a lesson is marked attended"), /needs remarks/);
  assert.match(e("REASON_REQUIRED: say why you are changing this mark"), /Say why/);
  assert.match(e("NOT_ALLOWED: your account can't mark attendance at this centre"), /can’t mark attendance/);
  assert.match(e("NOT_FOUND"), /isn’t available any more/);
  assert.match(e("CANCELLED: this lesson was cancelled"), /cancelled/);
  assert.match(e("NOT_MARKED: x"), /Mark it instead/); assert.match(e("NO_CHANGE: x"), /already marked that way/);
  assert.match(e("LOCKED: who marked"), /can’t be edited/); assert.match(e("TOO_LONG: x"), /too long/); assert.match(e("BAD_RANGE: x"), /shorter period/);
  assert.match(e("TypeError: Failed to fetch"), /Couldn’t reach the server/);
  for (const m of ["TOO_EARLY: x", "ALREADY_MARKED: x", "REMARKS_REQUIRED: x", "NOT_ALLOWED: x", "NOT_FOUND", "BAD_FILTER: x"]) assert.doesNotMatch(e(m), /[A-Z]{4,}_[A-Z]+/, m);
  assert.strictEqual(C.errorText(null), "Something went wrong.");
});
test("a missing function is told apart from a refusal", () => {
  assert.ok(C.isMissing({ code: "42883" })); assert.ok(C.isMissing({ code: "PGRST202" })); assert.ok(C.isMissing({ message: "Could not find the function public.staff_lessons" }));
  assert.ok(!C.isMissing({ message: "NOT_FOUND" })); assert.ok(!C.isMissing(null));
});
test("paging words and empty states", () => {
  assert.strictEqual(C.pageCount(0, 50), 1); assert.strictEqual(C.pageCount(51, 50), 2); assert.strictEqual(C.pageCount(100, 50), 2);
  assert.strictEqual(C.pagerLabel(2, 50, 62), "51–62 of 62"); assert.strictEqual(C.pagerLabel(1, 50, 0), "No lessons");
  assert.match(C.emptyText("unmarked", "day").title, /Nothing left to mark/); assert.match(C.emptyText("all", "week").title, /this week/);
  assert.ok(C.PAGE_SIZE >= 1 && C.PAGE_SIZE <= 100);                                              // the database refuses more than 100
});
