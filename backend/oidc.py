"""FarmerPlus account policy + Hydra integration, not an identity protocol engine.

Hydra owns grants, codes, protocol sessions and tokens. Its maintained SDK is the
only administrative transport. Opaque API tokens are introspected on every call.
"""
from __future__ import annotations
import hashlib
import hmac
import json
import os
import re
import secrets
import time
import asyncio
import httpx
from pathlib import Path
from urllib.parse import urlsplit, parse_qs, urlencode
from uuid import uuid4
import ory_hydra_client as hydra
from cryptography.fernet import Fernet
from fastapi import HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse
from jinja2 import Environment, FileSystemLoader, select_autoescape
from authlib.integrations.starlette_client import OAuth
from authlib.integrations.httpx_client import OAuth2Client
from pydantic import BaseModel, ConfigDict, Field, model_validator
from sqlalchemy import MetaData, Table, Column, String, Integer, Boolean, Text, select, insert, update, delete
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from schema_migrations import apply_identity_schema

SCOPES={'openid','profile','email','offline_access','farmerplus.identity','farm:read','farm:write','learning:courses:read','learning:content:read'}
AUDIENCES={'farmerplus-api','farmerplus-learning-api'}
meta=MetaData()
security=Table('account_security',meta,Column('owner',String(36),primary_key=True),Column('epoch',Integer,nullable=False,default=0),Column('suspended',Boolean,nullable=False,default=False))
registry=Table('oidc_applications',meta,Column('id',String(100),primary_key=True),Column('policy',Text,nullable=False),Column('enabled',Boolean,nullable=False),Column('status',String(24),nullable=False),Column('revision',Integer,nullable=False),Column('operation',String(36),nullable=False),Column('last_use',Integer),Column('error',String(180)))
audit=Table('identity_audit',meta,Column('id',String(36),primary_key=True),Column('actor',String(36),nullable=False),Column('action',String(64),nullable=False),Column('target',String(100),nullable=False),Column('result',String(32),nullable=False),Column('at',Integer,nullable=False))
flows=Table('oidc_browser_flows',meta,Column('hash',String(64),primary_key=True),Column('browser',String(64),nullable=False),Column('csrf',String(64),nullable=False),Column('kind',String(16),nullable=False),Column('sealed',Text,nullable=False),Column('expires',Integer,nullable=False))
reauth=Table('admin_reauthentication',meta,Column('hash',String(64),primary_key=True),Column('owner',String(36),nullable=False),Column('session',String(64),nullable=False),Column('epoch',Integer,nullable=False),Column('expires',Integer,nullable=False))
outbox=Table('identity_revocation_outbox',meta,Column('id',String(36),primary_key=True),Column('subject',String(32)),Column('client',String(100)),Column('epoch',Integer),Column('created',Integer,nullable=False),Column('next_attempt',Integer,nullable=False),Column('attempts',Integer,nullable=False,default=0),Column('status',String(20),nullable=False),Column('error',String(180)))
app_sessions=Table('oidc_app_sessions',meta,Column('hash',String(64),primary_key=True),Column('owner',String(36),nullable=False),Column('client',String(100),nullable=False),Column('epoch',Integer,nullable=False),Column('sealed',Text,nullable=False),Column('expires',Integer,nullable=False))
rp_credentials=Table('oidc_rp_credentials',meta,Column('client',String(100),primary_key=True),Column('sealed',Text,nullable=False))
session_auth=Table('central_session_authentication',meta,Column('hash',String(64),primary_key=True),Column('authenticated_at',Integer,nullable=False),Column('epoch',Integer,nullable=False))
rp_delivery=Table('identity_rp_revocation_delivery',meta,Column('event',String(36),primary_key=True),Column('client',String(100),primary_key=True),Column('acknowledged',Integer))
seen_sessions=Table('identity_seen_sessions',meta,Column('hash',String(64),primary_key=True),Column('owner',String(36),nullable=False),Column('client',String(100),nullable=False),Column('first_seen',Integer,nullable=False),Column('last_seen',Integer,nullable=False),Column('expires',Integer,nullable=False),Column('epoch',Integer,nullable=False))
recovery_reviews=Table('identity_recovery_reviews',meta,Column('id',String(36),primary_key=True),Column('owner',String(36),nullable=False),Column('requested_by',String(36),nullable=False),Column('reviewed_by',String(36)),Column('evidence_reference',Text,nullable=False),Column('created',Integer,nullable=False),Column('status',String(16),nullable=False))

def sha(value):return hashlib.sha256(value.encode()).hexdigest()
def compact(value):return json.dumps(value,separators=(',',':'),sort_keys=True)
def exact_uri(value, native=False):
    u=urlsplit(value)
    if len(value)>500 or '*' in value or u.fragment or u.username or u.password or '..' in u.path or '\\' in value:raise ValueError('Use an exact callback without credentials, fragments or wildcards')
    if u.scheme=='https' and u.hostname and u.path.startswith('/'):return value
    # Explicit staging native callback only. Production requires approved App Links.
    if native and os.getenv('FARMER_ENVIRONMENT')=='staging' and re.fullmatch(r'earth\.farmerplus\.app:/oauthredirect',value):return value
    raise ValueError('Use an exact HTTPS URI')

class Application(BaseModel):
    model_config=ConfigDict(extra='forbid')
    id:str=Field(pattern=r'^[a-z][a-z0-9_-]{2,99}$')
    name:str=Field(min_length=1,max_length=100)
    owner:str=Field(min_length=1,max_length=100)
    environment:str=Field(pattern=r'^(staging|production)$')
    type:str=Field(pattern=r'^(native|spa|server)$')
    callbacks:list[str]=Field(min_length=1,max_length=8)
    post_logout:list[str]=Field(default_factory=list,max_length=8)
    scopes:list[str]=Field(min_length=1,max_length=16)
    audiences:list[str]=Field(default_factory=list,max_length=2)
    first_party:bool=False
    preauthorized:bool=False
    allowed_roles:list[str]=Field(default_factory=lambda:['farmer'])
    backchannel_logout:str|None=None
    @model_validator(mode='after')
    def policy(self):
        if len(set(self.callbacks))!=len(self.callbacks):raise ValueError('Callback entries must be unique')
        for u in self.callbacks:exact_uri(u,self.type=='native')
        for u in self.post_logout:exact_uri(u)
        if self.backchannel_logout:exact_uri(self.backchannel_logout)
        if not set(self.scopes)<=SCOPES or 'openid' not in self.scopes:raise ValueError('Choose supported minimum scopes including openid')
        if not set(self.audiences)<=AUDIENCES:raise ValueError('Unsupported API audience')
        if not self.first_party and (self.preauthorized or 'farmerplus.identity' in self.scopes or self.audiences):raise ValueError('This access is limited to reviewed first-party apps')
        if not set(self.allowed_roles)<={'farmer','admin'} or not self.allowed_roles:raise ValueError('Choose server-assigned roles')
        if self.type!='server' and self.backchannel_logout:raise ValueError('Only implemented server clients may register back-channel logout')
        return self

class HydraGateway:
    def __init__(self,url):
        self.url=url
        cfg=hydra.Configuration(host=url)
        cfg.debug=False
        self.api=hydra.OAuth2Api(hydra.ApiClient(cfg))
    def call(self,name,**kwargs):
        try:
            value=getattr(self.api,name)(**kwargs,_request_timeout=(3.0,12.0))
            if isinstance(value,list):return [v.to_dict() for v in value]
            return value.to_dict() if value is not None else None
        except hydra.exceptions.ApiException as e:
            # SDK exceptions include request/response content; never serialize them.
            if name=='delete_o_auth2_client' and e.status==404:return None
            raise HTTPException(503 if e.status>=500 or not e.status else 409,'Identity provider request failed; no success was assumed') from None
        except Exception:raise HTTPException(503,'Identity provider is unavailable') from None

class IdentityService:
    def learning_introspection(self, token, scope):
        return self.introspect(token, 'farmerplus-learning-api', [scope])
    def __init__(self,app,engine,users,students,sessions,contacts,password_matches,issue_session,issue_recovery,throttle):
        self.app,self.engine,self.users,self.students,self.sessions,self.contacts=app,engine,users,students,sessions,contacts
        self.password_matches,self.issue_session,self.issue_recovery,self.throttle=password_matches,issue_session,issue_recovery,throttle
        self.issuer=os.getenv('FARMER_OIDC_ISSUER','').rstrip('/')
        self.origin=os.getenv('FARMER_PUBLIC_URL','').rstrip('/')
        self.environment=os.getenv('FARMER_ENVIRONMENT','staging')
        self.enabled=bool(self.issuer and self.origin and os.getenv('HYDRA_ADMIN_URL'))
        self.gateway=HydraGateway(os.getenv('HYDRA_ADMIN_URL','http://127.0.0.1:4445'))
        self.cipher=None
        if self.enabled:
            exact_uri(self.issuer+'/');exact_uri(self.origin+'/')
            self.cipher=Fernet(os.environ['FARMER_OIDC_STORAGE_KEY'].encode())
        self.templates=Environment(loader=FileSystemLoader(str(Path(__file__).parent/'templates')),autoescape=select_autoescape())
        self.schema=apply_identity_schema(engine,meta)
        with engine.begin() as db:
            for u in db.execute(select(users.c.id)).all():self.state(db,u.id)
        self.mount()
        async def revocation_worker():
            while True:
                await asyncio.to_thread(self.drain)
                await asyncio.sleep(15)
        async def start_worker():
            if self.enabled:self.worker=asyncio.create_task(revocation_worker())
        async def stop_worker():
            task=getattr(self,'worker',None)
            if task:task.cancel()
        app.router.on_startup.append(start_worker)
        app.router.on_shutdown.append(stop_worker)

    def state(self,db,owner,lock=False):
        insert_fn=pg_insert if db.dialect.name=='postgresql' else sqlite_insert
        db.execute(insert_fn(security).values(owner=owner,epoch=0,suspended=False).on_conflict_do_nothing(index_elements=['owner']))
        if lock:db.execute(update(security).where(security.c.owner==owner).values(epoch=security.c.epoch))
        return dict(db.execute(select(security).where(security.c.owner==owner)).mappings().one())
    def mapped(self,db,owner):
        row=db.execute(select(self.students).where(self.students.c.owner==owner)).mappings().first()
        if not row:raise HTTPException(409,'This account needs its permanent identity migration')
        return dict(row)
    def central(self,request,db=None):
        token=request.cookies.get(self.app.state.session_cookie,'')
        if not token:return None
        def lookup(c):
            row=c.execute(select(self.users).join(self.sessions,self.users.c.id==self.sessions.c.owner).where(self.sessions.c.hash==sha(token),self.sessions.c.expires>int(time.time()))).mappings().first()
            if not row:return None
            state=self.state(c,row['id'])
            if state['suspended']:return None
            authentication=c.execute(select(session_auth).where(session_auth.c.hash==sha(token))).mappings().first()
            if self.enabled and (not authentication or authentication['epoch']!=state['epoch']):return None
            return {**dict(row),'authenticated_at':authentication['authenticated_at'] if authentication else 0}
        if db is not None:return lookup(db)
        with self.engine.begin() as c:return lookup(c)
    def log(self,db,actor,action,target,result):
        db.execute(insert(audit).values(id=str(uuid4()),actor=actor,action=action,target=target,result=result,at=int(time.time())))
    def require_enabled(self):
        if not self.enabled:raise HTTPException(503,'Single sign-on is awaiting its staging configuration')
    def page(self,template_name,**context):return HTMLResponse(self.templates.get_template(template_name+'.html').render(**context))
    def redirect(self,url):
        # Hydra verifier redirects stay on the configured issuer. The RP code
        # callback is subsequently chosen/validated by Hydra, never this service.
        u=urlsplit(url);expected=urlsplit(self.issuer)
        if (u.scheme,u.netloc)!=(expected.scheme,expected.netloc) or u.username or u.password:raise HTTPException(503,'Identity provider returned an unexpected redirect')
        return RedirectResponse(url,303)
    def policy(self,db,client):
        row=db.execute(select(registry).where(registry.c.id==client)).mappings().first()
        if not row or not row['enabled'] or row['status']!='active':raise HTTPException(403,'This application is not enabled')
        return dict(row),json.loads(row['policy'])
    def csrf(self,request,value):
        cookie=request.cookies.get('__Host-fp_csrf' if self.enabled else 'fp_csrf','')
        if not cookie or not value or not hmac.compare_digest(cookie,value):raise HTTPException(403,'Refresh this page and try again')
        origin=request.headers.get('origin')
        if origin and origin!=self.origin:raise HTTPException(403,'Request origin was not accepted')
    def admin(self,request,write=False):
        user=self.central(request)
        if not user or not user['admin']:raise HTTPException(403,'Administrator access required')
        self.app.state.operations.authorize(request,user,write)
        if write:
            self.csrf(request,request.headers.get('x-csrf-token',''))
            key=request.headers.get('x-reauthentication','')
            with self.engine.begin() as db:
                state=self.state(db,user['id'],True)
                row=db.execute(select(reauth).where(reauth.c.hash==sha(key),reauth.c.owner==user['id'],reauth.c.session==sha(request.cookies.get(self.app.state.session_cookie,'')),reauth.c.expires>int(time.time()),reauth.c.epoch==state['epoch'])).first()
                if not row or state['suspended']:raise HTTPException(401,'Re-enter your password before changing identity settings')
        return user

    def new_flow(self,request,kind,payload,csrf_override=None,lifetime=300):
        browser=request.cookies.get('fp_oidc_browser') or secrets.token_urlsafe(32)
        flow=secrets.token_urlsafe(32);csrf=csrf_override or secrets.token_urlsafe(32)
        with self.engine.begin() as db:
            db.execute(delete(flows).where(flows.c.expires<int(time.time())))
            db.execute(insert(flows).values(hash=sha(flow),browser=sha(browser),csrf=sha(csrf),kind=kind,sealed=self.cipher.encrypt(compact(payload).encode()).decode(),expires=int(time.time())+lifetime))
        return flow,csrf,browser
    def consume_flow(self,request,flow,csrf,kind):
        with self.engine.begin() as db:
            row=db.execute(select(flows).where(flows.c.hash==sha(flow),flows.c.browser==sha(request.cookies.get('fp_oidc_browser','')),flows.c.csrf==sha(csrf),flows.c.kind==kind,flows.c.expires>int(time.time()))).mappings().first()
            if not row:raise HTTPException(403,'This request expired or was already used. Open sign-in again.')
            removed=db.execute(delete(flows).where(flows.c.hash==row['hash']))
            if removed.rowcount!=1:raise HTTPException(403,'This request was already used')
        return json.loads(self.cipher.decrypt(row['sealed'].encode()))
    def flow_page(self,request,kind,payload,**context):
        flow,csrf,browser=self.new_flow(request,kind,payload)
        response=self.page('identity',kind=kind,flow=flow,csrf=csrf,**context)
        response.set_cookie('fp_oidc_browser',browser,secure=True,httponly=True,samesite='lax',max_age=600)
        if kind=='login':response.set_cookie('fp_oidc_resume',flow,secure=True,httponly=True,samesite='lax',max_age=300)
        return response

    def check_authorization(self,details):
        query=parse_qs(urlsplit(details.get('request_url','')).query)
        if query.get('code_challenge_method')!=['S256'] or not query.get('code_challenge'):raise HTTPException(400,'This application must use PKCE S256')
        return query

    def fresh_login_required(self,details,user):
        query=self.check_authorization(details)
        if 'login' in query.get('prompt',[''])[0].split():return True
        if 'max_age' in query:
            try:age=int(query['max_age'][0])
            except ValueError:raise HTTPException(400,'Invalid sign-in age')
            if age<0 or age==0 or time.time()-user.get('authenticated_at',0)>age:return True
        return False

    def login_accept(self,request,challenge,user,response=None):
        details=self.gateway.call('get_o_auth2_login_request',login_challenge=challenge)
        self.check_authorization(details)
        with self.engine.begin() as db:
            state=self.state(db,user['id'],True)
            current=self.central(request,db)
            # POST authentication may just have created a new session response.
            if state['suspended'] or (response is None and (not current or current['id']!=user['id'])):raise HTTPException(401,'Sign in again to continue')
            mapped=self.mapped(db,user['id'])
            reg,policy=self.policy(db,details['client']['client_id'])
            role='admin' if user['admin'] else 'farmer'
            if role not in policy['allowed_roles']:raise HTTPException(403,'This account is not allowed to open the application')
            if details.get('skip') and details.get('subject') and details['subject']!=mapped['student_id']:raise HTTPException(409,'A different person is signed in to this browser. Sign out before changing accounts.')
            result=self.gateway.call('accept_o_auth2_login_request',login_challenge=challenge,accept_o_auth2_login_request=hydra.AcceptOAuth2LoginRequest(subject=mapped['student_id'],remember=True,remember_for=43200,context={'epoch':state['epoch'],'client_revision':reg['revision']},amr=['pwd']))
        destination=self.redirect(result['redirect_to'])
        if response:
            for k,v in response.raw_headers:
                if k==b'set-cookie':destination.raw_headers.append((k,v))
        return destination

    def consent_accept(self,request,challenge,approved):
        details=self.gateway.call('get_o_auth2_consent_request',consent_challenge=challenge)
        self.check_authorization(details)
        with self.engine.begin() as db:
            user=self.central(request,db)
            if not user:raise HTTPException(401,'Sign in to FarmerPlus again')
            state=self.state(db,user['id'],True);mapped=self.mapped(db,user['id'])
            if state['suspended'] or mapped['student_id']!=details['subject']:raise HTTPException(403,'This request belongs to another account')
            context=details.get('context') or {}
            reg,policy=self.policy(db,details['client']['client_id'])
            if ('admin' if user['admin'] else 'farmer') not in policy['allowed_roles']:raise HTTPException(403,'This account cannot open the application')
            if context.get('epoch')!=state['epoch'] or context.get('client_revision')!=reg['revision']:raise HTTPException(403,'Account or application access changed. Start again.')
            if not approved:
                result=self.gateway.call('reject_o_auth2_consent_request',consent_challenge=challenge,reject_o_auth2_request=hydra.RejectOAuth2Request(error='access_denied',error_description='The request was cancelled'))
                return self.redirect(result['redirect_to'])
            granted=sorted(set(details.get('requested_scope',[])) & set(policy['scopes']))
            audience=sorted(set(details.get('requested_access_token_audience',[])) & set(policy['audiences']))
            claims={}
            if 'profile' in granted:claims.update(name=' '.join(x for x in [mapped['firstname'],mapped['lastname']] if x),given_name=mapped['firstname'],family_name=mapped['lastname'])
            if policy['first_party'] and 'farmerplus.identity' in granted:claims['farmerplus_id']=mapped['student_id']
            if 'email' in granted:
                contact=db.execute(select(self.contacts).where(self.contacts.c.owner==user['id'],self.contacts.c.verified==True)).mappings().first()
                if contact:claims.update(email=contact['email'],email_verified=True)
            result=self.gateway.call('accept_o_auth2_consent_request',consent_challenge=challenge,accept_o_auth2_consent_request=hydra.AcceptOAuth2ConsentRequest(grant_scope=granted,grant_access_token_audience=audience,remember=False,session=hydra.AcceptOAuth2ConsentRequestSession(id_token=claims,access_token={'account_epoch':state['epoch']})))
            self.log(db,user['id'],'consent',reg['id'],'accepted')
        return self.redirect(result['redirect_to'])

    def queue_revoke(self,db,owner=None,client=None,suspend=None):
        subject=None;epoch=None
        if owner:
            state=self.state(db,owner,True);epoch=state['epoch']+1
            values={'epoch':epoch}
            if suspend is not None:values['suspended']=suspend
            db.execute(update(security).where(security.c.owner==owner).values(**values))
            subject=self.mapped(db,owner)['student_id']
            db.execute(delete(self.sessions).where(self.sessions.c.owner==owner))
            db.execute(delete(app_sessions).where(app_sessions.c.owner==owner))
            db.execute(delete(seen_sessions).where(seen_sessions.c.owner==owner))
            db.execute(delete(reauth).where(reauth.c.owner==owner))
        if client:db.execute(delete(app_sessions).where(app_sessions.c.client==client))
        if client:db.execute(delete(seen_sessions).where(seen_sessions.c.client==client))
        key=str(uuid4())
        db.execute(insert(outbox).values(id=key,subject=subject,client=client,epoch=epoch,created=int(time.time()),next_attempt=0,attempts=0,status='pending'))
        # API tokens from Android/web are checked on every Learning API request.
        # Learning browser sessions have their own client and separate grants.
        learning_client=os.getenv('FARMER_LEARNING_CLIENT_ID','farmerplus-learning-staging')
        if owner or client==learning_client:db.execute(insert(rp_delivery).values(event=key,client=learning_client))
        return key
    def drain(self):
        if not self.enabled:return
        with self.engine.connect() as db:rows=db.execute(select(outbox).where(outbox.c.status=='pending',outbox.c.next_attempt<=int(time.time())).limit(20)).mappings().all()
        for row in rows:
            try:
                self.revoke_provider_grants(row['subject'],row['client'])
                if row['subject']:self.gateway.call('revoke_o_auth2_login_sessions',subject=row['subject'])
                if row['client']:
                    with self.engine.connect() as db:client=db.execute(select(registry).where(registry.c.id==row['client'])).mappings().first()
                    if client and not client['enabled'] and client['status']=='revoking':
                        self.gateway.call('delete_o_auth2_client',id=row['client'])
                        with self.engine.begin() as db:db.execute(update(registry).where(registry.c.id==row['client']).values(status='disabled',error=None))
                with self.engine.begin() as db:db.execute(update(outbox).where(outbox.c.id==row['id']).values(status='provider_revoked',error=None))
            except HTTPException:
                with self.engine.begin() as db:db.execute(update(outbox).where(outbox.c.id==row['id']).values(attempts=row['attempts']+1,next_attempt=int(time.time())+min(300,5*2**min(row['attempts'],6)),error='Provider revocation pending; retry scheduled'))

    def revoke_provider_grants(self,subject=None,client=None):
        # Hydra v26.2 requires subject+all OR subject+client, never client+all.
        if subject:
            self.gateway.call('revoke_o_auth2_consent_sessions',subject=subject,client=client,all=not bool(client))
        elif client:
            with self.engine.connect() as db:subjects=db.execute(select(self.students.c.student_id)).scalars().all()
            for person in subjects:self.gateway.call('revoke_o_auth2_consent_sessions',subject=person,client=client,all=False)
        else:raise HTTPException(500,'A revocation target is required')

    def introspect(self,token,audience,scopes,expected_client=None):
        if token.startswith(('fpn_', 'fpl_')):
            return self.app.state.native.introspect(token,audience,scopes,expected_client)
        self.require_enabled()
        value=self.gateway.call('introspect_o_auth2_token',token=token,scope=' '.join(scopes))
        if value.get('iss') not in (None,self.issuer):raise HTTPException(401,'Token issuer mismatch')
        if not value.get('active') or value.get('token_use') not in (None,'access_token') or audience not in (value.get('aud') or []) or value.get('exp',0)<=time.time():raise HTTPException(401,'Access is expired or not valid for this service')
        if expected_client and value.get('client_id')!=expected_client:raise HTTPException(401,'This token belongs to another application')
        if not set(scopes)<=set((value.get('scope') or '').split()):raise HTTPException(403,'This action is outside the approved access')
        with self.engine.begin() as db:
            reg,policy=self.policy(db,value.get('client_id'))
            if audience not in policy['audiences'] or not set(scopes)<=set(policy['scopes']):raise HTTPException(403,'The application is not approved for this service')
            mapped=db.execute(select(self.students).where(self.students.c.student_id==value.get('sub'))).mappings().first()
            if not mapped:raise HTTPException(401,'Unknown permanent identity')
            state=self.state(db,mapped['owner'])
            if state['suspended'] or (value.get('ext') or {}).get('account_epoch')!=state['epoch']:raise HTTPException(401,'Account access has changed. Sign in again.')
            user=dict(db.execute(select(self.users).where(self.users.c.id==mapped['owner'])).mappings().one())
            if ('admin' if user['admin'] else 'farmer') not in policy['allowed_roles']:raise HTTPException(403,'Account role is outside the approved policy')
            db.execute(update(registry).where(registry.c.id==reg['id']).values(last_use=int(time.time())))
            now=int(time.time())
            stmt=pg_insert(seen_sessions) if db.dialect.name=='postgresql' else sqlite_insert(seen_sessions)
            db.execute(stmt.values(hash=sha(token),owner=user['id'],client=reg['id'],first_seen=now,last_seen=now,expires=value['exp'],epoch=state['epoch']).on_conflict_do_update(index_elements=['hash'],set_={'last_seen':now,'expires':value['exp']}))
            db.execute(delete(seen_sessions).where(seen_sessions.c.expires<now))
        return user,value

    def resource_identity(self,request):
        auth=request.headers.get('authorization','')
        client=None
        if auth.startswith('Bearer '):
            token=auth[7:];client=os.getenv('FARMER_ANDROID_CLIENT_ID')
            if not client:raise HTTPException(503,'Android client registration is missing')
        else:
            token,client=self.browser_token(request)
        scope='farm:write' if request.method in {'POST','PUT','PATCH','DELETE'} else 'farm:read'
        user,value=self.introspect(token,'farmerplus-api',[scope],client)
        request.state.credential_epoch=value['ext']['account_epoch']
        return user

    def web_secret(self):
        client=os.getenv('FARMER_WEB_CLIENT_ID','')
        with self.engine.connect() as db:row=db.execute(select(rp_credentials).where(rp_credentials.c.client==client)).mappings().first()
        return self.cipher.decrypt(row['sealed'].encode()).decode() if row else os.getenv('FARMER_WEB_CLIENT_SECRET','')

    def browser_token(self,request):
        key=sha(request.cookies.get('fp_app',''))
        with self.engine.begin() as db:
            first=db.execute(select(app_sessions).where(app_sessions.c.hash==key)).mappings().first()
            if not first:raise HTTPException(401,'Sign in to FarmerPlus')
            state=self.state(db,first['owner'],True)
            # Security state is locked first everywhere; token refresh and global
            # revocation cannot deadlock through opposite session lock ordering.
            db.execute(update(app_sessions).where(app_sessions.c.hash==key).values(expires=app_sessions.c.expires))
            row=db.execute(select(app_sessions).where(app_sessions.c.hash==key,app_sessions.c.expires>int(time.time()))).mappings().first()
            central=self.central(request,db)
            if not row or state['suspended'] or state['epoch']!=row['epoch']:raise HTTPException(401,'Account access changed. Sign in again.')
            if not central or central['id']!=row['owner']:raise HTTPException(409,'The active browser account differs. Sign in again to continue.')
            self.policy(db,row['client'])
            token=json.loads(self.cipher.decrypt(row['sealed'].encode()))
            if token.get('expires_at',0)<=time.time()+30:
                if not token.get('refresh_token'):raise HTTPException(401,'Open sign-in to renew your access')
                try:
                    with OAuth2Client(row['client'],self.web_secret(),token_endpoint_auth_method='client_secret_basic',timeout=15) as client:
                        renewed=client.refresh_token(getattr(self,'token_endpoint',self.issuer+'/oauth2/token'),refresh_token=token['refresh_token'])
                    if not renewed.get('access_token'):raise ValueError()
                    token={**token,**renewed}
                    db.execute(update(app_sessions).where(app_sessions.c.hash==key).values(sealed=self.cipher.encrypt(compact(token).encode()).decode()))
                except httpx.TransportError:raise HTTPException(503,'Sign-in service is temporarily unavailable. Try again when connected.') from None
                except Exception:raise HTTPException(401,'Account access could not be renewed. Open sign-in again.') from None
            return token['access_token'],row['client']

    def web_rp(self):
        client=os.getenv('FARMER_WEB_CLIENT_ID','')
        secret=self.web_secret()
        oauth=OAuth()
        return oauth.register('farmerplus',client_id=client,client_secret=secret,server_metadata_url=self.issuer+'/.well-known/openid-configuration',client_kwargs={'scope':'openid profile farmerplus.identity farm:read farm:write learning:courses:read learning:content:read offline_access','code_challenge_method':'S256','token_endpoint_auth_method':'client_secret_basic'})

    def mount(self):
        app=self.app
        def learning_token(request,scope):
            auth=request.headers.get('authorization','')
            if auth.startswith('Bearer '):token=auth[7:];client=os.environ['FARMER_ANDROID_CLIENT_ID']
            else:
                token,client=self.browser_token(request)
            user,claims=self.introspect(token,'farmerplus-learning-api',[scope],client)
            return token,user
        async def read_learning(request,resource,**params):
            scope='learning:courses:read' if resource=='courses' else 'learning:content:read'
            token,user=learning_token(request,scope)
            if token.startswith('fpn_') and os.getenv('FARMER_NATIVE_LEARNING_ENABLED') != '1':
                raise HTTPException(503,'The Learning connection has not been activated yet. Saved lessons remain available.')
            origin=os.environ.get('FARMER_LEARNING_ORIGIN','')
            tenancy=getattr(app.state,'tenancy',None)
            tenant_context=None
            if tenancy:
                tenant_context=tenancy.context(user,request.query_params.get('tenant') or 'farmerplus')
                # Separate tenant RPs need their own token audiences, launch keys and
                # tested Moodle boundary. Do not forward FarmerPlus bearer tokens there.
                if tenant_context['id']!='farmerplus':
                    raise HTTPException(503,'This tenant Learning connection is not activated')
                if resource in {'manifest','text','chunk'} and not tenant_context['offline']:
                    raise HTTPException(403,'New offline downloads are disabled for this tenant. Existing device data is retained.')
            exact_uri(origin+'/')
            try:
                async with httpx.AsyncClient(timeout=20,follow_redirects=False) as client:
                    response=await client.get(origin+'/auth/farmerplusoidc/api.php',params={'resource':resource,**params},headers={'Authorization':'Bearer '+token,'Accept':'application/json'})
                    if resource=='chunk' and response.status_code==409:raise HTTPException(409,'This lesson changed. Check for updates in Download, then resume.')
                    if resource=='chunk' and response.status_code==422:raise HTTPException(422,'The saved partial download does not match this lesson. Cancel it and download again.')
                    if response.status_code==403:raise HTTPException(403,'Open Learning online to finish connecting your account or check your course access.')
                    if response.status_code!=200:raise HTTPException(503,'Learning is temporarily unavailable. Saved lessons remain on your device.')
                    if len(response.content)>2200000:raise HTTPException(502,'Learning response exceeded the supported size')
                    payload=response.json()
                    if tenant_context:
                        if resource in {'manifest','text','chunk'}:
                            from tenancy import courses as commerce_courses
                            cid=payload.get('courseid')
                            if type(cid) is not int or cid<1:
                                raise HTTPException(503,'The offline Learning API upgrade is not active. Existing downloads remain available.')
                            with self.engine.connect() as db:
                                course_policy=db.execute(select(commerce_courses.c.offline).where(
                                    commerce_courses.c.tenant==tenant_context['id'],commerce_courses.c.courseid==cid)).first()
                            if course_policy is not None and not course_policy[0]:
                                raise HTTPException(403,'New downloads are disabled for this course. Existing device data is retained.')
                        payload['tenant_id']=tenant_context['id']
                        payload['instance_id']='farmerplus-learning'
                        payload['offline_enabled']=tenant_context['offline']
                    return payload
            except HTTPException:raise
            except Exception:raise HTTPException(503,'Learning could not be reached') from None
        @app.get('/learning/courses')
        async def learning_courses(request:Request,offset:int=0):
            if not 0<=offset<=10000:raise HTTPException(422,'Invalid course offset')
            return await read_learning(request,'courses',offset=offset)
        @app.get('/learning/activities/{courseid}')
        async def learning_activities(request:Request,courseid:int):
            if courseid<1:raise HTTPException(422,'Invalid course')
            return await read_learning(request,'activities',courseid=courseid)
        @app.get('/learning/text/{cmid}')
        async def learning_text(request:Request,cmid:int):
            if cmid<1:raise HTTPException(422,'Invalid activity')
            return await read_learning(request,'text',cmid=cmid)
        @app.get('/learning/manifest/{courseid}')
        async def learning_manifest(request:Request,courseid:int):
            if courseid<1:raise HTTPException(422,'Invalid course')
            return await read_learning(request,'manifest',courseid=courseid)
        @app.get('/learning/download/{cmid}')
        async def learning_download(request:Request,cmid:int,offset:int=0,version:str=''):
            if cmid<1 or not 0<=offset<=8392704 or not re.fullmatch(r'[a-f0-9]{64}',version):raise HTTPException(422,'Invalid resource request')
            return await read_learning(request,'chunk',cmid=cmid,offset=offset,version=version)
        @app.get('/login')
        def entry(request:Request):
            self.require_enabled()
            with self.engine.connect() as db:
                flow=db.execute(select(flows).where(flows.c.hash==sha(request.cookies.get('fp_oidc_resume','')),flows.c.kind=='login',flows.c.browser==sha(request.cookies.get('fp_oidc_browser','')),flows.c.expires>int(time.time()))).mappings().first()
                if flow:
                    payload=json.loads(self.cipher.decrypt(flow['sealed'].encode()))
                    return RedirectResponse('/oidc/login?'+urlencode({'login_challenge':payload['challenge']}),303)
            return RedirectResponse('/oidc/web/login',303)
        @app.get('/account/create')
        def create_page(request:Request):
            self.require_enabled()
            if self.central(request):return RedirectResponse('/account',303)
            return self.page('identity',kind='create')
        @app.get('/account/recover')
        def recover_page():return self.page('identity',kind='recover')
        @app.get('/account')
        def account_page(request:Request):
            user=self.central(request)
            if not user:return RedirectResponse('/login',303)
            with self.engine.begin() as db:mapped=self.mapped(db,user['id'])
            identities=getattr(self.app.state,'email_auth',None)
            profile=identities.profile(user['id']) if identities else None
            email=profile['email'] if profile else None
            return self.page('identity',kind='account',name=' '.join([mapped['firstname'],mapped['lastname']]).strip() or email or user['username'],username=user['username'],email=email,farmerplus_id=mapped['student_id'])
        @app.get('/account/recovery-codes')
        def reissue_page(request:Request):
            if not self.central(request):return RedirectResponse('/login',303)
            return self.page('identity',kind='reissue')
        @app.get('/account/credentials')
        def credentials_page(request:Request):
            if not self.central(request):return RedirectResponse('/login',303)
            return self.page('identity',kind='credentials')
        @app.get('/account/profile')
        def profile_page(request:Request):
            user=self.central(request)
            if not user:return RedirectResponse('/login',303)
            with self.engine.begin() as db:
                mapped=self.mapped(db,user['id']);contact=db.execute(select(self.contacts).where(self.contacts.c.owner==user['id'])).mappings().first()
            return self.page('identity',kind='profile',firstname=mapped['firstname'],lastname=mapped['lastname'],email=contact['email'] if contact else '')
        @app.post('/account/profile')
        async def update_profile(request:Request):
            user=self.central(request)
            if not user:raise HTTPException(401,'Sign in to edit your profile')
            self.throttle(request,'profile:'+user['id'],force=True)
            body=await request.json()
            first=str(body.get('firstname','')).strip();last=str(body.get('lastname','')).strip();email=body.get('email')
            if not first or not last or len(first)>100 or len(last)>100:raise HTTPException(422,'Enter your first and last names, each up to 100 characters')
            if email is not None and (not isinstance(email,str) or len(email)>254 or not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+',email)):raise HTTPException(422,'Enter a valid optional email')
            with self.engine.begin() as db:
                self.state(db,user['id'],True)
                current=db.execute(select(self.users).where(self.users.c.id==user['id'])).mappings().one()
                if not self.central(request,db) or not self.password_matches(str(body.get('current_password','')),current['password']):raise HTTPException(401,'Current password was not accepted')
                db.execute(update(self.students).where(self.students.c.owner==user['id']).values(firstname=first,lastname=last))
                contact=db.execute(select(self.contacts).where(self.contacts.c.owner==user['id'])).mappings().first()
                if (contact['email'] if contact else None)!=(email.lower() if email else None):
                    db.execute(delete(self.contacts).where(self.contacts.c.owner==user['id']))
                    if email:db.execute(insert(self.contacts).values(owner=user['id'],email=email.lower(),verified=False))
                self.log(db,user['id'],'profile',user['id'],'updated')
            return {'updated':True}
        @app.get('/oidc/config')
        def config():
            return {'enabled':self.enabled,'issuer':self.issuer or None,'webSignIn':self.origin+'/oidc/web/login' if self.enabled else None,'androidClientId':os.getenv('FARMER_ANDROID_CLIENT_ID') or None,'androidRedirect':os.getenv('FARMER_ANDROID_REDIRECT') or None,'learningUrl':os.getenv('FARMER_LEARNING_ORIGIN') or None,'environment':self.environment}
        @app.get('/oidc/web/login')
        async def web_login(request:Request):
            self.require_enabled();rp=self.web_rp()
            metadata=await rp.load_server_metadata()
            if metadata.get('issuer')!=self.issuer:raise HTTPException(503,'Provider discovery does not match the configured issuer')
            data=await rp.create_authorization_url(redirect_uri=self.origin+'/oidc/web/callback',audience='farmerplus-api farmerplus-learning-api')
            flow,_,browser=self.new_flow(request,'web',data,csrf_override=data['state'])
            response=self.redirect(data['url'])
            response.set_cookie('fp_oidc_browser',browser,secure=True,httponly=True,samesite='lax',max_age=600)
            response.set_cookie('fp_oidc_client',flow,secure=True,httponly=True,samesite='lax',max_age=300)
            return response
        @app.post('/oidc/native/verify')
        async def native_verify(request:Request):
            self.require_enabled()
            token=request.headers.get('authorization','').removeprefix('Bearer ')
            client=os.environ['FARMER_ANDROID_CLIENT_ID']
            user,value=self.introspect(token,'farmerplus-api',['farm:read'],client)
            body=await request.json();nonce=body.get('nonce');id_token=body.get('id_token')
            if not isinstance(nonce,str) or not 32<=len(nonce)<=256 or not isinstance(id_token,str) or len(id_token)>16000:raise HTTPException(422,'Invalid sign-in verification request')
            try:
                oauth=OAuth();rp=oauth.register('native',client_id=client,server_metadata_url=self.issuer+'/.well-known/openid-configuration')
                metadata=await rp.load_server_metadata()
                if metadata.get('issuer')!=self.issuer:raise ValueError()
                rp.server_metadata['id_token_signing_alg_values_supported']=['RS256']
                claims=await rp.parse_id_token({'access_token':token,'id_token':id_token,'token_type':'Bearer'},nonce=nonce,claims_options={'iss':{'essential':True,'value':self.issuer},'aud':{'essential':True,'value':client},'exp':{'essential':True},'nonce':{'essential':True,'value':nonce}},leeway=5)
                if claims.get('nonce_supported') is False or claims.get('sub')!=value['sub'] or claims.get('farmerplus_id')!=value['sub']:raise ValueError()
            except Exception:raise HTTPException(401,'Mobile sign-in could not be verified') from None
            with self.engine.begin() as db:
                state=self.state(db,user['id'],True)
                if state['suspended'] or value['ext']['account_epoch']!=state['epoch']:raise HTTPException(401,'Account access changed during sign-in')
            return {'verified':True,'farmerplusId':value['sub'],'issuer':self.issuer,'expires':value['exp'],'offlineSeconds':86400}
        @app.get('/oidc/web/callback')
        async def web_callback(request:Request):
            self.require_enabled()
            payload=self.consume_flow(request,request.cookies.get('fp_oidc_client',''),request.query_params.get('state',''),'web')
            if request.query_params.get('error'):return self.page('identity',kind='error',message='Sign-in was cancelled. Your saved records are unchanged.')
            code=request.query_params.get('code')
            if not code:raise HTTPException(400,'Authorization code is missing')
            try:
                rp=self.web_rp();metadata=await rp.load_server_metadata()
                if metadata.get('issuer')!=self.issuer or 'RS256' not in metadata.get('id_token_signing_alg_values_supported',[]):raise ValueError()
                # Restrict the library's permitted algorithms to this reviewed policy.
                rp.server_metadata['id_token_signing_alg_values_supported']=['RS256']
                token=await rp.fetch_access_token(redirect_uri=self.origin+'/oidc/web/callback',code=code,code_verifier=payload['code_verifier'])
                claims=await rp.parse_id_token(token,nonce=payload['nonce'],claims_options={'iss':{'essential':True,'value':self.issuer},'aud':{'essential':True,'value':os.environ['FARMER_WEB_CLIENT_ID']},'exp':{'essential':True},'nonce':{'essential':True,'value':payload['nonce']}},leeway=5)
                if claims.get('nonce_supported') is False:raise ValueError()
            except Exception:raise HTTPException(401,'Sign-in could not be verified. Start again.') from None
            user,value=self.introspect(token['access_token'],'farmerplus-api',['farm:read'],os.environ['FARMER_WEB_CLIENT_ID'])
            if claims.get('sub')!=value['sub'] or claims.get('farmerplus_id')!=value['sub']:raise HTTPException(401,'Verified identity claims do not match')
            with self.engine.begin() as db:
                state=self.state(db,user['id'],True);central=self.central(request,db)
                if state['suspended'] or not central or central['id']!=user['id'] or value['ext']['account_epoch']!=state['epoch']:raise HTTPException(409,'The browser account changed during sign-in')
                key=secrets.token_urlsafe(32)
                db.execute(insert(app_sessions).values(hash=sha(key),owner=user['id'],client=value['client_id'],epoch=state['epoch'],sealed=self.cipher.encrypt(compact(token).encode()).decode(),expires=int(time.time())+43200))
            response=RedirectResponse('/?signed_in=1',303);response.set_cookie('fp_app',key,secure=True,httponly=True,samesite='lax',max_age=43200);response.delete_cookie('fp_oidc_client')
            return response
        @app.get('/oidc/logout')
        def logout_prompt(request:Request,logout_challenge:str):
            self.require_enabled();details=self.gateway.call('get_o_auth2_logout_request',logout_challenge=logout_challenge)
            user=self.central(request)
            if user:
                with self.engine.begin() as db:mapped=self.mapped(db,user['id'])
                if details.get('subject') and mapped['student_id']!=details['subject']:raise HTTPException(409,'This sign-out request belongs to another browser account')
            return self.flow_page(request,'logout',{'challenge':logout_challenge},application='FarmerPlus')
        @app.post('/oidc/logout')
        async def logout_accept(request:Request):
            form=await request.form();payload=self.consume_flow(request,str(form.get('flow','')),str(form.get('csrf','')),'logout')
            details=self.gateway.call('get_o_auth2_logout_request',logout_challenge=payload['challenge']);user=self.central(request)
            if user:
                with self.engine.begin() as db:
                    mapped=self.mapped(db,user['id'])
                    if details.get('subject') and details['subject']!=mapped['student_id']:raise HTTPException(409,'Browser identity mismatch')
                    self.queue_revoke(db,owner=user['id'])
            result=self.gateway.call('accept_o_auth2_logout_request',logout_challenge=payload['challenge'])
            response=self.redirect(result['redirect_to']);response.delete_cookie(self.app.state.session_cookie);response.delete_cookie('fp_app')
            self.drain();return response
        @app.get('/oidc/signed-out')
        def signed_out():return self.page('identity',kind='error',message='Signed out on this browser. Other applications revalidate their online sessions; offline devices check when they reconnect.')
        @app.get('/oidc/login')
        def login(request:Request,login_challenge:str):
            self.require_enabled()
            details=self.gateway.call('get_o_auth2_login_request',login_challenge=login_challenge)
            self.check_authorization(details)
            with self.engine.begin() as db:self.policy(db,details['client']['client_id'])
            user=self.central(request)
            if user and not self.fresh_login_required(details,user):return self.login_accept(request,login_challenge,user)
            return self.flow_page(request,'login',{'challenge':login_challenge},application=details['client'].get('client_name','FarmerPlus'))
        @app.post('/oidc/login')
        async def login_post(request:Request):
            form=await request.form();payload=self.consume_flow(request,str(form.get('flow','')),str(form.get('csrf','')),'login')
            if form.get('decision')=='cancel':
                result=self.gateway.call('reject_o_auth2_login_request',login_challenge=payload['challenge'],reject_o_auth2_request=hydra.RejectOAuth2Request(error='access_denied',error_description='Sign-in cancelled'))
                return self.redirect(result['redirect_to'])
            username=str(form.get('username','')).lower().strip();password=str(form.get('password',''))
            self.throttle(request,username)
            self.throttle(request,'login-all',limit=120)
            if len(username)>64 or len(password)>256:raise HTTPException(401,'Username or password was not accepted')
            with self.engine.begin() as db:
                user=db.execute(select(self.users).where(self.users.c.username==username)).mappings().first()
                if not user:
                    self.password_matches(password,'00'*16+':'+'00'*32)
                    raise HTTPException(401,'Username or password was not accepted. Open sign-in again to retry.')
                user=dict(user);state=self.state(db,user['id'],True)
                current=db.execute(select(self.users).where(self.users.c.id==user['id'])).mappings().one()
                if not self.password_matches(password,current['password']):raise HTTPException(401,'Username or password was not accepted. Open sign-in again to retry.')
                if state['suspended']:raise HTTPException(403,'This account is suspended')
                response=JSONResponse({})
                self.issue_session(db,user,response)
                # Keep the security-row lock while accepting to serialize recovery.
                details=self.gateway.call('get_o_auth2_login_request',login_challenge=payload['challenge'])
                self.check_authorization(details)
                reg,policy=self.policy(db,details['client']['client_id']);mapped=self.mapped(db,user['id'])
                if ('admin' if user['admin'] else 'farmer') not in policy['allowed_roles']:raise HTTPException(403,'This account is not allowed to open this application')
                existing=self.central(request,db)
                if existing and existing['id']!=user['id']:raise HTTPException(409,'Sign out of the existing browser account before changing people')
                if details.get('skip') and details.get('subject')!=mapped['student_id']:raise HTTPException(409,'A different person has a remembered browser session')
                result=self.gateway.call('accept_o_auth2_login_request',login_challenge=payload['challenge'],accept_o_auth2_login_request=hydra.AcceptOAuth2LoginRequest(subject=mapped['student_id'],remember=True,remember_for=43200,context={'epoch':state['epoch'],'client_revision':reg['revision']},amr=['pwd']))
            dest=self.redirect(result['redirect_to'])
            for k,v in response.raw_headers:
                if k==b'set-cookie':dest.raw_headers.append((k,v))
            return dest
        @app.get('/oidc/consent')
        def consent(request:Request,consent_challenge:str):
            self.require_enabled();details=self.gateway.call('get_o_auth2_consent_request',consent_challenge=consent_challenge)
            with self.engine.begin() as db:reg,p=self.policy(db,details['client']['client_id'])
            if p['first_party'] and p['preauthorized']:return self.consent_accept(request,consent_challenge,True)
            return self.flow_page(request,'consent',{'challenge':consent_challenge},application=p['name'],scopes=sorted(set(details.get('requested_scope',[])) & set(p['scopes'])))
        @app.post('/oidc/consent')
        async def consent_post(request:Request):
            form=await request.form();payload=self.consume_flow(request,str(form.get('flow','')),str(form.get('csrf','')),'consent')
            return self.consent_accept(request,payload['challenge'],form.get('decision')=='allow')
        @app.get('/oidc/error')
        def oidc_error():return self.page('identity',kind='error',message='Sign-in could not finish. Open FarmerPlus and try again.')
        @app.post('/oidc/resource/learning-introspect')
        async def learning_introspect(request:Request):
            expected=os.getenv('FARMER_LEARNING_INTROSPECTION_SECRET','')
            supplied=request.headers.get('authorization','').removeprefix('Bearer ')
            if len(expected)<32 or not hmac.compare_digest(expected,supplied):raise HTTPException(403,'Server authentication required')
            try:
                body=await request.json() if request.headers.get('content-type','').startswith('application/json') else dict(await request.form())
                if not isinstance(body,dict):raise ValueError()
            except Exception:raise HTTPException(400,'Invalid introspection request body') from None
            scope=body.get('scope','')
            if scope not in {'learning:courses:read','learning:content:read'}:raise HTTPException(403,'Unsupported learning access')
            token=body.get('token','')
            if not isinstance(token,str) or not 16<=len(token)<=16384:raise HTTPException(422,'Invalid token format')
            try:user,value=self.learning_introspection(token,scope)
            except HTTPException as error:
                if error.status_code in (401,403):return {'active':False}
                raise
            return {'active':True,'iss':self.issuer,'sub':value['sub'],'farmerplus_id':value.get('farmerplus_id',value['sub']),'scope':value['scope'],'aud':value['aud'],'client_id':value['client_id'],'exp':value['exp'],'epoch':value['ext']['account_epoch']}
        def learning_service(request):
            self.require_enabled()
            expected=os.getenv('FARMER_LEARNING_INTROSPECTION_SECRET','')
            supplied=request.headers.get('authorization','').removeprefix('Bearer ')
            if len(expected)<32 or not hmac.compare_digest(expected,supplied):raise HTTPException(403,'Server authentication required')
            return os.getenv('FARMER_LEARNING_CLIENT_ID','farmerplus-learning-staging')
        @app.post('/oidc/resource/learning-revocations')
        def pending_learning_revocations(request:Request):
            client=learning_service(request)
            with self.engine.connect() as db:
                pending=db.execute(select(outbox).join(rp_delivery,rp_delivery.c.event==outbox.c.id).where(rp_delivery.c.client==client,rp_delivery.c.acknowledged.is_(None)).order_by(outbox.c.created).limit(100)).mappings().all()
            return {'events':[{'id':r['id'],'type':'account_revoked' if r['subject'] else 'client_disabled','sub':self.revocation_subject(r['subject']) if hasattr(self,'revocation_subject') else r['subject'],'client_id':client,'created':r['created']} for r in pending]}
        @app.post('/oidc/resource/learning-revocations/ack')
        async def acknowledge_learning_revocation(request:Request):
            client=learning_service(request);body=await request.json()
            event=body.get('id')
            if not isinstance(event,str) or len(event)!=36:raise HTTPException(422,'Invalid event reference')
            with self.engine.begin() as db:
                row=db.execute(select(rp_delivery).where(rp_delivery.c.event==event,rp_delivery.c.client==client)).mappings().first()
                if not row:raise HTTPException(404,'Delivery not found')
                if row['acknowledged'] is None:db.execute(update(rp_delivery).where(rp_delivery.c.event==event,rp_delivery.c.client==client).values(acknowledged=int(time.time())))
            return {'acknowledged':True}
        @app.get('/admin/identity')
        def admin_page(request:Request):
            user=self.central(request)
            if not user or not user['admin']:return self.page('identity',kind='admin_login',message='Sign in with your FarmerPlus administrator account.')
            response=self.page('admin_identity',environment=self.environment)
            response.set_cookie('__Host-fp_csrf' if self.enabled else 'fp_csrf',secrets.token_urlsafe(32),secure=self.enabled,httponly=False,samesite='strict')
            return response
        @app.get('/admin/identity/context')
        def admin_context(request:Request):
            user=self.admin(request)
            return {'username':user['username'],'environment':self.environment,'configured':self.enabled,'issuer':self.issuer or None}
        @app.post('/admin/identity/reauthenticate')
        async def reauthenticate(request:Request):
            user=self.admin(request);self.csrf(request,request.headers.get('x-csrf-token',''));self.throttle(request,'admin-reauth:'+user['id'],force=True)
            body=await request.json()
            with self.engine.begin() as db:
                current=db.execute(select(self.users).where(self.users.c.id==user['id'])).mappings().one();state=self.state(db,user['id'],True)
                if state['suspended'] or not self.password_matches(str(body.get('password','')),current['password']):raise HTTPException(401,'Password was not accepted')
                key=secrets.token_urlsafe(32)
                db.execute(insert(reauth).values(hash=sha(key),owner=user['id'],session=sha(request.cookies[self.app.state.session_cookie]),epoch=state['epoch'],expires=int(time.time())+300))
            return {'reauthentication':key,'expiresIn':300}
        @app.get('/admin/identity/applications')
        def list_apps(request:Request):
            self.admin(request)
            with self.engine.connect() as db:local=[dict(r) for r in db.execute(select(registry)).mappings()]
            try:
                self.require_enabled();remote=self.gateway.call('list_o_auth2_clients',page_size=1000);byid={r['client_id']:r for r in remote};available=True
            except HTTPException:byid={};available=False
            result=[]
            for r in local:
                p=json.loads(r['policy']);live=byid.pop(r['id'],None)
                result.append({**p,'enabled':r['enabled'],'status':r['status'],'lastSuccessfulUse':r['last_use'],'health':'unavailable' if not available else 'registered' if live else 'absent','error':r['error'],'revision':r['revision'],'provider':self.safe_client(live) if live else None})
            result += [{'id':k,'name':v.get('client_name') or k,'status':'unmanaged','health':'registered','enabled':False,'provider':self.safe_client(v)} for k,v in byid.items()]
            return {'applications':result,'providerAvailable':available,'truncated':len(byid)>=1000}
        @app.post('/admin/identity/applications')
        async def create_application(request:Request,body:Application):
            actor=self.admin(request,True);return self.register_client(body,actor['id'],False)
        @app.put('/admin/identity/applications/{client}')
        async def edit_application(client:str,request:Request,body:Application):
            actor=self.admin(request,True)
            if body.id!=client:raise HTTPException(422,'Client ID cannot be renamed')
            return self.register_client(body,actor['id'],True)
        @app.post('/admin/identity/applications/{client}/disable')
        def disable_application(client:str,request:Request):
            actor=self.admin(request,True);self.require_enabled()
            with self.engine.begin() as db:
                reg,p=self.policy(db,client)
                db.execute(update(registry).where(registry.c.id==client).values(enabled=False,status='revoking',revision=reg['revision']+1))
                self.queue_revoke(db,client=client);self.log(db,actor['id'],'disable',client,'pending')
            try:
                self.revoke_provider_grants(client=client)
                self.gateway.call('delete_o_auth2_client',id=client)
            except HTTPException:
                with self.engine.begin() as db:db.execute(update(registry).where(registry.c.id==client).values(error='Provider disablement pending; local API access is denied'))
                raise
            with self.engine.begin() as db:
                db.execute(update(registry).where(registry.c.id==client).values(status='disabled',error=None));self.log(db,actor['id'],'disable',client,'provider_revoked')
            return {'disabled':True,'localAccessDenied':True,'providerRegistrationRevoked':True,'relyingPartySessions':'revalidation required within 60 seconds online'}
        @app.post('/admin/identity/applications/{client}/rotate-secret')
        def rotate_secret(client:str,request:Request):
            actor=self.admin(request,True);self.require_enabled()
            op=str(uuid4())
            with self.engine.begin() as db:
                reg,p=self.policy(db,client)
                if p['type']!='server':raise HTTPException(422,'Public clients do not have secrets')
                changed=db.execute(update(registry).where(registry.c.id==client,registry.c.status=='active',registry.c.revision==reg['revision']).values(enabled=False,status='updating',revision=reg['revision']+1,operation=op,error=None))
                if changed.rowcount!=1:raise HTTPException(409,'Another change is already in progress')
                self.log(db,actor['id'],'rotate_client_secret',client,'pending')
            secret=secrets.token_urlsafe(48)
            try:
                existing=self.gateway.call('get_o_auth2_client',id=client);existing['client_secret']=secret
                existing['metadata']={'farmerplus_operation':op,'environment':self.environment}
                result=self.gateway.call('set_o_auth2_client',id=client,o_auth2_client=hydra.OAuth2Client.from_dict(existing))
                if not self.provider_matches(result,p,op):raise HTTPException(503,'Provider registration differs after rotation')
            except HTTPException:
                with self.engine.begin() as db:db.execute(update(registry).where(registry.c.id==client,registry.c.operation==op).values(status='needs_review',error='Secret rotation result uncertain; reconcile then rotate again before use'))
                raise
            with self.engine.begin() as db:
                db.execute(update(registry).where(registry.c.id==client,registry.c.operation==op).values(enabled=True,status='active',error=None))
                if client==os.getenv('FARMER_WEB_CLIENT_ID'):
                    db.execute(delete(rp_credentials).where(rp_credentials.c.client==client))
                    db.execute(insert(rp_credentials).values(client=client,sealed=self.cipher.encrypt(secret.encode()).decode()))
                self.log(db,actor['id'],'rotate_client_secret',client,'provider_confirmed')
            return {'rotated':True,'clientSecret':secret,'warning':'Existing tokens remain valid; use Revoke access to invalidate grants.'}
        @app.post('/admin/identity/applications/{client}/reconcile')
        def reconcile(client:str,request:Request):
            actor=self.admin(request,True);self.require_enabled()
            with self.engine.connect() as db:row=db.execute(select(registry).where(registry.c.id==client)).mappings().first()
            if not row or row['status'] not in {'needs_review','creating','updating'}:raise HTTPException(409,'No uncertain registration to reconcile')
            p=json.loads(row['policy']);live=self.gateway.call('get_o_auth2_client',id=client)
            if not self.provider_matches(live,p,row['operation']):raise HTTPException(409,'Provider registration differs; review it before enabling')
            with self.engine.begin() as db:
                db.execute(update(registry).where(registry.c.id==client,registry.c.operation==row['operation']).values(enabled=True,status='active',error=None));self.log(db,actor['id'],'reconcile',client,'provider_confirmed')
            return {'reconciled':True,'secretRecovery':'Rotate a confidential secret if its creation response was lost.'}
        @app.get('/admin/identity/people')
        def people(request:Request):
            self.admin(request)
            with self.engine.begin() as db:
                result=[]
                for u in db.execute(select(self.users)).mappings():
                    state=self.state(db,u['id']);mapped=self.mapped(db,u['id'])
                    count=len(db.execute(select(self.sessions.c.hash).where(self.sessions.c.owner==u['id'],self.sessions.c.expires>int(time.time()))).all())
                    contact=db.execute(select(self.contacts).where(self.contacts.c.owner==u['id'])).mappings().first()
                    observed=[{k:r[k] for k in ['client','first_seen','last_seen','expires']} for r in db.execute(select(seen_sessions).where(seen_sessions.c.owner==u['id'],seen_sessions.c.expires>int(time.time()),seen_sessions.c.epoch==state['epoch'])).mappings()]
                    result.append({'id':u['id'],'username':u['username'],'farmerplusId':mapped['student_id'],'firstname':mapped['firstname'],'lastname':mapped['lastname'],'email':contact['email'] if contact else None,'emailVerified':bool(contact and contact['verified']),'role':self.app.state.operations.role(db,u),'suspended':state['suspended'],'centralSessions':count,'observedSessions':observed,'epoch':state['epoch']})
                pending=[]
                for row in db.execute(select(outbox)).mappings():
                    deliveries=db.execute(select(rp_delivery).where(rp_delivery.c.event==row['id'])).mappings().all()
                    pending.append({**dict(row),'rp_status':'No Learning browser delivery required' if not deliveries else 'Learning acknowledged' if all(d['acknowledged'] is not None for d in deliveries) else 'Learning delivery pending'})
                reviews=[dict(r) for r in db.execute(select(recovery_reviews).order_by(recovery_reviews.c.created.desc()).limit(100)).mappings()]
            return {'people':result,'revocations':pending,'recoveryReviews':reviews}
        @app.put('/admin/identity/people/{owner}')
        async def edit_person(owner:str,request:Request):
            actor=self.admin(request,True);body=await request.json()
            if set(body)!={'firstname','lastname','email','role'} or body['role'] not in {'farmer','admin','support'}:raise HTTPException(422,'Provide the supported profile fields and role')
            if any(not isinstance(body[k],str) or not 1<=len(body[k].strip())<=100 for k in ['firstname','lastname']):raise HTTPException(422,'Names must contain 1-100 characters')
            email=body['email'] or None
            if email is not None and (not isinstance(email,str) or len(email)>254 or not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+',email)):raise HTTPException(422,'Enter a valid optional email')
            with self.engine.begin() as db:
                self.state(db,owner,True)
                target=db.execute(select(self.users).where(self.users.c.id==owner)).mappings().first()
                if not target:raise HTTPException(404,'Account unavailable')
                changed=self.app.state.operations.role(db,target)!=body['role']
                if changed and owner==actor['id']:raise HTTPException(409,'Ask another administrator to change your own role')
                db.execute(update(self.students).where(self.students.c.owner==owner).values(firstname=body['firstname'].strip(),lastname=body['lastname'].strip()))
                previous=db.execute(select(self.contacts).where(self.contacts.c.owner==owner)).mappings().first()
                if not previous or previous['email']!=email:
                    db.execute(delete(self.contacts).where(self.contacts.c.owner==owner))
                    if email:db.execute(insert(self.contacts).values(owner=owner,email=email,verified=False))
                db.execute(update(self.users).where(self.users.c.id==owner).values(admin=body['role'] in {'admin','support'}))
                from operations import staff
                db.execute(delete(staff).where(staff.c.owner==owner))
                if body['role']=='support':db.execute(insert(staff).values(owner=owner,role='support'))
                if changed:self.queue_revoke(db,owner=owner)
                self.log(db,actor['id'],'profile_role_update',owner,'revocation_pending' if changed else 'saved')
            return {'saved':True,'roleChanged':changed}
        @app.post('/admin/identity/recovery-reviews')
        async def request_recovery_review(request:Request):
            actor=self.admin(request,True);body=await request.json()
            reference=body.get('evidenceReference','')
            if not isinstance(reference,str) or not 20<=len(reference.strip())<=500 or body.get('proofReviewed') is not True:raise HTTPException(422,'Record a protected case reference and confirm proof of control beyond a name or account ID')
            with self.engine.begin() as db:
                target=db.execute(select(self.users).where(self.users.c.id==body.get('owner'))).mappings().first()
                if not target or target['admin'] or target['id']==actor['id']:raise HTTPException(409,'This assisted process is for farmer accounts; administrator recovery needs the break-glass procedure')
                key=str(uuid4());db.execute(insert(recovery_reviews).values(id=key,owner=target['id'],requested_by=actor['id'],evidence_reference=reference.strip(),created=int(time.time()),status='pending'))
                self.log(db,actor['id'],'recovery_review_requested',key,'pending_second_reviewer')
            return {'reviewId':key,'status':'pending independent administrator review'}
        @app.post('/admin/identity/recovery-reviews/{review}/approve')
        async def approve_recovery_review(review:str,request:Request):
            actor=self.admin(request,True);body=await request.json()
            if body.get('proofReviewed') is not True:raise HTTPException(422,'Independently verify the case before approval')
            with self.engine.begin() as db:
                initial=db.execute(select(recovery_reviews).where(recovery_reviews.c.id==review)).mappings().first()
                if not initial:raise HTTPException(404,'Review unavailable')
                self.state(db,initial['owner'],True)
                row=db.execute(select(recovery_reviews).where(recovery_reviews.c.id==review)).mappings().one()
                target=db.execute(select(self.users).where(self.users.c.id==row['owner'])).mappings().one()
                if row['status']!='pending' or row['requested_by']==actor['id'] or target['admin'] or row['created']<int(time.time())-86400:raise HTTPException(409,'A different administrator must approve a current pending farmer review')
                claimed=db.execute(update(recovery_reviews).where(recovery_reviews.c.id==review,recovery_reviews.c.status=='pending').values(status='approved',reviewed_by=actor['id']))
                if claimed.rowcount!=1:raise HTTPException(409,'This review has already been processed')
                codes=self.issue_recovery(db,row['owner']);self.queue_revoke(db,owner=row['owner'])
                self.log(db,actor['id'],'assisted_recovery_approved',review,'codes_issued_revocation_pending')
            return {'recoveryCodes':codes,'delivery':'Show once; hand to the verified account holder through the reviewed private channel.','revocation':'pending relying-party acknowledgment'}
        @app.post('/admin/identity/people/{owner}/{action}')
        def person_action(owner:str,action:str,request:Request):
            actor=self.admin(request,True)
            if action not in {'suspend','restore','revoke'}:raise HTTPException(404,'Unknown action')
            if owner==actor['id'] and action=='suspend':raise HTTPException(409,'An administrator cannot suspend their own active account')
            with self.engine.begin() as db:
                target=db.execute(select(self.users.c.id).where(self.users.c.id==owner)).first()
                if not target:raise HTTPException(404,'Account unavailable')
                key=self.queue_revoke(db,owner=owner,suspend=True if action=='suspend' else False if action=='restore' else None)
                self.log(db,actor['id'],action,owner,'pending')
            self.drain()
            return {'localSessionsRevoked':True,'revocationId':key,'relyingPartySessions':'pending revalidation; see revocation status'}
        @app.get('/admin/identity/audit')
        def audit_rows(request:Request):
            self.admin(request)
            with self.engine.connect() as db:return {'events':[dict(r) for r in db.execute(select(audit).order_by(audit.c.at.desc()).limit(200)).mappings()]}

    @staticmethod
    def safe_client(value):
        if value is None:return None
        return {k:value.get(k) for k in ['client_id','client_name','grant_types','response_types','redirect_uris','post_logout_redirect_uris','token_endpoint_auth_method','scope','audience','subject_type','backchannel_logout_uri']}
    @staticmethod
    def provider_matches(live,p,op):
        expected={'client_id':p['id'],'client_name':p['name'],'owner':p['owner'],'token_endpoint_auth_method':'client_secret_basic' if p['type']=='server' else 'none','subject_type':'public','access_token_strategy':'opaque'}
        if any(live.get(k)!=v for k,v in expected.items()):return False
        arrays={'redirect_uris':p['callbacks'],'post_logout_redirect_uris':p['post_logout'],'audience':p['audiences'],'response_types':['code'],'grant_types':['authorization_code']+(['refresh_token'] if 'offline_access' in p['scopes'] else [])}
        if any(set(live.get(k) or [])!=set(v) for k,v in arrays.items()):return False
        if set((live.get('scope') or '').split())!=set(p['scopes']):return False
        if (live.get('backchannel_logout_uri') or None)!=p['backchannel_logout']:return False
        if live.get('skip_consent') or live.get('skip_logout_consent'):return False
        return (live.get('metadata') or {}).get('farmerplus_operation')==op and (live.get('metadata') or {}).get('environment')==p['environment']
    def register_client(self,body,actor,editing=False):
        self.require_enabled();p=body.model_dump()
        if p['environment']!=self.environment:raise HTTPException(422,'Registration belongs to a different environment')
        op=str(uuid4())
        with self.engine.begin() as db:
            row=db.execute(select(registry).where(registry.c.id==p['id'])).mappings().first()
            if editing and not row:raise HTTPException(404,'Application unavailable')
            if row and not editing:raise HTTPException(409,'Application ID already exists; edit or reconcile it')
            if row and row['status']!='active':raise HTTPException(409,'Reconcile the current operation before editing; disabled IDs cannot be reused')
            if row and json.loads(row['policy'])['type']!=p['type']:raise HTTPException(409,'Create a separate registration to change client type')
            values={'policy':compact(p),'enabled':False,'status':'updating' if editing else 'creating','revision':row['revision']+1 if row else 1,'operation':op,'error':None}
            if row:
                changed=db.execute(update(registry).where(registry.c.id==p['id'],registry.c.status=='active',registry.c.revision==row['revision']).values(**values))
                if changed.rowcount!=1:raise HTTPException(409,'Another registration change is in progress')
            else:db.execute(insert(registry).values(id=p['id'],**values))
            self.log(db,actor,'edit_client' if editing else 'create_client',p['id'],'pending')
        secret=secrets.token_urlsafe(48) if p['type']=='server' and not editing else None
        client=hydra.OAuth2Client(client_id=p['id'],client_name=p['name'],owner=p['owner'],redirect_uris=p['callbacks'],post_logout_redirect_uris=p['post_logout'],grant_types=['authorization_code']+(['refresh_token'] if 'offline_access' in p['scopes'] else []),response_types=['code'],token_endpoint_auth_method='client_secret_basic' if p['type']=='server' else 'none',client_secret=secret,scope=' '.join(p['scopes']),audience=p['audiences'],subject_type='public',access_token_strategy='opaque',skip_consent=False,skip_logout_consent=False,backchannel_logout_uri=p['backchannel_logout'],backchannel_logout_session_required=bool(p['backchannel_logout']),authorization_code_grant_access_token_lifespan='5m',authorization_code_grant_id_token_lifespan='5m',refresh_token_grant_access_token_lifespan='5m',metadata={'farmerplus_operation':op,'environment':self.environment})
        try:
            result=self.gateway.call('set_o_auth2_client',id=p['id'],o_auth2_client=client) if editing else self.gateway.call('create_o_auth2_client',o_auth2_client=client)
            if not self.provider_matches(result,p,op):raise HTTPException(503,'Provider returned an unexpected registration')
        except HTTPException:
            with self.engine.begin() as db:db.execute(update(registry).where(registry.c.id==p['id'],registry.c.operation==op).values(status='needs_review',error='Provider result is uncertain. Reconcile before enabling.'))
            raise
        with self.engine.begin() as db:
            changed=db.execute(update(registry).where(registry.c.id==p['id'],registry.c.operation==op).values(enabled=True,status='active',error=None))
            if changed.rowcount!=1:raise HTTPException(409,'A concurrent registration change needs reconciliation')
            self.log(db,actor,'registration',p['id'],'provider_confirmed')
            if secret and p['id']==os.getenv('FARMER_WEB_CLIENT_ID'):
                db.execute(delete(rp_credentials).where(rp_credentials.c.client==p['id']))
                db.execute(insert(rp_credentials).values(client=p['id'],sealed=self.cipher.encrypt(secret.encode()).decode()))
        return {'application':p,'registered':True,**({'clientSecret':secret} if secret else {})}
