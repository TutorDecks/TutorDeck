"use strict";
// Invite email: the Brevo request builder, the preview block, and api/send-invite.js with Supabase and Brevo replaced by an in-memory fake
// (no network, no real keys, no real email). Run: node --test tests/*.test.js
process.env.SUPABASE_URL = "https://fake.supabase.test"; process.env.SUPABASE_SERVICE_ROLE_KEY = "service_fake";
const test = require("node:test"), assert = require("node:assert"), { Readable } = require("stream");
const M = require("../api/_brevo-lib.js"), handler = require("../api/send-invite.js");

const MID = "22222222-2222-2222-2222-222222222222", LOG = "33333333-3333-3333-3333-333333333333";
const LINK = "https://fake.supabase.test/auth/v1/verify?token=SECRET-LINK-TOKEN&type=recovery&redirect_to=x";
const KEY = "xkeysib-FAKE-KEY-FOR-TESTS";
let calls, reserve, userExists, brevoStatus, logs;
function reset(over) {
  calls = []; logs = []; userExists = true; brevoStatus = 201;
  reserve = Object.assign({ ok: true, log_id: LOG, email: "tara@tutordeck.com.sg", name: "Tara Tutor", role: "tutor", centre: "Alpha Tuition", inviter: "Olivia Owner" }, over || {});
  process.env.BREVO_API_KEY = KEY; delete process.env.VERCEL_ENV; delete process.env.INVITE_TEST_ALLOW; delete process.env.BREVO_INVITE_TEMPLATE_ID;
}
const json = (code, obj) => ({ ok: code < 400, status: code, json: async () => obj, text: async () => (obj == null ? "" : JSON.stringify(obj)) });
global.fetch = async (url, opt) => {
  opt = opt || {}; const u = String(url), m = opt.method || "GET";
  calls.push({ m, u, body: opt.body ? JSON.parse(opt.body) : null, headers: opt.headers || {} });
  if (u.endsWith("/auth/v1/user")) return opt.headers.Authorization === "Bearer good" ? json(200, { id: "user-1" }) : json(401, {});
  if (u.endsWith("/rest/v1/rpc/org_invite_mail_reserve")) {
    if (reserve === "forbidden") return json(403, { code: "42501" });
    return json(200, reserve);
  }
  if (u.includes("/rest/v1/org_invite_mail_log")) { logs.push(JSON.parse(opt.body)); return json(204, null); }
  if (u.endsWith("/auth/v1/admin/generate_link")) return userExists ? json(200, { action_link: LINK }) : json(404, { msg: "User not found" });
  if (u.endsWith("/auth/v1/admin/users")) { userExists = true; return json(200, { id: "new-user" }); }
  if (u === "https://api.brevo.com/v3/smtp/email") return json(brevoStatus, brevoStatus < 300 ? { messageId: "<msg-1@brevo>" } : { message: "nope" });
  throw new Error("unexpected fetch " + u);
};
function res() { const r = { headers: {}, setHeader(k, v) { r.headers[k] = v; }, end(b) { r.body = b ? JSON.parse(b) : null; r.raw = b || ""; } }; return r; }
function post(body, headers) {
  const req = Readable.from([Buffer.from(JSON.stringify(body))]); req.method = "POST";
  req.headers = Object.assign({ authorization: "Bearer good", host: "tutordeck.vercel.app" }, headers || {}); const r = res(); return handler(req, r).then(() => r);
}
const brevoCalls = () => calls.filter((c) => c.u.startsWith("https://api.brevo.com"));
function captureLogs(fn) {   // everything the handler prints, to prove no secret is in it
  const out = [], l = console.log, e = console.error; console.log = (...a) => out.push(a.join(" ")); console.error = (...a) => out.push(a.join(" "));
  return fn().then((r) => { console.log = l; console.error = e; return { r, out: out.join("\n") }; }, (x) => { console.log = l; console.error = e; throw x; });
}

// ---------------------------------------------------------------- the request builder
test("brevo body: fixed sender address, centre in the display name, fixed reply-to, link once, no key", () => {
  const b = M.inviteBody({ to: "Tara@Example.com ", name: "Tara", role: "tutor", centre: "Alpha Tuition", inviter: "Olivia", link: LINK }, {});
  assert.deepStrictEqual(b.sender, { name: "Alpha Tuition via TutorDeck", email: "noreply@tutordeck.com.sg" });
  assert.deepStrictEqual(b.replyTo, { email: "tutordeckadmin@gmail.com", name: "TutorDeck" });
  assert.deepStrictEqual(b.to, [{ email: "tara@example.com", name: "Tara" }]);
  assert.strictEqual(b.subject, "Olivia invited you to Alpha Tuition on TutorDeck");
  assert.ok(b.htmlContent.includes("Set my password") && b.textContent.includes("Set my password: " + LINK));
  assert.strictEqual(b.htmlContent.split(LINK.replace(/&/g, "&amp;")).length, 2, "the link appears once in the HTML");
  assert.ok(!JSON.stringify(b).includes(KEY) && !JSON.stringify(b).toLowerCase().includes("api-key"));
  assert.ok(/24 hours/.test(b.textContent) && !/student|fee|invoice/i.test(b.textContent), "plain words, no student or money detail");
});
test("brevo body: a hostile centre or person name cannot change the sender address or inject markup", () => {
  const b = M.inviteBody({ to: "a@example.com", name: '<script>alert(1)</script> "x"', role: "staff", centre: 'Evil" <boss@evil.com>;', inviter: "x@y.com", link: LINK }, {});
  assert.strictEqual(b.sender.email, "noreply@tutordeck.com.sg");
  assert.ok(!/[<>"@;]/.test(b.sender.name), "display name: " + b.sender.name);
  assert.ok(!b.htmlContent.includes("<script>") && !/boss@evil\.com/.test(JSON.stringify(b.sender)));
  assert.strictEqual(M.senderFor("").name, "TutorDeck"); assert.strictEqual(M.senderFor(null).email, "noreply@tutordeck.com.sg");
  assert.ok(M.senderFor("x".repeat(500)).name.length <= 80);
});
test("brevo body: with BREVO_INVITE_TEMPLATE_ID it uses the Brevo template and the documented params", () => {
  const b = M.inviteBody({ to: "a@example.com", name: "Tara", role: "tutor", centre: "Alpha", inviter: "Olivia", link: LINK }, { BREVO_INVITE_TEMPLATE_ID: "7" });
  assert.strictEqual(b.templateId, 7); assert.ok(!b.htmlContent);
  assert.deepStrictEqual(Object.keys(b.params).sort(), ["centre", "expiry", "inviter", "link", "name", "role"]);
});

// ---------------------------------------------------------------- preview block
test("preview rule: production sends to anyone; previews only to @tutordeck.com.sg and the allow-list", () => {
  assert.ok(M.addressAllowed("anyone@gmail.com", { VERCEL_ENV: "production" }));
  const pv = { VERCEL_ENV: "preview", INVITE_TEST_ALLOW: "me@gmail.com, @friends.example " };
  assert.ok(M.addressAllowed("Raphael@TutorDeck.com.sg", pv) && M.addressAllowed("a@tutordeck.com.sg", {}));
  assert.ok(M.addressAllowed("me@gmail.com", pv) && M.addressAllowed("x@friends.example", pv));
  for (const bad of ["other@gmail.com", "a@x.tutordeck.com.sg", "a@tutordeck.com.sg.evil.com", "a@evil.com@tutordeck.com.sg", '"a@evil.com"@tutordeck.com.sg',
                     "a@tutordeck.com.sg, b@evil.com", "", null, "nodomain", "x@friends.example.evil.com"]) assert.ok(!M.addressAllowed(bad, pv), "must block " + bad);
  assert.ok(!M.addressAllowed("other@gmail.com", {}), "no env at all = preview rules");
});

// ---------------------------------------------------------------- the Brevo call
test("send(): posts to Brevo with the key in the api-key header, returns the message id; missing key throws not_configured", async () => {
  reset(); let seen;
  const r = await M.send({ hello: 1 }, async (u, o) => { seen = { u, o }; return json(201, { messageId: "m1" }); }, { BREVO_API_KEY: KEY });
  assert.deepStrictEqual([r.ok, r.status, r.messageId], [true, 201, "m1"]);
  assert.strictEqual(seen.u, "https://api.brevo.com/v3/smtp/email"); assert.strictEqual(seen.o.headers["api-key"], KEY); assert.strictEqual(seen.o.method, "POST");
  await assert.rejects(() => M.send({}, async () => { throw new Error("must not call"); }, {}), (e) => e.code === "not_configured");
  const bad = await M.send({}, async () => json(400, { message: "bad" }), { BREVO_API_KEY: KEY }); assert.deepStrictEqual([bad.ok, bad.status], [false, 400]);
});

// ---------------------------------------------------------------- the endpoint
test("endpoint: sends once to an allowed address, logs 'sent' with the message id, never returns or logs the link or key", async () => {
  reset();
  const { r, out } = await captureLogs(() => post({ membership_id: MID }));
  assert.strictEqual(r.statusCode, 200); assert.deepStrictEqual(r.body, { ok: true, sent: true });
  assert.strictEqual(brevoCalls().length, 1);
  const bc = brevoCalls()[0]; assert.strictEqual(bc.headers["api-key"], KEY);
  assert.strictEqual(bc.body.sender.email, "noreply@tutordeck.com.sg"); assert.strictEqual(bc.body.sender.name, "Alpha Tuition via TutorDeck");
  assert.strictEqual(bc.body.to[0].email, "tara@tutordeck.com.sg"); assert.ok(bc.body.htmlContent.includes("token=SECRET-LINK-TOKEN"));
  const gl = calls.find((c) => c.u.endsWith("/generate_link")); assert.deepStrictEqual(gl.body, { type: "recovery", email: "tara@tutordeck.com.sg", redirect_to: "https://tutordeck.vercel.app/reset?welcome=1" });
  assert.deepStrictEqual(logs, [{ status: "sent", brevo_message_id: "<msg-1@brevo>" }]);
  assert.ok(!r.raw.includes("SECRET-LINK-TOKEN") && !r.raw.includes(KEY), "response has no link or key");
  assert.ok(!out.includes("SECRET-LINK-TOKEN") && !out.includes(KEY) && !out.includes("tara@"), "log lines have no link, key or address: " + out);
  assert.ok(calls.find((c) => c.u.endsWith("/rpc/org_invite_mail_reserve")).headers.Authorization === "Bearer good", "the permission check runs with the CALLER's token");
  assert.ok(!calls.some((c) => c.u.includes("/memberships")), "the invite row is never touched");
});
test("endpoint: preview + address not allowed → not sent, no account made, no link, logged 'blocked_preview'", async () => {
  reset({ email: "real.parent@gmail.com" });
  const { r, out } = await captureLogs(() => post({ membership_id: MID }));
  assert.strictEqual(r.statusCode, 200); assert.deepStrictEqual(r.body, { ok: true, sent: false, blocked: "preview" });
  assert.strictEqual(brevoCalls().length, 0); assert.ok(!calls.some((c) => c.u.includes("/auth/v1/admin")));
  assert.deepStrictEqual(logs, [{ status: "blocked_preview", brevo_message_id: null }]);
  assert.ok(/blocked in preview/.test(out) && !out.includes("gmail"), "logged without the address");
});
test("endpoint: the allow-list lets a preview email a listed address; production emails anyone", async () => {
  reset({ email: "me@gmail.com" }); process.env.INVITE_TEST_ALLOW = "me@gmail.com";
  assert.strictEqual((await post({ membership_id: MID })).body.sent, true);
  reset({ email: "someone@gmail.com" }); process.env.VERCEL_ENV = "production";
  assert.strictEqual((await post({ membership_id: MID })).body.sent, true); delete process.env.VERCEL_ENV;
});
test("endpoint: no account yet → the login is created (confirmed, unknown password) and then the link is made", async () => {
  reset(); userExists = false;
  const r = await post({ membership_id: MID }); assert.strictEqual(r.body.sent, true);
  const mk = calls.find((c) => c.u.endsWith("/auth/v1/admin/users"));
  assert.strictEqual(mk.body.email, "tara@tutordeck.com.sg"); assert.strictEqual(mk.body.email_confirm, true); assert.ok(mk.body.password.length >= 30);
  assert.strictEqual(calls.filter((c) => c.u.endsWith("/generate_link")).length, 2);
});
test("endpoint: refusals — not configured 503, signed out 401, bad id 400, bad host 400, not allowed 403, not invited 409, too soon / limits 429", async () => {
  reset(); delete process.env.BREVO_API_KEY; assert.strictEqual((await post({ membership_id: MID })).statusCode, 503);
  assert.strictEqual(calls.length, 0, "no key = nothing is called at all");
  reset(); assert.strictEqual((await post({ membership_id: MID }, { authorization: "Bearer bad" })).statusCode, 401);
  assert.strictEqual((await post({ membership_id: "x'; drop" })).statusCode, 400); assert.strictEqual((await post({})).statusCode, 400);
  assert.strictEqual((await post({ membership_id: MID }, { host: "evil.example" })).statusCode, 400);
  reset(); reserve = "forbidden"; assert.strictEqual((await post({ membership_id: MID })).statusCode, 403);
  for (const [reason, code] of [["not_invited", 409], ["too_soon", 429], ["daily_limit", 429], ["org_limit", 429]]) {
    reset({ ok: false, reason, retry_minutes: 7 }); const r = await post({ membership_id: MID });
    assert.strictEqual(r.statusCode, code, reason); assert.strictEqual(r.body.error, reason);
    assert.strictEqual(brevoCalls().length, 0); assert.strictEqual(logs.length, 0);
  }
  const g = res(); await handler({ method: "GET", headers: {} }, g); assert.strictEqual(g.statusCode, 405);
});
test("endpoint: the browser cannot choose the address — an 'email' or 'to' in the body is ignored", async () => {
  reset(); await post({ membership_id: MID, email: "victim@gmail.com", to: "victim@gmail.com", sender: "ceo@bank.com" });
  assert.strictEqual(brevoCalls()[0].body.to[0].email, "tara@tutordeck.com.sg"); assert.strictEqual(brevoCalls()[0].body.sender.email, "noreply@tutordeck.com.sg");
});
test("endpoint: Brevo refusing (4xx/5xx) → clear 502, log row 'failed', invite row untouched", async () => {
  for (const code of [400, 401, 500]) {
    reset(); brevoStatus = code; const { r, out } = await captureLogs(() => post({ membership_id: MID }));
    assert.strictEqual(r.statusCode, 502); assert.strictEqual(r.body.error, "email_failed");
    assert.deepStrictEqual(logs, [{ status: "failed", brevo_message_id: null }]); assert.ok(!out.includes(KEY) && !out.includes("SECRET-LINK-TOKEN"));
    assert.ok(!calls.some((c) => c.u.includes("/memberships")));
  }
});
test("endpoint: if Brevo cannot be reached at all → 502 and 'failed', never a crash", async () => {
  reset(); const f = global.fetch; global.fetch = async (u, o) => { if (String(u).startsWith("https://api.brevo.com")) throw new Error("network down"); return f(u, o); };
  try { const r = await post({ membership_id: MID }); assert.strictEqual(r.statusCode, 502); assert.deepStrictEqual(logs, [{ status: "failed", brevo_message_id: null }]); }
  finally { global.fetch = f; }
});
