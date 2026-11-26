"use strict";
const test = require("node:test"), assert = require("node:assert");
const fs = require("fs"), path = require("path");
const H = require("../assets/js/holiday-library.js");
const lib = JSON.parse(fs.readFileSync(path.join(__dirname, "../assets/data/sg-public-holidays.json"), "utf8"));
const WD = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

test("data file: valid dates, weekdays, years, statuses", () => {
  assert.ok(lib._meta.source.startsWith("https://www.mom.gov.sg/") && lib._meta.fetched_on && lib._meta.source_last_updated);
  assert.ok(lib.holidays.length > 0);
  lib.holidays.forEach((h) => {
    assert.match(h.date, /^\d{4}-\d{2}-\d{2}$/, h.date);
    const d = new Date(h.date + "T00:00:00Z");
    assert.strictEqual(d.toISOString().slice(0, 10), h.date, "real calendar date " + h.date);
    assert.strictEqual(d.getUTCFullYear(), h.year, "year matches date " + h.date);
    assert.strictEqual(WD[d.getUTCDay()], h.weekday, "weekday of " + h.date + " " + h.name);
    assert.ok(h.name && h.name.length < 80);
    assert.ok(["official", "to_confirm"].includes(h.status), "status " + h.status);
    if (h.substitute_for) {
      assert.strictEqual(WD[d.getUTCDay()], "Monday", "a substitute is a Monday");
      const o = lib.holidays.find((x) => x.date === h.substitute_for);
      assert.ok(o, "substitute_for points at a row"); assert.strictEqual(new Date(o.date + "T00:00:00Z").getUTCDay(), 0, "...that falls on a Sunday");
    }
  });
});
test("data file: no duplicate dates or names within a year, published years covered", () => {
  const dates = lib.holidays.map((h) => h.date); assert.strictEqual(new Set(dates).size, dates.length);
  const names = lib.holidays.map((h) => h.year + h.name); assert.strictEqual(new Set(names).size, names.length);
  lib._meta.years_published.forEach((y) => assert.ok(lib.holidays.some((h) => h.year === y), "rows for " + y));
  lib.holidays.forEach((h) => assert.ok(lib._meta.years_published.includes(h.year), "year listed as published"));
  lib._meta.years_not_published_yet.forEach((y) => assert.ok(!lib.holidays.some((h) => h.year === y)));
});
test("grouped by year, sorted by date", () => {
  const g = H.byYear(lib); assert.deepStrictEqual(g.map((x) => x.year), lib._meta.years_published.slice().sort());
  g.forEach((x) => assert.deepStrictEqual(x.rows.map((r) => r.date), x.rows.map((r) => r.date).slice().sort()));
});
const ny = lib.holidays.find((h) => h.date === "2026-01-01"), cny = lib.holidays.find((h) => h.date === "2026-02-18");
test("nothing is ticked with no saved rows; tick inserts a one-day row", () => {
  assert.strictEqual(H.isTicked([], ny), false); assert.strictEqual(H.match(null, ny), null);
  assert.deepStrictEqual(H.toRow(ny), { name: "New Year's Day", starts_on: "2026-01-01", ends_on: "2026-01-01" });
});
test("a saved row on the date shows ticked; exact one-day rows may be removed, ranges may not", () => {
  const one = { id: "a", name: "NYD", starts_on: "2026-01-01", ends_on: "2026-01-01" }, range = { id: "b", name: "CNY break", starts_on: "2026-02-16", ends_on: "2026-02-20" };
  assert.deepStrictEqual(H.match([one], ny), { row: one, exact: true });
  assert.deepStrictEqual(H.match([range], cny), { row: range, exact: false });
  assert.strictEqual(H.isTicked([one], ny), true);
  assert.strictEqual(H.isTicked([one], cny), false);
  const both = { id: "c", name: "CNY 2", starts_on: "2026-02-18", ends_on: "2026-02-18" };
  assert.strictEqual(H.match([range, both], cny).row.id, "c", "prefers the exact row");
});
test("select all skips dates already covered; clear removes only exact one-day rows of that year", () => {
  const n26 = lib.holidays.filter((h) => h.year === 2026 && !h.substitute_for).length;
  assert.strictEqual(H.toTick([], lib, 2026).length, n26);
  assert.strictEqual(H.toTick([], lib, 2030).length, 0);
  const saved = [{ id: "a", starts_on: "2026-01-01", ends_on: "2026-01-01" }, { id: "b", starts_on: "2026-02-16", ends_on: "2026-02-20" }, { id: "z", starts_on: "2027-01-01", ends_on: "2027-01-01" }];
  const t = H.toTick(saved, lib, 2026); assert.strictEqual(t.length, n26 - 3, "New Year, and CNY day 1 + 2 are covered");
  assert.ok(!t.some((r) => r.starts_on === "2026-01-01" || r.starts_on === "2026-02-17" || r.starts_on === "2026-02-18"));
  assert.deepStrictEqual(H.toClear(saved, lib, 2026), ["a"], "range b and the 2027 row stay");
  assert.deepStrictEqual(H.toClear(saved, lib, 2027), ["z"]);
  const hand = [{ id: "m", starts_on: "2026-03-05", ends_on: "2026-03-05" }]; assert.deepStrictEqual(H.toClear(hand, lib, 2026), [], "manual non-library day untouched");
});
test("select all leaves Monday substitutes unticked, but a ticked substitute can be cleared", () => {
  assert.ok(H.toTick([], lib, 2026).every((r) => !/substitute/.test(r.name)));
  const sub = lib.holidays.find((h) => h.substitute_for && h.year === 2026), saved = [{ id: "s", starts_on: sub.date, ends_on: sub.date }];
  assert.deepStrictEqual(H.toClear(saved, lib, 2026), ["s"]);
});
