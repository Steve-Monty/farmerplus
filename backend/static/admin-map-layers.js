/* Basemap and regional overlays never replace the farmer feature source. */
(function(root){
 'use strict';
 const overlays={rainfall:{name:'Rainfall rate · NASA IMERG',maxzoom:6,detail:'Daily precipitation rate · mm/hour · regional estimate, not a rain gauge. Colour scale: low to high rainfall.',colours:['#0000ff','#00ffff','#00ff00','#ffff00','#ff0000'],labels:['0','0.1','1','10','50+']},vegetation:{name:'Vegetation · NASA MODIS NDVI',maxzoom:9,detail:'8-day NDVI composite · regional vegetation greenness, not field-level crop health. Clouds and missing observations can leave gaps.',colours:['#ede8b5','#b7c86d','#669b3b','#1a6129'],labels:['0','0.3','0.6','1']}};
 const escape=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const defaultDate=()=>new Date(Date.now()-2*86400000).toISOString().slice(0,10);
 function controls(f){return `<details class="atlas-background-panel"><summary>Basemap & overlays</summary><label>Basemap<select id="atlas-basemap">${[["street","Street · OpenFreeMap"],["roadmap","Google Maps · Roads"],["satellite","Google Maps · Satellite"],["hybrid","Google Maps · Satellite + labels"],["terrain","Google Maps · Terrain"]].map(([id,label])=>`<option value="${id}" ${(f.basemap||"street")===id?"selected":""}>${label}</option>`).join("")}</select></label><p class="hint">Google imagery dates and detail vary by location; it is not live or proof of ownership. Online viewing only. FarmerPlus boundaries and pins are independent records.</p><label>Full-map overlay<select id="atlas-environment"><option value="">None</option>${Object.entries(overlays).map(([id,o])=>`<option value="${id}" ${f.overlay===id?'selected':''}>${o.name}</option>`).join('')}</select></label><label>Observation date<input id="atlas-overlay-date" type="date" min="2001-01-01" max="${new Date().toISOString().slice(0,10)}" value="${escape(f.overlayDate||defaultDate())}"></label><label>Overlay opacity<input id="atlas-overlay-opacity" type="range" min="0" max="100" value="60"></label><div id="atlas-overlay-evidence" role="status"></div><p class="hint">Blank areas can mean missing coverage—not zero. Farmer pins and boundaries remain above the overlay. Map views are requested from the imagery provider; no farmer names or IDs are sent.</p></details>`;}
 function attach(map,d,host,status){
  const f=d.filters();let current=f.overlay||'',observed=f.overlayDate||defaultDate();
 const streetLayers=map.__farmerStreetLayers??=map.getStyle().layers.filter(l=>!l.id.startsWith('atlas-')).map(l=>[l.id,l.layout?.visibility||'visible']);
  const showStreet=show=>streetLayers.forEach(([id,visibility])=>{if(map.getLayer(id))map.setLayoutProperty(id,'visibility',show?visibility:'none');});
  let baseKind=f.basemap||'street',googleConfigured=null,baseTicket=0,viewportTimer,loadedKind=map.__farmerGoogleState?.kind||'',loadedZoom=map.__farmerGoogleState?.zoom??-1,lastView='';
  const credit=map.__farmerGoogleCredit??document.createElement('div');if(!map.__farmerGoogleCredit)credit.hidden=true;map.__farmerGoogleCredit=credit;credit.className='atlas-google-credit';host.querySelector('.atlas-map-stage').append(credit);
  const sourceCredit=host.querySelector('#atlas-source-credit');
  function updateCredit(){const parts=[];if(baseKind==='street')parts.push('<a href="https://openfreemap.org/" target="_blank" rel="noreferrer">OpenFreeMap</a> · © <a href="https://openmaptiles.org/" target="_blank" rel="noreferrer">OpenMapTiles</a> · © <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noreferrer">OpenStreetMap contributors</a>');if(current)parts.push('<a href="https://www.earthdata.nasa.gov/" target="_blank" rel="noreferrer">NASA GIBS</a>');sourceCredit.innerHTML=parts.join(' · ');sourceCredit.hidden=!parts.length;}
  d.api('google-maps/config').then(config=>{
   if(!d.isCurrent(d.version))return;
   googleConfigured=!!config.configured;
   if(!googleConfigured&&baseKind!=='street'){
    const select=host.querySelector('#atlas-basemap');if(select)select.value='street';
    background('street');
   }else background(baseKind);
   if(config.configured||!config.canConfigure)return;
   const panel=host.querySelector('.atlas-background-panel');
   const form=document.createElement('form');form.id='atlas-google-setup';
   form.innerHTML='<h4>Connect Google Maps</h4><p>Platform administrator only. The restricted key is stored privately on this server.</p><label>Google Maps server API key<input type="password" name="key" autocomplete="off" required></label><button>Save server key</button><p role="status"></p>';
   panel.append(form);
   form.addEventListener('submit',async event=>{event.preventDefault();event.stopPropagation();const input=form.querySelector('input'),value=input.value;input.value='';try{await d.api('google-maps/config',{}, {key:value});googleConfigured=true;form.remove();status('Google Maps connected. Choose a Google basemap to use it.');}catch(error){form.querySelector('[role="status"]').textContent=error.message;}});
  }).catch(()=>{googleConfigured=false;if(baseKind!=='street')background('street');});
  async function background(value){
   baseKind=value;
   if(value==='street'){++baseTicket;lastView='';if(map.getLayer('atlas-google'))map.setLayoutProperty('atlas-google','visibility','none');credit.hidden=true;showStreet(true);map.setMaxZoom(22);updateCredit();return;}
   if(googleConfigured!==true){
    if(googleConfigured===false){const select=host.querySelector('#atlas-basemap');if(select)select.value='street';background('street');status('Google Maps is not connected. Street map remains available.',true);}
    return;
   }
   const b=map.getBounds(),wrap=v=>((v+180)%360+360)%360-180;
   const signature=[value,Math.floor(map.getZoom()),b.getNorth().toFixed(5),b.getSouth().toFixed(5),b.getEast().toFixed(5),b.getWest().toFixed(5)].join(':');
   if(signature===lastView)return;
   const ticket=++baseTicket;
   try{
    const viewport=await d.api('google-maps/viewport',{kind:value,zoom:Math.min(22,Math.floor(map.getZoom())),north:Math.min(85,b.getNorth()),south:Math.max(-85,b.getSouth()),east:wrap(b.getEast()),west:wrap(b.getWest())});
    if(ticket!==baseTicket||!d.isCurrent(d.version))return;
    lastView=signature;
    const c=map.getCenter(),rects=viewport.maxZoomRects.filter(r=>r.south<=c.lat&&r.north>=c.lat&&(r.west<=r.east?c.lng>=r.west&&c.lng<=r.east:c.lng>=r.west||c.lng<=r.east));
    const maxzoom=Math.min(22,Math.max(0,...rects.map(r=>r.maxZoom)));
    const url=new URL(d.path(`google-maps/tiles/${value}/{z}/{x}/{y}`),location.origin).href.replace(/%7B/gi,'{').replace(/%7D/gi,'}');
    if(loadedKind!==value||loadedZoom!==maxzoom||!map.getSource('atlas-google')){
     if(map.getLayer('atlas-google'))map.removeLayer('atlas-google');
     if(map.getSource('atlas-google'))map.removeSource('atlas-google');
     map.addSource('atlas-google',{type:'raster',tiles:[url],tileSize:viewport.tileSize,maxzoom});
     map.addLayer({id:'atlas-google',type:'raster',source:'atlas-google'},map.getLayer('atlas-environment')?'atlas-environment':'atlas-areas');
     loadedKind=value;loadedZoom=maxzoom;
     map.__farmerGoogleState={kind:value,zoom:maxzoom};
    }else map.setLayoutProperty('atlas-google','visibility','visible');
    credit.innerHTML='<img src="/static/google-maps-logo.svg" alt="Google Maps"><span></span>';credit.querySelector('span').textContent=viewport.copyright;credit.hidden=false;
    showStreet(false);
    updateCredit();
    if(map.getMaxZoom()!==Math.max(1,maxzoom))map.setMaxZoom(Math.max(1,maxzoom));
   }catch(error){if(ticket===baseTicket&&d.isCurrent(d.version)){showStreet(true);status(error.message+' Street map remains available.',true);}}
  }
  // Keep imagery visible while panning. Removing the layer on movestart caused
  // a visible flash and unnecessary reloads on every map interaction.
  const moved=()=>{clearTimeout(viewportTimer);viewportTimer=setTimeout(()=>{if(d.isCurrent(d.version))background(baseKind);},350);};map.on('moveend',moved);
  function surface(){
   const box=document.getElementById('atlas-overlay-evidence'),o=overlays[current],signature=current+'|'+observed;box.textContent='';
   if(!o){if(map.getLayer('atlas-environment'))map.removeLayer('atlas-environment');if(map.getSource('atlas-environment'))map.removeSource('atlas-environment');map.__farmerEnvironmentState='';updateCredit();return;}
   if(map.__farmerEnvironmentState===signature&&map.getLayer('atlas-environment')){map.setPaintProperty('atlas-environment','raster-opacity',Number(document.getElementById('atlas-overlay-opacity').value)/100);box.innerHTML=`<strong>${o.name}</strong><p>${escape(observed)} · ${o.detail}</p><a href="https://worldview.earthdata.nasa.gov/" target="_blank" rel="noreferrer">Source and detailed legend: NASA Worldview</a>`;updateCredit();return;}
   if(map.getLayer('atlas-environment'))map.removeLayer('atlas-environment');
   if(map.getSource('atlas-environment'))map.removeSource('atlas-environment');
   const base=d.path(`environment-tiles/${current}/{z}/{x}/{y}.png`,{observed});
   // URL builders may escape template braces; MapLibre expands these placeholders.
   const url=base.replace(/%7B/gi,'{').replace(/%7D/gi,'}');
   map.addSource('atlas-environment',{type:'raster',tiles:[new URL(url,location.origin).href.replace(/%7B/gi,'{').replace(/%7D/gi,'}')],tileSize:256,maxzoom:o.maxzoom,attribution:'NASA GIBS · '+o.name});
   map.addLayer({id:'atlas-environment',type:'raster',source:'atlas-environment',paint:{'raster-opacity':Number(document.getElementById('atlas-overlay-opacity').value)/100}},'atlas-areas');
   map.__farmerEnvironmentState=signature;
   box.innerHTML=`<strong>${o.name}</strong><p>${escape(observed)} · ${o.detail}</p><a href="https://worldview.earthdata.nasa.gov/" target="_blank" rel="noreferrer">Source and detailed legend: NASA Worldview</a>`;
   updateCredit();
  }
  if(baseKind==='street')background(baseKind);surface();
  host.addEventListener('change',event=>{try{const id=event.target.id;if(id==='atlas-basemap'){background(event.target.value);d.updatePresentation({basemap:event.target.value});}if(id==='atlas-environment'||id==='atlas-overlay-date'){current=document.getElementById('atlas-environment').value;observed=document.getElementById('atlas-overlay-date').value;if(!/^\d{4}-\d{2}-\d{2}$/.test(observed))return;surface();d.updatePresentation({overlay:current,overlayDate:observed});}}catch{status('This background layer could not load. Farmer records are still available.',true);}});
  host.addEventListener('input',event=>{if(event.target.id==='atlas-overlay-opacity'&&map.getLayer('atlas-environment'))map.setPaintProperty('atlas-environment','raster-opacity',Number(event.target.value)/100);});
  return ()=>{++baseTicket;clearTimeout(viewportTimer);map.off('moveend',moved);};
 }
 const api={controls,attach};if(typeof module==='object'&&module.exports)module.exports=api;else root.AdminMapLayers=api;
})(globalThis);
