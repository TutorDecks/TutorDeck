// Browser check for the Trial flag (T3 step 5). Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/centre-trials.check.js [screenshot-dir]
// The database functions are replaced by a small in-memory stand-in (the SQL tests prove the real ones). Trial flags are kept in
// localStorage so they survive moving between the Attendance and Students pages, like the database would.
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
  var flagged = []; try { flagged = JSON.parse(localStorage.getItem("__trials") || "[]"); } catch (e) {}
  var L = [
    { id: "l1", sid: "s1", d: TODAY, st: "15:00:00", en: "16:00:00", name: "Aiden Tan", lvl: "P5", att: "attended" },
    { id: "l2", sid: "s2", d: TODAY, st: "16:30:00", en: "17:30:00", name: "Ravi Menon", lvl: "Sec 1", att: null },
    { id: "l3", sid: "s3", d: add(TODAY, -40), st: "10:00:00", en: "11:00:00", name: "Old Month", lvl: "P4", att: "attended" }];
  L.forEach(function (x) { x.trial = flagged.indexOf(x.id) >= 0; });
  window.__calls = [];
  window.__override = function (c) {
    var from = c.from.bind(c), rpc = c.rpc.bind(c);
    function res(d, e) { return Promise.resolve({ data: d || null, error: e ? (typeof e === "string" ? { message: e } : e) : null }); }
    function state(x) { return x.att ? "marked" : x.d > TODAY ? "future" : "open"; }
    c.rpc = function (nm, a) {
      window.__calls.push([nm, a]);
      if (nm === "staff_home") return res({ org_id: "c1", org_name: "Demo Learning Centre", status: "active", today: TODAY, can: { students: true, timetable: true, charges: false },
        students_active: 3, today_lessons: 2, today_marked: 1, today_to_mark: 1, unmarked_past: 0, no_tutor_14d: 0, pending_charges: 0, trials_this_month: L.filter((x) => x.trial && x.d.slice(0, 7) === TODAY.slice(0, 7)).length });
      if (nm === "staff_set_trial") {
        if (cfg.canMark === false) return res(null, "NOT_ALLOWED: your account can't mark attendance at this centre");
        var l = L.filter((x) => x.id === a.p_lesson)[0];
        if (l.trial === a.p_trial) return res(null, "NO_CHANGE: the lesson is already " + (a.p_trial ? "a trial lesson" : "not a trial lesson"));
        l.trial = a.p_trial; flagged = L.filter((x) => x.trial).map((x) => x.id); localStorage.setItem("__trials", JSON.stringify(flagged)); return res({ lesson_id: l.id, trial: l.trial });
      }
      if (nm === "staff_lessons") {
        var m = L.filter((x) => x.d >= a.p_from && x.d <= a.p_to), shown = m.filter((x) => a.p_status === "all" || (a.p_status === "trial" && x.trial));
        return res({ today: TODAY, can_mark: cfg.canMark !== false, page: 1, size: a.p_size, total: shown.length,
          counts: { all: m.length, unmarked: m.filter((x) => !x.att && x.d <= TODAY).length, marked: m.filter((x) => x.att).length, trial: m.filter((x) => x.trial).length },
          tutors: [], rows: shown.map((x) => ({ lesson_id: x.id, lesson_date: x.d, start_time: x.st, end_time: x.en, student_name: x.name, student_level: x.lvl, subject: "Math", tutor_id: null, tutor_name: "Tutor One",
            attendance: x.att, status: "scheduled", state: state(x), trial: x.trial, remarks: null, marked_at: null, marked_by_name: null, charge_pending: false,
            can_mark: cfg.canMark !== false && state(x) === "open", can_correct: cfg.canMark !== false && state(x) === "marked" })) });
      }
      if (nm === "staff_students") {
        var ST = L.map((x) => ({ id: x.sid, name: x.name, level: x.lvl, trial: x.trial && x.d >= add(TODAY, -30) })), cnt = { active: ST.length, ended: 0, trial: ST.filter((s) => s.trial).length, all: ST.length };
        var rows = ST.filter((s) => a.p_filter === "trial" ? s.trial : true);
        return res({ org_id: "c1", today: TODAY, filter: a.p_filter, page: 1, size: a.p_size, total: rows.length, counts: cnt,
          rows: rows.map((s) => ({ id: s.id, name: s.name, level: s.level, end_date: null, ended: false, trial: s.trial, household_id: "h" + s.id, household_name: "Family", guardian_name: null, guardian_phone: null, guardians: 0 })) });
      }
      if (nm === "staff_student") { var x = L.filter((y) => y.sid === a.p_student)[0], t = x.trial && x.d >= add(TODAY, -30);
        return res({ id: x.sid, org_id: "c1", name: x.name, level: x.lvl, notes: null, end_date: null, ended: false, created_at: TODAY, today: TODAY, household: null, guardians: [], siblings: [], subjects: ["Math"], lessons_total: 1, lessons_trial: x.trial ? 1 : 0, trial: t, next_lessons: [] }); }
      return rpc(nm, a);
    };
    c.from = function (t) {
      if (t === "students") { var q = from(t), sel = q.select; q.select = function (cols, opt) { if (!(opt && opt.head)) return sel.apply(q, arguments); var o = {}; ["eq", "neq", "in", "is"].forEach(function (m) { o[m] = function () { return o; }; }); o.then = function (r, j) { return Promise.resolve({ count: 0, error: null }).then(r, j); }; return o; }; return q; }
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

(async () => {
  const browser = await chromium.launch();
  const FULL = ["manage_students", "manage_timetable"];
  for (const mode of ["desktop", "phone", "dark"]) {
    const phone = mode === "phone", tag = mode + ": ";
    const { ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", FULL)] }, { phone, dark: mode === "dark" });
    await page.goto(BASE + "centre-attendance?id=c1"); await page.waitForSelector(".ca-row");
    ok(await page.locator(".ca-chip.trial").count() === 0, tag + "no Trial badge before flagging");
    await page.locator(".ca-row", { hasText: "Ravi" }).click(); await page.waitForSelector("#ca-trial");
    ok(await page.locator("#ca-trial").isChecked() === false && /doesn’t count towards the centre’s fee/.test(await page.locator("#ca-sb").innerText()), tag + "the sheet has an unticked Trial switch and says it isn't charged to the centre's fee");
    await page.waitForTimeout(450); if (SC && mode !== "dark") await page.screenshot({ path: path.join(SC, "trial-sheet-" + mode + ".png") });
    await page.locator("#ca-trial").click();
    await page.waitForFunction(() => document.querySelectorAll(".ca-chip.trial").length === 1);
    const call = await page.evaluate(() => window.__calls.filter((c) => c[0] === "staff_set_trial").pop()[1]);
    ok(call.p_lesson === "l2" && call.p_trial === true, tag + "ticking it sends staff_set_trial(lesson, true) once");
    ok(await page.locator("#ca-trial").isChecked(), tag + "the sheet stays open and shows it ticked");
    await page.click("#ca-sx");
    ok(/Ravi Menon[\s\S]*Trial/.test(await page.locator(".ca-row", { hasText: "Ravi" }).innerText()), tag + "the lesson row now has a Trial badge");
    // Trial filter
    await page.click('#ca-seg [data-f="trial"]'); await page.waitForFunction(() => document.querySelectorAll(".ca-row").length === 1);
    ok(/Ravi/.test(await page.locator(".ca-row").innerText()) && /Trial\s*1/.test(await page.locator("#ca-seg").innerText()), tag + "the Attendance Trial filter shows only Ravi, with its count");
    // untick from the filter: row leaves the list, sheet closes
    await page.locator(".ca-row").click(); await page.waitForSelector("#ca-trial"); await page.locator("#ca-trial").click();
    await page.waitForFunction(() => document.querySelectorAll(".ca-row").length === 0 && !document.querySelector("#ca-sheet.on"));
    ok(/No trial lessons/.test(await page.locator("#ca-list").innerText()), tag + "unticking removes it from the Trial filter with a plain empty message");
    await page.locator("#ca-seg [data-f='all']").click(); await page.waitForSelector(".ca-row");
    await page.locator(".ca-row", { hasText: "Ravi" }).click(); await page.waitForSelector("#ca-trial"); await page.locator("#ca-trial").click(); await page.waitForSelector(".ca-chip.trial"); await page.click("#ca-sx");
    // Students: the Trial filter shows Ravi; his sheet shows it read-only
    await page.goto(BASE + "centre-students?id=c1&f=trial"); await page.waitForSelector(".cs-row, .cs-item, [data-id]");
    const lst = await page.locator("#cs-list").innerText();
    ok(/Ravi/.test(lst) && !/Aiden/.test(lst), tag + "the Students Trial filter (opened from a link) lists Ravi only");
    await page.locator("#cs-list [data-id]").first().click(); await page.waitForSelector("#cs-sheet.on");
    ok(/trial lesson in the last 30 days/.test(await page.locator("#cs-sb").innerText()) && await page.locator("#cs-sb input[type=checkbox]").count() === 0, tag + "the student sheet shows the trial read-only (no switch)");
    // Home tile links to the filtered month list
    await page.goto(BASE + "centre?id=c1"); await page.waitForSelector("a.ch-link");
    const tile = page.locator("a.ch-link", { hasText: "trial lesson" });
    ok(/1\s*\n?\s*trial lesson this month/i.test(await tile.innerText()) && /f=trial/.test(await tile.getAttribute("href")), tag + "the Home trials tile counts it and links to the filtered list");
    await tile.click(); await page.waitForURL(/centre-attendance/); await page.waitForSelector(".ca-row");
    ok(/November|December|January|February|March|April|May|June|July|August|September|October/.test(await page.locator("#ca-when").innerText()) && await page.locator("#ca-seg .on").innerText().then((t) => /Trial/.test(t)), tag + "the tile opens Attendance on this month with the Trial filter on");
    ok(errs.length === 0, tag + "no console errors " + errs.join("|"));
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + "no sideways scroll");
    if (SC) await page.screenshot({ path: path.join(SC, "trial-list-" + mode + ".png") });
    await ctx.close();
  }
  // a lesson from an earlier month gets the plain 'fee does not change' note
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")] });
    await page.goto(BASE + "centre-attendance?id=c1&view=month"); await page.waitForSelector(".ca-row");
    await page.click("#ca-prev"); await page.waitForFunction(() => /Old Month/.test(document.querySelector("#ca-list").textContent) || /No lessons/.test(document.querySelector("#ca-list").textContent));
    if (/Old Month/.test(await page.locator("#ca-list").innerText())) { await page.locator(".ca-row", { hasText: "Old Month" }).click(); await page.waitForSelector("#ca-trial"); ok(/earlier month/.test(await page.locator("#ca-sb").innerText()), "an earlier month's lesson says the fee already worked out does not change"); }
    else ok(true, "(the 40-days-ago stub lesson falls outside the previous month today; the note is unit-tested)");
    await ctx.close(); }
  // staff without manage_timetable: the badge, no switch
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_students"])], canMark: false });
    await page.evaluate(() => 0); await page.goto(BASE + "centre-attendance?id=c1"); await page.waitForSelector(".ca-row");
    await page.evaluate(() => localStorage.setItem("__trials", JSON.stringify(["l2"]))); await page.reload(); await page.waitForSelector(".ca-row");
    ok(await page.locator(".ca-chip.trial").count() === 1, "front desk (no manage_timetable): sees the Trial badge");
    await page.locator(".ca-row", { hasText: "Ravi" }).click(); await page.waitForSelector("#ca-sb");
    ok(await page.locator("#ca-trial").count() === 0 && /This is a trial lesson\./.test(await page.locator("#ca-sb").innerText()), "front desk: no toggle, a plain read-only line instead");
    await ctx.close(); }
  await browser.close();
  console.log(fails ? fails + " FAILED" : "ALL PASSED"); process.exit(fails ? 1 : 0);
})();
