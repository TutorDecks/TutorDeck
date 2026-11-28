// B8-FIX F1 / F2 / F3: the three page fixes that have no pure logic of their own, checked at the source (the browser check for each page covers the rest).
//   F1  Statements and Email tabs wait for the centre instead of calling the database with an organisation of "null".
//   F2  the undo sheet clears the red "Say why" once a reason is typed or the question is confirmed.
//   F3  "Email invoice" always says what happened and never leaves the button stuck.
const test = require("node:test"), assert = require("node:assert/strict"), fs = require("node:fs");
const src = (f) => fs.readFileSync(require.resolve("../assets/js/" + f), "utf8");

test("F1: Statements and Email never ask the database for an organisation that is not there yet", () => {
  for (const f of ["statements.js", "centre-email.js"]) {
    const s = src(f), at = s.indexOf("B8-FIX F1");
    assert.ok(at > -1, f + " has the guard");
    const guard = s.slice(at, at + 700);
    assert.match(guard, /!orgId \|\| orgId === "null"/, f + " tests for a missing id");
    assert.match(guard, /Loading your centre/, f + " shows a friendly message while it waits");
    assert.match(guard, /setTimeout\(show/, f + " tries again");
    assert.ok(s.indexOf("return;", at) < s.indexOf("load()", at), f + " returns before it loads anything");
  }
});

test("F2: the undo sheet clears 'Say why' when a reason is typed and before the confirm dialog", () => {
  const s = src("centre-refunds.js");
  assert.match(s, /\$\("cu-reason"\)\.addEventListener\("input", function \(\) \{ \$\("cr-err"\)\.textContent = ""; \}\)/);
  const a = s.indexOf("RC.checkUndo"), conf = s.indexOf('TL.confirm({ title: "Undo this?"');
  assert.ok(s.slice(a, conf).includes('$("cr-err").textContent = ""'), "cleared between the check and the dialog");
});

test("F3: Email invoice queues with a visible message, and always frees the button", () => {
  const s = src("centre-email.js"), at = s.indexOf('$("ce-send").addEventListener("click"'), end = s.indexOf("// the invoice sheet asks this");
  const h = s.slice(at, end);
  assert.match(h, /Queuing the email/, "says it is working");
  assert.match(h, /E\.queuedText\(queued\)/, "says 'Queued for N email(s)'");
  assert.match(h, /finally \{\s*busy = false;/, "busy is always released");
  assert.match(h, /filter = "waiting"; if \(built\) load\(\)/, "the Email tab then shows it waiting");
  assert.match(h, /Nothing was queued/, "says why when nothing was queued");
  assert.match(s, /If none is ticked, the first parent or guardian is used/, "the hint is still true: the database falls back to the first guardian");
});
