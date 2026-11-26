// Browser check (T36): a centre owner's Plan tab shows "Billing starts on <date>", "Pilot: not charged" and "Agreed starting number" in plain words.
// DEV may not have db/migration_centre_billing_start.sql yet, so the plan row and the snapshots are injected into the responses (dummy data only).
//   python3 tests/server.py 8765 &   node tests/centre-billing-start.check.js [screenshot-dir]
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
const CASES = [
  { n: "future start with an agreed number", start: "2999-02-01", ov: 85, snaps: [], want: [/Billing starts on 1 February 2999\./, /Until then you are on a free pilot: nothing is charged\./, /agreed starting number of 85 students/], not: [/Pilot: not charged/] },
  { n: "pilot month then first billed month", start: "2026-02-01", ov: 85,
    snaps: [{ month: "2026-02-01", active_students: 14, billable_students: 90, base_cents: 10000, per_student_cents: 50, fee_cents: 14500, billable: true, override_students: 85 },
            { month: "2026-01-01", active_students: 12, billable_students: 10, base_cents: 10000, per_student_cents: 50, fee_cents: 0, billable: false, waived_reason: "pilot" }],
    want: [/Billing starts on 1 February 2026\./, /Pilot: not charged/, /Agreed starting number: 85 students → 90 billable → S\$145\.00/], not: [/Until then you are on a free pilot/, /agreed starting number of 85 students\./] },
  { n: "no start date: unchanged", start: null, ov: null, snaps: [{ month: "2026-01-01", active_students: 403, billable_students: 400, base_cents: 10000, per_student_cents: 50, fee_cents: 30000, billable: true }],
    want: [/403 active → 400 billable → S\$300\.00/], not: [/Billing starts/, /Pilot/, /Agreed/] }
];
(async () => {
  const b = await chromium.launch();
  for (const vp of [{ n: "desktop", o: { viewport: { width: 1100, height: 900 } } }, { n: "phone", o: { viewport: { width: 390, height: 844 }, isMobile: true } }]) {
    for (const c of CASES) {
      const ctx = await b.newContext(vp.o), page = await ctx.newPage(), errs = [], L = vp.n + "/" + c.n;
      page.on("pageerror", (e) => errs.push(e.message));
      await page.route("**/rest/v1/org_plans*", async (r) => { const resp = await r.fetch(); let j = []; try { j = await resp.json(); } catch (e) {} if (Array.isArray(j)) j = j.map((x) => Object.assign({}, x, { billing_starts_on: c.start, first_month_billable_override: c.ov })); r.fulfill({ response: resp, body: JSON.stringify(j), contentType: "application/json" }); });
      await page.route("**/rest/v1/platform_fee_snapshots*", (r) => r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(c.snaps) }));
      await login(page, "centre.owner@example.test");
      await page.goto(BASE + "org.html", { waitUntil: "load" }); await page.waitForSelector("a[href*='org?id=']", { state: "attached", timeout: 15000 }); await page.waitForTimeout(1500);
      const href0 = await page.$$eval("a", (as) => (as.find((a) => /Live/.test(a.textContent) && /org\?id=/.test(a.getAttribute("href") || "")) || {}).href || "");
      await page.goto(href0.replace(/org\?id=/, "org.html?id=") + "#plan", { waitUntil: "load" }); await page.waitForSelector("#pl-contact", { timeout: 15000 });
      const txt = (await page.textContent("#og-body")).replace(/\s+/g, " ");
      c.want.forEach((re) => ok(re.test(txt), L + ": shows " + re));
      c.not.forEach((re) => ok(!re.test(txt), L + ": does not show " + re));
      ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), L + ": no sideways scroll");
      ok(errs.length === 0, L + ": no page errors " + errs.join("|"));
      if (SC) await page.screenshot({ path: path.join(SC, "billing-start-" + vp.n + "-" + c.n.replace(/\W+/g, "-") + ".png"), fullPage: true });
      await ctx.close();
    }
  }
  await b.close(); console.log(fails ? fails + " FAILED" : "ALL PASS"); process.exit(fails ? 1 : 0);
})();
