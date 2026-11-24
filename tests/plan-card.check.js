// Browser check for the card line on Settings → Your plan (not part of CI: needs Playwright + `python3 tests/server.py 8765`).
//   node tests/plan-card.check.js [screenshot-dir]
// The billing call (/api/billing) is stubbed here; the real Stripe sandbox is NOT contacted.
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
const PLUS = STUB + `;(function(){var o=window.supabase.createClient;window.supabase.createClient=function(){var c=o.apply(this,arguments);var r=c.rpc.bind(c);
  c.rpc=function(n,a){ if(n==="org_plan_status") return Promise.resolve({data:window.__plan,error:null}); return r(n,a); }; return c;};})();`;
const now = new Date(), yr = now.getFullYear();
const PLAN = (o) => Object.assign({ kind: "solo", tier: "pro", has_pro: true, status: "active", grandfathered: false, active_students: 8, free_limit: 5,
  current_period_end: new Date(Date.now() + 20 * 86400000).toISOString(), trial_end: null, cancel_at_period_end: false }, o);
const CASES = [
  { name: "card present", plan: PLAN(), api: { card: { brand: "Visa", last4: "4242", exp_month: 8, exp_year: yr + 3 } }, has: [/Visa ending 4242, expires 08\/\d{4}/, /Update card/], warn: false },
  { name: "trial, no card", plan: PLAN({ status: "trialing", trial_end: new Date(Date.now() + 10 * 86400000).toISOString() }), api: { card: null }, has: [/No card on file/, /Add a card to continue/], warn: false },
  { name: "card expiring soon", plan: PLAN(), api: { card: { brand: "Mastercard", last4: "4444", exp_month: now.getMonth() + 1, exp_year: yr } }, has: [/Mastercard ending 4444, expires/, /update it soon/], warn: true },
  { name: "card expired", plan: PLAN(), api: { card: { brand: "Visa", last4: "1111", exp_month: 1, exp_year: yr - 1 } }, has: [/expired 01\/\d{4}/], warn: true },
  { name: "past due with card", plan: PLAN({ status: "past_due" }), api: { card: { brand: "Visa", last4: "4242", exp_month: 8, exp_year: yr + 3 } }, has: [/last payment didn/, /Visa ending 4242/, /Update card/], warn: false },
  { name: "error", plan: PLAN(), api: 502, has: [/couldn’t check your card/], warn: false },
  { name: "free plan: no card line at all", plan: PLAN({ tier: "free", has_pro: false, status: "none" }), api: { card: null }, has: [/Free plan/], hasnt: [/card on file/i], warn: false },
];
(async () => {
  const browser = await chromium.launch();
  for (const vp of [{ n: "desktop", w: 1100, h: 800 }, { n: "phone", w: 390, h: 800 }]) {
    for (const c of CASES) {
      const ctx = await browser.newContext({ viewport: { width: vp.w, height: vp.h }, deviceScaleFactor: 1 }), page = await ctx.newPage();
      await page.route("**/assets/vendor/supabase-2.118.0.js", (r) => r.fulfill({ body: PLUS, contentType: "application/javascript" })); await page.addInitScript((p) => { window.__plan = p; }, c.plan);
      let calls = [];
      await page.route("**/api/billing", (r) => { const b = JSON.parse(r.request().postData() || "{}"); calls.push(b.action);
        if (c.api === 502) return r.fulfill({ status: 502, contentType: "application/json", body: '{"error":"billing_unavailable"}' });
        r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(c.api) }); });
      await page.route(/^https?:\/\/(?!127\.0\.0\.1)/, (r) => r.abort()); await page.goto(BASE + "settings.html", { waitUntil: "domcontentloaded", timeout: 15000 }); await page.waitForSelector("#plan-body .plan-line", { timeout: 8000 }).catch(() => {});
      await page.waitForTimeout(600);
      const txt = await page.textContent("#plan-card").catch(() => "");
      const tag = vp.n + " / " + c.name;
      (c.has || []).forEach((re) => ok(re.test(txt), tag + ": shows " + re));
      (c.hasnt || []).forEach((re) => ok(!re.test(txt), tag + ": does not show " + re));
      const warn = await page.$("#plan-card .plan-pay.warn");
      if (c.name !== "past due with card") ok(!!warn === c.warn, tag + ": amber text " + (c.warn ? "on" : "off"));
      ok(calls.length === (c.name.startsWith("free") ? 0 : 1) && (calls[0] || "card") === "card", tag + ": billing calls = " + JSON.stringify(calls));
      const over = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1);
      ok(!over, tag + ": no horizontal scroll");
      if (SC) { await page.locator("#plan-card").screenshot({ path: path.join(SC, "plan-" + vp.n + "-" + c.name.replace(/\W+/g, "-") + ".png") }).catch(() => {}); }
      await ctx.close();
    }
  }
  await browser.close();
  console.log(fails ? fails + " FAILED" : "all passed"); process.exit(fails ? 1 : 0);
})();
