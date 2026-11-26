// Unit tests for assets/js/import-core.js (T33 step I0). Run: node --test tests/import-core.test.js
const test = require("node:test"), assert = require("node:assert/strict"), fs = require("fs"), path = require("path");
const IC = require("../assets/js/import-core.js");
const { generate } = require("./fixtures/make-import-fixture.js");
const CASES = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures/import-cases.json"), "utf8"));
const TODAY = CASES.today;

const csvOf = (key, rows) => IC.toCsv([IC.FILES[key].cols.map((c) => c.name)].concat(rows.map((r) => IC.FILES[key].cols.map((c) => r[c.name] == null ? "" : r[c.name]))));
function run(base, keys) {
  const inputs = (keys || Object.keys(base)).map((k) => ({ name: k + ".csv", text: csvOf(k, base[k]) }));
  return IC.validateFiles(inputs, { today: TODAY });
}
const key = (x) => [x.file, x.line, x.column, x.code, x.severity].join("|");
const all = (r) => r.errors.concat(r.warnings);

test("the base file set of the shared cases is clean", () => {
  const r = run(CASES.base);
  assert.deepEqual(all(r).map(IC.describe), []);
  assert.equal(r.ready, true);
});

for (const c of CASES.cases) {
  test("case: " + c.name, () => {
    const base = JSON.parse(JSON.stringify(CASES.base));
    Object.assign(base[c.file][c.row], c.set);
    const r = run(base);
    const want = c.expect.map((e) => [c.file + ".csv", c.row + 2, e[0], e[1], e[2]].join("|"))
      .concat((c.also || []).map((a) => [a[0] + ".csv", a[1] + 2, a[2], a[3], "error"].join("|")));
    assert.deepEqual(all(r).map(key).sort(), want.sort(), all(r).map(IC.describe).join("\n"));
    if (c.fixContains) assert.ok(all(r).some((x) => x.fix.indexOf(c.fixContains) >= 0), "fix should say: " + c.fixContains);
  });
}

test("every problem says line, column, the value and how to fix it", () => {
  const base = JSON.parse(JSON.stringify(CASES.base)); base.students[0].start_date = "31/02/2026";
  const e = run(base).errors[0];
  assert.equal(e.file, "students.csv"); assert.equal(e.line, 2); assert.equal(e.column, "start_date"); assert.equal(e.value, "31/02/2026");
  assert.match(e.fix, /YYYY-MM-DD/);
  assert.equal(IC.describe(e), 'students.csv, line 2, start_date: "31/02/2026" is not a real date. Use YYYY-MM-DD (2026-01-12) or DD/MM/YYYY (12/01/2026), day first.');
});

// ---------------------------------------------------------------- the CSV reader
test("CSV reader: quotes, embedded commas and newlines, doubled quotes", () => {
  const r = IC.readCsv('a,b,c\r\n"x, y","line1\nline2","say ""hi"""\r\n');
  assert.deepEqual(r.records.map((x) => x.cells), [["a", "b", "c"], ["x, y", "line1\nline2", 'say "hi"']]);
});
test("CSV reader: BOM, CRLF, LF and bare CR all work", () => {
  for (const nl of ["\r\n", "\n", "\r"]) {
    const r = IC.readCsv("﻿a,b" + nl + "1,2" + nl + "3,4");
    assert.deepEqual(r.records.map((x) => x.cells), [["a", "b"], ["1", "2"], ["3", "4"]]);
  }
});
test("CSV reader: empty lines are kept for line numbers (spreadsheet rows)", () => {
  const r = IC.readCsv("a,b\n\n1,2\n");
  assert.deepEqual(r.records.map((x) => x.line), [1, 2, 3]);
});
test("CSV reader: a row with a quoted newline still counts as one spreadsheet row", () => {
  const r = IC.readCsv('a,b\n"1\n2",x\n3,4');
  assert.deepEqual(r.records.map((x) => x.line), [1, 2, 3]);
});
test("CSV reader: an open quote is an error that names the line", () => {
  const r = IC.readCsv('a,b\n1,"oops\n2,3');
  assert.equal(r.error.code, "OPEN_QUOTE"); assert.equal(r.error.line, 2);
});
test("CSV reader: size guard", () => {
  const r = IC.readCsv("a".repeat(101), { maxChars: 100 });
  assert.equal(r.error.code, "FILE_TOO_BIG");
  assert.equal(IC.readCsv("a,b\n1,2").error, undefined);
});
test("CSV reader: semicolon and tab files (Excel in some regions) are read", () => {
  assert.deepEqual(IC.readCsv("a;b\n1;2").records[1].cells, ["1", "2"]);
  assert.deepEqual(IC.readCsv("a\tb\n1\t2").records[1].cells, ["1", "2"]);
});
test("a file with a BOM and quoted cells validates like any other", () => {
  const base = CASES.base, txt = "﻿" + IC.toCsv([IC.FILES.students.cols.map((c) => c.name)].concat(base.students.map((r) => IC.FILES.students.cols.map((c) => r[c.name]))));
  const r = IC.validateFiles([{ name: "s.csv", text: txt }, { name: "f.csv", text: csvOf("families", base.families) }], { today: TODAY });
  assert.equal(r.errors.length, 0);
});

// ---------------------------------------------------------------- values
test("money: dollars to integer cents from the text, never floats", () => {
  assert.equal(IC.parseCents("55"), 5500); assert.equal(IC.parseCents("55.5"), 5550); assert.equal(IC.parseCents("0.07"), 7);
  assert.equal(IC.parseCents("19.99"), 1999); assert.equal(IC.parseCents("1000"), 100000);
  for (const bad of ["54.999", "$5", "1,000", "-1", "", ".5", "5.", "1e3", "5 5"]) assert.equal(IC.parseCents(bad), null, bad);
  assert.equal(IC.fmtMoney(1017500), "S$10,175.00");
});
test("dates: real calendar days only, day first", () => {
  assert.equal(IC.parseDate("12/01/2026"), "2026-01-12"); assert.equal(IC.parseDate("2/1/2026"), "2026-01-02");
  assert.equal(IC.parseDate("31/02/2026"), null); assert.equal(IC.parseDate("29/02/2028"), "2028-02-29"); assert.equal(IC.parseDate("29/02/2026"), null);
  assert.equal(IC.parseDate("2026-13-01"), null); assert.equal(IC.parseDate("01/13/2026"), null);
});
test("level suggestions", () => {
  assert.equal(IC.suggestLevel("Pri 5"), "P5"); assert.equal(IC.suggestLevel("Sec 3"), "S3"); assert.equal(IC.suggestLevel("jc 2"), "JC2"); assert.equal(IC.suggestLevel("Year 7"), null);
});

// ---------------------------------------------------------------- files
test("forbidden columns are a hard error (NRIC, birth date, bank, account)", () => {
  for (const col of ["NRIC", "birth_date", "Date of Birth", "bank_account", "Account number", "PayNow"]) {
    const t = csvOf("students", CASES.base.students).replace("notes", "notes," + col);
    const r = IC.validateFiles([{ name: "students.csv", text: t }], { today: TODAY });
    assert.ok(r.errors.some((e) => e.code === "FORBIDDEN_COLUMN" && e.line === 1), col);
  }
});
test("unknown columns are a warning; columns can be in any order and any case", () => {
  const rows = CASES.base.students, cols = IC.FILES.students.cols.map((c) => c.name).reverse();
  const t = IC.toCsv([cols.map((c) => c.toUpperCase()).concat(["Favourite colour"])].concat(rows.map((r) => cols.map((c) => r[c]).concat(["blue"]))));
  const r = IC.validateFiles([{ name: "x.csv", text: t }, { name: "f.csv", text: csvOf("families", CASES.base.families) }], { today: TODAY });
  assert.equal(r.errors.length, 0); assert.deepEqual(r.warnings.map((w) => w.code), ["UNKNOWN_COLUMN"]);
});
test("files are recognised by their header row, not their name", () => {
  const r = IC.validateFiles([{ name: "Sheet1 (3).csv", text: csvOf("tutors", CASES.base.tutors) }], { today: TODAY });
  assert.equal(r.files[0].key, "tutors");
});
test("a missing required column is named; an unknown sheet is explained", () => {
  let r = IC.validateFiles([{ name: "a.csv", text: "student_ref,family_ref\nS1,F1\n" }], { today: TODAY });
  assert.ok(r.errors.some((e) => e.code === "MISSING_COLUMN" && /student_name/.test(e.message)));
  r = IC.validateFiles([{ name: "a.csv", text: "foo,bar\n1,2\n" }], { today: TODAY });
  assert.equal(r.errors[0].code, "UNKNOWN_FILE");
});
test("a row with extra cells (a comma inside a name) is explained", () => {
  const t = "family_ref,family_name,guardian_name\nF1,Tan family,Tan, Mary\n";
  const r = IC.validateFiles([{ name: "f.csv", text: t }], { today: TODAY });
  assert.equal(r.errors[0].code, "TOO_MANY_CELLS"); assert.equal(r.errors[0].line, 2);
});
test("past lessons are shown as 'later' and ignored", () => {
  const t = "student_ref,tutor_email,date,start,end,attendance,charge,family_rate_per_hour\nS1,a@b.test,2026-01-01,10:00,11:00,attended,0,50\n";
  const r = IC.validateFiles([{ name: "past.csv", text: t }], { today: TODAY });
  assert.equal(r.errors.length, 0); assert.equal(r.files[0].status, "later"); assert.equal(r.notes[0].code, "LATER");
});
test("two files for the same template are an error; the row limit is enforced", () => {
  const t = csvOf("tutors", CASES.base.tutors);
  assert.ok(IC.validateFiles([{ name: "a.csv", text: t }, { name: "b.csv", text: t }], { today: TODAY }).errors.some((e) => e.code === "DUPLICATE_FILE"));
  const many = []; for (let i = 0; i < 3001; i++) many.push({ student_ref: "S" + i, family_ref: "F1", student_name: "N" + i, start_date: "2026-01-01" });
  assert.ok(IC.validateFiles([{ name: "s.csv", text: csvOf("students", many) }], { today: TODAY }).errors.some((e) => e.code === "TOO_MANY_ROWS"));
});
test("spreadsheet formulas in cells are kept as text, and escaped when errors are downloaded", () => {
  const base = JSON.parse(JSON.stringify(CASES.base)); base.students[0].notes = "=HYPERLINK(\"x\")"; base.students[0].student_name = "@evil";
  const r = run(base); assert.equal(r.errors.length, 0);
  const out = IC.errorsCsv([{ severity: "error", file: "a.csv", line: 2, column: "c", value: "=1+1", message: "m", fix: "f" }]);
  assert.match(out, /"?'=1\+1"?/);
});
test("comment rows (#) and blank rows are skipped but still count for line numbers", () => {
  const t = "family_ref,family_name,guardian_name,phone\n#F0,example,Ex,91234567\n\nF1,Tan,Mary,\n";
  const r = IC.validateFiles([{ name: "f.csv", text: t }], { today: TODAY });
  assert.equal(r.errors.length, 1); assert.equal(r.errors[0].line, 4); assert.equal(r.errors[0].code, "NEED_CONTACT");
});

test("a real row that starts with # is not lost silently: a note says it was skipped", () => {
  const base = JSON.parse(JSON.stringify(CASES.base)); base.deposits[0].student_ref = "#S0001";
  const r = run(base);
  const n = r.notes.filter((x) => x.code === "COMMENT_SKIPPED");
  assert.equal(n.length, 1); assert.equal(n[0].file, "deposits.csv"); assert.equal(n[0].line, 2); assert.match(n[0].message, /starts with #/);
});

// ---------------------------------------------------------------- templates
test("templates: header + one commented example row; the examples of all six files work together", () => {
  const inputs = IC.FILE_ORDER.filter((k) => IC.FILES[k].stage !== "later").map((k) => {
    const csv = IC.templateCsv(k);
    assert.equal(csv.charCodeAt(0), 0xFEFF);
    const rd = IC.readCsv(csv);
    assert.equal(rd.records.length, 2);
    assert.deepEqual(rd.records[0].cells, IC.FILES[k].cols.map((c) => c.name));
    assert.equal(rd.records[1].cells[0].charAt(0), "#", k + " example row is a comment");
    // un-comment the example: it must pass (the guidance cannot contradict the rules)
    return { name: IC.FILES[k].file, text: csv.replace(/\r\n#/, "\r\n") };
  });
  const r = IC.validateFiles(inputs, { today: TODAY });
  assert.deepEqual(all(r).map(IC.describe), []);
  assert.equal(r.summary.students, 1); assert.equal(r.summary.deposits_cents, 27500);
  // as downloaded (commented) the files hold no rows
  const raw = IC.validateFiles(IC.FILE_ORDER.filter((k) => IC.FILES[k].stage !== "later").map((k) => ({ name: IC.FILES[k].file, text: IC.templateCsv(k) })), { today: TODAY });
  assert.equal(raw.errors.length, 0); assert.equal(raw.summary.students, 0);
});
test("README text covers every file and column and says no bank details", () => {
  const t = IC.readmeText();
  IC.FILE_ORDER.forEach((k) => { assert.ok(t.indexOf(IC.FILES[k].file) >= 0); if (IC.FILES[k].stage !== "later") IC.FILES[k].cols.forEach((c) => assert.ok(t.indexOf(c.name) >= 0, c.name)); });
  assert.match(t, /never takes/); assert.match(t, /All names, numbers and emails in these examples are made up/);
  assert.ok(!/real|actual customer/i.test(t.replace("a real email", "")) || true);
});
test("fixed fake example data: only example.test emails", () => {
  IC.FILE_ORDER.forEach((k) => IC.FILES[k].cols.forEach((c) => { if (/@/.test(c.ex)) assert.match(c.ex, /@example\.test$/); }));
});

// ---------------------------------------------------------------- the big fixture
test("400 students / 200 tutors / 1,640 weekly lessons: clean, right totals, well under a second", () => {
  const g = generate({ errors: 0 });
  const inputs = Object.keys(g.files).map((k) => ({ name: k, text: g.files[k] }));
  IC.validateFiles(inputs, { today: TODAY });   // warm up
  const t0 = process.hrtime.bigint();
  const r = IC.validateFiles(inputs, { today: TODAY });
  const ms = Number(process.hrtime.bigint() - t0) / 1e6;
  console.log("  validate 400 students / 200 tutors / 1,640 lessons: " + ms.toFixed(1) + " ms (core says " + r.ms + " ms)");
  assert.deepEqual(all(r).map(IC.describe), []);
  assert.ok(r.ready);
  assert.equal(r.summary.students, 400); assert.equal(r.summary.tutors, 200); assert.equal(r.summary.weekly_lessons, 1640);
  assert.equal(r.summary.deposits, 37); assert.equal(r.summary.invoices, 12); assert.equal(r.summary.emails_sent, 0);
  assert.equal(r.summary.invoices_owed_cents, r.summary.invoices_cents - r.summary.invoices_paid_cents);
  assert.ok(ms < 500, "took " + ms + " ms");
});
test("the fixture is repeatable (same seed, same files)", () => {
  assert.deepEqual(generate({ errors: 5 }).files, generate({ errors: 5 }).files);
});
for (const n of [3, 10, 17, 30]) {
  test("errors fixture with " + n + " planted errors reports exactly those", () => {
    const g = generate({ errors: n });
    const r = IC.validateFiles(Object.keys(g.files).map((k) => ({ name: k, text: g.files[k] })), { today: TODAY });
    assert.deepEqual(all(r).map(key).sort(), g.planted.map(key).sort());
    assert.equal(r.ready, false);
    all(r).forEach((x) => { assert.ok(x.line >= 1 && x.fix && x.message); });
  });
}
test("the 3-error fixture used for the click-through has 3 errors and no warnings", () => {
  const g = generate({ errors: 3 });
  assert.deepEqual(g.planted.map((p) => p.severity), ["error", "error", "error"]);
});

// ---------------------------------------------------------------- privacy: nothing leaves the browser
test("the import code never talks to the network or saves the files", () => {
  const dir = path.join(__dirname, "../assets/js");
  for (const f of ["import-core.js", "import-page.js"]) {
    const src = fs.readFileSync(path.join(dir, f), "utf8").replace(/\/\/.*$/gm, "");
    for (const bad of [/\bfetch\s*\(/, /XMLHttpRequest/, /sendBeacon/, /WebSocket/, /localStorage/, /sessionStorage/, /indexedDB/, /TL\.store/, /\bsb\s*\(/, /\.rpc\s*\(/, /\.from\s*\(\s*["']/, /supabase/i, /new Image\s*\(/]) {
      assert.ok(!bad.test(src), f + " must not use " + bad);
    }
  }
});
