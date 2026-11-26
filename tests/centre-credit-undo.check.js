// Browser check for T4 step S5b: "Undo credit or deposit used" on the invoice sheet, the in-app notice when four-eyes falls back, and the four-eyes option
// being disabled (with its reason) in the settings wizard until a second approver exists. Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/centre-credit-undo.check.js [screenshot-dir]
// The database functions are replaced by a small in-memory stand-in (tests/sql/centre_credit_undo_test.sql proves the real ones; DEV does not have
// db/migration_centre_credit_undo.sql). State lives in localStorage so a reload keeps it. All names are fake. Runs at desktop, 390 px and dark.
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
const STUB_PLUS = STUB + `;(function(){var o=window.supabase.createClient;window.supabase.createClient=function(){var c=o.apply(this,arguments);if(window.__override)window.__override(c);return c;};})();`;
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
const SOLO = { id: "s1", kind: "solo", trading_name: "Empty Shell" }, C = { id: "c1", kind: "centre", trading_name: "Demo Learning Centre" };
const M = (o, role, permissions, extra) => Object.assign({ id: "m-" + Math.random().toString(36).slice(2), org_id: o.id, user_id: "u1", display_name: "Owen Owner", role, status: "active", permissions: permissions || [], organisations: o }, extra || {});

function override(cfg) {
  var TODAY = new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 10);
  // the invoice INV-9 (S$109.00) was paid in full by S$109.00 of family credit; the family still holds S$50.00 of other credit
  function fresh() { return { undone: false, owes: 0, credit: 5000, notes: cfg.notes || [] }; }
  function S() { try { return JSON.parse(localStorage.getItem("__cu") || "null") || fresh(); } catch (e) { return fresh(); } }
  function save(s) { localStorage.setItem("__cu", JSON.stringify(s)); }
  function res(d, e) { return Promise.resolve({ data: d == null ? null : d, error: e ? { message: e } : null }); }
  window.__calls = [];
  function app(s) {
    var blockers = cfg.blocked && !s.undone ? [{ code: "credit_note", invoice_id: "inv9", text: "Invoice INV-9 has a credit note, issued after the credit was used. Its figures now depend on it." }] : [];
    return { payment_id: "p1", method: cfg.method || "family_credit", cents: 10900, date: TODAY, on_this_invoice_cents: 10900, also_invoices: cfg.also || [], by: "Billing Bea", state: s.undone ? "undone" : "active",
      undone_on: s.undone ? TODAY : null, undone_by: s.undone ? "Owen Owner" : null, undone_reason: s.undone && cfg.canUndoRole !== false ? s.reason : null,
      blockers: blockers, can_undo: cfg.canUndoRole !== false && !s.undone && !blockers.length };
  }
  window.__override = function (c) {
    var from = c.from.bind(c), rpc = c.rpc.bind(c);
    c.rpc = function (nm, a) {
      window.__calls.push([nm, a]);
      if (nm === "staff_home") return res({ org_id: "c1", org_name: "Demo Learning Centre", status: "active", today: TODAY, can: { students: true, timetable: true, charges: true }, students_active: 4, today_lessons: 0 });
      if (nm === "org_notification_dismiss") { var s0 = S(); s0.notes = s0.notes.filter(function (n) { return n.id !== a.p_id; }); save(s0); return res(true); }
      if (!/^centre_(invoice_account|invoice_applications|undo_application|family_credit|refund_list)/.test(nm)) return rpc(nm, a);
      if (cfg.missing && /applications|undo/.test(nm)) return res(null, "Could not find the function public." + nm);
      var s = S();
      if (nm === "centre_invoice_account_list") return res({ today: TODAY, counts: { all: 1, paid: 1, issued: 0, part_paid: 0, overdue: 0, void: 0 }, rows: [{ id: "inv9", number: "INV-9", name: "Bee Family", kind: "lesson", pay_status: s.owes > 0 ? "issued" : "paid",
        total_cents: 10900, balance_cents: s.owes, issue_date: TODAY, due_date: TODAY, paid_cents: 10900 - s.owes }] });
      if (nm === "centre_invoice_account_get") return res({ id: "inv9", today: TODAY, status: "issued", number: "INV-9", name: "Bee Family", household_id: "h2", student_id: null, kind: "lesson", pay_status: s.owes > 0 ? "issued" : "paid",
        issue_date: TODAY, due_date: TODAY, lines: [{ kind: "lesson", student_name: "Ben Bee", description: "Math", qty: 1, unit_cents: 10000, line_cents: 10000 }], net_cents: 10000, gst_cents: 900, total_cents: 10900,
        gst_registered: true, credited_cents: 0, paid_cents: 10900 - s.owes, balance_cents: s.owes,
        payments: [{ payment_id: "p1", kind: "payment", received_on: TODAY, method: cfg.method || "family_credit", cents: 10900, reversed: s.undone }],
        credit_notes: [], can: { record_payments: true, issue_invoices: cfg.canUndoRole !== false, owner: true }, rules: { share_link: false, manual_paynow: true, partial_payments: true, overpayments: "credit" }, share: null, credit_balance_cents: s.credit });
      if (nm === "centre_invoice_applications") return res({ today: TODAY, can_undo_role: cfg.canUndoRole !== false, rows: [app(s)] });
      if (nm === "centre_undo_application") {
        if (!String(a.p_reason || "").trim()) return res(null, "REASON_REQUIRED: say why this is being undone");
        if (s.undone) return res({ already: true, payment_id: "p1" });
        var ap = app(s); if (!ap.can_undo) return res(null, "UNDO_BLOCKED: " + ap.blockers[0].text);
        s.undone = true; s.reason = a.p_reason; s.owes = 10900; s.credit += 10900; save(s); return res({ already: false, reversal_id: "r1", payment_id: "p1", undone_cents: 10900, credit_balance_cents: s.credit });
      }
      if (nm === "centre_refund_list") return res({ today: TODAY, approver_rule: "owner", rows: [] });
      if (nm === "centre_family_credit_status") return res({ today: TODAY, household_id: "h2", household_name: "Bee Family", balance_cents: s.credit, reserved_cents: 0, available_cents: s.credit, handling: "credit", approver_rule: "owner", open_invoices: [], refunds: [] });
      return res(null, "Could not find the function public." + nm);
    };
    c.from = function (t) {
      if (t === "org_notifications") {
        var o = {}; ["select", "eq", "order", "is", "limit"].forEach(function (m) { o[m] = function () { return o; }; });
        o.then = function (r, j) { return Promise.resolve({ data: S().notes, error: cfg.noNotes ? { message: "relation does not exist" } : null }).then(r, j); };
        return o;
      }
      if (t !== "memberships") return from(t);
      var o2 = {}; ["select", "eq", "order", "neq", "in", "is", "limit"].forEach(function (m) { o2[m] = function () { return o2; }; });
      o2.maybeSingle = o2.single = function () { return Promise.resolve({ data: cfg.members[0] || null, error: null }); };
      o2.then = function (r, j) { return Promise.resolve({ data: cfg.members, error: null }).then(r, j); };
      return o2;
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
const noScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
const shot = (page, name) => SC ? page.screenshot({ path: path.join(SC, name + ".png"), fullPage: true }) : null;
const calls = (page, nm) => page.evaluate((n) => window.__calls.filter((c) => c[0] === n).length, nm);
async function openInvoice(page) {
  await page.goto(BASE + "centre-money.html?id=c1&tab=invoices"); await page.waitForSelector(".cm-row");
  await page.locator(".cm-row", { hasText: "Bee Family" }).first().click(); await page.waitForSelector("#cm-sb .cm-tot");
}

(async () => {
  const browser = await chromium.launch();
  const OWNER = { members: [M(SOLO, "owner"), M(C, "owner")] };
  for (const mode of ["desktop", "phone", "dark"]) {
    const tag = "[" + mode + "] ", o = { phone: mode === "phone", dark: mode === "dark" };
    // ---- 1. family credit paid the invoice; the owner undoes it
    {
      const { ctx, page, errs } = await open(browser, OWNER, o);
      await openInvoice(page);
      const sb = (await text(page, "#cm-sb")).replace(/\s+/g, " ");
      ok(/Credit and deposit used/i.test(sb) && /Family credit used on this invoice/i.test(sb), tag + "the invoice sheet lists the credit that was used");
      ok(await page.locator("#cm-sb .cm-gh", { hasText: /^Payments$/i }).count() === 0, tag + "the internal 'payment' is not listed twice (and has no Reverse button)");
      ok(await page.locator("#cp-undo").count() === 1 && await page.locator("#cp-famcredit").count() === 1, tag + "Undo sits next to “Use or refund the family’s credit”");
      await shot(page, "undo-1-sheet-" + mode);
      await page.click("#cp-undo"); await page.waitForSelector("#cu-reason");
      ok(/back off the invoice/.test(await text(page, "#cm-sb")) && /Take back S\$109\.00 of credit from INV-9/.test(await text(page, "#cu-ok")), tag + "the form says what will happen");
      ok(await page.locator("#cu-block").count() === 0 && !(await page.locator("#cr-go").isDisabled()), tag + "nothing blocks it: the button is enabled");
      await shot(page, "undo-2-form-" + mode);
      await page.click("#cr-go"); ok(/Say why/.test(await text(page, "#cr-err")), tag + "a reason is required: " + (await text(page, "#cr-err")));
      ok(await calls(page, "centre_undo_application") === 0, tag + "nothing was sent without a reason");
      await page.fill("#cu-reason", "Applied to the wrong invoice"); await page.click("#cr-go"); await page.waitForSelector(".td-dlg");
      ok(/Undo this\?/.test(await text(page, ".td-dlg-t")) && /Take back S\$109\.00/.test(await text(page, ".td-dlg-m")), tag + "it asks first");
      await page.click(".td-dlg [data-yes]"); await page.waitForSelector("#cp-msg.ok");
      ok(/Undone\. S\$109\.00 is back in the family’s credit\./.test(await text(page, "#cp-msg")), tag + "success is said in words: " + (await text(page, "#cp-msg")));
      ok(await calls(page, "centre_undo_application") === 1, tag + "exactly one undo was sent");
      const sb2 = (await text(page, "#cm-sb")).replace(/\s+/g, " ");
      ok(/Undone/.test(sb2) && /Applied to the wrong invoice/.test(sb2) && await page.locator("#cp-undo").count() === 0, tag + "the row now says Undone, by whom and why; no Undo button is left");
      ok(/owes|Record payment/i.test(sb2) || await page.locator("#cp-pay").count() === 1, tag + "the invoice is open again (Record payment is offered)");
      ok(await noScroll(page), tag + "no sideways scroll"); await shot(page, "undo-3-done-" + mode);
      ok(errs.length === 0, tag + "no page errors " + errs.join("|")); await ctx.close();
    }
    // ---- 2. something blocks it: the reason is shown and the button is off (also: a deposit set-off, two invoices)
    {
      const { ctx, page, errs } = await open(browser, Object.assign({ blocked: true, method: "deposit", also: ["INV-10"] }, OWNER), o);
      await openInvoice(page);
      const sb = (await text(page, "#cm-sb")).replace(/\s+/g, " ");
      ok(/Deposit kept against this invoice/.test(sb) && /also paid INV-10/.test(sb), tag + "a deposit set-off that also paid another invoice says so");
      ok(/Can’t be undone: Invoice INV-9 has a credit note/.test(sb), tag + "the row says what blocks it");
      await page.click("#cp-undo"); await page.waitForSelector("#cu-block");
      ok(/Can’t be undone: Invoice INV-9 has a credit note/.test(await text(page, "#cu-block")) && await page.locator("#cr-go").isDisabled(), tag + "the form shows the blocker and the button is disabled");
      await shot(page, "undo-4-blocked-" + mode);
      ok(await calls(page, "centre_undo_application") === 0, tag + "nothing was sent");
      ok(await noScroll(page), tag + "no sideways scroll");
      ok(errs.length === 0, tag + "no page errors " + errs.join("|")); await ctx.close();
    }
    // ---- 3. a staff member who only records payments sees it but can't undo
    {
      const { ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["record_payments"])], canUndoRole: false }, o);
      await openInvoice(page);
      ok(/Only the owner or a staff member who issues invoices can undo this/.test(await text(page, "#cm-sb")) && await page.locator("#cp-undo").count() === 0, tag + "no Undo for a staff member without issue_invoices; the sheet says who can");
      ok(errs.length === 0, tag + "no page errors " + errs.join("|")); await ctx.close();
    }
    // ---- 4. the migration isn't there yet: the invoice sheet is exactly as before
    {
      const { ctx, page, errs } = await open(browser, Object.assign({ missing: true }, OWNER), o);
      await openInvoice(page);
      ok(await page.locator("#cp-undo").count() === 0 && /Payments/i.test(await text(page, "#cm-sb")) && /Family credit/i.test(await text(page, "#cm-sb")), tag + "without the migration the old sheet is shown and nothing breaks");
      ok(errs.length === 0, tag + "no page errors " + errs.join("|")); await ctx.close();
    }
    // ---- 5. the owner is told that four-eyes fell back; "Got it" dismisses it; staff get nothing
    {
      const note = { id: "n1", title: "Refund approval is back to “the owner approves”", body: "The setting “someone other than the person who asked” needs a second approver, and a staff member was removed. It has been changed back to “the owner approves”.", created_at: "2026-11-27T01:00:00Z" };
      const { ctx, page, errs } = await open(browser, Object.assign({ notes: [note] }, OWNER), o);
      await page.goto(BASE + "centre-money.html?id=c1&tab=refunds"); await page.waitForSelector("#cm-notices [data-dismiss]");
      ok(/Refund approval is back to/.test(await text(page, "#cm-notices")) && /a staff member was removed/.test(await text(page, "#cm-notices")), tag + "the owner sees the notice on the Money page");
      await shot(page, "undo-5-notice-" + mode);
      ok(await noScroll(page), tag + "no sideways scroll");
      await page.click("#cm-notices [data-dismiss]"); await page.waitForFunction(() => document.querySelector("#cm-notices").children.length === 0);
      ok(await calls(page, "org_notification_dismiss") === 1, tag + "“Got it” dismisses it (once)");
      await page.reload(); await page.waitForSelector("#cr-sum"); ok(await page.locator("#cm-notices [data-dismiss]").count() === 0, tag + "and it stays gone");
      ok(errs.length === 0, tag + "no page errors " + errs.join("|")); await ctx.close();
    }
    // ---- 6. the settings wizard: four-eyes is switched off, with the reason, until a second approver exists
    for (const ready of [false, true]) {
      const members = ready ? [M(SOLO, "owner"), M(C, "owner"), M(C, "staff", ["issue_invoices"], { user_id: "u2", display_name: "Bea" }), M(C, "staff", ["record_payments"], { user_id: "u3", display_name: "Pat" })]
                            : [M(SOLO, "owner"), M(C, "owner"), M(C, "staff", ["issue_invoices", "record_payments"], { user_id: null, status: "invited", display_name: "Sam" })];
      const { ctx, page, errs } = await open(browser, { members: members }, o);
      await page.goto(BASE + "org.html?id=o2#billing"); await page.waitForSelector("#f-billing-deposit-refund_approved_by");
      const opt = page.locator("#f-billing-deposit-refund_approved_by option[value='\"four_eyes\"']");
      const dis = await opt.evaluate((e) => e.disabled), why = await page.locator("#og-fe-why").count();
      if (ready) ok(!dis && why === 0, tag + "wizard: a second approver exists → four-eyes can be chosen, no warning");
      else {
        ok(dis && /needs a second approver/.test(await opt.textContent()), tag + "wizard: four-eyes is disabled (“needs a second approver”) while the owner is alone (a pending invite doesn't count)");
        ok(/Add a staff member who issues invoices/.test(await text(page, "#og-fe-why")) && /who records payments/.test(await text(page, "#og-fe-why")), tag + "and the reason is in plain words");
      }
      ok(!(await page.locator("#f-billing-deposit-refund_approved_by option[value='\"owner\"']").evaluate((e) => e.disabled)) && !(await page.locator("#f-billing-deposit-refund_approved_by option[value='\"staff\"']").evaluate((e) => e.disabled)), tag + "owner and staff are always available");
      ok(await noScroll(page), tag + "no sideways scroll"); await shot(page, "undo-6-wizard-" + (ready ? "ready" : "alone") + "-" + mode);
      ok(errs.length === 0, tag + "no page errors " + errs.join("|")); await ctx.close();
    }
  }
  await browser.close(); console.log(fails ? fails + " FAILED" : "ALL PASS"); process.exit(fails ? 1 : 0);
})();
