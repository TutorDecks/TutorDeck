#!/usr/bin/env node
// A small DUMMY bank statement for clicking through Money > Statements on DEV (T34). Invented payers, invented bank references, a layout that is NOT any bank's:
// separate Withdrawal and Deposit columns, DD/MM/YYYY dates, thousands commas, a few lines of the bank's own header and footer text, so the column mapping has to be used.
//
//   node tests/fixtures/make-statement-sample.js [--out FILE] INVOICE_NUMBER=AMOUNT ...
//   e.g.  node tests/fixtures/make-statement-sample.js DLC-0007=54.50 DLC-0008=120 > statement.csv
//
// Each INVOICE_NUMBER=AMOUNT becomes a money-in line whose reference holds that invoice number and the exact amount (so the matcher can settle it by itself, rule A).
// It also adds: one line with the right amount but no number (a suggestion only), one line with an amount nobody owes (left to review), one money-OUT line (never matched).
// Dates are in the last two weeks. Nothing here is real; never put a real statement in the repo.
"use strict";
const fs = require("fs");
const args = process.argv.slice(2); let out = null; const inv = [];
for (let i = 0; i < args.length; i++) { if (args[i] === "--out") out = args[++i]; else if (/^[A-Za-z0-9-]+=\d+(\.\d{1,2})?$/.test(args[i])) inv.push(args[i].split("=")); else { console.error("not understood: " + args[i]); process.exit(1); } }
const day = (back) => { const d = new Date(Date.now() - back * 86400000), p = (n) => (n < 10 ? "0" : "") + n; return p(d.getUTCDate()) + "/" + p(d.getUTCMonth() + 1) + "/" + d.getUTCFullYear(); };
const money = (v) => { const [a, b] = String(v).split("."), n = a.replace(/\B(?=(\d{3})+(?!\d))/g, ","); return n + "." + ((b || "") + "00").slice(0, 2); };
const PAYERS = ["TAN AH KOW", "LIM MEI LING", "NG SOON HOCK", "MRS CHUA", "KOH XIAO MING", "SITI AMINAH"];
const rows = [["Statement of account (dummy layout, not a real bank file)", "", "", "", "", ""], ["Account", "000-000000-0 (fake)", "", "", "", ""], ["", "", "", "", "", ""],
  ["Date", "Description", "Withdrawal", "Deposit", "Payer", "Reference"]];
inv.forEach(([no, amt], i) => rows.push([day(3 + i), no + " tuition fees", "", money(amt), PAYERS[i % PAYERS.length], "TX" + (200100 + i * 7)]));
rows.push([day(2), "school fees", "", money(60), PAYERS[4], "TX200901"]);
rows.push([day(2), "FAST PAYMENT", "", money(77.77), PAYERS[5], "TX200902"]);
rows.push([day(1), "FAST PAYMENT TO SUPPLIER 1001", money(30), "", "", "TX200903"]);
rows.push(["", "Closing balance", "", "99,999.99", "", ""]);
const q = (c) => (/[",\n]/.test(c) ? '"' + c.replace(/"/g, '""') + '"' : c);
const text = "﻿" + rows.map((r) => r.map(q).join(",")).join("\n") + "\n";
if (out) fs.writeFileSync(out, text); else process.stdout.write(text);
