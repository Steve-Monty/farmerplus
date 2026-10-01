'use strict';
const statusElement=document.getElementById('account-status');
function report(message){statusElement.textContent=message;statusElement.hidden=false;statusElement.focus();}
for(const form of document.querySelectorAll('form[data-account]'))form.addEventListener('submit',async event=>{
 event.preventDefault();const kind=form.dataset.account,values=Object.fromEntries(new FormData(form));
 if('confirmation' in values&&values.password!==values.confirmation)return report('The passwords do not match.');
 delete values.confirmation;if('email' in values&&!values.email)values.email=null;
 if(kind==='credentials'){if(!values.username)delete values.username;if(!values.password)delete values.password;}
 const routes={'admin-email':'/auth/email/login','admin-legacy':'/auth/login',create:'/auth/register',recover:'/auth/recover',reissue:'/auth/recovery/reissue',profile:'/account/profile',credentials:'/auth/change'};
 const submit=form.querySelector('button');submit.disabled=true;statusElement.hidden=true;
 try{const response=await fetch(routes[kind],{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(values),credentials:'same-origin'});const data=await response.json();if(!response.ok)throw Error(typeof data.detail==='string'?data.detail:'The request could not finish. Try again.');
 form.reset();if(data.recoveryCodes){form.hidden=true;document.getElementById('recovery-codes').textContent=data.recoveryCodes.join('\n');document.getElementById('recovery-result').hidden=false;}
 else{const administration=kind.startsWith('admin-');let target=administration?'/admin':'/account';if(administration){try{const saved=new URL(sessionStorage.getItem('admin-return')||'/admin',location.origin);if(saved.origin===location.origin&&saved.pathname==='/admin')target=saved.pathname+saved.search+saved.hash;sessionStorage.removeItem('admin-return');}catch{}}location.assign(data.signInRequired?'/login':target);}
 }catch(error){report(error.message);}finally{submit.disabled=false;}
});
const kept=document.getElementById('codes-kept'),next=document.getElementById('codes-continue');
if(kept)kept.addEventListener('change',()=>next.disabled=!kept.checked);
if(next)next.addEventListener('click',()=>{document.getElementById('recovery-codes').textContent='';location.assign('/login');});
const accountLogout=document.getElementById('account-logout');
if(accountLogout)accountLogout.addEventListener('click',async()=>{accountLogout.disabled=true;statusElement.hidden=true;try{const response=await fetch('/auth/logout',{method:'POST',credentials:'same-origin',headers:{Accept:'application/json'}});if(!response.ok&&response.status!==401)throw Error('Sign out could not finish. Try again.');try{sessionStorage.removeItem('admin-return');}catch{}location.assign('/admin/identity');}catch(error){accountLogout.disabled=false;report(error.message);}});
