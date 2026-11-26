// node --test tests/   — the People tab's wording and grouping (T3.9). The database's side is tests/sql/slot_changes_test.sql.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const P = require("../assets/js/centre-people-core.js");
const NOW = Date.parse("2026-11-26T12:00:00Z"), HOURS = (h) => new Date(NOW - h * 3600e3).toISOString();
const rows = [
  { id: "1", name: "Olivia Owner", role: "owner", status: "active", invited: false, you: true },
  { id: "2", name: "Sam Staff", role: "staff", status: "active", invited: false },
  { id: "3", name: "Tina Tutor", role: "tutor", status: "active", invited: false },
  { id: "4", name: "Wen Waiting", role: "tutor", status: "invited", invited: true, invited_at: HOURS(50), last_emailed_at: HOURS(2) },
  { id: "5", name: "Oscar Off", role: "tutor", status: "disabled", invited: false }
];

test("roles and statuses use plain words", () => {
  assert.equal(P.roleLabel("owner"), "Owner");
  assert.equal(P.roleLabel("staff"), "Staff admin");
  assert.equal(P.roleLabel("tutor"), "Tutor");
  assert.equal(P.roleLabel("parent"), "Member");
  assert.deepEqual(P.statusOf(rows[0]), { key: "active", label: "Active" });
  assert.deepEqual(P.statusOf(rows[3]), { key: "invited", label: "Invited" });
  assert.deepEqual(P.statusOf(rows[4]), { key: "off", label: "Off" });
});

test("people are grouped Owner, Staff, Tutors and empty groups are left out", () => {
  assert.deepEqual(P.group(rows).map((g) => g.title + ":" + g.rows.length), ["Owner:1", "Staff:1", "Tutors:3"]);
  assert.deepEqual(P.group(rows.filter((r) => r.role === "tutor")).map((g) => g.title), ["Tutors"], "staff with Manage tutors only get tutors");
  assert.deepEqual(P.group([]), []);
  assert.deepEqual(P.group(null), []);
});

test("an invite says when it was made and when it was last emailed, reusing the Users screen's rules", () => {
  assert.equal(P.inviteLine(rows[3], NOW), "Invited 2 days ago · Emailed today");
  assert.equal(P.inviteLine(rows[0], NOW), "", "nothing for someone who has signed in");
  assert.equal(P.inviteLine({ invited: true, invited_at: HOURS(1), last_emailed_at: null }, NOW), "Invited today · No email sent yet");
  assert.equal(P.inviteLine({ invited: true, invited_at: HOURS(100), last_emailed_at: HOURS(30) }, NOW), "Invited 4 days ago · Link expired, send a new one");
});

test("the summary counts people, invites and people switched off", () => {
  assert.equal(P.summary(rows), "5 people · 1 invited · 1 off");
  assert.equal(P.summary(rows.slice(0, 1)), "1 person");
  assert.equal(P.summary([]), "0 people");
});

test("errors are plain words; a missing function is recognised", () => {
  assert.match(P.errorText({ message: "NOT_ALLOWED: your account can't see the people at this centre" }), /Manage tutors/);
  assert.match(P.errorText({ message: "NOT_FOUND" }), /isn’t available/);
  assert.equal(P.errorText({ message: "boom" }), "boom");
  assert.ok(P.isMissing({ code: "PGRST202", message: "Could not find the function public.staff_people" }));
  assert.ok(!P.isMissing({ message: "NOT_ALLOWED" }));
});

test("the logic never reads pay, bank or contact fields of a person", () => {
  const src = require("node:fs").readFileSync(require.resolve("../assets/js/centre-people-core.js"), "utf8").replace(/^\s*\/\/.*$/gm, "");
  assert.ok(!/\.(email|invited_email|phone|payout\w*|bank\w*|paynow\w*|rate|amount|compensation|salary)\b/i.test(src), "only id, name, role, status, invite times");
});
