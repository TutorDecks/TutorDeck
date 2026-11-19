// Centre settings — everything a tuition centre customises without code changes:
// branding, fees & GST, billing rules (prepay / postpay / hybrid), tutor pay, the payout rule,
// team & roles (permission matrix), custom fields, invoice template, and the audit log.
// Needs db/migration_centres.sql. All money rules are enforced in the database; this page only edits data.
(function () {
  var B = window.BillingCore;
  var $ = function (id) { return document.getElementById(id); };
  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }
  function money(n) { return "$" + B.round2(n).toFixed(2); }
  function num(v) { var n = parseFloat(v); return isFinite(n) ? n : null; }
  function sel(opts, val) { return opts.map(function (o) { return '<option value="' + esc(o[0]) + '"' + (String(o[0]) === String(val == null ? "" : val) ? " selected" : "") + ">" + esc(o[1]) + "</option>"; }).join(""); }
  function sb() { return window.sb; }

  var S = { centre: null, me: null, perms: {}, roles: [], members: [], policies: [], prices: [], pay: [], fields: [], tab: "centre" };
  var TABS = [["centre", "Centre"], ["fees", "Fees & GST"], ["billing", "Billing rules"], ["pay", "Tutor pay"],
              ["team", "Team & roles"], ["fields", "Fields"], ["invoice", "Invoice"], ["audit", "Audit log"]];
  function can(p) { return !!(S.perms.__owner || S.perms[p]); }
  function missing(err) { return err && (err.code === "42P01" || err.code === "PGRST205" || err.code === "42883" || /does not exist|Could not find/i.test(err.message || "")); }

  // ------------------------------------------------------------------ load
  async function init() {
    try { await sb().rpc("td_claim_invites"); } catch (e) {}     // link any centre invite sent to this email
    var r = await sb().from("centres").select("*").order("created_at").limit(1);
    if (r.error) return missing(r.error) ? notSetUp() : fail(r.error);
    if (!r.data.length) return noCentre();
    S.centre = r.data[0];
    var tab = (location.hash || "").slice(1);
    if (TABS.some(function (t) { return t[0] === tab; })) S.tab = tab;
    await loadAll();
    render();
  }

  async function loadAll() {
    var c = S.centre.id, uid = TL.uid();
    var q = await Promise.all([
      sb().from("centre_roles").select("*").eq("centre_id", c).order("sort"),
      sb().from("centre_members").select("*").eq("centre_id", c).order("created_at"),
      sb().from("billing_policies").select("*").eq("centre_id", c).eq("archived", false).order("created_at"),
      sb().from("centre_price_list").select("*").eq("centre_id", c),
      sb().from("tutor_pay_rules").select("*").eq("centre_id", c).order("created_at"),
      sb().from("centre_fields").select("*").eq("centre_id", c).order("sort")
    ]);
    S.roles = q[0].data || []; S.members = q[1].data || []; S.policies = q[2].data || [];
    S.prices = q[3].data || []; S.pay = q[4].data || []; S.fields = q[5].data || [];
    S.me = S.members.filter(function (m) { return m.user_id === uid; })[0] || null;
    var role = S.me && S.roles.filter(function (r) { return r.id === S.me.role_id; })[0];
    S.perms = {};
    if (role) { if (role.key === "owner") S.perms.__owner = true; (role.permissions || []).forEach(function (p) { S.perms[p] = true; }); }
  }

  function fail(err) { $("cs").innerHTML = '<div class="card cs-card"><p class="cs-err">Couldn’t load: ' + esc(err.message) + "</p></div>"; }
  function notSetUp() {
    $("cs").innerHTML = '<div class="card cs-card cs-empty"><h2>Centre mode isn’t switched on yet</h2>' +
      '<p class="cs-sub">The database needs <b>db/migration_centres.sql</b> run in the Supabase SQL editor first.</p></div>';
  }
  function noCentre() {
    $("cs").innerHTML = '<div class="card cs-card cs-empty"><h2>Run a tuition centre?</h2>' +
      '<p class="cs-sub">Set up your centre to add staff and tutors, bill families by package or by month, and pay tutors once parents have paid. ' +
      'Your own TutorDeck (students, ledger, invoices) stays exactly as it is.</p>' +
      '<div class="field" style="max-width:340px;margin:0 auto 14px;text-align:left"><label for="cn">Centre name</label><input id="cn" type="text" maxlength="80" placeholder="e.g. Opus Tuition"></div>' +
      '<button class="btn btn-primary" id="cn-go">Create centre</button><p class="msg" id="cn-msg"></p></div>';
    $("cn-go").onclick = async function () {
      var name = $("cn").value.trim();
      if (!name) { $("cn").focus(); return; }
      $("cn-go").disabled = true;
      var r = await sb().rpc("td_create_centre", { p_name: name });
      if (r.error) { $("cn-go").disabled = false; $("cn-msg").textContent = r.error.message; $("cn-msg").className = "msg err"; return; }
      init();
    };
  }

  // ------------------------------------------------------------------ shell
  function render() {
    var h = '<div class="cs-tabs" role="tablist">' + TABS.map(function (t) {
      return '<button role="tab" data-tab="' + t[0] + '" class="' + (S.tab === t[0] ? "on" : "") + '" aria-selected="' + (S.tab === t[0]) + '">' + t[1] + "</button>";
    }).join("") + '</div><div id="cs-body"></div>';
    $("cs").innerHTML = h;
    $("cs").querySelectorAll("[data-tab]").forEach(function (b) {
      b.onclick = function () { S.tab = b.getAttribute("data-tab"); history.replaceState(null, "", "#" + S.tab); render(); };
    });
    ({ centre: tabCentre, fees: tabFees, billing: tabBilling, pay: tabPay, team: tabTeam, fields: tabFields, invoice: tabInvoice, audit: tabAudit })[S.tab]();
  }
  function card(title, sub, inner) { return '<section class="card cs-card"><h2>' + esc(title) + "</h2>" + (sub ? '<p class="cs-sub">' + sub + "</p>" : "") + inner + "</section>"; }
  function saveBar(id, label, perm) {
    return '<div class="cs-save"><div class="msg" id="' + id + '-msg"></div>' +
      (can(perm) ? '<button class="btn btn-primary" id="' + id + '">' + esc(label || "Save changes") + "</button>" : '<span class="muted" style="font-size:13px">View only</span>') + "</div>";
  }
  function say(id, text, ok) { var m = $(id + "-msg"); if (m) { m.textContent = text; m.className = "msg " + (ok ? "ok" : "err"); } }
  function field(id, label, val, attrs) { return '<div class="field"><label for="' + id + '">' + label + '</label><input id="' + id + '" value="' + esc(val == null ? "" : val) + '" ' + (attrs || 'type="text"') + "></div>"; }
  function check(id, label, on) { return '<label class="cs-check"><input type="checkbox" id="' + id + '"' + (on ? " checked" : "") + "> " + label + "</label>"; }
  function setts() { return S.centre.settings || {}; }

  async function saveCentre(patch, id) {
    var r = await sb().from("centres").update(patch).eq("id", S.centre.id).select("*").single();
    if (r.error) { say(id, r.error.message); return false; }
    S.centre = r.data; say(id, "Saved ✓", true); return true;
  }

  // ------------------------------------------------------------------ Centre
  function tabCentre() {
    var s = setts(), br = s.branding || {}, ct = s.contact || {}, pn = s.paynow || {}, bk = s.bank || {};
    $("cs-body").innerHTML =
      card("Centre", "How your centre appears to parents on invoices and messages.",
        '<div class="cs-row">' + field("c-name", "Centre name", S.centre.name, 'type="text" maxlength="80"') +
          field("c-disp", 'Name on invoices <span class="opt">Optional</span>', br.display_name, 'type="text" maxlength="60" placeholder="Same as centre name"') + "</div>" +
        '<div class="cs-row">' + field("c-logo", 'Logo link <span class="opt">Optional</span>', br.logo_url, 'type="url" placeholder="https://…/logo.png"') +
          field("c-col", "Invoice colour", br.color || "#0F766E", 'type="color" style="height:44px;padding:4px"') + "</div>" +
        '<div class="cs-row3">' + field("c-mail", "Email", ct.email, 'type="email"') + field("c-tel", "Phone", ct.phone, 'type="tel"') + field("c-uen", 'UEN <span class="opt">Optional</span>', ct.uen) + "</div>" +
        field("c-addr", 'Address <span class="opt">Optional</span>', ct.address)) +
      card("Getting paid", "Shown on invoices until card payments (Stripe) are switched on.",
        '<div class="cs-row"><div class="field"><label for="c-pt">PayNow type</label><select id="c-pt">' + sel([["uen", "UEN"], ["mobile", "Mobile number"]], pn.type || "uen") + "</select></div>" +
          field("c-pid", "PayNow ID", pn.id) + "</div>" +
        '<div class="cs-row">' + field("c-bn", 'Bank <span class="opt">Optional</span>', bk.bank_name) + field("c-ba", 'Account number <span class="opt">Optional</span>', bk.account_no) + "</div>" +
        field("c-bh", 'Account holder <span class="opt">Optional</span>', bk.account_name)) +
      saveBar("c-save", "Save", "settings.edit");
    if ($("c-save")) $("c-save").onclick = function () {
      var name = $("c-name").value.trim(); if (!name) { say("c-save", "Centre name can’t be empty."); return; }
      var s2 = Object.assign({}, setts(), {
        branding: Object.assign({}, setts().branding, { display_name: $("c-disp").value.trim() || null, logo_url: $("c-logo").value.trim() || null, color: $("c-col").value }),
        contact: { email: $("c-mail").value.trim(), phone: $("c-tel").value.trim(), uen: $("c-uen").value.trim(), address: $("c-addr").value.trim() },
        paynow: { type: $("c-pt").value, id: $("c-pid").value.trim() },
        bank: { bank_name: $("c-bn").value.trim(), account_no: $("c-ba").value.trim(), account_name: $("c-bh").value.trim() }
      });
      saveCentre({ name: name, settings: s2 }, "c-save");
    };
  }

  // ------------------------------------------------------------------ Fees & GST
  var priceRows = null;
  function tabFees() {
    priceRows = S.prices.map(function (p) { return Object.assign({}, p); });
    var c = S.centre;
    $("cs-body").innerHTML =
      card("GST", "If your centre is GST-registered, every invoice line gets GST and invoices show your registration number.",
        check("g-on", "GST-registered", c.gst_registered) +
        '<div class="cs-row3" id="g-more">' + field("g-rate", "GST rate (%)", c.gst_rate, 'type="number" min="0" max="50" step="0.01"') +
          '<div class="field"><label for="g-inc">Your prices</label><select id="g-inc">' + sel([["false", "Exclude GST (add on top)"], ["true", "Include GST"]], String(c.gst_inclusive)) + "</select></div>" +
          field("g-no", "GST reg. no.", c.gst_reg_no) + "</div>" +
        field("g-pre", "Invoice number prefix", c.invoice_prefix, 'type="text" maxlength="8"')) +
      card("Price list", "Default fee for a lesson. A class can set its own fee; the most specific row here wins (subject + level + type beats subject only). Leave a cell blank for “any”.",
        '<div class="cs-scroll"><table class="cs-grid"><thead><tr><th>Subject</th><th>Level</th><th>Type</th><th>Charged</th><th>Amount ($)</th><th></th></tr></thead><tbody id="pl"></tbody></table></div>' +
        '<button class="btn cs-add" id="pl-add">+ Add price</button><div class="cs-preview" id="pl-prev"></div>') +
      saveBar("f-save", "Save", "settings.edit");
    drawPrices();
    $("g-on").onchange = function () { $("g-more").style.opacity = $("g-on").checked ? 1 : .45; feePreview(); };
    $("g-more").style.opacity = c.gst_registered ? 1 : .45;
    ["g-rate", "g-inc"].forEach(function (id) { $(id).oninput = feePreview; });
    $("pl-add").onclick = function () { priceRows.push({ subject: "", level: "", kind: null, unit: "per_hour", amount: "" }); drawPrices(); };
    if ($("f-save")) $("f-save").onclick = saveFees;
  }
  function drawPrices() {
    $("pl").innerHTML = priceRows.map(function (p, i) {
      return '<tr data-i="' + i + '"><td><input data-k="subject" value="' + esc(p.subject || "") + '" placeholder="Any"></td>' +
        '<td><input data-k="level" value="' + esc(p.level || "") + '" placeholder="Any"></td>' +
        '<td><select data-k="kind">' + sel([["", "Any"], ["individual", "1-to-1"], ["group", "Group"]], p.kind || "") + "</select></td>" +
        '<td><select data-k="unit">' + sel([["per_hour", "Per hour"], ["per_lesson", "Per lesson"]], p.unit) + "</select></td>" +
        '<td><input class="num" data-k="amount" type="number" min="0" step="0.5" value="' + esc(p.amount) + '"></td>' +
        '<td><button class="cs-x" data-del aria-label="Remove">×</button></td></tr>';
    }).join("") || '<tr><td colspan="6" class="muted">No prices yet.</td></tr>';
    $("pl").querySelectorAll("tr[data-i]").forEach(function (tr) {
      var i = +tr.getAttribute("data-i");
      tr.querySelectorAll("[data-k]").forEach(function (el) { el.oninput = function () { priceRows[i][el.getAttribute("data-k")] = el.value; feePreview(); }; });
      tr.querySelector("[data-del]").onclick = function () { priceRows.splice(i, 1); drawPrices(); };
    });
    feePreview();
  }
  function feePreview() {
    var p = priceRows.filter(function (r) { return num(r.amount) != null; })[0];
    if (!p) { $("pl-prev").innerHTML = '<span class="muted">Add a price to see what a parent pays.</span>'; return; }
    var fee = p.unit === "per_hour" ? num(p.amount) * 1.5 : num(p.amount);
    var g = B.gst(fee, num($("g-rate").value) || 0, $("g-inc").value === "true", $("g-on").checked);
    $("pl-prev").innerHTML = "Example: a " + (p.unit === "per_hour" ? "1.5-hour " : "") + esc([p.level, p.subject].filter(Boolean).join(" ") || "") +
      " lesson → <b>" + money(g.net) + "</b>" + (g.gst ? " + GST " + money(g.gst) + " = <b>" + money(g.total) + "</b>" : "") + " per student.";
  }
  async function saveFees() {
    var rate = num($("g-rate").value);
    if ($("g-on").checked && (rate == null || rate < 0 || rate >= 100)) { say("f-save", "GST rate must be 0–99%."); return; }
    var bad = priceRows.filter(function (r) { return num(r.amount) == null || num(r.amount) < 0; });
    if (bad.length) { say("f-save", "Every price needs an amount."); return; }
    $("f-save").disabled = true;
    var ok = await saveCentre({ gst_registered: $("g-on").checked, gst_rate: rate == null ? 9 : rate, gst_inclusive: $("g-inc").value === "true",
      gst_reg_no: $("g-no").value.trim() || null, invoice_prefix: ($("g-pre").value.trim() || "INV").toUpperCase() }, "f-save");
    if (ok) ok = await syncRows("centre_price_list", S.prices, priceRows.map(function (r) {
      return { id: r.id, centre_id: S.centre.id, subject: (r.subject || "").trim() || null, level: (r.level || "").trim() || null, kind: r.kind || null, unit: r.unit, amount: num(r.amount) };
    }), "f-save");
    $("f-save").disabled = false;
    if (ok) { await loadAll(); say("f-save", "Saved ✓", true); }
  }

  // insert new rows, update existing, delete removed — one table, scoped to this centre
  async function syncRows(table, before, after, msgId) {
    var keep = {}; after.forEach(function (r) { if (r.id) keep[r.id] = true; });
    var gone = before.filter(function (r) { return !keep[r.id]; }).map(function (r) { return r.id; });
    if (gone.length) { var d = await sb().from(table).delete().in("id", gone); if (d.error) { say(msgId, d.error.message); return false; } }
    var olds = after.filter(function (r) { return r.id; }), news = after.filter(function (r) { return !r.id; }).map(function (r) { var c = Object.assign({}, r); delete c.id; return c; });
    if (olds.length) { var u = await sb().from(table).upsert(olds); if (u.error) { say(msgId, u.error.message); return false; } }
    if (news.length) { var n = await sb().from(table).insert(news); if (n.error) { say(msgId, n.error.message); return false; } }
    return true;
  }

  // ------------------------------------------------------------------ Billing rules
  var editPol = null;
  function tabBilling() {
    var list = S.policies.map(function (p) {
      return '<button class="cs-item" data-pol="' + p.id + '"><b>' + esc(p.name) + "</b>" + (p.is_default ? '<span class="cs-badge">Default</span>' : "") +
        '<span class="cs-badge grey">' + esc(p.model) + "</span><p>" + esc(B.describePolicy(p.model, p.config)) + "</p></button>";
    }).join("");
    $("cs-body").innerHTML = card("Billing rules", "Each family is billed by a rule. The default applies to everyone; a class or a student can use a different one. Rules are data — add as many as you need.",
      '<div class="cs-list">' + (list || '<p class="muted">No rules yet.</p>') + "</div>" +
      (can("billing.edit") ? '<button class="btn cs-add" id="pol-new">+ New billing rule</button>' : "")) + '<div id="pol-ed"></div>';
    $("cs-body").querySelectorAll("[data-pol]").forEach(function (b) {
      b.onclick = function () { openPolicy(S.policies.filter(function (p) { return p.id === b.getAttribute("data-pol"); })[0]); };
    });
    if ($("pol-new")) $("pol-new").onclick = function () { openPolicy({ name: "", model: "postpay", config: {}, is_default: !S.policies.length }); };
    if (editPol) openPolicy(editPol);
  }
  function openPolicy(p) {
    editPol = p;
    var c = B.withDefaults(p.config), cn = c.cancellation, sd = c.sibling_discount, lf = c.late_fee, un = c.unused;
    var pk = (c.packages || []).map(function (x, i) {
      return '<tr data-i="' + i + '"><td><input class="num" data-k="lessons" type="number" min="1" value="' + esc(x.lessons) + '"></td><td><input class="num" data-k="price" type="number" min="0" step="1" value="' + esc(x.price) + '"></td>' +
        '<td><input class="num" data-k="expiry_days" type="number" min="0" value="' + esc(x.expiry_days || "") + '" placeholder="Never"></td><td><button class="cs-x" data-del>×</button></td></tr>';
    }).join("");
    $("pol-ed").innerHTML = card(p.id ? "Edit “" + p.name + "”" : "New billing rule", "",
      '<div class="cs-row">' + field("p-name", "Name", p.name, 'type="text" maxlength="60" placeholder="e.g. Term packages"') +
        '<div class="field"><label for="p-model">How families pay</label><select id="p-model">' +
          sel([["postpay", "Postpay — billed after lessons"], ["prepay", "Prepay — packages paid upfront"], ["hybrid", "Hybrid — deposit + billed after"]], p.model) + "</select></div></div>" +
      '<div class="cs-row3"><div class="field" data-show="postpay hybrid"><label for="p-cycle">Invoice</label><select id="p-cycle">' + sel([["monthly", "Monthly"], ["per_lesson", "After every lesson"], ["term", "Per term"]], c.cycle) + "</select></div>" +
        field("p-due", "Due in (days)", c.due_days, 'type="number" min="0" max="120"') +
        '<div class="field" data-show="prepay"><label for="p-nob">No lessons left</label><select id="p-nob">' + sel([["charge", "Bill the lesson anyway"], ["block", "Don’t allow the lesson"]], c.no_balance) + "</select></div></div>" +
      '<div data-show="prepay"><h3>Packages</h3><div class="cs-scroll"><table class="cs-grid"><thead><tr><th>Lessons</th><th>Price ($)</th><th>Expires after (days)</th><th></th></tr></thead><tbody id="p-pk">' + pk + '</tbody></table></div><button class="btn cs-add" id="p-pk-add">+ Add package</button></div>' +
      '<div data-show="hybrid"><h3>Deposit</h3><div class="cs-row">' + field("p-dep", "Deposit ($)", c.deposit.amount, 'type="number" min="0"') +
        '<div class="field"><label>&nbsp;</label>' + check("p-depr", "Refundable when they leave", c.deposit.refundable) + "</div></div></div>" +
      "<h3>Cancellations & make-ups</h3>" +
      '<div class="cs-row3">' + field("p-nh", "Notice needed (hours)", cn.notice_hours, 'type="number" min="0"') +
        field("p-lc", "Late cancel charge (%)", cn.late_charge_pct, 'type="number" min="0" max="100"') +
        field("p-ns", "No-show charge (%)", cn.no_show_charge_pct, 'type="number" min="0" max="100"') + "</div>" +
      check("p-ptl", "Tutor is still paid for late cancellations", cn.pay_tutor_late_cancel) +
      check("p-mu", "Make-up lessons allowed (for cancellations with notice)", cn.makeup_allowed) +
      '<div class="cs-row">' + field("p-muw", "Make-up within (days)", cn.makeup_window_days, 'type="number" min="0"') + field("p-mum", "Max make-ups per term", cn.max_makeups_per_term, 'type="number" min="0"') + "</div>" +
      "<h3>Sibling discount</h3><div class=\"cs-row\">" +
        '<div class="field"><label for="p-sdt">Type</label><select id="p-sdt">' + sel([["percent", "% off"], ["fixed", "$ off per lesson"]], sd.type) + "</select></div>" +
        field("p-sdv", "2nd child onwards", sd.value, 'type="number" min="0" step="0.5"') + "</div>" +
      "<h3>Late payment</h3><div class=\"cs-row\">" +
        '<div class="field"><label for="p-lft">Late fee</label><select id="p-lft">' + sel([["fixed", "$ flat"], ["percent", "% of what’s owed"]], lf.type) + "</select></div>" +
        field("p-lfv", "Amount (0 = none)", lf.value, 'type="number" min="0" step="0.5"') + "</div>" +
      '<div class="cs-row">' + field("p-lfa", "After overdue (days)", lf.after_days, 'type="number" min="0"') + field("p-lfm", "At most (times per invoice)", lf.max_times, 'type="number" min="1"') + "</div>" +
      '<div data-show="prepay"><h3>Unused lessons when a package expires</h3><div class="cs-row3">' +
        '<div class="field"><label for="p-una">What happens</label><select id="p-una">' + sel([["forfeit", "Forfeited"], ["carry_forward", "Extended"], ["credit", "Credited to the family"], ["refund", "Flagged for refund"]], un.action) + "</select></div>" +
        field("p-und", "Extend by (days)", un.extend_days, 'type="number" min="1"') + field("p-unm", "Max extensions", un.max_extensions, 'type="number" min="0"') + "</div></div>" +
      check("p-def", "Default rule for the centre", p.is_default) +
      '<div class="cs-preview" id="p-prev"></div><div class="cs-err" id="p-err"></div>') +
      '<div class="cs-save"><div class="msg" id="p-save-msg"></div>' + (p.id && !p.is_default && can("billing.edit") ? '<button class="btn set-danger" id="p-arch">Archive</button>' : "") +
      '<button class="btn" id="p-cancel">Close</button>' + (can("billing.edit") ? '<button class="btn btn-primary" id="p-save">Save rule</button>' : "") + "</div>";
    var pkRows = (c.packages || []).map(function (x) { return Object.assign({}, x); });
    function bindPk() {
      $("p-pk").querySelectorAll("tr[data-i]").forEach(function (tr) {
        var i = +tr.getAttribute("data-i");
        tr.querySelectorAll("[data-k]").forEach(function (el) { el.oninput = function () { pkRows[i][el.getAttribute("data-k")] = num(el.value); prev(); }; });
        tr.querySelector("[data-del]").onclick = function () { pkRows.splice(i, 1); editPol = Object.assign({}, editPol, { config: Object.assign({}, read().config) }); openPolicy(editPol); };
      });
    }
    function read() {
      var cfg = {
        cycle: $("p-cycle").value, due_days: num($("p-due").value) || 0, no_balance: $("p-nob").value,
        packages: pkRows.filter(function (x) { return x.lessons || x.price; }).map(function (x) { return { lessons: num(x.lessons), price: num(x.price), expiry_days: num(x.expiry_days) || null }; }),
        deposit: { amount: num($("p-dep").value) || 0, refundable: $("p-depr").checked },
        cancellation: { notice_hours: num($("p-nh").value) || 0, late_charge_pct: num($("p-lc").value) || 0, no_show_charge_pct: num($("p-ns").value) || 0,
          pay_tutor_late_cancel: $("p-ptl").checked, makeup_allowed: $("p-mu").checked, makeup_window_days: num($("p-muw").value) || 0, max_makeups_per_term: num($("p-mum").value) || 0 },
        sibling_discount: { type: $("p-sdt").value, value: num($("p-sdv").value) || 0 },
        late_fee: { type: $("p-lft").value, value: num($("p-lfv").value) || 0, after_days: num($("p-lfa").value) || 0, max_times: num($("p-lfm").value) || 1 },
        unused: { action: $("p-una").value, extend_days: num($("p-und").value) || 30, max_extensions: num($("p-unm").value) || 0 }
      };
      return { name: $("p-name").value.trim(), model: $("p-model").value, config: cfg, is_default: $("p-def").checked };
    }
    function prev() {
      var v = read(), m = v.model;
      $("pol-ed").querySelectorAll("[data-show]").forEach(function (el) { el.style.display = el.getAttribute("data-show").split(" ").indexOf(m) > -1 ? "" : "none"; });
      $("p-prev").innerHTML = "<b>Parents see:</b> " + esc(B.describePolicy(m, v.config));
      $("p-err").textContent = B.validatePolicy(m, v.config).join(" ");
    }
    $("pol-ed").oninput = prev; $("pol-ed").onchange = prev;
    $("p-pk-add").onclick = function () { pkRows.push({ lessons: 4, price: null, expiry_days: 90 }); editPol = Object.assign({}, editPol, read(), { config: Object.assign(read().config, { packages: pkRows }) }); openPolicy(editPol); };
    $("p-cancel").onclick = function () { editPol = null; tabBilling(); };
    bindPk(); prev();
    if ($("p-arch")) $("p-arch").onclick = async function () {
      if (!(await TL.confirm({ title: "Archive this rule?", message: "Families already on it keep their invoices; nobody new can use it.", confirmText: "Archive" }))) return;
      var r = await sb().from("billing_policies").update({ archived: true }).eq("id", p.id);
      if (r.error) return say("p-save", r.error.message);
      editPol = null; await loadAll(); tabBilling();
    };
    if ($("p-save")) $("p-save").onclick = async function () {
      var v = read(), errs = B.validatePolicy(v.model, v.config);
      if (!v.name) errs.unshift("Give the rule a name.");
      if (errs.length) { $("p-err").textContent = errs.join(" "); return; }
      $("p-save").disabled = true;
      if (v.is_default) {                       // only one default: clear the old one first
        var d = await sb().from("billing_policies").update({ is_default: false }).eq("centre_id", S.centre.id).eq("is_default", true).neq("id", p.id || "00000000-0000-0000-0000-000000000000");
        if (d.error) { $("p-save").disabled = false; return say("p-save", d.error.message); }
      }
      var row = Object.assign({ centre_id: S.centre.id }, v);
      var r = p.id ? await sb().from("billing_policies").update(row).eq("id", p.id) : await sb().from("billing_policies").insert(row);
      $("p-save").disabled = false;
      if (r.error) return say("p-save", r.error.message);
      editPol = null; await loadAll(); tabBilling(); TL.toast("Billing rule saved");
    };
  }

  // ------------------------------------------------------------------ Tutor pay + payout rule
  var payRows = null;
  function tutors() { var tr = S.roles.filter(function (r) { return r.key !== "parent"; }).map(function (r) { return r.id; }); return S.members.filter(function (m) { return tr.indexOf(m.role_id) > -1; }); }
  function tabPay() {
    payRows = S.pay.map(function (p) { return Object.assign({}, p); });
    var rule = S.centre.payout_rule;
    $("cs-body").innerHTML =
      card("Tutor pay", "Set a centre-wide rate, then add more specific ones. The most specific match wins: a tutor’s own rate beats a subject rate, which beats the centre default.",
        '<div class="cs-scroll"><table class="cs-grid"><thead><tr><th>Tutor</th><th>Subject</th><th>Level</th><th>Paid</th><th>Rate</th><th>Min / lesson</th><th>Max / lesson</th><th></th></tr></thead><tbody id="pr"></tbody></table></div>' +
        '<button class="btn cs-add" id="pr-add">+ Add pay rate</button>' +
        "<h3>Try it</h3>" +
        '<div class="cs-row3"><div class="field"><label for="k-t">Tutor</label><select id="k-t">' + sel(tutors().map(function (m) { return [m.id, m.display_name]; }), "") + "</select></div>" +
          field("k-s", "Subject", "Maths") + field("k-l", "Level", "Sec 3") + "</div>" +
        '<div class="cs-row3">' + field("k-m", "Lesson length (min)", 90, 'type="number" min="15" step="15"') + field("k-h", "Students who paid", 4, 'type="number" min="0"') +
          field("k-f", "Fee per student ($, before GST)", 60, 'type="number" min="0"') + "</div>" +
        '<div class="cs-preview" id="k-out"></div>') +
      card("When tutors get paid", "",
        '<div class="cs-rule"><div><div class="k">' + (rule === "on_delivery" ? "As soon as the lesson is delivered" : "Only after the parent’s payment is received and reconciled") + "</div>" +
        '<p class="cs-sub" style="margin:4px 0 0">' + (rule === "on_delivery"
          ? "The centre carries the risk of unpaid fees. Refunds no longer claw back tutor pay."
          : "Delivered lessons create pending earnings. They become payable when the invoice or package covering them is reconciled (oldest lessons first for part-payments). Disputed invoices hold the pay; refunds after payout are deducted in the next batch.") + "</p></div>" +
        (can("payouts.override") ? '<button class="btn" id="po-change">Change…</button>' : "") + "</div>") +
      saveBar("pr-save", "Save pay rates", "billing.edit");
    drawPay();
    $("pr-add").onclick = function () { payRows.push({ tutor_member_id: null, subject: "", level: "", basis: "per_hour", rate: "" }); drawPay(); };
    ["k-t", "k-s", "k-l", "k-m", "k-h", "k-f"].forEach(function (id) { $(id).oninput = calc; });
    if ($("pr-save")) $("pr-save").onclick = savePay;
    if ($("po-change")) $("po-change").onclick = changePayoutRule;
  }
  function drawPay() {
    var tOpts = [["", "All tutors"]].concat(tutors().map(function (m) { return [m.id, m.display_name]; }));
    var bOpts = B.PAY_BASES.map(function (b) { return [b.key, b.label]; });
    $("pr").innerHTML = payRows.map(function (p, i) {
      return '<tr data-i="' + i + '"><td><select data-k="tutor_member_id">' + sel(tOpts, p.tutor_member_id || "") + "</select></td>" +
        '<td><input data-k="subject" value="' + esc(p.subject || "") + '" placeholder="Any"></td><td><input data-k="level" value="' + esc(p.level || "") + '" placeholder="Any"></td>' +
        '<td><select data-k="basis">' + sel(bOpts, p.basis) + "</select></td>" +
        '<td><input class="num" data-k="rate" type="number" min="0" step="0.5" value="' + esc(p.rate) + '" title="' + esc((B.PAY_BASES.filter(function (b) { return b.key === p.basis; })[0] || {}).unit) + '"></td>' +
        '<td><input class="num" data-k="min_pay" type="number" min="0" value="' + esc(p.min_pay == null ? "" : p.min_pay) + '" placeholder="—"></td>' +
        '<td><input class="num" data-k="max_pay" type="number" min="0" value="' + esc(p.max_pay == null ? "" : p.max_pay) + '" placeholder="—"></td>' +
        '<td><button class="cs-x" data-del aria-label="Remove">×</button></td></tr>';
    }).join("") || '<tr><td colspan="8" class="muted">No pay rates yet — lessons can’t be delivered until there is one.</td></tr>';
    $("pr").querySelectorAll("tr[data-i]").forEach(function (tr) {
      var i = +tr.getAttribute("data-i");
      tr.querySelectorAll("[data-k]").forEach(function (el) { el.oninput = function () { payRows[i][el.getAttribute("data-k")] = el.value; calc(); }; });
      tr.querySelector("[data-del]").onclick = function () { payRows.splice(i, 1); drawPay(); };
    });
    calc();
  }
  function calc() {
    var rules = payRows.filter(function (r) { return num(r.rate) != null; }).map(function (r) {
      return Object.assign({}, r, { tutor_member_id: r.tutor_member_id || null, subject: (r.subject || "").trim() || null, level: (r.level || "").trim() || null });
    });
    var r = B.pickPayRule(rules, { tutor: $("k-t").value, subject: $("k-s").value, level: $("k-l").value });
    if (!r) { $("k-out").innerHTML = '<span class="muted">No rate matches this lesson.</span>'; return; }
    var mins = num($("k-m").value) || 0, heads = num($("k-h").value) || 0, fee = (num($("k-f").value) || 0) * heads;
    var pay = B.payAmount(r.basis, num(r.rate), mins, heads, fee, num(r.min_pay), num(r.max_pay));
    var lbl = (B.PAY_BASES.filter(function (b) { return b.key === r.basis; })[0] || {}).label;
    $("k-out").innerHTML = "Uses <b>" + esc(lbl.toLowerCase()) + " " + (r.basis === "percent_of_fee" ? num(r.rate) + "%" : money(r.rate)) + "</b>" +
      (r.tutor_member_id ? " (this tutor’s rate)" : r.subject || r.level ? " (" + esc([r.subject, r.level].filter(Boolean).join(", ")) + " rate)" : " (centre default)") +
      " → tutor earns <b>" + money(pay) + "</b> for this lesson" + (heads ? ", released as each student’s fee is paid." : ".");
  }
  async function savePay() {
    if (payRows.some(function (r) { return num(r.rate) == null || num(r.rate) < 0; })) return say("pr-save", "Every row needs a rate.");
    if (payRows.some(function (r) { return r.basis === "percent_of_fee" && num(r.rate) > 100; })) return say("pr-save", "A % of fee can’t be over 100.");
    $("pr-save").disabled = true;
    var ok = await syncRows("tutor_pay_rules", S.pay, payRows.map(function (r) {
      return { id: r.id, centre_id: S.centre.id, tutor_member_id: r.tutor_member_id || null, subject: (r.subject || "").trim() || null, level: (r.level || "").trim() || null,
        basis: r.basis, rate: num(r.rate), min_pay: num(r.min_pay), max_pay: num(r.max_pay) };
    }), "pr-save");
    $("pr-save").disabled = false;
    if (ok) { await loadAll(); say("pr-save", "Saved ✓", true); }
  }
  async function changePayoutRule() {
    var cur = S.centre.payout_rule, to = cur === "on_delivery" ? "paid_reconciled" : "on_delivery";
    var reason = await TL.prompt({
      title: to === "on_delivery" ? "Pay tutors before parents pay?" : "Go back to paying after parents pay?",
      message: (to === "on_delivery" ? "Tutors become payable as soon as a lesson is delivered, even if the family never pays. " : "Earnings will wait for reconciled parent payments again. ") +
        "This is recorded in the audit log with your name. Why are you changing it?",
      placeholder: "Reason (required)", confirmText: "Change rule", danger: to === "on_delivery" });
    if (reason == null) return;
    if (reason.length < 5) return TL.alert("Please give a reason of at least 5 characters.");
    var r = await sb().rpc("td_set_payout_rule", { p_centre: S.centre.id, p_rule: to, p_reason: reason });
    if (r.error) return TL.alert(r.error.message);
    var c = await sb().from("centres").select("*").eq("id", S.centre.id).single();
    if (!c.error) S.centre = c.data;
    TL.toast("Payout rule changed (logged)"); tabPay();
  }

  // ------------------------------------------------------------------ Team & roles
  var roleEdits = null;
  function tabTeam() {
    roleEdits = {};
    S.roles.forEach(function (r) { roleEdits[r.id] = (r.permissions || []).slice(); });
    var rOpts = S.roles.map(function (r) { return [r.id, r.name]; });
    var rows = S.members.map(function (m) {
      var mine = S.me && m.id === S.me.id;
      return '<tr><td><b>' + esc(m.display_name) + "</b>" + (mine ? ' <span class="cs-badge grey">You</span>' : "") + '<div class="muted" style="font-size:12.5px">' + esc(m.email || "") + (m.user_id ? "" : " · invited") + "</div></td>" +
        '<td>' + (can("roles.manage") ? '<select data-member="' + m.id + '">' + sel(rOpts, m.role_id) + "</select>" : esc((S.roles.filter(function (r) { return r.id === m.role_id; })[0] || {}).name)) + "</td></tr>";
    }).join("");
    var cols = S.roles;
    var grp = "", matrix = "";
    B.PERMISSIONS.forEach(function (p) {
      if (p.group !== grp) { grp = p.group; matrix += '<tr class="grp"><td colspan="' + (cols.length + 1) + '">' + esc(grp) + "</td></tr>"; }
      matrix += "<tr><td>" + esc(p.label) + "</td>" + cols.map(function (r) {
        var on = r.key === "owner" || roleEdits[r.id].indexOf(p.key) > -1, lock = r.key === "owner" || !can("roles.manage");
        return '<td><input type="checkbox" data-role="' + r.id + '" data-perm="' + p.key + '"' + (on ? " checked" : "") + (lock ? " disabled" : "") + ' aria-label="' + esc(r.name + ": " + p.label) + '"></td>';
      }).join("") + "</tr>";
    });
    $("cs-body").innerHTML =
      card("Team", "Everyone who uses TutorDeck at your centre. Invite by email; they’re linked when they sign in with that email.",
        '<div class="cs-scroll"><table class="cs-grid"><tbody>' + rows + "</tbody></table></div>" +
        (can("roles.manage") ? '<h3>Invite someone</h3><div class="cs-row3">' + field("i-n", "Name", "", 'type="text" maxlength="60"') + field("i-e", "Email", "", 'type="email"') +
          '<div class="field"><label for="i-r">Role</label><select id="i-r">' + sel(S.roles.filter(function (r) { return r.key !== "owner"; }).map(function (r) { return [r.id, r.name]; }), (S.roles.filter(function (r) { return r.key === "tutor"; })[0] || {}).id) + "</select></div></div>" +
          '<button class="btn" id="i-go">Add to team</button><p class="msg" id="i-msg"></p>' : "")) +
      card("Roles", "What each role can do. Owner always has everything. Tick to change, or add your own role (e.g. “Senior tutor”).",
        '<div class="cs-scroll"><table class="cs-grid cs-matrix"><thead><tr><th>Permission</th>' + cols.map(function (r) { return "<th>" + esc(r.name) + "</th>"; }).join("") + "</tr></thead><tbody>" + matrix + "</tbody></table></div>" +
        (can("roles.manage") ? '<button class="btn cs-add" id="r-add">+ Add role</button>' : "")) +
      saveBar("r-save", "Save roles", "roles.manage");
    $("cs-body").querySelectorAll("[data-member]").forEach(function (s) {
      s.onchange = async function () {
        var r = await sb().rpc("td_set_member_role", { p_member: s.getAttribute("data-member"), p_role: s.value });
        if (r.error) { TL.alert(r.error.message); await loadAll(); return tabTeam(); }
        await loadAll(); TL.toast("Role changed (logged)"); tabTeam();
      };
    });
    $("cs-body").querySelectorAll("[data-perm]").forEach(function (cb) {
      cb.onchange = function () {
        var list = roleEdits[cb.getAttribute("data-role")], k = cb.getAttribute("data-perm"), i = list.indexOf(k);
        if (cb.checked && i < 0) list.push(k); if (!cb.checked && i > -1) list.splice(i, 1);
      };
    });
    if ($("i-go")) $("i-go").onclick = async function () {
      var n = $("i-n").value.trim(), e = $("i-e").value.trim().toLowerCase();
      if (!n || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e)) { $("i-msg").textContent = "Enter a name and a valid email."; $("i-msg").className = "msg err"; return; }
      if (S.members.some(function (m) { return (m.email || "").toLowerCase() === e; })) { $("i-msg").textContent = "Already on the team."; $("i-msg").className = "msg err"; return; }
      var r = await sb().from("centre_members").insert({ centre_id: S.centre.id, display_name: n, email: e, role_id: $("i-r").value });
      if (r.error) { $("i-msg").textContent = r.error.message; $("i-msg").className = "msg err"; return; }
      await loadAll(); tabTeam(); TL.toast(n + " added — ask them to sign in with " + e);
    };
    if ($("r-add")) $("r-add").onclick = async function () {
      var name = await TL.prompt({ title: "New role", message: "Name it after what they do. You can tick its permissions next.", placeholder: "e.g. Senior tutor", confirmText: "Add role" });
      if (!name) return;
      var key = name.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "").replace(/^(\d)/, "r_$1").slice(0, 30) || "role";
      if (S.roles.some(function (r) { return r.key === key; })) key = (key + "_" + Date.now().toString(36)).slice(0, 30);
      var r = await sb().rpc("td_save_role", { p_centre: S.centre.id, p_role: null, p_key: key, p_name: name, p_perms: ["lessons.remarks", "payouts.view_own"] });
      if (r.error) return TL.alert(r.error.message);
      await loadAll(); tabTeam();
    };
    if ($("r-save")) $("r-save").onclick = async function () {
      var changed = S.roles.filter(function (r) { return r.key !== "owner" && JSON.stringify((r.permissions || []).slice().sort()) !== JSON.stringify(roleEdits[r.id].slice().sort()); });
      if (!changed.length) return say("r-save", "No changes.", true);
      var mine = S.me && changed.filter(function (r) { return r.id === S.me.role_id && roleEdits[r.id].indexOf("roles.manage") < 0; })[0];
      if (mine && !(await TL.confirm({ title: "Remove your own access?", message: "You’re taking “Team & roles” away from your own role. You won’t be able to undo this yourself.", confirmText: "Save anyway", danger: true }))) return;
      $("r-save").disabled = true;
      for (var i = 0; i < changed.length; i++) {
        var r = await sb().rpc("td_save_role", { p_centre: S.centre.id, p_role: changed[i].id, p_key: changed[i].key, p_name: changed[i].name, p_perms: roleEdits[changed[i].id] });
        if (r.error) { $("r-save").disabled = false; return say("r-save", r.error.message); }
      }
      await loadAll(); tabTeam(); say("r-save", "Saved ✓ (logged)", true);
    };
  }

  // ------------------------------------------------------------------ Custom fields
  var fieldEnt = "student", fieldRows = null;
  var ENTS = [["student", "Students"], ["guardian", "Parents"], ["household", "Families"], ["class", "Classes"], ["tutor", "Tutors"]];
  var FTYPES = [["text", "Text"], ["number", "Number"], ["date", "Date"], ["select", "Pick from list"], ["checkbox", "Yes / no"], ["phone", "Phone"], ["email", "Email"]];
  function tabFields() {
    fieldRows = S.fields.filter(function (f) { return f.entity === fieldEnt; }).map(function (f) { return Object.assign({}, f, { options: (f.options || []).join(", ") }); });
    $("cs-body").innerHTML = card("Fields you collect", "Add the details your centre needs (school, allergies, how they heard of you…). They appear on the forms for that record.",
      '<div class="seg" role="tablist">' + ENTS.map(function (e) { return '<button data-ent="' + e[0] + '" class="' + (fieldEnt === e[0] ? "on" : "") + '">' + e[1] + "</button>"; }).join("") + "</div>" +
      '<div class="cs-scroll"><table class="cs-grid"><thead><tr><th>Label</th><th>Type</th><th>Choices (comma-separated)</th><th>Required</th><th>Shown</th><th></th></tr></thead><tbody id="fl"></tbody></table></div>' +
      '<button class="btn cs-add" id="fl-add">+ Add field</button>') + saveBar("fl-save", "Save fields", "settings.edit");
    $("cs-body").querySelectorAll("[data-ent]").forEach(function (b) { b.onclick = function () { fieldEnt = b.getAttribute("data-ent"); tabFields(); }; });
    drawFields();
    $("fl-add").onclick = function () { fieldRows.push({ label: "", type: "text", options: "", required: false, active: true }); drawFields(); };
    if ($("fl-save")) $("fl-save").onclick = saveFields;
  }
  function drawFields() {
    $("fl").innerHTML = fieldRows.map(function (f, i) {
      return '<tr data-i="' + i + '"><td><input data-k="label" value="' + esc(f.label) + '" placeholder="e.g. School"></td><td><select data-k="type">' + sel(FTYPES, f.type) + "</select></td>" +
        '<td><input data-k="options" value="' + esc(f.options) + '" placeholder="' + (f.type === "select" ? "e.g. Friend, Google, Flyer" : "—") + '"' + (f.type === "select" ? "" : " disabled") + "></td>" +
        '<td><input type="checkbox" data-c="required"' + (f.required ? " checked" : "") + ' style="width:18px;height:18px;min-width:0"></td>' +
        '<td><input type="checkbox" data-c="active"' + (f.active !== false ? " checked" : "") + ' style="width:18px;height:18px;min-width:0"></td>' +
        '<td><button class="cs-x" data-del aria-label="Remove">×</button></td></tr>';
    }).join("") || '<tr><td colspan="6" class="muted">No extra fields for ' + esc(ENTS.filter(function (e) { return e[0] === fieldEnt; })[0][1].toLowerCase()) + " yet.</td></tr>";
    $("fl").querySelectorAll("tr[data-i]").forEach(function (tr) {
      var i = +tr.getAttribute("data-i");
      tr.querySelectorAll("[data-k]").forEach(function (el) { el.oninput = function () { fieldRows[i][el.getAttribute("data-k")] = el.value; if (el.getAttribute("data-k") === "type") drawFields(); }; });
      tr.querySelectorAll("[data-c]").forEach(function (el) { el.onchange = function () { fieldRows[i][el.getAttribute("data-c")] = el.checked; }; });
      tr.querySelector("[data-del]").onclick = function () { fieldRows.splice(i, 1); drawFields(); };
    });
  }
  async function saveFields() {
    var seen = {}, out = [], err = "";
    fieldRows.forEach(function (f, i) {
      var label = (f.label || "").trim(); if (!label) { err = "Every field needs a label."; return; }
      var key = f.key || label.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "").replace(/^(\d)/, "f_$1").slice(0, 40) || "field";
      if (seen[key]) { err = "Two fields are called “" + label + "”."; return; } seen[key] = 1;
      var opts = f.type === "select" ? String(f.options || "").split(",").map(function (s) { return s.trim(); }).filter(Boolean) : [];
      if (f.type === "select" && !opts.length) { err = "“" + label + "” needs some choices."; return; }
      out.push({ id: f.id, centre_id: S.centre.id, entity: fieldEnt, key: key, label: label, type: f.type, options: opts, required: !!f.required, active: f.active !== false, sort: i * 10 });
    });
    if (err) return say("fl-save", err);
    $("fl-save").disabled = true;
    var ok = await syncRows("centre_fields", S.fields.filter(function (f) { return f.entity === fieldEnt; }), out, "fl-save");
    $("fl-save").disabled = false;
    if (ok) { await loadAll(); tabFields(); say("fl-save", "Saved ✓", true); }
  }

  // ------------------------------------------------------------------ Invoice template
  var INV_DEFAULT = { title: "Tax invoice", intro: "Dear {parent}, here are {student}’s lessons for {period}.", terms: "Please pay by {due_date}.",
    notes: "", footer: "Thank you for learning with {centre}!", show_gst_breakdown: true, show_paynow: true, show_bank: true, show_lesson_dates: true };
  function tabInvoice() {
    var t = Object.assign({}, INV_DEFAULT, setts().invoice || {});
    function ta(id, label, val, rows) { return '<div class="field"><label for="' + id + '">' + label + '</label><textarea id="' + id + '" rows="' + (rows || 2) + '" style="width:100%;padding:11px 13px;border:1px solid var(--line);border-radius:9px;font:inherit;resize:vertical">' + esc(val) + "</textarea></div>"; }
    $("cs-body").innerHTML = card("Invoice template", "Fill-ins: <b>{centre}</b> · <b>{parent}</b> · <b>{student}</b> · <b>{period}</b> · <b>{invoice}</b> · <b>{total}</b> · <b>{due_date}</b>",
      field("v-title", "Title", t.title) + ta("v-intro", "Opening line", t.intro) + ta("v-terms", "Payment terms", t.terms) +
      ta("v-notes", 'Notes <span class="opt">Optional</span>', t.notes, 3) + ta("v-foot", "Footer", t.footer) +
      check("v-gst", "Show the GST breakdown (when GST-registered)", t.show_gst_breakdown) + check("v-dates", "List each lesson date", t.show_lesson_dates) +
      check("v-pn", "Show PayNow", t.show_paynow) + check("v-bank", "Show bank details", t.show_bank)) +
      card("Preview", "Sample family, two lessons.", '<div id="v-prev"></div>') + saveBar("v-save", "Save template", "settings.edit");
    function read() { return { title: $("v-title").value, intro: $("v-intro").value, terms: $("v-terms").value, notes: $("v-notes").value, footer: $("v-foot").value,
      show_gst_breakdown: $("v-gst").checked, show_lesson_dates: $("v-dates").checked, show_paynow: $("v-pn").checked, show_bank: $("v-bank").checked }; }
    function prev() {
      var t2 = read(), c = S.centre, s = setts(), name = (s.branding || {}).display_name || c.name, col = (s.branding || {}).color || "#0F766E";
      var lines = [["Sec 3 Maths · 4 Nov", 60], ["Sec 3 Maths · 11 Nov", 60]], sub = 0, gst = 0, tot = 0;
      var rowsH = lines.map(function (l) { var g = B.gst(l[1], c.gst_rate, c.gst_inclusive, c.gst_registered); sub += g.net; gst += g.gst; tot += g.total;
        return "<tr><td>" + esc(t2.show_lesson_dates ? l[0] : "Sec 3 Maths lesson") + "</td><td>" + money(c.gst_inclusive ? g.total : g.net) + "</td></tr>"; }).join("");
      var due = new Date(Date.now() + 7 * 864e5).toLocaleDateString("en-SG", { day: "numeric", month: "short", year: "numeric" });
      var vars = { centre: name, parent: "Mrs Tan", student: "Alice", period: "November 2026", invoice: c.invoice_prefix + "-00042", total: money(tot), due_date: due };
      var f = function (x) { return esc(B.fillTemplate(x, vars)); };
      var pn = s.paynow || {}, bk = s.bank || {};
      $("v-prev").innerHTML = '<div class="inv-prev"><div class="bar" style="background:' + esc(/^#[0-9a-f]{6}$/i.test(col) ? col : "#0F766E") + '"></div><div class="in">' +
        '<div style="display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap"><div><h4>' + f(t2.title) + '</h4><div class="small">' + esc(vars.invoice) + " · due " + esc(due) + "</div></div>" +
        '<div style="text-align:right"><b>' + esc(name) + "</b>" + (c.gst_registered && c.gst_reg_no ? '<div class="small">GST reg. ' + esc(c.gst_reg_no) + "</div>" : "") + "</div></div>" +
        '<p style="margin:12px 0 0">' + f(t2.intro) + "</p><table>" + rowsH +
        (c.gst_registered && t2.show_gst_breakdown ? "<tr><td>Subtotal</td><td>" + money(sub) + "</td></tr><tr><td>GST " + esc(c.gst_rate) + "%</td><td>" + money(gst) + "</td></tr>" : "") +
        '<tr class="tot"><td>Total</td><td>' + money(tot) + "</td></tr></table>" +
        '<p style="margin:0 0 6px">' + f(t2.terms) + "</p>" +
        (t2.show_paynow && pn.id ? '<div class="small">PayNow: ' + esc(pn.id) + "</div>" : "") +
        (t2.show_bank && bk.account_no ? '<div class="small">' + esc([bk.bank_name, bk.account_no, bk.account_name].filter(Boolean).join(" · ")) + "</div>" : "") +
        (t2.notes ? '<p class="small" style="margin-top:8px">' + f(t2.notes) + "</p>" : "") +
        '<p class="small" style="margin-top:10px">' + f(t2.footer) + "</p></div></div>";
    }
    $("cs-body").oninput = prev; $("cs-body").onchange = prev; prev();
    if ($("v-save")) $("v-save").onclick = function () { saveCentre({ settings: Object.assign({}, setts(), { invoice: read() }) }, "v-save"); };
  }

  // ------------------------------------------------------------------ Audit log
  async function tabAudit() {
    $("cs-body").innerHTML = card("Audit log", "Every sensitive change: payout-rule changes and overrides, roles, payments, refunds, disputes and pay runs. Nobody can edit or delete it.", '<div id="au" class="muted">Loading…</div>');
    if (!can("audit.view")) { $("au").textContent = "Your role can’t see the audit log."; return; }
    var r = await sb().from("centre_audit_log").select("*").eq("centre_id", S.centre.id).order("at", { ascending: false }).limit(200);
    if (r.error) { $("au").textContent = r.error.message; return; }
    var who = {}; S.members.forEach(function (m) { if (m.user_id) who[m.user_id] = m.display_name; });
    var LABEL = { "centre.create": "Centre created", "settings.update": "Settings changed", "payout_rule.change": "Payout rule changed", "earning.override": "Earning made payable by override",
      "role.save": "Role permissions changed", "member.role": "Member’s role changed", "payment.record": "Payment recorded", "payment.reconcile": "Payment reconciled",
      "payment.refund": "Refund", "invoice.dispute": "Invoice disputed", "invoice.dispute_resolved": "Dispute resolved", "invoices.generate": "Invoices generated",
      "package.sell": "Package sold", "payout.batch_create": "Payout batch created", "payout.batch_paid": "Payout batch paid", "payout.batch_cancel": "Payout batch cancelled" };
    $("au").className = "";
    $("au").innerHTML = r.data.length ? '<div class="cs-scroll"><table class="cs-grid cs-audit"><tbody>' + r.data.map(function (a) {
      var d = new Date(a.at);
      return '<tr><td class="when">' + esc(d.toLocaleDateString("en-SG", { day: "numeric", month: "short" }) + " " + d.toLocaleTimeString("en-SG", { hour: "numeric", minute: "2-digit" })) + "</td>" +
        "<td><b>" + esc(LABEL[a.action] || a.action) + "</b>" + (a.reason ? '<div>“' + esc(a.reason) + "”</div>" : "") + "</td><td>" + esc(who[a.actor] || (a.actor ? "Someone" : "System")) + "</td></tr>";
    }).join("") + "</tbody></table></div>" : "Nothing yet.";
  }

  TL.requireAuth("centre", init);
})();
