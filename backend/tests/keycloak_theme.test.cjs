const {test}=require('node:test');
const assert=require('node:assert/strict');
const vm=require('node:vm');
const fs=require('node:fs');
const path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../identity/keycloak/themes/farmerplus/login/resources/js/farmerplus.js'),'utf8');
function page({draft=null,verify=false}={}) {
  const values={email:{value:'farmer@example.test'},firstName:{value:'Test'},lastName:{value:'Farmer'},password:{value:'secret-password'},'password-confirm':{value:'secret-password'}};
  const events={};let stored=draft===null?null:JSON.stringify(draft);
  const form={id:'kc-register-form',elements:{namedItem:n=>values[n]},append(){},setAttribute(){},removeAttribute(){},querySelectorAll:()=>[],addEventListener:(n,f)=>events[n]=f};
  const context={Date,setTimeout:f=>f(),addEventListener(){},sessionStorage:{getItem:()=>stored,setItem:(k,v)=>stored=v,removeItem:()=>stored=null},document:{body:{dataset:{pageId:verify?'login-login-verify-email':'login-register'}},addEventListener:(n,f)=>events[n]=f,querySelector:s=>s==='form'&&!verify?form:null,getElementById:()=>null,createElement:()=>({setAttribute(){}})}};
  vm.runInNewContext(source,context);
  return {values,events,load:()=>events.DOMContentLoaded(),stored:()=>stored};
}
test('registration draft retains only non-password fields',()=>{
  const p=page();p.load();p.events.submit();const saved=JSON.parse(p.stored());
  assert.equal(saved.email,'farmer@example.test');assert.equal(saved.firstName,'Test');
  assert.deepEqual(Object.keys(saved).sort(),['email','firstName','lastName','time']);
  assert.ok(!p.stored().includes('secret-password'));
});
test('expired form restores names and email without replacing passwords or server values',()=>{
  const p=page({draft:{time:Date.now(),email:'saved@example.test',firstName:'Saved',lastName:'Name',password:'must-not-restore'}});
  p.values.email.value='';p.values.lastName.value='';p.values.password.value='';p.load();
  assert.equal(p.values.email.value,'saved@example.test');assert.equal(p.values.lastName.value,'Name');
  assert.equal(p.values.firstName.value,'Test');assert.equal(p.values.password.value,'');
});
test('stale drafts are removed after 30 minutes',()=>{
  const p=page({draft:{time:Date.now()-1800001,email:'old@example.test'}});p.load();assert.equal(p.stored(),null);
});
test('actual Keycloak verification page clears the non-password draft',()=>{
  const p=page({verify:true,draft:{time:Date.now(),email:'saved@example.test'}});p.load();assert.equal(p.stored(),null);
});
