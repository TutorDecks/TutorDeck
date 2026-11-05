// Google Calendar "connect once" — one endpoint, POST { action, ... } with the TutorDeck (Supabase) access
// token in "Authorization: Bearer …". The browser never sees the long-lived Google key: it's stored encrypted
// in public.gcal_links (row-level security: each tutor only their own row) and only this server can decrypt it.
//   start      → { url }  Google's consent page to send the browser to (state is signed + bound to this tutor)
//   finish     → stores the key handed back by api/gcal-callback → { access_token, expires_in, email }
//   token      → a fresh 1-hour Google pass, no pop-up → { access_token, expires_in, email } | 404 not_linked | 401 revoked
//   set_calendar → remembers which Google calendar lessons go into (so other devices pick it up)
//   disconnect → revokes the key at Google and deletes the row
//   sync       → brings Google Calendar up to date ON THE SERVER, so the tutor can leave the page → 202 { started }
//   status     → how the last / current sync is going → { state: running|ok|error|null, note, at }
"use strict";
const L = require("./_gcal-lib");
const Core = require("../assets/js/gcal-core.js");

// Keep working after the reply is sent (Vercel's waitUntil; same thing @vercel/functions exposes).
function waitUntil() {
  try { const c = globalThis[Symbol.for("@vercel/request-context")]; const x = c && c.get && c.get(); return (x && x.waitUntil) || null; }
  catch (e) { return null; }
}
const STALE_MS = 6 * 60e3;   // a "running" sync older than this died (functions stop at 5 minutes)

// One full sync for this tutor, done as them (row-level security still applies).
async function runSync(jwt, uid, cal, accessToken) {
  const set = (o) => L.db(jwt, "PATCH", "gcal_links?tutor_id=eq." + uid, o, { Prefer: "return=minimal" });
  let lastNote = 0, noteP = Promise.resolve();
  try {
    const st = await L.db(jwt, "GET", "students?select=id,name,location");
    if (!st.ok) throw new Error("students " + st.status);
    const names = {}, locs = {};
    (st.data || []).forEach((x) => { names[x.id] = x.name; locs[x.id] = x.location || ""; });
    const google = async (method, path, body) => {
      const r = await fetch("https://www.googleapis.com/calendar/v3" + path, { method,
        headers: { Authorization: "Bearer " + accessToken, "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
      if (r.status === 401) { const e = new Error("expired"); e.code = 401; throw e; }
      if (!r.ok && r.status !== 410) throw new Error("Google API " + r.status);
      return (r.status === 204 || r.status === 410) ? null : r.json();
    };
    const cols = "id,student_id,lesson_date,start_time,end_time,subject,level,amount,paid,status,postponed,slot_id,one_off";
    const res = await Core.syncAll({
      owner: uid, cal, today: Core.sgToday(), names, locs, google,
      lessons: async (a, b) => { const r = await L.db(jwt, "GET", "lessons?select=" + cols + "&tutor_id=eq." + uid + "&lesson_date=gte." + a + "&lesson_date=lte." + b); return r.ok ? r.data : null; },
      ownLessonIds: async (ids) => { const r = await L.db(jwt, "GET", "lessons?select=id&tutor_id=eq." + uid + "&id=in.(" + ids.join(",") + ")"); return r.ok ? r.data.map((x) => x.id) : null; },
      lastLessonDate: async (from) => { const r = await L.db(jwt, "GET", "lessons?select=lesson_date&tutor_id=eq." + uid + "&lesson_date=gte." + from + "&order=lesson_date.desc&limit=1"); return r.ok && r.data[0] ? r.data[0].lesson_date : null; },
      progress: (label) => { if (Date.now() - lastNote > 1500) { lastNote = Date.now(); noteP = set({ sync_note: "Syncing " + label + "…" }); } },
    });
    await noteP;                                                       // a progress note must not land after the result
    await set({ sync_state: "ok", sync_note: res.text, sync_at: new Date().toISOString() });
    return res;
  } catch (e) {
    const note = e && e.code === 401 ? "Google pass expired mid-sync. Press Sync again." : "Sync hit an error. Press Sync again.";
    console.error("gcal sync", e && e.message);                          // never log tokens or lesson data
    await noteP.catch(() => {});
    await set({ sync_state: "error", sync_note: note, sync_at: new Date().toISOString() });
    return null;
  }
}

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
    if (b.action === "status") {
      const r = await L.db(jwt, "GET", "gcal_links?select=sync_state,sync_note,sync_at,sync_started_at&tutor_id=eq." + uid);
      if (!r.ok) return L.send(res, 503, { error: "no_columns" });
      const row = r.data && r.data[0];
      if (!row) return L.send(res, 404, { error: "not_linked" });
      let state = row.sync_state || null;
      if (state === "running" && Date.now() - Date.parse(row.sync_started_at || 0) > STALE_MS) state = "error";
      return L.send(res, 200, { state, note: state === "error" && row.sync_state === "running" ? "Sync stopped part-way. Press Sync again." : (row.sync_note || ""), at: row.sync_at || null });
    }
    if (b.action === "sync") {
      const r = await L.db(jwt, "GET", "gcal_links?select=calendar_id,refresh_enc,sync_state,sync_started_at&tutor_id=eq." + uid);
      if (!r.ok) return L.send(res, 503, { error: r.status === 404 ? "no_table" : "no_columns" });   // columns missing → browser sync
      const row = r.data && r.data[0];
      if (!row) return L.send(res, 404, { error: "not_linked" });
      if (row.sync_state === "running" && Date.now() - Date.parse(row.sync_started_at || 0) < STALE_MS)
        return L.send(res, 202, { running: true });                    // one at a time; the client just watches it
      const cal = String(b.calendar || row.calendar_id || "").slice(0, 300);
      if (!cal) return L.send(res, 400, { error: "calendar" });
      const k = L.open(row.refresh_enc);
      if (!k || !k.rt) return L.send(res, 404, { error: "not_linked" });
      const t = await L.googleToken({ grant_type: "refresh_token", refresh_token: k.rt });
      if (!t.ok) {
        if (t.data && t.data.error === "invalid_grant") { await L.db(jwt, "DELETE", "gcal_links?tutor_id=eq." + uid); return L.send(res, 401, { error: "revoked" }); }
        return L.send(res, 502, { error: "google" });
      }
      const now = new Date().toISOString();
      const mark = await L.db(jwt, "PATCH", "gcal_links?tutor_id=eq." + uid,
        { sync_state: "running", sync_started_at: now, sync_note: "Syncing…", calendar_id: cal, updated_at: now }, { Prefer: "return=minimal" });
      if (!mark.ok) return L.send(res, 503, { error: "no_columns" });
      const job = runSync(jwt, uid, cal, t.data.access_token);
      const wu = waitUntil();
      if (wu) { wu(job); return L.send(res, 202, { started: true }); }
      const out = await job;                                           // no waitUntil (local test) → finish first
      return L.send(res, 200, { done: true, note: out ? out.text : "" });
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
