// A stray </style> in the middle of a page's CSS (it happened in tutor-schedule.html at bundle 7) turns every rule after it into page text
// that the browser silently ignores. This fails when any page has CSS rules outside a <style> block.
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..");
function strayCss(html) {
  const rest = html.replace(/<style[\s\S]*?<\/style>/gi, "").replace(/<script[\s\S]*?<\/script>/gi, "").replace(/<!--[\s\S]*?-->/g, "");
  return rest.split("\n").filter((l) => /^\s*[.#]?[a-z][\w.#:>\s,-]*\{[^{}]*:[^{}]*\}\s*$/i.test(l) && !/^\s*</.test(l));
}
test("no page has CSS rules outside a <style> block", () => {
  for (const f of fs.readdirSync(root).filter((n) => n.endsWith(".html"))) {
    const bad = strayCss(fs.readFileSync(path.join(root, f), "utf8"));
    assert.deepStrictEqual(bad.slice(0, 3), [], f + " has CSS outside <style>");
  }
});
test("every <style> is closed once and dark.css is linked at most once", () => {
  for (const f of fs.readdirSync(root).filter((n) => n.endsWith(".html"))) {
    const h = fs.readFileSync(path.join(root, f), "utf8");
    assert.strictEqual((h.match(/<style\b/gi) || []).length, (h.match(/<\/style>/gi) || []).length, f + ": <style> / </style> do not pair up");
    assert.ok((h.match(/dark\.css/g) || []).length <= 1, f + ": dark.css linked more than once");
  }
});
test("the checker catches the bundle 7 mistake", () => {
  assert.strictEqual(strayCss("<style>\n.a{color:red}\n</style>\n<link>\n  .sc-seg{margin:0 0 10px}\n").length, 1);
});
