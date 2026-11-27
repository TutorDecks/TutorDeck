// Brevo tells us what happened to a message — POST /api/brevo-webhook   (Brevo → Transactional → Settings → Webhooks, events: hard bounce, blocked, invalid email, spam, error)
// A bounced, blocked, invalid or reported address is marked "bad" on the guardian (db: email_mark_bounce), staff see it on Money > Email, and nothing more is sent to it
// until someone fixes the address. Soft bounces are only noted in the log. Other events (delivered, opened, clicked ...) are ignored.
// Auth: the secret from BREVO_WEBHOOK_SECRET (16+ characters), sent as "Authorization: Bearer <secret>" or, where Brevo can't set a header, as ?s=<secret> on the URL.
// Always answers 200 to an authorised call (Brevo retries anything else): { ok, handled }. Never logs an address.
"use strict";
const crypto = require("crypto");
const L = require("./_gcal-lib");
const R = require("./_email-run");

const KINDS = { hard_bounce: "hard_bounce", soft_bounce: "soft_bounce", blocked: "blocked", invalid_email: "invalid", invalid: "invalid", spam: "spam", complaint: "spam", error: "error", unsubscribe: "unsubscribed", unsubscribed: "unsubscribed" };

function same(a, b) { const x = Buffer.from(String(a)), y = Buffer.from(String(b)); return x.length === y.length && crypto.timingSafeEqual(x, y); }
function authorised(req) {
  const secret = process.env.BREVO_WEBHOOK_SECRET || "";
  if (secret.length < 16) return false;
  const h = String(req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  const q = new URL(req.url || "/", "http://x").searchParams.get("s") || "";
  return (h && same(h, secret)) || (q && same(q, secret));
}

module.exports = async function (req, res) {
  if (req.method !== "POST") return L.send(res, 405, { error: "method" });
  if (!R.configured() || (process.env.BREVO_WEBHOOK_SECRET || "").length < 16) return L.send(res, 503, { error: "not_configured" });
  if (!authorised(req)) return L.send(res, 401, { error: "unauthorised" });
  const b = await L.readBody(req);
  const events = (Array.isArray(b) ? b : [b]).slice(0, 100);
  let handled = 0;
  for (const ev of events) {
    const kind = ev && KINDS[String(ev.event || "").toLowerCase()], mid = ev && (ev["message-id"] || ev.message_id || ev.messageId);
    if (!kind || !mid) continue;
    try { if (await R.rpc("email_mark_bounce", { p_message_id: String(mid).slice(0, 200), p_kind: kind })) handled++; } catch (e) { console.error("brevo-webhook", e && e.status || "error"); }
  }
  return L.send(res, 200, { ok: true, handled });
};
