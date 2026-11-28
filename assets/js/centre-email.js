// Centre Money > Email (T7.3): the queue of emails going to families ("12 queued · sends over 2 days"), the send log, addresses that bounced, and a preview of the
// reminder schedule. Also the "Email invoice" form inside an invoice's side sheet (who gets it, send, send again).
// Every read and write goes through database functions (email_queue_status / _queue_list / _log_list / _enqueue / _enqueue_unsent / _queue_cancel / _bad_list /
// _clear_bad / _reminder_preview / _household_contacts / _set_billing_contacts); this page never touches a table and never sees a whole address (only j***@g***.com).
// Sending itself is the server's job: POST /api/email-send (it checks the caller again, keeps to the caps and talks to Brevo). Wording and rules live in
// assets/js/invoice-email-core.js and db/migration_invoice_email.sql. Whether email is on, who sends and the caps are the CENTRE's choice (Settings > Invoicing).
// Shares the tabs, the message line and the side sheet with assets/js/centre-money.js (window.CentreMoneyUI).
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var E = window.InvoiceEmailCore, CM = window.CentreMoneyCore, UI = null, esc = E.esc;
  var orgId = null, st = null, queue = [], log = [], bad = [], rem = null, filter = "waiting", built = false, busy = false, seq = 0, prefetching = null;

  function rpc(name, args) { return window.sb.rpc(name, args); }
  function toast(text) { try { TL.toast(text, "ok"); } catch (e) {} }
  function sheetMsg(text, isBad) { var m = $("ce-msg"); if (!m) return; m.textContent = text || ""; m.className = "cm-msg" + (text ? (isBad ? " err" : " ok") : ""); }
  function when(iso) {
    if (!iso) return "";
    try { return new Date(iso).toLocaleString("en-SG", { timeZone: "Asia/Singapore", day: "numeric", month: "short", hour: "numeric", minute: "2-digit", hour12: false }); } catch (e) { return String(iso).slice(0, 16).replace("T", " "); }
  }
  async function api(path, body) {
    var s = await window.sb.auth.getSession(), jwt = s && s.data && s.data.session && s.data.session.access_token;
    if (!jwt) return { ok: false, status: 401, data: null };
    try {
      var r = await fetch(path, { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + jwt }, body: JSON.stringify(body) });
      var d = null; try { d = await r.json(); } catch (e) {}
      return { ok: r.ok, status: r.status, data: d };
    } catch (e) { return { ok: false, status: 0, data: null }; }
  }
  // Ask the server to send what is due, then say what happened. `quiet` = no message line (a background nudge).
  async function sendNow(quiet) {
    var r = await api("/api/email-send", { org_id: orgId });
    if (r.status === 503) { if (!quiet) UI.say("Sending isn’t set up on this site yet (the email key is missing). Your messages are safe in the queue.", true); return null; }
    if (!r.ok) { if (!quiet) UI.say("Couldn’t send just now. The messages are still queued and will go in the next run.", true); return null; }
    if (!quiet) UI.say(E.sentLine(r.data), false);
    return r.data;
  }

  // ---------------------------------------------------------------- the tab
  function frame() {
    $("cm-mail").innerHTML = '<div class="card cm-sum" id="ce-sum"><div class="cm-sum-s">Loading…</div></div><div id="ce-bad"></div><div id="ce-queue"></div><div id="ce-rem"></div><div id="ce-log"></div>';
    $("ce-sum").addEventListener("click", function (e) {
      if (e.target.closest("#ce-all")) queueAll(); else if (e.target.closest("#ce-now")) pressNow();
    });
    $("ce-bad").addEventListener("click", function (e) { var b = e.target.closest("[data-clear]"); if (b) clearBad(b.dataset.clear, b); });
    $("ce-queue").addEventListener("click", function (e) {
      var f = e.target.closest("[data-f]"); if (f) { filter = f.dataset.f; drawQueue(); return; }
      var c = e.target.closest("[data-cancel]"); if (c) cancelOne(c.dataset.cancel, c);
    });
    built = true;
  }
  function modeText(s) {
    if (s.mode === "off") return "Email is off. You share invoices yourself, by copying the link or on WhatsApp. To email them, switch it on in the invoicing settings.";
    if (s.mode === "staff_send") return "A person sends invoices: open an invoice and press Email, or queue all unsent invoices here. Only the family’s billing contacts receive them, never tutors.";
    return "Invoices are emailed automatically to each family’s billing contacts the moment they are issued. Tutors never receive them.";
  }
  function onOff(v) { return v ? "on" : "off"; }
  function drawSummary() {
    var s = st, canSend = s.mode !== "off";
    var h = '<div class="cm-sum-t">Family email</div><div class="cm-sum-s">' + esc(E.queueLine(s)) + '</div><p class="cm-note">' + esc(modeText(s)) + '</p>';
    if (canSend) {
      h += '<p class="cm-note">Receipts: <b>' + onOff(s.receipts_on) + '</b> · Late-fee notices: <b>' + onOff(s.late_fee_notice_on) + '</b> · Payment reminders: <b>' + onOff(s.reminders_on) + '</b>. Up to ' + s.daily_cap +
        ' emails a day and ' + s.per_hour + ' an hour; a longer queue simply carries on the next day.</p>';
      h += '<div class="cm-acts">';
      if (s.queued > 0) h += '<button type="button" class="btn btn-primary" id="ce-now">Send now</button>';
      h += '<button type="button" class="btn' + (s.queued > 0 ? '' : ' btn-primary') + '" id="ce-all">Queue all unsent invoices</button></div>';
      if (!s.share_link) h += '<p class="cm-note err">The shareable invoice link is switched off, so nothing can be emailed. Switch it on in the invoicing settings.</p>';
    }
    h += '<div class="cm-acts"><a class="btn" href="' + esc("org?id=" + encodeURIComponent(orgId)) + '">Change email settings</a></div>';
    if (s.failed_24h) h += '<p class="cm-note warn">' + E.plural(s.failed_24h, "email", "emails") + ' failed in the last day (see the send log below).</p>';
    $("ce-sum").innerHTML = h;
  }
  function drawBad() {
    if (!bad.length) { $("ce-bad").innerHTML = ""; return; }
    $("ce-bad").innerHTML = '<section class="cm-sec"><h2 class="cm-h">Addresses that bounced <span class="cm-n">' + bad.length + '</span></h2>' +
      '<p class="cm-note">Nothing is sent to these until the address is corrected in the student’s family details (that clears it by itself), or you press “Fixed”.</p>' +
      '<div class="card cm-list">' + bad.map(function (b) {
        return '<div class="cm-row held"><span class="cm-main"><span class="cm-name">' + esc(b.family || "Family") + (b.name ? ' · ' + esc(b.name) : '') + '</span><span class="cm-sub warn">' + esc(b.to_masked) +
          (b.since ? ' · bounced ' + esc(when(b.since)) : '') + '</span></span><button type="button" class="btn cm-act" data-clear="' + esc(b.guardian_id) + '">Fixed</button></div>';
      }).join("") + '</div></section>';
  }
  var FILTERS = [["waiting", "Waiting"], ["sent", "Sent"], ["problems", "Not sent"], ["all", "All"]];
  function inFilter(q) {
    return filter === "all" ? true : filter === "waiting" ? (q.status === "queued" || q.status === "sending") : filter === "sent" ? q.status === "sent" : (q.status === "failed" || q.status === "skipped" || q.status === "cancelled");
  }
  function chip(status) { var tone = status === "sent" ? "ok" : status === "failed" ? "bad" : (status === "skipped" || status === "cancelled") ? "warn" : ""; return '<span class="cm-chip ' + tone + '">' + esc(E.STATUS_TEXT[status] || status) + '</span>'; }
  function drawQueue() {
    var rows = queue.filter(inFilter);
    var h = '<section class="cm-sec"><h2 class="cm-h">Messages <span class="cm-n">' + rows.length + '</span></h2><div class="cm-filters" role="group" aria-label="Show">' +
      FILTERS.map(function (f) { return '<button type="button" class="cm-f" data-f="' + f[0] + '" aria-pressed="' + (filter === f[0]) + '">' + f[1] + '</button>'; }).join("") + '</div>';
    if (!rows.length) h += '<div class="card cm-block"><p class="cm-note">' + (filter === "waiting" ? "Nothing is waiting to be sent." : "Nothing here yet.") + '</p></div>';
    else h += '<div class="card cm-list">' + rows.map(function (q) {
      var sub = [q.to_masked && q.to_masked !== "***" ? q.to_masked : "", q.reason ? E.reasonText(q.reason) : "", q.automatic ? "automatic" : (q.by ? "sent by " + q.by : ""), when(q.requested_at)].filter(Boolean).join(" · ");
      return '<div class="cm-row"><span class="cm-main"><span class="cm-name">' + esc(E.kindText(q.kind, q.reminder_no)) + (q.invoice_number ? ' · <span class="cm-no">' + esc(q.invoice_number) + '</span>' : '') +
        ' · ' + esc(q.family || "Family") + '</span><span class="cm-sub' + (q.status === "failed" ? ' warn' : '') + '">' + esc(sub) + '</span></span>' + chip(q.status) +
        (q.status === "queued" ? '<button type="button" class="btn cm-act" data-cancel="' + esc(q.id) + '" aria-label="Cancel this email">Cancel</button>' : '') + '</div>';
    }).join("") + '</div>';
    $("ce-queue").innerHTML = h + '</section>';
  }
  function drawRem() {
    if (!rem) { $("ce-rem").innerHTML = ""; return; }
    var r = { enabled: rem.enabled, first_after_days: rem.first_after_days, repeat_days: rem.repeat_days, max_count: rem.max_count };
    var h = '<section class="cm-sec"><h2 class="cm-h">Payment reminders</h2><div class="card cm-block"><p class="cm-note"><b>' + esc(E.reminderLine(r)) + '</b></p>';
    if (r.enabled) {
      var due = E.addDays(st.today, 7), dates = E.reminderDates(due, r);
      h += '<p class="cm-note">For example, an invoice due on ' + esc(E.dateText(due)) + ' is reminded on ' + dates.map(function (d) { return esc(E.dateText(d)); }).join(", ") + '. A reminder never goes out for an invoice that has been paid or credited, even if it was waiting in the queue.</p>' +
        '<p class="cm-note">Right now ' + E.plural(rem.overdue_invoices, "invoice is", "invoices are") + ' overdue and still owed (issued in the last 120 days); ' + (rem.due_now ? '<b>' + rem.due_now + '</b> will get a reminder in the next run.' : 'none is due a reminder yet.') + '</p>';
    } else h += '<p class="cm-note">' + (rem.mode === "off" ? "Email is off, so no reminders are sent." : "Switch reminders on in the invoicing settings if you want overdue invoices followed up by email.") + '</p>';
    $("ce-rem").innerHTML = h + '</div></section>';
  }
  function drawLog() {
    var h = '<section class="cm-sec"><h2 class="cm-h">Send log <span class="cm-n">' + log.length + '</span></h2>';
    if (!log.length) h += '<div class="card cm-block"><p class="cm-note">Nothing has been sent yet. Every email is written here: who asked, when, the address (hidden but for its first letters), which email and what happened.</p></div>';
    else h += '<div class="card cm-list">' + log.map(function (l) {
      var tone = l.result === "sent" ? "ok" : (l.result === "failed" || l.result === "bounced") ? "bad" : l.result === "retry" || l.result === "skipped" || l.result === "cancelled" ? "warn" : "";
      var sub = [l.to_masked && l.to_masked !== "***" ? l.to_masked : "", l.detail ? E.reasonText(l.detail) : "", l.attempt > 1 ? "try " + l.attempt : "", l.automatic ? "automatic" : (l.by ? l.by : ""), when(l.at)].filter(Boolean).join(" · ");
      return '<div class="cm-row cm-static"><span class="cm-main"><span class="cm-name">' + esc(E.kindText(String(l.template || l.kind).split(":")[0])) + (String(l.template || "").indexOf(":custom") > -1 ? ' <span class="cm-tag">own wording</span>' : '') +
        (l.invoice_number ? ' · <span class="cm-no">' + esc(l.invoice_number) + '</span>' : '') + '</span><span class="cm-sub">' + esc(sub) + '</span></span><span class="cm-chip ' + tone + '">' + esc(E.RESULT_TEXT[l.result] || l.result) + '</span></div>';
    }).join("") + '</div>';
    $("ce-log").innerHTML = h + '<p class="cm-foot">Emails go from noreply@tutordeck.com.sg with your centre’s name; replies go to your reply-to address. The log keeps only the first letter of each part of an address.</p></section>';
  }
  async function load(msg) {
    var mine = ++seq;
    var all = await Promise.all([rpc("email_queue_status", { p_org: orgId }), rpc("email_queue_list", { p_org: orgId, p_limit: 120 }), rpc("email_log_list", { p_org: orgId, p_limit: 60 }),
      rpc("email_bad_list", { p_org: orgId }), rpc("email_reminder_preview", { p_org: orgId })]);
    if (mine !== seq) return;
    if (all[0].error) return fail(all[0].error);
    st = all[0].data; queue = all[1].data || []; log = all[2].data || []; bad = all[3].data || []; rem = all[4].data || null;
    if (!st || typeof st !== "object") { $("cm-mail").innerHTML = '<div class="card cm-block"><h2 class="cm-h2">Couldn’t load family email</h2><p class="cm-note">Refresh the page and try again.</p></div>'; return; }
    drawSummary(); drawBad(); drawQueue(); drawRem(); drawLog();
    if (msg) UI.say(msg, false);
  }
  function fail(err) {
    var m = (err && err.message) || "";
    if (E.isMissing(err)) { $("cm-mail").innerHTML = '<div class="card cm-block"><h2 class="cm-h2">Not switched on yet</h2><p class="cm-note">Family email needs <b>db/migration_invoice_email.sql</b> to be run on this database first.</p></div>'; return; }
    if (/NOT_FOUND/.test(m)) { $("cm-mail").innerHTML = '<div class="card cm-block"><h2 class="cm-h2">Centre not available</h2><p class="cm-note">This centre doesn’t exist, or you aren’t an owner or staff member there.</p></div>'; return; }
    if (/NOT_ALLOWED/.test(m) && !st) { $("cm-mail").innerHTML = '<div class="card cm-block"><h2 class="cm-h2">Family email isn’t switched on for your account</h2><p class="cm-note">Ask the centre owner to give you the “Issue invoices” or “Record payments” permission.</p></div>'; return; }
    UI.say(E.errorText(err), true);
  }
  var waits = 0;
  function show() {
    UI = window.CentreMoneyUI; orgId = UI.orgId();
    if (!built) frame();
    // B8-FIX F1: clicked before the centre has loaded, the tab said "invalid input syntax for type uuid: "null"". Wait for the centre instead.
    if (!orgId || orgId === "null" || orgId === "undefined") {
      $("ce-sum").innerHTML = '<div class="cm-sum-s">Loading your centre…</div>';
      if (waits++ < 40) setTimeout(show, 250);
      else $("ce-sum").innerHTML = '<div class="cm-sum-t">Couldn’t load your centre</div><p class="cm-note">Refresh the page and try again.</p>';
      return;
    }
    waits = 0;
    load().then(function () { if (st && st.mode !== "off" && st.queued > 0 && st.remaining_today > 0) { /* the queue has room today: a gentle nudge so nothing waits for tomorrow's job */ sendNow(true).then(function (r) { if (r && r.sent) load(); }); } });
  }

  // ---------------------------------------------------------------- the buttons
  async function pressNow() {
    if (busy) return; busy = true; var b = $("ce-now"); if (b) b.disabled = true;
    var r = await sendNow(false); busy = false;
    await load(r ? E.sentLine(r) : null);
  }
  async function queueAll() {
    if (busy) return;
    if (!(await TL.confirm({ title: "Queue all unsent invoices?", message: "Every issued invoice from the last 45 days that hasn’t been emailed yet goes to its family’s billing contacts. A long list is sent over several days if it is over your daily limit.", confirmText: "Queue them" }))) return;
    busy = true; var b = $("ce-all"); if (b) b.disabled = true;
    var r = await rpc("email_enqueue_unsent", { p_org: orgId });
    if (r.error) { busy = false; if (b) b.disabled = false; return UI.say(E.errorText(r.error), true); }
    var d = r.data || {}, text = d.queued ? E.plural(d.queued, "email", "emails") + " queued." : "Nothing new to queue.";
    if (d.skipped) text += " " + E.plural(d.skipped, "invoice wasn’t", "invoices weren’t") + " queued (" + problemSummary(d.problems) + ").";
    var s = d.queued ? await sendNow(true) : null; busy = false;
    toast(text); await load(text + (s && s.sent ? " " + E.sentLine(s) : ""));
  }
  function problemSummary(problems) {
    var by = {}; (problems || []).forEach(function (p) { by[p.reason] = (by[p.reason] || 0) + 1; });
    return Object.keys(by).map(function (k) { return by[k] + " " + E.reasonText(k).toLowerCase(); }).join(", ");
  }
  async function cancelOne(id, btn) {
    if (busy) return;
    if (!(await TL.confirm({ title: "Cancel this email?", message: "It won’t be sent. You can queue the invoice again later.", confirmText: "Cancel the email", danger: true }))) return;
    busy = true; if (btn) btn.disabled = true;
    var r = await rpc("email_queue_cancel", { p_org: orgId, p_ids: [id] }); busy = false;
    if (r.error) { if (btn) btn.disabled = false; return UI.say(E.errorText(r.error), true); }
    await load(r.data && r.data.cancelled ? "Email cancelled." : "It had already gone.");
  }
  async function clearBad(id, btn) {
    if (busy) return; busy = true; if (btn) btn.disabled = true;
    var r = await rpc("email_clear_bad", { p_org: orgId, p_guardian: id }); busy = false;
    if (r.error) { if (btn) btn.disabled = false; return UI.say(E.errorText(r.error), true); }
    await load("The address will be used again.");
  }

  // ---------------------------------------------------------------- the invoice's side sheet: "Email invoice"
  // a = the invoice's account (centre_invoice_account_get), back() redraws the invoice detail, done(msg) reopens it with a message
  async function invoiceForm(a, back, done) {
    UI = window.CentreMoneyUI; orgId = UI.orgId();
    $("cm-sm").textContent = a.number + " · Email invoice";
    $("cm-sb").innerHTML = '<div class="cm-msg" id="ce-msg" role="status" aria-live="polite"></div><p class="cm-note">Loading who gets it…</p>';
    var r = await rpc("email_household_contacts", { p_org: orgId, p_household: a.household_id });
    if (r.error) { $("cm-sb").innerHTML = '<div class="cm-msg err" id="ce-msg">' + esc(E.errorText(r.error)) + '</div><div class="cm-acts col"><button type="button" class="btn" id="ce-back">Back</button></div>'; $("ce-back").addEventListener("click", back); return; }
    var c = r.data || { guardians: [] }, gs = c.guardians || [];
    var rows = gs.map(function (g, i) {
      var note = !g.has_email ? "No email address" : g.bad ? "Bounced: not used" : g.receives ? "Gets this email" : "";
      return '<label class="ce-chk"><input type="checkbox" data-g="' + esc(g.id) + '"' + (g.billing_contact ? ' checked' : '') + '><span class="cm-main"><span class="cm-name">' + esc(g.name || "Parent or guardian") +
        (g.relation ? ' <span class="cm-sub">(' + esc(g.relation) + ')</span>' : '') + '</span><span class="cm-sub' + (!g.has_email || g.bad ? ' warn' : '') + '">' + esc(g.to_masked || "") + (g.to_masked && note ? ' · ' : '') + esc(note) + '</span></span></label>';
    }).join("");
    var willGo = gs.filter(function (g) { return g.receives; });
    $("cm-sb").innerHTML = '<div class="cm-msg" id="ce-msg" role="status" aria-live="polite"></div>' +
      '<h2 class="cm-h2">Who gets invoices by email</h2>' +
      (gs.length ? '<div class="card cm-list ce-contacts">' + rows + '</div>' : '<p class="cm-note err">This family has no parent or guardian saved, so there is nobody to email. Add one in the student’s family details.</p>') +
      '<p class="cm-note">Tick the billing contacts for this family. If none is ticked, the first parent or guardian is used.</p>' +
      '<div class="cm-acts col">' +
      '<button type="button" class="btn btn-primary" id="ce-send"' + (willGo.length ? '' : ' disabled') + '>Email invoice ' + esc(a.number) + (willGo.length ? ' to ' + E.plural(willGo.length, "person", "people") : '') + '</button>' +
      '<button type="button" class="btn quiet" id="ce-save">Save billing contacts</button><button type="button" class="btn quiet" id="ce-back">Back to the invoice</button></div>' +
      '<p class="cm-note">The email carries a secure link to this one invoice, in your centre’s name, with your own wording if you set it. It never contains lessons or student details.</p>';
    function chosen() { return Array.prototype.map.call($("cm-sb").querySelectorAll("[data-g]:checked"), function (x) { return x.dataset.g; }); }
    async function saveContacts() {
      var rr = await rpc("email_set_billing_contacts", { p_org: orgId, p_household: a.household_id, p_guardians: chosen() });
      if (rr.error) { sheetMsg(E.errorText(rr.error), true); return false; }
      return true;
    }
    $("ce-back").addEventListener("click", back);
    $("ce-save").addEventListener("click", async function () { if (busy) return; busy = true; var ok = await saveContacts(); busy = false; if (ok) invoiceForm(a, back, done); });
    $("ce-send").addEventListener("click", async function () {
      if (busy) return;
      busy = true; $("ce-send").disabled = true; sheetMsg("Queuing the email…", false);      // B8-FIX F3: always say what is happening, and never leave the button stuck
      var queued = 0;
      try {
        if (!(await saveContacts())) { $("ce-send").disabled = false; return; }
        var q = await rpc("email_enqueue", { p_org: orgId, p_invoices: [a.id], p_resend: false });
        if (!q.error && q.data && !q.data.queued && q.data.problems && q.data.problems[0] && q.data.problems[0].reason === "already_sent") {
          busy = false;
          if (!(await TL.confirm({ title: "Send it again?", message: "This invoice was already emailed or queued. Send it again to the same people?", confirmText: "Send again" }))) { $("ce-send").disabled = false; sheetMsg("", false); return; }
          busy = true; sheetMsg("Queuing the email…", false); q = await rpc("email_enqueue", { p_org: orgId, p_invoices: [a.id], p_resend: true });
        }
        if (q.error) { $("ce-send").disabled = false; return sheetMsg(E.errorText(q.error), true); }
        var d = q.data || {};
        if (!d.queued) { $("ce-send").disabled = false; return sheetMsg(d.problems && d.problems[0] ? E.reasonText(d.problems[0].reason) + "." : "Nothing was queued: this family has no parent or guardian with an email address.", true); }
        queued = d.queued;
        sheetMsg(E.queuedText(queued), false);                              // shown at once, before the send attempt
        toast("Email queued");
        await sendNow(true);                                                 // the server sends whatever is due now, within the caps; this invoice is in the queue either way
      } catch (err) {
        if (!queued) { $("ce-send").disabled = false; sheetMsg("Couldn’t queue the email just now. Try again.", true); }
      } finally {
        busy = false;
        if (queued) { filter = "waiting"; if (built) load(); }                // the Email tab shows it waiting
      }
    });
  }
  // the invoice sheet asks this to decide whether to show the "Email invoice" button
  function prefetch() {
    if (prefetching) return prefetching;
    UI = window.CentreMoneyUI; orgId = UI && UI.orgId();
    if (!orgId) return Promise.resolve(null);
    prefetching = rpc("email_queue_status", { p_org: orgId }).then(function (r) { if (!r.error && r.data) st = st || r.data; return r.data || null; }, function () { return null; });
    return prefetching;
  }
  window.CentreEmail = { show: show, refresh: function () { return built ? load() : null; }, invoiceForm: invoiceForm, prefetch: prefetch,
    on: function () { return !!(st && st.mode && st.mode !== "off" && st.share_link !== false); } };
})();
