// T34 M0-M2: bank statement matching, the browser's side (assets/js/statement-core.js). All data is invented (tests/fixtures/statement-gen.js).
const test = require("node:test"), assert = require("node:assert/strict"), fs = require("fs"), path = require("path");
const S = require("../assets/js/statement-core.js"), G = require("./fixtures/statement-gen.js"), Money = require("../assets/js/money.js");

test("CSV: quotes, escaped quotes, commas and line breaks inside quotes, CRLF, BOM, blank lines, last line without a newline", () => {
  const t = '﻿Date,Note,Amt\r\n01/11/2026,"fees, Nov ""A""",10.00\r\n\r\n02/11/2026,"two\nlines",5.50';
  const r = S.parseCSV(t, ",");
  assert.deepEqual(r[0], ["Date", "Note", "Amt"]);
  assert.deepEqual(r[1], ["01/11/2026", 'fees, Nov "A"', "10.00"]);
  assert.deepEqual(r[2], [""]);                                           // a blank row keeps its place (row numbers stay true)
  assert.deepEqual(r[3], ["02/11/2026", "two\nlines", "5.50"]);
  assert.equal(r.length, 4);
  assert.deepEqual(S.parseCSV("a;b;c\n1;2;3\n", ";"), [["a", "b", "c"], ["1", "2", "3"]]);
  assert.deepEqual(S.parseCSV("a\tb\n1\t\n", "\t"), [["a", "b"], ["1", ""]]);
  assert.deepEqual(S.parseCSV("", ","), []);
  assert.deepEqual(S.parseCSV('x,"unterminated', ","), [["x", "unterminated"]]);   // never throws on a damaged file
});

test("delimiter detection", () => {
  assert.equal(S.detectDelimiter("a,b,c\n1,2,3\n4,5,6"), ",");
  assert.equal(S.detectDelimiter("a;b;c\n1;2;3\n4;5;6"), ";");
  assert.equal(S.detectDelimiter("a\tb\tc\n1\t2\t3"), "\t");
  assert.equal(S.detectDelimiter('Date,"Note; with, both",Amt\n1,"x;y",3\n'), ",");
  assert.equal(S.detectDelimiter("just one column\nanother"), null);
});

test("dates: every format, two-digit years, leap days, times, rubbish", () => {
  const ok = [["31/12/2026", "dmy_slash", "2026-12-31"], ["1/2/26", "dmy_slash", "2026-02-01"], ["29/02/2028", "dmy_slash", "2028-02-29"], ["31-12-2026", "dmy_dash", "2026-12-31"],
    ["31.12.2026", "dmy_dash", "2026-12-31"], ["5 Nov 2026", "dmy_text", "2026-11-05"], ["05-NOV-26", "dmy_text", "2026-11-05"], ["5 November 2026", "dmy_text", "2026-11-05"],
    ["2026-12-31", "iso", "2026-12-31"], ["2026/1/5", "iso", "2026-01-05"], ["12/31/2026", "mdy_slash", "2026-12-31"], [" 31/12/2026 14:05 ", "dmy_slash", "2026-12-31"]];
  ok.forEach(([t, f, e]) => assert.equal(S.parseDate(t, f), e, t + " as " + f));
  [["29/02/2026", "dmy_slash"], ["31/04/2026", "dmy_slash"], ["32/01/2026", "dmy_slash"], ["12/31/2026", "dmy_slash"], ["31/12/2026", "mdy_slash"], ["5 Foo 2026", "dmy_text"], ["", "iso"], ["yesterday", "iso"], ["2026-13-01", "iso"], ["31/12/2026", "iso"]]
    .forEach(([t, f]) => assert.equal(S.parseDate(t, f), null, t + " as " + f));
  assert.equal(S.parseDate("31/12/2026", "nonsense"), null);
});

test("amounts: whole cents from the text, never floating point", () => {
  const ok = [["1,234.50", 123450], ["S$12", 1200], ["$0.05", 5], ["-0.05", -5], ["(12.00)", -1200], ["12.00-", -1200], ["(1,000.00)", -100000], ["12.00 CR", 1200], ["12.00 Dr", -1200],
    ["-12.00 CR", 1200], ["0.00", 0], ["19.99", 1999], ["0.1", 10], [" 5 ", 500], ["1,000,000.01", 100000001]];
  ok.forEach(([t, c]) => assert.equal(S.parseAmount(t), c, t));
  ["", "  ", "abc", "1.234", "12,3", "12,50", "1,23,456.00", "--5", "1 2", "S$"].forEach((t) => assert.equal(S.parseAmount(t), null, JSON.stringify(t)));
  assert.equal(S.parseAmount("1234.56"), 123456);                         // 1234.56 * 100 in floating point is 123455.99999999999
  assert.equal(S.parseAmount("0.29"), 29);                                // 0.29 * 100 = 28.999999999999996
});

test("normalisation vectors are shared with the database (tests/statement-vectors.csv; the SQL test reads the same file)", () => {
  const rows = S.parseCSV(fs.readFileSync(path.join(__dirname, "statement-vectors.csv"), "utf8"), ",").slice(1).filter((r) => r.length >= 2);
  assert.ok(rows.length >= 12);
  rows.forEach(([kind, input, expected]) => {
    const got = kind === "payer" ? S.normPayer(input) : kind === "ref" ? S.normRef(input) : S.maskDigits(input);
    assert.equal(got, expected || "", kind + ": " + JSON.stringify(input));
  });
});

test("invoice-number pattern: spacing, case and punctuation ignored; never a longer or shorter number", () => {
  const re = new RegExp(S.numberPattern("INV-12"));
  ["inv-12", "inv 12", "inv12", "paid inv.12 thanks", "x inv  12", "inv-12-2026", "(inv12)"].forEach((t) => assert.ok(re.test(t), t));
  ["inv-123", "inv-1", "xinv-12", "inv-120", "invoice 12", "inv-1 2", "12"].forEach((t) => assert.ok(!re.test(t), t));
  assert.equal(S.numberPattern("--"), null);
});

test("mapping validation: the same rules as stmt_save_mapping", () => {
  const good = { delimiter: ",", header_rows: 1, date_col: 0, date_format: "iso", amount_mode: "signed", amount_col: 2, ref_cols: [1], payer_col: 3, bank_ref_col: 4 };
  assert.deepEqual(S.validateMapping(good), []);
  assert.ok(S.validateMapping(null).length);
  assert.ok(S.validateMapping({ ...good, delimiter: "#" })[0].includes("separator"));
  assert.ok(S.validateMapping({ ...good, header_rows: 100 }).length);
  assert.ok(S.validateMapping({ ...good, header_rows: -1 }).length);
  assert.ok(S.validateMapping({ ...good, date_format: "yyyy" }).length);
  assert.ok(S.validateMapping({ ...good, amount_col: undefined }).length);
  assert.ok(S.validateMapping({ ...good, amount_mode: "debit_credit", debit_col: 1 }).some((m) => m.includes("money-in")));
  assert.ok(S.validateMapping({ ...good, amount_mode: "amount_drcr", amount_col: 2 }).some((m) => m.includes("Dr / Cr")));
  assert.ok(S.validateMapping({ ...good, ref_cols: [0, 1, 2, 3, 4, 5, 6] }).length);
  assert.ok(S.validateMapping({ ...good, ref_cols: "a" }).length);
  assert.ok(S.validateMapping({ ...good, payer_col: "x" }).length);
  assert.deepEqual(S.validateMapping({ ...good, payer_col: null, bank_ref_col: null }), []);
});

test("every generated layout parses back to exactly the lines that went in (layout assumed, not a real export)", () => {
  G.LAYOUTS.forEach((layout) => {
    const g = G.generate({ layout, n: 80, seed: 7, invoices: [{ number: "INV-12", bal: 9000 }, { number: "INV-7", bal: 12345 }] });
    const delim = S.detectDelimiter(g.text);
    assert.equal(delim, g.mapping.delimiter, layout + " delimiter");
    const rows = S.parseCSV(g.text, delim), r = S.applyMapping(rows, g.mapping);
    assert.deepEqual(r.errors, [], layout + " has no errors");
    assert.equal(r.lines.length, 80, layout + " line count");
    r.lines.forEach((l, i) => {
      const e = g.lines[i];
      assert.equal(l.date, e.date, layout + " date " + i); assert.equal(l.cents, e.cents, layout + " cents " + i);
      assert.equal(l.ref, S.maskDigits(e.ref), layout + " ref " + i); assert.equal(l.payer, e.payer, layout + " payer " + i); assert.equal(l.bank_ref, e.bank_ref);
    });
    if (layout === "headers_footer") { assert.equal(r.footer, 2, "the closing-balance and total rows are footer rows"); }
  });
  const g = G.generate({ layout: "signed", n: 200, seed: 3 });
  assert.ok(g.lines.some((l) => l.ref.includes("123456789012")) && !S.applyMapping(S.parseCSV(g.text, ","), g.mapping).lines.some((l) => /[0-9]{9}/.test(l.ref)), "account numbers are cut to their last 4 digits before they leave the browser");
});

test("mapping: errors name the row; sign inversion; Dr/Cr marker; empty amount; zero lines are counted", () => {
  const m = { delimiter: ",", header_rows: 1, date_col: 0, date_format: "dmy_slash", amount_mode: "signed", amount_col: 1, ref_cols: [2, 3], payer_col: null, bank_ref_col: null };
  const rows = S.parseCSV("Date,Amt,A,B\n01/11/2026,10.00,hello,world\n31/02/2026,5.00,x,\n02/11/2026,abc,y,\n03/11/2026,0.00,z,\n,, total,\n", ",");
  const r = S.applyMapping(rows, m);
  assert.equal(r.lines.length, 2);                                       // the good row and the zero row
  assert.equal(r.lines[0].ref, "hello world");                           // several reference columns are joined
  assert.equal(r.errors.length, 2);
  assert.match(r.errors[0].message, /^Row 3: the date .31\/02\/2026. doesn.t match the date format you picked \(for example 31\/12\/2026\)\.$/);
  assert.match(r.errors[1].message, /^Row 4: no amount/);
  assert.equal(r.zero, 1); assert.equal(r.footer, 1);
  assert.equal(S.applyMapping(rows, { ...m, invert: true }).lines[0].cents, -1000);
  const dr = S.applyMapping(S.parseCSV("d,a,t\n01/11/2026,50.00,Cr\n02/11/2026,20.00,Dr\n", ","), { ...m, amount_mode: "amount_drcr", amount_col: 1, drcr_col: 2, ref_cols: [] });
  assert.deepEqual(dr.lines.map((l) => l.cents), [5000, -2000]);
  const bad = S.applyMapping(rows, { ...m, date_format: "nope" });
  assert.equal(bad.lines.length, 0); assert.ok(bad.errors.length);
});

test("summary of a file: counts, totals, date range", () => {
  const s = S.summarise([{ date: "2026-11-02", cents: 5000 }, { date: "2026-11-01", cents: -1500 }, { date: "2026-11-09", cents: 2500 }]);
  assert.deepEqual([s.lines, s.credits, s.debits, s.nIn, s.nOut, s.from, s.to], [3, 7500, 1500, 2, 1, "2026-11-01", "2026-11-09"]);
});

test("presets are listed as unverified placeholders, never as working (no real sample yet)", () => {
  assert.deepEqual(S.PRESETS.map((p) => p.id), ["DBS", "OCBC", "UOB"]);
  S.PRESETS.forEach((p) => assert.equal(p.status, "unverified"));
});

// ---------------------------------------------------------------- scoring: the database's rules, same words (tests/sql/statement_matching_test.sql has the SQL twin)
const T = "2026-11-27";
const inv = (id, number, hid, bal, issue = T, due = "2026-12-04") => ({ id, number, hid, bal, issue, due });
const world = () => ({ today: T, settings: { auto_confirm: "exact_only", window_before_days: 7, window_after_days: 90 }, links: {},
  invoices: [inv("i1", "SMT-1", "h1", 10000), inv("i2", "SMT-2", "h1", 5000), inv("i3", "SMT-3", "h2", 3000), inv("i4", "SMT-4", "h3", 4000), inv("i5", "SMT-5", "h3", 4000),
    inv("i6", "SMT-6", "h4", 7000), inv("i7", "SMT-7", "h5", 6000), inv("i8", "SMT-8", "h5", 2500), inv("i9", "SMT-9", "h5", 1500), inv("i10", "SMT-10", "h6", 3000)] });
const L = (cents, ref, payer, date = T) => ({ date, cents, ref, payer });

test("rule A: the invoice number plus the exact amount pays by itself; every other outcome waits with its reason", () => {
  const w = world();
  let r = S.score(L(7000, "Lessons smt 6 thanks", "Mr GOH"), w);
  assert.deepEqual([r.rule, r.exact, r.auto, r.ids], ["invoice_no", true, true, ["i6"]]); assert.equal(r.reason, "SMT-6 found, exact amount.");
  assert.match(S.score(L(3000, "fees smt-2"), w).reason, /^SMT-2 found, but S\$20\.00 short\.$/);
  assert.match(S.score(L(6500, "SMT-7"), w).reason, /^SMT-7 found, but S\$5\.00 over\.$/);
  assert.equal(S.score(L(10000, "SMT-1"), w).auto, true);
  assert.equal(S.score(L(10000, "SMT-10"), w).rule, "invoice_no");        // "SMT-10" is its own invoice, not SMT-1
  assert.deepEqual(S.score(L(10000, "SMT-10"), w).ids, ["i10"]);
  r = S.score(L(4000, "SMT-8 & SMT-9"), w);
  assert.deepEqual([r.rule, r.exact, r.auto], ["household_total", true, false]); assert.match(r.reason, /^More than one invoice number found \(SMT-8, SMT-9\), and together they come to exactly S\$40\.00/);
  assert.match(S.score(L(1, "SMT-8 SMT-9"), w).reason, /Choose which one/);
  w.invoices[5].bal = 0; assert.match(S.score(L(7000, "SMT-6"), w).reason, /already paid\.$/);
});

test("the date window: day -7 / -8 before issue and due +90 / +91 (and a 0/0 window)", () => {
  const w = world(); w.invoices = [inv("a", "SMT-1", "h1", 500, "2026-11-27", "2026-11-27")];
  assert.equal(S.score(L(500, "SMT-1", "", "2026-11-20"), w).exact, true, "7 days before it was issued");
  assert.match(S.score(L(500, "SMT-1", "", "2026-11-19"), w).reason, /outside the allowed window \(7 days before it was issued to 90 days after it was due\)/, "8 days before");
  w.today = "2027-03-01"; assert.equal(S.score(L(500, "SMT-1", "", "2027-02-25"), w).exact, true, "due + 90");
  assert.match(S.score(L(500, "SMT-1", "", "2027-02-26"), w).reason, /outside the allowed window/, "due + 91");
  const z = world(); z.settings.window_before_days = 0; z.settings.window_after_days = 0; z.invoices = [inv("a", "SMT-1", "h1", 500, "2026-11-20", "2026-11-22")]; z.today = "2026-11-27";
  assert.equal(S.score(L(500, "SMT-1", "", "2026-11-20"), z).exact, true); assert.equal(S.score(L(500, "SMT-1", "", "2026-11-22"), z).exact, true);
  assert.match(S.score(L(500, "SMT-1", "", "2026-11-19"), z).reason, /0 days before it was issued to 0 days after/); assert.match(S.score(L(500, "SMT-1", "", "2026-11-23"), z).reason, /outside/);
});

test("auto-confirm: exact_only pays rules A and B by themselves; never waits for a person; C and D are never automatic", () => {
  const w = world(), line = L(7000, "SMT-6");
  assert.equal(S.score(line, w).auto, true);
  w.settings.auto_confirm = "never";
  const r = S.score(line, w); assert.equal(r.auto, false); assert.equal(r.exact, true); assert.match(r.reason, /Auto-confirm is off, so a person confirms\.$/);
  w.settings.auto_confirm = "exact_only";
  assert.equal(S.score(L(10000, "monthly", "Lim Mei"), w).auto, false);          // rule C
  assert.equal(S.score(L(15000, "school fees", "Lim Mei"), w).auto, false);       // rule D
});

test("rule C and D: amount only, ambiguity, a family's whole balance", () => {
  const w = world();
  let r = S.score(L(10000, "monthly", "Lim Mei"), w); assert.deepEqual([r.rule, r.exact, r.ids], ["amount_only", true, ["i1"]]);
  assert.match(S.score(L(4000, "", "x"), w).reason, /^2 invoices are owed for exactly S\$40\.00/);
  assert.match(S.score(L(3000, "", "x"), w).reason, /^2 invoices are owed for exactly S\$30\.00/);
  r = S.score(L(15000, "school fees", "x"), w); assert.deepEqual([r.rule, r.exact, r.ids], ["household_total", true, ["i1", "i2"]]); assert.match(r.reason, /equals everything one family owes \(2 invoices\)/);
  assert.match(S.score(L(123, "who knows", "x"), w).reason, /^No invoice matches S\$1\.23\./);
  w.invoices.forEach((v) => { v.bal = 0; }); assert.equal(S.score(L(123, "x", "x"), w).reason, "No open invoice yet.");
});

test("rule B: a remembered payer pays only the exact amount; a link never overrides a wrong amount", () => {
  const w = world(); w.links["lim mei"] = "h1";
  let r = S.score(L(5000, "", "LIM,  Mei"), w); assert.deepEqual([r.rule, r.exact, r.auto, r.ids], ["payer_link", true, true, ["i2"]]); assert.equal(r.reason, "Known payer, exact amount.");
  r = S.score(L(3000, "", "lim mei"), w); assert.equal(r.exact, false); assert.equal(r.auto, false);
  assert.match(r.reason, /^Known payer, but no open invoice of exactly S\$30\.00\.|several combinations|Their open invoice/);
  w.invoices = w.invoices.filter((v) => v.id !== "i1"); r = S.score(L(3000, "", "lim mei"), w); assert.match(r.reason, /^Known payer\. Their open invoice is S\$50\.00, this is S\$20\.00 short\.$/);
  const y = world(); y.links["yeo su"] = "h5"; y.invoices = y.invoices.filter((v) => v.hid === "h5");
  r = S.score(L(4000, "", "YEO SU"), y); assert.deepEqual([r.rule, r.exact, r.auto, r.ids], ["household_total", true, false, ["i8", "i9"]]);
  assert.match(r.reason, /^Known payer\. This equals 2 of the family's open invoices/);
  assert.match(S.score(L(1000, "", "YEO SU"), y).reason, /^Known payer, but no open invoice of exactly S\$10\.00\./);
});

test("money out, zero-day and future lines are never matched", () => {
  const w = world();
  assert.match(S.score(L(-5000, "rent"), w).reason, /^Money out/);
  assert.match(S.score(L(100, "x", "x", "2026-11-28"), w).reason, /^Dated in the future/);
  assert.match(S.score(L(100, "x", "x", "2020-01-01"), w).reason, /^Too old/);
});

test("speed: a generated 5,000-line statement (400 invoices) is parsed, mapped and scored in well under 3 seconds", () => {
  const invoices = []; for (let i = 1; i <= 400; i++) invoices.push(inv("i" + i, "INV-" + i, "h" + (1 + (i % 150)), 5000 + (i % 37) * 100));
  const t0 = Date.now();
  const g = G.generate({ layout: "debit_credit", n: 5000, seed: 11, invoices: invoices.map((v) => ({ number: v.number, bal: v.bal })) });
  const t1 = Date.now();
  const delim = S.detectDelimiter(g.text), rows = S.parseCSV(g.text, delim), r = S.applyMapping(rows, g.mapping);
  const t2 = Date.now();
  assert.equal(r.errors.length, 0); assert.equal(r.lines.length, 5000);
  const ctx = { today: "2026-12-31", settings: {}, links: {}, invoices };
  let auto = 0, review = 0;
  r.lines.forEach((l) => { const s = S.score(l, ctx); if (s.auto) auto++; else review++; });
  const t3 = Date.now();
  assert.ok(auto > 100 && review > 100, "a realistic mix: " + auto + " paid by their number, " + review + " for review");
  assert.ok(t3 - t1 < 3000, "parse + map + score took " + (t3 - t1) + " ms");
  console.log("  5,000 lines: generate " + (t1 - t0) + " ms, parse+map " + (t2 - t1) + " ms, score " + (t3 - t2) + " ms");
});
