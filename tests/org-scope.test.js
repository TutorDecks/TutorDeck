"use strict";
// Solo pages read/write only the current SOLO organisation (assets/js/org-scope.js). Pure logic, no browser.
const test = require("node:test"), assert = require("node:assert");
const fs = require("fs"), path = require("path");
const OS = require("../assets/js/org-scope.js");

const SID = "11111111-1111-4111-8111-111111111111", CID = "22222222-2222-4222-8222-222222222222";
const SOLO = { id: SID, kind: "solo", role: "owner", name: "Mei Tuition" };
const CENTRE = { id: CID, kind: "centre", role: "owner", name: "Alpha Centre" };
const CENTRE_TUTOR = { id: CID, kind: "centre", role: "tutor", name: "Alpha Centre" };
const UNKNOWN = { id: null, kind: "solo", role: null, name: "" };      // what TL.org() answers on a doubt (organisation tables missing, as on LIVE)

// A fake query that records what was asked of it.
function fakeQuery() { const calls = []; const q = { or: (s) => (calls.push(["or", s]), q), eq: (a, b) => (calls.push(["eq", a, b]), q), calls }; return q; }

test("solo organisation with an id: reads are narrowed to it (a null org_id counts as mine, T12 plan section 7)", () => {
  assert.strictEqual(OS.NULL_IS_MINE, true);
  const q = fakeQuery(); assert.strictEqual(OS.scope(q, SOLO), q);
  assert.deepStrictEqual(q.calls, [["or", "org_id.eq." + SID + ",org_id.is.null"]]);
});
test("id unknown (null) = NO filter at all: exactly today's behaviour on LIVE", () => {
  const q = fakeQuery(); assert.strictEqual(OS.scope(q, UNKNOWN), q); assert.deepStrictEqual(q.calls, []);
  for (const o of [null, undefined, {}, { kind: "solo" }, { kind: "solo", id: "" }]) { const q2 = fakeQuery(); OS.scope(q2, o); assert.deepStrictEqual(q2.calls, [], JSON.stringify(o)); }
});
test("an id that is not a uuid never reaches a filter string", () => {
  const q = fakeQuery(); OS.scope(q, { kind: "solo", id: "x),org_id.neq.(y" }); assert.deepStrictEqual(q.calls, []);
});
test("a centre is never filtered here (its pages are not the solo pages)", () => {
  const q = fakeQuery(); OS.scope(q, CENTRE); assert.deepStrictEqual(q.calls, []);
});
test("a missing query or a query without .or never throws", () => {
  assert.strictEqual(OS.scope(null, SOLO), null);
  const bare = {}; assert.strictEqual(OS.scope(bare, SOLO), bare);
});

test("inserts: org_id is set to the solo organisation, never overwritten, rows and arrays both work", () => {
  assert.deepStrictEqual(OS.fields({ a: 1 }, SOLO), { a: 1, org_id: SID });
  assert.deepStrictEqual(OS.fields([{ a: 1 }, { a: 2 }], SOLO), [{ a: 1, org_id: SID }, { a: 2, org_id: SID }]);
  assert.deepStrictEqual(OS.fields({ a: 1, org_id: "keep" }, SOLO), { a: 1, org_id: "keep" });
  const orig = { a: 1 }; OS.fields(orig, SOLO); assert.deepStrictEqual(orig, { a: 1 });   // input untouched
});
test("inserts: unknown id or a centre = the row as before (the database fills org_id as it always did)", () => {
  const r = { a: 1 };
  assert.strictEqual(OS.fields(r, UNKNOWN), r); assert.strictEqual(OS.fields(r, null), r); assert.strictEqual(OS.fields(r, CENTRE), r);
});

test("centre on a solo page = redirect to the centre home; own pages stay", () => {
  const home = "centre?id=" + CID;
  for (const page of ["dashboard", "calendar", "planner", "students", "student", "exams", "ledger", "invoices", "insights", "materials"])
    assert.strictEqual(OS.centreRedirect(CENTRE, page), home, page);
  for (const page of ["org", "settings", "tutor", "centre", "centre-students"]) assert.strictEqual(OS.centreRedirect(CENTRE, page), null, page);
  assert.strictEqual(OS.centreRedirect(CENTRE_TUTOR, "ledger"), "tutor");            // only a tutor there: My lessons
});
test("solo, unknown or odd organisations never redirect", () => {
  for (const o of [SOLO, UNKNOWN, null, undefined, {}, { kind: "centre" }, { kind: "centre", id: "" }])
    assert.strictEqual(OS.centreRedirect(o, "ledger"), null, JSON.stringify(o));
  assert.strictEqual(OS.centreRedirect(CENTRE, undefined), null);
});

// ---- guard against a page being edited and a call site forgotten ----
const JS = path.join(__dirname, "..", "assets", "js");
const PAGES = ["students", "ledger", "dashboard", "planner", "invoices", "student", "exams", "settings", "calendar"];
test("every read/insert of a business table on a solo page goes through TL.scope / TL.orgFields", () => {
  const BIZ = "(students|lessons|recurring_slots|exams|invoices)";
  for (const f of PAGES) {
    const src = fs.readFileSync(path.join(JS, f + ".js"), "utf8");
    const reads = src.match(new RegExp('window\\.sb\\.from\\("' + BIZ + '"\\)\\s*\\.select\\(', "g")) || [];
    const wrapped = src.match(new RegExp('TL\\.scope\\(window\\.sb\\.from\\("' + BIZ + '"\\)\\s*\\.select\\(', "g")) || [];
    assert.strictEqual(wrapped.length, reads.length, f + ": a read is not wrapped in TL.scope");
    const ins = src.match(new RegExp('window\\.sb\\.from\\("' + BIZ + '"\\)\\s*\\.insert\\(', "g")) || [];
    const insW = src.match(new RegExp('window\\.sb\\.from\\("' + BIZ + '"\\)\\s*\\.insert\\(TL\\.orgFields\\(', "g")) || [];
    assert.strictEqual(insW.length, ins.length, f + ": an insert does not carry org_id (TL.orgFields)");
  }
});
test("every page that loads app.js also loads org-scope.js first", () => {
  const root = path.join(__dirname, "..");
  for (const f of fs.readdirSync(root).filter((n) => n.endsWith(".html"))) {
    const h = fs.readFileSync(path.join(root, f), "utf8");
    if (!/assets\/js\/app\.js/.test(h)) continue;
    assert.ok(h.indexOf("assets/js/org-scope.js") > -1 && h.indexOf("assets/js/org-scope.js") < h.indexOf("assets/js/app.js"), f);
  }
});
