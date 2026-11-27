// node --test tests/   — the "Add past lessons" form's wording and checks (T3.10). The database's side is tests/sql/past_lessons_test.sql.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const P = require("../assets/js/centre-past-lessons-core.js");

const opts = { today: "2026-11-27", earliest: "2026-10-27" };
const base = () => ({ mode: "dates", tutor: "t1", reason: "Started last week", start: "16:00", end: "17:30", rate: "60", subject: "", dates: ["2026-11-24", "2026-11-23"], attended: true });

test("a good form has no errors, and the list is sorted, de-duplicated and carries the typed time and price", () => {
  const f = base(); f.dates.push("2026-11-24");
  assert.deepEqual(P.validate(f, opts), {});
  assert.deepEqual(P.buildItems(f), [{ date: "2026-11-23", start: "16:00", end: "17:30", rate: "60" }, { date: "2026-11-24", start: "16:00", end: "17:30", rate: "60" }]);
});
test("every required thing is checked before the call", () => {
  const e = P.validate({ mode: "dates", dates: [], start: "", end: "", rate: "abc", reason: "  ", subject: "x".repeat(61) }, opts);
  for (const k of ["tutor", "dates", "rate", "start", "reason", "subject"]) assert.ok(e[k], k);
  assert.match(P.validate(Object.assign(base(), { end: "16:05" }), opts).end, /15 minutes to 8 hours/);
  assert.match(P.validate(Object.assign(base(), { end: "15:00" }), opts).end, /end after it starts/);
  assert.match(P.validate(Object.assign(base(), { rate: "1001" }), opts).rate, /0 and 1000/);
  assert.match(P.validate(Object.assign(base(), { reason: "x".repeat(501) }), opts).reason, /500/);
  assert.match(P.validate(Object.assign(base(), { dates: ["2026-11-27"] }), opts).dates, /before today/);
  assert.match(P.validate(Object.assign(base(), { dates: ["2026-10-01"] }), opts).dates, /earliest day/);
  assert.match(P.validate(Object.assign(base(), { dates: Array.from({ length: 63 }, (_, i) => "2026-10-" + String(i + 1).padStart(2, "0")) }), opts).dates, /at most 62/);
  assert.equal(P.validate(Object.assign(base(), { rate: "" }), opts).rate, undefined, "an empty price means: take it from the weekly slot or the last lesson");
});
test("pattern items keep their own time and price; a typed price overrides them all", () => {
  const items = [{ date: "2026-11-20", start: "16:00:00", end: "17:00:00", rate: 55, subject: "Science" }, { date: "2026-11-23", start: "09:00:00", end: "10:00:00", rate: 70 }];
  const f = { mode: "pattern", tutor: "t1", reason: "r", items, rate: "" };
  assert.deepEqual(P.buildItems(f), [{ date: "2026-11-20", start: "16:00", end: "17:00", rate: "55", subject: "Science" }, { date: "2026-11-23", start: "09:00", end: "10:00", rate: "70" }]);
  assert.equal(P.buildItems(Object.assign({}, f, { rate: "80" }))[1].rate, "80");
  assert.match(P.validate(Object.assign({}, f, { items: [] }), opts).dates, /No lessons in that range/);
  assert.deepEqual(P.validate(f, opts), {}, "pattern mode needs no typed time");
});
test("the arguments match the database functions", () => {
  const a = P.addArgs("o1", "s1", Object.assign(base(), { remarks: "  Good  " }), { holiday: true, closed: false });
  assert.deepEqual(Object.keys(a).sort(), ["p_allow_closed_month", "p_confirm_holidays", "p_items", "p_mark_attended", "p_org", "p_reason", "p_remarks", "p_student", "p_tutor"]);
  assert.equal(a.p_mark_attended, true); assert.equal(a.p_remarks, "Good"); assert.equal(a.p_confirm_holidays, true); assert.equal(a.p_allow_closed_month, false);
  assert.equal(P.addArgs("o1", "s1", Object.assign(base(), { attended: false, remarks: "x" }), {}).p_remarks, null, "remarks are only sent with an attended mark");
  assert.deepEqual(Object.keys(P.previewArgs("o1", "s1", base(), {})).sort(), ["p_allow_closed_month", "p_confirm_holidays", "p_items", "p_org", "p_student", "p_tutor"]);
});
test("the preview in words", () => {
  const p = { new: 5, there: 1, refused: 0, total_cents: 45000, rows: [] };
  assert.equal(P.summary(p), "5 new lessons · S$450.00 · 1 already on the timetable");
  assert.equal(P.summary({ new: 1, there: 0, refused: 2, total_cents: 9000 }), "1 new lesson · S$90.00 · 2 can’t be added");
  assert.equal(P.summary({ new: 0, there: 0, refused: 0, total_cents: 0 }), "0 new lessons");
  const v = P.rowView({ state: "refused", code: "CLASH", message: "This student already has a lesson then", date: "2026-11-23", start: "16:00:00", end: "17:30:00", amount_cents: 9000 });
  assert.equal(v.tone, "bad"); assert.equal(v.price, "S$90.00"); assert.match(v.note, /already has a lesson/);
  assert.equal(P.rowView({ state: "there", message: "Already on the timetable: nothing to add." , date: "2026-11-23"}).tone, "there");
  assert.equal(P.rowView({ state: "new", holiday: true, fee_month_closed: true, date: "2026-11-23" }).note, "On a centre holiday · Fee month already closed");
});
test("the Add button needs a clean preview, the holiday confirmation, and something new", () => {
  const ok = { new: 2, there: 0, refused: 0, rows: [{ code: null }] };
  assert.equal(P.canAdd(ok, {}, {}), true);
  assert.equal(P.canAdd(ok, { reason: "x" }, {}), false, "a form error");
  assert.equal(P.canAdd(Object.assign({}, ok, { refused: 1 }), {}, {}), false, "a refused row");
  assert.equal(P.canAdd({ new: 0, there: 2, refused: 0, rows: [] }, {}, {}), false, "nothing new");
  const hol = { new: 1, there: 0, refused: 1, rows: [{ code: "HOLIDAY" }] };
  assert.deepEqual(P.needs(hol), { holiday: true, closed: false });
  assert.deepEqual(P.needs({ rows: [{ code: "FEE_MONTH_CLOSED" }] }), { holiday: false, closed: true });
  assert.equal(P.canAdd(null, {}, {}), false);
});
test("the answers are in plain words", () => {
  assert.match(P.errorText({ message: "BACKFILL_OFF: this centre hasn't switched on adding past lessons" }), /switched on adding past lessons/);
  assert.match(P.errorText({ message: "NOT_ALLOWED: only the centre owner can add lessons to a month whose fee is already closed" }), /Only the centre owner/);
  assert.match(P.errorText({ message: "REMARKS_REQUIRED: this centre needs remarks" }), /needs remarks/);
  assert.equal(P.errorText({ message: "REFUSED: 2 of these lessons can't be added, so none were. First problem: This student already has a lesson then (16:00 to 17:30)." }),
    "2 lessons can’t be added, so none were. This student already has a lesson then (16:00 to 17:30).");
  assert.match(P.errorText({ message: "NOT_FOUND" }), /./);
  const d = P.doneText({ created: 5, skipped: 1, attended: true, fee_month_closed: false, invoiced_months: [] });
  assert.equal(d, "5 lessons added and marked attended. 1 was already there. They will be on the next invoice run.");
  assert.match(P.doneText({ created: 1, skipped: 0, attended: false, fee_month_closed: true, invoiced_months: ["2026-11-01"] }), /1 lesson added\. That fee month was already closed.*already has an invoice.*next one/);
  assert.match(P.doneText({ created: 2, skipped: 0, attended: false, invoiced_months: [] }), /Mark them attended to bill them/);
});
test("the pattern range starts at the last 7 days but never before the first allowed day", () => {
  assert.deepEqual(P.defaultRange("2026-11-27", "2026-10-01"), { from: "2026-11-20", to: "2026-11-26" });
  assert.deepEqual(P.defaultRange("2026-11-27", "2026-11-24"), { from: "2026-11-24", to: "2026-11-26" });
});
