// Centre Attendance page logic with no DOM and no network (T3 step 3): which days a view covers, how a lesson row looks (chip, buttons),
// the early check on a correction, and what the database's refusals mean in plain words.
// Used by assets/js/centre-attendance.js and unit-tested in tests/centre-attendance-core.test.js. The database decides everything that matters
// (db/migration_staff_attendance.sql); this file only saves a round trip and words the answers.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.CentreAttendanceCore = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  var PAGE_SIZE = 50, REASON_MAX = 500, REMARKS_MAX = 2000;

  // The four marks staff can set, in the order the sheet shows them. `short` is the chip text.
  var MARKS = [
    { key: "attended",        label: "Attended",              short: "Attended",        tone: "ok" },
    { key: "absent",          label: "Absent",                short: "Absent",          tone: "muted" },
    { key: "late_cancelled",  label: "Late cancelled",        short: "Late cancelled",  tone: "muted" },
    { key: "cancelled_early", label: "Cancelled in time",     short: "Cancelled",       tone: "muted" }
  ];
  function mark(key) { for (var i = 0; i < MARKS.length; i++) if (MARKS[i].key === key) return MARKS[i]; return null; }
  var STATUS_FILTERS = [{ key: "all", label: "All" }, { key: "unmarked", label: "Not marked" }, { key: "marked", label: "Marked" }, { key: "trial", label: "Trial" }];

  // ---- days: a view is one day or one Monday–Sunday week, anchored on any date in it (ISO yyyy-mm-dd) ----
  function addDays(iso, n) { var d = new Date(iso + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); }
  function weekStart(iso) { var wd = new Date(iso + "T00:00:00Z").getUTCDay(); return addDays(iso, -((wd + 6) % 7)); }   // Monday
  function monthStart(iso) { return iso.slice(0, 8) + "01"; }
  function monthEnd(iso) { var d = new Date(monthStart(iso) + "T00:00:00Z"); d.setUTCMonth(d.getUTCMonth() + 1); d.setUTCDate(0); return d.toISOString().slice(0, 10); }
  function addMonths(iso, n) { var d = new Date(monthStart(iso) + "T00:00:00Z"); d.setUTCMonth(d.getUTCMonth() + n); return d.toISOString().slice(0, 10); }   // the 1st of the month n months on
  // a view is one day, one Monday–Sunday week or one calendar month (31 days at most, well inside the database's 62-day limit)
  function range(view, anchor) {
    if (view === "month") return { from: monthStart(anchor), to: monthEnd(anchor) };
    return view === "week" ? { from: weekStart(anchor), to: addDays(weekStart(anchor), 6) } : { from: anchor, to: anchor };
  }
  function shift(view, anchor, dir) { return view === "month" ? addMonths(anchor, dir) : addDays(anchor, (view === "week" ? 7 : 1) * dir); }
  var WD = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], MO = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  function parts(iso) { var d = new Date(iso + "T00:00:00Z"); return { wd: WD[d.getUTCDay()], d: d.getUTCDate(), m: MO[d.getUTCMonth()], y: d.getUTCFullYear() }; }
  function dayLabel(iso, today) {                      // "Today · Wed 25 Nov"
    var p = parts(iso), base = p.wd + " " + p.d + " " + p.m;
    if (iso === today) return "Today · " + base;
    if (iso === addDays(today, 1)) return "Tomorrow · " + base;
    if (iso === addDays(today, -1)) return "Yesterday · " + base;
    return base;
  }
  var MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
  function rangeLabel(view, anchor, today) {
    if (view === "month") { var pm = parts(anchor); return MONTHS[MO.indexOf(pm.m)] + " " + pm.y; }
    if (view !== "week") return dayLabel(anchor, today);
    var r = range("week", anchor), a = parts(r.from), b = parts(r.to);
    return a.d + " " + a.m + " – " + b.d + " " + b.m + (a.y === b.y ? "" : " " + b.y);
  }
  function validISO(s) { return typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s) && !isNaN(new Date(s + "T00:00:00Z")) && new Date(s + "T00:00:00Z").toISOString().slice(0, 10) === s; }
  function timeLabel(t) {
    var m = /^(\d{1,2}):(\d{2})/.exec(String(t || "")); if (!m) return "";
    var h = Number(m[1]), ap = h >= 12 ? "pm" : "am"; h = h % 12 || 12;
    return h + ":" + m[2] + " " + ap;
  }
  function timeRange(r) { return timeLabel(r.start_time) + (r.end_time ? " – " + timeLabel(r.end_time) : ""); }

  // ---- one row ----
  // chip: what the row's status badge says. States come from the database (staff_lessons.state): future | open | marked | cancelled.
  function chip(r) {
    if (r.state === "cancelled") return { text: "Cancelled", tone: "muted" };
    if (r.state === "marked") { var m = mark(r.attendance); return { text: m ? m.short : "Marked", tone: m ? m.tone : "muted" }; }
    if (r.state === "future") return { text: "Upcoming", tone: "muted" };
    return { text: "Not marked", tone: "warn" };
  }
  // Which buttons the sheet shows. The database already folded the caller's permission into can_mark / can_correct; this only turns them into words.
  //   mark      = the four mark buttons  ·  correct = the "Correct" button  ·  note = the sentence shown instead when there are no buttons
  function actions(r, canMark) {
    if (r.can_mark) return { mark: true, correct: false, note: "" };
    if (r.can_correct) return { mark: false, correct: true, note: "" };
    if (r.state === "future") return { mark: false, correct: false, note: "This lesson hasn’t started yet. It can be marked from its day." };
    if (r.state === "cancelled") return { mark: false, correct: false, note: "This lesson was cancelled, so there is nothing to mark." };
    if (!canMark) return { mark: false, correct: false, note: "Your account can look at attendance but not change it. Ask the centre owner if you need to mark lessons." };
    return { mark: false, correct: false, note: "" };
  }
  // "Marked by Sam on Tue 24 Nov" — marked_by_name can be missing (the person was removed)
  function markedLine(r) {
    if (r.attendance == null) return "";
    var who = r.marked_by_name ? " by " + r.marked_by_name : "";
    return "Marked" + who + (r.marked_at ? " on " + (function () { var p = parts(String(r.marked_at).slice(0, 10)); return p.wd + " " + p.d + " " + p.m; })() : "");
  }

  // Group the page's rows by day, in the order the database gave. → [{ date, rows }]
  function byDay(rows) {
    var out = [], idx = {};
    (rows || []).forEach(function (r) {
      if (idx[r.lesson_date] == null) { idx[r.lesson_date] = out.length; out.push({ date: r.lesson_date, rows: [] }); }
      out[idx[r.lesson_date]].rows.push(r);
    });
    return out;
  }

  // ---- early checks (the database repeats every one of these) ----
  function checkMark(attendance, remarks) {
    if (!mark(attendance)) return { ok: false, error: "Choose attended, absent, late cancelled or cancelled in time." };
    if (String(remarks || "").length > REMARKS_MAX) return { ok: false, error: "Keep the remarks under " + REMARKS_MAX + " characters." };
    return { ok: true };
  }
  function checkCorrection(current, attendance, reason) {
    if (!mark(attendance)) return { ok: false, error: "Choose the right mark." };
    if (attendance === current) return { ok: false, error: "The lesson is already marked that way. Choose a different mark." };
    var why = String(reason == null ? "" : reason).trim();
    if (!why) return { ok: false, error: "Say why you are changing this mark. It is kept on record." };
    if (why.length > REASON_MAX) return { ok: false, error: "Keep the reason under " + REASON_MAX + " characters." };
    return { ok: true, reason: why };
  }
  // The marks a correction can change TO (everything except what it is now)
  function otherMarks(current) { return MARKS.filter(function (m) { return m.key !== current; }); }

  // ---- trial flag ----
  // A lesson in an EARLIER month than today's: a fee already worked out for that month is not recomputed (the sheet says so).
  function pastMonthNote(lessonDate, today) {
    if (!lessonDate || !today || String(lessonDate).slice(0, 7) >= String(today).slice(0, 7)) return "";
    return "This lesson is in an earlier month. A fee already worked out for that month does not change.";
  }
  // The same one-line explanation the sheet shows under the toggle
  var TRIAL_HELP = "A trial lesson doesn’t count towards the centre’s fee.";

  // ---- the database's refusals, in plain words ----
  function errorText(err) {
    var m = String((err && err.message) || err || "");
    var map = [
      [/NO_CHANGE: the lesson is already (a trial|not a trial)/, "That lesson was already changed. Refresh the list."],
      [/NOT_ALLOWED/, "Your account can’t mark attendance at this centre."],
      [/NOT_FOUND/, "That lesson isn’t available any more. Refresh the list and try again."],
      [/TOO_EARLY/, "A lesson can be marked from its day onward, not before."],
      [/ALREADY_MARKED/, "Someone has already marked this lesson. Use Correct to change it, with a reason."],
      [/LOCKED/, "Who marked a lesson can’t be edited by hand."],
      [/CANCELLED/, "This lesson was cancelled, so it can’t be marked."],
      [/REMARKS_REQUIRED/, "This centre needs remarks before a lesson is marked attended. Write a short remark and try again."],
      [/REASON_REQUIRED/, "Say why you are changing this mark. It is kept on record."],
      [/NOT_MARKED/, "This lesson hasn’t been marked yet. Mark it instead of correcting it."],
      [/NO_CHANGE/, "The lesson is already marked that way."],
      [/TOO_LONG/, "That text is too long. Please shorten it."],
      [/BAD_RANGE/, "Choose a shorter period."],
      [/BAD_FILTER|BAD_PAGE|BAD_VALUE/, "That choice isn’t available. Refresh the page and try again."]
    ];
    for (var i = 0; i < map.length; i++) if (map[i][0].test(m)) return map[i][1];
    if (/Failed to fetch|NetworkError|network/i.test(m)) return "Couldn’t reach the server. Check your connection and try again.";
    return m || "Something went wrong.";
  }
  // Is the function missing (the migration isn't on this database yet)?
  function isMissing(err) { return !!err && (err.code === "42883" || err.code === "PGRST202" || /does not exist|Could not find the function/i.test(err.message || "")); }

  function pageCount(total, size) { return Math.max(1, Math.ceil((total || 0) / (size || PAGE_SIZE))); }
  function pagerLabel(page, size, total) {
    if (!total) return "No lessons";
    var from = (page - 1) * size + 1, to = Math.min(total, page * size);
    return from + "–" + to + " of " + total;
  }
  function emptyText(filter, view) {
    var when = view === "month" ? "this month" : view === "week" ? "this week" : "this day";
    if (filter === "unmarked") return { title: "Nothing left to mark", hint: "Every lesson that has started " + when + " has a mark." };
    if (filter === "trial") return { title: "No trial lessons " + when, hint: "Lessons flagged as a trial appear here." };
    if (filter === "marked") return { title: "Nothing marked yet", hint: "Marked lessons " + when + " appear here." };
    return { title: "No lessons " + when, hint: "Lessons made from the timetable appear here." };
  }

  return { PAGE_SIZE: PAGE_SIZE, REASON_MAX: REASON_MAX, REMARKS_MAX: REMARKS_MAX, MARKS: MARKS, STATUS_FILTERS: STATUS_FILTERS, mark: mark,
           addDays: addDays, addMonths: addMonths, monthStart: monthStart, monthEnd: monthEnd, weekStart: weekStart, range: range, shift: shift, dayLabel: dayLabel, rangeLabel: rangeLabel, validISO: validISO,
           timeLabel: timeLabel, timeRange: timeRange, chip: chip, actions: actions, markedLine: markedLine, byDay: byDay,
           checkMark: checkMark, checkCorrection: checkCorrection, otherMarks: otherMarks, errorText: errorText, isMissing: isMissing,
           pastMonthNote: pastMonthNote, TRIAL_HELP: TRIAL_HELP, pageCount: pageCount, pagerLabel: pagerLabel, emptyText: emptyText };
});
