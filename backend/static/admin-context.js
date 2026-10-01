/* Explicit source acquisition and source-backed farm history. No credentials in forms. */
let farmHistoryRows=[],farmHistoryFeature=null,farmHistoryCursor=null;
function completedMonth(){const now=new Date();return new Date(Date.UTC(now.getUTCFullYear(),now.getUTCMonth()-1,1)).toISOString().slice(0,7);}
async function openPublicRefresh(feature){
 const ticket=version,tenant=ctx.scope,result=await api('sources',{tenant});if(ticket!==version||scopePending)return;sourceItems=result.sources;
 const ready=sourceItems.filter(s=>['rainfall','water','climate'].includes(s.id));
 openEditor('Get farm context',`<form id="atlas-public-form"><p><strong>${esc(feature.properties.name)}</strong><br><small>Observations are added to this farm without changing farmer records.</small></p><input type="hidden" name="owner" value="${esc(feature.properties.owner)}"><input type="hidden" name="farm" value="${esc(feature.id)}"><label>Source<select name="provider" id="atlas-public-provider">${options(ready.map(s=>[s.id,s.name+' · '+s.source]),'rainfall')}</select></label>${field('Published period','period',completedMonth(),'text','required maxlength="10"')}<p id="atlas-public-guidance" class="hint">Monthly rainfall: YYYY-MM. Final CHIRPS data can arrive weeks after month end; try the preceding month if unavailable.</p><p id="atlas-public-privacy" class="hint">Reads a public raster; no farm-boundary upload. No provider account or API subscription is needed.</p><p class="hint">This enables the selected public source for this organisation if necessary, then requests this farm only. No background polling is started.</p><button class="primary">Fetch and save observations</button></form>`);
}
async function openFarmHistory(feature,provider){
 const ticket=version,tenant=ctx.scope,result=await api('observations',{tenant,owner:feature.properties.owner,farm:feature.id,limit:1000});if(ticket!==version||scopePending)return;
 farmHistoryRows=result.observations;farmHistoryFeature=feature;farmHistoryCursor=result.nextCursor;
 const series=[...new Map(farmHistoryRows.map(r=>[JSON.stringify([r.provider,r.data.metric,r.data.unit]),r])).entries()];
 openEditor('Observation history',`<p><strong>${esc(feature.properties.name)}</strong> · ${esc(feature.properties.farmer)}</p>${series.length?`<label>Measure<select id="atlas-history-series">${options(series.map(([key,r])=>[key,r.data.metric+' · '+r.data.unit+' · '+r.data.source]),(series.find(([,r])=>r.provider===provider)||series[0])[0])}</select></label><div id="atlas-history-content"></div><div class="history-actions"><button id="history-older" type="button" ${result.truncated?'':'hidden'}>Load older saved history</button><button id="history-fetch" type="button">Get older source data</button></div>`:empty('No observations have been collected for this farm. Fetch rainfall, water or climate data to start a genuine history.')}`);
 $('editor').classList.add('history-dialog');
 if(series.length)renderFarmHistory($('atlas-history-series').value);
 $('history-older')?.addEventListener('click',async()=>{const button=$('history-older');button.disabled=true;try{const next=await api('observations',{tenant,owner:feature.properties.owner,farm:feature.id,limit:1000,...farmHistoryCursor});if(ticket!==version||scopePending)return;farmHistoryRows.push(...next.observations);farmHistoryCursor=next.nextCursor;button.hidden=!farmHistoryCursor;renderFarmHistory($('atlas-history-series').value);}catch(error){$('editor-error').textContent=error.message;}finally{button.disabled=false;}});
 $('history-fetch')?.addEventListener('click',()=>openPublicRefresh(feature));
}
function renderFarmHistory(key){AdminHistory.render($('atlas-history-content'),farmHistoryRows,key);}
document.addEventListener('change',event=>{
 if(event.target.id==='atlas-public-provider'){
  const key=event.target.value;document.querySelector('#atlas-public-form [name=period]').value=completedMonth()+(key==='water'?'-D3':'');
  $('atlas-public-guidance').textContent=key==='rainfall'?'YYYY-MM. CHIRPS final monthly rainfall can arrive weeks after month end.':key==='water'?'YYYY-MM-D1, D2 or D3. WaPOR is an estimated daily mean over the selected ten-day period.':'YYYY-MM. Retrieves daily regional climate estimates for a completed month since 1984.';
  $('atlas-public-privacy').textContent=sourceItems.find(s=>s.id===key).privacy;
 }
 if(event.target.id==='atlas-history-series')renderFarmHistory(event.target.value);
});
document.addEventListener('submit',async event=>{
 if(!['atlas-public-form','atlas-near-form'].includes(event.target.id))return;event.preventDefault();event.stopImmediatePropagation();
 const form=event.target,values=Object.fromEntries(new FormData(form)),b=form.querySelector('button'),ticket=version,tenant=ctx.scope;b.disabled=true;
 try{
  if(form.id==='atlas-near-form'){filters={...filters,near:[values.lon,values.lat,values.radius].join(','),bbox:'',cell:'',kind:'farm',layer:'farms'};page=1;$('editor').close();await changed();return;}
  const provider=values.provider,source=sourceItems.find(s=>s.id===provider);
  b.textContent='Fetching source data…';$('editor-error').textContent='';
  if(!source.enabled){await api('sources/'+provider,{tenant}, {enabled:true,revision:source.revision},'PUT');source.enabled=true;source.revision++;}
  if(ticket!==version||scopePending)return;
  const result=await api('sources/'+provider+'/refresh',{tenant}, {owner:values.owner,farm:values.farm,period:values.period});
  if(ticket!==version||scopePending)return;
  $('editor').close();await render();feedback(`${result.added} observations saved; ${result.duplicates} already present. Select the matching data layer or reopen the farm to inspect its history.`);
 }catch(error){if(ticket===version&&!scopePending)$('editor-error').textContent=error.message;}
 finally{b.disabled=false;b.textContent=form.id==='atlas-near-form'?'Find nearby farms':'Fetch and save observations';}
});
