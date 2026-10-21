// Exams — manage assessments: add, edit, delete; upcoming (with countdown) vs past.
(function () {
  var userId=null, students=[], nameById={}, exams=[], editingId=null;
  var $=function(id){return document.getElementById(id);};
  function esc(s){return String(s==null?"":s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");}
  function pad(n){return (n<10?"0":"")+n;}
  function todayISO(){var d=new Date();return d.getFullYear()+"-"+pad(d.getMonth()+1)+"-"+pad(d.getDate());}
  function prettyDate(s){if(!s)return"—";var p=s.split("-");var mo=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];return (+p[2])+" "+mo[(+p[1])-1]+" "+p[0];}
  function daysAway(s){var now=new Date();now.setHours(0,0,0,0);return Math.round((new Date(s+"T00:00:00")-now)/86400000);}

  function studentOptions(){
    var act=students.filter(function(s){return s.active!==false;});
    $("m-student").innerHTML=act.length?act.map(function(s){return '<option value="'+s.id+'">'+esc(s.name)+"</option>";}).join(""):'<option value="">— add a student first —</option>';
  }

  function openModal(open, ex){
    $("modal").classList.toggle("on",open);
    $("m-msg").textContent="";$("m-msg").className="msg";
    if(!open)return;
    if(ex){
      editingId=ex.id;
      $("m-title").textContent="Edit exam";$("m-save").textContent="Save changes";
      $("m-student").value=ex.student_id;$("m-date").value=ex.exam_date||"";$("m-type").value=ex.assessment_type||"";
      $("m-subject").value=ex.subject||"";$("m-topics").value=ex.topics||"";$("m-remarks").value=ex.remarks||"";
      $("m-score").value=ex.score!=null?ex.score:"";$("m-maxscore").value=ex.max_score!=null?ex.max_score:"";
    }else{
      editingId=null;
      $("m-title").textContent="Add exam";$("m-save").textContent="Save exam";
      ["m-type","m-subject","m-topics","m-remarks","m-score","m-maxscore"].forEach(function(id){$(id).value="";});
      $("m-date").value="";
    }
  }

  async function save(){
    var msg=$("m-msg");
    var sid=$("m-student").value,date=$("m-date").value;
    if(!sid){msg.textContent="Pick a student.";msg.className="msg err";return;}
    if(!date){msg.textContent="Set an exam date.";msg.className="msg err";return;}
    var fields={student_id:sid,exam_date:date,
      assessment_type:$("m-type").value.trim()||null,
      subject:$("m-subject").value.trim()||null,
      topics:$("m-topics").value.trim()||null,score:$("m-score").value!==""?parseFloat($("m-score").value):null,max_score:$("m-maxscore").value!==""?parseFloat($("m-maxscore").value):null,
      remarks:$("m-remarks").value.trim()||null};
    $("m-save").disabled=true;
    var res=editingId
      ? await window.sb.from("exams").update(fields).eq("id",editingId)
      : await window.sb.from("exams").insert(Object.assign({tutor_id:userId},fields));
    $("m-save").disabled=false;
    if(res.error){msg.textContent=res.error.message;msg.className="msg err";return;}
    openModal(false);load();
  }

  async function del(id){
    if(!(await TL.confirm({title:"Delete this exam?",message:"Its date, topics and marks will be removed, and it drops off the progress chart.",confirmText:"Delete exam",danger:true})))return;
    var res=await window.sb.from("exams").delete().eq("id",id);
    if(res.error){TL.alert("Couldn't delete: "+res.error.message);return;}
    load();
  }

  var MO=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"], WD=["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
  function inLabel(d){return d===0?"Today":(d===1?"Tomorrow":"in "+d+" days");}
  function scoreOf(ex){return (ex.score!=null&&ex.max_score)?{t:ex.score+"/"+ex.max_score,p:Math.round(ex.score/ex.max_score*100)}:null;}
  function row(ex, upcoming){
    var dt=ex.exam_date?new Date(ex.exam_date+"T00:00:00"):null;
    var date=dt?'<b>'+dt.getDate()+'</b><small>'+MO[dt.getMonth()]+(dt.getFullYear()!==new Date().getFullYear()?" '"+String(dt.getFullYear()).slice(2):"")+'</small>':'<b>—</b>';
    var sub=[ex.assessment_type,ex.subject].filter(Boolean).join(" · ")||"Exam";
    var right;
    if(upcoming){var d=daysAway(ex.exam_date);right='<span class="ex-right'+(d<=14?' soon':'')+'">'+inLabel(d)+'</span>';}
    else{var sc=scoreOf(ex);right=sc?'<span class="ex-right score">'+esc(sc.t)+'<span class="pct">'+sc.p+'%</span></span>':'<span class="ex-right add">Add result</span>';}
    return '<button type="button" class="ex-row" id="ex-row-'+esc(String(ex.id))+'" data-ex="'+esc(String(ex.id))+'">'+
      '<span class="ex-date">'+date+'</span>'+
      '<span class="ex-main"><span class="ex-name">'+esc(nameById[ex.student_id]||"—")+'</span><span class="ex-sub">'+esc(sub)+(ex.topics?' · '+esc(ex.topics):'')+'</span></span>'+
      right+'<svg class="ex-chev" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="m9 18 6-6-6-6"/></svg></button>';
  }

  function openSheet(ex){
    if(!ex)return;
    var today=todayISO(), upcoming=ex.exam_date&&ex.exam_date>=today, sc=scoreOf(ex);
    $("xs-title").textContent=nameById[ex.student_id]||"Exam";
    $("xs-sub").textContent=[ex.assessment_type,ex.subject].filter(Boolean).join(" · ")||"Exam";
    var r=$("xs-right");
    if(upcoming){var d=daysAway(ex.exam_date);r.textContent=inLabel(d);r.className="owe-total"+(d<=14?" soon":" plain");r.style.fontSize="17px";}
    else{r.textContent=sc?sc.p+"%":"";r.className="owe-total plain";r.style.fontSize="";}
    var dt=ex.exam_date?new Date(ex.exam_date+"T00:00:00"):null;
    var items=[["Date",dt?WD[dt.getDay()]+" "+dt.getDate()+" "+MO[dt.getMonth()]+" "+dt.getFullYear():"—"],
      ["Topics",ex.topics?esc(ex.topics):"—"]];
    if(!upcoming||sc)items.push(["Result",sc?"<b>"+esc(sc.t)+"</b> ("+sc.p+"%)":'<span class="muted">Not added yet</span>']);
    if(ex.remarks)items.push(["Remarks",esc(ex.remarks)]);
    $("xs-body").innerHTML='<div class="rd-list">'+items.map(function(i){return '<div class="rd-row"><span class="rd-k">'+i[0]+'</span><span class="rd-v">'+i[1]+'</span></div>';}).join("")+'</div>';
    var needResult=!upcoming&&!sc;
    $("xs-acts").innerHTML=(needResult?'<button class="btn rd-primary" id="xs-result">Add result</button>':'')+
      '<button class="btn" id="xs-edit">Edit exam</button>'+
      '<a class="btn" href="student?id='+encodeURIComponent(ex.student_id)+'">Student profile</a>'+
      '<button class="btn rd-del" id="xs-del">Delete exam</button>';
    function edit(){closeSheet();openModal(true,ex);}
    $("xs-edit").onclick=edit; if($("xs-result"))$("xs-result").onclick=function(){edit();setTimeout(function(){$("m-score").focus();},50);};
    $("xs-del").onclick=function(){closeSheet();del(ex.id);};
    $("ex-sheet").classList.add("on");document.body.classList.add("sheet-lock");
  }
  function closeSheet(){$("ex-sheet").classList.remove("on");document.body.classList.remove("sheet-lock");}

  function highlightParam(){
    var m=location.search.match(/[?&]highlight=([^&]+)/);
    return m?decodeURIComponent(m[1]):null;
  }
  function highlightExam(){
    var id=highlightParam(); if(!id)return;
    var row=$("ex-row-"+id); if(!row)return;
    row.scrollIntoView({behavior:"smooth",block:"center"});
    row.classList.add("ex-hl");
    setTimeout(function(){row.classList.remove("ex-hl");},2600);
  }

  function wire(scope){
    function find(id){return exams.filter(function(e){return e.id===id;})[0];}
    scope.querySelectorAll("[data-ex]").forEach(function(b){b.addEventListener("click",function(){openSheet(find(b.dataset.ex));});});
  }

  async function load(){
    var st=await window.sb.from("students").select("id,name,active").order("name");
    students=st.data||[];nameById={};students.forEach(function(s){nameById[s.id]=s.name;});
    studentOptions();

    var res=await window.sb.from("exams").select("id,student_id,exam_date,assessment_type,subject,topics,remarks,score,max_score");
    if(res.error){$("x-count").textContent="Couldn't load exams: "+res.error.message;return;}
    exams=res.data||[];
    var today=todayISO();
    var up=exams.filter(function(e){return e.exam_date&&e.exam_date>=today;}).sort(function(a,b){return a.exam_date.localeCompare(b.exam_date);});
    var past=exams.filter(function(e){return !e.exam_date||e.exam_date<today;}).sort(function(a,b){return (b.exam_date||"").localeCompare(a.exam_date||"");});

    $("x-count").innerHTML=exams.length?'<b>'+up.length+'</b> coming up · '+exams.length+' in total':"No exams yet — add the first one.";


    $("up-list").innerHTML=up.length?up.map(function(e){return row(e,true);}).join(""):'<div class="ex-emp">No upcoming exams.</div>';
    wire($("up-list"));
    if(past.length){
      $("past-title").style.display="";$("past-list").style.display="";
      $("past-list").innerHTML=past.map(function(e){return row(e,false);}).join("");wire($("past-list"));
    }else{$("past-title").style.display="none";$("past-list").style.display="none";}

    highlightExam();
  }

  function init(user){
    userId=user.id;
    $("add-btn").addEventListener("click",function(){openModal(true,null);});
    $("m-cancel").addEventListener("click",function(){openModal(false);});
    $("modal").addEventListener("click",function(e){if(e.target===$("modal"))openModal(false);});
    $("m-save").addEventListener("click",save);
    $("xs-close").addEventListener("click",closeSheet);
    $("ex-sheet").addEventListener("click",function(e){if(e.target===$("ex-sheet"))closeSheet();});
    document.addEventListener("keydown",function(e){if(e.key==="Escape")closeSheet();});
    load();
  }
  TL.requireAuth("exams",init);
})();