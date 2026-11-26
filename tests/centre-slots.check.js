// Browser check for the centre Weekly slots (T3 step 7). Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/centre-slots.check.js [screenshot-dir]
// The database functions are replaced by a small in-memory stand-in that follows the same rules (tests/sql/staff_slots_test.sql proves the real
// ones: permissions, idempotency, holidays on / off, tutor visibility). Here we check the SCREENS: add / change / stop a slot, the "Create lessons
// for the next 4 weeks" button and its plain message (pressed twice), the Assigned tutors panel, the tutor's link, permissions, phone, dark mode.
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
  function add(d, n) { var x = new Date(d + "T00:00:00Z"); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); }
  function wdOf(iso) { return (new Date(iso + "T00:00:00Z").getUTCDay() + 6) % 7; }
  var me = (cfg.members.filter(function (m) { return m.org_id === "c1"; })[0]) || { role: "tutor", permissions: [] };
  var canEdit = me.role === "owner" || (me.role === "staff" && (me.permissions || []).indexOf("manage_timetable") >= 0);
  var canLink = canEdit || (me.permissions || []).indexOf("manage_students") >= 0;
  var STU = [{ id: "s1", name: "Aiden Tan", level: "P5" }, { id: "s2", name: "Ravi Menon", level: "Sec 1" }, { id: "s3", name: "Sophie Lim", level: "Sec 2" }];
  var TUT = [{ id: "m1", name: "Tutor One" }, { id: "m2", name: "Tutor Two" }];
  var SL = [], LS = [], seq = 0, ASSIGNED = { s1: [] }, LINK = {}, hol = [];
  try { hol = JSON.parse(localStorage.getItem("__holidays") || "[]"); } catch (e) {}
  window.__calls = [];
  function tname(id) { var t = TUT.filter(function (x) { return x.id === id; })[0]; return t ? t.name : null; }
  window.__override = function (c) {
    var from = c.from.bind(c), rpc = c.rpc.bind(c);
    function res(d, e) { return Promise.resolve({ data: d == null ? null : d, error: e ? { message: e } : null }); }
    function gate(write) { if (cfg.missing) return "Could not find the function public.staff_slots"; if (write && !canEdit) return "NOT_ALLOWED: your account can't change the timetable at this centre"; return null; }
    c.rpc = function (nm, a) {
      window.__calls.push([nm, a]);
      if (nm === "staff_home") return res({ org_id: "c1", org_name: "Demo Learning Centre", status: "active", today: TODAY, can: { students: true, timetable: true, charges: false }, students_active: 3, today_lessons: 0, today_marked: 0, today_to_mark: 0, unmarked_past: 0, no_tutor_14d: 0, pending_charges: 0, trials_this_month: 0 });
      if (nm === "staff_slots") {
        var e = gate(false); if (e) return res(null, e);
        var groups = {}, order = [];
        SL.forEach(function (s) { if (!s.active) return; var k = s.key || s.id; if (!groups[k]) { groups[k] = []; order.push(k); } groups[k].push(s); });
        var q = (a.p_q || "").toLowerCase();
        var rows = order.map(function (k) { var g = groups[k], f = g[0]; return { key: k, slot_id: f.id, weekday: f.weekday, start_time: f.start + ":00", end_time: f.end + ":00", minutes: 60, subject: f.subject, rate: canEdit ? f.rate : null,
          tutor_id: f.tutor, tutor_name: tname(f.tutor), no_tutor: !f.tutor, is_group: g.length > 1, students: g.map(function (x) { return { id: x.student, name: STU.filter(function (s) { return s.id === x.student; })[0].name, level: "P5", ended: false, slot_id: x.id }; }) }; })
          .filter(function (r) { return (!a.p_tutor || r.tutor_id === a.p_tutor) && (!q || (r.subject || "").toLowerCase().indexOf(q) >= 0 || r.students.some(function (s) { return s.name.toLowerCase().indexOf(q) >= 0; })); })
          .sort(function (x, y) { return x.weekday - y.weekday || x.start_time.localeCompare(y.start_time); });
        var gen = LS.length ? LS.map(function (l) { return l.d; }).sort().pop() : null;
        return res({ today: TODAY, can_edit: canEdit, page: a.p_page, size: a.p_size, total: rows.length, generated_until: gen, tutors: TUT, rows: rows.slice((a.p_page - 1) * a.p_size, a.p_page * a.p_size) });
      }
      if (nm === "staff_pick_students") { var e2 = gate(true); if (e2) return res(null, e2); var qq = (a.p_q || "").toLowerCase(); return res(STU.filter(function (s) { return !qq || s.name.toLowerCase().indexOf(qq) >= 0; })); }
      if (nm === "staff_save_slot") {
        var e3 = gate(true); if (e3) return res(null, e3);
        if (cfg.clash && a.p_slot == null) return res(null, "SLOT_CLASH: Aiden Tan already has a weekly lesson at that time");
        if (a.p_slot == null) {
          var key = a.p_students.length > 1 ? "k" + (++seq) : null, ids = [];
          a.p_students.forEach(function (sid) { var s = { id: "sl" + (++seq), key: key, student: sid, weekday: a.p_weekday, start: a.p_start, end: a.p_end, tutor: a.p_tutor, subject: a.p_subject, rate: a.p_rate, active: true }; SL.push(s); ids.push(s.id); });
          return res({ slot_ids: ids, added: ids.length, lessons_left: 0 });
        }
        var f = SL.filter(function (s) { return s.id === a.p_slot; })[0]; if (!f) return res(null, "NOT_FOUND");
        SL.filter(function (s) { return s.id === f.id || (f.key && s.key === f.key); }).forEach(function (s) { s.weekday = a.p_weekday; s.start = a.p_start; s.end = a.p_end; s.tutor = a.p_tutor; s.subject = a.p_subject; if (a.p_rate != null) s.rate = a.p_rate; });
        return res({ slot_ids: [f.id], added: 0, lessons_left: LS.length });
      }
      if (nm === "staff_stop_slot") {
        var e4 = gate(true); if (e4) return res(null, e4);
        var f2 = SL.filter(function (s) { return s.id === a.p_slot; })[0]; if (!f2) return res(null, "NOT_FOUND");
        var n = 0; SL.forEach(function (s) { if (s.active && (s.id === f2.id || (f2.key && s.key === f2.key))) { s.active = false; n++; } });
        return res({ stopped: n, lessons_left: 0 });
      }
      if (nm === "staff_generate_lessons") {
        var e5 = gate(true); if (e5) return res(null, e5);
        var created = 0, skipped = 0, hdays = {}, no_tutor = 0;
        try { hol = JSON.parse(localStorage.getItem("__holidays") || "[]"); } catch (e) {}
        for (var i = 0; i < 28; i++) {
          var d = add(TODAY, i);
          SL.forEach(function (s) {
            if (!s.active || wdOf(d) !== s.weekday) return;
            if (LS.some(function (l) { return l.slot === s.id && l.d === d; })) { skipped++; return; }
            if (hol.some(function (h) { return h.starts_on <= d && h.ends_on >= d; })) { hdays[d] = 1; return; }
            LS.push({ slot: s.id, d: d, student: s.student, tutor: s.tutor, start: s.start, end: s.end, subject: s.subject }); created++; if (!s.tutor) no_tutor++;
          });
        }
        return res({ from: TODAY, to: add(TODAY, 27), created: created, skipped: skipped, holidays: Object.keys(hdays).length, ended: 0, no_tutor: no_tutor, on_holiday: 0, slots: SL.filter(function (s) { return s.active; }).length });
      }
      if (nm === "staff_timetable") {
        var m = LS.filter(function (l) { return l.d >= a.p_from && l.d <= a.p_to; });
        return res({ today: TODAY, page: 1, size: a.p_size, total: m.length, holidays: [], counts: { n_all: m.length, n_notutor: m.filter(function (l) { return !l.tutor; }).length, n_cancelled: 0, n_holiday: 0 },
          tutors: TUT, branches: [], students: STU.map(function (s) { return { id: s.id, name: s.name }; }), students_more: false,
          rows: m.sort(function (x, y) { return x.d.localeCompare(y.d); }).map(function (l, i) { var s = STU.filter(function (x) { return x.id === l.student; })[0]; return { lesson_id: "L" + i, lesson_date: l.d, start_time: l.start + ":00", end_time: l.end + ":00", minutes: 60,
            student_id: s.id, student_name: s.name, student_level: s.level, subject: l.subject, tutor_id: l.tutor, tutor_name: tname(l.tutor), no_tutor: !l.tutor, trial: false, attendance: null, state: "future", cancelled: false, postponed: false, holiday: null, session_id: null, online_link: LINK[l.student] || null }; }) });
      }
      // ---- the Students page: a tiny list + sheet, and the new panel
      if (nm === "staff_students") return res({ org_id: "c1", today: TODAY, filter: "active", page: 1, size: 25, total: 1, counts: { active: 1, ended: 0, trial: 0, all: 1 },
        rows: [{ id: "s1", name: "Aiden Tan", level: "P5", end_date: null, ended: false, trial: false, household_id: "h1", household_name: "Tan family", guardian_name: "Mrs Tan", guardian_phone: "+65 8000 0001", guardian_count: 1, tutors: [] }] });
      if (nm === "staff_student") return res({ id: "s1", org_id: "c1", name: "Aiden Tan", level: "P5", notes: null, end_date: null, ended: false, created_at: TODAY, today: TODAY, household: { id: "h1", name: "Tan family" },
        guardians: [{ id: "g1", name: "Mrs Tan", relation: "Mother", phone: "+65 8000 0001", email: null }], siblings: [], subjects: ["Math"], lessons_total: 0, lessons_trial: 0, trial: false, next_lessons: [] });
      if (nm === "staff_student_tutors") {
        if (cfg.missing) return res(null, "Could not find the function public.staff_student_tutors");
        return res({ student_id: "s1", student_name: "Aiden Tan", can_edit: canEdit, can_link: canLink, online_link: LINK.s1 || null,
          assigned: (ASSIGNED.s1 || []).map(function (id) { return { id: id, name: tname(id), since: TODAY }; }), history: [], options: TUT });
      }
      if (nm === "staff_set_student_tutors") { var e6 = gate(true); if (e6) return res(null, e6); ASSIGNED.s1 = a.p_tutors.slice(); return res({ added: a.p_tutors.length, removed: 0, assigned: a.p_tutors.length }); }
      if (nm === "staff_set_student_link") { if (!canLink) return res(null, "NOT_ALLOWED: nope"); LINK.s1 = a.p_link || null; return res({ online_link: LINK.s1 }); }
      // ---- the tutor page
      if (nm === "tutor_my_lessons") return res(cfg.tutorRows || []);
      if (nm === "tutor_lesson_links") return res(cfg.tutorLinks || []);
      return rpc(nm, a);
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
const AXE_PATH = path.join(ROOT, "tests/node_modules/axe-core/axe.min.js"), AXE = fs.existsSync(AXE_PATH) ? fs.readFileSync(AXE_PATH, "utf8") : null;
async function axe(page, tag) {                                   // serious / critical accessibility problems on what is on screen now (same rule set as tests/smoke.py)
  if (!AXE) { console.log("SKIP " + tag + "axe (cd tests && npm install)"); return; }
  await page.evaluate(AXE);
  const v = await page.evaluate(() => axe.run(document, { runOnly: ["wcag2a", "wcag2aa", "best-practice"] }).then((r) => r.violations.filter((x) => x.impact === "serious" || x.impact === "critical").map((x) => x.id + " x" + x.nodes.length + " " + JSON.stringify(x.nodes[0].target))));
  ok(v.length === 0, tag + "axe: no serious or critical accessibility problems " + v.join(" | "));
}
const calls = (page, nm) => page.evaluate((n) => window.__calls.filter((c) => c[0] === n).length, nm);

(async () => {
  const browser = await chromium.launch();
  const TODAY = new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 10);
  const plus = (d, n) => { const x = new Date(d + "T00:00:00Z"); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };
  const wdOf = (iso) => (new Date(iso + "T00:00:00Z").getUTCDay() + 6) % 7;
  for (const mode of ["desktop", "phone", "dark"]) {
    const phone = mode === "phone", tag = mode + ": ";
    const { ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_timetable"])] }, { phone, dark: mode === "dark" });
    await page.goto(BASE + "centre-timetable.html?id=c1&mode=slots"); await page.waitForSelector("#sl-list .tt-empty, #sl-list .sl-row");
    ok(await page.locator("#sl").isVisible() && await page.locator("#tt").isHidden(), tag + "the address ?mode=slots opens the Weekly slots view");
    ok(/No weekly slots yet/.test(await page.locator("#sl-list").innerText()), tag + "an empty centre says so and says what to do");
    ok(await page.locator("#sl-add").isVisible() && await page.locator("#sl-gen").isVisible(), tag + "someone with manage_timetable sees Add weekly slot and Create lessons");
    ok((await page.locator("#sl-gen").innerText()).trim() === "Create lessons for the next 4 weeks", tag + "the button says exactly 'Create lessons for the next 4 weeks'");
    // nothing typed: the form says what is missing and makes NO call
    await page.click("#sl-add"); await page.waitForSelector("#sl-sheet.on"); await page.waitForSelector("#sf-pick button");
    await page.selectOption("#sf-day", ""); await page.fill("#sf-rate", ""); await page.click("#sf-save");
    ok(/Pick at least one student/.test(await page.locator("#sf-e-students").innerText()) && /Pick a day/.test(await page.locator("#sf-e-weekday").innerText()) && /Type the rate/.test(await page.locator("#sf-e-rate").innerText()), tag + "an empty form says what is missing");
    ok(await calls(page, "staff_save_slot") === 0, tag + "and does not call the database");
    // a real one: Aiden, on the weekday two days from now, with Tutor Two
    const wd = wdOf(plus(TODAY, 2));
    await page.fill("#sf-find", "aid"); await page.waitForFunction(() => document.querySelectorAll("#sf-pick button").length === 1);
    await page.click("#sf-pick button"); ok(/Aiden Tan/.test(await page.locator("#sf-chosen").innerText()), tag + "picking a student adds a chip");
    await page.selectOption("#sf-day", String(wd)); await page.fill("#sf-start", "16:00"); await page.fill("#sf-end", "17:30");
    await page.selectOption("#sf-tutor", "m2"); await page.fill("#sf-subject", "Math"); await page.fill("#sf-rate", "60");
    if (SC && mode !== "dark") await page.screenshot({ path: path.join(SC, "slots-form-" + mode + ".png") });
    await axe(page, tag + "add form: ");
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + "the form has no sideways scroll");
    await page.click("#sf-save"); await page.waitForFunction(() => !document.querySelector("#sl-sheet.on"));
    await page.waitForSelector(".sl-row");
    const row = await page.locator(".sl-row").first().innerText();
    ok(/Aiden Tan/.test(row) && /Tutor Two/.test(row) && /Math/.test(row) && /S\$60\/hr/.test(row) && /4:00 pm/.test(row), tag + "the new slot is listed with student, tutor, subject, rate and time: " + row.replace(/\n/g, " | "));
    ok(/1 weekly slot · no lessons made yet/.test(await page.locator("#sl-count").innerText()), tag + "the count says no lessons have been made yet");
    // a holiday on the second occurrence, then press Create lessons
    await page.evaluate((h) => localStorage.setItem("__holidays", JSON.stringify([h])), { id: "h1", name: "Deepavali", starts_on: plus(TODAY, 2 + 7), ends_on: plus(TODAY, 2 + 7) });
    await page.click("#sl-add"); await page.fill("#sf-find", "x"); await page.click("#sf-cancel");
    ok(!(await page.locator("#sl-sheet.on").count()), tag + "Cancel closes the sheet");
    await page.click("#sl-gen"); await page.waitForSelector("#sl-result:not([hidden]) b");
    ok((await page.locator("#sl-result b").innerText()) === "3 created, 0 skipped, 1 holiday", tag + "pressing Create lessons answers '3 created, 0 skipped, 1 holiday' (" + (await page.locator("#sl-result b").innerText()) + ")");
    ok(/up to/.test(await page.locator("#sl-count").innerText()), tag + "the count now says how far lessons are made");
    await axe(page, tag + "slots list with the result: ");
    await page.click("#sl-gen"); await page.waitForFunction(() => /^0 created/.test(document.querySelector("#sl-result b").textContent));
    ok(/^0 created, 3 skipped, 1 holiday/.test(await page.locator("#sl-result").innerText()) && /Nothing new/.test(await page.locator("#sl-result").innerText()), tag + "pressing it AGAIN creates nothing new and says so");
    ok(await calls(page, "staff_generate_lessons") === 2, tag + "two presses = two calls");
    // see the lessons
    await page.click("#sl-see"); await page.waitForSelector("#tt-list .tt-row");
    ok(await page.locator("#tt").isVisible() && await page.locator("#sl").isHidden(), tag + "'See the lessons' goes to the lessons view");
    ok(await page.locator("#tt-list .tt-row").count() === 1, tag + "the 14-day list shows the 1 lesson in range (the holiday one is skipped, the next is 16 days away)");
    ok(/Tutor Two/.test(await page.locator("#tt-list .tt-row").first().innerText()), tag + "and it has its tutor");
    // back to slots: edit
    await page.click('#tt-mode [data-m="slots"]'); await page.waitForSelector(".sl-row");
    await page.locator(".sl-row").first().click(); await page.waitForSelector("#sl-sheet.on #sf-day");
    ok(/Change weekly slot/.test(await page.locator("#sl-st").innerText()) && await page.locator("#sf-find").count() === 0, tag + "a slot opens in Change mode with the students read only");
    ok(await page.locator("#sf-tutor").inputValue() === "m2" && await page.locator("#sf-rate").inputValue() === "60", tag + "the form shows the current tutor and rate");
    await page.waitForTimeout(450); await axe(page, tag + "change form: ");
    await page.selectOption("#sf-tutor", ""); await page.fill("#sf-rate", ""); await page.click("#sf-save");
    await page.waitForFunction(() => !document.querySelector("#sl-sheet.on")); await page.waitForSelector(".sl-row.notutor");
    ok(/No tutor yet/.test(await page.locator(".sl-row").first().innerText()) && /S\$60\/hr/.test(await page.locator(".sl-row").first().innerText()), tag + "taking the tutor away flags it amber and an empty rate keeps the old rate");
    await page.waitForTimeout(700); if (SC) await page.screenshot({ path: path.join(SC, "slots-" + mode + ".png"), fullPage: true });
    // stop it
    await page.locator(".sl-row").first().click(); await page.waitForSelector("#sf-stop"); await page.click("#sf-stop");
    await page.waitForSelector(".td-confirm, [role=alertdialog], .modal.on, .cf-on, button:has-text('Stop slot')"); await page.locator("button", { hasText: "Stop slot" }).last().click();
    await page.waitForFunction(() => /No weekly slots yet/.test(document.querySelector("#sl-list").textContent));
    ok(true, tag + "stopping a slot (after a confirm) removes it from the list");
    ok(errs.length === 0, tag + "no console errors " + errs.join("|"));
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + "no sideways scroll");
    await ctx.close();
  }
  // a clash is shown in plain words, inside the form
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], clash: true });
    await page.goto(BASE + "centre-timetable.html?id=c1&mode=slots"); await page.waitForSelector("#sl-add"); await page.click("#sl-add"); await page.waitForSelector("#sf-pick button");
    await page.click("#sf-pick button"); await page.selectOption("#sf-day", "1"); await page.fill("#sf-rate", "50"); await page.click("#sf-save");
    await page.waitForSelector("#sf-e:not([hidden])");
    ok(/Aiden Tan already has a weekly lesson at that time\./.test(await page.locator("#sf-e").innerText()) && await page.locator("#sl-sheet.on").count() === 1, "a clash is explained in the form and the sheet stays open"); await ctx.close(); }
  // a group class: two students make ONE row
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")] });
    await page.goto(BASE + "centre-timetable.html?id=c1&mode=slots"); await page.waitForSelector("#sl-add"); await page.click("#sl-add"); await page.waitForSelector("#sf-pick button");
    await page.locator("#sf-pick button").nth(0).click(); await page.locator("#sf-pick button").nth(1).click();
    ok(await page.locator("#sf-chosen .sl-chip").count() === 2, "two students can be picked for one class");
    await page.selectOption("#sf-day", "2"); await page.fill("#sf-rate", "40"); await page.click("#sf-save"); await page.waitForSelector(".sl-row");
    ok(await page.locator(".sl-row").count() === 1 && /Class of 2/.test(await page.locator(".sl-row").first().innerText()), "a class of two is ONE row, marked 'Class of 2'"); await ctx.close(); }
  // front desk (manage_students only): can look, cannot edit, sees no rate
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_students"])] });
    await page.goto(BASE + "centre-timetable.html?id=c1&mode=slots"); await page.waitForSelector("#sl-list .tt-empty, #sl-list .sl-row");
    ok(await page.locator("#sl-bar").isHidden() && await page.locator("#sl-add").isHidden(), "front desk: no Add and no Create lessons buttons");
    ok(await page.locator(".sl-row").count() === 0, "front desk: the list loads (empty here)"); await ctx.close(); }
  // migration missing
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], missing: true });
    await page.goto(BASE + "centre-timetable.html?id=c1&mode=slots"); await page.waitForSelector("#sl-list .tt-block");
    ok(/migration_staff_slots/.test(await page.locator("#sl-list").innerText()), "migration missing: a plain message names the file"); await ctx.close(); }
  // the Students sheet: assigned tutors and the link
  for (const mode of ["desktop", "phone"]) {
    const { ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_timetable", "manage_students"])] }, { phone: mode === "phone" });
    const tag = mode + ": ";
    await page.goto(BASE + "centre-students.html?id=c1"); await page.waitForSelector(".cs-row"); await page.locator(".cs-row").first().click(); await page.waitForSelector("#cs-tut .cs-h");
    ok(/No tutor assigned yet/.test(await page.locator("#cs-tut").innerText()) && /Not set/.test(await page.locator("#cs-tut").innerText()), tag + "the student sheet has Assigned tutors (none) and Online lesson link (not set)");
    await page.click("#tt-edit"); await page.waitForSelector("#cs-tut [data-tid]");
    await page.locator('#cs-tut [data-tid]').nth(1).check(); await page.click("#tt-save"); await page.waitForSelector("#cs-tut .chip");
    ok(/Tutor Two/.test(await page.locator("#cs-tut .chips").innerText()), tag + "assigning a tutor shows them as a chip");
    await page.click("#tl-edit"); await page.fill("#tt-link", "http://nope"); await page.click("#tl-save");
    ok(/must start with https/.test(await page.locator("#cs-tut .err").innerText()), tag + "a link that is not https:// is refused in plain words, before any call");
    await page.fill("#tt-link", "https://meet.example.com/abc"); await page.click("#tl-save"); await page.waitForSelector("#cs-tut a.lk");
    ok(await page.locator("#cs-tut a.lk").getAttribute("href") === "https://meet.example.com/abc" && /noopener/.test(await page.locator("#cs-tut a.lk").getAttribute("rel")), tag + "the saved link shows, opens in a new tab with noopener");
    if (SC) await page.screenshot({ path: path.join(SC, "student-sheet-" + mode + ".png") });
    await axe(page, tag + "student sheet panel: ");
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + "no sideways scroll");
    ok(errs.length === 0, tag + "no console errors " + errs.join("|")); await ctx.close();
  }
  { // timetable-only staff see tutors but a manage_students-only person cannot change them
    const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_students"])] });
    await page.goto(BASE + "centre-students.html?id=c1"); await page.waitForSelector(".cs-row"); await page.locator(".cs-row").first().click(); await page.waitForSelector("#cs-tut .cs-h");
    ok(await page.locator("#tt-edit").count() === 0 && /Only people who manage the timetable/.test(await page.locator("#cs-tut").innerText()), "front desk: sees the panel but can't change tutors");
    ok(await page.locator("#tl-edit").count() === 1, "front desk: may still set the online link (manage_students)"); await ctx.close(); }
  { // the database without the migration: the student sheet simply has no panel
    const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], missing: true });
    await page.goto(BASE + "centre-students.html?id=c1"); await page.waitForSelector(".cs-row"); await page.locator(".cs-row").first().click(); await page.waitForSelector("#cs-sb .cs-h");
    await page.waitForTimeout(400); ok((await page.locator("#cs-tut").innerText()).trim() === "", "no migration: no panel and no error"); await ctx.close(); }
  // the tutor sees the link on My lessons
  { const lesson = { lesson_id: "L1", org_id: "c1", org_name: "Demo Learning Centre", student_id: "s1", student_name: "Aiden Tan", student_level: "P5", parent_contact: null, lesson_date: TODAY, start_time: "16:00:00", end_time: "17:00:00",
      subject: "Math", status: "scheduled", attendance: null, trial: false, session_id: null, topics: null, homework: null, remarks: null, remarks_due_at: plus(TODAY, 2) + "T10:00:00Z", can_mark: true, can_note: true, can_cancel: false,
      remarks_required: false, can_flag_trial: false, tutor_sets_compensation: false, charge_pending: false };
    const { ctx, page, errs } = await open(browser, { members: [M(C, "tutor")], tutorRows: [lesson], tutorLinks: [{ lesson_id: "L1", online_link: "https://meet.example.com/abc" }] }, { phone: true });
    await page.goto(BASE + "tutor.html"); await page.waitForSelector(".tt-row, [data-id]"); await page.locator(".tt-row, [data-id]").first().click(); await page.waitForSelector("#ts-title");
    ok(/Join the lesson/.test(await page.locator("#ts-body, .tt-facts").first().innerText()) && await page.locator('a[href="https://meet.example.com/abc"]').count() === 1, "the tutor sees 'Join the lesson' on a lesson with a link");
    ok(!/S\$|\$\d|rate|price/i.test(await page.locator(".tt-facts").first().innerText()), "and no money");
    ok(errs.length === 0, "tutor page: no console errors " + errs.join("|")); await ctx.close(); }
  await browser.close();
  console.log(fails ? fails + " FAILED" : "ALL PASSED"); process.exit(fails ? 1 : 0);
})();
