// Test double for the Supabase library: a signed-in tutor with made-up students, lessons, slots and exams.
// Used by tests/smoke.py only — never loaded by the real site. All names and numbers are fictional.
(function(){
  function pad(n){return String(n).padStart(2,"0");}
  function iso(d){return d.getFullYear()+"-"+pad(d.getMonth()+1)+"-"+pad(d.getDate());}
  var today=new Date(); today.setHours(0,0,0,0);
  var dow=(today.getDay()+6)%7; var mon=new Date(today); mon.setDate(today.getDate()-dow);
  function wd(i,off){var d=new Date(mon); d.setDate(mon.getDate()+i+(off||0)*7); return iso(d);}
  var U="u1";
  var students=[
    {id:"s1",tutor_id:U,name:"Wei Lin",level:"Sec 3 G3",active:true,contact:"91234567",recipient_name:"Mrs Lim",location:"Tampines"},
    {id:"s2",tutor_id:U,name:"Jun Jie",level:"P6",active:true,contact:"98765432",recipient_name:"Mr Ng",location:"Bedok"},
    {id:"s3",tutor_id:U,name:"Siti",level:"Sec 2 G2",active:true,contact:"96543210",recipient_name:"Mdm Rahim",location:"Pasir Ris"},
    {id:"s4",tutor_id:U,name:"Daniel",level:"JC1",active:true,contact:"93456789",recipient_name:"Mrs Koh",location:"Online"},
    {id:"s5",tutor_id:U,name:"Kai",level:"P5",active:true,contact:"98765432",recipient_name:"Mr Ng",location:"Bedok"}
  ];
  var slots=[
    {id:"r1",tutor_id:U,student_id:"s1",weekday:0,start_time:"16:00:00",end_time:"17:30:00",subject:"A-Math",level:"Sec 3 G3",rate:70,split:1,active:true},
    {id:"r2",tutor_id:U,student_id:"s2",weekday:1,start_time:"17:00:00",end_time:"18:30:00",subject:"Math",level:"P6",rate:60,split:1,active:true},
    {id:"r3",tutor_id:U,student_id:"s3",weekday:2,start_time:"19:00:00",end_time:"20:30:00",subject:"Science",level:"Sec 2 G2",rate:65,split:1,active:true},
    {id:"r4",tutor_id:U,student_id:"s4",weekday:3,start_time:"18:00:00",end_time:"20:00:00",subject:"H2 Computing",level:"JC1",rate:90,split:1,active:true},
    {id:"r5",tutor_id:U,student_id:"s5",weekday:5,start_time:"10:00:00",end_time:"11:30:00",subject:"Math",level:"P5",rate:55,split:1,active:true},
    {id:"r6",tutor_id:U,student_id:"s1",weekday:5,start_time:"14:00:00",end_time:"15:30:00",subject:"E-Math",level:"Sec 3 G3",rate:70,split:1,active:true}
  ];
  var lessons=[], n=0;
  var SLOT={"s1|16:00":"r1","s2|17:00":"r2","s3|19:00":"r3","s4|18:00":"r4","s5|10:00":"r5","s1|14:00":"r6"};
  function L(s,w,st,en,subj,rate,paid,status,extra){ var dur=((+en.slice(0,2))*60+ +en.slice(3,5)-((+st.slice(0,2))*60+ +st.slice(3,5)))/60;
    lessons.push(Object.assign({id:"l"+(++n),tutor_id:U,student_id:s,lesson_date:w,start_time:st,end_time:en,subject:subj,level:students.find(x=>x.id===s).level,rate:rate,split:1,amount:Math.round(rate*dur*100)/100,paid:paid,paid_date:paid?w:null,status:status||"done",postponed:false,one_off:false,slot_id:SLOT[s+"|"+st]||null,slot_date:w,compensation:null,topics:null,homework:null,remarks:null},extra||{})); }
  // last 3 weeks + this week
  for(var k=-3;k<=0;k++){
    L("s1",wd(0,k),"16:00","17:30","A-Math",70,k<-1,k<0||dow>0?"done":"scheduled",{topics:"Quadratic functions",homework:"Ex 3B Q1–8"});
    L("s2",wd(1,k),"17:00","18:30","Math",60,k<=-1,k<0||dow>1?"done":"scheduled",{topics:"Ratio & percentage",homework:"TYS 2024 P1"});
    L("s3",wd(2,k),"19:00","20:30","Science",65,k<=-2,k<0||dow>2?"done":"scheduled",{topics:"Ray diagrams"});
    L("s4",wd(3,k),"18:00","20:00","H2 Computing",90,k<=-1,k<0||dow>3?"done":"scheduled",{topics:"Recursion & sorting"});
    L("s5",wd(5,k),"10:00","11:30","Math",55,k<=-1,k<0||dow>5?"done":"scheduled");
    L("s1",wd(5,k),"14:00","15:30","E-Math",70,k<-1,k<0||dow>5?"done":"scheduled");
  }
  (function(){ var st="16:30",en="18:00"; slots.push({id:"r7",tutor_id:U,student_id:"s3",weekday:dow,start_time:st+":00",end_time:en+":00",subject:"Math",level:"Sec 2 G2",rate:65,split:1,active:true}); SLOT["s3|"+st]="r7";
    for(var k=-3;k<=0;k++) L("s3",wd(dow,k),st,en,"Math",65,k<=-1,k<0?"done":"scheduled",{topics:"Algebraic fractions",homework:"Worksheet 5"}); })();
  lessons.filter(function(l){return l.student_id==="s5";}).forEach(function(l){ l.topics="Fractions & decimals"; l.homework="Practice paper 2 Q1–10"; });
  students.push({id:"s_old",tutor_id:U,name:"Farhan",level:"Sec 4 G2",active:false,contact:"90001111",recipient_name:"Mr Yusof",end_date:"2023-11-30"});
  lessons.push({id:"l_old",tutor_id:U,student_id:"s_old",lesson_date:"2023-11-20",start_time:"16:00",end_time:"17:30",subject:"Math",level:"Sec 4 G2",rate:60,split:1,amount:90,paid:true,paid_date:"2023-11-20",status:"done",postponed:false,one_off:false,slot_id:null,slot_date:"2023-11-20",compensation:null});
  var exams=[
    {id:"e1",tutor_id:U,student_id:"s2",exam_date:wd(4,1),assessment_type:"Prelim",subject:"Math",topics:"Whole syllabus"},
    {id:"e2",tutor_id:U,student_id:"s1",exam_date:wd(2,2),assessment_type:"WA3",subject:"A-Math",topics:"Quadratics, Indices"},
    {id:"e3",tutor_id:U,student_id:"s3",exam_date:wd(2,2),assessment_type:"WA3",subject:"Science"}
  ];
  var profiles=[{id:U,full_name:"Mei",business_name:"Demo Tuition",paynow_type:"mobile",paynow_id:"91234567",invoice_prefix:"INV",fy_start_month:1,welcomed_at:"2026-01-01",reminder_checked_at:"2026-01-01",getpaid_dismissed_at:"2026-01-01",seen_tips:["all"],setup_done_at:"2026-01-01"}];
  var invoices=[{id:"i1",tutor_id:U,student_id:"s1",invoice_no:"INV-0007",issued_date:wd(0,-1),total:210,status:"issued",paid_date:null,data:{lesson_ids:["l1","l6"]}}];
  var DATA={students:students,recurring_slots:slots,lessons:lessons,exams:exams,profiles:profiles,invoices:invoices,material_folders:[],materials:[],gcal_links:[]};
  function q(t){ var rows=(DATA[t]||[]).slice(); var o={};
    var F={eq:function(k,v){rows=rows.filter(function(r){return r[k]==v;});},neq:function(k,v){rows=rows.filter(function(r){return r[k]!=v;});},
      gte:function(k,v){rows=rows.filter(function(r){return r[k]>=v;});},lte:function(k,v){rows=rows.filter(function(r){return r[k]<=v;});},
      gt:function(k,v){rows=rows.filter(function(r){return r[k]>v;});},lt:function(k,v){rows=rows.filter(function(r){return r[k]<v;});},
      in:function(k,v){rows=rows.filter(function(r){return v.indexOf(r[k])>-1;});},
      is:function(k,v){rows=rows.filter(function(r){return r[k]==v;});}};
    Object.keys(F).forEach(function(m){o[m]=function(k,v){F[m](k,v);return o;};});
    ["select","order","not","or","limit","range","match","filter","ilike","contains"].forEach(function(m){o[m]=function(){return o;};});
    o.single=o.maybeSingle=function(){return Promise.resolve({data:rows[0]||null,error:null});};
    o.then=function(r,j){return Promise.resolve({data:rows,error:null,count:rows.length}).then(r,j);};
    ["update","insert","upsert","delete"].forEach(function(m){o[m]=function(){return o;};}); return o; }
  var user={id:U,email:"demo@tutordeck.com.sg",user_metadata:{full_name:"Mei"}};
  window.supabase={createClient:function(){return {
    auth:{getSession:function(){return Promise.resolve({data:{session:{user:user,access_token:"x"}},error:null});},
      getUser:function(){return Promise.resolve({data:{user:user},error:null});},
      onAuthStateChange:function(){return {data:{subscription:{unsubscribe:function(){}}}};},
      mfa:{getAuthenticatorAssuranceLevel:function(){return Promise.resolve({data:{currentLevel:"aal1",nextLevel:"aal1"},error:null});},listFactors:function(){return Promise.resolve({data:{totp:[]},error:null});}}},
    from:q, rpc:function(){return Promise.resolve({data:null,error:null});}, functions:{invoke:function(){return Promise.resolve({data:null,error:null});}},
    storage:{from:function(){return {createSignedUrl:function(){return Promise.resolve({data:null});},list:function(){return Promise.resolve({data:[],error:null});}};}}
  };}};
})();
