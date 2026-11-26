// ---------------------------------------------------------------------
// Which Supabase project does this page talk to?
//   PRODUCTION addresses (the list below)  → the REAL database (project rnjvswkejbrhbaytutai): real tutors, students and payments.
//   EVERYTHING ELSE → the DEV database (project tuzxsqkfzrjssnpcoale): dummy data only. That means every Vercel preview, the dev
//   branch, local testing, and any address nobody has listed here.
// The list is deliberately short and exact, and the default is DEV, so a mistake here can only fail on the SAFE side (a real site
// address missing from the list would show the test banner and not let anyone in; it can never send a preview to real data).
// If a new production address is added (a new domain), add it to PRODUCTION_HOSTS and to tests/config.test.js, nothing else.
// Both URLs and publishable keys are public and SAFE to commit — Row Level Security protects the data, not the secrecy of these keys.
// ---------------------------------------------------------------------
(function () {
  var PRODUCTION_HOSTS = [
    "www.tutordeck.com.sg",
    "tutordeck.com.sg",
    "tutordeck.vercel.app",
    "tutordeck-longraphaeljames-8916.vercel.app",
    "tutordeck-git-main-longraphaeljames-8916.vercel.app"
  ];
  var LIVE = {
    ENV: "live",
    SUPABASE_URL:      "https://rnjvswkejbrhbaytutai.supabase.co",
    SUPABASE_ANON_KEY: "sb_publishable_IKUtlGhnwJT0Hld5A8cglw_0iF6Y5J9",
    // Cloudflare Turnstile SITE key (public), for the sign-up bot check on the real domain. "" = no bot check.
    TURNSTILE_SITE_KEY: "0x4AAAAAAFsffjS_h2zuqSJa"
  };
  var DEV = {
    ENV: "dev",
    SUPABASE_URL:      "https://tuzxsqkfzrjssnpcoale.supabase.co",
    SUPABASE_ANON_KEY: "sb_publishable__UR4PFxyxgc6pmRP_iVxLA_f_XoVusA",
    TURNSTILE_SITE_KEY: ""      // the bot check is tied to the real domain; previews don't use it
  };
  // Google OAuth client ID for Calendar sync (public, safe to commit — like the anon key). Same for both.
  var GOOGLE_CLIENT_ID = "560106211240-ip7sv5rrpc71f6jenmod34e13i94rdjg.apps.googleusercontent.com";

  function pick(hostname) {
    var h = String(hostname || "").toLowerCase();
    return PRODUCTION_HOSTS.indexOf(h) > -1 ? LIVE : DEV;
  }
  var chosen = pick(typeof location !== "undefined" ? location.hostname : "");
  var cfg = { ENV: chosen.ENV, SUPABASE_URL: chosen.SUPABASE_URL, SUPABASE_ANON_KEY: chosen.SUPABASE_ANON_KEY,
              GOOGLE_CLIENT_ID: GOOGLE_CLIENT_ID, TURNSTILE_SITE_KEY: chosen.TURNSTILE_SITE_KEY };

  // A small tab hanging from the top edge on every non-production page, so nobody mistakes a test build for the real site.
  // (Pages that draw their own shell call this again after they replace the page body.)
  cfg.showEnvBanner = function () {
    if (cfg.ENV !== "dev" || typeof document === "undefined" || !document.body || document.getElementById("td-env")) return;
    var b = document.createElement("div");
    b.id = "td-env"; b.setAttribute("role", "note");
    b.textContent = "Test version · dummy data only";
    b.style.cssText = "position:fixed;top:0;left:50%;transform:translateX(-50%);z-index:2147483000;padding:2px 12px 3px;" +
      "background:#B45309;color:#fff;font:700 11px/1.3 Manrope,system-ui,sans-serif;letter-spacing:.02em;border-radius:0 0 8px 8px;pointer-events:none";
    document.body.appendChild(b);
  };
  if (typeof document !== "undefined" && document.addEventListener) {
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", cfg.showEnvBanner);
    else cfg.showEnvBanner();
  }
  cfg._pick = pick; cfg._production = PRODUCTION_HOSTS.slice();      // for tests/config.test.js
  window.TLENG_CONFIG = cfg;
})();
