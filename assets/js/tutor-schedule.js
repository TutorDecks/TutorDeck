// Schedule — a centre tutor's own week and weekly slots (T6). The page calls database functions only and never reads a table: tutor_my_schedule and
// tutor_my_slots to look, and (T6 step 2, only when the centre has switched it on) tutor_postpone_lesson, tutor_revert_lesson and tutor_cancel_lesson to
// move a lesson, put it back, or cancel it in advance. Nothing here returns, shows or sends anything about money: a move keeps the lesson's length, and a
// cancel is "no charge to the family" decided by the database. Every button shown comes from the database's own answer (can_postpone / can_revert /
// can_cancel), so the screen can't offer what the rules refuse. Pure logic lives in assets/js/tutor-core.js (unit-tested).
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var esc = function (s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var TC = window.TutorCore, TCAL = window.TutorCalendar, today = "", start = "", data = null, byId = {}, manyOrgs = false, editing = "admin_only", opener = null, seq = 0, cur = null, busy = false;
  var view = "list", sel = "", HP = 58;     // UX1: "list" | "cal" (remembered per user), the day shown on a phone's calendar, pixels per hour
  function isPhone() { return !!(window.matchMedia && window.matchMedia("(max-width:820px)").matches); }
  var WD1 = ["M", "T", "W", "T", "F", "S", "S"], WD3 = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
  function calPhone() { return view === "cal" && isPhone(); }
  function orgOf(l) { return ((data && data.orgs) || []).filter(function (o) { return o.org_id === (l && l.org_id); })[0] || ((data && data.orgs) || [])[0] || {}; }
  function hhmm(t) { return String(t || "").slice(0, 5); }

  function chev() { return '<svg class="tt-chev" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="m9 18 6-6-6-6"/></svg>'; }

  function row(l) {
    var c = TC.scheduleChip(l), t = TC.timeLabel(l.start_time).split(" ");
    return '<button type="button" class="tt-row" data-id="' + esc(l.lesson_id) + '">' +
      '<span class="tt-time"><b>' + esc(t[0] || "") + '</b><small>' + esc(t[1] || "") + '</small></span>' +
      '<span class="tt-main"><span class="tt-name">' + esc(l.student_name) + '</span><span class="tt-sub">' + esc(TC.scheduleFacts(l, manyOrgs).join(" · ") || "Lesson") + '</span></span>' +
      (c ? '<span class="tt-chip ' + c.tone + '">' + esc(c.text) + '</span>' : '') + chev() + '</button>';
  }

  // The title above the list / grid: the week (list, and the desktop grid) or the one day on show (a phone's calendar).
  function renderTitle() {
    var end = TC.addDays(start, 6);
    if (calPhone() && sel) { $("sc-title").innerHTML = esc(TC.dateLabel(sel, today)) + '<small>' + esc(TC.weekTitle(start, today) + " · " + TC.rangeLabel(start, end)) + '</small>'; }
    else $("sc-title").innerHTML = esc(TC.weekTitle(start, today)) + '<small>' + esc(TC.rangeLabel(start, end)) + '</small>';
    var step = calPhone() ? "day" : "week";
    $("sc-prev").setAttribute("aria-label", "Previous " + step); $("sc-next").setAttribute("aria-label", "Next " + step);
  }

  function renderWeek() {
    var end = TC.addDays(start, 6), days = TC.scheduleDays(data, start, end), n = 0, html = "";
    (data.lessons || []).forEach(function (l) { if (!l.cancelled) n++; });
    renderTitle();
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


  // ---- Calendar view: a week grid (days across, time down); on a phone one day at a time under a Mon-Sun strip. Same chips, same sheet, no money. ----
  function evHtml(b, top, h, narrow) {
    var l = b.l, c = TCAL.chip(l), key = c ? c.key : "upcoming", st = TCAL.state(l), t0 = TCAL.hhmm(b.startMin);
    var label = TC.timeRange(l) + ", " + l.student_name + (l.subject ? ", " + l.subject : "") + (c ? ", " + c.text : "") + (manyOrgs ? ", " + l.org_name : "");
    var w = 100 / b.lanes, sub = [l.student_level, l.subject].filter(Boolean).join(" · ");
    return '<button type="button" class="sc-ev k-' + key + (h < 52 ? " tight" : "") + (narrow ? " narrow" : "") + '" data-id="' + esc(l.lesson_id) + '" aria-label="' + esc(label) + '" ' +
      'style="top:' + top + 'px;height:' + Math.max(h - 2, 16) + 'px;left:calc(' + (b.lane * w) + '% + 1px);width:calc(' + w + '% - 2px)">' +
      '<span class="e-n"><span class="e-t">' + esc(TC.timeLabel(t0 + ":00").replace(" ", "")) + '</span> ' + esc(l.student_name) + '</span>' +
      (sub ? '<span class="e-s">' + esc(sub) + '</span>' : '') + (c ? '<span class="e-c">' + (st.key === "attended" ? "✓ " : "") + esc(c.text) + '</span>' : '') + '</button>';
  }
  function colHtml(day, bd, today2, narrow) {
    var evs = TCAL.layoutDay(day.lessons).map(function (b) { return evHtml(b, (b.startMin - bd.start) / 60 * HP, (b.endMin - b.startMin) / 60 * HP, narrow || b.lanes > 2); }).join("");
    return '<div class="sc-col' + (day.date === today2 ? " today" : "") + (day.holidays.length ? " hol" : "") + '" data-date="' + day.date + '">' + evs + '</div>';
  }
  function renderCal() {
    var days = TCAL.week(data, start), all = data.lessons || [], bd = TCAL.bounds(all), hrs = (bd.end - bd.start) / 60, gutter = "", phone = isPhone(), html = "";
    for (var h = 0; h < hrs; h++) gutter += '<div class="sc-hr">' + esc(TC.timeLabel(TCAL.hhmm(bd.start + h * 60) + ":00").replace(":00 ", " ")) + '</div>';
    var style = '--hp:' + HP + 'px;height:' + (hrs * HP) + 'px';
    if (phone) {
      var one = days.filter(function (d) { return d.date === sel; })[0] || days[0];
      html += '<div class="sc-strip" role="group" aria-label="Days of this week">' + days.map(function (d, di) {
        var n = d.lessons.filter(function (l) { return !l.cancelled; }).length, dots = "";
        for (var i = 0; i < Math.min(n, 3); i++) dots += "<i></i>";
        return '<button type="button" class="sc-sd' + (d.date === one.date ? " on" : "") + (d.date === today ? " today" : "") + (d.holidays.length ? " hol" : "") + '" data-day="' + d.date + '" aria-pressed="' + (d.date === one.date) + '" aria-label="' +
          esc(TC.dateLabel(d.date, today) + (n ? ", " + n + " lesson" + (n === 1 ? "" : "s") : "") + (d.holidays.length ? ", holiday" : "")) + '"><span>' + WD1[di] + '</span><b>' + Number(d.date.slice(8)) + '</b><span class="sc-dots">' + dots + '</span></button>';
      }).join("") + '</div>';
      if (one.holidays.length) html += '<div class="sc-holband">' + esc(one.holidays.join(", ")) + ' · holiday</div>';
      html += '<div class="sc-cbody"><div class="sc-hours" style="' + style + '">' + gutter + '</div><div class="sc-cols" style="' + style + '">' + colHtml(one, bd, today) + '</div></div>';
      if (!one.lessons.length) html += '<div class="sc-none">No lessons on ' + esc(TC.dateLabel(one.date, today)) + '. Swipe or tap another day.</div>';
    } else {
      html += '<div class="sc-chead"><div class="sc-gut"></div>' + days.map(function (d, di) {
        return '<div class="sc-dh' + (d.date === today ? " today" : "") + (d.holidays.length ? " hol" : "") + '">' + WD3[di] + '<b>' + Number(d.date.slice(8)) + '</b>' +
          (d.holidays.length ? '<small title="' + esc(d.holidays.join(", ")) + '">' + esc(d.holidays[0]) + '</small>' : '') + '</div>';
      }).join("") + '</div><div class="sc-cbody"><div class="sc-hours" style="' + style + '">' + gutter + '</div><div class="sc-cols" style="' + style + '">' + days.map(function (d) { return colHtml(d, bd, today); }).join("") + '</div></div>';
      if (!all.length) html += '<div class="sc-none">No lessons this week.</div>';
    }
    $("sc-cal").innerHTML = html;
  }
  function applyView() {
    var cal = view === "cal";
    $("sc-v-list").classList.toggle("on", !cal); $("sc-v-cal").classList.toggle("on", cal);
    $("sc-v-list").setAttribute("aria-pressed", String(!cal)); $("sc-v-cal").setAttribute("aria-pressed", String(cal));
    $("sc-week").hidden = cal; $("sc-cal").hidden = !cal;
    if (data) { if (cal) { sel = TCAL.pickDay(start, today, sel); renderCal(); } renderTitle(); }
  }
  function setView(v) { view = v; try { TL.store.set("tutor_sched_view", v); } catch (e) {} applyView(); }
  // Prev / next: a week at a time, or (a phone's calendar) a day at a time, moving into the next week when it has to.
  function step(n) {
    if (!calPhone()) { go(TC.addDays(start, 7 * n)); return; }
    sel = TC.addDays(sel || start, n);
    var ws = TC.weekStart(sel);
    if (ws !== start) go(ws); else { renderCal(); renderTitle(); }
  }

  function renderSlots(rows) {
    var list = TC.slotList(rows);
    if (!list.length) { $("sc-slots").innerHTML = '<div class="card"><div class="tt-empty">You have no weekly slots yet. When your centre gives you a regular class, it will appear here.</div></div>'; return; }
    $("sc-slots").innerHTML = '<div class="card tt-list sc-slot">' + list.map(function (s) {
      var names = s.students.map(function (x) { return x.name + (x.level ? " (" + x.level + ")" : ""); }).join(", ");
      var t = TC.timeLabel(s.start_time).split(" ");
      return '<div class="sc-row"><span class="sc-wd">' + esc(TC.weekdayName(s.weekday).slice(0, 3)) + '</span>' +
        '<span class="tt-time"><b>' + esc(t[0] || "") + '</b><small>' + esc(t[1] || "") + '</small></span>' +
        '<span class="tt-main"><span class="tt-name">' + esc(names) + '</span><span class="tt-sub">' + esc([TC.timeRange(s), s.subject, manyOrgs ? s.org_name : null].filter(Boolean).join(" · ")) + '</span></span></div>';
    }).join("") + '</div>';
  }

  function note() { var n = $("sc-note"); n.textContent = TC.editNote(editing, ((data && data.orgs) || [])[0]); n.hidden = false; }

  function openSheet(l, trigger) {
    if (trigger) opener = trigger;
    cur = l;
    $("ts-title").textContent = l.student_name;
    $("ts-sub").textContent = TC.dateLabel(l.lesson_date, today) + " · " + TC.timeRange(l);
    var c = TC.scheduleChip(l), url = /^https:\/\/\S+$/.test(l.online_link || "") ? l.online_link : null, o = orgOf(l);
    var acts = (l.can_postpone ? '<button type="button" class="tt-opt" data-act="move">Move</button>' : '') +
               (l.can_revert ? '<button type="button" class="tt-opt" data-act="revert">Put back to usual time</button>' : '') +
               (l.can_cancel ? '<button type="button" class="tt-opt danger" data-act="cancel">Cancel lesson</button>' : '');
    var why = !acts && o.can_edit && l.change_block ? TC.blockText(l.change_block, o) : "";
    $("ts-body").innerHTML = '<div class="tt-facts">' +
      (l.student_level || l.subject ? '<div><span>Class</span><span>' + esc([l.student_level, l.subject].filter(Boolean).join(" · ")) + '</span></div>' : '') +
      '<div><span>Length</span><span>' + esc(l.minutes) + ' minutes</span></div>' +
      (manyOrgs ? '<div><span>Centre</span><span>' + esc(l.org_name) + '</span></div>' : '') +
      (l.parent_contact ? '<div><span>Parent</span><span><a href="tel:' + esc(String(l.parent_contact).replace(/[^\d+]/g, "")) + '">' + esc(l.parent_contact) + '</a></span></div>' : '') +
      (url ? '<div><span>Online link</span><span><a href="' + esc(url) + '" target="_blank" rel="noopener noreferrer">Join the lesson</a></span></div>' : '') +
      (c ? '<div><span>Status</span><span>' + esc(c.text) + '</span></div>' : '') +
      (l.trial ? '<div><span>Trial</span><span>This is a trial lesson</span></div>' : '') +
      (l.covering ? '<div><span>Covering</span><span>You are covering this lesson for another tutor</span></div>' : '') +
      (l.postponed ? '<div><span>Moved</span><span>This lesson was moved from its usual day</span></div>' : '') +
      (l.holiday ? '<div><span>Holiday</span><span>' + esc(l.holiday) + '</span></div>' : '') +
      '</div>' +
      (acts ? (l.class_size > 1 ? '<p class="tt-hint">This lesson is part of a class of ' + esc(l.class_size) + '. A change here changes the whole class.</p>' : '') +
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
    var l = cur, f = FORM[act], html = '<p class="tt-ro"><small>' + esc(f.title) + '</small>' + esc(l.student_name) + ' · ' + esc(TC.dateLabel(l.lesson_date, today)) + ' · ' + esc(TC.timeRange(l)) + '</p>';
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
            (l.class_size > 1 ? '<p class="tt-hint">This changes the whole class of ' + esc(l.class_size) + '.</p>' : '') +
            '<div class="msg err" id="ts-msg" role="alert" aria-live="assertive"></div>' +
            '<button class="btn ' + f.cls + '" id="ts-go" type="button" data-act="' + act + '" style="width:100%;min-height:46px;margin-bottom:8px">' + esc(f.go) + '</button>' +
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
    $("sc-week").hidden = false; $("sc-cal").hidden = true; $("sc-seg").hidden = true;
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
    sel = TCAL.pickDay(start, today, sel);
    renderWeek(); if (view === "cal") renderCal(); note();
  }
  async function loadSlots() {
    var r = await window.sb.rpc("tutor_my_slots");
    if (r.error) { $("sc-slots").innerHTML = '<div class="card"><div class="tt-empty">' + esc(TC.scheduleErrorText(r.error)) + '</div></div>'; return; }
    renderSlots(r.data || []);
  }
  function go(newStart) { start = newStart; $("sc-week").setAttribute("aria-busy", "true"); loadWeek().then(function () { $("sc-week").removeAttribute("aria-busy"); }); }

  function init() {
    today = TL.todayISO(); start = TC.weekStart(today); sel = today;
    try { view = TL.store.get("tutor_sched_view") === "cal" ? "cal" : "list"; } catch (e) {}
    var asked = (/[?&]d=(\d{4}-\d{2}-\d{2})(?:&|$)/.exec(location.search) || [])[1];      // /tutor-schedule?d=2026-11-24 opens the week of that day (the solo calendar links here)
    if (asked) { start = TC.weekStart(asked); sel = asked; }
    $("sc-prev").addEventListener("click", function () { step(-1); });
    $("sc-next").addEventListener("click", function () { step(1); });
    $("sc-today").addEventListener("click", function () { sel = today; if (TC.weekStart(today) !== start) go(TC.weekStart(today)); else { if (view === "cal") renderCal(); renderTitle(); } });
    $("sc-v-list").addEventListener("click", function () { setView("list"); });
    $("sc-v-cal").addEventListener("click", function () { setView("cal"); });
    window.addEventListener("resize", function () { if (data && view === "cal") { renderCal(); renderTitle(); } });
    $("sc-week").addEventListener("click", function (e) { var b = e.target.closest(".tt-row"); if (b && byId[b.getAttribute("data-id")]) openSheet(byId[b.getAttribute("data-id")], b); });
    $("sc-cal").addEventListener("click", function (e) {
      var d = e.target.closest(".sc-sd"); if (d) { sel = d.getAttribute("data-day"); renderCal(); renderTitle(); return; }
      var b = e.target.closest(".sc-ev"); if (b && byId[b.getAttribute("data-id")]) openSheet(byId[b.getAttribute("data-id")], b);
    });
    (function () {                                                    // phone: swipe the day sideways (the grid scrolls only up and down)
      var x0 = null, y0 = null, host = $("sc-cal");
      host.addEventListener("touchstart", function (e) { if (e.touches.length > 1 || !calPhone() || e.target.closest(".sc-strip")) { x0 = null; return; } x0 = e.touches[0].clientX; y0 = e.touches[0].clientY; }, { passive: true });
      host.addEventListener("touchend", function (e) {
        if (x0 === null) return; var t = e.changedTouches[0], dx = t.clientX - x0, dy = t.clientY - y0; x0 = null;
        if (Math.abs(dx) > 60 && Math.abs(dx) > Math.abs(dy) * 1.5) step(dx < 0 ? 1 : -1);
      }, { passive: true });
    })();
    $("ts-close").addEventListener("click", closeSheet);
    $("ts-body").addEventListener("click", function (e) {
      var a = e.target.closest("[data-act]"), back = e.target.closest("#ts-back");
      if (back) { if (!busy) openSheet(cur); return; }
      if (!a) return;
      if (a.id === "ts-go") submit(a.getAttribute("data-act")); else showForm(a.getAttribute("data-act"));
    });
    $("tt-sheet").addEventListener("click", function (e) { if (e.target === $("tt-sheet")) closeSheet(); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && $("tt-sheet").classList.contains("on")) closeSheet(); });
    applyView();
    loadWeek().then(function () { if (data) loadSlots(); });
    try { TL.detectRole(); } catch (e) {}
  }
  TL.requireAuth("tutor-schedule", init);
})();
