/* Host-owned runtime. Downloaded frames have no credentials or direct storage. */
(function(){
 'use strict';
 const decode=s=>Uint8Array.from(atob(s),c=>c.charCodeAt(0));
 async function verify(signed,signature,spki){
   const key=await crypto.subtle.importKey('spki',decode(spki),{name:'ECDSA',namedCurve:'P-256'},false,['verify']);
   if(!await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},key,decode(signature),decode(signed)))throw Error('App publisher signature is not valid.');
   return new TextDecoder().decode(decode(signed));
 }
 async function mount(frame,source,callback){
   const handshake=crypto.randomUUID(),nonce=document.querySelector('meta[name=farmerplus-script-nonce]')?.content||crypto.randomUUID().replaceAll('-','');
   const bridge=`(()=>{const waiting=new Map();let seq=0,port,update=()=>{};const ready=new Promise(resolve=>{addEventListener('message',e=>{if(e.source!==parent||e.data?.type!=='farmerplus-port'||e.data?.handshake!==${JSON.stringify(handshake)}||!e.ports[0]||port)return;port=e.ports[0];port.onmessage=e=>{const m=e.data;if(m.type==='update'){update();return;}const job=waiting.get(m.id);if(!job)return;waiting.delete(m.id);clearTimeout(job.timer);m.error?job.reject(Error(m.error)):job.resolve(m.value);};port.start();resolve();});});globalThis.FarmerPlus={call:async(method,args={})=>{await ready;return new Promise((resolve,reject)=>{const id=++seq,timer=setTimeout(()=>{waiting.delete(id);reject(Error('FarmerPlus did not respond. Your saved records are kept.'));},120000);waiting.set(id,{resolve,reject,timer});port.postMessage({id,method,args});});},onUpdate:fn=>{update=fn;}};let lastActivity=0;for(const name of ['pointerdown','pointermove','keydown','wheel'])addEventListener(name,e=>{if(e.isTrusted&&port&&Date.now()-lastActivity>1000){lastActivity=Date.now();port.postMessage({type:'activity'});}},{capture:true,passive:true});parent.postMessage({type:'farmerplus-ready',handshake:${JSON.stringify(handshake)}},'*');})();`;
   let channel,closed=false,busy=0;
   const listener=e=>{
     if(closed||e.source!==frame.contentWindow||e.data?.type!=='farmerplus-ready'||e.data?.handshake!==handshake)return;
     channel?.port1.close();
     channel=new MessageChannel();
     channel.port1.onmessage=async e=>{
       const m=e.data;if(!closed&&m?.type==='activity'){await callback(JSON.stringify({method:'activity',args:{}}));return;}if(closed||!m||!Number.isSafeInteger(m.id)||typeof m.method!=='string'||typeof m.args!=='object'||m.args===null||busy>20)return;
       if(JSON.stringify(m).length>12*1024*1024){channel.port1.postMessage({id:m.id,error:'App message is too large.'});return;}
       busy++;
       try{const response=JSON.parse(await callback(JSON.stringify({method:m.method,args:m.args})));if(!closed)channel.port1.postMessage({id:m.id,...response});}
       catch{if(!closed)channel.port1.postMessage({id:m.id,error:'The app request could not be completed.'});}finally{busy--;}
     };
     channel.port1.start();frame.contentWindow.postMessage({type:'farmerplus-port',handshake},'*',[channel.port2]);
   };
   window.addEventListener('message',listener);
   frame.setAttribute('sandbox','allow-scripts allow-forms');frame.setAttribute('referrerpolicy','no-referrer');
   const csp=`default-src 'none'; script-src 'nonce-${nonce}'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; media-src 'none'; form-action 'none'; base-uri 'none'`;
   // The response nonce permits verified scripts under inherited host CSP.
   const content=source.replace(/<script\b[^>]*>/gi,`<script nonce="${nonce}">`);
   frame.srcdoc=content.replace(/<head>/i,`<head><meta http-equiv="Content-Security-Policy" content="${csp}"><script nonce="${nonce}">${bridge}<\/script>`);
   return {update(){if(!closed)channel?.port1.postMessage({type:'update'});},close(){closed=true;window.removeEventListener('message',listener);channel?.port1.close();frame.srcdoc='';}};
 }
 window.FarmerMiniRuntime={verify,mount};
})();
