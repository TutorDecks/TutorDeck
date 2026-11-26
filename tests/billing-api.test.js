"use strict";
// Webhook + checkout handlers with Stripe and Supabase replaced by an in-memory fake (no network, no real keys).
process.env.STRIPE_SECRET_KEY = "sk_test_fake"; process.env.STRIPE_WEBHOOK_SECRET = "whsec_fake";
process.env.SUPABASE_URL = "https://fake.supabase.test"; process.env.SUPABASE_SERVICE_ROLE_KEY = "service_fake";
const test = require("node:test"), assert = require("node:assert"), crypto = require("crypto"), { Readable } = require("stream");
const webhook = require("../api/stripe-webhook.js"), billing = require("../api/billing.js");

const ORG = "11111111-1111-1111-1111-111111111111";
let calls, events, subs, failWrites, orgKind, planMethod;
function reset() {
  calls = []; events = new Set(); failWrites = false; orgKind = "solo"; planMethod = "stripe";
  subs = { [ORG]: { org_id: ORG, tier: "free", status: "none", stripe_customer_id: "cus_1", stripe_subscription_id: null, trial_end: null } };
}
const stripeSub = (o) => Object.assign({ id: "sub_1", customer: "cus_1", status: "trialing", trial_end: 1_900_000_000, cancel_at_period_end: false,
  metadata: { org_id: ORG, tier: "pro" }, items: { data: [{ current_period_end: 1_901_000_000, price: { lookup_key: "solo_pro_monthly" } }] } }, o || {});
let stripeState, stripeCustomer = { invoice_settings: {} }, stripePms = [];
global.fetch = async (url, opt) => {
  opt = opt || {}; const u = String(url); calls.push((opt.method || "GET") + " " + u);
  const json = (code, obj) => ({ ok: code < 400, status: code, json: async () => obj, text: async () => JSON.stringify(obj) });
  if (u.startsWith("https://api.stripe.com/v1/subscriptions/")) return json(200, stripeState);
  if (u.startsWith("https://api.stripe.com/v1/customers/")) return json(200, stripeCustomer);
  if (u.startsWith("https://api.stripe.com/v1/payment_methods")) return json(200, { data: stripePms });
  if (u.startsWith("https://api.stripe.com/v1/prices")) return json(200, { data: [{ id: "price_solo" }] });
  if (u.startsWith("https://api.stripe.com/v1/checkout/sessions")) { subs.__checkoutBody = opt.body; return json(200, { url: "https://checkout.stripe.test/s" }); }
  if (u.startsWith("https://api.stripe.com/v1/billing_portal/sessions")) return json(200, { url: "https://portal.stripe.test/s" });
  if (u.endsWith("/auth/v1/user")) return json(200, { id: "user-1", email: "t@example.test" });
  if (u.includes("/rest/v1/stripe_events")) {
    if (opt.method === "POST") { const id = JSON.parse(opt.body).id; if (events.has(id)) return json(409, {}); events.add(id); return { ok: true, status: 201, text: async () => "" }; }
    if (opt.method === "DELETE") { events.delete(decodeURIComponent(u.split("id=eq.")[1])); return { ok: true, status: 204, text: async () => "" }; }
  }
  if (u.includes("/rest/v1/org_subscriptions")) {
    if (opt.method === "PATCH") {
      if (failWrites) return json(500, {});
      const row = JSON.parse(opt.body), m = u.match(/org_id=eq\.([0-9a-f-]+)/), c = u.match(/stripe_customer_id=eq\.([\w%]+)/);
      // the webhook's "don't overwrite a different live subscription" rule, applied the way PostgREST applies the or=() filter
      const g = u.match(/or=\(stripe_subscription_id\.is\.null,stripe_subscription_id\.eq\.([\w%]+),status\.in\.\(([\w,]+)\)\)/);
      const allowed = (s) => !g || s.stripe_subscription_id == null || s.stripe_subscription_id === decodeURIComponent(g[1]) || g[2].split(",").indexOf(s.status) >= 0;
      const hit = Object.values(subs).filter((s) => s && s.org_id && allowed(s) && ((m && s.org_id === m[1]) || (c && s.stripe_customer_id === decodeURIComponent(c[1]))));
      hit.forEach((s) => Object.assign(s, row));
      return json(200, hit);
    }
    return json(200, Object.values(subs).filter((s) => s && s.org_id));
  }
  if (u.includes("/rest/v1/org_plans")) return json(200, [{ billing_method: planMethod }]);
  if (u.includes("/rest/v1/memberships")) return json(200, [{ id: "m1" }]);
  if (u.includes("/rest/v1/organisations")) return json(200, [{ kind: orgKind, trading_name: "Bright Maths" }]);
  throw new Error("unexpected fetch " + u);
};
function res() { const r = { headers: {}, setHeader(k, v) { r.headers[k] = v; }, end(b) { r.body = b ? JSON.parse(b) : null; } }; return r; }
function post(handler, body, headers) { const req = Readable.from([Buffer.from(typeof body === "string" ? body : JSON.stringify(body))]); req.method = "POST"; req.headers = headers || {}; const r = res(); return handler(req, r).then(() => r); }
function evt(id, type, obj) { return JSON.stringify({ id, type, data: { object: obj } }); }
function signed(body) { const t = String(Math.floor(Date.now() / 1000)); return { "stripe-signature": "t=" + t + ",v1=" + crypto.createHmac("sha256", "whsec_fake").update(t + "." + body).digest("hex") }; }

test("webhook: bad or missing signature is rejected and writes nothing", async () => {
  reset(); stripeState = stripeSub();
  const body = evt("evt_a", "customer.subscription.updated", { id: "sub_1" });
  assert.strictEqual((await post(webhook, body, {})).statusCode, 400);
  assert.strictEqual((await post(webhook, body, { "stripe-signature": "t=1,v1=00" })).statusCode, 400);
  assert.strictEqual(subs[ORG].status, "none"); assert.strictEqual(events.size, 0);
});

test("webhook: subscription.updated writes the CURRENT state fetched from Stripe", async () => {
  reset(); stripeState = stripeSub({ status: "active", trial_end: null });
  const body = evt("evt_b", "customer.subscription.updated", { id: "sub_1" });
  const r = await post(webhook, body, signed(body));
  assert.strictEqual(r.statusCode, 200);
  assert.strictEqual(subs[ORG].status, "active"); assert.strictEqual(subs[ORG].tier, "pro"); assert.strictEqual(subs[ORG].stripe_subscription_id, "sub_1");
});

test("webhook: the same event twice is processed once", async () => {
  reset(); stripeState = stripeSub();
  const body = evt("evt_c", "customer.subscription.created", { id: "sub_1" });
  await post(webhook, body, signed(body));
  const n = calls.filter((c) => c.startsWith("PATCH")).length;
  const r = await post(webhook, body, signed(body));
  assert.strictEqual(r.statusCode, 200); assert.strictEqual(r.body.duplicate, true);
  assert.strictEqual(calls.filter((c) => c.startsWith("PATCH")).length, n, "no second write");
});

test("webhook: a failed write returns 500 and forgets the event so Stripe's retry works", async () => {
  reset(); stripeState = stripeSub(); failWrites = true;
  const body = evt("evt_d", "customer.subscription.updated", { id: "sub_1" });
  const r = await post(webhook, body, signed(body));
  assert.strictEqual(r.statusCode, 500); assert.strictEqual(events.has("evt_d"), false);
  failWrites = false;
  assert.strictEqual((await post(webhook, body, signed(body))).statusCode, 200); assert.strictEqual(subs[ORG].status, "trialing");
});

test("webhook: payment failed → past_due; cancelled → canceled (limit comes back)", async () => {
  reset(); stripeState = stripeSub({ status: "past_due" });
  let body = evt("evt_e", "invoice.payment_failed", { parent: { subscription_details: { subscription: "sub_1" } } });
  await post(webhook, body, signed(body)); assert.strictEqual(subs[ORG].status, "past_due");
  stripeState = stripeSub({ status: "canceled" });
  body = evt("evt_f", "customer.subscription.deleted", { id: "sub_1" });
  await post(webhook, body, signed(body)); assert.strictEqual(subs[ORG].status, "canceled");
});

test("webhook: a late 'cancelled' event for an OLD subscription can't flip a paying tutor", async () => {
  reset(); subs[ORG].stripe_subscription_id = "sub_new"; subs[ORG].tier = "pro"; subs[ORG].status = "active";
  stripeState = stripeSub({ id: "sub_old", status: "canceled" });
  const body = evt("evt_h", "customer.subscription.deleted", { id: "sub_old" });
  const r = await post(webhook, body, signed(body));
  assert.strictEqual(r.statusCode, 200); assert.strictEqual(r.body.result, "ignored_other_live_subscription");
  assert.strictEqual(subs[ORG].status, "active"); assert.strictEqual(subs[ORG].stripe_subscription_id, "sub_new");
});

test("webhook: a second LIVE subscription (two checkouts at once) doesn't replace the first", async () => {
  reset(); subs[ORG].stripe_subscription_id = "sub_first"; subs[ORG].tier = "pro"; subs[ORG].status = "trialing";
  stripeState = stripeSub({ id: "sub_second", status: "active" });
  const body = evt("evt_i", "customer.subscription.created", { id: "sub_second" });
  const r = await post(webhook, body, signed(body));
  assert.strictEqual(r.body.result, "ignored_other_live_subscription");
  assert.strictEqual(subs[ORG].stripe_subscription_id, "sub_first"); assert.strictEqual(subs[ORG].status, "trialing");
});

test("webhook: a NEW subscription replaces one that has ended; updates to the current one still apply", async () => {
  reset(); subs[ORG].stripe_subscription_id = "sub_ended"; subs[ORG].tier = "pro"; subs[ORG].status = "canceled";
  stripeState = stripeSub({ id: "sub_next", status: "active", trial_end: null });
  let body = evt("evt_j", "customer.subscription.created", { id: "sub_next" });
  assert.strictEqual((await post(webhook, body, signed(body))).body.result, "updated");
  assert.strictEqual(subs[ORG].stripe_subscription_id, "sub_next"); assert.strictEqual(subs[ORG].status, "active");
  stripeState = stripeSub({ id: "sub_next", status: "past_due", trial_end: null });
  body = evt("evt_k", "invoice.payment_failed", { subscription: "sub_next" });
  assert.strictEqual((await post(webhook, body, signed(body))).body.result, "updated");
  assert.strictEqual(subs[ORG].status, "past_due", "the current subscription keeps updating");
});

test("webhook: an unrelated event is acknowledged and ignored", async () => {
  reset(); stripeState = stripeSub();
  const body = evt("evt_g", "charge.succeeded", { id: "ch_1" });
  const r = await post(webhook, body, signed(body));
  assert.strictEqual(r.statusCode, 200); assert.strictEqual(r.body.result, "ignored");
});

test("checkout: owner gets a Stripe URL; trial only the first time; centres refused", async () => {
  reset();
  const h = { authorization: "Bearer jwt", host: "tutordeck.vercel.app" };
  let r = await post(billing, { action: "checkout", org_id: ORG, interval: "yearly" }, h);
  assert.strictEqual(r.statusCode, 200); assert.ok(r.body.url.startsWith("https://checkout.stripe.test"));
  assert.ok(decodeURIComponent(subs.__checkoutBody).includes("trial_period_days]=30"), "first checkout has the 30-day trial");
  subs[ORG].trial_end = "2026-12-01T00:00:00Z";
  r = await post(billing, { action: "checkout", org_id: ORG }, h);
  assert.ok(!decodeURIComponent(subs.__checkoutBody).includes("trial_period_days"), "no second trial");
  subs[ORG].tier = "pro"; subs[ORG].status = "active";
  assert.strictEqual((await post(billing, { action: "checkout", org_id: ORG }, h)).statusCode, 409, "already subscribed");
  assert.strictEqual((await post(billing, { action: "portal", org_id: ORG }, h)).body.url.startsWith("https://portal.stripe.test"), true);
});

test("checkout: signed-out, bad org id and wrong host are refused", async () => {
  reset();
  const saved = global.fetch;
  global.fetch = async (u, o) => String(u).endsWith("/auth/v1/user") ? { ok: false, status: 401, json: async () => ({}), text: async () => "" } : saved(u, o);
  assert.strictEqual((await post(billing, { action: "checkout", org_id: ORG }, { authorization: "Bearer bad", host: "tutordeck.vercel.app" })).statusCode, 401);
  global.fetch = saved;
  assert.strictEqual((await post(billing, { action: "checkout", org_id: "x" }, { authorization: "Bearer jwt", host: "tutordeck.vercel.app" })).statusCode, 400);
  assert.strictEqual((await post(billing, { action: "checkout", org_id: ORG }, { authorization: "Bearer jwt", host: "evil.example.com" })).statusCode, 400);
});

// ---- T31a: a centre's billing method ('stripe' default | 'invoice') -------------------------------------------------------------
const stripeCalls = () => calls.filter((c) => c.indexOf("api.stripe.com") >= 0);
const HH = { authorization: "Bearer jwt", host: "tutordeck.vercel.app" };
test("invoice centre: every action except status is refused with 'contact us'; Stripe and the subscription row are never touched", async () => {
  for (const action of ["checkout", "portal", "card", "trial", "start_trial", "change_plan", "anything"]) {
    reset(); orgKind = "centre"; planMethod = "invoice"; subs[ORG].tier = "centre"; subs[ORG].stripe_customer_id = "cus_1";
    const r = await post(billing, { action, org_id: ORG, interval: "yearly" }, HH);
    assert.strictEqual(r.statusCode, 403, action); assert.strictEqual(r.body.error, "centre_invoice", action);
    assert.strictEqual(r.body.contact, require("../assets/js/contact.js").EMAIL); assert.ok(/invoice and PayNow/.test(r.body.message));
    assert.strictEqual(stripeCalls().length, 0, action + " must not call Stripe");
    assert.ok(!calls.some((c) => /org_subscriptions/.test(c)), action + " must not read the subscription row");
  }
});
test("stripe centre (the default): billing works as before — portal and card reach Stripe, checkout is still solo-only", async () => {
  reset(); orgKind = "centre"; planMethod = "stripe"; subs[ORG].tier = "centre";
  assert.strictEqual((await post(billing, { action: "portal", org_id: ORG }, HH)).body.url.startsWith("https://portal.stripe.test"), true);
  assert.strictEqual((await post(billing, { action: "card", org_id: ORG }, HH)).statusCode, 200);
  assert.ok(stripeCalls().length > 0, "a stripe centre still reaches Stripe");
  const r = await post(billing, { action: "checkout", org_id: ORG }, HH); assert.strictEqual(r.statusCode, 400); assert.strictEqual(r.body.error, "solo_only");
});
test("an invoice centre can still read its status", async () => {
  reset(); orgKind = "centre"; planMethod = "invoice";
  const saved = global.fetch;
  global.fetch = async (u, o) => String(u).includes("rpc/org_plan_status") ? { ok: true, status: 200, json: async () => ({ tier: "centre" }), text: async () => "{}" } : saved(u, o);
  try { assert.strictEqual((await post(billing, { action: "status", org_id: ORG }, HH)).statusCode, 200); } finally { global.fetch = saved; }
});
test("a failed plan lookup for a centre doesn't guess: generic 502, no Stripe call", async () => {
  reset(); orgKind = "centre"; subs[ORG].tier = "centre";
  const saved = global.fetch;
  global.fetch = async (u, o) => String(u).includes("/rest/v1/org_plans") ? { ok: false, status: 500, json: async () => ({}), text: async () => "" } : saved(u, o);
  try { const r = await post(billing, { action: "portal", org_id: ORG }, HH); assert.strictEqual(r.statusCode, 502); assert.strictEqual(stripeCalls().length, 0); } finally { global.fetch = saved; }
});
test("webhook: an event for an INVOICE centre is acknowledged and writes nothing; a stripe centre is handled as before", async () => {
  reset(); stripeState = stripeSub(); subs[ORG].tier = "centre"; planMethod = "invoice";
  let body = evt("evt_inv", "customer.subscription.updated", { id: "sub_1" });
  let r = await post(webhook, body, signed(body));
  assert.strictEqual(r.statusCode, 200); assert.strictEqual(r.body.result, "ignored_invoice_centre");
  assert.strictEqual(subs[ORG].status, "none"); assert.ok(!calls.some((c) => c.startsWith("PATCH")), "nothing written");
  reset(); stripeState = stripeSub(); subs[ORG].tier = "centre"; planMethod = "stripe";
  body = evt("evt_str", "customer.subscription.updated", { id: "sub_1" });
  r = await post(webhook, body, signed(body));
  assert.strictEqual(r.body.result, "updated"); assert.strictEqual(subs[ORG].status, "trialing");
});

const pm = (o) => ({ id: "pm_1", type: "card", card: Object.assign({ brand: "visa", last4: "4242", exp_month: 8, exp_year: 2029, fingerprint: "SECRET", number: "4242424242424242" }, o || {}) });
const H = { authorization: "Bearer jwt", host: "tutordeck.vercel.app" };

test("card: customer default card → brand, last4, expiry only (nothing else leaks)", async () => {
  reset(); stripeCustomer = { invoice_settings: { default_payment_method: pm() } }; stripePms = [];
  const r = await post(billing, { action: "card", org_id: ORG }, H);
  assert.strictEqual(r.statusCode, 200);
  assert.deepStrictEqual(r.body, { card: { brand: "Visa", last4: "4242", exp_month: 8, exp_year: 2029 } });
  assert.ok(!JSON.stringify(r.body).includes("SECRET") && !JSON.stringify(r.body).includes("4242424242424242"));
});

test("card: falls back to the subscription's card, then to any saved card", async () => {
  reset(); stripeCustomer = { invoice_settings: { default_payment_method: null } };
  subs[ORG].stripe_subscription_id = "sub_1"; stripeState = stripeSub({ default_payment_method: pm({ brand: "mastercard", last4: "4444" }) });
  assert.strictEqual((await post(billing, { action: "card", org_id: ORG }, H)).body.card.last4, "4444");
  stripeState = stripeSub({ default_payment_method: null }); stripePms = [pm({ brand: "amex", last4: "0005" })];
  const r = await post(billing, { action: "card", org_id: ORG }, H);
  assert.strictEqual(r.body.card.brand, "American Express"); assert.strictEqual(r.body.card.last4, "0005");
  stripePms = [];
});

test("card: no card on file (trial without card) → { card: null }; no Stripe customer yet → null without calling Stripe", async () => {
  reset(); stripeCustomer = { invoice_settings: {} }; stripePms = [];
  assert.deepStrictEqual((await post(billing, { action: "card", org_id: ORG }, H)).body, { card: null });
  subs[ORG].stripe_customer_id = null; calls.length = 0;
  assert.deepStrictEqual((await post(billing, { action: "card", org_id: ORG }, H)).body, { card: null });
  assert.ok(!calls.some((c) => c.includes("api.stripe.com")));
});

test("card: signed-out refused; Stripe failure gives a generic 502", async () => {
  reset();
  const saved = global.fetch;
  global.fetch = async (u, o) => String(u).endsWith("/auth/v1/user") ? { ok: false, status: 401, json: async () => ({}), text: async () => "" } : saved(u, o);
  assert.strictEqual((await post(billing, { action: "card", org_id: ORG }, H)).statusCode, 401);
  global.fetch = async (u, o) => String(u).includes("api.stripe.com") ? { ok: false, status: 500, json: async () => ({ error: { message: "internal secret detail" } }), text: async () => "" } : saved(u, o);
  const r = await post(billing, { action: "card", org_id: ORG }, H);
  assert.strictEqual(r.statusCode, 502); assert.ok(!JSON.stringify(r.body).includes("secret detail"));
  global.fetch = saved;
});
