// Centre Timetable page logic with no DOM and no network (T3 step 6, read only): the week as a day-by-day list, the holiday band, how a row
// looks (chips, "no tutor" flag), the filters and what the database's refusals mean in plain words.
// Used by assets/js/centre-timetable.js and unit-tested in tests/centre-timetable-core.test.js. The database decides everything that matters
// (db/migration_staff_timetable.sql, function staff_timetable); this file only saves a round trip and words the answers.
// The date helpers are the Attendance page's (assets/js/centre-attendance-core.js), so the two screens always agree on what a week is.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory(require("./centre-attendance-core.js"));
  else root.CentreTimetableCore = factory(root.CentreAttendanceCore);
})(typeof self !== "undefined" ? self : this, function (CA) {
  "use strict";
  var PAGE_SIZE = 50;
  var LONG_AGO = "2000-01-01";                // a "today" that is never today, so dayLabel prints a plain "Thu 26 Nov"
  var VIEWS = ["week", "day", "next14"];       // next14 = today and the 13 days after: exactly what the Home "no tutor, next 14 days" tile counts

  // ---- days ----
  // A view is one Monday–Sunday week (the default), one day, or 14 days from the anchor. Week and day follow the Attendance page's rule.
  function range(view, anchor) {
    if (view === "next14") return { from: anchor, to: CA.addDays(anchor, 13) };
    return CA.range(view === "day" ? "day" : "week", anchor);
  }
  function shift(view, anchor, dir) { return view === "next14" ? CA.addDays(anchor, 14 * dir) : CA.shift(view === "day" ? "day" : "week", anchor, dir); }
  function rangeLabel(view, anchor, today) {
    if (view === "next14") { var r = range(view, anchor); return CA.dayLabel(r.from, LONG_AGO) + " – " + CA.dayLabel(r.to, LONG_AGO); }
    return CA.rangeLabel(view === "day" ? "day" : "week", anchor, today);
  }
  function datesIn(from, to) { var out = [], d = from, n = 0; while (d <= to && n++ < 70) { out.push(d); d = CA.addDays(d, 1); } return out; }

  // ---- holidays: the grey band ----
  // The holidays that cover one day. The database returns them in start order; the band names each one, with its branch if it belongs to one.
  function holidaysOn(iso, holidays) {
    return (holidays || []).filter(function (h) { return h.starts_on <= iso && h.ends_on >= iso; });
  }
  function holidayLabel(h) { return h.name + (h.branch_name ? " (" + h.branch_name + ")" : ""); }
  function bandText(list) { return list.map(holidayLabel).join(" · "); }

  // ---- a day's block ----
  // The page's rows grouped by day, in the order the database gave. When everything fits one page (`all`) every day of the window is
  // listed, empty ones included (a week with nothing on Wednesday should say so); on a later page only days that have rows are.
  // → [{ date, rows, holidays }]
  function days(rows, holidays, from, to, all) {
    var idx = {}, out = [];
    (rows || []).forEach(function (r) { (idx[r.lesson_date] = idx[r.lesson_date] || []).push(r); });
    (all ? datesIn(from, to) : Object.keys(idx).sort()).forEach(function (d) {
      out.push({ date: d, rows: idx[d] || [], holidays: holidaysOn(d, holidays) });
    });
    return out;
  }

  // ---- one row ----
  // chips for a lesson, in the order they are shown. tone: warn (amber) | ok (teal) | muted (grey).
  //   Trial · Cancelled / Moved / Holiday · and the attendance chip: marked → what it was marked; open (its day has started) → "Not marked".
  //   An upcoming lesson has no attendance chip (it would be on every row of next week and say nothing).
  function chips(r) {
    var out = [];
    if (r.trial) out.push({ text: "Trial", tone: "trial" });
    if (r.covered_for_name && !r.cancelled) out.push({ text: "Covered by " + (r.tutor_name || "another tutor"), tone: "cover" });
    if (r.cancelled) out.push({ text: "Cancelled", tone: "muted" });
    else {
      if (r.postponed) out.push({ text: "Moved", tone: "muted" });
      if (r.state === "marked") { var m = CA.mark(r.attendance); out.push({ text: m ? m.short : "Marked", tone: m ? m.tone : "muted" }); }
      else if (r.state === "open") out.push({ text: "Not marked", tone: "warn" });
    }
    if (r.holiday) out.push({ text: "Holiday", tone: "muted" });
    return out;
  }
  // the second line of a row: who teaches it. No tutor = a warning the row shows in amber.
  function tutorLine(r) {
    if (r.no_tutor) return { text: "No tutor yet", warn: true };
    if (r.tutor_name) return { text: r.tutor_name, warn: false };
    return { text: r.cancelled ? "No tutor" : "No tutor yet", warn: false };       // a cancelled lesson nobody teaches is not a job to do
  }
  function durationLabel(minutes) {
    var m = Number(minutes); if (!isFinite(m) || m <= 0) return "";
    if (m < 60) return m + " min";
    var h = Math.floor(m / 60), rest = m % 60;
    return h + " h" + (rest ? " " + rest + " min" : "");
  }
  // the read-only facts the lesson sheet lists
  function facts(r) {
    var out = [];
    out.push(["Time", CA.timeRange(r) + (durationLabel(r.minutes) ? " (" + durationLabel(r.minutes) + ")" : "")]);
    out.push(["Tutor", tutorLine(r).text]);
    if (r.covered_for_name && !r.cancelled) out.push(["Covering for", r.covered_for_name]);
    if (r.student_level) out.push(["Level", r.student_level]);
    if (r.subject) out.push(["Subject", r.subject]);
    out.push(["Online link", r.online_link ? r.online_link : "Not set"]);
    var c = chips(r).map(function (x) { return x.text; });
    if (c.length) out.push(["Status", c.join(" · ")]);
    if (r.holiday) out.push(["Holiday", r.holiday]);
    return out;
  }

  // ---- filters ----
  // state = { view, anchor, tutor, branch, student, notutor, page }  →  the arguments of staff_timetable
  function args(orgId, s) {
    var r = range(s.view, s.anchor);
    return { p_org: orgId, p_from: r.from, p_to: r.to, p_tutor: s.tutor || null, p_branch: s.branch || null, p_student: s.student || null,
             p_page: s.page || 1, p_notutor: !!s.notutor, p_size: PAGE_SIZE };
  }
  var UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  // the address → a filter state (anything odd is ignored, never an error). q = URLSearchParams-like { get(name) }
  function fromQuery(q) {
    var s = { view: "week", anchor: null, tutor: "", branch: "", student: "", notutor: false, page: 1 };
    if (q.get("view") === "day" || q.get("view") === "next14") s.view = q.get("view");
    if (CA.validISO(q.get("date"))) s.anchor = q.get("date");
    ["tutor", "branch", "student"].forEach(function (k) { var v = q.get(k); if (v && UUID.test(v)) s[k] = v; });
    if (q.get("f") === "notutor") s.notutor = true;
    return s;
  }
  // a filter state → the part of the address after "?" (so a reload or a shared link keeps the view). `id` is the centre.
  function toQuery(id, s, today) {
    var p = ["id=" + encodeURIComponent(id)];
    if (s.view === "day" || s.view === "next14") p.push("view=" + s.view);
    if (s.anchor && s.anchor !== today) p.push("date=" + s.anchor);
    if (s.tutor) p.push("tutor=" + encodeURIComponent(s.tutor));
    if (s.branch) p.push("branch=" + encodeURIComponent(s.branch));
    if (s.student) p.push("student=" + encodeURIComponent(s.student));
    if (s.notutor) p.push("f=notutor");
    return p.join("&");
  }
  function anyFilter(s) { return !!(s.tutor || s.student || s.notutor); }          // (a branch only chooses which holidays show)
  // the student picker: names with lessons in the window, narrowed by what was typed (case-insensitive, any part of the name)
  function matchStudents(list, q) {
    var t = String(q || "").trim().toLowerCase();
    return (list || []).filter(function (s) { return !t || String(s.name || "").toLowerCase().indexOf(t) >= 0; });
  }

  // ---- paging ----
  function pageCount(total, size) { return CA.pageCount(total, size || PAGE_SIZE); }
  function pagerLabel(page, size, total) { return CA.pagerLabel(page, size, total); }
  function countText(total, counts, s) {
    if (!total) return "";
    var t = total + (total === 1 ? " lesson" : " lessons");
    if (!s.notutor && counts && counts.n_notutor) t += " · " + counts.n_notutor + " with no tutor";
    return t;
  }
  function emptyText(s) {
    var when = s.view === "day" ? "this day" : s.view === "next14" ? "in the next 14 days" : "this week";
    if (s.notutor) return { title: "Every lesson has a tutor", hint: "No lesson " + when + " is waiting for a tutor." };
    if (s.tutor || s.student) return { title: "No lessons " + when, hint: "Nothing matches these filters. Clear them to see the whole centre." };
    return { title: "No lessons " + when, hint: "Lessons made from the timetable appear here." };
  }

  // ---- reassign or cover one lesson (T3 step 8) ----
  // What the lesson sheet offers for this lesson. The database decides (staff_reassign_lesson); this only saves a round trip and words it.
  //   kind: "hidden" (no button: the caller can't edit the timetable, or this database has no such function yet) | "locked" (a note: the lesson can
  //   no longer change hands) | "off" (a note: the centre doesn't allow replacement tutors) | "assign" (no tutor yet: pick the first one) | "form".
  var OFF_NOTE = "This centre doesn’t allow replacement tutors. An owner can switch it on in Centre settings.";
  function reassignState(res, r) {
    if (!res || res.can_edit !== true || !r || typeof r.can_reassign !== "boolean") return { kind: "hidden" };
    if (!r.can_reassign) {
      var why = r.state === "marked" ? "This lesson is already marked, so it stays with the tutor who taught it."
              : r.cancelled ? "This lesson was cancelled, so it can’t change tutor."
              : "This lesson is paid or on an invoice, so it can’t change tutor.";
      return { kind: "locked", note: why };
    }
    if (!r.tutor_id) return { kind: "assign", label: "Assign a tutor" };
    if (res.replacements_allowed === false) return { kind: "off", note: OFF_NOTE };
    return { kind: "form", label: "Reassign or cover" };
  }
  // the tutors who can be picked: active ones, never the person who already teaches it
  function coverOptions(res, r) {
    return ((res && res.tutors) || []).filter(function (t) { return t.active !== false && t.id !== (r && r.tutor_id); })
      .sort(function (a, b) { return String(a.name || "").localeCompare(String(b.name || "")); });
  }
  var REASON_MAX = 500;
  // form = { tutor, mode: "cover" | "reassign", reason, links }  →  an error text, or "" when it can be sent
  function checkReassign(r, form) {
    if (!form || !form.tutor) return "Choose who will teach this lesson.";
    if (form.tutor === r.tutor_id) return "That tutor already teaches this lesson.";
    var reason = String(form.reason || "").trim();
    if (r.tutor_id && !reason) return "Say why. It is kept on record.";
    if (reason.length > REASON_MAX) return "Keep the reason under " + REASON_MAX + " characters.";
    return "";
  }
  function reassignArgs(r, form) {
    var mode = r.tutor_id && form.mode === "cover" ? "cover" : "reassign";
    return { p_lesson: r.lesson_id, p_new_tutor: form.tutor, p_mode: mode, p_reason: String(form.reason || "").trim() || null,
             p_update_links: mode === "reassign" && !!form.links };
  }
  function reassignedText(res, form) {
    var n = res && res.lessons > 1 ? " (" + res.lessons + " lessons of the class)" : "";
    var who = (res && res.tutor_name) || "the new tutor";
    return (form && form.mode === "cover" && res && res.covered_for ? who + " is covering this lesson" : who + " now teaches this lesson") + n + ".";
  }
  function reassignErrorText(err) {
    var m = String((err && err.message) || err || "");
    var map = [
      [/REPLACEMENT_OFF/, OFF_NOTE],
      [/ALREADY_MARKED/, "This lesson is already marked, so it stays with the tutor who taught it."],
      [/CANCELLED/, "This lesson was cancelled, so it can’t change tutor."],
      [/PAID/, "This lesson is already paid, so it can’t change tutor."],
      [/INVOICED/, "This lesson is on an invoice, so it can’t change tutor."],
      [/NOT_ALLOWED/, "Your account can’t change the timetable at this centre."],
      [/NOT_AVAILABLE/, "That person can’t be given lessons here. Pick an active tutor."],
      [/NO_CHANGE/, "That tutor already teaches this lesson."],
      [/NO_TUTOR_TO_COVER/, "This lesson has no tutor yet. Assign one instead."],
      [/REASON_REQUIRED/, "Say why. It is kept on record."],
      [/TOO_LONG/, "Keep the reason under " + REASON_MAX + " characters."],
      [/PICK_TUTOR/, "Choose who will teach this lesson."],
      [/LINK_NOT_FOR_COVER/, "A cover is for this lesson only, so it can’t change who a student is assigned to."],
      [/BAD_MODE/, "Choose cover or reassign."],
      [/NOT_FOUND/, "That lesson isn’t available any more. Refresh the page and try again."]
    ];
    for (var i = 0; i < map.length; i++) if (map[i][0].test(m)) return map[i][1];
    if (CA.isMissing(err)) return "Reassigning needs db/migration_staff_reassign.sql run first.";
    return CA.errorText(err);
  }

  // ---- the database's refusals, in plain words ----
  function errorText(err) {
    var m = String((err && err.message) || err || "");
    if (/NOT_FOUND/.test(m)) return "That isn’t available any more. Refresh the page and try again.";
    return CA.errorText(err);
  }
  function isMissing(err) { return CA.isMissing(err); }

  return { PAGE_SIZE: PAGE_SIZE, VIEWS: VIEWS, range: range, shift: shift, rangeLabel: rangeLabel, datesIn: datesIn, holidaysOn: holidaysOn,
           holidayLabel: holidayLabel, bandText: bandText, days: days, chips: chips, tutorLine: tutorLine, durationLabel: durationLabel, facts: facts,
           reassignState: reassignState, coverOptions: coverOptions, checkReassign: checkReassign, reassignArgs: reassignArgs,
           reassignedText: reassignedText, reassignErrorText: reassignErrorText, REASON_MAX: REASON_MAX, OFF_NOTE: OFF_NOTE,
           args: args, fromQuery: fromQuery, toQuery: toQuery, anyFilter: anyFilter, matchStudents: matchStudents,
           pageCount: pageCount, pagerLabel: pagerLabel, countText: countText, emptyText: emptyText, errorText: errorText, isMissing: isMissing,
           dayLabel: CA.dayLabel, timeLabel: CA.timeLabel, timeRange: CA.timeRange, validISO: CA.validISO };
});
