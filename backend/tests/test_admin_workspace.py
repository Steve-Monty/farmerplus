import csv
import io
import json
from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import insert,update,select,func
from app import create_app,users,records
from test_api import account,op
from operations import staff
from admin_workspace import deliveries,snapshots
from admin_providers import observations
from tenancy import members

@pytest.fixture
def workspace(tmp_path):
    app=create_app(data_dir=tmp_path,testing=True)
    admin,ai=account(app,'release-admin');farmer,fi=account(app,'release-farmer');other,oi=account(app,'another-owner')
    with app.state.engine.begin() as db:db.execute(update(users).where(users.c.id==ai['owner']).values(admin=True))
    farm=op(kind='farm',data={'name':'River maize','country':'South Africa','points':[{'lat':-25,'lon':28},{'lat':-25,'lon':28.01},{'lat':-24.99,'lon':28.01},{'lat':-24.99,'lon':28}],'manualAreaHa':90})
    assert farmer.post('/sync/push',json=farm).status_code==200
    yield app,admin,farmer,other,ai,fi,oi,farm
    app.state.engine.dispose()

def test_scoped_summary_search_map_and_hex(workspace):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    assert TestClient(app).get('/admin/api/v2/context').status_code==401
    assert farmer.get('/admin/api/v2/overview').status_code==403
    totals=admin.get('/admin/api/v2/overview').json()['totals']
    assert totals['farmers']==2 and totals['farms']==1 and totals['mappedFarms']==1 and 110<totals['mappedHa']<113
    assert totals['declaredHa']==90 and totals['neverSynced']==2
    assert admin.get('/admin/api/v2/farmers?q=River%20maize').json()['total']==1
    result=admin.get('/admin/api/v2/map?layer=hex').json()
    assert result['features'][0]['properties']['count']==1
    assert result['features'][0]['geometry']['type']=='Polygon'
    assert admin.get('/admin/api/v2/map?bbox=nan,0,2,3').status_code==422
    assert admin.get('/admin/api/v2/farmers?bbox=0,0,1,1').json()['total']==0
    assert admin.get('/admin/api/v2/export?bbox=0,0,1,1').text.count('\n')==1
    assert 'River maize' in admin.get('/admin/api/v2/farmers/'+fi['owner']).text

def test_tenant_admin_cannot_cross_scope(workspace):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    manager,mi=account(app,'organisation-manager')
    assert admin.post('/admin/api/platform/bootstrap').status_code==200
    second=admin.post('/admin/api/tenants',json={'name':'Separate','slug':'separate','platform_bps':0}).json()['id']
    assert admin.put('/tenants/'+second+'/members',json={'owner':mi['owner'],'role':'admin'}).status_code==200
    with app.state.engine.begin() as db:
        db.execute(update(members).where(members.c.owner==mi['owner'],members.c.tenant=='farmerplus').values(active=False))
    context=manager.get('/admin/api/v2/context').json();assert context['scope']==second and not context['platform']
    assert manager.get('/admin/api/v2/farmers/'+fi['owner']).status_code==404
    assert manager.get('/admin/api/v2/overview?tenant=all').status_code==403
    assert manager.post('/admin/api/v2/work',json={'title':'Cross-scope','owner':fi['owner']}).status_code==404
    assert manager.post('/admin/api/v2/campaigns',json={'title':'No','body':'No','recipients':[fi['owner']]}).status_code==404
    assert manager.get('/admin').status_code==200

def test_support_read_only_and_task_revisions(workspace):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    body={'title':'Review mapping','owner':fi['owner'],'farm':farm['id'],'due':'2026-09-30'}
    created=admin.post('/admin/api/v2/work',json=body);assert created.status_code==201
    row=created.json();body['revision']=1;body['status']='Resolved'
    assert admin.put('/admin/api/v2/work/'+row['id'],json=body).status_code==200
    assert admin.put('/admin/api/v2/work/'+row['id'],json=body).status_code==409
    with app.state.engine.begin() as db:db.execute(insert(staff).values(owner=ai['owner'],role='support'))
    assert admin.get('/admin/api/v2/overview').status_code==200
    assert admin.post('/admin/api/v2/work',json={'title':'Forbidden'}).status_code==403
    assert admin.post('/admin/api/v2/query',json={'question':'Show unmapped farms'}).json()['supported']
    assert admin.put('/admin/api/v2/sources/rainfall',json={'enabled':True}).status_code==403


def test_saved_views_preserve_state_and_are_private(workspace):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    values={'q':'River maize','bbox':'28,-25,29,-24','view':'atlas','layer':'hex','sort':'mappedHa','direction':'desc','page':2,'columns':['identity','area']}
    response=admin.post('/admin/api/v2/views',json={'name':'Private land view','filters':values})
    assert response.status_code==201
    saved=admin.get('/admin/api/v2/views').json()['views'][0]
    assert saved['id']==response.json()['id'] and saved['filters']==values
    with app.state.engine.begin() as db:db.execute(update(users).where(users.c.id==oi['owner']).values(admin=True))
    assert other.get('/admin/api/v2/views').json()['views']==[]
    assert admin.post('/admin/api/v2/views',json={'name':'Invalid','filters':{'page':-1}}).status_code==422

def test_campaign_send_replay_and_ack_is_per_record(workspace,monkeypatch):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    key=admin.post('/admin/api/v2/campaigns',json={'title':'Field visit','body':'Please review your farm boundary.','recipients':[fi['owner']]}).json()['id']
    with ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(lambda _:admin.post('/admin/api/v2/campaigns/'+key+'/send').status_code,range(2)))
    assert results==[200,200]
    assert len(farmer.get('/sync/pull').json()['records'])==3
    listing=admin.get('/admin/api/v2/campaigns').json()['campaigns'][0]
    assert listing['delivery']==dict(queued=1,delivered=0,read=0)
    monkeypatch.setattr(app.state.oidc,'resource_identity',lambda req:{'id':fi['owner'],'admin':False})
    with app.state.engine.connect() as db:receipt=db.execute(select(deliveries)).mappings().first()
    report={'device':str(uuid4()),'version':'1.0+1'}
    assert farmer.post('/sync/complete',json=report).status_code==200
    assert admin.get('/admin/api/v2/campaigns').json()['campaigns'][0]['delivery']['delivered']==0
    report['receivedInboxIds']=[receipt['record']]
    assert farmer.post('/sync/complete',json=report).status_code==200
    assert admin.get('/admin/api/v2/campaigns').json()['campaigns'][0]['delivery']['delivered']==1
    assert other.get('/sync/pull').json()['records']==[]

def market_csv(**changes):
    row=dict(observedAt='2026-09-14',metric='Wholesale price',value='3200',unit='ZAR/tonne',source='Test licensed feed',licence='Fixture only',resolution='Market grade quote',quality='Synthetic test',commodity='White maize',market='Test SA market',grade='WM1',currency='ZAR',country='South Africa')|changes
    text=io.StringIO();writer=csv.DictWriter(text,fieldnames=row.keys());writer.writeheader();writer.writerow(row);return text.getvalue()

def test_source_import_validates_previews_and_deduplicates(workspace):
    app,admin,*_=workspace
    route='/admin/api/v2/sources/markets/import'
    preview=admin.post(route,json={'csv':market_csv()}).json();assert preview['valid'] and preview['count']==1
    assert admin.get('/admin/api/v2/observations?provider=markets').json()['observations']==[]
    assert admin.post(route,json={'csv':market_csv(),'commit':True}).json()['added']==1
    assert admin.post(route,json={'csv':market_csv(),'commit':True}).json()['duplicates']==1
    assert not admin.post(route,json={'csv':market_csv(value='NaN'),'commit':True}).json()['valid']
    assert not admin.post(route,json={'csv':market_csv(country='Kenya'),'commit':True}).json()['valid']
    rows=admin.get('/admin/api/v2/observations?provider=markets').json()['observations'];assert len(rows)==1
    assert rows[0]['data']['value']==3200 and rows[0]['data']['country']=='South Africa'
    assert admin.get('/admin/api/v2/sources/markets/template').status_code==200

def test_provider_off_until_enabled_and_credentials_never_returned(workspace,monkeypatch):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    for key in ['FARMER_OPENMETEO_KEY','FARMER_COPERNICUS_CLIENT_ID','FARMER_COPERNICUS_CLIENT_SECRET']:monkeypatch.delenv(key,raising=False)
    assert admin.put('/admin/api/v2/sources/weather',json={'enabled':True}).status_code==409
    assert admin.post('/admin/api/v2/sources/rainfall/refresh',json={'owner':fi['owner'],'farm':farm['id'],'period':'2026-08'}).status_code==409
    assert admin.put('/admin/api/v2/sources/rainfall',json={'enabled':True}).status_code==200
    monkeypatch.setattr(app.state.providers,'raster',lambda *args:28.5)
    result=admin.post('/admin/api/v2/sources/rainfall/refresh',json={'owner':fi['owner'],'farm':farm['id'],'period':'2026-08'})
    assert result.status_code==200 and result.json()['added']==1
    monkeypatch.setenv('FARMER_OPENMETEO_KEY','synthetic-do-not-expose')
    assert 'synthetic-do-not-expose' not in admin.get('/admin/api/v2/sources').text
    assert admin.post('/admin/api/v2/sources/rainfall/refresh',json={'owner':oi['owner'],'farm':farm['id'],'period':'2026-08'}).status_code==422

def test_report_snapshots_are_scope_totals_not_filter_totals(workspace):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    assert admin.post('/admin/api/v2/reports',json={'name':'Only river farms','filters':{'q':'River'},'hours':24}).status_code==201
    result=admin.post('/admin/api/v2/reports/run');assert result.json()==dict(completed=1,failed=0)
    report=admin.get('/admin/api/v2/reports').json()['exports'][0]
    content=admin.get('/admin/api/v2/reports/'+report['id']+'/download').text
    assert 'release-farmer' in content and 'another-owner' not in content
    assert admin.get('/admin/api/v2/overview').json()['history'][0]['farmers']==2
    assert admin.post('/admin/api/v2/reports/run').json()['completed']==0
    with app.state.engine.begin() as db:db.execute(update(users).where(users.c.id==fi['owner']).values(username='=malicious'))
    assert "'=malicious" in admin.get('/admin/api/v2/export').text
