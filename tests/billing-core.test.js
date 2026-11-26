"use strict";
const test = require("node:test");
const assert = require("node:assert");
const crypto = require("crypto");
const B = require("../api/_billing-core.js");

const SECRET = "whsec_test_not_a_real_secret";
function sign(body, t, secret) {
  return "t=" + t + ",v1=" + crypto.createHmac("sha256", secret || SECRET).update(t + "." + body).digest("hex");
}

test("webhook signature: valid, tampered, wrong secret, old, missing", () => {
  const body = '{"id":"evt_1","type":"customer.subscription.updated"}', now = 1_800_000_000_000, t = String(now / 1000);
  assert.strictEqual(B.verifySignature(body, sign(body, t), SECRET, 300, now), true);
  assert.strictEqual(B.verifySignature(body + " ", sign(body, t), SECRET, 300, now), false, "body changed");
  assert.strictEqual(B.verifySignature(body, sign(body, t, "whsec_other"), SECRET, 300, now), false, "wrong secret");
  assert.strictEqual(B.verifySignature(body, sign(body, String(now / 1000 - 600)), SECRET, 300, now), false, "10 minutes old");
  assert.strictEqual(B.verifySignature(body, "", SECRET, 300, now), false);
  assert.strictEqual(B.verifySignature(body, "t=abc,v1=zz", SECRET, 300, now), false);
  assert.strictEqual(B.verifySignature(body, sign(body, t), "", 300, now), false, "no secret configured");
  assert.strictEqual(B.verifySignature(Buffer.from(body), sign(body, t), SECRET, 300, now), true, "raw Buffer body");
  // two v1 entries (secret rotation): either may match
  assert.strictEqual(B.verifySignature(body, "t=" + t + ",v1=00,v1=" + sign(body, t).split("v1=")[1], SECRET, 300, now), true);
});

test("form encoding of nested Stripe parameters", () => {
  assert.strictEqual(B.form({ mode: "subscription", line_items: [{ price: "price_1", quantity: 1 }], subscription_data: { trial_period_days: 30, metadata: { org_id: "o1" } }, skip: undefined, nul: null }),
    "mode=subscription&line_items%5B0%5D%5Bprice%5D=price_1&line_items%5B0%5D%5Bquantity%5D=1&subscription_data%5Btrial_period_days%5D=30&subscription_data%5Bmetadata%5D%5Borg_id%5D=o1");
});

test("status mapping", () => {
  ["trialing", "active", "past_due", "unpaid"].forEach((s) => assert.strictEqual(B.mapStatus(s), s));
  ["canceled", "incomplete_expired", "paused"].forEach((s) => assert.strictEqual(B.mapStatus(s), "canceled"));
  assert.strictEqual(B.mapStatus("incomplete"), "none");
  assert.strictEqual(B.mapStatus("something_new"), "none");
});

test("subscription row from a Stripe subscription (old and new API shapes)", () => {
  const base = { id: "sub_1", customer: "cus_1", status: "trialing", trial_end: 1_800_000_000, cancel_at_period_end: false, metadata: { org_id: "o1", tier: "pro" } };
  const a = B.subscriptionRow(Object.assign({}, base, { current_period_end: 1_801_000_000, items: { data: [{ price: { lookup_key: "solo_pro_monthly" } }] } }));
  assert.strictEqual(a.status, "trialing"); assert.strictEqual(a.tier, "pro"); assert.strictEqual(a.stripe_customer_id, "cus_1");
  assert.strictEqual(a.current_period_end, new Date(1_801_000_000 * 1000).toISOString());
  const b = B.subscriptionRow(Object.assign({}, base, { metadata: {}, items: { data: [{ current_period_end: 1_802_000_000, price: { lookup_key: "solo_pro_yearly" } }] } }));
  assert.strictEqual(b.tier, "pro", "tier from the price lookup key when metadata is missing");
  assert.strictEqual(b.current_period_end, new Date(1_802_000_000 * 1000).toISOString());
  const c = B.subscriptionRow({ id: "sub_2", customer: { id: "cus_2" }, status: "canceled", items: { data: [{ price: { lookup_key: null } }] }, metadata: {} });
  assert.strictEqual(c.status, "canceled"); assert.strictEqual("tier" in c, false, "unknown price: tier left alone"); assert.strictEqual(c.stripe_customer_id, "cus_2");
  assert.strictEqual(c.trial_end, null);
});

test("invoice → subscription id", () => {
  assert.strictEqual(B.invoiceSubscriptionId({ subscription: "sub_1" }), "sub_1");
  assert.strictEqual(B.invoiceSubscriptionId({ parent: { subscription_details: { subscription: "sub_2" } } }), "sub_2");
  assert.strictEqual(B.invoiceSubscriptionId({ subscription: { id: "sub_3" } }), "sub_3");
  assert.strictEqual(B.invoiceSubscriptionId({}), null);
});

test("only one free trial per organisation", () => {
  assert.strictEqual(B.trialDaysFor(null, 30), 30);
  assert.strictEqual(B.trialDaysFor({ trial_end: null, stripe_subscription_id: null }, 30), 30);
  assert.strictEqual(B.trialDaysFor({ trial_end: "2026-12-01T00:00:00Z", stripe_subscription_id: null }, 30), 0);
  assert.strictEqual(B.trialDaysFor({ trial_end: null, stripe_subscription_id: "sub_1" }, 30), 0);
});

test("cardSummary: keeps only brand, last4, expiry; rejects junk", () => {
  const C = require("../api/_billing-core");
  assert.deepStrictEqual(C.cardSummary({ card: { brand: "visa", last4: "4242", exp_month: 8, exp_year: 2029, fingerprint: "x" } }), { brand: "Visa", last4: "4242", exp_month: 8, exp_year: 2029 });
  assert.strictEqual(C.cardSummary({ card: { brand: "newbrand", last4: "1111", exp_month: 1, exp_year: 2030 } }).brand, "Card");
  assert.strictEqual(C.cardSummary("pm_123"), null);      // un-expanded id
  assert.strictEqual(C.cardSummary(null), null);
  assert.strictEqual(C.cardSummary({ card: { brand: "visa", last4: "12" } }), null);
});
