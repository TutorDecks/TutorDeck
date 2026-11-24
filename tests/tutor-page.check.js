// Browser check for the tutor page and the role-based menu (not part of CI: needs Playwright + `python3 tests/server.py 8765`).
//   node tests/tutor-page.check.js [screenshot-dir]
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
const AXE = (() => { try { return fs.readFileSync(path.join(ROOT, "tests/node_modules/axe-core/axe.min.js"), "utf8"); } catch (e) { return null; } })();
async function axeCheck(page, tag) {   // serious/critical problems only, the same bar as tests/smoke.py
  if (!AXE) return console.log("skip accessibility (npm install in tests/ to enable)");
  await page.evaluate(AXE);
  const v = await page.evaluate(() => axe.run(document, { runOnly: ["wcag2a", "wcag2aa", "best-practice"] }).then((r) => r.violations.filter((x) => x.impact === "serious" || x.impact === "critical").map((x) => x.id + " (" + x.nodes.length + ") e.g. " + x.nodes[0].target.join(" "))));
  ok(v.length === 0, tag + ": accessibility" + (v.length ? " " + v.join("; ") : ""));
}
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };

// the stub plus a hook that lets each scenario replace some database answers
const STUB_PLUS = STUB + `;(function(){var o=window.supabase.createClient;window.supabase.createClient=function(){var c=o.apply(this,arguments);if(window.__override)window.__override(c);return c;};})();`;

function override(cfg) {   // runs in the page before anything else
  window.__calls = [];
  window.__override = function (c) {
    var iso = function (n) { var d = new Date(); d.setDate(d.getDate() + n); var p = function (x) { return (x < 10 ? "0" : "") + x; }; return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()); };
    var L = function (id, off, o) { return Object.assign({ lesson_id: id, org_id: "o2", org_name: "Opus Tuition", student_id: "s" + id, student_name: "Pupil " + id, student_level: "P5", parent_contact: null,
      lesson_date: iso(off), start_time: "16:00:00", end_time: "17:00:00", subject: "Math", status: "scheduled", attendance: null, trial: false, session_id: null,
      topics: null, homework: null, remarks: null, remarks_due_at: null, can_mark: true, can_note: true, can_cancel: false, remarks_required: false,
      can_flag_trial: false, tutor_sets_compensation: false, charge_pending: false }, o || {}); };
    var lessons = cfg.lessons ? cfg.lessons.map(function (x) { return L(x[0], x[1], x[2]); }).sort(function (a, b) { return a.lesson_date < b.lesson_date ? -1 : a.lesson_date > b.lesson_date ? 1 : 0; }) : [];   // the database returns date order
    var origRpc = c.rpc.bind(c), origFrom = c.from.bind(c);
    c.rpc = function (n, a) {
      window.__calls.push([n, a]);
      if (n === "tutor_my_lessons") return Promise.resolve(cfg.rpcError ? { data: null, error: { message: "boom" } } : { data: lessons, error: null });
      if (n === "tutor_mark_attendance") return Promise.resolve(cfg.markError ? { data: null, error: { message: cfg.markError } } : { data: null, error: null });
      return origRpc(n, a);
    };
    c.from = function (t) {
      if (t === "memberships" && cfg.role) { var q = { select: function () { return q; }, eq: function () { return q; }, then: function (r, j) { return Promise.resolve({ data: cfg.role.memberships, error: null }).then(r, j); } }; return q; }
      if (t === "students" && cfg.role && cfg.role.studentCount != null) { var s = { select: function () { return s; }, then: function (r, j) { return Promise.resolve({ data: [], count: cfg.role.studentCount, error: null }).then(r, j); } }; return s; }
      return origFrom(t);
    };
  };
}

async function open(browser, vp, theme, cfg, url, pre) {
  const ctx = await browser.newContext(vp === "phone" ? { viewport: { width: 390, height: 844 }, isMobile: true, deviceScaleFactor: 2 } : { viewport: { width: 1100, height: 900 } });
  await ctx.addInitScript((t) => { try { localStorage.setItem("td_theme", t); } catch (e) {} }, theme);
  await ctx.route(/^(?!http:\/\/127\.0\.0\.1).*/, (r) => r.abort());
  const page = await ctx.newPage(); const errs = [];
  await page.route("**/assets/vendor/supabase-2.118.0.js", (r) => r.fulfill({ body: STUB_PLUS, contentType: "application/javascript" }));
  await page.addInitScript(override, cfg);
  if (pre) await page.addInitScript(pre);
  page.on("pageerror", (e) => errs.push(e.message));
  await page.goto(BASE + url, { waitUntil: "load" }); await page.waitForTimeout(1300);
  return { ctx, page, errs };
}
const LESSONS = [["a", -3], ["b", -1, { attendance: "late_cancelled", can_mark: false }], ["c", 0], ["d", 0, { attendance: "attended" }], ["e", 0, { can_mark: false }],
  ["f", 2, { can_mark: false, can_note: false }], ["g", -5, { status: "cancelled", can_mark: false, can_note: false }], ["h", -9, { can_mark: false, can_note: false }]];

(async () => {
  const b = await chromium.launch();
  // ---------- A. the page, both screen sizes and themes
  for (const [vp, theme] of [["desktop", "light"], ["phone", "light"], ["phone", "dark"]]) {
    const { ctx, page, errs } = await open(b, vp, theme, { lessons: LESSONS }, "tutor");
    const tag = vp + "/" + theme;
    const sections = await page.$$eval(".section-title", (e) => e.map((x) => x.textContent.trim()));
    ok(JSON.stringify(sections) === JSON.stringify(["To mark", "Today", "Coming up", "Earlier"]), tag + ": sections " + sections.join(" | "));
    const chips = await page.$$eval(".tt-chip", (e) => e.map((x) => x.textContent.trim()));
    ok(chips.join(",") === "To mark,Mark,Attended,Admin marks,Upcoming,Late cancellation,Cancelled,Ask an admin", tag + ": badges " + chips.join(","));
    const sum = await page.textContent("#tt-sum");
    ok(/3 lessons today/.test(sum) && /1 to mark/.test(sum), tag + ": summary \"" + sum.trim() + "\"");
    ok(errs.length === 0, tag + ": no script errors" + (errs.length ? " " + errs.join("|") : ""));
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + ": no sideways scroll");
    if (SC) await page.screenshot({ path: path.join(SC, `tutor-${vp}-${theme}.png`), fullPage: true });
    await axeCheck(page, tag + " list");
    if (vp === "phone" && theme === "light") {
      // open today's unmarked lesson: attendance choices + notes + Save
      await page.click('.tt-row[data-id="c"]'); await page.waitForTimeout(400);
      ok(await page.isVisible("#tt-sheet.on"), "sheet opens");
      ok((await page.$$(".tt-opt")).length === 2 && (await page.$$(".tt-ta")).length === 3, "attendance choices and three note boxes");
      ok(await page.isVisible("#ts-save"), "Save is offered");
      if (SC) await page.screenshot({ path: path.join(SC, "tutor-sheet-phone.png") });
      await axeCheck(page, "phone/light sheet open");
      // nothing changed → Save just closes, no call
      await page.click("#ts-save"); await page.waitForTimeout(300);
      ok(!(await page.isVisible("#tt-sheet.on")) && (await page.evaluate(() => window.__calls.filter((c) => c[0] === "tutor_mark_attendance").length)) === 0, "Save with nothing changed makes no call");
      // choose Absent + a remark → exactly those two fields are sent
      await page.click('.tt-row[data-id="c"]'); await page.click('.tt-opt[data-att="absent"]');
      ok((await page.getAttribute('.tt-opt[data-att="absent"]', "aria-pressed")) === "true" && (await page.getAttribute('.tt-opt[data-att="attended"]', "aria-pressed")) === "false", "choosing Absent un-selects Attended");
      await page.fill("#ts-remarks", "Away sick"); await page.click("#ts-save"); await page.waitForTimeout(500);
      const call = await page.evaluate(() => window.__calls.filter((c) => c[0] === "tutor_mark_attendance")[0]);
      ok(call && call[1].p_lesson === "c" && call[1].p_attendance === "absent" && call[1].p_remarks === "Away sick" && call[1].p_topics === null && call[1].p_homework === null, "only changed fields are sent: " + JSON.stringify(call && call[1]));
      // a locked lesson: no Save, a plain reason
      await page.click('.tt-row[data-id="e"]');
      ok(!(await page.$(".tt-opt")) && /admin marks attendance/.test(await page.textContent("#ts-body")), "admin-marks lesson: no attendance buttons, reason shown");
      ok((await page.$$(".tt-ta")).length === 3, "…but notes are still writable");
      await page.keyboard.press("Escape"); await page.waitForTimeout(250);
      ok(!(await page.isVisible("#tt-sheet.on")), "Escape closes the sheet");
      await page.click('.tt-row[data-id="f"]');
      ok(!(await page.isVisible("#ts-save")) && /from its day/.test(await page.textContent("#ts-body")), "future lesson: read-only, Save hidden");
    }
    await ctx.close();
  }
  // ---------- A2. the centre's own rules show up on the sheet
  { const cfg = { lessons: [["c", 0, { can_cancel: true, remarks_required: true }], ["d", 0, { can_cancel: false, remarks_required: false }]] };
    const { ctx, page } = await open(b, "phone", "light", cfg, "tutor");
    await page.click('.tt-row[data-id="c"]'); await page.waitForTimeout(300);
    const opts = await page.$$eval(".tt-opt", (e) => e.map((x) => x.textContent.trim()));
    ok(opts.join(",") === "Attended,Absent,Cancelled in time,Late cancellation", "centre lets tutors mark cancellations: four choices (" + opts.join(", ") + ")");
    ok(/required to mark attended/.test(await page.textContent("#ts-body")), "centre requires remarks: the Remarks box says so");
    await page.click('.tt-opt[data-att="late_cancelled"]'); await page.fill("#ts-remarks", "Parent called at noon"); await page.click("#ts-save"); await page.waitForTimeout(400);
    const call = await page.evaluate(() => window.__calls.filter((c) => c[0] === "tutor_mark_attendance")[0]);
    ok(call && call[1].p_attendance === "late_cancelled" && call[1].p_remarks === "Parent called at noon", "a cancellation is sent as chosen: " + JSON.stringify(call && call[1]));
    await page.click('.tt-row[data-id="d"]'); await page.waitForTimeout(300);
    const opts2 = await page.$$eval(".tt-opt", (e) => e.map((x) => x.textContent.trim()));
    ok(opts2.join(",") === "Attended,Absent" && !/required to mark attended/.test(await page.textContent("#ts-body")), "default centre: just attended / absent, remarks optional");
    await axeCheck(page, "phone/light sheet with four choices");
    if (SC) await page.screenshot({ path: path.join(SC, "tutor-sheet-four.png") });
    await ctx.close(); }
  // ---------- A2b. absent / cancelled lessons: the charge (compensation) the way the app already works, and trial lessons
  { const cfg = { lessons: [["p", 0, { tutor_sets_compensation: true, can_cancel: true, can_flag_trial: true }], ["q", 0, { tutor_sets_compensation: false }], ["r", 0, { attendance: "absent", can_mark: false, charge_pending: true }]] };
    const { ctx, page } = await open(b, "phone", "light", cfg, "tutor");
    await page.click('.tt-row[data-id="p"]'); await page.waitForTimeout(300);
    ok(!(await page.$("#ts-charge-in")), "attended is selected by default of nothing: no charge box yet");
    await page.click('.tt-opt[data-att="absent"]'); await page.waitForTimeout(200);
    ok(await page.isVisible("#ts-charge-in") && /Type 0 if the family/.test(await page.textContent("#ts-charge")), "centre has tutors type the charge: Absent shows the charge box with a 0 hint");
    await page.click('.tt-opt[data-att="attended"]'); await page.waitForTimeout(150);
    ok(!(await page.$("#ts-charge-in")), "switching back to Attended hides it");
    await page.click('.tt-opt[data-att="late_cancelled"]'); await page.waitForTimeout(150);
    ok(await page.isVisible("#ts-charge-in"), "a cancellation shows it too");
    await page.click("#ts-save"); await page.waitForTimeout(300);
    ok(/enter the charge/i.test(await page.textContent("#ts-msg")) && (await page.evaluate(() => window.__calls.filter((c) => c[0] === "tutor_mark_attendance").length)) === 0, "saving with the charge blank is refused on the screen, nothing is sent");
    await page.fill("#ts-charge-in", "abc"); await page.click("#ts-save"); await page.waitForTimeout(200);
    ok((await page.evaluate(() => window.__calls.filter((c) => c[0] === "tutor_mark_attendance").length)) === 0, "a non-number is not sent either");
    await page.check("#ts-trial"); await page.fill("#ts-charge-in", "0"); await page.click("#ts-save"); await page.waitForTimeout(400);
    const c1 = await page.evaluate(() => window.__calls.filter((c) => c[0] === "tutor_mark_attendance")[0]);
    ok(c1 && c1[1].p_attendance === "late_cancelled" && c1[1].p_compensation === 0 && c1[1].p_trial === true, "0 is sent as 0, with the trial flag: " + JSON.stringify(c1 && c1[1]));
    await axeCheck(page, "phone/light sheet with charge box + trial");
    await page.click('.tt-row[data-id="p"]'); await page.click('.tt-opt[data-att="absent"]'); await page.waitForTimeout(150);
    if (SC) await page.screenshot({ path: path.join(SC, "tutor-sheet-charge.png") });
    await page.keyboard.press("Escape"); await page.waitForTimeout(200);
    // an admin-sets-the-charge centre
    await page.click('.tt-row[data-id="q"]'); await page.click('.tt-opt[data-att="absent"]'); await page.waitForTimeout(200);
    ok(!(await page.$("#ts-charge-in")) && /An admin will decide what this lesson is charged/.test(await page.textContent("#ts-charge")), "admin-sets-the-charge centre: no box, just a plain note");
    ok(!(await page.$("#ts-trial")), "and no trial tick-box when admins flag trials");
    await page.click("#ts-save"); await page.waitForTimeout(300);
    const c2 = await page.evaluate(() => window.__calls.filter((c) => c[0] === "tutor_mark_attendance")[1]);
    ok(c2 && c2[1].p_attendance === "absent" && c2[1].p_compensation === null, "marked absent with no charge sent: " + JSON.stringify(c2 && c2[1]));
    // a lesson already absent with the charge pending
    await page.click('.tt-row[data-id="r"]'); await page.waitForTimeout(200);
    ok(/still needs to set the charge/.test(await page.textContent("#ts-body")), "pending charge: the tutor is told an admin still has to set it");
    await ctx.close(); }
  // ---------- A3. the sign-up screens offer the new options (and are honest about what is not built yet)
  { const { ctx, page } = await open(b, "desktop", "light", {}, "org");
    await page.click("text=Demo Learning Centre"); await page.waitForTimeout(900);        // open the centre being set up
    await page.click("button:has-text('Tutors and lessons')"); await page.waitForTimeout(700);   // step 7
    const txt = await page.evaluate(() => document.body.innerText);
    ok(/Tutors can mark or change attendance for/.test(txt), "setup screen: the marking-window option is offered");
    ok(/Cancellations \(in time or late\) are marked by/.test(txt), "setup screen: who marks cancellations is offered");
    ok(/Lesson remarks are required/.test(txt), "setup screen: required remarks is offered");
    ok(/charge \(compensation\) is entered by/.test(txt), "setup screen: who enters the charge for absent/cancelled lessons is offered");
    ok(/Trial lessons are flagged by/.test(txt), "setup screen: who flags trial lessons is offered");
    ok(/coming soon/i.test(txt), "setup screen: options that aren't built yet say \"coming soon\"");
    if (SC) await page.screenshot({ path: path.join(SC, "org-step-lessons.png"), fullPage: true });
    await ctx.close(); }
  // ---------- B. a refusal from the database is explained kindly and never shown raw
  { const { ctx, page } = await open(b, "phone", "light", { lessons: LESSONS, markError: "ALREADY_MARKED: someone else already marked this lesson; ask an admin to change it" }, "tutor");
    await page.click('.tt-row[data-id="c"]'); await page.click('.tt-opt[data-att="attended"]'); await page.click("#ts-save"); await page.waitForTimeout(400);
    const m = await page.textContent("#ts-msg");
    ok(/Someone else already marked/.test(m) && !/ALREADY_MARKED/.test(m), "refusal shown kindly: \"" + m.trim() + "\"");
    ok(await page.isVisible("#tt-sheet.on") && !(await page.isDisabled("#ts-save")), "sheet stays open and Save is usable again");
    await ctx.close(); }
  { const { ctx, page } = await open(b, "phone", "light", { rpcError: true }, "tutor");
    ok(/aren.t available right now/.test(await page.textContent("#tt-lists")), "if the lessons can't load: a plain message"); await ctx.close(); }
  { const { ctx, page } = await open(b, "phone", "light", { lessons: [] }, "tutor");
    ok(/No lessons are assigned to you/.test(await page.textContent("#tt-lists")), "no lessons: a friendly empty state"); await ctx.close(); }
  // ---------- C. role-based menu and Home redirect
  const centreTutor = (n) => ({ role: { memberships: [{ role: "tutor", status: "active", organisations: { kind: "centre" } }, { role: "owner", status: "active", organisations: { kind: "solo" } }], studentCount: n }, lessons: LESSONS });
  { const { ctx, page } = await open(b, "desktop", "light", centreTutor(0), "home");
    await page.waitForTimeout(800);
    ok(/\/tutor$/.test(page.url()), "tutor-only login on Home is sent to My lessons (" + page.url().replace(BASE, "/") + ")");
    const nav = await page.$$eval(".tn-links a", (e) => e.map((x) => x.textContent.trim()));
    ok(nav.join(",") === "My lessons", "tutor-only menu is just: " + nav.join(",")); 
    const tabs = await page.$$eval(".tabbar a, .tabbar button", (e) => e.map((x) => x.textContent.trim()));
    ok(tabs.join(",") === "My lessons,More", "phone bar: " + tabs.join(","));
    await ctx.close(); }
  { const { ctx, page } = await open(b, "phone", "light", centreTutor(4), "home");
    ok(/\/home$/.test(page.url()), "solo tutor who also teaches stays on Home");
    const sheet = await page.$$eval("#tl-sheet a", (e) => e.map((x) => x.textContent.trim().replace(/\s+/g, " ")));
    ok(sheet[0] === "My lessons", "…and finds My lessons in More: " + sheet.join(" | "));
    const nav = await page.$$eval(".tabbar a", (e) => e.map((x) => x.textContent.trim()));
    ok(nav.join(",") === "Home,Schedule,Students,Money", "main bar unchanged: " + nav.join(","));
    await ctx.close(); }
  for (const pg of ["home", "settings", "students", "calendar", "ledger", "exams"]) {
    const { ctx, page, errs } = await open(b, "desktop", "light", {}, pg);
    const nav = await page.$$eval(".tn-links a", (e) => e.map((x) => x.textContent.trim()));
    ok(nav.join(",") === "Home,Schedule,Students,Money" && !/\/tutor$/.test(page.url()) && errs.length === 0, "plain solo login on " + pg + ": menu and page unchanged" + (errs.length ? " ERR " + errs[0] : ""));
    await ctx.close();
  }
  await b.close();
  console.log(fails ? "\n" + fails + " FAILED" : "\nall browser checks passed"); process.exit(fails ? 1 : 0);
})();
