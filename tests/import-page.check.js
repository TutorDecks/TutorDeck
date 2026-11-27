// Browser check for the import page (T33 I0 + I1). Not part of CI: needs Playwright and `python3 tests/server.py 8765`.
//   node tests/import-page.check.js [screenshot-dir]
// Uses the Supabase stub (tests/supabase-stub-signed-in.js) plus a FAKE import database (FAKE below): no network. Proves: the owner sees templates,
// upload, report, summary, the database's own check, consent + backup note, Import now (one commit call, with file hashes), the plain-words
// result, history, Undo with its preview and report; the database's errors are shown without any cell text; a lost connection is handled;
// staff / tutor / solo see nothing; and nothing leaves the page before the owner presses Import now. Also at phone width (390 px) and in dark mode.
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path"), os = require("os");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
const AXE = (() => { try { return fs.readFileSync(path.join(ROOT, "tests/node_modules/axe-core/axe.min.js"), "utf8"); } catch (e) { return null; } })();
const IC = require("../assets/js/import-core.js"), { generate } = require("./fixtures/make-import-fixture.js");
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };

// A fake import database, in the page. window.__impMode: "ok" | "errors" (the database finds problems; its error text holds a planted secret) | "commitfail" (the connection drops during the commit).
const FAKE = `(function(){
  var S = window.__imp = { calls: [], batches: [], committed: false };
  function ok(d){ return Promise.resolve({ data: d, error: null }); }
  window.__impRpc = function(n, a){
    S.calls.push({ n: n, hasPayload: !!(a && a.p_payload), keys: a && a.p_payload ? Object.keys(a.p_payload) : [], hashes: a && a.p_hashes, org: a && a.p_org, batch: a && a.p_batch, size: a && a.p_payload ? JSON.stringify(a.p_payload).length : 0 });
    var P = a && a.p_payload, mode = window.__impMode || "ok";
    function counts(){ var f = {}; (P.families||[]).forEach(function(x){ f[x.family_ref] = 1; });
      return { families: Object.keys(f).length, guardians: P.families.length, students: P.students.length, tutors: P.tutors.length, weekly_lessons: P.weekly_lessons.length }; }
    if (n === "import_history") return ok(S.batches.slice().reverse());
    if (n === "import_dry_run") {
      if (mode === "errors") return ok({ ok: false, error_count: 2, errors: [{ file: "weekly_lessons", line: 212, column: "start", code: "SLOT_CLASH" }, { file: "students", line: 9, column: "family_ref", code: "UNKNOWN_FAMILY" }] });
      var c = counts(), z = { families: 0, guardians: 0, students: 0, tutors: 0, weekly_lessons: 0 };
      return ok({ ok: true, dry_run: true, errors: [], error_count: 0, warnings: S.committed ? [{ file: "students", line: 2, code: "DIFFERS" }] : [], created: S.committed ? z : c, skipped: S.committed ? c : z });
    }
    if (n === "import_commit") {
      if (mode === "commitfail") return Promise.reject(new Error("SECRETCELL network"));
      var c2 = counts(); S.committed = true;
      S.batches.push({ id: "b" + (S.batches.length + 1), created_at: new Date().toISOString(), stage: "A", status: "committed", counts: { created: c2 }, undo_until: new Date(Date.now() + 7 * 864e5).toISOString(), can_undo: true });
      return ok({ ok: true, dry_run: false, errors: [], created: c2, skipped: { families: 0, guardians: 0, students: 0, tutors: 0, weekly_lessons: 0 }, warnings: [], batch_id: "b" + S.batches.length, undo_until: S.batches[S.batches.length - 1].undo_until });
    }
    if (n === "import_undo_preview") return ok({ ok: true, preview: true, would_delete: { students: 398, recurring_slots: 1630, memberships: 190, guardians: 590, households: 295 }, kept: [{ type: "student", code: "s1", reason: "ACTIVITY" }, { type: "student", code: "s2", reason: "EDITED" }, { type: "tutor", code: "a@x.test", reason: "ACCEPTED" }], kept_count: 3, already_gone: 0 });
    if (n === "import_undo") { var b = S.batches.filter(function(x){ return x.id === a.p_batch; })[0]; if (b) b.status = "partly_undone";
      return ok({ ok: true, preview: false, deleted: { students: 398, recurring_slots: 1630 }, kept: [{ type: "student", code: "s1", reason: "ACTIVITY" }, { type: "tutor", code: "a@x.test", reason: "ACCEPTED" }], kept_count: 2, status: "partly_undone", already_gone: 0 }); }
    return ok(null);
  };
})();`;
const STUB_PLUS = STUB + `;(function(){var o=window.supabase.createClient;window.supabase.createClient=function(){var c=o.apply(this,arguments);
  var orp=c.rpc; c.rpc=function(n){ if(/^import_/.test(n)) return window.__impRpc.apply(null,arguments); return orp.apply(c,arguments); };
  if(window.__orgRole){var of=c.from;c.from=function(t){var q=of.apply(c,arguments);if(t==="memberships"){var ms=q.maybeSingle;q.maybeSingle=function(){return ms().then(function(x){return {data:x.data?Object.assign({},x.data,{role:window.__orgRole}):null,error:null};});};}return q;};}
  return c;};})();`;

function files(dir, g) { return Object.keys(g.files).map((f) => { const p = path.join(dir, f); fs.writeFileSync(p, g.files[f]); return p; }); }

async function open(browser, { vp = "desktop", theme = "light", role = null, url, mode = "ok" }) {
  const ctx = await browser.newContext(Object.assign(vp === "phone" ? { viewport: { width: 390, height: 844 }, isMobile: true, deviceScaleFactor: 2 } : { viewport: { width: 1280, height: 900 } }, { acceptDownloads: true }));
  await ctx.grantPermissions(["clipboard-read", "clipboard-write"], { origin: "http://127.0.0.1:8765" }).catch(() => {});
  await ctx.addInitScript(FAKE);
  await ctx.addInitScript((a) => { try { localStorage.setItem("td_theme", a[0]); localStorage.setItem("td_tip_client-view", "1"); } catch (e) {} window.__orgRole = a[1]; window.__impMode = a[2]; }, [theme, role, mode]);
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
  await shot(page, "3-summary");
  await axeCheck(page, "summary");
  // the database's own check, then consent and the backup note
  await page.waitForSelector(".imp-status.ok >> text=TutorDeck has checked everything");
  const calls0 = await page.evaluate(() => window.__imp.calls.map((c) => c.n));
  ok(calls0.filter((n) => n === "import_dry_run").length === 1 && !calls0.includes("import_commit"), "the database was asked to CHECK once and nothing was committed yet (" + calls0.join(",") + ")");
  const dry = await page.evaluate(() => window.__imp.calls.filter((c) => c.n === "import_dry_run")[0]);
  ok(dry.org === "o3" && dry.keys.sort().join() === "families,students,tutors,weekly_lessons", "the check sends the four stage-A tables for this centre only (no deposits or invoices): " + dry.keys.join());
  ok(/Download your data first/.test(await page.textContent(".imp-backup")), "backup note: Download your data first");
  ok(/Past lessons are not imported/.test(await page.textContent(".imp-billing")) && /Billing starts from/.test(await page.textContent(".imp-billing")), "billing-start reminder shown");
  ok(/not imported yet/.test(await page.textContent("#imp-out")), "money files are marked as checked but not imported yet");
  ok(await page.isDisabled("#imp-go") && /Tick the box/.test(await page.textContent("#imp-go-why")), "Import now is disabled until the consent box is ticked");
  await page.check("#imp-consent");
  ok(!(await page.isDisabled("#imp-go")) && /undo it for 7 days/.test(await page.textContent("#imp-go-why")), "ticked: Import now is enabled");
  await shot(page, "3b-ready");
  await axeCheck(page, "ready to import");
  // nothing left the browser before Import now
  const during = log.req.slice(reqBefore).filter((r) => !/^(blob:|data:)/.test(r.url) && !/^https:\/\/fonts\.(googleapis|gstatic)\.com\//.test(r.url));   // (the page's own web font, loaded lazily, is not file content)
  ok(during.length === 0, "no network request while uploading, checking and ticking (" + during.map((r) => r.url).join(", ") + ")");
  // import
  await page.click("#imp-go");
  await page.waitForSelector("text=5. Done");
  const calls1 = await page.evaluate(() => window.__imp.calls.filter((c) => c.n === "import_commit"));
  ok(calls1.length === 1, "exactly ONE commit call");
  const hs = calls1[0].hashes || {};
  ok(Object.keys(hs).sort().join() === "families.csv,students.csv,tutors.csv,weekly_lessons.csv" && Object.values(hs).every((h) => /^[0-9a-f]{64}$/.test(h)), "the commit carries the SHA-256 of the four files, not the files");
  ok(calls1[0].keys.sort().join() === "families,students,tutors,weekly_lessons", "the commit sends the same four tables");
  const done = await page.textContent("#imp-out");
  ok(/Added 400 students in \d+ new families/.test(done) && /Saved 200 tutor invitations\. No email was sent/.test(done) && /Added 1,640 weekly lessons/.test(done) && /undo this import until/.test(done), "plain-words result: 400 students, 200 invitations with no email, 1,640 weekly lessons, undo date");
  ok(await page.$$eval(".imp-chip", (c) => c.length) === 0, "the files are forgotten after a successful import");
  await page.waitForSelector("#imp-hist [data-undo]");
  ok(/Imported/.test(await page.textContent("#imp-hist")) && /400 students, 200 tutors, 1,640 weekly lessons/.test(await page.textContent("#imp-hist")), "history lists the import with its counts and an Undo button");
  await shot(page, "3c-done");
  await axeCheck(page, "done and history");
  // the same files again: nothing new, nothing to press
  await page.setInputFiles("#imp-pick", good);
  await page.waitForSelector(".imp-status.ok >> text=TutorDeck has checked everything");
  ok(/Nothing new/.test(await page.textContent("#imp-out")) && await page.isDisabled("#imp-go"), "the same files again: nothing new, Import now stays disabled");
  ok(/differ/.test(await page.textContent("#imp-out")), "a row that differs from what is in TutorDeck is mentioned (it is never changed)");
  // undo: preview, then do it
  await page.click("#imp-hist [data-undo]");
  await page.waitForSelector("#imp-undo-go");
  const prev = await page.textContent("#imp-hist");
  ok(/Undo will remove: 398 students/.test(prev) && /Stays: .*because lessons of it were marked, charged or invoiced/.test(prev) && /someone changed it after the import/.test(prev), "undo preview: what goes and what stays, and why");
  await shot(page, "3d-undo-preview");
  await axeCheck(page, "undo preview");
  await page.click("#imp-undo-go");
  await page.waitForSelector("#imp-hist >> text=Removed:");
  const rep = await page.textContent("#imp-hist");
  ok(/Removed: 398 students/.test(rep) && /Left in place: .*because/.test(rep) && /Partly undone/.test(rep), "undo report: removed, left in place with reasons, status partly undone");
  await shot(page, "3e-undone");
  ok(log.errs.length === 0, "no console errors" + (log.errs.length ? ": " + log.errs.join("; ") : ""));
  ok(log.req.every((r) => !r.post && r.method === "GET"), "no HTTP request in the whole session carries a body (" + log.req.length + " requests, all GET)");
  await ctx.close();

  // ---------------- the database finds problems the files could not show: words only, never cell text
  ({ ctx, page, log } = await open(browser, { url: "org?id=o3#import", role: "owner", mode: "errors" }));
  await page.setInputFiles("#imp-pick", good);
  await page.waitForSelector("text=TutorDeck found 2 problems");
  const eT = await page.textContent("#imp-out");
  ok(/weekly_lessons\.csv/.test(eT) && /212/.test(eT) && /overlaps another lesson of the same student/.test(eT) && /students\.csv/.test(eT) && /not a family in your files or in TutorDeck/.test(eT), "database problems: file, line, column and plain words");
  ok(!(await page.$("#imp-go")), "no Import now while the database reports problems");
  await shot(page, "3f-server-errors");
  await axeCheck(page, "database problems");
  await ctx.close();
  // ---------------- the connection drops during the commit: no false promise
  ({ ctx, page, log } = await open(browser, { url: "org?id=o3#import", role: "owner", mode: "commitfail" }));
  await page.setInputFiles("#imp-pick", good);
  await page.waitForSelector(".imp-status.ok >> text=TutorDeck has checked everything"); await page.check("#imp-consent"); await page.click("#imp-go");
  await page.waitForSelector("text=could not confirm");
  const lost = await page.textContent("#imp-out");
  ok(/Earlier imports/.test(lost) && /nothing is ever added twice/.test(lost) && !/SECRETCELL/.test(await page.textContent("body")), "a lost connection says so, points to history and shows no technical text");
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
    await page.waitForSelector(".imp-status.ok >> text=TutorDeck has checked everything");
    await shot(page, "5-" + vp + "-" + theme + "-summary");
    await axeCheck(page, vp + " " + theme + " summary");
    await page.check("#imp-consent");
    const box = await page.$eval("#imp-go", (b) => { const r = b.getBoundingClientRect(); return [r.width, r.height, r.right, innerWidth]; });
    ok(box[2] <= box[3] + 1 && box[1] >= 36, vp + " " + theme + ": Import now fits the screen and is tall enough to tap (" + Math.round(box[0]) + "x" + Math.round(box[1]) + ")");
    await page.click("#imp-go"); await page.waitForSelector("text=5. Done"); await page.waitForSelector("#imp-hist [data-undo]");
    await page.click("#imp-hist [data-undo]"); await page.waitForSelector("#imp-undo-go");
    const w2 = await page.evaluate(() => [document.documentElement.scrollWidth, innerWidth]);
    ok(w2[0] <= w2[1] + 1, vp + " " + theme + ": result, history and undo preview fit the width (" + w2.join("/") + ")");
    await shot(page, "6-" + vp + "-" + theme + "-undo");
    await axeCheck(page, vp + " " + theme + " history and undo");
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
