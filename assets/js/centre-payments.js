// Centre Money > Invoices & payments (T4 step S3): every issued invoice with its status (issued / part-paid / paid / overdue / void), filters, and one
// invoice's account in the side sheet: record a payment, issue a credit note, reverse a payment, copy the secret link, send it on WhatsApp.
// Every read and write goes through database functions (centre_invoice_account_list / _get, centre_record_payment, centre_reverse_payment,
// centre_issue_credit_note, centre_invoice_share_link, centre_invoice_whatsapp); this page never touches a table. Who may, what is allowed and every
// number are decided there (db/migration_centre_payments.sql); assets/js/centre-payments-core.js only words the answers.
// Shares the tabs, the message line and the side sheet with assets/js/centre-money.js (window.CentreMoneyUI).
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var CP = window.CentrePaymentsCore, CM = window.CentreMoneyCore, UI = null, esc = function (s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var orgId = null, filter = "all", query = "", list = null, seq = 0, built = false, cur = null, busy = false, today = "";

  function rpc(name, args) { return window.sb.rpc(name, args); }
  function chip(ps) { var c = CP.payChip(ps); return '<span class="cm-chip ' + c.tone + '">' + esc(c.text) + '</span>'; }
  function toast(text, kind) { try { TL.toast(text, kind || "ok"); } catch (e) {} }

  // ---------------------------------------------------------------- the list
  function frame() {
    $("cm-inv").innerHTML = '<div class="card cm-sum" id="cp-sum"><div class="cm-sum-s">Loading…</div></div>' +
      '<div class="cm-filters" id="cp-filters" role="group" aria-label="Show invoices"></div>' +
      '<input class="cm-search" id="cp-q" type="search" placeholder="Search by family or invoice number" aria-label="Search invoices" autocomplete="off">' +
      '<div id="cp-list" aria-live="polite"></div>';
    $("cp-filters").addEventListener("click", function (e) { var b = e.target.closest("[data-f]"); if (b && !busy) { filter = b.dataset.f; load(); } });
    $("cp-q").addEventListener("input", function (e) { query = e.target.value; drawList(); });
    $("cp-list").addEventListener("click", function (e) { var r = e.target.closest("[data-i]"); if (r) open(list.rows[+r.dataset.i].id, r); });
    built = true;
  }
  function drawFilters() {
    $("cp-filters").innerHTML = CP.filterChips(list.counts, filter).map(function (f) {
      return '<button type="button" class="cm-f" data-f="' + f.key + '" aria-pressed="' + f.active + '">' + esc(f.label) + (f.count != null ? ' ' + f.count : '') + '</button>';
    }).join("");
  }
  function drawList() {
    var rows = CP.searchRows(list.rows, query);
    var more = list.counts[filter === "all" ? "all" : filter] > list.rows.length;
    $("cp-list").innerHTML = !rows.length ? '<div class="card cm-block"><p class="cm-note">' + esc(CP.emptyText(filter, !!query.trim())) + '</p></div>' :
      '<div class="card cm-list">' + rows.map(function (x) {
        var i = list.rows.indexOf(x);
        return '<button type="button" class="cm-row" data-i="' + i + '"><span class="cm-main"><span class="cm-name"><span class="cm-no">' + esc(x.number) + '</span> ' + esc(x.name) + (x.kind === "deposit" ? '<span class="cm-tag">Refundable deposit</span>' : x.kind === "late_fee" ? '<span class="cm-tag">Late fee</span>' : '') + '</span>' +
          '<span class="cm-sub' + (x.pay_status === "overdue" ? ' warn' : '') + '">' + esc(CP.rowSub(x, today)) + '</span></span>' + chip(x.pay_status) +
          '<span class="cm-amt">' + esc(CM.money(CP.rowAmount(x))) + '</span>' + UI.chev() + '</button>';
      }).join("") + '</div>' + (more ? '<p class="cm-foot">Showing the newest ' + list.rows.length + '. Use the filters or search to find older ones.</p>' : '');
  }
  async function load() {
    var mine = ++seq;
    var r = await rpc("centre_invoice_account_list", { p_org: orgId, p_period: null, p_filter: filter === "all" ? null : filter });
    if (mine !== seq) return;
    if (r.error) return fail(r.error);
    list = r.data; today = list.today;
    $("cp-sum").innerHTML = '<div class="cm-sum-t">' + esc(list.counts.all ? CP.summaryLine(list) : "No invoices issued yet") + '</div>' +
      (list.counts.all ? '<div class="cm-sum-s">' + list.counts.all + ' issued · ' + list.counts.paid + ' paid</div>' : '<div class="cm-sum-s">Invoices appear here once you issue them on the Invoice run tab.</div>');
    drawFilters(); drawList();
  }
  function fail(err) {
    if (CP.isMissing(err)) { $("cm-inv").innerHTML = '<div class="card cm-block"><h2 class="cm-h2">Not switched on yet</h2><p class="cm-note">Payments need <b>db/migration_centre_payments.sql</b> run first.</p></div>'; return; }
    var m = (err && err.message) || "";
    if (/NOT_FOUND/.test(m)) { $("cm-inv").innerHTML = '<div class="card cm-block"><h2 class="cm-h2">Centre not available</h2><p class="cm-note">This centre doesn’t exist, or you aren’t an owner or staff member there.</p></div>'; return; }
    if (/NOT_ALLOWED/.test(m) && !list) { $("cm-inv").innerHTML = '<div class="card cm-block"><h2 class="cm-h2">Money isn’t switched on for your account</h2><p class="cm-note">Ask the centre owner to give you the “Issue invoices” or “Record payments” permission.</p></div>'; return; }
    UI.say(CP.errorText(err), true);
  }
  function show() {
    UI = window.CentreMoneyUI; orgId = UI.orgId();
    if (!built) frame();
    load();
  }

  // ---------------------------------------------------------------- one invoice
  function sheetMsg(text, bad) { var m = $("cp-msg"); if (!m) return; m.textContent = text || ""; m.className = "cm-msg" + (text ? (bad ? " err" : " ok") : ""); }
  async function open(id, trigger, msg) {
    $("cm-st").textContent = "Invoice"; $("cm-sm").textContent = "";
    if (trigger !== true) { $("cm-sb").innerHTML = '<p class="cm-note">Loading…</p>'; UI.openSheet(trigger); }
    var r = await rpc("centre_invoice_account_get", { p_invoice: id });
    if (r.error) { $("cm-sb").innerHTML = '<p class="cm-note err">' + esc(CP.errorText(r.error)) + '</p>'; return; }
    cur = r.data; today = cur.today || today;
    // credit / deposit that was used on this invoice, with Undo (db/migration_centre_credit_undo.sql). If that migration isn't there yet, the sheet is as it was.
    cur.apps = null;
    var ap = await rpc("centre_invoice_applications", { p_invoice: id });
    if (!ap.error && ap.data && Array.isArray(ap.data.rows)) { cur.apps = ap.data.rows; cur.appsRole = !!ap.data.can_undo_role; }
    renderDetail(msg);
  }
  function groupHtml(title, inner) { return '<div class="cm-g"><div class="cm-gh">' + esc(title) + '</div>' + inner + '</div>'; }
  function renderDetail(msg) {
    var a = cur, can = a.can || {}, rules = a.rules || {};
    $("cm-st").textContent = a.name; $("cm-sm").textContent = a.number + " · " + CP.payChip(a.pay_status).text;
    var h = '<div class="cm-msg" id="cp-msg" role="status" aria-live="polite"></div>';
    h += UI.linesHtml(a.lines) + UI.totalsHtml(a.net_cents, a.gst_cents, a.total_cents, a.gst_registered);
    h += '<div class="cm-tot">' + CP.amountsRows(a).slice(1).map(function (r, i, all) {
      return '<div' + (i === all.length - 1 ? ' class="big"' : '') + '><span>' + esc(r[0]) + '</span><span>' + esc(CM.money(r[1])) + '</span></div>'; }).join("") + '</div>';
    h += '<div class="cm-facts"><div><span>Issued</span><span>' + esc(CM.shortDate(a.issue_date)) + '</span></div><div><span>Due</span><span>' + esc(CM.shortDate(a.due_date)) + '</span></div></div>';
    if (a.credit_balance_cents > 0) h += '<p class="cm-credit">' + esc(CP.creditLine(a.credit_balance_cents)) + '</p>';
    var internal = function (p) { return a.apps && (p.method === "family_credit" || p.method === "deposit"); };     // shown below as "Credit and deposit used"
    if ((a.payments || []).some(function (p) { return !internal(p); })) {
      h += groupHtml("Payments", a.payments.map(function (p, i) {
        if (internal(p)) return "";
        var isRev = p.kind === "reversal";
        return '<div class="cm-pay' + (p.reversed ? ' off' : '') + '"><span class="cm-ld">' + esc(CP.paymentLine(p)) + (p.reversed ? '<span class="cm-tag">Reversed</span>' : '') + '</span>' +
          '<span class="cm-la">' + esc(CM.money(p.cents)) + '</span>' +
          (can.record_payments && !isRev && !p.reversed ? '<button type="button" class="cm-link" data-rev="' + i + '">Reverse</button>' : '') + '</div>';
      }).join(""));
    }
    if ((a.apps || []).length) {
      h += groupHtml("Credit and deposit used", a.apps.map(function (x) {
        var note = window.CentreRefundsCore.undoNote(x, a.appsRole);
        return '<div class="cm-pay' + (x.state === "undone" ? ' off' : '') + '"><span class="cm-ld"><b>' + esc(window.CentreRefundsCore.undoTitle(x)) + '</b>' + (x.state === "undone" ? '<span class="cm-tag">Undone</span>' : '') +
          '<span class="cm-sub"> ' + esc(window.CentreRefundsCore.undoRow(x)) + '</span>' + (note ? '<span class="cm-sub' + (x.state === "undone" ? '' : ' warn') + '"> ' + esc(note) + '</span>' : '') + '</span>' +
          '<span class="cm-la">' + esc(CM.money(window.CentreRefundsCore.undoAmount(x))) + '</span></div>';
      }).join(""));
    }
    if ((a.credit_notes || []).length) {
      h += groupHtml("Credit notes", a.credit_notes.map(function (n) {
        return '<div class="cm-pay"><span class="cm-ld"><b>' + esc(n.number) + '</b> · ' + esc(CM.shortDate(n.issue_date)) + '<span class="cm-sub"> ' + esc(n.reason || "") + '</span></span><span class="cm-la neg">' + esc(CM.money(-n.total_cents)) + '</span></div>';
      }).join(""));
    }
    var acts = '';
    if (can.record_payments && a.balance_cents > 0) acts += '<button type="button" class="btn btn-primary" id="cp-pay">Record payment</button>';
    if (can.issue_invoices && CP.creditLeft(a) > 0) acts += '<button type="button" class="btn" id="cp-credit">Issue credit note</button>';
    if (can.record_payments && a.credit_balance_cents > 0 && a.household_id && window.CentreRefunds) acts += '<button type="button" class="btn" id="cp-famcredit">Use or refund the family’s credit</button>';
    if (a.appsRole && (a.apps || []).some(function (x) { return x.state === "active"; }) && window.CentreRefunds) acts += '<button type="button" class="btn" id="cp-undo">Undo credit or deposit used</button>';
    if (can.issue_invoices && rules.share_link) {
      acts += '<button type="button" class="btn" id="cp-copy">Copy link</button>';
      if (a.balance_cents > 0) acts += '<button type="button" class="btn" id="cp-wa">Send on WhatsApp</button>';
      if (a.balance_cents > 0 && a.household_id && window.CentreEmail && window.CentreEmail.on()) acts += '<button type="button" class="btn" id="cp-email">Email invoice</button>';
      if (a.share) acts += '<button type="button" class="btn quiet" id="cp-newlink">Make a new link</button>';
    }
    h += acts ? '<div class="cm-acts col">' + acts + '</div>' : '';
    h += '<p class="cm-note">An issued invoice can’t be changed. A mistake is corrected with a credit note; a wrong payment is reversed, and credit or a deposit that was used by mistake is undone, never edited.</p>';
    $("cm-sb").innerHTML = h;
    sheetMsg(msg && msg.text, msg && msg.bad);
    var b = function (id, fn) { var e = $(id); if (e) e.addEventListener("click", fn); };
    b("cp-famcredit", function () { window.CentreRefunds.creditMenu(a, null, function (m) { open(a.id, true, m); }); });
    b("cp-undo", function () { window.CentreRefunds.undoApplication(a, a.apps, function (m) { open(a.id, true, m); }); });
    b("cp-pay", payForm); b("cp-credit", creditForm); b("cp-copy", function () { copyLink(false); }); b("cp-wa", whatsapp); b("cp-email", function () { window.CentreEmail.invoiceForm(a, back, function (m) { open(a.id, true, m); }); }); b("cp-newlink", function () { copyLink(true); });
    $("cm-sb").querySelectorAll("[data-rev]").forEach(function (e) { e.addEventListener("click", function () { reverse(a.payments[+e.dataset.rev]); }); });
  }
  function back() { renderDetail(); }

  // ---------------------------------------------------------------- record a payment
  function fieldHtml(id, label, control, hint) { return '<div class="cm-fld"><label for="' + id + '">' + esc(label) + '</label>' + control + (hint || '') + '</div>'; }
  function payForm() {
    var a = cur, rules = a.rules || {}, ms = CP.METHODS.filter(function (m) { return m[0] !== "manual_paynow" || rules.manual_paynow; });
    $("cm-sm").textContent = a.number + " · Record payment";
    $("cm-sb").innerHTML = '<button type="button" class="cm-link cm-back" id="cp-back">‹ Back to the invoice</button>' +
      '<h3 class="cm-h2">Record a payment</h3><p class="cm-note">' + esc(a.name) + ' · ' + esc(CM.money(a.balance_cents)) + ' still owed.</p>' +
      '<form id="cp-form" novalidate>' +
      fieldHtml("cp-amt", "Amount received (S$)", '<input id="cp-amt" inputmode="decimal" autocomplete="off" value="' + esc((a.balance_cents / 100).toFixed(2)) + '">', '<p class="cm-hint" id="cp-amt-h" aria-live="polite"></p>') +
      fieldHtml("cp-method", "How was it paid?", '<select id="cp-method">' + ms.map(function (m) { return '<option value="' + m[0] + '">' + esc(m[1]) + '</option>'; }).join("") + '</select>') +
      fieldHtml("cp-date", "Date received", '<input id="cp-date" type="date" value="' + esc(today) + '" max="' + esc(today) + '">') +
      fieldHtml("cp-ref", "Reference (optional)", '<input id="cp-ref" maxlength="120" autocomplete="off">', '<p class="cm-hint">For example the PayNow reference. Never type a full bank account number.</p>') +
      '<p class="cm-hint err" id="cp-err" role="alert"></p>' +
      '<div class="cm-acts col"><button type="submit" class="btn btn-primary" id="cp-go">Record payment</button><button type="button" class="btn" id="cp-cancel">Cancel</button></div></form>';
    $("cp-back").addEventListener("click", back); $("cp-cancel").addEventListener("click", back);
    var check = function () {
      var c = CP.checkPayment({ amountText: $("cp-amt").value, balance: a.balance_cents, rules: rules, date: $("cp-date").value, today: today }), h = $("cp-amt-h");
      h.className = "cm-hint" + (c.ok ? (c.note ? " warn" : "") : " err"); h.textContent = c.ok ? c.note : c.error; return c;
    };
    ["input", "change"].forEach(function (ev) { $("cp-form").addEventListener(ev, check); });
    $("cp-form").addEventListener("submit", async function (e) {
      e.preventDefault(); if (busy) return;
      var c = check(); if (!c.ok) { $("cp-amt").focus(); return; }
      busy = true; $("cp-go").disabled = true; $("cp-err").textContent = "";
      var r = await rpc("centre_record_payment", { p_org: orgId, p_household: a.household_id || null, p_method: $("cp-method").value, p_amount_cents: c.cents,
        p_received_on: $("cp-date").value, p_reference: $("cp-ref").value.trim() || null, p_invoice_ids: [a.id], p_payer_name: null, p_note: null });
      busy = false;
      if (r.error) { $("cp-go").disabled = false; $("cp-err").textContent = CP.errorText(r.error); return; }
      var text = CP.paidText(r.data); toast(text); afterChange(a.id, { text: text });
    });
    $("cp-amt").focus(); $("cp-amt").select(); check();
  }

  // ---------------------------------------------------------------- credit note
  function creditForm() {
    var a = cur, left = CP.creditLeft(a);
    $("cm-sm").textContent = a.number + " · Credit note";
    $("cm-sb").innerHTML = '<button type="button" class="cm-link cm-back" id="cp-back">‹ Back to the invoice</button>' +
      '<h3 class="cm-h2">Issue a credit note</h3><p class="cm-note">' + esc(a.name) + ' · ' + esc(a.number) + '. A credit note is its own numbered document. It takes money off this invoice' + (a.gst_registered ? ' (GST is worked out for you)' : '') + '.</p>' +
      '<form id="cp-form" novalidate>' +
      fieldHtml("cp-amt", "Amount to credit (S$)", '<input id="cp-amt" inputmode="decimal" autocomplete="off">', '<p class="cm-hint" id="cp-amt-h">' + esc("At most " + CM.money(left) + (a.gst_registered ? ", GST included" : "") + ".") + '</p>') +
      fieldHtml("cp-reason", "Reason (printed on the credit note)", '<input id="cp-reason" maxlength="300" autocomplete="off">') +
      '<p class="cm-hint err" id="cp-err" role="alert"></p>' +
      '<div class="cm-acts col"><button type="submit" class="btn btn-primary" id="cp-go">Issue credit note</button><button type="button" class="btn" id="cp-cancel">Cancel</button></div></form>';
    $("cp-back").addEventListener("click", back); $("cp-cancel").addEventListener("click", back);
    $("cp-form").addEventListener("submit", async function (e) {
      e.preventDefault(); if (busy) return;
      var c = CP.checkCredit({ amountText: $("cp-amt").value, left: left, reason: $("cp-reason").value });
      if (!c.ok) { $("cp-err").textContent = c.error; return; }
      $("cp-err").textContent = "";
      var q = CP.creditQuestion(a, c);
      if (!(await TL.confirm({ title: q.title, message: q.message, confirmText: "Issue credit note" }))) return;
      busy = true; $("cp-go").disabled = true;
      var r = await rpc("centre_issue_credit_note", { p_invoice: a.id, p_amount_cents: c.cents, p_reason: c.reason, p_lines: null });
      busy = false;
      if (r.error) { $("cp-go").disabled = false; $("cp-err").textContent = CP.errorText(r.error); return; }
      var text = CP.creditNoteText(r.data); toast(text); afterChange(a.id, { text: text });
    });
    $("cp-amt").focus();
  }

  // ---------------------------------------------------------------- reverse a payment
  async function reverse(p) {
    var q = CP.reverseQuestion(p);
    var why = await TL.prompt({ title: q.title, message: q.message, placeholder: q.placeholder, confirmText: "Reverse payment", danger: true });
    if (!why) return;
    if (busy) return; busy = true;
    var r = await rpc("centre_reverse_payment", { p_payment: p.payment_id, p_reason: why });
    busy = false;
    if (r.error) return sheetMsg(CP.errorText(r.error), true);
    var text = "Payment reversed. The invoice has been recalculated."; toast(text); afterChange(cur.id, { text: text });
  }
  function afterChange(id, msg) { open(id, true, msg); load(); if (UI.refreshRun) UI.refreshRun(); }

  // ---------------------------------------------------------------- the secret link and WhatsApp
  async function copyText(text) {
    try { await navigator.clipboard.writeText(text); return true; } catch (e) { return false; }
  }
  async function copyLink(rotate) {
    if (busy) return;
    if (rotate && !(await TL.confirm({ title: "Make a new link?", message: "The old link stops working at once. Anyone you sent it to will need the new one.", confirmText: "Make a new link", danger: true }))) return;
    busy = true;
    var r = await rpc("centre_invoice_share_link", { p_invoice: cur.id, p_expires_on: null, p_rotate: !!rotate });
    busy = false;
    if (r.error) return sheetMsg(CP.errorText(r.error), true);
    var url = CP.shareUrl(location.origin, r.data.token);
    var okText = rotate ? "New link copied. The old one no longer works." : "Link copied. Anyone who has it can see this one invoice and how to pay it, and nothing else.";
    if (await copyText(url)) toast(rotate ? "New link copied" : "Link copied"); else await TL.alert({ title: "Copy this link", message: url });
    open(cur.id, true, { text: okText });
  }
  async function whatsapp() {
    if (busy) return;
    var w = null; try { w = window.open("", "_blank"); } catch (e) {}            // opened inside the tap, so the browser allows it; sent to WhatsApp below
    busy = true;
    var r = await rpc("centre_invoice_whatsapp", { p_invoice: cur.id });
    busy = false;
    if (r.error) { if (w) w.close(); return sheetMsg(CP.errorText(r.error), true); }
    var d = r.data, link = d.token ? CP.shareUrl(location.origin, d.token) : "";
    var text = CP.fillTemplate(d.template, d.vars, link), url = CP.waUrl(d.phone, text);
    if (w) { try { w.opener = null; } catch (e) {} w.location.href = url; }
    else { await copyText(text); sheetMsg("Your browser blocked WhatsApp from opening. The message was copied, so you can paste it.", true); return; }
    var noPhone = "No WhatsApp number is saved for this family, so WhatsApp will ask who to send it to.";
    if (!cur.share || !d.phone) open(cur.id, true, d.phone ? null : { text: noPhone });
  }

  window.CentrePay = { show: show, refresh: function () { if (built) load(); }, open: function (id, trigger) { UI = window.CentreMoneyUI; orgId = UI.orgId(); today = today || UI.localToday(); if (!built) frame(); return open(id, trigger); } };      // frame(): an invoice opened from another tab still refreshes this tab's list afterwards
})();
