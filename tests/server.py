"""Local stand-in for Vercel: serves the repo with the headers from vercel.json (CSP etc.) and
cleanUrls (/ledger → ledger.html), so tests see the same security policy as the live site."""
import json, http.server, os, re, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG = json.load(open(os.path.join(ROOT, "vercel.json")))
def headers_for(path):
    out = {}
    for h in CFG.get("headers", []):
        if h.get("has"): continue                      # query-conditional rules don't matter locally
        pat = "^" + re.sub(r"\(\.\*\)", ".*", h["source"]) + "$"
        if re.match(pat, path): out.update({x["key"]: x["value"] for x in h["headers"]})
    return out
class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=ROOT, **k)
    def end_headers(self):
        for k, v in headers_for(self.path.split("?")[0]).items(): self.send_header(k, v)
        super().end_headers()
    def log_message(self, *a): pass
    def do_POST(self):
        # Test-only stand-in for api/gcal (the real function needs Vercel + Supabase). Answers 200 "not connected" with no
        # access_token, so the Calendar page falls back to its legacy mode quietly. Real 404/503s would trip the smoke test's
        # "HTTP >= 400" check. Every other POST still gets 501, so real problems are not hidden.
        if self.path.split("?")[0] == "/api/gcal":
            n = int(self.headers.get("Content-Length") or 0)
            if n: self.rfile.read(n)
            body = json.dumps({"linked": False, "state": None, "note": "", "at": None}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        else:
            self.send_error(501, "Unsupported method ('POST')")
    def translate_path(self, p):
        full = super().translate_path(p)
        if os.path.isdir(full) and os.path.exists(os.path.join(full, "index.html")): return os.path.join(full, "index.html")
        if not os.path.exists(full) and os.path.exists(full + ".html"): return full + ".html"
        return full
def serve(port):
    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
if __name__ == "__main__": serve(int(sys.argv[1]) if len(sys.argv) > 1 else 8765)
