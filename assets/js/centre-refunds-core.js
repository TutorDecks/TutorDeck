// Centre Money > Refunds (T4 step S5) logic with no DOM and no network: the state chips, the words for each step of a refund, what a person typed in the
// "release the deposit" / "refund family credit" / "mark paid" forms, which buttons to show, and the database's refusals in plain words.
// Used by assets/js/centre-refunds.js, assets/js/centre-deposits.js and assets/js/centre-payments.js and unit-tested in tests/centre-refunds-core.test.js.
// The database decides everything that matters (db/migration_centre_refunds.sql: who may ask, approve and pay; what is held; never over-refunding);
// this file only saves a round trip and words the answers. All amounts are whole cents.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory(require("./money.js"), require("./centre-money-core.js"));
  else root.CentreRefundsCore = factory(root.Money, root.CentreMoneyCore);
})(typeof self !== "undefined" ? self : this, function (Money, CM) {
  "use strict";
  var money = CM.money, plural = CM.plural, shortDate = CM.shortDate;
  var MAX = 100000000;
  var METHODS = [["bank", "Bank transfer"], ["manual_paynow", "PayNow"], ["cash", "Cash"], ["cheque", "Cheque"], ["other", "Other"]];
  var REF_DIGITS = /\d{8,}/;   // the database refuses it too: a whole account or PayNow number must never be stored (PDPA)

  // ---- state chips (colour = meaning: teal = done, amber = somebody has to act, grey = nothing to do) ----
  function isKept(r) { return !!r && r.kind === "deposit" && r.refund_cents === 0; }
  function chip(r) {
    var s = r && r.state;
    if (s === "requested") return { text: "Waiting for approval", tone: "warn" };
    if (s === "approved") return { text: "Approved · to pay", tone: "warn" };
    if (s === "paid") return { text: isKept(r) ? "Done" : "Paid", tone: "ok" };
    if (s === "cancelled") return { text: "Cancelled", tone: "muted" };
    return { text: "Waiting for approval", tone: "warn" };
  }
  function isOpen(r) { return !!r && (r.state === "requested" || r.state === "approved"); }

  // ---- the list ----
  function title(r) { return r.kind === "deposit" ? (r.student_name || "Deposit") : (r.household_name || "Family"); }
  function kindLabel(r) { return r.kind === "deposit" ? (isKept(r) ? "Deposit kept" : "Deposit refund") : "Family credit refund"; }
  function headline(r) { return r.kind === "deposit" ? (r.refund_cents > 0 ? r.refund_cents : r.forfeit_cents + r.set_off_cents) : r.refund_cents; }
  function rowSub(r) { return kindLabel(r) + " · asked " + shortDate(r.requested_on) + (r.requested_by_name ? " by " + r.requested_by_name : ""); }
  // what the request does with the money, one line per part
  function parts(r) {
    var p = [];
    if (r.refund_cents > 0) p.push(["Refunded to the family", r.refund_cents]);
    if (r.set_off_cents > 0) p.push(["Kept against unpaid invoices", r.set_off_cents]);
    if (r.forfeit_cents > 0) p.push(["Kept by the centre", r.forfeit_cents]);
    return p;
  }
  function amountLine(r) { return parts(r).map(function (x) { return x[0].toLowerCase() + " " + money(x[1]); }).join(" · "); }

  // ---- who must act next ----
  function approverWords(r) {
    if (r.approver_rule === "four_eyes") return "Someone other than " + (r.requested_by_name || "the person who asked") + " has to approve this.";
    if (r.approver_rule === "staff") return r.kind === "deposit" ? "The owner or a staff member who issues invoices approves this." : "The owner or a staff member who records payments approves this.";
    return "Only the centre owner approves this.";
  }
  // the buttons for one refund, from what the database said this caller may do. One primary action (the next step).
  function actions(r) {
    var a = [];
    if (r.can_approve) a.push({ id: "approve", label: "Approve", primary: true });
    if (r.can_pay) a.push({ id: "pay", label: "Mark as paid", primary: true });
    if (r.can_cancel) a.push({ id: "cancel", label: "Cancel this refund", primary: false });
    return a;
  }
  function nextText(r) {
    if (r.state === "requested") return r.can_approve ? "It needs your approval." : approverWords(r);
    if (r.state === "approved") return isKept(r) ? "" : (r.can_pay ? "Pay the family, then mark it as paid. TutorDeck records the payment; it doesn’t send money." : "Waiting for someone to pay the family and mark it as paid.");
    return "";
  }

  // ---- the trail (the statement) ----
  var EVENT = { approved: "Approved", paid: "Paid", cancelled: "Cancelled" };
  function methodLabel(m) { for (var i = 0; i < METHODS.length; i++) if (METHODS[i][0] === m) return METHODS[i][1]; return m || ""; }
  function trail(r) {
    var rows = [{ label: "Asked", on: r.requested_on, by: r.requested_by_name, detail: r.reason }];
    (r.events || []).forEach(function (e) {
      var d = [];
      if (e.kind === "paid" && isKept(r)) d.push("Completed");
      if (e.method) d.push(methodLabel(e.method));
      if (e.reference) d.push(e.reference);
      if (e.kind === "cancelled" && e.reason) d.push(e.reason);
      if (e.note) d.push(e.note);
      if (e.kind === "paid" && r.kind === "deposit" && r.set_off_cents > 0 && e.set_off_cents != null && e.set_off_cents !== r.set_off_cents) d.push("Kept against invoices: " + money(e.set_off_cents) + " of " + money(r.set_off_cents) + " (the rest stays held)");
      rows.push({ label: (e.kind === "paid" && isKept(r)) ? "Done" : EVENT[e.kind] || e.kind, on: e.on, by: e.by, detail: d.join(" · ") });
    });
    return rows;
  }
  function calculationRows(r) {
    var rows = [["Held when asked", r.held_cents]];
    parts(r).forEach(function (x) { rows.push(x); });
    if (r.gst_cents > 0) rows.push(["GST given back with the refund", r.gst_cents]);
    return rows;
  }
  function releaseRuleText(rule) {
    return { refund_full: "Refund the whole deposit", refund_less_unpaid: "Keep it against unpaid invoices, refund the rest", admin_decides: "An admin decides" }[rule] || "";
  }

  // ---- the release proposal (read from centre_deposit_release_proposal) ----
  function canAsk(p) { return !!p && p.state === "ready" && !!p.can_request; }
  function waitingText(p) {
    if (!p) return "";
    if (p.state === "waiting") return (p.waiting || []).join(" ");
    if (p.state === "nothing_held") return "Nothing is held for this student, so there is nothing to release.";
    if (p.state === "no_deposit") return "This student has no deposit.";
    if (p.state === "open_refund") return "A refund for this deposit is already in progress. Finish or cancel it first.";
    return "";
  }
  function suggestionText(p) {
    if (!p || !p.suggest) return p && p.state === "ready" ? "The centre has chosen “an admin decides”: type the amounts." : "";
    var s = p.suggest, bits = [];
    if (s.refund_cents > 0) bits.push("refund " + money(s.refund_cents));
    if (s.set_off_cents > 0) bits.push("keep " + money(s.set_off_cents) + " against unpaid invoices");
    if (s.forfeit_cents > 0) bits.push("keep " + money(s.forfeit_cents) + " (short notice)");
    return bits.length ? "The centre’s rule suggests: " + bits.join(", ") + "." : "";
  }
  function centsText(c) { return c ? (c / 100).toFixed(2) : "0.00"; }
  // o: { refundText, forfeitText, setOffText, p (the proposal), reason, payee, noticeText, today }
  // Mirrors what the database refuses, so a person finds out before pressing the button. The database still decides.
  function checkRelease(o) {
    var p = o.p || {}, parsed = {}, keys = [["refund", o.refundText], ["forfeit", o.forfeitText], ["setOff", o.setOffText]], i, c;
    for (i = 0; i < keys.length; i++) {
      var t = String(keys[i][1] == null ? "" : keys[i][1]).trim();
      c = t === "" ? 0 : Money.parse(t);
      if (c == null) return { ok: false, error: "Type amounts like 25 or 25.50." };
      if (c < 0) return { ok: false, error: "Amounts can’t be negative." };
      if (c > MAX) return { ok: false, error: "That amount is too large to be right." };
      parsed[keys[i][0]] = c;
    }
    var total = parsed.refund + parsed.forfeit + parsed.setOff;
    if (total <= 0) return { ok: false, error: "Choose how much to refund, keep or set off." };
    if (total > (p.available_cents || 0)) return { ok: false, error: "Only " + money(p.available_cents || 0) + " is held and free to release (you typed " + money(total) + ")." };
    if (parsed.setOff > 0 && p.taxable) return { ok: false, error: "This deposit carried GST, so it can’t be kept against invoices. Refund it instead." };
    if (parsed.setOff > (p.unpaid_cents || 0)) return { ok: false, error: "The family owes only " + money(p.unpaid_cents || 0) + " on open invoices." };
    var why = String(o.reason || "").trim();
    if (!why) return { ok: false, error: "Say why. The reason is kept in the record." };
    if (why.length > 300) return { ok: false, error: "Keep the reason under 300 characters." };
    var payee = String(o.payee || "").trim();
    if (payee.length > 120) return { ok: false, error: "Keep the name under 120 characters." };
    if (p.notice_days > 0 && o.noticeText && o.today && o.noticeText > o.today) return { ok: false, error: "The day notice was given can’t be in the future." };
    return { ok: true, refund: parsed.refund, forfeit: parsed.forfeit, setOff: parsed.setOff, reason: why, payee: payee || null };
  }
  function releaseQuestion(c, name) {
    var bits = [];
    if (c.refund > 0) bits.push("refund " + money(c.refund));
    if (c.setOff > 0) bits.push("keep " + money(c.setOff) + " against unpaid invoices");
    if (c.forfeit > 0) bits.push("keep " + money(c.forfeit) + " as income");
    return { title: "Ask to release " + name + "’s deposit?", message: "You will " + bits.join(", ") + ". Nothing moves until it is approved" + (c.refund > 0 ? " and marked as paid" : "") + "." };
  }
  function requestedText(r) { return r.already ? "That request was already made." : "Asked. " + approverWords(r); }

  // ---- family credit ----
  // o: { amountText, available, reason }
  function checkCreditRefund(o) {
    var c = Money.parse(o.amountText);
    if (c == null) return { ok: false, error: "Type the amount, for example 25 or 25.50." };
    if (c <= 0) return { ok: false, error: "The refund must be more than S$0.00." };
    if (c > MAX) return { ok: false, error: "That amount is too large to be right." };
    if (c > (o.available || 0)) return { ok: false, error: "Only " + money(o.available || 0) + " of credit is free to refund." };
    var why = String(o.reason || "").trim();
    if (!why) return { ok: false, error: "Say why. The reason is kept in the record." };
    if (why.length > 300) return { ok: false, error: "Keep the reason under 300 characters." };
    return { ok: true, cents: c, reason: why };
  }
  // what applying the credit would do to one invoice: min(credit free, what it still owes)
  function applyAmount(available, invoiceBalance) { return Math.max(0, Math.min(available || 0, invoiceBalance || 0)); }
  function checkApply(o) {
    var t = String(o.amountText == null ? "" : o.amountText).trim();
    var c = t === "" ? applyAmount(o.available, o.balance) : Money.parse(t);
    if (c == null) return { ok: false, error: "Type the amount, for example 25 or 25.50." };
    if (c <= 0) return { ok: false, error: (o.available || 0) <= 0 ? "This family has no free credit." : "This invoice is already paid." };
    if (c > (o.available || 0)) return { ok: false, error: "Only " + money(o.available || 0) + " of credit is free to use." };
    if (c > (o.balance || 0)) return { ok: false, error: "This invoice only owes " + money(o.balance || 0) + "." };
    return { ok: true, cents: c };
  }
  function appliedText(r) {
    if (r.already) return "That credit was already applied.";
    return money(r.applied_cents) + " of credit used. The family now holds " + money(r.credit_balance_cents) + ".";
  }
  function creditLines(st) {
    if (!st) return "";
    var s = money(st.balance_cents) + " held for the family";
    if (st.reserved_cents > 0) s += " · " + money(st.reserved_cents) + " being refunded";
    return s;
  }

  // ---- marking a refund paid ----
  // o: { method, dateText, today, requestedOn, reference }
  function checkPaid(o) {
    if (!o.method || !METHODS.some(function (m) { return m[0] === o.method; })) return { ok: false, error: "Choose how it was paid back." };
    if (!o.dateText) return { ok: false, error: "Choose the day it was paid." };
    if (o.today && o.dateText > o.today) return { ok: false, error: "The day it was paid can’t be in the future." };
    if (o.requestedOn && o.dateText < o.requestedOn) return { ok: false, error: "It can’t have been paid before it was asked for (" + shortDate(o.requestedOn) + ")." };
    var ref = String(o.reference || "").trim();
    if (ref.length > 120) return { ok: false, error: "Keep the reference under 120 characters." };
    if (REF_DIGITS.test(ref)) return { ok: false, error: "Don’t type a full bank account or PayNow number. The last 4 digits are enough, for example “DBS ending 6789”." };
    return { ok: true, method: o.method, date: o.dateText, reference: ref || null };
  }
  function paidText(r) { return r.already ? "That refund was already marked as paid." : (isKept(r) ? "Done." : "Marked as paid. The deposit and the record are updated."); }
  function approvedText(r) { return r.already ? "That refund was already approved." : (isKept(r) ? "Approved. The deposit has been kept." : "Approved. Now pay the family and mark it as paid."); }
  function cancelledText(r) { return r.already ? "That refund was already cancelled." : "Cancelled. Nothing was moved."; }
  function noticeNote(p) {
    if (!p || !(p.notice_days > 0)) return "";
    if (p.notice_given_on == null) return "This centre keeps the deposit if less than " + p.notice_days + " " + plural(p.notice_days, "day", "days") + "’ notice is given. Type the day the family said they were leaving.";
    return p.notice_short ? "Less than " + p.notice_days + " days’ notice was given." : "Enough notice was given (" + p.notice_days + " days needed).";
  }

  // ---- group a list: open first ----
  function split(rows) { var o = [], c = []; (rows || []).forEach(function (r) { (isOpen(r) ? o : c).push(r); }); return { open: o, closed: c }; }
  function summary(rows) {
    var s = split(rows), n = s.open.length;
    if (!n) return (rows || []).length ? "Nothing waiting. " + (rows.length) + " " + plural(rows.length, "refund", "refunds") + " in the record." : "No refunds yet.";
    var wait = s.open.filter(function (r) { return r.state === "requested"; }).length, pay = n - wait, bits = [];
    if (wait) bits.push(wait + " waiting for approval");
    if (pay) bits.push(pay + " to pay");
    return bits.join(" · ");
  }
  function emptyText() { return "No refunds yet. When a student leaves, open their deposit to release it; a family’s credit is refunded from one of its invoices."; }

  // ---- idempotency key: one per opened form, so pressing twice does nothing twice ----
  function newKey() {
    try { if (typeof crypto !== "undefined" && crypto.randomUUID) return crypto.randomUUID(); } catch (e) {}
    return "k-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10);
  }

  // ---- the database's refusals in plain words ----

  // ---- UNDO of credit / a deposit that was applied to an invoice (T4 step S5b; db/migration_centre_credit_undo.sql decides, this words it) ----
  // `a` is one row of centre_invoice_applications(invoice).rows: { method, cents, date, on_this_invoice_cents, also_invoices[], by, state, undone_on, undone_by, undone_reason, blockers[{code,text}], can_undo }
  function undoWhat(a) { return a && a.method === "deposit" ? "deposit kept against the invoice" : "family credit used"; }
  function undoTitle(a) { return a && a.method === "deposit" ? "Deposit kept against this invoice" : "Family credit used on this invoice"; }
  function undoRow(a) {
    var bits = [shortDate(a.date)];
    if (a.by) bits.push("by " + a.by);
    if ((a.also_invoices || []).length) bits.push("also paid " + a.also_invoices.join(", "));
    return bits.join(" · ");
  }
  function undoAmount(a) { return a.on_this_invoice_cents || a.cents || 0; }
  function undoBlockers(a) { return ((a && a.blockers) || []).map(function (b) { return b.text; }); }
  // what to say under the row when there is no Undo button
  function undoNote(a, canRole) {
    if (!a) return "";
    if (a.state === "undone") return "Undone" + (a.undone_on ? " on " + shortDate(a.undone_on) : "") + (a.undone_by ? " by " + a.undone_by : "") + (a.undone_reason ? ": " + a.undone_reason : "") + ".";
    if (a.can_undo) return "";
    var b = undoBlockers(a);
    if (b.length) return "Can’t be undone: " + b.join(" ");
    return canRole === false ? "Only the owner or a staff member who issues invoices can undo this." : "";
  }
  function undoQuestion(a, invoiceNumber) {
    var n = (a.also_invoices || []).length, what = a.method === "deposit" ? "deposit" : "credit";
    return "Take back " + money(a.cents) + " of " + what + (n ? " from " + invoiceNumber + " and " + n + plural(n, " other invoice", " other invoices") : " from " + invoiceNumber) + "? " +
      (n ? "They will all owe money again. " : "The invoice will owe " + money(undoAmount(a)) + " again. ") +
      (a.method === "deposit" ? "The money goes back into the student’s deposit." : "The money goes back into the family’s credit.") + " A record of the undo is kept.";
  }
  function checkUndo(o) {
    var why = String((o && o.reason) || "").trim();
    if (!why) return { ok: false, error: "Say why. The reason is kept in the record." };
    if (why.length > 300) return { ok: false, error: "Keep the reason under 300 characters." };
    return { ok: true, reason: why };
  }
  function undoDoneText(r, a) {
    if (r && r.already) return "That was already undone.";
    return "Undone. " + money((r && r.undone_cents) || (a && a.cents) || 0) + " is back in the " + (a && a.method === "deposit" ? "student’s deposit" : "family’s credit") + ".";
  }

  var CODED = /^(NOT_ALLOWED|BAD_VALUE|TOO_LONG|REASON_REQUIRED|NO_DEPOSIT|DEPOSIT_SHORT|CREDIT_SHORT|NOT_READY|OPEN_REFUND|NOT_APPROVED|ALREADY_CANCELLED|ALREADY_PAID|NOTHING_TO_APPLY|UNDO_BLOCKED|FOUR_EYES_UNAVAILABLE): ([\s\S]*)$/;
  function errorText(err) {
    var m = String((err && err.message) || err || "");
    var c = CODED.exec(m);
    if (c) return /^[a-z]/.test(c[2]) ? c[2].charAt(0).toUpperCase() + c[2].slice(1) : c[2];
    if (/REASON_REQUIRED/.test(m)) return "Please say why.";
    if (/NOT_FOUND/.test(m)) return "That isn’t available any more. Refresh the page and try again.";
    return CM.errorText(err);
  }
  function isMissing(err) { return CM.isMissing(err); }

  return { METHODS: METHODS, chip: chip, isOpen: isOpen, isKept: isKept, title: title, kindLabel: kindLabel, headline: headline, rowSub: rowSub, parts: parts, amountLine: amountLine,
           approverWords: approverWords, actions: actions, nextText: nextText, trail: trail, calculationRows: calculationRows, releaseRuleText: releaseRuleText, methodLabel: methodLabel,
           canAsk: canAsk, waitingText: waitingText, suggestionText: suggestionText, centsText: centsText, checkRelease: checkRelease, releaseQuestion: releaseQuestion, requestedText: requestedText,
           checkCreditRefund: checkCreditRefund, applyAmount: applyAmount, checkApply: checkApply, appliedText: appliedText, creditLines: creditLines, checkPaid: checkPaid,
           paidText: paidText, approvedText: approvedText, cancelledText: cancelledText, noticeNote: noticeNote, split: split, summary: summary, emptyText: emptyText, newKey: newKey,
           errorText: errorText, isMissing: isMissing,
           undoWhat: undoWhat, undoTitle: undoTitle, undoRow: undoRow, undoAmount: undoAmount, undoBlockers: undoBlockers, undoNote: undoNote, undoQuestion: undoQuestion,
           checkUndo: checkUndo, undoDoneText: undoDoneText };
});
