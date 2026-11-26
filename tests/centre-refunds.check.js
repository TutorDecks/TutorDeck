// Browser check for Money > Refunds, "Release or refund the deposit" and "Use or refund the family's credit" (T4 S5). Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/centre-refunds.check.js [screenshot-dir]
// The database functions are replaced by a small in-memory stand-in (tests/sql/centre_refunds_test.sql proves the real ones), because the DEV project
// does not have db/migration_centre_refunds.sql yet. State lives in localStorage so a reload keeps it. All names are fake.
// The click-through of the plan's S5 row: the student has ended · request the refund · approve (only the owner, or someone else under four-eyes) ·
// mark it paid with a reference (a whole account number is refused) · the deposit is no longer held · the statement shows the trail · family credit used on an invoice.
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
  var YEST = new Date(Date.now() - 86400000 - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 10);
  function fresh() { return { amyHeld: 6000, benHeld: 6000, refunds: [], credit: 9100, invOwes: 5450, applied: [] }; }
  function S() { try { return JSON.parse(localStorage.getItem("__rf") || "null") || fresh(); } catch (e) { return fresh(); } }
  function save(s) { localStorage.setItem("__rf", JSON.stringify(s)); }
  function res(d, e) { return Promise.resolve({ data: d == null ? null : d, error: e ? { message: e } : null }); }
  var who = cfg.who || "owner";                                           // owner | staff
  function view(s, r) {
    var open = r.state === "requested" || r.state === "approved";
    var can_approve = r.state === "requested" && (cfg.rule === "four_eyes" ? who !== "requester" && !!cfg.otherCanApprove : cfg.rule === "staff" ? true : who === "owner");
    return Object.assign({}, r, { approver_rule: cfg.rule || "owner", can_approve: can_approve, can_pay: r.state === "approved", can_cancel: open });
  }
  function proposal(s, who2, notice) {
    var ended = who2 === "amy";
    var held = who2 === "amy" ? s.amyHeld : s.benHeld, reserved = s.refunds.filter(function (r) { return r.student_id === who2 && (r.state === "requested" || r.state === "approved"); }).reduce(function (t, r) { return t + r.refund_cents + r.forfeit_cents + r.set_off_cents; }, 0);
    var openR = s.refunds.filter(function (r) { return r.student_id === who2 && (r.state === "requested" || r.state === "approved"); })[0];
    var base = { today: TODAY, student_id: who2, name: who2 === "amy" ? "Amy Aw" : "Ben Bee", held_cents: held, reserved_cents: reserved, available_cents: Math.max(held - reserved, 0), taxable: false,
      unpaid_cents: 10900, unpaid_invoices: [], release_rule: cfg.release || "refund_full", approver_rule: cfg.rule || "owner", notice_days: cfg.noticeDays || 0, notice_given_on: notice || null,
      notice_needed: (cfg.noticeDays || 0) > 0 && !notice, notice_short: (cfg.noticeDays || 0) > 0 && notice ? (Date.parse(YEST) - Date.parse(notice)) / 86400000 < cfg.noticeDays : null, lesson_end: ended ? YEST : null, open_refund_id: openR ? openR.id : null, note: null };
    if (held <= 0 && !openR) return Object.assign(base, { state: "nothing_held", waiting: [] });
    if (openR) return Object.assign(base, { state: "open_refund", waiting: [] });
    if (!ended) return Object.assign(base, { state: "waiting", waiting: ["The student hasn’t been ended yet. Set the day lessons run until in their profile."] });
    var rel = cfg.release || "refund_full", sug = rel === "admin_decides" ? null : rel === "refund_less_unpaid" ? { refund_cents: Math.max(held - 10900, 0), forfeit_cents: 0, set_off_cents: Math.min(held, 10900) } : { refund_cents: held, forfeit_cents: 0, set_off_cents: 0 };
    return Object.assign(base, { state: "ready", waiting: [], suggest: sug, can_request: cfg.canRequest !== false });
  }
  window.__calls = [];
  window.__override = function (c) {
    var from = c.from.bind(c), rpc = c.rpc.bind(c);
    c.rpc = function (nm, a) {
      window.__calls.push([nm, a]);
      if (nm === "staff_home") return res({ org_id: "c1", org_name: "Demo Learning Centre", status: "active", today: TODAY, can: { students: true, timetable: true, charges: true }, students_active: 4, today_lessons: 0 });
      if (!/^centre_(refund|deposit|family_credit|credit_refund|apply|invoice_account)/.test(nm)) return rpc(nm, a);
      if (cfg.missing) return res(null, "Could not find the function public." + nm);
      var s = S();
      if (nm === "centre_deposit_status") {
        var rows = [{ deposit_id: "d1", student_id: "amy", name: "Amy Aw", household_id: "h1", household_name: "Aw Family", source: "invoice_run", mode: "fixed", required_cents: 6000, due_cents: 6000, held_cents: s.amyHeld, waived_cents: 0, short_cents: 0, state: s.amyHeld > 0 ? "held" : "held", taxable: false, invoice_id: "i1", invoice_number: "INV-2", invoice_status: "issued" },
                    { deposit_id: "d2", student_id: "ben", name: "Ben Bee", household_id: "h2", household_name: "Bee Family", source: "invoice_run", mode: "fixed", required_cents: 6000, due_cents: 6000, held_cents: s.benHeld, waived_cents: 0, short_cents: 0, state: "held", taxable: false, invoice_id: "i2", invoice_number: "INV-4", invoice_status: "issued" }];
        return res({ today: TODAY, rows: rows, totals: { held_cents: s.amyHeld + s.benHeld, taxable_held_cents: 0, students_holding: (s.amyHeld > 0) + (s.benHeld > 0), required_cents: 12000, short_cents: 0, deposits: 2 } });
      }
      if (nm === "centre_deposits_held") return res({ today: TODAY, total_held_cents: s.amyHeld + s.benHeld, taxable_held_cents: 0, students_holding: 2, rows: [] });
      if (nm === "centre_deposit_ledger_get") {
        var amy = a.p_student === "amy", st = { student_id: a.p_student, name: amy ? "Amy Aw" : "Ben Bee", household_name: amy ? "Aw Family" : "Bee Family", source: "invoice_run", mode: "fixed", required_cents: 6000, held_cents: amy ? s.amyHeld : s.benHeld, waived_cents: 0, short_cents: 0, state: "held", invoice_id: "i1", invoice_status: "issued", invoice_number: "INV-2" };
        return res({ today: TODAY, student_id: a.p_student, name: st.name, status: st, entries: [{ id: "e1", date: TODAY, kind: "received", cents: 6000, invoice_number: "INV-2", balance_cents: 6000 }].concat(amy && s.amyHeld === 0 ? [{ id: "e2", date: TODAY, kind: "refunded", cents: -6000, reason: "Refunded to the family", balance_cents: 0 }] : []) });
      }
      if (nm === "centre_deposit_release_proposal") return res(proposal(s, a.p_student, a.p_notice_given_on));
      if (nm === "centre_deposit_refund_request") {
        var p = proposal(s, a.p_student, a.p_notice_given_on);
        if (p.state === "open_refund") { var ex = s.refunds.filter(function (r) { return r.id === p.open_refund_id; })[0]; return res(Object.assign(view(s, ex), { already: true })); }
        if (a.p_refund_cents + a.p_forfeit_cents + a.p_set_off_cents > p.available_cents) return res(null, "DEPOSIT_SHORT: only " + (p.available_cents / 100).toFixed(2) + " is held and free to release");
        var r = { id: "rf" + (s.refunds.length + 1), kind: "deposit", state: "requested", student_id: a.p_student, student_name: p.name, household_name: a.p_student === "amy" ? "Aw Family" : "Bee Family", refund_cents: a.p_refund_cents, forfeit_cents: a.p_forfeit_cents, set_off_cents: a.p_set_off_cents,
          held_cents: p.held_cents, taxable: false, gst_cents: 0, release_rule: p.release_rule, notice_days: p.notice_days || null, notice_given_on: a.p_notice_given_on, lesson_end: p.lesson_end, payee: a.p_payee, reason: a.p_reason, requested_by_name: cfg.who === "requester" ? "Billing Bea" : "Owen Owner", requested_on: TODAY, events: [] };
        s.refunds.push(r); save(s); return res(Object.assign(view(s, r), { already: false }));
      }
      if (nm === "centre_credit_refund_request") {
        if (a.p_cents > s.credit) return res(null, "CREDIT_SHORT: this family has only available");
        var r2 = { id: "rf" + (s.refunds.length + 1), kind: "family_credit", state: "requested", household_id: a.p_household, household_name: "Bee Family", refund_cents: a.p_cents, forfeit_cents: 0, set_off_cents: 0, held_cents: s.credit, taxable: false, gst_cents: 0, payee: a.p_payee, reason: a.p_reason, requested_by_name: "Owen Owner", requested_on: TODAY, events: [] };
        s.refunds.push(r2); save(s); return res(Object.assign(view(s, r2), { already: false }));
      }
      if (nm === "centre_refund_list") return res({ today: TODAY, approver_rule: cfg.rule || "owner", rows: s.refunds.slice().reverse().map(function (r) { return view(s, r); }) });
      if (nm === "centre_refund_statement") { var q = s.refunds.filter(function (x) { return x.id === a.p_refund; })[0]; return q ? res(Object.assign(view(s, q), { centre: "Demo Learning Centre" })) : res(null, "NOT_FOUND"); }
      if (nm === "centre_refund_approve") {
        var q2 = s.refunds.filter(function (x) { return x.id === a.p_refund; })[0], v = view(s, q2);
        if (q2.state !== "requested") return res(Object.assign(v, { already: true }));
        if (!v.can_approve) return res(null, "NOT_ALLOWED: this centre lets only the owner approve refunds (see Centre settings)");
        q2.state = "approved"; q2.events.push({ kind: "approved", on: TODAY, by: "Owen Owner" }); save(s); return res(Object.assign(view(s, q2), { already: false }));
      }
      if (nm === "centre_refund_pay") {
        var q3 = s.refunds.filter(function (x) { return x.id === a.p_refund; })[0];
        if (q3.state === "paid") return res(Object.assign(view(s, q3), { already: true }));
        if (/\d{8,}/.test(a.p_reference || "")) return res(null, "BAD_VALUE: don't type a full bank account or PayNow number here");
        q3.state = "paid"; q3.events.push({ kind: "paid", on: a.p_paid_on, by: "Owen Owner", method: a.p_method, reference: a.p_reference });
        if (q3.kind === "deposit") s[q3.student_id === "amy" ? "amyHeld" : "benHeld"] -= q3.refund_cents + q3.forfeit_cents + q3.set_off_cents; else s.credit -= q3.refund_cents;
        save(s); return res(Object.assign(view(s, q3), { already: false }));
      }
      if (nm === "centre_refund_cancel") {
        var q4 = s.refunds.filter(function (x) { return x.id === a.p_refund; })[0]; q4.state = "cancelled"; q4.events.push({ kind: "cancelled", on: TODAY, by: "Owen Owner", reason: a.p_reason }); save(s); return res(Object.assign(view(s, q4), { already: false }));
      }
      if (nm === "centre_invoice_account_list") return res({ today: TODAY, counts: { all: 1, paid: 0, issued: 1, part_paid: 0, overdue: 0, void: 0 }, rows: [{ id: "inv9", number: "INV-9", name: "Bee Family", kind: "lesson", pay_status: "issued", total_cents: 5450, balance_cents: s.invOwes, issue_date: TODAY, due_date: TODAY, paid_cents: 5450 - s.invOwes }] });
      if (nm === "centre_invoice_account_get") return res({ id: "inv9", today: TODAY, status: "issued", number: "INV-9", name: "Bee Family", household_id: "h2", student_id: null, kind: "lesson", pay_status: "issued", issue_date: TODAY, due_date: TODAY,
        lines: [{ kind: "lesson", student_name: "Ben Bee", description: "Math", qty: 1, unit_cents: 5000, line_cents: 5000 }], net_cents: 5000, gst_cents: 450, total_cents: 5450, gst_registered: true, credited_cents: 0, paid_cents: 5450 - s.invOwes, balance_cents: s.invOwes,
        payments: [], credit_notes: [], can: { record_payments: true, issue_invoices: true, owner: true }, rules: { share_link: false, manual_paynow: true, partial_payments: true, overpayments: "credit" }, share: null, credit_balance_cents: s.credit });
      if (nm === "centre_family_credit_status") return res({ today: TODAY, household_id: a.p_household, household_name: "Bee Family", balance_cents: s.credit, reserved_cents: s.refunds.filter(function (r) { return r.kind === "family_credit" && (r.state === "requested" || r.state === "approved"); }).reduce(function (t, r) { return t + r.refund_cents; }, 0),
        available_cents: s.credit - s.refunds.filter(function (r) { return r.kind === "family_credit" && (r.state === "requested" || r.state === "approved"); }).reduce(function (t, r) { return t + r.refund_cents; }, 0), handling: "credit", approver_rule: cfg.rule || "owner",
        open_invoices: s.invOwes > 0 ? [{ id: "inv9", number: "INV-9", balance_cents: s.invOwes }] : [], refunds: s.refunds.filter(function (r) { return r.kind === "family_credit"; }).map(function (r) { return view(s, r); }) });
      if (nm === "centre_apply_family_credit") {
        var n = Math.min(a.p_cents || s.credit, s.invOwes); if (s.applied.indexOf(a.p_request_key) > -1) return res({ already: true, applied_cents: n, credit_balance_cents: s.credit });
        s.credit -= n; s.invOwes -= n; s.applied.push(a.p_request_key); save(s); return res({ already: false, applied_cents: n, credit_balance_cents: s.credit });
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
const shot = (page, name) => SC ? page.screenshot({ path: path.join(SC, name + ".png"), fullPage: true }) : null;

(async () => {
  const browser = await chromium.launch();
  const OWNER = { members: [M(SOLO, "owner"), M(C, "owner")], rule: "owner" };
  for (const mode of ["desktop", "phone", "dark"]) {
    const tag = "[" + mode + "] ";
    const { ctx, page, errs } = await open(browser, OWNER, { phone: mode === "phone", dark: mode === "dark" });
    // ---- 1. a student who has not ended: the form waits and says why
    await page.goto(BASE + "centre-money.html?id=c1&tab=deposits"); await page.waitForSelector("#cd-list [data-i]");
    ok(await page.locator("#cm-tab-ref").count() === 1, tag + "there is a Refunds tab");
    await page.locator("#cd-list [data-i]", { hasText: "Ben Bee" }).click(); await page.waitForSelector("#cd-release");
    await page.click("#cd-release"); await page.waitForSelector(".cm-note.warn");
    ok(/hasn’t been ended yet/.test(await text(page, "#cm-sb")) && await page.locator("#cr-form").count() === 0, tag + "Ben has not ended: no form, the reason is shown");
    await page.click("#cr-back"); await page.waitForSelector("#cd-release"); await page.click("#cm-sx"); await page.waitForTimeout(350);
    // ---- 2. Amy has ended: the form is prefilled with the centre's suggestion
    await page.locator("#cd-list [data-i]", { hasText: "Amy Aw" }).click(); await page.waitForSelector("#cd-release"); await page.click("#cd-release"); await page.waitForSelector("#cr-form");
    ok((await page.inputValue("#cr-refund")) === "60.00" && (await page.inputValue("#cr-forfeit")) === "0.00" && (await page.inputValue("#cr-setoff")) === "0.00", tag + "release rule 'refund the whole deposit' prefills S$60.00 / 0 / 0");
    ok(/Only the owner|The owner/.test(await text(page, "#cm-sb")) && /still owes\s*S\$109\.00/.test((await text(page, "#cm-sb")).replace(/\s+/g, " ").replace("The family still owes ", "still owes ")) || /S\$109\.00/.test(await text(page, "#cm-sb")), tag + "the form shows what the family owes and who approves");
    await page.fill("#cr-refund", "60.01"); await page.fill("#cr-reason", "Left the centre"); await page.click("#cr-go");
    ok(/Only S\$60\.00 is held/.test(await text(page, "#cr-err")), tag + "S$60.01 is refused on the form: " + (await text(page, "#cr-err")));
    await page.fill("#cr-refund", "60"); await page.fill("#cr-reason", ""); await page.click("#cr-go");
    ok(/Say why/.test(await text(page, "#cr-err")), tag + "a reason is required");
    await page.fill("#cr-reason", "Left the centre"); await page.fill("#cr-payee", "Mrs Aw");
    if (SC && mode !== "dark") await page.screenshot({ path: path.join(SC, "refunds-form-" + mode + ".png") });
    await page.click("#cr-go"); await page.waitForSelector(".td-dlg");
    ok(/Ask to release Amy Aw’s deposit\?/.test(await text(page, ".td-dlg-t")) && /refund S\$60\.00/.test(await text(page, ".td-dlg-m")), tag + "it asks first and says what will happen");
    await page.click(".td-dlg [data-yes]"); await page.waitForFunction(() => /Waiting for approval/.test(document.querySelector("#cm-sm").textContent));
    ok(/Asked\./.test(await text(page, "#cr-msg")), tag + "asked: " + (await text(page, "#cr-msg")));
    const reqCalls = await page.evaluate(() => window.__calls.filter((c) => c[0] === "centre_deposit_refund_request").length);
    ok(reqCalls === 1, tag + "one request was sent");
    ok(await page.locator('[data-act="approve"]').count() === 1 && await page.locator(".btn-primary").count() === 1, tag + "the owner sees ONE primary action: Approve");
    // ---- 3. approve, then mark paid
    await page.click('[data-act="approve"]'); await page.waitForSelector(".td-dlg"); await page.click(".td-dlg [data-yes]");
    await page.waitForFunction(() => /Approved · to pay/.test(document.querySelector("#cm-sm").textContent));
    ok(/Pay the family, then mark it as paid/.test(await text(page, "#cm-sb")) && /never sends money|doesn’t send money/.test(await text(page, "#cm-sb")), tag + "after approval it says to pay the family and record it");
    await page.click('[data-act="pay"]'); await page.waitForSelector("#cr-form");
    await page.fill("#cr-ref", "DBS 0123456789"); await page.click("#cr-go");
    ok(/full bank account or PayNow number/.test(await text(page, "#cr-err")), tag + "a whole account number is refused on the form");
    await page.fill("#cr-ref", "DBS ending 6789"); await page.click("#cr-go");
    await page.waitForFunction(() => /^Deposit refund · Paid/.test(document.querySelector("#cm-sm").textContent));
    const sb = await text(page, "#cm-sb");
    ok(/Asked/.test(sb) && /Approved/.test(sb) && /Paid/.test(sb) && /Bank transfer · DBS ending 6789/.test(sb), tag + "the statement shows the trail: asked, approved, paid with method and reference");
    ok(await page.locator("[data-act]").count() === 0, tag + "a paid refund has no more buttons");
    if (SC && mode !== "dark") await page.screenshot({ path: path.join(SC, "refunds-statement-" + mode + ".png") });
    ok(await noScroll(page), tag + "no sideways scroll in the sheet");
    await page.click("#cm-sx"); await page.waitForTimeout(350);
    await page.click("#cm-tab-dep"); await page.waitForFunction(() => /S\$60\.00/.test(document.querySelector("#cd-held").textContent) && /1 student has/.test(document.querySelector("#cd-sum").textContent));
    ok(/S\$60\.00/.test(await text(page, "#cd-held")), tag + "Deposits held fell to S$60.00 (only Ben's)");
    // ---- 4. the Refunds tab
    await page.click("#cm-tab-ref"); await page.waitForSelector("#cr-list [data-i]");
    ok(/finished/i.test(await text(page, "#cr-list")) && /Amy Aw/.test(await text(page, "#cr-list")) && /Paid/.test(await text(page, "#cr-list")), tag + "the Refunds tab lists it as finished: " + (await text(page, "#cr-sum")).replace(/\s+/g, " ").slice(0, 70));
    ok(/tab=refunds/.test(page.url()), tag + "the address remembers the tab");
    if (SC) await shot(page, "refunds-list-" + mode);
    // ---- 5. a second request on the same deposit is no longer possible; Ben's waits
    await page.click("#cm-tab-dep"); await page.locator("#cd-list [data-i]", { hasText: "Amy Aw" }).click(); await page.waitForSelector("#cm-sb .cm-tot");
    ok(await page.locator("#cd-release").count() === 0, tag + "nothing is held for Amy any more: no release button");
    await page.click("#cm-sx"); await page.waitForTimeout(350);
    // ---- 6. family credit: use it on an invoice, then ask to refund the rest
    await page.click("#cm-tab-inv"); await page.waitForSelector("#cp-list [data-i]"); await page.locator("#cp-list [data-i]").first().click(); await page.waitForSelector("#cp-famcredit");
    ok(/S\$91\.00 in credit|holds S\$91\.00/.test(await text(page, "#cm-sb")), tag + "the invoice says the family holds S$91.00");
    await page.click("#cp-famcredit"); await page.waitForSelector("#cr-useform");
    ok(/Free to use or refund\s*S\$91\.00/.test((await text(page, "#cm-sb")).replace(/\s+/g, " ").replace(/\n/g, " ")) || /S\$91\.00/.test(await text(page, "#cm-sb")), tag + "the credit menu shows S$91.00 free");
    await page.click("#cr-useform"); await page.waitForSelector("#cr-form");
    ok((await page.getAttribute("#cr-amt", "placeholder")) === "54.50", tag + "using credit defaults to what the invoice needs (S$54.50)");
    await page.fill("#cr-amt", "60"); await page.click("#cr-go");
    ok(/only owes S\$54\.50/.test(await text(page, "#cr-err")), tag + "more than the invoice owes is refused on the form");
    await page.fill("#cr-amt", ""); await page.click("#cr-go"); await page.waitForFunction(() => /Paid|paid/.test(document.querySelector("#cm-sm").textContent) || !document.querySelector("#cr-form"));
    const useCalls = await page.evaluate(() => window.__calls.filter((c) => c[0] === "centre_apply_family_credit").length);
    ok(useCalls === 1, tag + "credit applied once");
    await page.waitForSelector("#cp-famcredit");
    ok(/S\$36\.50/.test(await text(page, "#cm-sb")), tag + "the invoice now says the family holds S$36.50");
    await page.click("#cp-famcredit"); await page.waitForSelector("#cr-refundform"); await page.click("#cr-refundform"); await page.waitForSelector("#cr-form");
    ok((await page.inputValue("#cr-amt")) === "36.50", tag + "refunding credit is prefilled with all that is free");
    await page.fill("#cr-reason", "Paid twice"); await page.click("#cr-go"); await page.waitForFunction(() => /Family credit refund · Waiting for approval/.test(document.querySelector("#cm-sm").textContent));
    ok(/Asked\./.test(await text(page, "#cr-msg")), tag + "credit refund asked: " + (await text(page, "#cr-msg")));
    ok(await noScroll(page), tag + "no sideways scroll");
    ok(errs.length === 0, tag + "no console or page errors " + errs.join(" | "));
    await ctx.close();
  }
  // ---- four-eyes: the person who asked can't approve, and the screen says who can
  {
    const { ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["issue_invoices", "record_payments"])], rule: "four_eyes", who: "requester", release: "refund_less_unpaid", noticeDays: 14 }, { phone: true });
    await page.goto(BASE + "centre-money.html?id=c1&tab=deposits"); await page.waitForSelector("#cd-list [data-i]");
    await page.locator("#cd-list [data-i]", { hasText: "Amy Aw" }).click(); await page.waitForSelector("#cd-release"); await page.click("#cd-release"); await page.waitForSelector("#cr-form");
    ok(/Day the family gave notice/.test(await text(page, "#cm-sb")) && /Type the day the family said they were leaving/.test(await text(page, "#cr-notice-h")), "notice rule: the form asks for the day notice was given");
    ok((await page.inputValue("#cr-refund")) === "0.00" && (await page.inputValue("#cr-setoff")) === "60.00", "release rule 'keep against unpaid invoices': S$60.00 is set off (the family owes S$109.00), refund S$0.00");
    await page.fill("#cr-notice", await page.evaluate(() => new Date(Date.now() - 5 * 86400000).toISOString().slice(0, 10))); await page.waitForFunction(() => /Less than 14 days/.test(document.querySelector("#cr-notice-h").textContent));
    ok(/Less than 14 days’ notice was given/.test(await text(page, "#cr-notice-h")), "short notice is called out");
    await page.fill("#cr-reason", "Left at short notice"); await page.click("#cr-go"); await page.waitForSelector(".td-dlg"); await page.click(".td-dlg [data-yes]");
    await page.waitForFunction(() => /Waiting for approval/.test(document.querySelector("#cm-sm").textContent));
    ok(await page.locator('[data-act="approve"]').count() === 0, "four-eyes: the requester has no Approve button");
    ok(/Someone other than Billing Bea has to approve this/.test(await text(page, "#cm-sb")), "and the screen says who can: " + (await text(page, "#cm-sb")).replace(/\s+/g, " ").slice(-120));
    ok(await page.locator('[data-act="cancel"]').count() === 1, "the requester can cancel");
    await page.click('[data-act="cancel"]'); await page.waitForSelector(".td-dlg"); await page.fill(".td-dlg-in", "Changed my mind"); await page.click(".td-dlg [data-yes]");
    await page.waitForFunction(() => /Cancelled/.test(document.querySelector("#cm-sm").textContent));
    ok(/Cancelled\. Nothing was moved/.test(await text(page, "#cr-msg")), "cancelled: " + (await text(page, "#cr-msg")));
    ok(errs.length === 0, "four-eyes: no console errors " + errs.join("|")); await ctx.close();
  }
  // ---- staff who can't act on deposits are told so, not shown a form
  {
    const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["record_payments"])], rule: "owner", canRequest: false });
    await page.goto(BASE + "centre-money.html?id=c1&tab=deposits"); await page.waitForSelector("#cd-list [data-i]");
    await page.locator("#cd-list [data-i]", { hasText: "Amy Aw" }).click(); await page.waitForSelector("#cd-release"); await page.click("#cd-release"); await page.waitForSelector(".cm-note.warn");
    ok(/Only the centre owner or a staff member who issues invoices can release a deposit/.test(await text(page, "#cm-sb")) && await page.locator("#cr-form").count() === 0, "a staff member without the permission gets a plain message and no form"); await ctx.close();
  }
  {
    const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], missing: true });
    await page.goto(BASE + "centre-money.html?id=c1&tab=refunds"); await page.waitForSelector("#cm-ref .cm-block");
    ok(/migration_centre_refunds\.sql/.test(await text(page, "#cm-ref")), "functions missing: the page says which migration to run"); await ctx.close();
  }
  {
    const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], rule: "owner" });
    await page.goto(BASE + "centre-money.html?id=c1&tab=refunds"); await page.waitForSelector("#cr-sum");
    ok(/No refunds yet/.test(await text(page, "#cm-ref")), "an empty centre explains where refunds come from"); await ctx.close();
  }
  await browser.close(); console.log(fails ? fails + " FAILED" : "ALL PASS"); process.exit(fails ? 1 : 0);
})();
