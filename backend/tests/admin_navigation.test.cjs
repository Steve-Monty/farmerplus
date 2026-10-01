const {test}=require('node:test');const assert=require('node:assert/strict');
const nav=require('../static/admin-navigation.js');const fs=require('node:fs');
test('top navigation contains the map-first entry and grouped Operations and Management',()=>{
 const html=nav.markup(true);
 for(const text of ['Operations map','Farmers &amp; land','Operations','Management','Work queue','Data quality','Data &amp; integrations','Accounts &amp; access'])assert(html.includes(text),text);
 assert(!html.includes('data-nav="atlas"'));
 assert.equal((html.match(/<nav /g)||[]).length,1);assert.equal((html.match(/<details /g)||[]).length,3);
 assert(html.includes('href="#overview"'));assert(html.includes('admin-wordmark.png'));assert(!html.includes('<select'));
 assert(html.includes('id="admin-logout"'));assert(html.includes('Sign out'));
 const ids=[...html.matchAll(/\bid="([^"]+)"/g)].map(m=>m[1]);assert.equal(ids.length,new Set(ids).size);
});
test('account-menu sign out posts to the server and opens the administrator login',async()=>{
 const calls=[],redirects=[],removed=[];
 await nav.signOut(async(url,options)=>{calls.push([url,options]);return {ok:true,status:200};},url=>redirects.push(url),{removeItem:key=>removed.push(key)});
 assert.equal(calls[0][0],'/auth/logout');assert.equal(calls[0][1].method,'POST');assert.equal(calls[0][1].credentials,'same-origin');
 assert.deepEqual(redirects,['/admin/identity']);assert.deepEqual(removed,['admin-return']);
});
test('management navigation links return to the dashboard without replacing internal views',()=>{
 const html=nav.markup(false);assert(html.includes('href="/admin#overview"'));assert(html.includes('href="/admin#work"'));assert(html.includes('href="/admin/tenants"'));
});
test('admin entry has no organisation dropdown or sidebar, and navigation loads before startup',()=>{
 const html=fs.readFileSync(require.resolve('../static/admin.html'),'utf8');assert(!html.includes('id="sidebar"'));assert(!html.includes('<select id="scope"'));assert(html.includes('type="hidden" id="scope"'));assert(html.indexOf('/static/admin-navigation.js')<html.indexOf('/static/admin.js'));
 assert(html.includes('rel="icon" href="/static/favicon.svg"'));
});
