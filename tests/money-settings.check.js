// Browser check (T4 S0): the centre wizard shows the centre-money options as "Coming soon" and disabled; 1-to-1 hides group-only options;
// a bad percent is refused; phone width, dark mode, no console errors.
//   python3 tests/server.py 8765 &   node tests/money-settings.check.js [screenshot-dir]
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), SC = process.argv[2] || null, BASE = "http://127.0.0.1:8765/";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };
const SOON_IDS = ["f-billing-deposit-top_up", "f-billing-deposit-set_off_unpaid",
  "f-billing-deposit-final_month", "f-billing-trials-charged"];
// T4 S6: every late-fee option is built (editable); only the "a line on the family's next invoice" placement is still to come
const LATE_IDS = ["f-billing-late_fee-enabled", "f-billing-late_fee-repeat", "f-billing-late_fee-type", "f-billing-late_fee-amount_cents", "f-billing-late_fee-percent_bp",
  "f-billing-late_fee-after_days", "f-billing-late_fee-cap_cents", "f-billing-late_fee-show_as", "f-billing-late_fee-waived_by"];
(async () => {
  const b = await chromium.launch(process.env.PW_EXE ? { executablePath: process.env.PW_EXE } : {});
  for (const vp of ["desktop", "phone", "dark"]) {
    const ctx = await b.newContext(vp === "phone" ? { viewport: { width: 390, height: 844 }, isMobile: true } : { viewport: { width: 1100, height: 900 }, colorScheme: vp === "dark" ? "dark" : "light" });
    await ctx.route(/^(?!http:\/\/127\.0\.0\.1).*/, (r) => r.abort());
    const page = await ctx.newPage(), errs = [];
    page.on("pageerror", (e) => errs.push(e.message)); page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource/.test(m.text())) errs.push(m.text()); });   // external fonts are blocked on purpose, so 'Failed to load resource' is expected
    await page.route("**/assets/vendor/supabase-2.118.0.js", (r) => r.fulfill({ body: STUB, contentType: "application/javascript" }));
    await page.goto(BASE + "org.html?id=o2#billing", { waitUntil: "load" }); await page.waitForTimeout(1300);
    if (vp === "dark") { await page.evaluate(() => document.documentElement.setAttribute("data-theme", "dark")); await page.waitForTimeout(200); }
    const og = await page.textContent("#og");
    for (const id of SOON_IDS) { const el = await page.$("#" + id); ok(!!el && await el.evaluate((e) => e.disabled), vp + ": " + id + " shown and disabled"); }
    for (const id of LATE_IDS) { const el = await page.$("#" + id); ok(!!el && await el.evaluate((e) => !e.disabled), vp + ": " + id + " is built, so it is editable"); }
    ok(await page.$eval("#f-billing-late_fee-show_as option[value='\"next_invoice_line\"']", (e) => e.disabled && /coming soon/.test(e.textContent)), vp + ": 'a line on the next invoice' is still marked coming soon");
    ok(await page.$eval("#f-billing-late_fee-show_as option[value='\"own_invoice\"']", (e) => !e.disabled), vp + ": 'its own small invoice' is available");
    for (const h of ["Refundable deposit", "Late fees"]) ok(og.includes(h), vp + ": sub-heading " + h);
    ok(og.includes("always approved and recorded step by step") && og.includes("comes in a later update") && og.includes("A person approves or waives each one"), vp + ": help says what is built and what is missing");
    for (const id of ["f-billing-deposit-mode", "f-billing-deposit-taxable", "f-billing-deposit-due", "f-billing-deposit-waived_by", "f-billing-deposit-release", "f-billing-deposit-forfeit_notice_days", "f-billing-deposit-refund_approved_by"]) ok(await page.$eval("#" + id, (e) => !e.disabled), vp + ": " + id + " is editable now (S4/S5)");
    const nSoon = (await page.$$(".og-soon")).length;
    ok(nSoon >= 10, vp + ": Coming soon badges (" + nSoon + ")");
    ok(await page.$eval("#f-billing-sibling_discount-type", (e) => !e.disabled), vp + ": sibling discount still editable");
    ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), vp + ": no sideways scroll");
    if (SC) await page.screenshot({ path: path.join(SC, "money-billing-" + vp + ".png"), fullPage: true });
    // a bad percent is refused (the editable sibling-discount percent; the new deposit/late-fee percents are locked until their step ships)
    await page.selectOption("#f-billing-sibling_discount-type", "\"percent\""); await page.waitForTimeout(200);
    await page.fill("#f-billing-sibling_discount-percent_bp", "150"); await page.waitForTimeout(300);
    ok(/over 100%/.test(await page.textContent("#og")), vp + ": 150% sibling discount is refused on screen");
    ok(await page.evaluate(() => { const s = OrgSettings.defaults(); s.profile.trading_name = "x"; s.billing.deposit.mode = "percent_first_month"; s.billing.deposit.percent_bp = 0;
      return OrgSettings.validate(s).some((m) => /Deposit percentage/.test(m)); }), vp + ": a 0% deposit percentage is refused by the validator");
    // class type: 1-to-1 hides the group-only options
    await page.click("[data-step=profile]"); await page.waitForTimeout(400);
    ok(await page.$eval("#f-lessons-class_type", (e) => !e.disabled), vp + ": class type editable");
    await page.click("[data-step=tutor_pay]"); await page.waitForTimeout(300);
    ok(!!(await page.$("#f-tutor_pay-group_count")), vp + ": group-only field shown for 'both'");
    const opts = await page.$$eval("#f-tutor_pay-rate_model option", (o) => o.map((x) => [x.textContent, x.disabled]));
    ok(opts.some(([t]) => /per student/i.test(t)), vp + ": per-student rate offered for 'both'");
    ok(opts.some(([t, d]) => /percentage/i.test(t) && !d && !/coming soon/i.test(t)), vp + ": percentage rate is built (T4 S7): offered and not marked coming soon");
    if (SC) await page.screenshot({ path: path.join(SC, "money-pay-both-" + vp + ".png"), fullPage: true });
    await page.click("[data-step=profile]"); await page.waitForTimeout(300);
    await page.selectOption("#f-lessons-class_type", "\"one_to_one\""); await page.waitForTimeout(300);
    await page.click("[data-step=tutor_pay]"); await page.waitForTimeout(300);
    ok(!(await page.$("#f-tutor_pay-group_count")), vp + ": 1-to-1 hides the group-only field");
    const opts2 = await page.$$eval("#f-tutor_pay-rate_model option", (o) => o.map((x) => x.textContent));
    ok(!opts2.some((t) => /per student/i.test(t)), vp + ": 1-to-1 hides the per-student rate");
    if (SC) await page.screenshot({ path: path.join(SC, "money-pay-1to1-" + vp + ".png"), fullPage: true });
    ok(errs.length === 0, vp + ": no console/page errors " + errs.join("|"));
    await ctx.close();
  }
  await b.close(); console.log(fails ? fails + " FAILED" : "ALL PASS"); process.exit(fails ? 1 : 0);
})();
