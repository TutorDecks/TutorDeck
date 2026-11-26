// Pure helpers for TutorDeck's own Stripe billing (no network, no secrets) — unit-tested in tests/billing-core.test.js.
// Files starting with "_" are not routes on Vercel.
"use strict";
const crypto = require("crypto");

// Stripe webhook signature: header "t=<unix>,v1=<hex>[,v1=<hex>…]"; signed payload is "<t>.<raw body>" (HMAC-SHA256).
// Rejects old timestamps (replay) and compares in constant time. `now` is injectable for tests.
function verifySignature(rawBody, header, secret, toleranceSec, now) {
  if (!rawBody || !header || !secret) return false;
  const tol = toleranceSec == null ? 300 : toleranceSec;
  const parts = String(header).split(",").map((p) => p.split("="));
  const t = (parts.find((p) => p[0] === "t") || [])[1];
  const sigs = parts.filter((p) => p[0] === "v1").map((p) => p[1]).filter(Boolean);
  if (!t || !/^\d+$/.test(t) || !sigs.length) return false;
  const ts = (now == null ? Date.now() : now) / 1000;
  if (Math.abs(ts - Number(t)) > tol) return false;
  const expected = crypto.createHmac("sha256", secret).update(t + "." + (Buffer.isBuffer(rawBody) ? rawBody.toString("utf8") : rawBody)).digest("hex");
  const eb = Buffer.from(expected, "hex");
  return sigs.some((s) => {
    const sb = Buffer.from(s, "hex");
    return sb.length === eb.length && crypto.timingSafeEqual(sb, eb);
  });
}

// application/x-www-form-urlencoded the way Stripe wants nested values: a[b]=1, items[0][price]=x
function formEncode(obj, prefix, out) {
  out = out || [];
  Object.keys(obj || {}).forEach((k) => {
    const v = obj[k];
    if (v === undefined || v === null) return;
    const key = prefix ? prefix + "[" + k + "]" : k;
    if (v !== null && typeof v === "object") formEncode(v, key, out);
    else out.push(encodeURIComponent(key) + "=" + encodeURIComponent(String(v)));
  });
  return out;
}
function form(obj) { return formEncode(obj).join("&"); }

// Stripe subscription status → the values allowed by org_subscriptions.status
function mapStatus(s) {
  switch (s) {
    case "trialing": case "active": case "past_due": case "unpaid": return s;
    case "canceled": case "incomplete_expired": case "paused": return "canceled";
    default: return "none";                 // incomplete: first payment not done yet
  }
}

// Stripe statuses where a subscription still exists and may charge (used to protect a live subscription from being overwritten).
const LIVE_STATUSES = ["trialing", "active", "past_due", "unpaid"];
// …and the others (the column only allows these six): a row in one of these may be replaced by a different subscription.
const ENDED_STATUSES = ["none", "canceled"];

const iso = (sec) => (sec ? new Date(sec * 1000).toISOString() : null);

// The org_subscriptions columns to write for a Stripe subscription object (current state, fetched from Stripe).
// tier: from our own metadata first, then the price's lookup key.
function subscriptionRow(sub) {
  const item = sub && sub.items && sub.items.data && sub.items.data[0];
  const key = (item && item.price && item.price.lookup_key) || "";
  const tier = (sub.metadata && sub.metadata.tier) || (/^solo_pro/.test(key) ? "pro" : /^centre/.test(key) ? "centre" : null);
  const row = {
    status: mapStatus(sub.status),
    stripe_subscription_id: sub.id,
    trial_end: iso(sub.trial_end),
    // newer API versions keep the period on the item, older ones on the subscription
    current_period_end: iso((item && item.current_period_end) || sub.current_period_end),
    cancel_at_period_end: !!sub.cancel_at_period_end,
    updated_at: new Date().toISOString()
  };
  if (tier) row.tier = tier;
  if (typeof sub.customer === "string") row.stripe_customer_id = sub.customer;
  else if (sub.customer && sub.customer.id) row.stripe_customer_id = sub.customer.id;
  return row;
}

// The subscription id an invoice belongs to (both the old and the new Stripe API shapes).
function invoiceSubscriptionId(inv) {
  const id = inv && (inv.subscription || (inv.parent && inv.parent.subscription_details && inv.parent.subscription_details.subscription));
  return typeof id === "string" ? id : (id && id.id) || null;
}

// A tutor who already had a trial or subscription doesn't get a second free trial.
function trialDaysFor(subRow, days) {
  if (subRow && (subRow.trial_end || subRow.stripe_subscription_id)) return 0;
  return days;
}

// Stripe PaymentMethod → the ONLY card facts the browser ever gets: brand, last4, expiry (never the full number; Stripe doesn't send it).
const BRANDS = { visa: "Visa", mastercard: "Mastercard", amex: "American Express", discover: "Discover", diners: "Diners Club", jcb: "JCB", unionpay: "UnionPay", cartes_bancaires: "Cartes Bancaires", eftpos_au: "EFTPOS" };
function cardSummary(pm) {
  const c = pm && typeof pm === "object" && pm.card;
  if (!c || !/^\d{4}$/.test(String(c.last4 || ""))) return null;
  const m = Number(c.exp_month), y = Number(c.exp_year);
  return { brand: BRANDS[c.brand] || "Card", last4: String(c.last4), exp_month: m >= 1 && m <= 12 ? m : null, exp_year: y > 2000 ? y : null };
}

module.exports = { cardSummary, LIVE_STATUSES, ENDED_STATUSES, verifySignature, form, formEncode, mapStatus, subscriptionRow, invoiceSubscriptionId, trialDaysFor };
