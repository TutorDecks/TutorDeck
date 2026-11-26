// Centre Money > Invoice run (T4 step S2): choose a month, see who is ready and who is held back (and why), create the drafts, look at one, approve
// one or all. Every read and write goes through database functions (centre_invoice_run_preview, _create_drafts, centre_invoice_list, _get,
// _approve, _approve_all, _discard_draft, _numbering); this page never touches a table. Who may, what is billed and the numbers are decided there
// (db/migration_centre_invoice_run.sql); assets/js/centre-money-core.js only words the answers and saves a round trip.
//   centre-money?id=<centre>[&month=yyyy-mm][&tab=invoices|deposits|refunds|latefees]
// S3 adds a second tab, Invoices & payments (assets/js/centre-payments.js): this file owns the tabs, the message line and the side sheet, and
// hands an issued invoice to window.CentrePay (record payment, credit note, reverse, share link, WhatsApp).
// S4 adds a third tab, Deposits (assets/js/centre-deposits.js, window.CentreDeposits), and a "Refundable deposits" section in the run's preview.
// S5 adds a fourth tab, Refunds (assets/js/centre-refunds.js, window.CentreRefunds): deposit refunds, family-credit refunds and using credit on an invoice.
// S6 adds a fifth tab, Late fees (assets/js/centre-late-fees.js, window.CentreLateFees): "Late fees waiting for you" to approve or waive.
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var esc = function (s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var CM = window.CentreMoneyCore, CD = window.CentreDepositsCore;
  var orgId = null, month = null, today = "", seq = 0, busy = false, sheetOpener = null, prev = null, invs = [], numb = null, urlMonth = false, tab = "run", ranRun = false;

  function card(inner) { $("cm-body").innerHTML = '<div class="card cm-block">' + inner + '</div>'; $("cm-num").innerHTML = ""; }
  function say(text, bad) { var m = $("cm-msg"); m.textContent = text || ""; m.className = "cm-msg" + (text ? (bad ? " err" : " ok") : ""); }
  function localToday() { var d = new Date(); return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10); }
  function link(path, extra) { return path + "?id=" + encodeURIComponent(orgId) + (extra || ""); }

  // ---------------------------------------------------------------- the page
  function nav() {
    $("cm-when").textContent = CM.monthLabel(month);
    $("cm-prev").disabled = busy; $("cm-next").disabled = busy;
  }
  function chipHtml(c) { return '<span class="cm-chip ' + c.tone + '">' + esc(c.text) + '</span>'; }
  function chev() { return '<svg class="cm-chev" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="m9 18 6-6-6-6"/></svg>'; }

  function heldHtml(p) {
    var h = p.held_back || [];
    if (!h.length) return "";
    return '<section class="cm-sec" aria-labelledby="cm-h-held"><h2 class="cm-h" id="cm-h-held">Held back <span class="cm-n">' + h.length + '</span></h2>' +
      '<p class="cm-note">These are not invoiced yet. Everyone else is.</p>' +
      '<div class="card cm-list">' + h.map(function (x) {
        return '<div class="cm-row held"><span class="cm-main"><span class="cm-name">' + esc(x.name) + '</span>' +
          (x.reasons || []).map(function (r) { return '<span class="cm-sub warn">' + esc(r.reason) + (r.lessons > 1 ? ' (' + r.lessons + ' lessons)' : '') + '</span>'; }).join("") +
          (x.not_marked ? '<span class="cm-sub">' + esc(CM.notMarkedNote(x.not_marked)) + '</span>' : '') + '</span>' +
          '<a class="btn cm-act" href="' + esc(link("centre-attendance", "&tab=charges")) + '">Set the charge</a></div>';
      }).join("") + '</div></section>';
  }
  function readyHtml(p) {
    var r = p.ready || [];
    if (!r.length) return "";
    return '<section class="cm-sec" aria-labelledby="cm-h-ready"><h2 class="cm-h" id="cm-h-ready">Ready to invoice <span class="cm-n">' + r.length + '</span></h2>' +
      '<div class="card cm-list">' + r.map(function (x, i) {
        var sub = x.lessons + ' ' + CM.plural(x.lessons, "lesson", "lessons") + (x.free_trials ? ' · ' + x.free_trials + ' free ' + CM.plural(x.free_trials, "trial", "trials") : '');
        return '<button type="button" class="cm-row" data-ready="' + i + '"><span class="cm-main"><span class="cm-name">' + esc(x.name) + '</span>' +
          '<span class="cm-sub">' + esc(sub) + '</span>' + (x.not_marked ? '<span class="cm-sub warn">' + esc(CM.notMarkedNote(x.not_marked)) + '</span>' : '') + '</span>' +
          '<span class="cm-amt">' + esc(CM.money(x.total_cents)) + '</span>' + chev() + '</button>';
      }).join("") + '</div></section>';
  }
  function depositsHtml(p) {
    var d = p.deposits || [], note = CD.runDepositNote(p);
    if (!d.length && !note) return "";
    return '<section class="cm-sec" aria-labelledby="cm-h-dep"><h2 class="cm-h" id="cm-h-dep">Refundable deposits' + (d.length ? ' <span class="cm-n">' + d.length + '</span>' : '') + '</h2>' +
      (note ? '<p class="cm-note err">' + esc(note) + '</p>' : '<p class="cm-note">Each one is its own invoice, raised once with the student’s first invoice. The money is held for the family, not counted as income.</p>') +
      (d.length ? '<div class="card cm-list">' + d.map(function (x) {
        return '<div class="cm-row"><span class="cm-main"><span class="cm-name">' + esc(x.name) + '</span><span class="cm-sub">' + esc(CD.previewLine(x)) + (x.taxable ? ' · taxable' : '') + '</span></span>' +
          '<span class="cm-amt">' + esc(CM.money(x.amount_cents)) + '</span></div>';
      }).join("") + '</div>' : '') + '</section>';
  }
  function invoicesHtml() {
    if (!invs.length) return "";
    return '<section class="cm-sec" aria-labelledby="cm-h-inv"><h2 class="cm-h" id="cm-h-inv">Invoices for ' + esc(CM.monthLabel(month)) + ' <span class="cm-n">' + invs.length + '</span></h2>' +
      '<div class="card cm-list">' + invs.map(function (x, i) {
        return '<button type="button" class="cm-row' + (x.status === "void" ? ' off' : '') + '" data-inv="' + i + '"><span class="cm-main"><span class="cm-name">' +
          (x.number ? '<span class="cm-no">' + esc(x.number) + '</span> ' : '') + esc(x.name) + (x.kind === "deposit" ? '<span class="cm-tag">Refundable deposit</span>' : '') + '</span><span class="cm-sub">' + esc(CM.invoiceSub(x)) + '</span></span>' +
          chipHtml(CM.chip(x)) + '<span class="cm-amt">' + esc(CM.money(x.total_cents)) + '</span>' + chev() + '</button>';
      }).join("") + '</div></section>';
  }
  function summaryHtml(p) {
    var step = CM.nextStep(p, invs), second = CM.secondStep(p, invs), t = p.totals || {};
    var head = invs.some(function (i) { return i.status === "draft"; }) || t.ready || t.held_back || t.drafts ? CM.summaryText(p) : "";
    var tot = CM.totalText(p);
    var empty = !t.ready && !t.held_back && !t.drafts && !invs.length;
    return '<div class="card cm-sum">' +
      '<div class="cm-sum-t">' + (empty ? 'Nothing to invoice for ' + esc(CM.monthLabel(month)) : esc(head || "All done for " + CM.monthLabel(month))) + '</div>' +
      (tot ? '<div class="cm-sum-s">' + esc(tot) + '</div>' : '') +
      (empty ? '<p class="cm-note">No lessons in this month need an invoice. If lessons were held, mark them in Attendance first.</p>' : '') +
      (p.review_before_sending === false && step.kind === "create" ? '<p class="cm-note">This centre issues invoices straight away (no review step).</p>' : '') +
      ((step.kind || second.kind) ? '<div class="cm-acts">' +
        (step.kind ? '<button type="button" class="btn btn-primary" id="cm-go" data-kind="' + step.kind + '">' + esc(step.label) + '</button>' : '') +
        (second.kind ? '<button type="button" class="btn" id="cm-go2" data-kind="' + second.kind + '">' + esc(second.label) + '</button>' : '') + '</div>' : '') +
      '</div>';
  }
  function numberingHtml() {
    if (!numb) return "";
    return '<p class="cm-foot">' + esc(CM.numberingText(numb)) + (numb.can_set && !numb.locked ? ' <button type="button" class="cm-link" id="cm-opening">Change the first number</button>' : '') + '</p>';
  }
  function draw() {
    nav();
    var p = prev;
    if (!p.built) {
      $("cm-ctx").textContent = CM.modelLabel(p);
      $("cm-body").innerHTML = '<div class="card cm-block"><h2 class="cm-h2">Not available yet</h2><p class="cm-note">' + esc(p.message) + '</p>' +
        '<p class="cm-note">Your billing model is set in Centre settings.</p><a class="btn" href="' + esc("org?id=" + encodeURIComponent(orgId)) + '">Open Centre settings</a></div>' + invoicesHtml();
    } else {
      $("cm-ctx").textContent = CM.modelLabel(p) + " · " + CM.groupingLabel(p) + " · due " + p.due_days + " days after issue";
      $("cm-body").innerHTML = summaryHtml(p) + heldHtml(p) + readyHtml(p) + depositsHtml(p) + invoicesHtml();
    }
    $("cm-num").innerHTML = numberingHtml();
  }

  // ---------------------------------------------------------------- loading
  function failure(err) {
    if (CM.isMissing(err)) return card('<h2 class="cm-h2">Not switched on yet</h2><p class="cm-note">Money needs <b>db/migration_centre_invoice_run.sql</b> run first.</p>');
    var m = (err && err.message) || "";
    if (/NOT_FOUND/.test(m) && !prev) return card('<h2 class="cm-h2">Centre not available</h2><p class="cm-note">This centre doesn’t exist, or you aren’t an owner or staff member there.</p>');
    if (/NOT_ALLOWED/.test(m) && !prev) {
      if (window.CentrePay && !failure.tried) { failure.tried = true; return setTab("inv"); }            // someone who only records payments lands on the payments tab
      return card('<h2 class="cm-h2">Money isn’t switched on for your account</h2><p class="cm-note">Ask the centre owner to give you the “Issue invoices” or “Record payments” permission.</p>');
    }
    say(CM.errorText(err), true);
  }
  async function load(keepMsg) {
    var mine = ++seq;
    if (!keepMsg) say("");
    nav();
    var pv = await window.sb.rpc("centre_invoice_run_preview", { p_org: orgId, p_period: month });
    if (mine !== seq) return;
    if (pv.error) { prev = null; return failure(pv.error); }
    if (!pv.data || typeof pv.data !== "object" || !pv.data.totals) { prev = null; return card('<h2 class="cm-h2">Couldn’t load the invoice run</h2><p class="cm-note">Refresh the page and try again.</p>'); }
    var ls = await window.sb.rpc("centre_invoice_list", { p_org: orgId, p_period: month, p_status: null });
    var nb = await window.sb.rpc("centre_invoice_numbering", { p_org: orgId });
    if (mine !== seq) return;
    if (ls.error) return failure(ls.error);
    if (!urlMonth && pv.data.model === "fixed_in_advance" && !load.switched) {              // a fixed fee billed in advance: the coming month is the one to invoice
      load.switched = true; var nm = CM.defaultMonth(pv.data.today || localToday(), "fixed_in_advance"); if (nm !== month) { month = nm; return load(); }
    }
    prev = pv.data; today = pv.data.today; invs = (ls.data && ls.data.rows) || []; numb = nb.error ? null : nb.data;
    draw(); syncUrl();
  }
  function syncUrl() { try { history.replaceState(null, "", location.pathname + "?" + (tab === "inv" ? "id=" + encodeURIComponent(orgId) + "&tab=invoices" : tab === "dep" ? "id=" + encodeURIComponent(orgId) + "&tab=deposits" : tab === "ref" ? "id=" + encodeURIComponent(orgId) + "&tab=refunds" : tab === "late" ? "id=" + encodeURIComponent(orgId) + "&tab=latefees" : CM.toQuery(orgId, month))); } catch (e) {} }

  // ---------------------------------------------------------------- actions
  async function act(fn) {
    if (busy) return; busy = true; document.querySelectorAll("#cm-run button").forEach(function (b) { b.disabled = true; });      // only the run panel: the tabs stay usable (they were left disabled after an action)
    try { await fn(); } finally { busy = false; await load(true); }
  }
  function create() {
    return act(async function () {
      var r = await window.sb.rpc("centre_invoice_run_create_drafts", { p_org: orgId, p_period: month });
      if (r.error) return say(CM.errorText(r.error), true);
      say(CM.createdText(r.data), false);
    });
  }
  async function approveAll() {
    var drafts = invs.filter(function (i) { return i.status === "draft"; });
    var q = CM.approveQuestion(drafts.length, drafts.reduce(function (a, d) { return a + d.total_cents; }, 0));
    if (!(await TL.confirm({ title: q.title, message: q.message, confirmText: "Issue " + drafts.length + (drafts.length === 1 ? " invoice" : " invoices") }))) return;
    return act(async function () {
      var r = await window.sb.rpc("centre_invoice_approve_all", { p_org: orgId, p_period: month });
      if (r.error) return say(CM.errorText(r.error), true);
      say(CM.approvedText(r.data), false);
    });
  }
  async function approveOne(id, label) {
    if (!(await TL.confirm({ title: "Issue " + label + "?", message: "It gets its number now and can’t be changed afterwards. A mistake is corrected with a credit note.", confirmText: "Issue invoice" }))) return;
    closeSheet();
    return act(async function () {
      var r = await window.sb.rpc("centre_invoice_approve", { p_invoice: id });
      if (r.error) return say(CM.errorText(r.error), true);
      say(CM.approvedText(r.data), false);
    });
  }
  async function discardOne(id, label) {
    var why = await TL.prompt({ title: "Discard the draft for " + label + "?", message: "Its lessons become ready to invoice again. Say why (kept in the record).", placeholder: "Reason", confirmText: "Discard draft", danger: true });
    if (!why) return;
    closeSheet();
    return act(async function () {
      var r = await window.sb.rpc("centre_invoice_discard_draft", { p_invoice: id, p_reason: why });
      if (r.error) return say(CM.errorText(r.error), true);
      say("Draft discarded. Its lessons are ready to invoice again.", false);
    });
  }
  async function setOpening() {
    var v = await TL.prompt({ title: "First invoice number", message: "The number the first invoice will get (for example 1000 if you are moving over from another system). It can’t be changed once an invoice is issued.", placeholder: "1", confirmText: "Save" });
    if (v == null) return;
    var n = CM.parseOpening(v);
    if (!n) return say("Type a whole number from 1.", true);
    return act(async function () {
      var r = await window.sb.rpc("centre_set_opening_number", { p_org: orgId, p_series: "invoice", p_next: n });
      if (r.error) return say(CM.errorText(r.error), true);
      say("The first invoice number is now " + n + ".", false);
    });
  }

  // ---------------------------------------------------------------- the sheet
  function lockBody(on) { document.body.classList.toggle("sheet-lock", on); }
  function openSheet(trigger) { sheetOpener = trigger || sheetOpener; $("cm-sheet").classList.add("on"); lockBody(true); $("cm-sx").focus(); }
  function closeSheet() { $("cm-sheet").classList.remove("on"); lockBody(false); setTimeout(function () { if (!$("cm-sheet").classList.contains("on")) $("cm-sb").innerHTML = ""; }, 300); if (sheetOpener && sheetOpener.focus && document.contains(sheetOpener)) sheetOpener.focus(); sheetOpener = null; }
  function linesHtml(lines) {
    return CM.groupLines(lines).map(function (g) {
      return '<div class="cm-g"><div class="cm-gh">' + esc(g.student) + '</div>' + g.lines.map(function (l) {
        var q = CM.qtyText(l), neg = CM.lineAmount(l) < 0;
        return '<div class="cm-ln"><span class="cm-ld">' + esc(l.description) + (q ? '<span class="cm-sub"> ' + esc(q) + '</span>' : '') + '</span><span class="cm-la' + (neg ? ' neg' : '') + '">' + esc(CM.money(CM.lineAmount(l))) + '</span></div>';
      }).join("") + '</div>';
    }).join("");
  }
  function totalsHtml(net, gst, total, registered) {
    return '<div class="cm-tot">' + (registered || gst ? '<div><span>Subtotal</span><span>' + esc(CM.money(net)) + '</span></div><div><span>GST</span><span>' + esc(CM.money(gst)) + '</span></div>' : '') +
           '<div class="big"><span>Total</span><span>' + esc(CM.money(total)) + '</span></div></div>';
  }
  function showReady(i, trigger) {
    var x = (prev.ready || [])[i]; if (!x) return;
    $("cm-st").textContent = x.name; $("cm-sm").textContent = "Ready · " + CM.monthLabel(month);
    $("cm-sb").innerHTML = linesHtml(x.lines) + totalsHtml(x.subtotal_cents, x.gst_cents, x.total_cents, x.gst_cents > 0 || x.net_cents !== x.total_cents) +
      '<p class="cm-note">This is a preview. Use “Create” on the page to make the draft.</p>';
    openSheet(trigger);
  }
  async function showInvoice(i, trigger) {
    var x = invs[i]; if (!x) return;
    if (x.status === "issued" && window.CentrePay) return window.CentrePay.open(x.id, trigger);               // an issued invoice has an account: payments, credit notes, link
    $("cm-st").textContent = x.name; $("cm-sm").textContent = (x.number ? x.number + " · " : "") + CM.chip(x).text;
    $("cm-sb").innerHTML = '<p class="cm-note">Loading…</p>'; openSheet(trigger);
    var r = await window.sb.rpc("centre_invoice_get", { p_invoice: x.id });
    if (r.error) { $("cm-sb").innerHTML = '<p class="cm-note err">' + esc(CM.errorText(r.error)) + '</p>'; return; }
    var d = r.data;
    $("cm-sb").innerHTML = linesHtml(d.lines) + totalsHtml(d.net_cents, d.gst_cents, d.total_cents, d.gst_registered) +
      (d.status === "issued" ? '<div class="cm-facts"><div><span>Issued</span><span>' + esc(CM.shortDate(d.issue_date)) + '</span></div><div><span>Due</span><span>' + esc(CM.shortDate(d.due_date)) + '</span></div></div><p class="cm-note">An issued invoice can’t be changed. A mistake is corrected with a credit note.</p>' : "") +
      (d.status === "void" ? '<p class="cm-note">Discarded: ' + esc(d.void_reason || "") + '</p>' : "") +
      (d.status === "draft" ? '<div class="cm-acts col"><button type="button" class="btn btn-primary" id="cm-ap">Approve and issue</button><button type="button" class="btn" id="cm-di">Discard this draft</button></div>' : "");
    var ap = $("cm-ap"), di = $("cm-di");
    if (ap) ap.addEventListener("click", function () { approveOne(x.id, x.name + "’s invoice"); });
    if (di) di.addEventListener("click", function () { discardOne(x.id, x.name); });
  }

  // ---------------------------------------------------------------- tabs
  var TABS = ["run", "inv", "dep", "ref", "late"];
  function setTab(name, focus) {
    tab = TABS.indexOf(name) > -1 ? name : "run";
    var run = tab === "run";
    TABS.forEach(function (t) { var on = t === tab, b = $("cm-tab-" + t); $("cm-" + t).hidden = !on; b.setAttribute("aria-selected", on ? "true" : "false"); b.tabIndex = on ? 0 : -1; });
    if (focus) $("cm-tab-" + tab).focus();
    say("");
    if (run && !ranRun) { ranRun = true; load(); } else if (run) syncUrl();
    if (tab === "inv") { if (window.CentrePay) window.CentrePay.show(); syncUrl(); }
    if (tab === "dep") { if (window.CentreDeposits) window.CentreDeposits.show(); syncUrl(); }
    if (tab === "ref") { if (window.CentreRefunds) window.CentreRefunds.show(); syncUrl(); }
    if (tab === "late") { if (window.CentreLateFees) window.CentreLateFees.show(); syncUrl(); }
  }

  // ---------------------------------------------------------------- wiring
  function wire() {
    $("cm-tab-run").addEventListener("click", function () { setTab("run"); });
    $("cm-tab-inv").addEventListener("click", function () { setTab("inv"); });
    $("cm-tab-dep").addEventListener("click", function () { setTab("dep"); });
    $("cm-tab-ref").addEventListener("click", function () { setTab("ref"); });
    $("cm-tab-late").addEventListener("click", function () { setTab("late"); });
    $("cm").querySelector(".cm-tabs").addEventListener("keydown", function (e) {
      if (e.key === "ArrowRight" || e.key === "ArrowLeft") { e.preventDefault(); setTab(TABS[(TABS.indexOf(tab) + (e.key === "ArrowRight" ? 1 : TABS.length - 1)) % TABS.length], true); }
    });
    $("cm-prev").addEventListener("click", function () { month = CM.shiftMonth(month, -1); urlMonth = true; load(); });
    $("cm-next").addEventListener("click", function () { month = CM.shiftMonth(month, 1); urlMonth = true; load(); });
    $("cm-body").addEventListener("click", function (e) {
      var r = e.target.closest("[data-ready]"), v = e.target.closest("[data-inv]"), g = e.target.closest("#cm-go,#cm-go2");
      if (r) return showReady(+r.dataset.ready, r);
      if (v) return showInvoice(+v.dataset.inv, v);
      if (g) return g.dataset.kind === "create" ? create() : approveAll();
    });
    $("cm-num").addEventListener("click", function (e) { if (e.target.id === "cm-opening") setOpening(); });
    $("cm-sx").addEventListener("click", closeSheet);
    $("cm-sheet").addEventListener("click", function (e) { if (e.target === $("cm-sheet")) closeSheet(); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && $("cm-sheet").classList.contains("on") && !document.querySelector(".td-dlg")) closeSheet(); });
  }

  function init() {
    var q = new URLSearchParams(location.search), id = q.get("id"), o = TL.org ? TL.org() : null;
    if (!id) id = o && o.kind === "centre" ? o.id : null;
    if (!id) { location.replace("home"); return; }                                                     // a solo login has no centre pages
    if (o && o.kind === "centre" && o.id === id && o.role === "tutor") { location.replace("tutor"); return; }
    orgId = id;
    var st = CM.fromQuery(location.search); urlMonth = !!st.month;
    month = st.month || CM.defaultMonth(localToday(), "postpaid_lessons");
    tab = q.get("tab") === "invoices" ? "inv" : q.get("tab") === "deposits" ? "dep" : q.get("tab") === "refunds" ? "ref" : q.get("tab") === "latefees" ? "late" : "run";
    wire(); nav();
    setTab(tab);
  }
  // what the Invoices tab (assets/js/centre-payments.js) shares with this page: the side sheet, the message line, the run's own refresh
  window.CentreMoneyUI = {
    orgId: function () { return orgId; }, openSheet: function (t) { openSheet(t); }, closeSheet: closeSheet, say: say, esc: esc, chev: chev, chipHtml: chipHtml,
    linesHtml: function (l) { return linesHtml(l); }, totalsHtml: function (a, b, c, d) { return totalsHtml(a, b, c, d); }, localToday: localToday,
    refreshRun: function () { if (ranRun) return load(true); }
  };
  // the Invoices tab script (centre-payments.js) loads after this one: start once every script has loaded
  TL.requireAuth("centre-money", function () { if (document.readyState === "complete") init(); else window.addEventListener("load", init); });
})();
