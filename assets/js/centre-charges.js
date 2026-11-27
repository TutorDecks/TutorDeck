// Centre Charges (T3 step 4): the second tab of the Attendance page. Absent / cancelled lessons wait here until someone with the "issue invoices"
// permission confirms what the family is charged (0 = not charged). Every read and write goes through database functions
// (staff_pending_charges, staff_set_charge, staff_set_charges); this page never touches a table. Who may, 0..price and the audit entry are decided
// there (db/migration_staff_charges.sql); assets/js/centre-charges-core.js only words the answers and saves a round trip.
// A person who isn't allowed gets NOT_ALLOWED on the very first call: the tab then never appears.
//   centre-attendance?id=<centre>&tab=charges
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var esc = function (s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var CG = window.CentreChargesCore, CA = window.CentreAttendanceCore;
  var orgId = null, enabled = false, active = false, res = null, page = 1, picked = {}, cur = null, seq = 0, opener = null, wired = false;

  function say(id, t) { $(id).textContent = t || ""; }
  function plural(n, a, b) { return n === 1 ? a : b; }
  function today() { return (res && res.today) || new Date().toISOString().slice(0, 10); }
  function find(id) { var rows = (res && res.rows) || []; for (var i = 0; i < rows.length; i++) if (rows[i].lesson_id === id) return rows[i]; return null; }

  // ---------------------------------------------------------------- the tabs (shared with the Lessons tab)
  function badge() {
    var n = res ? res.total : 0;
    $("cg-badge").textContent = n ? String(n) : "";
    $("cg-badge").hidden = !n;
    $("ca-tab-charges").setAttribute("aria-label", "Charges" + (n ? ", " + n + " waiting" : ""));
  }
  function tabs() {
    $("ca-tabs").querySelectorAll("[data-t]").forEach(function (b) { if (b.dataset.t === "makeups") return; var on = (b.dataset.t === "charges") === active; b.classList.toggle("on", on); b.setAttribute("aria-pressed", on); });   // the Make-ups tab (centre-credits.js) manages itself
    $("ca").hidden = active; $("cg").hidden = !active;
    try { var u = new URL(location.href); if (active) u.searchParams.set("tab", "charges"); else u.searchParams.delete("tab"); history.replaceState(null, "", u); } catch (e) {}
  }
  function show() { if (!enabled) return; active = true; tabs(); load(); }
  function hide() { active = false; tabs(); }

  // ---------------------------------------------------------------- the queue
  function rowHtml(r) {
    var sug = CG.suggestion(r);
    return '<div class="cg-row"><label class="cg-pick"><input type="checkbox" data-pick="' + esc(r.lesson_id) + '"' + (picked[r.lesson_id] ? " checked" : "") +
      ' aria-label="Select ' + esc(r.student_name) + '"></label>' +
      '<button type="button" class="cg-open" data-id="' + esc(r.lesson_id) + '">' +
      '<span class="ca-main"><span class="ca-name">' + esc(r.student_name) + (r.student_level ? ' · ' + esc(r.student_level) : '') + '</span>' +
      '<span class="ca-sub">' + esc(CG.whenLine(r, today())) + (r.tutor_name ? ' · ' + esc(r.tutor_name) : '') + '</span></span>' +
      '<span class="cg-amt"><span class="ca-chip muted">' + esc(CG.markShort(r.attendance)) + '</span>' +
      '<span class="cg-price">' + esc(CG.fmt(r.price_cents)) + '</span>' + (sug ? '<span class="cg-sug">' + esc(sug) + '</span>' : '') + '</span>' +
      '<svg class="ca-chev" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="m9 18 6-6-6-6"/></svg></button></div>';
  }
  function bulkBar() {
    var b = CG.bulk(res ? res.rows : [], picked, "full"), n = b.count;
    $("cg-bulk").hidden = !n;
    $("cg-sel").textContent = n + " " + plural(n, "lesson", "lessons") + " selected";
    var all = (res && res.rows || []).length > 0 && n === res.rows.length;
    $("cg-all").checked = all; $("cg-all").indeterminate = n > 0 && !all;
  }
  function draw() {
    if (!res) return;
    badge();
    var rows = res.rows || [], total = res.total || 0, pages = CA.pageCount(total, res.size);
    if (res.page > pages && total) { page = pages; return load(); }
    Object.keys(picked).forEach(function (id) { if (!find(id)) delete picked[id]; });          // a lesson that left the queue can't stay ticked
    $("cg-tools").hidden = !rows.length;
    if (!rows.length) {
      var e = CG.emptyText();
      $("cg-list").innerHTML = '<div class="card"><div class="ca-empty"><h3>' + esc(e.title) + '</h3><p>' + esc(e.hint) + '</p></div></div>';
    } else {
      $("cg-list").innerHTML = '<div class="card ca-list cg-rows">' + rows.map(rowHtml).join("") + '</div>';
    }
    $("cg-count").textContent = total ? total + " " + plural(total, "charge", "charges") + " to confirm" : "";
    $("cg-pager").hidden = total <= res.size;
    $("cg-pl").textContent = CA.pagerLabel(res.page, res.size, total);
    $("cg-pp").disabled = res.page <= 1; $("cg-pn").disabled = res.page >= pages;
    bulkBar();
  }
  async function load() {
    var mine = ++seq;
    var r = await window.sb.rpc("staff_pending_charges", { p_org: orgId, p_page: page, p_size: CG.PAGE_SIZE });
    if (mine !== seq) return;
    if (r.error) { $("cg-count").textContent = CG.errorText(r.error); return; }
    if (!r.data || !Array.isArray(r.data.rows)) { $("cg-count").textContent = "Couldn’t load the charges. Refresh and try again."; return; }
    res = r.data; draw();
  }

  // ---------------------------------------------------------------- the sheet: one lesson's charge
  function lockBody(on) { document.body.classList.toggle("sheet-lock", on); }
  function openSheet(trigger) { opener = trigger || opener; $("cg-sheet").classList.add("on"); lockBody(true); $("cg-amt").focus(); $("cg-amt").select(); }
  function closeSheet() { $("cg-sheet").classList.remove("on"); lockBody(false); cur = null; if (opener && opener.focus && document.contains(opener)) opener.focus(); opener = null; }
  function renderSheet() {
    var r = cur, rule = CG.ruleText(r.suggestion_mode), sug = r.suggested_cents;
    $("cg-st").textContent = r.student_name;
    $("cg-sm").textContent = CG.whenLine(r, today());
    $("cg-facts").innerHTML = '<div><span>Marked</span><span>' + esc(CG.markLabel(r.attendance)) + (r.marked_by_name ? ' by ' + esc(r.marked_by_name) : '') + '</span></div>' +
      (r.tutor_name ? '<div><span>Tutor</span><span>' + esc(r.tutor_name) + '</span></div>' : '') +
      (r.subject ? '<div><span>Subject</span><span>' + esc(r.subject) + '</span></div>' : '') +
      '<div><span>Lesson price</span><span>' + esc(CG.fmt(r.price_cents)) + '</span></div>' +
      (r.remarks ? '<div><span>Remarks</span><span>' + esc(r.remarks) + '</span></div>' : '');
    $("cg-rule").textContent = sug == null ? "Nothing is suggested for this lesson. Enter the charge, or 0 if the family isn’t charged."
      : (rule ? rule + " " : "") + (sug === 0 ? "Suggested: not charged." : "Suggested: " + CG.fmt(sug) + ".") + " You decide.";
    $("cg-amt").value = sug == null ? "" : CG.plain(sug);
    $("cg-hint").textContent = "From " + CG.fmt(0) + " up to " + CG.fmt(r.price_cents) + ".";
    $("cg-zero").textContent = "Not charged (" + CG.fmt(0) + ")";
    $("cg-full").textContent = "Full price (" + CG.fmt(r.price_cents) + ")";
    say("cg-err", "");
  }
  function open(id, trigger) { var r = find(id); if (!r) return; cur = r; renderSheet(); openSheet(trigger); }
  function busy(on) { document.querySelectorAll("#cg-sheet button, #cg-sheet input, #cg-bulk button").forEach(function (b) { b.disabled = on; }); }
  async function save() {
    var chk = CG.parseCharge($("cg-amt").value, cur.price_cents);
    if (!chk.ok) { say("cg-err", chk.error); return; }
    say("cg-err", ""); busy(true);
    var name = cur.student_name, id = cur.lesson_id;
    var r = await window.sb.rpc("staff_set_charge", { p_lesson: id, p_amount_cents: chk.cents, p_reason: null });
    busy(false);
    if (r.error) {
      var m = r.error.message || "";
      if (/REASON_REQUIRED|NO_CHANGE|NOT_FOUND|NOT_CANCELLED/.test(m)) { say("cg-err", "Someone else has just set this charge. The list has been refreshed."); load(); return; }
      say("cg-err", CG.errorText(r.error)); return;
    }
    TL.toast(name + ": " + (chk.cents === 0 ? "not charged" : CG.fmt(chk.cents) + " charged") + " confirmed", "ok");
    closeSheet(); await load();
  }

  // ---------------------------------------------------------------- many at once
  async function doBulk(mode) {
    var b = CG.bulk(res.rows, picked, mode);
    if (!b.count) return;
    if (b.tooMany) { TL.toast("Choose up to " + CG.BULK_MAX + " lessons at a time.", "err"); return; }
    var q = CG.bulkQuestion(b, mode);
    var yes = await TL.confirm({ title: q.title, message: q.message, confirmText: "Confirm" });
    if (!yes) return;
    busy(true);
    var r = await window.sb.rpc("staff_set_charges", { p_lessons: b.ids, p_mode: mode === "full" ? "full" : "amount", p_amount_cents: mode === "full" ? null : 0 });
    busy(false);
    if (r.error) { TL.toast(CG.errorText(r.error), "err"); if (/ALREADY_SET|NOT_FOUND|NOT_CANCELLED/.test(r.error.message || "")) load(); return; }
    var n = (r.data && r.data.updated) || b.count;
    TL.toast(n + " " + plural(n, "charge", "charges") + " confirmed", "ok");
    picked = {}; await load();
  }

  // ---------------------------------------------------------------- wiring
  function wire() {
    if (wired) return; wired = true;
    $("ca-tabs").addEventListener("click", function (e) { var b = e.target.closest("[data-t]"); if (!b) return; if (b.dataset.t === "charges") show(); else if (b.dataset.t === "lessons") hide(); });
    $("cg-list").addEventListener("click", function (e) { var b = e.target.closest(".cg-open"); if (b) open(b.dataset.id, b); });
    $("cg-list").addEventListener("change", function (e) {
      var c = e.target.closest("[data-pick]"); if (!c) return;
      if (c.checked) picked[c.dataset.pick] = true; else delete picked[c.dataset.pick];
      bulkBar();
    });
    $("cg-all").addEventListener("change", function () {
      picked = {}; if ($("cg-all").checked) (res.rows || []).forEach(function (r) { picked[r.lesson_id] = true; });
      document.querySelectorAll("#cg-list [data-pick]").forEach(function (c) { c.checked = !!picked[c.dataset.pick]; });
      bulkBar();
    });
    $("cg-bzero").addEventListener("click", function () { doBulk("zero"); });
    $("cg-bfull").addEventListener("click", function () { doBulk("full"); });
    $("cg-bclear").addEventListener("click", function () { picked = {}; document.querySelectorAll("#cg-list [data-pick]").forEach(function (c) { c.checked = false; }); bulkBar(); });
    $("cg-pp").addEventListener("click", function () { if (page > 1) { page--; load(); window.scrollTo(0, 0); } });
    $("cg-pn").addEventListener("click", function () { page++; load(); window.scrollTo(0, 0); });
    $("cg-sx").addEventListener("click", closeSheet);
    $("cg-sheet").addEventListener("click", function (e) { if (e.target === $("cg-sheet")) closeSheet(); });
    $("cg-zero").addEventListener("click", function () { $("cg-amt").value = CG.plain(0); say("cg-err", ""); $("cg-amt").focus(); });
    $("cg-full").addEventListener("click", function () { $("cg-amt").value = CG.plain(cur.price_cents); say("cg-err", ""); $("cg-amt").focus(); });
    $("cg-save").addEventListener("click", save);
    $("cg-amt").addEventListener("keydown", function (e) { if (e.key === "Enter") { e.preventDefault(); save(); } });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && $("cg-sheet").classList.contains("on")) closeSheet(); });
  }

  // Called once by the Attendance page. Resolves true when this person may see charges (the tab is then shown), false otherwise.
  async function init(id, wantTab) {
    orgId = id;
    var r = await window.sb.rpc("staff_pending_charges", { p_org: id, p_page: 1, p_size: CG.PAGE_SIZE });
    if (r.error || !r.data || !Array.isArray(r.data.rows)) return false;                 // not allowed, not switched on here yet, or any trouble: no tab, nothing else changes
    enabled = true; res = r.data; wire();
    $("ca-tabs").hidden = false; badge();
    if (wantTab === "charges") { active = true; tabs(); draw(); }
    return true;
  }
  window.CentreCharges = { init: init, show: show, hide: hide, enabled: function () { return enabled; } };
})();
