// Pure decisions for the monthly centre-fee job (api/billing-cron.js): which month, which plan, what to tell Stripe.
// No network, no secrets — unit-tested in tests/billing-job.test.js. Files starting with "_" are not routes on Vercel.
"use strict";
const Money = require("../assets/js/money.js");

const STUDENT_PRICE_KEY = "centre_student_monthly";
const BASE_PRICE_KEY = "centre_base_monthly";
const DEAD = ["canceled", "incomplete_expired"];

// First day of the CURRENT month in Singapore (UTC+8, no daylight saving) → "YYYY-MM-01". This is the month being billed.
function sgMonthStart(nowMs) {
  const d = new Date((nowMs == null ? Date.now() : nowMs) + 8 * 3600e3);
  return d.getUTCFullYear() + "-" + String(d.getUTCMonth() + 1).padStart(2, "0") + "-01";
}
// "2026-01-01" → "2025-12-01": the month whose students are counted.
function prevMonthStart(monthStart) {
  const y = Number(monthStart.slice(0, 4)), m = Number(monthStart.slice(5, 7));
  return m === 1 ? (y - 1) + "-12-01" : y + "-" + String(m - 1).padStart(2, "0") + "-01";
}
const validMonth = (s) => /^\d{4}-(0[1-9]|1[0-2])-01$/.test(String(s || ""));

// The plan in force on the first day of the billed month (latest effective_from on or before it).
function planFor(rows, monthStart) {
  const ok = (rows || []).filter((p) => p.effective_from <= monthStart).sort((a, b) => (a.effective_from < b.effective_from ? 1 : -1));
  return ok[0] || null;
}
const itemByKey = (sub, key) => ((sub && sub.items && sub.items.data) || []).find((i) => i.price && i.price.lookup_key === key) || null;

// Start of a Singapore month ("YYYY-MM-01" 00:00 SGT) as a Unix timestamp in seconds.
function sgMonthStartSec(monthStart) { return Date.parse(monthStart + "T00:00:00+08:00") / 1000; }
// The current billing period began on or after the 1st of the billed month: this month's renewal has ALREADY been invoiced,
// so a quantity set now would land on NEXT month's invoice with the wrong month's count. Stripe keeps the period start on the
// item in newer API versions and on the subscription in older ones.
function renewedInMonth(sub, monthStart) {
  const item = sub && sub.items && sub.items.data && sub.items.data[0];
  const start = (item && item.current_period_start) || (sub && sub.current_period_start);
  return Number.isFinite(start) && start >= sgMonthStartSec(monthStart);
}

// What to do for one centre. Returns { skip: reason } or { fee, itemId, currentQty, targetQty, needsUpdate }.
// The Stripe prices must equal the organisation's plan (org_plans is the source of truth) — if they differ, we don't guess.
function decide(sub, plan, activeStudents, monthStart) {
  if (!sub) return { skip: "no_subscription" };
  if (DEAD.indexOf(sub.status) >= 0) return { skip: "subscription_ended" };
  if (!plan || plan.plan_code !== "centre") return { skip: "no_centre_plan" };
  const stu = itemByKey(sub, STUDENT_PRICE_KEY), base = itemByKey(sub, BASE_PRICE_KEY);
  if (!stu || !base) return { skip: "missing_price_items" };
  if (sub.currency !== "sgd" || stu.price.unit_amount !== plan.per_student_cents || base.price.unit_amount !== plan.base_cents) return { skip: "price_mismatch" };
  if (monthStart && renewedInMonth(sub, monthStart)) return { skip: "renewal_already_billed" };
  const fee = Money.platformFee(activeStudents, plan);
  return { fee, itemId: stu.id, currentQty: stu.quantity, targetQty: fee.billable, needsUpdate: stu.quantity !== fee.billable };
}

// What goes in platform_fee_snapshots (the row that marks this centre + month as done).
function snapshotRow(orgId, monthStart, plan, fee) {
  return { org_id: orgId, month: monthStart, active_students: fee.active, billable_students: fee.billable,
    base_cents: plan.base_cents, per_student_cents: plan.per_student_cents, fee_cents: fee.fee_cents };
}

module.exports = { renewedInMonth, sgMonthStart, prevMonthStart, validMonth, planFor, itemByKey, decide, snapshotRow, STUDENT_PRICE_KEY, BASE_PRICE_KEY };
