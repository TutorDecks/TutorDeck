// node --test tests/billing-core.test.js
// Same numbers as the "maths parity" block in tests/sql/centres_test.sql, so the browser preview and
// the database can't drift apart.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const B = require("../assets/js/billing-core.js");

test("tutor pay bases match td_pay_amount", () => {
  assert.equal(B.payAmount("per_hour", 30, 90, 3, 0), 45);
  assert.equal(B.payAmount("per_lesson", 50, 90, 3, 0), 50);
  assert.equal(B.payAmount("per_student", 12, 90, 3, 0), 36);
  assert.equal(B.payAmount("per_student_hour", 8, 90, 3, 0), 36);
  assert.equal(B.payAmount("percent_of_fee", 45, 90, 3, 180), 81);
  assert.equal(B.payAmount("per_student", 12, 90, 1, 0, 25, null), 25);
  assert.equal(B.payAmount("per_student", 12, 90, 10, 0, null, 100), 100);
  assert.equal(B.payAmount("per_hour", 30, 120, 2, 0), 60);           // Tina's group lesson
  assert.equal(B.payAmount("percent_of_fee", 50, 90, 1, 55), 27.5);   // Tom's package lesson
  assert.equal(B.payAmount("per_hour", 30, 60, 0, 0, 25), 0);         // nobody billable → no pay, min ignored
});

test("GST matches td_gst", () => {
  assert.deepEqual(B.gst(100, 9, false, true), { net: 100, gst: 9, total: 109 });
  assert.deepEqual(B.gst(109, 9, true, true), { net: 100, gst: 9, total: 109 });
  assert.deepEqual(B.gst(100, 9, false, false), { net: 100, gst: 0, total: 100 });
  assert.deepEqual(B.gst(80, 9, false, true), { net: 80, gst: 7.2, total: 87.2 });
  assert.deepEqual(B.gst(72, 9, false, true), { net: 72, gst: 6.48, total: 78.48 });
  assert.deepEqual(B.gst(-165, 9, false, true), { net: -165, gst: -14.85, total: -179.85 });
  assert.equal(B.round2(1.005), 1.01);
});

test("sibling discount", () => {
  const cfg = { sibling_discount: { type: "percent", value: 10 } };
  assert.equal(B.siblingDiscount(80, 1, cfg), 0);
  assert.equal(B.siblingDiscount(80, 2, cfg), 8);
  assert.equal(B.siblingDiscount(20, 3, { sibling_discount: { type: "fixed", value: 25 } }), 20);
});

test("most specific pay rule wins", () => {
  const rules = [
    { id: "centre", basis: "per_hour", rate: 30, created_at: "1" },
    { id: "maths", subject: "maths", basis: "per_hour", rate: 35, created_at: "2" },
    { id: "tom", tutor_member_id: "t2", basis: "percent_of_fee", rate: 50, created_at: "3" }
  ];
  assert.equal(B.pickPayRule(rules, { tutor: "t1", subject: "Maths" }).id, "maths");
  assert.equal(B.pickPayRule(rules, { tutor: "t2", subject: "Maths" }).id, "tom");
  assert.equal(B.pickPayRule(rules, { tutor: "t1", subject: "English" }).id, "centre");
});

test("policy validation and summary", () => {
  assert.deepEqual(B.validatePolicy("postpay", { due_days: 7 }), []);
  assert.ok(B.validatePolicy("prepay", {}).some((m) => /package/.test(m)));
  assert.ok(B.validatePolicy("hybrid", {}).some((m) => /deposit/.test(m)));
  assert.equal(B.describePolicy("hybrid", { deposit: { amount: 100 }, due_days: 7 }), "$100 deposit, then billed monthly · due in 7 days");
  assert.equal(B.withDefaults({ cancellation: { late_charge_pct: 50 } }).cancellation.notice_hours, 24);
});

test("every permission the DB seeds exists in the catalogue", () => {
  const fs = require("node:fs");
  const sql = fs.readFileSync(require.resolve("../db/migration_centres.sql"), "utf8");
  const used = new Set();
  // permissions checked by td_require / td_has_perm, and the ones seeded into the default roles
  for (const m of sql.matchAll(/td_(?:require|has_perm)\([^,]+,\s*'{1,2}([a-z_]+\.[a-z_]+)'{1,2}\)/g)) used.add(m[1]);
  for (const arr of sql.matchAll(/array\[([^\]]*)\]/g)) for (const m of arr[1].matchAll(/'([a-z]+\.[a-z_]+)'/g)) used.add(m[1]);
  assert.ok(used.size >= 15, "found " + used.size + " permissions");
  const known = new Set(B.PERMISSIONS.map((p) => p.key));
  for (const k of used) assert.ok(known.has(k), "missing from PERMISSIONS: " + k);
});
