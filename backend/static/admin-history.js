/* Observation history: real timestamps, explicit gaps, no synthetic readings. */
(function(root){
 'use strict';
 const escape=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const day=v=>v.slice(0,10),number=v=>Number(v).toLocaleString(undefined,{maximumFractionDigits:3});
 function yearBefore(value){const d=new Date(value+'T00:00:00Z'),month=d.getUTCMonth();d.setUTCFullYear(d.getUTCFullYear()-1);if(d.getUTCMonth()!==month)d.setUTCDate(0);return d.toISOString().slice(0,10);}
 function series(rows,key){const [provider,metric,unit]=JSON.parse(key),unique=new Map();for(const r of [...rows].sort((a,b)=>b.imported-a.imported)){if(r.provider===provider&&r.data.metric===metric&&r.data.unit===unit&&!unique.has(r.observed))unique.set(r.observed,r);}return [...unique.values()].filter(r=>r.data.value!=null&&Number.isFinite(Number(r.data.value))).sort((a,b)=>a.observed.localeCompare(b.observed));}
 function segments(rows,monthly=false){const out=[];let group=[];for(const row of rows){if(group.length){const prior=group.at(-1),gap=(Date.parse(row.observed)-Date.parse(prior.observed))/86400000;if(gap>(monthly?32:1.1)){out.push(group);group=[];}}group.push(row);}if(group.length)out.push(group);return out;}
 function render(host,all,key){
  const rows=series(all,key),[,metric,unit]=JSON.parse(key);if(!rows.length){host.innerHTML='<p>No numeric observations in this series.</p>';return;}
  const latest=day(rows.at(-1).observed),earliest=day(rows[0].observed);
  host.innerHTML=`<div class="history-range"><label>From<input id="atlas-compare-a" type="date" value="${yearBefore(latest)}" max="${latest}"></label><label>To<input id="atlas-compare-b" type="date" value="${latest}" max="${latest}"></label><button type="button" id="history-all">All loaded history</button></div><div id="history-plot"></div><div id="history-reading" class="history-reading" role="status">Point to a reading, or use Tab to inspect exact values.</div><div id="atlas-comparison" class="history-summary"></div><details class="history-source"><summary>Source & coverage</summary><p>${escape(rows.at(-1).data.source)} · ${escape(rows.at(-1).data.resolution||'')}</p><p>${escape(rows.at(-1).data.quality||'')} Missing dates remain gaps, not zero. A difference is not a crop diagnosis.</p><p>Loaded coverage: ${earliest} – ${latest}. Earlier dates require older observations from the source.</p></details>`;
  const from=host.querySelector('#atlas-compare-a'),to=host.querySelector('#atlas-compare-b'),plot=host.querySelector('#history-plot'),summary=host.querySelector('#atlas-comparison');
  function draw(){
   const start=from.value,end=to.value;if(!start||!end||start>end){plot.innerHTML='<p class="notice">Choose a start date before the end date.</p>';summary.textContent='';return;}
   const shown=rows.filter(r=>day(r.observed)>=start&&day(r.observed)<=end);
   if(!shown.length){plot.innerHTML='<p class="empty">No observations saved for this range. Load older history or fetch source data.</p>';summary.textContent='';return;}
   const values=shown.map(r=>Number(r.data.value)),lo=Math.min(...values),hi=Math.max(...values),pad=(hi-lo)*.1||1,min=lo>=0?0:lo-pad,max=hi+pad;
   const first=Date.parse(start),last=Date.parse(end),x=r=>64+640*(Date.parse(r.observed)-first)/Math.max(1,last-first),y=r=>245-215*(Number(r.data.value)-min)/(max-min);
   const lines=segments(shown,/month/i.test(unit)||/monthly/i.test(metric)).map(group=>`<polyline fill="none" stroke="#245dcc" stroke-width="2" points="${group.map(r=>`${x(r).toFixed(2)},${y(r).toFixed(2)}`).join(' ')}"/>`).join('');
   plot.innerHTML=`<svg class="observation-chart" viewBox="0 0 740 295" role="group" aria-label="${escape(metric)} line graph in ${escape(unit)}. Missing dates are gaps.">${[0,.25,.5,.75,1].map(t=>`<line x1="64" y1="${245-t*215}" x2="704" y2="${245-t*215}" stroke="#e1e6ed"/><text x="53" y="${249-t*215}" text-anchor="end" font-size="12" fill="#556070">${number(min+t*(max-min))}</text>`).join('')}${lines}${shown.map((r,i)=>`<circle tabindex="0" data-reading="${i}" aria-label="${escape(day(r.observed)+': '+number(r.data.value)+' '+unit)}" cx="${x(r).toFixed(2)}" cy="${y(r).toFixed(2)}" r="${shown.length>100?2:3.5}" fill="#245dcc"/>`).join('')}<text x="64" y="278" font-size="12">${start}</text><text x="704" y="278" text-anchor="end" font-size="12">${end}</text></svg>`;
   const reading=host.querySelector('#history-reading');plot.querySelectorAll('[data-reading]').forEach(dot=>{const show=()=>{const r=shown[Number(dot.dataset.reading)];reading.textContent=`${day(r.observed)} · ${number(r.data.value)} ${unit} · ${r.data.source}`;};dot.onpointerenter=show;dot.onfocus=show;});
   const a=shown[0],b=shown.at(-1),diff=Number(b.data.value)-Number(a.data.value);
   summary.innerHTML=`<div><small>Readings in range</small><strong>${shown.length}</strong></div><div><small>First · ${day(a.observed)}</small><strong>${number(a.data.value)} ${escape(unit)}</strong></div><div><small>Latest · ${day(b.observed)}</small><strong>${number(b.data.value)} ${escape(unit)}</strong></div><div><small>Change between these readings</small><strong>${diff>0?'+':''}${number(diff)} ${escape(unit)}</strong></div>${earliest>start?'<p class="hint">The requested start predates the loaded records. No earlier values have been assumed.</p>':''}`;
  }
  from.onchange=draw;to.onchange=()=>{from.value=yearBefore(to.value);draw();};host.querySelector('#history-all').onclick=()=>{from.value=earliest;to.value=latest;draw();};draw();
 }
 const api={yearBefore,series,segments,render};root.AdminHistory=api;if(typeof module!=='undefined')module.exports=api;
})(globalThis);
