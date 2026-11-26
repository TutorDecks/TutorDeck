// Monthly centre fee — Vercel cron, once a day (vercel.json). For each ACTIVE centre that has no snapshot yet for the
// current Singapore month it: counts last month's active students → rounds them (assets/js/money.js) → records the fee
// snapshot (active → billable → fee in cents). Centres are NOT billed through Stripe (T31a: TutorDeck invoices them and they
// pay by PayNow), so this job never talks to Stripe. The snapshot is written LAST, so a failure part-way is retried by
// tomorrow's run. Re-runs after success do nothing; a closed month is never recomputed.
//
// Auth: Vercel sends "Authorization: Bearer $CRON_SECRET" to cron invocations; anything else is refused.
// GET /api/billing-cron?dry=1          → shows what it WOULD record; writes nothing
// GET /api/billing-cron?dry=1&month=2026-12   → dry run for another month (real runs always use the current month)
// Output has counts and money only (no names).
"use strict";
const crypto = require("crypto");
const L = require("./_gcal-lib");         // send()
const B = require("./_billing-lib");      // svc(), configured()  (Stripe is deliberately not used here)
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
        const [plans, cnt] = await Promise.all([
          B.svc("GET", "org_plans?select=plan_code,base_cents,per_student_cents,effective_from&org_id=eq." + o.id),
          B.svc("POST", "rpc/org_active_students_in_month", { p_org: o.id, p_month: counted })]);
        if (!plans.ok || !cnt.ok || !Number.isSafeInteger(cnt.data)) throw new Error("database read");
        const d = J.decide(J.planFor(plans.data, month), cnt.data);
        if (d.skip) { row.result = "skipped:" + d.skip; out.centres.push(row); continue; }   // no centre plan: nothing to record
        Object.assign(row, { active: d.fee.active, billable: d.fee.billable, fee_cents: d.fee.fee_cents });
        if (dry) { row.result = "dry:would_record"; out.centres.push(row); continue; }
        const w = await B.svc("POST", "platform_fee_snapshots", J.snapshotRow(o.id, month, d.plan, d.fee), { Prefer: "return=minimal" });
        if (!w.ok && w.status !== 409) throw new Error("snapshot write " + w.status);
        row.result = "recorded";
      } catch (e) {
        console.error("billing-cron", o.id, e && e.message);       // never echo database internals
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
