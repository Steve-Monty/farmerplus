// Uses only the isolated, synthetic local account created by server_integration_test.dart.
const fs=require('node:fs');
const path=require('node:path');
const assert=require('node:assert/strict');
const {chromium}=require('playwright');
const root=path.resolve(__dirname,'../..');
const state=JSON.parse(fs.readFileSync(path.join(root,'evidence/private/e2e-state.json'),'utf8'));
const shots=path.join(root,'.impeccable/review');
(async()=>{
 const browser=await chromium.launch({headless:true,channel:'msedge'});
 const context=await browser.newContext({viewport:{width:1440,height:1000},colorScheme:'light'});
 const page=await context.newPage(),errors=[];
 page.on('pageerror',e=>errors.push(e.message));page.on('dialog',d=>d.accept());
 await page.goto(state.server);await page.locator('#auth-submit').waitFor();
 await page.screenshot({path:path.join(shots,'web-auth.png'),fullPage:true});
 await page.locator('#username').fill(state.username);await page.locator('#password').fill(state.password);
 await page.locator('#auth-submit').click();await page.locator('#workspace').waitFor({state:'visible'});
 await page.getByRole('heading',{name:'Offline irrigation check',exact:true}).click();
 await page.locator('#record-title').fill('Irrigation checked on the web');
 await page.locator('#save-record').click();await page.locator('#editor').waitFor({state:'hidden'});
 await page.getByRole('heading',{name:'Irrigation checked on the web',exact:true}).waitFor();
 await page.screenshot({path:path.join(shots,'web-desktop.png'),fullPage:true});
 // Keep a draft on HTTP failure and retry the same edit.
 await page.locator('#new-record').click();await page.locator('#record-title').fill('Test draft and conflict');
 await page.route('**/sync/push',route=>route.abort('failed'));
 await page.locator('#save-record').click();await page.locator('#editor-status').filter({hasText:'Save failed'}).waitFor();
 assert.equal(await page.locator('#record-title').inputValue(),'Test draft and conflict');
 await page.unroute('**/sync/push');await page.locator('#save-record').click();await page.locator('#editor').waitFor({state:'hidden'});
 await page.getByRole('heading',{name:'Test draft and conflict',exact:true}).click();
 await page.locator('#record-notes').fill('My unsaved web edit');
 const all=await (await context.request.get(state.server+'/sync/pull')).json();
 const item=all.records.find(r=>r.data.title==='Test draft and conflict');
 const result=await context.request.post(state.server+'/sync/push',{data:{id:item.id,op_id:require('node:crypto').randomUUID(),kind:item.kind,base_version:item.version,deleted:false,data:{...item.data,notes:'Concurrent phone edit'}}});assert.equal(result.status(),200);
 await page.locator('#save-record').click();await page.locator('#conflict').waitFor({state:'visible'});
 assert.equal(await page.locator('#record-notes').inputValue(),'My unsaved web edit');
 await page.screenshot({path:path.join(shots,'web-conflict.png'),fullPage:true});
 await page.locator('#keep-edit').click();await page.locator('#editor').waitFor({state:'hidden'});
 const after=await (await context.request.get(state.server+'/sync/pull')).json();assert.equal(after.records.find(r=>r.id===item.id).data.notes,'My unsaved web edit');
 // Search, catalogue separation, mapped fields and responsive bounds.
 await page.locator('#search').fill('not-present');await page.getByRole('heading',{name:'No matching records'}).waitFor();await page.locator('#search').fill('');
 await page.locator('[data-kind="catalogue"]').click();await page.getByRole('heading',{name:'Learning',exact:true}).waitFor();
 assert.match(await page.locator('#content').innerText(),/course downloads are separate/i);
 await page.locator('[data-kind="farm"]').click();await page.getByRole('heading',{name:'Test north field',exact:true}).click();assert.equal(await page.locator('#map-preview polygon').count(),1);await page.locator('#close-editor').click();
 await page.locator('[data-kind="diary"]').click();await page.setViewportSize({width:390,height:844});
 assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
 await page.screenshot({path:path.join(shots,'web-mobile.png'),fullPage:true});
 await page.emulateMedia({colorScheme:'dark'});await page.screenshot({path:path.join(shots,'web-dark.png'),fullPage:true});
 await page.getByRole('heading',{name:'Irrigation checked on the web',exact:true}).click();
 assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
 await page.screenshot({path:path.join(shots,'web-mobile-editor.png'),fullPage:true});await page.locator('#close-editor').click();
 assert.deepEqual(errors,[]);
 fs.writeFileSync(path.join(root,'artifacts/web-validation.json'),JSON.stringify({passed:true,syntheticData:true,viewports:['1440x1000','390x844'],checks:['cookie sign-in','mobile record visible','web edit persisted','failed request preserves draft','concurrent edit conflict and explicit resolution','search empty state','separate learning client/course catalogue','saved field sketch','mobile bounds','dark theme','no uncaught JavaScript errors']},null,2));
 await browser.close();console.log('Web QA passed; screenshots saved.');
})().catch(e=>{console.error(e);process.exit(1)});

