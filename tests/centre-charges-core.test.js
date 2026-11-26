"use strict";
const test = require("node:test"), assert = require("node:assert");
const C = require("../assets/js/centre-charges-core.js");

const R = (id, price, o) => Object.assign({ lesson_id: id, price_cents: price, attendance: "absent", suggested_cents: null, lesson_date: "2026-11-24",
  start_time: "15:00:00", end_time: "16:00:00" }, o || {});

test("money is whole cents: S$ formatting and the text for an input box", () => {
  assert.strictEqual(C.fmt(12345), "S$123.45");
  assert.strictEqual(C.fmt(0), "S$0.00");
  assert.strictEqual(C.fmt(123456), "S$1,234.56");
  assert.strictEqual(C.plain(12345), "123.45");
  assert.strictEqual(C.plain(123456), "1234.56");             // no thousands comma inside an input
  assert.strictEqual(C.plain(0), "0.00");
});
test("a typed charge becomes exact cents, from the text", () => {
  assert.deepStrictEqual(C.parseCharge("0", 12345), { ok: true, cents: 0 });
  assert.deepStrictEqual(C.parseCharge("25", 12345), { ok: true, cents: 2500 });
  assert.deepStrictEqual(C.parseCharge("60.5", 12345), { ok: true, cents: 6050 });
  assert.deepStrictEqual(C.parseCharge("S$123.45", 12345), { ok: true, cents: 12345 });
  assert.deepStrictEqual(C.parseCharge(" 1,000 ", 100000), { ok: true, cents: 100000 });
  assert.deepStrictEqual(C.parseCharge("0.1", 12345), { ok: true, cents: 10 });
  assert.strictEqual(C.parseCharge("19.99", 5000).cents, 1999);                       // never 1998.9999 from parseFloat * 100
});
test("a typed charge is refused when empty, not a number, negative, with more than 2 decimals, or above the lesson's price", () => {
  for (const bad of ["", "   ", null, undefined]) assert.match(C.parseCharge(bad, 5000).error, /Enter the amount/, String(bad));
  for (const bad of ["abc", "12.345", "1e3", "--5", "5 6"]) assert.match(C.parseCharge(bad, 5000).error, /like 25 or 25\.50/, bad);
  assert.match(C.parseCharge("-5", 5000).error, /like 25|negative/);
  assert.match(C.parseCharge("S$-5", 5000).error, /like 25|negative/);
  const over = C.parseCharge("50.01", 5000);
  assert.strictEqual(over.ok, false); assert.match(over.error, /more than the lesson costs \(S\$50\.00\)/);
  assert.strictEqual(C.parseCharge("50", 5000).ok, true);                              // exactly the price is fine
  assert.strictEqual(C.parseCharge("1", 0).ok, false);                                 // a lesson with no price can only be charged 0
  assert.strictEqual(C.parseCharge("0", 0).ok, true);
});
test("a reason must be written and short", () => {
  assert.strictEqual(C.checkReason("  ").ok, false);
  assert.strictEqual(C.checkReason(null).ok, false);
  assert.deepStrictEqual(C.checkReason("  Parent sent a doctor's note "), { ok: true, reason: "Parent sent a doctor's note" });
  assert.strictEqual(C.checkReason("x".repeat(501)).ok, false);
  assert.strictEqual(C.checkReason("x".repeat(500)).ok, true);
});
test("the suggestion is worded for each case, and empty when the centre hasn't said", () => {
  assert.strictEqual(C.suggestion(R("a", 5000, { suggested_cents: 5000 })), "Suggested S$50.00");
  assert.strictEqual(C.suggestion(R("a", 5000, { suggested_cents: 0 })), "Suggested: not charged");
  assert.strictEqual(C.suggestion(R("a", 5000)), "");
  assert.match(C.ruleText("charged"), /charges absent/);
  assert.match(C.ruleText("not_charged"), /doesn’t charge/);
  assert.match(C.ruleText("charged_unless_notice"), /unless notice/);
  assert.strictEqual(C.ruleText("something_else"), "");
  assert.strictEqual(C.ruleText(null), "");
});
test("marks are named the way the Attendance page names them", () => {
  assert.strictEqual(C.markLabel("late_cancelled"), "Late cancelled");
  assert.strictEqual(C.markShort("cancelled_early"), "Cancelled");
  assert.strictEqual(C.markLabel("cancelled_early"), "Cancelled in time");
});
test("bulk: the count, the ids and the total follow what is ticked", () => {
  const rows = [R("a", 12345), R("b", 8000), R("c", 5000)];
  const none = C.bulk(rows, {}, "full"); assert.strictEqual(none.count, 0); assert.strictEqual(none.total, 0);
  const two = C.bulk(rows, { a: true, c: true, zzz: true }, "full");
  assert.deepStrictEqual(two.ids, ["a", "c"]); assert.strictEqual(two.total, 17345); assert.strictEqual(two.count, 2);   // ids not on the page are ignored
  assert.strictEqual(C.bulk(rows, { a: true, c: true }, "zero").total, 0);
  assert.strictEqual(C.bulk(rows, { a: false, b: true }, "full").total, 8000);
  const many = Array.from({ length: 101 }, (_, i) => R("r" + i, 100)), all = {}; many.forEach((r) => (all[r.lesson_id] = true));
  assert.strictEqual(C.bulk(many, all, "full").tooMany, true);
  assert.strictEqual(C.bulk(many.slice(0, 100), all, "full").tooMany, false);
});
test("bulk questions say how many and how much, in words a person can check", () => {
  const rows = [R("a", 12345), R("b", 8000)];
  const q = C.bulkQuestion(C.bulk(rows, { a: true, b: true }, "full"), "full");
  assert.match(q.message, /2 lessons \(S\$203\.45 in all\)/); assert.match(q.title, /full price/i);
  const z = C.bulkQuestion(C.bulk(rows, { a: true }, "zero"), "zero");
  assert.match(z.message, /1 lesson as not charged \(S\$0\)/); assert.match(z.message, /billed for it/);
});
test("a row says when: day label and time range", () => {
  assert.strictEqual(C.whenLine(R("a", 1), "2026-11-25"), "Yesterday · Tue 24 Nov · 3:00 pm – 4:00 pm");
});
test("every refusal of the database has plain words, never the raw code", () => {
  const codes = ["NOT_ALLOWED", "NOT_FOUND", "NOT_CANCELLED", "BAD_CHARGE", "ALREADY_SET", "ALREADY_PAID", "REASON_REQUIRED", "NO_CHANGE", "TOO_MANY", "TOO_LONG", "BAD_VALUE", "BAD_PAGE"];
  for (const c of codes) {
    const t = C.errorText({ message: c + ": whatever the database said" });
    assert.ok(t.length > 10 && !/[A-Z]{3,}_[A-Z]+/.test(t), c + " → " + t);
  }
  assert.match(C.errorText({ message: "TypeError: Failed to fetch" }), /connection/);
  assert.strictEqual(C.errorText(null), "Something went wrong.");
  assert.match(C.errorText({ message: "NOT_ALLOWED: your account can't set charges at this centre" }), /centre owner/);
});
test("a missing function (migration not on this database yet) and a permission refusal are told apart", () => {
  assert.strictEqual(C.isMissing({ code: "PGRST202", message: "Could not find the function" }), true);
  assert.strictEqual(C.isMissing({ code: "42883", message: "function does not exist" }), true);
  assert.strictEqual(C.isMissing({ message: "NOT_ALLOWED: x" }), false);
  assert.strictEqual(C.isNotAllowed({ message: "NOT_ALLOWED: x" }), true);
  assert.strictEqual(C.isNotAllowed({ message: "NOT_FOUND" }), false);
  assert.strictEqual(C.isNotAllowed(null), false);
});
test("the empty queue has its own words", () => { assert.match(C.emptyText().title, /Nothing waiting/); });
