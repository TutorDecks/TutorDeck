"use strict";
// The monthly job's endpoint with Supabase replaced by an in-memory fake (no network, no real keys). No Stripe key is set and any Stripe call fails the test:
// centres are invoiced by TutorDeck, so the job must never talk to Stripe (T31a).
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
    orgs: [{ id: ORG }], snapshots: [], active: { [ORG]: 403 }, failSnapshot: [],
    plans: { [ORG]: [{ plan_code: "centre", base_cents: 10000, per_student_cents: 50, effective_from: "2026-10-01" }] } }, o || {});
}
global.fetch = async (url, opt) => {
  opt = opt || {}; const u = String(url), method = opt.method || "GET";
  const json = (code, obj) => ({ ok: code < 400, status: code, json: async () => obj, text: async () => JSON.stringify(obj) });
  if (u.includes("stripe.com")) throw new Error("the monthly job must never call Stripe: " + u);
  if (u.includes("/org_subscriptions")) throw new Error("the monthly job no longer needs a subscription row");
  if (u.includes("/rest/v1/organisations")) return json(200, st.orgs);
  if (u.includes("/rest/v1/platform_fee_snapshots")) {
    if (method === "POST") {
      const b = JSON.parse(opt.body);
      if (st.failSnapshot.indexOf(b.org_id) >= 0) return json(500, {});
      writes.push(["snapshot", b]); return { ok: true, status: 201, text: async () => "" };
    }
    return json(200, st.snapshots.map((org_id) => ({ org_id })));
  }
  const org = (u.match(/org_id=eq\.([0-9a-f-]+)/) || [])[1];
  if (u.includes("/rest/v1/org_plans")) return json(200, st.plans[org] || []);
  if (u.includes("/rest/v1/rpc/org_active_students_in_month")) { const b = JSON.parse(opt.body); writes.push(["count", b]); return json(200, st.active[b.p_org]); }
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
test("real run: counts last month, records the snapshot last, never touches Stripe", async () => {
  reset();
  const r = await run("/api/billing-cron");
  assert.strictEqual(r.statusCode, 200); assert.strictEqual(r.body.month, MONTH); assert.strictEqual(r.body.counted_month, COUNTED);
  assert.deepStrictEqual(r.body.centres[0], { org_id: ORG, active: 403, billable: 400, fee_cents: 30000, result: "recorded" });
  assert.deepStrictEqual(writes.map((w) => w[0]), ["count", "snapshot"], "snapshot is the last write");
  assert.strictEqual(writes[0][1].p_month, COUNTED);
  assert.deepStrictEqual(writes[1][1], { org_id: ORG, month: MONTH, active_students: 403, billable_students: 400, base_cents: 10000, per_student_cents: 50, fee_cents: 30000 });
});
test("needs no Stripe key and no centre subscription row (a centre with none is still recorded)", async () => {
  reset();
  assert.strictEqual(process.env.STRIPE_SECRET_KEY, undefined);
  assert.strictEqual((await run("/api/billing-cron")).body.centres[0].result, "recorded");
});
test("running again after success does nothing (a closed month is never recomputed)", async () => {
  reset({ snapshots: [ORG] });
  const r = await run("/api/billing-cron");
  assert.strictEqual(r.body.centres[0].result, "already_done"); assert.strictEqual(writes.length, 0);
});
test("a duplicate snapshot (409) is treated as already done", async () => {
  reset();
  const real = global.fetch;
  global.fetch = async (u, o) => (String(u).includes("platform_fee_snapshots") && o && o.method === "POST" ? { ok: false, status: 409, text: async () => "" } : real(u, o));
  try { const r = await run("/api/billing-cron"); assert.strictEqual(r.statusCode, 200); assert.strictEqual(r.body.centres[0].result, "recorded"); }
  finally { global.fetch = real; }
});
test("dry run records nothing, and can look at another month", async () => {
  reset();
  let r = await run("/api/billing-cron?dry=1");
  assert.strictEqual(r.body.centres[0].result, "dry:would_record"); assert.strictEqual(r.body.centres[0].fee_cents, 30000);
  assert.deepStrictEqual(writes.map((w) => w[0]), ["count"]);
  r = await run("/api/billing-cron?dry=1&month=2027-03"); assert.strictEqual(r.body.month, "2027-03-01"); assert.strictEqual(r.body.counted_month, "2027-02-01");
  assert.strictEqual((await run("/api/billing-cron?month=2027-03")).statusCode, 400, "a real run can't be pointed at another month");
  assert.strictEqual((await run("/api/billing-cron?dry=1&month=2027-3")).statusCode, 400);
});
test("a failed snapshot write: job reports failure, nothing recorded for that centre, other centres still processed", async () => {
  const P = [{ plan_code: "centre", base_cents: 10000, per_student_cents: 50, effective_from: "2026-10-01" }];
  reset({ orgs: [{ id: ORG }, { id: ORG2 }], active: { [ORG]: 403, [ORG2]: 50 }, plans: { [ORG]: P, [ORG2]: P }, failSnapshot: [ORG] });
  const r = await run("/api/billing-cron");
  assert.strictEqual(r.statusCode, 500); assert.strictEqual(r.body.failed, 1);
  assert.strictEqual(r.body.centres[0].result, "error"); assert.strictEqual(r.body.centres[1].result, "recorded");
  assert.deepStrictEqual(writes.filter((w) => w[0] === "snapshot").map((w) => w[1].org_id), [ORG2]);
});
test("a centre with no centre plan is skipped quietly (not a failure)", async () => {
  reset({ plans: {} });
  const r = await run("/api/billing-cron"); assert.strictEqual(r.statusCode, 200); assert.strictEqual(r.body.centres[0].result, "skipped:no_centre_plan");
  assert.ok(!writes.some((w) => w[0] === "snapshot"));
});
test("an old price mismatch can no longer happen: a custom plan is simply recorded at its own price", async () => {
  reset({ plans: { [ORG]: [{ plan_code: "centre", base_cents: 9000, per_student_cents: 30, effective_from: "2026-10-01" }] } });
  const r = await run("/api/billing-cron");
  assert.strictEqual(r.statusCode, 200); assert.strictEqual(r.body.centres[0].fee_cents, 9000 + 400 * 30);
});
