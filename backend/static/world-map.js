'use strict';
const $=id=>document.getElementById(id),hidden=new Set();let features=[],ready=false,loading=false,lastFit=false;
const map=new maplibregl.Map({container:'map',style:'https://tiles.openfreemap.org/styles/liberty',center:[25,-15],zoom:1.5,attributionControl:true});
map.addControl(new maplibregl.NavigationControl(),'top-right');
map.on('error',()=>{$('map-error').hidden=false;});
const collection=rows=>({type:'FeatureCollection',features:rows});
function visible(){const text=$('search').value.toLowerCase();return features.filter(f=>!hidden.has(f.id)&&String(f.properties.name).toLowerCase().includes(text));}
function redraw(){
 if(!ready)return;
 const rows=visible();map.getSource('farms').setData(collection(rows));
 const points=rows.map(f=>{const coords=f.geometry.type==='Point'?f.geometry.coordinates:f.geometry.coordinates[0][0];return {...f,geometry:{type:'Point',coordinates:coords}};});
 map.getSource('locations').setData(collection(points));
}
function bounds(f){const b=new maplibregl.LngLatBounds();const coords=f.geometry.type==='Point'?[f.geometry.coordinates]:f.geometry.coordinates[0];coords.forEach(p=>b.extend(p));return b;}
function select(f){map.fitBounds(bounds(f),{padding:80,maxZoom:17});const p=f.properties;$('detail').hidden=false;$('detail').textContent=p.name+'\n'+(p.kind==='farm'?'Whole farm':p.kind==='pin'?'Place':'Farm area')+' · version '+p.version+'\n'+(p.areaM2?(p.areaM2/10000).toFixed(3)+' ha\n':'')+'Synced '+new Date(p.updated).toLocaleString();}
function fit(){const rows=visible();if(!rows.length)return;const b=new maplibregl.LngLatBounds();rows.forEach(f=>{b.extend(bounds(f));});map.fitBounds(b,{padding:70,maxZoom:16});}
function list(){const fragment=document.createDocumentFragment(),search=$('search').value.toLowerCase();
 for(const f of features.filter(f=>String(f.properties.name).toLowerCase().includes(search))){
  const row=document.createElement('div');row.className='record';const toggle=document.createElement('input');toggle.type='checkbox';toggle.checked=!hidden.has(f.id);toggle.setAttribute('aria-label','Show '+f.properties.name);toggle.addEventListener('change',()=>{if(toggle.checked)hidden.delete(f.id);else hidden.add(f.id);redraw();});
  const button=document.createElement('button'),name=document.createElement('strong'),small=document.createElement('small');name.textContent=f.properties.name;small.textContent=(f.properties.kind==='farm'?'Farm':f.properties.kind==='pin'?'Place':'Area')+' · v'+f.properties.version;button.append(name,small);button.addEventListener('click',()=>select(f));row.append(toggle,button);fragment.append(row);
 }$('records').replaceChildren(fragment);redraw();
}
async function refresh(){
 if(loading)return;loading=true;$('refresh').disabled=true;
 try{const response=await fetch($('all').checked?'/admin/map/geojson':'/map/geojson',{credentials:'same-origin',cache:'no-store'});
 if(!response.ok)throw Error(response.status===401?'Sign in to see your synced farms.':response.status===403?'Administrator access is required.':'Could not refresh. The last loaded map is retained.');
 const data=await response.json();features=data.features;$('status').textContent=features.length+' mapped records · '+data.unmapped+' not mapped'+(data.invalid?' · '+data.invalid+' need repair':'')+' · Checked '+new Date(data.checkedAt).toLocaleTimeString();list();if(!lastFit&&features.length&&ready){fit();lastFit=true;}
 }catch(e){$('status').textContent=e.message;}finally{loading=false;$('refresh').disabled=false;}
}
map.on('load',()=>{
 ready=true;map.addSource('farms',{type:'geojson',data:collection([])});map.addSource('locations',{type:'geojson',data:collection([])});
 map.addLayer({id:'farm-fill',type:'fill',source:'farms',filter:['==',['geometry-type'],'Polygon'],paint:{'fill-color':['match',['get','kind'],'farm','#2364bd','#218762'],'fill-opacity':0.22}});
 map.addLayer({id:'farm-line',type:'line',source:'farms',filter:['==',['geometry-type'],'Polygon'],paint:{'line-color':['match',['get','kind'],'farm','#2364bd','#13765b'],'line-width':3}});
 map.addLayer({id:'farm-locations',type:'circle',source:'locations',paint:{'circle-radius':7,'circle-color':'#13765b','circle-stroke-color':'#fff','circle-stroke-width':2}});
 for(const layer of ['farm-fill','farm-locations']){map.on('mouseenter',layer,()=>map.getCanvas().style.cursor='pointer');map.on('mouseleave',layer,()=>map.getCanvas().style.cursor='');map.on('click',layer,e=>{const f=features.find(f=>String(f.id)===String(e.features[0].id));if(f)select(f);});}
 redraw();if(features.length){fit();lastFit=true;}
});
$('refresh').addEventListener('click',refresh);$('fit').addEventListener('click',fit);$('search').addEventListener('input',list);$('all').addEventListener('change',()=>{hidden.clear();lastFit=false;refresh();});$('show').addEventListener('click',()=>{hidden.clear();list();});$('hide').addEventListener('click',()=>{features.forEach(f=>hidden.add(f.id));list();});
async function access(){
 const r=await fetch('/auth/me',{credentials:'same-origin'});const user=r.ok?await r.json():null;
 $('admin-control').hidden=!user?.admin;
 const config=await (await fetch('/oidc/config')).json();
 $('local-login').hidden=!!user||config.enabled;
}
$('local-login').addEventListener('submit',async e=>{
 e.preventDefault();const form=e.currentTarget,button=form.querySelector('button');button.disabled=true;
 try{const r=await fetch('/auth/login',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json'},body:JSON.stringify(Object.fromEntries(new FormData(form)))});
 if(!r.ok)throw Error('Sign-in failed. Check your details.');form.reset();await access();await refresh();
 }catch(e){$('status').textContent=e.message;}finally{button.disabled=false;}
});
access();
refresh();setInterval(()=>{if($('auto').checked&&!document.hidden)refresh();},20000);
