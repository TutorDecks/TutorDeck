// Per-student profile: header, totals, lesson history, slots, exams.
(function () {
  var userId=null, sid=null, student=null, lessons=[], exams=[], slots=[], noteId=null, lessonId=null, examId=null, cancelConfirming=false;
  var schY=null, schM=null;   // month shown in the "Monthly schedule" card
  var $=function(id){return document.getElementById(id);};
  function esc(s){return String(s==null?"":s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");}
  function qid(){var m=location.search.match(/[?&]id=([^&]+)/);return m?decodeURIComponent(m[1]):null;}
  var DOW=["Mon","Tue","Wed","Thu","Fri","Sat","Sun"];
  var MO=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
  function prettyDate(s){if(!s)return"—";var p=s.split("-");return (+p[2])+" "+MO[(+p[1])-1]+" "+p[0];}
  function hhmm(t){return t?t.slice(0,5):"";}
  function todayISO(){var d=new Date();function p(n){return(n<10?"0":"")+n;}return d.getFullYear()+"-"+p(d.getMonth()+1)+"-"+p(d.getDate());}

  function setTitle(name){var h=document.querySelector(".topbar h1");if(h)h.textContent=name;}

  async function load(){
    sid=qid();
    if(!sid){$("p-head").innerHTML='<div class="card"><p>No student selected. <a href="students">Back to students</a>.</p></div>';return;}
    await TL.promotePastLessons();

    var sres=await window.sb.from("students").select("id,name,kind,level,contact,location,recipient_name,notes,active,pay_by_bank,end_date").eq("id",sid).single();
    if(sres.error||!sres.data){$("p-head").innerHTML='<div class="card"><p>Couldn\'t load this student. <a href="students">Back to students</a>.</p></div>';return;}
    student=sres.data;setTitle(student.name);

    var LCOLS="id,slot_id,slot_date,lesson_date,start_time,end_time,subject,amount,paid,status,topics,homework,remarks,compensation";
    var lres=await window.sb.from("lessons").select(LCOLS+",charge_note").eq("student_id",sid);
    if(lres.error) lres=await window.sb.from("lessons").select(LCOLS).eq("student_id",sid);   // charge_note migration not run yet
    lessons=lres.data||[];
    // A cancelled lesson's billable amount is its compensation (0 if none) — every KPI/
    // table below reads plain l.amount, so normalizing it once here keeps that code simple.
    lessons.forEach(function(l){ if(l.status==="cancelled") l.amount=Number(l.compensation)||0; });
    var xres=await window.sb.from("exams").select("id,exam_date,assessment_type,subject,topics,remarks,score,max_score").eq("student_id",sid);
    exams=xres.data||[];
    var slres=await window.sb.from("recurring_slots").select("id,weekday,start_time,end_time,subject,level,rate").eq("student_id",sid).eq("active",true);
    slots=slres.data||[];
    if(schM==null){ var nn=new Date(); schY=nn.getFullYear(); schM=nn.getMonth(); }

    renderHead();
    renderKpis(lessons);
    renderLessons(lessons);        // tutor: lesson-history table
    renderNotes(lessons);          // tutor: separate notes list
    renderClientLessons(lessons);  // client: combined lessons + notes
    renderParentKpis(lessons, exams);
    renderSlots(slots);
    renderSchedule();              // tutor: copy-ready monthly schedule
    renderExams(exams);
    renderProgress(exams);
  }

  function renderHead(){
    // Icon + value lines (no label wall). Phone opens WhatsApp. On phones the lines sit behind "More info".
    var IC={
      phone:'<path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1.9.4 1.8.7 2.7a2 2 0 0 1-.5 2.1L8 9.8a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.4c.9.3 1.8.6 2.7.7a2 2 0 0 1 1.7 2z"/>',
      pin:'<path d="M20 10c0 6-8 12-8 12s-8-6-8-12a8 8 0 0 1 16 0Z"/><circle cx="12" cy="10" r="3"/>',
      msg:'<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>',
      note:'<path d="M14.5 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7.5z"/><path d="M14 2v6h6M8 13h8M8 17h5"/>'
    };
    function ic(n){return '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'+IC[n]+'</svg>';}
    function wa(raw){var d=String(raw||"").replace(/\D/g,"").replace(/^0+/,"");if(d.length===8)d="65"+d;return d;}
    var lines=[];
    if(student.contact){var n=wa(student.contact);
      lines.push(n?'<a class="ii" href="https://wa.me/'+n+'" target="_blank" rel="noopener">'+ic("phone")+'<span>'+esc(student.contact)+'</span></a>'
                  :'<span class="ii">'+ic("phone")+'<span>'+esc(student.contact)+'</span></span>');}
    if(student.location)lines.push('<span class="ii">'+ic("pin")+'<span>'+esc(student.location)+'</span></span>');
    if(student.recipient_name)lines.push('<span class="ii">'+ic("msg")+'<span>Messages to <b>'+esc(student.recipient_name)+'</b></span></span>');
    if(student.notes)lines.push('<span class="ii">'+ic("note")+'<span>'+esc(student.notes)+'</span></span>');
    // Year only once the subjects carry their own G-level (older profiles may say "Sec 4 G3").
    var anyG=slots.some(function(x){return TL.subLevel(x.level)||TL.subLevel(x.subject);});
    var lvlTxt=anyG?TL.yearLevel(student.level):(student.level||"");
    var chips=(lvlTxt?'<span class="lvl">'+esc(lvlTxt)+'</span>':'')+
      (!student.active?'<span class="lvl off">Discontinued</span>':'')+
      (student.end_date&&student.active?'<span class="lvl soft">Until '+prettyDate(student.end_date)+'</span>':'');
    $("p-head").innerHTML='<div class="sp-chips">'+chips+
      (lines.length?'<button type="button" class="sp-moreb" id="sp-moreb" aria-expanded="false">More info <span aria-hidden="true">▾</span></button>':'')+
      '</div>'+(lines.length?'<div class="sp-info" id="sp-info">'+lines.join("")+'</div>':'');
    var mb=$("sp-moreb");
    if(mb)mb.addEventListener("click",function(){var o=$("p-head").classList.toggle("open");mb.setAttribute("aria-expanded",o?"true":"false");
      mb.firstChild.textContent=o?"Less info ":"More info ";mb.lastChild.textContent=o?"▴":"▾";});
    var w=String(student.name||"").split(/\s+/).filter(Boolean);
    if($("sp-av"))$("sp-av").textContent=((w[0]||"?")[0]+((w[1]||"")[0]||"")).toUpperCase();
    $("p-actions").innerHTML='<button class="btn" id="p-edit">Edit</button> <a class="btn" href="ledger">Ledger</a>';
    $("p-edit").addEventListener("click",openEdit);
    
  }
  function openEdit(){
    if(!student)return;
    $("e-name").value=student.name||"";
    $("e-level").value=student.level||"";$("e-contact").value=student.contact||"";
    $("e-location").value=student.location||"";
    $("e-recipient").value=student.recipient_name||"";$("e-notes").value=student.notes||"";
    if($("e-enddate"))$("e-enddate").value=student.end_date||"";
    $("e-msg").textContent="";$("e-msg").className="msg";
    $("e-modal").classList.add("on");
  }
  function closeEdit(){$("e-modal").classList.remove("on");}
  async function saveEdit(){
    var name=$("e-name").value.trim(),msg=$("e-msg");
    if(!name){msg.textContent="Give the student a name.";msg.className="msg err";return;}
    var b=$("e-save");b.disabled=true;
    var res=await window.sb.from("students").update({
      name:name,
      level:$("e-level").value.trim()||null,contact:$("e-contact").value.trim()||null,
      location:$("e-location").value.trim()||null,
      recipient_name:$("e-recipient").value.trim()||null,notes:$("e-notes").value.trim()||null,
      end_date:($("e-enddate")&&$("e-enddate").value)||null
    }).eq("id",sid);
    b.disabled=false;
    if(res.error){msg.textContent=res.error.message;msg.className="msg err";return;}
    closeEdit();load();
  }

  function renderKpis(lessons){
    // Keep a cancelled lesson out of these totals unless it carries a compensation fee
    // (already normalized into amount) — an uncompensated cancellation isn't billable.
    var live=lessons.filter(function(l){return l.status!=="cancelled"||l.amount>0;});
    var billed=live.reduce(function(t,l){return t+Number(l.amount);},0);
    var paid=live.filter(function(l){return l.paid;}).reduce(function(t,l){return t+Number(l.amount);},0);
    var outstanding=live.filter(function(l){return TL.isOwed(l);}).reduce(function(t,l){return t+Number(l.amount);},0);
    var done=lessons.filter(function(l){return l.status==="done";}).length;
    function kpi(label,val,cls){return '<div class="kpi"><div class="lbl">'+label+'</div><div class="val'+(cls?" "+cls:"")+'">'+val+'</div></div>';}
    $("p-kpis").innerHTML=
      kpi("Outstanding",TL.sgd(outstanding),outstanding>0?"owed":"")+
      kpi("Collected",TL.sgd(paid),"")+
      kpi("Total billed",TL.sgd(billed),"")+
      kpi("Lessons done",done,"");
  }

  function renderLessons(lessons){
    lessons.sort(function(a,b){return (b.lesson_date+ (b.start_time||"")).localeCompare(a.lesson_date+(a.start_time||""));});
    var table=$("p-ltable"),empty=$("p-lempty");
    if(!lessons.length){table.style.display="none";empty.style.display="block";$("p-lhint").textContent="";return;}
    empty.style.display="none";table.style.display="table";
    $("p-lhint").textContent=lessons.length+" total";
    $("p-lbody").innerHTML=lessons.map(function(l){
      var badge=l.status==="cancelled"
        ?'<span class="kind-tag">cancelled</span>'+(l.amount>0?(l.paid?' <span class="badge paid">Paid</span>':' <span class="badge owed">Unpaid</span>'):'')
        :(l.status==="scheduled"?'<span class="kind-tag">scheduled</span>':(l.paid?'<span class="badge paid">Paid</span>':(TL.noCharge(l)?'<span class="badge nocharge">No charge'+(l.charge_note?' · '+esc(l.charge_note):'')+'</span>':'<span class="badge owed">Unpaid</span>')));
      return '<tr data-lid="'+l.id+'"><td data-label="Date">'+prettyDate(l.lesson_date)+'</td>'+
        '<td data-label="Subject">'+(l.subject?esc(l.subject):'<span class="muted">—</span>')+'</td>'+
        '<td data-label="Amount">'+TL.sgd(l.amount)+'</td>'+
        '<td data-label="Status">'+badge+'</td>'+
        '<td class="acts"><button class="tact" data-led="'+l.id+'">Edit</button></td></tr>';
    }).join("");
    $("p-lbody").querySelectorAll("[data-led]").forEach(function(b){b.addEventListener("click",function(){openLesson(b.dataset.led);});});
    // Mobile: rows are compact — tapping one opens the edit sheet (buttons are hidden there).
    $("p-lbody").querySelectorAll("tr[data-lid]").forEach(function(tr){
      tr.addEventListener("click",function(e){
        if(!window.matchMedia("(max-width:820px)").matches)return;
        if(e.target.closest("a,button,input,label"))return;
        openLesson(tr.dataset.lid);
      });
    });
  }

  // Client view only: one clean list combining each lesson with its notes — no money, no editing.
  // Parent view headline: attendance, latest score per subject (with change), next exam. No money.
  function renderParentKpis(lessons, exams){
    var box=$("pv-kpis"); if(!box)return;
    var today=todayISO();
    var attended=lessons.filter(function(l){return l.status==="done";}).length;
    var scored=exams.filter(function(e){return e.score!=null&&e.max_score>0&&e.exam_date&&e.exam_date<=today;})
      .sort(function(a,b){return a.exam_date.localeCompare(b.exam_date);});
    var bySub={}; scored.forEach(function(e){(bySub[e.subject||"General"]=bySub[e.subject||"General"]||[]).push(Math.round(e.score/e.max_score*100));});
    var subs=Object.keys(bySub).slice(0,2);
    var next=exams.filter(function(e){return e.exam_date&&e.exam_date>=today;}).sort(function(a,b){return a.exam_date.localeCompare(b.exam_date);})[0];
    function cell(label,val,sub){return '<div class="kpi"><div class="lbl">'+label+'</div><div class="val">'+val+'</div>'+(sub?'<div class="sub">'+sub+'</div>':'')+'</div>';}
    var html=cell("Lessons attended",attended,"");
    subs.forEach(function(sname){var a=bySub[sname],last=a[a.length-1],prev=a.length>1?a[a.length-2]:null;
      var ch=prev==null?"":(last>prev?'<small class="up">▲ '+(last-prev)+'</small>':(last<prev?'<small class="down">▼ '+(prev-last)+'</small>':'<small>—</small>'));
      html+=cell("Latest · "+esc(sname),last+"%"+ch,"");});
    html+=next?cell("Next exam",prettyDate(next.exam_date),esc((next.assessment_type?next.assessment_type+" · ":"")+(next.subject||""))):cell("Next exam","—","none scheduled");
    box.innerHTML=html;
    box.dataset.n=String(2+subs.length);   // 2–4 cells; CSS lays them out per screen size
  }
  function renderClientLessons(lessons){
    var today=todayISO();
    var live=lessons.filter(function(l){return l.status!=="cancelled"&&l.lesson_date<=today;});
    live.sort(function(a,b){return (b.lesson_date+(b.start_time||"")).localeCompare(a.lesson_date+(a.start_time||""));});
    var box=$("p-lessons");
    if(!live.length){box.innerHTML='<p class="muted" style="font-size:13.5px;margin:0">No lessons yet.</p>';$("p-lhint2").textContent="";return;}
    $("p-lhint2").textContent=TL.plural(live.length,"lesson");
    box.innerHTML='<div class="nlist">'+live.map(function(l){
      var has=l.topics||l.homework||l.remarks,bits="";
      if(l.topics)bits+='<div class="nbits"><span class="nk">Topics</span>'+esc(l.topics)+'</div>';
      if(l.homework)bits+='<div class="nbits"><span class="nk">Homework</span>'+esc(l.homework)+'</div>';
      if(l.remarks)bits+='<div class="nbits"><span class="nk">Next</span>'+esc(l.remarks)+'</div>';
      if(!has)bits='<div class="nempty">No notes recorded</div>';
      return '<div class="nrow"><div class="nhead"><span class="nd">'+prettyDate(l.lesson_date)+(l.subject?' · '+esc(l.subject):"")+'</span></div>'+bits+'</div>';
    }).join("")+'</div>';
  }

  // ---- lesson edit ----
  function openLesson(id){
    var l=lessons.filter(function(x){return x.id===id;})[0];if(!l)return;
    lessonId=id;
    var cancelled=l.status==="cancelled";
    $("l-title").textContent="Edit lesson · "+prettyDate(l.lesson_date);
    $("l-date").value=l.lesson_date||"";$("l-subject").value=l.subject||"";
    // l.amount is already normalized to the compensation for a cancelled lesson, so this
    // field doubles as the compensation editor here — no separate UI needed.
    $("l-amount").value=(l.amount!=null?l.amount:"");$("l-paid").checked=!!l.paid;
    var lbl=$("l-amount-lbl");if(lbl)lbl.textContent=cancelled?"Compensation (S$)":"Amount (S$)";
    $("l-toggle").textContent=cancelled?"Restore lesson":"Cancel lesson";
    $("l-toggle").classList.remove("btn-danger");
    cancelConfirming=false;$("l-cancel-box").style.display="none";$("l-cancel-comp").value="";
    $("l-msg").textContent="";$("l-msg").className="msg";
    $("l-modal").classList.add("on");
  }
  function closeLesson(){$("l-modal").classList.remove("on");lessonId=null;}
  async function saveLesson(){
    var l=lessons.filter(function(x){return x.id===lessonId;})[0];if(!l)return;
    var date=$("l-date").value,paid=$("l-paid").checked,msg=$("l-msg");
    if(!date){msg.textContent="Set a date.";msg.className="msg err";return;}
    var val=Number($("l-amount").value)||0;
    var fields={lesson_date:date,subject:$("l-subject").value.trim()||null,paid:paid,paid_date:paid?date:null};
    if(l.status==="cancelled") fields.compensation=val>0?val:null;
    else fields.amount=val;
    var b=$("l-save");b.disabled=true;
    var res=await window.sb.from("lessons").update(fields).eq("id",lessonId);
    b.disabled=false;
    if(res.error){msg.textContent=res.error.message;msg.className="msg err";return;}
    closeLesson();load();
  }
  function abortCancel(){
    cancelConfirming=false;$("l-cancel-box").style.display="none";
    $("l-toggle").textContent="Cancel lesson";$("l-toggle").classList.remove("btn-danger");
  }
  async function toggleLesson(){
    var l=lessons.filter(function(x){return x.id===lessonId;})[0];if(!l)return;
    var fields;
    if(l.status==="cancelled"){
      fields={status:(l.lesson_date>todayISO())?"scheduled":"done",compensation:null};
    }else if(!cancelConfirming){
      // First click just reveals the (optional) compensation field — the second click,
      // now relabelled, actually cancels. No browser prompt.
      cancelConfirming=true;
      $("l-cancel-box").style.display="block";$("l-cancel-comp").focus();
      $("l-toggle").textContent="Confirm cancel";$("l-toggle").classList.add("btn-danger");
      return;
    }else{
      var comp=Math.max(0,parseFloat($("l-cancel-comp").value)||0);
      fields={status:"cancelled",paid:false,paid_date:null,compensation:comp>0?comp:null};
    }
    var res=await window.sb.from("lessons").update(fields).eq("id",lessonId);
    if(res.error){$("l-msg").textContent=res.error.message;$("l-msg").className="msg err";return;}
    closeLesson();load();
  }
  async function deleteLesson(){
    if(!(await TL.confirm({title:"Delete lesson",message:"Delete this lesson permanently? Use Cancel lesson instead if you just want to void it.",confirmText:"Delete",danger:true})))return;
    var res=await window.sb.from("lessons").delete().eq("id",lessonId);
    if(res.error){TL.alert("Couldn't delete: "+res.error.message);return;}
    closeLesson();load();
  }

  function renderNotes(rows){
    var live=rows.filter(function(l){return l.status!=="cancelled";});
    live.sort(function(a,b){return (b.lesson_date+(b.start_time||"")).localeCompare(a.lesson_date+(a.start_time||""));});
    if(!live.length){$("p-notes").innerHTML='<p class="muted" style="font-size:13.5px">No lessons to annotate yet.</p>';$("p-nhint").textContent="";return;}
    $("p-nhint").textContent=live.filter(function(l){return l.topics||l.homework||l.remarks;}).length+" of "+live.length;
    $("p-notes").innerHTML='<div class="nlist">'+live.map(function(l){
      var has=l.topics||l.homework||l.remarks,bits="";
      if(l.topics)bits+='<div class="nbits"><span class="nk">Topics</span>'+esc(l.topics)+'</div>';
      if(l.homework)bits+='<div class="nbits"><span class="nk">Homework</span>'+esc(l.homework)+'</div>';
      if(l.remarks)bits+='<div class="nbits"><span class="nk">Next</span>'+esc(l.remarks)+'</div>';
      if(!has)bits='<div class="nempty">No notes yet</div>';
      return '<div class="nrow"><div class="nhead"><span class="nd">'+prettyDate(l.lesson_date)+(l.subject?' · '+esc(l.subject):"")+'</span>'+
        '<button class="tact" data-note="'+l.id+'">'+(has?"Edit":"Add notes")+'</button></div>'+bits+'</div>';
    }).join("")+'</div>';
    $("p-notes").querySelectorAll("[data-note]").forEach(function(b){b.addEventListener("click",function(){openNotes(b.dataset.note);});});
  }
  function openNotes(id){
    var l=lessons.filter(function(x){return x.id===id;})[0];if(!l)return;
    noteId=id;
    $("n-title").textContent="Lesson notes · "+prettyDate(l.lesson_date);
    $("n-topics").value=l.topics||"";$("n-homework").value=l.homework||"";$("n-remarks").value=l.remarks||"";
    $("n-msg").textContent="";$("n-msg").className="msg";
    $("n-modal").classList.add("on");
  }
  function closeNotes(){$("n-modal").classList.remove("on");noteId=null;}
  async function saveNotes(){
    if(!noteId)return;
    var b=$("n-save");b.disabled=true;
    var res=await window.sb.from("lessons").update({
      topics:$("n-topics").value.trim()||null,
      homework:$("n-homework").value.trim()||null,
      remarks:$("n-remarks").value.trim()||null
    }).eq("id",noteId);
    b.disabled=false;
    if(res.error){$("n-msg").textContent=res.error.message;$("n-msg").className="msg err";return;}
    closeNotes();load();
  }

  function renderSlots(slots){
    var link='<a class="slink plink" href="planner">Manage on planner ›</a>';
    if(!slots.length){$("p-slots").innerHTML='<div class="slotwrap"><p class="muted" style="font-size:13.5px;margin:0 0 12px">No recurring slots yet.</p>'+link+'</div>';return;}
    slots.sort(function(a,b){return a.weekday-b.weekday||(a.start_time||"").localeCompare(b.start_time||"");});
    var rows=slots.map(function(s){
      return '<div class="slotline">'+
        '<span class="slt">'+DOW[s.weekday]+" "+hhmm(s.start_time)+"–"+hhmm(s.end_time)+'</span>'+
        '<span class="slsub">'+esc([s.subject, TL.subLevel(s.subject)?"":TL.subLevel(s.level)].filter(Boolean).join(" "))+'</span>'+
        '<span class="slc">'+TL.sgd(TL.amount(s.rate,hhmm(s.start_time),hhmm(s.end_time)))+'</span></div>';
    }).join("");
    $("p-slots").innerHTML='<div class="slotwrap">'+rows+link+'</div>';
  }

  // ---- Monthly schedule: a copy-ready list of this student's lessons for a month ----
  function isoD(d){function p(n){return(n<10?"0":"")+n;}return d.getFullYear()+"-"+p(d.getMonth()+1)+"-"+p(d.getDate());}
  function t12(t){ if(!t)return""; var p=t.split(":"),h=+p[0],mi=+p[1],ap=h>=12?"pm":"am",hr=h%12; if(hr===0)hr=12; return hr+(mi?":"+(mi<10?"0"+mi:mi):"")+ap; }
  // "16:00"–"18:00" → "4–6pm" (drops the first meridian when it matches the second)
  function timeRange(s,e){ var a=t12(hhmm(s)),b=t12(hhmm(e)); if(a.slice(-2)===b.slice(-2)) a=a.slice(0,-2); return a+"–"+b; }
  // Occurrences for the month. If the month has any LOGGED lessons, those ARE the schedule — we show
  // only the real rows (cancelled omitted) and never re-project the weekly slot, so a lesson moved to
  // another day can't leave a phantom on its old slot day. Only a month with nothing logged yet (e.g.
  // a future month) falls back to previewing the weekly slots.
  function schedFor(y,m){
    var first=isoD(new Date(y,m,1)), lastD=new Date(y,m+1,0), lastISO=isoD(lastD);
    var inMonth=lessons.filter(function(l){ return l.lesson_date>=first && l.lesson_date<=lastISO; });
    if(inMonth.length){
      return inMonth.filter(function(l){ return l.status!=="cancelled"; })
        .map(function(l){ return {date:l.lesson_date,start:l.start_time,end:l.end_time}; })
        .sort(function(a,b){ return (a.date+hhmm(a.start)).localeCompare(b.date+hhmm(b.start)); });
    }
    var items=[];
    for(var day=1;day<=lastD.getDate();day++){
      var dt=new Date(y,m,day), di=isoD(dt), wd=(dt.getDay()+6)%7;
      if(student && TL.pastEnd(student.end_date, di)) continue;   // stop projecting after the student's end date
      slots.forEach(function(s){ if(s.weekday===wd) items.push({date:di,start:s.start_time,end:s.end_time}); });
    }
    return items.sort(function(a,b){ return (a.date+hhmm(a.start)).localeCompare(b.date+hhmm(b.start)); });
  }
  function schedLine(it){ var d=new Date(it.date+"T00:00:00"); return d.getDate()+"/"+(d.getMonth()+1)+" ("+DOW[(d.getDay()+6)%7]+") "+timeRange(it.start,it.end); }
  function monthLabel(y,m){ return new Date(y,m,1).toLocaleString("en-SG",{month:"long",year:"numeric"}); }
  function scheduleMsg(y,m){
    var items=schedFor(y,m), mn=monthLabel(y,m);
    if(!items.length) return "No lessons scheduled for "+mn+".";
    return "Here are your lessons for "+mn+":\n\n"+items.map(schedLine).join("\n")+
      "\n\n"+items.length+" lesson"+(items.length===1?"":"s")+".";
  }
  function renderSchedule(){
    if(!$("sch-text"))return;
    if(schM==null){ var n=new Date(); schY=n.getFullYear(); schM=n.getMonth(); }
    var items=schedFor(schY,schM);
    if($("sch-label")) $("sch-label").textContent=monthLabel(schY,schM);
    $("sch-text").value=scheduleMsg(schY,schM);
    if($("sch-count")) $("sch-count").textContent=items.length+" lesson"+(items.length===1?"":"s");
  }
  function shiftSched(d){ var dt=new Date(schY,schM+d,1); schY=dt.getFullYear(); schM=dt.getMonth(); renderSchedule(); }
  async function copyText(text){
    try{ if(navigator.clipboard&&navigator.clipboard.writeText){ await navigator.clipboard.writeText(text); return true; } }catch(e){}
    try{ var ta=document.createElement("textarea"); ta.value=text; ta.style.position="fixed"; ta.style.top="-1000px"; ta.style.opacity="0";
      document.body.appendChild(ta); ta.focus(); ta.select(); var ok=document.execCommand("copy"); ta.remove(); return ok; }catch(e){ return false; }
  }
  function sendScheduleWA(){
    // Contacts aren't reliably linked yet — open WhatsApp with the text and let the tutor pick who
    // to send it to, rather than dialling a possibly-wrong saved number.
    window.open("https://api.whatsapp.com/send?text="+encodeURIComponent($("sch-text").value), "_blank");
  }

  function renderProgress(rows){
    var pts=rows.filter(function(e){return e.score!=null&&e.max_score>0&&e.exam_date;})
      .map(function(e){return {t:new Date(e.exam_date+"T00:00:00").getTime(),date:e.exam_date,pct:Math.round(e.score/e.max_score*100),subject:(e.subject||"General")};})
      .sort(function(a,b){return a.t-b.t;});
    var card=$("p-progress-card"), none=$("p-progress-empty");
    if(pts.length<2){ card.style.display="none"; if(none)none.style.display=""; return; }
    card.style.display=""; if(none)none.style.display="none";
    var narrow=window.innerWidth<600;   // phone: smaller canvas so text stays readable when scaled
    var W=narrow?340:520,H=narrow?200:230,padL=34,padR=narrow?84:96,padT=14,padB=26;
    var x0=padL,x1=W-padR,y0=H-padB,y1=padT;
    var tmin=pts[0].t,tmax=pts[pts.length-1].t; if(tmax===tmin)tmax=tmin+1;
    function X(t){return x0+(t-tmin)/(tmax-tmin)*(x1-x0);}
    function Y(p){return y0-(p/100)*(y0-y1);}
    // One colour per subject, fixed order (validated for colour-blind separation; see README v154).
    var colors=["#2a78d6","#eb6834","#6250d6","#e87ba4","#eda100","#1baf7a"];
    // group by subject
    var bySub={},order=[];
    pts.forEach(function(p){ if(!bySub[p.subject]){bySub[p.subject]=[];order.push(p.subject);} bySub[p.subject].push(p); });
    var svg='<svg viewBox="0 0 '+W+' '+H+'" width="100%" style="display:block" role="img" aria-label="Exam scores over time by subject">';
    // y gridlines 0/50/100
    [0,50,100].forEach(function(g){var y=Y(g);svg+='<line x1="'+x0+'" y1="'+y+'" x2="'+x1+'" y2="'+y+'" stroke="#E2DED5"/>'+
      '<text x="'+(x0-6)+'" y="'+(y+3)+'" text-anchor="end" font-size="9" fill="#6F7480">'+g+'%</text>';});
    // x labels (first + last date)
    svg+='<text x="'+x0+'" y="'+(H-8)+'" font-size="9" fill="#6F7480">'+prettyDate(pts[0].date)+'</text>'+
         '<text x="'+x1+'" y="'+(H-8)+'" text-anchor="end" font-size="9" fill="#6F7480">'+prettyDate(pts[pts.length-1].date)+'</text>';
    order.forEach(function(sub,i){
      var col=colors[i%colors.length],ps=bySub[sub];
      if(ps.length>1){
        var d=ps.map(function(p,j){return (j?"L":"M")+X(p.t).toFixed(1)+" "+Y(p.pct).toFixed(1);}).join(" ");
        svg+='<path d="'+d+'" fill="none" stroke="'+col+'" stroke-width="2"/>';
      }
      ps.forEach(function(p){svg+='<circle cx="'+X(p.t).toFixed(1)+'" cy="'+Y(p.pct).toFixed(1)+'" r="4" fill="'+col+'" stroke="#fff" stroke-width="1.5"><title>'+esc(sub)+" · "+prettyDate(p.date)+" · "+p.pct+'%</title></circle>';});
    });
    // direct labels at each line's end: subject + latest %, nudged apart so they never overlap
    var ends=order.map(function(sub,i){var ps=bySub[sub],l=ps[ps.length-1];return {sub:sub,col:colors[i%colors.length],x:X(l.t),y:Y(l.pct),pct:l.pct};})
      .sort(function(a,b){return a.y-b.y;});
    for(var k=1;k<ends.length;k++){ if(ends[k].y-ends[k-1].y<13) ends[k].y=ends[k-1].y+13; }
    ends.forEach(function(e){
      svg+='<circle cx="'+(x1+8)+'" cy="'+(e.y-3.5).toFixed(1)+'" r="3.5" fill="'+e.col+'"/>'+
           '<text x="'+(x1+15)+'" y="'+e.y.toFixed(1)+'" font-size="10.5" font-weight="700" fill="#13233F">'+esc(e.sub)+
           ' <tspan font-weight="500" fill="#5E6676">'+e.pct+'%</tspan></text>';
    });
    svg+='</svg>';
    var legend='<div style="display:flex;flex-wrap:wrap;gap:12px;margin-top:8px;font-size:12px">'+
      order.map(function(sub,i){return '<span style="display:inline-flex;align-items:center;gap:5px"><i style="width:10px;height:10px;border-radius:3px;background:'+colors[i%colors.length]+';display:inline-block"></i>'+esc(sub)+'</span>';}).join("")+'</div>';
    $("p-progress").innerHTML=svg+legend;
  }

  function renderExams(rows){
    if(!rows.length){$("p-exams").innerHTML='<p class="muted" style="font-size:13.5px">No exams yet.</p>';return;}
    var today=todayISO();
    rows.sort(function(a,b){return (a.exam_date||"").localeCompare(b.exam_date||"");});
    $("p-exams").innerHTML=rows.map(function(e){
      var past=e.exam_date&&e.exam_date<today, upcoming=e.exam_date&&e.exam_date>=today;
      var typ=e.assessment_type?'<span class="kind-tag">'+esc(e.assessment_type)+'</span> ':"";
      var resu=TL.examMarks(e.score,e.max_score) || (past?'<span class="muted">no result</span>':"");
      var topics=(upcoming&&e.topics)?'<span style="display:block;color:var(--muted);font-size:12px;margin-top:2px">Topics: '+esc(e.topics)+'</span>':"";
      var dim=(past&&e.score==null)?';opacity:.6':"";
      // date | subject+topics (flexes/shrinks, can be 2 lines) | marks+Edit locked together, top-aligned
      return '<div class="lrow" style="align-items:flex-start'+dim+'"><span class="lwhen">'+prettyDate(e.exam_date)+'</span>'+
        '<span style="flex:1;min-width:0">'+typ+(e.subject?esc(e.subject):"")+topics+'</span>'+
        '<span class="right" style="flex:none;display:flex;align-items:center;gap:8px;white-space:nowrap">'+(resu||"")+'<button class="tact" data-xed="'+e.id+'">Edit</button></span></div>';
    }).join("");
    $("p-exams").querySelectorAll("[data-xed]").forEach(function(b){b.addEventListener("click",function(){openExam(b.dataset.xed);});});
  }

  // ---- exam edit ----
  function openExam(id){
    var e=id?exams.filter(function(x){return x.id===id;})[0]:null;
    examId=e?e.id:null;
    $("x-title").textContent=e?"Edit exam":"Add exam";
    $("x-del").style.display=e?"":"none";
    $("x-date").value=e?(e.exam_date||""):"";
    $("x-type").value=e?(e.assessment_type||""):"";
    $("x-subject").value=e?(e.subject||""):(function(){
      var last=exams.filter(function(x){return x.subject;}).sort(function(a,b){return (b.exam_date||"").localeCompare(a.exam_date||"");})[0];
      if(last)return last.subject;
      var sl=(slots||[]).filter(function(x){return x.subject;})[0]; if(sl)return sl.subject;
      var ls=(lessons||[]).filter(function(x){return x.subject;}).sort(function(a,b){return (b.lesson_date||"").localeCompare(a.lesson_date||"");})[0];
      return ls?ls.subject:"";
    })();
    $("x-topics").value=e?(e.topics||""):"";
    $("x-remarks").value=e?(e.remarks||""):"";
    $("x-score").value=e&&e.score!=null?e.score:"";
    $("x-maxscore").value=e&&e.max_score!=null?e.max_score:"";
    $("x-msg").textContent="";$("x-msg").className="msg";
    $("x-modal").classList.add("on");
  }
  function closeExam(){$("x-modal").classList.remove("on");examId=null;}
  async function saveExam(){
    var date=$("x-date").value,msg=$("x-msg");
    if(!date){msg.textContent="Set an exam date.";msg.className="msg err";return;}
    var fields={exam_date:date,assessment_type:$("x-type").value.trim()||null,
      subject:$("x-subject").value.trim()||null,topics:$("x-topics").value.trim()||null,
      remarks:$("x-remarks").value.trim()||null,
      score:$("x-score").value!==""?parseFloat($("x-score").value):null,
      max_score:$("x-maxscore").value!==""?parseFloat($("x-maxscore").value):null};
    var b=$("x-save");b.disabled=true;
    var res=examId
      ? await window.sb.from("exams").update(fields).eq("id",examId)
      : await window.sb.from("exams").insert(Object.assign({tutor_id:userId,student_id:sid},fields));
    b.disabled=false;
    if(res.error){msg.textContent=res.error.message;msg.className="msg err";return;}
    closeExam();load();
  }
  async function deleteExam(){
    if(!examId||!(await TL.confirm({title:"Delete this exam?",message:"Its date, topics and marks will be removed, and it drops off the progress chart.",confirmText:"Delete exam",danger:true})))return;
    var res=await window.sb.from("exams").delete().eq("id",examId);
    if(res.error){TL.alert("Couldn't delete: "+res.error.message);return;}
    closeExam();load();
  }

  function init(user){
    userId=user.id;
    $("n-cancel").addEventListener("click",closeNotes);
    $("n-modal").addEventListener("click",function(e){if(e.target===$("n-modal"))closeNotes();});
    $("n-save").addEventListener("click",saveNotes);
    $("e-cancel").addEventListener("click",closeEdit);
    $("e-modal").addEventListener("click",function(e){if(e.target===$("e-modal"))closeEdit();});
    $("e-save").addEventListener("click",saveEdit);
    TL.wirePostal("e-postal-btn","e-location","e-postal-msg");
    $("l-save").addEventListener("click",saveLesson);
    $("l-toggle").addEventListener("click",toggleLesson);
    $("l-cancel-abort").addEventListener("click",abortCancel);
    $("l-del").addEventListener("click",deleteLesson);
    $("l-modal").addEventListener("click",function(e){if(e.target===$("l-modal"))closeLesson();});
    if($("sch-prev")) $("sch-prev").addEventListener("click",function(){shiftSched(-1);});
    if($("sch-next")) $("sch-next").addEventListener("click",function(){shiftSched(1);});
    if($("sch-copy")) $("sch-copy").addEventListener("click",async function(){
      var b=$("sch-copy"), ok=await copyText($("sch-text").value);
      if(ok){ var o=b.textContent; b.textContent="Copied ✓"; setTimeout(function(){b.textContent=o;},1400); }
    });
    if($("sch-wa")) $("sch-wa").addEventListener("click",sendScheduleWA);
    $("p-addexam").addEventListener("click",function(){openExam(null);});
    $("x-save").addEventListener("click",saveExam);
    $("x-close").addEventListener("click",closeExam);
    $("x-del").addEventListener("click",deleteExam);
    $("x-modal").addEventListener("click",function(e){if(e.target===$("x-modal"))closeExam();});
    // Tutor / Client view — Client hides money + editing so the page can be shown to a parent.
    function setViewMode(client){
      var v=$("view")||document.body; v.classList.toggle("client",client);
      // parent view opens on Progress; leaving it returns to Lessons
      var pane=document.querySelector(client?'#sp-tabs [data-tab="progress"]':'#sp-tabs [data-tab="lessons"]'); if(pane)pane.click();
      window.scrollTo(0,0);
      var t=$("vm-tutor"),c=$("vm-client"); if(t)t.classList.toggle("on",!client); if(c)c.classList.toggle("on",client);
    }
    // The app-wide Client view switch drives this page too (it used to be a page-only "Parent view").
    if($("vm-tutor"))$("vm-tutor").addEventListener("click",function(){TL.setClient(false);});
    if($("vm-client"))$("vm-client").addEventListener("click",function(){TL.setClient(true);});
    // Client view only hides money here (see student.html); notes and editing stay usable mid-lesson.
    // Tabs: Lessons · Notes · Progress · Schedule (remembered per browser)
    function setTab(t){
      document.querySelectorAll("#sp-tabs [data-tab]").forEach(function(b){b.classList.toggle("on",b.dataset.tab===t);});
      document.querySelectorAll(".sp-pane").forEach(function(p){p.classList.toggle("on",p.dataset.pane===t);});
      try{sessionStorage.setItem("td_stab_"+(qid()||""),t);}catch(e){}
    }
    document.querySelectorAll("#sp-tabs [data-tab]").forEach(function(b){b.addEventListener("click",function(){setTab(b.dataset.tab);});});
    // Each student opens on Lessons, unless you were on another tab for *this* student earlier in this
    // visit (e.g. Notes, went to Ledger, came back). A link can ask for a tab with ?tab=notes.
    var st="lessons", qt=(location.search.match(/[?&]tab=(\w+)/)||[])[1];
    if(qt && document.querySelector('#sp-tabs [data-tab="'+qt+'"]')) st=qt;
    else { try{st=sessionStorage.getItem("td_stab_"+(qid()||""))||"lessons";}catch(e){} }
    setTab(st);
    load();
  }
  TL.requireAuth("student",init);
})();