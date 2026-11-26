// pg-safeupdate guard (SQLSTATE 21000): the Supabase API layer refuses any DELETE or UPDATE that has no WHERE clause. A function that runs one fails
// the first time a person uses it, so every `delete from x` / `update x set …` inside a function body in db/migration_*.sql must carry a WHERE
// (write `where true` when a statement really does touch every row). Undo files (*_down.sql) and statements outside functions run in the SQL editor,
// not through the API, so they are not checked. The tests/sql/ database tests run as the superuser and would not notice this, which is why it is a unit test.
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const DB = path.join(__dirname, "..", "db");

// the text of every function body (dollar-quoted block that follows CREATE [OR REPLACE] FUNCTION), with comments and string literals blanked out
function functionBodies(sql) {
  const out = [];
  const re = /create\s+(?:or\s+replace\s+)?function\b[\s\S]*?\bas\s+(\$[A-Za-z_]*\$)([\s\S]*?)\1/gi;
  let m;
  while ((m = re.exec(sql))) out.push(m[2]);
  return out;
}
function clean(body) {
  return body
    .replace(/--[^\n]*/g, " ")
    .replace(/\/\*[\s\S]*?\*\//g, " ")
    .replace(/'(?:[^']|'')*'/g, "''");
}
// every DELETE / UPDATE statement in a cleaned body that has no WHERE before its semicolon
function bareWrites(body) {
  const bad = [];
  const re = /\b(delete\s+from\s+[\w."]+|update\s+[\w."]+\s+set\b)([^;]*);/gi;
  let m;
  while ((m = re.exec(body))) if (!/\bwhere\b/i.test(m[2])) bad.push((m[1] + " " + m[2]).replace(/\s+/g, " ").slice(0, 100));
  return bad;
}

test("the checker itself finds a bare DELETE and a bare UPDATE and accepts WHERE true", () => {
  const sql = "create or replace function f() returns void language plpgsql as $$ begin delete from a; update b set x = 1; delete from c where true; update d set y = 2 where id = 1; end $$;";
  const bad = functionBodies(sql).flatMap((b) => bareWrites(clean(b)));
  assert.deepStrictEqual(bad.map((s) => s.split(" ")[0] + " " + s.split(" ")[1] + " " + s.split(" ")[2]), ["delete from a", "update b set"]);
  const ok = "create function g() returns void language sql as $q$ delete from a where true $q$;";
  assert.strictEqual(functionBodies(ok).flatMap((b) => bareWrites(clean(b))).length, 0);
  const upsert = "create function h() returns void language plpgsql as $$ begin insert into a values (1) on conflict (id) do update set x = excluded.x; end $$;";
  assert.strictEqual(functionBodies(upsert).flatMap((b) => bareWrites(clean(b))).length, 0, "an upsert's DO UPDATE SET is not a bare update");
  assert.strictEqual(bareWrites(clean("-- delete from x;\n select 'update y set z = 1;'")).length, 0, "comments and string literals are ignored");
});

test("no migration function runs a DELETE or UPDATE without a WHERE", () => {
  const files = fs.readdirSync(DB).filter((f) => /^migration_.*\.sql$/.test(f) && !/_down\.sql$/.test(f));
  assert.ok(files.length > 10, "the migrations were found");
  const found = [];
  for (const f of files) {
    const sql = fs.readFileSync(path.join(DB, f), "utf8");
    for (const b of functionBodies(sql)) for (const s of bareWrites(clean(b))) found.push(f + ": " + s);
  }
  assert.deepStrictEqual(found, [], "add `where true` to these statements:\n" + found.join("\n"));
});
