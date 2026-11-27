// node --test tests/   — settings schema: defaults are valid, matches the database's checks, edge cases.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const S = require("../assets/js/org-settings.js");
const SQL = fs.readFileSync(require.resolve("../db/migration_org_foundation.sql"), "utf8");
const MONEY = fs.readFileSync(require.resolve("../db/migration_money_settings.sql"), "utf8");   // T4 S0: the replacement validator
const field = (path) => S.STEPS.flatMap((s) => s.fields).find((f) => f.path === path);

test("defaults are valid once named, for both presets", () => {
  for (const preset of ["centre", "solo"]) {
    const s = S.defaults(preset);
    s.profile.trading_name = "Test";
    assert.deepEqual(S.validate(s), [], preset);
  }
  assert.ok(S.validate(S.defaults("centre")).some((m) => /trading name/.test(m)));
});

test("payout default is 'after the parent has paid' (owner's rule)", () => {
  assert.equal(S.defaults("centre").tutor_pay.payable_when, "parent_paid");
});

test("every wizard step 1–10 exists, in order", () => {
  assert.deepEqual(S.STEPS.map((s) => s.n), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  for (const st of S.STEPS) for (const f of st.fields) if (f.type !== "note" && f.type !== "group") assert.notEqual(S.get(S.defaults(), f.path), undefined, f.path + " has a default");
});

test("enums agree with org_validate_settings() in the migration", () => {
  const enumOf = (re) => (SQL.match(re) || [, ""])[1].match(/'([a-z_]+)'/g).map((x) => x.slice(1, -1)).sort();
  const opts = (path) => S.STEPS.flatMap((s) => s.fields).find((f) => f.path === path).options.map((o) => o[0]).sort();
  assert.deepEqual(opts("billing.model"), enumOf(/\{billing,model\}' not in \(([^)]*)\)/));
  assert.deepEqual(opts("tutor_pay.mode"), enumOf(/\{tutor_pay,mode\}' not in \(([^)]*)\)/));
  assert.deepEqual(opts("tutor_pay.payable_when"), enumOf(/\{tutor_pay,payable_when\}' not in \(([^)]*)\)/));
  assert.deepEqual(opts("invoicing.grouping"), enumOf(/\{invoicing,grouping\}' not in \(([^)]*)\)/));
  assert.deepEqual(opts("payments.modes"), enumOf(/\{payments,modes\}' \?\| array\[([^\]]*)\]/));
  assert.deepEqual(opts("lessons.attendance_by"), enumOf(/\{lessons,attendance_by\}' not in \(([^)]*)\)/));
  assert.deepEqual(opts("lessons.cancellations_marked_by"), enumOf(/\{lessons,cancellations_marked_by\}' not in \(([^)]*)\)/));
  assert.deepEqual(opts("lessons.compensation_entered_by"), enumOf(/\{lessons,compensation_entered_by\}' not in \(([^)]*)\)/));
  assert.deepEqual(opts("lessons.trials_flagged_by"), enumOf(/\{lessons,trials_flagged_by\}' not in \(([^)]*)\)/));
});

test("staff permissions agree with org_invite() in the migration", () => {
  const sqlPerms = SQL.match(/where x not in \(([^)]*)\)/)[1].match(/'([a-z_]+)'/g).map((x) => x.slice(1, -1)).sort();
  assert.deepEqual(S.STAFF_PERMISSIONS.map((p) => p.key).sort(), sqlPerms);
});

test("validation catches bad values", () => {
  const s = S.defaults(); s.profile.trading_name = "X";
  s.profile.gst_registered = true; s.profile.gst_number = "";
  s.payments.modes = [];
  s.invoicing.generate.day = 31;
  s.billing.model = "barter";
  s.billing.one_off_fees.deposit_cents = 12.5;
  const e = S.validate(s).join(" | ");
  for (const want of [/GST registration/, /at least one way/, /1–28/, /Default billing model/, /Deposit amount must be a whole number/]) assert.match(e, want);
});

test("billing changes start next cycle; profile changes today; never back-dated", () => {
  const a = S.defaults(); a.profile.trading_name = "X";
  const b = JSON.parse(JSON.stringify(a)); b.profile.address = "1 Road";
  assert.equal(S.effectiveFrom(a, b, "2026-11-23"), "2026-11-23");
  const c = JSON.parse(JSON.stringify(a)); c.billing.model = "prepaid_packages";
  assert.equal(S.effectiveFrom(a, c, "2026-11-23"), "2026-12-01");
  assert.equal(S.effectiveFrom(a, c, "2026-12-31"), "2027-01-01");
});

test("stored older settings gain new keys without losing values", () => {
  const stored = { schema_version: 1, preset: "solo", profile: { trading_name: "Mine", invoice_prefix: "BM" }, payments: { modes: ["manual_paynow"] } };
  const s = S.withDefaults(stored);
  assert.equal(s.profile.invoice_prefix, "BM");
  assert.equal(s.profile.gst_rate_bp, 900);
  assert.equal(s.tutor_pay.mode, "off");           // solo preset default
  assert.deepEqual(s.payments.modes, ["manual_paynow"]);
});

test("settings nothing reads yet are marked soon, with help text (T18a)", () => {
  const fields = {};
  S.STEPS.forEach((st) => st.fields.forEach((f) => { fields[f.path] = f; }));
  const credit = "Make-up credits come in a later update; for now a make-up is added as a normal lesson.";
  for (const p of ["billing.makeups.allowed", "billing.makeups.per_period", "billing.makeups.uses_credit",
    "billing.low_balance_credits", "billing.credit_expiry_days"]) {
    assert.equal(fields[p].soon, true, p + " must be soon");
    assert.equal(fields[p].help, credit, p);
  }
  assert.equal(fields["calendar.skip_holidays"].soon, true);
  assert.match(fields["calendar.skip_holidays"].help, /later update/);
  // saved values stay valid
  const s = S.defaults("centre"); s.profile.trading_name = "T";
  s.billing.makeups = { allowed: false, per_period: 5, uses_credit: true };
  s.calendar.skip_holidays = false;
  assert.deepEqual(S.validate(s), []);
});

// ---------------------------------------------------------------------------------------------------- T4 S0: centre money options
const ENUMS = ["tutor_pay.rate_model", "tutor_pay.percent_base", "tutor_pay.part_payments", "tutor_pay.cancelled_lessons", "tutor_pay.group_count",
  "billing.deposit.mode", "billing.deposit.due", "billing.deposit.waived_by", "billing.deposit.release", "billing.deposit.refund_approved_by",
  "billing.late_fee.repeat", "billing.late_fee.type", "billing.late_fee.show_as", "billing.late_fee.waived_by", "lessons.class_type"];
const BOOLS = ["billing.deposit.taxable", "billing.deposit.top_up", "billing.deposit.set_off_unpaid", "billing.deposit.final_month", "billing.trials.charged"];
const INTS = { "billing.deposit.percent_bp": [0, 10000], "billing.deposit.forfeit_notice_days": [0, 90], "billing.late_fee.percent_bp": [0, 10000],
  "billing.late_fee.after_days": [0, 365], "billing.late_fee.cap_cents": [0, 100000000], "billing.late_fee.amount_cents": [0, 100000000],
  "billing.one_off_fees.deposit_cents": [0, 100000000], "profile.next_invoice_number": [1, 999999999] };

test("T4 S0: every new choice has the same values in the form and in db/migration_money_settings.sql", () => {
  for (const path of ENUMS) {
    const key = path.replace(/\./g, ",");
    const m = MONEY.match(new RegExp("\\{" + key + "\\}' not in \\(([^)]*)\\)"));
    assert.ok(m, path + " is checked in the migration");
    const sql = m[1].match(/'([a-z_0-9]+)'/g).map((x) => x.slice(1, -1)).sort();
    assert.deepEqual(field(path).options.map((o) => o[0]).sort(), sql, path);
    assert.ok(field(path).options.some((o) => o[0] === S.get(S.defaults(), path)), path + " default is one of the options");
  }
});

test("T4 S0: every new yes/no and number has the same limits in the form and in the migration", () => {
  for (const b of BOOLS) assert.ok(MONEY.includes("'{" + b.replace(/\./g, ",") + "}'"), b + " is checked in the migration");
  for (const [path, [lo, hi]] of Object.entries(INTS)) {
    const re = new RegExp("\\('\\{" + path.replace(/\./g, ",") + "\\}', (\\d+), (\\d+),");
    const m = MONEY.match(re);
    assert.ok(m, path + " is checked in the migration");
    assert.deepEqual([+m[1], +m[2]], [lo, hi], path);
    const v = S.get(S.defaults(), path);
    assert.ok(Number.isInteger(v) && v >= lo && v <= hi, path + " default is inside its limits");
  }
  for (const b of BOOLS) assert.equal(typeof S.get(S.defaults(), b), "boolean", b);
});

test("T4 S0/S4/S6: trial, percentage-pay and the unbuilt deposit options are 'coming soon' until their step ships (honesty)", () => {
  const soonPaths = ["billing.trials.charged",
    "billing.deposit.top_up",
    "billing.deposit.set_off_unpaid", "billing.deposit.final_month"];
  for (const p of soonPaths) assert.equal(field(p).soon, true, p + " must be soon");
  // T4 S7: tutor rates, the pay list, percentage pay, held-until-paid and adjustments are built; bank-file payout is not (tutors seeing their own pay: S7b, below)
  for (const p of ["tutor_pay.mode", "tutor_pay.payable_when", "tutor_pay.rate_model", "tutor_pay.percent_base", "tutor_pay.part_payments", "tutor_pay.cancelled_lessons",
    "tutor_pay.group_count", "tutor_pay.rates_note", "tutor_pay.adjustments", "tutor_pay.cycle.cutoff_day", "tutor_pay.cycle.pay_day", "tutor_pay.tutors_see_own_pay"]) assert.ok(!field(p).soon, p + " is built in S7 / S7b");
  for (const k of ["mode", "rate_model", "part_payments"]) assert.ok(!(field("tutor_pay." + k).soonOptions || []).length, "tutor_pay." + k + " has no unbuilt option left");
  assert.deepEqual(field("tutor_pay.payout_method").soonOptions, ["bank_file"], "only the manual list is built; the bank file waits for the owner's bank");
  assert.ok(field("billing.deposit.due").soonOptions.includes("before_first_lesson"));
  // the sub-headings carry the same badge and say what is missing (the deposit heading is live from S4: it says what is still to come)
  for (const g of S.STEPS.flatMap((s) => s.fields).filter((f) => f.type === "group")) { if (g.label !== "Refundable deposit" && g.label !== "Late fees") assert.equal(g.soon, true, g.label); assert.match(g.help, /later update/); }
  // T4 S6: every late-fee option is built (proposals a person approves or waives); only "a line on the next invoice" is still to come
  for (const p of ["billing.late_fee.enabled", "billing.late_fee.repeat", "billing.late_fee.type", "billing.late_fee.amount_cents", "billing.late_fee.percent_bp", "billing.late_fee.after_days",
    "billing.late_fee.cap_cents", "billing.late_fee.show_as", "billing.late_fee.waived_by"]) assert.ok(!field(p).soon, p + " is built in S6");
  assert.deepEqual(field("billing.late_fee.show_as").soonOptions, ["next_invoice_line"], "the own-invoice placement is built; the line on the next invoice is not");
  assert.match(S.STEPS.flatMap((s) => s.fields).find((f) => f.type === "group" && f.label === "Late fees").help, /later update/);
  // T4 S4: what the invoice run now does with deposits is NOT 'soon'
  for (const p of ["billing.deposit.mode", "billing.one_off_fees.deposit_cents", "billing.deposit.percent_bp", "billing.deposit.taxable", "billing.deposit.due", "billing.deposit.waived_by"]) assert.ok(!field(p).soon, p + " is built in S4");
  // T4 S5: release, the forfeit notice and who approves a refund are built (refunds, family credit, keeping a deposit)
  for (const p of ["billing.deposit.release", "billing.deposit.forfeit_notice_days", "billing.deposit.refund_approved_by"]) assert.ok(!field(p).soon, p + " is built in S5");
  // the fixed amount is only asked for in fixed mode, the percentage only in percent mode
  const d = S.defaults("centre");
  d.billing.deposit.mode = "none"; assert.ok(!field("billing.one_off_fees.deposit_cents").show(d) && !field("billing.deposit.percent_bp").show(d));
  d.billing.deposit.mode = "fixed"; assert.ok(field("billing.one_off_fees.deposit_cents").show(d) && !field("billing.deposit.percent_bp").show(d));
  d.billing.deposit.mode = "percent_first_month"; assert.ok(!field("billing.one_off_fees.deposit_cents").show(d) && field("billing.deposit.percent_bp").show(d));
  // options that already work are not marked soon by accident
  for (const p of ["lessons.class_type", "profile.next_invoice_number", "billing.one_off_fees.registration_cents"]) assert.ok(!field(p).soon, p);
});

test("T4 S0: the defaults are the owner's rules", () => {
  const d = S.defaults("centre");
  assert.equal(d.billing.deposit.refund_approved_by, "owner");            // staff request, the owner approves
  assert.equal(d.billing.deposit.taxable, false);                         // a refundable deposit is not taxed when received
  assert.equal(d.billing.deposit.due, "with_first_invoice");
  assert.equal(d.billing.deposit.mode, "none");
  assert.equal(d.tutor_pay.percent_base, "billed_after_discounts");       // after discounts, before GST
  assert.equal(d.tutor_pay.part_payments, "after_full");                  // payable only when the invoice line is fully paid
  assert.equal(d.billing.late_fee.show_as, "own_invoice");               // a default must be something that is built
  assert.equal(d.billing.trials.charged, false);
  assert.equal(d.lessons.class_type, "both");                            // nothing changes for existing centres
});

test("T4 S0: percentages and notice periods are checked (a bad percent is refused)", () => {
  const ok = () => { const s = S.defaults(); s.profile.trading_name = "T"; return s; };
  const bad = (mut, want) => { const s = ok(); mut(s); assert.match(S.validate(s).join(" | "), want); };
  bad((s) => { s.billing.deposit.mode = "percent_first_month"; s.billing.deposit.percent_bp = 0; }, /Deposit percentage must be between 0\.01% and 100%/);
  bad((s) => { s.billing.deposit.mode = "percent_first_month"; s.billing.deposit.percent_bp = 10001; }, /Deposit percentage/);
  bad((s) => { s.billing.deposit.percent_bp = 10001; }, /Deposit percentage can't be over 100%/);
  bad((s) => { s.billing.deposit.forfeit_notice_days = 91; }, /Deposit notice must be 0–90/);
  bad((s) => { s.billing.late_fee.type = "percent"; s.billing.late_fee.percent_bp = 0; }, /Late fee percentage must be between 0\.01% and 100%/);
  bad((s) => { s.billing.late_fee.after_days = 366; }, /grace period must be 0–365/);
  bad((s) => { s.billing.deposit.mode = "tax_it"; }, /Deposit: pick an option/);
  bad((s) => { s.tutor_pay.rate_model = "per_minute"; }, /Pay rate: pick an option/);
  for (const mut of [(s) => { s.billing.deposit.mode = "percent_first_month"; s.billing.deposit.percent_bp = 5000; },
    (s) => { s.billing.deposit.mode = "percent_first_month"; s.billing.deposit.percent_bp = 1; },
    (s) => { s.billing.deposit.mode = "percent_first_month"; s.billing.deposit.percent_bp = 10000; },
    (s) => { s.billing.late_fee.type = "percent"; s.billing.late_fee.percent_bp = 500; s.billing.late_fee.after_days = 365; },
    (s) => { s.tutor_pay.rate_model = "percent_of_fee"; }]) { const s = ok(); mut(s); assert.deepEqual(S.validate(s), []); }
});

test("T4 S0: 1-to-1 centres don't see group-only options; group and both centres do", () => {
  const f = field("tutor_pay.group_count"), rm = field("tutor_pay.rate_model");
  const s = S.defaults("centre");
  for (const ct of ["both", "group"]) { s.lessons.class_type = ct; assert.equal(S.isVisible(f, s), true, ct); assert.ok(S.visibleOptions(rm, s).some((o) => o[0] === "per_student_lesson"), ct); }
  s.lessons.class_type = "one_to_one";
  assert.equal(S.isVisible(f, s), false);
  assert.ok(!S.visibleOptions(rm, s).some((o) => o[0] === "per_student_lesson"));
  assert.ok(S.visibleOptions(rm, s).some((o) => o[0] === "percent_of_fee"));
  s.tutor_pay.rate_model = "per_student_lesson";                                 // an already-saved choice is never hidden from its owner
  assert.ok(S.visibleOptions(rm, s).some((o) => o[0] === "per_student_lesson"));
  // fields that are not group-only are unaffected
  assert.equal(S.isVisible(field("billing.deposit.mode"), s), true);
});

test("T4 S0: settings saved before these options still load and validate (new keys come from the defaults)", () => {
  const stored = { schema_version: 1, preset: "centre", profile: { trading_name: "Old Centre", invoice_prefix: "OC", next_invoice_number: 41 },
    billing: { model: "prepaid_packages", late_fee: { enabled: true, amount_cents: 1500, after_days: 10 }, one_off_fees: { deposit_cents: 20000 } },
    tutor_pay: { mode: "full", rate_model: "per_student_lesson" }, payments: { modes: ["manual_paynow"] } };
  const s = S.withDefaults(stored);
  assert.equal(s.billing.late_fee.enabled, true); assert.equal(s.billing.late_fee.amount_cents, 1500); assert.equal(s.billing.late_fee.after_days, 10);
  assert.equal(s.billing.one_off_fees.deposit_cents, 20000); assert.equal(s.profile.next_invoice_number, 41);
  assert.equal(s.billing.late_fee.repeat, "once"); assert.equal(s.billing.deposit.mode, "none"); assert.equal(s.lessons.class_type, "both");
  assert.deepEqual(S.validate(s), []);
});

test("T4 S0: billing and pay changes (including the new options) start next cycle; class type applies today", () => {
  const a = S.defaults(); a.profile.trading_name = "X";
  const b = JSON.parse(JSON.stringify(a)); b.billing.deposit.mode = "fixed";
  assert.equal(S.effectiveFrom(a, b, "2026-11-26"), "2026-12-01");
  const c = JSON.parse(JSON.stringify(a)); c.lessons.class_type = "one_to_one";
  assert.equal(S.effectiveFrom(a, c, "2026-11-26"), "2026-11-26");
});

// ---------------------------------------------------------------------------------------------------- T4 S7b: tutors see their own pay
const OWNPAY = fs.readFileSync(require.resolve("../db/migration_tutor_own_pay.sql"), "utf8");
test("T4 S7b: tutor_pay.tutors_see_own_pay has the same three values in the form and in db/migration_tutor_own_pay.sql, and defaults to each lesson and total", () => {
  const m = OWNPAY.match(/\{tutor_pay,tutors_see_own_pay\}' not in \(([^)]*)\)/);
  assert.ok(m, "checked in the migration");
  const sql = m[1].match(/'([a-z_]+)'/g).map((x) => x.slice(1, -1)).sort();
  assert.deepEqual(field("tutor_pay.tutors_see_own_pay").options.map((o) => o[0]).sort(), sql);
  assert.deepEqual(sql, ["monthly_total", "off", "per_lesson_and_total"]);
  assert.equal(S.get(S.defaults("centre"), "tutor_pay.tutors_see_own_pay"), "per_lesson_and_total", "owner's default");
  assert.equal(field("tutor_pay.tutors_see_own_pay").soon, undefined, "built, not 'soon'");
  assert.ok(!(field("tutor_pay.tutors_see_own_pay").soonOptions || []).length);
  assert.equal(S.get(S.defaults("centre"), "tutor_pay.tutor_visibility"), undefined, "the old 'soon' tutor_visibility choice is gone");
  assert.ok(!S.STEPS.flatMap((s) => s.fields).some((f) => f.path === "tutor_pay.tutor_visibility"));
});
test("T4 S7b: the choice is only offered when pay is worked out in full, and saves cleanly", () => {
  const f = field("tutor_pay.tutors_see_own_pay"), s = S.defaults("centre"); s.profile.trading_name = "X";
  s.tutor_pay.mode = "report"; assert.equal(f.show(s), false);
  s.tutor_pay.mode = "off"; assert.equal(f.show(s), false);
  s.tutor_pay.mode = "full"; assert.equal(f.show(s), true);
  for (const v of ["off", "monthly_total", "per_lesson_and_total"]) { s.tutor_pay.tutors_see_own_pay = v; assert.deepEqual(S.validate(s), [], v); }
  assert.ok(/never the family's fee/.test(f.help) && /pending/.test(f.help), "the help says what a tutor never sees");
});
test("T4 S7b: changing who sees their own pay takes effect today (a process rule), other pay changes still wait for the next cycle", () => {
  const a = S.defaults("centre"); a.profile.trading_name = "X";
  const b = JSON.parse(JSON.stringify(a)); b.tutor_pay.tutors_see_own_pay = "off";
  assert.equal(S.effectiveFrom(a, b, "2026-11-26"), "2026-11-26");
  const c = JSON.parse(JSON.stringify(a)); c.tutor_pay.payable_when = "taught";
  assert.equal(S.effectiveFrom(a, c, "2026-11-26"), "2026-12-01");
  const d = JSON.parse(JSON.stringify(b)); d.tutor_pay.payable_when = "taught";
  assert.equal(S.effectiveFrom(a, d, "2026-11-26"), "2026-12-01", "both changed: the money change still waits");
});
