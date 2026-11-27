"use strict";
// The credit-expiry endpoint with Supabase replaced by an in-memory fake (no network, no real keys). The expiry rules themselves are proven in the database
// (tests/sql/makeup_credits_test.sql: the last day is still usable, the day after it expires, booked / revoked credits are never touched, twice is safe).
process.env.SUPABASE_URL = "https://fake.supabase.test"; process.env.SUPABASE_SERVICE_ROLE_KEY = "service_fake";
process.env.CRON_SECRET = "cron_secret_0123456789abcdef";
const test = require("node:test"), assert = require("node:assert");
const job = require("../api/credits-cron.js");
const fs = require("fs");

let calls, open;
function reset(o) { calls = []; open = o === undefined ? 3 : o; }
global.fetch = async (url, opt) => {
  opt = opt || {}; const u = String(url), method = opt.method || "GET";
  calls.push([method, u.replace("https://fake.supabase.test/rest/v1/", ""), opt.body ? JSON.parse(opt.body) : null, (opt.headers || {}).Authorization]);
  const json = (code, obj) => ({ ok: code < 400, status: code, json: async () => obj, text: async () => JSON.stringify(obj) });
  if (u.includes("/rest/v1/makeup_credits")) return json(200, Array.from({ length: open }, (_, i) => ({ id: "c" + i })));
  if (u.includes("/rest/v1/rpc/credits_expire_due")) { const n = open; open = 0; return json(200, n); }
  throw new Error("unexpected fetch " + u);
};
function res() { const r = { setHeader() {}, end(b) { r.body = b ? JSON.parse(b) : null; } }; return r; }
async function run(path, auth, method) {
  const r = res();
  await job({ method: method || "GET", url: path, headers: auth === undefined ? { authorization: "Bearer " + process.env.CRON_SECRET } : (auth ? { authorization: auth } : {}) }, r);
  return r;
}

test("refuses without the cron secret, and with the wrong one", async () => {
  reset();
  assert.strictEqual((await run("/api/credits-cron", null)).statusCode, 401);
  assert.strictEqual((await run("/api/credits-cron", "Bearer wrong_secret_0123456789abcdef")).statusCode, 401);
  assert.strictEqual((await run("/api/credits-cron", "Bearer " + process.env.CRON_SECRET + "x")).statusCode, 401);
  assert.strictEqual(calls.length, 0, "nothing is read or written for a refused caller");
});
test("only GET and POST", async () => { reset(); assert.strictEqual((await run("/api/credits-cron", undefined, "DELETE")).statusCode, 405); assert.strictEqual(calls.length, 0); });
test("a real run calls the database function with today in Singapore, once, and reports a count", async () => {
  reset(3);
  const r = await run("/api/credits-cron");
  assert.strictEqual(r.statusCode, 200);
  assert.deepStrictEqual(r.body, { day: job.sgToday(), dry: false, expired: 3 });
  assert.strictEqual(calls.length, 1); assert.deepStrictEqual(calls[0].slice(0, 3), ["POST", "rpc/credits_expire_due", { p_today: job.sgToday() }]);
  assert.match(calls[0][3], /^Bearer service_fake$/, "it uses the service key, never a person's login");
  const again = await run("/api/credits-cron"); assert.strictEqual(again.body.expired, 0, "running it again changes nothing");
});
test("a dry run only reads and counts", async () => {
  reset(2);
  const r = await run("/api/credits-cron?dry=1");
  assert.strictEqual(r.statusCode, 200); assert.deepStrictEqual(r.body, { day: job.sgToday(), dry: true, would_expire: 2 });
  assert.ok(calls.every((c) => c[0] === "GET"), "no write");
  assert.match(calls[0][1], /status=eq\.open&expires_on=lt\./);
});
test("the output has counts only: no names, ids or reasons", async () => {
  reset(2);
  for (const p of ["/api/credits-cron", "/api/credits-cron?dry=1"]) assert.doesNotMatch(JSON.stringify((await run(p)).body), /student|reason|"c\d/);
});
test("a database failure is a plain 500 with no details", async () => {
  reset(1); const real = global.fetch; global.fetch = async () => ({ ok: false, status: 500, text: async () => "secret details", json: async () => ({}) });
  const r = await run("/api/credits-cron"); global.fetch = real;
  assert.strictEqual(r.statusCode, 500); assert.deepStrictEqual(r.body, { error: "failed" });
});
test("not configured: 503, and it is NOT scheduled by this change", () => {
  const cfg = JSON.parse(fs.readFileSync(require.resolve("../vercel.json"), "utf8"));
  assert.ok(!JSON.stringify(cfg.crons || []).includes("credits-cron"), "vercel.json has no cron entry for credits-cron (the orchestrator adds it)");
});
