// Students — roster with add, EDIT, MERGE (de-dupe safely), and remove.
(function () {
  var userId=null, students=[], editingId=null, mergeSource=null;
  var $=function(id){return document.getElementById(id);};
  function esc(s){return String(s==null?"":s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");}

  // ---------- add / edit ----------
  function openModal(open, st){
    $("modal").classList.toggle("on",open);
    $("m-msg").textContent="";$("m-msg").className="msg";
    if(!open)return;
    if(st){
      editingId=st.id;
      $("m-title").textContent="Edit student";$("m-save").textContent="Save changes";
      $("m-name").value=st.name||"";
      $("m-level").value=st.level||"";$("m-contact").value=st.contact||"";$("m-location").value=st.location||"";$("m-recipient").value=st.recipient_name||"";$("m-notes").value=st.notes||"";
      if($("m-enddate"))$("m-enddate").value=st.end_date||"";
      if($("m-paybank"))$("m-paybank").checked=!!st.pay_by_bank;
    }else{
      editingId=null;
      $("m-title").textContent="Add student";$("m-save").textContent="Save student";
      ["m-name","m-level","m-contact","m-location","m-recipient","m-notes","m-enddate"].forEach(function(id){if($(id))$(id).value="";});
      if($("m-paybank"))$("m-paybank").checked=false;
    }
    $("m-name").focus();
  }
  async function save(){
    var name=$("m-name").value.trim(),msg=$("m-msg");
    if(!name){msg.textContent="Give the student a name.";msg.className="msg err";return;}
    var fields={name:name,
      level:$("m-level").value.trim()||null,contact:$("m-contact").value.trim()||null,
      location:$("m-location").value.trim()||null,
      recipient_name:$("m-recipient").value.trim()||null,
      end_date:($("m-enddate")&&$("m-enddate").value)||null,
      pay_by_bank:!!($("m-paybank")&&$("m-paybank").checked),
      notes:$("m-notes").value.trim()||null};
    $("m-save").disabled=true;
    var res=editingId
      ? await window.sb.from("students").update(fields).eq("id",editingId)
      : await window.sb.from("students").insert(Object.assign({tutor_id:userId},fields));
    $("m-save").disabled=false;
    if(res.error){msg.textContent=res.error.message;msg.className="msg err";return;}
    openModal(false);load();
  }

  // ---------- merge ----------
  function openMerge(open, source){
    $("merge-modal").classList.toggle("on",open);
    $("mg-msg").textContent="";$("mg-msg").className="msg";
    if(!open)return;
    mergeSource=source;
    $("mg-source").textContent=source.name;
    $("mg-target").innerHTML=students.filter(function(s){return s.id!==source.id;})
      .map(function(s){return '<option value="'+s.id+'">'+esc(s.name)+"</option>";}).join("");
  }
  async function doMerge(){
    var target=$("mg-target").value,msg=$("mg-msg");
    if(!target){msg.textContent="Pick a student to merge into.";msg.className="msg err";return;}
    $("mg-save").disabled=true;
    try{
      for(var i=0;i<3;i++){
        var table=["lessons","recurring_slots","exams"][i];
        var r=await window.sb.from(table).update({student_id:target}).eq("student_id",mergeSource.id);
        if(r.error)throw r.error;
      }
      var del=await window.sb.from("students").delete().eq("id",mergeSource.id);
      if(del.error)throw del.error;
    }catch(e){
      $("mg-save").disabled=false;
      msg.textContent="Merge failed: "+(e.message||e);msg.className="msg err";return;
    }
    $("mg-save").disabled=false;
    openMerge(false);load();
  }

  // ---------- remove ----------
  async function remove(id,name){
    if(!confirm("Remove "+name+"?\n\nThis permanently DELETES their lessons, slots and exams too. "+
                "To combine duplicates without losing history, use Merge instead."))return;
    var res=await window.sb.from("students").delete().eq("id",id);
    if(res.error){alert("Couldn't remove: "+res.error.message);return;}
    load();
  }
  async function setActive(id,active){
    // Reactivating a student whose scheduled end date has already passed must also clear that
    // date — otherwise they'd immediately fall back into Discontinued (end_date in the past).
    var cur=students.filter(function(s){return s.id===id;})[0];
    var fields={active:active};
    if(active && cur && TL.isEnded(cur.end_date)) fields.end_date=null;
    var res=await window.sb.from("students").update(fields).eq("id",id);
    if(res.error){alert("Couldn't update: "+res.error.message);return;}
    // Keep the weekly schedule in step: discontinuing removes the student's recurring slots from the
    // Planner/Calendar (both filter active slots); reactivating brings them back. Lessons are untouched.
    try{ await window.sb.from("recurring_slots").update({active:active}).eq("student_id",id); }
    catch(e){ console.warn("Couldn't update the student's slots:",e); }
    load();
  }

  // ---------- list ----------
  // A student is effectively active only if not discontinued AND their end date (if any) hasn't passed.
  function isActive(s){ return s.active!==false && !TL.isEnded(s.end_date); }
  // Short, quiet date: "30 Nov" (same year) or "30 Nov 2027" (different year).
  function fmtD(d){
    if(!d)return ""; var t=new Date(d+"T00:00:00"); if(isNaN(t))return d;
    var opts=t.getFullYear()===new Date().getFullYear()?{day:"numeric",month:"short"}:{day:"numeric",month:"short",year:"numeric"};
    return t.toLocaleDateString("en-SG",opts);
  }
  // A quiet grey line under the name — not a loud badge.
  function endLine(r){
    if(!r.end_date)return "";
    var word=TL.isEnded(r.end_date)?"ended ":"ends ";
    return '<div class="muted" style="font-size:12px;font-weight:500;margin-top:1px">'+word+esc(fmtD(r.end_date))+'</div>';
  }
  function initials(n){var w=String(n||"").split(/\s+/).filter(Boolean);return ((w[0]||"?")[0]+((w[1]||"")[0]||"")).toUpperCase();}
  function rowHtml(r,active){
    // One ⋯ menu per row; tapping anywhere else on the row opens the profile.
    // Merge (de-dupe) is no longer in the menu (v160); openMerge/doMerge + #merge-modal are kept so it can be
    // restored by adding back: '<button class="tact" data-merge="'+r.id+'">Merge with…</button>'
    var acts=active
      ? '<button class="tact" data-edit="'+r.id+'">Edit details</button>'+
        '<button class="tact" data-off="'+r.id+'">Discontinue</button><hr>'+
        '<button class="tact del" data-del="'+r.id+'">Remove</button>'
      : '<button class="tact" data-edit="'+r.id+'">Edit details</button>'+
        '<button class="tact" data-on="'+r.id+'">Reactivate</button><hr>'+
        '<button class="tact del" data-del="'+r.id+'">Remove</button>';
    var sub=[r.level,r.recipient_name].filter(Boolean).map(esc).join(" · ");
    return '<tr class="'+(active?"":"inactive")+'" data-id="'+r.id+'">'+
      '<td class="name" data-label="Name"><div class="ro-name"><span class="ro-av" aria-hidden="true">'+esc(initials(r.name))+'</span>'+
        '<span class="ro-nm"><a class="slink" href="student.html?id='+r.id+'">'+esc(r.name)+"</a>"+
        (sub?'<span class="ro-sub">'+sub+'</span>':'')+endLine(r)+'</span></div></td>'+
      '<td data-label="Parent">'+(r.recipient_name?esc(r.recipient_name):'<span class="muted">—</span>')+"</td>"+
      '<td data-label="Level">'+(r.level?'<span class="ro-lvl">'+esc(r.level)+'</span>':'<span class="muted">—</span>')+"</td>"+
      '<td data-label="Contact">'+(r.contact?esc(r.contact):'<span class="muted">—</span>')+"</td>"+
      '<td class="acts"><div class="rm"><button class="rmore" type="button" aria-label="Actions for '+esc(r.name)+'" aria-haspopup="true">⋯</button>'+
        '<div class="rm-menu" role="menu">'+acts+'</div></div></td></tr>';
  }
  function wire(scope){
    function find(id){return students.filter(function(s){return s.id===id;})[0];}
    scope.querySelectorAll("[data-edit]").forEach(function(b){b.addEventListener("click",function(){openModal(true,find(b.dataset.edit));});});
    scope.querySelectorAll("[data-view]").forEach(function(b){b.addEventListener("click",function(){location.href="student.html?id="+encodeURIComponent(b.dataset.view);});});
    scope.querySelectorAll("[data-merge]").forEach(function(b){b.addEventListener("click",function(){openMerge(true,find(b.dataset.merge));});});
    scope.querySelectorAll("[data-off]").forEach(function(b){b.addEventListener("click",function(){setActive(b.dataset.off,false);});});
    scope.querySelectorAll("[data-on]").forEach(function(b){b.addEventListener("click",function(){setActive(b.dataset.on,true);});});
    scope.querySelectorAll("[data-del]").forEach(function(b){b.addEventListener("click",function(){remove(b.dataset.del,find(b.dataset.del).name);});});
    // Mobile: rows are a compact list — tapping one (not a link/button) opens the profile.
    scope.querySelectorAll(".rmore").forEach(function(b){b.addEventListener("click",function(e){
      e.stopPropagation();var m=b.parentNode,o=!m.classList.contains("open");
      document.querySelectorAll(".rm.open").forEach(function(x){x.classList.remove("open");});m.classList.toggle("open",o);});});
    scope.querySelectorAll(".rm-menu .tact").forEach(function(b){b.addEventListener("click",function(){var m=b.closest(".rm");if(m)m.classList.remove("open");});});
    scope.querySelectorAll("tr[data-id]").forEach(function(tr){
      tr.addEventListener("click",function(e){
        if(e.target.closest("a,button,input,label,.rm"))return;
        location.href="student.html?id="+encodeURIComponent(tr.dataset.id);
      });
    });
  }
  function fillOpt(id,vals,label){
    var el=$(id);if(!el)return;var cur=el.value;
    el.innerHTML='<option value="">'+label+'</option>'+vals.map(function(v){return '<option value="'+String(v).replace(/"/g,"&quot;")+'">'+esc(v)+'</option>';}).join("");
    el.value=cur;
  }
  function fillStuFilters(){
    var lvl=[],par=[];
    students.forEach(function(s){
      if(s.level&&lvl.indexOf(s.level)<0)lvl.push(s.level);
      if(s.recipient_name&&par.indexOf(s.recipient_name)<0)par.push(s.recipient_name);
    });
    fillOpt("s-level",lvl.sort(),"All levels");
    fillOpt("s-parent",par.sort(),"All parents");
  }
  function clearStuFilters(){
    ["s-search","s-level","s-parent"].forEach(function(id){var el=$(id);if(el)el.value="";});
    renderRoster();
  }
  function matchesSearch(s,q){
    if(!q)return true;
    return [s.name,s.recipient_name,s.level,s.contact].some(function(v){return (v||"").toLowerCase().indexOf(q)>-1;});
  }
  function renderRoster(){
    var q=($("s-search")?$("s-search").value:"").trim().toLowerCase();
    var fLvl=$("s-level")?$("s-level").value:"";
    var fPar=$("s-parent")?$("s-parent").value:"";
    var fStat=$("s-status")?$("s-status").value:"";
    function pass(s){
      return matchesSearch(s,q) && (!fLvl||(s.level||"")===fLvl) && (!fPar||(s.recipient_name||"")===fPar);
    }
    var anyFilter=!!(q||fLvl||fPar);
    document.querySelectorAll("#ro-seg [data-st]").forEach(function(b){b.classList.toggle("on",b.dataset.st===fStat);});
    var offN=students.filter(function(s){return !isActive(s);}).length;
    if($("ro-off-n"))$("ro-off-n").textContent=offN?" · "+offN:"";
    ["s-level","s-parent"].forEach(function(id){var el=$(id);if(el)el.classList.toggle("on",!!el.value);});
    if($("s-clear"))$("s-clear").style.display=anyFilter?"":"none";

    var actAll=students.filter(isActive);
    var offAll=students.filter(function(s){return !isActive(s);});
    var act=(fStat==="off")?[]:actAll.filter(pass);
    var off=(fStat==="active")?[]:offAll.filter(pass);
    $("s-count").textContent=anyFilter?(act.length+off.length)+" of "+students.length+" shown":(actAll.length?actAll.length+(actAll.length===1?" active student":" active students"):"");

    var table=$("s-table"),empty=$("s-empty"),body=$("s-body");
    if($("s-sk"))$("s-sk").remove();
    if(!actAll.length){table.style.display="none";empty.style.display="block";}
    else if(!act.length){empty.style.display="none";table.style.display="table";body.innerHTML='<tr><td colspan="5" style="color:var(--muted);padding:14px 4px">'+(fStat==="off"?"Showing discontinued only.":"No active students match these filters.")+'</td></tr>';}
    else{empty.style.display="none";table.style.display="table";body.innerHTML=act.map(function(r){return rowHtml(r,true);}).join("");wire(body);}

    // "Discontinued" view: show only that section; "Active": hide it; "All": both.
    $("s-table").closest(".card").style.display=(fStat==="off")?"none":"";
    if(offAll.length&&fStat!=="active"){
      $("disc-title").style.display="";$("disc-card").style.display="";
      $("disc-hint").textContent=offAll.length+" hidden from slot & lesson pickers";
      $("disc-body").innerHTML=off.length?off.map(function(r){return rowHtml(r,false);}).join(""):'<tr><td colspan="5" style="color:var(--muted);padding:12px 4px">No matches.</td></tr>';
      wire($("disc-body"));
    }else{$("disc-title").style.display="none";$("disc-card").style.display="none";}
  }
  async function load(){
    var res=await window.sb.from("students").select("id,name,kind,level,contact,location,notes,active,recipient_name,end_date,pay_by_bank").order("name");
    if(res.error){$("s-count").textContent="Couldn't load students: "+res.error.message;return;}
    students=res.data||[];
    fillStuFilters();
    renderRoster();
  }

  function init(user){
    userId=user.id;
    if($("s-search"))$("s-search").addEventListener("input",renderRoster);
    ["s-level","s-parent","s-status"].forEach(function(id){var el=$(id);if(el)el.addEventListener("change",renderRoster);});
    document.querySelectorAll("#ro-seg [data-st]").forEach(function(b){b.addEventListener("click",function(){$("s-status").value=b.dataset.st;renderRoster();});});
    if($("ro-ftoggle"))$("ro-ftoggle").addEventListener("click",function(){var f=document.querySelector(".ro-filters"),o=!f.classList.contains("open");f.classList.toggle("open",o);this.setAttribute("aria-expanded",o?"true":"false");});
    document.addEventListener("click",function(){document.querySelectorAll(".rm.open").forEach(function(x){x.classList.remove("open");});});
    if($("s-clear"))$("s-clear").addEventListener("click",clearStuFilters);
    $("add-btn").addEventListener("click",function(){openModal(true,null);});
    $("m-cancel").addEventListener("click",function(){openModal(false);});
    $("modal").addEventListener("click",function(e){if(e.target===$("modal"))openModal(false);});
    $("m-save").addEventListener("click",save);
    TL.wirePostal("m-postal-btn","m-location","m-postal-msg");
    $("m-name").addEventListener("keydown",function(e){if(e.key==="Enter")save();});
    $("mg-cancel").addEventListener("click",function(){openMerge(false);});
    $("merge-modal").addEventListener("click",function(e){if(e.target===$("merge-modal"))openMerge(false);});
    $("mg-save").addEventListener("click",doMerge);
    load();
  }
  TL.requireAuth("students",init);
})();