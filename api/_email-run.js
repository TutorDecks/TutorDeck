// Sending the queue — shared by api/email-send.js (staff pressed Send / opened the screen) and api/email-cron.js (the daily job).
// Files starting with "_" are not routes on Vercel.
//
// Every limit that decides WHO may be sent WHEN lives in the database (db/migration_invoice_email.sql: email_claim() keeps to each centre's daily and hourly caps,
// checks everything again at this moment, and hands out only what may go). This file only: asks for the platform's room under Brevo's day limit, takes a
// small batch, writes each message (assets/js/invoice-email-core.js), sends it through Brevo, and tells the database what happened (email_complete()).
//   * Previews and local deploys only email @tutordeck.com.sg and the INVITE_TEST_ALLOW addresses (same rule as invites): any other message is closed as "blocked_preview".
//   * A message is never sent twice: it is "sending" in the database from the moment it is handed out, and only completed once.
//   * Brevo says 401/403 (our key or sender is wrong): the run STOPS, the rest of the batch goes back for an hour or two; nothing is marked bad.
//   * Nothing here logs an address, a link or a key. Counts only.
// Env (Vercel, server only): BREVO_API_KEY, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (no defaults, so a Preview can't touch the live project);
//   optional EMAIL_PLATFORM_DAILY_CAP (default 250 of Brevo's free 300), EMAIL_LINK_ORIGIN (the address the invoice links point at), INVITE_TEST_ALLOW.
"use strict";
const L = require("./_gcal-lib");
const B = require("./_billing-lib");
const M = require("./_brevo-lib");
const C = require("../assets/js/invoice-email-core.js");

const BATCH = 10;
const STAGGER_MS = 150;                    // a short pause between sends: a gentle stream, not a burst
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const serviceKey = () => process.env.SUPABASE_SERVICE_ROLE_KEY || "";
const configured = () => !!(M.configured() && B.SUPABASE_URL && serviceKey());
const platformCap = (env) => { const n = parseInt((env || process.env).EMAIL_PLATFORM_DAILY_CAP, 10); return n >= 1 && n <= 300 ? n : C.PLATFORM_DAILY_CAP; };

// The address invoice links point at: EMAIL_LINK_ORIGIN (if it is one of our hosts), else the host the staff member used, else the live address.
function linkOrigin(req, env) {
  env = env || process.env;
  const fromEnv = env.EMAIL_LINK_ORIGIN ? String(env.EMAIL_LINK_ORIGIN).replace(/\/+$/, "") : "";
  if (fromEnv && /^https:\/\/[a-z0-9.-]+$/i.test(fromEnv) && L.origin({ headers: { host: fromEnv.slice(8) } })) return fromEnv;
  const o = req && req.headers ? L.origin(req) : null;
  return o || (env.VERCEL_ENV === "production" ? "https://tutordeck.vercel.app" : null);
}

async function rpc(name, args) {
  const r = await B.svc("POST", "rpc/" + name, args || {});
  if (!r.ok) { const e = new Error("rpc " + name + " " + r.status); e.status = r.status; throw e; }
  return r.data;
}

// The exact body sent to Brevo for one claimed message (pure).
function brevoBody(item, origin, env) {
  const m = C.compose(item, origin);
  const replyOk = item.reply_to && C.validEmail(item.reply_to);
  return { body: { sender: M.senderFor(item.centre), replyTo: replyOk ? { email: item.reply_to, name: M.cleanName(item.centre, "TutorDeck") } : M.REPLY_TO,
    to: [{ email: String(item.to).trim().toLowerCase() }], subject: m.subject, htmlContent: m.html, textContent: m.text, tags: ["family-" + m.kind] }, message: m };
}

// Send what is due. opts: { org (uuid | null = every centre), origin, budgetMs, max, env, fetchImpl }.  Returns counts only.
async function drain(opts) {
  opts = opts || {};
  const env = opts.env || process.env, started = Date.now(), budget = opts.budgetMs || 20000, out = { claimed: 0, sent: 0, retried: 0, failed: 0, invalid: 0, blocked: 0, stopped: null };
  const maxTotal = opts.max || 200;
  let sent24 = await rpc("email_platform_sent_24h");
  while (out.claimed < maxTotal && Date.now() - started < budget) {
    const room = C.platformRoom(sent24, platformCap(env)) - 0;
    if (room <= 0) { out.stopped = "platform_cap"; break; }
    const items = await rpc("email_claim", { p_org: opts.org || null, p_max: Math.min(BATCH, room, maxTotal - out.claimed), p_platform_left: room });
    if (!Array.isArray(items) || !items.length) break;
    out.claimed += items.length;
    let halted = false;
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      if (halted) { await rpc("email_complete", { p_queue: it.queue_id, p_outcome: "retry", p_detail: "http_401", p_message_id: null, p_to: it.to, p_delay_minutes: 120 }); out.retried++; continue; }
      if (!M.addressAllowed(it.to, env)) {
        await rpc("email_complete", { p_queue: it.queue_id, p_outcome: "blocked_preview", p_detail: null, p_message_id: null, p_to: it.to, p_delay_minutes: null });
        out.blocked++; continue;
      }
      let status = 0, resp = null, messageId = null;
      try {
        const built = brevoBody(it, opts.origin, env).body;
        const r = await (opts.fetchImpl || fetch)("https://api.brevo.com/v3/smtp/email", { method: "POST",
          headers: { "api-key": env.BREVO_API_KEY, "content-type": "application/json", accept: "application/json" }, body: JSON.stringify(built) });
        status = r.status; try { resp = await r.json(); } catch (e) { resp = null; }
        messageId = resp && resp.messageId ? String(resp.messageId) : null;
      } catch (e) { status = 0; }
      const c = C.classifyBrevo(status, resp);
      if (c.fatal) {
        await rpc("email_complete", { p_queue: it.queue_id, p_outcome: "retry", p_detail: c.detail, p_message_id: null, p_to: it.to, p_delay_minutes: 120 });
        out.retried++; out.stopped = "brevo_" + status; halted = true; continue;
      }
      await rpc("email_complete", { p_queue: it.queue_id, p_outcome: c.outcome, p_detail: c.detail, p_message_id: messageId, p_to: it.to, p_delay_minutes: c.delayMinutes || null });
      if (c.outcome === "sent") { out.sent++; sent24++; } else if (c.outcome === "retry") out.retried++; else if (c.outcome === "invalid") out.invalid++; else out.failed++;
      if (i < items.length - 1) await (opts.sleep || sleep)(STAGGER_MS);
    }
    if (halted) break;
  }
  return out;
}

module.exports = { configured, platformCap, linkOrigin, rpc, brevoBody, drain, BATCH, serviceKey };
