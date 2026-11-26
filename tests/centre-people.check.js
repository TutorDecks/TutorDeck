// Browser check (T3.9): the People tab for owners and staff, and the Settings entry on a centre tutor's menu.
//   python3 tests/server.py 8765 &   node tests/centre-people.check.js [screenshot-dir]
// The database is a stand-in (tests/sql/slot_changes_test.sql proves the real staff_people: who sees whom, no email / phone / pay).
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
const STUB_PLUS = STUB + `;(function(){var o=window.supabase.createClient;window.supabase.createClient=function(){var c=o.apply(this,arguments);if(window.__override)window.__override(c);return c;};})();`;
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
const SOLO = { id: "s1", kind: "solo", trading_name: "Empty Shell" }, C = { id: "c1", kind: "centre", trading_name: "Demo Learning Centre" };
const M = (o, role, permissions) => ({ org_id: o.id, user_id: "u1", role, status: "active", permissions: permissions || [], organisations: o });

function override(cfg) {
  var me = (cfg.members.filter(function (m) { return m.org_id === "c1"; })[0]) || { role: "tutor", permissions: [] };
  var owner = me.role === "owner", hr = owner || (me.role === "staff" && (me.permissions || []).indexOf("manage_tutors") >= 0);
  var NOW = Date.now(), H = function (h) { return new Date(NOW - h * 3600e3).toISOString(); };
  var ALL = [
    { id: "m0", name: "Olivia Owner", role: "owner", status: "active", invited: false, invited_at: null, last_emailed_at: null, you: owner },
    { id: "m1", name: "Sam Staff", role: "staff", status: "active", invited: false, invited_at: null, last_emailed_at: null, you: false },
    { id: "m2", name: "Tina Tutor", role: "tutor", status: "active", invited: false, invited_at: null, last_emailed_at: null, you: false },
    { id: "m3", name: "Wen Waiting", role: "tutor", status: "invited", invited: true, invited_at: H(50), last_emailed_at: H(2), you: false },
    { id: "m4", name: "Oscar Off", role: "tutor", status: "disabled", invited: false, invited_at: null, last_emailed_at: null, you: false }
  ];
  window.__calls = [];
  window.__override = function (c) {
    var from = c.from.bind(c), rpc = c.rpc.bind(c);
    c.rpc = function (nm, a) {
      window.__calls.push([nm, a]);
      if (nm === "staff_home") return Promise.resolve({ data: { org_id: "c1", org_name: "Demo Learning Centre", status: "active", today: new Date().toISOString().slice(0, 10), can: { students: true, timetable: true, charges: false }, students_active: 3, today_lessons: 0, today_marked: 0, today_to_mark: 0, unmarked_past: 0, no_tutor_14d: 0, pending_charges: 0, trials_this_month: 0 }, error: null });
      if (nm === "staff_people") {
        if (cfg.missing) return Promise.resolve({ data: null, error: { message: "Could not find the function public.staff_people" } });
        if (!hr) return Promise.resolve({ data: null, error: { message: "NOT_ALLOWED: your account can't see the people at this centre" } });
        return Promise.resolve({ data: { today: "2026-11-26", centre: "Demo Learning Centre", can_users: owner, rows: ALL.filter(function (r) { return owner || r.role === "tutor"; }) }, error: null });
      }
      return rpc(nm, a);
    };
    c.from = function (t) {
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
  const ctx = await browser.newContext(opt.phone ? { viewport: { width: 390, height: 844 }, isMobile: true } : { viewport: { width: 1280, height: 800 } });
  if (opt.role) await ctx.addInitScript((r) => { try { localStorage.setItem("td:u1:role", JSON.stringify({ v: r, at: Date.now() })); } catch (e) {} }, opt.role);
  await ctx.route(/^(?!http:\/\/127\.0\.0\.1).*/, (r) => r.abort());
  const page = await ctx.newPage(), errs = [];
  page.on("pageerror", (e) => errs.push(String(e)));
  page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource|net::ERR/.test(m.text())) errs.push(m.text()); });
  await page.route("**/assets/vendor/supabase-2.118.0.js", (r) => r.fulfill({ body: STUB_PLUS, contentType: "application/javascript" }));
  await page.addInitScript(override, cfg);
  return { ctx, page, errs };
}
const bar = async (page, phone) => (await page.locator(phone ? ".botnav a, .botnav button, nav.bottom a, nav.bottom button, .tabbar a, .tabbar button" : ".tn-links a").allInnerTexts()).map((t) => t.trim().replace(/\s+/g, " ")).filter(Boolean);
(async () => {
  const browser = await chromium.launch();
  for (const mode of ["desktop", "phone"]) {
    const phone = mode === "phone", tag = mode + ": ";
    // ---- the owner
    let { ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")] }, { phone });
    await page.goto(BASE + "centre.html?id=c1"); await page.waitForSelector(".ch-date");
    const labels = await page.evaluate(() => Array.from(document.querySelectorAll(window.innerWidth <= 820 ? "#tl-bar a, .tabbar a, nav.bottom a, .botbar a, body > .app a[href^='centre']" : ".tn-links a")).map((a) => a.textContent.trim()));
    ok(labels.some((t) => /People/.test(t)), tag + "the owner's centre menu has a People tab: " + labels.join(" | "));
    await page.goto(BASE + "centre-people.html?id=c1"); await page.waitForSelector(".pp-row");
    const body = await page.locator("#pp").innerText();
    ok(/Owner/i.test(body) && /Staff/i.test(body) && /Tutors/i.test(body) && /Olivia Owner/.test(body) && /Sam Staff/.test(body) && /Tina Tutor/.test(body), tag + "the owner sees owner, staff and tutors in sections");
    ok(/Demo Learning Centre · 5 people · 1 invited · 1 off/.test(body), tag + "a one-line summary: " + body.split("\n")[0]);
    ok(/Staff admin/.test(body) && /Tutor/.test(body) && /Active/.test(body) && /Invited/.test(body) && /Off/.test(body), tag + "each person shows role and status");
    ok(/Invited 2 days ago · Emailed today/.test(body), tag + "an invite shows when it was made and last emailed");
    ok(/You/.test(await page.locator(".pp-row").first().innerText()), tag + "the owner's own row says You");
    ok(!/@|\+65|\$|S\$|payout|bank|paynow/i.test(body.replace(/Users and permissions/g, "")), tag + "no email, phone, pay or money anywhere on the page");
    ok(await page.locator('a[href="org?id=c1#users"]').count() === 1 && /Users and permissions/.test(await page.locator('a[href="org?id=c1#users"]').innerText()), tag + "a link to the existing Users and permissions screen");
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + "no sideways scroll");
    if (SC) await page.screenshot({ path: path.join(SC, "people-" + mode + ".png"), fullPage: true });
    if (phone) {
      const boxes = await page.evaluate(() => Array.from(document.querySelectorAll("#view ~ * a, body > .app a, .app a")).filter((a) => a.getBoundingClientRect().bottom > window.innerHeight - 90 && a.getBoundingClientRect().height > 0).map((a) => { const r = a.getBoundingClientRect(); return { t: a.textContent.trim(), l: r.left, r: r.right, w: r.width }; }));
      ok(boxes.length === 0 || boxes.every((b) => b.l >= -1 && b.r <= 391), tag + "every item of the bottom bar fits inside the 390px screen (" + boxes.map((b) => b.t + ":" + Math.round(b.w)).join(", ") + ")");
    }
    if (!phone) for (const w of [1001, 1100]) { await page.setViewportSize({ width: w, height: 800 }); await page.waitForTimeout(150);
      ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + "with six tabs the top bar still fits a " + w + "px window"); }
    ok(errs.length === 0, tag + "no console errors " + errs.join("|")); await ctx.close();
    // ---- staff with Manage tutors: tutors only; staff without it: no People tab, and a plain message if they open the page
    ({ ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_tutors"])] }, { phone }));
    await page.goto(BASE + "centre-people.html?id=c1"); await page.waitForSelector(".pp-row");
    const hrBody = await page.locator("#pp").innerText();
    ok(/Tina Tutor/.test(hrBody) && !/Olivia Owner|Sam Staff/.test(hrBody) && /Resend invites/.test(hrBody), tag + "staff with Manage tutors see the tutors only, with the shorter note about the Users screen");
    ok(errs.length === 0, tag + "(Manage tutors) no console errors " + errs.join("|")); await ctx.close();
    ({ ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_timetable"])] }, { phone }));
    await page.goto(BASE + "centre-people.html?id=c1"); await page.waitForSelector("#pp .msg.err, #pp .pp-row");
    ok(/Manage tutors/.test(await page.locator("#pp").innerText()) && await page.locator(".pp-row").count() === 0, tag + "staff without Manage tutors get a plain message naming the permission, and no list");
    await ctx.close();
    ({ ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], missing: true }, { phone }));
    await page.goto(BASE + "centre-people.html?id=c1"); await page.waitForSelector("#pp .pp-note");
    ok(/migration_slot_changes/.test(await page.locator("#pp").innerText()), tag + "an older database: a plain message names the migration file"); await ctx.close();
    // ---- a centre tutor's menu has Settings (goes to /tutor-settings); a solo tutor's menu is unchanged
    ({ ctx, page, errs } = await open(browser, { members: [M(C, "tutor")] }, { phone, role: "tutor-only" }));
    await page.goto(BASE + "tutor.html"); await page.waitForTimeout(1200);
    if (phone) { await page.click("#tl-more"); await page.waitForTimeout(400); }
    const sel = phone ? '#tl-sheet a[href="tutor-settings"]' : '.tn-right a[href="tutor-settings"]';
    ok(await page.locator(sel).count() === 1, tag + "a centre tutor's menu has a Settings entry that goes to /tutor-settings");
    ok(/Settings/.test(await page.locator(sel).first().evaluate((a) => a.getAttribute("aria-label") || a.textContent)), tag + "and it is called Settings");
    ok(await page.locator(phone ? '#tl-sheet a[href="settings"]' : '.tn-right a[href="settings"]').count() === 0, tag + "the solo Settings page is not offered to a centre tutor");
    if (SC && phone) await page.screenshot({ path: path.join(SC, "tutor-menu-more-phone.png") });
    await page.locator(sel).first().click(); await page.waitForTimeout(1800);
    ok(/tutor-settings/.test(page.url()), tag + "it opens their own settings page (" + page.url().split("/").pop() + ")");
    ok(await page.locator(phone ? "#tl-more.on" : '.tn-right a[href="tutor-settings"].active').count() === 1, tag + "and the Settings entry is highlighted there");
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + "tutor menu: no sideways scroll");
    ok(errs.length === 0, tag + "tutor menu: no console errors " + errs.join("|")); await ctx.close();
    // a tutor-only login's other menu items are still just My lessons and Schedule
    ({ ctx, page, errs } = await open(browser, { members: [M(C, "tutor")] }, { phone, role: "tutor-only" }));
    await page.goto(BASE + "tutor.html"); await page.waitForTimeout(1200);
    const tl = await page.evaluate((ph) => Array.from(document.querySelectorAll(ph ? ".bottombar a, .botnav a, nav[aria-label=Main] a, .app a" : ".tn-links a")).map((a) => a.textContent.trim()).filter(Boolean), phone);
    ok(tl.some((t) => /My lessons/.test(t)) && tl.some((t) => /Schedule/.test(t)), tag + "the tutor's main menu still has My lessons and Schedule"); await ctx.close();
    // solo menus untouched
    ({ ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner")] }, { phone }));
    await page.goto(BASE + "home.html"); await page.waitForTimeout(1500);
    if (phone) { await page.click("#tl-more"); await page.waitForTimeout(400); }
    ok(await page.locator(phone ? '#tl-sheet a[href="settings"]' : '.tn-right a[href="settings"]').count() === 1 && await page.locator('a[href="tutor-settings"]').count() === 0, tag + "a solo tutor still has Settings (/settings) and no tutor-settings entry");
    ok(errs.length === 0, tag + "solo menu: no console errors " + errs.join("|")); await ctx.close();
  }
  await browser.close(); console.log(fails ? fails + " FAILED" : "ALL PASSED"); process.exit(fails ? 1 : 0);
})();
