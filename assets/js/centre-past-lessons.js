// "Add past lessons" (T3.10): a bottom sheet that lets centre staff add lessons that were already taught (a student who started last week), with the
// tutor, the days, the price, an optional "mark attended" and a written reason. It lives on the Timetable and on a student's sheet.
// Everything goes through four database functions (staff_past_lessons_options / _pattern / _preview and staff_add_past_lessons); this file never touches a
// table and the database decides who may (manage_timetable or the owner), how far back, clashes, holidays and closed fee months. Logic and wording:
// assets/js/centre-past-lessons-core.js (unit-tested).
(function () {
  "use strict";
  var P = window.CentrePastCore, SC = window.CentreSlotsCore;
  var esc = function (s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var $ = function (id) { return document.getElementById(id); };
  var S = null, built = false, opener = null, previewSeq = 0, previewTimer = null, pickSeq = 0, busy = false;

  function build() {
    if (built) return; built = true;
    var el = document.createElement("div");
    el.className = "pl-sheet"; el.id = "pl-sheet"; el.setAttribute("role", "dialog"); el.setAttribute("aria-modal", "true"); el.setAttribute("aria-labelledby", "pl-t");
    el.innerHTML = '<div class="pl-panel"><div class="pl-grab"></div><div class="pl-head"><div class="pl-hl"><div class="pl-title" id="pl-t">Add past lessons</div><div class="pl-meta" id="pl-m"></div></div>' +
      '<button class="pl-x" id="pl-x" type="button" aria-label="Close"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6 6 18"/></svg></button></div>' +
      '<div class="pl-body" id="pl-b"></div></div>';
    document.body.appendChild(el);
    $("pl-x").addEventListener("click", close);
    el.addEventListener("click", function (e) { if (e.target === el) close(); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && el.classList.contains("on")) close(); });
    var b = $("pl-b");
    b.addEventListener("click", onClick); b.addEventListener("input", onInput); b.addEventListener("change", onInput); b.addEventListener("submit", function (e) { e.preventDefault(); submit(); });
  }
  function close() {
    var el = $("pl-sheet"); if (!el) return; el.classList.remove("on"); if (!document.querySelector(".owe-sheet.on")) document.body.classList.remove("sheet-lock"); S = null; previewSeq++;
    if (opener && opener.focus && document.contains(opener)) opener.focus(); opener = null;
  }
  function body(html) { $("pl-b").innerHTML = html; }
  function note(text, cls) { return '<p class="pl-note' + (cls ? " " + cls : "") + '" role="status">' + esc(text) + '</p>'; }

  // ---------------------------------------------------------------- opening
  // opts: { student: {id, name} (optional), onDone: function }
  function open(orgId, o, trigger) {
    build(); o = o || {};
    S = { orgId: orgId, student: o.student || null, onDone: o.onDone || null, opts: null, flags: { holiday: false, closed: false }, preview: null, tried: false,
          f: { mode: "dates", tutor: "", reason: "", start: "16:00", end: "17:00", rate: "", subject: "", dates: [], items: [], attended: true, remarks: "", from: "", to: "" } };
    opener = trigger || opener;
    $("pl-sheet").classList.add("on"); document.body.classList.add("sheet-lock");
    if (S.student) loadStudent(); else drawPicker("");
  }
  function drawPicker(q) {
    $("pl-m").textContent = "Pick the student";
    body('<div class="pl-form"><div class="field"><label for="pl-find">Student</label><input id="pl-find" type="search" placeholder="Search by name" autocomplete="off" value="' + esc(q) + '"></div>' +
      '<div class="pl-pick" id="pl-pick" role="group" aria-label="Matching students"></div></div>');
    var f = $("pl-find"); f.focus(); pickStudents(q);
  }
  async function pickStudents(q) {
    var mine = ++pickSeq, box = $("pl-pick"); if (!box || !S) return;
    var r = await window.sb.rpc("staff_pick_students", { p_org: S.orgId, p_q: q || null, p_limit: 20 });
    if (mine !== pickSeq || !$("pl-pick")) return;
    if (r.error) { box.innerHTML = '<div class="pl-pickmsg err">' + esc(P.errorText(r.error)) + '</div>'; return; }
    var list = r.data || [];
    box.innerHTML = list.length ? list.map(function (s) { return '<button type="button" data-stu="' + esc(s.id) + '" data-name="' + esc(s.name) + '"><span>' + esc(s.name) + '</span><span class="lv">' + esc(s.level || "") + '</span></button>'; }).join("")
      : '<div class="pl-pickmsg">No student found.</div>';
  }
  async function loadStudent() {
    $("pl-m").textContent = S.student.name; body(note("Loading…"));
    var mine = S, r = await window.sb.rpc("staff_past_lessons_options", { p_org: S.orgId, p_student: S.student.id });
    if (S !== mine) return;
    if (r.error) { body(note(SC.isMissing(r.error) ? "Adding past lessons isn’t switched on yet: db/migration_past_lessons.sql has to be run first." : P.errorText(r.error), "err") + '<div class="pl-acts"><button class="btn" type="button" id="pf-cancel">Close</button></div>'); return; }
    var o = r.data; S.opts = o;
    if (!o.can_add) { body(note("Your account can look at this, but only people who manage the timetable can add lessons.") + '<div class="pl-acts"><button class="btn" type="button" id="pf-cancel">Close</button></div>'); return; }
    if (!o.enabled) { body(note("This centre hasn’t switched on adding past lessons. The owner can do it in Centre settings, under Lessons (“days staff may add past lessons”).") + '<div class="pl-acts"><button class="btn" type="button" id="pf-cancel">Close</button></div>'); return; }
    var f = S.f; f.tutor = o.default_tutor || ""; if (o.slots && o.slots.length) { f.mode = "pattern"; var rg = P.defaultRange(o.today, o.earliest); f.from = rg.from; f.to = rg.to; }
    if (o.slots && o.slots.length === 1) { f.start = SC.hm(o.slots[0].start); f.end = SC.hm(o.slots[0].end); }
    drawForm();
    if (f.mode === "pattern") loadPattern();
  }

  // ---------------------------------------------------------------- the form
  function tutorOptions(sel) {
    return '<option value="">Pick the tutor</option>' + ((S.opts && S.opts.tutors) || []).map(function (t) { return '<option value="' + esc(t.id) + '"' + (t.id === sel ? " selected" : "") + '>' + esc(t.name) + '</option>'; }).join("");
  }
  function chipsHtml() {
    return S.f.dates.slice().sort().map(function (d) { return '<button type="button" class="pl-chip" data-rm="' + esc(d) + '" aria-label="Remove ' + esc(SC.dateText(d)) + '">' + esc(SC.dateText(d)) + ' ✕</button>'; }).join("");
  }
  function errHtml(id) { return '<div class="pl-err" id="pf-e-' + id + '" role="alert" hidden></div>'; }
  function drawForm() {
    var o = S.opts, f = S.f, hasSlots = !!(o.slots && o.slots.length), s = o.student || {}, today = o.today, earliest = o.earliest;
    $("pl-m").textContent = (s.name || S.student.name) + " · back to " + SC.dateText(earliest);
    var h = '<form class="pl-form" id="pf" novalidate>';
    h += '<div class="field"><label for="pf-tutor">Tutor</label><select id="pf-tutor">' + tutorOptions(f.tutor) + '</select>' + errHtml("tutor") + '</div>';
    if (hasSlots) h += '<div class="seg pl-seg" role="group" aria-label="Which days"><button type="button" data-mode="pattern" class="' + (f.mode === "pattern" ? "on" : "") + '" aria-pressed="' + (f.mode === "pattern") + '">From the weekly lessons</button>' +
      '<button type="button" data-mode="dates" class="' + (f.mode === "dates" ? "on" : "") + '" aria-pressed="' + (f.mode === "dates") + '">Pick days</button></div>';
    if (f.mode === "pattern") {
      h += '<div class="row2"><div class="field"><label for="pf-from">From</label><input id="pf-from" type="date" min="' + esc(earliest) + '" max="' + esc(SC.addDays(today, -1)) + '" value="' + esc(f.from) + '"></div>' +
        '<div class="field"><label for="pf-to">To</label><input id="pf-to" type="date" min="' + esc(earliest) + '" max="' + esc(SC.addDays(today, -1)) + '" value="' + esc(f.to) + '"></div></div>' + errHtml("dates");
    } else {
      h += '<div class="field"><label for="pf-day">Day <span class="opt">Add each day that was taught</span></label><div class="pl-addday"><input id="pf-day" type="date" min="' + esc(earliest) + '" max="' + esc(SC.addDays(today, -1)) + '">' +
        '<button type="button" class="btn" id="pf-addday">Add day</button></div><div class="pl-chips" id="pf-chips">' + chipsHtml() + '</div>' + errHtml("dates") + '</div>' +
        '<div class="row2"><div class="field"><label for="pf-start">Starts</label><input id="pf-start" type="time" value="' + esc(f.start) + '">' + errHtml("start") + '</div>' +
        '<div class="field"><label for="pf-end">Ends</label><input id="pf-end" type="time" value="' + esc(f.end) + '">' + errHtml("end") + '</div></div>';
    }
    var hint = o.last_rate != null ? 'Leave empty to use S$' + Number(o.last_rate).toFixed(2).replace(/\.00$/, "") + ' (this student’s latest lesson), or the weekly lesson’s price.' : 'Type the price: this student has no earlier lesson to take it from.';
    h += '<div class="row2"><div class="field"><label for="pf-rate">Price per hour (S$) <span class="opt">Optional</span></label><input id="pf-rate" type="number" inputmode="decimal" min="0" max="1000" step="0.01" value="' + esc(f.rate) + '">' + errHtml("rate") + '</div>' +
      '<div class="field"><label for="pf-subject">Subject <span class="opt">Optional</span></label><input id="pf-subject" type="text" maxlength="60" autocomplete="off" value="' + esc(f.subject) + '">' + errHtml("subject") + '</div></div>' +
      '<p class="pl-hint">' + esc(hint) + '</p>';
    h += '<div class="pl-pre" id="pf-pre" role="status" aria-live="polite"></div><div class="pl-conf" id="pf-conf"></div>';
    h += '<label class="pl-check"><input type="checkbox" id="pf-att"' + (f.attended ? " checked" : "") + '> Mark them attended <span class="opt">(attended lessons are the ones invoiced)</span></label>' +
      '<div class="field" id="pf-remarks-wrap"' + (f.attended ? "" : " hidden") + '><label for="pf-remarks">Remarks <span class="opt">' + (o.remarks_required ? "Required by this centre" : "Optional") + '</span></label><input id="pf-remarks" type="text" maxlength="2000" autocomplete="off" value="' + esc(f.remarks) + '"></div>' +
      '<div class="field"><label for="pf-reason">Why are these being added now?</label><input id="pf-reason" type="text" maxlength="500" autocomplete="off" placeholder="For example: started last week, timetable set up after" value="' + esc(f.reason) + '">' + errHtml("reason") + '</div>' +
      '<div class="pl-err" id="pf-e" role="alert" hidden></div>' +
      '<div class="pl-acts"><button class="btn btn-primary" type="submit" id="pf-go" disabled>Add lessons</button><button class="btn" type="button" id="pf-cancel">Cancel</button></div>' +
      '<p class="pl-fine">Every lesson added is recorded with your name and this reason.</p></form>';
    body(h); renderPreview(); syncGo();
  }
  function readForm() {
    var f = S.f, v = function (id) { var e = $(id); return e ? e.value : null; };
    if (v("pf-tutor") != null) f.tutor = v("pf-tutor");
    if (v("pf-start") != null) f.start = v("pf-start"); if (v("pf-end") != null) f.end = v("pf-end");
    if (v("pf-rate") != null) f.rate = v("pf-rate"); if (v("pf-subject") != null) f.subject = v("pf-subject");
    if (v("pf-reason") != null) f.reason = v("pf-reason"); if (v("pf-remarks") != null) f.remarks = v("pf-remarks");
    if ($("pf-att")) f.attended = $("pf-att").checked;
    if (v("pf-from") != null) f.from = v("pf-from"); if (v("pf-to") != null) f.to = v("pf-to");
  }
  function showErrors(errs) {
    ["tutor", "dates", "start", "end", "rate", "subject", "reason"].forEach(function (k) { var el = $("pf-e-" + k); if (!el) return; el.hidden = !errs[k]; el.textContent = errs[k] || ""; });
  }

  // ---------------------------------------------------------------- the weekly pattern and the preview
  async function loadPattern() {
    var f = S.f, mine = S; if (!f.from || !f.to || f.to < f.from) { f.items = []; schedulePreview(); return; }
    var pre = $("pf-pre"); if (pre) pre.innerHTML = note("Looking at the weekly lessons…");
    var r = await window.sb.rpc("staff_past_lessons_pattern", { p_org: S.orgId, p_student: S.student.id, p_from: f.from, p_to: f.to });
    if (S !== mine) return;
    if (r.error) { f.items = []; var e = $("pf-e-dates"); if (e) { e.hidden = false; e.textContent = P.errorText(r.error); } renderPreview(); return; }
    f.items = r.data || []; var e2 = $("pf-e-dates"); if (e2) e2.hidden = true; schedulePreview(0);
  }
  function readyForPreview() {
    var f = S.f, errs = P.validate(Object.assign({}, f, { reason: "x" }), S.opts); return !errs.tutor && !errs.dates && !errs.start && !errs.end && !errs.rate && !errs.subject;
  }
  function schedulePreview(delay) {
    if (!S) return; clearTimeout(previewTimer); S.preview = null; renderPreview(); syncGo();
    if (!readyForPreview()) return;
    previewTimer = setTimeout(runPreview, delay == null ? 300 : delay);
  }
  async function runPreview() {
    var mine = S, seq = ++previewSeq; if (!S) return;
    var pre = $("pf-pre"); if (pre) pre.innerHTML = note("Checking these lessons…");
    var r = await window.sb.rpc("staff_past_lessons_preview", P.previewArgs(S.orgId, S.student.id, S.f, S.flags));
    if (S !== mine || seq !== previewSeq) return;
    if (r.error) { S.preview = null; if ($("pf-pre")) $("pf-pre").innerHTML = note(P.errorText(r.error), "err"); syncGo(); return; }
    S.preview = r.data; renderPreview(); syncGo();
  }
  function renderPreview() {
    var pre = $("pf-pre"), conf = $("pf-conf"); if (!pre) return; var p = S && S.preview;
    if (!p) { if (!pre.querySelector(".pl-note")) pre.innerHTML = ""; if (conf) conf.innerHTML = ""; return; }
    var rows = (p.rows || []).map(function (r) {
      var v = P.rowView(r);
      return '<li class="pl-row ' + v.tone + '"><span class="pl-d">' + esc(v.title) + '<span>' + esc(v.time) + '</span></span><span class="pl-p">' + esc(v.price) + '</span>' + (v.note ? '<span class="pl-n">' + esc(v.note) + '</span>' : '') + '</li>';
    }).join("");
    pre.innerHTML = '<div class="pl-sum">' + esc(P.summary(p)) + '</div><ul class="pl-list">' + rows + '</ul>';
    var n = P.needs(p), c = "";
    if (n.holiday || S.flags.holiday) c += '<label class="pl-check"><input type="checkbox" id="pf-hol"' + (S.flags.holiday ? " checked" : "") + '> Some of these days are centre holidays. Add them anyway.</label>';
    if ((n.closed || S.flags.closed) && S.opts.is_owner) c += '<label class="pl-check"><input type="checkbox" id="pf-closed"' + (S.flags.closed ? " checked" : "") + '> A month’s TutorDeck fee is already recorded for some of these days. As the owner, add them anyway (the fee won’t change).</label>';
    conf.innerHTML = c;
  }
  function syncGo() {
    var go = $("pf-go"); if (!go || !S) return; readForm();
    var e = P.validate(S.f, S.opts), p = S.preview, ok = P.canAdd(p, e, S.flags);
    go.disabled = !ok || busy;
    go.textContent = p && p.new ? "Add " + p.new + (p.new === 1 ? " lesson" : " lessons") : "Add lessons";
  }

  // ---------------------------------------------------------------- doing it
  async function submit() {
    if (!S || busy) return; readForm(); S.tried = true;
    var errs = P.validate(S.f, S.opts); showErrors(errs);
    if (Object.keys(errs).length) { var first = $("pl-b").querySelector(".pl-err:not([hidden])"); if (first && first.parentNode.querySelector("input,select")) first.parentNode.querySelector("input,select").focus(); return; }
    if (!P.canAdd(S.preview, errs, S.flags)) return;
    busy = true; syncGo();
    var mine = S, r = await window.sb.rpc("staff_add_past_lessons", P.addArgs(S.orgId, S.student.id, S.f, S.flags));
    busy = false;
    if (S !== mine) return;
    if (r.error) { var m = $("pf-e"); m.hidden = false; m.textContent = P.errorText(r.error); m.scrollIntoView({ block: "nearest" }); syncGo(); return; }
    var done = S.onDone, res = r.data; close();
    if (window.TL && TL.toast) TL.toast(P.doneText(res), "ok");
    if (done) done(res);
  }

  // ---------------------------------------------------------------- events
  function onClick(e) {
    var t = e.target; if (!S) return;
    if (t.id === "pf-cancel") { close(); return; }
    var ps = t.closest("[data-stu]"); if (ps) { S.student = { id: ps.dataset.stu, name: ps.dataset.name }; loadStudent(); return; }
    var md = t.closest("[data-mode]"); if (md) { readForm(); S.f.mode = md.dataset.mode; S.preview = null; drawForm(); if (S.f.mode === "pattern") loadPattern(); else schedulePreview(); return; }
    if (t.id === "pf-addday") { var v = $("pf-day").value; if (v && S.f.dates.indexOf(v) < 0 && S.f.dates.length < P.MAX_ITEMS) { S.f.dates.push(v); $("pf-chips").innerHTML = chipsHtml(); $("pf-e-dates").hidden = true; schedulePreview(); } $("pf-day").value = ""; $("pf-day").focus(); return; }
    var rm = t.closest("[data-rm]"); if (rm) { var i = S.f.dates.indexOf(rm.dataset.rm); if (i >= 0) S.f.dates.splice(i, 1); $("pf-chips").innerHTML = chipsHtml(); schedulePreview(); return; }
  }
  function onInput(e) {
    if (!S) return; var id = e.target.id;
    if (id === "pl-find") { var q = e.target.value.trim(); clearTimeout(previewTimer); previewTimer = setTimeout(function () { pickStudents(q); }, 250); return; }
    if (!S.opts) return;
    if (id === "pf-hol") { S.flags.holiday = e.target.checked; schedulePreview(0); return; }
    if (id === "pf-closed") { S.flags.closed = e.target.checked; schedulePreview(0); return; }
    if (id === "pf-att") { $("pf-remarks-wrap").hidden = !e.target.checked; readForm(); syncGo(); return; }
    if (id === "pf-from" || id === "pf-to") { readForm(); S.f.items = []; loadPattern(); return; }
    var k = { "pf-tutor": "tutor", "pf-start": "start", "pf-end": "end", "pf-rate": "rate", "pf-subject": "subject", "pf-reason": "reason" }[id];
    if (k) { var er = $("pf-e-" + k); if (er) er.hidden = true; var g = $("pf-e"); if (g) g.hidden = true; readForm(); if (k === "reason") syncGo(); else schedulePreview(); }
    if (id === "pf-remarks") { readForm(); }
  }

  window.CentrePastLessons = { open: open, close: close };
})();
