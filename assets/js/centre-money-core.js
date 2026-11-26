// Centre Money > Invoice run page logic with no DOM and no network (T4 step S2): which month, how the preview is worded, the one next step,
// and what the database's refusals mean in plain words.
// Used by assets/js/centre-money.js and unit-tested in tests/centre-money-core.test.js. The database decides everything that matters
// (db/migration_centre_invoice_run.sql: centre_invoice_run_preview / _create_drafts / centre_invoice_approve / _approve_all); this file only saves
// a round trip and words the answers. All amounts are whole cents (assets/js/money.js formats them).
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory(require("./money.js"));
  else root.CentreMoneyCore = factory(root.Money);
})(typeof self !== "undefined" ? self : this, function (Money) {
  "use strict";
  var MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

  function plural(n, a, b) { return n === 1 ? a : b; }
  function money(c) { return Money.format(c); }

  // ---- months (YYYY-MM-01 strings; no time zones involved) ----
  function validMonth(s) { return typeof s === "string" && /^\d{4}-(0[1-9]|1[0-2])(-\d{2})?$/.test(s); }
  function monthStart(s) { return s.slice(0, 7) + "-01"; }
  function shiftMonth(s, n) {
    var y = +s.slice(0, 4), m = +s.slice(5, 7) - 1 + n;
    y += Math.floor(m / 12); m = ((m % 12) + 12) % 12;
    return y + "-" + (m < 9 ? "0" : "") + (m + 1) + "-01";
  }
  function monthLabel(s) { return MONTHS[+s.slice(5, 7) - 1] + " " + s.slice(0, 4); }
  // The month people usually invoice: the month that just ended for postpaid lessons; the coming month for a fixed fee billed in advance.
  function defaultMonth(todayISO, model) { return shiftMonth(monthStart(todayISO), model === "fixed_in_advance" ? 1 : -1); }
  function toQuery(orgId, month) { return "id=" + encodeURIComponent(orgId) + (month ? "&month=" + month.slice(0, 7) : ""); }
  function fromQuery(search) {
    var q = new URLSearchParams(search || ""), m = q.get("month");
    return { month: m && validMonth(m) ? monthStart(m) : null };
  }

  // ---- the model, in words ----
  var MODEL_LABEL = { postpaid_lessons: "Postpaid lessons", fixed_in_advance: "Fixed monthly fee", prepaid_packages: "Prepaid packages", pay_per_lesson: "Pay per lesson" };
  function modelLabel(p) { return MODEL_LABEL[p && p.model] || "Billing"; }
  function groupingLabel(p) { return p && p.grouping === "student" ? "One invoice per student" : "One invoice per family"; }
  function unitWord(p, n) { return p && p.grouping === "student" ? plural(n, "student", "students") : plural(n, "family", "families"); }

  // ---- the numbers line under the title ----
  function summaryText(p) {
    if (!p || !p.built) return "";
    var t = p.totals || {}, parts = [];
    parts.push(t.ready + " " + plural(t.ready, "invoice", "invoices") + " ready");
    if (t.held_back) parts.push(t.held_back + " held back");
    if (t.drafts) parts.push(t.drafts + " " + plural(t.drafts, "draft", "drafts") + " waiting for approval");
    return parts.join(" · ");
  }
  function totalText(p) {
    var t = (p && p.totals) || {};
    if (!t.ready) return "";
    return money(t.total_cents) + (t.gst_cents ? " including " + money(t.gst_cents) + " GST" : "");
  }

  // ---- the one next step ----
  // invoices: the month's list rows (drafts and issued). One primary action: create what is ready, otherwise approve what is waiting.
  function nextStep(p, invoices) {
    if (!p || !p.built) return { kind: null };
    var ready = (p.totals && p.totals.ready) || 0, drafts = (invoices || []).filter(function (i) { return i.status === "draft"; }).length;
    var issueNow = p.review_before_sending === false;
    var deps = (p.totals && p.totals.deposits) || 0, withDeps = deps > 0 ? " and " + deps + " " + plural(deps, "deposit", "deposits") : "";
    if (ready > 0) return { kind: "create", count: ready, label: (issueNow ? "Create and issue " : "Create ") + ready + " " + plural(ready, issueNow ? "invoice" : "draft", issueNow ? "invoices" : "drafts") + withDeps };
    if (drafts > 0) return { kind: "approve", count: drafts, label: "Approve " + (drafts === 1 ? "the draft" : "all " + drafts + " drafts") };
    return { kind: null };
  }
  // the second button when a create step is the primary one but drafts also exist
  function secondStep(p, invoices) {
    var n = nextStep(p, invoices), drafts = (invoices || []).filter(function (i) { return i.status === "draft"; }).length;
    if (n.kind === "create" && drafts > 0) return { kind: "approve", count: drafts, label: "Approve " + (drafts === 1 ? "the draft" : "all " + drafts + " drafts") };
    return { kind: null };
  }
  function approveQuestion(count, total) {
    return { title: "Issue " + count + " " + plural(count, "invoice", "invoices") + "?",
             message: "Each one gets its number now" + (total ? " (" + money(total) + " in all)" : "") + " and can’t be changed afterwards. A mistake is corrected with a credit note." };
  }

  // ---- what happened ----
  function createdText(r) {
    var parts = [];
    if (r.created) parts.push(r.created + " " + plural(r.created, "draft", "drafts") + " created" + (r.issued ? " and issued" : ""));
    else parts.push("Nothing new to create");
    if (r.deposits) parts.push(r.deposits + " refundable " + plural(r.deposits, "deposit", "deposits") + (r.deposits_issued ? " issued" : " drafted"));
    if (r.already_drafted) parts.push(r.already_drafted + " already " + plural(r.already_drafted, "has a draft", "have drafts"));
    if (r.held_back) parts.push(r.held_back + " held back until " + plural(r.held_back, "its charge is", "their charges are") + " set");
    return parts.join(". ") + ".";
  }
  function approvedText(r) {
    if (r.issued != null) return r.issued + " " + plural(r.issued, "invoice", "invoices") + " issued (" + r.first_number + (r.last_number !== r.first_number ? " to " + r.last_number : "") + ")" +
      (r.deposits ? ", " + r.deposits + " of them " + plural(r.deposits, "a refundable deposit", "refundable deposits") : "") + ".";
    return "Invoice " + r.number + " issued.";
  }

  // ---- one invoice's lines, grouped by child ----
  function groupLines(lines) {
    var out = [], idx = {};
    (lines || []).forEach(function (l) {
      var k = l.student_name || "";
      if (!(k in idx)) { idx[k] = out.length; out.push({ student: k, lines: [] }); }
      out[idx[k]].lines.push(l);
    });
    return out;
  }
  function qtyText(l) { return l.qty > 1 ? l.qty + " × " + money(l.unit_cents) : ""; }
  function lineAmount(l) { return l.line_cents != null ? l.line_cents : l.qty * l.unit_cents; }

  // ---- invoice rows ----
  function chip(inv) {
    if (inv.status === "draft") return { text: "Draft", tone: "muted" };
    if (inv.status === "issued") return { text: "Issued", tone: "ok" };
    return { text: "Discarded", tone: "muted" };
  }
  function shortDate(iso) {
    if (!iso) return "";
    var d = new Date(iso + "T00:00:00Z");
    return d.getUTCDate() + " " + MONTHS[d.getUTCMonth()].slice(0, 3) + " " + d.getUTCFullYear();
  }
  function invoiceSub(inv) {
    if (inv.status === "issued") return "Issued " + shortDate(inv.issue_date) + " · due " + shortDate(inv.due_date);
    if (inv.status === "void") return "Discarded draft";
    return inv.lines + " " + plural(inv.lines, "line", "lines");
  }
  function heldNote(h) {
    var n = (h.reasons || []).reduce(function (a, r) { return a + (r.lessons || 0); }, 0);
    return n + " " + plural(n, "charge", "charges") + " to set in Charges";
  }
  function notMarkedNote(n) { return n ? n + " " + plural(n, "lesson isn’t", "lessons aren’t") + " marked yet and " + plural(n, "is", "are") + " left off" : ""; }

  // ---- numbering ----
  function numberingText(nb) {
    if (!nb) return "";
    return nb.locked ? "Next invoice number: " + nb.next_text : "First invoice number will be " + nb.next_text;
  }
  function parseOpening(text) {
    var s = String(text == null ? "" : text).trim();
    if (!/^\d{1,9}$/.test(s) || +s < 1) return null;
    return +s;
  }

  // ---- refusals in plain words ----
  function errorText(err) {
    var m = String((err && err.message) || err || "");
    var map = [
      [/NOT_BUILT: (.*)/, null],
      [/BAD_PERIOD/, "Choose a month from the last three years up to two months ahead."],
      [/NOT_DRAFT/, "That invoice was already approved or discarded. Refresh the page."],
      [/NOTHING_TO_APPROVE/, "There are no drafts to approve for this month."],
      [/REASON_REQUIRED/, "Please say why."],
      [/NOT_ALLOWED: numbers have already been issued/, "Invoices have already been issued, so the first number can’t be changed any more."],
      [/NOT_ALLOWED/, "Your account can’t prepare or issue invoices at this centre."],
      [/NOT_FOUND/, "That isn’t available any more. Refresh the page and try again."],
      [/A document needs at least one line/, "That invoice has no lines, so it can’t be issued."],
      [/already billed/, "One of those lessons was just invoiced by someone else. Refresh the page."],
      [/JWT|expired|not authenticated/i, "Your session ended. Sign in again."],
      [/Failed to fetch|NetworkError|network/i, "Couldn’t reach the server. Check your connection and try again."]
    ];
    for (var i = 0; i < map.length; i++) {
      var r = map[i][0].exec(m);
      if (r) return map[i][1] === null ? r[1] : map[i][1];
    }
    return "Something went wrong. Refresh the page and try again.";
  }
  function isMissing(err) { return !!err && (err.code === "42883" || err.code === "PGRST202" || /does not exist|Could not find the function/i.test(err.message || "")); }

  return { MONTHS: MONTHS, plural: plural, money: money, validMonth: validMonth, monthStart: monthStart, shiftMonth: shiftMonth, monthLabel: monthLabel,
           defaultMonth: defaultMonth, toQuery: toQuery, fromQuery: fromQuery, modelLabel: modelLabel, groupingLabel: groupingLabel, unitWord: unitWord,
           summaryText: summaryText, totalText: totalText, nextStep: nextStep, secondStep: secondStep, approveQuestion: approveQuestion, createdText: createdText,
           approvedText: approvedText, groupLines: groupLines, qtyText: qtyText, lineAmount: lineAmount, chip: chip, shortDate: shortDate, invoiceSub: invoiceSub,
           heldNote: heldNote, notMarkedNote: notMarkedNote, numberingText: numberingText, parseOpening: parseOpening, errorText: errorText, isMissing: isMissing };
});
