// Browser check for UX1: the menu of EVERY kind of login (items + icons), the Schedule's List | Calendar view for centre tutors, and the
// "Also show my centre lessons" overlay on the solo calendar. Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/menus.check.js [screenshot-dir]
// Prints, per role and size, the bottom/top bar and the More sheet with the picture (icon id) of each entry. Supabase is a made-up stand-in.
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
const STUB_PLUS = STUB + `;(function(){var o=window.supabase.createClient;window.supabase.createClient=function(){var c=o.apply(this,arguments);if(window.__override)window.__override(c);return c;};})();`;
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };

const SOLO = { id: "s1", kind: "solo", role: "owner", name: "Mei Tuition" };
const CEN = (role, perms) => ({ id: "c1", kind: "centre", role, name: "Demo Centre", perms });
const ALL = ["manage_students", "manage_timetable", "issue_invoices", "manage_tutors"];
// [name, roleMode, [organisations], pick, page]
const MEM = (role, perms) => [{ org_id: "c1", user_id: "u1", role, status: "active", permissions: perms || [], organisations: { id: "c1", kind: "centre", trading_name: "Demo Centre" } }];
const ROLES = [
  ["solo tutor", "solo", [SOLO], null, "home"],
  ["both: in their solo organisation", "both", [SOLO, CEN("tutor")], "s1", "home"],
  ["both: working in the centre", "both", [SOLO, CEN("tutor")], "c1", "tutor"],
  ["centre-only tutor", "tutor-only", [CEN("tutor")], "c1", "tutor"],
  ["centre owner", "solo", [CEN("owner")], "c1", "centre?id=c1"],
  ["centre staff, all permissions", "solo", [CEN("staff", ALL)], "c1", "centre?id=c1", MEM("staff", ALL)],
  ["centre front desk (students)", "solo", [CEN("staff", ["manage_students"])], "c1", "centre?id=c1", MEM("staff", ["manage_students"])]
];

function override(cfg) {
  window.__calls = [];
  window.__override = function (c) {
    var iso = function (n) { var d = new Date(); d.setDate(d.getDate() + n); var p = function (x) { return (x < 10 ? "0" : "") + x; }; return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()); };
    var L = function (id, off, o) { return Object.assign({ lesson_id: id, org_id: "c1", org_name: "Demo Centre", student_id: "s" + id, student_name: "Pupil " + id, student_level: "P5", parent_contact: null,
      lesson_date: iso(off), start_time: "16:00:00", end_time: "17:00:00", minutes: 60, subject: "Math", trial: false, attendance: null, status: "scheduled", cancelled: false,
      postponed: false, covering: false, online_link: null, holiday: null, can_postpone: false, can_revert: false, can_cancel: false, change_block: null, class_size: 0 }, o || {}); };
    var lessons = (cfg.lessons || []).map(function (x) { return L(x[0], x[1], x[2]); });
    var origRpc = c.rpc.bind(c), origFrom = c.from.bind(c);
    c.from = function (t) {
      if (t !== "memberships" || !cfg.members) return origFrom(t);
      var q = {}; ["select", "eq", "order", "neq", "in", "is", "limit"].forEach(function (m) { q[m] = function () { return q; }; });
      q.then = function (r, j) { return Promise.resolve({ data: cfg.members, error: null }).then(r, j); };
      return q;
    };
    c.rpc = function (n, a) {
      window.__calls.push([n, a]);
      if (n === "tutor_my_schedule") {
        var inr = lessons.filter(function (l) { return l.lesson_date >= a.p_from && l.lesson_date <= a.p_to; });
        var hol = (cfg.holidays || []).map(function (h) { return { org_id: "c1", name: h[2], starts_on: iso(h[0]), ends_on: iso(h[1]) }; }).filter(function (h) { return h.starts_on <= a.p_to && h.ends_on >= a.p_from; });
        return Promise.resolve({ data: { today: iso(0), from: a.p_from, to: a.p_to, orgs: [{ org_id: "c1", name: "Demo Centre", today: iso(0), timetable_editing: "admin_only", can_edit: false, can_postpone: false, can_cancel: false,
          min_notice_hours: 24, max_changes_per_month: 0, changes_left: null }], lessons: inr, holidays: hol }, error: null });
      }
      if (n === "tutor_my_lessons") return Promise.resolve({ data: lessons.filter(function (l) { return l.lesson_date >= a.p_from && l.lesson_date <= a.p_to; }).map(function (l) {
        return { lesson_id: l.lesson_id, org_id: l.org_id, org_name: l.org_name, student_id: l.student_id, student_name: l.student_name, student_level: l.student_level, parent_contact: null, lesson_date: l.lesson_date,
          start_time: l.start_time, end_time: l.end_time, subject: l.subject, status: l.status, attendance: l.attendance, trial: l.trial, session_id: null, topics: null, homework: null, remarks: null, remarks_due_at: null,
          can_mark: false, can_note: false, can_cancel: false, remarks_required: false, can_flag_trial: false, tutor_sets_compensation: false, charge_pending: false }; }), error: null });
      if (n === "tutor_my_slots") return Promise.resolve({ data: [], error: null });
      if (n === "staff_home") return Promise.resolve({ data: null, error: { message: "NOT_ALLOWED" } });
      return origRpc(n, a);
    };
  };
}
async function open(browser, o) {
  const ctx = await browser.newContext(o.phone ? { viewport: { width: 390, height: 844 }, isMobile: true, deviceScaleFactor: 2 } : { viewport: { width: 1280, height: 900 } });
  await ctx.addInitScript((a) => {
    try {
      localStorage.setItem("td_theme", a.theme);
      if (a.seed && !localStorage.getItem("__seeded")) {   // seed only on the first load, so a reload keeps what the page itself saved
        localStorage.setItem("__seeded", "1");
        var now = Date.now();
        localStorage.setItem("td:u1:role", JSON.stringify({ v: a.seed.mode, at: now }));
        localStorage.setItem("td:u1:orgs", JSON.stringify({ list: a.seed.orgs, at: now }));
        if (a.seed.pick) localStorage.setItem("td:u1:org_pick", a.seed.pick);
        (a.seed.store || []).forEach(function (kv) { localStorage.setItem("td:u1:" + kv[0], kv[1]); });
      }
    } catch (e) {}
  }, { theme: o.dark ? "dark" : "light", seed: o.seed || null });
  await ctx.route(/^(?!http:\/\/127\.0\.0\.1).*/, (r) => r.abort());
  const page = await ctx.newPage(), errs = [];
  await page.route("**/assets/vendor/supabase-2.118.0.js", (r) => r.fulfill({ body: STUB_PLUS, contentType: "application/javascript" }));
  await page.addInitScript(override, o.cfg || {});
  page.on("pageerror", (e) => errs.push(e.message));
  page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource|net::ERR/.test(m.text())) errs.push("console: " + m.text()); });
  await page.goto(BASE + o.url, { waitUntil: "load" }); await page.waitForTimeout(1500);
  return { ctx, page, errs };
}
// every entry of the menu as drawn, with the icon id it uses
const DRAWN = () => {
  const ids = {}; Object.keys(window.Menus.ICONS).forEach((k) => { const s = document.createElementNS("http://www.w3.org/2000/svg", "svg"); s.innerHTML = window.Menus.ICONS[k]; ids[s.innerHTML] = k; });
  const idOf = (a) => { const v = a.querySelector("svg"); return v ? (ids[v.innerHTML] || "?") : "-"; };
  const txt = (a) => (a.getAttribute("aria-label") || a.textContent).replace(/\s+/g, " ").replace(/\s*soon\s*\(coming next\)/i, "").replace(/\s*soon$/i, "").trim();
  const vis = (e) => !!(e.offsetWidth || e.offsetHeight);
  const pick = (sel) => Array.from(document.querySelectorAll(sel)).filter(vis).map((a) => ({ label: txt(a), ic: idOf(a), href: a.getAttribute("href") }));
  return { bar: pick(".tabbar a, .tabbar button"), top: pick(".tn-links a"), topIcons: pick(".tn-right a.tn-ic"), sheet: Array.from(document.querySelectorAll("#tl-sheet a, #tl-sheet button.ms-out")).map((a) => ({ label: txt(a), ic: idOf(a), href: a.getAttribute("href") })) };
};
const dupes = (list) => { const seen = {}, d = []; list.forEach((x) => { if (seen[x.ic] && seen[x.ic] !== x.label) d.push(x.ic + ": " + seen[x.ic] + " / " + x.label); else seen[x.ic] = x.label; }); return d; };
const show = (l) => l.map((x) => x.label + "[" + x.ic + "]").join(" · ");

const iso = (n) => { const d = new Date(); d.setDate(d.getDate() + n); const p = (x) => (x < 10 ? "0" : "") + x; return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()); };
const dow = (new Date().getDay() + 6) % 7, mon = -dow;
const CFG = {
  lessons: [["a", mon, { start_time: "16:00:00" }], ["b", mon, { start_time: "16:30:00", end_time: "17:30:00", student_name: "Pupil B", trial: true }], ["c", mon + 2, { cancelled: true, status: "cancelled" }],
            ["d", mon + 3, { postponed: true }], ["e", mon + 4, { covering: true }], ["f", mon + 4, { attendance: "attended", start_time: "18:00:00", end_time: "19:00:00" }], ["g", mon + 8, { student_name: "Next week pupil" }]],
  holidays: [[mon + 3, mon + 3, "Teachers' Day"]]
};
const MONEY = /(S\$|\$\s?\d|\bprice\b|\brate\b|\bpaid\b|\bamount\b|\bcompensation\b|\bcharge\b|\bfee\b)/i;

(async () => {
  const b = await chromium.launch();
  // ---------- A. every role's menu: phone + desktop, light + dark
  for (const [name, mode, orgs, pick, url, members] of ROLES) {
    for (const [vp, theme] of [["phone", "light"], ["desktop", "light"], ["phone", "dark"], ["desktop", "dark"]]) {
      const { ctx, page } = await open(b, { phone: vp === "phone", dark: theme === "dark", url, seed: { mode, orgs, pick }, cfg: Object.assign({ members }, CFG) });
      const d = await page.evaluate(DRAWN), tag = name + " / " + vp + " / " + theme;
      const main = vp === "phone" ? d.bar.filter((x) => x.label !== "More") : d.top;
      if (theme === "light") console.log("  " + tag + "\n     " + (vp === "phone" ? "bottom bar: " : "top bar: ") + show(main) + "\n     " + (vp === "phone" ? "More sheet: " : "icons right: ") + show(vp === "phone" ? d.sheet : d.topIcons));
      const all = vp === "phone" ? d.bar.concat(d.sheet) : d.top.concat(d.topIcons);
      ok(dupes(all).length === 0 && !all.some((x) => x.ic === "?"), tag + ": every entry has its own icon" + (dupes(all).length ? " " + dupes(all).join("; ") : ""));
      if (vp === "phone" && theme === "light" && SC && ["both: in their solo organisation", "centre owner"].includes(name)) { await page.click("#tl-more"); await page.waitForTimeout(300); await page.screenshot({ path: path.join(SC, "menu-" + name.replace(/\W+/g, "-") + ".png") }); }
      if (vp === "phone" && theme === "light") {
        const labels = d.sheet.map((x) => x.label), hrefs = d.sheet.map((x) => x.href);
        if (name === "both: in their solo organisation") {
          ok(show(main) === "Home[home] · Schedule[schedule] · Students[students] · Money[money]", name + ": the normal solo bottom bar (" + show(main) + ")");
          ok(labels.join("|") === "My lessons|Materials MugCorner ↗|Settings|Sign out" && !labels.includes("My tutor profile") && hrefs.includes("settings") && !hrefs.includes("tutor-settings"),
             name + ": More = My lessons, Materials, Settings (solo page) and Sign out: " + labels.join(" | "));
        }
        if (name === "both: working in the centre") {
          ok(main.map((x) => x.label).join("|") === "My lessons|Schedule" && hrefs.includes("tutor-settings") && !hrefs.includes("settings"), name + ": tutor menu; Settings is /tutor-settings only: " + show(main) + " + " + labels.join(" | "));
        }
        if (name === "centre owner") ok(["Centre settings", "Your centres", "Settings"].every((l) => labels.includes(l)), name + ": three different settings entries in More");
      }
      await ctx.close();
    }
  }
  // ---------- B. Schedule: List | Calendar for a centre tutor
  const TUT = { mode: "tutor-only", orgs: [CEN("tutor")], pick: "c1" };
  for (const [vp, theme] of [["desktop", "light"], ["phone", "light"], ["phone", "dark"], ["desktop", "dark"]]) {
    const tag = "calendar/" + vp + "/" + theme;
    const { ctx, page, errs } = await open(b, { phone: vp === "phone", dark: theme === "dark", url: "tutor-schedule", seed: TUT, cfg: CFG });
    ok(await page.isVisible("#sc-week") && !(await page.isVisible("#sc-cal")) && (await page.getAttribute("#sc-v-list", "aria-pressed")) === "true", tag + ": opens on the List");
    await page.click("#sc-v-cal"); await page.waitForTimeout(400);
    ok(!(await page.isVisible("#sc-week")) && await page.isVisible("#sc-cal"), tag + ": Calendar replaces the list");
    const evs = await page.$$eval(".sc-ev", (e) => e.filter((x) => x.offsetWidth).map((x) => ({ n: x.querySelector(".e-n").textContent, c: (x.querySelector(".e-c") || {}).textContent || "", k: x.className })));
    if (vp === "desktop") {
      ok((await page.$$(".sc-dh")).length === 7 && (await page.$$(".sc-col")).length === 7, tag + ": seven day columns");
      ok(evs.length === 6, tag + ": the week's 6 lessons are drawn, not next week's (" + evs.length + ")");
      ok(["Trial", "Cancelled", "Moved", "Covering", "Attended"].every((c) => evs.some((x) => x.c.replace("✓ ", "") === c)), tag + ": same chips as the list (" + evs.map((x) => x.c).filter(Boolean).join(",") + ")");
      ok((await page.$$(".sc-col.hol")).length === 1 && (await page.$$(".sc-dh.hol")).length === 1 && /Teachers' Day/.test(await page.textContent(".sc-dh.hol")), tag + ": the holiday is a grey band");
      const pos = await page.$$eval('.sc-ev[data-id="a"], .sc-ev[data-id="b"]', (e) => e.map((x) => [Math.round(x.getBoundingClientRect().left), Math.round(x.getBoundingClientRect().width)]));
      ok(pos.length === 2 && pos[0][0] !== pos[1][0], tag + ": two overlapping lessons sit side by side " + JSON.stringify(pos));
    } else {
      ok((await page.$$(".sc-sd")).length === 7, tag + ": a Mon-Sun day strip");
      ok(evs.length >= 1 && (await page.$$(".sc-col")).length === 1, tag + ": one day's timeline (" + evs.length + " lessons)");
      const t0 = await page.textContent("#sc-title"); await page.click("#sc-next"); await page.waitForTimeout(400);
      const t1 = await page.textContent("#sc-title"); ok(t0 !== t1, tag + ": the arrow moves a day (" + t0.slice(0, 18) + " → " + t1.slice(0, 18) + ")");
      await page.click("#sc-today"); await page.waitForTimeout(400);
      await page.click(".sc-sd:nth-child(4)"); await page.waitForTimeout(300);   // Thursday: the holiday
      ok(/Teachers' Day · holiday/.test(await page.textContent("#sc-cal")) && (await page.$$(".sc-col.hol")).length === 1, tag + ": a holiday day shows the grey band");
      await page.click(".sc-sd:nth-child(5)"); await page.waitForTimeout(300);   // Friday: covering + attended
    }
    // tapping a lesson opens the same sheet as the list
    const id = vp === "desktop" ? "e" : null;
    const target = id ? '.sc-ev[data-id="' + id + '"]' : ".sc-ev";
    await page.click(target); await page.waitForTimeout(350);
    ok(await page.isVisible("#tt-sheet.on") && /Class|Length/.test(await page.textContent("#ts-body")), tag + ": a tap opens the lesson sheet");
    ok(!MONEY.test(await page.textContent("#tt-sheet")) && !MONEY.test(await page.textContent("#sc-cal")), tag + ": no money word in the grid or the sheet");
    await page.keyboard.press("Escape"); await page.waitForTimeout(250);
    if (SC) await page.screenshot({ path: path.join(SC, `schedule-calendar-${vp}-${theme}.png`), fullPage: true });
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + ": no sideways scroll");
    ok(errs.length === 0, tag + ": no script errors" + (errs.length ? " " + errs.join("|") : ""));
    // remembered per user: a reload opens on the Calendar
    await page.reload({ waitUntil: "load" }); await page.waitForTimeout(1200);
    ok(await page.isVisible("#sc-cal") && (await page.getAttribute("#sc-v-cal", "aria-pressed")) === "true", tag + ": the choice is remembered after a reload");
    await ctx.close();
  }
  { // ?d= opens the week of that day
    const { ctx, page } = await open(b, { phone: false, url: "tutor-schedule?d=" + iso(mon + 8), seed: TUT, cfg: CFG });
    ok(/Next week/.test(await page.textContent("#sc-title")), "tutor-schedule?d=<next week> opens next week");
    await ctx.close(); }
  // ---------- C. solo calendar: "Also show my centre lessons"
  for (const [vp, theme] of [["desktop", "light"], ["phone", "light"], ["phone", "dark"]]) {
    const tag = "overlay/" + vp + "/" + theme;
    const BOTH = { mode: "both", orgs: [SOLO, CEN("tutor")], pick: "s1" };
    const { ctx, page, errs } = await open(b, { phone: vp === "phone", dark: theme === "dark", url: "calendar", seed: BOTH, cfg: CFG });
    ok(await page.isVisible("#cal-centre") && (await page.getAttribute("#cal-centre", "aria-pressed")) === "false", tag + ": a both-role tutor sees the toggle, off by default");
    ok(!(await page.evaluate(() => window.__calls.some((c) => c[0] === "tutor_my_lessons"))), tag + ": nothing from the centre is asked for while it is off");
    const before = await page.$$eval(".cal-ev, .ag-row, .cal-chip", (e) => e.filter((x) => /Pupil/.test(x.textContent)).length);
    ok(before === 0, tag + ": no centre lesson on the solo calendar by default");
    await page.click("#cal-centre"); await page.waitForTimeout(900);
    if (vp === "phone") { const m = await page.$("#seg-list"); }
    const blocks = await page.$$eval(".is-centre", (e) => e.filter((x) => x.offsetWidth).map((x) => x.textContent.replace(/\s+/g, " ").trim()));
    ok(blocks.length >= 4 && blocks.some((t) => /Pupil/.test(t)) && blocks.some((t) => /Demo Centre/.test(t)), tag + ": centre lessons appear, labelled with the centre (" + blocks.length + "): " + (blocks[0] || "").slice(0, 60));
    ok((await page.evaluate(() => window.__calls.filter((c) => c[0] === "tutor_my_lessons").length)) >= 1, tag + ": they come from tutor_my_lessons");
    const solo = await page.$$eval(".cal-ev:not(.is-centre), .ag-row:not(.is-centre)", (e) => e.length);
    ok(solo >= 1, tag + ": the tutor's own lessons are still there (" + solo + ")");
    ok((await page.$$(".is-centre.is-clash")).length === 0, tag + ": a centre lesson never draws a clash outline");
    await page.click(".is-centre:not(.is-cancel)"); await page.waitForTimeout(300);
    const pop = await page.textContent("#cal-pop");
    ok(/Centre lesson/.test(pop) && /Demo Centre/.test(pop) && !MONEY.test(pop) && !(await page.$("#cp-postpone, #cp-cancel, #cp-delete, #cp-log")) && /tutor-schedule\?d=/.test(await page.getAttribute("#cal-pop .cp-act", "href")), tag + ": the popover is read-only facts with a link to the schedule");
    if (SC) await page.screenshot({ path: path.join(SC, `calendar-overlay-${vp}-${theme}.png`), fullPage: false });
    ok(errs.length === 0, tag + ": no script errors" + (errs.length ? " " + errs.join("|") : ""));
    await page.keyboard.press("Escape"); await page.mouse.click(5, 5);
    await page.reload({ waitUntil: "load" }); await page.waitForTimeout(1300);
    ok((await page.getAttribute("#cal-centre", "aria-pressed")) === "true" && (await page.$$(".is-centre")).length > 0, tag + ": remembered after a reload");
    await page.click("#cal-centre"); await page.waitForTimeout(500);
    ok((await page.$$eval(".is-centre", (e) => e.filter((x) => x.offsetWidth).length)) === 0, tag + ": switching it off removes them again");
    await ctx.close();
  }
  { const { ctx, page } = await open(b, { phone: false, url: "calendar", seed: { mode: "solo", orgs: [SOLO], pick: "s1" }, cfg: CFG });
    ok(!(await page.isVisible("#cal-centre")), "a solo tutor with no centre never sees the toggle");
    ok(!(await page.evaluate(() => window.__calls.some((c) => c[0] === "tutor_my_lessons"))), "and the centre function is never called");
    await ctx.close(); }
  await b.close();
  console.log(fails ? "\n" + fails + " FAILED" : "\nall browser checks passed"); process.exit(fails ? 1 : 0);
})();
