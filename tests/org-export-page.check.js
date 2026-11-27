// Browser check (T35-E): Settings → Data export for a centre owner, at phone width (390px) and desktop.
// Uses the DEV Supabase project for sign-in only (dummy data, demo logins from db/seed_dev_demo.sql). The three export functions are STUBBED in the browser
// (DEV may not have db/migration_org_export.sql applied yet), so this checks the screen, the progress, the download and the file, not the database (tests/sql/org_export_test.sql does that).
//   python3 tests/server.py 8765 &   node tests/org-export-page.check.js [screenshot-dir]
const { chromium } = require("playwright");
const path = require("path"), fs = require("fs"), os = require("os"), cp = require("child_process");
const X = require("../assets/js/org-export-core.js");
const SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/", PW = "Demo-Pass-2026";
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "org-export-check-"));
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
async function login(page, email) {
  await page.goto(BASE + "login.html", { waitUntil: "load" });
  await page.fill("#email", email); await page.fill("#pw", PW);
  if (await page.$("#consent")) { try { await page.check("#consent", { timeout: 500 }); } catch (e) {} }
  await page.click("#go"); await page.waitForURL(/home|tutor|settings|org/, { timeout: 20000 });
}
// a tiny pretend database: 3 students, 2 lessons, 2 guardians, the rest empty
const ROWS = { students: 3, lessons: 2, guardians: 2 };
function fakeRows(tbl) { const t = X.CATALOG.find((c) => c.tbl === tbl), n = ROWS[tbl] || 0; return Array.from({ length: n }, (_, i) => t.cols.map((c) => /_cents$/.test(c[0]) ? 5000 + i : c[0] === "name" || c[0] === "student_name" ? "Student " + i + ", \"Q\" 陈" : /id$/.test(c[0]) ? "00000000-0000-0000-0000-00000000000" + i : null)); }
async function stub(page, calls) {
  await page.route("**/rest/v1/rpc/org_export_*", async (route) => {
    const req = route.request(), name = req.url().split("/rpc/")[1].split("?")[0], body = JSON.parse(req.postData() || "{}"); calls.push([name, body]);
    const json = (data) => route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(data) });
    if (name === "org_export_start") return json({ job: 7, full_payout: !!body.p_full_payout, tables: X.CATALOG.map((t) => ({ tbl: t.tbl, rows: fakeRows(t.tbl).length })) });
    if (name === "org_export_page") { const t = X.CATALOG.find((c) => c.tbl === body.p_table); await new Promise((r) => setTimeout(r, 25)); return json({ cols: t.cols.map((c) => c[0]), rows: fakeRows(t.tbl), next: null }); }
    if (name === "org_export_finish") return json({ matched: true, differs: [] });
    return route.fulfill({ status: 404, body: "{}" });
  });
}
(async () => {
  const b = await chromium.launch();
  for (const vp of [{ n: "phone", o: { viewport: { width: 390, height: 844 }, isMobile: true, acceptDownloads: true } }, { n: "desktop", o: { viewport: { width: 1100, height: 900 }, acceptDownloads: true } }]) {
    const ctx = await b.newContext(vp.o), page = await ctx.newPage(), errs = [], calls = [];
    page.on("pageerror", (e) => errs.push(e.message)); await stub(page, calls);
    await login(page, "centre.owner@example.test");
    await page.goto(BASE + "org.html", { waitUntil: "load" }); await page.waitForSelector("a[href*='org?id=']", { state: "attached", timeout: 15000 }); await page.waitForTimeout(1200);
    const href = await page.$$eval("a", (as) => (as.find((a) => /Live/.test(a.textContent) && /org\?id=/.test(a.getAttribute("href") || "")) || {}).href || "");
    await page.goto(href.replace(/org\?id=/, "org.html?id=") + "#export", { waitUntil: "load" }); await page.waitForSelector("#ex-go", { timeout: 15000 });
    const L = vp.n, txt = await page.textContent("#og");
    ok(await page.$("button[data-step='export']") !== null, L + ": the owner sees a Data export tab");
    ok(/personal data/i.test(txt) && /PDPA/.test(txt) && /phone numbers and email addresses/.test(txt), L + ": the screen says it holds families' contact details (PDPA)");
    ok(/Not included: passwords/.test(txt) && /Stripe/.test(txt), L + ": says what is not included");
    ok(await page.isChecked("#ex-full") === false, L + ": 'full payout numbers' is OFF by default");
    ok((await page.$$("#og-body .btn-primary")).length === 1, L + ": exactly one primary button");
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), L + ": no sideways scroll");
    if (SC) await page.screenshot({ path: path.join(SC, "export-" + L + "-idle.png"), fullPage: true });
    // masked export
    const [dl] = await Promise.all([page.waitForEvent("download", { timeout: 20000 }), page.click("#ex-go")]);
    const zipPath = path.join(TMP, L + ".zip"); await dl.saveAs(zipPath);
    ok(/^tutordeck-export-.*-\d{4}-\d{2}-\d{2}\.zip$/.test(dl.suggestedFilename()), L + ": downloaded " + dl.suggestedFilename());
    await page.waitForFunction(() => /Downloaded/.test(document.querySelector("#ex-msg").textContent), null, { timeout: 10000 });
    const msg = await page.textContent("#ex-msg");
    ok(/7 rows/.test(msg) && /store it somewhere private/.test(msg), L + ": message says rows and 'store it somewhere private' (" + msg.slice(0, 90) + "…)");
    const start = calls.find((c) => c[0] === "org_export_start")[1]; ok(start.p_full_payout === false && /^[0-9a-f-]{36}$/.test(start.p_org), L + ": start asked for masked payout numbers for this centre");
    ok(calls.some((c) => c[0] === "org_export_finish" && c[1].p_counts.students === 3 && c[1].p_counts.lessons === 2), L + ": finish was told the row counts");
    const listing = cp.spawnSync("unzip", ["-l", zipPath]).stdout.toString();
    ok(/students\.csv/.test(listing) && /lessons\.csv/.test(listing) && /README\.txt/.test(listing), L + ": the ZIP holds the CSVs and the README");
    ok(cp.spawnSync("unzip", ["-tq", zipPath]).status === 0, L + ": the ZIP passes unzip -t");
    const students = cp.spawnSync("unzip", ["-p", zipPath, "students.csv"]).stdout.toString("utf8");
    ok(students.charCodeAt(0) === 0xFEFF && /Student 0, ""Q"" 陈/.test(students), L + ": students.csv has a BOM and correctly quoted names");
    ok(/masked/.test(cp.spawnSync("unzip", ["-p", zipPath, "README.txt"]).stdout.toString("utf8")), L + ": README says payout numbers are masked");
    // the tick: asks to confirm, then sends full_payout = true
    calls.length = 0;
    await page.check("#ex-full"); await page.click("#ex-go");
    await page.waitForSelector("text=Include full payout numbers?", { timeout: 5000 });
    ok(true, L + ": ticking full payout numbers asks the owner to confirm first");
    if (SC) await page.screenshot({ path: path.join(SC, "export-" + L + "-confirm.png") });
    const [dl2] = await Promise.all([page.waitForEvent("download", { timeout: 20000 }), page.click("text=Include them")]);
    await dl2.saveAs(zipPath + "2");
    ok(calls.find((c) => c[0] === "org_export_start")[1].p_full_payout === true, L + ": after confirming, start asked for FULL payout numbers");
    ok(/FULL/.test(cp.spawnSync("unzip", ["-p", zipPath + "2", "README.txt"]).stdout.toString("utf8")), L + ": README says so");
    if (SC) await page.screenshot({ path: path.join(SC, "export-" + L + "-done.png"), fullPage: true });
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), L + ": still no sideways scroll");
    // a refusal is shown in plain words
    await page.unroute("**/rest/v1/rpc/org_export_*"); await page.route("**/rest/v1/rpc/org_export_*", (r) => r.fulfill({ status: 400, contentType: "application/json", body: JSON.stringify({ code: "P0001", message: "NOT_FOUND" }) }));
    await page.uncheck("#ex-full"); await page.click("#ex-go"); await page.waitForFunction(() => /owner/.test(document.querySelector("#ex-msg").textContent), null, { timeout: 8000 });
    ok(/Only the centre.s owner/.test(await page.textContent("#ex-msg")), L + ": a refusal reads 'Only the centre's owner can export its data.'");
    ok(errs.length === 0, L + ": no page errors " + errs.join("|"));
    await ctx.close();
  }
  // a centre tutor has no way in: Home sends them to /tutor and the Data export tab is not theirs
  const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true }), page = await ctx.newPage();
  await login(page, "tutor.one@example.test"); await page.waitForTimeout(1500);
  await page.goto(BASE + "org.html", { waitUntil: "load" }); await page.waitForTimeout(2500);
  ok(!(await page.$("button[data-step='export']")) && !(await page.$("#ex-go")), "a centre tutor: no Data export tab and no export button");
  await ctx.close(); await b.close();
  console.log(fails ? fails + " FAILED" : "all passed"); process.exit(fails ? 1 : 0);
})();
