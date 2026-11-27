// Browser check for Tutor pay (T4 step S7): Pay list · Rates · Lessons taught. Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/centre-tutor-pay.check.js [screenshot-dir]
// The database functions are replaced by a small in-memory stand-in (tests/sql/centre_tutor_pay_test.sql proves the real ones). State lives in localStorage so a
// reload keeps it. Runs on desktop, at 390px and in dark mode. All names are fake.
// The click-through of the plan's S7/S8 rows: the pay list shows what is due and what is held until families pay · open a tutor · record a part payment (more than is
// due is refused) · add a bonus (a reason is required) · download the list (it is logged first, no bank details) · Rates: set a percentage rate (a bad one is refused),
// the history shows it · Lessons taught has no money · report-only centres say so · a tutor is sent to My lessons · missing migration / no permission say so.
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
    return { rates: [
      { id: "r1", student_id: null, level: null, method: "per_lesson", amount_cents: 5000, percent_bp: null, effective_from: "2026-01-01", reason: "Starting rate", in_force: true },
      { id: "r2", student_id: "st1", student_name: "Kid One", level: null, method: "per_lesson", amount_cents: 7000, percent_bp: null, effective_from: "2026-03-01", reason: "Exam class", in_force: true }],
      paid: 0, adj: [], pay: [], seq: 5, exports: 0 };
  }
  function S() { try { return JSON.parse(localStorage.getItem("__tp") || "null") || fresh(); } catch (e) { return fresh(); } }
  function save(s) { localStorage.setItem("__tp", JSON.stringify(s)); }
  function res(d, e) { return Promise.resolve({ data: d == null ? null : d, error: e ? { message: e } : null }); }
  window.__calls = [];
  window.__override = function (c) {
    var from = c.from.bind(c), rpc = c.rpc.bind(c);
    c.rpc = function (nm, a) {
      window.__calls.push([nm, a]);
      if (nm === "staff_home") return res({ org_id: "c1", org_name: "Demo Learning Centre", status: "active", today: TODAY, can: { students: true, timetable: true, charges: true }, students_active: 4, today_lessons: 0 });
      if (!/^centre_tutor/.test(nm)) return rpc(nm, a);
      if (cfg.missing) return res(null, "Could not find the function public." + nm);
      if (cfg.denied) return res(null, "NOT_ALLOWED: your account can't see or change tutor pay at this centre");
      if (cfg.off) return res(null, "PAY_OFF: tutor pay is switched off in Centre settings");
      var s = S(), mode = cfg.mode || "full", ms = (a.p_month || TODAY).slice(0, 7) + "-01";
      if (mode === "report" && /pay_list|pay_detail|pay_adjust|pay_record|pay_reverse|export_log/.test(nm)) return res(null, "PAY_REPORT_ONLY: this centre uses the lessons-taught report only");
      var out = Math.max(0, 22000 + s.adj.reduce(function (t, x) { return t + x.amount_cents; }, 0) - s.paid);
      if (nm === "centre_tutor_rate_list") return res({ today: TODAY, mode: mode, default_method: "per_hour", class_type: "both",
        tutors: [{ membership_id: "m1", name: "Tutor Tia", role: "tutor", employment_type: "employee", status: "active", frozen_to: null, rates: s.rates },
                 { membership_id: "m2", name: "Tutor Tom", role: "tutor", employment_type: "freelancer", status: "active", frozen_to: null, rates: [] }],
        students: [{ id: "st1", name: "Kid One" }, { id: "st2", name: "Kid Two" }], levels: ["Sec 3"] });
      if (nm === "centre_tutor_rate_set") {
        if (a.p_method === "percent_of_fee" && (a.p_percent_bp < 0 || a.p_percent_bp > 10000)) return res(null, "BAD_RATE: the percentage must be between 0% and 100%");
        s.rates.unshift({ id: "r" + (s.seq++), student_id: a.p_student, student_name: a.p_student ? "Kid Two" : null, level: a.p_level, method: a.p_method, amount_cents: a.p_amount_cents, percent_bp: a.p_percent_bp, effective_from: a.p_effective_from, reason: a.p_reason, in_force: a.p_effective_from <= TODAY });
        save(s); return res({ id: "rx", effective_from: a.p_effective_from, method: a.p_method });
      }
      if (nm === "centre_tutor_taught_report") return res({ month: ms, unassigned_lessons: 1, tutors: [{ membership_id: "m1", name: "Tutor Tia", employment_type: "employee", lessons: 8, minutes: 480, students: 3, cancelled: 1, trials: 1 }] });
      if (nm === "centre_tutor_pay_list") return res({ period_from: ms, period_to: ms.slice(0, 7) + "-28", month: ms, cutoff_day: 28, pay_day: 7, payable_when: "parent_paid", adjustments_on: true, unassigned_lessons: 0, today: TODAY,
        tutors: [{ membership_id: "m1", name: "Tutor Tia", employment_type: "employee", status: "active", lessons: 6, minutes: 360, carry_cents: 0, released_cents: 20000, monthly_cents: 0,
                   adjustments_cents: s.adj.reduce(function (t, x) { return t + x.amount_cents; }, 0), due_cents: 20000 + s.adj.reduce(function (t, x) { return t + x.amount_cents; }, 0) + 2000, paid_cents: s.paid, outstanding_cents: out, held_cents: 5000, held_lessons: 1, waiting_invoice: 0, waiting_charge: 1, no_rate: 0, frozen_to: null,
                   pay_state: s.paid > 0 ? (out > 0 ? "part_paid" : "paid") : "unpaid" },
                  { membership_id: "m2", name: "Tutor Tom", employment_type: "freelancer", status: "active", lessons: 2, minutes: 120, carry_cents: 0, released_cents: 0, monthly_cents: 0, adjustments_cents: 0, due_cents: 0, paid_cents: 0, outstanding_cents: 0, held_cents: 0, held_lessons: 0, waiting_invoice: 0, waiting_charge: 0, no_rate: 2, frozen_to: null, pay_state: "nothing_due" }],
        totals: { due_cents: 22000, paid_cents: s.paid, outstanding_cents: out, held_cents: 5000 } });
      if (nm === "centre_tutor_pay_detail") return res({ membership_id: a.p_membership, name: "Tutor Tia", period_from: ms, period_to: ms.slice(0, 7) + "-28",
        lines: [{ lesson_id: "l1", date: ms.slice(0, 7) + "-05", student: "Kid One", minutes: 60, lesson_status: "done", trial: false, method: "per_lesson", scope: "student", earn_cents: 7000, base_cents: null, state: "payable", released_cents: 7000, held_cents: 0, in_period: true },
                {  lesson_id: "l2", date: ms.slice(0, 7) + "-06", student: "Kid Two", minutes: 60, lesson_status: "done", trial: false, method: "per_lesson", scope: "default", earn_cents: 5000, base_cents: null, state: "held", released_cents: 0, held_cents: 5000, in_period: true },
                {  lesson_id: "l3", date: ms.slice(0, 7) + "-07", student: "Kid Two", minutes: 60, lesson_status: "cancelled", trial: false, method: null, scope: null, earn_cents: null, base_cents: null, state: "waiting_charge", released_cents: 0, held_cents: null, in_period: true }],
        adjustments: s.adj, payments: s.pay });
      if (nm === "centre_tutor_pay_adjust") {
        if (!a.p_reason || !String(a.p_reason).trim()) return res(null, "REASON_REQUIRED: say why this bonus or deduction is being made");
        s.adj.push({ id: "a" + (s.seq++), kind: a.p_amount_cents > 0 ? "bonus" : "deduction", amount_cents: a.p_amount_cents, effective_on: a.p_on, reason: a.p_reason }); save(s); return res({ id: "ax" });
      }
      if (nm === "centre_tutor_pay_record") {
        if (a.p_amount_cents > out) return res(null, "TOO_MUCH: only " + out + " is still to pay for this period");
        s.paid += a.p_amount_cents; s.pay.push({ id: "p" + (s.seq++), kind: "payment", amount_cents: a.p_amount_cents, paid_on: a.p_paid_on, method: a.p_method, reference: a.p_reference, reversed: false }); save(s);
        return res({ id: "px", amount_cents: a.p_amount_cents, outstanding_cents: out - a.p_amount_cents });
      }
      if (nm === "centre_tutor_pay_reverse") {
        var p = s.pay.filter(function (x) { return x.id === a.p_payment; })[0]; if (!p) return res(null, "NOT_FOUND");
        p.reversed = true; s.paid -= p.amount_cents; s.pay.push({ id: "p" + (s.seq++), kind: "reversal", amount_cents: p.amount_cents, paid_on: TODAY, method: p.method, reference: null, reversed: false }); save(s); return res({ already: false });
      }
      if (nm === "centre_tutor_pay_export_log") { s.exports++; save(s); return res({ logged: true }); }
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
  const ctx = await browser.newContext({ viewport: opt.phone ? { width: 390, height: 780 } : { width: 1280, height: 800 }, acceptDownloads: true });
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
const confirmDlg = async (page) => { await page.waitForSelector(".td-dlg"); await page.click(".td-dlg [data-yes]"); };

(async () => {
  const browser = await chromium.launch();
  for (const mode of ["desktop", "phone", "dark"]) {
    const tag = "[" + mode + "] ";
    const { ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")] }, { phone: mode === "phone", dark: mode === "dark" });
    await page.goto(BASE + "centre-tutor-pay.html?id=c1"); await page.waitForSelector("#tp-paybody .cm-row");
    const t0 = await text(page, "#tp-paybody");
    ok(/Tutor Tia/.test(t0) && /Tutor Tom/.test(t0), tag + "the pay list shows both tutors");
    ok(/S\$50\.00 held/.test(t0) && /1 lesson waiting/.test(t0) && /2 with no rate/.test(t0), tag + "it says what is held until families pay, what waits for a charge, and who has no rate");
    ok(/to pay/.test(await text(page, "#tp-paybody .cm-sum-s")) && /held until families pay/.test(await text(page, "#tp-paybody .cm-sum-s")), tag + "the summary line");
    ok(/after the family’s payment/.test(t0), tag + "it explains the 'paid after the parent pays' rule");
    ok(await page.locator("#tp-tab-pay").getAttribute("aria-selected") === "true", tag + "a full-pay centre opens on the Pay list");
    ok(/private|never see/i.test(await text(page, "#tp")), tag + "the page says tutors never see pay");
    if (mode === "phone") ok(await noScroll(page), tag + "no sideways scrolling at 390px");
    if (SC) await page.screenshot({ path: path.join(SC, "tutor-pay-list-" + mode + ".png"), fullPage: true });

    // open Tia: due, held, lessons with their state chips
    await page.locator('#tp-paybody [data-t="0"]').click(); await page.waitForSelector("#cm-sheet.on .tp-ln");
    const sh = await text(page, "#cm-sb");
    ok(/Due/.test(sh) && /Still to pay/.test(sh) && /S\$220\.00/.test(sh), tag + "the sheet shows what is due and what is still to pay");
    ok(/Held/.test(sh) && /Payable/.test(sh) && /Charge not typed/.test(sh), tag + "each lesson shows its state (payable, held, charge not typed)");
    ok(/held until the families pay/.test(sh), tag + "held money is explained and not part of what is due");
    if (mode === "phone") ok(await noScroll(page), tag + "the sheet fits a phone");
    await page.waitForTimeout(400);
    if (SC) await page.screenshot({ path: path.join(SC, "tutor-pay-sheet-" + mode + ".png") });

    // a part payment: too much first
    await page.click("#tp-rec"); await page.waitForSelector("#tp-amt");
    await page.fill("#tp-amt", "9999"); await page.click("#tp-go");
    ok(/Only S\$220\.00 is still to pay/.test(await text(page, "#tp-smsg")), tag + "paying more than is due is refused before anything is sent");
    ok(await calls(page, "centre_tutor_pay_record") === 0, tag + "nothing was sent");
    await page.fill("#tp-amt", "100"); await page.fill("#tp-ref", "DBS 123456789012"); await page.click("#tp-go");
    ok(/last 4 digits/.test(await text(page, "#tp-smsg")), tag + "a whole account number in the reference is refused");
    await page.fill("#tp-ref", "Pay run 1"); await page.click("#tp-go"); await confirmDlg(page);
    await page.waitForFunction(() => /Part paid/.test(document.querySelector("#tp-paybody").innerText));
    ok(/Recorded S\$100\.00/.test(await text(page, "#tp-smsg")) && /S\$120\.00/.test(await text(page, "#cm-sb")), tag + "a part payment: S$100 recorded, S$120 still to pay");
    ok(/Part paid/.test(await text(page, "#tp-paybody")), tag + "the list now says Part paid");
    // a bonus needs a reason
    await page.click("#tp-adj"); await page.waitForSelector("#tp-reason");
    await page.fill("#tp-amt", "25"); await page.click("#tp-go");
    ok(/Say why/.test(await text(page, "#tp-smsg")), tag + "a bonus without a reason is refused");
    await page.fill("#tp-reason", "Great month"); await page.click("#tp-go");
    await page.waitForFunction(() => /Great month/.test(document.querySelector("#cm-sb").innerText));
    ok(/Bonus · .*Great month/.test(await text(page, "#cm-sb")), tag + "the bonus appears with its reason");
    // reverse the payment
    await page.click("[data-rev]"); await page.waitForSelector(".td-dlg-in");
    await page.fill(".td-dlg-in", "Paid the wrong person");
    await confirmDlg(page);
    await page.waitForFunction(() => /Reversed/.test(document.querySelector("#cm-sb").innerText));
    ok(/Payment reversed/.test(await text(page, "#tp-smsg")) || /Reversed/.test(await text(page, "#cm-sb")), tag + "a wrong payment is reversed, not edited (it stays listed as Reversed)");
    await page.click("#cm-sx"); await page.waitForTimeout(350);

    // the CSV: logged first, only people still owed, no bank details
    const dl = page.waitForEvent("download");
    await page.click("#tp-csv"); const d = await dl;
    const csv = fs.readFileSync(await d.path(), "utf8");
    ok(/^﻿Payee,Employment,Amount \(S\$\),Reference,Period/.test(csv) && /Tutor Tia,Employee,2\d\d\.00,Tutor pay /.test(csv), tag + "the CSV lists who is owed what");
    ok(!/Tutor Tom/.test(csv), tag + "a tutor owed nothing is not on the list");
    ok(!/account|bank|uen/i.test(csv.split("\n").slice(1).join("")), tag + "no bank details in the list");
    ok(await calls(page, "centre_tutor_pay_export_log") === 1, tag + "the export was logged in the audit log");
    ok(/\.csv$/.test(d.suggestedFilename()), tag + "file name " + d.suggestedFilename());

    // Rates
    await page.click("#tp-tab-rates"); await page.waitForSelector("#tp-rates .cm-row");
    ok(/S\$50\.00 per lesson · 1 special rate/.test(await text(page, "#tp-rates")), tag + "Tia: usual rate and one special rate");
    ok(/No rate yet/.test(await text(page, "#tp-rates")), tag + "Tom: no rate yet is shown in amber");
    await page.locator('#tp-rates [data-r="0"]').click(); await page.waitForSelector("#tp-new");
    ok(/Exam class/.test(await text(page, "#cm-sb")) && /Student: Kid One/.test(await text(page, "#cm-sb")) && /In force/.test(await text(page, "#cm-sb")), tag + "the history lists each rate, its reason and which one is in force");
    await page.click("#tp-new"); await page.waitForSelector("#tp-method");
    ok(!(await page.locator("#tp-method option[value=inherit]").count()), tag + "the usual rate has no 'back to the usual rate' choice");
    await page.selectOption("#tp-scope", "student"); await page.waitForSelector("#tp-stu");
    ok(await page.locator("#tp-method option[value=monthly_fixed]").count() === 0 && await page.locator("#tp-method option[value=inherit]").count() === 1, tag + "a student rate has no monthly amount");
    await page.selectOption("#tp-scope", "default");
    await page.selectOption("#tp-method", "percent_of_fee"); await page.waitForSelector("#tp-pct");
    await page.fill("#tp-pct", "150"); await page.fill("#tp-reason", "Move to commission"); await page.click("#tp-go");
    ok(/between 0% and 100%/.test(await text(page, "#tp-smsg")), tag + "a percentage above 100% is refused");
    await page.fill("#tp-pct", "60"); await page.fill("#tp-from", "2099-01-01"); await page.click("#tp-go");
    await page.waitForFunction(() => /60% of the fee/.test(document.querySelector("#cm-sb").innerText));
    ok(/Coming/.test(await text(page, "#cm-sb")) && /In force/.test(await text(page, "#cm-sb")), tag + "the new rate is saved as 'coming', the old one stays in force until its date");
    if (SC) await page.screenshot({ path: path.join(SC, "tutor-pay-rates-" + mode + ".png") });
    await page.click("#cm-sx"); await page.waitForTimeout(350);

    // Lessons taught: no money
    await page.click("#tp-tab-taught"); await page.waitForSelector("#tp-taught .cm-row");
    const tt = await text(page, "#tp-taught");
    ok(/8 lessons · 8h · 3 students/.test(tt) && /1 cancelled/.test(tt) && /1 trial/.test(tt) && /no tutor assigned/.test(tt), tag + "the lessons-taught report");
    ok(!/S\$/.test(tt), tag + "the report has no money on it");
    ok(errs.length === 0, tag + "no console/page errors " + errs.join("|"));
    await ctx.close();
  }

  // report-only centre: the money list says so, rates still work
  { const { ctx, page, errs } = await open(browser, { mode: "report", members: [M(SOLO, "owner"), M(C, "owner")] });
    await page.goto(BASE + "centre-tutor-pay.html?id=c1"); await page.waitForSelector("#tp-rates .cm-row");
    ok(await page.locator("#tp-tab-rates").getAttribute("aria-selected") === "true", "report-only centre: opens on Rates");
    await page.click("#tp-tab-pay"); await page.waitForSelector("#tp-paybody .cm-block");
    ok(/report only/i.test(await text(page, "#tp-paybody")), "report-only centre: the Pay list explains why there is no money list");
    ok(errs.length === 0, "report-only: no errors " + errs.join("|")); await ctx.close(); }
  // switched off / migration missing / no permission
  for (const [cfg, re, label] of [[{ off: true }, /switched off/, "tutor pay switched off"], [{ missing: true }, /migration_centre_tutor_pay/, "migration not run yet"], [{ denied: true }, /Run tutor pay/, "no permission"]]) {
    const { ctx, page } = await open(browser, Object.assign({ members: [M(SOLO, "owner"), M(C, "staff", ["issue_invoices"])] }, cfg));
    await page.goto(BASE + "centre-tutor-pay.html?id=c1"); await page.waitForSelector("#tp-paybody .cm-block");
    ok(re.test(await text(page, "#tp-paybody")), label + ": says so in plain words"); await ctx.close();
  }
  // a tutor is sent to My lessons
  { const { ctx, page } = await open(browser, { members: [M(C, "tutor")] });
    await page.goto(BASE + "centre-tutor-pay.html?id=c1"); await page.waitForTimeout(1200);
    ok(/\/tutor(\.html)?(\?|$)/.test(page.url()), "a tutor can't stay on the page: sent to My lessons (" + page.url() + ")"); await ctx.close(); }
  // the More menu: owner sees Tutor pay, staff without the permission do not
  { const { ctx, page } = await open(browser, { members: [M(C, "owner")] }, { phone: true });
    await page.goto(BASE + "centre-tutor-pay.html?id=c1"); await page.waitForSelector("#tp-paybody .cm-row");
    ok(await page.locator('a[href*="centre-tutor-pay"]').count() > 0, "the owner has Tutor pay in the menu"); await ctx.close(); }
  { const { ctx, page } = await open(browser, { members: [M(C, "staff", ["issue_invoices"])] }, { phone: true });
    await page.goto(BASE + "centre-money.html?id=c1"); await page.waitForTimeout(1200);
    ok(await page.locator('a[href*="centre-tutor-pay"]').count() === 0, "staff without 'Run tutor pay' have no Tutor pay in the menu"); await ctx.close(); }
  await browser.close(); console.log(fails ? fails + " FAILED" : "ALL PASS"); process.exit(fails ? 1 : 0);
})();
