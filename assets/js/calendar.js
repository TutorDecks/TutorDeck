// Calendar — week/month view of the ledger.
// Shows real logged lessons (with status/paid) plus faded "projected" blocks
// from the recurring template for occurrences not yet logged. Read-only:
// clicking a block opens a details popover that links into the Ledger.
//
// Loading: students + active slots load once; lessons are fetched a whole month
// at a time and cached in memory (keyed "YYYY-MM"), so paging/toggling back to a
// month already seen is instant. All fetches for a view run in parallel.
(function () {
  var $ = function (id) { return document.getElementById(id); };
  var HOUR_PX = 46, MIN_HR = 6;

  var userId = null, anchor = null, mode = "week";
  var students = [], slots = [], exams = [], nameById = {}, locById = {}, hhById = {}, endById = {}, loadedStatic = false;
  var lessonCache = {}, pending = {}, lastBlocks = [], hidden = {};

  function pad(n){ return (n<10?"0":"")+n; }
  function iso(d){ return d.getFullYear()+"-"+pad(d.getMonth()+1)+"-"+pad(d.getDate()); }
  function hhmm(t){ return t ? String(t).slice(0,5) : ""; }
  function hhmm2(min){ return pad(Math.floor(min/60))+":"+pad(min%60); }
  function toMin(t){ var p=String(t||"0:0").split(":"); return (+p[0])*60+(+p[1]); }
  function esc(s){ return String(s==null?"":s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;"); }
  function mondayOf(date){ var d=new Date(date); d.setHours(0,0,0,0); d.setDate(d.getDate()-((d.getDay()+6)%7)); return d; }
  function addDays(d,n){ var x=new Date(d); x.setDate(x.getDate()+n); return x; }
  function dayIdx(dateISO){ var d=new Date(dateISO+"T00:00:00"); return (d.getDay()+6)%7; }
  // Household key = normalised phone (matches ledger.js): same number → same household.
  function hhKey(c){ var d=String(c||"").replace(/\D/g,""); if(d.length===10&&d.slice(0,2)==="65") d=d.slice(2); return d||null; }

  var MON=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
  var MONF=["January","February","March","April","May","June","July","August","September","October","November","December"];
  var DAY=["Mon","Tue","Wed","Thu","Fri","Sat","Sun"];

  // ---- what span a given anchor+mode covers ----
  function rangeFor(a, m){
    if(m==="month"){
      var first=new Date(a.getFullYear(),a.getMonth(),1);
      var last=new Date(a.getFullYear(),a.getMonth()+1,0);
      return { start:mondayOf(first), end:addDays(mondayOf(last),6) };
    }
    var ws=mondayOf(a);
    return { start:ws, end:addDays(ws,6) };
  }
  function visibleRange(){ return rangeFor(anchor, mode); }
  function monthsIn(range){
    var out=[], d=new Date(range.start.getFullYear(),range.start.getMonth(),1),
        endM=new Date(range.end.getFullYear(),range.end.getMonth(),1);
    while(d<=endM){ out.push(d.getFullYear()+"-"+pad(d.getMonth()+1)); d=new Date(d.getFullYear(),d.getMonth()+1,1); }
    return out;
  }
  function rangeLabel(){
    if(mode==="month") return MONF[anchor.getMonth()]+" "+anchor.getFullYear();
    var ws=mondayOf(anchor), end=addDays(ws,6);
    return ws.getMonth()===end.getMonth()
      ? ws.getDate()+"–"+end.getDate()+" "+MON[end.getMonth()]
      : ws.getDate()+" "+MON[ws.getMonth()]+" – "+end.getDate()+" "+MON[end.getMonth()];
  }
  function hourLabel(min){ var h=Math.floor(min/60), ap=(h<12||h>=24)?"AM":"PM", hr=h%12; if(hr===0)hr=12; return hr+" "+ap; }

  // ---- data ----
  async function loadStatic(){
    var r=await Promise.all([
      window.sb.from("students").select("id,name,location,contact,active,level,end_date"),
      window.sb.from("recurring_slots").select("id,student_id,weekday,start_time,end_time,subject,level,rate,split").eq("active",true),
      window.sb.from("exams").select("id,student_id,exam_date,assessment_type,subject")
    ]);
    students=r[0].error?[]:(r[0].data||[]);
    nameById={}; locById={}; hhById={}; endById={};
    students.forEach(function(s){ nameById[s.id]=s.name; locById[s.id]=s.location||""; hhById[s.id]=hhKey(s.contact); endById[s.id]=s.end_date||null; });
    slots=r[1].error?[]:(r[1].data||[]);
    exams=r[2].error?[]:(r[2].data||[]);
    loadedStatic=true;
  }
  function examsByDate(){
    var m={};
    exams.forEach(function(e){ if(e.exam_date) (m[e.exam_date]=m[e.exam_date]||[]).push(e); });
    return m;
  }
  function examChipHTML(e){
    var label=[e.assessment_type,e.subject].filter(Boolean).join(" ")||"Exam";
    return '<span class="cal-chip is-exam" data-exam="'+esc(String(e.id))+'">◷ '+esc(nameById[e.student_id]||"—")+' — '+esc(label)+'</span>';
  }
  // Returns a promise; no-ops if the month is already cached, and dedupes a month
  // that a background prefetch and a visible load ask for at the same time.
  function fetchMonth(key){
    if(key in lessonCache) return Promise.resolve();
    if(pending[key]) return pending[key];
    var p=key.split("-"), y=+p[0], m=+p[1]-1;
    var first=iso(new Date(y,m,1)), last=iso(new Date(y,m+1,0));
    pending[key]=window.sb.from("lessons")
      .select("id,slot_id,slot_date,student_id,lesson_date,start_time,end_time,subject,level,amount,rate,split,paid,status,postponed,compensation,one_off")
      .gte("lesson_date",first).lte("lesson_date",last)
      .then(function(ls){
        var rows=ls.error?[]:(ls.data||[]);
        // A cancelled lesson's billable amount is its compensation (0 if none) — the
        // popover already shows plain l.amount, so normalizing it once here is enough.
        rows.forEach(function(l){ if(l.status==="cancelled") l.amount=Number(l.compensation)||0; });
        lessonCache[key]=rows; delete pending[key];
      });
    return pending[key];
  }
  function lessonsForRange(range){
    var s=iso(range.start), e=iso(range.end), out=[];
    monthsIn(range).forEach(function(k){
      (lessonCache[k]||[]).forEach(function(l){ if(l.lesson_date>=s&&l.lesson_date<=e) out.push(l); });
    });
    return out;
  }
  // Load what the visible range needs (fetchMonth no-ops on cached months), paint,
  // then warm the neighbouring months in the background so ‹ / › are instant too.
  async function ensureData(){
    var jobs=[];
    if(!loadedStatic) jobs.push(loadStatic());
    monthsIn(visibleRange()).forEach(function(k){ jobs.push(fetchMonth(k)); });
    await Promise.all(jobs);
    render();
    prefetchAdjacent();
  }
  // The months touched by one step back and one step forward (week or month).
  function neighborMonths(){
    var out={};
    [-1,1].forEach(function(dir){
      var a2 = mode==="month" ? new Date(anchor.getFullYear(),anchor.getMonth()+dir,1) : addDays(anchor,dir*7);
      monthsIn(rangeFor(a2,mode)).forEach(function(k){ out[k]=1; });
    });
    return Object.keys(out);
  }
  function prefetchAdjacent(){ neighborMonths().forEach(function(k){ fetchMonth(k); }); }  // fire-and-forget

  // ---- blocks: real lessons + projected slot occurrences across a date range ----
  // Every slot occurrence a lesson fulfils, keyed slot_id|slot_date. Because slot_date is
  // fixed at generation and never moves, a postponed lesson still claims its ORIGINAL
  // occurrence — so no phantom "not logged" appears, on any day or month boundary.
  // Built from the whole cache, so a lesson postponed into another (cached) month still
  // claims its occurrence back here. Falls back to the exact time for one-off lessons and
  // any pre-backfill rows that lack slot_date.
  function loggedOccurrences(){
    var occ={}, time={};
    Object.keys(lessonCache).forEach(function(m){
      lessonCache[m].forEach(function(l){
        if(l.slot_id && l.slot_date) occ[l.slot_id+"|"+l.slot_date]=1;
        time[l.student_id+"|"+l.lesson_date+"|"+hhmm(l.start_time)]=1;
      });
    });
    return { occ:occ, time:time };
  }
  function buildBlocks(range){
    var blocks=[], claimed=loggedOccurrences(), lessons=lessonsForRange(range);
    lessons.forEach(function(l){
      var st=l.status==="cancelled" ? "cancel" : l.status==="scheduled" ? "sched" : (l.paid?"paid":"unpaid");
      blocks.push({ id:l.id, dateISO:l.lesson_date, day:dayIdx(l.lesson_date), startMin:toMin(l.start_time), endMin:toMin(l.end_time),
        name:nameById[l.student_id]||"—", subject:l.subject||"", level:l.level||"", location:locById[l.student_id]||"", amount:l.amount,
        rate:l.rate, split:l.split,
        kind:"lesson", state:st, postponed:!!l.postponed, adhoc:!!l.one_off, slotId:l.slot_id, slotDate:l.slot_date, hh:hhById[l.student_id]||null });
    });
    for(var d=new Date(range.start); iso(d)<=iso(range.end); d=addDays(d,1)){
      var di=iso(d), wd=(d.getDay()+6)%7;
      slots.forEach(function(s){
        if(s.weekday!==wd) return;
        if(TL.pastEnd(endById[s.student_id], di)) return;                    // past the student's end date — no projection
        if(claimed.occ[s.id+"|"+di]) return;                                 // this occurrence is logged
        if(claimed.time[s.student_id+"|"+di+"|"+hhmm(s.start_time)]) return; // one-off / pre-backfill fallback
        blocks.push({ id:"slot-"+s.id+"-"+di, dateISO:di, day:wd, startMin:toMin(s.start_time), endMin:toMin(s.end_time),
          name:nameById[s.student_id]||"—", subject:s.subject||"", level:s.level||"", location:locById[s.student_id]||"", kind:"proj", state:"proj",
          studentId:s.student_id, slotId:s.id, rate:s.rate, split:s.split||1, startHM:hhmm(s.start_time), endHM:hhmm(s.end_time) });
      });
    }
    return blocks.filter(function(b){ return !hidden[b.state]; });   // legend toggles
  }

  // Within one day: cluster overlaps, give each a lane, and flag genuine double-bookings.
  // A clash needs two *real* lessons to overlap. A cancelled lesson isn't happening, and a
  // projected ("not logged") block is only a preview of the template — neither is a real
  // booking, so overlapping either is not a clash. The clash appears once you actually log
  // the second lesson (it becomes real).
  function isReal(b){ return b.state!=="cancel" && b.state!=="proj"; }
  function laneAssign(day){
    day.sort(function(a,b){ return a.startMin-b.startMin || a.endMin-b.endMin; });
    var i=0;
    while(i<day.length){
      var cluster=[day[i]], end=day[i].endMin, j=i+1;
      while(j<day.length && day[j].startMin<end){ cluster.push(day[j]); end=Math.max(end,day[j].endMin); j++; }
      var laneEnds=[];
      cluster.forEach(function(b){
        var placed=false;
        for(var k=0;k<laneEnds.length;k++){ if(b.startMin>=laneEnds[k]){ b.lane=k; laneEnds[k]=b.endMin; placed=true; break; } }
        if(!placed){ b.lane=laneEnds.length; laneEnds.push(b.endMin); }
      });
      var real=cluster.filter(isReal);
      cluster.forEach(function(b){
        b.lanes=laneEnds.length;
        // Clash = overlaps another real lesson from a DIFFERENT household. Same household at
        // the same time is an intentional group (e.g. siblings), so no clash.
        b.clash = isReal(b) && real.some(function(o){
          return o!==b && o.startMin<b.endMin && b.startMin<o.endMin && !(b.hh && o.hh && b.hh===o.hh);
        });
      });
      i=j;
    }
  }

  function bounds(blocks){
    if(!blocks.length) return { start:15*60, end:21*60 };
    var mn=Math.min.apply(null,blocks.map(function(b){return b.startMin;}));
    var mx=Math.max.apply(null,blocks.map(function(b){return b.endMin;}));
    var start=Math.floor(mn/60)*60, end=Math.ceil(mx/60)*60;
    if((end-start)/60 < MIN_HR) end=start+MIN_HR*60;
    return { start:start, end:end };
  }

  // ---- week (time-grid) ----
  function evHTML(b, top, height){
    var cls=["cal-ev","is-"+b.state];
    if(b.clash) cls.push("is-clash");
    if(height<34) cls.push("tight");
    var w=100/b.lanes, left=b.lane*w;
    var style="top:"+top+"px;height:"+Math.max(height-2,15)+"px;left:calc("+left+"% + 2px);width:calc("+w+"% - 4px)";
    var sub=[b.subject,b.level].filter(Boolean).join(" · ");
    return '<div class="'+cls.join(" ")+'" style="'+style+'" data-ev="'+esc(String(b.id))+'">'+
      '<span class="ce-t">'+hhmm2(b.startMin)+(b.clash?'<span class="ce-warn">⚠</span>':'')+'</span>'+
      '<span class="ce-n">'+esc(b.name)+(b.adhoc?' ✦':'')+(b.postponed?' ↻':'')+'</span>'+
      (sub?'<span class="ce-s">'+esc(sub)+'</span>':'')+
      (b.location?'<span class="ce-loc">◍ '+esc(b.location)+'</span>':'')+'</div>';
  }
  function renderWeek(range){
    var ws=range.start, blocks=buildBlocks(range);
    var byDay=[[],[],[],[],[],[],[]];
    blocks.forEach(function(b){ byDay[b.day].push(b); });
    byDay.forEach(laneAssign);
    lastBlocks=blocks;
    var bd=bounds(blocks), hours=(bd.end-bd.start)/60, gridH=hours*HOUR_PX, today=iso(new Date());

    var headCells="";
    for(var d=0; d<7; d++){
      var date=addDays(ws,d), isT=iso(date)===today;
      headCells+='<div class="cal-day-h'+(isT?" today":"")+'">'+DAY[d]+'<b>'+date.getDate()+'</b></div>';
    }
    var examsByDt=examsByDate(), adCells="", weekHasExams=false;
    for(var de=0; de<7; de++){
      var dayExams=examsByDt[iso(addDays(ws,de))]||[];
      if(dayExams.length) weekHasExams=true;
      adCells+='<div class="cal-ad-cell">'+dayExams.map(examChipHTML).join("")+'</div>';
    }
    var gutter="";
    for(var h=0; h<hours; h++)
      gutter+='<div class="cal-hr" style="height:'+HOUR_PX+'px"><span>'+hourLabel(bd.start+h*60)+'</span></div>';
    var cols="";
    for(var c=0; c<7; c++){
      var isTc=iso(addDays(ws,c))===today, evs="";
      byDay[c].forEach(function(b){
        var top=(b.startMin-bd.start)/60*HOUR_PX, height=(b.endMin-b.startMin)/60*HOUR_PX;
        evs+=evHTML(b, top, height);
      });
      cols+='<div class="cal-col'+(isTc?" today":"")+'">'+evs+'</div>';
    }
    var gridBg="background-image:repeating-linear-gradient(var(--line) 0 1px,transparent 1px "+HOUR_PX+"px)";
    var el=$("cal");
    el.innerHTML='<div class="cal-head"><div class="cal-gutter-h"></div>'+headCells+'</div>'+
      (weekHasExams?('<div class="cal-allday"><div class="cal-gutter-h"></div>'+adCells+'</div>'):'')+
      '<div class="cal-body"><div class="cal-gutter">'+gutter+'</div>'+
      '<div class="cal-cols" style="height:'+gridH+'px;'+gridBg+'">'+cols+'</div></div>';
    if(!blocks.length)
      el.innerHTML+='<div class="cal-empty">No lessons or recurring slots this week. Add slots on the Planner, or log lessons in the Ledger.</div>';
    wireEvents();
  }

  // ---- month (day-cell grid) ----
  function chipHTML(b){
    var cls="cal-chip is-"+b.state+(b.clash?" is-clash":"");
    return '<span class="'+cls+'" data-ev="'+esc(String(b.id))+'">'+(b.clash?'⚠ ':'')+hhmm2(b.startMin)+' '+esc(b.name)+'</span>';
  }
  function renderMonth(range){
    var blocks=buildBlocks(range);
    var byDate={}; blocks.forEach(function(b){ (byDate[b.dateISO]=byDate[b.dateISO]||[]).push(b); });
    Object.keys(byDate).forEach(function(k){ laneAssign(byDate[k]); });   // sets clash per day
    lastBlocks=blocks;
    var examsByDt=examsByDate();
    var today=iso(new Date()), curMonth=anchor.getMonth();
    var head=DAY.map(function(d){ return '<div class="cal-mh">'+d+'</div>'; }).join("");
    var cells="";
    for(var d=new Date(range.start); iso(d)<=iso(range.end); d=addDays(d,1)){
      var di=iso(d), inMonth=d.getMonth()===curMonth, isT=di===today;
      var examHtml=(examsByDt[di]||[]).map(examChipHTML).join("");
      var chips=(byDate[di]||[]).slice().sort(function(a,b){ return a.startMin-b.startMin; });
      var shown=chips.slice(0,3).map(chipHTML).join("");
      var more=chips.length>3?'<div class="cal-more">+'+(chips.length-3)+' more</div>':"";
      cells+='<div class="cal-mday'+(inMonth?"":" other")+(isT?" today":"")+'" data-day="'+di+'">'+
        '<div class="md-num">'+d.getDate()+'</div>'+examHtml+shown+more+'</div>';
    }
    $("cal").innerHTML='<div class="cal-mhead">'+head+'</div><div class="cal-month">'+cells+'</div>';
    // click a day (not a chip) → open that week
    $("cal").querySelectorAll(".cal-mday").forEach(function(cell){
      cell.addEventListener("click", function(){ anchor=new Date(cell.dataset.day+"T00:00:00"); setMode("week"); });
    });
    wireEvents();
  }

  function render(){
    if(!$("cal")) return;
    $("cal-range").textContent=rangeLabel();
    if(mode==="month") renderMonth(visibleRange()); else renderWeek(visibleRange());
  }

  function wireEvents(){
    $("cal").querySelectorAll("[data-ev]").forEach(function(node){
      node.addEventListener("click", function(e){ e.stopPropagation(); showPopover(node); });
    });
    $("cal").querySelectorAll("[data-exam]").forEach(function(node){
      node.addEventListener("click", function(e){ e.stopPropagation(); location.href="exams.html?highlight="+encodeURIComponent(node.dataset.exam); });
    });
  }

  // ---- popover: view + direct actions (postpone / cancel / restore / delete) ----
  // Acts straight on the same "lessons" row the Ledger reads/writes, so a change
  // made here shows up there (and vice versa) the next time either page loads data.
  function statusFor(dateISO,endHM){ return new Date(dateISO+"T"+(endHM||"23:59")+":00").getTime()>Date.now() ? "scheduled" : "done"; }
  function findBlock(id){ return lastBlocks.filter(function(b){ return String(b.id)===String(id); })[0]; }
  var popNode=null;
  function positionPopover(node){
    var pop=$("cal-pop");
    var r=node.getBoundingClientRect(), pw=Math.max(260,pop.offsetWidth), ph=pop.offsetHeight;
    var left=Math.min(r.left, window.innerWidth-pw-10);
    var top=r.bottom+8; if(top+ph>window.innerHeight-10) top=Math.max(10, r.top-ph-8);
    pop.style.left=Math.max(10,left)+"px"; pop.style.top=top+"px";
  }
  function actionButtons(b){
    if(b.kind!=="lesson") return '<div class="cp-btns"><button class="cp-btn primary" id="cp-log">Log this lesson</button></div>';
    var toggle=b.state==="cancel"
      ? '<button class="cp-btn" id="cp-restore">Restore</button>'
      : '<button class="cp-btn warn" id="cp-cancel">Cancel</button>';
    // A postponed lesson that still has its recurring slot can snap back to the original date/time.
    var revert=(b.postponed && b.slotId && b.slotDate)?'<button class="cp-btn" id="cp-revert">↩ Revert to slot</button>':'';
    return '<div class="cp-btns"><button class="cp-btn" id="cp-postpone">Postpone</button>'+revert+toggle+'<button class="cp-btn danger" id="cp-delete">Delete</button></div>';
  }
  function showPopover(node){
    var b=findBlock(node.dataset.ev); if(!b) return;
    popNode=node;
    var pop=$("cal-pop");
    var label={paid:["Paid","rgba(14,124,123,.14)","#0b5b5a"], unpaid:["Unpaid","rgba(179,64,47,.12)","#8a2f22"],
      sched:["Scheduled","rgba(26,42,79,.10)","var(--navy)"], cancel:["Cancelled","#f3f0e8","var(--muted)"],
      proj:["Not logged yet","rgba(181,137,43,.12)","#7a5f1f"]}[b.state];
    var dt=new Date(b.dateISO+"T00:00:00");
    var when=DAY[(dt.getDay()+6)%7]+" "+dt.getDate()+" "+MON[dt.getMonth()]+" · "+hhmm2(b.startMin)+"–"+hhmm2(b.endMin);
    var sub=[b.subject,b.level].filter(Boolean).join(" · ");
    pop.innerHTML='<span class="cp-x" id="cp-x">×</span><h4>'+esc(b.name)+'</h4>'+
      '<div class="cp-row">'+esc(when)+'</div>'+
      (sub?'<div class="cp-row"><b>'+esc(sub)+'</b></div>':'')+
      (b.location?'<div class="cp-row">◍ <b>'+esc(b.location)+'</b></div>':'')+
      (b.kind==="lesson"&&b.amount!=null?'<div class="cp-row">'+(b.state==="cancel"?"Compensation":"Amount")+' <b>'+TL.sgd(b.amount)+'</b></div>':'')+
      (b.clash?'<div class="cp-row" style="color:var(--owed);font-weight:700">⚠ Overlaps another lesson</div>':'')+
      '<span class="cp-tag" style="background:'+label[1]+';color:'+label[2]+'">'+label[0]+'</span>'+
      (b.adhoc?' <span class="cp-tag" style="background:rgba(26,42,79,.10);color:var(--navy)">✦ One-off</span>':'')+
      (b.postponed?' <span class="cp-tag" style="background:rgba(200,146,42,.18);color:#8a5f14">Postponed</span>':'')+
      actionButtons(b)+
      '<a class="cp-act" href="ledger.html">'+(b.kind==="proj"?"Log in Ledger →":"Edit in Ledger →")+'</a>';
    pop.style.display="block";
    positionPopover(node);
    $("cp-x").addEventListener("click", hidePopover);
    var cancelBtn=$("cp-cancel"); if(cancelBtn) cancelBtn.addEventListener("click", function(){ showCancelForm(b); });
    var restoreBtn=$("cp-restore"); if(restoreBtn) restoreBtn.addEventListener("click", function(){ doRestore(b); });
    var deleteBtn=$("cp-delete"); if(deleteBtn) deleteBtn.addEventListener("click", function(){ doDelete(b.id); });
    var postponeBtn=$("cp-postpone"); if(postponeBtn) postponeBtn.addEventListener("click", function(){ showPostponeForm(b); });
    var revertBtn=$("cp-revert"); if(revertBtn) revertBtn.addEventListener("click", function(){ doRevert(b); });
    var logBtn=$("cp-log"); if(logBtn) logBtn.addEventListener("click", function(){ doLogProjected(b); });
  }
  function hidePopover(){ var p=$("cal-pop"); if(p) p.style.display="none"; popNode=null; }
  // After any write, the visible range (and whichever month a lesson may have moved
  // into/out of) needs fresh data — simplest correct fix is to drop the whole cache.
  function refreshAfterMutation(){ hidePopover(); lessonCache={}; ensureData(); }
  // In-app confirm dialog → Promise<boolean>; dims the page instead of the browser's native confirm.
  function confirmBox(msg, opts){
    opts=opts||{};
    return new Promise(function(resolve){
      var bd=$("confirm-modal"), yes=$("confirm-yes"), no=$("confirm-no");
      if(!bd){ resolve(window.confirm(msg)); return; }
      $("confirm-title").textContent=opts.title||"Confirm";
      $("confirm-msg").textContent=msg;
      yes.textContent=opts.yes||"Confirm"; no.textContent=opts.no||"Cancel";
      yes.className="btn "+(opts.danger?"btn-danger":"btn-primary");
      function done(v){ bd.classList.remove("on"); yes.onclick=null; no.onclick=null; bd.onclick=null; resolve(v); }
      yes.onclick=function(){ done(true); };
      no.onclick=function(){ done(false); };
      bd.onclick=function(e){ if(e.target===bd) done(false); };
      bd.classList.add("on");
    });
  }
  function splitAmt(rate,s,e,split){ var sp=(split&&split>1)?split:1; return Math.round(TL.amount(rate,s,e)/sp*100)/100; }
  // Amount for a changed lesson time. Prefer the stored rate/split (matches the Ledger); if a lesson
  // has no rate, scale the old amount by the new/old duration ratio so it never drops to zero.
  function amtFor(rate, split, oldAmount, oldStartMin, oldEndMin, start, end){
    if(rate!=null && rate!=="") return splitAmt(rate, start, end, split);
    var oldMin=oldEndMin-oldStartMin, newMin=toMin(end)-toMin(start);
    return oldMin>0 ? Math.round((Number(oldAmount)||0)*newMin/oldMin*100)/100 : (Number(oldAmount)||0);
  }
  async function doLogProjected(b){
    var row={ tutor_id:userId, student_id:b.studentId, slot_id:b.slotId, lesson_date:b.dateISO, slot_date:b.dateISO,
      start_time:b.startHM, end_time:b.endHM, subject:b.subject, level:b.level, rate:b.rate, split:b.split||1,
      amount:splitAmt(b.rate,b.startHM,b.endHM,b.split), status:statusFor(b.dateISO,b.endHM), paid:false };
    var res=await window.sb.from("lessons").insert(row);
    if(res.error){alert("Couldn't log: "+res.error.message);return;}
    refreshAfterMutation();
  }

  // ---- add a one-off lesson straight from the calendar ----
  function studentOpts(){
    var act=students.filter(function(s){return s.active!==false && !TL.isEnded(s.end_date);});
    return act.length ? act.map(function(s){return '<option value="'+s.id+'">'+esc(s.name)+'</option>';}).join("")
                      : '<option value="">— add a student first —</option>';
  }
  function slotFor(sid){ return slots.filter(function(s){return String(s.student_id)===String(sid);})[0]; }
  function studentById(sid){ return students.filter(function(s){return String(s.id)===String(sid);})[0]; }
  // Fill the form from the chosen student — subject/rate/split from their recurring slot, level from
  // the slot or the student record. Overwrites (not just-if-blank) so switching students updates it.
  function applyStudentDefaults(){
    var id=$("ca-student").value, sl=slotFor(id), stu=studentById(id);
    if(sl){
      $("ca-subject").value=sl.subject||"";
      $("ca-rate").value=(sl.rate!=null?sl.rate:"");
      $("ca-split").value=sl.split||1;
      $("ca-level").value=sl.level||(stu&&stu.level)||"";
    } else {
      // no recurring slot → no subject/rate default; still offer the student's level
      $("ca-subject").value=""; $("ca-rate").value=""; $("ca-split").value="1";
      $("ca-level").value=(stu&&stu.level)||"";
    }
  }
  function openAdd(prefill){
    prefill=prefill||{};
    $("ca-student").innerHTML=studentOpts();
    $("ca-date").value=prefill.date||iso(new Date());
    $("ca-start").value=prefill.start||"16:00";
    $("ca-end").value=prefill.end||"17:00";
    $("ca-subject").value=""; $("ca-level").value=""; $("ca-rate").value=""; $("ca-split").value="1"; $("ca-paid").checked=false;
    $("ca-msg").textContent=""; $("ca-msg").className="msg";
    applyStudentDefaults();
    $("add-modal").classList.add("on");
  }
  function closeAdd(){ $("add-modal").classList.remove("on"); }
  async function saveAdd(){
    var sid=$("ca-student").value, date=$("ca-date").value, start=$("ca-start").value, end=$("ca-end").value,
        rate=parseFloat($("ca-rate").value), split=Math.max(1,parseInt($("ca-split").value,10)||1), msg=$("ca-msg");
    function err(m){ msg.textContent=m; msg.className="msg err"; }
    if(!sid){ err("Pick a student."); return; }
    if(!date){ err("Pick a date."); return; }
    if(!start||!end||end<=start){ err("Check the start and end times."); return; }
    if(!(rate>=0)){ err("Enter a rate."); return; }
    var paid=$("ca-paid").checked;
    var row={ tutor_id:userId, student_id:sid, lesson_date:date, start_time:start, end_time:end,
      subject:$("ca-subject").value.trim()||null, level:$("ca-level").value.trim()||null,
      rate:rate, split:split, amount:splitAmt(rate,start,end,split), status:statusFor(date,end),
      paid:paid, paid_date:paid?date:null, one_off:true };   // manual add from the calendar = one-off
    var b=$("ca-save"); b.disabled=true;
    var res=await window.sb.from("lessons").insert(row);
    b.disabled=false;
    if(res.error){ err(res.error.message); return; }
    closeAdd(); refreshAfterMutation();
  }
  function showCancelForm(b){
    var pop=$("cal-pop");
    pop.innerHTML='<span class="cp-x" id="cp-x">×</span><h4>Cancel '+esc(b.name)+'</h4>'+
      '<div class="cp-row" style="color:var(--muted)">Won\'t count toward income unless you add a compensation amount.</div>'+
      '<div class="cp-field"><label for="cp-comp">Compensation <span class="muted">(optional)</span></label><input type="number" id="cp-comp" min="0" step="0.01" placeholder="0.00"></div>'+
      '<div class="msg" id="cp-cmsg"></div>'+
      '<div class="cp-btns"><button class="cp-btn danger" id="cp-csave">Cancel lesson</button><button class="cp-btn" id="cp-cback">Back</button></div>';
    pop.style.display="block";
    if(popNode) positionPopover(popNode);
    $("cp-x").addEventListener("click", hidePopover);
    $("cp-cback").addEventListener("click", function(){ if(popNode) showPopover(popNode); });
    $("cp-csave").addEventListener("click", function(){ saveCancelForm(b); });
  }
  async function saveCancelForm(b){
    var comp=Math.max(0,parseFloat($("cp-comp").value)||0), msg=$("cp-cmsg");
    var res=await window.sb.from("lessons").update({status:"cancelled",paid:false,paid_date:null,compensation:comp>0?comp:null}).eq("id",b.id);
    if(res.error){msg.textContent=res.error.message;msg.className="msg err";return;}
    refreshAfterMutation();
  }
  async function doRestore(b){
    var res=await window.sb.from("lessons").update({status:statusFor(b.dateISO,hhmm2(b.endMin)),compensation:null}).eq("id",b.id);
    if(res.error){alert("Couldn't restore: "+res.error.message);return;}
    refreshAfterMutation();
  }
  async function doDelete(id){
    if(!(await confirmBox("Delete this lesson permanently? Use Cancel instead if you just want to void it.", {title:"Delete lesson", yes:"Delete", danger:true}))) return;
    var res=await window.sb.from("lessons").delete().eq("id",id);
    if(res.error){alert("Couldn't delete: "+res.error.message);return;}
    refreshAfterMutation();
  }
  function showPostponeForm(b){
    var pop=$("cal-pop");
    pop.innerHTML='<span class="cp-x" id="cp-x">×</span><h4>Postpone '+esc(b.name)+'</h4>'+
      '<div class="cp-field"><label for="cp-pdate">New date</label><input type="date" id="cp-pdate" value="'+b.dateISO+'"></div>'+
      '<div class="cp-row2">'+
        '<div class="cp-field"><label for="cp-pstart">Start</label><input type="time" id="cp-pstart" value="'+hhmm2(b.startMin)+'"></div>'+
        '<div class="cp-field"><label for="cp-pend">End</label><input type="time" id="cp-pend" value="'+hhmm2(b.endMin)+'"></div>'+
      '</div>'+
      '<div class="msg" id="cp-pmsg"></div>'+
      '<div class="cp-btns"><button class="cp-btn primary" id="cp-psave">Save</button><button class="cp-btn" id="cp-pback">Back</button></div>';
    pop.style.display="block";
    if(popNode) positionPopover(popNode);
    $("cp-x").addEventListener("click", hidePopover);
    $("cp-pback").addEventListener("click", function(){ if(popNode) showPopover(popNode); });
    $("cp-psave").addEventListener("click", function(){ savePostpone(b); });
  }
  // Undo a postpone: move the lesson back to its recurring slot's original date + time.
  async function doRevert(b){
    if(!b.slotId||!b.slotDate){ alert("This lesson has no original slot to revert to."); return; }
    var slot=slots.filter(function(s){return String(s.id)===String(b.slotId);})[0];
    // Follow the planner: land on the slot's CURRENT weekday + time, anchored on the
    // occurrence week (slot_date). So if the slot's day/time changed, revert tracks it —
    // and lessons whose slot_date was lost to the old backfill still snap to the real day.
    var date, start, end;
    if(slot){
      var ref=new Date(b.slotDate+"T00:00:00");
      date=iso(addDays(ref, slot.weekday - dayIdx(b.slotDate)));
      start=hhmm(slot.start_time); end=hhmm(slot.end_time);
    } else {
      date=b.slotDate; start=hhmm2(b.startMin); end=hhmm2(b.endMin);
    }
    if(!(await confirmBox("Revert this lesson to its original slot — "+date+", "+start+"–"+end+"?", {title:"Revert to slot", yes:"Revert"}))) return;
    var amount=amtFor(slot?slot.rate:b.rate, slot?slot.split:b.split, b.amount, b.startMin, b.endMin, start, end);
    var res=await window.sb.from("lessons").update({lesson_date:date,start_time:start,end_time:end,amount:amount,status:statusFor(date,end),postponed:false}).eq("id",b.id);
    if(res.error){ alert("Couldn't revert: "+res.error.message); return; }
    refreshAfterMutation();
  }
  async function savePostpone(b){
    var date=$("cp-pdate").value, start=$("cp-pstart").value, end=$("cp-pend").value, msg=$("cp-pmsg");
    if(!date||!start||!end){msg.textContent="Pick a date, start and end time.";msg.className="msg err";return;}
    if(end<=start){msg.textContent="End time must be after start time.";msg.className="msg err";return;}
    var amount=amtFor(b.rate, b.split, b.amount, b.startMin, b.endMin, start, end);   // keep earnings in step with the new duration
    var res=await window.sb.from("lessons").update({lesson_date:date,start_time:start,end_time:end,amount:amount,status:statusFor(date,end),postponed:true}).eq("id",b.id);
    if(res.error){msg.textContent="Couldn't postpone: "+res.error.message;msg.className="msg err";return;}
    refreshAfterMutation();
  }

  // ---- Google Calendar sync (client-side OAuth via Google Identity Services) ----
  var GCLIENT=(window.TLENG_CONFIG||{}).GOOGLE_CLIENT_ID||"";
  var GSCOPE="https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.calendarlist.readonly", GTZ="Asia/Singapore";
  var gToken=null, gTokenExp=0, gTokenClient=null, gUserInit=false;
  function gTokenValid(){ return !!gToken && Date.now()<gTokenExp; }   // reuse an unexpired token, no fresh Google popup

  function gcalConfigured(){ return !!GCLIENT; }
  function gcalConnected(){ try{ return localStorage.getItem("tl_gcal_connected")==="1"; }catch(e){ return false; } }
  function gcalListGranted(){ try{ return localStorage.getItem("tl_gcal_list")==="1"; }catch(e){ return false; } }
  function gcalChosen(){ try{ return localStorage.getItem("tl_gcal_chosen")==="1"; }catch(e){ return false; } }
  function gcalTarget(){ try{ return localStorage.getItem("tl_gcal_calendar")||"primary"; }catch(e){ return "primary"; } }
  function gStatus(t,cls){ var el=$("gcal-status"); if(el){ el.textContent=t||""; el.className="gcal-status"+(cls?" "+cls:""); } }
  function gcalCals(){ try{ return JSON.parse(localStorage.getItem("tl_gcal_cals")||"[]")||[]; }catch(e){ return []; } }
  // A connection attempt failed — drop back to the Connect step (clear the loaded list so the
  // dropdown gives way to the Connect button). Keep the chosen calendar so reconnect resumes it.
  function gcalFail(msg){
    gToken=null; gTokenExp=0;
    try{ localStorage.removeItem("tl_gcal_connected"); localStorage.removeItem("tl_gcal_list"); localStorage.removeItem("tl_gcal_cals"); }catch(e){}
    updateGcalUI();
    gStatus(msg||"Couldn't connect to Google — click Connect to try again.","err");
  }
  // The Connect button and the calendar dropdown are mutually exclusive:
  //  - no calendars loaded yet → show "Connect Google Calendar", hide the dropdown
  //  - calendars loaded, none chosen → hide the button, the dropdown is the next step
  //  - a calendar is chosen → show "↻ Sync now" alongside the dropdown
  function updateGcalUI(){
    var chosen=gcalChosen(), hasCals=gcalCals().length>0;
    var btn=$("gcal-btn"), row=$("gsync-row"), brand=$("gsync-brand"), sel=$("gcal-cal");
    if(hasCals) fillDropdownFromCache();
    // Brand chip + picker show only once we have calendars; the bordered pill only then too.
    if(brand) brand.classList.toggle("gcal-hide", !hasCals);
    if(sel) sel.classList.toggle("gcal-hide", !hasCals);
    if(row) row.classList.toggle("bare", !hasCals);
    if(btn){
      var lbl=btn.querySelector(".glabel");
      function setLabel(t){ if(lbl) lbl.textContent=t; else btn.textContent=t; }
      if(!hasCals){                             // nothing to pick → white Google connect button
        setLabel("Connect Google Calendar"); btn.classList.add("btn-connect"); btn.classList.remove("btn-sync"); btn.style.display="";
      } else if(chosen){                        // set up → teal "Sync now" inside the pill
        setLabel("↻ Sync now"); btn.classList.add("btn-sync"); btn.classList.remove("btn-connect"); btn.style.display="";
      } else {                                  // calendars loaded, pick one → the picker is the action, no button
        btn.style.display="none";
        if($("gcal-status") && !$("gcal-status").textContent) gStatus("Choose a calendar to sync your lessons into.");
      }
    }
  }
  // Render the dropdown from a list of {v,l} items, selecting the chosen target.
  function fillDropdown(items){
    var sel=$("gcal-cal"); if(!sel) return;
    var opts=(items||[]).map(function(c){ return '<option value="'+esc(c.v)+'">'+esc(c.l)+'</option>'; });
    if(!gcalChosen()) opts.unshift('<option value="">Choose a calendar…</option>');
    sel.innerHTML=opts.join("") || '<option value="">Choose a calendar…</option>';
    sel.value=gcalChosen()?gcalTarget():"";
  }
  // On load we have no live token yet — fill from the cached list so the picker isn't empty.
  function fillDropdownFromCache(){
    var items=gcalCals();
    if(items.length) fillDropdown(items);
  }

  function whenGoogleReady(cb){
    if(window.google && google.accounts && google.accounts.oauth2){ cb(); return; }
    var n=0, t=setInterval(function(){ n++; if(window.google&&google.accounts&&google.accounts.oauth2){ clearInterval(t); cb(); } else if(n>40){ clearInterval(t); } },200);
  }
  function initGcal(){
    if(!gcalConfigured() || !$("gcal-btn")) return;
    $("gcal-btn").style.display="";
    whenGoogleReady(function(){
      gTokenClient=google.accounts.oauth2.initTokenClient({
        client_id:GCLIENT, scope:GSCOPE,
        callback:function(resp){
          if(resp && resp.access_token){
            gToken=resp.access_token;
            gTokenExp=Date.now()+(((+resp.expires_in||3600)*1000)-60000);   // reuse until ~1min before expiry
            try{localStorage.setItem("tl_gcal_connected","1");}catch(e){}
            updateGcalUI(); populateCalendars();
            if(gUserInit){                                              // only sync on a deliberate click, not silent load
              gUserInit=false;
              if(gcalChosen()) syncNow();
              else gStatus("Connected — now choose which calendar to sync into.","ok");
            }
          }
          else if(gUserInit){ gUserInit=false; gcalFail(); }           // deliberate attempt that returned no token → restart
        },
        error_callback:function(){                                     // popup closed / blocked / consent denied
          if(gUserInit){ gUserInit=false; gcalFail(); }                // only reset on a deliberate click, not a silent load
        }
      });
      updateGcalUI();
      if(gcalConnected()) gTokenClient.requestAccessToken({prompt:""});   // silent re-auth + sync on load
    });
  }
  function connectGcal(){
    if(!gTokenClient){ gStatus("Google isn't ready yet — try again in a second.","err"); return; }
    // Token still good? Just act — no fresh Google popup on every click.
    if(gTokenValid()){
      if(gcalChosen()) syncNow();
      else if(gcalCals().length) gStatus("Choose a calendar to sync your lessons into.");
      else populateCalendars();
      return;
    }
    gUserInit=true;   // deliberate click → sync (or prompt to choose) once the token arrives
    // Force the consent screen only until the calendar-list permission is granted; after that,
    // an expired token refreshes silently where the browser allows it.
    var needConsent = !gcalListGranted();
    gTokenClient.requestAccessToken({ prompt: needConsent?"consent":"" });
  }
  // Fill the calendar dropdown with the user's own+writable calendars.
  async function populateCalendars(){
    var sel=$("gcal-cal"); if(!sel || !gToken) return;
    try{
      var res=await fetch("https://www.googleapis.com/calendar/v3/users/me/calendarList", { headers:{ Authorization:"Bearer "+gToken } });
      if(res.status===403){                                   // calendar-list permission not granted → restart
        gcalFail("Google needs permission to see your calendars — click Connect to grant it.");
        return;
      }
      if(res.status===401){ gcalFail("Google session expired — click Connect to reconnect."); return; }
      if(!res.ok){ return; }
      try{ localStorage.setItem("tl_gcal_list","1"); }catch(e){}
      var d=await res.json();
      var items=(d.items||[]).filter(function(c){ return c.accessRole==="owner"||c.accessRole==="writer"; })
        .map(function(c){ return { v:c.primary?"primary":c.id, l:c.primary?"Main calendar":(c.summary||c.id) }; });
      try{ localStorage.setItem("tl_gcal_cals", JSON.stringify(items)); }catch(e){}   // remember for next load
      fillDropdown(items);
      updateGcalUI();   // list just arrived → re-render so the Connect button gives way to the picker
    }catch(e){}
  }

  function gEvent(l){
    var sym=(l.postponed?"↻":"")+(l.one_off?"✦":"");     // ↻ postponed, ✦ one-off — same keys as the app
    var summary=(sym?sym+" ":"")+[nameById[l.student_id]||"Lesson", l.subject].filter(Boolean).join(" · ");
    var d=[]; if(l.level)d.push("Level: "+l.level); if(l.amount!=null)d.push("Amount: S$"+l.amount);
    d.push(l.status==="scheduled"?"Scheduled":(l.paid?"Paid":"Unpaid"));
    if(l.postponed)d.push("Postponed (↻)"); if(l.one_off)d.push("One-off (✦)");
    var e={ summary:summary, description:d.join("\n"),
      start:{ dateTime:l.lesson_date+"T"+hhmm(l.start_time)+":00", timeZone:GTZ },
      end:{ dateTime:l.lesson_date+"T"+hhmm(l.end_time)+":00", timeZone:GTZ },
      reminders:{ useDefault:false },                      // no notification spam on re-create
      extendedProperties:{ private:{ tlengSync:"1", tlLessonId:String(l.id) } } };  // tag + which lesson it mirrors
    var loc=locById[l.student_id]; if(loc) e.location=loc;
    return e;
  }
  // Comparable fingerprint of the fields we sync — used to detect drift (incl. Google-side edits).
  function gFP(x){
    return [ x.summary||"", ((x.start&&x.start.dateTime)||"").slice(0,19),
      ((x.end&&x.end.dateTime)||"").slice(0,19), x.location||"", x.description||"" ].join("|");
  }
  async function gapi(method, path, body){
    var res=await fetch("https://www.googleapis.com/calendar/v3"+path, {
      method:method, headers:{ "Authorization":"Bearer "+gToken, "Content-Type":"application/json" },
      body: body?JSON.stringify(body):undefined });
    if(res.status===401){ gToken=null; gTokenExp=0; var err=new Error("expired"); err.code=401; throw err; }
    if(!res.ok && res.status!==410) throw new Error("Google API "+res.status);   // 410 = already gone
    return (res.status===204||res.status===410) ? null : res.json();
  }
  // The month around a date, both as lesson-date bounds (YYYY-MM-DD) and RFC3339 SGT times.
  function monthWindow(when){
    var y=when.getFullYear(), m=when.getMonth(), lastDay=new Date(y,m+1,0).getDate();
    var ny=(m===11)?y+1:y, nm=(m===11)?0:m+1;
    return { firstISO:y+"-"+pad(m+1)+"-01", lastISO:y+"-"+pad(m+1)+"-"+pad(lastDay),
      tmin:y+"-"+pad(m+1)+"-01T00:00:00+08:00", tmax:ny+"-"+pad(nm+1)+"-01T00:00:00+08:00", label:MONF[m]+" "+y };
  }
  // All app-created events on a calendar (optionally within a time window), following pages.
  async function listAppEvents(cal, tmin, tmax){
    var out=[], page=null;
    do{
      var q="/calendars/"+encodeURIComponent(cal)+"/events?privateExtendedProperty="+encodeURIComponent("tlengSync=1")+"&maxResults=250&singleEvents=true";
      if(tmin) q+="&timeMin="+encodeURIComponent(tmin);
      if(tmax) q+="&timeMax="+encodeURIComponent(tmax);
      if(page) q+="&pageToken="+encodeURIComponent(page);
      var d=await gapi("GET", q);
      (d && d.items || []).forEach(function(e){ if(e.id) out.push(e); });
      page = d && d.nextPageToken;
    } while(page);
    return out;
  }
  function evLessonId(ev){ try{ return ev.extendedProperties.private.tlLessonId||""; }catch(e){ return ""; } }
  // Reconcile ONE month on the target calendar against the ledger (app is source of truth):
  // create missing lessons, update any that drifted (incl. Google-side edits), delete orphans.
  // Returns counts; throws on 401 so the caller stops.
  async function syncMonth(when){
    var cal=gcalTarget(), w=monthWindow(when);
    gStatus("Syncing "+w.label+"…");
    var events=await listAppEvents(cal, w.tmin, w.tmax);
    var byLesson={}, extra=[];                              // extra = duplicates or legacy events (no lesson id)
    events.forEach(function(ev){ var lid=evLessonId(ev); if(lid && !byLesson[lid]) byLesson[lid]=ev; else extra.push(ev); });
    var ls=await window.sb.from("lessons")
      .select("id,student_id,lesson_date,start_time,end_time,subject,level,amount,paid,status,postponed,slot_id,one_off")
      .gte("lesson_date", w.firstISO).lte("lesson_date", w.lastISO);
    if(ls.error) return { created:0, updated:0, deleted:0, skipped:0, fail:1 };
    var rows=(ls.data||[]).filter(function(l){ return l.status!=="cancelled"; });
    var created=0, updated=0, deleted=0, skipped=0, fail=0, keep={};
    for(var i=0;i<rows.length;i++){
      var l=rows[i], want=gEvent(l), ev=byLesson[String(l.id)]; keep[String(l.id)]=1;
      try{
        if(!ev){ await gapi("POST","/calendars/"+encodeURIComponent(cal)+"/events", want); created++; }
        else if(gFP(ev)!==gFP(want)){ await gapi("PUT","/calendars/"+encodeURIComponent(cal)+"/events/"+encodeURIComponent(ev.id), want); updated++; }
        else skipped++;
      }catch(e){ if(e&&e.code===401) throw e; fail++; }
    }
    var toDel=extra.slice();                                // orphans: lesson gone/cancelled, plus dups/legacy
    Object.keys(byLesson).forEach(function(lid){ if(!keep[lid]) toDel.push(byLesson[lid]); });
    for(var k=0;k<toDel.length;k++){ try{ await gapi("DELETE","/calendars/"+encodeURIComponent(cal)+"/events/"+encodeURIComponent(toDel[k].id)); deleted++; }catch(e){ if(e&&e.code===401) throw e; } }
    return { created:created, updated:updated, deleted:deleted, skipped:skipped, fail:fail };
  }
  // Sync the current month through the last month that has a lesson (capped +6mo) — so lessons
  // you've logged for future months go too, while past months are left untouched.
  async function syncNow(){
    if(!gToken) return;
    if(!loadedStatic) await loadStatic();
    var now=new Date(), fromM=new Date(now.getFullYear(), now.getMonth(), 1);
    var q=await window.sb.from("lessons").select("lesson_date").gte("lesson_date", iso(fromM)).order("lesson_date",{ascending:false}).limit(1);
    var lastISO=(!q.error && q.data && q.data[0] && q.data[0].lesson_date) || iso(fromM);
    var lastM=new Date(+lastISO.slice(0,4), (+lastISO.slice(5,7))-1, 1);
    var capM=new Date(now.getFullYear(), now.getMonth()+6, 1);
    if(lastM>capM) lastM=capM;
    var created=0, updated=0, deleted=0, skipped=0, fail=0, months=0, t0=Date.now();
    try{
      for(var cur=new Date(fromM); cur<=lastM; cur=new Date(cur.getFullYear(), cur.getMonth()+1, 1)){
        var r=await syncMonth(new Date(cur));
        created+=r.created; updated+=r.updated; deleted+=r.deleted; skipped+=r.skipped; fail+=r.fail; months++;
      }
    }catch(e){ if(e&&e.code===401){ gStatus("Google session expired — click Connect again.","err"); return; } gStatus("Sync hit an error — try again.","err"); return; }
    var secs=Math.max(1, Math.round((Date.now()-t0)/1000)), total=created+updated+skipped;
    var parts=[]; if(created)parts.push(created+" added"); if(updated)parts.push(updated+" updated"); if(deleted)parts.push(deleted+" removed");
    var detail=parts.length?parts.join(", "):"already up to date";
    gStatus("Synced ✓ "+total+" lesson"+(total===1?"":"s")+" in "+secs+"s · "+detail+(fail?" · "+fail+" failed":""), "ok");
  }
  // Switch which calendar we sync into: wipe ALL our events off the old calendar, then rebuild
  // the current month on the new one.
  async function setGcalTarget(raw){
    if(!(raw||"").trim()) return;                             // "Choose a calendar…" placeholder — ignore
    var newT=(raw||"").trim(), oldT=gcalTarget(), first=!gcalChosen();
    if(!gToken){
      // No live token this session — remember the choice, then get a token and sync to it.
      try{ localStorage.setItem("tl_gcal_calendar", newT); localStorage.setItem("tl_gcal_chosen","1"); }catch(e){}
      updateGcalUI(); gStatus("Connecting to Google…");
      connectGcal();                                          // gUserInit=true → syncNow() to the chosen calendar after the token
      return;
    }
    if(!first && newT!==oldT){
      gStatus("Moving to the new calendar…");
      try{ var evs=await listAppEvents(oldT); for(var i=0;i<evs.length;i++){ try{ await gapi("DELETE","/calendars/"+encodeURIComponent(oldT)+"/events/"+encodeURIComponent(evs[i].id)); }catch(e){} } }catch(e){}
    }
    try{ localStorage.setItem("tl_gcal_calendar", newT); localStorage.setItem("tl_gcal_chosen","1"); }catch(e){}
    updateGcalUI();
    syncNow();
  }

  // ---- nav / mode ----
  function setMode(m){
    mode=m;
    try{ localStorage.setItem("tl_cal_mode",m); }catch(e){}
    $("seg-week").classList.toggle("on",m==="week");
    $("seg-month").classList.toggle("on",m==="month");
    ensureData();
  }
  function shiftRange(dir){
    if(mode==="month") anchor=new Date(anchor.getFullYear(),anchor.getMonth()+dir,1);
    else anchor=addDays(anchor,dir*7);
    ensureData();
  }
  function goToday(){ anchor=new Date(); ensureData(); }

  function initLegend(){
    document.querySelectorAll(".cal-legend .leg").forEach(function(btn){
      var cat=btn.dataset.cat;
      btn.classList.toggle("off", !!hidden[cat]);
      btn.addEventListener("click", function(e){
        e.stopPropagation();
        if(hidden[cat]) delete hidden[cat]; else hidden[cat]=true;
        btn.classList.toggle("off", !!hidden[cat]);
        try{ localStorage.setItem("tl_cal_hidden", JSON.stringify(hidden)); }catch(e2){}
        render();   // re-filter; no refetch needed
      });
    });
  }

  function init(user){
    userId=user.id; anchor=new Date();
    try{ mode=localStorage.getItem("tl_cal_mode")||"week"; }catch(e){ mode="week"; }
    try{ hidden=JSON.parse(localStorage.getItem("tl_cal_hidden")||"{}")||{}; }catch(e){ hidden={}; }
    $("seg-week").classList.toggle("on",mode==="week");
    $("seg-month").classList.toggle("on",mode==="month");
    $("cal-prev").addEventListener("click", function(){ shiftRange(-1); });
    $("cal-next").addEventListener("click", function(){ shiftRange(1); });
    $("cal-today").addEventListener("click", goToday);
    if($("gcal-btn")) $("gcal-btn").addEventListener("click", connectGcal);
    if($("gcal-cal")) $("gcal-cal").addEventListener("change", function(){ if(this.value) setGcalTarget(this.value); });
    initGcal();
    $("seg-week").addEventListener("click", function(){ setMode("week"); });
    $("seg-month").addEventListener("click", function(){ setMode("month"); });
    if($("cal-add")) $("cal-add").addEventListener("click", function(){ openAdd(); });
    if($("ca-student")) $("ca-student").addEventListener("change", applyStudentDefaults);
    if($("ca-cancel")) $("ca-cancel").addEventListener("click", closeAdd);
    if($("ca-save")) $("ca-save").addEventListener("click", saveAdd);
    if($("add-modal")) $("add-modal").addEventListener("click", function(e){ if(e.target===$("add-modal")) closeAdd(); });
    initLegend();
    // Clicks inside the popover (buttons, date/time fields) shouldn't bubble to the
    // document listener below, which closes it on any outside click.
    $("cal-pop").addEventListener("click", function(e){ e.stopPropagation(); });
    document.addEventListener("click", hidePopover);
    window.addEventListener("resize", hidePopover);
    if(window.TL && TL.promotePastLessons) TL.promotePastLessons();
    ensureData();
  }

  if (window.__CAL_TEST__) {
    window.CAL = { seed:function(s,sl,l,a,m,ex){
      students=s; slots=sl; exams=ex||[]; loadedStatic=true; anchor=a; mode=m||"week";
      nameById={}; locById={}; hhById={}; s.forEach(function(x){ nameById[x.id]=x.name; locById[x.id]=x.location||""; hhById[x.id]=hhKey(x.contact); });
      lessonCache={}; (l||[]).forEach(function(x){ var k=x.lesson_date.slice(0,7); (lessonCache[k]=lessonCache[k]||[]).push(x); });
      var w=$("seg-week"), mo=$("seg-month");
      if(w) w.classList.toggle("on",mode==="week"); if(mo) mo.classList.toggle("on",mode==="month");
    }, render:render, ensureData:ensureData, initLegend:initLegend,
       go:function(a,m){ anchor=a; if(m) mode=m; },
       blocks:function(){ return buildBlocks(visibleRange()); },
       cachedMonths:function(){ return Object.keys(lessonCache); } };
  } else {
    TL.requireAuth("calendar", init);
  }
})();
