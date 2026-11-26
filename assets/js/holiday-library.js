// Singapore public-holiday library: pure logic, no DOM, no network. Used by assets/js/org.js (centre wizard step 2) and unit-tested in
// tests/holiday-library.test.js. Data: assets/data/sg-public-holidays.json. Nothing here applies a holiday by itself: org.js only
// inserts/deletes `holidays` rows when the centre ticks/unticks a box.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.HolidayLibrary = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  // Rows grouped by year, oldest first: [{year, rows:[...]}]
  function byYear(lib) {
    var m = {}; (lib && lib.holidays || []).forEach(function (h) { (m[h.year] = m[h.year] || []).push(h); });
    return Object.keys(m).map(Number).sort().map(function (y) { return { year: y, rows: m[y].slice().sort(function (a, b) { return a.date < b.date ? -1 : a.date > b.date ? 1 : 0; }) }; });
  }
  // A saved holidays row (starts_on..ends_on) that covers this library date, preferring a single-day row on exactly that date.
  // → { row, exact } or null. exact = the row is only that one day, so un-ticking may delete it; a longer row (e.g. a school-holiday
  // range the centre typed by hand) shows ticked but is left alone.
  function match(saved, h) {
    var found = null;
    (saved || []).forEach(function (r) {
      if (!(r.starts_on <= h.date && h.date <= r.ends_on)) return;
      var exact = r.starts_on === h.date && r.ends_on === h.date;
      if (!found || (exact && !found.exact)) found = { row: r, exact: exact };
    });
    return found;
  }
  function isTicked(saved, h) { return !!match(saved, h); }
  // The row to insert when ticking (same shape as the manual form).
  function toRow(h) { return { name: h.name, starts_on: h.date, ends_on: h.date }; }
  // "Select all for {year}": rows to insert, skipping any date already covered (so a second click, or a manual row, never doubles up).
  // Monday substitutes are left out: MOM gives them only to people whose rest day is that Sunday, so a centre ticks them on purpose.
  function toTick(saved, lib, year) {
    return byYear(lib).filter(function (g) { return g.year === year; }).reduce(function (a, g) {
      return a.concat(g.rows.filter(function (h) { return !h.substitute_for && !isTicked(saved, h); }).map(toRow));
    }, []);
  }
  // "Clear": ids of saved single-day rows that sit on a library date of that year. Ranges and other rows are never removed.
  function toClear(saved, lib, year) {
    var ids = [];
    byYear(lib).filter(function (g) { return g.year === year; }).forEach(function (g) {
      g.rows.forEach(function (h) { var m = match(saved, h); if (m && m.exact && ids.indexOf(m.row.id) < 0) ids.push(m.row.id); });
    });
    return ids;
  }
  return { byYear: byYear, match: match, isTicked: isTicked, toRow: toRow, toTick: toTick, toClear: toClear };
});
