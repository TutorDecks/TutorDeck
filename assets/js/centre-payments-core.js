// Centre Money > Invoices (T4 step S3) logic with no DOM and no network: status chips, filters, the one-line summaries, what a person typed in the
// "Record payment" and "Credit note" forms, the WhatsApp text, the share address, and the database's refusals in plain words.
// Used by assets/js/centre-payments.js and unit-tested in tests/centre-payments-core.test.js. The database decides everything that matters
// (db/migration_centre_payments.sql); this file only saves a round trip and words the answers. All amounts are whole cents.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory(require("./money.js"), require("./centre-money-core.js"));
  else root.CentrePaymentsCore = factory(root.Money, root.CentreMoneyCore);
})(typeof self !== "undefined" ? self : this, function (Money, CM) {
  "use strict";
  var plural = CM.plural, money = CM.money, shortDate = CM.shortDate;

  var METHODS = [["manual_paynow", "PayNow"], ["bank", "Bank transfer"], ["cash", "Cash"], ["cheque", "Cheque"], ["other", "Other"]];
  // family_credit / deposit are not ways to pay: they are money already held, moved onto an invoice (so they are not in METHODS, the payment form's list)
  function methodLabel(m) { if (m === "family_credit") return "Family credit"; if (m === "deposit") return "Deposit kept"; for (var i = 0; i < METHODS.length; i++) if (METHODS[i][0] === m) return METHODS[i][1]; return "Other"; }

  // ---- status chips (colour = meaning: teal paid, red overdue, amber part-paid, grey otherwise) ----
  var CHIPS = { issued: ["Issued", "muted"], part_paid: ["Part-paid", "warn"], paid: ["Paid", "ok"], overdue: ["Overdue", "bad"], void: ["Void (credited)", "muted"],
                draft: ["Draft", "muted"], discarded: ["Discarded", "muted"], credit_note: ["Credit note", "muted"] };
  function payChip(ps) { var c = CHIPS[ps] || CHIPS.issued; return { text: c[0], tone: c[1] }; }

  // ---- filters (the chips above the list); counts come from the database ----
  var FILTERS = [["all", "All"], ["unpaid", "Unpaid"], ["overdue", "Overdue"], ["part_paid", "Part-paid"], ["paid", "Paid"]];
  function filterChips(counts, active) {
    return FILTERS.map(function (f) { return { key: f[0], label: f[1], count: counts && counts[f[0]] != null ? counts[f[0]] : null, active: f[0] === active }; });
  }
  function validFilter(f) { return FILTERS.some(function (x) { return x[0] === f; }); }

  // ---- the list ----
  function daysBetween(a, b) { return Math.round((Date.parse(b + "T00:00:00Z") - Date.parse(a + "T00:00:00Z")) / 86400000); }
  function rowSub(r, today) {
    var due = r.due_date ? shortDate(r.due_date) : "";
    switch (r.pay_status) {
      case "paid": return "Paid in full";
      case "void": return "Credited in full";
      case "overdue": {
        var n = r.due_date && today ? daysBetween(r.due_date, today) : 0;
        return "Overdue" + (n > 0 ? " by " + n + " " + plural(n, "day", "days") : "") + (r.paid_cents ? " · " + money(r.paid_cents) + " of " + money(r.total_cents) + " paid" : "");
      }
      case "part_paid": return money(r.paid_cents) + " of " + money(r.total_cents) + " paid" + (due ? " · due " + due : "");
      default: return due ? "Due " + due : "Issued";
    }
  }
  function rowAmount(r) { return r.balance_cents > 0 ? r.balance_cents : r.total_cents; }
  function summaryLine(list) {
    if (!list) return "";
    var parts = [money(list.outstanding_cents || 0) + " owed"];
    if (list.overdue_cents) parts.push(money(list.overdue_cents) + " overdue");
    return parts.join(" · ");
  }
  function searchRows(rows, q) {
    var s = String(q || "").trim().toLowerCase();
    if (!s) return rows || [];
    return (rows || []).filter(function (r) { return String(r.name || "").toLowerCase().indexOf(s) >= 0 || String(r.number || "").toLowerCase().indexOf(s) >= 0; });
  }
  function emptyText(filter, searching) {
    if (searching) return "No invoice matches that.";
    return { unpaid: "Nothing is owed right now.", overdue: "Nothing is overdue.", part_paid: "No invoice is part-paid.", paid: "No invoice is fully paid yet.", all: "No invoices have been issued yet. Issue them from the Invoice run tab." }[filter] || "Nothing here.";
  }

  // ---- one invoice ----
  function paymentLine(p) {
    var d = shortDate(p.received_on), m = methodLabel(p.method);
    if (p.kind === "reversal") return "Reversal · " + d;
    return d + " · " + m + (p.reference ? " · " + p.reference : "");
  }
  function amountsRows(a) {
    var rows = [["Invoice total", a.total_cents]];
    if (a.credited_cents) rows.push(["Credit notes", -a.credited_cents]);
    if (a.paid_cents) rows.push(["Paid", -a.paid_cents]);
    rows.push(["Still owed", a.balance_cents]);
    return rows;
  }
  function creditLine(c) { return c > 0 ? "This family holds " + money(c) + " in credit." : ""; }

  // ---- what was typed ----
  var MAX_PAYMENT = 100000000;
  function todayISO(d) { d = d || new Date(); return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10); }
  // o: { amountText, balance, rules: {partial_payments, overpayments}, date, today }
  function checkPayment(o) {
    var c = Money.parse(o.amountText);
    if (c == null) return { ok: false, error: "Type the amount, for example 50 or 50.00." };
    if (c <= 0) return { ok: false, error: "The amount must be more than S$0.00." };
    if (c > MAX_PAYMENT) return { ok: false, error: "That amount is too large to be right." };
    if (!o.date) return { ok: false, error: "Choose the date it was received." };
    if (o.today && o.date > o.today) return { ok: false, error: "The date received can’t be in the future." };
    var rules = o.rules || {}, bal = o.balance || 0;
    if (rules.partial_payments === false && c < bal) return { ok: false, cents: c, error: "This centre doesn’t accept part payments. The payment has to cover the whole invoice (" + money(bal) + ")." };
    var res = { ok: true, cents: c, over: 0, part: false, note: "" };
    if (c > bal) {
      res.over = c - bal;
      res.note = money(res.over) + " is more than this invoice. " + (rules.overpayments === "refund" ? "It will be marked to refund to the family." : "It will be kept as credit for the family.");
    } else if (c < bal) { res.part = true; res.note = "The invoice will be part-paid. " + money(bal - c) + " will still be owed."; }
    return res;
  }
  // o: { amountText, left (what can still be credited), reason }
  function checkCredit(o) {
    var c = Money.parse(o.amountText);
    if (c == null) return { ok: false, error: "Type the amount, for example 10 or 10.00." };
    if (c <= 0) return { ok: false, error: "The credit must be more than S$0.00." };
    if (c > o.left) return { ok: false, error: "You can credit at most " + money(o.left) + " on this invoice." };
    var why = String(o.reason || "").trim();
    if (!why) return { ok: false, cents: c, error: "Say why. The reason is printed on the credit note." };
    if (why.length > 300) return { ok: false, cents: c, error: "Keep the reason under 300 characters." };
    return { ok: true, cents: c, reason: why };
  }
  // what the credit note would leave the family holding: the invoice's money in minus what it now costs
  function creditExcess(a, cents) { return Math.max(a.paid_cents + a.credited_cents + cents - a.total_cents, 0); }
  function creditLeft(a) { return Math.max(a.total_cents - a.credited_cents, 0); }
  function creditQuestion(a, c) {
    var ex = creditExcess(a, c.cents);
    return { title: "Issue a credit note for " + money(c.cents) + "?",
             message: "It gets its own number (CN-…) and can’t be changed afterwards. " + (ex ? money(ex) + " has already been paid, so it will be " + (a.rules && a.rules.overpayments === "refund" ? "marked to refund to the family." : "kept as credit for the family.") : "It reduces what the family owes.") };
  }

  // ---- messages after an action ----
  function paidText(r, number) {
    var al = (r.allocated || []), parts = [];
    if (al.length === 1) {
      var bal = al[0].balance_after_cents;
      parts.push(bal === 0 ? al[0].number + " is paid." : al[0].number + " is part-paid. " + money(bal) + " still owed.");
    } else if (al.length > 1) parts.push("Covered " + al.length + " invoices.");
    if (r.excess_cents) parts.push(money(r.excess_cents) + (r.excess_handling === "refund" ? " to refund to the family." : " kept as credit for the family."));
    return "Payment recorded. " + parts.join(" ");
  }
  function creditNoteText(r) {
    return "Credit note " + r.number + " issued for " + money(r.total_cents) + "." + (r.pay_status === "void" ? " The invoice is now void." : "") +
      (r.excess_to_family_cents ? " " + money(r.excess_to_family_cents) + " is now held for the family." : "");
  }
  function reverseQuestion(p) {
    return { title: "Reverse this payment?", message: money(Math.abs(p.cents)) + " (" + methodLabel(p.method) + ", " + shortDate(p.received_on) + ") is taken off the invoice. The original entry stays on record with a reversing entry beside it. Say why.", placeholder: "Reason (for example: wrong family)" };
  }

  // ---- the WhatsApp message and the share address ----
  function shareUrl(origin, token) { return String(origin || "").replace(/\/+$/, "") + "/pay?t=" + encodeURIComponent(token); }
  // vars from centre_invoice_whatsapp(); link may be "" (links switched off): a line with {link} in it is then left out
  function fillTemplate(tpl, vars, link) {
    var v = { name: vars.name || "", centre: vars.centre || "", number: vars.number || "", amount: money(vars.amount_cents || 0),
              due_date: vars.due_date ? shortDate(vars.due_date) : "", link: link || "" };
    var lines = String(tpl || "").split(/\r?\n/);
    if (!link) lines = lines.filter(function (l) { return l.indexOf("{link}") < 0; });
    var out = lines.join("\n").replace(/\{(\w+)\}/g, function (_, k) { return v[k] != null ? v[k] : ""; });
    return out.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  }
  function waUrl(phone, text) { return "https://wa.me/" + (phone ? String(phone).replace(/\D/g, "") : "") + "?text=" + encodeURIComponent(text); }

  // ---- refusals in plain words (the database's messages are already plain; this strips the code in front and covers the rest) ----
  var CODED = /^(NOT_ALLOWED|PART_NOT_ALLOWED|BAD_VALUE|TOO_MUCH|CREDIT_SHORT|ALREADY_REVERSED|TOO_LONG): ([\s\S]*)$/;
  function errorText(err) {
    var m = String((err && err.message) || err || "");
    var c = CODED.exec(m);
    if (c) return /^[a-z]/.test(c[2]) ? c[2].charAt(0).toUpperCase() + c[2].slice(1) : c[2];
    if (/REASON_REQUIRED/.test(m)) return "Please say why.";
    if (/NOT_FOUND/.test(m)) return "That isn’t available any more. Refresh the page and try again.";
    var known = CM.errorText(err);
    if (known !== "Something went wrong." && !/^Something went wrong/.test(known)) return known;
    // an error word the code knows but the message doesn't explain: say what kind of problem it is, in plain words
    var code = String((err && err.code) || "");
    if (code === "21000") return "The database refused this change as unsafe, so nothing was recorded. This is a fault on our side, not yours. Please tell TutorDeck (code 21000).";
    if (code === "23514") return "The amounts didn’t add up, so nothing was recorded. Refresh the page and try again.";
    if (code === "40001" || code === "40P01") return "Someone else was changing this family’s payments at the same moment. Try again in a few seconds.";
    if (code === "23505") return "That was already recorded. Refresh the page to see it.";
    if (code === "42501") return "Your account isn’t allowed to do that at this centre.";
    if (code) return "Something went wrong (code " + code + "). Refresh the page and try again; if it happens again, tell TutorDeck.";
    return known;
  }
  function isMissing(err) { return CM.isMissing(err); }

  return { METHODS: METHODS, methodLabel: methodLabel, payChip: payChip, FILTERS: FILTERS, filterChips: filterChips, validFilter: validFilter, rowSub: rowSub, rowAmount: rowAmount,
           summaryLine: summaryLine, searchRows: searchRows, emptyText: emptyText, paymentLine: paymentLine, amountsRows: amountsRows, creditLine: creditLine, todayISO: todayISO,
           checkPayment: checkPayment, checkCredit: checkCredit, creditExcess: creditExcess, creditLeft: creditLeft, creditQuestion: creditQuestion, paidText: paidText,
           creditNoteText: creditNoteText, reverseQuestion: reverseQuestion, shareUrl: shareUrl, fillTemplate: fillTemplate, waUrl: waUrl, errorText: errorText, isMissing: isMissing,
           daysBetween: daysBetween };
});
