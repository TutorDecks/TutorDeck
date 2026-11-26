// Browser check for the tutor's read-only Schedule page (T6 step 1). Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
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
      postponed: false, covering: false, online_link: null, holiday: null }, o || {}); };
    var lessons = (cfg.lessons || []).map(function (x) { return L(x[0], x[1], x[2]); });
    var origRpc = c.rpc.bind(c), origFrom = c.from.bind(c);
    c.rpc = function (n, a) {
      window.__calls.push([n, a]);
      if (n === "tutor_my_schedule") {
        if (cfg.notFound) return Promise.resolve({ data: null, error: { message: "NOT_FOUND" } });
        if (cfg.rpcError) return Promise.resolve({ data: null, error: { message: "boom" } });
        var inr = lessons.filter(function (l) { return l.lesson_date >= a.p_from && l.lesson_date <= a.p_to; }).sort(function (x, y) { return x.lesson_date < y.lesson_date ? -1 : x.lesson_date > y.lesson_date ? 1 : x.start_time < y.start_time ? -1 : 0; });
        var hol = (cfg.holidays || []).map(function (h) { return { org_id: "o2", name: h[2], starts_on: iso(h[0]), ends_on: iso(h[1]) }; }).filter(function (h) { return h.starts_on <= a.p_to && h.ends_on >= a.p_from; });
        return Promise.resolve({ data: { today: iso(0), from: a.p_from, to: a.p_to, orgs: [{ org_id: "o2", name: "Test Tuition", today: iso(0), timetable_editing: cfg.editing || "admin_only", can_edit: false }], lessons: inr, holidays: hol }, error: null });
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
  // ---------- C. the centre's setting only changes the note (nothing can be edited in this step)
  { const { ctx, page } = await open(b, "phone", "light", Object.assign({}, CFG, { editing: "tutors_own" }), "tutor-schedule");
    ok(/coming soon/.test(await page.textContent("#sc-note")) && (await page.$$("[data-page='tutor-schedule'] input, [data-page='tutor-schedule'] textarea, [data-page='tutor-schedule'] select")).length === 0, "a centre that lets tutors edit: a 'coming soon' note, still read-only"); await ctx.close(); }
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
