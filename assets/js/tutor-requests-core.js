// What a tutor's REQUEST says, in plain words (T6 step 6, tutors_propose). Used by the tutor Schedule (their own requests) and by the staff Requests list on the centre Home.
// No DOM, no network, and nothing about money: the rows come from tutor_my_requests() and staff_schedule_requests(org) (db/migration_tutor_link_propose.sql), which carry none.
// Unit-tested in tests/tutor-requests-core.test.js.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.TutorRequestsCore = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  var MO = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  var WD = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  var WDM = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];     // a slot's weekday: 0 = Monday
  function dayText(iso) { if (!iso) return ""; var d = new Date(String(iso).slice(0, 10) + "T00:00:00Z"); return WD[d.getUTCDay()] + " " + d.getUTCDate() + " " + MO[d.getUTCMonth()]; }
  function timeText(t) {
    var m = /^(\d{1,2}):(\d{2})/.exec(String(t || "")); if (!m) return "";
    var h = Number(m[1]), ap = h >= 12 ? "pm" : "am"; h = h % 12 || 12; return h + ":" + m[2] + " " + ap;
  }
  function when(date, time) { return (dayText(date) + " " + timeText(time)).trim(); }
  function dayDiff(a, b) { return Math.round((new Date(a + "T00:00:00Z") - new Date(b + "T00:00:00Z")) / 86400000); }
  function plural(n, one, many) { return n + " " + (n === 1 ? one : many); }

  // What is being asked for ("Move to Fri 4 Dec 5:00 pm"). `r` is one row of either list.
  function ask(r) {
    switch (r && r.kind) {
      case "postpone": return "Move to " + when(r.new_date, r.new_start);
      case "revert": return "Put back to its usual time";
      case "cancel": return "Cancel the lesson (the family is not charged)";
      case "add_lesson": return "Add a lesson on " + when(r.new_date, r.new_start) + (r.new_end ? " – " + timeText(r.new_end) : "");
      case "save_slot": return r.slot_id ? "Change the weekly slot to " + (WDM[Number(r.weekday)] || "") + " " + timeText(r.new_start) + (r.new_end ? " – " + timeText(r.new_end) : "")
                                        : "Add a weekly slot on " + (WDM[Number(r.weekday)] || "") + " " + timeText(r.new_start) + (r.new_end ? " – " + timeText(r.new_end) : "");
      case "stop_slot": return "Stop the weekly slot";
      case "generate": return "Create lessons from " + dayText(r.from_date) + " to " + dayText(r.to_date);
      case "link": return (r.link ? "Set the online link" : "Remove the online link") + (r.link_scope === "lesson" ? " for this lesson" : " for this student");
      default: return "A change";
    }
  }
  // The line above it: for a tutor "Move Ann"; for staff "Tutor One asks to move Ann".
  var VERB = { postpone: "move", revert: "put back", cancel: "cancel", add_lesson: "add a lesson for", save_slot: "change the weekly slot of", stop_slot: "stop the weekly slot of", generate: "create lessons", link: "set the online link of" };
  function headline(r, forStaff) {
    var kid = (r && r.student_name) || "";
    var verb = VERB[r && r.kind] || "change";
    if (r && r.kind === "save_slot" && !r.slot_id) verb = "add a weekly slot for";
    var what = verb + (kid && r.kind !== "generate" ? " " + kid : "");
    return forStaff ? ((r.tutor_name || "A tutor") + " asks to " + what) : what.charAt(0).toUpperCase() + what.slice(1);
  }
  // What it is now ("Now Tue 1 Dec 4:00 pm"): the lesson, or the slot, as it stands today
  function now(r) {
    if (!r) return "";
    if (r.lesson_date && (r.kind === "postpone" || r.kind === "revert" || r.kind === "cancel" || (r.kind === "link" && r.link_scope === "lesson"))) return "Now " + when(r.lesson_date, r.start_time);
    if (r.slot_id && (r.kind === "save_slot" || r.kind === "stop_slot") && r.slot_start) return "Now every " + (WDM[Number(r.weekday)] || "") + " " + timeText(r.slot_start) + (r.slot_end ? " – " + timeText(r.slot_end) : "");
    return "";
  }
  var STATUS = {
    pending: { text: "Waiting for an admin", tone: "warn" }, approved: { text: "Approved", tone: "ok" }, declined: { text: "Declined", tone: "muted" },
    cancelled: { text: "You took it back", tone: "muted" }, expired: { text: "Ran out", tone: "muted" }, no_longer_possible: { text: "No longer possible", tone: "muted" }
  };
  function status(r, forStaff) {
    var s = STATUS[r && r.status] || { text: "", tone: "muted" };
    if (forStaff && r && r.status === "cancelled") return { text: "Taken back", tone: "muted" };
    if (forStaff && r && r.status === "pending") return { text: "Waiting for you", tone: "warn" };
    return s;
  }
  // "Asked today" / "Asked 3 days ago"; "runs out in 4 days" (today is the centre's own date from the same answer)
  function asked(r, today) {
    var d = String((r && r.created_at) || "").slice(0, 10), n = d && today ? dayDiff(today, d) : null;
    return n == null || isNaN(n) || n <= 0 ? "Asked today" : n === 1 ? "Asked yesterday" : "Asked " + n + " days ago";
  }
  function expires(r, today) {
    var d = String((r && r.expires_at) || "").slice(0, 10), n = d && today ? dayDiff(d, today) : null;
    if (n == null || isNaN(n)) return "";
    return n <= 0 ? "Runs out today" : n === 1 ? "Runs out tomorrow" : "Runs out in " + n + " days";
  }
  // the sentence under a finished request: why it was declined / couldn't be done / ran out
  function outcome(r) {
    if (!r) return "";
    if (r.status === "declined") return "Declined" + (r.decision_reason ? ": " + r.decision_reason : "");
    if (r.status === "no_longer_possible") return "Couldn't be done: " + String(r.decision_reason || "it no longer applies").replace(/^./, function (c) { return c.toLowerCase(); }) + ".";
    if (r.status === "expired") return "Nobody answered in time, so nothing changed. You can ask again.";
    if (r.status === "cancelled") return "You took this request back. Nothing changed.";
    if (r.status === "approved") return "Approved: the change has been made.";
    return "";
  }
  // The same, for staff (who read it about a tutor): "Approved by Sam", "Declined by Sam: ...", "Taken back by the tutor"
  function staffOutcome(r) {
    var by = r && r.decided_by_name ? " by " + r.decided_by_name : "", low = function (t) { return String(t || "it no longer applies").replace(/^./, function (c) { return c.toLowerCase(); }); };
    switch (r && r.status) {
      case "approved": return "Approved" + by + ".";
      case "declined": return "Declined" + by + (r.decision_reason ? ": " + r.decision_reason : "") + ".";
      case "no_longer_possible": return "Couldn't be done: " + low(r.decision_reason) + ". Nothing was changed.";
      case "expired": return "Ran out: nobody answered in time. Nothing was changed.";
      case "cancelled": return "The tutor took this request back.";
      default: return "";
    }
  }
  function waitingCount(rows) { return (rows || []).filter(function (r) { return r.status === "pending"; }).length; }
  // The toast after a tutor asks (the database answered requested = true)
  function sentText(r) { return "Request sent. Nothing changes until an admin approves it. You can follow it under “My requests”."; }
  function homeNote(n) { return n ? "Approving makes the change straight away, after checking every rule again. Declining tells the tutor why." : "Nothing is waiting for you."; }
  // The words staff read when answering fails
  var DECIDE_FIXED = {
    NOT_FOUND: "That request isn't available to you any more. Please refresh.",
    NOT_ALLOWED: "Your account can't answer timetable requests at this centre.",
    ALREADY_DECIDED: "Someone has already answered this request. Please refresh.",
    REASON_REQUIRED: "Please say why, in a few words. The tutor reads it.",
    TOO_LONG: "Please keep the reason under 300 characters."
  };
  function decideErrorText(err) {
    var m = /^([A-Z_]+)(?::|$)/.exec(String((err && err.message) || ""));
    return (m && DECIDE_FIXED[m[1]]) || "We couldn't save that just now. Please try again.";
  }
  // What staff are told after pressing Approve (the database's status decides)
  function approveResult(d) {
    var s = d && d.status;
    if (s === "approved") return d.already ? "Already approved." : "Approved. The change has been made.";
    if (s === "no_longer_possible") return "This can't be done any more: " + String(d.reason || "it no longer applies").replace(/^./, function (c) { return c.toLowerCase(); }) + ". Nothing was changed.";
    if (s === "expired") return "This request had run out, so nothing was changed.";
    if (s === "cancelled") return "The tutor took this request back, so nothing was changed.";
    if (s === "declined") return "Already declined.";
    return "Done.";
  }
  // The link a tutor types: https:// only, no spaces, 500 characters at most (the database checks the same). '' clears.
  function linkCheck(raw) {
    var v = String(raw == null ? "" : raw).trim();
    if (!v) return { link: "" };
    if (v.length > 500 || !/^https:\/\/[^\s]+$/.test(v)) return { error: "Please paste a link that starts with https:// and has no spaces." };
    return { link: v };
  }
  return { ask: ask, headline: headline, now: now, status: status, asked: asked, expires: expires, outcome: outcome, staffOutcome: staffOutcome, waitingCount: waitingCount, sentText: sentText, homeNote: homeNote,
           decideErrorText: decideErrorText, approveResult: approveResult, linkCheck: linkCheck, dayText: dayText, timeText: timeText, when: when, plural: plural };
});
