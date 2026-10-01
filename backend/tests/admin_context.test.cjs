const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const source=fs.readFileSync(require.resolve('../static/admin-context.js'),'utf8');
const pending=()=>{let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};};
function harness(api){
 const listeners={},nodes={},opened=[],rendered=[];
 const context={version:1,scopePending:false,ctx:{scope:'organisation-a'},sourceItems:[{id:'rainfall',enabled:false,revision:1}],api,
  document:{addEventListener:(name,callback)=>listeners[name]=callback},FormData:class{constructor(form){return form.values;}},
  $:id=>nodes[id]||(nodes[id]={textContent:'',close(){opened.push('closed');}}),openEditor:()=>opened.push('opened'),render:async()=>rendered.push(true),feedback:()=>opened.push('feedback')};
 vm.createContext(context);vm.runInContext(source,context);
 return {context,listeners,opened,rendered};
}
const feature={id:'farm-a',properties:{owner:'owner-a',name:'Test farm'}};
for(const name of ['openPublicRefresh','openFarmHistory'])test(name+' ignores a response after organisation navigation',async()=>{
 const wait=pending(),calls=[],h=harness(async(route,params)=>{calls.push({route,params});return wait.promise;});
 const running=h.context[name](feature);h.context.version++;h.context.ctx.scope='organisation-b';wait.resolve({sources:[],observations:[]});await running;
 assert.equal(calls[0].params.tenant,'organisation-a');assert.equal(h.opened.length,0);
});
function submit(h){const button={disabled:false,textContent:''},form={id:'atlas-public-form',values:[['provider','rainfall'],['owner','owner-a'],['farm','farm-a'],['period','2026-06']],querySelector:()=>button};return h.listeners.submit({target:form,preventDefault(){},stopImmediatePropagation(){}});}
test('source enable cannot trigger a fetch in a newly selected organisation',async()=>{
 const wait=pending(),calls=[],h=harness(async(route,params)=>{calls.push({route,params});return wait.promise;});
 const running=submit(h);h.context.version++;h.context.ctx.scope='organisation-b';wait.resolve({});await running;
 assert.equal(calls.length,1);assert.equal(calls[0].params.tenant,'organisation-a');assert.equal(h.opened.length,0);
});
test('in-flight refresh stays explicitly scoped and cannot overwrite the new view',async()=>{
 const wait=pending(),calls=[],h=harness(async(route,params)=>{calls.push({route,params});return wait.promise;});h.context.sourceItems[0].enabled=true;
 const running=submit(h);h.context.version++;h.context.ctx.scope='organisation-b';wait.resolve({added:1,duplicates:0});await running;
 assert.equal(calls[0].route,'sources/rainfall/refresh');assert.equal(calls[0].params.tenant,'organisation-a');assert.equal(h.opened.length,0);assert.equal(h.rendered.length,0);
});
