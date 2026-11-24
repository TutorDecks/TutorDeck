// Tutor page logic with no DOM and no network: how lessons are grouped, what each row says, why a lesson is locked, and what
// the database's refusal codes mean in plain words. Used by assets/js/tutor.js and unit-tested in tests/tutor-core.test.js.
// The database (tutor_my_lessons / tutor_mark_attendance) is the authority on what a tutor may do; this only explains it.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.TutorCore = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  var MO = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  var WD = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

  // "2026-11-24" + n days → "2026-11-27" (calendar arithmetic only, no timezone involved)
  function addDays(iso, n) {
    var d = new Date(iso + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n);
    return d.toISOString().slice(0, 10);
  }
  function parts(iso) { var d = new Date(iso + "T00:00:00Z"); return { wd: WD[d.getUTCDay()], d: d.getUTCDate(), m: MO[d.getUTCMonth()], y: d.getUTCFullYear() }; }
  function dateLabel(iso, today) {
    if (iso === today) return "Today";
    if (iso === addDays(today, 1)) return "Tomorrow";
    if (iso === addDays(today, -1)) return "Yesterday";
    var p = parts(iso); return p.wd + " " + p.d + " " + p.m;
  }
  // "16:00:00" → "4:00 pm"
  function timeLabel(t) {
    var m = /^(\d{1,2}):(\d{2})/.exec(String(t || "")); if (!m) return "";
    var h = Number(m[1]), ap = h >= 12 ? "pm" : "am"; h = h % 12 || 12;
    return h + ":" + m[2] + " " + ap;
  }
  function timeRange(l) { return timeLabel(l.start_time) + (l.end_time ? " – " + timeLabel(l.end_time) : ""); }

  var STAFF_SET = { late_cancelled: "Late cancellation", cancelled_early: "Cancelled in time" };

  // What the row's badge says. tone: ok (teal) · warn (amber) · muted (grey) · action (needs you, shown as a call to act)
  function chip(l, today) {
    if (l.status === "cancelled") return { text: "Cancelled", tone: "muted" };
    if (l.attendance === "attended") return { text: "Attended", tone: "ok" };
    if (l.attendance === "absent") return { text: "Absent", tone: "muted" };
    if (STAFF_SET[l.attendance]) return { text: STAFF_SET[l.attendance], tone: "muted" };
    if (l.lesson_date > today) return { text: "Upcoming", tone: "muted" };
    if (l.can_mark) return l.lesson_date === today ? { text: "Mark", tone: "action" } : { text: "To mark", tone: "warn" };
    if (!l.can_note) return { text: "Ask an admin", tone: "warn" };           // too long ago for a tutor to change
    return { text: "Admin marks", tone: "muted" };                              // this centre's admins set attendance
  }

  // Why a tutor can't set attendance on this lesson (null if they can). Order mirrors the database's checks.
  function lockReason(l, today) {
    if (l.can_mark) return null;
    if (l.status === "cancelled") return "This lesson was cancelled.";
    if (l.lesson_date > today) return "You can mark a lesson from its day onward.";
    if (!l.can_note) return "That's too long ago to change here. Please ask an admin.";
    if (l.attendance) return STAFF_SET[l.attendance] ? "Already marked as \"" + STAFF_SET[l.attendance].toLowerCase() + "\" by someone else. Ask an admin to change it." : "Someone else already marked this lesson. Ask an admin to change it.";
    return "At this centre an admin marks attendance. You can still add notes.";
  }

  // Remarks reminder: only for lessons whose notes can still be written and have no remarks yet.
  function remarksDue(l, nowMs) {
    if (!l.remarks_due_at || !l.can_note || (l.remarks && String(l.remarks).trim())) return null;
    var due = Date.parse(l.remarks_due_at); if (!isFinite(due)) return null;
    return { overdue: due < nowMs, at: due };
  }

  // Sections, in the order the page shows them. Within each, lessons stay in the order the database gave (date, time, name).
  //   To mark  = earlier days still waiting for attendance (oldest first, so the longest-waiting is on top)
  //   Today    = everything dated today
  //   Coming up = later days
  //   Earlier  = earlier days that are done, locked or cancelled (newest first)
  function group(rows, today) {
    var g = { toMark: [], today: [], upcoming: [], earlier: [] };
    (rows || []).forEach(function (l) {
      if (l.lesson_date === today) g.today.push(l);
      else if (l.lesson_date > today) g.upcoming.push(l);
      else if (l.can_mark && !l.attendance && l.status !== "cancelled") g.toMark.push(l);
      else g.earlier.push(l);
    });
    g.earlier.reverse();
    return [
      { key: "toMark", title: "To mark", rows: g.toMark },
      { key: "today", title: "Today", rows: g.today },
      { key: "upcoming", title: "Coming up", rows: g.upcoming },
      { key: "earlier", title: "Earlier", rows: g.earlier }
    ].filter(function (s) { return s.rows.length; });
  }

  // The database's refusals start with a code ("TOO_OLD: …"); say it kindly. Anything unknown gets a generic line and is never shown raw.
  var ERRORS = {
    NOT_FOUND: "That lesson isn't assigned to you any more. Pull to refresh.",
    TOO_EARLY: "You can mark a lesson from its day onward.",
    TOO_OLD: "That lesson is too old to change here. Please ask an admin.",
    CANCELLED: "That lesson was cancelled.",
    ADMIN_ONLY: "At this centre an admin marks attendance. Your notes were not saved either, so please try again without changing attendance.",
    ALREADY_MARKED: "Someone else already marked this lesson. Ask an admin to change it.",
    BAD_VALUE: "That isn't something you can mark at this centre.",
    REMARKS_REQUIRED: "This centre needs remarks before a lesson is marked as attended. Please add them and save again.",
    TOO_LONG: "Please keep each note under 2000 characters.",
    BAD_RANGE: "Something went wrong loading your lessons. Please try again."
  };
  function errorText(err) {
    var m = /^([A-Z_]+)(?::|$)/.exec(String((err && err.message) || ""));
    return (m && ERRORS[m[1]]) || "We couldn't save that just now. Please try again.";
  }

  // The attendance choices this tutor is offered: attended / absent always, and the two cancellations only when the centre lets tutors mark them.
  function attendanceOptions(l) {
    var o = [{ value: "attended", label: "Attended" }, { value: "absent", label: "Absent" }];
    if (l.can_cancel) o.push({ value: "cancelled_early", label: "Cancelled in time" }, { value: "late_cancelled", label: "Late cancellation" });
    return o;
  }

  // Which fields to send: attendance only if it changed, a note only if its text changed (null = leave it alone in the database)
  function changes(l, form) {
    var out = { attendance: null, topics: null, homework: null, remarks: null }, any = false;
    if (form.attendance && form.attendance !== l.attendance) { out.attendance = form.attendance; any = true; }
    ["topics", "homework", "remarks"].forEach(function (k) {
      var was = String(l[k] || "").trim(), now = String(form[k] == null ? "" : form[k]).trim();
      if (now !== was) { out[k] = now; any = true; }
    });
    out.any = any;
    return out;
  }

  return { addDays: addDays, dateLabel: dateLabel, timeLabel: timeLabel, timeRange: timeRange, chip: chip, lockReason: lockReason,
           remarksDue: remarksDue, attendanceOptions: attendanceOptions, group: group, errorText: errorText, changes: changes };
});
