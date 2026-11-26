// Browser check (T18a): the centre wizard shows the make-up / credit / holiday settings as "Coming soon" and disabled.
//   python3 tests/server.py 8765 &   node tests/org-soon.check.js [screenshot-dir]
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
const SOON = ["f-billing-makeups-allowed", "f-billing-makeups-per_period", "f-billing-makeups-uses_credit"];
const OTHER = ["f-billing-model", "f-billing-absences-mode", "f-billing-proration"];
(async () => {
  const b = await chromium.launch();
  for (const vp of ["desktop", "phone"]) {
    const ctx = await b.newContext(vp === "phone" ? { viewport: { width: 390, height: 844 }, isMobile: true } : { viewport: { width: 1100, height: 900 } });
    await ctx.route(/^(?!http:\/\/127\.0\.0\.1).*/, (r) => r.abort());
    const page = await ctx.newPage(), errs = [];
    page.on("pageerror", (e) => errs.push(e.message));
    await page.route("**/assets/vendor/supabase-2.118.0.js", (r) => r.fulfill({ body: STUB, contentType: "application/javascript" }));
    await page.goto(BASE + "org.html?id=o2#calendar", { waitUntil: "load" }); await page.waitForTimeout(1300);
    ok(!(await page.$eval("#f-calendar-skip_holidays", (e) => e.disabled)), vp + ": skip_holidays is editable (built in T3 step 7)");
    ok(!/Coming soon/.test(await page.textContent("#og")), vp + ": calendar step no longer shows Coming soon");
    if (SC) await page.screenshot({ path: path.join(SC, "wizard-calendar-" + vp + ".png"), fullPage: true });
    await page.click("[data-step=billing]"); await page.waitForTimeout(500);
    for (const id of SOON) {
      const el = await page.$("#" + id);
      ok(!!el && await el.evaluate((e) => e.disabled), vp + ": " + id + " visible and disabled");
    }
    for (const id of OTHER) { const el = await page.$("#" + id); ok(!!el && !(await el.evaluate((e) => e.disabled)), vp + ": " + id + " still editable"); }
    ok((await page.$$(".og-soon")).length >= 3, vp + ": Coming soon badges on billing step");
    ok((await page.textContent("#og")).includes("Make-up credits come in a later update; for now a make-up is added as a normal lesson."), vp + ": help text shown");
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), vp + ": no sideways scroll");
    ok(errs.length === 0, vp + ": no page errors " + errs.join("|"));
    if (SC) await page.screenshot({ path: path.join(SC, "wizard-billing-" + vp + ".png"), fullPage: true });
    await ctx.close();
  }
  await b.close(); console.log(fails ? fails + " FAILED" : "ALL PASS"); process.exit(fails ? 1 : 0);
})();
