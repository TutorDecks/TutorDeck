// "Which organisation am I working in right now?" (T12b). Pure logic: no DOM, no network, no storage.
// assets/js/app.js reads the person's active memberships once, hands them here, and remembers the answer (TL.org()).
// Rules: the remembered choice if it is still one of their organisations; else their solo organisation; else their
// first centre. Anything odd (no rows, bad rows, an error) = null, and the caller treats null as "their solo organisation",
// which is what every login has today. Unit-tested in tests/org-current.test.js.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.OrgCurrent = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  var RANK = { owner: 0, staff: 1, tutor: 2 };   // parents (and anything unknown) don't use these screens

  // memberships: rows of { org_id, role, status, organisations: { id, kind, trading_name } } (as the database returns them).
  // → one entry per organisation, { id, kind, role, name }, using the person's strongest role in it; solo first, then centres by name.
  function list(rows) {
    var by = {};
    (Array.isArray(rows) ? rows : []).forEach(function (r) {
      try {
        if (!r || r.status !== "active" || !(r.role in RANK)) return;
        var o = r.organisations || {}, id = r.org_id || o.id;
        if (!id || (o.kind !== "solo" && o.kind !== "centre")) return;
        var cur = by[id];
        if (!cur || RANK[r.role] < RANK[cur.role]) by[id] = { id: String(id), kind: o.kind, role: r.role, name: String(o.trading_name || o.name || "").trim() };
      } catch (e) {}
    });
    return Object.keys(by).map(function (k) { return by[k]; }).sort(function (a, b) {
      if (a.kind !== b.kind) return a.kind === "solo" ? -1 : 1;
      return a.name.localeCompare(b.name) || (a.id < b.id ? -1 : 1);
    });
  }

  // orgs: the result of list(). → { id, kind, role, name } or null (= no answer: the caller uses the solo organisation as before)
  function pick(orgs, remembered) {
    if (!Array.isArray(orgs) || !orgs.length) return null;
    if (remembered) for (var i = 0; i < orgs.length; i++) if (orgs[i].id === String(remembered)) return orgs[i];
    for (var j = 0; j < orgs.length; j++) if (orgs[j].kind === "solo") return orgs[j];
    return orgs[0];
  }
  function choose(rows, remembered) { return pick(list(rows), remembered); }

  // The switcher is for people with more than one organisation. A tutor-only login (one menu item) never gets one.
  function showSwitcher(orgs, mode) {
    return Array.isArray(orgs) && orgs.length > 1 && mode !== "tutor-only";
  }

  // Where choosing an organisation lands: solo → Home; a centre → My lessons if they are only a tutor there, else that centre's page.
  function landing(org) {
    if (!org || org.kind === "solo") return "home";
    return org.role === "tutor" ? "tutor" : "org?id=" + encodeURIComponent(org.id);
  }

  return { list: list, pick: pick, choose: choose, showSwitcher: showSwitcher, landing: landing };
});
