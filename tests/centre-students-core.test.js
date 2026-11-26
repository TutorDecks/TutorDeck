"use strict";
const test = require("node:test"), assert = require("node:assert");
const C = require("../assets/js/centre-students-core.js");

const G = (o) => Object.assign({ name: "Mrs Test", relation: "Mother", phone: "+65 9123 4567", email: "" }, o || {});
const F = (o) => Object.assign({ name: "Test Child", level: "Sec 2", notes: "", householdName: "", guardians: [G()], family: null }, o || {});

test("a guardian needs a name and a phone or an email (the database's rule, caught early)", () => {
  assert.strictEqual(C.checkGuardian(G()).ok, true);
  assert.strictEqual(C.checkGuardian(G({ phone: "", email: "m@x.com" })).ok, true);
  assert.strictEqual(C.checkGuardian(G({ name: "  " })).ok, false);
  assert.match(C.checkGuardian(G({ phone: "", email: "" })).error, /phone number or an email/);
  assert.strictEqual(C.checkGuardian(G({ phone: "abc" })).ok, false);
  assert.strictEqual(C.checkGuardian(G({ phone: "123" })).ok, false);                         // too few digits
  assert.strictEqual(C.checkGuardian(G({ phone: "1".repeat(16) })).ok, false);                // too many
  assert.strictEqual(C.checkGuardian(G({ phone: "(65) 9123-4567" })).ok, true);
  assert.strictEqual(C.checkGuardian(G({ phone: "", email: "not-an-email" })).ok, false);
  assert.strictEqual(C.checkGuardian(G({ name: "n".repeat(121) })).ok, false);
});
test("a guardian is tidied: trimmed, email lower-cased, empty fields become null, an existing id is kept", () => {
  const v = C.checkGuardian({ id: "g1", name: "  Mr Tan ", relation: "", phone: " 8111 2222 ", email: " TAN@Example.COM " }).value;
  assert.deepStrictEqual(v, { id: "g1", name: "Mr Tan", relation: null, phone: "8111 2222", email: "tan@example.com" });
  assert.strictEqual("id" in C.checkGuardian(G()).value, false);
});
test("adding a student: the payload names every argument of staff_save_student", () => {
  const r = C.check(F({ householdName: "The Test family", notes: " likes maths " }), "add");
  assert.strictEqual(r.ok, true);
  assert.deepStrictEqual(Object.keys(r.payload).sort(), ["p_guardians", "p_household", "p_household_name", "p_level", "p_name", "p_notes"]);
  assert.strictEqual(r.payload.p_name, "Test Child"); assert.strictEqual(r.payload.p_notes, "likes maths"); assert.strictEqual(r.payload.p_household, null);
  assert.strictEqual(r.payload.p_household_name, "The Test family"); assert.strictEqual(r.payload.p_guardians.length, 1);
  assert.strictEqual(C.check(F({ level: "  ", householdName: "" }), "add").payload.p_level, null);
});
test("a student needs a name; a new family needs at least one contact; at most six", () => {
  assert.strictEqual(C.check(F({ name: "  " }), "add").ok, false);
  assert.match(C.check(F({ name: "" }), "add").errors.name, /name/);
  assert.strictEqual(C.check(F({ name: "n".repeat(121) }), "add").ok, false);
  const none = C.check(F({ guardians: [] }), "add");
  assert.strictEqual(none.ok, false); assert.match(none.errors.form, /parent or guardian/);
  assert.strictEqual(C.check(F({ guardians: Array.from({ length: 7 }, () => G()) }), "add").ok, false);
  assert.strictEqual(C.check(F({ guardians: Array.from({ length: 6 }, () => G()) }), "add").ok, true);
  assert.strictEqual(C.check(F({ level: "l".repeat(41) }), "add").ok, false);
  assert.strictEqual(C.check(F({ notes: "n".repeat(1001) }), "add").ok, false);
});
test("a bad contact is reported against ITS row and blocks the save", () => {
  const r = C.check(F({ guardians: [G(), G({ phone: "", email: "" })] }), "add");
  assert.strictEqual(r.ok, false); assert.strictEqual(r.errors.guardians[0], null); assert.match(r.errors.guardians[1], /phone number or an email/); assert.strictEqual(r.payload, null);
});
test("adding a brother or sister: the family is sent and its contacts are left alone (guardians = null)", () => {
  const r = C.check(F({ family: "h1", guardians: [] }), "add");
  assert.strictEqual(r.ok, true); assert.strictEqual(r.payload.p_household, "h1"); assert.strictEqual(r.payload.p_guardians, null);
});
test("editing: no family is sent (a student never moves family), the full contact list is, with ids", () => {
  const r = C.check(F({ family: "h1", guardians: [G({ id: "g1" }), G({ name: "Mr Test", phone: "9000 2222" })] }), "edit");
  assert.strictEqual(r.ok, true); assert.strictEqual(r.payload.p_household, null);
  assert.strictEqual(r.payload.p_guardians[0].id, "g1"); assert.strictEqual("id" in r.payload.p_guardians[1], false);
  assert.strictEqual(C.check(F({ guardians: [] }), "edit").ok, false);                         // an edit can't leave a family with nobody to contact
});
test("the database's refusals read as plain words", () => {
  assert.match(C.errorText({ message: "NOT_ALLOWED: your account can't manage students at this centre" }), /can.t manage students/);
  assert.match(C.errorText({ message: "NOT_FOUND" }), /isn.t available/);
  assert.strictEqual(C.errorText({ message: "BAD_GUARDIAN: that email address doesn't look right (x)" }), "That email address doesn't look right (x).");
  assert.strictEqual(C.errorText({ message: "DUPLICATE: Test Child is already in this family" }), "Test Child is already in this family.");
  assert.match(C.errorText({ message: "TypeError: Failed to fetch" }), /Couldn.t reach the server/);
  assert.strictEqual(C.errorText(null), "Something went wrong.");
});
test("a database without the migration is recognised", () => {
  assert.strictEqual(C.isMissing({ code: "PGRST202", message: "Could not find the function public.staff_students" }), true);
  assert.strictEqual(C.isMissing({ code: "42883", message: "function staff_students does not exist" }), true);
  assert.strictEqual(C.isMissing({ message: "NOT_FOUND" }), false); assert.strictEqual(C.isMissing(null), false);
});
test("initials, links, paging and empty states", () => {
  assert.strictEqual(C.initials("Mei Ling Koh"), "MK"); assert.strictEqual(C.initials("  aiden "), "A"); assert.strictEqual(C.initials(""), "?");
  assert.strictEqual(C.telHref("+65 9123 4567"), "tel:+6591234567"); assert.strictEqual(C.telHref("9123-4567"), "tel:91234567"); assert.strictEqual(C.telHref("n/a"), "");
  assert.strictEqual(C.mailHref("a@b.co"), "mailto:a@b.co"); assert.strictEqual(C.mailHref("javascript:alert(1)"), "");
  assert.strictEqual(C.pageCount(62, 25), 3); assert.strictEqual(C.pageCount(0, 25), 1); assert.strictEqual(C.pageCount(25, 25), 1); assert.strictEqual(C.pageCount(26, 25), 2);
  assert.strictEqual(C.pagerLabel(3, 25, 62), "51–62 of 62"); assert.strictEqual(C.pagerLabel(1, 25, 62), "1–25 of 62"); assert.strictEqual(C.pagerLabel(1, 25, 0), "No students");
  assert.match(C.emptyText("active", true).title, /No students match/); assert.match(C.emptyText("ended", false).title, /discontinued/);
  assert.deepStrictEqual(C.FILTERS.map((f) => f.key), ["active", "ended", "trial", "all"]);
});
test("'lessons run until' in words", () => {
  const d = (iso) => iso;
  assert.strictEqual(C.endNote({ end_date: null }, "2026-11-25", d), "");
  assert.strictEqual(C.endNote({ end_date: "2026-12-01", ended: false }, "2026-11-25", d), "Lessons run until 2026-12-01");
  assert.strictEqual(C.endNote({ end_date: "2026-11-01", ended: true }, "2026-11-25", d), "Lessons ended 2026-11-01");
});
