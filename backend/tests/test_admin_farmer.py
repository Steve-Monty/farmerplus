import json,time
from uuid import uuid4
from sqlalchemy import update,select,insert
from app import students,users
from admin_farmer import learning,inventory
from operations import staff
from test_admin_workspace import workspace
from test_api import op

def test_inventory_history_and_legacy_reports(workspace,monkeypatch):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    monkeypatch.setattr(app.state.oidc,'resource_identity',lambda r:{'id':fi['owner'],'admin':False})
    device=str(uuid4());body={'device':device,'version':'0.1.4+4015','installedApps':[{'id':'diary','version':1}],'pendingChanges':0,'conflicts':0}
    assert farmer.post('/sync/complete',json=body).status_code==200
    route='/admin/api/v2/farmers/'+fi['owner']+'/apps'
    state=admin.get(route).json();assert state['inventoryKnown'] and state['apps'][0]['installed'] and not state['apps'][0]['hasSyncedData']
    entry=op(kind='diary',data={'title':'First day'},sourceAppId='diary',deviceId=device)
    assert farmer.post('/sync/push',json=entry).status_code==200
    assert farmer.post('/sync/push',json=entry).status_code==200
    assert farmer.post('/sync/push',json={**entry,'op_id':str(uuid4()),'base_version':1,'data':{'title':'Corrected day'}}).status_code==200
    history=admin.get(route+'/diary/history').json();assert history['total']==2
    assert history['records'][0]['provenance']['device']==device
    assert admin.get(route).json()['apps'][0]['hasSyncedData']
    assert farmer.post('/sync/complete',json={'device':device,'version':'legacy'}).status_code==200
    assert admin.get(route).json()['apps'][0]['installed']
    assert farmer.post('/sync/complete',json={**body,'installedApps':[]}).status_code==200
    assert not admin.get(route).json()['apps'][0]['installed']
    assert admin.get(route).json()['apps'][0]['hasSyncedData']
    assert other.get(route).status_code==403
    assert farmer.post('/sync/push',json=op(kind='diary',data={'title':'Bad'},sourceAppId='stock')).status_code==422

def test_learning_failures_preserve_results_and_mapping_changes_clear_them(workspace,monkeypatch):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    reporting=app.state.workspace.farmer_reporting;owner=fi['owner']
    with app.state.engine.begin() as db:db.execute(update(students).where(students.c.owner==owner).values(moodle_id=42))
    monkeypatch.setenv('FARMER_MOODLE_REPORT_TOKEN','synthetic-test-token')
    reporting.ensure(owner,42)
    monkeypatch.setattr(reporting,'fetch',lambda mid:[{'id':1,'name':'Course','completed':True,'progress':100}])
    reporting.refresh(owner,42);assert reporting.read(owner)['courses'][0]['completed']
    monkeypatch.setattr(reporting,'fetch',lambda mid:(_ for _ in ()).throw(RuntimeError('secret provider error')))
    reporting.refresh(owner,42);result=reporting.read(owner)
    assert result['error'] and result['courses'][0]['completed'] and 'secret' not in json.dumps(result)
    with app.state.engine.begin() as db:db.execute(update(students).where(students.c.owner==owner).values(moodle_id=43))
    assert reporting.read(owner)['courses']==[]
    assert farmer.get('/admin/api/v2/farmers/'+owner+'/learning').status_code==403
    with app.state.engine.begin() as db:db.execute(insert(staff).values(owner=ai['owner'],role='support'))
    assert admin.post('/admin/api/v2/farmers/'+owner+'/learning/refresh').status_code==403

def test_cross_tenant_reporting_is_denied(workspace):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    from test_api import account
    manager,mi=account(app,'report-manager')
    assert admin.post('/admin/api/platform/bootstrap').status_code==200
    tenant=admin.post('/admin/api/tenants',json={'name':'Other org','slug':'other-org','platform_bps':0}).json()['id']
    admin.put('/tenants/'+tenant+'/members',json={'owner':mi['owner'],'role':'admin'})
    for suffix in ['apps','apps/diary/history','apps/coop/history','learning','sharing','classification','notifications']:
        assert manager.get('/admin/api/v2/farmers/'+fi['owner']+'/'+suffix+'?tenant='+tenant).status_code==404
