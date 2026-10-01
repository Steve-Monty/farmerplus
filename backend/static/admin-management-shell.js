'use strict';
if(location.pathname==='/admin/tenants'){
 const style=document.createElement('link');style.rel='stylesheet';style.href='/static/admin-shell.css?v=20260915.3';document.head.append(style);
 const nav=document.createElement('script');nav.src='/static/admin-navigation.js?v=20260915.3';nav.onload=()=>{const mount=document.createElement('script');mount.src='/static/admin-shell-nav.js?v=20260915.3';document.head.append(mount);};document.head.append(nav);
}
