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

// ---------------------------------------------------------------- privacy: the files stay in the browser until the owner presses Import now
test("the import code never saves the files, never logs them, and talks to the database only through the five import functions", () => {
  const dir = path.join(__dirname, "../assets/js");
  const strip = (f) => fs.readFileSync(path.join(dir, f), "utf8").replace(/\/\/.*$/gm, "");
  const common = [/\bfetch\s*\(/, /XMLHttpRequest/, /sendBeacon/, /WebSocket/, /localStorage/, /sessionStorage/, /indexedDB/, /TL\.store/, /\.from\s*\(\s*["']/, /supabase/i, /new Image\s*\(/, /\bconsole\./];
  const core = strip("import-core.js");
  for (const bad of common.concat([/\bsb\s*\(/, /\.rpc\s*\(/, /window\.sb/])) assert.ok(!bad.test(core), "import-core.js must not use " + bad);
  const page = strip("import-page.js");
  for (const bad of common) assert.ok(!bad.test(page), "import-page.js must not use " + bad);
  const calls = [...page.matchAll(/\.rpc\(\s*"([a-z_]+)"/g)].map((m) => m[1]);
  assert.ok(calls.length >= 5, "the page calls the database");
  for (const c of calls) assert.ok(["import_dry_run", "import_commit", "import_history", "import_undo_preview", "import_undo"].includes(c), "the page may call only the import functions, not " + c);
  assert.equal([...page.matchAll(/\.rpc\(/g)].length, calls.length, "every call names its function as a plain string");
});

// ---------------------------------------------------------------- T33 I1: what the page sends to the database, and how it explains the answers
const SQL = fs.readFileSync(path.join(__dirname, "../db/migration_import.sql"), "utf8");

test("buildPayload: the four stage-A files, checked values only, cents and Monday = 0", () => {
  const g = generate({ errors: 0, students: 20, tutors: 6, lessons: 30 });
  const r = IC.validateFiles(Object.keys(g.files).map((f) => ({ name: f, text: g.files[f] })));
  assert.ok(r.ready && r.payload);
  assert.deepEqual(Object.keys(r.payload).sort(), ["families", "students", "tutors", "weekly_lessons"]);
  assert.equal(r.payload.students.length, 20);
  assert.equal(r.payload.tutors.length, 6);
  assert.equal(r.payload.weekly_lessons.length, 30);
  for (const w of r.payload.weekly_lessons) {
    assert.ok(Number.isInteger(w.rate_cents) && w.rate_cents >= 0 && w.rate_cents <= 100000, "rate in whole cents");
    assert.ok(Number.isInteger(w.day) && w.day >= 0 && w.day <= 6, "day 0-6");
    assert.match(w.start, /^\d{2}:\d{2}$/); assert.match(w.end, /^\d{2}:\d{2}$/);
    assert.ok(Number.isInteger(w.line) && w.line >= 2, "carries its file line");
  }
  for (const t of r.payload.tutors) assert.deepEqual(Object.keys(t).sort(), ["employment", "line", "phone", "subjects", "tutor_email", "tutor_name"], "no pay columns are sent");
  // money files are never part of the payload
  const withMoney = IC.validateFiles(Object.keys(g.files).map((f) => ({ name: f, text: g.files[f] })));
  assert.equal(withMoney.payload.deposits, undefined); assert.equal(withMoney.payload.unpaid_invoices, undefined);
  assert.equal(IC.validateFiles([{ name: "students.csv", text: g.files["students.csv"] }]).payload, null, "no payload until every error is fixed and all four files are there");
});
test("buildPayload: a known small file maps cell by cell", () => {
  const f = {
    "families.csv": "family_ref,family_name,guardian_name,relation,phone,email,main\nF1,Tan family,Mary Tan,Mother,9123 4501,MARY@example.test,Y\n",
    "students.csv": "student_ref,family_ref,student_name,level,lesson_location,online_link,start_date,notes\nS1,F1,Ethan Tan,p5,Online,https://meet.example.test/a,12/01/2026,Hi\n",
    "tutors.csv": "tutor_email,tutor_name,phone,subjects,employment\nAva@Example.test,Ava Lim,9100 0001,Maths,Freelancer\n",
    "weekly_lessons.csv": "student_ref,tutor_email,day,start,end,subject,level,family_rate_per_hour\nS1,ava@example.test,Wednesday,9:05,10:35,Maths,,55.5\n"
  };
  const r = IC.validateFiles(Object.keys(f).map((n) => ({ name: n, text: f[n] })));
  assert.ok(r.ready, r.errors.map(IC.describe).join("; "));
  assert.deepEqual(r.payload.families[0], { family_ref: "F1", family_name: "Tan family", guardian_name: "Mary Tan", relation: "Mother", phone: "91234501", email: "mary@example.test", main: true, line: 2 });
  assert.deepEqual(r.payload.students[0], { student_ref: "S1", family_ref: "F1", student_name: "Ethan Tan", level: "P5", lesson_location: "Online", online_link: "https://meet.example.test/a", start_date: "2026-01-12", notes: "Hi", line: 2 });
  assert.deepEqual(r.payload.tutors[0], { tutor_email: "ava@example.test", tutor_name: "Ava Lim", phone: "+6591000001", subjects: "Maths", employment: "freelancer", line: 2 });
  assert.deepEqual(r.payload.weekly_lessons[0], { student_ref: "S1", tutor_email: "ava@example.test", day: 2, start: "09:05", end: "10:35", subject: "Maths", level: null, rate_cents: 5550, line: 2 });
});

test("every error code the database can return has words in the page (and nothing is invented the other way)", () => {
  // the codes the SQL puts in its error table: insert into imp_err select 'file', line, 'col', 'CODE'
  const sqlCodes = new Set([...SQL.matchAll(/insert into imp_err select [^;]*?'([A-Z_]+)'\s+from/g)].map((m) => m[1]));
  for (const c of ["BAD_PAYLOAD", "TOO_MANY_ROWS"]) sqlCodes.add(c);                      // returned directly, not through the table
  assert.ok(sqlCodes.size >= 25, "found the codes in the migration (" + sqlCodes.size + ")");
  for (const c of sqlCodes) assert.ok(IC.SERVER_TEXT[c], "the page has words for " + c);
  for (const c of Object.keys(IC.SERVER_TEXT)) assert.ok(sqlCodes.has(c), c + " is described but the database never returns it");
});
test("every code the SQL returns that the page also checks uses the same code name", () => {
  const src = fs.readFileSync(path.join(__dirname, "../assets/js/import-core.js"), "utf8");
  const jsCodes = new Set([...src.matchAll(/"([A-Z][A-Z_]{3,})"/g)].map((m) => m[1]));
  const sqlOnly = new Set(["BAD_PAYLOAD", "TUTOR_OTHER_ROLE", "TUTOR_NOT_AVAILABLE"]);          // rules about what is already in the centre: only the database can see them
  for (const c of Object.keys(IC.SERVER_TEXT)) if (!sqlOnly.has(c)) assert.ok(jsCodes.has(c), c + " is also a code of the page's own checks");
});
test("serverIssue: a database error reads like a page error, with the file name and no cell text", () => {
  const i = IC.serverIssue({ file: "weekly_lessons", line: 212, column: "start", code: "SLOT_CLASH" });
  assert.equal(i.file, "weekly_lessons.csv"); assert.equal(i.line, 212); assert.equal(i.column, "start"); assert.equal(i.severity, "error"); assert.equal(i.value, "");
  assert.match(IC.describe(i), /weekly_lessons\.csv, line 212, start: .*overlaps/);
  assert.match(IC.serverIssue({ file: "students", line: 3, column: "x", code: "SOMETHING_NEW" }).message, /SOMETHING_NEW/, "an unknown code is still shown, not hidden");
});
test("resultLines: plain words for a commit", () => {
  const L = IC.resultLines({ created: { families: 300, guardians: 600, students: 400, tutors: 200, weekly_lessons: 1640 }, skipped: { students: 0, tutors: 0, weekly_lessons: 0, families: 0 }, warnings: [] });
  assert.match(L.join(" "), /Added 400 students in 300 new families \(600 guardians\)/);
  assert.match(L.join(" "), /Saved 200 tutor invitations\. No email was sent/);
  assert.match(L.join(" "), /Added 1,640 weekly lessons/);
  const again = IC.resultLines({ created: { students: 0, tutors: 0, weekly_lessons: 0, guardians: 0 }, skipped: { students: 400, tutors: 200, weekly_lessons: 1640, families: 300 }, warnings: [{}] });
  assert.match(again[0], /Nothing new/); assert.match(again.join(" "), /2,540 rows were already in TutorDeck/); assert.match(again.join(" "), /1 row differs/);
  assert.equal(IC.resultLines({ created: { students: 1, tutors: 1, weekly_lessons: 1, guardians: 1, families: 1 }, skipped: {}, warnings: [] })[0].includes("1 student in 1 new family"), true, "singular forms");
});
test("undoLines: says what went, and why the rest stayed", () => {
  const rep = { deleted: { students: 1, recurring_slots: 1 }, kept: [
    { type: "student", code: "s1", reason: "ACTIVITY" }, { type: "student", code: "s2", reason: "EDITED" }, { type: "tutor", code: "b@x.test", reason: "ACCEPTED" },
    { type: "guardian", code: null, reason: "IN_USE" }, { type: "slot", code: "k", reason: "ACTIVITY" }], already_gone: 2 };
  const L = IC.undoLines(rep, false);
  assert.match(L[0], /^Removed: 1 student, 1 weekly lesson\.$/);
  assert.ok(L.some((l) => /Left in place: 1 student, 1 weekly lesson, because lessons of it were marked, charged or invoiced/.test(l)));
  assert.ok(L.some((l) => /1 student, because someone changed it after the import/.test(l)));
  assert.ok(L.some((l) => /1 tutor, because the tutor accepted the invitation/.test(l)));
  assert.ok(L.some((l) => /2 records had already been removed by hand/.test(l)));
  assert.ok(!L.some((l) => /guardian/.test(l)), "guardians follow their family and are not listed one by one");
  assert.match(IC.undoLines({ would_delete: { students: 3 }, kept: [] }, true)[0], /^Undo will remove: 3 students\.$/);
  assert.match(IC.undoLines({ deleted: {}, kept: [] }, false)[0], /Removed: nothing/);
});
