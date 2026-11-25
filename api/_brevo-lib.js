// Brevo (transactional email) helpers for TutorDeck's own emails. Files starting with "_" are not routes on Vercel.
// Used by api/send-invite.js; the invoice and reminder emails planned later should reuse it.
//
// Secrets live ONLY in Vercel → Settings → Environment Variables (never in this public repo, never in logs):
//   BREVO_API_KEY       Brevo → SMTP & API → API keys. Production = the live key, Preview = a separate DEV key (same variable name).
// Non-secret settings (also Vercel env vars):
//   INVITE_TEST_ALLOW   Preview only: extra addresses a Preview deploy may email, comma separated. An entry is a full address
//                       ("me@gmail.com") or a whole domain written with a leading @ ("@example.com"). @tutordeck.com.sg is always allowed.
//   BREVO_INVITE_TEMPLATE_ID   optional: id of an invite template made in Brevo (params: name, centre, role, inviter, link, expiry).
//                       Without it the invite is built from the plain wording in buildInviteEmail() below (same words as docs/orchestrator/t7/).
// The sender ADDRESS and the reply-to are fixed in code; the browser can never choose them. Only the display name varies
// ("Alpha Tuition via TutorDeck").
"use strict";

const SENDER_EMAIL = "noreply@tutordeck.com.sg";
const REPLY_TO = { email: "tutordeckadmin@gmail.com", name: "TutorDeck" };   // reply-to for launch (owner's decision 2026-11-25)
const TEAM_DOMAIN = "tutordeck.com.sg";
const LINK_HOURS = 24;                                                          // set in Supabase: Authentication → Emails → "Email OTP expiration"

const isProduction = () => process.env.VERCEL_ENV === "production";
const configured = () => !!process.env.BREVO_API_KEY;

function esc(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }

// A person's or centre's name is shown in an email header: keep letters, digits and ordinary punctuation only, never anything
// that could break the header or pretend to be an address.
function cleanName(s, fallback) {
  const t = String(s == null ? "" : s).replace(/[\u0000-\u001f\u007f<>"@\;:,]/g, " ").replace(/\s+/g, " ").trim().slice(0, 60);
  return t || fallback;
}

// "Alpha Tuition via TutorDeck" (the address stays noreply@tutordeck.com.sg)
function senderFor(centre) {
  const c = cleanName(centre, "");
  return { name: c ? c + " via TutorDeck" : "TutorDeck", email: SENDER_EMAIL };
}

// Preview / local deploys may only email our own domain and an explicit allow-list, so a demo invite can never reach a real person.
function addressAllowed(email, env) {
  env = env || process.env;
  if (env.VERCEL_ENV === "production") return true;
  const e = String(email || "").trim().toLowerCase();
  const m = /^[^\s@<>,;]+@([^\s@<>,;]+)$/.exec(e);
  if (!m) return false;
  if (m[1] === TEAM_DOMAIN) return true;
  return String(env.INVITE_TEST_ALLOW || "").toLowerCase().split(/[,\s]+/).filter(Boolean).some((a) => a === e || (a.charAt(0) === "@" && a.slice(1) === m[1]));
}

const ROLE_WORDS = { tutor: "tutor", staff: "staff admin", owner: "owner" };

// The invite, in plain words. Never any student, fee or lesson detail. `link` is the one-time set-your-password link.
function buildInviteEmail(o) {
  const centre = cleanName(o.centre, "your centre"), inviter = cleanName(o.inviter, centre), name = cleanName(o.name, "there");
  const role = ROLE_WORDS[o.role] || "member of the team";
  const subject = inviter + " invited you to " + centre + " on TutorDeck";
  const intro = inviter + " has added you as a " + role + " at " + centre + ". Tap the button to choose a password and see your lessons.";
  const small = "This link works once and expires in " + LINK_HOURS + " hours. If it has expired, ask " + inviter + " to send it again. Not expecting this? You can ignore this email.";
  const foot = "You are getting this because " + inviter + " entered your email address on TutorDeck. TutorDeck Pte. Ltd., Singapore.";
  const html = '<!doctype html><html><body style="margin:0;background:#FAF9F6;font-family:Manrope,Arial,Helvetica,sans-serif;color:#13233F">' +
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:28px 16px">' +
    '<table role="presentation" width="520" cellpadding="0" cellspacing="0" style="max-width:520px;width:100%;background:#ffffff;border:1px solid #E8E5DE;border-radius:12px">' +
    '<tr><td style="padding:28px 28px 8px;font-size:20px;font-weight:800;color:#13233F">TutorDeck</td></tr>' +
    '<tr><td style="padding:8px 28px 0;font-size:16px;line-height:1.5">Hi ' + esc(name) + ",<br><br>" + esc(intro) + "</td></tr>" +
    '<tr><td style="padding:22px 28px"><a href="' + esc(o.link) + '" style="display:inline-block;background:#0F766E;color:#ffffff;text-decoration:none;font-weight:700;padding:13px 22px;border-radius:10px;font-size:15px">Set my password</a></td></tr>' +
    '<tr><td style="padding:0 28px 8px;font-size:13px;line-height:1.5;color:#5B6678">' + esc(small) + "</td></tr>" +
    '<tr><td style="padding:12px 28px 26px;font-size:12px;line-height:1.5;color:#5B6678">' + esc(foot) + "</td></tr>" +
    "</table></td></tr></table></body></html>";
  const text = "Hi " + name + ",\n\n" + intro + "\n\nSet my password: " + o.link + "\n\n" + small + "\n\n" + foot + "\n";
  return { subject, html, text };
}

// The exact body sent to POST https://api.brevo.com/v3/smtp/email (pure, so tests can inspect it; contains the link, never log it).
function inviteBody(o, env) {
  env = env || process.env;
  const base = { sender: senderFor(o.centre), replyTo: REPLY_TO, to: [{ email: String(o.to).trim().toLowerCase(), name: cleanName(o.name, undefined) }],
    tags: ["invite"] };
  if (!base.to[0].name) delete base.to[0].name;
  const tid = parseInt(env.BREVO_INVITE_TEMPLATE_ID, 10);
  if (tid > 0) {
    return Object.assign(base, { templateId: tid, params: { name: cleanName(o.name, "there"), centre: cleanName(o.centre, "your centre"),
      role: ROLE_WORDS[o.role] || "member of the team", inviter: cleanName(o.inviter, "your centre"), link: o.link, expiry: LINK_HOURS + " hours" } });
  }
  const m = buildInviteEmail(o);
  return Object.assign(base, { subject: m.subject, htmlContent: m.html, textContent: m.text });
}

// Send one transactional email. Returns { ok, status, messageId }. Throws { code: "not_configured" } without a key.
// `fetchImpl` is for tests (no network). The key is read at call time and never returned or logged.
async function send(body, fetchImpl, env) {
  env = env || process.env;
  if (!env.BREVO_API_KEY) { const e = new Error("BREVO_API_KEY missing"); e.code = "not_configured"; throw e; }
  const r = await (fetchImpl || fetch)("https://api.brevo.com/v3/smtp/email", { method: "POST",
    headers: { "api-key": env.BREVO_API_KEY, "content-type": "application/json", accept: "application/json" }, body: JSON.stringify(body) });
  let d = null; try { d = await r.json(); } catch (e) {}
  return { ok: !!r.ok, status: r.status, messageId: (d && d.messageId) || null };
}

module.exports = { SENDER_EMAIL, REPLY_TO, LINK_HOURS, isProduction, configured, cleanName, senderFor, addressAllowed, buildInviteEmail, inviteBody, send };
