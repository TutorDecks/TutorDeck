// Google sends the browser back here after the consent page (GET ?code&state, or ?error).
// We swap the one-time code for tokens, seal them for this tutor (10-minute, encrypted, readable only by this
// server), and hand the sealed blob back to the app in the URL fragment; the app then calls api/gcal "finish"
// with the tutor's own sign-in, which checks the blob belongs to them before saving anything.
"use strict";
const L = require("./_gcal-lib");

function back(res, url) { res.statusCode = 302; res.setHeader("Location", url); res.setHeader("Cache-Control", "no-store"); res.end(); }

module.exports = async function (req, res) {
  const o = L.origin(req);
  if (!o) { res.statusCode = 400; return res.end("Unknown host"); }
  const u = new URL(req.url, o), st = L.configured() ? L.open(u.searchParams.get("state")) : null;
  const ret = (st && st.ret) || "/calendar";
  if (!st || Date.now() > st.exp) return back(res, o + ret + "#gcal_error=expired");
  if (u.searchParams.get("error")) return back(res, o + ret + "#gcal_error=" + encodeURIComponent(u.searchParams.get("error")));
  try {
    const t = await L.googleToken({ grant_type: "authorization_code", code: u.searchParams.get("code") || "", redirect_uri: L.redirectUri(req) });
    if (!t.ok || !t.data.access_token) return back(res, o + ret + "#gcal_error=exchange");
    if (!t.data.refresh_token) return back(res, o + ret + "#gcal_error=no_refresh");
    const granted = String(t.data.scope || "");
    if (granted.indexOf("calendar.events") < 0 || granted.indexOf("calendar.calendarlist.readonly") < 0) {
      await L.revoke(t.data.refresh_token);                                   // unticked a permission → can't sync
      return back(res, o + ret + "#gcal_error=scope");
    }
    const email = await L.googleEmail(t.data.access_token);
    const blob = L.seal({ uid: st.uid, rt: t.data.refresh_token, at: t.data.access_token, exp_in: t.data.expires_in || 3600,
      email: email || "", exp: Date.now() + 10 * 60e3 });
    return back(res, o + ret + "#gcal=" + blob);
  } catch (e) {
    console.error("gcal-callback", e && e.message);
    return back(res, o + ret + "#gcal_error=server");
  }
};
