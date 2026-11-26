// People tab for centre owners and staff (T3.9): the centre's people on one list (owner, staff, tutors) with role, status and invite state, and a link
// to the existing Users and permissions screen where things are changed. One database call, staff_people(org); the database decides who sees whom
// (the owner sees everyone, staff with Manage tutors see the tutors) and never returns an email, phone, pay or money. This page only draws it.
// Wording and grouping: assets/js/centre-people-core.js (unit-tested).
(function () {
  "use strict";
  var P = window.CentrePeopleCore, $ = function (id) { return document.getElementById(id); };
  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }
  function card(inner) { $("pp").innerHTML = '<div class="card panel pp-empty">' + inner + '</div>'; }

  function rowHtml(r) {
    var st = P.statusOf(r), inv = P.inviteLine(r);
    return '<div class="pp-row"><div class="pp-name">' + esc(r.name) + (r.you ? '<span class="pp-you">You</span>' : "") + '</div>' +
      '<div class="pp-meta"><span>' + esc(P.roleLabel(r.role)) + '</span><span class="pp-badge ' + st.key + '">' + esc(st.label) + '</span></div>' +
      (inv ? '<div class="pp-inv">' + esc(inv) + '</div>' : "") + '</div>';
  }
  function draw(id, d) {
    var rows = d.rows || [], out = ['<p class="pp-sum">' + esc(d.centre || "Your centre") + ' · ' + esc(P.summary(rows)) + '</p>'];
    P.group(rows).forEach(function (g) { out.push('<div class="pp-h">' + esc(g.title) + '</div><div class="card pp-list">' + g.rows.map(rowHtml).join("") + '</div>'); });
    if (!rows.length) out.push('<div class="card panel pp-empty"><p class="pp-note">No one has been added yet.</p></div>');
    out.push('<div class="card pp-link"><p>' + (d.can_users ? "Add people, change what staff can do, switch someone off or resend an invite on the Users and permissions screen." : "Resend invites to tutors on the Users and permissions screen.") +
      '</p><a class="btn btn-primary" href="org?id=' + encodeURIComponent(id) + '#users">Users and permissions</a></div>');
    out.push('<p class="pp-note">This list shows names, roles and invite status only: no contact details and no pay.</p>');
    $("pp").innerHTML = out.join("");
  }
  async function init() {
    var q = new URLSearchParams(location.search), id = q.get("id"), cur = TL.org ? TL.org() : null;
    if (!id) id = cur && cur.kind === "centre" ? cur.id : null;
    if (!id) { location.replace("home"); return; }
    if (cur && cur.kind === "centre" && cur.id === id && cur.role === "tutor") { location.replace("tutor"); return; }
    var r = await window.sb.rpc("staff_people", { p_org: id });
    if (r.error) {
      if (P.isMissing(r.error)) return card('<h2 style="font-size:17px;font-weight:800;margin:0 0 6px">Not switched on yet</h2><p class="pp-note">The People list needs <b>db/migration_slot_changes.sql</b> run first.</p>');
      return card('<p class="msg err" style="margin:0">' + esc(P.errorText(r.error)) + '</p><p style="margin:12px 0 0"><a class="btn" href="centre?id=' + encodeURIComponent(id) + '">Back to Home</a></p>');
    }
    if (!r.data || !Array.isArray(r.data.rows)) return card('<p class="msg err" style="margin:0">Couldn’t load the people list. Refresh and try again.</p>');
    draw(id, r.data);
  }
  TL.requireAuth("centre-people", init);
})();
