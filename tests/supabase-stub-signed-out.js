// Test double for the Supabase library: nobody signed in (landing, login, legal pages). Used by tests/smoke.py only.
(function(){
  var today=new Date(); function iso(d){return d.getFullYear()+"-"+String(d.getMonth()+1).padStart(2,"0")+"-"+String(d.getDate()).padStart(2,"0");}
  var day=iso(new Date(today.getFullYear(),today.getMonth(),today.getDate()+1));
  var DATA={
    students:[{id:"s1",name:"Qin Heng",active:true},{id:"s2",name:"Aisha",active:true},{id:"s3",name:"Lucas",active:true}],
    exams:[{id:"e1",student_id:"s1",exam_date:day,assessment_type:"WA3",subject:"Math"},
           {id:"e2",student_id:"s2",exam_date:day,assessment_type:"Prelim",subject:"Science"},
           {id:"e3",student_id:"s3",exam_date:day,assessment_type:"Prelim",subject:"NA Math P1"}]
  };
  function q(t){ var rows=DATA[t]||[]; var o={}; ["select","eq","neq","in","gte","lte","lt","gt","order","is","not","or","limit","range","match","filter","ilike"].forEach(function(m){o[m]=function(){return o;};});
    o.single=o.maybeSingle=function(){return Promise.resolve({data:rows[0]||{id:"u1"},error:null});};
    o.then=function(r,j){return Promise.resolve({data:rows,error:null}).then(r,j);}; ["update","insert","upsert","delete"].forEach(function(m){o[m]=function(){return o;};}); return o; }
  var user={id:"u1",email:"dummy@example.com",user_metadata:{}};
  window.supabase={createClient:function(){return {
    auth:{getSession:function(){return Promise.resolve({data:{session:null},error:null});},signUp:function(o){window.__signedUp=o;return Promise.resolve({data:{user:null,session:null},error:null});},
      getUser:function(){return Promise.resolve({data:{user:user},error:null});},
      onAuthStateChange:function(){return {data:{subscription:{unsubscribe:function(){}}}};},
      mfa:{getAuthenticatorAssuranceLevel:function(){return Promise.resolve({data:{currentLevel:"aal1",nextLevel:"aal1"},error:null});},listFactors:function(){return Promise.resolve({data:{totp:[]},error:null});}}},
    from:q, rpc:function(){return Promise.resolve({data:null,error:null});},
    storage:{from:function(){return {createSignedUrl:function(){return Promise.resolve({data:null});}};}}
  };}};
})();
