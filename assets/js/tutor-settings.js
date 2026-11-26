// Your settings (centre tutors): profile (name, phone), change password, payout details, plus sign out. All access goes through database
// functions (tutor_my_profile / tutor_save_profile, tutor_my_payout / tutor_save_payout / tutor_clear_payout / tutor_reveal_payout); this page never
// reads or writes a table. Pure checks: assets/js/tutor-settings-core.js. Payout numbers are never logged, never put in a URL, and a revealed value
// is hidden again after 30 seconds or when the page goes to the background.
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


  // ---------------------------------------------------------------- payout details
  var po = [], poCur = null, poTimer = null, poShown = false, poEditing = false;
  function poMethod() { var r = document.querySelector('input[name="po-method"]:checked'); return r ? r.value : "paynow_mobile"; }
  function poHide() { clearTimeout(poTimer); poTimer = null; poShown = false; }
  function poShowValues() {
    if (!poCur || !poCur.has_payout) return;
    var hidden = poCur.method === "bank" ? (poCur.bank_name || "Bank") + "  " + (poCur.masked || "") + "  ·  " + (poCur.holder_hint || "") : (poCur.masked || "");
    $("po-val").textContent = poShown && poCur._full ? C.payoutDisplay(poCur._full) : hidden;
    $("po-show").textContent = poShown ? "Hide" : "Show"; $("po-show").setAttribute("aria-pressed", poShown ? "true" : "false");
  }
  function poFields() {
    var m = poMethod();
    $("po-bank-row").style.display = m === "bank" ? "" : "none"; $("po-holder-row").style.display = m === "bank" ? "" : "none";
    $("po-bank-other").style.display = m === "bank" && $("po-bank").value === "Other" ? "" : "none";
    $("po-value-wrap").classList.toggle("ts-phone", m === "paynow_mobile");
    $("po-value-wrap").firstElementChild.style.display = m === "paynow_mobile" ? "" : "none";
    $("po-value-l").textContent = m === "paynow_mobile" ? "Mobile number" : m === "paynow_uen" ? "UEN" : "Account number";
    $("po-value").placeholder = m === "paynow_mobile" ? "8123 4567" : m === "paynow_uen" ? "53123456K" : "Digits only";
    $("po-value").setAttribute("inputmode", m === "paynow_uen" ? "text" : m === "bank" ? "numeric" : "tel");
    $("po-value-h").textContent = m === "paynow_mobile" ? "The mobile number that is linked to your PayNow." : m === "paynow_uen" ? "The UEN that is linked to your PayNow." : "Numbers only, 7 to 16 digits.";
  }
  function poClearForm() { $("po-value").value = ""; $("po-holder").value = ""; $("po-bank-other").value = ""; $("po-confirm").checked = false; }
  function poRender() {
    var r = poCur; if (!r) return;
    var has = !!r.has_payout;
    $("po-cur").style.display = has ? "" : "none"; $("po-sure").style.display = "none";
    $("po-form").style.display = !has || poEditing ? "" : "none";
    if (has) { $("po-kind").textContent = C.METHODS[r.method] || ""; poShowValues(); }
    poFields();
  }
  async function poLoad() {
    var r = await window.sb.rpc("tutor_my_payout");
    if (r.error) { $("po-card").style.display = ""; $("po-form").style.display = "none"; $("po-cur").style.display = "none"; $("po-load").style.display = ""; $("po-load").className = "msg err"; $("po-load").textContent = "Your payout details aren’t available right now. Please try again in a few minutes."; return; }
    $("po-load").style.display = "none";
    po = r.data || [];
    if (!po.length) { $("po-card").style.display = "none"; return; }
    var keep = poCur && poCur.membership_id;
    $("po-centre").innerHTML = po.map(function (x) { return '<option value="' + x.membership_id + '">' + String(x.org_name || "Centre").replace(/&/g, "&amp;").replace(/</g, "&lt;") + '</option>'; }).join("");
    if (keep && po.some(function (x) { return x.membership_id === keep; })) $("po-centre").value = keep;
    $("po-centre-row").style.display = po.length > 1 ? "" : "none";
    poPick();
    $("po-card").style.display = "";
  }
  function poPick() { var id = $("po-centre").value; poCur = po.filter(function (x) { return x.membership_id === id; })[0] || po[0]; poHide(); poRender(); }

  async function poToggleShow() {
    if (poShown) { poHide(); delete poCur._full; poShowValues(); return; }
    $("po-show").disabled = true;
    var r = await window.sb.rpc("tutor_reveal_payout", { p_membership: poCur.membership_id });
    $("po-show").disabled = false;
    if (r.error || !r.data || !r.data.length) { say("po-msg", C.payoutErrorText(r.error), true); return; }
    poCur._full = r.data[0]; poShown = true; poShowValues();
    clearTimeout(poTimer); poTimer = setTimeout(function () { poHide(); if (poCur) delete poCur._full; poShowValues(); }, 30000);
  }
  async function poSave(e) {
    e.preventDefault();
    var bank = $("po-bank").value === "Other" ? $("po-bank-other").value : $("po-bank").value;
    var v = C.validatePayout({ method: poMethod(), value: $("po-value").value, bank: bank, holder: $("po-holder").value, confirm: $("po-confirm").checked });
    if (!v.ok) { say("po-msg", v.error, true); var f = { value: "po-value", bank: $("po-bank").value === "Other" ? "po-bank-other" : "po-bank", holder: "po-holder", confirm: "po-confirm", method: "po-card" }[v.field]; if ($(f) && $(f).focus) $(f).focus(); return; }
    $("po-save").disabled = true; say("po-msg", "Saving…");
    var args = v.args; args.p_membership = poCur.membership_id;
    var r = await window.sb.rpc("tutor_save_payout", args);
    args = null;
    $("po-save").disabled = false;
    if (r.error) { say("po-msg", C.payoutErrorText(r.error), true); return; }
    poClearForm(); say("po-msg", ""); poEditing = false; poHide(); TL.toast("Payout details saved");
    await poLoad();
  }
  async function poClear() {
    $("po-clear-yes").disabled = true;
    var r = await window.sb.rpc("tutor_clear_payout", { p_membership: poCur.membership_id });
    $("po-clear-yes").disabled = false;
    if (r.error) { say("po-msg", C.payoutErrorText(r.error), true); return; }
    poHide(); poEditing = false; say("po-msg", ""); TL.toast("Payout details cleared");
    await poLoad();
  }
  function poInit() {
    $("po-card").addEventListener("submit", poSave);
    $("po-centre").addEventListener("change", function () { poEditing = false; say("po-msg", ""); poClearForm(); poPick(); });
    Array.prototype.forEach.call(document.querySelectorAll('input[name="po-method"]'), function (x) { x.addEventListener("change", function () { say("po-msg", ""); $("po-value").value = ""; poFields(); }); });
    $("po-bank").innerHTML = '<option value="">Choose your bank</option>' + C.BANKS.map(function (b) { return "<option>" + b.replace(/&/g, "&amp;") + "</option>"; }).join("");
    $("po-bank").addEventListener("change", poFields);
    $("po-show").addEventListener("click", poToggleShow);
    $("po-change").addEventListener("click", function () { poEditing = true; poHide(); say("po-msg", ""); poRender(); $("po-form").querySelector("input[name=po-method]:checked").focus(); });
    $("po-clear").addEventListener("click", function () { $("po-sure").style.display = ""; $("po-clear-no").focus(); });
    $("po-clear-no").addEventListener("click", function () { $("po-sure").style.display = "none"; $("po-clear").focus(); });
    $("po-clear-yes").addEventListener("click", poClear);
    document.addEventListener("visibilitychange", function () { if (document.hidden && poShown && poCur) { poHide(); delete poCur._full; poShowValues(); } });
    poFields();
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
    pwList(); poInit();
    load(); poLoad();
  }
  TL.requireAuth("tutor-settings", init);
})();
