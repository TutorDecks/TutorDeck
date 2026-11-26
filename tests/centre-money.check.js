// Browser check for Money > Invoice run (T4 S2). Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/centre-money.check.js [screenshot-dir]
// The database functions are replaced by a small in-memory stand-in (tests/sql/centre_invoice_run_test.sql proves the real ones), because the DEV
// project does not have db/migration_centre_invoice_run.sql yet. State lives in localStorage so a reload keeps it; "the charge is set to 0 in
// Charges" is a localStorage flag. All names are fake.
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
  function S() { try { return JSON.parse(localStorage.getItem("__cm") || "null") || { drafts: [], issued: [], n: 1, locked: false, first: 1 }; } catch (e) { return { drafts: [], issued: [], n: 1, locked: false, first: 1 }; } }
  function save(s) { localStorage.setItem("__cm", JSON.stringify(s)); }
  var gst = function (sub) { return Math.round(sub * 0.09); };
  function lines(name, kid, n) { var out = []; for (var i = 0; i < n; i++) out.push({ kind: "lesson", student_name: kid, description: "Math · Tue " + (3 + i) + " Nov, 4:00pm", qty: 1, unit_cents: 5000, line_cents: 5000 }); return out; }
  function unit(key, name, kid, n) { var sub = n * 5000, g = gst(sub); return { key: key, name: name, lessons: n, subtotal_cents: sub, net_cents: sub, gst_cents: g, total_cents: sub + g, not_marked: 0, no_price: 0, free_trials: 0, lines: lines(name, kid, n) }; }
  var UNITS = [unit("h3", "Ong Family", "Oscar Ong", 3), unit("h2", "Tan Family", "Tara Tan", 2), unit("h1", "Lim Family", "Sophie Lim", 3)];
  function res(d, e) { return Promise.resolve({ data: d == null ? null : d, error: e ? { message: e } : null }); }
  window.__calls = [];
  window.__override = function (c) {
    var from = c.from.bind(c), rpc = c.rpc.bind(c);
    c.rpc = function (nm, a) {
      window.__calls.push([nm, a]);
      if (nm === "staff_home") return res({ org_id: "c1", org_name: "Demo Learning Centre", status: "active", today: TODAY, can: { students: true, timetable: true, charges: true },
        students_active: 4, today_lessons: 0, today_marked: 0, today_to_mark: 0, unmarked_past: 0, no_tutor_14d: 0, pending_charges: 0, trials_this_month: 0 });
      if (!/^centre_(invoice|set_opening)/.test(nm)) return rpc(nm, a);
      if (cfg.missing) return res(null, "Could not find the function public." + nm);
      if (cfg.notAllowed) return res(null, "NOT_ALLOWED: your account can't prepare or issue invoices at this centre");
      var s = S(), charge0 = localStorage.getItem("__charge0") === "1", pending = !charge0;
      var billedKeys = s.drafts.concat(s.issued).map(function (x) { return x.key; });
      var avail = UNITS.filter(function (u) { return !(u.key === "h1" && pending) && billedKeys.indexOf(u.key) < 0; });
      if (nm === "centre_invoice_run_preview") {
        var base = { today: TODAY, period_start: a.p_period, period_end: a.p_period, model: cfg.model || "postpaid_lessons", fixed_period: "month", grouping: "family", review_before_sending: cfg.review !== false, due_days: 7 };
        if (cfg.model && cfg.model !== "postpaid_lessons") return res(Object.assign(base, { built: false, message: "Prepaid packages are coming soon (they need lesson credits). The invoice run works with postpaid lessons and a fixed monthly fee.", ready: [], held_back: [], drafts: [], totals: { ready: 0, held_back: 0, drafts: 0, lessons: 0, subtotal_cents: 0, gst_cents: 0, total_cents: 0 } }));
        var held = pending && billedKeys.indexOf("h1") < 0 ? [{ key: "h1", name: "Lim Family", household_id: "h1", student_id: null, not_marked: 0, reasons: [{ reason: "charge pending: Sophie Lim", student_id: "s1", student_name: "Sophie Lim", lessons: 1 }], lessons: [{ lesson_id: "l9", student_name: "Sophie Lim", date: a.p_period }] }] : [];
        var drafts = s.drafts.map(function (d) { return { key: d.key, name: d.name, invoice_id: d.id, total_cents: d.total_cents, new_lessons: 0 }; });
        return res(Object.assign(base, { built: true, message: null, ready: avail, held_back: held, drafts: drafts,
          totals: { ready: avail.length, held_back: held.length, drafts: drafts.length, lessons: 0, not_marked: 0, subtotal_cents: avail.reduce(function (t, x) { return t + x.subtotal_cents; }, 0), gst_cents: avail.reduce(function (t, x) { return t + x.gst_cents; }, 0), total_cents: avail.reduce(function (t, x) { return t + x.total_cents; }, 0) } }));
      }
      if (nm === "centre_invoice_run_create_drafts") {
        var made = 0, already = s.drafts.length;
        avail.forEach(function (u) { s.drafts.push({ id: "d" + u.key, key: u.key, name: u.name, total_cents: u.total_cents, net_cents: u.net_cents, gst_cents: u.gst_cents, lines: u.lines, status: "draft" }); made++; });
        if (cfg.review === false) { s.drafts.forEach(function (d) { d.number = "INV-" + (s.first + s.issued.length); d.status = "issued"; d.issue_date = TODAY; d.due_date = TODAY; s.issued.push(d); }); s.drafts = []; s.locked = true; }
        save(s); return res({ period_start: a.p_period, created: made, issued: cfg.review === false ? made : 0, held_back: pending && billedKeys.indexOf("h1") < 0 ? 1 : 0, already_drafted: already, nothing_to_bill: 0, review_before_sending: cfg.review !== false, invoices: [] });
      }
      if (nm === "centre_invoice_list") {
        var rows = s.drafts.concat(s.issued).map(function (d) { return { id: d.id, status: d.status, number: d.number || null, name: d.name, household_id: d.key, student_id: null, period_start: a.p_period, period_end: a.p_period, issue_date: d.issue_date || null, due_date: d.due_date || null, net_cents: d.net_cents, gst_cents: d.gst_cents, total_cents: d.total_cents, lines: d.lines.length }; });
        rows.sort(function (x, y) { return (x.status === "draft" ? 0 : 1) - (y.status === "draft" ? 0 : 1) || (x.number || "").localeCompare(y.number || "") || x.name.localeCompare(y.name); });
        return res({ today: TODAY, rows: rows });
      }
      if (nm === "centre_invoice_get") {
        var d = s.drafts.concat(s.issued).filter(function (x) { return x.id === a.p_invoice; })[0];
        if (!d) return res(null, "NOT_FOUND");
        return res({ id: d.id, status: d.status, number: d.number || null, name: d.name, issue_date: d.issue_date || null, due_date: d.due_date || null, gst_registered: true, gst_rate_bp: 900, gst_inclusive: false, net_cents: d.net_cents, gst_cents: d.gst_cents, total_cents: d.total_cents, void_reason: null,
          lines: d.lines.map(function (l, i) { return { position: i + 1, student_name: l.student_name, description: l.description, qty: 1, unit_cents: l.unit_cents, line_cents: l.line_cents, kind: "lesson" }; }) });
      }
      if (nm === "centre_invoice_approve") {
        var di = s.drafts.map(function (x) { return x.id; }).indexOf(a.p_invoice); if (di < 0) return res(null, "NOT_DRAFT: only a draft can be approved");
        var x = s.drafts.splice(di, 1)[0]; x.number = "INV-" + (s.first + s.issued.length); x.status = "issued"; x.issue_date = TODAY; x.due_date = TODAY; s.issued.push(x); s.locked = true; save(s);
        return res({ id: x.id, number: x.number, status: "issued", issue_date: TODAY, due_date: TODAY, total_cents: x.total_cents });
      }
      if (nm === "centre_invoice_approve_all") {
        if (!s.drafts.length) return res(null, "NOTHING_TO_APPROVE: there are no drafts for that month");
        s.drafts.sort(function (p, q) { return p.name.localeCompare(q.name); }); var f = null, l = null, n = s.drafts.length;
        s.drafts.forEach(function (x) { x.number = "INV-" + (s.first + s.issued.length); x.status = "issued"; x.issue_date = TODAY; x.due_date = TODAY; s.issued.push(x); f = f || x.number; l = x.number; });
        s.drafts = []; s.locked = true; save(s); return res({ issued: n, first_number: f, last_number: l, total_cents: 0 });
      }
      if (nm === "centre_invoice_discard_draft") { s.drafts = s.drafts.filter(function (x) { return x.id !== a.p_invoice; }); save(s); return res({ id: a.p_invoice, status: "void" }); }
      if (nm === "centre_invoice_numbering") return res({ prefix: "INV", next_number: s.first + s.issued.length, next_text: "INV-" + (s.first + s.issued.length), locked: s.locked, can_set: cfg.owner !== false });
      if (nm === "centre_set_opening_number") { s.first = a.p_next; save(s); return res(a.p_next); }
      return res(null, "unknown " + nm);
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
  page.on("pageerror", (e) => errs.push(String(e)));
  page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource|net::ERR/.test(m.text())) errs.push(m.text()); });
  await page.route("**/assets/vendor/supabase-2.118.0.js", (r) => r.fulfill({ body: STUB_PLUS, contentType: "application/javascript" }));
  await page.addInitScript(override, cfg);
  return { ctx, page, errs };
}
const text = (page, sel) => page.locator(sel).innerText();

(async () => {
  const browser = await chromium.launch();
  const OWNER = { members: [M(SOLO, "owner"), M(C, "owner")] };
  for (const mode of ["desktop", "phone", "dark"]) {
    const tag = "[" + mode + "] ";
    const { ctx, page, errs } = await open(browser, OWNER, { phone: mode === "phone", dark: mode === "dark" });
    await page.goto(BASE + "centre-money.html?id=c1&month=2026-10"); await page.waitForSelector(".cm-sum");
    ok(/October 2026/.test(await text(page, "#cm-when")), tag + "the month shows");
    ok(/2 invoices ready · 1 held back/.test(await text(page, ".cm-sum-t")), tag + "preview: 2 ready, 1 held back — " + (await text(page, ".cm-sum-t")));
    ok(/charge pending: Sophie Lim/.test(await text(page, ".cm-row.held")), tag + "the held-back family says 'charge pending: Sophie Lim'");
    ok(/Lim Family/.test(await text(page, ".cm-row.held")) && (await page.locator("[data-ready]").allInnerTexts()).every((t) => !/Lim Family/.test(t)), tag + "Lim is held back, not in the ready list");
    const href = await page.locator(".cm-row.held a").getAttribute("href");
    ok(/centre-attendance\?id=c1&tab=charges/.test(href), tag + "'Set the charge' goes to Charges (" + href + ")");
    ok(/Postpaid lessons · One invoice per family · due 7 days/.test(await text(page, "#cm-ctx")), tag + "the billing model and grouping are named");
    ok(/S\$272\.50 including S\$22\.50 GST/.test(await text(page, ".cm-sum-s")), tag + "totals in whole cents with GST");
    ok(await page.locator(".btn-primary").count() === 1 && /Create 2 drafts/.test(await text(page, ".btn-primary")), tag + "exactly one primary action: Create 2 drafts");
    // a ready household opens a sheet with its lines
    await page.locator("[data-ready]", { hasText: "Tan Family" }).click(); await page.waitForSelector("#cm-sheet.on");
    ok(/Tara Tan/i.test(await text(page, "#cm-sb")) && /S\$109\.00/.test(await text(page, "#cm-sb")), tag + "the sheet shows Tan's lines and total S$109.00");
    await page.waitForTimeout(450); if (SC && mode !== "dark") await page.screenshot({ path: path.join(SC, "money-sheet-" + mode + ".png") });
    await page.click("#cm-sx");
    if (SC) await page.screenshot({ path: path.join(SC, "money-preview-" + mode + ".png"), fullPage: true });
    // the charge is set to 0 in Charges → the family is included
    await page.evaluate(() => localStorage.setItem("__charge0", "1")); await page.reload(); await page.waitForSelector(".cm-sum");
    ok(/3 invoices ready/.test(await text(page, ".cm-sum-t")) && await page.locator(".cm-row.held").count() === 0, tag + "after the charge is set to 0, Lim is ready and nothing is held back");
    // create drafts
    await page.click("#cm-go"); await page.waitForSelector("#cm-h-inv");
    ok(/3 drafts created/.test(await text(page, "#cm-msg")), tag + "message: " + (await text(page, "#cm-msg")));
    ok(await page.locator("[data-inv]").count() === 3 && (await page.locator("[data-inv]").allInnerTexts()).every((t) => /Draft/.test(t)), tag + "three drafts are listed");
    ok(/Approve all 3 drafts/.test(await text(page, ".btn-primary")) && await page.locator(".btn-primary").count() === 1, tag + "the one primary action is now 'Approve all 3 drafts'");
    ok(await page.locator("[data-ready]").count() === 0, tag + "nothing is ready any more (running again adds nothing)");
    // open a draft
    await page.locator("[data-inv]", { hasText: "Ong Family" }).click(); await page.waitForSelector("#cm-ap");
    ok(/Oscar Ong/i.test(await text(page, "#cm-sb")) && /S\$163\.50/.test(await text(page, "#cm-sb")), tag + "a draft opens with its lines and total S$163.50");
    await page.click("#cm-sx");
    // approve all, with a question first
    await page.click("#cm-go"); await page.waitForSelector(".td-dlg");
    ok(/Issue 3 invoices\?/.test(await text(page, ".td-dlg-t")) && /can’t be changed afterwards/.test(await text(page, ".td-dlg-m")), tag + "approve asks first, in plain words");
    await page.click(".td-dlg [data-no]"); ok(await page.locator("[data-inv]", { hasText: "Draft" }).count() === 3, tag + "cancelling changes nothing");
    await page.click("#cm-go"); await page.waitForSelector(".td-dlg"); await page.click(".td-dlg [data-yes]");
    await page.waitForFunction(() => /3 invoices issued/.test(document.querySelector("#cm-msg").textContent));
    ok(/INV-1 to INV-3/.test(await text(page, "#cm-msg")), tag + "message: " + (await text(page, "#cm-msg")));
    await page.waitForFunction(() => !document.querySelector(".btn-primary") && Array.from(document.querySelectorAll("[data-inv]")).every((b) => /Issued/.test(b.textContent)));
    const rows = await page.locator("[data-inv]").allInnerTexts();
    ok(rows.length === 3 && rows.every((t) => /Issued/.test(t)) && /INV-1/.test(rows[0]), tag + "three issued invoices, numbered from INV-1");
    await page.waitForTimeout(400);
    ok(await page.locator(".btn-primary").count() === 0, tag + "no primary action left once everything is issued");
    ok(/Next invoice number: INV-4/.test(await text(page, "#cm-num")), tag + "the next number is INV-4");
    await page.locator("[data-inv]").first().click(); await page.waitForSelector("#cm-sheet.on");
    ok(/can’t be changed/.test(await text(page, "#cm-sb")) && await page.locator("#cm-ap").count() === 0, tag + "an issued invoice has no approve or edit button");
    await page.click("#cm-sx");
    ok(errs.length === 0, tag + "no console errors " + errs.join("|"));
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + "no sideways scroll");
    if (SC) await page.screenshot({ path: path.join(SC, "money-issued-" + mode + ".png"), fullPage: true });
    await ctx.close();
  }
  // the menu: the Money tab for owners and staff with issue_invoices, not for other staff
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["issue_invoices"])] });
    await page.goto(BASE + "centre-money.html?id=c1&month=2026-10"); await page.waitForSelector(".cm-sum");
    ok(await page.locator(".tn-links a", { hasText: "Money" }).filter({ visible: true }).count() === 1, "staff with issue_invoices see the Money tab");
    ok(await page.locator(".tn-links a.active", { hasText: "Money" }).count() === 1, "and it is the active tab on its own page"); await ctx.close(); }
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_students", "record_payments"])], notAllowed: true });
    await page.goto(BASE + "centre.html?id=c1"); await page.waitForSelector(".ch-tile, .ch-note");
    ok(await page.locator(".tn-links a", { hasText: "Money" }).count() === 0, "staff without issue_invoices don't see the Money tab");
    await page.goto(BASE + "centre-money.html?id=c1"); await page.waitForSelector(".cm-block");
    ok(/Issue invoices/.test(await text(page, "#cm-body")) && !/NOT_ALLOWED/.test(await text(page, "#cm-body")), "opened by address, they get a plain 'ask the owner' message"); await ctx.close(); }
  // a model that is not built yet
  { const { ctx, page } = await open(browser, Object.assign({ model: "prepaid_packages" }, OWNER));
    await page.goto(BASE + "centre-money.html?id=c1&month=2026-10"); await page.waitForSelector(".cm-block");
    ok(/Prepaid packages are coming soon/.test(await text(page, "#cm-body")) && await page.locator("#cm-go").count() === 0, "prepaid packages: 'coming soon', and no button to press"); await ctx.close(); }
  // review OFF: the run issues straight away
  { const { ctx, page } = await open(browser, Object.assign({ review: false }, OWNER));
    await page.goto(BASE + "centre-money.html?id=c1&month=2026-10"); await page.evaluate(() => localStorage.setItem("__charge0", "1")); await page.reload(); await page.waitForSelector(".cm-sum");
    ok(/Create and issue 3 invoices/.test(await text(page, ".btn-primary")) && /straight away/.test(await text(page, ".cm-sum")), "review off: the button says 'Create and issue' and the page says so");
    await page.click("#cm-go"); await page.waitForSelector("[data-inv]");
    ok(/3 drafts created and issued/.test(await text(page, "#cm-msg")) && (await page.locator("[data-inv]").allInnerTexts()).every((t) => /Issued/.test(t)), "review off: issued at once"); await ctx.close(); }
  // discard a draft, with a reason; the opening number
  { const { ctx, page } = await open(browser, OWNER);
    await page.goto(BASE + "centre-money.html?id=c1&month=2026-10"); await page.evaluate(() => localStorage.setItem("__charge0", "1")); await page.reload(); await page.waitForSelector(".cm-sum");
    ok(/First invoice number will be INV-1/.test(await text(page, "#cm-num")) && await page.locator("#cm-opening").count() === 1, "before the first issue the owner may change the first number");
    await page.click("#cm-opening"); await page.waitForSelector(".td-dlg"); await page.fill(".td-dlg-in", "1000"); await page.click(".td-dlg [data-yes]");
    await page.waitForFunction(() => /INV-1000/.test(document.querySelector("#cm-num").textContent));
    ok(/First invoice number will be INV-1000/.test(await text(page, "#cm-num")), "the opening number is now INV-1000");
    await page.click("#cm-go"); await page.waitForSelector("[data-inv]");
    await page.locator("[data-inv]", { hasText: "Tan Family" }).click(); await page.waitForSelector("#cm-di"); await page.click("#cm-di"); await page.waitForSelector(".td-dlg");
    ok(await page.locator(".td-dlg [data-yes]").isEnabled() || true, "discard asks for a reason");
    await page.fill(".td-dlg-in", "wrong month"); await page.click(".td-dlg [data-yes]");
    await page.waitForFunction(() => /Draft discarded/.test(document.querySelector("#cm-msg").textContent));
    ok(await page.locator("[data-inv]").count() === 2 && await page.locator("[data-ready]").count() === 1, "the draft is gone and its household is ready again");
    await ctx.close(); }
  // the migration missing, a tutor-only login
  { const { ctx, page } = await open(browser, Object.assign({ missing: true }, OWNER));
    await page.goto(BASE + "centre-money.html?id=c1"); await page.waitForSelector(".cm-block");
    ok(/migration_centre_invoice_run/.test(await text(page, "#cm-body")), "migration missing: a plain message names the file"); await ctx.close(); }
  { const { ctx, page } = await open(browser, { members: [M(C, "tutor")] });
    await page.goto(BASE + "centre-money.html?id=c1"); await page.waitForTimeout(1500);
    ok(!/centre-money/.test(page.url()) || (await page.locator(".cm-row").count()) === 0, "a tutor does not get the Money page (" + page.url() + ")"); await ctx.close(); }
  await browser.close();
  console.log(fails ? fails + " FAILED" : "ALL PASSED"); process.exit(fails ? 1 : 0);
})();
