"use strict";
// The central "tutor-only logins can't open solo pages" decision in assets/js/app.js (TL.tutorOnlyRedirect).
const test = require("node:test"), assert = require("node:assert"), fs = require("fs"), path = require("path"), vm = require("vm");

function loadTL() {
  const store = {};
  const ls = { getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); }, removeItem: k => { delete store[k]; }, key: i => Object.keys(store)[i], get length() { return Object.keys(store).length; } };
  const el = () => ({ addEventListener() {}, style: {}, classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } }, setAttribute() {}, appendChild() {}, querySelector() { return null; }, querySelectorAll() { return []; } });
  const document = { getElementById: () => null, querySelector: () => null, querySelectorAll: () => [], createElement: el, addEventListener() {}, body: el(), head: el(), documentElement: el(), readyState: "loading", cookie: "" };
  const win = { document, localStorage: ls, location: { pathname: "/", href: "", replace() {} }, addEventListener() {}, matchMedia: () => ({ matches: false, addEventListener() {} }), sb: null };
  win.window = win;
  const ctx = vm.createContext(Object.assign(win, { localStorage: ls, document, console, setTimeout() {}, clearTimeout() {}, navigator: { userAgent: "" } }));
  vm.runInContext(fs.readFileSync(path.join(__dirname, "../assets/js/app.js"), "utf8"), ctx);
  return ctx.TL;
}
const TL = loadTL();
const R = TL.tutorOnlyRedirect;

test("tutor-only logins are sent to My lessons from every solo page", () => {
  for (const p of ["dashboard", "insights", "students", "student", "ledger", "planner", "calendar", "invoices", "exams", "org", "materials", "settings"])
    assert.strictEqual(R(p, "tutor-only"), "tutor", p);
});
test("tutor-only logins may stay on My lessons only (no redirect loop); Settings now redirects", () => {
  assert.strictEqual(R("tutor", "tutor-only"), null);
  assert.strictEqual(R("settings", "tutor-only"), "tutor");
});
test("(S7b) a tutor-only login may open Your pay as well (no redirect loop), and it is the only other page", () => {
  assert.strictEqual(R("mypay", "tutor-only"), null);
  for (const mode of ["solo", "both", null]) assert.strictEqual(R("mypay", mode), null);
});
test("(S7b) with nothing remembered (or signed out) there is no Your pay menu entry, and setting it never throws", () => {
  assert.strictEqual(TL.payOn(), false);
  assert.doesNotThrow(() => TL.setPayView(true));      // the store is per signed-in user: with nobody signed in it keeps nothing, so still no entry
  assert.strictEqual(TL.payOn(), false);
});
test("solo, both and unknown logins are never redirected, on any page", () => {
  for (const mode of ["solo", "both", null, undefined, "", "TUTOR-ONLY", "tutor", "centre", 1, {}])
    for (const p of ["dashboard", "students", "ledger", "planner", "settings", "org", "tutor", "exams", "invoices", "calendar"])
      assert.strictEqual(R(p, mode), null, mode + " on " + p);
});
test("a page with no name never redirects", () => { assert.strictEqual(R("", "tutor-only"), null); assert.strictEqual(R(undefined, "tutor-only"), null); });
