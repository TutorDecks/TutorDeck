// Centre make-up credits (T18 step 4): the third tab of the Attendance page, "Make-ups", the OWED LIST. Each row is a make-up lesson a family is owed, with the
// missed lesson linked; the sheet has "Book make-up" (creates an ordinary lesson linked to the credit), "Remove the make-up" (gives the credit back) and
// "Take back credit". "Give a credit" grants one by hand, with a reason. Every read and write goes through database functions (staff_credit_list,
// staff_grant_credit, staff_revoke_credit, staff_book_makeup, staff_unbook_makeup); this page never touches a table. Who may, the price of the make-up, the
// expiry and the audit entry are decided there (db/migration_makeup_credits.sql); assets/js/centre-credits-core.js only words the answers.
// Tutors never get here (the first call answers NOT_FOUND to them, so the tab never appears). Staff who may only look see the list without buttons.
//   centre-attendance?id=<centre>&tab=makeups[&student=<student id>]
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var esc = function (s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var MC = window.CentreCreditsCore, TC = window.TutorCore, CA = window.CentreAttendanceCore;
  var UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  var orgId = null, enabled = false, active = false, res = null, filter = "open", page = 1, student = null, cur = null, mode = "", seq = 0, opener = null, wired = false,
      tutors = null, chargesOn = false, picked = null, pickSeq = 0, pickTimer = null;

  function say(id, t) { $(id).textContent = t || ""; }
  function plural(n, a, b) { return n === 1 ? a : b; }
  function today() { return (res && res.today) || new Date().toISOString().slice(0, 10); }
  function find(id) { var rows = (res && res.rows) || []; for (var i = 0; i < rows.length; i++) if (rows[i].credit_id === id) return rows[i]; return null; }
  function fmtDay(iso) { return TC.dateLabel(iso, today()); }

  // ---------------------------------------------------------------- the tabs (shared with Lessons and Charges)
  function badge() {
    var n = MC.badgeCount(res);
    $("mk-badge").textContent = n ? String(n) : ""; $("mk-badge").hidden = !n;
    $("ca-tab-makeups").setAttribute("aria-label", "Make-ups" + (n ? ", " + n + " owed" : ""));
  }
  function tabs() {
    $("ca-tabs").querySelectorAll("[data-t]").forEach(function (b) { var on = b.dataset.t === "makeups"; b.classList.toggle("on", on); b.setAttribute("aria-pressed", on); });
    $("mk").hidden = false; $("ca").hidden = true; $("cg").hidden = true;
    try { var u = new URL(location.href); u.searchParams.set("tab", "makeups"); history.replaceState(null, "", u); } catch (e) {}
  }
  function show() { if (!enabled) return; active = true; tabs(); load(); }
  // leaving for Lessons or Charges: when Charges is not available at all, this file puts the Lessons tab back itself
  function leave(to) {
    if (!active) return;
    active = false; $("mk").hidden = true; $("ca-tab-makeups").classList.remove("on"); $("ca-tab-makeups").setAttribute("aria-pressed", "false");
    if (!chargesOn) { $("ca").hidden = false; var l = $("ca-tabs").querySelector('[data-t="lessons"]'); if (l) { l.classList.add("on"); l.setAttribute("aria-pressed", "true"); } }
    try { var u = new URL(location.href); if (u.searchParams.get("tab") === "makeups") u.searchParams.delete("tab"); history.replaceState(null, "", u); } catch (e) {}
  }

  // ---------------------------------------------------------------- the list
  function segHtml() {
    return MC.FILTERS.map(function (f) {
      var n = res && res.counts && f.key !== "all" ? res.counts[f.key === "open" ? "open" : f.key] : null;
      return '<button type="button" data-f="' + f.key + '" class="' + (filter === f.key ? "on" : "") + '" aria-pressed="' + (filter === f.key) + '">' + esc(f.label) +
        (n ? ' <span class="mk-n">' + n + '</span>' : '') + '</button>';
    }).join("");
  }
  function rowHtml(r) {
    var chip = MC.rowChip(r, today()), exp = MC.expiryText(r, today()), mk = MC.makeupLine(r, today());
    return '<button type="button" class="ca-row mk-open" data-id="' + esc(r.credit_id) + '">' +
      '<span class="ca-main"><span class="ca-name">' + esc(r.student_name) + '</span>' +
      '<span class="ca-sub">' + esc(MC.missedLine(r, today())) + '</span>' +
      (mk ? '<span class="ca-sub">' + esc(mk) + '</span>' : (exp ? '<span class="ca-sub' + (chip.kind === "warn" ? ' none' : '') + '">' + esc(exp) + '</span>' : '')) + '</span>' +
      '<span class="ca-chip' + (chip.kind === "ok" ? " ok" : chip.kind === "warn" ? " warn" : " muted") + '">' + esc(chip.text) + '</span>' +
      '<svg class="ca-chev" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="m9 18 6-6-6-6"/></svg></button>';
  }
  function draw() {
    if (!res) return;
    badge();
    $("mk-seg").innerHTML = segHtml();
    $("mk-give").hidden = !res.can_grant;
    var rows = res.rows || [], total = res.total || 0, pages = CA.pageCount(total, res.size);
    if (res.page > pages && total) { page = pages; return load(); }
    $("mk-who").hidden = !student;
    if (student) { var nm = rows.length ? rows[0].student_name : "this student"; $("mk-who-t").textContent = "Showing " + nm + " only"; }
    if (!rows.length) {
      var e = MC.emptyText(filter, res.enabled);
      $("mk-list").innerHTML = '<div class="card"><div class="ca-empty"><h3>' + esc(e.title) + '</h3><p>' + esc(e.hint) + '</p></div></div>';
    } else {
      $("mk-list").innerHTML = '<div class="card ca-list">' + rows.map(rowHtml).join("") + '</div>';
    }
    $("mk-count").textContent = total ? total + " " + plural(total, "credit", "credits") : "";
    $("mk-pager").hidden = total <= res.size;
    $("mk-pl").textContent = CA.pagerLabel(res.page, res.size, total).replace("No lessons", "No credits");
    $("mk-pp").disabled = res.page <= 1; $("mk-pn").disabled = res.page >= pages;
    $("mk-note").textContent = res.enabled ? "A make-up lesson a family is owed, with the lesson that was missed. Book it, and marking that lesson uses the credit up. " + MC.priceRule(res.makeup_price)
      : "Make-up credits are switched off at this centre. Existing credits are listed here; turn the feature on in Centre settings.";
  }
  async function load() {
    var mine = ++seq;
    var r = await window.sb.rpc("staff_credit_list", { p_org: orgId, p_status: filter, p_student: student, p_page: page, p_size: MC.PAGE_SIZE });
    if (mine !== seq) return;
    if (r.error) { $("mk-count").textContent = MC.errorText(r.error); return; }
    if (!r.data || !Array.isArray(r.data.rows)) { $("mk-count").textContent = "Couldn’t load the make-ups. Refresh and try again."; return; }
    res = r.data; draw();
  }

  // ---------------------------------------------------------------- the sheet: one credit
  function lockBody(on) { document.body.classList.toggle("sheet-lock", on); }
  function openSheet(trigger) { opener = trigger || opener; $("mk-sheet").classList.add("on"); lockBody(true); $("mk-sx").focus(); }
  function closeSheet() { $("mk-sheet").classList.remove("on"); lockBody(false); cur = null; mode = ""; if (opener && opener.focus && document.contains(opener)) opener.focus(); opener = null; }
  function fact(k, v) { return v ? '<div><span>' + esc(k) + '</span><span>' + esc(v) + '</span></div>' : ""; }
  function tutorOptions(selected) {
    return '<option value="">Same tutor as the missed lesson</option>' + (tutors || []).map(function (t) {
      return '<option value="' + esc(t.id) + '"' + (t.id === selected ? " selected" : "") + '>' + esc(t.name) + '</option>'; }).join("");
  }
  function formHtml(r) {
    if (mode === "book") {
      var d = MC.bookingDefaults(r), first = TC.addDays(today(), 7); if (r.expires_on && first > r.expires_on) first = r.expires_on;
      return '<div class="mk-form"><div class="field"><label for="mk-date">Day</label><input id="mk-date" type="date" min="' + esc(today()) + '"' + (r.expires_on ? ' max="' + esc(r.expires_on) + '"' : '') + ' value="' + esc(first) + '"></div>' +
        '<div class="mk-two"><div class="field"><label for="mk-start">Starts</label><input id="mk-start" type="time" value="' + d.start + '"></div>' +
        '<div class="field"><label for="mk-end">Ends</label><input id="mk-end" type="time" value="' + d.end + '"></div></div>' +
        '<div class="field"><label for="mk-tutor">Tutor</label><select id="mk-tutor">' + tutorOptions("") + '</select></div>' +
        '<p class="ca-note">' + esc(MC.priceRule(res.makeup_price)) + '</p>' +
        '<div class="ca-err" id="mk-err" role="alert"></div>' +
        '<div class="mk-btns"><button class="btn btn-primary" type="button" id="mk-do">Book make-up</button><button class="btn" type="button" id="mk-back">Cancel</button></div></div>';
    }
    if (mode === "revoke" || mode === "unbook") {
      var unb = mode === "unbook";
      return '<div class="mk-form"><div class="field"><label for="mk-reason">' + (unb ? 'Why is the make-up being removed?' : 'Why is the credit being taken back?') + '</label>' +
        '<textarea id="mk-reason" maxlength="' + MC.REASON_MAX + '" placeholder="' + (unb ? 'e.g. The family can’t make that day' : 'e.g. Given by mistake') + '"></textarea>' +
        '<span class="fhint">Required. It is kept on the centre’s record with your name.' + (unb ? ' The make-up lesson is removed and the credit goes back to Owed.' : '') + '</span></div>' +
        '<div class="ca-err" id="mk-err" role="alert"></div>' +
        '<div class="mk-btns"><button class="btn btn-primary" type="button" id="mk-do">' + (unb ? 'Remove make-up' : 'Take back credit') + '</button><button class="btn" type="button" id="mk-back">Cancel</button></div></div>';
    }
    var h = '<div class="mk-btns">';
    if (r.can_book) h += '<button class="btn btn-primary" type="button" id="mk-book">Book make-up</button>';
    if (r.can_unbook) h += '<button class="btn" type="button" id="mk-unbook">Remove the make-up…</button>';
    if (r.can_revoke) h += '<button class="btn" type="button" id="mk-revoke">Take back credit…</button>';
    h += '</div>';
    if (r.status === "open" && !r.can_book && !r.can_revoke) h += '<p class="ca-note">' + (r.expired_by_date ? 'This credit has ended, so no make-up can be booked with it.' : 'Your account can’t change credits. Ask the centre owner.') + '</p>';
    if (r.status === "booked" && !r.can_unbook) h += '<p class="ca-note">' + (r.makeup && r.makeup.attendance ? 'The make-up has been marked.' : res.can_book ? 'This make-up is paid or on an invoice, so it can’t be removed here.' : 'Your account can’t change make-ups. Ask the centre owner.') + '</p>';
    if (r.status === "used") h += '<p class="ca-note">The make-up lesson was marked, so this credit is used up.</p>';
    return h;
  }
  function renderSheet() {
    var r = cur;
    $("mk-st").textContent = r.student_name;
    $("mk-sm").textContent = MC.sourceLabel(r.source) + " · " + MC.statusLabel(r.status);
    $("mk-sb").innerHTML = '<div class="ca-facts">' +
      fact("Missed lesson", r.missed ? MC.missedLine(r, today()).replace(/^Missed /, "") : "") +
      fact("Reason", r.source === "manual" ? r.reason : "") +
      fact("Earned", r.earned_on ? fmtDay(r.earned_on) : "") +
      fact("Expiry", MC.expiryText(r, today())) +
      fact("Make-up lesson", r.makeup ? MC.makeupLine(r, today()).replace(/^Make-up /, "") : "") +
      fact("Billing", r.makeup ? MC.billingText(r.makeup.billing) : "") + '</div>' + formHtml(r);
    var f = $("mk-sb").querySelector("input,textarea,select"); if (f && mode) f.focus();
  }
  async function open(id, trigger) {
    var r = find(id); if (!r) return; cur = r; mode = "";
    if (tutors == null) { tutors = []; loadTutors(); }
    renderSheet(); openSheet(trigger);
  }
  // the tutor list for the booking form (the same list the Lessons tab filters by); quietly empty when it can't be read
  async function loadTutors() {
    var r = await window.sb.rpc("staff_lessons", { p_org: orgId, p_from: today(), p_to: today(), p_tutor: null, p_status: "all", p_page: 1, p_size: 1 });
    tutors = r.data && Array.isArray(r.data.tutors) ? r.data.tutors : [];
    if (mode === "book" && cur) { var s = $("mk-tutor"); if (s) s.innerHTML = tutorOptions(s.value); }
  }
  function busy(on) { document.querySelectorAll("#mk-sheet button, #mk-sheet input, #mk-sheet select, #mk-sheet textarea").forEach(function (b) { b.disabled = on; }); }
  // run one write; on a "somebody got there first" refusal the list is refreshed and the sheet closes
  async function act(fn, okText) {
    busy(true);
    var r = await fn();
    busy(false);
    if (r.error) {
      say("mk-err", MC.errorText(r.error));
      if (MC.isStale(r.error)) { closeSheet(); TL.toast(MC.errorText(r.error), "err"); load(); }
      return;
    }
    TL.toast(okText, "ok"); closeSheet(); await load();
  }
  async function doBook() {
    var chk = MC.checkBooking({ date: $("mk-date").value, start: $("mk-start").value, end: $("mk-end").value, tutor: $("mk-tutor").value }, today(), cur);
    if (!chk.ok) { say("mk-err", chk.error); return; }
    var v = chk.value, name = cur.student_name, id = cur.credit_id;
    await act(function () { return window.sb.rpc("staff_book_makeup", { p_credit: id, p_date: v.date, p_start: v.start, p_end: v.end, p_tutor: v.tutor }); },
              "Make-up booked for " + name + ", " + fmtDay(v.date));
  }
  async function doReason(fnName, okText) {
    var chk = MC.checkReason($("mk-reason").value);
    if (!chk.ok) { say("mk-err", chk.error); return; }
    var id = cur.credit_id;
    await act(function () { return window.sb.rpc(fnName, { p_credit: id, p_reason: chk.value }); }, okText);
  }

  // ---------------------------------------------------------------- give a credit by hand
  function openGive() {
    picked = null; $("mg-q").value = ""; $("mg-reason").value = ""; say("mg-msg", ""); $("mg-results").innerHTML = ""; $("mg-picked").textContent = "";
    $("mk-give-modal").classList.add("on"); lockBody(true); $("mg-q").focus(); searchStudents();
  }
  function closeGive() { $("mk-give-modal").classList.remove("on"); lockBody(false); }
  async function searchStudents() {
    var mine = ++pickSeq, q = $("mg-q").value.trim();
    var r = await window.sb.rpc("staff_pick_students", { p_org: orgId, p_q: q || null, p_limit: 8 });
    if (mine !== pickSeq) return;
    if (r.error) { $("mg-results").innerHTML = '<p class="ca-note">' + esc(MC.errorText(r.error)) + '</p>'; return; }
    var list = Array.isArray(r.data) ? r.data : [];
    $("mg-results").innerHTML = list.length ? list.map(function (s) {
      return '<button type="button" class="mk-pick' + (picked && picked.id === s.id ? " on" : "") + '" data-id="' + esc(s.id) + '" data-name="' + esc(s.name) + '">' + esc(s.name) + (s.level ? ' · ' + esc(s.level) : '') + '</button>';
    }).join("") : '<p class="ca-note">No student matches.</p>';
  }
  async function doGive() {
    if (!picked) { say("mg-msg", "Choose the student."); return; }
    var chk = MC.checkReason($("mg-reason").value);
    if (!chk.ok) { say("mg-msg", chk.error); return; }
    $("mg-save").disabled = true;
    var r = await window.sb.rpc("staff_grant_credit", { p_org: orgId, p_student: picked.id, p_reason: chk.value, p_lesson: null });
    $("mg-save").disabled = false;
    if (r.error) { say("mg-msg", MC.errorText(r.error)); if (MC.isStale(r.error)) load(); return; }
    TL.toast("Credit given to " + picked.name, "ok"); closeGive(); filter = "open"; page = 1; await load();
  }

  // ---------------------------------------------------------------- wiring
  function wire() {
    if (wired) return; wired = true;
    $("ca-tabs").addEventListener("click", function (e) {
      var b = e.target.closest("[data-t]"); if (!b) return;
      if (b.dataset.t === "makeups") show(); else leave(b.dataset.t);
    });
    $("mk-seg").addEventListener("click", function (e) { var b = e.target.closest("[data-f]"); if (!b || b.dataset.f === filter) return; filter = b.dataset.f; page = 1; load(); });
    $("mk-list").addEventListener("click", function (e) { var b = e.target.closest(".mk-open"); if (b) open(b.dataset.id, b); });
    $("mk-pp").addEventListener("click", function () { if (page > 1) { page--; load(); window.scrollTo(0, 0); } });
    $("mk-pn").addEventListener("click", function () { page++; load(); window.scrollTo(0, 0); });
    $("mk-all").addEventListener("click", function () { student = null; page = 1; try { var u = new URL(location.href); u.searchParams.delete("student"); history.replaceState(null, "", u); } catch (e) {} load(); });
    $("mk-give").addEventListener("click", openGive);
    $("mk-sx").addEventListener("click", closeSheet);
    $("mk-sheet").addEventListener("click", function (e) {
      if (e.target === $("mk-sheet")) { closeSheet(); return; }
      var id = e.target.id;
      if (id === "mk-book") { mode = "book"; renderSheet(); }
      else if (id === "mk-revoke") { mode = "revoke"; renderSheet(); }
      else if (id === "mk-unbook") { mode = "unbook"; renderSheet(); }
      else if (id === "mk-back") { mode = ""; renderSheet(); }
      else if (id === "mk-do") { if (mode === "book") doBook(); else if (mode === "unbook") doReason("staff_unbook_makeup", "Make-up removed; the credit is owed again"); else doReason("staff_revoke_credit", "Credit taken back"); }
    });
    $("mg-q").addEventListener("input", function () { clearTimeout(pickTimer); pickTimer = setTimeout(searchStudents, 250); });
    $("mg-results").addEventListener("click", function (e) {
      var b = e.target.closest(".mk-pick"); if (!b) return;
      picked = { id: b.dataset.id, name: b.dataset.name }; $("mg-picked").textContent = "Giving a credit to " + picked.name;
      $("mg-results").querySelectorAll(".mk-pick").forEach(function (x) { x.classList.toggle("on", x === b); }); say("mg-msg", "");
    });
    $("mg-save").addEventListener("click", doGive);
    $("mg-cancel").addEventListener("click", closeGive);
    document.addEventListener("keydown", function (e) {
      if (e.key !== "Escape") return;
      if ($("mk-give-modal").classList.contains("on")) closeGive(); else if ($("mk-sheet").classList.contains("on")) closeSheet();
    });
  }

  // Called once by the Attendance page, with the promise of the Charges tab's own start-up (so the two never fight over who shows the tab bar).
  // Resolves true when this person may see make-ups (the tab is then shown), false otherwise: not allowed (tutors, parents, strangers), solo, an older
  // database without the migration, or a centre that never switched credits on and has none.
  async function init(id, wantTab, chargesReady, wantStudent) {
    orgId = id;
    if (wantStudent && UUID.test(wantStudent)) student = wantStudent;
    var r = await window.sb.rpc("staff_credit_list", { p_org: id, p_status: "open", p_student: student, p_page: 1, p_size: MC.PAGE_SIZE });
    if (r.error || !r.data || !Array.isArray(r.data.rows) || !MC.showTab(r.data)) {
      if (student && !r.error) { student = null; }
      return false;
    }
    try { chargesOn = !!(await chargesReady); } catch (e) { chargesOn = false; }
    enabled = true; res = r.data; wire();
    $("ca-tabs").hidden = false; $("ca-tab-makeups").hidden = false;
    if (!chargesOn) $("ca-tab-charges").hidden = true;
    badge();
    if (wantTab) { active = true; tabs(); filter = "open"; draw(); }
    return true;
  }
  window.CentreCredits = { init: init, show: show, enabled: function () { return enabled; } };
})();
