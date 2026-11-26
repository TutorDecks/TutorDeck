// Money — every TutorDeck calculation, in integer cents. One module, used by the browser (previews,
// wizard step 10), later by Edge Functions (invoice runs), and by tests/money.test.js (worked examples).
// Rules: amounts are whole cents (Number.isSafeInteger); rates are basis points (9% GST = 900 bp);
// rounding is half-up (half away from zero for negatives), done once at the step the brief names.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.Money = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  function assertCents(c, what) {
    if (!Number.isSafeInteger(c)) throw new Error((what || "amount") + " must be whole cents, got " + c);
    return c;
  }

  // a / b rounded half away from zero, for integers (b > 0). No floating point.
  function divRound(a, b) {
    assertCents(a, "numerator"); assertCents(b, "denominator");
    if (b <= 0) throw new Error("denominator must be positive");
    var neg = a < 0, x = Math.abs(a), q = Math.floor(x / b), r = x - q * b;
    if (r * 2 >= b) q += 1;
    return neg ? -q : q;
  }

  // "1,234.5" / "S$12" / "-3.05" → cents, from the TEXT (never parseFloat * 100).
  function parse(text) {
    var s = String(text == null ? "" : text).replace(/S\$|\$|,|\s/g, "");
    var m = /^(-)?(\d*)(?:\.(\d{0,2}))?$/.exec(s);
    if (!m || (m[2] === "" && (m[3] == null || m[3] === ""))) return null;
    var c = Number(m[2] || "0") * 100 + Number(((m[3] || "") + "00").slice(0, 2));
    return m[1] ? -c : c;
  }

  function format(cents, opts) {
    assertCents(cents);
    var neg = cents < 0, a = Math.abs(cents), d = Math.floor(a / 100), c = a % 100;
    var s = String(d).replace(/\B(?=(\d{3})+(?!\d))/g, ",") + "." + (c < 10 ? "0" : "") + c;
    return (neg ? "-" : "") + ((opts && opts.symbol === false) ? "" : "S$") + s;
  }

  // percentage of an amount, rate in basis points (1% = 100 bp)
  function pct(cents, bp) { return divRound(assertCents(cents) * bp, 10000); }

  // GST once per invoice (owner's decision). Exclusive: GST added on top. Inclusive: GST is inside the total.
  function gstForInvoice(subtotalCents, rateBp, inclusive, registered) {
    assertCents(subtotalCents);
    if (!registered || !rateBp) return { net: subtotalCents, gst: 0, total: subtotalCents };
    if (inclusive) {
      var gst = divRound(subtotalCents * rateBp, 10000 + rateBp);
      return { net: subtotalCents - gst, gst: gst, total: subtotalCents };
    }
    var g = pct(subtotalCents, rateBp);
    return { net: subtotalCents, gst: g, total: subtotalCents + g };
  }

  // Invoice totals from lines (each line already whole cents; discounts are negative lines).
  function invoiceTotals(lines, profile) {
    var sub = 0;
    (lines || []).forEach(function (l) { sub += assertCents(l.cents, "line"); });
    return gstForInvoice(sub, profile.gst_rate_bp || 0, !!profile.gst_inclusive, !!profile.gst_registered);
  }

  // Sibling discount for the child at `rank` (1 = first). cfg: { type: 'percent'|'fixed', percent_bp, fixed_cents }
  function siblingDiscount(feeCents, rank, cfg) {
    if (!cfg || rank < 2) return 0;
    var d = cfg.type === "fixed" ? (cfg.fixed_cents || 0) : pct(feeCents, cfg.percent_bp || 0);
    return Math.min(feeCents, d);
  }

  // Proration for a mid-period join/leave. mode: 'by_remaining' | 'full' | 'skip'
  function prorate(periodCents, lessonsInPeriod, lessonsRemaining, mode) {
    if (mode === "full") return periodCents;
    if (mode === "skip") return 0;
    if (!lessonsInPeriod) return 0;
    return divRound(periodCents * lessonsRemaining, lessonsInPeriod);
  }

  // ---- TutorDeck's own fee ----
  // Billable = previous month's active students rounded to the nearest 10, halves up (403→400, 405→410).
  function billableStudents(active) {
    if (!Number.isSafeInteger(active) || active < 0) throw new Error("active students must be a whole number");
    return Math.floor((active + 5) / 10) * 10;
  }
  function platformFee(activeStudents, plan) {
    var billable = billableStudents(activeStudents);
    var fee = assertCents(plan.base_cents, "base") + assertCents(plan.per_student_cents, "rate") * billable;
    return { active: activeStudents, billable: billable, fee_cents: fee };
  }

  // ---- tutor pay (wizard preview; full calculation is phase 5) ----
  // model: per_lesson | per_hour | per_student_lesson | monthly_fixed
  function tutorPay(model, rateCents, lesson) {
    assertCents(rateCents, "rate");
    if (model === "per_lesson") return rateCents;
    if (model === "per_hour") return divRound(rateCents * (lesson.minutes || 0), 60);
    if (model === "per_student_lesson") return rateCents * (lesson.students || 0);
    if (model === "monthly_fixed") return 0;     // paid per month, not per lesson
    throw new Error("unknown pay model " + model);
  }

  return { divRound: divRound, parse: parse, format: format, pct: pct, gstForInvoice: gstForInvoice, invoiceTotals: invoiceTotals,
    siblingDiscount: siblingDiscount, prorate: prorate, billableStudents: billableStudents, platformFee: platformFee, tutorPay: tutorPay };
});
