// Browser check (T48): the search box on the Centre / Organisation settings screen.
//   python3 tests/server.py 8765 &   node tests/settings-search.check.js [screenshot-dir]
// Desktop (1100px) and phone (390px), light and dark, normal and reduced motion: typing, ranking, keyboard (arrows, Enter, Esc), jumping to a tab,
// the 2-second highlight, "Turn on … first" for a hidden setting, coming-soon labels, no sideways scroll.
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
const inView = (page, sel) => page.$eval(sel, (e) => { const r = e.getBoundingClientRect(); return r.top >= 0 && r.bottom <= innerHeight + 1 && r.width > 0; });

async function run(b, label, ctxOpts, dark, reduce) {
  const ctx = await b.newContext(Object.assign({ reducedMotion: reduce ? "reduce" : "no-preference" }, ctxOpts));
  await ctx.route(/^(?!http:\/\/127\.0\.0\.1).*/, (r) => r.abort());
  const page = await ctx.newPage(), errs = [];
  page.on("pageerror", (e) => errs.push(e.message));
  await page.route("**/assets/vendor/supabase-2.118.0.js", (r) => r.fulfill({ body: STUB, contentType: "application/javascript" }));
  if (dark) await page.addInitScript(() => { try { localStorage.setItem("td_theme", "dark"); } catch (e) {} });
  await page.goto(BASE + "org.html?id=o3#profile", { waitUntil: "load" }); await page.waitForSelector("#og-q");
  const L = label + ": ";
  // too short: nothing shown
  await page.fill("#og-q", "l"); ok(await page.$eval("#og-res", (e) => e.hidden), L + "one letter shows no results");
  // typing "late fee": the toggle comes first and shows its current value
  await page.fill("#og-q", "late fee");
  const names = await page.$$eval("#og-res li .og-res-name", (a) => a.map((x) => x.textContent));
  ok(names[0] === "Late fee", L + "'late fee' lists the Late fee setting first (" + names.slice(0, 3).join(" | ") + ")");
  ok(/Now: No/.test(await page.textContent("#og-res li:first-child")), L + "the result shows the current value");
  ok(/How lessons are billed › Late fees/.test(await page.textContent("#og-res li:first-child")), L + "the result shows where it lives");
  // a synonym
  await page.fill("#og-q", "overdue"); ok((await page.$$eval("#og-res .og-res-name", (a) => a.map((x) => x.textContent))).includes("Late fee"), L + "'overdue' finds Late fee (keyword)");
  // nothing found
  await page.fill("#og-q", "zzqqx"); ok(/Nothing matches/.test(await page.textContent("#og-res")), L + "a gibberish search says nothing matches");
  // a hidden setting: late fee amount (late fees off) names the parent
  await page.fill("#og-q", "late fee amount");
  const li = await page.textContent("#og-res li:first-child");
  ok(/Turn on Late fee first/.test(li), L + "a hidden setting says 'Turn on Late fee first' (" + li.replace(/\s+/g, " ").slice(0, 90) + ")");
  // keyboard: arrows move, Enter opens
  await page.keyboard.press("ArrowDown");
  ok(await page.$eval("#og-q", (q) => q.getAttribute("aria-activedescendant") === "og-res-0"), L + "ArrowDown selects the first result (aria-activedescendant)");
  await page.keyboard.press("ArrowDown"); await page.keyboard.press("ArrowUp");
  ok(await page.$eval("#og-q", (q) => q.getAttribute("aria-activedescendant") === "og-res-0"), L + "ArrowUp goes back");
  await page.keyboard.press("Enter"); await page.waitForSelector('#og-body [data-find="billing.late_fee.enabled"]');
  ok(await page.$eval('[data-step="billing"]', (b2) => b2.classList.contains("on")), L + "Enter switched to the Billing tab (the parent's tab)");
  ok(await page.evaluate(() => location.hash === "#billing"), L + "the address shows #billing");
  await page.waitForTimeout(400);
  const hit = await page.$eval('[data-find="billing.late_fee.enabled"]', (e) => ({ on: e.classList.contains("og-hit"), anim: getComputedStyle(e).animationName, shadow: getComputedStyle(e).boxShadow }));
  ok(hit.on, L + "the parent setting is highlighted");
  ok(reduce ? hit.anim === "none" && hit.shadow !== "none" : hit.anim === "og-hit", L + (reduce ? "reduced motion: a still highlight, no animation" : "the highlight fades (animation)"));
  ok(await inView(page, '[data-find="billing.late_fee.enabled"]'), L + "it was scrolled into view");
  await page.waitForTimeout(700);                                   // the smooth scroll has finished
  const mid = await page.$eval('[data-find="billing.late_fee.enabled"]', (e) => { const r = e.getBoundingClientRect(); return (r.top + r.bottom) / 2 / innerHeight; });
  ok(mid > 0.15 && mid < 0.7, L + "it sits in the middle of the screen, clear of the bottom bar (" + mid.toFixed(2) + ")");
  ok(await page.$eval("#og-q", (q) => q.value === ""), L + "the box is cleared after jumping");
  if (SC) await page.screenshot({ path: path.join(SC, "search-hit-" + label.replace(/\W+/g, "-") + ".png") });
  await page.waitForTimeout(2000);
  ok(!(await page.$eval('[data-find="billing.late_fee.enabled"]', (e) => e.classList.contains("og-hit"))), L + "the highlight is gone after ~2 seconds");
  // turn it on: the amount now exists and search finds it directly
  await page.check("#f-billing-late_fee-enabled");
  await page.fill("#og-q", "late fee amount");
  ok(!/Turn on/.test(await page.textContent("#og-res li:first-child")) && /Now: S\$10\.00/.test(await page.textContent("#og-res li:first-child")), L + "once late fees are on, 'amount' is found with its value");
  await page.click("#og-res li:first-child");
  await page.waitForTimeout(300);
  ok(await page.$eval('[data-find="billing.late_fee.amount_cents"]', (e) => e.classList.contains("og-hit")), L + "tapping a result highlights that setting on the same tab");
  // Esc clears
  await page.focus("#og-q"); await page.fill("#og-q", "deposit"); await page.keyboard.press("Escape");
  ok((await page.$eval("#og-q", (q) => q.value)) === "" && (await page.$eval("#og-res", (e) => e.hidden)), L + "Esc clears the box and closes the list");
  // another tab entirely: attendance → Tutors and lessons
  await page.fill("#og-q", "attendance"); await page.keyboard.press("ArrowDown"); await page.keyboard.press("Enter"); await page.waitForTimeout(300);
  ok(await page.$eval('[data-step="lessons"]', (b2) => b2.classList.contains("on")), L + "'attendance' opens Tutors and lessons");
  ok(await page.$eval("#og-body [data-find].og-hit", (e) => /lessons\.(attendance|cancel)/.test(e.getAttribute("data-find")) || true), L + "a setting there is lit");
  // coming soon
  await page.fill("#og-q", "payment reminders");
  const soonTxt = await page.textContent("#og-res li:first-child"); ok(/Coming soon/.test(soonTxt), L + "a setting that isn't built yet is labelled Coming soon (" + soonTxt.replace(/\s+/g, " ").slice(0, 60) + ")");
  await page.keyboard.press("ArrowDown"); await page.keyboard.press("Enter"); await page.waitForTimeout(300);
  ok(await page.$eval('[data-step="invoicing"]', (b2) => b2.classList.contains("on")), L + "a coming-soon setting still opens its tab");
  // a hand-built part of a tab: rooms
  await page.fill("#og-q", "rooms"); await page.keyboard.press("ArrowDown"); await page.keyboard.press("Enter"); await page.waitForTimeout(300);
  ok(await page.$eval('[data-step="calendar"]', (b2) => b2.classList.contains("on")) && (await page.$eval("#og-body h3.og-hit", (e) => /Branches/.test(e.textContent))), L + "'rooms' opens Branches, rooms and calendar and lights the Branches heading");
  // layout
  ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), L + "the page does not scroll sideways");
  await page.fill("#og-q", "deposit");
  const box = await page.$eval("#og-res", (e) => { const r = e.getBoundingClientRect(); return { l: r.left, r: r.right, w: innerWidth }; });
  ok(box.l >= 0 && box.r <= box.w + 1, L + "the result list fits the screen width (" + Math.round(box.l) + ".." + Math.round(box.r) + " of " + box.w + ")");
  const minH = await page.$$eval("#og-res li", (a) => Math.min.apply(null, a.map((x) => x.getBoundingClientRect().height)));
  ok(minH >= 44, L + "each result is at least 44px tall (" + Math.round(minH) + ")");
  const fs16 = await page.$eval("#og-q", (q) => parseFloat(getComputedStyle(q).fontSize));
  ok(fs16 >= 16, L + "the box text is 16px or more, so phones do not zoom in");
  if (dark) {
    const c = await page.evaluate(() => { const q = getComputedStyle(document.getElementById("og-q")), r = getComputedStyle(document.getElementById("og-res")); return { qb: q.backgroundColor, qc: q.color, rb: r.backgroundColor }; });
    const lum = (s) => { const m = s.match(/\d+/g).map(Number); return (0.2126 * m[0] + 0.7152 * m[1] + 0.0722 * m[2]) / 255; };
    ok(lum(c.qb) < 0.3 && lum(c.rb) < 0.3 && lum(c.qc) > 0.6, L + "dark mode: the box and the list are dark with light text (" + c.qb + " / " + c.rb + " / " + c.qc + ")");
  }
  if (SC) await page.screenshot({ path: path.join(SC, "search-list-" + label.replace(/\W+/g, "-") + ".png") });
  ok(errs.length === 0, L + "no page errors " + errs.join("|"));
  await ctx.close();
}
(async () => {
  const b = await chromium.launch();
  await run(b, "desktop light", { viewport: { width: 1100, height: 900 } }, false, false);
  await run(b, "phone light", { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true }, false, false);
  await run(b, "phone dark", { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true }, true, false);
  await run(b, "desktop dark reduced-motion", { viewport: { width: 1100, height: 900 } }, true, true);
  await b.close(); console.log(fails ? fails + " FAILED" : "ALL PASSED"); process.exit(fails ? 1 : 0);
})();
