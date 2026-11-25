// Browser check for the sign-up password hint (not part of CI: needs Playwright + `python3 tests/server.py 8765`).
//   node tests/password-hint.check.js [screenshot-dir]
// Supabase is stubbed (tests/supabase-stub-signed-out.js): no network, no accounts.
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, URL = "http://127.0.0.1:8765/login.html";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-out.js"), "utf8");
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
const LABELS = ["At least 8 characters", "A lowercase letter", "An uppercase letter", "A number", "A symbol"];
// [password, which lines are met (length, lower, upper, digit, symbol)]
const CASES = [
  ["", [0, 0, 0, 0, 0]], ["abcdefgh", [1, 1, 0, 0, 0]], ["ABCDEFGH", [1, 0, 1, 0, 0]], ["12345678", [1, 0, 0, 1, 0]],
  ["!!!!!!!!", [1, 0, 0, 0, 1]], ["aB1!", [0, 1, 1, 1, 1]], ["Abcdef1!", [1, 1, 1, 1, 1]],
];
const rows = (page) => page.$$eval("#pw-hint li", (l) => l.map((x) => ({ cls: x.className, text: x.querySelector(".pw-txt").textContent, color: getComputedStyle(x).color, ico: getComputedStyle(x.querySelector(".pw-ico"), "::before").content })));
(async () => {
  const browser = await chromium.launch();
  for (const [name, vp] of [["desktop", { width: 1280, height: 800 }], ["phone", { width: 390, height: 844 }]]) {
    const ctx = await browser.newContext({ viewport: vp, deviceScaleFactor: 1 });
    await ctx.route(/supabase-2\.\d+\.\d+\.js/, (r) => r.fulfill({ contentType: "application/javascript", body: STUB }));
    const page = await ctx.newPage(); const errs = []; page.on("pageerror", (e) => errs.push(e.message));
    await page.goto(URL); await page.click("#tab-up");
    const h0 = await page.evaluate(() => document.getElementById("pw-hint").offsetHeight);
    ok(await page.getAttribute("#pw-hint", "aria-live") === "polite", name + ": aria-live polite");
    for (const [pw, met] of CASES) {
      await page.fill("#pw", pw);
      const r = await rows(page);
      ok(r.length === 5 && r.every((x, i) => x.text === LABELS[i]), name + ": five labelled lines");
      ok(r.every((x, i) => x.cls.includes("met") === !!met[i] && !x.cls.includes("bad")), name + ": " + JSON.stringify(pw) + " ticks " + met.join(""));
      ok(r.every((x, i) => met[i] ? x.ico.includes("\u2713") : x.ico === "none" || x.ico === "normal"), name + ": tick glyph only on met lines");
      ok((await page.evaluate(() => document.getElementById("pw-hint").offsetHeight)) === h0, name + ": no layout jump");
      if (SC) await page.screenshot({ path: path.join(SC, name + "-" + (pw ? "pw-" + met.join("") : "empty") + ".png") });
    }
    const metCol = (await rows(page))[0].color; ok(metCol === "rgb(15, 118, 110)", name + ": met colour is --accent teal " + metCol);
    await page.fill("#pw", ""); const grey = (await rows(page))[0].color; ok(grey !== "rgb(180, 67, 47)" && grey !== metCol, name + ": unmet is neutral grey " + grey);
    // submit with a weak password: blocked on the page, nothing sent
    await page.fill("#email", "dummy@example.com"); await page.fill("#pw", "Abcdefg1"); await page.click("#go");
    await page.waitForTimeout(200);
    ok((await page.textContent("#msg")).includes("Your password is missing: a symbol"), name + ": submit explains what is missing");
    const sr = await rows(page);
    ok(sr.map((x) => x.cls).join("|") === "met|met|met|met|bad" && sr[4].color === "rgb(180, 67, 47)", name + ": after submit unmet line is owed red, met stay teal");
    if (SC) await page.screenshot({ path: path.join(SC, name + "-submit-unmet.png") });
    await page.fill("#pw", "Abcdefg1!"); ok((await rows(page)).every((x) => !x.cls.includes("bad")), name + ": red clears when typing resumes");
    await page.fill("#pw", "Abcdefg1");
    ok(!(await page.evaluate(() => window.__signedUp)), name + ": nothing sent to Supabase when weak");
    const sw = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
    ok(sw, name + ": no horizontal scroll"); ok(errs.length === 0, name + ": no page errors " + errs.join(";"));
    await ctx.close();
  }
  await browser.close(); console.log(fails ? fails + " FAILED" : "all passed"); process.exit(fails ? 1 : 0);
})();
