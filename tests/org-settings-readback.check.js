// Browser check (B5-FIX B, C, I): the settings page shows the NEWEST saved version (not the one with the latest start date), saving 0 ("no limit") is sent,
// a billing change waits for the next cycle without holding back the rest, and the tab row scrolls sideways (wheel, End key) at phone width.
//   python3 tests/server.py 8765 &   node tests/org-settings-readback.check.js [screenshot-dir]
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
const STUB_PLUS = STUB + `;(function(){var o=window.supabase.createClient;window.supabase.createClient=function(){var c=o.apply(this,arguments);if(window.__override)window.__override(c);return c;};})();`;
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
function override() {
  window.__saves = [];
  window.__override = function (c) {
    var rpc = c.rpc.bind(c), from = c.from.bind(c);
    // newest VERSION: 50 changes a month, refunds by the owner. What applies today (rpc org_settings_on) is older: 2 and "four eyes" (the bug showed these).
    c.from = function (t) {
      if (t !== "org_settings") return from(t);
      var q = {}; ["select", "eq", "order", "limit"].forEach(function (m) { q[m] = function () { return q; }; });
      q.then = function (res) { return rpc("org_settings_on", { p_org: "o3", p_day: "9999-12-31" }).then(function (r) {
        var s = JSON.parse(JSON.stringify(r.data || {})); s.lessons = s.lessons || {}; s.lessons.timetable_editing = "tutors_direct"; s.lessons.max_changes_per_month = 50;
        s.billing = s.billing || {}; s.billing.deposit = Object.assign({}, s.billing.deposit, { refund_approved_by: "owner" });
        return res({ data: [{ settings: s }], error: null }); }); };
      return q;
    };
    c.rpc = function (nm, a) {
      if (nm === "org_save_settings") { window.__saves.push(a); return Promise.resolve({ data: window.__saves.length, error: null }); }
      if (nm === "org_settings_on") return rpc(nm, a).then(function (r) { var s = JSON.parse(JSON.stringify(r.data || {})); s.lessons = s.lessons || {}; s.lessons.timetable_editing = "tutors_direct"; s.lessons.max_changes_per_month = 2;
        s.billing = s.billing || {}; s.billing.deposit = Object.assign({}, s.billing.deposit, { refund_approved_by: "four_eyes" }); return { data: s, error: r.error }; });
      return rpc(nm, a);
    };
  };
}
(async () => {
  const b = await chromium.launch();
  for (const vp of ["desktop", "phone"]) {
    const ctx = await b.newContext(vp === "phone" ? { viewport: { width: 390, height: 844 }, isMobile: true } : { viewport: { width: 1100, height: 900 } });
    await ctx.route(/^(?!http:\/\/127\.0\.0\.1).*/, (r) => r.abort());
    const page = await ctx.newPage(), errs = [];
    page.on("pageerror", (e) => errs.push(e.message));
    await page.route("**/assets/vendor/supabase-2.118.0.js", (r) => r.fulfill({ body: STUB_PLUS, contentType: "application/javascript" }));
    await page.addInitScript(override);
    await page.goto(BASE + "org.html?id=o3#lessons", { waitUntil: "load" }); await page.waitForSelector("#f-lessons-max_changes_per_month");
    ok((await page.inputValue("#f-lessons-max_changes_per_month")) === "50", vp + ": 'most changes per tutor per month' shows the saved 50 (the older version says 2)");
    // C: type 0 = no limit and save
    await page.fill("#f-lessons-max_changes_per_month", "0"); await page.click("#og-save"); await page.waitForTimeout(500);
    ok((await page.evaluate(() => window.__saves.length)) === 2, vp + ": saving writes today's version and a next-cycle version");
    const sv = await page.evaluate(() => window.__saves[0]);
    ok(sv && sv.p_settings.lessons.max_changes_per_month === 0, vp + ": 0 is what is sent (no limit)");
    ok(sv && sv.p_settings.billing.deposit.refund_approved_by === "four_eyes" && /^\d{4}-\d{2}-\d{2}$/.test(sv.p_effective_from) && sv.p_effective_from === new Date().toISOString().slice(0, 10), vp + ": it takes effect today and keeps what applies today for billing (the pending billing change waits for the next cycle)");
    const sv2 = await page.evaluate(() => window.__saves[1]);
    ok(sv2 && sv2.p_settings.billing.deposit.refund_approved_by === "owner" && sv2.p_effective_from.slice(8) === "01" && sv2.p_settings.lessons.max_changes_per_month === 0, vp + ": a second version carries the pending billing change from the next cycle (and the 0)");
    ok(/billing changes apply from/.test(await page.textContent("#og-msg")), vp + ": the message says which part waits for the next cycle");
    // B: the refund dropdown shows the newest saved value
    await page.reload({ waitUntil: "load" }); await page.waitForSelector('[data-step="billing"]'); await page.click('[data-step="billing"]'); await page.waitForSelector("#f-billing-deposit-refund_approved_by");
    ok((await page.inputValue("#f-billing-deposit-refund_approved_by")) === '"owner"', vp + ": 'Refunds are approved by' shows the newest saved value, not the older four-eyes one");
    // I: the tab row scrolls sideways
    await page.setViewportSize(vp === "phone" ? { width: 390, height: 844 } : { width: 560, height: 800 });
    const m = await page.$eval(".og-steps", (e) => ({ sw: e.scrollWidth, cw: e.clientWidth, ox: getComputedStyle(e).overflowX }));
    ok(m.sw > m.cw && m.ox === "auto", vp + ": the tab row is wider than its box (" + m.sw + " > " + m.cw + ") and scrolls");
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), vp + ": the page itself does not scroll sideways");
    await page.evaluate(() => { document.querySelector(".og-steps").scrollLeft = 0; });
    await page.hover(".og-steps"); await page.mouse.wheel(0, 200); await page.waitForTimeout(300);
    ok((await page.$eval(".og-steps", (e) => e.scrollLeft)) > 0, vp + ": the mouse wheel moves the tab row");
    await page.evaluate(() => { document.querySelector(".og-steps").scrollLeft = 0; document.querySelector(".og-steps button").focus(); });
    await page.keyboard.press("End"); await page.waitForTimeout(300);
    ok((await page.$eval(".og-steps", (e) => e.scrollLeft)) > 0 && (await page.evaluate(() => document.activeElement.parentElement.classList.contains("og-steps"))), vp + ": the End key goes to the last tab and scrolls to it");
    await page.keyboard.press("ArrowLeft"); await page.waitForTimeout(100);
    ok(await page.evaluate(() => { var bs = document.querySelectorAll(".og-steps button"); return document.activeElement === bs[bs.length - 2]; }), vp + ": the arrow keys still walk the tabs");
    if (SC) await page.screenshot({ path: path.join(SC, "org-tabs-" + vp + ".png") });
    ok(errs.length === 0, vp + ": no page errors " + errs.join("|")); await ctx.close();
  }
  await b.close(); console.log(fails ? fails + " FAILED" : "ALL PASSED"); process.exit(fails ? 1 : 0);
})();
