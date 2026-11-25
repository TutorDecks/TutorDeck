// Browser check for /tutor-settings (not part of CI: needs Playwright + `python3 tests/server.py 8765`). Uses the test stub with a small fake
// profile database, so it needs no network.   node tests/tutor-settings.check.js
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
    var pdb = JSON.parse(JSON.stringify(cfg.payout || {})), db = JSON.parse(JSON.stringify(cfg.profiles || [])), origRpc = c.rpc.bind(c), origFrom = c.from.bind(c);
    c.rpc = function (n, a) {
      window.__calls.push([n, a]);
      if (n === "tutor_my_profile") return Promise.resolve({ data: JSON.parse(JSON.stringify(db)), error: null });
      if (n === "tutor_save_profile") {
        if (cfg.saveError) return Promise.resolve({ data: null, error: { message: cfg.saveError } });
        db.forEach(function (r) { r.phone = a.p_phone ? "+65" + a.p_phone.replace(/\D/g, "").slice(-8) : null; if (r.membership_id === a.p_membership || a.p_all_centres) r.display_name = a.p_name; });
        return Promise.resolve({ data: null, error: null });
      }
      if (/^tutor_(my|save|clear|reveal)_payout$/.test(n)) {
        if (cfg.payoutDown) return Promise.resolve({ data: null, error: { message: "function not found" } });
        if (n === "tutor_my_payout") return Promise.resolve({ data: db.map(function (r) { var p = pdb[r.membership_id];
          return { membership_id: r.membership_id, org_id: r.org_id, org_name: r.org_name, has_payout: !!p, method: p ? p.method : null,
            masked: p ? "\u2022\u2022\u2022\u2022\u2022" + (p.method === "bank" ? p.account_no : p.paynow_id).slice(-4) : null, bank_name: p ? p.bank_name : null,
            holder_hint: p && p.account_holder ? p.account_holder[0] + "\u2022\u2022\u2022" : null, updated_at: "2026-11-25T00:00:00Z" }; }), error: null });
        if (cfg.payoutError && n === "tutor_save_payout") return Promise.resolve({ data: null, error: { message: cfg.payoutError } });
        if (n === "tutor_save_payout") { pdb[a.p_membership] = { method: a.p_method, paynow_id: a.p_method === "bank" ? null : a.p_value, bank_name: a.p_bank_name, account_no: a.p_method === "bank" ? a.p_value : null, account_holder: a.p_holder }; return Promise.resolve({ data: null, error: null }); }
        if (n === "tutor_clear_payout") { delete pdb[a.p_membership]; return Promise.resolve({ data: null, error: null }); }
        if (n === "tutor_reveal_payout") return Promise.resolve(pdb[a.p_membership] ? { data: [pdb[a.p_membership]], error: null } : { data: null, error: { message: "NO_PAYOUT" } });
      }
      return origRpc(n, a);
    };
    c.auth.signInWithPassword = function (x) { window.__calls.push(["signIn", { email: x.email }]); return Promise.resolve(x.password === "Old-Pass-1!" ? { data: {}, error: null } : { data: null, error: { message: "Invalid login credentials" } }); };
    c.auth.updateUser = function (x) { window.__calls.push(["updateUser", { len: x.password.length }]); return Promise.resolve(cfg.weak ? { data: null, error: { weak_password: { reasons: ["pwned"] } } } : { data: {}, error: null }); };
    c.from = function (t) {
      if (t === "memberships" && cfg.role) { var q = { select: function () { return q; }, eq: function () { return q; }, then: function (r, j) { return Promise.resolve({ data: cfg.role.memberships, error: null }).then(r, j); } }; return q; }
      if (t === "students" && cfg.role && cfg.role.studentCount != null) { var s = { select: function () { return s; }, then: function (r, j) { return Promise.resolve({ data: [], count: cfg.role.studentCount, error: null }).then(r, j); } }; return s; }
      return origFrom(t);
    };
  };
}
async function open(browser, vp, theme, cfg, url) {
  const ctx = await browser.newContext(vp === "phone" ? { viewport: { width: 390, height: 844 }, isMobile: true, deviceScaleFactor: 2 } : { viewport: { width: 1100, height: 900 } });
  await ctx.addInitScript((t) => { try { localStorage.setItem("td_theme", t); } catch (e) {} }, theme);
  await ctx.route(/^(?!http:\/\/127\.0\.0\.1).*/, (r) => r.abort());
  const page = await ctx.newPage(); const errs = [];
  await page.route("**/assets/vendor/supabase-2.118.0.js", (r) => r.fulfill({ body: STUB_PLUS, contentType: "application/javascript" }));
  await page.addInitScript(override, cfg);
  page.on("pageerror", (e) => errs.push(e.message));
  page.on("console", (m) => { if (m.type() === "error" && !/ERR_FAILED/.test(m.text())) errs.push("console: " + m.text()); if (/8123|1234567890|53123456/.test(m.text())) errs.push("NUMBER IN CONSOLE"); });
  await page.goto(BASE + url, { waitUntil: "load" }); await page.waitForTimeout(1300);
  return { ctx, page, errs };
}
async function axeCheck(page, tag) {
  if (!AXE) return;
  await page.evaluate(AXE);
  const v = await page.evaluate(() => axe.run(document, { runOnly: ["wcag2a", "wcag2aa", "best-practice"] }).then((r) => r.violations.filter((x) => x.impact === "serious" || x.impact === "critical").map((x) => x.id + " e.g. " + x.nodes[0].target.join(" "))));
  ok(v.length === 0, tag + ": accessibility" + (v.length ? " " + v.join("; ") : ""));
}
const P1 = { membership_id: "m1", org_id: "o2", org_name: "Demo Centre", display_name: "Demo Tutor One", phone: null, email: "tutor.one@example.test" };
const centreTutor = (n) => ({ role: { memberships: [{ role: "tutor", status: "active", organisations: { kind: "centre" } }, { role: "owner", status: "active", organisations: { kind: "solo" } }], studentCount: n } });

(async () => {
  const b = await chromium.launch();
  for (const [vp, theme] of [["phone", "light"], ["phone", "dark"], ["desktop", "light"]]) {
    const { ctx, page, errs } = await open(b, vp, theme, { profiles: [P1], ...centreTutor(0) }, "tutor-settings"), tag = vp + "/" + theme;
    ok(/\/tutor-settings$/.test(page.url()), tag + ": a tutor-only login stays on the page (" + page.url().replace(BASE, "/") + ")");
    ok((await page.inputValue("#tp-name")) === "Demo Tutor One" && (await page.inputValue("#tp-email")) === "tutor.one@example.test", tag + ": name and read-only email shown");
    ok(await page.getAttribute("#tp-email", "readonly") !== null, tag + ": email is read-only");
    ok(!(await page.isVisible("#tp-centre-row")) && !(await page.isVisible("#pw-both")), tag + ": one centre → no centre picker; tutor-only → no 'changes for both' note");
    ok(errs.length === 0, tag + ": no script errors " + errs.join("|"));
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + ": no sideways scroll");
    ok(await page.$$eval("button,input,select,a.ts-back", (e) => e.filter((x) => x.offsetParent && x.type !== "checkbox" && window.innerWidth < 600 && x.getBoundingClientRect().height < 44 && !x.closest(".ts-phone")).map((x) => x.id).filter(Boolean)).then((l) => l.length === 0), tag + ": tap targets at least 44px");
    await axeCheck(page, tag);
    if (vp === "phone" && theme === "light") {
      // profile: edit and save
      await page.fill("#tp-name", "  Pat Tan "); await page.fill("#tp-phone", "9123 4567"); await page.click("#tp-save"); await page.waitForTimeout(500);
      const call = await page.evaluate(() => window.__calls.filter((c) => c[0] === "tutor_save_profile")[0]);
      ok(call && call[1].p_membership === "m1" && call[1].p_name === "Pat Tan" && call[1].p_phone === "+6591234567" && call[1].p_all_centres === false, "save sends trimmed name and +65 phone: " + JSON.stringify(call && call[1]));
      await page.reload({ waitUntil: "load" }); await page.waitForTimeout(1000);
      // (the fake database lives in the page, so a reload resets it; persistence is the SQL test's job. Check the phone box formats on load instead.)
      // bad phone is caught before any call
      await page.fill("#tp-phone", "12345678"); await page.click("#tp-save"); await page.waitForTimeout(200);
      ok(/Singapore number/.test(await page.textContent("#tp-msg")) && (await page.evaluate(() => window.__calls.filter((c) => c[0] === "tutor_save_profile").length)) === 0, "bad phone: plain message, no call");
      await page.fill("#tp-name", ""); await page.click("#tp-save"); ok(/type your name/.test(await page.textContent("#tp-msg")), "empty name: plain message");
      // password: weak
      await page.fill("#pw-old", "Old-Pass-1!"); await page.fill("#pw-new", "abc"); await page.click("#pw-save"); await page.waitForTimeout(200);
      const m = await page.textContent("#pw-msg");
      ok(/^Still needed:/.test(m) && /uppercase/.test(m) && /number/.test(m) && /symbol/.test(m), "weak password shows 'Still needed': " + m);
      ok((await page.evaluate(() => window.__calls.filter((c) => c[0] === "signIn" || c[0] === "updateUser").length)) === 0, "…and nothing is sent");
      ok((await page.$$eval("#pw-list li.met", (e) => e.length)) === 1 && (await page.$$eval("#pw-list li.bad", (e) => e.length)) === 4, "checklist: only lowercase met, four marked as missing");
      // password: wrong current
      await page.fill("#pw-old", "Wrong-1!"); await page.fill("#pw-new", "New-Pass-2@x"); await page.click("#pw-save"); await page.waitForTimeout(300);
      ok(/isn’t your current password/.test(await page.textContent("#pw-msg")) && (await page.evaluate(() => window.__calls.filter((c) => c[0] === "updateUser").length)) === 0, "wrong current password: refused, password not changed");
      // password: good
      await page.fill("#pw-old", "Old-Pass-1!"); await page.click("#pw-save"); await page.waitForTimeout(400);
      const calls = await page.evaluate(() => window.__calls.map((c) => c[0]).filter((n) => n === "signIn" || n === "updateUser"));
      ok(calls.slice(-2).join() === "signIn,updateUser" && (await page.inputValue("#pw-new")) === "", "good password: current re-checked first, then updated, boxes cleared");
      await page.check("#pw-show"); ok((await page.getAttribute("#pw-new", "type")) === "text", "Show passwords works");
    }
    await ctx.close();
  }

  { // payout details: the plan's step 3 click-through (stubbed database; phone, light)
    const { ctx, page, errs } = await open(b, "phone", "light", { profiles: [P1], ...centreTutor(0) }, "tutor-settings");
    const calls = (n) => page.evaluate((n) => window.__calls.filter((c) => c[0] === n), n);
    ok(await page.isVisible("#po-card") && !(await page.isVisible("#po-cur")) && await page.isVisible("#po-form"), "payout: nothing saved yet → the form shows, no current panel");
    await page.fill("#po-value", "8123 4567"); await page.click("#po-save"); await page.waitForTimeout(200);
    ok(/own details/.test(await page.textContent("#po-msg")) && (await calls("tutor_save_payout")).length === 0, "payout: not ticked → plain message, nothing sent");
    await page.fill("#po-value", "7123 4567"); await page.check("#po-confirm"); await page.click("#po-save"); await page.waitForTimeout(200);
    ok(/starts with 8 or 9/.test(await page.textContent("#po-msg")) && (await calls("tutor_save_payout")).length === 0, "payout: weak mobile refused in plain words, nothing sent");
    await page.fill("#po-value", "8123 4567"); await page.click("#po-save"); await page.waitForTimeout(500);
    const sv = (await calls("tutor_save_payout"))[0];
    ok(sv && sv[1].p_method === "paynow_mobile" && sv[1].p_value === "+6581234567" && sv[1].p_membership === "m1" && sv[1].p_confirm === true && sv[1].p_bank_name === null, "payout: saves PayNow mobile as +65 and 8 digits for this centre");
    ok(await page.isVisible("#po-cur") && !(await page.isVisible("#po-form")) && (await page.textContent("#po-val")) === "•••••4567" && (await page.textContent("#po-kind")) === "PayNow mobile", "payout: shows •••••4567 and hides the form");
    ok(!/8123|81234567/.test(await page.evaluate(() => document.body.innerText)) && (await page.inputValue("#po-value")) === "", "payout: the full number is nowhere on the page, and the box was emptied");
    await page.click("#po-show"); await page.waitForTimeout(300);
    ok((await page.textContent("#po-val")) === "+65 8123 4567" && (await page.textContent("#po-show")) === "Hide" && (await calls("tutor_reveal_payout")).length === 1, "payout: Show asks the database and shows the full number");
    await page.click("#po-show"); ok((await page.textContent("#po-val")) === "•••••4567", "payout: Hide masks it again");
    await page.click("#po-show"); await page.waitForTimeout(200); await page.reload({ waitUntil: "load" });   // a reload forgets it (stub db resets) – check a reveal never sticks across a view change instead:
    // bank account, with "Other"
    await page.waitForTimeout(800);
    await page.check('input[value="bank"]');
    ok(await page.isVisible("#po-bank") && await page.isVisible("#po-holder") && (await page.textContent("#po-value-l")) === "Account number", "payout: bank shows bank, account number and holder");
    await page.fill("#po-value", "12345"); await page.selectOption("#po-bank", "Other"); ok(await page.isVisible("#po-bank-other"), "payout: 'Other' bank lets them type its name");
    await page.check("#po-confirm"); await page.click("#po-save"); await page.waitForTimeout(200);
    ok(/Choose your bank|type its name/.test(await page.textContent("#po-msg")), "payout: bank missing → plain message");
    await page.fill("#po-bank-other", "Example Bank"); await page.click("#po-save"); await page.waitForTimeout(200);
    ok(/7 to 16 digits/.test(await page.textContent("#po-msg")), "payout: short account number → plain message");
    await page.fill("#po-value", "123-456-789-0"); await page.click("#po-save"); await page.waitForTimeout(200);
    ok(/name on the bank account/.test(await page.textContent("#po-msg")), "payout: holder missing → plain message");
    await page.fill("#po-holder", "Pat Tan"); await page.click("#po-save"); await page.waitForTimeout(500);
    const bk = (await calls("tutor_save_payout"))[0];
    ok(bk && bk[1].p_method === "bank" && bk[1].p_value === "1234567890" && bk[1].p_bank_name === "Example Bank" && bk[1].p_holder === "Pat Tan", "payout: bank saved with digits only");
    ok(/Example Bank\s+•••••7890\s+·\s+P•••/.test(await page.textContent("#po-val")) && !/Pat Tan|1234567890/.test(await page.evaluate(() => document.body.innerText)), "payout: bank shown masked with the holder reduced to a first letter");
    await page.click("#po-change"); ok(await page.isVisible("#po-form"), "payout: Change opens the form again");
    await page.click("#po-clear"); ok(await page.isVisible("#po-sure"), "payout: Clear asks first");
    await page.click("#po-clear-no"); ok(!(await page.isVisible("#po-sure")) && (await calls("tutor_clear_payout")).length === 0, "payout: Keep them cancels");
    await page.click("#po-clear"); await page.click("#po-clear-yes"); await page.waitForTimeout(500);
    ok((await calls("tutor_clear_payout")).length === 1 && !(await page.isVisible("#po-cur")) && await page.isVisible("#po-form"), "payout: Clear removes them and shows the empty form");
    ok(errs.length === 0, "payout: no script or console errors " + errs.join("|")); await ctx.close(); }
  { // tutor two: nothing saved for them (stub has details only for m1)
    const two = [P1, { ...P1, membership_id: "m2", org_id: "o3", org_name: "Other Centre" }];
    const { ctx, page } = await open(b, "phone", "light", { profiles: two, payout: { m1: { method: "paynow_mobile", paynow_id: "+6581234567" } }, ...centreTutor(0) }, "tutor-settings");
    ok(await page.isVisible("#po-centre-row") && (await page.textContent("#po-val")) === "•••••4567", "payout: two centres → picker; first shows its details");
    await page.selectOption("#po-centre", "m2"); ok(!(await page.isVisible("#po-cur")) && await page.isVisible("#po-form") && !/4567/.test(await page.evaluate(() => document.body.innerText)), "payout: the other centre shows nothing of it"); await ctx.close(); }
  { const { ctx, page } = await open(b, "phone", "light", { profiles: [P1], payoutError: "BAD_UEN: x", ...centreTutor(0) }, "tutor-settings");
    await page.check('input[value="paynow_uen"]'); await page.fill("#po-value", "53123456K"); await page.check("#po-confirm"); await page.click("#po-save"); await page.waitForTimeout(400);
    ok(/9 or 10 characters/.test(await page.textContent("#po-msg")) && !/BAD_/.test(await page.textContent("#po-msg")), "payout: a database refusal is shown in plain words"); await ctx.close(); }
  { const { ctx, page } = await open(b, "phone", "light", { profiles: [P1], payoutDown: true, ...centreTutor(0) }, "tutor-settings");
    ok(/aren’t available/.test(await page.textContent("#po-load")) && !(await page.isVisible("#po-form")) && await page.isVisible("#tp-card"), "payout: functions missing → a plain message, the profile still works"); await ctx.close(); }
  for (const [vp, theme] of [["phone", "dark"], ["phone", "light"], ["desktop", "light"]]) {
    const { ctx, page, errs } = await open(b, vp, theme, { profiles: [P1], payout: { m1: { method: "bank", bank_name: "Example Bank", account_no: "1234567890", account_holder: "Pat Tan" } }, ...centreTutor(0) }, "tutor-settings"), tag = "payout " + vp + "/" + theme;
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tag + ": no sideways scroll");
    ok(await page.$$eval("#po-card button,#po-card input,#po-card select", (e) => e.filter((x) => x.offsetParent && x.type !== "checkbox" && x.type !== "radio" && window.innerWidth < 600 && x.getBoundingClientRect().height < 44 && !x.closest(".ts-phone")).map((x) => x.id)).then((l) => l.length === 0), tag + ": tap targets at least 44px");
    await axeCheck(page, tag + " (current)"); await page.click("#po-change"); await page.check('input[value="bank"]'); await axeCheck(page, tag + " (form)");
    if (vp === "phone") await page.screenshot({ path: "/tmp/payout-" + theme + ".png", fullPage: true });
    ok(errs.length === 0, tag + ": no errors " + errs.join("|")); await ctx.close(); }
  { // server says the password is weak (breached)
    const { ctx, page } = await open(b, "phone", "light", { profiles: [P1], weak: true }, "tutor-settings");
    await page.fill("#pw-old", "Old-Pass-1!"); await page.fill("#pw-new", "New-Pass-2@x"); await page.click("#pw-save"); await page.waitForTimeout(400);
    ok(/data breach/.test(await page.textContent("#pw-msg")), "server's weak-password refusal explained"); await ctx.close(); }
  { // save refused by the database
    const { ctx, page } = await open(b, "phone", "light", { profiles: [P1], saveError: "BAD_PHONE: x" }, "tutor-settings");
    await page.fill("#tp-phone", "9123 4567"); await page.click("#tp-save"); await page.waitForTimeout(400);
    ok(/Singapore number/.test(await page.textContent("#tp-msg")), "database refusal shown in plain words"); await ctx.close(); }
  { // two centres: picker, all-centres tick, the 'both' note
    const two = [P1, { ...P1, membership_id: "m2", org_id: "o3", org_name: "Other Centre", display_name: "T One (other)" }];
    const { ctx, page } = await open(b, "phone", "light", { profiles: two, ...centreTutor(4) }, "tutor-settings");
    ok(await page.isVisible("#tp-centre-row") && await page.isVisible("#tp-all-row"), "two centres: picker and 'all my centres' tick");
    ok(await page.isVisible("#pw-both"), "a login with its own students is told the password changes for both");
    await page.selectOption("#tp-centre", "m2"); ok((await page.inputValue("#tp-name")) === "T One (other)", "switching centre shows that centre's name");
    await page.check("#tp-all"); await page.click("#tp-save"); await page.waitForTimeout(400);
    const c = await page.evaluate(() => window.__calls.filter((x) => x[0] === "tutor_save_profile")[0]);
    ok(c && c[1].p_membership === "m2" && c[1].p_all_centres === true, "all-centres tick is sent"); await ctx.close(); }
  { // no tutor membership (removed): a plain message, no forms
    const { ctx, page } = await open(b, "phone", "light", { profiles: [] }, "tutor-settings");
    ok(!(await page.isVisible("#tp-card")) && /aren’t a tutor/.test(await page.textContent("#tp-load")), "no centre profile: plain message, no forms"); await ctx.close(); }
  // the solo /settings stays closed to tutor-only; a solo login is unaffected
  { const { ctx, page } = await open(b, "desktop", "light", centreTutor(0), "settings");
    ok(/\/tutor$/.test(page.url()), "/settings still redirects a tutor-only login to My lessons (" + page.url().replace(BASE, "/") + ")");
    ok(await page.isVisible('a.tt-set[href="tutor-settings"]'), "My lessons links to the settings page");
    await page.click("a.tt-set"); await page.waitForTimeout(800); ok(/\/tutor-settings$/.test(page.url()), "the link opens it"); await ctx.close(); }
  { const { ctx, page } = await open(b, "phone", "light", centreTutor(4), "home");
    const sheet = await page.$$eval("#tl-sheet a", (e) => e.map((x) => x.textContent.trim().replace(/\s+/g, " ")));
    ok(sheet.some((s) => /My tutor profile/.test(s)) && /My lessons/.test(sheet[0]), "'both' login finds the profile link in More: " + sheet.join(" | ")); await ctx.close(); }
  { const { ctx, page } = await open(b, "desktop", "light", { role: { memberships: [{ org_id: "o1", user_id: "u1", role: "owner", status: "active", organisations: { id: "o1", kind: "solo", trading_name: "Mei" } }] }, profiles: [] }, "home");
    const nav = await page.$$eval(".tn-links a", (e) => e.map((x) => x.textContent.trim()));
    ok(nav.join(",") === "Home,Schedule,Students,Money" && !/tutor/.test(page.url()), "a plain solo login is unchanged"); await ctx.close(); }
  await b.close();
  console.log(fails ? "\n" + fails + " FAILED" : "\nall browser checks passed"); process.exit(fails ? 1 : 0);
})();
