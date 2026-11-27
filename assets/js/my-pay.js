// Your pay — a centre tutor's OWN pay, a month at a time. All data comes from four database functions (tutor_my_pay_modes, tutor_my_pay_month,
// tutor_my_pay_adjustments, tutor_my_pay); this page reads no table. It shows only the tutor's own figures, as an estimate until the centre confirms the
// pay run: never a fee, a rate, a percentage, an invoice or what a family paid. A held lesson says "Pending" with no amount. Wording: assets/js/tutor-pay-core.js.
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var esc = function (s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var P = window.TutorPayCore, month = "", thisMonth = "", busy = 0;

  function say(html) { $("mp-body").innerHTML = '<div class="card mp-card"><div class="mp-empty">' + html + '</div></div>'; }

  function card(r, adjs, lessons, names) {
    var lines = P.monthLines(r, adjs.filter(function (a) { return a.org_id === r.org_id; }));
    var html = '<section class="card mp-card" aria-label="' + esc(r.org_name) + '">';
    html += '<div class="mp-org">' + esc(r.org_name) + '</div>';
    html += '<div class="mp-total">' + esc(P.sgd(r.total_cents)) + '</div>' +
      '<div class="mp-period">' + esc(P.periodLabel(r.period_from, r.period_to)) + '</div>' +
      '<span class="mp-est' + (r.run_recorded ? ' final' : '') + '">' + esc(P.estimateNote(r.run_recorded)) + '</span>';
    html += '<ul class="mp-lines">' + lines.map(function (l) {
      return '<li class="' + l.kind + '"><span>' + esc(l.label) + (l.date ? ' <small style="color:var(--muted)">· ' + esc(P.dayLabel(l.date)) + '</small>' : '') + '</span><span>' + esc(l.text) + '</span></li>';
    }).join("") + '</ul>';
    if (r.pending_lessons > 0) html += '<div class="mp-pend">' + esc(P.pendingWord(r.pending_lessons)) + '</div>';
    if (r.pay_view === "per_lesson_and_total") {
      var mine = lessons.filter(function (x) { return x.org_id === r.org_id && x.lesson_date >= r.period_from && x.lesson_date <= r.period_to; });
      if (mine.length) {
        html += '<div class="mp-sub">Lessons</div>' + mine.map(function (x) {
          var w = P.lessonPay(x), nm = names[x.lesson_id] || "Lesson";
          return '<div class="mp-les"><span class="d">' + esc(P.dayLabel(x.lesson_date)) + '</span><span class="n">' + esc(nm) + '</span><span class="a ' + (w && w.pending ? 'pending' : '') + '">' + esc(w ? w.text : "") + '</span></div>';
        }).join("");
        html += '<div class="mp-foot">An amount appears beside a lesson once it is released for pay. Lessons from earlier months that were released this month are in the total above.</div>';
      }
    }
    return html + '</section>';
  }

  async function load() {
    var my = ++busy;
    $("mp-label").textContent = P.monthLabel(month);
    $("mp-next").disabled = month >= P.addMonths(thisMonth, 1);          // up to next month's period, no further
    say("Loading your pay…");
    var rm = await window.sb.rpc("tutor_my_pay_month", { p_month: month });
    if (my !== busy) return;
    if (rm.error) { say(esc(P.errorText(rm.error))); return; }
    var rows = rm.data || [];
    if (!rows.length) { $("mp-nav").style.display = "none"; say("Your centre doesn’t show tutors their own pay. If you think it should, ask your centre’s admin."); return; }
    $("mp-nav").style.display = "";
    var ra = await window.sb.rpc("tutor_my_pay_adjustments", { p_month: month });
    var adjs = ra.error ? [] : (ra.data || []);
    var lessons = [], names = {};
    var per = rows.filter(function (r) { return r.pay_view === "per_lesson_and_total"; });
    for (var i = 0; i < per.length; i++) {                                // one centre at a time: each pay period is at most 31 days
      var r0 = per[i];
      var rl = await window.sb.rpc("tutor_my_pay", { p_from: r0.period_from, p_to: r0.period_to });
      if (!rl.error) lessons = lessons.concat((rl.data || []).filter(function (x) { return x.org_id === r0.org_id; }));
      // names of the tutor's own students come from the lessons list they already have (tutor_my_lessons)
      var rn = await window.sb.rpc("tutor_my_lessons", { p_from: r0.period_from, p_to: r0.period_to });
      if (!rn.error) (rn.data || []).forEach(function (x) { names[x.lesson_id] = x.student_name; });
    }
    lessons.sort(function (a, b) { return a.lesson_date < b.lesson_date ? -1 : a.lesson_date > b.lesson_date ? 1 : 0; });
    if (my !== busy) return;
    $("mp-body").innerHTML = rows.map(function (r) { return card(r, adjs, lessons, names); }).join("");
  }

  function init() {
    thisMonth = TL.todayISO().slice(0, 7) + "-01"; month = thisMonth;
    $("mp-prev").addEventListener("click", function () { month = P.addMonths(month, -1); load(); });
    $("mp-next").addEventListener("click", function () { if (month < P.addMonths(thisMonth, 1)) { month = P.addMonths(month, 1); load(); } });
    // remember on this device whether this login has a Your pay entry (the menu reads it)
    try { TL.detectPay(true); } catch (e) {}
    load();
  }
  TL.requireAuth("mypay", init);
})();
