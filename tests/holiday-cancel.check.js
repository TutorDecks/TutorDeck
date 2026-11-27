// Browser check (T3.9): adding a holiday by hand offers "also cancel the lessons already on those days" with the count first.
//   python3 tests/server.py 8765 &   node tests/holiday-cancel.check.js [screenshot-dir]
// The database function is a stand-in here (tests/sql/slot_changes_test.sql proves the real one: never marked, paid or invoiced lessons, idempotent, audited).
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
const STUB_PLUS = STUB + `;(function(){var o=window.supabase.createClient;window.supabase.createClient=function(){var c=o.apply(this,arguments);if(window.__override)window.__override(c);return c;};})();`;
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
function override(cfg) {
  window.__calls = []; window.__ins = [];
  window.__override = function (c) {
    var rpc = c.rpc.bind(c), from = c.from.bind(c);
    c.from = function (t) { var q = from(t); if (t === "holidays" && q.insert) { var ins = q.insert.bind(q); q.insert = function (row) { window.__ins.push(row); return ins(row); }; } return q; };
    c.rpc = function (nm, a) {
      if (nm !== "staff_holiday_cancel") return rpc(nm, a);
      window.__calls.push(a);
      if (cfg.error) return Promise.resolve({ data: null, error: { message: cfg.error } });
      return Promise.resolve({ data: a.p_dry ? { dry: true, cancel: cfg.cancel, kept: cfg.kept || 0, earlier: 0 } : { dry: false, cancel: cfg.cancel, kept: cfg.kept || 0, earlier: 0 }, error: null });
    };
  };
}
async function run(b, vp, cfg, answer) {
  const ctx = await b.newContext(vp === "phone" ? { viewport: { width: 390, height: 844 }, isMobile: true } : { viewport: { width: 1100, height: 900 } });
  await ctx.route(/^(?!http:\/\/127\.0\.0\.1).*/, (r) => r.abort());
  const page = await ctx.newPage(), errs = [];
  page.on("pageerror", (e) => errs.push(e.message));
  await page.route("**/assets/vendor/supabase-2.118.0.js", (r) => r.fulfill({ body: STUB_PLUS, contentType: "application/javascript" }));
  await page.addInitScript(override, cfg);
  await page.goto(BASE + "org.html?id=o2#calendar", { waitUntil: "load" }); await page.waitForSelector("#h-add");
  await page.fill("#h-name", "Founders Day"); await page.fill("#h-from", "2027-08-09"); await page.fill("#h-to", "2027-08-09"); await page.click("#h-add");
  await page.waitForTimeout(900);
  return { ctx, page, errs };
}
(async () => {
  const b = await chromium.launch();
  for (const vp of ["desktop", "phone"]) {
    // 3 lessons, 1 protected: the offer shows the count first
    let { ctx, page, errs } = await run(b, vp, { cancel: 3, kept: 1 });
    const dlg = page.locator("[role=dialog], [role=alertdialog], .td-confirm, .cf-on").first();
    ok(await page.locator("button", { hasText: "Cancel the lessons" }).count() === 1, vp + ": a holiday added by hand offers to cancel the lessons already on it");
    const body = await page.locator("body").innerText();
    ok(/Also cancel 3 lessons already on that day\?/.test(body) && /3 lessons are already planned/.test(body) && /no charge/.test(body) && /1 lesson stays because it is marked, paid or invoiced/.test(body), vp + ": it shows the count, 'no charge' and how many stay");
    ok((await page.evaluate(() => window.__calls)).length === 1 && (await page.evaluate(() => window.__calls[0].p_dry)) === true, vp + ": before you answer, only a dry-run count has been asked for");
    if (SC) await page.screenshot({ path: path.join(SC, "holiday-offer-" + vp + ".png") });
    await page.locator("button", { hasText: "Cancel the lessons" }).click(); await page.waitForTimeout(500);
    const calls = await page.evaluate(() => window.__calls);
    ok(calls.length === 2 && calls[1].p_dry === false && calls[1].p_from === "2027-08-09" && calls[1].p_name === "Founders Day", vp + ": confirming makes the real call with the holiday's days and name");
    ok(/3 lessons cancelled with no charge/.test(await page.locator("body").innerText()), vp + ": and says how many were cancelled");
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), vp + ": no sideways scroll");
    ok(errs.length === 0, vp + ": no page errors " + errs.join("|")); await ctx.close();
    // Keep them
    ({ ctx, page, errs } = await run(b, vp, { cancel: 1 }));
    ok(/Also cancel the lesson already on that day\?/.test(await page.locator("body").innerText()), vp + ": one lesson is worded in the singular");
    await page.locator("button", { hasText: "Keep them" }).click(); await page.waitForTimeout(400);
    ok((await page.evaluate(() => window.__calls)).length === 1, vp + ": 'Keep them' cancels nothing");
    ok((await page.evaluate(() => window.__ins)).some((r) => r.name === "Founders Day" && r.starts_on === "2027-08-09"), vp + ": the holiday itself is saved either way (it is saved BEFORE the offer)"); await ctx.close();
    // nothing to cancel, and an older database: silent
    for (const cfg of [{ cancel: 0 }, { cancel: 5, error: "Could not find the function public.staff_holiday_cancel" }]) {
      ({ ctx, page, errs } = await run(b, vp, cfg));
      ok(await page.locator("button", { hasText: /Cancel the lesson|Keep them/ }).count() === 0, vp + ": no offer when there is nothing to cancel or the database can't do it (" + (cfg.error ? "older database" : "0 lessons") + ")");
      ok((await page.evaluate(() => window.__ins)).length === 1 && errs.length === 0, vp + ": and the holiday is still saved without errors"); await ctx.close();
    }
  }
  await b.close(); console.log(fails ? fails + " FAILED" : "ALL PASSED"); process.exit(fails ? 1 : 0);
})();
