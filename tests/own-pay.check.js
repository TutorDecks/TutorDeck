// Browser check for "a tutor sees their own pay" (T4 S7b): the My lessons pay line, the Your pay page and menu entry, the Settings tick box and the Home combined
// lines for a tutor who also has students of their own. Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
//   node tests/own-pay.check.js [screenshot-dir]
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

// the page-side stand-in for the database's answers; cfg.pay = { modes, month, adjs, lessons, mine }, cfg.role = the memberships
function override(cfg) {
  window.__calls = [];
  window.__override = function (c) {
    var origRpc = c.rpc.bind(c), origFrom = c.from.bind(c), P = cfg.pay || {};
    var iso = function (n) { var d = new Date(); d.setDate(d.getDate() + n); var p = function (x) { return (x < 10 ? "0" : "") + x; }; return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()); };
    c.rpc = function (n, a) {
      window.__calls.push([n, a || null]);
      var res = function (d) { return Promise.resolve({ data: d, error: null }); }, err = function (m) { return Promise.resolve({ data: null, error: { message: m } }); };
      if (n === "tutor_my_pay_modes") return P.noFn ? err("function not found") : (P.modes ? res(P.modes) : err("NOT_FOUND"));
      if (n === "tutor_my_pay_month") return P.noFn ? err("function not found") : res(typeof P.month === "function" ? P.month(a) : (P.month || []));
      if (n === "tutor_my_pay_adjustments") return res(P.adjs || []);
      if (n === "tutor_my_pay") return res(P.lessons || []);
      if (n === "tutor_my_lessons") return res((P.mine || []).map(function (x) {
        return Object.assign({ lesson_id: x[0], org_id: "o2", org_name: "Opus Tuition", student_id: "s" + x[0], student_name: x[1], student_level: "P5", parent_contact: null, lesson_date: iso(x[2]),
          start_time: "16:00:00", end_time: "17:00:00", subject: "Math", status: "done", attendance: "attended", trial: false, session_id: null, topics: null, homework: null, remarks: null,
          remarks_due_at: null, can_mark: false, can_note: false, can_cancel: false, remarks_required: false, can_flag_trial: false, tutor_sets_compensation: false, charge_pending: false }, x[3] || {});
      }));
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
  await page.goto(BASE + url, { waitUntil: "load" }); await page.waitForTimeout(1500);
  return { ctx, page, errs };
}
const today = new Date(), pad = (x) => (x < 10 ? "0" : "") + x, ymd = (d) => d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate());
const first = new Date(today.getFullYear(), today.getMonth(), 1), last = new Date(today.getFullYear(), today.getMonth() + 1, 0);
const MONTH = { org_id: "o2", org_name: "Opus Tuition", period_from: ymd(first), period_to: ymd(last), pay_view: "per_lesson_and_total", lessons: 4, earned_cents: 20000, adjustments_cents: 1000,
  carry_cents: 0, total_cents: 21000, pending_lessons: 2, run_recorded: false };
const PAY = {
  modes: [{ org_id: "o2", org_name: "Opus Tuition", pay_view: "per_lesson_and_total" }],
  month: [MONTH],
  adjs: [{ org_id: "o2", org_name: "Opus Tuition", effective_on: ymd(today), kind: "bonus", adjustment_cents: 1500, label: "Great month" },
         { org_id: "o2", org_name: "Opus Tuition", effective_on: ymd(today), kind: "deduction", adjustment_cents: -500, label: "Lost textbook" }],
  lessons: [{ org_id: "o2", org_name: "Opus Tuition", lesson_id: "a", lesson_date: ymd(today), pay_state: "amount", pay_cents: 4000 },
            { org_id: "o2", org_name: "Opus Tuition", lesson_id: "b", lesson_date: ymd(today), pay_state: "pending", pay_cents: null }],
  mine: [["a", "Ann Tan", 0, { can_mark: false }], ["b", "Ben Lim", 0, { can_mark: false }], ["c", "Cy Ong", 0, { can_mark: false }]]
};
const centreTutor = (n, pay) => ({ role: { memberships: [{ org_id: "o2", user_id: "u1", role: "tutor", status: "active", organisations: { id: "o2", kind: "centre", trading_name: "Opus Tuition" } },
  { org_id: "o1", user_id: "u1", role: "owner", status: "active", organisations: { id: "o1", kind: "solo", trading_name: "Mei Tuition" } }], studentCount: n }, pay });
const SOLO_ONLY = { role: { memberships: [{ org_id: "o1", user_id: "u1", role: "owner", status: "active", organisations: { id: "o1", kind: "solo", trading_name: "Mei Tuition" } }] } };
const callsOf = (page, re) => page.evaluate((s) => window.__calls.filter((c) => new RegExp(s).test(c[0])).length, re.source);
const noSideways = (page) => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);

(async () => {
  const b = await chromium.launch();
  // ---------- A. My lessons: the pay line and each lesson (a tutor-only login, 390px)
  for (const [vp, theme] of [["phone", "light"], ["phone", "dark"], ["desktop", "light"]]) {
    const { ctx, page, errs } = await open(b, vp, theme, centreTutor(0, PAY), "tutor"); const tag = "My lessons " + vp + "/" + theme;
    const card = await page.textContent(".tt-paycard");
    ok(/S\$210\.00/.test(card) && /Estimate until the pay run is confirmed/.test(card) && /2 lessons pending/.test(card), tag + ": your pay line says the total, that it is an estimate, and how many are pending (\"" + card.replace(/\s+/g, " ").trim() + "\")");
    const rowA = await page.textContent('.tt-row[data-id="a"]'), rowB = await page.textContent('.tt-row[data-id="b"]'), rowC = await page.textContent('.tt-row[data-id="c"]');
    ok(/S\$40\.00 est\./.test(rowA), tag + ": a released lesson shows its amount");
    ok(/Pay pending/.test(rowB) && !/S\$/.test(rowB), tag + ": a held lesson says only \"Pay pending\", no amount");
    ok(!/S\$|pending/i.test(rowC.replace(/Cy Ong|P5|Math/g, "")), tag + ": a lesson with no pay line shows nothing about pay");
    const all = await page.evaluate(() => document.body.innerText);
    ok(!/\b(rate|fee|invoice|percent|paid by|parent paid|outstanding)\b/i.test(all.replace(/Your pay|Estimate until/g, "")), tag + ": no word of a rate, fee, invoice, percentage or what a family paid on the page");
    ok(errs.length === 0, tag + ": no script errors" + (errs.length ? " " + errs.join("|") : ""));
    ok(await noSideways(page), tag + ": no sideways scroll");
    if (vp === "phone" && theme === "light") {
      await page.click('.tt-row[data-id="a"]'); await page.waitForTimeout(350);
      ok(/Your pay\s*S\$40\.00\s*estimate/.test((await page.textContent("#ts-body")).replace(/\s+/g, " ")), tag + ": the sheet shows Your pay S$40.00 estimate");
      if (SC) await page.screenshot({ path: path.join(SC, "own-pay-sheet-phone.png") });
      await page.keyboard.press("Escape"); await page.waitForTimeout(200);
      await page.click('.tt-row[data-id="b"]'); await page.waitForTimeout(350);
      const body = (await page.textContent("#ts-body")).replace(/\s+/g, " ");
      ok(/Your pay\s*Pending/.test(body) && !/Pending\s*S\$/.test(body), tag + ": a held lesson's sheet says Pending, with no amount and no reason");
      await page.keyboard.press("Escape"); await page.waitForTimeout(500);       // let the sheet finish closing before looking at the page
    }
    if (SC) await page.screenshot({ path: path.join(SC, `own-pay-lessons-${vp}-${theme}.png`), fullPage: true });
    await axeCheck(page, tag);
    // the menu: a tutor-only login gets three entries (My lessons, Schedule, Your pay), the last with its own icon
    const nav = await page.$$eval(vp === "phone" ? ".tabbar a" : ".tn-links a", (e) => e.map((x) => x.textContent.trim()));
    ok(nav.join(",") === "My lessons,Schedule,Your pay", tag + ": menu is My lessons, Schedule, Your pay (" + nav.join(",") + ")");
    const icons = await page.$$eval(vp === "phone" ? ".tabbar a" : ".tn-links a", (e) => e.map((x) => x.querySelector("svg").innerHTML));
    ok(icons.length === 3 && new Set(icons).size === 3 && /<rect/.test(icons[2]) && !/M19 7V4/.test(icons[2]), tag + ": Your pay has its own icon (not the Money wallet, not the calendar)");
    await ctx.close();
  }
  // ---------- A2. the centre doesn't show pay: nothing at all (no line, no menu entry, no per-lesson call)
  for (const off of [{ modes: [{ org_id: "o2", org_name: "Opus Tuition", pay_view: "off" }], month: [] }, { noFn: true }]) {
    const { ctx, page } = await open(b, "phone", "light", centreTutor(0, Object.assign({}, PAY, off)), "tutor");
    ok(!(await page.isVisible(".tt-paycard")) && !/Pay pending|est\./.test(await page.textContent("#tt-lists")), "pay off / not installed: no pay line and no amounts on My lessons");
    const nav = await page.$$eval(".tabbar a", (e) => e.map((x) => x.textContent.trim()));
    ok(nav.join(",") === "My lessons,Schedule", "pay off / not installed: no Your pay entry (" + nav.join(",") + ")");
    ok((await callsOf(page, /^tutor_my_pay$/)) === 0, "pay off: the per-lesson function is not even asked");
    await ctx.close();
  }
  // ---------- B. the Your pay page
  for (const [vp, theme] of [["phone", "light"], ["phone", "dark"], ["desktop", "light"]]) {
    const { ctx, page, errs } = await open(b, vp, theme, centreTutor(0, PAY), "my-pay"); const tag = "Your pay " + vp + "/" + theme;
    ok(/\/my-pay$/.test(page.url()), tag + ": a tutor-only login may open it (no redirect)");
    ok((await page.textContent(".mp-total")).trim() === "S$210.00", tag + ": total S$210.00");
    ok(/Estimate until the pay run is confirmed/.test(await page.textContent(".mp-est")), tag + ": labelled an estimate");
    const lines = (await page.$$eval(".mp-lines li", (e) => e.map((x) => x.textContent.replace(/\s+/g, " ").trim())));
    ok(lines.length === 4 && /Earned this period\s*S\$200\.00/.test(lines[0]) && /Great month.*\+S\$15\.00/.test(lines[1]) && /Lost textbook.*−S\$5\.00/.test(lines[2]) && /Total\s*S\$210\.00/.test(lines[3]),
       tag + ": one line each, with the staff's label: " + JSON.stringify(lines));
    ok(/2 lessons pending/.test(await page.textContent(".mp-pend")) && !/S\$/.test(await page.textContent(".mp-pend")), tag + ": pending is a count, never an amount");
    const les = await page.$$eval(".mp-les", (e) => e.map((x) => x.textContent.replace(/\s+/g, " ").trim()));
    ok(les.length === 2 && /Ann Tan.*S\$40\.00/.test(les[0]) && /Ben Lim.*Pending/.test(les[1]) && !/S\$/.test(les[1]), tag + ": lessons list: amount for the released, Pending for the held: " + JSON.stringify(les));
    const all = await page.evaluate(() => document.body.innerText);
    ok(!/\b(rate|fee|invoice|percent|outstanding)\b/i.test(all.replace(/Estimate until/g, "")), tag + ": no word of a rate, fee, invoice or percentage");
    ok(errs.length === 0, tag + ": no script errors" + (errs.length ? " " + errs.join("|") : ""));
    ok(await noSideways(page), tag + ": no sideways scroll");
    if (SC) await page.screenshot({ path: path.join(SC, `own-pay-page-${vp}-${theme}.png`), fullPage: true });
    await axeCheck(page, tag);
    if (vp === "phone" && theme === "light") {
      const lab0 = await page.textContent("#mp-label");
      await page.click("#mp-prev"); await page.waitForTimeout(500);
      const lab1 = await page.textContent("#mp-label"), asked = await page.evaluate(() => window.__calls.filter((c) => c[0] === "tutor_my_pay_month").map((c) => c[1] && c[1].p_month));
      ok(lab0 !== lab1 && asked.length >= 2 && asked[asked.length - 1] < asked[0], tag + ": the arrow asks for the month before (" + lab0 + " → " + lab1 + ")");
      const nav = await page.$$eval(".tabbar a", (e) => e.map((x) => x.textContent.trim() + (x.classList.contains("on") ? "*" : "")));
      ok(nav.join(",") === "My lessons,Schedule,Your pay*", tag + ": the Your pay tab is the active one (" + nav.join(",") + ")");
    }
    await ctx.close();
  }
  { // a centre that shows totals only: no lessons list, no per-lesson call; and a confirmed pay run
    const pay = Object.assign({}, PAY, { modes: [{ org_id: "o2", org_name: "Opus Tuition", pay_view: "monthly_total" }], month: [Object.assign({}, MONTH, { pay_view: "monthly_total", run_recorded: true, pending_lessons: 0, carry_cents: 5000, total_cents: 26000 })] });
    const { ctx, page } = await open(b, "phone", "light", centreTutor(0, pay), "my-pay");
    ok(!(await page.$(".mp-les")) && (await callsOf(page, /^tutor_my_pay$/)) === 0, "totals-only centre: no lesson list and the per-lesson function is not asked");
    const lines = (await page.$$eval(".mp-lines li", (e) => e.map((x) => x.textContent.replace(/\s+/g, " ").trim())));
    ok(lines.some((l) => /Carried over from earlier\s*S\$50\.00/.test(l)) && /Pay run confirmed/.test(await page.textContent(".mp-est")) && !(await page.$(".mp-pend")), "carried-over line, \"Pay run confirmed\", no pending box");
    await ctx.close(); }
  { // pay off: a plain message, not a blank page
    const { ctx, page } = await open(b, "phone", "light", centreTutor(0, Object.assign({}, PAY, { month: [] })), "my-pay");
    ok(/doesn.t show tutors their own pay/.test(await page.textContent("#mp-body")), "pay off: Your pay page says so plainly");
    await ctx.close(); }
  // ---------- C. Settings: the tick box (a solo tutor who also teaches at a centre)
  { const { ctx, page } = await open(b, "phone", "light", centreTutor(4, PAY), "settings");
    ok(await page.isVisible("#combine-card") && /Include my centre earnings in my totals/.test(await page.textContent("#combine-card")), "Settings: the tick box is shown to a tutor who teaches at a centre");
    ok(!(await page.isChecked("#combine-pay")) && !(await page.isDisabled("#combine-pay")), "Settings: off by default, and usable when the centre shows pay");
    await page.check("#combine-pay"); await page.waitForTimeout(300);
    ok((await page.evaluate(() => localStorage.getItem("td:u1:combine_pay"))) === "1", "Settings: ticking it is remembered for this user");
    ok((await callsOf(page, /^tutor_my_pay(_month)?$/)) === 0, "Settings: it only reads which centres show pay; nothing about money is fetched");
    if (SC) await page.screenshot({ path: path.join(SC, "own-pay-settings-phone.png") });
    await axeCheck(page, "Settings tick box");
    await ctx.close(); }
  { const { ctx, page } = await open(b, "phone", "light", centreTutor(4, Object.assign({}, PAY, { modes: [{ org_id: "o2", org_name: "Opus Tuition", pay_view: "off" }] })), "settings");
    ok(await page.isDisabled("#combine-pay") && /Opus Tuition doesn.t show tutors their own pay/.test(await page.textContent("#combine-note")), "Settings: when the centre's choice is off the box is disabled and says why in plain words");
    await ctx.close(); }
  { const { ctx, page } = await open(b, "phone", "light", SOLO_ONLY, "settings");
    ok(!(await page.isVisible("#combine-card")) && (await callsOf(page, /^tutor_my_pay/)) === 0, "Settings: a plain solo tutor never sees the box and nothing is asked");
    await ctx.close(); }
  // ---------- D. Home: the combined lines
  const tick = () => { try { localStorage.setItem("td:u1:combine_pay", "1"); } catch (e) {} };
  for (const [vp, theme] of [["phone", "light"], ["phone", "dark"], ["desktop", "light"]]) {
    const { ctx, page, errs } = await open(b, vp, theme, centreTutor(4, PAY), "home", tick); const tag = "Home " + vp + "/" + theme;
    ok(await page.isVisible("#home-centre-pay"), tag + ": the combined lines show when ticked");
    const rows = await page.$$eval("#home-centre-pay .cp-row", (e) => e.map((x) => x.textContent.replace(/\s+/g, " ").trim()));
    ok(rows.length === 3 && /^My students/.test(rows[0]) && /^At Opus Tuition\s*\$210\.00$/.test(rows[1]) && /^Combined/.test(rows[2]), tag + ": My students, At Opus Tuition, Combined: " + JSON.stringify(rows));
    const money = (t) => Math.round(parseFloat(t.replace(/[^0-9.\-]/g, "")) * 100);
    const mine = money(rows[0].replace(/^My students/, "")), centre = money(rows[1].replace(/^At Opus Tuition/, "")), comb = money(rows[2].replace(/^Combined/, ""));
    const collected = money(await page.textContent("#k-collected"));
    ok(mine === collected, tag + ": My students equals the Dashboard's own Collected figure (" + mine + " = " + collected + ")");
    ok(comb === mine + centre && centre === 21000, tag + ": Combined = My students + the centre's estimate; the 2 pending lessons add nothing (" + comb + ")");
    ok(/2 lessons pending/.test(await page.textContent("#home-centre-pay .cp-pend")) && !/S\$/.test(await page.textContent("#home-centre-pay .cp-pend")), tag + ": pending is its own line, a count only");
    ok(/estimate until the pay run is confirmed/i.test(await page.textContent("#home-centre-pay .cp-note")), tag + ": labelled an estimate");
    ok(!/S\$210\.00/.test(await page.textContent("#k-pending") + await page.textContent("#k-collected") + await page.textContent("#mc-booked")), tag + ": the ledger's own figures (Collected, Owed, Booked) do not contain the centre pay");
    ok(errs.length === 0, tag + ": no script errors" + (errs.length ? " " + errs.join("|") : ""));
    ok(await noSideways(page), tag + ": no sideways scroll");
    if (SC) await page.screenshot({ path: path.join(SC, `own-pay-home-${vp}-${theme}.png`), fullPage: false });
    if (vp === "phone" && theme === "light") await axeCheck(page, tag);
    await ctx.close();
  }
  { const { ctx, page } = await open(b, "phone", "light", centreTutor(4, PAY), "home");    // not ticked
    ok(!(await page.isVisible("#home-centre-pay")) && (await callsOf(page, /^tutor_my_pay_month$/)) === 0, "Home: not ticked = no combined lines and the pay is not even fetched");
    await ctx.close(); }
  { const { ctx, page } = await open(b, "phone", "light", centreTutor(4, Object.assign({}, PAY, { modes: [{ org_id: "o2", org_name: "Opus Tuition", pay_view: "off" }], month: [] })), "home", tick);
    ok(!(await page.isVisible("#home-centre-pay")) && (await callsOf(page, /^tutor_my_pay_month$/)) === 0, "Home: ticked but the centre switched pay off = nothing shown, nothing fetched");
    await ctx.close(); }
  { const { ctx, page } = await open(b, "phone", "light", SOLO_ONLY, "home", tick);
    ok(!(await page.isVisible("#home-centre-pay")) && (await callsOf(page, /^tutor_my_pay/)) === 0, "Home: a solo tutor with no centre never sees it and no pay function is called");
    await ctx.close(); }
  { const pay = Object.assign({}, PAY, { month: [Object.assign({}, MONTH, { pending_lessons: 0, run_recorded: true, total_cents: 7000 }), Object.assign({}, MONTH, { org_name: "Second Centre", total_cents: 1000, pending_lessons: 1 })] });
    const { ctx, page } = await open(b, "phone", "light", centreTutor(4, pay), "home", tick);
    const rows = await page.$$eval("#home-centre-pay .cp-row", (e) => e.map((x) => x.textContent.replace(/\s+/g, " ").trim()));
    ok(rows.length === 4 && /^At Opus Tuition/.test(rows[1]) && /^At Second Centre/.test(rows[2]), "Home: two centres = two labelled lines: " + JSON.stringify(rows));
    await ctx.close(); }
  await b.close();
  console.log(fails ? "\n" + fails + " FAILED" : "\nall browser checks passed"); process.exit(fails ? 1 : 0);
})();
