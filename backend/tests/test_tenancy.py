from concurrent.futures import ThreadPoolExecutor
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import update, select, func
from app import create_app, users
from test_api import account
from tenancy import split_payment, tenants, members, wallets, transactions, entries, courses, control


@pytest.fixture
def site(tmp_path):
    app=create_app(data_dir=tmp_path,testing=True)
    root,ri=account(app,'platform-owner')
    learner,li=account(app,'student-one')
    creator,ci=account(app,'creator-one')
    manager,mi=account(app,'tenant-manager')
    stranger,si=account(app,'other-student')
    with app.state.engine.begin() as db:
        db.execute(update(users).where(users.c.id==ri['owner']).values(admin=True))
    assert root.post('/admin/api/platform/bootstrap').status_code==200
    for person,role in [(ci,'creator'),(mi,'admin')]:
        assert root.put('/tenants/farmerplus/members',json={'owner':person['owner'],'role':role}).status_code==200
    app.state.tenancy.configure_instance('farmerplus','learning-one','https://learning-one.example.test')
    yield app,root,learner,creator,manager,stranger,ri,li,ci,mi,si
    app.state.engine.dispose()


def listing(root,slug='tenant-two',bps=1000):
    return root.post('/admin/api/tenants',json={'name':slug,'slug':slug,'platform_bps':bps}).json()['id']


def course(site,tenant='farmerplus',instance='learning-one'):
    app,root,learner,creator,manager,stranger,ri,li,ci,mi,si=site
    result=root.post('/tenants/'+tenant+'/courses',json={'instance':instance,'courseid':2,
        'creator':ci['owner'],'title':'Soil lesson','price':10000,'currency':'ZAR','published':True})
    assert result.status_code==200,result.text
    return result.json()['id']


def balance(app,key):
    with app.state.engine.connect() as db:
        return db.scalar(select(wallets.c.balance).where(wallets.c.id==key)) or 0


def test_split_is_exact_and_platform_is_share_of_commission():
    assert split_payment(10000,2000,1000)==dict(price=10000,creator=8000,commission=2000,platform=200,tenant=1800)
    assert split_payment(10000,2000,0)['tenant']==2000
    for price in [0,1,3,99,10001,10**12]:
        for c,p in [(0,0),(2000,1000),(10000,10000),(3333,7777)]:
            s=split_payment(price,c,p)
            assert s['creator']+s['tenant']+s['platform']==price
    for value in [True,1.5,-1,10**12+1]:
        with pytest.raises(ValueError):split_payment(value,2000,1000)


def test_unpublish_preserves_entitlement_and_stops_new_purchase(site):
    from tenancy import entitlements
    app,root,student,creator,manager,other,ri,li,ci,mi,si=site
    cid=course(site)
    root.post('/tenants/farmerplus/test-funding',json={'owner':li['owner'],'amount':10000,'currency':'ZAR','key':'fund-policy-test'})
    assert student.post('/tenants/farmerplus/purchase',json={'course':cid,'revision':1,'key':'buy-policy-test'}).status_code==200
    body={'revision':1,'price':10000,'published':False,'offline':True}
    assert student.put('/tenants/farmerplus/courses/'+cid,json=body).status_code==403
    assert creator.put('/tenants/farmerplus/courses/'+cid,json=body).status_code==200
    assert creator.put('/tenants/farmerplus/courses/'+cid,json=body).status_code==409
    assert other.post('/tenants/farmerplus/purchase',json={'course':cid,'revision':2,'key':'buy-unpublished'}).status_code==404
    with app.state.engine.connect() as db:
        assert db.scalar(select(entitlements.c.active).where(entitlements.c.owner==li['owner'],entitlements.c.course==cid))
    assert root.get('/admin/tenants').status_code==200
    assert student.get('/admin/tenants').status_code==403


def test_logo_path_does_not_accept_traversal(site):
    root=site[1]
    assert root.post('/admin/api/tenants',json={'name':'Bad','slug':'bad-logo','logo':'/static/../private.svg','platform_bps':0}).status_code==422


def test_learning_download_policy_checked_on_server(site,monkeypatch):
    import httpx
    app,root,student,creator,manager,other,ri,li,ci,mi,si=site
    monkeypatch.setenv('FARMER_LEARNING_ORIGIN','https://learning.example.test')
    monkeypatch.setattr(app.state.oidc,'browser_token',lambda request:('fixture','fixture-client'))
    monkeypatch.setattr(app.state.oidc,'introspect',lambda *args:({'id':li['owner'],'admin':False},{}))
    calls=[]
    class Learning:
        def __init__(self,**kwargs):pass
        async def __aenter__(self):return self
        async def __aexit__(self,*args):pass
        async def get(self,url,**kwargs):
            calls.append(url)
            return httpx.Response(200,json={'courseid':2,'activities':[]})
    monkeypatch.setattr(httpx,'AsyncClient',Learning)
    denied=root.put('/admin/api/tenants/farmerplus',json={'name':'FarmerPlus','slug':'farmerplus','platform_bps':0,'offline':False})
    assert denied.status_code==200
    assert student.get('/learning/manifest/2').status_code==403
    assert calls==[]
    assert student.get('/learning/manifest/2?tenant=another').status_code==404
    root.put('/admin/api/tenants/farmerplus',json={'name':'FarmerPlus','slug':'farmerplus','platform_bps':0,'offline':True})
    reply=student.get('/learning/manifest/2')
    assert reply.status_code==200,reply.text
    assert reply.json()['tenant_id']=='farmerplus' and reply.json()['offline_enabled']
    cid=course(site)
    root.put('/tenants/farmerplus/courses/'+cid,json={'revision':1,'price':10000,'published':True,'offline':False})
    assert student.get('/learning/manifest/2').status_code==403


def test_default_policy_and_single_superadmin(site):
    app,root,student,creator,manager,other,ri,li,ci,mi,si=site
    p=root.get('/tenants').json()
    assert p['superadmin'] and p['walletMode']=='test'
    assert p['tenants'][0]['offline'] and p['tenants'][0]['platform_bps']==0
    assert student.post('/admin/api/platform/bootstrap').status_code==403
    with app.state.engine.begin() as db:db.execute(update(users).where(users.c.id==si['owner']).values(admin=True))
    assert other.post('/admin/api/platform/bootstrap').status_code==403
    assert other.get('/admin/api/farmers').status_code==403
    assert manager.get('/admin/api/farmers').status_code==403


def test_tenant_cross_access_denied_and_rates_root_only(site):
    app,root,student,creator,manager,other,ri,li,ci,mi,si=site
    tid=listing(root)
    assert student.get('/tenants/'+tid+'/courses').status_code==403
    assert manager.get('/tenants/'+tid+'/finance').status_code==403
    assert manager.put('/admin/api/tenants/farmerplus',json={'name':'Bad','slug':'farmerplus','platform_bps':0}).status_code==403
    assert manager.put('/tenants/farmerplus/members',json={'owner':mi['owner'],'role':'admin'}).status_code==403
    assert manager.put('/tenants/farmerplus/members',json={'owner':ci['owner'],'role':'creator','commission_bps':1500}).status_code==200
    assert student.put('/tenants/farmerplus/members',json={'owner':ci['owner'],'role':'creator'}).status_code==403


def test_payment_farmerplus_zero_fee_duplicate_and_refund(site):
    app,root,student,creator,manager,other,ri,li,ci,mi,si=site
    cid=course(site)
    funding={'owner':li['owner'],'amount':10000,'currency':'ZAR','key':'fund-once'}
    assert root.post('/tenants/farmerplus/test-funding',json=funding).status_code==200
    assert root.post('/tenants/farmerplus/test-funding',json=funding).json()['replayed']
    body={'course':cid,'revision':1,'key':'purchase-once'}
    paid=student.post('/tenants/farmerplus/purchase',json=body)
    assert paid.status_code==200,paid.text
    tx=paid.json()
    assert tx['creator']==8000 and tx['tenant']==2000 and tx['platform']==0
    assert tx['learningStatus']=='pending_enrolment' # Not a false Moodle enrolment claim.
    assert student.post('/tenants/farmerplus/purchase',json=body).json()['replayed']
    assert student.post('/tenants/farmerplus/purchase',json={**body,'key':'new-reference'}).json()['charged']==0
    assert balance(app,'person:'+li['owner']+':ZAR')==0
    assert balance(app,'person:'+ci['owner']+':ZAR')==8000
    assert balance(app,'tenant:farmerplus:ZAR')==2000
    refund=manager.post('/tenants/farmerplus/refund/'+tx['id'])
    assert refund.status_code==200,refund.text
    assert manager.post('/tenants/farmerplus/refund/'+tx['id']).json()['replayed']
    assert balance(app,'person:'+li['owner']+':ZAR')==10000
    assert balance(app,'person:'+ci['owner']+':ZAR')==0
    with app.state.engine.connect() as db:
        assert db.scalar(select(func.sum(entries.c.amount)))==0


def test_platform_share_gross_then_deduction_and_original_refund(site):
    app,root,student,creator,manager,other,ri,li,ci,mi,si=site
    tid=listing(root)
    for person,role in [(li,'student'),(ci,'creator'),(mi,'admin')]:
        assert root.put('/tenants/'+tid+'/members',json={'owner':person['owner'],'role':role}).status_code==200
    app.state.tenancy.configure_instance(tid,'learning-two','https://learning-two.example.test')
    cid=course(site,tid,'learning-two')
    root.post('/tenants/'+tid+'/test-funding',json={'owner':li['owner'],'amount':10000,'currency':'ZAR','key':'fund-second'})
    result=student.post('/tenants/'+tid+'/purchase',json={'course':cid,'revision':1,'key':'second-purchase'}).json()
    assert result['platform']==200 and result['tenant']==1800
    finance=manager.get('/tenants/'+tid+'/finance').json()
    purchase=next(t for t in finance['transactions'] if t['kind']=='purchase')
    assert [(e['amount']) for e in purchase['entries'] if e['wallet']==f'tenant:{tid}:ZAR']==[2000,-200]
    assert not any(w['id'].startswith('platform:') for w in finance['wallets'])
    root.put('/admin/api/tenants/'+tid,json={'name':'Changed','slug':'tenant-two','platform_bps':9000})
    assert manager.post('/tenants/'+tid+'/refund/'+result['id']).status_code==200
    assert balance(app,'platform:ZAR')==0


def test_insufficient_funds_is_atomic_and_no_cross_course_lookup(site):
    app,root,student,creator,manager,other,ri,li,ci,mi,si=site
    cid=course(site)
    assert student.post('/tenants/farmerplus/purchase',json={'course':cid,'revision':1,'key':'not-enough'}).status_code==409
    assert balance(app,'person:'+ci['owner']+':ZAR')==0
    with app.state.engine.connect() as db:assert db.scalar(select(func.count()).select_from(transactions))==0
    tid=listing(root)
    assert root.post('/tenants/'+tid+'/purchase',json={'course':cid,'revision':1,'key':'wrong-tenant'}).status_code==404


def test_concurrent_retries_charge_once(site):
    app,root,student,creator,manager,other,ri,li,ci,mi,si=site
    cid=course(site)
    root.post('/tenants/farmerplus/test-funding',json={'owner':li['owner'],'amount':10000,'currency':'ZAR','key':'fund-race'})
    cookie=student.cookies.get('farmer_session')
    def pay(_):
        with TestClient(app) as c:
            c.cookies.set('farmer_session',cookie)
            return c.post('/tenants/farmerplus/purchase',json={'course':cid,'revision':1,'key':'racing-pay'}).status_code
    with ThreadPoolExecutor(max_workers=4) as pool:assert list(pool.map(pay,range(4)))==[200]*4
    assert balance(app,'person:'+ci['owner']+':ZAR')==8000


def test_wallet_disabled_cannot_simulate_money(site):
    app,root,student,creator,manager,other,ri,li,ci,mi,si=site
    app.state.tenancy.test_wallet=False
    assert root.post('/tenants/farmerplus/test-funding',json={'owner':li['owner'],'amount':10000,'currency':'ZAR','key':'no-provider'}).status_code==503
    assert balance(app,'person:'+li['owner']+':ZAR')==0
