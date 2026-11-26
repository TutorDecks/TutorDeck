// Browser check for the read-only Timetable (T3 step 6). Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/centre-timetable.check.js [screenshot-dir]
// The database function staff_timetable is replaced by a small in-memory stand-in (tests/sql/staff_timetable_test.sql proves the real one).
// Holidays are kept in localStorage, standing in for a row added on /org.
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
    { id: "l1", sid: "s1", d: TODAY, st: "15:00:00", en: "16:00:00", name: "Aiden Tan", lvl: "P5", tid: "m1", tn: "Tutor One", state: "open" },
    { id: "l2", sid: "s2", d: TODAY, st: "16:00:00", en: "17:30:00", name: "Ravi Menon", lvl: "Sec 1", tid: null, tn: null, state: "open", nt: true },
    { id: "l3", sid: "s3", d: add(TODAY, 2), st: "10:00:00", en: "11:00:00", name: "Sophie Lim", lvl: "Sec 2", tid: "m2", tn: "Tutor Two", state: "future", trial: true },
    { id: "l4", sid: "s4", d: add(TODAY, 3), st: "10:00:00", en: "11:00:00", name: "Daniel Ong", lvl: "P4", tid: null, tn: null, state: "future", nt: true },
    { id: "l5", sid: "s1", d: add(TODAY, 9), st: "10:00:00", en: "11:00:00", name: "Aiden Tan", lvl: "P5", tid: "m1", tn: "Tutor One", state: "future" }];
  var hol = []; try { hol = JSON.parse(localStorage.getItem("__holidays") || "[]"); } catch (e) {}
  window.__calls = [];
  window.__override = function (c) {
    var from = c.from.bind(c), rpc = c.rpc.bind(c);
    function res(d, e) { return Promise.resolve({ data: d || null, error: e ? { message: e } : null }); }
    c.rpc = function (nm, a) {
      window.__calls.push([nm, a]);
      if (nm === "staff_home") return res({ org_id: "c1", org_name: "Demo Learning Centre", status: "active", today: TODAY, can: { students: true, timetable: true, charges: false },
        students_active: 4, today_lessons: 2, today_marked: 0, today_to_mark: 2, unmarked_past: 0, no_tutor_14d: 2, pending_charges: 0, trials_this_month: 0 });
      if (nm === "staff_timetable") {
        if (cfg.missing) return res(null, "Could not find the function public.staff_timetable");
        var m = L.filter(function (x) { return x.d >= a.p_from && x.d <= a.p_to && (!a.p_tutor || x.tid === a.p_tutor) && (!a.p_student || x.sid === a.p_student); });
        var shown = m.filter(function (x) { return !a.p_notutor || x.nt; });
        var hs = hol.filter(function (h) { return h.starts_on <= a.p_to && h.ends_on >= a.p_from; });
        return res({ today: TODAY, page: 1, size: a.p_size, total: shown.length, holidays: hs,
          counts: { n_all: m.length, n_notutor: m.filter(function (x) { return x.nt; }).length, n_cancelled: 0, n_holiday: 0 },
          can_edit: cfg.canEdit !== false, replacements_allowed: !cfg.replOff,
          tutors: [{ id: "m1", name: "Tutor One", active: true }, { id: "m2", name: "Tutor Two", active: true }, { id: "m3", name: "Not Yet Joined", active: false }], branches: cfg.branches || [],
          students: [{ id: "s1", name: "Aiden Tan" }, { id: "s2", name: "Ravi Menon" }, { id: "s3", name: "Sophie Lim" }, { id: "s4", name: "Daniel Ong" }], students_more: false,
          rows: shown.map(function (x) {
            var h = hol.filter(function (q) { return q.starts_on <= x.d && q.ends_on >= x.d; })[0];
            return { lesson_id: x.id, lesson_date: x.d, start_time: x.st, end_time: x.en, minutes: x.id === "l2" ? 90 : 60, student_id: x.sid, student_name: x.name, student_level: x.lvl, subject: "Math",
              covered_for_id: x.cf ? "m1" : null, covered_for_name: x.cf || null, can_reassign: x.locked ? false : true,
              tutor_id: x.tid, tutor_name: x.tn, no_tutor: !!x.nt, trial: !!x.trial, attendance: null, state: x.state, cancelled: false, postponed: false, holiday: h ? h.name : null, session_id: null, online_link: null };
          }) });
      }
      if (nm === "staff_reassign_lesson") {
        var x = L.filter(function (q) { return q.id === a.p_lesson; })[0];
        if (!x) return res(null, "NOT_FOUND");
        if (cfg.refuse) return res(null, cfg.refuse);
        if (cfg.replOff && x.tid) return res(null, "REPLACEMENT_OFF: this centre doesn't allow replacement tutors. An owner can switch this on in the centre settings");
        var nm2 = a.p_new_tutor === "m1" ? "Tutor One" : "Tutor Two";
        if (a.p_mode === "cover") x.cf = x.cf || x.tn; else x.cf = null;
        x.tid = a.p_new_tutor; x.tn = nm2; x.nt = false;
        return res({ lesson_id: x.id, lessons: 1, mode: a.p_mode, tutor_id: a.p_new_tutor, tutor_name: nm2, covered_for: x.cf ? "m1" : null, links_ended: 0, links_added: 0 });
      }
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


(async () => {
  const browser = await chromium.launch();
  const TODAY = new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 10);
  const plus = (d, n) => { const x = new Date(d + "T00:00:00Z"); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };
  for (const mode of ["desktop", "phone", "dark"]) {
    const phone = mode === "phone", tag = mode + ": ";
    const { ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_timetable"])] }, { phone, dark: mode === "dark" });
    await page.goto(BASE + "centre-timetable.html?id=c1&view=next14"); await page.waitForSelector(".tt-row");
    ok(await page.locator(".tt-row").count() === 5 - 0, tag + "the 14-day list shows the 5 lessons");
    ok(await page.locator(".tt-row.notutor").count() === 2 && /No tutor yet/.test(await page.locator(".tt-row.notutor").first().innerText()), tag + "the 2 lessons with no tutor are flagged amber");
    const amber = await page.locator(".tt-row.notutor").first().evaluate((e) => getComputedStyle(e).borderLeftColor);
    ok(amber !== "rgba(0, 0, 0, 0)" && amber !== "transparent", tag + "the amber flag has a visible colour (" + amber + ")");
    ok(/Trial/.test(await page.locator(".tt-row", { hasText: "Sophie" }).innerText()), tag + "a trial lesson carries a Trial chip");
    ok(/1 h 30|Ravi/.test(await page.locator(".tt-row", { hasText: "Ravi" }).innerText()), tag + "rows show student and time");
    ok(!/S\$|\$\d|price|rate/i.test(await page.locator("#tt").innerText()), tag + "no money on the page");
    ok(/2 with no tutor/.test(await page.locator("#tt-count").innerText()), tag + "the count says how many have no tutor");
    // filters
    await page.selectOption("#tt-tutor", "m1"); await page.waitForFunction(() => document.querySelectorAll(".tt-row").length === 2);
    await page.selectOption("#tt-tutor", ""); await page.waitForFunction(() => document.querySelectorAll(".tt-row").length === 5);
    await page.click("#tt-notutor"); await page.waitForFunction(() => document.querySelectorAll(".tt-row").length === 2);
    ok(await page.locator(".tt-row.notutor").count() === 2 && /f=notutor/.test(page.url()), tag + "the No tutor filter shows just those 2 and is kept in the address");
    await page.click("#tt-clear"); await page.waitForFunction(() => document.querySelectorAll(".tt-row").length === 5);
    await page.selectOption("#tt-student", "s1"); await page.waitForFunction(() => document.querySelectorAll(".tt-row").length === 2);
    ok(await page.locator("#tt-clear").isVisible(), tag + "the student filter works and offers Clear filters");
    await page.click("#tt-clear"); await page.waitForSelector(".tt-row");
    ok(await page.locator("#tt-branch").isHidden(), tag + "no branch control for a remote centre with no branches");
    // sheet is read only
    await page.locator(".tt-row", { hasText: "Ravi" }).click(); await page.waitForSelector("#tt-sheet.on");
    const sb = await page.locator("#tt-sb").innerText();
    ok(/Online link\s*\n?\s*Not set/.test(sb) && /No tutor yet/.test(sb) && /Open in Attendance/.test(sb), tag + "the sheet shows 'Not set' for the link and the no-tutor warning");
    ok(await page.locator("#tt-sb input, #tt-sb textarea, #tt-sb select").count() === 0, tag + "the sheet has no form fields (read only)");
    await page.waitForTimeout(450); if (SC && mode !== "dark") await page.screenshot({ path: path.join(SC, "timetable-sheet-" + mode + ".png") });
    await page.click("#tt-sx");
    // holiday band: "add a holiday" (stands in for a row added on /org), reload, see the grey band
    await page.evaluate((h) => localStorage.setItem("__holidays", JSON.stringify([h])), { id: "h1", name: "Deepavali", starts_on: plus(TODAY, 2), ends_on: plus(TODAY, 2), branch_id: null, branch_name: null });
    await page.reload(); await page.waitForSelector(".tt-row");
    ok(/Deepavali/.test(await page.locator(".tt-band").first().innerText()), tag + "a holiday shows as a grey band");
    ok(/Holiday/.test(await page.locator(".tt-row", { hasText: "Sophie" }).innerText()), tag + "a lesson on the holiday carries a Holiday chip");
    await page.evaluate(() => localStorage.removeItem("__holidays"));
    // week view navigation: next and back, and "no lessons" on empty days
    await page.goto(BASE + "centre-timetable.html?id=c1"); await page.waitForSelector(".tt-row, .tt-none");
    ok(/–/.test(await page.locator("#tt-when").innerText()) && await page.locator(".tt-day").count() >= 1, tag + "the default is the week, day by day");
    await page.click("#tt-next"); await page.waitForFunction(() => /No lessons|lesson/.test(document.querySelector("#tt-list").textContent));
    await page.click("#tt-today"); await page.waitForSelector(".tt-row");
    ok(errs.length === 0, tag + "no console errors " + errs.join("|"));
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + "no sideways scroll");
    if (SC) await page.screenshot({ path: path.join(SC, "timetable-" + mode + ".png"), fullPage: true });
    await ctx.close();
  }
  // ---- T3 step 8: Reassign or cover (the real rules are proved in tests/sql/staff_reassign_test.sql; this checks the screen) ----
  for (const mode of ["desktop", "phone", "dark"]) {
    const phone = mode === "phone", tag = "cover " + mode + ": ";
    const { ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_timetable"])] }, { phone, dark: mode === "dark" });
    await page.goto(BASE + "centre-timetable.html?id=c1&view=next14"); await page.waitForSelector(".tt-row");
    await page.locator(".tt-row", { hasText: "Aiden" }).first().click(); await page.waitForSelector("#tt-sheet.on");
    ok(await page.locator("#tt-reassign").count() === 1 && /Reassign or cover/.test(await page.locator("#tt-reassign").innerText()), tag + "staff with manage_timetable see 'Reassign or cover' in the lesson sheet");
    await page.click("#tt-reassign");
    ok(await page.locator("#tt-rt option").allInnerTexts().then((o) => o.join("|") === "Choose a tutor|Tutor Two"), tag + "the picker offers active tutors only, not the current one or the invited one");
    ok(await page.locator('input[name="tt-rm"]:checked').getAttribute("value") === "cover" && await page.locator("#tt-rl").isHidden(), tag + "cover is the default and the assigned-tutor box is hidden");
    await page.click("#tt-rs"); ok(/Choose who/.test(await page.locator("#tt-re-tutor").innerText()), tag + "no tutor chosen: a plain message");
    await page.selectOption("#tt-rt", "m2"); await page.click("#tt-rs"); ok(/Say why/.test(await page.locator("#tt-re-reason").innerText()), tag + "no reason: a plain message");
    await page.locator('input[name="tt-rm"][value="reassign"]').check(); ok(await page.locator("#tt-rl").isVisible(), tag + "choosing 'Give this lesson to them' reveals the assigned-tutor choice (off by default)");
    ok(!(await page.locator("#tt-rl").isChecked()), tag + "and it is not ticked by default");
    await page.locator('input[name="tt-rm"][value="cover"]').check(); ok(await page.locator("#tt-rl").isHidden(), tag + "back to cover hides it again");
    await page.waitForTimeout(450); if (SC && mode !== "dark") await page.screenshot({ path: path.join(SC, "reassign-form-" + mode + ".png") });
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + "no sideways scroll with the form open");
    await page.fill("#tt-rr", "Tutor One is unwell"); await page.click("#tt-rs");
    await page.waitForFunction(() => !document.querySelector("#tt-sheet.on")); await page.waitForSelector(".tt-chip.cover");
    ok(/Covered by Tutor Two/.test(await page.locator(".tt-row", { hasText: "Aiden" }).first().innerText()), tag + "the row now says 'Covered by Tutor Two'");
    const calls = await page.evaluate(() => window.__calls.filter((c) => c[0] === "staff_reassign_lesson").map((c) => c[1]));
    ok(calls.length === 1 && calls[0].p_mode === "cover" && calls[0].p_reason === "Tutor One is unwell" && calls[0].p_update_links === false && calls[0].p_new_tutor === "m2", tag + "one cover call with the reason, and no assigned-tutor change");
    await page.selectOption("#tt-tutor", "m1"); await page.waitForFunction(() => document.querySelectorAll(".tt-row").length === 1);
    ok(!/Covered/.test(await page.locator("#tt").innerText()), tag + "filtered to Tutor One: the covered lesson is gone from their list (Aiden's next week is still theirs)");
    await page.selectOption("#tt-tutor", "m2"); await page.waitForFunction(() => document.querySelectorAll(".tt-row").length === 2);
    ok(/Covered by Tutor Two/.test(await page.locator("#tt").innerText()), tag + "and it is on Tutor Two's list");
    await page.click("#tt-clear"); await page.waitForFunction(() => document.querySelectorAll(".tt-row").length === 5);
    // the sheet of the covered lesson says who it was meant for; the other choice sends the assigned-tutor box when ticked
    await page.locator(".tt-row", { hasText: "Aiden" }).first().click(); await page.waitForSelector("#tt-sheet.on");
    ok(/Covering for\s*\n?\s*Tutor One/.test(await page.locator("#tt-sb").innerText()), tag + "the sheet says 'Covering for Tutor One'");
    await page.click("#tt-sx");
    await page.locator(".tt-row", { hasText: "Aiden" }).nth(1).click(); await page.waitForSelector("#tt-sheet.on");
    await page.click("#tt-reassign"); await page.selectOption("#tt-rt", "m2"); await page.locator('input[name="tt-rm"][value="reassign"]').check(); await page.locator("#tt-rl").check();
    await page.fill("#tt-rr", "Moves to Tutor Two"); await page.click("#tt-rs"); await page.waitForFunction(() => !document.querySelector("#tt-sheet.on"));
    const c2 = await page.evaluate(() => window.__calls.filter((c) => c[0] === "staff_reassign_lesson").map((c) => c[1]));
    ok(c2.length === 2 && c2[1].p_mode === "reassign" && c2[1].p_update_links === true, tag + "reassign with the box ticked asks for the assigned-tutor change");
    // no tutor yet: a first assignment, no reason needed
    await page.locator(".tt-row", { hasText: "Ravi" }).click(); await page.waitForSelector("#tt-sheet.on");
    ok(/Assign a tutor/.test(await page.locator("#tt-reassign").innerText()), tag + "a lesson with no tutor offers 'Assign a tutor'");
    await page.click("#tt-reassign"); ok(await page.locator('input[name="tt-rm"]').count() === 0, tag + "no cover/reassign choice for a first assignment");
    await page.selectOption("#tt-rt", "m1"); await page.click("#tt-rs"); await page.waitForFunction(() => !document.querySelector("#tt-sheet.on"));
    ok(!/No tutor yet/.test(await page.locator(".tt-row", { hasText: "Ravi" }).innerText()), tag + "assigned without a reason");
    ok(errs.length === 0, tag + "no console errors " + errs.join("|"));
    await ctx.close();
  }
  // the centre switched replacements OFF: the page explains instead of offering the form, a first assignment is still possible
  { const { ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_timetable"])], replOff: true }, { phone: true });
    await page.goto(BASE + "centre-timetable.html?id=c1&view=next14"); await page.waitForSelector(".tt-row");
    await page.locator(".tt-row", { hasText: "Aiden" }).first().click(); await page.waitForSelector("#tt-sheet.on");
    ok(await page.locator("#tt-reassign").count() === 0 && /doesn’t allow replacement tutors/.test(await page.locator("#tt-ranote").innerText()), "replacements OFF: no button, a plain note instead");
    await page.waitForTimeout(450); if (SC) await page.screenshot({ path: path.join(SC, "reassign-off-phone.png") });
    await page.click("#tt-sx");
    await page.locator(".tt-row", { hasText: "Ravi" }).click(); await page.waitForSelector("#tt-sheet.on");
    ok(await page.locator("#tt-reassign").count() === 1, "replacements OFF: a lesson with no tutor can still be assigned");
    ok(errs.length === 0, "replacements OFF: no console errors " + errs.join("|")); await ctx.close(); }
  // the page thought it was allowed but the database refuses (the setting changed meanwhile): the plain message, no code, the form stays
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_timetable"])], refuse: "REPLACEMENT_OFF: this centre doesn't allow replacement tutors. An owner can switch this on in the centre settings" });
    await page.goto(BASE + "centre-timetable.html?id=c1&view=next14"); await page.waitForSelector(".tt-row");
    await page.locator(".tt-row", { hasText: "Aiden" }).first().click(); await page.click("#tt-reassign");
    await page.selectOption("#tt-rt", "m2"); await page.fill("#tt-rr", "Sick"); await page.click("#tt-rs"); await page.waitForSelector("#tt-re:not([hidden])");
    const t = await page.locator("#tt-re").innerText();
    ok(/doesn’t allow replacement tutors/.test(t) && !/REPLACEMENT_OFF/.test(t) && await page.locator("#tt-rf").count() === 1, "refused by the database: the plain message shows, no error code, the form stays"); await ctx.close(); }
  // locked lessons (marked / paid / invoiced) and a login without manage_timetable
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_students"])], canEdit: false });
    await page.goto(BASE + "centre-timetable.html?id=c1&view=next14"); await page.waitForSelector(".tt-row");
    await page.locator(".tt-row", { hasText: "Aiden" }).first().click(); await page.waitForSelector("#tt-sheet.on");
    ok(await page.locator("#tt-reassign").count() === 0 && await page.locator("#tt-ranote").count() === 0, "front desk (no manage_timetable): no Reassign button and no note"); await ctx.close(); }

  // branches present: the control shows
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], branches: [{ id: "b1", name: "Bishan" }] });
    await page.goto(BASE + "centre-timetable.html?id=c1"); await page.waitForSelector(".tt-row, .tt-none");
    ok(await page.locator("#tt-branch").isVisible(), "a centre with branches gets the branch (holiday) control"); await ctx.close(); }
  // menu: owner and every kind of staff see Timetable; the Home tile opens the no-tutor list
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_students"])] });
    await page.goto(BASE + "centre.html?id=c1"); await page.waitForSelector(".ch-tile");
    ok(await page.locator(".tn-links a", { hasText: "Timetable" }).filter({ visible: true }).count() === 1, "front desk (students only) sees the Timetable tab (view = any owner / staff)");
    ok(await page.locator(".tn-links a", { hasText: "Timetable" }).filter({ visible: true }).locator(".soon-pill").count() === 0, "and it is not marked soon");
    await page.locator("a.ch-link", { hasText: "no tutor" }).click(); await page.waitForURL(/centre-timetable.*f=notutor/); await page.waitForSelector(".tt-row");
    ok(await page.locator(".tt-row").count() === 2 && /14 days/.test(await page.locator("#tt-view .on").innerText()), "the Home 'no tutor' tile opens the 14-day no-tutor list with the same 2 lessons");
    await ctx.close(); }
  // the migration missing, a tutor-only login, a stranger
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], missing: true });
    await page.goto(BASE + "centre-timetable.html?id=c1"); await page.waitForSelector(".tt-block");
    ok(/migration_staff_timetable/.test(await page.locator("#tt").innerText()), "migration missing: a plain message names the file"); await ctx.close(); }
  { const { ctx, page } = await open(browser, { members: [M(C, "tutor")] });
    await page.goto(BASE + "centre-timetable.html?id=c1"); await page.waitForTimeout(1500);
    ok(!/centre-timetable/.test(page.url()) || (await page.locator(".tt-row").count()) === 0, "a tutor does not get the staff timetable (" + page.url() + ")"); await ctx.close(); }
  await browser.close();
  console.log(fails ? fails + " FAILED" : "ALL PASSED"); process.exit(fails ? 1 : 0);
})();
