// Make-up credit expiry (T18 step 4) — a job endpoint in the style of api/billing-cron.js. It calls the database function credits_expire_due(), which turns every
// OPEN credit whose last day has passed into "expired" (with an event and an audit row each). A booked credit never expires; running it twice changes nothing.
//
// NOT SCHEDULED: vercel.json has no cron entry for it (the orchestrator decides when to add one, e.g. daily after the fee job). Until then it can be called by hand:
//   curl -H "Authorization: Bearer $CRON_SECRET" "https://<host>/api/credits-cron?dry=1"      counts what WOULD expire (reads only)
//   curl -H "Authorization: Bearer $CRON_SECRET" "https://<host>/api/credits-cron"           expires them
// Auth: "Authorization: Bearer $CRON_SECRET" (16+ characters), the same secret as billing-cron; anything else is refused. The day is today in Singapore.
// Output: counts only (no names, no student ids).
"use strict";
const crypto = require("crypto");
const L = require("./_gcal-lib");         // send()
const B = require("./_billing-lib");      // svc(), dbConfigured()

function authorised(req) {
  const secret = process.env.CRON_SECRET || "";
  if (secret.length < 16) return false;
  const got = Buffer.from(String(req.headers.authorization || "")), want = Buffer.from("Bearer " + secret);
  return got.length === want.length && crypto.timingSafeEqual(got, want);
}
// today in Singapore (UTC+8, no daylight saving) as YYYY-MM-DD
function sgToday(nowMs) { return new Date((nowMs == null ? Date.now() : nowMs) + 8 * 3600e3).toISOString().slice(0, 10); }

async function handler(req, res) {
  if (req.method !== "GET" && req.method !== "POST") return L.send(res, 405, { error: "method" });
  if (!B.dbConfigured() || (process.env.CRON_SECRET || "").length < 16) return L.send(res, 503, { error: "not_configured" });
  if (!authorised(req)) return L.send(res, 401, { error: "unauthorised" });
  const dry = new URL(req.url || "/", "http://x").searchParams.get("dry") === "1";
  const day = sgToday();
  try {
    if (dry) {                                                         // reads ids only to count them; nothing is changed (at most 1000 are counted)
      const r = await B.svc("GET", "makeup_credits?select=id&status=eq.open&expires_on=lt." + day + "&limit=1000");
      if (!r.ok || !Array.isArray(r.data)) throw new Error("read " + r.status);
      return L.send(res, 200, { day, dry: true, would_expire: r.data.length });
    }
    const r = await B.svc("POST", "rpc/credits_expire_due", { p_today: day });
    if (!r.ok || !Number.isSafeInteger(r.data)) throw new Error("expire " + r.status);
    return L.send(res, 200, { day, dry: false, expired: r.data });
  } catch (e) {
    return L.send(res, 500, { error: "failed" });
  }
}
module.exports = handler;
module.exports.sgToday = sgToday;
