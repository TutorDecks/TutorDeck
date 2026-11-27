// Unit tests for assets/js/centre-late-fees-core.js (T4 step S6): the words for a waiting fee, the summary, the waive form check, the questions, the refusals.
// Made-up names and amounts. The rules themselves (grace, month ends, cap, GST) are proved in tests/sql/centre_late_fees_test.sql.
const test = require("node:test"), assert = require("node:assert/strict");
const L = require("../assets/js/centre-late-fees-core.js");

const w = (o) => ({ id: "f1", invoice_number: "INV-12", name: "Aw Family", month_no: 1, fee_date: "2026-11-15", fee_cents: 1000, base_cents: null, type: "fixed", repeat: "monthly",
  invoice_due_date: "2026-11-07", invoice_total_cents: 20000, balance_cents: 20000, days_late: 20, gst_cents: 90, total_cents: 1090, ...o });

test("a waiting fee names the invoice and family and says how late it is", () => {
  assert.equal(L.title(w()), "INV-12 · Aw Family");
  assert.equal(L.rowSub(w()), "Due 7 Nov 2026 · 20 days overdue · month 1");
  assert.equal(L.rowSub(w({ days_late: 1, repeat: "once" })), "Due 7 Nov 2026 · 1 day overdue");
  assert.equal(L.rowSub(w({ days_late: 0, repeat: "once" })), "Due 7 Nov 2026");
});

test("how the amount was worked out, and the amount with its GST", () => {
  assert.equal(L.basisText(w()), "A fixed amount set by the centre.");
  assert.equal(L.basisText(w({ type: "percent", base_cents: 15000 })), "A percentage of the S$150.00 still unpaid on 15 Nov 2026.");
  assert.equal(L.amountLine(w()), "S$10.00 + S$0.90 GST = S$10.90");
  assert.equal(L.amountLine(w({ gst_cents: 0, total_cents: 1000 })), "S$10.00");
});

test("the summary and the empty state", () => {
  assert.equal(L.summary({ waiting_count: 0 }), "No late fees waiting.");
  assert.equal(L.summary({ waiting_count: 1, waiting_cents: 1000 }), "1 late fee waiting · S$10.00");
  assert.equal(L.summary({ waiting_count: 3, waiting_cents: 3000 }), "3 late fees waiting · S$30.00");
  assert.match(L.emptyText({ enabled: true }), /Nothing is ever added to a family’s bill without you/);
  assert.equal(L.emptyText({ enabled: false, note: "Late fees are switched off for this centre." }), "Late fees are switched off for this centre.");
});

test("decided fees: waived shows the reason, approved shows its invoice", () => {
  assert.equal(L.recentLine({ status: "waived", reason: "Family hardship", decided_at: "2026-11-20T04:00:00Z" }), "Waived 20 Nov 2026 · Family hardship");
  assert.equal(L.recentLine({ status: "approved", document_number: "INV-31", decided_at: "2026-11-20T04:00:00Z" }), "Added to the family’s account as INV-31 · 20 Nov 2026");
  assert.deepEqual(L.recentChip({ status: "waived" }), { text: "Waived", tone: "muted" });
  assert.deepEqual(L.recentChip({ status: "approved" }), { text: "Approved", tone: "ok" });
});

test("who may waive is the centre's setting, said plainly", () => {
  assert.equal(L.waiveHint({ can: { waive: true, waived_by: "owner" } }), "");
  assert.equal(L.waiveHint({ can: { waive: false, waived_by: "owner" } }), "Only the centre owner can waive a late fee at this centre.");
  assert.equal(L.waiveHint({ can: { waive: false, waived_by: "issue_invoices" } }), "You can’t waive a late fee.");
  assert.equal(L.waiveHint(null), "");
});

test("waiving always needs a reason, and a short one", () => {
  assert.equal(L.checkWaive("").ok, false); assert.equal(L.checkWaive("   ").ok, false); assert.equal(L.checkWaive(null).ok, false);
  assert.deepEqual(L.checkWaive("  Family hardship "), { ok: true, reason: "Family hardship" });
  assert.equal(L.checkWaive("x".repeat(300)).ok, true);
  assert.equal(L.checkWaive("x".repeat(301)).ok, false);
});

test("the questions before approving say what happens", () => {
  const q = L.approveQuestion(w());
  assert.equal(q.confirmText, "Approve"); assert.match(q.message, /INV-12 · Aw Family/); assert.match(q.message, /S\$10\.00 \+ S\$0\.90 GST = S\$10\.90/); assert.match(q.message, /credit note/);
  const a = L.approveAllQuestion({ waiting_count: 3, waiting_cents: 3000 });
  assert.equal(a.title, "Approve all 3 late fees?"); assert.equal(a.confirmText, "Approve 3"); assert.match(a.message, /S\$30\.00 before GST/);
  assert.equal(L.approveAllQuestion({ waiting_count: 1, waiting_cents: 1000 }).title, "Approve all 1 late fee?");
});

test("what the screen says afterwards", () => {
  assert.equal(L.approvedText({ already: false, number: "INV-31" }), "Approved. It is now INV-31 on the family’s account.");
  assert.equal(L.approvedText({ already: true, number: "INV-31" }), "That late fee was already approved (INV-31).");
  assert.equal(L.approvedAllText({ approved: 3, skipped: 0, total_cents: 3270 }), "Approved 3 late fees (S$32.70).");
  assert.equal(L.approvedAllText({ approved: 1, skipped: 2, total_cents: 1090 }), "Approved 1 late fee (S$10.90). 2 were skipped (paid or credited in the meantime).");
  assert.equal(L.approvedAllText({ approved: 0, skipped: 0 }), "Nothing to approve.");
  assert.equal(L.waivedText({ already: false }), "Waived. The family isn’t charged.");
  assert.equal(L.waivedText({ already: true }), "That late fee was already waived.");
});

test("the database's refusals in plain words", () => {
  const e = (m) => L.errorText({ message: m });
  assert.equal(e("NOT_ALLOWED: only the centre owner can waive a late fee"), "Only the centre owner can waive a late fee");
  assert.equal(e("REASON_REQUIRED: say why this late fee is being waived"), "Say why this late fee is being waived");
  assert.equal(e("INVOICE_SETTLED: that invoice has been paid or credited, so no late fee is due"), "That invoice has been paid or credited, so no late fee is due");
  assert.equal(e("TOO_LONG: keep the reason under 300 characters"), "Keep the reason under 300 characters");
  assert.match(e("NOT_FOUND"), /isn’t available any more/);
  assert.match(e("something odd"), /Something went wrong/);
  assert.equal(L.isMissing({ code: "PGRST202" }), true); assert.equal(L.isMissing({ message: "boom" }), false);
});
