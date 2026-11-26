"use strict";
const test = require("node:test"), assert = require("node:assert");
const J = require("../api/_billing-job-core.js");

test("billed month is the current Singapore month (UTC+8)", () => {
  assert.strictEqual(J.sgMonthStart(Date.UTC(2026, 11, 1, 0, 30)), "2026-12-01");          // 08:30 SGT on 1 Dec
  assert.strictEqual(J.sgMonthStart(Date.UTC(2026, 10, 30, 16, 30)), "2026-12-01");        // 00:30 SGT on 1 Dec = 16:30 UTC on 30 Nov
  assert.strictEqual(J.sgMonthStart(Date.UTC(2026, 10, 30, 15, 59)), "2026-11-01");        // still 23:59 SGT on 30 Nov
  assert.strictEqual(J.sgMonthStart(Date.UTC(2026, 11, 31, 16, 0)), "2027-01-01");         // year rollover
});
test("counted month is the one before", () => {
  assert.strictEqual(J.prevMonthStart("2026-12-01"), "2026-11-01");
  assert.strictEqual(J.prevMonthStart("2027-01-01"), "2026-12-01");
  assert.strictEqual(J.prevMonthStart("2026-03-01"), "2026-02-01");
});
test("month validation", () => {
  assert.ok(J.validMonth("2026-12-01")); assert.ok(!J.validMonth("2026-13-01")); assert.ok(!J.validMonth("2026-12-15")); assert.ok(!J.validMonth(""));
});
test("plan in force on the first of the billed month", () => {
  const rows = [{ plan_code: "centre", base_cents: 10000, per_student_cents: 50, effective_from: "2026-10-01" },
                { plan_code: "centre", base_cents: 5000, per_student_cents: 20, effective_from: "2026-12-01" },
                { plan_code: "centre", base_cents: 1, per_student_cents: 1, effective_from: "2027-02-01" }];
  assert.strictEqual(J.planFor(rows, "2026-11-01").base_cents, 10000);
  assert.strictEqual(J.planFor(rows, "2026-12-01").base_cents, 5000, "a plan effective on the 1st applies that month");
  assert.strictEqual(J.planFor(rows, "2026-09-01"), null);
});

const plan = { plan_code: "centre", base_cents: 10000, per_student_cents: 50, effective_from: "2026-10-01" };

test("decide: rounds and prices the fee (no Stripe involved, T31a)", () => {
  let d = J.decide(plan, 403);
  assert.strictEqual(d.fee.active, 403); assert.strictEqual(d.fee.billable, 400); assert.strictEqual(d.fee.fee_cents, 30000); assert.strictEqual(d.plan, plan);
  d = J.decide(plan, 405); assert.strictEqual(d.fee.billable, 410, "halves round up"); assert.strictEqual(d.fee.fee_cents, 10000 + 410 * 50);
  d = J.decide(plan, 3); assert.strictEqual(d.fee.billable, 0); assert.strictEqual(d.fee.fee_cents, 10000, "under 5 active students = base fee only");
  d = J.decide(plan, 98); assert.strictEqual(d.fee.billable, 100); assert.strictEqual(d.fee.fee_cents, 15000);
  d = J.decide(plan, 250); assert.strictEqual(d.fee.fee_cents, 22500);
});
test("decide: only a centre plan gets a fee", () => {
  assert.strictEqual(J.decide(null, 10).skip, "no_centre_plan");
  assert.strictEqual(J.decide({ plan_code: "solo", base_cents: 0, per_student_cents: 0 }, 10).skip, "no_centre_plan");
});
test("the job core has no Stripe pieces left", () => {
  ["decide", "snapshotRow", "planFor", "sgMonthStart", "prevMonthStart", "validMonth"].forEach((k) => assert.strictEqual(typeof J[k], "function", k));
  ["itemByKey", "renewedInMonth", "STUDENT_PRICE_KEY", "BASE_PRICE_KEY"].forEach((k) => assert.strictEqual(J[k], undefined, k + " must be gone"));
});
test("snapshot row has exactly the table's columns", () => {
  const f = J.decide(plan, 403).fee;
  assert.deepStrictEqual(J.snapshotRow("o1", "2026-12-01", plan, f), { org_id: "o1", month: "2026-12-01", active_students: 403, billable_students: 400, base_cents: 10000, per_student_cents: 50, fee_cents: 30000 });
});
