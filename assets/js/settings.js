// Settings — load and save the tutor's business + PayNow details on their profile.
(function () {
  var userId = null;
  var $ = function (id) { return document.getElementById(id); };

  function preview() {
    var type = $("ptype").value, id = $("pid").value.trim();
    if (!id) { $("preview").textContent = ""; return; }
    $("preview").textContent = "Parents pay to " + PayNow.normalize(type, id);
  }

  async function load() {
    var res = await window.sb.from("profiles")
      .select("business_name,full_name,paynow_type,paynow_id,invoice_prefix,reminder_message,invoice_message,fy_start_month,bank_account_name,bank_name,bank_account_no,bank_swift").eq("id", userId).single();
    if (res.error) { $("s-msg").textContent = "Couldn't load: " + res.error.message; $("s-msg").className = "msg err"; return; }
    var p = res.data || {};
    $("biz").value = p.business_name || "";
    $("fullname").value = p.full_name || "";
    $("ptype").value = p.paynow_type || "mobile";
    $("pid").value = p.paynow_id || "";
    $("prefix").value = p.invoice_prefix || "INV";
    $("bk-name").value = p.bank_account_name || "";
    $("bk-bank").value = p.bank_name || "";
    $("bk-acct").value = p.bank_account_no || "";
    $("bk-swift").value = p.bank_swift || "";
    $("fystart").value = String(p.fy_start_month || 1);
    $("rmsg").value = p.reminder_message || "";
    $("imsg").value = p.invoice_message || "";
    preview();
  }

  async function save() {
    var msg = $("s-msg");
    // Tuition name and PayNow are optional: invoices fall back to your own name, and can use bank transfer instead.
    var biz = $("biz").value.trim(), pid = $("pid").value.trim(), fn = $("fullname").value.trim();
    $("save").disabled = true;
    var res = await window.sb.from("profiles").update({
      full_name: fn || null,
      business_name: biz || null,
      paynow_type: $("ptype").value,
      paynow_id: pid || null,
      invoice_prefix: $("prefix").value.trim() || "INV",
      fy_start_month: parseInt($("fystart").value, 10) || 1,
      reminder_message: $("rmsg").value.trim() || null,
      invoice_message: $("imsg").value.trim() || null,
      bank_account_name: $("bk-name").value.trim() || null,
      bank_name: $("bk-bank").value.trim() || null,
      bank_account_no: $("bk-acct").value.trim() || null,
      bank_swift: $("bk-swift").value.trim() || null
    }).eq("id", userId);
    $("save").disabled = false;
    if (res.error) { msg.textContent = res.error.message; msg.className = "msg err"; return; }
    msg.textContent = "Saved ✓"; msg.className = "msg ok";
    TL.setBrand(biz || "");   // the top bar (and the next page) shows the new name straight away
    TL.setHello(TL.firstName(fn), fn);
  }

  // ---- Two-factor (TOTP) ----
  var enrollId = null;
  function mfaShow(which) {
    ["mfa-loading","mfa-off","mfa-enroll","mfa-on"].forEach(function(id){
      var el=$(id); if(el) el.style.display = (id===which?"block":"none");
    });
  }
  async function refreshMfa() {
    mfaShow("mfa-loading");
    try {
      var r = await window.sb.auth.mfa.listFactors();
      if (r.error) throw r.error;
      var verified = (r.data && r.data.totp || []).filter(function(f){return f.status==="verified";});
      mfaShow(verified.length ? "mfa-on" : "mfa-off");
    } catch (e) { mfaShow("mfa-off"); }
  }
  async function mfaEnable() {
    $("mfa-enable").disabled = true;
    try {
      var r = await window.sb.auth.mfa.enroll({ factorType: "totp", friendlyName: "Authenticator ("+Date.now()+")" });
      if (r.error) throw r.error;
      enrollId = r.data.id;
      $("mfa-qr").src = r.data.totp.qr_code;
      $("mfa-secret").textContent = r.data.totp.secret;
      $("mfa-code").value = "";
      $("mfa-emsg").textContent = ""; $("mfa-emsg").className = "msg";
      mfaShow("mfa-enroll");
    } catch (e) {
      var m=$("s-msg"); m.textContent = "Couldn't start setup: "+(e.message||e); m.className="msg err";
    } finally { $("mfa-enable").disabled = false; }
  }
  async function mfaVerify() {
    var code = ($("mfa-code").value||"").trim(), em = $("mfa-emsg");
    if (!/^\d{6}$/.test(code)) { em.textContent="Enter the 6-digit code from your app."; em.className="msg err"; return; }
    $("mfa-verify").disabled = true;
    try {
      var r = await window.sb.auth.mfa.challengeAndVerify({ factorId: enrollId, code: code });
      if (r.error) throw r.error;
      enrollId = null;
      refreshMfa();
    } catch (e) {
      em.textContent = e.message || "That code didn't match. Try the current one."; em.className="msg err";
    } finally { $("mfa-verify").disabled = false; }
  }
  async function mfaCancel() {
    if (enrollId) { try { await window.sb.auth.mfa.unenroll({ factorId: enrollId }); } catch(e){} enrollId=null; }
    refreshMfa();
  }
  async function mfaDisable() {
    if (!(await TL.confirm({ title: "Turn off two-factor authentication?", message: "You\u2019ll sign in with just your password, which makes your account easier to break into.", confirmText: "Turn off", danger: true }))) return;
    $("mfa-disable").disabled = true;
    try {
      var r = await window.sb.auth.mfa.listFactors();
      var factors = (r.data && r.data.all) || [];
      for (var i=0;i<factors.length;i++){ await window.sb.auth.mfa.unenroll({ factorId: factors[i].id }); }
      refreshMfa();
    } catch (e) {
      var m=$("s-msg"); m.textContent = "Couldn't turn it off: "+(e.message||e); m.className="msg err";
    } finally { $("mfa-disable").disabled = false; }
  }

  // ---- Your data: export + delete ----
  async function exportData(){
    var m=$("data-msg"); m.textContent="Gathering your data…"; m.className="msg";
    $("export-btn").disabled=true;
    try{
      var tables=["profiles","students","recurring_slots","lessons","exams","invoices"];
      var bundle={ exported_at:new Date().toISOString(), account:userId };
      for(var i=0;i<tables.length;i++){
        var r=await window.sb.from(tables[i]).select("*");
        bundle[tables[i]]=r.error?("(error: "+r.error.message+")"):(r.data||[]);
      }
      var blob=new Blob([JSON.stringify(bundle,null,2)],{type:"application/json"});
      var url=URL.createObjectURL(blob),a=document.createElement("a");
      var d=new Date();
      a.href=url;a.download="tutordeck-data-"+d.getFullYear()+"-"+String(d.getMonth()+1).padStart(2,"0")+"-"+String(d.getDate()).padStart(2,"0")+".json";
      document.body.appendChild(a);a.click();a.remove();
      setTimeout(function(){URL.revokeObjectURL(url);},4000);
      m.textContent="Downloaded."; m.className="msg ok";
    }catch(e){ m.textContent="Export failed: "+(e.message||e); m.className="msg err"; }
    finally{ $("export-btn").disabled=false; }
  }

  async function deleteAccount(){
    var m=$("data-msg");
    var typed=await TL.prompt({title:"Delete your account?",
      message:"This permanently deletes your account and ALL your data: students, lessons, invoices and settings. It can\u2019t be undone.\n\nTo confirm, type DELETE below.",
      placeholder:"DELETE", match:"DELETE", confirmText:"Delete account", danger:true});
    if(typed!=="DELETE"){ m.textContent="Deletion cancelled."; m.className="msg"; return; }
    $("delete-btn").disabled=true; m.textContent="Deleting…"; m.className="msg";
    try{
      // remove any materials files this account owns (DB cascade won't touch storage)
      var mats=await window.sb.from("materials").select("file_path").eq("owner_id",userId);
      if(mats.data&&mats.data.length){ await window.sb.storage.from("materials").remove(mats.data.map(function(x){return x.file_path;})); }

      // full server-side deletion: removes the login record + cascades all data
      var res=await window.sb.functions.invoke("delete-account");
      if(res.error) throw res.error;

      try{ TL.store.clear(""); }catch(e){} try{ await window.sb.auth.signOut(); }catch(e){}
      await TL.alert({title:"Account deleted",message:"Your account and all your data have been permanently deleted."});
      location.replace("login");
    }catch(e){
      // Fallback if the Edge Function isn't deployed: wipe the data rows directly.
      try{
        await window.sb.from("materials").delete().eq("owner_id",userId);
        await window.sb.from("invoices").delete().eq("tutor_id",userId);
        await window.sb.from("students").delete().eq("tutor_id",userId);  // cascades lessons, slots, exams
        await window.sb.from("profiles").delete().eq("id",userId);
        try{ TL.store.clear(""); }catch(e){}
        await window.sb.auth.signOut();
        await TL.alert("Your data has been deleted and you've been signed out.\n\n(Note: the account login record couldn't be removed automatically — deploy the delete-account function for full removal.)");
        location.replace("login");
      }catch(e2){
        m.textContent="Couldn't complete deletion: "+(e2.message||e2); m.className="msg err";
        $("delete-btn").disabled=false;
      }
    }
  }

  // ---- share / referral ----
  var SHARE_URL="https://www.tutordeck.com.sg/";
  var SHARE_TEXT="I run my tuition admin on TutorDeck — students, schedule, PayNow invoices and WhatsApp reminders in one place. Free while in early access: "+SHARE_URL;
  function shareWA(){ window.open("https://wa.me/?text="+encodeURIComponent(SHARE_TEXT),"_blank"); }
  async function shareCopy(){
    var m=$("share-msg");
    try{ await navigator.clipboard.writeText(SHARE_URL); m.textContent="Link copied."; m.className="msg ok"; }
    catch(e){ m.textContent=SHARE_URL; m.className="msg"; }
  }

  // ---- PDPA retention review: discontinued students with no lesson in 2+ years ----
  async function retentionReview(){
    var box=$("retention"), list=$("retention-list"); if(!box||!list) return;
    var st=await window.sb.from("students").select("id,name,active,end_date");
    var today=TL.todayISO?TL.todayISO():new Date().toISOString().slice(0,10);
    var gone=(st.data||[]).filter(function(s){ return s.active===false || (s.end_date && s.end_date<today); });
    if(!gone.length) return;
    var ls=await window.sb.from("lessons").select("student_id,lesson_date").in("student_id",gone.map(function(s){return s.id;}));
    var last={}; (ls.data||[]).forEach(function(l){ if(!last[l.student_id]||l.lesson_date>last[l.student_id]) last[l.student_id]=l.lesson_date; });
    var cut=new Date(); cut.setFullYear(cut.getFullYear()-2); var cutISO=cut.toISOString().slice(0,10);
    var old=gone.filter(function(s){ var d=last[s.id]||s.end_date||""; return d && d<cutISO; })
      .sort(function(a,b){ return (last[a.id]||"").localeCompare(last[b.id]||""); });
    if(!old.length) return;
    list.innerHTML=old.map(function(s){
      var d=last[s.id]; var when=d?new Date(d+"T00:00:00").toLocaleDateString("en-SG",{month:"short",year:"numeric"}):"no lessons";
      return '<a class="ret-row" href="student?id='+encodeURIComponent(s.id)+'"><b>'+esc(s.name)+'</b><span>last lesson '+esc(when)+'</span><span class="ret-go">Review ›</span></a>';
    }).join("");
    box.style.display="";
  }
  function esc(x){ return String(x==null?"":x).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;"); }

  function init(user) {
    userId = user.id;
    if($("share-wa")) $("share-wa").addEventListener("click", shareWA);
    if($("share-copy")) $("share-copy").addEventListener("click", shareCopy);
    retentionReview().catch(function(){});
    $("save").addEventListener("click", save);
    ["ptype", "pid"].forEach(function (id) { $(id).addEventListener("input", preview); });
    $("mfa-enable").addEventListener("click", mfaEnable);
    $("mfa-verify").addEventListener("click", mfaVerify);
    $("mfa-cancel").addEventListener("click", mfaCancel);
    $("mfa-disable").addEventListener("click", mfaDisable);
    $("export-btn").addEventListener("click", exportData);
    $("delete-btn").addEventListener("click", deleteAccount);
    // Opening the message templates counts as "checked your WhatsApp reminder" (Home's Get paid faster card).
    $("msg-more").addEventListener("toggle", function () {
      if (!$("msg-more").open || checkedMsg) return; checkedMsg = true;
      window.sb.from("profiles").update({ reminder_checked_at: new Date().toISOString() }).eq("id", userId).then(function () {}, function () {});
    });
    load().then(jumpTo);
    refreshMfa();
  }
  var checkedMsg = false;
  // settings#paid / settings#messages (from Home's Get paid faster card): scroll there and open the right part.
  function jumpTo() {
    var h = location.hash.slice(1), sec = h && document.getElementById(h);
    if (!sec || (h !== "paid" && h !== "messages")) return;
    if (h === "messages") $("msg-more").open = true;
    sec.scrollIntoView({ block: "start" });
    var f = h === "paid" ? $("pid") : $("rmsg");
    setTimeout(function () { try { f.focus({ preventScroll: true }); } catch (e) {} }, 80);
  }
  TL.requireAuth("settings", init);
})();