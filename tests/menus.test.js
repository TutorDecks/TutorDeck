"use strict";
// UX1: what every kind of login sees in the menu, and that no two DIFFERENT destinations of one menu share an icon.
// Pure logic (assets/js/menus.js + assets/js/org-current.js): no browser. The browser check tests/menus.check.js prints the same menus as drawn.
const test = require("node:test"), assert = require("node:assert");
const M = require("../assets/js/menus.js"), OC = require("../assets/js/org-current.js");

const SOLO = { id: "s1", kind: "solo", role: "owner", name: "Solo" };
const C = (role, perms) => ({ id: "c1", kind: "centre", role, name: "Centre", perms });
const ALL = ["manage_students", "manage_timetable", "issue_invoices", "manage_tutors"];
// every login that exists: [name, roleMode, current organisation]
const ROLES = [
  ["solo tutor", "solo", SOLO],
  ["solo tutor, roleMode unknown", null, SOLO],
  ["both, in their solo organisation", "both", SOLO],
  ["both, working in the centre", "both", C("tutor")],
  ["centre-only tutor", "tutor-only", C("tutor")],
  ["centre-only tutor, organisation unknown", "tutor-only", { id: null, kind: "solo", role: null, name: "" }],
  ["centre owner", "solo", C("owner")],
  ["centre staff, every permission", "solo", C("staff", ALL)],
  ["centre staff, front desk (students only)", "solo", C("staff", ["manage_students"])],
  ["centre staff, timetable only", "solo", C("staff", ["manage_timetable"])],
  ["centre staff, money only", "solo", C("staff", ["issue_invoices"])],
  ["centre staff, people only", "solo", C("staff", ["manage_tutors"])],
  ["centre staff, no permission", "solo", C("staff", [])],
  ["solo tutor with an unknown organisation", "solo", { id: null, kind: "solo", role: null, name: "" }]
];
const menuOf = (mode, org) => M.build(mode, org, OC.centreTabs(org));
const ids = (a) => a.map((x) => x.id);

test("no two different destinations of one menu share an icon, for every role", () => {
  for (const [name, mode, org] of ROLES) {
    const menu = menuOf(mode, org);
    assert.deepStrictEqual(M.duplicateIcons(menu), [], name + ": " + JSON.stringify(M.items(menu).map((n) => n.label + "=" + n.ic)));
  }
});
test("the check itself catches a shared icon", () => {
  const bad = { groups: [{ id: "a", label: "Schedule", ic: "schedule" }], extras: [{ id: "b", label: "My lessons", ic: "schedule" }] };
  assert.strictEqual(M.duplicateIcons(bad).length, 1);
});
test("every icon id a menu uses has a picture, and every picture is different", () => {
  for (const [name, mode, org] of ROLES) for (const n of M.items(menuOf(mode, org))) assert.ok(M.ICONS[n.ic], name + ": no picture for " + n.ic);
  const paths = Object.keys(M.ICONS).map((k) => M.ICONS[k]);
  assert.strictEqual(new Set(paths).size, paths.length, "two icon ids draw the same picture");
  for (const k of Object.keys(M.ICONS)) assert.ok(/^<(path|circle|rect)/.test(M.ICONS[k]), k);
});
test("the same page keeps the same icon in every menu (a centre's Timetable is never My lessons)", () => {
  const by = {};
  for (const [name, mode, org] of ROLES) for (const n of M.items(menuOf(mode, org))) { (by[n.label] = by[n.label] || new Set()).add(n.ic); }
  assert.deepStrictEqual([...by["My lessons"]], ["lessons"]);
  assert.deepStrictEqual([...by["Timetable"]], ["timetable"]);
  assert.deepStrictEqual([...by["People"]], ["people"]);
  assert.deepStrictEqual([...by["Settings"]], ["settings"]);
  assert.deepStrictEqual([...by["Centre settings"]], ["centre"]);
  assert.deepStrictEqual([...by["Your centres"]], ["centres"]);
});
test("solo tutor: the normal menu, nothing about a centre", () => {
  const m = menuOf("solo", SOLO);
  assert.deepStrictEqual(ids(m.groups), ["home", "schedule", "students", "money"]);
  assert.deepStrictEqual(ids(m.extras), ["materials", "settings"]);
  assert.strictEqual(m.kind, "solo");
});
test("both-role tutor in their SOLO organisation: exactly the solo menu plus ONE centre entry under More", () => {
  const solo = menuOf("solo", SOLO), both = menuOf("both", SOLO);
  assert.deepStrictEqual(ids(both.groups), ids(solo.groups));
  assert.deepStrictEqual(ids(both.extras), ["tutor", "materials", "settings"]);
  assert.strictEqual(both.extras.filter((n) => /^tutor/.test(n.href)).length, 1, "one centre entry");
  const labels = both.extras.map((n) => n.label);
  assert.ok(!labels.includes("My tutor profile"));
  assert.deepStrictEqual(both.extras.filter((n) => n.label === "Settings").map((n) => n.href), ["settings"], "Settings is the solo Settings page");
  assert.ok(!both.extras.some((n) => n.href === "tutor-settings"));
  assert.deepStrictEqual(ids(both.extras[0].pages), ["tutor", "tutor-schedule"], "its Schedule is a sub-tab, not a second menu entry");
});
test("both-role tutor working in the centre gets the tutor menu, and Settings is /tutor-settings", () => {
  const m = menuOf("both", C("tutor"));
  assert.deepStrictEqual(ids(m.groups), ["tutor", "tutor-schedule"]);
  assert.deepStrictEqual(m.extras.map((n) => n.href), ["tutor-settings"]);
  assert.deepStrictEqual(m.extras.map((n) => n.label), ["Settings"]);
  assert.deepStrictEqual(menuOf("tutor-only", C("tutor")).extras, m.extras);
});
test("Settings is never offered twice: the solo page and the tutor page never share one menu", () => {
  for (const [name, mode, org] of ROLES) {
    const hrefs = menuOf(mode, org).extras.map((n) => n.href), settings = hrefs.filter((h) => h === "settings" || h === "tutor-settings");
    assert.strictEqual(settings.length, 1, name + ": " + hrefs);
    assert.ok(menuOf(mode, org).extras.filter((n) => n.label === "Settings").length <= 1, name);
  }
});
test("centre owner / staff: Centre settings, Your centres and Settings are three different entries", () => {
  const m = menuOf("solo", C("owner"));
  assert.deepStrictEqual(ids(m.groups), ["orghome", "orgtt", "orgst", "orgatt", "orgmoney", "orgpeople"]);
  assert.deepStrictEqual(ids(m.extras), ["orgsettings", "orglist", "settings"]);
  assert.deepStrictEqual(m.extras.map((n) => n.ic), ["centre", "centres", "settings"]);
  // Students (the centre's students) and Your centres no longer share a picture
  assert.notStrictEqual(m.groups.find((g) => g.id === "orgst").ic, m.extras.find((n) => n.id === "orglist").ic);
  // staff see only what their permissions allow
  assert.deepStrictEqual(ids(menuOf("solo", C("staff", ["manage_students"])).groups), ["orghome", "orgtt", "orgst"]);
});
test("a tutor-only login never gets the solo screens' menu, whatever organisation is remembered", () => {
  for (const org of [SOLO, C("tutor"), { id: null, kind: "solo", role: null, name: "" }]) {
    const m = menuOf("tutor-only", org);
    assert.deepStrictEqual(ids(m.groups), ["tutor", "tutor-schedule"]);
    assert.deepStrictEqual(m.extras.map((n) => n.href), ["tutor-settings"]);
  }
});
