"""Farmer App local/self-hostable API. The existing learning service owns official results."""
from __future__ import annotations
import base64
import hashlib
import hmac
import json
import math
import os
import re
import secrets
import time
from pathlib import Path
from typing import Literal
from uuid import UUID, uuid4, uuid5, NAMESPACE_URL
import urllib.request
import urllib.parse
from urllib.parse import urlparse
from datetime import datetime, timezone
from geometry import validate as validate_polygon, contains as contains_polygon, measures
from business import validate as validate_business
from oidc import IdentityService, session_auth
from fastapi import FastAPI, HTTPException, Request, Response, Depends
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from fastapi.exceptions import RequestValidationError
from pydantic import BaseModel, Field, ConfigDict
from sqlalchemy import (create_engine, MetaData, Table, Column, String, Integer, Boolean, Text, LargeBinary, ForeignKey, select, insert, update, delete, func, event)
from sqlalchemy.exc import IntegrityError

ROOT=Path(__file__).resolve().parent
KINDS={'profile','farm','field','diary','task','progress','inbox','season','stock','stockmove','harvest','sale','guideprogress','pin','calculation'}
MAX_MEDIA=25*1024*1024
CHUNK=128*1024
HASH=re.compile(r'^[a-f0-9]{64}$')
meta=MetaData()
users=Table('users',meta,Column('id',String(36),primary_key=True),Column('username',String(64),unique=True,nullable=False),Column('password',Text,nullable=False),Column('admin',Boolean,nullable=False,default=False),Column('serial',Integer,nullable=False,default=0))
sessions=Table('sessions',meta,Column('hash',String(64),primary_key=True),Column('owner',String(36),ForeignKey('users.id'),nullable=False),Column('expires',Integer,nullable=False))
records=Table('records',meta,Column('owner',String(36),ForeignKey('users.id'),primary_key=True),Column('id',String(36),primary_key=True),Column('kind',String(20),nullable=False),Column('data',Text,nullable=False),Column('version',Integer,nullable=False),Column('deleted',Boolean,nullable=False),Column('updated',String(40),nullable=False))
receipts=Table('receipts',meta,Column('owner',String(36),ForeignKey('users.id'),primary_key=True),Column('op_id',String(36),primary_key=True),Column('digest',String(64),nullable=False),Column('response',Text,nullable=False))
media=Table('media',meta,Column('owner',String(36),ForeignKey('users.id'),primary_key=True),Column('hash',String(64),primary_key=True),Column('total',Integer,nullable=False),Column('body',LargeBinary,nullable=False),Column('complete',Boolean,nullable=False))
packages=Table('packages',meta,Column('id',String(64),primary_key=True),Column('version',Integer,primary_key=True),Column('manifest',Text,nullable=False),Column('body',LargeBinary,nullable=False),Column('sha',String(64),nullable=False),Column('active',Boolean,nullable=False))
attempts=Table('auth_attempts',meta,Column('key',String(64),primary_key=True),Column('window',Integer,nullable=False),Column('count',Integer,nullable=False))
recovery=Table('recovery_codes',meta,Column('owner',String(36),ForeignKey('users.id'),primary_key=True),Column('hash',String(64),primary_key=True),Column('created',Integer,nullable=False))
contacts=Table('account_contacts',meta,Column('owner',String(36),ForeignKey('users.id'),primary_key=True),Column('email',String(254),nullable=False),Column('verified',Boolean,nullable=False,default=False))
students=Table('student_identities',meta,Column('owner',String(36),ForeignKey('users.id'),primary_key=True),Column('student_id',String(32),unique=True,nullable=False),Column('moodle_id',Integer,unique=True),Column('login_alias',String(64),unique=True),Column('provider',String(12),nullable=False,default='local'),Column('firstname',String(100),nullable=False,default=''),Column('lastname',String(100),nullable=False,default=''))
revocations=Table('learning_revocations',meta,Column('owner',String(36),ForeignKey('users.id'),primary_key=True),Column('created',Integer,nullable=False))

class Credentials(BaseModel):
    username:str=Field(min_length=3,max_length=64,pattern=r'^[A-Za-z0-9_@.+-]+$')
    password:str=Field(min_length=1,max_length=256)
class Registration(Credentials):
    email:str|None=Field(default=None,max_length=254)
    firstname:str=Field(default='',max_length=100)
    lastname:str=Field(default='',max_length=100)
class LearningProfile(BaseModel):
    firstname:str=Field(min_length=1,max_length=100)
    lastname:str=Field(min_length=1,max_length=100)
class LearningRead(BaseModel):
    function:Literal['core_webservice_get_site_info','core_enrol_get_users_courses','core_course_get_contents']
    courseid:int|None=Field(default=None,gt=0)
class LearningLaunch(BaseModel):
    target:str=Field(default='/my/',max_length=300)
class AccountChange(BaseModel):
    current_password:str=Field(min_length=1,max_length=256)
    username:str|None=Field(default=None,min_length=3,max_length=64,pattern=r'^[A-Za-z0-9_@.+-]+$')
    password:str|None=Field(default=None,max_length=256)
class LearningExchange(BaseModel):
    token:str=Field(min_length=16,max_length=256,pattern=r'^[A-Za-z0-9]+$')
class RecoveryRequest(BaseModel):
    username:str=Field(min_length=3,max_length=64)
    code:str=Field(min_length=1,max_length=80)
    password:str=Field(min_length=1,max_length=256)
class ReissueRequest(BaseModel):
    current_password:str=Field(min_length=1,max_length=256)

def recovery_hash(code):
    return hashlib.sha256(('farmerplus-recovery-v1:'+re.sub(r'[-\s]','',code).upper()).encode()).hexdigest()

def issue_recovery(db,owner):
    db.execute(delete(recovery).where(recovery.c.owner==owner))
    codes=[]
    for _ in range(8):
        raw=base64.b32encode(secrets.token_bytes(16)).decode().rstrip('=')
        code='-'.join(raw[i:i+4] for i in range(0,len(raw),4))
        db.execute(insert(recovery).values(owner=owner,hash=recovery_hash(code),created=int(time.time())))
        codes.append(code)
    return codes

def validate_password(value):
    if len(value)<8 or not re.search('[A-Z]',value) or not re.search('[a-z]',value):
        raise HTTPException(422,'Use at least 8 characters with uppercase and lowercase letters')

class Operation(BaseModel):
    model_config=ConfigDict(extra='forbid')
    id:UUID
    op_id:UUID
    kind:Literal['preference','profile','farm','field','diary','task','progress','inbox','season','stock','stockmove','harvest','sale','guideprogress','pin','calculation']
    base_version:int=Field(ge=0,strict=True)
    data:dict
    deleted:bool=False
    sourceAppId:str|None=Field(default=None,max_length=32)
    deviceId:UUID|None=None
class MediaChunk(BaseModel):
    offset:int=Field(ge=0,le=MAX_MEDIA,strict=True)
    total:int=Field(ge=1,le=MAX_MEDIA,strict=True)
    chunk:str=Field(max_length=180000)
class ProviderMessage(BaseModel):
    owner:UUID
    event_id:UUID
    source:str=Field(min_length=1,max_length=80)
    title:str=Field(min_length=1,max_length=160)
    action:str=Field(min_length=1,max_length=80)
    route:str=Field(min_length=1,max_length=200)
    priority:Literal['normal','high']='normal'


def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False,allow_nan=False)
def now():return datetime.now(timezone.utc).isoformat()
def digest(value:bytes):return hashlib.sha256(value).hexdigest()
def password_hash(password:str,salt:bytes|None=None):
    salt=salt or secrets.token_bytes(16)
    result=hashlib.scrypt(password.encode(),salt=salt,n=16384,r=8,p=1,dklen=32)
    return salt.hex()+':'+result.hex()
def password_matches(password,encoded):
    if encoded.startswith('!'):return False
    salt,_=encoded.split(':')
    return hmac.compare_digest(password_hash(password,bytes.fromhex(salt)),encoded)
def record_json(row):return {'id':row['id'],'kind':row['kind'],'data':json.loads(row['data']),'version':row['version'],'deleted':row['deleted'],'updated':row['updated']}
def owned(table,owner,**keys):
    clause=table.c.owner==owner
    for key,value in keys.items():clause=clause & (table.c[key]==value)
    return clause

def validate_data(kind,data,deleted):
    try:encoded=canonical(data)
    except (ValueError,TypeError):raise HTTPException(422,'Record contains invalid numbers or values')
    if len(encoded.encode())>65536:raise HTTPException(413,'Record exceeds 64 KB')
    for key,limit in [('name',160),('title',160),('notes',16000),('country',100)]:
        if key in data and (not isinstance(data[key],str) or len(data[key])>limit):raise HTTPException(422,f'Invalid {key}')
    if kind in {'farm','field'} and data.get('points'):
        points=data['points']
        if not isinstance(points,list) or not 3<=len(points)<=1000:raise HTTPException(422,'A boundary needs 3 to 1000 points')
        for point in points:
            if not isinstance(point,dict) or any(isinstance(point.get(k),bool) or not isinstance(point.get(k),(int,float)) or not math.isfinite(point[k]) for k in ['lat','lon']):raise HTTPException(422,'Invalid coordinate')
            if abs(point['lat'])>85 or abs(point['lon'])>180:raise HTTPException(422,'Coordinate out of range')
    attachments=data.get('media',[])
    if not isinstance(attachments,list) or len(attachments)>20:raise HTTPException(422,'At most 20 attachments per record')
    for m in attachments:
        if not isinstance(m,dict) or not HASH.fullmatch(str(m.get('hash',''))) or m.get('type') not in {'image/jpeg','image/png','audio/mp4','audio/aac','audio/wav'}:raise HTTPException(422,'Unsupported attachment')
    if kind=='progress':
        forbidden={'officialGrade','officialCompletion','credential','entitlement'} & data.keys()
        if forbidden:raise HTTPException(422,'Official learning results may only come from the configured learning service')
        data={**data,'authority':'local-practice' if data.get('sample') is True else 'local-evidence'}
    if kind=='preference':
        from preferences import validate_preference
        validate_preference(data)
    if kind=='profile':data={**data,'verified':False,'emailVerified':False}
    return data


def create_app(database_url:str|None=None,data_dir:Path|None=None,testing:bool=False,session_cookie:str='farmer_session',email_sender=None,social_gateway=None):
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]{0,63}',session_cookie):raise ValueError('Invalid session cookie name')
    data_dir=data_dir or Path(os.getenv('FARMER_DATA_DIR',str(ROOT/'data')))
    data_dir.mkdir(parents=True,exist_ok=True)
    local_url=f'sqlite:///{(data_dir/"farmer.sqlite").as_posix()}'
    url=database_url or (local_url if testing else os.getenv('DATABASE_URL',local_url))
    engine=create_engine(url,connect_args={'check_same_thread':False,'timeout':30} if url.startswith('sqlite') else {},pool_pre_ping=True)
    if url.startswith('sqlite'):
        @event.listens_for(engine,'connect')
        def configure_sqlite(connection,_):
            connection.execute('PRAGMA foreign_keys=ON')
            connection.execute('PRAGMA journal_mode=WAL')
    meta.create_all(engine)
    app=FastAPI(title='Farmer App Sync',version='0.1.0',docs_url=None,redoc_url=None)
    preview_origins={'http://127.0.0.1:8091','http://localhost:8091','http://127.0.0.1:5173','http://localhost:5173'}
    preview_origins.update(value.strip().rstrip('/') for value in os.getenv('FARMER_PWA_DEV_ORIGINS','').split(',') if value.strip())
    app.add_middleware(CORSMiddleware,allow_origins=sorted(preview_origins),allow_credentials=True,allow_methods=['GET','POST','PUT','PATCH','DELETE'],allow_headers=['Authorization','Content-Type','X-CSRF-Token','X-Reauthentication','X-Change-Reason'])
    app.state.engine=engine
    app.state.session_cookie=session_cookie
    @app.exception_handler(RequestValidationError)
    async def validation_error(request,exc):
        # Pydantic errors normally include raw input values, including secrets.
        return JSONResponse({'detail':'Invalid request fields. Check the required format and length.'},422)
    secure_cookie=os.getenv('FARMER_SECURE_COOKIES','0')=='1'
    packaged=ROOT/'resources'/'packs'
    pack_dir=Path(os.getenv('FARMER_PACK_DIR',str(packaged)))
    with engine.begin() as db:
        for file in pack_dir.glob('*.json'):
            body=file.read_bytes();content=json.loads(body)
            if db.execute(select(packages.c.id).where(packages.c.id==content['id'],packages.c.version==content['version'])).first():continue
            manifest={'id':content['id'],'version':content['version'],'title':content['title'],'description':content.get('description',''),'provider':'FarmerPlus','price':'free','offline':True,'license':content.get('license',content.get('licence')),'bytes':len(body),'sha256':digest(body),'sample':content.get('sample',True),'executable':False}
            db.execute(insert(packages).values(id=manifest['id'],version=manifest['version'],manifest=canonical(manifest),body=body,sha=manifest['sha256'],active=True))

    @app.middleware('http')
    async def boundaries(request:Request,call_next):
        length=request.headers.get('content-length','0')
        limit = 6500000 if re.fullmatch(r'/admin/api/v2/apps/[a-z0-9-]+/releases', request.url.path) else 210000
        if length.isdigit() and int(length)>limit:return JSONResponse({'detail':'Request too large'},413)
        if request.method in {'POST','PUT','PATCH'}:
            # Bound streamed requests too, including callers without Content-Length.
            body=bytearray()
            async for chunk in request.stream():
                body.extend(chunk)
                if len(body)>limit:return JSONResponse({'detail':'Request too large'},413)
            request._body=bytes(body)
        if request.method in {'POST','PUT','DELETE','PATCH'}:
            origin=request.headers.get('origin')
            # Browsers may serialize Origin as null on a form navigation under
            # Referrer-Policy:no-referrer. Only our one-use OIDC forms can pass
            # this case; consume_flow still verifies the secret CSRF value and
            # HttpOnly browser-cookie binding before any login/consent action.
            bound_oidc_form=origin=='null' and request.url.path in {'/oidc/login','/oidc/consent','/oidc/logout'} and bool(request.cookies.get('fp_oidc_browser')) and request.headers.get('sec-fetch-site')=='same-origin'
            # Apple returns the authorization response as a cross-site form POST.
            # Authlib validates its signed session cookie and one-use OIDC state.
            bound_apple_callback=request.method=='POST' and request.url.path=='/auth/social/apple/callback'
            if origin and not bound_oidc_form and not bound_apple_callback and urlparse(origin).netloc!=request.headers.get('host') and origin not in preview_origins:
                return JSONResponse({'detail':'Cross-origin writes are not allowed'},403)
            if request.headers.get('sec-fetch-site')=='cross-site' and not bound_apple_callback:return JSONResponse({'detail':'Cross-site writes are not allowed'},403)
        response=await call_next(request)
        response.headers['X-Content-Type-Options']='nosniff'
        response.headers['Referrer-Policy']='no-referrer'
        response.headers['Content-Security-Policy']="default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob:; media-src 'self' blob:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
        if request.url.path in {'/','/farmer','/app.html','/sqflite_sw.js','/map','/admin','/admin/tenants','/admin/identity'}:
            response.headers['Content-Security-Policy']="default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: https://tiles.openfreemap.org https://tiles.maps.eox.at; media-src 'self' blob:; font-src 'self' data:; worker-src 'self' blob:; connect-src 'self' blob: https://tiles.openfreemap.org https://tiles.maps.eox.at https://api.open-meteo.com https://geocoding-api.open-meteo.com; object-src 'none'; base-uri 'self'; frame-ancestors 'none'"
        if request.url.path in {'/', '/farmer', '/app.html'}:
            from miniapp_api import allow_verified_frame_scripts
            response = await allow_verified_frame_scripts(response)
        if request.url.path.startswith('/static/'):
            # Local administration assets change frequently while the workspace
            # is running. Revalidate them so a normal reload sees current code.
            if os.getenv('FARMER_ENVIRONMENT','development')!='production':
                response.headers['Cache-Control']='no-cache'
        else:
            response.headers['Cache-Control']='no-store'
        return response

    def identity(request:Request):
        local_admin=getattr(app.state,'admin_auth',None)
        if local_admin and local_admin.enabled and (request.url.path.startswith('/admin') or (request.cookies.get('fp_admin_session') and request.url.path.startswith(('/tenants', '/wallets')))):
            return local_admin.require(request)
        oidc=getattr(app.state,'oidc',None)
        if oidc and oidc.enabled:
            if getattr(oidc,'provider',None)=='keycloak':return oidc.resource_identity(request)
            if request.headers.get('authorization','').startswith('Bearer ') or request.url.path.startswith(('/sync/','/media/','/packages/')) or request.url.path in {'/catalogue','/auth/me'}:return oidc.resource_identity(request)
            user=oidc.central(request)
            if not user:raise HTTPException(401,'Sign in to FarmerPlus')
            return user
        auth=request.headers.get('authorization','')
        token=auth[7:] if auth.startswith('Bearer ') else request.cookies.get(session_cookie,'')
        if not token:raise HTTPException(401,'Sign in to synchronise')
        with engine.connect() as db:
            user=db.execute(select(users).join(sessions,users.c.id==sessions.c.owner).where(sessions.c.hash==digest(token.encode()),sessions.c.expires>int(time.time()))).mappings().first()
        if not user:raise HTTPException(401,'Session expired or invalid. Sign in again.')
        return dict(user)
    def admin(request:Request,user=Depends(identity)):
        if not user['admin']:raise HTTPException(403,'Administrator access required')
        tenancy=getattr(app.state,'tenancy',None)
        if tenancy:
            from tenancy import control as tenant_control
            with engine.connect() as db:
                platform_owner=db.scalar(select(tenant_control.c.superadmin).where(tenant_control.c.id==1))
            if platform_owner and platform_owner!=user['id']:
                raise HTTPException(403,'Use your tenant administration; platform access is restricted')
        app.state.operations.authorize(request,user,request.method not in {'GET','HEAD','OPTIONS'})
        return user
    def throttle(request,username,force=False,limit=12):
        if testing and not force:return
        key=digest(f'{request.client.host if request.client else "unknown"}:{username.lower()}'.encode());current=int(time.time())
        with engine.begin() as db:
            row=db.execute(select(attempts).where(attempts.c.key==key)).mappings().first()
            if row and current-row['window']<300:
                if row['count']>=limit:raise HTTPException(429,'Too many sign-in attempts. Try again in five minutes.')
                db.execute(update(attempts).where(attempts.c.key==key).values(count=attempts.c.count+1))
            else:
                db.execute(delete(attempts).where(attempts.c.key==key))
                db.execute(insert(attempts).values(key=key,window=current,count=1))

    def student(db, owner, **values):
        # A stable public mapping key, never an authentication credential.
        row=db.execute(select(students).where(students.c.owner==owner)).mappings().first()
        if not row:
            db.execute(insert(students).values(owner=owner,student_id=secrets.token_hex(16),provider='local',firstname='',lastname='',**values))
            tenancy=getattr(app.state,'tenancy',None)
            if tenancy:tenancy.register_farmerplus(db,owner)
        elif values:
            db.execute(update(students).where(students.c.owner==owner).values(**values))
        return dict(db.execute(select(students).where(students.c.owner==owner)).mappings().one())

    def queue_revoke(db,owner):
        app.state.oidc.queue_revoke(db,owner=owner)
    def revoke_learning(owner):
        app.state.oidc.drain()
        return False  # RP delivery/revalidation has its own evidence; never claim global success.

    def issue_session(db,user,response):
        token=secrets.token_urlsafe(32);expires=int(time.time())+12*3600
        db.execute(delete(sessions).where(sessions.c.expires<int(time.time())))
        db.execute(insert(sessions).values(hash=digest(token.encode()),owner=user['id'],expires=expires))
        security=app.state.oidc.state(db,user['id'],True)
        db.execute(insert(session_auth).values(hash=digest(token.encode()),authenticated_at=int(time.time()),epoch=security['epoch']))
        mapped=student(db,user['id'])
        response.set_cookie(session_cookie,token,httponly=True,secure=secure_cookie,samesite='lax',max_age=12*3600)
        return {**({'token':token} if not app.state.oidc.enabled else {}),'owner':user['id'],'expires':expires,'verified':False,'studentId':mapped['student_id'],
                'accessOwner':f'moodle:{mapped["moodle_id"]}' if mapped['provider']=='moodle' else f'local:{user["id"]}',
                'accountKind':mapped['provider']}

    @app.get('/health')
    def health():
        with engine.connect() as db:db.execute(select(1))
        return {'status':'ok','database':'postgresql' if url.startswith('postgresql') else 'sqlite','learning':'oidc' if app.state.oidc.enabled else 'awaiting_oidc_configuration','wallet':'not_configured',**({'identity':'keycloak','identityReconciliation':getattr(app.state.oidc,'last_reconcile_error',None) or 'running'} if getattr(app.state.oidc,'provider',None)=='keycloak' else {})}
    @app.post('/auth/register',status_code=201)
    def register(body:Registration,request:Request):
        throttle(request,body.username)
        if app.state.oidc.central(request):raise HTTPException(409,'Sign out before creating an account for another person')
        if body.email is not None:
            if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+',body.email):raise HTTPException(422,'Enter a valid optional email address')
            validate_password(body.password)
        else:validate_password(body.password)
        try:
            with engine.begin() as db:
                owner=str(uuid4())
                db.execute(insert(users).values(id=owner,username=body.username.lower(),password=password_hash(body.password),admin=False,serial=0))
                if body.email:db.execute(insert(contacts).values(owner=owner,email=body.email.lower(),verified=False))
                mapped=student(db,owner)
                db.execute(update(students).where(students.c.owner==owner).values(firstname=body.firstname.strip(),lastname=body.lastname.strip()))
                codes=issue_recovery(db,owner)
        except IntegrityError:raise HTTPException(409,'Username is unavailable')
        return {'created':True,'owner':owner,'studentId':mapped['student_id'],'verified':False,'recoveryCodes':codes}
    @app.post('/auth/login')
    def login(body:Credentials,request:Request,response:Response):
        throttle(request,body.username)
        throttle(request,'login-all',limit=120)
        with engine.begin() as db:
            user=db.execute(select(users).where(users.c.username==body.username.lower())).mappings().first()
            if not user:
                password_hash(body.password,b'0000000000000000')
                raise HTTPException(401,'Invalid username or password')
            state=app.state.oidc.state(db,user['id'],True)
            current=db.execute(select(users).where(users.c.id==user['id'])).mappings().one()
            if state['suspended'] or not password_matches(body.password,current['password']):raise HTTPException(401,'Invalid username or password')
            existing=app.state.oidc.central(request,db)
            if existing and existing['id']!=user['id']:raise HTTPException(409,'Sign out of the current browser account before changing people')
            result=issue_session(db,user,response)
        return result
    @app.get('/auth/me')
    def me(user=Depends(identity)):
        with engine.begin() as db:
            mapped=student(db,user['id']);state=app.state.oidc.state(db,user['id'])
        pwa_identity=getattr(app.state,'email_auth',None)
        pwa_profile=pwa_identity.profile(user['id']) if pwa_identity else None
        if getattr(app.state.oidc,'provider',None)=='keycloak':
            with engine.connect() as db: contact=db.execute(select(contacts).where(contacts.c.owner==user['id'])).mappings().first()
            pwa_profile={'verified':bool(contact and contact['verified']),'email':contact['email'] if contact else None,'accountKind':'keycloak'}
        return {'owner':user['id'],'username':user['username'],'admin':user['admin'],'verified':pwa_profile['verified'] if pwa_profile else False,'email':pwa_profile['email'] if pwa_profile else None,'studentId':mapped['student_id'],'firstname':mapped['firstname'],'lastname':mapped['lastname'],'accessOwner':'farmerplus:'+mapped['student_id'],'accountKind':pwa_profile['accountKind'] if pwa_profile else 'oidc' if app.state.oidc.enabled else mapped['provider'],'credentialEpoch':state['epoch']}

    @app.post('/auth/offline/verify')
    def verify_offline_password(body:ReissueRequest,request:Request,user=Depends(identity)):
        if not app.state.oidc.enabled or not request.headers.get('authorization','').startswith('Bearer '):
            raise HTTPException(403,'A verified native FarmerPlus session is required')
        throttle(request,'offline-password:'+user['id'],force=True)
        with engine.begin() as db:
            state=app.state.oidc.state(db,user['id'],True)
            if state['suspended'] or state['epoch']!=getattr(request.state,'credential_epoch',None):
                raise HTTPException(401,'Account access changed. Sign in again.')
            current=db.execute(select(users).where(users.c.id==user['id'])).mappings().one()
            if not password_matches(body.current_password,current['password']):raise HTTPException(401,'Password was not accepted')
            mapped=student(db,user['id'])
            app.state.oidc.log(db,user['id'],'offline_password_verified',user['id'],'verified')
        return {'verified':True,'owner':user['id'],'studentId':mapped['student_id'],'username':current['username'],'credentialEpoch':state['epoch']}
    @app.post('/auth/moodle')
    def exchange():
        raise HTTPException(410,'The password/token bridge is retired. Use FarmerPlus OpenID Connect; existing learner mappings are preserved.')
    @app.post('/auth/change')
    def change(body:AccountChange,request:Request,user=Depends(identity)):
        throttle(request,user['username'])
        if user['username'].startswith('moodle:'):raise HTTPException(409,'Change your Learning credentials on the authoritative website')
        if body.password is not None:validate_password(body.password)
        with engine.begin() as db:
            state=app.state.oidc.state(db,user['id'],True)
            if state['suspended'] or (hasattr(request.state,'credential_epoch') and state['epoch']!=request.state.credential_epoch):
                raise HTTPException(401,'Account access changed. Sign in again.')
            current=db.execute(select(users).where(users.c.id==user['id'])).mappings().one()
            if not password_matches(body.current_password,current['password']):raise HTTPException(401,'Re-authentication failed')
            values={}
            if body.username is not None:values['username']=body.username.lower()
            if body.password is not None:values['password']=password_hash(body.password)
            try:
                if values:db.execute(update(users).where(users.c.id==user['id']).values(**values))
            except IntegrityError:raise HTTPException(409,'Username is unavailable') from None
            if body.password is not None:queue_revoke(db,user['id'])
            mapped=student(db,user['id']);state=app.state.oidc.state(db,user['id'])
        if body.password is not None:revoke_learning(user['id'])
        return {'updated':True,'owner':user['id'],'username':values.get('username',user['username']),'signInRequired':body.password is not None,'verified':body.password is not None,'studentId':mapped['student_id'],'credentialEpoch':state['epoch']}
    @app.post('/auth/recover')
    def recover(body:RecoveryRequest,request:Request):
        throttle(request,'recover:'+body.username,force=True)
        throttle(request,'recover-all',force=True)
        validate_password(body.password)
        verifier=recovery_hash(body.code)
        with engine.connect() as db:
            user=db.execute(select(users).where(users.c.username==body.username.lower())).mappings().first()
        if not user or user['username'].startswith('moodle:'):
            raise HTTPException(401,'Recovery could not verify these details. Check your username and an unused recovery code.')
        with engine.begin() as db:
            # One security-row lock orders login, recovery and revocation.
            app.state.oidc.state(db,user['id'],True)
            consumed=db.execute(delete(recovery).where(recovery.c.owner==user['id'],recovery.c.hash==verifier))
            if consumed.rowcount!=1:raise HTTPException(401,'Recovery could not verify these details. Check your username and an unused recovery code.')
            db.execute(update(users).where(users.c.id==user['id']).values(password=password_hash(body.password)))
            db.execute(delete(sessions).where(sessions.c.owner==user['id']))
            queue_revoke(db,user['id'])
            codes=issue_recovery(db,user['id'])
        return {'reset':True,'recoveryCodes':codes,'sessionsRevoked':True,'learningSessionsRevoked':revoke_learning(user['id'])}
    @app.post('/auth/recovery/reissue')
    def reissue(body:ReissueRequest,request:Request,user=Depends(identity)):
        throttle(request,'reissue:'+user['username'],force=True)
        with engine.begin() as db:
            app.state.oidc.state(db,user['id'],True)
            current=db.execute(select(users).where(users.c.id==user['id'])).mappings().one()
            if current['username'].startswith('moodle:') or not password_matches(body.current_password,current['password']):raise HTTPException(401,'Re-authentication failed')
            codes=issue_recovery(db,user['id'])
        return {'recoveryCodes':codes,'replaced':True}
    @app.post('/auth/logout')
    def logout(request:Request,response:Response,user=Depends(identity)):
        auth=request.headers.get('authorization','');token=auth[7:] if auth.startswith('Bearer ') else request.cookies.get(session_cookie,'')
        with engine.begin() as db:
            db.execute(delete(sessions).where(sessions.c.hash==digest(token.encode()),sessions.c.owner==user['id']))
            queue_revoke(db,user['id'])
        response.delete_cookie(session_cookie);response.delete_cookie('fp_app');return {'signedOut':True,'learningSessionsRevoked':revoke_learning(user['id']),'remoteStatus':'pending online revalidation',**({'endSessionUrl':'/oidc/logout'} if getattr(app.state.oidc,'provider',None)=='keycloak' else {})}

    @app.post('/learning/session')
    @app.post('/learning/read')
    @app.post('/learning/launch')
    def retired_learning_bridge():
        raise HTTPException(410,'Open Learning through its OpenID Connect entry point. The interim bridge is retired.')

    @app.post('/sync/push')
    def push(op:Operation,user=Depends(identity)):
        owner=user['id'];key=str(op.id);opid=str(op.op_id)
        payload=op.model_dump(mode='json',exclude={'sourceAppId','deviceId'});sha=digest(canonical(payload).encode())
        data=validate_data(op.kind,op.data,op.deleted)
        if op.kind == 'preference':
            from uuid import uuid5, NAMESPACE_URL
            expected = str(uuid5(NAMESPACE_URL, 'https://farmerplus.earth/preferences/' + data['key']))
            if key != expected or op.deleted:
                raise HTTPException(422, 'Preferences require their stable key ID; reset using a valid value')
        with engine.begin() as db:
            # This row update serialises competing writes by one owner in both SQLite and PostgreSQL.
            db.execute(update(users).where(users.c.id==owner).values(serial=users.c.serial+1))
            receipt=db.execute(select(receipts).where(owned(receipts,owner,op_id=opid))).mappings().first()
            if receipt:
                if receipt['digest']!=sha:raise HTTPException(409,'Operation ID was already used with different content')
                return json.loads(receipt['response'])
            old=db.execute(select(records).where(owned(records,owner,id=key))).mappings().first()
            if old and old['kind']!=op.kind:raise HTTPException(409,'Record type cannot change')
            version=old['version'] if old else 0
            if version!=op.base_version:
                if old:return {'conflict':True,'record':record_json(old)}
                raise HTTPException(409,'Record does not exist at the requested base version')
            try:validate_business(db,records,owner,key,op.kind,data,op.deleted)
            except (ValueError,TypeError,KeyError):raise HTTPException(422,'Record conflicts with its farm, stock balance or harvest quantity') from None
            if op.kind in {'farm','field'}:
                try:
                    app.state.miniapps.protect_location(db,owner,key,op.kind,data,op.deleted)
                    points=data.get('points',[])
                    if not op.deleted and points:
                        validate_polygon(points)
                        data={**data,'areaM2':measures(points)[0],'perimeterM':measures(points)[1]}
                    if not op.deleted and not points:data={**data,'areaM2':0,'perimeterM':0}
                    if op.kind=='field' and not op.deleted:
                        parent=db.execute(select(records).where(owned(records,owner,id=str(data.get('farmId',''))),records.c.kind=='farm',records.c.deleted==False)).mappings().first()
                        if not parent:raise ValueError('Choose and map the parent farm first')
                        if points:contains_polygon(json.loads(parent['data']).get('points',[]),points)
                    if op.kind=='farm':
                        children=db.execute(select(records).where(records.c.owner==owner,records.c.kind=='field',records.c.deleted==False)).mappings().all()
                        for child in children:
                            child_data=json.loads(child['data'])
                            if child_data.get('farmId')!=key:continue
                            if op.deleted:raise ValueError('Farm still has fields; move or delete them explicitly first')
                            try:
                                if child_data.get('points'):contains_polygon(points,child_data['points'])
                            except ValueError as exc:raise ValueError('Farm change would exclude field '+child_data.get('name',child['id'])+': '+str(exc)) from exc
                except (ValueError,TypeError,KeyError) as exc:raise HTTPException(422,str(exc)) from exc
            for item in data.get('media',[]):
                if not db.execute(select(media.c.hash).where(owned(media,owner,hash=item['hash']),media.c.complete==True)).first():raise HTTPException(422,'Attachment must be uploaded and verified for this account first')
            if not old:
                if db.execute(select(func.count()).select_from(records).where(records.c.owner==owner)).scalar_one()>=10000:raise HTTPException(413,'This account has reached the 10,000 record limit')
            values={'kind':op.kind,'data':canonical(data),'version':version+1,'deleted':op.deleted,'updated':now()}
            if old:db.execute(update(records).where(owned(records,owner,id=key)).values(**values))
            else:db.execute(insert(records).values(owner=owner,id=key,**values))
            if op.kind=='inbox' and data.get('read') is True and getattr(app.state,'workspace',None):
                app.state.workspace.record_delivery(db,owner,key,read=True)
            result={'conflict':False,'record':{'id':key,**values,'data':data}}
            from admin_farmer import record_provenance
            record_provenance(db,owner,op,version+1)
            db.execute(insert(receipts).values(owner=owner,op_id=opid,digest=sha,response=canonical(result)))
        return result
    def polygon_collection(owner=None):
        query=select(records).where(records.c.kind.in_(['farm','field','pin']),records.c.deleted==False)
        if owner is not None:query=query.where(records.c.owner==owner)
        with engine.connect() as db:rows=db.execute(query).mappings().all()
        features=[];unmapped=0;invalid=0
        for row in rows:
            data=json.loads(row['data'])
            props={'name':data.get('name','Unnamed area'),'kind':row['kind'],'farmId':data.get('farmId'),'areaType':data.get('areaType'),'version':row['version'],'updated':row['updated'],'areaM2':0}
            if owner is None:props['owner']=row['owner']
            if row['kind']=='pin':
                lat,lon=data.get('lat'),data.get('lon')
                if not all(isinstance(v,(int,float)) and math.isfinite(v) for v in [lat,lon]):invalid+=1;continue
                geometry={'type':'Point','coordinates':[lon,lat]}
                props['placeType']=data.get('type')
            else:
                points=data.get('points',[])
                if not points:unmapped+=1;continue
                try:validate_polygon(points)
                except (ValueError,TypeError,KeyError):invalid+=1;continue
                props['areaM2']=measures(points)[0]
                ring=[[p['lon'],p['lat']] for p in points];ring.append(ring[0])
                geometry={'type':'Polygon','coordinates':[ring]}
            features.append({'type':'Feature','id':row['id'],'geometry':geometry,'properties':props})
        return {'type':'FeatureCollection','features':features,'unmapped':unmapped,'invalid':invalid,'checkedAt':now()}

    @app.get('/map/geojson')
    def my_map(user=Depends(identity)):
        return polygon_collection(user['id'])

    @app.get('/admin/map/geojson')
    def world_map(user=Depends(admin)):
        return polygon_collection()

    @app.get('/map')
    def map_page():
        return FileResponse(ROOT/'static'/'world-map.html',media_type='text/html')

    @app.get('/sync/pull')
    def pull(user=Depends(identity)):
        with engine.connect() as db:rows=db.execute(select(records).where(records.c.owner==user['id']).order_by(records.c.updated,records.c.id)).mappings().all()
        return {'records':[record_json(r) for r in rows],'serverTime':now()}

    def valid_hash(hash):
        if not HASH.fullmatch(hash):raise HTTPException(422,'Invalid media identifier')
    @app.get('/media/{hash}/status')
    def media_status(hash:str,user=Depends(identity)):
        valid_hash(hash)
        with engine.connect() as db:row=db.execute(select(media).where(owned(media,user['id'],hash=hash))).mappings().first()
        return {'bytes':len(row['body']) if row else 0,'complete':row['complete'] if row else False}
    @app.put('/media/{hash}')
    def media_put(hash:str,part:MediaChunk,user=Depends(identity)):
        valid_hash(hash)
        try:chunk=base64.b64decode(part.chunk,validate=True)
        except ValueError:raise HTTPException(422,'Invalid base64 chunk')
        if not 0<len(chunk)<=CHUNK or part.offset+len(chunk)>part.total:raise HTTPException(422,'Invalid chunk size or range')
        owner=user['id']
        with engine.begin() as db:
            db.execute(update(users).where(users.c.id==owner).values(serial=users.c.serial+1))
            old=db.execute(select(media).where(owned(media,owner,hash=hash))).mappings().first()
            content=old['body'] if old else b''
            if old and old['total']!=part.total:raise HTTPException(409,'Attachment total cannot change')
            if not old:
                total=db.execute(select(func.coalesce(func.sum(media.c.total),0)).where(media.c.owner==owner)).scalar_one()
                if total+part.total>512*1024*1024:raise HTTPException(413,'Account attachment quota exceeded')
            if part.offset<len(content):
                if content[part.offset:part.offset+len(chunk)]!=chunk:raise HTTPException(409,'Retried chunk differs from accepted content')
                return {'bytes':len(content),'complete':old['complete']}
            if part.offset!=len(content):raise HTTPException(409,'Resume from the accepted byte offset')
            content+=chunk;complete=len(content)==part.total
            if complete and digest(content)!=hash:
                db.execute(delete(media).where(owned(media,owner,hash=hash)))
                return JSONResponse({'detail':'Attachment integrity failed; restart upload'},422)
            values={'body':content,'complete':complete,'total':part.total}
            if old:db.execute(update(media).where(owned(media,owner,hash=hash)).values(**values))
            else:db.execute(insert(media).values(owner=owner,hash=hash,**values))
        return {'bytes':len(content),'complete':complete}
    @app.get('/media/{hash}')
    def media_get(hash:str,offset:int=0,user=Depends(identity)):
        valid_hash(hash)
        with engine.connect() as db:row=db.execute(select(media).where(owned(media,user['id'],hash=hash),media.c.complete==True)).mappings().first()
        if not row:raise HTTPException(404,'Verified attachment not found for this account')
        if not 0<=offset<=row['total']:raise HTTPException(416,'Offset outside attachment')
        return {'chunk':base64.b64encode(row['body'][offset:offset+CHUNK]).decode(),'total':row['total']}

    @app.get('/catalogue')
    def catalogue(user=Depends(identity)):
        with engine.connect() as db:rows=db.execute(select(packages.c.manifest).where(packages.c.active==True)).all()
        return {'packages':[json.loads(r[0]) for r in rows],'learningConnected':False}
    @app.get('/packages/{id}/{version}')
    def package(id:str,version:int,offset:int=0,user=Depends(identity)):
        with engine.connect() as db:row=db.execute(select(packages).where(packages.c.id==id,packages.c.version==version,packages.c.active==True)).mappings().first()
        if not row:raise HTTPException(404,'Package not available')
        if not 0<=offset<=len(row['body']):raise HTTPException(416,'Invalid package offset')
        return {'chunk':base64.b64encode(row['body'][offset:offset+CHUNK]).decode(),'total':len(row['body']),'sha256':row['sha']}
    @app.post('/admin/messages')
    def message(body:ProviderMessage,user=Depends(admin)):
        if not re.fullmatch(r'(task:[a-f0-9-]{36}|learning:sample-records:[0-9]+)',body.route):raise HTTPException(422,'Unsupported deep link')
        owner=str(body.owner);key=str(body.event_id)
        data={'source':body.source,'title':body.title,'action':body.action,'route':body.route,'priority':body.priority,'read':False,'completed':False}
        with engine.begin() as db:
            target=db.execute(select(users.c.id).where(users.c.id==owner)).first()
            if not target:raise HTTPException(404,'Account not found')
            db.execute(update(users).where(users.c.id==owner).values(serial=users.c.serial+1))
            existing=db.execute(select(records).where(owned(records,owner,id=key))).mappings().first()
            if existing:
                prior=json.loads(existing['data'])
                if existing['kind']!='inbox' or any(prior.get(k)!=data[k] for k in ['source','title','action','route','priority']):raise HTTPException(409,'Message event ID already used')
                return {'record':record_json(existing),'deduplicated':True}
            row={'id':key,'kind':'inbox','data':canonical(data),'version':1,'deleted':False,'updated':now()}
            db.execute(insert(records).values(owner=owner,**row))
        return {'record':{**row,'data':data},'deduplicated':False}
    @app.patch('/admin/packages/{id}/{version}')
    def activate_package(id:str,version:int,active:bool,user=Depends(admin)):
        with engine.begin() as db:result=db.execute(update(packages).where(packages.c.id==id,packages.c.version==version).values(active=active))
        if not result.rowcount:raise HTTPException(404,'Package not found')
        return {'active':active}
    @app.get('/learning/status')
    def learning_status(user=Depends(identity)):
        with engine.begin() as db:mapped=student(db,user['id'])
        return {'connected':bool(mapped['moodle_id']),'browserSsoConfigured':app.state.oidc.enabled,'authority':'Moodle','localProgress':'evidence_only','officialResults':None}
    @app.get('/')
    def home():
        return RedirectResponse('/admin',303)
    @app.get('/favicon.ico',include_in_schema=False)
    def favicon():
        return FileResponse(ROOT/'static'/'favicon.svg',media_type='image/svg+xml')
    @app.get('/farmer')
    def farmer_web():
        web=ROOT/'web'/'index.html'
        return FileResponse(web if web.exists() else ROOT/'static'/'index.html')
    with engine.begin() as db:
        for row in db.execute(select(users.c.id)).all():student(db,row.id)
    identity_type=IdentityService
    if os.getenv('FARMER_IDENTITY_PROVIDER','keycloak') not in {'keycloak','hydra'}:
        raise ValueError('FARMER_IDENTITY_PROVIDER must be keycloak or hydra')
    if os.getenv('FARMER_IDENTITY_PROVIDER','keycloak')=='keycloak' and os.getenv('FARMER_ENVIRONMENT')=='production' and not os.getenv('FARMER_OIDC_ISSUER'):
        raise ValueError('Production Keycloak mode requires its realm issuer; local authentication fallback is disabled')
    if os.getenv('FARMER_IDENTITY_PROVIDER','keycloak') == 'keycloak' and os.getenv('FARMER_OIDC_ISSUER'):
        from keycloak_identity import KeycloakIdentity
        identity_type=KeycloakIdentity
    app.state.oidc=identity_type(app,engine,users,students,sessions,contacts,password_matches,issue_session,issue_recovery,throttle)
    from admin_auth import AdminAuthentication
    app.state.admin_auth=AdminAuthentication(app,users,password_matches,throttle)
    from email_auth import EmailAuthentication
    app.state.email_auth=EmailAuthentication(app,engine,users,sessions,contacts,students,password_hash,password_matches,validate_password,issue_session,issue_recovery,student,throttle,email_sender,social_gateway)
    from native_access import NativeAccess
    app.state.native = NativeAccess(app, users, password_matches, password_hash, throttle)
    from operations import Operations
    app.state.operations = Operations(app, identity)
    # Explicit rollout gate: existing deployments keep their current identity and
    # administration until the additive tenant migration has been rehearsed.
    if testing or os.getenv('FARMER_TENANCY_ENABLED') == '1':
        from tenancy import Tenancy
        app.state.tenancy = Tenancy(app, users, identity, admin, testing=testing)
    from admin_workspace import Workspace
    app.state.workspace = Workspace(app, users, students, contacts, records, media, identity)
    from push_notifications import PushNotifications
    app.state.push = PushNotifications(app.state.workspace)
    from community import Community
    app.state.community = Community(app.state.workspace)
    from admin_providers import Providers
    app.state.providers = Providers(app.state.workspace)
    from map_download_api import register_map_downloads
    register_map_downloads(app, data_dir, identity, throttle)
    from admin_portal import register_admin_portal
    from miniapp_api import MiniApps
    app.state.miniapps = MiniApps(app, users, records, media, identity, admin, testing=testing)
    register_admin_portal(app,engine,users,students,contacts,records,media,admin)
    app.mount('/static',StaticFiles(directory=ROOT/'static'),name='static')
    if (ROOT/'web').is_dir():app.mount('/',StaticFiles(directory=ROOT/'web',html=True),name='farmer-app')
    return app

app=create_app()
