// Schedule — a centre tutor's own week and weekly slots, READ ONLY (T6 step 1). The page calls two database functions
// (tutor_my_schedule, tutor_my_slots) and never reads a table. Neither returns anything about money. Nothing on this page changes data:
// changes are the centre's admins' job until later T6 steps. Pure logic lives in assets/js/tutor-core.js (unit-tested).
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var esc = function (s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var TC = window.TutorCore, today = "", start = "", data = null, byId = {}, manyOrgs = false, editing = "admin_only", opener = null, seq = 0;

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

  function note() { var n = $("sc-note"); n.textContent = TC.editNote(editing); n.hidden = false; }

  function openSheet(l, trigger) {
    opener = trigger || null;
    $("ts-title").textContent = l.student_name;
    $("ts-sub").textContent = TC.dateLabel(l.lesson_date, today) + " · " + TC.timeRange(l);
    var c = TC.scheduleChip(l), url = /^https:\/\/\S+$/.test(l.online_link || "") ? l.online_link : null;
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
      '</div><p class="tt-note">' + esc(TC.editNote(editing)) + '</p>';
    $("tt-sheet").classList.add("on"); document.body.classList.add("sheet-lock");
    setTimeout(function () { try { $("ts-close").focus({ preventScroll: true }); } catch (e) {} }, 60);
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
    renderWeek(); note();
  }
  async function loadSlots() {
    var r = await window.sb.rpc("tutor_my_slots");
    if (r.error) { $("sc-slots").innerHTML = '<div class="card"><div class="tt-empty">' + esc(TC.scheduleErrorText(r.error)) + '</div></div>'; return; }
    renderSlots(r.data || []);
  }
  function go(newStart) { start = newStart; $("sc-week").setAttribute("aria-busy", "true"); loadWeek().then(function () { $("sc-week").removeAttribute("aria-busy"); }); }

  function init() {
    today = TL.todayISO(); start = TC.weekStart(today);
    $("sc-prev").addEventListener("click", function () { go(TC.addDays(start, -7)); });
    $("sc-next").addEventListener("click", function () { go(TC.addDays(start, 7)); });
    $("sc-today").addEventListener("click", function () { go(TC.weekStart(today)); });
    $("sc-week").addEventListener("click", function (e) { var b = e.target.closest(".tt-row"); if (b && byId[b.getAttribute("data-id")]) openSheet(byId[b.getAttribute("data-id")], b); });
    $("ts-close").addEventListener("click", closeSheet);
    $("tt-sheet").addEventListener("click", function (e) { if (e.target === $("tt-sheet")) closeSheet(); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && $("tt-sheet").classList.contains("on")) closeSheet(); });
    loadWeek().then(function () { if (data) loadSlots(); });
    try { TL.detectRole(); } catch (e) {}
  }
  TL.requireAuth("tutor-schedule", init);
})();
