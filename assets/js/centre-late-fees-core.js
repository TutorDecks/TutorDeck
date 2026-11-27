// Centre Money > Late fees (T4 step S6) logic with no DOM and no network: the words for each waiting fee, the summary line, the "waive" form check, the
// questions asked before approving, and the database's refusals in plain words. Used by assets/js/centre-late-fees.js and unit-tested in
// tests/centre-late-fees-core.test.js. The database decides everything that matters (db/migration_centre_late_fees.sql: when a fee falls due, how much, the cap,
// who may approve or waive, never twice); this file only words the answers. All amounts are whole cents.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory(require("./centre-money-core.js"));
  else root.CentreLateFeesCore = factory(root.CentreMoneyCore);
})(typeof self !== "undefined" ? self : this, function (CM) {
  "use strict";
  var money = CM.money, plural = CM.plural, shortDate = CM.shortDate;
  var REASON_MAX = 300;

  // ---- the list ----
  function title(w) { return (w.invoice_number || "Invoice") + " · " + (w.name || "Family"); }
  // "Due 7 Nov 2026 · 20 days overdue · month 2" (short: it has to fit a phone)
  function rowSub(w) {
    var bits = ["Due " + shortDate(w.invoice_due_date)];
    if (w.days_late > 0) bits.push(w.days_late + " " + plural(w.days_late, "day", "days") + " overdue");
    if (w.repeat === "monthly") bits.push("month " + w.month_no);
    return bits.join(" · ");
  }
  // how the amount was worked out, in one line
  function basisText(w) {
    if (w.type === "percent" && w.base_cents != null) return "A percentage of the " + money(w.base_cents) + " still unpaid on " + shortDate(w.fee_date) + ".";
    return "A fixed amount set by the centre.";
  }
  // "S$10.00 + S$0.90 GST = S$10.90" when there is GST, else "S$10.00"
  function amountLine(w) {
    if (w.gst_cents > 0) return money(w.fee_cents) + " + " + money(w.gst_cents) + " GST = " + money(w.total_cents);
    return money(w.fee_cents);
  }
  function summary(list) {
    var n = (list && list.waiting_count) || 0;
    if (!n) return "No late fees waiting.";
    return n + " late " + plural(n, "fee", "fees") + " waiting · " + money(list.waiting_cents || 0);
  }
  // what to say when nothing is waiting
  function emptyText(list) {
    if (list && list.note && !list.enabled) return list.note;
    return "Nothing waiting. When an invoice is still unpaid the day after its grace period ends, a late fee appears here for you to approve or waive. Nothing is ever added to a family’s bill without you.";
  }
  function recentLine(r) {
    var d = r.decided_at ? shortDate(String(r.decided_at).slice(0, 10)) : "";
    if (r.status === "waived") return "Waived" + (d ? " " + d : "") + (r.reason ? " · " + r.reason : "");
    return "Added to the family’s account as " + (r.document_number || "its own invoice") + (d ? " · " + d : "");
  }
  function recentChip(r) { return r.status === "waived" ? { text: "Waived", tone: "muted" } : { text: "Approved", tone: "ok" }; }

  // ---- who may do what (the database enforces it; this decides which buttons to show) ----
  function waiveHint(list) {
    if (!list || !list.can) return "";
    return list.can.waive ? "" : list.can.waived_by === "owner" ? "Only the centre owner can waive a late fee at this centre." : "You can’t waive a late fee.";
  }

  // ---- the questions asked before a change ----
  function approveQuestion(w) {
    return { title: "Add this late fee to the family’s account?", message: title(w) + ". " + amountLine(w) + ". It becomes its own invoice with its own number and can’t be edited afterwards; a mistake is corrected with a credit note.",
             confirmText: "Approve" };
  }
  function approveAllQuestion(list) {
    var n = (list && list.waiting_count) || 0;
    return { title: "Approve all " + n + " late " + plural(n, "fee", "fees") + "?", message: "Each becomes its own invoice on its family’s account (" + money(list.waiting_cents || 0) + " before GST). Fees whose invoice was paid in the meantime are skipped.",
             confirmText: "Approve " + n };
  }
  // what a person typed as the reason for waiving
  function checkWaive(text) {
    var why = String(text == null ? "" : text).trim();
    if (!why) return { ok: false, error: "Please say why this late fee is being waived." };
    if (why.length > REASON_MAX) return { ok: false, error: "Keep the reason under " + REASON_MAX + " characters." };
    return { ok: true, reason: why };
  }

  // ---- what the screen says after an action ----
  function approvedText(r) { return r.already ? "That late fee was already approved (" + (r.number || "its invoice") + ")." : "Approved. It is now " + (r.number || "an invoice") + " on the family’s account."; }
  function approvedAllText(r) {
    var a = (r && r.approved) || 0, s = (r && r.skipped) || 0;
    if (!a && !s) return "Nothing to approve.";
    return "Approved " + a + " late " + plural(a, "fee", "fees") + (a ? " (" + money(r.total_cents || 0) + ")" : "") + "." + (s ? " " + s + " " + plural(s, "was", "were") + " skipped (paid or credited in the meantime)." : "");
  }
  function waivedText(r) { return r.already ? "That late fee was already waived." : "Waived. The family isn’t charged."; }

  // ---- the database's refusals in plain words ----
  var CODED = /^(NOT_ALLOWED|REASON_REQUIRED|TOO_LONG|INVOICE_SETTLED): ([\s\S]*)$/;
  function errorText(err) {
    var m = String((err && err.message) || err || "");
    var c = CODED.exec(m);
    if (c) return /^[a-z]/.test(c[2]) ? c[2].charAt(0).toUpperCase() + c[2].slice(1) : c[2];
    if (/REASON_REQUIRED/.test(m)) return "Please say why.";
    if (/INVOICE_SETTLED/.test(m)) return "That invoice has been paid or credited, so no late fee is due.";
    if (/NOT_ALLOWED/.test(m)) return "Your account can’t do that at this centre. Late fees need the “Issue invoices” permission.";
    if (/NOT_FOUND/.test(m)) return "That isn’t available any more. Refresh the page and try again.";
    return CM.errorText(err);
  }
  function isMissing(err) { return CM.isMissing(err); }

  return { REASON_MAX: REASON_MAX, title: title, rowSub: rowSub, basisText: basisText, amountLine: amountLine, summary: summary, emptyText: emptyText, recentLine: recentLine,
           recentChip: recentChip, waiveHint: waiveHint, approveQuestion: approveQuestion, approveAllQuestion: approveAllQuestion, checkWaive: checkWaive, approvedText: approvedText,
           approvedAllText: approvedAllText, waivedText: waivedText, errorText: errorText, isMissing: isMissing };
});
