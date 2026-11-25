"use strict";
// What the people list says about a waiting invite (assets/js/invite-status.js). Run: node --test tests/*.test.js
const test = require("node:test"), assert = require("node:assert");
const IS = require("../assets/js/invite-status.js");
const NOW = Date.parse("2026-11-25T12:00:00Z"), H = 3600e3, D = 24 * H;
const iso = (ago) => new Date(NOW - ago).toISOString();

test("'Invited today / yesterday / N days ago' from when the invite was made", () => {
  assert.strictEqual(IS.describe({ created_at: iso(2 * H) }, null, NOW).invited, "Invited today");
  assert.strictEqual(IS.describe({ created_at: iso(30 * H) }, null, NOW).invited, "Invited yesterday");
  assert.strictEqual(IS.describe({ created_at: iso(3 * D + H) }, null, NOW).invited, "Invited 3 days ago");
  assert.strictEqual(IS.describe({}, null, NOW).invited, "Invited");
});
test("emailed less than 24 hours ago: valid link, no warning", () => {
  const o = IS.describe({ created_at: iso(5 * D) }, { last_sent_at: iso(3 * H), sent_24h: 1, can_resend_at: iso(3 * H - 600e3) }, NOW);
  assert.deepStrictEqual([o.expired, o.neverSent, o.hint, o.canPress, o.buttonLabel], [false, false, "Emailed today", true, "Resend invite"]);
});
test("emailed more than 24 hours ago: 'expired' hint", () => {
  const o = IS.describe({ created_at: iso(5 * D) }, { last_sent_at: iso(25 * H), sent_24h: 0 }, NOW);
  assert.strictEqual(o.expired, true); assert.strictEqual(o.hint, "Link expired, send a new one"); assert.strictEqual(o.canPress, true);
  assert.strictEqual(IS.describe({}, { last_sent_at: iso(24 * H - 1000) }, NOW).expired, false, "exactly inside 24 hours is still valid");
});
test("never emailed: says so and offers to send", () => {
  const o = IS.describe({ created_at: iso(H) }, { last_sent_at: null, sent_24h: 0 }, NOW);
  assert.deepStrictEqual([o.neverSent, o.hint, o.buttonLabel, o.expired], [true, "No email sent yet", "Send invite email", false]);
  assert.strictEqual(IS.describe({ created_at: iso(H) }, null, NOW).neverSent, true);
});
test("the button waits 10 minutes after a send and stops at 5 emails a day (the server enforces both again)", () => {
  const wait = IS.describe({}, { last_sent_at: iso(3 * 60e3), can_resend_at: new Date(NOW + 7 * 60e3).toISOString(), sent_24h: 1 }, NOW);
  assert.deepStrictEqual([wait.waitMinutes, wait.canPress], [7, false]);
  assert.strictEqual(IS.describe({}, { last_sent_at: iso(H), sent_24h: 5 }, NOW).canPress, false);
  assert.strictEqual(IS.describe({}, { last_sent_at: iso(H), sent_24h: 5 }, NOW).dailyLimit, true);
  assert.strictEqual(IS.describe({}, { last_sent_at: iso(H), sent_24h: 4 }, NOW).canPress, true);
  assert.strictEqual(IS.describe({}, { can_resend_at: new Date(NOW + 1000).toISOString() }, NOW).waitMinutes, 1);
});
