// The menus and icons of every kind of login, in ONE place with no DOM and no network (UX1). assets/js/app.js draws what this returns;
// tests/menus.test.js checks, for every role, that no two different destinations in one menu share an icon.
// Which menu a login gets (owner's words, UX1): what you SEE depends on the organisation you are working in (TL.org()) and on TL.roleMode().
//
//   login                         organisation       bottom bar / top bar              More sheet
//   solo tutor                    solo               Home · Schedule · Students · Money   Materials · Settings
//   solo tutor who also teaches   solo               (the same four)                      My lessons · Materials · Settings
//     at a centre ("both")        a centre (tutor)   My lessons · Schedule                Settings (the tutor's own page)
//   centre-only tutor             a centre (tutor)   My lessons · Schedule                Settings (the tutor's own page)
//   centre owner / staff          a centre           Home · Timetable · Students ·        Centre settings · Your centres · Settings
//                                                    Attendance · Money · People (by permission)
// "Settings" is the solo Settings page in a solo organisation and the tutor's own page (/tutor-settings) only while working in a centre as a
// tutor: never both in one menu. A "both" login in their solo organisation gets ONE entry for the centre (My lessons, with a Schedule sub-tab on
// its pages), no "My tutor profile" and no second calendar.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.Menus = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  // 24px grid, stroke, currentColor (app.js wraps these in the <svg>). Every id below is a different picture.
  var ICONS = {
    home:     '<path d="M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8"/><path d="M3 10a2 2 0 0 1 .709-1.528l7-5.999a2 2 0 0 1 2.582 0l7 5.999A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
    schedule: '<path d="M8 2v4"/><path d="M16 2v4"/><rect width="18" height="18" x="3" y="4" rx="2"/><path d="M3 10h18"/><path d="M8 14h.01"/><path d="M12 14h.01"/><path d="M16 14h.01"/><path d="M8 18h.01"/><path d="M12 18h.01"/>',
    students: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>',
    money:    '<path d="M19 7V4a1 1 0 0 0-1-1H5a2 2 0 0 0 0 4h15a1 1 0 0 1 1 1v4h-3a2 2 0 0 0 0 4h3a1 1 0 0 0 1-1v-2a1 1 0 0 0-1-1"/><path d="M3 5v14a2 2 0 0 0 2 2h15a1 1 0 0 0 1-1v-4"/>',
    check:    '<circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/>',
    more:     '<circle cx="12" cy="12" r="1.4"/><circle cx="19" cy="12" r="1.4"/><circle cx="5" cy="12" r="1.4"/>',
    settings: '<path d="M20 7h-9"/><path d="M14 17H5"/><circle cx="17" cy="17" r="3"/><circle cx="7" cy="7" r="3"/>',
    materials:'<path d="M12 7v14"/><path d="M3 18a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h5a4 4 0 0 1 4 4 4 4 0 0 1 4-4h5a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1h-6a3 3 0 0 0-3 3 3 3 0 0 0-3-3z"/>',
    user:     '<circle cx="12" cy="8" r="4"/><path d="M4 21v-1a6 6 0 0 1 6-6h4a6 6 0 0 1 6 6v1"/>',
    signout:  '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><path d="m16 17 5-5-5-5"/><path d="M21 12H9"/>',
    // UX1: the pictures that used to be borrowed from another page
    lessons:  '<rect width="8" height="4" x="8" y="2" rx="1" ry="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><path d="M12 11h4"/><path d="M12 16h4"/><path d="M8 11h.01"/><path d="M8 16h.01"/>',          // My lessons (clipboard with lines)
    timetable:'<path d="M12 3v18"/><rect width="18" height="18" x="3" y="3" rx="2"/><path d="M3 9h18"/><path d="M3 15h18"/>',                                                                                                  // centre Timetable (grid)
    people:   '<path d="M16 2v2"/><path d="M7 22v-2a2 2 0 0 1 2-2h6a2 2 0 0 1 2 2v2"/><path d="M8 2v2"/><circle cx="12" cy="11" r="3"/><rect x="3" y="4" width="18" height="18" rx="2"/>',                                         // centre People (contact card)
    centre:   '<path d="M6 22V4a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v18Z"/><path d="M6 12H4a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h2"/><path d="M18 9h2a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-2"/><path d="M10 6h4"/><path d="M10 10h4"/><path d="M10 14h4"/><path d="M10 18h4"/>',   // Centre settings (building)
    centres:  '<path d="M12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83Z"/><path d="m22 17.65-9.17 4.16a2 2 0 0 1-1.66 0L2 17.65"/><path d="m22 12.65-9.17 4.16a2 2 0 0 1-1.66 0L2 12.65"/>'   // Your centres (stack)
  };

  var GROUPS = [
    { id: "home",     label: "Home",     ic: "home",     pages: [ { id: "dashboard", label: "Dashboard", href: "home" } ] },
    { id: "schedule", label: "Schedule", ic: "schedule", pages: [ { id: "calendar", label: "Calendar", href: "calendar" },
                                                                  { id: "planner",  label: "Weekly planner", href: "planner" } ] },
    { id: "students", label: "Students", ic: "students", pages: [ { id: "students", label: "Roster", href: "students" },
                                                                  { id: "exams",    label: "Exams",  href: "exams" } ],
      also: ["student"] },
    { id: "money",    label: "Money",    ic: "money",    pages: [ { id: "ledger",   label: "Ledger",   href: "ledger" },
                                                                  { id: "invoices", label: "Invoices", href: "invoices" },
                                                                  { id: "insights", label: "Insights", href: "insights" } ] }
  ];
  // A centre tutor's own menu (a centre-only login, or a "both" login while working in the centre).
  var TUTOR_GROUPS = [
    { id: "tutor", label: "My lessons", ic: "lessons", pages: [ { id: "tutor", label: "My lessons", href: "tutor" } ] },
    { id: "tutor-schedule", label: "Schedule", ic: "schedule", pages: [ { id: "tutor-schedule", label: "Schedule", href: "tutor-schedule" } ] }
  ];
  // The ONE centre entry a "both" login sees in their solo organisation: My lessons, with its Schedule as a sub-tab on those two pages.
  var BOTH_CENTRE_EXTRA = { id: "tutor", label: "My lessons", href: "tutor", ic: "lessons", also: ["tutor-schedule"],
    pages: [ { id: "tutor", label: "My lessons", href: "tutor" }, { id: "tutor-schedule", label: "Schedule", href: "tutor-schedule" } ] };
  var TUTOR_MENU_SETTINGS = { id: "tutor-settings", label: "Settings", href: "tutor-settings", ic: "settings" };   // a centre tutor's own profile and password
  var EXTRA = [
    { id: "materials", label: "Materials", href: "https://mugcornersg.com", ic: "materials", ext: true, hint: "Materials on MugCorner (opens in a new tab)" },
    { id: "settings",  label: "Settings",  href: "settings",  ic: "settings" }
  ];
  var CENTRE_GROUPS = [
    { id: "orghome", label: "Centre home", ic: "home",     pages: [ { id: "orghome", label: "Centre home", href: "org" } ] },
    { id: "orglist", label: "Centres",     ic: "centres",  pages: [ { id: "orglist", label: "Centres", href: "org" } ] }
  ];

  // → { groups, extras, kind } for this login in this organisation.
  //   mode: "solo" | "both" | "tutor-only" (TL.roleMode(); null = solo)    org: TL.org() ({ id, kind, role })
  //   tabs: the centre owner / staff tabs for this org (OrgCurrent.centreTabs(org)), each { id, label, ic, soon, tab, page, href }
  function build(mode, org, tabs) {
    var centre = !!(org && org.kind === "centre" && org.id);
    if (mode === "tutor-only") return { kind: "tutor", groups: TUTOR_GROUPS, extras: [TUTOR_MENU_SETTINGS] };
    if (centre) {
      if (org.role === "tutor") return { kind: "tutor", groups: TUTOR_GROUPS, extras: [TUTOR_MENU_SETTINGS] };
      var G = (tabs || []).map(function (t) { return { id: t.id, label: t.label, ic: t.ic, soon: t.soon, tab: t.tab, page: t.page, pages: [ { id: t.id, label: t.label, href: t.href } ] }; });
      if (!G.length) G = CENTRE_GROUPS;
      return { kind: "centre", groups: G, extras: [
        { id: "orgsettings", label: "Centre settings", href: "org?id=" + encodeURIComponent(org.id), ic: "centre" },
        { id: "orglist", label: "Your centres", href: "org", ic: "centres" },
        EXTRA[1] ] };
    }
    return { kind: "solo", groups: GROUPS, extras: mode === "both" ? [BOTH_CENTRE_EXTRA].concat(EXTRA) : EXTRA };
  }

  // Every destination a menu shows (bottom bar + More sheet + the More button and Sign out), as [{ id, label, ic }], for the tests and the browser check.
  function items(menu) {
    var out = menu.groups.map(function (g) { return { id: g.id, label: g.label, ic: g.ic }; });
    out.push({ id: "more", label: "More", ic: "more" });
    menu.extras.forEach(function (n) { out.push({ id: n.id, label: n.label, ic: n.ic }); });
    out.push({ id: "signout", label: "Sign out", ic: "signout" });
    return out;
  }
  // The two icon ids that two DIFFERENT destinations of one menu share (an empty list = fine). Used by the tests and the browser check.
  function duplicateIcons(menu) {
    var seen = {}, dup = [];
    items(menu).forEach(function (n) {
      if (seen[n.ic] && seen[n.ic] !== n.label) dup.push(n.ic + ": " + seen[n.ic] + " / " + n.label); else seen[n.ic] = n.label;
    });
    return dup;
  }

  return { ICONS: ICONS, GROUPS: GROUPS, TUTOR_GROUPS: TUTOR_GROUPS, TUTOR_MENU_SETTINGS: TUTOR_MENU_SETTINGS, EXTRA: EXTRA, CENTRE_GROUPS: CENTRE_GROUPS,
           BOTH_CENTRE_EXTRA: BOTH_CENTRE_EXTRA, build: build, items: items, duplicateIcons: duplicateIcons };
});
