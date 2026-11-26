// Browser check for the import page (T33 step I0). Not part of CI: needs Playwright and `python3 tests/server.py 8765`.
//   node tests/import-page.check.js [screenshot-dir]
// Uses the Supabase stub (tests/supabase-stub-signed-in.js): no network. Proves: owner sees templates + upload + report + summary,
// staff / tutor / solo see nothing, and no request leaves the page while files are checked.
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path"), os = require("os");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
const AXE = (() => { try { return fs.readFileSync(path.join(ROOT, "tests/node_modules/axe-core/axe.min.js"), "utf8"); } catch (e) { return null; } })();
const IC = require("../assets/js/import-core.js"), { generate } = require("./fixtures/make-import-fixture.js");
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };

const STUB_PLUS = STUB + `;(function(){var o=window.supabase.createClient;window.supabase.createClient=function(){var c=o.apply(this,arguments);
  if(window.__orgRole){var of=c.from;c.from=function(t){var q=of.apply(c,arguments);if(t==="memberships"){var ms=q.maybeSingle;q.maybeSingle=function(){return ms().then(function(x){return {data:x.data?Object.assign({},x.data,{role:window.__orgRole}):null,error:null};});};}return q;};}
  return c;};})();`;

function files(dir, g) { return Object.keys(g.files).map((f) => { const p = path.join(dir, f); fs.writeFileSync(p, g.files[f]); return p; }); }

async function open(browser, { vp = "desktop", theme = "light", role = null, url }) {
  const ctx = await browser.newContext(Object.assign(vp === "phone" ? { viewport: { width: 390, height: 844 }, isMobile: true, deviceScaleFactor: 2 } : { viewport: { width: 1280, height: 900 } }, { acceptDownloads: true }));
  await ctx.grantPermissions(["clipboard-read", "clipboard-write"], { origin: "http://127.0.0.1:8765" }).catch(() => {});
  await ctx.addInitScript((a) => { try { localStorage.setItem("td_theme", a[0]); localStorage.setItem("td_tip_client-view", "1"); } catch (e) {} window.__orgRole = a[1]; }, [theme, role]);
  await ctx.route(/^(?!http:\/\/127\.0\.0\.1).*/, (r) => r.abort());
  const page = await ctx.newPage(), log = { errs: [], req: [] };
  await page.route("**/assets/vendor/supabase-2.118.0.js", (r) => r.fulfill({ body: STUB_PLUS, contentType: "application/javascript" }));
  page.on("pageerror", (e) => log.errs.push("script error: " + e.message));
  page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource/.test(m.text())) log.errs.push("console: " + m.text()); });
  page.on("request", (r) => log.req.push({ url: r.url(), post: r.postData(), method: r.method() }));
  await page.goto(BASE + url, { waitUntil: "load" });
  await page.waitForSelector(".og-steps", { timeout: 8000 });
  return { ctx, page, log };
}
async function axeCheck(page, tag) {
  if (!AXE) return console.log("skip accessibility (npm install in tests/)");
  await page.evaluate(AXE);
  const v = await page.evaluate(() => axe.run(document, { runOnly: ["wcag2a", "wcag2aa", "best-practice"] }).then((r) => r.violations.filter((x) => x.impact === "serious" || x.impact === "critical").map((x) => x.id + " (" + x.nodes.length + ") e.g. " + x.nodes[0].target.join(" "))));
  ok(v.length === 0, tag + ": accessibility" + (v.length ? " " + v.join("; ") : ""));
}
const shot = (page, n) => SC ? page.screenshot({ path: path.join(SC, n + ".png"), fullPage: true }) : null;

(async () => {
  const browser = await chromium.launch({ args: ["--no-sandbox"] });
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "td-imp-")), bad = files(path.join(fs.mkdirSync(path.join(tmp, "bad")) || tmp, "bad"), generate({ errors: 3 })), planted = generate({ errors: 3 }).planted;
  const good = files(path.join(fs.mkdirSync(path.join(tmp, "good")) || tmp, "good"), generate({ errors: 0 }));

  // ---------------- owner, Settings > Import (live centre o3)
  let { ctx, page, log } = await open(browser, { url: "org?id=o3#import", role: "owner" });
  ok((await page.$$eval(".og-steps button", (b) => b.map((x) => x.textContent))).some((t) => /Import/.test(t)), "owner: the Import tab is there");
  ok(await page.isVisible("#imp-root"), "owner: import page shown");
  // templates
  const dls = await page.$$("[data-dl]"); ok(dls.length === 6, "six template buttons (past lessons shown as Later)");
  ok(/Later/.test(await page.textContent("#imp-root")), "past lessons marked Later");
  for (const k of IC.FILE_ORDER.filter((x) => IC.FILES[x].stage !== "later")) {
    const [dl] = await Promise.all([page.waitForEvent("download"), page.click('[data-dl="' + k + '"]')]);
    const txt = fs.readFileSync(await dl.path(), "utf8");
    ok(dl.suggestedFilename() === IC.FILES[k].file && txt === IC.templateCsv(k), "downloaded " + IC.FILES[k].file + " = the template (header + commented example)");
  }
  const [rd] = await Promise.all([page.waitForEvent("download"), page.click("#imp-readme")]);
  ok(/TutorDeck import templates/.test(fs.readFileSync(await rd.path(), "utf8")), "README downloaded");
  await shot(page, "1-templates");
  // upload the fixture with 3 planted errors
  const reqBefore = log.req.length;
  await page.setInputFiles("#imp-pick", bad);
  await page.waitForSelector(".imp-group");
  const rows = await page.$$eval(".imp-group", (gs) => gs.map((g) => ({ file: g.querySelector("h4").textContent.trim().split(" ")[0], rows: [...g.querySelectorAll("tbody tr")].map((tr) => [...tr.children].map((td) => td.textContent.trim())) })));
  ok(rows.reduce((n, g) => n + g.rows.length, 0) === 3, "3 problems listed");
  planted.forEach((p) => {
    const g = rows.filter((x) => x.file === p.file)[0], r = g && g.rows.filter((x) => x[0] === String(p.line) && x[1] === p.column)[0];
    ok(!!r && r[2].length > 0 && r[3].length > 0 && r[4].length > 0, p.file + " line " + p.line + " " + p.column + ": shows line, column, value, what is wrong and how to fix (" + (r ? r[4] : "missing") + ")");
  });
  ok(await page.isDisabled("#imp-go").catch(() => true) || !(await page.$("#imp-go")), "no Import now button while there are errors (or disabled)");
  ok(/3 problems/.test(await page.textContent(".imp-status")), "status says 3 problems");
  await shot(page, "2-errors");
  await axeCheck(page, "report with errors");
  // copy errors
  await page.click("#imp-copy"); await page.waitForFunction(() => /Copied/.test(document.getElementById("imp-msg").textContent));
  const clip = await page.evaluate(() => navigator.clipboard.readText().catch(() => ""));
  ok(!clip || (clip.split("\n").length === 3 && /line \d+/.test(clip)), "Copy errors: 3 lines on the clipboard");
  const [ed] = await Promise.all([page.waitForEvent("download"), page.click("#imp-csv")]);
  ok(fs.readFileSync(await ed.path(), "utf8").split("\r\n").filter(Boolean).length === 4, "errors CSV: header + 3 rows");
  // fix: add the corrected files again (they replace the old ones)
  await page.setInputFiles("#imp-pick", good);
  await page.waitForSelector(".imp-sum");
  const sumTxt = await page.textContent(".imp-sum");
  ok(/400 students/.test(sumTxt) && /200 tutors/.test(sumTxt) && /1,640 weekly lessons/.test(sumTxt) && /37 deposits/.test(sumTxt) && /12 unpaid invoices/.test(sumTxt) && /0 emails sent/.test(sumTxt), "summary: 400 students, 200 tutors, 1,640 lessons, 37 deposits, 12 invoices, 0 emails (" + sumTxt.replace(/\s+/g, " ").slice(0, 160) + ")");
  ok(await page.$$eval(".imp-chip", (c) => c.length) === 6, "six files, the old ones replaced (not twelve)");
  ok(await page.isDisabled("#imp-go") && /Coming in the next step/.test(await page.textContent(".imp-go")), "Import now is disabled: Coming in the next step");
  await shot(page, "3-summary");
  await axeCheck(page, "summary");
  // nothing left the browser
  const during = log.req.slice(reqBefore).filter((r) => !/^(blob:|data:)/.test(r.url) && !/^https:\/\/fonts\.(googleapis|gstatic)\.com\//.test(r.url));   // (the page's own web font, loaded lazily, is not file content)
  ok(during.length === 0, "no network request while uploading and checking files (" + during.map((r) => r.url).join(", ") + ")");
  ok(log.req.every((r) => !r.post && r.method === "GET"), "no request in the whole session carries a body (" + log.req.length + " requests, all GET)");
  ok(log.errs.length === 0, "no console errors" + (log.errs.length ? ": " + log.errs.join("; ") : ""));
  await ctx.close();

  // ---------------- dark mode and phone width
  for (const [vp, theme] of [["desktop", "dark"], ["phone", "light"], ["phone", "dark"]]) {
    ({ ctx, page, log } = await open(browser, { vp, theme, url: "org?id=o3#import", role: "owner" }));
    await page.setInputFiles("#imp-pick", bad); await page.waitForSelector(".imp-group");
    const w = await page.evaluate(() => [document.documentElement.scrollWidth, innerWidth]);
    ok(w[0] <= w[1] + 1, vp + " " + theme + ": no sideways page scroll (" + w.join("/") + ")");
    await shot(page, "4-" + vp + "-" + theme + "-errors");
    await axeCheck(page, vp + " " + theme + " errors");
    await page.setInputFiles("#imp-pick", good); await page.waitForSelector(".imp-sum");
    await shot(page, "5-" + vp + "-" + theme + "-summary");
    await axeCheck(page, vp + " " + theme + " summary");
    ok(log.errs.length === 0, vp + " " + theme + ": no console errors" + (log.errs.length ? ": " + log.errs.join("; ") : ""));
    await ctx.close();
  }

  // ---------------- the wizard (centre still being set up, o2), step 9
  ({ ctx, page, log } = await open(browser, { url: "org?id=o2#import", role: "owner" }));
  ok(await page.isVisible("#imp-root") && /9\. Import data/.test(await page.textContent("#og-body")), "owner: wizard step 9 shows the import page");
  await ctx.close();

  // ---------------- staff, tutor, solo: nothing
  for (const [who, role, url] of [["staff admin (wizard)", "staff", "org?id=o2#import"], ["staff admin (settings)", "staff", "org?id=o3#import"], ["tutor", "tutor", "org?id=o3#import"], ["solo tutor", "owner", "org?id=o1#import"]]) {
    ({ ctx, page, log } = await open(browser, { role, url }));
    const tabs = (await page.$$eval(".og-steps button", (b) => b.map((x) => x.textContent))).join("|");
    ok(!/Import/.test(tabs) && !(await page.$("#imp-root")) && !(await page.$("[data-dl]")) && !/Choose files/.test(await page.textContent("body")), who + ": no Import tab, no templates, no file picker");
    await ctx.close();
  }
  await browser.close(); fs.rmSync(tmp, { recursive: true, force: true });
  console.log(fails ? "\n" + fails + " FAILED" : "\nAll import page checks passed");
  process.exit(fails ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
