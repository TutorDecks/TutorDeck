// Schedule — a centre tutor's own week and weekly slots (T6). The page calls database functions only and never reads a table: tutor_my_schedule and
// tutor_my_slots to look, and (T6 step 2, only when the centre has switched it on) tutor_postpone_lesson, tutor_revert_lesson and tutor_cancel_lesson to
// move a lesson, put it back, or cancel it in advance; (T6 steps 5-6) tutor_set_link for the online lesson link, tutor_my_requests and tutor_cancel_request, and at a centre that
// asks ("tutors_propose") EVERY one of the calls below returns {requested: true} instead of acting: the screen then says "request sent" and shows it under My requests; (T6 steps 3-4, each only when the centre has switched it on) tutor_my_students, tutor_add_lesson,
// tutor_save_slot, tutor_stop_slot and tutor_generate_lessons to add a one-off lesson, keep my own weekly slots and press "Create lessons". Nothing here returns, shows or sends anything about money: a move keeps the lesson's length, and a
// cancel is "no charge to the family" decided by the database. Every button shown comes from the database's own answer (can_postpone / can_revert /
// can_cancel, can_one_off / can_slots / can_generate, a slot's can_change), so the screen can't offer what the rules refuse. Pure logic lives in assets/js/tutor-core.js (unit-tested).
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var esc = function (s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var TC = window.TutorCore, RC = window.TutorRequestsCore, reqs = [], reqById = {}, today = "", start = "", data = null, byId = {}, manyOrgs = false, editing = "admin_only", opener = null, seq = 0, cur = null, busy = false,
      slotRows = [], slotById = {}, students = null;
  function orgOf(l) { return ((data && data.orgs) || []).filter(function (o) { return o.org_id === (l && l.org_id); })[0] || ((data && data.orgs) || [])[0] || {}; }
  function hhmm(t) { return String(t || "").slice(0, 5); }
  function proposesFor(o) { return !!(o && o.proposes); }
  function firstOrg() { return ((data && data.orgs) || [])[0] || {}; }
  function sendLabel(base) { return proposesFor(firstOrg()) ? "Send request" : base; }
  var ASK_HINT = '<p class="tt-hint">An admin will look at your request. Nothing changes until they approve it.</p>';
  // the database answered {requested: true}: nothing was changed, a request is waiting
  function wasRequested(r) { return !!(r && r.data && r.data.requested); }

  function chev() { return '<svg class="tt-chev" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="m9 18 6-6-6-6"/></svg>'; }

  function row(l) {
    var c = TC.scheduleChip(l), t = TC.timeLabel(l.start_time).split(" ");
    return '<button type="button" class="tt-row" data-id="' + esc(l.lesson_id) + '">' +
      '<span class="tt-time"><b>' + esc(t[0] || "") + '</b><small>' + esc(t[1] || "") + '</small></span>' +
      '<span class="tt-main"><span class="tt-name">' + esc(l.student_name) + '</span><span class="tt-sub">' + esc(TC.scheduleFacts(l, manyOrgs).join(" · ") || "Lesson") + '</span></span>' +
      (c ? '<span class="tt-chip ' + c.tone + '">' + esc(c.text) + '</span>' : '') + chev() + '</button>';
  }

  function renderWeek() {
    var end = TC.addDays(start, 6), days = TC.scheduleDays(data, start, end), n = 0, html = "";
    (data.lessons || []).forEach(function (l) { if (!l.cancelled) n++; });
    $("sc-title").innerHTML = esc(TC.weekTitle(start, today)) + '<small>' + esc(TC.rangeLabel(start, end)) + '</small>';
    $("sc-sum").innerHTML = '<b>' + n + '</b> lesson' + (n === 1 ? "" : "s") + ' this ' + (start === TC.weekStart(today) ? "week" : "page");
    if (!days.length) { $("sc-week").innerHTML = '<div class="card"><div class="tt-empty">No lessons this week.</div></div>'; return; }
    html = '<div class="card tt-list">';
    days.forEach(function (d) {
      html += '<div class="tt-day' + (d.holidays.length ? ' hol' : '') + '">' + esc(TC.dateLabel(d.date, today)) +
              (d.holidays.length ? '<span>' + esc(d.holidays.join(", ")) + ' · holiday</span>' : '') + '</div>';
      d.lessons.forEach(function (l) { html += row(l); });
    });
    $("sc-week").innerHTML = html + '</div>';
  }

  function renderSlots(rows) {
    slotRows = rows || []; slotById = {};
    var list = TC.slotList(rows);
    if (!list.length) { $("sc-slots").innerHTML = '<div class="card"><div class="tt-empty">You have no weekly slots yet. ' + (anyOrg("can_slots") ? 'Tap "Add a weekly slot" to make one.' : 'When your centre gives you a regular class, it will appear here.') + '</div></div>'; return; }
    $("sc-slots").innerHTML = '<div class="card tt-list sc-slot">' + list.map(function (s) {
      slotById[s.slot_id] = s;
      var names = s.students.map(function (x) { return x.name + (x.level ? " (" + x.level + ")" : ""); }).join(", ");
      var t = TC.timeLabel(s.start_time).split(" ");
      var inner = '<span class="sc-wd">' + esc(TC.weekdayName(s.weekday).slice(0, 3)) + '</span>' +
        '<span class="tt-time"><b>' + esc(t[0] || "") + '</b><small>' + esc(t[1] || "") + '</small></span>' +
        '<span class="tt-main"><span class="tt-name">' + esc(names) + '</span><span class="tt-sub">' + esc([TC.timeRange(s), s.subject, s.is_group ? "Group class" : null, manyOrgs ? s.org_name : null].filter(Boolean).join(" · ")) + '</span></span>' +
        (s.pending_request ? '<span class="tt-chip warn">Waiting for approval</span>' : s.awaiting_centre ? '<span class="tt-chip muted">To confirm</span>' : '');
      return s.can_change ? '<button type="button" class="sc-tap" data-slot="' + esc(s.slot_id) + '">' + inner + chev() + '</button>' : '<div class="sc-row">' + inner + '</div>';
    }).join("") + '</div>';
  }
  function anyOrg(flag) { return ((data && data.orgs) || []).some(function (o) { return o[flag]; }); }
  // the three buttons the centre has switched on (each is the database's own answer)
  function renderActions() {
    var one = anyOrg("can_one_off"), sl = anyOrg("can_slots"), gen = anyOrg("can_generate");
    $("sc-add").hidden = !one; $("sc-add-slot").hidden = !sl; $("sc-generate").hidden = !gen; $("sc-slot-acts").hidden = !(sl || gen);
  }

  function note() { var n = $("sc-note"); n.textContent = TC.editNote(editing, ((data && data.orgs) || [])[0]); n.hidden = false; }

  function openSheet(l, trigger) {
    if (trigger) opener = trigger;
    cur = l;
    $("ts-title").textContent = l.student_name;
    $("ts-sub").textContent = TC.dateLabel(l.lesson_date, today) + " · " + TC.timeRange(l);
    var c = TC.scheduleChip(l), url = /^https:\/\/\S+$/.test(l.online_link || "") ? l.online_link : null, o = orgOf(l), P = proposesFor(o), wait = l.pending_request, wr = wait && reqById[wait.request_id];
    var lessonOpen = !l.cancelled && !wait && l.lesson_date >= today;
    var acts = wait ? "" : (l.can_postpone ? '<button type="button" class="tt-opt" data-act="move">' + (P ? "Ask to move" : "Move") + '</button>' : '') +
               (l.can_revert ? '<button type="button" class="tt-opt" data-act="revert">' + (P ? "Ask to put back to usual time" : "Put back to usual time") + '</button>' : '') +
               (l.can_cancel ? '<button type="button" class="tt-opt danger" data-act="cancel">' + (P ? "Ask to cancel lesson" : "Cancel lesson") + '</button>' : '') +
               (lessonOpen && o.can_link ? '<button type="button" class="tt-opt" data-do="link-lesson">' + (P ? "Ask to set the link of this lesson" : "Set the link of this lesson") + '</button>' +
                 '<button type="button" class="tt-opt" data-do="link-student">' + (P ? "Ask to set " : "Set ") + esc(l.student_name) + '\'s usual link</button>' : '');
    var why = !acts && !wait && o.can_edit && l.change_block ? TC.blockText(l.change_block, o) : "";
    $("ts-body").innerHTML = '<div class="tt-facts">' +
      (l.student_level || l.subject ? '<div><span>Class</span><span>' + esc([l.student_level, l.subject].filter(Boolean).join(" · ")) + '</span></div>' : '') +
      '<div><span>Length</span><span>' + esc(l.minutes) + ' minutes</span></div>' +
      (manyOrgs ? '<div><span>Centre</span><span>' + esc(l.org_name) + '</span></div>' : '') +
      (l.parent_contact ? '<div><span>Parent</span><span><a href="tel:' + esc(String(l.parent_contact).replace(/[^\d+]/g, "")) + '">' + esc(l.parent_contact) + '</a></span></div>' : '') +
      (url ? '<div><span>Online link</span><span><a href="' + esc(url) + '" target="_blank" rel="noopener noreferrer">Join the lesson</a></span></div>' : '') +
      (wait ? '<div><span>Your request</span><span>' + esc(wr ? RC.ask(wr) : "Waiting for an admin") + '</span></div>' : '') +
      (c ? '<div><span>Status</span><span>' + esc(c.text) + '</span></div>' : '') +
      (l.trial ? '<div><span>Trial</span><span>This is a trial lesson</span></div>' : '') +
      (l.covering ? '<div><span>Covering</span><span>You are covering this lesson for another tutor</span></div>' : '') +
      (l.postponed ? '<div><span>Moved</span><span>This lesson was moved from its usual day</span></div>' : '') +
      (l.holiday ? '<div><span>Holiday</span><span>' + esc(l.holiday) + '</span></div>' : '') +
      (l.awaiting_centre ? '<div><span>To confirm</span><span>' + esc(TC.AWAITING_NOTE) + '</span></div>' : '') +
      '</div>' +
      (wait ? '<p class="tt-hint">Your request is waiting for an admin. You can change this lesson again once they have answered, or take your request back.</p>' +
              '<div class="msg err" id="ts-msg" role="alert" aria-live="assertive"></div><button type="button" class="btn" id="ts-do" data-do="req-cancel" data-req="' + esc(wait.request_id) + '" style="width:100%;min-height:46px">Take my request back</button>' :
      acts ? (l.class_size > 1 ? '<p class="tt-hint">This lesson is part of a class of ' + esc(l.class_size) + '. A change here changes the whole class.</p>' : '') +
              '<div class="tt-opts" id="ts-actions">' + acts + '</div><p class="tt-note">' + esc(TC.editNote(editing, o)) + '</p>'
            : '<p class="tt-note">' + esc(why || TC.editNote(editing, o)) + '</p>');
    $("tt-sheet").classList.add("on"); document.body.classList.add("sheet-lock");
    setTimeout(function () { try { $("ts-close").focus({ preventScroll: true }); } catch (e) {} }, 60);
  }

  // The form for one change. The reason is required (the centre keeps it); a move keeps the lesson's length, so only the day and start are asked.
  var FORM = {
    move:   { title: "Move this lesson", go: "Move lesson", cls: "btn-primary" },
    revert: { title: "Put this lesson back to its usual time", go: "Put back", cls: "btn-primary" },
    cancel: { title: "Cancel this lesson", go: "Cancel lesson", cls: "btn-danger" }
  };
  function showForm(act) {
    var l = cur, f = FORM[act], P = proposesFor(orgOf(l)), html = '<p class="tt-ro"><small>' + esc(P ? f.title.replace(/^(\w)/, function (c) { return "Ask to " + c.toLowerCase(); }) : f.title) + '</small>' + esc(l.student_name) + ' · ' + esc(TC.dateLabel(l.lesson_date, today)) + ' · ' + esc(TC.timeRange(l)) + '</p>';
    if (act === "move") {
      html += '<label class="tt-lbl" for="ts-date">New day</label><input class="tt-in" type="date" id="ts-date" min="' + esc(today) + '" value="' + esc(l.lesson_date) + '">' +
              '<label class="tt-lbl" for="ts-start" style="margin-top:12px">New start time</label><input class="tt-in" type="time" id="ts-start" value="' + esc(hhmm(l.start_time)) + '">' +
              '<p class="tt-hint" id="ts-end"></p>';
    } else if (act === "revert") {
      html += '<p class="tt-hint">It goes back to the day and time it normally has. Your centre is told.</p>';
    } else {
      html += '<p class="tt-hint">The family is not charged for a lesson you cancel in advance. Your centre is told and decides what happens next.</p>';
    }
    html += '<label class="tt-lbl" for="ts-reason">Why? (your centre sees this)</label><textarea class="tt-ta" id="ts-reason" maxlength="300" rows="3"></textarea>' +
            (l.class_size > 1 ? '<p class="tt-hint">This changes the whole class of ' + esc(l.class_size) + '.</p>' : '') + (P ? ASK_HINT : '') +
            '<div class="msg err" id="ts-msg" role="alert" aria-live="assertive"></div>' +
            '<button class="btn ' + f.cls + '" id="ts-go" type="button" data-act="' + act + '" style="width:100%;min-height:46px;margin-bottom:8px">' + esc(P ? "Send request" : f.go) + '</button>' +
            '<button class="btn" id="ts-back" type="button" style="width:100%;min-height:46px">Back</button>';
    $("ts-body").innerHTML = html;
    if (act === "move") { endHint(); $("ts-date").addEventListener("input", endHint); $("ts-start").addEventListener("input", endHint); }
    setTimeout(function () { var first = act === "move" ? $("ts-date") : $("ts-reason"); try { first.focus({ preventScroll: true }); } catch (e) {} }, 30);
  }
  function endHint() {
    var h = $("ts-end"); if (!h) return;
    var e = TC.endTime($("ts-start").value, cur.minutes);
    h.textContent = e ? "It stays " + cur.minutes + " minutes: it will end at " + TC.timeLabel(e + ":00") + "." : "That start time would run past midnight.";
  }
  async function submit(act) {
    if (busy) return;                                           // one press, one request
    var msg = $("ts-msg"), reason = ($("ts-reason").value || "").trim(), r, args = { p_lesson: cur.lesson_id, p_reason: reason }, fn;
    msg.textContent = "";
    if (reason.length < 3) { msg.textContent = TC.changeErrorText({ message: "REASON_REQUIRED" }); $("ts-reason").focus(); return; }
    if (act === "move") {
      args.p_date = $("ts-date").value; args.p_start = $("ts-start").value;
      if (!args.p_date || !args.p_start) { msg.textContent = TC.changeErrorText({ message: "BAD_DATE" }); return; }
      if (args.p_date < today) { msg.textContent = TC.changeErrorText({ message: "BAD_DATE" }); return; }
      if (!TC.endTime(args.p_start, cur.minutes)) { msg.textContent = TC.changeErrorText({ message: "BAD_TIME" }); return; }
      fn = "tutor_postpone_lesson";
    } else fn = act === "revert" ? "tutor_revert_lesson" : "tutor_cancel_lesson";
    busy = true; $("ts-go").disabled = true; $("ts-back").disabled = true;
    try { r = await window.sb.rpc(fn, args); } catch (e) { r = { error: e }; }
    busy = false;
    if (r.error) {
      msg.textContent = TC.changeErrorText(r.error);
      var g = $("ts-go"), b = $("ts-back"); if (g) g.disabled = false; if (b) b.disabled = false;
      loadWeek();                                               // the lesson may have changed under us: refresh the buttons behind this sheet
      return;
    }
    if (wasRequested(r)) { closeSheet(); TL.toast(RC.sentText(r.data)); loadWeek(); loadReqs(); return; }
    var d = r.data || {}, said = act === "cancel" ? "Lesson cancelled. The family isn't charged, and your centre has been told."
      : (act === "revert" ? "Put back to " : "Moved to ") + TC.dateLabel(d.lesson_date, today) + ", " + TC.timeLabel(d.start_time) + ".";
    closeSheet(); TL.toast(said); loadWeek();
  }
  function closeSheet() {
    $("tt-sheet").classList.remove("on"); document.body.classList.remove("sheet-lock");
    if (opener && document.body.contains(opener)) { try { opener.focus({ preventScroll: true }); } catch (e) {} }
  }

  function fail(err) {
    $("sc-sum").textContent = ""; $("sc-title").textContent = "";
    $("sc-week").innerHTML = '<div class="card"><div class="tt-empty">' + esc(TC.scheduleErrorText(err)) + '</div></div>';
    $("sc-slots").innerHTML = ""; $("sc-note").hidden = true; $("sc-slots").previousElementSibling.hidden = true;
    ["sc-prev", "sc-next", "sc-today"].forEach(function (i) { $(i).disabled = true; });
  }

  async function loadWeek() {
    var mine = ++seq;
    var r = await window.sb.rpc("tutor_my_schedule", { p_from: start, p_to: TC.addDays(start, 6) });
    if (mine !== seq) return;                                   // a newer week was asked for meanwhile
    if (r.error) return fail(r.error);
    data = r.data || { lessons: [], holidays: [], orgs: [] }; byId = {};
    var orgs = {}; (data.lessons || []).forEach(function (l) { byId[l.lesson_id] = l; orgs[l.org_id] = 1; });
    manyOrgs = (data.orgs || []).length > 1;
    editing = (data.orgs && data.orgs[0] && data.orgs[0].timetable_editing) || "admin_only";
    renderWeek(); note(); renderActions();
  }
  async function loadSlots() {
    var r = await window.sb.rpc("tutor_my_slots");
    if (r.error) { $("sc-slots").innerHTML = '<div class="card"><div class="tt-empty">' + esc(TC.scheduleErrorText(r.error)) + '</div></div>'; return; }
    renderSlots(r.data || []); renderActions();
  }
  function go(newStart) { start = newStart; $("sc-week").setAttribute("aria-busy", "true"); loadWeek().then(function () { $("sc-week").removeAttribute("aria-busy"); }); }


  // ================= T6 steps 3-4: add a lesson, my weekly slots, Create lessons =================
  // Every field here is plain: a student, a day, times, a subject, a note. There is no field for money anywhere; the database copies the student's usual details
  // (or the centre confirms them) and the answer only says "your centre will confirm the details" when that is so.
  function sheetOpen(title, sub, html, trigger) {
    if (trigger) opener = trigger;
    $("ts-title").textContent = title; $("ts-sub").textContent = sub || ""; $("ts-body").innerHTML = html;
    $("tt-sheet").classList.add("on"); document.body.classList.add("sheet-lock");
  }
  async function loadStudents() {
    if (students) return students;
    var r = await window.sb.rpc("tutor_my_students");
    if (r.error) throw r.error;
    students = r.data || []; return students;
  }
  function orgIds(flag) { return ((data && data.orgs) || []).filter(function (o) { return o[flag]; }).map(function (o) { return o.org_id; }); }
  function picker(id, flag, chosen) {
    var ids = orgIds(flag), list = TC.studentOptions(students).filter(function (x) { return ids.indexOf(x.org_id) >= 0; });
    var orgName = {}; ((data && data.orgs) || []).forEach(function (o) { orgName[o.org_id] = o.name; });
    if (!list.length) return null;
    return '<select class="tt-in" id="' + id + '">' + (list.length > 1 && !chosen ? '<option value="">Choose a student…</option>' : '') + list.map(function (x) {
      return '<option value="' + esc(x.id) + '" data-org="' + esc(x.org_id) + '" data-subject="' + esc(x.subject) + '" data-await="' + (x.awaiting_centre ? "1" : "") + '"' + (chosen === x.id ? " selected" : "") + '>' +
        esc(x.name + (x.level ? " (" + x.level + ")" : "") + (manyOrgs ? " · " + (orgName[x.org_id] || "") : "")) + '</option>';
    }).join("") + '</select>';
  }
  var NO_STUDENTS = '<p class="tt-hint">No students are assigned to you yet, so there is nobody to add. Ask an admin to assign your students.</p><button class="btn" type="button" data-do="close" style="width:100%;min-height:46px">Close</button>';
  function formButtons(go, label, extra) {
    return '<div class="msg err" id="ts-msg" role="alert" aria-live="assertive"></div>' +
      '<button class="btn btn-primary" id="ts-do" type="button" data-do="' + go + '" style="width:100%;min-height:46px;margin-bottom:8px">' + esc(label) + '</button>' + (extra || "") +
      '<button class="btn" type="button" data-do="close" style="width:100%;min-height:46px">Cancel</button>';
  }
  function timeFields(idA, idB, a, b) {
    return '<div class="tt-row2 tt-gap"><div><label class="tt-lbl" for="' + idA + '">Starts</label><input class="tt-in" type="time" id="' + idA + '" value="' + esc(hhmm(a)) + '"></div>' +
           '<div><label class="tt-lbl" for="' + idB + '">Ends</label><input class="tt-in" type="time" id="' + idB + '" value="' + esc(hhmm(b)) + '"></div></div>';
  }
  function autoEnd(startId, endId) {
    var st = $(startId), en = $(endId);
    st.addEventListener("input", function () { var e = TC.endTime(st.value, 60); if (e && (!en.value || en.value <= st.value)) en.value = e; });
  }
  async function showAdd(trigger) {
    sheetOpen("Add a lesson", "One lesson, for one of your students", '<p class="tt-hint">Loading your students…</p>', trigger);
    try { await loadStudents(); } catch (e) { $("ts-body").innerHTML = '<div class="msg err" role="alert">' + esc(TC.ownErrorText(e)) + '</div>'; return; }
    var sel = picker("ad-stu", "can_one_off");
    if (!sel) { $("ts-body").innerHTML = NO_STUDENTS; return; }
    $("ts-body").innerHTML = '<label class="tt-lbl" for="ad-stu">Student</label>' + sel +
      '<div class="tt-gap"><label class="tt-lbl" for="ad-date">Day</label><input class="tt-in" type="date" id="ad-date" min="' + esc(today) + '" value="' + esc(TC.addDays(today, 1)) + '"></div>' +
      timeFields("ad-start", "ad-end", "", "") +
      '<div class="tt-gap"><label class="tt-lbl" for="ad-subj">Subject (optional)</label><input class="tt-in" type="text" id="ad-subj" maxlength="60"></div>' +
      '<div class="tt-gap"><label class="tt-lbl" for="ad-note">Note for your centre (optional)</label><textarea class="tt-ta" id="ad-note" maxlength="300" rows="2" style="margin-bottom:6px"></textarea></div>' +
      '<p class="tt-hint" id="ad-hint"></p>' + (proposesFor(firstOrg()) ? ASK_HINT : '') + formButtons("add-go", sendLabel("Add lesson"));
    function hint() {
      var o = $("ad-stu").selectedOptions[0];
      $("ad-hint").textContent = o && o.value ? (o.getAttribute("data-await") ? TC.AWAITING_NOTE + " " : "") + "It can't be a trial or a group class, and it must start at least " + noticeText() + " from now." : "";
      $("ad-subj").placeholder = (o && o.getAttribute("data-subject")) || "";
    }
    $("ad-stu").addEventListener("change", hint); hint(); autoEnd("ad-start", "ad-end");
    setTimeout(function () { try { $("ad-stu").focus({ preventScroll: true }); } catch (e) {} }, 30);
  }
  function noticeText() {
    var o = ((data && data.orgs) || [])[0] || {}, n = o.min_notice_hours == null ? 24 : o.min_notice_hours;
    return n > 0 ? n + " hour" + (n === 1 ? "" : "s") : "a moment";
  }
  async function doAdd() {
    if (busy) return;
    var msg = $("ts-msg"), c = TC.addLessonCheck({ student: $("ad-stu").value, date: $("ad-date").value, start: $("ad-start").value, end: $("ad-end").value, subject: $("ad-subj").value, note: $("ad-note").value }, today);
    msg.textContent = "";
    if (c.error) { msg.textContent = c.error; return; }
    busy = true; $("ts-do").disabled = true;
    var r; try { r = await window.sb.rpc("tutor_add_lesson", c.args); } catch (e) { r = { error: e }; }
    busy = false;
    if (r.error) { msg.textContent = TC.ownErrorText(r.error); var g = $("ts-do"); if (g) g.disabled = false; return; }
    if (wasRequested(r)) { closeSheet(); students = null; TL.toast(RC.sentText(r.data)); loadWeek(); loadReqs(); return; }
    var d = r.data || {}; closeSheet(); students = null;
    TL.toast("Lesson added for " + TC.dateLabel(d.lesson_date, today) + "." + (d.awaiting_centre ? " " + TC.AWAITING_NOTE : ""));
    go(TC.weekStart(d.lesson_date || today));
  }

  // one weekly slot: add (no id) or change (an id; the student can't change)
  var slotCur = null;
  async function showSlot(slot, trigger) {
    slotCur = slot || null;
    sheetOpen(slot ? "Change this weekly slot" : "Add a weekly slot", slot ? slot.students.map(function (x) { return x.name; }).join(", ") : "Every week, for one of your students", '<p class="tt-hint">Loading…</p>', trigger);
    var who;
    if (slot) who = '<p class="tt-ro"><small>Student</small>' + esc(slot.students.map(function (x) { return x.name + (x.level ? " (" + x.level + ")" : ""); }).join(", ")) + '</p>';
    else {
      try { await loadStudents(); } catch (e) { $("ts-body").innerHTML = '<div class="msg err" role="alert">' + esc(TC.ownErrorText(e)) + '</div>'; return; }
      var sel = picker("sl-stu", "can_slots");
      if (!sel) { $("ts-body").innerHTML = NO_STUDENTS; return; }
      who = '<label class="tt-lbl" for="sl-stu">Student</label>' + sel;
    }
    var wd = TC.weekdayOptions().map(function (o) { return '<option value="' + o.value + '"' + (slot && slot.weekday === o.value ? " selected" : "") + '>' + esc(o.label) + '</option>'; }).join("");
    $("ts-body").innerHTML = who + '<div class="tt-gap"><label class="tt-lbl" for="sl-wd">Day of the week</label><select class="tt-in" id="sl-wd">' + (slot ? "" : '<option value="">Choose a day…</option>') + wd + '</select></div>' +
      timeFields("sl-start", "sl-end", slot ? slot.start_time : "", slot ? slot.end_time : "") +
      '<div class="tt-gap"><label class="tt-lbl" for="sl-subj">Subject (optional)</label><input class="tt-in" type="text" id="sl-subj" maxlength="60" value="' + esc(slot ? slot.subject || "" : "") + '"></div>' +
      '<p class="tt-hint">' + (slot ? "Lessons already made from this slot don't change. Use Create lessons to make the next ones." : "Press Create lessons afterwards to make the lessons for the coming weeks.") + '</p>' +
      (proposesFor(firstOrg()) ? ASK_HINT : '') + formButtons("slot-go", sendLabel(slot ? "Save changes" : "Add weekly slot"), slot ? '<button class="btn tt-stop" type="button" data-do="slot-stop" style="width:100%;min-height:46px;margin-bottom:8px">Stop this weekly slot</button>' : "");
    autoEnd("sl-start", "sl-end");
    setTimeout(function () { try { (slot ? $("sl-wd") : $("sl-stu")).focus({ preventScroll: true }); } catch (e) {} }, 30);
  }
  async function doSlot() {
    if (busy) return;
    var msg = $("ts-msg"), c = TC.slotCheck({ slot: slotCur && slotCur.slot_id, student: $("sl-stu") && $("sl-stu").value, weekday: $("sl-wd").value, start: $("sl-start").value, end: $("sl-end").value, subject: $("sl-subj").value });
    msg.textContent = "";
    if (c.error) { msg.textContent = c.error; return; }
    busy = true; $("ts-do").disabled = true;
    var r; try { r = await window.sb.rpc("tutor_save_slot", c.args); } catch (e) { r = { error: e }; }
    busy = false;
    if (r.error) { msg.textContent = TC.ownErrorText(r.error); var g = $("ts-do"); if (g) g.disabled = false; return; }
    if (wasRequested(r)) { closeSheet(); students = null; TL.toast(RC.sentText(r.data)); loadSlots(); loadReqs(); return; }
    var d = r.data || {}; closeSheet(); students = null;
    TL.toast(d.added ? "Weekly slot added." + (d.awaiting_centre ? " " + TC.AWAITING_NOTE : "") : "Weekly slot changed." + (d.lessons_left ? " Its " + d.lessons_left + " coming lesson" + (d.lessons_left === 1 ? "" : "s") + " stay as they are." : ""));
    loadSlots(); loadWeek();
  }
  function showSlotStop() {
    var sl = slotCur;
    $("ts-title").textContent = "Stop this weekly slot?";
    $("ts-body").innerHTML = '<p class="tt-ro"><small>Weekly slot</small>' + esc(sl.students.map(function (x) { return x.name; }).join(", ") + " · " + TC.weekdayName(sl.weekday) + " " + TC.timeRange(sl)) + '</p>' +
      '<p class="tt-hint">No new lessons will be made from it. Lessons already made stay. You can add the slot again later.</p>' +
      '<div class="msg err" id="ts-msg" role="alert" aria-live="assertive"></div>' +
      (proposesFor(firstOrg()) ? ASK_HINT : '') +
      '<button class="btn btn-danger" id="ts-do" type="button" data-do="slot-stop-go" style="width:100%;min-height:46px;margin-bottom:8px">' + (proposesFor(firstOrg()) ? "Send request to stop it" : "Stop weekly slot") + '</button>' +
      '<button class="btn" type="button" data-do="slot-back" style="width:100%;min-height:46px">Back</button>';
  }
  async function doSlotStop() {
    if (busy) return;
    busy = true; $("ts-do").disabled = true;
    var r; try { r = await window.sb.rpc("tutor_stop_slot", { p_slot: slotCur.slot_id }); } catch (e) { r = { error: e }; }
    busy = false;
    if (r.error) { $("ts-msg").textContent = TC.ownErrorText(r.error); var g = $("ts-do"); if (g) g.disabled = false; return; }
    if (wasRequested(r)) { closeSheet(); TL.toast(RC.sentText(r.data)); loadSlots(); loadReqs(); return; }
    closeSheet(); TL.toast("Weekly slot stopped."); loadSlots();
  }

  // Create lessons: today to the chosen last day, for my own slots
  function showGenerate(trigger) {
    var os = ((data && data.orgs) || []).filter(function (o) { return o.can_generate; });
    sheetOpen("Create lessons", "From your weekly slots", (os.length > 1 ? '<label class="tt-lbl" for="gn-org">Centre</label><select class="tt-in" id="gn-org">' + os.map(function (o) { return '<option value="' + esc(o.org_id) + '">' + esc(o.name) + '</option>'; }).join("") + '</select><div class="tt-gap"></div>' : "") +
      '<label class="tt-lbl" for="gn-to">Make lessons up to and including</label><input class="tt-in" type="date" id="gn-to" min="' + esc(today) + '" max="' + esc(TC.addDays(today, 62)) + '" value="' + esc(TC.generateEnd(today)) + '">' +
      '<p class="tt-hint">This makes the lessons of your own weekly slots, from today to that day (62 days at most). Pressing it again never makes the same lesson twice. Holidays and students whose lessons have ended are left out.</p>' +
      (proposesFor(os[0]) ? ASK_HINT : '') + formButtons("gen-go", proposesFor(os[0]) ? "Send request" : "Create lessons"), trigger);
    setTimeout(function () { try { $("gn-to").focus({ preventScroll: true }); } catch (e) {} }, 30);
  }
  async function doGenerate() {
    if (busy) return;
    var os = ((data && data.orgs) || []).filter(function (o) { return o.can_generate; }), org = $("gn-org") ? $("gn-org").value : (os[0] && os[0].org_id), msg = $("ts-msg");
    var c = TC.generateCheck({ org: org, to: $("gn-to").value }, today); msg.textContent = "";
    if (c.error) { msg.textContent = c.error; return; }
    busy = true; $("ts-do").disabled = true;
    var r; try { r = await window.sb.rpc("tutor_generate_lessons", c.args); } catch (e) { r = { error: e }; }
    busy = false;
    if (r.error) { msg.textContent = TC.ownErrorText(r.error); var g = $("ts-do"); if (g) g.disabled = false; return; }
    if (wasRequested(r)) { closeSheet(); TL.toast(RC.sentText(r.data)); loadReqs(); return; }
    $("ts-title").textContent = "Lessons created";
    $("ts-body").innerHTML = '<div class="tt-done">' + esc(TC.generateSummary(r.data)) + '</div><button class="btn btn-primary" type="button" data-do="close" style="width:100%;min-height:46px">Done</button>';
    loadWeek(); loadSlots();
  }
  function openSlotSheet(slot, trigger) {
    if (trigger) opener = trigger;
    var t = TC.timeRange(slot);
    sheetOpen(slot.students.map(function (x) { return x.name; }).join(", "), TC.weekdayName(slot.weekday) + " · " + t,
      '<div class="tt-facts"><div><span>Every</span><span>' + esc(TC.weekdayName(slot.weekday)) + '</span></div><div><span>Time</span><span>' + esc(t) + '</span></div>' +
      (slot.subject ? '<div><span>Subject</span><span>' + esc(slot.subject) + '</span></div>' : '') +
      (slot.awaiting_centre ? '<div><span>To confirm</span><span>' + esc(TC.AWAITING_NOTE) + '</span></div>' : '') +
      (slot.pending_request ? '<div><span>Your request</span><span>' + esc(reqById[slot.pending_request] ? RC.ask(reqById[slot.pending_request]) : "Waiting for an admin") + '</span></div>' : '') + '</div>' +
      (slot.pending_request ? '<p class="tt-hint">Your request is waiting for an admin. You can change this slot again once they have answered, or take your request back.</p>' +
          '<div class="msg err" id="ts-msg" role="alert" aria-live="assertive"></div><button type="button" class="btn" id="ts-do" data-do="req-cancel" data-req="' + esc(slot.pending_request) + '" style="width:100%;min-height:46px">Take my request back</button>' :
        '<div class="tt-opts"><button type="button" class="tt-opt" data-do="slot-edit">' + (proposesFor(firstOrg()) ? "Ask to change" : "Change") + '</button><button type="button" class="tt-opt danger" data-do="slot-stop">' + (proposesFor(firstOrg()) ? "Ask to stop" : "Stop") + '</button></div>'));
    slotCur = slot;
  }
  // ---- T6 steps 5-6: the online link, and my requests
  var linkScope = "lesson";
  function showLink(scope) {
    var l = cur, P = proposesFor(orgOf(l)); linkScope = scope;
    var now = scope === "lesson" ? (l.lesson_link || "") : (l.student_link || "");
    $("ts-title").textContent = scope === "lesson" ? "Online link for this lesson" : l.student_name + "'s usual online link";
    $("ts-body").innerHTML = '<p class="tt-ro"><small>' + (scope === "lesson" ? "Only this lesson" : "Every lesson of " + esc(l.student_name) + " without a link of its own") + '</small>' +
      esc(l.student_name) + ' · ' + esc(TC.dateLabel(l.lesson_date, today)) + ' · ' + esc(TC.timeRange(l)) + '</p>' +
      '<label class="tt-lbl" for="lk-url">Link</label><input class="tt-in" type="url" inputmode="url" id="lk-url" maxlength="500" placeholder="https://" autocomplete="off" value="' + esc(now) + '">' +
      '<p class="tt-hint">Paste the meeting link. It must start with https://. Leave it empty to remove it' + (scope === "lesson" ? ", and the lesson uses the usual link again" : "") + '.</p>' + (P ? ASK_HINT : '') +
      '<div class="msg err" id="ts-msg" role="alert" aria-live="assertive"></div>' +
      '<button class="btn btn-primary" id="ts-do" type="button" data-do="link-go" style="width:100%;min-height:46px;margin-bottom:8px">' + (P ? "Send request" : "Save link") + '</button>' +
      '<button class="btn" type="button" data-do="link-back" style="width:100%;min-height:46px">Back</button>';
    setTimeout(function () { try { $("lk-url").focus({ preventScroll: true }); } catch (e) {} }, 30);
  }
  async function doLink() {
    if (busy) return;
    var msg = $("ts-msg"), c = RC.linkCheck($("lk-url").value), l = cur; msg.textContent = "";
    if (c.error) { msg.textContent = c.error; return; }
    busy = true; $("ts-do").disabled = true;
    var args = linkScope === "lesson" ? { p_student: null, p_lesson: l.lesson_id, p_link: c.link } : { p_student: l.student_id, p_lesson: null, p_link: c.link }, r;
    try { r = await window.sb.rpc("tutor_set_link", args); } catch (e) { r = { error: e }; }
    busy = false;
    if (r.error) { msg.textContent = TC.ownErrorText(r.error); var g = $("ts-do"); if (g) g.disabled = false; return; }
    closeSheet();
    if (wasRequested(r)) { TL.toast(RC.sentText(r.data)); loadReqs(); loadWeek(); return; }
    TL.toast(r.data && r.data.changed === false ? "That is already the link." : (c.link ? "Link saved." : "Link removed."));
    loadWeek();
  }
  async function loadReqs() {
    var r; try { r = await window.sb.rpc("tutor_my_requests"); } catch (e) { r = { error: e }; }
    if (r.error) { reqs = []; reqById = {}; renderReqs(); return; }
    reqs = (r.data && r.data.rows) || []; reqById = {}; reqs.forEach(function (x) { reqById[x.request_id] = x; });
    renderReqs();
  }
  function renderReqs() {
    var any = ((data && data.orgs) || []).some(function (o) { return o.proposes; }), h = $("sc-reqs-h"), box = $("sc-reqs");
    h.hidden = !(any || reqs.length);
    if (!reqs.length) { box.innerHTML = any ? '<div class="card"><div class="tt-empty">You have not asked for anything yet. Tap a lesson to ask for a change.</div></div>' : ""; return; }
    box.innerHTML = '<div class="card tt-list sc-slot">' + reqs.map(function (r) {
      var st = RC.status(r, false);
      return '<button type="button" class="sc-tap" data-req="' + esc(r.request_id) + '"><span class="tt-main"><span class="tt-name">' + esc(RC.headline(r, false)) + '</span><span class="tt-sub">' +
        esc(RC.ask(r) + (r.status === "pending" ? " · " + RC.expires(r, today) : "")) + '</span></span><span class="tt-chip ' + esc(st.tone) + '">' + esc(st.text) + '</span>' + chev() + '</button>';
    }).join("") + '</div>';
  }
  function openReqSheet(r, trigger) {
    if (trigger) opener = trigger;
    var st = RC.status(r, false), nowTxt = RC.now(r), out = RC.outcome(r);
    sheetOpen(RC.headline(r, false), st.text, '<div class="tt-facts"><div><span>You asked</span><span>' + esc(RC.ask(r)) + '</span></div>' +
      (nowTxt ? '<div><span>Now</span><span>' + esc(nowTxt.replace(/^Now /, "")) + '</span></div>' : '') +
      (manyOrgs ? '<div><span>Centre</span><span>' + esc(r.org_name) + '</span></div>' : '') +
      (r.reason ? '<div><span>Your reason</span><span>' + esc(r.reason) + '</span></div>' : '') +
      '<div><span>When</span><span>' + esc(RC.asked(r, today) + (r.status === "pending" ? " · " + RC.expires(r, today) : "")) + '</span></div></div>' +
      (out ? '<p class="tt-note">' + esc(out) + '</p>' : '') +
      '<div class="msg err" id="ts-msg" role="alert" aria-live="assertive"></div>' +
      (r.status === "pending" ? '<button type="button" class="btn" id="ts-do" data-do="req-cancel" data-req="' + esc(r.request_id) + '" style="width:100%;min-height:46px;margin-bottom:8px">Take my request back</button>' : '') +
      '<button type="button" class="btn" data-do="close" style="width:100%;min-height:46px">Close</button>');
  }
  async function doReqCancel(id) {
    if (busy || !id) return;
    busy = true; var b = $("ts-do"); if (b) b.disabled = true;
    var r; try { r = await window.sb.rpc("tutor_cancel_request", { p_request: id }); } catch (e) { r = { error: e }; }
    busy = false;
    if (r.error) { var m = $("ts-msg"); if (m) m.textContent = TC.changeErrorText(r.error); if (b) b.disabled = false; loadReqs(); loadWeek(); loadSlots(); return; }
    closeSheet(); TL.toast("Request taken back. Nothing was changed."); loadReqs(); loadWeek(); loadSlots();
  }
  function doAction(a, el) {
    if (a === "req-cancel") return doReqCancel(el && el.getAttribute("data-req"));
    if (a === "link-lesson") return showLink("lesson");
    if (a === "link-student") return showLink("student");
    if (a === "link-back") return openSheet(cur);
    if (a === "link-go") return doLink();
    if (a === "close") return closeSheet();
    if (a === "add-go") return doAdd();
    if (a === "slot-go") return doSlot();
    if (a === "slot-edit") return showSlot(slotCur);
    if (a === "slot-back") return showSlot(slotCur);
    if (a === "slot-stop") return showSlotStop();
    if (a === "slot-stop-go") return doSlotStop();
    if (a === "gen-go") return doGenerate();
  }

  function init() {
    today = TL.todayISO(); start = TC.weekStart(today);
    $("sc-prev").addEventListener("click", function () { go(TC.addDays(start, -7)); });
    $("sc-next").addEventListener("click", function () { go(TC.addDays(start, 7)); });
    $("sc-today").addEventListener("click", function () { go(TC.weekStart(today)); });
    $("sc-week").addEventListener("click", function (e) { var b = e.target.closest(".tt-row"); if (b && byId[b.getAttribute("data-id")]) openSheet(byId[b.getAttribute("data-id")], b); });
    $("sc-add").addEventListener("click", function () { showAdd(this); });
    $("sc-add-slot").addEventListener("click", function () { showSlot(null, this); });
    $("sc-generate").addEventListener("click", function () { showGenerate(this); });
    $("sc-reqs").addEventListener("click", function (e) { var b = e.target.closest("[data-req]"); if (b && reqById[b.getAttribute("data-req")]) openReqSheet(reqById[b.getAttribute("data-req")], b); });
    $("sc-slots").addEventListener("click", function (e) { var b = e.target.closest(".sc-tap"); if (b && slotById[b.getAttribute("data-slot")]) openSlotSheet(slotById[b.getAttribute("data-slot")], b); });
    $("ts-close").addEventListener("click", closeSheet);
    $("ts-body").addEventListener("click", function (e) {
      var dd = e.target.closest("[data-do]"); if (dd) { doAction(dd.getAttribute("data-do"), dd); return; }
      var a = e.target.closest("[data-act]"), back = e.target.closest("#ts-back");
      if (back) { if (!busy) openSheet(cur); return; }
      if (!a) return;
      if (a.id === "ts-go") submit(a.getAttribute("data-act")); else showForm(a.getAttribute("data-act"));
    });
    $("tt-sheet").addEventListener("click", function (e) { if (e.target === $("tt-sheet")) closeSheet(); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && $("tt-sheet").classList.contains("on")) closeSheet(); });
    loadWeek().then(function () { if (data) { loadSlots(); loadReqs(); } });
    try { TL.detectRole(); } catch (e) {}
  }
  TL.requireAuth("tutor-schedule", init);
})();
