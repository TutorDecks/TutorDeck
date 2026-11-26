// Unit tests for the centre Money > Invoice run page logic (T4 S2). No DOM, no network.  node --test tests/centre-money-core.test.js
const test = require("node:test");
const assert = require("node:assert");
const CM = require("../assets/js/centre-money-core.js");

test("months: label, shift across a year, default month", () => {
  assert.strictEqual(CM.monthLabel("2026-11-01"), "November 2026");
  assert.strictEqual(CM.shiftMonth("2026-12-01", 1), "2027-01-01");
  assert.strictEqual(CM.shiftMonth("2026-01-01", -1), "2025-12-01");
  assert.strictEqual(CM.shiftMonth("2026-03-01", -14), "2025-01-01");
  assert.strictEqual(CM.defaultMonth("2026-11-26", "postpaid_lessons"), "2026-10-01");     // the month that just ended
  assert.strictEqual(CM.defaultMonth("2026-01-05", "postpaid_lessons"), "2025-12-01");
  assert.strictEqual(CM.defaultMonth("2026-11-26", "fixed_in_advance"), "2026-12-01");     // the coming month
  assert.strictEqual(CM.defaultMonth("2026-12-31", "fixed_in_advance"), "2027-01-01");
});
test("query: only a real month is accepted", () => {
  assert.strictEqual(CM.fromQuery("?id=c1&month=2026-09").month, "2026-09-01");
  assert.strictEqual(CM.fromQuery("?month=2026-13").month, null);
  assert.strictEqual(CM.fromQuery("?month=junk").month, null);
  assert.strictEqual(CM.fromQuery("").month, null);
  assert.strictEqual(CM.toQuery("c 1", "2026-09-01"), "id=c%201&month=2026-09");
});
const P = (over) => Object.assign({ built: true, model: "postpaid_lessons", grouping: "family", review_before_sending: true, totals: { ready: 3, held_back: 1, drafts: 0, total_cents: 27250, gst_cents: 2250 } }, over);
test("the summary names what is ready and held back, in whole cents", () => {
  assert.strictEqual(CM.summaryText(P()), "3 invoices ready · 1 held back");
  assert.strictEqual(CM.summaryText(P({ totals: { ready: 1, held_back: 0, drafts: 2 } })), "1 invoice ready · 2 drafts waiting for approval");
  assert.strictEqual(CM.summaryText({ built: false }), "");
  assert.strictEqual(CM.totalText(P()), "S$272.50 including S$22.50 GST");
  assert.strictEqual(CM.totalText(P({ totals: { ready: 1, total_cents: 5000, gst_cents: 0 } })), "S$50.00");
  assert.strictEqual(CM.totalText(P({ totals: { ready: 0 } })), "");
});
test("one primary next step: create what is ready, else approve what waits, else nothing", () => {
  const draft = { status: "draft" }, issued = { status: "issued" };
  assert.deepStrictEqual(CM.nextStep(P(), []), { kind: "create", count: 3, label: "Create 3 drafts" });
  assert.strictEqual(CM.nextStep(P({ totals: { ready: 1 } }), []).label, "Create 1 draft");
  assert.strictEqual(CM.nextStep(P({ review_before_sending: false }), []).label, "Create and issue 3 invoices");
  assert.strictEqual(CM.nextStep(P({ totals: { ready: 0 } }), [draft, draft]).label, "Approve all 2 drafts");
  assert.strictEqual(CM.nextStep(P({ totals: { ready: 0 } }), [draft]).label, "Approve the draft");
  assert.strictEqual(CM.nextStep(P({ totals: { ready: 0 } }), [issued]).kind, null);
  assert.strictEqual(CM.nextStep({ built: false }, [draft]).kind, null);
  assert.strictEqual(CM.secondStep(P(), [draft]).kind, "approve");
  assert.strictEqual(CM.secondStep(P({ totals: { ready: 0 } }), [draft]).kind, null);           // already the primary one
});
test("what happened, in plain words", () => {
  assert.strictEqual(CM.createdText({ created: 3, held_back: 1, already_drafted: 0 }), "3 drafts created. 1 held back until its charge is set.");
  assert.strictEqual(CM.createdText({ created: 1, issued: 1, held_back: 0, already_drafted: 2 }), "1 draft created and issued. 2 already have drafts.");
  assert.strictEqual(CM.createdText({ created: 0, held_back: 2, already_drafted: 1 }), "Nothing new to create. 1 already has a draft. 2 held back until their charges are set.");
  assert.strictEqual(CM.approvedText({ issued: 3, first_number: "INV-1", last_number: "INV-3" }), "3 invoices issued (INV-1 to INV-3).");
  assert.strictEqual(CM.approvedText({ issued: 1, first_number: "INV-9", last_number: "INV-9" }), "1 invoice issued (INV-9).");
  assert.strictEqual(CM.approvedText({ number: "INV-4" }), "Invoice INV-4 issued.");
  assert.match(CM.approveQuestion(2, 10900).message, /S\$109\.00/);
});
test("invoice lines are grouped per child and shown in whole cents", () => {
  const g = CM.groupLines([{ student_name: "A", description: "x", qty: 1, unit_cents: 5000 }, { student_name: "B", description: "y", qty: 1, unit_cents: 5000 }, { student_name: "A", description: "z", qty: 2, unit_cents: 500 }]);
  assert.deepStrictEqual(g.map((x) => [x.student, x.lines.length]), [["A", 2], ["B", 1]]);
  assert.strictEqual(CM.qtyText({ qty: 2, unit_cents: 500 }), "2 × S$5.00");
  assert.strictEqual(CM.qtyText({ qty: 1, unit_cents: 500 }), "");
  assert.strictEqual(CM.lineAmount({ qty: 3, unit_cents: -500 }), -1500);
  assert.strictEqual(CM.lineAmount({ line_cents: 7, qty: 1, unit_cents: 7 }), 7);
});
test("invoice rows: status chip, sub line, held note", () => {
  assert.deepStrictEqual(CM.chip({ status: "draft" }), { text: "Draft", tone: "muted" });
  assert.deepStrictEqual(CM.chip({ status: "issued" }), { text: "Issued", tone: "ok" });
  assert.strictEqual(CM.invoiceSub({ status: "issued", issue_date: "2026-11-26", due_date: "2026-12-03" }), "Issued 26 Nov 2026 · due 3 Dec 2026");
  assert.strictEqual(CM.invoiceSub({ status: "draft", lines: 1 }), "1 line");
  assert.strictEqual(CM.heldNote({ reasons: [{ lessons: 2 }, { lessons: 1 }] }), "3 charges to set in Charges");
  assert.strictEqual(CM.notMarkedNote(1), "1 lesson isn’t marked yet and is left off");
  assert.strictEqual(CM.notMarkedNote(0), "");
});
test("numbering: opening number is a whole number from 1", () => {
  assert.strictEqual(CM.parseOpening("1000"), 1000);
  for (const bad of ["0", "-5", "1.5", "abc", "", "1234567890", null]) assert.strictEqual(CM.parseOpening(bad), null, String(bad));
  assert.strictEqual(CM.numberingText({ locked: false, next_text: "INV-1" }), "First invoice number will be INV-1");
  assert.strictEqual(CM.numberingText({ locked: true, next_text: "INV-5" }), "Next invoice number: INV-5");
});
test("refusals are words, never codes", () => {
  assert.match(CM.errorText({ message: "NOT_ALLOWED: your account can't prepare or issue invoices at this centre" }), /can’t prepare or issue invoices/);
  assert.match(CM.errorText({ message: "NOT_ALLOWED: numbers have already been issued, so the opening number can't be changed" }), /already been issued/);
  assert.strictEqual(CM.errorText({ message: "NOT_BUILT: Prepaid packages are coming soon." }), "Prepaid packages are coming soon.");
  assert.match(CM.errorText({ message: "NOT_DRAFT: only a draft can be approved" }), /already approved/);
  assert.match(CM.errorText({ message: "BAD_PERIOD: choose" }), /Choose a month/);
  assert.match(CM.errorText({ message: "NOTHING_TO_APPROVE: none" }), /no drafts/);
  assert.match(CM.errorText({ message: "something odd" }), /Something went wrong/);
  assert.doesNotMatch(CM.errorText({ message: "NOT_FOUND" }), /NOT_FOUND/);
  assert.ok(CM.isMissing({ code: "PGRST202", message: "x" }) && CM.isMissing({ message: "Could not find the function public.centre_invoice_run_preview" }) && !CM.isMissing({ message: "NOT_FOUND" }));
});
test("wording for the model and grouping", () => {
  assert.strictEqual(CM.modelLabel({ model: "fixed_in_advance" }), "Fixed monthly fee");
  assert.strictEqual(CM.groupingLabel({ grouping: "student" }), "One invoice per student");
  assert.strictEqual(CM.unitWord({ grouping: "family" }, 2), "families");
});
