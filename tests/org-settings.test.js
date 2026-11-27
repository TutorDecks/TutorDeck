// node --test tests/   — settings schema: defaults are valid, matches the database's checks, edge cases.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const S = require("../assets/js/org-settings.js");
const SQL = fs.readFileSync(require.resolve("../db/migration_org_foundation.sql"), "utf8");
const MONEY = fs.readFileSync(require.resolve("../db/migration_money_settings.sql"), "utf8");   // T4 S0: the replacement validator
const field = (path) => S.STEPS.flatMap((s) => s.fields).find((f) => f.path === path);
const MOVES = fs.readFileSync(require.resolve("../db/migration_tutor_moves.sql"), "utf8");   // T6 step 2: the validator that knows the tutor-editing options
const PAYOUT_SQL = fs.readFileSync(require.resolve("../db/migration_payout_permission.sql"), "utf8");

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

test("staff permissions agree with org_invite() and org_update_member() in the latest migration", () => {
  // the catalogue is checked in two places in db/migration_payout_permission.sql (invite and update); both must equal the JS list
  const lists = [...PAYOUT_SQL.matchAll(/where x not in \(([^)]*)\)/g)].map((m) => m[1].match(/'([a-z_]+)'/g).map((x) => x.slice(1, -1)).sort());
  assert.equal(lists.length, 2);
  const js = S.STAFF_PERMISSIONS.map((p) => p.key).sort();
  for (const l of lists) assert.deepEqual(js, l);
  // the first migration's list is the older catalogue: every name in it is still valid
  const old = SQL.match(/where x not in \(([^)]*)\)/)[1].match(/'([a-z_]+)'/g).map((x) => x.slice(1, -1));
  for (const k of old) assert.ok(js.includes(k), k + " must stay valid");
  assert.ok(js.includes("view_payout_details"));
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
  // built in T3 step 7: staff_generate_lessons skips whole-centre holidays when this is on (SQL tests: staff_slots_test.sql), so it is no longer "soon"
  assert.ok(!fields["calendar.skip_holidays"].soon);
  assert.match(fields["calendar.skip_holidays"].help, /Create lessons/);
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
    "billing.deposit.set_off_unpaid", "billing.deposit.final_month",
    "tutor_pay.percent_base", "tutor_pay.part_payments", "tutor_pay.cancelled_lessons", "tutor_pay.group_count", "tutor_pay.rates_note"];
  for (const p of soonPaths) assert.equal(field(p).soon, true, p + " must be soon");
  assert.ok(field("tutor_pay.rate_model").soonOptions.includes("percent_of_fee"));
  assert.ok(field("billing.deposit.due").soonOptions.includes("before_first_lesson"));
  assert.ok(field("tutor_pay.part_payments").soonOptions.includes("pro_rata"));
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

// ---------------------------------------------------------------------------------------------------- T3.9: assigned tutors follow a weekly slot
test("T3.9: 'a weekly slot adds its tutor to the student' is a setting: default on, built (not soon), and a yes/no the database reads as of today", () => {
  const fields = {};
  S.STEPS.forEach((st) => st.fields.forEach((f) => { fields[f.path] = f; }));
  const f = fields["lessons.auto_assign_tutors"];
  assert.ok(f, "the field exists in the wizard");
  assert.equal(f.type, "toggle", "a yes/no (no enum: the SQL treats a missing or non-boolean value as on)");
  assert.ok(!f.soon, "it is built (db/migration_slot_changes.sql, tests/sql/slot_changes_test.sql), so it is not marked soon");
  assert.match(f.help, /nobody is taken off/i);
  assert.strictEqual(S.defaults("centre").lessons.auto_assign_tutors, true, "default on");
  assert.strictEqual(S.defaults("solo").lessons.auto_assign_tutors, true);
  const s = S.defaults("centre"); s.profile.trading_name = "T"; s.lessons.auto_assign_tutors = false;
  assert.deepEqual(S.validate(s), [], "off is valid");
  // an older saved document without the key is still valid (the SQL reads a missing key as on)
  const old = S.defaults("centre"); old.profile.trading_name = "T"; delete old.lessons.auto_assign_tutors;
  assert.deepEqual(S.validate(old), []);
});

// ---- T6 step 2: tutors change their own lessons (db/migration_tutor_moves.sql)
test("T6.2: 'who edits the timetable' has the same values in the form and in the database; the old tutors_own is gone", () => {
  const sqlVals = (re) => MOVES.match(re)[1].match(/'([a-z_]+)'/g).map((x) => x.slice(1, -1)).sort();
  const f = field("lessons.timetable_editing");
  assert.deepEqual(f.options.map((x) => x[0]).sort(), sqlVals(/\{lessons,timetable_editing\}' not in \(([^)]*)\)/));
  assert.deepEqual(f.options.map((x) => x[0]).sort(), ["admin_only", "tutors_direct", "tutors_propose"]);
  assert.ok(!f.options.some((x) => x[0] === "tutors_own"), "tutors_own is renamed");
  assert.deepEqual(f.soonOptions, ["tutors_propose"], "only asking-for-approval is still coming soon");
  assert.equal(S.get(S.defaults("centre"), "lessons.timetable_editing"), "admin_only");
  assert.equal(S.get(S.defaults("solo"), "lessons.timetable_editing"), "admin_only");
});

test("T6.2: notify_family has the same values in the form and in the database, default list_for_admin", () => {
  const sql = MOVES.match(/\{lessons,notify_family\}' not in \(([^)]*)\)/)[1].match(/'([a-z_]+)'/g).map((x) => x.slice(1, -1)).sort();
  assert.deepEqual(field("lessons.notify_family").options.map((x) => x[0]).sort(), sql);
  assert.equal(S.get(S.defaults(), "lessons.notify_family"), "list_for_admin");
  assert.ok(!field("lessons.notify_family").soon && !(field("lessons.notify_family").soonOptions || []).length, "the in-app list is built, so nothing here is marked soon");
});

test("T6.2: the six switches: postpone and cancel are built, the other four are coming soon; every switch is a yes/no in the database", () => {
  const sw = ["postpone", "cancel", "weekly_slots", "generate", "one_off", "link"];
  for (const k of sw) {
    assert.ok(MOVES.includes("'{lessons,tutors_edit," + k + "}'"), k + " is validated in the migration");
    assert.equal(typeof S.get(S.defaults(), "lessons.tutors_edit." + k), "boolean", k);
  }
  for (const k of ["postpone", "cancel"]) assert.ok(!field("lessons.tutors_edit." + k).soon, k + " is built");
  for (const k of ["weekly_slots", "generate", "one_off", "link"]) assert.equal(field("lessons.tutors_edit." + k).soon, true, k + " must be soon");
  // the defaults the form starts from are the ones the database assumes for a missing key (postpone on, cancel off)
  assert.equal(S.get(S.defaults(), "lessons.tutors_edit.postpone"), true);
  assert.equal(S.get(S.defaults(), "lessons.tutors_edit.cancel"), false);
  assert.match(MOVES, /tutors_edit,postpone\}'\)::boolean, true\)/);
  assert.match(MOVES, /tutors_edit,cancel\}'\)::boolean, false\)/);
});

test("T6.2: the limits are the same in the form and in the database, and the defaults are the owner's (24 hours, no limit)", () => {
  for (const [path, key, lo, hi] of [["lessons.min_notice_hours", "min_notice_hours", 0, 168], ["lessons.max_changes_per_month", "max_changes_per_month", 0, 500]]) {
    const m = MOVES.match(new RegExp("\\('\\{lessons," + key + "\\}', (\\d+), (\\d+),"));
    assert.ok(m, path + " is checked in the migration");
    assert.deepEqual([+m[1], +m[2]], [lo, hi], path);
  }
  assert.equal(S.get(S.defaults(), "lessons.min_notice_hours"), 24);
  assert.equal(S.get(S.defaults(), "lessons.max_changes_per_month"), 0);
  assert.match(MOVES, /min_notice_hours\}'\)::int, 24\)/);
  assert.match(MOVES, /max_changes_per_month\}'\)::int, 0\)/);
  const ok = () => { const s = S.defaults(); s.profile.trading_name = "T"; return s; };
  for (const [k, v, want] of [["min_notice_hours", 169, /Notice before a tutor/], ["min_notice_hours", -1, /Notice before a tutor|whole number/], ["min_notice_hours", 1.5, /Notice before a tutor|whole number/],
    ["max_changes_per_month", 501, /Changes per tutor per month/], ["max_changes_per_month", -2, /Changes per tutor per month|whole number/]]) {
    const s = ok(); s.lessons[k] = v; assert.match(S.validate(s).join(" | "), want, k + "=" + v);
  }
  for (const [k, v] of [["min_notice_hours", 0], ["min_notice_hours", 168], ["max_changes_per_month", 0], ["max_changes_per_month", 500]]) {
    const s = ok(); s.lessons[k] = v; assert.deepEqual(S.validate(s), [], k + "=" + v);
  }
});

test("T6.2: the switches and limits show only when tutors may change lessons; settings saved before this load with the defaults", () => {
  const s = S.defaults("centre");
  const paths = ["lessons.tutors_edit.postpone", "lessons.tutors_edit.cancel", "lessons.tutors_edit.weekly_slots", "lessons.min_notice_hours", "lessons.max_changes_per_month", "lessons.notify_family"];
  for (const p of paths) assert.equal(S.isVisible(field(p), s), false, p + " hidden while admin_only");
  s.lessons.timetable_editing = "tutors_direct";
  for (const p of paths) assert.equal(S.isVisible(field(p), s), true, p + " shown for tutors_direct");
  const old = S.withDefaults({ schema_version: 1, preset: "centre", profile: { trading_name: "Old" }, lessons: { attendance_by: "admin" } });
  assert.equal(old.lessons.timetable_editing, "admin_only"); assert.equal(old.lessons.min_notice_hours, 24); assert.equal(old.lessons.tutors_edit.postpone, true);
  assert.deepEqual(S.validate(old), []);
  assert.equal(S.effectiveFrom(S.defaults(), Object.assign(S.defaults(), { lessons: Object.assign({}, S.defaults().lessons, { timetable_editing: "tutors_direct" }) }), "2026-11-26"), "2026-11-26", "a process rule applies today");
});

// ---------------------------------------------------------------- family emails (T7.3)
const EMAIL_SQL = fs.readFileSync(require.resolve("../db/migration_invoice_email.sql"), "utf8");
test("email options: every value of every option is in the wizard and in the database validator", () => {
  const f = (p) => field(p);
  assert.deepEqual(f("email.mode").options.map((o) => o[0]).sort(), ["auto_on_issue", "off", "staff_send"]);
  assert.match(EMAIL_SQL, /s#>>'\{email,mode\}' not in \('off','staff_send','auto_on_issue'\)/);
  for (const p of ["email.receipts", "email.late_fee_notice", "email.reminders.enabled"]) assert.equal(f(p).type, "toggle", p);
  for (const p of ["email.reminders.first_after_days", "email.reminders.repeat_days", "email.reminders.max_count", "email.daily_cap", "email.per_hour"]) assert.ok(f(p), p);
  for (const k of ["invoice", "receipt", "reminder", "late_fee"]) { assert.equal(f("email.templates." + k + ".subject").type, "text"); assert.equal(f("email.templates." + k + ".body").type, "textarea"); }
  assert.ok(!f("invoicing.delivery.email") && !f("invoicing.reminders.enabled"), "the old 'coming soon' placeholders are gone");
  for (const p of ["email.mode", "email.receipts", "email.reminders.enabled", "email.daily_cap", "email.templates.invoice.body"]) assert.ok(!f(p).soon, p + " is built, so it is not marked soon");
});
test("email options: defaults are OFF, valid, and the other options are hidden until email is switched on", () => {
  const s = S.defaults("centre"); s.profile.trading_name = "X";
  assert.equal(s.email.mode, "off"); assert.deepEqual(S.validate(s), []);
  assert.ok(!S.isVisible(field("email.receipts"), s) && !S.isVisible(field("email.daily_cap"), s) && S.isVisible(field("email.mode"), s));
  s.email.mode = "staff_send";
  assert.ok(S.isVisible(field("email.receipts"), s) && S.isVisible(field("email.daily_cap"), s) && !S.isVisible(field("email.reminders.first_after_days"), s));
  s.email.reminders.enabled = true;
  assert.ok(S.isVisible(field("email.reminders.first_after_days"), s) && S.isVisible(field("email.reminders.max_count"), s));
  for (const mode of ["off", "staff_send", "auto_on_issue"]) { const t = S.defaults("centre"); t.profile.trading_name = "X"; t.email.mode = mode; assert.deepEqual(S.validate(t), [], mode); }
});
test("email options: the same ranges as the database (both edges), wording rules, and the link requirement", () => {
  const bad = (mutate) => { const s = S.defaults("centre"); s.profile.trading_name = "X"; s.email.mode = "staff_send"; mutate(s); return S.validate(s).join(" | "); };
  for (const [path, lo, hi] of [["first_after_days", 1, 90], ["repeat_days", 0, 90], ["max_count", 1, 10]]) {
    assert.equal(bad((s) => { s.email.reminders[path] = lo; }), "", path + " low edge"); assert.equal(bad((s) => { s.email.reminders[path] = hi; }), "", path + " high edge");
    assert.notEqual(bad((s) => { s.email.reminders[path] = lo - 1; }), "", path + " below"); assert.notEqual(bad((s) => { s.email.reminders[path] = hi + 1; }), "", path + " above");
  }
  for (const p of ["daily_cap", "per_hour"]) { assert.equal(bad((s) => { s.email[p] = 1; }), ""); assert.equal(bad((s) => { s.email[p] = 300; }), ""); assert.notEqual(bad((s) => { s.email[p] = 0; }), ""); assert.notEqual(bad((s) => { s.email[p] = 301; }), ""); }
  assert.match(bad((s) => { s.email.mode = "sometimes"; }), /pick an option/);
  assert.match(bad((s) => { s.email.receipts = "yes"; }), /yes or no/);
  assert.match(bad((s) => { s.email.templates.invoice.body = "Hi {nam}"; }), /can only use/);
  assert.match(bad((s) => { s.email.templates.receipt.subject = "x".repeat(121); }), /too long/);
  assert.equal(bad((s) => { s.email.templates.receipt.subject = "x".repeat(120); s.email.templates.reminder.body = "y".repeat(1000); }), "");
  assert.match(bad((s) => { s.invoicing.delivery.share_link = false; }), /needs the shareable invoice link/);
  const off = S.defaults("centre"); off.profile.trading_name = "X"; off.invoicing.delivery.share_link = false; assert.deepEqual(S.validate(off), [], "with email off the link may be off");
  // the database repeats every one of these
  for (const [p, lo, hi] of [["{email,reminders,first_after_days}", 1, 90], ["{email,reminders,repeat_days}", 0, 90], ["{email,reminders,max_count}", 1, 10], ["{email,daily_cap}", 1, 300], ["{email,per_hour}", 1, 300]])
    assert.ok(EMAIL_SQL.includes("('" + p + "', " + lo + ", " + hi + ","), p);
});
test("email options: they apply today (not from the next billing cycle) and old stored settings gain them", () => {
  const a = S.defaults("centre"); a.profile.trading_name = "X"; const b = JSON.parse(JSON.stringify(a)); b.email.mode = "auto_on_issue"; b.email.reminders.enabled = true;
  assert.equal(S.effectiveFrom(a, b, "2026-11-23"), "2026-11-23");
  const old = S.withDefaults({ schema_version: 1, preset: "centre", profile: { trading_name: "Old" }, invoicing: { grouping: "family", delivery: { email: false, share_link: true }, reminders: { enabled: false, schedule: [-3, 0, 7] } } });
  assert.equal(old.email.mode, "off"); assert.equal(old.email.daily_cap, 200); assert.deepEqual(S.validate(old), []);
});
