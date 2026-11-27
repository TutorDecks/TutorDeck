// T18 step 4: the make-up credits page logic (assets/js/centre-credits-core.js). Run: node --test tests/*.test.js
const test = require("node:test");
const assert = require("node:assert/strict");
const C = require("../assets/js/centre-credits-core.js");
const TODAY = "2026-11-27";
const open = { credit_id: "c1", status: "open", source: "absence", earned_on: "2026-11-20", expires_on: null, days_left: null, expired_by_date: false,
  student_name: "Kid One", missed: { lesson_id: "l1", date: "2026-11-21", start_time: "10:00:00", attendance: "cancelled_early", tutor_name: "Tutor One" }, makeup: null };

test("wording of a row: the missed lesson, the make-up, the source and the state", () => {
  assert.match(C.missedLine(open, TODAY), /^Missed Sat 21 Nov, 10:00 am · Tutor One \(/);
  assert.equal(C.missedLine({ source: "manual", reason: "Goodwill", missed: null }, TODAY), "Goodwill");
  assert.equal(C.missedLine({ source: "holiday", missed: null }, TODAY), "Holiday", "no lesson and no reason: the source");
  assert.equal(C.makeupLine({ makeup: { date: "2026-11-30", start_time: "17:00:00", end_time: "18:00:00", tutor_name: "Tutor Two" } }, TODAY), "Make-up Mon 30 Nov, 5:00 pm – 6:00 pm · Tutor Two");
  assert.equal(C.makeupLine({ makeup: null }, TODAY), "");
  assert.deepEqual(["absence", "tutor_cancel", "holiday", "manual"].map(C.sourceLabel), ["Missed lesson", "Cancelled by tutor", "Holiday", "Given by hand"]);
  assert.deepEqual(["open", "booked", "used", "expired", "revoked"].map(C.statusLabel), ["Owed", "Booked", "Used", "Expired", "Taken back"]);
});

test("expiry wording, including the last day and the day after", () => {
  assert.equal(C.expiryText(open, TODAY), "Never expires");
  assert.equal(C.expiryText({ status: "open", expires_on: "2026-12-27" }, TODAY), "Use by Sun 27 Dec (30 days left)");
  assert.equal(C.expiryText({ status: "open", expires_on: "2026-11-28" }, TODAY), "Use by Tomorrow (1 day left)");
  assert.equal(C.expiryText({ status: "open", expires_on: TODAY }, TODAY), "Last day today", "usable ON its last day");
  assert.equal(C.expiryText({ status: "open", expires_on: "2026-11-26" }, TODAY), "Ended Yesterday", "the day after the last day it has ended");
  assert.equal(C.expiryText({ status: "booked", expires_on: "2026-11-20" }, TODAY), "", "a booked credit never expires, so no warning");
  assert.equal(C.expiryText({ status: "used", expires_on: "2026-12-30" }, TODAY), "");
});

test("the pill on a row", () => {
  assert.deepEqual(C.rowChip(open, TODAY), { text: "Owed", kind: "ok" });
  assert.deepEqual(C.rowChip({ status: "open", expires_on: "2026-11-30", days_left: 3 }, TODAY), { text: "Ends soon", kind: "warn" });
  assert.deepEqual(C.rowChip({ status: "open", expires_on: "2026-12-30", days_left: 33 }, TODAY), { text: "Owed", kind: "ok" });
  assert.deepEqual(C.rowChip({ status: "open", expired_by_date: true, expires_on: "2026-11-26", days_left: -1 }, TODAY), { text: "Ended", kind: "warn" });
  assert.deepEqual(C.rowChip({ status: "booked" }, TODAY), { text: "Booked", kind: "ok" });
  assert.deepEqual(C.rowChip({ status: "used" }, TODAY), { text: "Used", kind: "muted" });
  assert.deepEqual(C.rowChip({ status: "revoked" }, TODAY), { text: "Taken back", kind: "muted" });
});

test("billing wording has no amount in it, ever", () => {
  assert.equal(C.billingText("free"), "Not billed");
  assert.equal(C.billingText("normal"), "Billed at the normal price");
  assert.equal(C.billingText(null), "");
  for (const m of ["free", "if_missed_not_charged"]) assert.doesNotMatch(C.priceRule(m), /S\$|\d/, m);
  assert.match(C.priceRule("if_missed_not_charged"), /never pays twice/);
  assert.match(C.priceRule("free"), /not billed/);
});

test("the badge, the chip on the student sheet and when the tab shows", () => {
  assert.equal(C.badgeCount({ counts: { open: 3 } }), 3);
  assert.equal(C.badgeCount(null), 0);
  assert.equal(C.chipText({ open: 1, booked: 0 }), "1 make-up credit owed");
  assert.equal(C.chipText({ open: 2, booked: 1 }), "2 make-up credits owed · 1 booked");
  assert.equal(C.chipText({ open: 0, booked: 1 }), "1 booked");
  assert.equal(C.chipText({ open: 0, booked: 0, used: 4 }), "", "nothing owed or booked: no chip (used credits are history)");
  assert.equal(C.chipText(null), "");
  const z = { open: 0, booked: 0, used: 0, expired: 0, revoked: 0 };
  assert.equal(C.showTab({ enabled: true, counts: z }), true, "switched on: the tab shows even when empty");
  assert.equal(C.showTab({ enabled: false, counts: z }), false, "never switched on, nothing ever earned: no tab");
  assert.equal(C.showTab({ enabled: false, counts: Object.assign({}, z, { used: 1 }) }), true, "switched off later but there is history: the tab stays");
  assert.equal(C.showTab(null), false);
});

test("the booking form: defaults and every refusal before anything is sent", () => {
  assert.deepEqual(C.bookingDefaults(open), { start: "10:00", end: "11:00" });
  assert.deepEqual(C.bookingDefaults({ missed: null }), { start: "16:00", end: "17:00" });
  assert.equal(C.addMinutes("23:30", 60), "23:59", "never wraps past midnight");
  const ok = (f, r) => C.checkBooking(f, TODAY, r || open);
  assert.deepEqual(ok({ date: "2026-11-30", start: "17:00", end: "18:00", tutor: "m1" }), { ok: true, value: { date: "2026-11-30", start: "17:00", end: "18:00", tutor: "m1" } });
  assert.equal(ok({ date: TODAY, start: "17:00", end: "18:00" }).ok, true, "today is allowed");
  assert.equal(ok({ date: "2026-11-26", start: "17:00", end: "18:00" }).ok, false, "yesterday");
  assert.equal(ok({ date: "2027-11-27", start: "17:00", end: "18:00" }).ok, true, "exactly a year ahead");
  assert.equal(ok({ date: "2027-11-28", start: "17:00", end: "18:00" }).ok, false, "a year and a day");
  assert.equal(ok({ date: "", start: "17:00", end: "18:00" }).ok, false);
  assert.equal(ok({ date: "2026-13-45", start: "17:00", end: "18:00" }).ok, false, "not a real day");
  assert.equal(ok({ date: "2026-11-30", start: "", end: "18:00" }).ok, false);
  assert.equal(ok({ date: "2026-11-30", start: "17:00", end: "25:00" }).ok, false);
  assert.equal(ok({ date: "2026-11-30", start: "18:00", end: "17:00" }).ok, false, "ends before it starts");
  assert.equal(ok({ date: "2026-11-30", start: "17:00", end: "17:00" }).ok, false, "zero length");
  const ends = Object.assign({}, open, { expires_on: "2026-12-05" });
  assert.equal(ok({ date: "2026-12-05", start: "17:00", end: "18:00" }, ends).ok, true, "ON the credit's last day");
  const late = ok({ date: "2026-12-06", start: "17:00", end: "18:00" }, ends);
  assert.equal(late.ok, false); assert.match(late.error, /up to Sat 5 Dec/, "the day after is refused, and says the last day");
});

test("a reason is required, 3 to 300 letters", () => {
  assert.equal(C.checkReason("").ok, false); assert.equal(C.checkReason("   ").ok, false); assert.equal(C.checkReason(null).ok, false);
  assert.equal(C.checkReason("ab").ok, false);
  assert.deepEqual(C.checkReason("  abc  "), { ok: true, value: "abc" });
  assert.equal(C.checkReason("x".repeat(300)).ok, true); assert.equal(C.checkReason("x".repeat(301)).ok, false);
});

test("the database's refusals in plain words (never a raw code)", () => {
  const e = (m) => C.errorText({ message: m });
  assert.match(e("NOT_ALLOWED: at this centre only the owner can do this"), /only the owner/);
  assert.match(e("NOT_ALLOWED: your account can't change"), /Ask the centre owner/);
  assert.match(e("NOT_ENABLED: make-up credits are switched off"), /switched off/);
  assert.match(e("IN_USE: a make-up lesson is already booked"), /Remove the make-up first/);
  assert.match(e("TOO_LATE: this credit can only be used up to 25 Dec"), /last day/);
  assert.match(e("EXPIRED: this credit ended on 01 Dec 2026"), /has ended/);
  assert.match(e("CHARGE_PENDING: type the charge"), /Attendance, Charges/);
  assert.match(e("DUPLICATE: this student already has a lesson at that time"), /already has a lesson/);
  assert.match(e("DUPLICATE: this credit was just given"), /just given/);
  assert.match(e("NO_TEMPLATE: add one lesson"), /Add one lesson first/);
  assert.match(e("LOCKED: this make-up can't be removed (paid)"), /paid or on an invoice/);
  assert.match(e("Failed to fetch"), /connection/);
  assert.equal(e(""), "Something went wrong.");
  for (const code of ["NOT_FOUND", "REASON_REQUIRED", "BAD_REASON", "ALREADY_HAS_CREDIT", "IS_MAKEUP", "NO_CHANGE", "ALREADY_BOOKED", "NOT_OPEN", "BAD_DATE", "BAD_TIME", "ENDED", "NOT_AVAILABLE", "BAD_FILTER"]) {
    assert.doesNotMatch(e(code + ": x"), new RegExp("^" + code), code + " is worded, not shown raw");
  }
});

test("which errors mean someone else got there first (the list refreshes)", () => {
  for (const m of ["NOT_FOUND", "NO_CHANGE: x", "NOT_OPEN: x", "ALREADY_BOOKED: x", "IN_USE: x", "DUPLICATE: this credit was just given"]) assert.equal(C.isStale({ message: m }), true, m);
  for (const m of ["TOO_LATE: x", "BAD_TIME: x", "DUPLICATE: this student already has a lesson"]) assert.equal(C.isStale({ message: m }), false, m);
  assert.equal(C.isNotAllowed({ message: "NOT_ALLOWED: x" }), true); assert.equal(C.isNotAllowed(null), false);
  assert.equal(C.isMissing({ code: "PGRST202" }), true, "an older database without the migration: the tab stays hidden");
});

test("the filters and empty states", () => {
  assert.deepEqual(C.FILTERS.map((f) => f.key), ["open", "booked", "used", "all"]);
  assert.ok(C.isFilter("open") && !C.isFilter("expired"));
  for (const f of ["open", "booked", "used", "all"]) { const t = C.emptyText(f, true); assert.ok(t.title && t.hint, f); }
  assert.match(C.emptyText("open", false).title, /switched off/);
});
