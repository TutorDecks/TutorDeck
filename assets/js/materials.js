// Teaching materials library — owner-only for now. Files in the private
// 'materials' Storage bucket; metadata in public.materials.
(function () {
  var $ = function (id) { return document.getElementById(id); };
  function esc(s){return String(s==null?"":s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");}
  var userId = null, all = [];

  function extKind(name){
    var e=(name.split(".").pop()||"").toLowerCase();
    if(e==="pptx"||e==="ppt")return "slides";
    if(e==="docx"||e==="doc"||e==="pdf")return "worksheet";
    return "other";
  }
  function humanSize(b){ if(!b)return""; if(b<1024)return b+" B"; if(b<1048576)return Math.round(b/1024)+" KB"; return (b/1048576).toFixed(1)+" MB"; }

  function fillFilter(id, values, label){
    var cur=$(id).value;
    $(id).innerHTML='<option value="">'+label+'</option>'+values.map(function(v){return '<option value="'+esc(v)+'">'+esc(v)+'</option>';}).join("");
    $(id).value=cur;
  }
  function refreshFilters(){
    var subs=[],lvls=[],strs=[];
    all.forEach(function(m){
      if(m.subject&&subs.indexOf(m.subject)<0)subs.push(m.subject);
      if(m.level&&lvls.indexOf(m.level)<0)lvls.push(m.level);
      if(m.stream&&strs.indexOf(m.stream)<0)strs.push(m.stream);
    });
    subs.sort();lvls.sort();strs.sort();
    fillFilter("f-subject",subs,"All subjects");
    fillFilter("f-level",lvls,"All levels");
    fillFilter("f-stream",strs,"All streams");
  }

  function render(){
    var fs=$("f-subject").value,fl=$("f-level").value,fst=$("f-stream").value;
    var rows=all.filter(function(m){
      return (!fs||m.subject===fs)&&(!fl||m.level===fl)&&(!fst||m.stream===fst);
    });
    $("mat-count").textContent=all.length+" material"+(all.length===1?"":"s")+
      (rows.length!==all.length?" · "+rows.length+" shown":"");
    if(!rows.length){$("mat-list").innerHTML='<div class="mat-empty">'+(all.length?"Nothing matches these filters.":"No materials yet. Tap \u201C+ Upload material\u201D to add your first.")+'</div>';return;}
    // group by topic (within current filter)
    var groups={};
    rows.forEach(function(m){var k=m.topic||"Untitled topic";(groups[k]=groups[k]||[]).push(m);});
    var keys=Object.keys(groups).sort();
    $("mat-list").innerHTML=keys.map(function(k){
      var items=groups[k].sort(function(a,b){return (a.title||"").localeCompare(b.title||"");});
      return '<div class="topic-group"><div class="topic-head">'+esc(k)+'</div>'+
        items.map(function(m){
          var kind=m.kind||extKind(m.file_name||"");
          var badge=kind==="slides"?"PPT":kind==="worksheet"?"DOC":"FILE";
          var meta=[m.subject,m.level,m.stream].filter(Boolean).join(" · ")+(m.size_bytes?" · "+humanSize(m.size_bytes):"");
          return '<div class="mat-row"><div class="mat-ic '+esc(kind)+'">'+badge+'</div>'+
            '<div class="mat-body"><div class="mat-title">'+esc(m.title||m.file_name||"Untitled")+'</div>'+
            '<div class="mat-meta">'+esc(meta)+'</div></div>'+
            '<div class="mat-act"><button class="dl" data-dl="'+m.id+'">Open</button>'+
            '<button class="rm" data-rm="'+m.id+'">Delete</button></div></div>';
        }).join("")+'</div>';
    }).join("");
    $("mat-list").querySelectorAll("[data-dl]").forEach(function(b){b.addEventListener("click",function(){openFile(b.dataset.dl);});});
    $("mat-list").querySelectorAll("[data-rm]").forEach(function(b){b.addEventListener("click",function(){removeMaterial(b.dataset.rm);});});
  }

  async function load(){
    var r=await window.sb.from("materials").select("*").order("created_at",{ascending:false});
    if(r.error){$("mat-list").innerHTML='<div class="mat-empty">Couldn\u2019t load: '+esc(r.error.message)+'. Have you run db/migration_materials.sql?</div>';return;}
    all=r.data||[];
    refreshFilters();
    render();
  }

  async function openFile(id){
    var m=all.filter(function(x){return x.id===id;})[0];if(!m)return;
    var r=await window.sb.storage.from("materials").createSignedUrl(m.file_path,3600);
    if(r.error||!r.data){TL.alert("Couldn't open the file: "+((r.error&&r.error.message)||"unknown"));return;}
    window.open(r.data.signedUrl,"_blank");
  }

  async function removeMaterial(id){
    var m=all.filter(function(x){return x.id===id;})[0];if(!m)return;
    if(!(await TL.confirm({title:"Delete \u201C"+(m.title||m.file_name)+"\u201D?",message:"This removes the file permanently.",confirmText:"Delete file",danger:true})))return;
    await window.sb.storage.from("materials").remove([m.file_path]);
    var r=await window.sb.from("materials").delete().eq("id",id);
    if(r.error){TL.alert("Couldn't delete the record: "+r.error.message);return;}
    load();
  }

  function openUpload(){
    ["u-title-in","u-subject","u-level","u-topic"].forEach(function(i){$(i).value="";});
    $("u-file").value="";$("u-stream").value="";$("u-kind").value="slides";
    $("u-msg").textContent="";$("u-msg").className="msg";
    $("u-modal").classList.add("on");
  }
  function closeUpload(){$("u-modal").classList.remove("on");}

  async function doUpload(){
    var msg=$("u-msg"), file=$("u-file").files[0];
    var subject=$("u-subject").value.trim(), level=$("u-level").value.trim(),
        topic=$("u-topic").value.trim(), title=$("u-title-in").value.trim(),
        stream=$("u-stream").value||null, kind=$("u-kind").value;
    if(!file){msg.textContent="Choose a file to upload.";msg.className="msg err";return;}
    if(!subject||!level||!topic){msg.textContent="Subject, level and topic are required.";msg.className="msg err";return;}
    if(!title)title=file.name;
    $("u-save").disabled=true;msg.textContent="Uploading\u2026";msg.className="msg";
    try{
      var safe=file.name.replace(/[^A-Za-z0-9._-]/g,"_");
      var path=userId+"/"+Date.now()+"_"+safe;
      var up=await window.sb.storage.from("materials").upload(path,file,{upsert:false});
      if(up.error)throw up.error;
      var ins=await window.sb.from("materials").insert({
        owner_id:userId,subject:subject,level:level,stream:stream,topic:topic,
        title:title,kind:kind,file_path:path,file_name:file.name,size_bytes:file.size
      });
      if(ins.error){ await window.sb.storage.from("materials").remove([path]); throw ins.error; }
      closeUpload();load();
    }catch(e){
      msg.textContent="Upload failed: "+(e.message||e);msg.className="msg err";
    }finally{ $("u-save").disabled=false; }
  }

  window.TL.requireAuth("materials", function (user) {
    // Owner-only. RLS also protects the data, this just hides the UI.
    if (!window.TL_IS_OWNER) {
      $("mat-app").style.display="none";
      $("mat-noaccess").style.display="block";
      return;
    }
    userId = user.id;
    $("add-btn").addEventListener("click", openUpload);
    $("u-cancel").addEventListener("click", closeUpload);
    $("u-modal").addEventListener("click", function(e){ if(e.target===$("u-modal"))closeUpload(); });
    $("u-save").addEventListener("click", doUpload);
    $("u-file").addEventListener("change", function(){
      var f=$("u-file").files[0]; if(f){ $("u-kind").value=extKind(f.name); if(!$("u-title-in").value)$("u-title-in").value=f.name.replace(/\.[^.]+$/,""); }
    });
    ["f-subject","f-level","f-stream"].forEach(function(id){$(id).addEventListener("change",render);});
    load();
  });
})();