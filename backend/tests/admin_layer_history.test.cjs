const {test}=require('node:test');const assert=require('node:assert/strict');
const {farmChart}=require('../static/admin-atlas.js');
const reading=(value,observed='2026-07-01')=>({provider:'rainfall',observed,imported:1,data:{metric:'Monthly rainfall',unit:'mm/month',value,source:'CHIRPS'}});
test('selected layer chart shows real readings including zero, not missing values',()=>{
 const html=farmChart([reading(0),reading(null,'2026-06-01')],'rainfall');
 assert(html.includes('1 readings'));assert(html.includes('<circle'));assert(html.includes('CHIRPS'));
});
test('another provider never supplies the selected layer chart',()=>{
 assert(!farmChart([reading(12)],'vegetation').includes('<circle'));
});
test('history deduplicates revised observations and escapes source names',()=>{
 const revised={...reading(22),imported:2,data:{...reading(22).data,source:'<unsafe>'}};
 const html=farmChart([reading(12),revised],'rainfall','2026-07');
 assert(html.includes('1 readings'));assert(html.includes('&lt;unsafe&gt;'));assert(html.includes('#b87516'));
});
