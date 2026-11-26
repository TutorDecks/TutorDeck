// Centre Attendance (T3 step 3): a day or a week of lessons, who marked what, mark a lesson, correct a mark. Every read and write goes through three
// database functions (staff_lessons, staff_mark_attendance, staff_correct_attendance); this page never touches a table. What a person may do is decided
// there (any owner / staff may look; manage_timetable is needed to mark or correct; "not before its day" and "never over someone else's mark" are
// enforced by the lessons table itself); assets/js/centre-attendance-core.js only words the answers and saves a round trip.
// The second tab, Charges (T3 step 4), is its own file: assets/js/centre-charges.js, started at the end of init().
//   centre-attendance?id=<centre>[&date=yyyy-mm-dd][&view=day|week][&f=unmarked|marked]
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var esc = function (s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var CA = window.CentreAttendanceCore;
  var orgId = null, today = "", seq = 0, sheetOpener = null, cur = null, lastRes = null, firstLoad = true, tutorsDrawn = false,
      state = { view: "day", anchor: null, status: "all", tutor: "", page: 1 };

  function card(inner) { $("ca").innerHTML = '<div class="card ca-block">' + inner + '</div>'; }
  function say(id, t) { $(id).textContent = t || ""; }
  function plural(n, a, b) { return n === 1 ? a : b; }
  function localToday() { var d = new Date(); return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10); }

  // ---------------------------------------------------------------- the list
  function controls() {
    $("ca-view").querySelectorAll("[data-v]").forEach(function (b) { var on = b.dataset.v === state.view; b.classList.toggle("on", on); b.setAttribute("aria-pressed", on); });
    var c = (lastRes && lastRes.counts) || null;
    $("ca-seg").innerHTML = CA.STATUS_FILTERS.map(function (f) {
      var n = c ? c[f.key] : null;
      return '<button type="button" data-f="' + f.key + '" class="' + (state.status === f.key ? "on" : "") + '" aria-pressed="' + (state.status === f.key) + '">' + f.label +
             (n == null ? "" : ' <span class="seg-n">' + n + '</span>') + '</button>';
    }).join("");
    $("ca-when").textContent = CA.rangeLabel(state.view, state.anchor || localToday(), today || localToday());
  }
  function drawTutors(list) {
    var sel = $("ca-tutor"), keep = state.tutor;
    sel.innerHTML = '<option value="">All tutors</option>' + (list || []).map(function (t) { return '<option value="' + esc(t.id) + '">' + esc(t.name) + '</option>'; }).join("");
    sel.value = keep; if (sel.value !== keep) { state.tutor = ""; sel.value = ""; }
    tutorsDrawn = true;
  }
  function rowHtml(r) {
    var c = CA.chip(r), tutor = r.tutor_name ? esc(r.tutor_name) : "No tutor yet";
    return '<button type="button" class="ca-row" data-id="' + esc(r.lesson_id) + '">' +
      '<span class="ca-time">' + esc(CA.timeLabel(r.start_time)) + (r.end_time ? '<span>' + esc(CA.timeLabel(r.end_time)) + '</span>' : '') + '</span>' +
      '<span class="ca-main"><span class="ca-name">' + esc(r.student_name) + (r.student_level ? ' · ' + esc(r.student_level) : '') + '</span>' +
      '<span class="ca-sub' + (r.tutor_name ? '' : ' none') + '">' + tutor + '</span></span>' +
      (r.trial ? '<span class="ca-chip trial">Trial</span>' : '') +
      '<span class="ca-chip ' + c.tone + '">' + esc(c.text) + '</span>' +
      '<svg class="ca-chev" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="m9 18 6-6-6-6"/></svg></button>';
  }
  function draw(res) {
    lastRes = res; today = res.today;
    if (firstLoad) {                                                         // the first answer tells us the centre's own today
      firstLoad = false;
      if (!state.anchor) { state.anchor = res.today; if (state.anchor !== localToday()) return load(); }
    }
    if (!tutorsDrawn) drawTutors(res.tutors);
    controls();
    var rows = res.rows || [], total = res.total || 0, pages = CA.pageCount(total, res.size);
    if (res.page > pages && total) { state.page = pages; return load(); }
    if (!rows.length) {
      var e = CA.emptyText(state.status, state.view);
      $("ca-list").innerHTML = '<div class="card"><div class="ca-empty"><h3>' + esc(e.title) + '</h3><p>' + esc(e.hint) + '</p></div></div>';
    } else {
      $("ca-list").innerHTML = CA.byDay(rows).map(function (d) {
        return (state.view === "week" ? '<div class="ca-day">' + esc(CA.dayLabel(d.date, today)) + '</div>' : '') +
               '<div class="card ca-list">' + d.rows.map(rowHtml).join("") + '</div>';
      }).join("");
    }
    $("ca-count").textContent = total ? total + " " + plural(total, "lesson", "lessons") : "";
    $("ca-pager").hidden = total <= res.size;
    $("ca-pl").textContent = CA.pagerLabel(res.page, res.size, total);
    $("ca-pp").disabled = res.page <= 1; $("ca-pn").disabled = res.page >= pages;
  }
  async function load() {
    var mine = ++seq, anchor = state.anchor || localToday(), r = CA.range(state.view, anchor);
    controls();
    var res = await window.sb.rpc("staff_lessons", { p_org: orgId, p_from: r.from, p_to: r.to, p_tutor: state.tutor || null, p_status: state.status,
                                                    p_page: state.page, p_size: CA.PAGE_SIZE });
    if (mine !== seq) return;                                                        // a newer choice is already on its way
    if (res.error) return failure(res.error);
    if (!res.data || !res.data.counts) { $("ca-count").textContent = "Couldn’t load the lessons. Refresh and try again."; return; }
    draw(res.data);
    return res.data;
  }
  function failure(err) {
    var m = (err && err.message) || "";
    if (CA.isMissing(err)) return card('<h2 style="font-size:17px;font-weight:800;margin:0 0 6px">Not switched on yet</h2><p class="ca-note">The centre Attendance screen needs <b>db/migration_staff_attendance.sql</b> run first.</p>');
    if (/NOT_FOUND/.test(m)) return card('<h2 style="font-size:17px;font-weight:800;margin:0 0 6px">Centre not available</h2><p class="ca-note">This centre doesn’t exist, or you aren’t an owner or staff member there.</p><p style="margin:12px 0 0"><a class="btn" href="org">Your centres</a></p>');
    $("ca-count").textContent = CA.errorText(err);
  }

  // ---------------------------------------------------------------- the sheet
  function lockBody(on) { document.body.classList.toggle("sheet-lock", on); }
  function openSheet(trigger) { sheetOpener = trigger || sheetOpener; $("ca-sheet").classList.add("on"); lockBody(true); $("ca-sx").focus(); }
  function closeSheet() { $("ca-sheet").classList.remove("on"); lockBody(false); cur = null; if (sheetOpener && sheetOpener.focus && document.contains(sheetOpener)) sheetOpener.focus(); sheetOpener = null; }
  function find(id) { var rows = (lastRes && lastRes.rows) || []; for (var i = 0; i < rows.length; i++) if (rows[i].lesson_id === id) return rows[i]; return null; }

  function renderSheet() {
    var r = cur, a = CA.actions(r, lastRes && lastRes.can_mark), html = "", c = CA.chip(r);
    $("ca-st").textContent = r.student_name;
    $("ca-sm").textContent = [CA.dayLabel(r.lesson_date, today), CA.timeRange(r)].join(" · ");
    html += '<div class="ca-h">Lesson</div><div class="ca-facts">' +
      '<div><span>Status</span><span>' + esc(c.text) + '' + '</span></div>' +
      (r.student_level ? '<div><span>Level</span><span>' + esc(r.student_level) + '</span></div>' : '') +
      (r.subject ? '<div><span>Subject</span><span>' + esc(r.subject) + '</span></div>' : '') +
      '<div><span>Tutor</span><span>' + (r.tutor_name ? esc(r.tutor_name) : 'No tutor yet') + '</span></div>' +
      (r.attendance != null ? '<div><span>Marked</span><span>' + esc(CA.markedLine(r).replace(/^Marked\s*/, "") || "Yes") + '</span></div>' : '') +
      (r.remarks ? '<div><span>Remarks</span><span>' + esc(r.remarks) + '</span></div>' : '') + '</div>';
    // Trial: anyone may SEE it (badge above); only staff with manage_timetable get the switch (the database decides, can_mark tells us)
    html += '<div class="ca-h">Trial lesson</div>' + (lastRes && lastRes.can_mark
      ? '<label class="ca-opt ca-trial" for="ca-trial"><input type="checkbox" id="ca-trial"' + (r.trial ? ' checked' : '') + '><span>This is a trial lesson</span></label>'
      : '<p class="ca-ro" style="margin-top:0">' + (r.trial ? 'This is a trial lesson.' : 'This is not a trial lesson.') + ' Ask the centre owner if you need to change it.</p>') +
      '<p class="ca-note" style="margin-top:8px">' + esc(CA.TRIAL_HELP) + '</p>' +
      (CA.pastMonthNote(r.lesson_date, today) ? '<p class="ca-note" style="margin-top:6px">' + esc(CA.pastMonthNote(r.lesson_date, today)) + '</p>' : '') +
      '<div class="ca-err" id="ca-terr" role="alert"></div>';
    if (r.charge_pending) {
      var CH = window.CentreCharges, mine = CH && CH.enabled();
      html += '<p class="ca-pend">The charge for this lesson hasn’t been confirmed yet. ' + (mine ? '' : 'Whoever looks after invoicing sets it.') + '</p>' +
        (mine ? '<div class="ca-marks"><button type="button" class="btn" id="ca-tocharges">Go to Charges</button></div>' : '');
    }
    if (a.note) html += '<p class="ca-ro">' + esc(a.note) + '</p>';
    if (a.mark) {
      html += '<div class="ca-h">Mark this lesson</div><div class="field"><label for="ca-rm">Remarks <span class="opt">Optional</span></label>' +
        '<textarea id="ca-rm" maxlength="' + CA.REMARKS_MAX + '" placeholder="e.g. Finished the fractions worksheet"></textarea></div>' +
        '<div class="ca-marks" id="ca-marks">' + CA.MARKS.map(function (m, i) {
          return '<button type="button" class="btn' + (i === 0 ? ' btn-primary' : '') + '" data-mark="' + m.key + '">' + esc(m.label) + '</button>';
        }).join("") + '</div><div class="ca-err" id="ca-merr" role="alert"></div>';
    }
    if (a.correct) html += '<div class="ca-marks"><button type="button" class="btn btn-primary" id="ca-correct">Correct this mark…</button></div>' +
      '<p class="ca-note" style="margin-top:10px">A correction needs a reason and is kept on record with your name.</p>';
    $("ca-sb").innerHTML = html;
  }
  function open(id, trigger) {
    var r = find(id); if (!r) return;
    cur = r; renderSheet(); openSheet(trigger);
  }
  function busy(on) { document.querySelectorAll("#ca-marks button, #cc-save").forEach(function (b) { b.disabled = on; }); }
  async function doMark(key) {
    var rm = $("ca-rm") ? $("ca-rm").value : "", chk = CA.checkMark(key, rm);
    if (!chk.ok) { say("ca-merr", chk.error); return; }
    say("ca-merr", ""); busy(true);
    var id = cur.lesson_id, name = cur.student_name;
    var r = await window.sb.rpc("staff_mark_attendance", { p_lesson: id, p_attendance: key, p_remarks: rm.trim() ? rm : null });
    busy(false);
    if (r.error) { say("ca-merr", CA.errorText(r.error)); if (/NOT_FOUND|ALREADY_MARKED|CANCELLED|TOO_EARLY/.test(r.error.message || "")) load(); return; }
    TL.toast(name + " marked " + CA.mark(key).label.toLowerCase(), "ok");
    closeSheet(); await load();
  }

  // ---------------------------------------------------------------- the trial switch
  async function doTrial(box) {
    var want = box.checked, id = cur.lesson_id, name = cur.student_name;
    say("ca-terr", ""); box.disabled = true;
    var r = await window.sb.rpc("staff_set_trial", { p_lesson: id, p_trial: want });
    box.disabled = false;
    if (r.error) {
      box.checked = !want;                                                          // nothing changed: show the truth
      say("ca-terr", CA.isMissing(r.error) ? "Trial flags need db/migration_staff_trials.sql run first." : CA.errorText(r.error));
      if (/NOT_FOUND|NO_CHANGE/.test(r.error.message || "")) load();
      return;
    }
    TL.toast(name + (want ? " flagged as a trial lesson" : " is no longer a trial lesson"), "ok");
    var res = await load();                                                         // the list (and the Trial count) now tell the truth
    var fresh = find(id);
    if (fresh && cur && cur.lesson_id === id) { cur = fresh; renderSheet(); }
    else if (!fresh) closeSheet();                                                  // it left the current filter
    return res;
  }

  // ---------------------------------------------------------------- correct a mark
  function openCorrect() {
    var r = cur, m = CA.mark(r.attendance);
    $("cc-title").textContent = "Correct " + r.student_name;
    $("cc-text").textContent = "Currently marked " + (m ? m.label.toLowerCase() : "something else") + ". Choose what it should be and say why.";
    $("cc-opts").innerHTML = '<legend>Change it to</legend>' + CA.otherMarks(r.attendance).map(function (o, i) {
      return '<label class="ca-opt"><input type="radio" name="cc-m" value="' + o.key + '"' + (i === 0 ? ' checked' : '') + '>' + esc(o.label) + '</label>';
    }).join("");
    $("cc-reason").value = ""; say("cc-msg", ""); $("ca-cor").classList.add("on"); $("cc-reason").focus();
  }
  async function saveCorrect() {
    var pick = document.querySelector('input[name="cc-m"]:checked'), val = pick ? pick.value : "", chk = CA.checkCorrection(cur.attendance, val, $("cc-reason").value);
    if (!chk.ok) { say("cc-msg", chk.error); return; }
    say("cc-msg", ""); busy(true);
    var id = cur.lesson_id, name = cur.student_name;
    var r = await window.sb.rpc("staff_correct_attendance", { p_lesson: id, p_attendance: val, p_reason: chk.reason });
    busy(false);
    if (r.error) { say("cc-msg", CA.errorText(r.error)); return; }
    $("ca-cor").classList.remove("on");
    TL.toast(name + " corrected to " + CA.mark(val).label.toLowerCase(), "ok");
    closeSheet(); await load();
  }

  // ---------------------------------------------------------------- wiring
  function go(anchor) { state.anchor = anchor; state.page = 1; load(); }
  function wire() {
    $("ca-prev").addEventListener("click", function () { go(CA.shift(state.view, state.anchor || today, -1)); });
    $("ca-next").addEventListener("click", function () { go(CA.shift(state.view, state.anchor || today, 1)); });
    $("ca-today").addEventListener("click", function () { go(today || localToday()); });
    $("ca-view").addEventListener("click", function (e) { var b = e.target.closest("[data-v]"); if (b && b.dataset.v !== state.view) { state.view = b.dataset.v; state.page = 1; load(); } });
    $("ca-seg").addEventListener("click", function (e) { var b = e.target.closest("[data-f]"); if (b) { state.status = b.dataset.f; state.page = 1; load(); } });
    $("ca-tutor").addEventListener("change", function () { state.tutor = $("ca-tutor").value; state.page = 1; load(); });
    $("ca-list").addEventListener("click", function (e) { var b = e.target.closest("[data-id]"); if (b) open(b.dataset.id, b); });
    $("ca-pp").addEventListener("click", function () { if (state.page > 1) { state.page--; load(); window.scrollTo(0, 0); } });
    $("ca-pn").addEventListener("click", function () { state.page++; load(); window.scrollTo(0, 0); });
    $("ca-sx").addEventListener("click", closeSheet);
    $("ca-sheet").addEventListener("click", function (e) { if (e.target === $("ca-sheet")) closeSheet(); });
    $("ca-sb").addEventListener("click", function (e) {
      if (!cur) return;
      if (e.target.id === "ca-trial") { doTrial(e.target); return; }
      var m = e.target.closest("[data-mark]"); if (m) { doMark(m.dataset.mark); return; }
      if (e.target.id === "ca-correct") openCorrect();
      if (e.target.id === "ca-tocharges") { closeSheet(); window.CentreCharges.show(); }
    });
    $("cc-cancel").addEventListener("click", function () { $("ca-cor").classList.remove("on"); });
    $("cc-save").addEventListener("click", saveCorrect);
    document.addEventListener("keydown", function (e) {
      if (e.key !== "Escape") return;
      if ($("ca-cor").classList.contains("on")) $("ca-cor").classList.remove("on");
      else if ($("ca-sheet").classList.contains("on")) closeSheet();
    });
  }

  function init() {
    var q = new URLSearchParams(location.search), id = q.get("id"), o = TL.org ? TL.org() : null;
    if (!id) id = o && o.kind === "centre" ? o.id : null;
    if (!id) { location.replace("home"); return; }                                                     // a solo login has no centre pages
    if (o && o.kind === "centre" && o.id === id && o.role === "tutor") { location.replace("tutor"); return; }
    orgId = id;
    if (q.get("view") === "week") state.view = "week";
    if (CA.validISO(q.get("date"))) state.anchor = q.get("date");
    if (q.get("f") === "unmarked" || q.get("f") === "marked" || q.get("f") === "trial") state.status = q.get("f");
    if (q.get("view") === "month") state.view = "month";
    wire(); controls(); load();
    if (window.CentreCharges) window.CentreCharges.init(id, q.get("tab") === "charges" ? "charges" : "");   // adds the Charges tab only for people who may set charges (issue_invoices)
  }
  TL.requireAuth("centre-attendance", init);
})();
