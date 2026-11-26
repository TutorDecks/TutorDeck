// Monthly centre fee — Vercel cron, once a day (vercel.json). For each ACTIVE centre that has no snapshot yet for the
// current Singapore month it: counts last month's active students → rounds them (assets/js/money.js) → sets the
// quantity on the centre's per-student Stripe item → records the snapshot. The snapshot is written LAST, so a failure
// part-way is retried by tomorrow's run (the quantity update is idempotent). Re-runs after success do nothing.
//
// Two billing methods per centre (org_plans.billing_method): 'stripe' (default, as above) and 'invoice' (managed: TutorDeck invoices the centre,
// it pays by PayNow): for 'invoice' centres the job ONLY records the snapshot, never calls Stripe, and needs no Stripe subscription row.
//
// T36 billing start (org_plans.billing_starts_on / first_month_billable_override): a month BEFORE the start is recorded for information only
// (billable=false, waived_reason 'pilot', fee 0; Stripe is never contacted, whatever the method); the FIRST billed month counts the agreed
// override number instead (rounded like any count; the snapshot keeps the real count too). Rules in api/_billing-job-core.js startRule().
//
// Auth: Vercel sends "Authorization: Bearer $CRON_SECRET" to cron invocations; anything else is refused.
// GET /api/billing-cron?dry=1          → shows what it WOULD do; touches neither Stripe nor the database
// GET /api/billing-cron?dry=1&month=2026-12   → dry run for another month (real runs always use the current month)
// Output has counts and money only (no names).
"use strict";
const crypto = require("crypto");
const L = require("./_gcal-lib");         // send()
const B = require("./_billing-lib");      // stripe(), svc(), configured()
const J = require("./_billing-job-core");

function authorised(req) {
  const secret = process.env.CRON_SECRET || "";
  if (secret.length < 16) return false;
  const got = Buffer.from(String(req.headers.authorization || "")), want = Buffer.from("Bearer " + secret);
  return got.length === want.length && crypto.timingSafeEqual(got, want);
}

module.exports = async function (req, res) {
  if (req.method !== "GET" && req.method !== "POST") return L.send(res, 405, { error: "method" });
  if (!B.dbConfigured() || (process.env.CRON_SECRET || "").length < 16) return L.send(res, 503, { error: "not_configured" });
  if (!authorised(req)) return L.send(res, 401, { error: "unauthorised" });

  const q = new URL(req.url || "/", "http://x").searchParams;
  const dry = q.get("dry") === "1";
  let month = J.sgMonthStart();
  if (q.get("month")) {                                   // only for dry runs: a real run can't be pointed at another month
    const m = q.get("month") + "-01";
    if (!dry || !J.validMonth(m)) return L.send(res, 400, { error: "month" });
    month = m;
  }
  const counted = J.prevMonthStart(month);
  const out = { month, counted_month: counted, dry, centres: [], failed: 0 };

  try {
    const orgs = await B.svc("GET", "organisations?select=id&kind=eq.centre&status=eq.active&order=created_at");
    if (!orgs.ok) throw new Error("organisations " + orgs.status);
    const done = await B.svc("GET", "platform_fee_snapshots?select=org_id&month=eq." + month);
    if (!done.ok) throw new Error("snapshots " + done.status);
    const doneSet = new Set((done.data || []).map((r) => r.org_id));

    for (const o of orgs.data || []) {
      const row = { org_id: o.id };
      try {
        if (doneSet.has(o.id)) { row.result = "already_done"; out.centres.push(row); continue; }
        const [plans, subRow, cnt] = await Promise.all([
          B.svc("GET", "org_plans?select=plan_code,billing_method,base_cents,per_student_cents,effective_from,billing_starts_on,first_month_billable_override&org_id=eq." + o.id),
          B.svc("GET", "org_subscriptions?select=stripe_subscription_id&org_id=eq." + o.id),
          B.svc("POST", "rpc/org_active_students_in_month", { p_org: o.id, p_month: counted })]);
        if (!plans.ok || !subRow.ok || !cnt.ok || !Number.isSafeInteger(cnt.data)) throw new Error("database read");
        const plan = J.planFor(plans.data, month);
        const pilot = !!plan && plan.plan_code === "centre" && J.startRule(plan, month, cnt.data).kind === "pilot";
        if (J.isInvoice(plan) || pilot) {                               // managed centre, or a pilot month: record the fee only, Stripe is never contacted
          const d = J.decideInvoice(plan, cnt.data, month);
          if (d.skip) { row.result = "skipped:" + d.skip; out.centres.push(row); continue; }
          Object.assign(row, { method: J.isInvoice(plan) ? "invoice" : "stripe", active: d.fee.active, billable: d.fee.billable, fee_cents: d.fee.fee_cents });
          if (d.rule.kind !== "normal") row.start = d.rule.kind === "pilot" ? "pilot" : "first_month_agreed_number";
          if (dry) { row.result = "dry:would_record"; out.centres.push(row); continue; }
          const wi = await B.svc("POST", "platform_fee_snapshots", J.snapshotRow(o.id, month, plan, d.fee, d.rule), { Prefer: "return=minimal" });
          if (!wi.ok && wi.status !== 409) throw new Error("snapshot write " + wi.status);
          row.result = "recorded"; out.centres.push(row); continue;
        }
        const subId = subRow.data && subRow.data[0] && subRow.data[0].stripe_subscription_id;
        if (!subId) { row.result = "skipped:no_subscription"; out.centres.push(row); continue; }
        const sub = await B.stripe("GET", "/subscriptions/" + encodeURIComponent(subId));
        const d = J.decide(sub, plan, cnt.data, month);
        // these need a human, so they count as failures (HTTP 500, visible in the logs); the others are normal "nothing to do"
        if (d.skip) { row.result = "skipped:" + d.skip; out.failed += ["price_mismatch", "missing_price_items", "renewal_already_billed"].indexOf(d.skip) >= 0 ? 1 : 0; out.centres.push(row); continue; }
        Object.assign(row, { active: d.fee.active, billable: d.fee.billable, fee_cents: d.fee.fee_cents, quantity_before: d.currentQty });
        if (d.rule.kind === "override") row.start = "first_month_agreed_number";
        if (dry) { row.result = d.needsUpdate ? "dry:would_update" : "dry:already_correct"; out.centres.push(row); continue; }
        if (d.needsUpdate) {
          await B.stripe("POST", "/subscriptions/" + encodeURIComponent(subId),
            { items: [{ id: d.itemId, quantity: d.targetQty }], proration_behavior: "none" });
        }
        const w = await B.svc("POST", "platform_fee_snapshots", J.snapshotRow(o.id, month, plan, d.fee, d.rule), { Prefer: "return=minimal" });
        if (!w.ok && w.status !== 409) throw new Error("snapshot write " + w.status);
        row.result = d.needsUpdate ? "updated" : "already_correct";
      } catch (e) {
        console.error("billing-cron", o.id, e && e.message);       // never echo Stripe/database internals
        row.result = "error"; out.failed++;
      }
      out.centres.push(row);
    }
  } catch (e) {
    console.error("billing-cron", e && e.message);
    return L.send(res, 500, { error: "job_failed" });
  }
  return L.send(res, out.failed ? 500 : 200, out);
};
