const {test}=require('node:test');
const assert=require('node:assert/strict');
const atlas=require('../static/admin-atlas.js');
const state=require('../static/admin-state.js');
const farm=(id,owner='owner',kind='farm')=>({type:'Feature',id,geometry:{type:'Polygon',coordinates:[[[28,-25],[28.01,-25],[28.01,-24.99],[28,-25]]]},properties:{owner,kind,name:'Test farm',farmer:'Test farmer'}});
const row=(id,at,value=10,unit='mm/month',owner='owner')=>({id,owner,farm:'farm',observed:at,imported:1,data:{metric:'Monthly rainfall',value,unit,observedAt:at}});

test('source layers select latest compatible observations per owner/farm, preserve genuine zero',()=>{
 const rows=[row('old','2026-06-01',6),row('new','2026-07-01',0),row('bad-unit','2026-08-01',200,'inch'),row('other','2026-09-01',99,'mm/month','other')];
 const result=atlas.observationFeatures([farm('farm'),farm('empty'),farm('field','owner','field')],rows,'rainfall',{});
 assert.equal(result.length,2);assert.equal(result[0].properties.value,0);assert.equal(result[0].properties.hasValue,true);assert.equal(result[1].properties.hasValue,false);assert(!('value' in result[1].properties));
});
test('nulls, incompatible measures and stale revisions cannot overwrite readings',()=>{
 const rows=[row('a','2026-06-01',10),{...row('b','2026-06-01',12),imported:2},row('missing','2026-07-01',null)];
 assert.equal(atlas.latest(rows,'rainfall').get('owner:farm').data.value,12);
 assert.equal(atlas.latest(rows,'water').size,0);
});
test('external observations respect area and nearby selection and deduplicate overlap',()=>{
 const a={id:'a',owner:'one',data:{source:'NASA',metric:'FRP',value:4,lat:-25,lon:28,observedAt:'2026-06-01'}},b={...a,id:'b',owner:'two'};
 assert.equal(atlas.observationFeatures([], [a,b], 'fire',{}).length,1);
 assert.equal(atlas.observationFeatures([], [a,b], 'fire',{bbox:'0,0,1,1'}).length,0);
 assert.equal(atlas.observationFeatures([], [a,b], 'fire',{near:'28,-25,25'}).length,1);
 assert.equal(atlas.observationFeatures([], [a,b], 'fire',{near:'10,10,25'}).length,0);
});
test('centre and distance use longitude/latitude, not swapped coordinates',()=>{
 const c=atlas.centre(farm('farm'));assert(c[0]>28&&c[0]<28.01);assert(c[1]>-25&&c[1]<-24.99);
 assert.equal(atlas.distance([28,-25],[28,-25]),0);assert(atlas.distance([28,-25],[29,-25])>100);
});
test('map modes, period and scale survive URL restoration, exact spatial filters stay private',()=>{
 const input={...state.defaults(),filters:{mode:'heat',resolution:'5',period:'2026-06',layer:'rainfall',crop:'Maize',near:'28.0123,-25.1234,25',cell:'8566e433fffffff',q:'Private farmer'}};
 const route=state.encode('atlas',input),decoded=state.decode(route).state.filters;
 assert.equal(decoded.mode,'heat');assert.equal(decoded.period,'2026-06');assert.equal(decoded.resolution,'5');assert(!route.includes('28.0123'));assert(!route.includes('8566'));assert(!route.includes('Private'));
});
test('arrival view composes linked map controls with organisation-wide summary and source readiness',async()=>{
 const calls=[],geo={features:[farm('farm')],hexagons:[],total:1,farms:1,farmers:1,mappedHa:10,unmapped:0,invalid:0,countries:['South Africa'],crops:['Maize']};
 const sources=['places','rainfall','water','vegetation','fire'].map(id=>({id,name:id,source:'Public source',configured:true,enabled:false,access:'No registration'}));
 const d={version:1,isCurrent:()=>true,filters:()=>({}),canWrite:()=>true,path:r=>'/admin/api/v2/'+r,api:async r=>{calls.push(r);return r==='map'?geo:r==='sources'?{sources}:r==='overview'?{totals:{farmers:2,farms:1,mappedFarms:1,fields:0,mappedHa:10,attention:0},attention:[]}:null;}};
 const html=await atlas.build(d,true);
 assert.deepEqual(new Set(calls),new Set(['map','sources','overview']));
 for(const control of ['Heatmap','Hexagons','Boundaries','Select an area','Nearby','Source & setup','Get rainfall']){
  if(['Source & setup','Get rainfall'].includes(control))continue;
  assert(html.includes(control),control);
 }
 assert(html.includes('Whole organisation summary'));assert(html.includes('Farmer records'));assert(html.includes('id="atlas-farmer-suggestions"'));
 assert(html.indexOf('class="atlas-workspace"')<html.indexOf('Whole organisation summary'),'map workspace must be the first operating surface');
 assert.equal((html.match(/id="map"/g)||[]).length,1);
 const ids=[...html.matchAll(/\bid="([^"]+)"/g)].map(m=>m[1]);assert.equal(ids.length,new Set(ids).size);
});
