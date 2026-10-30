#!/usr/bin/env python3
"""Build changelog.html from the "Raphael's updates" log in README.md.
Run after adding a log entry:  python3 tools/build-changelog.py
Each entry's first sentence (the bold header) becomes a headline; the rest is the summary.
Internal file paths, PR numbers and dev notes stay in the README — the public page only shows the headline + summary."""
import re, html, datetime, pathlib
root = pathlib.Path(__file__).resolve().parent.parent
md = (root / "README.md").read_text(encoding="utf-8")
sec = md.split("## Raphael's updates", 1)[1].split("\n## ", 1)[0]
entries = re.findall(r"^- \*\*(\d{4}-\d{2}-\d{2}) — (.+?)\*\*\s*(.*?)(?=^- \*\*\d{4}-\d{2}-\d{2} — |\Z)", sec, re.S | re.M)
MON = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
def clean(t):
    t = re.sub(r"\s+in `[^`]*`", "", t)               # "in vercel.json" → gone cleanly
    t = re.sub(r"`[^`]*`", "", t)                       # drop remaining code spans (file names)
    t = re.sub(r"\(\d\)\s*", "", t)                   # (1) (2) numbering
    t = re.sub(r"\s*\([^()]*\)", lambda m: "" if re.search(r"[./_]|→|v\d", m.group(0)) else m.group(0), t)  # drop parentheticals that are dev notes
    t = re.sub(r"\*\*(.+?)\*\*", r"\1", t)              # unbold
    t = re.sub(r"\(#\d+\)|#\d+", "", t)                 # PR numbers
    t = re.sub(r"\s+", " ", t).strip()
    t = re.sub(r"\s+([,.;:])", r"\1", t)
    t = re.sub(r"[:;]?\s*(,\s*){2,}", ", ", t)           # ",,,," / ":,,." left by removed code spans
    t = re.sub(r"^\s*-\s*", "", t)                        # leading list dash
    t = re.sub(r"\b(in|from|under|at)\s+(app\.js|[a-z-]+\.(?:js|html|css|json|sql))\b", "", t)
    t = re.sub(r"\s*\(\s*\)", "", t)                   # empty "()"
    t = re.sub(r"\s*→\s*([,.])", r"\1", t)             # "Start free →," → "Start free,"
    t = re.sub(r",\s*(and|or)\b", r" \1", t)            # "fonts, and" → "fonts and"
    return t
def first_sentences(t, n=2):
    parts = re.split(r"(?<=[.!?])\s+(?=[A-Z(])", t)
    return " ".join(parts[:n]).strip()
items = []
for d, title, body in entries:
    ver = re.search(r"\((v\d+)\)\s*\.?\s*$", title); label = ver.group(1) if ver else ""
    title = clean(re.sub(r"\s*\(v\d+\)\s*\.?\s*$", "", title)).rstrip(".")
    y, m, dd = d.split("-"); nice = f"{int(dd)} {MON[int(m)-1]} {y}"
    summary = first_sentences(clean(body), 2)
    if len(summary) > 260: summary = first_sentences(clean(body), 1)
    if body.lstrip().startswith("-") or re.search(r",,|:\s*,|\(\s*\)|\bwhen,", summary): summary = ""   # bullet-list bodies don't summarise well — headline only
    items.append((d, nice, title, label, summary))
items.sort(key=lambda x: x[0], reverse=True)
lis = "\n".join(
    f'      <li><time datetime="{d}">{nice}</time><div><h2>{html.escape(t)}{(" <span class=v>"+l+"</span>") if l else ""}</h2>{("<p>"+html.escape(s)+"</p>") if s else ""}</div></li>'
    for d, nice, t, l, s in items)
page = f'''<!doctype html>
<html lang="en-SG">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>What's new · TutorDeck</title>
<meta name="description" content="Every improvement shipped to TutorDeck, the tuition management app for private tutors in Singapore — newest first.">
<link rel="canonical" href="https://www.tutordeck.com.sg/changelog">
<link rel="icon" type="image/svg+xml" href="assets/img/logo.svg">
<link href="https://fonts.googleapis.com/css2?family=Manrope:wght@400;600;700;800&display=swap" rel="stylesheet">
<style>
  :root{{--ink:#13233F;--accent:#0F766E;--ground:#FAF9F6;--line:#E8E5DE;--muted:#5E6676}}
  *{{box-sizing:border-box}} body{{margin:0;font-family:Manrope,system-ui,sans-serif;background:var(--ground);color:var(--ink);line-height:1.55}}
  .wrap{{max-width:760px;margin:0 auto;padding:28px 22px 60px}}
  .top{{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:28px}}
  .brand{{display:flex;align-items:center;gap:10px;font-weight:800;text-decoration:none;color:var(--ink)}} .brand img{{width:28px;height:28px}}
  .top a.btn{{color:var(--accent);font-weight:700;text-decoration:none;border:1px solid var(--line);border-radius:10px;padding:8px 14px;background:#fff}}
  h1{{font-size:clamp(28px,4vw,38px);font-weight:800;letter-spacing:-.03em;margin:0 0 6px}} .lede{{color:var(--muted);margin:0 0 30px}}
  ul{{list-style:none;padding:0;margin:0}} li{{display:grid;grid-template-columns:120px 1fr;gap:16px;padding:18px 0;border-top:1px solid var(--line)}}
  time{{color:var(--muted);font-size:13.5px;font-weight:600;padding-top:3px}}
  h2{{font-size:17px;font-weight:800;margin:0 0 4px;letter-spacing:-.01em}} .v{{font-size:11px;font-weight:700;color:var(--accent);background:#E7F3F1;border-radius:999px;padding:2px 8px;margin-left:6px;vertical-align:middle}}
  p{{margin:0;color:var(--muted);font-size:14.5px}}
  footer{{margin-top:40px;color:var(--muted);font-size:13px}} footer a{{color:var(--accent)}}
  @media(max-width:600px){{li{{grid-template-columns:1fr;gap:4px}}}}
</style>
</head>
<body>
<div class="wrap">
  <div class="top"><a class="brand" href="/"><img src="assets/img/logo.svg" alt="">TutorDeck</a><a class="btn" href="login?mode=signup">Start free</a></div>
  <h1>What's new</h1>
  <p class="lede">Every improvement shipped to TutorDeck, newest first. Built by tutors who use it every day.</p>
  <ul>
{lis}
  </ul>
  <footer>Updated {datetime.date.today().strftime("%-d %b %Y")} · <a href="/">Home</a> · <a href="privacy">Privacy</a> · <a href="terms">Terms</a></footer>
</div>
</body>
</html>
'''
(root / "changelog.html").write_text(page, encoding="utf-8")
print(f"changelog.html: {len(items)} entries")
