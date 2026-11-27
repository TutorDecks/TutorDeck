// node --test tests/settings-search-core.test.js — T48: the settings search (pure logic).
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const S = require("../assets/js/org-settings.js");
const C = require("../assets/js/settings-search-core.js");

const EXTRA = [["plan", "Plan"], ["audit", "Audit log"]];
const mk = (setup) => C.createIndex({ steps: S.STEPS, extraTabs: EXTRA, setup: !!setup, isVisible: S.isVisible, get: S.get, set: S.set, display: S.display });
const idx = mk(false), idxSetup = mk(true);
const settings = () => S.defaults("centre");
const top = (q, s, n) => C.search(idx, q, s || settings(), { limit: n || 8 });
const paths = (q, s, n) => top(q, s, n).map((r) => r.entry.path || r.entry.id);

test("normalise: case, accents, punctuation, curly quotes, plural", () => {
  assert.equal(C.normalise("  Late-Fee!! "), "late fee");
  assert.equal(C.normalise("Lessons"), "lesson");
  assert.equal(C.normalise("tutors’ payout"), "tutor payout");
  assert.equal(C.normalise("Café"), "cafe");
  assert.equal(C.normalise("1-to-1"), "1 to 1");
  assert.equal(C.normalise(null), "");
});

test("fewer than 2 letters finds nothing; whitespace does not count", () => {
  assert.deepEqual(top("l"), []);
  assert.deepEqual(top(" l "), []);
  assert.deepEqual(top(""), []);
  assert.ok(top("la").length > 0);
});

test("EVERY setting in the schema can be found by searching its own label (no setting can be missing from search)", () => {
  const missing = [], slow = [];
  S.STEPS.forEach((st) => st.fields.forEach((f) => {
    if (f.type === "group") return;
    const label = f.label || (f.help || "").split(/(?<=[.!?])\s/)[0].slice(0, 80);
    if (!label) return missing.push(f.path + " has neither a label nor help");
    const ids = C.search(idxSetup, label, settings(), { limit: 400 }).map((r) => r.entry.path || r.entry.id);
    const id = f.path || "field:" + label, at = ids.indexOf(id);
    if (at < 0) missing.push((f.path || label) + " <- " + label);
    else if (at > 7) slow.push((f.path || label) + " is result " + (at + 1) + " for its own label");
  }));
  assert.deepEqual(missing, []);
  assert.deepEqual(slow, [], "a label search should show the setting on the first screen of results");
});

test("every group heading and every tab can be found by its own name", () => {
  S.STEPS.forEach((st) => {
    const ids = C.search(idxSetup, st.title, settings(), { limit: 400 }).map((r) => r.entry.id);
    assert.ok(ids.indexOf("tab:" + st.id) > -1, "tab " + st.id);
    st.fields.filter((f) => f.type === "group").forEach((g) => assert.ok(C.search(idxSetup, g.label, settings(), { limit: 400 }).some((r) => r.entry.id === "group:" + g.label), g.label));
  });
  EXTRA.forEach((t) => assert.ok(C.search(idx, t[1], settings(), { limit: 50 }).some((r) => r.entry.id === "tab:" + t[0]), t[1]));
});

test("the wizard-only tabs (Import, Review) are searchable only during setup", () => {
  assert.ok(!idx.entries.some((e) => e.stepId === "review" || e.stepId === "import"));
  assert.ok(idxSetup.entries.some((e) => e.id === "tab:review") && idxSetup.entries.some((e) => e.id === "tab:import"));
  assert.ok(!idxSetup.entries.some((e) => e.stepId === "plan" || e.stepId === "audit"));
  assert.ok(idx.entries.some((e) => e.id === "tab:plan") && idx.entries.some((e) => e.id === "tab:audit"));
});

test("synonyms from `keywords`: overdue finds late fees; refundable finds the deposit", () => {
  assert.ok(paths("overdue").includes("billing.late_fee.enabled"));
  assert.ok(paths("penalty").includes("billing.late_fee.enabled"));
  assert.ok(paths("refundable").includes("billing.deposit.mode"));
  assert.ok(paths("salary").includes("tutor_pay.mode"));
  assert.ok(paths("whatsapp message").includes("invoicing.whatsapp_template"));
  assert.ok(paths("sibling").includes("billing.sibling_discount.type"));
  assert.ok(paths("feedback").includes("lessons.remarks.required"));
  assert.ok(paths("relief").includes("lessons.replacement_tutors"));
});

test("help text and option labels are searched too", () => {
  assert.ok(paths("unbroken series").includes("profile.next_invoice_number"), "help text");
  assert.ok(paths("prepaid packages").includes("billing.model"), "option label");
  assert.ok(paths("bank statement matching").includes("payments.modes"), "option label of a multi-choice");
});

test("ranking: an exact label beats a longer one, a label hit beats a help-text hit", () => {
  assert.equal(top("late fee")[0].entry.path, "billing.late_fee.enabled");
  assert.equal(top("timezone")[0].entry.path, "profile.timezone");
  assert.equal(top("invoice prefix")[0].entry.path, "profile.invoice_prefix");
  const r = paths("deposit amount");
  assert.equal(r[0], "billing.one_off_fees.deposit_cents");
});

test("every word typed must match (narrowing) and word order does not matter", () => {
  assert.ok(paths("late fee amount").includes("billing.late_fee.amount_cents"));
  assert.ok(!paths("late fee amount").includes("profile.timezone"));
  assert.deepEqual(paths("fee late amount")[0], paths("late fee amount")[0]);
  assert.deepEqual(top("zzzzqq"), []);
});

test("typing a plural or part of a word still finds it", () => {
  assert.ok(paths("invoic").includes("profile.invoice_prefix"));
  assert.ok(paths("holidays").includes("calendar.skip_holidays"));
  assert.ok(paths("holiday").includes("calendar.skip_holidays"));
});

test("hand-built parts of a tab are findable: rooms, holidays, invite staff, permissions", () => {
  assert.equal(top("rooms")[0].entry.id, "item:Rooms");
  assert.ok(top("invite").some((r) => r.entry.id === "item:Invite staff or tutors"));
  assert.ok(top("permissions").some((r) => r.entry.id === "item:Staff permissions"));
  assert.equal(top("rooms")[0].entry.stepId, "calendar");
});

test("`soon` settings are found and flagged coming soon", () => {
  const r = top("reminders").filter((x) => x.entry.path === "invoicing.reminders.enabled")[0];
  assert.ok(r && r.soon === true);
  const g = top("late fee").filter((x) => x.entry.path === "billing.late_fee.enabled")[0];
  assert.equal(g.soon, false);
  assert.ok(top("credit expire").some((x) => x.entry.path === "billing.credit_expiry_days" && x.soon));
});

test("each result carries the current value, shown the way the Review step shows it", () => {
  const s = settings(); s.billing.late_fee.enabled = true; s.billing.late_fee.amount_cents = 1250; s.billing.deposit.mode = "fixed";
  const v = (q, p) => C.search(idx, q, s, { limit: 20 }).filter((r) => r.entry.path === p)[0].value;
  assert.equal(v("late fee", "billing.late_fee.enabled"), "Yes");
  assert.equal(v("late fee amount", "billing.late_fee.amount_cents"), "S$12.50");
  assert.equal(v("deposit", "billing.deposit.mode"), "A fixed amount");
  assert.equal(v("grace period", "billing.late_fee.after_days"), "7");
  assert.match(v("whatsapp message", "invoicing.whatsapp_template"), /^Hi \{name\}, this is \{centre\}.+\u2026$/);
  s.invoicing.whatsapp_template = ""; assert.equal(v("whatsapp message", "invoicing.whatsapp_template"), "Standard message");
});

test("a setting hidden by an option that is off says which one to turn on", () => {
  const s = settings();                                                   // late fees are off by default
  const r = C.search(idx, "late fee amount", s, { limit: 20 }).filter((x) => x.entry.path === "billing.late_fee.amount_cents")[0];
  assert.ok(r.hidden, "hidden while late fees are off");
  assert.equal(r.hidden.parentPath, "billing.late_fee.enabled");
  assert.equal(r.hidden.action, "Turn on Late fee first");
  s.billing.late_fee.enabled = true;
  assert.equal(C.search(idx, "late fee amount", s, { limit: 20 }).filter((x) => x.entry.path === "billing.late_fee.amount_cents")[0].hidden, null);
  s.billing.late_fee.type = "percent";                                    // visible parent, wrong choice: the amount (not the percentage) is hidden
  const h = C.search(idx, "late fee amount", s, { limit: 20 }).filter((x) => x.entry.path === "billing.late_fee.amount_cents")[0].hidden;
  assert.equal(h.parentPath, "billing.late_fee.type");
  assert.match(h.action, /Set .Late fee is. to .A fixed amount. first/);
});

test("a setting hidden behind two options names the first one to change", () => {
  const s = settings(); s.billing.late_fee.type = "percent";               // enabled is still off, and the amount also needs type = fixed
  const h = C.search(idx, "late fee amount", s, { limit: 20 }).filter((x) => x.entry.path === "billing.late_fee.amount_cents")[0].hidden;
  assert.equal(h.parentPath, "billing.late_fee.enabled");
  assert.equal(h.action, "Turn on Late fee first");
});

test("a select parent: the deposit amount needs the deposit set to a fixed amount; GST rate needs GST on", () => {
  let s = settings();
  let h = C.search(idx, "deposit amount", s, { limit: 20 }).filter((x) => x.entry.path === "billing.one_off_fees.deposit_cents")[0].hidden;
  assert.equal(h.parentPath, "billing.deposit.mode");
  assert.match(h.action, /Set .Deposit. to .A fixed amount. first/);
  h = C.search(idx, "gst rate", s, { limit: 20 }).filter((x) => x.entry.path === "profile.gst_rate_bp")[0].hidden;
  assert.equal(h.action, "Turn on GST registered first");
  s.profile.gst_registered = true;
  assert.equal(C.search(idx, "gst rate", s, { limit: 20 }).filter((x) => x.entry.path === "profile.gst_rate_bp")[0].hidden, null);
});

test("group-only settings are hidden for 1-to-1 centres and point at 'Classes you run'", () => {
  const s = settings(); s.lessons.class_type = "one_to_one";
  const r = C.search(idx, "present enrolled students counted", s, { limit: 20 }).filter((x) => x.entry.path === "tutor_pay.group_count")[0];
  assert.ok(r && r.hidden && r.hidden.parentPath === "lessons.class_type");
  s.lessons.class_type = "both";
  assert.equal(C.search(idx, "present enrolled students counted", s, { limit: 20 }).filter((x) => x.entry.path === "tutor_pay.group_count")[0].hidden, null);
});

test("EVERY setting that can be hidden names a parent that exists, and changing that parent brings it back", () => {
  const all = S.STEPS.flatMap((st) => st.fields).filter((f) => f.path);
  const byPath = {}; all.forEach((f) => { byPath[f.path] = f; });
  const problems = [];
  all.forEach((f) => {
    if (!f.show && !f.groupOnly) return;
    if (f.show && !f.parent) return problems.push(f.path + " has a show rule but no parent");
    (f.parent ? [].concat(f.parent) : []).forEach((p) => { if (!byPath[p]) problems.push(f.path + " parent " + p + " does not exist"); });
    // some combination of the parents' values (from defaults) shows it
    const ps = (f.parent ? [].concat(f.parent) : []).map((p) => byPath[p]).filter(Boolean);
    const vals = ps.map((p) => p.type === "toggle" ? [true, false] : (p.options || []).map((o) => o[0]));
    let found = !ps.length && !f.show;
    (function walk(i, s) {
      if (found) return;
      if (i === ps.length) { if (S.isVisible(f, s)) found = true; return; }
      vals[i].forEach((v) => { const c = JSON.parse(JSON.stringify(s)); S.set(c, ps[i].path, v); walk(i + 1, c); });
    })(0, settings());
    if (!found) problems.push(f.path + ": no value of its parent(s) shows it");
    // and the search reports it as hidden / visible consistently with isVisible, for every combination of defaults
    const s = settings();
    const r = C.hiddenInfo(idxSetup, idxSetup.byPath[f.path], s);
    if (S.isVisible(f, s) !== !r) problems.push(f.path + ": hiddenInfo disagrees with isVisible");
    if (r && !r.parentPath) problems.push(f.path + ": hidden but no parent named");
    if (r && !/^(Turn o(n|ff) .+ first|Set .+ first|Change .+ first)$/.test(r.action)) problems.push(f.path + ": odd wording: " + r.action);
  });
  assert.deepEqual(problems, []);
});

test("following the advice makes the setting visible (walk the parents until it shows)", () => {
  const all = S.STEPS.flatMap((st) => st.fields).filter((f) => f.path && f.show);
  all.forEach((f) => {
    const s = settings(); let guard = 0;
    for (;;) {
      const h = C.hiddenInfo(idxSetup, idxSetup.byPath[f.path], s);
      if (!h) break;
      assert.ok(++guard < 6, f.path + " never becomes visible");
      const pf = idxSetup.byPath[h.parentPath].field;
      S.set(s, h.parentPath, h.optionsNeeded[0]);
      assert.ok(pf, "parent field");
    }
    assert.ok(S.isVisible(f, s), f.path);
  });
});

test("tab entries point at the right tab and sort after a real setting", () => {
  const r = top("billing", null, 50);
  assert.ok(r.some((x) => x.entry.kind === "tab" && x.entry.stepId === "billing"));
  const t = top("tutor pay");
  assert.ok(t.length > 0);
});

test("trail reads 'Tab › Group'", () => {
  const e = idx.byPath["billing.late_fee.after_days"];
  assert.equal(C.trail(e), "How lessons are billed › Late fees");
  assert.equal(C.trail(idx.byPath["profile.timezone"]), "Organisation profile");
});

test("search never throws on odd input", () => {
  ["%%", "(", "\\", "a b c d e f", "\u0000\u0000", "<script>", "   ", "é", "1-to-1"].forEach((q) => assert.doesNotThrow(() => C.search(idx, q, settings())));
  assert.deepEqual(C.search(idx, "late", null).length > 0, true, "works without settings (no values, nothing hidden)");
});
