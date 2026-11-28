// The DEV apply pack is generated from tests/sql/run.sh by tools/build-dev-pack.py: this fails if someone changes a migration or
// the run order and forgets to rebuild it (python3 tools/build-dev-pack.py).
const test = require("node:test");
const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const path = require("node:path");

test("docs/orchestrator/dev-apply-pack.sql is up to date", () => {
  const r = spawnSync("python3", [path.join(__dirname, "../tools/build-dev-pack.py"), "--check"]);
  assert.strictEqual(r.status, 0, "rebuild it: python3 tools/build-dev-pack.py");
});

test("docs/orchestrator/dev-apply-pack-b8.sql is up to date", () => {
  const r = spawnSync("python3", [path.join(__dirname, "../tools/build-dev-pack-b8.py"), "--check"]);
  assert.strictEqual(r.status, 0, "rebuild it: python3 tools/build-dev-pack-b8.py");
});
