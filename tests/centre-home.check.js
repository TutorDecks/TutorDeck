// Browser check for the centre Home and the centre menu (T3 step 1). Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/centre-home.check.js [screenshot-dir]
// Made-up Supabase stand-in: the person's memberships and the answer of staff_home() are replaced per scenario.
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
const STUB_PLUS = STUB + `;(function(){var o=window.supabase.createClient;window.supabase.createClient=function(){var c=o.apply(this,arguments);if(window.__override)window.__override(c);return c;};})();`;
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };

const SOLO = { id: "s1", kind: "solo", trading_name: "Empty Shell" }, C = { id: "c1", kind: "centre", trading_name: "Demo Learning Centre" };
const M = (o, role, permissions) => ({ org_id: o.id, user_id: "u1", role, status: "active", permissions: permissions || [], organisations: o });
const TODAY = new Date().toISOString().slice(0, 10);
const FULL = { org_id: "c1", org_name: "Demo Learning Centre", status: "active", today: TODAY, can: { students: true, timetable: true, charges: true },
  students_active: 8, today_lessons: 6, today_marked: 1, today_to_mark: 5, unmarked_past: 3, no_tutor_14d: 0, trials_this_month: 0, pending_charges: 1 };
const FRONT = Object.assign({}, FULL, { can: { students: true, timetable: false, charges: false }, today_lessons: null, today_marked: null, today_to_mark: null, unmarked_past: null, no_tutor_14d: null, trials_this_month: null, pending_charges: null });
function override(cfg) {
  window.__override = function (c) {
    var from = c.from.bind(c), rpc = c.rpc.bind(c);
    c.rpc = function (n, a) { if (n === "staff_home") return Promise.resolve(cfg.home.error ? { data: null, error: cfg.home.error } : { data: cfg.home, error: null }); return rpc(n, a); };
    c.from = function (t) {
      if (t === "students") {
        var q = from(t), sel = q.select;
        q.select = function (cols, opt) {
          if (!(opt && opt.head)) return sel.apply(q, arguments);
          var o = {}; ["eq", "neq", "in", "is"].forEach(function (m) { o[m] = function () { return o; }; });
          o.then = function (r, j) { return Promise.resolve({ data: null, count: 0, error: null }).then(r, j); };
          return o;
        };
        return q;
      }
      if (t !== "memberships") return from(t);
      var o = {}; ["select", "eq", "order", "neq", "in", "is", "limit"].forEach(function (m) { o[m] = function () { return o; }; });
      o.maybeSingle = o.single = function () { return Promise.resolve({ data: cfg.members[0] || null, error: null }); };
      o.then = function (r, j) { return Promise.resolve({ data: cfg.members, error: null }).then(r, j); };
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
  return { ctx, page, errs };
}
const txt = (page) => page.locator("#content").innerText();
const tabs = (page, phone) => page.locator(phone ? ".tabbar a" : ".tn-links a").filter({ visible: true }).allInnerTexts().then((a) => a.map((x) => x.replace(/\s*\n?\s*soon\s*\(coming next\)/i, "").replace(/\s*soon$/i, "").trim()));

(async () => {
  const browser = await chromium.launch();
  for (const mode of ["desktop", "phone", "dark"]) {
    const phone = mode === "phone";
    // owner: solo shell is hidden, Home lands on the centre page with the counts
    { const { ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], home: FULL }, { phone, dark: mode === "dark" });
      await page.goto(BASE + "home"); await page.waitForURL(/centre\?id=c1/); await page.waitForSelector(".tile, .ch-tile");
      const t = await txt(page);
      ok(/6\s*\n?\s*lessons today/.test(t) && /5\s*\n?\s*still to mark/.test(t) && /8\s*\n?\s*active students/.test(t), mode + " owner: Home shows the demo counts");
      ok(/1\s*\n?\s*charge to confirm/.test(t) && /3\s*\n?\s*past lessons not marked/.test(t), mode + " owner: pending items shown");
      ok(!/S\$|\$\d/.test(t), mode + " owner: no money on the page");
      ok((await tabs(page, phone)).slice(0, 4).join("|") === "Home|Timetable|Students|Attendance" || (phone && (await tabs(page, true)).slice(0, 4).join("|") === "Home|Timetable|Students|Attendance"), mode + " owner: tabs Home · Timetable · Students · Attendance (got " + (await tabs(page, phone)).join("|") + ")");
      ok(await page.locator(".soon-pill").filter({ visible: true }).count() === 3, mode + " owner: three tabs marked soon");
      ok(await page.locator(".org-sw").count() === 0, mode + " owner: no chip for an empty solo shell");
      if (SC) await page.screenshot({ path: path.join(SC, "home-" + mode + ".png"), fullPage: false });
      // coming-next tab: a real page, not a dead link
      await page.goto(BASE + "centre?id=c1&tab=timetable"); await page.waitForSelector(".ch-soon");
      ok(/Coming next/.test(await txt(page)) && /Timetable/.test(await txt(page)), mode + " owner: Timetable tab says Coming next");
      if (SC && mode !== "dark") await page.screenshot({ path: path.join(SC, "soon-" + mode + ".png") });
      await page.goto(BASE + "centre?id=c1&tab=nonsense"); await page.waitForSelector(".ch-empty");
      ok(/doesn.t exist|Not available/.test(await txt(page)), mode + " owner: an unknown tab gets a plain message");
      if (phone) { await page.locator("#tl-more").click(); const sheet = await page.locator("#tl-sheet").innerText();
        ok(/Centre settings/.test(sheet) && /Your centres/.test(sheet), "phone: More holds Centre settings and Your centres"); if (SC) await page.screenshot({ path: path.join(SC, "more-phone.png") }); }
      ok(errs.length === 0, mode + " owner: no console errors " + errs.join("|")); await ctx.close(); }
  }
  // full staff: same as owner
  { const { ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_timetable", "manage_students", "issue_invoices"])], home: FULL });
    await page.goto(BASE + "home"); await page.waitForURL(/centre\?id=c1/); await page.waitForSelector(".ch-tile");
    ok((await tabs(page)).join("|") === "Home|Timetable|Students|Attendance", "staff (full): all four tabs");
    ok(/6\s*\n?\s*lessons today/.test(await txt(page)), "staff (full): sees the same counts as the owner");
    ok(await page.locator(".org-sw").count() === 0, "staff: empty solo shell hidden, lands in the centre");
    ok(errs.length === 0, "staff (full): no console errors " + errs.join("|")); await ctx.close(); }
  // front desk: Students only
  for (const phone of [false, true]) {
    const { ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_students"])], home: FRONT }, { phone });
    await page.goto(BASE + "home"); await page.waitForURL(/centre\?id=c1/); await page.waitForSelector(".ch-tile");
    const t = await txt(page);
    ok((await tabs(page, phone)).slice(0, 2).join("|") === "Home|Students" && (await tabs(page, phone)).filter((x) => /Timetable|Attendance/.test(x)).length === 0, "front desk" + (phone ? " (phone)" : "") + ": menu is Home · Students only");
    ok(/8\s*\n?\s*active students/.test(t) && !/lessons today|still to mark|not marked|charge/.test(t), "front desk" + (phone ? " (phone)" : "") + ": only the student count, nothing about lessons or charges");
    await page.goto(BASE + "centre?id=c1&tab=timetable"); await page.waitForSelector(".ch-empty");
    ok(/Not available to you/.test(await txt(page)), "front desk: typing the Timetable address gives a plain 'not available'");
    if (SC && !phone) { await page.goto(BASE + "centre?id=c1"); await page.waitForSelector(".ch-tile"); await page.screenshot({ path: path.join(SC, "home-frontdesk.png") }); }
    ok(errs.length === 0, "front desk: no console errors " + errs.join("|")); await ctx.close(); }
  // errors: not found, and the migration missing
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], home: { error: { message: "NOT_FOUND" } } });
    await page.goto(BASE + "centre?id=c1"); await page.waitForSelector(".ch-empty"); ok(/Centre not available/.test(await txt(page)), "NOT_FOUND: friendly message"); await ctx.close(); }
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], home: { error: { code: "PGRST202", message: "Could not find the function" } } });
    await page.goto(BASE + "centre?id=c1"); await page.waitForSelector(".ch-empty"); ok(/Not switched on yet/.test(await txt(page)), "migration missing: plain message"); await ctx.close(); }
  // tutor only: sent to My lessons; solo only: sent Home
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "tutor")], home: FULL });
    await page.goto(BASE + "centre?id=c1"); await page.waitForTimeout(1500); ok(/\/tutor/.test(page.url()), "a centre tutor opening the centre page goes to My lessons (" + page.url() + ")"); await ctx.close(); }
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner")], home: FULL });
    await page.goto(BASE + "centre"); await page.waitForTimeout(1500); ok(/\/home/.test(page.url()), "a solo login opening the centre page goes Home (" + page.url() + ")");
    await page.waitForSelector(".topnav"); ok((await tabs(page)).includes("Dashboard") || (await tabs(page)).includes("Home"), "solo menu unchanged"); await ctx.close(); }
  await browser.close();
  console.log(fails ? fails + " FAILED" : "all passed"); process.exit(fails ? 1 : 0);
})();
