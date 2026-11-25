"use strict";
const test = require("node:test"), assert = require("node:assert");
const T = require("../assets/js/tutor-settings-core.js");

test("phone: a Singapore number is accepted in the ways people type it and stored as +65 and 8 digits", () => {
  for (const s of ["91234567", "9123 4567", "9123-4567", " 9123 4567 ", "+65 9123 4567", "6591234567", "+6591234567", "81234567", "61234567"])
    assert.deepStrictEqual(T.normalisePhone(s), { ok: true, value: "+65" + s.replace(/[^\d]/g, "").replace(/^65(?=\d{8}$)/, "") }, s);
});
test("phone: empty clears it, anything else that is not a Singapore number is refused in plain words", () => {
  assert.deepStrictEqual(T.normalisePhone(""), { ok: true, value: null }); assert.deepStrictEqual(T.normalisePhone(null), { ok: true, value: null });
  for (const s of ["12345678", "9123456", "912345678", "+44 7911 123456", "abcd efgh", "+65 1234 5678", "9123 456x"]) {
    const r = T.normalisePhone(s); assert.strictEqual(r.ok, false, s); assert.match(r.error, /Singapore number/);
  }
});
test("phone is shown and edited with the +65 handled for them", () => {
  assert.strictEqual(T.phoneDisplay("+6591234567"), "+65 9123 4567"); assert.strictEqual(T.phoneForEdit("+6591234567"), "9123 4567");
  assert.strictEqual(T.phoneDisplay(null), ""); assert.strictEqual(T.phoneForEdit(""), ""); assert.strictEqual(T.phoneForEdit("garbage"), "");
});
test("name: 1 to 80 characters after trimming", () => {
  assert.strictEqual(T.nameProblem("Pat Tan"), null); assert.strictEqual(T.nameProblem("  x "), null); assert.strictEqual(T.nameProblem("x".repeat(80)), null);
  assert.match(T.nameProblem(""), /type your name/); assert.match(T.nameProblem("   "), /type your name/); assert.match(T.nameProblem("x".repeat(81)), /80/);
});
test("database refusals read in plain words (and never show the raw code)", () => {
  assert.match(T.errorText({ message: "BAD_PHONE: use a Singapore mobile number" }), /Singapore number/);
  assert.match(T.errorText({ message: "BAD_NAME: use 1 to 80 characters" }), /name/);
  assert.match(T.errorText({ message: "NOT_FOUND" }), /reload/);
  assert.match(T.errorText({ message: "boom" }), /try again/); assert.match(T.errorText(null), /try again/);
  for (const m of ["BAD_PHONE: x", "BAD_NAME: x", "NOT_FOUND", "boom"]) assert.doesNotMatch(T.errorText({ message: m }), /BAD_|NOT_FOUND/);
});
test("a weak-password refusal from the server is explained; other errors are not mistaken for it", () => {
  assert.match(T.weakPasswordText({ weak_password: { reasons: ["length", "characters"] } }, 8), /at least 8 characters.*lowercase and an uppercase letter, a number and a symbol/);
  assert.match(T.weakPasswordText({ weak_password: { reasons: ["pwned"] } }, 8), /data breach/);
  assert.match(T.weakPasswordText({ code: "weak_password" }, 8), /isn’t strong enough/);
  assert.strictEqual(T.weakPasswordText({ message: "network" }, 8), null); assert.strictEqual(T.weakPasswordText(null, 8), null);
});
