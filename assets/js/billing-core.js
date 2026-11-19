// Centre billing core — the catalogue + maths shared by the browser (centre.js) and, later, the server.
// No DOM, no Supabase. The database (db/migration_centres.sql) is the authority; these functions mirror
// td_pay_amount / td_gst exactly so previews match what gets billed (tests/billing-core.test.js checks the
// same cases as tests/sql/centres_test.sql).
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.BillingCore = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  // ---- permissions (keep in sync with the catalogue comment in db/migration_centres.sql) ----
  var PERMISSIONS = [
    { group: "Students",  key: "students.view",      label: "See students & families" },
    { group: "Students",  key: "students.edit",      label: "Add / edit students & families" },
    { group: "Schedule",  key: "classes.edit",       label: "Manage classes & lessons" },
    { group: "Schedule",  key: "schedule.view_all",  label: "See every tutor's schedule" },
    { group: "Schedule",  key: "lessons.deliver",    label: "Mark lessons delivered (bills them)" },
    { group: "Schedule",  key: "lessons.remarks",    label: "Write remarks on own lessons" },
    { group: "Billing",   key: "billing.view",       label: "See invoices & payments" },
    { group: "Billing",   key: "billing.edit",       label: "Billing rules, packages, invoice runs" },
    { group: "Billing",   key: "payments.record",    label: "Record a payment" },
    { group: "Billing",   key: "payments.reconcile", label: "Reconcile, refund, disputes" },
    { group: "Payouts",   key: "payouts.view",       label: "See all tutor earnings" },
    { group: "Payouts",   key: "payouts.view_own",   label: "See own earnings" },
    { group: "Payouts",   key: "payouts.manage",     label: "Create & pay payout batches" },
    { group: "Payouts",   key: "payouts.override",   label: "Override the payout rule (audited)" },
    { group: "Admin",     key: "settings.edit",      label: "Centre settings" },
    { group: "Admin",     key: "roles.manage",       label: "Team & roles" },
    { group: "Admin",     key: "audit.view",         label: "See the audit log" }
  ];

  var PAY_BASES = [
    { key: "per_hour",         label: "Per hour",              unit: "$ / hour" },
    { key: "per_lesson",       label: "Per lesson",            unit: "$ / lesson" },
    { key: "per_student",      label: "Per student",           unit: "$ / student / lesson" },
    { key: "per_student_hour", label: "Per student per hour",  unit: "$ / student / hour" },
    { key: "percent_of_fee",   label: "% of the lesson fee",   unit: "% of fee (before GST)" }
  ];

  // Every key a billing policy understands. Missing keys fall back to these.
  var DEFAULT_POLICY = {
    cycle: "monthly",            // monthly | per_lesson | term   (postpay / hybrid)
    due_days: 7,
    no_balance: "charge",        // prepay with no package left: "charge" as postpay, or "block"
    packages: [],                // [{ lessons, price, expiry_days }]   (prepay)
    deposit: { amount: 0, refundable: true },                             // hybrid
    cancellation: { notice_hours: 24, late_charge_pct: 100, no_show_charge_pct: 100,
                    pay_tutor_late_cancel: false, makeup_allowed: true, makeup_window_days: 30, max_makeups_per_term: 2 },
    sibling_discount: { type: "percent", value: 0 },                      // 2nd child onwards
    late_fee: { type: "fixed", value: 0, after_days: 7, max_times: 1 },
    unused: { action: "forfeit", extend_days: 30, max_extensions: 1 }    // forfeit | carry_forward | credit | refund
  };

  function num(x) { var n = Number(x); return isFinite(n) ? n : 0; }
  // Postgres round(numeric, 2): half away from zero, on the decimal value (avoid 1.005 → 1.00).
  function round2(x) {
    var n = num(x), s = n < 0 ? -1 : 1, a = Math.abs(n);
    return s * Math.round(Number((a * 100).toPrecision(15))) / 100;
  }

  // Mirror of td_gst(amount, rate, inclusive, registered) → { net, gst, total }
  function gst(amount, rate, inclusive, registered) {
    rate = num(rate);
    if (!registered || rate === 0) { var n = round2(amount); return { net: n, gst: 0, total: n }; }
    if (inclusive) { var t = round2(amount), g = round2(num(amount) * rate / (100 + rate)); return { net: round2(t - g), gst: g, total: t }; }
    var net = round2(amount), g2 = round2(num(amount) * rate / 100);
    return { net: net, gst: g2, total: round2(net + g2) };
  }

  // Mirror of td_pay_amount(basis, rate, minutes, heads, fee, min, max)
  function payAmount(basis, rate, minutes, heads, fee, min, max) {
    rate = num(rate); minutes = num(minutes); heads = num(heads); fee = num(fee);
    var v = basis === "per_hour" ? rate * minutes / 60
      : basis === "per_lesson" ? rate
      : basis === "per_student" ? rate * heads
      : basis === "per_student_hour" ? rate * heads * minutes / 60
      : basis === "percent_of_fee" ? fee * rate / 100 : 0;
    if (heads === 0) v = 0;
    if (min != null && min !== "" && v < num(min) && heads > 0) v = num(min);
    if (max != null && max !== "" && v > num(max)) v = num(max);
    return round2(v);
  }

  // Mirror of td_sibling_discount for one child at rank (1 = eldest/first enrolled).
  function siblingDiscount(fee, rank, cfg) {
    var d = cfg && cfg.sibling_discount;
    if (!d || !num(d.value) || rank < 2) return 0;
    return Math.min(num(fee), round2(d.type === "fixed" ? num(d.value) : num(fee) * num(d.value) / 100));
  }

  // Most specific rule wins (tutor 8, class 4, subject 2, level 1); ties → newest.
  function pickPayRule(rules, ctx) {
    var best = null, bestScore = -1;
    (rules || []).forEach(function (r) {
      function eq(a, b) { return String(a || "").toLowerCase() === String(b || "").toLowerCase(); }
      if (r.tutor_member_id && r.tutor_member_id !== ctx.tutor) return;
      if (r.class_id && r.class_id !== ctx.classId) return;
      if (r.subject && !eq(r.subject, ctx.subject)) return;
      if (r.level && !eq(r.level, ctx.level)) return;
      var sc = (r.tutor_member_id ? 8 : 0) + (r.class_id ? 4 : 0) + (r.subject ? 2 : 0) + (r.level ? 1 : 0);
      if (sc > bestScore || (sc === bestScore && String(r.created_at || "") > String(best.created_at || ""))) { best = r; bestScore = sc; }
    });
    return best;
  }

  // Fill any missing keys from DEFAULT_POLICY (one level deep for the nested blocks).
  function withDefaults(cfg) {
    cfg = cfg || {};
    var out = {};
    Object.keys(DEFAULT_POLICY).forEach(function (k) {
      var d = DEFAULT_POLICY[k], v = cfg[k];
      if (d && typeof d === "object" && !Array.isArray(d)) out[k] = Object.assign({}, d, v || {});
      else out[k] = v === undefined ? (Array.isArray(d) ? d.slice() : d) : v;
    });
    Object.keys(cfg).forEach(function (k) { if (!(k in out)) out[k] = cfg[k]; });
    return out;
  }

  // Problems that would make a policy bill wrongly. [] = fine.
  function validatePolicy(model, cfg) {
    var e = [], c = withDefaults(cfg);
    if (["prepay", "postpay", "hybrid"].indexOf(model) < 0) e.push("Pick prepay, postpay or hybrid.");
    if (!(num(c.due_days) >= 0 && num(c.due_days) <= 120)) e.push("Due days must be 0–120.");
    if (model === "prepay" && !(c.packages || []).length) e.push("Prepay needs at least one package.");
    (c.packages || []).forEach(function (p, i) {
      if (!(num(p.lessons) > 0)) e.push("Package " + (i + 1) + ": lessons must be more than 0.");
      if (!(num(p.price) > 0)) e.push("Package " + (i + 1) + ": price must be more than 0.");
    });
    if (model === "hybrid" && !(num(c.deposit.amount) > 0)) e.push("Hybrid needs a deposit amount.");
    ["late_charge_pct", "no_show_charge_pct"].forEach(function (k) {
      var v = num(c.cancellation[k]); if (v < 0 || v > 100) e.push("Cancellation charge must be 0–100%.");
    });
    if (c.sibling_discount.type === "percent" && (num(c.sibling_discount.value) < 0 || num(c.sibling_discount.value) > 100))
      e.push("Sibling discount must be 0–100%.");
    if (["forfeit", "carry_forward", "credit", "refund"].indexOf(c.unused.action) < 0) e.push("Pick what happens to unused lessons.");
    return e;
  }

  // One-line, parent-readable summary of a policy.
  function describePolicy(model, cfg) {
    var c = withDefaults(cfg), bits = [];
    if (model === "prepay") {
      bits.push("Pay upfront for packages" + ((c.packages || []).length ? " (" + c.packages.map(function (p) { return num(p.lessons) + " lessons $" + num(p.price); }).join(", ") + ")" : ""));
    } else {
      bits.push(model === "hybrid" ? "$" + num(c.deposit.amount) + " deposit, then billed " + cycleWord(c.cycle) : "Billed " + cycleWord(c.cycle) + " after lessons");
    }
    bits.push("due in " + num(c.due_days) + " days");
    if (num(c.sibling_discount.value)) bits.push((c.sibling_discount.type === "fixed" ? "$" + num(c.sibling_discount.value) : num(c.sibling_discount.value) + "%") + " off for siblings");
    if (num(c.late_fee.value)) bits.push("late fee " + (c.late_fee.type === "percent" ? num(c.late_fee.value) + "%" : "$" + num(c.late_fee.value)) + " after " + num(c.late_fee.after_days) + " days overdue");
    return bits.join(" · ");
  }
  function cycleWord(c) { return c === "per_lesson" ? "per lesson" : c === "term" ? "per term" : "monthly"; }

  // Invoice template → filled text for previews. {placeholders} like the WhatsApp templates.
  function fillTemplate(text, vars) {
    return String(text || "").replace(/\{(\w+)\}/g, function (m, k) { return vars && vars[k] != null ? String(vars[k]) : m; });
  }

  return { PERMISSIONS: PERMISSIONS, PAY_BASES: PAY_BASES, DEFAULT_POLICY: DEFAULT_POLICY,
    round2: round2, gst: gst, payAmount: payAmount, siblingDiscount: siblingDiscount, pickPayRule: pickPayRule,
    withDefaults: withDefaults, validatePolicy: validatePolicy, describePolicy: describePolicy, fillTemplate: fillTemplate };
});
