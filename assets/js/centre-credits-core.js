// Make-up credits page logic with no DOM and no network (T18 step 4): how a credit row is worded, what the buttons are, what a booking must look like
// before it is sent, and what the database's refusals mean in plain words. Used by assets/js/centre-credits.js and unit-tested in
// tests/centre-credits-core.test.js. The database decides everything that matters (db/migration_makeup_credits.sql: who may, the price rule, the expiry,
// one credit per missed lesson); this file only saves a round trip and words the answers. There is NO money anywhere in here: staff see which make-up is
// free or billed normally, never an amount.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory(require("./tutor-core.js"), require("./centre-attendance-core.js"));
  else root.CentreCreditsCore = factory(root.TutorCore, root.CentreAttendanceCore);
})(typeof self !== "undefined" ? self : this, function (TC, CA) {
  "use strict";
  var PAGE_SIZE = 25, REASON_MIN = 3, REASON_MAX = 300;

  // the four lists staff can look at (the database also knows expired and revoked; they show under "All")
  var FILTERS = [{ key: "open", label: "Owed" }, { key: "booked", label: "Booked" }, { key: "used", label: "Used" }, { key: "all", label: "All" }];
  function isFilter(k) { return FILTERS.some(function (f) { return f.key === k; }); }

  var SOURCES = { absence: "Missed lesson", tutor_cancel: "Cancelled by tutor", holiday: "Holiday", manual: "Given by hand" };
  var STATUSES = { open: "Owed", booked: "Booked", used: "Used", expired: "Expired", revoked: "Taken back" };
  function sourceLabel(s) { return SOURCES[s] || "Credit"; }
  function statusLabel(s) { return STATUSES[s] || String(s || ""); }

  // "Missed Sat 21 Nov, 10:00 am · Tutor One (cancelled in time)"; a credit with no lesson behind it says why it was given
  function missedLine(r, today) {
    var m = r && r.missed;
    if (!m) return r && r.reason ? r.reason : sourceLabel(r && r.source);
    var mark = CA.mark ? CA.mark(m.attendance) : null;
    return "Missed " + TC.dateLabel(m.date, today) + ", " + TC.timeLabel(m.start_time) + (m.tutor_name ? " · " + m.tutor_name : "") +
           (mark && m.attendance ? " (" + String(mark.label || mark.short || "").toLowerCase() + ")" : "");
  }
  function makeupLine(r, today) {
    var k = r && r.makeup; if (!k) return "";
    return "Make-up " + TC.dateLabel(k.date, today) + ", " + TC.timeLabel(k.start_time) + (k.end_time ? " – " + TC.timeLabel(k.end_time) : "") + (k.tutor_name ? " · " + k.tutor_name : "");
  }
  function plural(n, a, b) { return n === 1 ? a : b; }
  // when the credit ends: "Never expires" / "Use by Fri 25 Dec" / "Last day today" / "Ended Thu 10 Dec"
  function expiryText(r, today) {
    if (!r || !r.expires_on) return r && r.status === "open" ? "Never expires" : "";
    if (r.status === "booked" || r.status === "used" || r.status === "revoked") return "";
    if (r.expires_on < today) return "Ended " + TC.dateLabel(r.expires_on, today);
    if (r.expires_on === today) return "Last day today";
    var left = Math.round((Date.parse(r.expires_on + "T00:00:00Z") - Date.parse(today + "T00:00:00Z")) / 86400000);
    return "Use by " + TC.dateLabel(r.expires_on, today) + " (" + left + " " + plural(left, "day", "days") + " left)";
  }
  // the small pill on a row: what state it is in
  function rowChip(r, today) {
    if (!r) return { text: "", kind: "muted" };
    if (r.status === "open") {
      if (r.expired_by_date) return { text: "Ended", kind: "warn" };
      if (r.expires_on && r.days_left != null && r.days_left <= 7) return { text: "Ends soon", kind: "warn" };
      return { text: "Owed", kind: "ok" };
    }
    if (r.status === "booked") return { text: "Booked", kind: "ok" };
    return { text: statusLabel(r.status), kind: "muted" };
  }
  // how the booked make-up is billed, in words (no amount)
  function billingText(b) { return b === "free" ? "Not billed" : b === "normal" ? "Billed at the normal price" : ""; }
  function priceRule(mode) {
    return mode === "if_missed_not_charged"
      ? "The make-up is billed at the normal price only if the missed lesson was not charged. If the missed lesson was charged, the make-up is free: the family never pays twice."
      : "The make-up is not billed: the missed lesson was already billed or waived.";
  }

  function badgeCount(res) { return res && res.counts ? Number(res.counts.open) || 0 : 0; }
  // the little chip on a student's sheet
  function chipText(counts) {
    var n = counts ? Number(counts.open) || 0 : 0, b = counts ? Number(counts.booked) || 0 : 0;
    if (!n && !b) return "";
    var s = n ? n + " make-up " + plural(n, "credit", "credits") + " owed" : "";
    if (b) s += (s ? " · " : "") + b + " booked";
    return s;
  }
  // should the tab show at all? Not when the centre never switched credits on and nothing was ever earned
  function showTab(res) {
    if (!res || !res.counts) return false;
    var c = res.counts, all = (Number(c.open) || 0) + (Number(c.booked) || 0) + (Number(c.used) || 0) + (Number(c.expired) || 0) + (Number(c.revoked) || 0);
    return res.enabled === true || all > 0;
  }

  // ---- the booking form: a day, a start and an end ("17:00"), checked before it is sent ----
  var TIME = /^([01]\d|2[0-3]):[0-5]\d$/, DAY = /^\d{4}-\d{2}-\d{2}$/;
  function minutes(t) { return Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5)); }
  function addMinutes(t, n) { var m = Math.min(1439, Math.max(0, minutes(t) + n)); return ("0" + Math.floor(m / 60)).slice(-2) + ":" + ("0" + (m % 60)).slice(-2); }
  // the start and end the form begins with: the missed lesson's start time and an hour long
  function bookingDefaults(r) {
    var st = r && r.missed && /^\d{2}:\d{2}/.test(r.missed.start_time || "") ? r.missed.start_time.slice(0, 5) : "16:00";
    return { start: st, end: addMinutes(st, 60) };
  }
  function checkBooking(f, today, r) {
    var d = String((f && f.date) || ""), s = String((f && f.start) || ""), e = String((f && f.end) || "");
    if (!DAY.test(d) || isNaN(Date.parse(d + "T00:00:00Z"))) return { ok: false, error: "Choose the day of the make-up lesson." };
    if (d < today) return { ok: false, error: "Choose today or a day coming up." };
    if (d > TC.addDays(today, 365)) return { ok: false, error: "Choose a day within the next year." };
    if (r && r.expires_on && d > r.expires_on) return { ok: false, error: "This credit can only be used up to " + TC.dateLabel(r.expires_on, today) + ". Choose an earlier day." };
    if (!TIME.test(s)) return { ok: false, error: "Choose the start time." };
    if (!TIME.test(e)) return { ok: false, error: "Choose the end time." };
    if (minutes(e) <= minutes(s)) return { ok: false, error: "The lesson must end after it starts." };
    return { ok: true, value: { date: d, start: s, end: e, tutor: (f && f.tutor) || null } };
  }
  // a reason kept on record (grant, take back, remove a make-up)
  function checkReason(text) {
    var t = String(text == null ? "" : text).trim();
    if (!t) return { ok: false, error: "Say why. It is kept on the centre’s record with your name." };
    if (t.length < REASON_MIN) return { ok: false, error: "Give a little more detail (at least " + REASON_MIN + " letters)." };
    if (t.length > REASON_MAX) return { ok: false, error: "Keep it under " + REASON_MAX + " letters." };
    return { ok: true, value: t };
  }

  function emptyText(filter, enabled) {
    if (filter === "open") return enabled === false
      ? { title: "Make-up credits are switched off", hint: "Turn them on in Centre settings, under how lessons are billed. Credits you already have stay here." }
      : { title: "No make-ups owed", hint: "When a lesson is missed in a way this centre credits, the family’s make-up shows here." };
    if (filter === "booked") return { title: "No make-ups booked", hint: "Book a make-up from the Owed list." };
    if (filter === "used") return { title: "Nothing used yet", hint: "A credit is used up when its make-up lesson is marked." };
    return { title: "No credits yet", hint: "Credits appear here as lessons are missed." };
  }

  function errorText(err) {
    var m = String(err && typeof err === "object" ? (err.message || "") : (err || ""));
    var map = [
      [/NOT_ALLOWED: at this centre only the owner/, "At this centre only the owner can do this."],
      [/NOT_ALLOWED/, "Your account can’t change make-up credits at this centre. Ask the centre owner."],
      [/NOT_ENABLED/, "Make-up credits are switched off at this centre. Turn them on in Centre settings."],
      [/NOT_FOUND/, "That credit isn’t available any more. The list has been refreshed."],
      [/REASON_REQUIRED/, "Say why. It is kept on record."],
      [/BAD_REASON/, "The reason must be 3 to 300 letters."],
      [/DUPLICATE: this credit/, "This credit was just given. Refresh the list."],
      [/DUPLICATE/, "This student already has a lesson at that time. Choose another time."],
      [/ALREADY_HAS_CREDIT/, "That lesson already has its credit."],
      [/IS_MAKEUP/, "A make-up lesson can’t earn another credit."],
      [/IN_USE/, "A make-up is already booked or taught with this credit, so it can’t be taken back. Remove the make-up first, if it isn’t marked yet."],
      [/NO_CHANGE/, "Someone has already done this. The list has been refreshed."],
      [/ALREADY_BOOKED/, "A make-up is already booked with this credit."],
      [/NOT_OPEN/, "This credit is no longer open."],
      [/EXPIRED/, "This credit has ended, so no make-up can be booked with it."],
      [/TOO_LATE/, "This credit can’t be used on a day after its last day. Choose an earlier day."],
      [/BAD_DATE/, "Choose today or a day within the next year."],
      [/BAD_TIME/, "Check the day and the times: the lesson must end after it starts."],
      [/ENDED/, "This student’s lessons end before that day."],
      [/NO_TEMPLATE/, "This student has no lesson to copy the subject and price from. Add one lesson first."],
      [/NOT_AVAILABLE/, "That tutor can’t be given lessons here."],
      [/CHARGE_PENDING/, "Confirm the charge for the missed lesson first (Attendance, Charges), so the family isn’t charged twice."],
      [/LOCKED/, "This make-up can’t be removed: it is paid or on an invoice."],
      [/BAD_FILTER|BAD_PAGE/, "That choice isn’t available. Refresh the page and try again."]
    ];
    for (var i = 0; i < map.length; i++) if (map[i][0].test(m)) return map[i][1];
    if (/Failed to fetch|NetworkError|network/i.test(m)) return "Couldn’t reach the server. Check your connection and try again.";
    return m || "Something went wrong.";
  }
  function isMissing(err) { return CA.isMissing(err); }
  function isNotAllowed(err) { return !!err && /NOT_ALLOWED/.test(err.message || ""); }
  // errors that mean "someone else got there first": the screen refreshes the list
  function isStale(err) { return !!err && /NOT_FOUND|NO_CHANGE|NOT_OPEN|ALREADY_BOOKED|IN_USE|DUPLICATE: this credit/.test(err.message || ""); }

  return { PAGE_SIZE: PAGE_SIZE, REASON_MAX: REASON_MAX, FILTERS: FILTERS, isFilter: isFilter, sourceLabel: sourceLabel, statusLabel: statusLabel,
           missedLine: missedLine, makeupLine: makeupLine, expiryText: expiryText, rowChip: rowChip, billingText: billingText, priceRule: priceRule,
           badgeCount: badgeCount, chipText: chipText, showTab: showTab, bookingDefaults: bookingDefaults, checkBooking: checkBooking, checkReason: checkReason,
           emptyText: emptyText, errorText: errorText, isMissing: isMissing, isNotAllowed: isNotAllowed, isStale: isStale, addMinutes: addMinutes };
});
