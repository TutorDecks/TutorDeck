// What staff read about lessons their tutors changed (T6 step 2): the "Tutor changes" list on the centre Home and the amber "Changed by tutor" flag on the
// Timetable. No DOM, no network; the rows come from staff_tutor_changes(org) (db/migration_tutor_moves.sql), which carries no money.
// Unit-tested in tests/tutor-changes-core.test.js.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.TutorChangesCore = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  var MO = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  var WD = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  function dayText(iso) { if (!iso) return ""; var d = new Date(iso + "T00:00:00Z"); return WD[d.getUTCDay()] + " " + d.getUTCDate() + " " + MO[d.getUTCMonth()]; }
  function timeText(t) {
    var m = /^(\d{1,2}):(\d{2})/.exec(String(t || "")); if (!m) return "";
    var h = Number(m[1]), ap = h >= 12 ? "pm" : "am"; h = h % 12 || 12; return h + ":" + m[2] + " " + ap;
  }
  function when(date, time) { return (dayText(date) + " " + timeText(time)).trim(); }
  function dayDiff(a, b) { return Math.round((new Date(a + "T00:00:00Z") - new Date(b + "T00:00:00Z")) / 86400000); }

  // "Tutor One moved Kid One"
  function headline(r) {
    var who = r.tutor_name || "A tutor", kid = r.student_name || "a student";
    if (r.what === "cancelled") return who + " cancelled " + kid;
    if (r.what === "reverted") return who + " put " + kid + " back to the usual time";
    return who + " moved " + kid;
  }
  // "Tue 1 Dec 4:00 pm → Fri 4 Dec 5:00 pm" / "Tue 1 Dec 4:00 pm (cancelled)"
  function detail(r) {
    if (r.what === "cancelled") return when(r.lesson_date, r.start_time) + " (cancelled)";
    var from = when(r.from_date, r.from_start), to = when(r.lesson_date, r.start_time);
    return from ? from + " → " + to : "Now " + to;
  }
  // "today", "yesterday", "3 days ago": changed_at is a timestamp; `today` is the centre's own date from the same answer
  function ago(r, today) {
    var d = String(r.changed_at || "").slice(0, 10), n = d && today ? dayDiff(today, d) : null;
    if (n == null || isNaN(n) || n <= 0) return "today";
    return n === 1 ? "yesterday" : n + " days ago";
  }
  // The amber flag on the Timetable row, and what the lesson sheet says. `r` is one entry of the staff list.
  function chip(r) { return r ? { text: "Changed by tutor", tone: "warn" } : null; }
  function sheetFact(r, today) {
    if (!r) return null;
    return [r.what === "cancelled" ? "Cancelled by" : r.what === "reverted" ? "Put back by" : "Moved by",
            (r.tutor_name || "A tutor") + ", " + ago(r, today) + (r.reason ? ". “" + r.reason + "”" : "") + (r.what === "moved" && r.from_date ? ". Was " + when(r.from_date, r.from_start) : "")];
  }
  function byLesson(rows) { var m = {}; (rows || []).forEach(function (r) { if (r && r.lesson_id && !m[r.lesson_id]) m[r.lesson_id] = r; }); return m; }   // rows are newest first: the newest change of a lesson is the one its row shows
  // the note under the Home list: what staff are expected to do
  function homeNote(tellFamily) {
    return tellFamily ? "Tell the family about each change. A tutor’s cancel is at no charge to them; decide whether they get a make-up lesson." : "Tutors’ changes are listed for your information.";
  }
  return { headline: headline, detail: detail, ago: ago, chip: chip, sheetFact: sheetFact, byLesson: byLesson, homeNote: homeNote, when: when };
});
