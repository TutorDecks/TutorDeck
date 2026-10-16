// =====================================================================
// TL core — auth guard + app shell + shared helpers
// Every protected page calls:  TL.requireAuth("dashboard", initFn)
// =====================================================================
window.TL = (function () {
  var OWNER_ID = "ad4e2f4f-90c9-4fd9-8d51-e85b0e0bebb4";  // only this account sees Materials
  var isOwner = false;
  var NAV = [
    { id: "dashboard", label: "Dashboard", href: "app.html",    ic: "◧" },
    { id: "planner",   label: "Planner",   href: "planner.html",  ic: "▦" },
    { id: "calendar",  label: "Calendar",  href: "calendar.html", ic: "⊞" },
    { id: "ledger",    label: "Ledger",    href: "ledger.html",   ic: "₪" },
    { id: "students",  label: "Students",  href: "students.html", ic: "☺" },
    { id: "exams",     label: "Exams",     href: "exams.html",    ic: "◷" },
    { id: "invoices",  label: "Invoices",  href: "invoices.html", ic: "❑" },
    { id: "materials", label: "Materials", href: "materials.html",ic: "▤", ownerOnly: true },
    { id: "settings",  label: "Settings",  href: "settings.html", ic: "⚙" }
  ];

  var DEFAULT_BRAND = "TutorDeck";
  var brandName = DEFAULT_BRAND;   // set per-user from profiles.business_name in requireAuth

  // Two-letter badge from the brand: initials of the first two words
  // ("T-Leng Tuition" → "TL", "Raphael Tuition" → "RT"), else first two letters.
  function monogram(name) {
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
           esc(possessive(brandName)) + '</b><small>Dashboard</small></span>';
  }

  function configBanner() {
    if (window.TL_CONFIGURED) return "";
    return '<div class="note-banner">⚙︎ Not connected yet — paste your Supabase ' +
           'URL and anon key into <code>assets/js/config.js</code> to enable sign-in and data.</div>';
  }

  // Build sidebar + topbar around the page's <div id="view">
  function mountShell(active, email, title, sub) {
    var nav = NAV.filter(function (n) { return !n.ownerOnly || isOwner; }).map(function (n) {
      return '<a href="' + n.href + '" class="' + (n.id === active ? "active" : "") +
             '"><span class="ic">' + n.ic + '</span>' + n.label + "</a>";
    }).join("");

    var view = document.getElementById("view");
    var inner = view.innerHTML;
    var app = document.createElement("div");
    app.className = "app";
    var burgerSvg = '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="4" y1="7" x2="20" y2="7"/><line x1="4" y1="12" x2="20" y2="12"/><line x1="4" y1="17" x2="20" y2="17"/></svg>';
    app.innerHTML = `
      <aside class="sidebar">
        <div class="brand">${mono()}</div>
        <nav class="nav">${nav}</nav>
        <div class="side-foot">
          <div class="who">${email || ""}</div>
          <button id="tl-signout">Sign out</button>
        </div>
      </aside>
      <div class="nav-scrim" id="tl-scrim"></div>
      <div class="main">
        <div class="mnav">
          <span class="mmono">${esc(monogram(brandName))}</span>
          <span class="mbrand">${esc(brandName)}</span>
          <button class="burger" id="tl-burger" aria-label="Open menu" aria-expanded="false">${burgerSvg}</button>
        </div>
        <div class="topbar">
          <div><h1>${title}</h1>${sub ? `<div class="sub">${sub}</div>` : ""}</div>
        </div>
        ${configBanner()}
        <div class="content" id="content">${inner}</div>
      </div>`;
    document.body.innerHTML = "";
    document.body.appendChild(app);
    document.getElementById("tl-signout").addEventListener("click", signOut);
    // Mobile nav: hamburger opens a slide-in drawer; scrim / a tab / Esc closes it.
    var burger = document.getElementById("tl-burger"), scrim = document.getElementById("tl-scrim");
    function setNav(open) { app.classList.toggle("nav-open", open); if (burger) burger.setAttribute("aria-expanded", open ? "true" : "false"); }
    if (burger) burger.addEventListener("click", function () { setNav(!app.classList.contains("nav-open")); });
    if (scrim) scrim.addEventListener("click", function () { setNav(false); });
    app.querySelectorAll(".nav a").forEach(function (a) { a.addEventListener("click", function () { setNav(false); }); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape") setNav(false); });
  }

  async function requireAuth(active, init) {
    var meta = { dashboard: ["Dashboard", "Your week at a glance"],
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
    mountShell(active, session.user.email, meta[0], meta[1]);
    if (typeof init === "function") init(session.user);
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

  return { requireAuth: requireAuth, signOut: signOut, mountShell: mountShell,
           sgd: sgd, hoursBetween: hoursBetween, amount: amount, examMarks: examMarks,
           promotePastLessons: promotePastLessons, postalLookup: postalLookup, wirePostal: wirePostal,
           todayISO: todayISO, isEnded: isEnded, pastEnd: pastEnd };
})();