// Synthetic bank-statement generator for tests (T34). Seeded, so every run is the same. EVERYTHING HERE IS INVENTED: fake families, fake payers from a fixed
// list, obviously invalid account numbers. Every layout is labelled "layout assumed, not a real export": none of them is a copy of any bank's file, and the
// repo is public, so no real statement (not even an anonymised one) may ever be a fixture.
"use strict";
function rng(seed) { var a = seed >>> 0; return function () { a |= 0; a = a + 0x6D2B79F5 | 0; var t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }
var PAYERS = ["TAN AH KOW", "LIM MEI LING", "NG SOON HOCK", "MRS CHUA", "WONG, DAVID", "KOH XIAO MING", "OH \"AH\" BENG", "SITI AMINAH", "RAJ KUMAR", "GOH & SONS PTE LTD"];
var NOTES = ["school fees", "maths lessons", "Nov fees", "tuition", "PAYNOW", "fees for kid", "thanks!", "class fee, Nov", "see invoice"];
var MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
function p2(n) { return (n < 10 ? "0" : "") + n; }
function fmtDate(iso, how) {
  var y = iso.slice(0, 4), m = +iso.slice(5, 7), d = +iso.slice(8, 10);
  return how === "dmy_slash" ? p2(d) + "/" + p2(m) + "/" + y : how === "dmy_dash" ? p2(d) + "-" + p2(m) + "-" + y : how === "dmy_text" ? d + " " + MON[m - 1] + " " + y : how === "mdy_slash" ? p2(m) + "/" + p2(d) + "/" + y : iso;
}
function money(c, thousands) { var a = Math.abs(c), s = Math.floor(a / 100) + "." + p2(a % 100); if (thousands) s = s.replace(/\B(?=(\d{3})+(?!\d))/g, ","); return s; }
function q(s, delim) { s = String(s); return /["\r\n]/.test(s) || s.indexOf(delim) >= 0 ? '"' + s.replace(/"/g, '""') + '"' : s; }

// layouts: signed | debit_credit | amount_drcr | headers_footer | text_dates | us_dates | semicolon
var LAYOUTS = ["signed", "debit_credit", "amount_drcr", "headers_footer", "text_dates", "us_dates", "semicolon"];
function generate(o) {
  o = o || {}; var r = rng(o.seed == null ? 1 : o.seed), n = o.n || 50, layout = o.layout || "signed", invoices = o.invoices || [];
  var delim = layout === "semicolon" ? ";" : ",", dateHow = layout === "text_dates" ? "dmy_text" : layout === "us_dates" ? "mdy_slash" : layout === "semicolon" ? "dmy_dash" : "dmy_slash";
  var thousands = layout !== "us_dates";
  var lines = [], day0 = Date.UTC(2026, 9, 1);
  for (var i = 0; i < n; i++) {
    var t = new Date(day0 + Math.floor(r() * 56) * 86400000).toISOString().slice(0, 10);
    var out = r() < 0.12, cents = (Math.floor(r() * 400) + 5) * 100 + (r() < 0.3 ? Math.floor(r() * 99) + 1 : 0), ref, payer = out ? "" : PAYERS[Math.floor(r() * PAYERS.length)];
    if (out) { cents = -cents; ref = "FAST PAYMENT TO SUPPLIER " + (1000 + i); }
    else if (invoices.length && r() < 0.5) { var v = invoices[Math.floor(r() * invoices.length)]; ref = (r() < 0.5 ? v.number : v.number.toLowerCase().replace("-", " ")) + " " + NOTES[Math.floor(r() * NOTES.length)]; if (r() < 0.6) cents = v.bal; }
    else ref = NOTES[Math.floor(r() * NOTES.length)] + (r() < 0.15 ? ", acct 123456789012" : "");
    lines.push({ date: t, cents: cents, ref: ref, payer: payer, bank_ref: "TX" + (100000 + i * 7) });
  }
  var rows = [], head, mapping;
  function dateCell(l) { return fmtDate(l.date, dateHow); }
  if (layout === "debit_credit") {
    head = ["Date", "Description", "Withdrawal", "Deposit", "Payer", "Reference"];
    lines.forEach(function (l) { rows.push([dateCell(l), l.ref, l.cents < 0 ? money(l.cents, thousands) : "", l.cents > 0 ? money(l.cents, thousands) : "", l.payer, l.bank_ref]); });
    mapping = { date_col: 0, amount_mode: "debit_credit", debit_col: 2, credit_col: 3, ref_cols: [1], payer_col: 4, bank_ref_col: 5 };
  } else if (layout === "amount_drcr") {
    head = ["Posted", "Details", "Amount", "Dr/Cr", "From", "Ref"];
    lines.forEach(function (l) { rows.push([dateCell(l), l.ref, money(l.cents, thousands), l.cents < 0 ? "DR" : "CR", l.payer, l.bank_ref]); });
    mapping = { date_col: 0, amount_mode: "amount_drcr", amount_col: 2, drcr_col: 3, drcr_in: "CR", ref_cols: [1], payer_col: 4, bank_ref_col: 5 };
  } else {
    head = ["Date", "Description", "Amount", "Payer", "Reference"];
    lines.forEach(function (l) { rows.push([dateCell(l), l.ref, (l.cents < 0 ? "-" : "") + money(l.cents, thousands), l.payer, l.bank_ref]); });
    mapping = { date_col: 0, amount_mode: "signed", amount_col: 2, ref_cols: [1], payer_col: 3, bank_ref_col: 4 };
  }
  mapping.delimiter = delim; mapping.date_format = dateHow; mapping.header_rows = 1; mapping.skip_empty_date = true;
  var all = [head].concat(rows), pre = [], post = [];
  if (layout === "headers_footer") {
    pre = [["Statement of account (layout assumed, not a real export)", "", "", "", ""], ["Account", "000-000000-0 (fake)", "", "", ""], ["", "", "", "", ""]];
    post = [["", "Closing balance", "99,999.99", "", ""], ["", "Total", money(lines.reduce(function (t, l) { return t + l.cents; }, 0), true), "", ""]];
    mapping.header_rows = pre.length + 1; all = pre.concat(all, post);
  }
  var text = all.map(function (row) { return row.map(function (c) { return q(c, delim); }).join(delim); }).join(layout === "us_dates" ? "\r\n" : "\n") + "\n";
  if (layout === "semicolon" || layout === "debit_credit") text = "﻿" + text;
  return { text: text, mapping: mapping, lines: lines, layout: layout, note: "layout assumed, not a real export" };
}
module.exports = { generate: generate, LAYOUTS: LAYOUTS, rng: rng };
