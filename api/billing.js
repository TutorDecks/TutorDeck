// TutorDeck's own billing — one endpoint, POST { action, org_id } with the TutorDeck (Supabase) access token in
// "Authorization: Bearer …". Only the organisation's OWNER may use it.
//   checkout → { url }  Stripe Checkout for Solo Pro (monthly | yearly), 30-day free trial, no card needed to start
//   portal   → { url }  Stripe's customer portal: change card, switch monthly/yearly, cancel
//   card     → { card: {brand,last4,exp_month,exp_year} | null }  the card on file, read live from Stripe (owner only)
//   status   → the Plan screen's numbers (active students, limit, trial end…)
// A centre has TWO billing methods (org_plans.billing_method): 'stripe' (default, self-serve, as before) and 'invoice' (managed: TutorDeck
// invoices it and it pays by PayNow, set by a platform admin when the centre contacts us). For an 'invoice' centre every action except
// "status" answers 403 "centre_invoice" (contact us) before any Stripe or subscription lookup.
// Subscription state is written ONLY by api/stripe-webhook.js, never from here or from the browser.
"use strict";
const L = require("./_gcal-lib");       // getUser, db (as the user, row-level security applies), origin, send, readBody
const B = require("./_billing-lib");
const Core = require("./_billing-core");
const Contact = require("../assets/js/contact.js");   // the one contact-address constant

const PRICE_KEYS = { monthly: "solo_pro_monthly", yearly: "solo_pro_yearly" };

module.exports = async function (req, res) {
  if (req.method !== "POST") return L.send(res, 405, { error: "method" });
  if (!B.configured()) return L.send(res, 503, { error: "not_configured" });
  const jwt = String(req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  const user = await L.getUser(jwt);
  if (!user) return L.send(res, 401, { error: "signed_out" });
  const b = await L.readBody(req);
  const orgId = String(b.org_id || "");
  if (!/^[0-9a-f-]{36}$/i.test(orgId)) return L.send(res, 400, { error: "org" });

  try {
    if (b.action === "status") {
      const r = await L.db(jwt, "POST", "rpc/org_plan_status", { p_org: orgId });
      return r.ok ? L.send(res, 200, r.data) : L.send(res, r.status === 400 ? 403 : r.status, { error: "forbidden" });
    }

    // owner of an organisation (row-level security: you can only see your own membership rows)
    const own = await L.db(jwt, "GET", "memberships?select=id&org_id=eq." + orgId + "&user_id=eq." + user.id + "&role=eq.owner&status=eq.active");
    if (!own.ok || !(own.data || []).length) return L.send(res, 403, { error: "owner_only" });
    const org = await L.db(jwt, "GET", "organisations?select=kind,trading_name&id=eq." + orgId);
    const kind = org.ok && org.data && org.data[0] && org.data[0].kind;
    if (kind === "centre") {
      const pl = await B.svc("GET", "org_plans?select=billing_method&org_id=eq." + orgId + "&plan_code=eq.centre&effective_from=lte." + new Date().toISOString().slice(0, 10) + "&order=effective_from.desc&limit=1");
      if (!pl.ok) throw new Error("plan lookup " + pl.status);                       // can't tell the method → don't guess
      if (pl.data && pl.data[0] && pl.data[0].billing_method === "invoice")
        return L.send(res, 403, { error: "centre_invoice", contact: Contact.EMAIL, message: "Billing for your centre is by invoice and PayNow. Contact us if you want to change this." });
    }
    const origin = L.origin(req);
    if (!origin) return L.send(res, 400, { error: "host" });

    const cur = await B.svc("GET", "org_subscriptions?select=*&org_id=eq." + orgId);
    const sub = cur.ok && cur.data && cur.data[0];
    if (!sub) return L.send(res, 404, { error: "no_subscription_row" });

    // one Stripe customer per organisation; the e-mail is only for Stripe's receipts
    async function customerId() {
      if (sub.stripe_customer_id) return sub.stripe_customer_id;
      const c = await B.stripe("POST", "/customers", { email: user.email, name: org.data[0].trading_name, metadata: { org_id: orgId } });
      const w = await B.svc("PATCH", "org_subscriptions?org_id=eq." + orgId + "&stripe_customer_id=is.null", { stripe_customer_id: c.id, updated_at: new Date().toISOString() }, { Prefer: "return=minimal" });
      if (!w.ok) throw new Error("could not save customer");
      return c.id;
    }

    if (b.action === "checkout") {
      if (kind !== "solo") return L.send(res, 400, { error: "solo_only" });      // centres are set up with the TutorDeck team
      if (B.hasLiveSubscription(sub)) return L.send(res, 409, { error: "already_subscribed" });
      const key = PRICE_KEYS[b.interval === "yearly" ? "yearly" : "monthly"];
      const prices = await B.stripe("GET", "/prices", { lookup_keys: [key], active: "true", limit: 1 });
      const price = prices.data && prices.data[0];
      if (!price) return L.send(res, 500, { error: "price_missing" });
      const trial = Core.trialDaysFor(sub, B.TRIAL_DAYS);
      const sess = await B.stripe("POST", "/checkout/sessions", {
        mode: "subscription", customer: await customerId(), client_reference_id: orgId,
        line_items: [{ price: price.id, quantity: 1 }],
        payment_method_collection: "if_required",
        subscription_data: Object.assign({ metadata: { org_id: orgId, tier: "pro" } },
          trial ? { trial_period_days: trial, trial_settings: { end_behavior: { missing_payment_method: "cancel" } } } : {}),
        success_url: origin + "/settings?billing=success", cancel_url: origin + "/settings?billing=cancel",
        allow_promotion_codes: "true"
      });
      return L.send(res, 200, { url: sess.url });
    }

    // The card on file, in plain facts only (brand, last 4, expiry), read live from Stripe so it matches the customer portal.
    // Order: the customer's default for invoices → the subscription's own default → any card saved on the customer.
    if (b.action === "card") {
      if (!sub.stripe_customer_id) return L.send(res, 200, { card: null });
      const cus = await B.stripe("GET", "/customers/" + encodeURIComponent(sub.stripe_customer_id), { expand: ["invoice_settings.default_payment_method"] });
      let card = Core.cardSummary(cus.invoice_settings && cus.invoice_settings.default_payment_method);
      if (!card && sub.stripe_subscription_id) {
        const s = await B.stripe("GET", "/subscriptions/" + encodeURIComponent(sub.stripe_subscription_id), { expand: ["default_payment_method"] });
        card = Core.cardSummary(s.default_payment_method);
      }
      if (!card) {
        const l = await B.stripe("GET", "/payment_methods", { customer: sub.stripe_customer_id, type: "card", limit: 1 });
        card = Core.cardSummary(l.data && l.data[0]);
      }
      return L.send(res, 200, { card });
    }

    if (b.action === "portal") {
      if (!sub.stripe_customer_id) return L.send(res, 404, { error: "no_customer" });
      const p = await B.stripe("POST", "/billing_portal/sessions", { customer: sub.stripe_customer_id, return_url: origin + "/settings" });
      return L.send(res, 200, { url: p.url });
    }
    return L.send(res, 400, { error: "action" });
  } catch (e) {
    // never echo Stripe or database internals to the browser
    console.error("billing", b.action, e && e.message);
    return L.send(res, 502, { error: "billing_unavailable" });
  }
};
