"use strict";
const test = require("node:test"), assert = require("node:assert");
const P = require("../assets/js/password-rules.js");
const SYM = "a symbol (like ! ? # @)";

test("a password meeting everything has no problems", () => {
  assert.deepStrictEqual(P.problems("Abcdef1!"), []);
  assert.deepStrictEqual(P.problems("Correct-Horse-9"), []);
});
test("each rule missing on its own is reported alone", () => {
  assert.deepStrictEqual(P.problems("ABCDEF1!"), ["a lowercase letter"]);
  assert.deepStrictEqual(P.problems("abcdef1!"), ["an uppercase letter"]);
  assert.deepStrictEqual(P.problems("Abcdefg!"), ["a number"]);
  assert.deepStrictEqual(P.problems("Abcdefg1"), [SYM]);
  assert.deepStrictEqual(P.problems("Ab1!"), ["at least 8 characters (4 more)"]);
});
test("empty and non-string input list everything", () => {
  assert.strictEqual(P.problems("").length, 5);
  assert.strictEqual(P.problems(null).length, 5);
  assert.strictEqual(P.problems(undefined).length, 5);
});
test("length is exactly the minimum", () => {
  assert.deepStrictEqual(P.problems("Abcde1!"), ["at least 8 characters (1 more)"]);
  assert.deepStrictEqual(P.problems("Abcdef1!"), []);
});
test("space, accented letters, emoji and non-ASCII digits do not count", () => {
  assert.ok(P.problems("Abcdef1 ").includes(SYM));
  assert.ok(P.problems("ABCDEF1!é").includes("a lowercase letter"));
  assert.ok(P.problems("abcdef1!É").includes("an uppercase letter"));
  assert.ok(P.problems("Abcdefg1😀").includes(SYM));
  assert.ok(P.problems("Abcdefg١!").includes("a number"));
});
test("every character of the symbol list counts as a symbol", () => {
  for (const c of P.SYMBOLS) assert.deepStrictEqual(P.problems("Abcdef1" + c), [], "symbol " + c);
  assert.strictEqual(P.SYMBOLS.length, 32);
});
test("rule list drives the summary", () => {
  assert.match(P.summary(), /8 characters/);
  assert.strictEqual(P.RULES.length, 4);
});
