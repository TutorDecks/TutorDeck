// node --test tests/   — worked examples for assets/js/money.js (all amounts in cents)
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const M = require("../assets/js/money.js");

test("TutorDeck fee: the brief's worked examples (S$100 base + 50c × billable students)", () => {
  const plan = { base_cents: 10000, per_student_cents: 50 };
  const cases = [[98, 100, 15000], [250, 250, 22500], [398, 400, 30000], [403, 400, 30000],
                 [405, 410, 30500], [500, 500, 35000], [1000, 1000, 60000]];
  for (const [active, billable, fee] of cases) {
    const r = M.platformFee(active, plan);
    assert.equal(r.billable, billable, active + " active → " + billable + " billable");
    assert.equal(r.fee_cents, fee, active + " active → " + M.format(fee));
  }
  assert.equal(M.billableStudents(0), 0);
  assert.equal(M.billableStudents(4), 0);
  assert.equal(M.billableStudents(5), 10);
  assert.throws(() => M.billableStudents(3.5));
});

test("GST once per invoice, half up", () => {
  // 3 lessons of S$33.35 = S$100.05; 9% = 900.45c → 900c... exact: 10005 × 0.09 = 900.45 → 900
  assert.deepEqual(M.invoiceTotals([{ cents: 3335 }, { cents: 3335 }, { cents: 3335 }], { gst_registered: true, gst_rate_bp: 900 }),
    { net: 10005, gst: 900, total: 10905 });
  // per-line rounding would give 3 × round(300.15) = 900 too; this case shows the half-up edge: 50c × 9% = 4.5c → 5c
  assert.deepEqual(M.gstForInvoice(50, 900, false, true), { net: 50, gst: 5, total: 55 });
  // inclusive: S$109.00 includes S$9.00 GST
  assert.deepEqual(M.gstForInvoice(10900, 900, true, true), { net: 10000, gst: 900, total: 10900 });
  // not registered: no GST
  assert.deepEqual(M.gstForInvoice(10000, 900, false, false), { net: 10000, gst: 0, total: 10000 });
  // credit note (negative): rounds away from zero symmetrically
  assert.deepEqual(M.gstForInvoice(-50, 900, false, true), { net: -50, gst: -5, total: -55 });
});

test("parsing and formatting never use floats", () => {
  assert.equal(M.parse("1,234.50"), 123450);
  assert.equal(M.parse("S$0.1"), 10);
  assert.equal(M.parse("-3.05"), -305);
  assert.equal(M.parse("12"), 1200);
  assert.equal(M.parse("1.005"), null);       // more than 2 decimals is refused, not rounded silently
  assert.equal(M.parse("abc"), null);
  assert.equal(M.format(123450), "S$1,234.50");
  assert.equal(M.format(-5), "-S$0.05");
  assert.throws(() => M.format(1.5));
});

test("discounts, proration, tutor pay", () => {
  assert.equal(M.siblingDiscount(6000, 1, { type: "percent", percent_bp: 1000 }), 0);
  assert.equal(M.siblingDiscount(6000, 2, { type: "percent", percent_bp: 1000 }), 600);
  assert.equal(M.siblingDiscount(1000, 3, { type: "fixed", fixed_cents: 1500 }), 1000);   // never more than the fee
  // joins with 3 of 4 lessons left in a S$240 month
  assert.equal(M.prorate(24000, 4, 3, "by_remaining"), 18000);
  assert.equal(M.prorate(10000, 3, 1, "by_remaining"), 3333);
  assert.equal(M.prorate(10000, 3, 2, "by_remaining"), 6667);
  assert.equal(M.prorate(24000, 4, 3, "full"), 24000);
  assert.equal(M.prorate(24000, 4, 3, "skip"), 0);
  assert.equal(M.tutorPay("per_hour", 3000, { minutes: 90 }), 4500);
  assert.equal(M.tutorPay("per_student_lesson", 1200, { students: 4 }), 4800);
  assert.equal(M.tutorPay("per_lesson", 5000, {}), 5000);
  assert.equal(M.divRound(5, 2), 3);
  assert.equal(M.divRound(-5, 2), -3);
});
