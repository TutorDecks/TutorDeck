// Browser check for T7: the reset / welcome page, the people list's invite status + Resend button, and the invite claim on /tutor.
// Not part of CI (needs Playwright + `python3 tests/server.py 8765`):   node tests/invites-page.check.js [screenshot-dir]
// Everything is stubbed: the Supabase library (tests/supabase-stub-signed-in.js plus overrides here) and POST /api/send-invite. No network, no email.
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path"), crypto = require("crypto");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
const AXE = (() => { try { return fs.readFileSync(path.join(ROOT, "tests/node_modules/axe-core/axe.min.js"), "utf8"); } catch (e) { return null; } })();
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
async function axeCheck(page, tag) {
  if (!AXE) return console.log("skip accessibility (npm install in tests/ to enable)");
  await page.evaluate(AXE);
  const v = await page.evaluate(() => axe.run(document, { runOnly: ["wcag2a", "wcag2aa", "best-practice"] }).then((r) => r.violations.filter((x) => x.impact === "serious" || x.impact === "critical").map((x) => x.id + " (" + x.nodes.length + ") e.g. " + x.nodes[0].target.join(" "))));
  ok(v.length === 0, tag + ": accessibility" + (v.length ? " " + v.join("; ") : ""));
}
const STUB_PLUS = STUB + `;(function(){var o=window.supabase.createClient;window.supabase.createClient=function(){var c=o.apply(this,arguments);if(window.__override)window.__override(c);return c;};})();`;

// runs in the page before anything else
function override(cfg) {
  window.__calls = []; window.__auth = [];
  window.__override = function (c) {
    var ago = function (ms) { return new Date(Date.now() - ms).toISOString(); }, H = 3600e3, D = 24 * H;
    var me = { id: "mm1", org_id: "o2", user_id: "u1", display_name: "Mei", role: cfg.myRole || "owner", permissions: cfg.myPerms || [], status: "active", created_at: ago(30 * D) };
    var rows = [me,
      { id: "m3", org_id: "o2", user_id: null, invited_email: "sam@demo.test", display_name: "Sam", role: "staff", permissions: ["manage_timetable"], status: "invited", created_at: ago(3 * D) },
      { id: "m5", org_id: "o2", user_id: null, invited_email: "tia@demo.test", display_name: "Tia", role: "tutor", employment_type: "freelancer", permissions: [], status: "invited", created_at: ago(H) },
      { id: "m6", org_id: "o2", user_id: null, invited_email: "una@demo.test", display_name: "Una", role: "tutor", permissions: [], status: "invited", created_at: ago(2 * H) },
      { id: "m7", org_id: "o2", user_id: null, invited_email: "max@demo.test", display_name: "Max", role: "tutor", permissions: [], status: "invited", created_at: ago(2 * D) },
      { id: "m4", org_id: "o2", user_id: "u9", display_name: "Ravi", role: "tutor", employment_type: "freelancer", permissions: [], status: "active", created_at: ago(20 * D) }];
    var status = [{ member_id: "m3", invited_at: ago(3 * D), last_sent_at: ago(30 * H), sent_24h: 0, can_resend_at: ago(30 * H - 600e3) },
      { member_id: "m5", invited_at: ago(H), last_sent_at: null, sent_24h: 0, can_resend_at: null },
      { member_id: "m6", invited_at: ago(2 * H), last_sent_at: ago(3 * 60e3), sent_24h: 1, can_resend_at: new Date(Date.now() + 7 * 60e3).toISOString() },
      { member_id: "m7", invited_at: ago(2 * D), last_sent_at: ago(2 * H), sent_24h: 5, can_resend_at: ago(H) }];
    var origRpc = c.rpc.bind(c), origFrom = c.from.bind(c);
    c.rpc = function (n, a) {
      window.__calls.push([n, a]);
      if (n === "org_claim_invites") return Promise.resolve({ data: cfg.claims == null ? 0 : (window.__claimed ? 0 : (window.__claimed = true, cfg.claims)), error: null });
      if (n === "org_invite_mail_status") return Promise.resolve(cfg.noMailFn ? { data: null, error: { message: "function does not exist", code: "42883" } } : { data: status, error: null });
      if (n === "org_invite") return Promise.resolve({ data: "m-new", error: null });
      return origRpc(n, a);
    };
    c.from = function (t) {
      if (t === "memberships" && cfg.orgPage) {
        var f = []; var q = { select: function () { return q; }, order: function () { return q; }, eq: function (k, v) { f.push([k, v]); return q; },
          maybeSingle: function () { return Promise.resolve({ data: me, error: null }); }, single: function () { return Promise.resolve({ data: me, error: null }); },
          then: function (r, j) { var out = rows.filter(function (x) { return f.every(function (p) { return x[p[0]] == p[1]; }); }); return Promise.resolve({ data: out, error: null }).then(r, j); } };
        return q;
      }
      if (t === "memberships" && cfg.role) { var q2 = { select: function () { return q2; }, eq: function () { return q2; }, then: function (r, j) { return Promise.resolve({ data: cfg.role.memberships, error: null }).then(r, j); } }; return q2; }
      if (t === "students" && cfg.role && cfg.role.studentCount != null) { var s = { select: function () { return s; }, then: function (r, j) { return Promise.resolve({ data: [], count: cfg.role.studentCount, error: null }).then(r, j); } }; return s; }
      return origFrom(t);
    };
    if (cfg.noSession) c.auth.getSession = function () { return Promise.resolve({ data: { session: null }, error: null }); };
    c.auth.updateUser = function (u) { window.__auth.push(["updateUser", u.password]); return Promise.resolve(cfg.updateError ? { data: null, error: cfg.updateError } : { data: {}, error: null }); };
    c.auth.signOut = function () { window.__auth.push(["signOut"]); return Promise.resolve({ error: null }); };
    if (cfg.lessons) { var base = c.rpc; c.rpc = function (n, a) { if (n === "tutor_my_lessons") { window.__calls.push([n, a]); return Promise.resolve({ data: [], error: null }); } if (n === "tutor_mark_attendance") return Promise.resolve({ data: null, error: null }); return base(n, a); }; }
  };
}

async function open(browser, vp, cfg, url, hooks) {
  const ctx = await browser.newContext(vp === "phone" ? { viewport: { width: 390, height: 844 }, isMobile: true, deviceScaleFactor: 2 } : { viewport: { width: 1100, height: 900 } });
  await ctx.route(/^(?!http:\/\/127\.0\.0\.1).*/, (r) => r.abort());
  const page = await ctx.newPage(); const errs = [], api = [];
  await page.route("**/assets/vendor/supabase-2.118.0.js", (r) => r.fulfill({ body: STUB_PLUS, contentType: "application/javascript" }));
  await page.route("**/api/send-invite", (r) => { const req = r.request(); api.push({ auth: req.headers()["authorization"], body: JSON.parse(req.postData() || "{}") });
    const a = (hooks && hooks.api) || { status: 200, body: { ok: true, sent: true } }; const x = typeof a === "function" ? a(api.length) : a;
    r.fulfill({ status: x.status, contentType: "application/json", body: JSON.stringify(x.body) }); });
  if (hooks && hooks.pwned) await page.route("https://api.pwnedpasswords.com/**", (r) => r.fulfill({ status: 200, body: hooks.pwned }));
  await page.addInitScript(override, cfg);
  if (hooks && hooks.pre) await page.addInitScript(hooks.pre);
  page.on("pageerror", (e) => errs.push(e.message));
  page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource|ERR_FAILED|net::/.test(m.text())) errs.push(m.text()); });
  await page.goto(BASE + url, { waitUntil: "load" }); await page.waitForTimeout(hooks && hooks.wait || 1000);
  return { ctx, page, errs, api };
}
const visible = (page, sel) => page.evaluate((s) => { const e = document.querySelector(s); return !!e && getComputedStyle(e).display !== "none" && e.offsetParent !== null; }, sel);
const auth = (page) => page.evaluate(() => window.__auth);
const GOOD = "Str0ng!Pass-2026";

(async () => {
  const b = await chromium.launch();

  // ---------- A. /reset keeps today's behaviour, with the sign-up password rules
  { const { ctx, page, errs } = await open(b, "phone", {}, "reset.html");
    const items = await page.$$eval("#pw-hint li", (e) => e.map((x) => x.textContent.replace(/\s+/g, " ").trim()));
    ok(items.length === 5 && /8 characters/.test(items[0]) && /lowercase/.test(items[1]) && /uppercase/.test(items[2]) && /number/.test(items[3]) && /symbol/.test(items[4]), "reset: the same five-rule checklist as sign-up: " + items.join(" | "));
    ok((await page.textContent("#rs-title")) === "Set a new password" && (await page.textContent("#rs-save")) === "Update password", "reset: today's wording");
    await page.fill("#pw1", "abc123"); await page.fill("#pw2", "abc123"); await page.click("#rs-save");
    const m = await page.textContent("#rs-msg");
    ok(/^Your password is missing: /.test(m) && /8 characters/.test(m) && /uppercase letter/.test(m) && /symbol/.test(m) && !/lowercase|number/.test(m), "reset: a weak password is refused with what is still needed: " + m);
    ok((await auth(page)).length === 0, "reset: the weak password was never sent to Supabase");
    ok((await page.$$eval("#pw-hint li.bad", (e) => e.length)) >= 3, "reset: unmet rules turn red after a refused submit");
    await page.fill("#pw1", GOOD); await page.fill("#pw2", GOOD + "x"); await page.click("#rs-save");
    ok(/don't match/.test(await page.textContent("#rs-msg")) && (await auth(page)).length === 0, "reset: mismatched confirmation refused");
    await page.fill("#pw2", GOOD); await page.click("#rs-save"); await page.waitForTimeout(400);
    const a = await auth(page);
    ok(a.length === 2 && a[0][0] === "updateUser" && a[0][1] === GOOD && a[1][0] === "signOut", "reset: a good password is accepted, saved, and the recovery session ended");
    ok((await visible(page, "#rs-done")) && /Password updated/.test(await page.textContent("#rs-done-title")) && (await page.getAttribute("#rs-done-link", "href")) === "login", "reset: ends on 'Go to sign in' as before");
    ok(errs.length === 0, "reset: no console errors" + (errs.length ? " " + errs.join("|") : ""));
    await ctx.close(); }
  { // a password that has appeared in a breach is refused
    const sha = crypto.createHash("sha1").update("Passw0rd!Breach").digest("hex").toUpperCase();
    const { ctx, page } = await open(b, "desktop", {}, "reset.html", { pwned: "0000000000000000000000000000000000A:1\n" + sha.slice(5) + ":4321\n" });
    await page.fill("#pw1", "Passw0rd!Breach"); await page.fill("#pw2", "Passw0rd!Breach"); await page.click("#rs-save"); await page.waitForTimeout(300);
    ok(/appeared in 4,321 known data breaches/.test(await page.textContent("#rs-msg")) && (await auth(page)).length === 0, "reset: a known-breached password is refused (same check as sign-up)");
    ok(!(await page.isDisabled("#rs-save")), "reset: the button is usable again after that refusal");
    await ctx.close(); }
  { // Supabase refusing for its own reasons is shown in plain words
    const { ctx, page } = await open(b, "desktop", { updateError: { code: "weak_password", message: "x", weak_password: { reasons: ["characters"] } } }, "reset.html");
    await page.fill("#pw1", GOOD); await page.fill("#pw2", GOOD); await page.click("#rs-save"); await page.waitForTimeout(300);
    ok(/needs to include a lowercase and an uppercase letter, a number and a symbol/.test(await page.textContent("#rs-msg")), "reset: Supabase's weak-password refusal in plain words");
    await ctx.close(); }
  { const { ctx, page } = await open(b, "desktop", { noSession: true }, "reset.html");
    ok((await visible(page, "#rs-bad")) && !(await visible(page, "#rs-form")) && /Link expired/.test(await page.textContent("#rs-bad")), "reset: no session = 'Link expired', as before");
    await ctx.close(); }

  // ---------- B. the welcome variant (invite link)
  { const { ctx, page, errs } = await open(b, "phone", {}, "reset.html?welcome=1");
    ok(/Welcome to TutorDeck/.test(await page.textContent("#rs-title")) && (await page.textContent("#rs-save")) === "Set my password", "welcome: welcome wording");
    ok((await page.$$eval("#pw-hint li", (e) => e.length)) === 5, "welcome: same rule list as sign-up");
    await page.fill("#pw1", "weakpass"); await page.fill("#pw2", "weakpass"); await page.click("#rs-save");
    ok(/^Your password is missing: /.test(await page.textContent("#rs-msg")) && (await auth(page)).length === 0, "welcome: a weak password is refused");
    if (SC) await page.screenshot({ path: path.join(SC, "welcome-phone.png"), fullPage: true });
    await axeCheck(page, "welcome page");
    await page.fill("#pw1", GOOD); await page.fill("#pw2", GOOD); await page.click("#rs-save"); await page.waitForTimeout(300);
    const a = await auth(page);
    ok(a.length === 1 && a[0][0] === "updateUser" && a[0][1] === GOOD, "welcome: password saved and the session is KEPT (no sign-out)");
    ok(/Password set/.test(await page.textContent("#rs-done-title")) && /Taking you to your lessons/.test(await page.textContent("#rs-done-text")), "welcome: 'Password set. Taking you to your lessons'");
    await page.waitForTimeout(1600);
    ok(!/reset/.test(page.url()), "welcome: then leaves the page for the app (Home routes each login on, here the stub's centre owner to /org): " + page.url().replace(BASE, "/"));
    ok(errs.length === 0, "welcome: no console errors" + (errs.length ? " " + errs.join("|") : ""));
    await ctx.close(); }
  { const { ctx, page } = await open(b, "desktop", { noSession: true }, "reset.html?welcome=1");
    ok(/invite link has expired/i.test(await page.textContent("#rs-bad")) && /send it again/.test(await page.textContent("#rs-bad")), "welcome: an expired invite link says to ask for a new one");
    await ctx.close(); }

  // ---------- C. people list: invite status + Resend invite
  const PEOPLE = "org.html?id=o2#users";
  for (const vp of ["desktop", "phone"]) {
    const { ctx, page, errs, api } = await open(b, vp, { orgPage: true }, PEOPLE, { api: (n) => n === 1 ? { status: 200, body: { ok: true, sent: true } } : { status: 429, body: { error: "too_soon", retry_minutes: 6 } } });
    const tag = "people/" + vp;
    const rowsTxt = await page.$$eval(".og-item", (e) => e.map((x) => x.textContent.replace(/\s+/g, " ").trim()));
    const sam = rowsTxt.find((t) => t.includes("Sam")) || "", tia = rowsTxt.find((t) => t.includes("Tia")) || "", ravi = rowsTxt.find((t) => t.includes("Ravi")) || "";
    ok(/Invited 3 days ago/.test(sam) && /Link expired, send a new one/.test(sam), tag + ": Sam: 'Invited 3 days ago' + expired hint (" + sam.slice(0, 120) + ")");
    ok(/Invited today/.test(tia) && /No email sent yet/.test(tia), tag + ": Tia: never emailed");
    ok(/Emailed today/.test(rowsTxt.find((t) => t.includes("Una")) || ""), tag + ": Una: emailed today, no warning");
    const btns = await page.$$eval("[data-resend]", (e) => e.map((x) => [x.getAttribute("data-resend"), x.textContent.trim(), x.disabled]));
    ok(JSON.stringify(btns.map((x) => x[0])) === JSON.stringify(["m3", "m5", "m6", "m7"]), tag + ": Resend only on people who are still invited (not Mei or Ravi): " + btns.map((x) => x[0]).join(","));
    ok(btns[0][1] === "Resend invite" && btns[1][1] === "Send invite email", tag + ": labels 'Resend invite' / 'Send invite email'");
    ok(btns[0][2] === false && btns[1][2] === false && btns[2][2] === true && btns[3][2] === true, tag + ": disabled while inside the 10-minute wait (Una) and at the daily limit (Max)");
    ok(!/Resend/.test(ravi), tag + ": no Resend on an active person");
    await page.click('[data-resend="m3"]'); await page.waitForTimeout(500);
    ok(api.length === 1 && api[0].body.membership_id === "m3" && /^Bearer /.test(api[0].auth) && Object.keys(api[0].body).join() === "membership_id", tag + ": Resend sends only the membership id, with the user's token");
    ok(/Invite emailed to Sam/.test(await page.textContent("#td-toast")), tag + ": toast 'Invite emailed to Sam'");
    await page.click('[data-resend="m5"]'); await page.waitForTimeout(500);
    ok(/Try again in 6 min/.test(await page.textContent("#td-toast")), tag + ": a refused resend is explained: " + (await page.textContent("#td-toast")));
    if (SC) await page.screenshot({ path: path.join(SC, `people-${vp}.png`), fullPage: true });
    if (vp === "desktop") await axeCheck(page, tag);
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + ": no sideways scroll");
    ok(errs.length === 0, tag + ": no console errors" + (errs.length ? " " + errs.join("|") : ""));
    await ctx.close();
  }
  { // sending the first email when someone is invited
    const { ctx, page, api } = await open(b, "desktop", { orgPage: true }, PEOPLE);
    await page.fill("#i-name", "Nina New"); await page.fill("#i-email", "nina@demo.test"); await page.click("#i-go"); await page.waitForTimeout(600);
    ok(api.length === 1 && api[0].body.membership_id === "m-new", "invite: the first email is requested right after org_invite, for the new membership only");
    ok(/Nina New invited\. Email sent\./.test(await page.textContent("#td-toast")), "invite: toast says invited + email sent");
    await ctx.close(); }
  { // a blocked preview, an unconfigured server
    const { ctx, page } = await open(b, "desktop", { orgPage: true }, PEOPLE, { api: { status: 200, body: { ok: true, sent: false, blocked: "preview" } } });
    await page.click('[data-resend="m3"]'); await page.waitForTimeout(500);
    ok(/test site doesn.t email real people/.test(await page.textContent("#td-toast")), "preview block is explained, not shown as an error");
    await ctx.close(); }
  { const { ctx, page } = await open(b, "desktop", { orgPage: true }, PEOPLE, { api: { status: 503, body: { error: "not_configured" } } });
    await page.click('[data-resend="m3"]'); await page.waitForTimeout(500);
    ok(/Email isn.t switched on yet/.test(await page.textContent("#td-toast")), "email not configured yet: plain message");
    await ctx.close(); }
  // who sees the button
  { const { ctx, page } = await open(b, "desktop", { orgPage: true, myRole: "staff", myPerms: ["manage_tutors"] }, PEOPLE);
    ok((await page.$$("[data-resend]")).length === 4, "staff admin WITH 'manage tutors' sees Resend invite");
    await ctx.close(); }
  { const { ctx, page } = await open(b, "desktop", { orgPage: true, myRole: "staff", myPerms: ["manage_students"] }, PEOPLE);
    ok((await page.$$("[data-resend]")).length === 0 && !/Link expired/.test(await page.textContent("#og-body")), "staff admin WITHOUT 'manage tutors' sees no Resend button and no invite status");
    await ctx.close(); }
  { const { ctx, page } = await open(b, "desktop", { orgPage: true, myRole: "tutor" }, PEOPLE);
    ok((await page.$$("[data-resend]")).length === 0, "a tutor sees no Resend button");
    await ctx.close(); }
  { const { ctx, page, errs } = await open(b, "desktop", { orgPage: true, noMailFn: true }, PEOPLE);
    ok((await page.$$("[data-resend]")).length === 0 && /Invited 3 days ago/.test(await page.textContent("#og-body")) && errs.length === 0, "migration not installed here: no Resend button, the list still works, no errors");
    await ctx.close(); }

  // ---------- D. an invited tutor who lands straight on /tutor is linked
  const CENTRE_TUTOR = { memberships: [{ role: "tutor", status: "active", organisations: { kind: "centre" } }, { role: "owner", status: "active", organisations: { kind: "solo" } }], studentCount: 0 };
  { const { ctx, page, errs } = await open(b, "phone", { claims: 1, lessons: true, role: CENTRE_TUTOR }, "tutor.html", { pre: () => { localStorage.setItem("td:u1:role", JSON.stringify({ v: "solo", at: Date.now() })); } , wait: 1500 });
    const calls = await page.evaluate(() => window.__calls.map((c) => c[0]));
    ok(calls.filter((c) => c === "org_claim_invites").length === 1, "/tutor: org_claim_invites runs once on landing (" + calls.join(",") + ")");
    ok(calls.indexOf("org_claim_invites") < calls.indexOf("tutor_my_lessons"), "/tutor: the link happens before the lessons are asked for");
    const role = await page.evaluate(() => JSON.parse(localStorage.getItem("td:u1:role") || "null"));
    ok(role && role.v === "tutor-only", "/tutor: the remembered 'solo' menu was dropped after linking, so the tutor sees the tutor menu: " + JSON.stringify(role));
    ok(errs.length === 0, "/tutor: no console errors" + (errs.length ? " " + errs.join("|") : ""));
    await ctx.close(); }
  { const { ctx, page } = await open(b, "phone", { claims: 0, lessons: true, role: CENTRE_TUTOR }, "tutor.html", { pre: () => { localStorage.setItem("td:u1:claimed_at", String(Date.now() - 60e3)); } });
    const calls = await page.evaluate(() => window.__calls.map((c) => c[0]));
    ok(!calls.includes("org_claim_invites"), "/tutor: asked again within 30 minutes? no (no extra waiting on normal page loads)");
    await ctx.close(); }
  for (const pg of ["home.html", "students.html"]) {
    const { ctx, page } = await open(b, "desktop", { claims: 0, role: { memberships: [{ org_id: "o1", user_id: "u1", role: "owner", status: "active", organisations: { id: "o1", kind: "solo", trading_name: "Mei" } }] } }, pg);
    const calls = await page.evaluate(() => window.__calls.map((c) => c[0]));
    ok(calls.filter((c) => c === "org_claim_invites").length === 1 && !/\/tutor$/.test(page.url()), pg + ": a solo tutor is claimed once, nothing changes for them");
    await ctx.close();
  }
  await b.close();
  console.log(fails ? "\n" + fails + " FAILED" : "\nall browser checks passed"); process.exit(fails ? 1 : 0);
})();
