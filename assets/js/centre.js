// Centre home for owners and staff (T3 step 1). One database call, staff_home(org), returns COUNTS ONLY (no money, no names);
// which sections come back is decided by the person's permissions in the database, this page only draws what it got.
// Timetable is not built yet: its tab opens a clear "Coming next" page (never a dead link). Students and Attendance are their own pages.
//   centre?id=<centre>               Home
//   centre?id=<centre>&tab=<name>    timetable (coming next); students and attendance are their own pages now (centre-students, centre-attendance)
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }
  function missing(err) { return err && (err.code === "42883" || err.code === "PGRST202" || /does not exist|Could not find/i.test(err.message || "")); }
  function card(inner) { $("ch").innerHTML = '<div class="card panel ch-empty">' + inner + '</div>'; }

  // What each coming tab will be (plain words, from the T3 plan). `need` = the staff_home section a person needs to see the tab at all.
  var SOON = {
    timetable:  { title: "Timetable", need: "timetable", lead: "The week at your centre, one day at a time.",
                  items: ["See every lesson by day, filtered by tutor", "Add or change a weekly slot, and who teaches it", "Cover a lesson with a replacement tutor"] },
    attendance: { title: "Attendance", need: "timetable", lead: "Mark today’s lessons, and correct a mark when something was wrong.",
                  items: ["See which lessons still need a mark", "Mark attended or absent, with remarks", "Correct a mark, with a reason that is kept on record"] }
  };

  function tile(n, label, todo, href) {
    if (n == null) return "";                                        // not allowed to see this one: leave it out, don't show a 0
    var inner = '<span class="n">' + n + '</span><span class="l">' + esc(label) + '</span>', cls = 'card ch-tile' + (todo ? " todo" : "") + (todo && n === 0 ? " zero" : "");
    return href ? '<a class="' + cls + ' ch-link" href="' + esc(href) + '">' + inner + '</a>' : '<div class="' + cls + '">' + inner + '</div>';
  }
  function plural(n, one, many) { return n === 1 ? one : many; }

  function home(h) {
    var tt = h.can.timetable, out = [];
    out.push('<p class="ch-date">' + esc(new Date(h.today + "T00:00:00").toLocaleDateString("en-SG", { weekday: "long", day: "numeric", month: "long" })) + ' · ' + esc(h.org_name) + '</p>');
    if (tt) {
      out.push('<div class="ch-h">Today</div><div class="ch-grid">' +
        tile(h.today_lessons, plural(h.today_lessons, "lesson today", "lessons today")) +
        tile(h.today_marked, "marked") +
        tile(h.today_to_mark, "still to mark", true) + '</div>');
      out.push('<div class="ch-h">Needs attention</div><div class="ch-grid">' +
        tile(h.unmarked_past, plural(h.unmarked_past, "past lesson not marked", "past lessons not marked"), true) +
        tile(h.no_tutor_14d, plural(h.no_tutor_14d, "lesson with no tutor, next 14 days", "lessons with no tutor, next 14 days"), true) +
        (h.can.charges ? tile(h.pending_charges, plural(h.pending_charges, "charge to confirm", "charges to confirm"), true, "centre-attendance?id=" + encodeURIComponent(h.org_id) + "&tab=charges") : "") + '</div>');
    } else if (h.can.charges) {
      out.push('<div class="ch-h">Needs attention</div><div class="ch-grid">' + tile(h.pending_charges, plural(h.pending_charges, "charge to confirm", "charges to confirm"), true, "centre-attendance?id=" + encodeURIComponent(h.org_id) + "&tab=charges") + '</div>');
    }
    var more = (h.can.students ? tile(h.students_active, plural(h.students_active, "active student", "active students")) : "") +
               (tt ? tile(h.trials_this_month, plural(h.trials_this_month, "trial lesson this month", "trial lessons this month"), false, "centre-attendance?id=" + encodeURIComponent(h.org_id) + "&f=trial&view=month") : "");
    if (more) out.push('<div class="ch-h">At a glance</div><div class="ch-grid">' + more + '</div>');
    if (!tt && !h.can.students && !h.can.charges)
      out.push('<div class="card panel"><p class="ch-note" style="margin:0">Your account doesn’t have any centre screens switched on yet. Ask the centre owner to give you access to students or the timetable.</p></div>');
    else out.push('<p class="ch-note">The lists behind these numbers are coming next. Only counts are shown here, never money or contact details.</p>');
    $("ch").innerHTML = out.join("");
  }

  function soon(h, tab) {
    var s = SOON[tab];
    if (!s || !h.can[s.need]) {
      return card('<h2 style="font-size:17px;font-weight:800;margin:0 0 6px">Not available to you</h2><p class="ch-note">' +
        (s ? "Your account doesn’t include this screen." : "That page doesn’t exist.") + '</p><p style="margin:12px 0 0"><a class="btn btn-primary" href="centre?id=' + encodeURIComponent(h.org_id) + '">Back to Home</a></p>');
    }
    $("ch").innerHTML = '<div class="card ch-soon"><span class="ch-pill">Coming next</span><h2>' + esc(s.title) + '</h2><p>' + esc(s.lead) +
      '</p><ul>' + s.items.map(function (i) { return "<li>" + esc(i) + "</li>"; }).join("") + '</ul>' +
      '<a class="btn btn-primary" href="centre?id=' + encodeURIComponent(h.org_id) + '">Back to Home</a></div>';
  }

  async function init() {
    var q = new URLSearchParams(location.search), id = q.get("id"), tab = (q.get("tab") || "").toLowerCase();
    var cur = TL.org ? TL.org() : null;
    if (!id) id = cur && cur.kind === "centre" ? cur.id : null;
    if (!id) { location.replace("home"); return; }                                    // a solo login has no centre home
    if (cur && cur.kind === "centre" && cur.id === id && cur.role === "tutor") { location.replace("tutor"); return; }   // tutors have My lessons only
    var r = await window.sb.rpc("staff_home", { p_org: id });
    if (r.error) {
      if (missing(r.error)) return card('<h2 style="font-size:17px;font-weight:800;margin:0 0 6px">Not switched on yet</h2><p class="ch-note">The centre home needs <b>db/migration_staff_home.sql</b> run first.</p>');
      if (/NOT_FOUND/.test(r.error.message || "")) return card('<h2 style="font-size:17px;font-weight:800;margin:0 0 6px">Centre not available</h2><p class="ch-note">This centre doesn’t exist, or you aren’t an owner or staff member there.</p><p style="margin:12px 0 0"><a class="btn" href="org">Your centres</a></p>');
      return card('<p class="msg err" style="margin:0">' + esc(r.error.message || "Something went wrong.") + '</p>');
    }
    var h = r.data || {};
    if (h.status === "setup") {                                                        // a centre still being set up goes on with its wizard
      if (cur && cur.role === "owner") { location.replace("org?id=" + encodeURIComponent(id)); return; }
      return card('<h2 style="font-size:17px;font-weight:800;margin:0 0 6px">Still being set up</h2><p class="ch-note">The owner is still setting this centre up. Check back soon.</p>');
    }
    h.can = h.can || {};
    if (tab === "students" && h.can.students) { location.replace("centre-students?id=" + encodeURIComponent(id)); return; }   // (T3 step 2) an old link or bookmark
    if (tab === "attendance" && (h.can.timetable || h.can.charges)) { location.replace("centre-attendance?id=" + encodeURIComponent(id)); return; }   // (T3 step 3) an old link or bookmark
    if (tab) soon(h, tab); else home(h);
  }
  TL.requireAuth("centre", init);
})();
