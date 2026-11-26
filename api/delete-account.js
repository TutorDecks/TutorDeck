// Delete my account — POST /api/delete-account   Authorization: Bearer <TutorDeck access token>   body { "confirm": "DELETE" }
// Replaces the old Supabase Edge Function, which could only delete the login. A solo tutor's data now hangs off an
// organisation (not the login), and some of it lives outside the database, so this one server function does it all, in this order:
//   1  check: signed in, typed confirmation, and not also part of a tuition centre (centres can't be deleted this way yet)
//   2  Stripe: cancel the subscription now (no refund), then delete the Stripe customer (name + email; Stripe keeps its own invoice records)
//   3  storage: every file in "receipts" and "materials" (the database can't delete these)
//   4  Google: revoke the Calendar link's token at Google (best effort)
//   5  database: org_delete_solo(), one transaction that removes the organisation and everything of theirs, audit log included
//   6  the login itself
// Order matters: steps 2–4 are retryable and use ids that step 5 would erase; if any step 1–5 fails nothing later runs, the
// answer is an error, and pressing Delete again continues where it stopped (every step copes with "already gone").
// A tutor whose subscription couldn't be cancelled is never deleted, so nobody keeps being billed for an account that's gone.
// Needs (Vercel env vars, server only): SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, STRIPE_SECRET_KEY (only if they ever subscribed),
// GOOGLE_CLIENT_SECRET + GCAL_TOKEN_KEY (only to revoke Google). SUPABASE_URL has no default here, so a Preview can't touch the wrong database.
// Never logs names, emails, tokens or row contents.
"use strict";
const L = require("./_gcal-lib");
const B = require("./_billing-lib");

const SERVICE_KEY = () => process.env.SUPABASE_SERVICE_ROLE_KEY || "";
const BUCKETS = ["receipts", "materials"];
const LIVE = ["trialing", "active", "past_due", "unpaid"];

// the service key, for Storage and the Auth admin API (B.svc covers the REST API)
async function raw(method, path, body) {
  const r = await fetch(B.SUPABASE_URL + path, { method,
    headers: { apikey: SERVICE_KEY(), Authorization: "Bearer " + SERVICE_KEY(), "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined });
  const t = await r.text();
  let d = null; try { d = t ? JSON.parse(t) : null; } catch (e) {}
  return { ok: r.ok, status: r.status, data: d };
}

// every file under bucket/prefix, folders included
async function listFiles(bucket, prefix) {
  const out = [];
  for (let off = 0; ; off += 100) {
    const r = await raw("POST", "/storage/v1/object/list/" + bucket, { prefix, limit: 100, offset: off, sortBy: { column: "name", order: "asc" } });
    if (!r.ok) throw new Error("storage list " + r.status);
    const items = Array.isArray(r.data) ? r.data : [];
    for (const it of items) {
      if (it.id) out.push(prefix + it.name);                                  // a file
      else out.push.apply(out, await listFiles(bucket, prefix + it.name + "/")); // a folder
    }
    if (items.length < 100) break;
  }
  return out;
}
async function removeFiles(bucket, paths) {
  for (let i = 0; i < paths.length; i += 100) {
    const r = await raw("DELETE", "/storage/v1/object/" + bucket, { prefixes: paths.slice(i, i + 100) });
    if (!r.ok) throw new Error("storage remove " + r.status);
  }
}
const gone = (e) => e && (e.status === 404 || (e.stripe && e.stripe.code === "resource_missing"));

module.exports = async function (req, res) {
  if (req.method !== "POST") return L.send(res, 405, { error: "method" });
  if (!B.SUPABASE_URL || !SERVICE_KEY()) return L.send(res, 503, { error: "not_configured" });
  const jwt = String(req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  const user = await L.getUser(jwt);
  if (!user) return L.send(res, 401, { error: "signed_out" });
  const b = await L.readBody(req);
  if (b.confirm !== "DELETE") return L.send(res, 400, { error: "confirm" });
  const uid = user.id;
  let step = "start";

  try {
    // ---- 1. which organisation, and is this person only a solo tutor?
    step = "find";
    const p = await B.svc("POST", "rpc/org_personal", { p_user: uid });
    if (!p.ok) return L.send(res, p.status === 404 ? 503 : 502, { error: p.status === 404 ? "not_ready" : "db" });
    const org = typeof p.data === "string" ? p.data : null;                    // null: already deleted on an earlier try
    const mem = await B.svc("GET", "memberships?select=org_id&user_id=eq." + uid);
    if (!mem.ok) return L.send(res, 502, { error: "db" });
    if ((mem.data || []).some((m) => m.org_id !== org)) return L.send(res, 409, { error: "has_other_orgs" });

    if (org) {
      // ---- 2. Stripe
      step = "stripe";
      const s = await B.svc("GET", "org_subscriptions?select=status,stripe_customer_id,stripe_subscription_id&org_id=eq." + org);
      if (!s.ok && s.status !== 404) return L.send(res, 502, { error: "db" });        // 404: the billing tables aren't installed, so no subscription
      const sub = s.ok && s.data && s.data[0];
      if (sub && (sub.stripe_customer_id || sub.stripe_subscription_id)) {
        if (!process.env.STRIPE_SECRET_KEY) return L.send(res, 503, { error: "stripe_not_configured" });
        try {
          if (sub.stripe_subscription_id && LIVE.indexOf(sub.status) >= 0) {
            try { await B.stripe("DELETE", "/subscriptions/" + encodeURIComponent(sub.stripe_subscription_id)); } catch (e) { if (!gone(e)) throw e; }
          }
          if (sub.stripe_customer_id) {
            try { await B.stripe("DELETE", "/customers/" + encodeURIComponent(sub.stripe_customer_id)); } catch (e) { if (!gone(e)) throw e; }
          }
        } catch (e) { console.error("delete-account stripe", e && e.status, e && e.stripe && e.stripe.code); return L.send(res, 502, { error: "billing_unavailable" }); }
      }

      // ---- 3. storage (paths come from our own rows plus everything under the tutor's folder)
      step = "storage";
      const mats = await B.svc("GET", "materials?select=file_path&owner_id=eq." + uid);
      const known = (mats.ok && mats.data || []).map((m) => m.file_path).filter(Boolean);
      for (const bucket of BUCKETS) {
        const files = await listFiles(bucket, uid + "/");
        const all = Array.from(new Set(files.concat(bucket === "materials" ? known : [])));
        if (all.length) await removeFiles(bucket, all);
      }

      // ---- 4. Google Calendar token (the encrypted copy is deleted with the login; this makes Google forget it too)
      step = "google";
      try {
        const g = await B.svc("GET", "gcal_links?select=refresh_enc&tutor_id=eq." + uid);
        const k = g.ok && g.data && g.data[0] && L.configured() && L.open(g.data[0].refresh_enc);
        if (k && k.rt) await L.revoke(k.rt);
      } catch (e) { /* best effort: our copy is deleted either way */ }

      // ---- 5. the database
      step = "database";
      const d = await B.svc("POST", "rpc/org_delete_solo", { p_org: org, p_user: uid });
      if (!d.ok) {
        const msg = String((d.data && d.data.message) || "");
        if (msg.indexOf("HAS_OTHER_ORGS") >= 0) return L.send(res, 409, { error: "has_other_orgs" });
        console.error("delete-account database", d.status, msg.split(":")[0]);                // our own error codes only, never row data
        return L.send(res, d.status === 404 ? 503 : 502, { error: d.status === 404 ? "not_ready" : "db" });
      }
    }

    // ---- 6. the login (also removes the profile, Google link and error log, which hang off it)
    step = "login";
    const u = await raw("DELETE", "/auth/v1/admin/users/" + uid);
    if (!u.ok && u.status !== 404) { console.error("delete-account login", u.status); return L.send(res, 502, { error: "login" }); }
    return L.send(res, 200, { ok: true });
  } catch (e) {
    console.error("delete-account", step, e && e.message);                               // never echo internals to the browser
    return L.send(res, 502, { error: "failed", step });
  }
};
