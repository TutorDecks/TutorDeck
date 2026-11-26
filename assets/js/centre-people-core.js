// The People tab (T3.9): the page logic with no DOM and no network. Used by assets/js/centre-people.js and unit-tested in tests/centre-people-core.test.js.
// The database (staff_people, db/migration_slot_changes.sql) decides who may see whom and returns only: id, name, role, status, invite state,
// when the last invite email went out. Never an email address, phone, pay, payout or any money, so this file has none to show either.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory(require("./invite-status.js"));
  else root.CentrePeopleCore = factory(root.InviteStatus);
})(typeof self !== "undefined" ? self : this, function (IS) {
  "use strict";
  var ROLES = { owner: "Owner", staff: "Staff admin", tutor: "Tutor" };
  var TITLES = { owner: "Owner", staff: "Staff", tutor: "Tutors" };
  function plural(n, one, many) { return n + " " + (n === 1 ? one : many); }
  function roleLabel(role) { return ROLES[role] || "Member"; }
  // active | invited (asked, not signed in yet) | off (access switched off)
  function statusOf(row) {
    if (row && row.status === "disabled") return { key: "off", label: "Off" };
    if (row && (row.invited || row.status === "invited")) return { key: "invited", label: "Invited" };
    return { key: "active", label: "Active" };
  }
  // the rows in sections: Owner, Staff, Tutors (empty sections are left out). The database already orders each section.
  function group(rows) {
    return ["owner", "staff", "tutor"].map(function (r) {
      return { role: r, title: TITLES[r], rows: (rows || []).filter(function (x) { return x.role === r; }) };
    }).filter(function (g) { return g.rows.length; });
  }
  // "Invited 2 days ago · Emailed today" / "Invited today · No email sent yet" / "Invited 3 days ago · Link expired, send a new one"
  function inviteLine(row, now) {
    if (!row || !row.invited) return "";
    var d = IS.describe({ created_at: row.invited_at }, row.last_emailed_at ? { last_sent_at: row.last_emailed_at } : { last_sent_at: null }, now);
    return d.invited + " · " + d.hint;
  }
  function summary(rows) {
    rows = rows || [];
    var by = { active: 0, invited: 0, off: 0 };
    rows.forEach(function (r) { by[statusOf(r).key]++; });
    var parts = [plural(rows.length, "person", "people")];
    if (by.invited) parts.push(by.invited + " invited");
    if (by.off) parts.push(by.off + " off");
    return parts.join(" · ");
  }
  function isMissing(err) { return !!err && (err.code === "42883" || err.code === "PGRST202" || /does not exist|Could not find/i.test(err.message || "")); }
  function errorText(err) {
    var m = String((err && err.message) || err || "");
    if (/NOT_ALLOWED/.test(m)) return "Your account doesn’t include the People list. Ask the centre owner to give you “Manage tutors”.";
    if (/NOT_FOUND/.test(m)) return "This centre isn’t available, or you aren’t an owner or staff member there.";
    return m || "Something went wrong. Refresh and try again.";
  }
  return { ROLES: ROLES, roleLabel: roleLabel, statusOf: statusOf, group: group, inviteLine: inviteLine, summary: summary, isMissing: isMissing, errorText: errorText };
});
