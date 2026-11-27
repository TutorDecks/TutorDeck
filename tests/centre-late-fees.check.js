// Browser check for Money > Late fees (T4 step S6). Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/centre-late-fees.check.js [screenshot-dir]
// The database functions are replaced by a small in-memory stand-in (tests/sql/centre_late_fees_test.sql proves the real ones), because the DEV project does not
// have db/migration_centre_late_fees.sql yet. State lives in localStorage so a reload keeps it. Runs on desktop, at 390px and in dark mode. All names are fake.
// The click-through of the plan's S6 row: three fees are waiting · open one and read how it was worked out · approve (it asks first; it becomes an invoice) ·
// waive (a reason is required; staff who may not waive are told so) · approve all · pressing approve twice gives the same invoice · nothing waiting says why.
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
  function fresh() {
    var f = cfg.empty ? [] : [
      { id: "f1", invoice_id: "i1", invoice_number: "INV-2", name: "Aw Family", month_no: 1, fee_date: "2026-10-16", fee_cents: 1000, base_cents: null, type: "fixed", repeat: "monthly", invoice_due_date: "2026-10-08", invoice_total_cents: 20000, balance_cents: 20000, days_late: 50 },
      { id: "f2", invoice_id: "i1", invoice_number: "INV-2", name: "Aw Family", month_no: 2, fee_date: "2026-11-16", fee_cents: 1000, base_cents: null, type: "fixed", repeat: "monthly", invoice_due_date: "2026-10-08", invoice_total_cents: 20000, balance_cents: 20000, days_late: 50 },
      { id: "f3", invoice_id: "i2", invoice_number: "INV-4", name: "Bee Family", month_no: 1, fee_date: TODAY, fee_cents: 750, base_cents: 15000, type: "percent", repeat: "monthly", invoice_due_date: "2026-11-19", invoice_total_cents: 20000, balance_cents: 15000, days_late: 8 }
    ];
    f.forEach(function (x) { x.gst_cents = Math.round(x.fee_cents * 0.09); x.total_cents = x.fee_cents + x.gst_cents; });
    return { waiting: f, recent: [], n: 30 };
  }
  function S() { try { return JSON.parse(localStorage.getItem("__lf") || "null") || fresh(); } catch (e) { return fresh(); } }
  function save(s) { localStorage.setItem("__lf", JSON.stringify(s)); }
  function res(d, e) { return Promise.resolve({ data: d == null ? null : d, error: e ? { message: e } : null }); }
  window.__calls = [];
  window.__override = function (c) {
    var from = c.from.bind(c), rpc = c.rpc.bind(c);
    c.rpc = function (nm, a) {
      window.__calls.push([nm, a]);
      if (nm === "staff_home") return res({ org_id: "c1", org_name: "Demo Learning Centre", status: "active", today: TODAY, can: { students: true, timetable: true, charges: true }, students_active: 4, today_lessons: 0 });
      if (!/^centre_late_fee/.test(nm)) return rpc(nm, a);
      if (cfg.missing) return res(null, "Could not find the function public." + nm);
      if (cfg.denied) return res(null, "NOT_ALLOWED: your account can't issue credit notes or share invoices at this centre");
      var s = S();
      if (nm === "centre_late_fee_list") {
        return res({ today: TODAY, enabled: cfg.enabled !== false, note: cfg.note || null, repeat: "monthly", can: { approve: true, waive: cfg.canWaive !== false, waived_by: cfg.canWaive === false ? "owner" : "issue_invoices" },
          waiting_count: s.waiting.length, waiting_cents: s.waiting.reduce(function (t, x) { return t + x.fee_cents; }, 0), waiting: s.waiting, recent: s.recent });
      }
      function take(id) { var i = s.waiting.findIndex(function (x) { return x.id === id; }); return i < 0 ? null : s.waiting.splice(i, 1)[0]; }
      if (nm === "centre_late_fee_approve") {
        var done = s.recent.filter(function (r) { return r.id === a.p_fee; })[0];
        if (done) return res({ id: a.p_fee, status: "approved", already: true, number: done.document_number, total_cents: done.fee_cents });
        var x = take(a.p_fee); if (!x) return res(null, "INVOICE_SETTLED: that invoice has been paid or credited, so no late fee is due");
        var no = "INV-" + (s.n++); s.recent.unshift({ id: x.id, invoice_number: x.invoice_number, name: x.name, month_no: x.month_no, status: "approved", fee_cents: x.fee_cents, decided_at: TODAY + "T04:00:00Z", document_number: no });
        save(s); return res({ id: x.id, status: "approved", already: false, number: no, total_cents: x.total_cents });
      }
      if (nm === "centre_late_fee_approve_all") {
        var n = s.waiting.length, tot = 0; s.waiting.slice().forEach(function (w) { var y = take(w.id); tot += y.total_cents; s.recent.unshift({ id: y.id, invoice_number: y.invoice_number, name: y.name, month_no: y.month_no, status: "approved", fee_cents: y.fee_cents, decided_at: TODAY + "T04:00:00Z", document_number: "INV-" + (s.n++) }); });
        save(s); return res({ approved: n, skipped: 0, total_cents: tot });
      }
      if (nm === "centre_late_fee_waive") {
        if (!a.p_reason || !String(a.p_reason).trim()) return res(null, "REASON_REQUIRED: say why this late fee is being waived");
        var z = take(a.p_fee); if (!z) return res({ id: a.p_fee, status: "waived", already: true });
        s.recent.unshift({ id: z.id, invoice_number: z.invoice_number, name: z.name, month_no: z.month_no, status: "waived", fee_cents: z.fee_cents, decided_at: TODAY + "T04:00:00Z", reason: a.p_reason });
        save(s); return res({ id: z.id, status: "waived", already: false, fee_cents: z.fee_cents });
      }
      return res(null, "Could not find the function public." + nm);
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
  const ctx = await browser.newContext({ viewport: opt.phone ? { width: 390, height: 780 } : { width: 1280, height: 800 } });
  await ctx.addInitScript((t) => { try { if (t) localStorage.setItem("td_theme", t); } catch (e) {} }, opt.dark ? "dark" : "");
  await ctx.route(/^(?!http:\/\/127\.0\.0\.1).*/, (r) => r.abort());
  const page = await ctx.newPage(), errs = [];
  page.on("pageerror", (e) => errs.push(String(e) + (process.env.STACK ? " " + e.stack : "")));
  page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource|net::ERR/.test(m.text())) errs.push(m.text()); });
  await page.route("**/assets/vendor/supabase-2.118.0.js", (r) => r.fulfill({ body: STUB_PLUS, contentType: "application/javascript" }));
  await page.addInitScript(override, cfg);
  return { ctx, page, errs };
}
const text = (page, sel) => page.locator(sel).innerText();
const noScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
const calls = (page, nm) => page.evaluate((n) => window.__calls.filter((c) => c[0] === n).length, nm);

(async () => {
  const browser = await chromium.launch();
  for (const mode of ["desktop", "phone", "dark"]) {
    const tag = "[" + mode + "] ";
    const { ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")] }, { phone: mode === "phone", dark: mode === "dark" });
    await page.goto(BASE + "centre-money.html?id=c1&tab=latefees"); await page.waitForSelector("#cl-list [data-i]");
    ok(await page.locator("#cm-tab-late").count() === 1 && /Late fees/.test(await text(page, "#cm-tab-late")), tag + "there is a Late fees tab");
    ok((await page.getAttribute("#cm-tab-late", "aria-selected")) === "true", tag + "it opens from ?tab=latefees");
    ok(/Late fees waiting for you/i.test(await text(page, "#cl-list")) && await page.locator("#cl-list [data-i]").count() === 3, tag + "'Late fees waiting for you' lists the three proposals");
    ok(/3 late fees waiting · S\$27\.50/.test(await text(page, "#cl-sum")), tag + "the summary adds them up: " + (await text(page, "#cl-sum")).split("\n")[1]);
    ok(/nothing reaches a family until you approve it/i.test(await text(page, "#cl-sum")), tag + "it says nothing reaches a family without approval");
    ok(await noScroll(page), tag + "no sideways scroll");
    if (SC) await page.screenshot({ path: path.join(SC, "late-fees-list-" + mode + ".png"), fullPage: true });
    // ---- open one: how it was worked out, with GST; ONE primary action
    await page.locator("#cl-list [data-i]", { hasText: "Bee Family" }).click(); await page.waitForSelector("#cl-ap");
    const sb = (await text(page, "#cm-sb")).replace(/\s+/g, " ");
    ok(/S\$7\.50 \+ S\$0\.68 GST = S\$8\.18/.test(sb) && /percentage of the S\$150\.00 still unpaid/.test(sb), tag + "the sheet shows the sum, GST and the unpaid balance it was taken on");
    ok(await page.locator("#cm-sb .btn-primary").count() === 1 && /Approve/.test(await text(page, "#cl-ap")), tag + "one primary action: Approve");
    ok(/credit note/.test(sb) || /its own number/.test(sb), tag + "it says an approved fee is its own invoice");
    await page.waitForTimeout(450);
    if (SC) await page.screenshot({ path: path.join(SC, "late-fees-sheet-" + mode + ".png") });
    // ---- waive: a reason is required
    await page.click("#cl-wv"); await page.waitForSelector(".td-dlg-in");
    await page.click(".td-dlg [data-yes]");
    await page.waitForFunction(() => /Please say why/.test(document.querySelector("#cl-msg").textContent));
    ok((await calls(page, "centre_late_fee_waive")) === 0, tag + "an empty reason is stopped on the page: nothing was sent");
    await page.click("#cl-wv"); await page.waitForSelector(".td-dlg-in"); await page.fill(".td-dlg-in", "Family hardship"); await page.click(".td-dlg [data-yes]");
    await page.waitForFunction(() => document.querySelectorAll("#cl-list [data-i]").length === 2);
    ok((await calls(page, "centre_late_fee_waive")) === 1, tag + "one waive was sent with the reason");
    ok(/Waived/.test(await text(page, "#cl-list")) && /Family hardship/.test(await text(page, "#cl-list")), tag + "it moves to 'Decided' with its reason");
    await page.waitForFunction(() => !document.querySelector(".owe-sheet.on"));
    // ---- approve one: it asks first
    await page.locator("#cl-list [data-i]", { hasText: "month 1" }).first().click(); await page.waitForSelector("#cl-ap");
    await page.click("#cl-ap"); await page.waitForSelector(".td-dlg");
    ok(/Add this late fee to the family’s account\?/.test(await text(page, ".td-dlg-t")) && /INV-2 · Aw Family/.test(await text(page, ".td-dlg-m")), tag + "it asks first and names the invoice");
    await page.click(".td-dlg [data-yes]");
    await page.waitForFunction(() => document.querySelectorAll("#cl-list [data-i]").length === 1);
    ok(/Added to the family’s account as INV-30/.test(await text(page, "#cl-list")), tag + "approved: it is now invoice INV-30 on the account");
    // ---- one left: no 'approve all' button for a single fee
    ok(await page.locator("#cl-all").count() === 0, tag + "with one fee left there is no Approve all button");
    ok(await noScroll(page), tag + "still no sideways scroll");
    if (SC) await page.screenshot({ path: path.join(SC, "late-fees-after-" + mode + ".png"), fullPage: true });
    ok(errs.length === 0, tag + "no console errors" + (errs.length ? ": " + errs.join(" | ") : ""));
    await ctx.close();
  }
  // ---- approve all (and a double press asks and sends only once)
  {
    const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")] }, { phone: true });
    await page.goto(BASE + "centre-money.html?id=c1&tab=latefees"); await page.waitForSelector("#cl-all");
    ok(/Approve all 3/.test(await text(page, "#cl-all")) && await page.locator("#cl-sum .btn-primary").count() === 1, "phone: 'Approve all 3' is the one primary action");
    await page.click("#cl-all"); await page.waitForSelector(".td-dlg");
    ok(/Approve all 3 late fees\?/.test(await text(page, ".td-dlg-t")) && /S\$27\.50 before GST/.test(await text(page, ".td-dlg-m")), "approve all asks first and says the total");
    await page.click(".td-dlg [data-yes]"); await page.waitForFunction(() => document.querySelectorAll("#cl-list [data-i]").length === 0);
    ok((await calls(page, "centre_late_fee_approve_all")) === 1 && /No late fees waiting/.test(await text(page, "#cl-sum")), "all approved with one request; nothing waiting afterwards");
    ok(/Decided/i.test(await text(page, "#cl-list")) && (await page.locator("#cl-list .cm-row").count()) === 3, "the three appear under Decided");
    await ctx.close();
  }
  // ---- a person who may not waive is told so, and the button is off
  {
    const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["issue_invoices"])], canWaive: false }, { phone: true });
    await page.goto(BASE + "centre-money.html?id=c1&tab=latefees"); await page.waitForSelector("#cl-list [data-i]");
    await page.locator("#cl-list [data-i]").first().click(); await page.waitForSelector("#cl-wv");
    ok(await page.locator("#cl-wv").isDisabled() && /Only the centre owner can waive/.test(await text(page, "#cm-sb")), "staff who can't waive: the button is off and the page says who can");
    ok(await page.locator("#cl-ap").isEnabled(), "...but they can still approve");
    await ctx.close();
  }
  // ---- nothing waiting, and switched off
  {
    const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], empty: true }, { phone: true });
    await page.goto(BASE + "centre-money.html?id=c1&tab=latefees"); await page.waitForSelector("#cl-sum .cm-sum-s");
    await page.waitForFunction(() => /No late fees waiting/.test(document.querySelector("#cl-sum").textContent));
    ok(/Nothing is ever added to a family’s bill without you/.test(await text(page, "#cl-list")), "an empty list explains when a fee appears");
    await ctx.close();
  }
  {
    const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], empty: true, enabled: false, note: "Late fees are switched off for this centre (Centre settings). Proposals made earlier still wait here." }, { phone: true });
    await page.goto(BASE + "centre-money.html?id=c1&tab=latefees"); await page.waitForFunction(() => /switched off/.test(document.querySelector("#cm-late").textContent));
    ok(/switched off for this centre/.test(await text(page, "#cl-list")) && /switched off/.test(await text(page, "#cl-sum")), "switched off: the page says so");
    await ctx.close();
  }
  {
    const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], missing: true });
    await page.goto(BASE + "centre-money.html?id=c1&tab=latefees"); await page.waitForSelector("#cm-late .cm-block");
    ok(/migration_centre_late_fees\.sql/.test(await text(page, "#cm-late")), "functions missing: the page says which migration to run"); await ctx.close();
  }
  {
    const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["record_payments"])], denied: true });
    await page.goto(BASE + "centre-money.html?id=c1&tab=latefees"); await page.waitForSelector("#cm-late .cm-block");
    ok(/Issue invoices/.test(await text(page, "#cm-late")), "staff without issue_invoices: the page names the permission to ask for"); await ctx.close();
  }
  await browser.close(); console.log(fails ? fails + " FAILED" : "ALL PASS"); process.exit(fails ? 1 : 0);
})();
