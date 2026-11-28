// Import page (T33 I0 + I1): templates, file pickers, the check report, the summary, the database check, Import now, Undo and History.
// Used by the wizard step 9 and Settings > Import (org.js mounts it for the OWNER only, with the organisation id).
// The files are read with File.text() and kept in memory only. Nothing is sent until the owner presses Import now: before that the
// page asks the database to CHECK the checked rows (import_dry_run: writes nothing), and after that ONE call (import_commit) sends them.
// No cell text is ever logged, stored in the browser or put in an error message. Rules live in import-core.js; the database re-checks all of them.
(function () {
  "use strict";
  var IC = window.ImportCore;
  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }
  var SHOW = 200;                                           // rows of the report shown per file
  var BIG_BYTES = 20 * 1024 * 1024;

  function mount(el, opts) {
    opts = opts || {};
    var files = [];                                         // [{ name, text, key, tooBig }]  (in memory only)
    var result = null, msg = "";
    var srv = { status: "idle", sig: "", res: null };       // the database's own check of what is on screen: idle | checking | ok | errors | failed
    var run = { status: "idle", res: null, lines: [] };     // the commit: idle | running | done | failed | unknown
    var consent = false, hist = null, histErr = "", undo = null;   // undo: { batch, stage: "loading"|"ask"|"running"|"done"|"failed", lines }
    var sb = function () { return window.sb; };
    var q = function (sel) { return el.querySelector(sel); };

    function download(name, text, type) {
      var url = URL.createObjectURL(new Blob([text], { type: type || "text/csv;charset=utf-8" }));
      var a = document.createElement("a"); a.href = url; a.download = name; document.body.appendChild(a); a.click();
      setTimeout(function () { document.body.removeChild(a); URL.revokeObjectURL(url); }, 0);
    }
    function say(t, bad) { msg = t; var m = q("#imp-msg"); if (m) { m.textContent = t; m.className = "msg " + (bad ? "err" : "ok"); } }

    // ---------------------------------------------------------------- 1. templates
    function templatesHtml() {
      return '<h3>1. Get the templates</h3><p class="imp-sub">Fill them in from your own sheets. The grey example row starts with # and is ignored. Columns can be in any order.</p>' +
        '<div class="imp-list">' + IC.FILE_ORDER.map(function (k) {
          var f = IC.FILES[k], later = f.stage === "later";
          return '<div class="imp-file' + (later ? " imp-later" : "") + '"><div class="imp-file-h"><div class="grow"><b>' + esc(f.file) + '</b> <span class="imp-tag">' + (later ? "Later" : f.stage === "B" ? "Money, can follow" : "First import") + "</span>" +
            '<div class="imp-meta">' + esc(f.title) + (later ? " are not part of the first import." : ": " + f.what) + "</div></div>" +
            (later ? "" : '<button class="btn" data-dl="' + k + '" aria-label="Download ' + esc(f.file) + ' template">Download</button>') + "</div>" +
            (later ? "" : '<details><summary>How to fill it</summary><div class="imp-scroll"><table class="imp-tbl imp-cols"><thead><tr><th scope="col">Column</th><th scope="col">What to write</th><th scope="col">Example</th></tr></thead><tbody>' +
              f.cols.map(function (c) { return "<tr><td data-label=\"Column\"><code>" + esc(c.name) + "</code>" + (c.req ? ' <span class="imp-req">required</span>' : "") + '</td><td data-label="What to write">' + esc(c.rule) + '</td><td data-label="Example">' + esc(c.ex.replace(/^#/, "")) + "</td></tr>"; }).join("") +
              "</tbody></table></div></details>") + "</div>";
        }).join("") + "</div>" +
        '<p style="margin:10px 0 0"><button class="btn" id="imp-readme">Download the how-to (README)</button></p>';
    }

    // ---------------------------------------------------------------- 2. upload
    function uploadHtml() {
      return '<h3>2. Add your files</h3><p class="imp-sub">Choose all your files at once. Each one is recognised by its first row, not by its name. Add a corrected file again and it replaces the old one.</p>' +
        '<label class="imp-drop" id="imp-drop"><input type="file" id="imp-pick" multiple accept=".csv,text/csv,text/plain"><span class="btn">Choose files</span><span class="imp-meta">or drop them here</span></label>' +
        '<p class="imp-priv">Your files stay in this browser tab and are never saved. Nothing is sent to TutorDeck until you press Import now, and closing the page forgets them.</p>' +
        '<div class="imp-chips" id="imp-chips"></div><p class="msg" id="imp-msg" role="status" aria-live="polite"></p>';
    }
    function chipsHtml() {
      if (!files.length) return "";
      return files.map(function (f, i) {
        var info = result && result.files.filter(function (x) { return x.name === f.name; })[0] || {};
        var what = info.key ? IC.FILES[info.key].title : "not recognised";
        return '<span class="imp-chip' + (info.key ? "" : " bad") + '"><span><b>' + esc(f.name) + "</b> · " + esc(what) + (info.key && info.status !== "later" ? " · " + (info.rows || 0).toLocaleString("en-SG") + " rows" : "") + '</span><button class="imp-x" data-rm="' + i + '" aria-label="Remove ' + esc(f.name) + '">×</button></span>';
      }).join("");
    }

    // ---------------------------------------------------------------- 3. report
    function reportHtml() {
      if (!files.length) return "";
      var h = '<h3>3. Check</h3>';
      var all = result.errors.concat(result.warnings), nE = result.errors.length, nW = result.warnings.length;
      if (nE) h += '<p class="imp-status bad" role="status"><b>' + nE + (nE === 1 ? " problem" : " problems") + "</b> to fix before you can import" + (nW ? ", and " + nW + (nW === 1 ? " warning" : " warnings") : "") + ". Fix them in your file, then add the corrected file again.</p>";
      else if (result.missing.length) h += '<p class="imp-status" role="status">No problems so far. Add ' + result.missing.map(function (k) { return "<b>" + esc(IC.FILES[k].file) + "</b>"; }).join(", ") + " to see the summary.</p>";
      else h += '<p class="imp-status ok" role="status"><b>All files pass.</b>' + (nW ? " " + nW + (nW === 1 ? " warning" : " warnings") + " for you to read below." : "") + "</p>";
      if (all.length) h += '<p class="imp-actions"><button class="btn" id="imp-copy">Copy errors</button> <button class="btn" id="imp-csv">Download all errors (CSV)</button></p>' +
        '<p class="imp-help" style="margin-top:-4px">The download holds names from your files: save it on your own computer and delete it when you are done.</p>';
      var groups = {}, order = [];
      result.errors.concat(result.warnings, result.notes).forEach(function (it) { if (!groups[it.file]) { groups[it.file] = []; order.push(it.file); } groups[it.file].push(it); });
      order.forEach(function (name) {
        var items = groups[name], main = items.filter(function (x) { return x.severity !== "note"; }), notes = items.filter(function (x) { return x.severity === "note"; });
        var e = main.filter(function (x) { return x.severity === "error"; }).length, w = main.length - e;
        if (main.length) {
          h += '<section class="imp-group"><h4>' + esc(name) + ' <span class="imp-meta">' + (e ? e + (e === 1 ? " error" : " errors") : "") + (e && w ? ", " : "") + (w ? w + (w === 1 ? " warning" : " warnings") : "") + "</span></h4>" +
            '<div class="imp-scroll"><table class="imp-tbl"><thead><tr><th scope="col">Line</th><th scope="col">Column</th><th scope="col">Value</th><th scope="col">What is wrong</th><th scope="col">How to fix</th></tr></thead><tbody>' +
            main.slice(0, SHOW).map(function (it) {
              return '<tr class="' + it.severity + '"><td data-label="Line">' + esc(it.line) + '</td><td data-label="Column">' + esc(it.column || "–") + '</td><td data-label="Value">' + (it.value === "" ? "–" : "<code>" + esc(it.value) + "</code>") +
                '</td><td data-label="What is wrong"><span class="imp-sev ' + it.severity + '" role="img" aria-label="' + (it.severity === "error" ? "Error" : "Warning") + '" title="' + (it.severity === "error" ? "Error" : "Warning") + '">' + (it.severity === "error" ? "!" : "?") + "</span> " + esc(IC.sentence(it)) + '</td><td data-label="How to fix">' + esc(it.fix) + "</td></tr>";
            }).join("") + "</tbody></table></div>" +
            (main.length > SHOW ? '<p class="imp-help">Showing the first ' + SHOW + " of " + main.length + ". Use Download all errors (CSV) for the rest.</p>" : "") + "</section>";
        }
        if (notes.length) h += '<details class="imp-notes"><summary>' + esc(name) + ": " + notes.length + (notes.length === 1 ? " note" : " notes") + "</summary><ul>" + notes.map(function (n) { return "<li>" + esc(n.message + " " + n.fix) + "</li>"; }).join("") + "</ul></details>";
      });
      return h;
    }

    // ---------------------------------------------------------------- 4. summary, database check, confirm
    function n0(x) { return Number(x || 0).toLocaleString("en-SG"); }
    function fmtDate(iso) { try { return new Date(iso).toLocaleDateString("en-SG", { day: "numeric", month: "short", year: "numeric" }); } catch (e) { return String(iso || ""); } }
    function errText(e) {
      var m = String((e && e.message) || e || "");
      if (/NOT_FOUND/.test(m)) return "Only the owner of this centre can import. Sign in as the owner and try again.";
      return "Could not reach TutorDeck. Check your connection and try again.";
    }
    function backupHtml() {
      var link = window.TL && window.TL.exportHref ? ' <a href="' + esc(window.TL.exportHref) + '">Download your data</a>' : "";
      return '<p class="imp-backup"><b>Download your data first.</b> An import adds records and never changes or deletes anything, and you can undo it for 7 days, but a copy of your data is the safest way to start.' + link + "</p>";
    }
    function billingHtml() {
      var bs = opts.getBillingStart ? opts.getBillingStart() : null;
      return '<p class="imp-help imp-billing">Past lessons are not imported. <b>Billing starts from:</b> ' + (bs ? esc(fmtDate(bs + "T00:00:00")) : "not set, so every lesson can be billed") +
        '. ' + (opts.goBilling ? '<button class="og-link" id="imp-bill">Change it in step 4</button>' : "Change it in the billing step.") + "</p>";
    }
    function summaryHtml() {
      if (!result || !result.ready) return "";
      var s = result.summary, hrs = Math.round(s.weekly_minutes / 6) / 10;
      var rows = [
        [n0(s.students) + (s.students === 1 ? " student" : " students"), "in " + n0(s.families) + (s.families === 1 ? " family" : " families") + " (" + n0(s.guardians) + " guardians)"],
        [n0(s.tutors) + (s.tutors === 1 ? " tutor" : " tutors"), n0(s.invitations) + " invitations saved, " + s.emails_sent + " emails sent"],
        [n0(s.weekly_lessons) + " weekly lessons", hrs.toLocaleString("en-SG") + " lesson hours a week"]
      ];
      var money = result.files.some(function (f) { return f.key === "deposits" || f.key === "unpaid_invoices"; });
      if (result.files.some(function (f) { return f.key === "deposits"; })) rows.push([n0(s.deposits) + (s.deposits === 1 ? " deposit" : " deposits"), "totalling " + IC.fmtMoney(s.deposits_cents) + " (checked, not imported yet)"]);
      if (result.files.some(function (f) { return f.key === "unpaid_invoices"; })) rows.push([n0(s.invoices) + (s.invoices === 1 ? " unpaid invoice" : " unpaid invoices"), IC.fmtMoney(s.invoices_owed_cents) + " still owed (" + IC.fmtMoney(s.invoices_cents) + " in total, " + IC.fmtMoney(s.invoices_paid_cents) + " already paid; checked, not imported yet)"]);
      var h = '<h3>4. Summary</h3><p class="imp-sub">Tick these numbers against your own sheets.</p>' +
        '<table class="imp-sum"><tbody>' + rows.map(function (r) { return "<tr><th scope=\"row\">" + esc(r[0]) + "</th><td>" + esc(r[1]) + "</td></tr>"; }).join("") + "</tbody></table>" +
        (money ? '<p class="imp-help">Deposits and unpaid invoices are checked but are not imported yet. They come in a later step, so nothing about them is saved now.</p>' : "") +
        (result.warnings.length ? '<p class="imp-help">' + result.warnings.length + (result.warnings.length === 1 ? " warning" : " warnings") + " above will not stop the import.</p>" : "") +
        srvHtml();
      if (srv.status === "ok" && run.status !== "done") {
        var c = srv.res.created, k = srv.res.skipped, nothing = !(c.students || c.tutors || c.weekly_lessons || c.guardians);
        h += backupHtml() + billingHtml() +
          '<label class="og-check imp-consent"><input type="checkbox" id="imp-consent"' + (consent ? " checked" : "") + '> <span>I confirm that this centre may give TutorDeck this personal data (names, phone numbers and emails of families and tutors) to keep on its behalf.</span></label>' +
          '<p class="imp-go"><button class="btn btn-primary" id="imp-go"' + (consent && run.status !== "running" && !nothing ? "" : " disabled") + ' aria-describedby="imp-go-why">' + (run.status === "running" ? "Importing…" : "Import now") + "</button> " +
          '<span class="imp-meta" id="imp-go-why">' + (nothing ? "Nothing new to import." : consent ? "No email is sent. You can undo it for 7 days." : "Tick the box above to continue.") + "</span></p>";
      }
      return h;
    }
    function srvHtml() {
      if (srv.status === "checking") return '<p class="imp-status" role="status">Checking your rows with TutorDeck…</p>';
      if (srv.status === "failed") return '<p class="imp-status bad" role="alert">' + esc(srv.text) + ' <button class="btn" id="imp-recheck">Try again</button></p>';
      if (srv.status === "errors") {
        var errs = srv.res.errors.map(IC.serverIssue);
        return '<p class="imp-status bad" role="alert"><b>TutorDeck found ' + (srv.res.error_count === 1 ? "1 problem" : n0(srv.res.error_count) + " problems") + "</b> that your files could not show, usually something that is already in TutorDeck. Fix them and add the corrected file again.</p>" +
          '<div class="imp-scroll"><table class="imp-tbl"><thead><tr><th scope="col">File</th><th scope="col">Line</th><th scope="col">Column</th><th scope="col">What is wrong</th><th scope="col">How to fix</th></tr></thead><tbody>' +
          errs.map(function (it) { return '<tr class="error"><td data-label="File">' + esc(it.file) + '</td><td data-label="Line">' + esc(it.line || "–") + '</td><td data-label="Column">' + esc(it.column || "–") + '</td><td data-label="What is wrong"><span class="imp-sev error">Error</span> ' + esc(it.message) + '</td><td data-label="How to fix">' + esc(it.fix) + "</td></tr>"; }).join("") + "</tbody></table></div>";
      }
      if (srv.status === "ok") {
        var c = srv.res.created, k = srv.res.skipped, skipped = (k.students || 0) + (k.tutors || 0) + (k.weekly_lessons || 0);
        return '<p class="imp-status ok" role="status"><b>TutorDeck has checked everything.</b> ' + (c.students || c.tutors || c.weekly_lessons ? "It will add " + n0(c.students) + " students, " + n0(c.tutors) + " tutor invitations and " + n0(c.weekly_lessons) + " weekly lessons." : "Nothing new would be added.") +
          (skipped ? " " + n0(skipped) + " rows are already in TutorDeck and will be left as they are." : "") +
          ((srv.res.warnings || []).length ? " " + srv.res.warnings.length + (srv.res.warnings.length === 1 ? " row differs" : " rows differ") + " from what is in TutorDeck and will not be changed." : "") + "</p>";
      }
      return "";
    }
    function doneHtml() {
      if (run.status === "failed") return '<h3>Import</h3><p class="imp-status bad" role="alert">' + esc(run.text) + "</p>";
      if (run.status === "unknown") return '<h3>Import</h3><p class="imp-status bad" role="alert">' + esc(run.text) + "</p>";
      if (run.status !== "done") return "";
      var r = run.res;
      return '<h3>5. Done</h3><div class="imp-status ok" role="status"><ul class="imp-lines">' + run.lines.map(function (l) { return "<li>" + esc(l) + "</li>"; }).join("") + "</ul>" +
        (r.batch_id ? '<p class="imp-help">You can undo this import until ' + esc(fmtDate(r.undo_until)) + ".</p>" : "") + "</div>" +
        '<p class="imp-help">Next: invite your tutors from Users when you are ready (nothing is sent until you do), then create lessons from the weekly lessons.</p>';
    }

    // ---------------------------------------------------------------- history and undo
    function histHtml() {
      if (histErr) return '<h3>Earlier imports</h3><p class="imp-help">' + esc(histErr) + "</p>";
      if (!hist || !hist.length) return "";
      var h = '<h3>Earlier imports</h3><div class="imp-scroll"><table class="imp-tbl imp-hist"><thead><tr><th scope="col">Date</th><th scope="col">Added</th><th scope="col">Status</th><th scope="col"><span class="sr-only">Action</span></th></tr></thead><tbody>';
      hist.forEach(function (b) {
        var c = (b.counts && b.counts.created) || {};
        var st = b.status === "undone" ? "Undone" : b.status === "partly_undone" ? "Partly undone" : "Imported";
        var act = b.can_undo ? '<button class="btn" data-undo="' + esc(b.id) + '">Undo</button>' : (b.status === "committed" ? '<span class="imp-meta">Undo ended</span>' : "");
        h += "<tr><td data-label=\"Date\">" + esc(fmtDate(b.created_at)) + '</td><td data-label="Added">' + n0(c.students) + " students, " + n0(c.tutors) + " tutors, " + n0(c.weekly_lessons) + ' weekly lessons</td><td data-label="Status">' + st + '</td><td data-label="">' + act + "</td></tr>";
        if (undo && undo.batch === b.id) h += '<tr><td colspan="4">' + undoPanel() + "</td></tr>";
      });
      return h + "</tbody></table></div>";
    }
    function undoPanel() {
      if (undo.stage === "loading") return '<p class="imp-status" role="status">Checking what can be undone…</p>';
      if (undo.stage === "failed") return '<p class="imp-status bad" role="alert">' + esc(undo.text) + "</p>";
      var ul = '<ul class="imp-lines">' + undo.lines.map(function (l) { return "<li>" + esc(l) + "</li>"; }).join("") + "</ul>";
      if (undo.stage === "done") return '<div class="imp-status ok" role="status">' + ul + "</div>";
      return '<div class="imp-status">' + ul + '<p class="imp-help">Anything that people have edited, marked or invoiced since the import is never removed.</p>' +
        '<p class="imp-actions"><button class="btn" id="imp-undo-go"' + (undo.stage === "running" ? " disabled" : "") + ">" + (undo.stage === "running" ? "Undoing…" : "Undo this import") + '</button> <button class="btn" id="imp-undo-no">Keep it</button></p></div>';
    }
    function loadHist() {
      if (!opts.orgId || !sb()) return;
      sb().rpc("import_history", { p_org: opts.orgId }).then(function (r) {
        if (r.error) { histErr = /NOT_FOUND/.test(r.error.message || "") ? "" : "Earlier imports could not be loaded."; hist = null; }
        else { hist = r.data || []; histErr = ""; }
        paintHist();
      }, function () { histErr = "Earlier imports could not be loaded."; paintHist(); });
    }
    function paintHist() {
      var box = q("#imp-hist"); if (!box) return;
      box.innerHTML = histHtml();
      box.querySelectorAll("[data-undo]").forEach(function (b) { b.onclick = function () { startUndo(b.getAttribute("data-undo")); }; });
      var go = q("#imp-undo-go"), no = q("#imp-undo-no");
      if (go) go.onclick = confirmUndo; if (no) no.onclick = function () { undo = null; paintHist(); };
    }
    function startUndo(id) {
      undo = { batch: id, stage: "loading", lines: [] }; paintHist();
      sb().rpc("import_undo_preview", { p_batch: id }).then(function (r) {
        if (r.error || !r.data) { undo = { batch: id, stage: "failed", text: errText(r.error) }; }
        else if (!r.data.ok) { undo = { batch: id, stage: "failed", text: r.data.code === "UNDO_EXPIRED" ? "The 7 days to undo this import are over." : "This import has already been undone." }; }
        else undo = { batch: id, stage: "ask", lines: IC.undoLines(r.data, true) };
        paintHist();
      }, function (e) { undo = { batch: id, stage: "failed", text: errText(e) }; paintHist(); });
    }
    function confirmUndo() {
      if (!undo || undo.stage !== "ask") return;
      var id = undo.batch; undo.stage = "running"; paintHist();
      sb().rpc("import_undo", { p_batch: id }).then(function (r) {
        if (r.error || !r.data || !r.data.ok) undo = { batch: id, stage: "failed", text: r.error ? errText(r.error) : "This import can no longer be undone." };
        else undo = { batch: id, stage: "done", lines: IC.undoLines(r.data, false) };
        paintHist(); refreshHist();
      }, function (e) { undo = { batch: id, stage: "failed", text: errText(e) }; paintHist(); });
    }
    function refreshHist() {                                  // reload the list but keep the undo report on screen
      sb().rpc("import_history", { p_org: opts.orgId }).then(function (r) { if (!r.error) hist = r.data || []; paintHist(); }, function () {});
    }

    // ---------------------------------------------------------------- the database's own check, then the commit
    function sigOf(p) { return JSON.stringify(p); }
    function serverCheck() {
      if (!opts.orgId || !sb() || !result || !result.ready) { srv = { status: "idle", sig: "", res: null }; return; }
      var sig = sigOf(result.payload);
      if (sig === srv.sig && srv.status !== "failed") return;               // same rows as already checked
      srv = { status: "checking", sig: sig, res: null };
      sb().rpc("import_dry_run", { p_org: opts.orgId, p_payload: result.payload }).then(function (r) {
        if (srv.sig !== sig) return;                                         // files changed meanwhile
        if (r.error || !r.data) srv = { status: "failed", sig: sig, text: errText(r.error) };
        else srv = { status: r.data.ok ? "ok" : "errors", sig: sig, res: r.data };
        paintOut();
      }, function (e) { if (srv.sig === sig) { srv = { status: "failed", sig: sig, text: errText(e) }; paintOut(); } });
    }
    function sha256(text) {
      if (!(window.crypto && crypto.subtle && window.TextEncoder)) return Promise.resolve("");
      return crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)).then(function (b) { return Array.prototype.map.call(new Uint8Array(b), function (x) { return ("0" + x.toString(16)).slice(-2); }).join(""); }, function () { return ""; });
    }
    function commit() {
      if (run.status === "running" || srv.status !== "ok" || !consent) return;
      run = { status: "running", res: null, lines: [] }; paintOut();
      var names = files.filter(function (f) { return IC.STAGE_A.indexOf(f.key) >= 0; });
      Promise.all(names.map(function (f) { return sha256(f.text).then(function (h) { return [IC.FILES[f.key].file, h]; }); })).then(function (pairs) {
        var hashes = {}; pairs.forEach(function (x) { if (x[1]) hashes[x[0]] = x[1]; });
        return sb().rpc("import_commit", { p_org: opts.orgId, p_payload: result.payload, p_hashes: hashes });
      }).then(function (r) {
        if (r.error) { run = { status: "failed", text: errText(r.error) + " Nothing was imported." }; }
        else if (!r.data || !r.data.ok) { srv = { status: "errors", sig: srv.sig, res: r.data || { errors: [], error_count: 0 } }; run = { status: "idle", res: null, lines: [] }; }
        else {
          run = { status: "done", res: r.data, lines: IC.resultLines(r.data) };
          files = []; result = null; srv = { status: "idle", sig: "", res: null }; consent = false; msg = "";        // the files are not needed any more: forget them
          loadHist();
        }
        render();
      }, function () {
        run = { status: "unknown", text: "We could not confirm whether the import went through. Look at Earlier imports below before you try again. Trying again is safe: nothing is ever added twice." };
        render(); loadHist();
      });
    }

    // ---------------------------------------------------------------- render and events
    function render() {
      result = files.length ? IC.validateFiles(files.map(function (f) { return { name: f.name, text: f.text, tooBig: f.tooBig }; })) : null;
      if (run.status === "done" && files.length) run = { status: "idle", res: null, lines: [] };      // new files start a new import
      if (!files.length) srv = run.status === "done" ? srv : { status: "idle", sig: "", res: null };
      serverCheck();
      q("#imp-chips").innerHTML = chipsHtml();
      paintOut();
    }
    function paintOut() {
      q("#imp-out").innerHTML = (files.length ? reportHtml() + summaryHtml() : "") + doneHtml();
      var m = q("#imp-msg"); m.textContent = msg;
      bindOut();
    }
    function bindOut() {
      el.querySelectorAll("[data-rm]").forEach(function (b) { b.onclick = function () { var f = files.splice(+b.getAttribute("data-rm"), 1)[0]; msg = "Removed " + f.name + "."; render(); }; });
      var c = q("#imp-copy"), d = q("#imp-csv");
      if (c) c.onclick = function () {
        var items = result.errors.concat(result.warnings), text = items.map(IC.describe).join("\n");
        function done(ok) { say(ok ? "Copied " + items.length + (items.length === 1 ? " item" : " items") + " to the clipboard." : "Could not copy. Use Download all errors (CSV) instead.", !ok); }
        if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(function () { done(true); }, function () { fallbackCopy(text, done); });
        else fallbackCopy(text, done);
      };
      if (d) d.onclick = function () { download("import-errors.csv", IC.errorsCsv(result.errors.concat(result.warnings))); say("Saved import-errors.csv. It holds values from your files, so delete it when you are done."); };
      var cb = q("#imp-consent"), go = q("#imp-go"), rc = q("#imp-recheck"), bl = q("#imp-bill");
      if (cb) cb.onchange = function () { consent = cb.checked; if (go) go.disabled = !(consent && run.status !== "running"); var w = q("#imp-go-why"); if (w) w.textContent = consent ? "No email is sent. You can undo it for 7 days." : "Tick the box above to continue."; };
      if (go) go.onclick = commit;
      if (rc) rc.onclick = function () { srv.sig = ""; serverCheck(); paintOut(); };
      if (bl && opts.goBilling) bl.onclick = opts.goBilling;
    }

    function fallbackCopy(text, done) {
      var t = document.createElement("textarea"); t.value = text; t.setAttribute("readonly", ""); t.style.position = "fixed"; t.style.opacity = "0"; document.body.appendChild(t); t.select();
      var ok = false; try { ok = document.execCommand("copy"); } catch (e) {} document.body.removeChild(t); done(ok);
    }

    function addFiles(list) {
      var arr = Array.prototype.slice.call(list || []); if (!arr.length) return;
      var notes = [];
      Promise.all(arr.map(function (f) {
        if (f.size > BIG_BYTES) return Promise.resolve({ name: f.name, text: "", tooBig: true, key: null });
        return f.text().then(function (t) { return { name: f.name, text: t, key: IC.detectText(t) }; });
      })).then(function (read) {
        read.forEach(function (nf) {
          var i = -1;
          files.forEach(function (o, j) { if (i < 0 && (o.name === nf.name || (nf.key && o.key === nf.key))) i = j; });
          if (i >= 0) { notes.push((files[i].name === nf.name ? "Replaced " : "Replaced " + files[i].name + " with ") + nf.name); files[i] = nf; } else files.push(nf);
        });
        msg = notes.length ? notes.join(". ") + "." : "";
        render();
      }, function () { msg = "Could not read one of the files."; render(); });
    }

    el.innerHTML = '<div class="imp">' + templatesHtml() + uploadHtml() + '<div id="imp-out"></div><div id="imp-hist"></div></div>';
    el.querySelectorAll("[data-dl]").forEach(function (b) { b.onclick = function () { var k = b.getAttribute("data-dl"); download(IC.FILES[k].file, IC.templateCsv(k)); }; });
    q("#imp-readme").onclick = function () { download("TutorDeck-import-README.txt", "﻿" + IC.readmeText(), "text/plain;charset=utf-8"); };
    var pick = q("#imp-pick"), drop = q("#imp-drop");
    pick.onchange = function () { addFiles(pick.files); pick.value = ""; };
    ["dragenter", "dragover"].forEach(function (ev) { drop.addEventListener(ev, function (e) { e.preventDefault(); drop.classList.add("over"); }); });
    ["dragleave", "drop"].forEach(function (ev) { drop.addEventListener(ev, function (e) { e.preventDefault(); drop.classList.remove("over"); }); });
    drop.addEventListener("drop", function (e) { addFiles(e.dataTransfer && e.dataTransfer.files); });
    loadHist();
  }

  window.ImportPage = { mount: mount };
})();
