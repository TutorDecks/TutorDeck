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

const item = (id, key, unit, qty) => ({ id, quantity: qty, price: { lookup_key: key, unit_amount: unit } });
const sub = (o) => Object.assign({ status: "active", currency: "sgd", items: { data: [item("si_base", "centre_base_monthly", 10000, 1), item("si_stu", "centre_student_monthly", 50, 100)] } }, o || {});
const plan = { plan_code: "centre", base_cents: 10000, per_student_cents: 50, effective_from: "2026-10-01" };

test("decide: rounds, prices the fee, and says whether Stripe needs updating", () => {
  let d = J.decide(sub(), plan, 403);
  assert.strictEqual(d.fee.billable, 400); assert.strictEqual(d.fee.fee_cents, 30000); assert.strictEqual(d.targetQty, 400); assert.strictEqual(d.needsUpdate, true); assert.strictEqual(d.itemId, "si_stu");
  d = J.decide(sub(), plan, 405); assert.strictEqual(d.targetQty, 410, "halves round up");
  d = J.decide(sub({ items: { data: [item("si_base", "centre_base_monthly", 10000, 1), item("si_stu", "centre_student_monthly", 50, 400)] } }), plan, 403);
  assert.strictEqual(d.needsUpdate, false, "already correct: no Stripe write");
  d = J.decide(sub(), plan, 3); assert.strictEqual(d.targetQty, 0); assert.strictEqual(d.fee.fee_cents, 10000, "under 5 active students = base fee only");
});
test("decide: refuses to guess", () => {
  assert.strictEqual(J.decide(null, plan, 10).skip, "no_subscription");
  assert.strictEqual(J.decide(sub({ status: "canceled" }), plan, 10).skip, "subscription_ended");
  assert.strictEqual(J.decide(sub(), null, 10).skip, "no_centre_plan");
  assert.strictEqual(J.decide(sub(), { plan_code: "solo", base_cents: 0, per_student_cents: 0 }, 10).skip, "no_centre_plan");
  assert.strictEqual(J.decide(sub({ items: { data: [item("si_base", "centre_base_monthly", 10000, 1)] } }), plan, 10).skip, "missing_price_items");
  assert.strictEqual(J.decide(sub(), Object.assign({}, plan, { per_student_cents: 30 }), 10).skip, "price_mismatch", "plan says 30c, Stripe charges 50c");
  assert.strictEqual(J.decide(sub({ items: { data: [item("si_base", "centre_base_monthly", 10000, 1), item("si_stu", "centre_student_monthly", 40, 100)] } }), plan, 10).skip, "price_mismatch", "T30: Stripe still on the old 40c price, plan says 50c");
  assert.strictEqual(J.decide(sub(), Object.assign({}, plan, { per_student_cents: 40 }), 10).skip, "price_mismatch", "T30: plan still 40c, Stripe already on 50c");
  assert.strictEqual(J.decide(sub(), Object.assign({}, plan, { base_cents: 9000 }), 10).skip, "price_mismatch");
  assert.strictEqual(J.decide(sub({ currency: "usd" }), plan, 10).skip, "price_mismatch");
});
test("snapshot row has exactly the table's columns", () => {
  const f = J.decide(sub(), plan, 403).fee;
  assert.deepStrictEqual(J.snapshotRow("o1", "2026-12-01", plan, f), { org_id: "o1", month: "2026-12-01", active_students: 403, billable_students: 400, base_cents: 10000, per_student_cents: 50, fee_cents: 30000 });
});

test("renewal already billed this month → don't touch the quantity (it would land on the wrong month)", () => {
  const sec = (iso) => Date.parse(iso) / 1000;
  const withStart = (start, shape) => { const sb = sub(); if (shape === "sub") sb.current_period_start = start; else sb.items.data.forEach((i) => { i.current_period_start = start; }); return sb; };
  // period started on the 15th of last month → this month's renewal is still ahead: fine
  assert.strictEqual(J.renewedInMonth(withStart(sec("2026-11-15T04:00:00Z"), "item"), "2026-12-01"), false);
  // period started 1 Dec 04:00 UTC (12:00 SGT) → already renewed for December
  assert.strictEqual(J.renewedInMonth(withStart(sec("2026-12-01T04:00:00Z"), "item"), "2026-12-01"), true);
  // boundary: 00:00 SGT on the 1st counts as this month; 23:59:59 SGT the day before doesn't
  assert.strictEqual(J.renewedInMonth(withStart(sec("2026-11-30T16:00:00Z"), "item"), "2026-12-01"), true);
  assert.strictEqual(J.renewedInMonth(withStart(sec("2026-11-30T15:59:59Z"), "item"), "2026-12-01"), false);
  // older API shape: the period start is on the subscription itself
  assert.strictEqual(J.renewedInMonth(withStart(sec("2026-12-02T00:00:00Z"), "sub"), "2026-12-01"), true);
  // no period information at all: can't tell, so don't block
  assert.strictEqual(J.renewedInMonth(sub(), "2026-12-01"), false);
  // decide() uses it, but only when it is given the month
  assert.strictEqual(J.decide(withStart(sec("2026-12-01T04:00:00Z"), "item"), plan, 403, "2026-12-01").skip, "renewal_already_billed");
  assert.ok(J.decide(withStart(sec("2026-11-15T04:00:00Z"), "item"), plan, 403, "2026-12-01").fee);
});
