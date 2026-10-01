"""Versioned first-party downloadable apps and atomic, owner-scoped commands."""
import base64
import hashlib
import json
import os
import re
import secrets
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal
from uuid import UUID

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from fastapi import Depends, HTTPException, Query, Request
from fastapi import Response
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import MetaData, Table, Column, String, Integer, Text, LargeBinary, select, insert, update
from animal_rules import apply, empty_state, RuleError, BREEDS, TYPES

ROOT = Path(__file__).resolve().parent
meta = MetaData()
registry = Table('miniapp_registry', meta, Column('id', String(64), primary_key=True), Column('metadata', Text, nullable=False))
releases = Table('miniapp_releases', meta, Column('app_id', String(64), primary_key=True), Column('version', Integer, primary_key=True), Column('manifest', Text, nullable=False), Column('body', LargeBinary, nullable=False), Column('status', String(20), nullable=False))
states = Table('miniapp_states', meta, Column('owner', String(36), primary_key=True), Column('app_id', String(64), primary_key=True), Column('revision', Integer, nullable=False), Column('state', Text, nullable=False))
receipts = Table('miniapp_receipts', meta, Column('owner', String(36), primary_key=True), Column('app_id', String(64), primary_key=True), Column('operation_id', String(36), primary_key=True), Column('digest', String(64), nullable=False), Column('response', Text, nullable=False))
installs = Table('miniapp_installations', meta, Column('owner', String(36), primary_key=True), Column('id', String(36), primary_key=True), Column('app_id', String(64), nullable=False), Column('report', Text, nullable=False))
audit = Table('miniapp_audit', meta, Column('id', Integer, primary_key=True, autoincrement=True), Column('app_id', String(64), nullable=False), Column('actor', String(36), nullable=False), Column('action', String(80), nullable=False), Column('at', String(40), nullable=False), Column('reason', Text, nullable=False))
CAPABILITIES = ['context', 'theme', 'farms.read', 'farms.create', 'locations.read', 'locations.create', 'records', 'commands', 'drafts', 'media.read', 'media.write', 'sync', 'export']

def canonical(x): return json.dumps(x, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False)
def now(): return datetime.now(timezone.utc).isoformat()
def digest(x): return hashlib.sha256(x).hexdigest()
def fail(status, message): raise HTTPException(status, message)

async def allow_verified_frame_scripts(response):
    """Bind downloaded frame scripts to a per-document nonce, including offline HTML."""
    if response.status_code != 200 or 'text/html' not in response.headers.get('content-type',''):
        return response
    nonce=secrets.token_urlsafe(24)
    content=b''.join([part async for part in response.body_iterator])
    marker=f'<meta name="farmerplus-script-nonce" content="{nonce}">'.encode()
    content=content.replace(b'</head>',marker+b'</head>',1)
    headers=dict(response.headers)
    headers.pop('content-length',None)
    headers.pop('etag',None)
    headers.pop('last-modified',None)
    headers['cache-control']='no-store'
    headers['content-security-policy']=headers['content-security-policy'].replace("script-src 'self'",f"script-src 'nonce-{nonce}' 'self'",1)
    return Response(content,status_code=response.status_code,headers=headers)

class Input(BaseModel):
    model_config = ConfigDict(extra='forbid')

class Command(Input):
    operationId: UUID
    deviceId: UUID
    schemaVersion: Literal[1] = 1
    ruleVersion: Literal[1] = 1
    expectedRevision: int = Field(ge=0, strict=True)
    name: str = Field(min_length=1, max_length=80)
    payload: dict

class Installation(Input):
    version: int = Field(ge=1)
    state: Literal['Downloading', 'Installed', 'Failed', 'Removed']
    deviceId: UUID

class AppInput(Input):
    id: str = Field(pattern=r'^[a-z][a-z0-9-]{1,63}$')
    title: str = Field(min_length=1, max_length=80)
    description: str = Field(max_length=300)

class ReleaseInput(Input):
    package: str = Field(max_length=6000000)
    releaseNotes: str = Field(default='', max_length=4000)

class Reason(Input):
    reason: str = Field(min_length=3, max_length=500)

def signing_key(testing=False):
    configured = os.getenv('FARMER_MINIAPP_SIGNING_KEY')
    production = os.getenv('FARMER_ENVIRONMENT') == 'production' and not testing
    path = Path(configured) if configured else ROOT / '.local-development' / 'miniapp-signing.pem'
    if production and not configured:
        return None
    if not path.exists():
        if production: return None
        path.parent.mkdir(parents=True, exist_ok=True)
        key = ec.generate_private_key(ec.SECP256R1())
        # Exclusive create: concurrent development test processes must share one key.
        try:
            with path.open('xb') as f:
                f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        except FileExistsError: pass
    return serialization.load_pem_private_key(path.read_bytes(), password=None)

def public_key(key):
    return base64.b64encode(key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)).decode()

def package_bytes():
    folder = ROOT / 'miniapps' / 'my-animals'
    if not (folder / 'index.html').exists(): return None
    html = (folder / 'index.html').read_text(encoding='utf-8')
    for marker, filename in [('/* APP_STYLE */', 'style.css'), ('/* APP_RULES */', 'rules.js'), ('/* APP_CODE */', 'app.js')]:
        html = html.replace(marker, (folder / filename).read_text(encoding='utf-8'))
    return canonical({'format': 1, 'id':'my-animals', 'version':1, 'sdk':1, 'html':html}).encode()

def validate_package(raw, app_id):
    if len(raw) > 4 * 1024 * 1024: fail(413, 'App package must be smaller than 4 MB.')
    try:
        obj = json.loads(raw)
        assert set(obj) == {'format','id','version','sdk','html'} and obj['format'] == 1 and obj['sdk'] == 1
        assert obj['id'] == app_id and type(obj['version']) is int and 0 < obj['version'] < 1000000
        assert isinstance(obj['html'], str) and '<html' in obj['html']
    except (ValueError, AssertionError, TypeError): fail(422, 'Invalid app package or unsupported SDK.')
    return obj

class MiniApps:
    def __init__(self, app, users, shared, media, identity, admin, testing=False):
        self.app, self.engine, self.users, self.shared, self.media = app, app.state.engine, users, shared, media
        meta.create_all(self.engine)
        self.key = signing_key(testing)
        self.testing = testing
        raw = package_bytes()
        if raw and self.key and (testing or os.getenv('FARMER_ENVIRONMENT', 'development') != 'production'):
            # Local first-party seed only. Never silently replace immutable released bytes.
            with self.engine.begin() as db:
                if not db.execute(select(registry).where(registry.c.id == 'my-animals')).first():
                    db.execute(insert(registry).values(id='my-animals', metadata=canonical({'title':'My Animals','description':'Your animals, their locations and a clear record of what happened.','category':'Records'})))
                if not db.execute(select(releases).where(releases.c.app_id == 'my-animals', releases.c.version == 1)).first():
                    self.store_release(db, 'my-animals', raw, 'Initial My Animals release', 'Published')
        self.routes(identity, admin)

    def store_release(self, db, app_id, raw, notes, status='Draft'):
        obj = validate_package(raw, app_id)
        if self.key is None: fail(503, 'Configure the app release signing key first.')
        signed = {'appId':app_id, 'version':obj['version'], 'sdk':1, 'ruleVersion':1, 'bytes':len(raw), 'sha256':digest(raw), 'capabilities':CAPABILITIES, 'releasedAt':now(), 'releaseNotes':notes}
        encoded = canonical(signed).encode()
        r,s = decode_dss_signature(self.key.sign(encoded, ec.ECDSA(hashes.SHA256())))
        manifest = {**signed, 'signed':base64.b64encode(encoded).decode(), 'signature':base64.b64encode(r.to_bytes(32,'big')+s.to_bytes(32,'big')).decode(), 'keyId':digest(base64.b64decode(public_key(self.key)))[:16]}
        db.execute(insert(releases).values(app_id=app_id, version=obj['version'], manifest=canonical(manifest), body=raw, status=status))
        return manifest

    def app_meta(self, db, app_id):
        row = db.execute(select(registry).where(registry.c.id == app_id)).mappings().first()
        if not row: fail(404, 'App not found.')
        return {'id':app_id, **json.loads(row['metadata'])}

    def snapshot(self, db, owner, app_id):
        row = db.execute(select(states).where(states.c.owner == owner, states.c.app_id == app_id)).mappings().first()
        return {'revision':row['revision'], 'state':json.loads(row['state'])} if row else {'revision':0, 'state':empty_state()}

    def context(self, db, owner):
        rows = db.execute(select(self.shared).where(self.shared.c.owner == owner, self.shared.c.deleted == False)).mappings().all()
        farms, locations = {}, {}
        for row in rows:
            data = json.loads(row['data'])
            if row['kind'] == 'farm': farms[row['id']] = data
            if row['kind'] == 'field': locations[row['id']] = data.get('farmId')
        return {'farms':farms, 'locations':locations}

    def protect_location(self, db, owner, record_id, kind, data, deleted):
        for row in db.execute(select(states.c.state).where(states.c.owner == owner)).all():
            for p in json.loads(row[0])['profiles']:
                if not p.get('active'): continue
                referenced = p.get('farmId' if kind == 'farm' else 'locationId') == record_id
                if referenced and (deleted or (kind == 'field' and data.get('farmId') != p.get('farmId'))):
                    raise ValueError('Move the animals at this location before removing it or changing its farm.')

    def validate_media(self, db, owner, state):
        hashes_used = {p.get('photo') for p in state['profiles']} | {e.get('photo') for e in state['events']}
        for sha in hashes_used - {None, ''}:
            if not db.execute(select(self.media.c.hash).where(self.media.c.owner == owner, self.media.c.hash == sha, self.media.c.complete == True)).first():
                fail(422, 'Wait for the photo to upload before syncing this record.')

    def log(self, db, user, app_id, action, reason):
        db.execute(insert(audit).values(app_id=app_id, actor=user['id'], action=action, reason=reason, at=now()))

    def routes(self, identity, admin):
        app = self.app
        def known(app_id):
            if app_id != 'my-animals': fail(422, 'This app has no registered record service.')

        @app.get('/api/v1/apps')
        def catalogue(user=Depends(identity)):
            with self.engine.connect() as db:
                result=[]
                for row in db.execute(select(registry)).mappings():
                    release=db.execute(select(releases).where(releases.c.app_id==row['id'], releases.c.status=='Published').order_by(releases.c.version.desc())).mappings().first()
                    if release: result.append({**self.app_meta(db,row['id']), 'release':json.loads(release['manifest']), 'offline':True, 'price':'free'})
            return {'apps':result,'sdk':1}

        @app.get('/api/v1/apps/{app_id}')
        def detail(app_id:str,user=Depends(identity)):
            return next((item for item in catalogue(user)['apps'] if item['id']==app_id), None) or fail(404,'App unavailable.')

        @app.get('/api/v1/apps/{app_id}/releases')
        def versions(app_id:str,user=Depends(identity)):
            with self.engine.connect() as db:
                self.app_meta(db,app_id)
                return {'releases':[json.loads(r['manifest']) for r in db.execute(select(releases).where(releases.c.app_id==app_id,releases.c.status=='Published').order_by(releases.c.version.desc())).mappings()]}

        def release_row(app_id,version):
            with self.engine.connect() as db:
                row=db.execute(select(releases).where(releases.c.app_id==app_id,releases.c.version==version,releases.c.status=='Published')).mappings().first()
            if not row: fail(404,'This app release is not available.')
            return row

        @app.get('/api/v1/apps/{app_id}/releases/{version}/manifest')
        def manifest(app_id:str,version:int,user=Depends(identity)):
            return json.loads(release_row(app_id,version)['manifest'])

        @app.get('/api/v1/apps/{app_id}/releases/{version}/package')
        def package(app_id:str,version:int,offset:int=0,user=Depends(identity)):
            row=release_row(app_id,version); raw=row['body']
            if not 0<=offset<=len(raw):fail(416,'Invalid download offset.')
            chunk=raw[offset:offset+65536]
            return {'chunk':base64.b64encode(chunk).decode(),'offset':offset,'nextOffset':offset+len(chunk),'total':len(raw),'sha256':digest(raw)}

        @app.put('/api/v1/apps/{app_id}/installations/{installation_id}')
        def report(app_id:str,installation_id:UUID,body:Installation,user=Depends(identity)):
            with self.engine.begin() as db:
                self.app_meta(db,app_id)
                db.execute(update(self.users).where(self.users.c.id==user['id']).values(serial=self.users.c.serial+1))
                key=(installs.c.owner==user['id']) & (installs.c.id==str(installation_id))
                prior=db.execute(select(installs).where(key)).mappings().first()
                if prior and prior['app_id']!=app_id:fail(409,'Installation identity belongs to another app.')
                value=canonical({**body.model_dump(mode='json'),'reportedAt':now()})
                if prior:db.execute(update(installs).where(key).values(report=value))
                else:db.execute(insert(installs).values(owner=user['id'],id=str(installation_id),app_id=app_id,report=value))
            return {'saved':True}

        @app.get('/api/v1/platform/context')
        def platform_context(user=Depends(identity)):
            return {'owner':user['id'],'sdk':1,'capabilities':CAPABILITIES}

        def shared_records(owner,kind):
            with self.engine.connect() as db:
                return [{'id':r['id'],'version':r['version'],**json.loads(r['data'])} for r in db.execute(select(self.shared).where(self.shared.c.owner==owner,self.shared.c.kind==kind,self.shared.c.deleted==False)).mappings()]

        @app.get('/api/v1/farmer/profile')
        def farmer_profile(user=Depends(identity)):
            rows=shared_records(user['id'],'profile')
            return {k:v for k,v in (rows[0] if rows else {}).items() if k in {'id','name','firstname','lastname','language'}}

        @app.get('/api/v1/farms')
        def farms(user=Depends(identity)):
            return {'farms':shared_records(user['id'],'farm')}

        @app.get('/api/v1/farms/{farm_id}')
        def farm(farm_id:UUID,user=Depends(identity)):
            return next((r for r in shared_records(user['id'],'farm') if r['id']==str(farm_id)),None) or fail(404,'Farm unavailable.')

        @app.get('/api/v1/farms/{farm_id}/locations')
        def locations(farm_id:UUID,user=Depends(identity)):
            farm(farm_id,user)
            return {'locations':[r for r in shared_records(user['id'],'field') if r.get('farmId')==str(farm_id)]}

        @app.get('/api/v1/locations/{location_id}')
        def loc(location_id:UUID,user=Depends(identity)):
            return next((r for r in shared_records(user['id'],'field') if r['id']==str(location_id)),None) or fail(404,'Location unavailable.')

        @app.get('/api/v1/apps/{app_id}/catalogues/{name}')
        def catalogues(app_id:str,name:str,user=Depends(identity)):
            known(app_id)
            if name!='animals':fail(404,'Catalogue unavailable.')
            return {'version':1,'types':TYPES,'breeds':BREEDS}

        @app.get('/api/v1/apps/{app_id}/records')
        def records(app_id:str,user=Depends(identity)):
            known(app_id)
            with self.engine.connect() as db:return self.snapshot(db,user['id'],app_id)

        @app.get('/api/v1/apps/{app_id}/changes')
        def changes(app_id:str,cursor:int=Query(default=0,ge=0),user=Depends(identity)):
            result=records(app_id,user)
            return {'cursor':result['revision'],'complete':True,'snapshot':result if result['revision']!=cursor else None}

        @app.get('/api/v1/apps/{app_id}/records/{kind}/{record_id}')
        def record(app_id:str,kind:str,record_id:UUID,user=Depends(identity)):
            key={'animal':'profiles','animalGroup':'profiles','animalEvent':'events','animalBreed':'breeds','animalType':'types'}.get(kind)
            if not key:fail(404,'Unknown record kind.')
            snap=records(app_id,user)
            value=next((r for r in snap['state'][key] if r['id']==str(record_id)),None)
            if not value or (kind in {'animal','animalGroup'} and value['kind']!=('group' if kind=='animalGroup' else 'individual')):fail(404,'Record unavailable.')
            return {'revision':snap['revision'],'record':value}

        def run(app_id,body,user,preview=False):
            known(app_id)
            command=body.model_dump(mode='json'); encoded=canonical(command)
            if len(encoded.encode())>64000:fail(413,'Command exceeds 64 KB.')
            with self.engine.begin() as db:
                db.execute(update(self.users).where(self.users.c.id==user['id']).values(serial=self.users.c.serial+1))
                receipt_key=(receipts.c.owner==user['id']) & (receipts.c.app_id==app_id) & (receipts.c.operation_id==str(body.operationId))
                existing=db.execute(select(receipts).where(receipt_key)).mappings().first()
                if existing:
                    if existing['digest']!=digest(encoded.encode()):fail(409,'Operation ID already used with different content.')
                    return json.loads(existing['response'])
                previous=self.snapshot(db,user['id'],app_id)
                if previous['revision']!=body.expectedRevision:fail(409,'Animal records changed on another device. Review your pending changes before syncing.')
                try: state=apply(previous['state'],command,self.context(db,user['id']))
                except RuleError as e:fail(422,str(e))
                except (KeyError, TypeError, AttributeError):fail(422,'Check the required command fields and their types.')
                if preview:return {'revision':previous['revision'],'state':state,'status':'preview'}
                self.validate_media(db,user['id'],state)
                # Author/time belong to the authenticated service, not client payload.
                old_events={e['id']:e for e in previous['state']['events']}
                for e in state['events']:
                    old=old_events.get(e['id'])
                    if not old:e.update(author=user['id'],recordedAt=now())
                    if len(e.get('revisions',[]))>len(old.get('revisions',[]) if old else []):e['revisions'][-1].update(author=user['id'],recordedAt=now())
                result={'operationId':str(body.operationId),'status':'applied','revision':previous['revision']+1,'state':state,'serverTime':now()}
                if len(canonical(state).encode())>8*1024*1024:fail(413,'Animal records exceed this version’s 8 MB account limit. Export your data and contact support.')
                values={'revision':result['revision'],'state':canonical(state)}
                if previous['revision']:db.execute(update(states).where(states.c.owner==user['id'],states.c.app_id==app_id).values(**values))
                else:db.execute(insert(states).values(owner=user['id'],app_id=app_id,**values))
                db.execute(insert(receipts).values(owner=user['id'],app_id=app_id,operation_id=str(body.operationId),digest=digest(encoded.encode()),response=canonical(result)))
                return result

        @app.post('/api/v1/apps/{app_id}/commands/preview')
        def preview(app_id:str,body:Command,user=Depends(identity)):return run(app_id,body,user,True)

        @app.post('/api/v1/apps/{app_id}/commands')
        def command(app_id:str,body:Command,user=Depends(identity)):return run(app_id,body,user)

        @app.get('/api/v1/apps/{app_id}/commands/{operation_id}')
        def receipt(app_id:str,operation_id:UUID,user=Depends(identity)):
            known(app_id)
            with self.engine.connect() as db:
                row=db.execute(select(receipts.c.response).where(receipts.c.owner==user['id'],receipts.c.app_id==app_id,receipts.c.operation_id==str(operation_id))).first()
            return json.loads(row[0]) if row else fail(404,'Operation not yet accepted.')

        @app.get('/admin/api/v2/apps')
        def admin_apps(user=Depends(admin)):
            with self.engine.connect() as db:
                return {'apps':[{**self.app_meta(db,r['id']),'releases':[{'status':v['status'],**json.loads(v['manifest'])} for v in db.execute(select(releases).where(releases.c.app_id==r['id']).order_by(releases.c.version.desc())).mappings()]} for r in db.execute(select(registry)).mappings()]}

        @app.post('/admin/api/v2/apps')
        def register(body:AppInput,user=Depends(admin)):
            with self.engine.begin() as db:
                if db.execute(select(registry).where(registry.c.id==body.id)).first():fail(409,'App ID already exists.')
                db.execute(insert(registry).values(id=body.id,metadata=canonical(body.model_dump(exclude={'id'}))))
                self.log(db,user,body.id,'Registered','App registered')
            return body.model_dump()

        @app.get('/admin/api/v2/apps/{app_id}')
        def admin_detail(app_id:str,user=Depends(admin)):
            return next((a for a in admin_apps(user)['apps'] if a['id']==app_id),None) or fail(404,'App unavailable.')

        @app.patch('/admin/api/v2/apps/{app_id}')
        def metadata(app_id:str,body:AppInput,user=Depends(admin)):
            if body.id!=app_id:fail(422,'App ID cannot change.')
            with self.engine.begin() as db:
                self.app_meta(db,app_id)
                db.execute(update(registry).where(registry.c.id==app_id).values(metadata=canonical(body.model_dump(exclude={'id'}))))
                self.log(db,user,app_id,'Metadata updated','Store description updated')
            return body.model_dump()

        @app.get('/admin/api/v2/apps/{app_id}/releases')
        def admin_versions(app_id:str,user=Depends(admin)):return {'releases':admin_detail(app_id,user)['releases']}

        @app.post('/admin/api/v2/apps/{app_id}/releases')
        def upload(app_id:str,body:ReleaseInput,user=Depends(admin)):
            try:raw=base64.b64decode(body.package,validate=True)
            except ValueError:fail(422,'Invalid package encoding.')
            obj=validate_package(raw,app_id)
            with self.engine.begin() as db:
                self.app_meta(db,app_id)
                if db.execute(select(releases).where(releases.c.app_id==app_id,releases.c.version==obj['version'])).first():fail(409,'Release versions are immutable. Use a new version.')
                result=self.store_release(db,app_id,raw,body.releaseNotes)
                self.log(db,user,app_id,'Uploaded',body.releaseNotes)
            return result

        def transition(app_id,version,action,reason,user):
            with self.engine.begin() as db:
                row=db.execute(select(releases).where(releases.c.app_id==app_id,releases.c.version==version)).mappings().first()
                if not row:fail(404,'Release unavailable.')
                validate_package(row['body'],app_id)
                if digest(row['body'])!=json.loads(row['manifest'])['sha256']:fail(422,'Package integrity failed.')
                if action=='validate':status='Validated' if row['status']=='Draft' else row['status']
                elif action=='retire':status='Retired'
                else:
                    if row['status'] not in {'Validated','Published','Retired'}:fail(409,'Validate this release before publishing.')
                    status='Published'
                    if action=='rollback':db.execute(update(releases).where(releases.c.app_id==app_id,releases.c.version>version,releases.c.status=='Published').values(status='Retired'))
                db.execute(update(releases).where(releases.c.app_id==app_id,releases.c.version==version).values(status=status))
                self.log(db,user,app_id,f'{action} v{version}',reason)
            return {'status':status}

        @app.post('/admin/api/v2/apps/{app_id}/releases/{version}/validate')
        def validate(app_id:str,version:int,body:Reason,user=Depends(admin)):return transition(app_id,version,'validate',body.reason,user)
        @app.post('/admin/api/v2/apps/{app_id}/releases/{version}/publish')
        def publish(app_id:str,version:int,body:Reason,user=Depends(admin)):return transition(app_id,version,'publish',body.reason,user)
        @app.post('/admin/api/v2/apps/{app_id}/releases/{version}/retire')
        def retire(app_id:str,version:int,body:Reason,user=Depends(admin)):return transition(app_id,version,'retire',body.reason,user)
        @app.post('/admin/api/v2/apps/{app_id}/releases/{version}/rollback')
        def rollback(app_id:str,version:int,body:Reason,user=Depends(admin)):return transition(app_id,version,'rollback',body.reason,user)

        @app.get('/admin/api/v2/apps/{app_id}/installations')
        def installations(app_id:str,user=Depends(admin)):
            with self.engine.connect() as db:return {'installations':[{'id':r['id'],'owner':r['owner'],**json.loads(r['report'])} for r in db.execute(select(installs).where(installs.c.app_id==app_id)).mappings()]}

        @app.get('/admin/api/v2/apps/{app_id}/audit')
        def history(app_id:str,user=Depends(admin)):
            with self.engine.connect() as db:return {'events':[dict(r) for r in db.execute(select(audit).where(audit.c.app_id==app_id).order_by(audit.c.id.desc()).limit(200)).mappings()]}
