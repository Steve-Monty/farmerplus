const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const {webcrypto}=require('node:crypto');
const source=fs.readFileSync('web/miniapp-runtime.js','utf8');
const b64=bytes=>Buffer.from(bytes).toString('base64');
test('publisher verification rejects tampered bytes and another signing key',async()=>{
 const window={};vm.runInNewContext(source,{window,crypto:webcrypto,atob,Uint8Array,TextDecoder});
 const key=await webcrypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
 const other=await webcrypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
 const bytes=Buffer.from('{"appId":"my-animals","version":1}');
 const signature=await webcrypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},key.privateKey,bytes);
 const publicKey=b64(await webcrypto.subtle.exportKey('spki',key.publicKey));
 assert.equal(await window.FarmerMiniRuntime.verify(b64(bytes),b64(signature),publicKey),bytes.toString());
 await assert.rejects(()=>window.FarmerMiniRuntime.verify(b64(Buffer.from('tampered')),b64(signature),publicKey));
 await assert.rejects(()=>window.FarmerMiniRuntime.verify(b64(bytes),b64(signature),b64(Buffer.from('invalid'))));
 const otherPublic=b64(await webcrypto.subtle.exportKey('spki',other.publicKey));
 await assert.rejects(()=>window.FarmerMiniRuntime.verify(b64(bytes),b64(signature),otherPublic));
});
test('runtime sandboxes packages and refuses a handshake from a different frame',async()=>{
 let listener,called=0;const window={addEventListener:(n,f)=>listener=f,removeEventListener(){}};
 vm.runInNewContext(source,{window,crypto:webcrypto,atob,Uint8Array,TextDecoder,MessageChannel,document:{querySelector:()=>null}});
 const attrs={},frame={setAttribute:(k,v)=>attrs[k]=v,contentWindow:{postMessage(){called++;}}};
 const handle=await window.FarmerMiniRuntime.mount(frame,'<html><head></head><script>run()</script></html>',()=>{});
 assert.equal(attrs.sandbox,'allow-scripts allow-forms');assert.match(frame.srcdoc,/connect-src 'none'/);assert.match(frame.srcdoc,/<script nonce=/);
 listener({source:{},data:{type:'farmerplus-ready'}});assert.equal(called,0);
 handle.close();assert.equal(frame.srcdoc,'');
});

test('only the bound mini-app port can report interaction to the host',async()=>{
 let listener,port,events=[];const window={addEventListener:(n,f)=>listener=f,removeEventListener(){}};
 class Channel {constructor(){this.port1=port={start(){},close(){},postMessage(){}};this.port2={};}}
 vm.runInNewContext(source,{window,crypto:webcrypto,atob,Uint8Array,TextDecoder,MessageChannel:Channel,document:{querySelector:()=>null}});
 const frame={setAttribute(){},contentWindow:{postMessage(){}}};
 const handle=await window.FarmerMiniRuntime.mount(frame,'<html><head></head></html>',async raw=>{events.push(JSON.parse(raw));return '{}';});
 const handshake=frame.srcdoc.match(/handshake:"([^"]+)"/)[1];
 listener({source:{},data:{type:'farmerplus-ready',handshake}});assert.equal(port,undefined);
 listener({source:frame.contentWindow,data:{type:'farmerplus-ready',handshake}});
 await port.onmessage({data:{type:'activity'}});assert.deepEqual(events,[{method:'activity',args:{}}]);
 assert.match(frame.srcdoc,/e.isTrusted/);handle.close();
});
