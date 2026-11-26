// Browser check for Money > Invoices & payments and the public invoice page (T4 S3). Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/centre-payments.check.js [screenshot-dir]
// The database functions are replaced by a small in-memory stand-in (tests/sql/centre_payments_test.sql proves the real ones), because the DEV
// project does not have db/migration_centre_payments.sql yet. State lives in localStorage so a reload keeps it. All names are fake.
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
const STUB_PLUS = STUB + `;(function(){var o=window.supabase.createClient;window.supabase.createClient=function(){var c=o.apply(this,arguments);if(window.__override)window.__override(c);return c;};})();`;
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
const SOLO = { id: "s1", kind: "solo", trading_name: "Empty Shell" }, C = { id: "c1", kind: "centre", trading_name: "Demo Learning Centre" };
const M = (o, role, permissions) => ({ org_id: o.id, user_id: "u1", role, status: "active", permissions: permissions || [], organisations: o });
const TOKEN = "11111111-1111-4111-8111-111111111111";

function override(cfg) {
  var TODAY = new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 10);
  function addDays(n) { var d = new Date(TODAY + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); }
  function fresh() { return { inv: [
    { id: "i1", number: "INV-1", name: "Lim Family", hh: "h1", total: 10900, due: addDays(7), issued: TODAY, pays: [], cns: [], share: false },
    { id: "i2", number: "INV-2", name: "Tan Family", hh: "h2", total: 5450, due: addDays(-5), issued: addDays(-12), pays: [], cns: [], share: false }], seq: 0, credit: 0 }; }
  function S() { try { return JSON.parse(localStorage.getItem("__cp") || "null") || fresh(); } catch (e) { return fresh(); } }
  function save(s) { localStorage.setItem("__cp", JSON.stringify(s)); }
  function calc(i) {
    var paid = i.pays.reduce(function (t, p) { return t + (p.reversed ? 0 : p.cents); }, 0), cr = i.cns.reduce(function (t, n) { return t + n.total_cents; }, 0), bal = Math.max(i.total - cr - paid, 0), ps;
    if (i.total > 0 && cr >= i.total) ps = "void"; else if (bal <= 0) ps = "paid"; else if (i.due < TODAY) ps = "overdue"; else if (paid > 0) ps = "part_paid"; else ps = "issued";
    return { paid: paid, cr: cr, bal: bal, ps: ps };
  }
  function row(i) { var c = calc(i); return { id: i.id, number: i.number, name: i.name, household_id: i.hh, kind: "lesson", issue_date: i.issued, due_date: i.due, total_cents: i.total, credited_cents: c.cr, paid_cents: c.paid, balance_cents: c.bal, pay_status: c.ps }; }
  function res(d, e) { return Promise.resolve({ data: d == null ? null : d, error: e ? { message: e } : null }); }
  window.__calls = [];
  window.__override = function (c) {
    var from = c.from.bind(c), rpc = c.rpc.bind(c);
    c.rpc = function (nm, a) {
      window.__calls.push([nm, a]);
      if (nm === "staff_home") return res({ org_id: "c1", org_name: "Demo Learning Centre", status: "active", today: TODAY, can: { students: true, timetable: true, charges: true }, students_active: 4, today_lessons: 0, today_marked: 0, today_to_mark: 0, unmarked_past: 0, no_tutor_14d: 0, pending_charges: 0, trials_this_month: 0 });
      if (nm === "centre_invoice_public") {
        if (a.p_token !== "11111111-1111-4111-8111-111111111111") return res(null);
        return res({ centre: { name: "Demo Learning Centre", brand_color: "#0F766E", logo_url: null, uen: "201912345A", gst_number: "M12345678X" },
          invoice: { number: "INV-1", bill_to: "Lim Family", issue_date: TODAY, due_date: addDays(7), gst_registered: true, gst_rate_bp: 900, net_cents: 10000, gst_cents: 900, total_cents: 10900, credited_cents: 1000, paid_cents: 0, balance_cents: 9900, pay_status: "issued",
            lines: [{ student_name: "Sophie Lim", description: "Math · Tue 3 Nov, 4:00pm", qty: 2, unit_cents: 5000, line_cents: 10000 }] },
          paynow: { type: "uen", id: "201912345A", reference: "INV-1", amount_cents: 9900 }, expires_on: null });
      }
      if (!/^centre_(invoice_account|record_payment|reverse_payment|issue_credit|invoice_share|invoice_whatsapp)/.test(nm)) {
        if (/^centre_/.test(nm)) return res(null, "Could not find the function public." + nm);
        return rpc(nm, a);
      }
      if (cfg.missing) return res(null, "Could not find the function public." + nm);
      var s = S(), i;
      if (nm === "centre_invoice_account_list") {
        var rows = s.inv.map(row), f = a.p_filter, cnt = function (fn) { return rows.filter(fn).length; };
        var shown = rows.filter(function (r) { return !f || f === "all" || (f === "unpaid" ? r.balance_cents > 0 && r.pay_status !== "void" : f === "overdue" ? r.pay_status === "overdue" : f === "part_paid" ? r.paid_cents > 0 && r.balance_cents > 0 : f === "paid" ? r.pay_status === "paid" : r.pay_status === "void"); });
        return res({ today: TODAY, counts: { all: rows.length, unpaid: cnt(function (r) { return r.balance_cents > 0 && r.pay_status !== "void"; }), overdue: cnt(function (r) { return r.pay_status === "overdue"; }), part_paid: cnt(function (r) { return r.paid_cents > 0 && r.balance_cents > 0; }), paid: cnt(function (r) { return r.pay_status === "paid"; }), void: cnt(function (r) { return r.pay_status === "void"; }) },
          outstanding_cents: rows.reduce(function (t, r) { return t + r.balance_cents; }, 0), overdue_cents: rows.filter(function (r) { return r.pay_status === "overdue"; }).reduce(function (t, r) { return t + r.balance_cents; }, 0), rows: shown });
      }
      var id = a.p_invoice || (a.p_invoice_ids && a.p_invoice_ids[0]);
      i = s.inv.filter(function (x) { return x.id === id; })[0];
      if (nm === "centre_invoice_account_get") {
        if (!i) return res(null, "NOT_FOUND");
        var c = calc(i), r = row(i);
        var pays = []; i.pays.forEach(function (p) { pays.push({ payment_id: p.id, kind: "payment", received_on: p.on, method: p.method, cents: p.cents, reference: p.ref, reversed: !!p.reversed }); if (p.reversed) pays.push({ payment_id: p.id + "r", kind: "reversal", received_on: TODAY, method: p.method, cents: -p.cents, reference: null, reversed: false }); });
        return res(Object.assign({}, r, { today: TODAY, status: "issued", kind: "lesson", gst_registered: true, gst_rate_bp: 900, gst_inclusive: false, net_cents: Math.round(i.total / 1.09), gst_cents: i.total - Math.round(i.total / 1.09),
          can: { record_payments: cfg.canPay !== false, issue_invoices: cfg.canInvoice !== false, owner: true }, rules: { partial_payments: cfg.partial !== false, overpayments: cfg.over || "credit", manual_paynow: true, share_link: true },
          credit_balance_cents: s.credit, share: i.share ? { expires_on: null, expired: false } : null, payments: pays,
          credit_notes: i.cns.map(function (n) { return { id: n.id, number: n.number, issue_date: TODAY, total_cents: n.total_cents, reason: n.reason }; }),
          lines: [{ position: 1, student_name: "Sophie Lim", description: "Math lessons", qty: 2, unit_cents: Math.round(i.total / 1.09 / 2), line_cents: Math.round(i.total / 1.09), kind: "lesson" }] }));
      }
      if (!i && nm !== "centre_reverse_payment") return res(null, "NOT_FOUND");
      var cc = i ? calc(i) : null;
      if (nm === "centre_record_payment") {
        if (a.p_amount_cents <= 0) return res(null, "BAD_VALUE: the amount must be more than S$0.00");
        if (cfg.partial === false && a.p_amount_cents < cc.bal) return res(null, "PART_NOT_ALLOWED: this centre doesn't accept part payments, so a payment has to cover whole invoices. " + i.number + " still owes S$" + (cc.bal / 100).toFixed(2) + ".");
        var take = Math.min(a.p_amount_cents, cc.bal), ex = a.p_amount_cents - take;
        i.pays.push({ id: "p" + (++s.seq), cents: take, on: a.p_received_on, method: a.p_method, ref: a.p_reference }); s.credit += ex; save(s);
        return res({ payment_id: "p" + s.seq, allocated: [{ invoice_id: i.id, number: i.number, cents: take, balance_after_cents: cc.bal - take }], excess_cents: ex, excess_handling: ex ? (cfg.over || "credit") : null, credit_balance_cents: s.credit });
      }
      if (nm === "centre_reverse_payment") {
        var inv = s.inv.filter(function (x) { return x.pays.some(function (p) { return p.id === a.p_payment; }); })[0];
        if (!inv) return res(null, "NOT_FOUND");
        inv.pays.forEach(function (p) { if (p.id === a.p_payment) p.reversed = true; }); inv.pays = inv.pays.map(function (p) { return p; });
        inv.pays.forEach(function (p) { if (p.reversed) p.cents = p.cents; }); save(s); return res({ reversal_id: "r1", payment_id: a.p_payment });
      }
      if (nm === "centre_issue_credit_note") {
        var left = i.total - cc.cr; if (a.p_amount_cents > left) return res(null, "TOO_MUCH: you can credit at most S$" + (left / 100).toFixed(2) + " more on this invoice");
        var n = { id: "n" + (++s.seq), number: "CN-INV-" + (i.cns.length + 1), total_cents: a.p_amount_cents, reason: a.p_reason }; i.cns.push(n); save(s);
        var c2 = calc(i); return res({ id: n.id, number: n.number, total_cents: n.total_cents, excess_to_family_cents: 0, balance_cents: c2.bal, pay_status: c2.ps });
      }
      if (nm === "centre_invoice_share_link") { i.share = true; save(s); return res({ token: "11111111-1111-4111-8111-111111111111", expires_on: null, rotated: !!a.p_rotate }); }
      if (nm === "centre_invoice_whatsapp") { i.share = true; save(s); return res({ template: "Hi {name}, this is {centre}. Invoice {number} for {amount} is due on {due_date}.\nYou can see it and pay by PayNow here: {link}\nThank you!", phone: cfg.phone === false ? null : "6591234567", token: "11111111-1111-4111-8111-111111111111", vars: { name: i.name, centre: "Demo Learning Centre", number: i.number, amount_cents: cc.bal, due_date: i.due } }); }
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
const blocked = [];
async function open(browser, cfg, opt) {
  opt = opt || {};
  const ctx = await browser.newContext({ viewport: opt.phone ? { width: 390, height: 780 } : { width: 1280, height: 800 }, permissions: ["clipboard-read", "clipboard-write"] });
  await ctx.addInitScript((t) => { try { if (t) localStorage.setItem("td_theme", t); } catch (e) {} }, opt.dark ? "dark" : "");
  await ctx.route(/^(?!http:\/\/127\.0\.0\.1).*/, (r) => { blocked.push(r.request().url()); r.abort(); });
  const page = await ctx.newPage(), errs = [];
  page.on("pageerror", (e) => errs.push(String(e)));
  page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource|net::ERR/.test(m.text())) errs.push(m.text()); });
  await page.route("**/assets/vendor/supabase-2.118.0.js", (r) => r.fulfill({ body: opt.stub || STUB_PLUS, contentType: "application/javascript" }));
  await page.addInitScript(override, cfg);
  return { ctx, page, errs };
}
const text = (page, sel) => page.locator(sel).innerText();
const shot = async (page, name) => { if (SC) { await page.waitForTimeout(350); await page.screenshot({ path: path.join(SC, name + ".png"), fullPage: true }); } };

(async () => {
  const browser = await chromium.launch();
  const OWNER = { members: [M(SOLO, "owner"), M(C, "owner")] };
  for (const mode of ["desktop", "phone", "dark"]) {
    const tag = "[" + mode + "] ";
    const { ctx, page, errs } = await open(browser, OWNER, { phone: mode === "phone", dark: mode === "dark" });
    await page.goto(BASE + "centre-money.html?id=c1&tab=invoices"); await page.waitForSelector(".cm-row");
    ok(await page.locator("#cm-tab-inv[aria-selected=true]").count() === 1 && await page.locator("#cm-inv").isVisible() && !(await page.locator("#cm-run").isVisible()), tag + "the Invoices & payments tab opens from the address");
    ok(((await page.locator(".topbar .sub").first().textContent()) || "").trim() === "Invoices & payments", tag + "the Money subtitle names the open tab (Invoices & payments)");
    ok(await page.locator(".cm-tabs").evaluate((e) => e.scrollHeight <= e.clientHeight + 1), tag + "the tab row has no vertical scrollbar");
    await page.locator("#cm-tab-run").click();
    ok(((await page.locator(".topbar .sub").first().textContent()) || "").trim() === "Invoice run", tag + "and back to Invoice run it says Invoice run");
    await page.locator("#cm-tab-inv").click();
    ok(await page.locator("#cp-list .cm-row").count() === 2, tag + "two issued invoices are listed");
    ok(/S\$163\.50 owed · S\$54\.50 overdue/.test(await text(page, "#cp-sum")), tag + "summary: " + (await text(page, "#cp-sum")).replace(/\n/g, " | "));
    ok(/Overdue/.test(await text(page, "#cp-list .cm-row:has-text('INV-2')")) && /Overdue by 5 days/.test(await text(page, "#cp-list .cm-row:has-text('INV-2')")), tag + "INV-2 shows the red Overdue chip and how late");
    ok(/Issued/.test(await text(page, "#cp-list .cm-row:has-text('INV-1')")), tag + "INV-1 shows Issued");
    await page.click("[data-f=overdue]"); await page.waitForFunction(() => document.querySelectorAll("#cp-list .cm-row").length === 1);
    ok(/INV-2/.test(await text(page, "#cp-list")) && await page.locator("[data-f=overdue][aria-pressed=true]").count() === 1, tag + "filter Overdue: only INV-2");
    await page.click("[data-f=all]"); await page.waitForFunction(() => document.querySelectorAll("#cp-list .cm-row").length === 2);
    await page.fill("#cp-q", "lim"); ok(await page.locator("#cp-list .cm-row").count() === 1, tag + "search finds Lim Family");
    await page.fill("#cp-q", "");
    await shot(page, "pay-list-" + mode);

    // part payment on INV-1
    await page.locator("#cp-list .cm-row", { hasText: "INV-1" }).click(); await page.waitForSelector("#cp-pay");
    ok(await page.locator("#cm-sb .btn-primary").count() === 1 && /Record payment/.test(await text(page, "#cm-sb .btn-primary")), tag + "the sheet has ONE primary action: Record payment");
    await shot(page, "pay-sheet-" + mode);
    await page.click("#cp-pay"); await page.fill("#cp-amt", "40");
    ok(/part-paid\. S\$69\.00 will still be owed/.test(await text(page, "#cp-amt-h")), tag + "the form says what a part payment does: " + (await text(page, "#cp-amt-h")));
    await page.fill("#cp-amt", "abc"); await page.click("#cp-go"); ok(/Type the amount/.test(await text(page, "#cp-amt-h")) , tag + "a bad amount is refused in words");
    await page.fill("#cp-amt", "40"); await page.selectOption("#cp-method", "bank"); await page.fill("#cp-ref", "DBS ref 55");
    await shot(page, "pay-form-" + mode);
    await page.click("#cp-go"); await page.waitForFunction(() => /Part-paid/.test(document.querySelector("#cm-sm").textContent));
    ok(/Paid\s*-S\$40\.00/.test((await text(page, "#cm-sb")).replace(/\n/g, "")) && /Still owed\s*S\$69\.00/.test((await text(page, "#cm-sb")).replace(/\n/g, "")), tag + "INV-1 is now part-paid: paid S$40.00, still owed S$69.00");
    ok(/Bank transfer · DBS ref 55/.test(await text(page, "#cm-sb")), tag + "the payment is listed with its method and reference");
    const call = await page.evaluate(() => window.__calls.filter((c) => c[0] === "centre_record_payment").pop()[1]);
    ok(call.p_amount_cents === 4000 && call.p_method === "bank" && call.p_invoice_ids[0] === "i1" && call.p_household === "h1", tag + "whole cents and the invoice are sent: " + JSON.stringify(call).slice(0, 120));

    // credit note S$10 with a reason
    await page.click("#cp-credit"); await page.fill("#cp-amt", "10");
    await page.click("#cp-go"); ok(/Say why/.test(await text(page, "#cp-err")), tag + "a credit note needs a reason");
    await page.fill("#cp-reason", "Lesson cancelled by the centre"); await page.click("#cp-go"); await page.waitForSelector(".td-dlg");
    ok(/Issue a credit note for S\$10\.00\?/.test(await text(page, ".td-dlg-t")) && /can’t be changed/.test(await text(page, ".td-dlg-m")), tag + "it asks first, in plain words");
    await page.click(".td-dlg [data-yes]"); await page.waitForFunction(() => /CN-INV-1/.test(document.querySelector("#cm-sb").textContent));
    ok(/CN-INV-1/.test(await text(page, "#cm-sb")) && /Lesson cancelled by the centre/.test(await text(page, "#cm-sb")) && /Still owed\s*S\$59\.00/.test((await text(page, "#cm-sb")).replace(/\n/g, "")), tag + "credit note CN-INV-1 for S$10.00 listed, still owed S$59.00");

    // reverse the payment
    await page.click("[data-rev='0']"); await page.waitForSelector(".td-dlg");
    ok(/Reverse this payment\?/.test(await text(page, ".td-dlg-t")), tag + "reversing asks for a reason");
    await page.fill(".td-dlg-in", "Entered against the wrong family"); await page.click(".td-dlg [data-yes]");
    await page.waitForFunction(() => /Reversed/.test(document.querySelector("#cm-sb").textContent));
    ok(/Still owed\s*S\$99\.00/.test((await text(page, "#cm-sb")).replace(/\n/g, "")) && await page.locator("[data-rev]").count() === 0, tag + "after the reversal INV-1 owes S$99.00 again; the old payment stays listed as Reversed");

    // the link
    await page.click("#cp-copy"); await page.waitForFunction(() => /Link copied/.test(document.querySelector("#cp-msg").textContent));
    const link = await page.evaluate(() => navigator.clipboard.readText());
    ok(/\/pay\?t=11111111-1111-4111-8111-111111111111$/.test(link), tag + "the copied link is a pay?t= address: " + link);
    ok(await page.locator("#cp-newlink").count() === 1, tag + "once a link exists, 'Make a new link' is offered");
    // WhatsApp
    const popup = page.waitForEvent("popup"); await page.click("#cp-wa"); const pop = await popup;
    await page.waitForFunction(() => window.__calls.some((c) => c[0] === "centre_invoice_whatsapp")); await page.waitForTimeout(600);
    const wa = blocked.filter((u) => /wa\.me/.test(u)).pop() || pop.url();
    ok(/^https:\/\/wa\.me\/6591234567\?text=/.test(wa), tag + "WhatsApp opens for the family's number: " + wa.slice(0, 60));
    const msg = decodeURIComponent(wa.split("text=")[1] || "");
    ok(/Hi Lim Family, this is Demo Learning Centre\. Invoice INV-1 for S\$99\.00 is due on/.test(msg) && /pay\?t=11111111/.test(msg), tag + "the message has the amount owed, the due date and the link");
    await pop.close();
    await page.click("#cm-sx");
    // overdue INV-2 paid in full
    await page.locator("#cp-list .cm-row", { hasText: "INV-2" }).click(); await page.waitForSelector("#cp-pay"); await page.click("#cp-pay");
    ok(await page.inputValue("#cp-amt") === "54.50", tag + "the amount is prefilled with what is owed");
    await page.click("#cp-go"); await page.waitForFunction(() => /Paid/.test(document.querySelector("#cm-sm").textContent) && !/Part/.test(document.querySelector("#cm-sm").textContent));
    ok(await page.locator("#cp-pay").count() === 0, tag + "a paid invoice has no Record payment button");
    await page.click("#cm-sx"); await page.waitForFunction(() => /Paid/.test(document.querySelector("#cp-list .cm-row:nth-child(2)").textContent) || /Paid/.test(document.querySelector("#cp-list").textContent));
    await shot(page, "pay-list-after-" + mode);
    ok(errs.length === 0, tag + "no console errors " + errs.join("|"));
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + "no sideways scroll");
    await ctx.close();

    // the public page, logged out
    const pub = await open(browser, OWNER, { phone: mode === "phone", dark: mode === "dark", stub: fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-out.js"), "utf8") + ";(function(){var o=window.supabase.createClient;window.supabase.createClient=function(){var c=o.apply(this,arguments);if(window.__override)window.__override(c);return c;};})();" });
    await pub.page.goto(BASE + "pay.html?t=" + TOKEN); await pub.page.waitForSelector(".pv-h"); await pub.page.waitForFunction(() => { var i = document.querySelector(".pv-qr"); return !i || (i.src || "").startsWith("data:"); });
    ok(/Invoice INV-1/.test(await text(pub.page, "main")) && /Demo Learning Centre/.test(await text(pub.page, "#pv-head")), tag + "the link opens the invoice with the centre's name, logged out");
    ok(/Amount due\s*S\$99\.00/.test((await text(pub.page, "main")).replace(/\n/g, "")), tag + "it shows the amount outstanding");
    ok(await pub.page.locator(".pv-qr").count() === 1 && /^data:image/.test(await pub.page.locator(".pv-qr").getAttribute("src")), tag + "a PayNow QR is drawn");
    ok(/201912345A/.test(await text(pub.page, ".pv-ref")) && /INV-1/.test(await text(pub.page, ".pv-ref")), tag + "the PayNow UEN and the invoice number as reference are shown");
    ok(!/Tan Family|INV-2|Sign in|Dashboard/.test(await text(pub.page, "body")), tag + "nothing else from the centre is on the page");
    ok(await pub.page.locator("a, button, input").count() === 0, tag + "read-only: no links, buttons or fields");
    await shot(pub.page, "pay-public-" + mode);
    ok(pub.errs.length === 0 && await pub.page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + "public page: no console errors, no sideways scroll " + pub.errs.join("|"));
    await pub.page.goto(BASE + "pay.html?t=22222222-2222-4222-8222-222222222222"); await pub.page.waitForSelector(".pv-bad");
    ok(/isn’t valid any more/.test(await text(pub.page, "main")) && !/INV-1/.test(await text(pub.page, "body")), tag + "a wrong token shows 'not valid' and nothing");
    await pub.page.goto(BASE + "pay.html?t=junk"); await pub.page.waitForSelector(".pv-bad"); ok(true, tag + "a junk token is handled");
    await pub.page.goto(BASE + "pay.html"); await pub.page.waitForSelector(".pv-bad"); ok(true, tag + "no token is handled");
    await pub.ctx.close();
  }
  // partial payments switched off: the refusal is in plain words and the form says so before sending
  { const { ctx, page } = await open(browser, Object.assign({ partial: false }, OWNER));
    await page.goto(BASE + "centre-money.html?id=c1&tab=invoices"); await page.waitForSelector(".cm-row");
    await page.locator("#cp-list .cm-row", { hasText: "INV-1" }).click(); await page.waitForSelector("#cp-pay"); await page.click("#cp-pay"); await page.fill("#cp-amt", "40");
    ok(/doesn’t accept part payments/.test(await text(page, "#cp-amt-h")), "partial off: the form refuses a part payment before it is sent");
    await page.click("#cp-go"); ok((await page.evaluate(() => window.__calls.filter((c) => c[0] === "centre_record_payment").length)) === 0, "and nothing is sent"); await ctx.close(); }
  // overpayment: the note says credit / refund as the centre chose
  for (const over of ["credit", "refund"]) { const { ctx, page } = await open(browser, Object.assign({ over }, OWNER));
    await page.goto(BASE + "centre-money.html?id=c1&tab=invoices"); await page.waitForSelector(".cm-row");
    await page.locator("#cp-list .cm-row", { hasText: "INV-2" }).click(); await page.waitForSelector("#cp-pay"); await page.click("#cp-pay"); await page.fill("#cp-amt", "60");
    ok(new RegExp(over === "credit" ? "kept as credit for the family" : "marked to refund").test(await text(page, "#cp-amt-h")), "overpayments = " + over + ": the form says so");
    await page.click("#cp-go"); await page.waitForFunction(() => /Payment recorded/.test(document.body.textContent) || document.querySelector(".cm-credit"));
    ok(await page.locator(".cm-credit").count() === 1 && /holds S\$5\.50 in credit/.test(await text(page, ".cm-credit")), "overpayments = " + over + ": the family's credit is shown on the invoice"); await ctx.close(); }
  // staff who only issue invoices: no Record payment; staff who only record payments: no credit note / link
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["issue_invoices"])], canPay: false });
    await page.goto(BASE + "centre-money.html?id=c1&tab=invoices"); await page.waitForSelector(".cm-row"); await page.locator("#cp-list .cm-row").first().click(); await page.waitForSelector("#cp-credit");
    ok(await page.locator("#cp-pay").count() === 0 && await page.locator("#cp-copy").count() === 1, "issue_invoices only: no Record payment, but credit note and link"); await ctx.close(); }
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["record_payments"])], canInvoice: false });
    await page.goto(BASE + "centre-money.html?id=c1&tab=invoices"); await page.waitForSelector(".cm-row"); await page.locator("#cp-list .cm-row").first().click(); await page.waitForSelector("#cp-pay");
    ok(await page.locator("#cp-credit").count() === 0 && await page.locator("#cp-copy").count() === 0 && await page.locator("#cp-wa").count() === 0, "record_payments only: no credit note, link or WhatsApp"); await ctx.close(); }
  { const { ctx, page } = await open(browser, Object.assign({ missing: true }, OWNER));
    await page.goto(BASE + "centre-money.html?id=c1&tab=invoices"); await page.waitForSelector("#cm-inv .cm-block");
    ok(/migration_centre_payments/.test(await text(page, "#cm-inv")), "migration missing: a plain message names the file"); await ctx.close(); }
  await browser.close();
  console.log(fails ? fails + " FAILED" : "ALL PASSED"); process.exit(fails ? 1 : 0);
})();
