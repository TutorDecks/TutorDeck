// Browser check for the centre Attendance screen (T3 step 3). Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/centre-attendance.check.js [screenshot-dir]
// The three database functions are replaced by a small in-memory stand-in that follows the same rules (the SQL tests prove the real ones).
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
  var L = [
    { id: "l1", d: TODAY, st: "15:00:00", en: "16:00:00", name: "Aiden Tan", lvl: "P5", tut: "Tutor One", tid: "m1", att: "absent", by: "Tutor One" },
    { id: "l2", d: TODAY, st: "16:30:00", en: "17:30:00", name: "Mei Ling Koh", lvl: "P6", tut: "Tutor Two", tid: "m2", att: null },
    { id: "l3", d: add(TODAY, 1), st: "15:00:00", en: "16:00:00", name: "Ravi Menon", lvl: "Sec 1", tut: "Tutor One", tid: "m1", att: null },
    { id: "l4", d: add(TODAY, -2), st: "10:00:00", en: "11:00:00", name: "Sophie Lim", lvl: "P4", tut: null, tid: null, att: null }];
  window.__calls = []; window.__audit = [];
  function state(l) { return l.att ? "marked" : l.d > TODAY ? "future" : "open"; }
  window.__override = function (c) {
    var from = c.from.bind(c), rpc = c.rpc.bind(c);
    function res(d, e) { return Promise.resolve({ data: d || null, error: e ? (typeof e === "string" ? { message: e } : e) : null }); }
    c.rpc = function (nm, a) {
      window.__calls.push([nm, a]);
      if (nm === "staff_home") return res({ org_id: "c1", org_name: "Demo Learning Centre", status: "active", today: TODAY, can: { students: true, timetable: true, charges: false } });
      if (!/^staff_(lessons|mark_attendance|correct_attendance)$/.test(nm)) return rpc(nm, a);
      if (cfg.error) return res(null, cfg.error);
      var l = L.filter((x) => x.id === a.p_lesson)[0];
      if (nm === "staff_lessons") {
        var m = L.filter((x) => x.d >= a.p_from && x.d <= a.p_to && (!a.p_tutor || x.tid === a.p_tutor));
        var shown = m.filter((x) => a.p_status === "all" || (a.p_status === "marked" ? x.att : !x.att && x.d <= TODAY));
        return res({ today: TODAY, can_mark: cfg.canMark !== false, page: a.p_page, size: a.p_size, total: shown.length,
          counts: { all: m.length, unmarked: m.filter((x) => !x.att && x.d <= TODAY).length, marked: m.filter((x) => x.att).length },
          tutors: [{ id: "m1", name: "Tutor One" }, { id: "m2", name: "Tutor Two" }],
          rows: shown.map((x) => ({ lesson_id: x.id, lesson_date: x.d, start_time: x.st, end_time: x.en, student_name: x.name, student_level: x.lvl, subject: "Math", tutor_id: x.tid, tutor_name: x.tut,
            attendance: x.att, status: x.att ? (x.att === "attended" ? "done" : "cancelled") : "scheduled", state: state(x), trial: false, remarks: x.rm || null, marked_at: x.att ? TODAY + "T01:00:00+00:00" : null,
            marked_by_name: x.by || null, charge_pending: ["absent", "late_cancelled", "cancelled_early"].indexOf(x.att) >= 0,
            can_mark: cfg.canMark !== false && state(x) === "open", can_correct: cfg.canMark !== false && state(x) === "marked" })) });
      }
      if (nm === "staff_mark_attendance") {
        if (l.d > TODAY) return res(null, "TOO_EARLY: a lesson can be marked from its day onward");
        if (l.att) return res(null, "ALREADY_MARKED: this lesson is already marked");
        if (cfg.remarksRequired && a.p_attendance === "attended" && !a.p_remarks) return res(null, "REMARKS_REQUIRED: this centre needs remarks before a lesson is marked attended");
        l.att = a.p_attendance; l.by = "Staff Sam"; l.rm = a.p_remarks; return res({ lesson_id: l.id, attendance: l.att });
      }
      if (!a.p_reason || !String(a.p_reason).trim()) return res(null, "REASON_REQUIRED: say why you are changing this mark");
      window.__audit.push({ lesson: l.id, from: l.att, to: a.p_attendance, reason: a.p_reason }); l.att = a.p_attendance; l.by = "Staff Sam"; return res({ lesson_id: l.id, attendance: l.att });
    };
    c.from = function (t) {
      if (t === "students") { var q = from(t), sel = q.select; q.select = function (cols, opt) { if (!(opt && opt.head)) return sel.apply(q, arguments); var o = {}; ["eq", "neq", "in", "is"].forEach(function (m) { o[m] = function () { return o; }; }); o.then = function (r, j) { return Promise.resolve({ data: null, count: 0, error: null }).then(r, j); }; return o; }; return q; }
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
const txt = (page) => page.locator("#content").innerText();


(async () => {
  const browser = await chromium.launch();
  const FULL = ["manage_students", "manage_timetable"];
  for (const mode of ["desktop", "phone", "dark"]) {
    const phone = mode === "phone", tag = mode + ": ";
    const { ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", FULL)] }, { phone, dark: mode === "dark" });
    await page.goto(BASE + "centre-attendance?id=c1"); await page.waitForSelector(".ca-row");
    ok(await page.locator(".ca-row").count() === 2, tag + "today shows its 2 lessons");
    ok(/Today/.test(await page.locator("#ca-when").innerText()), tag + "the heading says Today");
    ok(/Not marked\s*2|Not marked\s*1/.test(await page.locator("#ca-seg").innerText()), tag + "filter chips carry counts");
    // tomorrow: opens with no buttons
    await page.click("#ca-next"); await page.waitForFunction(() => /Ravi Menon/.test(document.querySelector("#ca-list").textContent));
    await page.click(".ca-row"); await page.waitForSelector("#ca-sheet.on");
    ok(await page.locator("#ca-marks, #ca-correct").count() === 0 && /hasn’t started/.test(await page.locator("#ca-sb").innerText()), tag + "tomorrow's lesson: sheet has NO buttons and says why");
    await page.click("#ca-sx");
    const tomorrowId = "l3", early = await page.evaluate(async (id) => (await window.sb.rpc("staff_mark_attendance", { p_lesson: id, p_attendance: "attended" })).error.message, tomorrowId);
    ok(/TOO_EARLY/.test(early), tag + "asking the server to mark tomorrow is refused");
    // today: mark Mei Ling
    await page.click("#ca-today"); await page.waitForFunction(() => document.querySelectorAll(".ca-row").length === 2);
    await page.locator(".ca-row", { hasText: "Mei Ling" }).click(); await page.waitForSelector("#ca-marks");
    ok(await page.locator("#ca-marks button").count() === 4, tag + "an open lesson offers the four marks");
    if (SC && mode !== "dark") await page.screenshot({ path: path.join(SC, "sheet-open-" + mode + ".png") });
    await page.fill("#ca-rm", "Did fractions"); await page.click('[data-mark="attended"]');
    await page.waitForFunction(() => /Attended/.test(document.querySelector("#ca-list").textContent));
    const mk = await page.evaluate(() => window.__calls.filter((c) => c[0] === "staff_mark_attendance").pop()[1]);
    ok(mk.p_lesson === "l2" && mk.p_attendance === "attended" && mk.p_remarks === "Did fractions", tag + "Mei Ling marked attended with her remarks (one call)");
    // correct tutor one's mark
    await page.locator(".ca-row", { hasText: "Aiden" }).click(); await page.waitForSelector("#ca-correct");
    ok(await page.locator("#ca-marks").count() === 0 && /Tutor One/.test(await page.locator("#ca-sb").innerText()), tag + "a marked lesson shows Correct, not the mark buttons");
    await page.click("#ca-correct"); await page.waitForSelector("#ca-cor.on");
    await page.click("#cc-save"); ok(/Say why/.test(await page.locator("#cc-msg").innerText()), tag + "a correction with no reason is refused in plain words");
    await page.fill("#cc-reason", "Parent confirmed the lesson took place");
    if (SC && mode !== "dark") await page.screenshot({ path: path.join(SC, "correct-" + mode + ".png") });
    await page.click("#cc-save"); await page.waitForFunction(() => document.querySelectorAll("#ca-cor.on").length === 0);
    const aud = await page.evaluate(() => window.__audit);
    ok(aud.length === 1 && aud[0].lesson === "l1" && aud[0].from === "absent" && aud[0].reason === "Parent confirmed the lesson took place", tag + "the correction was sent with its reason and the audit stand-in recorded it");
    await page.waitForFunction(() => /Aiden Tan[\s\S]*Attended/.test(document.querySelector("#ca-list").textContent));
    // week view groups by day, tutor filter works
    await page.click('#ca-view [data-v="week"]'); await page.waitForSelector(".ca-day");
    ok(await page.locator(".ca-day").count() >= 2, tag + "week view shows day headings");
    await page.selectOption("#ca-tutor", "m2"); await page.waitForFunction(() => document.querySelectorAll(".ca-row").length === 1);
    ok(/Mei Ling/.test(await page.locator(".ca-row").innerText()), tag + "tutor filter narrows to that tutor");
    await page.selectOption("#ca-tutor", ""); await page.click('#ca-seg [data-f="unmarked"]');
    await page.waitForFunction(() => /Sophie Lim/.test(document.querySelector("#ca-list").textContent));
    ok(/No tutor yet/.test(await page.locator("#ca-list").innerText()), tag + "Not marked filter lists the old lesson, flagged 'No tutor yet'");
    ok(errs.length === 0, tag + "no console errors " + errs.join("|"));
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + "no sideways scroll");
    if (SC) await page.screenshot({ path: path.join(SC, "list-" + mode + ".png") });
    await ctx.close();
  }
  // centre rule: remarks required -> plain refusal, stays open
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], remarksRequired: true });
    await page.goto(BASE + "centre-attendance?id=c1"); await page.waitForSelector(".ca-row"); await page.locator(".ca-row", { hasText: "Mei Ling" }).click(); await page.waitForSelector("#ca-marks");
    await page.click('[data-mark="attended"]'); await page.waitForFunction(() => /needs remarks/.test(document.querySelector("#ca-merr").textContent));
    ok(await page.locator("#ca-sheet.on").count() === 1, "remarks.required: plain message, sheet stays open so they can type the remark");
    const tabsTxt = (await page.locator(".tn-links a").filter({ visible: true }).allInnerTexts()).join("|");
    ok(/Attendance/.test(tabsTxt) && !/Attendance\s*\n?\s*soon/i.test(tabsTxt), "owner: Attendance tab is built (no soon pill)");
    await page.goto(BASE + "centre?id=c1&tab=attendance"); await page.waitForURL(/centre-attendance/); ok(true, "the old Attendance link goes to the new page"); await ctx.close(); }
  // look-only staff: no buttons anywhere
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_timetable"])], canMark: false });
    await page.goto(BASE + "centre-attendance?id=c1"); await page.waitForSelector(".ca-row"); await page.locator(".ca-row", { hasText: "Mei Ling" }).click(); await page.waitForSelector("#ca-sb p.ca-ro");
    ok(await page.locator("#ca-marks, #ca-correct").count() === 0 && /look at attendance/.test(await page.locator("#ca-sb").innerText()), "look-only: sheet has no buttons and says so"); await ctx.close(); }
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], error: { code: "PGRST202", message: "Could not find the function" } });
    await page.goto(BASE + "centre-attendance?id=c1"); await page.waitForSelector(".ca-block"); ok(/Not switched on yet/.test(await txt(page)), "migration missing: plain message"); await ctx.close(); }
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "tutor")] });
    await page.goto(BASE + "centre-attendance?id=c1"); await page.waitForTimeout(1500); ok(/\/tutor/.test(page.url()), "a centre tutor is sent to My lessons (" + page.url() + ")"); await ctx.close(); }
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner")] });
    await page.goto(BASE + "centre-attendance"); await page.waitForTimeout(1500); ok(/\/home/.test(page.url()), "a solo login is sent Home (" + page.url() + ")"); await ctx.close(); }
  await browser.close();
  console.log(fails ? fails + " FAILED" : "all passed"); process.exit(fails ? 1 : 0);
})();
