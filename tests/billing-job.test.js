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

test("invoice centres: only the fee is decided, nothing about Stripe (T31a)", () => {
  assert.strictEqual(J.isInvoice({ billing_method: "invoice" }), true);
  assert.strictEqual(J.isInvoice({ billing_method: "stripe" }), false); assert.strictEqual(J.isInvoice({}), false, "no method = stripe (default)"); assert.strictEqual(J.isInvoice(null), false);
  const d = J.decideInvoice(plan, 403); assert.strictEqual(d.fee.billable, 400); assert.strictEqual(d.fee.fee_cents, 30000);
  assert.strictEqual(J.decideInvoice(plan, 3).fee.fee_cents, 10000);
  assert.strictEqual(J.decideInvoice(null, 5).skip, "no_centre_plan"); assert.strictEqual(J.decideInvoice({ plan_code: "solo" }, 5).skip, "no_centre_plan");
});

// ---- T36: billing start date + first-month agreed number
test("startRule: no start date = the normal rule, unchanged (T36)", () => {
  const r = J.startRule(plan, "2026-12-01", 403);
  assert.strictEqual(r.kind, "normal"); assert.deepStrictEqual(r.fee, { active: 403, billable: 400, fee_cents: 30000 });
  assert.strictEqual(J.startRule(Object.assign({}, plan, { billing_starts_on: null, first_month_billable_override: null }), "2026-12-01", 403).kind, "normal");
  assert.strictEqual(J.startRule(Object.assign({}, plan, { first_month_billable_override: 80 }), "2026-12-01", 403).kind, "normal", "an override without a start date does nothing");
});
test("startRule: a month before the start is a pilot: counted for information, fee 0 (T36)", () => {
  const p = Object.assign({}, plan, { billing_starts_on: "2027-02-01", first_month_billable_override: 80 });
  const r = J.startRule(p, "2027-01-01", 12);
  assert.strictEqual(r.kind, "pilot"); assert.deepStrictEqual(r.fee, { active: 12, billable: 10, fee_cents: 0 });
  assert.deepStrictEqual(J.snapshotRow("o1", "2027-01-01", p, r.fee, r), { org_id: "o1", month: "2027-01-01", active_students: 12, billable_students: 10, base_cents: 10000, per_student_cents: 50, fee_cents: 0, billable: false, waived_reason: "pilot" });
  assert.strictEqual(J.startRule(p, "2026-06-01", 0).kind, "pilot", "any earlier month too");
});
test("startRule: the first billed month uses the agreed number when there is one, rounded the usual way (T36)", () => {
  const p = Object.assign({}, plan, { billing_starts_on: "2027-02-01", first_month_billable_override: 85 });
  const r = J.startRule(p, "2027-02-01", 12);
  assert.strictEqual(r.kind, "override");
  assert.deepStrictEqual(r.fee, { active: 12, billable: 90, fee_cents: 10000 + 50 * 90 }, "85 rounds half-up to 90; the REAL count stays in 'active'");
  assert.deepStrictEqual(J.snapshotRow("o1", "2027-02-01", p, r.fee, r), { org_id: "o1", month: "2027-02-01", active_students: 12, billable_students: 90, base_cents: 10000, per_student_cents: 50, fee_cents: 14500, override_students: 85 });
  assert.strictEqual(J.startRule(Object.assign({}, p, { first_month_billable_override: 0 }), "2027-02-01", 12).fee.fee_cents, 10000, "an agreed 0 is an override too (base fee only)");
});
test("startRule: first billed month without an agreed number, and every later month, use the normal rule (T36)", () => {
  const p = Object.assign({}, plan, { billing_starts_on: "2027-02-01", first_month_billable_override: null });
  let r = J.startRule(p, "2027-02-01", 403); assert.strictEqual(r.kind, "normal"); assert.strictEqual(r.fee.fee_cents, 30000);
  assert.deepStrictEqual(J.snapshotRow("o1", "2027-02-01", p, r.fee, r), { org_id: "o1", month: "2027-02-01", active_students: 403, billable_students: 400, base_cents: 10000, per_student_cents: 50, fee_cents: 30000 });
  const q = Object.assign({}, p, { first_month_billable_override: 85 });
  r = J.startRule(q, "2027-03-01", 403); assert.strictEqual(r.kind, "normal", "the override is for ONE month only"); assert.strictEqual(r.fee.billable, 400);
});
test("decide / decideInvoice carry the rule: override sets the Stripe quantity, count stays real (T36)", () => {
  const p = Object.assign({}, plan, { billing_starts_on: "2026-12-01", first_month_billable_override: 85 });
  const d = J.decide(sub(), p, 12, "2026-12-01");
  assert.strictEqual(d.targetQty, 90); assert.strictEqual(d.fee.active, 12); assert.strictEqual(d.rule.kind, "override");
  const i = J.decideInvoice(p, 12, "2026-12-01"); assert.strictEqual(i.fee.fee_cents, 14500); assert.strictEqual(J.decideInvoice(plan, 12).rule.kind, "normal", "month omitted = normal");
});
