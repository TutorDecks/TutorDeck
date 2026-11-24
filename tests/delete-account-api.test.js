"use strict";
// api/delete-account.js with Supabase, Stripe, Storage and Google replaced by an in-memory fake (no network, no real keys).
process.env.STRIPE_SECRET_KEY = "sk_test_fake"; process.env.SUPABASE_URL = "https://fake.supabase.test"; process.env.SUPABASE_SERVICE_ROLE_KEY = "service_fake";
const test = require("node:test"), assert = require("node:assert"), { Readable } = require("stream");
const handler = require("../api/delete-account.js");

const UID = "22222222-2222-2222-2222-222222222222", ORG = "11111111-1111-1111-1111-111111111111", OTHER = "33333333-3333-3333-3333-333333333333";
let calls, st, fail;
function reset() {
  calls = []; fail = {};
  st = { org: ORG, members: [{ org_id: ORG }], sub: { status: "active", stripe_customer_id: "cus_1", stripe_subscription_id: "sub_1" },
    files: { receipts: [UID + "/a.png", UID + "/2026/b.png"], materials: [UID + "/m1.pdf"] }, mats: [{ file_path: UID + "/m1.pdf" }, { file_path: "legacy/odd.pdf" }],
    removed: [], dbDeleted: false, loginDeleted: false, billingTables: true };
}
const json = (code, obj) => ({ ok: code < 400, status: code, json: async () => obj, text: async () => (obj === undefined ? "" : JSON.stringify(obj)) });
global.fetch = async (url, opt) => {
  opt = opt || {}; const u = String(url), m = opt.method || "GET"; calls.push(m + " " + u.replace("https://fake.supabase.test", "").replace("https://api.stripe.com/v1", "stripe:"));
  if (u.endsWith("/auth/v1/user")) return String(opt.headers.Authorization).includes("bad") ? json(401, {}) : json(200, { id: UID, email: "t@example.test" });
  if (u.startsWith("https://api.stripe.com/v1/")) {
    if (fail.stripe) return json(fail.stripe, { error: { message: "boom", code: fail.stripe === 404 ? "resource_missing" : "api_error" } });
    return json(200, { deleted: true });
  }
  if (u.endsWith("/rest/v1/rpc/org_personal")) return json(200, st.org);
  if (u.includes("/rest/v1/memberships")) return json(200, st.dbDeleted ? [] : st.members);   // the organisation delete removes its memberships
  if (u.includes("/rest/v1/org_subscriptions")) return st.billingTables ? json(200, st.sub ? [st.sub] : []) : json(404, { code: "PGRST205" });
  if (u.includes("/rest/v1/materials")) return json(200, st.mats);
  if (u.includes("/rest/v1/gcal_links")) return json(200, []);
  if (u.endsWith("/rest/v1/rpc/org_delete_solo")) {
    if (fail.db) return json(fail.db.status, { message: fail.db.message });
    const b = JSON.parse(opt.body); assert.strictEqual(b.p_org, ORG); assert.strictEqual(b.p_user, UID);   // the user comes from the token, never the request
    st.dbDeleted = true; st.org = null; return json(200, { deleted: true });
  }
  let mm = u.match(/\/storage\/v1\/object\/list\/(\w+)/);
  if (mm) {
    const b = JSON.parse(opt.body), all = st.files[mm[1]], here = all.filter((f) => f.startsWith(b.prefix));
    const names = new Map();
    here.forEach((f) => { const rest = f.slice(b.prefix.length), i = rest.indexOf("/"); names.set(i < 0 ? rest : rest.slice(0, i), i < 0 ? "file-id" : null); });
    return json(200, [...names].map(([name, id]) => ({ name, id })).slice(b.offset, b.offset + b.limit));
  }
  mm = u.match(/\/storage\/v1\/object\/(\w+)$/);
  if (mm && m === "DELETE") { if (fail.storage) return json(500, {}); JSON.parse(opt.body).prefixes.forEach((p) => st.removed.push(mm[1] + ":" + p)); return json(200, []); }
  if (u.endsWith("/auth/v1/admin/users/" + UID) && m === "DELETE") { if (fail.login) return json(500, {}); st.loginDeleted = true; return json(200, {}); }
  throw new Error("unexpected fetch " + m + " " + u);
};
function res() { const r = { headers: {}, setHeader(k, v) { r.headers[k] = v; }, end(b) { r.body = b ? JSON.parse(b) : null; } }; return r; }
function post(body, headers) { const req = Readable.from([Buffer.from(JSON.stringify(body))]); req.method = "POST"; req.headers = headers || { authorization: "Bearer jwt" }; const r = res(); return handler(req, r).then(() => r); }
const idx = (re) => calls.findIndex((c) => re.test(c));

test("deletes everything, in order: Stripe → files → database → login", async () => {
  reset();
  const r = await post({ confirm: "DELETE" });
  assert.strictEqual(r.statusCode, 200); assert.deepStrictEqual(r.body, { ok: true });
  assert.ok(st.dbDeleted && st.loginDeleted);
  assert.ok(calls.includes("DELETE stripe:/subscriptions/sub_1") && calls.includes("DELETE stripe:/customers/cus_1"), "subscription cancelled and customer deleted");
  assert.ok(idx(/stripe:\/subscriptions/) < idx(/stripe:\/customers/), "cancel the subscription before deleting the customer");
  assert.ok(idx(/stripe:\/customers/) < idx(/rpc\/org_delete_solo/), "Stripe before the database (the ids are erased with it)");
  assert.ok(idx(/\/storage\/v1\/object\/materials$/) < idx(/rpc\/org_delete_solo/), "files before the database");
  assert.ok(idx(/rpc\/org_delete_solo/) < idx(/admin\/users/), "database before the login (the login holds the organisation link)");
  assert.deepStrictEqual(st.removed.sort(), ["materials:" + UID + "/m1.pdf", "materials:legacy/odd.pdf", "receipts:" + UID + "/2026/b.png", "receipts:" + UID + "/a.png"].sort(),
    "every receipt (incl. in sub-folders) and every material, even one stored outside the tutor's folder");
});

test("signed out, no confirmation, or missing server config: nothing is touched", async () => {
  reset();
  assert.strictEqual((await post({ confirm: "DELETE" }, { authorization: "Bearer bad" })).statusCode, 401);
  assert.strictEqual((await post({})).statusCode, 400);
  assert.strictEqual((await post({ confirm: "delete" })).statusCode, 400, "must be exactly DELETE");
  assert.deepStrictEqual(calls.filter((c) => !c.endsWith("/auth/v1/user")), []);
});

test("someone who also belongs to a tuition centre is refused BEFORE anything irreversible", async () => {
  reset(); st.members.push({ org_id: OTHER });
  const r = await post({ confirm: "DELETE" });
  assert.strictEqual(r.statusCode, 409); assert.strictEqual(r.body.error, "has_other_orgs");
  assert.ok(!calls.some((c) => /stripe|storage|org_delete_solo|admin/.test(c)), "no Stripe, no files, no database, no login");
});

test("Stripe failure stops everything: a subscriber is never deleted while still billed", async () => {
  reset(); fail.stripe = 500;
  const r = await post({ confirm: "DELETE" });
  assert.strictEqual(r.statusCode, 502); assert.strictEqual(r.body.error, "billing_unavailable");
  assert.ok(!st.dbDeleted && !st.loginDeleted && st.removed.length === 0, "nothing deleted");
  fail = {};                                                                            // Stripe back: pressing Delete again works
  assert.strictEqual((await post({ confirm: "DELETE" })).statusCode, 200); assert.ok(st.dbDeleted && st.loginDeleted);
});

test("a Stripe customer that is already gone (404) is fine", async () => {
  reset(); fail.stripe = 404;
  assert.strictEqual((await post({ confirm: "DELETE" })).statusCode, 200); assert.ok(st.dbDeleted);
});

test("subscribed but no Stripe key on the server: refuses rather than skipping the cancellation", async () => {
  reset(); const k = process.env.STRIPE_SECRET_KEY; delete process.env.STRIPE_SECRET_KEY;
  const r = await post({ confirm: "DELETE" }); process.env.STRIPE_SECRET_KEY = k;
  assert.strictEqual(r.statusCode, 503); assert.ok(!st.dbDeleted && !st.loginDeleted);
});

test("never subscribed: no Stripe calls at all, and works without a Stripe key", async () => {
  reset(); st.sub = { status: "none", stripe_customer_id: null, stripe_subscription_id: null }; const k = process.env.STRIPE_SECRET_KEY; delete process.env.STRIPE_SECRET_KEY;
  const r = await post({ confirm: "DELETE" }); process.env.STRIPE_SECRET_KEY = k;
  assert.strictEqual(r.statusCode, 200); assert.ok(!calls.some((c) => /stripe:/.test(c)));
});

test("billing tables not installed yet: still deletes (no subscription can exist)", async () => {
  reset(); st.billingTables = false;
  assert.strictEqual((await post({ confirm: "DELETE" })).statusCode, 200); assert.ok(st.dbDeleted && st.loginDeleted);
});

test("storage failure stops before the database and the login (retry later)", async () => {
  reset(); fail.storage = true;
  const r = await post({ confirm: "DELETE" });
  assert.strictEqual(r.statusCode, 502); assert.ok(!st.dbDeleted && !st.loginDeleted);
});

test("database refusal or failure: the login is kept so they can try again", async () => {
  reset(); fail.db = { status: 400, message: "INCOMPLETE: 3 row(s) in x still point at the organisation" };
  let r = await post({ confirm: "DELETE" });
  assert.strictEqual(r.statusCode, 502); assert.ok(!st.loginDeleted); assert.ok(!JSON.stringify(r.body).includes("INCOMPLETE"), "no internals sent to the browser");
  reset(); fail.db = { status: 404, message: "function not found" };
  r = await post({ confirm: "DELETE" }); assert.strictEqual(r.statusCode, 503); assert.strictEqual(r.body.error, "not_ready"); assert.ok(!st.loginDeleted);
});

test("retry after the database step already succeeded: only the login is left to delete", async () => {
  reset(); fail.login = true;
  assert.strictEqual((await post({ confirm: "DELETE" })).statusCode, 502); assert.ok(st.dbDeleted && !st.loginDeleted);
  fail = {}; calls = [];
  const r = await post({ confirm: "DELETE" });
  assert.strictEqual(r.statusCode, 200); assert.ok(st.loginDeleted);
  assert.ok(!calls.some((c) => /stripe:|storage|org_delete_solo/.test(c)), "nothing is re-done");
});
