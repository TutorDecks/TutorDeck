"use strict";
// The monthly job's endpoint with Stripe and Supabase replaced by an in-memory fake (no network, no real keys).
process.env.STRIPE_SECRET_KEY = "sk_test_fake"; process.env.STRIPE_WEBHOOK_SECRET = "whsec_fake";
process.env.SUPABASE_URL = "https://fake.supabase.test"; process.env.SUPABASE_SERVICE_ROLE_KEY = "service_fake";
process.env.CRON_SECRET = "cron_secret_0123456789abcdef";
const test = require("node:test"), assert = require("node:assert");
const job = require("../api/billing-cron.js"), J = require("../api/_billing-job-core.js");

const ORG = "11111111-1111-1111-1111-111111111111", ORG2 = "22222222-2222-2222-2222-222222222222";
const MONTH = J.sgMonthStart(), COUNTED = J.prevMonthStart(MONTH);
let st, writes;
function reset(o) {
  writes = [];
  st = Object.assign({
    orgs: [{ id: ORG }], snapshots: [], active: { [ORG]: 403 },
    plans: { [ORG]: [{ plan_code: "centre", base_cents: 10000, per_student_cents: 40, effective_from: "2026-10-01" }] },
    subs: { [ORG]: "sub_1" }, qty: { sub_1: 100 }, failStripePost: false }, o || {});
}
const stripeSub = (id) => ({ id, status: "active", currency: "sgd", items: { data: [
  { id: "si_base", quantity: 1, current_period_start: st.periodStart, price: { lookup_key: "centre_base_monthly", unit_amount: 10000 } },
  { id: "si_stu", quantity: st.qty[id], current_period_start: st.periodStart, price: { lookup_key: "centre_student_monthly", unit_amount: 40 } }] } });
global.fetch = async (url, opt) => {
  opt = opt || {}; const u = String(url), method = opt.method || "GET";
  const json = (code, obj) => ({ ok: code < 400, status: code, json: async () => obj, text: async () => JSON.stringify(obj) });
  if (u.includes("/rest/v1/organisations")) return json(200, st.orgs);
  if (u.includes("/rest/v1/platform_fee_snapshots")) {
    if (method === "POST") { writes.push(["snapshot", JSON.parse(opt.body)]); return { ok: true, status: 201, text: async () => "" }; }
    return json(200, st.snapshots.map((org_id) => ({ org_id })));
  }
  const org = (u.match(/org_id=eq\.([0-9a-f-]+)/) || [])[1];
  if (u.includes("/rest/v1/org_plans")) return json(200, st.plans[org] || []);
  if (u.includes("/rest/v1/org_subscriptions")) return json(200, st.subs[org] ? [{ stripe_subscription_id: st.subs[org] }] : [{ stripe_subscription_id: null }]);
  if (u.includes("/rest/v1/rpc/org_active_students_in_month")) { const b = JSON.parse(opt.body); writes.push(["count", b]); return json(200, st.active[b.p_org]); }
  if (u.startsWith("https://api.stripe.com/v1/subscriptions/")) {
    const id = u.split("/subscriptions/")[1];
    if (method === "POST") { if (st.failStripePost) return json(500, { error: { message: "boom" } }); writes.push(["stripe", opt.body]); st.qty[id] = Number(/items%5B0%5D%5Bquantity%5D=(\d+)/.exec(opt.body)[1]); return json(200, stripeSub(id)); }
    return json(200, stripeSub(id));
  }
  throw new Error("unexpected fetch " + u);
};
function res() { const r = { setHeader() {}, end(b) { r.body = b ? JSON.parse(b) : null; } }; return r; }
async function run(path, auth) { const r = res(); await job({ method: "GET", url: path, headers: auth === undefined ? { authorization: "Bearer " + process.env.CRON_SECRET } : (auth ? { authorization: auth } : {}) }, r); return r; }

test("refuses without the cron secret", async () => {
  reset();
  assert.strictEqual((await run("/api/billing-cron", null)).statusCode, 401);
  assert.strictEqual((await run("/api/billing-cron", "Bearer wrong_secret_0123456789abcdef")).statusCode, 401);
  assert.strictEqual(writes.length, 0);
});
test("real run: counts last month, updates Stripe, writes the snapshot last", async () => {
  reset();
  const r = await run("/api/billing-cron");
  assert.strictEqual(r.statusCode, 200); assert.strictEqual(r.body.month, MONTH); assert.strictEqual(r.body.counted_month, COUNTED);
  assert.deepStrictEqual(r.body.centres[0], { org_id: ORG, active: 403, billable: 400, fee_cents: 26000, quantity_before: 100, result: "updated" });
  assert.deepStrictEqual(writes.map((w) => w[0]), ["count", "stripe", "snapshot"], "snapshot is the last write");
  assert.strictEqual(writes[0][1].p_month, COUNTED);
  assert.strictEqual(st.qty.sub_1, 400);
  assert.ok(decodeURIComponent(writes[1][1]).includes("proration_behavior=none"));
  assert.deepStrictEqual(writes[2][1], { org_id: ORG, month: MONTH, active_students: 403, billable_students: 400, base_cents: 10000, per_student_cents: 40, fee_cents: 26000 });
});
test("running again after success does nothing", async () => {
  reset({ snapshots: [ORG] });
  const r = await run("/api/billing-cron");
  assert.strictEqual(r.body.centres[0].result, "already_done"); assert.strictEqual(writes.length, 0);
});
test("dry run touches nothing, and can look at another month", async () => {
  reset();
  let r = await run("/api/billing-cron?dry=1");
  assert.strictEqual(r.body.centres[0].result, "dry:would_update"); assert.strictEqual(r.body.centres[0].fee_cents, 26000);
  assert.deepStrictEqual(writes.map((w) => w[0]), ["count"]); assert.strictEqual(st.qty.sub_1, 100);
  r = await run("/api/billing-cron?dry=1&month=2027-03"); assert.strictEqual(r.body.month, "2027-03-01"); assert.strictEqual(r.body.counted_month, "2027-02-01");
  assert.strictEqual((await run("/api/billing-cron?month=2027-03")).statusCode, 400, "a real run can't be pointed at another month");
  assert.strictEqual((await run("/api/billing-cron?dry=1&month=2027-3")).statusCode, 400);
});
test("quantity already right: no Stripe write, snapshot still recorded", async () => {
  reset({ qty: { sub_1: 400 } });
  const r = await run("/api/billing-cron");
  assert.strictEqual(r.body.centres[0].result, "already_correct"); assert.deepStrictEqual(writes.map((w) => w[0]), ["count", "snapshot"]);
});
test("Stripe failure: no snapshot (so tomorrow retries), job reports failure, other centres still processed", async () => {
  reset({ orgs: [{ id: ORG }, { id: ORG2 }], active: { [ORG]: 403, [ORG2]: 50 }, plans: { [ORG]: [{ plan_code: "centre", base_cents: 10000, per_student_cents: 40, effective_from: "2026-10-01" }], [ORG2]: [{ plan_code: "centre", base_cents: 10000, per_student_cents: 40, effective_from: "2026-10-01" }] },
    subs: { [ORG]: "sub_1", [ORG2]: "sub_2" }, qty: { sub_1: 100, sub_2: 50 }, failStripePost: true });
  const r = await run("/api/billing-cron");
  assert.strictEqual(r.statusCode, 500); assert.strictEqual(r.body.failed, 1);
  assert.strictEqual(r.body.centres[0].result, "error");
  assert.strictEqual(r.body.centres[1].result, "already_correct", "centre 2 (50 → 50) needed no write");
  assert.strictEqual(writes.filter((w) => w[0] === "snapshot").length, 1, "only the centre that succeeded got a snapshot");
});
test("skips centres with no subscription yet, and flags a price mismatch as a failure", async () => {
  reset({ subs: {} });
  let r = await run("/api/billing-cron"); assert.strictEqual(r.statusCode, 200); assert.strictEqual(r.body.centres[0].result, "skipped:no_subscription");
  reset({ plans: { [ORG]: [{ plan_code: "centre", base_cents: 10000, per_student_cents: 30, effective_from: "2026-10-01" }] } });
  r = await run("/api/billing-cron"); assert.strictEqual(r.statusCode, 500); assert.strictEqual(r.body.centres[0].result, "skipped:price_mismatch");
  assert.ok(!writes.some((w) => w[0] === "stripe" || w[0] === "snapshot"));
});

test("renewal already invoiced this month: no Stripe write, no snapshot, flagged as a failure", async () => {
  reset({ periodStart: Math.floor(Date.now() / 1000) });        // the billing period started just now = this month
  const r = await run("/api/billing-cron");
  assert.strictEqual(r.statusCode, 500); assert.strictEqual(r.body.failed, 1);
  assert.strictEqual(r.body.centres[0].result, "skipped:renewal_already_billed");
  assert.ok(!writes.some((w) => w[0] === "stripe" || w[0] === "snapshot"));
  assert.strictEqual(st.qty.sub_1, 100, "quantity untouched");
  reset({ periodStart: Math.floor(Date.now() / 1000) - 40 * 86400 });   // period began 40 days ago: normal
  assert.strictEqual((await run("/api/billing-cron")).statusCode, 200);
});
