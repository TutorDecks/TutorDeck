// Centre Money > Refunds (T4 step S5): the refunds a centre has asked for, approved and paid — deposit refunds (and keeping a deposit) and refunds of family
// credit — plus the two forms that start them, and "use the family's credit on an invoice". Every read and write goes through database functions
// (centre_refund_list / _statement / _approve / _pay / _cancel, centre_deposit_release_proposal, centre_deposit_refund_request, centre_family_credit_status,
// centre_credit_refund_request, centre_apply_family_credit); this page never touches a table. Who may do what, what is held and every number are decided there
// (db/migration_centre_refunds.sql); assets/js/centre-refunds-core.js only words the answers.
// Shares the tabs, the message line and the side sheet with assets/js/centre-money.js (window.CentreMoneyUI). TutorDeck records refunds; it never sends the money.
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var RC = window.CentreRefundsCore, CM = window.CentreMoneyCore, UI = null, esc = function (s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var orgId = null, list = null, seq = 0, built = false, busy = false, cur = null, today = "", back = null;

  function rpc(name, args) { return window.sb.rpc(name, args); }
  function chip(r) { var c = RC.chip(r); return '<span class="cm-chip ' + c.tone + '">' + esc(c.text) + '</span>'; }
  function toast(text) { try { TL.toast(text, "ok"); } catch (e) {} }
  function sheetMsg(text, bad) { var m = $("cr-msg"); if (!m) return; m.textContent = text || ""; m.className = "cm-msg" + (text ? (bad ? " err" : " ok") : ""); }
  function field(id, label, control, hint) { return '<div class="cm-fld"><label for="' + id + '">' + esc(label) + '</label>' + control + (hint || '') + '</div>'; }
  function group(title, inner) { return '<div class="cm-g"><div class="cm-gh">' + esc(title) + '</div>' + inner + '</div>'; }

  // ---------------------------------------------------------------- the Refunds tab
  function frame() {
    $("cm-ref").innerHTML = '<div class="card cm-sum" id="cr-sum"><div class="cm-sum-s">Loading…</div></div><div id="cr-list" aria-live="polite"></div>';
    $("cr-list").addEventListener("click", function (e) { var r = e.target.closest("[data-i]"); if (r) { back = null; openRefund(list.rows[+r.dataset.i].id, r); } });
    built = true;
  }
  function rowHtml(x) {
    var i = list.rows.indexOf(x);
    return '<button type="button" class="cm-row" data-i="' + i + '"><span class="cm-main"><span class="cm-name">' + esc(RC.title(x)) + '</span>' +
      '<span class="cm-sub' + (x.state === "requested" && x.can_approve ? ' warn' : '') + '">' + esc(RC.rowSub(x)) + '</span></span>' + chip(x) +
      '<span class="cm-amt">' + esc(CM.money(RC.headline(x))) + '</span>' + UI.chev() + '</button>';
  }
  function drawList() {
    var s = RC.split(list.rows);
    $("cr-sum").innerHTML = '<div class="cm-sum-t">Refunds</div><div class="cm-sum-s">' + esc(RC.summary(list.rows)) + '</div>' +
      '<p class="cm-note">Every refund is asked for, approved and then marked as paid. TutorDeck records it; it never sends money.</p>';
    if (!list.rows.length) { $("cr-list").innerHTML = '<div class="card cm-block"><p class="cm-note">' + esc(RC.emptyText()) + '</p></div>'; return; }
    $("cr-list").innerHTML = (s.open.length ? '<section class="cm-sec"><h2 class="cm-h">Needs action <span class="cm-n">' + s.open.length + '</span></h2><div class="card cm-list">' + s.open.map(rowHtml).join("") + '</div></section>' : '') +
      (s.closed.length ? '<section class="cm-sec"><h2 class="cm-h">Finished <span class="cm-n">' + s.closed.length + '</span></h2><div class="card cm-list">' + s.closed.map(rowHtml).join("") + '</div></section>' : '');
  }
  async function load(msg) {
    var mine = ++seq;
    var r = await rpc("centre_refund_list", { p_org: orgId, p_state: null });
    if (mine !== seq) return;
    if (r.error) return fail(r.error);
    if (!r.data || !r.data.rows) { $("cm-ref").innerHTML = '<div class="card cm-block"><h2 class="cm-h2">Couldn’t load refunds</h2><p class="cm-note">Refresh the page and try again.</p></div>'; return; }
    list = r.data; today = list.today || today;
    drawList();
    if (msg) UI.say(msg, false);
  }
  function fail(err) {
    if (RC.isMissing(err)) { $("cm-ref").innerHTML = '<div class="card cm-block"><h2 class="cm-h2">Not switched on yet</h2><p class="cm-note">Refunds need <b>db/migration_centre_refunds.sql</b> run first.</p></div>'; return; }
    var m = (err && err.message) || "";
    if (/NOT_FOUND/.test(m)) { $("cm-ref").innerHTML = '<div class="card cm-block"><h2 class="cm-h2">Centre not available</h2><p class="cm-note">This centre doesn’t exist, or you aren’t an owner or staff member there.</p></div>'; return; }
    if (/NOT_ALLOWED/.test(m) && !list) { $("cm-ref").innerHTML = '<div class="card cm-block"><h2 class="cm-h2">Refunds aren’t switched on for your account</h2><p class="cm-note">Ask the centre owner to give you the “Record payments”, “Issue invoices” or “View revenue” permission.</p></div>'; return; }
    UI.say(RC.errorText(err), true);
  }
  function show() {
    UI = window.CentreMoneyUI; orgId = UI.orgId();
    if (!built) frame();
    load();
  }

  // ---------------------------------------------------------------- one refund: its calculation, its trail, and the next step
  async function openRefund(id, trigger, msg) {
    $("cm-st").textContent = "Refund"; $("cm-sm").textContent = "";
    if (trigger !== true) { $("cm-sb").innerHTML = '<p class="cm-note">Loading…</p>'; UI.openSheet(trigger); }
    var r = await rpc("centre_refund_statement", { p_refund: id });
    if (r.error) { $("cm-sb").innerHTML = '<p class="cm-note err">' + esc(RC.errorText(r.error)) + '</p>'; return; }
    cur = r.data; renderRefund(msg);
  }
  function renderRefund(msg) {
    var r = cur, c = RC.chip(r);
    $("cm-st").textContent = RC.title(r); $("cm-sm").textContent = RC.kindLabel(r) + " · " + c.text;
    var h = backLink() + '<div class="cm-msg" id="cr-msg" role="status" aria-live="polite"></div>';
    h += '<div class="cm-tot">' + RC.calculationRows(r).map(function (x, i, all) { return '<div' + (i === 0 ? '' : '') + '><span>' + esc(x[0]) + '</span><span>' + esc(CM.money(x[1])) + '</span></div>'; }).join("") + '</div>';
    h += '<div class="cm-facts">' + (r.payee ? '<div><span>Pay to</span><span>' + esc(r.payee) + '</span></div>' : '') +
         (r.kind === "deposit" && r.lesson_end ? '<div><span>Lessons ended</span><span>' + esc(CM.shortDate(r.lesson_end)) + '</span></div>' : '') +
         (r.notice_days ? '<div><span>Notice given</span><span>' + (r.notice_given_on ? esc(CM.shortDate(r.notice_given_on)) : 'Not recorded') + ' (' + r.notice_days + ' days needed)</span></div>' : '') +
         (r.release_rule && r.kind === "deposit" ? '<div><span>Centre’s rule</span><span>' + esc(RC.releaseRuleText(r.release_rule)) + '</span></div>' : '') +
         (r.taxable ? '<div><span>Tax</span><span>The deposit carried GST</span></div>' : '') + '</div>';
    h += group("History", RC.trail(r).map(function (t) {
      return '<div class="cm-pay"><span class="cm-ld"><b>' + esc(t.label) + '</b> · ' + esc(CM.shortDate(t.on)) + (t.by ? ' · ' + esc(t.by) : '') + (t.detail ? '<span class="cm-sub"> ' + esc(t.detail) + '</span>' : '') + '</span></div>';
    }).join(""));
    var next = RC.nextText(r);
    if (next) h += '<p class="cm-note">' + esc(next) + '</p>';
    var acts = RC.actions(r).map(function (a) { return '<button type="button" class="btn' + (a.primary ? ' btn-primary' : ' quiet') + '" data-act="' + a.id + '">' + esc(a.label) + '</button>'; }).join("");
    h += acts ? '<div class="cm-acts col">' + acts + '</div>' : '';
    h += '<p class="cm-note">A refund can’t be edited. If something is wrong, cancel it before it is paid and ask again.</p>';
    $("cm-sb").innerHTML = h; wireBack(); sheetMsg(msg && msg.text, msg && msg.bad);
    $("cm-sb").querySelectorAll("[data-act]").forEach(function (b) { b.addEventListener("click", function () { act(b.dataset.act); }); });
  }
  async function act(kind) {
    if (busy) return;
    var r = cur;
    if (kind === "approve") {
      var ok = await TL.confirm({ title: "Approve this refund?", message: RC.amountLine(r) ? "You are approving: " + RC.amountLine(r) + "." : "", confirmText: "Approve" });
      if (!ok) return;
      busy = true; var a = await rpc("centre_refund_approve", { p_refund: r.id, p_note: null }); busy = false;
      if (a.error) return sheetMsg(RC.errorText(a.error), true);
      var t = RC.approvedText(a.data); toast(t); openRefund(r.id, true, { text: t }); load();
    } else if (kind === "pay") payForm();
    else if (kind === "cancel") {
      var why = await TL.prompt({ title: "Cancel this refund?", message: "Nothing has moved yet. The money stays held for the family.", placeholder: "Reason (kept in the record)", confirmText: "Cancel the refund", danger: true });
      if (!why) return;
      busy = true; var c = await rpc("centre_refund_cancel", { p_refund: r.id, p_reason: why }); busy = false;
      if (c.error) return sheetMsg(RC.errorText(c.error), true);
      var t2 = RC.cancelledText(c.data); toast(t2); openRefund(r.id, true, { text: t2 }); load(); afterMoney();
    }
  }
  function payForm() {
    var r = cur;
    $("cm-sm").textContent = RC.kindLabel(r) + " · Mark as paid";
    $("cm-sb").innerHTML = '<button type="button" class="cm-link cm-back" id="cr-back">‹ Back to the refund</button><h3 class="cm-h2">Mark as paid</h3>' +
      '<p class="cm-note">Pay ' + esc(r.payee || "the family") + ' ' + esc(CM.money(r.refund_cents)) + ' yourself (bank, PayNow, cash or cheque), then record it here.</p>' +
      '<form id="cr-form" novalidate>' +
      field("cr-method", "How was it paid?", '<select id="cr-method">' + RC.METHODS.map(function (m) { return '<option value="' + m[0] + '">' + esc(m[1]) + '</option>'; }).join("") + '</select>') +
      field("cr-date", "Day it was paid", '<input id="cr-date" type="date" value="' + esc(today) + '" max="' + esc(today) + '" min="' + esc(r.requested_on) + '">') +
      field("cr-ref", "Reference (optional)", '<input id="cr-ref" maxlength="120" autocomplete="off">', '<p class="cm-hint">For example “DBS ending 6789”. Never a full bank account or PayNow number.</p>') +
      '<p class="cm-hint err" id="cr-err" role="alert"></p>' +
      '<div class="cm-acts col"><button type="submit" class="btn btn-primary" id="cr-go">Mark as paid</button><button type="button" class="btn" id="cr-cancel">Cancel</button></div></form>';
    $("cr-back").addEventListener("click", function () { renderRefund(); }); $("cr-cancel").addEventListener("click", function () { renderRefund(); });
    $("cr-form").addEventListener("submit", async function (e) {
      e.preventDefault(); if (busy) return;
      var c = RC.checkPaid({ method: $("cr-method").value, dateText: $("cr-date").value, today: today, requestedOn: r.requested_on, reference: $("cr-ref").value });
      if (!c.ok) { $("cr-err").textContent = c.error; return; }
      $("cr-err").textContent = ""; busy = true; $("cr-go").disabled = true;
      var p = await rpc("centre_refund_pay", { p_refund: r.id, p_method: c.method, p_paid_on: c.date, p_reference: c.reference, p_note: null });
      busy = false;
      if (p.error) { $("cr-go").disabled = false; $("cr-err").textContent = RC.errorText(p.error); return; }
      var t = RC.paidText(p.data); toast(t); openRefund(r.id, true, { text: t }); load(); afterMoney();
    });
    $("cr-method").focus();
  }
  // a refund changes what the Deposits tab and the invoices show
  function afterMoney() {
    if (window.CentreDeposits && window.CentreDeposits.refresh) window.CentreDeposits.refresh();
    if (window.CentrePay && window.CentrePay.refresh) window.CentrePay.refresh();
  }

  // ---------------------------------------------------------------- ask to release a student's deposit
  // fromBack: called to go back to the screen that opened this form (the student's deposit sheet)
  async function releaseForm(studentId, name, trigger, fromBack, noticeOn, keep) {
    back = fromBack || null;
    $("cm-st").textContent = "Release deposit"; $("cm-sm").textContent = name;
    $("cm-sb").innerHTML = '<p class="cm-note">Loading…</p>'; if (trigger) UI.openSheet(trigger);
    var r = await rpc("centre_deposit_release_proposal", { p_student: studentId, p_notice_given_on: noticeOn || null });
    if (r.error) { $("cm-sb").innerHTML = '<p class="cm-note err">' + esc(RC.errorText(r.error)) + '</p>' + backLink(); wireBack(); return; }
    var p = r.data; today = p.today || today;
    var h = backLink() + '<div class="cm-msg" id="cr-msg" role="status" aria-live="polite"></div><h3 class="cm-h2">Release the deposit</h3>';
    h += '<div class="cm-tot"><div><span>Held for the family</span><span>' + esc(CM.money(p.held_cents)) + '</span></div>' +
         (p.reserved_cents ? '<div><span>Already being released</span><span>' + esc(CM.money(p.reserved_cents)) + '</span></div>' : '') +
         '<div class="big"><span>Free to release</span><span>' + esc(CM.money(p.available_cents)) + '</span></div></div>';
    if (p.state !== "ready") {
      h += '<p class="cm-note warn">' + esc(RC.waitingText(p)) + '</p>';
      if (p.state === "open_refund" && p.open_refund_id) h += '<div class="cm-acts col"><button type="button" class="btn btn-primary" id="cr-openrf">Open that refund</button></div>';
      $("cm-sb").innerHTML = h; wireBack();
      var o = $("cr-openrf"); if (o) o.addEventListener("click", function () { openRefund(p.open_refund_id, true); });
      return;
    }
    if (!p.can_request) {
      $("cm-sb").innerHTML = h + '<p class="cm-note warn">Only the centre owner or a staff member who issues invoices can release a deposit. Ask one of them.</p>'; wireBack(); return;
    }
    var sug = p.suggest || { refund_cents: 0, forfeit_cents: 0, set_off_cents: 0 }, v = keep || { refund: sug.refund_cents, forfeit: sug.forfeit_cents, setOff: sug.set_off_cents };
    h += '<div class="cm-facts"><div><span>The family still owes</span><span>' + esc(CM.money(p.unpaid_cents)) + '</span></div>' +
         '<div><span>Centre’s rule</span><span>' + esc(RC.releaseRuleText(p.release_rule)) + '</span></div><div><span>Refund approved by</span><span>' + esc({ owner: "The owner", staff: "Owner or staff", four_eyes: "Someone other than the person who asks" }[p.approver_rule] || "") + '</span></div></div>';
    if (p.notice_days > 0) {
      h += field("cr-notice", "Day the family gave notice", '<input id="cr-notice" type="date" value="' + esc(p.notice_given_on || "") + '" max="' + esc(p.today) + '">', '<p class="cm-hint' + (p.notice_short ? ' err' : '') + '" id="cr-notice-h">' + esc(RC.noticeNote(p)) + '</p>');
    }
    if (RC.suggestionText(p)) h += '<p class="cm-note">' + esc(RC.suggestionText(p)) + '</p>';
    if (p.note && !(p.notice_days > 0 && /notice/i.test(p.note))) h += '<p class="cm-note">' + esc(p.note) + '</p>';
    h += '<form id="cr-form" novalidate>' +
      field("cr-refund", "Refund to the family (S$)", '<input id="cr-refund" inputmode="decimal" autocomplete="off" value="' + RC.centsText(v.refund) + '">') +
      (p.taxable ? '' : field("cr-setoff", "Keep against unpaid invoices (S$)", '<input id="cr-setoff" inputmode="decimal" autocomplete="off" value="' + RC.centsText(v.setOff) + '">', '<p class="cm-hint">Pays the family’s open invoices, oldest first, up to what they owe.</p>')) +
      field("cr-forfeit", "Keep as the centre’s income (S$)", '<input id="cr-forfeit" inputmode="decimal" autocomplete="off" value="' + RC.centsText(v.forfeit) + '">', '<p class="cm-hint">Whatever you don’t release stays held.' + (p.taxable ? ' This deposit carried GST: refunds give the GST back.' : '') + '</p>') +
      field("cr-payee", "Pay to (optional)", '<input id="cr-payee" maxlength="120" autocomplete="off" placeholder="Name of the parent">', '<p class="cm-hint">Never a full bank or PayNow number.</p>') +
      field("cr-reason", "Reason (kept in the record)", '<input id="cr-reason" maxlength="300" autocomplete="off" value="' + esc(keep && keep.reason || "") + '">') +
      '<p class="cm-hint err" id="cr-err" role="alert"></p>' +
      '<div class="cm-acts col"><button type="submit" class="btn btn-primary" id="cr-go">Ask for approval</button><button type="button" class="btn" id="cr-cancel">Cancel</button></div></form>';
    $("cm-sb").innerHTML = h; wireBack();
    var key = RC.newKey();                                    // one key per opened form: pressing the button twice asks once
    $("cr-cancel").addEventListener("click", goBack);
    var nt = $("cr-notice");
    if (nt) nt.addEventListener("change", function () { releaseForm(studentId, name, null, fromBack, nt.value || null, null); });      // a new notice day can change the suggestion: ask the database again
    $("cr-form").addEventListener("submit", async function (e) {
      e.preventDefault(); if (busy) return;
      var c = RC.checkRelease({ refundText: $("cr-refund").value, forfeitText: $("cr-forfeit").value, setOffText: $("cr-setoff") ? $("cr-setoff").value : "", p: p, reason: $("cr-reason").value, payee: $("cr-payee").value,
                                noticeText: nt ? nt.value : "", today: p.today });
      if (!c.ok) { $("cr-err").textContent = c.error; return; }
      var q = RC.releaseQuestion(c, name);
      if (!(await TL.confirm({ title: q.title, message: q.message, confirmText: "Ask for approval" }))) return;
      $("cr-err").textContent = ""; busy = true; $("cr-go").disabled = true;
      var s = await rpc("centre_deposit_refund_request", { p_student: studentId, p_refund_cents: c.refund, p_forfeit_cents: c.forfeit, p_set_off_cents: c.setOff,
        p_notice_given_on: nt && nt.value ? nt.value : null, p_payee: c.payee, p_reason: c.reason, p_request_key: key });
      busy = false;
      if (s.error) { $("cr-go").disabled = false; $("cr-err").textContent = RC.errorText(s.error); return; }
      var t = RC.requestedText(s.data); toast(t); openRefund(s.data.id, true, { text: t }); load(); afterMoney();
    });
    $("cr-refund").focus(); $("cr-refund").select();
  }
  function backLink() { return back ? '<button type="button" class="cm-link cm-back" id="cr-back">‹ Back</button>' : ''; }
  function wireBack() { var b = $("cr-back"); if (b) b.addEventListener("click", goBack); }
  function goBack() { if (back) { var f = back; back = null; f(); } else UI.closeSheet(); }

  // ---------------------------------------------------------------- family credit: use it on an invoice, or refund it
  // inv: the invoice sheet's account (a); fromBack returns to that sheet
  async function creditMenu(inv, trigger, fromBack) {
    back = fromBack || null;
    $("cm-st").textContent = "Family credit"; $("cm-sm").textContent = inv.name;
    $("cm-sb").innerHTML = '<p class="cm-note">Loading…</p>'; if (trigger) UI.openSheet(trigger);
    var r = await rpc("centre_family_credit_status", { p_org: orgId, p_household: inv.household_id });
    if (r.error) { $("cm-sb").innerHTML = backLink() + '<p class="cm-note err">' + esc(RC.errorText(r.error)) + '</p>'; wireBack(); return; }
    var st = r.data; today = st.today || today;
    var h = backLink() + '<div class="cm-msg" id="cr-msg" role="status" aria-live="polite"></div><h3 class="cm-h2">' + esc(st.household_name) + ' · credit</h3>' +
      '<div class="cm-tot"><div><span>Held for the family</span><span>' + esc(CM.money(st.balance_cents)) + '</span></div>' +
      (st.reserved_cents ? '<div><span>Being refunded</span><span>' + esc(CM.money(st.reserved_cents)) + '</span></div>' : '') +
      '<div class="big"><span>Free to use or refund</span><span>' + esc(CM.money(st.available_cents)) + '</span></div></div>';
    var open = st.open_invoices || [], acts = '';
    if (st.available_cents > 0 && open.length) acts += '<button type="button" class="btn btn-primary" id="cr-useform">Use credit on an invoice</button>';
    if (st.available_cents > 0) acts += '<button type="button" class="btn" id="cr-refundform">Refund credit to the family</button>';
    h += acts ? '<div class="cm-acts col">' + acts + '</div>' : '<p class="cm-note">No free credit.</p>';
    if (st.available_cents > 0 && !open.length) h += '<p class="cm-note">There is no open invoice to use it on.</p>';
    var rf = (st.refunds || []);
    if (rf.length) h += group("Credit refunds", rf.map(function (x, i) {
      return '<button type="button" class="cm-row" data-rf="' + i + '"><span class="cm-main"><span class="cm-name">' + esc(CM.money(x.refund_cents)) + '</span><span class="cm-sub">' + esc(RC.rowSub(x)) + '</span></span>' + chip(x) + UI.chev() + '</button>';
    }).join(""));
    $("cm-sb").innerHTML = h; wireBack();
    var u = $("cr-useform"), f = $("cr-refundform");
    if (u) u.addEventListener("click", function () { useForm(inv, st, fromBack); });
    if (f) f.addEventListener("click", function () { creditRefundForm(inv, st, fromBack); });
    $("cm-sb").querySelectorAll("[data-rf]").forEach(function (b) { b.addEventListener("click", function () { back = function () { creditMenu(inv, null, fromBack); }; openRefund(rf[+b.dataset.rf].id, true); }); });
  }
  function useForm(inv, st, fromBack) {
    var open = st.open_invoices || [], pick = open.filter(function (i) { return i.id === inv.id; })[0] || open[0];
    back = function () { creditMenu(inv, null, fromBack); };
    $("cm-sm").textContent = st.household_name + " · Use credit";
    $("cm-sb").innerHTML = backLink() + '<h3 class="cm-h2">Use credit on an invoice</h3><p class="cm-note">The credit pays the invoice; no cash is refunded. If it was a mistake, the owner or a staff member who issues invoices can undo it from the invoice (a credit note can’t give it back).</p>' +
      '<form id="cr-form" novalidate>' +
      field("cr-inv", "Which invoice?", '<select id="cr-inv">' + open.map(function (i) { return '<option value="' + esc(i.id) + '"' + (i.id === pick.id ? ' selected' : '') + '>' + esc(i.number + ' · owes ' + CM.money(i.balance_cents)) + '</option>'; }).join("") + '</select>') +
      field("cr-amt", "Amount to use (S$)", '<input id="cr-amt" inputmode="decimal" autocomplete="off" placeholder="' + RC.centsText(RC.applyAmount(st.available_cents, pick.balance_cents)) + '">', '<p class="cm-hint" id="cr-amt-h">Leave blank to use as much as the invoice needs. ' + esc(CM.money(st.available_cents)) + ' is free.</p>') +
      '<p class="cm-hint err" id="cr-err" role="alert"></p>' +
      '<div class="cm-acts col"><button type="submit" class="btn btn-primary" id="cr-go">Use credit</button><button type="button" class="btn" id="cr-cancel">Cancel</button></div></form>';
    wireBack(); $("cr-cancel").addEventListener("click", goBack);
    var key = RC.newKey();
    function sel() { var id = $("cr-inv").value; return open.filter(function (i) { return i.id === id; })[0]; }
    $("cr-inv").addEventListener("change", function () { $("cr-amt").placeholder = RC.centsText(RC.applyAmount(st.available_cents, sel().balance_cents)); });
    $("cr-form").addEventListener("submit", async function (e) {
      e.preventDefault(); if (busy) return;
      var i = sel(), c = RC.checkApply({ amountText: $("cr-amt").value, available: st.available_cents, balance: i.balance_cents });
      if (!c.ok) { $("cr-err").textContent = c.error; return; }
      $("cr-err").textContent = ""; busy = true; $("cr-go").disabled = true;
      var a = await rpc("centre_apply_family_credit", { p_org: orgId, p_household: inv.household_id, p_invoice_ids: [i.id], p_cents: c.cents, p_request_key: key });
      busy = false;
      if (a.error) { $("cr-go").disabled = false; $("cr-err").textContent = RC.errorText(a.error); return; }
      var t = RC.appliedText(a.data); toast(t); back = null;
      if (fromBack) fromBack({ text: t }); else UI.closeSheet();
      if (window.CentrePay && window.CentrePay.refresh) window.CentrePay.refresh();
    });
    $("cr-amt").focus();
  }
  function creditRefundForm(inv, st, fromBack) {
    back = function () { creditMenu(inv, null, fromBack); };
    $("cm-sm").textContent = st.household_name + " · Refund credit";
    $("cm-sb").innerHTML = backLink() + '<h3 class="cm-h2">Refund credit</h3><p class="cm-note">' + esc(CM.money(st.available_cents)) + ' is free to refund. It is asked for here and has to be approved. ' + esc(RC.approverWords({ kind: "family_credit", approver_rule: st.approver_rule })) + ' Then you pay the family yourself and mark it as paid.</p>' +
      '<form id="cr-form" novalidate>' +
      field("cr-amt", "Amount to refund (S$)", '<input id="cr-amt" inputmode="decimal" autocomplete="off" value="' + RC.centsText(st.available_cents) + '">') +
      field("cr-payee", "Pay to (optional)", '<input id="cr-payee" maxlength="120" autocomplete="off" placeholder="Name of the parent">', '<p class="cm-hint">Never a full bank or PayNow number.</p>') +
      field("cr-reason", "Reason (kept in the record)", '<input id="cr-reason" maxlength="300" autocomplete="off">') +
      '<p class="cm-hint err" id="cr-err" role="alert"></p>' +
      '<div class="cm-acts col"><button type="submit" class="btn btn-primary" id="cr-go">Ask for approval</button><button type="button" class="btn" id="cr-cancel">Cancel</button></div></form>';
    wireBack(); $("cr-cancel").addEventListener("click", goBack);
    var key = RC.newKey();
    $("cr-form").addEventListener("submit", async function (e) {
      e.preventDefault(); if (busy) return;
      var c = RC.checkCreditRefund({ amountText: $("cr-amt").value, available: st.available_cents, reason: $("cr-reason").value });
      if (!c.ok) { $("cr-err").textContent = c.error; return; }
      $("cr-err").textContent = ""; busy = true; $("cr-go").disabled = true;
      var s = await rpc("centre_credit_refund_request", { p_org: orgId, p_household: inv.household_id, p_cents: c.cents, p_payee: $("cr-payee").value.trim() || null, p_reason: c.reason, p_request_key: key });
      busy = false;
      if (s.error) { $("cr-go").disabled = false; $("cr-err").textContent = RC.errorText(s.error); return; }
      var t = RC.requestedText(s.data); toast(t); back = function () { creditMenu(inv, null, fromBack); }; openRefund(s.data.id, true, { text: t }); load();
    });
    $("cr-amt").focus(); $("cr-amt").select();
  }

  // ---------------------------------------------------------------- undo credit / a deposit that was applied to an invoice (T4 step S5b)
  // apps: centre_invoice_applications(invoice).rows. The database says who may and what blocks it; this shows it and asks for the reason.
  function undoForm(inv, apps, fromBack) {
    var act = (apps || []).filter(function (a) { return a.state === "active"; });
    back = null;
    $("cm-st").textContent = "Undo"; $("cm-sm").textContent = inv.number + " · Undo credit or deposit used";
    if (!act.length) { $("cm-sb").innerHTML = '<button type="button" class="cm-link cm-back" id="cr-back">‹ Back to the invoice</button><p class="cm-note">Nothing on this invoice can be undone.</p>'; $("cr-back").addEventListener("click", function () { if (fromBack) fromBack(); }); return; }
    var pick = act.filter(function (a) { return a.can_undo; })[0] || act[0];
    $("cm-sb").innerHTML = '<button type="button" class="cm-link cm-back" id="cr-back">‹ Back to the invoice</button><h3 class="cm-h2">Undo credit or deposit used</h3>' +
      '<p class="cm-note">The money is taken back off the invoice and goes back to the family’s credit (or the student’s deposit). The original entry stays in the record; the undo is a new entry with your reason. Only the owner or a staff member who issues invoices can do this.</p>' +
      '<form id="cr-form" novalidate>' +
      (act.length > 1 ? field("cu-pick", "Which one?", '<select id="cu-pick">' + act.map(function (a, i) { return '<option value="' + i + '"' + (a === pick ? ' selected' : '') + '>' + esc(CM.money(a.cents) + ' · ' + RC.undoWhat(a) + ' · ' + CM.shortDate(a.date)) + '</option>'; }).join("") + '</select>') : '') +
      '<div id="cu-det"></div>' +
      field("cu-reason", "Reason (kept in the record)", '<input id="cu-reason" maxlength="300" autocomplete="off">') +
      '<p class="cm-hint err" id="cr-err" role="alert"></p>' +
      '<div class="cm-acts col"><button type="submit" class="btn btn-primary" id="cr-go">Undo</button><button type="button" class="btn" id="cr-cancel">Cancel</button></div></form>';
    var key = null;
    function sel() { return act.length > 1 ? act[+$("cu-pick").value] : act[0]; }
    function draw() {
      var a = sel(), b = RC.undoBlockers(a);
      $("cu-det").innerHTML = '<div class="cm-tot"><div><span>' + esc(RC.undoTitle(a)) + '</span><span>' + esc(CM.money(a.cents)) + '</span></div></div><p class="cm-note">' + esc(RC.undoRow(a)) + '</p>' +
        (b.length ? '<p class="cm-note warn" id="cu-block">Can’t be undone: ' + esc(b.join(' ')) + '</p>' : '<p class="cm-note" id="cu-ok">' + esc(RC.undoQuestion(a, inv.number)) + '</p>');
      $("cr-go").disabled = !a.can_undo; $("cu-reason").disabled = !a.can_undo;
    }
    var goBackSheet = function () { if (fromBack) fromBack(); else UI.closeSheet(); };
    $("cr-back").addEventListener("click", goBackSheet); $("cr-cancel").addEventListener("click", goBackSheet);
    if (act.length > 1) $("cu-pick").addEventListener("change", draw);
    draw();
    $("cr-form").addEventListener("submit", async function (e) {
      e.preventDefault(); if (busy) return;
      var a = sel(); if (!a.can_undo) return;
      var c = RC.checkUndo({ reason: $("cu-reason").value });
      if (!c.ok) { $("cr-err").textContent = c.error; return; }
      if (!(await TL.confirm({ title: "Undo this?", message: RC.undoQuestion(a, inv.number), confirmText: "Undo" }))) return;
      $("cr-err").textContent = ""; busy = true; $("cr-go").disabled = true;
      var r = await rpc("centre_undo_application", { p_payment: a.payment_id, p_reason: c.reason });
      busy = false;
      if (r.error) { $("cr-go").disabled = false; $("cr-err").textContent = RC.errorText(r.error); return; }
      var t = RC.undoDoneText(r.data, a); toast(t);
      if (fromBack) fromBack({ text: t }); else UI.closeSheet();
      if (window.CentrePay && window.CentrePay.refresh) window.CentrePay.refresh();
    });
    if (!$("cu-reason").disabled) $("cu-reason").focus();
  }

  function ensure() { UI = window.CentreMoneyUI; orgId = UI.orgId(); today = today || UI.localToday(); if (!built) frame(); }
  window.CentreRefunds = {
    show: show, refresh: function () { if (built) load(); },
    releaseDeposit: function (studentId, name, trigger, fromBack) { ensure(); return releaseForm(studentId, name, trigger, fromBack); },
    creditMenu: function (inv, trigger, fromBack) { ensure(); return creditMenu(inv, trigger, fromBack); },
    undoApplication: function (inv, apps, fromBack) { ensure(); return undoForm(inv, apps, fromBack); },
    open: function (id, trigger) { ensure(); back = null; return openRefund(id, trigger); }
  };
})();
