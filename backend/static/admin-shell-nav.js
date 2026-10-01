'use strict';
// Preserve the separately authorised management tools as a secondary navigation.
(function(){
 const old=document.querySelector('aside');if(!old||!window.AdminNavigation)return;
 const main=document.querySelector('main'),internal=old.querySelector('nav');
 document.body.classList.add('management-surface');main?.classList.add('admin-main');
 for(const id of ['menu-toggle','workspace-name']){const retained=old.querySelector('#'+id);if(retained){retained.hidden=true;main?.prepend(retained);}}
 if(internal){internal.classList.add('admin-subnav');internal.setAttribute('aria-label',location.pathname.includes('identity')?'Account tools':'Organisation tools');main?.prepend(internal);}
 const header=document.createElement('header');header.id='admin-topnav';old.replaceWith(header);AdminNavigation.mount(header,false);
})();
