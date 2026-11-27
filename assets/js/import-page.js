// Import page (T33 step I0): templates, file pickers, the check report and the summary. Used by the wizard step 9 and Settings > Import
// (org.js mounts it for the OWNER only). Everything happens in this browser tab: the files are read with File.text(), kept in memory
// and never sent, stored or logged. "Import now" is disabled until the next step is built. Rules live in import-core.js.
(function () {
  "use strict";
  var IC = window.ImportCore;
  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }
  var SHOW = 200;                                           // rows of the report shown per file
  var BIG_BYTES = 20 * 1024 * 1024;

  function mount(el) {
    var files = [];                                         // [{ name, text, key, tooBig }]  (in memory only)
    var result = null, msg = "";
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
        '<p class="imp-priv">Your files stay in this browser tab. Nothing is uploaded or saved, and closing the page forgets them.</p>' +
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
                '</td><td data-label="What is wrong"><span class="imp-sev ' + it.severity + '">' + (it.severity === "error" ? "Error" : "Warning") + "</span> " + esc(it.message) + '</td><td data-label="How to fix">' + esc(it.fix) + "</td></tr>";
            }).join("") + "</tbody></table></div>" +
            (main.length > SHOW ? '<p class="imp-help">Showing the first ' + SHOW + " of " + main.length + ". Use Download all errors (CSV) for the rest.</p>" : "") + "</section>";
        }
        if (notes.length) h += '<details class="imp-notes"><summary>' + esc(name) + ": " + notes.length + (notes.length === 1 ? " note" : " notes") + "</summary><ul>" + notes.map(function (n) { return "<li>" + esc(n.message + " " + n.fix) + "</li>"; }).join("") + "</ul></details>";
      });
      return h;
    }

    // ---------------------------------------------------------------- 4. summary
    function summaryHtml() {
      if (!result || !result.ready) return "";
      var s = result.summary, n = function (x) { return x.toLocaleString("en-SG"); }, hrs = Math.round(s.weekly_minutes / 6) / 10;
      var rows = [
        [n(s.students) + (s.students === 1 ? " student" : " students"), "in " + n(s.families) + (s.families === 1 ? " family" : " families") + " (" + n(s.guardians) + " guardians)"],
        [n(s.tutors) + (s.tutors === 1 ? " tutor" : " tutors"), n(s.invitations) + " invitations saved, " + s.emails_sent + " emails sent"],
        [n(s.weekly_lessons) + " weekly lessons", hrs.toLocaleString("en-SG") + " lesson hours a week"]
      ];
      if (result.files.some(function (f) { return f.key === "deposits"; })) rows.push([n(s.deposits) + (s.deposits === 1 ? " deposit" : " deposits"), "totalling " + IC.fmtMoney(s.deposits_cents)]);
      if (result.files.some(function (f) { return f.key === "unpaid_invoices"; })) rows.push([n(s.invoices) + (s.invoices === 1 ? " unpaid invoice" : " unpaid invoices"), IC.fmtMoney(s.invoices_owed_cents) + " still owed (" + IC.fmtMoney(s.invoices_cents) + " in total, " + IC.fmtMoney(s.invoices_paid_cents) + " already paid)"]);
      return '<h3>4. Summary</h3><p class="imp-sub">Tick these numbers against your own sheets. A wrong total usually means a mistyped amount.</p>' +
        '<table class="imp-sum"><tbody>' + rows.map(function (r) { return "<tr><th scope=\"row\">" + esc(r[0]) + "</th><td>" + esc(r[1]) + "</td></tr>"; }).join("") + "</tbody></table>" +
        (result.warnings.length ? '<p class="imp-help">' + result.warnings.length + (result.warnings.length === 1 ? " warning" : " warnings") + " above will not stop the import.</p>" : "") +
        '<p class="imp-go"><button class="btn btn-primary" id="imp-go" disabled aria-describedby="imp-go-why">Import now</button> <span class="imp-meta" id="imp-go-why">Coming in the next step. Nothing has been saved or sent.</span></p>';
    }

    // ---------------------------------------------------------------- render and events
    function render() {
      result = files.length ? IC.validateFiles(files.map(function (f) { return { name: f.name, text: f.text, tooBig: f.tooBig }; })) : null;
      q("#imp-chips").innerHTML = chipsHtml();
      q("#imp-out").innerHTML = files.length ? reportHtml() + summaryHtml() : "";
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

    el.innerHTML = '<div class="imp">' + templatesHtml() + uploadHtml() + '<div id="imp-out"></div></div>';
    el.querySelectorAll("[data-dl]").forEach(function (b) { b.onclick = function () { var k = b.getAttribute("data-dl"); download(IC.FILES[k].file, IC.templateCsv(k)); }; });
    q("#imp-readme").onclick = function () { download("TutorDeck-import-README.txt", "﻿" + IC.readmeText(), "text/plain;charset=utf-8"); };
    var pick = q("#imp-pick"), drop = q("#imp-drop");
    pick.onchange = function () { addFiles(pick.files); pick.value = ""; };
    ["dragenter", "dragover"].forEach(function (ev) { drop.addEventListener(ev, function (e) { e.preventDefault(); drop.classList.add("over"); }); });
    ["dragleave", "drop"].forEach(function (ev) { drop.addEventListener(ev, function (e) { e.preventDefault(); drop.classList.remove("over"); }); });
    drop.addEventListener("drop", function (e) { addFiles(e.dataTransfer && e.dataTransfer.files); });
  }

  window.ImportPage = { mount: mount };
})();
