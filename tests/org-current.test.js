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

test("centre owner with an empty solo organisation: solo is dropped, centre is the default, no chip", () => {
  const l = OC.dropEmptySolo(OC.list([SOLO, CA]), 0);
  assert.deepStrictEqual(ids(l), ["c1"]);
  assert.strictEqual(OC.pick(l).id, "c1");
  assert.strictEqual(OC.showSwitcher(l, "solo"), false);
  assert.strictEqual(OC.pick(l, "s1").id, "c1");   // a remembered solo choice is no longer valid
});
test("empty solo + two owned centres: chip shows for the centres only", () => {
  const CO = Object.assign({}, CB, { role: "owner" });
  const l = OC.dropEmptySolo(OC.list([SOLO, CA, CO]), 0);
  assert.deepStrictEqual(ids(l), ["c1", "c2"]);
  assert.strictEqual(OC.showSwitcher(l, "solo"), true);
});
test("a solo tutor with students is never moved; doubt or error keeps solo", () => {
  const l = OC.list([SOLO, CA]);
  for (const n of [1, 5, null, undefined, NaN, "0", -1]) assert.deepStrictEqual(ids(OC.dropEmptySolo(l, n)), ["s1", "c1"], String(n));
  assert.strictEqual(OC.pick(OC.dropEmptySolo(l, 3)).id, "s1");
});
test("empty solo but only a tutor/staff role at the centre: solo is kept (not an owner)", () => {
  assert.deepStrictEqual(ids(OC.dropEmptySolo(OC.list([SOLO, CB]), 0)), ["s1", "c2"]);
  assert.deepStrictEqual(ids(OC.dropEmptySolo(OC.list([SOLO, CT]), 0)), ["s1", "c3"]);
  assert.deepStrictEqual(ids(OC.dropEmptySolo(OC.list([SOLO]), 0)), ["s1"]);
  assert.strictEqual(OC.dropEmptySolo(null, 0), null);
});
test("Home redirects only owners/admins whose current organisation is a centre", () => {
  assert.strictEqual(OC.homeRedirect("dashboard", { kind: "centre", id: "c1", role: "owner" }), "org?id=c1");
  assert.strictEqual(OC.homeRedirect("dashboard", { kind: "centre", id: "c2", role: "staff" }), "org?id=c2");
  assert.strictEqual(OC.homeRedirect("dashboard", { kind: "centre", id: "c3", role: "tutor" }), null);
  assert.strictEqual(OC.homeRedirect("dashboard", { kind: "solo", id: "s1", role: "owner" }), null);
  assert.strictEqual(OC.homeRedirect("dashboard", { kind: "solo", id: null, role: null }), null);
  assert.strictEqual(OC.homeRedirect("ledger", { kind: "centre", id: "c1", role: "owner" }), null);
  for (const bad of [null, undefined, {}, "x"]) assert.strictEqual(OC.homeRedirect("dashboard", bad), null);
});
