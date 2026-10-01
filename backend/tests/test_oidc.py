"""Deterministic policy/transaction tests; Hydra is a fixture, not conformance evidence."""
import json,time
import pytest
from cryptography.fernet import Fernet
from fastapi import HTTPException,Request
from fastapi.testclient import TestClient
from sqlalchemy import select,update
from app import create_app,users,recovery
from oidc import Application,registry,security,recovery_reviews

class ProviderFixture:
    def __init__(self):self.clients={};self.fail=False;self.revokes=[];self.token={}
    def call(self,name,**values):
        if self.fail:raise HTTPException(503,'Fixture outage')
        if name in {'create_o_auth2_client','set_o_auth2_client'}:
            c=values['o_auth2_client'].to_dict();self.clients[c['client_id']]=c;return c
        if name=='get_o_auth2_client':return self.clients[values['id']]
        if name=='list_o_auth2_clients':return list(self.clients.values())
        if name=='delete_o_auth2_client':self.clients.pop(values['id'],None);return
        if name.startswith('revoke_'):self.revokes.append((name,values));return
        if name=='introspect_o_auth2_token':return self.token
        if name=='reject_o_auth2_login_request':return {'redirect_to':'https://identity.farmerplus.test/oauth2/auth?login_verifier=fixture'}
        raise AssertionError(name)

@pytest.fixture
def identity(tmp_path,monkeypatch):
    monkeypatch.setenv('FARMER_IDENTITY_PROVIDER','hydra')
    for k,v in {'FARMER_ENVIRONMENT':'staging','FARMER_OIDC_ISSUER':'https://identity.farmerplus.test','FARMER_PUBLIC_URL':'https://app.farmerplus.test','HYDRA_ADMIN_URL':'http://private:4445','FARMER_OIDC_STORAGE_KEY':Fernet.generate_key().decode(),'FARMER_ANDROID_CLIENT_ID':'fixture-native'}.items():monkeypatch.setenv(k,v)
    app=create_app(data_dir=tmp_path,testing=True);provider=ProviderFixture();app.state.oidc.gateway=provider
    def login(name,admin=False):
        c=TestClient(app,base_url='https://app.farmerplus.test');password='Fixture-only-Password'
        r=c.post('/auth/register',json={'username':name,'password':password,'firstname':'Fixture','lastname':name});assert r.status_code==201
        owner=r.json()['owner']
        if admin:
            with app.state.engine.begin() as db:db.execute(update(users).where(users.c.id==owner).values(admin=True))
        assert c.post('/auth/login',json={'username':name,'password':password}).status_code==200
        if admin:
            c.get('/admin/identity');c.headers['X-CSRF-Token']=c.cookies.get('__Host-fp_csrf')
            v=c.post('/admin/identity/reauthenticate',json={'password':password});assert v.status_code==200
            c.headers['X-Reauthentication']=v.json()['reauthentication'];c.headers['X-Change-Reason']='Authorised fixture account change'
        return c,owner
    yield app,provider,login
    app.state.engine.dispose()

def spec(id='fixture-native',**changes):return {'id':id,'name':'Fixture native','owner':'Tests','environment':'staging','type':'native','callbacks':['earth.farmerplus.app:/oauthredirect'],'scopes':['openid','farmerplus.identity','farm:read'],'audiences':['farmerplus-api'],'first_party':True,'preauthorized':True,**changes}

@pytest.mark.parametrize('change',[{'callbacks':['https://bad.example/*']},{'callbacks':['https://good.example/cb#x']},{'callbacks':['http://good.example/cb']},{'callbacks':['https://user:pass@good.example/cb']},{'scopes':['openid','admin']},{'first_party':False},{'type':'spa','backchannel_logout':'https://good.example/logout'}])
def test_disallowed_registration_policy(change,monkeypatch):
    monkeypatch.setenv('FARMER_ENVIRONMENT','staging')
    with pytest.raises(ValueError):Application(**spec(**change))

def test_uncertain_registration_fail_closed_and_reconciliation(identity):
    app,p,login=identity;c,_=login('admin',True);p.fail=True
    assert c.post('/admin/identity/applications',json=spec()).status_code==503
    with app.state.engine.connect() as db:
        row=db.execute(select(registry)).mappings().one();assert not row['enabled'] and row['status']=='needs_review'
    assert c.post('/admin/identity/applications/fixture-native/reconcile',json={}).status_code==503

def test_public_client_scope_owner_epoch_and_disable(identity):
    app,p,login=identity;admin,_=login('admin',True);farmer,owner=login('farmer')
    r=admin.post('/admin/identity/applications',json=spec());assert r.status_code==200 and 'clientSecret' not in r.json()
    assert admin.post('/admin/identity/applications/fixture-native/rotate-secret',json={}).status_code==422
    with app.state.engine.begin() as db:subject=app.state.oidc.mapped(db,owner)['student_id']
    p.token={'active':True,'sub':subject,'client_id':'fixture-native','aud':['farmerplus-api'],'scope':'farm:read','exp':int(time.time())+300,'ext':{'account_epoch':0}}
    assert farmer.get('/auth/me',headers={'Authorization':'Bearer fixture-token'}).status_code==200
    p.token['client_id']='other';assert farmer.get('/auth/me',headers={'Authorization':'Bearer fixture-token'}).status_code==401
    p.token['client_id']='fixture-native';p.token['ext']['account_epoch']=9
    assert farmer.get('/auth/me',headers={'Authorization':'Bearer fixture-token'}).status_code==401
    assert admin.post('/admin/identity/applications/fixture-native/disable',json={}).status_code==200
    consent=[kwargs for name,kwargs in p.revokes if name=='revoke_o_auth2_consent_sessions'];assert consent and all(v['subject'] and v['client']=='fixture-native' and v['all'] is False for v in consent)

def test_recovery_two_reviewers_single_use_and_audit(identity):
    app,p,login=identity;one,_=login('admin_one',True);two,_=login('admin_two',True);farmer,owner=login('farmer')
    assert farmer.get('/admin/identity/people').status_code==403
    r=one.post('/admin/identity/recovery-reviews',json={'owner':owner,'evidenceReference':'Protected fixture case 123, dual control checked','proofReviewed':True});assert r.status_code==200;key=r.json()['reviewId']
    assert one.post('/admin/identity/recovery-reviews/'+key+'/approve',json={'proofReviewed':True}).status_code==409
    r=two.post('/admin/identity/recovery-reviews/'+key+'/approve',json={'proofReviewed':True});assert r.status_code==200;codes=r.json()['recoveryCodes'];assert len(codes)==8
    assert two.post('/admin/identity/recovery-reviews/'+key+'/approve',json={'proofReviewed':True}).status_code==409
    with app.state.engine.connect() as db:
        assert db.execute(select(security.c.epoch).where(security.c.owner==owner)).scalar_one()==1
        saved=str(db.execute(select(recovery).where(recovery.c.owner==owner)).all())
        assert all(code not in saved for code in codes)
    assert farmer.post('/auth/change',json={'current_password':'Fixture-only-Password','username':'renamed'}).status_code==401

def test_profile_role_change_preserves_subject_and_revokes(identity):
    app,p,login=identity;admin,_=login('admin',True);farmer,owner=login('farmer')
    with app.state.engine.begin() as db:prior=app.state.oidc.mapped(db,owner)['student_id']
    r=admin.put('/admin/identity/people/'+owner,json={'firstname':'Updated','lastname':'Farmer','email':None,'role':'admin'});assert r.status_code==200 and r.json()['roleChanged']
    with app.state.engine.begin() as db:assert app.state.oidc.mapped(db,owner)['student_id']==prior
    assert farmer.get('/admin/identity/people').status_code==403

def test_browser_null_origin_only_for_cookie_bound_one_use_forms(identity):
    app,p,login=identity
    c=TestClient(app,base_url='https://app.farmerplus.test')
    request=Request({'type':'http','method':'GET','path':'/oidc/login','headers':[]})
    flow,csrf,browser=app.state.oidc.new_flow(request,'login',{'challenge':'fixture-challenge'})
    headers={'Origin':'null','Sec-Fetch-Site':'same-origin'}
    c.cookies.set('fp_oidc_browser',browser)
    assert c.post('/auth/register',headers=headers,json={'username':'new','password':'Fixture-only-Password'}).status_code==403
    bad=c.post('/oidc/login',headers=headers,data={'flow':flow,'csrf':'forged','decision':'cancel'},follow_redirects=False)
    assert bad.status_code==403
    valid=c.post('/oidc/login',headers=headers,data={'flow':flow,'csrf':csrf,'decision':'cancel'},follow_redirects=False)
    assert valid.status_code==303
    assert c.post('/oidc/login',headers=headers,data={'flow':flow,'csrf':csrf,'decision':'cancel'},follow_redirects=False).status_code==403

def test_admin_web_and_farmer_mobile_roles_enforced_on_existing_tokens(identity):
    app,p,login=identity
    admin,admin_owner=login('admin',True)
    farmer,farmer_owner=login('farmer')
    assert admin.post('/admin/identity/applications',json=spec(allowed_roles=['farmer'])).status_code==200
    assert admin.post('/admin/identity/applications',json=spec('fixture-admin-web',type='server',callbacks=['https://app.farmerplus.test/oidc/web/callback'],allowed_roles=['admin'])).status_code==200
    for client,owner,allowed in [('fixture-native',farmer_owner,True),('fixture-native',admin_owner,False),('fixture-admin-web',admin_owner,True),('fixture-admin-web',farmer_owner,False)]:
        with app.state.engine.begin() as db:subject=app.state.oidc.mapped(db,owner)['student_id']
        p.token={'active':True,'sub':subject,'client_id':client,'aud':['farmerplus-api'],'scope':'farm:read','exp':int(time.time())+300,'ext':{'account_epoch':0}}
        if allowed:
            user,_=app.state.oidc.introspect('fixture-token','farmerplus-api',['farm:read'],client)
            assert user['id']==owner
        else:
            with pytest.raises(HTTPException) as error:app.state.oidc.introspect('fixture-token','farmerplus-api',['farm:read'],client)
            assert error.value.status_code==403

def test_refresh_transport_outage_is_retryable_and_keeps_credentials(identity,monkeypatch):
    import httpx
    import oidc
    from sqlalchemy import insert
    app,p,login=identity;admin,_=login('admin',True);farmer,owner=login('farmer')
    r=admin.post('/admin/identity/applications',json=spec('fixture-web',type='server',callbacks=['https://app.farmerplus.test/oidc/web/callback']));assert r.status_code==200
    sealed=app.state.oidc.cipher.encrypt(json.dumps({'access_token':'old-fixture','refresh_token':'refresh-fixture','expires_at':time.time()-2}).encode()).decode()
    with app.state.engine.begin() as db:
        app.state.oidc.state(db,owner,True)
        db.execute(insert(oidc.app_sessions).values(hash=oidc.sha('fixture-cookie'),owner=owner,client='fixture-web',epoch=0,sealed=sealed,expires=int(time.time())+300))
    class OfflineClient:
        def __init__(self,*args,**kwargs):pass
        def __enter__(self):return self
        def __exit__(self,*args):pass
        def refresh_token(self,*args,**kwargs):raise httpx.ConnectError('Fixture outage')
    monkeypatch.setattr(oidc,'OAuth2Client',OfflineClient)
    monkeypatch.setattr(app.state.oidc,'central',lambda *args:{'id':owner})
    request=Request({'type':'http','method':'GET','path':'/auth/me','headers':[(b'cookie',b'fp_app=fixture-cookie')]})
    with pytest.raises(HTTPException) as error:app.state.oidc.browser_token(request)
    assert error.value.status_code==503
    with app.state.engine.connect() as db:assert db.execute(select(oidc.app_sessions.c.sealed)).scalar_one()==sealed
