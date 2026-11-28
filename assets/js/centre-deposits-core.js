// Centre Money > Deposits (T4 step S4) logic with no DOM and no network: the state chips, the one-line summaries, the words for each ledger row,
// what a person typed in the "opening balance" form, and the database's refusals in plain words.
// Used by assets/js/centre-deposits.js and assets/js/centre-money.js and unit-tested in tests/centre-deposits-core.test.js. The database decides
// everything that matters (db/migration_centre_deposits.sql); this file only saves a round trip and words the answers. All amounts are whole cents.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory(require("./money.js"), require("./centre-money-core.js"));
  else root.CentreDepositsCore = factory(root.Money, root.CentreMoneyCore);
})(typeof self !== "undefined" ? self : this, function (Money, CM) {
  "use strict";
  var plural = CM.plural, money = CM.money, shortDate = CM.shortDate;

  // ---- state chips (colour = meaning: teal = held, amber = something still to collect, grey = not money yet) ----
  var CHIPS = { held: ["Held", "ok"], part_paid: ["Part-paid", "warn"], unpaid: ["Not paid yet", "warn"], draft: ["Draft invoice", "muted"], waived: ["Waived", "muted"],
                 discarded: ["Draft discarded", "muted"], refunded: ["Refunded", "muted"], settled: ["Settled", "muted"] };
  function stateChip(state) { var c = CHIPS[state] || CHIPS.unpaid; return { text: c[0], tone: c[1] }; }

  // ---- how the amount was worked out ----
  function basisText(r) {
    if (!r) return "";
    if (r.mode === "percent_first_month") {
      var pct = r.percent_bp / 100;
      return (pct % 1 === 0 ? pct : pct.toFixed(2).replace(/0+$/, "")) + "% of the first month’s fee (" + money(r.first_month_cents) + ")";
    }
    if (r.mode === "fixed") return "A fixed amount";
    if (r.mode === "opening") return "Collected before TutorDeck";
    return "";
  }
  // a line in the invoice run's preview
  function previewLine(d) {
    var base = d.mode === "percent_first_month" ? (d.percent_bp / 100) + "% of " + money(d.first_month_cents) + " first month" : "Fixed deposit";
    return d.frozen ? base + " · same amount as before" : base;
  }

  // ---- the list ----
  function rowSub(r) {
    var who = r.household_name ? r.household_name + " · " : "";
    if (r.state === "held") return who + (r.source === "opening_balance" ? "Collected before TutorDeck" : "Received in full");
    if (r.state === "part_paid") return who + money(r.short_cents) + " still to collect";
    if (r.state === "unpaid") return who + money(r.short_cents) + " to collect" + (r.invoice_number ? " · " + r.invoice_number : "");
    if (r.state === "draft") return who + "Invoice not issued yet";
    if (r.state === "waived") return who + money(r.waived_cents) + " waived";
    if (r.state === "discarded") return who + "Draft discarded · raised again in the next Invoice run";
    if (r.state === "refunded") return who + "Refunded to the family · nothing to collect";
    if (r.state === "settled") return who + "Used up · nothing to collect";
    return who;
  }
  // what the right-hand figure shows: the money actually held (a draft or waived deposit holds nothing)
  function rowAmount(r) { return r.state === "draft" || r.state === "unpaid" || r.state === "discarded" ? r.due_cents != null ? r.due_cents : r.required_cents : r.held_cents; }
  function summaryLine(t) {
    t = t || {};
    var held = t.students_holding || 0;
    return held ? held + " " + plural(held, "student", "students") + " " + plural(held, "has", "have") + " a deposit held" : "No deposits held yet";
  }
  function shortLine(t) { return t && t.short_cents > 0 ? money(t.short_cents) + " still to collect" : ""; }
  function emptyText() {
    return "No deposits yet. Set the deposit in Centre settings; each new student then gets a separate “Refundable deposit” invoice with their first invoice. A deposit collected before TutorDeck can be added by the owner.";
  }
  function searchRows(rows, q) {
    q = String(q || "").trim().toLowerCase();
    if (!q) return rows;
    return rows.filter(function (r) { return (r.name || "").toLowerCase().indexOf(q) > -1 || (r.household_name || "").toLowerCase().indexOf(q) > -1 || (r.invoice_number || "").toLowerCase().indexOf(q) > -1; });
  }

  // ---- the ledger rows ----
  var KIND = { received: "Received", reversal: "Payment reversed", waived: "Waived", adjusted: "Adjusted", applied: "Kept against fees", forfeited: "Kept by the centre",
               refunded: "Refunded", transferred_out: "Moved to another student", transferred_in: "Moved from another student", opening_balance: "Collected before TutorDeck" };
  function kindLabel(k) { return KIND[k] || "Entry"; }
  // a waiver is not cash: it is shown without a sign and without changing the balance
  function entryAmount(e) { return e.kind === "waived" ? money(e.cents) : (e.cents > 0 ? "+" : "−") + money(Math.abs(e.cents)); }
  function entryLine(e) { return shortDate(e.date) + " · " + kindLabel(e.kind) + (e.invoice_number && e.kind !== "opening_balance" ? " · " + e.invoice_number : ""); }

  // ---- what the detail sheet may offer ----
  function canWaive(r) { return !!r && r.source === "invoice_run" && r.state !== "waived" && r.state !== "held" && (r.state === "draft" || r.short_cents > 0); }
  function waiveQuestion(r) {
    var amt = r.state === "draft" ? r.required_cents : r.short_cents;
    return { title: "Waive " + r.name + "’s deposit?",
             message: r.state === "draft" ? "The draft invoice is discarded and no deposit is asked for." : "A credit note takes " + money(amt) + " off the deposit invoice. What was already paid stays held.",
             placeholder: "Reason (kept in the record)" };
  }

  // ---- the opening-balance form ----
  var MAX = 100000000;
  // o: { studentId, amountText, date, today, note }
  function checkOpening(o) {
    if (!o.studentId) return { ok: false, error: "Choose the student first." };
    var c = Money.parse(o.amountText);
    if (c == null) return { ok: false, error: "Type the amount, for example 150 or 150.00." };
    if (c <= 0) return { ok: false, error: "The amount must be more than S$0.00." };
    if (c > MAX) return { ok: false, error: "That amount is too large to be right." };
    if (!o.date) return { ok: false, error: "Choose the date the deposit was collected." };
    if (o.today && o.date > o.today) return { ok: false, error: "The date can’t be in the future." };
    var note = String(o.note || "").trim();
    if (note.length > 300) return { ok: false, error: "Keep the note under 300 characters." };
    return { ok: true, cents: c, note: note || null };
  }
  function openingText(name, cents) { return money(cents) + " recorded as held for " + name + "."; }
  function waivedText(r) { return r.how === "draft_discarded" ? "Deposit waived. The draft invoice was discarded." : "Deposit waived. " + money(r.waived_cents) + " was credited on the invoice."; }

  // ---- the invoice run's messages about deposits ----
  function runDepositNote(p) { return (p && p.deposit_note) || ""; }
  // "No deposit: Kid has no lesson ready to invoice yet…" (the database's reason starts with a verb, so it reads on after the name)
  function whyLine(r) { var t = String((r && r.reason) || "").trim(); return t ? "This student " + t.charAt(0).toLowerCase() + t.slice(1) : "No deposit is raised."; }
  function runDepositTotal(p) { var t = (p && p.totals) || {}; return t.deposits ? t.deposits + " " + plural(t.deposits, "deposit", "deposits") + " · " + money(t.deposit_cents) : ""; }

  // ---- refusals in plain words (the database's messages are already plain; this strips the code in front) ----
  var CODED = /^(NOT_ALLOWED|BAD_VALUE|TOO_LONG|REASON_REQUIRED|NO_DEPOSIT|ALREADY_WAIVED|ALREADY_HAS_DEPOSIT|DEPOSIT_SHORT): ([\s\S]*)$/;
  function errorText(err) {
    var m = String((err && err.message) || err || "");
    var c = CODED.exec(m);
    if (c) return /^[a-z]/.test(c[2]) ? c[2].charAt(0).toUpperCase() + c[2].slice(1) : c[2];
    if (/REASON_REQUIRED/.test(m)) return "Please say why.";
    if (/NOT_FOUND/.test(m)) return "That isn’t available any more. Refresh the page and try again.";
    return CM.errorText(err);
  }
  function isMissing(err) { return CM.isMissing(err); }

  return { stateChip: stateChip, basisText: basisText, previewLine: previewLine, rowSub: rowSub, rowAmount: rowAmount, summaryLine: summaryLine, shortLine: shortLine,
           emptyText: emptyText, searchRows: searchRows, kindLabel: kindLabel, entryAmount: entryAmount, entryLine: entryLine, canWaive: canWaive, waiveQuestion: waiveQuestion,
           checkOpening: checkOpening, openingText: openingText, waivedText: waivedText, runDepositNote: runDepositNote, whyLine: whyLine, runDepositTotal: runDepositTotal,
           errorText: errorText, isMissing: isMissing };
});
