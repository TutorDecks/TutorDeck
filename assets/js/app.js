// =====================================================================
// TL core — auth guard + app shell + shared helpers
// Every protected page calls:  TL.requireAuth("dashboard", initFn)
// =====================================================================
window.TL = (function () {
  var OWNER_ID = "ad4e2f4f-90c9-4fd9-8d51-e85b0e0bebb4";  // only this account sees Materials
  var isOwner = false;
  // Navigation is grouped by job. Each group is one tab (bottom bar on phones, sidebar on
  // desktop); its pages show as sub-tabs under the page title.
  var ICONS = {
    home:     '<path d="M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8"/><path d="M3 10a2 2 0 0 1 .709-1.528l7-5.999a2 2 0 0 1 2.582 0l7 5.999A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
    schedule: '<path d="M8 2v4"/><path d="M16 2v4"/><rect width="18" height="18" x="3" y="4" rx="2"/><path d="M3 10h18"/><path d="M8 14h.01"/><path d="M12 14h.01"/><path d="M16 14h.01"/><path d="M8 18h.01"/><path d="M12 18h.01"/>',
    students: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>',
    money:    '<path d="M19 7V4a1 1 0 0 0-1-1H5a2 2 0 0 0 0 4h15a1 1 0 0 1 1 1v4h-3a2 2 0 0 0 0 4h3a1 1 0 0 0 1-1v-2a1 1 0 0 0-1-1"/><path d="M3 5v14a2 2 0 0 0 2 2h15a1 1 0 0 0 1-1v-4"/>',
    more:     '<circle cx="12" cy="12" r="1.4"/><circle cx="19" cy="12" r="1.4"/><circle cx="5" cy="12" r="1.4"/>',
    settings: '<path d="M20 7h-9"/><path d="M14 17H5"/><circle cx="17" cy="17" r="3"/><circle cx="7" cy="7" r="3"/>',
    materials:'<path d="M12 7v14"/><path d="M3 18a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h5a4 4 0 0 1 4 4 4 4 0 0 1 4-4h5a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1h-6a3 3 0 0 0-3 3 3 3 0 0 0-3-3z"/>',
    signout:  '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><path d="m16 17 5-5-5-5"/><path d="M21 12H9"/>'
  };
  function icon(name, size) {
    var z = size || 20;
    return '<svg class="i" width="' + z + '" height="' + z + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
           'stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + (ICONS[name] || "") + '</svg>';
  }
  var GROUPS = [
    { id: "home",     label: "Home",     ic: "home",     pages: [ { id: "dashboard", label: "Dashboard", href: "home" } ] },
    { id: "schedule", label: "Schedule", ic: "schedule", pages: [ { id: "calendar", label: "Calendar", href: "calendar" },
                                                                  { id: "planner",  label: "Weekly planner", href: "planner" } ] },
    { id: "students", label: "Students", ic: "students", pages: [ { id: "students", label: "Roster", href: "students" },
                                                                  { id: "exams",    label: "Exams",  href: "exams" } ],
      also: ["student"] },
    { id: "money",    label: "Money",    ic: "money",    pages: [ { id: "ledger",   label: "Ledger",   href: "ledger" },
                                                                  { id: "invoices", label: "Invoices", href: "invoices" },
                                                                  { id: "insights", label: "Insights", href: "insights" } ] }
  ];
  // Secondary destinations: sidebar footer on desktop, "More" sheet on phones.
  var EXTRA = [
    { id: "materials", label: "Materials", href: "materials", ic: "materials", ownerOnly: true },
    { id: "settings",  label: "Settings",  href: "settings",  ic: "settings" }
  ];
  function groupOf(active) {
    for (var i = 0; i < GROUPS.length; i++) {
      var g = GROUPS[i];
      if ((g.also || []).indexOf(active) > -1) return g;
      for (var j = 0; j < g.pages.length; j++) if (g.pages[j].id === active) return g;
    }
    return null;
  }

  // TutorDeck product mark (same art as assets/img/logo.svg), inline so it never flashes.
  var LOGO = '<svg class="td-logo" viewBox="0 0 32 32" width="32" height="32" aria-hidden="true">' +
    '<rect width="32" height="32" rx="8" fill="#0F766E"/>' +
    '<rect x="10.5" y="6.5" width="14" height="17.5" rx="2.6" fill="#fff" fill-opacity=".42" transform="rotate(9 17.5 15)"/>' +
    '<rect x="8" y="8.5" width="14" height="17.5" rx="2.6" fill="#fff"/>' +
    '<rect x="10.6" y="12.2" width="8.8" height="1.9" rx=".95" fill="#0F766E"/>' +
    '<rect x="10.6" y="16" width="6.2" height="1.9" rx=".95" fill="#0F766E" fill-opacity=".55"/></svg>';
  var DEFAULT_BRAND = "TutorDeck";
  var brandName = DEFAULT_BRAND;   // set per-user from profiles.business_name in requireAuth

  // Two-letter badge from the brand: initials of the first two words
  // ("T-Leng Tuition" → "TL", "Raphael Tuition" → "RT"), else first two letters.
  function monogram(name) {
    if (name === DEFAULT_BRAND) return "TD";
    var w = String(name || "").split(/[\s-]+/).filter(function (t) { return /[A-Za-z0-9]/.test(t); });
    var s = w.length >= 2 ? (w[0][0] + w[1][0]) : (w[0] || "").slice(0, 2);
    return s.toUpperCase() || "TD";
  }

  function esc(s) {
    return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  // "Raphael Tuition" → "Raphael Tuition's"; a name already ending in s takes just "'".
  function possessive(name) {
    var s = String(name || "");
    return /s$/i.test(s) ? s + "’" : s + "’s";
  }

  // Account avatar: the tutor's own initials ("Alex Tan" → "AT"); without a name, the business monogram.
  function acctInitials() { return helloFull ? monogram(helloFull) : monogram(brandName); }
  function mono() {
    return '<span class="mono">' + esc(monogram(brandName)) + '</span><span><b>' +
           esc(brandName === DEFAULT_BRAND ? brandName : possessive(brandName)) + '</b><small>Dashboard</small></span>';
  }

  function configBanner() {
    if (window.TL_CONFIGURED) return "";
    return '<div class="note-banner">⚙︎ Not connected yet — paste your Supabase ' +
           'URL and anon key into <code>assets/js/config.js</code> to enable sign-in and data.</div>';
  }

  // Build sidebar + topbar around the page's <div id="view">
  function mountShell(active, email, title, sub) {
    var grp = groupOf(active);
    var extras = EXTRA.filter(function (n) { return !n.ownerOnly || isOwner; });
    var onExtra = extras.some(function (n) { return n.id === active; });

    // Desktop top bar: brand · the four groups · Settings/Materials icons + account menu.
    var side = GROUPS.map(function (g) {
      return '<a href="' + g.pages[0].href + '" class="' + (grp === g ? "active" : "") + '"' +
             (grp === g ? ' aria-current="page"' : "") + '>' + icon(g.ic, 18) + '<span>' + g.label + '</span></a>';
    }).join("");
    var sideExtra = extras.map(function (n) {
      return '<a href="' + n.href + '" class="tn-ic' + (n.id === active ? " active" : "") + '" title="' + n.label +
             '" aria-label="' + n.label + '">' + icon(n.ic, 19) + '</a>';
    }).join("");
    var initials = acctInitials();

    // Phone bottom bar: the four groups + More.
    var bar = GROUPS.map(function (g) {
      return '<a href="' + g.pages[0].href + '" class="' + (grp === g ? "on" : "") + '"' +
             (grp === g ? ' aria-current="page"' : "") + '>' + icon(g.ic, 22) + '<span>' + g.label + '</span></a>';
    }).join("") +
      '<button type="button" id="tl-more" class="' + (onExtra ? "on" : "") + '" aria-haspopup="dialog" aria-expanded="false">' +
      icon("more", 22) + '<span>More</span></button>';

    // Sub-tabs: the other pages in this group (hidden when the group has one page).
    var subtabs = "";
    if (grp && grp.pages.length > 1 && grp.pages.some(function (p) { return p.id === active; })) {
      subtabs = '<nav class="subtabs" aria-label="' + grp.label + '">' + grp.pages.map(function (p) {
        return '<a href="' + p.href + '" class="' + (p.id === active ? "on" : "") + '"' +
               (p.id === active ? ' aria-current="page"' : "") + '>' + p.label + '</a>';
      }).join("") + '</nav>';
    }

    var sheet = '<div class="more-sheet" id="tl-sheet" role="dialog" aria-label="More">' +
      '<div class="ms-grab"></div>' +
      '<div class="ms-brand">' + LOGO + '<span><b>' + esc(brandName) + '</b><small>TutorDeck</small></span></div>' +
      extras.map(function (n) {
        return '<a href="' + n.href + '" class="' + (n.id === active ? "on" : "") + '">' + icon(n.ic) + '<span>' + n.label + '</span></a>';
      }).join("") +
      '<div class="ms-who">' + esc(email || "") + '</div>' +
      '<button type="button" class="ms-out" id="tl-signout-m">' + icon("signout") + '<span>Sign out</span></button>' +
      '</div>';

    var view = document.getElementById("view");
    var inner = view.innerHTML;
    var app = document.createElement("div");
    app.className = "app";
    app.innerHTML = `
      <header class="topnav">
        <div class="tn-in">
          <a class="tn-brand" href="home" aria-label="TutorDeck home">${LOGO}<b>TutorDeck</b></a>
          <nav class="tn-links" aria-label="Main">${side}</nav>
          <div class="tn-right">
            ${sideExtra}
            <div class="tn-acct">
              <button type="button" id="tl-acct" class="tn-avatar" aria-haspopup="true" aria-expanded="false" aria-label="Account" title="${esc(brandName)}">${esc(initials)}</button>
              <div class="tn-menu" id="tl-acct-menu">
                <div class="tn-who"><b>${esc(brandName)}</b>${esc(email || "")}</div>
                <button id="tl-signout">${icon("signout", 16)}<span>Sign out</span></button>
              </div>
            </div>
          </div>
        </div>
      </header>
      <div class="main">
        <div class="topbar">
          <div><h1>${title}</h1>${sub ? `<div class="sub">${sub}</div>` : ""}</div>
        </div>
        ${subtabs}
        ${configBanner()}
        <div class="content" id="content">${inner}</div>
      </div>
      <nav class="tabbar" aria-label="Main">${bar}</nav>
      <div class="nav-scrim" id="tl-scrim"></div>
      ${sheet}`;
    document.body.innerHTML = "";
    document.body.appendChild(app);
    document.getElementById("tl-signout").addEventListener("click", signOut);
    document.getElementById("tl-signout-m").addEventListener("click", signOut);
    // Desktop account menu
    var acct = document.getElementById("tl-acct"), acctWrap = acct.parentNode;
    acct.addEventListener("click", function (e) { e.stopPropagation(); var o = !acctWrap.classList.contains("open");
      acctWrap.classList.toggle("open", o); acct.setAttribute("aria-expanded", o ? "true" : "false"); });
    document.addEventListener("click", function (e) { if (!acctWrap.contains(e.target)) { acctWrap.classList.remove("open"); acct.setAttribute("aria-expanded", "false"); } });
    // Phone "More" sheet: opens from the bottom; scrim / Esc / a link closes it.
    var more = document.getElementById("tl-more"), scrim = document.getElementById("tl-scrim");
    function setSheet(open) { app.classList.toggle("sheet-open", open); more.setAttribute("aria-expanded", open ? "true" : "false"); }
    more.addEventListener("click", function () { setSheet(!app.classList.contains("sheet-open")); });
    scrim.addEventListener("click", function () { setSheet(false); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape") { setSheet(false); acctWrap.classList.remove("open"); } });
    // Client view: one floating eye on every page. Tap = hide money instantly (no reload), tap again = show.
    CV_ACTIVE = active;
    if (!document.getElementById("td-cv")) {
      var cvb = document.createElement("button");
      cvb.type = "button"; cvb.id = "td-cv"; cvb.className = "cv-fab";
      document.body.appendChild(cvb);
      cvb.addEventListener("click", function (e) { e.stopPropagation(); setClient(!CLIENT); });
    }
    applyClient();
    // First-time tip on whichever page a new user opens first (not over the Calendar's own first tip).
    var calTipsPending = active === "calendar" && !store.get("td_tip_cal-filters");
    // Home decides for itself once its cards are drawn (not alongside the setup or Get paid faster card).
    if (!CLIENT && !calTipsPending && active !== "dashboard") setTimeout(cvTip, 700);

    enhanceForms();
    // Phones: a page's main "add" button (marked data-fab) becomes a floating + at bottom right,
    // inside thumb reach. The original button stays in the DOM (hidden on phones) and does the work.
    var fabSrc = document.querySelector("[data-fab]");
    if (fabSrc && !document.getElementById("td-fab")) {
      var fab = document.createElement("button");
      fab.type = "button"; fab.id = "td-fab"; fab.className = "td-fab";
      fab.setAttribute("aria-label", fabSrc.getAttribute("data-fab"));
      fab.innerHTML = '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>';
      fab.addEventListener("click", function (e) { e.stopPropagation(); fabSrc.click(); });
      document.body.appendChild(fab);
    }
    // Tapping the tab you're already on: scroll to the top and tell the page (Calendar jumps to today).
    document.querySelectorAll(".tabbar a.on").forEach(function (a) {
      a.addEventListener("click", function (e) {
        if (pageKey(a.getAttribute("href")) !== pageKey(location.pathname)) return;
        e.preventDefault();
        window.scrollTo({ top: 0, behavior: "smooth" });
        window.dispatchEvent(new CustomEvent("td:tabagain"));
      });
    });
  }

  // Page name from a path or href, so old and clean URLs compare equal:
  // "/calendar", "calendar.html", "/calendar.html?x=1" → "calendar"; "/" or "" → "index".
  function pageKey(p) {
    p = String(p || "").split(/[?#]/)[0].split("/").pop().replace(/\.html$/, "");
    return p || "index";
  }

  // Loading placeholders: elements marked data-sk shimmer until the page first writes into them,
  // so no page ever flashes "Loading…" or "—". Safety net: cleared after 15s whatever happens.
  function skWatch() {
    if (!document.querySelector("[data-sk]") || !window.MutationObserver) return;
    var mo = new MutationObserver(function (recs) {
      recs.forEach(function (r) {
        var t = r.target.nodeType === 3 ? r.target.parentNode : r.target;
        var h = t && t.closest && t.closest("[data-sk]");
        if (h) h.removeAttribute("data-sk");
      });
      if (!document.querySelector("[data-sk]")) mo.disconnect();
    });
    mo.observe(document.body, { childList: true, subtree: true, characterData: true });
    setTimeout(function () { mo.disconnect(); document.querySelectorAll("[data-sk]").forEach(function (e) { e.removeAttribute("data-sk"); }); }, 15000);
  }

  // ---- per-user browser storage ----
  // Several tutors can use the same browser (and a tester signs up next to their own account), so any
  // saved preference or state that belongs to a tutor is keyed by their auth user id: "td:<uid>:<key>".
  // Device-wide on purpose: td_client (Client view hides money on THIS screen). sessionStorage td_stab_<studentId>
  // is already unique per student and per tab.
  var UID = null;
  function skey(k) { return UID ? "td:" + UID + ":" + k : null; }
  var store = {
    get: function (k) { var s = skey(k); if (!s) return null; try { return localStorage.getItem(s); } catch (e) { return null; } },
    set: function (k, v) { var s = skey(k); if (!s) return; try { localStorage.setItem(s, String(v)); } catch (e) {} },
    remove: function (k) { var s = skey(k); if (!s) return; try { localStorage.removeItem(s); } catch (e) {} },
    // remove this tutor's keys that start with prefix ("" = all of this tutor's keys)
    clear: function (prefix) {
      var base = skey(prefix || ""); if (!base) return;
      try { for (var i = localStorage.length - 1; i >= 0; i--) { var k = localStorage.key(i); if (k && k.indexOf(base) === 0) localStorage.removeItem(k); } } catch (e) {}
    }
  };
  // Old builds kept these unscoped, so a second account in the same browser inherited the first one's
  // state (e.g. "Not logged" hidden, Google Calendar "connected"). Nobody can tell whose they were — drop them.
  (function dropLegacy() {
    try {
      var old = ["td_onboarded", "tl_cal_hidden", "tl_cal_mode", "tl_dash_mode", "tl_fin_sub", "tl_ledger_mode", "tl_period",
                 "tl_gcal_connected", "tl_gcal_list", "tl_gcal_chosen", "tl_gcal_calendar", "tl_gcal_cals"];
      old.forEach(function (k) { localStorage.removeItem(k); });
      for (var i = localStorage.length - 1; i >= 0; i--) { var k = localStorage.key(i); if (k && k.indexOf("td_tip_") === 0) localStorage.removeItem(k); }
    } catch (e) {}
  })();

  // ---- one-time tips and "setup done", remembered on the ACCOUNT ----
  // Browser storage is per website and per device, so every Vercel preview link, the live site, a phone and a
  // laptop each started fresh and the tips came back. The account's user metadata (Supabase Auth, no table or
  // migration) keeps { td_onboarded, td_tips:{ "cal-log":1, … } }; the browser copy is just a fast cache.
  var acctTips = {};
  function seedFromAccount(user) {
    var md = (user && user.user_metadata) || {};
    acctTips = Object.assign({}, md.td_tips || {});
    Object.keys(acctTips).forEach(function (k) { store.set("td_tip_" + k, "1"); });
    if (md.td_onboarded) store.set("td_onboarded", "1");
    // The session can hold an older copy (e.g. a tip dismissed on the phone a minute ago): refresh once quietly.
    try { window.sb.auth.getUser().then(function (r) {
      var m2 = (r && r.data && r.data.user && r.data.user.user_metadata) || {};
      Object.keys(m2.td_tips || {}).forEach(function (k) {
        acctTips[k] = 1; store.set("td_tip_" + k, "1");
        var open = document.getElementById("td-tip-" + k); if (open) open.remove();
      });
      if (m2.td_onboarded) store.set("td_onboarded", "1");
    }, function () {}); } catch (e) {}
  }
  var acctQ = null;
  function saveToAccount(patch) {
    if (!window.sb || !window.sb.auth || !window.sb.auth.updateUser) return;
    acctQ = Object.assign(acctQ || {}, patch);
    clearTimeout(saveToAccount.t);
    saveToAccount.t = setTimeout(function () {
      var p = acctQ; acctQ = null;
      try { window.sb.auth.updateUser({ data: p }).then(function () {}, function () {}); } catch (e) {}
    }, 400);
  }
  function tipSeen(key) {
    store.set("td_tip_" + key, "1");
    if (acctTips[key]) return;
    acctTips[key] = 1; saveToAccount({ td_tips: Object.assign({}, acctTips) });
  }

  function cvTip() {
    if (CLIENT) return;
    coach("client-view", document.getElementById("td-cv"),
      "<b>Client view</b><br>Student or parent nearby? Tap this eye to hide all money instantly. Tap it again to bring it back.", { above: true });
  }
  // Levels: a student's Level is the year ("Sec 4"); G1/G2/G3 (or IB HL/SL) belongs to each subject and is kept
  // on the weekly slot / lesson. Older data may hold both together ("Sec 4 G3"), so pull them apart here.
  var SUBLVL_RE = /\b(G[1-3]|HL|SL)\b/i;
  function subLevel(s) { var m = SUBLVL_RE.exec(String(s || "")); return m ? m[1].toUpperCase() : ""; }
  function yearLevel(s) { return String(s || "").replace(new RegExp(SUBLVL_RE.source, "gi"), "").replace(/\s{2,}/g, " ").trim(); }
  // First word of a full name ("Raphael Long" → "Raphael").
  function firstName(n) { return String(n || "").trim().split(/\s+/)[0] || ""; }
  var helloFirst = "", helloFull = "", setHello = function () {}, setBrand = function () {};
  async function requireAuth(active, init) {
    var hr = new Date().getHours();
    var meta = { dashboard: [hr < 12 ? "Good morning" : hr < 18 ? "Good afternoon" : "Good evening",
                             new Date().toLocaleDateString("en-SG", { weekday: "long", day: "numeric", month: "long" })],
                 insights: ["Insights", "Income and collections"],
                 planner: ["Weekly planner", "Mon–Sun schedule"],
                 calendar: ["Calendar", "Lessons across the week"],
                 ledger: ["Ledger", "Lessons, payments & projections"],
                 settings: ["Settings", "Business, payments & your account"],
                 exams: ["Exams", "Upcoming assessments"],
                 invoices: ["Invoices", "Saved invoices"],
                 materials: ["Teaching materials", "Your resource library"],
                 student: ["Student", "Profile"],
                 students: ["Students", "Your roster"] }[active] || ["", ""];

    if (!window.TL_CONFIGURED) {
      // Render the shell so the setup banner is visible, skip the auth call.
      mountShell(active, "", meta[0], meta[1]);
      return;
    }
    var res = await window.sb.auth.getSession();
    var session = res.data && res.data.session;
    if (!session) { location.replace("login"); return; }
    UID = session.user.id;
    seedFromAccount(session.user);   // tips already seen / setup done on another device or link
    isOwner = session.user.id === OWNER_ID;
    window.TL_IS_OWNER = isOwner; window.TL_OWNER_ID = OWNER_ID;
    // If two-factor is enabled but not yet satisfied this session (e.g. after a
    // Google sign-in), send the user to complete the challenge first.
    try {
      var aal = await window.sb.auth.mfa.getAuthenticatorAssuranceLevel();
      if (aal.data && aal.data.currentLevel === "aal1" && aal.data.nextLevel === "aal2") {
        location.replace("login?mfa=1"); return;
      }
    } catch (e) { /* MFA unavailable — proceed as normal */ }
    // Brand the top bar with this tutor's business name. Draw the page straight away with the name we saw
    // last time on this browser (no blank screen while the profile loads); fix it up if it has changed.
    // First visit on a browser: wait for the profile as before.
    // Home greets the tutor by their own first name (profiles.full_name, from the Welcome screen or Google);
    // without one it falls back to the business name, as before.
    var profileP = window.sb.from("profiles").select("business_name,full_name").eq("id", session.user.id).single()
      .then(function (pr) {
        if (pr && pr.error) return window.sb.from("profiles").select("business_name").eq("id", session.user.id).single();
        return pr;
      })
      .then(function (pr) {
        var d = (pr && pr.data) || {}, bn = (d.business_name || "").trim();
        return { brand: bn || DEFAULT_BRAND, first: firstName(d.full_name), full: String(d.full_name || "").trim() };
      }, function () { return { brand: DEFAULT_BRAND, first: "", full: "" }; });
    var cachedBrand = store.get("td_brand"), cachedFirst = store.get("td_first"), cachedFull = store.get("td_full");
    var greet = meta[0];
    function heroTitle(name, first) {
      var who = first || (name && name !== DEFAULT_BRAND ? name : "");
      return (active === "dashboard" && who)
        ? '<span class="hi-eyebrow">' + greet + '</span><span class="hi-name">' + esc(who) + '</span>' : greet;
    }
    setHello = function (first, full) {
      helloFirst = first || ""; store.set("td_first", helloFirst);
      if (full !== undefined) { helloFull = full || ""; store.set("td_full", helloFull); var a = document.getElementById("tl-acct"); if (a) a.textContent = acctInitials(); }
      var h1 = document.querySelector(".topbar h1"); if (h1 && active === "dashboard") h1.innerHTML = heroTitle(brandName, helloFirst);
    };
    setBrand = function (fresh) {
      fresh = fresh || DEFAULT_BRAND; store.set("td_brand", fresh);
      if (fresh === brandName) return;
      brandName = fresh;
      var who = document.querySelector(".tn-who b"); if (who) who.textContent = fresh;
      var av = document.getElementById("tl-acct"); if (av) { av.title = fresh; av.textContent = acctInitials(); }
      var ms = document.querySelector(".ms-brand b"); if (ms) ms.textContent = fresh;
      var h1 = document.querySelector(".topbar h1"); if (h1 && active === "dashboard") h1.innerHTML = heroTitle(fresh, helloFirst);
    };
    if (cachedBrand === null) { var p0 = await profileP; brandName = p0.brand; helloFirst = p0.first; helloFull = p0.full; store.set("td_brand", brandName); store.set("td_first", helloFirst); store.set("td_full", helloFull); }
    else {
      brandName = cachedBrand || DEFAULT_BRAND; helloFirst = cachedFirst || ""; helloFull = cachedFull || "";
      profileP.then(function (fresh) {
        var f0 = helloFirst, n0 = helloFull; helloFirst = fresh.first; store.set("td_first", fresh.first);
        if (fresh.brand !== brandName) { helloFull = fresh.full; store.set("td_full", fresh.full); setBrand(fresh.brand); }
        else if (fresh.first !== f0 || fresh.full !== n0) setHello(fresh.first, fresh.full);
      });
    }
    // Apple-style hero: small grey greeting over the tutor's first name in large, heavy type.
    meta[0] = heroTitle(brandName, helloFirst);
    mountShell(active, session.user.email, meta[0], meta[1]);
    skWatch();
    if (typeof init === "function") init(session.user);
  }

  // ---- forms (every .modal-backdrop except small confirm dialogs) ----
  // Save/Cancel pinned to the bottom (CSS), a bottom sheet you can swipe down on phones, and a tap
  // outside or a swipe never silently throws away what you've typed. (The ✕ was retired in v202.)
  function formFields(m) { return Array.prototype.slice.call(m.querySelectorAll("input,select,textarea")); }
  function formSnap(m) { return formFields(m).map(function (f) { return f.type === "checkbox" || f.type === "radio" ? f.checked : f.value; }).join("\u0001"); }
  // "More details" folds: open when something inside is already filled in (editing), closed otherwise.
  function openFilledMore(m) {
    m.querySelectorAll("details.more-fields").forEach(function (d) {
      d.open = Array.prototype.some.call(d.querySelectorAll("input,select,textarea"), function (f) {
        if (f.type === "checkbox" || f.type === "radio") return f.checked !== f.defaultChecked;
        if (f.tagName === "SELECT" || f.disabled || f.hasAttribute("data-autofill")) return false;   // auto-filled (e.g. level) doesn't count
        return f.value.trim() !== "" && f.value !== f.defaultValue;
      });
    });
  }
  function formClose(bd) {   // use the form's own Cancel/Close button so each page's close logic runs
    var btn = Array.prototype.slice.call(bd.querySelectorAll(".modal-actions .btn")).filter(function (b) { return /^(cancel|close)$/i.test(b.textContent.trim()); })[0];
    if (btn) btn.click(); else bd.classList.remove("on");
  }
  // ---- In-app dialogs: ONE component for every confirm / alert / prompt (no browser pop-ups) ----
  // TL.confirm({ title, message, confirmText, cancelText, danger }) → Promise<boolean>
  // TL.alert(message | { title, message, confirmText })            → Promise<void>
  // TL.prompt({ title, message, placeholder, confirmText, danger, match }) → Promise<string|null>
  //   (match: the confirm button stays disabled until the typed text equals it, e.g. "DELETE")
  // Esc or a tap on the dimmed backdrop = Cancel. Enter in a text box = confirm; otherwise Enter presses the
  // focused button. Focus starts on Cancel for destructive (danger) dialogs, on the main button otherwise,
  // and stays inside the dialog (Tab loops). Messages are plain text; line breaks are kept.
  var dlgQueue = Promise.resolve();
  function dialog(o) {
    var run = function () { return new Promise(function (resolve) {
      var prev = document.activeElement, isPrompt = !!o.prompt, hasCancel = o.cancelText !== false;
      var wrap = document.createElement("div");
      wrap.className = "td-dlg";
      // o.body: an element with form fields shown under the message (Welcome, payment details).
      // o.canConfirm(): live check that enables the confirm button. o.onClose(ok): runs synchronously
      // inside the tap, before the promise resolves (so it can open WhatsApp without a pop-up blocker).
      // o.cancelLink: show Cancel as a small text link (e.g. "Skip for now"). o.keepOnBackdrop: a tap
      // outside doesn't close it (forms, so typed details aren't lost).
      wrap.innerHTML = '<div class="td-dlg-box' + (o.danger ? ' danger' : '') + (o.body ? ' form' : '') + '" role="' + (o.body ? 'dialog' : 'alertdialog') + '" aria-modal="true" aria-labelledby="td-dlg-t" aria-describedby="td-dlg-m">' +
        '<h2 class="td-dlg-t" id="td-dlg-t"></h2><p class="td-dlg-m" id="td-dlg-m"></p>' +
        (isPrompt ? '<input class="td-dlg-in" type="text" autocomplete="off" autocapitalize="off" spellcheck="false">' : '') +
        '<div class="td-dlg-acts' + (o.cancelLink ? ' link' : '') + '">' + (hasCancel ? '<button type="button" class="btn' + (o.cancelLink ? ' td-dlg-link' : '') + '" data-no></button>' : '') +
        '<button type="button" class="btn ' + (o.danger ? 'btn-danger' : 'btn-primary') + '" data-yes></button></div></div>';
      wrap.querySelector(".td-dlg-t").textContent = o.title || "";
      if (!o.title) wrap.querySelector(".td-dlg-t").remove();
      wrap.querySelector(".td-dlg-m").textContent = o.message || "";
      if (!o.message) wrap.querySelector(".td-dlg-m").remove();
      if (o.body) wrap.querySelector(".td-dlg-acts").parentNode.insertBefore(o.body, wrap.querySelector(".td-dlg-acts"));
      var yesB = wrap.querySelector("[data-yes]"), noB = wrap.querySelector("[data-no]"), inp = wrap.querySelector(".td-dlg-in");
      yesB.textContent = o.confirmText || "OK";
      if (noB) noB.textContent = o.cancelText || "Cancel";
      if (inp) { inp.placeholder = o.placeholder || ""; if (o.match) { yesB.disabled = true; inp.addEventListener("input", function () { yesB.disabled = inp.value.trim() !== o.match; }); } }
      if (o.canConfirm) {
        var check = function () { yesB.disabled = !o.canConfirm(); };
        wrap.addEventListener("input", check); wrap.addEventListener("change", check); check();
      }
      document.body.appendChild(wrap);
      document.body.classList.add("td-dlg-open");
      function done(ok) {
        if (o.onClose) { try { o.onClose(ok); } catch (e) { console.error(e); } }
        document.removeEventListener("keydown", onKey, true);
        wrap.remove();
        if (!document.querySelector(".td-dlg")) document.body.classList.remove("td-dlg-open");
        try { if (prev && prev.focus) prev.focus({ preventScroll: true }); } catch (e) {}
        resolve(isPrompt ? (ok ? inp.value.trim() : null) : ok);
      }
      function onKey(e) {
        if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); done(false); }
        else if (e.key === "Enter" && (document.activeElement === inp || !document.activeElement || document.activeElement === document.body ||
                 (o.body && document.activeElement.tagName === "INPUT" && o.body.contains(document.activeElement)))) {
          e.preventDefault(); if (!yesB.disabled) done(true);
        } else if (e.key === "Tab") {                      // keep focus inside the dialog
          var f = Array.prototype.filter.call(wrap.querySelectorAll("input,button,select,textarea,summary,a[href]"), function (x) { return !x.disabled && x.offsetParent !== null; });
          if (!f.length) return;
          var i = f.indexOf(document.activeElement);
          if (e.shiftKey && i <= 0) { e.preventDefault(); f[f.length - 1].focus(); }
          else if (!e.shiftKey && i === f.length - 1) { e.preventDefault(); f[0].focus(); }
        }
      }
      document.addEventListener("keydown", onKey, true);
      yesB.addEventListener("click", function () { done(true); });
      if (noB) noB.addEventListener("click", function () { done(false); });
      wrap.addEventListener("click", function (e) { if (e.target === wrap && !o.keepOnBackdrop) done(!hasCancel); });   // backdrop = Cancel (or OK for a plain notice)
      setTimeout(function () {
        var first = o.body && (o.focus ? o.body.querySelector(o.focus) : o.body.querySelector("input:not([type=checkbox]),select,textarea"));
        (first || inp || (o.danger && noB) || yesB).focus();
      }, 30);
    }); };
    var p = dlgQueue.then(run, run);                      // one at a time
    dlgQueue = p.catch(function () {});
    return p;
  }
  function tlConfirm(o) { return dialog(Object.assign({ confirmText: "OK" }, o)).then(function (v) { return !!v; }); }
  function tlAlert(o) { if (typeof o === "string") o = { message: o }; return dialog(Object.assign({ confirmText: "OK", cancelText: false }, o)).then(function () {}); }
  function tlPrompt(o) { return dialog(Object.assign({ confirmText: "OK" }, o, { prompt: true })); }

  function askDiscard(yes) {
    tlConfirm({ title: "Discard changes?", message: "What you\u2019ve typed in this form will be lost.",
      confirmText: "Discard", cancelText: "Keep editing", danger: true }).then(function (ok) { if (ok) yes(); });
  }
  function enhanceForms() {
    document.querySelectorAll(".modal-backdrop").forEach(function (bd) {
      // A JS property, not an attribute: mountShell rebuilds the page from HTML text, which copies
      // attributes but drops every listener, so a copied form must be set up again.
      if (bd._tdForm || /confirm/.test(bd.id)) return;
      var m = bd.querySelector(".modal"); if (!m) return;
      bd._tdForm = true; bd.classList.add("td-form");
      m.querySelectorAll(":scope > .modal-x").forEach(function (old) { old.remove(); });   // retired ✕ (v202)
      // Phones: drag the sheet down to close it (like iOS sheets). Starts only when the form is
      // scrolled to the top and the drag is clearly downward; a short drag springs back.
      var y0 = null, x0 = 0, dy = 0, dragging = false;
      m.addEventListener("touchstart", function (e) {
        if (!window.matchMedia("(max-width:820px)").matches || e.touches.length > 1) { y0 = null; return; }
        if (e.target.closest("input,select,textarea")) { y0 = null; return; }
        y0 = e.touches[0].clientY; x0 = e.touches[0].clientX; dy = 0; dragging = false;
      }, { passive: true });
      m.addEventListener("touchmove", function (e) {
        if (y0 === null) return;
        var t = e.touches[0], my = t.clientY - y0, mx = t.clientX - x0;
        if (!dragging) {
          if (my > 8 && my > Math.abs(mx) && m.scrollTop <= 0) { dragging = true; m.style.transition = "none"; }
          else if (Math.abs(my) > 8 || Math.abs(mx) > 8) { y0 = null; return; }
          else return;
        }
        e.preventDefault();
        dy = Math.max(0, my);
        m.style.transform = "translateY(" + dy + "px)";
        bd.style.background = "rgba(19,24,40," + (0.5 * Math.max(0.2, 1 - dy / 400)) + ")";
      }, { passive: false });
      function endDrag() {
        if (y0 === null) return; var was = dragging; y0 = null; dragging = false;
        if (!was) return;
        var close = dy > Math.min(140, m.offsetHeight * 0.25);
        m.style.transition = "transform .2s ease"; bd.style.background = "";
        if (!close) { m.style.transform = ""; return; }
        var dirty = bd._snap != null && formSnap(m) !== bd._snap;
        if (dirty) { m.style.transform = ""; askDiscard(function () { formClose(bd); }); return; }
        m.style.transform = "translateY(100%)";
        setTimeout(function () { formClose(bd); m.style.transform = ""; m.style.transition = ""; }, 190);
      }
      m.addEventListener("touchend", endDrag, { passive: true });
      m.addEventListener("touchcancel", endDrag, { passive: true });
      // Save pressed with something missing: the page shows a red .msg — make it impossible to miss.
      // Outline the first empty required field ([data-req]) in red, scroll to it and focus it;
      // otherwise (e.g. end before start) scroll the message itself into view.
      m.querySelectorAll(".msg").forEach(function (msgEl) {
        new MutationObserver(function () {
          if (!msgEl.classList.contains("err") || !msgEl.textContent.trim()) return;
          var miss = Array.prototype.filter.call(m.querySelectorAll("[data-req]"), function (f) { return !String(f.value || "").trim(); })[0];
          if (miss) {
            miss.classList.add("invalid");
            var d = miss.closest("details"); if (d) d.open = true;
            miss.scrollIntoView({ block: "center", behavior: "smooth" });
            try { miss.focus({ preventScroll: true }); } catch (e) {}
          } else msgEl.scrollIntoView({ block: "nearest", behavior: "smooth" });
        }).observe(msgEl, { attributes: true, attributeFilter: ["class"], childList: true });
      });
      m.addEventListener("input", function (e) { if (e.target.classList) e.target.classList.remove("invalid"); });
      m.addEventListener("change", function (e) { if (e.target.classList) e.target.classList.remove("invalid"); });
      // remember the form as it opened, to know later whether anything was typed
      new MutationObserver(function () {
        if (bd.classList.contains("on")) { if (!bd._open) { bd._open = true; setTimeout(function () { m.querySelectorAll(".invalid").forEach(function (x) { x.classList.remove("invalid"); }); openFilledMore(m); bd._snap = formSnap(m); m.scrollTop = 0; }, 0); } }
        else bd._open = false;
      }).observe(bd, { attributes: true, attributeFilter: ["class"] });
      // a tap outside: close if nothing changed, otherwise ask first (runs before the page's own handler)
      bd.addEventListener("click", function (e) {
        if (e.target !== bd) return;
        if (bd._snap != null && formSnap(m) !== bd._snap) {
          e.stopImmediatePropagation(); e.preventDefault();
          askDiscard(function () { formClose(bd); });
        }
      }, true);
    });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", enhanceForms); else enhanceForms();

  // ---- offline awareness ----
  // Tutors use this between lessons, in lifts and basements. Without this, a save on a dead connection
  // fails silently. A slim banner appears while offline and primary buttons are held until it's back.
  function offlineBanner(on) {
    var el = document.getElementById("td-offline");
    if (on && !el) {
      el = document.createElement("div"); el.id = "td-offline"; el.setAttribute("role", "status");
      el.textContent = "You're offline — changes can't be saved until you reconnect.";
      document.body.appendChild(el);
    }
    if (el) el.style.display = on ? "" : "none";
    document.documentElement.classList.toggle("is-offline", !!on);
  }
  window.addEventListener("offline", function () { offlineBanner(true); });
  window.addEventListener("online",  function () { offlineBanner(false); });
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", function () { offlineBanner(!navigator.onLine); });
  else offlineBanner(!navigator.onLine);

  // ---- installable app (PWA) ----
  // manifest.json + a minimal service worker make "Add to Home Screen" offer a real app icon and a
  // standalone window. The worker only serves cached static assets when the network fails — it never
  // caches Supabase data, so nothing stale is ever shown as live.
  if ("serviceWorker" in navigator && location.protocol === "https:") {
    window.addEventListener("load", function () { navigator.serviceWorker.register("/sw.js").catch(function () {}); });
  }

  // ---- first-time tips ("coach marks") ----
  // TL.coach(key, anchorEl, html): shows a small tip under anchorEl ONCE per browser; "Got it" dismisses it
  // for good (localStorage "td_tip_<key>"). Use for new or non-obvious features instead of permanent banners.
  // opts.above: open above the anchor (for buttons pinned to the bottom of the screen).
  // ---- first-run guide (pages opened with ?guide=1 from Home's "Set up in 3 steps") ----
  // One step at a time: the page opens the right form, then a small card says what's next.
  // Until setup is finished (td_onboarded), the other one-time tips stay quiet.
  var GUIDE = /[?&]guide=1(&|$)/.test(location.search);
  function onboarded() { return store.get("td_onboarded") === "1"; }
  function setOnboarded() { if (onboarded()) return; store.set("td_onboarded", "1"); saveToAccount({ td_onboarded: true }); }
  // o: { step:1-3, done:"✓ line", title, text, href, cta }
  function guideCard(o) {
    var c = document.getElementById("content"); if (!c) return;
    var g = document.getElementById("td-guide");
    if (!g) { g = document.createElement("div"); g.id = "td-guide"; g.className = "td-guide"; c.insertBefore(g, c.firstChild); }
    g.innerHTML =
      (o.done ? '<div class="tg-done">' + o.done + '</div>' : '') +
      '<div class="tg-row"><div class="tg-body">' +
      (o.step ? '<span class="tg-step">Step ' + o.step + ' of 3</span>' : '') +
      '<b class="tg-t">' + o.title + '</b>' + (o.text ? '<span class="tg-d">' + o.text + '</span>' : '') +
      '</div>' + (o.href ? '<a class="btn btn-gold tg-btn" href="' + o.href + '">' + o.cta + '</a>' : '') + '</div>' +
      (o.final ? '' : '<a class="tg-skip" href="home" data-skip>Skip setup</a>');
    var sk = g.querySelector("[data-skip]"); if (sk) sk.addEventListener("click", setOnboarded);
    g.classList.remove("tg-pop"); void g.offsetWidth; g.classList.add("tg-pop");
  }

  // A one-line hint inside a form (the guide card sits behind the form sheet on phones).
  function guideFormHint(afterEl, text) {
    if (!afterEl || afterEl.parentNode.querySelector(".tg-inform")) return;
    var p = document.createElement("p"); p.className = "tg-inform"; p.textContent = text;
    afterEl.insertAdjacentElement("afterend", p);
  }

  function coach(key, anchor, html, opts) {
    opts = opts || {};
    if (GUIDE || !onboarded()) return;   // new tutors: finish the 3-step setup first, then tips
    var k = "td_tip_" + key;
    if (store.get(k)) return;
    if (!anchor || !anchor.getBoundingClientRect || document.getElementById("td-tip-" + key)) return;
    // One tip on screen at a time: wait for the open one to be dismissed, then show this one.
    var openTip = document.querySelector(".td-tip");
    if (openTip) {
      openTip.querySelector(".td-tip-ok").addEventListener("click", function () {
        setTimeout(function () { if (document.body.contains(anchor)) coach(key, anchor, html, opts); }, 250);
      });
      return;
    }
    var tip = document.createElement("div");
    tip.className = "td-tip"; tip.id = "td-tip-" + key; tip.setAttribute("role", "status");
    tip.innerHTML = '<span class="td-tip-arrow" aria-hidden="true"></span><div class="td-tip-body">' + html +
      '</div><button type="button" class="td-tip-ok">Got it</button>';
    document.body.appendChild(tip);
    function place() {
      var r = anchor.getBoundingClientRect();
      if (!r.width) { tip.style.display = "none"; return; }
      tip.style.display = "";
      var w = Math.min(300, window.innerWidth - 24);
      tip.style.width = w + "px";
      var left = Math.max(12, Math.min(r.left + r.width / 2 - w / 2, window.innerWidth - w - 12));
      var fixed = getComputedStyle(anchor).position === "fixed";
      tip.style.position = fixed ? "fixed" : "absolute";
      var sx = fixed ? 0 : window.scrollX, sy = fixed ? 0 : window.scrollY;
      tip.style.left = left + sx + "px";
      tip.classList.toggle("above", !!opts.above);
      if (opts.above) { tip.style.top = ""; tip.style.bottom = (fixed ? window.innerHeight - r.top : document.documentElement.clientHeight - r.top - sy) + 10 + "px"; }
      else { tip.style.bottom = ""; tip.style.top = r.bottom + sy + 10 + "px"; }
      tip.querySelector(".td-tip-arrow").style.left = (r.left + r.width / 2 - left - 7) + "px";
    }
    place(); window.addEventListener("resize", place);
    function dismiss() {
      tipSeen(key);
      window.removeEventListener("resize", place); document.removeEventListener("pointerdown", outside, true); tip.remove();
    }
    // Got it, or a tap anywhere else (incl. using the thing it points at): either way it's been seen.
    // (Goes through the Got it button so anything waiting on it, like the Calendar's next tip, still runs.)
    function outside(e) { if (!tip.contains(e.target)) setTimeout(function () { if (tip.isConnected) tip.querySelector(".td-tip-ok").click(); }, 0); }
    tip.querySelector(".td-tip-ok").addEventListener("click", dismiss);
    setTimeout(function () { document.addEventListener("pointerdown", outside, true); }, 400);
  }

  async function signOut() {
    // Google Calendar access belongs to this tutor's session only: forget the link on this browser,
    // so the next person to sign in here can't sync into (or clean up) this tutor's Google Calendar.
    store.clear("tl_gcal_");
    try { if (window.TD_GCAL_REVOKE) window.TD_GCAL_REVOKE(); } catch (e) {}
    try { await window.sb.auth.signOut(); } catch (e) {}
    location.replace("login");
  }

  // ---- helpers ----
  // ---- Client view: one switch (per device) that hides money everywhere, for when a student or
  // parent can see your screen. Every amount goes through sgd(), so masking it here covers the app.
  var CLIENT = false;
  try { CLIENT = localStorage.getItem("td_client") === "1"; } catch (e) {}
  function isClient() { return CLIENT; }
  var CV_ACTIVE = "";
  // Masking works on what's on screen, both ways and instantly: while Client view is on, every dollar
  // figure that appears (now or rendered later) is swapped for $••• before the browser paints, and the
  // real text is remembered so turning it off just puts it back. No reloads.
  var MONEY_RE = /-?\$\s?\d[\d,]*(\.\d+)?/g, ORIG = new Map(), MO = null;
  function maskText(t) {
    var v = t.nodeValue; MONEY_RE.lastIndex = 0;
    if (!v || !MONEY_RE.test(v)) return;
    MONEY_RE.lastIndex = 0; ORIG.set(t, v); t.nodeValue = v.replace(MONEY_RE, "$•••");
  }
  function maskTree(root) {
    if (root.nodeType === 3) { maskText(root); return; }
    if (root.nodeType !== 1 || /^(SCRIPT|STYLE|TEXTAREA)$/.test(root.nodeName)) return;
    var w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null), n, list = [];
    while ((n = w.nextNode())) list.push(n);
    list.forEach(maskText);
  }
  function startMask() {
    if (MO || !document.body) return;
    maskTree(document.body);
    MO = new MutationObserver(function (muts) {
      muts.forEach(function (m) {
        if (m.type === "characterData") maskText(m.target);
        else m.addedNodes.forEach(maskTree);
      });
    });
    MO.observe(document.body, { childList: true, subtree: true, characterData: true });
  }
  function stopMask() {
    if (MO) { MO.disconnect(); MO = null; }
    ORIG.forEach(function (v, t) { if (t.isConnected && t.nodeValue.indexOf("$•••") >= 0) t.nodeValue = v; });
    ORIG.clear();
  }
  function setClient(on) {
    try { if (on) localStorage.setItem("td_client", "1"); else localStorage.removeItem("td_client"); } catch (e) {}
    CLIENT = !!on;
    if (CLIENT) startMask(); else stopMask();
    applyClient();
    window.dispatchEvent(new CustomEvent("td:clientview", { detail: { on: CLIENT } }));
  }
  if (CLIENT) startMask();   // page opened with Client view already on: mask from the first paint
  function applyClient() {
    document.body.classList.toggle("client-view", CLIENT);
    var b = document.getElementById("td-cv");
    if (b) {
      b.innerHTML = CLIENT ? EYE_OFF : EYE;
      b.setAttribute("aria-pressed", CLIENT ? "true" : "false");
      b.setAttribute("aria-label", CLIENT ? "Show money" : "Hide money (client view)");
      b.title = CLIENT ? "Client view is on: tap to show money" : "Client view: hide all money";
    }
    // Money pages have nothing to show in client view: say so instead of a page of $•••.
    var oldBlk = document.getElementById("cv-block");
    if (!CLIENT) { document.body.classList.remove("cv-money"); if (oldBlk) oldBlk.remove(); }
    if (CLIENT && ["ledger", "invoices", "insights"].indexOf(CV_ACTIVE) >= 0) {
      document.body.classList.add("cv-money");
      var c = document.getElementById("content");
      if (c && !document.getElementById("cv-block")) {
        var blk = document.createElement("div");
        blk.id = "cv-block"; blk.className = "card cv-block";
        blk.innerHTML = '<div class="cv-ic">' + EYE_OFF + '</div><b>Money is hidden</b><p>Client view is on. Tap the eye to show payments and invoices again.</p>';
        c.insertBefore(blk, c.firstChild);
      }
    }
  }
  var EYE = '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/></svg>';
  var EYE_OFF = '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9.9 4.2A10 10 0 0 1 12 4c6.5 0 10 8 10 8a17 17 0 0 1-2.2 3.2M6.6 6.6A17 17 0 0 0 2 12s3.5 8 10 8a10 10 0 0 0 5.4-1.6"/><path d="M2 2l20 20"/></svg>';

  function sgd(n) {   // always the real figure; Client view masks it on screen (see startMask)
    return "$" + (Number(n) || 0).toLocaleString("en-SG",
      { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }
  // "1 lesson", "2 lessons"
  function plural(n, word, many) { return n + " " + (n === 1 ? word : (many || word + "s")); }
  function hoursBetween(start, end) {              // "17:00" → "18:30" = 1.5
    function m(t){ var p=t.split(":"); return (+p[0])*60+(+p[1]); }
    return (m(end) - m(start)) / 60;
  }
  function amount(rate, start, end) { return Math.round(rate * hoursBetween(start, end) * 100) / 100; }
  // One standard marks token used everywhere: "88/100 · 88%" when scored, "—/100" when only the
  // total is known (not sat yet), "" when neither. Numbers only, safe to inject.
  function examMarks(score, max) {
    var hasMax = max != null && max !== "" && Number(max) > 0;
    if (score != null && score !== "" && hasMax)
      return '<b>' + score + '/' + max + '</b> <small class="muted">· ' + Math.round(score / max * 100) + '%</small>';
    if (hasMax) return '<span class="muted">—/' + max + '</span>';
    return "";
  }

  // Flip any "scheduled" lesson whose time has passed to "done" (unpaid),
  // so completed lessons show up as owed without needing a background server.
  async function promotePastLessons() {
    if (!window.sb) return;
    var n = new Date(), p = function (x) { return (x < 10 ? "0" : "") + x; };
    var today = n.getFullYear() + "-" + p(n.getMonth() + 1) + "-" + p(n.getDate());
    var nowT = p(n.getHours()) + ":" + p(n.getMinutes()) + ":" + p(n.getSeconds());
    try {
      // past dates: always promote
      await window.sb.from("lessons").update({ status: "done" })
        .eq("status", "scheduled").lt("lesson_date", today);
      // today: promote only those whose end time has already passed
      await window.sb.from("lessons").update({ status: "done" })
        .eq("status", "scheduled").eq("lesson_date", today).lte("end_time", nowT);
    } catch (e) { /* non-fatal */ }
  }

  // ---- scheduled discontinuation (students.end_date) ----
  // One shared definition so every surface agrees: lessons run through end_date
  // INCLUSIVE; after that the student is "ended" (treated as discontinued).
  function todayISO() {
    var n = new Date(), p = function (x) { return (x < 10 ? "0" : "") + x; };
    return n.getFullYear() + "-" + p(n.getMonth() + 1) + "-" + p(n.getDate());
  }
  // Has the student's end date already passed? (so they belong in Discontinued)
  function isEnded(endDate) { return !!endDate && endDate < todayISO(); }
  // Money owed for a lesson: it happened (or was cancelled with compensation), isn't paid, and costs more than $0.
  // A $0 lesson (e.g. the first lessons from an agency go to the agent as commission, a free trial) is settled
  // by itself: never "unpaid", never in Who owes you, invoices or reminders.
  function isOwed(l) { return !!l && !l.paid && Number(l.amount) > 0 && (l.status === "done" || l.status === "cancelled"); }
  // A lesson's paid tick changed outside the Ledger's pay window (e.g. on the student page): bring any saved
  // invoice covering it in line. All its lessons paid → invoice Paid (with that date); any unpaid → back to
  // unpaid. Never creates an invoice; invoices replaced by a newer one are left as they were (same as the Ledger).
  async function syncInvoicesForLessons(ids, paidDate) {
    ids = (ids || []).map(String);
    var q = await window.sb.from("invoices").select("id,data,status");
    if (q.error) return;
    var hits = (q.data || []).filter(function (v) {
      var lids = (v.data && v.data.lesson_ids) || [];
      return !(v.data && v.data.replaced_by) && lids.some(function (x) { return ids.indexOf(String(x)) > -1; });
    });
    for (var i = 0; i < hits.length; i++) {
      var v = hits[i], chk = await window.sb.from("lessons").select("id,paid").in("id", v.data.lesson_ids);
      var got = chk.data || [], allPaid = got.length > 0 && got.every(function (l) { return l.paid; });
      if (allPaid && v.status !== "paid") await window.sb.from("invoices").update({ status: "paid", paid_date: paidDate || todayISO() }).eq("id", v.id);
      else if (!allPaid && v.status === "paid") await window.sb.from("invoices").update({ status: "issued", paid_date: null }).eq("id", v.id);
    }
  }
  function noCharge(l) { return !!l && l.status !== "cancelled" && l.status !== "scheduled" && !l.paid && !(Number(l.amount) > 0); }
  // Is a given lesson date beyond the student's end date? (so don't project/generate it)
  function pastEnd(endDate, dateISO) { return !!endDate && dateISO > endDate; }

  // Singapore postal-code → address via OneMap (public gov API, CORS-open, no key needed).
  // Best-effort convenience: returns { address } or { error }; callers degrade to manual entry.
  function titleCase(s) {
    return String(s || "").toLowerCase().replace(/\b([a-z])/g, function (m, c) { return c.toUpperCase(); });
  }
  async function postalLookup(code) {
    code = String(code || "").replace(/\D/g, "");
    if (code.length !== 6) return { error: "Enter a 6-digit postal code." };
    try {
      var r = await fetch("https://www.onemap.gov.sg/api/common/elastic/search?searchVal=" +
        code + "&returnGeom=N&getAddrDetails=Y&pageNum=1");
      var d = await r.json();
      var res = (d.results || [])[0];
      if (!res || !res.ADDRESS || res.ADDRESS.indexOf("NIL") > -1) return { error: "No address found for " + code + "." };
      return { address: titleCase(res.ADDRESS) };
    } catch (e) { return { error: "Couldn't reach the address lookup." }; }
  }

  // Wire the in-field search icon: find the 6-digit postal code typed into the location bar
  // and expand it in place to the full address (keeping any name you typed before it).
  function wirePostal(btnId, locId, msgId) {
    var btn = document.getElementById(btnId); if (!btn) return;
    async function run() {
      var loc = document.getElementById(locId), msg = document.getElementById(msgId);
      function say(t, cls) { if (msg) { msg.textContent = t || ""; msg.className = "postal-msg" + (cls ? " " + cls : ""); } }
      var val = loc.value || "", m = val.match(/(\d{6})/);
      if (!m) { say("Type a 6-digit postal code in the box, then tap search.", "err"); return; }
      say("Looking up…");
      var r = await postalLookup(m[1]);
      if (r.error) { say(r.error, "err"); return; }
      loc.value = val.replace(m[1], r.address).replace(/\s+/g, " ").trim();  // postal → address, in place
      say("Expanded ✓ — add the unit number", "ok"); loc.focus();
    }
    btn.addEventListener("click", run);
  }

  return { requireAuth: requireAuth, signOut: signOut, mountShell: mountShell, coach: coach,
           store: store, uid: function () { return UID; }, plural: plural,
           confirm: tlConfirm, alert: tlAlert, prompt: tlPrompt,
           guide: { on: GUIDE, card: guideCard, formHint: guideFormHint, finish: setOnboarded, onboarded: onboarded },
           sgd: sgd, isClient: isClient, setClient: setClient, hoursBetween: hoursBetween, amount: amount, examMarks: examMarks,
           promotePastLessons: promotePastLessons, postalLookup: postalLookup, wirePostal: wirePostal,
           todayISO: todayISO, isEnded: isEnded, pastEnd: pastEnd, isOwed: isOwed, noCharge: noCharge, syncInvoicesForLessons: syncInvoicesForLessons,
           dialog: dialog, firstName: firstName, subLevel: subLevel, yearLevel: yearLevel, cvTip: function () { cvTip(); },
           setHello: function (f, full) { setHello(f, full); }, setBrand: function (b) { setBrand(b); },
           // Name parents see (invoices, PayNow, WhatsApp): tuition name, else the tutor's own name, else generic.
           payeeName: function (p, generic) { p = p || {}; return (p.business_name || "").trim() || (p.full_name || "").trim() || generic; } };
})();