// Centre Tutor pay (T4 step S7): Pay list · Rates · Lessons taught. For the centre owner and staff with the "Run tutor pay" permission ONLY: tutors never see rates or pay.
// Every read and write goes through database functions (centre_tutor_rate_list / _rate_set, centre_tutor_pay_list / _detail / _adjust / _record / _reverse / _export_log,
// centre_tutor_taught_report); this page never touches a table. Which rate is in force, what a lesson earns, when it is released ("held until the parent pays"), who may
// and the period figures are decided there (db/migration_centre_tutor_pay.sql); assets/js/centre-tutor-pay-core.js only words the answers and checks what was typed.
// Page address: centre-tutor-pay?id=<centre>[&tab=rates|taught][&month=yyyy-mm]
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var esc = function (s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var CP = window.CentreTutorPayCore, CM = window.CentreMoneyCore;
  var orgId = null, mode = "off", month = null, tab = "pay", rates = null, plist = null, taught = null, curTutor = null, detail = null;
  var busy = false, sheetOpener = null, seq = 0;

  function rpc(name, args) { return window.sb.rpc(name, args); }
  function say(text, bad) { var m = $("tp-msg"); m.textContent = text || ""; m.className = "cm-msg" + (text ? (bad ? " err" : " ok") : ""); }
  function sheetMsg(text, bad) { var m = $("tp-smsg"); if (!m) return say(text, bad); m.textContent = text || ""; m.className = "cm-msg" + (text ? (bad ? " err" : " ok") : ""); }
  function toast(t) { try { TL.toast(t, "ok"); } catch (e) {} }
  function localToday() { var d = new Date(); return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10); }
  function chip(c) { return '<span class="cm-chip ' + c.tone + '">' + esc(c.text) + '</span>'; }
  function chev() { return '<svg class="cm-chev" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="m9 18 6-6-6-6"/></svg>'; }
  function card(el, inner) { el.innerHTML = '<div class="card cm-block">' + inner + '</div>'; }
  function lockBody(on) { document.body.classList.toggle("sheet-lock", !!on); }
  function openSheet(trigger) { sheetOpener = trigger || sheetOpener; $("cm-sheet").classList.add("on"); lockBody(true); $("cm-sx").focus(); }
  function closeSheet() { $("cm-sheet").classList.remove("on"); lockBody(false); setTimeout(function () { if (!$("cm-sheet").classList.contains("on")) $("cm-sb").innerHTML = ""; }, 300);
    if (sheetOpener && sheetOpener.focus && document.contains(sheetOpener)) sheetOpener.focus(); sheetOpener = null; curTutor = null; detail = null; }
  function fld(id, label, control, hint) { return '<div class="cm-fld"><label for="' + id + '">' + esc(label) + '</label>' + control + (hint ? '<p class="cm-hint">' + hint + '</p>' : '') + '</div>'; }
  function opts(list, sel) { return list.map(function (o) { return '<option value="' + esc(o[0]) + '"' + (o[0] === sel ? " selected" : "") + '>' + esc(o[1]) + '</option>'; }).join(""); }

  // ---------------------------------------------------------------- errors that stop the whole page
  function fatal(err) {
    var m = (err && err.message) || "";
    var box = '<h2 class="cm-h2">';
    var all = [$("tp-paybody"), $("tp-rates"), $("tp-taught")];
    var html;
    if (CP.isMissing(err)) html = box + 'Not switched on yet</h2><p class="cm-note">Tutor pay needs <b>db/migration_centre_tutor_pay.sql</b> run first.</p>';
    else if (/PAY_OFF/.test(m)) html = box + 'Tutor pay is switched off</h2><p class="cm-note">Switch it on in Centre settings (Tutor pay) to set rates and see the pay list.</p>';
    else if (/NOT_FOUND/.test(m)) html = box + 'Centre not available</h2><p class="cm-note">This centre doesn’t exist, or you aren’t an owner or staff member there.</p>';
    else if (/NOT_ALLOWED/.test(m)) html = box + 'Tutor pay isn’t switched on for your account</h2><p class="cm-note">Ask the centre owner to give you the “Run tutor pay” permission.</p>';
    else return say(CP.errorText(err), true);
    all.forEach(function (el) { card(el, html); });
    $("tp-when").textContent = ""; $("tp-prev").disabled = $("tp-next").disabled = true;
  }

  // ---------------------------------------------------------------- the month
  function nav() { $("tp-when").textContent = CM.monthLabel(month); $("tp-prev").disabled = busy; $("tp-next").disabled = busy; }
  function syncUrl() {
    try { history.replaceState(null, "", location.pathname + "?id=" + encodeURIComponent(orgId) + (tab === "rates" ? "&tab=rates" : (tab === "taught" ? "&tab=taught&" : "&") + "month=" + month.slice(0, 7))); } catch (e) {}
  }

  // ---------------------------------------------------------------- Pay list
  async function loadPay(msg) {
    var mine = ++seq; nav(); $("tp-ctx").textContent = "";
    var r = await rpc("centre_tutor_pay_list", { p_org: orgId, p_month: month });
    if (mine !== seq) return;
    if (r.error) {
      if (/PAY_REPORT_ONLY/.test(r.error.message || "")) { $("tp-ctx").textContent = ""; return card($("tp-paybody"), '<h2 class="cm-h2">Report only</h2><p class="cm-note">' + esc(CP.modeNote("report")) + '</p>'); }
      return fatal(r.error);
    }
    plist = r.data; drawPay(); if (msg) say(msg, false);
  }
  function tutorRow(t, i) {
    var c = CP.payChip(t), neg = t.outstanding_cents < 0;
    return '<button type="button" class="cm-row" data-t="' + i + '"><span class="cm-main"><span class="cm-name">' + esc(t.name) + '</span><span class="cm-sub' + (t.no_rate ? ' warn' : '') + '">' + esc(CP.rowSub(t)) + '</span></span>' +
      chip(c) + '<span class="cm-amt">' + esc(CM.money(Math.max(t.outstanding_cents, 0))) + '</span>' + chev() + '</button>';
  }
  function drawPay() {
    var l = plist; $("tp-ctx").textContent = CP.periodText(l);
    var rows = CP.csvRows(l), un = CP.unassignedNote(l.unassigned_lessons);
    var h = '<div class="card cm-sum"><div class="cm-sum-t">Pay list</div><div class="cm-sum-s">' + esc(CP.listSummary(l)) + '</div>' +
      '<p class="cm-note">' + esc(CP.modeNote("full", l.payable_when)) + ' Pay day is the ' + esc(l.pay_day) + 'th.</p>' + (un ? '<p class="cm-note warn">' + esc(un) + '</p>' : '') +
      '<div class="cm-acts"><button type="button" class="btn" id="tp-csv"' + (rows.length ? '' : ' disabled') + '>Download the list (CSV)</button></div></div>';
    h += '<section class="cm-sec"><h2 class="cm-h">Tutors <span class="cm-n">' + (l.tutors || []).length + '</span></h2>' +
      ((l.tutors || []).length ? '<div class="card cm-list">' + l.tutors.map(tutorRow).join("") + '</div>' :
        '<div class="card cm-block"><p class="cm-note">No tutors yet. Add tutors in Centre settings, then set their rates under Rates.</p></div>') + '</section>';
    $("tp-paybody").innerHTML = h;
  }

  // ---------------------------------------------------------------- one tutor's pay (the sheet)
  async function openTutor(i, trigger, keepMsg) {
    var t = (plist.tutors || [])[i]; if (!t) return;
    curTutor = t; if (trigger) sheetOpener = trigger;
    $("cm-st").textContent = t.name; $("cm-sm").textContent = CP.periodText(plist) + (CP.employmentText(t.employment_type) ? " · " + CP.employmentText(t.employment_type) : "");
    $("cm-sb").innerHTML = '<div class="cm-msg" id="tp-smsg" role="status" aria-live="polite"></div><p class="cm-note">Loading…</p>'; openSheet(trigger);
    var r = await rpc("centre_tutor_pay_detail", { p_org: orgId, p_membership: t.membership_id, p_month: month });
    if (r.error) { $("cm-sb").innerHTML = '<p class="cm-note err">' + esc(CP.errorText(r.error)) + '</p>'; return; }
    detail = r.data; drawTutor(keepMsg);
  }
  function drawTutor(keepMsg) {
    var t = curTutor, d = detail, rowsDue = CP.dueRows(t), h = '<div class="cm-msg" id="tp-smsg" role="status" aria-live="polite"></div>';
    h += '<div class="cm-tot">' + rowsDue.map(function (x) { return '<div><span>' + esc(x[0]) + '</span><span>' + esc(CM.money(x[1])) + '</span></div>'; }).join("") +
      '<div class="big"><span>Due</span><span>' + esc(CM.money(t.due_cents)) + '</span></div>' +
      (t.paid_cents ? '<div><span>Paid so far</span><span>' + esc(CM.money(t.paid_cents)) + '</span></div>' : '') +
      '<div class="big"><span>Still to pay</span><span>' + esc(CM.money(Math.max(t.outstanding_cents, 0))) + '</span></div></div>';
    if (t.held_cents > 0) h += '<p class="cm-note warn">' + esc(CM.money(t.held_cents)) + ' is held until the families pay. It is not part of what is due.</p>';
    h += '<div class="cm-acts col">' + (t.outstanding_cents > 0 ? '<button type="button" class="btn btn-primary" id="tp-rec">Record a payment</button>' : '') +
      (plist.adjustments_on ? '<button type="button" class="btn" id="tp-adj">Add a bonus or deduction</button>' : '') + '</div>';
    var lines = d.lines || [];
    h += '<div class="cm-g"><div class="cm-gh">Lessons (' + lines.length + ')</div>' + (lines.length ? lines.map(function (l) {
      var c = CP.stateChip(l.state), held = CP.lineHeld(l);
      return '<div class="tp-ln"><span class="cm-ld">' + esc(CP.lineSub(l)) + '<span class="cm-sub">' + esc(l.method ? CP.methodLabel(l.method) + (l.scope && l.scope !== "default" ? " (" + l.scope + " rate)" : "") : "No rate") + ' · ' + esc(CP.stateHelp(l.state)) + '</span></span>' +
        '<span class="tp-end">' + chip(c) + '<b>' + esc(CP.lineAmount(l)) + '</b>' + (held ? '<span class="cm-sub">' + esc(held) + '</span>' : '') + '</span></div>';
    }).join("") : '<p class="cm-note">No lessons in this period.</p>') + '</div>';
    if ((d.adjustments || []).length) h += '<div class="cm-g"><div class="cm-gh">Bonuses and deductions</div>' + d.adjustments.map(function (a) {
      return '<div class="cm-ln"><span class="cm-ld">' + esc(CP.adjustmentLine(a)) + '</span><span class="cm-la' + (a.amount_cents < 0 ? '' : ' neg') + '">' + esc(CM.money(a.amount_cents)) + '</span></div>'; }).join("") + '</div>';
    if ((d.payments || []).length) h += '<div class="cm-g"><div class="cm-gh">Payments recorded</div>' + d.payments.map(function (p) {
      var rev = p.kind === "reversal", off = rev || p.reversed;
      return '<div class="cm-pay' + (off ? ' off' : '') + '"><span class="cm-ld">' + esc((rev ? "Reversal · " : "") + CM.shortDate(p.paid_on) + " · " + methodName(p.method) + (p.reference ? " · " + p.reference : "")) + (p.reversed ? '<span class="cm-tag">Reversed</span>' : '') + '</span>' +
        '<span class="cm-la">' + esc(CM.money(p.amount_cents)) + '</span>' + (!off ? '<button type="button" class="cm-link" data-rev="' + esc(p.id) + '">Reverse</button>' : '') + '</div>'; }).join("") + '</div>';
    $("cm-sb").innerHTML = h;
    if ($("tp-rec")) $("tp-rec").addEventListener("click", recordForm);
    if ($("tp-adj")) $("tp-adj").addEventListener("click", adjustForm);
    if (keepMsg) sheetMsg(keepMsg, false);
  }
  function methodName(m) { var f = CP.PAY_METHODS.filter(function (x) { return x[0] === m; })[0]; return f ? f[1] : m; }

  function formShell(title, inner, go) {
    $("cm-sb").innerHTML = '<div class="cm-msg" id="tp-smsg" role="status" aria-live="polite"></div><button type="button" class="cm-link cm-back" id="tp-back">‹ Back</button><form id="tp-form" novalidate>' + inner +
      '<p class="cm-hint" id="tp-hint"></p><div class="cm-acts col"><button type="submit" class="btn btn-primary" id="tp-go">' + esc(go) + '</button><button type="button" class="btn" id="tp-cancel">Cancel</button></div></form>';
    $("tp-back").addEventListener("click", function () { drawTutor(); });
    $("tp-cancel").addEventListener("click", function () { drawTutor(); });
  }
  function recordForm() {
    var t = curTutor, today = localToday();
    formShell("Record a payment",
      fld("tp-amt", "Amount paid (S$)", '<input id="tp-amt" inputmode="decimal" autocomplete="off" value="' + esc((Math.max(t.outstanding_cents, 0) / 100).toFixed(2)) + '">', "Still to pay: " + esc(CM.money(Math.max(t.outstanding_cents, 0))) + ". TutorDeck only records it; you make the transfer yourself.") +
      fld("tp-method", "How you paid", '<select id="tp-method">' + opts(CP.PAY_METHODS, "paynow") + '</select>') +
      fld("tp-date", "Day paid", '<input id="tp-date" type="date" max="' + today + '" value="' + today + '">') +
      fld("tp-ref", "Reference (optional)", '<input id="tp-ref" maxlength="100" autocomplete="off">', "For your own records, for example a pay-run name. Never a whole bank or PayNow number."), "Record payment");
    $("tp-form").addEventListener("submit", async function (e) {
      e.preventDefault(); if (busy) return;
      var c = CP.checkPayment({ amountText: $("tp-amt").value, outstanding: t.outstanding_cents, method: $("tp-method").value, date: $("tp-date").value, today: today, reference: $("tp-ref").value });
      if (!c.ok) return sheetMsg(c.error, true);
      if (!(await TL.confirm(CP.payQuestion(t.name, c, CP.periodText(plist))))) return;
      busy = true; $("tp-go").disabled = true;
      var r = await rpc("centre_tutor_pay_record", { p_org: orgId, p_membership: t.membership_id, p_month: month, p_amount_cents: c.cents, p_paid_on: $("tp-date").value, p_method: $("tp-method").value, p_reference: c.ref, p_note: null });
      busy = false; $("tp-go") && ($("tp-go").disabled = false);
      if (r.error) return sheetMsg(CP.errorText(r.error), true);
      toast("Payment recorded."); await refreshTutor("Recorded " + CM.money(c.cents) + " for " + t.name + ".");
    });
  }
  function adjustForm() {
    var today = localToday();
    formShell("Add a bonus or deduction",
      fld("tp-kind", "This is a", '<select id="tp-kind"><option value="bonus">Bonus (adds to the pay)</option><option value="deduction">Deduction (takes off the pay)</option></select>') +
      fld("tp-amt", "Amount (S$)", '<input id="tp-amt" inputmode="decimal" autocomplete="off">') +
      fld("tp-date", "Belongs to the day", '<input id="tp-date" type="date" value="' + esc(plist.period_to < today ? plist.period_to : today) + '">', "It counts in the pay period that day falls in. A period you have already recorded as paid can’t take a new one: pick a later day.") +
      fld("tp-reason", "Reason", '<textarea id="tp-reason" maxlength="300"></textarea>', "Kept in the record, never deleted."), "Add it");
    $("tp-form").addEventListener("submit", async function (e) {
      e.preventDefault(); if (busy) return;
      var c = CP.checkAdjustment({ kind: $("tp-kind").value, amountText: $("tp-amt").value, on: $("tp-date").value, reason: $("tp-reason").value, today: today });
      if (!c.ok) return sheetMsg(c.error, true);
      busy = true; $("tp-go").disabled = true;
      var r = await rpc("centre_tutor_pay_adjust", { p_org: orgId, p_membership: curTutor.membership_id, p_amount_cents: c.args.p_amount_cents, p_on: c.args.p_on, p_reason: c.args.p_reason });
      busy = false; $("tp-go") && ($("tp-go").disabled = false);
      if (r.error) return sheetMsg(CP.errorText(r.error), true);
      toast("Added."); await refreshTutor("Added.");
    });
  }
  async function reversePay(id) {
    if (busy) return;
    var why = await TL.prompt({ title: "Reverse this payment?", message: "Use this for a payment recorded by mistake. The original stays on record and a reversal is added. Say why.", placeholder: "Reason", confirmText: "Reverse it", danger: true });
    if (why == null) return;
    if (!String(why).trim()) return sheetMsg("Please say why.", true);
    busy = true; var r = await rpc("centre_tutor_pay_reverse", { p_payment: id, p_reason: String(why).trim() }); busy = false;
    if (r.error) return sheetMsg(CP.errorText(r.error), true);
    toast("Reversed."); await refreshTutor("Payment reversed.");
  }
  // reload the list and reopen the same tutor
  async function refreshTutor(msg) {
    var id = curTutor && curTutor.membership_id;
    var r = await rpc("centre_tutor_pay_list", { p_org: orgId, p_month: month });
    if (r.error) return sheetMsg(CP.errorText(r.error), true);
    plist = r.data; drawPay();
    var i = (plist.tutors || []).findIndex(function (x) { return x.membership_id === id; });
    if (i >= 0) await openTutor(i, null, msg);
  }

  // ---------------------------------------------------------------- the CSV
  async function exportCsv() {
    if (busy || !plist) return;
    var csv = CP.buildCsv(plist), rows = CP.csvRows(plist).length;
    busy = true; var b = $("tp-csv"); if (b) b.disabled = true;
    var r = await rpc("centre_tutor_pay_export_log", { p_org: orgId, p_month: month, p_rows: rows, p_total_cents: CP.csvTotal(plist) });   // the export is written to the audit log first
    busy = false; if (b) b.disabled = false;
    if (r.error) return say(CP.errorText(r.error), true);
    var blob = new Blob(["﻿" + csv], { type: "text/csv;charset=utf-8" }), a = document.createElement("a");
    a.href = URL.createObjectURL(blob); a.download = CP.csvName(plist); document.body.appendChild(a); a.click(); a.remove();
    setTimeout(function () { URL.revokeObjectURL(a.href); }, 2000);
    say("Downloaded " + rows + " " + (rows === 1 ? "payee" : "payees") + " (" + CM.money(CP.csvTotal(plist)) + "). It lists what is still to pay; it has no bank details.", false);
  }

  // ---------------------------------------------------------------- Rates
  async function loadRates() {
    var r = await rpc("centre_tutor_rate_list", { p_org: orgId });
    if (r.error) return fatal(r.error);
    rates = r.data; mode = rates.mode; drawRates();
  }
  function rateRow(t, i) {
    return '<button type="button" class="cm-row" data-r="' + i + '"><span class="cm-main"><span class="cm-name">' + esc(t.name) + '</span><span class="cm-sub' + (CP.currentDefault(t) ? '' : ' warn') + '">' +
      esc(CP.tutorSub(t, rates.today)) + '</span></span>' + (CP.employmentText(t.role === "tutor" ? t.employment_type : t.employment_type) ? '<span class="cm-chip">' + esc(CP.employmentText(t.employment_type)) + '</span>' : '') + chev() + '</button>';
  }
  function drawRates() {
    var ts = rates.tutors || [];
    $("tp-rates").innerHTML = '<div class="card cm-sum"><div class="cm-sum-t">Rates</div><div class="cm-sum-s">Each tutor has their own rate, and you can set a different one for a student or a level.</div>' +
      '<p class="cm-note">A new rate starts on the date you choose. Lessons already taught keep the rate they had, unless nothing was set yet. Nothing is ever edited or deleted: each change is a new line in the history.</p></div>' +
      '<section class="cm-sec"><h2 class="cm-h">Tutors <span class="cm-n">' + ts.length + '</span></h2>' + (ts.length ? '<div class="card cm-list">' + ts.map(rateRow).join("") + '</div>' :
      '<div class="card cm-block"><p class="cm-note">No tutors yet. Add tutors in Centre settings.</p></div>') + '</section>';
  }
  function openRates(i, trigger, msg) {
    var t = (rates.tutors || [])[i]; if (!t) return; curTutor = t; if (trigger) sheetOpener = trigger;
    $("cm-st").textContent = t.name; $("cm-sm").textContent = "Rates" + (CP.employmentText(t.employment_type) ? " · " + CP.employmentText(t.employment_type) : "");
    var today = rates.today, groups = { default: [], level: [], student: [] };
    (t.rates || []).forEach(function (r) { groups[CP.scopeKind(r)].push(r); });
    var h = '<div class="cm-msg" id="tp-smsg" role="status" aria-live="polite"></div><div class="cm-acts col"><button type="button" class="btn btn-primary" id="tp-new">Set a new rate</button></div>';
    [["default", "Usual rate"], ["level", "By level"], ["student", "By student"]].forEach(function (g) {
      var rows = groups[g[0]]; if (!rows.length) return;
      var seen = {};
      h += '<div class="cm-g"><div class="cm-gh">' + g[1] + '</div>' + rows.map(function (r) {
        var key = CP.scopeText(r), first = !seen[key]; seen[key] = true;
        return '<div class="cm-ln"><span class="cm-ld">' + (g[0] !== "default" && first ? '<b>' + esc(CP.scopeText(r)) + '</b><br>' : g[0] !== "default" ? esc(CP.scopeText(r)) + '<br>' : '') + esc(CP.historyLine(r, today)) + '<span class="cm-sub">' + esc(r.reason) + '</span></span>' +
          (r.in_force ? '<span class="cm-chip ok">In force</span>' : r.effective_from > today ? '<span class="cm-chip warn">Coming</span>' : '<span class="cm-chip">Replaced</span>') + '</div>';
      }).join("") + '</div>';
    });
    if (!(t.rates || []).length) h += '<p class="cm-note warn">No rate yet. Lessons this tutor teaches will show “No rate” and won’t be paid until you set one.</p>';
    if (t.frozen_to) h += '<p class="cm-note">Pay up to ' + esc(CM.shortDate(t.frozen_to)) + ' is already recorded as paid, so a new rate has to start after that day.</p>';
    $("cm-sb").innerHTML = h; openSheet(trigger);
    $("tp-new").addEventListener("click", function () { rateForm(); });
    if (msg) sheetMsg(msg, false);
  }
  function rateForm() {
    var t = curTutor, today = rates.today, ct = rates.class_type;
    formShell("Set a new rate",
      fld("tp-scope", "This rate is for", '<select id="tp-scope"><option value="default">All this tutor’s lessons (the usual rate)</option><option value="level">One level</option><option value="student">One student</option></select>') +
      '<div id="tp-who"></div>' +
      fld("tp-method", "How the tutor is paid", '<select id="tp-method"></select>') +
      '<div id="tp-val"></div>' +
      fld("tp-from", "Starts on", '<input id="tp-from" type="date" value="' + esc(t.frozen_to && t.frozen_to >= today ? "" : today) + '">', "Lessons taught before this day keep the rate they had.") +
      fld("tp-reason", "Reason", '<input id="tp-reason" maxlength="300" autocomplete="off" value="' + ((t.rates || []).length ? "" : "Starting rate") + '">', "For example “Annual review”. Kept in the history."), "Save rate");
    function who() {
      var sc = $("tp-scope").value;
      $("tp-who").innerHTML = sc === "student" ? fld("tp-stu", "Student", '<select id="tp-stu">' + opts((rates.students || []).map(function (s) { return [s.id, s.name]; })) + '</select>') :
        sc === "level" ? fld("tp-level", "Level", '<input id="tp-level" list="tp-levels" maxlength="60" autocomplete="off" placeholder="for example Sec 3"><datalist id="tp-levels">' + (rates.levels || []).map(function (l) { return '<option value="' + esc(l) + '">'; }).join("") + '</datalist>') : "";
      var sel = $("tp-method"), prev = sel.value || rates.default_method;
      sel.innerHTML = opts(CP.methodsFor(sc, ct), prev); val();
    }
    function val() {
      var m = $("tp-method").value;
      $("tp-val").innerHTML = m === "percent_of_fee" ? fld("tp-pct", "Percentage of the fee billed", '<input id="tp-pct" inputmode="decimal" autocomplete="off" placeholder="60">', "Worked out on the fee the family is billed for each lesson, before GST (see Centre settings > Tutor pay).") :
        (m === "none" || m === "inherit") ? '<p class="cm-hint">' + (m === "none" ? "No pay for these lessons." : "From this day the tutor’s usual rate applies again.") + '</p>' :
        fld("tp-amt", m === "per_hour" ? "Amount per hour (S$)" : m === "monthly_fixed" ? "Amount each month (S$)" : m === "per_student_lesson" ? "Amount per student per lesson (S$)" : "Amount per lesson (S$)", '<input id="tp-amt" inputmode="decimal" autocomplete="off" placeholder="40.00">');
    }
    $("tp-scope").addEventListener("change", who); $("tp-method").addEventListener("change", val); who();
    $("tp-form").addEventListener("submit", async function (e) {
      e.preventDefault(); if (busy) return;
      var c = CP.checkRate({ scope: $("tp-scope").value, studentId: $("tp-stu") && $("tp-stu").value, level: $("tp-level") && $("tp-level").value, method: $("tp-method").value,
        amountText: $("tp-amt") && $("tp-amt").value, percentText: $("tp-pct") && $("tp-pct").value, from: $("tp-from").value, reason: $("tp-reason").value, today: today, classType: ct });
      if (!c.ok) return sheetMsg(c.error, true);
      if (c.note && !(await TL.confirm({ title: "Start this rate in the past?", message: c.note, confirmText: "Yes, save it" }))) return;
      busy = true; $("tp-go").disabled = true;
      var args = Object.assign({ p_org: orgId, p_membership: t.membership_id }, c.args);
      var r = await rpc("centre_tutor_rate_set", args);
      busy = false; $("tp-go") && ($("tp-go").disabled = false);
      if (r.error) return sheetMsg(CP.errorText(r.error), true);
      toast("Rate saved.");
      var id = t.membership_id; await loadRates();
      var i = (rates.tutors || []).findIndex(function (x) { return x.membership_id === id; });
      if (i >= 0) openRates(i, null, "Saved.");
    });
  }

  // ---------------------------------------------------------------- Lessons taught (no money)
  async function loadTaught() {
    var r = await rpc("centre_tutor_taught_report", { p_org: orgId, p_month: month });
    if (r.error) return fatal(r.error);
    taught = r.data; var ts = taught.tutors || [], un = CP.unassignedNote(taught.unassigned_lessons);
    $("tp-taught").innerHTML = '<div class="cm-nav"><button class="btn" id="tp-prev2" type="button" aria-label="Previous month">&lsaquo;</button><div class="cm-when">' + esc(CM.monthLabel(month)) + '</div><button class="btn" id="tp-next2" type="button" aria-label="Next month">&rsaquo;</button></div>' +
      '<div class="card cm-sum"><div class="cm-sum-t">Lessons taught</div><div class="cm-sum-s">How many lessons and hours each tutor taught in the month. No money on this report.</div>' + (un ? '<p class="cm-note warn">' + esc(un) + '</p>' : '') + '</div>' +
      '<section class="cm-sec"><h2 class="cm-h">Tutors <span class="cm-n">' + ts.length + '</span></h2>' + (ts.length ? '<div class="card cm-list">' + ts.map(function (t) {
        return '<div class="cm-row cm-static"><span class="cm-main"><span class="cm-name">' + esc(t.name) + '</span><span class="cm-sub">' + esc(CP.reportSub(t)) + '</span></span></div>'; }).join("") + '</div>' :
        '<div class="card cm-block"><p class="cm-note">No lessons taught this month.</p></div>') + '</section>';
    $("tp-prev2").addEventListener("click", function () { month = CM.shiftMonth(month, -1); nav(); syncUrl(); loadTaught(); });
    $("tp-next2").addEventListener("click", function () { month = CM.shiftMonth(month, 1); nav(); syncUrl(); loadTaught(); });
  }

  // ---------------------------------------------------------------- tabs, wiring, start
  var TABS = ["pay", "rates", "taught"];
  function setTab(name, focus) {
    tab = TABS.indexOf(name) > -1 ? name : "pay";
    TABS.forEach(function (t) { var on = t === tab, b = $("tp-tab-" + t); $("tp-" + t).hidden = !on; b.setAttribute("aria-selected", on ? "true" : "false"); b.tabIndex = on ? 0 : -1; });
    if (focus) $("tp-tab-" + tab).focus();
    say("");
    if (tab === "pay") loadPay(); else if (tab === "rates") loadRates(); else loadTaught();
    syncUrl();
  }
  function wire() {
    TABS.forEach(function (t) { $("tp-tab-" + t).addEventListener("click", function () { setTab(t); }); });
    $("tp").querySelector(".cm-tabs").addEventListener("keydown", function (e) {
      if (e.key === "ArrowRight" || e.key === "ArrowLeft") { e.preventDefault(); setTab(TABS[(TABS.indexOf(tab) + (e.key === "ArrowRight" ? 1 : TABS.length - 1)) % TABS.length], true); }
    });
    $("tp-prev").addEventListener("click", function () { month = CM.shiftMonth(month, -1); syncUrl(); loadPay(); });
    $("tp-next").addEventListener("click", function () { month = CM.shiftMonth(month, 1); syncUrl(); loadPay(); });
    $("tp-paybody").addEventListener("click", function (e) { var r = e.target.closest("[data-t]"); if (r) return openTutor(+r.dataset.t, r); if (e.target.closest("#tp-csv")) return exportCsv(); });
    $("tp-rates").addEventListener("click", function (e) { var r = e.target.closest("[data-r]"); if (r) openRates(+r.dataset.r, r); });
    $("cm-sb").addEventListener("click", function (e) { var v = e.target.closest("[data-rev]"); if (v) reversePay(v.getAttribute("data-rev")); });
    $("cm-sx").addEventListener("click", closeSheet);
    $("cm-sheet").addEventListener("click", function (e) { if (e.target === $("cm-sheet")) closeSheet(); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && $("cm-sheet").classList.contains("on") && !document.querySelector(".td-dlg")) closeSheet(); });
  }
  async function init() {
    var q = new URLSearchParams(location.search), id = q.get("id"), o = TL.org ? TL.org() : null;
    if (!id) id = o && o.kind === "centre" ? o.id : null;
    if (!id) { location.replace("home"); return; }                                                     // a solo login has no centre pages
    if (o && o.kind === "centre" && o.id === id && o.role === "tutor") { location.replace("tutor"); return; }   // tutors never see this page
    orgId = id;
    var st = CM.fromQuery(location.search);
    month = st.month || CM.monthStart(localToday());
    wire(); nav();
    var r = await rpc("centre_tutor_rate_list", { p_org: orgId });                                      // also tells us the mode and whether this person may be here at all
    if (r.error) return fatal(r.error);
    rates = r.data; mode = rates.mode;
    var want = q.get("tab") === "rates" ? "rates" : q.get("tab") === "taught" ? "taught" : mode === "full" ? "pay" : "rates";
    setTab(want);
  }
  TL.requireAuth("centre-tutor-pay", init);
})();
