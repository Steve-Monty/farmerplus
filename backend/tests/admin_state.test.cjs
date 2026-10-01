const {test}=require('node:test');
const assert=require('node:assert/strict');
const state=require('../static/admin-state.js');

test('URL restores non-identifying filters, sorting, page, columns and layer',()=>{
 const input={...state.defaults(),filters:{mapping:'Unmapped',country:'South Africa',sync:'never',layer:'hex'},sort:'mappedHa',direction:'desc',page:3,visibleColumns:['identity','area']};
 const route=state.encode('atlas',input);
 assert.deepEqual(state.decode(route),{view:'atlas',explicit:true,state:input});
});
test('Names and exact coordinates never appear in a route',()=>{
 const input={...state.defaults(),filters:{q:'Naledi Mokoena',bbox:'28.031,-26.014,28.042,-26.009'},savedId:'00000000-0000-0000-0000-000000000001'};
 const route=state.encode('farmers',input);
 assert(!route.includes('Naledi'));assert(!route.includes('28.031'));assert.equal(state.decode(route).state.savedId,input.savedId);
 assert.deepEqual(state.decode(route).state.filters,{});
});
test('Malformed URL values are bounded to valid defaults',()=>{
 const decoded=state.decode('#farmers?sort=password&direction=bad&page=-2&columns=secret,area&saved=not-an-id');
 assert.equal(decoded.state.sort,'name');assert.equal(decoded.state.page,1);assert.deepEqual(decoded.state.visibleColumns,['identity','area']);assert.equal(decoded.state.savedId,'');
});
test('Failed scope switch restores committed context and selector',async()=>{
 let committed='old',selector='new',content='old data',message='';
 const change=state.latestRequest(async()=>{throw Error('Access revoked');},{pending(){content='Loading';},commit(next){committed=selector=next;content=next;},fail(error){selector=committed;content=committed+' data';message=error.message;}});
 await change('new');assert.equal(committed,'old');assert.equal(selector,'old');assert.equal(content,'old data');assert.equal(message,'Access revoked');
});
test('Rapid organisation switches discard older success and older failures',async()=>{
 const requests=new Map(),commits=[],errors=[];
 const change=state.latestRequest(id=>new Promise((resolve,reject)=>requests.set(id,{resolve,reject})),{pending(){},commit(value){commits.push(value);},fail(e){errors.push(e.message);}});
 const first=change('slow'),second=change('fast');requests.get('fast').resolve('fast');await second;requests.get('slow').resolve('slow');await first;
 assert.deepEqual(commits,['fast']);
 const third=change('stale-error'),fourth=change('latest');requests.get('latest').resolve('latest');await fourth;requests.get('stale-error').reject(Error('stale'));await third;
 assert.deepEqual(commits,['fast','latest']);assert.deepEqual(errors,[]);
});
