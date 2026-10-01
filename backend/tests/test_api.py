import base64
import hashlib
from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import update, select
from app import create_app, users, sessions
from geometry import contains as polygon_contains

def poly(xy):return [{'lon':x*.001,'lat':y*.001} for x,y in xy]

def test_nested_boundary_api_and_parent_edit(service):
    c,_=account(service,'boundary')
    parent=poly([(0,0),(4,0),(4,4),(3,4),(3,1),(1,1),(1,4),(0,4)])
    inner=poly([(0,0),(1,0),(1,1),(0,1)])
    bridge=poly([(.5,2),(3.5,2),(3.5,3),(.5,3)])
    polygon_contains(parent,inner)
    with pytest.raises(ValueError,match='edge'):polygon_contains(parent,bridge)
    farm=op(kind='farm',data={'name':'Test farm','points':parent})
    assert c.post('/sync/push',json=farm).status_code==200
    field=op(kind='field',data={'name':'Test field','farmId':farm['id'],'points':inner,'areaM2':999})
    result=c.post('/sync/push',json=field)
    assert result.status_code==200 and result.json()['record']['data']['areaM2']!=999
    for points in [bridge,poly([(5,0),(6,0),(6,1)]),[inner[0],inner[2],inner[1],inner[3]]]:
        assert c.post('/sync/push',json=op(kind='field',data={**field['data'],'points':points})).status_code==422
    assert c.post('/sync/push',json=op(kind='field',data={**field['data'],'farmId':str(uuid4())})).status_code==422
    assert c.post('/sync/push',json=op(id=farm['id'],kind='farm',base_version=1,data={'name':'Shrink','points':poly([(2,0),(4,0),(4,1),(2,1)])})).status_code==422
    assert c.post('/sync/push',json=op(id=farm['id'],kind='farm',base_version=1,data=farm['data'],deleted=True)).status_code==422
    saved=c.get('/sync/pull').json()['records']
    assert len(saved)==2 and all(r['version']==1 for r in saved)
    other,_=account(service,'otherboundary')
    assert other.post('/sync/push',json=op(kind='field',data=field['data'])).status_code==422

@pytest.fixture
def service(tmp_path):
    app=create_app(data_dir=tmp_path,testing=True)
    yield app
    app.state.engine.dispose()

def account(app,name):
    c=TestClient(app)
    creds={'username':name,'password':'Local-test-only-passphrase!'}
    assert c.post('/auth/register',json=creds).status_code==201
    result=c.post('/auth/login',json=creds)
    assert result.status_code==200
    return c,result.json()

def op(**values):
    return {'id':str(uuid4()),'op_id':str(uuid4()),'kind':'diary','data':{'title':'Test activity'},'base_version':0,'deleted':False,**values}

def test_identity_isolation_retry_conflict_and_tombstone(service):
    a,identity=account(service,'first');b,_=account(service,'second')
    assert TestClient(service).get('/sync/pull').status_code==401
    operation=op();first=a.post('/sync/push',json=operation)
    assert first.status_code==200
    assert a.post('/sync/push',json=operation).json()==first.json()
    assert a.post('/sync/push',json={**operation,'data':{'title':'Different'}}).status_code==409
    assert b.get('/sync/pull').json()['records']==[]
    assert b.post('/sync/push',json=op(id=operation['id'])).json()['record']['version']==1
    changed=op(id=operation['id'],base_version=1,data={'title':'Web change'})
    assert a.post('/sync/push',json=changed).json()['record']['version']==2
    conflict=a.post('/sync/push',json=op(id=operation['id'],base_version=1)).json()
    assert conflict['conflict'] and conflict['record']['data']['title']=='Web change'
    deleted=a.post('/sync/push',json=op(id=operation['id'],base_version=2,deleted=True)).json()
    assert deleted['record']['deleted'] and deleted['record']['version']==3
    assert a.get('/sync/pull').json()['records'][0]['deleted']
    with service.state.engine.connect() as db:
        assert db.execute(select(sessions.c.hash)).first()[0]!=identity['token']
    assert a.post('/auth/logout').status_code==200
    assert a.get('/sync/pull').status_code==401
    assert b.get('/sync/pull').status_code==200

def test_simultaneous_edits_have_one_winner(service):
    c,identity=account(service,'concurrent')
    item=op();c.post('/sync/push',json=item)
    def edit(i):
        with TestClient(service) as client:
            return client.post('/sync/push',headers={'Authorization':'Bearer '+identity['token']},json=op(id=item['id'],base_version=1,data={'title':str(i)})).json()
    with ThreadPoolExecutor(2) as pool:results=list(pool.map(edit,[1,2]))
    assert sorted(r['conflict'] for r in results)==[False,True]
    assert c.get('/sync/pull').json()['records'][0]['version']==2

def test_media_resume_integrity_and_owner_scope(service):
    a,_=account(service,'mediaa');b,_=account(service,'mediab')
    raw=b'fixture-only-attachment'*10000;sha=hashlib.sha256(raw).hexdigest()
    def part(start,end):return {'offset':start,'total':len(raw),'chunk':base64.b64encode(raw[start:end]).decode()}
    assert a.put('/media/'+sha,json=part(0,100000)).json()['bytes']==100000
    assert a.put('/media/'+sha,json=part(0,100000)).json()['bytes']==100000
    assert a.get('/media/'+sha).status_code==404
    assert a.put('/media/'+sha,json=part(100001,200000)).status_code==409
    assert a.put('/media/'+sha,json=part(100000,200000)).status_code==200
    assert a.put('/media/'+sha,json=part(200000,len(raw))).json()['complete']
    assert b.get('/media/'+sha).status_code==404
    assert b.get('/media/'+sha+'/status').json()=={'bytes':0,'complete':False}
    data={'title':'Attached','media':[{'hash':sha,'type':'audio/wav'}]}
    assert a.post('/sync/push',json=op(data=data)).status_code==200
    assert b.post('/sync/push',json=op(data=data)).status_code==422
    received=b''
    while len(received)<len(raw):received+=base64.b64decode(a.get('/media/'+sha+'?offset='+str(len(received))).json()['chunk'])
    assert received==raw
    bad='a'*64
    assert a.put('/media/'+bad,json={'offset':0,'total':3,'chunk':'YWJj'}).status_code==422
    assert a.get('/media/'+bad+'/status').json()['bytes']==0

def test_boundaries_and_learning_authority(service):
    c,_=account(service,'validation')
    assert c.post('/sync/push',json=op(),headers={'Origin':'https://elsewhere.example'}).status_code==403
    assert c.post('/sync/push',json=op(),headers={'Sec-Fetch-Site':'cross-site'}).status_code==403
    assert c.post('/sync/push',content=b'x'*210001).status_code==413
    assert c.post('/sync/push',content=iter([b'x'*100000,b'y'*110001])).status_code==413
    assert c.post('/sync/push',json=op(data={'notes':'x'*16001})).status_code==422
    assert c.post('/sync/push',json=op(kind='field',data={'points':[{'lat':999,'lon':1}]*3})).status_code==422
    assert c.post('/sync/push',json=op(kind='progress',data={'officialGrade':100})).status_code==422
    result=c.post('/sync/push',json=op(kind='progress',data={'lessons':[0],'authority':'official'})).json()
    assert result['record']['data']['authority']=='local-evidence'
    assert c.get('/learning/status').json()['officialResults'] is None
    assert "frame-ancestors 'none'" in c.get('/').headers['content-security-policy']

def test_provider_admin_dedup_and_packages(service):
    c,identity=account(service,'provider');recipient,target=account(service,'recipient')
    message={'owner':target['owner'],'event_id':str(uuid4()),'source':'Test provider','title':'Lesson ready','action':'Read lesson','route':'learning:sample-records:0'}
    assert c.post('/admin/messages',json=message).status_code==403
    with service.state.engine.begin() as db:db.execute(update(users).where(users.c.id==identity['owner']).values(admin=True))
    first=c.post('/admin/messages',json=message).json()
    assert not first['deduplicated']
    record=first['record'];data={**record['data'],'read':True}
    assert recipient.post('/sync/push',json=op(id=record['id'],kind='inbox',base_version=1,data=data)).status_code==200
    again=c.post('/admin/messages',json=message).json()
    assert again['deduplicated'] and again['record']['data']['read']
    assert c.post('/admin/messages',json={**message,'title':'Different'}).status_code==409
    catalogue=recipient.get('/catalogue').json()['packages']
    assert {'learning','sample-records'} <= {p['id'] for p in catalogue}
    for package in catalogue:
        data=recipient.get(f"/packages/{package['id']}/{package['version']}").json()
        assert hashlib.sha256(base64.b64decode(data['chunk'])).hexdigest()==package['sha256']
        assert package['executable'] is False
    assert c.patch('/admin/packages/diary/1?active=false').status_code==200
    assert recipient.get('/packages/diary/1').status_code==404

def test_restart_keeps_account_records_and_receipts(tmp_path):
    first=create_app(data_dir=tmp_path,testing=True);c,identity=account(first,'restart')
    operation=op();result=c.post('/sync/push',json=operation).json();first.state.engine.dispose()
    second=create_app(data_dir=tmp_path,testing=True)
    with TestClient(second) as client:
        headers={'Authorization':'Bearer '+identity['token']}
        assert client.get('/sync/pull',headers=headers).json()['records'][0]['id']==operation['id']
        assert client.post('/sync/push',headers=headers,json=operation).json()==result
    second.state.engine.dispose()


def test_email_registration_password_change_and_redaction(service):
    c=TestClient(service)
    body={'username':'farmer@example.invalid','email':'farmer@example.invalid','password':'GoodPass'}
    for invalid in ['short','alllowercase','ALLUPPERCASE']:
        assert c.post('/auth/register',json={**body,'password':invalid}).status_code==422
    assert c.post('/auth/register',json=body).status_code==201
    auth=c.post('/auth/login',json=body).json()
    saved=c.post('/sync/push',json=op()).json()['record']
    assert c.post('/auth/change',json={'current_password':'WrongPass','password':'BetterPass'}).status_code==401
    changed=c.post('/auth/change',json={'current_password':'GoodPass','username':'newfarmer','password':'BetterPass'})
    assert changed.status_code==200 and changed.json()['owner']==auth['owner']
    assert changed.json()['signInRequired'] is True
    assert c.get('/auth/me').status_code==401
    assert c.post('/auth/login',json={'username':'newfarmer','password':'BetterPass'}).status_code==200
    assert c.get('/auth/me').json()['username']=='newfarmer'
    assert c.get('/sync/pull').json()['records'][0]['id']==saved['id']
    assert TestClient(service).post('/auth/login',json=body).status_code==401
    assert TestClient(service).post('/auth/login',json={'username':'newfarmer','password':'BetterPass'}).json()['owner']==auth['owner']
    sensitive='X'*257
    result=c.post('/auth/change',json={'current_password':sensitive})
    assert result.status_code==422 and sensitive not in result.text
    with service.state.engine.connect() as db:
        encoded=db.execute(select(users.c.password).where(users.c.id==auth['owner'])).scalar_one()
        assert 'BetterPass' not in encoded and ':' in encoded


def test_retired_learning_bridge_never_accepts_legacy_tokens(service):
    c=TestClient(service)
    for value in ['A'*32,'B'*32,'short']:
        response=c.post('/auth/moodle',json={'token':value})
        assert response.status_code==410 and 'retired' in response.json()['detail']
    assert c.get('/auth/me').status_code==401
    with service.state.engine.connect() as db:assert db.execute(select(users)).all()==[]


def test_preview_cors_is_explicit(service):
    c=TestClient(service)
    good=c.options('/auth/login',headers={'Origin':'http://127.0.0.1:8091','Access-Control-Request-Method':'POST','Access-Control-Request-Headers':'content-type'})
    assert good.status_code==200 and good.headers['access-control-allow-origin']=='http://127.0.0.1:8091'
    assert c.post('/auth/login',headers={'Origin':'https://untrusted.invalid'},json={'username':'any','password':'Secret'}).status_code==403


def test_username_registration_optional_email_and_atomic_recovery(service):
    from app import recovery, contacts
    c=TestClient(service)
    creds={'username':'recoverable','password':'OriginalPass'}
    registered=c.post('/auth/register',json=creds)
    assert registered.status_code==201
    codes=registered.json()['recoveryCodes']
    assert len(codes)==8 and len(set(codes))==8
    login=c.post('/auth/login',json=creds).json();owner=login['owner']
    saved=c.post('/sync/push',json=op()).json()['record']['id']
    with service.state.engine.connect() as db:
        rows=db.execute(select(recovery).where(recovery.c.owner==owner)).mappings().all()
        assert len(rows)==8 and all(len(r['hash'])==64 for r in rows)
        assert all(code not in str(rows) for code in codes)
        assert db.execute(select(contacts).where(contacts.c.owner==owner)).first() is None
    bad=TestClient(service).post('/auth/recover',json={'username':'recoverable','code':'invalid','password':'ReplacementPass'})
    absent=TestClient(service).post('/auth/recover',json={'username':'does-not-exist','code':'invalid','password':'ReplacementPass'})
    assert bad.status_code==absent.status_code==401 and bad.json()==absent.json()
    body={'username':'recoverable','code':codes[0],'password':'ReplacementPass'}
    def recover_once(_):return TestClient(service).post('/auth/recover',json=body).status_code
    with ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(recover_once,range(2)))
    assert sorted(results)==[200,401]
    assert c.get('/auth/me').status_code==401
    assert TestClient(service).post('/auth/login',json=creds).status_code==401
    fresh=TestClient(service)
    assert fresh.post('/auth/login',json={'username':'recoverable','password':'ReplacementPass'}).json()['owner']==owner
    assert fresh.get('/sync/pull').json()['records'][0]['id']==saved
    assert fresh.post('/auth/recover',json={**body,'code':codes[1]}).status_code==401
    assert fresh.post('/auth/recovery/reissue',json={'current_password':'wrong'}).status_code==401
    reissued=fresh.post('/auth/recovery/reissue',json={'current_password':'ReplacementPass'})
    assert reissued.status_code==200 and len(reissued.json()['recoveryCodes'])==8
    c2=TestClient(service)
    optional=c2.post('/auth/register',json={'username':'optionalcontact','password':'OptionalPass','email':'contact@example.invalid'})
    assert optional.status_code==201
    with service.state.engine.connect() as db:
        contact=db.execute(select(contacts).where(contacts.c.owner==optional.json()['owner'])).mappings().one()
        assert contact['verified'] is False


def test_recovery_rate_limit_and_secret_redaction(service):
    c=TestClient(service)
    payload={'username':'unknownuser','code':'invalid','password':'ReplacementPass'}
    for _ in range(12):assert c.post('/auth/recover',json=payload).status_code==401
    assert c.post('/auth/recover',json=payload).status_code==429
    secret='Z'*257
    response=TestClient(service).post('/auth/recover',json={**payload,'password':secret})
    assert response.status_code==422 and secret not in response.text
