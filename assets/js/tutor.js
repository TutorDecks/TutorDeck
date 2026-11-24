// My lessons — a centre tutor's own lessons and attendance. All access goes through two database functions
// (tutor_my_lessons, tutor_mark_attendance); this page never reads a table. What a tutor may do is decided by the
// database; assets/js/tutor-core.js only explains it in plain words.
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var esc = function (s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var TC = window.TutorCore, rows = [], byId = {}, today = "", current = null, picked = null, opener = null, manyOrgs = false;

  function say(t, err) { var m = $("ts-msg"); m.textContent = t || ""; m.className = "msg" + (t ? (err ? " err" : " ok") : ""); }

  function row(l) {
    var c = TC.chip(l, today), t = TC.timeLabel(l.start_time).split(" ");
    var sub = [l.student_level, l.subject, manyOrgs ? l.org_name : null].filter(Boolean).join(" · ");
    return '<button type="button" class="tt-row" data-id="' + esc(l.lesson_id) + '">' +
      '<span class="tt-time"><b>' + esc(t[0] || "") + '</b><small>' + esc(t[1] || "") + '</small></span>' +
      '<span class="tt-main"><span class="tt-name">' + esc(l.student_name) + '</span><span class="tt-sub">' + esc(sub || "Lesson") + '</span></span>' +
      '<span class="tt-chip ' + c.tone + '">' + esc(c.text) + '</span>' +
      '<svg class="tt-chev" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="m9 18 6-6-6-6"/></svg></button>';
  }

  function render() {
    var groups = TC.group(rows, today), toMark = rows.filter(function (l) { return l.lesson_date < today && l.can_mark && !l.attendance && l.status !== "cancelled"; }).length;
    var todayN = rows.filter(function (l) { return l.lesson_date === today && l.status !== "cancelled"; }).length;
    $("tt-sum").innerHTML = rows.length
      ? '<b>' + todayN + '</b> lesson' + (todayN === 1 ? "" : "s") + ' today' + (toMark ? ' · <span style="color:var(--warn);font-weight:700">' + toMark + ' to mark</span>' : "")
      : "";
    if (!rows.length) {
      $("tt-lists").innerHTML = '<div class="card"><div class="tt-empty">No lessons are assigned to you in the last 2 weeks or the next week. When your centre schedules you, they’ll appear here.</div></div>';
      return;
    }
    $("tt-lists").innerHTML = groups.map(function (g) {
      var html = '', last = '';
      g.rows.forEach(function (l) {
        if (g.key !== "today" && l.lesson_date !== last) { html += '<div class="tt-day">' + esc(TC.dateLabel(l.lesson_date, today)) + '</div>'; last = l.lesson_date; }
        html += row(l);
      });
      return '<div class="section-title">' + esc(g.title) + '</div><div class="card tt-list">' + html + '</div>';
    }).join("");
  }

  function openSheet(l, trigger) {
    var opts = TC.attendanceOptions(l);
    current = l; picked = opts.some(function (o) { return o.value === l.attendance; }) ? l.attendance : null; opener = trigger || null;
    $("ts-title").textContent = l.student_name;
    $("ts-sub").textContent = TC.dateLabel(l.lesson_date, today) + " · " + TC.timeRange(l);
    var lock = TC.lockReason(l, today), due = TC.remarksDue(l, Date.now()), html = "";
    html += '<div class="tt-facts">' +
      (l.subject || l.student_level ? '<div><span>Class</span><span>' + esc([l.student_level, l.subject].filter(Boolean).join(" · ")) + '</span></div>' : '') +
      (manyOrgs ? '<div><span>Centre</span><span>' + esc(l.org_name) + '</span></div>' : '') +
      (l.parent_contact ? '<div><span>Parent</span><span><a href="tel:' + esc(String(l.parent_contact).replace(/[^\d+]/g, "")) + '">' + esc(l.parent_contact) + '</a></span></div>' : '') +
      (due ? '<div><span>Remarks due</span><span class="due' + (due.overdue ? ' late' : '') + '">' + esc(new Date(due.at).toLocaleString("en-SG", { weekday: "short", day: "numeric", month: "short", hour: "numeric", minute: "2-digit" })) + (due.overdue ? " (overdue)" : "") + '</span></div>' : '') +
      '</div>';
    if (l.can_mark) {
      html += '<span class="tt-lbl" id="ts-att-l">Attendance</span><div class="tt-opts" role="group" aria-labelledby="ts-att-l">' +
        opts.map(function (o) { return '<button type="button" class="tt-opt" data-att="' + o.value + '" aria-pressed="' + (picked === o.value) + '">' + esc(o.label) + '</button>'; }).join("") + '</div>';
    } else if (lock) {
      html += '<p class="tt-note">' + esc(lock) + '</p>';
    }
    if (l.can_note) {
      html += '<label class="tt-lbl" for="ts-topics">Topics covered</label><textarea class="tt-ta" id="ts-topics" maxlength="2000">' + esc(l.topics) + '</textarea>' +
              '<label class="tt-lbl" for="ts-homework">Homework</label><textarea class="tt-ta" id="ts-homework" maxlength="2000">' + esc(l.homework) + '</textarea>' +
              '<label class="tt-lbl" for="ts-remarks">Remarks' + (l.remarks_required ? ' <span style="font-weight:600;color:var(--muted)">(required to mark attended)</span>' : '') + '</label><textarea class="tt-ta" id="ts-remarks" maxlength="2000">' + esc(l.remarks) + '</textarea>';
    } else {
      [["Topics covered", l.topics], ["Homework", l.homework], ["Remarks", l.remarks]].forEach(function (n) {
        if (n[1]) html += '<div class="tt-ro"><small>' + n[0] + '</small>' + esc(n[1]) + '</div>';
      });
    }
    $("ts-body").innerHTML = html;
    $("ts-save").style.display = (l.can_mark || l.can_note) ? "" : "none";
    $("ts-save").disabled = false; say("");
    $("tt-sheet").classList.add("on"); document.body.classList.add("sheet-lock");
    var first = $("ts-body").querySelector("button,textarea"); if (first) setTimeout(function () { try { first.focus({ preventScroll: true }); } catch (e) {} }, 60);
  }
  function closeSheet() {
    $("tt-sheet").classList.remove("on"); document.body.classList.remove("sheet-lock");
    if (opener && document.body.contains(opener)) { try { opener.focus({ preventScroll: true }); } catch (e) {} }
    current = null;
  }

  async function save() {
    var l = current; if (!l) return;
    var form = { attendance: picked, topics: $("ts-topics") ? $("ts-topics").value : l.topics, homework: $("ts-homework") ? $("ts-homework").value : l.homework,
                 remarks: $("ts-remarks") ? $("ts-remarks").value : l.remarks };
    var ch = TC.changes(l, form);
    if (!ch.any) { closeSheet(); return; }
    $("ts-save").disabled = true; say("Saving…");
    var r = await window.sb.rpc("tutor_mark_attendance", { p_lesson: l.lesson_id, p_attendance: ch.attendance, p_topics: ch.topics, p_homework: ch.homework, p_remarks: ch.remarks });
    if (r.error) { say(TC.errorText(r.error), true); $("ts-save").disabled = false; return; }
    closeSheet(); TL.toast("Saved"); load(true);
  }

  async function load(quiet) {
    today = TL.todayISO();
    if (!quiet) $("tt-sum").textContent = "Loading your lessons…";
    var r = await window.sb.rpc("tutor_my_lessons", { p_from: TC.addDays(today, -14), p_to: TC.addDays(today, 7) });
    if (r.error) {
      $("tt-sum").textContent = "";
      $("tt-lists").innerHTML = '<div class="card"><div class="tt-empty">Your lessons aren’t available right now. Please try again in a few minutes.</div></div>';
      return;
    }
    rows = r.data || []; byId = {};
    var orgs = {}; rows.forEach(function (l) { byId[l.lesson_id] = l; orgs[l.org_id] = 1; });
    manyOrgs = Object.keys(orgs).length > 1;
    render();
  }

  function init() {
    $("tt-lists").addEventListener("click", function (e) {
      var b = e.target.closest(".tt-row"); if (b && byId[b.getAttribute("data-id")]) openSheet(byId[b.getAttribute("data-id")], b);
    });
    $("ts-body").addEventListener("click", function (e) {
      var o = e.target.closest(".tt-opt"); if (!o) return;
      picked = o.getAttribute("data-att");
      Array.prototype.forEach.call($("ts-body").querySelectorAll(".tt-opt"), function (x) { x.setAttribute("aria-pressed", String(x === o)); });
    });
    $("ts-save").addEventListener("click", save);
    $("ts-close").addEventListener("click", closeSheet);
    $("tt-sheet").addEventListener("click", function (e) { if (e.target === $("tt-sheet")) closeSheet(); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && current) closeSheet(); });
    load();
    // remember on this device that this login is a centre tutor (so the menu shows My lessons)
    try { TL.detectRole(); } catch (e) {}
  }
  TL.requireAuth("tutor", init);
})();
