// Import core (T33 step I0): everything about reading and checking the centre import files, with NO database and NO network.
// Pure and dependency-free: works in the browser (window.ImportCore) and under `node --test` (tests/import-core.test.js).
//   readCsv(text)              → records (quotes, BOM, CRLF, embedded commas and newlines, size guard)
//   FILES / templateCsv / readmeText → the six templates (and "past lessons", marked later) from ONE source of truth
//   validateFiles([{name,text}]) → { errors, warnings, notes, summary, ready, ... }  (every problem: file, line, column, value, what, fix)
// Rules come from docs/orchestrator/T33-plan.md sections 1 and 2. Money is integer cents only (never floats).
// Line numbers are SPREADSHEET rows: the header is line 1, and blank or "#" comment rows still count.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.ImportCore = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  var MAX_CHARS = 5 * 1024 * 1024;                       // size guard per file (about 5 MB of text)
  var LEVELS = ["K1", "K2", "P1", "P2", "P3", "P4", "P5", "P6", "S1", "S2", "S3", "S4", "S5", "JC1", "JC2", "Poly", "Uni", "Adult", "Other"];
  var DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
  var DAY_LONG = { monday: "Mon", tuesday: "Tue", wednesday: "Wed", thursday: "Thu", friday: "Fri", saturday: "Sat", sunday: "Sun" };
  var FORBIDDEN = /nric|birth|dob|bank|account|passport|paynow/;   // column names TutorDeck never takes
  var PAY_METHODS = ["per_lesson", "per_hour", "monthly_fixed", "percent_of_fee"];
  var EMAIL_RE = /^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$/;

  // ------------------------------------------------------------------ small helpers
  function len(s) { return Array.from(s).length; }
  function pad2(n) { return (n < 10 ? "0" : "") + n; }
  function norm(h) { return String(h == null ? "" : h).trim().replace(/\*$/, "").trim().toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, ""); }
  function shorten(v, n) { v = String(v == null ? "" : v).replace(/[\r\n]+/g, " "); return v.length > (n || 80) ? v.slice(0, (n || 80) - 1) + "…" : v; }

  // ------------------------------------------------------------------ CSV reader
  // Returns { records: [{ line, cells: [..] }], error }. line = the record number (header = 1).
  function readCsv(text, opts) {
    var max = (opts && opts.maxChars) || MAX_CHARS;
    text = String(text == null ? "" : text);
    if (text.length > max) return { records: [], error: { code: "FILE_TOO_BIG", message: "The file is bigger than " + Math.round(max / 1048576) + " MB.", fix: "Split it into smaller files, or remove columns you do not need." } };
    if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1);
    // delimiter: the commonest of , ; tab in the first line outside quotes (Excel in some regions saves with ;)
    var counts = { ",": 0, ";": 0, "\t": 0 }, q = false, i, c;
    for (i = 0; i < text.length; i++) {
      c = text[i];
      if (c === '"') q = !q; else if (!q && (c === "\n" || c === "\r")) break; else if (!q && counts[c] !== undefined) counts[c]++;
    }
    var delim = ","; if (counts[";"] > counts[delim]) delim = ";"; if (counts["\t"] > counts[delim]) delim = "\t";
    var records = [], rec = [], field = "", inQ = false, openedAt = 0, n = text.length, lineNo = 1;
    function endRecord() { rec.push(field); records.push({ line: lineNo, cells: rec }); rec = []; field = ""; lineNo++; }
    for (i = 0; i < n; i++) {
      c = text[i];
      if (inQ) {
        if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else inQ = false; } else field += c;
      } else if (c === '"' && field === "") { inQ = true; openedAt = lineNo; }
      else if (c === delim) { rec.push(field); field = ""; }
      else if (c === "\n" || c === "\r") { if (c === "\r" && text[i + 1] === "\n") i++; endRecord(); }
      else field += c;
    }
    if (inQ) return { records: records, error: { code: "OPEN_QUOTE", line: openedAt, message: 'A quote mark opened on line ' + openedAt + ' is never closed.', fix: "Close the quote, or remove the stray \" from that cell." } };
    if (field !== "" || rec.length) endRecord();
    return { records: records, delimiter: delim };
  }

  // rows → CSV text (for templates and the errors download). safe: stop spreadsheets running a cell as a formula.
  function toCsv(rows, safe) {
    return rows.map(function (r) {
      return r.map(function (v) {
        v = v == null ? "" : String(v);
        if (safe && /^[=+\-@\t\r]/.test(v)) v = "'" + v;
        return /[",\r\n]|^\s|\s$/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v;
      }).join(",");
    }).join("\r\n") + "\r\n";
  }

  // ------------------------------------------------------------------ value parsers (each returns a value or null)
  function realDate(y, m, d) {
    if (y < 2000 || y > 2100 || m < 1 || m > 12 || d < 1 || d > 31) return null;
    var t = new Date(Date.UTC(y, m - 1, d));
    return t.getUTCFullYear() === y && t.getUTCMonth() === m - 1 && t.getUTCDate() === d ? y + "-" + pad2(m) + "-" + pad2(d) : null;
  }
  function parseDate(s) {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
    if (m) return realDate(+m[1], +m[2], +m[3]);
    m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(s);          // day first, never month first
    return m ? realDate(+m[3], +m[2], +m[1]) : null;
  }
  function parseTime(s) {                                    // → minutes since midnight
    var m = /^(\d{1,2}):(\d{2})$/.exec(s);
    return m && +m[1] <= 23 && +m[2] <= 59 ? +m[1] * 60 + +m[2] : null;
  }
  // dollars → integer cents, from the TEXT: digits and an optional 1-2 digit decimal part. No "$", no commas, never parseFloat.
  function parseCents(s) {
    var m = /^(\d{1,9})(?:\.(\d{1,2}))?$/.exec(s);
    return m ? Number(m[1]) * 100 + Number(((m[2] || "") + "00").slice(0, 2)) : null;
  }
  function fmtTime(min) { return pad2(Math.floor(min / 60)) + ":" + pad2(min % 60); }
  function fmtMoney(cents) {
    var neg = cents < 0, a = Math.abs(cents);
    return (neg ? "-" : "") + "S$" + String(Math.floor(a / 100)).replace(/\B(?=(\d{3})+(?!\d))/g, ",") + "." + pad2(a % 100);
  }
  function addDays(iso, days) { var d = new Date(iso + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + days); return d.getUTCFullYear() + "-" + pad2(d.getUTCMonth() + 1) + "-" + pad2(d.getUTCDate()); }
  function localToday() { var d = new Date(); return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate()); }
  function suggestLevel(raw) {
    var s = String(raw).toLowerCase().replace(/[^a-z0-9]/g, ""), m;
    if ((m = /^(?:k|kindergarten|kg)([12])$/.exec(s))) return "K" + m[1];
    if ((m = /^(?:p|pri|primary)([1-6])$/.exec(s))) return "P" + m[1];
    if ((m = /^(?:s|sec|secondary)([1-5])$/.exec(s))) return "S" + m[1];
    if ((m = /^(?:jc|j)([12])$/.exec(s))) return "JC" + m[1];
    if (/^(poly|polytechnic)$/.test(s)) return "Poly";
    if (/^(uni|university)$/.test(s)) return "Uni";
    if (/^adult$/.test(s)) return "Adult";
    return null;
  }

  // ------------------------------------------------------------------ the templates (one source of truth)
  // col: name, req (required), type, max, rule (plain words for the how-to table and the README), ex (example cell; first row starts with "#")
  function C(name, req, type, rule, ex, extra) { var c = { name: name, req: !!req, type: type, rule: rule, ex: ex }; if (extra) for (var k in extra) c[k] = extra[k]; return c; }
  var FILES = {
    families: {
      key: "families", file: "families.csv", stage: "A", title: "Families and guardians", limit: 18000,
      what: "One row per parent or guardian. Brothers and sisters share the same family_ref.",
      cols: [
        C("family_ref", true, "ref", "Your own code for the family, the same on every row of that family. Up to 40 characters.", "#F001"),
        C("family_name", true, "text", "Up to 120 characters. The same on every row of the family.", "Tan family", { max: 120 }),
        C("guardian_name", true, "text", "Up to 120 characters.", "Mary Tan", { max: 120 }),
        C("relation", false, "text", "Mother, Father, Guardian or Other. Up to 40 characters.", "Mother", { max: 40 }),
        C("phone", false, "phone", "6 to 15 digits. +65 is optional.", "9123 4501"),
        C("email", false, "email", "A real email address.", "mary.tan@example.test"),
        C("main", false, "yn", "Y or N. The main contact of the family. Blank means the first row.", "Y")
      ]
    },
    students: {
      key: "students", file: "students.csv", stage: "A", title: "Students", limit: 3000,
      what: "One row per student who is still having lessons. Students who have left are not imported.",
      cols: [
        C("student_ref", true, "ref", "Your own student number, never changed between runs. Up to 40 characters.", "#S0001"),
        C("family_ref", true, "ref", "Must be a family in families.csv.", "F001"),
        C("student_name", true, "text", "Up to 120 characters.", "Ethan Tan", { max: 120 }),
        C("level", false, "level", "K1, K2, P1 to P6, S1 to S5, JC1, JC2, Poly, Uni, Adult or Other. Anything else is kept as typed, with a warning.", "P5"),
        C("lesson_location", false, "text", "Up to 120 characters, for example Online.", "Online", { max: 120 }),
        C("online_link", false, "url", "A link starting with https://", "https://meet.example.test/e1"),
        C("start_date", true, "date", "The first lesson date. YYYY-MM-DD or DD/MM/YYYY (day first). Not more than a year ahead.", "2026-01-12"),
        C("notes", false, "text", "Up to 1,000 characters.", "Prefers mornings", { max: 1000 })
      ]
    },
    tutors: {
      key: "tutors", file: "tutors.csv", stage: "A", title: "Tutors", limit: 1500,
      what: "One row per tutor. Each tutor is saved as an invitation. No email is sent by the import.",
      cols: [
        C("tutor_email", true, "email", "The tutor's email. It is their key, so it must be unique.", "#ava.lim@example.test"),
        C("tutor_name", true, "text", "Up to 120 characters.", "Ava Lim", { max: 120 }),
        C("phone", false, "phone_sg", "A Singapore number: 8 digits starting with 6, 8 or 9. +65 is optional.", "9100 0001"),
        C("subjects", false, "text", "Separate with ; and keep it under 200 characters. Shown only.", "Maths;Science", { max: 200 }),
        C("employment", true, "enum", "employee or freelancer.", "freelancer", { values: ["employee", "freelancer"] }),
        C("pay_method", false, "enum", "per_lesson, per_hour, monthly_fixed or percent_of_fee. Fill in pay_method, pay_amount and pay_from together, or leave all three empty.", "per_hour", { values: PAY_METHODS }),
        C("pay_amount", false, "pay", "Dollars (28 or 28.00), or for percent_of_fee a percentage from 0 to 100 (up to 2 decimals).", "28.00"),
        C("pay_from", false, "date", "The date this pay starts.", "2026-12-01")
      ]
    },
    weekly_lessons: {
      key: "weekly_lessons", file: "weekly_lessons.csv", stage: "A", title: "Weekly lessons", limit: 20000,
      what: "One row per weekly 1-to-1 lesson slot.",
      cols: [
        C("student_ref", true, "ref", "Must be a student in students.csv.", "#S0001"),
        C("tutor_email", true, "email", "Must be a tutor in tutors.csv.", "ava.lim@example.test"),
        C("day", true, "enum", "Mon, Tue, Wed, Thu, Fri, Sat or Sun.", "Mon", { values: DAYS }),
        C("start", true, "time", "24-hour time, HH:MM.", "16:00"),
        C("end", true, "time", "24-hour time, HH:MM. The lesson is 15 minutes to 8 hours long.", "17:30"),
        C("subject", false, "text", "Up to 60 characters.", "Mathematics", { max: 60 }),
        C("level", false, "level", "Blank means the student's level.", "P5"),
        C("family_rate_per_hour", true, "rate", "What the family pays for one hour, in dollars, 0 to 1,000. Never the tutor's pay.", "55.00")
      ]
    },
    deposits: {
      key: "deposits", file: "deposits.csv", stage: "B", title: "Deposits held", limit: 3000,
      what: "One row per deposit the centre is still holding. If part was refunded, enter what is left.",
      cols: [
        C("student_ref", true, "ref", "Must be a student in students.csv.", "#S0001"),
        C("amount", true, "money", "Dollars held now, more than 0.", "275.00"),
        C("received_date", true, "date", "The day it was received. Not in the future.", "2026-10-05"),
        C("reference", false, "text", "Up to 60 characters. Never an account number.", "PayNow Oct", { max: 60 })
      ]
    },
    unpaid_invoices: {
      key: "unpaid_invoices", file: "unpaid_invoices.csv", stage: "B", title: "Unpaid invoices", limit: 3000,
      what: "One row per invoice that is unpaid or part-paid. Lessons are not imported, only the amounts owed.",
      cols: [
        C("invoice_number", true, "text", "The centre's old invoice number, up to 30 characters. Unique.", "#OLD-0412", { max: 30 }),
        C("family_ref", true, "ref", "Must be a family in families.csv.", "F001"),
        C("invoice_date", true, "date", "The date of the invoice.", "2026-11-01"),
        C("due_date", false, "date", "The date it was due.", "2026-11-08"),
        C("amount", true, "money", "The original total in dollars, more than 0.", "220.00"),
        C("paid_so_far", false, "money0", "Dollars already paid. Blank means 0. Must be less than amount.", "0.00"),
        C("covers", false, "text", "What it was for, in plain words. Up to 300 characters.", "Nov 2026 4 lessons Ethan", { max: 300 }),
        C("student_ref", false, "ref", "Optional. A student of that family.", "S0001")
      ]
    },
    past_lessons: {
      key: "past_lessons", file: "past_lessons.csv", stage: "later", title: "Past lessons", limit: 0,
      what: "Not part of the first import.",
      cols: [C("student_ref", true, "ref", "", ""), C("tutor_email", true, "email", "", ""), C("date", true, "date", "", ""), C("start", true, "time", "", ""),
        C("end", true, "time", "", ""), C("attendance", true, "enum", "", ""), C("charge", false, "money", "", ""), C("family_rate_per_hour", false, "rate", "", "")]
    }
  };
  var FILE_ORDER = ["families", "students", "tutors", "weekly_lessons", "deposits", "unpaid_invoices", "past_lessons"];
  var STAGE_A = ["families", "students", "tutors", "weekly_lessons"];

  function templateRows(key) {
    var f = FILES[key];
    return [f.cols.map(function (c) { return c.name; }), f.cols.map(function (c) { return c.ex; })];
  }
  // header row, then one example row that starts with "#" (readers skip it). UTF-8 BOM so Excel shows every character.
  function templateCsv(key) { return "﻿" + toCsv(templateRows(key)); }

  function readmeText() {
    var L = [];
    L.push("TutorDeck import templates", "===========================", "",
      "How it works",
      "1. Fill in the templates from your own sheets. One file per kind of record. Any column order is fine.",
      "2. Upload the files on the Import page. TutorDeck checks every row and tells you the line, the column and how to fix it.",
      "3. Your files are read inside your browser and never sent anywhere in this step.", "",
      "Rules for every file",
      "- Save as CSV UTF-8. The first row holds the column names exactly as in the template.",
      "- The grey example row starts with # . Delete it or leave it: rows starting with # are ignored.",
      "- Dates: YYYY-MM-DD (2026-01-12) or DD/MM/YYYY (12/01/2026). Day first, never month first.",
      "- Times: 24-hour HH:MM (16:00).",
      "- Money: dollars with up to 2 decimals (55 or 55.50). No $ sign and no commas.",
      "- Y or N for yes/no columns.",
      "- Every *_ref is a code you invent (your own student number, or the row number). Never change a ref between runs.",
      "- Do not add columns for NRIC, date of birth, bank or account details. TutorDeck never takes them.", "");
    FILE_ORDER.forEach(function (k) {
      var f = FILES[k];
      if (f.stage === "later") { L.push(f.file + " (later)", "  Past lessons are not part of the first import.", ""); return; }
      L.push(f.file + "  (" + f.title + (f.stage === "B" ? ", money files: can be added after the first import" : "") + ")", "  " + f.what);
      f.cols.forEach(function (c) { L.push("  " + c.name + (c.req ? " *" : "") + ": " + c.rule + "   e.g. " + c.ex.replace(/^#/, "")); });
      L.push("");
    });
    L.push("* = required. All names, numbers and emails in these examples are made up.", "");
    return L.join("\r\n");
  }

  // ------------------------------------------------------------------ read one file into a table
  function detectFile(headers) {
    var best = null, score = 0, tie = false, set = {};
    headers.forEach(function (h) { set[h] = 1; });
    FILE_ORDER.forEach(function (k) {
      var f = FILES[k];
      if (!f.cols.every(function (c) { return !c.req || set[c.name]; })) return;
      var s = f.cols.filter(function (c) { return set[c.name]; }).length;
      if (s > score) { best = k; score = s; tie = false; } else if (s === score) tie = true;
    });
    return tie ? null : best;
  }
  function closest(headers) {
    var set = {}, best = null, bestN = 0;
    headers.forEach(function (h) { set[h] = 1; });
    FILE_ORDER.forEach(function (k) {
      var n = FILES[k].cols.filter(function (c) { return set[c.name]; }).length;
      if (FILES[k].stage !== "later" && n > bestN) { best = k; bestN = n; }
    });
    return bestN >= 2 ? best : null;
  }

  // which template a file's text is (by its header row), or null
  function detectText(text) {
    var rd = readCsv(text), i = 0;
    if (rd.error) return null;
    while (i < rd.records.length && rd.records[i].cells.every(function (c) { return String(c).trim() === ""; })) i++;
    return i < rd.records.length ? detectFile(rd.records[i].cells.map(norm)) : null;
  }

  // ------------------------------------------------------------------ validation
  function validateFiles(inputs, opts) {
    var t0 = typeof performance !== "undefined" ? performance.now() : Date.now();
    opts = opts || {};
    var today = opts.today || localToday(), maxFuture = addDays(today, 365);
    var existing = opts.existing || {};
    var issues = [], tables = {}, fileInfo = [];
    var order = {};
    FILE_ORDER.forEach(function (k, i) { order[k] = i; });

    function issue(sev, file, line, column, value, code, message, fix) {
      issues.push({ severity: sev, file: file, line: line, column: column || "", value: value == null ? "" : shorten(value), code: code, message: message, fix: fix || "" });
    }

    // ---- 1. file level
    inputs.forEach(function (inp) {
      var name = inp.name || "file.csv", info = { name: name, key: null, rows: 0, status: "ok" };
      fileInfo.push(info);
      var rd = inp.tooBig ? { records: [], error: { code: "FILE_TOO_BIG", message: "The file is bigger than " + Math.round(MAX_CHARS / 1048576) + " MB.", fix: "Split it into smaller files, or remove columns you do not need." } } : readCsv(inp.text, opts);
      if (rd.error) { info.status = "error"; issue("error", name, rd.error.line || 1, "", "", rd.error.code, rd.error.message, rd.error.fix); return; }
      var recs = rd.records, h = 0;
      while (h < recs.length && recs[h].cells.every(function (c) { return String(c).trim() === ""; })) h++;
      if (h >= recs.length) { info.status = "error"; issue("error", name, 1, "", "", "EMPTY_FILE", "The file is empty.", "Add the column names in the first row, or choose another file."); return; }
      var headers = recs[h].cells.map(norm), headLine = recs[h].line;
      var key = detectFile(headers);
      if (!key) {
        info.status = "error"; var near = closest(headers);
        if (near) {
          var missingCols = FILES[near].cols.filter(function (c) { return c.req && headers.indexOf(c.name) < 0; }).map(function (c) { return c.name; });
          issue("error", name, headLine, "", "", "MISSING_COLUMN", "This looks like " + FILES[near].file + " but " + (missingCols.length > 1 ? "these columns are missing: " : "this column is missing: ") + missingCols.join(", ") + ".",
            "Add " + (missingCols.length > 1 ? "them" : "it") + " to the first row, or start again from the template.");
        } else issue("error", name, headLine, "", "", "UNKNOWN_FILE", "TutorDeck cannot tell which template this is from its first row.", "Download the template again and paste your data under its column names.");
        return;
      }
      info.key = key;
      if (FILES[key].stage === "later") { info.status = "later"; issue("note", name, 1, "", "", "LATER", "Past lessons are not part of the first import, so this file is ignored.", "Nothing to do. Remove it if you like."); return; }
      if (tables[key]) { info.status = "error"; issue("error", name, 1, "", "", "DUPLICATE_FILE", "There are two " + FILES[key].file + " files (" + tables[key].name + " and this one).", "Upload only one file for each template."); return; }
      var f = FILES[key], seenCol = {}, colOk = true;
      headers.forEach(function (hd, i) {
        var raw = String(recs[h].cells[i]).trim();
        if (hd === "") { if (raw !== "") issue("warning", name, headLine, "", raw, "UNKNOWN_COLUMN", "A column with no usable name is ignored.", "Give it a name from the template, or delete it."); return; }
        if (FORBIDDEN.test(hd)) { issue("error", name, headLine, raw, raw, "FORBIDDEN_COLUMN", 'The column "' + raw + '" is not allowed.', "Remove this column. TutorDeck never takes NRIC, birth dates or bank details."); return; }
        if (seenCol[hd]) { issue("error", name, headLine, raw, raw, "DUPLICATE_COLUMN", 'The column "' + raw + '" appears twice.', "Delete one of them."); return; }
        seenCol[hd] = true;
        if (!f.cols.some(function (c) { return c.name === hd; })) issue("warning", name, headLine, raw, raw, "UNKNOWN_COLUMN", 'The column "' + raw + '" is not part of the template, so it is ignored.', "Remove it, or ignore this warning.");
      });
      f.cols.forEach(function (c) { if (c.req && !seenCol[c.name]) { colOk = false; issue("error", name, headLine, c.name, "", "MISSING_COLUMN", 'The required column "' + c.name + '" is missing.', "Add it to the first row, or start again from the template."); } });
      if (!colOk) { info.status = "error"; return; }
      var rows = [], skipped = [];
      for (var r = h + 1; r < recs.length; r++) {
        var cells = recs[r].cells;
        if (cells.every(function (c) { return String(c).trim() === ""; })) continue;                // blank row
        if (String(cells[0]).trim().charAt(0) === "#") { skipped.push(recs[r].line); continue; }      // comment (example) row
        if (cells.length > headers.length && cells.slice(headers.length).some(function (c) { return String(c).trim() !== ""; })) {
          issue("error", name, recs[r].line, "", "", "TOO_MANY_CELLS", "This row has " + cells.length + " cells but the first row has " + headers.length + ".", "A comma inside a name or note must be wrapped in quotes, for example \"Tan, Mary\".");
          continue;
        }
        var obj = {};
        headers.forEach(function (hd, i) { if (hd && !FORBIDDEN.test(hd) && obj[hd] === undefined) obj[hd] = i < cells.length ? String(cells[i]).trim() : ""; });
        rows.push({ line: recs[r].line, c: obj, v: {}, bad: false });
      }
      info.rows = rows.length;
      if (skipped.length) issue("note", name, skipped[0], "", "", "COMMENT_SKIPPED", skipped.length + (skipped.length === 1 ? " row starts" : " rows start") + " with # and " + (skipped.length === 1 ? "was" : "were") + " skipped as a comment (line" + (skipped.length === 1 ? " " : "s ") + skipped.slice(0, 5).join(", ") + (skipped.length > 5 ? ", …" : "") + ").", "That is right for the grey example row. If a real row starts with #, remove the # from it.");
      if (rows.length > f.limit) { info.status = "error"; issue("error", name, 1, "", rows.length, "TOO_MANY_ROWS", "There are " + rows.length + " rows; one import takes up to " + f.limit.toLocaleString("en-SG") + " for this file.", "Split it into two files and import them one after the other."); return; }
      tables[key] = { name: name, key: key, rows: rows };
    });

    // ---- 2. row level (types, lengths, allowed values)
    function colIssue(t, row, col, code, msg, fix, sev) { row.bad = row.bad || (sev || "error") === "error"; issue(sev || "error", t.name, row.line, col.name, row.c[col.name], code, msg, fix); }
    Object.keys(tables).forEach(function (key) {
      var t = tables[key], f = FILES[key];
      t.rows.forEach(function (row) {
        f.cols.forEach(function (col) {
          var s = row.c[col.name] || "", v = null, n;
          if (s === "") {
            if (col.req) colIssue(t, row, col, "REQUIRED", "is empty, but this column is required.", "Fill it in.");
            row.v[col.name] = null; return;
          }
          switch (col.type) {
            case "ref":
              if (len(s) > 40) colIssue(t, row, col, "TOO_LONG", "is " + len(s) + " characters; the limit is 40.", "Use a shorter code.");
              else v = s;
              break;
            case "text":
              if (len(s) > col.max) colIssue(t, row, col, "TOO_LONG", "is " + len(s) + " characters; the limit is " + col.max + ".", "Shorten it to " + col.max + " characters or fewer.");
              else v = s;
              break;
            case "level":
              if (len(s) > 40) { colIssue(t, row, col, "TOO_LONG", "is " + len(s) + " characters; the limit is 40.", "Shorten it to 40 characters or fewer."); break; }
              v = s;
              var hit = LEVELS.filter(function (l) { return l.toLowerCase() === s.toLowerCase(); })[0];
              if (hit) v = hit;
              else { var sg = suggestLevel(s); colIssue(t, row, col, "UNKNOWN_LEVEL", "is not recognised.", sg ? "Use " + sg + "." : "Use one of " + LEVELS.join(", ") + ". It is kept as typed if you leave it.", "warning"); }
              break;
            case "email":
              if (!EMAIL_RE.test(s) || len(s) > 254) colIssue(t, row, col, "BAD_EMAIL", "is not a valid email address.", "Write it like name@example.com, one address only.");
              else v = s.toLowerCase();
              break;
            case "url":
              if (!/^https:\/\/[^\s/]+\.[^\s/]+\S*$/i.test(s) || len(s) > 300) colIssue(t, row, col, "BAD_URL", "is not a link starting with https://", "Paste the full link, starting with https://");
              else v = s;
              break;
            case "phone": {
              var d = s.replace(/[\s\-()]/g, "");
              if (/^\+?\d{6,15}$/.test(d)) v = d; else colIssue(t, row, col, "BAD_PHONE", "is not a phone number.", "Use 6 to 15 digits, for example 9123 4501 or +65 9123 4501.");
              break;
            }
            case "phone_sg": {
              var d2 = s.replace(/[\s\-()]/g, ""), m2 = /^(?:\+?65)?([689]\d{7})$/.exec(d2);
              if (m2) v = "+65" + m2[1]; else colIssue(t, row, col, "BAD_PHONE", "is not a Singapore mobile or landline number.", "Use 8 digits starting with 6, 8 or 9, for example 9100 0001 (+65 is optional).");
              break;
            }
            case "yn": {
              var yl = s.toLowerCase();
              if (yl === "y" || yl === "yes") v = true; else if (yl === "n" || yl === "no") v = false; else colIssue(t, row, col, "BAD_YN", "must be Y or N.", "Write Y or N, or leave it empty.");
              break;
            }
            case "enum": {
              var low = s.toLowerCase().replace(/\s+/g, "_");
              var vals = col.values;
              if (col.name === "day") { var dd = DAYS.filter(function (x) { return x.toLowerCase() === low.slice(0, 3) && (low.length === 3 || DAY_LONG[low] === x); })[0]; v = dd || null; }
              else v = vals.indexOf(low) >= 0 ? low : null;
              if (v == null) colIssue(t, row, col, "BAD_VALUE", "is not an allowed value.", "Use one of: " + vals.join(", ") + ".");
              break;
            }
            case "date":
              v = parseDate(s);
              if (!v) colIssue(t, row, col, "BAD_DATE", "is not a real date.", "Use YYYY-MM-DD (2026-01-12) or DD/MM/YYYY (12/01/2026), day first.");
              break;
            case "time":
              v = parseTime(s);
              if (v == null) colIssue(t, row, col, "BAD_TIME", "is not a time.", "Use 24-hour HH:MM, for example 16:00.");
              break;
            case "money": case "money0": case "rate": case "pay": {
              if (col.type === "pay" && row.c.pay_method === "percent_of_fee") {
                var pm = /^(\d{1,3})(?:\.(\d{1,2}))?$/.exec(s), bp = pm ? Number(pm[1]) * 100 + Number(((pm[2] || "") + "00").slice(0, 2)) : null;
                if (bp == null) colIssue(t, row, col, "BAD_MONEY", "is not a percentage.", "Write a number from 0 to 100 with at most 2 decimals, for example 40 or 37.5.");
                else if (bp <= 0 || bp > 10000) colIssue(t, row, col, "OUT_OF_RANGE", "is outside 0 to 100 percent.", "Write a percentage above 0 and up to 100.");
                else v = bp;
                break;
              }
              var cents = parseCents(s);
              if (cents == null) colIssue(t, row, col, "BAD_MONEY", "is not an amount in dollars.", "Write digits with at most 2 decimals, for example 55 or 55.50. No $ sign and no commas.");
              else if (col.type === "rate" && cents > 100000) colIssue(t, row, col, "OUT_OF_RANGE", "is more than 1,000 dollars an hour.", "Check the amount. The hourly rate must be from 0 to 1,000 dollars.");
              else if (col.type === "pay" && cents > 10000000) colIssue(t, row, col, "OUT_OF_RANGE", "is more than 100,000 dollars.", "Check the amount.");
              else if ((col.type === "money" || col.type === "pay") && cents <= 0) colIssue(t, row, col, "OUT_OF_RANGE", "must be more than 0.", "Write an amount above 0.");
              else v = cents;
              break;
            }
          }
          row.v[col.name] = v;
        });
      });
    });

    // ---- 3. rules inside and across files
    var T = tables, famKeys = {}, stuKeys = {}, tutKeys = {};
    function setFrom(arr) { var o = {}; (arr || []).forEach(function (x) { o[String(x).toLowerCase()] = 1; }); return o; }
    var exFam = setFrom(existing.families), exStu = setFrom(existing.students), exTut = setFrom(existing.tutors);
    var notes = [];

    // families
    if (T.families) {
      var byFam = {};
      T.families.rows.forEach(function (row) {
        var ref = row.v.family_ref; if (ref == null) return;
        var g = byFam[ref] || (byFam[ref] = []); g.push(row);
        famKeys[ref.toLowerCase()] = 1;
        if (!row.c.phone && !row.c.email && row.v.guardian_name) { issue("error", T.families.name, row.line, "phone", "", "NEED_CONTACT", "has no phone and no email for " + row.c.guardian_name + ".", "Each guardian needs a phone number or an email address. Fill in at least one."); row.bad = true; }
      });
      Object.keys(byFam).forEach(function (ref) {
        var g = byFam[ref], first = g[0], mains = 0, seen = {};
        g.forEach(function (row, i) {
          if (row.v.family_name && first.v.family_name && row.v.family_name !== first.v.family_name) { issue("error", T.families.name, row.line, "family_name", row.c.family_name, "FAMILY_NAME_MISMATCH", "differs from line " + first.line + ", where " + ref + " is called \"" + shorten(first.c.family_name, 40) + "\".", "Use the same family name on every row of " + ref + "."); row.bad = true; }
          if (i === 6) { issue("error", T.families.name, row.line, "guardian_name", row.c.guardian_name, "TOO_MANY_GUARDIANS", "is the 7th guardian of " + ref + "; a family can have up to 6.", "Remove the extra guardians."); row.bad = true; }
          if (row.v.main === true && ++mains === 2) { issue("error", T.families.name, row.line, "main", row.c.main, "MULTIPLE_MAIN", "is a second main contact for " + ref + ".", "Only one guardian per family can be Y. Set the others to N."); row.bad = true; }
          var dk = [row.c.guardian_name, row.c.phone, row.c.email].join("\u0001").toLowerCase();
          if (seen[dk] != null) { issue("error", T.families.name, row.line, "guardian_name", row.c.guardian_name, "DUPLICATE_ROW", "is the same as line " + seen[dk] + ".", "Delete the repeated row, or add a phone or email to tell them apart."); row.bad = true; } else seen[dk] = row.line;
        });
      });
    }

    // students
    if (T.students) {
      var seenS = {}, nameIn = {};
      T.students.rows.forEach(function (row) {
        var ref = row.v.student_ref;
        if (ref != null) {
          if (seenS[ref.toLowerCase()] != null) { issue("error", T.students.name, row.line, "student_ref", ref, "DUPLICATE_KEY", "is already used on line " + seenS[ref.toLowerCase()] + ".", "Give every student their own student_ref."); row.bad = true; }
          else { seenS[ref.toLowerCase()] = row.line; stuKeys[ref.toLowerCase()] = row; }
        }
        var fr = row.v.family_ref;
        if (fr != null) {
          if (T.families && !famKeys[fr.toLowerCase()] && !exFam[fr.toLowerCase()]) { issue("error", T.students.name, row.line, "family_ref", fr, "UNKNOWN_FAMILY", "is not in " + T.families.name + ".", "Add family " + fr + " to " + T.families.name + ", or correct the code."); row.bad = true; }
          var nm = row.v.student_name;
          if (nm != null) {
            var nk = fr.toLowerCase() + "\u0001" + nm.toLowerCase();
            if (nameIn[nk] != null) { issue("error", T.students.name, row.line, "student_name", nm, "DUPLICATE_STUDENT_NAME", "is already a student of family " + fr + " on line " + nameIn[nk] + ".", "Check for a repeated row. If they are two children with the same name, add a middle initial."); row.bad = true; } else nameIn[nk] = row.line;
          }
        }
        if (row.v.start_date && row.v.start_date > maxFuture) { issue("error", T.students.name, row.line, "start_date", row.c.start_date, "FUTURE_DATE", "is more than a year from today.", "Check the year, or leave the student out until nearer the time."); row.bad = true; }
      });
    }

    // tutors
    if (T.tutors) {
      var seenT = {};
      T.tutors.rows.forEach(function (row) {
        var em = row.v.tutor_email;
        if (em != null) {
          if (seenT[em] != null) { issue("error", T.tutors.name, row.line, "tutor_email", row.c.tutor_email, "DUPLICATE_KEY", "is already used on line " + seenT[em] + ".", "Each tutor needs their own email. Delete the repeated row."); row.bad = true; }
          else { seenT[em] = row.line; tutKeys[em] = row; }
        }
        var set = ["pay_method", "pay_amount", "pay_from"].filter(function (k) { return row.c[k] !== ""; }).length;
        if (set > 0 && set < 3) { var miss = ["pay_method", "pay_amount", "pay_from"].filter(function (k) { return row.c[k] === ""; }); issue("error", T.tutors.name, row.line, miss[0], "", "PAY_INCOMPLETE", "pay_method, pay_amount and pay_from go together, and " + miss.join(" and ") + (miss.length > 1 ? " are" : " is") + " empty.", "Fill in all three, or empty all three."); row.bad = true; }
      });
    }

    // weekly lessons
    if (T.weekly_lessons) {
      var W = T.weekly_lessons, seenK = {}, byStu = {}, byTut = {};
      W.rows.forEach(function (row) {
        var s = row.v.student_ref, tu = row.v.tutor_email;
        if (s != null && T.students && !stuKeys[s.toLowerCase()] && !exStu[s.toLowerCase()]) { issue("error", W.name, row.line, "student_ref", s, "UNKNOWN_STUDENT", "is not in " + T.students.name + ".", "Add student " + s + " to " + T.students.name + ", or correct the code."); row.bad = true; }
        if (tu != null && T.tutors && !tutKeys[tu] && !exTut[tu]) { issue("error", W.name, row.line, "tutor_email", row.c.tutor_email, "UNKNOWN_TUTOR", "is not in " + T.tutors.name + ".", "Add this tutor to " + T.tutors.name + ", or correct the email."); row.bad = true; }
        var st = row.v.start, en = row.v.end;
        if (st != null && en != null) {
          if (en <= st) { issue("error", W.name, row.line, "end", row.c.end, "END_BEFORE_START", "is not after the start time " + row.c.start + ".", "Make the end time later than the start time."); row.bad = true; }
          else if (en - st < 15) { issue("error", W.name, row.line, "end", row.c.end, "BAD_DURATION", "makes a lesson of " + (en - st) + " minutes; the shortest is 15.", "Check the times. A lesson is 15 minutes to 8 hours."); row.bad = true; }
          else if (en - st > 480) { issue("error", W.name, row.line, "end", row.c.end, "BAD_DURATION", "makes a lesson of " + (en - st) + " minutes; the longest is 480 (8 hours).", "Check the times. A lesson is 15 minutes to 8 hours."); row.bad = true; }
        }
        if (row.bad || s == null || tu == null || row.v.day == null) return;
        var kk = [s, tu, row.v.day, st].join("\u0001").toLowerCase();
        if (seenK[kk] != null) { issue("error", W.name, row.line, "start", row.c.start, "DUPLICATE_KEY", "is the same lesson as line " + seenK[kk] + " (same student, tutor, day and start).", "Delete the repeated row."); row.bad = true; return; }
        seenK[kk] = row.line;
        (byStu[s.toLowerCase() + "\u0001" + row.v.day] || (byStu[s.toLowerCase() + "\u0001" + row.v.day] = [])).push(row);
        (byTut[tu + "\u0001" + row.v.day] || (byTut[tu + "\u0001" + row.v.day] = [])).push(row);
      });
      function sweep(groups, onClash) {
        Object.keys(groups).forEach(function (k) {
          var g = groups[k]; if (g.length < 2) return;
          g.sort(function (a, b) { return a.v.start - b.v.start || a.line - b.line; });
          var reach = g[0].v.end, who = g[0];
          for (var i = 1; i < g.length; i++) {
            if (g[i].v.start < reach) { onClash(g[i], who); if (g[i].v.end > reach) { reach = g[i].v.end; who = g[i]; } }
            else { reach = g[i].v.end; who = g[i]; }
          }
        });
      }
      sweep(byStu, function (row, other) { issue("error", W.name, row.line, "start", row.c.start, "SLOT_CLASH", "overlaps line " + other.line + " for the same student on " + row.v.day + " (" + fmtTime(other.v.start) + " to " + fmtTime(other.v.end) + ").", "A student cannot have two lessons at the same time. Change one of the times."); row.bad = true; });
      sweep(byTut, function (row, other) { issue("warning", W.name, row.line, "start", row.c.start, "TUTOR_DOUBLE_BOOKED", "overlaps line " + other.line + " for the same tutor on " + row.v.day + " (" + fmtTime(other.v.start) + " to " + fmtTime(other.v.end) + ").", "Check it is not a mistake. One tutor can only teach one student at a time."); });
    }

    // deposits
    if (T.deposits) {
      var seenD = {};
      T.deposits.rows.forEach(function (row) {
        var s = row.v.student_ref;
        if (s != null && T.students && !stuKeys[s.toLowerCase()] && !exStu[s.toLowerCase()]) { issue("error", T.deposits.name, row.line, "student_ref", s, "UNKNOWN_STUDENT", "is not in " + T.students.name + ".", "Add student " + s + " to " + T.students.name + ", or correct the code."); row.bad = true; }
        if (row.v.received_date && row.v.received_date > today) { issue("error", T.deposits.name, row.line, "received_date", row.c.received_date, "FUTURE_DATE", "is in the future.", "A deposit already held must have been received on or before today."); row.bad = true; }
        if (row.c.reference && /\d{9,}/.test(row.c.reference.replace(/[\s\-]/g, ""))) issue("warning", T.deposits.name, row.line, "reference", row.c.reference, "LONG_NUMBER", "contains 9 or more digits in a row, which looks like an account number.", "Do not put account numbers here. Use words like \"PayNow Oct\".");
        if (!row.bad && s != null && row.v.amount != null && row.v.received_date) {
          var dk = [s.toLowerCase(), row.v.received_date, row.v.amount, (row.c.reference || "").toLowerCase()].join("\u0001");
          if (seenD[dk] != null) { issue("error", T.deposits.name, row.line, "student_ref", s, "DUPLICATE_ROW", "is the same as line " + seenD[dk] + " (same student, date, amount and reference).", "Delete the repeated row, or add a reference to tell them apart."); row.bad = true; } else seenD[dk] = row.line;
        }
      });
    }

    // unpaid invoices
    if (T.unpaid_invoices) {
      var seenI = {};
      T.unpaid_invoices.rows.forEach(function (row) {
        var no = row.v.invoice_number;
        if (no != null) {
          if (seenI[no.toLowerCase()] != null) { issue("error", T.unpaid_invoices.name, row.line, "invoice_number", no, "DUPLICATE_KEY", "is already used on line " + seenI[no.toLowerCase()] + ".", "Each invoice number can appear once."); row.bad = true; } else seenI[no.toLowerCase()] = row.line;
        }
        var fr = row.v.family_ref;
        if (fr != null && T.families && !famKeys[fr.toLowerCase()] && !exFam[fr.toLowerCase()]) { issue("error", T.unpaid_invoices.name, row.line, "family_ref", fr, "UNKNOWN_FAMILY", "is not in " + T.families.name + ".", "Add family " + fr + " to " + T.families.name + ", or correct the code."); row.bad = true; }
        var sr = row.v.student_ref;
        if (sr != null && T.students) {
          var srow = stuKeys[sr.toLowerCase()];
          if (!srow && !exStu[sr.toLowerCase()]) { issue("error", T.unpaid_invoices.name, row.line, "student_ref", sr, "UNKNOWN_STUDENT", "is not in " + T.students.name + ".", "Add student " + sr + " to " + T.students.name + ", correct the code, or leave it empty."); row.bad = true; }
          else if (srow && fr != null && !row.bad && srow.v.family_ref && srow.v.family_ref.toLowerCase() !== fr.toLowerCase()) { issue("error", T.unpaid_invoices.name, row.line, "student_ref", sr, "STUDENT_NOT_IN_FAMILY", "belongs to family " + srow.v.family_ref + ", not " + fr + ".", "Use the right family_ref, or the right student_ref."); row.bad = true; }
        }
        if (row.v.invoice_date && row.v.invoice_date > today) { issue("error", T.unpaid_invoices.name, row.line, "invoice_date", row.c.invoice_date, "FUTURE_DATE", "is in the future.", "Only invoices already issued can be imported."); row.bad = true; }
        if (row.v.due_date && row.v.invoice_date && row.v.due_date < row.v.invoice_date) issue("warning", T.unpaid_invoices.name, row.line, "due_date", row.c.due_date, "DUE_BEFORE_INVOICE", "is before the invoice date.", "Check the two dates are the right way round.");
        if (row.v.amount != null && row.v.paid_so_far != null && row.v.paid_so_far >= row.v.amount) { issue("error", T.unpaid_invoices.name, row.line, "paid_so_far", row.c.paid_so_far, "PAID_TOO_MUCH", "is not less than the amount " + row.c.amount + ", so this invoice is not unpaid.", "Leave fully paid invoices out, or correct the amounts."); row.bad = true; }
      });
    }

    // ---- 4. notes about files that were not uploaded
    var missing = STAGE_A.filter(function (k) { return !T[k]; });
    if (T.students && !T.families && !(opts.existing && opts.existing.families)) notes.push(["students", "families.csv was not uploaded, so the family codes in students.csv were not checked."]);
    if (T.weekly_lessons && !T.students) notes.push(["weekly_lessons", "students.csv was not uploaded, so the students in the weekly lessons were not checked."]);
    if (T.weekly_lessons && !T.tutors) notes.push(["weekly_lessons", "tutors.csv was not uploaded, so the tutors in the weekly lessons were not checked."]);
    notes.forEach(function (n) { issue("note", T[n[0]].name, 1, "", "", "NOT_CHECKED", n[1], "Upload the missing file to check them."); });
    if (T.deposits && !T.students && !(opts.existing && opts.existing.students)) issue("note", T.deposits.name, 1, "", "", "NOT_CHECKED", "students.csv was not uploaded, so the students in the deposits were not checked.", "Upload the missing file to check them.");
    if (T.unpaid_invoices && !T.families && !(opts.existing && opts.existing.families)) issue("note", T.unpaid_invoices.name, 1, "", "", "NOT_CHECKED", "families.csv was not uploaded, so the families in the invoices were not checked.", "Upload the missing file to check them.");

    // ---- 5. order, summary
    var sevRank = { error: 0, warning: 1, note: 2 };
    var fileOrder = {}; fileInfo.forEach(function (fi, i) { fileOrder[fi.name] = fi.key != null ? order[fi.key] : 100 + i; });
    issues.sort(function (a, b) { return (fileOrder[a.file] - fileOrder[b.file]) || (a.line - b.line) || (sevRank[a.severity] - sevRank[b.severity]); });
    var errors = issues.filter(function (x) { return x.severity === "error"; }), warnings = issues.filter(function (x) { return x.severity === "warning"; }), notesOut = issues.filter(function (x) { return x.severity === "note"; });
    var ready = errors.length === 0 && missing.length === 0;
    var summary = ready ? summarise(T) : null;
    var t1 = typeof performance !== "undefined" ? performance.now() : Date.now();
    return { files: fileInfo, errors: errors, warnings: warnings, notes: notesOut, missing: missing, ready: ready, summary: summary, ms: Math.round((t1 - t0) * 10) / 10 };
  }

  function summarise(T) {
    var s = { families: 0, guardians: 0, students: 0, tutors: 0, invitations: 0, emails_sent: 0, weekly_lessons: 0, weekly_minutes: 0, deposits: 0, deposits_cents: 0, invoices: 0, invoices_cents: 0, invoices_paid_cents: 0, invoices_owed_cents: 0, siblings_families: 0 };
    var fam = {}, perFam = {};
    T.families.rows.forEach(function (r) { s.guardians++; fam[r.v.family_ref.toLowerCase()] = 1; });
    s.families = Object.keys(fam).length;
    T.students.rows.forEach(function (r) { s.students++; var k = r.v.family_ref.toLowerCase(); perFam[k] = (perFam[k] || 0) + 1; });
    Object.keys(perFam).forEach(function (k) { if (perFam[k] > 1) s.siblings_families++; });
    s.tutors = T.tutors.rows.length; s.invitations = s.tutors;
    T.weekly_lessons.rows.forEach(function (r) { s.weekly_lessons++; s.weekly_minutes += r.v.end - r.v.start; });
    if (T.deposits) T.deposits.rows.forEach(function (r) { s.deposits++; s.deposits_cents += r.v.amount; });
    if (T.unpaid_invoices) T.unpaid_invoices.rows.forEach(function (r) { var paid = r.v.paid_so_far || 0; s.invoices++; s.invoices_cents += r.v.amount; s.invoices_paid_cents += paid; s.invoices_owed_cents += r.v.amount - paid; });
    return s;
  }

  // "students.csv, line 17, level: "Pri 5" is not recognised. Use P5."
  function describe(it) {
    var where = it.file + (it.line ? ", line " + it.line : "") + (it.column ? ", " + it.column : "");
    return where + ": " + (it.value !== "" && it.value != null ? '"' + it.value + '" ' : "") + it.message + (it.fix ? " " + it.fix : "");
  }
  function errorsCsv(items) {
    return "﻿" + toCsv([["severity", "file", "line", "column", "value", "what is wrong", "how to fix"]].concat(items.map(function (i) { return [i.severity, i.file, i.line, i.column, i.value, i.message, i.fix]; })), true);
  }

  return {
    MAX_CHARS: MAX_CHARS, LEVELS: LEVELS, DAYS: DAYS, FILES: FILES, FILE_ORDER: FILE_ORDER, STAGE_A: STAGE_A,
    readCsv: readCsv, toCsv: toCsv, templateRows: templateRows, templateCsv: templateCsv, readmeText: readmeText,
    parseDate: parseDate, parseTime: parseTime, parseCents: parseCents, fmtMoney: fmtMoney, suggestLevel: suggestLevel,
    validateFiles: validateFiles, detectText: detectText, describe: describe, errorsCsv: errorsCsv, detectFile: detectFile, norm: norm
  };
});
