#!/usr/bin/env python3
"""TutorDeck smoke tests — run on every pull request (.github/workflows/checks.yml) and locally:

    pip install playwright && python -m playwright install chromium
    (cd tests && npm install)          # axe-core, for the accessibility check
    python3 tests/smoke.py

Never touches Supabase: the Supabase library is swapped for tests/supabase-stub-*.js (made-up
students), and every request that leaves this machine is blocked.

Static checks : JS syntax, JSON files, one ?v= version on every page (matching app.css),
                dark.css regenerated, every local file a page links to exists.
In a browser  : every page, desktop + phone, light (+ dark for app pages): no script errors,
                no console errors, no broken same-origin requests, no Content-Security-Policy
                blocks, and no serious/critical accessibility (axe-core) violations.
"""
import glob, json, os, re, subprocess, sys, tempfile, threading, shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS = os.path.join(ROOT, "tests")
PORT = int(os.environ.get("SMOKE_PORT", "8765"))
BASE = "http://127.0.0.1:%d/" % PORT
APP = ["home", "calendar", "planner", "ledger", "invoices", "insights", "students", "student", "exams", "settings"]
PUBLIC = ["index", "login", "privacy", "terms", "changelog", "reset", "confirmed"]
failures = []

def fail(where, what):
    failures.append("%s: %s" % (where, what))

# ------------------------------------------------------------------ static checks
def static_checks():
    node = shutil.which("node")
    for f in sorted(glob.glob(os.path.join(ROOT, "assets/js/*.js"))):
        if not node: break
        r = subprocess.run([node, "--check", f], capture_output=True, text=True)
        if r.returncode: fail(os.path.relpath(f, ROOT), "syntax error\n" + r.stderr.strip()[:400])
    for f in ["vercel.json", "manifest.json"]:
        try: json.load(open(os.path.join(ROOT, f)))
        except Exception as e: fail(f, "invalid JSON: %s" % e)

    versions = {}
    for f in glob.glob(os.path.join(ROOT, "*.html")):
        for v in re.findall(r"\?v=(\d+)", open(f, encoding="utf-8").read()):
            versions.setdefault(v, set()).add(os.path.basename(f))
    css_v = re.match(r"/\* v(\d+) \*/", open(os.path.join(ROOT, "assets/css/app.css")).readline())
    if len(versions) > 1:
        fail("versions", "pages use different ?v= numbers: " + "; ".join("v%s in %s" % (v, ", ".join(sorted(p)[:4])) for v, p in versions.items()) + " — run bash bump-version.sh <N>")
    elif versions and css_v and css_v.group(1) not in versions:
        fail("versions", "app.css says v%s but pages load ?v=%s — run bash bump-version.sh <N>" % (css_v.group(1), list(versions)[0]))

    # dark.css must match what tools/build-dark.py produces from the current CSS
    tmp = tempfile.mkdtemp()
    try:
        for d in ["assets/css", "tools"]: os.makedirs(os.path.join(tmp, d))
        shutil.copy(os.path.join(ROOT, "tools/build-dark.py"), os.path.join(tmp, "tools"))
        shutil.copy(os.path.join(ROOT, "assets/css/app.css"), os.path.join(tmp, "assets/css"))
        for f in glob.glob(os.path.join(ROOT, "*.html")): shutil.copy(f, tmp)
        subprocess.run([sys.executable, os.path.join(tmp, "tools/build-dark.py")], capture_output=True, check=True)
        if open(os.path.join(tmp, "assets/css/dark.css")).read() != open(os.path.join(ROOT, "assets/css/dark.css")).read():
            fail("assets/css/dark.css", "out of date — run: python3 tools/build-dark.py")
    except Exception as e:
        fail("tools/build-dark.py", "failed: %s" % e)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    for f in glob.glob(os.path.join(ROOT, "*.html")):
        for ref in re.findall(r'(?:src|href)="(assets/[^"?#]+)', open(f, encoding="utf-8").read()):
            if not os.path.exists(os.path.join(ROOT, ref)):
                fail(os.path.basename(f), "links to missing file " + ref)

# ------------------------------------------------------------------ browser checks
INIT = """
window.__csp = [];
document.addEventListener('securitypolicyviolation', function (e) { window.__csp.push(e.violatedDirective + ' blocked ' + (e.blockedURI || 'inline')); });
try { localStorage.setItem('td_tip_client-view', '1'); %s } catch (e) {}
"""

def browser_checks():
    from playwright.sync_api import sync_playwright
    axe_path = os.path.join(TESTS, "node_modules/axe-core/axe.min.js")
    axe = open(axe_path).read() if os.path.exists(axe_path) else None
    if not axe: print("! axe-core not installed (cd tests && npm install) — skipping accessibility check")
    stub_in = os.path.join(TESTS, "supabase-stub-signed-in.js")
    stub_out = os.path.join(TESTS, "supabase-stub-signed-out.js")
    viewports = {"desktop": dict(viewport={"width": 1280, "height": 900}),
                 "phone": dict(viewport={"width": 390, "height": 844}, is_mobile=True, has_touch=True, device_scale_factor=2)}
    checked = 0
    with sync_playwright() as p:
        browser = p.chromium.launch()
        for theme in ["light", "dark"]:
            for vp_name, vp in viewports.items():
                ctx = browser.new_context(**vp)
                ctx.add_init_script(INIT % ("localStorage.setItem('td_theme','dark');" if theme == "dark" else ""))
                # nothing leaves this machine
                ctx.route(re.compile(r"^(?!http://127\.0\.0\.1).*"), lambda r: r.abort())
                ctx.route("**/_vercel/**", lambda r: r.abort())
                for name in APP + ([] if theme == "dark" else PUBLIC):
                    stub = stub_in if name in APP else stub_out
                    page = ctx.new_page()
                    page.route("**/assets/vendor/supabase-2.118.0.js", (lambda s: lambda r: r.fulfill(path=s, content_type="application/javascript"))(stub))
                    where = "%s (%s, %s)" % (name, vp_name, theme)
                    errs = []
                    page.on("pageerror", lambda e, errs=errs: errs.append("script error: " + str(e)[:300]))
                    page.on("console", lambda m, errs=errs: errs.append("console: " + m.text[:300]) if m.type == "error" and "Failed to load resource" not in m.text else None)
                    page.on("response", lambda r, errs=errs: errs.append("HTTP %d %s" % (r.status, r.url.replace(BASE, "/"))) if r.url.startswith(BASE) and r.status >= 400 else None)
                    url = BASE + ("" if name == "index" else name) + ("?id=s1" if name == "student" else "")
                    try:
                        page.goto(url, wait_until="load", timeout=20000)
                        page.wait_for_timeout(1500)
                    except Exception as e:
                        errs.append("did not load: %s" % str(e)[:200])
                    try:
                        for c in page.evaluate("window.__csp || []"): errs.append("CSP " + c)
                    except Exception: pass
                    if axe:
                        try:
                            page.evaluate(axe)
                            vio = page.evaluate("""axe.run(document, {runOnly: ['wcag2a','wcag2aa','best-practice']}).then(r => r.violations
                                .filter(v => v.impact === 'serious' || v.impact === 'critical')
                                .map(v => v.id + ' (' + v.nodes.length + '): ' + v.help + ' — e.g. ' + v.nodes[0].target.join(' ')))""")
                            for v in vio: errs.append("accessibility: " + v)
                        except Exception as e:
                            errs.append("axe failed: %s" % str(e)[:200])
                    for e in dict.fromkeys(errs): fail(where, e)
                    checked += 1
                    page.close()
                ctx.close()
        browser.close()
    return checked

def main():
    static_checks()
    sys.path.insert(0, TESTS)
    import server
    threading.Thread(target=server.serve, args=(PORT,), daemon=True).start()
    n = browser_checks()
    if failures:
        print("\n✗ %d problem(s):\n" % len(failures))
        for f in failures: print(" - " + f)
        sys.exit(1)
    print("✓ static checks passed; %d page loads checked with no errors" % n)

if __name__ == "__main__":
    main()
