// Unit tests (T4 step S5b) for the words and checks of "Undo credit or deposit used" in assets/js/centre-refunds-core.js, and the four-eyes readiness rule in
// assets/js/org-settings.js (the same rule as org_four_eyes_status() in db/migration_centre_credit_undo.sql, which tests/sql/centre_credit_undo_test.sql proves).
const test = require("node:test"), assert = require("node:assert/strict");
const R = require("../assets/js/centre-refunds-core.js");
const S = require("../assets/js/org-settings.js");

const app = (o) => Object.assign({ payment_id: "p1", method: "family_credit", cents: 15000, date: "2026-11-12", on_this_invoice_cents: 10000, also_invoices: ["INV-2"], by: "Billing Bea",
  state: "active", undone_on: null, undone_by: null, undone_reason: null, blockers: [], can_undo: true }, o || {});

test("an application is described in plain words", () => {
  assert.equal(R.undoTitle(app()), "Family credit used on this invoice");
  assert.equal(R.undoTitle(app({ method: "deposit" })), "Deposit kept against this invoice");
  assert.equal(R.undoWhat(app()), "family credit used");
  assert.equal(R.undoWhat(app({ method: "deposit" })), "deposit kept against the invoice");
  assert.equal(R.undoRow(app()), "12 Nov 2026 · by Billing Bea · also paid INV-2");
  assert.equal(R.undoRow(app({ also_invoices: [], by: null })), "12 Nov 2026");
  assert.equal(R.undoAmount(app()), 10000, "the row shows what it paid on THIS invoice");
  assert.equal(R.undoAmount(app({ on_this_invoice_cents: 0 })), 15000);
});

test("the question says what will happen, including every invoice it reopens", () => {
  const q = R.undoQuestion(app(), "INV-1");
  assert.match(q, /Take back S\$150\.00 of credit from INV-1 and 1 other invoice\?/);
  assert.match(q, /They will all owe money again/);
  assert.match(q, /back into the family’s credit/);
  const one = R.undoQuestion(app({ also_invoices: [], cents: 10000 }), "INV-1");
  assert.match(one, /from INV-1\?/); assert.match(one, /The invoice will owe S\$100\.00 again/);
  assert.match(R.undoQuestion(app({ method: "deposit", also_invoices: ["INV-2", "INV-3"] }), "INV-1"), /deposit from INV-1 and 2 other invoices.*student’s deposit/);
});

test("what is shown when there is no Undo button: what blocks it, or that it is done, or that the role can't", () => {
  assert.equal(R.undoNote(app(), true), "", "nothing to explain when it can be undone");
  assert.equal(R.undoNote(app({ can_undo: false, blockers: [{ code: "credit_note", text: "Invoice INV-1 has a credit note, issued after the credit was used. Its figures now depend on it." }] }), true),
    "Can’t be undone: Invoice INV-1 has a credit note, issued after the credit was used. Its figures now depend on it.");
  assert.equal(R.undoNote(app({ can_undo: false, blockers: [{ text: "A." }, { text: "B." }] }), true), "Can’t be undone: A. B.", "every blocker is listed");
  assert.equal(R.undoNote(app({ can_undo: false }), false), "Only the owner or a staff member who issues invoices can undo this.");
  assert.equal(R.undoNote(app({ state: "undone", undone_on: "2026-11-13", undone_by: "Billing Bea", undone_reason: "Wrong invoice" }), true), "Undone on 13 Nov 2026 by Billing Bea: Wrong invoice.");
  assert.equal(R.undoNote(app({ state: "undone", undone_on: "2026-11-13", undone_by: null, undone_reason: null }), false), "Undone on 13 Nov 2026.", "a person who may not undo is not shown the reason");
  assert.deepEqual(R.undoBlockers(app({ blockers: [{ text: "X" }] })), ["X"]);
  assert.deepEqual(R.undoBlockers(null), []);
});

test("a reason is required, trimmed and at most 300 characters", () => {
  assert.deepEqual(R.checkUndo({ reason: "  Wrong invoice " }), { ok: true, reason: "Wrong invoice" });
  assert.equal(R.checkUndo({ reason: "   " }).ok, false);
  assert.equal(R.checkUndo({}).ok, false);
  assert.equal(R.checkUndo({ reason: "x".repeat(300) }).ok, true);
  assert.equal(R.checkUndo({ reason: "x".repeat(301) }).ok, false);
});

test("the done message and the database's refusals are in plain words", () => {
  assert.equal(R.undoDoneText({ already: false, undone_cents: 15000 }, app()), "Undone. S$150.00 is back in the family’s credit.");
  assert.equal(R.undoDoneText({ already: false, undone_cents: 10000 }, app({ method: "deposit" })), "Undone. S$100.00 is back in the student’s deposit.");
  assert.equal(R.undoDoneText({ already: true }, app()), "That was already undone.");
  assert.equal(R.errorText({ message: "UNDO_BLOCKED: Money was recorded on invoice INV-3 after the credit was used. Reverse that payment first." }), "Money was recorded on invoice INV-3 after the credit was used. Reverse that payment first.");
  assert.equal(R.errorText({ message: "REASON_REQUIRED: say why this is being undone" }), "Say why this is being undone");
  assert.match(R.errorText({ message: "FOUR_EYES_UNAVAILABLE: needs a second approver" }), /^Needs a second approver/);
});

// ---- four eyes: the same cases as the SQL test (owner alone, one kind of staff, both, disabled, no permission, invited, a staff member covering both kinds) ----
const mem = (role, perms, o) => Object.assign({ role, status: "active", user_id: "u" + Math.random(), permissions: perms || [] }, o || {});
test("four-eyes can only be chosen when a second approver exists for both kinds of refund", () => {
  const owner = mem("owner"), bill = mem("staff", ["issue_invoices"]), pay = mem("staff", ["record_payments"]), both = mem("staff", ["issue_invoices", "record_payments"]);
  assert.equal(S.fourEyes([owner]).ready, false, "the owner alone");
  assert.equal(S.fourEyes([]).ready, false, "nobody");
  assert.equal(S.fourEyes([owner, bill]).ready, false, "only deposit refunds would have an approver");
  assert.equal(S.fourEyes([owner, pay]).ready, false, "only credit refunds would have an approver");
  assert.equal(S.fourEyes([owner, bill, pay]).ready, true, "one of each");
  assert.equal(S.fourEyes([owner, both]).ready, true, "one staff member covering both");
  assert.equal(S.fourEyes([bill, pay]).ready, false, "no owner");
  assert.equal(S.fourEyes([owner, mem("staff", ["issue_invoices", "record_payments"], { status: "disabled" })]).ready, false, "a switched-off account doesn't count");
  assert.equal(S.fourEyes([owner, mem("staff", ["issue_invoices", "record_payments"], { status: "invited", user_id: null })]).ready, false, "a pending invite doesn't count");
  assert.equal(S.fourEyes([owner, mem("staff", ["view_revenue"])]).ready, false, "a staff member without the permissions doesn't count");
  assert.equal(S.fourEyes([owner, mem("tutor", ["issue_invoices", "record_payments"])]).ready, false, "a tutor doesn't count whatever it says");
  assert.equal(S.fourEyes([owner, bill, pay, both]).ready, true);
  assert.equal(S.fourEyes([owner, pay, both]).ready, true, "one of two removed, the other still covers both");
  const r = S.fourEyes([owner]);
  assert.deepEqual([r.owner, r.deposit, r.credit], [true, false, false]);
  assert.match(r.reason, /Add a staff member who issues invoices \(for deposit refunds\) and a staff member who records payments \(for credit refunds\)/);
  assert.equal(S.fourEyes([owner, bill, pay]).reason, "");
});

test("the settings field still offers the three values, and its help explains the guard", () => {
  const f = [].concat(...S.STEPS.map((s) => s.fields || [])).filter((x) => x.path === "billing.deposit.refund_approved_by")[0];
  assert.deepEqual(f.options.map((o) => o[0]), ["owner", "staff", "four_eyes"]);
  assert.match(f.help, /second approver/);
  assert.ok(!f.soon && !(f.soonOptions || []).length, "none of the three is 'coming soon'");
});

test("credit and deposit used on an invoice are labelled as what they are (not 'Other') where they still appear as a payment line", () => {
  const P = require("../assets/js/centre-payments-core.js");
  assert.equal(P.methodLabel("family_credit"), "Family credit");
  assert.equal(P.methodLabel("deposit"), "Deposit kept");
  assert.equal(P.methodLabel("cash"), "Cash");
  assert.equal(P.methodLabel("???"), "Other");
  assert.ok(!P.METHODS.some((m) => m[0] === "family_credit" || m[0] === "deposit"), "they are not offered as ways to record a payment");
});
