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
    CHARGE_REQUIRED: "Please enter the charge for this lesson, or 0 if the family isn't charged.",
    BAD_CHARGE: "The charge must be an amount from 0 up to the lesson's own price, with at most 2 decimals.",
    CHARGE_ADMIN_ONLY: "At this centre an admin enters the charge for absent or cancelled lessons.",
    TRIAL_ADMIN_ONLY: "At this centre an admin flags trial lessons.",
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

  // The charge (compensation) for an absent or cancelled lesson: a number, 0 if the family isn't charged. "25", "12.5", "S$12.50", "0" are fine.
  var CHARGE_VALUES = ["absent", "cancelled_early", "late_cancelled"];
  function parseCharge(text) {
    var t = String(text == null ? "" : text).trim().replace(/^S?\$\s*/i, "");
    if (!/^\d+(\.\d{1,2})?$/.test(t)) return { ok: false };
    return { ok: true, value: Number(t) };
  }
  // Does this centre make the tutor type a charge for this choice?
  function needsCharge(l, attendance) { return !!l.tutor_sets_compensation && CHARGE_VALUES.indexOf(attendance) >= 0; }
  // Only for absent / cancelled choices when the ADMIN sets the charge: tell the tutor what happens next.
  function adminChargeNote(l, attendance) { return !l.tutor_sets_compensation && CHARGE_VALUES.indexOf(attendance) >= 0; }

  // Which fields to send: attendance only if it changed, a note only if its text changed (null = leave it alone in the database)
  function changes(l, form) {
    var out = { attendance: null, topics: null, homework: null, remarks: null, trial: null, compensation: null, chargeError: false }, any = false;
    if (form.attendance && form.attendance !== l.attendance) { out.attendance = form.attendance; any = true; }
    ["topics", "homework", "remarks"].forEach(function (k) {
      var was = String(l[k] || "").trim(), now = String(form[k] == null ? "" : form[k]).trim();
      if (now !== was) { out[k] = now; any = true; }
    });
    if (l.can_flag_trial && form.trial != null && !!form.trial !== !!l.trial) { out.trial = !!form.trial; any = true; }
    // the charge: required whenever the attendance changes to an absent / cancelled choice (and the centre has tutors type it); otherwise only if they typed one
    if (needsCharge(l, form.attendance || l.attendance)) {
      var typed = String(form.compensation == null ? "" : form.compensation).trim();
      if (out.attendance !== null || typed !== "") {
        var c = parseCharge(typed);
        if (!c.ok) out.chargeError = true; else { out.compensation = c.value; any = true; }
      }
    }
    out.any = any;
    return out;
  }

  // ================= T6 step 1: the read-only Schedule (tutor_my_schedule / tutor_my_slots). No money anywhere in these rows. =================
  var WD_LONG = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
  // the Monday of the week that holds this date ("2026-11-26" → "2026-11-23")
  function weekStart(iso) { var d = new Date(iso + "T00:00:00Z"), k = (d.getUTCDay() + 6) % 7; return addDays(iso, -k); }
  function weekTitle(start, today) {
    var cur = weekStart(today);
    if (start === cur) return "This week";
    if (start === addDays(cur, 7)) return "Next week";
    if (start === addDays(cur, -7)) return "Last week";
    var a = parts(start), b = parts(addDays(start, 6));
    return a.d + " " + a.m + " – " + b.d + " " + b.m;
  }
  // The days of one range that have something to show, in date order: { date, holidays: [names], lessons: [...] }.
  // A day with a whole-centre holiday is listed even with no lesson (a grey band); a lesson on a holiday keeps its row.
  function scheduleDays(data, from, to) {
    var days = {}, order = [];
    function day(d) { if (!days[d]) { days[d] = { date: d, holidays: [], lessons: [] }; order.push(d); } return days[d]; }
    ((data && data.holidays) || []).forEach(function (h) {
      for (var d = h.starts_on < from ? from : h.starts_on, end = h.ends_on > to ? to : h.ends_on, n = 0; d <= end && n < 70; d = addDays(d, 1), n++) {
        var x = day(d); if (x.holidays.indexOf(h.name) < 0) x.holidays.push(h.name);
      }
    });
    ((data && data.lessons) || []).forEach(function (l) { day(l.lesson_date).lessons.push(l); });
    return order.sort().map(function (d) { return days[d]; });
  }
  // The badge on a schedule row (one word) and the small facts under the name. Nothing here says anything about money.
  function scheduleChip(l) {
    if (l.cancelled) return { text: "Cancelled", tone: "muted" };
    if (l.attendance === "attended") return { text: "Attended", tone: "ok" };
    if (l.attendance === "absent") return { text: "Absent", tone: "muted" };
    if (STAFF_SET[l.attendance]) return { text: STAFF_SET[l.attendance], tone: "muted" };
    if (l.postponed) return { text: "Moved", tone: "muted" };
    if (l.covering) return { text: "Covering", tone: "muted" };
    if (l.trial) return { text: "Trial", tone: "muted" };
    return null;
  }
  function scheduleFacts(l, withCentre) {
    var f = [l.student_level, l.subject];
    if (l.trial) f.push("Trial");
    if (l.covering) f.push("Covering for another tutor");
    if (l.postponed) f.push("Moved from its usual day");
    if (withCentre) f.push(l.org_name);
    return f.filter(Boolean);
  }
  // The note under the week. Step 1 can't change anything, whatever the centre chose; the database says which value the centre has.
  function editNote(editing) {
    return (editing || "admin_only") === "admin_only"
      ? "Your centre handles changes: ask an admin."
      : "Changing your own lessons here is coming soon. For now, ask an admin.";
  }
  function rangeLabel(a, b) { var x = parts(a), y = parts(b); return x.d + " " + x.m + " – " + y.d + " " + y.m; }
  function weekdayName(i) { return WD_LONG[i] || ""; }
  // my weekly slots, one entry per class (a group class shares a session_key), in week order
  function slotList(rows) {
    var out = [], by = {};
    (rows || []).forEach(function (r) {
      var k = r.session_key || r.slot_id;
      if (!by[k]) { by[k] = { key: k, weekday: r.weekday, start_time: r.start_time, end_time: r.end_time, subject: r.subject, org_name: r.org_name, students: [] }; out.push(by[k]); }
      by[k].students.push({ name: r.student_name, level: r.student_level });
    });
    return out.sort(function (a, b) { return a.weekday - b.weekday || (a.start_time < b.start_time ? -1 : a.start_time > b.start_time ? 1 : 0); });
  }
  function scheduleErrorText(err) {
    var m = /^([A-Z_]+)(?::|$)/.exec(String((err && err.message) || ""));
    if (m && m[1] === "NOT_FOUND") return "This page is for tutors at a centre. If you should have lessons here, ask your centre's admin.";
    return "Your schedule isn't available right now. Please try again in a few minutes.";
  }

  return { weekStart: weekStart, weekTitle: weekTitle, scheduleDays: scheduleDays, scheduleChip: scheduleChip, scheduleFacts: scheduleFacts, editNote: editNote,
           weekdayName: weekdayName, rangeLabel: rangeLabel, slotList: slotList, scheduleErrorText: scheduleErrorText, addDays: addDays, dateLabel: dateLabel, timeLabel: timeLabel, timeRange: timeRange, chip: chip, lockReason: lockReason,
           remarksDue: remarksDue, attendanceOptions: attendanceOptions, parseCharge: parseCharge, needsCharge: needsCharge, adminChargeNote: adminChargeNote, group: group, errorText: errorText, changes: changes };
});
