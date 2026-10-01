import json
import base64
from uuid import uuid4
from concurrent.futures import ThreadPoolExecutor
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import update
from app import create_app, users
from animal_rules import apply, empty_state, RuleError

@pytest.fixture
def service(tmp_path):
    app=create_app(data_dir=tmp_path,testing=True)
    yield app
    app.state.engine.dispose()

def account(app,name='animals'):
    c=TestClient(app);credentials={'username':name,'password':'Local-test-Pass123'}
    assert c.post('/auth/register',json=credentials).status_code==201
    assert c.post('/auth/login',json=credentials).status_code==200
    return c

def farm(c):
    key=str(uuid4());res=c.post('/sync/push',json={'id':key,'op_id':str(uuid4()),'kind':'farm','base_version':0,'data':{'name':'Animal farm','points':[]}})
    assert res.status_code==200,res.text
    return key

def cmd(name,payload,revision=0):
    return {'operationId':str(uuid4()),'deviceId':str(uuid4()),'schemaVersion':1,'ruleVersion':1,'expectedRevision':revision,'name':name,'payload':payload}

def group(farm_id,count=40):
    return {'id':str(uuid4()),'eventId':str(uuid4()),'farmId':farm_id,'locationId':None,'species':'chicken','name':'House 2 flock','quantity':count,'occurredOn':'2026-09-20'}

PATH='/api/v1/apps/my-animals'

def test_download_signature_chunk_resume_and_owner_isolation(service):
    a=account(service); b=account(service,'other')
    assert TestClient(service).get('/api/v1/apps').status_code==401
    listing=a.get('/api/v1/apps').json()['apps'];assert listing[0]['id']=='my-animals'
    manifest=a.get(PATH+'/releases/1/manifest').json()
    first=a.get(PATH+'/releases/1/package').json()
    assert first['total']==manifest['bytes'] and len(base64.b64decode(first['chunk']))==first['nextOffset']
    assert a.get(PATH+'/releases/1/package?offset=-1').status_code==416
    assert json.loads(base64.b64decode(manifest['signed']))['sha256']==manifest['sha256']
    assert b.get(PATH+'/records').json()['revision']==0
    assert b.get('/admin/api/v2/apps').status_code==403

def test_atomic_transfer_retry_correction_and_conflict(service):
    c=account(service);f=farm(c);g=group(f)
    created=c.post(PATH+'/commands',json=cmd('animals.createGroup',g));assert created.status_code==200,created.text
    target=str(uuid4());move=cmd('events.recordMove',{'subjectId':g['id'],'eventId':str(uuid4()),'farmId':f,'locationId':None,'destinationId':target,'newDestination':{'name':'House 3 flock'},'quantity':10,'occurredOn':'2026-09-21'},1)
    result=c.post(PATH+'/commands',json=move);assert result.status_code==200,result.text
    assert [p['count'] for p in result.json()['state']['profiles']]==[30,10]
    assert c.post(PATH+'/commands',json=move).json()==result.json()
    assert c.post(PATH+'/commands',json={**move,'payload':{**move['payload'],'quantity':9}}).status_code==409
    stale=c.post(PATH+'/commands',json=cmd('events.recordDeparture',{'subjectId':g['id'],'eventId':str(uuid4()),'quantity':31,'reason':'Sold','occurredOn':'2026-09-22'},1));assert stale.status_code==409
    invalid=c.post(PATH+'/commands',json=cmd('events.recordDeparture',{'subjectId':g['id'],'eventId':str(uuid4()),'quantity':31,'reason':'Sold','occurredOn':'2026-09-22'},2));assert invalid.status_code==422
    assert c.get(PATH+'/records').json()['revision']==2
    corrected=c.post(PATH+'/commands',json=cmd('events.correct',{'id':move['payload']['eventId'],'replacement':{'quantity':5},'correctionReason':'Counted twice'},2));assert corrected.status_code==200,corrected.text
    assert [p['count'] for p in corrected.json()['state']['profiles']]==[35,5]
    assert len(corrected.json()['state']['events'][1]['revisions'])==1
    blocked=c.post(PATH+'/commands',json=cmd('events.void',{'id':g['eventId'],'correctionReason':'Test dependency'},3));assert blocked.status_code==422
    # Legacy clients never receive new app data.
    assert [r['kind'] for r in c.get('/sync/pull').json()['records']]==['farm']

def test_foreign_farm_invalid_counts_dates_tags(service):
    a=account(service);b=account(service,'second');f=farm(a)
    assert b.post(PATH+'/commands',json=cmd('animals.createGroup',group(f))).status_code==422
    for value in [0,-1,1.2,True,'40']:
        assert a.post(PATH+'/commands',json=cmd('animals.createGroup',group(f,value))).status_code==422
    g=group(f);g['occurredOn']='2099-01-01'
    assert a.post(PATH+'/commands',json=cmd('animals.createGroup',g)).status_code==422

def test_identify_keeps_total_and_void_preserves_audit(service):
    c=account(service);f=farm(c);g=group(f,4)
    c.post(PATH+'/commands',json=cmd('animals.createGroup',g))
    identified=cmd('animals.identifyFromGroup',{'subjectId':g['id'],'eventId':str(uuid4()),'farmId':f,'locationId':None,'quantity':1,'destinationId':str(uuid4()),'newDestination':{'name':'Hen one','tag':'H1'},'occurredOn':'2026-09-21'},1)
    r=c.post(PATH+'/commands',json=identified);assert r.status_code==200,r.text
    assert [p['count'] for p in r.json()['state']['profiles']]==[3,1]
    void=c.post(PATH+'/commands',json=cmd('events.void',{'id':identified['payload']['eventId'],'correctionReason':'Incorrect identification'},2));assert void.status_code==200,void.text
    assert [p['count'] for p in void.json()['state']['profiles']]==[4,0]
    assert void.json()['state']['events'][-1]['void']

def test_admin_release_is_immutable_and_farmer_cannot_publish(service):
    c=account(service);owner=c.get('/auth/me').json()['owner']
    with service.state.engine.begin() as db:db.execute(update(users).where(users.c.id==owner).values(admin=True))
    assert c.get('/admin/api/v2/apps').status_code==200
    assert c.post('/admin/api/v2/apps/my-animals/releases/1/retire',json={'reason':'Local test'}).status_code==200
    assert c.get(PATH+'/releases/1/package').status_code==404
    assert c.post('/admin/api/v2/apps/my-animals/releases/1/publish',json={'reason':'Local test restore'}).status_code==200
    r=c.get(PATH+'/releases/1/package').json()
    raw=base64.b64decode(r['chunk'])
    assert c.post('/admin/api/v2/apps/my-animals/releases',json={'package':base64.b64encode(raw).decode()}).status_code==409

def test_invalid_command_and_parent_deletion_are_rejected(service):
    c=account(service);f=farm(c);g=group(f)
    invalid={**g};invalid.pop('eventId')
    assert c.post(PATH+'/commands',json=cmd('animals.createGroup',invalid)).status_code==422
    assert c.post(PATH+'/commands',json=cmd('animals.createGroup',g)).status_code==200
    delete=c.post('/sync/push',json={'id':f,'op_id':str(uuid4()),'kind':'farm','base_version':1,'deleted':True,'data':{'name':'Animal farm','points':[]}})
    assert delete.status_code==422 and 'Move the animals' in delete.text
    assert not c.get('/sync/pull').json()['records'][0]['deleted']

def test_pwa_response_nonce_matches_policy_without_weakening_admin(service):
    from fastapi.responses import HTMLResponse
    @service.get('/app.html')
    def test_shell(): return HTMLResponse('<html><head></head><body>Fixture</body></html>')
    c=TestClient(service)
    response=c.get('/app.html')
    import re
    nonce=re.search(r'<meta name="farmerplus-script-nonce" content="([^"]+)">',response.text)
    assert nonce, response.status_code
    assert "'nonce-"+nonce[1]+"'" in response.headers['content-security-policy']
    assert 'script-src' in response.headers['content-security-policy']
    assert "script-src 'self' 'unsafe-inline'" not in response.headers['content-security-policy']
    assert 'farmerplus-script-nonce' not in c.get('/admin/identity').text
