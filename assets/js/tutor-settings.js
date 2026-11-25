// Your settings (centre tutors): profile (name, phone) and change password, plus sign out. All profile access goes through two database
// functions (tutor_my_profile, tutor_save_profile); this page never reads or writes a table. Pure checks: assets/js/tutor-settings-core.js.
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var C = window.TutorSettingsCore, PR = window.PasswordRules, rows = [], cur = null;

  function say(id, t, err) { var m = $(id); m.textContent = t || ""; m.className = "msg" + (t ? (err ? " err" : " ok") : ""); }

  function fill() {
    cur = rows.filter(function (r) { return r.membership_id === ($("tp-centre").value || (cur && cur.membership_id)); })[0] || rows[0];
    $("tp-name").value = cur.display_name || "";
    $("tp-phone").value = C.phoneForEdit(cur.phone);
    $("tp-email").value = cur.email || "";
  }

  async function saveProfile(e) {
    e.preventDefault();
    var np = C.nameProblem($("tp-name").value), ph = C.normalisePhone($("tp-phone").value);
    if (np) { say("tp-msg", np, true); $("tp-name").focus(); return; }
    if (!ph.ok) { say("tp-msg", ph.error, true); $("tp-phone").focus(); return; }
    $("tp-save").disabled = true; say("tp-msg", "Saving…");
    var r = await window.sb.rpc("tutor_save_profile", { p_membership: cur.membership_id, p_name: $("tp-name").value.trim(), p_phone: ph.value || "", p_all_centres: !!($("tp-all-row").style.display !== "none" && $("tp-all").checked) });
    $("tp-save").disabled = false;
    if (r.error) { say("tp-msg", C.errorText(r.error), true); return; }
    say("tp-msg", ""); TL.toast("Saved");
    await load(true);
  }

  function pwList() {
    var el = $("pw-list"), items = PR.checklist($("pw-new").value);
    if (el.children.length !== items.length) el.innerHTML = items.map(function () { return '<li><span class="pw-ico" aria-hidden="true"></span><span class="pw-txt"></span><span class="sr-only"></span></li>'; }).join("");
    items.forEach(function (it, i) { var li = el.children[i]; li.className = it.ok ? "met" : ""; li.children[1].textContent = it.label; li.children[2].textContent = it.ok ? " (done)" : " (not yet)"; });
  }

  async function changePassword(e) {
    e.preventDefault();
    var oldPw = $("pw-old").value, newPw = $("pw-new").value;
    if (!oldPw) { say("pw-msg", "Type your current password first.", true); $("pw-old").focus(); return; }
    var need = PR.problems(newPw);
    if (need.length) { say("pw-msg", "Still needed: " + need.join(", ") + ".", true); Array.prototype.forEach.call($("pw-list").children, function (li) { if (!li.classList.contains("met")) li.classList.add("bad"); }); $("pw-new").focus(); return; }
    if (newPw === oldPw) { say("pw-msg", "Choose a password that is different from your current one.", true); $("pw-new").focus(); return; }
    $("pw-save").disabled = true; say("pw-msg", "Checking…");
    var email = (rows[0] && rows[0].email) || "";
    var chk = await window.sb.auth.signInWithPassword({ email: email, password: oldPw });   // proves it is really you before anything changes
    if (chk.error) { $("pw-save").disabled = false; say("pw-msg", /rate|too many/i.test(chk.error.message || "") ? "Too many tries. Please wait a minute and try again." : "That isn’t your current password.", true); $("pw-old").focus(); return; }
    var u = await window.sb.auth.updateUser({ password: newPw });
    $("pw-save").disabled = false;
    if (u.error) { say("pw-msg", C.weakPasswordText(u.error, PR.MIN) || "We couldn’t change your password just now. Please try again.", true); return; }
    $("pw-old").value = ""; $("pw-new").value = ""; pwList(); say("pw-msg", ""); TL.toast("Password changed");
  }

  async function load(quiet) {
    var r = await window.sb.rpc("tutor_my_profile");
    if (r.error) { $("tp-load").className = "msg err"; $("tp-load").textContent = "Your profile isn’t available right now. Please try again in a few minutes."; return; }
    rows = r.data || [];
    if (!rows.length) { $("tp-load").className = "msg"; $("tp-load").textContent = "You aren’t a tutor at a centre right now, so there is no centre profile to edit."; }
    else $("tp-load").style.display = "none";
    if (!rows.length) { $("ts-out").style.display = ""; return; }
    var keep = cur && cur.membership_id;
    $("tp-centre").innerHTML = rows.map(function (x) { return '<option value="' + x.membership_id + '">' + String(x.org_name || "Centre").replace(/&/g, "&amp;").replace(/</g, "&lt;") + '</option>'; }).join("");
    if (keep && rows.some(function (x) { return x.membership_id === keep; })) $("tp-centre").value = keep;
    $("tp-centre-row").style.display = rows.length > 1 ? "" : "none";
    $("tp-all-row").style.display = rows.length > 1 ? "" : "none";
    fill();
    $("tp-card").style.display = ""; $("pw-card").style.display = ""; $("ts-out").style.display = "";
    $("pw-both").style.display = (TL.roleMode && TL.roleMode() === "both") ? "" : "none";
  }

  function init() {
    $("tp-card").addEventListener("submit", saveProfile);
    $("pw-card").addEventListener("submit", changePassword);
    $("tp-centre").addEventListener("change", function () { say("tp-msg", ""); cur = null; fill(); });
    $("pw-new").addEventListener("input", pwList);
    $("pw-show").addEventListener("change", function () { var t = $("pw-show").checked ? "text" : "password"; $("pw-old").type = t; $("pw-new").type = t; });
    $("ts-out").addEventListener("click", function () { TL.signOut(); });
    pwList();
    load();
  }
  TL.requireAuth("tutor-settings", init);
})();
