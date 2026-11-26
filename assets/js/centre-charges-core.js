// Centre Charges page logic with no DOM and no network (T3 step 4): the amount a person types, the suggestion's wording, what a bulk action will
// add up to, and what the database's refusals mean in plain words. Money is always whole cents (assets/js/money.js).
// Used by assets/js/centre-charges.js and unit-tested in tests/centre-charges-core.test.js. The database decides everything that matters
// (db/migration_staff_charges.sql: who may, 0..price, audit); this file only saves a round trip and words the answers.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory(require("./money.js"), require("./centre-attendance-core.js"));
  else root.CentreChargesCore = factory(root.Money, root.CentreAttendanceCore);
})(typeof self !== "undefined" ? self : this, function (Money, CA) {
  "use strict";
  var PAGE_SIZE = 50, REASON_MAX = 500, BULK_MAX = 100;

  function fmt(cents) { return Money.format(cents); }                         // 12345 → "S$123.45"
  function plain(cents) { return Money.format(cents, { symbol: false }).replace(/,/g, ""); }   // 12345 → "123.45" (for an input box)

  // The centre's own wording of billing.absences.mode, shown beside the suggestion. (It only pre-fills; a person confirms.)
  var RULES = {
    charged: "This centre charges absent lessons.",
    not_charged: "This centre doesn’t charge absent lessons.",
    charged_unless_notice: "This centre charges unless notice was given."
  };
  function ruleText(mode) { return RULES[mode] || ""; }
  function markLabel(key) { var m = CA.mark(key); return m ? m.label : "Absent"; }
  function markShort(key) { var m = CA.mark(key); return m ? m.short : "Absent"; }

  // "Suggested S$123.45" / "Suggested: not charged" / "" when the centre hasn't said
  function suggestion(r) {
    if (r.suggested_cents == null) return "";
    return r.suggested_cents === 0 ? "Suggested: not charged" : "Suggested " + fmt(r.suggested_cents);
  }

  // What the person typed → whole cents, from the text (never parseFloat). price = the lesson's own price in cents.
  function parseCharge(text, price) {
    var t = String(text == null ? "" : text).trim();
    if (!t) return { ok: false, error: "Enter the amount to charge, or 0 if the family isn’t charged." };
    var c = /\s/.test(t) ? null : Money.parse(t);                                       // "5 6" is a typo, not S$56
    if (c == null || /^-/.test(t.replace(/^S\$/, ""))) return { ok: false, error: "Enter an amount like 25 or 25.50." };
    if (c < 0) return { ok: false, error: "The charge can’t be negative." };
    if (c > price) return { ok: false, error: "That is more than the lesson costs (" + fmt(price) + "). Enter " + fmt(price) + " or less." };
    return { ok: true, cents: c };
  }
  function checkReason(text) {
    var why = String(text == null ? "" : text).trim();
    if (!why) return { ok: false, error: "Say why you are changing the charge. It is kept on record." };
    if (why.length > REASON_MAX) return { ok: false, error: "Keep the reason under " + REASON_MAX + " characters." };
    return { ok: true, reason: why };
  }

  // Bulk: which rows are picked, what the action will add up to, and whether it can be done at all.
  //   mode 'zero' → 0 each · mode 'full' → each lesson's own price
  function bulk(rows, picked, mode) {
    var chosen = (rows || []).filter(function (r) { return picked && picked[r.lesson_id]; });
    var total = 0;
    chosen.forEach(function (r) { total += mode === "full" ? (r.price_cents || 0) : 0; });
    return { count: chosen.length, ids: chosen.map(function (r) { return r.lesson_id; }), total: total, tooMany: chosen.length > BULK_MAX };
  }
  function bulkQuestion(b, mode) {
    var n = b.count, what = n === 1 ? "1 lesson" : n + " lessons";
    return mode === "full"
      ? { title: "Charge full price?", message: "Charge the full price for " + what + " (" + fmt(b.total) + " in all)? Each family is charged that lesson’s own price." }
      : { title: "Mark as not charged?", message: "Mark " + what + " as not charged (S$0)? The families won’t be billed for " + (n === 1 ? "it" : "them") + "." };
  }

  function whenLine(r, today) {
    return CA.dayLabel(r.lesson_date, today) + " · " + CA.timeRange(r);
  }
  function emptyText() { return { title: "Nothing waiting", hint: "When a lesson is marked absent or cancelled, its charge waits here until someone confirms it." }; }

  // ---- the database's refusals, in plain words ----
  function errorText(err) {
    var m = String((err && err.message) || err || "");
    var map = [
      [/NOT_ALLOWED/, "Your account can’t set charges at this centre. Ask the centre owner."],
      [/NOT_FOUND/, "That lesson isn’t available any more. Refresh the list and try again."],
      [/NOT_CANCELLED/, "Only a lesson marked absent or cancelled has a charge. Refresh the list."],
      [/BAD_CHARGE/, "That amount isn’t allowed. Enter 0 up to the lesson’s own price."],
      [/ALREADY_SET/, "Someone has already set the charge for one of these lessons. Refresh the list and try again."],
      [/ALREADY_PAID/, "This lesson is already paid, so its charge can’t be changed."],
      [/REASON_REQUIRED/, "Say why you are changing the charge. It is kept on record."],
      [/NO_CHANGE/, "The charge is already that amount."],
      [/TOO_MANY/, "Choose up to " + BULK_MAX + " lessons at a time."],
      [/TOO_LONG/, "That text is too long. Please shorten it."],
      [/BAD_VALUE|BAD_PAGE/, "That choice isn’t available. Refresh the page and try again."]
    ];
    for (var i = 0; i < map.length; i++) if (map[i][0].test(m)) return map[i][1];
    if (/Failed to fetch|NetworkError|network/i.test(m)) return "Couldn’t reach the server. Check your connection and try again.";
    return m || "Something went wrong.";
  }
  function isMissing(err) { return CA.isMissing(err); }
  function isNotAllowed(err) { return !!err && /NOT_ALLOWED/.test(err.message || ""); }

  return { PAGE_SIZE: PAGE_SIZE, BULK_MAX: BULK_MAX, fmt: fmt, plain: plain, ruleText: ruleText, markLabel: markLabel, markShort: markShort,
           suggestion: suggestion, parseCharge: parseCharge, checkReason: checkReason, bulk: bulk, bulkQuestion: bulkQuestion, whenLine: whenLine,
           emptyText: emptyText, errorText: errorText, isMissing: isMissing, isNotAllowed: isNotAllowed };
});
