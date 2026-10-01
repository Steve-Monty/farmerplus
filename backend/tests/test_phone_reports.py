from uuid import uuid4
from sqlalchemy import select,func
from phone_reports import reports
from test_admin_workspace import workspace

def body(device=None):
    return {'schemaVersion':1,'reportId':str(uuid4()),'deviceId':device or str(uuid4()),'capturedAt':1789543000000,
            'technical':{'model':'Test phone','androidId':'0123456789abcdef','phoneIdentifier':'0123456789abcdef','versionCode':4016,'networkMetered':False},'permissions':{'camera':'denied'}}

def test_ack_replay_content_and_scope(workspace,monkeypatch):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    monkeypatch.setattr(app.state.oidc,'resource_identity',lambda r:{'id':fi['owner'],'admin':False})
    b=body();first=farmer.post('/sync/phone-report',json=b)
    assert first.status_code==200,first.text
    assert first.json()['ack']=='y' and first.json()['owner']==fi['owner']
    assert farmer.post('/sync/phone-report',json=b).json()==first.json()
    assert farmer.post('/sync/phone-report',json={**b,'technical':{'model':'Changed'}}).status_code==409
    assert farmer.post('/sync/phone-report',json=body(b['deviceId'])).status_code==429
    route='/admin/api/v2/farmers/'+fi['owner']+'/phones'
    result=admin.get(route).json();assert result['total']==1
    assert result['reports'][0]['technical']['androidId']=='0123456789abcdef'
    assert result['reports'][0]['technical']['networkMetered'] is False
    assert 'local' not in result['reports'][0]
    assert other.get(route).status_code==403
    assert farmer.get(route).status_code==403
    assert admin.get(route+'?page=2').json()['reports']==[]
    with app.state.engine.connect() as db:assert db.scalar(select(func.count()).select_from(reports))==1

def test_only_allowed_technical_fields_and_farmer_identity(workspace,monkeypatch):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    monkeypatch.setattr(app.state.oidc,'resource_identity',lambda r:{'id':fi['owner'],'admin':False})
    for patch in [{'technical':{'password':'secret'}},{'local':{'records':10}},{'owner':oi['owner']},{'permissions':{'contacts':'granted'}},{'technical':{'model':'x'*513}}]:
        assert farmer.post('/sync/phone-report',json={**body(),**patch}).status_code==422
    monkeypatch.setattr(app.state.oidc,'resource_identity',lambda r:{'id':ai['owner'],'admin':True})
    assert admin.post('/sync/phone-report',json=body()).status_code==403

def test_two_devices_remain_distinct(workspace,monkeypatch):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    monkeypatch.setattr(app.state.oidc,'resource_identity',lambda r:{'id':fi['owner'],'admin':False})
    one,two=body(),body()
    assert farmer.post('/sync/phone-report',json=one).status_code==200
    assert farmer.post('/sync/phone-report',json=two).status_code==200
    result=admin.get('/admin/api/v2/farmers/'+fi['owner']+'/phones').json()
    assert {r['deviceId'] for r in result['reports']}=={one['deviceId'],two['deviceId']}
