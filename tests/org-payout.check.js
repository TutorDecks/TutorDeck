// Browser check for the centre's tutor payout list on /org (People step). Not part of CI: needs Playwright + `python3 tests/server.py 8765`.
// Uses the signed-in test stub with a fake database for the three payout functions (made-up numbers).   node tests/org-payout.check.js
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
const AXE = (() => { try { return fs.readFileSync(path.join(ROOT, "tests/node_modules/axe-core/axe.min.js"), "utf8"); } catch (e) { return null; } })();
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
const STUB_PLUS = STUB + `;(function(){var o=window.supabase.createClient;window.supabase.createClient=function(){var c=o.apply(this,arguments);if(window.__override)window.__override(c);return c;};})();`;

function override(cfg) {
  window.__calls = [];
  window.__override = function (c) {
    var origRpc = c.rpc.bind(c), origFrom = c.from.bind(c), audit = [];
    var ROWS = [   // the centre's tutors as the database would answer (m4 = Ravi in the stub; m6 and m7 are extra fake tutors)
      { membership_id: "m4", display_name: "Ravi", member_status: "active", has_payout: true, method: "paynow_mobile", masked: "•••••5432", bank_name: null, holder_hint: null, changed_by_name: "Ravi", changed_at: new Date(Date.now() - 864e5).toISOString(), changed_recently: true },
      { membership_id: "m6", display_name: "Mei Ling", member_status: "active", has_payout: true, method: "bank", masked: "•••••7890", bank_name: "Test Bank", holder_hint: "M•••", changed_by_name: "Mei Ling", changed_at: "2026-10-01T00:00:00Z", changed_recently: false },
      { membership_id: "m7", display_name: "Arun", member_status: "active", has_payout: false, method: null, masked: null, bank_name: null, holder_hint: null, changed_by_name: null, changed_at: null, changed_recently: false }];
    var FULL = { m4: { method: "paynow_mobile", paynow_id: "+6598765432", bank_name: null, account_no: null, account_holder: null },
                 m6: { method: "bank", paynow_id: null, bank_name: "Test Bank", account_no: "1234567890", account_holder: "Mei Ling Test" } };
    c.rpc = function (n, a) {
      window.__calls.push([n, a && a.p_membership ? { p_membership: a.p_membership } : a]);
      if (/^org_tutor_payout/.test(n) || n === "org_reveal_payout") {
        if (cfg.migrationMissing) return Promise.resolve({ data: null, error: { code: "PGRST202", message: "Could not find the function public." + n } });
        if (n === "org_tutor_payouts") return Promise.resolve(cfg.staffNoPerm ? { data: null, error: { message: "NOT_FOUND" } } : { data: JSON.parse(JSON.stringify(ROWS)), error: null });
        if (n === "org_tutor_payout_status") return Promise.resolve({ data: ROWS.map(function (r) { return { membership_id: r.membership_id, has_payout: r.has_payout }; }), error: null });
        if (n === "org_reveal_payout") { audit.push(a.p_membership); return Promise.resolve(FULL[a.p_membership] ? { data: [FULL[a.p_membership]], error: null } : { data: null, error: { message: "NO_PAYOUT: x" } }); }
      }
      return origRpc(n, a);
    };
    window.__audit = audit;
    c.from = function (t) {
      var q = origFrom(t);
      if (t !== "memberships" || !cfg.asStaff) return q;
      var fix = function (rows) { return rows.map(function (m) { return m.id === "m2" ? Object.assign({}, m, { role: "staff", permissions: cfg.perms || [] }) : m; }); };
      var oThen = q.then, oMs = q.maybeSingle;
      q.then = function (r, j) { return oThen.call(q, function (x) { return r(x && x.data ? Object.assign({}, x, { data: fix(x.data) }) : x); }, j); };
      q.maybeSingle = function () { return oMs.call(q).then(function (x) { return x && x.data ? Object.assign({}, x, { data: fix([x.data])[0] }) : x; }); };
      return q;
    };
    // two more tutors in the list
    var oFrom = c.from;
    c.from = function (t) {
      var q = oFrom(t);
      if (t !== "memberships") return q;
      var oThen = q.then;
      q.then = function (r, j) { return oThen.call(q, function (x) {
        if (x && Array.isArray(x.data) && x.data.some(function (m) { return m.id === "m4"; }))
          x = Object.assign({}, x, { data: x.data.concat([{ id: "m6", org_id: "o2", user_id: "u10", display_name: "Mei Ling", role: "tutor", employment_type: "employee", permissions: [], status: "active", created_at: "6" },
                                                          { id: "m7", org_id: "o2", user_id: "u11", display_name: "Arun", role: "tutor", employment_type: "freelancer", permissions: [], status: "active", created_at: "7" }]) });
        return r(x); }, j); };
      return q;
    };
  };
}
async function open(browser, vp, theme, cfg) {
  const ctx = await browser.newContext(vp === "phone" ? { viewport: { width: 390, height: 844 }, isMobile: true, deviceScaleFactor: 2 } : { viewport: { width: 1100, height: 900 } });
  await ctx.addInitScript((t) => { try { localStorage.setItem("td_theme", t); } catch (e) {} }, theme);
  await ctx.route(/^(?!http:\/\/127\.0\.0\.1).*/, (r) => r.abort());
  const page = await ctx.newPage(); const errs = [];
  await page.route("**/assets/vendor/supabase-2.118.0.js", (r) => r.fulfill({ body: STUB_PLUS, contentType: "application/javascript" }));
  await page.addInitScript(override, cfg);
  page.on("pageerror", (e) => errs.push(e.message));
  page.on("console", (m) => { if (m.type() === "error" && !/ERR_FAILED/.test(m.text())) errs.push("console: " + m.text()); if (/98765432|1234567890/.test(m.text())) errs.push("NUMBER IN CONSOLE"); });
  await page.goto(BASE + "org.html?id=o2#users", { waitUntil: "load" }); await page.waitForTimeout(1400);
  return { ctx, page, errs };
}
async function axeCheck(page, tag) {
  if (!AXE) return;
  await page.evaluate(AXE);
  const v = await page.evaluate(() => axe.run(document, { runOnly: ["wcag2a", "wcag2aa", "best-practice"] }).then((r) => r.violations.filter((x) => x.impact === "serious" || x.impact === "critical").map((x) => x.id + " e.g. " + x.nodes[0].html.slice(0, 80))));
  ok(v.length === 0, tag + ": accessibility" + (v.length ? " " + v.join("; ") : ""));
}
const shot = process.env.SHOTS;

(async () => {
  const b = await chromium.launch();
  for (const [vp, theme] of [["phone", "light"], ["phone", "dark"], ["desktop", "light"]]) {
    const tag = "owner " + vp + "/" + theme;
    const { ctx, page, errs } = await open(b, vp, theme, {});
    const txt = async () => (await page.textContent("#og-body")) || "";
    ok(/Ravi/.test(await txt()) && (await page.$$("[data-pay]")).length === 3, tag + ": three tutors have a payout line");
    const t = await txt();
    ok(/PayNow mobile\s*•••••5432/.test(t) && /Bank account · Test Bank\s*•••••7890/.test(t), tag + ": masked values with the method");
    ok(/Payout details: not provided/.test(t), tag + ": a tutor with nothing saved says so");
    ok(!/98765432|1234567890|Mei Ling Test/.test(await page.content()), tag + ": no full number anywhere in the page");
    ok((await page.$$(".og-badge.amber")).length === 1 && /Changed/.test(await page.textContent(".og-badge.amber")), tag + ": exactly one amber 'Changed' chip (only the recent change)");
    ok((await page.$$("[data-reveal]")).length === 2, tag + ": a Reveal button for each tutor who has details");
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + ": no sideways scroll");
    if (vp === "phone" && theme === "light" && shot) await page.screenshot({ path: shot + "/owner-phone.png", fullPage: true });
    if (vp === "phone" && theme === "dark" && shot) await page.screenshot({ path: shot + "/owner-phone-dark.png", fullPage: true });
    if (vp === "desktop" && shot) await page.screenshot({ path: shot + "/owner-desktop.png", fullPage: true });
    await axeCheck(page, tag);
    if (vp === "phone" && theme === "light") {
      // reveal: asks first; Cancel does nothing
      await page.click('[data-reveal="m4"]'); await page.waitForTimeout(300);
      ok(/recorded in the audit log/.test(await page.textContent("body")), "reveal asks for confirmation and says it is logged");
      const cancel = await page.$('button:has-text("Cancel")'); if (cancel) await cancel.click(); await page.waitForTimeout(250);
      ok((await page.evaluate(() => window.__calls.filter((c) => c[0] === "org_reveal_payout").length)) === 0 && !(await page.isVisible('[data-revealed="m4"]')), "cancel: nothing is asked of the database, nothing shown");
      await page.click('[data-reveal="m4"]'); await page.waitForTimeout(300);
      await page.click('button:has-text("Show")'); await page.waitForTimeout(400);
      ok(await page.isVisible('[data-revealed="m4"]') && /PayNow mobile \+6598765432/.test(await page.textContent('[data-revealed="m4"]')), "confirm: the full number appears under that tutor");
      ok((await page.evaluate(() => window.__audit)).join() === "m4", "one reveal call for that tutor");
      if (shot) await page.screenshot({ path: shot + "/revealed-phone.png", fullPage: true });
      await page.click('[data-revealed="m4"] button'); await page.waitForTimeout(150);
      ok(!(await page.isVisible('[data-revealed="m4"]')) && (await page.textContent('[data-revealed="m4"]')) === "" && await page.isVisible('[data-reveal="m4"]'), "Hide clears the number from the page and brings Reveal back");
      await page.click('[data-reveal="m6"]'); await page.waitForTimeout(250); await page.click('button:has-text("Show")'); await page.waitForTimeout(350);
      ok(/Account 1234567890/.test(await page.textContent('[data-revealed="m6"]')) && /Name Mei Ling Test/.test(await page.textContent('[data-revealed="m6"]')), "bank details reveal shows bank, account and holder");
    }
    ok(errs.length === 0, tag + ": no script or console errors " + errs.join("|"));
    await ctx.close();
  }
  { // staff WITHOUT the permission: provided / not provided only
    const { ctx, page, errs } = await open(b, "phone", "light", { asStaff: true, perms: ["manage_tutors"] });
    const t = (await page.textContent("#og-body")) || "";
    ok(/Payout details: provided/.test(t) && /Payout details: not provided/.test(t), "staff without permission: 'provided' / 'not provided'");
    ok(!/5432|7890|PayNow mobile|Test Bank|Reveal|Changed/.test(t), "…and no digits, method, bank, Reveal or Changed chip");
    ok((await page.evaluate(() => window.__calls.map((c) => c[0]).filter((n) => /payout/.test(n)))).join() === "org_tutor_payout_status", "…and only the status function was called");
    if (shot) await page.screenshot({ path: shot + "/staff-no-perm.png", fullPage: true });
    ok(errs.length === 0, "staff without permission: no errors " + errs.join("|"));
    await ctx.close();
  }
  { // staff WITH the permission: masked list and Reveal
    const { ctx, page, errs } = await open(b, "phone", "light", { asStaff: true, perms: ["manage_tutors", "view_payout_details"] });
    const t = (await page.textContent("#og-body")) || "";
    ok(/•••••5432/.test(t) && (await page.$$("[data-reveal]")).length === 2, "staff with permission: masked list and Reveal buttons");
    ok(errs.length === 0, "staff with permission: no errors " + errs.join("|"));
    await ctx.close();
  }
  { // owner: the permission shows in the staff permissions editor with a plain label
    const { ctx, page } = await open(b, "phone", "light", {});
    const t = (await page.textContent("#og-body")) || "";
    ok(/See tutors’ payout details \(PayNow, bank\)/.test(t) && (await page.$$('[data-ip="view_payout_details"]')).length === 1, "invite form lists the new permission with a plain label");
    ok((await page.$$('[data-mp-m3="view_payout_details"]')).length === 1, "and so does the existing staff member's permissions row");
    await ctx.close();
  }
  { // migration not on the project yet: the page works and shows nothing extra
    const { ctx, page, errs } = await open(b, "phone", "light", { migrationMissing: true });
    ok(/Ravi/.test((await page.textContent("#og-body")) || "") && !/Payout/.test((await page.textContent("#og-body")) || "") && errs.length === 0, "function missing: People list still works, no payout line, no errors " + errs.join("|"));
    await ctx.close();
  }
  await b.close();
  console.log(fails ? "\n" + fails + " FAILED" : "\nALL PASSED"); process.exit(fails ? 1 : 0);
})();
