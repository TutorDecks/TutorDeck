// The daily family-email job — Vercel cron (vercel.json), early every morning in Singapore. For each centre that uses email it: plans the overdue reminders that have
// come due (db: email_plan_reminders), then sends what is queued, within every cap (each centre's own, and the platform's room under Brevo's day limit).
// A long queue is not a problem: whatever is over the day's cap simply waits for tomorrow's run (or for staff pressing "Send now" the next morning), which is why the
// screen says "N queued, sends over M days". On Vercel's Hobby plan a cron may run once a day; on Pro it can be set hourly (vercel.json) for a smoother stream.
// Auth: Vercel sends "Authorization: Bearer $CRON_SECRET"; anything else is refused. Production only: the cron does not run on previews.
// GET /api/email-cron?dry=1 → counts what it WOULD plan, sends nothing. Output has counts only.
"use strict";
const crypto = require("crypto");
const L = require("./_gcal-lib");
const R = require("./_email-run");

function authorised(req) {
  const secret = process.env.CRON_SECRET || "";
  if (secret.length < 16) return false;
  const got = Buffer.from(String(req.headers.authorization || "")), want = Buffer.from("Bearer " + secret);
  return got.length === want.length && crypto.timingSafeEqual(got, want);
}

module.exports = async function (req, res) {
  if (req.method !== "GET" && req.method !== "POST") return L.send(res, 405, { error: "method" });
  if (!R.configured() || (process.env.CRON_SECRET || "").length < 16) return L.send(res, 503, { error: "not_configured" });
  if (!authorised(req)) return L.send(res, 401, { error: "unauthorised" });
  const dry = new URL(req.url || "/", "http://x").searchParams.get("dry") === "1";
  const out = { dry, centres: 0, reminders_planned: 0, failed_centres: 0, send: null };
  try {
    const orgs = await R.rpc("email_active_orgs");
    for (const o of orgs || []) {
      out.centres++;
      try { out.reminders_planned += Number(await R.rpc("email_plan_reminders", { p_org: o.org_id, p_dry: dry })) || 0; } catch (e) { out.failed_centres++; }
    }
    if (!dry) out.send = await R.drain({ org: null, origin: R.linkOrigin(null), budgetMs: 45000, max: 250 });
    console.log("email-cron", out.centres, out.reminders_planned, out.send ? out.send.sent : 0);
    return L.send(res, 200, out);
  } catch (e) {
    console.error("email-cron", e && e.status || "error");
    return L.send(res, 502, Object.assign({ error: "job_failed" }, out));
  }
};
