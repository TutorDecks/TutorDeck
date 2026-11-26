// Browser check (T31a): a centre owner's Plan tab has the fee info and a Contact card but no Stripe controls; a solo tutor's plan card is unchanged.
// Uses the DEV Supabase project (dummy data, demo logins from db/seed_dev_demo.sql). /api/billing is stubbed; Stripe is never contacted.
//   python3 tests/server.py 8765 &   node tests/centre-plan.check.js [screenshot-dir]
const { chromium } = require("playwright");
const path = require("path");
const SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/", PW = "Demo-Pass-2026";
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
async function login(page, email) {
  await page.goto(BASE + "login.html", { waitUntil: "load" });
  await page.fill("#email", email); await page.fill("#pw", PW);
  if (await page.$("#consent")) { try { await page.check("#consent", { timeout: 500 }); } catch (e) {} }
  await page.click("#go"); await page.waitForURL(/home|tutor|settings|org/, { timeout: 20000 });
}
(async () => {
  const b = await chromium.launch();
  for (const vp of [{ n: "desktop", o: { viewport: { width: 1100, height: 900 } } }, { n: "phone", o: { viewport: { width: 390, height: 844 }, isMobile: true } }]) {
    // ---- centre owner
    let ctx = await b.newContext(vp.o), page = await ctx.newPage(), errs = [], billing = [];
    page.on("pageerror", (e) => errs.push(e.message));
    await page.route("**/api/billing", (r) => { billing.push(r.request().postData()); r.fulfill({ status: 403, contentType: "application/json", body: "{\"error\":\"centre_contact_us\"}" }); });
    await login(page, "centre.owner@example.test");
    await page.goto(BASE + "org.html", { waitUntil: "load" }); await page.waitForSelector("a[href*='org?id=']", { state: "attached", timeout: 15000 }); await page.waitForTimeout(1500);
    const href0 = await page.$$eval("a", (as) => (as.find((a) => /Live/.test(a.textContent) && /org\?id=/.test(a.getAttribute("href") || "")) || {}).href || "");   // a launched centre
    await page.goto(href0.replace(/org\?id=/, "org.html?id=") + "#plan", { waitUntil: "load" }); await page.waitForSelector("#pl-contact", { timeout: 15000 });
    const txt = await page.textContent("#og-body");
    ok(/Billing for centres is by invoice and PayNow/.test(txt) && /Contact us to set up your account/.test(txt), vp.n + ": centre sees the contact card");
    // the DEV demo centre may still hold the old 40c plan until db/migration_fee_050.sql is applied there, so read the numbers from the page
    ok(/S\$100\.00 a month \+ S\$0\.\d\d per billable student/.test(txt), vp.n + ": fee formula shown");
    ok(/98 students → 100 billable → S\$\d+\.\d\d/.test(txt) && /405 students → 410 billable → S\$\d+\.\d\d/.test(txt), vp.n + ": worked examples shown");
    const href = await page.getAttribute("#pl-contact-btn", "href");
    ok(/^mailto:tutordeckadmin@gmail\.com\?subject=/.test(href), vp.n + ": Contact button is a mailto (" + href + ")");
    ok(!(await page.$("#og-body [data-act], #og-body input[type=radio]")) && !/Start 30-day|Add a card|Update card|Manage plan|Stripe/i.test(txt), vp.n + ": no checkout / subscribe / card controls");
    ok(billing.length === 0, vp.n + ": the page made no /api/billing call");
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), vp.n + ": no sideways scroll");
    ok(errs.length === 0, vp.n + ": no page errors " + errs.join("|"));
    if (SC) await page.screenshot({ path: path.join(SC, "centre-plan-" + vp.n + ".png"), fullPage: true });
    await ctx.close();
    // ---- solo tutor: unchanged plan card
    ctx = await b.newContext(vp.o); page = await ctx.newPage(); errs = [];
    page.on("pageerror", (e) => errs.push(e.message));
    await page.route("**/api/billing", (r) => r.fulfill({ status: 200, contentType: "application/json", body: "{\"card\":null}" }));
    await login(page, "solo.tutor@example.test");
    await page.goto(BASE + "settings.html", { waitUntil: "load" }); await page.waitForTimeout(2500);
    const card = await page.textContent("#plan-card").catch(() => "");
    // the DEV demo tutor's plan state changes as people test it (free / trial / paid), so check the card is the usual solo one
    ok(/Solo Pro/.test(card) && /active student/.test(card), vp.n + ": solo plan card shows its usual Solo Pro / student-count text");
    ok(!!(await page.$('#plan-card button[data-act="checkout"], #plan-card button[data-act="portal"]')), vp.n + ": solo still has its checkout / manage button");
    ok(!/Billing for centres/.test(card), vp.n + ": no centre text on the solo card");
    ok(errs.length === 0, vp.n + ": no page errors " + errs.join("|"));
    if (SC) await page.locator("#plan-card").screenshot({ path: path.join(SC, "solo-plan-" + vp.n + ".png") }).catch(() => {});
    await ctx.close();
  }
  await b.close(); console.log(fails ? fails + " FAILED" : "ALL PASS"); process.exit(fails ? 1 : 0);
})();
