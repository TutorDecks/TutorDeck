// Pure decisions for the monthly centre-fee job (api/billing-cron.js): which month, which plan, what fee to record.
// No network, no secrets — unit-tested in tests/billing-job.test.js. Files starting with "_" are not routes on Vercel.
"use strict";
const Money = require("../assets/js/money.js");

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
// What to record for one centre. Returns { skip: reason } or { plan, fee }. No Stripe: centres are invoiced by TutorDeck (T31a).
function decide(plan, activeStudents) {
  if (!plan || plan.plan_code !== "centre") return { skip: "no_centre_plan" };
  return { plan, fee: Money.platformFee(activeStudents, plan) };
}

// What goes in platform_fee_snapshots (the row that marks this centre + month as done).
function snapshotRow(orgId, monthStart, plan, fee) {
  return { org_id: orgId, month: monthStart, active_students: fee.active, billable_students: fee.billable,
    base_cents: plan.base_cents, per_student_cents: plan.per_student_cents, fee_cents: fee.fee_cents };
}

module.exports = { sgMonthStart, prevMonthStart, validMonth, planFor, decide, snapshotRow };
