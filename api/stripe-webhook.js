// Stripe → TutorDeck webhook. POST https://<host>/api/stripe-webhook  (register this URL in Stripe → Developers → Webhooks)
// Events to send: checkout.session.completed, customer.subscription.created, customer.subscription.updated,
//                 customer.subscription.deleted, invoice.paid, invoice.payment_failed
// Centres on the 'invoice' billing method (org_plans.billing_method) are billed by TutorDeck, not Stripe: an event that resolves to one is
// logged and ignored, never written. Centres on 'stripe' (the default) and solo tutors are handled as before.
// Design: the event only tells us WHICH subscription changed; we then fetch its current state from Stripe and write
// that, so late or out-of-order deliveries can't leave a wrong status. Each event id is processed once.
"use strict";
const L = require("./_gcal-lib");
const B = require("./_billing-lib");
const Core = require("./_billing-core");

async function syncSubscription(subId, orgHint) {
  const sub = await B.stripe("GET", "/subscriptions/" + encodeURIComponent(subId));
  const row = Core.subscriptionRow(sub);
  // which organisation? our own metadata first, then the Stripe customer we saved at checkout
  let q = null;
  const org = orgHint || (sub.metadata && sub.metadata.org_id);
  if (org && /^[0-9a-f-]{36}$/i.test(org)) q = "org_id=eq." + org;
  else if (row.stripe_customer_id) q = "stripe_customer_id=eq." + encodeURIComponent(row.stripe_customer_id);
  if (!q) return "no_org";
  const own = await B.svc("GET", "org_subscriptions?select=org_id,tier&" + q);
  const ownRow = own.ok && own.data && own.data[0];
  if (ownRow && ownRow.tier === "centre") {
    const pl = await B.svc("GET", "org_plans?select=billing_method&plan_code=eq.centre&org_id=eq." + ownRow.org_id + "&order=effective_from.desc&limit=1");
    if (!pl.ok) throw new Error("plan lookup " + pl.status);
    if (pl.data && pl.data[0] && pl.data[0].billing_method === "invoice") {
      console.error("stripe-webhook: ignored subscription " + sub.id + ": the centre is billed by invoice, not Stripe");
      return "ignored_invoice_centre";
    }
  }
  // Never let one subscription overwrite a row that holds a DIFFERENT live one: a late "cancelled" event for an old
  // subscription, or the loser of two checkouts opened at once, must not flip a paying tutor to cancelled. The rule is part
  // of the write itself (one atomic request): allowed when the row has no subscription yet, is this same subscription,
  // or its current subscription is no longer live.
  const guard = "&or=(stripe_subscription_id.is.null,stripe_subscription_id.eq." + encodeURIComponent(sub.id) +
    ",status.in.(" + Core.ENDED_STATUSES.join(",") + "))";
  const w = await B.svc("PATCH", "org_subscriptions?" + q + guard, row, { Prefer: "return=representation" });
  if (!w.ok) throw new Error("write " + w.status);
  if ((w.data || []).length) return "updated";
  const ex = await B.svc("GET", "org_subscriptions?select=org_id&" + q);
  if (ex.ok && (ex.data || []).length) {
    console.error("stripe-webhook: ignored subscription " + sub.id + " (status " + sub.status + "): the organisation already has a different live subscription");
    return "ignored_other_live_subscription";
  }
  return "no_org";
}

module.exports = async function (req, res) {
  if (req.method !== "POST") return L.send(res, 405, { error: "method" });
  if (!B.configured() || !process.env.STRIPE_WEBHOOK_SECRET) return L.send(res, 503, { error: "not_configured" });
  const raw = await B.rawBody(req);
  if (!Core.verifySignature(raw, req.headers["stripe-signature"], process.env.STRIPE_WEBHOOK_SECRET)) return L.send(res, 400, { error: "signature" });
  let ev; try { ev = JSON.parse(raw.toString("utf8")); } catch (e) { return L.send(res, 400, { error: "json" }); }
  if (!ev || !ev.id || !ev.type) return L.send(res, 400, { error: "event" });

  // once per event id; if handling fails we forget the id so Stripe's retry is processed
  const seen = await B.svc("POST", "stripe_events", { id: ev.id, type: ev.type }, { Prefer: "return=minimal" });
  if (seen.status === 409) return L.send(res, 200, { ok: true, duplicate: true });
  if (!seen.ok) return L.send(res, 500, { error: "db" });

  try {
    const o = ev.data && ev.data.object || {};
    let result = "ignored";
    switch (ev.type) {
      case "checkout.session.completed":
        if (o.mode === "subscription" && o.subscription) result = await syncSubscription(typeof o.subscription === "string" ? o.subscription : o.subscription.id, o.client_reference_id);
        break;
      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted":
        if (o.id) result = await syncSubscription(o.id);
        break;
      case "invoice.paid":
      case "invoice.payment_failed": {
        const sid = Core.invoiceSubscriptionId(o);
        if (sid) result = await syncSubscription(sid);
        break;
      }
    }
    return L.send(res, 200, { ok: true, result });
  } catch (e) {
    console.error("stripe-webhook", ev.type, ev.id, e && e.message);
    await B.svc("DELETE", "stripe_events?id=eq." + encodeURIComponent(ev.id), null, { Prefer: "return=minimal" });
    return L.send(res, 500, { error: "retry" });
  }
};
