"""Atlas contract, scope, public providers and credential-boundary regression tests."""
import json
from datetime import datetime, timezone
import pytest
from sqlalchemy import update, insert
from fastapi.testclient import TestClient
from test_admin_workspace import workspace
from test_api import op
from admin_providers import observations, sources
from admin_workspace import stamp
from app import records, users
from operations import staff


def test_atlas_population_nearby_crop_hex_and_exports(workspace):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    data=farm['data']|{'crop':'Maize'}
    with app.state.engine.begin() as db:db.execute(update(records).where(records.c.id==farm['id']).values(data=json.dumps(data)))
    far=op(kind='farm',data={'name':'Distant wheat','country':'South Africa','crop':'Wheat','points':[{'lat':-30,'lon':20},{'lat':-30,'lon':20.01},{'lat':-29.99,'lon':20.01}]})
    assert other.post('/sync/push',json=far).status_code==200
    result=admin.get('/admin/api/v2/map').json()
    assert result['total']==2 and result['farms']==2 and result['farmers']==2
    assert set(result['crops'])=={'Maize','Wheat'}
    near={'near':'28,-25,25','kind':'farm'}
    selected=admin.get('/admin/api/v2/map',params=near).json()
    assert selected['total']==1 and selected['features'][0]['id']==farm['id']
    assert selected['features'][0]['properties']['distanceKm']<2
    assert admin.get('/admin/api/v2/farmers',params=near).json()['total']==1
    assert 'another-owner' not in admin.get('/admin/api/v2/export',params=near).text
    assert admin.get('/admin/api/v2/map',params={'crop':'maize','country':'south africa'}).json()['total']==1
    cell=selected['hexagons'][0]['id']
    for route in ['map','map/export']:
        response=admin.get('/admin/api/v2/'+route,params={'cell':cell,'layer':'hex','resolution':5})
        assert response.status_code==200 and response.json()['features'][0]['properties']['count']==1
    assert admin.get('/admin/api/v2/farmers',params={'cell':cell}).json()['total']==1
    assert 'another-owner' not in admin.get('/admin/api/v2/export',params={'cell':cell}).text
    assert admin.get('/admin/api/v2/map',params={'cell':'not-a-cell'}).status_code==422
    for value in ['nan,0,25','28,-25,0','28,-25,501','28,99,20']:
        assert admin.get('/admin/api/v2/map',params={'near':value}).status_code==422
    assert admin.get('/admin/api/v2/map',params={'near':'28,-25,25','bbox':'0,0,1,1'}).json()['total']==0


def test_new_private_saved_filters_and_public_source_catalog(workspace,monkeypatch):
    app,admin,*_=workspace
    for name in ['FARMER_GEOAPIFY_KEY','FARMER_FIRMS_MAP_KEY']:monkeypatch.delenv(name,raising=False)
    catalogs={s['id']:s for s in admin.get('/admin/api/v2/sources').json()['sources']}
    assert all(catalogs[p]['configured'] and not catalogs[p]['enabled'] for p in ['rainfall','water','climate'])
    assert not catalogs['places']['configured'] and catalogs['places']['registerUrl']=='https://myprojects.geoapify.com/'
    values={'near':'28,-25,25','cell':'8566e433fffffff','mode':'heat','resolution':'5','period':'2026-06','crop':'Maize','view':'overview'}
    assert admin.post('/admin/api/v2/views',json={'name':'My private region','filters':values}).status_code==201
    assert admin.get('/admin/api/v2/views').json()['views'][0]['filters']==values
    assert admin.get('/admin/api/v2/sources/places/template').status_code==422


def test_geoapify_disabled_authentication_proxy_cache_and_secret_redaction(workspace,monkeypatch):
    app,admin,farmer,other,ai,*_=workspace
    monkeypatch.delenv('FARMER_GEOAPIFY_KEY',raising=False)
    route='/admin/api/v2/places'
    assert TestClient(app).post(route,json={'text':'Pretoria'}).status_code==401
    assert farmer.post(route,json={'text':'Pretoria'}).status_code==403
    assert admin.post(route,json={'text':'Pretoria'}).status_code==409
    monkeypatch.setenv('FARMER_GEOAPIFY_KEY','synthetic-private-key')
    assert admin.put('/admin/api/v2/sources/places',json={'enabled':True}).status_code==200
    calls=[]
    class Reply:
        def raise_for_status(self):pass
        def json(self):return {'results':[{'formatted':'Pretoria, South Africa','lon':28.2,'lat':-25.75,'country':'South Africa','apiKey':'must-not-be-returned'}]}
    class Client:
        def __init__(self,**kw):assert kw['follow_redirects'] is False
        def __enter__(self):return self
        def __exit__(self,*args):pass
        def get(self,url,**kw):calls.append((url,kw));return Reply()
    monkeypatch.setattr('admin_providers.httpx.Client',Client)
    result=admin.post(route,json={'text':'Pretoria'})
    assert result.status_code==200 and result.json()['places'][0]['lon']==28.2
    assert 'private-key' not in result.text and 'must-not-be-returned' not in result.text
    assert calls[0][0]=='https://api.geoapify.com/v1/geocode/autocomplete'
    assert calls[0][1]['params']['apiKey']=='synthetic-private-key'
    assert admin.post(route,json={'text':'Pretoria'}).status_code==200 and len(calls)==1
    assert admin.post(route,json={'text':'https://attacker.example','url':'https://attacker.example'}).status_code==422
    with app.state.engine.begin() as db:db.execute(insert(staff).values(owner=ai['owner'],role='support'))
    assert admin.post(route,json={'text':'Pretoria'}).status_code==200
    assert 'synthetic-private-key' not in admin.get('/admin/api/v2/sources').text


def test_power_cache_units_missing_values_and_invalid_period(workspace,monkeypatch):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    assert admin.put('/admin/api/v2/sources/climate',json={'enabled':True}).status_code==200
    calls=[]
    class Reply:
        def raise_for_status(self):pass
        def json(self):return {'header':{'fill_value':-999},'properties':{'parameter':{'T2M':{'20260601':14.4,'20260602':-999,'20260603':None},'ALLSKY_SFC_SW_DWN':{'20260601':15.3}}},'parameters':{'T2M':{'units':'C'},'ALLSKY_SFC_SW_DWN':{'units':'MJ/m^2/day'}}}
    class Client:
        def __init__(self,**kw):pass
        def __enter__(self):return self
        def __exit__(self,*args):pass
        def get(self,url,**kw):calls.append(kw['params']);return Reply()
    monkeypatch.setattr('admin_providers.httpx.Client',Client)
    body={'owner':fi['owner'],'farm':farm['id'],'period':'2026-06'}
    result=admin.post('/admin/api/v2/sources/climate/refresh',json=body)
    assert result.status_code==200 and result.json()['added']==2
    assert admin.post('/admin/api/v2/sources/climate/refresh',json=body).json()['duplicates']==2
    assert len(calls)==1 and calls[0]['longitude']==28 and calls[0]['latitude']==-25
    rows=admin.get('/admin/api/v2/observations',params={'provider':'climate'}).json()['observations']
    assert {r['data']['unit'] for r in rows}=={'C','MJ/m^2/day'}
    assert all(r['data']['referenceLon']==28 for r in rows)
    assert admin.post('/admin/api/v2/sources/climate/refresh',json=body|{'period':'2026-99'}).status_code==422
    assert admin.post('/admin/api/v2/sources/climate/refresh',json=body|{'period':'1983-01'}).status_code==422


def test_map_observation_period_scope_and_redaction(workspace):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    def observation(scope,owner,at,key):return {'id':key,'scope':scope,'provider':'rainfall','owner':owner,'farm':farm['id'],'observed':at,'imported':stamp(),'data':json.dumps({'metric':'Monthly rainfall','value':7,'unit':'mm/month','source':'Synthetic fixture','observedAt':at})}
    with app.state.engine.begin() as db:
        db.execute(insert(observations),[observation('all',fi['owner'],'2026-06-01T00:00:00+00:00','a'),observation('all',fi['owner'],'2026-07-01T00:00:00+00:00','b'),observation('separate',fi['owner'],'2026-06-01T00:00:00+00:00','c'),observation('all','revoked-owner','2026-06-01T00:00:00+00:00','d')])
    rows=admin.get('/admin/api/v2/map/observations',params={'provider':'rainfall','period':'2026-06'}).json()['observations']
    assert [r['id'] for r in rows]==['a']
    assert farmer.get('/admin/api/v2/map/observations?provider=rainfall').status_code==403
    assert admin.get('/admin/api/v2/map/observations?provider=rainfall&period=bad').status_code==422
