// Browser check for the Make-ups tab (the owed list) on the Attendance page (T18 step 4). Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/centre-credits.check.js [screenshot-dir]
// The database functions are replaced by a small in-memory stand-in that follows the same rules (tests/sql/makeup_credits_test.sql proves the real ones).
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
  var K = { "11111111-1111-4111-8111-111111111111": "Kid One", "22222222-2222-4222-8222-222222222222": "Kid Two", "33333333-3333-4333-8333-333333333333": "Kid Three" };
  var CR = cfg.empty ? [] : [
    { id: "cr1", st: "11111111-1111-4111-8111-111111111111", status: "open", source: "absence", reason: "Missed lesson: cancelled early", earned: add(TODAY, -1), exp: null, miss: { d: add(TODAY, -1), t: "10:00:00", att: "cancelled_early", tut: "Demo Tutor One" } },
    { id: "cr2", st: "22222222-2222-4222-8222-222222222222", status: "open", source: "absence", reason: "Missed lesson: late cancelled", earned: add(TODAY, -3), exp: add(TODAY, 3), miss: { d: add(TODAY, -3), t: "16:00:00", att: "late_cancelled", tut: "Demo Tutor Two" } },
    { id: "cr3", st: "33333333-3333-4333-8333-333333333333", status: "open", source: "manual", reason: "Tutor was unwell", earned: add(TODAY, -2), exp: null, miss: null },
    { id: "cr4", st: "11111111-1111-4111-8111-111111111111", status: "booked", source: "absence", reason: "x", earned: add(TODAY, -6), exp: null, miss: { d: add(TODAY, -6), t: "10:00:00", att: "cancelled_early", tut: "Demo Tutor One" },
      mk: { d: add(TODAY, 4), s: "17:00:00", e: "18:00:00", att: null, billing: "free", tut: "Demo Tutor Two" } }];
  window.__calls = [];
  function counts(list) { var c = { open: 0, booked: 0, used: 0, expired: 0, revoked: 0 }; list.forEach((x) => c[x.status]++); return c; }
  function row(x) {
    var look = cfg.look;
    return { credit_id: x.id, student_id: x.st, student_name: K[x.st], status: x.status, source: x.source, reason: x.reason, earned_on: x.earned, expires_on: x.exp,
      days_left: x.exp && x.status === "open" ? Math.round((Date.parse(x.exp) - Date.parse(TODAY)) / 86400000) : null, expired_by_date: false,
      missed: x.miss ? { lesson_id: "l" + x.id, date: x.miss.d, start_time: x.miss.t, subject: "Math", attendance: x.miss.att, tutor_name: x.miss.tut } : null,
      makeup: x.mk ? { lesson_id: "m" + x.id, date: x.mk.d, start_time: x.mk.s, end_time: x.mk.e, attendance: x.mk.att, billing: x.mk.billing, tutor_name: x.mk.tut } : null,
      can_revoke: x.status === "open" && !look, can_book: x.status === "open" && !look, can_unbook: x.status === "booked" && !look && !(x.mk && x.mk.att) };
  }
  window.__override = function (c) {
    var from = c.from.bind(c), rpc = c.rpc.bind(c);
    function res(d, e) { return Promise.resolve({ data: d || null, error: e ? (typeof e === "string" ? { message: e } : e) : null }); }
    c.rpc = function (nm, a) {
      window.__calls.push([nm, a]);
      if (nm === "staff_home") return res({ org_id: "c1", org_name: "Demo Learning Centre", status: "active", today: TODAY, can: { students: true, timetable: true, charges: false },
        students_active: 8, today_lessons: 3, today_marked: 1, today_to_mark: 2, unmarked_past: 0, no_tutor_14d: 0, trials_this_month: 0, pending_charges: null });
      if (nm === "staff_lessons") return res({ today: TODAY, can_mark: true, page: 1, size: 50, total: 0, counts: { all: 0, unmarked: 0, marked: 0 },
        tutors: [{ id: "t1", name: "Demo Tutor One" }, { id: "t2", name: "Demo Tutor Two" }], rows: [] });
      if (nm === "staff_pending_charges") return cfg.charges ? res({ today: TODAY, page: 1, size: 50, total: 0, rows: [] }) : res(null, { code: "PGRST202", message: "Could not find the function" });
      if (!/^staff_(credit_list|grant_credit|revoke_credit|book_makeup|unbook_makeup|pick_students)$/.test(nm)) return rpc(nm, a);
      if (cfg.listError && nm === "staff_credit_list") return res(null, cfg.listError);
      if (nm === "staff_pick_students") return res([{ id: "11111111-1111-4111-8111-111111111111", name: "Kid One", level: "P3" }, { id: "33333333-3333-4333-8333-333333333333", name: "Kid Three", level: "P5" }]);
      if (nm === "staff_credit_list") {
        var st = a.p_status, list = CR.filter((x) => (!a.p_student || x.st === a.p_student) && (st === "all" || x.status === st));
        return res({ today: TODAY, page: a.p_page, size: a.p_size, total: list.length, counts: counts(CR.filter((x) => !a.p_student || x.st === a.p_student)), rows: list.map(row),
          enabled: cfg.enabled !== false, can_grant: !cfg.look, can_book: !cfg.look, makeup_price: cfg.price || "free", expiry_days: 0 });
      }
      var x = CR.find((y) => y.id === a.p_credit);
      if (nm === "staff_grant_credit") { CR.push({ id: "cr" + (CR.length + 1), st: a.p_student, status: "open", source: "manual", reason: a.p_reason, earned: TODAY, exp: null, miss: null }); return res({ credit_id: "new" }); }
      if (!x) return res(null, "NOT_FOUND");
      if (nm === "staff_revoke_credit") { if (x.status !== "open") return res(null, "NO_CHANGE: this credit is " + x.status); x.status = "revoked"; return res({ status: "revoked" }); }
      if (nm === "staff_book_makeup") {
        if (x.status === "booked") return res(null, "ALREADY_BOOKED: a make-up lesson is already booked with this credit");
        if (cfg.bookError) return res(null, cfg.bookError);
        x.status = "booked"; x.mk = { d: a.p_date, s: a.p_start + ":00", e: a.p_end + ":00", att: null, billing: "free", tut: "Demo Tutor One" }; return res({ credit_id: x.id, lesson_id: "ml", billing: "free", date: a.p_date });
      }
      if (nm === "staff_unbook_makeup") { if (x.status !== "booked") return res(null, "NO_CHANGE: no make-up is booked with this credit"); x.status = "open"; x.mk = null; return res({ status: "open" }); }
    };
    c.from = function (t) {
      if (t === "students") { var q = from(t), sel = q.select; q.select = function (cols, opt) { if (!(opt && opt.head)) return sel.apply(q, arguments); var o = {}; ["eq", "neq", "in", "is"].forEach(function (f) { o[f] = function () { return o; }; }); o.then = function (r, j) { return Promise.resolve({ count: 8, error: null }).then(r, j); }; return o; }; return q; }
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
const calls = (page, nm) => page.evaluate((n) => window.__calls.filter((c) => c[0] === n).map((c) => c[1]), nm);
const noOverflow = (page) => page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1);

(async () => {
  const browser = await chromium.launch();
  const STAFF = ["manage_students", "manage_timetable"];
  for (const mode of ["desktop", "phone", "dark"]) {
    const phone = mode === "phone", tag = mode + ": ";
    const { ctx, page, errs } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", STAFF)] }, { phone, dark: mode === "dark" });
    await page.goto(BASE + "centre-attendance.html?id=c1"); await page.waitForSelector("#ca-tabs:not([hidden])");
    ok(/Make-ups\s*3/.test((await page.locator("#ca-tabs").innerText()).replace(/\n/g, " ")), tag + "the Make-ups tab shows, with the 3 owed");
    ok(await page.locator("#ca-tab-charges").isHidden(), tag + "without the Charges permission the Charges tab stays away");
    ok(await page.locator("#mk").isHidden() && await page.locator("#ca").isVisible(), tag + "Lessons is still the first tab");
    await page.click("#ca-tab-makeups"); await page.waitForSelector(".mk-open");
    ok(await page.locator(".mk-open").count() === 3, tag + "the owed list has the 3 open credits (the booked one is under Booked)");
    ok(/tab=makeups/.test(page.url()) && await page.locator("#ca").isHidden(), tag + "the address remembers the tab and Lessons steps aside");
    const body = await page.locator("#mk").innerText();
    ok(!/S\$|\$\d|undefined|null|NaN/.test(body), tag + "no money and no raw words on the page");
    ok(/not billed|never pays twice/i.test(body), tag + "the centre's price rule is explained in words");
    const r1 = await page.locator(".mk-open", { hasText: "Kid One" }).innerText();
    ok(/Missed .*10:00 am · Demo Tutor One/.test(r1) && /Owed/.test(r1), tag + "a row names the student, the missed lesson, its tutor and the state");
    const r2 = await page.locator(".mk-open", { hasText: "Kid Two" }).innerText();
    ok(/Ends soon/.test(r2) && /Use by .*\(3 days left\)/.test(r2), tag + "a credit about to end says so");
    const r3 = await page.locator(".mk-open", { hasText: "Kid Three" }).innerText();
    ok(/Tutor was unwell/.test(r3), tag + "a credit given by hand shows its reason");
    if (phone) ok(await noOverflow(page), tag + "no sideways scrolling at 390px");
    if (SC) await page.screenshot({ path: path.join(SC, "makeups-list-" + mode + ".png") });
    // booking
    await page.locator(".mk-open", { hasText: "Kid One" }).click(); await page.waitForSelector("#mk-sheet.on");
    ok(/Missed lesson/.test(await page.locator("#mk-sb").innerText()) && await page.locator("#mk-book").isVisible() && await page.locator("#mk-revoke").isVisible(), tag + "the sheet shows the missed lesson with Book and Take back");
    await page.click("#mk-book");
    ok((await page.inputValue("#mk-start")) === "10:00" && (await page.inputValue("#mk-end")) === "11:00", tag + "the form begins with the missed lesson's time, an hour long");
    await page.fill("#mk-end", "09:00"); await page.click("#mk-do");
    ok(/end after it starts/.test(await page.locator("#mk-err").innerText()) && (await calls(page, "staff_book_makeup")).length === 0, tag + "ending before it starts: refused in words, nothing sent");
    if (phone) ok(await noOverflow(page), tag + "the booking form fits at 390px");
    if (SC) await page.screenshot({ path: path.join(SC, "makeups-book-" + mode + ".png") });
    await page.fill("#mk-end", "11:30"); await page.selectOption("#mk-tutor", "t2"); await page.click("#mk-do");
    await page.waitForFunction(() => !document.querySelector("#mk-sheet.on"));
    const sent = await calls(page, "staff_book_makeup");
    ok(sent.length === 1 && sent[0].p_credit === "cr1" && sent[0].p_start === "10:00" && sent[0].p_end === "11:30" && sent[0].p_tutor === "t2" && /^\d{4}-\d{2}-\d{2}$/.test(sent[0].p_date), tag + "one booking sent: credit, day, times and the chosen tutor");
    await page.waitForFunction(() => document.querySelectorAll(".mk-open").length === 2);
    ok(/Make-ups\s*2/.test((await page.locator("#ca-tabs").innerText()).replace(/\n/g, " ")), tag + "the badge drops to 2 and the booked credit leaves the owed list");
    // booked list and unbook
    await page.click('#mk-seg [data-f="booked"]'); await page.waitForFunction(() => document.querySelectorAll(".mk-open").length === 2);
    const bk = await page.locator(".mk-open", { hasText: "Kid One" }).first().innerText();
    ok(/Make-up .*Demo Tutor/.test(bk) && /Booked/.test(bk), tag + "a booked row shows its make-up lesson");
    await page.locator(".mk-open", { hasText: "Kid One" }).first().click(); await page.waitForSelector("#mk-sheet.on");
    ok(/Not billed/.test(await page.locator("#mk-sb").innerText()), tag + "the sheet says the make-up is not billed (no amount)");
    await page.click("#mk-unbook"); await page.click("#mk-do");
    ok(/Say why/.test(await page.locator("#mk-err").innerText()) && (await calls(page, "staff_unbook_makeup")).length === 0, tag + "removing a make-up needs a reason");
    await page.fill("#mk-reason", "Family cannot come"); await page.click("#mk-do");
    await page.waitForFunction(() => !document.querySelector("#mk-sheet.on"));
    const ub = await calls(page, "staff_unbook_makeup");
    ok(ub.length === 1 && ub[0].p_reason === "Family cannot come", tag + "unbooking sends the reason, once");
    // take back
    await page.click('#mk-seg [data-f="open"]'); await page.waitForFunction(() => document.querySelectorAll(".mk-open").length === 3);
    await page.locator(".mk-open", { hasText: "Kid Three" }).click(); await page.waitForSelector("#mk-sheet.on");
    await page.click("#mk-revoke"); await page.fill("#mk-reason", "ab"); await page.click("#mk-do");
    ok(/at least 3 letters/.test(await page.locator("#mk-err").innerText()), tag + "a too-short reason is refused in words");
    await page.fill("#mk-reason", "Given by mistake"); await page.click("#mk-do");
    await page.waitForFunction(() => document.querySelectorAll(".mk-open").length === 2);
    ok((await calls(page, "staff_revoke_credit")).length === 1, tag + "taking a credit back sends one call and the row leaves the list");
    // give a credit
    await page.click("#mk-give"); await page.waitForSelector("#mk-give-modal.on");
    await page.click("#mg-save"); ok(/Choose the student/.test(await page.locator("#mg-msg").innerText()), tag + "giving a credit needs a student");
    await page.locator(".mk-pick", { hasText: "Kid Three" }).click();
    await page.click("#mg-save"); ok(/Say why/.test(await page.locator("#mg-msg").innerText()), tag + "…and a reason");
    if (phone) ok(await noOverflow(page), tag + "the give-a-credit form fits at 390px");
    if (SC) await page.screenshot({ path: path.join(SC, "makeups-give-" + mode + ".png") });
    await page.fill("#mg-reason", "Goodwill make-up"); await page.click("#mg-save");
    await page.waitForFunction(() => !document.querySelector("#mk-give-modal.on"));
    const g = await calls(page, "staff_grant_credit");
    ok(g.length === 1 && g[0].p_student === "33333333-3333-4333-8333-333333333333" && g[0].p_reason === "Goodwill make-up" && g[0].p_lesson === null, tag + "one grant sent with the student and the reason");
    await page.waitForFunction(() => document.querySelectorAll(".mk-open").length === 3);
    // back to Lessons
    await page.click('#ca-tabs [data-t="lessons"]');
    ok(await page.locator("#ca").isVisible() && await page.locator("#mk").isHidden(), tag + "back to Lessons: the list returns, Make-ups steps aside");
    ok(!/tab=makeups/.test(page.url()), tag + "…and the address forgets the tab");
    ok(errs.length === 0, tag + "no console errors" + (errs.length ? " " + errs.join(" | ") : ""));
    await ctx.close();
  }
  // the deep link from a student's sheet: only that student
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", STAFF)] });
    await page.goto(BASE + "centre-attendance.html?id=c1&tab=makeups&student=11111111-1111-4111-8111-111111111111"); await page.waitForSelector(".mk-open");
    ok(await page.locator("#mk").isVisible() && await page.locator("#ca").isHidden(), "the link opens the Make-ups tab straight away");
    ok(await page.locator(".mk-open").count() === 1 && /Showing Kid One only/.test(await page.locator("#mk-who").innerText()), "…showing only that student, and saying so");
    await page.click("#mk-all"); await page.waitForFunction(() => document.querySelectorAll(".mk-open").length === 3);
    ok(!/student=/.test(page.url()), "'Show everyone' clears the filter"); await ctx.close(); }
  // staff who may only look
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "staff", ["manage_students"])], look: true });
    await page.goto(BASE + "centre-attendance.html?id=c1&tab=makeups"); await page.waitForSelector(".mk-open");
    ok(await page.locator("#mk-give").isHidden(), "look-only: no Give a credit button");
    await page.locator(".mk-open").first().click(); await page.waitForSelector("#mk-sheet.on");
    ok(await page.locator("#mk-book, #mk-revoke, #mk-unbook").count() === 0 && /Ask the centre owner/.test(await page.locator("#mk-sb").innerText()), "look-only: the sheet has no buttons and says who to ask"); await ctx.close(); }
  // the owner with Charges as well: all three tabs live together
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], charges: true });
    await page.goto(BASE + "centre-attendance.html?id=c1"); await page.waitForSelector("#ca-tabs:not([hidden])");
    ok(await page.locator("#ca-tab-charges").isVisible() && await page.locator("#ca-tab-makeups").isVisible(), "owner: Lessons, Charges and Make-ups all show");
    await page.click("#ca-tab-makeups"); await page.waitForSelector(".mk-open");
    ok(await page.locator("#cg").isHidden() && await page.locator("#ca").isHidden(), "Make-ups open: Lessons and Charges are both out of the way");
    await page.click("#ca-tab-charges");
    ok(await page.locator("#mk").isHidden() && await page.locator("#cg").isVisible() && (await page.locator("#ca-tab-makeups").getAttribute("aria-pressed")) === "false", "switching to Charges closes Make-ups");
    await page.click("#ca-tab-makeups"); await page.click('#ca-tabs [data-t="lessons"]');
    ok(await page.locator("#ca").isVisible() && await page.locator("#mk").isHidden() && await page.locator("#cg").isHidden(), "switching to Lessons closes Make-ups"); await ctx.close(); }
  // a stale list: somebody else booked it first
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], bookError: "ALREADY_BOOKED: a make-up lesson is already booked with this credit" });
    await page.goto(BASE + "centre-attendance.html?id=c1&tab=makeups"); await page.waitForSelector(".mk-open");
    await page.locator(".mk-open", { hasText: "Kid One" }).click(); await page.click("#mk-book"); await page.click("#mk-do");
    await page.waitForFunction(() => !document.querySelector("#mk-sheet.on"));
    ok((await calls(page, "staff_credit_list")).length >= 2, "a refusal that means 'someone got there first' refreshes the list"); await ctx.close(); }
  // nobody else sees a tab: a tutor / a database without the migration / a centre that never switched it on
  for (const [label, cfg] of [["a tutor", { members: [M(SOLO, "owner"), M(C, "tutor")], listError: "NOT_FOUND" }],
                              ["an older database", { members: [M(SOLO, "owner"), M(C, "owner")], listError: { code: "PGRST202", message: "Could not find the function" } }],
                              ["a centre that never used credits", { members: [M(SOLO, "owner"), M(C, "owner")], empty: true, enabled: false }]]) {
    const { ctx, page, errs } = await open(browser, cfg);
    await page.goto(BASE + (label === "a tutor" ? "tutor.html" : "centre-attendance.html") + "?id=c1"); await page.waitForTimeout(900);
    ok(await page.locator("#ca-tab-makeups").count() === 0 || await page.locator("#ca-tab-makeups").isHidden(), label + ": no Make-ups tab");
    ok(errs.length === 0, label + ": no console errors" + (errs.length ? " " + errs.join(" | ") : "")); await ctx.close();
  }
  // credits switched on but nothing owed: the tab shows with a friendly empty state
  { const { ctx, page } = await open(browser, { members: [M(SOLO, "owner"), M(C, "owner")], empty: true, enabled: true });
    await page.goto(BASE + "centre-attendance.html?id=c1&tab=makeups"); await page.waitForSelector("#mk-list .ca-empty");
    ok(/No make-ups owed/.test(await page.locator("#mk-list").innerText()), "switched on but nothing owed: a friendly empty state"); await ctx.close(); }
  await browser.close();
  console.log(fails ? fails + " FAILED" : "all passed"); process.exit(fails ? 1 : 0);
})();
