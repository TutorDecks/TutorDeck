"use strict";
// Which organisation is "current" (assets/js/org-current.js) and when the switcher shows. Pure logic, no browser.
const test = require("node:test"), assert = require("node:assert");
const OC = require("../assets/js/org-current.js");

const SOLO = { org_id: "s1", role: "owner", status: "active", organisations: { id: "s1", kind: "solo", trading_name: "Mei Tuition" } };
const CA = { org_id: "c1", role: "owner", status: "active", organisations: { id: "c1", kind: "centre", trading_name: "Alpha Centre" } };
const CB = { org_id: "c2", role: "staff", status: "active", organisations: { id: "c2", kind: "centre", trading_name: "Beta Centre" } };
const CT = { org_id: "c3", role: "tutor", status: "active", organisations: { id: "c3", kind: "centre", trading_name: "Gamma Centre" } };
const ids = (a) => a.map((o) => o.id);

test("solo only: the solo organisation, no switcher", () => {
  const c = OC.choose([SOLO]);
  assert.deepStrictEqual(c, { id: "s1", kind: "solo", role: "owner", name: "Mei Tuition" });
  assert.strictEqual(OC.showSwitcher(OC.list([SOLO]), "solo"), false);
});
test("solo + centre: solo is the default, switcher shows", () => {
  assert.strictEqual(OC.choose([CA, SOLO]).id, "s1");
  assert.deepStrictEqual(ids(OC.list([CA, SOLO])), ["s1", "c1"]);
  assert.strictEqual(OC.showSwitcher(OC.list([CA, SOLO]), "solo"), true);
  assert.strictEqual(OC.showSwitcher(OC.list([CT, SOLO]), "both"), true);
});
test("two centres and no solo: first centre by name; switcher shows", () => {
  assert.strictEqual(OC.choose([CB, CA]).id, "c1");
  assert.strictEqual(OC.showSwitcher(OC.list([CB, CA]), "solo"), true);
});
test("only one centre and no solo: that centre; no switcher", () => {
  assert.strictEqual(OC.choose([CB]).id, "c2");
  assert.strictEqual(OC.showSwitcher(OC.list([CB]), "solo"), false);
});
test("remembered choice wins when it is still one of theirs", () => {
  assert.strictEqual(OC.choose([SOLO, CA, CB], "c2").id, "c2");
  assert.strictEqual(OC.choose([SOLO, CA], "s1").id, "s1");
});
test("remembered choice no longer valid: falls back to solo, then to the only centre", () => {
  assert.strictEqual(OC.choose([SOLO, CA], "gone").id, "s1");
  assert.strictEqual(OC.choose([CA], "gone").id, "c1");
  const inactive = Object.assign({}, CB, { status: "removed" });
  assert.strictEqual(OC.choose([SOLO, inactive], "c2").id, "s1");   // a removed membership is not an option
});
test("errors and bad data give null (the caller then uses the solo organisation)", () => {
  for (const bad of [null, undefined, [], {}, "x", 5, [null], [{}], [{ org_id: "x", role: "owner", status: "active" }],
    [{ org_id: "x", role: "owner", status: "active", organisations: { kind: "weird" } }]])
    assert.strictEqual(OC.choose(bad, "c1"), null, JSON.stringify(bad));
  assert.strictEqual(OC.pick(null), null);
  assert.strictEqual(OC.showSwitcher(null, "solo"), false);
});
test("parents and invited/removed rows are not organisations to work in", () => {
  const parent = Object.assign({}, CA, { role: "parent" }), invited = Object.assign({}, CB, { status: "invited" });
  assert.deepStrictEqual(ids(OC.list([SOLO, parent, invited])), ["s1"]);
});
test("one organisation with two memberships counts once, with the strongest role", () => {
  const asTutor = Object.assign({}, CA, { role: "tutor" });
  const l = OC.list([asTutor, CA, SOLO]);
  assert.deepStrictEqual(ids(l), ["s1", "c1"]);
  assert.strictEqual(l[1].role, "owner");
});
test("tutor-only logins never get a switcher", () => {
  assert.strictEqual(OC.showSwitcher(OC.list([SOLO, CT]), "tutor-only"), false);
});
test("landing: solo → home; centre → its page; a centre tutor → My lessons", () => {
  assert.strictEqual(OC.landing({ kind: "solo", id: "s1", role: "owner" }), "home");
  assert.strictEqual(OC.landing({ kind: "centre", id: "c1", role: "owner" }), "org?id=c1");
  assert.strictEqual(OC.landing({ kind: "centre", id: "c2", role: "staff" }), "org?id=c2");
  assert.strictEqual(OC.landing({ kind: "centre", id: "c3", role: "tutor" }), "tutor");
  assert.strictEqual(OC.landing(null), "home");
});
