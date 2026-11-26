// Centre Timetable (T3 step 6, READ ONLY): the week at the centre as a day-by-day list, with holidays as a grey band and lessons nobody teaches
// flagged amber. One database call, staff_timetable(...), returns everything drawn here; this page never touches a table and changes nothing
// (slots, tutors and moving a lesson come in step 7). Any owner or staff member may look; the database decides, not this page.
// assets/js/centre-timetable-core.js holds the pure logic (days, chips, filters, wording) and is unit-tested.
//   centre-timetable?id=<centre>[&date=yyyy-mm-dd][&view=day|next14][&tutor=<id>][&student=<id>][&branch=<id>][&f=notutor][&mode=slots]
// T3 step 7 adds the "Weekly slots" view (assets/js/centre-slots.js): add / change / stop a weekly slot with its tutor and create the next 4 weeks of
// lessons. The lessons view below stays a list. T3 step 8 adds "Reassign or cover" to the lesson sheet (staff_reassign_lesson); moving a lesson to
// another day comes later.
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var esc = function (s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var TT = window.CentreTimetableCore;
  var orgId = null, today = "", seq = 0, sheetOpener = null, cur = null, lastRes = null, firstLoad = true, studentsAll = [],
      state = TT.fromQuery(new URLSearchParams("")), deep = false, mode = "lessons", stale = false, started = false,
      tcc = window.TutorChangesCore, changes = {};          // lessons a tutor changed in the last 7 days (T6 step 2), by lesson id

  function card(inner) { $("tt").innerHTML = '<div class="card tt-block">' + inner + '</div>'; }
  function plural(n, a, b) { return n === 1 ? a : b; }
  function localToday() { var d = new Date(); return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10); }

  // ---------------------------------------------------------------- controls
  function controls() {
    $("tt-view").querySelectorAll("[data-v]").forEach(function (b) { var on = b.dataset.v === state.view; b.classList.toggle("on", on); b.setAttribute("aria-pressed", on); });
    $("tt-when").textContent = TT.rangeLabel(state.view, state.anchor || localToday(), today || localToday());
    var n = lastRes && lastRes.counts ? lastRes.counts.n_notutor : 0;
    $("tt-nn").textContent = n; $("tt-notutor").setAttribute("aria-pressed", state.notutor);
    $("tt-clear").hidden = !TT.anyFilter(state);
  }
  function drawTutors(list) {
    var sel = $("tt-tutor"), keep = state.tutor;
    sel.innerHTML = '<option value="">All tutors</option>' + (list || []).map(function (t) { return '<option value="' + esc(t.id) + '">' + esc(t.name) + '</option>'; }).join("");
    sel.value = keep; if (sel.value !== keep) { state.tutor = ""; sel.value = ""; }
  }
  function drawStudents(list, more) {
    studentsAll = list || [];
    var f = $("tt-find"); f.hidden = studentsAll.length <= 12;
    fillStudents(f.hidden ? "" : f.value);
    $("tt-student").title = more ? "Showing the first 300 students with lessons in this period" : "";
  }
  function fillStudents(q) {
    var sel = $("tt-student"), keep = state.student, list = TT.matchStudents(studentsAll, q);
    if (keep && !list.some(function (s) { return s.id === keep; })) { var k = studentsAll.filter(function (s) { return s.id === keep; })[0]; if (k) list = [k].concat(list); }
    sel.innerHTML = '<option value="">All students</option>' + list.map(function (s) { return '<option value="' + esc(s.id) + '">' + esc(s.name) + '</option>'; }).join("");
    sel.value = keep; if (sel.value !== keep) { state.student = ""; sel.value = ""; }
  }
  function drawBranches(list) {
    var sel = $("tt-branch"), keep = state.branch;
    sel.hidden = !(list && list.length);                                         // a remote 1-to-1 centre has no branches: no control at all
    sel.innerHTML = '<option value="">Holidays: all branches</option>' + (list || []).map(function (b) { return '<option value="' + esc(b.id) + '">' + esc(b.name) + '</option>'; }).join("");
    sel.value = keep; if (sel.value !== keep) { state.branch = ""; sel.value = ""; }
  }

  // ---------------------------------------------------------------- the list
  var HOL_ICON = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M16 3v4M8 3v4M3 11h18"/></svg>';
  function rowHtml(r) {
    var tl = TT.tutorLine(r), chips = TT.chips(r), tc = tcc && changes[r.lesson_id] ? tcc.chip(changes[r.lesson_id]) : null;
    if (tc) chips.push(tc);                                                          // the amber "Changed by tutor" flag
    return '<button type="button" class="tt-row' + (r.no_tutor ? ' notutor' : '') + (r.cancelled ? ' off' : '') + '" data-id="' + esc(r.lesson_id) + '">' +
      '<span class="tt-time">' + esc(TT.timeLabel(r.start_time)) + (r.end_time ? '<span>' + esc(TT.timeLabel(r.end_time)) + '</span>' : '') + '</span>' +
      '<span class="tt-main"><span class="tt-name">' + esc(r.student_name) + (r.student_level ? ' · ' + esc(r.student_level) : '') + '</span>' +
      '<span class="tt-sub' + (tl.warn ? ' none' : '') + '">' + esc(tl.text) + '</span></span>' +
      (chips.length ? '<span class="tt-chips">' + chips.map(function (c) { return '<span class="tt-chip ' + c.tone + '">' + esc(c.text) + '</span>'; }).join("") + '</span>' : '') +
      '<svg class="tt-chev" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="m9 18 6-6-6-6"/></svg></button>';
  }
  function dayHtml(d, multi) {
    var out = "", n = d.rows.length;
    if (multi) out += '<div class="tt-day' + (d.date === today ? ' today' : '') + '"><span>' + esc(TT.dayLabel(d.date, today)) + '</span><span>' + (n ? n + ' ' + plural(n, 'lesson', 'lessons') : '') + '</span></div>';
    if (d.holidays.length) out += '<div class="tt-band" role="note">' + HOL_ICON + '<span>' + esc(TT.bandText(d.holidays)) + '</span></div>';
    if (n) out += '<div class="card tt-list">' + d.rows.map(rowHtml).join("") + '</div>';
    else if (multi && !d.holidays.length) out += '<p class="tt-none">No lessons</p>';
    return out;
  }
  function draw(res) {
    lastRes = res; today = res.today;
    var r = TT.range(state.view, state.anchor);
    drawTutors(res.tutors); drawStudents(res.students, res.students_more); drawBranches(res.branches);
    controls();
    var rows = res.rows || [], total = res.total || 0, pages = TT.pageCount(total, res.size);
    if (res.page > pages && total) { state.page = pages; return load(); }
    var everything = total <= res.size && !TT.anyFilter(state);                        // one page and no filter: list every day, empty ones too
    var ds = TT.days(rows, res.holidays, r.from, r.to, everything), multi = state.view !== "day";
    if (!rows.length && !res.holidays.length) {
      var e = TT.emptyText(state);
      $("tt-list").innerHTML = '<div class="card"><div class="tt-empty"><h3>' + esc(e.title) + '</h3><p>' + esc(e.hint) + '</p></div></div>';
    } else {
      $("tt-list").innerHTML = ds.map(function (d) { return dayHtml(d, multi); }).join("") +
        (!rows.length ? '<div class="card"><div class="tt-empty"><h3>' + esc(TT.emptyText(state).title) + '</h3><p>' + esc(TT.emptyText(state).hint) + '</p></div></div>' : "");
    }
    $("tt-count").textContent = TT.countText(total, res.counts, state);
    $("tt-pager").hidden = total <= res.size;
    $("tt-pl").textContent = TT.pagerLabel(res.page, res.size, total);
    $("tt-pp").disabled = res.page <= 1; $("tt-pn").disabled = res.page >= pages;
    syncUrl();
  }
  function syncUrl() {                                          // a reload, or a copied link, comes back to the same view and filters
    try { history.replaceState(null, "", location.pathname + "?" + TT.toQuery(orgId, state, today) + (mode === "slots" ? "&mode=slots" : "")); } catch (e) {}
  }
  async function load() {
    var mine = ++seq;
    if (!state.anchor) state.anchor = localToday();
    controls();
    var res = await window.sb.rpc("staff_timetable", TT.args(orgId, state));
    if (mine !== seq) return;                                                        // a newer choice is already on its way
    if (res.error) return failure(res.error);
    if (!res.data || !res.data.counts) { $("tt-count").textContent = "Couldn’t load the timetable. Refresh and try again."; return; }
    changes = {};
    if (res.data.can_edit && tcc) {                                                  // the amber flags need manage_timetable; if it can't be read the page just shows none
      try { var tcr = await window.sb.rpc("staff_tutor_changes", { p_org: orgId }); if (mine !== seq) return; if (!tcr.error && tcr.data) changes = tcc.byLesson(tcr.data.rows); } catch (e) { changes = {}; }
    }
    if (firstLoad) {                                                                 // the first answer tells us the centre's own today
      firstLoad = false;
      if (!deep && res.data.today !== state.anchor) { state.anchor = res.data.today; today = res.data.today; return load(); }
    }
    draw(res.data);
    return res.data;
  }
  function failure(err) {
    var m = (err && err.message) || "";
    if (TT.isMissing(err)) return card('<h2 style="font-size:17px;font-weight:800;margin:0 0 6px">Not switched on yet</h2><p class="tt-note">The centre Timetable needs <b>db/migration_staff_timetable.sql</b> run first.</p>');
    if (/NOT_FOUND/.test(m) && !$("tt-list").innerHTML) return card('<h2 style="font-size:17px;font-weight:800;margin:0 0 6px">Centre not available</h2><p class="tt-note">This centre doesn’t exist, or you aren’t an owner or staff member there.</p><p style="margin:12px 0 0"><a class="btn" href="org">Your centres</a></p>');
    $("tt-count").textContent = TT.errorText(err);
  }

  // ---------------------------------------------------------------- the lesson sheet
  function lockBody(on) { document.body.classList.toggle("sheet-lock", on); }
  function openSheet(trigger) { sheetOpener = trigger || sheetOpener; $("tt-sheet").classList.add("on"); lockBody(true); $("tt-sx").focus(); }
  function closeSheet() { $("tt-sheet").classList.remove("on"); lockBody(false); cur = null; if (sheetOpener && sheetOpener.focus && document.contains(sheetOpener)) sheetOpener.focus(); sheetOpener = null; }
  function find(id) { var rows = (lastRes && lastRes.rows) || []; for (var i = 0; i < rows.length; i++) if (rows[i].lesson_id === id) return rows[i]; return null; }
  function open(id, trigger) {
    var r = find(id); if (!r) return;
    cur = r; reForm = null;
    $("tt-st").textContent = r.student_name;
    $("tt-sm").textContent = TT.dayLabel(r.lesson_date, today);
    var ra = TT.reassignState(lastRes, r), tf = tcc ? tcc.sheetFact(changes[r.lesson_id], lastRes.today) : null;
    var html = '<div class="tt-h">Lesson</div><div class="tt-facts">' + TT.facts(r).concat(tf ? [tf] : []).map(function (f) {
      return '<div><span>' + esc(f[0]) + '</span><span' + (f[0] === "Tutor" && r.no_tutor ? ' class="warn"' : (f[0] === "Moved by" || f[0] === "Cancelled by" || f[0] === "Put back by" ? ' class="warn"' : '')) + '>' + esc(f[1]) + '</span></div>';
    }).join("") + '</div><div class="tt-acts">' +
      '<a class="btn" href="centre-attendance?id=' + encodeURIComponent(orgId) + '&date=' + esc(r.lesson_date) + '&view=day">Open in Attendance</a>' +
      '<button type="button" class="btn" id="tt-onlyst">Show only ' + esc(r.student_name) + '</button>' +
      (r.tutor_id ? '<button type="button" class="btn" id="tt-onlytu">Show only ' + esc(r.tutor_name || "this tutor") + '</button>' : '') +
      (ra.label ? '<button type="button" class="btn btn-primary" id="tt-reassign">' + esc(ra.label) + '</button>' : '') + '</div>' +
      (ra.note ? '<p class="tt-ro" id="tt-ranote">' + esc(ra.note) + '</p>' : '') +
      '<p class="tt-ro">To change the day, time or tutor of every lesson in a weekly slot, use <b>Weekly slots</b>. Moving a lesson to another day is coming next.</p>';
    $("tt-sb").innerHTML = html; openSheet(trigger);
  }

  // ---------------------------------------------------------------- Reassign or cover (one lesson)
  var reForm = null, reBusy = false;
  function reHtml(r, ra) {
    var opts = TT.coverOptions(lastRes, r), first = !r.tutor_id, isClass = !!r.session_id;
    var h = '<form class="sl-form" id="tt-rf" novalidate><div class="tt-h">' + esc(ra.label) + '</div>' +
      '<p class="tt-note" style="margin:0 0 12px">' + esc(r.student_name) + ' · ' + esc(TT.dayLabel(r.lesson_date, today)) + ' · ' + esc(TT.timeRange(r)) +
      (first ? '. Nobody teaches it yet.' : '. Taught by ' + esc(r.tutor_name || "a former tutor") + '.') + '</p>' +
      '<div class="field"><label for="tt-rt">' + (first ? 'Tutor' : 'New tutor') + '</label><select id="tt-rt"><option value="">Choose a tutor</option>' +
      opts.map(function (t) { return '<option value="' + esc(t.id) + '"' + (reForm.tutor === t.id ? ' selected' : '') + '>' + esc(t.name) + '</option>'; }).join("") +
      '</select><div class="sl-err" id="tt-re-tutor" role="alert" hidden></div></div>';
    if (!first) {
      h += '<fieldset class="tt-modes"><legend class="tt-h">What should happen?</legend>' +
        '<label class="tt-mode-opt"><input type="radio" name="tt-rm" value="cover"' + (reForm.mode === "cover" ? ' checked' : '') + '><span><b>Cover this lesson only</b>' +
        '<span>' + esc(r.tutor_name || "The tutor") + ' stays on the weekly slot. Next week is unchanged.</span></span></label>' +
        '<label class="tt-mode-opt"><input type="radio" name="tt-rm" value="reassign"' + (reForm.mode === "reassign" ? ' checked' : '') + '><span><b>Give this lesson to them</b>' +
        '<span>It becomes theirs. The weekly slot is not changed.</span></span></label></fieldset>' +
        '<label class="tt-chk" id="tt-rlw"' + (reForm.mode === "reassign" ? '' : ' hidden') + '><input type="checkbox" id="tt-rl"' + (reForm.links ? ' checked' : '') + '><span>Also make them ' +
        esc(r.student_name) + '’s assigned tutor. ' + esc(r.tutor_name || "The old tutor") + ' stays assigned if they still teach ' + esc(r.student_name) + ' in another slot or lesson; otherwise they are replaced.</span></label>';
    }
    h += '<div class="field"><label for="tt-rr">Reason' + (first ? ' <span class="opt">Optional</span>' : '') + '</label><input id="tt-rr" type="text" maxlength="' + TT.REASON_MAX + '" autocomplete="off" ' +
      'placeholder="e.g. Tutor is unwell" value="' + esc(reForm.reason) + '"><div class="sl-err" id="tt-re-reason" role="alert" hidden></div></div>' +
      (isClass ? '<p class="tt-note" style="margin:0 0 4px">This lesson is part of a class: every student’s lesson that day moves together.</p>' : '') +
      '<div class="sl-err" id="tt-re" role="alert" hidden></div>' +
      '<div class="sl-acts"><button class="btn btn-primary" type="submit" id="tt-rs">' + (first ? 'Assign tutor' : 'Save') + '</button>' +
      '<button class="btn" type="button" id="tt-rb">Back</button></div></form>';
    return h;
  }
  function openReassign() {
    var r = cur; if (!r) return;
    var ra = TT.reassignState(lastRes, r); if (!ra.label) return;
    reForm = { tutor: "", mode: "cover", reason: "", links: false };
    $("tt-sb").innerHTML = reHtml(r, ra);
    $("tt-rt").focus();
  }
  function reRead() {
    reForm.tutor = $("tt-rt").value; reForm.reason = $("tt-rr").value;
    var m = $("tt-sb").querySelector('input[name="tt-rm"]:checked'); if (m) reForm.mode = m.value;
    reForm.links = !!($("tt-rl") && $("tt-rl").checked && reForm.mode === "reassign");
  }
  function reShow(id, msg) { var e = $(id); if (!e) return; e.hidden = !msg; e.textContent = msg || ""; }
  async function reSave(e) {
    if (e) e.preventDefault();
    if (!reForm || !cur || reBusy) return;
    var r = cur; reRead();
    ["tt-re-tutor", "tt-re-reason", "tt-re"].forEach(function (i) { reShow(i, ""); });
    var bad = TT.checkReassign(r, reForm);
    if (bad) { var f = !reForm.tutor || reForm.tutor === r.tutor_id ? "tt-re-tutor" : "tt-re-reason"; reShow(f, bad); $(f === "tt-re-tutor" ? "tt-rt" : "tt-rr").focus(); return; }
    reBusy = true; var b = $("tt-rs"); b.disabled = true;
    var res = await window.sb.rpc("staff_reassign_lesson", TT.reassignArgs(r, reForm));
    reBusy = false; b.disabled = false;
    if (res.error) { reShow("tt-re", TT.reassignErrorText(res.error)); $("tt-re").scrollIntoView({ block: "nearest" }); return; }
    var form = reForm; closeSheet(); TL.toast(TT.reassignedText(res.data, form), "ok"); load();
  }

  // ---------------------------------------------------------------- Lessons | Weekly slots
  function showMode(m, first) {
    mode = m === "slots" ? "slots" : "lessons";
    $("tt-mode").querySelectorAll("[data-m]").forEach(function (b) { var on = b.dataset.m === mode; b.classList.toggle("on", on); b.setAttribute("aria-pressed", on); });
    $("tt").hidden = mode === "slots"; $("sl").hidden = mode !== "slots";
    if (mode === "slots") { if (!first) { try { history.replaceState(null, "", location.pathname + "?id=" + encodeURIComponent(orgId) + "&mode=slots"); } catch (e) {} } window.CentreSlots.show(); }
    else if (!first) { closeSheet(); window.CentreSlots.close(); if (stale || !started) { stale = false; started = true; load(); } else syncUrl(); }
  }

  // ---------------------------------------------------------------- wiring
  function go(anchor) { state.anchor = anchor; state.page = 1; load(); }
  function pick(patch) { Object.keys(patch).forEach(function (k) { state[k] = patch[k]; }); state.page = 1; load(); }
  function wire() {
    $("tt-mode").addEventListener("click", function (e) { var b = e.target.closest("[data-m]"); if (b && b.dataset.m !== mode) showMode(b.dataset.m); });
    $("tt-prev").addEventListener("click", function () { go(TT.shift(state.view, state.anchor || today, -1)); });
    $("tt-next").addEventListener("click", function () { go(TT.shift(state.view, state.anchor || today, 1)); });
    $("tt-today").addEventListener("click", function () { go(today || localToday()); });
    $("tt-view").addEventListener("click", function (e) {
      var b = e.target.closest("[data-v]"); if (!b || b.dataset.v === state.view) return;
      var t = today || localToday();
      pick({ view: b.dataset.v, anchor: b.dataset.v === "next14" ? t : (state.view === "next14" ? t : state.anchor) });   // "14 days" always starts today
    });
    $("tt-tutor").addEventListener("change", function () { pick({ tutor: $("tt-tutor").value }); });
    $("tt-student").addEventListener("change", function () { pick({ student: $("tt-student").value }); });
    $("tt-branch").addEventListener("change", function () { pick({ branch: $("tt-branch").value }); });
    $("tt-find").addEventListener("input", function () { fillStudents($("tt-find").value); });
    $("tt-notutor").addEventListener("click", function () { pick({ notutor: !state.notutor }); });
    $("tt-clear").addEventListener("click", function () { $("tt-find").value = ""; pick({ tutor: "", student: "", notutor: false }); });
    $("tt-list").addEventListener("click", function (e) { var b = e.target.closest("[data-id]"); if (b) open(b.dataset.id, b); });
    $("tt-pp").addEventListener("click", function () { if (state.page > 1) { state.page--; load(); window.scrollTo(0, 0); } });
    $("tt-pn").addEventListener("click", function () { state.page++; load(); window.scrollTo(0, 0); });
    $("tt-sx").addEventListener("click", closeSheet);
    $("tt-sheet").addEventListener("click", function (e) { if (e.target === $("tt-sheet")) closeSheet(); });
    $("tt-sb").addEventListener("click", function (e) {
      if (!cur) return;
      if (e.target.id === "tt-onlyst") { var s = cur.student_id; closeSheet(); pick({ student: s }); }
      if (e.target.id === "tt-onlytu") { var t = cur.tutor_id; closeSheet(); pick({ tutor: t }); }
      if (e.target.closest("#tt-reassign")) openReassign();
      if (e.target.id === "tt-rb") open(cur.lesson_id);
    });
    $("tt-sb").addEventListener("submit", reSave);
    $("tt-sb").addEventListener("change", function (e) {
      if (e.target.name === "tt-rm") { var on = e.target.value === "reassign"; if ($("tt-rlw")) { $("tt-rlw").hidden = !on; if (!on && $("tt-rl")) $("tt-rl").checked = false; } }
    });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && $("tt-sheet").classList.contains("on")) closeSheet(); });
  }

  function init() {
    var q = new URLSearchParams(location.search), id = q.get("id"), o = TL.org ? TL.org() : null;
    if (!id) id = o && o.kind === "centre" ? o.id : null;
    if (!id) { location.replace("home"); return; }                                                     // a solo login has no centre pages
    if (o && o.kind === "centre" && o.id === id && o.role === "tutor") { location.replace("tutor"); return; }
    orgId = id;
    state = TT.fromQuery(q); deep = !!state.anchor;
    if (state.view === "next14" && !state.anchor) state.anchor = localToday();
    wire(); controls();
    window.CentreSlots.init(orgId, { lessonsChanged: function () { stale = true; }, showLessons: function () { state.anchor = today || localToday(); state.view = "next14"; stale = false; showMode("lessons"); started = true; state.page = 1; load(); } });
    if (q.get("mode") === "slots") { started = false; showMode("slots", true); } else { started = true; load(); }
  }
  TL.requireAuth("centre-timetable", init);
})();
