// Browser check for Money > Deposits and the deposit line of the invoice run (T4 S4). Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/centre-deposits.check.js [screenshot-dir]
// The database functions are replaced by a small in-memory stand-in (tests/sql/centre_deposits_test.sql proves the real ones), because the DEV project
// does not have db/migration_centre_deposits.sql yet. State lives in localStorage so a reload keeps it. All names are fake.
// The click-through of the plan's S4 row: deposit mode percent 50 · two students ready · run: each family gets its lesson invoice AND a separate
// "Refundable deposit" invoice for half the first month · approve · record one deposit paid: the held total rises · waive the other · opening balance.
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
  function fresh() { return { drafts: [], issued: [], deps: {}, ledger: [], n: 1, paid: {} }; }
  function S() { try { return JSON.parse(localStorage.getItem("__dp") || "null") || fresh(); } catch (e) { return fresh(); } }
  function save(s) { localStorage.setItem("__dp", JSON.stringify(s)); }
  var gst = function (sub) { return Math.round(sub * 0.09); };
  // two families, one child each: Newton Ng 4 lessons (S$200.00), Maya Mok 2 lessons (S$100.00). Tia Trial has only a free trial (never a deposit).
  var FAMILIES = [{ key: "h1", name: "Mok Family", kid: "Maya Mok", sid: "st2", n: 2 }, { key: "h2", name: "Ng Family", kid: "Newton Ng", sid: "st1", n: 4 }];
  function lessonLines(f) { var o = []; for (var i = 0; i < f.n; i++) o.push({ kind: "lesson", student_name: f.kid, description: "Math · Tue " + (3 + i) + " Nov, 4:00pm", qty: 1, unit_cents: 5000, line_cents: 5000 }); return o; }
  function unit(f) { var sub = f.n * 5000, g = gst(sub); return { key: f.key, name: f.name, household_id: f.key, student_id: null, lessons: f.n, subtotal_cents: sub, net_cents: sub, gst_cents: g, total_cents: sub + g, not_marked: 0, no_price: 0, free_trials: 0, lines: lessonLines(f) }; }
  function res(d, e) { return Promise.resolve({ data: d == null ? null : d, error: e ? { message: e } : null }); }
  function held(s, sid) { return s.ledger.filter(function (e) { return e.sid === sid && e.kind !== "waived"; }).reduce(function (t, e) { return t + e.cents; }, 0); }
  function waived(s, sid) { return s.ledger.filter(function (e) { return e.sid === sid && e.kind === "waived"; }).reduce(function (t, e) { return t + e.cents; }, 0); }
  function invFor(s, id) { return s.drafts.concat(s.issued).filter(function (x) { return x.id === id; })[0]; }
  function statusRow(s, d) {
    var inv = d.invoice_id ? invFor(s, d.invoice_id) : null, h = held(s, d.sid), w = waived(s, d.sid), due = inv ? inv.total_cents : d.required;
    var state = w > 0 ? "waived" : inv && inv.status === "draft" ? "draft" : h >= due ? "held" : h > 0 ? "part_paid" : "unpaid";
    return { deposit_id: "dep-" + d.sid, student_id: d.sid, name: d.name, household_id: d.hh, household_name: d.hname, source: d.source, mode: d.mode, percent_bp: d.pbp, first_month_cents: d.first,
      required_cents: d.required, due_cents: due, held_cents: h, waived_cents: w, short_cents: state === "waived" || state === "draft" ? 0 : Math.max(due - h, 0), state: state, taxable: false,
      period_start: null, invoice_id: d.invoice_id, invoice_number: inv && inv.number || null, invoice_status: inv ? inv.status : null, due_date: inv && inv.due_date || null };
  }
  window.__calls = [];
  window.__override = function (c) {
    var from = c.from.bind(c), rpc = c.rpc.bind(c);
    c.rpc = function (nm, a) {
      window.__calls.push([nm, a]);
      if (nm === "staff_home") return res({ org_id: "c1", org_name: "Demo Learning Centre", status: "active", today: TODAY, can: { students: true, timetable: true, charges: true }, students_active: 4, today_lessons: 0, today_marked: 0, today_to_mark: 0, unmarked_past: 0, no_tutor_14d: 0, pending_charges: 0, trials_this_month: 0 });
      if (nm === "staff_students") {
        var q = (a.p_q || "").toLowerCase(), rows = [{ id: "st9", name: "Zed Zhang", level: "P5", household_name: "Zhang Family" }, { id: "st1", name: "Newton Ng", level: "P6", household_name: "Ng Family" }].filter(function (x) { return !q || x.name.toLowerCase().indexOf(q) > -1; });
        return res({ rows: rows, total: rows.length, counts: {} });
      }
      if (!/^centre_(invoice|set_opening|deposit|record_payment)/.test(nm)) return rpc(nm, a);
      if (cfg.missing) return res(null, "Could not find the function public." + nm);
      var s = S();
      if (nm === "centre_invoice_run_preview") {
        var billed = s.drafts.concat(s.issued).filter(function (x) { return x.kind === "lesson"; }).map(function (x) { return x.key; });
        var avail = FAMILIES.filter(function (f) { return billed.indexOf(f.key) < 0; }).map(unit);
        var deps = cfg.mode === "none" ? [] : avail.map(function (u) { var f = FAMILIES.filter(function (x) { return x.key === u.key; })[0]; if (s.deps[f.sid]) return null;
          return { student_id: f.sid, name: f.kid, household_id: f.key, key: f.key, mode: "percent_first_month", percent_bp: 5000, first_month_cents: f.n * 5000, amount_cents: f.n * 2500, taxable: false, frozen: false }; }).filter(Boolean);
        var tot = avail.reduce(function (t, x) { return t + x.total_cents; }, 0);
        return res({ today: TODAY, period_start: a.p_period, period_end: a.p_period, model: "postpaid_lessons", fixed_period: "month", grouping: "family", review_before_sending: true, due_days: 7, built: true, message: null,
          deposit_mode: cfg.mode || "percent_first_month", deposit_note: cfg.note || null, deposits: deps, ready: avail, held_back: [],
          drafts: s.drafts.filter(function (x) { return x.kind === "lesson"; }).map(function (d) { return { key: d.key, name: d.name, invoice_id: d.id, total_cents: d.total_cents, new_lessons: 0 }; }),
          totals: { deposits: deps.length, deposit_cents: deps.reduce(function (t, x) { return t + x.amount_cents; }, 0), ready: avail.length, held_back: 0, drafts: s.drafts.filter(function (x) { return x.kind === "lesson"; }).length, lessons: 0, not_marked: 0,
                    subtotal_cents: tot, gst_cents: 0, total_cents: tot } });
      }
      if (nm === "centre_invoice_run_create_drafts") {
        var made = 0, nd = 0, b2 = s.drafts.concat(s.issued).filter(function (x) { return x.kind === "lesson"; }).map(function (x) { return x.key; });
        FAMILIES.filter(function (f) { return b2.indexOf(f.key) < 0; }).forEach(function (f) {
          var u = unit(f); s.drafts.push({ id: "d" + f.key, kind: "lesson", key: f.key, name: f.name, total_cents: u.total_cents, net_cents: u.net_cents, gst_cents: u.gst_cents, lines: u.lines, status: "draft" }); made++;
          if (cfg.mode !== "none" && !s.deps[f.sid]) {
            var amt = f.n * 2500; s.deps[f.sid] = { sid: f.sid, name: f.kid, hh: f.key, hname: f.name, source: "invoice_run", mode: "percent_first_month", pbp: 5000, first: f.n * 5000, required: amt, invoice_id: "dep-inv-" + f.sid };
            s.drafts.push({ id: "dep-inv-" + f.sid, kind: "deposit", key: "dep-" + f.sid, name: f.kid, hh: f.key, total_cents: amt, net_cents: amt, gst_cents: 0, status: "draft", lines: [{ kind: "lesson", student_name: f.kid, description: "Refundable deposit", qty: 1, unit_cents: amt, line_cents: amt }] }); nd++;
          }
        });
        save(s); return res({ period_start: a.p_period, created: made, issued: 0, held_back: 0, already_drafted: 0, nothing_to_bill: 0, review_before_sending: true, invoices: [], deposits: nd, deposits_issued: 0, deposit_invoices: [] });
      }
      if (nm === "centre_invoice_list") {
        var rows = s.drafts.concat(s.issued).map(function (d) { return { id: d.id, kind: d.kind, status: d.status, number: d.number || null, name: d.name, household_id: d.hh || d.key, student_id: null, period_start: a.p_period, period_end: a.p_period, issue_date: d.issue_date || null, due_date: d.due_date || null, net_cents: d.net_cents, gst_cents: d.gst_cents, total_cents: d.total_cents, lines: d.lines.length }; });
        rows.sort(function (x, y) { return (x.status === "draft" ? 0 : 1) - (y.status === "draft" ? 0 : 1) || (x.number || "").localeCompare(y.number || ""); });
        return res({ today: TODAY, rows: rows });
      }
      if (nm === "centre_invoice_numbering") return res({ prefix: "INV", next_number: 1 + s.issued.length, next_text: "INV-" + (1 + s.issued.length), locked: s.issued.length > 0, can_set: true });
      if (nm === "centre_invoice_approve_all") {
        if (!s.drafts.length) return res(null, "NOTHING_TO_APPROVE: there are no drafts for that month");
        s.drafts.sort(function (p, q) { return p.name.localeCompare(q.name) || (p.kind === "lesson" ? -1 : 1); });
        var f1 = null, l1 = null, n = s.drafts.length, nd2 = 0;
        s.drafts.forEach(function (x) { x.number = "INV-" + (1 + s.issued.length); x.status = "issued"; x.issue_date = TODAY; x.due_date = TODAY; s.issued.push(x); f1 = f1 || x.number; l1 = x.number; if (x.kind === "deposit") nd2++; });
        s.drafts = []; save(s); return res({ issued: n, first_number: f1, last_number: l1, total_cents: 0, deposits: nd2 });
      }
      if (nm === "centre_invoice_account_list") {
        var rs = s.issued.map(function (d) { var paid = s.paid[d.id] || 0; return { id: d.id, number: d.number, name: d.name, household_id: d.hh || d.key, student_id: null, kind: d.kind, period_start: null, issue_date: d.issue_date, due_date: d.due_date, total_cents: d.total_cents, credited_cents: 0, paid_cents: paid, balance_cents: d.total_cents - paid, pay_status: paid >= d.total_cents ? "paid" : paid > 0 ? "part_paid" : "issued", lines: 1 }; });
        return res({ today: TODAY, counts: { all: rs.length, unpaid: 0, overdue: 0, part_paid: 0, paid: 0 }, outstanding_cents: 0, overdue_cents: 0, rows: rs });
      }
      if (nm === "centre_invoice_account_get") {
        var dd = invFor(s, a.p_invoice); if (!dd) return res(null, "NOT_FOUND");
        var pd = s.paid[dd.id] || 0;
        return res({ id: dd.id, today: TODAY, status: "issued", number: dd.number, name: dd.name, household_id: dd.hh || dd.key, kind: dd.kind, issue_date: dd.issue_date, due_date: dd.due_date, pay_status: pd >= dd.total_cents ? "paid" : "issued", gst_registered: false, net_cents: dd.net_cents, gst_cents: dd.gst_cents, total_cents: dd.total_cents,
          credited_cents: 0, paid_cents: pd, balance_cents: dd.total_cents - pd, can: { record_payments: true, issue_invoices: true }, rules: { partial_payments: true, overpayments: "credit", manual_paynow: true, share_link: true }, payments: [], credit_notes: [], credit_balance_cents: 0, share: null,
          lines: dd.lines.map(function (l, i) { return { position: i + 1, student_name: l.student_name, description: l.description, qty: 1, unit_cents: l.unit_cents, line_cents: l.line_cents, kind: "lesson" }; }) });
      }
      if (nm === "centre_record_payment") {
        var id = a.p_invoice_ids[0], inv = invFor(s, id); s.paid[id] = (s.paid[id] || 0) + a.p_amount_cents;
        if (inv && inv.kind === "deposit") { var sid = Object.keys(s.deps).filter(function (k) { return s.deps[k].invoice_id === id; })[0]; s.ledger.push({ sid: sid, kind: "received", cents: a.p_amount_cents, date: a.p_received_on, inv: inv.number }); }
        save(s); return res({ payment_id: "p1", household_id: a.p_household, amount_cents: a.p_amount_cents, allocated: [{ invoice_id: id, number: inv.number, cents: a.p_amount_cents, balance_after_cents: inv.total_cents - s.paid[id] }], excess_cents: 0, excess_handling: null, credit_balance_cents: 0 });
      }
      if (nm === "centre_deposit_status") {
        var rows2 = Object.keys(s.deps).map(function (k) { return statusRow(s, s.deps[k]); }).sort(function (x, y) { return x.name.localeCompare(y.name); });
        return res({ today: TODAY, rows: rows2, totals: { held_cents: rows2.reduce(function (t, r) { return t + r.held_cents; }, 0), taxable_held_cents: 0, students_holding: rows2.filter(function (r) { return r.held_cents > 0; }).length, required_cents: 0, short_cents: rows2.reduce(function (t, r) { return t + r.short_cents; }, 0), deposits: rows2.length } });
      }
      if (nm === "centre_deposits_held") {
        var hs = Object.keys(s.deps).map(function (k) { return held(s, k); }).filter(function (x) { return x > 0; });
        return res({ today: TODAY, total_held_cents: hs.reduce(function (t, x) { return t + x; }, 0), taxable_held_cents: 0, students_holding: hs.length, rows: [] });
      }
      if (nm === "centre_deposit_ledger_get") {
        var d1 = s.deps[a.p_student]; if (!d1) return res(null, "NOT_FOUND"); var bal = 0;
        return res({ today: TODAY, student_id: d1.sid, name: d1.name, status: statusRow(s, d1), entries: s.ledger.filter(function (e) { return e.sid === d1.sid; }).map(function (e, i) { if (e.kind !== "waived") bal += e.cents; return { id: "e" + i, date: e.date || TODAY, kind: e.kind, cents: e.cents, taxable: false, invoice_number: e.inv || null, reason: e.reason || null, balance_cents: bal }; }) });
      }
      if (nm === "centre_deposit_waive") {
        if (!(a.p_reason || "").trim()) return res(null, "REASON_REQUIRED: say why this deposit is being waived");
        var d2 = s.deps[a.p_student], i2 = invFor(s, d2.invoice_id), amt2 = i2.total_cents - (s.paid[i2.id] || 0), how = i2.status === "draft" ? "draft_discarded" : "credit_note";
        if (how === "draft_discarded") s.drafts = s.drafts.filter(function (x) { return x.id !== i2.id; });
        s.ledger.push({ sid: d2.sid, kind: "waived", cents: amt2, reason: a.p_reason }); save(s); return res({ student_id: d2.sid, waived_cents: amt2, how: how, credit_note: null });
      }
      if (nm === "centre_deposit_opening_balance") {
        if (s.deps[a.p_student]) return res(null, "ALREADY_HAS_DEPOSIT: this student already has a deposit record");
        s.deps[a.p_student] = { sid: a.p_student, name: "Zed Zhang", hh: "h9", hname: "Zhang Family", source: "opening_balance", mode: "opening", pbp: null, first: null, required: a.p_amount_cents, invoice_id: null };
        s.ledger.push({ sid: a.p_student, kind: "opening_balance", cents: a.p_amount_cents, date: a.p_date, reason: a.p_note }); save(s); return res({ deposit_id: "x", student_id: a.p_student, held_cents: a.p_amount_cents });
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

(async () => {
  const browser = await chromium.launch();
  const OWNER = { members: [M(SOLO, "owner"), M(C, "owner")] };
  for (const mode of ["desktop", "phone", "dark"]) {
    const tag = "[" + mode + "] ";
    const { ctx, page, errs } = await open(browser, OWNER, { phone: mode === "phone", dark: mode === "dark" });
    // ---- 1. the run: a separate refundable deposit for each family's first invoice
    await page.goto(BASE + "centre-money.html?id=c1&month=2026-10"); await page.waitForSelector(".cm-sum");
    ok(/2 invoices ready/.test(await text(page, ".cm-sum-t")), tag + "two families are ready: " + (await text(page, ".cm-sum-t")));
    const sec = await text(page, "#cm-h-dep");
    ok(/Refundable deposits\s*2/i.test(sec), tag + "a 'Refundable deposits' section lists 2 (" + sec.replace(/\s+/g, " ") + ")");
    const body = await text(page, "#cm-body");
    ok(/Newton Ng/.test(body) && /50% of S\$200\.00 first month/.test(body) && /S\$100\.00/.test(body), tag + "Newton: S$100.00 = 50% of his S$200.00 first month");
    ok(/Maya Mok/.test(body) && /50% of S\$100\.00 first month/.test(body) && /S\$50\.00/.test(body), tag + "Maya: S$50.00 = 50% of S$100.00");
    ok(!/Tia Trial/.test(body), tag + "a trial student is not offered a deposit");
    ok(/held for the family, not counted as income/.test(await text(page, ".cm-sec:has(#cm-h-dep) .cm-note")), tag + "the section says a deposit is not income");
    ok(await page.locator(".btn-primary").count() === 1 && /Create 2 drafts and 2 deposits/.test(await text(page, ".btn-primary")), tag + "still ONE primary action: " + (await text(page, ".btn-primary")));
    if (SC) await page.screenshot({ path: path.join(SC, "deposits-run-" + mode + ".png"), fullPage: true });
    await page.click("#cm-go"); await page.waitForSelector("#cm-h-inv");
    ok(/2 drafts created\. 2 refundable deposits drafted\./.test(await text(page, "#cm-msg")), tag + "message: " + (await text(page, "#cm-msg")));
    const rows = await page.locator("[data-inv]").allInnerTexts();
    ok(rows.length === 4 && rows.filter((t) => /Refundable deposit/.test(t)).length === 2, tag + "four drafts: two lesson invoices and two tagged 'Refundable deposit'");
    ok(/Approve all 4 drafts/.test(await text(page, ".btn-primary")), tag + "next: " + (await text(page, ".btn-primary")));
    await page.click("#cm-go"); await page.waitForSelector(".td-dlg"); await page.click(".td-dlg [data-yes]");
    await page.waitForFunction(() => /issued/.test(document.querySelector("#cm-msg").textContent));
    ok(/4 invoices issued \(INV-1 to INV-4\), 2 of them refundable deposits\./.test(await text(page, "#cm-msg")), tag + "approve all: " + (await text(page, "#cm-msg")));
    // ---- 2. the Deposits tab
    await page.click("#cm-tab-dep"); await page.waitForSelector("#cd-held");
    ok(/S\$0\.00/.test(await text(page, "#cd-held")) && /No deposits held yet/.test(await text(page, "#cd-sum")), tag + "nothing is held until a deposit is paid: " + (await text(page, "#cd-held")));
    ok(/never counted in your revenue/.test(await text(page, "#cd-sum")), tag + "the page says deposits are never counted in revenue");
    const dep = await page.locator("#cd-list [data-i]").allInnerTexts();
    ok(dep.length === 2 && dep.every((t) => /Not paid yet/.test(t)), tag + "two deposits, both 'Not paid yet'");
    const nrow = dep.filter((t) => /Newton Ng/.test(t))[0] || "";
    ok(/S\$100\.00/.test(nrow) && /INV-/.test(nrow), tag + "Newton's row: S$100.00 to collect, with its invoice number");
    ok(/tab=deposits/.test(page.url()), tag + "the address remembers the tab");
    if (SC) await page.screenshot({ path: path.join(SC, "deposits-list-" + mode + ".png"), fullPage: true });
    // pay Newton's deposit through the normal invoice screen
    await page.locator("#cd-list [data-i]", { hasText: "Newton Ng" }).click(); await page.waitForSelector("#cd-inv");
    ok(/Required\s*S\$100\.00/.test(await text(page, "#cm-sb")) && /50% of the first month’s fee \(S\$200\.00\)/.test(await text(page, "#cm-sb")), tag + "the sheet shows the frozen amount and how it was worked out");
    ok(/Open the invoice to record a payment/.test(await text(page, "#cd-inv")) && await page.locator("#cd-waive").count() === 1, tag + "the sheet offers the invoice and waive");
    await page.waitForTimeout(450); if (SC && mode !== "dark") await page.screenshot({ path: path.join(SC, "deposits-sheet-" + mode + ".png") });
    await page.click("#cd-inv"); await page.waitForSelector("#cp-pay"); await page.click("#cp-pay"); await page.waitForSelector("#cp-form");
    ok((await page.inputValue("#cp-amt")) === "100.00", tag + "the payment form is prefilled with the S$100.00 deposit");
    await page.click("#cp-go"); await page.waitForFunction(() => /Paid|recorded|received/i.test(document.querySelector("#cp-msg") ? document.querySelector("#cp-msg").textContent : ""), null, { timeout: 4000 }).catch(() => {});
    await page.click("#cm-sx"); await page.waitForTimeout(350);
    await page.click("#cm-tab-inv"); await page.waitForSelector("#cp-list");
    ok(/Refundable deposit/.test(await text(page, "#cp-list")), tag + "the Invoices tab marks the deposit invoices");
    await page.click("#cm-tab-dep"); await page.waitForFunction(() => /S\$100\.00/.test(document.querySelector("#cd-held").textContent));
    ok(/S\$100\.00/.test(await text(page, "#cd-held")) && /1 student has a deposit held/.test(await text(page, "#cd-sum")), tag + "the held total ROSE to S$100.00: " + (await text(page, "#cd-held")));
    ok((await page.locator("#cd-list [data-i]", { hasText: "Newton Ng" }).innerText()).includes("Held"), tag + "Newton's deposit is 'Held'");
    ok(/S\$50\.00 to collect/.test(await text(page, "#cd-sum")) || /S\$50\.00 still to collect/.test(await text(page, "#cd-sum")), tag + "and S$50.00 is still to collect: " + (await text(page, "#cd-sum")).replace(/\s+/g, " "));
    // ---- 3. waive Maya's deposit, with a reason
    await page.locator("#cd-list [data-i]", { hasText: "Maya Mok" }).click(); await page.waitForSelector("#cd-waive");
    await page.click("#cd-waive"); await page.waitForSelector(".td-dlg");
    ok(/Waive Maya Mok’s deposit\?/.test(await text(page, ".td-dlg-t")) && /credit note takes S\$50\.00/.test(await text(page, ".td-dlg-m")), tag + "waiving asks first and says what happens");
    await page.fill(".td-dlg-in", "Sibling of a long-standing student"); await page.click(".td-dlg [data-yes]");
    await page.waitForFunction(() => /Waived/.test(document.querySelector("#cm-sm").textContent));
    ok(/Waived/.test(await text(page, "#cm-sm")) && await page.locator("#cd-waive").count() === 0, tag + "the deposit shows as waived and can't be waived again");
    ok(/Sibling of a long-standing student/.test(await text(page, "#cm-sb")), tag + "the reason is in the history");
    await page.click("#cm-sx"); await page.waitForTimeout(350);
    ok(/S\$100\.00/.test(await text(page, "#cd-held")), tag + "a waiver is not cash: the held total is unchanged");
    // ---- 4. opening balance (owner)
    await page.click("#cd-open"); await page.waitForSelector("#cd-form");
    await page.fill("#cd-find", "zed"); await page.waitForSelector("[data-s]"); await page.click("[data-s]");
    ok(/Selected: Zed Zhang/.test(await text(page, "#cd-picked")), tag + "the student is picked from a search");
    await page.fill("#cd-amt", "0"); await page.click("#cd-go");
    ok(/more than S\$0\.00/.test(await text(page, "#cd-err")), tag + "a zero amount is refused on the form");
    await page.fill("#cd-amt", "150"); await page.click("#cd-go"); await page.waitForFunction(() => /Zed Zhang/.test(document.querySelector("#cd-list").textContent));
    ok(/S\$250\.00/.test(await text(page, "#cd-held")) && /2 students have a deposit held/.test(await text(page, "#cd-sum")), tag + "opening balance S$150.00 added: held S$250.00 for 2 students");
    ok((await page.locator("#cd-list [data-i]", { hasText: "Zed Zhang" }).innerText()).includes("Collected before TutorDeck"), tag + "Zed's row says it was collected before TutorDeck");
    ok(await noScroll(page), tag + "no sideways scroll");
    if (SC) await page.screenshot({ path: path.join(SC, "deposits-done-" + mode + ".png"), fullPage: true });
    ok(errs.length === 0, tag + "no console or page errors " + errs.join(" | "));
    await ctx.close();
  }
  // ---- staff without the owner's button; centre not switched on; "before the first lesson" is coming soon
  {
    const { ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["record_payments"])] });
    await page.goto(BASE + "centre-money.html?id=c1&tab=deposits"); await page.waitForSelector("#cd-sum");
    ok(await page.locator("#cd-open").count() === 0, "staff never see the owner-only opening-balance button");
    ok(/No deposits yet/.test(await text(page, "#cd-list")), "an empty centre explains where deposits come from: " + (await text(page, "#cd-list")).slice(0, 60));
    ok(errs.length === 0, "staff: no console errors " + errs.join("|")); await ctx.close();
  }
  {
    const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], missing: true });
    await page.goto(BASE + "centre-money.html?id=c1&tab=deposits"); await page.waitForSelector("#cm-dep .cm-block");
    ok(/migration_centre_deposits\.sql/.test(await text(page, "#cm-dep")), "functions missing: the page says which migration to run"); await ctx.close();
  }
  {
    const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], note: "Deposits invoiced before the first lesson are coming soon. No deposit is raised until the setting says “together with the first lesson invoice”." });
    await page.goto(BASE + "centre-money.html?id=c1&month=2026-10"); await page.waitForSelector(".cm-sum");
    ok(/before the first lesson are coming soon/.test(await text(page, "#cm-body")), "a setting that isn't built yet is explained on the run page"); await ctx.close();
  }
  await browser.close(); console.log(fails ? fails + " FAILED" : "ALL PASS"); process.exit(fails ? 1 : 0);
})();
