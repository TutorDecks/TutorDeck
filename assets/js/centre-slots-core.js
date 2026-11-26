// Centre weekly slots, the lesson generator and assigned tutors (T3 step 7): the page logic with no DOM and no network.
// Used by assets/js/centre-timetable.js (Weekly slots view) and assets/js/centre-students.js (the Assigned tutors panel), and unit-tested in
// tests/centre-slots-core.test.js. The database decides everything that matters (db/migration_staff_slots.sql); this file only saves a round trip
// (the same checks, so a typing mistake is caught before the call) and words the answers in plain language.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory(require("./centre-attendance-core.js"));
  else root.CentreSlotsCore = factory(root.CentreAttendanceCore);
})(typeof self !== "undefined" ? self : this, function (CA) {
  "use strict";
  var DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];   // weekday 0 = Monday, like the Planner
  var DAY_SHORT = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
  var MAX_STUDENTS = 30, MIN_MINUTES = 15, MAX_MINUTES = 480, MAX_RATE = 1000, PAGE_SIZE = 25;

  function plural(n, one, many) { return n + " " + (n === 1 ? one : many); }
  function hm(t) { return t ? String(t).slice(0, 5) : ""; }                              // "16:00:00" → "16:00"
  function toMin(t) { var p = hm(t).split(":"); return p.length === 2 ? (+p[0]) * 60 + (+p[1]) : NaN; }
  function minutesBetween(a, b) { return toMin(b) - toMin(a); }
  function isoWeekday(iso) { var d = new Date(iso + "T00:00:00Z"); return (d.getUTCDay() + 6) % 7; }   // Monday = 0

  // ---- the form: the same checks the database makes ----
  // form = { students: [id…] (add only), weekday, start, end, tutor, subject, rate }. mode = "add" | "edit".
  // → { field: message }  (empty = fine). The database still checks everything again.
  function validate(form, mode) {
    var e = {}, wd = form.weekday === "" || form.weekday == null ? NaN : Number(form.weekday);
    if (mode === "add" && !(form.students && form.students.length)) e.students = "Pick at least one student.";
    if (mode === "add" && form.students && form.students.length > MAX_STUDENTS) e.students = "A class has at most " + MAX_STUDENTS + " students.";
    if (!(wd >= 0 && wd <= 6) || Math.floor(wd) !== wd) e.weekday = "Pick a day of the week.";
    var m = minutesBetween(form.start, form.end);
    if (!form.start) e.start = "Give a start time.";
    else if (!form.end) e.end = "Give an end time.";
    else if (!(m > 0)) e.end = "The lesson must end after it starts.";
    else if (m < MIN_MINUTES || m > MAX_MINUTES) e.end = "A lesson lasts 15 minutes to 8 hours.";
    var r = String(form.rate == null ? "" : form.rate).trim();
    if (r === "") { if (mode === "add") e.rate = "Type the rate per hour."; }
    else if (!/^\d{1,4}(\.\d{1,2})?$/.test(r) || Number(r) > MAX_RATE) e.rate = "The rate per hour must be between 0 and " + MAX_RATE + ".";
    if (String(form.subject || "").trim().length > 60) e.subject = "The subject is too long (60 characters at most).";
    return e;
  }
  // → the arguments of staff_save_slot (edit: p_students is null, an empty rate means "keep")
  function saveArgs(orgId, slotId, form, mode) {
    var r = String(form.rate == null ? "" : form.rate).trim();
    return { p_org: orgId, p_slot: mode === "edit" ? slotId : null, p_students: mode === "edit" ? null : (form.students || []).slice(),
             p_weekday: Number(form.weekday), p_start: hm(form.start), p_end: hm(form.end), p_tutor: form.tutor || null,
             p_subject: String(form.subject || "").trim() || null, p_rate: r === "" ? null : Number(r) };
  }

  // ---- the list ----
  function rateText(n) {
    if (n == null || n === "") return "";
    var v = Number(n); if (!isFinite(v)) return "";
    return "S$" + (v % 1 === 0 ? v.toFixed(0) : v.toFixed(2)) + "/hr";
  }
  function studentsText(row, max) {
    var names = (row.students || []).map(function (s) { return s.name; }), m = max || 3;
    if (names.length <= m) return names.join(", ");
    return names.slice(0, m).join(", ") + " +" + (names.length - m);
  }
  function kindText(row) { return row.is_group ? "Class of " + (row.students || []).length : ""; }
  function tutorLine(row) {
    if (row.no_tutor) return { text: row.tutor_name === "Former tutor" ? "Former tutor: pick a new tutor" : "No tutor yet", warn: true };
    return { text: row.tutor_name || "No tutor yet", warn: false };
  }
  function timeText(row) { return CA.timeRange({ start_time: row.start_time, end_time: row.end_time }); }
  // rows grouped by weekday (Monday first), in the order the database gave them
  function byDay(rows) {
    var out = [], idx = {};
    (rows || []).forEach(function (r) {
      var k = Number(r.weekday);
      if (!idx[k]) { idx[k] = { weekday: k, name: DAYS[k] || "", rows: [] }; out.push(idx[k]); }
      idx[k].rows.push(r);
    });
    return out.sort(function (a, b) { return a.weekday - b.weekday; });
  }
  function countText(total, genUntil, fmt) {
    if (!total) return "";
    return plural(total, "weekly slot", "weekly slots") + (genUntil ? " · lessons made up to " + (fmt ? fmt(genUntil) : genUntil) : " · no lessons made yet");
  }
  function emptyText(filtered) {
    return filtered ? { title: "No weekly slots match", hint: "Clear the search or the tutor to see them all." }
                    : { title: "No weekly slots yet", hint: "Add a weekly slot with a student, a day and a time, then create the lessons from it." };
  }

  // ---- the answer of the generator, in the plain words the button shows ----
  // "12 created, 0 skipped, 2 holidays" + a second line only when there is something to say
  function generateMessage(res) {
    res = res || {};
    var created = Number(res.created) || 0, skipped = Number(res.skipped) || 0, hol = Number(res.holidays) || 0;
    var head = created + " created, " + skipped + " skipped, " + plural(hol, "holiday", "holidays");
    var more = [];
    if (!(Number(res.slots) > 0)) more.push("There are no weekly slots yet. Add one first.");
    else if (created === 0 && skipped > 0) more.push("Nothing new: these weeks were already created.");
    if (Number(res.ended) > 0) more.push(plural(Number(res.ended), "lesson was", "lessons were") + " left out because the student has finished.");
    if (Number(res.no_tutor) > 0) more.push(plural(Number(res.no_tutor), "new lesson has", "new lessons have") + " no tutor yet. Give the weekly slot a tutor, or pick one in Timetable.");
    if (Number(res.on_holiday) > 0) more.push(plural(Number(res.on_holiday), "new lesson falls", "new lessons fall") + " on a holiday, because this centre doesn’t skip holidays.");
    return { head: head, more: more, text: [head].concat(more).join(" ") };
  }
  function savedText(res, mode) {
    if (mode === "add") { var n = Number(res && res.added) || 1; return n > 1 ? "Weekly slot added for " + n + " students" : "Weekly slot added"; }
    var left = Number(res && res.lessons_left) || 0;
    return "Weekly slot changed" + (left ? ". " + plural(left, "lesson", "lessons") + " already created keep the old time and tutor." : "");
  }
  function stoppedText(res) {
    var left = Number(res && res.lessons_left) || 0;
    return "Weekly slot stopped" + (left ? ". " + plural(left, "upcoming lesson", "upcoming lessons") + " already created stay in the timetable." : "");
  }

  // ---- assigned tutors and the online link ----
  function assignedText(list) { return (list || []).map(function (t) { return t.name; }).join(", "); }
  function sameSet(a, b) { a = (a || []).slice().sort(); b = (b || []).slice().sort(); return a.length === b.length && a.every(function (x, i) { return x === b[i]; }); }
  function linkProblem(v) {
    v = String(v == null ? "" : v).trim();
    if (!v) return "";
    if (v.length > 500) return "That link is too long (500 characters at most).";
    if (!/^https:\/\/[^\s]+$/.test(v)) return "The link must start with https:// and have no spaces.";
    return "";
  }

  // ---- the database's refusals, in plain words ----
  function errorText(err) {
    var m = String((err && err.message) || err || "");
    var map = [
      [/NOT_ALLOWED/, "Your account can’t change the timetable at this centre."],
      [/NOT_FOUND/, "That isn’t available any more. Refresh the page and try again."],
      [/BAD_TIME: the lesson must end/, "The lesson must end after it starts."],
      [/BAD_TIME/, "A lesson lasts 15 minutes to 8 hours."],
      [/BAD_RATE: type/, "Type the rate per hour."],
      [/BAD_RATE/, "The rate per hour must be between 0 and 1000."],
      [/BAD_STUDENTS: pick/, "Pick at least one student."],
      [/BAD_STUDENTS: a class/, "A class has at most 30 students."],
      [/BAD_STUDENTS/, "To change who is in a slot, stop it and add a new one."],
      [/BAD_TUTORS/, "A student has at most 20 assigned tutors."],
      [/BAD_SLOT: pick/, "Pick a day of the week."],
      [/BAD_SLOT/, "The subject is too long (60 characters at most)."],
      [/BAD_LINK/, "The link must start with https:// and have no spaces."],
      [/NOT_AVAILABLE/, "That person can’t be given lessons here any more. Pick someone else."],
      [/STUDENT_ENDED: (.+?)['’]s lessons have ended/, null],
      [/SLOT_CLASH: (.+?) already has/, null],
      [/BAD_RANGE: lessons can/, "Lessons can’t be created for days that have passed."],
      [/BAD_RANGE/, "Choose a shorter period."],
      [/BAD_SEARCH|BAD_PAGE/, "That choice isn’t available. Refresh the page and try again."]
    ];
    for (var i = 0; i < map.length; i++) {
      var x = map[i][0].exec(m);
      if (!x) continue;
      if (map[i][1]) return map[i][1];
      if (/STUDENT_ENDED/.test(m)) return x[1] + "’s lessons have ended, so they can’t get a weekly slot.";
      if (/SLOT_CLASH/.test(m)) return x[1] + " already has a weekly lesson at that time.";
    }
    return CA.errorText(err);
  }
  function isMissing(err) { return CA.isMissing(err); }

  return { DAYS: DAYS, DAY_SHORT: DAY_SHORT, MAX_STUDENTS: MAX_STUDENTS, PAGE_SIZE: PAGE_SIZE, hm: hm, minutesBetween: minutesBetween, isoWeekday: isoWeekday,
           validate: validate, saveArgs: saveArgs, rateText: rateText, studentsText: studentsText, kindText: kindText, tutorLine: tutorLine, timeText: timeText,
           byDay: byDay, countText: countText, emptyText: emptyText, generateMessage: generateMessage, savedText: savedText, stoppedText: stoppedText,
           assignedText: assignedText, sameSet: sameSet, linkProblem: linkProblem, errorText: errorText, isMissing: isMissing,
           pageCount: CA.pageCount, timeLabel: CA.timeLabel, dateText: function (iso) { return CA.dayLabel(iso, "2000-01-01"); },
           pagerLabel: function (page, size, total) { return total ? CA.pagerLabel(page, size, total) : "No slots"; } };
});
