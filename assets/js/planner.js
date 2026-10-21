// Weekly planner — Mon–Sun grid from recurring_slots; add, EDIT, remove slots.
(function () {
  function fillSubjects(list){var el=document.getElementById("dl-subject");if(!el)return;var u=[];(list||[]).forEach(function(s){s=(s||"").trim();if(s&&u.indexOf(s)<0)u.push(s);});el.innerHTML=u.sort().map(function(s){return "<option value=\""+s.replace(/"/g,"&quot;")+"\">";}).join("");}
  var DAYS=["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"];
  var SHORT=["Mon","Tue","Wed","Thu","Fri","Sat","Sun"];
  var userId=null, students=[], allStudents=[], allSlots=[], editingId=null, hhById={};
  var $=function(id){return document.getElementById(id);};
  function esc(s){return String(s==null?"":s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");}
  function hhmm(t){return t?t.slice(0,5):"";}
  function nameOf(id){for(var i=0;i<allStudents.length;i++)if(allStudents[i].id===id)return allStudents[i].name;return "—";}
  // Household key = normalised phone (matches ledger.js/calendar.js): same number → same household.
  function hhKey(c){var d=String(c||"").replace(/\D/g,"");if(d.length===10&&d.slice(0,2)==="65")d=d.slice(2);return d||null;}

  function studentOptions(){
    $("m-student").innerHTML=students.length?students.map(function(s){return '<option value="'+s.id+'">'+esc(s.name)+"</option>";}).join(""):'<option value="">— no students yet —</option>';
  }
  function clearForm(){
    $("m-subject").value="";$("m-level").value="";$("m-start").value="";$("m-end").value="";$("m-rate").value="";$("m-split").value="1";splitHint();
    $("m-day").value="0";if(students.length)$("m-student").value=students[0].id;
  }

  // Live price under the rate: "1.5 hours × S$50 = S$75 per lesson" (÷ students for a group).
  function pricePreview(){
    var el=$("m-price");if(!el)return;
    var rate=parseFloat($("m-rate").value),sp=Math.max(1,parseInt($("m-split").value,10)||1),
        s=$("m-start").value,e=$("m-end").value;
    if(!(rate>=0)||!s||!e||e<=s){el.textContent="";return;}
    var h=TL.hoursBetween(s,e), hTxt=(Math.round(h*100)/100)+" hour"+(h===1?"":"s"), total=TL.amount(rate,s,e);
    el.textContent=hTxt+" \u00d7 "+TL.sgd(rate)+" = "+TL.sgd(total)+" per lesson"+
      (sp>1?" \u00b7 "+TL.sgd(Math.round(total/sp*100)/100)+" each for "+sp+" students":"");
  }
  function splitHint(){
    pricePreview();
    var el=$("m-splithint");if(!el)return;
    var rate=parseFloat($("m-rate").value),sp=Math.max(1,parseInt($("m-split").value,10)||1),
        s=$("m-start").value,e=$("m-end").value;
    if(!(rate>=0)||sp<2){el.textContent="";return;}
    if(s&&e&&e>s){
      var each=Math.round(TL.amount(rate,s,e)/sp*100)/100;
      el.textContent="Each student pays "+TL.sgd(each)+" per lesson (rate ÷ "+sp+").";
    } else {
      el.textContent="Each student pays "+TL.sgd(Math.round(rate/sp*100)/100)+"/hr (rate ÷ "+sp+").";
    }
  }

  function planPrefill(){
    if(editingId)return;                 // don't overwrite when editing an existing slot
    var sid=$("m-student").value;
    var slot=allSlots.find(function(x){return x.student_id===sid;});
    if(!slot)return;                     // no existing slot to copy from
    $("m-rate").value=slot.rate!=null?slot.rate:"";
    $("m-split").value=slot.split||1;
    if(!$("m-subject").value)$("m-subject").value=slot.subject||"";
    if(!$("m-level").value)$("m-level").value=slot.level||"";
    splitHint();
  }

  function openModal(open, slot){
    $("modal").classList.toggle("on",open);
    $("m-msg").textContent="";$("m-msg").className="msg";
    if(!open)return;
    if(slot){
      editingId=slot.id;
      $("m-title").textContent="Edit slot";$("m-save").textContent="Save changes";
      if($("m-remove")) $("m-remove").style.display="";
      $("m-student").value=slot.student_id;$("m-day").value=slot.weekday;
      $("m-subject").value=slot.subject||"";$("m-level").value=slot.level||"";$("m-start").value=hhmm(slot.start_time);
      $("m-end").value=hhmm(slot.end_time);$("m-rate").value=slot.rate;$("m-split").value=slot.split||1;splitHint();
    }else{
      editingId=null;clearForm();
      $("m-title").textContent="Add weekly slot";$("m-save").textContent="Save slot";
      if($("m-remove")) $("m-remove").style.display="none";
    }
    if(!students.length){$("m-msg").textContent="Add a student first (Students tab).";$("m-msg").className="msg err";}
  }

  function render(){
    var byDay=[[],[],[],[],[],[],[]];
    allSlots.forEach(function(s){if(s.weekday>=0&&s.weekday<=6)byDay[s.weekday].push(s);});
    byDay.forEach(function(a){a.sort(function(x,y){return (x.start_time||"").localeCompare(y.start_time||"");});});
    var weekTotal=0;
    $("week").innerHTML=byDay.map(function(arr,d){
      var dayTotal=0;
      // A clash = two slots with different start times whose ranges overlap, for
      // different households. Same start time is an intentional split (grouped
      // below, never a clash); same household back-to-back is assumed intentional too.
      var clash={};
      for(var i=0;i<arr.length;i++){
        for(var j=i+1;j<arr.length;j++){
          var a=arr[i],b=arr[j];
          if(a.start_time===b.start_time)continue;
          if(!(a.start_time<b.end_time&&b.start_time<a.end_time))continue;
          var ha=hhById[a.student_id],hb=hhById[b.student_id];
          if(ha&&hb&&ha===hb)continue;
          clash[a.id]=1;clash[b.id]=1;
        }
      }
      function warnBadge(s){ return clash[s.id]?' <span class="clash-badge" title="Overlaps another lesson">⚠</span>':""; }
      function slotHTML(s){
        var sp=s.split||1;
        var cost=Math.round(TL.amount(s.rate,hhmm(s.start_time),hhmm(s.end_time))/sp*100)/100;dayTotal+=cost;
        return '<div class="slot'+(clash[s.id]?" clash":"")+'" data-edit="'+s.id+'">'+
          '<div class="t">'+hhmm(s.start_time)+"–"+hhmm(s.end_time)+warnBadge(s)+'</div>'+
          (s.subject||s.level?'<div class="subj">'+esc([s.subject,s.level].filter(Boolean).join(" · "))+'</div>':"")+
          '<div class="s">'+esc(nameOf(s.student_id))+'</div>'+
          '<div class="c">'+TL.sgd(cost)+(sp>1?' <span class="muted" style="font-weight:400">(÷'+sp+')</span>':'')+'</div></div>';
      }
      // Same-time slots (e.g. two students split one lesson) share one time header
      // and stack full-width below it, instead of squeezing side by side.
      function groupItemHTML(s){
        var sp=s.split||1;
        var cost=Math.round(TL.amount(s.rate,hhmm(s.start_time),hhmm(s.end_time))/sp*100)/100;dayTotal+=cost;
        return '<div class="sg-item'+(clash[s.id]?" clash":"")+'" data-edit="'+s.id+'">'+
          (s.subject||s.level?'<div class="subj">'+esc([s.subject,s.level].filter(Boolean).join(" · "))+'</div>':"")+
          '<div class="s">'+esc(nameOf(s.student_id))+''+warnBadge(s)+'</div>'+
          '<div class="c">'+TL.sgd(cost)+(sp>1?' <span class="muted" style="font-weight:400">(÷'+sp+')</span>':'')+'</div></div>';
      }
      function groupHTML(g){
        var t=hhmm(g.items[0].start_time)+"–"+hhmm(g.items[0].end_time);
        return '<div class="slot slot-group"><div class="t">'+t+'</div>'+g.items.map(groupItemHTML).join("")+'</div>';
      }
      var inner;
      if(!arr.length){ inner=''; }
      else {
        // group consecutive slots that start at the same time (a split lesson)
        var groups=[],cur=null;
        arr.forEach(function(s){
          if(cur&&cur.key===s.start_time){cur.items.push(s);}
          else {cur={key:s.start_time,items:[s]};groups.push(cur);}
        });
        inner=groups.map(function(g){
          return g.items.length>1?groupHTML(g):slotHTML(g.items[0]);
        }).join("");
      }
      weekTotal+=dayTotal;
      return '<div class="day'+(arr.length?'':' dempty')+'"><h3 class="'+(arr.length?"has":"")+'"><span>'+SHORT[d]+'</span>'+
        '<span class="dtot">'+(dayTotal?TL.sgd(dayTotal):"No slots")+'</span></h3><div class="slots">'+inner+'</div></div>';
    }).join("");
    $("p-total").innerHTML=allSlots.length?'<span class="wt-k">Every week</span><b>'+TL.sgd(weekTotal)+'</b><span class="wt-n">'+allSlots.length+' slot'+(allSlots.length===1?'':'s')+'</span>':"No recurring slots yet — add your first.";

    $("week").querySelectorAll("[data-del]").forEach(function(b){b.addEventListener("click",function(e){e.stopPropagation();removeSlot(b.dataset.del);});});
    $("week").querySelectorAll("[data-edit]").forEach(function(el){el.addEventListener("click",function(){
      var s=allSlots.find(function(x){return x.id===el.dataset.edit;});if(s)openModal(true,s);});});
  }

  async function load(){
    var st=await window.sb.from("students").select("id,name,active,contact,end_date").order("name");
    if(!st.error){
      allStudents=st.data||[];students=allStudents.filter(function(s){return s.active!==false && !TL.isEnded(s.end_date);});studentOptions();
      hhById={};allStudents.forEach(function(s){hhById[s.id]=hhKey(s.contact);});
    }
    var res=await window.sb.from("recurring_slots").select("id,student_id,weekday,start_time,end_time,subject,level,rate,split").eq("active",true);
    if(res.error){$("p-total").textContent="Couldn't load schedule: "+res.error.message;return;}
    allSlots=res.data||[];
    // Only show slots for active students — a discontinued student (or one whose scheduled
    // end date has passed) drops off the planner.
    if(allStudents.length){
      var actIds={}; allStudents.forEach(function(s){ if(s.active!==false && !TL.isEnded(s.end_date)) actIds[s.id]=1; });
      allSlots=allSlots.filter(function(s){ return actIds[s.student_id]; });
    }
    fillSubjects(allSlots.map(function(s){return s.subject;}));render();
    guideStart();
  }

  async function removeSlot(id){
    // Deleting a slot is safe now: each lesson carries its own one_off flag, so even though the DB
    // nulls slot_id on its past lessons ("on delete set null"), they keep the correct recurring/one-off
    // label and all their other data. The slot is just a template — binning it loses no lesson history.
    if(!(await TL.confirm({title:"Remove this weekly slot?",
      message:"It stops appearing on the calendar from now on. Lessons you\u2019ve already logged stay on the calendar and in your records.",
      confirmText:"Remove slot", danger:true})))return;
    var res=await window.sb.from("recurring_slots").delete().eq("id",id);
    if(res.error){TL.alert("Couldn't remove: "+res.error.message);return;}
    openModal(false);load();
  }

  async function save(){
    var msg=$("m-msg");
    var sid=$("m-student").value,start=$("m-start").value,end=$("m-end").value,rate=parseFloat($("m-rate").value);
    if(!sid){msg.textContent="Pick a student.";msg.className="msg err";return;}
    if(!start||!end){msg.textContent="Set a start and end time.";msg.className="msg err";return;}
    if(end<=start){msg.textContent="End time must be after start.";msg.className="msg err";return;}
    if(!(rate>=0)){msg.textContent="Enter an hourly rate.";msg.className="msg err";return;}
    var payload={tutor_id:userId,student_id:sid,weekday:parseInt($("m-day").value,10),
      start_time:start,end_time:end,subject:$("m-subject").value.trim()||null,level:$("m-level").value.trim()||null,rate:rate,split:Math.max(1,parseInt($("m-split").value,10)||1)};
    $("m-save").disabled=true;
    var res=editingId
      ? await window.sb.from("recurring_slots").update(payload).eq("id",editingId)
      : await window.sb.from("recurring_slots").insert(payload);
    $("m-save").disabled=false;
    if(res.error){msg.textContent=res.error.message;msg.className="msg err";return;}
    var wasNew=!editingId;
    openModal(false);load();
    if(wasNew && TL.guide && TL.guide.on){
      var hint=document.querySelector("#modal .tg-inform"); if(hint) hint.remove();
      TL.guide.card({step:3, done:"\u2713 Weekly lesson saved",
        title:"Confirm this week\u2019s lessons",
        text:"Your weekly lessons show on the calendar as Not logged. One tap confirms them, so you can track and bill them.",
        href:"calendar?guide=1", cta:"Open calendar"});
    }
  }

  // First-run guide, step 2: open Add slot with the student from step 1 already picked.
  var guided=false;
  function guideStart(){
    if(guided||!(TL.guide&&TL.guide.on))return; guided=true;
    var want=(location.search.match(/[?&]student=([^&]+)/)||[])[1];
    var st=students.filter(function(x){return String(x.id)===decodeURIComponent(want||"");})[0]||(students.length===1?students[0]:null);
    if(!students.length){
      TL.guide.card({step:1, title:"Add a student first", text:"Your weekly lessons belong to a student.", href:"students?guide=1", cta:"Add a student"});
      return;
    }
    TL.guide.card({step:2, title:"Set "+(st?esc(st.name)+"\u2019s":"the")+" weekly lesson time",
      text:"Pick the day, time and hourly rate. TutorDeck repeats it every week."});
    openModal(true,null);
    TL.guide.formHint($("m-title"), "Step 2 of 3 \u00b7 Pick the day, time and hourly rate. It repeats every week.");
    if(st){ $("m-student").value=st.id; planPrefill(); }
  }

  function init(user){
    userId=user.id;
    $("add-btn").addEventListener("click",function(){openModal(true,null);});
    $("m-cancel").addEventListener("click",function(){openModal(false);});
    $("modal").addEventListener("click",function(e){if(e.target===$("modal"))openModal(false);});
    $("m-save").addEventListener("click",save);
    if($("m-remove")) $("m-remove").addEventListener("click",function(){ if(editingId) removeSlot(editingId); });
    $("m-student").addEventListener("change",planPrefill);
    ["m-rate","m-split","m-start","m-end"].forEach(function(id){var el=$(id);if(el){el.addEventListener("input",splitHint);el.addEventListener("change",splitHint);}});
    load();
  }
  TL.requireAuth("planner",init);
})();