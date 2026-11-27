// Unit tests for assets/js/centre-refunds-core.js (T4 step S5): chips, the words for each step, the release / credit / paid forms, buttons, refusals. Made-up names and amounts.
const test = require("node:test"), assert = require("node:assert/strict");
const R = require("../assets/js/centre-refunds-core.js");

const dep = (o) => ({ kind: "deposit", state: "requested", student_name: "Amy Aw", household_name: "Aw Family", refund_cents: 6000, forfeit_cents: 0, set_off_cents: 0, held_cents: 6000, gst_cents: 0,
  requested_on: "2026-11-20", requested_by_name: "Billing Bea", reason: "Left the centre", approver_rule: "owner", events: [], can_approve: false, can_pay: false, can_cancel: false, ...o });

test("state chips: amber means somebody has to act, teal is done, grey is nothing to do", () => {
  assert.deepEqual(R.chip(dep()), { text: "Waiting for approval", tone: "warn" });
  assert.deepEqual(R.chip(dep({ state: "approved" })), { text: "Approved · to pay", tone: "warn" });
  assert.deepEqual(R.chip(dep({ state: "paid" })), { text: "Paid", tone: "ok" });
  assert.deepEqual(R.chip(dep({ state: "paid", refund_cents: 0, forfeit_cents: 6000 })), { text: "Done", tone: "ok" }, "keeping a deposit has no payment, so it is not 'Paid'");
  assert.deepEqual(R.chip(dep({ state: "cancelled" })), { text: "Cancelled", tone: "muted" });
  assert.equal(R.chip({ state: "???" }).tone, "warn", "an unknown state is never shown as done");
  assert.equal(R.isOpen(dep()), true); assert.equal(R.isOpen(dep({ state: "approved" })), true); assert.equal(R.isOpen(dep({ state: "paid" })), false); assert.equal(R.isOpen(dep({ state: "cancelled" })), false);
});

test("the list says who, what and how much", () => {
  assert.equal(R.title(dep()), "Amy Aw");
  assert.equal(R.title({ kind: "family_credit", household_name: "Bee Family" }), "Bee Family");
  assert.equal(R.kindLabel(dep()), "Deposit refund");
  assert.equal(R.kindLabel(dep({ refund_cents: 0, forfeit_cents: 6000 })), "Deposit kept");
  assert.equal(R.kindLabel({ kind: "family_credit" }), "Family credit refund");
  assert.equal(R.headline(dep()), 6000);
  assert.equal(R.headline(dep({ refund_cents: 0, forfeit_cents: 4000, set_off_cents: 2000 })), 6000, "a kept deposit shows what is kept in total");
  assert.equal(R.rowSub(dep()), "Deposit refund · asked 20 Nov 2026 by Billing Bea");
  assert.equal(R.amountLine(dep({ refund_cents: 1100, set_off_cents: 10900 })), "refunded to the family S$11.00 · kept against unpaid invoices S$109.00");
  assert.deepEqual(R.parts(dep({ refund_cents: 0, forfeit_cents: 500 })), [["Kept by the centre", 500]]);
});

test("who has to act next, for every approval rule", () => {
  assert.equal(R.approverWords(dep({ approver_rule: "owner" })), "Only the centre owner approves this.");
  assert.equal(R.approverWords(dep({ approver_rule: "staff" })), "The owner or a staff member who issues invoices approves this.");
  assert.equal(R.approverWords({ kind: "family_credit", approver_rule: "staff" }), "The owner or a staff member who records payments approves this.");
  assert.equal(R.approverWords(dep({ approver_rule: "four_eyes" })), "Someone other than Billing Bea has to approve this.");
  assert.equal(R.nextText(dep({ can_approve: true })), "It needs your approval.");
  assert.equal(R.nextText(dep({ can_approve: false })), "Only the centre owner approves this.");
  assert.match(R.nextText(dep({ state: "approved", can_pay: true })), /Pay the family, then mark it as paid/);
  assert.match(R.nextText(dep({ state: "approved", can_pay: false })), /Waiting for someone to pay/);
  assert.equal(R.nextText(dep({ state: "paid" })), "");
});

test("buttons come from what the database said the caller may do, with one primary action", () => {
  assert.deepEqual(R.actions(dep()), []);
  assert.deepEqual(R.actions(dep({ can_approve: true, can_cancel: true })).map((a) => a.id + (a.primary ? "*" : "")), ["approve*", "cancel"]);
  assert.deepEqual(R.actions(dep({ state: "approved", can_pay: true, can_cancel: true })).map((a) => a.id + (a.primary ? "*" : "")), ["pay*", "cancel"]);
  assert.equal(R.actions(dep({ state: "paid", can_cancel: false })).length, 0, "nothing to do once it is paid");
});

test("the trail shows who asked, approved and paid, how, and the reference", () => {
  const r = dep({ state: "paid", events: [{ kind: "approved", on: "2026-11-21", by: "Owen Owner", note: "Checked" }, { kind: "paid", on: "2026-11-22", by: "Pat Pay", method: "bank", reference: "DBS ending 6789" }] });
  const t = R.trail(r);
  assert.deepEqual(t.map((x) => x.label), ["Asked", "Approved", "Paid"]);
  assert.equal(t[0].detail, "Left the centre"); assert.equal(t[0].by, "Billing Bea");
  assert.equal(t[1].detail, "Checked");
  assert.equal(t[2].detail, "Bank transfer · DBS ending 6789");
  const kept = R.trail(dep({ state: "paid", refund_cents: 0, forfeit_cents: 6000, events: [{ kind: "approved", on: "2026-11-21", by: "Owen" }, { kind: "paid", on: "2026-11-21", by: "Owen", set_off_cents: 0 }] }));
  assert.equal(kept[2].label, "Done"); assert.equal(kept[2].detail, "Completed");
  const part = R.trail(dep({ state: "paid", set_off_cents: 10900, events: [{ kind: "paid", on: "2026-11-22", by: "Pat", method: "bank", set_off_cents: 5000 }] }));
  assert.match(part[1].detail, /Kept against invoices: S\$50\.00 of S\$109\.00 \(the rest stays held\)/);
  const c = R.trail(dep({ state: "cancelled", events: [{ kind: "cancelled", on: "2026-11-21", by: "Billing Bea", reason: "Changed their mind" }] }));
  assert.equal(c[1].label, "Cancelled"); assert.equal(c[1].detail, "Changed their mind");
  assert.deepEqual(R.calculationRows(dep({ taxable: true, gst_cents: 270, refund_cents: 3270, held_cents: 6540 })), [["Held when asked", 6540], ["Refunded to the family", 3270], ["GST given back with the refund", 270]]);
  assert.equal(R.releaseRuleText("refund_less_unpaid"), "Keep it against unpaid invoices, refund the rest");
  assert.equal(R.releaseRuleText("???"), "");
});

test("the release proposal in words", () => {
  assert.equal(R.canAsk({ state: "ready", can_request: true }), true);
  assert.equal(R.canAsk({ state: "ready", can_request: false }), false, "staff who can't act on deposits are never offered the button");
  assert.equal(R.canAsk({ state: "waiting", can_request: true }), false);
  assert.equal(R.waitingText({ state: "waiting", waiting: ["Lessons run until 25 Nov 2026. A refund can be asked for after that day."] }), "Lessons run until 25 Nov 2026. A refund can be asked for after that day.");
  assert.equal(R.waitingText({ state: "waiting", waiting: ["A.", "B."] }), "A. B.");
  assert.match(R.waitingText({ state: "nothing_held" }), /Nothing is held/);
  assert.match(R.waitingText({ state: "open_refund" }), /already in progress/);
  assert.equal(R.waitingText({ state: "ready" }), "");
  assert.equal(R.suggestionText({ state: "ready", suggest: { refund_cents: 1100, set_off_cents: 10900, forfeit_cents: 0 } }), "The centre’s rule suggests: refund S$11.00, keep S$109.00 against unpaid invoices.");
  assert.equal(R.suggestionText({ state: "ready", suggest: { refund_cents: 0, set_off_cents: 0, forfeit_cents: 12000 } }), "The centre’s rule suggests: keep S$120.00 (short notice).");
  assert.match(R.suggestionText({ state: "ready", suggest: null }), /an admin decides/);
  assert.equal(R.noticeNote({ notice_days: 0 }), "");
  assert.match(R.noticeNote({ notice_days: 14, notice_given_on: null }), /Type the day the family said they were leaving/);
  assert.equal(R.noticeNote({ notice_days: 14, notice_given_on: "2026-11-01", notice_short: true }), "Less than 14 days’ notice was given.");
  assert.equal(R.noticeNote({ notice_days: 14, notice_given_on: "2026-11-01", notice_short: false }), "Enough notice was given (14 days needed).");
  assert.equal(R.centsText(5450), "54.50"); assert.equal(R.centsText(0), "0.00");
});

test("the release form refuses what the database would refuse", () => {
  const p = { available_cents: 6000, unpaid_cents: 3000, taxable: false };
  const ok = R.checkRelease({ refundText: "30", forfeitText: "10", setOffText: "20", p, reason: " Left ", payee: " Pat " });
  assert.deepEqual(ok, { ok: true, refund: 3000, forfeit: 1000, setOff: 2000, reason: "Left", payee: "Pat" });
  assert.equal(R.checkRelease({ refundText: "60", forfeitText: "", setOffText: "", p, reason: "x" }).ok, true, "blank boxes mean S$0.00");
  assert.match(R.checkRelease({ refundText: "60.01", forfeitText: "", setOffText: "", p, reason: "x" }).error, /Only S\$60\.00 is held and free to release \(you typed S\$60\.01\)/);
  assert.match(R.checkRelease({ refundText: "", forfeitText: "", setOffText: "", p, reason: "x" }).error, /Choose how much/);
  assert.match(R.checkRelease({ refundText: "-5", forfeitText: "", setOffText: "", p, reason: "x" }).error, /negative/);
  assert.match(R.checkRelease({ refundText: "abc", forfeitText: "", setOffText: "", p, reason: "x" }).error, /Type amounts/);
  assert.match(R.checkRelease({ refundText: "", forfeitText: "", setOffText: "30.01", p, reason: "x" }).error, /owes only S\$30\.00/);
  assert.match(R.checkRelease({ refundText: "", forfeitText: "", setOffText: "10", p: { ...p, taxable: true }, reason: "x" }).error, /carried GST/);
  assert.match(R.checkRelease({ refundText: "10", forfeitText: "", setOffText: "", p, reason: "  " }).error, /Say why/);
  assert.match(R.checkRelease({ refundText: "10", forfeitText: "", setOffText: "", p, reason: "x".repeat(301) }).error, /under 300/);
  assert.match(R.checkRelease({ refundText: "10", forfeitText: "", setOffText: "", p, reason: "x", payee: "x".repeat(121) }).error, /under 120/);
  assert.match(R.checkRelease({ refundText: "10", forfeitText: "", setOffText: "", p: { ...p, notice_days: 14 }, reason: "x", noticeText: "2026-12-05", today: "2026-11-26" }).error, /future/);
  assert.match(R.checkRelease({ refundText: "10000000000", forfeitText: "", setOffText: "", p, reason: "x" }).error, /too large/);
  assert.deepEqual(R.releaseQuestion({ refund: 1100, setOff: 10900, forfeit: 0 }, "Amy").message, "You will refund S$11.00, keep S$109.00 against unpaid invoices. Nothing moves until it is approved and marked as paid.");
  assert.equal(R.releaseQuestion({ refund: 0, setOff: 0, forfeit: 12000 }, "Ben").message, "You will keep S$120.00 as income. Nothing moves until it is approved.");
  assert.equal(R.requestedText({ already: true }), "That request was already made.");
  assert.equal(R.requestedText({ already: false, approver_rule: "owner" }), "Asked. Only the centre owner approves this.");
});

test("family credit: refund and apply", () => {
  assert.equal(R.checkCreditRefund({ amountText: "30", available: 4100, reason: "Paid twice" }).cents, 3000);
  assert.match(R.checkCreditRefund({ amountText: "41.01", available: 4100, reason: "x" }).error, /Only S\$41\.00 of credit is free to refund/);
  assert.match(R.checkCreditRefund({ amountText: "0", available: 4100, reason: "x" }).error, /more than S\$0\.00/);
  assert.match(R.checkCreditRefund({ amountText: "", available: 4100, reason: "x" }).error, /Type the amount/);
  assert.match(R.checkCreditRefund({ amountText: "10", available: 4100, reason: " " }).error, /Say why/);
  assert.equal(R.applyAmount(9100, 5450), 5450); assert.equal(R.applyAmount(3000, 5450), 3000); assert.equal(R.applyAmount(-5, 100), 0); assert.equal(R.applyAmount(100, 0), 0);
  assert.deepEqual(R.checkApply({ amountText: "", available: 9100, balance: 5450 }), { ok: true, cents: 5450 }, "blank means as much as the invoice needs");
  assert.deepEqual(R.checkApply({ amountText: "10", available: 9100, balance: 5450 }), { ok: true, cents: 1000 });
  assert.match(R.checkApply({ amountText: "60", available: 9100, balance: 5450 }).error, /only owes S\$54\.50/);
  assert.match(R.checkApply({ amountText: "92", available: 9100, balance: 20000 }).error, /Only S\$91\.00 of credit is free to use/);
  assert.match(R.checkApply({ amountText: "", available: 0, balance: 5450 }).error, /no free credit/);
  assert.match(R.checkApply({ amountText: "", available: 100, balance: 0 }).error, /already paid/);
  assert.equal(R.appliedText({ already: false, applied_cents: 5100, credit_balance_cents: 4000 }), "S$51.00 of credit used. The family now holds S$40.00.");
  assert.equal(R.appliedText({ already: true }), "That credit was already applied.");
  assert.equal(R.creditLines({ balance_cents: 4100, reserved_cents: 0 }), "S$41.00 held for the family");
  assert.equal(R.creditLines({ balance_cents: 4100, reserved_cents: 3000 }), "S$41.00 held for the family · S$30.00 being refunded");
});

test("marking paid: how, when, and never a whole account number", () => {
  const base = { method: "bank", dateText: "2026-11-26", today: "2026-11-26", requestedOn: "2026-11-20", reference: "DBS ending 6789" };
  assert.deepEqual(R.checkPaid(base), { ok: true, method: "bank", date: "2026-11-26", reference: "DBS ending 6789" });
  assert.equal(R.checkPaid({ ...base, reference: "" }).reference, null, "the reference is optional");
  assert.match(R.checkPaid({ ...base, method: "" }).error, /how it was paid/);
  assert.match(R.checkPaid({ ...base, method: "barter" }).error, /how it was paid/);
  assert.match(R.checkPaid({ ...base, dateText: "" }).error, /Choose the day/);
  assert.match(R.checkPaid({ ...base, dateText: "2026-11-27" }).error, /future/);
  assert.match(R.checkPaid({ ...base, dateText: "2026-11-19" }).error, /before it was asked for \(20 Nov 2026\)/);
  assert.match(R.checkPaid({ ...base, reference: "DBS 0123456789" }).error, /full bank account or PayNow number/);
  assert.match(R.checkPaid({ ...base, reference: "91234567" }).error, /full bank account or PayNow number/, "an 8-digit mobile number is refused");
  assert.equal(R.checkPaid({ ...base, reference: "ending 1234, 26 Nov" }).ok, true, "short digit runs are fine");
  assert.match(R.checkPaid({ ...base, reference: "x".repeat(121) }).error, /under 120/);
  assert.equal(R.paidText({ already: true }), "That refund was already marked as paid.");
  assert.equal(R.paidText({ already: false, kind: "deposit", refund_cents: 100 }), "Marked as paid. The deposit and the record are updated.");
  assert.equal(R.paidText({ already: false, kind: "deposit", refund_cents: 0 }), "Done.");
  assert.equal(R.approvedText({ already: false, kind: "deposit", refund_cents: 100 }), "Approved. Now pay the family and mark it as paid.");
  assert.equal(R.approvedText({ already: false, kind: "deposit", refund_cents: 0 }), "Approved. The deposit has been kept.");
  assert.equal(R.approvedText({ already: true }), "That refund was already approved.");
  assert.equal(R.cancelledText({ already: false }), "Cancelled. Nothing was moved.");
  assert.equal(R.methodLabel("manual_paynow"), "PayNow");
});

test("the list: open refunds first, with a one-line summary", () => {
  const rows = [dep({ state: "paid" }), dep({ state: "requested" }), dep({ state: "approved" }), dep({ state: "cancelled" })];
  const s = R.split(rows);
  assert.equal(s.open.length, 2); assert.equal(s.closed.length, 2);
  assert.equal(R.summary(rows), "1 waiting for approval · 1 to pay");
  assert.equal(R.summary([dep({ state: "paid" })]), "Nothing waiting. 1 refund in the record.");
  assert.equal(R.summary([]), "No refunds yet.");
  assert.match(R.emptyText(), /No refunds yet/);
});

test("a request key is different every time (so a double press is the only repeat)", () => {
  const a = R.newKey(), b = R.newKey();
  assert.notEqual(a, b); assert.ok(a.length >= 8 && a.length <= 80);
});

test("the database's refusals in plain words", () => {
  assert.equal(R.errorText({ message: "DEPOSIT_SHORT: only S$60.00 is held and free to release (you asked for S$60.01)" }), "Only S$60.00 is held and free to release (you asked for S$60.01)");
  assert.equal(R.errorText({ message: "CREDIT_SHORT: this family has only S$11.00 available to refund (S$41.00 is held, S$30.00 is already being refunded)" }).slice(0, 18), "This family has on");
  assert.equal(R.errorText({ message: "NOT_ALLOWED: a refund has to be approved by someone other than the person who asked for it" }), "A refund has to be approved by someone other than the person who asked for it");
  assert.equal(R.errorText({ message: "NOT_READY: The student hasn't been ended yet." }), "The student hasn't been ended yet.");
  assert.match(R.errorText({ message: "OPEN_REFUND: a refund for this deposit is already in progress; finish or cancel it first" }), /already in progress/);
  assert.match(R.errorText({ message: "NOT_APPROVED: the refund has to be approved before it is marked paid" }), /approved before/);
  assert.match(R.errorText({ message: "ALREADY_PAID: that refund was already paid, so it can't be cancelled" }), /already paid/);
  assert.match(R.errorText({ message: "NOTHING_TO_APPLY: this family has no open invoice for the credit to pay" }), /no open invoice/);
  assert.equal(R.errorText({ message: "REASON_REQUIRED: say why" }), "Say why");
  assert.match(R.errorText({ message: "NOT_FOUND" }), /isn’t available any more/);
  assert.equal(R.isMissing({ code: "PGRST202" }), true); assert.equal(R.isMissing({ message: "something else" }), false);
});
