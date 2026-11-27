// Centre Money > Statements (T34 M0-M2): upload a bank statement CSV, tell TutorDeck which column is which (once), review what matched and what did not,
// confirm, mark "not ours", undo. The FILE NEVER LEAVES THE BROWSER: it is read and parsed here (assets/js/statement-core.js), and only the mapped lines
// go up (account numbers already cut to their last 4 digits). Every read and write is a database function (stmt_queue, stmt_check, stmt_import,
// stmt_save_mapping, stmt_confirm, stmt_ignore, stmt_ignore_out, stmt_undo, stmt_forget_payer, stmt_rematch); this page never touches a table and never writes money
// by itself: the matching rules, the payments and the undo all live in db/migration_statement_matching.sql.
// Shares the tabs, the message line and the side sheet with assets/js/centre-money.js (window.CentreMoneyUI).
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var SC = window.StatementCore, CM = window.CentreMoneyCore, UI = null;
  var esc = function (s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var orgId = null, data = null, sub = "review", mode = "list", built = false, busy = false, seq = 0, cur = null;
  var up = { text: "", rows: [], mapping: null, parsed: null, check: null, mappingId: null, account: "Main account", saveName: "My bank", save: true, fileName: "", chosen: "new" };

  function rpc(name, args) { return window.sb.rpc(name, args); }
  function toast(t) { try { TL.toast(t, "ok"); } catch (e) {} }
  function say(t, bad) { if (UI) UI.say(t, bad); }
  function money(c) { return SC.fmtMoney(c); }
  function dshort(iso) { return CM.shortDate(iso); }
  function plural(n, a, b) { return n === 1 ? a : b; }
  function chev() { return UI.chev(); }
  function errorText(err) {
    var m = String((err && err.message) || err || "");
    if (/NOT_FOUND/.test(m)) return "That isn’t available any more. Check again and try once more.";
    if (/JWT|expired|not authenticated/i.test(m)) return "Your session ended. Sign in again.";
    if (/Failed to fetch|NetworkError|network/i.test(m)) return "Couldn’t reach the server. Check your connection and try again.";
    return m.replace(/^[A-Z_]+: /, "") || "Something went wrong. Try again.";
  }
  function missing(err) { return !!err && (err.code === "42883" || err.code === "PGRST202" || /does not exist|Could not find the function/i.test(err.message || "")); }
  function msgSheet(t, bad) { var m = $("st-msg"); if (!m) return; m.textContent = t || ""; m.className = "cm-msg" + (t ? (bad ? " err" : " ok") : ""); }

  // ---------------------------------------------------------------- the tab
  function frame() {
    $("cm-stmt").innerHTML = '<div class="card cm-sum" id="st-sum"><div class="cm-sum-s">Loading…</div></div><div id="st-main" aria-live="polite"></div>';
    $("st-sum").addEventListener("click", function (e) {
      if (e.target.closest("#st-up")) startUpload();
      else if (e.target.closest("#st-again")) rematch();
    });
    $("st-main").addEventListener("click", onMain);
    $("st-main").addEventListener("change", onChange);
    $("st-main").addEventListener("input", onInput);
    built = true;
  }
  async function show() {
    UI = window.CentreMoneyUI; orgId = UI.orgId();
    if (!built) frame();
    await load();
  }
  async function load(msg) {
    var mine = ++seq;
    var r = await rpc("stmt_queue", { p_org: orgId });
    if (mine !== seq) return;
    if (r.error) return fail(r.error);
    data = r.data; draw(msg);
  }
  function fail(err) {
    var m = String((err && err.message) || "");
    var box = '<div class="card cm-block"><h2 class="cm-h2">';
    if (missing(err)) { $("st-sum").innerHTML = ""; $("st-main").innerHTML = box + 'Not switched on yet</h2><p class="cm-note">Statement matching needs <b>db/migration_statement_matching.sql</b> run on this database first.</p></div>'; return; }
    if (/switched on/.test(m)) { $("st-sum").innerHTML = ""; $("st-main").innerHTML = box + 'Bank statement matching is off</h2><p class="cm-note">Switch on “Bank statement matching” under <b>How parents pay</b> in this centre’s settings, then come back here.</p></div>'; return; }
    if (/NOT_ALLOWED/.test(m)) { $("st-sum").innerHTML = ""; $("st-main").innerHTML = box + 'Statements are for people who record payments</h2><p class="cm-note">Ask the centre owner to give you the “record payments” permission.</p></div>'; return; }
    if (/NOT_FOUND/.test(m)) { $("st-sum").innerHTML = ""; $("st-main").innerHTML = box + 'Centre not available</h2><p class="cm-note">This centre doesn’t exist, or you aren’t an owner or staff member there.</p></div>'; return; }
    say(errorText(err), true);
  }
  function counts() {
    var inN = 0, outN = 0; (data.review || []).forEach(function (l) { if (l.cents > 0) inN++; else outN++; });
    return { inN: inN, outN: outN, matched: (data.matched || []).filter(function (m) { return !m.reversed; }).length };
  }
  function draw(msg) {
    var c = counts(), total = data.review_total || 0;
    var line = total ? (c.inN + " " + plural(c.inN, "payment needs", "payments need") + " a decision" + (c.outN ? " · " + c.outN + " money out" : "")) : "Nothing is waiting for you";
    $("st-sum").innerHTML = '<div class="cm-sum-t">Bank statements</div><div class="cm-sum-s">' + esc(line) + '</div>' +
      (msg ? '<p class="cm-note ok-note">' + esc(msg) + '</p>' : '') +
      '<div class="cm-acts"><button type="button" class="btn btn-primary" id="st-up">Upload a statement</button>' +
      (total ? '<button type="button" class="btn" id="st-again">Check again</button>' : '') + '</div>' +
      '<p class="cm-note">The file is read on this device. Only the date, amount and payment text go to TutorDeck, and the text is deleted once a line is settled (or after 60 days).</p>';
    if (mode === "upload") return drawUpload();
    drawList();
    try { var b = $("st-up"); if (b) TL.coach("stmt-intro", b, "Upload your bank’s CSV. TutorDeck marks a payment paid when it carries the invoice number and the exact amount; everything else waits here for you."); } catch (e) {}
  }

  // ---------------------------------------------------------------- the lists
  function filters() {
    var c = counts(), f = [["review", "Needs review", data.review_total || 0], ["matched", "Matched", c.matched], ["batches", "Uploads", (data.batches || []).length], ["payers", "Payers", (data.payers || []).length]];
    return '<div class="cm-filters" role="group" aria-label="Show">' + f.map(function (x) {
      return '<button type="button" class="cm-f" data-sub="' + x[0] + '" aria-pressed="' + (sub === x[0]) + '">' + esc(x[1]) + ' ' + x[2] + '</button>';
    }).join("") + '</div>';
  }
  function drawList() {
    var html = filters();
    if (sub === "review") html += reviewHtml(); else if (sub === "matched") html += matchedHtml(); else if (sub === "batches") html += batchesHtml(); else html += payersHtml();
    $("st-main").innerHTML = html;
  }
  function reviewRow(l, i) {
    var text = l.stub ? "Put back after an undo" : (l.ref_text || l.payer_text || "(no text)");
    var who = !l.stub && l.payer_text && l.ref_text ? l.payer_text : "";
    var tone = l.rule && l.exact ? "" : " warn";
    return '<button type="button" class="cm-row" data-r="' + i + '"><span class="cm-main"><span class="cm-name st-text">' + esc(text) + '</span>' +
      '<span class="cm-sub">' + esc(dshort(l.line_date)) + (who ? ' · ' + esc(who) : '') + '</span><span class="cm-sub' + tone + '">' + esc(l.reason || "") + '</span></span>' +
      '<span class="cm-amt' + (l.cents < 0 ? ' st-out' : '') + '">' + esc(money(l.cents)) + '</span>' + chev() + '</button>';
  }
  function reviewHtml() {
    var rows = data.review || [], ins = [], outs = [];
    rows.forEach(function (l, i) { (l.cents > 0 ? ins : outs).push([l, i]); });
    if (!rows.length) return '<div class="card cm-block"><p class="cm-note">Nothing is waiting. Upload a statement and the payments it carries are matched to your open invoices.</p></div>';
    var h = '';
    if (ins.length) h += '<section class="cm-sec"><h2 class="cm-h">Money in <span class="cm-n">' + ins.length + '</span></h2><div class="card cm-list">' + ins.map(function (x) { return reviewRow(x[0], x[1]); }).join("") + '</div></section>';
    else h += '<p class="cm-note">No payments are waiting. Only money out is left below.</p>';
    if (outs.length) h += '<section class="cm-sec"><h2 class="cm-h">Money out <span class="cm-n">' + outs.length + '</span></h2><p class="cm-note">Never matched automatically. Mark what is not a refund as “not ours”.</p>' +
      '<div class="card cm-list">' + outs.map(function (x) { return reviewRow(x[0], x[1]); }).join("") + '</div><div class="cm-acts"><button type="button" class="btn" id="st-out">Mark all money out as not ours</button></div></section>';
    if ((data.review_total || 0) > rows.length) h += '<p class="cm-foot">Showing the first ' + rows.length + ' of ' + data.review_total + '.</p>';
    return h;
  }
  function matchedChip(m) {
    if (m.reversed) return ["Undone", ""];
    if (m.kind === "ignored") return ["Not ours", ""];
    if (m.payment_reversed) return ["Payment reversed", "bad"];
    return m.auto ? ["Automatic", "ok"] : ["Confirmed", "ok"];
  }
  function matchedHtml() {
    var rows = data.matched || [];
    if (!rows.length) return '<div class="card cm-block"><p class="cm-note">Nothing has been matched yet.</p></div>';
    return '<div class="card cm-list">' + rows.map(function (m, i) {
      var c = matchedChip(m), what = m.kind === "ignored" ? "Not ours" : ((m.invoices || []).join(", ") || "Payment") + (m.household ? " · " + m.household : "");
      return '<button type="button" class="cm-row' + (m.reversed ? ' off' : '') + '" data-m="' + i + '"><span class="cm-main"><span class="cm-name">' + esc(what) + '</span><span class="cm-sub">' + esc(dshort(m.line_date)) + '</span></span>' +
        '<span class="cm-chip ' + c[1] + '">' + esc(c[0]) + '</span><span class="cm-amt">' + esc(money(m.cents)) + '</span>' + chev() + '</button>';
    }).join("") + '</div>';
  }
  function batchesHtml() {
    var rows = data.batches || [];
    if (!rows.length) return '<div class="card cm-block"><p class="cm-note">No statement has been uploaded yet.</p></div>';
    return '<div class="card cm-list">' + rows.map(function (b) {
      var a = [b.new + " new", b.duplicates ? b.duplicates + " already imported" : "", b.auto ? b.auto + " paid automatically" : "", b.review ? b.review + " to review" : ""].filter(Boolean).join(" · ");
      return '<div class="cm-row cm-static"><span class="cm-main"><span class="cm-name">' + esc(b.account) + ' · ' + esc(dshort(b.imported_at.slice(0, 10))) + '</span><span class="cm-sub">' +
        esc(b.date_from ? dshort(b.date_from) + " to " + dshort(b.date_to) : "") + '</span><span class="cm-sub">' + esc(a) + '</span></span><span class="cm-amt">' + b.lines + '</span></div>';
    }).join("") + '</div><p class="cm-note">Only counts are kept for an upload: never the file or its name.</p>';
  }
  function payersHtml() {
    var rows = data.payers || [];
    if (!rows.length) return '<div class="card cm-block"><p class="cm-note">No payer is remembered yet. When you confirm a payment, tick “Remember this payer” and their next exact payment is matched by itself.</p></div>';
    return '<div class="card cm-list">' + rows.map(function (p, i) {
      return '<div class="cm-row cm-static"><span class="cm-main"><span class="cm-name st-text">' + esc(p.payer) + '</span><span class="cm-sub">pays for ' + esc(p.household) + ' · used ' + p.times_used + ' ' + plural(p.times_used, "time", "times") + '</span></span>' +
        '<button type="button" class="btn cm-act" data-forget="' + i + '">Forget</button></div>';
    }).join("") + '</div>';
  }

  async function rematch() {
    if (busy) return; busy = true;
    var r = await rpc("stmt_rematch", { p_org: orgId }); busy = false;
    if (r.error) return say(errorText(r.error), true);
    var t = r.data.auto_matched ? r.data.auto_matched + " " + plural(r.data.auto_matched, "payment was", "payments were") + " marked paid." : "Checked again: nothing new matched.";
    await load(t);
  }

  // ---------------------------------------------------------------- one waiting line
  function openLine(i, trigger) {
    var l = (data.review || [])[i]; if (!l) return;
    cur = { kind: "line", i: i, pick: [], remember: !!l.payer_text, choosing: false };
    $("cm-st").textContent = money(l.cents) + (l.cents < 0 ? " out" : " in"); $("cm-sm").textContent = dshort(l.line_date) + (l.stub ? " · put back after an undo" : "");
    drawLineSheet(l);
    UI.openSheet(trigger);
  }
  function invRow(v) { return '<div class="cm-pay"><span class="cm-ld">' + esc(v.number) + (v.household ? ' · ' + esc(v.household) : '') + '</span><span>' + esc(money(v.balance_cents)) + ' owed</span></div>'; }
  function lineSheetNote(l, ids) {
    var all = (data.open_invoices || []), tot = 0;
    ids.forEach(function (id) { var v = all.filter(function (x) { return x.id === id; })[0] || (l.invoices || []).filter(function (x) { return x.id === id; })[0]; if (v) tot += v.balance_cents; });
    if (!ids.length || !tot) return "";
    if (l.cents === tot) return "The amount matches exactly.";
    if (l.cents < tot) return data.settings.partial_payments === false ? money(tot - l.cents) + " short, and this centre does not accept part payments, so TutorDeck will refuse it. Pick invoices this payment covers in full."
      : money(tot - l.cents) + " short: the invoice stays part-paid with " + money(tot - l.cents) + " still owing.";
    return money(l.cents - tot) + " over: " + (data.settings.overpayments === "refund" ? "the extra is flagged as owed back to the family." : "the extra is kept as credit for the family.");
  }
  function drawLineSheet(l) {
    var out = l.cents < 0, ids = cur.pick.length ? cur.pick : (cur.choosing ? [] : (l.invoices || []).map(function (v) { return v.id; }));
    var h = '<div class="cm-msg" id="st-msg" role="status" aria-live="polite"></div>';
    h += '<div class="cm-facts">' + (l.ref_text ? '<div><span>Text</span><span class="st-text">' + esc(l.ref_text) + '</span></div>' : '') + (l.payer_text ? '<div><span>Payer</span><span class="st-text">' + esc(l.payer_text) + '</span></div>' : '') +
      (l.bank_ref ? '<div><span>Bank ref</span><span class="st-text">' + esc(l.bank_ref) + '</span></div>' : '') + '</div>';
    if (l.reason) h += '<p class="cm-note' + (l.exact && l.rule ? '' : ' warn') + '">' + esc(l.reason) + '</p>';
    if (!out) {
      if (!cur.choosing && (l.invoices || []).length) {
        h += '<div class="cm-g"><div class="cm-gh">Suggested</div>' + l.invoices.map(invRow).join("") + '</div>';
        var n = lineSheetNote(l, ids); if (n) h += '<p class="cm-note">' + esc(n) + '</p>';
      }
      if (cur.choosing) {
        h += '<div class="cm-g"><div class="cm-gh">Choose the invoice(s) this pays</div><input class="cm-search" id="st-q" type="search" placeholder="Search by family or number" aria-label="Search open invoices" autocomplete="off">' +
          '<div id="st-pick">' + pickHtml("") + '</div></div>';
        var n2 = lineSheetNote(l, cur.pick); h += '<p class="cm-note" id="st-pn">' + esc(n2) + '</p>';
      }
      if (l.payer_text) h += '<label class="st-chk"><input type="checkbox" id="st-rem"' + (cur.remember ? ' checked' : '') + '> Remember this payer: their next exact payment is matched by itself</label>';
      h += '<div class="cm-acts col">';
      var can = cur.choosing ? cur.pick.length > 0 : (l.invoices || []).length > 0;
      h += '<button type="button" class="btn btn-primary" id="st-conf"' + (can ? '' : ' disabled') + '>Confirm this payment</button>';
      h += '<button type="button" class="btn" id="st-other">' + (cur.choosing ? 'Back to the suggestion' : 'Choose another invoice') + '</button>';
    } else h += '<div class="cm-acts col">';
    h += '<button type="button" class="btn quiet" id="st-no">Not ours</button></div>';
    h += '<p class="cm-note">Confirming records an ordinary bank payment on the invoice. You can undo it from the Matched list.</p>';
    $("cm-sb").innerHTML = h;
  }
  function pickHtml(q) {
    q = String(q || "").toLowerCase().trim();
    var rows = (data.open_invoices || []).filter(function (v) { return !q || (v.number + " " + (v.household || "")).toLowerCase().indexOf(q) >= 0; }).slice(0, 60);
    if (!rows.length) return '<p class="cm-note">No open invoice' + (q ? ' matches that' : ' yet') + '.</p>';
    return rows.map(function (v) {
      return '<label class="st-opt"><input type="checkbox" data-inv="' + esc(v.id) + '"' + (cur.pick.indexOf(v.id) >= 0 ? ' checked' : '') + '><span class="st-opt-t">' + esc(v.number) + ' · ' + esc(v.household || "") + '</span><span class="st-opt-a">' + esc(money(v.balance_cents)) + '</span></label>';
    }).join("");
  }
  async function confirmLine() {
    if (busy || !cur) return;
    var l = data.review[cur.i], ids = cur.choosing ? cur.pick : null;
    if (cur.choosing && !ids.length) return msgSheet("Choose at least one invoice.", true);
    var rem = $("st-rem"), remember = rem ? rem.checked : false;
    busy = true; var b = $("st-conf"); if (b) b.disabled = true;
    var r = await rpc("stmt_confirm", { p_line: l.id, p_invoice_ids: ids, p_remember: remember }); busy = false;
    if (r.error) { if (b) b.disabled = false; return msgSheet(errorText(r.error), true); }
    var n = (r.data.allocated || []).map(function (a) { return a.number; }).join(", ");
    var t = money(l.cents) + " recorded" + (n ? " on " + n : "") + (r.data.excess_cents ? " (" + money(r.data.excess_cents) + " kept as family credit)" : "") + ".";
    toast(t); UI.closeSheet(); await load(t); afterMoney();
  }
  async function ignoreLine() {
    if (busy || !cur) return;
    var l = data.review[cur.i];
    if (!(await TL.confirm({ title: "Not ours?", message: "This " + money(l.cents) + " line is set aside. No payment is recorded. You can undo it from the Matched list.", confirmText: "Not ours" }))) return;
    busy = true; var r = await rpc("stmt_ignore", { p_line: l.id }); busy = false;
    if (r.error) return msgSheet(errorText(r.error), true);
    toast("Set aside."); UI.closeSheet(); await load("Set aside.");
  }
  async function ignoreOut() {
    if (busy) return;
    var n = counts().outN;
    if (!(await TL.confirm({ title: "Mark money out as not ours?", message: n + " " + plural(n, "line", "lines") + " of money out will be set aside. No payment is recorded. You can undo each from the Matched list.", confirmText: "Mark all" }))) return;
    busy = true; var r = await rpc("stmt_ignore_out", { p_org: orgId }); busy = false;
    if (r.error) return say(errorText(r.error), true);
    await load(r.data.ignored + " set aside.");
  }

  // ---------------------------------------------------------------- one matched line
  function openMatch(i, trigger) {
    var m = (data.matched || [])[i]; if (!m) return;
    cur = { kind: "match", i: i };
    var c = matchedChip(m);
    $("cm-st").textContent = money(m.cents); $("cm-sm").textContent = dshort(m.line_date) + " · " + c[0];
    var how = m.kind === "ignored" ? "Set aside as not ours." : m.auto ? "Marked paid automatically (" + ruleWords(m.rule) + ")." : "Confirmed by a person" + (m.rule !== "manual" ? " (" + ruleWords(m.rule) + ")" : "") + ".";
    var h = '<div class="cm-msg" id="st-msg" role="status" aria-live="polite"></div><p class="cm-note">' + esc(how) + '</p>';
    if ((m.invoices || []).length) h += '<div class="cm-facts"><div><span>Invoices</span><span>' + esc(m.invoices.join(", ")) + '</span></div>' + (m.household ? '<div><span>Family</span><span>' + esc(m.household) + '</span></div>' : '') + '</div>';
    if (m.payment_reversed && !m.reversed) h += '<p class="cm-note warn">This payment was reversed from the invoice. Undo puts the line back in the queue so it can be matched again.</p>';
    if (!m.reversed) h += '<div class="cm-acts col"><button type="button" class="btn btn-primary" id="st-undo">Undo this match</button></div><p class="cm-note">Undo ' + (m.kind === "ignored" ? 'puts the line back to be decided again.' : 'reverses the payment (a new entry, nothing is edited) and puts the line back in the queue.') + ' A reason is kept in the record.</p>';
    else h += '<p class="cm-note">Undone. The line went back to the queue.</p>';
    $("cm-sb").innerHTML = h; UI.openSheet(trigger);
  }
  function ruleWords(r) { return { invoice_no: "invoice number and amount", payer_link: "remembered payer", amount_only: "the only invoice of that amount", household_total: "the family’s total", manual: "chosen by hand" }[r] || r; }
  async function undoMatch() {
    if (busy || !cur) return;
    var m = data.matched[cur.i];
    var why = await TL.prompt({ title: "Undo this match?", message: m.kind === "ignored" ? "The line goes back to the queue." : "The payment is reversed and the line goes back to the queue. Say why (kept in the record).", placeholder: "Reason", confirmText: "Undo" });
    if (why == null) return;
    if (!String(why).trim()) return msgSheet("Please say why.", true);
    busy = true; var r = await rpc("stmt_undo", { p_match: m.id, p_reason: String(why).trim() }); busy = false;
    if (r.error) return msgSheet(errorText(r.error), true);
    toast("Undone."); UI.closeSheet(); sub = "review"; await load("Undone: the line is back in the queue."); afterMoney();
  }
  async function forget(i) {
    var p = (data.payers || [])[i]; if (!p) return;
    if (!(await TL.confirm({ title: "Forget this payer?", message: "Their next payment will wait for you to confirm it, until you remember them again.", confirmText: "Forget" }))) return;
    var r = await rpc("stmt_forget_payer", { p_link: p.id });
    if (r.error) return say(errorText(r.error), true);
    await load("Forgotten.");
  }
  function afterMoney() { if (window.CentrePay && window.CentrePay.refresh) window.CentrePay.refresh(); }

  // ---------------------------------------------------------------- upload and the column mapping
  function startUpload() { mode = "upload"; sub = "review"; up.text = ""; up.rows = []; up.mapping = null; up.parsed = null; up.check = null; up.mappingId = null; up.fileName = ""; up.chosen = "new";
    try { up.account = TL.store.get("stmt_account") || up.account; up.saveName = TL.store.get("stmt_mapname") || up.saveName; } catch (e) {} drawUpload(); say(""); }
  function leaveUpload() { mode = "list"; draw(); }
  function drawUpload() {
    var h = '<div class="card cm-block st-up"><h2 class="cm-h2">Upload a bank statement</h2>' +
      '<p class="cm-note">Download the CSV from your bank’s online banking. The file stays on this device.</p>' +
      '<label class="st-lab" for="st-file">Statement file (CSV)</label><input type="file" id="st-file" accept=".csv,.txt,text/csv,text/plain">' +
      '<label class="st-lab" for="st-acct">Account label</label><input type="text" id="st-acct" maxlength="40" value="' + esc(up.account) + '" autocomplete="off">' +
      '<p class="cm-note">Any name you like, for example “Main account”. A different label keeps two accounts apart.</p>';
    if (up.text) h += mappingHtml();
    h += '<div class="cm-acts"><button type="button" class="btn" id="st-cancel">Cancel</button></div></div>';
    $("st-main").innerHTML = h;
    if (up.text) drawPreview();
  }
  function colLabel(i) {
    var hdr = up.rows[(up.mapping.header_rows || 1) - 1] || [], first = up.rows[up.mapping.header_rows || 1] || [];
    var hv = String(hdr[i] || "").trim(), sv = String(first[i] || "").trim();
    return SC.colName(i) + (hv ? " · " + hv : "") + (sv ? " (" + sv.slice(0, 24) + ")" : "");
  }
  function colSelect(id, val, none) {
    var n = up.rows.reduce(function (t, r) { return Math.max(t, r.length); }, 0), o = none ? '<option value="">' + esc(none) + '</option>' : '';
    for (var i = 0; i < Math.min(n, 40); i++) o += '<option value="' + i + '"' + (val === i ? ' selected' : '') + '>' + esc(colLabel(i)) + '</option>';
    return '<select id="' + id + '" data-k="' + id + '">' + o + '</select>';
  }
  function mappingHtml() {
    var m = up.mapping, saved = data.mappings || [];
    var h = '<div class="st-map"><div class="cm-gh">How to read this file</div>';
    if (saved.length) h += '<label class="st-lab" for="st-saved">Saved layout</label><select id="st-saved"><option value="new">Set up the columns again</option>' +
      saved.map(function (s) { return '<option value="' + esc(s.id) + '"' + (up.chosen === s.id ? ' selected' : '') + '>' + esc(s.name) + '</option>'; }).join("") + '</select>';
    h += '<div class="st-two"><div><label class="st-lab" for="st-delim">Columns are separated by</label><select id="st-delim" data-k="delimiter">' +
      [[",", "commas ( , )"], [";", "semicolons ( ; )"], ["\t", "tabs"], ["|", "bars ( | )"]].map(function (d) { return '<option value="' + (d[0] === "\t" ? "tab" : d[0]) + '"' + (m.delimiter === d[0] ? ' selected' : '') + '>' + d[1] + '</option>'; }).join("") + '</select></div>' +
      '<div><label class="st-lab" for="st-hdr">Rows above the first payment</label><input type="number" id="st-hdr" data-k="header_rows" min="0" max="99" value="' + m.header_rows + '"></div></div>';
    h += '<div class="st-two"><div><label class="st-lab" for="st-date">Date column</label>' + colSelect("st-date", m.date_col) + '</div>' +
      '<div><label class="st-lab" for="st-dfmt">Date looks like</label><select id="st-dfmt" data-k="date_format">' + SC.DATE_FORMATS.map(function (f) { return '<option value="' + f[0] + '"' + (m.date_format === f[0] ? ' selected' : '') + '>' + esc(f[1] + " — " + f[2]) + '</option>'; }).join("") + '</select></div></div>';
    h += '<label class="st-lab" for="st-amode">Amounts</label><select id="st-amode" data-k="amount_mode">' + SC.AMOUNT_MODES.map(function (a) { return '<option value="' + a[0] + '"' + (m.amount_mode === a[0] ? ' selected' : '') + '>' + esc(a[1]) + '</option>'; }).join("") + '</select>';
    if (m.amount_mode === "signed") h += '<label class="st-lab" for="st-amt">Amount column</label>' + colSelect("st-amt", m.amount_col);
    else if (m.amount_mode === "debit_credit") h += '<div class="st-two"><div><label class="st-lab" for="st-deb">Money out column</label>' + colSelect("st-deb", m.debit_col) + '</div><div><label class="st-lab" for="st-cre">Money in column</label>' + colSelect("st-cre", m.credit_col) + '</div></div>';
    else h += '<div class="st-two"><div><label class="st-lab" for="st-amt">Amount column</label>' + colSelect("st-amt", m.amount_col) + '</div><div><label class="st-lab" for="st-dc">Dr / Cr column</label>' + colSelect("st-dc", m.drcr_col) + '</div></div>';
    h += '<label class="st-chk"><input type="checkbox" id="st-inv"' + (m.invert ? ' checked' : '') + '> Swap signs (this bank shows money in as negative)</label>';
    h += '<div class="cm-gh">Payment text</div><div class="st-refs" id="st-refs">';
    var n = Math.min(up.rows.reduce(function (t, r) { return Math.max(t, r.length); }, 0), 40);
    for (var i = 0; i < n; i++) h += '<label class="st-chk"><input type="checkbox" data-ref="' + i + '"' + (m.ref_cols.indexOf(i) >= 0 ? ' checked' : '') + '> ' + esc(colLabel(i)) + '</label>';
    h += '</div><p class="cm-note">Tick every column that can carry the invoice number: the description, the PayNow remark, the reference.</p>';
    h += '<div class="st-two"><div><label class="st-lab" for="st-payer">Payer name column</label>' + colSelect("st-payer", m.payer_col, "None") + '</div><div><label class="st-lab" for="st-bref">Bank’s own reference column</label>' + colSelect("st-bref", m.bank_ref_col, "None") + '</div></div>';
    h += '<div id="st-prev" aria-live="polite"></div>';
    h += '<label class="st-chk"><input type="checkbox" id="st-save"' + (up.save ? ' checked' : '') + '> Remember these columns for next time as <input type="text" id="st-sname" maxlength="60" value="' + esc(up.saveName) + '" aria-label="Name of this layout"></label>';
    h += '<div class="cm-acts"><button type="button" class="btn btn-primary" id="st-go" disabled>Import</button></div></div>';
    return h;
  }
  function drawPreview() {
    var m = up.mapping, p = up.parsed = SC.applyMapping(up.rows, m), box = $("st-prev"); if (!box) return;
    var s = SC.summarise(p.lines), h = '<div class="cm-gh">Check the first rows</div>';
    h += '<div class="st-tbl-w"><table class="st-tbl"><thead><tr><th>Date</th><th class="r">Amount</th><th>Text</th></tr></thead><tbody>' +
      p.lines.slice(0, 5).map(function (l) { return '<tr><td>' + esc(dshort(l.date)) + '</td><td class="r">' + esc(money(l.cents)) + '</td><td class="st-text">' + esc(l.ref || l.payer || "") + '</td></tr>'; }).join("") + '</tbody></table></div>';
    var go = $("st-go");
    if (p.errors.length) {
      h += '<p class="cm-note err">' + p.errors.length + ' ' + plural(p.errors.length, "row doesn’t", "rows don’t") + ' read correctly. ' + esc(p.errors[0].message) + (p.errors.length > 1 ? ' (and ' + (p.errors.length - 1) + ' more)' : '') + ' Change the columns above until none are left.</p>';
      if (go) go.disabled = true;
    } else if (!p.lines.length) { h += '<p class="cm-note err">No payment rows found. Check “Rows above the first payment”.</p>'; if (go) go.disabled = true; }
    else {
      h += '<p class="cm-note"><b>' + s.lines + '</b> ' + plural(s.lines, "line", "lines") + ' · money in ' + esc(money(s.credits)) + ' (' + s.nIn + ') · money out ' + esc(money(s.debits)) + ' (' + s.nOut + ') · ' + esc(dshort(s.from)) + ' to ' + esc(dshort(s.to)) + '.</p>';
      h += '<p class="cm-note" id="st-known">Checking which lines were uploaded before…</p>';
      if (go) { go.disabled = false; go.textContent = "Import " + s.lines + " " + plural(s.lines, "line", "lines"); }
      checkKnown(p.lines);
    }
    box.innerHTML = h;
  }
  var checkTimer = null;
  function checkKnown(lines) {
    clearTimeout(checkTimer);
    checkTimer = setTimeout(async function () {
      var acct = ($("st-acct") || {}).value || up.account, r = await rpc("stmt_check", { p_org: orgId, p_account: acct, p_lines: lines });
      var el = $("st-known"); if (!el) return;
      if (r.error) { el.textContent = ""; return; }
      var k = r.data.known || 0;
      el.textContent = k ? k + " of these " + plural(k, "line was", "lines were") + " uploaded before and will be skipped. " + r.data.new + " " + plural(r.data.new, "is", "are") + " new." : "None of these lines were uploaded before.";
    }, 250);
  }
  function parseFile(text) {
    up.text = text; var d = SC.detectDelimiter(text);
    if (!d) { up.rows = []; up.text = ""; say("That doesn’t look like a CSV table (no columns found). Download the statement as CSV from your bank.", true); return false; }
    up.rows = SC.parseCSV(text, d); up.mapping = SC.guessMapping(up.rows, d); up.chosen = "new"; return true;
  }
  function onMain(e) {
    var t = e.target;
    if (t.closest("#st-cancel")) return leaveUpload();
    if (t.closest("#st-go")) return doImport();
    var f = t.closest("[data-sub]"); if (f) { sub = f.dataset.sub; return drawList(); }
    var r = t.closest("[data-r]"); if (r) return openLine(+r.dataset.r, r);
    var m = t.closest("[data-m]"); if (m) return openMatch(+m.dataset.m, m);
    var fg = t.closest("[data-forget]"); if (fg) return forget(+fg.dataset.forget);
    if (t.closest("#st-out")) return ignoreOut();
  }
  function readMapping() {
    var m = up.mapping, v = function (id) { var el = $(id); return el ? el.value : ""; }, num = function (id) { var x = v(id); return x === "" ? null : +x; };
    m.header_rows = Math.max(0, Math.min(99, +v("st-hdr") || 0));
    m.date_col = num("st-date"); m.date_format = v("st-dfmt") || m.date_format; m.amount_mode = v("st-amode") || m.amount_mode;
    if (m.amount_mode === "signed") m.amount_col = num("st-amt"); else if (m.amount_mode === "debit_credit") { m.debit_col = num("st-deb"); m.credit_col = num("st-cre"); } else { m.amount_col = num("st-amt"); m.drcr_col = num("st-dc"); }
    m.payer_col = num("st-payer"); m.bank_ref_col = num("st-bref"); m.invert = !!($("st-inv") || {}).checked;
    m.ref_cols = Array.prototype.map.call(document.querySelectorAll("#st-refs [data-ref]:checked"), function (c) { return +c.dataset.ref; });
  }
  async function onChange(e) {
    var t = e.target;
    if (t.id === "st-file") {
      var file = t.files && t.files[0]; if (!file) return;
      if (file.size > 12 * 1024 * 1024) return say("That file is bigger than 12 MB: is it a bank statement?", true);
      up.fileName = file.name; var text = await file.text(); say("");
      if (!parseFile(text)) return drawUpload();
      return drawUpload();
    }
    if (t.id === "st-saved") {
      up.chosen = t.value;
      if (t.value === "new") { up.mapping = SC.guessMapping(up.rows, up.mapping.delimiter); }
      else { var s = (data.mappings || []).filter(function (x) { return x.id === t.value; })[0]; if (s) { up.mapping = JSON.parse(JSON.stringify(s.mapping)); up.mappingId = s.id; up.saveName = s.name; } }
      return drawUpload();
    }
    if (t.id === "st-acct") { up.account = t.value; try { TL.store.set("stmt_account", t.value); } catch (x) {} if (up.parsed && up.parsed.lines.length && !up.parsed.errors.length) checkKnown(up.parsed.lines); return; }
    if (t.id === "st-save") { up.save = t.checked; return; }
    if (t.id === "st-delim") {
      var d = t.value === "tab" ? "\t" : t.value; up.rows = SC.parseCSV(up.text, d); up.mapping.delimiter = d; return drawUpload();
    }
    if (t.closest && t.closest(".st-map") && t.id !== "st-sname") {
      readMapping(); up.chosen = "new";                                                 // changed by hand: it is a new layout now (saved, if asked)
      var amodeChanged = t.id === "st-amode"; if (amodeChanged || t.id === "st-hdr") return drawUpload();
      drawPreview();
    }
  }
  function onInput(e) { var t = e.target; if (t.id === "st-sname") up.saveName = t.value; if (t.id === "st-hdr") { readMapping(); up.chosen = "new"; drawPreview(); } }
  document.addEventListener("change", function (e) {
    var c = e.target.closest && e.target.closest("#st-pick [data-inv]"); if (!c || !cur || cur.kind !== "line") return;
    var id = c.dataset.inv, i = cur.pick.indexOf(id);
    if (c.checked && i < 0) cur.pick.push(id); else if (!c.checked && i >= 0) cur.pick.splice(i, 1);
    var l = data.review[cur.i], n = $("st-pn"); if (n) n.textContent = lineSheetNote(l, cur.pick);
    var b = $("st-conf"); if (b) b.disabled = !cur.pick.length;
  });
  document.addEventListener("click", function (e) {
    var sb = $("cm-sb"); if (!sb || !sb.contains(e.target) || !cur) return;
    if (cur.kind === "line") {
      if (e.target.closest("#st-conf")) confirmLine();
      else if (e.target.closest("#st-no")) ignoreLine();
      else if (e.target.closest("#st-other")) { cur.choosing = !cur.choosing; cur.pick = []; drawLineSheet(data.review[cur.i]); }
    } else if (cur.kind === "match" && e.target.closest("#st-undo")) undoMatch();
  });
  document.addEventListener("input", function (e) { if (e.target.id === "st-q") { var b = $("st-pick"); if (b) b.innerHTML = pickHtml(e.target.value); } });
  document.addEventListener("change", function (e) { if (e.target.id === "st-rem" && cur) cur.remember = e.target.checked; });

  async function doImport() {
    if (busy || !up.parsed || up.parsed.errors.length || !up.parsed.lines.length) return;
    var acct = String(($("st-acct") || {}).value || "").trim();
    if (!acct) return say("Give the account a label first.", true);
    var bad = SC.validateMapping(up.mapping); if (bad.length) return say(bad[0], true);
    busy = true; var go = $("st-go"); if (go) { go.disabled = true; go.textContent = "Importing…"; } say("");
    try {
      var mid = up.chosen !== "new" ? up.chosen : null, saveBox = $("st-save"), nm = String(($("st-sname") || {}).value || "").trim();
      if (saveBox && saveBox.checked && nm) {
        var sv = await rpc("stmt_save_mapping", { p_org: orgId, p_name: nm, p_mapping: up.mapping });
        if (sv.error) throw sv.error; mid = sv.data.mapping_id; try { TL.store.set("stmt_mapname", nm); } catch (x) {}
      }
      var r = await rpc("stmt_import", { p_org: orgId, p_account: acct, p_mapping: mid, p_lines: up.parsed.lines });
      if (r.error) throw r.error;
      var d = r.data, parts = [d.new + " new " + plural(d.new, "line", "lines")];
      if (d.duplicates) parts.push(d.duplicates + " already imported (skipped)");
      if (d.auto_matched) parts.push(d.auto_matched + " paid automatically");
      parts.push(d.to_review + " " + plural(d.to_review, "needs", "need") + " a decision");
      var t = "Imported: " + parts.join(", ") + ".";
      mode = "list"; sub = "review"; toast(t); await load(t); afterMoney();
    } catch (err) { busy = false; if (go) { go.disabled = false; go.textContent = "Import"; } say(errorText(err), true); return; }
    busy = false;
  }

  window.CentreStatements = { show: show, refresh: function () { return built ? load() : null; } };
})();
