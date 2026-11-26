// Centre Timetable, "Weekly slots" view (T3 step 7): the weekly slots with their tutors, add / change / stop, and the button that creates the
// lessons of the next 4 weeks. Everything goes through database functions (staff_slots, staff_pick_students, staff_save_slot, staff_stop_slot,
// staff_generate_lessons); this page never touches a table and the database decides who may (manage_timetable), not this file.
// Pure logic and wording: assets/js/centre-slots-core.js (unit-tested). Started by assets/js/centre-timetable.js.
(function () {
  "use strict";
  var SC = window.CentreSlotsCore;
  var $ = function (id) { return document.getElementById(id); };
  var esc = function (s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var orgId = null, opts = {}, wired = false, seq = 0, state = { tutor: "", q: "", page: 1 }, last = null, canEdit = false, timer = null,
      sheetOpener = null, form = null, names = {}, pickSeq = 0, busy = false;

  var CAL = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="m9 18 6-6-6-6"/></svg>';
  function fmtDay(iso) { return iso ? SC.dateText(iso) : ""; }
  function say(text, kind, extra) {
    var r = $("sl-result"); if (!text) { r.hidden = true; r.innerHTML = ""; return; }
    r.className = "sl-result" + (kind === "err" ? " err" : ""); r.hidden = false;
    r.innerHTML = text + (extra || "");
  }

  // ---------------------------------------------------------------- the list
  function rowHtml(r) {
    var tl = SC.tutorLine(r), kind = SC.kindText(r);
    var inner = '<span class="tt-time">' + esc(SC.timeLabel(r.start_time)) + '<span>' + esc(SC.timeLabel(r.end_time)) + '</span></span>' +
      '<span class="tt-main"><span class="tt-name">' + esc(SC.studentsText(r)) + (kind ? '<span class="sl-grp">' + esc(kind) + '</span>' : '') + '</span>' +
      '<span class="tt-sub' + (tl.warn ? ' none' : '') + '">' + esc(tl.text) + (r.subject ? ' · ' + esc(r.subject) : '') + '</span></span>' +
      (canEdit && r.rate != null ? '<span class="tt-chips"><span class="sl-rate">' + esc(SC.rateText(r.rate)) + '</span></span>' : '');
    if (!canEdit) return '<div class="tt-row sl-row static' + (r.no_tutor ? ' notutor' : '') + '">' + inner + '</div>';
    return '<button type="button" class="tt-row sl-row' + (r.no_tutor ? ' notutor' : '') + '" data-key="' + esc(r.key) + '">' + inner + CAL.replace('<svg ', '<svg class="tt-chev" ') + '</button>';
  }
  function draw(res) {
    last = res; canEdit = !!res.can_edit;
    $("sl-bar").hidden = !canEdit;
    var sel = $("sl-tutor"), keep = state.tutor;
    sel.innerHTML = '<option value="">All tutors</option>' + (res.tutors || []).map(function (t) { return '<option value="' + esc(t.id) + '">' + esc(t.name) + '</option>'; }).join("");
    sel.value = keep; if (sel.value !== keep) { state.tutor = ""; sel.value = ""; }
    var pages = SC.pageCount(res.total, res.size);
    if (res.page > pages && res.total) { state.page = pages; return load(); }
    var rows = res.rows || [], filtered = !!(state.tutor || state.q);
    if (!rows.length) {
      var e = SC.emptyText(filtered);
      $("sl-list").innerHTML = '<div class="card"><div class="tt-empty"><h3>' + esc(e.title) + '</h3><p>' + esc(canEdit || filtered ? e.hint : "The centre hasn’t set up any weekly slots yet.") + '</p></div></div>';
    } else {
      $("sl-list").innerHTML = SC.byDay(rows).map(function (d) {
        return '<div class="tt-day"><span>' + esc(d.name) + '</span><span>' + d.rows.length + (d.rows.length === 1 ? ' slot' : ' slots') + '</span></div><div class="card tt-list">' + d.rows.map(rowHtml).join("") + '</div>';
      }).join("");
    }
    $("sl-count").textContent = SC.countText(res.total, res.generated_until, fmtDay);
    $("sl-pager").hidden = res.total <= res.size;
    $("sl-pl").textContent = SC.pagerLabel(res.page, res.size, res.total);
    $("sl-pp").disabled = res.page <= 1; $("sl-pn").disabled = res.page >= pages;
  }
  function failure(err) {
    if (SC.isMissing(err)) { $("sl-list").innerHTML = '<div class="card tt-block"><h2 style="font-size:17px;font-weight:800;margin:0 0 6px">Not switched on yet</h2><p class="tt-note">Weekly slots need <b>db/migration_staff_slots.sql</b> run first.</p></div>'; $("sl-count").textContent = ""; $("sl-bar").hidden = true; return; }
    $("sl-count").textContent = SC.errorText(err);
  }
  async function load() {
    var mine = ++seq;
    var res = await window.sb.rpc("staff_slots", { p_org: orgId, p_tutor: state.tutor || null, p_q: state.q || null, p_page: state.page, p_size: SC.PAGE_SIZE });
    if (mine !== seq) return null;
    if (res.error) { failure(res.error); return null; }
    if (!res.data || !Array.isArray(res.data.rows)) { $("sl-count").textContent = "Couldn’t load the weekly slots. Refresh and try again."; return null; }
    draw(res.data);
    return res.data;
  }

  // ---------------------------------------------------------------- create the lessons
  async function generate() {
    if (busy) return; busy = true; var b = $("sl-gen"); b.disabled = true; var old = b.textContent; b.textContent = "Creating…";
    try {
      var r = await window.sb.rpc("staff_generate_lessons", { p_org: orgId });
      if (r.error) { say(esc(SC.errorText(r.error)), "err"); return; }
      var m = SC.generateMessage(r.data);
      say('<b>' + esc(m.head) + '</b>' + (m.more.length ? '<span>' + esc(m.more.join(" ")) + '</span>' : ""), "", '<button class="btn" type="button" id="sl-see">See the lessons</button>');
      if (opts.lessonsChanged) opts.lessonsChanged();
      load();
    } finally { busy = false; b.disabled = false; b.textContent = old; }
  }

  // ---------------------------------------------------------------- the sheet
  function lockBody(on) { document.body.classList.toggle("sheet-lock", on); }
  function openSheet(trigger) { sheetOpener = trigger || sheetOpener; $("sl-sheet").classList.add("on"); lockBody(true); var f = $("sl-sheet").querySelector("input,select,button.btn"); if (f) f.focus(); }
  function closeSheet() { $("sl-sheet").classList.remove("on"); lockBody(false); form = null; if (sheetOpener && sheetOpener.focus && document.contains(sheetOpener)) sheetOpener.focus(); sheetOpener = null; }
  function rowByKey(key) { var rows = (last && last.rows) || []; for (var i = 0; i < rows.length; i++) if (rows[i].key === key) return rows[i]; return null; }
  function tutorOptions(sel) {
    return '<option value="">No tutor yet</option>' + ((last && last.tutors) || []).map(function (t) { return '<option value="' + esc(t.id) + '"' + (t.id === sel ? ' selected' : '') + '>' + esc(t.name) + '</option>'; }).join("");
  }
  function dayOptions(sel) {
    return '<option value="">Pick a day</option>' + SC.DAYS.map(function (d, i) { return '<option value="' + i + '"' + (String(sel) === String(i) ? ' selected' : '') + '>' + d + '</option>'; }).join("");
  }
  function chipsHtml() {
    return form.students.map(function (id) { return '<button type="button" class="sl-chip" data-rm="' + esc(id) + '" aria-label="Remove ' + esc(names[id] || "student") + '">' + esc(names[id] || "Student") + ' ✕</button>'; }).join("");
  }
  function openForm(mode, row, trigger) {
    form = { mode: mode, row: row || null, students: [], weekday: row ? String(row.weekday) : "", start: row ? SC.hm(row.start_time) : "16:00", end: row ? SC.hm(row.end_time) : "17:00",
             tutor: row && row.tutor_id && !row.no_tutor ? row.tutor_id : "", subject: row ? (row.subject || "") : "", rate: row && row.rate != null ? String(row.rate) : "" };
    $("sl-st").textContent = mode === "add" ? "Add weekly slot" : "Change weekly slot";
    $("sl-sm").textContent = mode === "add" ? "Repeats every week" : SC.studentsText(row, 4);
    var h = '<form class="sl-form" id="sf" novalidate>';
    if (mode === "add") {
      h += '<div class="field"><label for="sf-find">Students <span class="opt">Pick one, or several for a class</span></label>' +
        '<input id="sf-find" type="search" placeholder="Search by name" autocomplete="off"><div class="sl-pick" id="sf-pick" role="group" aria-label="Matching students"></div>' +
        '<div class="sl-chips" id="sf-chosen"></div><div class="sl-err" id="sf-e-students" role="alert" hidden></div></div>';
    } else {
      h += '<div class="tt-facts" style="margin-bottom:12px"><div><span>Students</span><span>' + esc((row.students || []).map(function (s) { return s.name; }).join(", ")) + '</span></div></div>' +
        (row.is_group ? '<p class="sl-more" style="margin:0 0 12px">This changes the whole class.</p>' : '');
    }
    h += '<div class="field"><label for="sf-day">Day</label><select id="sf-day">' + dayOptions(form.weekday) + '</select><div class="sl-err" id="sf-e-weekday" role="alert" hidden></div></div>' +
      '<div class="row2"><div class="field"><label for="sf-start">Starts</label><input id="sf-start" type="time" value="' + esc(form.start) + '"><div class="sl-err" id="sf-e-start" role="alert" hidden></div></div>' +
      '<div class="field"><label for="sf-end">Ends</label><input id="sf-end" type="time" value="' + esc(form.end) + '"><div class="sl-err" id="sf-e-end" role="alert" hidden></div></div></div>' +
      '<div class="field"><label for="sf-tutor">Tutor</label><select id="sf-tutor">' + tutorOptions(form.tutor) + '</select></div>' +
      '<div class="field"><label for="sf-subject">Subject <span class="opt">Optional</span></label><input id="sf-subject" type="text" maxlength="60" autocomplete="off" value="' + esc(form.subject) + '"><div class="sl-err" id="sf-e-subject" role="alert" hidden></div></div>' +
      '<div class="field"><label for="sf-rate">Rate per hour (S$)</label><input id="sf-rate" type="number" inputmode="decimal" min="0" max="1000" step="0.01" value="' + esc(form.rate) + '"><div class="sl-err" id="sf-e-rate" role="alert" hidden></div></div>' +
      '<div class="sl-err" id="sf-e" role="alert" hidden></div>' +
      '<div class="sl-acts"><button class="btn btn-primary" type="submit" id="sf-save">' + (mode === "add" ? 'Add weekly slot' : 'Save changes') + '</button>' +
      '<button class="btn" type="button" id="sf-cancel">Cancel</button>' +
      (mode === "edit" ? '<button class="btn sl-stop" type="button" id="sf-stop">Stop this weekly slot…</button>' : '') + '</div>' +
      (mode === "edit" ? '<p class="tt-ro">Lessons already created keep their old time and tutor. Stopping a slot only stops new lessons being created.</p>' : '<p class="tt-ro">Adding a slot doesn’t create lessons by itself. Press “Create lessons for the next 4 weeks” afterwards.</p>') +
      '</form>';
    $("sl-sb").innerHTML = h;
    if (mode === "add") { $("sf-chosen").innerHTML = ""; pick(""); }
    openSheet(trigger);
  }
  function readForm() {
    form.weekday = $("sf-day").value; form.start = $("sf-start").value; form.end = $("sf-end").value; form.tutor = $("sf-tutor").value;
    form.subject = $("sf-subject").value; form.rate = $("sf-rate").value;
  }
  function showErrors(errs) {
    ["students", "weekday", "start", "end", "subject", "rate"].forEach(function (k) {
      var el = $("sf-e-" + k); if (!el) return; el.hidden = !errs[k]; el.textContent = errs[k] || "";
    });
  }
  async function pick(q) {
    var mine = ++pickSeq, box = $("sf-pick"); if (!box) return;
    var r = await window.sb.rpc("staff_pick_students", { p_org: orgId, p_q: q || null, p_limit: 20 });
    if (mine !== pickSeq || !$("sf-pick")) return;
    if (r.error) { box.innerHTML = '<div style="padding:10px 12px;font-size:13px;color:var(--owed)">' + esc(SC.errorText(r.error)) + '</div>'; return; }
    var list = r.data || [];
    list.forEach(function (s) { names[s.id] = s.name; });
    box.innerHTML = list.length ? list.map(function (s) {
      var on = form.students.indexOf(s.id) >= 0;
      return '<button type="button" data-st="' + esc(s.id) + '" aria-pressed="' + on + '"><span>' + esc(s.name) + '</span><span class="lv">' + esc(s.level || "") + (on ? ' ✓' : '') + '</span></button>';
    }).join("") : '<div style="padding:10px 12px;font-size:13px;color:var(--muted)">No student found.</div>';
  }
  async function save(e) {
    if (e) e.preventDefault();
    if (!form) return;
    readForm();
    var errs = SC.validate(form, form.mode); showErrors(errs);
    if (Object.keys(errs).length) { var f = $("sl-sb").querySelector(".sl-err:not([hidden])"); if (f && f.parentNode.querySelector("input,select")) f.parentNode.querySelector("input,select").focus(); return; }
    var b = $("sf-save"); b.disabled = true;
    var r = await window.sb.rpc("staff_save_slot", SC.saveArgs(orgId, form.row && form.row.slot_id, form, form.mode));
    b.disabled = false;
    if (r.error) { var m = $("sf-e"); m.hidden = false; m.textContent = SC.errorText(r.error); m.scrollIntoView({ block: "nearest" }); return; }
    var mode = form.mode; closeSheet(); TL.toast(SC.savedText(r.data, mode), "ok"); load();
  }
  async function stop() {
    if (!form || !form.row) return;
    var row = form.row;
    if (!(await TL.confirm({ title: "Stop this weekly slot?", message: SC.studentsText(row, 4) + " · " + SC.DAYS[row.weekday] + " " + SC.timeText(row) + ". No new lessons will be created from it. Lessons already created stay.", confirmText: "Stop slot" }))) return;
    var r = await window.sb.rpc("staff_stop_slot", { p_org: orgId, p_slot: row.slot_id });
    if (r.error) { var m = $("sf-e"); if (m) { m.hidden = false; m.textContent = SC.errorText(r.error); } else TL.toast(SC.errorText(r.error), "err"); return; }
    closeSheet(); TL.toast(SC.stoppedText(r.data), "ok"); load();
  }

  // ---------------------------------------------------------------- wiring
  function wire() {
    if (wired) return; wired = true;
    $("sl-add").addEventListener("click", function (e) { openForm("add", null, e.currentTarget); });
    $("sl-gen").addEventListener("click", generate);
    $("sl-result").addEventListener("click", function (e) { if (e.target.id === "sl-see" && opts.showLessons) opts.showLessons(); });
    $("sl-tutor").addEventListener("change", function () { state.tutor = $("sl-tutor").value; state.page = 1; load(); });
    $("sl-find").addEventListener("input", function () { clearTimeout(timer); timer = setTimeout(function () { state.q = $("sl-find").value.trim(); state.page = 1; load(); }, 250); });
    $("sl-list").addEventListener("click", function (e) { var b = e.target.closest("[data-key]"); if (!b) return; var r = rowByKey(b.dataset.key); if (r) openForm("edit", r, b); });
    $("sl-pp").addEventListener("click", function () { if (state.page > 1) { state.page--; load(); window.scrollTo(0, 0); } });
    $("sl-pn").addEventListener("click", function () { state.page++; load(); window.scrollTo(0, 0); });
    $("sl-sx").addEventListener("click", closeSheet);
    $("sl-sheet").addEventListener("click", function (e) { if (e.target === $("sl-sheet")) closeSheet(); });
    $("sl-sb").addEventListener("submit", save);
    $("sl-sb").addEventListener("click", function (e) {
      var t = e.target;
      if (t.id === "sf-cancel") closeSheet();
      else if (t.id === "sf-stop") stop();
      var st = t.closest("[data-st]");
      if (st && form) {
        var id = st.dataset.st, i = form.students.indexOf(id);
        if (i >= 0) form.students.splice(i, 1); else if (form.students.length < SC.MAX_STUDENTS) form.students.push(id);
        st.setAttribute("aria-pressed", i < 0); var lv = st.querySelector(".lv"); if (lv) lv.textContent = lv.textContent.replace(" ✓", "") + (i < 0 ? " ✓" : "");
        $("sf-chosen").innerHTML = chipsHtml(); var er = $("sf-e-students"); if (er) er.hidden = true;
      }
      var rm = t.closest("[data-rm]");
      if (rm && form) { var j = form.students.indexOf(rm.dataset.rm); if (j >= 0) form.students.splice(j, 1); $("sf-chosen").innerHTML = chipsHtml(); pick($("sf-find") ? $("sf-find").value.trim() : ""); }
    });
    var FIELD = { "sf-day": "weekday", "sf-start": "start", "sf-end": "end", "sf-subject": "subject", "sf-rate": "rate" };
    function clearError(e) { var k = FIELD[e.target.id]; if (!k) return; var er = $("sf-e-" + k); if (er) er.hidden = true; var g = $("sf-e"); if (g) g.hidden = true; }
    $("sl-sb").addEventListener("change", clearError);
    $("sl-sb").addEventListener("input", function (e) {
      clearError(e);
      if (e.target.id === "sf-find") { var q = e.target.value.trim(); clearTimeout(timer); timer = setTimeout(function () { pick(q); }, 250); }
    });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && $("sl-sheet").classList.contains("on")) closeSheet(); });
  }

  window.CentreSlots = {
    init: function (id, o) { orgId = id; opts = o || {}; wire(); },
    show: function () { return load(); },
    close: function () { if ($("sl-sheet").classList.contains("on")) closeSheet(); }
  };
})();
