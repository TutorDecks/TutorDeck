// Browser check: which database does a page talk to, on each kind of address? (not part of CI: needs Playwright + `python3 tests/server.py 8765`)
//   node tests/env-hosts.check.js
// Pretend addresses are served from the local copy of the site, so the page really runs config.js under that hostname.
const { chromium } = require("playwright"); const fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, ".."), LOCAL = "http://127.0.0.1:8765";
const STUB = fs.readFileSync(path.join(ROOT, "tests/supabase-stub-signed-in.js"), "utf8");
const LIVE_URL = "https://rnjvswkejbrhbaytutai.supabase.co", DEV_URL = "https://tuzxsqkfzrjssnpcoale.supabase.co";
let fails = 0; const ok = (c, m) => { console.log((c ? "PASS " : "FAIL ") + m); if (!c) fails++; };

async function visit(b, host, pagePath, useStub) {
  const ctx = await b.newContext({ viewport: { width: 1100, height: 800 } });
  const page = await ctx.newPage(); const hits = [];
  await page.route("**/*", async (route) => {
    const u = new URL(route.request().url());
    if (u.hostname === host) {                                              // the pretend site: serve the local files
      if (useStub && u.pathname.endsWith("supabase-2.118.0.js")) return route.fulfill({ body: STUB, contentType: "application/javascript" });
      const r = await route.fetch({ url: LOCAL + u.pathname + u.search }); return route.fulfill({ response: r });
    }
    if (/supabase\.co$/.test(u.hostname)) hits.push(u.origin);               // record, never really call, any Supabase address
    return route.abort();
  });
  await page.goto("https://" + host + pagePath, { waitUntil: "load" }); await page.waitForTimeout(900);
  const info = await page.evaluate(() => ({ env: window.TLENG_CONFIG && window.TLENG_CONFIG.ENV, url: window.TLENG_CONFIG && window.TLENG_CONFIG.SUPABASE_URL,
    clientUrl: window.sb && (window.sb.supabaseUrl || (window.sb.rest && window.sb.rest.url) || ""), banner: !!document.getElementById("td-env"),
    bannerText: (document.getElementById("td-env") || {}).textContent || "", captcha: window.TLENG_CONFIG && window.TLENG_CONFIG.TURNSTILE_SITE_KEY }));
  await ctx.close(); return Object.assign(info, { hits: Array.from(new Set(hits)) });
}

(async () => {
  const b = await chromium.launch();
  for (const host of ["www.tutordeck.com.sg", "tutordeck.com.sg", "tutordeck.vercel.app", "tutordeck-git-main-longraphaeljames-8916.vercel.app"]) {
    const r = await visit(b, host, "/login", false);
    ok(r.env === "live" && r.url === LIVE_URL && r.clientUrl === LIVE_URL && !r.banner && !!r.captcha, "PRODUCTION " + host + ": the database client itself uses the real project, no banner, bot check kept");
    ok(!r.hits.includes(DEV_URL), "PRODUCTION " + host + ": never contacts DEV (contacted: " + (r.hits.join(", ") || "nothing yet") + ")");
  }
  for (const host of ["tutordeck-git-claude-sleepy-bell-xfr6zb-longraphaeljames-8916.vercel.app", "tutordeck-254w1aczj-longraphaeljames-8916.vercel.app", "tutordeck-git-dev-longraphaeljames-8916.vercel.app", "localhost", "tutordeck.vercel.app.evil.example"]) {
    const r = await visit(b, host, "/login", false);
    ok(r.env === "dev" && r.url === DEV_URL && r.clientUrl === DEV_URL && r.banner && r.captcha === "", "PREVIEW " + host + ": the database client itself uses DEV, test banner shown, no bot check");
    ok(!r.hits.includes(LIVE_URL), "PREVIEW " + host + ": never contacts the real database (contacted: " + (r.hits.join(", ") || "nothing yet") + ")");
  }
  // pages that redraw their own shell keep the banner; production pages never get it
  let r = await visit(b, "tutordeck-git-dev-longraphaeljames-8916.vercel.app", "/students", true);
  ok(r.banner && /Test version/.test(r.bannerText), "PREVIEW /students (page with its own shell): the banner survives the redraw: \"" + r.bannerText + "\"");
  r = await visit(b, "www.tutordeck.com.sg", "/students", true);
  ok(!r.banner, "PRODUCTION /students: no banner");
  await b.close(); console.log(fails ? "\n" + fails + " FAILED" : "\nall address checks passed"); process.exit(fails ? 1 : 0);
})();
