// Browser check for the organisation switcher (T12b). Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/org-switcher.check.js [screenshot-dir]
// Uses the same made-up Supabase stand-in as the other checks, with the person's memberships replaced per scenario.
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
const STUB_PLUS = STUB + `;(function(){var o=window.supabase.createClient;window.supabase.createClient=function(){var c=o.apply(this,arguments);if(window.__override)window.__override(c);return c;};})();`;
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };

const O = { solo: { id: "s1", kind: "solo", trading_name: "Mei Tuition" }, a: { id: "c1", kind: "centre", trading_name: "Alpha Learning Centre" }, b: { id: "c2", kind: "centre", trading_name: "Beta Centre" } };
const M = (o, role) => ({ org_id: o.id, user_id: "u1", role, status: "active", organisations: o });
function override(cfg) {   // runs in the page before anything else
  window.__override = function (c) {
    var from = c.from.bind(c);
    c.from = function (t) {
      if (t === "students" && cfg.members) {   // the head-only COUNT of the solo organisation's students (the rest of the stub is untouched)
        var q = from(t), sel = q.select;
        q.select = function (cols, opt) {
          if (!(opt && opt.head)) return sel.apply(q, arguments);
          var o = {}; ["eq", "neq", "in", "is"].forEach(function (m) { o[m] = function () { return o; }; });
          o.then = function (r, j) { return Promise.resolve(cfg.countError ? { data: null, count: null, error: { message: "x" } } : { data: null, count: cfg.soloStudents === undefined ? 3 : cfg.soloStudents, error: null }).then(r, j); };
          return o;
        };
        return q;
      }
      if (t !== "memberships" || !cfg.members) return from(t);
      var o = {}; ["select", "eq", "order", "neq", "in", "is", "limit"].forEach(function (m) { o[m] = function () { return o; }; });
      o.maybeSingle = o.single = function () { return Promise.resolve({ data: cfg.members[0] || null, error: null }); };
      o.then = function (r, j) { return Promise.resolve(cfg.error ? { data: null, error: { message: "relation does not exist" } } : { data: cfg.members, error: null }).then(r, j); };
      return o;
    };
  };
}
async function open(browser, cfg, opt) {
  opt = opt || {};
  const ctx = await browser.newContext({ viewport: opt.phone ? { width: 390, height: 780 } : { width: 1280, height: 800 } });
  await ctx.addInitScript((t) => { try { if (t) localStorage.setItem("td_theme", t); } catch (e) {} }, opt.dark ? "dark" : "");
  await ctx.route(/^(?!http:\/\/127\.0\.0\.1).*/, (r) => r.abort());
  const page = await ctx.newPage(), errs = [];
  page.on("pageerror", (e) => errs.push(String(e)));
  page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource|net::ERR/.test(m.text())) errs.push(m.text()); });
  await page.route("**/assets/vendor/supabase-2.118.0.js", (r) => r.fulfill({ body: STUB_PLUS, contentType: "application/javascript" }));
  await page.addInitScript(override, cfg);
  if (opt.pre) await page.addInitScript(opt.pre);
  return { ctx, page, errs };
}
const vis = (page, sel) => page.locator(sel).filter({ visible: true }).count();

(async () => {
  const browser = await chromium.launch();
  // 1 solo only: nothing new anywhere
  { const { ctx, page, errs } = await open(browser, { members: [M(O.solo, "owner")] });
    await page.goto(BASE + "home"); await page.waitForSelector(".topnav");
    ok(await page.locator(".org-sw").count() === 0, "solo only (desktop): no switcher in the page at all");
    ok(await page.evaluate(() => TL.org().kind === "solo" && TL.org().id === "s1"), "solo only: TL.org() is the solo organisation");
    ok(errs.length === 0, "solo only: no console errors " + errs.join("|")); await ctx.close(); }
  // 2 solo + centre (like both.tutor, but an owner here): switcher, switch, sticks across pages and reload
  { const { ctx, page, errs } = await open(browser, { members: [M(O.solo, "owner"), M(O.a, "owner")] });
    await page.goto(BASE + "home"); await page.waitForSelector(".topnav");
    ok(await vis(page, ".org-sw-desk .org-chip") === 1, "solo + centre: chip shown in the header");
    ok((await page.locator(".org-sw-desk .org-chip b").innerText()) === "Mei Tuition", "chip names the current (solo) organisation");
    if (SC) await page.screenshot({ path: path.join(SC, "chip-desktop.png") });
    await page.locator(".org-sw-desk .org-chip").click();
    ok(await vis(page, ".org-sw-desk .org-menu button") === 2, "menu lists both organisations");
    if (SC) await page.screenshot({ path: path.join(SC, "menu-desktop.png") });
    await page.locator('.org-sw-desk .org-menu [data-org="c1"]').click();
    await page.waitForURL(/org\?id=c1/);
    ok(true, "choosing the centre lands on its centre page (org?id=c1)");
    await page.goto(BASE + "calendar"); await page.waitForSelector(".topnav");
    ok((await page.locator(".org-sw-desk .org-chip b").innerText()) === "Alpha Learning Centre", "the choice sticks on another page");
    await page.reload(); await page.waitForSelector(".topnav");
    ok(await page.evaluate(() => TL.org().id) === "c1", "…and after a reload (TL.org() = centre)");
    await page.locator(".org-sw-desk .org-chip").click();
    await page.locator('.org-sw-desk .org-menu [data-org="s1"]').click();
    await page.waitForURL(/\/home/);
    ok((await page.locator(".org-sw-desk .org-chip b").innerText()) === "Mei Tuition", "switching back lands on Home with the solo organisation");
    await page.locator(".org-sw-desk .org-chip").click(); await page.keyboard.press("Escape");
    ok(await vis(page, ".org-sw-desk .org-menu") === 0, "Escape closes the menu");
    ok(errs.length === 0, "solo + centre: no console errors " + errs.join("|")); await ctx.close(); }
  // 2b centre owner whose own solo organisation has no students (centre.owner): lands on the centre home, no chip
  { const { ctx, page, errs } = await open(browser, { members: [M(O.solo, "owner"), M(O.a, "owner")], soloStudents: 0 });
    await page.goto(BASE + "home"); await page.waitForURL(/org\?id=c1/);
    ok(true, "centre owner with an empty solo organisation: Home lands on the centre page (org?id=c1)");
    await page.waitForSelector(".topnav");
    ok(await page.locator(".org-sw").count() === 0, "…and no chip");
    ok(await page.evaluate(() => TL.org().id) === "c1", "…TL.org() is the centre");
    ok(errs.length === 0, "centre owner: no console errors " + errs.join("|")); await ctx.close(); }
  // 2c students count fails: doubt = solo, nothing moves
  { const { ctx, page } = await open(browser, { members: [M(O.solo, "owner"), M(O.a, "owner")], countError: true });
    await page.goto(BASE + "home"); await page.waitForSelector(".topnav");
    ok(page.url().endsWith("/home") && await page.evaluate(() => TL.org().id) === "s1" && await vis(page, ".org-sw-desk .org-chip") === 1, "student count error: stays solo, chip kept"); await ctx.close(); }
  // 3 a remembered choice that is no longer valid falls back to solo
  { const { ctx, page } = await open(browser, { members: [M(O.solo, "owner"), M(O.a, "owner")] }, { pre: () => { try { localStorage.setItem("td:u1:org_pick", "gone"); } catch (e) {} } });
    await page.goto(BASE + "home"); await page.waitForSelector(".topnav");
    ok(await page.evaluate(() => TL.org().id) === "s1", "stale remembered choice: back to the solo organisation"); await ctx.close(); }
  // 4 only a centre (centre.owner): single organisation, no chip
  { const { ctx, page, errs } = await open(browser, { members: [M(O.a, "owner")] });
    await page.goto(BASE + "home"); await page.waitForSelector(".topnav");
    ok(await page.locator(".org-sw").count() === 0, "one centre only: no switcher");
    ok(await page.evaluate(() => TL.org().id) === "c1", "one centre only: TL.org() is that centre");
    ok(errs.length === 0, "one centre only: no console errors " + errs.join("|")); await ctx.close(); }
  // 5 tutor-only (tutor.one): never a switcher, even with two memberships
  { const { ctx, page, errs } = await open(browser, { members: [M(O.solo, "owner"), M(O.a, "tutor")] },
      { pre: () => { try { localStorage.setItem("td:u1:role", JSON.stringify({ v: "tutor-only", at: Date.now() })); } catch (e) {} } });
    await page.goto(BASE + "tutor"); await page.waitForSelector(".topnav");
    ok(await page.locator(".org-sw").count() === 0, "tutor-only: no switcher");
    ok(errs.length === 0, "tutor-only: no console errors " + errs.join("|")); await ctx.close(); }
  // 6 organisation tables missing / error: usual page, solo, no errors
  { const { ctx, page, errs } = await open(browser, { members: [], error: true });
    await page.goto(BASE + "home"); await page.waitForSelector(".topnav");
    ok(await page.locator(".org-sw").count() === 0, "memberships error: no switcher");
    ok(await page.evaluate(() => TL.org().kind === "solo" && TL.org().id === null), "memberships error: TL.org() = solo, id unknown");
    ok(errs.length === 0, "memberships error: no console errors " + errs.join("|")); await ctx.close(); }
  // 7 phone width, light and dark
  for (const dark of [false, true]) {
    const { ctx, page, errs } = await open(browser, { members: [M(O.solo, "owner"), M(O.a, "owner"), M(O.b, "staff")] }, { phone: true, dark });
    const t = dark ? "phone dark" : "phone";
    await page.goto(BASE + "home"); await page.waitForSelector(".tabbar");
    ok(await vis(page, ".org-sw-phone .org-chip") === 1 && await vis(page, ".org-sw-desk") === 0, t + ": chip shown at the top of the page (header bar is hidden on phones)");
    await page.locator(".org-sw-phone .org-chip").click();
    ok(await vis(page, ".org-sw-phone .org-menu button") === 3, t + ": menu lists three organisations");
    const box = await page.locator(".org-sw-phone .org-menu").boundingBox();
    ok(box && box.x >= 0 && box.x + box.width <= 390, t + ": menu fits inside the screen");
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= 390), t + ": no horizontal scroll");
    if (SC) await page.screenshot({ path: path.join(SC, "menu-" + t.replace(" ", "-") + ".png") });
    ok(errs.length === 0, t + ": no console errors " + errs.join("|")); await ctx.close();
  }
  await browser.close();
  console.log(fails ? fails + " FAILED" : "all passed"); process.exit(fails ? 1 : 0);
})();
