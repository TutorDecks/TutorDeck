// Browser check for the Singapore public holiday library in the centre wizard step 2 / Settings (not part of CI).
// Needs Playwright + `python3 tests/server.py 8765`; signs in as the DEV demo centre owner (db/seed_dev_demo.sql) and writes to DEV ONLY.
// It unticks everything it ticked, so the demo centre is left as it was found.   node tests/holiday-library.check.js [screenshot-dir]
const { chromium } = require("playwright"); const path = require("path");
const BASE = "http://127.0.0.1:8765/", SC = process.argv[2] || null; let fails = 0;
const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
(async () => {
  const b = await chromium.launch(), errs = [];
  const ctx = await b.newContext({ viewport: { width: 390, height: 800 } }), page = await ctx.newPage();
  page.on("console", (m) => { if (m.type() === "error") errs.push(m.text()); }); page.on("pageerror", (e) => errs.push(String(e)));
  await page.goto(BASE + "login.html"); await page.fill("#email", "centre.owner@example.test"); await page.fill("#pw", "Demo-Pass-2026"); await page.click("#go");
  await page.waitForURL((u) => !/login/.test(u.pathname), { timeout: 20000 });
  await page.goto(BASE + "org.html"); await page.waitForSelector(".og-item, .og-card");
  const href = await page.locator('a.og-item[href^="org?id="]').first().getAttribute("href"); ok(!!href, "found the demo centre");
  await page.goto(BASE + href.replace(/^org\?/, "org.html?") + "#calendar"); await page.waitForSelector("[data-hol]", { timeout: 15000 });
  const boxes = () => page.locator("[data-hol]"), n = await boxes().count();
  ok(n === 26, "26 library rows shown (" + n + ")");
  const manual = () => page.locator('[data-del="holidays"]').count();
  const before = await manual(), tickedBefore = await page.locator("[data-hol]:checked").count();
  ok(tickedBefore === 0 || before > 0, "starting state: " + tickedBefore + " ticked, " + before + " manual rows");
  ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), "no horizontal scroll at 390px");
  if (SC) await page.screenshot({ path: path.join(SC, "holidays-phone.png"), fullPage: true });
  // tick one
  const first = page.locator('[data-hol="2027-01-01"]'); const wasOn = await first.isChecked();
  if (!wasOn) { await first.check(); await page.waitForFunction((x) => document.querySelectorAll('[data-del="holidays"]').length === x, before + 1); }
  ok(await page.locator('[data-hol="2027-01-01"]').isChecked(), "tick shows checked");
  ok((await manual()) === (wasOn ? before : before + 1) && (await page.locator("text=New Year's Day").count()) > 0, "row appears in the manual list");
  await page.reload(); await page.waitForSelector("[data-hol]"); ok(await page.locator('[data-hol="2027-01-01"]').isChecked(), "tick persists after reload");
  // untick
  await page.locator('[data-hol="2027-01-01"]').uncheck(); await page.waitForFunction((x) => document.querySelectorAll('[data-del="holidays"]').length === x, before);
  ok(!(await page.locator('[data-hol="2027-01-01"]').isChecked()) && (await manual()) === before, "untick deletes the row");
  // select all 2026 (substitutes excluded), twice (no doubles), then clear
  await page.click('[data-hsel="2026"]'); await page.waitForFunction((x) => document.querySelectorAll('[data-del="holidays"]').length === x, before + 11);
  const after1 = await manual(); await page.click('[data-hsel="2026"]'); await page.waitForTimeout(1200);
  ok(after1 === before + 11 && (await manual()) === after1, "select all adds 11 once, second click adds none (" + after1 + ")");
  ok((await page.locator('[data-hol="2026-06-01"]').isChecked()) === false, "Monday substitute not ticked by select all");
  await page.click('[data-hclr="2026"]'); await page.click(".td-dlg-box [data-yes]");
  await page.waitForFunction((x) => document.querySelectorAll('[data-del="holidays"]').length === x, before, { timeout: 8000 }).catch(() => {});
  ok((await manual()) === before, "clear returns to " + before + " rows (" + (await manual()) + ")");
  // dark mode
  await page.evaluate(() => document.documentElement.setAttribute("data-theme", "dark"));
  if (SC) await page.screenshot({ path: path.join(SC, "holidays-dark.png"), fullPage: true });
  ok(errs.length === 0, "no console errors" + (errs.length ? ": " + errs.join(" | ") : ""));
  await b.close(); console.log(fails ? fails + " FAILED" : "all passed"); process.exit(fails ? 1 : 0);
})();
