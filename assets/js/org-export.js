// Settings → Data export (T35-E): the centre owner downloads every record the centre holds as a ZIP of CSV files.
// All the work is in assets/js/org-export-core.js (pure, unit-tested) and db/migration_org_export.sql (owner-only, audited, paged). This file is only the screen:
// the explanation, the "full payout numbers" tick, the progress bar and the download. Called from assets/js/org.js (tab "Data export"), owner only.
(function () {
  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }
  function num(n) { return Number(n).toLocaleString("en-SG"); }
  function mb(bytes) { return bytes >= 1048576 ? (bytes / 1048576).toFixed(1) + " MB" : Math.max(1, Math.round(bytes / 1024)) + " KB"; }
  function missing(err) { return err && (err.code === "42883" || err.code === "PGRST202" || /Could not find the function|does not exist/i.test(err.message || "")); }
  var busy = false;

  // ctx: { el, org, isOwner, sb, members }
  function render(ctx) {
    var el = ctx.el;
    if (!ctx.isOwner) { el.innerHTML = '<section class="card og-card"><h2>Data export</h2><p class="og-sub" style="margin:0">Only the owner of the centre can export its data.</p></section>'; return; }
    el.innerHTML = '<section class="card og-card" id="ex-card"><h2>Export your centre’s data</h2>' +
      '<p class="og-sub">One ZIP file with a spreadsheet (CSV) for each kind of record — students, families, lessons, attendance, invoices, payments, credit, deposits, refunds, settings and more — and a README that explains every column. It opens in Excel, Numbers and Google Sheets.</p>' +
      '<div class="og-note" id="ex-pdpa"><b>This file contains personal data.</b> It has parents’ and guardians’ names, phone numbers and email addresses, and students’ details. Under the PDPA you are responsible for it once it is downloaded: keep it somewhere private, share it only with people who need it, and delete it when you are done.</div>' +
      '<div class="og-note">Not included: passwords and logins, other centres’ data, billing-provider ids (Stripe) and invoice share links. Every “who” column shows a name, never a login id.</div>' +
      '<label class="og-check"><input type="checkbox" id="ex-full"> <span>Include full payout numbers (bank and PayNow) for tutors</span></label>' +
      '<span class="og-help">Left unticked, payout numbers show only their last four digits (•••••1234). Ticking this is written to your audit log.</span>' +
      '<div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap"><button class="btn btn-primary" id="ex-go" type="button">Download export (ZIP)</button><span class="muted" id="ex-hint" style="font-size:13px">Takes a minute or two for a large centre. Keep this page open.</span></div>' +
      '<div id="ex-prog" hidden style="margin-top:14px"><div class="og-prog" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0"><i id="ex-bar"></i></div><div class="og-help" id="ex-ptxt" style="margin:6px 0 0"></div></div>' +
      '<div class="msg" id="ex-msg" role="status" style="margin-top:12px"></div></section>' +
      '<section class="card og-card"><h3 style="margin-top:0">Recent exports</h3><div id="ex-recent" class="muted">Loading…</div></section>';
    var go = ctx.el.querySelector("#ex-go"), msg = ctx.el.querySelector("#ex-msg");
    go.onclick = function () { run(ctx, go, msg); };
    recent(ctx);
  }

  async function recent(ctx) {
    var box = ctx.el.querySelector("#ex-recent"); if (!box) return;
    var r = await ctx.sb.from("audit_log").select("id,actor,action,after,at").eq("org_id", ctx.org.id).in("action", ["org_export_finished"]).order("at", { ascending: false }).limit(5);
    if (r.error || !r.data) { box.textContent = "Nothing to show yet."; return; }
    if (!r.data.length) { box.textContent = "No exports yet."; return; }
    var who = {}; (ctx.members || []).forEach(function (m) { if (m.user_id) who[m.user_id] = m.display_name; });
    box.className = "";
    box.innerHTML = '<div class="og-list">' + r.data.map(function (a) {
      var counts = (a.after && a.after.counts) || {}, total = Object.keys(counts).reduce(function (s, k) { return s + (Number(counts[k]) || 0); }, 0), d = new Date(a.at);
      return '<div class="og-item"><div class="grow"><b>' + esc(d.toLocaleDateString("en-SG", { day: "numeric", month: "short", year: "numeric" }) + " " + d.toLocaleTimeString("en-SG", { hour: "numeric", minute: "2-digit" })) +
        '</b><div class="meta">' + esc(who[a.actor] || "Someone") + " · " + num(total) + " rows · payout numbers " + (a.after && a.after.full_payout ? "full" : "masked") + "</div></div></div>";
    }).join("") + "</div>";
  }

  async function run(ctx, go, msg) {
    if (busy) return; busy = true;
    var X = window.OrgExportCore, full = ctx.el.querySelector("#ex-full").checked;
    if (full && window.TL && TL.confirm) {
      var ok = await TL.confirm({ title: "Include full payout numbers?", message: "Tutors’ full bank account and PayNow numbers will be written into the file. This is recorded in your audit log. Continue?", confirmText: "Include them" });
      if (!ok) { busy = false; return; }
    }
    var prog = ctx.el.querySelector("#ex-prog"), bar = ctx.el.querySelector("#ex-bar"), txt = ctx.el.querySelector("#ex-ptxt"), pb = prog.firstElementChild;
    go.disabled = true; ctx.el.querySelector("#ex-full").disabled = true; prog.hidden = false; msg.textContent = ""; msg.className = "msg";
    var warn = function (e) { e.preventDefault(); e.returnValue = ""; return ""; }; window.addEventListener("beforeunload", warn);
    try {
      var res = await X.runExport(function (name, args) { return ctx.sb.rpc(name, args); }, {
        orgId: ctx.org.id, centreName: ctx.org.trading_name, fullPayout: full,
        onProgress: function (p) {
          var pct = p.expected ? Math.min(99, Math.round(100 * p.done / p.expected)) : 0;
          bar.style.width = pct + "%"; pb.setAttribute("aria-valuenow", String(pct));
          txt.textContent = p.phase === "finishing" ? "Finishing…" : (X.catalogByTable()[p.table] || {}).title + " · " + num(p.done) + " of " + num(p.expected) + " rows";
        }
      });
      bar.style.width = "100%";
      var url = URL.createObjectURL(res.blob), a = document.createElement("a"); a.href = url; a.download = res.filename; document.body.appendChild(a); a.click(); a.remove();
      setTimeout(function () { URL.revokeObjectURL(url); }, 60000);
      msg.className = "msg ok";
      msg.textContent = "Downloaded " + res.filename + " — " + num(res.rows) + " rows, " + mb(res.blob.size) + ". It holds families’ contact details: store it somewhere private." +
        (res.matched ? "" : " Some records changed while the export was running (" + res.differs.map(function (t) { return (X.catalogByTable()[t] || {}).title || t; }).join(", ") + "); export again for an exact copy.");
      recent(ctx);
    } catch (e) {
      msg.className = "msg err";
      msg.textContent = missing(e) ? "Data export isn’t switched on for this server yet." : X.errorText(e);
      prog.hidden = true;
    } finally {
      window.removeEventListener("beforeunload", warn); go.disabled = false; var f = ctx.el.querySelector("#ex-full"); if (f) f.disabled = false; busy = false;
    }
  }

  window.OrgExport = { render: render };
})();
