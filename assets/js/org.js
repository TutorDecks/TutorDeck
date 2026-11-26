// Organisation page — the 10-step setup wizard for a new tuition centre, and the same steps as Settings
// after launch (plus Plan and Audit log). Needs db/migration_org_foundation.sql.
//   org            → your organisations + "Create a tuition centre"
//   org?id=…       → wizard while status = 'setup', settings tabs once active
// All rules are enforced in the database (owner-only settings, versioned & effective-dated, audited).
(function () {
  var S = window.OrgSettings, M = window.Money;
  var $ = function (id) { return document.getElementById(id); };
  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }
  function sb() { return window.sb; }
  function todayISO() { return TL.todayISO ? TL.todayISO() : new Date().toISOString().slice(0, 10); }
  function missing(err) { return err && (err.code === "42P01" || err.code === "PGRST205" || err.code === "42883" || /does not exist|Could not find/i.test(err.message || "")); }
  function prettyDate(iso) { return new Date(iso + "T00:00:00").toLocaleDateString("en-SG", { day: "numeric", month: "short", year: "numeric" }); }

  var st = { lib: undefined, libBusy: false, org: null, role: null, saved: null, draft: null, step: "profile", members: [], branches: [], rooms: [], terms: [], holidays: [] };
  var EXTRA_TABS = [["plan", "Plan"], ["audit", "Audit log"]];
  function isOwner() { return st.role === "owner"; }
  function setup() { return st.org && st.org.status === "setup"; }

  // ------------------------------------------------------------------ entry
  async function init() {
    try { await sb().rpc("org_claim_invites"); } catch (e) {}
    var id = new URLSearchParams(location.search).get("id");
    if (!id) return listOrgs();
    var r = await sb().from("organisations").select("*").eq("id", id).maybeSingle();
    if (r.error) return missing(r.error) ? notReady() : fail(r.error);
    if (!r.data) return fail({ message: "Organisation not found, or you're not a member." });
    st.org = r.data;
    var m = await sb().from("memberships").select("role").eq("org_id", id).eq("user_id", TL.uid()).maybeSingle();
    st.role = m.data && m.data.role;
    var s = await sb().rpc("org_settings_on", { p_org: id, p_day: "9999-12-31" });   // latest version (incl. ones starting next cycle)
    st.saved = S.withDefaults(s.data || {}, st.org.preset);
    st.draft = JSON.parse(JSON.stringify(st.saved));
    var hash = location.hash.slice(1);
    if (setup()) st.step = S.STEPS[Math.max(0, Math.min(9, (st.org.setup_step || 1) - 1))].id;
    if (hash && (S.STEPS.some(function (x) { return x.id === hash; }) || EXTRA_TABS.some(function (x) { return x[0] === hash; }))) st.step = hash;
    await loadSide();
    render();
  }
  async function loadSide() {
    var id = st.org.id;
    var q = await Promise.all([
      sb().from("memberships").select("*").eq("org_id", id).order("created_at"),
      sb().from("branches").select("*").eq("org_id", id).order("created_at"),
      sb().from("rooms").select("*").eq("org_id", id),
      sb().from("terms").select("*").eq("org_id", id).order("starts_on"),
      sb().from("holidays").select("*").eq("org_id", id).order("starts_on")
    ]);
    st.members = q[0].data || []; st.branches = q[1].data || []; st.rooms = q[2].data || []; st.terms = q[3].data || []; st.holidays = q[4].data || [];
    if (st.lib === undefined) {
      try { var lr = await fetch("assets/data/sg-public-holidays.json", { cache: "no-cache" }); st.lib = lr.ok ? await lr.json() : null; } catch (e) { st.lib = null; }
    }
  }
  function fail(err) { $("og").innerHTML = '<div class="card og-card"><p class="msg err" style="margin:0">' + esc(err.message) + '</p><p style="margin:12px 0 0"><a class="og-link" href="org">← Your organisations</a></p></div>'; }
  function notReady() { $("og").innerHTML = '<div class="card og-card og-empty"><h2>Not switched on yet</h2><p class="og-sub">Organisations need <b>db/migration_org_foundation.sql</b> run first.</p></div>'; }

  // ------------------------------------------------------------------ list + create
  async function listOrgs() {
    var r = await sb().from("memberships").select("role, organisations(id, trading_name, kind, status)").eq("user_id", TL.uid());
    if (r.error) return missing(r.error) ? notReady() : fail(r.error);
    var rows = (r.data || []).filter(function (x) { return x.organisations; });
    var centres = rows.filter(function (x) { return x.organisations.kind === "centre"; });
    var solo = rows.filter(function (x) { return x.organisations.kind === "solo"; })[0];
    $("og").innerHTML =
      '<section class="card og-card"><h2>Your organisations</h2><p class="og-sub">' +
        (solo ? "Your own tuition, <b>" + esc(solo.organisations.trading_name) + "</b>, is set up in Settings and works as it always has." : "") + "</p>" +
        '<div class="og-list">' + (centres.map(function (x) {
          var o = x.organisations;
          return '<a class="og-item" href="org?id=' + esc(o.id) + '" style="text-decoration:none;color:inherit"><div class="grow"><b>' + esc(o.trading_name) + '</b><div class="meta">' +
            esc(x.role === "owner" ? "Owner" : x.role === "staff" ? "Staff admin" : "Tutor") + "</div></div>" +
            (o.status === "setup" ? '<span class="og-badge grey">Setting up</span>' : '<span class="og-badge">Live</span>') + "</a>";
        }).join("") || '<p class="muted" style="font-size:13.5px;margin:0">You aren’t part of a tuition centre yet.</p>') + "</div></section>" +
      '<section class="card og-card"><h2>Run a tuition centre?</h2><p class="og-sub">Set up your centre in 10 short steps. Every step has a sensible default, so you can skip ahead and change anything later.</p>' +
        '<div class="field" style="max-width:360px"><label for="og-new">Centre name</label><input id="og-new" type="text" maxlength="120" placeholder="e.g. Bright Minds Learning Centre"></div>' +
        '<button class="btn btn-primary" id="og-create">Create and start setup</button><p class="msg" id="og-cmsg"></p></section>';
    $("og-create").onclick = async function () {
      var name = $("og-new").value.trim();
      if (!name) { $("og-new").focus(); return; }
      $("og-create").disabled = true;
      var s = S.defaults("centre"); s.profile.trading_name = name;
      var r2 = await sb().rpc("org_create_centre", { p_name: name, p_settings: s });
      if (r2.error) { $("og-create").disabled = false; $("og-cmsg").textContent = r2.error.message; $("og-cmsg").className = "msg err"; return; }
      location.href = "org?id=" + encodeURIComponent(r2.data);
    };
  }

  // ------------------------------------------------------------------ shell
  function render() {
    var tabs = S.STEPS.filter(function (x) { return setup() || (x.id !== "review" && x.id !== "import"); });
    var cur = S.STEPS.filter(function (x) { return x.id === st.step; })[0];
    var h = '<div><h2 style="font-size:20px;font-weight:800;margin:0">' + esc(st.org.trading_name) + "</h2>" +
      '<p class="og-sub" style="margin:2px 0 0">' + (setup() ? "Setup · step " + (cur ? cur.n : 10) + " of 10" : "Settings") +
      (isOwner() ? "" : " · view only (the owner changes settings)") + "</p></div>" +
      '<div class="og-steps" role="tablist">' + tabs.map(function (x) {
        var done = setup() && x.n < (st.org.setup_step || 1);
        return '<button role="tab" data-step="' + x.id + '" class="' + (st.step === x.id ? "on " : "") + (done ? "done" : "") + '">' + (setup() ? '<span class="n">' + x.n + "</span>" : "") + esc(x.title) + "</button>";
      }).join("") + (setup() ? "" : EXTRA_TABS.map(function (t) { return '<button role="tab" data-step="' + t[0] + '" class="' + (st.step === t[0] ? "on" : "") + '">' + t[1] + "</button>"; }).join("")) + "</div>" +
      '<div id="og-body"></div>';
    $("og").innerHTML = h;
    $("og").querySelectorAll("[data-step]").forEach(function (b) { b.onclick = function () { go(b.getAttribute("data-step")); }; });
    var on = $("og").querySelector(".og-steps .on"); if (on && on.scrollIntoView) on.scrollIntoView({ block: "nearest", inline: "center" });
    if (st.step === "plan") return tabPlan();
    if (st.step === "audit") return tabAudit();
    renderStep(cur);
  }
  function go(step) { st.step = step; history.replaceState(null, "", location.pathname + location.search + "#" + step); render(); window.scrollTo(0, 0); }

  // ------------------------------------------------------------------ generic step
  function renderStep(step) {
    var inner = "";
    if (step.custom === "calendar") inner += calendarHtml();
    if (step.custom === "users") inner += usersHtml();
    if (step.custom === "import") inner += importHtml();
    if (step.custom === "review") inner += reviewHtml();
    inner += step.fields.map(fieldHtml).join("");
    $("og-body").innerHTML = '<section class="card og-card"><h2>' + step.n + ". " + esc(step.title) + "</h2>" + subFor(step) + inner + "</section>" + navHtml(step);
    bindFields(step);
    if (step.custom === "calendar") bindCalendar();
    if (step.custom === "users") bindUsers();
    if (step.custom === "review") bindReview();
    bindNav(step);
  }
  function subFor(step) {
    var t = { profile: "Who you are, on invoices and your pages.", calendar: "Lessons aren’t generated on holidays.",
      users: "Invite staff admins with the permissions they need, and your tutors.", billing: "Your default. Individual fee plans can override it.",
      invoicing: "When invoices are made and how parents get them.", payments: "Money always goes straight to your own account — TutorDeck never holds it.",
      lessons: "What tutors do after each lesson.", tutor_pay: "How tutor pay is worked out.", import: "Bring in your tutors, students, families and classes.",
      review: "Check everything, see a test invoice and pay statement, then launch." }[step.id];
    return t ? '<p class="og-sub">' + t + "</p>" : "";
  }
  function fieldHtml(f) {
    var s = st.draft, v = f.path ? S.get(s, f.path) : undefined, id = f.path ? "f-" + f.path.replace(/\./g, "-") : "", lock = !isOwner() || f.soon;
    if (!S.isVisible(f, s)) return "";
    var soon = f.soon ? '<span class="og-soon">Coming soon</span>' : "";
    var help = f.help ? '<span class="og-help">' + esc(f.help) + "</span>" : "";
    if (f.type === "group") return '<div class="og-group' + (f.soon ? " og-off" : "") + '"><h3>' + esc(f.label) + soon + "</h3>" + (f.help ? '<span class="og-help">' + esc(f.help) + "</span>" : "") + "</div>";
    if (f.type === "note") return '<div class="og-note' + (f.soon ? " og-off" : "") + '">' + (f.label ? "<b>" + esc(f.label) + "</b>" + soon + "<br>" : "") + esc(f.help || "") + "</div>";
    if (f.type === "toggle")
      return '<label class="og-check' + (f.soon ? " og-off" : "") + '"><input type="checkbox" id="' + id + '" data-path="' + f.path + '"' + (v ? " checked" : "") + (lock ? " disabled" : "") + "> <span>" + esc(f.label) + soon + "</span></label>" + help;
    if (f.type === "multi")
      return '<div class="field"><label>' + esc(f.label) + "</label>" + f.options.map(function (op) {
        var so = (f.soonOptions || []).indexOf(op[0]) > -1, on = (v || []).indexOf(op[0]) > -1;
        return '<label class="og-check' + (so ? " og-off" : "") + '"><input type="checkbox" data-multi="' + f.path + '" value="' + esc(op[0]) + '"' + (on ? " checked" : "") + (lock || so ? " disabled" : "") + "> <span>" + esc(op[1]) + (so ? '<span class="og-soon">Coming soon</span>' : "") + "</span></label>";
      }).join("") + "</div>" + help;
    var input;
    if (f.type === "textarea") {
      input = '<textarea id="' + id + '" data-path="' + f.path + '" data-type="text" rows="4" maxlength="1000"' + (lock ? " disabled" : "") + ">" + esc(v == null ? "" : v) + "</textarea>";
    } else if (f.type === "select") {
      var fe = f.path === "billing.deposit.refund_approved_by" ? S.fourEyes(st.members) : null;     // four-eyes needs a second approver
      input = '<select id="' + id + '" data-path="' + f.path + '"' + (lock ? " disabled" : "") + ">" + S.visibleOptions(f, s).map(function (op) {
        var so = (f.soonOptions || []).indexOf(op[0]) > -1, nb = !!fe && op[0] === "four_eyes" && !fe.ready;
        return '<option value="' + esc(JSON.stringify(op[0])) + '"' + (op[0] === v ? " selected" : "") + (so || nb ? " disabled" : "") + ">" + esc(op[1]) + (so ? " (coming soon)" : nb ? " (needs a second approver)" : "") + "</option>";
      }).join("") + "</select>" + (fe && !fe.ready ? '<span class="og-help" id="og-fe-why">' + esc(fe.reason) + "</span>" : "");
    } else {
      var shown = f.type === "money" ? (v == null ? "" : M.format(v, { symbol: false }).replace(/,/g, "")) : f.type === "percent" ? (v == null ? "" : String(v / 100))
        : f.type === "list" ? (v || []).join(", ") : (v == null ? "" : v);
      var t = f.type === "email" ? "email" : f.type === "color" ? "color" : (f.type === "number" || f.type === "days") ? "number" : "text";
      var extra = (f.type === "money" || f.type === "percent") ? ' inputmode="decimal"' : t === "number" ? ' min="0" step="1"' : "";
      input = '<input id="' + id + '" type="' + t + '" data-path="' + f.path + '" data-type="' + f.type + '" value="' + esc(shown) + '"' + extra + (lock ? " disabled" : "") +
        (t === "color" ? ' style="height:44px;padding:4px"' : "") + ">";
    }
    var unit = f.type === "money" ? " (S$)" : f.type === "percent" ? " (%)" : "";
    return '<div class="field' + (f.soon ? " og-off" : "") + '"><label for="' + id + '">' + esc(f.label) + unit + soon + "</label>" + input + "</div>" + help;
  }
  function readInput(el) {
    var t = el.getAttribute("data-type"), v = el.value.trim();
    if (el.type === "checkbox") return el.checked;
    if (el.tagName === "SELECT") return JSON.parse(el.value);
    if (t === "money") { var c = M.parse(v || "0"); return c == null ? NaN : c; }
    if (t === "percent") { var b = M.parse(v || "0"); return b == null ? NaN : b; }        // "9" → 900 bp, same 2-decimal parser
    if (t === "number" || t === "days") return v === "" ? 0 : Number(v);
    if (t === "list") return v ? v.split(",").map(function (x) { return Number(x.trim()); }) : [];
    return v;
  }
  function bindFields(step) {
    var body = $("og-body");
    body.querySelectorAll("[data-path]").forEach(function (el) {
      var h = function () {
        S.set(st.draft, el.getAttribute("data-path"), readInput(el));
        if (el.tagName === "SELECT" || el.type === "checkbox") { var y = window.scrollY; renderStep(step); window.scrollTo(0, y); }
        else showErrors();
      };
      el.addEventListener(el.tagName === "SELECT" || el.type === "checkbox" ? "change" : "input", h);
    });
    body.querySelectorAll("[data-multi]").forEach(function (el) {
      el.addEventListener("change", function () {
        var p = el.getAttribute("data-multi"), list = (S.get(st.draft, p) || []).slice(), i = list.indexOf(el.value);
        if (el.checked && i < 0) list.push(el.value); if (!el.checked && i > -1) list.splice(i, 1);
        S.set(st.draft, p, list); showErrors();
      });
    });
  }

  // ------------------------------------------------------------------ nav + save
  function navHtml(step) {
    if (!isOwner()) return "";
    var idx = S.STEPS.indexOf(step);
    if (setup()) {
      return '<div class="og-nav"><div class="msg" id="og-msg"></div>' + (idx > 0 ? '<button class="btn" id="og-back">Back</button>' : "") +
        (step.id === "review" ? '<button class="btn btn-primary" id="og-launch">Launch</button>' : '<button class="btn btn-primary" id="og-next">Save and continue</button>') + "</div>";
    }
    if (!step.fields.length && step.custom) return "";
    return '<div class="og-nav"><div class="msg" id="og-msg"></div><button class="btn btn-primary" id="og-save">Save changes</button></div>';
  }
  function showErrors() {
    var m = $("og-msg"); if (!m) return;
    var e = S.validate(st.draft);
    m.textContent = e.length ? e[0] + (e.length > 1 ? " (+" + (e.length - 1) + " more)" : "") : ""; m.className = "msg" + (e.length ? " err" : "");
  }
  async function saveSettings(effective) {
    var e = S.validate(st.draft);
    if (e.length) { var m = $("og-msg"); if (m) { m.textContent = e.join(" "); m.className = "msg err"; } return false; }
    if (JSON.stringify(st.draft) !== JSON.stringify(st.saved)) {
      if (S.get(st.draft, "billing.deposit.refund_approved_by") === "four_eyes" && !S.fourEyes(st.members).ready) {
        var fm = $("og-msg"); if (fm) { fm.textContent = S.fourEyes(st.members).reason; fm.className = "msg err"; } return false;
      }
      var r = await sb().rpc("org_save_settings", { p_org: st.org.id, p_settings: st.draft, p_effective_from: effective });
      if (r.error) { $("og-msg").textContent = String(r.error.message || "").replace(/^FOUR_EYES_UNAVAILABLE: /, ""); $("og-msg").className = "msg err"; return false; }
      var p = st.draft.profile;     // keep the organisation's own columns in step with the profile
      var u = await sb().from("organisations").update({ trading_name: p.trading_name, legal_name: p.legal_name || null, uen: p.uen || null,
        address: p.address || null, brand_color: p.brand_color || null, reply_to_email: p.reply_to_email || null }).eq("id", st.org.id).select("*").single();
      if (!u.error) st.org = u.data;
      st.saved = JSON.parse(JSON.stringify(st.draft));
    }
    return true;
  }
  function bindNav(step) {
    var idx = S.STEPS.indexOf(step);
    if ($("og-back")) $("og-back").onclick = function () { go(S.STEPS[idx - 1].id); };
    if ($("og-next")) $("og-next").onclick = async function () {
      $("og-next").disabled = true;
      var ok = await saveSettings(todayISO());
      if (ok && (st.org.setup_step || 1) < step.n + 1) {
        var r = await sb().from("organisations").update({ setup_step: step.n + 1 }).eq("id", st.org.id).select("*").single();
        if (!r.error) st.org = r.data;
      }
      if ($("og-next")) $("og-next").disabled = false;
      if (ok) go(S.STEPS[idx + 1].id);
    };
    if ($("og-save")) $("og-save").onclick = async function () {
      var eff = S.effectiveFrom(st.saved, st.draft, todayISO());
      $("og-save").disabled = true;
      var ok = await saveSettings(eff);
      $("og-save").disabled = false;
      if (ok) { $("og-msg").textContent = eff === todayISO() ? "Saved ✓" : "Saved ✓ — applies from " + prettyDate(eff) + " (next billing cycle)"; $("og-msg").className = "msg ok"; }
    };
    if ($("og-launch")) $("og-launch").onclick = async function () {
      var e = S.validate(st.draft);
      if (e.length) { $("og-msg").textContent = e.join(" "); $("og-msg").className = "msg err"; return; }
      if (!(await TL.confirm({ title: "Launch " + st.org.trading_name + "?", message: "Your settings go live today. You can still change them later in Settings; billing changes then apply from the next cycle.", confirmText: "Launch" }))) return;
      if (!(await saveSettings(todayISO()))) return;
      var r = await sb().from("organisations").update({ status: "active", setup_step: 10 }).eq("id", st.org.id).select("*").single();
      if (r.error) { $("og-msg").textContent = r.error.message; $("og-msg").className = "msg err"; return; }
      st.org = r.data; TL.toast(st.org.trading_name + " is live"); go("profile");
    };
  }

  // ------------------------------------------------------------------ step 2: branches, rooms, terms, holidays
  function calendarHtml() {
    var can = isOwner();
    function rm(t, id) { return can ? '<button class="og-x" data-del="' + t + '" data-id="' + esc(id) + '" aria-label="Remove">×</button>' : ""; }
    var br = st.branches.map(function (b) {
      var rooms = st.rooms.filter(function (r) { return r.branch_id === b.id; });
      return '<div class="og-item"><div class="grow"><b>' + esc(b.name) + "</b>" + (b.address ? '<div class="meta">' + esc(b.address) + "</div>" : "") +
        '<div class="meta">Rooms: ' + (rooms.map(function (r) { return esc(r.name) + (r.capacity ? " (" + r.capacity + ")" : ""); }).join(", ") || "none") + "</div></div>" +
        (can ? '<button class="btn" data-addroom="' + esc(b.id) + '" style="height:34px;padding:0 12px">+ Room</button>' : "") + rm("branches", b.id) + "</div>";
    }).join("");
    function dated(list, t) { return list.map(function (x) { return '<div class="og-item"><div class="grow"><b>' + esc(x.name) + '</b><div class="meta">' + esc(prettyDate(x.starts_on)) + " – " + esc(prettyDate(x.ends_on)) + "</div></div>" + rm(t, x.id) + "</div>"; }).join(""); }
    return "<h3>Branches</h3><div class=\"og-list\">" + (br || '<p class="muted" style="font-size:13px;margin:0">No branches yet. One is enough for a single centre.</p>') + "</div>" +
      (can ? '<div class="og-row"><div class="field"><label for="b-name">Branch name</label><input id="b-name" type="text" placeholder="e.g. Tampines"></div><div class="field"><label for="b-addr">Address (optional)</label><input id="b-addr" type="text"></div></div><button class="btn" id="b-add">Add branch</button>' : "") +
      "<h3>Terms</h3><div class=\"og-list\">" + (dated(st.terms, "terms") || '<p class="muted" style="font-size:13px;margin:0">No terms yet (only needed for per-term fees).</p>') + "</div>" +
      (can ? dateForm("t", "Term name", "e.g. Term 1 2027") : "") +
      libraryHtml(can) +
      "<h3>Holidays</h3><div class=\"og-list\">" + (dated(st.holidays, "holidays") || '<p class="muted" style="font-size:13px;margin:0">No holidays yet.</p>') + "</div>" +
      (can ? dateForm("h", "Holiday", "e.g. Chinese New Year") : "") + "<h3>Rule</h3>";
  }
  // Singapore public holidays (assets/data/sg-public-holidays.json). Nothing ticked by default; ticking inserts a normal `holidays` row.
  var HL = window.HolidayLibrary;
  function shortDate(iso) { return new Date(iso + "T00:00:00Z").toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" }); }
  function libraryHtml(can) {
    var head = "<h3>Singapore public holidays</h3>";
    if (!st.lib || !HL) return head + '<p class="og-help" style="margin-top:0">The holiday list could not be loaded. You can still add holidays below.</p>';
    var m = st.lib._meta || {}, groups = HL.byYear(st.lib);
    var out = head + '<p class="og-help" style="margin-top:0">Optional. Tick the days your centre is closed; nothing is added unless you tick it. Monday substitutes are not included in “Select all”. Source: Ministry of Manpower, checked ' + esc(shortDate(m.fetched_on || "2026-01-01")) + ".</p>";
    groups.forEach(function (g) {
      out += '<div class="og-hol"><div class="og-hol-head"><b>' + g.year + "</b>" + (can ? '<span class="og-hol-btns"><button class="btn" type="button" data-hsel="' + g.year + '">Select all for ' + g.year + '</button><button class="btn" type="button" data-hclr="' + g.year + '">Clear</button></span>' : "") + '</div><div class="og-hol-list">';
      g.rows.forEach(function (h) {
        var mt = HL.match(st.holidays, h), on = !!mt, rangeOnly = on && !mt.exact;
        var meta = shortDate(h.date) + (h.substitute_for ? " · only if you also close on the Monday" : "") + (rangeOnly ? " · part of “" + esc(mt.row.name) + "”" : "");
        out += '<label class="og-check og-hol-row"><input type="checkbox" data-hol="' + esc(h.date) + '"' + (on ? " checked" : "") + (!can || rangeOnly ? " disabled" : "") + '><span><span class="og-hol-name">' + esc(h.name) + '</span>' +
          (h.status === "to_confirm" ? ' <span class="og-badge grey">To confirm</span>' : "") + '<span class="meta og-hol-meta">' + meta + "</span></span></label>";
      });
      out += "</div></div>";
    });
    var none = (m.years_not_published_yet || []).map(function (y) { return y + ": not published yet"; });
    return out + (none.length ? '<p class="og-help">' + esc(none.join(" · ")) + ".</p>" : "");
  }
  async function libWrite(fn) {
    if (st.libBusy) return; st.libBusy = true;
    try { await fn(); await loadSide(); } catch (e) { TL.alert(e.message || String(e)); try { await loadSide(); } catch (e2) {} }
    st.libBusy = false; var y = window.scrollY; renderStep(S.STEPS[1]); window.scrollTo(0, y);
  }
  function bindLibrary() {
    var body = $("og-body");
    body.querySelectorAll("[data-hol]").forEach(function (cb) {
      cb.onchange = function () {
        var h = st.lib.holidays.filter(function (x) { return x.date === cb.getAttribute("data-hol"); })[0]; if (!h) return;
        libWrite(async function () {
          var mt = HL.match(st.holidays, h);
          if (cb.checked) {
            if (mt) return; // already has a row for that day: never double up
            var r = await sb().from("holidays").insert(Object.assign({ org_id: st.org.id }, HL.toRow(h))); if (r.error) throw r.error;
          } else if (mt && mt.exact) {
            var d = await sb().from("holidays").delete().eq("id", mt.row.id); if (d.error) throw d.error;
          }
        });
      };
    });
    body.querySelectorAll("[data-hsel]").forEach(function (b) {
      b.onclick = function () {
        var y = +b.getAttribute("data-hsel");
        libWrite(async function () {
          await loadSide(); var rows = HL.toTick(st.holidays, st.lib, y); if (!rows.length) return;
          var r = await sb().from("holidays").insert(rows.map(function (x) { return Object.assign({ org_id: st.org.id }, x); })); if (r.error) throw r.error;
        });
      };
    });
    body.querySelectorAll("[data-hclr]").forEach(function (b) {
      b.onclick = async function () {
        var y = +b.getAttribute("data-hclr"), ids = HL.toClear(st.holidays, st.lib, y);
        if (!ids.length) return TL.toast("Nothing ticked for " + y);
        if (!(await TL.confirm({ title: "Clear " + ids.length + " holiday" + (ids.length === 1 ? "" : "s") + " for " + y + "?", message: "Removes the ticked Singapore public holidays for " + y + ". Holidays you added yourself are kept.", confirmText: "Clear", danger: true }))) return;
        libWrite(async function () { var d = await sb().from("holidays").delete().in("id", ids); if (d.error) throw d.error; });
      };
    });
  }
  function dateForm(p, label, ph) {
    return '<div class="og-row"><div class="field"><label for="' + p + '-name">' + label + '</label><input id="' + p + '-name" type="text" placeholder="' + ph + '"></div>' +
      '<div class="og-row" style="gap:8px"><div class="field"><label for="' + p + '-from">From</label><input id="' + p + '-from" type="date"></div><div class="field"><label for="' + p + '-to">To</label><input id="' + p + '-to" type="date"></div></div></div>' +
      '<button class="btn" id="' + p + '-add">Add</button>';
  }
  async function addRow(table, row) {
    var r = await sb().from(table).insert(Object.assign({ org_id: st.org.id }, row));
    if (r.error) { TL.alert(r.error.message); return; }
    await loadSide(); var y = window.scrollY; renderStep(S.STEPS[1]); window.scrollTo(0, y);
  }
  function bindCalendar() {
    var body = $("og-body"); if (st.lib && HL) bindLibrary();
    if ($("b-add")) $("b-add").onclick = function () { var n = $("b-name").value.trim(); if (!n) return $("b-name").focus(); addRow("branches", { name: n, address: $("b-addr").value.trim() || null }); };
    [["t", "terms"], ["h", "holidays"]].forEach(function (x) {
      if (!$(x[0] + "-add")) return;
      $(x[0] + "-add").onclick = function () {
        var n = $(x[0] + "-name").value.trim(), a = $(x[0] + "-from").value, b = $(x[0] + "-to").value || a;
        if (!n || !a) return TL.alert("Give it a name and a start date.");
        if (b < a) return TL.alert("The end date is before the start date.");
        addRow(x[1], { name: n, starts_on: a, ends_on: b });
      };
    });
    body.querySelectorAll("[data-addroom]").forEach(function (b) {
      b.onclick = async function () {
        var n = await TL.prompt({ title: "Add a room", placeholder: "e.g. Room 2", confirmText: "Add" });
        if (n) addRow("rooms", { branch_id: b.getAttribute("data-addroom"), name: n });
      };
    });
    body.querySelectorAll("[data-del]").forEach(function (b) {
      b.onclick = async function () {
        if (!(await TL.confirm({ title: "Remove this?", confirmText: "Remove", danger: true }))) return;
        var r = await sb().from(b.getAttribute("data-del")).delete().eq("id", b.getAttribute("data-id"));
        if (r.error) return TL.alert(r.error.message);
        await loadSide(); renderStep(S.STEPS[1]);
      };
    });
  }

  // ------------------------------------------------------------------ step 3: users & permissions
  function permBoxes(prefix, on, disabled) {
    return '<div class="og-perms">' + S.STAFF_PERMISSIONS.map(function (p) {
      return '<label><input type="checkbox" data-' + prefix + '="' + p.key + '"' + (on.indexOf(p.key) > -1 ? " checked" : "") + (disabled ? " disabled" : "") + "> " + esc(p.label) + "</label>";
    }).join("") + "</div>";
  }
  function usersHtml() {
    var can = isOwner();
    var list = st.members.map(function (m) {
      var role = { owner: "Owner", staff: "Staff admin", tutor: "Tutor", parent: "Parent" }[m.role];
      return '<div class="og-item" style="align-items:flex-start"><div class="grow"><b>' + esc(m.display_name) + "</b> " +
        (m.status === "invited" ? '<span class="og-badge grey">Invited</span>' : m.status === "disabled" ? '<span class="og-badge grey">Off</span>' : "") +
        '<div class="meta">' + esc(role) + (m.employment_type ? " · " + esc(m.employment_type) : "") + (m.invited_email ? " · " + esc(m.invited_email) : "") + "</div>" +
        (m.role === "staff" ? permBoxes("mp-" + m.id, m.permissions || [], !can) : "") + "</div>" +
        (can && m.role !== "owner" ? '<button class="og-x" data-mstatus="' + esc(m.id) + '" title="' + (m.status === "disabled" ? "Turn back on" : "Turn off access") + '">' + (m.status === "disabled" ? "↺" : "×") + "</button>" : "") + "</div>";
    }).join("");
    return '<div class="og-list">' + list + "</div>" + (can ?
      '<h3>Invite someone</h3><div class="og-row"><div class="field"><label for="i-name">Name</label><input id="i-name" type="text" maxlength="60"></div>' +
      '<div class="field"><label for="i-email">Email</label><input id="i-email" type="email"></div></div>' +
      '<div class="og-row"><div class="field"><label for="i-role">Role</label><select id="i-role"><option value="tutor">Tutor</option><option value="staff">Staff admin</option></select></div>' +
      '<div class="field" id="i-emp-w"><label for="i-emp">Employment</label><select id="i-emp"><option value="freelancer">Freelancer</option><option value="employee">Employee</option></select></div></div>' +
      '<div id="i-perms-w" style="display:none"><label style="font-size:13px;font-weight:700">Permissions</label>' + permBoxes("ip", ["manage_timetable", "manage_students"], false) + "</div>" +
      '<button class="btn" id="i-go" style="margin-top:10px">Send invite</button><span class="og-help" style="margin:8px 0 0">They’re linked when they sign in with that email. Invite emails come with the email provider (coming soon) — for now, tell them to sign up.</span>' +
      '<p class="og-help" style="margin-top:12px">Tutor CSV import is in step 9.</p>' : "");
  }
  function bindUsers() {
    var body = $("og-body");
    if ($("i-role")) $("i-role").onchange = function () {
      var staff = $("i-role").value === "staff"; $("i-perms-w").style.display = staff ? "" : "none"; $("i-emp-w").style.display = staff ? "none" : "";
    };
    if ($("i-go")) $("i-go").onclick = async function () {
      var name = $("i-name").value.trim(), email = $("i-email").value.trim(), role = $("i-role").value;
      if (!name || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return TL.alert("Enter a name and a valid email.");
      var perms = []; body.querySelectorAll("[data-ip]:checked").forEach(function (c) { perms.push(c.getAttribute("data-ip")); });
      var r = await sb().rpc("org_invite", { p_org: st.org.id, p_email: email, p_name: name, p_role: role, p_perms: role === "staff" ? perms : null, p_employment: role === "tutor" ? $("i-emp").value : null });
      if (r.error) return TL.alert(r.error.message);
      await loadSide(); renderStep(S.STEPS[2]); TL.toast(name + " invited");
    };
    st.members.forEach(function (m) {
      var boxes = body.querySelectorAll("[data-mp-" + m.id + "]");
      boxes.forEach(function (c) {
        c.onchange = async function () {
          var perms = []; boxes.forEach(function (x) { if (x.checked) perms.push(x.getAttribute("data-mp-" + m.id)); });
          var r = await sb().rpc("org_update_member", { p_member: m.id, p_role: null, p_perms: perms, p_status: null });
          if (r.error) { TL.alert(r.error.message); c.checked = !c.checked; return; }
          m.permissions = perms; TL.toast("Permissions saved");
        };
      });
    });
    body.querySelectorAll("[data-mstatus]").forEach(function (b) {
      b.onclick = async function () {
        var m = st.members.filter(function (x) { return x.id === b.getAttribute("data-mstatus"); })[0];
        var off = m.status !== "disabled";
        if (off && !(await TL.confirm({ title: "Turn off " + m.display_name + "’s access?", message: "They keep their history; they just can’t sign in to this centre.", confirmText: "Turn off", danger: true }))) return;
        var r = await sb().rpc("org_update_member", { p_member: m.id, p_role: null, p_perms: null, p_status: off ? "disabled" : (m.user_id ? "active" : "invited") });
        if (r.error) return TL.alert(r.error.message);
        await loadSide(); renderStep(S.STEPS[2]);
      };
    });
  }

  // ------------------------------------------------------------------ step 9: import (coming soon)
  function importHtml() {
    return '<div class="og-note og-off"><b>CSV import</b><span class="og-soon">Coming soon</span><br>Templates for tutors, students (level, subjects, class, fee plan), parents and households, and classes. ' +
      "Every row is checked first and errors are shown line by line; nothing is saved until the whole file passes.</div>" +
      '<p class="og-sub" style="margin:0">You can skip this step and add people by hand.</p>';
  }

  // ------------------------------------------------------------------ step 10: review + test documents
  function reviewHtml() {
    var errs = S.validate(st.draft);
    var sum = S.STEPS.filter(function (x) { return x.n < 10; }).map(function (x) {
      var rows = x.fields.filter(function (f) { return f.type !== "note" && f.type !== "group" && S.isVisible(f, st.draft); }).map(function (f) {
        return "<tr><td>" + esc(f.label) + (f.soon ? ' <span class="og-soon">Soon</span>' : "") + "</td><td>" + esc(S.display(f, S.get(st.draft, f.path))) + "</td></tr>";
      });
      if (x.id === "calendar") rows.unshift("<tr><td>Branches / terms / holidays</td><td>" + st.branches.length + " / " + st.terms.length + " / " + st.holidays.length + "</td></tr>");
      if (x.id === "users") rows.push("<tr><td>People</td><td>" + st.members.length + "</td></tr>");
      if (x.id === "import") rows.push("<tr><td>CSV import</td><td>Coming soon</td></tr>");
      return '<div class="og-sum-h"><h3>' + x.n + ". " + esc(x.title) + '</h3><button class="og-link" data-goto="' + x.id + '">Edit</button></div><table class="og-sum"><tbody>' + rows.join("") + "</tbody></table>";
    }).join("");
    return (errs.length ? '<p class="msg err">' + esc(errs.join(" ")) + "</p>" : "") + sum +
      "<h3 style=\"margin-top:22px\">Test invoice</h3>" + testInvoice() + "<h3>Test pay statement</h3>" + testPay();
  }
  function bindReview() { $("og-body").querySelectorAll("[data-goto]").forEach(function (b) { b.onclick = function () { go(b.getAttribute("data-goto")); }; }); }

  // A sample family of two children, four S$40 lessons each, billed with these settings.
  function testInvoice() {
    var s = st.draft, p = s.profile, b = s.billing, fee = 4000, lines = [];
    ["Alice", "Ben"].forEach(function (kid, i) {
      lines.push({ text: kid + " · 4 lessons × S$40.00", cents: 4 * fee });
      var d = b.sibling_discount.type === "none" ? 0 : 4 * M.siblingDiscount(fee, i + 1, b.sibling_discount);
      if (d) lines.push({ text: "Sibling discount (" + kid + ")", cents: -d });
    });
    if (s.invoicing.grouping === "student") lines = lines.slice(0, 1);
    var t = M.invoiceTotals(lines, p), col = /^#[0-9a-f]{6}$/i.test(p.brand_color || "") ? p.brand_color : "#0F766E";
    var pay = (s.payments.modes || []).map(function (m) {
      return m === "manual_paynow" ? "PayNow to " + esc(p.uen || s.payments.paynow.id || "your UEN") + " — use the invoice number as the reference" : "";
    }).filter(Boolean).join("<br>");
    var due = new Date(Date.now() + s.invoicing.due_days * 864e5).toISOString().slice(0, 10);
    return '<div class="og-doc"><div class="bar" style="background:' + col + '"></div><div class="in">' +
      '<div style="display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap"><div><h4>' + (p.gst_registered ? "Tax invoice" : "Invoice") + "</h4>" +
      '<div class="small">' + esc(p.invoice_prefix) + "-" + String(p.next_invoice_number).padStart(5, "0") + " · due " + esc(prettyDate(due)) + (s.invoicing.review_before_sending ? " · draft until approved" : "") + "</div></div>" +
      '<div style="text-align:right"><b>' + esc(p.trading_name) + "</b>" + (p.uen ? '<div class="small">UEN ' + esc(p.uen) + "</div>" : "") + (p.gst_registered && p.gst_number ? '<div class="small">GST reg. ' + esc(p.gst_number) + "</div>" : "") + "</div></div>" +
      "<table>" + lines.map(function (l) { return "<tr><td>" + esc(l.text) + "</td><td>" + M.format(l.cents) + "</td></tr>"; }).join("") +
      (p.gst_registered ? "<tr><td>" + (p.gst_inclusive ? "Includes GST " : "GST ") + esc(p.gst_rate_bp / 100) + "%</td><td>" + M.format(t.gst) + "</td></tr>" : "") +
      '<tr class="tot"><td>Total</td><td>' + M.format(t.total) + "</td></tr></table>" +
      '<div class="small">' + (pay || "Payment details appear here.") + "</div></div></div>" +
      '<p class="og-help" style="margin:8px 0 0">GST is worked out once on the invoice total, rounded half up.</p>';
  }
  // A sample tutor: 8 lessons of 90 minutes with 3 students, S$30 rate.
  function testPay() {
    var tp = st.draft.tutor_pay;
    if (tp.mode === "off") return '<p class="og-sub" style="margin:0">Tutor pay is off.</p>';
    var rate = 3000, each = M.tutorPay(tp.rate_model === "monthly_fixed" ? "per_lesson" : tp.rate_model, rate, { minutes: 90, students: 3 });
    var total = tp.rate_model === "monthly_fixed" ? 150000 : each * 8;
    var held = tp.payable_when === "parent_paid" ? 2 : 0;
    var lbl = { per_lesson: "S$30 per lesson", per_hour: "S$30 per hour", per_student_lesson: "S$30 per student per lesson", monthly_fixed: "S$1,500.00 a month" }[tp.rate_model];
    return '<div class="og-doc"><div class="in"><h4>Pay statement · Sam Tan (freelancer)</h4><div class="small">' + (tp.mode === "report" ? "Lessons-taught report" : "Pay period ending day " + esc(tp.cycle.cutoff_day)) + "</div>" +
      "<table><tr><td>8 lessons × 90 min, 3 students · " + lbl + "</td><td>" + (tp.mode === "report" ? "8 lessons" : M.format(total)) + "</td></tr>" +
      (held && tp.mode !== "report" ? "<tr><td>Pending: 2 lessons whose fees aren’t paid yet (roll into the next period)</td><td>" + M.format(-each * held) + "</td></tr>" +
        '<tr class="tot"><td>Payable now</td><td>' + M.format(total - each * held) + "</td></tr>" : "") + "</table>" +
      (tp.mode === "full" ? "" : '<div class="small">Full pay calculation is coming soon; this shows what tutors would see.</div>') + "</div></div>";
  }

  // ------------------------------------------------------------------ Plan (TutorDeck's fee, same number as the platform sees)
  async function tabPlan() {
    $("og-body").innerHTML = '<section class="card og-card"><h2>Your TutorDeck plan</h2><div id="pl" class="muted">Loading…</div></section>';
    var q = await Promise.all([
      sb().from("org_plans").select("*").eq("org_id", st.org.id).lte("effective_from", todayISO()).order("effective_from", { ascending: false }).limit(1),
      sb().from("platform_fee_snapshots").select("*").eq("org_id", st.org.id).order("month", { ascending: false }).limit(6)
    ]);
    var plan = (q[0].data || [])[0], snaps = q[1].data || [];
    if (!plan) { $("pl").textContent = isOwner() ? "No plan yet." : "Only the owner sees the plan."; return; }
    var ex = [98, 250, 405].map(function (n) { var f = M.platformFee(n, plan); return n + " students → " + f.billable + " billable → " + M.format(f.fee_cents); });
    $("pl").className = "";
    $("pl").innerHTML = '<p class="og-sub">' + M.format(plan.base_cents) + " a month + " + M.format(plan.per_student_cents) + " per billable student. " +
      "Billable students are last month’s active students (anyone with an attended, absent or late-cancelled lesson, not trials), rounded to the nearest 10.</p>" +
      '<div class="og-note">For example: ' + ex.join(" · ") + "</div>" +
      (snaps.length ? '<table class="og-sum"><tbody>' + snaps.map(function (s) {
        return "<tr><td>" + esc(new Date(s.month + "T00:00:00").toLocaleDateString("en-SG", { month: "long", year: "numeric" })) + "</td><td>" + esc(s.active_students) + " active → " + esc(s.billable_students) + " billable → <b>" + M.format(s.fee_cents) + "</b></td></tr>";
      }).join("") + "</tbody></table>" : '<p class="og-sub" style="margin:0">Your first monthly count appears here after your first full month.</p>');
  }

  // ------------------------------------------------------------------ Audit log
  async function tabAudit() {
    $("og-body").innerHTML = '<section class="card og-card"><h2>Audit log</h2><p class="og-sub">Who changed what: settings, people, students, lessons and invoices. It can’t be edited or deleted.</p><div id="au" class="muted">Loading…</div></section>';
    var r = await sb().from("audit_log").select("*").eq("org_id", st.org.id).order("at", { ascending: false }).limit(200);
    if (r.error) { $("au").textContent = r.error.message; return; }
    if (!r.data.length) { $("au").textContent = isOwner() ? "Nothing yet." : "Your permissions don’t include the audit log."; return; }
    var who = {}; st.members.forEach(function (m) { if (m.user_id) who[m.user_id] = m.display_name; });
    var T = { organisations: "Organisation", memberships: "Person", org_settings: "Settings", org_plans: "Plan", support_access_grants: "Support access",
      branches: "Branch", rooms: "Room", terms: "Term", holidays: "Holiday", households: "Family", guardians: "Parent", students: "Student",
      recurring_slots: "Weekly slot", lessons: "Lesson", invoices: "Invoice" };
    var A = { insert: "added", update: "changed", delete: "removed", migrate: "set up" };
    function what(a) {
      var x = a.after || a.before || {};
      if (a.table_name === "org_settings") return "version " + x.version + (x.effective_from ? " from " + prettyDate(x.effective_from) : "");
      if (a.table_name === "memberships") return x.display_name || "";
      return x.name || x.invoice_no || x.trading_name || x.lesson_date || "";
    }
    $("au").className = "";
    $("au").innerHTML = '<div style="overflow-x:auto"><table class="og-audit" style="width:100%;border-collapse:collapse"><tbody>' + r.data.map(function (a) {
      var d = new Date(a.at);
      return '<tr><td class="when">' + esc(d.toLocaleDateString("en-SG", { day: "numeric", month: "short" }) + " " + d.toLocaleTimeString("en-SG", { hour: "numeric", minute: "2-digit" })) + "</td>" +
        "<td><b>" + esc((T[a.table_name] || a.table_name || "") + " " + (A[a.action] || a.action)) + "</b> " + esc(what(a)) + "</td><td>" + esc(who[a.actor] || (a.actor ? "Someone" : "System")) + "</td></tr>";
    }).join("") + "</tbody></table></div>";
  }

  TL.requireAuth("org", init);
})();
