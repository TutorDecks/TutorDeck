// node --test tests/   — centre data export (T35-E): the column list matches the database's catalogue, the data dictionary file is current, the CSV writer
// (quotes, commas, newlines, emoji and Chinese, formula guard, BOM, dollars columns), the ZIP writer (read back with an independent reader), and the whole export loop
// against a pretend database (paging, retries, refusals, masked/full flag, 100,000-row tables without holding them in memory). All names are made up.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const zlib = require("node:zlib");
const path = require("node:path");
const cp = require("node:child_process");
const os = require("node:os");
const X = require("../assets/js/org-export-core.js");
const SQL = fs.readFileSync(path.join(__dirname, "..", "db", "migration_org_export.sql"), "utf8");

// ---------------------------------------------------------------- the database's catalogue, parsed out of the migration
function sqlCatalogue() {
  const body = SQL.slice(SQL.indexOf("create or replace function public.org_export_catalog()"), SQL.indexOf("-- ---------------------------------------------------------------- internal helpers"));
  const re = /\(\s*'(\w+)',\s*'(include|exclude)',\s*'(\w+)',\s*'(\w+)',\s*'(\w+)',\s*(null|'(?:[^']|'')*'),\s*array\[([\s\S]*?)\](?:::text\[\])?,\s*(null|'(?:[^']|'')*')\s*\)/g;
  const out = []; let m;
  while ((m = re.exec(body))) {
    const cols = [...m[7].matchAll(/'((?:[^']|'')*)'/g)].map((x) => x[1].replace(/''/g, "'"));
    out.push({ tbl: m[1], mode: m[2], org_col: m[3], key_col: m[4], key_type: m[5], cols, reason: m[8] === "null" ? null : m[8].slice(1, -1).replace(/''/g, "'") });
  }
  return out;
}
const SQLCAT = sqlCatalogue();

test("the column list in the code is the database's catalogue: same tables, same order, same columns", () => {
  const inc = SQLCAT.filter((t) => t.mode === "include");
  assert.ok(inc.length >= 30, "parsed " + inc.length + " included tables from the migration");
  assert.deepEqual(X.CATALOG.map((t) => t.tbl), inc.map((t) => t.tbl), "tables, in the same order");
  for (const t of inc) {
    const js = X.CATALOG.find((c) => c.tbl === t.tbl);
    assert.deepEqual(js.cols.map((c) => c[0]), t.cols.map((c) => c.split("=")[0]), "columns of " + t.tbl);
  }
});

test("excluded tables and their reasons are the same words in the database and in the README", () => {
  const exc = SQLCAT.filter((t) => t.mode === "exclude");
  assert.deepEqual(X.EXCLUDED.map((e) => e.tbl), exc.map((e) => e.tbl));
  for (const e of exc) assert.equal(X.EXCLUDED.find((x) => x.tbl === e.tbl).reason, e.reason, e.tbl);
  assert.ok(X.EXCLUDED.every((e) => e.reason.length > 30));
});

test("every column has a plain-words description, names are unique, file names are unique", () => {
  const files = new Set();
  for (const t of X.CATALOG) {
    assert.ok(t.title && t.about && t.file.endsWith(".csv"), t.tbl);
    assert.ok(!files.has(t.file), "duplicate file " + t.file); files.add(t.file);
    const names = new Set();
    for (const [c, d] of t.cols) { assert.ok(d && d.length >= 4, t.tbl + "." + c + " has no description"); assert.ok(!names.has(c), "duplicate column " + t.tbl + "." + c); names.add(c); }
  }
});

test("no exported column looks like a secret or a login id (same rule as the SQL test)", () => {
  for (const t of X.CATALOG) for (const [c] of t.cols) {
    assert.ok(!/(token|hash|secret|_enc|stripe|password|refresh|share|brevo|gcal)/i.test(c), t.tbl + "." + c);
    assert.ok(!["user_id", "tutor_id", "owner_id"].includes(c), t.tbl + "." + c);
  }
  // every person-reference column is documented as a name, never an id
  for (const t of X.CATALOG) for (const [c, d] of t.cols) if (/(created_by|issued_by|recorded_by|requested_by|actor|decided_by|granted_by|sent_by|marked_by|changed_by_tutor)$/.test(c)) assert.match(d, /person's name/, t.tbl + "." + c);
});

test("docs/centre-data-export-dictionary.md is generated from this list and up to date (run: node tests/gen-export-dictionary.js)", () => {
  const file = fs.readFileSync(path.join(__dirname, "..", "docs", "centre-data-export-dictionary.md"), "utf8");
  assert.equal(file, X.dictionaryMarkdown() + "\n");
  for (const t of X.CATALOG) for (const [c] of t.cols) assert.ok(file.includes("`" + c + "`"), c + " is in the dictionary file");
  assert.ok(file.includes(X.PROMISE) && file.includes("PDPA"));
});

// ---------------------------------------------------------------- CSV
test("CSV cells: quotes, commas, newlines, emoji and Chinese, nulls and booleans", () => {
  assert.equal(X.csvCell("plain"), "plain");
  assert.equal(X.csvCell("a,b"), "\"a,b\"");
  assert.equal(X.csvCell("say \"hi\""), "\"say \"\"hi\"\"\"");
  assert.equal(X.csvCell("line1\nline2"), "\"line1\nline2\"");
  assert.equal(X.csvCell("O'Neil, Jr \"Q\" 🙂"), "\"O'Neil, Jr \"\"Q\"\" 🙂\"");
  assert.equal(X.csvCell("陈小明"), "陈小明");
  assert.equal(X.csvCell(null), ""); assert.equal(X.csvCell(undefined), "");
  assert.equal(X.csvCell(true), "true"); assert.equal(X.csvCell(false), "false");
  assert.equal(X.csvCell(0), "0"); assert.equal(X.csvCell(-250), "-250"); assert.equal(X.csvCell(12.5), "12.5");
  assert.equal(X.csvCell(" padded "), "\" padded \"", "leading/trailing spaces survive");
  assert.equal(X.csvCell(["manage_students", "view_revenue"]), "manage_students; view_revenue");
  assert.equal(X.csvCell({ a: 1, b: "x,y" }), "\"{\"\"a\"\":1,\"\"b\"\":\"\"x,y\"\"}\"");
  assert.equal(X.csvCell({}), "{}");
});

test("formula guard: text a spreadsheet would run gets an apostrophe; plain numbers and ordinary text do not", () => {
  for (const bad of ["=HYPERLINK(\"http://x\")", "+SUM(A1)", "-2+3", "@cmd", "=1+1", "\tTAB", "+65 9123 4567"]) assert.ok(X.csvCell(bad).replace(/^"/, "").startsWith("'"), JSON.stringify(bad));
  for (const ok of ["-12", "+65", "3.5", "-0.25", "a=b", "x+y", "Mr -Lim", "e-mail"]) assert.ok(!X.csvCell(ok).startsWith("'"), JSON.stringify(ok));
  assert.equal(X.csvCell(-12), "-12", "a real negative number is not text");
  assert.equal(X.csvCell(["=evil", "ok"]), "'=evil; ok");
});

test("cents get an exact dollars column (no floating point)", () => {
  assert.deepEqual(X.outputColumns(["id", "total_cents", "x"]), ["id", "total_cents", "total_dollars", "x"]);
  const cases = [[0, "0.00"], [5, "0.05"], [99, "0.99"], [100, "1.00"], [1250, "12.50"], [10900, "109.00"], [-500, "-5.00"], [-5, "-0.05"], [123456789, "1234567.89"], [null, ""], ["", ""], [1.5, ""]];
  for (const [c, d] of cases) assert.equal(X.centsToDollars(c), d, String(c));
  assert.equal(X.csvRows(["id", "amount_cents"], [["a", 1250], ["b", null]]), "a,1250,12.50\r\nb,,\r\n");
});

test("header: a BOM (so Excel reads UTF-8), CRLF line ends, technical column names, dollars columns", () => {
  const h = X.csvHeader(["id", "name", "fee_cents"]);
  assert.equal(h, "﻿id,name,fee_cents,fee_dollars\r\n");
  assert.ok(!h.slice(1).includes("﻿"));
  const out = X.csvRows(["id", "name"], [["1", "Ann O'Neil, Jr"], ["2", "陈"]]);
  assert.equal(out, "1,\"Ann O'Neil, Jr\"\r\n2,陈\r\n");
});

// ---------------------------------------------------------------- ZIP, read back by an independent reader
function readZip(buf) {
  const eocd = buf.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06])); assert.ok(eocd >= 0, "end record");
  const n = buf.readUInt16LE(eocd + 10), cdOff = buf.readUInt32LE(eocd + 16); let p = cdOff; const files = {};
  for (let i = 0; i < n; i++) {
    assert.equal(buf.readUInt32LE(p), 0x02014b50);
    const flags = buf.readUInt16LE(p + 8), method = buf.readUInt16LE(p + 10), crc = buf.readUInt32LE(p + 16), cs = buf.readUInt32LE(p + 20), us = buf.readUInt32LE(p + 24);
    const nl = buf.readUInt16LE(p + 28), el = buf.readUInt16LE(p + 30), cl = buf.readUInt16LE(p + 32), off = buf.readUInt32LE(p + 42), name = buf.slice(p + 46, p + 46 + nl).toString("utf8");
    assert.equal(flags & 0x0800, 0x0800, "UTF-8 name flag");
    assert.equal(buf.readUInt32LE(off), 0x04034b50); const lnl = buf.readUInt16LE(off + 26), lel = buf.readUInt16LE(off + 28), start = off + 30 + lnl + lel;
    const raw = buf.slice(start, start + cs), data = method === 8 ? zlib.inflateRawSync(raw) : raw;
    assert.equal(data.length, us, name + " size"); assert.equal(zlib.crc32 ? zlib.crc32(data) : X.crc32(data), crc, name + " crc");
    files[name] = { data, method, cs, us }; p += 46 + nl + el + cl;
  }
  return files;
}
const blobBuf = async (b) => Buffer.from(await b.arrayBuffer());

test("crc32 matches the standard check value", () => {
  assert.equal(X.crc32(Buffer.from("123456789")), 0xCBF43926);
  assert.equal(X.crc32(Buffer.from("6789"), X.crc32(Buffer.from("12345"))), 0xCBF43926, "incremental");
  assert.equal(X.crc32(Buffer.alloc(0)), 0);
});

test("ZIP writer: stored and deflated files read back byte for byte, names in UTF-8, CRCs right", async () => {
  for (const compress of [false, true]) {
    const z = new X.ZipWriter({ compress, now: new Date(2026, 10, 27, 10, 30, 0) });
    const big = "row,陈小明,\"O'Neil\"\r\n".repeat(5000);
    await z.addText("a.csv", "hello\r\n"); await z.addText("empty.csv", ""); await z.addText("陈 notes.txt", "x");
    await z.addStreamed("big.csv", async (emit) => { for (let i = 0; i < 5; i++) emit(big); });
    const files = readZip(await blobBuf(z.finish()));
    assert.deepEqual(Object.keys(files), ["a.csv", "empty.csv", "陈 notes.txt", "big.csv"]);
    assert.equal(files["a.csv"].data.toString(), "hello\r\n"); assert.equal(files["empty.csv"].data.length, 0); assert.equal(files["big.csv"].data.toString(), big.repeat(5));
    if (compress) assert.ok(files["big.csv"].method === 8 && files["big.csv"].cs < files["big.csv"].us / 5, "the big file is deflated"); else assert.equal(files["big.csv"].method, 0);
  }
});

test("the ZIP opens in unzip and Python (independent tools), when they are installed", async (t) => {
  const have = (c) => cp.spawnSync("sh", ["-c", "command -v " + c]).status === 0;
  const z = new X.ZipWriter(); await z.addText("one.csv", "a,b\r\n1,2\r\n"); await z.addStreamed("陈.csv", async (e) => e("x,y\r\n".repeat(3000)));
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "zipchk-")), f = path.join(dir, "t.zip"); fs.writeFileSync(f, await blobBuf(z.finish()));
  if (have("unzip")) { const r = cp.spawnSync("unzip", ["-tq", f]); assert.equal(r.status, 0, r.stdout + r.stderr); } else t.diagnostic("unzip not installed");
  if (have("python3")) { const r = cp.spawnSync("python3", ["-I", "-c", "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; print(sorted(z.namelist()))", f]); assert.equal(r.status, 0, r.stderr.toString()); } else t.diagnostic("python3 not installed");
  fs.rmSync(dir, { recursive: true });
});

// ---------------------------------------------------------------- the whole export against a pretend database
// rows(tbl) -> array of arrays in catalogue order; counts and pages like the real functions
function fakeDb(rowsOf, opts) {
  opts = opts || {}; const calls = []; let job = 41, started = null, finished = 0, pageFails = opts.pageFails || 0;
  const rpc = (name, args) => { const p = rpc0(name, args); return { then: (a, b) => p.then(a, b) }; };     // a thenable only, like the Supabase builder (no .catch)
  const rpc0 = async (name, args) => {
    calls.push([name, args]);
    if (opts.refuse) return { error: { message: "NOT_FOUND", code: "P0001" } };
    if (name === "org_export_start") { started = args; return { data: { job, full_payout: !!args.p_full_payout, tables: X.CATALOG.map((t) => ({ tbl: t.tbl, rows: rowsOf(t.tbl).length })).concat(opts.extraTable ? [{ tbl: "mystery", rows: 1 }] : []) } }; }
    if (name === "org_export_page") {
      if (pageFails > 0) { pageFails--; return { error: { message: "Failed to fetch" } }; }
      const t = X.CATALOG.find((c) => c.tbl === args.p_table), all = rowsOf(t.tbl), start = args.p_after ? Number(args.p_after) : 0, lim = Math.min(Math.max(args.p_limit, 1), 5000), rows = all.slice(start, start + lim);
      return { data: { cols: opts.wrongCols ? ["x"] : t.cols.map((c) => c[0]), rows, next: rows.length === lim ? String(start + lim) : null } };
    }
    if (name === "org_export_finish") { finished++; const ok = X.CATALOG.every((t) => args.p_counts[t.tbl] === rowsOf(t.tbl).length); return { data: { matched: ok, differs: [] } }; }
    return { error: { message: "unexpected " + name } };
  };
  return { rpc, calls, get started() { return started; }, get finished() { return finished; } };
}
const cell = (t, c, i) => { // a value for column c of table t, row i
  if (/_cents$/.test(c)) return 1000 + i; if (c === "id" || /_id$/.test(c)) return "00000000-0000-0000-0000-" + String(i).padStart(12, "0");
  if (/^(lesson_date|starts_on|ends_on|exam_date)$/.test(c)) return "2026-11-" + String(1 + (i % 28)).padStart(2, "0");
  if (c === "name" || c === "display_name" || c === "student_name" || c === "tutor_name") return "Name, " + i + " \"Q\" 🙂陈";
  if (c === "before" || c === "after" || c === "settings" || c === "data") return { n: i, text: "line\nbreak" };
  if (c === "permissions") return ["manage_students", "view_revenue"];
  if (/^(active|paid|trial|one_off|postponed|locked|taxable|billable)$/.test(c)) return i % 2 === 0;
  return i % 7 === 0 ? null : c + "-" + i;
};
const makeRows = (spec) => (tbl) => { const t = X.CATALOG.find((c) => c.tbl === tbl), n = spec[tbl] || 0, out = []; for (let i = 0; i < n; i++) out.push(t.cols.map((c) => cell(tbl, c[0], i))); return out; };

test("a whole export: one CSV per table + README, row counts equal, finish told the counts, payout flag passed through", async () => {
  const spec = { students: 7, lessons: 12, households: 3, audit_log: 4 }, db = fakeDb(makeRows(spec)), progress = [];
  const r = await X.runExport(db.rpc, { orgId: "ORG1", centreName: "Bright Minds Centre", fullPayout: false, now: () => new Date(2026, 10, 27, 9, 5), onProgress: (p) => progress.push(p) });
  assert.equal(r.filename, "tutordeck-export-bright-minds-centre-2026-11-27.zip");
  assert.equal(r.rows, 26); assert.equal(r.matched, true); assert.equal(r.job, 41); assert.equal(db.started.p_full_payout, false); assert.equal(db.finished, 1);
  const files = readZip(await blobBuf(r.blob));
  assert.equal(Object.keys(files).length, X.CATALOG.length + 1, "every table has a file, plus README.txt");
  for (const t of X.CATALOG) assert.ok(files[t.file], t.file);
  const lessons = files["lessons.csv"].data.toString("utf8");
  assert.ok(lessons.startsWith("﻿id,student_id,student_name,"), "BOM and header");
  assert.equal(lessons.split("\r\n").length, 12 + 2, "header + 12 rows + trailing empty");
  assert.match(lessons, /rate_cents,rate_dollars,/);
  assert.match(lessons, /Name, 0 ""Q"" 🙂陈/, "quotes doubled, emoji and Chinese intact");
  assert.equal(files["branches.csv"].data.toString("utf8"), "﻿id,name,address,created_at\r\n", "an empty table is a header-only file");
  assert.equal(files["people_tutors_and_staff.csv"].data.toString("utf8"), X.csvHeader(X.CATALOG.find((t) => t.tbl === "memberships").cols.map((c) => c[0])));
  const readme = files["README.txt"].data.toString("utf8");
  assert.match(readme, /Bright Minds Centre/); assert.match(readme, /masked \(•••••1234\)/); assert.match(readme, /PDPA/); assert.match(readme, /students\.csv {2}\(7 rows\)/);
  assert.match(readme, /Invoice share links/); assert.match(readme, /Self-service export of all records/);
  assert.ok(progress.some((p) => p.phase === "finishing") && progress[0].expected === 26);
  const finishCall = db.calls.find((c) => c[0] === "org_export_finish")[1]; assert.equal(finishCall.p_counts.students, 7); assert.equal(finishCall.p_counts.branches, 0);
});

test("the full-payout tick is sent to the database and shown in the README", async () => {
  const db = fakeDb(makeRows({ students: 1 })), r = await X.runExport(db.rpc, { orgId: "O", centreName: "C", fullPayout: true, now: () => new Date(2026, 0, 2) });
  assert.equal(db.started.p_full_payout, true); assert.equal(r.fullPayout, true);
  assert.match((readZip(await blobBuf(r.blob)))["README.txt"].data.toString("utf8"), /FULL \(the owner ticked/);
});

test("paging: tables are fetched in the page sizes the code chose, following the cursor to the end", async () => {
  const db = fakeDb(makeRows({ lessons: 2500, students: 5200 })); await X.runExport(db.rpc, { orgId: "O", centreName: "C", now: () => new Date(2026, 0, 2) });
  const pages = (tbl) => db.calls.filter((c) => c[0] === "org_export_page" && c[1].p_table === tbl);
  assert.deepEqual(pages("lessons").map((c) => c[1].p_limit), [1000, 1000, 1000]);                                   // 2500 rows = 1000 + 1000 + 500
  assert.deepEqual(pages("students").map((c) => c[1].p_limit), [5000, 5000]); assert.equal(pages("students")[1][1].p_after, "5000");
  assert.equal(pages("branches").length, 1, "an empty table is one page");
  assert.equal(X.pageSize("lessons"), 1000); assert.equal(X.pageSize("guardians"), 5000);
  assert.ok(db.calls.every((c) => c[1].p_org === "O"));
});

test("a refusal is final (no retry) and worded plainly; a dropped connection is retried", async () => {
  const refuse = fakeDb(makeRows({}), { refuse: true });
  await assert.rejects(X.runExport(refuse.rpc, { orgId: "O", centreName: "C", wait: async () => {} }), (e) => { assert.equal(X.errorText(e), "Only the centre's owner can export its data."); return true; });
  assert.equal(refuse.calls.length, 1, "NOT_FOUND is not retried");
  const flaky = fakeDb(makeRows({ students: 3 }), { pageFails: 2 }); const waits = [];
  const r = await X.runExport(flaky.rpc, { orgId: "O", centreName: "C", wait: async (ms) => waits.push(ms), now: () => new Date(2026, 0, 2) });
  assert.equal(r.matched, true); assert.equal(waits.length, 2, "two failed pages were retried after a pause"); assert.ok(waits[1] > waits[0]);
  const dead = fakeDb(makeRows({}), { pageFails: 99 });
  await assert.rejects(X.runExport(dead.rpc, { orgId: "O", centreName: "C", wait: async () => {}, retries: 2 }), (e) => /Failed to fetch/.test(e.message));
  assert.match(X.errorText({ message: "Failed to fetch" }), /connection dropped/); assert.match(X.errorText({ message: "NOT_ALLOWED: too many exports in the last hour, please try again later" }), /lot of exports/);
});

test("a database that disagrees with this page's column list, or lists a table it doesn't know, stops the export instead of writing a wrong file", async () => {
  await assert.rejects(X.runExport(fakeDb(makeRows({ students: 1 }), { wrongCols: true }).rpc, { orgId: "O", centreName: "C" }), /differ from this page/);
  await assert.rejects(X.runExport(fakeDb(makeRows({}), { extraTable: true }).rpc, { orgId: "O", centreName: "C" }), /does not know yet \(mystery\)/);
});

test("PERFORMANCE: 100,000 lessons + 100,000 audit rows + 400 students stream into a ZIP quickly and without holding the tables in memory", async () => {
  const spec = { lessons: 100000, audit_log: 100000, students: 400, households: 200, memberships: 200 };
  // rows are made on demand, one page at a time, so the pretend database itself holds nothing: whatever memory grows is the export's
  const rows = (tbl) => { const t = X.CATALOG.find((c) => c.tbl === tbl), n = spec[tbl] || 0; return { length: n, slice: (a, b) => { const o = []; for (let i = a; i < Math.min(b, n); i++) o.push(t.cols.map((c) => cell(tbl, c[0], i))); return o; } }; };
  const db = fakeDb(rows); if (global.gc) global.gc(); const heap0 = process.memoryUsage().heapUsed, t0 = Date.now();
  const r = await X.runExport(db.rpc, { orgId: "O", centreName: "Big Centre", now: () => new Date(2026, 10, 27) });
  const secs = (Date.now() - t0) / 1000, grew = (process.memoryUsage().heapUsed - heap0) / 1048576;
  const files = readZip(await blobBuf(r.blob));
  assert.equal(r.rows, 200800 + 0); assert.equal(r.matched, true);
  assert.equal(files["lessons.csv"].data.toString("utf8").split("\r\n").length, 100002); assert.equal(files["audit_log.csv"].data.toString("utf8").split("\r\n").length, 100002);
  assert.ok(files["lessons.csv"].method === 8, "big tables are deflated");
  const pages = db.calls.filter((c) => c[0] === "org_export_page").length;
  assert.ok(pages >= 200 && pages < 260, "about 200 requests of 1000 rows, not one per row: " + pages);
  console.log("# perf: " + r.rows + " rows, " + pages + " pages, " + secs.toFixed(1) + " s, zip " + (r.blob.size / 1048576).toFixed(1) + " MB, lessons.csv " + (files["lessons.csv"].us / 1048576).toFixed(1) + " MB, heap growth " + grew.toFixed(0) + " MB");
  assert.ok(secs < 60, "took " + secs + " s");
  assert.ok(grew < 150, "heap grew " + grew + " MB: the tables are being held in memory");
});
