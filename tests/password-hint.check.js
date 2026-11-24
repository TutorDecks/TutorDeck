// Browser check for the sign-up password hint (not part of CI: needs Playwright + `python3 tests/server.py 8765`).
//   node tests/password-hint.check.js [screenshot-dir]
// Supabase is stubbed (tests/supabase-stub-signed-out.js): no network, no accounts.
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, URL = "http://127.0.0.1:8765/login.html";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-out.js"), "utf8");
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
const CASES = [
  ["", "At least 8 characters, with a lowercase and an uppercase letter, a number and a symbol", false],
  ["abc", "Still needed: at least 8 characters (5 more), an uppercase letter, a number, a symbol (like ! ? # @)", false],
  ["ABCDEF1!", "Still needed: a lowercase letter", false],
  ["abcdef1!", "Still needed: an uppercase letter", false],
  ["Abcdefg!", "Still needed: a number", false],
  ["Abcdefg1", "Still needed: a symbol (like ! ? # @)", false],
  ["Abcdef1 ", "Still needed: a symbol (like ! ? # @)", false],
  ["Abcdef1!", "✓ Looks good", true],
];
(async () => {
  const browser = await chromium.launch();
  for (const [name, vp] of [["desktop", { width: 1280, height: 800 }], ["phone", { width: 390, height: 844 }]]) {
    const ctx = await browser.newContext({ viewport: vp, deviceScaleFactor: 1 });
    await ctx.route(/supabase-2\.\d+\.\d+\.js/, (r) => r.fulfill({ contentType: "application/javascript", body: STUB }));
    const page = await ctx.newPage(); const errs = []; page.on("pageerror", (e) => errs.push(e.message));
    await page.goto(URL); await page.click("#tab-up");
    for (const [pw, text, good] of CASES) {
      await page.fill("#pw", pw);
      const t = (await page.textContent("#pw-hint")).trim(), cls = await page.getAttribute("#pw-hint", "class");
      ok(t === text && cls.includes("ok") === good, name + ": " + JSON.stringify(pw) + " → " + t);
      if (SC && (pw === "" || pw === "abc" || pw === "Abcdef1!")) await page.screenshot({ path: path.join(SC, name + "-" + (pw || "empty") + ".png") });
    }
    // submit with a weak password: blocked on the page, nothing sent
    await page.fill("#email", "dummy@example.com"); await page.fill("#pw", "Abcdefg1"); await page.click("#go");
    await page.waitForTimeout(200);
    ok((await page.textContent("#msg")).includes("Your password is missing: a symbol"), name + ": submit explains what is missing");
    ok(!(await page.evaluate(() => window.__signedUp)), name + ": nothing sent to Supabase when weak");
    const sw = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
    ok(sw, name + ": no horizontal scroll"); ok(errs.length === 0, name + ": no page errors " + errs.join(";"));
    await ctx.close();
  }
  await browser.close(); console.log(fails ? fails + " FAILED" : "all passed"); process.exit(fails ? 1 : 0);
})();
