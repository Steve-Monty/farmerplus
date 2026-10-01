/* Route state deliberately excludes farmer searches and exact map bounds. */
(function(root){
 'use strict';
 const filterKeys=['mapping','sync','country','kind','layer','mode','resolution','period','crop','farmStatus','accountType','location','basemap','overlay','overlayDate'];
 const defaults=()=>({filters:{},sort:'name',direction:'asc',page:1,visibleColumns:['identity','land','area','sync'],savedId:''});
 function encode(view,state){
  const p=new URLSearchParams();p.set('state','1');
  if(state.savedId)p.set('saved',state.savedId);
  for(const key of filterKeys)if(state.filters[key])p.set(key,state.filters[key]);
  if(state.sort!=='name')p.set('sort',state.sort);
  if(state.direction==='desc')p.set('direction','desc');
  if(state.page>1)p.set('page',String(state.page));
  p.set('columns',state.visibleColumns.join(','));
  return '#'+view+'?'+p;
 }
 function decode(hash){
  const [view='overview',query='']=hash.replace(/^#/,'').split('?'),p=new URLSearchParams(query),state=defaults();
  for(const key of filterKeys)if(p.has(key))state.filters[key]=p.get(key).slice(0,200);
  if(['name','farms','mappedHa','lastSync'].includes(p.get('sort')))state.sort=p.get('sort');
  if(p.get('direction')==='desc')state.direction='desc';
  const page=Number(p.get('page'));if(Number.isInteger(page)&&page>0&&page<=100000)state.page=page;
  if(p.has('columns'))state.visibleColumns=['identity',...p.get('columns').split(',').filter(c=>['land','area','sync'].includes(c))];
  if(/^[a-f0-9-]{36}$/.test(p.get('saved')||''))state.savedId=p.get('saved');
  return {view:view||'overview',explicit:!!query,state};
 }
 // Only the newest request may commit or report an error. Pending content must
 // be blocked by the caller until that request settles.
 function latestRequest(request,hooks){
  let sequence=0;
  return async function(input){
   const ticket=++sequence;hooks.pending(input);
   try{const result=await request(input);if(ticket===sequence)await hooks.commit(result,input);}
   catch(error){if(ticket===sequence)await hooks.fail(error,input);}
  };
 }
 const api={defaults,encode,decode,latestRequest};
 if(typeof module==='object'&&module.exports)module.exports=api;else root.AdminState=api;
})(typeof globalThis==='object'?globalThis:this);
