// Tutor settings logic with no DOM and no network: phone and name checks, how a phone is shown, and what the database's
// refusal codes mean in plain words. Used by assets/js/tutor-settings.js and unit-tested in tests/tutor-settings-core.test.js.
// The database (tutor_my_profile / tutor_save_profile) is the authority; these checks only give an earlier, friendlier answer.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.TutorSettingsCore = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  var NAME_MAX = 80;

  // → { ok, value } where value is "+65" + 8 digits or null (empty = no phone), or { ok:false, error } in plain words.
  // Same rule as the database: +65 then 8 digits starting 6, 8 or 9 (the plan's [689]); spaces and dashes are ignored.
  function normalisePhone(s) {
    var raw = String(s == null ? "" : s).replace(/[\s\-]/g, "");
    if (raw === "") return { ok: true, value: null };
    if (/^[689]\d{7}$/.test(raw)) raw = "+65" + raw;
    else if (/^65[689]\d{7}$/.test(raw)) raw = "+" + raw;
    if (!/^\+65[689]\d{7}$/.test(raw)) return { ok: false, error: "Use a Singapore number, like 9123 4567." };
    return { ok: true, value: raw };
  }
  // "+6591234567" → "+65 9123 4567" ("" for nothing)
  function phoneDisplay(v) {
    var m = /^\+65(\d{4})(\d{4})$/.exec(String(v || ""));
    return m ? "+65 " + m[1] + " " + m[2] : "";
  }
  // "9123 4567" for the edit box (the +65 is added for them)
  function phoneForEdit(v) {
    var m = /^\+65(\d{4})(\d{4})$/.exec(String(v || ""));
    return m ? m[1] + " " + m[2] : "";
  }
  // → null when fine, or a plain sentence
  function nameProblem(s) {
    var n = String(s == null ? "" : s).trim();
    if (!n) return "Please type your name.";
    if (n.length > NAME_MAX) return "Please use " + NAME_MAX + " characters or fewer.";
    return null;
  }
  // database refusal → plain words (codes are the text before the first colon)
  function errorText(err) {
    var m = String((err && err.message) || "");
    if (/^BAD_PHONE/.test(m)) return "Use a Singapore number, like 9123 4567.";
    if (/^BAD_NAME/.test(m)) return "Please use between 1 and " + NAME_MAX + " characters for your name.";
    if (/NOT_FOUND/.test(m)) return "We couldn’t find your tutor profile. Please reload the page.";
    return "That didn’t save. Please try again in a moment.";
  }
  // Supabase's server-side weak-password refusal → plain words; null when it isn't one
  function weakPasswordText(e, min) {
    var r = (e && e.weak_password && e.weak_password.reasons) || [];
    if (!r.length && !(e && e.code === "weak_password")) return null;
    var out = [];
    if (r.indexOf("length") >= 0) out.push("be at least " + min + " characters");
    if (r.indexOf("characters") >= 0) out.push("include a lowercase and an uppercase letter, a number and a symbol");
    if (r.indexOf("pwned") >= 0) out.push("not be one that has appeared in a data breach");
    return out.length ? "Your password needs to " + out.join(", ") + "." : "That password isn’t strong enough. Try a longer one.";
  }
  return { NAME_MAX: NAME_MAX, normalisePhone: normalisePhone, phoneDisplay: phoneDisplay, phoneForEdit: phoneForEdit, nameProblem: nameProblem, errorText: errorText, weakPasswordText: weakPasswordText };
});
