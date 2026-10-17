// Ledger — KPIs, outstanding by student, mark paid, add lesson, log-week-from-schedule.
(function () {
  function fillSubjects(list){var el=document.getElementById("dl-subject");if(!el)return;var u=[];(list||[]).forEach(function(s){s=(s||"").trim();if(s&&u.indexOf(s)<0)u.push(s);});el.innerHTML=u.sort().map(function(s){return "<option value=\""+s.replace(/"/g,"&quot;")+"\">";}).join("");}
  var userId = null, nameById = {}, contactById = {}, recipientById = {}, payByBankById = {}, levelById = {}, endById = {}, students = [], slots = [], profile = null, outGroups = {}, monthById = {}, editLessonId = null, allLessons = [], period = null, genWeekOff = 0, genMonthOff = 0, selectedLessons = {}, lastUnpaid = [], householdBy = {}, selectedRecords = {}, lastRecordRows = [], payIds = [];
  // Bank-transfer payment method (overseas clients, no PayNow).
  function hasBank(p){ return !!(p && p.bank_account_no); }
  function bankObj(p){ return { name:(p.bank_account_name||p.business_name||""), bank:(p.bank_name||""), acct:(p.bank_account_no||""), swift:(p.bank_swift||"") }; }
  var $ = function (id) { return document.getElementById(id); };

  function esc(s){return String(s==null?"":s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");}
  function pad(n){return (n<10?"0":"")+n;}
  function iso(d){return d.getFullYear()+"-"+pad(d.getMonth()+1)+"-"+pad(d.getDate());}
  function todayISO(){return iso(new Date());}
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
  function hm(t){return t?t.slice(0,5):"";}
  // A lesson is "done" only once its end time has passed — so a lesson later TODAY stays
  // "scheduled" (date-only comparison wrongly marked every today lesson done). endHM = "HH:MM".
  function statusFor(dateISO,endHM){return new Date(dateISO+"T"+(endHM||"23:59")+":00").getTime()>Date.now()?"scheduled":"done";}
  function prettyDate(s){if(!s)return"";var p=s.split("-");var mo=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];return (+p[2])+" "+mo[(+p[1])-1];}
  // Records table only — the weekday ties each row back to its recurring slot.
  function recDate(s){if(!s)return"";var p=s.split("-");var wd=["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];return wd[new Date(+p[0],+p[1]-1,+p[2]).getDay()]+" "+prettyDate(s);}
  function monthOccurrences(weekday){var now=new Date(),y=now.getFullYear(),m=now.getMonth(),c=0,d=new Date(y,m,1);while(d.getMonth()===m){if(((d.getDay()+6)%7)===weekday)c++;d.setDate(d.getDate()+1);}return c;}
  function monthRange(){var now=new Date(),y=now.getFullYear(),m=now.getMonth();return{first:y+"-"+pad(m+1)+"-01",last:y+"-"+pad(m+1)+"-"+pad(new Date(y,m+1,0).getDate()),label:now.toLocaleString("en-SG",{month:"long"})};}
  function mondayOf(date){var d=new Date(date);d.setHours(0,0,0,0);d.setDate(d.getDate()-((d.getDay()+6)%7));return d;}
  function setGenLabel(){
    var mo=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
    var moFull=["January","February","March","April","May","June","July","August","September","October","November","December"];
    var mon=mondayOf(new Date());mon.setDate(mon.getDate()+genWeekOff*7);
    var sun=new Date(mon);sun.setDate(mon.getDate()+6);
    var range=mon.getMonth()===sun.getMonth()
      ? mon.getDate()+"–"+sun.getDate()+" "+mo[sun.getMonth()]
      : mon.getDate()+" "+mo[mon.getMonth()]+" – "+sun.getDate()+" "+mo[sun.getMonth()];
    var wpre=genWeekOff===0?"this week":(genWeekOff===1?"next week":"week");
    var b=$("gen-btn");if(b)b.textContent="Log "+wpre+" ("+range+")";
    var now=new Date(),mb=new Date(now.getFullYear(),now.getMonth()+genMonthOff,1);
    var mpre=genMonthOff===0?"this month":(genMonthOff===1?"next month":"month");
    var mlbl=moFull[mb.getMonth()]+(mb.getFullYear()!==now.getFullYear()?" "+mb.getFullYear():"");
    var mbtn=$("gen-month-btn");if(mbtn)mbtn.textContent="Log "+mpre+" ("+mlbl+")";
  }
  function stepWeek(d){genWeekOff=Math.max(0,genWeekOff+d);setGenLabel();}
  function stepMonth(d){genMonthOff=Math.max(0,genMonthOff+d);setGenLabel();}

  function openCustom(){
    var t=new Date(),plus=new Date();plus.setDate(plus.getDate()+13);
    $("cr-from").value=iso(t);$("cr-to").value=iso(plus);
    $("cr-msg").textContent="";$("cr-msg").className="msg";
    $("cr-modal").classList.add("on");
  }
  function closeCustom(){$("cr-modal").classList.remove("on");}
  async function generateRange(){
    var msg=$("cr-msg");
    if(!slots.length){msg.textContent="No recurring slots to generate from. Add them on the Planner first.";msg.className="msg err";return;}
    var fromISO=$("cr-from").value,toISO=$("cr-to").value;
    if(!fromISO||!toISO){msg.textContent="Pick both a start and end date.";msg.className="msg err";return;}
    if(toISO<fromISO){msg.textContent="\u201CTo\u201D must be on or after \u201CFrom\u201D.";msg.className="msg err";return;}
    var start=new Date(fromISO+"T00:00:00"),end=new Date(toISO+"T00:00:00");
    if(Math.round((end-start)/86400000)+1>366){msg.textContent="Range too large \u2014 keep it within a year.";msg.className="msg err";return;}
    var b=$("cr-save");b.disabled=true;
    var ex=await window.sb.from("lessons").select("student_id,lesson_date,start_time").gte("lesson_date",fromISO).lte("lesson_date",toISO);
    var seen={};(ex.data||[]).forEach(function(l){seen[l.student_id+"|"+l.lesson_date+"|"+hm(l.start_time)]=1;});
    var rows=[];
    for(var d=new Date(start);d<=end;d.setDate(d.getDate()+1)){
      var wd=(d.getDay()+6)%7,di=iso(d);
      slots.forEach(function(s){
        if(s.weekday!==wd)return;
        if(TL.pastEnd(endById[s.student_id],di))return;   // student's lessons end on their end_date
        if(seen[s.student_id+"|"+di+"|"+hm(s.start_time)])return;
        rows.push({tutor_id:userId,student_id:s.student_id,slot_id:s.id,lesson_date:di,slot_date:di,start_time:s.start_time,end_time:s.end_time,subject:s.subject,level:s.level,rate:s.rate,split:s.split||1,amount:splitAmt(s.rate,hm(s.start_time),hm(s.end_time),s.split),status:statusFor(di,hm(s.end_time)),paid:false});
      });
    }
    b.disabled=false;
    if(!rows.length){msg.textContent="That range is already logged \u2014 nothing new to add.";msg.className="msg";return;}
    if(!confirm("Add "+rows.length+" lessons from "+fromISO+" to "+toISO+"? Already-logged lessons are skipped."))return;
    b.disabled=true;
    var res=await window.sb.from("lessons").insert(rows);
    b.disabled=false;
    if(res.error){msg.textContent="Couldn't generate: "+res.error.message;msg.className="msg err";return;}
    closeCustom();load();
  }

  // ---------- rendering ----------
  function daysSince(iso){
    var d=new Date(iso+"T00:00:00"),t=new Date();t.setHours(0,0,0,0);
    return Math.max(0,Math.round((t-d)/86400000));
  }
  function ageTag(days){
    if(days<7)return "";
    var lbl=days>=30?(Math.floor(days/30)+"mth"+(days>=60?"s":"")):(Math.floor(days/7)+"wk"+(days>=14?"s":""));
    var cls=days>=30?"age bad":(days>=14?"age warn":"age");
    return '<span class="'+cls+'">'+lbl+' overdue</span>';
  }
  function renderOutstanding(unpaidAll){
    lastUnpaid=unpaidAll;
    // Shared period (header) — scope the whole view (counts, invoicing, marking) to it.
    var pk=periodKey();
    var unpaid=pk==="all"?unpaidAll:unpaidAll.filter(function(l){return (l.lesson_date||"").slice(0,7)===pk;});
    var groups={};unpaid.forEach(function(l){(groups[l.student_id]=groups[l.student_id]||[]).push(l);});
    outGroups=groups;
    function oldestOf(id){return groups[id].reduce(function(m,l){return (!m||l.lesson_date<m)?l.lesson_date:m;},null);}
    // oldest debt first — chase these before anything else
    var ids=Object.keys(groups).sort(function(a,b){
      var oa=oldestOf(a),ob=oldestOf(b);
      if(oa!==ob)return oa.localeCompare(ob);
      var sa=groups[a].reduce(function(t,l){return t+Number(l.amount);},0);
      var sb=groups[b].reduce(function(t,l){return t+Number(l.amount);},0);return sb-sa;});
    if(!ids.length){
      var em=periodKey()==="all"?"All settled 🎉":"Nothing pending for "+periodLabel();
      $("outstanding").innerHTML='<div class="card empty"><h3>'+em+'</h3></div>';$("out-hint").textContent="";setOutCount(0);return;}
    $("out-hint").textContent=ids.length+(ids.length===1?" student owing":" students owing");
    setOutCount(ids.length);
    var unpaidLessonIds={};unpaid.forEach(function(l){unpaidLessonIds[l.id]=1;});
    Object.keys(selectedLessons).forEach(function(lid){if(!unpaidLessonIds[lid])delete selectedLessons[lid];});
    function studentCard(id){
      var rows=groups[id].sort(function(a,b){return a.lesson_date.localeCompare(b.lesson_date);});
      var sum=rows.reduce(function(t,l){return t+Number(l.amount);},0);
      var lessonIds=rows.map(function(l){return l.id;});
      var selIds=rows.filter(function(l){return selectedLessons[l.id];}).map(function(l){return l.id;});
      var age=ageTag(daysSince(rows[0].lesson_date));
      var inner=rows.map(function(l){var d=daysSince(l.lesson_date);
        var label=l.status==="cancelled"
          ?'<span class="muted">Cancellation fee'+(l.subject?" · "+esc(l.subject):"")+'</span>'
          :(l.subject?esc(l.subject):'<span class="muted">lesson</span>');
        return '<div class="lrow"><input type="checkbox" class="lchk" data-lsel="'+l.id+'"'+(selectedLessons[l.id]?" checked":"")+'><span class="lwhen">'+prettyDate(l.lesson_date)+(d>=14?' <span class="agedot" title="'+d+' days unpaid">•</span>':"")+"</span><span>"+label+'</span><span class="lamt">'+TL.sgd(l.amount)+'</span><button class="mark lite" data-pay="'+l.id+'">Mark paid</button></div>';}).join("");
      var selBtn=selIds.length?'<button class="mark lite" data-invsel="'+id+'::'+selIds.join(",")+'">Invoice '+selIds.length+' selected</button><button class="mark" data-paysel="'+selIds.join(",")+'">Mark '+selIds.length+' selected paid</button>':"";
      return '<div class="card group collapsed"><div class="group-head" data-grp="'+id+'"><span class="gsel"><input type="checkbox" data-sel="'+id+'" title="Select all lessons for this student"><span class="gname"><a class="snl" href="student.html?id='+id+'">'+esc(nameById[id]||"—")+'</a></span>'+age+'<span class="grp-caret" aria-hidden="true">›</span></span><span class="right"><span class="gsum">'+TL.sgd(sum)+'</span><button class="mark lite" data-remind="'+id+'">Remind</button><button class="mark lite" data-inv="'+id+'">Invoice</button>'+selBtn+'<button class="mark" data-payall="'+lessonIds.join(",")+'">Mark all paid</button></span></div>'+inner+'</div>';
    }
    // group owing students by household
    var byHH={}; ids.forEach(function(id){var h=householdBy[id];if(h)(byHH[h]=byHH[h]||[]).push(id);});
    var doneHH={};
    $("outstanding").innerHTML=ids.map(function(id){
      var h=householdBy[id];
      if(h&&byHH[h].length>=2){
        if(doneHH[h])return "";
        doneHH[h]=1;
        var members=byHH[h];
        var hhLabel=members.map(function(m){return recipientById[m];}).filter(Boolean)[0]||contactById[members[0]]||"Household";
        var hhSum=members.reduce(function(t,m){return t+groups[m].reduce(function(s,l){return s+Number(l.amount);},0);},0);
        var hhOldest=members.reduce(function(m,id){var o=oldestOf(id);return (!m||o<m)?o:m;},null);
        var hhLessonIds=members.reduce(function(a,m){return a.concat(groups[m].map(function(l){return l.id;}));},[]);
        // lessons checked across the whole household → invoice/mark-paid just those together
        var hhSelIds=members.reduce(function(a,m){return a.concat((groups[m]||[]).filter(function(l){return selectedLessons[l.id];}).map(function(l){return l.id;}));},[]);
        var hhSelBtns=hhSelIds.length?'<button class="mark lite" data-hhinvsel="'+members.join(",")+'::'+hhSelIds.join(",")+'">Invoice '+hhSelIds.length+' selected</button><button class="mark" data-hhpaysel="'+hhSelIds.join(",")+'">Mark '+hhSelIds.length+' selected paid</button>':'';
        return '<div class="hh-block"><div class="hh-head"><span class="gsel"><input type="checkbox" data-hh="'+encodeURIComponent(h)+'" title="Select all lessons in this household"><span class="hh-name">⌂ '+esc(hhLabel)+' <span class="muted" style="font-weight:600;font-size:12px">· '+members.length+' students</span></span>'+ageTag(daysSince(hhOldest))+'</span>'+
          '<span class="hh-actions"><span class="gsum">'+TL.sgd(hhSum)+' <small>total</small></span><button class="mark lite" data-hhrem="'+members.join(",")+'">Remind</button><button class="mark lite" data-hhinv="'+members.join(",")+'">Invoice together</button>'+hhSelBtns+'<button class="mark" data-hhpayall="'+hhLessonIds.join(",")+'">Mark all paid</button></span></div>'+members.map(studentCard).join("")+'</div>';
      }
      return studentCard(id);
    }).join("");
    $("outstanding").querySelectorAll("[data-pay]").forEach(function(b){b.addEventListener("click",function(){openPayModal([b.dataset.pay]);});});
    $("outstanding").querySelectorAll("[data-payall]").forEach(function(b){b.addEventListener("click",async function(){var ids=b.dataset.payall.split(",");if(await confirmBox("Mark all "+ids.length+" of this student's lessons as paid?",{title:"Mark paid",yes:"Continue"})) openPayModal(ids);});});
    $("outstanding").querySelectorAll("[data-hhpayall]").forEach(function(b){b.addEventListener("click",async function(){var ids=b.dataset.hhpayall.split(",");if(await confirmBox("Mark all "+ids.length+" lessons for this household as paid?",{title:"Mark household paid",yes:"Continue"})) openPayModal(ids);});});
    $("outstanding").querySelectorAll("[data-paysel]").forEach(function(b){b.addEventListener("click",async function(){var ids=b.dataset.paysel.split(",");if(await confirmBox("Mark "+ids.length+" selected lesson"+(ids.length===1?"":"s")+" as paid?",{title:"Mark paid",yes:"Continue"})) openPayModal(ids);});});
    $("outstanding").querySelectorAll("[data-invsel]").forEach(function(b){b.addEventListener("click",function(){var p=b.dataset.invsel.split("::");openInvoice(p[0], p[1]?p[1].split(","):null);});});
    $("outstanding").querySelectorAll("[data-hhpaysel]").forEach(function(b){b.addEventListener("click",async function(){var ids=b.dataset.hhpaysel.split(",");if(await confirmBox("Mark "+ids.length+" selected lesson"+(ids.length===1?"":"s")+" for this household as paid?",{title:"Mark household paid",yes:"Continue"})) openPayModal(ids);});});
    $("outstanding").querySelectorAll("[data-hhinvsel]").forEach(function(b){b.addEventListener("click",function(){var p=b.dataset.hhinvsel.split("::");openInvoiceMany(p[0].split(","), p[1]?p[1].split(","):null);});});
    // Collapsed by default: tapping a student header (not its buttons/checkbox/link) shows its lessons.
    $("outstanding").querySelectorAll(".group-head[data-grp]").forEach(function(h){
      h.addEventListener("click",function(e){
        if(e.target.closest("input,button,a,label"))return;
        h.parentNode.classList.toggle("collapsed");
      });
    });
    $("outstanding").querySelectorAll("[data-lsel]").forEach(function(cb){
      cb.addEventListener("change",function(){
        if(cb.checked)selectedLessons[cb.dataset.lsel]=1; else delete selectedLessons[cb.dataset.lsel];
        renderOutstanding(lastUnpaid);
      });
    });
    $("outstanding").querySelectorAll("[data-inv]").forEach(function(b){b.addEventListener("click",function(){openInvoice(b.dataset.inv);});});
    $("outstanding").querySelectorAll("[data-remind]").forEach(function(b){b.addEventListener("click",function(){remind(b.dataset.remind);});});
    // Master checkbox by the name → tick/untick ALL that student's outstanding lessons.
    // Shows a dash (indeterminate) when only some of the student's lessons are ticked.
    $("outstanding").querySelectorAll("[data-sel]").forEach(function(cb){
      var lids=(groups[cb.dataset.sel]||[]).map(function(l){return String(l.id);});
      var n=lids.filter(function(x){return selectedLessons[x];}).length;
      cb.checked=lids.length>0&&n===lids.length; cb.indeterminate=n>0&&n<lids.length;
      cb.addEventListener("change",function(){
        lids.forEach(function(x){ if(cb.checked)selectedLessons[x]=1; else delete selectedLessons[x]; });
        renderOutstanding(lastUnpaid);
      });
    });
    // Household master checkbox → tick/untick every lesson across the household.
    $("outstanding").querySelectorAll("[data-hh]").forEach(function(cb){
      var h=decodeURIComponent(cb.dataset.hh), members=ids.filter(function(id){return householdBy[id]===h;});
      var lids=members.reduce(function(a,m){return a.concat((groups[m]||[]).map(function(l){return String(l.id);}));},[]);
      var n=lids.filter(function(x){return selectedLessons[x];}).length;
      cb.checked=lids.length>0&&n===lids.length; cb.indeterminate=n>0&&n<lids.length;
      cb.addEventListener("change",function(){
        lids.forEach(function(x){ if(cb.checked)selectedLessons[x]=1; else delete selectedLessons[x]; });
        renderOutstanding(lastUnpaid);
      });
    });
    $("outstanding").querySelectorAll("[data-hhinv]").forEach(function(b){b.addEventListener("click",function(){openInvoiceMany(b.dataset.hhinv.split(","));});});
    $("outstanding").querySelectorAll("[data-hhrem]").forEach(function(b){b.addEventListener("click",function(){remindMany(b.dataset.hhrem.split(","));});});
  }

  function waNumber(raw){
    var d=String(raw||"").replace(/\D/g,"");
    if(!d)return "";
    d=d.replace(/^0+/,"");
    if(d.length===8)return "65"+d;   // Singapore local mobile/landline
    return d;                         // assume it already carries a country code
  }
  var DEFAULT_REMINDER="Hi {name}! Friendly reminder from {business}: you have an outstanding balance of {amount} for {count} tuition lesson(s). PayNow to {paynow}. Thank you!";
  var DEFAULT_INVOICE="Hi {name}! Here's your invoice {invoice} from {business} — total {amount}. PayNow to {paynow}. Thank you!";
  var DEFAULT_INVOICE_BANK="Hi {name}! Here's your invoice {invoice} from {business} — total {amount}. Bank-transfer details are on the invoice. Thank you!";
  function fillTemplate(tpl,vars){return String(tpl).replace(/\{(\w+)\}/g,function(_,k){return vars[k]!=null?String(vars[k]):"";});}
  var MONTHS=["January","February","March","April","May","June","July","August","September","October","November","December"];
  function monthsLabel(rows){
    var seen={},keys=[];
    (rows||[]).forEach(function(l){var k=(l.lesson_date||"").slice(0,7);if(k&&!seen[k]){seen[k]=1;keys.push(k);}});
    keys.sort();
    var names=keys.map(function(k){return MONTHS[parseInt(k.slice(5,7),10)-1];});
    if(!names.length)return "";
    if(names.length===1)return names[0];
    if(names.length===2)return names[0]+" & "+names[1];
    return names.slice(0,-1).join(", ")+" & "+names[names.length-1];
  }

  function remind(id){
    var num=waNumber(contactById[id]);
    if(!num){alert("No contact number saved for "+(nameById[id]||"this student")+".\n\nAdd one on the Students page (Edit → Contact), then try again.");return;}
    var rows=outGroups[id]||[];
    if(!rows.length)return;
    var sum=rows.reduce(function(t,l){return t+Number(l.amount);},0);
    var vars={name:recipientById[id]||nameById[id]||"",student:nameById[id]||"",business:(profile&&profile.business_name)||"your tutor",
      amount:TL.sgd(sum),count:rows.length,invoice:"",paynow:(profile&&profile.paynow_id)||"",
      month:monthsLabel(rows),date:prettyDate(iso(new Date())),year:String(new Date().getFullYear())};
    var tpl=(profile&&profile.reminder_message)||DEFAULT_REMINDER;
    window.open("https://wa.me/"+num+"?text="+encodeURIComponent(fillTemplate(tpl,vars)),"_blank");
  }

  function remindMany(ids){
    var num="", targetId=null;
    ids.some(function(id){var n=waNumber(contactById[id]);if(n){num=n;targetId=id;return true;}return false;});
    if(!num){alert("None of the selected students have a saved contact number.\n\nAdd one on the Students page (Edit → Contact), then try again.");return;}
    var all=[]; ids.forEach(function(id){(outGroups[id]||[]).forEach(function(l){all.push(l);});});
    if(!all.length)return;
    var sum=all.reduce(function(t,l){return t+Number(l.amount);},0);
    var names=ids.map(function(id){return nameById[id]||"";}).filter(Boolean);
    var who=names.length===2?names[0]+" & "+names[1]:names.join(", ");
    var vars={name:recipientById[targetId]||nameById[targetId]||"",student:who,business:(profile&&profile.business_name)||"your tutor",
      amount:TL.sgd(sum),count:all.length,invoice:"",paynow:(profile&&profile.paynow_id)||"",
      month:monthsLabel(all),date:prettyDate(iso(new Date())),year:String(new Date().getFullYear())};
    var tpl=(profile&&profile.reminder_message)||DEFAULT_REMINDER;
    window.open("https://wa.me/"+num+"?text="+encodeURIComponent(fillTemplate(tpl,vars)),"_blank");
  }
  function periodLabel(){return period.mode==="all"?"All time":new Date(period.y,period.m,1).toLocaleString("en-SG",{month:"long",year:"numeric"});}
  function fillOpt(id,pairs,label){
    var el=$(id);if(!el)return;var cur=el.value;
    el.innerHTML='<option value="">'+label+'</option>'+pairs.map(function(p){return '<option value="'+String(p[0]).replace(/"/g,"&quot;")+'">'+esc(p[1])+'</option>';}).join("");
    el.value=cur;
  }
  function fillRecFilters(){
    var stu=[],sub=[],lvl=[];
    allLessons.forEach(function(l){
      if(l.student_id&&stu.indexOf(l.student_id)<0)stu.push(l.student_id);
      if(l.subject&&sub.indexOf(l.subject)<0)sub.push(l.subject);
      if(l.level&&lvl.indexOf(l.level)<0)lvl.push(l.level);
    });
    stu.sort(function(a,b){return (nameById[a]||"").localeCompare(nameById[b]||"");});
    fillOpt("rec-student",stu.map(function(id){return [id,nameById[id]||"—"];}),"All students");
    fillOpt("rec-subject",sub.sort().map(function(s){return [s,s];}),"All subjects");
    fillOpt("rec-level",lvl.sort().map(function(s){return [s,s];}),"All levels");
  }
  function clearRecFilters(){
    ["rec-search","rec-student","rec-subject","rec-level","rec-status"].forEach(function(id){var el=$(id);if(el)el.value="";});
    renderRecords();
  }
  function renderRecords(){
    if(!period)period={mode:"month",y:new Date().getFullYear(),m:new Date().getMonth()};
    updatePeriodUI();
    var rows=allLessons.filter(function(l){
      if(period.mode==="all")return true;
      return l.lesson_date.slice(0,7)===period.y+"-"+pad(period.m+1);
    });
    var q=($("rec-search")?$("rec-search").value:"").trim().toLowerCase();
    var fStu=$("rec-student")?$("rec-student").value:"";
    var fSub=$("rec-subject")?$("rec-subject").value:"";
    var fLvl=$("rec-level")?$("rec-level").value:"";
    var stat=$("rec-status")?$("rec-status").value:"";
    if(q)rows=rows.filter(function(l){return [nameById[l.student_id],l.subject,l.level].some(function(v){return (v||"").toLowerCase().indexOf(q)>-1;});});
    if(fStu)rows=rows.filter(function(l){return l.student_id===fStu;});
    if(fSub)rows=rows.filter(function(l){return (l.subject||"")===fSub;});
    if(fLvl)rows=rows.filter(function(l){return (l.level||"")===fLvl;});
    if(stat)rows=rows.filter(function(l){
      if(stat==="unpaid")return !l.paid&&(l.status==="done"||(l.status==="cancelled"&&l.amount>0));
      if(stat==="paid")return l.paid;
      if(stat==="postponed")return !!l.postponed;
      return l.status===stat; // scheduled / cancelled
    });
    var anyFilter=!!(q||fStu||fSub||fLvl||stat);
    ["rec-student","rec-subject","rec-level","rec-status"].forEach(function(id){var el=$(id);if(el)el.classList.toggle("on",!!el.value);});
    if($("rec-clear"))$("rec-clear").style.display=anyFilter?"":"none";
    var table=$("month-table"),empty=$("month-empty"),body=$("month-body");
    monthById={};rows.forEach(function(l){monthById[l.id]=l;});
    var allIds={};allLessons.forEach(function(l){allIds[l.id]=1;});
    Object.keys(selectedRecords).forEach(function(id){if(!allIds[id])delete selectedRecords[id];});
    if(!rows.length){
      table.style.display="none";empty.style.display="block";
      empty.innerHTML="<h3>"+(anyFilter?"No lessons match these filters":"No lessons in "+periodLabel())+"</h3>";
      $("month-hint").textContent="";lastRecordRows=[];updateRecSelBar();return;
    }
    empty.style.display="none";table.style.display="table";
    rows.sort(function(a,b){return b.lesson_date.localeCompare(a.lesson_date);});
    lastRecordRows=rows;
    $("month-hint").textContent=rows.length+" lessons";
    // Anchor the "Today" jump. Rows run newest-first, so when today has no lessons
    // the divider goes in front of the first older row — i.e. where today would sit.
    var today=todayISO();
    var todayInView=period.mode==="all"||today.slice(0,7)===period.y+"-"+pad(period.m+1);
    var hasToday=rows.some(function(l){return l.lesson_date===today;});
    var divider='<tr class="today-div" id="rec-today"><td colspan="8">Today · '+recDate(today)+'</td></tr>';
    var placed=false;
    body.innerHTML=rows.map(function(l){
      var lead="";
      if(todayInView&&!hasToday&&!placed&&l.lesson_date<today){lead=divider;placed=true;}
      var isToday=todayInView&&l.lesson_date===today;
      var cls=[];
      if(isToday)cls.push("today");
      if(l.status==="cancelled")cls.push("is-cancelled");
      var attrs=(isToday&&!placed?(placed=true,' id="rec-today"'):"")+(cls.length?' class="'+cls.join(" ")+'"':"");
      var badge=l.status==="cancelled"
        ?'<span class="kind-tag">cancelled</span>'+(l.amount>0?(l.paid?' <span class="badge paid">Paid</span>':' <span class="badge owed">Unpaid</span>'):'')
        :(l.status==="scheduled"?'<span class="kind-tag">scheduled</span>':(l.paid?'<span class="badge paid">Paid</span>':'<span class="badge owed">Unpaid</span>'));
      if(l.postponed)badge+=' <span class="kind-tag" style="background:#C8922A;color:#fff">postponed</span>';
      var cancelBtn=l.status==="cancelled"
        ? '<button class="tact" data-restore="'+l.id+'">Restore</button>'
        : '<button class="tact warn" data-cancel="'+l.id+'">Cancel</button>';
      return lead+'<tr data-lid="'+l.id+'"'+attrs+'><td data-label=""><input type="checkbox" class="lchk" data-rsel="'+l.id+'"'+(selectedRecords[l.id]?" checked":"")+'></td><td data-label="Date">'+recDate(l.lesson_date)+'</td><td class="name" data-label="Student"><a class="snl" href="student.html?id='+l.student_id+'">'+esc(nameById[l.student_id]||"—")+'</a></td><td data-label="Subject">'+(l.subject?esc(l.subject):'<span class="muted">—</span>')+'</td><td data-label="Level">'+(l.level?esc(l.level):'<span class="muted">—</span>')+'</td><td data-label="Amount">'+TL.sgd(l.amount)+'</td><td data-label="Status">'+badge+'</td>'+
        '<td class="acts"><button class="tact" data-edit="'+l.id+'">Edit</button>'+cancelBtn+'<button class="tact del" data-delete="'+l.id+'">Delete</button></td></tr>';
    }).join("")
      // every row is newer than today (or filters hid it) — today belongs at the bottom
      +(todayInView&&!placed?divider:"");
    body.querySelectorAll("[data-edit]").forEach(function(b){b.addEventListener("click",function(){openAdd(true,monthById[b.dataset.edit]);});});
    body.querySelectorAll("[data-cancel]").forEach(function(b){b.addEventListener("click",function(){cancelLesson(b.dataset.cancel);});});
    body.querySelectorAll("[data-restore]").forEach(function(b){b.addEventListener("click",function(){restoreLesson(monthById[b.dataset.restore]);});});
    body.querySelectorAll("[data-delete]").forEach(function(b){b.addEventListener("click",function(){deleteLesson(b.dataset.delete);});});
    body.querySelectorAll("[data-rsel]").forEach(function(cb){
      cb.addEventListener("change",function(){
        if(cb.checked)selectedRecords[cb.dataset.rsel]=1; else delete selectedRecords[cb.dataset.rsel];
        updateRecSelBar();
      });
    });
    // Mobile: rows are compact — tapping one (not a link/button) opens its detail sheet.
    body.querySelectorAll("tr[data-lid]").forEach(function(tr){
      tr.addEventListener("click",function(e){
        if(!window.matchMedia("(max-width:820px)").matches)return;
        if(e.target.closest("a,button,input,label"))return;
        openRecDetail(tr.dataset.lid);
      });
    });
    updateRecSelBar();
  }
  // Read-friendly detail sheet for one lesson (mobile), carrying the same row actions.
  function openRecDetail(id){
    var l=monthById[id]; if(!l)return;
    var badge=l.status==="cancelled"
      ?'<span class="kind-tag">cancelled</span>'+(l.amount>0?(l.paid?' <span class="badge paid">Paid</span>':' <span class="badge owed">Unpaid</span>'):'')
      :(l.status==="scheduled"?'<span class="kind-tag">scheduled</span>':(l.paid?'<span class="badge paid">Paid</span>':'<span class="badge owed">Unpaid</span>'));
    if(l.postponed)badge+=' <span class="kind-tag" style="background:#C8922A;color:#fff">postponed</span>';
    $("rd-title").textContent=recDate(l.lesson_date);
    var time=(l.start_time&&l.end_time)?(hm(l.start_time)+"–"+hm(l.end_time)):"";
    var items=[["Student",esc(nameById[l.student_id]||"—")],["Subject",l.subject?esc(l.subject):"—"],["Level",l.level?esc(l.level):"—"]];
    if(time)items.push(["Time",time]);
    items.push([l.status==="cancelled"?"Compensation":"Amount","<b>"+TL.sgd(l.amount)+"</b>"],["Status",badge]);
    $("rd-body").innerHTML='<div class="rd-list">'+items.map(function(r){return '<div class="rd-row"><span class="rd-k">'+r[0]+'</span><span class="rd-v">'+r[1]+'</span></div>';}).join("")+'</div>';
    var canc=l.status==="cancelled"?'<button class="btn" id="rd-restore">Restore</button>':'<button class="btn" id="rd-cancel" style="color:var(--gold-2)">Cancel lesson</button>';
    $("rd-actions").innerHTML='<button class="btn" id="rd-del" style="color:var(--owed)">Delete</button><span style="display:inline-flex;gap:8px;margin-left:auto">'+canc+'<button class="btn btn-primary" id="rd-edit">Postpone / edit</button></span>';
    $("rd-edit").onclick=function(){closeRecDetail();openAdd(true,l);};
    $("rd-del").onclick=function(){closeRecDetail();deleteLesson(id);};
    var rc=$("rd-cancel");if(rc)rc.onclick=function(){closeRecDetail();cancelLesson(id);};
    var rr=$("rd-restore");if(rr)rr.onclick=function(){closeRecDetail();restoreLesson(l);};
    $("rec-detail").classList.add("on");
  }
  function closeRecDetail(){$("rec-detail").classList.remove("on");}
  function updateRecSelBar(){
    var n=Object.keys(selectedRecords).length;
    var btn=$("rec-delsel-btn");
    if(btn){btn.style.display=n?"":"none";btn.textContent="Delete "+n+" selected";}
    var all=$("rec-selall");
    if(all)all.checked=lastRecordRows.length>0&&lastRecordRows.every(function(l){return selectedRecords[l.id];});
  }
  function toggleSelectAllRecords(){
    var checked=$("rec-selall").checked;
    lastRecordRows.forEach(function(l){if(checked)selectedRecords[l.id]=1; else delete selectedRecords[l.id];});
    renderRecords();
  }
  function deleteSelectedRecords(){
    var ids=Object.keys(selectedRecords);
    if(!ids.length)return;
    if(!confirm("Delete "+ids.length+" selected lesson(s) permanently? This cannot be undone."))return;
    selectedRecords={};
    deleteLessons(ids);
  }
  function shiftMonth(d){period.mode="month";var dt=new Date(period.y,period.m+d,1);period.y=dt.getFullYear();period.m=dt.getMonth();refreshPeriod();}
  function periodAll(){period.mode="all";refreshPeriod();}
  function periodThisMonth(){var n=new Date();period={mode:"month",y:n.getFullYear(),m:n.getMonth()};refreshPeriod();}
  // Outstanding / Records tabs — mirrors setDashMode() on the dashboard.
  function setLedgerMode(mode){
    var rec=mode==="rec";
    if($("out-view"))$("out-view").style.display=rec?"none":"block";
    if($("rec-view"))$("rec-view").style.display=rec?"block":"none";
    if($("seg-out"))$("seg-out").classList.toggle("on",!rec);
    if($("seg-rec"))$("seg-rec").classList.toggle("on",rec);
    try{localStorage.setItem("tl_ledger_mode",mode);}catch(e){}
  }
  // Count rides on the tab so you can see who's owing without switching to look.
  function setOutCount(n){var el=$("seg-out-n");if(el)el.textContent=n?" · "+n:"";}
  // Jump to today — snaps back to the current month first, so the button always lands somewhere.
  function goToday(){
    var n=new Date();
    if(period.mode!=="all"&&(period.y!==n.getFullYear()||period.m!==n.getMonth())){
      period={mode:"month",y:n.getFullYear(),m:n.getMonth()};renderRecords();
    }
    var el=$("rec-today");if(!el)return;
    el.scrollIntoView({behavior:"smooth",block:"center"});
    el.classList.remove("flash");void el.offsetWidth;el.classList.add("flash");
  }

  function csvCell(v){v=String(v==null?"":v);return /[",\n\r]/.test(v)?'"'+v.replace(/"/g,'""')+'"':v;}
  function exportCSV(){
    var rows=allLessons.filter(function(l){
      if(period.mode==="all")return true;
      return l.lesson_date.slice(0,7)===period.y+"-"+pad(period.m+1);
    });
    rows.sort(function(a,b){return (a.lesson_date+(a.start_time||"")).localeCompare(b.lesson_date+(b.start_time||""));});
    var head=["Date","Start","End","Student","Subject","Level","Amount (S$)","Status","Paid","Paid date"];
    var lines=[head.join(",")];
    rows.forEach(function(l){
      lines.push([l.lesson_date,hm(l.start_time),hm(l.end_time),nameById[l.student_id]||"",l.subject||"",l.level||"",
        Number(l.amount).toFixed(2),l.status,l.paid?"Yes":"No",l.paid_date||""].map(csvCell).join(","));
    });
    var csv="\ufeff"+lines.join("\r\n");
    var blob=new Blob([csv],{type:"text/csv;charset=utf-8"});
    var url=URL.createObjectURL(blob),a=document.createElement("a");
    a.href=url;a.download="Ledger_"+periodLabel().replace(/\s+/g,"-")+".csv";
    document.body.appendChild(a);a.click();a.remove();
    setTimeout(function(){URL.revokeObjectURL(url);},4000);
  }

  var cancelLessonId=null;
  function cancelLesson(id){
    cancelLessonId=id;
    $("cancel-amt").value="";$("cancel-msg").textContent="";$("cancel-msg").className="msg";
    $("cancel-modal").classList.add("on");
  }
  function closeCancelModal(){$("cancel-modal").classList.remove("on");cancelLessonId=null;}
  async function confirmCancel(){
    if(!cancelLessonId)return;
    var id=cancelLessonId, comp=Math.max(0,parseFloat($("cancel-amt").value)||0), msg=$("cancel-msg");
    $("cancel-confirm").disabled=true;
    var res=await window.sb.from("lessons").update({status:"cancelled",paid:false,paid_date:null,compensation:comp>0?comp:null}).eq("id",id);
    $("cancel-confirm").disabled=false;
    if(res.error){msg.textContent=res.error.message;msg.className="msg err";return;}
    closeCancelModal();
    load();
  }
  async function restoreLesson(l){
    var status=statusFor(l.lesson_date,hm(l.end_time));
    var res=await window.sb.from("lessons").update({status:status,compensation:null}).eq("id",l.id);
    if(res.error){alert("Couldn't restore: "+res.error.message);return;}
    load();
  }
  async function deleteLesson(id){
    if(!confirm("Delete this lesson permanently? (Use Cancel instead if you just want to void it.)"))return;
    var res=await window.sb.from("lessons").delete().eq("id",id);
    if(res.error){alert("Couldn't delete: "+res.error.message);return;}
    load();
  }
  async function deleteLessons(ids){
    var res=await window.sb.from("lessons").delete().in("id",ids);
    if(res.error){alert("Couldn't delete: "+res.error.message);return;}
    load();
  }

  // ---------- actions ----------
  // ---- keep invoices in step with payments ----
  // Reuse: if an unpaid invoice already covers these lessons, mark THAT paid.
  // Create: otherwise generate a paid receipt so it can be sent to the parent.
  // Create a paid-receipt invoice for these lessons, dated to the actual payment date.
  // Returns the new invoice id (or null) so a screenshot can be attached to it.
  async function createPaidInvoice(rows, paidDate){
    if(!profile)return null;
    var pd=paidDate||todayISO();
    var byStu={};rows.forEach(function(l){(byStu[l.student_id]=byStu[l.student_id]||[]).push(l);});
    var stuIds=Object.keys(byStu),single=stuIds.length===1;
    var names=stuIds.map(function(id){return nameById[id]||"Student";});
    var billTo=single?names[0]:(names.length===2?names[0]+" & "+names[1]:names.join(", "));
    var now=new Date(), pdate=new Date(pd+"T00:00:00");
    var total=Math.round(rows.reduce(function(t,l){return t+Number(l.amount);},0)*100)/100;
    var slug=single?((names[0]||"").replace(/[^A-Za-z0-9]/g,"").slice(0,8).toUpperCase()||"STUDENT")
                   :(names.map(function(n){return n.replace(/[^A-Za-z0-9]/g,"").slice(0,4);}).join("+").toUpperCase().slice(0,18)||"GROUP");
    var invoiceNo=(profile.invoice_prefix||"INV")+"-"+now.getFullYear()+pad(now.getMonth()+1)+pad(now.getDate())+"-"+slug;
    var sorted=rows.slice().sort(function(a,b){return a.lesson_date.localeCompare(b.lesson_date);});
    if(!single)sorted=sorted.map(function(l){return Object.assign({_who:nameById[l.student_id]||"—"},l);});
    var dstr=pdate.toLocaleDateString("en-SG",{day:"numeric",month:"short",year:"numeric"});
    var byBank=anyBank(stuIds);
    var data={biz:profile.business_name||"Tuition",invoiceNo:invoiceNo,dateStr:dstr,paidStr:dstr,
      student:billTo,lessons:sorted,total:total,combined:!single,paid:true,
      payTo:byBank?bankObj(profile).name:(profile.paynow_id?PayNow.normalize(profile.paynow_type,profile.paynow_id):"")};
    var html=invoiceHTML(data,"");   // paid receipt — no QR needed
    var ins=await window.sb.from("invoices").insert({
      tutor_id:userId,student_id:single?stuIds[0]:null,invoice_no:invoiceNo,
      issued_date:pd,total:total,status:"paid",paid_date:pd,
      data:{html:html,title:"Invoice_"+slug+"_"+pd,
        students:single?null:stuIds,name:single?null:billTo,lesson_ids:rows.map(function(l){return l.id;})}
    }).select("id").single();
    return ins.error?null:(ins.data&&ins.data.id);
  }
  // Settle/create the invoice covering these lessons; returns its id so proof can attach.
  // Keep every invoice that covers any of these lessons in sync with its lessons' paid state:
  //   all its lessons paid  → invoice "paid"  (paid_date = given date)
  //   any lesson unpaid     → invoice "issued" (revert if it had been settled)
  // Runs from both "mark paid" (Outstanding) and the Records edit, in both directions, so the
  // Invoices tab always matches the ledger. Returns the first covering invoice's id (for proof
  // attachment). With opts.create, freshly-paid lessons that no invoice covers get a paid receipt.
  async function reconcileInvoicesForLessons(ids, paidDate, opts){
    opts=opts||{};
    var q=await window.sb.from("invoices").select("id,data,status");
    if(q.error)return null;
    var matches=(q.data||[]).filter(function(v){
      var lids=(v.data&&v.data.lesson_ids)||[];
      return lids.length && lids.some(function(x){return ids.indexOf(x)>-1;});
    });
    var firstId=matches.length?matches[0].id:null;
    for(var i=0;i<matches.length;i++){
      var m=matches[i], lids=m.data.lesson_ids;
      var chk=await window.sb.from("lessons").select("id,paid").in("id",lids);
      var got=chk.data||[];
      var allPaid=got.length>0 && got.every(function(l){return l.paid;});
      if(allPaid && m.status!=="paid")
        await window.sb.from("invoices").update({status:"paid",paid_date:paidDate||todayISO()}).eq("id",m.id);
      else if(!allPaid && m.status==="paid")
        await window.sb.from("invoices").update({status:"issued",paid_date:null}).eq("id",m.id);
    }
    if(matches.length) return firstId;   // an invoice exists — reconciled above, never duplicated
    if(opts.create){
      var rows=allLessons.filter(function(l){return ids.indexOf(l.id)>-1 && l.paid;});
      if(rows.length) return await createPaidInvoice(rows, paidDate);
    }
    return null;
  }
  // Core: mark lessons paid on the given date, settle the invoice, attach the screenshot.
  async function doMarkPaid(ids, paidDate, file){
    var res=await window.sb.from("lessons").update({paid:true,paid_date:paidDate}).in("id",ids);
    if(res.error){alert("Couldn't update: "+res.error.message);return false;}
    var invId=null;
    try{ invId=await reconcileInvoicesForLessons(ids, paidDate, {create:true}); }
    catch(e){ console.warn("Invoice sync skipped:",e); }        // payment still stands
    if(file && invId){
      try{
        var safe=file.name.replace(/[^A-Za-z0-9._-]/g,"_");
        var path=userId+"/"+invId+"_"+Date.now()+"_"+safe;
        var up=await window.sb.storage.from("receipts").upload(path,file,{upsert:false});
        if(!up.error) await window.sb.from("invoices").update({proof_path:path}).eq("id",invId);
      }catch(e){ console.warn("Screenshot upload skipped:",e); }  // payment still stands
    }
    return true;
  }
  // Does any invoice covering these lessons already have a payment screenshot attached?
  async function existingProofFor(ids){
    var q=await window.sb.from("invoices").select("proof_path,data");
    if(q.error)return null;
    var hit=null;
    (q.data||[]).forEach(function(v){
      if(hit||!v.proof_path)return;
      var lids=(v.data&&v.data.lesson_ids)||[];
      if(lids.length && lids.some(function(x){return ids.indexOf(x)>-1;})) hit=v.proof_path;
    });
    return hit;
  }
  // Every "mark paid" trigger opens this modal to capture the real date + optional screenshot.
  async function openPayModal(ids){
    payIds=(ids||[]).slice();
    var myIds=payIds;   // guards the async note below against a reopen for different lessons
    if(!payIds.length)return;
    $("pay-date").value=todayISO(); $("pay-shot").value=""; $("pay-msg").textContent="";
    $("pay-sub").textContent="Marking "+payIds.length+" lesson"+(payIds.length===1?"":"s")+" as paid.";
    // If a covering invoice already has a screenshot, say so — no need to re-upload.
    var note=$("pay-proof"), lbl=$("pay-shot-lbl");
    if(note){ note.style.display="none"; note.textContent=""; }
    if(lbl) lbl.innerHTML='Transaction screenshot <span class="muted">(optional)</span>';
    $("pay-save").disabled=false;
    $("pay-modal").classList.add("on");
    try{
      var proof=await existingProofFor(myIds);
      if(proof && payIds===myIds && $("pay-modal").classList.contains("on")){
        if(note){ note.textContent="✓ A screenshot is already attached to this invoice — leave this blank to keep it, or choose a file to replace it."; note.style.display="block"; }
        if(lbl) lbl.innerHTML='Transaction screenshot <span class="muted">(optional — replaces the attached one)</span>';
      }
    }catch(e){ /* non-blocking: the field still works without the hint */ }
  }
  function closePay(){ $("pay-modal").classList.remove("on"); payIds=[]; }
  async function confirmPay(){
    if(!payIds.length){closePay();return;}
    var date=$("pay-date").value||todayISO(), file=$("pay-shot").files[0]||null, ids=payIds.slice();
    $("pay-save").disabled=true; $("pay-msg").textContent=file?"Saving + uploading…":"Saving…";
    ids.forEach(function(id){delete selectedLessons[id];});
    var ok=await doMarkPaid(ids, date, file);
    if(ok){ closePay(); load(); }
    else { $("pay-save").disabled=false; $("pay-msg").textContent=""; }
  }

  function studentOptions(){
    var act=students.filter(function(s){return s.active!==false && !TL.isEnded(s.end_date);});
    $("m-student").innerHTML=act.length?act.map(function(s){return '<option value="'+s.id+'">'+esc(s.name)+"</option>";}).join(""):'<option value="">— add a student first —</option>';
  }
  function splitAmt(rate,s,e,split){var sp=(split&&split>1)?split:1;return Math.round(TL.amount(rate,s,e)/sp*100)/100;}
  function mSplit(){return Math.max(1,parseInt($("m-split").value,10)||1);}
  function recalcCost(){
    var r=parseFloat($("m-rate").value),s=$("m-start").value,e=$("m-end").value;
    $("m-cost").value=(r>=0&&s&&e&&e>s)?TL.sgd(splitAmt(r,s,e,mSplit())):"";
  }
  function prefillFromSlot(){
    var sid=$("m-student").value;
    var slot=slots.find(function(x){return x.student_id===sid;});
    if(!slot){ // no recurring slot for this student — clear slot-derived fields
      ["m-start","m-end","m-rate","m-subject","m-level"].forEach(function(id){$(id).value="";});
      $("m-split").value="1"; recalcCost(); return;
    }
    $("m-rate").value=slot.rate!=null?slot.rate:"";
    $("m-split").value=slot.split||1;
    $("m-start").value=hm(slot.start_time);
    $("m-end").value=hm(slot.end_time);
    $("m-subject").value=slot.subject||"";
    $("m-level").value=slot.level||"";
    recalcCost();
  }
  function openAdd(open, lesson){
    $("modal").classList.toggle("on",open);
    $("m-msg").textContent="";$("m-msg").className="msg";
    if(!open)return;
    if(lesson){
      editLessonId=lesson.id;
      $("m-title").textContent="Postpone / edit lesson";$("m-save").textContent="Save changes";
      $("m-student").value=lesson.student_id;
      $("m-date").value=lesson.lesson_date;
      $("m-subject").value=lesson.subject||"";$("m-level").value=lesson.level||"";
      $("m-start").value=hm(lesson.start_time);$("m-end").value=hm(lesson.end_time);
      $("m-rate").value=lesson.rate;$("m-split").value=lesson.split||1;$("m-paid").checked=!!lesson.paid;$("m-postponed").checked=!!lesson.postponed;
      recalcCost();
    }else{
      editLessonId=null;
      $("m-title").textContent="Add lesson";$("m-save").textContent="Save lesson";
      $("m-date").value=todayISO();$("m-paid").checked=false;$("m-postponed").checked=false;
      ["m-subject","m-level","m-start","m-end","m-rate","m-cost"].forEach(function(id){$(id).value="";});
      $("m-split").value="1";
      prefillFromSlot();
    }
  }
  async function saveLesson(){
    var msg=$("m-msg");
    var sid=$("m-student").value,date=$("m-date").value,start=$("m-start").value,end=$("m-end").value,rate=parseFloat($("m-rate").value),split=mSplit();
    if(!sid){msg.textContent="Pick a student.";msg.className="msg err";return;}
    if(!date){msg.textContent="Pick a date.";msg.className="msg err";return;}
    if(!start||!end||end<=start){msg.textContent="Check the start/end times.";msg.className="msg err";return;}
    if(!(rate>=0)){msg.textContent="Enter a rate.";msg.className="msg err";return;}
    var paid=$("m-paid").checked;
    // status here is always scheduled/done, never cancelled — saving through this form
    // always un-cancels, so any compensation from a prior cancellation no longer applies.
    var fields={student_id:sid,lesson_date:date,start_time:start,end_time:end,
      subject:$("m-subject").value.trim()||null,level:$("m-level").value.trim()||null,rate:rate,split:split,amount:splitAmt(rate,start,end,split),
      status:statusFor(date,end),paid:paid,paid_date:paid?date:null,postponed:$("m-postponed").checked,compensation:null};
    $("m-save").disabled=true;
    var res=editLessonId
      ? await window.sb.from("lessons").update(fields).eq("id",editLessonId)   // editing never changes one_off
      : await window.sb.from("lessons").insert(Object.assign({tutor_id:userId,one_off:true},fields));   // manual add = one-off
    $("m-save").disabled=false;
    if(res.error){msg.textContent=res.error.message;msg.className="msg err";return;}
    // Ticking/unticking "already paid" here must flow through to any invoice covering this lesson.
    if(editLessonId){
      try{ await reconcileInvoicesForLessons([editLessonId], fields.paid_date||todayISO(), {create:false}); }
      catch(e){ console.warn("Invoice reconcile skipped:",e); }
    }
    openAdd(false);load();
  }
  async function generateMonth(){
    if(!slots.length){alert("No recurring slots to generate from. Add them on the Planner first.");return;}
    var now=new Date(),base=new Date(now.getFullYear(),now.getMonth()+genMonthOff,1),y=base.getFullYear(),m=base.getMonth();
    var last=new Date(y,m+1,0).getDate();
    var mStart=iso(new Date(y,m,1)),mEnd=iso(new Date(y,m,last));
    var mo=["January","February","March","April","May","June","July","August","September","October","November","December"][m];
    var ex=await window.sb.from("lessons").select("student_id,lesson_date,start_time").gte("lesson_date",mStart).lte("lesson_date",mEnd);
    var seen={};(ex.data||[]).forEach(function(l){seen[l.student_id+"|"+l.lesson_date+"|"+hm(l.start_time)]=1;});
    var rows=[];
    for(var day=1;day<=last;day++){
      var d=new Date(y,m,day),wd=(d.getDay()+6)%7,di=iso(d);
      slots.forEach(function(s){
        if(s.weekday!==wd)return;
        if(TL.pastEnd(endById[s.student_id],di))return;   // student's lessons end on their end_date
        if(seen[s.student_id+"|"+di+"|"+hm(s.start_time)])return;
        rows.push({tutor_id:userId,student_id:s.student_id,slot_id:s.id,lesson_date:di,slot_date:di,start_time:s.start_time,end_time:s.end_time,subject:s.subject,level:s.level,rate:s.rate,split:s.split||1,amount:splitAmt(s.rate,hm(s.start_time),hm(s.end_time),s.split),status:statusFor(di,hm(s.end_time)),paid:false});
      });
    }
    if(!rows.length){alert(mo+" is already fully logged — nothing new to add.");return;}
    if(!confirm("Add "+rows.length+" lessons to fill every recurring slot across "+mo+"? Already-logged lessons are skipped."))return;
    var res=await window.sb.from("lessons").insert(rows);
    if(res.error){alert("Couldn't generate: "+res.error.message);return;}
    load();
  }
  async function generateWeek(){
    if(!slots.length){alert("No recurring slots to generate from. Add them on the Planner first.");return;}
    var mon=mondayOf(new Date());mon.setDate(mon.getDate()+genWeekOff*7);
    var weekStart=iso(mon),end=new Date(mon);end.setDate(mon.getDate()+6);var weekEnd=iso(end);
    var ex=await window.sb.from("lessons").select("student_id,lesson_date,start_time").gte("lesson_date",weekStart).lte("lesson_date",weekEnd);
    var seen={};(ex.data||[]).forEach(function(l){seen[l.student_id+"|"+l.lesson_date+"|"+hm(l.start_time)]=1;});
    var rows=[];
    slots.forEach(function(s){
      var d=new Date(mon);d.setDate(mon.getDate()+s.weekday);var di=iso(d);
      if(TL.pastEnd(endById[s.student_id],di))return;   // student's lessons end on their end_date
      if(seen[s.student_id+"|"+di+"|"+hm(s.start_time)])return;
      rows.push({tutor_id:userId,student_id:s.student_id,slot_id:s.id,lesson_date:di,slot_date:di,start_time:s.start_time,end_time:s.end_time,subject:s.subject,level:s.level,rate:s.rate,split:s.split||1,amount:splitAmt(s.rate,hm(s.start_time),hm(s.end_time),s.split),status:statusFor(di,hm(s.end_time)),paid:false});
    });
    if(!rows.length){alert("This week is already logged — nothing new to add.");return;}
    if(!confirm("Add "+rows.length+" lessons for "+weekStart+" to "+weekEnd+"?"))return;
    var res=await window.sb.from("lessons").insert(rows);
    if(res.error){alert("Couldn't generate: "+res.error.message);return;}
    load();
  }

  // ---------- invoice ----------
  function invoiceHTML(d, qrUrl){
    var combined=!!d.combined;
    function durHrs(l){ var s=hm(l.start_time),e=hm(l.end_time); if(!s||!e)return 0;
      var tm=function(t){var p=t.split(":");return (+p[0])*60+(+p[1]);}; var m=tm(e)-tm(s); return m>0?m/60:0; }
    function hrsLabel(h){ h=Math.round(h*100)/100; return h===1?"1 hr":(h+" hrs"); }
    function lrow(l){
      if(l.status==="cancelled") return "<tr><td>"+prettyDate(l.lesson_date)+"</td><td>Cancellation fee</td>"+'<td class="r">'+TL.sgd(l.amount)+"</td></tr>";
      var dur=durHrs(l);
      return "<tr><td>"+prettyDate(l.lesson_date)+"</td><td>"+(dur?hrsLabel(dur):"Lesson")+'</td><td class="r">'+TL.sgd(l.amount)+"</td></tr>";
    }
    // Label for a student's lessons: SUBJECTS from the invoiced lessons themselves (so only what's
    // actually billed this month appears — a Math-only month never lists their Chinese slot), and
    // LEVEL from the student profile (one grade across subjects; this is the field that was showing
    // wrong when a lesson kept a switched student's stale level). Level falls back to the lesson's own
    // value only if the profile has none. Called per student (single invoice / one household member).
    function subjLevel(ls){
      var out=[], done={};
      ls.forEach(function(l){
        var id=l.student_id; if(id==null||done[id])return; done[id]=1;
        var mine=ls.filter(function(x){return String(x.student_id)===String(id);});
        var subs=[], seen={};
        mine.forEach(function(x){ if(x.subject && !seen[x.subject]){ seen[x.subject]=1; subs.push(x.subject); } });
        var lvl=levelById[id]||(mine[0]&&mine[0].level)||"";
        var label=[subs.join(", "), lvl].filter(Boolean).join(" · ");
        if(label) out.push(label);
      });
      return out.join(", ");
    }
    // "N hrs @ $R/hr" from the effective (blended) rate = amount / hours — cancellation
    // fees aren't taught hours, so they'd skew this; excluded from the note (their amount
    // still counts in the subtotal/total, just not in this blended-rate line).
    function rateNote(ls){ var real=ls.filter(function(l){return l.status!=="cancelled";});
      var hrs=real.reduce(function(t,l){return t+durHrs(l);},0), amt=real.reduce(function(t,l){return t+(Number(l.amount)||0);},0);
      if(!hrs)return ""; return hrsLabel(hrs)+" @ "+TL.sgd(Math.round(amt/hrs*100)/100)+"/hr"; }
    var rows;
    if(combined){
      // Group each student's lessons together with their own subject/level + subtotal (rate/hr).
      var order=[], byWho={};
      d.lessons.forEach(function(l){ var w=l._who||"—"; if(!byWho[w]){byWho[w]=[];order.push(w);} byWho[w].push(l); });
      rows=order.map(function(w){
        var grp=byWho[w], sub=Math.round(grp.reduce(function(t,l){return t+(Number(l.amount)||0);},0)*100)/100, sl=subjLevel(grp), rn=rateNote(grp);
        return '<tr><td colspan="3" style="background:#faf6ec;padding:9px 8px 6px"><span style="font-weight:700;color:#1A2A4F">'+esc(w)+'</span>'+
            (sl?' <span style="color:#6b7280;font-size:12px">— '+esc(sl)+'</span>':'')+'</td></tr>'+
          grp.map(lrow).join("")+
          '<tr><td colspan="2" class="r" style="color:#6b7280;font-size:12px;border-top:1px solid #eee;padding-bottom:8px">Subtotal'+(rn?' · '+rn:'')+'</td>'+
          '<td class="r" style="color:#6b7280;font-size:12px;border-top:1px solid #eee;padding-bottom:8px">'+TL.sgd(sub)+'</td></tr>';
      }).join("");
    } else {
      rows=d.lessons.map(lrow).join("");
    }
    var billSL=combined?"":subjLevel(d.lessons), totalRN=combined?"":rateNote(d.lessons);
    return '<div class="invoice">'+
      '<div class="inv-head"><div class="inv-biz">'+esc(d.biz)+'<small>Invoice</small></div>'+
        '<div class="inv-meta"><b>'+esc(d.invoiceNo)+'</b><br>'+d.dateStr+'</div></div>'+
      '<div class="inv-to"><span class="lbl">Bill to</span><br><b>'+esc(d.student)+'</b>'+
        (billSL?'<br><span style="color:#6b7280;font-size:12.5px">'+esc(billSL)+'</span>':'')+'</div>'+
      '<table class="inv-table"><thead><tr><th>Date</th><th>Duration</th><th class="r">Amount</th></tr></thead>'+
        '<tbody>'+rows+'</tbody></table>'+
      (totalRN?'<div class="r" style="color:#6b7280;font-size:12px;padding:5px 8px 0">'+esc(totalRN)+'</div>':'')+
      '<div class="inv-total"><span>'+(d.paid?"Total paid":"Total due")+'</span><span>'+TL.sgd(d.total)+'</span></div>'+
      (d.paid
        ? '<div class="inv-pay"><div><div class="pn-h"><span class="pn-dot"></span>Paid</div>'+
          '<div class="pn-sub">Received with thanks'+(d.paidStr?" on <b>"+esc(d.paidStr)+"</b>":"")+'.<br>'+
          (d.payTo?'Paid to <b>'+esc(d.payTo)+'</b><br>':'')+'Ref: <b>'+esc(d.invoiceNo)+'</b></div></div></div>'
        : d.bank
        ? '<div class="inv-pay"><div><div class="pn-h"><span class="pn-dot"></span>Bank transfer</div>'+
          '<div class="pn-sub">'+
          'Account name: <b>'+esc(d.bank.name)+'</b><br>'+
          (d.bank.bank?'Bank: <b>'+esc(d.bank.bank)+'</b><br>':'')+
          'Account no: <b>'+esc(d.bank.acct)+'</b><br>'+
          (d.bank.swift?'SWIFT/BIC: <b>'+esc(d.bank.swift)+'</b><br>':'')+
          'Ref: <b>'+esc(d.invoiceNo)+'</b></div></div></div>'
        : '<div class="inv-pay"><img src="'+qrUrl+'" alt="PayNow QR">'+
          '<div><div class="pn-h"><span class="pn-dot"></span>PayNow</div>'+
          '<div class="pn-sub">Scan with any Singapore banking app to pay.<br>'+
          'Pays to <b>'+esc(d.payTo)+'</b><br>Ref: <b>'+esc(d.invoiceNo)+'</b></div></div></div>')+
      '</div>';
  }

  // Load the QR library on demand, trying two CDNs (resilient to a blocked/missing script tag)
  var qrLoading=null;
  function loadQR(){
    if(window.QRCode&&window.QRCode.toDataURL)return Promise.resolve();
    if(qrLoading)return qrLoading;
    var urls=["assets/js/qrlib.js",
              "https://cdn.jsdelivr.net/npm/qrcode@1.4.4/build/qrcode.min.js",
              "https://unpkg.com/qrcode@1.4.4/build/qrcode.min.js"];
    qrLoading=new Promise(function(resolve,reject){
      var i=0;
      (function next(){
        if(window.QRCode&&window.QRCode.toDataURL)return resolve();
        if(i>=urls.length)return reject(new Error("blocked"));
        var s=document.createElement("script");
        s.src=urls[i++];
        s.onload=function(){(window.QRCode&&window.QRCode.toDataURL)?resolve():next();};
        s.onerror=next;
        document.head.appendChild(s);
      })();
    });
    return qrLoading;
  }

  // Show the built invoice in the overlay (shared by the PayNow and bank-transfer paths).
  function presentInvoice(data, qrUrl, meta){
    window._invHTML=invoiceHTML(data,qrUrl); window._invSaved=false;
    window._invMeta=meta;
    $("inv-body").innerHTML=window._invHTML;
    $("inv-save").textContent="Save to app";$("inv-save").disabled=false;
    $("inv-backdrop").classList.add("on");
  }
  // If any billed student pays by bank, the invoice shows bank details (no PayNow QR).
  function anyBank(ids){ return ids.some(function(id){return payByBankById[id];}); }

  async function openInvoice(studentId, onlyIds){
    if(!profile){
      alert("Couldn't read your profile. Make sure you've run db/migration_paynow.sql in Supabase.");
      return;
    }
    var byBank=!!payByBankById[studentId];
    if(byBank && !hasBank(profile)){
      if(confirm("This student pays by bank transfer, but no bank details are saved yet. Open Settings to add them now?")) location.href="settings.html";
      return;
    }
    if(!byBank && !profile.paynow_id){
      if(confirm("No PayNow details saved yet. Open Settings to add them now?")) location.href="settings.html";
      return;
    }
    var lessons=(outGroups[studentId]||[]).slice()
      .filter(function(l){ return !onlyIds || onlyIds.indexOf(String(l.id))>-1; })   // invoice only the picked lessons, if any
      .sort(function(a,b){return a.lesson_date.localeCompare(b.lesson_date);});
    if(!lessons.length)return;
    var total=Math.round(lessons.reduce(function(t,l){return t+Number(l.amount);},0)*100)/100;
    var student=nameById[studentId]||"Student";
    var now=new Date();
    window._invTitle="Invoice_"+(student.replace(/[^A-Za-z0-9]+/g,"")||"Student")+"_"+now.getFullYear()+"-"+pad(now.getMonth()+1)+"-"+pad(now.getDate());
    var slug=student.replace(/[^A-Za-z0-9]/g,"").slice(0,8).toUpperCase();
    var invoiceNo=(profile.invoice_prefix||"INV")+"-"+now.getFullYear()+pad(now.getMonth()+1)+pad(now.getDate())+"-"+slug;
    var data={biz:profile.business_name||"Tuition",invoiceNo:invoiceNo,
      dateStr:now.toLocaleDateString("en-SG",{day:"numeric",month:"short",year:"numeric"}),
      student:student,lessons:lessons,total:total};
    var meta={studentId:studentId,invoiceNo:invoiceNo,total:total,issuedDate:iso(now),month:monthsLabel(lessons),lessonIds:lessons.map(function(l){return l.id;})};
    if(byBank){
      data.bank=bankObj(profile); data.payTo=data.bank.name;
      presentInvoice(data,"",meta);
      return;
    }
    try{ await loadQR(); }
    catch(e){
      alert("The QR code library is being blocked (ad-blocker or network). Allow cdn.jsdelivr.net or unpkg.com, then try again.");
      return;
    }
    data.payTo=PayNow.normalize(profile.paynow_type,profile.paynow_id);
    try{
      var payload=PayNow.build({type:profile.paynow_type,id:profile.paynow_id,amount:total,name:profile.business_name||"Tuition",reference:invoiceNo});
      window.QRCode.toDataURL(payload,{margin:1,width:300},function(err,url){
        if(err){alert("Couldn't generate QR: "+(err.message||err));return;}
        presentInvoice(data,url,meta);
      });
    }catch(e){ alert("Invoice error: "+(e.message||e)); }
  }

  async function openInvoiceMany(ids, onlyIds){
    if(!profile){alert("Couldn't read your profile. Make sure you've run db/migration_paynow.sql in Supabase.");return;}
    var byBank=anyBank(ids);
    if(byBank && !hasBank(profile)){
      if(confirm("This household pays by bank transfer, but no bank details are saved yet. Open Settings to add them now?"))location.href="settings.html";
      return;
    }
    if(!byBank && !profile.paynow_id){if(confirm("No PayNow details saved yet. Open Settings to add them now?"))location.href="settings.html";return;}
    var all=[];
    ids.forEach(function(id){(outGroups[id]||[]).forEach(function(l){ if(!onlyIds||onlyIds.indexOf(String(l.id))>-1) all.push(Object.assign({_who:nameById[id]||"—"},l)); });});
    all.sort(function(a,b){return a.lesson_date.localeCompare(b.lesson_date)||String(a._who).localeCompare(String(b._who));});
    if(!all.length)return;
    var total=Math.round(all.reduce(function(t,l){return t+Number(l.amount);},0)*100)/100;
    var names=ids.map(function(id){return nameById[id]||"Student";});
    var billTo=names.length===2?names[0]+" & "+names[1]:names.join(", ");
    var now=new Date();
    var slug=names.map(function(n){return n.replace(/[^A-Za-z0-9]/g,"").slice(0,4);}).join("+").toUpperCase().slice(0,18)||"GROUP";
    window._invTitle="Invoice_"+slug+"_"+now.getFullYear()+"-"+pad(now.getMonth()+1)+"-"+pad(now.getDate());
    var invoiceNo=(profile.invoice_prefix||"INV")+"-"+now.getFullYear()+pad(now.getMonth()+1)+pad(now.getDate())+"-"+slug;
    var data={biz:profile.business_name||"Tuition",invoiceNo:invoiceNo,
      dateStr:now.toLocaleDateString("en-SG",{day:"numeric",month:"short",year:"numeric"}),
      student:billTo,lessons:all,total:total,combined:true};
    var meta={studentId:null,students:ids,name:billTo,
      recipient:(ids.map(function(id){return recipientById[id];}).filter(Boolean)[0]||""),   // parent name for {name}
      invoiceNo:invoiceNo,total:total,issuedDate:iso(now),month:monthsLabel(all),lessonIds:all.map(function(l){return l.id;})};
    if(byBank){
      data.bank=bankObj(profile); data.payTo=data.bank.name;
      presentInvoice(data,"",meta);
      return;
    }
    try{ await loadQR(); }
    catch(e){ alert("The QR code library is being blocked (ad-blocker or network). Allow cdn.jsdelivr.net or unpkg.com, then try again."); return; }
    data.payTo=PayNow.normalize(profile.paynow_type,profile.paynow_id);
    try{
      var payload=PayNow.build({type:profile.paynow_type,id:profile.paynow_id,amount:total,name:profile.business_name||"Tuition",reference:invoiceNo});
      window.QRCode.toDataURL(payload,{margin:1,width:300},function(err,url){
        if(err){alert("Couldn't generate QR: "+(err.message||err));return;}
        presentInvoice(data,url,meta);
      });
    }catch(e){ alert("Invoice error: "+(e.message||e)); }
  }

  async function saveInvoice(){
    if(!window._invHTML||!window._invMeta)return;
    var m=window._invMeta,b=$("inv-save");
    b.disabled=true;b.textContent="Saving…";
    var res=await window.sb.from("invoices").insert({
      tutor_id:userId,student_id:m.studentId,invoice_no:m.invoiceNo,
      issued_date:m.issuedDate,total:m.total,status:"issued",
      data:{html:window._invHTML,title:window._invTitle||("Invoice_"+m.invoiceNo),
        students:m.students||null,name:m.name||null,lesson_ids:m.lessonIds||null}
    });
    b.disabled=false;
    if(res.error){b.textContent="Save to app";alert("Couldn't save invoice: "+res.error.message);return;}
    window._invSaved=true;   // recorded in the Invoices tab
    b.textContent="Saved ✓";setTimeout(function(){b.textContent="Save to app";},1600);
  }

  // Lazily load html2canvas (self-hosted copy first, then CDNs) for rendering the invoice to an image.
  function loadH2C(){
    if(window.html2canvas)return Promise.resolve();
    var urls=["assets/js/html2canvas.min.js",
      "https://cdnjs.cloudflare.com/ajax/libs/html2canvas/1.4.1/html2canvas.min.js",
      "https://cdn.jsdelivr.net/npm/html2canvas@1.4.1/dist/html2canvas.min.js",
      "https://unpkg.com/html2canvas@1.4.1/dist/html2canvas.min.js"];
    return new Promise(function(resolve,reject){
      (function tryNext(i){
        if(i>=urls.length){reject(new Error("could not load the image library"));return;}
        var s=document.createElement("script");s.src=urls[i];
        s.onload=function(){window.html2canvas?resolve():tryNext(i+1);};
        s.onerror=function(){tryNext(i+1);};
        document.head.appendChild(s);
      })(0);
    });
  }
  function invoiceMsg(m){
    var isCombined=!m.studentId;
    var byBank=isCombined?anyBank(m.students||[]):!!payByBankById[m.studentId];
    var vars={name:isCombined?(m.recipient||m.name||""):(recipientById[m.studentId]||nameById[m.studentId]||""),
      student:isCombined?(m.name||""):(nameById[m.studentId]||""),business:(profile&&profile.business_name)||"your tutor",
      amount:TL.sgd(m.total),count:"",invoice:m.invoiceNo,paynow:byBank?"":((profile&&profile.paynow_id)||""),
      month:m.month||"",date:prettyDate(m.issuedDate),year:(m.issuedDate||"").slice(0,4)};
    // Bank clients can't use PayNow — the default message points them to the on-invoice bank details.
    var tpl=(profile&&profile.invoice_message)||(byBank?DEFAULT_INVOICE_BANK:DEFAULT_INVOICE);
    return fillTemplate(tpl,vars);
  }
  // Two WhatsApp flows, picked by OS:
  //   • macOS desktop  → skip the OS share sheet (it has no WhatsApp entry, so it dead-ends) and
  //                      go straight to WhatsApp Web/Desktop via wa.me, image downloaded + on the
  //                      clipboard. (Raphael's Mac fix.)
  //   • everything else (Windows/Linux desktop, Android, iOS) → the original native share sheet
  //                      with the image attached — where WhatsApp IS a share target. (Friend's flow.)
  // iOS stays on the share sheet on purpose: unlike macOS, its sheet lists WhatsApp.
  function isMacDesktop(){
    var uaData=navigator.userAgentData;
    var plat=(uaData&&uaData.platform)||navigator.platform||"";
    var ua=navigator.userAgent||"";
    var isMac=/Mac/i.test(plat)||/Mac OS X/i.test(ua);
    var touch=(navigator.maxTouchPoints||0)>0;   // real Macs have no touch; iPad/iPhone report Mac-ish but do
    return isMac && !touch;
  }
  // Copy text to the clipboard (async API, with a legacy fallback). Returns true on success.
  async function copyText(text){
    try{ if(navigator.clipboard&&navigator.clipboard.writeText){ await navigator.clipboard.writeText(text); return true; } }catch(e){}
    try{
      var ta=document.createElement("textarea"); ta.value=text;
      ta.style.position="fixed"; ta.style.top="-1000px"; ta.style.opacity="0";
      document.body.appendChild(ta); ta.focus(); ta.select();
      var ok=document.execCommand("copy"); ta.remove(); return ok;
    }catch(e){ return false; }
  }
  async function shareInvoice(){
    if(!window._invHTML||!window._invMeta)return;
    var m=window._invMeta,b=$("inv-wa"),msg=invoiceMsg(m);
    b.disabled=true;b.textContent="Preparing…";
    if(!window._invSaved){ try{ await saveInvoice(); }catch(e){} }   // sending records the invoice in the Invoices tab
    // WhatsApp often drops the text when an image is shared/attached, so keep the message on the
    // clipboard — it can always be pasted into the chat even if it doesn't prefill.
    var copied=await copyText(msg);
    try{
      await loadH2C();
      var node=$("inv-body").firstElementChild||$("inv-body");
      var canvas=await window.html2canvas(node,{backgroundColor:"#ffffff",scale:2,useCORS:true});
      canvas.toBlob(async function(blob){
        b.disabled=false;b.textContent="Send on WhatsApp";
        if(!blob){alert("Couldn't render the invoice image.");return;}
        var file=new File([blob],(window._invTitle||("Invoice_"+m.invoiceNo))+".png",{type:"image/png"});
        // Original flow (Windows/Linux/Android/iOS): native share sheet, image attached. Skipped
        // only on macOS desktop, where the sheet dead-ends — that falls through to wa.me below.
        if(!isMacDesktop() && navigator.canShare && navigator.canShare({files:[file]})){
          try{
            await navigator.share({files:[file],text:msg});
            alert((copied?"Your message is copied to the clipboard — ":"Tip: copy your message, then ")+"paste it into the chat if WhatsApp only shows the image.");
            return;
          }
          catch(e){ if(e&&e.name==="AbortError")return; /* otherwise fall through */ }
        }
        // Fallback (desktop / unsupported): download image, open WhatsApp with text to attach manually
        var url=URL.createObjectURL(blob),a=document.createElement("a");
        a.href=url;a.download=file.name;document.body.appendChild(a);a.click();a.remove();
        setTimeout(function(){URL.revokeObjectURL(url);},5000);
        var num=waNumber(contactById[m.studentId||(m.students&&m.students[0])]);   // combined: use the household's number
        window.open(num ? "https://wa.me/"+num+"?text="+encodeURIComponent(msg)
                        : "https://api.whatsapp.com/send?text="+encodeURIComponent(msg), "_blank");
        alert((copied?"Your message has been copied — paste it into the chat if it doesn't prefill.\n\n":"")+"The invoice image was just downloaded — attach it in the WhatsApp chat that opened.");
      },"image/png");
    }catch(e){
      b.disabled=false;b.textContent="Send on WhatsApp";
      alert("Couldn't prepare the invoice image: "+(e.message||e)+"\n\nIf this keeps happening, the image library may be blocked — tell me and I'll set up a self-hosted copy.");
    }
  }

  function printInvoice(){
    if(!window._invHTML)return;
    var css=document.querySelector('link[rel="stylesheet"]').href;
    var w=window.open("","_blank","width=720,height=900");
    if(!w){alert("Allow pop-ups to print, or use your browser's print on this page.");return;}
    var title=esc(window._invTitle||"Invoice");
    w.document.write('<!doctype html><html><head><meta charset="utf-8"><title>'+title+'</title>'+
      '<link rel="stylesheet" href="'+css+'"><style>body{background:#fff;padding:28px;max-width:640px;margin:auto}</style></head>'+
      '<body>'+window._invHTML+'</body></html>');
    w.document.close();
    w.onload=function(){ setTimeout(function(){ w.focus(); w.print(); }, 250); };
  }

  // ---------- load ----------
  async function load(){
    await TL.promotePastLessons();
    var pr=await window.sb.from("profiles").select("business_name,paynow_type,paynow_id,invoice_prefix,reminder_message,invoice_message,bank_account_name,bank_name,bank_account_no,bank_swift").eq("id",userId).single();
    profile=pr.error?null:pr.data;

    var st=await window.sb.from("students").select("id,name,active,contact,recipient_name,pay_by_bank,level,end_date").order("name");
    students=st.data||[];nameById={};contactById={};recipientById={};payByBankById={};levelById={};endById={};householdBy={};students.forEach(function(s){nameById[s.id]=s.name;contactById[s.id]=s.contact;recipientById[s.id]=s.recipient_name;payByBankById[s.id]=!!s.pay_by_bank;levelById[s.id]=s.level||"";endById[s.id]=s.end_date||null;householdBy[s.id]=(function(c){var d=(c||"").replace(/\D/g,"");if(d.length===10&&d.slice(0,2)==="65")d=d.slice(2);return d||null;})(s.contact);});
    studentOptions();

    var sl=await window.sb.from("recurring_slots").select("id,student_id,weekday,start_time,end_time,subject,level,rate,split").eq("active",true);
    slots=sl.data||[];

    var ls=await window.sb.from("lessons").select("id,student_id,lesson_date,start_time,end_time,subject,level,rate,split,amount,paid,paid_date,status,postponed,compensation");
    if(ls.error){$("k-pending").textContent="—";$("out-hint").textContent="Couldn't load: "+ls.error.message;return;}
    var lessons=ls.data||[];
    // A cancelled lesson's billable amount is its compensation (0 if none) — everything
    // downstream (Outstanding, KPIs, invoices, CSV) reads plain l.amount, so normalizing
    // it once here means none of that code needs to know compensation exists.
    lessons.forEach(function(l){ if(l.status==="cancelled") l.amount=Number(l.compensation)||0; });

    allLessons=lessons;
    var unpaid=lessons.filter(function(l){return !l.paid&&(l.status==="done"||(l.status==="cancelled"&&l.amount>0));});
    lastUnpaid=unpaid;
    renderPendingKpi();   // pending follows the month picker (All = all-time total)
    renderMonthKpis();    // collected/projected follow the picked month (All = current month)

    renderOutstanding(unpaid);
    fillSubjects(allLessons.map(function(l){return l.subject;}).concat(slots.map(function(s){return s.subject;})));fillRecFilters();
    renderRecords();
  }

  // One shared period (the header navigator) drives the KPIs, Outstanding, and Records.
  function periodKey(){ return period.mode==="all"?"all":(period.y+"-"+pad(period.m+1)); }
  function updatePeriodUI(){
    if($("p-label"))$("p-label").textContent=periodLabel();
    if($("p-all"))$("p-all").classList.toggle("on",period.mode==="all");
    // "This month" only shows when you've moved away from the current month
    var n=new Date(), cur=period.mode==="month"&&period.y===n.getFullYear()&&period.m===n.getMonth();
    if($("p-today"))$("p-today").style.display=cur?"none":"";
  }
  function persistPeriod(){ try{localStorage.setItem("tl_period",JSON.stringify(period));}catch(e){} }
  function refreshPeriod(){ persistPeriod(); updatePeriodUI(); renderPendingKpi(); renderMonthKpis(); renderOutstanding(lastUnpaid); renderRecords(); }
  // Pending KPI: All = all-time total; a specific month = that month's pending.
  function renderPendingKpi(){
    var all=lastUnpaid||[], pk=periodKey();
    var sel=pk==="all"?all:all.filter(function(l){return (l.lesson_date||"").slice(0,7)===pk;});
    var amt=sel.reduce(function(t,l){return t+Number(l.amount);},0);
    var lbl=$("k-pending-lbl"), note=$("k-pending-n");
    $("k-pending").textContent=TL.sgd(amt);
    if(pk==="all"){ if(lbl)lbl.textContent="Owed (all time)"; if(note)note.textContent=all.length+" unpaid lesson"+(all.length===1?"":"s"); }
    else{ if(lbl)lbl.textContent="Owed"; if(note)note.textContent=sel.length+" unpaid"; }
  }
  // Collected/Projected describe the picked month (current month while on All).
  function activeMonthRange(){
    var y,m; if(period.mode==="all"){var n=new Date();y=n.getFullYear();m=n.getMonth()+1;}else{y=period.y;m=period.m+1;}
    return { first:y+"-"+pad(m)+"-01", last:y+"-"+pad(m)+"-"+pad(new Date(y,m,0).getDate()),
      label:new Date(y,m-1,1).toLocaleDateString("en-SG",{month:"long",year:"numeric"}) };
  }
  function renderMonthKpis(){
    var r=activeMonthRange();
    var month=(allLessons||[]).filter(function(l){return l.lesson_date>=r.first&&l.lesson_date<=r.last;});
    var collected=month.filter(function(l){return l.paid;}).reduce(function(t,l){return t+Number(l.amount);},0);
    // No cancelled-exclusion needed: a cancelled lesson's amount is already normalized to
    // its compensation (0 if none), so a plain lesson-run vs. a compensated cancellation
    // both contribute correctly, and a no-compensation cancellation contributes $0.
    var projected=month.reduce(function(t,l){return t+Number(l.amount);},0);
    $("k-collected").textContent=TL.sgd(collected); if($("k-collected-n"))$("k-collected-n").textContent=period.mode==="all"?r.label:"this month";
    $("k-projected").textContent=TL.sgd(projected);  if($("k-projected-n"))$("k-projected-n").textContent=period.mode==="all"?r.label:"lessons this month";
  }
  function init(user){
    userId=user.id;
    var on=function(id,evt,fn){var el=$(id);if(el)el.addEventListener(evt,fn);};
    try{var sp=localStorage.getItem("tl_period"); if(sp)period=JSON.parse(sp);}catch(e){}
    if(!period||!period.mode) period={mode:"month",y:new Date().getFullYear(),m:new Date().getMonth()};
    updatePeriodUI();
    on("p-prev","click",function(){shiftMonth(-1);});
    on("p-next","click",function(){shiftMonth(1);});
    on("p-today","click",periodThisMonth);
    on("p-all","click",periodAll);
    on("add-btn","click",function(){openAdd(true);});
    on("gen-btn","click",generateWeek);
    on("gen-month-btn","click",generateMonth);
    on("wk-prev","click",function(){stepWeek(-1);});
    on("wk-next","click",function(){stepWeek(1);});
    on("mo-prev","click",function(){stepMonth(-1);});
    on("mo-next","click",function(){stepMonth(1);});
    on("gen-custom-btn","click",openCustom);
    on("cr-cancel","click",closeCustom);
    on("cr-modal","click",function(e){if(e.target===$("cr-modal"))closeCustom();});
    on("cr-save","click",generateRange);
    setGenLabel();
    on("m-cancel","click",function(){openAdd(false);});
    on("modal","click",function(e){if(e.target===$("modal"))openAdd(false);});
    on("m-save","click",saveLesson);
    on("pay-cancel","click",closePay);
    on("pay-modal","click",function(e){if(e.target===$("pay-modal"))closePay();});
    on("pay-save","click",confirmPay);
    on("cancel-back","click",closeCancelModal);
    on("cancel-modal","click",function(e){if(e.target===$("cancel-modal"))closeCancelModal();});
    on("cancel-confirm","click",confirmCancel);
    on("rd-close","click",closeRecDetail);
    on("rec-detail","click",function(e){if(e.target===$("rec-detail"))closeRecDetail();});
    on("m-student","change",prefillFromSlot);
    ["m-rate","m-split","m-start","m-end"].forEach(function(id){on(id,"input",recalcCost);});
    on("inv-close","click",function(){$("inv-backdrop").classList.remove("on");});
    on("inv-backdrop","click",function(e){if(e.target===$("inv-backdrop"))$("inv-backdrop").classList.remove("on");});
    on("inv-print","click",printInvoice);
    on("inv-wa","click",shareInvoice);
    on("inv-save","click",saveInvoice);
    // period nav is the shared header control (p-prev/p-next/p-today/p-all), wired above
    on("csv-btn","click",function(){closeMenus();exportCSV();});
    // dropdown menus (Log lessons, ⋯): toggle on tap, close on outside tap / Esc
    function closeMenus(except){document.querySelectorAll(".dd.open").forEach(function(d){if(d!==except){d.classList.remove("open");var b=d.querySelector("[aria-expanded]");if(b)b.setAttribute("aria-expanded","false");}});}
    ["log-dd","more-dd"].forEach(function(id){var d=$(id);if(!d)return;var b=d.querySelector("button");
      b.addEventListener("click",function(e){e.stopPropagation();var open=!d.classList.contains("open");closeMenus(d);d.classList.toggle("open",open);b.setAttribute("aria-expanded",open?"true":"false");});
      d.querySelector(".dd-menu").addEventListener("click",function(e){e.stopPropagation();});});
    document.addEventListener("click",function(){closeMenus();});
    document.addEventListener("keydown",function(e){if(e.key==="Escape")closeMenus();});
    ["gen-custom-btn","gen-btn","gen-month-btn"].forEach(function(id){on(id,"click",function(){closeMenus();});});
    on("rec-ftoggle","click",function(){var f=document.querySelector("#rec-view .filters");var open=!f.classList.contains("open");f.classList.toggle("open",open);$("rec-ftoggle").setAttribute("aria-expanded",open?"true":"false");});
    on("rec-search","input",renderRecords);
    ["rec-student","rec-subject","rec-level","rec-status"].forEach(function(id){on(id,"change",renderRecords);});
    on("rec-clear","click",clearRecFilters);
    on("rec-selall","change",toggleSelectAllRecords);
    on("rec-delsel-btn","click",deleteSelectedRecords);
    on("seg-out","click",function(){setLedgerMode("out");});
    on("seg-rec","click",function(){setLedgerMode("rec");});
    var savedMode="out";
    try{savedMode=localStorage.getItem("tl_ledger_mode")||"out";}catch(e){}
    setLedgerMode(savedMode);
    load();
  }
  TL.requireAuth("ledger",init);
})();