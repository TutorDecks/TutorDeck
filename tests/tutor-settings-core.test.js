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

// ---------------------------------------------------------------- payout details (T24c step 3)
test("payout: PayNow mobile is +65 and 8 digits starting 8 or 9 (a 6 is a landline); written any usual way", () => {
  for (const s of ["81234567", "8123 4567", "+65 9123-4567", "6591234567", " 9876 5432 "]) assert.strictEqual(T.normalisePaynowMobile(s).ok, true, s);
  assert.strictEqual(T.normalisePaynowMobile("8123 4567").value, "+6581234567");
  for (const s of ["", "61234567", "71234567", "8123456", "812345678", "+44 7911 123456", "81x34567", "+65 6123 4567"]) {
    const r = T.normalisePaynowMobile(s); assert.strictEqual(r.ok, false, s); assert.match(r.error, /starts with 8 or 9/); assert.ok(!r.error.includes(s.trim()) || s.trim() === "");
  }
});
test("payout: the three UEN shapes are accepted (any case, spaces ignored); anything else is refused", () => {
  assert.deepStrictEqual(T.normaliseUen("53123456k"), { ok: true, value: "53123456K" });
  assert.deepStrictEqual(T.normaliseUen("2019 12345 a"), { ok: true, value: "201912345A" });
  assert.deepStrictEqual(T.normaliseUen("2005-12345-B"), { ok: true, value: "200512345B" });
  assert.deepStrictEqual(T.normaliseUen("t08ll1234h"), { ok: true, value: "T08LL1234H" });
  for (const s of ["", "1234", "531234567", "5312345K", "30191234AA", "X08LL1234H", "1819123456"]) assert.strictEqual(T.normaliseUen(s).ok, false, s);
});
test("payout: bank account is 7 to 16 digits after spaces and dashes are ignored", () => {
  assert.deepStrictEqual(T.normaliseAccount("123-456-789-0"), { ok: true, value: "1234567890" });
  assert.strictEqual(T.normaliseAccount("1234567").ok, true); assert.strictEqual(T.normaliseAccount("1234567890123456").ok, true);
  for (const s of ["", "123456", "12345678901234567", "12345X78", "abcdefgh"]) assert.strictEqual(T.normaliseAccount(s).ok, false, s);
});
test("payout: masking shows five dots and the last 4 characters, never more", () => {
  assert.strictEqual(T.mask("+6581234567"), "•••••4567"); assert.strictEqual(T.mask("1234567890"), "•••••7890"); assert.strictEqual(T.mask("53123456K"), "•••••456K");
  assert.strictEqual(T.mask(""), ""); assert.strictEqual(T.mask(null), "");
  assert.ok(!T.mask("+6581234567").includes("8123"));
});
test("payout: validatePayout checks in a sensible order and returns exactly what the database function expects", () => {
  const ok = T.validatePayout({ method: "paynow_mobile", value: "8123 4567", confirm: true });
  assert.deepStrictEqual(ok, { ok: true, args: { p_method: "paynow_mobile", p_value: "+6581234567", p_bank_name: null, p_holder: null, p_confirm: true } });
  assert.deepStrictEqual(T.validatePayout({ method: "paynow_uen", value: "201912345a", bank: "ignored", holder: "ignored", confirm: true }).args,
    { p_method: "paynow_uen", p_value: "201912345A", p_bank_name: null, p_holder: null, p_confirm: true });
  assert.deepStrictEqual(T.validatePayout({ method: "bank", value: "123-456-789-0", bank: " Example Bank ", holder: " Pat Tan ", confirm: true }).args,
    { p_method: "bank", p_value: "1234567890", p_bank_name: "Example Bank", p_holder: "Pat Tan", p_confirm: true });
  const bad = (f) => T.validatePayout(Object.assign({ method: "bank", value: "1234567890", bank: "Example Bank", holder: "Pat Tan", confirm: true }, f));
  assert.strictEqual(bad({ method: "" }).field, "method"); assert.strictEqual(bad({ method: "cheque" }).field, "method");
  assert.strictEqual(bad({ bank: "" }).field, "bank"); assert.strictEqual(bad({ bank: "x" }).field, "bank");
  assert.strictEqual(bad({ value: "123" }).field, "value"); assert.strictEqual(bad({ holder: "P" }).field, "holder"); assert.strictEqual(bad({ holder: "x".repeat(81) }).field, "holder");
  assert.strictEqual(bad({ confirm: false }).field, "confirm"); assert.match(bad({ confirm: false }).error, /own details/);
  assert.strictEqual(T.validatePayout({ method: "paynow_mobile", value: "71234567", confirm: true }).field, "value");
  assert.strictEqual(T.validatePayout({ method: "paynow_uen", value: "12", confirm: true }).field, "value");
  for (const r of [bad({ bank: "" }), bad({ confirm: false }), T.validatePayout({ method: "paynow_mobile", value: "71234567", confirm: true })]) assert.ok(!/BAD_|NEED_|undefined/.test(r.error));
});
test("payout: Show formats the full value for each method", () => {
  assert.strictEqual(T.payoutDisplay({ method: "paynow_mobile", paynow_id: "+6581234567" }), "+65 8123 4567");
  assert.strictEqual(T.payoutDisplay({ method: "paynow_uen", paynow_id: "53123456K" }), "53123456K");
  assert.strictEqual(T.payoutDisplay({ method: "bank", bank_name: "Example Bank", account_no: "1234567890", account_holder: "Pat Tan" }), "Example Bank · 1234567890 · Pat Tan");
  assert.strictEqual(T.payoutDisplay(null), "");
});
test("payout: database refusals read in plain words, never show a code, and never repeat what was typed", () => {
  const codes = ["BAD_PAYNOW_MOBILE", "BAD_UEN", "BAD_ACCOUNT", "BAD_BANK_NAME", "BAD_HOLDER", "BAD_METHOD", "NEED_CONFIRM", "NO_PAYOUT", "NOT_FOUND", "boom"];
  for (const c of codes) { const t = T.payoutErrorText({ message: c + ": x" }); assert.doesNotMatch(t, /BAD_|NEED_|NO_PAYOUT|NOT_FOUND|boom/, c); assert.ok(t.length > 10, c); }
  assert.match(T.payoutErrorText({ message: "BAD_PAYNOW_MOBILE: whatever" }), /8 or 9/); assert.match(T.payoutErrorText({ message: "NEED_CONFIRM" }), /own details/);
  assert.match(T.payoutErrorText(null), /try again/);
  assert.ok(T.BANKS.includes("Other") && T.BANKS.length >= 5); assert.deepStrictEqual(Object.keys(T.METHODS), ["paynow_mobile", "paynow_uen", "bank"]);
});
