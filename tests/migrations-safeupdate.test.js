// Supabase's API layer runs pg-safeupdate: a DELETE or UPDATE with no WHERE clause is refused with SQLSTATE 21000 ("DELETE requires a WHERE clause").
// The throwaway test Postgres doesn't, so this reads every migration and fails on such a statement (B4-FIX: it broke "Record payment").
const test = require("node:test"), assert = require("node:assert"), fs = require("fs"), path = require("path");
const dir = path.join(__dirname, "..", "db");
// migration_centre_payments.sql is already applied on DEV and carries the old statement; migration_payment_fix.sql replaces that function.
const KNOWN_FIXED_BY_LATER_MIGRATION = { "migration_centre_payments.sql": ["delete from _td_pay_open"] };

test("no migration has a DELETE or UPDATE without WHERE (pg-safeupdate)", () => {
  const bad = [];
  for (const f of fs.readdirSync(dir).filter((n) => /^migration_.*\.sql$/.test(n) && !/_down\.sql$/.test(n))) {
    const text = fs.readFileSync(path.join(dir, f), "utf8").replace(/--[^\n]*/g, "").replace(/\/\*[\s\S]*?\*\//g, "");
    // only function bodies matter (they run through the API); a one-off script run in the SQL editor is not subject to the rule
    const bodies = (text.match(/\$\$[\s\S]*?\$\$/g) || []).join(";");
    for (const raw of bodies.split(";")) {
      const st = raw.trim().replace(/\s+/g, " ");
      if (!/^(delete from|update \S+ set)/i.test(st)) continue;
      if (/\bwhere\b/i.test(st) || /\bcurrent of\b/i.test(st)) continue;
      if ((KNOWN_FIXED_BY_LATER_MIGRATION[f] || []).includes(st.toLowerCase())) continue;
      bad.push(f + ": " + st.slice(0, 80));
    }
  }
  assert.deepStrictEqual(bad, []);
});

test("the payment fix migration is in place and the old statement is gone from it", () => {
  const s = fs.readFileSync(path.join(dir, "migration_payment_fix.sql"), "utf8").replace(/--[^\n]*/g, "");
  assert.match(s, /delete from _td_pay_open where true/);
  assert.doesNotMatch(s, /delete from _td_pay_open\s*;/);
});
