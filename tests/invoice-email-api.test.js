"use strict";
// Family emails, server side: api/_email-run.js (drain), api/email-send.js, api/email-cron.js and api/brevo-webhook.js with Supabase and Brevo replaced by an in-memory
// fake (no network, no real keys, no real email). Run: node --test tests/*.test.js
process.env.SUPABASE_URL = "https://fake.supabase.test"; process.env.SUPABASE_SERVICE_ROLE_KEY = "service_fake_key_for_tests";
const test = require("node:test"), assert = require("node:assert"), { Readable } = require("stream");
const R = require("../api/_email-run.js"), send = require("../api/email-send.js"), cron = require("../api/email-cron.js"), hook = require("../api/brevo-webhook.js");

const KEY = "xkeysib-FAKE-KEY-FOR-TESTS", CRON = "cron-secret-0123456789abcdef", HOOK = "hook-secret-0123456789abcdef";
const ORG = "11111111-1111-1111-1111-111111111111";
let calls, claims, status, sent24, brevo, rpcFail, activeOrgs;
function reset() {
  calls = []; claims = []; sent24 = 0; brevo = () => ({ status: 201, body: { messageId: "<m-" + calls.length + "@brevo>" } }); rpcFail = {}; activeOrgs = [{ org_id: ORG }];
  status = { mode: "staff_send", queued: 2, sent_today: 0, daily_cap: 200, sends_over_days: 1 };
  process.env.BREVO_API_KEY = KEY; process.env.CRON_SECRET = CRON; process.env.BREVO_WEBHOOK_SECRET = HOOK; delete process.env.VERCEL_ENV; delete process.env.INVITE_TEST_ALLOW; delete process.env.EMAIL_PLATFORM_DAILY_CAP; delete process.env.EMAIL_LINK_ORIGIN;
}
const item = (n, over) => Object.assign({ queue_id: "00000000-0000-0000-0000-00000000000" + n, org_id: ORG, kind: "invoice", attempt: 1, to: "parent" + n + "@tutordeck.com.sg", name: "Mrs Tan", centre: "Alpha Tuition",
  reply_to: "office@alpha.test", templates: {}, vars: { number: "INV-" + n, amount_cents: 10000, total_cents: 10000, due_date: "2026-12-07", days_overdue: 0, token: "aaaaaaaa-bbbb-cccc-dddd-00000000000" + n } }, over || {});
const json = (code, obj) => ({ ok: code < 400, status: code, json: async () => obj, text: async () => (obj == null ? "" : JSON.stringify(obj)) });
global.fetch = async (url, opt) => {
  opt = opt || {}; const u = String(url), body = opt.body ? JSON.parse(opt.body) : null;
  calls.push({ m: opt.method || "GET", u, body, headers: opt.headers || {} });
  if (u.endsWith("/auth/v1/user")) return opt.headers.Authorization === "Bearer good" ? json(200, { id: "user-1" }) : json(401, {});
  const m = /\/rest\/v1\/rpc\/([a-z_0-9]+)$/.exec(u);
  if (m) {
    const name = m[1];
    if (rpcFail[name]) return json(rpcFail[name], { code: "x" });
    if (name === "email_queue_status") return opt.headers.Authorization === "Bearer good" ? json(200, status) : json(403, {});
    if (name === "email_platform_sent_24h") return json(200, sent24);
    if (name === "email_claim") return json(200, claims.length ? claims.shift() : []);
    if (name === "email_complete") return json(200, true);
    if (name === "email_plan_reminders") return json(200, body.p_dry ? 3 : 2);
    if (name === "email_active_orgs") return json(200, activeOrgs);
    if (name === "email_mark_bounce") return json(200, body.p_message_id.length > 5);
    throw new Error("unexpected rpc " + name);
  }
  if (u === "https://api.brevo.com/v3/smtp/email") { const b = brevo(body); return json(b.status, b.body); }
  throw new Error("unexpected fetch " + u);
};
const noSleep = async () => {};
const rpcs = (name) => calls.filter((c) => c.u.endsWith("/rpc/" + name));
const brevoCalls = () => calls.filter((c) => c.u === "https://api.brevo.com/v3/smtp/email");
const completes = () => rpcs("email_complete").map((c) => c.body);
function res() { const r = { headers: {}, setHeader(k, v) { r.headers[k] = v; }, end(b) { r.body = b ? JSON.parse(b) : null; r.raw = b || ""; } }; return r; }
function call(handler, method, body, headers, url) {
  const req = Readable.from([Buffer.from(JSON.stringify(body || {}))]); req.method = method; req.url = url || "/";
  req.headers = Object.assign({ authorization: "Bearer good", host: "tutordeck.vercel.app" }, headers || {}); const r = res(); return handler(req, r).then(() => r);
}
function captureLogs(fn) {
  const out = [], l = console.log, e = console.error; console.log = (...a) => out.push(a.join(" ")); console.error = (...a) => out.push(a.join(" "));
  return fn().then((r) => { console.log = l; console.error = e; return { r, out: out.join("\n") }; }, (x) => { console.log = l; console.error = e; throw x; });
}
const PROD = { BREVO_API_KEY: KEY, VERCEL_ENV: "production" };

// ---------------------------------------------------------------- the message that goes to Brevo
test("brevo body: our sender address, the centre in the display name, the centre's reply-to, the secure link on our address, no key", () => {
  reset();
  const { body } = R.brevoBody(item(1), "https://www.tutordeck.com.sg");
  assert.deepStrictEqual(body.sender, { name: "Alpha Tuition via TutorDeck", email: "noreply@tutordeck.com.sg" });
  assert.deepStrictEqual(body.replyTo, { email: "office@alpha.test", name: "Alpha Tuition" });
  assert.deepStrictEqual(body.to, [{ email: "parent1@tutordeck.com.sg" }]);
  assert.strictEqual(body.subject, "Invoice INV-1 from Alpha Tuition");
  assert.ok(body.textContent.includes("https://www.tutordeck.com.sg/pay?t=aaaaaaaa-bbbb-cccc-dddd-000000000001") && body.htmlContent.includes("/pay?t=aaaaaaaa"));
  assert.ok(/no unsubscribe link/.test(body.textContent) && body.textContent.includes("office@alpha.test"), "a transactional footer with the centre's contact");
  assert.ok(!JSON.stringify(body).includes(KEY) && !JSON.stringify(body).includes("api-key"));
});
test("brevo body: no centre address → the platform's own reply-to; a bad one is ignored; a hostile centre name can't change the sender address", () => {
  reset();
  assert.deepStrictEqual(R.brevoBody(item(1, { reply_to: null }), "https://x.tutordeck.com.sg").body.replyTo, { email: "tutordeckadmin@gmail.com", name: "TutorDeck" });
  assert.deepStrictEqual(R.brevoBody(item(1, { reply_to: "not an address" }), "https://x").body.replyTo, { email: "tutordeckadmin@gmail.com", name: "TutorDeck" });
  const b = R.brevoBody(item(1, { centre: 'Evil" <boss@evil.com>;', name: "<script>" }), "https://x").body;
  assert.strictEqual(b.sender.email, "noreply@tutordeck.com.sg"); assert.ok(!/[<>"@;]/.test(b.sender.name));
  assert.ok(!b.htmlContent.includes("<script>"));
});
test("the link address: our own host only", () => {
  reset();
  assert.strictEqual(R.linkOrigin({ headers: { host: "tutordeck.vercel.app" } }, {}), "https://tutordeck.vercel.app");
  assert.strictEqual(R.linkOrigin({ headers: { host: "evil.example.com" } }, {}), null, "an unknown host is refused");
  assert.strictEqual(R.linkOrigin(null, { VERCEL_ENV: "production" }), "https://tutordeck.vercel.app", "the daily job has no host: the live address");
  assert.strictEqual(R.linkOrigin(null, {}), null);
  assert.strictEqual(R.linkOrigin({ headers: { host: "tutordeck.vercel.app" } }, { EMAIL_LINK_ORIGIN: "https://www.tutordeck.com.sg/" }), "https://www.tutordeck.com.sg");
  assert.strictEqual(R.linkOrigin({ headers: { host: "tutordeck.vercel.app" } }, { EMAIL_LINK_ORIGIN: "https://evil.example.com" }), "https://tutordeck.vercel.app", "a setting for a foreign host is ignored");
});

// ---------------------------------------------------------------- draining the queue
test("drain: each claimed message is sent once and reported once, with Brevo's id and the address only in the call to the database", async () => {
  reset(); claims.push([item(1), item(2)]);
  const o = await R.drain({ origin: "https://tutordeck.vercel.app", env: PROD, sleep: noSleep });
  assert.deepStrictEqual([o.claimed, o.sent, o.retried, o.failed, o.invalid, o.blocked], [2, 2, 0, 0, 0, 0]);
  assert.strictEqual(brevoCalls().length, 2);
  assert.strictEqual(brevoCalls()[0].headers["api-key"], KEY);
  const c = completes(); assert.strictEqual(c.length, 2);
  assert.deepStrictEqual(c.map((x) => x.p_outcome), ["sent", "sent"]); assert.ok(c.every((x) => /^<m-\d+@brevo>$/.test(x.p_message_id) && x.p_queue && x.p_to));
});
test("drain: nothing claimed means nothing sent; the platform's count is read first", async () => {
  reset();
  const o = await R.drain({ origin: "https://x", env: PROD, sleep: noSleep });
  assert.strictEqual(o.claimed, 0); assert.strictEqual(brevoCalls().length, 0); assert.strictEqual(rpcs("email_platform_sent_24h").length, 1);
});
test("drain: the platform cap (Brevo's free day) is passed down as the room left, and at zero nothing is claimed", async () => {
  reset(); sent24 = 240; claims.push([item(1)]);
  await R.drain({ env: PROD, sleep: noSleep });
  assert.strictEqual(rpcs("email_claim")[0].body.p_platform_left, 10); assert.ok(rpcs("email_claim")[0].body.p_max <= 10);
  reset(); sent24 = 250; claims.push([item(1)]);
  const o = await R.drain({ env: PROD, sleep: noSleep });
  assert.strictEqual(rpcs("email_claim").length, 0); assert.strictEqual(o.stopped, "platform_cap"); assert.strictEqual(brevoCalls().length, 0);
  reset(); sent24 = 250; process.env.EMAIL_PLATFORM_DAILY_CAP = "300"; claims.push([item(1)]);
  const o2 = await R.drain({ env: Object.assign({ EMAIL_PLATFORM_DAILY_CAP: "300" }, PROD), sleep: noSleep });
  assert.strictEqual(o2.sent, 1, "the cap can be raised to Brevo's real limit (a paid plan) with EMAIL_PLATFORM_DAILY_CAP, but never above 300");
  assert.strictEqual(R.platformCap({ EMAIL_PLATFORM_DAILY_CAP: "5000" }), 250); assert.strictEqual(R.platformCap({ EMAIL_PLATFORM_DAILY_CAP: "abc" }), 250); assert.strictEqual(R.platformCap({ EMAIL_PLATFORM_DAILY_CAP: "40" }), 40);
});
test("drain: the platform count grows as it sends, so one run can't pass the cap", async () => {
  reset(); sent24 = 248; claims.push([item(1), item(2), item(3)]); claims.push([item(4)]);
  const o = await R.drain({ env: PROD, sleep: noSleep });
  assert.ok(o.sent <= 3 && brevoCalls().length <= 3, "sent " + o.sent);
});
test("preview rule: a preview or local run never emails a real person (only @tutordeck.com.sg and the allow-list)", async () => {
  reset(); claims.push([item(1, { to: "real.parent@gmail.com" }), item(2), item(3, { to: "me@gmail.com" })]);
  const env = { BREVO_API_KEY: KEY, VERCEL_ENV: "preview", INVITE_TEST_ALLOW: "me@gmail.com" };
  const o = await R.drain({ env, sleep: noSleep });
  assert.deepStrictEqual([o.sent, o.blocked], [2, 1]);
  assert.deepStrictEqual(brevoCalls().map((c) => c.body.to[0].email), ["parent2@tutordeck.com.sg", "me@gmail.com"]);
  assert.deepStrictEqual(completes().map((x) => x.p_outcome), ["blocked_preview", "sent", "sent"]);
  reset(); claims.push([item(1, { to: "real.parent@gmail.com" })]);
  const o2 = await R.drain({ env: { BREVO_API_KEY: KEY }, sleep: noSleep });   // no VERCEL_ENV at all = a local run
  assert.strictEqual(o2.blocked, 1); assert.strictEqual(brevoCalls().length, 0);
  reset(); claims.push([item(1, { to: "real.parent@gmail.com" })]);
  const o3 = await R.drain({ env: PROD, sleep: noSleep });
  assert.strictEqual(o3.sent, 1, "production sends to anyone");
});
test("drain: what Brevo answers decides what is recorded (retry, invalid address, refused, rate limit)", async () => {
  reset(); claims.push([item(1), item(2), item(3), item(4), item(5)]);
  const answers = [{ status: 503, body: {} }, { status: 400, body: { code: "invalid_parameter", message: "email is not valid" } }, { status: 400, body: { message: "bad template" } }, { status: 429, body: {} }, { status: 201, body: { messageId: "<ok>" } }];
  let i = 0; brevo = () => answers[i++];
  const o = await R.drain({ env: PROD, sleep: noSleep });
  assert.deepStrictEqual([o.sent, o.retried, o.failed, o.invalid], [1, 2, 1, 1]);
  const c = completes();
  assert.deepStrictEqual(c.map((x) => x.p_outcome), ["retry", "invalid", "failed", "retry", "sent"]);
  assert.strictEqual(c[0].p_detail, "http_503"); assert.strictEqual(c[0].p_delay_minutes, null, "the database chooses 15 minutes, then an hour, then 6 hours");
  assert.strictEqual(c[3].p_delay_minutes, 720, "a rate limit waits 12 hours");
});
test("drain: a network error is a retry, never a crash", async () => {
  reset(); claims.push([item(1)]);
  const real = global.fetch; global.fetch = async (u, o) => { if (String(u).startsWith("https://api.brevo.com")) throw new Error("socket hang up"); return real(u, o); };
  try { const o = await R.drain({ env: PROD, sleep: noSleep }); assert.strictEqual(o.retried, 1); assert.strictEqual(completes()[0].p_detail, "network"); } finally { global.fetch = real; }
});
test("drain: Brevo refusing our key stops the run at once; the rest of the batch is put back for two hours, nothing is marked bad", async () => {
  reset(); claims.push([item(1), item(2), item(3)]); claims.push([item(4)]);
  brevo = () => ({ status: 401, body: { message: "Key not found" } });
  const o = await R.drain({ env: PROD, sleep: noSleep });
  assert.strictEqual(brevoCalls().length, 1, "only one try, then stop"); assert.strictEqual(o.sent, 0); assert.strictEqual(o.retried, 3); assert.strictEqual(o.stopped, "brevo_401");
  assert.ok(completes().every((x) => x.p_outcome === "retry" && x.p_delay_minutes === 120), "all back in two hours");
  assert.strictEqual(rpcs("email_claim").length, 1, "no further batches");
});
test("drain: stays inside its batch size and its total", async () => {
  reset(); for (let b = 0; b < 5; b++) claims.push(Array.from({ length: 10 }, (_, i) => item(b * 10 + i + 1)));
  const o = await R.drain({ env: PROD, sleep: noSleep, max: 25 });
  assert.ok(o.claimed <= 30 && o.sent <= 30); assert.ok(rpcs("email_claim").every((c) => c.body.p_max <= 10));
  assert.ok(rpcs("email_claim")[rpcs("email_claim").length - 1].body.p_max <= 5, "the last batch is only what is left of the total");
});
test("drain: a failing database call is raised, not swallowed (the message stays 'sending' and the database retries it after 15 minutes)", async () => {
  reset(); claims.push([item(1)]); rpcFail.email_complete = 500;
  await assert.rejects(() => R.drain({ env: PROD, sleep: noSleep }), /rpc email_complete 500/);
});

// ---------------------------------------------------------------- POST /api/email-send
test("email-send: not configured → 503 and nothing is called; wrong method → 405", async () => {
  reset(); delete process.env.BREVO_API_KEY;
  assert.strictEqual((await call(send, "POST", { org_id: ORG })).statusCode, 503); assert.strictEqual(calls.length, 0);
  reset(); assert.strictEqual((await call(send, "GET", {})).statusCode, 405);
});
test("email-send: signed out → 401; a bad org id → 400; an unknown host → 400", async () => {
  reset();
  assert.strictEqual((await call(send, "POST", { org_id: ORG }, { authorization: "Bearer bad" })).statusCode, 401);
  assert.strictEqual((await call(send, "POST", { org_id: "nope" })).statusCode, 400);
  assert.strictEqual((await call(send, "POST", { org_id: ORG }, { host: "evil.example.com" })).statusCode, 400);
  assert.strictEqual(rpcs("email_claim").length, 0);
});
test("email-send: someone the database refuses (a tutor, a parent, another centre, a solo tutor) gets 404 and nothing is sent", async () => {
  reset(); rpcFail.email_queue_status = 400;
  const r = await call(send, "POST", { org_id: ORG }); assert.strictEqual(r.statusCode, 404); assert.strictEqual(rpcs("email_claim").length, 0); assert.strictEqual(brevoCalls().length, 0);
  reset(); rpcFail.email_queue_status = 403; assert.strictEqual((await call(send, "POST", { org_id: ORG })).statusCode, 404);
  reset(); rpcFail.email_queue_status = 500; assert.strictEqual((await call(send, "POST", { org_id: ORG })).statusCode, 502);
});
test("email-send: with email switched off nothing is claimed or sent", async () => {
  reset(); status.mode = "off";
  const r = await call(send, "POST", { org_id: ORG });
  assert.strictEqual(r.statusCode, 200); assert.strictEqual(r.body.stopped, "off"); assert.strictEqual(rpcs("email_claim").length, 0);
});
test("email-send: plans reminders, sends the queue for THIS centre only, answers with counts and the queue, never an address or a link", async () => {
  reset(); claims.push([item(1), item(2)]);
  const { r, out } = await captureLogs(() => call(send, "POST", { org_id: ORG }));
  assert.strictEqual(r.statusCode, 200); assert.deepStrictEqual([r.body.ok, r.body.claimed, r.body.sent], [true, 2, 2]); assert.strictEqual(r.body.queue.mode, "staff_send");
  assert.strictEqual(rpcs("email_plan_reminders")[0].body.p_org, ORG); assert.strictEqual(rpcs("email_claim")[0].body.p_org, ORG);
  const all = r.raw + out; assert.ok(!all.includes("tutordeck.com.sg") && !all.includes(KEY) && !all.includes("aaaaaaaa-bbbb") && !/pay\?t=/.test(all), "no address, key or link in the answer or the logs");
  assert.ok(brevoCalls()[0].body.textContent.includes("https://tutordeck.vercel.app/pay?t="), "the link points at the host the staff member used");
});
test("email-send: a failure while planning reminders doesn't stop the queue being sent", async () => {
  reset(); rpcFail.email_plan_reminders = 500; claims.push([item(1)]);
  const r = await call(send, "POST", { org_id: ORG }); assert.strictEqual(r.statusCode, 200); assert.strictEqual(r.body.sent, 1);
});
test("email-send: a database failure while sending is a 502 with no detail", async () => {
  reset(); claims.push([item(1)]); rpcFail.email_complete = 500;
  const { r, out } = await captureLogs(() => call(send, "POST", { org_id: ORG }));
  assert.strictEqual(r.statusCode, 502); assert.deepStrictEqual(r.body, { error: "send_failed" }); assert.ok(!out.includes("tutordeck.com.sg"));
});

// ---------------------------------------------------------------- the daily job
test("cron: refuses anyone without the secret, and a missing/short secret means 'not configured'", async () => {
  reset();
  assert.strictEqual((await call(cron, "GET", {}, { authorization: "Bearer wrong" })).statusCode, 401);
  assert.strictEqual((await call(cron, "GET", {}, { authorization: undefined })).statusCode, 401);
  process.env.CRON_SECRET = "short"; assert.strictEqual((await call(cron, "GET", {}, { authorization: "Bearer short" })).statusCode, 503);
  reset(); delete process.env.BREVO_API_KEY; assert.strictEqual((await call(cron, "GET", {}, { authorization: "Bearer " + CRON })).statusCode, 503);
  assert.strictEqual(rpcs("email_claim").length, 0);
});
test("cron: plans reminders for every centre that uses email, then sends everyone's queue under the platform cap", async () => {
  reset(); process.env.VERCEL_ENV = "production"; activeOrgs = [{ org_id: ORG }, { org_id: "22222222-2222-2222-2222-222222222222" }]; claims.push([item(1, { to: "x@gmail.com" })]);
  const r = await call(cron, "GET", {}, { authorization: "Bearer " + CRON, host: undefined });
  assert.strictEqual(r.statusCode, 200); assert.strictEqual(r.body.centres, 2); assert.strictEqual(r.body.reminders_planned, 4); assert.strictEqual(r.body.send.sent, 1);
  assert.deepStrictEqual(rpcs("email_plan_reminders").map((c) => c.body.p_dry), [false, false]); assert.strictEqual(rpcs("email_claim")[0].body.p_org, null);
  assert.ok(brevoCalls()[0].body.textContent.includes("https://tutordeck.vercel.app/pay?t="), "no host on a cron: the live address");
  delete process.env.VERCEL_ENV;
});
test("cron: ?dry=1 counts and sends nothing", async () => {
  reset(); claims.push([item(1)]);
  const r = await call(cron, "GET", {}, { authorization: "Bearer " + CRON }, "/api/email-cron?dry=1");
  assert.strictEqual(r.body.dry, true); assert.strictEqual(r.body.reminders_planned, 3); assert.strictEqual(r.body.send, null); assert.strictEqual(rpcs("email_claim").length, 0); assert.strictEqual(rpcs("email_plan_reminders")[0].body.p_dry, true);
});
test("cron: one centre failing to plan doesn't stop the others or the sending", async () => {
  reset(); process.env.VERCEL_ENV = "production"; rpcFail.email_plan_reminders = 500; claims.push([item(1)]);
  const r = await call(cron, "GET", {}, { authorization: "Bearer " + CRON, host: undefined });
  assert.strictEqual(r.statusCode, 200); assert.strictEqual(r.body.failed_centres, 1); assert.strictEqual(r.body.send.sent, 1); delete process.env.VERCEL_ENV;
});

// ---------------------------------------------------------------- Brevo's events
test("webhook: needs the secret (header or ?s=), else 401; without the setting 503; only POST", async () => {
  reset(); const ev = { event: "hard_bounce", "message-id": "<abc.123@smtp>", email: "a@b.com" };
  assert.strictEqual((await call(hook, "POST", ev, { authorization: undefined })).statusCode, 401);
  assert.strictEqual((await call(hook, "POST", ev, { authorization: "Bearer nope" })).statusCode, 401);
  assert.strictEqual((await call(hook, "POST", ev, { authorization: undefined }, "/api/brevo-webhook?s=wrong")).statusCode, 401);
  assert.strictEqual((await call(hook, "GET", ev)).statusCode, 405);
  assert.strictEqual((await call(hook, "POST", ev, { authorization: "Bearer " + HOOK })).statusCode, 200);
  assert.strictEqual((await call(hook, "POST", ev, { authorization: undefined }, "/api/brevo-webhook?s=" + HOOK)).statusCode, 200);
  process.env.BREVO_WEBHOOK_SECRET = "short"; assert.strictEqual((await call(hook, "POST", ev, { authorization: "Bearer short" })).statusCode, 503);
  assert.strictEqual(rpcs("email_mark_bounce").length, 2);
});
test("webhook: bounces, blocks, invalid addresses and spam reports are passed on; delivered, opened and clicks are ignored; one call may carry many events", async () => {
  reset();
  const evs = [{ event: "hard_bounce", "message-id": "<m1@x.y>" }, { event: "soft_bounce", "message-id": "<m2@x.y>" }, { event: "invalid_email", "message-id": "<m3@x.y>" }, { event: "blocked", "message-id": "<m4@x.y>" },
    { event: "spam", "message-id": "<m5@x.y>" }, { event: "delivered", "message-id": "<m6@x.y>" }, { event: "opened", "message-id": "<m7@x.y>" }, { event: "click", "message-id": "<m8@x.y>" },
    { event: "hard_bounce" }, { event: "unsubscribe", "message-id": "<m9@x.y>" }, { event: "error", "message-id": "<m10@x.y>" }, { event: "deferred", "message-id": "<m11@x.y>" }];
  const r = await call(hook, "POST", evs, { authorization: "Bearer " + HOOK });
  assert.strictEqual(r.statusCode, 200); assert.strictEqual(r.body.handled, 7);
  assert.deepStrictEqual(rpcs("email_mark_bounce").map((c) => c.body.p_kind), ["hard_bounce", "soft_bounce", "invalid", "blocked", "spam", "unsubscribed", "error"]);
});
test("webhook: the answer and the logs never carry an address", async () => {
  reset();
  const { r, out } = await captureLogs(() => call(hook, "POST", { event: "hard_bounce", "message-id": "<q@x.y>", email: "private.person@example.org" }, { authorization: "Bearer " + HOOK }));
  assert.ok(!r.raw.includes("private.person") && !out.includes("private.person"));
  reset(); rpcFail.email_mark_bounce = 500;
  const x = await captureLogs(() => call(hook, "POST", { event: "hard_bounce", "message-id": "<q@x.y>", email: "private.person@example.org" }, { authorization: "Bearer " + HOOK }));
  assert.strictEqual(x.r.statusCode, 200, "a database hiccup is still a 200 so Brevo doesn't hammer us; the next event or a staff fix handles it"); assert.ok(!x.out.includes("private.person"));
});
