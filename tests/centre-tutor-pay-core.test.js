// Unit tests for assets/js/centre-tutor-pay-core.js (T4 S7): rate form checks, the words for rates and states, bonus / payment checks, the manual pay-list CSV.
const test = require("node:test");
const assert = require("node:assert/strict");
const P = require("../assets/js/centre-tutor-pay-core.js");

test("rate text: every method in words, with money and percentages formatted", () => {
  assert.equal(P.rateText({ method: "per_lesson", amount_cents: 4000 }), "S$40.00 per lesson");
  assert.equal(P.rateText({ method: "per_hour", amount_cents: 5001 }), "S$50.01 per hour");
  assert.equal(P.rateText({ method: "per_student_lesson", amount_cents: 1500 }), "S$15.00 per student per lesson");
  assert.equal(P.rateText({ method: "monthly_fixed", amount_cents: 300000 }), "S$3,000.00 a month");
  assert.equal(P.rateText({ method: "percent_of_fee", percent_bp: 6000 }), "60% of the fee");
  assert.equal(P.rateText({ method: "percent_of_fee", percent_bp: 1250 }), "12.5% of the fee");
  assert.equal(P.rateText({ method: "percent_of_fee", percent_bp: 725 }), "7.25% of the fee");
  assert.equal(P.rateText({ method: "none" }), "Not paid");
  assert.equal(P.rateText({ method: "inherit" }), "Back to the usual rate");
  assert.equal(P.rateText(null), "No rate");
});

test("which methods a form offers: no monthly amount for one student, no 'back to usual' for the default, classes only when the centre runs them", () => {
  const ids = (scope, ct) => P.methodsFor(scope, ct).map((m) => m[0]);
  assert.ok(ids("default", "both").includes("monthly_fixed") && !ids("default", "both").includes("inherit"));
  assert.ok(!ids("student", "both").includes("monthly_fixed") && ids("student", "both").includes("inherit"));
  assert.ok(!ids("level", "both").includes("monthly_fixed") && ids("level", "both").includes("none"));
  assert.ok(!ids("default", "one_to_one").includes("per_student_lesson") && ids("default", "group").includes("per_student_lesson"));
  assert.ok(ids("default", "both").includes("percent_of_fee"));
});

test("percentages are read as basis points from the text, never with floating point", () => {
  assert.equal(P.parsePercent("60"), 6000);
  assert.equal(P.parsePercent("12.5%"), 1250);
  assert.equal(P.parsePercent("7.25"), 725);
  assert.equal(P.parsePercent("0.07"), 7);
  assert.equal(P.parsePercent("100"), 10000);
  assert.equal(P.parsePercent("1.005"), null);
  assert.equal(P.parsePercent("abc"), null);
  assert.equal(P.parsePercent("-5"), null);
  assert.equal(P.parsePercent(""), null);
});

const form = (o) => Object.assign({ scope: "default", method: "per_lesson", amountText: "40", from: "2026-12-01", reason: "Starting rate", today: "2026-11-27", classType: "both" }, o);
test("the new-rate form: every problem has a plain sentence and nothing is sent", () => {
  assert.equal(P.checkRate(form({ method: "" })).ok, false);
  assert.match(P.checkRate(form({ method: "" })).error, /how this tutor is paid/);
  assert.match(P.checkRate(form({ amountText: "" })).error, /Type the amount/);
  assert.match(P.checkRate(form({ amountText: "-5" })).error, /negative/);
  assert.match(P.checkRate(form({ amountText: "2000000" })).error, /too large/);
  assert.match(P.checkRate(form({ from: "" })).error, /date/);
  assert.match(P.checkRate(form({ reason: "  " })).error, /Say why/);
  assert.match(P.checkRate(form({ reason: "x".repeat(301) })).error, /300/);
  assert.match(P.checkRate(form({ scope: "student", studentId: "" })).error, /student/);
  assert.match(P.checkRate(form({ scope: "level", level: " " })).error, /level/);
  assert.match(P.checkRate(form({ scope: "level", level: "x".repeat(61) })).error, /60/);
  assert.match(P.checkRate(form({ method: "percent_of_fee", percentText: "101" })).error, /between 0% and 100%/);
  assert.match(P.checkRate(form({ method: "percent_of_fee", percentText: "lots" })).error, /percentage/);
  assert.match(P.checkRate(form({ method: "monthly_fixed", scope: "student", studentId: "s1" })).error, /isn’t available/);
  assert.match(P.checkRate(form({ method: "per_student_lesson", classType: "one_to_one" })).error, /isn’t available/);
});
test("the new-rate form: what is sent to the database", () => {
  assert.deepEqual(P.checkRate(form({})).args, { p_student: null, p_level: null, p_method: "per_lesson", p_amount_cents: 4000, p_percent_bp: null, p_effective_from: "2026-12-01", p_reason: "Starting rate" });
  assert.deepEqual(P.checkRate(form({ method: "per_hour", amountText: "S$60.50" })).args.p_amount_cents, 6050);
  const pct = P.checkRate(form({ method: "percent_of_fee", percentText: "60%" })).args;
  assert.equal(pct.p_percent_bp, 6000); assert.equal(pct.p_amount_cents, null);
  const st = P.checkRate(form({ scope: "student", studentId: "abc" })).args;
  assert.equal(st.p_student, "abc"); assert.equal(st.p_level, null);
  const lv = P.checkRate(form({ scope: "level", level: "  Sec 3 " })).args;
  assert.equal(lv.p_level, "Sec 3"); assert.equal(lv.p_student, null);
  const none = P.checkRate(form({ scope: "student", studentId: "abc", method: "none" })).args;
  assert.equal(none.p_amount_cents, null); assert.equal(none.p_percent_bp, null);
  const inh = P.checkRate(form({ scope: "level", level: "Sec 3", method: "inherit" })).args;
  assert.equal(inh.p_method, "inherit");
  assert.equal(P.checkRate(form({ amountText: "0" })).ok, true, "a rate of S$0.00 is allowed (volunteer lessons)");
  assert.match(P.checkRate(form({ from: "2026-11-01" })).note, /already taught/, "a start date in the past comes with a heads-up");
  assert.equal(P.checkRate(form({})).note, "");
});

test("a tutor's row on the rates screen", () => {
  const t = { rates: [
    { method: "per_lesson", amount_cents: 5000, effective_from: "2026-10-01", in_force: true },
    { method: "per_lesson", amount_cents: 4000, effective_from: "2026-01-01", in_force: false },
    { method: "per_lesson", amount_cents: 7000, student_id: "s", student_name: "Kid", effective_from: "2026-10-01", in_force: true },
    { method: "inherit", level: "Sec 3", effective_from: "2026-10-01", in_force: true },
    { method: "per_lesson", amount_cents: 6000, effective_from: "2027-01-01", in_force: false }] };
  assert.equal(P.currentDefault(t).amount_cents, 5000);
  assert.equal(P.tutorSub(t, "2026-11-27"), "S$50.00 per lesson · 1 special rate · a change from 1 Jan 2027");
  assert.equal(P.tutorSub({ rates: [] }, "2026-11-27"), "No rate yet");
  assert.equal(P.scopeText({ student_id: "s", student_name: "Kid" }), "Student: Kid");
  assert.equal(P.scopeText({ level: "Sec 3" }), "Level: Sec 3");
  assert.equal(P.scopeText({}), "Everything else");
  assert.match(P.historyLine(t.rates[4], "2026-11-27"), /from 1 Jan 2027 \(not started\)/);
  assert.match(P.historyLine(t.rates[0], "2026-11-27"), /since 1 Oct 2026/);
});

test("state chips: colour means something (teal = fine, amber = wait or act, red = a problem)", () => {
  assert.deepEqual(P.stateChip("payable"), { text: "Payable", tone: "ok" });
  for (const s of ["held", "part", "waiting_invoice", "waiting_charge"]) assert.equal(P.stateChip(s).tone, "warn", s);
  assert.equal(P.stateChip("no_rate").tone, "bad");
  assert.equal(P.stateChip("zero").tone, "muted");
  assert.equal(P.stateChip("what").tone, "muted", "an unknown state is grey, never a crash");
  for (const s of ["payable", "part", "held", "waiting_invoice", "waiting_charge", "no_rate", "zero", "unpaid", "monthly"]) assert.ok(P.stateHelp(s).length > 10, s);
  assert.equal(P.payChip({ pay_state: "paid" }).tone, "ok");
  assert.equal(P.payChip({ pay_state: "part_paid" }).text, "Part paid");
  assert.equal(P.payChip({ pay_state: "unpaid" }).text, "To pay");
  assert.equal(P.payChip({}).text, "Nothing due");
});

test("the pay-list row and summary words", () => {
  const t = { lessons: 4, minutes: 270, held_cents: 5000, carry_cents: 12000, waiting_invoice: 1, waiting_charge: 1, no_rate: 2 };
  assert.equal(P.rowSub(t), "4 lessons · 4h 30m · S$50.00 held · S$120.00 carried over · 2 lessons waiting · 2 with no rate");
  assert.equal(P.rowSub({ lessons: 1, minutes: 60, held_cents: 0, carry_cents: 0 }), "1 lesson · 1h");
  assert.equal(P.rowSub({ lessons: 0, minutes: 0, held_cents: 0, carry_cents: 0 }), "0 lessons");
  assert.equal(P.hoursText(45), "45m"); assert.equal(P.hoursText(90), "1h 30m"); assert.equal(P.hoursText(0), "0m");
  assert.equal(P.listSummary({ tutors: [{}], totals: { outstanding_cents: 22000, held_cents: 4000, paid_cents: 10000 } }), "S$220.00 to pay · S$40.00 held until families pay · S$100.00 paid");
  assert.equal(P.listSummary({ tutors: [], totals: {} }), "No tutors yet.");
  assert.deepEqual(P.dueRows({ carry_cents: 100, released_cents: 20000, monthly_cents: 0, adjustments_cents: -500 }), [["Carried over from earlier", 100], ["Lessons released this period", 20000], ["Bonuses and deductions", -500]]);
  assert.match(P.unassignedNote(2), /2 lessons were taught with no tutor/);
  assert.equal(P.unassignedNote(0), "");
  assert.match(P.modeNote("report"), /report only/); assert.match(P.modeNote("off"), /switched off/);
  assert.match(P.modeNote("full", "parent_paid"), /after the family’s payment/); assert.match(P.modeNote("full", "taught"), /once it has been taught/);
  assert.equal(P.lineSub({ date: "2026-11-05", student: "Kid 1", minutes: 60, trial: true, lesson_status: "cancelled" }), "5 Nov 2026 · Kid 1 · 60 min · trial · cancelled");
  assert.equal(P.lineAmount({ earn_cents: null }), ""); assert.equal(P.lineAmount({ earn_cents: 4000 }), "S$40.00");
  assert.equal(P.lineHeld({ held_cents: 4000 }), "S$40.00 held"); assert.equal(P.lineHeld({ held_cents: 0 }), "");
});

test("a bonus or deduction: the sign comes from the choice, a reason is required", () => {
  const base = { kind: "bonus", amountText: "25", on: "2026-11-20", reason: "Great month" };
  assert.deepEqual(P.checkAdjustment(base), { ok: true, args: { p_amount_cents: 2500, p_on: "2026-11-20", p_reason: "Great month" } });
  assert.equal(P.checkAdjustment(Object.assign({}, base, { kind: "deduction" })).args.p_amount_cents, -2500);
  assert.equal(P.checkAdjustment(Object.assign({}, base, { amountText: "-25", kind: "deduction" })).args.p_amount_cents, -2500, "a typed minus sign doesn't double up");
  assert.match(P.checkAdjustment(Object.assign({}, base, { reason: " " })).error, /Say why/);
  assert.match(P.checkAdjustment(Object.assign({}, base, { amountText: "0" })).error, /more than/);
  assert.match(P.checkAdjustment(Object.assign({}, base, { amountText: "" })).error, /Type the amount/);
  assert.match(P.checkAdjustment(Object.assign({}, base, { on: "" })).error, /date/);
  assert.match(P.checkAdjustment(Object.assign({}, base, { kind: "" })).error, /bonus or deduction/);
  assert.match(P.checkAdjustment(Object.assign({}, base, { reason: "x".repeat(301) })).error, /300/);
  assert.equal(P.adjustmentLine({ kind: "deduction", effective_on: "2026-11-21", reason: "Lost textbook" }), "Deduction · 21 Nov 2026 · Lost textbook");
});

test("recording a payment: never more than is outstanding, never a future day, never a whole account number", () => {
  const base = { amountText: "100", outstanding: 22000, method: "bank", date: "2026-11-27", today: "2026-11-27", reference: "Pay run 1" };
  const ok = P.checkPayment(base);
  assert.equal(ok.ok, true); assert.equal(ok.cents, 10000); assert.equal(ok.part, true); assert.match(ok.note, /S\$120\.00 will still be to pay/);
  assert.equal(P.checkPayment(Object.assign({}, base, { amountText: "220" })).part, false);
  assert.match(P.checkPayment(Object.assign({}, base, { amountText: "220.01" })).error, /Only S\$220\.00 is still to pay/);
  assert.match(P.checkPayment(Object.assign({}, base, { amountText: "0" })).error, /more than/);
  assert.match(P.checkPayment(Object.assign({}, base, { amountText: "x" })).error, /Type the amount/);
  assert.match(P.checkPayment(Object.assign({}, base, { method: "" })).error, /how you paid/);
  assert.match(P.checkPayment(Object.assign({}, base, { date: "2026-11-28" })).error, /future/);
  assert.match(P.checkPayment(Object.assign({}, base, { reference: "DBS 123456789012" })).error, /last 4 digits/);
  assert.match(P.checkPayment(Object.assign({}, base, { reference: "x".repeat(101) })).error, /100/);
  assert.equal(P.checkPayment(Object.assign({}, base, { reference: "" })).ref, null);
  assert.equal(P.checkPayment(Object.assign({}, base, { reference: "PayNow ending 1234" })).ok, true);
  assert.match(P.payQuestion("Tali", ok, "1 Nov to 30 Nov").message, /doesn’t send the money/);
});

const list = { month: "2026-11-01", period_from: "2026-11-01", period_to: "2026-11-30", tutors: [
  { name: "Tali Tan", employment_type: "employee", outstanding_cents: 22000 },
  { name: "Tom, \"TJ\" Lee", employment_type: "freelancer", outstanding_cents: 123456 },
  { name: "Paid Person", employment_type: "freelancer", outstanding_cents: 0 },
  { name: "Owes Back", employment_type: "freelancer", outstanding_cents: -500 },
  { name: "=HYPERLINK(\"http://x\")", employment_type: null, outstanding_cents: 100 }] };
test("the manual pay list: only people still owed money, plain amounts, safe in a spreadsheet, no bank details", () => {
  const rows = P.csvRows(list);
  assert.equal(rows.length, 3);
  assert.deepEqual(rows[0], ["Tali Tan", "Employee", "220.00", "Tutor pay November 2026", "1 Nov 2026 to 30 Nov 2026"]);
  assert.equal(rows[1][2], "1234.56", "no thousands separator: a bank upload would choke on it");
  const csv = P.buildCsv(list).split("\r\n");
  assert.equal(csv[0], "Payee,Employment,Amount (S$),Reference,Period");
  assert.equal(csv[1], "Tali Tan,Employee,220.00,Tutor pay November 2026,1 Nov 2026 to 30 Nov 2026");
  assert.equal(csv[2], '"Tom, ""TJ"" Lee",Freelancer,1234.56,Tutor pay November 2026,1 Nov 2026 to 30 Nov 2026', "commas and quotes are escaped");
  assert.ok(csv[3].startsWith("\"'=HYPERLINK(\"\"http://x\"\")\"") || csv[3].startsWith("'=HYPERLINK"), "a name that starts with = can't run as a formula: " + csv[3]);
  assert.equal(csv.length, 5, "header + 3 rows + trailing newline");
  assert.ok(!/bank|account|paynow number|uen/i.test(csv.join("\n").replace(/Bank transfer/i, "")), "no bank detail column");
  assert.equal(P.csvTotal(list), 22000 + 123456 + 100);
  assert.equal(P.csvName(list), "tutor-pay-2026-11.csv");
  assert.equal(P.buildCsv({ month: "2026-11-01", tutors: [] }), "Payee,Employment,Amount (S$),Reference,Period\r\n");
  assert.equal(P.csvCell("+1"), "'+1"); assert.equal(P.csvCell("-1"), "'-1"); assert.equal(P.csvCell("@a"), "'@a"); assert.equal(P.csvCell("plain"), "plain"); assert.equal(P.csvCell(null), "");
  assert.equal(P.amountCsv(5), "0.05"); assert.equal(P.amountCsv(100000000), "1000000.00");
});

test("the database's refusals in plain words", () => {
  const e = (m) => P.errorText({ message: m });
  assert.equal(e("PERIOD_PAID: pay for the period ending 2026-10-31 is already recorded for this tutor, so nothing can be dated on or before then; use a later date"), "Pay for the period ending 2026-10-31 is already recorded for this tutor, so nothing can be dated on or before then; use a later date");
  assert.match(e("TOO_MUCH: only S$12.00 is still to pay for this period"), /^Only S\$12\.00/);
  assert.match(e("PAY_OFF: tutor pay is switched off in Centre settings"), /switched off/);
  assert.match(e("PAY_REPORT_ONLY: this centre uses the lessons-taught report only; switch"), /report only/);
  assert.match(e("NOT_ALLOWED: your account can't see or change tutor pay at this centre"), /^Your account can't/);
  assert.match(e("NOT_FOUND"), /isn’t available any more/);
  assert.match(e("REASON_REQUIRED: say why"), /^Say why/);
  assert.match(e("ADJUSTMENTS_OFF: bonuses and deductions are switched off in Centre settings"), /^Bonuses and deductions/);
  assert.match(e("BAD_RATE: the percentage must be between 0% and 100%"), /between 0% and 100%/);
  assert.match(e("Failed to fetch"), /Couldn’t reach the server/);
  assert.match(e(""), /Something went wrong/);
  assert.equal(P.isMissing({ code: "PGRST202" }), true); assert.equal(P.isMissing({ code: "42501" }), false);
});
