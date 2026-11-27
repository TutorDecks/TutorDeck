"use strict";
// T6 step 6: what a request says (tutor and staff screens). Pure text, no DOM; nothing here can say anything about money.
const test = require("node:test"), assert = require("node:assert");
const R = require("../assets/js/tutor-requests-core.js");

const base = { request_id: "r1", student_name: "Ann", tutor_name: "Tutor One", status: "pending", created_at: "2026-11-24T03:00:00+00:00", expires_at: "2026-12-08T03:00:00+00:00" };
const row = (o) => Object.assign({}, base, o);

test("ask: every kind says what is wanted, in plain words", () => {
  assert.strictEqual(R.ask(row({ kind: "postpone", new_date: "2026-12-04", new_start: "17:00:00" })), "Move to Fri 4 Dec 5:00 pm");
  assert.strictEqual(R.ask(row({ kind: "revert" })), "Put back to its usual time");
  assert.strictEqual(R.ask(row({ kind: "cancel" })), "Cancel the lesson (the family is not charged)");
  assert.strictEqual(R.ask(row({ kind: "add_lesson", new_date: "2026-12-05", new_start: "14:00:00", new_end: "15:30:00" })), "Add a lesson on Sat 5 Dec 2:00 pm – 3:30 pm");
  assert.strictEqual(R.ask(row({ kind: "save_slot", slot_id: null, weekday: "2", new_start: "16:00:00", new_end: "17:00:00" })), "Add a weekly slot on Wednesday 4:00 pm – 5:00 pm");
  assert.strictEqual(R.ask(row({ kind: "save_slot", slot_id: "s1", weekday: "0", new_start: "09:00:00", new_end: "10:00:00" })), "Change the weekly slot to Monday 9:00 am – 10:00 am");
  assert.strictEqual(R.ask(row({ kind: "stop_slot", slot_id: "s1" })), "Stop the weekly slot");
  assert.strictEqual(R.ask(row({ kind: "generate", from_date: "2026-11-27", to_date: "2026-12-24" })), "Create lessons from Fri 27 Nov to Thu 24 Dec");
  assert.strictEqual(R.ask(row({ kind: "link", link: "https://meet.example.com/x", link_scope: "student" })), "Set the online link for this student");
  assert.strictEqual(R.ask(row({ kind: "link", link: null, link_scope: "lesson" })), "Remove the online link for this lesson");
  assert.strictEqual(R.ask({ kind: "mystery" }), "A change");
});

test("headline: 'Move Ann' for the tutor, 'Tutor One asks to move Ann' for staff", () => {
  assert.strictEqual(R.headline(row({ kind: "postpone" }), false), "Move Ann");
  assert.strictEqual(R.headline(row({ kind: "postpone" }), true), "Tutor One asks to move Ann");
  assert.strictEqual(R.headline(row({ kind: "cancel" }), true), "Tutor One asks to cancel Ann");
  assert.strictEqual(R.headline(row({ kind: "add_lesson" }), true), "Tutor One asks to add a lesson for Ann");
  assert.strictEqual(R.headline(row({ kind: "save_slot", slot_id: null }), true), "Tutor One asks to add a weekly slot for Ann");
  assert.strictEqual(R.headline(row({ kind: "save_slot", slot_id: "s" }), false), "Change the weekly slot of Ann");
  assert.strictEqual(R.headline(row({ kind: "generate", student_name: null }), true), "Tutor One asks to create lessons");
  assert.strictEqual(R.headline({ kind: "postpone", student_name: "Ann" }, true), "A tutor asks to move Ann");
});

test("now: what the lesson or slot is today", () => {
  assert.strictEqual(R.now(row({ kind: "postpone", lesson_date: "2026-12-01", start_time: "16:00:00" })), "Now Tue 1 Dec 4:00 pm");
  assert.strictEqual(R.now(row({ kind: "link", link_scope: "lesson", lesson_date: "2026-12-01", start_time: "16:00:00" })), "Now Tue 1 Dec 4:00 pm");
  assert.strictEqual(R.now(row({ kind: "link", link_scope: "student" })), "");
  assert.strictEqual(R.now(row({ kind: "stop_slot", slot_id: "s", weekday: "1", slot_start: "16:00:00", slot_end: "17:00:00" })), "Now every Tuesday 4:00 pm – 5:00 pm");
  assert.strictEqual(R.now(row({ kind: "add_lesson" })), "");
});

test("status chips: the tutor's words, and the staff's", () => {
  for (const [st, text, tone] of [["pending", "Waiting for an admin", "warn"], ["approved", "Approved", "ok"], ["declined", "Declined", "muted"], ["cancelled", "You took it back", "muted"], ["expired", "Ran out", "muted"], ["no_longer_possible", "No longer possible", "muted"]])
    assert.deepStrictEqual(R.status({ status: st }, false), { text, tone }, st);
  assert.deepStrictEqual(R.status({ status: "pending" }, true), { text: "Waiting for you", tone: "warn" });
  assert.deepStrictEqual(R.status({ status: "cancelled" }, true), { text: "Taken back", tone: "muted" });
  assert.strictEqual(R.status({ status: "approved" }, true).text, "Approved");
  assert.strictEqual(R.status({}, false).text, "");
});

test("asked / expires: relative to the centre's own today", () => {
  assert.strictEqual(R.asked(row(), "2026-11-24"), "Asked today");
  assert.strictEqual(R.asked(row(), "2026-11-25"), "Asked yesterday");
  assert.strictEqual(R.asked(row(), "2026-11-28"), "Asked 4 days ago");
  assert.strictEqual(R.asked({}, "2026-11-28"), "Asked today");
  assert.strictEqual(R.expires(row(), "2026-11-24"), "Runs out in 14 days");
  assert.strictEqual(R.expires(row(), "2026-12-07"), "Runs out tomorrow");
  assert.strictEqual(R.expires(row(), "2026-12-08"), "Runs out today");
  assert.strictEqual(R.expires(row(), "2026-12-09"), "Runs out today");
  assert.strictEqual(R.expires({}, "2026-12-09"), "");
});

test("outcome: why a finished request ended the way it did", () => {
  assert.strictEqual(R.outcome(row({ status: "declined", decision_reason: "We need that lesson" })), "Declined: We need that lesson");
  assert.strictEqual(R.outcome(row({ status: "declined" })), "Declined");
  assert.strictEqual(R.outcome(row({ status: "no_longer_possible", decision_reason: "The lesson has been marked since the request was made" })), "Couldn't be done: the lesson has been marked since the request was made.");
  assert.match(R.outcome(row({ status: "expired" })), /Nobody answered in time, so nothing changed/);
  assert.match(R.outcome(row({ status: "cancelled" })), /took this request back/);
  assert.match(R.outcome(row({ status: "approved" })), /the change has been made/);
  assert.strictEqual(R.outcome(row({ status: "pending" })), "");
  assert.strictEqual(R.outcome(null), "");
});

test("staffOutcome: what staff read about an answered request", () => {
  assert.strictEqual(R.staffOutcome(row({ status: "approved", decided_by_name: "Staff Sam" })), "Approved by Staff Sam.");
  assert.strictEqual(R.staffOutcome(row({ status: "approved" })), "Approved.");
  assert.strictEqual(R.staffOutcome(row({ status: "declined", decided_by_name: "Staff Sam", decision_reason: "We need it" })), "Declined by Staff Sam: We need it.");
  assert.strictEqual(R.staffOutcome(row({ status: "no_longer_possible", decision_reason: "The lesson has been paid or put on an invoice since the request was made" })), "Couldn't be done: the lesson has been paid or put on an invoice since the request was made. Nothing was changed.");
  assert.match(R.staffOutcome(row({ status: "expired" })), /Ran out/); assert.match(R.staffOutcome(row({ status: "cancelled" })), /The tutor took this request back/);
  assert.strictEqual(R.staffOutcome(row({ status: "pending" })), ""); assert.strictEqual(R.staffOutcome(null), "");
});

test("waitingCount, sentText, homeNote", () => {
  assert.strictEqual(R.waitingCount([row(), row({ status: "approved" }), row()]), 2);
  assert.strictEqual(R.waitingCount(null), 0);
  assert.match(R.sentText(), /Nothing changes until an admin approves it/);
  assert.match(R.homeNote(2), /Approving makes the change/); assert.match(R.homeNote(0), /Nothing is waiting/);
});

test("decision words: staff errors are plain and never raw; approval results say what happened", () => {
  assert.match(R.decideErrorText({ message: "REASON_REQUIRED: say why" }), /say why/);
  assert.match(R.decideErrorText({ message: "ALREADY_DECIDED: this request has already been approved" }), /already answered/);
  assert.match(R.decideErrorText({ message: "NOT_ALLOWED: nope" }), /can't answer/);
  assert.match(R.decideErrorText({ message: "NOT_FOUND" }), /isn't available/);
  assert.match(R.decideErrorText({ message: "TOO_LONG: x" }), /300/);
  assert.match(R.decideErrorText({ message: "boom" }), /couldn't save that just now/);
  assert.strictEqual(R.approveResult({ status: "approved", already: false }), "Approved. The change has been made.");
  assert.strictEqual(R.approveResult({ status: "approved", already: true }), "Already approved.");
  assert.strictEqual(R.approveResult({ status: "no_longer_possible", reason: "The lesson has been marked since the request was made" }), "This can't be done any more: the lesson has been marked since the request was made. Nothing was changed.");
  assert.match(R.approveResult({ status: "expired" }), /had run out/); assert.match(R.approveResult({ status: "cancelled" }), /took this request back/); assert.match(R.approveResult({ status: "declined" }), /Already declined/);
});

test("linkCheck: https only, no spaces, 500 characters; empty clears (the database checks the same rules again)", () => {
  assert.deepStrictEqual(R.linkCheck("  https://meet.example.com/abc?x=1  "), { link: "https://meet.example.com/abc?x=1" });
  assert.deepStrictEqual(R.linkCheck(""), { link: "" }); assert.deepStrictEqual(R.linkCheck(null), { link: "" }); assert.deepStrictEqual(R.linkCheck("   "), { link: "" });
  for (const bad of ["http://meet.example.com/x", "javascript:alert(1)", "JAVASCRIPT:alert(1)", "data:text/html,x", "ftp://x.test/y", "//x.test/y", "meet.example.com/x", "https://a b", "https://", "https:// x.test", "https://" + "a".repeat(493)])
    assert.ok(R.linkCheck(bad).error, bad);
  assert.ok(!R.linkCheck("https://" + "a".repeat(492)).error, "500 characters is fine");
});

test("nothing a request says is about money", () => {
  const rows = ["postpone", "revert", "cancel", "add_lesson", "save_slot", "stop_slot", "generate", "link"].map((k) => row({ kind: k, new_date: "2026-12-04", new_start: "17:00:00", new_end: "18:00:00", weekday: "1", slot_id: "s", slot_start: "16:00:00", lesson_date: "2026-12-01", start_time: "16:00:00", from_date: "2026-11-27", to_date: "2026-12-24", link: "https://x.test/y", link_scope: "lesson" }));
  const all = JSON.stringify(rows.map((r) => [R.ask(r), R.headline(r, true), R.headline(r, false), R.now(r), R.status(r, true), R.outcome(Object.assign({}, r, { status: "declined", decision_reason: "No" }))]));
  assert.ok(!/\b(rate|price|amount|paid|compensation|charge|fee|cents)\b/i.test(all), "no money word");
});
