// Unit tests for assets/js/centre-deposits-core.js (T4 step S4): chips, summaries, ledger wording, the opening-balance form and the refusals in plain words.
// All names and amounts are made up.
const test = require("node:test"), assert = require("node:assert/strict");
const CD = require("../assets/js/centre-deposits-core.js"), CM = require("../assets/js/centre-money-core.js");

test("a deposit's state chip says what it is, with colour meaning only", () => {
  assert.deepEqual(CD.stateChip("held"), { text: "Held", tone: "ok" });
  assert.deepEqual(CD.stateChip("part_paid"), { text: "Part-paid", tone: "warn" });
  assert.deepEqual(CD.stateChip("unpaid"), { text: "Not paid yet", tone: "warn" });
  assert.deepEqual(CD.stateChip("draft"), { text: "Draft invoice", tone: "muted" });
  assert.deepEqual(CD.stateChip("waived"), { text: "Waived", tone: "muted" });
  assert.equal(CD.stateChip("???").text, "Not paid yet", "an unknown state is never shown as held");
});

test("how the amount was worked out", () => {
  assert.equal(CD.basisText({ mode: "percent_first_month", percent_bp: 5000, first_month_cents: 20000 }), "50% of the first month’s fee (S$200.00)");
  assert.equal(CD.basisText({ mode: "percent_first_month", percent_bp: 1250, first_month_cents: 20000 }), "12.5% of the first month’s fee (S$200.00)");
  assert.equal(CD.basisText({ mode: "fixed" }), "A fixed amount");
  assert.equal(CD.basisText({ mode: "opening" }), "Collected before TutorDeck");
  assert.equal(CD.previewLine({ mode: "percent_first_month", percent_bp: 5000, first_month_cents: 20000, frozen: false }), "50% of S$200.00 first month");
  assert.equal(CD.previewLine({ mode: "fixed", frozen: true }), "Fixed deposit · same amount as before");
});

test("list rows: who, what is still to collect, and the figure on the right", () => {
  const r = { household_name: "Aw Family", short_cents: 4500, invoice_number: "INV-5", waived_cents: 0 };
  assert.equal(CD.rowSub({ ...r, state: "held", source: "invoice_run" }), "Aw Family · Received in full");
  assert.equal(CD.rowSub({ ...r, state: "held", source: "opening_balance" }), "Aw Family · Collected before TutorDeck");
  assert.equal(CD.rowSub({ ...r, state: "part_paid" }), "Aw Family · S$45.00 still to collect");
  assert.equal(CD.rowSub({ ...r, state: "unpaid" }), "Aw Family · S$45.00 to collect · INV-5");
  assert.equal(CD.rowSub({ ...r, state: "draft" }), "Aw Family · Invoice not issued yet");
  assert.equal(CD.rowSub({ ...r, state: "waived", waived_cents: 5000 }), "Aw Family · S$50.00 waived");
  assert.equal(CD.rowAmount({ state: "held", held_cents: 10000, required_cents: 10000 }), 10000);
  assert.equal(CD.rowAmount({ state: "part_paid", held_cents: 3000, required_cents: 7500, due_cents: 7500 }), 3000, "a part-paid deposit shows what is held, not what is asked");
  assert.equal(CD.rowAmount({ state: "unpaid", held_cents: 0, required_cents: 7500, due_cents: 8175 }), 8175, "an unpaid deposit shows what the invoice asks for");
  assert.equal(CD.rowAmount({ state: "waived", held_cents: 4000 }), 4000, "a waived deposit shows only what was received");
});

test("summary lines", () => {
  assert.equal(CD.summaryLine({ students_holding: 0 }), "No deposits held yet");
  assert.equal(CD.summaryLine({ students_holding: 1 }), "1 student has a deposit held");
  assert.equal(CD.summaryLine({ students_holding: 3 }), "3 students have a deposit held");
  assert.equal(CD.shortLine({ short_cents: 0 }), "");
  assert.equal(CD.shortLine({ short_cents: 4500 }), "S$45.00 still to collect");
  assert.match(CD.emptyText(), /Refundable deposit/);
});

test("search finds by student, family or invoice number", () => {
  const rows = [{ name: "Amy Aw", household_name: "Aw Family", invoice_number: "INV-2" }, { name: "Dee Dee", household_name: "Dee Family", invoice_number: "INV-5" }];
  assert.equal(CD.searchRows(rows, "").length, 2);
  assert.deepEqual(CD.searchRows(rows, " amy ").map((r) => r.name), ["Amy Aw"]);
  assert.deepEqual(CD.searchRows(rows, "dee family").map((r) => r.name), ["Dee Dee"]);
  assert.deepEqual(CD.searchRows(rows, "inv-5").map((r) => r.name), ["Dee Dee"]);
  assert.equal(CD.searchRows(rows, "zzz").length, 0);
});

test("ledger rows: every kind has a plain label, and a waiver is never shown as cash", () => {
  for (const k of ["received", "reversal", "waived", "adjusted", "applied", "forfeited", "refunded", "transferred_out", "transferred_in", "opening_balance"]) assert.notEqual(CD.kindLabel(k), "Entry", k);
  assert.equal(CD.kindLabel("nonsense"), "Entry");
  assert.equal(CD.entryAmount({ kind: "received", cents: 10000 }), "+S$100.00");
  assert.equal(CD.entryAmount({ kind: "reversal", cents: -3000 }), "−S$30.00");
  assert.equal(CD.entryAmount({ kind: "waived", cents: 5000 }), "S$50.00");
  assert.equal(CD.entryLine({ date: "2026-11-26", kind: "received", invoice_number: "INV-2" }), "26 Nov 2026 · Received · INV-2");
  assert.equal(CD.entryLine({ date: "2026-10-01", kind: "opening_balance" }), "1 Oct 2026 · Collected before TutorDeck");
});

test("waiving is offered only while there is something to waive", () => {
  const base = { source: "invoice_run", short_cents: 5000, required_cents: 5000, name: "Ben Aw" };
  assert.ok(CD.canWaive({ ...base, state: "unpaid" }));
  assert.ok(CD.canWaive({ ...base, state: "part_paid" }));
  assert.ok(CD.canWaive({ ...base, state: "draft", short_cents: 0 }));
  assert.ok(!CD.canWaive({ ...base, state: "held", short_cents: 0 }), "a deposit paid in full can't be waived");
  assert.ok(!CD.canWaive({ ...base, state: "waived" }));
  assert.ok(!CD.canWaive({ ...base, source: "opening_balance", state: "held", short_cents: 0 }));
  assert.ok(!CD.canWaive(null));
  assert.match(CD.waiveQuestion({ ...base, state: "unpaid" }).message, /credit note takes S\$50\.00/);
  assert.match(CD.waiveQuestion({ ...base, state: "draft" }).message, /discarded/);
});

test("the opening-balance form", () => {
  const ok = { studentId: "s1", amountText: "150", date: "2026-10-01", today: "2026-11-26", note: " sheet " };
  assert.deepEqual(CD.checkOpening(ok), { ok: true, cents: 15000, note: "sheet" });
  assert.equal(CD.checkOpening({ ...ok, note: "" }).note, null);
  assert.match(CD.checkOpening({ ...ok, studentId: null }).error, /Choose the student/);
  assert.match(CD.checkOpening({ ...ok, amountText: "abc" }).error, /Type the amount/);
  assert.match(CD.checkOpening({ ...ok, amountText: "0" }).error, /more than S\$0\.00/);
  assert.match(CD.checkOpening({ ...ok, amountText: "-5" }).error, /(Type the amount|more than)/);
  assert.match(CD.checkOpening({ ...ok, amountText: "2000000" }).error, /too large/);
  assert.match(CD.checkOpening({ ...ok, date: "" }).error, /Choose the date/);
  assert.match(CD.checkOpening({ ...ok, date: "2026-11-27" }).error, /future/);
  assert.match(CD.checkOpening({ ...ok, note: "x".repeat(301) }).error, /300/);
  assert.equal(CD.checkOpening({ ...ok, date: "2026-11-26" }).ok, true, "today is fine");
  assert.equal(CD.openingText("Amy Aw", 15000), "S$150.00 recorded as held for Amy Aw.");
  assert.equal(CD.waivedText({ how: "draft_discarded" }), "Deposit waived. The draft invoice was discarded.");
  assert.equal(CD.waivedText({ how: "credit_note", waived_cents: 8000 }), "Deposit waived. S$80.00 was credited on the invoice.");
});

test("the invoice run's deposit lines", () => {
  assert.equal(CD.runDepositNote({ deposit_note: "coming soon" }), "coming soon");
  assert.equal(CD.runDepositNote({}), "");
  assert.equal(CD.runDepositTotal({ totals: { deposits: 3, deposit_cents: 22500 } }), "3 deposits · S$225.00");
  assert.equal(CD.runDepositTotal({ totals: { deposits: 1, deposit_cents: 1000 } }), "1 deposit · S$10.00");
  assert.equal(CD.runDepositTotal({ totals: { deposits: 0 } }), "");
  // the shared run wording learns about deposits and stays the same without them
  const p = { built: true, review_before_sending: true, totals: { ready: 2, deposits: 3, drafts: 0 } };
  assert.equal(CM.nextStep(p, []).label, "Create 2 drafts and 3 deposits");
  assert.equal(CM.nextStep({ ...p, totals: { ready: 2 } }, []).label, "Create 2 drafts");
  assert.equal(CM.nextStep({ ...p, review_before_sending: false, totals: { ready: 1, deposits: 1 } }, []).label, "Create and issue 1 invoice and 1 deposit");
  assert.equal(CM.createdText({ created: 2, issued: 0, deposits: 3, deposits_issued: 0 }), "2 drafts created. 3 refundable deposits drafted.");
  assert.equal(CM.createdText({ created: 2, issued: 2, deposits: 1, deposits_issued: 1 }), "2 drafts created and issued. 1 refundable deposit issued.");
  assert.equal(CM.createdText({ created: 2 }), "2 drafts created.");
  assert.equal(CM.approvedText({ issued: 5, first_number: "INV-1", last_number: "INV-5", deposits: 3 }), "5 invoices issued (INV-1 to INV-5), 3 of them refundable deposits.");
  assert.equal(CM.approvedText({ issued: 2, first_number: "INV-1", last_number: "INV-2" }), "2 invoices issued (INV-1 to INV-2).");
});

test("refusals in plain words", () => {
  assert.equal(CD.errorText({ message: "REASON_REQUIRED: say why this deposit is being waived" }), "Say why this deposit is being waived");
  assert.equal(CD.errorText({ message: "NOT_ALLOWED: only the centre owner can waive a deposit" }), "Only the centre owner can waive a deposit");
  assert.equal(CD.errorText({ message: "ALREADY_WAIVED: this deposit has already been waived" }), "This deposit has already been waived");
  assert.equal(CD.errorText({ message: "ALREADY_HAS_DEPOSIT: this student already has a deposit record" }), "This student already has a deposit record");
  assert.equal(CD.errorText({ message: "NOT_FOUND" }), "That isn’t available any more. Refresh the page and try again.");
  assert.match(CD.errorText({ message: "boom" }), /Something went wrong/);
  assert.equal(CD.isMissing({ code: "PGRST202" }), true);
});
