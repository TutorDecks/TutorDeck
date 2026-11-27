// Browser check for the tutor's Schedule page (T6 step 1: read only; step 2: Move / Put back / Cancel when the centre allows it; steps 3-4: Add a lesson, my weekly
// slots (add / change / stop) and Create lessons when the centre allows them). Not part of CI:
// needs Playwright + `python3 tests/server.py 8765`.
//   node tests/tutor-schedule.check.js [screenshot-dir]
// The database is stubbed (tutor_my_schedule / tutor_my_slots answer from the scenario); the real isolation between tutors and the
// "no money" rule are proved by tests/sql/tutor_schedule_test.sql on a real Postgres.
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
const AXE = (() => { try { return fs.readFileSync(path.join(ROOT, "tests/node_modules/axe-core/axe.min.js"), "utf8"); } catch (e) { return null; } })();
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
async function axeCheck(page, tag) {
  if (!AXE) return console.log("skip accessibility (npm install in tests/ to enable)");
  await page.evaluate(AXE);
  const v = await page.evaluate(() => axe.run(document, { runOnly: ["wcag2a", "wcag2aa", "best-practice"] }).then((r) => r.violations.filter((x) => x.impact === "serious" || x.impact === "critical").map((x) => x.id + " (" + x.nodes.length + ") e.g. " + x.nodes[0].target.join(" "))));
  ok(v.length === 0, tag + ": accessibility" + (v.length ? " " + v.join("; ") : ""));
}
const STUB_PLUS = STUB + `;(function(){var o=window.supabase.createClient;window.supabase.createClient=function(){var c=o.apply(this,arguments);if(window.__override)window.__override(c);return c;};})();`;

function override(cfg) {
  window.__calls = [];
  window.__override = function (c) {
    var iso = function (n) { var d = new Date(); d.setDate(d.getDate() + n); var p = function (x) { return (x < 10 ? "0" : "") + x; }; return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()); };
    var L = function (id, off, o) { return Object.assign({ lesson_id: id, org_id: "o2", org_name: "Test Tuition", student_id: "s" + id, student_name: "Pupil " + id, student_level: "P5", parent_contact: null,
      lesson_date: iso(off), start_time: "16:00:00", end_time: "17:00:00", minutes: 60, subject: "Math", trial: false, attendance: null, status: "scheduled", cancelled: false,
      postponed: false, covering: false, online_link: null, lesson_link: null, student_link: null, pending_request: null, holiday: null, can_postpone: false, can_revert: false, can_cancel: false, change_block: null, class_size: 0, awaiting_centre: false, added_by_you: false }, o || {}); };
    var lessons = (cfg.lessons || []).map(function (x) { return L(x[0], x[1], x[2]); });
    var origRpc = c.rpc.bind(c), origFrom = c.from.bind(c);
    c.rpc = function (n, a) {
      window.__calls.push([n, a]);
      if (n === "tutor_my_schedule") {
        if (cfg.notFound) return Promise.resolve({ data: null, error: { message: "NOT_FOUND" } });
        if (cfg.rpcError) return Promise.resolve({ data: null, error: { message: "boom" } });
        var inr = lessons.filter(function (l) { return l.lesson_date >= a.p_from && l.lesson_date <= a.p_to; }).sort(function (x, y) { return x.lesson_date < y.lesson_date ? -1 : x.lesson_date > y.lesson_date ? 1 : x.start_time < y.start_time ? -1 : 0; });
        var hol = (cfg.holidays || []).map(function (h) { return { org_id: "o2", name: h[2], starts_on: iso(h[0]), ends_on: iso(h[1]) }; }).filter(function (h) { return h.starts_on <= a.p_to && h.ends_on >= a.p_from; });
        return Promise.resolve({ data: { today: iso(0), from: a.p_from, to: a.p_to, orgs: [{ org_id: "o2", name: "Test Tuition", today: iso(0), timetable_editing: cfg.editing || "admin_only", can_edit: !!(cfg.canPostpone || cfg.canCancel), can_postpone: !!cfg.canPostpone, can_cancel: !!cfg.canCancel,
          can_one_off: !!cfg.canOneOff, proposes: !!cfg.proposes, can_link: !!cfg.canLink, requests_pending: (cfg.requests || []).filter(function (q) { return q.status === "pending"; }).length, can_slots: !!cfg.canSlots, can_generate: !!cfg.canGenerate,
          min_notice_hours: 24, max_changes_per_month: cfg.changesLeft == null ? 0 : 5, changes_left: cfg.changesLeft == null ? null : cfg.changesLeft }], lessons: inr, holidays: hol }, error: null });
      }
      if (n === "tutor_postpone_lesson" || n === "tutor_revert_lesson" || n === "tutor_cancel_lesson") {
        if (cfg.changeError) return Promise.resolve({ data: null, error: { message: cfg.changeError } });
        if (cfg.proposes) return Promise.resolve({ data: { requested: true, request_id: "rqnew", kind: "x", status: "pending" }, error: null });
        return new Promise(function (res) { setTimeout(function () { res({ data: { lesson_id: a.p_lesson, lessons: 1, what: n === "tutor_cancel_lesson" ? "cancelled" : n === "tutor_revert_lesson" ? "reverted" : "moved",
          lesson_date: a.p_date || iso(2), start_time: (a.p_start || "15:00") + ":00", end_time: "16:00:00", cancelled: n === "tutor_cancel_lesson" }, error: null }); }, 150); });
      }
      if (n === "tutor_my_slots") return Promise.resolve({ data: (cfg.slots || []).map(function (s, i) { return { slot_id: "sl" + i, org_id: "o2", org_name: "Test Tuition", weekday: s[0], start_time: s[1], end_time: s[2], subject: s[3], student_id: "x" + i, student_name: s[4], student_level: s[5], session_key: s[6] || null, timetable_editing: cfg.editing || "admin_only", can_change: !!s[7], is_group: !!s[6], awaiting_centre: !!s[8] }; }), error: null });
      if (n === "tutor_my_students") return Promise.resolve({ data: cfg.students || [], error: null });
      if (n === "tutor_add_lesson" || n === "tutor_save_slot" || n === "tutor_stop_slot" || n === "tutor_generate_lessons") {
        if (cfg.ownError) return Promise.resolve({ data: null, error: { message: cfg.ownError } });
        if (cfg.proposes) return Promise.resolve({ data: { requested: true, request_id: "rqnew", kind: "x", status: "pending" }, error: null });
        return new Promise(function (res) { setTimeout(function () { res({ error: null, data:
          n === "tutor_add_lesson" ? { lesson_id: "new1", lesson_date: a.p_date, start_time: a.p_start + ":00", end_time: a.p_end + ":00", awaiting_centre: !!cfg.awaiting }
          : n === "tutor_save_slot" ? { slot_id: a.p_slot || "slnew", added: !a.p_slot, lessons_left: a.p_slot ? 2 : 0, awaiting_centre: !!cfg.awaiting }
          : n === "tutor_stop_slot" ? { stopped: 1, lessons_left: 2 }
          : { from: a.p_from, to: a.p_to, created: 7, skipped: 3, holidays: 1, ended: 0, too_soon: 1, not_assigned: 0, awaiting_centre: cfg.awaiting ? 2 : 0, slots: 2 } }); }, 150); });
      }
      if (n === "tutor_my_requests") return cfg.requestsError ? Promise.resolve({ data: null, error: { message: "boom" } }) : Promise.resolve({ data: { today: iso(0), rows: cfg.requests || [] }, error: null });
      if (n === "tutor_set_link") {
        if (cfg.linkError) return Promise.resolve({ data: null, error: { message: cfg.linkError } });
        return Promise.resolve({ data: cfg.proposes ? { requested: true, request_id: "rqlink", kind: "link", status: "pending" } : { changed: true, scope: a.p_lesson ? "lesson" : "student", online_link: a.p_link || null }, error: null });
      }
      if (n === "tutor_cancel_request") return Promise.resolve({ data: { request_id: a.p_request, status: "cancelled", already: false }, error: null });
      if (n === "tutor_my_lessons") return Promise.resolve({ data: [], error: null });
      return origRpc(n, a);
    };
    c.from = function (t) {
      if (t === "memberships" && cfg.role) { var q = { select: function () { return q; }, eq: function () { return q; }, then: function (r, j) { return Promise.resolve({ data: cfg.role.memberships, error: null }).then(r, j); } }; return q; }
      if (t === "students" && cfg.role && cfg.role.studentCount != null) { var s = { select: function () { return s; }, then: function (r, j) { return Promise.resolve({ data: [], count: cfg.role.studentCount, error: null }).then(r, j); } }; return s; }
      return origFrom(t);
    };
  };
}
async function open(browser, vp, theme, cfg, url) {
  const ctx = await browser.newContext(vp === "phone" ? { viewport: { width: 390, height: 844 }, isMobile: true, deviceScaleFactor: 2 } : { viewport: { width: 1100, height: 900 } });
  await ctx.addInitScript((t) => { try { localStorage.setItem("td_theme", t); } catch (e) {} }, theme);
  await ctx.route(/^(?!http:\/\/127\.0\.0\.1).*/, (r) => r.abort());
  const page = await ctx.newPage(); const errs = [];
  await page.route("**/assets/vendor/supabase-2.118.0.js", (r) => r.fulfill({ body: STUB_PLUS, contentType: "application/javascript" }));
  await page.addInitScript(override, cfg);
  page.on("pageerror", (e) => errs.push(e.message));
  page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource/.test(m.text())) errs.push("console: " + m.text()); });
  await page.goto(BASE + url, { waitUntil: "load" }); await page.waitForTimeout(1300);
  return { ctx, page, errs };
}
// this week is built relative to today so the check never goes stale: offsets are days from today; the week list shows Monday-Sunday of the current week
const dow = (new Date().getDay() + 6) % 7;                  // 0 = Monday
const mon = -dow;                                           // offset of this week's Monday
const CFG = {
  lessons: [["a", mon, { start_time: "16:00:00" }], ["b", mon, { start_time: "17:30:00", student_name: "Pupil B", trial: true }], ["c", mon + 2, { cancelled: true, status: "cancelled" }],
            ["d", mon + 3, { postponed: true }], ["e", mon + 4, { covering: true, online_link: "https://meet.example.com/xyz" }], ["f", mon + 4, { attendance: "attended", start_time: "18:00:00" }],
            ["g", mon + 3, { holiday: "Teachers' Day", start_time: "10:00:00" }], ["n", mon + 8, { student_name: "Next week pupil" }]],
  holidays: [[mon + 3, mon + 3, "Teachers' Day"], [mon + 5, mon + 5, "Founders' Day"]],
  slots: [[1, "15:00:00", "16:00:00", "Maths", "Aiden", "P5"], [3, "17:00:00", "18:00:00", "Science", "Bea", "P6"]]
};
const MONEY = /(S\$|\$\s?\d|\bprice\b|\brate\b|\bpaid\b|\bamount\b|\bcompensation\b|\bcharge\b|\bfee\b)/i;

(async () => {
  const b = await chromium.launch();
  // ---------- A. the page, both sizes, light + dark
  for (const [vp, theme] of [["desktop", "light"], ["phone", "light"], ["phone", "dark"]]) {
    const { ctx, page, errs } = await open(b, vp, theme, CFG, "tutor-schedule");
    const tag = vp + "/" + theme;
    ok((await page.textContent("#sc-title")).startsWith("This week"), tag + ": titled 'This week'");
    const days = await page.$$eval(".tt-day", (e) => e.map((x) => x.textContent.trim()));
    ok(days.length === 5 && /Teachers' Day · holiday/.test(days.join("|")) && /Founders' Day · holiday/.test(days.join("|")), tag + ": days with lessons or a holiday: " + days.join(" | "));
    ok((await page.$$(".tt-day.hol")).length >= 2, tag + ": holidays are a grey band (even a day with no lessons)");
    const rows = await page.$$eval(".tt-row .tt-name", (e) => e.map((x) => x.textContent.trim()));
    ok(rows.length === 7 && !rows.includes("Next week pupil"), tag + ": the week shows its 7 lessons, not next week's (" + rows.length + ")");
    const chips = await page.$$eval(".tt-chip", (e) => e.map((x) => x.textContent.trim()));
    ok(["Trial", "Cancelled", "Moved", "Covering", "Attended"].every((c) => chips.includes(c)), tag + ": flags shown as badges (" + chips.join(",") + ")");
    ok(/Your centre handles changes: ask an admin\./.test(await page.textContent("#sc-note")) && !(await page.$("#sc-note[hidden]")), tag + ": the 'ask an admin' note is shown");
    ok((await page.$$("[data-page='tutor-schedule'] button:not([hidden]):not(.tt-row):not(.sc-nav):not(.owe-x)")).length === 0 && (await page.$$("[data-page='tutor-schedule'] input, [data-page='tutor-schedule'] textarea, [data-page='tutor-schedule'] select")).length === 0, tag + ": no edit buttons or fields anywhere");
    ok(/Maths/.test(await page.textContent("#sc-slots")) && /Aiden/.test(await page.textContent("#sc-slots")) && /Science/.test(await page.textContent("#sc-slots")), tag + ": my weekly slots are listed");
    ok(!MONEY.test(await page.evaluate(() => document.body.innerText)), tag + ": no price, rate or money word on the page");
    ok(errs.length === 0, tag + ": no script or console errors" + (errs.length ? " " + errs.join("|") : ""));
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + ": no sideways scroll");
    if (SC) await page.screenshot({ path: path.join(SC, `tutor-schedule-${vp}-${theme}.png`), fullPage: true });
    await axeCheck(page, tag + " list");
    if (vp === "phone") {
      await page.click('.tt-row[data-id="e"]'); await page.waitForTimeout(400);
      const sheet = await page.textContent("#ts-body");
      ok(await page.isVisible("#tt-sheet.on") && /covering this lesson for another tutor/.test(sheet) && /Join the lesson/.test(sheet) && /ask an admin/.test(sheet), tag + ": the sheet shows the facts, the online link and the note");
      ok(!(await page.$("#ts-save")) && (await page.$$("#ts-body input, #ts-body textarea, #ts-body select, #ts-body button")).length === 0, tag + ": the sheet has no way to change anything");
      ok(!MONEY.test(await page.textContent("#tt-sheet")), tag + ": no money word in the sheet");
      if (SC) await page.screenshot({ path: path.join(SC, `tutor-schedule-sheet-${theme}.png`) });
      await axeCheck(page, tag + " sheet open");
      await page.keyboard.press("Escape"); await page.waitForTimeout(250);
      ok(!(await page.isVisible("#tt-sheet.on")), tag + ": Escape closes the sheet");
      await page.click('.tt-row[data-id="g"]'); await page.waitForTimeout(250);
      ok(/Teachers' Day/.test(await page.textContent("#ts-body")), tag + ": a lesson on a holiday says so in its sheet");
    }
    await ctx.close();
  }
  // ---------- B. week navigation asks for the right 7 days
  { const { ctx, page } = await open(b, "phone", "light", CFG, "tutor-schedule");
    await page.click("#sc-next"); await page.waitForTimeout(500);
    ok((await page.textContent("#sc-title")).startsWith("Next week") && /Next week pupil/.test(await page.textContent("#sc-week")), "next week shows next week's lesson");
    const calls = await page.evaluate(() => window.__calls.filter((c) => c[0] === "tutor_my_schedule").map((c) => c[1]));
    ok(calls.length === 2 && calls[1].p_from > calls[0].p_from && calls[1].p_to > calls[0].p_to, "and asks for the following seven days: " + JSON.stringify(calls[1]));
    await page.click("#sc-prev"); await page.click("#sc-prev"); await page.waitForTimeout(500);
    ok((await page.textContent("#sc-title")).startsWith("Last week") && /No lessons this week/.test(await page.textContent("#sc-week")), "last week: a friendly empty state");
    await page.click("#sc-today"); await page.waitForTimeout(500);
    ok((await page.textContent("#sc-title")).startsWith("This week"), "Today goes back to this week");
    await ctx.close(); }
  // ---------- C. a centre where tutors ask, with nothing switched on: a plain note, still read-only
  { const { ctx, page } = await open(b, "phone", "light", Object.assign({}, CFG, { editing: "tutors_propose", proposes: true }), "tutor-schedule");
    ok(/not switched on requests/.test(await page.textContent("#sc-note")) && !/coming soon/.test(await page.textContent("#sc-note")) && (await page.$$("[data-page='tutor-schedule'] input, [data-page='tutor-schedule'] textarea, [data-page='tutor-schedule'] select")).length === 0, "a centre where tutors ask but nothing is switched on: a plain note (never 'coming soon'), still read-only");
    ok(/You have not asked for anything yet/.test(await page.textContent("#sc-reqs")) && !(await page.$("#sc-reqs-h[hidden]")), "and the My requests list says nothing has been asked yet"); await ctx.close(); }
  // ---------- F. T6 step 2: a centre that lets its tutors change lessons (tutors_direct)
  const DIRECT = Object.assign({}, CFG, { editing: "tutors_direct", canPostpone: true, canCancel: true, changesLeft: 2,
    lessons: [["a", mon + 8, { start_time: "16:00:00", can_postpone: true, can_cancel: true }], ["r", mon + 8, { start_time: "18:00:00", postponed: true, can_postpone: true, can_revert: true, can_cancel: true, student_name: "Moved pupil" }],
              ["k", mon + 9, { start_time: "16:00:00", can_postpone: true, can_cancel: true, class_size: 3, student_name: "Class pupil" }],
              ["t", mon + 8, { start_time: "19:00:00", change_block: "TOO_LATE", student_name: "Soon pupil" }], ["m", mon + 9, { start_time: "10:00:00", attendance: "attended", change_block: "ALREADY_MARKED", student_name: "Marked pupil" }]] });
  const goNext = async (page) => { await page.click("#sc-next"); await page.waitForTimeout(500); };
  for (const theme of ["light", "dark"]) {
    const { ctx, page, errs } = await open(b, "phone", theme, DIRECT, "tutor-schedule"); await goNext(page);
    const tag = "direct/" + theme;
    ok(/move or cancel your own lessons/.test(await page.textContent("#sc-note")) && /at least 24 hours/.test(await page.textContent("#sc-note")) && /2 more changes this month/.test(await page.textContent("#sc-note")), tag + ": the note says what a tutor can do, the notice and the changes left");
    await page.click('.tt-row[data-id="a"]'); await page.waitForTimeout(350);
    const acts = await page.$$eval("#ts-actions [data-act]", (e) => e.map((x) => x.textContent.trim()));
    ok(acts.join("|") === "Move|Cancel lesson", tag + ": an ordinary lesson offers Move and Cancel lesson (" + acts.join("|") + ")");
    ok(!MONEY.test(await page.textContent("#tt-sheet")), tag + ": no money word in the sheet");
    if (SC) await page.screenshot({ path: path.join(SC, `tutor-schedule-direct-sheet-${theme}.png`) });
    await axeCheck(page, tag + " sheet");
    await page.click('#ts-actions [data-act="move"]'); await page.waitForTimeout(250);
    ok(await page.isVisible("#ts-date") && await page.isVisible("#ts-start") && await page.isVisible("#ts-reason") && /stays 60 minutes: it will end at 5:00 pm/.test(await page.textContent("#ts-end")), tag + ": the move form asks a day, a start time and why; the end is worked out (the length never changes)");
    ok((await page.$$eval("#ts-body input, #ts-body textarea", (e) => e.map((x) => x.id))).join(",") === "ts-date,ts-start,ts-reason", tag + ": only those three fields (no end time, no price)");
    await page.fill("#ts-start", "23:30"); ok(/run past midnight/.test(await page.textContent("#ts-end")), tag + ": a start that would pass midnight is called out");
    await page.fill("#ts-start", "17:00"); ok(/end at 6:00 pm/.test(await page.textContent("#ts-end")), tag + ": and the end follows the start");
    await page.click("#ts-go"); await page.waitForTimeout(150);
    ok(/say why/.test(await page.textContent("#ts-msg")) && (await page.evaluate(() => window.__calls.filter((c) => /tutor_(postpone|cancel|revert)_lesson/.test(c[0])).length)) === 0, tag + ": no reason: a plain message, nothing sent");
    if (SC) await page.screenshot({ path: path.join(SC, `tutor-schedule-direct-form-${theme}.png`) });
    await axeCheck(page, tag + " form");
    await page.fill("#ts-reason", "Student has a school event");
    await page.evaluate(() => { var b = document.getElementById("ts-go"); b.click(); b.click(); });           // a double press (the second click lands on a disabled button, as a fast thumb would)
    await page.waitForTimeout(700);
    const calls = await page.evaluate(() => window.__calls.filter((c) => /tutor_postpone_lesson/.test(c[0])));
    ok(calls.length === 1 && calls[0][1].p_lesson === "a" && calls[0][1].p_start === "17:00" && calls[0][1].p_reason === "Student has a school event" && /^\d{4}-\d\d-\d\d$/.test(calls[0][1].p_date), tag + ": ONE request for a double press, with the lesson, day, start and reason: " + JSON.stringify(calls[0] && calls[0][1]));
    ok(!(await page.isVisible("#tt-sheet.on")) && /Moved to/.test(await page.textContent("#td-toast")), tag + ": the sheet closes and a toast says what happened");
    ok((await page.evaluate(() => window.__calls.filter((c) => c[0] === "tutor_my_schedule").length)) >= 3, tag + ": the week is read again afterwards");
    ok(!/Cancel lesson|\bMove\b/.test(await page.evaluate(() => document.querySelector("#sc-week").innerText)) && errs.length === 0, tag + ": no script errors" + (errs.length ? " " + errs.join("|") : ""));
    await ctx.close();
  }
  { const { ctx, page } = await open(b, "phone", "light", DIRECT, "tutor-schedule"); await goNext(page);
    await page.click('.tt-row[data-id="r"]'); await page.waitForTimeout(300);
    ok((await page.$$eval("#ts-actions [data-act]", (e) => e.map((x) => x.textContent.trim()))).join("|") === "Move|Put back to usual time|Cancel lesson", "a moved lesson also offers 'Put back to usual time'");
    await page.click('#ts-actions [data-act="revert"]'); await page.waitForTimeout(200);
    ok((await page.$$("#ts-body input")).length === 0 && /usual day and time|normally has/.test(await page.textContent("#ts-body")), "put back: no date to pick, only why");
    await page.fill("#ts-reason", "Parent changed their mind"); await page.click("#ts-go"); await page.waitForTimeout(500);
    const c = await page.evaluate(() => window.__calls.filter((x) => x[0] === "tutor_revert_lesson").map((x) => x[1]));
    ok(c.length === 1 && c[0].p_lesson === "r" && c[0].p_reason === "Parent changed their mind" && /Put back to/.test(await page.textContent("#td-toast")), "put back sends the lesson and the reason, and says what happened");
    await ctx.close(); }
  { const { ctx, page } = await open(b, "phone", "light", DIRECT, "tutor-schedule"); await goNext(page);
    await page.click('.tt-row[data-id="k"]'); await page.waitForTimeout(300);
    ok(/part of a class of 3/.test(await page.textContent("#ts-body")), "a lesson in a class says a change changes the whole class");
    await page.click('#ts-actions [data-act="cancel"]'); await page.waitForTimeout(200);
    ok(/not charged/.test(await page.textContent("#ts-body")) && /Your centre is told/.test(await page.textContent("#ts-body")) && /whole class of 3/.test(await page.textContent("#ts-body")), "cancel: says the family isn't charged, the centre is told, and it is the whole class");
    ok((await page.$$("#ts-body input")).length === 0 && /btn-danger/.test(await page.getAttribute("#ts-go", "class")), "cancel: only why, and the red button");
    await page.fill("#ts-reason", "I am unwell"); await page.click("#ts-go"); await page.waitForTimeout(500);
    const c = await page.evaluate(() => window.__calls.filter((x) => x[0] === "tutor_cancel_lesson").map((x) => x[1]));
    ok(c.length === 1 && c[0].p_lesson === "k" && /Lesson cancelled/.test(await page.textContent("#td-toast")) && !MONEY.test(await page.textContent("#td-toast")), "cancel sends the lesson and the reason; the toast has no money in it");
    await ctx.close(); }
  { const { ctx, page } = await open(b, "phone", "light", DIRECT, "tutor-schedule"); await goNext(page);
    await page.click('.tt-row[data-id="t"]'); await page.waitForTimeout(300);
    ok((await page.$$("#ts-actions")).length === 0 && /less than 24 hours, so only an admin can change it/.test(await page.textContent("#ts-body")), "a lesson inside the notice: no buttons, and it says why");
    await page.keyboard.press("Escape"); await page.waitForTimeout(250);
    await page.click('.tt-row[data-id="m"]'); await page.waitForTimeout(300);
    ok((await page.$$("#ts-actions")).length === 0 && /already marked/.test(await page.textContent("#ts-body")), "a marked lesson: no buttons, and it says why");
    await ctx.close(); }
  for (const [err, want] of [["TOO_LATE: a lesson can only be changed 24 hours or more before it starts. Ask an admin", /24 hours or more before it starts/], ["CLASH: you already teach Kid Four at that time. Pick another time", /already teach Kid Four/], ["boom", /couldn't change that just now/], ["HOLIDAY: Founders' Day is a holiday at this centre. Pick another day", /Founders' Day is a holiday/]]) {
    const { ctx, page } = await open(b, "phone", "light", Object.assign({}, DIRECT, { changeError: err }), "tutor-schedule"); await goNext(page);
    await page.click('.tt-row[data-id="a"]'); await page.waitForTimeout(250); await page.click('#ts-actions [data-act="move"]'); await page.waitForTimeout(200);
    await page.fill("#ts-reason", "Because"); await page.click("#ts-go"); await page.waitForTimeout(500);
    const t = await page.textContent("#ts-msg");
    ok(want.test(t) && !/boom|[A-Z]{3,}_[A-Z]+/.test(t) && (await page.isVisible("#tt-sheet.on")) && !(await page.$eval("#ts-go", (e) => e.disabled)), "a refusal (" + err.split(":")[0] + ") is shown in plain words, the sheet stays open and the button works again: " + t);
    await page.click("#ts-back"); await page.waitForTimeout(200);
    ok(/Length/.test(await page.textContent("#ts-body")), "Back returns to the lesson");
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), "no sideways scroll with the sheet open");
    await ctx.close(); }
  // switches: only Move on
  { const { ctx, page } = await open(b, "phone", "light", Object.assign({}, DIRECT, { canCancel: false, lessons: [["a", mon + 8, { can_postpone: true, can_cancel: false }]] }), "tutor-schedule"); await goNext(page);
    ok(/You can move your own lessons/.test(await page.textContent("#sc-note")) && !/cancel/.test(await page.textContent("#sc-note")), "with only 'move' switched on the note says only that");
    await page.click('.tt-row[data-id="a"]'); await page.waitForTimeout(250);
    ok((await page.$$eval("#ts-actions [data-act]", (e) => e.map((x) => x.textContent.trim()))).join("|") === "Move", "and only Move is offered");
    await ctx.close(); }
  // ---------- G. T6 steps 3-4: add a lesson, my weekly slots, Create lessons
  const STU = [{ org_id: "o2", org_name: "Test Tuition", student_id: "st1", name: "Aiden", level: "P5", subject: "Maths", awaiting_centre: false },
               { org_id: "o2", org_name: "Test Tuition", student_id: "st2", name: "Bea", level: "P6", subject: "", awaiting_centre: true }];
  const OWN = Object.assign({}, CFG, { editing: "tutors_direct", canPostpone: true, canOneOff: true, canSlots: true, canGenerate: true, students: STU,
    slots: [[1, "15:00:00", "16:00:00", "Maths", "Aiden", "P5", null, true, false], [3, "17:00:00", "18:00:00", "Science", "Bea", "P6", null, true, true], [6, "10:00:00", "11:00:00", "Maths", "Group pupil", "S1", "gk", false, false]] });
  const callsOf = (page, n) => page.evaluate((nn) => window.__calls.filter((c) => c[0] === nn).map((c) => c[1]), n);
  const MONEYW = /(S\$|\$\s?\d|\bprice\b|\brate\b|\bpaid\b|\bamount\b|\bcompensation\b|\bcharge\b|\bfee\b|\bcost\b|\binvoice)/i;
  for (const theme of ["light", "dark"]) {
    const { ctx, page, errs } = await open(b, "phone", theme, OWN, "tutor-schedule"); const tag = "own/" + theme;
    ok(await page.isVisible("#sc-add") && await page.isVisible("#sc-add-slot") && await page.isVisible("#sc-generate"), tag + ": the three buttons are shown when the centre has switched them on");
    ok(/add a one-off lesson/.test(await page.textContent("#sc-note")) && /weekly slots/.test(await page.textContent("#sc-note")), tag + ": the note says so");
    const slotRows = await page.$$eval("#sc-slots .sc-tap, #sc-slots .sc-row", (e) => e.map((x) => x.tagName + ":" + x.textContent.replace(/\s+/g, " ").trim()));
    ok(slotRows.length === 3 && slotRows.filter((x) => /^BUTTON/.test(x)).length === 2 && /^DIV:.*Group class/.test(slotRows[2]) && /To confirm/.test(slotRows[1]), tag + ": my own slots are buttons, a group class is a plain row, a slot the centre must confirm says 'To confirm' (" + slotRows.join(" | ") + ")");
    // --- add a lesson
    await page.click("#sc-add"); await page.waitForTimeout(250);
    const ids = await page.$$eval("#ts-body input, #ts-body select, #ts-body textarea", (e) => e.map((x) => x.id));
    ok(ids.join(",") === "ad-stu,ad-date,ad-start,ad-end,ad-subj,ad-note", tag + ": the add form asks only student, day, times, subject, note (" + ids.join(",") + ")");
    ok(!MONEYW.test(await page.textContent("#tt-sheet")), tag + ": no money word in the add form");
    await page.click("#ts-do"); await page.waitForTimeout(100);
    ok(/choose a student/.test(await page.textContent("#ts-msg")) && (await callsOf(page, "tutor_add_lesson")).length === 0, tag + ": nothing chosen: a plain message and nothing is sent");
    await page.selectOption("#ad-stu", "st2"); await page.waitForTimeout(100);
    ok(/Your centre will confirm the details of this one/.test(await page.textContent("#ad-hint")) && /at least 24 hours/.test(await page.textContent("#ad-hint")), tag + ": a student with nothing to copy: the hint says the centre will confirm; the notice is stated");
    await page.selectOption("#ad-stu", "st1"); await page.waitForTimeout(100);
    ok(!/will confirm/.test(await page.textContent("#ad-hint")) && (await page.getAttribute("#ad-subj", "placeholder")) === "Maths", tag + ": a student with a usual subject: no such hint, the subject is suggested");
    await page.fill("#ad-start", "16:00"); ok((await page.inputValue("#ad-end")) === "17:00", tag + ": the end time follows the start (an hour)");
    await page.fill("#ad-end", "15:00"); await page.click("#ts-do"); await page.waitForTimeout(100);
    ok(/end after it starts/.test(await page.textContent("#ts-msg")) && (await callsOf(page, "tutor_add_lesson")).length === 0, tag + ": an end before the start is caught on the screen");
    if (SC) await page.screenshot({ path: path.join(SC, `tutor-schedule-own-add-${theme}.png`) });
    await axeCheck(page, tag + " add form");
    await page.fill("#ad-end", "17:00"); await page.fill("#ad-note", "extra revision");
    await page.evaluate(() => { var b = document.getElementById("ts-do"); b.click(); b.click(); }); await page.waitForTimeout(700);
    const ac = await callsOf(page, "tutor_add_lesson");
    ok(ac.length === 1 && Object.keys(ac[0]).join(",") === "p_student,p_date,p_start,p_end,p_subject,p_note" && ac[0].p_student === "st1" && ac[0].p_start === "16:00" && ac[0].p_end === "17:00" && ac[0].p_note === "extra revision" && ac[0].p_subject === null,
       tag + ": ONE request for a double press, with exactly the function's arguments and nothing money-like: " + JSON.stringify(ac[0]));
    ok(!(await page.isVisible("#tt-sheet.on")) && /Lesson added/.test(await page.textContent("#td-toast")) && !MONEYW.test(await page.textContent("#td-toast")), tag + ": the sheet closes and the toast says the lesson was added");
    ok((await page.evaluate(() => window.__calls.filter((c) => c[0] === "tutor_my_schedule").length)) >= 2, tag + ": the week is read again");
    // --- a refusal in plain words
    await ctx.close();
    const e1 = await open(b, "phone", theme, Object.assign({}, OWN, { ownError: "ALREADY_THERE: Aiden already has a lesson at that time" }), "tutor-schedule");
    await e1.page.click("#sc-add"); await e1.page.waitForTimeout(250); await e1.page.selectOption("#ad-stu", "st1"); await e1.page.fill("#ad-start", "16:00"); await e1.page.click("#ts-do"); await e1.page.waitForTimeout(500);
    ok(/Aiden already has a lesson at that time\./.test(await e1.page.textContent("#ts-msg")) && (await e1.page.isVisible("#tt-sheet.on")) && !(await e1.page.$eval("#ts-do", (x) => x.disabled)), tag + ": a refusal is shown in plain words, the sheet stays open, the button works again");
    await e1.ctx.close();
    const e2 = await open(b, "phone", theme, Object.assign({}, OWN, { ownError: "boom" }), "tutor-schedule");
    await e2.page.click("#sc-add"); await e2.page.waitForTimeout(250); await e2.page.selectOption("#ad-stu", "st1"); await e2.page.fill("#ad-start", "16:00"); await e2.page.click("#ts-do"); await e2.page.waitForTimeout(500);
    ok(/couldn't save that just now/.test(await e2.page.textContent("#ts-msg")) && !/boom/.test(await e2.page.textContent("#ts-msg")), tag + ": an unknown error is never shown raw");
    await e2.ctx.close();
    // --- weekly slots
    const s = await open(b, "phone", theme, Object.assign({}, OWN, { awaiting: true }), "tutor-schedule");
    await s.page.click('.sc-tap[data-slot="sl0"]'); await s.page.waitForTimeout(250);
    ok(/Every[\s\S]*Tuesday/.test(await s.page.textContent("#ts-body")) && (await s.page.$$eval("#ts-body [data-do]", (e) => e.map((x) => x.textContent.trim()))).join("|") === "Change|Stop", tag + ": a slot sheet offers Change and Stop");
    await s.page.click('[data-do="slot-edit"]'); await s.page.waitForTimeout(250);
    const sid = await s.page.$$eval("#ts-body input, #ts-body select, #ts-body textarea", (e) => e.map((x) => x.id));
    ok(sid.join(",") === "sl-wd,sl-start,sl-end,sl-subj" && (await s.page.inputValue("#sl-wd")) === "1" && (await s.page.inputValue("#sl-start")) === "15:00" && /Aiden/.test(await s.page.textContent("#ts-body")), tag + ": the change form: day, times, subject filled in; the student is shown, not editable (" + sid.join(",") + ")");
    if (SC) await s.page.screenshot({ path: path.join(SC, `tutor-schedule-own-slot-${theme}.png`) });
    await axeCheck(s.page, tag + " slot form");
    await s.page.selectOption("#sl-wd", "2"); await s.page.fill("#sl-start", "16:00"); await s.page.fill("#sl-end", "17:00"); await s.page.click("#ts-do"); await s.page.waitForTimeout(600);
    const sc = await callsOf(s.page, "tutor_save_slot");
    ok(sc.length === 1 && JSON.stringify(sc[0]) === JSON.stringify({ p_slot: "sl0", p_student: null, p_weekday: 2, p_start: "16:00", p_end: "17:00", p_subject: "Maths" }) && /Weekly slot changed/.test(await s.page.textContent("#td-toast")) && /2 coming lessons stay as they are/.test(await s.page.textContent("#td-toast")),
       tag + ": a change sends the slot id and no student: " + JSON.stringify(sc[0]));
    await s.page.click('.sc-tap[data-slot="sl0"]'); await s.page.waitForTimeout(200); await s.page.click('[data-do="slot-stop"]'); await s.page.waitForTimeout(200);
    ok(/Stop this weekly slot\?/.test(await s.page.textContent("#ts-title")) && /Lessons already made stay/.test(await s.page.textContent("#ts-body")) && /btn-danger/.test(await s.page.getAttribute("#ts-do", "class")), tag + ": stopping asks first, says lessons already made stay, and is the red button");
    await s.page.click('[data-do="slot-back"]'); await s.page.waitForTimeout(200);
    ok(/Change this weekly slot/.test(await s.page.textContent("#ts-title")), tag + ": Back returns to the slot");
    await s.page.click('[data-do="slot-stop"]'); await s.page.waitForTimeout(150); await s.page.evaluate(() => { var b = document.getElementById("ts-do"); b.click(); b.click(); }); await s.page.waitForTimeout(600);
    const st = await callsOf(s.page, "tutor_stop_slot");
    ok(st.length === 1 && st[0].p_slot === "sl0" && /Weekly slot stopped/.test(await s.page.textContent("#td-toast")), tag + ": stop sends the slot once (a double press too)");
    await s.page.click("#sc-add-slot"); await s.page.waitForTimeout(300);
    ok((await s.page.$$eval("#ts-body input, #ts-body select, #ts-body textarea", (e) => e.map((x) => x.id))).join(",") === "sl-stu,sl-wd,sl-start,sl-end,sl-subj", tag + ": the add-slot form also asks for the student");
    await s.page.click("#ts-do"); await s.page.waitForTimeout(100);
    ok(/choose a student/.test(await s.page.textContent("#ts-msg")), tag + ": nothing chosen: a plain message");
    await s.page.selectOption("#sl-stu", "st2"); await s.page.selectOption("#sl-wd", "4"); await s.page.fill("#sl-start", "09:00"); await s.page.fill("#sl-end", "10:00"); await s.page.click("#ts-do"); await s.page.waitForTimeout(600);
    const sa = (await callsOf(s.page, "tutor_save_slot")).filter((x) => !x.p_slot);
    ok(sa.length === 1 && sa[0].p_student === "st2" && sa[0].p_weekday === 4 && /Weekly slot added/.test(await s.page.textContent("#td-toast")) && /will confirm the details/.test(await s.page.textContent("#td-toast")), tag + ": adding a slot sends the student; the toast says the centre will confirm when it must");
    ok(s.errs.length === 0, tag + ": no script errors" + (s.errs.length ? " " + s.errs.join("|") : ""));
    await s.ctx.close();
    // --- Create lessons
    const g = await open(b, "phone", theme, Object.assign({}, OWN, { awaiting: true }), "tutor-schedule");
    await g.page.click("#sc-generate"); await g.page.waitForTimeout(250);
    ok((await g.page.$$eval("#ts-body input, #ts-body select", (e) => e.map((x) => x.id))).join(",") === "gn-to" && /62 days/.test(await g.page.textContent("#ts-body")) && /never makes the same lesson twice/.test(await g.page.textContent("#ts-body")), tag + ": Create lessons asks only for the last day and explains itself");
    ok((await g.page.getAttribute("#gn-to", "min")) < (await g.page.getAttribute("#gn-to", "max")) && (await g.page.inputValue("#gn-to")) > (await g.page.getAttribute("#gn-to", "min")), tag + ": the last day starts at four weeks, between today and 62 days");
    if (SC) await g.page.screenshot({ path: path.join(SC, `tutor-schedule-own-generate-${theme}.png`) });
    await axeCheck(g.page, tag + " generate form");
    await g.page.fill("#gn-to", "2000-01-01"); await g.page.click("#ts-do"); await g.page.waitForTimeout(100);
    ok(/can't be in the past/.test(await g.page.textContent("#ts-msg")) && (await callsOf(g.page, "tutor_generate_lessons")).length === 0, tag + ": a last day in the past is caught on the screen");
    await g.page.fill("#gn-to", await g.page.getAttribute("#gn-to", "max")); await g.page.evaluate(() => { var b = document.getElementById("ts-do"); b.click(); b.click(); }); await g.page.waitForTimeout(700);
    const gc = await callsOf(g.page, "tutor_generate_lessons");
    ok(gc.length === 1 && Object.keys(gc[0]).join(",") === "p_org,p_from,p_to" && gc[0].p_org === "o2", tag + ": ONE request, org / from / to only: " + JSON.stringify(gc[0]));
    const said = await g.page.textContent("#ts-body");
    ok(/7 new lessons created\./.test(said) && /3 were already there/.test(said) && /1 holiday day was skipped/.test(said) && /will confirm the details of 2 of them/.test(said) && !MONEYW.test(said), tag + ": the result is said in plain words, with no money word: " + said.trim());
    await g.page.click('[data-do="close"]'); await g.page.waitForTimeout(250);
    ok(!(await g.page.isVisible("#tt-sheet.on")) && (await g.page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)), tag + ": Done closes the sheet; no sideways scroll");
    await g.ctx.close();
  }
  // only some switches on / none / nothing to pick
  { const { ctx, page } = await open(b, "phone", "light", Object.assign({}, OWN, { canSlots: false, canGenerate: false }), "tutor-schedule");
    ok(await page.isVisible("#sc-add") && !(await page.isVisible("#sc-add-slot")) && !(await page.isVisible("#sc-generate")) && !(await page.isVisible("#sc-slot-acts")), "only one_off on: only 'Add a lesson' is shown");
    ok((await page.$$("#sc-slots .sc-tap")).length === 2, "...slots are still tappable because the database says can_change"); await ctx.close(); }
  { const { ctx, page } = await open(b, "phone", "light", Object.assign({}, OWN, { canOneOff: false, canSlots: false, canGenerate: false, slots: [[1, "15:00:00", "16:00:00", "Maths", "Aiden", "P5", null, false, false]] }), "tutor-schedule");
    ok(!(await page.isVisible("#sc-add")) && !(await page.isVisible("#sc-slot-acts")) && (await page.$$("#sc-slots .sc-tap")).length === 0, "no new switch on: no new button, no tappable slot"); await ctx.close(); }
  { const { ctx, page } = await open(b, "phone", "light", Object.assign({}, OWN, { students: [] }), "tutor-schedule");
    await page.click("#sc-add"); await page.waitForTimeout(250);
    ok(/No students are assigned to you yet/.test(await page.textContent("#ts-body")) && (await page.$$("#ts-body input")).length === 0, "no assigned students: a plain message instead of an empty form"); await ctx.close(); }
  { const { ctx, page } = await open(b, "desktop", "light", OWN, "tutor-schedule");
    ok(await page.isVisible("#sc-add") && (await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)), "desktop: the buttons show, no sideways scroll");
    await page.click("#sc-add"); await page.waitForTimeout(300); ok(await page.isVisible("#ad-stu"), "desktop: the form opens in the side panel"); await ctx.close(); }
  // ---------- H. T6 steps 5-6: a centre where tutors ASK (tutors_propose), and the online link
  const ago = (n) => { const d = new Date(); d.setDate(d.getDate() + n); return d.toISOString(); };
  const PROPOSE = Object.assign({}, CFG, { editing: "tutors_propose", proposes: true, canPostpone: true, canCancel: true, canOneOff: true, canSlots: true, canGenerate: true, canLink: true, changesLeft: 2,
    students: [{ org_id: "o2", org_name: "Test Tuition", student_id: "st1", name: "Aiden", level: "P5", subject: "Maths", awaiting_centre: false, online_link: null }],
    lessons: [["a", mon + 8, { start_time: "16:00:00", can_postpone: true, can_cancel: true }],
              ["w", mon + 8, { start_time: "18:00:00", can_postpone: true, can_cancel: true, student_name: "Waiting pupil", pending_request: { request_id: "rq-wait", kind: "cancel" } }],
              ["x", mon + 9, { start_time: "16:00:00", cancelled: true, status: "cancelled", student_name: "Cancelled pupil" }]],
    requests: [
      { request_id: "rq-wait", org_id: "o2", org_name: "Test Tuition", kind: "cancel", status: "pending", created_at: ago(-2), expires_at: ago(12), reason: "Family trip", student_name: "Waiting pupil", lesson_id: "w", lesson_date: new Date(Date.now() + (mon + 8) * 864e5).toISOString().slice(0, 10), start_time: "18:00:00", end_time: "19:00:00" },
      { request_id: "rq-dec", org_id: "o2", org_name: "Test Tuition", kind: "postpone", status: "declined", created_at: ago(-6), expires_at: ago(8), decided_at: ago(-5), reason: "Need a free evening", decision_reason: "We need that lesson to go ahead", student_name: "Declined pupil", new_date: "2030-01-04", new_start: "17:00:00" },
      { request_id: "rq-nlp", org_id: "o2", org_name: "Test Tuition", kind: "add_lesson", status: "no_longer_possible", created_at: ago(-9), decided_at: ago(-8), decision_reason: "It is now too close to the lesson: your centre's notice time has passed", student_name: "Late pupil", new_date: "2030-01-05", new_start: "14:00:00", new_end: "15:00:00" },
      { request_id: "rq-ok", org_id: "o2", org_name: "Test Tuition", kind: "link", status: "approved", created_at: ago(-4), decided_at: ago(-3), student_name: "Linked pupil", link: "https://meet.example.com/ok", link_scope: "student" }] });
  for (const theme of ["light", "dark"]) {
    const { ctx, page, errs } = await open(b, "phone", theme, PROPOSE, "tutor-schedule"); await goNext(page);
    const tag = "propose/" + theme;
    const note = await page.textContent("#sc-note");
    ok(/you ask and an admin approves: nothing changes until they do/.test(note) && /ask to move or cancel/.test(note) && /set the online link/.test(note) && /2 more changes this month \(waiting requests count\)/.test(note), tag + ": the note explains asking: " + note.slice(0, 90) + "…");
    const chips = await page.$$eval(".tt-chip", (e) => e.map((x) => x.textContent.trim()));
    ok(chips.includes("Waiting for approval") && chips.includes("Cancelled"), tag + ": a lesson with a waiting request shows 'Waiting for approval' (" + chips.join(",") + ")");
    ok(!(await page.$("#sc-reqs-h[hidden]")) && (await page.$$("#sc-reqs .sc-tap")).length === 4, tag + ": My requests lists the four requests");
    const reqText = await page.textContent("#sc-reqs");
    ok(/Waiting for an admin/.test(reqText) && /Declined/.test(reqText) && /No longer possible/.test(reqText) && /Approved/.test(reqText) && /Runs out in/.test(reqText), tag + ": each request has its status in plain words");
    ok(!MONEY.test(await page.evaluate(() => document.body.innerText)), tag + ": no money word anywhere on the page");
    // a lesson you can ask about
    await page.click('.tt-row[data-id="a"]'); await page.waitForTimeout(300);
    let body = await page.textContent("#ts-body");
    ok(/Ask to move/.test(body) && /Ask to cancel lesson/.test(body) && /Ask to set the link of this lesson/.test(body) && /Ask to set Pupil a.s usual link/.test(body), tag + ": the buttons say 'Ask to …'");
    await page.click('[data-act="move"]'); await page.waitForTimeout(250);
    body = await page.textContent("#ts-body");
    ok(/Ask to move this lesson/.test(body) && /Nothing changes until they approve it/.test(body) && /Send request/.test(body), tag + ": the form says it is a request (button: Send request)");
    await page.fill("#ts-date", await page.evaluate(() => { const d = new Date(); d.setDate(d.getDate() + 30); return d.toISOString().slice(0, 10); })); await page.fill("#ts-start", "17:00"); await page.fill("#ts-reason", "Tutor is away");
    await page.click("#ts-go"); await page.waitForTimeout(500);
    const sent = await page.evaluate(() => window.__calls.filter((c) => c[0] === "tutor_postpone_lesson").map((c) => c[1]));
    ok(sent.length === 1 && sent[0].p_lesson === "a" && sent[0].p_reason === "Tutor is away" && /^17:00/.test(sent[0].p_start), tag + ": 'Send request' calls the same function with the same arguments: " + JSON.stringify(sent[0]));
    ok(!(await page.isVisible("#tt-sheet.on")) && /Request sent\. Nothing changes until an admin approves it/.test(await page.textContent("body")), tag + ": the sheet closes and says the request was sent, and nothing changed");
    // a lesson with a waiting request: no 'Ask' buttons, a way to take it back
    await page.click('.tt-row[data-id="w"]'); await page.waitForTimeout(300);
    body = await page.textContent("#ts-body");
    ok(/Your request/.test(body) && /Cancel the lesson/.test(body) && /waiting for an admin/.test(body) && /Take my request back/.test(body) && !/Ask to move/.test(body) && !(await page.$("[data-act]")), tag + ": a lesson with a waiting request shows it and offers only 'Take my request back'");
    if (SC && theme === "light") await page.screenshot({ path: path.join(SC, "tutor-schedule-propose-waiting-sheet.png") });
    await axeCheck(page, tag + " waiting sheet");
    await page.click('[data-do="req-cancel"]'); await page.waitForTimeout(500);
    const cc = await page.evaluate(() => window.__calls.filter((c) => c[0] === "tutor_cancel_request").map((c) => c[1]));
    ok(cc.length === 1 && cc[0].p_request === "rq-wait", tag + ": taking it back calls tutor_cancel_request with its id");
    ok(!(await page.isVisible("#tt-sheet.on")) && /Request taken back\. Nothing was changed/.test(await page.textContent("body")), tag + ": and says nothing was changed");
    // the request list: a declined one shows the reason
    await page.click('#sc-reqs [data-req="rq-dec"]'); await page.waitForTimeout(300);
    body = await page.textContent("#ts-body");
    ok(/Declined: We need that lesson to go ahead/.test(body) && /Need a free evening/.test(body) && !(await page.$('[data-do="req-cancel"]')), tag + ": a declined request shows the admin's reason and no 'take back' button");
    await page.keyboard.press("Escape"); await page.waitForTimeout(200);
    await page.click('#sc-reqs [data-req="rq-nlp"]'); await page.waitForTimeout(300);
    ok(/Couldn't be done: it is now too close to the lesson/.test(await page.textContent("#ts-body")), tag + ": a 'no longer possible' request says why in plain words");
    await page.keyboard.press("Escape"); await page.waitForTimeout(200);
    // the link
    await page.click('.tt-row[data-id="a"]'); await page.waitForTimeout(250);
    await page.click('[data-do="link-lesson"]'); await page.waitForTimeout(250);
    ok(/Online link for this lesson/.test(await page.textContent("#ts-title")) && /Send request/.test(await page.textContent("#ts-body")), tag + ": the link form is a request too");
    await page.fill("#lk-url", "http://meet.example.com/x"); await page.click("#ts-do"); await page.waitForTimeout(250);
    ok(/https:\/\//.test(await page.textContent("#ts-msg")) && (await page.evaluate(() => window.__calls.filter((c) => c[0] === "tutor_set_link").length)) === 0, tag + ": an http:// link is refused on the page before anything is sent");
    await page.fill("#lk-url", "javascript:alert(1)"); await page.click("#ts-do"); await page.waitForTimeout(150);
    ok((await page.evaluate(() => window.__calls.filter((c) => c[0] === "tutor_set_link").length)) === 0, tag + ": javascript: is refused on the page");
    await page.fill("#lk-url", "https://meet.example.com/room-7"); await page.click("#ts-do"); await page.waitForTimeout(400);
    const lk = await page.evaluate(() => window.__calls.filter((c) => c[0] === "tutor_set_link").map((c) => c[1]));
    ok(lk.length === 1 && lk[0].p_lesson === "a" && lk[0].p_student === null && lk[0].p_link === "https://meet.example.com/room-7", tag + ": a good link is sent for the lesson: " + JSON.stringify(lk[0]));
    await page.click('.tt-row[data-id="a"]'); await page.waitForTimeout(250);
    await page.click('[data-do="link-student"]'); await page.waitForTimeout(250);
    await page.fill("#lk-url", "https://meet.example.com/usual"); await page.click("#ts-do"); await page.waitForTimeout(400);
    const lk2 = await page.evaluate(() => window.__calls.filter((c) => c[0] === "tutor_set_link").map((c) => c[1]));
    ok(lk2.length === 2 && lk2[1].p_student === "sa" && lk2[1].p_lesson === null, tag + ": the student's usual link is sent for the student: " + JSON.stringify(lk2[1]));
    // a cancelled lesson has no link button
    await page.click('.tt-row[data-id="x"]'); await page.waitForTimeout(250);
    ok(!(await page.$('[data-do="link-lesson"]')), tag + ": a cancelled lesson has no link button");
    await page.keyboard.press("Escape"); await page.waitForTimeout(200);
    // add a lesson, a slot and create lessons are requests too
    await page.click("#sc-add"); await page.waitForTimeout(500);
    ok(/Send request/.test(await page.textContent("#ts-do")) && /Nothing changes until they approve it/.test(await page.textContent("#ts-body")), tag + ": Add a lesson is a request (Send request)");
    await page.selectOption("#ad-stu", "st1"); await page.fill("#ad-date", await page.evaluate(() => { const d = new Date(); d.setDate(d.getDate() + 20); return d.toISOString().slice(0, 10); })); await page.fill("#ad-start", "15:00"); await page.fill("#ad-end", "16:00");
    await page.click("#ts-do"); await page.waitForTimeout(500);
    ok(/Request sent/.test(await page.textContent("body")) && !/Lesson added for/.test(await page.textContent("body")), tag + ": adding a lesson says 'Request sent', not 'Lesson added'");
    await page.click("#sc-generate"); await page.waitForTimeout(300);
    ok(/Send request/.test(await page.textContent("#ts-do")), tag + ": Create lessons is a request (Send request)");
    await page.click("#ts-do"); await page.waitForTimeout(500);
    ok(/Request sent/.test(await page.textContent("body")) && !(await page.isVisible("#tt-sheet.on")), tag + ": Create lessons says 'Request sent'");
    ok(errs.length === 0, tag + ": no script or console errors" + (errs.length ? " " + errs.join("|") : ""));
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + ": no sideways scroll at 390px");
    if (SC) await page.screenshot({ path: path.join(SC, `tutor-schedule-propose-${theme}.png`), fullPage: true });
    await axeCheck(page, tag + " page");
    await ctx.close();
  }
  { // the same page when the requests list can't be read (older database): the rest still works
    const { ctx, page, errs } = await open(b, "phone", "light", Object.assign({}, PROPOSE, { requestsError: true }), "tutor-schedule"); await goNext(page);
    ok((await page.$$("#sc-reqs .sc-tap")).length === 0 && (await page.$$(".tt-row")).length >= 2 && errs.length === 0, "the schedule still works when the requests list can't be loaded");
    await ctx.close(); }
  { // a refusal from the database is shown in plain words, never raw
    const { ctx, page } = await open(b, "phone", "light", Object.assign({}, PROPOSE, { changeError: "ALREADY_PENDING: you have already asked for this and an admin hasn't answered yet. Take that request back first if you want to change it" }), "tutor-schedule"); await goNext(page);
    await page.click('.tt-row[data-id="a"]'); await page.waitForTimeout(250); await page.click('[data-act="cancel"]'); await page.fill("#ts-reason", "A good reason"); await page.click("#ts-go"); await page.waitForTimeout(400);
    ok(/You have already asked for this/.test(await page.textContent("#ts-msg")) && !/ALREADY_PENDING/.test(await page.textContent("#ts-msg")), "ALREADY_PENDING is shown in plain words");
    await ctx.close(); }
  { // at a centre that acts directly, with the link switch on: a link is saved at once
    const { ctx, page } = await open(b, "phone", "light", Object.assign({}, DIRECT, { canLink: true }), "tutor-schedule"); await goNext(page);
    await page.click('.tt-row[data-id="a"]'); await page.waitForTimeout(250);
    ok(/Set the link of this lesson/.test(await page.textContent("#ts-body")) && !/Ask to/.test(await page.textContent("#ts-body")), "direct centre: 'Set the link of this lesson' (no 'Ask to')");
    await page.click('[data-do="link-lesson"]'); await page.fill("#lk-url", "https://meet.example.com/direct"); await page.click("#ts-do"); await page.waitForTimeout(400);
    ok(/Link saved\./.test(await page.textContent("body")) && !/Request sent/.test(await page.textContent("body")), "direct centre: the link is saved at once");
    await ctx.close(); }
  // ---------- D. errors and empty states
  { const { ctx, page } = await open(b, "phone", "light", { notFound: true }, "tutor-schedule");
    ok(/for tutors at a centre/.test(await page.textContent("#sc-week")) && !/NOT_FOUND/.test(await page.evaluate(() => document.body.innerText)), "someone who isn't a centre tutor: a plain message, never the raw code"); await ctx.close(); }
  { const { ctx, page } = await open(b, "phone", "light", { rpcError: true }, "tutor-schedule");
    ok(/isn.t available right now/.test(await page.textContent("#sc-week")), "if it can't load: a plain message"); await ctx.close(); }
  { const { ctx, page } = await open(b, "phone", "light", { lessons: [], slots: [] }, "tutor-schedule");
    ok(/No lessons this week/.test(await page.textContent("#sc-week")) && /no weekly slots yet/.test(await page.textContent("#sc-slots")), "nothing scheduled: friendly empty states"); await ctx.close(); }
  // ---------- E. who sees the Schedule tab
  const SOLO_ONLY = { role: { memberships: [{ org_id: "o1", user_id: "u1", role: "owner", status: "active", organisations: { id: "o1", kind: "solo", trading_name: "Mei Tuition" } }] } };
  const centreTutor = (n) => Object.assign({ role: { memberships: [{ role: "tutor", status: "active", organisations: { kind: "centre" } }, { role: "owner", status: "active", organisations: { kind: "solo" } }], studentCount: n } }, CFG);
  const hrefs = (page) => page.$$eval("a", (e) => e.map((x) => x.getAttribute("href")).filter(Boolean));
  { const { ctx, page } = await open(b, "desktop", "light", centreTutor(0), "tutor");
    const nav = await page.$$eval(".tn-links a", (e) => e.map((x) => x.textContent.trim()));
    ok(nav.join(",") === "My lessons,Schedule", "tutor-only: My lessons + Schedule (" + nav.join(",") + ")");
    await page.click('.tn-links a[href="tutor-schedule"]'); await page.waitForTimeout(1200);
    ok(/tutor-schedule$/.test(page.url()) && /Pupil/.test(await page.textContent("#sc-week")), "the Schedule tab opens and a tutor-only login STAYS there (no redirect)"); await ctx.close(); }
  { const { ctx, page } = await open(b, "desktop", "light", centreTutor(0), "tutor-schedule");
    ok(/tutor-schedule$/.test(page.url()), "a tutor-only login typing /tutor-schedule is not redirected");
    await page.goto(BASE + "ledger"); await page.waitForTimeout(1200);
    ok(/\/tutor$/.test(page.url()), "…but typing a solo page still sends them to My lessons"); await ctx.close(); }
  { const { ctx, page } = await open(b, "phone", "light", centreTutor(4), "home");
    const sheet = await page.$$eval("#tl-sheet a", (e) => e.map((x) => x.getAttribute("href")));
    ok(sheet.filter((h) => /^tutor/.test(h)).join() === "tutor" && /\/home$/.test(page.url()), "UX1: a solo tutor who also teaches at a centre has ONE centre entry in More (My lessons): " + sheet.join(","));
    await page.goto(BASE + "tutor-schedule"); await page.waitForTimeout(1200);
    ok((await page.$$eval(".subtabs a", (e) => e.map((x) => x.textContent.trim()))).join("|") === "My lessons|Schedule", "…and its Schedule is a sub-tab on those pages");
    await ctx.close(); }
  for (const pg of ["home", "calendar", "students", "settings"]) {
    const { ctx, page } = await open(b, "desktop", "light", SOLO_ONLY, pg);
    ok(!(await hrefs(page)).includes("tutor-schedule") && !/tutor-schedule/.test(page.url()), "a plain solo login on " + pg + " has no Schedule-tutor link"); await ctx.close();
  }
  { const { ctx, page } = await open(b, "desktop", "light", {}, "centre");      // the default stub owns a centre: its menu is the staff menu
    ok(!(await hrefs(page)).includes("tutor-schedule"), "centre owner/staff menu has no tutor Schedule tab"); await ctx.close(); }
  await b.close();
  console.log(fails ? "\n" + fails + " FAILED" : "\nall browser checks passed"); process.exit(fails ? 1 : 0);
})();
