// Browser check for the centre Students screen (T3 step 2). Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/centre-students.check.js [screenshot-dir]
// The four database functions are replaced by a small in-memory stand-in that follows the same rules (the SQL tests prove the real ones).
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
const STUB_PLUS = STUB + `;(function(){var o=window.supabase.createClient;window.supabase.createClient=function(){var c=o.apply(this,arguments);if(window.__override)window.__override(c);return c;};})();`;
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
const SOLO = { id: "s1", kind: "solo", trading_name: "Empty Shell" }, C = { id: "c1", kind: "centre", trading_name: "Demo Learning Centre" };
const M = (o, role, permissions) => ({ org_id: o.id, user_id: "u1", role, status: "active", permissions: permissions || [], organisations: o });

function override(cfg) {
  var TODAY = new Date().toISOString().slice(0, 10), n = 100, ST = [], GS = {};
  function add(name, level, hh, gname, phone, extra) { var id = "st" + (++n); ST.push(Object.assign({ id: id, name: name, level: level, hh: hh, end_date: null, trial: false, notes: null }, extra || {})); GS[hh] = GS[hh] || [{ id: "g" + (++n), name: gname, relation: "Mother", phone: phone, email: null }]; return id; }
  add("Aiden Tan", "P5", "h1", "Mrs Tan", "+65 8000 0001"); add("Mei Ling Koh", "P6", "h2", "Mr Koh", "+65 8000 0002", { trial: true });
  add("Old Student", "Sec 4", "h3", "Mr Old", "+65 8000 0009", { end_date: "2020-01-01" });
  for (var i = 0; i < 30; i++) add("Pg " + String(i + 10), "P3", "hp" + i, "Parent " + i, "+65 8100 00" + (10 + i));
  function ended(s) { return !!s.end_date && s.end_date < TODAY; }
  function listRow(s) { var g = (GS[s.hh] || [])[0] || {}; return { id: s.id, name: s.name, level: s.level, end_date: s.end_date, ended: ended(s), trial: s.trial, household_id: s.hh, household_name: s.hh + " family", guardian_name: g.name || null, guardian_phone: g.phone || null, guardians: (GS[s.hh] || []).length }; }
  function sheet(s) { return { id: s.id, org_id: "c1", name: s.name, level: s.level, notes: s.notes, end_date: s.end_date, ended: ended(s), created_at: TODAY, today: TODAY, household: { id: s.hh, name: s.hh + " family" },
      guardians: GS[s.hh] || [], siblings: ST.filter((x) => x.hh === s.hh && x.id !== s.id).map((x) => ({ id: x.id, name: x.name, level: x.level, ended: ended(x) })), subjects: ["Math"], lessons_total: 2, lessons_trial: s.trial ? 1 : 0, trial: s.trial,
      next_lessons: [{ date: TODAY, start: "15:00:00", end: "16:00:00", subject: "Math", tutor: null }] }; }
  window.__calls = [];
  window.__override = function (c) {
    var from = c.from.bind(c), rpc = c.rpc.bind(c);
    function res(d, e) { return Promise.resolve({ data: d || null, error: e ? (typeof e === "string" ? { message: e } : e) : null }); }
    c.rpc = function (nm, a) {
      window.__calls.push([nm, a]);
      if (nm === "staff_home") return res({ org_id: "c1", org_name: "Demo Learning Centre", status: "active", today: TODAY, can: { students: true, timetable: false, charges: false } });
      if (!/^staff_/.test(nm)) return rpc(nm, a);
      if (cfg.error) return res(null, cfg.error);
      if (nm === "staff_students") {
        var q = (a.p_q || "").toLowerCase(), m = ST.filter((s) => !q || (s.name + " " + s.level + " " + ((GS[s.hh] || []).map((g) => g.name + g.phone).join(" "))).toLowerCase().includes(q));
        var cnt = { active: m.filter((s) => !ended(s)).length, ended: m.filter(ended).length, trial: m.filter((s) => s.trial).length, all: m.length };
        var shown = m.filter((s) => a.p_filter === "all" || (a.p_filter === "ended" ? ended(s) : a.p_filter === "trial" ? s.trial : !ended(s))).sort((x, y) => x.name.localeCompare(y.name));
        return res({ org_id: "c1", today: TODAY, filter: a.p_filter, page: a.p_page, size: a.p_size, total: shown.length, counts: cnt, rows: shown.slice((a.p_page - 1) * a.p_size, a.p_page * a.p_size).map(listRow) });
      }
      if (nm === "staff_student") return res(sheet(ST.filter((s) => s.id === a.p_student)[0]));
      if (nm === "staff_save_student") {
        if (/^\s*$/.test(a.p_name)) return res(null, "BAD_STUDENT: give the student a name");
        var s, created = !a.p_student, hh = a.p_household;
        if (created) { hh = hh || "hn" + (++n); s = { id: "st" + (++n), name: a.p_name, hh: hh, end_date: null, trial: false }; ST.push(s); } else s = ST.filter((x) => x.id === a.p_student)[0];
        s.name = a.p_name; s.level = a.p_level; s.notes = a.p_notes;
        if (a.p_guardians) GS[hh] = a.p_guardians.map((g, i) => Object.assign({ id: g.id || "g" + (++n) }, g));
        return res({ student_id: s.id, household_id: hh, created: created });
      }
      if (nm === "staff_set_student_end") { var t = ST.filter((x) => x.id === a.p_student)[0]; t.end_date = a.p_end_date; return res({ student_id: t.id, end_date: a.p_end_date, ended: ended(t) }); }
      return rpc(nm, a);
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
const rows = (page) => page.locator(".cs-row").count();

(async () => {
  const browser = await chromium.launch();
  for (const mode of ["desktop", "phone", "dark"]) {
    const phone = mode === "phone", tag = mode + ": ";
    // staff with manage_students (front desk and full staff use the same screen): add Test Child with a parent
    for (const perms of [["manage_students"], ["manage_students", "manage_timetable", "issue_invoices"]]) {
      const who = perms.length === 1 ? "front desk" : "staff";
      const { ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", perms)] }, { phone, dark: mode === "dark" });
      await page.goto(BASE + "centre-students?id=c1"); await page.waitForSelector(".cs-row");
      ok(await rows(page) === 25, tag + who + ": first page has 25 rows of 32 active");
      ok(/1–25 of 32/.test(await page.locator("#cs-pl").innerText()), tag + who + ": pager says 1–25 of 32");
      await page.click("#cs-next"); await page.waitForFunction(() => document.querySelectorAll(".cs-row").length === 7);
      ok(true, tag + who + ": page 2 has the last 7");
      await page.fill("#cs-q", "mei"); await page.waitForFunction(() => document.querySelectorAll(".cs-row").length === 1);
      ok(/Mei Ling Koh/.test(await page.locator(".cs-row").innerText()) && /Trial/.test(await page.locator(".cs-row").innerText()), tag + who + ": server-side search finds Mei Ling Koh, with the Trial badge");
      await page.fill("#cs-q", "zzz"); await page.waitForSelector(".cs-empty");
      ok(/No students match/.test(await txt(page)), tag + who + ": empty search says so");
      await page.fill("#cs-q", "");
      await page.waitForFunction(() => document.querySelectorAll(".cs-row").length === 25);
      // add
      await page.click(phone ? "#td-fab" : "#cs-add");
      await page.waitForSelector("#cs-form.on");
      await page.click("#cf-save"); ok(/name/i.test(await page.locator("#cf-msg").innerText()), tag + who + ": a blank name is refused in plain words");
      await page.fill("#cf-name", "Test Child"); await page.fill("#cf-level", "Sec 2");
      await page.fill("#cg-n0", "Mrs Test"); await page.click("#cf-save"); ok(/phone number or an email/.test(await page.locator("#cf-gs").innerText()), tag + who + ": a parent without phone or email is refused");
      await page.selectOption("#cg-r0", "Mother"); await page.fill("#cg-p0", "+65 9123 4567");
      if (SC && mode !== "dark") await page.screenshot({ path: path.join(SC, "form-" + mode + "-" + who.replace(" ", "") + ".png") });
      await page.click("#cf-save"); await page.waitForSelector("#cs-sheet.on");
      const sh = await page.locator("#cs-sb").innerText();
      ok(/Test Child/.test(await page.locator("#cs-st").innerText()) && /Mrs Test/.test(sh) && /9123 4567/.test(sh) && /Main contact|Mother/.test(sh), tag + who + ": Test Child added with the parent, sheet shows them");
      const call = await page.evaluate(() => window.__calls.filter((c) => c[0] === "staff_save_student").pop()[1]);
      ok(call.p_org === "c1" && call.p_student === null && call.p_household === null && call.p_guardians.length === 1 && call.p_guardians[0].phone === "+65 9123 4567", tag + who + ": one call, new family, one guardian");
      if (SC && who === "staff") await page.waitForTimeout(500), await page.screenshot({ path: path.join(SC, "sheet-" + mode + ".png") });
      // sibling
      await page.click("#cs-sibling"); await page.waitForSelector("#cs-form.on");
      ok(await page.locator("#cf-contacts").isHidden() && /Joins/.test(await page.locator("#cf-fam").innerText()), tag + who + ": sibling form reuses the family's contacts");
      await page.fill("#cf-name", "Test Sibling"); await page.click("#cf-save"); await page.waitForFunction(() => /Test Sibling/.test(document.querySelector("#cs-st").textContent));
      const sib = await page.evaluate(() => window.__calls.filter((c) => c[0] === "staff_save_student").pop()[1]);
      ok(sib.p_household && sib.p_guardians === null, tag + who + ": sibling sent with the family id and no guardians");
      // discontinue
      await page.click("#cs-disc"); await page.waitForSelector("#cs-end.on"); await page.fill("#ce-date", "2020-06-01"); await page.click("#ce-save");
      await page.waitForFunction(() => /Ended/.test(document.querySelector("#cs-sb").textContent));
      ok(/Lessons ended/.test(await page.locator("#cs-sb").innerText()) && await page.locator("#cs-back").count() === 1, tag + who + ": discontinued: sheet says ended and offers Bring back");
      await page.click("#cs-sx"); await page.click('#cs-seg [data-f="ended"]'); await page.waitForFunction(() => /Test Sibling/.test(document.querySelector("#cs-list").textContent));
      ok(/Old Student/.test(await page.locator("#cs-list").innerText()), tag + who + ": the Ended filter lists them");
      ok(errs.length === 0, tag + who + ": no console errors " + errs.join("|"));
      ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + who + ": no sideways scroll");
      if (SC && who === "staff") await page.screenshot({ path: path.join(SC, "list-" + mode + ".png") });
      await ctx.close();
    }
  }
  // the owner sees the same screen; menu has Students built (no soon pill on it)
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")] });
    await page.goto(BASE + "centre-students?id=c1"); await page.waitForSelector(".cs-row");
    const tabsTxt = (await page.locator(".tn-links a").filter({ visible: true }).allInnerTexts()).join("|");
    ok(/Students/.test(tabsTxt) && !/Students\s*\n?\s*soon/i.test(tabsTxt), "owner: Students tab is built (no soon pill)");
    ok(await page.locator(".tn-links a.active, .tn-links a[aria-current]").filter({ hasText: "Students" }).count() === 1, "owner: the Students tab is the highlighted one");
    await page.goto(BASE + "centre?id=c1&tab=students"); await page.waitForURL(/centre-students/); ok(true, "owner: the old Students link goes to the new page"); await ctx.close(); }
  // timetable-only staff: no Students tab; database refusal is a plain page
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_timetable"])], error: "NOT_ALLOWED: nope" });
    await page.goto(BASE + "centre-students?id=c1"); await page.waitForSelector(".cs-block");
    ok(/Not available to you/.test(await txt(page)), "timetable-only: typing the address gives a plain 'not available'");
    ok(!/Students/.test((await page.locator(".tn-links a").filter({ visible: true }).allInnerTexts()).join("|")), "timetable-only: no Students tab in the menu"); await ctx.close(); }
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], error: { code: "PGRST202", message: "Could not find the function" } });
    await page.goto(BASE + "centre-students?id=c1"); await page.waitForSelector(".cs-block"); ok(/Not switched on yet/.test(await txt(page)), "migration missing: plain message"); await ctx.close(); }
  // tutor: sent to My lessons; solo: Home
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "tutor")] });
    await page.goto(BASE + "centre-students?id=c1"); await page.waitForTimeout(1500); ok(/\/tutor/.test(page.url()), "a centre tutor is sent to My lessons (" + page.url() + ")"); await ctx.close(); }
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner")] });
    await page.goto(BASE + "centre-students"); await page.waitForTimeout(1500); ok(/\/home/.test(page.url()), "a solo login is sent Home (" + page.url() + ")"); await ctx.close(); }
  await browser.close();
  console.log(fails ? fails + " FAILED" : "all passed"); process.exit(fails ? 1 : 0);
})();
