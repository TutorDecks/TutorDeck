"use strict";
// The safety rule for which database a page talks to: only the listed production addresses get the REAL database; everything else gets DEV.
const test = require("node:test"), assert = require("node:assert"), fs = require("fs"), path = require("path"), vm = require("vm"), { execFileSync } = require("child_process");
const SRC = fs.readFileSync(path.join(__dirname, "../assets/js/config.js"), "utf8");
const LIVE_URL = "https://rnjvswkejbrhbaytutai.supabase.co", DEV_URL = "https://tuzxsqkfzrjssnpcoale.supabase.co";

function load(hostname) {   // run config.js as a browser would on that address (no DOM needed)
  const win = {}; vm.runInNewContext(SRC, { window: win, location: { hostname }, document: undefined });
  return win.TLENG_CONFIG;
}

test("the real production addresses get the real database", () => {
  ["www.tutordeck.com.sg", "tutordeck.com.sg", "tutordeck.vercel.app", "tutordeck-longraphaeljames-8916.vercel.app", "tutordeck-git-main-longraphaeljames-8916.vercel.app"].forEach((h) => {
    const c = load(h); assert.strictEqual(c.ENV, "live", h); assert.strictEqual(c.SUPABASE_URL, LIVE_URL, h);
    assert.ok(c.TURNSTILE_SITE_KEY, h + " keeps the sign-up bot check");
  });
});

test("every preview, the dev branch, local testing and unknown addresses get DEV (never the real database)", () => {
  ["tutordeck-git-claude-sleepy-bell-xfr6zb-longraphaeljames-8916.vercel.app", "tutordeck-git-dev-longraphaeljames-8916.vercel.app", "tutordeck-254w1aczj-longraphaeljames-8916.vercel.app",
   "localhost", "127.0.0.1", "", "example.com", "tutordeck.vercel.app.evil.com", "evil-tutordeck.vercel.app", "tutordeck.com.sg.evil.com", "WWW.TUTORDECK.COM.SG.", "www.tutordeck.com.sg:8080"].forEach((h) => {
    const c = load(h);
    if (h === "WWW.TUTORDECK.COM.SG.") return;                     // see next test (case is normalised)
    assert.strictEqual(c.ENV, "dev", "'" + h + "' must not get the real database"); assert.strictEqual(c.SUPABASE_URL, DEV_URL, h);
    assert.strictEqual(c.TURNSTILE_SITE_KEY, "", h + ": no bot check on test builds");
  });
  assert.strictEqual(load(undefined).ENV, "dev", "no address at all = DEV");
});

test("capital letters in the address don't matter, look-alike addresses do", () => {
  assert.strictEqual(load("WWW.TutorDeck.com.SG").ENV, "live");
  assert.strictEqual(load("www.tutordeck.com.sg.").ENV, "dev", "a trailing dot isn't one of the listed addresses (fails safe)");
});

test("both projects have different URLs and keys, and the keys are the publishable kind", () => {
  const l = load("tutordeck.vercel.app"), d = load("localhost");
  assert.notStrictEqual(l.SUPABASE_URL, d.SUPABASE_URL); assert.notStrictEqual(l.SUPABASE_ANON_KEY, d.SUPABASE_ANON_KEY);
  [l, d].forEach((c) => assert.match(c.SUPABASE_ANON_KEY, /^sb_publishable_/));
  assert.ok(!/service_role|secret/i.test(SRC), "no secret keys in this public file");
  assert.strictEqual(l.GOOGLE_CLIENT_ID, d.GOOGLE_CLIENT_ID);
});

test("the production list is exactly the one in the Vercel project (update both together)", () => {
  assert.deepStrictEqual(Array.from(load("localhost")._production).sort(), ["tutordeck-git-main-longraphaeljames-8916.vercel.app", "tutordeck-longraphaeljames-8916.vercel.app",
    "tutordeck.com.sg", "tutordeck.vercel.app", "www.tutordeck.com.sg"].sort());
});

test("server functions: without settings, only the production deployment falls back to the real database", () => {
  const url = (env) => execFileSync(process.execPath, ["-e", "console.log(require(process.argv[1]).SUPABASE_URL)", path.join(__dirname, "../api/_gcal-lib.js")],
    { env: Object.assign({ PATH: process.env.PATH }, env) }).toString().trim();
  assert.strictEqual(url({}), DEV_URL, "no VERCEL_ENV (local/tests)");
  assert.strictEqual(url({ VERCEL_ENV: "preview" }), DEV_URL, "preview");
  assert.strictEqual(url({ VERCEL_ENV: "development" }), DEV_URL);
  assert.strictEqual(url({ VERCEL_ENV: "production" }), LIVE_URL, "production keeps the real database");
  assert.strictEqual(url({ VERCEL_ENV: "preview", SUPABASE_URL: "https://x.supabase.co" }), "https://x.supabase.co", "an explicit setting always wins");
});
