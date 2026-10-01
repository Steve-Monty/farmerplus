const {test}=require('node:test');
const assert=require('node:assert/strict');
const {controls}=require('../static/admin-map-layers.js');

test('free street basemap is the default and Google remains an explicit choice',()=>{
 const fresh=controls({});
 assert.match(fresh,/<option value="street" selected>/);
 assert.doesNotMatch(fresh,/<option value="hybrid" selected>/);
 const chosen=controls({basemap:'hybrid'});
 assert.match(chosen,/<option value="hybrid" selected>/);
});
