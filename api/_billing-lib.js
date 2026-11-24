// Shared helpers for TutorDeck's own Stripe billing (api/billing.js, api/stripe-webhook.js).
// Files starting with "_" are not routes on Vercel.
//
// Secrets live ONLY in Vercel → Settings → Environment Variables (never in this public repo):
//   STRIPE_SECRET_KEY          sk_test_… while testing (sandbox), sk_live_… in production
//   STRIPE_WEBHOOK_SECRET      whsec_… shown once when the webhook endpoint is created in Stripe
//   SUPABASE_SERVICE_ROLE_KEY  lets this server write org_subscriptions (bypasses row-level security — server only!)
//   SUPABASE_URL               REQUIRED here (no default), so a Preview deploy can never write to the wrong database
// Prices are looked up by lookup_key (solo_pro_monthly, solo_pro_yearly), so no price ids are stored anywhere.
"use strict";
const Core = require("./_billing-core");

const SUPABASE_URL = process.env.SUPABASE_URL || "";
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || "";
const STRIPE_KEY = process.env.STRIPE_SECRET_KEY || "";
const TRIAL_DAYS = 30;

// Already paying or in a trial? (a past_due account keeps access until Stripe gives up and cancels)
function hasLiveSubscription(sub) { return !!sub && sub.tier === "pro" && ["trialing", "active", "past_due"].indexOf(sub.status) >= 0; }

function configured() { return !!(SUPABASE_URL && SERVICE_KEY && STRIPE_KEY); }

async function stripe(method, path, params) {
  const body = params ? Core.form(params) : null;
  const url = "https://api.stripe.com/v1" + path + (method === "GET" && body ? "?" + body : "");
  const r = await fetch(url, { method, headers: Object.assign({ Authorization: "Bearer " + STRIPE_KEY },
    method === "GET" ? {} : { "Content-Type": "application/x-www-form-urlencoded" }), body: method === "GET" ? undefined : body });
  const d = await r.json().catch(() => ({}));
  if (!r.ok) { const e = new Error((d.error && d.error.message) || "Stripe " + r.status); e.status = r.status; e.stripe = d.error; throw e; }
  return d;
}

// Postgres via REST with the SERVICE key. Only used for org_subscriptions / stripe_events, after the caller was checked.
async function svc(method, path, body, extra) {
  const r = await fetch(SUPABASE_URL + "/rest/v1/" + path, { method,
    headers: Object.assign({ apikey: SERVICE_KEY, Authorization: "Bearer " + SERVICE_KEY, "Content-Type": "application/json" }, extra || {}),
    body: body ? JSON.stringify(body) : undefined });
  const t = await r.text();
  let d = null; try { d = t ? JSON.parse(t) : null; } catch (e) {}
  return { ok: r.ok, status: r.status, data: d };
}

// The raw request bytes (the signature is over the exact bytes Stripe sent, so don't let anything parse them first).
async function rawBody(req) {
  const chunks = [];
  for await (const c of req) chunks.push(typeof c === "string" ? Buffer.from(c) : c);
  if (chunks.length) return Buffer.concat(chunks);
  if (Buffer.isBuffer(req.body)) return req.body;
  if (typeof req.body === "string") return Buffer.from(req.body);
  return Buffer.alloc(0);
}

module.exports = { TRIAL_DAYS, hasLiveSubscription, configured, stripe, svc, rawBody, SUPABASE_URL };
