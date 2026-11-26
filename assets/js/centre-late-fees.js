// Centre Money > Late fees (T4 step S6): "Late fees waiting for you". A late fee is only ever a proposal; a person approves it (it becomes its own numbered
// invoice on the family's account) or waives it with a reason. Every read and write goes through database functions (centre_late_fee_list / _approve /
// _approve_all / _waive); this page never touches a table. When a fee falls due, how much it is, the cap, who may waive and "never twice" are all decided
// there (db/migration_centre_late_fees.sql); assets/js/centre-late-fees-core.js only words the answers.
// Shares the tabs, the message line and the side sheet with assets/js/centre-money.js (window.CentreMoneyUI).
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var LC = window.CentreLateFeesCore, CM = window.CentreMoneyCore, UI = null, esc = function (s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var orgId = null, list = null, seq = 0, built = false, busy = false, cur = null;

  function rpc(name, args) { return window.sb.rpc(name, args); }
  function toast(text) { try { TL.toast(text, "ok"); } catch (e) {} }
  function sheetMsg(text, bad) { var m = $("cl-msg"); if (!m) return; m.textContent = text || ""; m.className = "cm-msg" + (text ? (bad ? " err" : " ok") : ""); }
  function group(title, inner) { return '<div class="cm-g"><div class="cm-gh">' + esc(title) + '</div>' + inner + '</div>'; }

  // ---------------------------------------------------------------- the tab
  function frame() {
    $("cm-late").innerHTML = '<div class="card cm-sum" id="cl-sum"><div class="cm-sum-s">Loading…</div></div><div id="cl-list" aria-live="polite"></div>';
    $("cl-sum").addEventListener("click", function (e) { if (e.target.closest("#cl-all")) approveAll(); });
    $("cl-list").addEventListener("click", function (e) { var r = e.target.closest("[data-i]"); if (r) openFee(+r.dataset.i, r); });
    built = true;
  }
  function waitingRow(w, i) {
    return '<button type="button" class="cm-row" data-i="' + i + '"><span class="cm-main"><span class="cm-name">' + esc(LC.title(w)) + '</span>' +
      '<span class="cm-sub warn">' + esc(LC.rowSub(w)) + '</span></span><span class="cm-chip warn">To decide</span>' +
      '<span class="cm-amt">' + esc(CM.money(w.fee_cents)) + '</span>' + UI.chev() + '</button>';
  }
  function recentRow(r) {
    var c = LC.recentChip(r);
    return '<div class="cm-row cm-static"><span class="cm-main"><span class="cm-name">' + esc((r.invoice_number || "Invoice") + " · " + (r.name || "Family")) + '</span>' +
      '<span class="cm-sub">' + esc(LC.recentLine(r)) + '</span></span><span class="cm-chip ' + c.tone + '">' + esc(c.text) + '</span><span class="cm-amt">' + esc(CM.money(r.fee_cents)) + '</span></div>';
  }
  function draw() {
    var n = list.waiting_count || 0;
    $("cl-sum").innerHTML = '<div class="cm-sum-t">Late fees</div><div class="cm-sum-s">' + esc(LC.summary(list)) + '</div>' +
      (list.note ? '<p class="cm-note">' + esc(list.note) + '</p>' : '') +
      (n > 1 ? '<div class="cm-acts"><button type="button" class="btn btn-primary" id="cl-all">Approve all ' + n + '</button></div>' : '') +
      '<p class="cm-note">TutorDeck suggests a late fee the day after an invoice’s grace period ends. Nothing reaches a family until you approve it. Each approved fee is its own invoice.</p>';
    var wl = list.waiting || [], rl = list.recent || [];
    var h = '<section class="cm-sec"><h2 class="cm-h">Late fees waiting for you <span class="cm-n">' + wl.length + '</span></h2>' +
      (wl.length ? '<div class="card cm-list">' + wl.map(waitingRow).join("") + '</div>' : '<div class="card cm-block"><p class="cm-note">' + esc(LC.emptyText(list)) + '</p></div>') + '</section>';
    if (rl.length) h += '<section class="cm-sec"><h2 class="cm-h">Decided <span class="cm-n">' + rl.length + '</span></h2><div class="card cm-list">' + rl.map(recentRow).join("") + '</div></section>';
    $("cl-list").innerHTML = h;
  }
  async function load(msg) {
    var mine = ++seq;
    var r = await rpc("centre_late_fee_list", { p_org: orgId });
    if (mine !== seq) return;
    if (r.error) return fail(r.error);
    if (!r.data || typeof r.data !== "object") { $("cm-late").innerHTML = '<div class="card cm-block"><h2 class="cm-h2">Couldn’t load late fees</h2><p class="cm-note">Refresh the page and try again.</p></div>'; return; }
    list = r.data; draw();
    if (msg) UI.say(msg, false);
  }
  function fail(err) {
    if (LC.isMissing(err)) { $("cm-late").innerHTML = '<div class="card cm-block"><h2 class="cm-h2">Not switched on yet</h2><p class="cm-note">Late fees need <b>db/migration_centre_late_fees.sql</b> run first.</p></div>'; return; }
    var m = (err && err.message) || "";
    if (/NOT_FOUND/.test(m)) { $("cm-late").innerHTML = '<div class="card cm-block"><h2 class="cm-h2">Centre not available</h2><p class="cm-note">This centre doesn’t exist, or you aren’t an owner or staff member there.</p></div>'; return; }
    if (/NOT_ALLOWED/.test(m) && !list) { $("cm-late").innerHTML = '<div class="card cm-block"><h2 class="cm-h2">Late fees aren’t switched on for your account</h2><p class="cm-note">Ask the centre owner to give you the “Issue invoices” permission.</p></div>'; return; }
    UI.say(LC.errorText(err), true);
  }
  function show() {
    UI = window.CentreMoneyUI; orgId = UI.orgId();
    if (!built) frame();
    load();
  }

  // ---------------------------------------------------------------- one waiting fee
  function openFee(i, trigger, msg) {
    var w = (list.waiting || [])[i]; if (!w) return;
    cur = w;
    $("cm-st").textContent = LC.title(w); $("cm-sm").textContent = "Late fee · month " + w.month_no;
    var can = list.can || {}, hint = LC.waiveHint(list);
    $("cm-sb").innerHTML = '<div class="cm-msg" id="cl-msg" role="status" aria-live="polite"></div>' +
      '<div class="cm-tot"><div class="big"><span>Late fee</span><span>' + esc(CM.money(w.total_cents)) + '</span></div></div>' +
      '<p class="cm-note">' + esc(LC.amountLine(w)) + '. ' + esc(LC.basisText(w)) + '</p>' +
      '<div class="cm-facts"><div><span>Invoice</span><span>' + esc(w.invoice_number) + ' · ' + esc(CM.money(w.invoice_total_cents)) + '</span></div>' +
      '<div><span>Due</span><span>' + esc(CM.shortDate(w.invoice_due_date)) + '</span></div>' +
      '<div><span>Still unpaid</span><span>' + esc(CM.money(w.balance_cents)) + '</span></div>' +
      '<div><span>Fell due</span><span>' + esc(CM.shortDate(w.fee_date)) + '</span></div></div>' +
      '<div class="cm-acts col"><button type="button" class="btn btn-primary" id="cl-ap">Approve and add to the account</button>' +
      '<button type="button" class="btn quiet" id="cl-wv"' + (can.waive ? '' : ' disabled') + '>Waive this late fee</button></div>' +
      (hint ? '<p class="cm-note">' + esc(hint) + '</p>' : '') +
      '<p class="cm-note">Approving makes its own invoice with its own number; the family pays it like any invoice. Waiving needs a reason and is kept in the record.</p>';
    if (trigger !== true) UI.openSheet(trigger);
    $("cl-ap").addEventListener("click", approveOne); $("cl-wv").addEventListener("click", waiveOne);
    if (msg) sheetMsg(msg.text, msg.bad);
  }
  async function approveOne() {
    if (busy || !cur) return;
    var q = LC.approveQuestion(cur);
    if (!(await TL.confirm(q))) return;
    busy = true; var id = cur.id; var r = await rpc("centre_late_fee_approve", { p_fee: id }); busy = false;
    if (r.error) return sheetMsg(LC.errorText(r.error), true);
    var t = LC.approvedText(r.data); toast(t); UI.closeSheet(); await load(t); afterMoney();
  }
  async function waiveOne() {
    if (busy || !cur) return;
    var why = await TL.prompt({ title: "Waive this late fee?", message: "The family won’t be charged it. Say why (kept in the record).", placeholder: "Reason", confirmText: "Waive the fee", danger: true });
    if (why == null) return;
    var c = LC.checkWaive(why);
    if (!c.ok) return sheetMsg(c.error, true);
    busy = true; var id = cur.id; var r = await rpc("centre_late_fee_waive", { p_fee: id, p_reason: c.reason }); busy = false;
    if (r.error) return sheetMsg(LC.errorText(r.error), true);
    var t = LC.waivedText(r.data); toast(t); UI.closeSheet(); await load(t);
  }
  async function approveAll() {
    if (busy || !list || !list.waiting_count) return;
    if (!(await TL.confirm(LC.approveAllQuestion(list)))) return;
    busy = true; var b = $("cl-all"); if (b) b.disabled = true;
    var r = await rpc("centre_late_fee_approve_all", { p_org: orgId }); busy = false;
    if (r.error) { if (b) b.disabled = false; return UI.say(LC.errorText(r.error), true); }
    var t = LC.approvedAllText(r.data); toast(t); await load(t); afterMoney();
  }
  // an approved fee is a new invoice: the Invoices tab shows it
  function afterMoney() { if (window.CentrePay && window.CentrePay.refresh) window.CentrePay.refresh(); }

  window.CentreLateFees = { show: show, refresh: function () { return built ? load() : null; } };
})();
