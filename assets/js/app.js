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
    { id: "home",     label: "Home",     ic: "home",     pages: [ { id: "dashboard", label: "Dashboard", href: "app.html" } ] },
    { id: "schedule", label: "Schedule", ic: "schedule", pages: [ { id: "calendar", label: "Calendar", href: "calendar.html" },
                                                                  { id: "planner",  label: "Weekly planner", href: "planner.html" } ] },
    { id: "students", label: "Students", ic: "students", pages: [ { id: "students", label: "Roster", href: "students.html" },
                                                                  { id: "exams",    label: "Exams",  href: "exams.html" } ],
      also: ["student"] },
    { id: "money",    label: "Money",    ic: "money",    pages: [ { id: "ledger",   label: "Ledger",   href: "ledger.html" },
                                                                  { id: "invoices", label: "Invoices", href: "invoices.html" },
                                                                  { id: "insights", label: "Insights", href: "insights.html" } ] }
  ];
  // Secondary destinations: sidebar footer on desktop, "More" sheet on phones.
  var EXTRA = [
    { id: "materials", label: "Materials", href: "materials.html", ic: "materials", ownerOnly: true },
    { id: "settings",  label: "Settings",  href: "settings.html",  ic: "settings" }
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
    var initials = monogram(brandName);

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
          <a class="tn-brand" href="app.html" aria-label="TutorDeck home">${LOGO}<b>TutorDeck</b></a>
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
  }

  async function requireAuth(active, init) {
    var hr = new Date().getHours();
    var meta = { dashboard: [hr < 12 ? "Good morning" : hr < 18 ? "Good afternoon" : "Good evening",
                             new Date().toLocaleDateString("en-SG", { weekday: "long", day: "numeric", month: "long" })],
                 insights: ["Insights", "Income and collections"],
                 planner: ["Weekly planner", "Mon–Sun schedule"],
                 calendar: ["Calendar", "Lessons across the week"],
                 ledger: ["Ledger", "Lessons, payments & projections"],
                 settings: ["Settings", "Business & PayNow details"],
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
    if (!session) { location.replace("login.html"); return; }
    isOwner = session.user.id === OWNER_ID;
    window.TL_IS_OWNER = isOwner; window.TL_OWNER_ID = OWNER_ID;
    // If two-factor is enabled but not yet satisfied this session (e.g. after a
    // Google sign-in), send the user to complete the challenge first.
    try {
      var aal = await window.sb.auth.mfa.getAuthenticatorAssuranceLevel();
      if (aal.data && aal.data.currentLevel === "aal1" && aal.data.nextLevel === "aal2") {
        location.replace("login.html?mfa=1"); return;
      }
    } catch (e) { /* MFA unavailable — proceed as normal */ }
    // Brand the sidebar with this tutor's business name; fall back to the default.
    try {
      var pr = await window.sb.from("profiles").select("business_name").eq("id", session.user.id).single();
      var bn = pr.data && pr.data.business_name && pr.data.business_name.trim();
      brandName = bn || DEFAULT_BRAND;
    } catch (e) { brandName = DEFAULT_BRAND; }
    // Home greets the tutor by their business name ("Good afternoon, Raphael Tuition")
    // Apple-style hero: small grey greeting over the business name in large, heavy type.
    if (active === "dashboard" && brandName && brandName !== DEFAULT_BRAND)
      meta[0] = '<span class="hi-eyebrow">' + meta[0] + '</span><span class="hi-name">' + esc(brandName) + '</span>';
    mountShell(active, session.user.email, meta[0], meta[1]);
    if (typeof init === "function") init(session.user);
  }

  // ---- first-time tips ("coach marks") ----
  // TL.coach(key, anchorEl, html): shows a small tip under anchorEl ONCE per browser; "Got it" dismisses it
  // for good (localStorage "td_tip_<key>"). Use for new or non-obvious features instead of permanent banners.
  function coach(key, anchor, html) {
    var k = "td_tip_" + key;
    try { if (localStorage.getItem(k)) return; } catch (e) { return; }
    if (!anchor || !anchor.getBoundingClientRect || document.getElementById("td-tip-" + key)) return;
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
      tip.style.left = left + window.scrollX + "px";
      tip.style.top = r.bottom + window.scrollY + 10 + "px";
      tip.querySelector(".td-tip-arrow").style.left = (r.left + r.width / 2 - left - 7) + "px";
    }
    place(); window.addEventListener("resize", place);
    tip.querySelector(".td-tip-ok").addEventListener("click", function () {
      try { localStorage.setItem(k, "1"); } catch (e) {}
      window.removeEventListener("resize", place); tip.remove();
    });
  }

  async function signOut() {
    try { await window.sb.auth.signOut(); } catch (e) {}
    location.replace("login.html");
  }

  // ---- helpers ----
  function sgd(n) {
    return "$" + (Number(n) || 0).toLocaleString("en-SG",
      { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }
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
           sgd: sgd, hoursBetween: hoursBetween, amount: amount, examMarks: examMarks,
           promotePastLessons: promotePastLessons, postalLookup: postalLookup, wirePostal: wirePostal,
           todayISO: todayISO, isEnded: isEnded, pastEnd: pastEnd };
})();