// Sign-up password rules in ONE place, matching what Supabase Auth enforces (min length + required character classes).
// Pure logic, no DOM: used by login.html and unit-tested in tests/password-rules.test.js.
// To change a rule, change it here and in Supabase (Authentication → Sign In / Providers → Email) on BOTH projects.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.PasswordRules = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  var MIN = 8;
  // Supabase's required-character sets are fixed lists, not "anything that isn't a letter or digit": letters are ASCII a-z / A-Z
  // and symbols are exactly this string (space, accented letters, emoji etc. do NOT count). Assumption taken from Supabase's docs
  // ("lowercase, uppercase, digits, symbols": !@#$%^&*()_+-=[]{};'\:"|<>?,./`~); we could not re-check the docs page from here.
  var SYMBOLS = "!@#$%^&*()_+-=[]{};'\\:\"|<>?,./`~";
  var LOWER = "abcdefghijklmnopqrstuvwxyz", UPPER = LOWER.toUpperCase(), DIGITS = "0123456789";
  function has(pw, set) { for (var i = 0; i < pw.length; i++) if (set.indexOf(pw.charAt(i)) >= 0) return true; return false; }
  // Each rule: `need` is what the "Still needed" line says when it is missing.
  var RULES = [
    { key: "lower", label: "A lowercase letter", need: "a lowercase letter", ok: function (p) { return has(p, LOWER); } },
    { key: "upper", label: "An uppercase letter", need: "an uppercase letter", ok: function (p) { return has(p, UPPER); } },
    { key: "digit", label: "A number", need: "a number", ok: function (p) { return has(p, DIGITS); } },
    { key: "symbol", label: "A symbol", need: "a symbol (like ! ? # @)", ok: function (p) { return has(p, SYMBOLS); } }
  ];
  // Plain-words list of what is missing, in order; [] means the password is acceptable.
  function problems(pw) {
    pw = String(pw == null ? "" : pw);
    var out = [];
    if (pw.length < MIN) out.push("at least " + MIN + " characters (" + (MIN - pw.length) + " more)");
    RULES.forEach(function (r) { if (!r.ok(pw)) out.push(r.need); });
    return out;
  }
  // Every rule as a checklist line (length first, then RULES in order): [{ key, label, ok }]. Used by the sign-up checklist.
  function checklist(pw) {
    pw = String(pw == null ? "" : pw);
    var out = [{ key: "length", label: "At least " + MIN + " characters", ok: pw.length >= MIN }];
    RULES.forEach(function (r) { out.push({ key: r.key, label: r.label, ok: r.ok(pw) }); });
    return out;
  }
  function summary() { return "At least " + MIN + " characters, with a lowercase and an uppercase letter, a number and a symbol"; }
  return { MIN: MIN, SYMBOLS: SYMBOLS, RULES: RULES, problems: problems, checklist: checklist, summary: summary };
});
