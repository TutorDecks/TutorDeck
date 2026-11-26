// Centre Money > Deposits (T4 step S4): the refundable deposits a centre holds for families — the "Deposits held" total, one row per student, one
// student's ledger in the side sheet, waive (with a reason) and, for the owner, an opening balance for a deposit collected before TutorDeck.
// Every read and write goes through database functions (centre_deposit_status, centre_deposits_held, centre_deposit_ledger_get, centre_deposit_waive,
// centre_deposit_opening_balance, staff_students for the student picker); this page never touches a table. Who may, what is allowed and every number are
// decided there (db/migration_centre_deposits.sql); assets/js/centre-deposits-core.js only words the answers.
// Shares the tabs, the message line and the side sheet with assets/js/centre-money.js (window.CentreMoneyUI). Deposits are money the centre holds for
// families: they are never income and never counted in a revenue figure.
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var CD = window.CentreDepositsCore, CM = window.CentreMoneyCore, UI = null, esc = function (s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var orgId = null, data = null, held = null, query = "", seq = 0, built = false, busy = false, cur = null, today = "", isOwner = null;

  function rpc(name, args) { return window.sb.rpc(name, args); }
  function chip(state) { var c = CD.stateChip(state); return '<span class="cm-chip ' + c.tone + '">' + esc(c.text) + '</span>'; }
  function toast(text) { try { TL.toast(text, "ok"); } catch (e) {} }

  // ---------------------------------------------------------------- the list
  function frame() {
    $("cm-dep").innerHTML = '<div class="card cm-sum" id="cd-sum"><div class="cm-sum-s">Loading…</div></div>' +
      '<input class="cm-search" id="cd-q" type="search" placeholder="Search by student, family or invoice number" aria-label="Search deposits" autocomplete="off">' +
      '<div id="cd-list" aria-live="polite"></div><div id="cd-foot"></div>';
    $("cd-q").addEventListener("input", function (e) { query = e.target.value; drawList(); });
    $("cd-list").addEventListener("click", function (e) { var r = e.target.closest("[data-i]"); if (r) open(data.rows[+r.dataset.i].student_id, r); });
    $("cd-foot").addEventListener("click", function (e) { if (e.target.closest("#cd-open")) openingForm(e.target.closest("#cd-open")); });
    built = true;
  }
  function drawSummary() {
    var t = data.totals || {}, h = (held && held.total_held_cents) || 0;
    $("cd-sum").innerHTML = '<div class="cm-sum-s">Deposits held</div><div class="cm-sum-t cd-big" id="cd-held">' + esc(CM.money(h)) + '</div>' +
      '<div class="cm-sum-s">' + esc(CD.summaryLine(t)) + (CD.shortLine(t) ? ' · ' + esc(CD.shortLine(t)) : '') + '</div>' +
      '<p class="cm-note">Money held for families. It isn’t income and is never counted in your revenue.' +
      (held && held.taxable_held_cents > 0 ? ' ' + esc(CM.money(held.taxable_held_cents)) + ' of it was taxable when received.' : '') + '</p>';
  }
  function drawList() {
    var rows = CD.searchRows(data.rows, query);
    $("cd-list").innerHTML = !data.rows.length ? '<div class="card cm-block"><p class="cm-note">' + esc(CD.emptyText()) + '</p></div>' :
      !rows.length ? '<div class="card cm-block"><p class="cm-note">No deposit matches that search.</p></div>' :
      '<div class="card cm-list">' + rows.map(function (x) {
        var i = data.rows.indexOf(x);
        return '<button type="button" class="cm-row" data-i="' + i + '"><span class="cm-main"><span class="cm-name">' + esc(x.name) + '</span>' +
          '<span class="cm-sub' + (x.state === "unpaid" || x.state === "part_paid" ? ' warn' : '') + '">' + esc(CD.rowSub(x)) + '</span></span>' + chip(x.state) +
          '<span class="cm-amt">' + esc(CM.money(CD.rowAmount(x))) + '</span>' + UI.chev() + '</button>';
      }).join("") + '</div>';
    $("cd-foot").innerHTML = isOwner ? '<p class="cm-foot">Collected a deposit before using TutorDeck? <button type="button" class="cm-link" id="cd-open">Add an opening balance</button></p>' : '';
  }
  async function load(msg) {
    var mine = ++seq;
    var st = await rpc("centre_deposit_status", { p_org: orgId, p_student: null });
    var hd = await rpc("centre_deposits_held", { p_org: orgId });
    if (mine !== seq) return;
    if (st.error) return fail(st.error);
    if (!st.data || typeof st.data !== "object" || !st.data.rows) { data = null; $("cm-dep").innerHTML = '<div class="card cm-block"><h2 class="cm-h2">Couldn’t load deposits</h2><p class="cm-note">Refresh the page and try again.</p></div>'; return; }
    data = st.data; held = hd.error ? null : hd.data; today = data.today || today;
    drawSummary(); drawList();
    if (msg) UI.say(msg, false);
  }
  function fail(err) {
    if (CD.isMissing(err)) { $("cm-dep").innerHTML = '<div class="card cm-block"><h2 class="cm-h2">Not switched on yet</h2><p class="cm-note">Deposits need <b>db/migration_centre_deposits.sql</b> run first.</p></div>'; return; }
    var m = (err && err.message) || "";
    if (/NOT_FOUND/.test(m)) { $("cm-dep").innerHTML = '<div class="card cm-block"><h2 class="cm-h2">Centre not available</h2><p class="cm-note">This centre doesn’t exist, or you aren’t an owner or staff member there.</p></div>'; return; }
    if (/NOT_ALLOWED/.test(m) && !data) { $("cm-dep").innerHTML = '<div class="card cm-block"><h2 class="cm-h2">Deposits aren’t switched on for your account</h2><p class="cm-note">Ask the centre owner to give you the “Record payments” or “View revenue” permission.</p></div>'; return; }
    UI.say(CD.errorText(err), true);
  }
  async function detectOwner() {
    if (isOwner != null) return;
    var o = TL.org ? TL.org() : null;
    isOwner = !!(o && o.id === orgId && o.role === "owner");
  }
  async function show() {
    UI = window.CentreMoneyUI; orgId = UI.orgId();
    await detectOwner();
    if (!built) frame();
    load();
  }

  // ---------------------------------------------------------------- one student's deposit
  function sheetMsg(text, bad) { var m = $("cd-msg"); if (!m) return; m.textContent = text || ""; m.className = "cm-msg" + (text ? (bad ? " err" : " ok") : ""); }
  function groupHtml(title, inner) { return '<div class="cm-g"><div class="cm-gh">' + esc(title) + '</div>' + inner + '</div>'; }
  async function open(studentId, trigger, msg) {
    $("cm-st").textContent = "Deposit"; $("cm-sm").textContent = "";
    if (trigger !== true) { $("cm-sb").innerHTML = '<p class="cm-note">Loading…</p>'; UI.openSheet(trigger); }
    var r = await rpc("centre_deposit_ledger_get", { p_org: orgId, p_student: studentId });
    if (r.error) { $("cm-sb").innerHTML = '<p class="cm-note err">' + esc(CD.errorText(r.error)) + '</p>'; return; }
    cur = r.data; render(msg);
  }
  function render(msg) {
    var d = cur, s = d.status || {}, c = CD.stateChip(s.state);
    $("cm-st").textContent = d.name; $("cm-sm").textContent = (s.household_name ? s.household_name + " · " : "") + c.text;
    var h = '<div class="cm-msg" id="cd-msg" role="status" aria-live="polite"></div>';
    h += '<div class="cm-tot"><div><span>Required</span><span>' + esc(CM.money(s.required_cents)) + '</span></div>' +
         '<div><span>Held now</span><span>' + esc(CM.money(s.held_cents)) + '</span></div>' +
         (s.waived_cents ? '<div><span>Waived</span><span>' + esc(CM.money(s.waived_cents)) + '</span></div>' : '') +
         (s.short_cents ? '<div class="big"><span>Still to collect</span><span>' + esc(CM.money(s.short_cents)) + '</span></div>' : '<div class="big"><span>Held for the family</span><span>' + esc(CM.money(s.held_cents)) + '</span></div>') + '</div>';
    h += '<div class="cm-facts"><div><span>How</span><span>' + esc(CD.basisText(s)) + '</span></div>' +
         (s.invoice_number ? '<div><span>Invoice</span><span>' + esc(s.invoice_number) + (s.due_date ? ' · due ' + esc(CM.shortDate(s.due_date)) : '') + '</span></div>' : '') +
         (s.taxable ? '<div><span>Tax</span><span>Taxable when received</span></div>' : '') + '</div>';
    if ((d.entries || []).length) {
      h += groupHtml("History", d.entries.map(function (e) {
        return '<div class="cm-pay"><span class="cm-ld">' + esc(CD.entryLine(e)) + (e.reason ? '<span class="cm-sub"> ' + esc(e.reason) + '</span>' : '') + '</span>' +
          '<span class="cm-la' + (e.kind === "waived" ? '' : e.cents < 0 ? ' neg' : '') + '">' + esc(CD.entryAmount(e)) + '</span></div>';
      }).join(""));
    } else h += '<p class="cm-note">Nothing has been received yet.</p>';
    var acts = '';
    if (s.invoice_id && s.invoice_status === "issued" && window.CentrePay && s.state !== "waived") acts += '<button type="button" class="btn btn-primary" id="cd-inv">' + (s.short_cents > 0 ? 'Open the invoice to record a payment' : 'Open the invoice') + '</button>';
    if (CD.canWaive(s)) acts += '<button type="button" class="btn" id="cd-waive">Waive this deposit</button>';
    h += acts ? '<div class="cm-acts col">' + acts + '</div>' : '';
    h += '<p class="cm-note">A deposit is held for the family and can’t be edited. A mistake is corrected with a new entry, never by changing an old one.</p>';
    $("cm-sb").innerHTML = h; sheetMsg(msg && msg.text, msg && msg.bad);
    var b = function (id, fn) { var e = $(id); if (e) e.addEventListener("click", fn); };
    b("cd-waive", waive);
    b("cd-inv", function () { window.CentrePay.open(s.invoice_id, $("cd-inv")); });
  }
  async function waive() {
    if (busy) return;
    var s = cur.status, q = CD.waiveQuestion(s);
    var why = await TL.prompt({ title: q.title, message: q.message, placeholder: q.placeholder, confirmText: "Waive deposit", danger: true });
    if (!why) return;
    busy = true;
    var r = await rpc("centre_deposit_waive", { p_student: s.student_id, p_reason: why });
    busy = false;
    if (r.error) return sheetMsg(CD.errorText(r.error), true);
    var text = CD.waivedText(r.data); toast(text); open(s.student_id, true, { text: text }); load(); if (UI.refreshRun) UI.refreshRun();
  }

  // ---------------------------------------------------------------- opening balance (owner)
  var pick = null, results = [];
  function openingForm(trigger) {
    pick = null; results = [];
    $("cm-st").textContent = "Opening balance"; $("cm-sm").textContent = "A deposit collected before TutorDeck";
    $("cm-sb").innerHTML = '<p class="cm-note">No invoice is made and no invoice number is used. The money is recorded as held, outside your revenue.</p>' +
      '<form id="cd-form" novalidate>' +
      '<div class="cm-fld"><label for="cd-find">Student</label><input id="cd-find" type="search" autocomplete="off" placeholder="Search by name" aria-describedby="cd-found"><div id="cd-found" class="cm-list card" aria-live="polite" hidden></div><p class="cm-hint" id="cd-picked"></p></div>' +
      '<div class="cm-fld"><label for="cd-amt">Amount held (S$)</label><input id="cd-amt" inputmode="decimal" autocomplete="off"></div>' +
      '<div class="cm-fld"><label for="cd-date">Date it was collected</label><input id="cd-date" type="date" value="' + esc(today) + '" max="' + esc(today) + '"></div>' +
      '<div class="cm-fld"><label for="cd-note">Note (optional)</label><input id="cd-note" maxlength="300" autocomplete="off"><p class="cm-hint">For example “paid by PayNow in January”. Never a full bank account number.</p></div>' +
      '<p class="cm-hint err" id="cd-err" role="alert"></p>' +
      '<div class="cm-acts col"><button type="submit" class="btn btn-primary" id="cd-go">Record opening balance</button><button type="button" class="btn" id="cd-cancel">Cancel</button></div></form>';
    UI.openSheet(trigger);
    $("cd-cancel").addEventListener("click", UI.closeSheet);
    var timer = null;
    $("cd-find").addEventListener("input", function () { clearTimeout(timer); timer = setTimeout(find, 250); });
    $("cd-found").addEventListener("click", function (e) {
      var b = e.target.closest("[data-s]"); if (!b) return;
      pick = results[+b.dataset.s]; $("cd-picked").textContent = "Selected: " + pick.name + (pick.household_name ? " (" + pick.household_name + ")" : ""); $("cd-found").hidden = true; $("cd-find").value = pick.name;
    });
    $("cd-form").addEventListener("submit", submitOpening);
    $("cd-find").focus();
  }
  async function find() {
    var q = $("cd-find").value.trim(), box = $("cd-found");
    if (q.length < 2) { box.hidden = true; return; }
    var r = await rpc("staff_students", { p_org: orgId, p_q: q, p_filter: "all", p_page: 1, p_size: 8 });
    if (r.error) { box.hidden = false; box.innerHTML = '<p class="cm-note err">' + esc(CD.errorText(r.error)) + '</p>'; return; }
    results = (r.data && r.data.rows) || [];
    box.hidden = false;
    box.innerHTML = results.length ? results.map(function (x, i) {
      return '<button type="button" class="cm-row" data-s="' + i + '"><span class="cm-main"><span class="cm-name">' + esc(x.name) + '</span><span class="cm-sub">' + esc(x.household_name || x.level || "") + '</span></span></button>';
    }).join("") : '<p class="cm-note">No student found.</p>';
  }
  async function submitOpening(e) {
    e.preventDefault(); if (busy) return;
    var c = CD.checkOpening({ studentId: pick && pick.id, amountText: $("cd-amt").value, date: $("cd-date").value, today: today, note: $("cd-note").value });
    if (!c.ok) { $("cd-err").textContent = c.error; return; }
    $("cd-err").textContent = ""; busy = true; $("cd-go").disabled = true;
    var r = await rpc("centre_deposit_opening_balance", { p_student: pick.id, p_amount_cents: c.cents, p_date: $("cd-date").value, p_note: c.note });
    busy = false;
    if (r.error) { $("cd-go").disabled = false; $("cd-err").textContent = CD.errorText(r.error); return; }
    var text = CD.openingText(pick.name, c.cents); toast(text); UI.closeSheet(); load(text);
  }

  window.CentreDeposits = { show: show, open: function (id, trigger) { UI = window.CentreMoneyUI; orgId = UI.orgId(); return open(id, trigger); } };
})();
