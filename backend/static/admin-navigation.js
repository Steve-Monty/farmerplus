/* Shared disclosure navigation. No third-party UI or authentication dependency. */
(function(root){
 'use strict';
 const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const groups={Operations:[['work','Work queue','Assign and follow up'],['quality','Data quality','Find records needing review'],['learning','Learning','Enrolment and completion'],['messages','Communications','Farmer Inbox messages']],Management:[['apps','App store','Packages, versions and installations'],['sources','Data & integrations','Connect and review sources'],['reports','Reports','Exports and saved reports'],['audit','Activity & audit','Changes and accountability'],['/admin/tenants','Organisations & wallets','Membership and allocations'],['/admin/identity','Accounts & access','Identity and permissions']]};
 function link(id,label,description='',local=false){const route=id.startsWith('/'),href=route?id:(local?'#':'/admin#')+id;return `<a href="${href}" ${route?'':`data-nav="${id}"`} ${id==='/admin/identity'?'id="accounts-link"':''}><span>${esc(label)}</span>${description?'<small>'+esc(description)+'</small>':''}</a>`;}
 function markup(local=false){return `<a class="brand" href="/admin" aria-label="FarmerPlus operations map"><img src="/static/admin-wordmark.png" alt="FarmerPlus" width="166" height="50"></a><button id="menu" class="nav-toggle" aria-expanded="false" aria-controls="primary-navigation">Menu</button><nav id="primary-navigation" aria-label="Administration">${link('overview','Operations map','',local)}${link('farmers','Farmers & land','',local)}${Object.entries(groups).map(([label,rows])=>`<details class="nav-group"><summary>${label}</summary><div class="nav-popover">${rows.map(r=>link(...r,local)).join('')}</div></details>`).join('')}</nav><details class="nav-group account-menu"><summary aria-label="Account menu"><span class="account-monogram" aria-hidden="true">FP</span><span id="administrator">My account</span></summary><div class="nav-popover"><p class="account-caption">Signed-in workspace</p><small id="environment"></small><a href="/account">My account</a><a href="/admin/identity">Sign in again</a><button id="admin-logout" class="account-action" type="button">Sign out</button><p id="admin-logout-status" class="account-action-status" role="alert" hidden></p></div></details>`;}
 async function signOut(request=fetch,navigate=url=>location.assign(url),storage=sessionStorage){
  const csrf=typeof document==='undefined'?'':(document.cookie.split('; ').find(v=>v.startsWith('fp_admin_csrf='))?.split('=')[1]||'');
  const response=await request(csrf?'/admin/logout':'/auth/logout',{method:'POST',credentials:'same-origin',headers:{Accept:'application/json','X-CSRF-Token':csrf}});
  if(!response.ok&&response.status!==401)throw Error('Sign out could not finish. Try again.');
  try{storage.removeItem('admin-return');}catch{}
  navigate('/admin/identity');
 }
 function bind(header){
  if(document.cookie.includes('fp_admin_csrf=')){header.querySelector('a[href="/account"]').href='/admin/account';}
  const menu=header.querySelector('#menu'),nav=header.querySelector('nav');
  menu.addEventListener('click',()=>{const open=menu.getAttribute('aria-expanded')!=='true';menu.setAttribute('aria-expanded',String(open));header.classList.toggle('nav-open',open);});
  const close=()=>{header.querySelectorAll('details[open]').forEach(d=>d.open=false);header.classList.remove('nav-open');menu.setAttribute('aria-expanded','false');};
  header.addEventListener('click',e=>{if(e.target.closest('a'))close();});
  header.querySelectorAll('details').forEach(d=>d.addEventListener('toggle',()=>{if(d.open)header.querySelectorAll('details').forEach(other=>{if(other!==d)other.open=false;});}));
  document.addEventListener('click',e=>{if(!header.contains(e.target))close();});
  header.addEventListener('keydown',e=>{if(e.key==='Escape'){const group=e.target.closest('details'),mobile=header.classList.contains('nav-open');close();(mobile?menu:group?.querySelector('summary')||menu).focus();}});
  const logout=header.querySelector('#admin-logout'),logoutStatus=header.querySelector('#admin-logout-status');
  logout.addEventListener('click',async()=>{logout.disabled=true;logoutStatus.hidden=true;try{await signOut();}catch(error){logoutStatus.textContent=error.message;logoutStatus.hidden=false;logout.disabled=false;}});
  function current(){const raw=location.hash.slice(1).split('?')[0],view=raw==='atlas'?'overview':raw||'overview';nav.querySelectorAll('a').forEach(a=>{const active=a.dataset.nav?location.pathname==='/admin'&&a.dataset.nav===view:new URL(a.href).pathname===location.pathname;a.toggleAttribute('aria-current',active);if(active)a.setAttribute('aria-current','page');});nav.querySelectorAll('details').forEach(d=>d.classList.toggle('is-current',!!d.querySelector('[aria-current=page]')));}
  current();window.addEventListener('hashchange',current);header.refreshCurrent=current;
 }
 function mount(header,local=false){header.className='admin-topnav';header.innerHTML=markup(local);bind(header);}
 const api={markup,mount,signOut};if(typeof module==='object'&&module.exports)module.exports=api;else{root.AdminNavigation=api;const h=document.getElementById('admin-topnav');if(h)mount(h,true);}
})(typeof globalThis==='object'?globalThis:this);
