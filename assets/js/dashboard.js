// Dashboard — live KPIs, income-by-month chart, upcoming exam countdown.
(function () {
  var $ = function (id) { return document.getElementById(id); };
  // Shared by Home (home.html) and Money → Insights (insights.html); each page only has some of
  // these elements, so writes go through setText, which skips anything that isn't on the page.
  function setText(id, v){ var el=$(id); if(el) el.textContent=v; }
  function pad(n){return (n<10?"0":"")+n;}
  function iso(d){return d.getFullYear()+"-"+pad(d.getMonth()+1)+"-"+pad(d.getDate());}
  function todayISO(){return iso(new Date());}
  function esc(s){return String(s==null?"":s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");}
  function hm(t){return t?t.slice(0,5):"";}
  function monthOccurrences(weekday){var now=new Date(),y=now.getFullYear(),m=now.getMonth(),c=0,d=new Date(y,m,1);while(d.getMonth()===m){if(((d.getDay()+6)%7)===weekday)c++;d.setDate(d.getDate()+1);}return c;}

  var MONTHS=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
  var chartObj=null, yearChartObj=null, allLessons=[], nameByIdM={}, selY=null, selM=null, dmWired=false;
  var fyStart=1, fyAnchor=null, finSub="month", finSubWired=false;
  var userId=null, tnWired=false, lessonsById={}, noteLes=null;

  function drawStacked(canvasId, labels, collected, pending, upcoming, prev){
    var r2=function(v){return Math.round(v*100)/100;};
    var ctx=$(canvasId).getContext("2d");
    if(prev)prev.destroy();
    return new Chart(ctx,{
      type:"bar",
      data:{labels:labels,datasets:[
        {label:"Collected",data:collected.map(r2),backgroundColor:"#0F766E",maxBarThickness:34,stack:"s",borderRadius:3},
        {label:"Pending payment",data:pending.map(r2),backgroundColor:"#B4432F",maxBarThickness:34,stack:"s",borderRadius:3},
        {label:"Projected (upcoming)",data:upcoming.map(r2),backgroundColor:"#C9C5BC",maxBarThickness:34,stack:"s",borderRadius:3}
      ]},
      options:{
        responsive:true,maintainAspectRatio:false,
        plugins:{
          legend:{display:true,position:"bottom",labels:{boxWidth:12,boxHeight:12,font:{size:11},padding:14}},
          tooltip:{callbacks:{label:function(c){return c.dataset.label+": "+TL.sgd(c.parsed.y);}}}
        },
        scales:{
          x:{stacked:true,grid:{display:false}},
          y:{stacked:true,beginAtZero:true,ticks:{callback:function(v){return "$"+v;}},grid:{color:"#ECE9E2"}}
        }
      }
    });
  }
  function renderMonthKpis(){
    var mFirst=selY+"-"+pad(selM+1)+"-01",mLast=selY+"-"+pad(selM+1)+"-"+pad(new Date(selY,selM+1,0).getDate());
    var month=allLessons.filter(function(l){return l.lesson_date>=mFirst&&l.lesson_date<=mLast;});
    // No cancelled-exclusion needed: a cancelled lesson's amount is already normalized to
    // its compensation (0 if none), so this sums correctly either way.
    var projected=month.reduce(function(t,l){return t+Number(l.amount);},0);
    var collected=month.filter(function(l){return l.paid;}).reduce(function(t,l){return t+Number(l.amount);},0);
    setText("k-projected",TL.sgd(projected)); setText("mc-booked",TL.sgd(projected));
    setText("k-collected",TL.sgd(collected));
    // collection progress: collected (teal) + owed (red) + upcoming (grey remainder)
    var owed=month.filter(function(l){return !l.paid&&(l.status==="done"||(l.status==="cancelled"&&l.amount>0));}).reduce(function(t,l){return t+Number(l.amount);},0);
    var upcoming=Math.max(0,projected-collected-owed);
    var pct=projected>0?Math.round(collected/projected*100):0;
    var owedPct=projected>0?Math.round(owed/projected*100):0;
    if($("mprog-fill"))$("mprog-fill").style.width=Math.min(100,pct)+"%";
    if($("mprog-owed"))$("mprog-owed").style.width=Math.min(100-Math.min(100,pct),owedPct)+"%";
    if($("mprog-pct"))$("mprog-pct").textContent=projected>0?pct+"%":"—";
    if($("mprog-c"))$("mprog-c").textContent=TL.sgd(collected);
    if($("mprog-o"))$("mprog-o").textContent=TL.sgd(owed);
    if($("mprog-u"))$("mprog-u").textContent=TL.sgd(upcoming);
    if($("mprog-legend"))$("mprog-legend").style.display=projected>0?"flex":"none";
    if($("mprog-sub"))$("mprog-sub").textContent=projected>0
      ? TL.sgd(collected)+" collected of "+TL.sgd(projected)+" booked this month"
      : "No lessons booked this month yet.";
    var d1=new Date(selY,selM,1);
    setText("k-collected-n",d1.toLocaleString("en-SG",{month:"long"}));
    if($("dm-label"))$("dm-label").textContent=d1.toLocaleString("en-SG",{month:"long",year:"numeric"});
  }
  function stepDMonth(d){var dt=new Date(selY,selM+d,1);selY=dt.getFullYear();selM=dt.getMonth();renderMonthKpis();}

  function renderExams(exams, nameById, listId, hintId){
    var today=todayISO();
    var up=exams.filter(function(e){return e.exam_date&&e.exam_date>=today;})
                .sort(function(a,b){return a.exam_date.localeCompare(b.exam_date);}).slice(0,7);
    if(hintId&&$(hintId))$(hintId).textContent=up.length?up.length+" ahead":"";
    if(!up.length){$(listId).innerHTML='<div class="muted" style="font-size:13.5px">No upcoming exams.</div>';return;}
    var now=new Date(); now.setHours(0,0,0,0);
    $(listId).innerHTML=up.map(function(e){
      var d=new Date(e.exam_date+"T00:00:00");
      var days=Math.round((d-now)/86400000);
      var soon=days<=14;
      var label=[e.assessment_type,e.subject].filter(Boolean).join(" · ")||"exam";
      var mk=TL.examMarks(e.score,e.max_score);
      var extra=[]; if(e.topics)extra.push(esc(e.topics)); if(mk)extra.push(mk);
      var sub=esc(label)+(extra.length?" — "+extra.join(" · "):"");
      return '<a class="exam-row" href="exams?highlight='+esc(String(e.id))+'"><div class="ex-main"><div class="ex-name">'+esc(nameById[e.student_id]||"—")+'</div><div class="ex-sub">'+sub+'</div></div>'+
        '<div class="days'+(soon?" soon":"")+'"><b>'+days+'</b><small>'+(days===1?"day":"days")+'</small></div></a>';
    }).join("");
  }

  function shortDate(d){return new Date(d+"T00:00:00").toLocaleDateString("en-SG",{day:"numeric",month:"short"});}
  function summarizeOne(l, subjLabel){
    if(!l) return '<div class="tr-empty">No previous '+(subjLabel?esc(subjLabel)+' ':'')+'lesson recorded.</div>';
    var head="Last "+(l.subject?esc(l.subject)+" ":"")+"lesson · "+shortDate(l.lesson_date);
    var parts=[];
    if(l.topics)   parts.push('<div class="tr-note"><b>Topics:</b> '+esc(l.topics)+'</div>');
    if(l.homework) parts.push('<div class="tr-note"><b>Homework:</b> '+esc(l.homework)+'</div>');
    if(l.remarks)  parts.push('<div class="tr-note"><b>Remarks:</b> '+esc(l.remarks)+'</div>');
    return '<div class="tr-when">'+head+'</div>'+(parts.length?parts.join(""):'<div class="tr-empty">No notes from that lesson.</div>');
  }
  // This lesson's own note (once one is written, it replaces the "last lesson" recap on the row)
  function ownNote(l, label){
    var parts=[];
    if(l.topics)   parts.push('<div class="tr-note"><b>Topics:</b> '+esc(l.topics)+'</div>');
    if(l.homework) parts.push('<div class="tr-note"><b>Homework:</b> '+esc(l.homework)+'</div>');
    if(l.remarks)  parts.push('<div class="tr-note"><b>Remarks:</b> '+esc(l.remarks)+'</div>');
    return parts.length?'<div class="tr-when">'+label+'</div>'+parts.join(""):"";
  }
  function renderTeaching(lessons, nameById, exams){
    var doneByStu={};
    lessons.forEach(function(l){ if(l.status!=="done")return; (doneByStu[l.student_id]=doneByStu[l.student_id]||[]).push(l); });
    Object.keys(doneByStu).forEach(function(k){doneByStu[k].sort(function(a,b){return b.lesson_date.localeCompare(a.lesson_date);});});
    var today=new Date(); today.setHours(0,0,0,0);
    var tmr=new Date(today); tmr.setDate(today.getDate()+1);
    var todayISOv=iso(today);
    // last done lesson before a date, matching subject when the upcoming lesson has one
    function lastBeforeSubject(stu, beforeISO, subject){
      var a=doneByStu[stu]||[], subj=(subject||"").trim().toLowerCase();
      for(var i=0;i<a.length;i++){
        if(a[i].lesson_date>=beforeISO)continue;
        if(!subj)return a[i];
        if((a[i].subject||"").trim().toLowerCase()===subj)return a[i];
      }
      return null;
    }
    // upcoming exams by student
    var examsByStu={};
    (exams||[]).forEach(function(e){ if(e.exam_date&&e.exam_date>=todayISOv){ (examsByStu[e.student_id]=examsByStu[e.student_id]||[]).push(e); } });
    Object.keys(examsByStu).forEach(function(k){examsByStu[k].sort(function(a,b){return a.exam_date.localeCompare(b.exam_date);});});
    function examChips(stu){
      var up=examsByStu[stu]||[]; if(!up.length)return "";
      var items=up.slice(0,3).map(function(e){
        var d=new Date(e.exam_date+"T00:00:00"), days=Math.round((d-today)/86400000);
        var lbl=[e.assessment_type,e.subject].filter(Boolean).join(" ")||"Exam";
        var mk=TL.examMarks(e.score,e.max_score);
        var top=e.topics?'<span class="ex-t" title="'+esc(e.topics)+'">'+esc(e.topics)+'</span>':"";
        return '<a class="exchip" href="exams?highlight='+esc(String(e.id))+'"><span class="ex-l">'+esc(lbl)+(mk?' <span class="ex-m">'+mk+'</span>':'')+'</span>'+
          '<span class="ex-d">'+shortDate(e.exam_date)+' · '+(days<=0?"today":"in "+days+"d")+'</span>'+top+'</a>';
      }).join("");
      return '<div class="tr-exams"><div class="tr-exh">Upcoming exams</div>'+items+'</div>';
    }
    // Today/Tomorrow are ledger-only: only lessons actually logged (any status but
    // cancelled) show up here. A Planner slot with no lesson row yet — e.g. a schedule
    // change saved ahead of its effective week — deliberately does not appear; you're
    // expected to log lessons in advance (Ledger "Log this week/month", or the Calendar's
    // "Log this lesson"), so an un-logged slot isn't yet a real commitment for that date.
    lessonsById={}; lessons.forEach(function(l){lessonsById[l.id]=l;});
    function renderDay(listId, subId, headId, dateObj, label, withNote){
      var dISO=iso(dateObj);
      var day=lessons.filter(function(l){return l.lesson_date===dISO&&l.status!=="cancelled";})
        .sort(function(a,b){return (a.start_time||"").localeCompare(b.start_time||"");});
      if($(headId))$(headId).textContent=label;
      if($(subId))$(subId).textContent=dateObj.toLocaleDateString("en-SG",{weekday:"long",day:"numeric",month:"long"});
      if(!day.length){$(listId).innerHTML='<div class="tr-empty">No lessons scheduled.</div>';return;}
      $(listId).innerHTML=day.map(function(l){
        var btn="";
        if(withNote){
          var has=l.topics||l.homework||l.remarks;
          btn='<button class="tnote'+(has?" has":"")+'" data-note-id="'+l.id+'">'+(has?"Edit note":"Add note")+'</button>';
        }
        return '<div class="teach-row"><div class="tr-time">'+hm(l.start_time)+'</div>'+
          '<div class="tr-body">'+
          '<div class="tr-head"><div class="tr-name"><a class="snl" href="student?id='+l.student_id+'">'+esc(nameById[l.student_id]||"—")+'</a>'+
          (l.subject?'<span class="tr-subj">'+esc(l.subject)+'</span>':'')+'</div>'+btn+'</div>'+
          '<div class="tr-cols"><div class="tr-notes">'+(ownNote(l,label+"\u2019s note")||summarizeOne(lastBeforeSubject(l.student_id,dISO,l.subject),l.subject))+'</div>'+examChips(l.student_id)+'</div>'+
          '</div></div>';
      }).join("");
      if(withNote)$(listId).querySelectorAll("[data-note-id]").forEach(function(b){b.addEventListener("click",function(){openNote(b.dataset.noteId);});});
    }
    // Past 7 days — lessons already taught (not cancelled) that still have no notes
    (function(){
      var DAYS_BACK=7;
      var from=new Date(today); from.setDate(today.getDate()-DAYS_BACK);
      var fromISO=iso(from), todayISO=iso(today);
      var missing=lessons.filter(function(l){
        return l.lesson_date>=fromISO && l.lesson_date<todayISO && l.status!=="cancelled" &&
               !(l.topics||l.homework||l.remarks);
      }).sort(function(a,b){   // most recent day first, then by time within the day
        return b.lesson_date.localeCompare(a.lesson_date)||(a.start_time||"").localeCompare(b.start_time||"");
      });
      var sec=$("yday-sec"); if(!sec)return;
      if(!missing.length){ sec.style.display="none"; return; }
      sec.style.display="";
      $("yday-hint").textContent=window.innerWidth<=820?String(missing.length):missing.length+" without notes";
      $("yday-sub").textContent="Past "+DAYS_BACK+" days · "+
        from.toLocaleDateString("en-SG",{day:"numeric",month:"short"})+" – "+
        new Date(today.getTime()-86400000).toLocaleDateString("en-SG",{day:"numeric",month:"short"});
      var lastDay=null;
      $("yday-list").innerHTML=missing.map(function(l){
        var head="";
        if(l.lesson_date!==lastDay){
          lastDay=l.lesson_date;
          var d=new Date(l.lesson_date+"T00:00:00"), ago=Math.round((today-d)/86400000);
          head='<div class="miss-day">'+d.toLocaleDateString("en-SG",{weekday:"short",day:"numeric",month:"short"})+
               '<span>'+(ago===1?"yesterday":ago+" days ago")+'</span></div>';
        }
        return head+'<div class="teach-row"><div class="tr-time">'+hm(l.start_time)+'</div>'+
          '<div class="tr-body"><div class="tr-head"><div class="tr-name"><a class="snl" href="student?id='+l.student_id+'">'+esc(nameById[l.student_id]||"—")+'</a>'+
          (l.subject?'<span class="tr-subj">'+esc(l.subject)+'</span>':'')+'</div>'+
          '<button class="tnote" data-note-id="'+l.id+'">Add note</button></div>'+
          '</div></div>';
      }).join("");
      $("yday-list").querySelectorAll("[data-note-id]").forEach(function(b){
        b.addEventListener("click",function(){openNote(b.dataset.noteId);});
      });
    })();
    renderDay("today-list","today-sub","today-h", today, "Today", true);
    renderDay("tmr-list","tmr-sub","tmr-h", tmr, "Tomorrow", false);
  }

  // ---- quick lesson note (today / yesterday) ----
  function openNote(lessonId){
    var les=lessonsById[lessonId]||null; noteLes=les;
    var dISO=les?les.lesson_date:iso(new Date());
    var name=nameByIdM[les?les.student_id:null]||"student";
    var dObj=new Date(dISO+"T00:00:00");
    var when=dObj.toLocaleDateString("en-SG",{weekday:"long",day:"numeric",month:"long"});
    var isToday=dISO===iso(new Date());
    var subj=les&&les.subject?les.subject:"";
    $("tn-title").textContent=(isToday?"Today's note · ":"Note · ")+name;
    $("tn-sub").textContent=when+(subj?" · "+subj:"");
    $("tn-topics").value=les?(les.topics||""):"";
    $("tn-homework").value=les?(les.homework||""):"";
    $("tn-remarks").value=les?(les.remarks||""):"";
    $("tn-msg").textContent=""; $("tn-msg").className="msg";
    $("tn-modal").classList.add("on");
  }
  function closeNote(){$("tn-modal").classList.remove("on");}
  async function saveNote(){
    var msg=$("tn-msg");
    if(!noteLes){msg.textContent="Couldn't find that lesson."; msg.className="msg err"; return;}
    var fields={topics:$("tn-topics").value.trim()||null,homework:$("tn-homework").value.trim()||null,remarks:$("tn-remarks").value.trim()||null};
    $("tn-save").disabled=true;
    var res=await window.sb.from("lessons").update(fields).eq("id",noteLes.id);
    $("tn-save").disabled=false;
    if(res.error){msg.textContent=res.error.message; msg.className="msg err"; return;}
    closeNote();
    load();
  }

  var segWired=false;
  function setDashMode(mode){
    var teach=mode==="teach";
    if($("fin-view"))$("fin-view").style.display=teach?"none":"block";
    if($("teach-view"))$("teach-view").style.display=teach?"block":"none";
    if($("seg-fin"))$("seg-fin").classList.toggle("on",!teach);
    if($("seg-teach"))$("seg-teach").classList.toggle("on",teach);
    try{TL.store.set("tl_dash_mode",mode);}catch(e){}
  }

  // ---- Financial year ----
  function fyMonthsOf(anchor){var arr=[],base=fyStart-1;for(var i=0;i<12;i++){var mm=base+i;arr.push({y:anchor+Math.floor(mm/12),m:((mm%12)+12)%12});}return arr;}
  function fyLabelOf(anchor){return fyStart===1?String(anchor):("FY "+anchor+"/"+String(anchor+1).slice(2));}
  function currentFyAnchor(){var n=new Date();return (n.getMonth()>=(fyStart-1))?n.getFullYear():n.getFullYear()-1;}
  function mkey(o){return o.y+"-"+pad(o.m+1);}

  function collectedInFy(anchor){
    var keys={};fyMonthsOf(anchor).forEach(function(o){keys[mkey(o)]=1;});
    return allLessons.reduce(function(t,l){
      return (l.paid && l.lesson_date && keys[l.lesson_date.slice(0,7)]) ? t+Number(l.amount) : t;
    },0);
  }

  function renderYear(){
    if($("fy-label"))$("fy-label").textContent=fyLabelOf(fyAnchor);
    var months=fyMonthsOf(fyAnchor), keys={}; months.forEach(function(o){keys[mkey(o)]=1;});
    // Keep a cancelled lesson out of the taught/billed counts below unless it carries a
    // compensation fee (already normalized into amount) — an uncompensated cancellation
    // isn't a lesson taught or billed.
    var rows=allLessons.filter(function(l){return l.lesson_date&&keys[l.lesson_date.slice(0,7)]&&(l.status!=="cancelled"||l.amount>0);});

    var collected=0,owed=0,upc=0,doneCount=0,doneBilled=0;
    var perMonth={}, perStudent={}, perSubject={};
    months.forEach(function(o){perMonth[mkey(o)]={c:0,p:0,u:0};});
    rows.forEach(function(l){
      var amt=Number(l.amount)||0, k=l.lesson_date.slice(0,7), pm=perMonth[k];
      if(l.paid){collected+=amt; if(pm)pm.c+=amt;}
      else if(l.status==="done"){owed+=amt; if(pm)pm.p+=amt;}
      else {upc+=amt; if(pm)pm.u+=amt;}
      if(l.status==="done"){doneCount++; doneBilled+=amt;}
      var s=perStudent[l.student_id]||(perStudent[l.student_id]={c:0,owe:0,n:0});
      s.n++; if(l.paid)s.c+=amt; else if(l.status==="done")s.owe+=amt;
      var subj=[l.subject,l.level].filter(Boolean).join(" · ")||"Unspecified", ps=perSubject[subj]||(perSubject[subj]={c:0,n:0});
      ps.n++; if(l.paid)ps.c+=amt;
    });
    var billed=collected+owed+upc, due=collected+owed;
    var rate=due>0?Math.round(collected/due*100):0;
    var activeMonths=months.filter(function(o){return perMonth[mkey(o)].c>0;}).length;
    var avgMonth=activeMonths?collected/activeMonths:0;
    var avgLesson=doneCount?doneBilled/doneCount:0;
    var prevCollected=collectedInFy(fyAnchor-1);
    var yoy=prevCollected>0?Math.round((collected-prevCollected)/prevCollected*100):null;

    // best / quietest month by collected
    var mv=months.map(function(o){return {k:mkey(o),y:o.y,m:o.m,v:perMonth[mkey(o)].c};}).filter(function(x){return x.v>0;});
    function mname(x){return new Date(x.y,x.m,1).toLocaleDateString("en-SG",{month:"short"});}
    var best=mv.length?mv.reduce(function(a,b){return b.v>a.v?b:a;}):null;
    var quiet=mv.length?mv.reduce(function(a,b){return b.v<a.v?b:a;}):null;
    if($("fy-chart-hint"))$("fy-chart-hint").textContent=best?("Best "+mname(best)+" "+TL.sgd(best.v)+" · Quietest "+mname(quiet)+" "+TL.sgd(quiet.v)):"";

    var yoyNote = yoy===null ? "vs last year: n/a" : (yoy>=0?"▲ "+yoy+"% vs last year":"▼ "+Math.abs(yoy)+"% vs last year");
    var tiles=[
      {cls:"paid",  label:"Total collected", val:TL.sgd(collected), note:yoyNote},
      {cls:"",      label:"Total billed",    val:TL.sgd(billed),    note:"incl. upcoming "+TL.sgd(upc)},
      {cls:"owed",  label:"Outstanding (owed)", val:TL.sgd(owed),  note:"delivered but unpaid"},
      {cls:"accent",label:"Collection rate", val:rate+"%",          note:"of "+TL.sgd(due)+" due"},
      {cls:"",      label:"Avg / active month", val:TL.sgd(avgMonth), note:activeMonths+" active month(s)"},
      {cls:"",      label:"Lessons taught",  val:String(doneCount), note:"avg "+TL.sgd(avgLesson)+"/lesson"}
    ];
    $("fy-tiles").innerHTML=tiles.map(function(t){
      return '<div class="card kpi '+t.cls+'"><div class="label">'+t.label+'</div>'+
        '<div class="val">'+t.val+'</div><div class="note">'+t.note+'</div></div>';
    }).join("");

    // per-student breakdown (by collected desc)
    var sList=Object.keys(perStudent).map(function(id){var s=perStudent[id];return {id:id,name:nameByIdM[id]||"—",c:s.c,owe:s.owe,n:s.n};})
      .sort(function(a,b){return b.c-a.c||b.owe-a.owe;});
    $("fy-students").innerHTML=sList.length?sList.map(function(s){
      return '<div class="brk"><span class="bn"><a class="snl" href="student?id='+s.id+'">'+esc(s.name)+'</a><div class="bmeta">'+s.n+' lesson'+(s.n===1?"":"s")+'</div></span>'+
        '<span class="bv">'+TL.sgd(s.c)+(s.owe>0?'<small>owed '+TL.sgd(s.owe)+'</small>':'')+'</span></div>';
    }).join(""):'<div class="muted" style="font-size:13.5px">No income recorded for this year.</div>';

    // per-subject breakdown
    var subjList=Object.keys(perSubject).map(function(k){return {name:k,c:perSubject[k].c,n:perSubject[k].n};})
      .sort(function(a,b){return b.c-a.c;});
    $("fy-subjects").innerHTML=subjList.length?subjList.map(function(s){
      return '<div class="brk"><span class="bn">'+esc(s.name)+'<div class="bmeta">'+s.n+' lesson'+(s.n===1?"":"s")+'</div></span>'+
        '<span class="bv">'+TL.sgd(s.c)+'</span></div>';
    }).join(""):'<div class="muted" style="font-size:13.5px">—</div>';

    // FY-ordered chart
    var labels=months.map(function(o){return new Date(o.y,o.m,1).toLocaleDateString("en-SG",{month:"short"});});
    var yc=months.map(function(o){return perMonth[mkey(o)].c;}),
        yp=months.map(function(o){return perMonth[mkey(o)].p;}),
        yu=months.map(function(o){return perMonth[mkey(o)].u;});
    if(window.Chart)yearChartObj=drawStacked("yearChart",labels,yc,yp,yu,yearChartObj);
  }
  function stepFy(d){fyAnchor+=d;renderYear();}
  function setFinSub(mode){
    var year=mode==="year";
    if($("fin-month"))$("fin-month").style.display=year?"none":"block";
    if($("fin-year"))$("fin-year").style.display=year?"block":"none";
    if($("fseg-month"))$("fseg-month").classList.toggle("on",!year);
    if($("fseg-year"))$("fseg-year").classList.toggle("on",year);
    finSub=mode;
    try{TL.store.set("tl_fin_sub",mode);}catch(e){}
    if(year)renderYear();   // render while visible so the chart sizes correctly
  }

  // Skeleton placeholders show the page's shape while data loads; real content replaces them in place.
  function doneLoading(){ document.querySelectorAll(".sk-on").forEach(function(e){ e.classList.remove("sk-on"); }); }
  async function load(){
    try { await loadInner(); } finally { doneLoading(); }
  }
  async function loadInner(){
    await TL.promotePastLessons();
    var st=await window.sb.from("students").select("id,name");
    var nameById={};(st.data||[]).forEach(function(s){nameById[s.id]=s.name;});
    nameByIdM=nameById;

    userId=(await window.sb.auth.getUser()).data.user.id;
    var pr=await window.sb.from("profiles").select("fy_start_month").eq("id",userId).single();
    fyStart=(pr.data&&pr.data.fy_start_month)||1;

    var sl=await window.sb.from("recurring_slots").select("id,student_id,weekday,start_time,end_time,subject,level,rate,split").eq("active",true);

    var ls=await window.sb.from("lessons").select("id,student_id,lesson_date,start_time,end_time,amount,paid,status,subject,level,topics,homework,remarks,compensation");
    var lessons=ls.data||[];
    // A cancelled lesson's billable amount is its compensation (0 if none) — every KPI/
    // chart below reads plain l.amount, so normalizing it once here keeps that code simple.
    lessons.forEach(function(l){ if(l.status==="cancelled") l.amount=Number(l.compensation)||0; });

    renderOnboarding((st.data||[]).length, (sl.data||[]).length, lessons.length);
    allLessons=lessons;
    var now=new Date(),y=now.getFullYear(),m=now.getMonth();
    if(selY===null){selY=y;selM=m;}

    var unpaid=lessons.filter(function(l){return !l.paid&&(l.status==="done"||(l.status==="cancelled"&&l.amount>0));});
    setText("k-pending",TL.sgd(unpaid.reduce(function(t,l){return t+Number(l.amount);},0)));
    setText("k-pending-n",unpaid.length===1?"1 unpaid lesson":unpaid.length+" unpaid lessons");

    renderMonthKpis();
    if(!dmWired){
      dmWired=true;
      var on=function(id,fn){var el=$(id);if(el)el.addEventListener("click",fn);};
      on("dm-prev",function(){stepDMonth(-1);});
      on("dm-next",function(){stepDMonth(1);});
      on("dm-today",function(){var n=new Date();selY=n.getFullYear();selM=n.getMonth();renderMonthKpis();});
    }

    // lessons this week (Mon–Sun, excluding cancelled)
    var mon=new Date();mon.setHours(0,0,0,0);mon.setDate(mon.getDate()-((mon.getDay()+6)%7));
    var sun=new Date(mon);sun.setDate(mon.getDate()+6);
    var ws=iso(mon),we=iso(sun);
    var week=lessons.filter(function(l){return l.lesson_date>=ws&&l.lesson_date<=we&&l.status!=="cancelled";});
    setText("k-week",week.length); setText("k-week-w",week.length===1?"lesson":"lessons");

    // income by month for current year: collected (paid) + pending (done, unpaid) + upcoming (scheduled)
    var collected=new Array(12).fill(0),pending=new Array(12).fill(0),upcoming=new Array(12).fill(0);
    lessons.forEach(function(l){
      if(!l.lesson_date||l.lesson_date.slice(0,4)!=String(y)||(l.status==="cancelled"&&!(l.amount>0)))return;
      var mi=parseInt(l.lesson_date.slice(5,7),10)-1,amt=Number(l.amount);
      if(l.paid)collected[mi]+=amt;
      else if(l.status==="done")pending[mi]+=amt;
      else upcoming[mi]+=amt;
    });
    var ytd=collected.reduce(function(a,b){return a+b;},0);
    setText("inc-hint","Collected YTD "+TL.sgd(ytd));
    if(window.Chart&&$("incomeChart"))chartObj=drawStacked("incomeChart",MONTHS,collected,pending,upcoming,chartObj);

    var ex=await window.sb.from("exams").select("id,student_id,exam_date,assessment_type,subject,topics,max_score");
    var exams=ex.data||[];
    if($("teach-view")){
      renderExams(exams,nameById,"teach-exam-list",null);
      renderTeaching(lessons,nameById,exams);
      var t0=todayISO(),t14=new Date();t14.setDate(t14.getDate()+14);t14=iso(t14);
      setText("k-exams",exams.filter(function(e){return e.exam_date>=t0&&e.exam_date<=t14;}).length);
    }

    if(!segWired){
      segWired=true;
      if($("seg-fin"))$("seg-fin").addEventListener("click",function(){setDashMode("fin");});
      if($("seg-teach"))$("seg-teach").addEventListener("click",function(){setDashMode("teach");});
      if($("dash-seg")){
        var saved="fin"; try{saved=TL.store.get("tl_dash_mode")||"fin";}catch(e){}
        setDashMode(saved);
      }   // applied after the chart rendered while visible, so sizing is correct
    }

    if(fyAnchor===null)fyAnchor=currentFyAnchor();
    if(!finSubWired&&$("fin-view")){
      finSubWired=true;
      if($("fseg-month"))$("fseg-month").addEventListener("click",function(){setFinSub("month");});
      if($("fseg-year"))$("fseg-year").addEventListener("click",function(){setFinSub("year");});
      if($("fy-prev"))$("fy-prev").addEventListener("click",function(){stepFy(-1);});
      if($("fy-next"))$("fy-next").addEventListener("click",function(){stepFy(1);});
      if($("fy-today"))$("fy-today").addEventListener("click",function(){fyAnchor=currentFyAnchor();renderYear();});
      var fsub="month"; try{fsub=TL.store.get("tl_fin_sub")||"month";}catch(e){}
      setFinSub(fsub);
    }

    var yt=$("yd-toggle");
    if(yt&&!yt.dataset.w){yt.dataset.w="1";yt.addEventListener("click",function(){var o=$("yday-sec").classList.toggle("open");yt.setAttribute("aria-expanded",o?"true":"false");});}
    if(!tnWired){
      tnWired=true;
      if($("tn-cancel"))$("tn-cancel").addEventListener("click",closeNote);
      if($("tn-save"))$("tn-save").addEventListener("click",saveNote);
      if($("tn-modal"))$("tn-modal").addEventListener("click",function(e){if(e.target===$("tn-modal"))closeNote();});
    }
  }

  // First-run setup: three short steps, each opening the right form (?guide=1). Worked out from the data
  // (students, weekly slots, logged lessons), so it's right after any refresh or route back to Home.
  function renderOnboarding(students, slots, lessons){
    var box=$("onboard");if(!box)return;
    var steps=[
      {done:students>0, t:"Add your first student",          d:"Just a name to start.",                     href:"students?guide=1", cta:"Add your first student"},
      {done:slots>0,    t:"Set their weekly lesson time",    d:"Day, time and rate. It repeats every week.", href:"planner?guide=1",  cta:"Set the weekly lesson time"},
      {done:lessons>0,  t:"Confirm this week\u2019s lessons", d:"So you can track and bill them.",            href:"calendar?guide=1", cta:"Confirm on the calendar"}
    ];
    var G=TL.guide||{onboarded:function(){return true;},finish:function(){}};
    if(lessons>0) steps.forEach(function(s){ s.done=true; });   // has confirmed lessons before = set up (even if no active slots now)
    if(steps.every(function(s){return s.done;})){
      // Finished. If this tutor went through setup here and hasn't seen the finish line yet, show it once.
      if(TL.store.get("td_setup_started")==="1"){
        box.innerHTML='<div class="ob-card ob-done"><div class="ob-tick" aria-hidden="true">\u2713</div>'+
          '<h3 class="ob-h">You\u2019re all set up!</h3>'+
          '<p class="ob-sub">Your first lessons are confirmed. From now on:</p>'+
          '<ul class="ob-next"><li><b>Each week</b>, tap <b>Log</b> on the calendar to confirm that week\u2019s lessons.</li>'+
          '<li><b>When a parent pays</b>, mark the lessons paid in <b>Money</b>. Past lessons are logged as taught and unpaid (red) until then.</li></ul>'+
          '<button type="button" class="btn btn-gold ob-go" id="ob-ok">Got it</button></div>';
        box.style.display="block";
        // Setup counts as finished (and the usual tips may start) once they've read this and tapped Got it.
        $("ob-ok").addEventListener("click",function(){ box.style.display="none"; box.innerHTML=""; G.finish(); TL.store.remove("td_setup_started"); });
        return;
      }
      box.style.display="none";box.innerHTML="";G.finish();return;
    }
    TL.store.set("td_setup_started","1");
    var next=steps.filter(function(s){return !s.done;})[0];
    var rows=steps.map(function(s,i){
      var cur=s===next;
      return '<li class="ob-step'+(s.done?" done":"")+(cur?" cur":"")+'"><span class="ob-num">'+(s.done?"\u2713":(i+1))+'</span>'+
        '<span class="ob-txt"><span class="ob-t">'+s.t+'</span>'+(cur?'<span class="ob-d">'+s.d+'</span>':'')+'</span></li>';
    }).join("");
    box.innerHTML='<div class="ob-card"><h3 class="ob-h">Set up TutorDeck</h3>'+
      '<p class="ob-sub">3 quick steps, about 2 minutes.</p><ol class="ob-list">'+rows+'</ol>'+
      '<a class="btn btn-gold ob-go" href="'+next.href+'">'+next.cta+'</a></div>';
    box.style.display="block";
  }

  TL.requireAuth(($("view")&&$("view").dataset.page)||"dashboard",function(){load();});
})();