"""Deterministic provider fixtures; these are not evidence of live OAuth setup."""
import json
import time
from urllib.parse import urlsplit, parse_qs
from uuid import uuid4

import pytest
from cryptography.fernet import Fernet
from fastapi import HTTPException, Request
from fastapi.testclient import TestClient
from sqlalchemy import select, update
from app import create_app, users, students, contacts
from keycloak_identity import bindings, provisions, permanent_id, validate_url
from oidc import app_sessions, outbox, compact, sha

@pytest.fixture
def kc(tmp_path, monkeypatch):
    values = {'FARMER_IDENTITY_PROVIDER':'keycloak','FARMER_ENVIRONMENT':'staging',
        'FARMER_OIDC_ISSUER':'https://identity.example.test/realms/farmerplus',
        'FARMER_PWA_PUBLIC_URL':'https://app.example.test','FARMER_PUBLIC_URL':'https://app.example.test','FARMER_WEB_CLIENT_ID':'farmerplus-pwa',
        'FARMER_WEB_CLIENT_SECRET':'fixture-secret','FARMER_LEARNING_CLIENT_ID':'farmerplus-learning',
        'FARMER_KEYCLOAK_ADMIN_CLIENT_ID':'farmerplus-provisioner','FARMER_KEYCLOAK_ADMIN_CLIENT_SECRET':'fixture-admin-secret',
        'FARMER_OIDC_STORAGE_KEY':Fernet.generate_key().decode(),'FARMER_LEARNING_ORIGIN':'https://learn.example.test',
        'FARMER_LEARNING_PROVISIONING_SECRET':'fixture-provisioning-secret-32-characters',
        'FARMER_SECURE_COOKIES':'1'}
    for k,v in values.items(): monkeypatch.setenv(k,v)
    app=create_app(data_dir=tmp_path,testing=True)
    yield app,app.state.oidc,TestClient(app,base_url=values['FARMER_PWA_PUBLIC_URL'])
    app.state.engine.dispose()

def person(**kwargs):
    return {'id':'keycloak-subject-1','email':'farmer@example.test','emailVerified':True,
        'firstName':'Test','lastName':'Farmer','enabled':True,**kwargs}

def token(service, profile=None, **kwargs):
    p=profile or person()
    return {'active':True,'iss':service.issuer,'sub':p['id'],
        'farmerplus_id':permanent_id(service.issuer,p['id']),
        'aud':['farmerplus-api','farmerplus-learning-api'],'client_id':service.client_id,
        'scope':'farm:read farm:write learning:courses:read learning:content:read','iat':int(time.time()),'exp':int(time.time())+300,**kwargs}

def test_registration_outbox_atomic_idempotent_and_no_email_link(kc):
    app,s,_=kc
    one=s.bind(person())
    assert s.bind(person())['id']==one['id']
    two=s.bind(person(id='different-provider-subject'))
    assert one['id']!=two['id']
    with app.state.engine.connect() as db:
        assert len(db.execute(select(bindings)).all())==2
        assert len(db.execute(select(provisions)).all())==2
        assert db.execute(select(users.c.password).where(users.c.id==one['id'])).scalar_one()=='!keycloak-managed'
        before=db.execute(select(provisions).where(provisions.c.owner==one['id'])).mappings().one()
    s.bind(person(firstName='Changed'))
    with app.state.engine.connect() as db:
        after=db.execute(select(provisions).where(provisions.c.owner==one['id'])).mappings().one()
    assert after['revision']==2 and before['event_id']!=after['event_id']
    assert 'password' not in after['payload']


@pytest.mark.parametrize('change',[{'emailVerified':False},{'firstName':''},{'lastName':''},{'email':'bad'}])
def test_incomplete_registration_never_provisions(kc,change):
    app,s,_=kc
    with pytest.raises(HTTPException):s.bind(person(**change))
    with app.state.engine.connect() as db:assert not db.execute(select(provisions)).first()

def test_reconcile_verified_registration_before_browser_callback(kc,monkeypatch):
    app,s,_=kc
    calls=[]
    def admin(method,path,**kwargs):
        calls.append((method,path,kwargs))
        return [person(),person(id='unverified',emailVerified=False)] if method=='GET' else None
    monkeypatch.setattr(s.gateway,'admin',admin)
    s.reconcile()
    with app.state.engine.connect() as db:
        assert len(db.execute(select(provisions)).all())==1
    assert calls[-1][2]['json']['attributes']['farmerplus_id']==[permanent_id(s.issuer,person()['id'])]
    assert calls[-1][2]['json']['email']==person()['email']
    assert calls[-1][2]['json']['firstName']==person()['firstName']
    assert calls[-1][2]['json']['lastName']==person()['lastName']

def test_realm_import_has_standard_claims_and_introspection_audience():
    from identity.keycloak.realm import realm
    model=realm('https://app.example.test','https://learn.example.test',
        {k:'test-secret' for k in ('farmerplus-pwa','farmerplus-learning','farmerplus-provisioner')})
    scopes={s['name']:s for s in model['clientScopes']}
    assert any(m['protocolMapper']=='oidc-sub-mapper' for m in scopes['basic']['protocolMappers'])
    assert any(m['config']['claim.name']=='email_verified' for m in scopes['email']['protocolMappers'])
    for client in model['clients'][:2]:
        assert {'basic','profile','email'}<=set(client['defaultClientScopes'])
        assert any(m['config'].get('included.custom.audience')=='farmerplus-pwa' for m in client['protocolMappers'])
    profile=json.loads(model['components']['org.keycloak.userprofile.UserProfileProvider'][0]['config']['kc.user.profile.config'][0])
    assert 'unmanagedAttributePolicy' not in profile

@pytest.mark.parametrize('change,status',[
    ({'iss':'https://evil.example/realms/farmerplus'},401),({'active':False},401),
    ({'aud':['other-api']},401),({'scope':'farm:write'},403),({'client_id':'unapproved'},403),
    ({'farmerplus_id':'f'*32},401),({'exp':0},401)])
def test_token_boundaries(kc,monkeypatch,change,status):
    _,s,_=kc;s.bind(person())
    monkeypatch.setattr(s.gateway,'inspect',lambda _:token(s,**change))
    with pytest.raises(HTTPException) as error:s.introspect('fixture','farmerplus-api',['farm:read'])
    assert error.value.status_code==status


def test_preview_client_is_approved_only_for_learning_introspection(kc, monkeypatch):
    _, service, _ = kc
    service.bind(person())
    monkeypatch.setattr(service.gateway, 'inspect',
                        lambda _: token(service, client_id='farmerplus-local'))
    with pytest.raises(HTTPException):
        service.learning_introspection('fixture', 'learning:courses:read')
    monkeypatch.setenv('FARMER_PREVIEW_LEARNING_CLIENT_ID', 'farmerplus-local')
    assert service.learning_introspection('fixture', 'learning:courses:read')[1]['client_id'] == 'farmerplus-local'
    with pytest.raises(HTTPException):
        service.introspect('fixture', 'farmerplus-api', ['farm:read'])
    with pytest.raises(HTTPException):
        service.introspect('fixture', 'farmerplus-learning-api', ['learning:content:read'])

def test_pending_revocation_fails_closed(kc,monkeypatch):
    app,s,_=kc;user=s.bind(person())
    monkeypatch.setattr(s.gateway,'inspect',lambda _:token(s))
    assert s.introspect('fixture','farmerplus-api',['farm:read'])[0]['id']==user['id']
    with app.state.engine.begin() as db:s.queue_revoke(db,owner=user['id'])
    with pytest.raises(HTTPException):s.introspect('fixture','farmerplus-api',['farm:read'])
    assert s.revocation_subject(permanent_id(s.issuer,person()['id']))==person()['id']
    calls=[];monkeypatch.setattr(s.gateway,'admin',lambda *args,**kwargs:calls.append(args))
    s.drain()
    assert calls==[('POST','/users/keycloak-subject-1/logout')]

def test_moodle_outage_retry_wrong_identity_and_success(kc,monkeypatch):
    app,s,_=kc;user=s.bind(person());calls=[]
    class Reply:
        status_code=503;content=b'{}'
        def json(self):return self.body
    reply=Reply()
    def post(_self,url,**kwargs):calls.append(kwargs['json']);return reply
    monkeypatch.setattr('httpx.Client.post',post)
    s.drain_provisioning()
    assert s.provisioning_status(user['id'])=={'status':'pending','moodleId':None,'retrying':True}
    with app.state.engine.begin() as db:
        row=db.execute(select(provisions)).mappings().one()
        assert row['attempts']==1 and row['next_attempt']>time.time()
        db.execute(update(provisions).values(next_attempt=0))
    reply.status_code=200;reply.body={**calls[0],'moodle_id':42,'farmerplus_id':'wrong'}
    s.drain_provisioning();assert s.provisioning_status(user['id'])['status']=='pending'
    with app.state.engine.begin() as db:db.execute(update(provisions).values(next_attempt=0))
    reply.body={**calls[0],'moodle_id':42}
    s.drain_provisioning();assert s.provisioning_status(user['id'])=={'status':'ready','moodleId':42,'retrying':False}
    assert calls[0]['event_id']==calls[1]['event_id']==calls[2]['event_id']
    s.drain_provisioning();assert len(calls)==3

def test_no_hydra_or_parallel_password_authority(kc):
    _,_,c=kc
    assert c.get('/auth/providers').json()['authority']=='keycloak'
    assert c.get('/oidc/config').json()['provider']=='keycloak'
    for path in ['/auth/email/register','/auth/login','/auth/recover','/auth/mobile/login']:
        assert c.post(path,json={}).status_code==409
    assert c.get('/oidc/login?login_challenge=forged').status_code==404
    assert c.get('/oidc/consent?consent_challenge=forged').status_code==404
    assert c.get('/learning/provisioning').status_code==401
    assert c.get('/oidc/web/callback?state=forged&code=forged').status_code==403

def test_flow_browser_binding_single_use_and_expiry(kc):
    app,s,_=kc
    req=Request({'type':'http','headers':[]})
    flow,csrf,browser=s.new_flow(req,'web',{'nonce':'fixture'})
    bound=Request({'type':'http','headers':[(b'cookie',('fp_oidc_browser='+browser).encode())]})
    with pytest.raises(HTTPException):s.consume_flow(req,flow,csrf,'web')
    assert s.consume_flow(bound,flow,csrf,'web')=={'nonce':'fixture'}
    with pytest.raises(HTTPException):s.consume_flow(bound,flow,csrf,'web')

def test_loopback_is_explicit_and_https_default():
    with pytest.raises(ValueError):validate_url('http://127.0.0.1:8180')
    assert validate_url('http://127.0.0.1:8180',True)
    with pytest.raises(ValueError):validate_url('http://public.example',True)
    with pytest.raises(ValueError):validate_url('https://identity.example/path?redirect=elsewhere')

def test_web_flow_survives_five_minutes_and_parallel_tabs(kc, monkeypatch):
    _,s,c=kc
    now=int(time.time())
    req=Request({'type':'http','headers':[]})
    _,state,browser=s.new_flow(req,'web',{'nonce':'first'},lifetime=s.web_flow_lifetime)
    bound=Request({'type':'http','headers':[(b'cookie',('fp_oidc_browser='+browser+'; fp_oidc_client=second-tab').encode())]})
    _,second,_=s.new_flow(bound,'web',{'nonce':'second'},lifetime=s.web_flow_lifetime)
    monkeypatch.setattr('keycloak_identity.time.time',lambda:now+600)
    with pytest.raises(HTTPException): s.consume_web_flow(req,state)
    assert s.consume_web_flow(bound,state)=={'nonce':'first'}
    assert s.consume_web_flow(bound,second)=={'nonce':'second'}
    with pytest.raises(HTTPException): s.consume_web_flow(bound,state)

def test_web_flow_expiry_has_safe_retry(kc,monkeypatch):
    _,s,c=kc
    now=int(time.time())
    _,state,browser=s.new_flow(Request({'type':'http','headers':[]}), 'web',{},lifetime=s.web_flow_lifetime)
    c.cookies.set('fp_oidc_browser',browser)
    monkeypatch.setattr('keycloak_identity.time.time',lambda:now+1801)
    r=c.get('/oidc/web/callback?state='+state+'&code=never-exchange')
    assert r.status_code==403
    assert 'Return to FarmerPlus sign in' in r.text and 'href="/oidc/web/login"' in r.text
    assert 'href="/oidc/web/login?destination=learning"' in r.text
    assert state not in r.text and 'never-exchange' not in r.text
    assert r.headers['cache-control']=='no-store'
    assert '<style>' not in r.text
    css=c.get('/oidc/appearance.css')
    assert css.status_code==200 and 'text/css' in css.headers['content-type']

def test_registration_collects_password_before_email_verification():
    from identity.keycloak.realm import realm
    model=realm('https://app.example.test','https://learn.example.test',
        {k:'fixture' for k in ('farmerplus-pwa','farmerplus-learning','farmerplus-provisioner')})
    assert model['verifyEmail'] is True
    assert model['loginTheme']=='farmerplus'
    assert model['accessCodeLifespanLogin']==1800
    assert model['authenticatorConfig'][0]['config']['always_set_password_on_register_form']=='true'
    assert model['passwordPolicy'].startswith('length(8)')

def test_signed_backchannel_logout_revokes_and_rejects_forgery(kc,monkeypatch):
    from authlib.jose import jwt,JsonWebKey
    from oidc import security
    app,s,c=kc;user=s.bind(person())
    key=JsonWebKey.generate_key('RSA',2048,is_private=True,options={'kid':'fixture-key'})
    monkeypatch.setattr(s.gateway,'request',lambda *args,**kwargs:{'keys':[key.as_dict(is_private=False)]})
    payload={'iss':s.issuer,'aud':s.client_id,'sub':person()['id'],'jti':'logout-fixture',
        'iat':int(time.time()),'events':{'http://schemas.openid.net/event/backchannel-logout':{}}}
    signed=jwt.encode({'alg':'RS256','kid':'fixture-key'},payload,key).decode()
    assert c.post('/oidc/backchannel',data={'logout_token':signed}).status_code==200
    assert c.post('/oidc/backchannel',data={'logout_token':signed}).status_code==200
    with app.state.engine.connect() as db:
        assert db.execute(select(security.c.epoch).where(security.c.owner==user['id'])).scalar_one()==1
    assert c.post('/oidc/backchannel',data={'logout_token':signed[:-10]+'tampered'}).status_code==400
    bad=jwt.encode({'alg':'RS256','kid':'fixture-key'},{**payload,'aud':'another-client','jti':'bad-audience'},key).decode()
    assert c.post('/oidc/backchannel',data={'logout_token':bad}).status_code==400

def test_authorization_request_contains_pkce_and_nonce(kc,monkeypatch):
    _,s,c=kc
    rp=s.web_rp()
    metadata={'issuer':s.issuer,'authorization_endpoint':s.gateway.protocol+'/auth',
        'token_endpoint':s.gateway.protocol+'/token','jwks_uri':s.gateway.protocol+'/certs'}
    async def load():
        rp.server_metadata.update(metadata)
        return metadata
    monkeypatch.setattr(rp,'load_server_metadata',load)
    monkeypatch.setattr(s,'web_rp',lambda:rp)
    response=c.get('/oidc/web/login',follow_redirects=False)
    assert response.status_code==303
    values=parse_qs(urlsplit(response.headers['location']).query)
    assert values['code_challenge_method']==['S256']
    assert len(values['code_challenge'][0])>=43 and values['nonce'][0] and values['state'][0]
    assert 'code_verifier' not in values and 'client_secret' not in values

@pytest.mark.parametrize('destination,provider', [('pwa',''), ('learning',''), ('learning','google'), ('admin','')])
@pytest.mark.parametrize('replace_previous', [False, True])
@pytest.mark.parametrize('expired', [False, True])
def test_complete_signed_protocol_callback_refresh_and_session(kc,monkeypatch,destination,provider,replace_previous,expired):
    import httpx
    from authlib.jose import jwt,JsonWebKey
    from authlib.integrations.httpx_client import AsyncOAuth2Client
    app,s,c=kc
    if destination == 'admin':
        s.admin_origin = 'https://backend.example.test'
        c = TestClient(app, base_url=s.admin_origin)
    if replace_previous:
        from http.cookies import SimpleCookie
        from fastapi import Response
        from sqlalchemy import insert
        from keycloak_identity import keycloak_sessions
        from oidc import session_auth
        old_user=s.bind(person(id='previous-subject',email='previous@example.test'))
        browser_response,other_device_response=Response(),Response()
        with app.state.engine.begin() as db:
            s.issue_session(db,old_user,browser_response)
            s.issue_session(db,old_user,other_device_response)
            db.execute(insert(app_sessions).values(hash=sha('previous-app'),owner=old_user['id'],
                client=s.client_id,epoch=0,sealed='old-sealed-token',expires=int(time.time())+300))
            db.execute(insert(keycloak_sessions).values(hash=sha('previous-app'),
                subject='previous-subject',sid='previous-sid'))
        def cookie(response):
            parsed=SimpleCookie();parsed.load(response.headers['set-cookie'])
            return parsed[app.state.session_cookie].value
        previous_cookie,other_cookie=cookie(browser_response),cookie(other_device_response)
        c.cookies.set(app.state.session_cookie,previous_cookie)
        c.cookies.set('fp_app','previous-app')
        # Unverified callbacks must not retire an existing session.
        assert c.get('/oidc/web/callback?state=forged&code=forged').status_code==403
        with app.state.engine.connect() as db:
            assert db.execute(select(s.sessions).where(s.sessions.c.hash==sha(previous_cookie))).first()
    key=JsonWebKey.generate_key('RSA',2048,is_private=True,options={'kid':'fixture-key'})
    nonce={};requests=[]
    def transport(request):
        requests.append(request.url.path)
        if request.url.path.endswith('/.well-known/openid-configuration'):
            return httpx.Response(200,json={'issuer':s.issuer,'authorization_endpoint':s.gateway.protocol+'/auth',
                'token_endpoint':s.gateway.protocol+'/token','jwks_uri':s.gateway.protocol+'/certs',
                'id_token_signing_alg_values_supported':['RS256']})
        if request.url.path.endswith('/certs'):
            return httpx.Response(200,json={'keys':[key.as_dict(is_private=False)]})
        if request.url.path.endswith('/token'):
            body=parse_qs(request.content.decode())
            if body['grant_type']==['authorization_code']:
                assert body['code_verifier'][0]
                assert body['redirect_uri']==[(s.admin_origin if destination=='admin' else s.origin)+'/oidc/web/callback']
            payload={'iss':s.issuer,'aud':s.client_id,'azp':s.client_id,'sub':person()['id'],
                'iat':int(time.time()),'exp':int(time.time())+300,'nonce':nonce['value'],'sid':'fixture-session'}
            signed=jwt.encode({'alg':'RS256','kid':'fixture-key'},payload,key).decode()
            return httpx.Response(200,json={'access_token':'fixture-access-token','refresh_token':'fixture-refresh-token',
                'token_type':'Bearer','expires_in':300,'id_token':signed})
        raise AssertionError('Unexpected protocol endpoint')
    original=AsyncOAuth2Client.__init__
    def init(self,*args,**kwargs):
        kwargs['transport']=httpx.MockTransport(transport)
        original(self,*args,**kwargs)
    monkeypatch.setattr(AsyncOAuth2Client,'__init__',init)
    monkeypatch.setattr(s.gateway,'admin',lambda method,path,**kwargs:person() if method=='GET' else None)
    monkeypatch.setattr(s.gateway,'inspect',lambda _:token(s))
    monkeypatch.setenv('FARMER_LEARNING_ORIGIN','https://learn.example.test')
    monkeypatch.setenv('FARMER_KEYCLOAK_GOOGLE_ENABLED','1')
    monkeypatch.setenv('FARMER_KEYCLOAK_APPLE_ENABLED','0')
    unavailable=c.get('/oidc/web/login?provider=apple&destination='+destination,follow_redirects=False)
    assert unavailable.status_code==503 and 'provider is not configured' in unavailable.text
    start=c.get('/oidc/web/login?destination='+destination+'&cmid=42&provider='+provider,follow_redirects=False)
    assert start.status_code==303
    query=parse_qs(urlsplit(start.headers['location']).query);nonce['value']=query['nonce'][0]
    assert query.get('kc_idp_hint', [''])[0] == provider
    if expired:
        from oidc import flows
        with app.state.engine.begin() as db:
            db.execute(update(flows).values(expires=int(time.time())-1))
        # The short-lived browser binding may also be gone after inactivity.
        c.cookies.delete('fp_oidc_browser')
        old_state = query['state'][0]
        restart = c.get('/oidc/web/callback?code=expired-code&state='+old_state+'&destination=evil&cmid=999', follow_redirects=False)
        assert restart.status_code == 303
        assert '/oidc/web/login?' in restart.headers['location']
        assert 'destination='+destination in restart.headers['location']
        assert 'cmid=42' in restart.headers['location']
        assert not any(path.endswith('/token') for path in requests)
        start = c.get(restart.headers['location'], follow_redirects=False)
        query = parse_qs(urlsplit(start.headers['location']).query)
        assert query['state'][0] != old_state
        nonce['value'] = query['nonce'][0]
    callback='/oidc/web/callback?code=fixture-code&state='+query['state'][0]
    response=c.get(callback+'&destination=untrusted&cmid=999',follow_redirects=False)
    assert response.status_code==303,response.text
    assert response.headers['location']==('https://learn.example.test/auth/farmerplusoidc/login.php?continue=1&cmid=42' if destination=='learning' else s.admin_origin+'/admin' if destination=='admin' else 'https://app.example.test/auth/callback')
    if destination == 'admin':
        # A destination never grants administrator privileges.
        assert c.get('/admin').status_code == 403
    me=c.get('/auth/me')
    assert me.status_code==200,me.text
    assert me.json()['verified'] is True and me.json()['accountKind']=='keycloak'
    assert c.get('/sync/pull').status_code==200
    assert c.get('/learning/provisioning').json()['status']=='pending'
    repeated=c.get(callback,follow_redirects=False)
    assert repeated.status_code==303
    assert repeated.headers['location']==response.headers['location']
    assert c.get(callback+'x',follow_redirects=False).status_code==403
    with app.state.engine.connect() as db:
        session=db.execute(select(app_sessions)).mappings().one()
        assert 'fixture-access-token' not in session['sealed']
        assert len(db.execute(select(provisions)).all())==(2 if replace_previous else 1)
        if replace_previous:
            assert not db.execute(select(s.sessions).where(s.sessions.c.hash==sha(previous_cookie))).first()
            assert not db.execute(select(session_auth).where(session_auth.c.hash==sha(previous_cookie))).first()
            assert not db.execute(select(keycloak_sessions).where(keycloak_sessions.c.hash==sha('previous-app'))).first()
            assert db.execute(select(s.sessions).where(s.sessions.c.hash==sha(other_cookie))).first()
            assert db.execute(select(users).where(users.c.id==old_user['id'])).first()
    assert sum(path.endswith('/token') for path in requests)==2
    from keycloak_identity import browser_activity
    with app.state.engine.begin() as db:
        db.execute(update(browser_activity).values(last_activity=int(time.time())-1790))
    assert c.post('/auth/activity', json={'idleForSeconds': 0}).status_code == 200
    assert c.post('/auth/activity', json={'idleForSeconds': -1}).status_code == 422
    assert c.post('/auth/activity', headers={'Origin':'https://evil.example'}, json={}).status_code == 403
    with app.state.engine.connect() as db:
        recent = db.execute(select(browser_activity.c.last_activity).where(browser_activity.c.hash == session['hash'])).scalar_one()
    assert abs(recent-int(time.time())) < 5
    assert c.get('/auth/me').status_code == 200
    with app.state.engine.begin() as db:
        db.execute(update(browser_activity).values(last_activity=int(time.time())-1801))
    assert c.get('/auth/me').status_code == 401
    assert c.post('/auth/activity', json={}).status_code == 401



def test_learning_destination_rejects_external_urls_and_bad_activity(kc):
    _, _, c = kc
    for query in ['destination=https://evil.invalid', 'destination=//evil.invalid', 'cmid=-1', 'cmid=2147483648']:
        assert c.get('/oidc/web/login?' + query, follow_redirects=False).status_code == 400


def test_split_domain_login_sets_cookies_only_on_callback_host(kc):
    app, s, c = kc
    s.origin = 'https://mobile.example.test'
    response = c.get('/oidc/web/login?destination=learning&cmid=42', follow_redirects=False)
    assert response.status_code == 303
    assert response.headers['location'].startswith(s.origin+'/oidc/web/login?')
    assert 'destination=learning' in response.headers['location']
    assert 'set-cookie' not in response.headers
    portal = c.get('/admin', follow_redirects=False)
    assert portal.headers['location'] == '/oidc/web/login?destination=admin'


def test_restart_requires_signed_context_and_stops_redirect_loops(kc):
    _, s, c = kc
    context = {'state': sha('expired-state'), 'destination': 'learning', 'cmid': 42}
    c.cookies.set('fp_oidc_return', s.cipher.encrypt(compact(context).encode()).decode())
    url = '/oidc/web/callback?state=expired-state&code=never-exchange'
    assert c.get(url+'&error=access_denied', follow_redirects=False).status_code == 403
    assert c.get(url.replace('expired-state', 'forged'), follow_redirects=False).status_code == 403
    assert c.get(url, follow_redirects=False).status_code == 303
    assert c.get(url, follow_redirects=False).status_code == 403
    c.cookies.clear()
    c.cookies.set('fp_oidc_return', 'tampered')
    assert c.get(url, follow_redirects=False).status_code == 403
