// Browser check for Money > Email and the invoice sheet's "Email invoice" (T7.3). Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/centre-email.check.js [screenshot-dir]
// The database functions and /api/email-send are replaced by a small in-memory stand-in (tests/sql/invoice_email_test.sql proves the real functions and
// tests/invoice-email-api.test.js the server), because the DEV project does not have db/migration_invoice_email.sql yet. State lives in localStorage so a
// reload keeps it. Runs on desktop, at 390px and in dark mode. All names and addresses are fake (@example.test).
// The click-through: three emails waiting and "sends over 2 days" · who sent what, masked addresses only · cancel one (asks first) · Send now (the server answers in
// words) · queue all unsent · an address that bounced, marked fixed · the reminder schedule in plain words · off / missing / not allowed · the invoice sheet:
// choose the billing contacts, Email invoice, "send it again?".
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
    return { bad: cfg.noBad ? [] : [{ guardian_id: "g9", name: "Mdm Wee", family: "Wee Family", household_id: "h9", to_masked: "w***@e***.test", since: new Date().toISOString() }],
      q: [
        { id: "q1", kind: "invoice", status: "queued", reason: null, attempts: 0, requested_at: new Date().toISOString(), invoice_number: "INV-1", family: "Lim Family", to_masked: "l***@e***.test", by: "Olivia Owner", automatic: false },
        { id: "q2", kind: "reminder", reminder_no: 1, status: "queued", reason: null, attempts: 0, requested_at: new Date().toISOString(), invoice_number: "INV-2", family: "Tan Family", to_masked: "t***@e***.test", by: null, automatic: true },
        { id: "q3", kind: "receipt", status: "queued", reason: null, attempts: 0, requested_at: new Date().toISOString(), invoice_number: "INV-3", family: "Ong Family", to_masked: "o***@e***.test", by: null, automatic: true },
        { id: "q4", kind: "invoice", status: "sent", reason: null, attempts: 1, requested_at: new Date().toISOString(), invoice_number: "INV-0", family: "Aw Family", to_masked: "a***@e***.test", by: "Olivia Owner", automatic: false },
        { id: "q5", kind: "invoice", status: "skipped", reason: "no_email", attempts: 0, requested_at: new Date().toISOString(), invoice_number: "INV-4", family: "Neo Family", to_masked: null, by: null, automatic: true }],
      log: [{ id: 3, at: new Date().toISOString(), kind: "invoice", template: "invoice:custom", result: "sent", detail: null, attempt: 1, to_masked: "a***@e***.test", invoice_number: "INV-0", by: "Olivia Owner", automatic: false },
        { id: 2, at: new Date().toISOString(), kind: "invoice", template: "invoice", result: "skipped", detail: "no_email", attempt: null, to_masked: null, invoice_number: "INV-4", by: null, automatic: true },
        { id: 1, at: new Date().toISOString(), kind: "invoice", template: "invoice", result: "retry", detail: "http_503", attempt: 1, to_masked: "m***@e***.test", invoice_number: "INV-9", by: null, automatic: true }],
      sentToday: 0, enqueued: [], dup: false };
  }
  function S() { try { return JSON.parse(localStorage.getItem("__ce") || "null") || fresh(); } catch (e) { return fresh(); } }
  function save(s) { localStorage.setItem("__ce", JSON.stringify(s)); }
  function res(d, e) { return Promise.resolve({ data: d == null ? null : d, error: e ? { message: e } : null }); }
  function status(s) {
    var queued = s.q.filter(function (x) { return x.status === "queued"; }).length, cap = 2, rem = Math.max(cap - s.sentToday, 0);
    return { mode: cfg.mode || "staff_send", queued: queued, sending: 0, sent_today: s.sentToday, failed_24h: cfg.failed || 0, skipped_24h: 1, daily_cap: cap, per_hour: 60, remaining_today: rem,
      sends_over_days: queued === 0 ? 0 : queued <= rem ? 1 : 1 + Math.ceil((queued - rem) / cap), bad_addresses: s.bad.length, last_sent_at: null, reminders_on: cfg.remindersOn !== false, receipts_on: true,
      late_fee_notice_on: false, share_link: cfg.shareOff ? false : true, today: TODAY };
  }
  window.__calls = []; window.__sends = 0;
  // what /api/email-send does to the pretend queue (the Node side calls this from its route handler)
  window.__sendAll = function () {
    var s = S(), n = 0, room = Math.max(2 - s.sentToday, 0);
    s.q.forEach(function (x) { if (x.status === "queued" && n < room) { x.status = "sent"; n++; } });
    s.sentToday += n; save(s); window.__sends++; return n;
  };
  window.__override = function (c) {
    var from = c.from.bind(c), rpc = c.rpc.bind(c);
    c.rpc = function (nm, a) {
      window.__calls.push([nm, a]);
      if (nm === "staff_home") return res({ org_id: "c1", org_name: "Demo Learning Centre", status: "active", today: TODAY, can: { students: true, timetable: true, charges: true }, students_active: 4, today_lessons: 0, today_marked: 0, today_to_mark: 0, unmarked_past: 0, no_tutor_14d: 0, pending_charges: 0, trials_this_month: 0 });
      if (/^centre_invoice_account_/.test(nm)) {
        if (nm === "centre_invoice_account_list") return res({ today: TODAY, counts: { all: 1, unpaid: 1, overdue: 0, part_paid: 0, paid: 0, void: 0 }, outstanding_cents: 10900, overdue_cents: 0,
          rows: [{ id: "i1", number: "INV-1", name: "Lim Family", household_id: "h1", kind: "lesson", issue_date: TODAY, due_date: TODAY, total_cents: 10900, credited_cents: 0, paid_cents: 0, balance_cents: 10900, pay_status: "issued" }] });
        return res({ id: "i1", number: "INV-1", name: "Lim Family", household_id: "h1", kind: "lesson", issue_date: TODAY, due_date: TODAY, total_cents: 10900, credited_cents: 0, paid_cents: 0, balance_cents: 10900, pay_status: "issued", today: TODAY,
          status: "issued", gst_registered: false, gst_rate_bp: 0, gst_inclusive: false, net_cents: 10900, gst_cents: 0, can: { record_payments: true, issue_invoices: cfg.canInvoice !== false, owner: true },
          rules: { partial_payments: true, overpayments: "credit", manual_paynow: true, share_link: true }, credit_balance_cents: 0, share: null, payments: [], credit_notes: [], lines: [{ position: 1, student_name: "Sophie Lim", description: "Math lessons", qty: 2, unit_cents: 5450, line_cents: 10900, kind: "lesson" }] });
      }
      if (!/^email_/.test(nm)) { if (/^centre_/.test(nm)) return res(null, "Could not find the function public." + nm); return rpc(nm, a); }
      if (cfg.missing) return res(null, "Could not find the function public." + nm);
      if (cfg.denied) return res(null, "NOT_ALLOWED: your account can't see invoices and payments at this centre");
      var s = S();
      if (nm === "email_queue_status") return res(status(s));
      if (nm === "email_queue_list") return res(s.q.filter(function (x) { return !a.p_status || x.status === a.p_status; }));
      if (nm === "email_log_list") return res(s.log);
      if (nm === "email_bad_list") return res(s.bad);
      if (nm === "email_reminder_preview") return res({ enabled: cfg.remindersOn !== false && (cfg.mode || "staff_send") !== "off", mode: cfg.mode || "staff_send", first_after_days: 3, repeat_days: 7, max_count: 3, overdue_invoices: 5, due_now: 2 });
      if (nm === "email_clear_bad") { s.bad = []; save(s); return res({ ok: true, bad_addresses: 0 }); }
      if (nm === "email_queue_cancel") { var n = 0; s.q.forEach(function (x) { if (a.p_ids.indexOf(x.id) > -1 && x.status === "queued") { x.status = "cancelled"; x.reason = "cancelled_by_staff"; n++; } }); save(s); return res({ cancelled: n, status: status(s) }); }
      if (nm === "email_enqueue_unsent") { s.q.push({ id: "q" + (s.q.length + 1), kind: "invoice", status: "queued", reason: null, attempts: 0, requested_at: new Date().toISOString(), invoice_number: "INV-7", family: "New Family", to_masked: "n***@e***.test", by: "Olivia Owner", automatic: false }); save(s); return res({ queued: 1, skipped: 1, problems: [{ invoice_id: "x", reason: "no_email" }] }); }
      if (nm === "email_household_contacts") return res({ flagged: false, guardians: [
        { id: "ga", name: "Mrs Lim", relation: "Mother", has_email: true, to_masked: "m***@e***.test", billing_contact: false, bad: false, receives: true },
        { id: "gb", name: "Mr Lim", relation: "Father", has_email: true, to_masked: "f***@e***.test", billing_contact: false, bad: false, receives: false },
        { id: "gc", name: "Aunty Lim", relation: null, has_email: false, to_masked: null, billing_contact: false, bad: false, receives: false }] });
      if (nm === "email_set_billing_contacts") { s.contacts = a.p_guardians; save(s); return res({ flagged: a.p_guardians.length > 0, guardians: [] }); }
      if (nm === "email_enqueue") {
        s.enqueued.push([a.p_invoices[0], !!a.p_resend]);
        if (s.dup && !a.p_resend) { save(s); return res({ queued: 0, skipped: 1, problems: [{ invoice_id: a.p_invoices[0], number: "INV-1", reason: "already_sent" }], status: status(s) }); }
        s.dup = true; s.q.push({ id: "q" + (s.q.length + 1), kind: "invoice", status: "queued", reason: null, attempts: 0, requested_at: new Date().toISOString(), invoice_number: "INV-1", family: "Lim Family", to_masked: "m***@e***.test", by: "Olivia Owner", automatic: false });
        save(s); return res({ queued: 1, skipped: 0, problems: [], status: status(s) });
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
  const page = await ctx.newPage(), errs = [], api = [];
  page.on("pageerror", (e) => errs.push(String(e) + (process.env.STACK ? " " + e.stack : "")));
  page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource|net::ERR/.test(m.text())) errs.push(m.text()); });
  await page.route("**/assets/vendor/supabase-2.118.0.js", (r) => r.fulfill({ body: STUB_PLUS, contentType: "application/javascript" }));
  await page.route("**/api/email-send", async (r) => {
    api.push(JSON.parse(r.request().postData() || "{}"));
    if (cfg.apiDown) return r.fulfill({ status: 503, contentType: "application/json", body: JSON.stringify({ error: "not_configured" }) });
    const n = await page.evaluate(() => window.__sendAll());
    r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ ok: true, claimed: n, sent: n, retried: 0, failed: 0, invalid: 0, blocked: 0, stopped: null }) });
  });
  await page.addInitScript(override, cfg);
  return { ctx, page, errs, api };
}
const text = (page, sel) => page.locator(sel).innerText();
const noScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
const calls = (page, nm) => page.evaluate((n) => window.__calls.filter((c) => c[0] === n).length, nm);
const owner = { members: [M(SOLO, "owner"), M(C, "owner")] };

(async () => {
  const browser = await chromium.launch();
  for (const mode of ["desktop", "phone", "dark"]) {
    const tag = "[" + mode + "] ";
    const { ctx, page, errs, api } = await open(browser, Object.assign({ apiDown: true }, owner), { phone: mode === "phone", dark: mode === "dark" });
    await page.goto(BASE + "centre-money.html?id=c1&tab=email"); await page.waitForSelector("#ce-queue .cm-row");
    ok((await page.getAttribute("#cm-tab-mail", "aria-selected")) === "true" && /Email/.test(await text(page, "#cm-tab-mail")), tag + "there is an Email tab and it opens from ?tab=email");
    ok(/3 queued · sends over 2 days \(2 a day\) · 0 sent today/.test(await text(page, "#ce-sum")), tag + "the queue says '3 queued · sends over 2 days': " + (await text(page, "#ce-sum")).split("\n")[1]);
    ok(/A person sends invoices/.test(await text(page, "#ce-sum")) && /never tutors/.test(await text(page, "#ce-sum")), tag + "it says who sends and that tutors never receive these");
    ok(/Receipts: on/.test(await text(page, "#ce-sum")) && /Payment reminders: on/.test(await text(page, "#ce-sum")), tag + "it says which messages are on");
    const body = await text(page, "#cm-mail");
    ok(!/@example\.test/.test(body.replace(/[a-z]\*\*\*@[a-z]\*\*\*\.test/g, "")), tag + "no whole address anywhere, only masked ones (l***@e***.test)");
    ok(await page.locator("#ce-queue .cm-row").count() === 3, tag + "'Waiting' lists the three queued messages");
    ok(/Invoice · INV-1 · Lim Family/.test(await text(page, "#ce-queue")) && /Reminder 1 · INV-2/.test(await text(page, "#ce-queue")) && /automatic/.test(await text(page, "#ce-queue")) && /sent by Olivia Owner/.test(await text(page, "#ce-queue")), tag + "each row names the email, the invoice, the family and who asked (or 'automatic')");
    ok(await page.locator("#ce-sum .btn-primary").count() === 1 && /Send now/.test(await text(page, "#ce-sum .btn-primary")), tag + "one primary action: Send now");
    ok(/Addresses that bounced/i.test(await text(page, "#ce-bad")) && /w\*\*\*@e\*\*\*\.test/.test(await text(page, "#ce-bad")), tag + "a bounced address is shown to staff, masked");
    ok(/First reminder 3 days after the due date, then every 7 days, 3 reminders at most\./.test(await text(page, "#ce-rem")) && /overdue and still owed/.test(await text(page, "#ce-rem")) && /2<\/b> will get a reminder|2 will get a reminder/.test((await text(page, "#ce-rem"))), tag + "the reminder schedule is in plain words, with how many are due");
    ok(/Send log/i.test(await text(page, "#ce-log")) && /own wording/i.test(await text(page, "#ce-log")) && /Will retry/i.test(await text(page, "#ce-log")) && /Brevo was busy/.test(await text(page, "#ce-log")), tag + "the send log shows results, retries and 'own wording'");
    ok(await noScroll(page), tag + "no sideways scroll");
    if (SC) await page.screenshot({ path: path.join(SC, "email-tab-" + mode + ".png"), fullPage: true });
    // filters
    await page.click('#ce-queue [data-f="problems"]');
    ok(await page.locator("#ce-queue .cm-row").count() === 1 && /No valid email address/.test(await text(page, "#ce-queue")), tag + "'Not sent' shows the skipped one and why");
    await page.click('#ce-queue [data-f="sent"]'); ok(await page.locator("#ce-queue .cm-row").count() === 1, tag + "'Sent' shows the sent one");
    await page.click('#ce-queue [data-f="waiting"]');
    // cancel asks first
    await page.locator("#ce-queue .cm-row", { hasText: "INV-2" }).locator("[data-cancel]").click(); await page.waitForSelector(".td-dlg");
    ok(/Cancel this email\?/.test(await text(page, ".td-dlg-t")), tag + "cancelling asks first");
    await page.click(".td-dlg [data-yes]"); await page.waitForFunction(() => document.querySelectorAll("#ce-queue .cm-row").length === 2);
    ok((await calls(page, "email_queue_cancel")) === 1 && /2 queued/.test(await text(page, "#ce-sum")) && /Email cancelled/.test(await text(page, "#cm-msg")), tag + "it is cancelled and the queue shrinks to 2");
    // a bounced address, fixed
    await page.click("[data-clear]"); await page.waitForFunction(() => !document.querySelector("#ce-bad [data-clear]"));
    ok((await calls(page, "email_clear_bad")) === 1, tag + "'Fixed' clears the bounce flag");
    // Send now: the server isn't configured here → an honest message, the queue is untouched
    await page.click("#ce-now"); await page.waitForFunction(() => /isn’t set up on this site/.test(document.querySelector("#cm-msg").textContent));
    ok(api.length >= 1 && /safe in the queue/.test(await text(page, "#cm-msg")) && /2 queued/.test(await text(page, "#ce-sum")), tag + "no server key: it says so, and the messages stay queued");
    ok(errs.length === 0, tag + "no page errors" + (errs.length ? ": " + errs.join(" | ") : ""));
    await ctx.close();
  }
  // ---- Send now with a working server, then "queue all unsent"
  {
    const { ctx, page, api } = await open(browser, owner, { phone: true });
    await page.goto(BASE + "centre-money.html?id=c1&tab=email"); await page.waitForSelector("#ce-now");
    await page.waitForFunction(() => window.__sends >= 1 && /1 queued/.test(document.querySelector("#ce-sum").textContent));
    ok(/1 queued · sends over 2 days/.test(await text(page, "#ce-sum")) && /2 sent today/.test(await text(page, "#ce-sum")), "opening the tab nudges the server: 2 went out at once (today's limit), 1 waits (" + (await text(page, "#ce-sum")).split("\n")[1] + ")");
    await page.click("#ce-now"); await page.waitForFunction(() => /Nothing was due to be sent right now/.test(document.querySelector("#cm-msg").textContent));
    ok(true, "Send now with nothing due says so in words");
    ok(api.every((a) => a.org_id === "c1" && Object.keys(a).length === 1), "the browser sends only the centre id to the server (no address, no text)");
    await page.click("#ce-all"); await page.waitForSelector(".td-dlg");
    ok(/Queue all unsent invoices\?/.test(await text(page, ".td-dlg-t")), "'Queue all unsent' asks first");
    await page.click(".td-dlg [data-yes]"); await page.waitForFunction(() => /queued\./.test(document.querySelector("#cm-msg").textContent));
    ok((await calls(page, "email_enqueue_unsent")) === 1 && /1 email queued\. 1 invoice wasn’t queued \(1 no valid email address/.test(await text(page, "#cm-msg")), "queue all: says how many were queued and why others weren't (" + (await text(page, "#cm-msg")) + ")");
    await ctx.close();
  }
  // ---- email off: honest, no buttons that do nothing
  {
    const { ctx, page } = await open(browser, Object.assign({ mode: "off" }, owner), { phone: true });
    await page.goto(BASE + "centre-money.html?id=c1&tab=email"); await page.waitForSelector("#ce-sum .cm-sum-t");
    ok(/Email is off/.test(await text(page, "#ce-sum")) && await page.locator("#ce-now, #ce-all").count() === 0, "off: the page says so and has no Send buttons");
    ok(/Email is off, so no reminders are sent/.test(await text(page, "#ce-rem")) && /Change email settings/.test(await text(page, "#ce-sum")), "off: reminders say they are off, with a link to the settings");
    await ctx.close();
  }
  // ---- the link switched off: nothing can be emailed, and it says so
  {
    const { ctx, page } = await open(browser, Object.assign({ shareOff: true }, owner), { phone: true });
    await page.goto(BASE + "centre-money.html?id=c1&tab=email"); await page.waitForSelector("#ce-sum .cm-sum-t");
    ok(/shareable invoice link is switched off/.test(await text(page, "#ce-sum")), "link off: the page explains why nothing can be emailed");
    await ctx.close();
  }
  { // functions missing / not allowed
    let t = await open(browser, Object.assign({ missing: true }, owner));
    await t.page.goto(BASE + "centre-money.html?id=c1&tab=email"); await t.page.waitForSelector("#cm-mail .cm-block");
    ok(/migration_invoice_email\.sql/.test(await text(t.page, "#cm-mail")), "functions missing: the page says which migration to run"); await t.ctx.close();
    t = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["view_revenue"])], denied: true });
    await t.page.goto(BASE + "centre-money.html?id=c1&tab=email"); await t.page.waitForSelector("#cm-mail .cm-block");
    ok(/isn’t switched on for your account/.test(await text(t.page, "#cm-mail")), "not allowed: the page says who to ask"); await t.ctx.close();
  }
  // ---- the invoice's side sheet
  for (const mode of ["desktop", "phone"]) {
    const tag = "[" + mode + "] ";
    const { ctx, page, api } = await open(browser, owner, { phone: mode === "phone" });
    await page.goto(BASE + "centre-money.html?id=c1&tab=invoices"); await page.waitForSelector("#cp-list [data-i], #cm-inv .cm-row");
    await page.waitForFunction(() => window.CentreEmail && window.CentreEmail.on());
    await page.locator("#cm-inv .cm-row").first().click(); await page.waitForSelector("#cp-email");
    ok(/Email invoice/.test(await text(page, "#cp-email")), tag + "the invoice sheet has an 'Email invoice' button when email is on");
    await page.click("#cp-email"); await page.waitForSelector("#ce-send");
    const sb = (await text(page, "#cm-sb")).replace(/\s+/g, " ");
    ok(/Who gets invoices by email/.test(sb) && /m\*\*\*@e\*\*\*\.test/.test(sb) && /No email address/.test(sb) && /Gets this email/.test(sb), tag + "it lists the guardians (masked), who gets it, and who has no address");
    ok(!/@example/.test(sb.replace(/[a-z]\*\*\*@[a-z]\*\*\*\.test/g, "")), tag + "no whole address in the sheet");
    ok(await page.locator("#cm-sb .btn-primary").count() === 1 && /Email invoice INV-1 to 1 person/.test(await text(page, "#ce-send")), tag + "one primary action: 'Email invoice INV-1 to 1 person'");
    ok(await noScroll(page), tag + "no sideways scroll");
    if (SC) await page.screenshot({ path: path.join(SC, "email-invoice-sheet-" + mode + ".png") });
    await page.locator('[data-g="gb"]').check();
    await page.click("#ce-send"); await page.waitForFunction(() => window.__calls.some((c) => c[0] === "email_enqueue"));
    await page.waitForFunction(() => /Queued for 1 email/.test(document.body.innerText));
    const cs = await page.evaluate(() => ({ set: window.__calls.filter((c) => c[0] === "email_set_billing_contacts").pop()[1].p_guardians, enq: window.__calls.filter((c) => c[0] === "email_enqueue").map((c) => c[1].p_resend) }));
    ok(JSON.stringify(cs.set) === '["gb"]' && JSON.stringify(cs.enq) === "[false]", tag + "it saves the billing contacts you ticked, then queues the invoice (not a resend)");
    ok(api.length === 1 && /Queued for 1 email\. It goes out within minutes/.test(await page.evaluate(() => document.body.innerText)), tag + "then asks the server to send what is due, and says it is queued");
    // again → "send it again?"
    await page.waitForSelector("#cp-email"); await page.click("#cp-email"); await page.waitForSelector("#ce-send"); await page.click("#ce-send");
    await page.waitForSelector(".td-dlg"); ok(/Send it again\?/.test(await text(page, ".td-dlg-t")), tag + "a second press asks 'Send it again?' (it was already emailed)");
    await page.click(".td-dlg [data-yes]"); await page.waitForFunction(() => window.__calls.filter((c) => c[0] === "email_enqueue").length === 3);
    ok(JSON.stringify(await page.evaluate(() => window.__calls.filter((c) => c[0] === "email_enqueue").map((c) => c[1].p_resend))) === "[false,false,true]", tag + "and only then is it queued as a deliberate resend");
    await ctx.close();
  }
  { // email off: no button on the invoice
    const { ctx, page } = await open(browser, Object.assign({ mode: "off" }, owner), { phone: true });
    await page.goto(BASE + "centre-money.html?id=c1&tab=invoices"); await page.waitForSelector("#cm-inv .cm-row");
    await page.waitForFunction(() => window.__calls.some((c) => c[0] === "email_queue_status"));
    await page.locator("#cm-inv .cm-row").first().click(); await page.waitForSelector("#cp-copy");
    ok(await page.locator("#cp-email").count() === 0, "email off: the invoice has no Email button (copy link and WhatsApp stay)");
    await ctx.close();
  }
  await browser.close(); console.log(fails ? fails + " FAILED" : "ALL PASS"); process.exit(fails ? 1 : 0);
})();
