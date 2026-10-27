// Shared helpers for the Google Calendar "connect once" server functions (api/gcal.js, api/gcal-callback.js).
// Files starting with "_" are not routes on Vercel.
//
// Secrets live ONLY in Vercel → Settings → Environment Variables (never in this public repo):
//   GOOGLE_CLIENT_SECRET  the OAuth client secret of the TutorDeck web client (Google Cloud → Credentials)
//   GCAL_TOKEN_KEY        any long random string; used to encrypt each tutor's Google refresh token
// The Supabase URL / publishable key and the Google client ID are public (same values as assets/js/config.js).
"use strict";
const crypto = require("crypto");

const SUPABASE_URL = process.env.SUPABASE_URL || "https://rnjvswkejbrhbaytutai.supabase.co";
const SUPABASE_ANON = process.env.SUPABASE_ANON_KEY || "sb_publishable_IKUtlGhnwJT0Hld5A8cglw_0iF6Y5J9";
const GOOGLE_CLIENT_ID = process.env.GOOGLE_CLIENT_ID || "560106211240-ip7sv5rrpc71f6jenmod34e13i94rdjg.apps.googleusercontent.com";
const SCOPE = "https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.calendarlist.readonly";

function configured() { return !!(process.env.GOOGLE_CLIENT_SECRET && (process.env.GCAL_TOKEN_KEY || "").length >= 16); }
function key() { return crypto.createHash("sha256").update(String(process.env.GCAL_TOKEN_KEY)).digest(); }

// AES-256-GCM, output base64url(iv | tag | ciphertext). Only this server can read it.
function seal(obj) {
  const iv = crypto.randomBytes(12), c = crypto.createCipheriv("aes-256-gcm", key(), iv);
  const ct = Buffer.concat([c.update(JSON.stringify(obj), "utf8"), c.final()]);
  return Buffer.concat([iv, c.getAuthTag(), ct]).toString("base64url");
}
function open(s) {
  try {
    const b = Buffer.from(String(s || ""), "base64url");
    const d = crypto.createDecipheriv("aes-256-gcm", key(), b.subarray(0, 12));
    d.setAuthTag(b.subarray(12, 28));
    return JSON.parse(Buffer.concat([d.update(b.subarray(28)), d.final()]).toString("utf8"));
  } catch (e) { return null; }
}

// Which addresses may start / finish a connection. Callback = same host, so each one must be listed under
// "Authorised redirect URIs" in Google Cloud: <host>/api/gcal-callback.
function allowedHost(h) {
  h = String(h || "").toLowerCase();
  return h === "tutordeck.vercel.app" || h === "www.tutordeck.com.sg" || h === "tutordeck.com.sg" ||
    /^tutordeck-git-[a-z0-9-]+-longraphaeljames-8916\.vercel\.app$/.test(h) || /^localhost(:\d+)?$/.test(h) || /^127\.0\.0\.1(:\d+)?$/.test(h);
}
function origin(req) {
  const h = req.headers["x-forwarded-host"] || req.headers.host;
  const proto = /^(localhost|127\.0\.0\.1)/.test(h) ? "http" : "https";
  return allowedHost(h) ? proto + "://" + h : null;
}
function redirectUri(req) { const o = origin(req); return o ? o + "/api/gcal-callback" : null; }

// The signed-in TutorDeck user, from their Supabase access token.
async function getUser(jwt) {
  if (!jwt) return null;
  const r = await fetch(SUPABASE_URL + "/auth/v1/user", { headers: { apikey: SUPABASE_ANON, Authorization: "Bearer " + jwt } });
  if (!r.ok) return null;
  const u = await r.json();
  return u && u.id ? u : null;
}
// Postgres via the REST API *as that user*, so row-level security still applies (no service-role key).
async function db(jwt, method, path, body, extra) {
  const r = await fetch(SUPABASE_URL + "/rest/v1/" + path, {
    method, headers: Object.assign({ apikey: SUPABASE_ANON, Authorization: "Bearer " + jwt, "Content-Type": "application/json" }, extra || {}),
    body: body ? JSON.stringify(body) : undefined });
  const t = await r.text();
  let d = null; try { d = t ? JSON.parse(t) : null; } catch (e) {}
  return { ok: r.ok, status: r.status, data: d };
}
async function googleToken(params) {
  const r = await fetch("https://oauth2.googleapis.com/token", { method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(Object.assign({ client_id: GOOGLE_CLIENT_ID, client_secret: process.env.GOOGLE_CLIENT_SECRET }, params)).toString() });
  const d = await r.json().catch(() => ({}));
  return { ok: r.ok, data: d };
}
// The Google account an access token belongs to (its primary calendar id is the account email).
async function googleEmail(accessToken) {
  const r = await fetch("https://www.googleapis.com/calendar/v3/users/me/calendarList?minAccessRole=owner", { headers: { Authorization: "Bearer " + accessToken } });
  if (!r.ok) return null;
  const d = await r.json().catch(() => ({}));
  const p = (d.items || []).filter((c) => c.primary)[0];
  return (p && p.id) || null;
}
async function revoke(token) {
  try { await fetch("https://oauth2.googleapis.com/revoke", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: "token=" + encodeURIComponent(token) }); } catch (e) {}
}
function send(res, status, obj) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json");
  res.setHeader("Cache-Control", "no-store");
  res.end(JSON.stringify(obj));
}
async function readBody(req) {
  if (req.body && typeof req.body === "object") return req.body;
  if (typeof req.body === "string") { try { return JSON.parse(req.body); } catch (e) { return {}; } }
  const chunks = []; for await (const c of req) chunks.push(c);
  try { return JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}"); } catch (e) { return {}; }
}

module.exports = { SCOPE, GOOGLE_CLIENT_ID, configured, seal, open, origin, redirectUri, getUser, db, googleToken, googleEmail, revoke, send, readBody };
