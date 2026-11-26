"use strict";
// T31a: ONE contact constant, used by the centre Plan tab and by api/billing.js; centres have no Stripe controls in the browser.
const test = require("node:test"), assert = require("node:assert"), fs = require("fs");
const C = require("../assets/js/contact.js");

test("the contact address is one constant and the mailto is built from it", () => {
  assert.strictEqual(C.EMAIL, "tutordeckadmin@gmail.com");
  assert.strictEqual(C.centreBillingMailto("Bright Centre"), "mailto:tutordeckadmin@gmail.com?subject=TutorDeck%20billing%20for%20Bright%20Centre");
  assert.ok(C.centreBillingMailto("").startsWith("mailto:" + C.EMAIL));
});
test("no other file hard-codes the address (change it in assets/js/contact.js only)", () => {
  const files = ["assets/js/org.js", "api/billing.js", "api/billing-cron.js", "api/stripe-webhook.js", "assets/js/plan.js", "org.html"];
  files.forEach((f) => assert.ok(!/tutordeckadmin@/.test(fs.readFileSync(f, "utf8")), f + " must use TDContact / contact.js"));
});
test("the centre Plan tab has no checkout, card or Stripe controls and loads contact.js", () => {
  const org = fs.readFileSync("assets/js/org.js", "utf8"), tab = org.slice(org.indexOf("async function tabPlan"), org.indexOf("// ---", org.indexOf("async function tabPlan"))).replace(/^\s*\/\/.*$/gm, "");
  assert.ok(/invoice and PayNow/.test(tab) && /Contact us/.test(tab));
  assert.ok(!/stripe|checkout|portal|\/api\/billing|card on file|Update card/i.test(tab), "no Stripe controls in the centre Plan tab");
  assert.ok(/contact\.js/.test(fs.readFileSync("org.html", "utf8")));
  assert.ok(org.indexOf("TDContact") > 0);
});
