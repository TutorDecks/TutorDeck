// Browser check for the tutor's Schedule page (T6 step 1: read only; step 2: Move / Put back / Cancel when the centre allows it). Not part of CI:
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
      postponed: false, covering: false, online_link: null, holiday: null, can_postpone: false, can_revert: false, can_cancel: false, change_block: null, class_size: 0 }, o || {}); };
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
          min_notice_hours: 24, max_changes_per_month: cfg.changesLeft == null ? 0 : 5, changes_left: cfg.changesLeft == null ? null : cfg.changesLeft }], lessons: inr, holidays: hol }, error: null });
      }
      if (n === "tutor_postpone_lesson" || n === "tutor_revert_lesson" || n === "tutor_cancel_lesson") {
        if (cfg.changeError) return Promise.resolve({ data: null, error: { message: cfg.changeError } });
        return new Promise(function (res) { setTimeout(function () { res({ data: { lesson_id: a.p_lesson, lessons: 1, what: n === "tutor_cancel_lesson" ? "cancelled" : n === "tutor_revert_lesson" ? "reverted" : "moved",
          lesson_date: a.p_date || iso(2), start_time: (a.p_start || "15:00") + ":00", end_time: "16:00:00", cancelled: n === "tutor_cancel_lesson" }, error: null }); }, 150); });
      }
      if (n === "tutor_my_slots") return Promise.resolve({ data: (cfg.slots || []).map(function (s, i) { return { slot_id: "sl" + i, org_id: "o2", org_name: "Test Tuition", weekday: s[0], start_time: s[1], end_time: s[2], subject: s[3], student_id: "x" + i, student_name: s[4], student_level: s[5], session_key: null, timetable_editing: "admin_only" }; }), error: null });
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
    ok((await page.$$("[data-page='tutor-schedule'] button:not(.tt-row):not(.sc-nav):not(.owe-x)")).length === 0 && (await page.$$("[data-page='tutor-schedule'] input, [data-page='tutor-schedule'] textarea, [data-page='tutor-schedule'] select")).length === 0, tag + ": no edit buttons or fields anywhere");
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
  // ---------- C. a centre whose setting is not built yet only changes the note
  { const { ctx, page } = await open(b, "phone", "light", Object.assign({}, CFG, { editing: "tutors_propose" }), "tutor-schedule");
    ok(/coming soon/.test(await page.textContent("#sc-note")) && (await page.$$("[data-page='tutor-schedule'] input, [data-page='tutor-schedule'] textarea, [data-page='tutor-schedule'] select")).length === 0, "a centre where tutors ask and an admin approves (not built): a 'coming soon' note, still read-only"); await ctx.close(); }
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
    await page.click("#ts-go"); await page.click("#ts-go").catch(() => {});           // a double press
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
    ok(sheet.includes("tutor-schedule") && /\/home$/.test(page.url()), "a solo tutor who also teaches at a centre finds Schedule in More: " + sheet.join(","));
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
