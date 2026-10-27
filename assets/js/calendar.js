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
  var HOUR_PX = 46, HOUR_PX_BASE = 46, MIN_HR = 6;

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

  // ---- view modes ----
  // Desktop: week | month. Phone adds day (week strip + one-day timeline), 3day and list.
  var PHONE_ONLY={day:1};
  function isPhone(){ return !!(window.matchMedia && window.matchMedia("(max-width:820px)").matches); }
  function effMode(m){ m=m||mode;
    if(m==="3day"||m==="list") m="week";   // retired trial views
    return (PHONE_ONLY[m] && !isPhone()) ? "week" : m; }
  function stepDays(m){ return m==="day"?1:(m==="3day"?3:7); }

  // ---- what span a given anchor+mode covers ----
  function rangeFor(a, m){
    m=effMode(m);
    if(m==="3day"){ var s0=new Date(a); s0.setHours(0,0,0,0); return { start:s0, end:addDays(s0,2) }; }
    if(m==="month"){
      var first=new Date(a.getFullYear(),a.getMonth(),1);
      var last=new Date(a.getFullYear(),a.getMonth()+1,0);
      return { start:mondayOf(first), end:addDays(mondayOf(last),6) };
    }
    var ws=mondayOf(a);
    return { start:ws, end:addDays(ws,6) };
  }
  function visibleRange(){ return rangeFor(anchor, mode); }
  var WDF=["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"];
  function monthsIn(range){
    var out=[], d=new Date(range.start.getFullYear(),range.start.getMonth(),1),
        endM=new Date(range.end.getFullYear(),range.end.getMonth(),1);
    while(d<=endM){ out.push(d.getFullYear()+"-"+pad(d.getMonth()+1)); d=new Date(d.getFullYear(),d.getMonth()+1,1); }
    return out;
  }
  function rangeLabel(){
    var m=effMode();
    if(m==="month") return MONF[anchor.getMonth()]+" "+anchor.getFullYear();
    if(m==="day") return MONF[anchor.getMonth()]+" "+anchor.getFullYear();
    var ws=(m==="3day")?rangeFor(anchor,m).start:mondayOf(anchor), end=addDays(ws,m==="3day"?2:6);
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
      window.sb.from("exams").select("id,student_id,exam_date,assessment_type,subject,topics,score,max_score,remarks"),
      // setup check: has this tutor ever confirmed a lesson? (one tiny query)
      window.sb.from("lessons").select("id").limit(1)
    ]);
    students=r[0].error?[]:(r[0].data||[]);
    nameById={}; locById={}; hhById={}; endById={};
    students.forEach(function(s){ nameById[s.id]=s.name; locById[s.id]=s.location||""; hhById[s.id]=hhKey(s.contact); endById[s.id]=s.end_date||null; });
    slots=r[1].error?[]:(r[1].data||[]);
    exams=r[2].error?[]:(r[2].data||[]);
    // Setup in progress = opened from the guide, or (worked out from the data, so it survives a refresh or
    // arriving from the tab bar) a weekly slot exists but no lesson has ever been logged.
    // Decided from the data alone (like Home's setup card), not from a saved "done" flag — so an account
    // that starts over (all lessons removed) is guided again.
    var everLogged=!!(r[3]&&!r[3].error&&r[3].data&&r[3].data.length);
    setupMode = !!TL.guide && (TL.guide.on || (slots.length>0 && !everLogged));
    if(TL.guide && everLogged && !TL.guide.on && !TL.guide.onboarded()) TL.guide.finish();   // established tutor, new browser
    // During setup the "Not logged" lessons ARE the next step — never hide them (not saved as a preference).
    // Setup step 3 is the same for everyone: this week, in Week view (not saved as a preference).
    if(setupMode && !TL.guide.onboarded() && effMode()!=="week"){ mode="week"; anchor=new Date(); }
    if(setupMode && hidden.proj){
      delete hidden.proj;
      var lg=document.querySelector('.cal-legend [data-cat="proj"]'); if(lg){ lg.classList.remove("off"); lg.setAttribute("aria-pressed","true"); }
    }
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
    neighborMonths().forEach(function(k){ jobs.push(fetchMonth(k)); });   // panes either side are real too
    await Promise.all(jobs);
    render();
    prefetchAdjacent();
  }
  // The months touched by one step back and one step forward (week or month).
  function neighborMonths(){
    var out={};
    [-1,1].forEach(function(dir){
      var m=effMode();
      var a2 = m==="month" ? new Date(anchor.getFullYear(),anchor.getMonth()+dir,1) : addDays(anchor,dir*stepDays(m));
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
  function buildBlocks(range, all){
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
    // Client view hides the Paid/Unpaid switches, so ignore those two filters there (otherwise lessons vanish with no way back).
    var cv=document.body.classList.contains("client-view");
    return all ? blocks : blocks.filter(function(b){ return !hidden[b.state] || (cv && (b.state==="paid"||b.state==="unpaid")); });   // legend toggles (all=true ignores them)
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
  // Renderers paint into calEl(): normally #cal, but during render() each carousel pane in turn.
  var HOST=null, SHARED=null, stickyBd=null;
  function calEl(){ return HOST || $("cal"); }
  function renderWeek(range){ renderGrid(range, [0,1,2,3,4,5,6].map(function(d){ return addDays(range.start,d); }), calEl()); }
  // Time grid for any run of dates (1 = day, 3 = three days, 7 = week), Google-Calendar style.
  function renderGrid(range, dates, el, opts){
    opts=Object.assign({}, opts||{}, SHARED||{}); var HOUR_PX=opts.hourPx||HOUR_PX_BASE;
    var G=!opts.noGutter;   // in the carousel the hour labels live outside, fixed
    var blocks=buildBlocks(range), keys=dates.map(iso);
    var byCol=dates.map(function(){ return []; });
    blocks.forEach(function(b){ var i=keys.indexOf(b.dateISO); if(i>=0) byCol[i].push(b); });
    byCol.forEach(laneAssign);
    lastBlocks=blocks;
    var shown=[].concat.apply([],byCol);
    var bd=opts.bd||bounds(opts.boundsFrom||shown), hours=(bd.end-bd.start)/60, gridH=hours*HOUR_PX, today=iso(new Date());
    var headCells="";
    dates.forEach(function(date){
      var isT=iso(date)===today;
      headCells+='<div class="cal-day-h'+(isT?" today":"")+'">'+DAY[(date.getDay()+6)%7]+'<b>'+date.getDate()+'</b></div>';
    });
    var examsByDt=examsByDate(), adCells="", hasEx=false;
    dates.forEach(function(date){
      var dayExams=examsByDt[iso(date)]||[];
      if(dayExams.length) hasEx=true;
      // Carousel: a fixed slim row — first exam + "+N" — so weeks with and without exams line up.
      adCells+='<div class="cal-ad-cell">'+(opts.slimAllday
        ? (dayExams.length===1 ? examChipHTML(dayExams[0])
          : dayExams.length ? '<button type="button" class="cal-chip is-exam ad-all" data-exday="'+iso(date)+'" aria-label="See all '+dayExams.length+' exams">◷ '+dayExams.length+'<span class="ad-lbl"> exams</span></button>' : '')
        : dayExams.map(examChipHTML).join(""))+'</div>';
    });
    var gutter="";
    for(var h=0; h<hours; h++)
      gutter+='<div class="cal-hr" style="height:'+HOUR_PX+'px"><span>'+hourLabel(bd.start+h*60)+'</span></div>';
    var cols="";
    dates.forEach(function(date,c){
      var isTc=iso(date)===today, evs="";
      byCol[c].forEach(function(b){
        var top=(b.startMin-bd.start)/60*HOUR_PX, height=(b.endMin-b.startMin)/60*HOUR_PX;
        evs+=evHTML(b, top, height);
      });
      cols+='<div class="cal-col'+(isTc?" today":"")+'">'+evs+'</div>';
    });
    var gridBg="background-image:repeating-linear-gradient(var(--line) 0 1px,transparent 1px "+HOUR_PX+"px)";
    var gh=G?'<div class="cal-gutter-h"></div>':'';
    el.innerHTML=(opts.noHead?'':'<div class="cal-head">'+gh+headCells+'</div>')+
      ((hasEx||opts.forceAllday)?('<div class="cal-allday">'+gh+adCells+'</div>'):'')+
      '<div class="cal-body">'+(G?'<div class="cal-gutter">'+gutter+'</div>':'')+
      '<div class="cal-cols cols-'+dates.length+'" style="height:'+gridH+'px;'+gridBg+'">'+cols+'</div></div>';
    if(!shown.length && opts.noHead && G){ el.innerHTML='<div class="cal-empty">Nothing on '+WDF[(dates[0].getDay()+6)%7]+'. Swipe or tap another day.</div>'; wireEvents(); return; }
    if(!shown.length && G)
      el.innerHTML+='<div class="cal-empty">'+(dates.length===1?'No lessons on '+WDF[(dates[0].getDay()+6)%7]+'.':'No lessons or recurring slots in these days. Add slots on the Planner, or tap +.')+'</div>';
    wireEvents();
  }

  // Phone day view: a Mon–Sun strip (dots = lessons that day) that stays put, and the chosen day's
  // timeline, which is what slides.
  function dayStripHTML(range){
    var ws=range.start, blocks=buildBlocks(range), today=iso(new Date()), sel=iso(anchor);
    var count={}; blocks.forEach(function(b){ if(b.state!=="cancel") count[b.dateISO]=(count[b.dateISO]||0)+1; });
    var exD=examsByDate();
    return '<div class="dstrip">'+[0,1,2,3,4,5,6].map(function(d){
      var date=addDays(ws,d), k=iso(date), n=count[k]||0, dots="";
      for(var i=0;i<Math.min(n,3);i++) dots+='<i></i>';
      if((exD[k]||[]).length) dots+='<i class="ex"></i>';
      return '<button type="button" class="ds-d'+(k===sel?' on':'')+(k===today?' today':'')+'" data-day="'+k+'">'+
        '<span class="ds-w">'+DAY[d].charAt(0)+'</span><span class="ds-n">'+date.getDate()+'</span><span class="ds-dots">'+dots+'</span></button>';
    }).join("")+'</div>';
  }
  function renderDay(range){
    var d=new Date(anchor); d.setHours(0,0,0,0);
    var n=buildBlocks({start:d,end:d}).filter(function(b){ return b.state!=="cancel"; }).length;
    var host=calEl();
    host.innerHTML='<div class="dhead"><b>'+WDF[(d.getDay()+6)%7]+'</b> '+d.getDate()+' '+MON[d.getMonth()]+
      '<span>'+(n?n+' lesson'+(n===1?'':'s'):'')+'</span></div><div class="cal-dayg"></div>';
    renderGrid(range, [d], host.querySelector(".cal-dayg"), { noHead:true, hourPx:68 });
  }
  function render3(range){ renderGrid(range, [0,1,2].map(function(i){ return addDays(range.start,i); }), calEl(), { hourPx:56 }); }

  // ---- month (day-cell grid) ----
  function chipHTML(b){
    var cls="cal-chip is-"+b.state+(b.clash?" is-clash":"");
    return '<span class="'+cls+'" data-ev="'+esc(String(b.id))+'">'+(b.clash?'⚠ ':'')+hhmm2(b.startMin)+' '+esc(b.name)+'</span>';
  }
  function renderMonth(range){
    // Spill-over days from the months either side show only logged lessons: their Not logged ones
    // belong to that other month (and its Log chip), so the chip count matches what's on screen.
    var mo=anchor.getMonth();
    var blocks=buildBlocks(range).filter(function(b){ return !(b.kind==="proj" && new Date(b.dateISO+"T00:00:00").getMonth()!==mo); });
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
    calEl().innerHTML='<div class="cal-mhead">'+head+'</div><div class="cal-month">'+cells+'</div>';
    // click a day (not a chip) → open that week
    calEl().querySelectorAll(".cal-mday").forEach(function(cell){
      cell.addEventListener("click", function(){ anchor=new Date(cell.dataset.day+"T00:00:00"); setMode("week"); });
    });
    wireEvents();
  }

  // ---- phone week: agenda list (a 7-column time grid is unreadable at 390px) ----
  var phoneMQ = window.matchMedia ? window.matchMedia("(max-width:820px)") : { matches:false };
  var STATE_TAG = { paid:"Paid", unpaid:"Unpaid", sched:"", proj:"Not logged", cancel:"Cancelled" };
  function durLabel(min){ var h=min/60; return (Math.round(h*10)/10)+" h"; }
  function renderAgenda(range){
    var ws=range.start, blocks=buildBlocks(range);
    var byDay=[[],[],[],[],[],[],[]];
    blocks.forEach(function(b){ byDay[b.day].push(b); });
    byDay.forEach(laneAssign);   // flags clashes
    lastBlocks=blocks;
    var today=iso(new Date()), examsByDt=examsByDate(), html="", any=false;
    for(var d=0; d<7; d++){
      var date=addDays(ws,d), di=iso(date), isT=di===today;
      var rows=byDay[d].slice().sort(function(a,b){ return a.startMin-b.startMin; });
      var ex=examsByDt[di]||[];
      if(!rows.length && !ex.length && !isT) continue;
      any=true;
      html+='<section class="ag-day'+(isT?' today':'')+'"><div class="ag-dh"><span class="ag-dw">'+DAY[d]+'</span> '+
        date.getDate()+' '+MON[date.getMonth()]+(isT?'<span class="ag-today">Today</span>':'')+'</div>';
      if(ex.length) html+='<div class="ag-ex">'+ex.map(examChipHTML).join("")+'</div>';
      if(!rows.length) html+='<div class="ag-none">No lessons</div>';
      else html+='<div class="ag-list">'+rows.map(function(b){
        var sub=[b.subject,b.level,b.location].filter(Boolean).join(" · "), tag=STATE_TAG[b.state]||"";
        return '<button type="button" class="ag-row is-'+b.state+(b.clash?' is-clash':'')+'" data-ev="'+esc(String(b.id))+'">'+
          '<span class="ag-t"><b>'+hhmm2(b.startMin)+'</b><small>'+durLabel(b.endMin-b.startMin)+'</small></span>'+
          '<span class="ag-bar"></span>'+
          '<span class="ag-main"><span class="ag-n">'+esc(b.name)+(b.adhoc?' ✦':'')+(b.postponed?' ↻':'')+'</span>'+
          (sub?'<span class="ag-s">'+esc(sub)+'</span>':'')+'</span>'+
          (b.clash?'<span class="ag-tag clash">Clash</span>':(tag?'<span class="ag-tag">'+tag+'</span>':''))+'</button>';
      }).join("")+'</div>';
      html+='</section>';
    }
    calEl().innerHTML = any ? '<div class="ag">'+html+'</div>' :
      '<div class="cal-empty">No lessons this week. Add slots on the Planner, or tap + Add.</div>';
    wireEvents();
  }

  function render(){
    if(!$("cal")) return;
    $("cal-range").textContent=rangeLabel();
    // Phones: "Today" only appears once you've moved away from the period that contains today.
    var now=new Date(), em=effMode(), here=
      em==="day"   ? iso(anchor)===iso(now) :
      em==="month" ? anchor.getFullYear()===now.getFullYear() && anchor.getMonth()===now.getMonth() :
                     iso(mondayOf(anchor))===iso(mondayOf(now));
    var nav=document.querySelector(".cal-nav"); if(nav) nav.classList.toggle("away", !here);
    var m=effMode();
    document.body.classList.toggle("cal-agenda", m==="list");
    document.body.classList.toggle("cal-dayview", m==="day");
    ["day","3day","week","list","month"].forEach(function(k){ var b=$("seg-"+k); if(b) b.classList.toggle("on", k===m); });
    var fn = m==="month"?renderMonth : m==="list"?renderAgenda : m==="day"?renderDay : m==="3day"?render3 : renderWeek;
    var cal=$("cal"), grid=(m==="week"||m==="day"||m==="3day");
    var vp='<div class="cal-vp" id="cal-vp"><div class="cal-track" id="cal-track">'+
      '<div class="cal-pane"></div><div class="cal-pane"></div><div class="cal-pane"></div></div></div>';
    cal.innerHTML=(m==="day"?'<div id="cal-stripbox">'+dayStripHTML(visibleRange())+'</div>':'')+
      (grid?'<div class="cal-gwrap"><div class="cal-gfix" id="cal-gfix"></div>'+vp+'</div>':vp);
    var panes=cal.querySelectorAll(".cal-pane"), save=anchor;
    SHARED=null;
    if(grid){
      // One hour range for all three panes, so their rows line up with the fixed hour labels.
      var d0=new Date(save); d0.setHours(0,0,0,0);
      var span = m==="day" ? { start:addDays(d0,-1), end:addDays(d0,1) }     // just the three days you can swipe between
                           : { start:rangeFor(stepAnchor(save,-1),m).start, end:rangeFor(stepAnchor(save,1),m).end };
      // Hours = your teaching hours (every weekly Planner slot), widened only if a lesson nearby
      // falls outside them, so swiping never rescales the grid.
      var hp=m==="day"?68:(m==="3day"?56:HOUR_PX_BASE);
      var base=slots.map(function(sl){ return { startMin:toMin(sl.start_time), endMin:toMin(sl.end_time) }; });
      // Also count every lesson already loaded (this month and its neighbours), and only ever widen
      // while the page is open — so landing on a new week never rescales the grid.
      var loaded=[]; Object.keys(lessonCache).forEach(function(k){ (lessonCache[k]||[]).forEach(function(l){
        if(l.status!=="cancelled" && l.start_time && l.end_time) loaded.push({ startMin:toMin(l.start_time), endMin:toMin(l.end_time) }); }); });
      var bd=bounds(base.concat(loaded, buildBlocks(span)));
      if(stickyBd) bd={ start:Math.min(bd.start,stickyBd.start), end:Math.max(bd.end,stickyBd.end) };
      stickyBd=bd;
      SHARED={ noGutter:true, bd:bd, hourPx:hp, forceAllday:true, slimAllday:true };
      var gut="";
      for(var h=0; h<(bd.end-bd.start)/60; h++) gut+='<div class="cal-hr" style="height:'+hp+'px"><span>'+hourLabel(bd.start+h*60)+'</span></div>';
      $("cal-gfix").innerHTML='<div class="cal-gspace"></div>'+gut;
    }
    // neighbours first, the current view last (so popovers/clash data belong to what you see)
    [[0,-1],[2,1],[1,0]].forEach(function(p){
      var a=p[1]?stepAnchor(save,p[1]):save;
      anchor=a; HOST=panes[p[0]];
      try{ fn(rangeFor(a,m)); } finally{ HOST=null; anchor=save; }
    });
    SHARED=null;
    if(grid) alignGutter();
    updateLogBar();
    fitHeight();
    cal.querySelectorAll(".ds-d").forEach(function(btn){
      btn.addEventListener("click", function(e){ e.stopPropagation(); jumpTo(new Date(btn.dataset.day+"T00:00:00")); });
    });
  }
  // Line the fixed hour labels up with the panes: equal exam rows, then a spacer as tall as the headers.
  function alignGutter(){
    var vp=$("cal-vp"), g=$("cal-gfix"); if(!vp||!g) return;
    var ad=vp.querySelectorAll(".cal-allday"), mh=0;
    ad.forEach(function(x){ x.style.minHeight=""; mh=Math.max(mh,x.offsetHeight); });
    ad.forEach(function(x){ x.style.minHeight=mh+"px"; });
    var cur=vp.querySelectorAll(".cal-pane")[1], body=cur&&cur.querySelector(".cal-body");
    if(body) g.querySelector(".cal-gspace").style.height=(body.getBoundingClientRect().top-cur.getBoundingClientRect().top)+"px";
  }
  // The viewport takes the current pane's height so a short neighbour doesn't leave a gap.
  function fitHeight(){ var vp=$("cal-vp"), p=vp&&vp.querySelectorAll(".cal-pane")[1]; if(p) vp.style.height=p.offsetHeight+"px"; }
  // While moving, open the viewport to the tallest pane so the incoming one is never cut off.
  function openHeight(){ var vp=$("cal-vp"); if(!vp) return; var h=0;
    vp.querySelectorAll(".cal-pane").forEach(function(p){ h=Math.max(h,p.offsetHeight); }); vp.style.height=h+"px"; }
  if(phoneMQ.addEventListener) phoneMQ.addEventListener("change", function(){ if(loadedStatic) render(); });

  function wireEvents(){
    calEl().querySelectorAll("[data-ev]").forEach(function(node){
      node.addEventListener("click", function(e){ e.stopPropagation(); showPopover(node); });
    });
    calEl().querySelectorAll("[data-exam]").forEach(function(node){
      node.addEventListener("click", function(e){ e.stopPropagation(); showExamPopover(node); });
    });
    calEl().querySelectorAll("[data-exday]").forEach(function(node){
      node.addEventListener("click", function(e){ e.stopPropagation(); showExamDayPopover(node); });
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
    var label={paid:["Paid","rgba(15,118,110,.14)","#0B5D57"], unpaid:["Unpaid","rgba(180,67,47,.12)","#8a2f22"],
      sched:["Scheduled","rgba(19,35,63,.10)","var(--navy)"], cancel:["Cancelled","#F1EFEA","var(--muted)"],
      proj:["Not logged yet","rgba(15,118,110,.12)","#0B5D57"]}[b.state];
    var dt=new Date(b.dateISO+"T00:00:00");
    var when=DAY[(dt.getDay()+6)%7]+" "+dt.getDate()+" "+MON[dt.getMonth()]+" · "+hhmm2(b.startMin)+"–"+hhmm2(b.endMin);
    var sub=[b.subject,b.level].filter(Boolean).join(" · "), cv=!!(window.TL&&TL.isClient&&TL.isClient());
    pop.innerHTML='<span class="cp-x" id="cp-x">×</span><h4>'+esc(b.name)+'</h4>'+
      '<div class="cp-row">'+esc(when)+'</div>'+
      (sub?'<div class="cp-row"><b>'+esc(sub)+'</b></div>':'')+
      (b.location?'<div class="cp-row">◍ <b>'+esc(b.location)+'</b></div>':'')+
      (b.kind==="lesson"&&b.amount!=null&&!cv?'<div class="cp-row">'+(b.state==="cancel"?"Compensation":"Amount")+' <b>'+TL.sgd(b.amount)+'</b></div>':'')+
      (b.clash?'<div class="cp-row" style="color:var(--owed);font-weight:700">⚠ Overlaps another lesson</div>':'')+
      (cv&&(b.state==="paid"||b.state==="unpaid")?'':'<span class="cp-tag" style="background:'+label[1]+';color:'+label[2]+'">'+label[0]+'</span>')+
      (b.adhoc?' <span class="cp-tag" style="background:rgba(19,35,63,.10);color:var(--navy)">✦ One-off</span>':'')+
      (b.postponed?' <span class="cp-tag" style="background:rgba(180,83,9,.18);color:#92400E">Postponed</span>':'')+
      actionButtons(b)+
      (cv?'':'<a class="cp-act" href="ledger">'+(b.kind==="proj"?"Open Ledger":"Edit in Ledger")+' →</a>');
    pop.style.display="block";
    var pbd=$("cal-pop-bd"); if(pbd) pbd.classList.add("on");
    positionPopover(node);
    $("cp-x").addEventListener("click", hidePopover);
    var cancelBtn=$("cp-cancel"); if(cancelBtn) cancelBtn.addEventListener("click", function(){ showCancelForm(b); });
    var restoreBtn=$("cp-restore"); if(restoreBtn) restoreBtn.addEventListener("click", function(){ doRestore(b); });
    var deleteBtn=$("cp-delete"); if(deleteBtn) deleteBtn.addEventListener("click", function(){ doDelete(b.id); });
    var postponeBtn=$("cp-postpone"); if(postponeBtn) postponeBtn.addEventListener("click", function(){ showPostponeForm(b); });
    var revertBtn=$("cp-revert"); if(revertBtn) revertBtn.addEventListener("click", function(){ doRevert(b); });
    var logBtn=$("cp-log"); if(logBtn) logBtn.addEventListener("click", function(){ doLogProjected(b); });
  }
  // Exam details first (like lessons); Exams page and student profile are one tap away.
  function showExamPopover(node){
    var ex=exams.filter(function(x){ return String(x.id)===String(node.dataset.exam); })[0]; if(!ex) return;
    popNode=node;
    var pop=$("cal-pop"), dt=new Date(ex.exam_date+"T00:00:00");
    var now=new Date(); now.setHours(0,0,0,0);
    var days=Math.round((dt-now)/86400000);
    var when=days===0?"Today":(days===1?"Tomorrow":(days>1?"In "+days+" days":(days===-1?"Yesterday":Math.abs(days)+" days ago")));
    var title=[ex.assessment_type,ex.subject].filter(Boolean).join(" · ")||"Exam";
    var hasScore=ex.score!=null&&ex.max_score, cv=!!(window.TL&&TL.isClient&&TL.isClient());
    var tag=(cv&&days<0)?'':days>=0
      ? '<span class="cp-tag" style="background:'+(days<=14?'rgba(180,83,9,.12);color:var(--warn)':'#F1EFEA;color:var(--muted)')+'">'+when+'</span>'
      : (hasScore?'<span class="cp-tag" style="background:var(--accent-soft);color:var(--accent)">'+esc(ex.score+"/"+ex.max_score)+' · '+Math.round(ex.score/ex.max_score*100)+'%</span>'
                 :'<span class="cp-tag" style="background:#F1EFEA;color:var(--muted)">No result yet</span>');
    pop.innerHTML='<span class="cp-x" id="cp-x">×</span><h4>'+esc(nameById[ex.student_id]||"—")+'</h4>'+
      '<div class="cp-row"><b>'+esc(title)+'</b></div>'+
      '<div class="cp-row">'+DAY[(dt.getDay()+6)%7]+' '+dt.getDate()+' '+MON[dt.getMonth()]+' '+dt.getFullYear()+(days<0?' · '+when:'')+'</div>'+
      (ex.topics?'<div class="cp-row">Topics <b>'+esc(ex.topics)+'</b></div>':'')+
      (ex.remarks?'<div class="cp-row">'+esc(ex.remarks)+'</div>':'')+
      tag+
      '<div class="cp-btns"><a class="cp-btn primary" style="text-decoration:none" href="exams?highlight='+encodeURIComponent(ex.id)+'">'+(days<0&&!hasScore?'Add result in Exams':'Open in Exams')+'</a>'+
      '<a class="cp-btn" style="text-decoration:none" href="student?id='+encodeURIComponent(ex.student_id)+'">Student profile</a></div>';
    pop.style.display="block";
    var pbd=$("cal-pop-bd"); if(pbd) pbd.classList.add("on");
    positionPopover(node);
    $("cp-x").addEventListener("click", hidePopover);
  }
  // "+N" on a day with several exams: list every exam that day; tap one for its details.
  function showExamDayPopover(node){
    var dayISO=node.dataset.exday, list=(examsByDate()[dayISO]||[]).slice()
      .sort(function(a,b){ return (nameById[a.student_id]||"").localeCompare(nameById[b.student_id]||""); });
    if(!list.length) return;
    popNode=node;
    var pop=$("cal-pop"), dt=new Date(dayISO+"T00:00:00");
    pop.innerHTML='<span class="cp-x" id="cp-x">×</span>'+
      '<h4>'+list.length+' exams</h4>'+
      '<div class="cp-row">'+DAY[(dt.getDay()+6)%7]+' '+dt.getDate()+' '+MON[dt.getMonth()]+' '+dt.getFullYear()+'</div>'+
      '<div class="cp-exlist">'+list.map(function(ex){
        var what=[ex.assessment_type,ex.subject].filter(Boolean).join(" · ")||"Exam";
        return '<button type="button" class="cp-exitem" data-exam="'+esc(String(ex.id))+'">'+
          '<b>'+esc(nameById[ex.student_id]||"—")+'</b><span>'+esc(what)+'</span></button>';
      }).join("")+'</div>';
    pop.style.display="block";
    var pbd=$("cal-pop-bd"); if(pbd) pbd.classList.add("on");
    positionPopover(node);
    $("cp-x").addEventListener("click", hidePopover);
    pop.querySelectorAll(".cp-exitem").forEach(function(btn){
      btn.addEventListener("click", function(e){ e.stopPropagation(); showExamPopover(btn); popNode=node; positionPopover(node); });
    });
  }
  function hidePopover(){ var p=$("cal-pop"); if(p) p.style.display="none"; var pbd=$("cal-pop-bd"); if(pbd) pbd.classList.remove("on"); popNode=null; }
  // After any write, the visible range (and whichever month a lesson may have moved
  // into/out of) needs fresh data — simplest correct fix is to drop the whole cache.
  function refreshAfterMutation(){ hidePopover(); lessonCache={}; ensureData(); }
  function confirmBox(msg, opts){   // → the app-wide dialog (TL.confirm); kept so existing calls read the same
    opts=opts||{};
    return TL.confirm({ title:opts.title||"Confirm", message:msg, confirmText:opts.yes||"Confirm", cancelText:opts.no||"Cancel", danger:!!opts.danger });
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
    var res=await window.sb.from("lessons").insert(row); if(!res.error) gAuto();
    if(res.error){TL.alert("Couldn't log: "+res.error.message);return;}
    refreshAfterMutation();
  }

  // ---- "Log lessons": turn every faded (not logged) block in the period on screen into real lessons ----
  // Week view logs that Mon–Sun, Month view that calendar month, Day view that day. Uses the same
  // projection as the faded blocks (so what you see is what gets logged) and ignores the legend toggles.
  function logTarget(){
    var m=effMode(), a=new Date(anchor); a.setHours(0,0,0,0);
    var today=new Date(); today.setHours(0,0,0,0);
    if(m==="month"){
      var s0=new Date(a.getFullYear(),a.getMonth(),1), e0=new Date(a.getFullYear(),a.getMonth()+1,0);
      var cur=today.getFullYear()===a.getFullYear()&&today.getMonth()===a.getMonth();
      return { start:s0, end:e0, when:cur?"this month":"in "+MONF[a.getMonth()], confirmWhen:MONF[a.getMonth()]+" "+a.getFullYear() };
    }
    if(m==="day"){
      var lbl=a.toLocaleDateString("en-SG",{weekday:"short",day:"numeric",month:"short"});
      return { start:a, end:a, when:iso(a)===iso(today)?"today":"on "+lbl, confirmWhen:lbl };
    }
    var ws=mondayOf(a), we=addDays(ws,6), rl=rangeLabel();
    return { start:ws, end:we, when:iso(mondayOf(today))===iso(ws)?"this week":"for "+rl, confirmWhen:rl };
  }
  function unloggedIn(t){ return buildBlocks({ start:t.start, end:t.end }, true).filter(function(b){ return b.kind==="proj"; }); }
  function updateLogBar(){
    var btn=$("cal-log-btn"); if(!btn) return;
    var t=logTarget(), n=hidden.proj ? 0 : unloggedIn(t).length;   // hidden while "Not logged" is filtered out
    btn.hidden=!n;
    guideStep(n);
    if(!n) return;
    $("cal-log-txt").textContent="Log "+n;
    btn.title=n+" lesson"+(n===1?"":"s")+" not logged "+t.when+" — tap to log";
    btn.setAttribute("aria-label", btn.title);
    whenNoTip(function(){
      if(btn.hidden || !(window.TL && TL.coach)) return;
      TL.coach("cal-log", btn, "<b>Log lessons</b><br>Logs every <b>Not logged</b> lesson on screen in one tap.");
    });
  }
  // First-run guide, step 3: point at the Log chip; logging finishes setup.
  var guideFinished=false, setupMode=false;
  function guideStep(n){
    if(!setupMode||guideFinished) return;
    var btn=$("cal-log-btn"); if(btn) btn.classList.toggle("tg-hint", n>0);
    // One standard step 3, whether this week's first lesson is still to come or already passed.
    TL.guide.card({step:3, title:"Tap Log to confirm this week\u2019s lessons.",
      text:n>0 ? "Dashed blocks are your weekly lessons, not confirmed yet."
               : "No lessons on this screen. Go back to this week to see them."});
  }
  function guideFinish(){
    if(!setupMode||guideFinished) return;
    guideFinished=true; TL.guide.finish(); TL.store.remove("td_setup_started");   // Home won't repeat the finish line
    var btn=$("cal-log-btn"); if(btn) btn.classList.remove("tg-hint");
    // Same finish message for everyone, whether the lessons were past or still to come.
    TL.guide.card({final:true, done:"\u2713 You\u2019re all set up!",
      title:"Lessons that already happened show as Unpaid.",
      text:"Mark them paid in <b>Money</b> when the parent pays.",
      href:"home", cta:"Go to Home"});
  }

  // One tip at a time: if another tip is open, wait for its "Got it" before showing the next.
  function whenNoTip(fn){
    var open=document.querySelector(".td-tip");
    if(!open){ fn(); return; }
    var ok=open.querySelector(".td-tip-ok");
    if(!ok) return;
    if(!ok._tdQ){ ok._tdQ=[]; ok.addEventListener("click", function(){ var q=ok._tdQ; setTimeout(function(){ if(q.length) whenNoTip(q.shift()); /* rest chain via the next tip */ q.forEach(function(f){ whenNoTip(f); }); }, 150); }); }
    if(ok._tdQ.indexOf(fn)<0) ok._tdQ.push(fn);
  }
  async function logVisible(){
    var t=logTarget(), btn=$("cal-log-btn");
    // re-read these months fresh first, so lessons logged elsewhere (Ledger, another phone) aren't duplicated
    var keys=monthsIn({ start:t.start, end:t.end });
    keys.forEach(function(k){ delete lessonCache[k]; });
    btn.disabled=true;
    try{ await Promise.all(keys.map(fetchMonth)); } finally{ btn.disabled=false; }
    var todo=unloggedIn(t);
    if(!todo.length){ render(); return; }
    var ok=await confirmBox("Log "+todo.length+" lesson"+(todo.length===1?"":"s")+" for "+t.confirmWhen+" from your weekly schedule? Lessons already logged are skipped.",
      { title:"Log lessons", yes:"Log "+todo.length });
    if(!ok) return;
    var rows=todo.map(function(b){ return { tutor_id:userId, student_id:b.studentId, slot_id:b.slotId, lesson_date:b.dateISO, slot_date:b.dateISO,
      start_time:b.startHM, end_time:b.endHM, subject:b.subject, level:b.level, rate:b.rate, split:b.split||1,
      amount:splitAmt(b.rate,b.startHM,b.endHM,b.split), status:statusFor(b.dateISO,b.endHM), paid:false }; });
    btn.disabled=true;
    var res=await window.sb.from("lessons").insert(rows); if(!res.error) gAuto();
    btn.disabled=false;
    if(res.error){ TL.alert("Couldn't log: "+res.error.message); return; }
    refreshAfterMutation();
    guideFinish();
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
    var res=await window.sb.from("lessons").insert(row); if(!res.error) gAuto();
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
    var res=await window.sb.from("lessons").update({status:"cancelled",paid:false,paid_date:null,compensation:comp>0?comp:null}).eq("id",b.id); if(!res.error) gAuto();
    if(res.error){msg.textContent=res.error.message;msg.className="msg err";return;}
    refreshAfterMutation();
  }
  async function doRestore(b){
    var res=await window.sb.from("lessons").update({status:statusFor(b.dateISO,hhmm2(b.endMin)),compensation:null}).eq("id",b.id); if(!res.error) gAuto();
    if(res.error){TL.alert("Couldn't restore: "+res.error.message);return;}
    refreshAfterMutation();
  }
  async function doDelete(id){
    if(!(await confirmBox("Delete this lesson permanently? Use Cancel instead if you just want to void it.", {title:"Delete lesson", yes:"Delete", danger:true}))) return;
    var res=await window.sb.from("lessons").delete().eq("id",id); if(!res.error) gAuto();
    if(res.error){TL.alert("Couldn't delete: "+res.error.message);return;}
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
    if(!b.slotId||!b.slotDate){ TL.alert("This lesson has no original slot to revert to."); return; }
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
    var res=await window.sb.from("lessons").update({lesson_date:date,start_time:start,end_time:end,amount:amount,status:statusFor(date,end),postponed:false}).eq("id",b.id); if(!res.error) gAuto();
    if(res.error){ TL.alert("Couldn't revert: "+res.error.message); return; }
    refreshAfterMutation();
  }
  async function savePostpone(b){
    var date=$("cp-pdate").value, start=$("cp-pstart").value, end=$("cp-pend").value, msg=$("cp-pmsg");
    if(!date||!start||!end){msg.textContent="Pick a date, start and end time.";msg.className="msg err";return;}
    if(end<=start){msg.textContent="End time must be after start time.";msg.className="msg err";return;}
    var amount=amtFor(b.rate, b.split, b.amount, b.startMin, b.endMin, start, end);   // keep earnings in step with the new duration
    var res=await window.sb.from("lessons").update({lesson_date:date,start_time:start,end_time:end,amount:amount,status:statusFor(date,end),postponed:true}).eq("id",b.id); if(!res.error) gAuto();
    if(res.error){msg.textContent="Couldn't postpone: "+res.error.message;msg.className="msg err";return;}
    refreshAfterMutation();
  }

  // ---- Google Calendar sync (client-side OAuth via Google Identity Services) ----
  var GCLIENT=(window.TLENG_CONFIG||{}).GOOGLE_CLIENT_ID||"";
  var GSCOPE="https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.calendarlist.readonly", GTZ="Asia/Singapore";
  var gToken=null, gTokenExp=0, gTokenClient=null, gUserInit=false;
  var gNext=null;      // one-off follow-up for the next token reply (Change account); replaces the default sync
  function gTokenValid(){ return !!gToken && Date.now()<gTokenExp; }   // reuse an unexpired token, no fresh Google popup

  function gcalConfigured(){ return !!GCLIENT; }
  function gcalConnected(){ try{ return TL.store.get("tl_gcal_connected")==="1"; }catch(e){ return false; } }
  function gcalListGranted(){ try{ return TL.store.get("tl_gcal_list")==="1"; }catch(e){ return false; } }
  function gcalChosen(){ try{ return TL.store.get("tl_gcal_chosen")==="1"; }catch(e){ return false; } }
  function gcalTarget(){ try{ return TL.store.get("tl_gcal_calendar")||"primary"; }catch(e){ return "primary"; } }
  function gStatus(t,cls){ var el=$("gcal-status"); if(el){ el.textContent=t||""; el.className="gcal-status"+(cls?" "+cls:""); } }
  function gcalCals(){ try{ return JSON.parse(TL.store.get("tl_gcal_cals")||"[]")||[]; }catch(e){ return []; } }
  // Safety: the Google account this tutor linked (its primary calendar id = the account email), and the
  // account the current token belongs to. Sync only when they match, so one tutor can never write into
  // (or clean up) another person's Google Calendar from a shared browser.
  var gTokenAccount=null;
  function gcalAccount(){ return TL.store.get("tl_gcal_account")||""; }
  function gOwnerOf(ev){ try{ return ev.extendedProperties.private.tlOwner||""; }catch(e){ return ""; } }
  // Revoke the live token on sign-out (app.js calls this).
  window.TD_GCAL_REVOKE=function(){ if(gMode==="server"){ gToken=null; gTokenExp=0; return; } try{ if(gToken && window.google && google.accounts && google.accounts.oauth2) google.accounts.oauth2.revoke(gToken, function(){}); }catch(e){} gToken=null; gTokenExp=0; };
  // A connection attempt failed — drop back to the Connect step (clear the loaded list so the
  // dropdown gives way to the Connect button). Keep the chosen calendar so reconnect resumes it.
  function gcalFail(msg){
    gToken=null; gTokenExp=0; gTokenAccount=null;
    try{ TL.store.remove("tl_gcal_connected"); TL.store.remove("tl_gcal_list"); TL.store.remove("tl_gcal_cals"); }catch(e){}
    updateGcalUI();
    gStatus(msg||"Couldn't connect to Google — click Connect to try again.","err");
  }
  // ---- "Connect once" (server mode): api/gcal keeps an encrypted long-lived Google key per tutor and hands
  // out fresh 1-hour passes, so there's no Google pop-up after the first connect, on any device.
  // gMode: "?" not checked yet · "server" api/gcal is set up · "legacy" it isn't (falls back to the pop-up flow).
  var gMode="?", gLinked=false;
  async function gServer(action, extra){
    try{
      var s=await window.sb.auth.getSession(), jwt=s&&s.data&&s.data.session&&s.data.session.access_token;
      if(!jwt) return { status:401, data:{} };
      var r=await fetch("/api/gcal", { method:"POST", headers:{ "Content-Type":"application/json", Authorization:"Bearer "+jwt },
        body:JSON.stringify(Object.assign({ action:action }, extra||{})) });
      var d={}; try{ d=await r.json(); }catch(e){}
      return { status:r.status, data:d||{} };
    }catch(e){ return { status:0, data:{} }; }
  }
  function gTake(d){                                         // a pass from the server → use it like a pop-up token
    gToken=d.access_token; gTokenExp=Date.now()+(((+d.expires_in||3600)*1000)-60000);
    gTokenAccount=d.email||null; gLinked=true; gMode="server";
    try{ TL.store.set("tl_gcal_connected","1"); TL.store.set("tl_gcal_list","1"); }catch(e){}
    if(gTokenAccount && !gcalAccount()) TL.store.set("tl_gcal_account", gTokenAccount);
    if(d.calendar && !gcalChosen()){ try{ TL.store.set("tl_gcal_calendar", d.calendar); TL.store.set("tl_gcal_chosen","1"); }catch(e){} }   // chosen on another device
  }
  // Fresh pass without any pop-up. true = got one; false = not linked / not available (gMode says which).
  async function gServerToken(){
    var r=await gServer("token");
    if(r.status===200 && r.data.access_token){ gTake(r.data); return true; }
    if(r.status===404 && r.data.error==="not_linked"){ gMode="server"; gLinked=false; return false; }
    if(r.status===401 && r.data.error==="revoked"){ gMode="server"; gLinked=false;
      gStatus("Google Calendar access was removed in your Google account. Tap Connect to link it again.","err"); return false; }
    if(r.status===401){ return false; }                       // TutorDeck session problem; leave the mode alone
    if(r.status===502){ gMode="server"; gLinked=true; return false; }   // Google hiccup; we're still linked
    gMode="legacy"; return false;                             // 503 not set up yet / 404 no function → pop-up flow
  }
  // Send the browser to Google's consent page (a full page, not a pop-up: works the same on phones).
  async function gServerConnect(){
    gStatus("Opening Google…");
    var r=await gServer("start", { ret:"/calendar" });
    if(r.status===200 && r.data.url){ location.href=r.data.url; return; }
    gStatus(r.data.error==="host" ? "Google Calendar can't be connected from this address. Use tutordeck.vercel.app." : "Couldn't reach Google — try again.","err");
  }
  var G_ERR={ access_denied:"Google Calendar wasn't connected (you cancelled on Google's page).",
    scope:"Google Calendar wasn't connected: please leave both permission boxes ticked so lessons can sync.",
    expired:"That took a while, so Google Calendar wasn't connected. Tap Connect to try again.",
    no_refresh:"Google didn't finish connecting. Tap Connect to try again." };
  // Back from Google's page: the address ends in #gcal=<sealed key> (or #gcal_error=…). Save it to this tutor.
  async function gServerFinish(){
    var h=location.hash||"", m=h.match(/[#&]gcal=([A-Za-z0-9_-]+)/), e=h.match(/[#&]gcal_error=([a-z_]+)/);
    if(!m && !e) return false;
    try{ history.replaceState(null, "", location.pathname+location.search); }catch(x){}
    if(e){ gMode="server"; gStatus(G_ERR[e[1]]||"Google Calendar wasn't connected. Tap Connect to try again.","err"); return true; }
    gStatus("Finishing the Google Calendar connection…");
    var blob=m[1], r=await gServer("finish", { blob:blob, expect:gcalAccount() });
    if(r.status===409 && r.data.error==="other_account"){
      var ok=await confirmBox("You connected "+r.data.email+", but this TutorDeck account syncs to "+r.data.linked+". Sync to "+r.data.email+" from now on? Lessons already on "+r.data.linked+" stay there.",
        { title:"Different Google account", yes:"Use "+r.data.email, no:"Cancel" });
      if(!ok){ await gServer("finish", { blob:blob, decline:true }); gMode="server"; gStatus("Nothing changed. Lessons still sync to "+r.data.linked+".","ok"); return true; }
      r=await gServer("finish", { blob:blob, replace:true });
      if(r.status===200){ TL.store.set("tl_gcal_account", r.data.email); TL.store.remove("tl_gcal_chosen"); TL.store.remove("tl_gcal_calendar"); }
    }
    if(r.status!==200 || !r.data.access_token){
      gStatus(r.data.error==="no_table" ? "Google Calendar connect isn't switched on yet (database update pending)." : "Couldn't finish connecting Google Calendar. Tap Connect to try again.","err");
      return true;
    }
    gTake(r.data);
    await populateCalendars();
    if(gcalChosen()) syncNow(); else { updateGcalUI(); gStatus("Connected ✓ Now choose which calendar to sync into.","ok"); }
    return true;
  }
  // On opening Schedule: get a pass quietly and bring Google up to date (at most every 5 minutes).
  async function gcalBoot(){
    if(await gServerFinish()) return;
    var got=await gServerToken();
    if(got){
      await populateCalendars();
      var last=+(TL.store.get("tl_gcal_last")||0);
      if(gcalChosen() && Date.now()-last>5*60e3) syncNow();
      return;
    }
    if(gMode==="server" && !gLinked && gcalChosen() && !($("gcal-status")||{}).textContent)
      gStatus("Tap Sync now once to switch on automatic Google Calendar sync.");
  }
  // After a lesson is added / changed / cancelled / removed on this page: sync a moment later.
  var gAutoT=null;
  function gAuto(){
    if(!(gMode==="server" && gLinked && gcalChosen())) return;
    clearTimeout(gAutoT); gAutoT=setTimeout(function(){ syncNow(); }, 1500);
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
    var acct=$("gsync-acct"), linked=gcalAccount();
    if(acct){
      acct.classList.toggle("gcal-hide", !(hasCals && linked));
      var em=$("gsync-email"); if(em) em.textContent=linked;
    }
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
          if(gNext){ var nx=gNext; gNext=null; gUserInit=false;
            if(resp && resp.access_token){ gToken=resp.access_token; gTokenExp=Date.now()+(((+resp.expires_in||3600)*1000)-60000); gTokenAccount=null; }
            nx(!!(resp && resp.access_token)); return; }
          if(resp && resp.access_token){
            gToken=resp.access_token;
            gTokenExp=Date.now()+(((+resp.expires_in||3600)*1000)-60000);   // reuse until ~1min before expiry
            try{TL.store.set("tl_gcal_connected","1");}catch(e){}
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
          if(gNext){ var nx=gNext; gNext=null; nx(false); return; }
          if(gUserInit){ gUserInit=false; gcalFail(); }                // only reset on a deliberate click, not a silent load
        }
      });
      updateGcalUI();
      // No request on page load: Google can only ask in a popup, so a load-time request either gets
      // blocked or (after a double-click on Schedule) pops a sign-in window nobody asked for.
      // Syncing happens when you press Sync.
    });
  }
  async function connectGcal(){
    if(gMode==="server"){
      if(gTokenValid() || (gLinked && await gServerToken())){
        if(gcalChosen()) syncNow(); else if(gcalCals().length) gStatus("Choose a calendar to sync your lessons into."); else populateCalendars();
        return;
      }
      if(gMode==="server" && !gLinked){ gServerConnect(); return; }
      if(gMode==="server"){ gStatus("Google isn't responding — try again in a minute.","err"); return; }
    }
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
    // No Google account linked yet (first connect, or after Change account) → always show Google's account
    // picker, so it can't silently reuse whichever account this browser happens to be signed in to.
    gTokenClient.requestAccessToken({ prompt: !gcalAccount() ? "select_account consent" : (needConsent?"consent":"") });
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
      try{ TL.store.set("tl_gcal_list","1"); }catch(e){}
      var d=await res.json();
      var prim=(d.items||[]).filter(function(c){ return c.primary; })[0];
      gTokenAccount=(prim&&prim.id)||null;
      if(gTokenAccount && !gcalAccount()) TL.store.set("tl_gcal_account", gTokenAccount);   // first link: remember the account
      var items=(d.items||[]).filter(function(c){ return c.accessRole==="owner"||c.accessRole==="writer"; })
        .map(function(c){ return { v:c.primary?"primary":c.id, l:c.primary?"Main calendar":(c.summary||c.id) }; });
      try{ TL.store.set("tl_gcal_cals", JSON.stringify(items)); }catch(e){}   // remember for next load
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
      extendedProperties:{ private:{ tlengSync:"1", tlLessonId:String(l.id), tlOwner:String(userId) } } };  // tag + lesson + which TutorDeck tutor
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
  //
  // Ownership rules (several tutors can sync into one shared Google calendar):
  //  • tagged with this tutor's id (tlOwner)  → ours: kept, updated or removed as the ledger says.
  //  • tagged with ANOTHER tutor's id         → never touched.
  //  • untagged "legacy" event (made before tlOwner existed) → ours ONLY if its tlLessonId is one of
  //    this tutor's lessons (any status, any date — row-level security means we can only ever see our
  //    own). Then it's adopted: kept + stamped with tlOwner if the lesson is live in this month,
  //    removed if the lesson is cancelled or now sits in another month. Legacy events whose lesson
  //    no longer exists can't be proven ours, so they're left alone and counted in `unknown`.
  async function syncMonth(when){
    var cal=gcalTarget(), w=monthWindow(when), calP="/calendars/"+encodeURIComponent(cal)+"/events";
    var none={ created:0, updated:0, deleted:0, skipped:0, unknown:0, fail:1 };
    gStatus("Syncing "+w.label+"…");
    var events=await listAppEvents(cal, w.tmin, w.tmax);
    var mine=events.filter(function(ev){ return gOwnerOf(ev)===String(userId); });
    var legacy=events.filter(function(ev){ return !gOwnerOf(ev) && evLessonId(ev); });
    // ALL of this tutor's lessons in the month, cancelled ones included — used to decide ownership.
    var ls=await window.sb.from("lessons")
      .select("id,student_id,lesson_date,start_time,end_time,subject,level,amount,paid,status,postponed,slot_id,one_off")
      .eq("tutor_id", userId).gte("lesson_date", w.firstISO).lte("lesson_date", w.lastISO);
    if(ls.error) return none;
    var all=ls.data||[], ownIds={};
    all.forEach(function(l){ ownIds[String(l.id)]=1; });
    // Legacy events pointing at a lesson outside this month: check whether that lesson is ours.
    var ask=[]; legacy.forEach(function(ev){ var lid=evLessonId(ev); if(!ownIds[lid] && ask.indexOf(lid)<0) ask.push(lid); });
    for(var a=0;a<ask.length;a+=100){
      var chunk=ask.slice(a,a+100).filter(function(x){ return /^[0-9a-f-]{36}$/i.test(x); });
      if(!chunk.length) continue;
      var o=await window.sb.from("lessons").select("id").eq("tutor_id", userId).in("id", chunk);
      if(o.error) return none;
      (o.data||[]).forEach(function(r){ ownIds[String(r.id)]=1; });
    }
    var rows=all.filter(function(l){ return l.status!=="cancelled"; });   // what should be on the calendar
    var byLesson={}, toDel=[], unknown=0;
    mine.forEach(function(ev){ var lid=evLessonId(ev); if(lid && !byLesson[lid]) byLesson[lid]=ev; else toDel.push(ev); });  // dups of ours
    legacy.forEach(function(ev){
      var lid=evLessonId(ev);
      if(!ownIds[lid]){ unknown++; return; }                // can't prove it's ours → leave it alone
      if(!byLesson[lid]) byLesson[lid]=Object.assign({_legacy:true},ev); else toDel.push(ev);   // proven ours; extra copy = dup
    });
    var created=0, updated=0, deleted=0, skipped=0, fail=0, keep={};
    for(var i=0;i<rows.length;i++){
      var l=rows[i], want=gEvent(l), ev=byLesson[String(l.id)]; keep[String(l.id)]=1;
      try{
        if(!ev){ await gapi("POST", calP, want); created++; }
        // PUT replaces the event with `want`, which carries tlOwner — so an adopted legacy event stops being legacy.
        else if(ev._legacy || gFP(ev)!==gFP(want)){ await gapi("PUT", calP+"/"+encodeURIComponent(ev.id), want); updated++; }
        else skipped++;
      }catch(e){ if(e&&e.code===401) throw e; fail++; }
    }
    // Orphans: our events (tagged or proven legacy) whose lesson is cancelled, deleted, or moved out of this month.
    Object.keys(byLesson).forEach(function(lid){ if(!keep[lid]) toDel.push(byLesson[lid]); });
    for(var k=0;k<toDel.length;k++){ try{ await gapi("DELETE", calP+"/"+encodeURIComponent(toDel[k].id)); deleted++; }catch(e){ if(e&&e.code===401) throw e; fail++; } }
    return { created:created, updated:updated, deleted:deleted, skipped:skipped, unknown:unknown, fail:fail };
  }
  // Sync from the 1st of LAST month through the last month that has a lesson (capped +6mo) — so
  // last week's cancellations are caught even across a month boundary, and lessons logged for
  // future months go too. Older months are left untouched.
  async function syncNow(){
    if(!gTokenValid() && gMode==="server" && gLinked) await gServerToken();
    if(!gToken) return;
    if(!(await gcalAccountOK())) return;
    if(!loadedStatic) await loadStatic();
    var now=new Date(), fromM=new Date(now.getFullYear(), now.getMonth()-1, 1);
    var q=await window.sb.from("lessons").select("lesson_date").gte("lesson_date", iso(fromM)).order("lesson_date",{ascending:false}).limit(1);
    var lastISO=(!q.error && q.data && q.data[0] && q.data[0].lesson_date) || iso(fromM);
    var lastM=new Date(+lastISO.slice(0,4), (+lastISO.slice(5,7))-1, 1);
    var capM=new Date(now.getFullYear(), now.getMonth()+6, 1);
    if(lastM>capM) lastM=capM;
    var created=0, updated=0, deleted=0, skipped=0, unknown=0, fail=0, months=0, t0=Date.now();
    try{
      for(var cur=new Date(fromM); cur<=lastM; cur=new Date(cur.getFullYear(), cur.getMonth()+1, 1)){
        var r=await syncMonth(new Date(cur));
        created+=r.created; updated+=r.updated; deleted+=r.deleted; skipped+=r.skipped; unknown+=r.unknown||0; fail+=r.fail; months++;
      }
    }catch(e){ if(e&&e.code===401){ gStatus("Google session expired — click Connect again.","err"); return; } gStatus("Sync hit an error — try again.","err"); return; }
    var secs=Math.max(1, Math.round((Date.now()-t0)/1000)), total=created+updated+skipped;
    var parts=[]; if(created)parts.push(created+" added"); if(updated)parts.push(updated+" updated");
    if(!parts.length && !deleted) parts.push("already up to date");
    if(deleted) parts.push(deleted+" removed");                // cancelled / deleted lessons taken off Google
    if(fail) parts.push(fail+" failed");
    try{ TL.store.set("tl_gcal_last", String(Date.now())); }catch(e){}
    gStatus("Synced ✓ "+total+" lesson"+(total===1?"":"s")+" in "+secs+"s · "+parts.join(" · "), "ok");
    if(unknown) console.info("[TutorDeck] Google sync left "+unknown+" older event(s) alone: they can't be confirmed as yours (lesson deleted, or it belongs to another account).");
  }
  // Make sure the Google account behind the token is the one this tutor linked. If it changed (another
  // Google account is signed in on this browser), stop and ask before anything is written.
  async function gcalAccountOK(){
    if(!gTokenAccount) await populateCalendars();
    var linked=gcalAccount();
    if(!gTokenAccount){ gStatus("Couldn't confirm which Google account this is — click Connect to try again.","err"); return false; }
    if(!linked){ TL.store.set("tl_gcal_account", gTokenAccount); return true; }
    if(linked===gTokenAccount) return true;
    var ok=await confirmBox("You're signed in to Google as "+gTokenAccount+", but this TutorDeck account syncs to "+linked+". Switch your lesson sync to "+gTokenAccount+"?",
      { title:"Different Google account", yes:"Switch account", no:"Cancel" });
    if(!ok){ gStatus("Sync cancelled. Sign in to Google as "+linked+", then press Sync again.","err"); return false; }
    TL.store.set("tl_gcal_account", gTokenAccount);
    TL.store.remove("tl_gcal_chosen"); TL.store.remove("tl_gcal_calendar");      // the old calendar choice was for the other account
    updateGcalUI(); gStatus("Now choose which calendar to sync into.");
    return false;
  }
  // Events on a calendar that are provably this tutor's: tagged with their id, or older untagged events
  // whose lesson is one of theirs (same rule as syncMonth). Another tutor's events are never included.
  async function myEventsOn(cal){
    var evs=await listAppEvents(cal), out=[], ask=[];
    evs.forEach(function(ev){
      var o=gOwnerOf(ev), lid=evLessonId(ev);
      if(o===String(userId)) out.push(ev);
      else if(!o && /^[0-9a-f-]{36}$/i.test(lid) && ask.indexOf(lid)<0) ask.push(lid);
    });
    var own={};
    for(var a=0;a<ask.length;a+=100){
      var q=await window.sb.from("lessons").select("id").eq("tutor_id", userId).in("id", ask.slice(a,a+100));
      if(q.error) throw q.error;
      (q.data||[]).forEach(function(r){ own[String(r.id)]=1; });
    }
    evs.forEach(function(ev){ if(!gOwnerOf(ev) && own[evLessonId(ev)]) out.push(ev); });
    return out;
  }
  // Forget the linked Google account on this TutorDeck account and go back to the Connect step.
  function gcalUnlink(){
    if(gMode==="server"){ gServer("disconnect"); gLinked=false; }
    else try{ if(gToken && window.google && google.accounts && google.accounts.oauth2) google.accounts.oauth2.revoke(gToken, function(){}); }catch(e){}
    gToken=null; gTokenExp=0; gTokenAccount=null;
    ["tl_gcal_account","tl_gcal_chosen","tl_gcal_calendar","tl_gcal_cals","tl_gcal_list","tl_gcal_connected"].forEach(function(k){ try{ TL.store.remove(k); }catch(e){} });
    updateGcalUI();
  }
  function calLabel(){ var t=gcalTarget(), c=gcalCals().filter(function(x){ return x.v===t; })[0]; return c?c.l:"your calendar"; }
  // "Change account": optionally take this tutor's lessons off the old Google calendar (while we can still
  // reach it), then unlink and open Google's account picker for the new one.
  async function changeGcalAccount(){
    var linked=gcalAccount(); if(!linked || (!gTokenClient && gMode!=="server")) return;
    var cal=calLabel();
    var body=document.createElement("label"); body.className="gsync-opt";
    body.innerHTML='<input type="checkbox" checked> <span>Remove my lessons from <b></b> first</span>';
    body.querySelector("b").textContent=(cal==="Main calendar"?"this Google Calendar":"“"+cal+"”");
    var box=body.querySelector("input"), remove=true, needToken=false;
    var ok=await TL.dialog({ title:"Change Google account",
      message:"Your lessons sync to "+linked+". You'll pick a different Google account next.",
      body:body, confirmText:"Change account", cancelText:"Cancel",
      onClose:function(yes){                                   // runs inside the tap, so Google's pop-up isn't blocked
        if(!yes) return;
        remove=box.checked;
        if(gMode==="server") return;                           // no pop-up needed: handled after the dialog
        if(!remove){ gcalUnlink(); gStatus("Choose the Google account to sync into…"); gUserInit=true; gTokenClient.requestAccessToken({ prompt:"select_account consent" }); return; }
        if(!(gTokenValid() && gTokenAccount===linked)){
          needToken=true;
          gNext=function(got){ removeThenUnlink(linked, got); };
          gTokenClient.requestAccessToken({ prompt:"", login_hint:linked });
        }
      } });
    if(!ok) return;
    if(gMode==="server"){
      if(!remove){ gcalUnlink(); gServerConnect(); return; }
      var got=gTokenValid() || await gServerToken();
      await removeThenUnlink(linked, got);
      if(!gLinked && !gcalAccount()) gServerConnect();          // removed + unlinked → straight on to Google's page
      return;
    }
    if(remove && !needToken) removeThenUnlink(linked, true);
  }
  async function removeThenUnlink(linked, got){
    if(!got){ gStatus("Couldn't reach "+linked+", so nothing was changed. Try again, or untick “Remove my lessons”.","err"); return; }
    if(!gTokenAccount) await populateCalendars();
    if(gTokenAccount!==linked){
      gStatus("To remove your lessons from "+linked+", sign in to Google as "+linked+". Nothing was changed.","err"); return;
    }
    var cal=gcalTarget(), n=0, failed=0;
    gStatus("Removing your lessons from "+linked+"…");
    try{
      var evs=await myEventsOn(cal);
      for(var i=0;i<evs.length;i++){
        try{ await gapi("DELETE","/calendars/"+encodeURIComponent(cal)+"/events/"+encodeURIComponent(evs[i].id)); n++; }
        catch(e){ if(e&&e.code===401){ gStatus("Google session expired, so not every lesson was removed. Try Change account again.","err"); return; } failed++; }
      }
    }catch(e){ gStatus("Couldn't remove your lessons from "+linked+". Nothing else was changed.","err"); return; }
    if(failed){ gStatus("Removed "+n+", but "+failed+" couldn't be removed. Try Change account again.","err"); return; }
    gcalUnlink();
    gStatus((n?"Removed "+n+" lesson"+(n===1?"":"s")+" from "+linked+".":"No lessons to remove from "+linked+".")+" Now connect the Google account you want.","ok");
  }
  // Switch which calendar we sync into: wipe ALL our events off the old calendar, then rebuild
  // the current month on the new one.
  async function setGcalTarget(raw){
    if(!(raw||"").trim()) return;                             // "Choose a calendar…" placeholder — ignore
    var newT=(raw||"").trim(), oldT=gcalTarget(), first=!gcalChosen();
    if(!gToken){
      // No live token this session — remember the choice, then get a token and sync to it.
      try{ TL.store.set("tl_gcal_calendar", newT); TL.store.set("tl_gcal_chosen","1"); }catch(e){}
      if(gMode==="server" && gLinked) gServer("set_calendar", { calendar:newT });
      updateGcalUI(); gStatus("Connecting to Google…");
      connectGcal();                                          // gUserInit=true → syncNow() to the chosen calendar after the token
      return;
    }
    if(!first && newT!==oldT){
      gStatus("Moving to the new calendar…");
      try{ var evs=await myEventsOn(oldT); for(var i=0;i<evs.length;i++){ try{ await gapi("DELETE","/calendars/"+encodeURIComponent(oldT)+"/events/"+encodeURIComponent(evs[i].id)); }catch(e){} } }catch(e){}
    }
    try{ TL.store.set("tl_gcal_calendar", newT); TL.store.set("tl_gcal_chosen","1"); }catch(e){}
    if(gMode==="server" && gLinked) gServer("set_calendar", { calendar:newT });
    updateGcalUI();
    syncNow();
  }

  // ---- nav / mode ----
  function setMode(m){
    mode=m;
    try{ TL.store.set("tl_cal_mode",m); }catch(e){}
    ensureData();
  }
  function stepAnchor(a, dir){
    var m=effMode();
    return m==="month" ? new Date(a.getFullYear(),a.getMonth()+dir,1) : addDays(a,dir*stepDays(m));
  }
  function shiftRange(dir){ anchor=stepAnchor(anchor,dir); return ensureData(); }

  // ---- slide animation: the view follows your finger, then slides out and the new one in ----
  var reduceMotion = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : { matches:false };
  var sliding=false;
  // The track holds [previous | current | next]; it rests at -1/3 and moves with the finger.
  function track(){ return $("cal-track"); }
  function setTrack(px, pct, ms){
    var t=track(); if(!t) return;
    t.style.transition = ms ? "transform "+ms+"ms cubic-bezier(.2,.7,.2,1)" : "none";
    t.style.transform = "translateX(calc("+(pct==null?-100/3:pct)+"% + "+(px||0)+"px))";
  }
  // Move by dir (+1 forward / -1 back): slide the neighbour in, then re-centre on it.
  function go(dir){
    if(sliding) return; hidePopover();
    if(reduceMotion.matches || !track()){ shiftRange(dir); return; }
    sliding=true; openHeight();
    setTrack(0, dir>0 ? -200/3 : 0, 230);
    setTimeout(function(){
      Promise.resolve(shiftRange(dir)).then(function(){ sliding=false; }, function(){ sliding=false; });
    }, 240);
  }
  function jumpTo(date){
    var a=new Date(anchor); a.setHours(0,0,0,0); var b=new Date(date); b.setHours(0,0,0,0);
    var d=Math.round((b-a)/86400000), m=effMode();
    if(m==="day" && Math.abs(d)===1){ go(d); return; }           // next/previous day: slide
    anchor=date; ensureData();
  }
  // One-time tips, each pointing at what it explains, one at a time:
  // phones first get "swipe" on the calendar itself, then "tap a colour" on the key below it.
  function showTips(){
    if(!(window.TL && TL.coach)) return;
    // Wait until the key is actually on screen, so the tip isn't shown where nobody can see it.
    function filters(){
      var key=document.querySelector(".cal-legend"); if(!key) return;
      function show(){ whenNoTip(function(){ TL.coach("cal-filters", key,
        "<b>Filters</b><br>Tap a status to hide those lessons, e.g. <b>Not logged</b>."); }); }
      if(!("IntersectionObserver" in window)){ show(); return; }
      var io=new IntersectionObserver(function(es){ if(es[0].isIntersecting){ io.disconnect(); show(); } }, { threshold:1 });
      io.observe(key);
    }
    var seen=true; try{ seen=!!TL.store.get("td_tip_cal-swipe"); }catch(e){}
    if(!isPhone() || seen){ filters(); return; }
    var cur=document.querySelector("#cal-vp .cal-pane:nth-child(2)");
    var anchor=(cur && (cur.querySelector(".cal-head")||cur.querySelector(".dhead")||cur.querySelector(".cal-mhead"))) || $("cal");
    TL.coach("cal-swipe", anchor, "<b>Swipe the calendar</b><br>Swipe left or right to go to the next or previous "+(effMode()==="month"?"month":effMode()==="day"?"day":"week")+".");
    var ok=document.querySelector("#td-tip-cal-swipe .td-tip-ok");
    if(ok) ok.addEventListener("click", function(){ setTimeout(filters, 150); });
  }
  function goToday(){ hidePopover(); anchor=new Date(); ensureData(); }
  // FAB in Day view: start the new lesson on the day you're looking at.
  function m2prefill(){ return effMode()==="day" ? { date: iso(anchor) } : undefined; }

  function initLegend(){
    document.querySelectorAll(".cal-legend .leg").forEach(function(btn){
      var cat=btn.dataset.cat;
      btn.classList.toggle("off", !!hidden[cat]); btn.setAttribute("aria-pressed", hidden[cat]?"false":"true");
      btn.addEventListener("click", function(e){
        e.stopPropagation();
        if(hidden[cat]) delete hidden[cat]; else hidden[cat]=true;
        btn.classList.toggle("off", !!hidden[cat]); btn.setAttribute("aria-pressed", hidden[cat]?"false":"true");
        try{ TL.store.set("tl_cal_hidden", JSON.stringify(hidden)); }catch(e2){}
        render();   // re-filter; no refetch needed
      });
    });
  }

  function init(user){
    userId=user.id; anchor=new Date();
    try{ mode=TL.store.get("tl_cal_mode")||""; }catch(e){ mode=""; }
    if(!mode) mode="week";   // default everywhere; the user's last choice is remembered (tl_cal_mode)
    try{ hidden=JSON.parse(TL.store.get("tl_cal_hidden")||"{}")||{}; }catch(e){ hidden={}; }
    window.addEventListener("td:clientview", function(){ render(); });   // Paid/Unpaid filters only apply outside Client view
    $("cal-prev").addEventListener("click", function(){ go(-1); });
    $("cal-next").addEventListener("click", function(){ go(1); });
    $("cal-today").addEventListener("click", goToday);
    if($("cal-log-btn")) $("cal-log-btn").addEventListener("click", logVisible);
    if($("gcal-btn")) $("gcal-btn").addEventListener("click", connectGcal);
    if($("gcal-cal")) $("gcal-cal").addEventListener("change", function(){ if(this.value) setGcalTarget(this.value); });
    if($("gsync-change")) $("gsync-change").addEventListener("click", changeGcalAccount);
    initGcal(); gcalBoot();
    ["day","3day","week","list","month"].forEach(function(k){ var b=$("seg-"+k); if(b) b.addEventListener("click", function(){ setMode(k); }); });
    // phone: swipe left/right on the calendar to move a day / 3 days / week
    // The view tracks the finger once the gesture is clearly sideways; vertical scrolling is left alone.
    (function(){ var x0=null,y0=null,dx=0,axis=null, host=$("cal");
      host.addEventListener("touchstart", function(e){
        if(sliding || e.touches.length>1) { x0=null; return; }
        if(e.target.closest(".dstrip")) { x0=null; return; }      // the day strip has its own taps
        var t=e.touches[0]; x0=t.clientX; y0=t.clientY; dx=0; axis=null;
      }, {passive:true});
      host.addEventListener("touchmove", function(e){
        if(x0===null) return;
        var t=e.touches[0], mx=t.clientX-x0, my=t.clientY-y0;
        if(!axis){ if(Math.abs(mx)<10 && Math.abs(my)<10) return; axis = Math.abs(mx)>Math.abs(my)*1.2 ? "x" : "y"; }
        if(axis!=="x") return;
        e.preventDefault();                          // we own this gesture now
        if(dx===0) openHeight();
        dx=mx;
        if(!reduceMotion.matches) setTrack(dx);
      }, {passive:false});
      function end(){
        if(x0===null) return; var was=axis; x0=null; axis=null;
        if(was!=="x") return;
        var w=($("cal-vp")||{}).offsetWidth||360;
        if(Math.abs(dx)>Math.min(80,w*0.2)) go(dx<0?1:-1);
        else { setTrack(0, null, 180); setTimeout(fitHeight, 190); }   // not far enough: snap back
      }
      host.addEventListener("touchend", end, {passive:true});
      host.addEventListener("touchcancel", end, {passive:true});
    })();
    if($("cal-add")) $("cal-add").addEventListener("click", function(){ openAdd(); });
    if($("cal-fab")) $("cal-fab").addEventListener("click", function(e){ e.stopPropagation(); openAdd(m2prefill()); });
    window.addEventListener("td:tabagain", function(){ hidePopover(); goToday(); });
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

    Promise.resolve(ensureData()).then(showTips);
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
