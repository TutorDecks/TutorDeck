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

  // memberships: rows of { org_id, role, status, permissions, organisations: { id, kind, trading_name } } (as the database returns them).
  // → one entry per organisation, { id, kind, role, name }, using the person's strongest role in it; solo first, then centres by name.
  function list(rows) {
    var by = {};
    (Array.isArray(rows) ? rows : []).forEach(function (r) {
      try {
        if (!r || r.status !== "active" || !(r.role in RANK)) return;
        var o = r.organisations || {}, id = r.org_id || o.id;
        if (!id || (o.kind !== "solo" && o.kind !== "centre")) return;
        var cur = by[id];
        if (!cur || RANK[r.role] < RANK[cur.role]) {
          var e = { id: String(id), kind: o.kind, role: r.role, name: String(o.trading_name || o.name || "").trim() };
          if (r.role === "staff" && Array.isArray(r.permissions)) e.perms = r.permissions.filter(function (x) { return typeof x === "string"; });   // (T3) which tabs a staff login gets
          by[id] = e;
        }
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

  // A centre owner's (or staff member's) own solo organisation is an empty shell when they have no students of their own (it is created at sign-up).
  // Then it is not a place they work in: leave it out, so the centre is their default and they get no chip for a shell.
  // soloStudents must be the number 0 (a real count); anything else (unknown, error, >0) keeps the solo organisation: a solo tutor
  // with students is never moved.
  function dropEmptySolo(orgs, soloStudents) {
    if (!Array.isArray(orgs) || soloStudents !== 0) return orgs;
    var ownsCentre = orgs.some(function (o) { return o.kind === "centre" && (o.role === "owner" || o.role === "staff"); });   // staff: their centre login has an empty solo shell too
    if (!ownsCentre) return orgs;
    return orgs.filter(function (o) { return o.kind !== "solo"; });
  }

  // Home is the solo dashboard. When the current organisation is a centre the person owns or administers, Home sends them to
  // that centre's page instead. Only the "dashboard" page; anything else or any doubt = null (stay).
  function homeRedirect(active, org) {
    if (active !== "dashboard" || !org || org.kind !== "centre" || !org.id) return null;
    return org.role === "owner" || org.role === "staff" ? landing(org) : null;
  }

  // The switcher is for people with more than one organisation. A tutor-only login (one menu item) never gets one.
  function showSwitcher(orgs, mode) {
    return Array.isArray(orgs) && orgs.length > 1 && mode !== "tutor-only";
  }

  // Where choosing an organisation lands: solo → Home; a centre → My lessons if they are only a tutor there, else that centre's page.
  function landing(org) {
    if (!org || org.kind === "solo") return "home";
    return org.role === "tutor" ? "tutor" : "centre?id=" + encodeURIComponent(org.id);
  }

  // (T3, T4) The centre menu for an owner or staff member: Home · Timetable · Students · Attendance · Money (then the More sheet).
  // A staff member only gets the tabs their permissions allow (owners get all); Timetable is view-only for every owner / staff. All four are built (`page` = its own page);
  // a tab not built yet would carry soon:true and open a clear "Coming next" page, never a dead link. perms = undefined means "not known yet" (an older remembered list): show the tab,
  // the database refuses what a person may not do anyway. Remove `soon` from a tab the day its screen exists.
  var TABS = [
    { id: "orghome", label: "Home",       ic: "home",     tab: "",           perm: null,               soon: false },
    { id: "orgtt",   label: "Timetable",  ic: "schedule", tab: "timetable",  perm: null,               soon: false, page: "centre-timetable" },   // viewing is for any owner / staff (T3 plan §1); editing will need manage_timetable
    { id: "orgst",   label: "Students",   ic: "students", tab: "students",   perm: "manage_students",  soon: false, page: "centre-students" },
    { id: "orgatt",  label: "Attendance", ic: "check",    tab: "attendance", perm: ["manage_timetable", "issue_invoices"], soon: false, page: "centre-attendance" },   // issue_invoices alone: the Charges tab on that page
    { id: "orgmoney", label: "Money",    ic: "money",    tab: "money",      perm: "issue_invoices",   soon: false, page: "centre-money" }         // (T4 S2) the invoice run; only people who may issue invoices see it
  ];
  function can(org, perm) {                                   // perm: one permission name, or a list where ANY one is enough
    if (!perm || !org) return true;
    if (org.role === "owner") return true;
    if (org.role !== "staff") return false;
    var want = Array.isArray(perm) ? perm : [perm];
    return Array.isArray(org.perms) ? want.some(function (p) { return org.perms.indexOf(p) >= 0; }) : true;
  }
  function centreTabs(org) {
    if (!org || org.kind !== "centre" || !org.id || (org.role !== "owner" && org.role !== "staff")) return [];
    var base = "centre?id=" + encodeURIComponent(org.id);
    return TABS.filter(function (t) { return can(org, t.perm); }).map(function (t) {
      return { id: t.id, label: t.label, ic: t.ic, soon: t.soon, tab: t.tab, page: t.page || "", href: t.page ? t.page + "?id=" + encodeURIComponent(org.id) : t.tab ? base + "&tab=" + t.tab : base };
    });
  }

  return { centreTabs: centreTabs, can: can, list: list, dropEmptySolo: dropEmptySolo, homeRedirect: homeRedirect, pick: pick, choose: choose, showSwitcher: showSwitcher, landing: landing };
});
