// Settings search — pure logic (no DOM). Used by the Centre / Organisation settings screen (assets/js/org.js).
// Builds an index from the settings schema (assets/js/org-settings.js), matches what the person typed against labels, help text, option labels and
// `keywords`, ranks the hits, and says what to do about a setting that is hidden because a parent option is off ("Turn on Late fee first").
// Tested in tests/settings-search-core.test.js, including "every schema setting can be found by searching its own label".
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.SettingsSearchCore = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  var MIN_CHARS = 2;

  // lower case, no accents or punctuation, one space between words, a trailing "s" dropped from longer words ("lessons" = "lesson")
  function normalise(str) {
    var t = String(str == null ? "" : str).normalize("NFKD").replace(/[̀-ͯ]/g, "").toLowerCase();
    t = t.replace(/[‘’ʼ]/g, "'").replace(/'s\b/g, "").replace(/['"]/g, "").replace(/[^a-z0-9%]+/g, " ").trim();
    return t.split(" ").filter(Boolean).map(stem).join(" ");
  }
  function stem(w) { return w.length > 3 && /[^s]s$/.test(w) ? w.slice(0, -1) : w; }
  function words(str) { var n = normalise(str); return n ? n.split(" ") : []; }

  // Tab and sub-item names for the parts of the screen that are not plain settings (their content is built by hand in org.js).
  var TAB_KEYWORDS = {
    profile: ["business", "company", "name", "address", "logo", "gst", "tax", "invoice number"],
    calendar: ["branches", "branch", "rooms", "room", "terms", "term", "holidays", "holiday", "closed days", "school year", "library"],
    users: ["staff", "admin", "invite", "tutor", "team", "permissions", "people", "access", "owner", "email invite"],
    billing: ["billing", "billed", "how to bill", "fees", "charges", "deposit", "late fee", "discount", "prepaid", "absent"],
    invoicing: ["invoicing", "invoice", "bills", "send", "due date", "whatsapp"],
    payments: ["paynow", "pay", "bank", "card", "hitpay", "stripe"],
    lessons: ["attendance", "remarks", "feedback", "timetable", "tutors"],
    tutor_pay: ["salary", "wages", "payroll", "commission"],
    import: ["upload", "csv", "spreadsheet", "bulk", "bring in data"],
    review: ["launch", "check", "test invoice", "go live"],
    plan: ["subscription", "price", "upgrade", "stripe", "billing", "per student", "tutordeck fee", "card"],
    audit: ["history", "log", "changes", "who changed", "record"]
  };
  // Things inside the hand-built tabs. `stepId` says which tab, `label` is what is shown, `find` is the heading (or CSS selector) to scroll to.
  var CUSTOM_ITEMS = [
    { stepId: "calendar", label: "Branches", find: "Branches", keywords: ["branch", "location", "centre address", "add a branch"] },
    { stepId: "calendar", label: "Rooms", find: "Branches", keywords: ["room", "classroom", "capacity", "add a room"] },
    { stepId: "calendar", label: "Terms", find: "Terms", keywords: ["term", "school term", "term dates", "add a term"] },
    { stepId: "calendar", label: "Holidays", find: "Holidays", keywords: ["holiday", "public holiday", "closed", "library", "school holiday", "add a holiday"] },
    { stepId: "users", label: "Invite staff or tutors", find: "Invite someone", keywords: ["invite", "add staff", "add tutor", "new user", "email invite", "resend invite"] },
    { stepId: "users", label: "Staff permissions", find: ".og-perms", keywords: ["permission", "access", "who can", "manage timetable", "issue invoices", "record payments", "view revenue", "run tutor pay", "audit log", "payout details"] }
  ];

  // Make an index. deps: { steps, extraTabs: [[id,title]], isVisible(field, settings), get(settings,path), display(field,value), visibleOptions?, setup: bool }
  // setup=false leaves out the wizard-only tabs (import, review), exactly as the tab row does.
  function createIndex(deps) {
    var entries = [], byPath = {}, n = 0;
    var steps = (deps.steps || []).filter(function (st) { return deps.setup || (st.id !== "review" && st.id !== "import"); });
    function add(e) {
      e.order = n++; e.nLabel = normalise(e.label); e.nKeywords = (e.keywords || []).map(normalise);
      e.nHelp = normalise(e.help || ""); e.nOptions = (e.optionLabels || []).map(normalise);
      e.nTab = normalise(e.stepTitle || ""); e.nGroup = normalise(e.group || "");
      entries.push(e); if (e.path) byPath[e.path] = e; return e;
    }
    steps.forEach(function (st) {
      add({ kind: "tab", id: "tab:" + st.id, stepId: st.id, stepTitle: st.title, label: st.title, keywords: TAB_KEYWORDS[st.id] || [] });
      var group = "";
      st.fields.forEach(function (f) {
        if (f.type === "group") {
          group = f.label;
          add({ kind: "group", id: "group:" + f.label, stepId: st.id, stepTitle: st.title, group: "", label: f.label, help: f.help, keywords: f.keywords, soon: !!f.soon, field: f });
          return;
        }
        var label = f.label || firstSentence(f.help) || f.path;
        add({ kind: "field", id: f.path || "field:" + label, path: f.path, stepId: st.id, stepTitle: st.title, group: group, label: label, help: f.help, keywords: f.keywords,
          optionLabels: (f.options || []).map(function (o) { return o[1]; }), soon: !!f.soon, field: f, type: f.type });
      });
      CUSTOM_ITEMS.filter(function (c) { return c.stepId === st.id; }).forEach(function (c) {
        add({ kind: "item", find: c.find, id: "item:" + c.label, stepId: st.id, stepTitle: st.title, group: "", label: c.label, keywords: c.keywords });
      });
    });
    if (!deps.setup) (deps.extraTabs || []).forEach(function (t) {
      add({ kind: "tab", id: "tab:" + t[0], stepId: t[0], stepTitle: t[1], label: t[1], keywords: TAB_KEYWORDS[t[0]] || [] });
    });
    return { entries: entries, byPath: byPath, deps: deps };
  }
  function firstSentence(s) { return s ? String(s).split(/(?<=[.!?])\s/)[0].slice(0, 80) : ""; }

  // 3 = same word, 2 = the word starts with it, 1 = the word contains it (3+ letters)
  function wordHit(w, t) { return w === t ? 3 : (t.length >= MIN_CHARS && w.indexOf(t) === 0) ? 2 : (t.length >= 3 && w.indexOf(t) > 0) ? 1 : 0; }
  function best(wordList, t) { var b = 0; for (var i = 0; i < wordList.length; i++) { var h = wordHit(wordList[i], t); if (h > b) b = h; if (b === 3) break; } return b; }

  // Score one entry for the typed tokens; 0 = no match. EVERY token has to match somewhere (so "late fee amount" narrows).
  function scoreEntry(e, tokens, nq) {
    var total = 0;
    var lw = e.nLabel ? e.nLabel.split(" ") : [], hw = e.nHelp ? e.nHelp.split(" ") : [], tw = e.nTab ? e.nTab.split(" ") : [], gw = e.nGroup ? e.nGroup.split(" ") : [];
    for (var i = 0; i < tokens.length; i++) {
      var t = tokens[i], s = 0, h;
      if ((h = best(lw, t))) s = Math.max(s, 20 + h * 14);                              // label words 34..62
      for (var k = 0; k < e.nKeywords.length; k++) { var kw = e.nKeywords[k]; var kh = kw === t ? 3 : best(kw.split(" "), t); if (kh) s = Math.max(s, 16 + kh * 12); }   // keywords 28..52
      for (var o = 0; o < e.nOptions.length; o++) { if ((h = best(e.nOptions[o].split(" "), t))) s = Math.max(s, 8 + h * 8); }                                          // option labels 16..32
      if ((h = best(gw, t))) s = Math.max(s, 6 + h * 5);                                // the group heading it sits under
      if ((h = best(tw, t))) s = Math.max(s, 4 + h * 4);                                // the tab it is on
      if ((h = best(hw, t))) s = Math.max(s, 2 + h * 3);                                // help text 5..11
      if (!s) return 0;
      total += s;
    }
    if (e.nLabel === nq) total += 120;                                                  // the whole label typed
    else if (e.nLabel.indexOf(nq) === 0) total += 50;                                   // label starts with what was typed
    else if (nq && (" " + e.nLabel + " ").indexOf(" " + nq + " ") > -1) total += 30;    // whole words inside the label
    if (e.kind === "tab" || e.kind === "group") total -= 10;                            // a real setting beats the tab or heading it sits under
    return total;
  }

  // Results for `query`, best first. Each: { entry, score, value, hidden, soon }.
  // `settings` is what the form shows now (the draft).
  function search(index, query, settings, opts) {
    var nq = normalise(query), tokens = nq ? nq.split(" ") : [];
    if (String(query == null ? "" : query).trim().length < MIN_CHARS || !tokens.length) return [];
    var limit = (opts && opts.limit) || 8, out = [];
    index.entries.forEach(function (e) {
      var sc = scoreEntry(e, tokens, nq);
      if (sc > 0) out.push({ entry: e, score: sc });
    });
    out.sort(function (a, b) { return b.score - a.score || a.entry.order - b.entry.order; });
    return out.slice(0, limit).map(function (r) {
      var e = r.entry;
      return { entry: e, score: r.score, soon: !!e.soon, value: valueText(index, e, settings), hidden: hiddenInfo(index, e, settings) };
    });
  }

  function valueText(index, e, s) {
    if (e.kind !== "field" || !e.path || !s) return "";
    var f = e.field;
    if (f.type === "note" || f.type === "group") return "";
    if (f.type === "textarea") { var v = String(index.deps.get(s, e.path) || "").replace(/\s+/g, " ").trim(); return v.length > 48 ? v.slice(0, 47) + "\u2026" : v || "Standard message"; }
    try { return String(index.deps.display(f, index.deps.get(s, e.path))); } catch (x) { return ""; }
  }

  // Why a setting is not on screen right now, and which other setting brings it back.
  // null = it is showing. Otherwise { parentPath, parentLabel, action, optionsNeeded } — `action` is the sentence to show.
  function hiddenInfo(index, e, s, depth) {
    if (e.kind !== "field" || !s) return null;
    var f = e.field, deps = index.deps;
    if (deps.isVisible(f, s)) return null;
    var parents = (f.parent ? [].concat(f.parent) : []).slice();
    if (f.groupOnly && parents.indexOf("lessons.class_type") < 0) parents.push("lessons.class_type");
    var pf = parents.map(function (p) { return index.byPath[p] && index.byPath[p].field; }).filter(Boolean);
    if (!pf.length) return { parentPath: null, parentLabel: "", action: "Not showing right now", optionsNeeded: [] };
    // try every combination of the parents' values; keep the one that changes the fewest, and name the first parent it changes
    var cands = pf.map(candidates), bestPlan = null;
    (function walk(i, plan) {
      if (i === pf.length) {
        var c = clone(s); plan.forEach(function (p) { deps.set(c, p.path, p.value); });
        if (!deps.isVisible(f, c)) return;
        var changes = plan.filter(function (p) { return p.changed; }).length;
        if (!bestPlan || changes < bestPlan.changes) bestPlan = { changes: changes, plan: plan.slice() };
        return;
      }
      cands[i].forEach(function (v) {
        var cur = deps.get(s, pf[i].path);
        plan.push({ path: pf[i].path, value: v, changed: JSON.stringify(v) !== JSON.stringify(cur), field: pf[i] }); walk(i + 1, plan); plan.pop();
      });
    })(0, []);
    if (!bestPlan) return { parentPath: pf[0].path, parentLabel: pf[0].label, action: "Not showing right now", optionsNeeded: [] };
    var first = bestPlan.plan.filter(function (p) { return p.changed; })[0] || bestPlan.plan[0], pfield = first.field;
    var needed = bestPlan.plan.filter(function (p) { return p.path === first.path; });
    // every value of that parent that works (alone, with the other parents as planned)
    var okValues = candidates(pfield).filter(function (v) {
      var c = clone(s); bestPlan.plan.forEach(function (p) { deps.set(c, p.path, p.path === first.path ? v : p.value); }); return deps.isVisible(f, c);
    });
    var pe = index.byPath[first.path], up = pe && (depth || 0) < 3 ? hiddenInfo(index, pe, s, (depth || 0) + 1) : null;
    if (up) return up;                                                                   // the parent is itself hidden: ask for that one first
    return { parentPath: first.path, parentLabel: pfield.label, action: phrase(pfield, okValues), optionsNeeded: okValues, needed: needed.length };
  }
  function candidates(pf) {
    if (pf.type === "toggle") return [true, false];
    if (pf.options) return pf.options.map(function (o) { return o[0]; });
    return [];
  }
  function phrase(pf, okValues) {
    if (pf.type === "toggle") return (okValues[0] === false ? "Turn off " : "Turn on ") + pf.label + " first";
    var labels = okValues.map(function (v) { var o = (pf.options || []).filter(function (x) { return x[0] === v; })[0]; return o ? shortOption(o[1]) : String(v); });
    if (labels.length && labels.length <= 2) return "Set “" + pf.label + "” to " + labels.map(function (l) { return "“" + l + "”"; }).join(" or ") + " first";
    return "Change “" + pf.label + "” first";
  }
  function shortOption(l) { return String(l).split(" — ")[0]; }
  function clone(o) { return JSON.parse(JSON.stringify(o)); }

  // What the result line says under the name: "Billing › Late fees"
  function trail(e) { return [e.stepTitle, e.kind === "field" || e.kind === "group" ? (e.group || "") : ""].filter(Boolean).join(" › "); }

  return { MIN_CHARS: MIN_CHARS, normalise: normalise, createIndex: createIndex, search: search, hiddenInfo: hiddenInfo, valueText: valueText, trail: trail,
    TAB_KEYWORDS: TAB_KEYWORDS, CUSTOM_ITEMS: CUSTOM_ITEMS };
});
