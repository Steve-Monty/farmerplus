/* Read-only farmer choices: administrators cannot provide consent on their behalf. */
function quietDescription(p){
 if(!p||p.quietStart==null||p.quietEnd==null)return 'Off at last report';
 const hour=v=>String(v).padStart(2,'0')+':00';
 const offset=Number(p.utcOffsetMinutes||0),sign=offset<0?'−':'+';
 return hour(p.quietStart)+'–'+hour(p.quietEnd)+' · UTC'+sign+String(Math.floor(Math.abs(offset)/60)).padStart(2,'0')+':'+String(Math.abs(offset)%60).padStart(2,'0');
}
if(typeof globalThis.profileHeading!=='function')globalThis.profileHeading=(tab,action='')=>`<header><h3>${esc(tab)}</h3>${action}</header>`;
async function profileSharing(owner){
 const ticket=profileTicket,scope=ctx.scope;
 try{
  const r=await api('farmers/'+encodeURIComponent(owner)+'/sharing');
  if(!profileGuard(owner,'Share Data',ticket,scope))return;
  const categories=new Map(r.choices.map(c=>[c.category,c]));
  const choices=r.choices.map(c=>`<article class="sharing-choice ${c.enabled?'is-on':c.explicit?'is-off':'is-pending'}"><div class="sharing-icon" aria-hidden="true">${c.enabled?'✓':c.explicit?'—':'·'}</div><div><h4>${esc(c.name)}</h4><p>${c.enabled?'Sharing category enabled':c.explicit?'Sharing category disabled':'No choice received yet'}</p><small>${c.updated?'Received '+time(c.updated):'Awaiting the first phone sync'}</small></div><span class="profile-pill ${c.enabled?'success':c.explicit?'neutral':'warning'}">${c.enabled?'Yes':c.explicit?'No':'Not received'}</span></article>`).join('');
  const recipients=r.recipients.map(c=>{const category=categories.get(c.category),state=c.effective?'Allowed':c.consent?'Waiting for category choice':category?.enabled?'Awaiting disclosed approval':'Category not enabled',tone=c.effective?'success':category?.enabled?'warning':'neutral';return `<article class="permission-card"><header><div><span class="record-kicker">${esc(category?.name||c.category)}</span><h4>${esc(c.name)}</h4></div><span class="profile-pill ${tone}">${esc(state)}</span></header><p>${esc(c.purpose)}</p><div class="permission-fields"><small>Information included</small>${c.fields.map(f=>`<span>${esc(sharingFieldName(f))}</span>`).join('')}</div><footer><span>${c.consent?'Disclosed approval received':'Approval not received'}</span><span>${c.updated?'Updated '+time(c.updated):'Not recorded'}</span></footer></article>`;}).join('');
  $('profile-content').innerHTML=`${profileHeading('Share Data','<button data-refresh-sharing>Refresh received choices</button>')}<div class="profile-update-line">Server-received choices · refreshes after the phone synchronises</div><section class="profile-subsection"><div class="section-title"><h4>Sharing categories</h4><span>${num(r.choices.filter(c=>c.enabled).length)} enabled</span></div><div class="sharing-choice-grid">${choices}</div></section><section class="profile-subsection"><div class="section-title"><h4>Named recipients</h4><span>${num(r.recipients.filter(c=>c.effective).length)} currently allowed</span></div><div class="permission-grid">${recipients||empty('No named recipients are available.')}</div></section>`;
 }catch(error){if(profileGuard(owner,'Share Data',ticket,scope))$('profile-content').textContent=error.message;}
}
function sharingFieldName(value){return ({name:'Name',country:'Country',productionCategory:'Production category',email:'Email address',phone:'Phone number'})[value]||String(value).replace(/([a-z])([A-Z])/g,'$1 $2').replace(/^./,c=>c.toUpperCase());}
function coopStatus(value){return ({demo_member:'Demo member',left:'Left cooperative',demo_no_payment:'Demo · no payment collected',not_required:'Not required',pending:'Pending',member:'Member'})[value]||String(value||'Not reported').replaceAll('_',' ');}
function coopHistoryView(r){
 const page=r.page;
 return '<section class="app-history"><h3>Your cooperatives</h3><p class="hint">'+esc(r.attribution)+'</p>'+table(['Cooperative','Membership','Annual premium','Payment','Updated'],r.memberships.map(c=>[esc(c.name)+(c.demo?' <span class="badge neutral">Demo</span>':''),esc(coopStatus(c.status)),esc(c.currency)+' '+num(c.annualMinor/100,2),esc(coopStatus(c.payment_status)),time(c.updated)]))+'<h3>Membership history</h3>'+table(['Cooperative','Action','Result','Server received'],r.events.map(c=>[esc(c.name),c.action==='coop.join'?'Joined':'Left',esc(coopStatus(c.status)),time(c.at)]))+`<div class="pagination"><button data-history-app="coop" data-history-page="${page-1}" ${page<=1?'disabled':''}>Previous</button><span>${num(r.total)} events · Page ${page} of ${Math.max(1,Math.ceil(r.total/25))}</span><button data-history-app="coop" data-history-page="${page+1}" ${page*25>=r.total?'disabled':''}>Next</button></div></section>`;
}
document.addEventListener('click',async event=>{
 if(event.target.closest('[data-refresh-sharing]')){await profileSharing(profileData.person.id);return;}
 if(event.target.closest('[data-no-farm]')){
  // Start a people-only search, clearing incompatible crop, country and map bounds.
  try{await navigate('farmers',{farmStatus:'none'});}catch(error){feedback(error.message,true);}
 }
});
async function profileClassification(owner){
 const ticket=profileTicket,scope=ctx.scope;
 try{
  const r=await api('farmers/'+encodeURIComponent(owner)+'/classification');
  if(!profileGuard(owner,'Account classification',ticket,scope))return;
  $('profile-content').innerHTML=`${profileHeading('Account classification')}<section class="classification-card"><span class="profile-pill ${r.classification==='production'?'success':r.classification==='test'?'warning':'neutral'}">${esc(r.classification)}</span><div><h4>Current account type</h4><p>${r.updated?'Updated '+time(r.updated)+' · '+esc(r.reason):'No classification has been recorded.'}</p></div></section>${r.canEdit?`<form id="classification-form" class="profile-form-card"><h4>Update classification</h4><p>Use an explicit administrator decision. Names and usage patterns are never used to infer this label.</p><div class="form-grid"><label>Classification<select name="classification">${options(['unknown','production','test'],r.classification)}</select></label><label>Reason<input name="reason" required minlength="3" maxlength="500"></label></div><button>Save classification</button><p role="status" id="classification-status"></p></form>`:'<p class="notice">Only platform administrators can change this label.</p>'}`;
  const form=$('classification-form');if(!form)return;
  form.onsubmit=async event=>{event.preventDefault();if(!profileGuard(owner,'Account classification',ticket,scope))return;const b=form.querySelector('button');b.disabled=true;try{const values=Object.fromEntries(new FormData(form));await api('farmers/'+encodeURIComponent(owner)+'/classification',{}, {...values,revision:r.revision});if(profileGuard(owner,'Account classification',ticket,scope))await profileClassification(owner);}catch(error){if(profileGuard(owner,'Account classification',ticket,scope))$('classification-status').textContent=error.message;}finally{b.disabled=false;}};
 }catch(error){if(profileGuard(owner,'Account classification',ticket,scope))$('profile-content').textContent=error.message;}
}
