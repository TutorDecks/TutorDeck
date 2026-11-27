// Centre Tutor pay (T4 step S7) logic with no DOM and no network: the words for each rate and lesson state, what was typed in the rate / bonus / payment forms,
// the manual pay-list CSV, and the database's refusals in plain words. Used by assets/js/centre-tutor-pay.js and unit-tested in tests/centre-tutor-pay-core.test.js.
// The database decides everything that matters (db/migration_centre_tutor_pay.sql: which rate is in force, what a lesson earns, when it is released, who may see
// it); this file only saves a round trip and words the answers. Rates and pay are for the owner and staff with "Run tutor pay" ONLY: tutors never see them.
// All amounts are whole cents.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory(require("./money.js"), require("./centre-money-core.js"));
  else root.CentreTutorPayCore = factory(root.Money, root.CentreMoneyCore);
})(typeof self !== "undefined" ? self : this, function (Money, CM) {
  "use strict";
  var money = CM.money, plural = CM.plural, shortDate = CM.shortDate;
  var MAX = 100000000, REASON_MAX = 300;

  // ---- the methods ----
  var METHODS = [
    ["per_lesson", "Per lesson"], ["per_hour", "Per hour"], ["per_student_lesson", "Per student per lesson"],
    ["monthly_fixed", "Fixed amount each month"], ["percent_of_fee", "A percentage of the fee billed"],
    ["none", "Not paid for these lessons"], ["inherit", "Back to the usual rate"]
  ];
  var METHOD_WORD = { per_lesson: "per lesson", per_hour: "per hour", per_student_lesson: "per student per lesson", monthly_fixed: "a month" };
  // which methods a form may offer: the default rate has no "back to usual", an override has no monthly amount; classes only for centres that run them
  function methodsFor(scope, classType) {
    return METHODS.filter(function (m) {
      if (m[0] === "monthly_fixed" && scope !== "default") return false;
      if (m[0] === "inherit" && scope === "default") return false;
      if (m[0] === "per_student_lesson" && classType === "one_to_one") return false;
      return true;
    });
  }
  function methodLabel(m) { var f = METHODS.filter(function (x) { return x[0] === m; })[0]; return f ? f[1] : "Rate"; }
  function pctText(bp) { var s = (bp / 100).toFixed(2).replace(/\.?0+$/, ""); return s + "%"; }
  // "S$40.00 per lesson" / "60% of the fee" / "Not paid" ...
  function rateText(r) {
    if (!r) return "No rate";
    if (r.method === "percent_of_fee") return pctText(r.percent_bp) + " of the fee";
    if (r.method === "none") return "Not paid";
    if (r.method === "inherit") return "Back to the usual rate";
    return money(r.amount_cents) + " " + (METHOD_WORD[r.method] || "");
  }
  function scopeText(r) { return r.student_id ? "Student: " + (r.student_name || "a student") : r.level ? "Level: " + r.level : "Everything else"; }
  function scopeKind(r) { return r.student_id ? "student" : r.level ? "level" : "default"; }

  // ---- rates screen ----
  // the rate row in force today for the tutor's default scope
  function currentDefault(tutor) {
    var rows = (tutor && tutor.rates) || [];
    return rows.filter(function (r) { return !r.student_id && !r.level && r.in_force; })[0] || null;
  }
  function tutorSub(tutor, today) {
    var d = currentDefault(tutor), over = ((tutor && tutor.rates) || []).filter(function (r) { return (r.student_id || r.level) && r.in_force && r.method !== "inherit"; }).length;
    var parts = [d ? rateText(d) : "No rate yet"];
    if (over) parts.push(over + " " + plural(over, "special rate", "special rates"));
    var future = ((tutor && tutor.rates) || []).filter(function (r) { return today && r.effective_from > today; });
    if (future.length) parts.push("a change from " + shortDate(future[future.length - 1].effective_from));
    return parts.join(" · ");
  }
  function employmentText(e) { return e === "employee" ? "Employee" : e === "freelancer" ? "Freelancer" : ""; }
  function historyLine(r, today) {
    var when = r.effective_from > today ? "from " + shortDate(r.effective_from) + " (not started)" : "since " + shortDate(r.effective_from);
    return rateText(r) + " · " + when;
  }

  // what was typed in the "new rate" form → the arguments of centre_tutor_rate_set, or the problem in plain words.
  // o: { scope: "default"|"student"|"level", studentId, level, method, amountText, percentText, from, reason, today, classType }
  function checkRate(o) {
    var m = o.method, scope = o.scope || "default";
    if (!m) return { ok: false, error: "Pick how this tutor is paid." };
    if (methodsFor(scope, o.classType).every(function (x) { return x[0] !== m; })) return { ok: false, error: "That choice isn’t available for this kind of rate." };
    if (scope === "student" && !o.studentId) return { ok: false, error: "Pick the student this rate is for." };
    var lv = String(o.level == null ? "" : o.level).trim();
    if (scope === "level" && !lv) return { ok: false, error: "Type the level this rate is for, for example Sec 3." };
    if (scope === "level" && lv.length > 60) return { ok: false, error: "Keep the level name under 60 characters." };
    var amount = null, bp = null;
    if (m === "percent_of_fee") {
      var p = parsePercent(o.percentText);
      if (p == null) return { ok: false, error: "Type the percentage, for example 60 or 12.5." };
      if (p < 0 || p > 10000) return { ok: false, error: "The percentage must be between 0% and 100%." };
      bp = p;
    } else if (m !== "none" && m !== "inherit") {
      var c = Money.parse(o.amountText);
      if (c == null) return { ok: false, error: "Type the amount, for example 40 or 40.00." };
      if (c < 0) return { ok: false, error: "The amount can’t be negative." };
      if (c > MAX) return { ok: false, error: "That amount is too large to be right." };
      amount = c;
    }
    if (!o.from) return { ok: false, error: "Choose the date this rate starts." };
    var why = String(o.reason == null ? "" : o.reason).trim();
    if (!why) return { ok: false, error: "Say why, for example “Starting rate” or “Annual review”." };
    if (why.length > REASON_MAX) return { ok: false, error: "Keep the reason under " + REASON_MAX + " characters." };
    return { ok: true, args: { p_student: scope === "student" ? o.studentId : null, p_level: scope === "level" ? lv : null, p_method: m, p_amount_cents: amount, p_percent_bp: bp,
                               p_effective_from: o.from, p_reason: why },
             note: o.today && o.from < o.today ? "This rate starts in the past, so it also applies to lessons already taught from " + shortDate(o.from) + " that have not been paid yet." : "" };
  }
  // "60" / "12.5" / "7.25%" → basis points (12.5 → 1250); null if it isn't a plain percentage with at most two decimals
  function parsePercent(text) {
    var s = String(text == null ? "" : text).replace(/%|\s/g, "");
    var m = /^(\d{1,3})(?:\.(\d{0,2}))?$/.exec(s);
    if (!m) return null;
    return Number(m[1]) * 100 + Number(((m[2] || "") + "00").slice(0, 2));
  }

  // ---- the pay list ----
  // colour = meaning: teal = nothing to do / paid, amber = somebody has to act or wait, red = a problem, grey = nothing counts
  var STATE = {
    payable: { text: "Payable", tone: "ok", help: "The tutor has earned this and it can be paid now." },
    part: { text: "Part held", tone: "warn", help: "Part of this is released; the rest waits for the family to pay." },
    held: { text: "Held", tone: "warn", help: "Waiting for the family to pay. It rolls into the period when they do." },
    waiting_invoice: { text: "Not invoiced", tone: "warn", help: "The pay depends on what the family is billed, and the invoice isn’t issued yet." },
    waiting_charge: { text: "Charge not typed", tone: "warn", help: "A cancelled lesson whose charge hasn’t been entered yet, so the pay can’t be worked out." },
    no_rate: { text: "No rate", tone: "bad", help: "This tutor has no rate for these lessons. Set one under Rates." },
    zero: { text: "S$0.00", tone: "muted", help: "Nothing to pay for this lesson under the centre’s rules." },
    unpaid: { text: "Not paid", tone: "muted", help: "You chose not to pay this tutor for these lessons." },
    monthly: { text: "Fixed monthly", tone: "muted", help: "Covered by the tutor’s fixed monthly amount." }
  };
  function stateChip(s) { var x = STATE[s] || STATE.zero; return { text: x.text, tone: x.tone }; }
  function stateHelp(s) { return (STATE[s] || STATE.zero).help; }
  var PAY_STATE = { unpaid: { text: "To pay", tone: "warn" }, part_paid: { text: "Part paid", tone: "warn" }, paid: { text: "Paid", tone: "ok" }, nothing_due: { text: "Nothing due", tone: "muted" } };
  function payChip(t) { return PAY_STATE[t && t.pay_state] || PAY_STATE.nothing_due; }

  function hoursText(mins) {
    var h = Math.floor(mins / 60), m = mins % 60;
    return (h ? h + "h" : "") + (h && m ? " " : "") + (m || !h ? m + "m" : "");
  }
  function rowSub(t) {
    var p = [t.lessons + " " + plural(t.lessons, "lesson", "lessons")];
    if (t.minutes) p.push(hoursText(t.minutes));
    if (t.held_cents > 0) p.push(money(t.held_cents) + " held");
    if (t.carry_cents > 0) p.push(money(t.carry_cents) + " carried over");
    var w = (t.waiting_invoice || 0) + (t.waiting_charge || 0);
    if (w) p.push(w + " " + plural(w, "lesson", "lessons") + " waiting");
    if (t.no_rate) p.push(t.no_rate + " with no rate");
    return p.join(" · ");
  }
  function periodText(l) { return l ? shortDate(l.period_from) + " to " + shortDate(l.period_to) : ""; }
  function listSummary(l) {
    var t = (l && l.totals) || {};
    if (!l || !(l.tutors || []).length) return "No tutors yet.";
    return money(t.outstanding_cents || 0) + " to pay" + (t.held_cents > 0 ? " · " + money(t.held_cents) + " held until families pay" : "") + (t.paid_cents > 0 ? " · " + money(t.paid_cents) + " paid" : "");
  }
  // the lines of one tutor's sum: what the due amount is made of
  function dueRows(t) {
    var r = [];
    if (t.carry_cents) r.push(["Carried over from earlier", t.carry_cents]);
    r.push(["Lessons released this period", t.released_cents]);
    if (t.monthly_cents) r.push(["Fixed monthly amount", t.monthly_cents]);
    if (t.adjustments_cents) r.push(["Bonuses and deductions", t.adjustments_cents]);
    return r;
  }
  function lineSub(l) {
    var p = [shortDate(l.date), l.student || "Student", l.minutes + " min"];
    if (l.trial) p.push("trial");
    if (l.lesson_status === "cancelled") p.push("cancelled");
    return p.join(" · ");
  }
  function lineAmount(l) { return l.earn_cents == null ? "" : money(l.earn_cents); }
  function lineHeld(l) { return l.held_cents > 0 ? money(l.held_cents) + " held" : ""; }
  function unassignedNote(n) { return n > 0 ? n + " " + plural(n, "lesson was", "lessons were") + " taught with no tutor assigned, so nobody is paid for " + plural(n, "it", "them") + ". Assign a tutor in the Timetable." : ""; }
  function modeNote(mode, payableWhen) {
    if (mode === "report") return "This centre uses the lessons-taught report only. Switch Tutor pay to “Full pay calculation” in Centre settings to work out pay.";
    if (mode === "off") return "Tutor pay is switched off in Centre settings.";
    return payableWhen === "parent_paid" ? "Tutors are paid only after the family’s payment is received, so lessons not yet paid for show as held and roll into the period when the family pays."
                                          : "Tutors are paid for each lesson once it has been taught.";
  }

  // ---- bonus / deduction ----
  // o: { kind: "bonus"|"deduction", amountText, on, reason, today }
  function checkAdjustment(o) {
    var c = Money.parse(String(o.amountText == null ? "" : o.amountText).replace(/^-/, ""));
    if (c == null) return { ok: false, error: "Type the amount, for example 25 or 25.00." };
    if (c <= 0) return { ok: false, error: "The amount must be more than S$0.00." };
    if (c > MAX) return { ok: false, error: "That amount is too large to be right." };
    if (o.kind !== "bonus" && o.kind !== "deduction") return { ok: false, error: "Choose bonus or deduction." };
    if (!o.on) return { ok: false, error: "Choose the date this belongs to." };
    var why = String(o.reason == null ? "" : o.reason).trim();
    if (!why) return { ok: false, error: "Say why. The reason is kept in the record." };
    if (why.length > REASON_MAX) return { ok: false, error: "Keep the reason under " + REASON_MAX + " characters." };
    return { ok: true, args: { p_amount_cents: o.kind === "bonus" ? c : -c, p_on: o.on, p_reason: why } };
  }
  function adjustmentLine(a) { return (a.kind === "bonus" ? "Bonus" : "Deduction") + " · " + shortDate(a.effective_on) + " · " + a.reason; }

  // ---- recording a payment ----
  var PAY_METHODS = [["paynow", "PayNow"], ["bank", "Bank transfer"], ["cash", "Cash"], ["cheque", "Cheque"], ["other", "Other"]];
  var REF_DIGITS = /\d{8,}/;      // never keep a whole account or PayNow number (PDPA)
  // o: { amountText, outstanding, method, date, today, reference }
  function checkPayment(o) {
    var c = Money.parse(o.amountText);
    if (c == null) return { ok: false, error: "Type the amount, for example 120 or 120.00." };
    if (c <= 0) return { ok: false, error: "The amount must be more than S$0.00." };
    if (c > MAX) return { ok: false, error: "That amount is too large to be right." };
    if (c > o.outstanding) return { ok: false, error: "Only " + money(Math.max(o.outstanding, 0)) + " is still to pay for this period." };
    if (!o.method) return { ok: false, error: "Pick how you paid." };
    if (!o.date) return { ok: false, error: "Choose the day you paid." };
    if (o.today && o.date > o.today) return { ok: false, error: "The day paid can’t be in the future." };
    var ref = String(o.reference == null ? "" : o.reference).trim();
    if (ref.length > 100) return { ok: false, error: "Keep the reference under 100 characters." };
    if (REF_DIGITS.test(ref)) return { ok: false, error: "Don’t type a whole bank or PayNow number in the reference (it is kept in the record). The last 4 digits are enough." };
    return { ok: true, cents: c, ref: ref || null, part: c < o.outstanding,
             note: c < o.outstanding ? money(o.outstanding - c) + " will still be to pay." : "" };
  }
  function payQuestion(name, c, periodTxt) {
    return { title: "Record this payment?", message: "You paid " + name + " " + money(c.cents) + " for " + periodTxt + ". This is a record only: TutorDeck doesn’t send the money. A mistake is corrected with a reversal, never by editing.",
             confirmText: "Record payment" };
  }

  // ---- the manual pay list (CSV): who, how much, a reference. No bank details are kept in TutorDeck (the bank file comes later). ----
  function csvCell(v) {
    var s = String(v == null ? "" : v);
    if (/^[=+\-@\t\r]/.test(s)) s = "'" + s;                 // a spreadsheet must never run a typed value as a formula
    return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  }
  function amountCsv(c) { return Money.format(c, { symbol: false }).replace(/,/g, ""); }
  function refText(l) { return "Tutor pay " + CM.monthLabel(String(l.month || l.period_to).slice(0, 7) + "-01"); }
  // rows for everyone who is still owed something
  function csvRows(l) {
    return ((l && l.tutors) || []).filter(function (t) { return t.outstanding_cents > 0; }).map(function (t) {
      return [t.name, employmentText(t.employment_type), amountCsv(t.outstanding_cents), refText(l), periodText(l)];
    });
  }
  function buildCsv(l) {
    var head = ["Payee", "Employment", "Amount (S$)", "Reference", "Period"];
    return [head].concat(csvRows(l)).map(function (r) { return r.map(csvCell).join(","); }).join("\r\n") + "\r\n";
  }
  function csvTotal(l) { return ((l && l.tutors) || []).reduce(function (a, t) { return a + (t.outstanding_cents > 0 ? t.outstanding_cents : 0); }, 0); }
  function csvName(l) { return "tutor-pay-" + String(l.month || l.period_to).slice(0, 7) + ".csv"; }

  // ---- the lessons-taught report ----
  function reportSub(t) { return t.lessons + " " + plural(t.lessons, "lesson", "lessons") + " · " + hoursText(t.minutes) + " · " + t.students + " " + plural(t.students, "student", "students")
    + (t.cancelled ? " · " + t.cancelled + " cancelled" : "") + (t.trials ? " · " + t.trials + " " + plural(t.trials, "trial", "trials") : ""); }

  // ---- the database's refusals in plain words ----
  var CODED = /^(NOT_ALLOWED|REASON_REQUIRED|TOO_LONG|BAD_RATE|BAD_AMOUNT|BAD_DATE|BAD_METHOD|BAD_REFERENCE|TOO_MUCH|PERIOD_PAID|PAY_OFF|PAY_REPORT_ONLY|ADJUSTMENTS_OFF): ([\s\S]*)$/;
  function errorText(err) {
    var m = String((err && err.message) || err || "");
    var c = CODED.exec(m);
    if (c) return /^[a-z]/.test(c[2]) ? c[2].charAt(0).toUpperCase() + c[2].slice(1) : c[2];
    if (/REASON_REQUIRED/.test(m)) return "Please say why.";
    if (/PAY_OFF/.test(m)) return "Tutor pay is switched off in Centre settings.";
    if (/PAY_REPORT_ONLY/.test(m)) return "This centre uses the lessons-taught report only.";
    if (/NOT_ALLOWED/.test(m)) return "Your account can’t see or change tutor pay at this centre. It needs the “Run tutor pay” permission.";
    if (/NOT_FOUND/.test(m)) return "That isn’t available any more. Refresh the page and try again.";
    return CM.errorText(err);
  }
  function isMissing(err) { return CM.isMissing(err); }

  return { METHODS: METHODS, PAY_METHODS: PAY_METHODS, REASON_MAX: REASON_MAX, methodsFor: methodsFor, methodLabel: methodLabel, rateText: rateText, scopeText: scopeText, scopeKind: scopeKind,
           currentDefault: currentDefault, tutorSub: tutorSub, employmentText: employmentText, historyLine: historyLine, checkRate: checkRate, parsePercent: parsePercent, pctText: pctText,
           stateChip: stateChip, stateHelp: stateHelp, payChip: payChip, hoursText: hoursText, rowSub: rowSub, periodText: periodText, listSummary: listSummary, dueRows: dueRows,
           lineSub: lineSub, lineAmount: lineAmount, lineHeld: lineHeld, unassignedNote: unassignedNote, modeNote: modeNote, checkAdjustment: checkAdjustment, adjustmentLine: adjustmentLine,
           checkPayment: checkPayment, payQuestion: payQuestion, csvCell: csvCell, amountCsv: amountCsv, csvRows: csvRows, buildCsv: buildCsv, csvTotal: csvTotal, csvName: csvName,
           reportSub: reportSub, errorText: errorText, isMissing: isMissing };
});
