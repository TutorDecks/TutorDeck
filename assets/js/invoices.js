// Invoices — list saved invoices; re-view, re-print, mark paid, delete.
(function () {
  var userId=null, nameById={}, invoices=[], current=null, fFrom="", fTo="", fStat="", openId=null, proofTarget=null;
  var hasSent=true;   // false until db/migration_invoice_sent.sql has been run (sent_at column)
  var $=function(id){return document.getElementById(id);};
  function esc(s){return String(s==null?"":s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");}
  function prettyDate(s){if(!s)return"—";var p=s.split("-");var mo=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];return (+p[2])+" "+mo[(+p[1])-1]+" "+p[0];}

  // Who the invoice is for. Removing a student keeps their saved invoices (student_id is set to null),
  // so fall back to what the invoice itself recorded: the stored name, then the "Bill to" line of the
  // saved snapshot, then "Removed student".
  var billToCache={};
  function studentName(inv){
    if(inv.student_id&&nameById[inv.student_id])return nameById[inv.student_id];
    var d=inv.data||{};
    if(d.name)return d.name;
    if(!(inv.id in billToCache)){
      var nm="";
      try{ if(d.html){ var b=new DOMParser().parseFromString(d.html,"text/html").querySelector(".inv-to b"); nm=b?b.textContent.trim():""; } }catch(e){}
      billToCache[inv.id]=nm;
    }
    return billToCache[inv.id]||"Removed student";
  }

  function printInvoice(){
    if(!current||!current.data||!current.data.html)return;
    var css=document.querySelector('link[rel="stylesheet"]').href;
    var title=esc(current.data.title||("Invoice_"+current.invoice_no));
    var w=window.open("","_blank","width=720,height=900");
    if(!w){TL.alert("Allow pop-ups to print, or use your browser's print on this page.");return;}
    w.document.write('<!doctype html><html><head><meta charset="utf-8"><title>'+title+'</title>'+
      '<link rel="stylesheet" href="'+css+'"><style>body{background:#fff;padding:28px;max-width:640px;margin:auto}</style></head>'+
      '<body>'+current.data.html+'</body></html>');
    w.document.close();
    w.onload=function(){ setTimeout(function(){ w.focus(); w.print(); }, 250); };
  }

  function todayISO(){var d=new Date();return d.getFullYear()+"-"+String(d.getMonth()+1).padStart(2,"0")+"-"+String(d.getDate()).padStart(2,"0");}
  async function togglePaid(inv){
    // Paying goes through the Ledger's one pay window (payment date + optional screenshot), then back here.
    var payIds=(inv.data&&inv.data.lesson_ids)||[];
    if(inv.status!=="paid" && payIds.length){ location.href="ledger?pay="+encodeURIComponent(payIds.join(","))+"&back=invoices"; return; }
    var next=inv.status==="paid"?"issued":"paid", pd=next==="paid"?todayISO():null;
    var res=await window.sb.from("invoices").update({status:next,paid_date:pd}).eq("id",inv.id);
    if(res.error){TL.alert("Couldn't update: "+res.error.message);return;}
    // Keep the Ledger in sync — settle (or un-settle) the lessons this invoice covers.
    var lids=(inv.data&&inv.data.lesson_ids)||null;
    if(lids&&lids.length){
      var lr=await window.sb.from("lessons").update({paid:next==="paid",paid_date:pd}).in("id",lids);
      if(lr.error) TL.alert("Invoice updated, but its lessons didn't sync: "+lr.error.message);
    }
    load();
  }
  async function updatePaidDate(id,date){
    var res=await window.sb.from("invoices").update({paid_date:date||null}).eq("id",id);
    if(res.error){TL.alert("Couldn't update the paid date: "+res.error.message);load();return;}
    var v=invoices.filter(function(x){return x.id===id;})[0];
    if(v){ v.paid_date=date||null;
      var lids=(v.data&&v.data.lesson_ids)||null;
      if(lids&&lids.length) await window.sb.from("lessons").update({paid_date:date||null}).in("id",lids);   // sync lessons' paid date
    }
  }
  async function del(id){
    if(!(await TL.confirm({title:"Delete this saved invoice?",message:"This only removes the saved copy. Lessons and payments stay exactly as they are.",confirmText:"Delete invoice",danger:true})))return;
    var res=await window.sb.from("invoices").delete().eq("id",id);
    if(res.error){TL.alert("Couldn't delete: "+res.error.message);return;}
    load();
  }

  // ---- income filter (by paid date) ----
  function inRange(v){
    if(!fFrom && !fTo) return true;
    // paid invoices count by the day they were paid; awaiting ones by the day they were issued
    var d=v.status==="paid"?(v.paid_date||v.issued_date||""):(v.issued_date||"");
    if(!d) return false;
    if(fFrom && d<fFrom) return false;
    if(fTo && d>fTo) return false;
    return true;
  }
  function inPeriod(){ return invoices.filter(inRange); }
  function isSent(v){ return !!v.sent_at; }
  // Replaced by a newer invoice for the same lessons (Ledger marks it): shown under All, never counted.
  function replacedBy(v){ return (v.data&&v.data.replaced_by)||""; }
  function filtered(){ return inPeriod().filter(function(v){
    if(!fStat) return true;
    if(replacedBy(v)) return false;
    if(fStat==="paid") return v.status==="paid";
    if(fStat==="unsent") return v.status!=="paid" && !isSent(v);
    return v.status!=="paid";
  }); }

  // ---- transaction screenshot (proof) ----
  function startAttach(id){ proofTarget=id; var f=$("proof-file"); f.value=""; f.click(); }
  async function onProofFile(){
    var file=$("proof-file").files[0]; if(!file||!proofTarget) return;
    var id=proofTarget; proofTarget=null;
    var safe=file.name.replace(/[^A-Za-z0-9._-]/g,"_");
    var path=userId+"/"+id+"_"+Date.now()+"_"+safe;
    var up=await window.sb.storage.from("receipts").upload(path,file,{upsert:false});
    if(up.error){ TL.alert("Upload failed: "+up.error.message); return; }
    var res=await window.sb.from("invoices").update({proof_path:path}).eq("id",id);
    if(res.error){ await window.sb.storage.from("receipts").remove([path]); TL.alert("Couldn't save: "+res.error.message); return; }
    load();
  }
  async function viewProof(v){
    if(!v||!v.proof_path) return;
    var r=await window.sb.storage.from("receipts").createSignedUrl(v.proof_path,3600);
    if(r.error||!r.data){ TL.alert("Couldn't open the screenshot: "+((r.error&&r.error.message)||"unknown")); return; }
    window.open(r.data.signedUrl,"_blank");
  }
  async function removeProof(v){
    if(!v||!v.proof_path) return;
    if(!(await TL.confirm({title:"Remove the payment screenshot?",message:"The screenshot is deleted from this invoice. The invoice stays marked as paid.",confirmText:"Remove screenshot",danger:true}))) return;
    await window.sb.storage.from("receipts").remove([v.proof_path]);
    var res=await window.sb.from("invoices").update({proof_path:null}).eq("id",v.id);
    if(res.error){ TL.alert("Couldn't update: "+res.error.message); return; }
    load();
  }

  // ---- CSV export of the (filtered) income record ----
  function csvCell(s){ s=String(s==null?"":s); return /[",\n]/.test(s)?'"'+s.replace(/"/g,'""')+'"':s; }
  function exportCSV(){
    var list=filtered().filter(function(v){ return !replacedBy(v); });   // income record: replaced invoices aren't income
    var lines=[["Paid date","Issued date","Student","Invoice no.","Total","Status","Sent","Payment screenshot"].join(",")];
    list.forEach(function(v){
      lines.push([v.paid_date||"",v.issued_date||"",studentName(v),v.invoice_no,Number(v.total||0).toFixed(2),v.status,v.sent_at?String(v.sent_at).slice(0,10):"",v.proof_path?"yes":"no"].map(csvCell).join(","));
    });
    var blob=new Blob([lines.join("\n")],{type:"text/csv"});
    var a=document.createElement("a"); a.href=URL.createObjectURL(blob);
    a.download="income"+((fFrom||fTo)?("_"+(fFrom||"start")+"_"+(fTo||"end")):"")+".csv";
    document.body.appendChild(a); a.click(); document.body.removeChild(a); URL.revokeObjectURL(a.href);
  }

  function initials(n){var w=String(n||"").split(/\s+/).filter(Boolean);return ((w[0]||"?")[0]+((w[1]||"")[0]||"")).toUpperCase();}
  var CLIP='<svg class="iv-clip" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-label="Payment screenshot attached"><path d="m21.4 11.6-9.2 9.2a6 6 0 0 1-8.5-8.5l9.2-9.2a4 4 0 0 1 5.7 5.7l-9.2 9.2a2 2 0 0 1-2.8-2.8l8.5-8.5"/></svg>';
  function shortDate(s){if(!s)return"";var p=s.split("-");var mo=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];return (+p[2])+" "+mo[(+p[1])-1];}

  function render(){
    var period=inPeriod().filter(function(v){ return !replacedBy(v); }), list=filtered();
    var paid=period.filter(function(v){return v.status==="paid";}), wait=period.filter(function(v){return v.status!=="paid";});
    var sum=function(a){return a.reduce(function(t,v){return t+Number(v.total||0);},0);};
    $("iv-paid").textContent=TL.sgd(sum(paid)); $("iv-paid-n").textContent=paid.length+(paid.length===1?" invoice":" invoices");
    $("iv-wait").textContent=TL.sgd(sum(wait)); $("iv-wait-n").textContent=wait.length+(wait.length===1?" invoice":" invoices");
    var unsent=wait.filter(function(v){return !isSent(v);});
    $("iv-unsent").textContent=hasSent?String(unsent.length):"—";
    $("iv-unsent-n").textContent=hasSent?TL.sgd(sum(unsent))+" waiting to go out":"run the sent-date update";
    $("iv-unsent-c").textContent=hasSent&&unsent.length?" · "+unsent.length:"";
    $("iv-wait-c").textContent=wait.length?" · "+wait.length:"";
    document.querySelectorAll("#iv-seg [data-st]").forEach(function(b){b.classList.toggle("on",b.dataset.st===fStat);});
    $("i-count").textContent=list.length+(list.length===1?" invoice":" invoices");
    var box=$("iv-list"), empty=$("i-empty");
    if(!list.length){
      box.style.display="none"; empty.style.display="block";
      empty.querySelector("h3").textContent=invoices.length?"No invoices here":"No saved invoices yet";
      empty.querySelector("p").style.display=invoices.length?"none":"";
    } else {
      empty.style.display="none"; box.style.display="";
      box.innerHTML=list.map(function(v){
        var isPaid=v.status==="paid", nm=studentName(v), rb=replacedBy(v);
        var st=rb?'<span class="iv-st repl">Replaced by '+esc(rb)+'</span>':isPaid?'<span class="iv-st paid">Paid'+(v.paid_date?' '+shortDate(v.paid_date):'')+'</span>'
          :(!hasSent?'<span class="iv-st wait">Awaiting</span>'
          :(isSent(v)?'<span class="iv-st sent">Sent '+shortDate(String(v.sent_at).slice(0,10))+'</span>':'<span class="iv-st unsent">Not sent</span>'));
        return '<button type="button" class="iv-row'+(rb?' repl':'')+'" data-open="'+v.id+'">'+
          '<span class="iv-av" aria-hidden="true">'+esc(nm==="Removed student"?"\u2013":initials(nm))+'</span>'+
          '<span class="iv-main"><span class="iv-name">'+esc(nm)+'</span><span class="iv-sub">'+esc(v.invoice_no)+' · issued '+shortDate(v.issued_date)+'</span></span>'+
          (v.proof_path?CLIP:'')+
          '<span class="iv-right2"><span class="iv-amt">'+TL.sgd(v.total)+'</span>'+st+'</span></button>';
      }).join("");
      box.querySelectorAll("[data-open]").forEach(function(b){b.addEventListener("click",function(){openSheet(b.dataset.open);});});
    }
    if(openId) renderSheet();
  }

  // ---- invoice sheet ----
  function find(id){return invoices.filter(function(v){return v.id===id;})[0];}
  function openSheet(id){ openId=id; renderSheet(); $("iv-sheet").classList.add("on"); document.body.classList.add("sheet-lock"); }
  function closeSheet(){ openId=null; current=null; $("iv-sheet").classList.remove("on"); document.body.classList.remove("sheet-lock"); }
  function renderSheet(){
    var v=find(openId); if(!v){ closeSheet(); return; }
    current=v;
    var isPaid=v.status==="paid", rb=replacedBy(v);
    $("iv-s-name").textContent=studentName(v);
    $("iv-s-meta").textContent=v.invoice_no+" · issued "+prettyDate(v.issued_date);
    $("iv-s-amt").textContent=TL.sgd(v.total);
    $("iv-s-amt").style.color=rb?"var(--muted)":isPaid?"var(--accent)":"var(--owed)";
    var proof=v.proof_path
      ? '<span><button class="tact" data-vproof>View</button><button class="tact del" data-rproof>Remove</button></span>'
      : '<button class="tact" data-aproof>Attach screenshot</button>';
    $("iv-s-body").innerHTML=
      (rb?'<p class="ivs-note">Replaced by <b>'+esc(rb)+'</b>, a newer invoice that includes these lessons. It isn\u2019t counted in your totals.</p>':'')+
      '<div class="ivs-acts">'+
        (rb?'':isPaid?'<button class="btn wide" data-paid>Mark as unpaid</button>'
               :'<button class="btn btn-gold wide" data-paid>Mark as paid</button>')+
        (!rb&&!isPaid&&hasSent&&!isSent(v)?'<button class="btn wide" data-sent>Mark as sent</button>':'')+
        '<button class="btn" data-print>Print / Save PDF</button>'+
        '<a class="btn" href="ledger">Open Ledger</a>'+
      '</div>'+
      '<div class="ivs-box">'+
        '<div class="ivs-line"><span class="k">Status</span>'+(rb?'<span class="iv-st repl">Replaced by '+esc(rb)+'</span>':isPaid?'<span class="iv-st paid">Paid</span>':'<span class="iv-st wait">Awaiting payment</span>')+'</div>'+
        (hasSent?'<div class="ivs-line"><span class="k">Sent to parent</span>'+(isSent(v)
          ?'<span>'+prettyDate(String(v.sent_at).slice(0,10))+' <button class="tact" data-unsent>Undo</button></span>'
          :'<span class="iv-st unsent">Not sent yet</span>')+'</div>':'')+
        (isPaid?'<div class="ivs-line"><span class="k">Paid on</span><input type="date" data-pd value="'+(v.paid_date||"")+'"></div>':'')+
        '<div class="ivs-line"><span class="k">Payment screenshot</span>'+proof+'</div>'+
      '</div>'+
      '<div class="ivs-prev">'+((v.data&&v.data.html)||'<p class="muted">Snapshot unavailable.</p>')+'</div>'+
      '<button class="ivs-del" data-del>Delete invoice</button>';
    var B=$("iv-s-body");
    function on(sel,fn){var el=B.querySelector(sel);if(el)el.addEventListener("click",fn);}
    on("[data-paid]",function(){togglePaid(v);});
    on("[data-sent]",function(){setSent(v,true);});
    on("[data-unsent]",function(){setSent(v,false);});
    on("[data-print]",printInvoice);
    on("[data-aproof]",function(){startAttach(v.id);});
    on("[data-vproof]",function(){viewProof(v);});
    on("[data-rproof]",function(){removeProof(v);});
    on("[data-del]",function(){del(v.id);});
    var pd=B.querySelector("[data-pd]"); if(pd)pd.addEventListener("change",function(){updatePaidDate(v.id,pd.value).then(render);});
  }

  async function setSent(v,sent){
    var at=sent?new Date().toISOString():null;
    var res=await window.sb.from("invoices").update({sent_at:at}).eq("id",v.id);
    if(res.error){TL.alert("Couldn't update: "+res.error.message);return;}
    v.sent_at=at; render();
  }

  // ---- period picker ----
  function setPeriod(p){
    var y=new Date().getFullYear();
    $("iv-custom").classList.toggle("on",p==="custom");
    if(p==="year"){fFrom=y+"-01-01";fTo=y+"-12-31";}
    else if(p==="lastyear"){fFrom=(y-1)+"-01-01";fTo=(y-1)+"-12-31";}
    else if(p==="all"){fFrom="";fTo="";}
    else {fFrom=$("f-from").value;fTo=$("f-to").value;}
    render();
  }

  async function load(){
    var st=await window.sb.from("students").select("id,name");
    nameById={};(st.data||[]).forEach(function(s){nameById[s.id]=s.name;});
    var cols="id,student_id,invoice_no,issued_date,total,status,paid_date,proof_path,data";
    var res=await window.sb.from("invoices").select(cols+",sent_at").order("issued_date",{ascending:false}).order("created_at",{ascending:false});
    // Before db/migration_invoice_sent.sql is run there's no sent_at column — fall back and hide "Sent".
    if(res.error&&/sent_at/.test(res.error.message||"")){
      hasSent=false;
      res=await window.sb.from("invoices").select(cols).order("issued_date",{ascending:false}).order("created_at",{ascending:false});
    } else hasSent=true;
    if(res.error){$("i-count").textContent="Couldn't load invoices: "+res.error.message;return;}
    invoices=res.data||[];render();
  }

  function init(user){
    userId=user.id;
    $("iv-s-close").addEventListener("click",closeSheet);
    $("iv-sheet").addEventListener("click",function(e){if(e.target===$("iv-sheet"))closeSheet();});
    document.addEventListener("keydown",function(e){if(e.key==="Escape"&&openId)closeSheet();});
    document.querySelectorAll("#iv-seg [data-st]").forEach(function(b){b.addEventListener("click",function(){fStat=b.dataset.st;render();});});
    $("iv-period").addEventListener("change",function(){setPeriod(this.value);});
    $("f-from").addEventListener("change",function(){fFrom=this.value;render();});
    $("f-to").addEventListener("change",function(){fTo=this.value;render();});
    var dd=$("iv-more"), ddb=dd.querySelector("button");
    ddb.addEventListener("click",function(e){e.stopPropagation();dd.classList.toggle("open");});
    document.addEventListener("click",function(){dd.classList.remove("open");});
    $("i-csv").addEventListener("click",function(){dd.classList.remove("open");exportCSV();});
    $("proof-file").addEventListener("change",onProofFile);
    load();
  }
  TL.requireAuth("invoices",init);
})();