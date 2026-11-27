// Send a centre's queued family emails now — POST /api/email-send   Authorization: Bearer <TutorDeck access token>   body { "org_id": "<uuid>" }
// Called by the Money > Email screen after staff press Send / "Send now", and when the screen is opened with messages waiting.
// WHO may send is decided in the database, as the caller: email_queue_status() starts with the same gate as every other money screen (the centre's owner, or staff
// with "Issue invoices" or "Record payments"; tutors, parents, strangers and solo tutors get nothing). The browser never sends an address or any text: everything
// comes out of the database (see api/_email-run.js). It sends no more than the centre's own caps and the platform's room allow, so calling it again and again is harmless.
// Answers: 200 { ok, queue, sent, retried, failed, invalid, blocked, stopped } | 401 | 403 | 404 | 405 | 502 | 503 not_configured
// Env (Vercel, server only): BREVO_API_KEY, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY; see api/_email-run.js.
"use strict";
const L = require("./_gcal-lib");
const R = require("./_email-run");

module.exports = async function (req, res) {
  if (req.method !== "POST") return L.send(res, 405, { error: "method" });
  if (!R.configured()) return L.send(res, 503, { error: "not_configured" });
  const jwt = String(req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  const user = await L.getUser(jwt);
  if (!user) return L.send(res, 401, { error: "signed_out" });
  const b = await L.readBody(req);
  const org = String(b.org_id || "");
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(org)) return L.send(res, 400, { error: "org" });
  const origin = R.linkOrigin(req);
  if (!origin) return L.send(res, 400, { error: "host" });
  try {
    // the gate, as the caller (any centre member who may see the money screens may ask for a send)
    const st = await L.db(jwt, "POST", "rpc/email_queue_status", { p_org: org });
    if (!st.ok) return L.send(res, st.status === 400 || st.status === 403 || st.status === 404 ? 404 : 502, { error: st.status === 400 || st.status === 403 || st.status === 404 ? "not_found" : "status_failed" });
    if (!st.data || st.data.mode === "off") return L.send(res, 200, { ok: true, queue: st.data || null, claimed: 0, sent: 0, retried: 0, failed: 0, invalid: 0, blocked: 0, stopped: "off" });
    try { await R.rpc("email_plan_reminders", { p_org: org, p_dry: false }); } catch (e) { /* reminders are planned again tomorrow; sending what is queued matters more */ }
    const out = await R.drain({ org, origin, budgetMs: 20000, max: 60 });
    const after = await L.db(jwt, "POST", "rpc/email_queue_status", { p_org: org });
    console.log("email-send", org, out.claimed, out.sent);                  // ids and counts only: never an address, a link or a key
    return L.send(res, 200, Object.assign({ ok: true, queue: after.ok ? after.data : st.data }, out));
  } catch (e) {
    console.error("email-send", e && e.status || "error");
    return L.send(res, 502, { error: "send_failed" });
  }
};
