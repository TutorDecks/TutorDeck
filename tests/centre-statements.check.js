// Browser check for Money > Statements (T34 M0-M2). Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/centre-statements.check.js [screenshot-dir]
// The database functions are replaced by a small in-memory stand-in (tests/sql/statement_matching_test.sql proves the real ones; the stand-in applies the same
// rules through assets/js/statement-core.js score()), because the DEV project does not have db/migration_statement_matching.sql yet. State lives in localStorage so a
// reload keeps it. Runs on desktop, at 390px and in dark mode. The file is an invented layout ("layout assumed, not a real export"); every name is fake.
// The click-through of the plan's M2 row: upload a file in an unusual layout · the columns are guessed and checked in a preview · fix a wrong date format in the
// preview · import · one line pays itself, one waits with its reason · confirm it · a second upload says "N already imported (skipped)" · undo with a reason ·
// choose another invoice · "not ours" · forget a payer.
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
const STUB_PLUS = STUB + `;(function(){var o=window.supabase.createClient;window.supabase.createClient=function(){var c=o.apply(this,arguments);if(window.__override)window.__override(c);return c;};})();`;
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
const SOLO = { id: "s1", kind: "solo", trading_name: "Empty Shell" }, C = { id: "c1", kind: "centre", trading_name: "Demo Learning Centre" };
const M = (o, role, permissions) => ({ org_id: o.id, user_id: "u1", role, status: "active", permissions: permissions || [], organisations: o });

function day(n) { const d = new Date(Date.now() - new Date().getTimezoneOffset() * 60000 + n * 86400000); return d.toISOString().slice(0, 10); }
function text(n) { const d = day(n), M = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]; return +d.slice(8, 10) + " " + M[+d.slice(5, 7) - 1] + " " + d.slice(0, 4); }
// an invented layout: semicolons, two header lines above the table, money out / money in columns, "5 Nov 2026" dates, a quoted field with a comma
const CSV = ["Account;000-000000-0 (fake)", "Statement (layout assumed, not a real export);", "Posting date;Particulars;Money out;Money in;Sender;Txn id",
  text(-2) + ';"PAYNOW INV-1, school fees";;100.00;LIM MEI;T1', text(-1) + ";PAYNOW fees;;30.00;TAN AH KOW;T2", text(-1) + ";FAST to supplier;45.00;;;T3", ""].join("\r\n");

function override(cfg) {
  var TODAY = new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 10);
  function ago(n) { return new Date(Date.now() - new Date().getTimezoneOffset() * 60000 - n * 86400000).toISOString().slice(0, 10); }
  function fresh() {
    return { n: 1, fps: {}, lines: [], matches: [], payers: [], batches: [], mappings: [], seq: 1,
      inv: [{ id: "i1", number: "INV-1", hid: "h1", hname: "Lim Family", issue: ago(3), due: ago(-4), bal: 10000 }, { id: "i2", number: "INV-2", hid: "h1", hname: "Lim Family", issue: ago(3), due: ago(-4), bal: 5000 },
        { id: "i3", number: "INV-3", hid: "h2", hname: "Tan Family", issue: ago(3), due: ago(-4), bal: 3000 }] };
  }
  function S() { try { return JSON.parse(localStorage.getItem("__st") || "null") || fresh(); } catch (e) { return fresh(); } }
  function save(s) { localStorage.setItem("__st", JSON.stringify(s)); }
  function res(d, e) { return Promise.resolve({ data: d == null ? null : d, error: e ? { message: e } : null }); }
  function norm(t) { return String(t || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").replace(/\s+/g, " ").trim(); }
  function id(s, p) { return p + (s.seq++); }
  window.__calls = [];
  window.__override = function (c) {
    var from = c.from.bind(c), rpc = c.rpc.bind(c);
    c.rpc = function (nm, a) {
      window.__calls.push([nm, a]);
      if (nm === "staff_home") return res({ org_id: "c1", org_name: "Demo Learning Centre", status: "active", today: TODAY, can: { students: true, timetable: true, charges: true }, students_active: 4, today_lessons: 0 });
      if (!/^stmt_/.test(nm)) return rpc(nm, a);
      if (cfg.missing) return res(null, "Could not find the function public." + nm);
      if (cfg.off) return res(null, "NOT_ALLOWED: bank statement matching isn't switched on in this centre's payment settings");
      if (cfg.denied) return res(null, "NOT_ALLOWED: your account can't record or reverse payments at this centre");
      var s = S(), SCx = window.StatementCore;
      function ctx() { var links = {}; s.payers.forEach(function (p) { links[p.key] = p.hid; }); return { today: TODAY, settings: { auto_confirm: "exact_only", window_before_days: 7, window_after_days: 90 }, links: links, invoices: s.inv }; }
      function invOf(i) { return { id: i.id, number: i.number, balance_cents: i.bal, due_date: i.due, household: i.hname }; }
      function apply(l, ids, rule, auto, remember) {
        var rem = l.cents, alloc = [], inv = ids.map(function (x) { return s.inv.filter(function (v) { return v.id === x; })[0]; }).filter(Boolean).sort(function (p, q) { return p.issue < q.issue ? -1 : 1; });
        inv.forEach(function (v) { var t = Math.min(rem, v.bal); if (t > 0) { v.bal -= t; rem -= t; alloc.push({ invoice_id: v.id, number: v.number, cents: t }); } });
        var hh = inv[0].hid, mid = id(s, "m");
        s.matches.unshift({ id: mid, line_date: l.line_date, cents: l.cents, kind: "invoice", rule: rule, auto: auto, confirmed_at: TODAY + "T04:00:00Z", reversed: false, household: inv[0].hname, invoices: alloc.map(function (x) { return x.number; }), alloc: alloc, fp: l.fp, occ: 1 });
        var pk = norm(l.payer_text); if (pk && (remember || (auto && rule === "payer_link")) && !s.payers.some(function (p) { return p.key === pk; })) s.payers.push({ id: id(s, "p"), key: pk, hid: hh, hname: inv[0].hname, used: 1, last: TODAY });
        s.lines = s.lines.filter(function (x) { return x.id !== l.id; });
        return { match_id: mid, payment_id: "pay" + mid, allocated: alloc, excess_cents: rem, rule: rule, auto: auto };
      }
      if (nm === "stmt_queue") {
        var rv = s.lines.map(function (l) { return Object.assign({}, l, { invoices: (l.ids || []).map(function (x) { return invOf(s.inv.filter(function (v) { return v.id === x; })[0]); }) }); });
        return res({ settings: { auto_confirm: "exact_only", window_before_days: 7, window_after_days: 90, partial_payments: true, overpayments: "credit" }, review_total: s.lines.length, review: rv, matched: s.matches,
          batches: s.batches, payers: s.payers.map(function (p) { return { id: p.id, payer: p.key, household: p.hname, times_used: p.used, last_used: p.last }; }),
          mappings: s.mappings, open_invoices: s.inv.filter(function (v) { return v.bal > 0; }).map(invOf) });
      }
      if (nm === "stmt_save_mapping") { var mid = id(s, "mp"); s.mappings = s.mappings.filter(function (x) { return x.name !== a.p_name; }); s.mappings.push({ id: mid, name: a.p_name, version: 1, mapping: a.p_mapping }); save(s); return res({ mapping_id: mid, name: a.p_name, version: 1 }); }
      function fpOf(acct, x) { return [acct.toLowerCase(), x.date, x.cents, norm(x.ref), String(x.bank_ref || "").toLowerCase()].join("|"); }
      if (nm === "stmt_check") { var seen = {}, known = 0; a.p_lines.forEach(function (x) { var f = fpOf(a.p_account, x); seen[f] = (seen[f] || 0) + 1; if (s.fps[f + "#" + seen[f]]) known++; }); return res({ lines: a.p_lines.length, known: known, new: a.p_lines.length - known }); }
      if (nm === "stmt_import") {
        var occ = {}, nnew = 0, dup = 0, auto = 0, rev = 0;
        a.p_lines.forEach(function (x) {
          var f = fpOf(a.p_account, x); occ[f] = (occ[f] || 0) + 1;
          if (s.fps[f + "#" + occ[f]] || x.cents === 0) { dup++; return; }
          s.fps[f + "#" + occ[f]] = 1; nnew++;
          var l = { id: id(s, "l"), line_date: x.date, cents: x.cents, ref_text: x.ref || null, payer_text: x.payer || null, bank_ref: x.bank_ref || null, row_no: x.row, stub: false, fp: f };
          var r = SCx.score({ date: x.date, cents: x.cents, ref: x.ref, payer: x.payer }, ctx());
          l.rule = r.rule; l.exact = r.exact; l.reason = r.reason; l.ids = r.ids; l.household = null; s.lines.push(l);
          if (r.auto) { apply(l, r.ids, r.rule, true, false); auto++; }
        });
        rev = s.lines.length; s.batches.unshift({ id: id(s, "b"), account: a.p_account, date_from: a.p_lines[0].date, date_to: a.p_lines[a.p_lines.length - 1].date, lines: a.p_lines.length, new: nnew, duplicates: dup, skipped: 0, auto: auto, review: rev, imported_at: TODAY + "T04:00:00Z" });
        save(s); return res({ batch_id: "b", lines: a.p_lines.length, new: nnew, duplicates: dup, skipped: 0, auto_matched: auto, to_review: rev });
      }
      if (nm === "stmt_confirm") {
        var l = s.lines.filter(function (x) { return x.id === a.p_line; })[0]; if (!l) return res(null, "NOT_FOUND");
        var ids = a.p_invoice_ids && a.p_invoice_ids.length ? a.p_invoice_ids : l.ids; if (!ids || !ids.length) return res(null, "BAD_VALUE: choose the invoice this payment is for");
        var r2 = apply(l, ids, a.p_invoice_ids ? "manual" : (l.rule || "manual"), false, a.p_remember); save(s); return res(r2);
      }
      if (nm === "stmt_ignore") { var l2 = s.lines.filter(function (x) { return x.id === a.p_line; })[0]; if (!l2) return res(null, "NOT_FOUND"); s.lines = s.lines.filter(function (x) { return x !== l2; });
        s.matches.unshift({ id: id(s, "m"), line_date: l2.line_date, cents: l2.cents, kind: "ignored", rule: "manual", auto: false, reversed: false, invoices: [], fp: l2.fp }); save(s); return res({ match_id: "x" }); }
      if (nm === "stmt_ignore_out") { var out = s.lines.filter(function (x) { return x.cents < 0; }); out.forEach(function (l3) { s.matches.unshift({ id: id(s, "m"), line_date: l3.line_date, cents: l3.cents, kind: "ignored", rule: "manual", auto: false, reversed: false, invoices: [], fp: l3.fp }); });
        s.lines = s.lines.filter(function (x) { return x.cents > 0; }); save(s); return res({ ignored: out.length }); }
      if (nm === "stmt_undo") {
        var m = s.matches.filter(function (x) { return x.id === a.p_match; })[0]; if (!m) return res(null, "NOT_FOUND"); if (m.reversed) return res({ already: true });
        if (!a.p_reason || !String(a.p_reason).trim()) return res(null, "REASON_REQUIRED: say why you are undoing this match");
        (m.alloc || []).forEach(function (al) { s.inv.filter(function (v) { return v.id === al.invoice_id; })[0].bal += al.cents; }); m.reversed = true;
        s.lines.push({ id: id(s, "l"), line_date: m.line_date, cents: m.cents, ref_text: null, payer_text: null, bank_ref: null, stub: true, rule: null, exact: false, ids: [], reason: "Put back after an undo: only the date and amount are kept.", fp: m.fp });
        save(s); return res({ match_id: m.id, payment_already_reversed: false });
      }
      if (nm === "stmt_forget_payer") { s.payers = s.payers.filter(function (p) { return p.id !== a.p_link; }); save(s); return res({ forgotten: true }); }
      if (nm === "stmt_rematch") return res({ auto_matched: 0, to_review: s.lines.length });
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
const text2 = (page, sel) => page.locator(sel).innerText();
const noScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
const calls = (page, nm) => page.evaluate((n) => window.__calls.filter((c) => c[0] === n).length, nm);
const file = (page) => page.setInputFiles("#st-file", { name: "export.csv", mimeType: "text/csv", buffer: Buffer.from(CSV) });
const settle = (page) => page.waitForFunction(() => !document.querySelector(".owe-sheet.on"));

(async () => {
  const browser = await chromium.launch();
  for (const mode of ["desktop", "phone", "dark"]) {
    const tag = "[" + mode + "] ";
    const { ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")] }, { phone: mode === "phone", dark: mode === "dark" });
    await page.goto(BASE + "centre-money.html?id=c1&tab=statements"); await page.waitForSelector("#st-up");
    ok((await page.getAttribute("#cm-tab-stmt", "aria-selected")) === "true" && /Statements/.test(await text2(page, "#cm-tab-stmt")), tag + "there is a Statements tab and ?tab=statements opens it");
    ok(/Nothing is waiting for you/.test(await text2(page, "#st-sum")) && await page.locator("#st-sum .btn-primary").count() === 1, tag + "empty: one primary action, Upload a statement");
    ok(/read on this device/.test(await text2(page, "#st-sum")) && /deleted once a line is settled/.test(await text2(page, "#st-sum")), tag + "it says the file stays on the device and the text is deleted");
    // ---- upload: columns guessed, preview shown
    await page.click("#st-up"); await page.waitForSelector("#st-file"); await file(page); await page.waitForSelector("#st-prev .st-tbl");
    const prev = (await text2(page, "#st-prev")).replace(/\s+/g, " ");
    ok(/3 lines/.test(prev) && /money in S\$130\.00 \(2\)/.test(prev) && /money out S\$45\.00 \(1\)/.test(prev), tag + "the preview: 3 lines, money in S$130.00, money out S$45.00 (" + prev.slice(0, 120) + ")");
    ok(/PAYNOW INV-1, school fees/.test(prev) && /S\$100\.00/.test(prev), tag + "a quoted field with a comma, and the date and amount, are read correctly");
    ok(await page.inputValue("#st-delim") === ";" && await page.inputValue("#st-dfmt") === "dmy_text" && await page.inputValue("#st-amode") === "debit_credit" && await page.inputValue("#st-hdr") === "3", tag + "the guess: semicolons, '5 Nov 2026' dates, money out / in columns, 3 rows above the table");
    await page.waitForFunction(() => /None of these lines were uploaded before/.test(document.querySelector("#st-known").textContent));
    ok(await noScroll(page), tag + "no sideways scroll on the upload screen");
    if (SC) await page.screenshot({ path: path.join(SC, "statements-upload-" + mode + ".png"), fullPage: true });
    // ---- a wrong date format is caught in the preview and blocks the import
    await page.selectOption("#st-dfmt", "iso"); await page.waitForSelector("#st-prev .cm-note.err");
    ok(/rows? don.t read correctly/.test(await text2(page, "#st-prev")) && /Row 4: the date/.test(await text2(page, "#st-prev")) && await page.locator("#st-go").isDisabled(), tag + "a wrong date format: the row is named and Import is off");
    await page.selectOption("#st-dfmt", "dmy_text"); await page.waitForFunction(() => !document.querySelector("#st-go").disabled);
    ok(/Import 3 lines/.test(await text2(page, "#st-go")), tag + "fixed: the button says Import 3 lines");
    ok(await page.locator("#st-main .btn-primary").count() === 1, tag + "one primary action on the upload screen");
    await page.fill("#st-sname", "Bank X export"); await page.click("#st-go");
    await page.waitForFunction(() => /Imported: 3 new lines/.test(document.querySelector("#st-sum").textContent));
    const sum = await text2(page, "#st-sum");
    ok(/1 paid automatically/.test(sum) && /2 need a decision/.test(sum), tag + "imported: one paid automatically, two need a decision (" + sum.split("\n").filter((x) => /Imported/.test(x))[0] + ")");
    ok((await calls(page, "stmt_save_mapping")) === 1 && (await calls(page, "stmt_import")) === 1, tag + "the layout was saved once and the file imported once");
    ok(await page.evaluate(() => JSON.stringify(window.__calls.filter((c) => c[0] === "stmt_import")[0][1].p_lines).indexOf("000-000000-0") < 0), tag + "only mapped lines were sent: the rows above the table never left the browser");
    // ---- the review list
    const rv = (await text2(page, "#st-main")).replace(/\s+/g, " ");
    ok(/money in 1/i.test(rv) && /money out 1/i.test(rv) && /Only one invoice is owed for exactly S\$30\.00/.test(rv), tag + "the waiting payment says why it waits; money out is a separate group");
    if (SC) await page.screenshot({ path: path.join(SC, "statements-review-" + mode + ".png"), fullPage: true });
    // ---- open the waiting payment: suggestion + one primary action
    await page.locator("#st-main [data-r]", { hasText: "PAYNOW fees" }).click(); await page.waitForSelector("#st-conf");
    const sb = (await text2(page, "#cm-sb")).replace(/\s+/g, " ");
    ok(/INV-3/.test(sb) && /Tan Family/.test(sb) && /The amount matches exactly/.test(sb) && await page.locator("#cm-sb .btn-primary").count() === 1, tag + "the sheet suggests INV-3 for the Tan Family, exact, with one primary action");
    ok(await page.locator("#st-rem").isChecked(), tag + "'Remember this payer' is ticked by default");
    await page.waitForTimeout(450); if (SC) await page.screenshot({ path: path.join(SC, "statements-sheet-" + mode + ".png") });
    await page.click("#st-conf"); await page.waitForFunction(() => /S\$30\.00 recorded on INV-3/.test(document.querySelector("#st-sum").textContent));
    await settle(page);
    ok(/Nothing is waiting for you|0 payments need/.test(await text2(page, "#st-sum")) || /1 money out/.test(await text2(page, "#st-sum")), tag + "confirmed: no payment is waiting any more");
    // ---- matched tab, payers tab
    await page.click('[data-sub="matched"]');
    const mt = (await text2(page, "#st-main")).replace(/\s+/g, " ");
    ok(/INV-1/.test(mt) && /Automatic/.test(mt) && /INV-3/.test(mt) && /Confirmed/.test(mt), tag + "Matched lists the automatic one and the confirmed one");
    await page.click('[data-sub="payers"]'); ok(/tan ah kow/.test(await text2(page, "#st-main")) && /pays for Tan Family/.test(await text2(page, "#st-main")), tag + "the remembered payer is listed");
    // ---- the same file again: nothing new, and it says so beforehand
    await page.click("#st-up"); await file(page); await page.waitForFunction(() => /3 of these lines were uploaded before and will be skipped/.test((document.querySelector("#st-known") || {}).textContent || ""));
    ok(true, tag + "a second upload says '3 of these lines were uploaded before and will be skipped'");
    await page.click("#st-go"); await page.waitForFunction(() => /Imported: 0 new lines, 3 already imported \(skipped\)/.test(document.querySelector("#st-sum").textContent));
    ok(true, tag + "importing it again adds nothing: 3 already imported (skipped)");
    // ---- undo needs a reason, then the line is back as a stub
    await page.click('[data-sub="matched"]'); await page.locator("#st-main [data-m]", { hasText: "INV-3" }).click(); await page.waitForSelector("#st-undo");
    await page.click("#st-undo"); await page.waitForSelector(".td-dlg-in"); await page.click(".td-dlg [data-yes]");
    await page.waitForFunction(() => /Please say why/.test(document.querySelector("#st-msg").textContent));
    ok((await calls(page, "stmt_undo")) === 0, tag + "undo without a reason is stopped on the page");
    await page.click("#st-undo"); await page.waitForSelector(".td-dlg-in"); await page.fill(".td-dlg-in", "wrong family"); await page.click(".td-dlg [data-yes]");
    await page.waitForFunction(() => /Undone: the line is back in the queue/.test(document.querySelector("#st-sum").textContent));
    await settle(page);
    ok(/Put back after an undo/.test(await text2(page, "#st-main")), tag + "undone: the line is back, with only its date and amount");
    // ---- choose another invoice: the note says what will happen
    await page.locator("#st-main [data-r]", { hasText: "Put back after an undo" }).first().click(); await page.waitForSelector("#st-other");
    ok(await page.locator("#st-rem").count() === 0, tag + "a stub has no payer, so no 'remember' box");
    await page.click("#st-other"); await page.waitForSelector("#st-pick [data-inv]");
    ok(await page.locator("#st-conf").isDisabled(), tag + "nothing chosen: Confirm is off");
    await page.fill("#st-q", "lim"); await page.waitForFunction(() => document.querySelectorAll("#st-pick [data-inv]").length === 1);
    ok(/INV-2/.test(await text2(page, "#st-pick")), tag + "the search narrows the open invoices to the Lim family's INV-2 (INV-1 is paid)");
    await page.check('#st-pick [data-inv]'); await page.waitForFunction(() => /short: the invoice stays part-paid/.test(document.querySelector("#st-pn").textContent));
    ok(/S\$20\.00 short/.test(await text2(page, "#st-pn")), tag + "S$30.00 against S$50.00: 'S$20.00 short: the invoice stays part-paid'");
    await page.click("#st-conf"); await page.waitForFunction(() => /S\$30\.00 recorded on INV-2/.test(document.querySelector("#st-sum").textContent)); await settle(page);
    // ---- money out: not ours, all at once
    await page.click('[data-sub="review"]'); await page.waitForSelector("#st-out");
    await page.click("#st-out"); await page.waitForSelector(".td-dlg"); ok(/1 line of money out will be set aside/.test(await text2(page, ".td-dlg-m")), tag + "it asks first and counts the lines");
    await page.click(".td-dlg [data-yes]"); await page.waitForFunction(() => /1 set aside/.test(document.querySelector("#st-sum").textContent));
    ok(/Nothing is waiting/.test(await text2(page, "#st-sum")), tag + "nothing is waiting any more");
    // ---- forget a payer
    await page.click('[data-sub="payers"]'); await page.click("[data-forget]"); await page.waitForSelector(".td-dlg"); await page.click(".td-dlg [data-yes]");
    await page.waitForFunction(() => /No payer is remembered yet/.test(document.querySelector("#st-main").textContent));
    ok(true, tag + "a payer can be forgotten");
    ok(await noScroll(page), tag + "no sideways scroll at the end");
    ok(errs.length === 0, tag + "no console errors" + (errs.length ? ": " + errs.join(" | ") : ""));
    await ctx.close();
  }
  // ---- messages for everyone who can't use it
  for (const [label, cfg, re] of [["functions missing", { missing: true }, /migration_statement_matching\.sql/], ["matching switched off", { off: true }, /Bank statement matching is off/], ["no permission", { denied: true }, /record payments/i]]) {
    const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], ...cfg }, { phone: true });
    await page.goto(BASE + "centre-money.html?id=c1&tab=statements"); await page.waitForSelector("#cm-stmt .cm-block");
    ok(re.test(await text2(page, "#cm-stmt")), label + ": the page says what to do"); await ctx.close();
  }
  await browser.close(); console.log(fails ? fails + " FAILED" : "ALL PASS"); process.exit(fails ? 1 : 0);
})();
