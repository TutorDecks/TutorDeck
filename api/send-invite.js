// Email a tutor / staff invite — POST /api/send-invite   Authorization: Bearer <TutorDeck access token>   body { "membership_id": "<uuid>" }
// Used right after org_invite (first mail) and by the people list's "Resend invite" button. The browser NEVER sends an address:
// everything about the invite (address, name, role, centre, inviter) comes out of the database, so this endpoint cannot be used to
// mail arbitrary people.
//   1  signed in?  The caller's own token runs org_invite_mail_reserve(): in SQL it checks the caller may manage tutors in that organisation,
//      that the invite is still waiting, and the limits (1 per invite per 10 min, 5 per 24 h, 30 per organisation per hour), and logs a 'pending' row.
//   2  Preview / local deploys only email @tutordeck.com.sg and INVITE_TEST_ALLOW addresses; any other is logged "blocked in preview" and NOT sent
//      (no account is created either).
//   3  the person's login is created if missing (email confirmed, a random password nobody knows), then Supabase's own recovery link is made
//      with the Auth admin API, pointing at /reset?welcome=1 on THIS site (only our allowed hosts).
//   4  Brevo sends it. The log row becomes 'sent' (+ Brevo's message id) or 'failed'. The invite row itself is never touched.
// The link is a password-setting key: it is never logged, never returned to the browser, never written to the database.
// Answers: 200 { ok, sent:true } | 200 { ok, sent:false, blocked:"preview" } | 401 | 403 | 409 not_invited | 429 too_soon/daily_limit/org_limit | 502 | 503 not_configured
// Env (Vercel, server only): BREVO_API_KEY, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (no default for the last two, so a Preview can't touch the live
// project); optional INVITE_TEST_ALLOW, BREVO_INVITE_TEMPLATE_ID. See api/_brevo-lib.js.
"use strict";
const crypto = require("crypto");
const L = require("./_gcal-lib");
const B = require("./_billing-lib");
const M = require("./_brevo-lib");

const serviceKey = () => process.env.SUPABASE_SERVICE_ROLE_KEY || "";
// Auth admin API and REST with the service key (server only)
async function admin(method, path, body) {
  const r = await fetch(B.SUPABASE_URL + path, { method, headers: { apikey: serviceKey(), Authorization: "Bearer " + serviceKey(), "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined });
  const t = await r.text();
  let d = null; try { d = t ? JSON.parse(t) : null; } catch (e) {}
  return { ok: r.ok, status: r.status, data: d };
}
async function markLog(id, status, messageId) {
  try { await B.svc("PATCH", "org_invite_mail_log?id=eq." + id, { status, brevo_message_id: messageId || null }, { Prefer: "return=minimal" }); } catch (e) { /* the mail outcome matters more than its log line */ }
}

// A one-time set-password link for this address. Creates the login first if there is none.
async function recoveryLink(email, redirectTo) {
  async function make() { return admin("POST", "/auth/v1/admin/generate_link", { type: "recovery", email, redirect_to: redirectTo }); }
  let g = await make();
  if (!g.ok) {
    const c = await admin("POST", "/auth/v1/admin/users", { email, email_confirm: true, password: crypto.randomBytes(24).toString("base64url") + "aA1!" });
    if (!c.ok && c.status !== 422) return null;                 // 422 = it already exists after all (someone signed up in between): just retry the link
    g = await make();
  }
  const link = g.ok && g.data && (g.data.action_link || (g.data.properties && g.data.properties.action_link));
  return link || null;
}

module.exports = async function (req, res) {
  if (req.method !== "POST") return L.send(res, 405, { error: "method" });
  if (!M.configured() || !B.SUPABASE_URL || !serviceKey()) return L.send(res, 503, { error: "not_configured" });
  const jwt = String(req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  const user = await L.getUser(jwt);
  if (!user) return L.send(res, 401, { error: "signed_out" });
  const b = await L.readBody(req);
  const mid = String(b.membership_id || "");
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(mid)) return L.send(res, 400, { error: "membership" });
  const origin = L.origin(req);
  if (!origin) return L.send(res, 400, { error: "host" });

  let logId = null;
  try {
    // 1 — permission + limits, in SQL, as the caller
    const rs = await L.db(jwt, "POST", "rpc/org_invite_mail_reserve", { p_member: mid });
    if (!rs.ok) return L.send(res, rs.status === 400 || rs.status === 403 ? 403 : 502, { error: rs.status === 400 || rs.status === 403 ? "forbidden" : "reserve_failed" });
    const r = rs.data || {};
    if (!r.ok) {
      const code = { not_invited: 409, too_soon: 429, daily_limit: 429, org_limit: 429 }[r.reason];
      return L.send(res, code || 409, { error: r.reason || "refused", retry_minutes: r.retry_minutes });
    }
    logId = r.log_id;

    // 2 — preview safety
    if (!M.addressAllowed(r.email)) {
      await markLog(logId, "blocked_preview");
      console.log("send-invite: blocked in preview", mid);            // ids only: never the address
      return L.send(res, 200, { ok: true, sent: false, blocked: "preview" });
    }

    // 3 — the link
    const link = await recoveryLink(r.email, origin + "/reset?welcome=1");
    if (!link) { await markLog(logId, "failed"); console.error("send-invite: no link", mid); return L.send(res, 502, { error: "link_failed" }); }

    // 4 — Brevo
    const sent = await M.send(M.inviteBody({ to: r.email, name: r.name, role: r.role, centre: r.centre, inviter: r.inviter, link }));
    if (!sent.ok) { await markLog(logId, "failed"); console.error("send-invite: brevo", sent.status, mid); return L.send(res, 502, { error: "email_failed" }); }
    await markLog(logId, "sent", sent.messageId);
    console.log("send-invite: sent", mid, sent.messageId || "");
    return L.send(res, 200, { ok: true, sent: true });
  } catch (e) {
    if (logId) await markLog(logId, "failed");
    console.error("send-invite", mid, e && e.code || "error");          // never the message: it could carry an address
    return L.send(res, 502, { error: "email_failed" });
  }
};
