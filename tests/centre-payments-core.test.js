// Unit tests for the centre Money > Invoices page logic (T4 S3). No DOM, no network.  node --test tests/centre-payments-core.test.js
const test = require("node:test");
const assert = require("node:assert");
const CP = require("../assets/js/centre-payments-core.js");

test("status chips: colour is meaning (teal paid, red overdue, amber part-paid)", () => {
  assert.deepStrictEqual(CP.payChip("paid"), { text: "Paid", tone: "ok" });
  assert.deepStrictEqual(CP.payChip("overdue"), { text: "Overdue", tone: "bad" });
  assert.deepStrictEqual(CP.payChip("part_paid"), { text: "Part-paid", tone: "warn" });
  assert.deepStrictEqual(CP.payChip("issued"), { text: "Issued", tone: "muted" });
  assert.deepStrictEqual(CP.payChip("void"), { text: "Void (credited)", tone: "muted" });
  assert.strictEqual(CP.payChip("nonsense").text, "Issued");
});
test("filters: the five chips with the database's counts; the active one is marked", () => {
  const f = CP.filterChips({ all: 9, unpaid: 4, overdue: 1, part_paid: 2, paid: 5 }, "overdue");
  assert.deepStrictEqual(f.map((x) => x.label + ":" + x.count), ["All:9", "Unpaid:4", "Overdue:1", "Part-paid:2", "Paid:5"]);
  assert.deepStrictEqual(f.filter((x) => x.active).map((x) => x.key), ["overdue"]);
  assert.ok(CP.validFilter("part_paid")); assert.ok(!CP.validFilter("void")); assert.ok(!CP.validFilter("x"));
});
test("row lines say what matters for each status", () => {
  const base = { total_cents: 10900, paid_cents: 0, balance_cents: 10900, due_date: "2026-12-05" };
  assert.strictEqual(CP.rowSub({ ...base, pay_status: "issued" }, "2026-11-26"), "Due 5 Dec 2026");
  assert.strictEqual(CP.rowSub({ ...base, pay_status: "part_paid", paid_cents: 4000, balance_cents: 6900 }, "2026-11-26"), "S$40.00 of S$109.00 paid · due 5 Dec 2026");
  assert.strictEqual(CP.rowSub({ ...base, pay_status: "overdue", due_date: "2026-11-23" }, "2026-11-26"), "Overdue by 3 days");
  assert.strictEqual(CP.rowSub({ ...base, pay_status: "overdue", due_date: "2026-11-25", paid_cents: 1000 }, "2026-11-26"), "Overdue by 1 day · S$10.00 of S$109.00 paid");
  assert.strictEqual(CP.rowSub({ ...base, pay_status: "paid" }, "2026-11-26"), "Paid in full");
  assert.strictEqual(CP.rowSub({ ...base, pay_status: "void" }, "2026-11-26"), "Credited in full");
  assert.strictEqual(CP.rowAmount({ total_cents: 100, balance_cents: 40 }), 40);
  assert.strictEqual(CP.rowAmount({ total_cents: 100, balance_cents: 0 }), 100);
});
test("summary line and search", () => {
  assert.strictEqual(CP.summaryLine({ outstanding_cents: 12345, overdue_cents: 0 }), "S$123.45 owed");
  assert.strictEqual(CP.summaryLine({ outstanding_cents: 12345, overdue_cents: 500 }), "S$123.45 owed · S$5.00 overdue");
  const rows = [{ number: "INV-1", name: "Lim Family" }, { number: "INV-12", name: "Tan Family" }];
  assert.strictEqual(CP.searchRows(rows, " lim ").length, 1);
  assert.strictEqual(CP.searchRows(rows, "inv-1").length, 2);
  assert.strictEqual(CP.searchRows(rows, "").length, 2);
  assert.strictEqual(CP.searchRows(rows, "zzz").length, 0);
});
test("recording a payment: what is typed is checked in whole cents", () => {
  const rules = { partial_payments: true, overpayments: "credit" };
  const o = (t, extra) => Object.assign({ amountText: t, balance: 10900, rules, date: "2026-11-26", today: "2026-11-26" }, extra || {});
  assert.strictEqual(CP.checkPayment(o("40")).cents, 4000);
  assert.strictEqual(CP.checkPayment(o("S$1,090.50")).cents, 109050);
  assert.strictEqual(CP.checkPayment(o("0.1")).cents, 10);
  assert.ok(CP.checkPayment(o("109")).ok && !CP.checkPayment(o("109")).part && CP.checkPayment(o("109")).over === 0);
  const part = CP.checkPayment(o("40"));
  assert.ok(part.ok && part.part && /part-paid\. S\$69\.00 will still be owed/.test(part.note));
  const over = CP.checkPayment(o("120"));
  assert.ok(over.ok && over.over === 1100 && /S\$11\.00 is more than this invoice\. It will be kept as credit for the family\./.test(over.note));
  assert.ok(/marked to refund/.test(CP.checkPayment(o("120", { rules: { partial_payments: true, overpayments: "refund" } })).note));
  for (const bad of ["", "abc", "-5", "0", "0.00", "1e3", "12.345.6"]) assert.ok(!CP.checkPayment(o(bad)).ok, "refuse " + JSON.stringify(bad));
  assert.ok(!CP.checkPayment(o("2000000")).ok, "absurd amount");
  assert.ok(/future/.test(CP.checkPayment(o("10", { date: "2026-11-27" })).error));
  assert.ok(/Choose the date/.test(CP.checkPayment(o("10", { date: "" })).error));
});
test("partial payments switched off: only a payment that covers the invoice is accepted", () => {
  const rules = { partial_payments: false, overpayments: "credit" };
  const o = (t) => ({ amountText: t, balance: 10900, rules, date: "2026-11-26", today: "2026-11-26" });
  assert.ok(!CP.checkPayment(o("108.99")).ok);
  assert.ok(/doesn’t accept part payments.*S\$109\.00/.test(CP.checkPayment(o("108.99")).error));
  assert.ok(CP.checkPayment(o("109")).ok);
  assert.ok(CP.checkPayment(o("110")).ok);
});
test("credit note: amount, cap, reason; and what the family would be left holding", () => {
  const a = { total_cents: 10900, credited_cents: 1000, paid_cents: 0, balance_cents: 9900, rules: { overpayments: "credit" } };
  assert.strictEqual(CP.creditLeft(a), 9900);
  const c = CP.checkCredit({ amountText: "10", left: 9900, reason: " Lesson cancelled " });
  assert.ok(c.ok && c.cents === 1000 && c.reason === "Lesson cancelled");
  assert.ok(/at most S\$99\.00/.test(CP.checkCredit({ amountText: "100", left: 9900, reason: "x" }).error));
  assert.ok(/Say why/.test(CP.checkCredit({ amountText: "10", left: 9900, reason: "  " }).error));
  assert.ok(!CP.checkCredit({ amountText: "0", left: 9900, reason: "x" }).ok);
  assert.ok(!CP.checkCredit({ amountText: "x", left: 9900, reason: "x" }).ok);
  assert.ok(!CP.checkCredit({ amountText: "10", left: 9900, reason: "x".repeat(301) }).ok);
  assert.strictEqual(CP.creditExcess(a, 1000), 0);                                          // nothing paid: it just lowers the balance
  const paid = { total_cents: 10900, credited_cents: 0, paid_cents: 10900, balance_cents: 0, rules: { overpayments: "credit" } };
  assert.strictEqual(CP.creditExcess(paid, 1000), 1000);                                    // already paid: the family is owed it back
  assert.match(CP.creditQuestion(paid, { cents: 1000 }).message, /S\$10\.00 has already been paid, so it will be kept as credit for the family/);
  assert.match(CP.creditQuestion({ ...paid, rules: { overpayments: "refund" } }, { cents: 1000 }).message, /marked to refund/);
  assert.match(CP.creditQuestion(a, { cents: 1000 }).message, /reduces what the family owes/);
});
test("messages after an action", () => {
  assert.strictEqual(CP.paidText({ allocated: [{ number: "INV-1", balance_after_cents: 6900 }], excess_cents: 0 }), "Payment recorded. INV-1 is part-paid. S$69.00 still owed.");
  assert.strictEqual(CP.paidText({ allocated: [{ number: "INV-1", balance_after_cents: 0 }], excess_cents: 1550, excess_handling: "credit" }), "Payment recorded. INV-1 is paid. S$15.50 kept as credit for the family.");
  assert.match(CP.paidText({ allocated: [{}, {}], excess_cents: 100, excess_handling: "refund" }), /Covered 2 invoices\. S\$1\.00 to refund to the family\./);
  assert.strictEqual(CP.creditNoteText({ number: "CN-INV-1", total_cents: 1000, pay_status: "issued", excess_to_family_cents: 0 }), "Credit note CN-INV-1 issued for S$10.00.");
  assert.match(CP.creditNoteText({ number: "CN-INV-2", total_cents: 9900, pay_status: "void", excess_to_family_cents: 500 }), /The invoice is now void\. S\$5\.00 is now held for the family\./);
  assert.match(CP.reverseQuestion({ cents: 4000, method: "bank", received_on: "2026-11-20" }).message, /S\$40\.00 \(Bank transfer, 20 Nov 2026\)/);
});
test("payment lines and the amounts block", () => {
  assert.strictEqual(CP.paymentLine({ kind: "payment", received_on: "2026-11-20", method: "manual_paynow", reference: "ref 12" }), "20 Nov 2026 · PayNow · ref 12");
  assert.strictEqual(CP.paymentLine({ kind: "payment", received_on: "2026-11-20", method: "cash" }), "20 Nov 2026 · Cash");
  assert.strictEqual(CP.paymentLine({ kind: "reversal", received_on: "2026-11-21", method: "cash" }), "Reversal · 21 Nov 2026");
  assert.deepStrictEqual(CP.amountsRows({ total_cents: 10900, credited_cents: 1000, paid_cents: 4000, balance_cents: 5900 }),
    [["Invoice total", 10900], ["Credit notes", -1000], ["Paid", -4000], ["Still owed", 5900]]);
  assert.deepStrictEqual(CP.amountsRows({ total_cents: 100, credited_cents: 0, paid_cents: 0, balance_cents: 100 }), [["Invoice total", 100], ["Still owed", 100]]);
  assert.strictEqual(CP.creditLine(1550), "This family holds S$15.50 in credit."); assert.strictEqual(CP.creditLine(0), "");
});
test("the WhatsApp text is the centre's wording with the placeholders filled", () => {
  const vars = { name: "Lim Family", centre: "Pay Test Centre", number: "INV-5", amount_cents: 13800, due_date: "2026-12-03" };
  const tpl = "Hi {name}, this is {centre}. Invoice {number} for {amount} is due on {due_date}.\nYou can see it and pay by PayNow here: {link}\nThank you!";
  assert.strictEqual(CP.fillTemplate(tpl, vars, "https://x.test/pay?t=abc"),
    "Hi Lim Family, this is Pay Test Centre. Invoice INV-5 for S$138.00 is due on 3 Dec 2026.\nYou can see it and pay by PayNow here: https://x.test/pay?t=abc\nThank you!");
  assert.strictEqual(CP.fillTemplate(tpl, vars, ""), "Hi Lim Family, this is Pay Test Centre. Invoice INV-5 for S$138.00 is due on 3 Dec 2026.\nThank you!");   // links off: the link line goes
  assert.strictEqual(CP.fillTemplate("Pay {amount} {nonsense}!", vars, ""), "Pay S$138.00 !");
  assert.strictEqual(CP.waUrl("6591234567", "Hi & bye"), "https://wa.me/6591234567?text=Hi%20%26%20bye");
  assert.strictEqual(CP.waUrl(null, "x"), "https://wa.me/?text=x");
  assert.strictEqual(CP.waUrl("+65 9123-4567", "x"), "https://wa.me/6591234567?text=x");
  assert.strictEqual(CP.shareUrl("https://tutordeck.vercel.app/", "a-b"), "https://tutordeck.vercel.app/pay?t=a-b");
});
test("refusals come out in plain words", () => {
  assert.strictEqual(CP.errorText({ message: "PART_NOT_ALLOWED: this centre doesn't accept part payments, so a payment has to cover whole invoices. INV-1 still owes S$69.00." }),
    "This centre doesn't accept part payments, so a payment has to cover whole invoices. INV-1 still owes S$69.00.");
  assert.match(CP.errorText({ message: "NOT_ALLOWED: PAY-3 is already paid in full" }), /^PAY-3 is already paid in full$/);
  assert.match(CP.errorText({ message: "TOO_MUCH: you can credit at most S$99.00 more on this invoice (it came to S$109.00, already credited S$10.00)" }), /^You can credit at most S\$99\.00 more/);
  assert.match(CP.errorText({ message: "CREDIT_SHORT: that would take the family's credit below zero (they hold 550 cents)" }), /^That would take/);
  assert.match(CP.errorText({ message: "ALREADY_REVERSED: that payment was already reversed" }), /^That payment was already reversed/);
  assert.strictEqual(CP.errorText({ message: "REASON_REQUIRED: say why you are reversing this payment" }), "Please say why.");
  assert.match(CP.errorText({ message: "NOT_FOUND" }), /isn’t available any more/);
  assert.match(CP.errorText({ message: "Failed to fetch" }), /Couldn’t reach the server/);
  assert.match(CP.errorText({ message: "something odd" }), /Something went wrong/);
  assert.ok(CP.isMissing({ code: "PGRST202" }));
});
