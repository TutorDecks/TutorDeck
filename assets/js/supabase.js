// Creates the shared Supabase client used by every page.
// Loaded after the CDN script (window.supabase) and config.js.
(function () {
  var cfg = window.TLENG_CONFIG || {};
  window.TL_CONFIGURED =
    cfg.SUPABASE_URL &&
    cfg.SUPABASE_URL.indexOf("YOUR-PROJECT") === -1 &&
    cfg.SUPABASE_ANON_KEY &&
    cfg.SUPABASE_ANON_KEY.indexOf("YOUR-ANON") === -1;

  if (!window.supabase || !window.supabase.createClient) {
    console.error("Supabase library failed to load.");
    return;
  }
  // Use placeholders if unconfigured so pages still render (with a banner).
  window.sb = window.supabase.createClient(
    cfg.SUPABASE_URL || "https://placeholder.supabase.co",
    cfg.SUPABASE_ANON_KEY || "placeholder"
  );
})();
// ---- Error log (db/migration_client_errors.sql) ----
// Writes a short row to client_errors when, on a signed-in tutor's device, a script crashes, a
// database request fails, or the security policy blocks something. Read it in Supabase →
// Table Editor → client_errors. At most 5 reports per page load, each distinct message once;
// nothing is sent when signed out or offline. Values that could be personal data (emails, long
// numbers, "(column)=(value)" pairs from database messages) are blanked before sending.
(function () {
  var sb = window.sb; if (!sb || !sb.from) return;
  var sent = 0, seen = {}, MAX = 5;
  function ver() { var l = document.querySelector('link[href*="app.css?v="]'); var m = l && /v=(\d+)/.exec(l.getAttribute("href")); return m ? "v" + m[1] : ""; }
  function scrub(s) {
    return String(s == null ? "" : s)
      .replace(/\(([^()]*)\)=\(([^()]*)\)/g, "($1)=(…)")
      .replace(/[\w.+-]+@[\w-]+\.[\w.-]+/g, "<email>")
      .replace(/\+?\d[\d\s-]{6,}\d/g, "<number>");
  }
  function report(kind, message, detail) {
    try {
      message = scrub(message).slice(0, 500);
      if (!message || sent >= MAX || seen[kind + message] || (navigator.onLine === false)) return;
      seen[kind + message] = 1; sent++;
      sb.auth.getSession().then(function (r) {
        if (!r || !r.data || !r.data.session) return;   // signed out: the table only accepts signed-in tutors
        sb.from("client_errors").insert({
          kind: kind, message: message, detail: scrub(detail).slice(0, 4000) || null,
          page: location.pathname.slice(0, 200), app_version: ver(),
          user_agent: (navigator.userAgent || "").slice(0, 300)
        }).then(function () {}, function () {});
      }, function () {});
    } catch (e) {}
  }
  window.TL_REPORT_ERROR = report;

  // Script crashes (ignore browser-extension noise and the opaque "Script error." from other origins)
  window.addEventListener("error", function (e) {
    if (!e || !e.message || e.message === "Script error." || /ResizeObserver loop/.test(e.message)) return;
    if (e.filename && e.filename.indexOf(location.origin) !== 0) return;
    report("js", e.message, (e.filename || "").replace(location.origin, "") + ":" + e.lineno + ":" + e.colno + (e.error && e.error.stack ? "\n" + e.error.stack : ""));
  });
  window.addEventListener("unhandledrejection", function (e) {
    var r = e && e.reason; if (!r) return;
    var msg = r.message || String(r); if (/Failed to fetch|NetworkError|Load failed/.test(msg)) return;   // just offline/flaky
    report("promise", msg, r.stack || "");
  });
  // Anything the Content-Security-Policy blocks (e.g. a script or request to a new domain)
  document.addEventListener("securitypolicyviolation", function (e) {
    report("csp", (e.violatedDirective || "") + " blocked " + (e.blockedURI || "inline"), (e.sourceFile || "").replace(location.origin, "") + ":" + (e.lineNumber || ""));
  });

  // Failed database requests: every query resolves through the builder's then(), so wrap it once.
  // Skips the error log's own table and "no rows" from .single() (an expected outcome, not a bug).
  try {
    var b = sb.from("client_errors").select("id"), proto = Object.getPrototypeOf(b);   // a query builder; never awaited, so nothing is sent
    while (proto && !Object.prototype.hasOwnProperty.call(proto, "then")) proto = Object.getPrototypeOf(proto);
    if (proto && !proto.__tdWrapped) {
      var orig = proto.then; proto.__tdWrapped = true;
      proto.then = function (onOk, onErr) {
        var self = this;
        return orig.call(this, function (res) {
          try {
            var err = res && res.error, url = self && self.url ? String(self.url) : "";
            if (err && url.indexOf("client_errors") === -1 && err.code !== "PGRST116" && !/Failed to fetch|NetworkError|Load failed/.test(err.message || "")) {
              var table = (/\/rest\/v1\/(?:rpc\/)?([\w-]+)/.exec(url) || [])[1] || "?";
              report("db", (self.method || "") + " " + table + ": " + (err.message || "error"), [err.code, err.details, err.hint].filter(Boolean).join(" | "));
            }
          } catch (e) {}
          return onOk ? onOk(res) : res;
        }, onErr);
      };
    }
  } catch (e) {}
})();
