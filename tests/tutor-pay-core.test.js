"use strict";
const test = require("node:test"), assert = require("node:assert");
const P = require("../assets/js/tutor-pay-core.js");

const M = (o) => Object.assign({ org_id: "o1", org_name: "Opus Tuition", period_from: "2026-11-01", period_to: "2026-11-30", pay_view: "per_lesson_and_total", lessons: 4,
  earned_cents: 12000, adjustments_cents: 0, carry_cents: 0, total_cents: 12000, pending_lessons: 0, run_recorded: false }, o || {});

test("money is worded in dollars and cents, with a real minus", () => {
  assert.strictEqual(P.sgd(0), "S$0.00"); assert.strictEqual(P.sgd(4000), "S$40.00"); assert.strictEqual(P.sgd(1334), "S$13.34");
  assert.strictEqual(P.sgd(123456789), "S$1,234,567.89"); assert.strictEqual(P.sgd(-500), "−S$5.00"); assert.strictEqual(P.sgd("2921"), "S$29.21");
  assert.strictEqual(P.sgd(null), "S$0.00"); assert.strictEqual(P.sgd("abc"), "S$0.00");
  assert.strictEqual(P.signed(1500), "+S$15.00"); assert.strictEqual(P.signed(-500), "−S$5.00"); assert.strictEqual(P.signed(0), "S$0.00");
  assert.strictEqual(P.toCents(12.34), 1234); assert.strictEqual(P.toCents(0.1 + 0.2), 30);
});

test("months and pay periods read naturally", () => {
  assert.strictEqual(P.monthLabel("2026-11-01"), "November 2026"); assert.strictEqual(P.monthLabel(""), "");
  assert.strictEqual(P.periodLabel("2026-11-01", "2026-11-30"), "1 Nov – 30 Nov");
  assert.strictEqual(P.addMonths("2026-11-01", 1), "2026-12-01"); assert.strictEqual(P.addMonths("2026-01-01", -1), "2025-12-01"); assert.strictEqual(P.addMonths("2026-12-01", 13), "2028-01-01");
});

test("a centre's choice: only the two 'on' values show pay; anything else hides it", () => {
  assert.strictEqual(P.viewOf({ pay_view: "off" }), "off");
  assert.strictEqual(P.viewOf({ pay_view: "monthly_total" }), "monthly_total");
  assert.strictEqual(P.viewOf({ pay_view: "per_lesson_and_total" }), "per_lesson_and_total");
  for (const bad of [undefined, null, {}, { pay_view: "everything" }, { pay_view: "" }, { pay_view: 1 }]) assert.strictEqual(P.viewOf(bad), "off", "a doubt hides pay");
  assert.strictEqual(P.anyOn([]), false); assert.strictEqual(P.anyOn(null), false);
  assert.strictEqual(P.anyOn([{ pay_view: "off" }, { pay_view: "monthly_total" }]), true);
  assert.strictEqual(P.anyPerLesson([{ pay_view: "monthly_total" }]), false); assert.strictEqual(P.anyPerLesson([{ pay_view: "off" }, { pay_view: "per_lesson_and_total" }]), true);
});

test("a lesson's pay word: amount, or 'Pending' with no amount, or nothing", () => {
  assert.deepStrictEqual(P.lessonPay({ pay_state: "amount", pay_cents: 4000 }), { text: "S$40.00", tone: "amount", pending: false, cents: 4000 });
  const p = P.lessonPay({ pay_state: "pending", pay_cents: null });
  assert.strictEqual(p.text, "Pending"); assert.strictEqual(p.pending, true); assert.strictEqual(p.cents, undefined);
  // even if a pending row somehow carried an amount, the word never shows it
  assert.strictEqual(P.lessonPay({ pay_state: "pending", pay_cents: 4000 }).text, "Pending");
  assert.strictEqual(P.lessonPay({ pay_state: "amount", pay_cents: null }), null);
  assert.strictEqual(P.lessonPay({ pay_state: "other" }), null); assert.strictEqual(P.lessonPay(null), null);
  assert.deepStrictEqual(Object.keys(P.byLesson([{ lesson_id: "a" }, { lesson_id: "b" }, null, {}])), ["a", "b"]);
});

test("the My lessons summary: one line per centre, pending counted not valued", () => {
  const s = P.summaryLines([M({ pending_lessons: 3, total_cents: 4000 }), M({ org_name: "Other", run_recorded: true })]);
  assert.strictEqual(s.length, 2); assert.strictEqual(s[0].total, "S$40.00"); assert.strictEqual(s[0].pending, 3); assert.strictEqual(s[0].final, false);
  assert.strictEqual(s[1].final, true); assert.strictEqual(s[0].period, "1 Nov – 30 Nov");
  assert.strictEqual(P.pendingWord(1), "1 lesson pending"); assert.strictEqual(P.pendingWord(4), "4 lessons pending");
  assert.strictEqual(P.estimateNote(false), "Estimate until the pay run is confirmed"); assert.strictEqual(P.estimateNote(true), "Pay run confirmed");
});

test("the monthly page lines: earned, each bonus / deduction with the staff's label, carry only when not zero, total last", () => {
  const lines = P.monthLines(M({ earned_cents: 20000, adjustments_cents: 1000, carry_cents: 0, total_cents: 21000 }),
    [{ label: "Great month", adjustment_cents: 1500, effective_on: "2026-11-15" }, { label: "Lost textbook", adjustment_cents: -500, effective_on: "2026-11-16" }]);
  assert.deepStrictEqual(lines.map((l) => l.kind), ["earned", "bonus", "deduction", "total"]);
  assert.deepStrictEqual(lines.map((l) => l.text), ["S$200.00", "+S$15.00", "−S$5.00", "S$210.00"]);
  assert.strictEqual(lines[1].label, "Great month"); assert.strictEqual(lines[2].label, "Lost textbook");
  const withCarry = P.monthLines(M({ carry_cents: 12000, earned_cents: 4000, total_cents: 16000 }), []);
  assert.deepStrictEqual(withCarry.map((l) => l.kind), ["earned", "carry", "total"]);
  assert.strictEqual(withCarry[1].text, "S$120.00");
  // nothing is invented: no row at all still gives a sane list
  assert.deepStrictEqual(P.monthLines(null, null).map((l) => l.text), ["S$0.00", "S$0.00"]);
});

test("combine: availability of the tick box", () => {
  assert.deepStrictEqual(P.combineAvailability([]), { shown: false, enabled: false, reason: "" });
  assert.deepStrictEqual(P.combineAvailability(null), { shown: false, enabled: false, reason: "" });
  assert.deepStrictEqual(P.combineAvailability([{ org_name: "Opus", pay_view: "per_lesson_and_total" }]), { shown: true, enabled: true, reason: "" });
  assert.deepStrictEqual(P.combineAvailability([{ org_name: "Opus", pay_view: "monthly_total" }]), { shown: true, enabled: true, reason: "" });
  const off = P.combineAvailability([{ org_name: "Opus", pay_view: "off" }]);
  assert.strictEqual(off.shown, true); assert.strictEqual(off.enabled, false); assert.match(off.reason, /Opus doesn.t show tutors their own pay/);
  const offMany = P.combineAvailability([{ org_name: "A", pay_view: "off" }, { org_name: "B", pay_view: "off" }]);
  assert.strictEqual(offMany.enabled, false); assert.match(offMany.reason, /None of your centres/);
  assert.strictEqual(P.combineAvailability([{ org_name: "A", pay_view: "off" }, { org_name: "B", pay_view: "monthly_total" }]).enabled, true);
});

test("combine: the Dashboard shows the lines only when the tick is on AND the centre allows it", () => {
  const on = [{ org_name: "Opus", pay_view: "monthly_total" }], off = [{ org_name: "Opus", pay_view: "off" }];
  assert.strictEqual(P.combineOn("1", on), true);
  assert.strictEqual(P.combineOn("0", on), false); assert.strictEqual(P.combineOn(null, on), false); assert.strictEqual(P.combineOn(undefined, on), false);
  assert.strictEqual(P.combineOn("1", off), false, "the centre switching pay off wins over the tick");
  assert.strictEqual(P.combineOn("1", []), false, "a tutor with no centre never sees it");
  assert.strictEqual(P.combineOn(true, on), false, "only the stored '1' counts");
});

test("combine: My students + At <centre> + a combined total; pending is separate and never added", () => {
  const c = P.combine(150000, [M({ total_cents: 12000, pending_lessons: 4 })]);
  assert.strictEqual(c.mine.label, "My students"); assert.strictEqual(c.mine.text, "S$1,500.00");
  assert.strictEqual(c.centres[0].label, "At Opus Tuition"); assert.strictEqual(c.centres[0].text, "S$120.00");
  assert.strictEqual(c.total.cents, 162000); assert.strictEqual(c.total.text, "S$1,620.00"); assert.strictEqual(c.total.label, "Combined");
  assert.strictEqual(c.pending, 4); assert.strictEqual(c.pendingText, "4 lessons pending");
  assert.strictEqual(c.total.cents, c.mine.cents + c.centres[0].cents, "pending lessons add nothing to the total");
  assert.match(c.note, /estimate until the pay run is confirmed/);
});

test("combine can use the Dashboard's plain $ so one screen shows one currency mark", () => {
  const c = P.combine(150000, [M({ total_cents: 12000 })], "$");
  assert.deepStrictEqual([c.mine.text, c.centres[0].text, c.total.text], ["$1,500.00", "$120.00", "$1,620.00"]);
  assert.strictEqual(P.sgd(-500, "$"), "−$5.00");
});

test("combine: two centres, a deduction month, nothing pending, a confirmed pay run", () => {
  const c = P.combine(0, [M({ org_name: "A", total_cents: 7000, run_recorded: true }), M({ org_name: "B", total_cents: -500, run_recorded: true })]);
  assert.deepStrictEqual(c.centres.map((x) => x.label), ["At A", "At B"]);
  assert.strictEqual(c.total.cents, 6500); assert.strictEqual(c.pendingText, ""); assert.strictEqual(c.allFinal, true); assert.match(c.note, /confirmed/);
  const none = P.combine(10000, []);
  assert.strictEqual(none.total.cents, 10000); assert.strictEqual(none.centres.length, 0); assert.strictEqual(none.allFinal, false);
});

test("combine never changes what it is given (centre pay can't leak into the solo figures)", () => {
  const rows = [M({ total_cents: 12000, pending_lessons: 1 })], before = JSON.stringify(rows);
  const solo = 5000, c = P.combine(solo, rows);
  assert.strictEqual(JSON.stringify(rows), before); assert.strictEqual(solo, 5000);
  c.centres[0].cents = 0; c.total.cents = 0;
  assert.strictEqual(rows[0].total_cents, 12000, "editing the result does not edit the database rows");
  assert.strictEqual(c.mine.cents, 5000, "the solo figure goes in and comes out as it was");
});

test("combine reads only pay figures: no key of a fee, rate, percentage or invoice is ever used", () => {
  const src = require("fs").readFileSync(require("path").join(__dirname, "../assets/js/tutor-pay-core.js"), "utf8").replace(/\/\/[^\n]*/g, "");
  assert.ok(!/\.(fee|rate|percent|percent_bp|invoice|invoice_id|amount|paid|price)\b/i.test(src), "the code never reads a fee, rate, percentage, invoice, amount or paid field");
});

test("error words are kind and never show raw database text", () => {
  assert.match(P.errorText({ message: "NOT_FOUND" }), /isn.t available here/);
  assert.match(P.errorText({ message: "boom: secret" }), /right now/); assert.ok(!/secret/.test(P.errorText({ message: "boom: secret" })));
  assert.match(P.errorText(null), /right now/);
});
