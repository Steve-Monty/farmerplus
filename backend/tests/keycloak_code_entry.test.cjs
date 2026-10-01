const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const source=fs.readFileSync('identity/keycloak/themes/farmerplus/login/resources/js/farmerplus.js','utf8');
function setup() {
  let focused, ready, group;
  const element=()=>({value:'',children:[],events:{},attributes:{},append(x){this.children.push(x)},setAttribute(k,v){this.attributes[k]=v},removeAttribute(k){delete this.attributes[k]},addEventListener(k,f){(this.events[k]??=[]).push(f)},fire(k,e={}){for(const f of this.events[k]??[])f(e)},focus(){focused=this},select(){},querySelectorAll(){return []}});
  const code=element();code.parentElement={after(x){group=x}};
  const form=element();form.id='kc-verify-email-code-form';
  const context={Date,setTimeout:f=>f(),addEventListener(){},sessionStorage:{removeItem(){}},document:{body:{dataset:{}},addEventListener:(k,f)=>ready=f,querySelector:s=>s==='form'?form:null,getElementById:id=>id==='verification-code'?code:null,createElement:element}};
  vm.runInNewContext(source,context);ready();
  return {code,form,digits:group.children,focused:()=>focused};
}
test('six individual digits advance and submit the original single code field',()=>{
  const p=setup();assert.equal(p.digits.length,6);
  p.digits.forEach((d,i)=>{d.value=String(i+1);d.fire('input');assert.equal(p.focused(),p.digits[Math.min(i+1,5)]);assert.equal(d.pattern,'[0-9]');assert.equal(d.required,true)});
  p.form.fire('submit');assert.equal(p.code.value,'123456');assert.equal(p.code.type,'hidden');assert.equal(p.code.parentElement.hidden,true);
});
test('paste and mobile autofill distribute a full code, including leading zero',()=>{
  const p=setup();let prevented=false;
  p.digits[2].fire('paste',{preventDefault(){prevented=true},clipboardData:{getData:()=> '01 23-45'}});
  assert.equal(prevented,true);assert.equal(p.code.value,'012345');assert.equal(p.focused(),p.digits[5]);
  p.digits[0].value='654321';p.digits[0].fire('input');assert.equal(p.code.value,'654321');
});
test('backspace, arrow navigation and invalid characters keep payload synchronized',()=>{
  const p=setup();p.digits[0].value='12';p.digits[0].fire('input');
  p.digits[2].fire('keydown',{key:'Backspace',preventDefault(){}});assert.equal(p.focused(),p.digits[1]);assert.equal(p.code.value,'1');
  p.digits[1].fire('keydown',{key:'ArrowLeft',preventDefault(){}});assert.equal(p.focused(),p.digits[0]);
  p.digits[0].value='abc';p.digits[0].fire('input');assert.equal(p.code.value,'');
});
