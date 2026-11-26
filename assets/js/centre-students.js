// Centre Students (T3 step 2): the list, the student sheet, add / edit, discontinue. Every read and write goes through four database functions
// (staff_students, staff_student, staff_save_student, staff_set_student_end); this page never touches a table. What a person may do is decided
// there (owners, and staff with manage_students); assets/js/centre-students-core.js only checks the form early and explains refusals in plain words.
//   centre-students?id=<centre>
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var esc = function (s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var CS = window.CentreStudentsCore, TC = window.TutorCore;
  var orgId = null, today = "", state = { filter: "active", q: "", page: 1 }, counts = null, seq = 0, timer = null,
      sheetOpener = null, form = { mode: "add", student: null, family: null, guardians: [] }, cur = null, endFor = null;

  function card(inner) { $("cs").innerHTML = '<div class="card cs-block">' + inner + '</div>'; }
  function say(id, t) { var m = $(id); m.textContent = t || ""; }
  function fmtDate(iso) {
    if (!iso) return "";
    var d = new Date(iso + "T00:00:00Z"), mo = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][d.getUTCMonth()];
    return d.getUTCDate() + " " + mo + " " + d.getUTCFullYear();
  }
  function plural(n, a, b) { return n === 1 ? a : b; }

  // ---------------------------------------------------------------- the list
  function tabs() {
    $("cs-seg").innerHTML = CS.FILTERS.map(function (f) {
      var n = counts ? counts[f.key] : null;
      return '<button type="button" data-f="' + f.key + '" class="' + (state.filter === f.key ? "on" : "") + '" aria-pressed="' + (state.filter === f.key) + '">' + f.label +
             (n == null ? "" : ' <span class="seg-n">' + n + '</span>') + '</button>';
    }).join("");
  }
  function row(r) {
    var sub = [r.guardian_name, r.guardian_phone].filter(Boolean).join(" · ");
    if (!sub && r.household_name) sub = r.household_name;
    if (r.ended) sub = (sub ? sub + " · " : "") + "ended " + fmtDate(r.end_date);
    return '<button type="button" class="cs-row' + (r.ended ? " ended" : "") + '" data-id="' + esc(r.id) + '">' +
      '<span class="cs-av" aria-hidden="true">' + esc(CS.initials(r.name)) + '</span>' +
      '<span class="cs-main"><span class="cs-name">' + esc(r.name) + '</span><span class="cs-sub">' + esc(sub || "No contact yet") + '</span></span>' +
      '<span class="cs-tags">' + (r.trial ? '<span class="cs-chip">Trial</span>' : '') + (r.level ? '<span class="cs-chip lvl">' + esc(r.level) + '</span>' : '') + '</span>' +
      '<svg class="cs-chev" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="m9 18 6-6-6-6"/></svg></button>';
  }
  function draw(res) {
    counts = res.counts; today = res.today;
    tabs();
    var rows = res.rows || [], total = res.total || 0, pages = CS.pageCount(total, res.size);
    if (res.page > pages && total) { state.page = pages; return load(); }                     // the last page emptied (someone moved a student): go back one
    if (!rows.length) {
      var e = CS.emptyText(state.filter, !!state.q);
      $("cs-list").innerHTML = '<div class="cs-empty"><h3>' + esc(e.title) + '</h3><p>' + esc(e.hint) + '</p></div>';
    } else $("cs-list").innerHTML = rows.map(row).join("");
    $("cs-count").textContent = total ? total + " " + plural(total, "student", "students") + (state.q ? " match" : "") : "";
    $("cs-pager").hidden = total <= res.size;
    $("cs-pl").textContent = CS.pagerLabel(res.page, res.size, total);
    $("cs-prev").disabled = res.page <= 1; $("cs-next").disabled = res.page >= pages;
  }
  async function load() {
    var mine = ++seq;
    var r = await window.sb.rpc("staff_students", { p_org: orgId, p_q: state.q || null, p_filter: state.filter, p_page: state.page, p_size: CS.PAGE_SIZE });
    if (mine !== seq) return;                                                                // a newer search is already on its way
    if (r.error) return failure(r.error);
    if (!r.data || !r.data.counts) { $("cs-count").textContent = "Couldn’t load the students. Refresh and try again."; return; }
    draw(r.data);
  }
  function failure(err) {
    if (CS.isMissing(err)) return card('<h2 style="font-size:17px;font-weight:800;margin:0 0 6px">Not switched on yet</h2><p class="cs-note">The centre Students screen needs <b>db/migration_staff_students.sql</b> run first.</p>');
    if (/NOT_ALLOWED/.test(err.message || "")) return card('<h2 style="font-size:17px;font-weight:800;margin:0 0 6px">Not available to you</h2><p class="cs-note">Your account doesn’t include managing students. Ask the centre owner to give you access.</p><p style="margin:12px 0 0"><a class="btn btn-primary" href="centre?id=' + encodeURIComponent(orgId) + '">Back to Home</a></p>');
    if (/NOT_FOUND/.test(err.message || "")) return card('<h2 style="font-size:17px;font-weight:800;margin:0 0 6px">Centre not available</h2><p class="cs-note">This centre doesn’t exist, or you aren’t an owner or staff member there.</p><p style="margin:12px 0 0"><a class="btn" href="org">Your centres</a></p>');
    $("cs-count").textContent = CS.errorText(err);
  }

  // ---------------------------------------------------------------- the sheet
  function lockBody(on) { document.body.classList.toggle("sheet-lock", on); }
  function openSheet(trigger) { sheetOpener = trigger || sheetOpener; $("cs-sheet").classList.add("on"); lockBody(true); $("cs-sx").focus(); }
  function closeSheet() { $("cs-sheet").classList.remove("on"); lockBody(false); cur = null; if (sheetOpener && sheetOpener.focus && document.contains(sheetOpener)) sheetOpener.focus(); sheetOpener = null; }

  async function showStudent(id, trigger) {
    var r = await window.sb.rpc("staff_student", { p_org: orgId, p_student: id });
    if (r.error) { TL.toast(CS.errorText(r.error), "err"); return null; }
    cur = r.data; today = cur.today || today; tut = null; tutEdit = ""; renderSheet(); openSheet(trigger); loadTutors(cur.id);
    return cur;
  }
  // ---- assigned tutors and the online lesson link (T3 step 7): own function; quietly absent on a database without the migration ----
  var SC = window.CentreSlotsCore, tut = null, tutEdit = "";
  async function loadTutors(id) {
    var r = await window.sb.rpc("staff_student_tutors", { p_org: orgId, p_student: id });
    if (!cur || cur.id !== id || !$("cs-tut")) return;
    if (r.error) { $("cs-tut").innerHTML = SC.isMissing(r.error) ? "" : '<p class="cs-note">' + esc(SC.errorText(r.error)) + '</p>'; return; }
    tut = r.data; drawTutors();
  }
  function drawTutors(msg) {
    var box = $("cs-tut"); if (!box || !tut) return;
    var h = '<div class="cs-h">Assigned tutors</div>';
    if (tutEdit === "tutors") {
      var on = {}; (tut.assigned || []).forEach(function (t) { on[t.id] = 1; });
      h += (tut.options || []).length ? '<div class="pick" role="group" aria-label="Assigned tutors">' + tut.options.map(function (o) {
        return '<label><input type="checkbox" data-tid="' + esc(o.id) + '"' + (on[o.id] ? ' checked' : '') + '> ' + esc(o.name) + '</label>'; }).join("") + '</div>'
        : '<p class="cs-note" style="margin:0 0 8px">This centre has no tutors yet. Invite them in Centre settings.</p>';
      h += (msg ? '<p class="err" role="alert">' + esc(msg) + '</p>' : '') + '<div class="row"><button class="btn btn-primary" type="button" id="tt-save">Save</button><button class="btn" type="button" id="tt-cancel">Cancel</button></div>';
    } else {
      h += (tut.assigned || []).length ? '<div class="chips">' + tut.assigned.map(function (t) { return '<span class="chip">' + esc(t.name) + '</span>'; }).join("") + '</div>'
        : '<p class="cs-note" style="margin:0 0 8px">No tutor assigned yet.</p>';
      if ((tut.history || []).length) h += '<p class="hist">Before: ' + esc(tut.history.slice(0, 3).map(function (x) { return x.name + (x.until ? " until " + fmtDate(x.until) : ""); }).join(" · ")) + '</p>';
      if (tut.can_edit) h += '<button class="btn" type="button" id="tt-edit">' + ((tut.assigned || []).length ? 'Change tutors' : 'Assign tutors') + '</button>';
      else h += '<p class="cs-note">Only people who manage the timetable can change this.</p>';
      if (msg) h += '<p class="cs-note" role="status" style="margin-top:6px">' + esc(msg) + '</p>';
    }
    h += '<div class="cs-h">Online lesson link</div>';
    if (tutEdit === "link") {
      h += '<label class="sr-only" for="tt-link">Online lesson link</label><input id="tt-link" type="url" inputmode="url" maxlength="500" placeholder="https://" autocomplete="off" value="' + esc(tut.online_link || "") + '">' +
        (msg ? '<p class="err" role="alert">' + esc(msg) + '</p>' : '') +
        '<div class="row"><button class="btn btn-primary" type="button" id="tl-save">Save link</button>' + (tut.online_link ? '<button class="btn" type="button" id="tl-clear">Remove link</button>' : '') + '<button class="btn" type="button" id="tl-cancel">Cancel</button></div>';
    } else {
      h += tut.online_link ? '<a class="lk" href="' + esc(tut.online_link) + '" target="_blank" rel="noopener noreferrer">' + esc(tut.online_link) + '</a>' : '<p class="cs-note" style="margin:0 0 8px">Not set. Their tutor sees it on every lesson once it is.</p>';
      if (tut.can_link) h += '<button class="btn" type="button" id="tl-edit">' + (tut.online_link ? 'Change link' : 'Set link') + '</button>';
    }
    box.innerHTML = h;
    var f = box.querySelector("#tt-link") || box.querySelector("[data-tid]"); if (f && tutEdit) f.focus();
  }
  async function tutAct(e) {
    var id = e.target.id; if (!id || !tut || !cur) return;
    if (id === "tt-edit") { tutEdit = "tutors"; drawTutors(); }
    else if (id === "tl-edit") { tutEdit = "link"; drawTutors(); }
    else if (id === "tt-cancel" || id === "tl-cancel") { tutEdit = ""; drawTutors(); }
    else if (id === "tt-save") {
      var ids = Array.prototype.map.call(document.querySelectorAll("#cs-tut [data-tid]:checked"), function (i) { return i.dataset.tid; });
      e.target.disabled = true;
      var r = await window.sb.rpc("staff_set_student_tutors", { p_org: orgId, p_student: cur.id, p_tutors: ids });
      if (r.error) { drawTutors(SC.errorText(r.error)); return; }
      var r2 = await window.sb.rpc("staff_student_tutors", { p_org: orgId, p_student: cur.id });
      if (!r2.error) tut = r2.data;
      tutEdit = ""; drawTutors(ids.length ? "" : "Tutors removed."); TL.toast("Assigned tutors saved", "ok");
    } else if (id === "tl-save" || id === "tl-clear") {
      var v = id === "tl-clear" ? "" : $("tt-link").value.trim(), p = SC.linkProblem(v);
      if (p) { drawTutors(p); var li = $("tt-link"); if (li) li.value = v; return; }
      e.target.disabled = true;
      var s2 = await window.sb.rpc("staff_set_student_link", { p_org: orgId, p_student: cur.id, p_link: v });
      if (s2.error) { drawTutors(SC.errorText(s2.error)); return; }
      tut.online_link = s2.data && s2.data.online_link || null; tutEdit = ""; drawTutors(); TL.toast(v ? "Link saved" : "Link removed", "ok");
    }
  }
  function renderSheet() {
    var s = cur, g = s.guardians || [], html = "";
    $("cs-st").textContent = s.name;
    $("cs-sm").textContent = [s.level, s.household && s.household.name].filter(Boolean).join(" · ") || "Student";
    html += '<div class="cs-h">Details</div><div class="cs-facts">' +
      '<div><span>Status</span><span>' + (s.ended ? 'Ended' : 'Active') + (s.end_date ? ' · ' + esc(CS.endNote(s, today, function (d) { return fmtDate(d); })) : '') + '</span></div>' +
      (s.level ? '<div><span>Level</span><span>' + esc(s.level) + '</span></div>' : '') +
      (s.household ? '<div><span>Family</span><span>' + esc(s.household.name) + '</span></div>' : '') +
      ((s.subjects || []).length ? '<div><span>Subjects</span><span>' + esc(s.subjects.join(", ")) + '</span></div>' : '') +
      (s.notes ? '<div><span>Notes</span><span>' + esc(s.notes) + '</span></div>' : '') + '</div>';
    if (s.trial) html += '<p class="cs-trial">Has a trial lesson in the last 30 days. To change it, open the lesson in Attendance.</p>';
    html += '<div class="cs-h">Parents and guardians</div>';
    if (!g.length) html += '<p class="cs-note">No contact yet. Use Edit to add a parent or guardian.</p>';
    html += g.map(function (c, i) {
      var tel = CS.telHref(c.phone), mail = CS.mailHref(c.email);
      return '<div class="cs-card">' + (i === 0 && g.length > 1 ? '<span class="main">Main contact</span>' : '') + '<b>' + esc(c.name) + '</b>' + (c.relation ? '<span class="rel">' + esc(c.relation) + '</span>' : '') +
        (c.phone ? '<span class="line">' + (tel ? '<a href="' + esc(tel) + '">' + esc(c.phone) + '</a>' : esc(c.phone)) + '</span>' : '') +
        (c.email ? '<span class="line">' + (mail ? '<a href="' + esc(mail) + '">' + esc(c.email) + '</a>' : esc(c.email)) + '</span>' : '') + '</div>';
    }).join("");
    if ((s.siblings || []).length) {
      html += '<div class="cs-h">Brothers and sisters</div><div class="cs-links">' + s.siblings.map(function (x) {
        return '<button type="button" class="cs-link" data-sib="' + esc(x.id) + '">' + esc(x.name) + (x.level ? ' · ' + esc(x.level) : '') + (x.ended ? ' (ended)' : '') + '</button>';
      }).join("") + '</div>';
    }
    html += '<div class="cs-h">Next lessons</div>';
    if (!(s.next_lessons || []).length) html += '<p class="cs-note">No lessons coming up.</p>';
    else html += '<div class="cs-next">' + s.next_lessons.map(function (l) {
      return '<div><span>' + esc(TC.dateLabel(l.date, today)) + ' · ' + esc(TC.timeLabel(l.start)) + (l.subject ? ' · ' + esc(l.subject) : '') + '</span><span class="t">' + esc(l.tutor || 'No tutor yet') + '</span></div>';
    }).join("") + '</div>';
    html += '<div class="cs-tut" id="cs-tut" aria-live="polite"></div>';
    html += '<div class="cs-acts"><button class="btn btn-primary" type="button" id="cs-edit">Edit details</button>' +
      '<button class="btn" type="button" id="cs-sibling">Add a brother or sister</button>' +
      (s.ended || s.end_date ? '<button class="btn" type="button" id="cs-back">Bring back</button>' : '') +
      (!s.ended ? '<button class="btn" type="button" id="cs-disc">' + (s.end_date ? 'Change end date' : 'Discontinue…') + '</button>' : '') + '</div>';
    $("cs-sb").innerHTML = html;
  }

  // ---------------------------------------------------------------- add / edit
  function relationOptions(sel) {
    var list = CS.RELATIONS.slice(); if (sel && list.indexOf(sel) < 0) list.push(sel);
    return '<option value="">Relation</option>' + list.map(function (r) { return '<option' + (r === sel ? ' selected' : '') + '>' + esc(r) + '</option>'; }).join("");
  }
  function drawGuardians(errs) {
    var gs = form.guardians;
    $("cf-gs").innerHTML = gs.map(function (g, i) {
      return '<div class="cs-g" data-i="' + i + '"><div class="cs-g-h"><span>' + (i === 0 ? 'Main contact' : 'Contact ' + (i + 1)) + '</span>' +
        (gs.length > 1 ? '<button type="button" class="cs-g-x" data-rm="' + i + '" aria-label="Remove contact ' + (i + 1) + '">Remove</button>' : '') + '</div>' +
        '<div class="row2"><div class="field"><label for="cg-n' + i + '">Name</label><input id="cg-n' + i + '" data-k="name" type="text" maxlength="120" autocomplete="off" value="' + esc(g.name) + '"></div>' +
        '<div class="field"><label for="cg-r' + i + '">Relation <span class="opt">Optional</span></label><select id="cg-r' + i + '" data-k="relation">' + relationOptions(g.relation) + '</select></div></div>' +
        '<div class="row2"><div class="field"><label for="cg-p' + i + '">Phone</label><input id="cg-p' + i + '" data-k="phone" type="tel" maxlength="30" autocomplete="off" placeholder="e.g. +65 9123 4567" value="' + esc(g.phone) + '"></div>' +
        '<div class="field"><label for="cg-e' + i + '">Email</label><input id="cg-e' + i + '" data-k="email" type="email" maxlength="254" autocomplete="off" value="' + esc(g.email) + '"></div></div>' +
        (errs && errs[i] ? '<div class="cs-err" role="alert">' + esc(errs[i]) + '</div>' : '') + '</div>';
    }).join("");
    $("cf-addg").hidden = gs.length >= CS.MAX_GUARDIANS;
  }
  function readGuardians() {   // what is typed right now, back into form.guardians (so Add / Remove don't lose it)
    document.querySelectorAll("#cf-gs .cs-g").forEach(function (box) {
      var g = form.guardians[+box.dataset.i]; if (!g) return;
      box.querySelectorAll("[data-k]").forEach(function (el) { g[el.dataset.k] = el.value; });
    });
  }
  function openForm(mode, s, family) {
    form = { mode: mode, student: mode === "edit" ? s.id : null, family: family || null, guardians: [] };
    var adding = mode === "add", sibling = adding && family;
    $("cf-title").textContent = adding ? (sibling ? "Add a brother or sister" : "Add student") : "Edit " + s.name;
    $("cf-save").textContent = adding ? "Add student" : "Save changes";
    $("cf-name").value = adding ? "" : s.name; $("cf-level").value = adding ? "" : (s.level || ""); $("cf-notes").value = adding ? "" : (s.notes || "");
    $("cf-hn").value = !adding && s.household ? s.household.name : "";
    $("cf-hn-f").hidden = !!sibling;
    var famBox = $("cf-fam");
    if (sibling) {
      var gs = (cur && cur.guardians) || [];
      famBox.hidden = false;
      famBox.innerHTML = 'Joins <b>' + esc(cur && cur.household ? cur.household.name : "the family") + '</b>. Contacts stay as they are' + (gs.length ? ': ' + esc(gs.map(function (c) { return c.name + (c.phone ? " " + c.phone : ""); }).join(" · ")) : '') + '.';
    } else famBox.hidden = true;
    $("cf-contacts").hidden = !!sibling;
    if (!sibling) {
      form.guardians = (!adding && (s.guardians || []).length) ? s.guardians.map(function (c) { return { id: c.id, name: c.name || "", relation: c.relation || "", phone: c.phone || "", email: c.email || "" }; }) : [CS.blankGuardian()];
      drawGuardians();
    }
    $("cf-name-e").hidden = true; say("cf-msg", "");
    $("cs-form").classList.add("on"); $("cf-name").focus();
  }
  function closeForm() { $("cs-form").classList.remove("on"); }
  async function saveForm() {
    readGuardians();
    var res = CS.check({ name: $("cf-name").value, level: $("cf-level").value, notes: $("cf-notes").value, householdName: $("cf-hn").value, guardians: form.guardians, family: form.family }, form.mode);
    $("cf-name-e").hidden = !res.errors.name; $("cf-name-e").textContent = res.errors.name || "";
    drawGuardians(res.errors.guardians);
    if (!res.ok) { say("cf-msg", res.errors.name || res.errors.form || "Please fix the details marked above."); if (res.errors.name) $("cf-name").focus(); return; }
    say("cf-msg", ""); $("cf-save").disabled = true;
    var p = Object.assign({ p_org: orgId, p_student: form.student }, res.payload);
    var r = await window.sb.rpc("staff_save_student", p);
    $("cf-save").disabled = false;
    if (r.error) { say("cf-msg", CS.errorText(r.error)); return; }
    var created = r.data && r.data.created, id = r.data && r.data.student_id, name = res.payload.p_name;
    closeForm();
    TL.toast(created ? name + " added" : "Saved", "ok");
    if (created) state.page = 1;
    await load();
    if (id) await showStudent(id);                                                                   // the sheet shows what was just saved
  }

  // ---------------------------------------------------------------- discontinue / bring back
  function openEnd(s) {
    endFor = s;
    $("ce-title").textContent = s.end_date ? "Change end date" : "Discontinue " + s.name;
    $("ce-text").textContent = s.end_date ? s.name + " " + (s.ended ? "stopped" : "stops") + " after the date below." : s.name + " stops after the last day below. You can bring them back later.";
    $("ce-date").value = s.end_date || today;
    $("ce-save").textContent = s.end_date ? "Save date" : "Discontinue";
    say("ce-msg", ""); $("cs-end").classList.add("on"); $("ce-date").focus();
  }
  async function saveEnd(date) {
    $("ce-save").disabled = true;
    var r = await window.sb.rpc("staff_set_student_end", { p_org: orgId, p_student: endFor.id, p_end_date: date });
    $("ce-save").disabled = false;
    if (r.error) { say("ce-msg", CS.errorText(r.error)); return false; }
    return true;
  }
  async function afterEnd(id, text) { $("cs-end").classList.remove("on"); TL.toast(text, "ok"); await load(); await showStudent(id); }

  // ---------------------------------------------------------------- wiring
  function wire() {
    $("cs-q").addEventListener("input", function () {
      clearTimeout(timer); timer = setTimeout(function () { state.q = $("cs-q").value.trim(); state.page = 1; load(); }, 250);
    });
    $("cs-seg").addEventListener("click", function (e) { var b = e.target.closest("[data-f]"); if (!b) return; state.filter = b.dataset.f; state.page = 1; load(); });
    $("cs-list").addEventListener("click", function (e) { var b = e.target.closest("[data-id]"); if (b) showStudent(b.dataset.id, b); });
    $("cs-prev").addEventListener("click", function () { if (state.page > 1) { state.page--; load(); window.scrollTo(0, 0); } });
    $("cs-next").addEventListener("click", function () { state.page++; load(); window.scrollTo(0, 0); });
    $("cs-add").addEventListener("click", function () { cur = null; openForm("add", null, null); });
    $("cs-sx").addEventListener("click", closeSheet);
    $("cs-sheet").addEventListener("click", function (e) { if (e.target === $("cs-sheet")) closeSheet(); });
    $("cs-sb").addEventListener("click", function (e) {
      if (e.target.closest && e.target.closest("#cs-tut")) { tutAct(e); return; }
      var sib = e.target.closest("[data-sib]"); if (sib) { showStudent(sib.dataset.sib); return; }
      if (!cur) return;
      var id = e.target.id;
      if (id === "cs-edit") openForm("edit", cur, null);
      else if (id === "cs-sibling") openForm("add", null, cur.household && cur.household.id);
      else if (id === "cs-disc") openEnd(cur);
      else if (id === "cs-back") bringBack(cur);
    });
    $("cf-addg").addEventListener("click", function () { readGuardians(); if (form.guardians.length < CS.MAX_GUARDIANS) form.guardians.push(CS.blankGuardian()); drawGuardians(); var last = document.querySelector("#cf-gs .cs-g:last-child input"); if (last) last.focus(); });
    $("cf-gs").addEventListener("click", function (e) { var b = e.target.closest("[data-rm]"); if (!b) return; readGuardians(); form.guardians.splice(+b.dataset.rm, 1); drawGuardians(); });
    $("cf-cancel").addEventListener("click", closeForm); $("cf-save").addEventListener("click", saveForm);
    $("ce-cancel").addEventListener("click", function () { $("cs-end").classList.remove("on"); });
    $("ce-save").addEventListener("click", async function () {
      var d = $("ce-date").value; if (!d) { say("ce-msg", "Pick the last day of lessons."); return; }
      if (await saveEnd(d)) afterEnd(endFor.id, endFor.name + (d < today ? " discontinued" : " will stop after " + fmtDate(d)));
    });
    document.addEventListener("keydown", function (e) {
      if (e.key !== "Escape") return;
      if ($("cs-form").classList.contains("on")) closeForm();
      else if ($("cs-end").classList.contains("on")) $("cs-end").classList.remove("on");
      else if ($("cs-sheet").classList.contains("on")) closeSheet();
    });
  }
  async function bringBack(s) {
    if (!(await TL.confirm({ title: "Bring " + s.name + " back?", message: "They will count as an active student again, and their weekly slots switch back on.", confirmText: "Bring back" }))) return;
    endFor = s;
    if (await saveEnd(null)) afterEnd(s.id, s.name + " is active again");
    else TL.toast("Couldn’t bring them back.", "err");
  }

  function init() {
    var q = new URLSearchParams(location.search), id = q.get("id"), o = TL.org ? TL.org() : null;
    if (!id) id = o && o.kind === "centre" ? o.id : null;
    if (!id) { location.replace("home"); return; }                                                     // a solo login has no centre pages
    if (o && o.kind === "centre" && o.id === id && o.role === "tutor") { location.replace("tutor"); return; }
    orgId = id;
    if (["active", "ended", "trial", "all"].indexOf(q.get("f")) >= 0) state.filter = q.get("f");
    wire(); tabs(); load();
  }
  TL.requireAuth("centre-students", init);
})();
