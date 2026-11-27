// A tutor's OWN pay, with no DOM and no network: how the figures from the four database functions (tutor_my_pay_modes, tutor_my_pay,
// tutor_my_pay_month, tutor_my_pay_adjustments) are worded, and how a tutor who has students of their own AND teaches at a centre can combine the
// two on the Dashboard. Used by assets/js/tutor.js, my-pay.js, settings.js, dashboard.js and app.js; unit-tested in tests/tutor-pay-core.test.js.
//
// Rules this file keeps (owner's decision, 2026-11-27):
//  * a tutor sees only their OWN pay: never the family's fee, the rate, the percentage, the invoice, another tutor's pay, or whether a family paid;
//  * a held lesson is "Pending": no amount, no reason; once released it shows the amount; everything is an estimate until the pay run is confirmed;
//  * centre pay NEVER enters the solo ledger, invoices, unpaid tracking, reminders or exports: combine() only builds numbers to DISPLAY, it returns
//    new objects and touches nothing it is given;
//  * pending centre pay is NOT in the combined total; it is its own separate line.
// The database is the authority on who may see what; this only words it.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.TutorPayCore = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  var VIEWS = ["off", "monthly_total", "per_lesson_and_total"];
  var MO = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
  var MS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

  function int(n) { var v = Math.round(Number(n)); return isFinite(v) ? v : 0; }
  // 123456 → "S$1,234.56"; negative → "−S$5.00" (a real minus sign)
  function sgd(cents) {
    var c = int(cents), neg = c < 0; c = Math.abs(c);
    var d = Math.floor(c / 100), r = c % 100;
    return (neg ? "−" : "") + "S$" + String(d).replace(/\B(?=(\d{3})+(?!\d))/g, ",") + "." + (r < 10 ? "0" : "") + r;
  }
  // "+S$15.00" / "−S$5.00" (for bonus and deduction lines)
  function signed(cents) { var c = int(cents); return (c > 0 ? "+" : "") + sgd(c); }
  // dollars (a float from the solo ledger) → whole cents, without float drift
  function toCents(dollars) { return int(Number(dollars) * 100); }

  // "2026-11-01" → "November 2026"; and a pay period "1 Nov – 30 Nov"
  function monthLabel(iso) { var m = /^(\d{4})-(\d{2})/.exec(String(iso || "")); return m ? MO[Number(m[2]) - 1] + " " + m[1] : ""; }
  function dayLabel(iso) { var m = /^\d{4}-(\d{2})-(\d{2})/.exec(String(iso || "")); return m ? Number(m[2]) + " " + MS[Number(m[1]) - 1] : ""; }
  function periodLabel(from, to) { return dayLabel(from) + " – " + dayLabel(to); }
  function addMonths(iso, n) {
    var m = /^(\d{4})-(\d{2})/.exec(iso); var y = Number(m[1]), mo = Number(m[2]) - 1 + n;
    y += Math.floor(mo / 12); mo = ((mo % 12) + 12) % 12;
    return y + "-" + (mo + 1 < 10 ? "0" : "") + (mo + 1) + "-01";
  }

  // What does this tutor's list of centres allow? modes = rows of tutor_my_pay_modes ({org_id, org_name, pay_view}).
  // Never throws on odd input: an unknown value counts as "off" (so a doubt hides pay, never shows it).
  function viewOf(row) { return row && VIEWS.indexOf(row.pay_view) > 0 ? row.pay_view : "off"; }
  function anyOn(modes) { return (modes || []).some(function (r) { return viewOf(r) !== "off"; }); }
  function anyPerLesson(modes) { return (modes || []).some(function (r) { return viewOf(r) === "per_lesson_and_total"; }); }

  // The "Your pay" word for one lesson (a row of tutor_my_pay), or null when there is nothing to say.
  function lessonPay(row) {
    if (!row) return null;
    if (row.pay_state === "pending") return { text: "Pending", tone: "pending", pending: true };
    if (row.pay_state === "amount" && row.pay_cents != null) return { text: sgd(row.pay_cents), tone: "amount", pending: false, cents: int(row.pay_cents) };
    return null;
  }
  // rows of tutor_my_pay → { lessonId: row }
  function byLesson(rows) { var o = {}; (rows || []).forEach(function (r) { if (r && r.lesson_id) o[r.lesson_id] = r; }); return o; }

  // The summary line under My lessons: one entry per centre (rows of tutor_my_pay_month).
  function summaryLines(monthRows) {
    return (monthRows || []).map(function (r) {
      return { org: r.org_name, total: sgd(r.total_cents), cents: int(r.total_cents), pending: int(r.pending_lessons), final: !!r.run_recorded,
               period: periodLabel(r.period_from, r.period_to) };
    });
  }
  function pendingWord(n) { return n + " lesson" + (n === 1 ? "" : "s") + " pending"; }
  function estimateNote(final) { return final ? "Pay run confirmed" : "Estimate until the pay run is confirmed"; }

  // The monthly page for one centre: the lines in the order a person reads them, and what to say under them.
  // line: { label, cents, text, kind } kind: earned | carry | bonus | deduction | total
  function monthLines(monthRow, adjRows) {
    var r = monthRow || {}, out = [];
    out.push({ label: "Earned this period", cents: int(r.earned_cents), text: sgd(r.earned_cents), kind: "earned" });
    (adjRows || []).forEach(function (a) {
      var c = int(a.adjustment_cents);
      out.push({ label: String(a.label || (c < 0 ? "Deduction" : "Bonus")), cents: c, text: signed(c), kind: c < 0 ? "deduction" : "bonus", date: a.effective_on });
    });
    if (int(r.carry_cents) !== 0) out.push({ label: "Carried over from earlier", cents: int(r.carry_cents), text: sgd(r.carry_cents), kind: "carry" });
    // a total that does not equal the lines (it should) is shown as the database says; the lines are never "fixed up" here
    out.push({ label: "Total", cents: int(r.total_cents), text: sgd(r.total_cents), kind: "total" });
    return out;
  }

  // ---------------------------------------------------------------- combine (both-role tutors)
  // The preference lives in the tutor's own settings. It can only be ON when the tutor teaches at a centre (there is a mode row) AND at least one
  // of those centres lets tutors see their pay. Returns { shown, enabled, reason }:
  //   shown   = show the tick box at all (only tutors who teach at a centre)
  //   enabled = the tick box can be used; otherwise `reason` says why in plain words
  function combineAvailability(modes) {
    var list = modes || [];
    if (!list.length) return { shown: false, enabled: false, reason: "" };
    if (!anyOn(list)) {
      return { shown: true, enabled: false, reason: list.length === 1
        ? list[0].org_name + " doesn’t show tutors their own pay, so there is nothing to add."
        : "None of your centres shows tutors their own pay, so there is nothing to add." };
    }
    return { shown: true, enabled: true, reason: "" };
  }
  // Is the Dashboard to show the combined lines? pref = the stored tick ("1"/"0"/null), modes as above.
  function combineOn(pref, modes) { return String(pref) === "1" && combineAvailability(modes).enabled; }

  // Builds the Dashboard's combined lines. soloCents = what the tutor's own students gave this month (the Dashboard's own figure, whole cents);
  // monthRows = rows of tutor_my_pay_month for that month. Centres that don't show pay are not in monthRows at all.
  // Pending centre lessons are counted and shown on their own line, never added. Returns NEW objects; nothing passed in is changed.
  function combine(soloCents, monthRows) {
    var centres = (monthRows || []).map(function (r) {
      return { name: r.org_name, label: "At " + r.org_name, cents: int(r.total_cents), text: sgd(r.total_cents), pending: int(r.pending_lessons), final: !!r.run_recorded,
               period: periodLabel(r.period_from, r.period_to) };
    });
    var mine = int(soloCents), sum = centres.reduce(function (t, c) { return t + c.cents; }, 0), pend = centres.reduce(function (t, c) { return t + c.pending; }, 0);
    return {
      mine: { label: "My students", cents: mine, text: sgd(mine) },
      centres: centres,
      total: { label: "Combined", cents: mine + sum, text: sgd(mine + sum) },
      pending: pend, pendingText: pend ? pendingWord(pend) : "",
      allFinal: centres.length > 0 && centres.every(function (c) { return c.final; }),
      note: centres.length && centres.every(function (c) { return c.final; }) ? "Centre pay: pay run confirmed." : "Centre pay is an estimate until the pay run is confirmed."
    };
  }

  // The database's refusals start with a code; say it kindly. Pay is a bonus on these screens, so a failure is quiet: the page just doesn't show it.
  var ERRORS = {
    NOT_FOUND: "Your pay isn’t available here.",
    BAD_RANGE: "Something went wrong loading your pay. Please try again."
  };
  function errorText(err) {
    var m = /^([A-Z_]+)(?::|$)/.exec(String((err && err.message) || ""));
    return (m && ERRORS[m[1]]) || "Your pay isn’t available right now. Please try again in a few minutes.";
  }

  return { VIEWS: VIEWS, sgd: sgd, signed: signed, toCents: toCents, monthLabel: monthLabel, dayLabel: dayLabel, periodLabel: periodLabel, addMonths: addMonths,
           viewOf: viewOf, anyOn: anyOn, anyPerLesson: anyPerLesson, lessonPay: lessonPay, byLesson: byLesson, summaryLines: summaryLines, pendingWord: pendingWord,
           estimateNote: estimateNote, monthLines: monthLines, combineAvailability: combineAvailability, combineOn: combineOn, combine: combine, errorText: errorText };
});
