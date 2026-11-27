// B5-FIX B, C, D: saved values are read back into the form for EVERY setting key; 0 is saved for every numeric setting that allows it;
// mode-dependent fields show only when they apply; and billing-type changes still wait for the next cycle without holding back the rest.
const test = require("node:test"), assert = require("node:assert/strict");
const S = require("../assets/js/org-settings.js");
const fields = [];
S.STEPS.forEach((st) => st.fields.forEach((f) => { if (f.path) fields.push(f); }));
const clone = (x) => JSON.parse(JSON.stringify(x));

// a value that differs from the default and is valid for the field
function other(f, cur) {
  if (f.type === "toggle") return !cur;
  if (f.type === "select") { const all = f.options.map((o) => o[0]); return all.find((v) => v !== cur) ; }
  if (f.type === "multi") { const all = f.options.map((o) => o[0]); return all.filter((v) => (cur || []).indexOf(v) < 0).slice(0, 1).concat(cur || []); }
  if (f.type === "money" || f.type === "number" || f.type === "days" || f.type === "percent") return (typeof cur === "number" ? cur : 0) + 7;
  if (f.type === "list") return [3, 4];
  if (f.type === "color") return "#123456";
  if (f.type === "email") return "a@b.test";
  return "changed " + f.path;
}

test("B: every setting key saved with a non-default value is read back into the form", () => {
  const base = S.defaults("centre"); let n = 0;
  fields.forEach((f) => {
    const stored = clone(base), v = other(f, S.get(base, f.path));
    if (v === undefined) return;                                         // a select with a single option has nothing else to save
    S.set(stored, f.path, v);
    const form = S.withDefaults(JSON.parse(JSON.stringify(stored)), "centre");      // what the page does after loading a saved version
    assert.deepEqual(S.get(form, f.path), v, f.path + " lost its saved value");
    n++;
  });
  assert.ok(n > 100, "checked " + n + " keys");
});

test("B: saved values also win over defaults for the keys that were added later", () => {
  const stored = S.defaults("centre"); stored.lessons.max_changes_per_month = 2; stored.billing.deposit.refund_approved_by = "owner";
  const form = S.withDefaults(stored, "centre");
  assert.equal(form.lessons.max_changes_per_month, 2); assert.equal(form.billing.deposit.refund_approved_by, "owner");
});

test("C: 0 (and every number the field allows) is valid and survives, for every numeric setting that allows 0", () => {
  const base = S.defaults("centre"); base.profile.trading_name = "T"; base.profile.invoice_prefix = "INV"; let n = 0;
  fields.filter((f) => ["money", "number", "days"].indexOf(f.type) > -1).forEach((f) => {
    const s = clone(base); S.set(s, f.path, 0);
    const form = S.withDefaults(clone(s), "centre");
    assert.strictEqual(S.get(form, f.path), 0, f.path + " must keep 0");
    const ONE_UP = ["profile.next_invoice_number", "tutor_pay.cycle.cutoff_day", "tutor_pay.cycle.pay_day", "invoicing.generate.day"];   // numbers that start at 1 on purpose (day of month, invoice number)
    const errs = ONE_UP.indexOf(f.path) > -1 ? [] : S.validate(s).filter((e) => e.indexOf(f.label) === 0);
    assert.deepEqual(errs, [], f.path + ": 0 refused: " + errs.join("|"));
    n++;
  });
  assert.ok(n >= 8, "numeric fields checked: " + n);
  // the specific one: "no limit" = 0 after a limit of 50
  const s = clone(base); s.lessons.max_changes_per_month = 50;
  const f = S.withDefaults(clone(s), "centre"); f.lessons.max_changes_per_month = 0;
  assert.equal(f.lessons.max_changes_per_month, 0); assert.deepEqual(S.validate(f).filter((e) => /Changes per tutor/.test(e)), []);
});

const find = (p) => fields.find((f) => f.path === p);
test("D: late fee shows only the field that applies, and nothing when late fees are off", () => {
  const s = S.defaults("centre"); s.billing.late_fee.enabled = true;
  s.billing.late_fee.type = "fixed";
  assert.ok(S.isVisible(find("billing.late_fee.amount_cents"), s)); assert.ok(!S.isVisible(find("billing.late_fee.percent_bp"), s));
  s.billing.late_fee.type = "percent";
  assert.ok(!S.isVisible(find("billing.late_fee.amount_cents"), s)); assert.ok(S.isVisible(find("billing.late_fee.percent_bp"), s));
  s.billing.late_fee.enabled = false;
  ["type", "amount_cents", "percent_bp", "repeat", "after_days", "cap_cents", "show_as", "waived_by"].forEach((k) => assert.ok(!S.isVisible(find("billing.late_fee." + k), s), k + " hidden while off"));
  assert.ok(S.isVisible(find("billing.late_fee.enabled"), s));
});
test("D: deposit shows its amount or its percentage by mode, and its details only when there is a deposit", () => {
  const s = S.defaults("centre");
  s.billing.deposit.mode = "fixed";
  assert.ok(S.isVisible(find("billing.one_off_fees.deposit_cents"), s)); assert.ok(!S.isVisible(find("billing.deposit.percent_bp"), s));
  s.billing.deposit.mode = "percent_first_month";
  assert.ok(!S.isVisible(find("billing.one_off_fees.deposit_cents"), s)); assert.ok(S.isVisible(find("billing.deposit.percent_bp"), s));
  ["taxable", "due", "waived_by", "release", "forfeit_notice_days"].forEach((k) => assert.ok(S.isVisible(find("billing.deposit." + k), s), k));
  s.billing.deposit.mode = "none";
  ["taxable", "due", "waived_by", "release", "forfeit_notice_days"].forEach((k) => assert.ok(!S.isVisible(find("billing.deposit." + k), s), k + " hidden with no deposit"));
  assert.ok(S.isVisible(find("billing.deposit.refund_approved_by"), s), "refund approval also covers family credit");
});

test("savePlan: a pending next-cycle version no longer hides or reverts a change saved today", () => {
  const today = "2026-11-27", inForce = S.defaults("centre"); inForce.lessons.max_changes_per_month = 50;
  const latest = clone(inForce); latest.billing.deposit.refund_approved_by = "four_eyes";            // pending, starts 1 Dec
  const draft = clone(latest); draft.lessons.max_changes_per_month = 0;                                // owner types 0 = no limit
  const plan = S.savePlan(latest, inForce, draft, today, false);
  assert.equal(plan.length, 2);
  assert.equal(plan[0].effective, today); assert.equal(plan[0].settings.lessons.max_changes_per_month, 0);
  assert.equal(plan[0].settings.billing.deposit.refund_approved_by, inForce.billing.deposit.refund_approved_by, "billing waits for the cycle");
  assert.equal(plan[1].effective, "2026-12-01"); assert.equal(plan[1].settings.billing.deposit.refund_approved_by, "four_eyes"); assert.equal(plan[1].settings.lessons.max_changes_per_month, 0);
});
test("savePlan: only non-billing changes = today; only billing = next cycle; nothing changed = nothing; setup = today", () => {
  const today = "2026-12-20", base = S.defaults("centre");
  const a = clone(base); a.lessons.max_changes_per_month = 3; assert.deepEqual(S.savePlan(base, base, a, today, false).map((p) => p.effective), [today]);
  const b = clone(base); b.billing.late_fee.enabled = !b.billing.late_fee.enabled; assert.deepEqual(S.savePlan(base, base, b, today, false).map((p) => p.effective), ["2027-01-01"]);
  assert.deepEqual(S.savePlan(base, base, clone(base), today, false), []);
  assert.deepEqual(S.savePlan(base, base, b, today, true).map((p) => p.effective), [today]);
});
