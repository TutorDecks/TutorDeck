// Centre "Add past lessons" (T3.10): the form's logic and wording with no DOM and no network.
// Used by assets/js/centre-past-lessons.js (the sheet on the Timetable and on a student's sheet) and unit-tested in tests/centre-past-lessons-core.test.js.
// The database decides everything that matters (db/migration_past_lessons.sql: who may, how far back, clashes, holidays, closed fee months, the reason);
// this file only saves a round trip (the same checks, so a typing mistake is caught before the call) and says the answers in plain language.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory(require("./centre-slots-core.js"));
  else root.CentrePastCore = factory(root.CentreSlotsCore);
})(typeof self !== "undefined" ? self : this, function (SC) {
  "use strict";
  var MAX_ITEMS = 62, MAX_RATE = 1000, MAX_REASON = 500;

  function plural(n, one, many) { return n + " " + (n === 1 ? one : many); }
  function money(cents) { var c = Math.round(Number(cents) || 0); return "S$" + (c / 100).toFixed(2); }
  function hm(t) { return t ? String(t).slice(0, 5) : ""; }
  function toMin(t) { var p = hm(t).split(":"); return p.length === 2 ? (+p[0]) * 60 + (+p[1]) : NaN; }

  // ---- the answers the database gives when it refuses a whole call ----
  function errorText(err) {
    var m = String((err && err.message) || err || "");
    var map = [
      [/BACKFILL_OFF/, "This centre hasn’t switched on adding past lessons. The owner can do it in Centre settings, under Lessons."],
      [/NOT_ALLOWED: only the centre owner/, "Only the centre owner can add lessons to a month whose fee is already closed."],
      [/REASON_REQUIRED/, "Say why these lessons are being added now."],
      [/REMARKS_REQUIRED/, "This centre needs remarks before a lesson is marked attended. Type them, or leave attended unticked."],
      [/BAD_TUTOR/, "Pick the tutor who taught these lessons."],
      [/NOT_AVAILABLE/, "That person can’t be given lessons here. Pick someone else."],
      [/BAD_ITEMS: add at most/, "Add at most " + MAX_ITEMS + " lessons at a time."],
      [/BAD_ITEMS/, "Pick at least one lesson."],
      [/BAD_RANGE/, "Pick a range of at most 62 days."],
      [/REFUSED: (\d+) of these lessons can.t be added, so none were\. First problem: (.*)$/, null],
      [/TOO_LONG: keep the reason/, "Keep the reason under 500 characters."],
      [/TOO_LONG/, "That is too long."]
    ];
    for (var i = 0; i < map.length; i++) {
      var x = map[i][0].exec(m); if (!x) continue;
      if (map[i][1]) return map[i][1];
      var n = +x[1];
      return (n === 1 ? "One lesson can’t be added" : n + " lessons can’t be added") + ", so none were. " + x[2];
    }
    return SC.errorText(err);
  }

  // ---- the form ----
  // f = { tutor, reason, start, end, rate, subject, dates: [iso…] (typed dates), items: [...] (from the weekly pattern), mode: "dates" | "pattern" }
  // o = the answer of staff_past_lessons_options.  → { field: message }
  function validate(f, o) {
    var e = {}, today = o && o.today, earliest = o && o.earliest;
    if (!f.tutor) e.tutor = "Pick the tutor who taught these lessons.";
    var items = buildItems(f);
    if (!items.length) e.dates = f.mode === "pattern" ? "No lessons in that range. Pick other dates, or type the days yourself." : "Add at least one day.";
    if (items.length > MAX_ITEMS) e.dates = "Add at most " + MAX_ITEMS + " lessons at a time.";
    var rd = String(f.rate == null ? "" : f.rate).trim();
    if (rd !== "" && (!/^\d{1,4}(\.\d{1,2})?$/.test(rd) || Number(rd) > MAX_RATE)) e.rate = "The price per hour must be between 0 and " + MAX_RATE + ".";
    if (f.mode !== "pattern") {
      var m = toMin(f.end) - toMin(f.start);
      if (!f.start) e.start = "Give a start time.";
      else if (!f.end) e.end = "Give an end time.";
      else if (!(m > 0)) e.end = "The lesson must end after it starts.";
      else if (m < 15 || m > 480) e.end = "A lesson lasts 15 minutes to 8 hours.";
    }
    (f.dates || []).forEach(function (d) {
      if (!e.dates && today && d >= today) e.dates = "Only days before today can be added here.";
      else if (!e.dates && earliest && d < earliest) e.dates = "The earliest day you can add is " + SC.dateText(earliest) + ".";
    });
    if (String(f.subject || "").trim().length > 60) e.subject = "The subject is too long (60 characters at most).";
    var why = String(f.reason || "").trim();
    if (!why) e.reason = "Say why these lessons are being added now.";
    else if (why.length > MAX_REASON) e.reason = "Keep the reason under " + MAX_REASON + " characters.";
    return e;
  }
  // the list sent to the database: typed days share one time, price and subject; pattern items keep their own (the price can be overridden for all)
  function buildItems(f) {
    var rate = String(f.rate == null ? "" : f.rate).trim(), subj = String(f.subject || "").trim();
    if (f.mode === "pattern") {
      return (f.items || []).map(function (it) {
        var o = { date: it.date, start: hm(it.start), end: hm(it.end) };
        if (rate !== "") o.rate = rate; else if (it.rate != null) o.rate = String(it.rate);
        if (subj) o.subject = subj; else if (it.subject) o.subject = it.subject;
        return o;
      });
    }
    var seen = {}, out = [];
    (f.dates || []).slice().sort().forEach(function (d) {
      if (!d || seen[d]) return; seen[d] = 1;
      var o = { date: d, start: hm(f.start), end: hm(f.end) }; if (rate !== "") o.rate = rate; if (subj) o.subject = subj; out.push(o);
    });
    return out;
  }
  function previewArgs(orgId, studentId, f, flags) {
    flags = flags || {};
    return { p_org: orgId, p_student: studentId, p_tutor: f.tutor || null, p_items: buildItems(f), p_confirm_holidays: !!flags.holiday, p_allow_closed_month: !!flags.closed };
  }
  function addArgs(orgId, studentId, f, flags) {
    flags = flags || {};
    return { p_org: orgId, p_student: studentId, p_tutor: f.tutor || null, p_items: buildItems(f), p_reason: String(f.reason || "").trim(),
             p_mark_attended: !!f.attended, p_remarks: f.attended && String(f.remarks || "").trim() ? String(f.remarks).trim() : null,
             p_confirm_holidays: !!flags.holiday, p_allow_closed_month: !!flags.closed };
  }

  // ---- the preview ----
  // one row → { title, time, price, tone: "new" | "there" | "bad", note }
  function rowView(r) {
    var tone = r.state === "new" ? "new" : r.state === "there" ? "there" : "bad";
    var note = r.state === "new" ? (r.holiday ? "On a centre holiday" : "") + (r.holiday && r.fee_month_closed ? " · " : "") + (r.fee_month_closed ? "Fee month already closed" : "") : (r.message || "");
    return { title: r.date ? SC.dateText(r.date) : "", time: r.start ? SC.timeLabel(r.start) + "–" + SC.timeLabel(r.end) : "", price: r.amount_cents != null ? money(r.amount_cents) : "", tone: tone, note: note };
  }
  function summary(p) {
    if (!p) return "";
    var parts = [plural(p.new, "new lesson", "new lessons") + (p.new ? " · " + money(p.total_cents) : "")];
    if (p.there) parts.push(plural(p.there, "already on the timetable", "already on the timetable"));
    if (p.refused) parts.push(plural(p.refused, "can’t be added", "can’t be added"));
    return parts.join(" · ");
  }
  // which confirmations the preview is asking for
  function needs(p) {
    var rows = (p && p.rows) || [];
    return { holiday: rows.some(function (r) { return r.code === "HOLIDAY"; }), closed: rows.some(function (r) { return r.code === "FEE_MONTH_CLOSED"; }) };
  }
  // can the Add button work? p = a preview, e = validate(), flags = { holiday, closed } as confirmed so far
  function canAdd(p, e, flags) {
    if (!p || Object.keys(e || {}).length) return false;
    if (p.refused > 0) return false;
    if (needs(p).holiday && !(flags && flags.holiday)) return false;
    return p.new > 0;
  }
  function doneText(res, attended, fmtMonth) {
    var n = res.created, s = plural(n, "lesson", "lessons") + " added" + (res.attended ? " and marked attended" : "") + ".";
    if (res.skipped) s += " " + plural(res.skipped, "was", "were") + " already there.";
    if (res.fee_month_closed) s += " That fee month was already closed, so its fee has not changed.";
    var im = (res.invoiced_months || []);
    if (im.length) s += " " + (im.length === 1 ? "That month already has an invoice for this family" : "Some of those months already have an invoice") + ": the new lessons go on the next one.";
    else if (res.attended) s += " They will be on the next invoice run.";
    else s += " Mark them attended to bill them.";
    return s;
  }
  // the weekly-pattern range the form starts with: the last 7 days, never earlier than the first day allowed
  function defaultRange(today, earliest) {
    var to = SC.addDays(today, -1), from = SC.addDays(today, -7); if (earliest && from < earliest) from = earliest;
    return { from: from, to: to };
  }
  function tutorName(opts, id) { var t = ((opts && opts.tutors) || []).filter(function (x) { return x.id === id; })[0]; return t ? t.name : ""; }

  return { MAX_ITEMS: MAX_ITEMS, errorText: errorText, validate: validate, buildItems: buildItems, previewArgs: previewArgs, addArgs: addArgs, rowView: rowView,
           summary: summary, needs: needs, canAdd: canAdd, doneText: doneText, defaultRange: defaultRange, tutorName: tutorName, money: money };
});
