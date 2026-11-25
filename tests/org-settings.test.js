// node --test tests/   — settings schema: defaults are valid, matches the database's checks, edge cases.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const S = require("../assets/js/org-settings.js");
const SQL = fs.readFileSync(require.resolve("../db/migration_org_foundation.sql"), "utf8");
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
  for (const st of S.STEPS) for (const f of st.fields) if (f.type !== "note") assert.notEqual(S.get(S.defaults(), f.path), undefined, f.path + " has a default");
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
  for (const want of [/GST registration/, /at least one way/, /1–28/, /Default billing model/, /Deposit must be a whole number/]) assert.match(e, want);
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
