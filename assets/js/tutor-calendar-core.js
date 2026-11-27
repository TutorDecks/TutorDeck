// The week/day grid of a centre tutor's lessons, and the read-only overlay of those lessons on a solo calendar (UX1). No DOM, no network, no storage.
// Used by assets/js/tutor-schedule.js (List | Calendar), assets/js/calendar.js ("Also show my centre lessons") and unit-tested in tests/tutor-calendar-core.test.js.
// Nothing here knows about money: the rows it takes (tutor_my_schedule / tutor_my_lessons) carry none.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.TutorCalendar = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  var STAFF_SET = { late_cancelled: "Late cancellation", cancelled_early: "Cancelled in time" };

  function addDays(iso, n) { var d = new Date(iso + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); }
  function toMin(t) { var m = /^(\d{1,2}):(\d{2})/.exec(String(t || "")); return m ? (+m[1]) * 60 + (+m[2]) : 0; }
  function hhmm(min) { return ("0" + Math.floor(min / 60)).slice(-2) + ":" + ("0" + (min % 60)).slice(-2); }
  function weekDays(start) { var o = []; for (var i = 0; i < 7; i++) o.push(addDays(start, i)); return o; }
  function weekStart(iso) { var d = new Date(iso + "T00:00:00Z"); return addDays(iso, -((d.getUTCDay() + 6) % 7)); }

  // What a lesson block looks like. One word of state (the order matters: cancelled beats everything), and the small marks that can be on top of it.
  // Works on a tutor_my_schedule row (has `cancelled`, `postponed`, `covering`) and on a tutor_my_lessons row (has `status`).
  function state(l) {
    if (l.cancelled || l.status === "cancelled") return { key: "cancelled", text: "Cancelled" };
    if (l.attendance === "attended") return { key: "attended", text: "Attended" };
    if (l.attendance === "absent") return { key: "absent", text: "Absent" };
    if (STAFF_SET[l.attendance]) return { key: "absent", text: STAFF_SET[l.attendance] };
    return { key: "upcoming", text: "" };
  }
  // The chip a block carries, in the same words as the List view (assets/js/tutor-core.js scheduleChip): state first, then moved, covering, trial.
  function chip(l) {
    var s = state(l);
    if (s.key !== "upcoming") return { text: s.text, key: s.key };
    if (l.postponed) return { text: "Moved", key: "moved" };
    if (l.covering) return { text: "Covering", key: "covering" };
    if (l.trial) return { text: "Trial", key: "trial" };
    return null;
  }
  // Blocks of ONE day, with the side-by-side lane each gets when lessons overlap: [{ l, startMin, endMin, lane, lanes }], earliest first.
  function layoutDay(lessons) {
    var day = (lessons || []).map(function (l) {
      var a = toMin(l.start_time), b = toMin(l.end_time); if (b <= a) b = a + 60;
      return { l: l, startMin: a, endMin: b, lane: 0, lanes: 1 };
    }).sort(function (x, y) { return x.startMin - y.startMin || x.endMin - y.endMin; });
    var i = 0;
    while (i < day.length) {
      var cluster = [day[i]], end = day[i].endMin, j = i + 1;
      while (j < day.length && day[j].startMin < end) { cluster.push(day[j]); end = Math.max(end, day[j].endMin); j++; }
      var laneEnds = [];
      cluster.forEach(function (b) {
        var placed = false;
        for (var k = 0; k < laneEnds.length; k++) if (b.startMin >= laneEnds[k]) { b.lane = k; laneEnds[k] = b.endMin; placed = true; break; }
        if (!placed) { b.lane = laneEnds.length; laneEnds.push(b.endMin); }
      });
      cluster.forEach(function (b) { b.lanes = laneEnds.length; });
      i = j;
    }
    return day;
  }
  // The hours the grid shows: the lessons' own hours, rounded out to whole hours, never fewer than minHours (default 6); an empty week shows 15:00-21:00.
  function bounds(lessons, minHours) {
    var mh = minHours || 6, ls = (lessons || []).filter(function (l) { return l && l.start_time; });
    if (!ls.length) return { start: 15 * 60, end: 21 * 60 };
    var mn = Math.min.apply(null, ls.map(function (l) { return toMin(l.start_time); })), mx = Math.max.apply(null, ls.map(function (l) { var e = toMin(l.end_time); return e > toMin(l.start_time) ? e : toMin(l.start_time) + 60; }));
    var s = Math.floor(mn / 60) * 60, e = Math.min(24 * 60, Math.ceil(mx / 60) * 60);
    if ((e - s) / 60 < mh) { e = Math.min(24 * 60, s + mh * 60); if (e - s < mh * 60) s = Math.max(0, e - mh * 60); }
    return { start: s, end: e };
  }
  // The seven days of a week for the grid: { date, holidays: [names], lessons: [...] } (every day, even an empty one).
  function week(data, start) {
    var days = weekDays(start).map(function (d) { return { date: d, holidays: [], lessons: [] }; }), by = {};
    days.forEach(function (d) { by[d.date] = d; });
    ((data && data.holidays) || []).forEach(function (h) {
      weekDays(start).forEach(function (d) { if (d >= h.starts_on && d <= h.ends_on && by[d].holidays.indexOf(h.name) < 0) by[d].holidays.push(h.name); });
    });
    ((data && data.lessons) || []).forEach(function (l) { if (by[l.lesson_date]) by[l.lesson_date].lessons.push(l); });
    days.forEach(function (d) { d.lessons.sort(function (a, b) { return toMin(a.start_time) - toMin(b.start_time) || (a.student_name < b.student_name ? -1 : 1); }); });
    return days;
  }
  // The day to show on a phone when a week is opened: the remembered one if it is in that week, else today if it is, else the Monday.
  function pickDay(start, today, remembered) {
    var days = weekDays(start);
    if (remembered && days.indexOf(remembered) >= 0) return remembered;
    return days.indexOf(today) >= 0 ? today : days[0];
  }

  // ---------- the overlay on the solo calendar (item 3): a tutor_my_lessons row → a read-only block ----------
  // tutor_my_lessons never returns a price, rate, amount, paid flag or compensation, and nothing is copied here but the facts below.
  function overlayBlock(r) {
    var c = chip(r);
    return { id: "centre-" + r.lesson_id, kind: "centre", state: "centre", dateISO: r.lesson_date, startMin: toMin(r.start_time), endMin: toMin(r.end_time) > toMin(r.start_time) ? toMin(r.end_time) : toMin(r.start_time) + 60,
             name: r.student_name || "", subject: r.subject || "", level: r.student_level || "", centre: r.org_name || "", tag: c ? c.text : "", cancelled: state(r).key === "cancelled",
             trial: !!r.trial, lessonId: r.lesson_id, orgId: r.org_id };
  }
  // The label under a centre block: "Centre name · subject".
  function overlayLabel(b) { return [b.centre, b.subject].filter(Boolean).join(" · "); }
  // Should the toggle be offered at all? Only a "both" login, and only on their solo calendar (never a solo tutor with no centre, never inside a centre).
  function overlayAvailable(mode, org) { return mode === "both" && !!org && org.kind !== "centre"; }

  return { addDays: addDays, toMin: toMin, hhmm: hhmm, weekDays: weekDays, weekStart: weekStart, state: state, chip: chip, layoutDay: layoutDay, bounds: bounds, week: week,
           pickDay: pickDay, overlayBlock: overlayBlock, overlayLabel: overlayLabel, overlayAvailable: overlayAvailable };
});
