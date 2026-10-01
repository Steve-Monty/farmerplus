const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
function setup(data){
 const nodes={'profile':{open:true},'profile-content':{innerHTML:''},'profile-tabs':{addEventListener(){}}};
 const context={document:{addEventListener(){}},profileData:{person:{id:'one'}},profileTab:'Notifications',ctx:{scope:'all'},scopePending:false,
  api:async()=>data,canWrite:()=>false,table:(h,r)=>h.join(' ')+r.flat().join(' '),
  esc:v=>String(v??'').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;'),
  num:String,time:v=>v==null?'Not recorded':String(v),empty:String,$:id=>nodes[id]};
 vm.createContext(context);vm.runInContext(fs.readFileSync(path.join(__dirname,'..','static','admin-profile.js'),'utf8'),context);
 vm.runInContext(fs.readFileSync(path.join(__dirname,'..','static','admin-community.js'),'utf8'),context);
 return {context,nodes};
}
test('push diagnostics escape device fields and distinguish accepted from delivery',async()=>{
 const {context,nodes}=setup({configured:false,devices:[{device:'<img src=x>',version:'4017',permission:'denied',updated:1,active:false}],
   deliveries:[{device:'one',state:'accepted',attempts:1,accepted:2,opened:null,read:null,error:null}]});
 await context.profileNotifications('one');
 assert.match(nodes['profile-content'].innerHTML,/&lt;img/);assert.doesNotMatch(nodes['profile-content'].innerHTML,/<img/);
 assert.match(nodes['profile-content'].innerHTML,/Firebase accepted/);
 assert.match(nodes['profile-content'].innerHTML,/not configured/);
 assert.doesNotMatch(nodes['profile-content'].innerHTML,/push-send-form/);
});
test('push response cannot paint after farmer or tenant changes',async()=>{
 const {context,nodes}=setup({});let resolve;
 context.api=()=>new Promise(r=>resolve=r);
 const request=context.profileNotifications('one');context.ctx.scope='another';
 resolve({configured:true,devices:[],deliveries:[]});await request;
 assert.equal(nodes['profile-content'].innerHTML,'');
});
