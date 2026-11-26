// Browser check for the centre Charges tab (T3 step 4). Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/centre-charges.check.js [screenshot-dir]
// The database functions are replaced by a small in-memory stand-in that follows the same rules (tests/sql/staff_charges_test.sql proves the real ones).
// The queue starts with the demo's "Sophie Lim, late cancelled, charge pending" lesson, plus an absent and a cancelled-in-time one.
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
const STUB_PLUS = STUB + `;(function(){var o=window.supabase.createClient;window.supabase.createClient=function(){var c=o.apply(this,arguments);if(window.__override)window.__override(c);return c;};})();`;
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
const SOLO = { id: "s1", kind: "solo", trading_name: "Empty Shell" }, C = { id: "c1", kind: "centre", trading_name: "Demo Learning Centre" };
const M = (o, role, permissions) => ({ org_id: o.id, user_id: "u1", role, status: "active", permissions: permissions || [], organisations: o });

function override(cfg) {
  var TODAY = new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 10);
  function add(d, n) { var x = new Date(d + "T00:00:00Z"); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); }
  var Q = [
    { id: "q1", d: add(TODAY, -2), st: "15:00:00", en: "16:00:00", name: "Sophie Lim", lvl: "Sec 2", tut: "Demo Tutor One", att: "late_cancelled", price: 6000 },
    { id: "q2", d: add(TODAY, -1), st: "16:00:00", en: "17:00:00", name: "Hannah Wee", lvl: "Sec 1", tut: "Demo Tutor Two", att: "absent", price: 12345 },
    { id: "q3", d: add(TODAY, -5), st: "17:00:00", en: "18:00:00", name: "Ravi Menon", lvl: "Sec 1", tut: "Demo Tutor One", att: "cancelled_early", price: 8000 }];
  var mode = cfg.mode || "charged_unless_notice";
  window.__calls = []; window.__audit = [];
  function sugg(q) { return mode === "charged" ? q.price : mode === "not_charged" ? 0 : (q.att === "cancelled_early" ? 0 : q.price); }
  window.__override = function (c) {
    var from = c.from.bind(c), rpc = c.rpc.bind(c);
    function res(d, e) { return Promise.resolve({ data: d || null, error: e ? (typeof e === "string" ? { message: e } : e) : null }); }
    c.rpc = function (nm, a) {
      window.__calls.push([nm, a]);
      if (nm === "staff_home") return res({ org_id: "c1", org_name: "Demo Learning Centre", status: "active", today: TODAY,
        can: { students: true, timetable: cfg.timetable !== false, charges: !cfg.noCharges }, students_active: 8, today_lessons: 3, today_marked: 1, today_to_mark: 2, unmarked_past: 0, no_tutor_14d: 0,
        trials_this_month: 0, pending_charges: cfg.noCharges ? null : Q.length });
      if (nm === "staff_lessons") return res({ today: TODAY, can_mark: cfg.timetable !== false, page: 1, size: 50, total: 0, counts: { all: 0, unmarked: 0, marked: 0 }, tutors: [], rows: [] });
      if (!/^(staff_pending_charges|staff_set_charge|staff_set_charges)$/.test(nm)) return rpc(nm, a);
      if (cfg.chargesError) return res(null, cfg.chargesError);
      if (nm === "staff_pending_charges") {
        return res({ today: TODAY, page: a.p_page, size: a.p_size, total: Q.length,
          rows: Q.slice().sort((x, y) => (x.d < y.d ? 1 : -1)).map((q) => ({ lesson_id: q.id, lesson_date: q.d, start_time: q.st, end_time: q.en, student_id: "s" + q.id, student_name: q.name, student_level: q.lvl, subject: "English",
            tutor_name: q.tut, attendance: q.att, remarks: null, marked_by_name: "Demo Centre Owner", marked_at: q.d + "T08:00:00+00:00", session_id: null,
            price_cents: q.price, suggestion_mode: mode, suggested_cents: sugg(q) })) });
      }
      if (nm === "staff_set_charge") {
        var i = Q.findIndex((x) => x.id === a.p_lesson), q = Q[i];
        if (!q) return res(null, "NOT_FOUND");
        if (a.p_amount_cents == null || a.p_amount_cents < 0 || a.p_amount_cents > q.price) return res(null, "BAD_CHARGE: enter an amount from 0 up to the lesson's own price");
        window.__audit.push({ lesson: q.id, cents: a.p_amount_cents }); Q.splice(i, 1);
        return res({ lesson_id: q.id, compensation_cents: a.p_amount_cents, price_cents: q.price });
      }
      var ids = a.p_lessons, got = Q.filter((x) => ids.indexOf(x.id) >= 0);
      if (got.length !== ids.length) return res(null, "NOT_FOUND");
      got.forEach((x) => { window.__audit.push({ lesson: x.id, cents: a.p_mode === "full" ? x.price : a.p_amount_cents }); Q.splice(Q.indexOf(x), 1); });
      return res({ updated: got.length, total_cents: 0 });
    };
    c.from = function (t) {
      if (t === "students") { var q = from(t), sel = q.select; q.select = function (cols, opt) { if (!(opt && opt.head)) return sel.apply(q, arguments); var o = {}; ["eq", "neq", "in", "is"].forEach(function (m) { o[m] = function () { return o; }; }); o.then = function (r, j) { return Promise.resolve({ data: null, count: 0, error: null }).then(r, j); }; return o; }; return q; }
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
const calls = (page, nm) => page.evaluate((n) => window.__calls.filter((c) => c[0] === n).map((c) => c[1]), nm);

(async () => {
  const browser = await chromium.launch();
  const ALL = ["manage_students", "manage_timetable", "issue_invoices"];
  for (const mode of ["desktop", "phone", "dark"]) {
    const phone = mode === "phone", tag = mode + ": ";
    const { ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ALL)] }, { phone, dark: mode === "dark" });
    await page.goto(BASE + "centre-attendance.html?id=c1"); await page.waitForSelector("#ca-tabs:not([hidden])");
    ok(/Charges\s*3/.test((await page.locator("#ca-tabs").innerText()).replace(/\n/g, " ")), tag + "the Charges tab shows, with the 3 waiting");
    ok(await page.locator("#cg").isHidden(), tag + "Lessons is the first tab; Charges stays out of the way");
    await page.click("#ca-tab-charges"); await page.waitForSelector(".cg-row");
    ok(await page.locator(".cg-row").count() === 3, tag + "the queue lists the 3 lessons");
    ok(/tab=charges/.test(page.url()), tag + "the address remembers the tab");
    const first = await page.locator(".cg-row").first().innerText();
    ok(/Hannah Wee/.test(first) && /S\$123\.45/.test(first), tag + "newest first, with the lesson price");
    ok(/Sophie Lim[\s\S]*Late cancelled/.test(await page.locator(".cg-row", { hasText: "Sophie" }).innerText()) || /Late/.test(await page.locator(".cg-row", { hasText: "Sophie" }).innerText()), tag + "a row says how it was marked");
    ok(/Suggested: not charged/.test(await page.locator(".cg-row", { hasText: "Ravi" }).innerText()), tag + "cancelled in time: suggestion is 0 under 'charged unless notice'");
    ok(!/waiting for charge|undefined|null/.test(await page.locator("#cg").innerText()), tag + "no raw words on the page");
    // Sophie: open, suggestion pre-filled, validation, type 0
    await page.locator(".cg-row", { hasText: "Sophie" }).locator(".cg-open").click(); await page.waitForSelector("#cg-sheet.on");
    ok((await page.inputValue("#cg-amt")) === "60.00", tag + "the sheet pre-fills the suggested S$60.00");
    ok(/charges unless notice was given/.test(await page.locator("#cg-rule").innerText()) && /You decide/.test(await page.locator("#cg-rule").innerText()), tag + "the centre's rule is explained and a person decides");
    await page.fill("#cg-amt", "999"); await page.click("#cg-save");
    ok(/more than the lesson costs \(S\$60\.00\)/.test(await page.locator("#cg-err").innerText()), tag + "too much: plain refusal with the price");
    await page.fill("#cg-amt", "abc"); await page.click("#cg-save");
    ok(/like 25 or 25\.50/.test(await page.locator("#cg-err").innerText()), tag + "not a number: plain refusal");
    await page.fill("#cg-amt", ""); await page.click("#cg-save");
    ok(/Enter the amount/.test(await page.locator("#cg-err").innerText()), tag + "empty: plain refusal");
    ok((await calls(page, "staff_set_charge")).length === 0, tag + "nothing was sent while the amount was wrong");
    await page.click("#cg-full"); ok((await page.inputValue("#cg-amt")) === "60.00", tag + "'Full price' fills the lesson's price");
    await page.click("#cg-zero"); ok((await page.inputValue("#cg-amt")) === "0.00", tag + "'Not charged' fills 0");
    if (SC) await page.screenshot({ path: path.join(SC, "charge-sheet-" + mode + ".png") });
    await page.click("#cg-save"); await page.waitForFunction(() => !/Sophie/.test(document.querySelector("#cg-list").textContent));
    const sent = await calls(page, "staff_set_charge");
    ok(sent.length === 1 && sent[0].p_lesson === "q1" && sent[0].p_amount_cents === 0, tag + "typing 0 sends whole cents (0) for Sophie's lesson, one call");
    ok(await page.locator(".cg-row").count() === 2 && /Charges\s*2/.test((await page.locator("#ca-tabs").innerText()).replace(/\n/g, " ")), tag + "it leaves the queue and the tab count drops to 2");
    // exact cents from a typed amount
    await page.locator(".cg-row", { hasText: "Ravi" }).locator(".cg-open").click(); await page.waitForSelector("#cg-sheet.on");
    await page.fill("#cg-amt", "19.99"); await page.click("#cg-save"); await page.waitForFunction(() => !/Ravi/.test(document.querySelector("#cg-list").textContent));
    ok((await calls(page, "staff_set_charge")).pop().p_amount_cents === 1999, tag + "S$19.99 is sent as exactly 1999 cents");
    // bulk on the last one + a fresh queue
    ok(await page.locator("#cg-bulk").isHidden(), tag + "no bulk bar until something is ticked");
    await page.check('[data-pick="q2"]'); await page.waitForSelector("#cg-bulk:not([hidden])");
    ok(/1 lesson selected/.test(await page.locator("#cg-sel").innerText()), tag + "the bar counts what is ticked");
    if (SC) await page.screenshot({ path: path.join(SC, "charges-bulk-" + mode + ".png") });
    await page.click("#cg-bfull"); await page.waitForSelector(".td-dlg");
    ok(/Charge the full price for 1 lesson \(S\$123\.45 in all\)/.test(await page.locator(".td-dlg").innerText()), tag + "bulk full price asks first, with the total in dollars");
    await page.click(".td-dlg [data-yes]"); await page.waitForSelector("#cg .ca-empty");
    const bulk = await calls(page, "staff_set_charges");
    ok(bulk.length === 1 && bulk[0].p_mode === "full" && bulk[0].p_lessons.length === 1 && bulk[0].p_lessons[0] === "q2", tag + "the bulk call sends the mode and the ids");
    ok(/Nothing waiting/.test(await page.locator("#cg-list").innerText()) && await page.locator("#cg-bulk").isHidden(), tag + "empty queue: its own message, no bulk bar");
    ok(await page.locator("#cg-badge").isHidden(), tag + "and the tab count disappears");
    ok(errs.length === 0, tag + "no console errors " + errs.join("|"));
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + "no sideways scroll");
    if (SC) await page.screenshot({ path: path.join(SC, "charges-empty-" + mode + ".png") });
    await ctx.close();
  }
  // bulk: select all, Not charged (0)
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")] });
    await page.goto(BASE + "centre-attendance.html?id=c1&tab=charges"); await page.waitForSelector(".cg-row");
    ok(await page.locator("#cg").isVisible() && await page.locator("#ca").isHidden(), "?tab=charges opens the Charges tab directly");
    await page.check("#cg-all"); await page.waitForSelector("#cg-bulk:not([hidden])");
    ok(/3 lessons selected/.test(await page.locator("#cg-sel").innerText()), "'Select all' ticks the page");
    await page.uncheck('[data-pick="q3"]'); ok(/2 lessons selected/.test(await page.locator("#cg-sel").innerText()), "one can be un-ticked again");
    await page.click("#cg-bzero"); await page.waitForSelector(".td-dlg");
    ok(/2 lessons as not charged \(S\$0\)/.test(await page.locator(".td-dlg").innerText()), "'Not charged (S$0)' asks first");
    await page.click(".td-dlg [data-no]"); await page.waitForTimeout(200);
    ok((await calls(page, "staff_set_charges")).length === 0, "cancelling the question sends nothing");
    await page.click("#cg-bzero"); await page.waitForSelector(".td-dlg"); await page.click(".td-dlg [data-yes]"); await page.waitForFunction(() => document.querySelectorAll(".cg-row").length === 1);
    const b = await calls(page, "staff_set_charges");
    ok(b.length === 1 && b[0].p_mode === "amount" && b[0].p_amount_cents === 0 && b[0].p_lessons.length === 2, "'Not charged' sends amount 0 for the two ticked lessons");
    await ctx.close(); }
  // staff with the timetable permission but NOT issue_invoices: the server says NOT_ALLOWED, so there is no Charges tab at all
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_students", "manage_timetable"])], chargesError: "NOT_ALLOWED: your account can't set charges at this centre" });
    await page.goto(BASE + "centre-attendance.html?id=c1&tab=charges"); await page.waitForTimeout(1200);
    ok(await page.locator("#ca-tabs").isHidden() && await page.locator("#cg").isHidden(), "centre.frontdesk-style staff (no issue_invoices): no Charges tab, even with ?tab=charges");
    ok(await page.locator("#ca").isVisible(), "…and the Lessons tab is simply shown");
    ok(await page.locator("#ca-tab-charges").isHidden(), "the tab button itself is hidden");
    await ctx.close(); }
  // charges function not on this database yet
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], chargesError: { code: "PGRST202", message: "Could not find the function public.staff_pending_charges" } });
    await page.goto(BASE + "centre-attendance.html?id=c1"); await page.waitForTimeout(1200);
    ok(await page.locator("#ca-tabs").isHidden() && await page.locator("#ca").isVisible(), "migration not applied: no tab, Lessons works as before"); await ctx.close(); }
  // staff holding ONLY issue_invoices: the Attendance menu item is there and so is the tab
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["issue_invoices"])], timetable: false });
    await page.goto(BASE + "centre-attendance.html?id=c1"); await page.waitForSelector("#ca-tabs:not([hidden])");
    const menu = (await page.locator(".tn-links a").filter({ visible: true }).allInnerTexts()).join("|");
    ok(/Attendance/.test(menu), "issue_invoices alone: the Attendance menu item is there (" + menu.replace(/\n/g, " ") + ")");
    await page.click("#ca-tab-charges"); await page.waitForSelector(".cg-row"); ok(await page.locator(".cg-row").count() === 3, "…and the queue opens"); await ctx.close(); }
  // the demo staff with manage_timetable only see nothing about charges on Home; the owner's Home tile opens the tab
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")] });
    await page.goto(BASE + "centre.html?id=c1"); await page.waitForSelector(".ch-tile");
    const a = page.locator("a.ch-tile", { hasText: "charges to confirm" });
    ok(await a.count() === 1 && /centre-attendance\?id=c1&tab=charges/.test(await a.getAttribute("href")), "Home: the 'charges to confirm' tile is a link to the Charges tab");
    await a.click(); await page.waitForSelector(".cg-row"); ok(await page.locator(".cg-row").count() === 3, "…and the link lands on the queue"); await ctx.close(); }
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_timetable"])], noCharges: true });
    await page.goto(BASE + "centre.html?id=c1"); await page.waitForSelector(".ch-tile");
    ok(await page.locator("a.ch-tile[href*=\"tab=charges\"]").count() === 0 && !/charge/.test(await page.locator("#ch").innerText()), "Home without issue_invoices: no charges tile at all"); await ctx.close(); }
  await browser.close();
  console.log(fails ? fails + " FAILED" : "all passed"); process.exit(fails ? 1 : 0);
})();
