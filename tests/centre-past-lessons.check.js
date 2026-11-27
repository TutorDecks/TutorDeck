// Browser check for "Add past lessons" (T3.10). Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/centre-past-lessons.check.js [screenshot-dir]
// The database functions are replaced by a small in-memory stand-in that follows the same rules (tests/sql/past_lessons_test.sql proves the real
// ones). Here we check the SCREEN: the student picker, the weekly-pattern and typed-days modes, the preview with its counts, a refused row stops the
// button, the holiday confirmation, the reason, attended + remarks, the switched-off and no-permission messages, the student sheet, 390px phone, dark mode.
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), SCR = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
const STUB_PLUS = STUB + `;(function(){var o=window.supabase.createClient;window.supabase.createClient=function(){var c=o.apply(this,arguments);if(window.__override)window.__override(c);return c;};})();`;
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
const SOLO = { id: "s1", kind: "solo", trading_name: "Empty Shell" }, C = { id: "c1", kind: "centre", trading_name: "Demo Learning Centre" };
const M = (o, role, permissions) => ({ org_id: o.id, user_id: "u1", role, status: "active", permissions: permissions || [], organisations: o });
// reuse the stand-in of the weekly-slots check (it knows the centre pages, the student list and the student sheet) and add the four new functions
const slotsSrc = fs.readFileSync(path.join(ROOT, "tests/centre-slots.check.js"), "utf8");
const baseOverride = new Function(slotsSrc.slice(slotsSrc.indexOf("function override(cfg)"), slotsSrc.indexOf("async function open(")) + "; return override;")();

function override(cfg) {
  var TODAY = new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 10);
  function add(d, n) { var x = new Date(d + "T00:00:00Z"); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); }
  function wdOf(iso) { return (new Date(iso + "T00:00:00Z").getUTCDay() + 6) % 7; }
  var me = (cfg.members.filter(function (m) { return m.org_id === "c1"; })[0]) || { role: "tutor", permissions: [] };
  var canAdd = me.role === "owner" || (me.role === "staff" && (me.permissions || []).indexOf("manage_timetable") >= 0);
  var TUT = [{ id: "m1", name: "Tutor One" }, { id: "m2", name: "Tutor Two" }], made = {};
  var prev = window.__override;
  window.__override = function (c) {
    prev(c); var base = c.rpc.bind(c);
    function res(d, e) { return Promise.resolve({ data: d == null ? null : d, error: e ? { message: e } : null }); }
    c.rpc = function (nm, a) {
      if (nm.indexOf("staff_past_lessons") !== 0 && nm !== "staff_add_past_lessons") return base(nm, a);
      window.__calls.push([nm, a]);
      if (!canAdd && nm !== "staff_past_lessons_options") return res(null, "NOT_ALLOWED: your account can't change the timetable at this centre");
      if (nm === "staff_past_lessons_options") {
        return res({ today: TODAY, enabled: !cfg.off, allowed_days: 31, can_add: canAdd, is_owner: me.role === "owner", earliest: add(TODAY, -31), billing_start: null,
          student: { id: a.p_student, name: "Aiden Tan", level: "P5", created: TODAY, end_date: null },
          slots: cfg.slots ? [{ weekday: wdOf(add(TODAY, -2)), start: "16:00:00", end: "17:30:00", subject: "Math", rate: canAdd ? 60 : null, tutor_id: "m1" }] : [],
          tutors: TUT, default_tutor: "m1", last_rate: canAdd ? 60 : null, last_subject: null, fee_closed_before: null, remarks_required: !!cfg.remarksRequired });
      }
      if (nm === "staff_past_lessons_pattern") {
        var out = []; for (var d = a.p_from; d <= a.p_to && d < TODAY; d = add(d, 1)) if (wdOf(d) === wdOf(add(TODAY, -2))) out.push({ date: d, start: "16:00:00", end: "17:30:00", subject: "Math", rate: 60, tutor_id: "m1" });
        return res(out);
      }
      if (nm === "staff_past_lessons_preview" || nm === "staff_add_past_lessons") {
        var rows = a.p_items.map(function (it, i) {
          var mins = (+it.end.slice(0, 2) * 60 + +it.end.slice(3, 5)) - (+it.start.slice(0, 2) * 60 + +it.start.slice(3, 5)), amt = Math.round((it.rate ? +it.rate : 60) * mins / 60 * 100);
          var r = { idx: i + 1, date: it.date, start: it.start + ":00", end: it.end + ":00", minutes: mins, rate: it.rate || 60, amount: amt / 100, amount_cents: amt, state: "new", code: null, message: null, holiday: false, fee_month_closed: false };
          if (it.date >= TODAY) { r.state = "refused"; r.code = "NOT_PAST"; r.message = "Only days before today can be added here."; }
          else if (made[it.date]) { r.state = "there"; r.code = "THERE"; r.message = "Already on the timetable: nothing to add."; }
          else if (it.date === add(TODAY, -20)) { r.state = "refused"; r.code = "CLASH"; r.message = "This student already has a lesson then (16:00 to 17:30 with Tutor One)."; }
          else if (it.date === add(TODAY, -3)) { if (a.p_confirm_holidays) r.holiday = true; else { r.state = "refused"; r.code = "HOLIDAY"; r.message = "That day is a centre holiday (Test Day). Confirm to add it anyway."; } }
          return r;
        });
        var cnt = function (s) { return rows.filter(function (r) { return r.state === s; }).length; };
        if (nm === "staff_past_lessons_preview") return res({ today: TODAY, allowed_days: 31, rows: rows, "new": cnt("new"), there: cnt("there"), refused: cnt("refused"), total_cents: rows.filter(function (r) { return r.state === "new"; }).reduce(function (s, r) { return s + r.amount_cents; }, 0), fee_month_closed: false });
        if (!a.p_reason || !a.p_reason.trim()) return res(null, "REASON_REQUIRED: say why these lessons are being added now");
        if (cnt("refused")) return res(null, "REFUSED: " + cnt("refused") + " of these lessons can't be added, so none were. First problem: x");
        if (cfg.remarksRequired && a.p_mark_attended && !a.p_remarks) return res(null, "REMARKS_REQUIRED: this centre needs remarks before a lesson is marked attended");
        var n = 0; rows.forEach(function (r) { if (r.state === "new") { made[r.date] = 1; n++; } });
        return res({ created: n, skipped: cnt("there"), lesson_ids: [], attended: a.p_mark_attended && n > 0, fee_month_closed: false, invoiced_months: [] });
      }
      return base(nm, a);
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
  await page.addInitScript(baseOverride, cfg);
  await page.addInitScript(override, cfg);
  return { ctx, page, errs };
}
const calls = (page, nm) => page.evaluate((n) => window.__calls.filter((c) => c[0] === n), nm);
const lum = (rgb) => { const m = rgb.match(/\d+/g).map(Number); return (0.2126 * m[0] + 0.7152 * m[1] + 0.0722 * m[2]) / 255; };

(async () => {
  const browser = await chromium.launch();
  const TODAY = new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 10);
  const plus = (d, n) => { const x = new Date(d + "T00:00:00Z"); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };
  const OWNER = { members: [M(SOLO, "owner"), M(C, "owner")] };
  for (const mode of ["desktop", "phone", "dark"]) {
    const phone = mode === "phone", tag = mode + ": ";
    const { ctx, page, errs } = await open(browser, OWNER, { phone, dark: mode === "dark" });
    await page.goto(BASE + "centre-timetable.html?id=c1&mode=slots"); await page.waitForSelector("#sl-past");
    ok(await page.locator("#sl-past").isVisible(), tag + "the owner sees 'Add past lessons' on the Timetable");
    await page.click("#sl-past"); await page.waitForSelector("#pl-find");
    ok(/Student/.test(await page.locator("#pl-b").innerText()) && await page.locator("#pl-sheet.on").count() === 1, tag + "it opens a sheet that first asks which student");
    await page.waitForSelector("#pl-pick button"); await page.fill("#pl-find", "Aid"); await page.waitForFunction(() => document.querySelectorAll("#pl-pick button").length === 1);
    await page.click("#pl-pick button"); await page.waitForSelector("#pf");
    ok(/Aiden Tan/.test(await page.locator("#pl-m").innerText()), tag + "the sheet names the student and how far back it goes");
    ok(await page.locator("#pf-tutor").inputValue() === "m1", tag + "the tutor is filled in from the student's weekly lesson / last lesson");
    ok(await page.locator("#pf-go").isDisabled(), tag + "nothing yet: the Add button is off");
    // typed days
    await page.fill("#pf-day", plus(TODAY, -2)); await page.click("#pf-addday"); await page.fill("#pf-day", plus(TODAY, -1)); await page.click("#pf-addday");
    await page.waitForFunction(() => /2 new lessons/.test(document.querySelector("#pf-pre").textContent));
    ok(/S\$120\.00/.test(await page.locator("#pf-pre").innerText()), tag + "the preview counts them and adds up the money (2 x 1 hour at the latest price, S$60 = S$120.00)");
    ok(await page.locator(".pl-chip").count() === 2, tag + "the chosen days show as chips");
    ok(await page.locator("#pf-go").isDisabled(), tag + "still off: a reason is required");
    await page.fill("#pf-reason", "Started with us last week");
    await page.waitForFunction(() => !document.querySelector("#pf-go").disabled);
    ok((await page.locator("#pf-go").innerText()).trim() === "Add 2 lessons", tag + "the button says exactly how many lessons it adds");
    ok(await page.locator("#pf-att").isChecked(), tag + "'Mark them attended' is ticked (attended lessons are the ones invoiced)");
    if (phone) { const h = await page.locator("#pf-go").evaluate((e) => e.getBoundingClientRect().height); ok(h >= 44, tag + "the Add button is at least 44px tall"); }
    // a refused row stops the whole call
    await page.fill("#pf-day", plus(TODAY, -20)); await page.click("#pf-addday");
    await page.waitForFunction(() => /can’t be added/.test(document.querySelector("#pf-pre").textContent));
    ok(/already has a lesson then/.test(await page.locator("#pf-pre").innerText()) && await page.locator("#pf-go").isDisabled(), tag + "a clash is shown on its row, in plain words, and the button goes off (all or nothing)");
    if (SCR) await page.screenshot({ path: path.join(SCR, "past-refused-" + mode + ".png") });
    await page.click('[data-rm="' + plus(TODAY, -20) + '"]'); await page.waitForFunction(() => !document.querySelector("#pf-go").disabled);
    // the holiday needs a tick
    await page.fill("#pf-day", plus(TODAY, -3)); await page.click("#pf-addday");
    await page.waitForSelector("#pf-hol");
    ok(await page.locator("#pf-go").isDisabled() && /centre holiday/.test(await page.locator("#pf-pre").innerText()), tag + "a centre holiday asks for confirmation first");
    await page.check("#pf-hol"); await page.waitForFunction(() => !document.querySelector("#pf-go").disabled);
    ok((await page.locator("#pf-go").innerText()).trim() === "Add 3 lessons", tag + "after the tick, 3 lessons");
    if (SCR) await page.screenshot({ path: path.join(SCR, "past-form-" + mode + ".png") });
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + "no sideways scroll");
    if (mode === "dark") ok(lum(await page.locator(".pl-panel").evaluate((e) => getComputedStyle(e).backgroundColor)) < 0.3, tag + "the sheet is dark in dark mode");
    await page.click("#pf-go"); await page.waitForFunction(() => !document.querySelector("#pl-sheet.on"));
    const add = (await calls(page, "staff_add_past_lessons")).pop()[1];
    ok(add.p_items.length === 3 && add.p_mark_attended === true && add.p_reason === "Started with us last week" && add.p_tutor === "m1" && add.p_confirm_holidays === true && add.p_org === "c1",
       tag + "the call carries the tutor, the three days, attended, the reason and the holiday confirmation");
    ok(/3 lessons added and marked attended/.test(await page.locator("body").innerText()), tag + "the toast says what happened");
    ok(errs.length === 0, tag + "no console errors " + errs.join("|"));
    await ctx.close();
  }
  // weekly-pattern mode, remarks, a second call creates nothing twice
  { const { ctx, page, errs } = await open(browser, Object.assign({ slots: true, remarksRequired: true }, OWNER), { phone: true });
    await page.goto(BASE + "centre-timetable.html?id=c1&mode=slots"); await page.waitForSelector("#sl-past"); await page.click("#sl-past");
    await page.waitForSelector("#pl-pick button"); await page.click("#pl-pick button"); await page.waitForSelector("#pf");
    ok(await page.locator('[data-mode="pattern"].on').count() === 1, "pattern: a student with a weekly lesson starts on 'From the weekly lessons'");
    await page.waitForFunction(() => /new lesson/.test(document.querySelector("#pf-pre").textContent));
    ok(/new lessons?/.test(await page.locator("#pf-pre").innerText()), "pattern: the last 7 days of the weekly lesson are listed with a count");
    ok(/Required by this centre/.test(await page.locator("#pf-remarks-wrap").innerText()), "remarks: the form says the centre requires them");
    await page.fill("#pf-reason", "Timetable set up late");
    await page.click("#pf-go"); await page.waitForSelector("#pf-e:not([hidden])");
    ok(/needs remarks/.test(await page.locator("#pf-e").innerText()), "remarks: refused with the centre's own words, nothing is lost");
    await page.fill("#pf-remarks", "Algebra revision"); await page.click("#pf-go"); await page.waitForFunction(() => !document.querySelector("#pl-sheet.on"));
    ok((await calls(page, "staff_add_past_lessons")).pop()[1].p_remarks === "Algebra revision", "remarks: sent with the attended mark");
    await page.click("#sl-past"); await page.waitForSelector("#pl-pick button"); await page.click("#pl-pick button"); await page.waitForSelector("#pf");
    await page.waitForFunction(() => /already on the timetable/.test(document.querySelector("#pf-pre").textContent));
    ok(await page.locator("#pf-go").isDisabled(), "idempotent: the same days again say 'already on the timetable' and there is nothing to add");
    ok(errs.length === 0, "pattern: no console errors " + errs.join("|")); await ctx.close(); }
  // switched off / no permission
  { const { ctx, page } = await open(browser, Object.assign({ off: true }, OWNER), {});
    await page.goto(BASE + "centre-timetable.html?id=c1&mode=slots"); await page.waitForSelector("#sl-past"); await page.click("#sl-past"); await page.waitForSelector("#pl-pick button"); await page.click("#pl-pick button");
    await page.waitForFunction(() => /switched on adding past lessons/.test(document.querySelector("#pl-b").textContent));
    ok(await page.locator("#pf").count() === 0, "off (0 days): the sheet says the centre hasn't switched it on and shows no form"); await ctx.close(); }
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_students"])] }, {});
    await page.goto(BASE + "centre-timetable.html?id=c1&mode=slots"); await page.waitForTimeout(600);
    ok(await page.locator("#sl-past").isHidden(), "front desk (no manage_timetable): the button is not there"); await ctx.close(); }
  // from a student's sheet: the student is already chosen
  { const { ctx, page, errs } = await open(browser, OWNER, { phone: true });
    await page.goto(BASE + "centre-students.html?id=c1"); await page.waitForSelector(".cs-row"); await page.locator(".cs-row").first().click(); await page.waitForSelector("#tt-past");
    await page.click("#tt-past"); await page.waitForSelector("#pf");
    ok(await page.locator("#pl-find").count() === 0 && /Aiden Tan/.test(await page.locator("#pl-m").innerText()), "student sheet: it opens straight on the form for that student");
    await page.click("#pf-cancel"); await page.waitForFunction(() => !document.querySelector("#pl-sheet.on"));
    ok(await page.locator("#cs-sheet.on").count() === 1 && await page.evaluate(() => document.body.classList.contains("sheet-lock")), "student sheet: closing it leaves the student's sheet open and the page still locked behind it");
    ok(errs.length === 0, "student sheet: no console errors " + errs.join("|")); await ctx.close(); }
  await browser.close();
  console.log(fails ? fails + " FAILED" : "ALL PASSED"); process.exit(fails ? 1 : 0);
})();
