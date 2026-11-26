// Centre Students page logic with no DOM and no network: how a form becomes the payload of staff_save_student, the same checks the database makes
// (so a mistake is caught before the round trip; the database still decides), and what its refusals mean in plain words.
// Used by assets/js/centre-students.js and unit-tested in tests/centre-students-core.test.js.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.CentreStudentsCore = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  var MAX_GUARDIANS = 6, PAGE_SIZE = 25;
  var RELATIONS = ["Mother", "Father", "Guardian", "Grandparent", "Self", "Other"];

  function trim(s) { return String(s == null ? "" : s).trim(); }
  function blankGuardian() { return { id: null, name: "", relation: "", phone: "", email: "" }; }

  // One contact: a name, and a phone or an email (the same rules as staff_clean_guardian in db/migration_staff_students.sql).
  // → { ok, error, value } where value is what is sent to the database.
  function checkGuardian(g) {
    var name = trim(g && g.name), rel = trim(g && g.relation), ph = trim(g && g.phone), em = trim(g && g.email).toLowerCase();
    if (!name) return { ok: false, error: "Give each parent or guardian a name." };
    if (name.length > 120) return { ok: false, error: "That name is too long." };
    if (rel.length > 40) return { ok: false, error: "That relation is too long." };
    if (!ph && !em) return { ok: false, error: "Give " + name + " a phone number or an email, so the centre can reach the family." };
    if (ph) {
      var digits = ph.replace(/\D/g, "").length;
      if (!/^[0-9+()\s-]{6,30}$/.test(ph) || digits < 6 || digits > 15) return { ok: false, error: "That phone number doesn’t look right (" + ph + ")." };
    }
    if (em && (em.length > 254 || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(em))) return { ok: false, error: "That email address doesn’t look right (" + em + ")." };
    var v = { name: name, relation: rel || null, phone: ph || null, email: em || null };
    if (g && g.id) v.id = g.id;
    return { ok: true, value: v };
  }

  // The whole form. mode "add" needs at least one contact for a NEW family (family = null); adding a sibling (family given) may leave contacts alone.
  // → { ok, errors: { name, guardians: [msg|null…], form }, payload }
  function check(form, mode) {
    var errors = { name: null, guardians: [], form: null }, name = trim(form.name), list = form.guardians || [], out = [], bad = false;
    if (!name) { errors.name = "Give the student a name."; bad = true; }
    else if (name.length > 120) { errors.name = "That name is too long (120 characters at most)."; bad = true; }
    if (trim(form.level).length > 40) { errors.form = "The level is too long (40 characters at most)."; bad = true; }
    if (trim(form.notes).length > 1000) { errors.form = "The notes are too long (1000 characters at most)."; bad = true; }
    if (trim(form.householdName).length > 120) { errors.form = "The family name is too long (120 characters at most)."; bad = true; }
    var sendGuardians = !(mode === "add" && form.family);                     // a sibling added to an existing family leaves its contacts as they are
    if (sendGuardians) {
      if (list.length === 0) { errors.form = "Add a parent or guardian with a phone number or an email, so the centre can reach the family."; bad = true; }
      if (list.length > MAX_GUARDIANS) { errors.form = "At most " + MAX_GUARDIANS + " parents or guardians per family."; bad = true; }
      list.forEach(function (g, i) {
        var c = checkGuardian(g); errors.guardians[i] = c.ok ? null : c.error;
        if (c.ok) out.push(c.value); else bad = true;
      });
    }
    return {
      ok: !bad, errors: errors,
      payload: bad ? null : {
        p_name: name, p_level: trim(form.level) || null, p_notes: trim(form.notes) || null,
        p_household: mode === "add" && form.family ? form.family : null, p_household_name: trim(form.householdName) || null,
        p_guardians: sendGuardians ? out : null
      }
    };
  }

  // The database's refusals, in plain words. Codes: NOT_FOUND, NOT_ALLOWED, BAD_STUDENT, BAD_GUARDIAN, BAD_DATE, BAD_FILTER, BAD_SEARCH, DUPLICATE.
  function errorText(err) {
    var m = String((err && err.message) || err || "");
    if (/NOT_ALLOWED/.test(m)) return "Your account can’t manage students at this centre.";
    if (/NOT_FOUND/.test(m)) return "That student or family isn’t available any more. Refresh the list and try again.";
    var coded = /(?:BAD_STUDENT|BAD_GUARDIAN|BAD_DATE|BAD_FILTER|BAD_SEARCH|DUPLICATE):\s*(.+)$/.exec(m);
    if (coded) return coded[1].charAt(0).toUpperCase() + coded[1].slice(1) + (/[.!?]$/.test(coded[1]) ? "" : ".");
    if (/Failed to fetch|NetworkError|network/i.test(m)) return "Couldn’t reach the server. Check your connection and try again.";
    return m || "Something went wrong.";
  }
  // Is the function missing (the migration isn't on this database yet)?
  function isMissing(err) { return !!err && (err.code === "42883" || err.code === "PGRST202" || /does not exist|Could not find the function/i.test(err.message || "")); }

  function initials(name) {
    var p = trim(name).split(/\s+/).filter(Boolean);
    if (!p.length) return "?";
    return (p[0].charAt(0) + (p.length > 1 ? p[p.length - 1].charAt(0) : "")).toUpperCase();
  }
  // "+65 9123 4567" → "tel:+6591234567" (digits and a leading +, nothing else) · "" when there are no digits
  function telHref(phone) {
    var s = trim(phone), d = s.replace(/\D/g, "");
    return d ? "tel:" + (s.charAt(0) === "+" ? "+" : "") + d : "";
  }
  function mailHref(email) { var e = trim(email); return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e) ? "mailto:" + e : ""; }

  // paging: "26–50 of 62"
  function pageCount(total, size) { return Math.max(1, Math.ceil((total || 0) / (size || PAGE_SIZE))); }
  function pagerLabel(page, size, total) {
    if (!total) return "No students";
    var from = (page - 1) * size + 1, to = Math.min(total, page * size);
    return from + "–" + to + " of " + total;
  }

  var FILTERS = [{ key: "active", label: "Active" }, { key: "ended", label: "Ended" }, { key: "trial", label: "Trial" }, { key: "all", label: "All" }];
  function emptyText(filter, searching) {
    if (searching) return { title: "No students match", hint: "Try a different name, level, parent or phone number." };
    return { active: { title: "No students yet", hint: "Add your first student and their parent’s contact details." },
             ended: { title: "No discontinued students", hint: "Students whose lessons have ended appear here." },
             trial: { title: "No trial lessons in the last 30 days", hint: "Students with a recent trial lesson appear here." },
             all: { title: "No students yet", hint: "Add your first student and their parent’s contact details." } }[filter] || { title: "No students", hint: "" };
  }

  // "Lessons run until" in words, for the sheet and the list.  today = the centre's own today (from the database).
  function endNote(s, today, dateLabel) {
    if (!s || !s.end_date) return "";
    var d = dateLabel ? dateLabel(s.end_date, today) : s.end_date;
    return s.ended ? "Lessons ended " + d : "Lessons run until " + d;
  }

  return { MAX_GUARDIANS: MAX_GUARDIANS, PAGE_SIZE: PAGE_SIZE, RELATIONS: RELATIONS, FILTERS: FILTERS, blankGuardian: blankGuardian, checkGuardian: checkGuardian, check: check,
           errorText: errorText, isMissing: isMissing, initials: initials, telHref: telHref, mailHref: mailHref, pageCount: pageCount, pagerLabel: pagerLabel,
           emptyText: emptyText, endNote: endNote };
});
