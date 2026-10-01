"""First-party mobile sessions. These are not an OAuth password grant or ID tokens."""
import hashlib
import hmac
import json
import os
import secrets
import time
from uuid import uuid4
from fastapi import HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy import Table, Column, String, Integer, Boolean, Text, select, insert, update, delete, inspect, text


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


class NativeLogin(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=256)


class NativeRefresh(BaseModel):
    refresh_token: str = Field(min_length=32, max_length=256)
    request_id: str = Field(min_length=32, max_length=100)

class LearningLaunch(BaseModel):
    cmid: int | None = Field(default=None, ge=1, le=2147483647)

class LearningTicket(BaseModel):
    ticket: str = Field(min_length=32, max_length=100)


class NativeAccess:
    def __init__(self, app, users, password_matches, password_hash, throttle):
        self.app, self.users, self.engine = app, users, app.state.engine
        self.identity = app.state.oidc
        self.password_matches, self.password_hash, self.throttle = password_matches, password_hash, throttle
        self.sessions = Table('native_mobile_sessions', users.metadata,
            Column('id', String(36), primary_key=True), Column('owner', String(36), nullable=False),
            Column('access_hash', String(64), unique=True, nullable=False), Column('refresh_hash', String(64), unique=True, nullable=False),
            Column('expires', Integer, nullable=False), Column('refresh_expires', Integer, nullable=False),
            Column('epoch', Integer, nullable=False), Column('revoked', Boolean, nullable=False),
            Column('policy_revision', Integer, nullable=False, server_default='0'), extend_existing=True)
        self.rotations = Table('native_mobile_rotations', users.metadata,
            Column('hash', String(64), primary_key=True), Column('session', String(36), nullable=False),
            Column('nonce', String(64), nullable=False), Column('reply', Text, nullable=False),
            Column('expires', Integer, nullable=False), extend_existing=True)
        self.sessions.create(self.engine, checkfirst=True)
        if 'policy_revision' not in {c['name'] for c in inspect(self.engine).get_columns('native_mobile_sessions')}:
            with self.engine.begin() as db:
                db.execute(text('ALTER TABLE native_mobile_sessions ADD COLUMN policy_revision INTEGER NOT NULL DEFAULT 0'))
        self.rotations.create(self.engine, checkfirst=True)
        self.learning = Table('native_learning_access', users.metadata,
            Column('hash', String(64), primary_key=True), Column('family', String(36), nullable=False),
            Column('kind', String(12), nullable=False), Column('cmid', Integer),
            Column('expires', Integer, nullable=False), extend_existing=True)
        self.learning.create(self.engine, checkfirst=True)
        self.mount()

    def policy(self, db):
        client = os.getenv('FARMER_ANDROID_CLIENT_ID', '')
        if not client: raise HTTPException(503, 'Mobile sign-in is not configured')
        registration, policy = self.identity.policy(db, client)
        policy['_revision'] = registration['revision']
        if policy['type'] != 'native' or 'farmer' not in policy['allowed_roles']:
            raise HTTPException(403, 'Farmer mobile access is not enabled')
        return client, policy

    def person(self, db, owner, epoch=None, lock=False):
        state = self.identity.state(db, owner, lock)
        person = db.execute(select(self.users).where(self.users.c.id == owner)).mappings().first()
        if not person or person['admin'] or state['suspended'] or (epoch is not None and epoch != state['epoch']):
            raise HTTPException(401, 'Farmer account access changed. Sign in again.')
        return dict(person), state

    def tokens(self, client, expiry):
        return {'access_token': 'fpn_' + secrets.token_urlsafe(32), 'refresh_token': 'fpr_' + secrets.token_urlsafe(32),
                'expires': (int(time.time()) + 900) * 1000, 'refreshExpires': expiry * 1000,
                'kind': 'native', 'client': client, 'server': self.identity.origin}

    def introspect(self, token, audience, scopes, expected_client=None):
        self.identity.require_enabled()
        with self.engine.begin() as db:
            client, policy = self.policy(db)
            if expected_client and expected_client != client: raise HTTPException(401, 'Wrong mobile application')
            if audience not in policy['audiences'] or not set(scopes) <= set(policy['scopes']):
                raise HTTPException(403, 'Mobile session is not permitted for this service')
            if token.startswith('fpl_'):
                if audience != 'farmerplus-learning-api' or not set(scopes) <= {'learning:courses:read','learning:content:read'}:
                    raise HTTPException(403, 'Learning session cannot access farm or administration services')
                grant = db.execute(select(self.learning).where(self.learning.c.hash==digest(token), self.learning.c.kind=='session', self.learning.c.expires>int(time.time()))).mappings().first()
                row = db.execute(select(self.sessions).where(self.sessions.c.id==grant['family'], self.sessions.c.revoked.is_(False), self.sessions.c.refresh_expires>int(time.time()))).mappings().first() if grant else None
            else:
                grant = None
                row = db.execute(select(self.sessions).where(self.sessions.c.access_hash == digest(token), self.sessions.c.revoked.is_(False), self.sessions.c.expires > int(time.time()))).mappings().first()
            if not row: raise HTTPException(401, 'Sign in to FarmerPlus')
            if row['policy_revision'] != policy['_revision']: raise HTTPException(401, 'Mobile access settings changed. Sign in again.')
            user, state = self.person(db, row['owner'], row['epoch'])
            subject = self.identity.mapped(db, user['id'])['student_id']
            return user, {'active': True, 'sub': subject, 'client_id': client, 'aud': policy['audiences'],
                          'scope': 'learning:courses:read learning:content:read' if grant else ' '.join(policy['scopes']), 'exp': grant['expires'] if grant else row['expires'], 'ext': {'account_epoch': state['epoch']}}

    def mount(self):
        @self.app.post('/auth/native/login')
        def login(body: NativeLogin, request: Request):
            self.identity.require_enabled()
            username = body.username.strip().lower()
            self.throttle(request, username)
            self.throttle(request, 'native-login-all', limit=120)
            with self.engine.begin() as db:
                client, policy = self.policy(db)
                row = db.execute(select(self.users).where(self.users.c.username == username)).mappings().first()
                if not row:
                    self.password_hash(body.password, b'0000000000000000')
                    raise HTTPException(401, 'Username or password was not accepted')
                user, state = self.person(db, row['id'], lock=True)
                if not self.password_matches(body.password, user['password']):
                    raise HTTPException(401, 'Username or password was not accepted')
                mapped = self.identity.mapped(db, user['id'])
                expiry = int(time.time()) + 30 * 86400
                tokens = self.tokens(client, expiry)
                db.execute(insert(self.sessions).values(id=str(uuid4()), owner=user['id'], access_hash=digest(tokens['access_token']), refresh_hash=digest(tokens['refresh_token']), expires=tokens['expires']//1000, refresh_expires=expiry, epoch=state['epoch'], revoked=False, policy_revision=policy['_revision']))
                self.identity.log(db, user['id'], 'native_farmer_login', client, 'success')
            return {'owner': user['id'], 'username': user['username'], 'admin': False, 'studentId': mapped['student_id'],
                    'credentialEpoch': state['epoch'], 'verified': True, 'accountKind': 'native', 'oidcSession': tokens}

        @self.app.post('/auth/native/refresh')
        def refresh(body: NativeRefresh, request: Request):
            self.identity.require_enabled()
            self.throttle(request, 'native-refresh', limit=120)
            key, nonce = digest(body.refresh_token), digest(body.request_id)
            rejected = False
            result = None
            with self.engine.begin() as db:
                client, policy = self.policy(db)
                prior = db.execute(select(self.rotations).where(self.rotations.c.hash == key)).mappings().first()
                first = db.execute(select(self.sessions).where(self.sessions.c.id == prior['session'] if prior else self.sessions.c.refresh_hash == key)).mappings().first()
                if not first: raise HTTPException(401, 'Sign in again to continue')
                self.person(db, first['owner'], first['epoch'], lock=True)
                row = db.execute(select(self.sessions).where(self.sessions.c.id == first['id']).with_for_update()).mappings().one()
                # Re-read after the account lock to handle simultaneous refreshes.
                prior = db.execute(select(self.rotations).where(self.rotations.c.hash == key)).mappings().first()
                if row['revoked'] or row['refresh_expires'] <= int(time.time()) or row['policy_revision'] != policy['_revision']:
                    raise HTTPException(401, 'Sign in again to continue')
                if prior:
                    if hmac.compare_digest(prior['nonce'], nonce) and prior['expires'] > int(time.time()):
                        result = json.loads(self.identity.cipher.decrypt(prior['reply'].encode()))
                    else:
                        db.execute(update(self.sessions).where(self.sessions.c.id == row['id']).values(revoked=True))
                        self.identity.log(db, row['owner'], 'native_refresh_reuse', row['id'], 'revoked')
                        rejected = True
                else:
                    result = self.tokens(client, row['refresh_expires'])
                    db.execute(update(self.sessions).where(self.sessions.c.id == row['id']).values(access_hash=digest(result['access_token']), refresh_hash=digest(result['refresh_token']), expires=result['expires']//1000))
                    db.execute(insert(self.rotations).values(hash=key, session=row['id'], nonce=nonce, reply=self.identity.cipher.encrypt(json.dumps(result).encode()).decode(), expires=int(time.time())+120))
                # Keep token hashes for replay detection; erase expired cached replies.
                db.execute(update(self.rotations).where(self.rotations.c.expires < int(time.time())).values(reply=''))
            if rejected: raise HTTPException(401, 'Sign-in was renewed elsewhere. Sign in again.')
            return result

        @self.app.post('/learning/native-launch')
        def launch(body: LearningLaunch, request: Request):
            from urllib.parse import urlsplit
            if os.getenv('FARMER_NATIVE_LEARNING_ENABLED') != '1':
                raise HTTPException(503, 'The Learning connection is being prepared. Saved text lessons remain available.')
            origin = os.getenv('FARMER_LEARNING_ORIGIN','')
            parsed = urlsplit(origin)
            if parsed.scheme!='https' or not parsed.hostname or parsed.username or parsed.port or parsed.query or parsed.fragment or parsed.path:
                raise HTTPException(503, 'Learning is not configured')
            token = request.headers.get('authorization','').removeprefix('Bearer ')
            if not token.startswith('fpn_'): raise HTTPException(401, 'Sign in from the farmer app')
            user, claims = self.introspect(token,'farmerplus-learning-api',['learning:courses:read','learning:content:read'])
            tenancy = getattr(self.app.state,'tenancy',None)
            if tenancy:
                tenancy.context(user,'farmerplus')
            self.throttle(request, 'learning-launch:'+user['id'], limit=30)
            ticket = secrets.token_urlsafe(32)
            with self.engine.begin() as db:
                self.person(db,user['id'],claims['ext']['account_epoch'],lock=True)
                family = db.execute(select(self.sessions.c.id).where(self.sessions.c.access_hash==digest(token),self.sessions.c.revoked.is_(False))).scalar_one_or_none()
                if not family: raise HTTPException(401,'Sign in again')
                db.execute(delete(self.learning).where(self.learning.c.expires<int(time.time())))
                db.execute(insert(self.learning).values(hash=digest(ticket),family=family,kind='ticket',cmid=body.cmid,expires=int(time.time())+60))
            return {'url':origin+'/auth/farmerplusoidc/native.php','ticket':ticket,'expiresIn':60}

        @self.app.post('/learning/native-consume')
        def consume(body: LearningTicket, request: Request):
            self.identity.require_enabled()
            expected = os.getenv('FARMER_LEARNING_INTROSPECTION_SECRET','')
            supplied = request.headers.get('authorization','').removeprefix('Bearer ')
            if len(expected)<32 or not hmac.compare_digest(expected,supplied): raise HTTPException(403,'Learning server authentication required')
            with self.engine.begin() as db:
                client, policy = self.policy(db)
                needed = {'learning:courses:read','learning:content:read'}
                if 'farmerplus-learning-api' not in policy['audiences'] or not needed <= set(policy['scopes']): raise HTTPException(403,'Learning access is disabled')
                row = db.execute(select(self.learning).where(self.learning.c.hash==digest(body.ticket),self.learning.c.kind=='ticket',self.learning.c.expires>int(time.time()))).mappings().first()
                if not row: raise HTTPException(401,'Learning link expired or already used')
                family = db.execute(select(self.sessions).where(self.sessions.c.id==row['family'], self.sessions.c.revoked.is_(False), self.sessions.c.refresh_expires>int(time.time()))).mappings().first()
                if not family or family['policy_revision'] != policy['_revision']: raise HTTPException(401,'Farmer session ended')
                user, state = self.person(db,family['owner'],family['epoch'],lock=True)
                if db.execute(delete(self.learning).where(self.learning.c.hash==row['hash'])).rowcount!=1: raise HTTPException(401,'Learning link already used')
                mapped = self.identity.mapped(db,user['id'])
                token = 'fpl_'+secrets.token_urlsafe(32)
                expires = min(int(time.time())+14400, family['refresh_expires'])
                db.execute(insert(self.learning).values(hash=digest(token),family=family['id'],kind='session',cmid=row['cmid'],expires=expires))
                self.identity.log(db,user['id'],'native_learning_handoff',client,'consumed')
                return {'access_token':token,'cmid':row['cmid'],'claims':{'active':True,'iss':self.identity.issuer,
                    'sub':mapped['student_id'],'farmerplus_id':mapped['student_id'],'client_id':client,
                    'given_name':mapped['firstname'] or user['username'],'family_name':mapped['lastname'] or 'Farmer',
                    'aud':['farmerplus-learning-api'],'scope':'learning:courses:read learning:content:read',
                    'epoch':state['epoch'],'iat':int(time.time()),'exp':expires,'sid':family['id']}}
