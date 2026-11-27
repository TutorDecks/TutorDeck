// Bank statement matching — the browser's side (T34 M0-M2). Pure functions, no DOM, no network: unit-tested in tests/statement-core.test.js.
//   parseCSV / detectDelimiter     the file → rows (BOM, quotes, "" inside quotes, CRLF, line breaks inside quotes)
//   parseDate / parseAmount        Singapore formats → "yyyy-mm-dd" and WHOLE CENTS (never parseFloat * 100; text goes through Money.parse)
//   validateMapping / applyMapping the saved column mapping → the lines the database takes (account numbers cut to their last 4 digits first)
//   normPayer / normRef / maskDigits / numberPattern   the same normalisation as db/migration_statement_matching.sql (shared vectors: tests/statement-vectors.csv)
//   score                          the matching rules A-D as the database applies them (db: stmt_run_rules). The DATABASE is the authority; this twin only
//                                  powers the upload preview ("n lines carry an invoice number") and the unit tests.
// BANK PRESETS: none ship. DBS/POSB, OCBC and UOB are listed in PRESETS as 'unverified' (column names expected from the plan, NOT checked against a real
// export); the app offers only the custom mapping until a real sample file has confirmed a preset (T34 M6).
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory(require("./money.js"));
  else root.StatementCore = factory(root.Money);
})(typeof self !== "undefined" ? self : this, function (Money) {
  "use strict";

  var DELIMS = [",", ";", "\t", "|"];
  var DATE_FORMATS = [
    ["dmy_slash", "31/12/2026", "day/month/year, with slashes"],
    ["dmy_dash", "31-12-2026", "day-month-year, with dashes or dots"],
    ["dmy_text", "31 Dec 2026", "day, month name, year"],
    ["iso", "2026-12-31", "year-month-day"],
    ["mdy_slash", "12/31/2026", "month/day/year (American)"]
  ];
  var AMOUNT_MODES = [
    ["signed", "One amount column (money out is negative)"],
    ["debit_credit", "Two columns: money out and money in"],
    ["amount_drcr", "An amount column and a Dr / Cr column"]
  ];
  // Presets are placeholders: the column names are the plan's expectation, NOT verified against a real export. Nothing here is offered in the app.
  var PRESETS = [
    { id: "DBS", label: "DBS / POSB", status: "unverified", columns: ["Transaction Date", "Debit Amount", "Credit Amount", "Transaction Ref1", "Transaction Ref2", "Transaction Ref3"] },
    { id: "OCBC", label: "OCBC", status: "unverified", columns: ["Transaction date", "Description", "Withdrawals", "Deposits"] },
    { id: "UOB", label: "UOB", status: "unverified", columns: ["Transaction Date", "Transaction Description", "Withdrawal", "Deposit"] }
  ];

  // ------------------------------------------------------------------------------------------------ CSV
  function parseCSV(text, delim) {
    text = String(text == null ? "" : text);
    if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1);
    delim = delim || ",";
    var rows = [], row = [], cell = "", i = 0, n = text.length, q = false, started = false;
    function endCell() { row.push(cell); cell = ""; started = false; }
    function endRow() { endCell(); rows.push(row); row = []; }
    while (i < n) {
      var c = text.charAt(i);
      if (q) {
        if (c === '"') { if (text.charAt(i + 1) === '"') { cell += '"'; i += 2; continue; } q = false; i++; continue; }
        cell += c; i++; continue;
      }
      if (c === '"' && !started) { q = true; started = true; i++; continue; }
      if (c === delim) { endCell(); i++; continue; }
      if (c === "\r") { endRow(); i += text.charAt(i + 1) === "\n" ? 2 : 1; continue; }
      if (c === "\n") { endRow(); i++; continue; }
      cell += c; started = true; i++;
    }
    if (cell !== "" || row.length || started) endRow();
    return rows;
  }

  // the separator that gives the most steady column count over the first lines; null when nothing looks like a table
  function detectDelimiter(text) {
    text = String(text == null ? "" : text).replace(/^﻿/, "");
    var best = null, bestScore = 0;
    DELIMS.forEach(function (d) {
      var rows = parseCSV(text.slice(0, 20000), d).filter(function (r) { return r.length > 1 || (r[0] || "").trim() !== ""; }).slice(0, 12);
      var counts = rows.map(function (r) { return r.length; });
      var max = Math.max.apply(null, counts.concat([0]));
      if (max < 2) return;
      var same = counts.filter(function (x) { return x === max; }).length;
      var score = same * 100 + max;
      if (score > bestScore) { best = d; bestScore = score; }
    });
    return best;
  }

  // ------------------------------------------------------------------------------------------------ dates and amounts
  var MONTHS = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12 };
  function iso(y, m, d) {
    y = +y; m = +m; d = +d;
    if (y < 100) y += 2000;
    if (!(m >= 1 && m <= 12 && d >= 1 && y >= 1990 && y <= 2100)) return null;
    var dim = [31, (y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0)) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1];
    if (d > dim) return null;
    return y + "-" + (m < 10 ? "0" : "") + m + "-" + (d < 10 ? "0" : "") + d;
  }
  function parseDate(text, format) {
    var s = String(text == null ? "" : text).trim().replace(/\s+\d{1,2}:\d{2}(:\d{2})?(\s*[AaPp][Mm])?$/, "");
    var m;
    if (format === "iso") { m = /^(\d{4})[-\/.](\d{1,2})[-\/.](\d{1,2})$/.exec(s); return m ? iso(m[1], m[2], m[3]) : null; }
    if (format === "dmy_slash") { m = /^(\d{1,2})\/(\d{1,2})\/(\d{4}|\d{2})$/.exec(s); return m ? iso(m[3], m[2], m[1]) : null; }
    if (format === "dmy_dash") { m = /^(\d{1,2})[-.](\d{1,2})[-.](\d{4}|\d{2})$/.exec(s); return m ? iso(m[3], m[2], m[1]) : null; }
    if (format === "mdy_slash") { m = /^(\d{1,2})\/(\d{1,2})\/(\d{4}|\d{2})$/.exec(s); return m ? iso(m[3], m[1], m[2]) : null; }
    if (format === "dmy_text") {
      m = /^(\d{1,2})[ \-\/.]+([A-Za-z]{3,9})\.?[ \-\/.,]+(\d{4}|\d{2})$/.exec(s);
      if (!m) return null;
      var mo = MONTHS[m[2].slice(0, 3).toLowerCase()];
      return mo ? iso(m[3], mo, m[1]) : null;
    }
    return null;
  }
  // "1,234.50" "S$12" "(12.00)" "12.00-" "-12" "12.00 CR" "12.00 Dr" → signed cents; null when it is not an amount. CR = money in, DR = money out.
  function parseAmount(text) {
    var s = String(text == null ? "" : text).trim();
    if (s === "") return null;
    var neg = false, tag = null, m;
    if ((m = /\s*\b(CR|DR)\.?$/i.exec(s))) { tag = m[1].toUpperCase(); s = s.slice(0, m.index); }
    s = s.trim();
    if (/^\(.*\)$/.test(s)) { neg = true; s = s.slice(1, -1).trim(); }
    if (/-$/.test(s)) { neg = !neg; s = s.slice(0, -1).trim(); }
    // strict: thousands commas only in groups of three ("12,50" would be a European decimal, not S$1,250), no spaces inside the number
    s = s.replace(/^(-?)\s*S?\$\s*/i, "$1");
    if (!/^-?((\d{1,3}(,\d{3})+)|\d+)?(\.\d{0,2})?$/.test(s)) return null;
    var c = Money.parse(s);
    if (c == null) return null;
    if (neg) c = -Math.abs(c);
    if (tag === "DR") c = -Math.abs(c); else if (tag === "CR") c = Math.abs(c);
    return c;
  }
  function fmtMoney(c) { return Money.format(c); }

  // ------------------------------------------------------------------------------------------------ normalisation (twin of the SQL helpers)
  function maskDigits(t) { return String(t == null ? "" : t).replace(/[0-9]{5,}([0-9]{4})/g, "****$1"); }
  function normPayer(t) { return String(t == null ? "" : t).toLowerCase().replace(/[^a-z0-9]+/g, " ").replace(/\s+/g, " ").trim(); }
  function normRef(t) { return normPayer(maskDigits(t)); }
  // the pattern that finds an invoice number in lower-cased reference text; INV-12 matches "inv 12", "INV-12", "inv12" but not "inv123" or "inv-1"
  function numberPattern(n) {
    var parts = String(n).toLowerCase().match(/[a-z]+|[0-9]+/g) || [];
    if (!parts.length) return null;
    return "(^|[^a-z0-9])" + parts.join("[^a-z0-9]*") + "([^a-z0-9]|$)";
  }

  // ------------------------------------------------------------------------------------------------ the mapping
  function isCol(v) { return v === 0 || (Number.isInteger(v) && v >= 0 && v <= 999); }
  function validateMapping(m) {
    var e = [];
    if (!m || typeof m !== "object") return ["Pick how to read the file."];
    if (DELIMS.indexOf(m.delimiter) < 0) e.push("Pick the column separator.");
    if (!(Number.isInteger(m.header_rows) && m.header_rows >= 0 && m.header_rows <= 99)) e.push("Say how many rows to skip above the table (0 to 99).");
    if (!DATE_FORMATS.some(function (f) { return f[0] === m.date_format; })) e.push("Pick the date format.");
    if (!isCol(m.date_col)) e.push("Pick the date column.");
    if (!AMOUNT_MODES.some(function (a) { return a[0] === m.amount_mode; })) e.push("Pick how amounts are laid out.");
    else if (m.amount_mode === "signed") { if (!isCol(m.amount_col)) e.push("Pick the amount column."); }
    else if (m.amount_mode === "debit_credit") { if (!isCol(m.debit_col)) e.push("Pick the money-out column."); if (!isCol(m.credit_col)) e.push("Pick the money-in column."); }
    else { if (!isCol(m.amount_col)) e.push("Pick the amount column."); if (!isCol(m.drcr_col)) e.push("Pick the Dr / Cr column."); }
    if (!Array.isArray(m.ref_cols) || m.ref_cols.length > 6 || !m.ref_cols.every(isCol)) e.push("Pick the reference column(s), at most 6.");
    if (m.payer_col != null && !isCol(m.payer_col)) e.push("The payer column must be a column number or empty.");
    if (m.bank_ref_col != null && !isCol(m.bank_ref_col)) e.push("The bank reference column must be a column number or empty.");
    return e;
  }
  function cell(row, i) { return i == null || i < 0 ? "" : String(row[i] == null ? "" : row[i]).trim(); }
  function colName(i) { var s = "", n = i + 1; while (n > 0) { var r = (n - 1) % 26; s = String.fromCharCode(65 + r) + s; n = Math.floor((n - 1) / 26); } return s; }

  // rows + mapping → { lines, errors, blank, footer, zero }. A line: { row, date, cents, ref, payer, bank_ref } (the shape stmt_import takes).
  function applyMapping(rows, m) {
    var out = { lines: [], errors: [], blank: 0, footer: 0, zero: 0 }, bad = validateMapping(m);
    if (bad.length) { out.errors.push({ row: 0, message: bad[0] }); return out; }
    for (var i = m.header_rows; i < rows.length; i++) {
      var r = rows[i], rn = i + 1;
      if (!r.some(function (c) { return String(c).trim() !== ""; })) { out.blank++; continue; }
      var dtxt = cell(r, m.date_col);
      if (dtxt === "" && m.skip_empty_date !== false) { out.footer++; continue; }                  // a totals / closing-balance row has no date
      var date = parseDate(dtxt, m.date_format);
      if (!date) { out.errors.push({ row: rn, message: "Row " + rn + ": the date “" + dtxt + "” doesn’t match the date format you picked (for example " + (DATE_FORMATS.filter(function (f) { return f[0] === m.date_format; })[0] || ["", "", ""])[1] + ")." }); continue; }
      var cents = null;
      if (m.amount_mode === "signed") cents = parseAmount(cell(r, m.amount_col));
      else if (m.amount_mode === "debit_credit") {
        var d = parseAmount(cell(r, m.debit_col)), c = parseAmount(cell(r, m.credit_col));
        if (d == null && c == null) cents = null;
        else cents = (c == null ? 0 : Math.abs(c)) - (d == null ? 0 : Math.abs(d));
      } else {
        var a = parseAmount(cell(r, m.amount_col)), tag = cell(r, m.drcr_col).toLowerCase();
        var inTag = String(m.drcr_in == null ? "CR" : m.drcr_in).toLowerCase();
        cents = a == null ? null : (tag === inTag || tag.charAt(0) === inTag.charAt(0) ? Math.abs(a) : -Math.abs(a));
      }
      if (cents == null) { out.errors.push({ row: rn, message: "Row " + rn + ": no amount that reads as money (“" + (cell(r, m.amount_mode === "debit_credit" ? m.credit_col : m.amount_col) || "empty") + "”)." }); continue; }
      if (m.invert) cents = -cents;
      if (cents === 0) out.zero++;
      var ref = (m.ref_cols || []).map(function (ci) { return cell(r, ci); }).filter(Boolean).join(" ");
      out.lines.push({ row: rn, date: date, cents: cents, ref: maskDigits(ref), payer: maskDigits(cell(r, m.payer_col)), bank_ref: maskDigits(cell(r, m.bank_ref_col)) });
    }
    return out;
  }
  function summarise(lines) {
    var s = { lines: lines.length, credits: 0, debits: 0, nIn: 0, nOut: 0, from: null, to: null };
    lines.forEach(function (l) {
      if (l.cents > 0) { s.credits += l.cents; s.nIn++; } else if (l.cents < 0) { s.debits -= l.cents; s.nOut++; }
      if (!s.from || l.date < s.from) s.from = l.date;
      if (!s.to || l.date > s.to) s.to = l.date;
    });
    return s;
  }

  // ------------------------------------------------------------------------------------------------ scoring (twin of stmt_run_rules)
  function dayNo(iso8) { var p = String(iso8).split("-"); return Math.round(Date.UTC(+p[0], +p[1] - 1, +p[2]) / 86400000); }
  function inWindow(date, inv, wb, wa) { var d = dayNo(date); return d >= dayNo(inv.issue) - wb && d <= dayNo(inv.due || inv.issue) + wa; }
  function subsets(bals, target) {         // how many combinations of at most 10 balances add up to target, and which one if exactly one
    var n = bals.length, cnt = 0, hit = 0;
    if (n < 1 || n > 10) return { count: 0, idx: [] };
    for (var mask = 1; mask < (1 << n); mask++) {
      var t = 0; for (var i = 0; i < n; i++) if (mask & (1 << i)) t += bals[i];
      if (t === target) { cnt++; hit = mask; }
    }
    var idx = []; if (cnt === 1) for (var j = 0; j < n; j++) if (hit & (1 << j)) idx.push(j);
    return { count: cnt, idx: idx };
  }
  // ctx: { today, settings: { auto_confirm, window_before_days, window_after_days }, invoices: [{id, number, hid, issue, due, bal}], links: { payerKey: householdId }, patterns? }
  // → { rule, exact, ids, household, reason, auto }.   The wording is the database's (tests compare them).
  function prepare(ctx) {
    if (!ctx._pat) ctx._pat = ctx.invoices.map(function (v) { var p = numberPattern(v.number); return { inv: v, re: p ? new RegExp(p) : null, compact: String(v.number).toLowerCase().replace(/[^a-z0-9]/g, "") }; })
      .sort(function (a, b) { return a.inv.number < b.inv.number ? -1 : a.inv.number > b.inv.number ? 1 : 0; });
    return ctx._pat;
  }
  function byOldest(a, b) { return a.issue < b.issue ? -1 : a.issue > b.issue ? 1 : (a.number < b.number ? -1 : a.number > b.number ? 1 : 0); }
  function score(line, ctx) {
    var st = ctx.settings || {}, wb = st.window_before_days == null ? 7 : st.window_before_days, wa = st.window_after_days == null ? 90 : st.window_after_days;
    var auto = st.auto_confirm || "exact_only", r = { rule: null, exact: false, ids: [], household: null, reason: null, auto: false };
    var amt = Money.format(Math.abs(line.cents)), rn = String(line.ref || "").toLowerCase(), compactRef = rn.replace(/[^a-z0-9]/g, ""), pk = normPayer(line.payer);
    function win(v) { return inWindow(line.date, v, wb, wa); }
    function done() {
      if (r.exact && (r.rule === "invoice_no" || r.rule === "payer_link")) {
        if (auto === "exact_only") r.auto = true; else r.reason += " Auto-confirm is off, so a person confirms.";
      }
      return r;
    }
    if (line.cents < 0) { r.reason = "Money out, so it is never matched automatically. Mark it \"not ours\" unless it is a refund."; return r; }
    if (line.date > ctx.today) { r.reason = "Dated in the future: wait until that day."; return r; }
    if (dayNo(line.date) < dayNo(ctx.today) - 1825) { r.reason = "Too old to record (over 5 years)."; return r; }
    // A
    var found = prepare(ctx).filter(function (p) { return p.re && compactRef.indexOf(p.compact) >= 0 && p.re.test(rn); }).map(function (p) { return p.inv; });
    if (found.length >= 2) {
      var tot = found.reduce(function (t, v) { return t + v.bal; }, 0);
      r.rule = "household_total"; r.ids = found.map(function (v) { return v.id; }); r.exact = tot === line.cents;
      r.reason = "More than one invoice number found (" + found.map(function (v) { return v.number; }).join(", ") + ")" + (r.exact ? ", and together they come to exactly " + amt + ". Check and confirm." : ". Choose which one this is for.");
      return r;
    }
    if (found.length === 1) {
      var o = found[0]; r.rule = "invoice_no"; r.ids = [o.id]; r.household = o.hid;
      if (o.bal === 0) r.reason = o.number + " found, but it is already paid.";
      else if (!win(o)) r.reason = o.number + " found, but the date is outside the allowed window (" + wb + " days before it was issued to " + wa + " days after it was due).";
      else if (line.cents === o.bal) { r.exact = true; r.reason = o.number + " found, exact amount."; }
      else if (line.cents < o.bal) r.reason = o.number + " found, but " + Money.format(o.bal - line.cents) + " short.";
      else r.reason = o.number + " found, but " + Money.format(line.cents - o.bal) + " over.";
      return done();
    }
    // B
    var hh = pk && ctx.links ? ctx.links[pk.slice(0, 120)] : null;
    var open = ctx.invoices.filter(function (v) { return v.bal > 0 && win(v); }).sort(byOldest);
    if (hh) {
      r.household = hh;
      var same = open.filter(function (v) { return v.hid === hh && v.bal === line.cents; });
      if (same.length === 1) { r.rule = "payer_link"; r.exact = true; r.ids = [same[0].id]; r.reason = "Known payer, exact amount."; return done(); }
      if (same.length >= 2) { r.rule = "payer_link"; r.ids = same.map(function (v) { return v.id; }); r.reason = "Known payer, but " + same.length + " invoices of this family are exactly " + amt + ". Choose one."; return r; }
      var fam = open.filter(function (v) { return v.hid === hh; });
      if (fam.length === 1) { r.rule = "payer_link"; r.ids = [fam[0].id]; r.reason = "Known payer. Their open invoice is " + Money.format(fam[0].bal) + ", this is " + (line.cents < fam[0].bal ? Money.format(fam[0].bal - line.cents) + " short." : Money.format(line.cents - fam[0].bal) + " over."); return r; }
      if (fam.length > 10) { r.reason = "Known payer, but the family has more than 10 open invoices. Choose by hand."; return r; }
      if (fam.length >= 2) {
        var sub = subsets(fam.map(function (v) { return v.bal; }), line.cents);
        if (sub.count === 1) { r.rule = "household_total"; r.exact = true; r.ids = sub.idx.map(function (k) { return fam[k].id; }); r.reason = "Known payer. This equals " + r.ids.length + " of the family's open invoices. Check and confirm."; return r; }
        if (sub.count > 1) { r.reason = "Known payer, but several combinations of the family's invoices come to " + amt + ". Choose by hand."; return r; }
      }
      r.reason = "Known payer, but no open invoice of exactly " + amt + "."; return r;
    }
    // C
    var amtOnly = open.filter(function (v) { return v.bal === line.cents; });
    if (amtOnly.length === 1) { r.rule = "amount_only"; r.exact = true; r.ids = [amtOnly[0].id]; r.household = amtOnly[0].hid; r.reason = "Only one invoice is owed for exactly " + amt + ", but there is no invoice number or known payer. Check and confirm."; return r; }
    if (amtOnly.length >= 2) { r.rule = "amount_only"; r.ids = amtOnly.slice(0, 10).map(function (v) { return v.id; }); r.reason = amtOnly.length + " invoices are owed for exactly " + amt + ". Choose which family this is."; return r; }
    // D
    var groups = {};
    open.forEach(function (v) { if (v.hid) (groups[v.hid] = groups[v.hid] || []).push(v); });
    var hit = Object.keys(groups).filter(function (h) { var g = groups[h]; return g.length >= 2 && g.length <= 10 && g.reduce(function (t, v) { return t + v.bal; }, 0) === line.cents; });
    if (hit.length === 1) { r.rule = "household_total"; r.exact = true; r.household = hit[0]; r.ids = groups[hit[0]].map(function (v) { return v.id; }); r.reason = "This equals everything one family owes (" + r.ids.length + " invoices). Check and confirm."; return r; }
    if (hit.length >= 2) { r.reason = "More than one family owes a total of exactly " + amt + ". Choose which."; return r; }
    r.reason = ctx.invoices.some(function (v) { return v.bal > 0; }) ? "No invoice matches " + amt + ". Add the invoice number to the reference, or choose the invoice." : "No open invoice yet.";
    return r;
  }

  // a first guess for a file nobody has mapped yet: the header row is the first one with a "date" cell; columns are found by the words in the headers; the
  // date format is the first one that reads the first dates. Always shown to the person to check (the preview), never trusted blindly.
  function guessMapping(rows, delimiter) {
    var m = { delimiter: delimiter || ",", header_rows: 1, date_col: 0, date_format: "dmy_slash", amount_mode: "signed", amount_col: 1, ref_cols: [], payer_col: null, bank_ref_col: null, skip_empty_date: true };
    var hi = -1, i, j;
    for (i = 0; i < Math.min(rows.length, 40) && hi < 0; i++) if (rows[i].length >= 3 && rows[i].some(function (c) { return /date/i.test(c); })) hi = i;
    if (hi < 0) hi = 0;
    m.header_rows = hi + 1;
    var h = (rows[hi] || []).map(function (c) { return String(c || "").trim(); });
    function find(re, not) { for (var k = 0; k < h.length; k++) if (re.test(h[k]) && !(not && not.test(h[k]))) return k; return null; }
    var d = find(/date/i, /value|post/i); if (d == null) d = find(/date/i); if (d != null) m.date_col = d;
    var deb = find(/debit|withdraw|money out|paid out/i), cre = find(/credit|deposit|money in|paid in/i), amt = find(/^(txn |transaction )?amount|^amt/i), dc = find(/^dr ?\/ ?cr|^cr ?\/ ?dr|^type$|indicator/i);
    if (deb != null && cre != null) { m.amount_mode = "debit_credit"; m.debit_col = deb; m.credit_col = cre; delete m.amount_col; }
    else if (amt != null && dc != null) { m.amount_mode = "amount_drcr"; m.amount_col = amt; m.drcr_col = dc; }
    else m.amount_col = amt != null ? amt : (cre != null ? cre : 1);
    var refs = [], used = [m.date_col, m.amount_col, m.debit_col, m.credit_col, m.drcr_col].filter(function (x) { return x != null; });
    var pay = find(/payer|sender|from|remitter|name/i), bref = find(/(bank|txn|transaction|customer) ?(ref|id|no)|^ref(erence)? ?(no|num|id)/i);
    if (pay != null) m.payer_col = pay;
    if (bref != null && bref !== pay) m.bank_ref_col = bref;
    for (j = 0; j < h.length; j++) if (/desc|detail|particular|narrat|remark|reference|ref\b|message|note/i.test(h[j]) && used.indexOf(j) < 0 && j !== m.payer_col && j !== m.bank_ref_col) refs.push(j);
    m.ref_cols = refs.slice(0, 6);
    var fmts = ["dmy_slash", "dmy_dash", "dmy_text", "iso", "mdy_slash"], sample = [];
    for (i = hi + 1; i < rows.length && sample.length < 8; i++) { var c = String(rows[i][m.date_col] || "").trim(); if (c) sample.push(c); }
    var best = null, bestN = 0;
    fmts.forEach(function (f) { var n = sample.filter(function (c) { return parseDate(c, f); }).length; if (n > bestN) { best = f; bestN = n; } });
    if (best) m.date_format = best;
    return m;
  }

  return { guessMapping: guessMapping, DELIMS: DELIMS, DATE_FORMATS: DATE_FORMATS, AMOUNT_MODES: AMOUNT_MODES, PRESETS: PRESETS, parseCSV: parseCSV, detectDelimiter: detectDelimiter, parseDate: parseDate,
    parseAmount: parseAmount, fmtMoney: fmtMoney, maskDigits: maskDigits, normPayer: normPayer, normRef: normRef, numberPattern: numberPattern, validateMapping: validateMapping,
    applyMapping: applyMapping, summarise: summarise, score: score, colName: colName, dayNo: dayNo };
});
