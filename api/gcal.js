// Google Calendar "connect once" — one endpoint, POST { action, ... } with the TutorDeck (Supabase) access
// token in "Authorization: Bearer …". The browser never sees the long-lived Google key: it's stored encrypted
// in public.gcal_links (row-level security: each tutor only their own row) and only this server can decrypt it.
//   start      → { url }  Google's consent page to send the browser to (state is signed + bound to this tutor)
//   finish     → stores the key handed back by api/gcal-callback → { access_token, expires_in, email }
//   token      → a fresh 1-hour Google pass, no pop-up → { access_token, expires_in, email } | 404 not_linked | 401 revoked
//   set_calendar → remembers which Google calendar lessons go into (so other devices pick it up)
//   disconnect → revokes the key at Google and deletes the row
"use strict";
const L = require("./_gcal-lib");

module.exports = async function (req, res) {
  if (req.method !== "POST") return L.send(res, 405, { error: "method" });
  if (!L.configured()) return L.send(res, 503, { error: "not_configured" });
  const jwt = String(req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  const user = await L.getUser(jwt);
  if (!user) return L.send(res, 401, { error: "signed_out" });
  const b = await L.readBody(req), uid = user.id;
  try {
    if (b.action === "start") {
      const ru = L.redirectUri(req);
      if (!ru) return L.send(res, 400, { error: "host" });
      const ret = /^\/[a-z0-9\-/?=&]*$/i.test(b.ret || "") ? b.ret : "/calendar";
      const state = L.seal({ uid, ret, exp: Date.now() + 10 * 60e3, n: require("crypto").randomBytes(8).toString("hex") });
      const q = new URLSearchParams({ client_id: L.GOOGLE_CLIENT_ID, redirect_uri: ru, response_type: "code", scope: L.SCOPE,
        access_type: "offline", prompt: "select_account consent", include_granted_scopes: "true", state });
      return L.send(res, 200, { url: "https://accounts.google.com/o/oauth2/v2/auth?" + q.toString() });
    }
    if (b.action === "finish") {
      const p = L.open(b.blob);
      if (!p || p.uid !== uid || Date.now() > p.exp) return L.send(res, 400, { error: "expired" });
      if (b.decline) { await L.revoke(p.rt); return L.send(res, 200, { ok: true }); }   // picked the wrong account → undo at Google
      const old = await L.db(jwt, "GET", "gcal_links?select=google_email,calendar_id,refresh_enc&tutor_id=eq." + uid);
      if (!old.ok) return L.send(res, old.status === 404 ? 503 : 500, { error: old.status === 404 ? "no_table" : "read" });
      const prevRow = old.data && old.data[0], prev = prevRow && L.open(prevRow.refresh_enc);
      // Connected a DIFFERENT Google account than the one lessons sync to? Ask first (nothing saved yet).
      const linked = (prevRow && prevRow.google_email) || String(b.expect || "");
      if (linked && p.email && linked !== p.email && !b.replace) return L.send(res, 409, { error: "other_account", email: p.email, linked });
      const up = await L.db(jwt, "POST", "gcal_links?on_conflict=tutor_id",
        Object.assign({ tutor_id: uid, google_email: p.email, refresh_enc: L.seal({ rt: p.rt }), updated_at: new Date().toISOString() },
          linked && linked !== p.email ? { calendar_id: null } : {}),        // new account → its calendars are different
        { Prefer: "resolution=merge-duplicates,return=minimal" });
      if (!up.ok) return L.send(res, 500, { error: up.status === 404 ? "no_table" : "save" });
      if (prev && prev.rt && prev.rt !== p.rt) await L.revoke(prev.rt);      // replaced an older link → retire its key
      const cal = linked && linked !== p.email ? null : (prevRow && prevRow.calendar_id) || null;
      return L.send(res, 200, { access_token: p.at, expires_in: p.exp_in, email: p.email, calendar: cal });
    }
    if (b.action === "token") {
      const r = await L.db(jwt, "GET", "gcal_links?select=google_email,calendar_id,refresh_enc&tutor_id=eq." + uid);
      if (!r.ok) return L.send(res, r.status === 404 ? 503 : 500, { error: r.status === 404 ? "no_table" : "read" });
      const row = r.data && r.data[0];
      if (!row) return L.send(res, 404, { error: "not_linked" });
      const k = L.open(row.refresh_enc);
      if (!k || !k.rt) return L.send(res, 404, { error: "not_linked" });
      const t = await L.googleToken({ grant_type: "refresh_token", refresh_token: k.rt });
      if (!t.ok) {
        if (t.data && t.data.error === "invalid_grant") {                   // access removed in Google → forget it
          await L.db(jwt, "DELETE", "gcal_links?tutor_id=eq." + uid);
          return L.send(res, 401, { error: "revoked" });
        }
        return L.send(res, 502, { error: "google" });
      }
      return L.send(res, 200, { access_token: t.data.access_token, expires_in: t.data.expires_in, email: row.google_email, calendar: row.calendar_id || null });
    }
    if (b.action === "set_calendar") {
      const cal = String(b.calendar || "").slice(0, 300);
      if (!cal) return L.send(res, 400, { error: "calendar" });
      const r = await L.db(jwt, "PATCH", "gcal_links?tutor_id=eq." + uid, { calendar_id: cal, updated_at: new Date().toISOString() }, { Prefer: "return=minimal" });
      return L.send(res, r.ok ? 200 : 500, r.ok ? { ok: true } : { error: "save" });
    }
    if (b.action === "disconnect") {
      const r = await L.db(jwt, "GET", "gcal_links?select=refresh_enc&tutor_id=eq." + uid);
      const k = r.ok && r.data && r.data[0] && L.open(r.data[0].refresh_enc);
      if (k && k.rt) await L.revoke(k.rt);
      await L.db(jwt, "DELETE", "gcal_links?tutor_id=eq." + uid);
      return L.send(res, 200, { ok: true });
    }
    return L.send(res, 400, { error: "action" });
  } catch (e) {
    console.error("gcal", b && b.action, e && e.message);                    // never log tokens
    return L.send(res, 500, { error: "server" });
  }
};
