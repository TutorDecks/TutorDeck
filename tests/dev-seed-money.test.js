// T47: static guards for the DEV money demo seed (the database test is tests/sql/dev_seed_money_test.sh, run at the end of tests/sql/run.sh).
const test = require("node:test"), assert = require("node:assert"), fs = require("fs"), path = require("path");
const root = path.join(__dirname, "..");
const read = (f) => fs.readFileSync(path.join(root, f), "utf8");
const strip = (s) => s.replace(/--[^\n]*/g, "").replace(/\/\*[\s\S]*?\*\//g, "");

test("the money seed and its undo never mention the LIVE project and refuse to run outside the demo centre", () => {
  for (const f of ["db/seed_dev_demo_money.sql", "db/seed_dev_demo_money_down.sql"]) {
    const s = read(f);
    assert.doesNotMatch(s, /rnjvswkejbrhbaytutai/, f + " mentions the live project");
    assert.match(s, /REFUSED/, f + " has no refusal");
    assert.match(s, /centre\.owner@example\.test/, f + " does not look for the demo centre by its members");
    assert.match(s, /not like '%@example\.test'/, f + " does not check that every member is an @example.test login");
  }
  assert.match(read("db/seed_dev_demo_money.sql"), /stripe_subscription_id is not null/);
});

test("every UPDATE and DELETE in the money seed and its undo has a WHERE (the Supabase API refuses one without)", () => {
  const bad = [];
  for (const f of ["db/seed_dev_demo_money.sql", "db/seed_dev_demo_money_down.sql"]) {
    const text = strip(read(f)).replace(/\$(seed|down)\$/g, ";");
    for (const raw of text.split(";")) {
      const st = raw.trim().replace(/\s+/g, " ");
      if (!/^(delete from|update \S+ set)/i.test(st)) continue;
      if (!/\bwhere\b/i.test(st)) bad.push(f + ": " + st.slice(0, 90));
    }
  }
  assert.deepStrictEqual(bad, []);
});

test("the seed ends with a one-line post-check and the undo knows the seed's markers", () => {
  const up = read("db/seed_dev_demo_money.sql"), down = read("db/seed_dev_demo_money_down.sql");
  assert.match(up, /'SEED \| OK'/);
  assert.match(up, /'SEED \| FAILED/);
  assert.match(down, /seed_money.*t47/);
  assert.match(down, /0000000e01%/);
  assert.match(up, /seed_money', 't47'/);
});

test("tests/sql/build_chain.sh lists only migrations that exist", () => {
  const chain = read("tests/sql/build_chain.sh");
  const list = (chain.match(/for m in ([\s\S]*?); do/) || [])[1];
  assert.ok(list, "migration list not found");
  const names = list.replace(/\\\n/g, " ").split(/\s+/).filter(Boolean);
  assert.ok(names.length >= 35);
  for (const n of names) assert.ok(fs.existsSync(path.join(root, "db", "migration_" + n + ".sql")), "missing db/migration_" + n + ".sql");
});

test("run.sh runs the seed test", () => {
  assert.match(read("tests/sql/run.sh"), /bash tests\/sql\/dev_seed_money_test\.sh/);
});
