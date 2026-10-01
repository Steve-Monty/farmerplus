"""Keycloak RP and registration reconciliation. No local password authority.

The existing owner-scoped storage and Learning proxy remain shared. Keycloak
owns login, verification, recovery, brokers and sessions; no Hydra routes mount.
"""
import asyncio
import json
import os
import re
import secrets
import time
from pathlib import Path
from urllib.parse import urlencode, quote, urlsplit
from uuid import uuid4, uuid5, NAMESPACE_URL

import httpx
from authlib.integrations.starlette_client import OAuth
from authlib.jose import JsonWebToken
from cryptography.fernet import Fernet
from fastapi import HTTPException, Request, Body
from fastapi.responses import RedirectResponse, JSONResponse, HTMLResponse, FileResponse
from sqlalchemy import MetaData, Table, Column, String, Integer, Text, select, insert, update, delete
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.dialects.postgresql import insert as pg_insert

from oidc import IdentityService, meta as identity_meta, app_sessions, outbox, rp_delivery, security, flows, sha, compact
from schema_migrations import apply_identity_schema, apply_additive_schema
from keycloak_browser_session import retire_browser_sessions

meta = MetaData()
activity_meta = MetaData()
browser_activity = Table('keycloak_browser_activity', activity_meta,
    Column('hash', String(64), primary_key=True), Column('last_activity', Integer, nullable=False))
bindings = Table('keycloak_bindings', meta,
    Column('issuer', String(500), primary_key=True), Column('subject', String(255), primary_key=True),
    Column('owner', String(36), unique=True, nullable=False), Column('farmer_id', String(32), unique=True, nullable=False),
    Column('revoked_before', Integer, nullable=False, default=0))
logout_receipts = Table('keycloak_logout_receipts',meta,
    Column('jti',String(255),primary_key=True),Column('expires',Integer,nullable=False))
keycloak_sessions = Table('keycloak_session_bindings',meta,
    Column('hash',String(64),primary_key=True),Column('subject',String(255),nullable=False),Column('sid',String(255),nullable=False))
provisions = Table('learning_provisioning', meta,
    Column('owner', String(36), primary_key=True), Column('event_id', String(36), nullable=False),
    Column('payload', Text, nullable=False), Column('status', String(24), nullable=False),
    Column('attempts', Integer, nullable=False), Column('next_attempt', Integer, nullable=False), Column('revision', Integer, nullable=False),
    Column('moodle_id', Integer), Column('error', String(120)))


def permanent_id(issuer, subject):
    return uuid5(NAMESPACE_URL, issuer + '\x00' + subject).hex


def validate_url(value, development=False):
    p = urlsplit(value)
    if p.username or p.password or p.query or p.fragment or not p.hostname or '*' in value:
        raise ValueError('An exact service URL is required')
    if p.scheme != 'https' and not (development and p.scheme == 'http' and p.hostname in {'127.0.0.1', 'localhost'}):
        raise ValueError('HTTPS is required outside explicit loopback development')
    return value.rstrip('/')


class KeycloakGateway:
    """Bounded, non-redirecting transport; exceptions never include credentials."""
    def __init__(self, issuer, client, secret, admin_client, admin_secret):
        self.issuer, self.client, self.secret = issuer, client, secret
        self.admin_client, self.admin_secret = admin_client, admin_secret
        self.protocol = issuer + '/protocol/openid-connect'
        root, realm = issuer.rsplit('/realms/', 1)
        self.admin_url = root + '/admin/realms/' + quote(realm, safe='')

    def request(self, method, url, **kwargs):
        try:
            with httpx.Client(timeout=15, follow_redirects=False) as client:
                response = client.request(method, url, **kwargs)
            if response.status_code >= 300 or len(response.content) > 2_000_000:
                raise ValueError()
            return response.json() if response.content else None
        except Exception:
            raise HTTPException(503, 'Identity service request failed; retry scheduled') from None

    def inspect(self, token):
        return self.request('POST', self.protocol + '/token/introspect',
            auth=(self.client, self.secret), data={'token': token})

    def admin(self, method, path, **kwargs):
        token = self.request('POST', self.protocol + '/token', auth=(self.admin_client, self.admin_secret),
            data={'grant_type': 'client_credentials'})
        return self.request(method, self.admin_url + path,
            headers={'Authorization': 'Bearer ' + token['access_token']}, **kwargs)


class KeycloakIdentity(IdentityService):
    provider = 'keycloak'
    web_flow_lifetime = 1800

    def browser_token(self, request):
        key, now = sha(request.cookies.get('fp_app', '')), int(time.time())
        with self.engine.begin() as db:
            last = db.execute(select(browser_activity.c.last_activity).where(browser_activity.c.hash == key)).scalar_one_or_none()
            if last is not None and now - last >= 1800:
                raise HTTPException(401, 'Session inactive. Sign in to continue.')
        token, client = super().browser_token(request)
        # Existing sessions get one initial activity baseline at rollout.
        if last is None:
            with self.engine.begin() as db:
                stmt = pg_insert if db.dialect.name == 'postgresql' else sqlite_insert
                db.execute(stmt(browser_activity).values(hash=key, last_activity=now).on_conflict_do_nothing())
        return token, client

    def restart_web_flow(self, request, status=403):
        """Restart once with fresh PKCE/state; never accept the expired code."""
        try:
            context = json.loads(self.cipher.decrypt(
                request.cookies.get('fp_oidc_return', '').encode(), ttl=43200))
            if (context['state'] != sha(request.query_params.get('state', ''))
                    or context['destination'] not in {'pwa', 'learning', 'admin'}
                    or request.query_params.get('error')
                    or not request.query_params.get('code')):
                raise ValueError('Untrusted restart')
            try:
                self.cipher.decrypt(request.cookies.get('fp_oidc_restart', '').encode(), ttl=120)
            except Exception:
                pass
            else:
                raise ValueError('Automatic restart already attempted')
            origin = self.admin_origin if context['destination'] == 'admin' else self.origin
            if request.headers.get('host') != urlsplit(origin).netloc:
                raise ValueError('Wrong callback host')
            response = RedirectResponse(origin + '/oidc/web/login?' + urlencode({
                'destination': context['destination'], 'cmid': context.get('cmid', 0)}), 303,
                headers={'Cache-Control': 'no-store'})
            response.set_cookie('fp_oidc_restart', self.cipher.encrypt(b'restarted').decode(),
                secure=not self.development, httponly=True, samesite='lax', max_age=120)
            return response
        except Exception:
            return self.sign_in_retry(status)

    def sign_in_retry(self, status=403, reason='session'):
        # No request parameters or identity details are interpolated into HTML.
        message = {
            'session': 'This sign-in session expired, was already used, or could not be verified. Your account and saved work are safe.',
            'provider': 'This sign-in provider is not configured. Use email and password or another available provider.',
            'unavailable': 'Sign-in is temporarily unavailable. Please try again shortly. Your account and saved work are safe.',
        }.get(reason, 'Please start sign-in again.')
        page = '''<!doctype html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Continue to FarmerPlus</title><link rel="stylesheet" href="/oidc/appearance.css">
</head><body><main><img src="/assets/assets/branding/wordmark.png" alt="FarmerPlus">
<h1>Let’s start sign-in again</h1><p>MESSAGE</p>
<a href="/oidc/web/login">Return to FarmerPlus sign in</a>
<a href="/oidc/web/login?destination=learning">Return to Learning sign in</a></main></body></html>'''
        return HTMLResponse(page.replace('MESSAGE', message), status_code=status,
            headers={'Cache-Control':'no-store','Referrer-Policy':'no-referrer',
                     'Content-Security-Policy':"default-src 'none'; style-src 'self'; img-src 'self'; base-uri 'none'; frame-ancestors 'none'"})

    def consume_web_flow(self, request, state):
        # State identifies the tab's flow; the HttpOnly browser cookie binds it
        # to this browser. A second tab must not overwrite the first tab's flow.
        if not state or len(state) > 512:
            raise HTTPException(403, 'Start sign-in again to create a fresh session.')
        with self.engine.begin() as db:
            row = db.execute(select(flows).where(
                flows.c.csrf == sha(state), flows.c.kind == 'web',
                flows.c.browser == sha(request.cookies.get('fp_oidc_browser', '')),
                flows.c.expires > int(time.time()))).mappings().first()
            if not row:
                raise HTTPException(403, 'This sign-in expired or was already used. Start again.')
            if db.execute(delete(flows).where(flows.c.hash == row['hash'])).rowcount != 1:
                raise HTTPException(403, 'This sign-in was already used. Start again.')
        return json.loads(self.cipher.decrypt(row['sealed'].encode()))

    def __init__(self, app, engine, users, students, sessions, contacts, password_matches, issue_session, issue_recovery, throttle):
        self.app, self.engine, self.users, self.students, self.sessions, self.contacts = app, engine, users, students, sessions, contacts
        self.password_matches, self.issue_session, self.issue_recovery, self.throttle = password_matches, issue_session, issue_recovery, throttle
        self.environment = os.getenv('FARMER_ENVIRONMENT', 'staging')
        self.development = os.getenv('FARMER_KEYCLOAK_LOOPBACK') == '1' and self.environment != 'production'
        self.issuer = validate_url(os.environ['FARMER_OIDC_ISSUER'], self.development)
        if not re.fullmatch(r'.+/realms/[A-Za-z0-9_-]+', self.issuer):
            raise ValueError('Configure the separate FarmerPlus Keycloak realm issuer')
        self.origin = validate_url(os.environ['FARMER_PWA_PUBLIC_URL'], self.development)
        self.admin_origin = validate_url(os.getenv('FARMER_PUBLIC_URL') or self.origin, self.development)
        self.client_id = os.environ['FARMER_WEB_CLIENT_ID']
        self.client_secret = os.environ['FARMER_WEB_CLIENT_SECRET']
        self.learning_client = os.environ['FARMER_LEARNING_CLIENT_ID']
        self.cipher = Fernet(os.environ['FARMER_OIDC_STORAGE_KEY'].encode())
        self.gateway = KeycloakGateway(self.issuer, self.client_id, self.client_secret,
            os.environ['FARMER_KEYCLOAK_ADMIN_CLIENT_ID'], os.environ['FARMER_KEYCLOAK_ADMIN_CLIENT_SECRET'])
        self.token_endpoint = self.gateway.protocol + '/token'
        self.enabled = True
        self.schema = apply_identity_schema(engine, identity_meta)
        apply_additive_schema(engine, meta, '20260922_01_keycloak_learning', 'Keycloak subject bindings and durable Learning provisioning')
        apply_additive_schema(engine, activity_meta, '20260929_01_browser_activity', 'Explicit browser activity; background sync does not extend inactivity')
        self.mount()
        self.last_reconcile_error = 'Awaiting first identity reconciliation'
        async def run():
            while True:
                try:
                    await asyncio.to_thread(self.reconcile)
                    self.last_reconcile_error = None
                except Exception:
                    self.last_reconcile_error = 'Identity reconciliation pending'
                try:
                    await asyncio.to_thread(self.drain)
                    await asyncio.to_thread(self.drain_provisioning)
                except Exception:
                    self.last_reconcile_error = 'Learning delivery pending'
                await asyncio.sleep(15)
        async def start():
            self.worker = asyncio.create_task(run())
        async def stop():
            self.worker.cancel()
            try:
                await self.worker
            except asyncio.CancelledError:
                pass
        app.router.on_startup.append(start)
        app.router.on_shutdown.append(stop)

    def web_secret(self):
        return self.client_secret

    def policy(self, db, client):
        if client not in {self.client_id, self.learning_client, os.getenv('FARMER_ANDROID_CLIENT_ID')}:
            raise HTTPException(403, 'Unapproved identity client')
        return {}, {}

    def web_rp(self):
        return OAuth().register('farmerplus', client_id=self.client_id, client_secret=self.client_secret,
            server_metadata_url=self.issuer + '/.well-known/openid-configuration',
            client_kwargs={'scope': 'openid profile email farmerplus.identity farm:read farm:write learning:courses:read learning:content:read',
                'code_challenge_method': 'S256', 'token_endpoint_auth_method': 'client_secret_basic'})

    async def metadata(self, rp):
        try:
            metadata=await rp.load_server_metadata()
            if metadata.get('issuer') != self.issuer: raise ValueError()
            for endpoint in ('authorization_endpoint','token_endpoint','jwks_uri'):
                if not metadata.get(endpoint,'').startswith(self.issuer+'/protocol/openid-connect/'):
                    raise ValueError()
            return metadata
        except Exception:
            raise HTTPException(503,'Identity discovery is unavailable or does not match this realm') from None

    def bind(self, profile):
        """Only verified Keycloak claims/admin records enter this transaction."""
        sub = profile.get('id') or profile.get('sub')
        email = profile.get('email')
        first = profile.get('firstName', profile.get('given_name', '')).strip()
        last = profile.get('lastName', profile.get('family_name', '')).strip()
        verified = profile.get('emailVerified', profile.get('email_verified')) is True
        if not isinstance(sub, str) or not 1 <= len(sub) <= 255 or not verified or not isinstance(email, str) or '@' not in email or len(email) > 254 or not first or not last or max(len(first),len(last)) > 100:
            raise HTTPException(403, 'Finish verified email and name setup in FarmerPlus sign-in')
        farmer_id = permanent_id(self.issuer, sub)
        with self.engine.begin() as db:
            owner = str(uuid5(NAMESPACE_URL, 'farmerplus-owner:' + self.issuer + '\x00' + sub))
            stmt = pg_insert if db.dialect.name == 'postgresql' else sqlite_insert
            db.execute(stmt(bindings).values(issuer=self.issuer, subject=sub, owner=owner, farmer_id=farmer_id).on_conflict_do_nothing())
            binding = db.execute(select(bindings).where(bindings.c.issuer == self.issuer, bindings.c.subject == sub)).mappings().one()
            owner = binding['owner']
            if binding['farmer_id'] != farmer_id:
                raise HTTPException(409, 'Permanent identity mapping requires review')
            db.execute(stmt(self.users).values(id=owner, username='kc:' + farmer_id, password='!keycloak-managed', admin=False, serial=0).on_conflict_do_nothing())
            db.execute(stmt(self.students).values(owner=owner, student_id=farmer_id, provider='keycloak', firstname=first, lastname=last).on_conflict_do_update(index_elements=['owner'],set_={'firstname':first,'lastname':last}))
            db.execute(stmt(self.contacts).values(owner=owner, email=email, verified=True).on_conflict_do_update(index_elements=['owner'],set_={'email':email,'verified':True}))
            self.state(db, owner, True)
            tenancy = getattr(self.app.state, 'tenancy', None)
            if tenancy:
                tenancy.register_farmerplus(db, owner)
            payload = compact({'issuer':self.issuer,'sub':sub,'farmerplus_id':farmer_id,'tenant':'farmerplus',
                'instance':'farmerplus-learning','email':email,'email_verified':True,'given_name':first,'family_name':last})
            current = db.execute(select(provisions).where(provisions.c.owner == owner)).mappings().first()
            if not current:
                db.execute(insert(provisions).values(owner=owner,event_id=str(uuid4()),payload=payload,status='pending',attempts=0,next_attempt=0,revision=1))
            elif current['payload'] != payload:
                db.execute(update(provisions).where(provisions.c.owner == owner).values(event_id=str(uuid4()),payload=payload,status='pending',attempts=0,next_attempt=0,error=None,revision=current['revision']+1))
            return dict(db.execute(select(self.users).where(self.users.c.id == owner)).mappings().one())

    def prepare_profile(self, profile):
        user = self.bind(profile)
        sub = profile.get('id') or profile['sub']
        attrs = dict(profile.get('attributes') or {})
        expected = [permanent_id(self.issuer, sub)]
        if attrs.get('farmerplus_id') != expected:
            attrs['farmerplus_id'] = expected
            # Keycloak's declarative profile validates required fields even on
            # an attributes-only PUT. Preserve them instead of clearing them.
            update_profile = {key: profile[key] for key in
                ('username', 'email', 'firstName', 'lastName') if key in profile}
            self.gateway.admin('PUT', '/users/' + quote(sub, safe=''), json={**update_profile, 'attributes':attrs})
        return user

    def reconcile(self):
        """Poll persisted users, so lost registration webhooks cannot lose accounts.

        Includes verified email/social registration before the first PWA callback.
        Full paginated reconciliation intentionally avoids an event timestamp gap.
        """
        offset = 0
        while True:
            people = self.gateway.admin('GET', '/users', params={'first':offset,'max':100,'briefRepresentation':'false'})
            for profile in people:
                sub = profile.get('id', '')
                with self.engine.begin() as db:
                    binding = db.execute(select(bindings).where(bindings.c.issuer == self.issuer,bindings.c.subject == sub)).mappings().first()
                    if binding:
                        state = self.state(db,binding['owner'],True)
                        suspended = profile.get('enabled') is not True
                        if state['suspended'] != suspended:
                            self.queue_revoke(db,owner=binding['owner'],suspend=suspended)
                if profile.get('enabled') is True and profile.get('emailVerified') is True:
                    try:
                        self.prepare_profile(profile)
                    except HTTPException as error:
                        if error.status_code != 403:
                            raise
            if len(people) < 100:
                break
            offset += len(people)

    def learning_introspection(self, token, scope):
        # Moodle alone may validate an explicitly approved loopback preview
        # client. Ordinary farm resources continue to use the main allowlist.
        return self.introspect(token, 'farmerplus-learning-api', [scope], allow_preview_learning=True)

    def introspect(self, token, audience, scopes, expected_client=None, allow_preview_learning=False):
        value = self.gateway.inspect(token)
        audiences = value.get('aud', [])
        if isinstance(audiences,str): audiences = [audiences]
        if value.get('active') is not True or value.get('iss') != self.issuer or value.get('exp',0) <= time.time() or audience not in audiences:
            raise HTTPException(401,'Access is expired or not valid for this service')
        client = value.get('client_id') or value.get('azp')
        if expected_client and client != expected_client:
            raise HTTPException(401,'Token belongs to another application')
        preview_client = os.getenv('FARMER_PREVIEW_LEARNING_CLIENT_ID', '')
        approved_preview = (allow_preview_learning and audience == 'farmerplus-learning-api'
                            and bool(preview_client) and client == preview_client)
        if not approved_preview:
            self.policy(None,client)
        if not set(scopes) <= set(value.get('scope','').split()):
            raise HTTPException(403,'Token scope is insufficient')
        with self.engine.begin() as db:
            binding = db.execute(select(bindings).where(bindings.c.issuer == self.issuer,bindings.c.subject == value.get('sub'))).mappings().first()
            if not binding or value.get('farmerplus_id') != binding['farmer_id']:
                raise HTTPException(401,'Permanent identity is not ready; sign in again')
            state = self.state(db,binding['owner'])
            if state['suspended']:
                raise HTTPException(401,'Account is suspended')
            if type(value.get('iat')) is not int or value['iat'] <= binding['revoked_before']:
                raise HTTPException(401,'Token predates account revocation')
            pending = db.execute(select(outbox.c.id).where(outbox.c.subject==binding['farmer_id'],outbox.c.status=='pending')).first()
            if pending:
                raise HTTPException(401,'Account logout is pending. Sign in again after it completes.')
            user = dict(db.execute(select(self.users).where(self.users.c.id == binding['owner'])).mappings().one())
        return user,{**value,'client_id':client,'ext':{'account_epoch':state['epoch']}}

    def drain_provisioning(self):
        origin = os.getenv('FARMER_LEARNING_ORIGIN','')
        secret = os.getenv('FARMER_LEARNING_PROVISIONING_SECRET','')
        if not origin or len(secret) < 32:
            return
        validate_url(origin,False)
        now = int(time.time())
        with self.engine.connect() as db:
            rows = db.execute(select(provisions).where(provisions.c.status == 'pending',provisions.c.next_attempt <= now).limit(20)).mappings().all()
        for row in rows:
            # Claim with a lease, permitting restart/retry and concurrent workers.
            with self.engine.begin() as db:
                claimed = db.execute(update(provisions).where(provisions.c.owner == row['owner'],provisions.c.event_id == row['event_id'],provisions.c.next_attempt == row['next_attempt']).values(next_attempt=now+60))
                if claimed.rowcount != 1: continue
            try:
                payload = {**json.loads(row['payload']),'event_id':row['event_id'],'revision':row['revision']}
                with httpx.Client(timeout=20,follow_redirects=False) as client:
                    result = client.post(origin.rstrip('/')+'/auth/farmerplusoidc/provision.php',json=payload,headers={'Authorization':'Bearer '+secret})
                if result.status_code != 200 or len(result.content)>4096: raise ValueError()
                body = result.json()
                if body.get('event_id') != row['event_id'] or body.get('farmerplus_id') != payload['farmerplus_id'] or body.get('tenant') != 'farmerplus' or body.get('instance') != 'farmerplus-learning' or type(body.get('moodle_id')) is not int or body['moodle_id'] < 1: raise ValueError()
                with self.engine.begin() as db:
                    changed = db.execute(update(provisions).where(provisions.c.owner == row['owner'],provisions.c.event_id == row['event_id']).values(status='ready',moodle_id=body['moodle_id'],error=None))
                    if changed.rowcount:
                        db.execute(update(self.students).where(self.students.c.owner == row['owner']).values(moodle_id=body['moodle_id']))
            except Exception:
                attempts = row['attempts']+1
                with self.engine.begin() as db:
                    db.execute(update(provisions).where(provisions.c.owner == row['owner'],provisions.c.event_id == row['event_id']).values(attempts=attempts,next_attempt=now+min(3600,5*2**min(attempts,10)),error='Learning provisioning pending; automatic retry scheduled'))

    def provisioning_status(self, owner):
        with self.engine.connect() as db:
            row = db.execute(select(provisions).where(provisions.c.owner == owner)).mappings().first()
        return {'status': ('needs_attention' if row['attempts'] >= 10 else row['status']) if row else 'pending',
            'moodleId':row['moodle_id'] if row and row['status']=='ready' else None,
            'retrying':bool(row and row['status']=='pending')}

    def drain(self):
        with self.engine.connect() as db:
            rows = db.execute(select(outbox).where(outbox.c.status=='pending',outbox.c.next_attempt<=int(time.time())).limit(20)).mappings().all()
        for row in rows:
            try:
                with self.engine.connect() as db:
                    binding = db.execute(select(bindings).where(bindings.c.farmer_id == row['subject'])).mappings().first()
                if not binding: raise ValueError()
                self.gateway.admin('POST','/users/'+quote(binding['subject'],safe='')+'/logout')
                with self.engine.begin() as db:
                    db.execute(update(outbox).where(outbox.c.id==row['id']).values(status='provider_revoked',error=None))
            except Exception:
                with self.engine.begin() as db:
                    db.execute(update(outbox).where(outbox.c.id==row['id']).values(attempts=row['attempts']+1,next_attempt=int(time.time())+60,error='Keycloak logout pending'))

    def revocation_subject(self, farmer_id):
        with self.engine.connect() as db:
            return db.execute(select(bindings.c.subject).where(bindings.c.farmer_id==farmer_id)).scalar_one_or_none()

    def queue_revoke(self,db,owner=None,client=None,suspend=None):
        event=super().queue_revoke(db,owner,client,suspend)
        if owner:
            db.execute(update(bindings).where(bindings.c.owner==owner).values(revoked_before=int(time.time())))
        return event

    def apply_logout(self,claims):
        now=int(time.time())
        if claims.get('iss')!=self.issuer or self.client_id not in ([claims.get('aud')] if isinstance(claims.get('aud'),str) else claims.get('aud',[])):
            raise HTTPException(400,'Logout issuer or audience mismatch')
        event='http://schemas.openid.net/event/backchannel-logout'
        if type(claims.get('iat')) is not int or not now-120 <= claims['iat'] <= now+30 or 'nonce' in claims or not isinstance(claims.get('jti'),str) or not 1<=len(claims['jti'])<=255 or not isinstance(claims.get('events'),dict) or claims['events'].get(event)!= {}:
            raise HTTPException(400,'Invalid logout claims')
        sub=claims.get('sub');sid=claims.get('sid')
        if not any(isinstance(v,str) and 1<=len(v)<=255 for v in (sub,sid)):
            raise HTTPException(400,'Logout identity missing')
        with self.engine.begin() as db:
            stmt=pg_insert if db.dialect.name=='postgresql' else sqlite_insert
            receipt=db.execute(stmt(logout_receipts).values(jti=claims['jti'],expires=now+3600).on_conflict_do_nothing())
            if receipt.rowcount != 1:return
            if not sub:
                sub=db.execute(select(keycloak_sessions.c.subject).where(keycloak_sessions.c.sid==sid)).scalar()
            binding=db.execute(select(bindings).where(bindings.c.issuer==self.issuer,bindings.c.subject==sub)).mappings().first()
            if binding:
                # Revoke all local sessions for that person, a deliberate stronger
                # boundary than a single browser session. No remote logout loop.
                state=self.state(db,binding['owner'],True)
                db.execute(update(security).where(security.c.owner==binding['owner']).values(epoch=state['epoch']+1))
                db.execute(update(bindings).where(bindings.c.owner==binding['owner']).values(revoked_before=max(binding['revoked_before'],claims['iat'])))
                db.execute(delete(self.sessions).where(self.sessions.c.owner==binding['owner']))
                db.execute(delete(app_sessions).where(app_sessions.c.owner==binding['owner']))
                db.execute(delete(keycloak_sessions).where(keycloak_sessions.c.subject==sub))
            db.execute(delete(logout_receipts).where(logout_receipts.c.expires<now))

    def mount(self):
        app = self.app
        previous = list(app.router.routes)
        super().mount()
        # Reuse only provider-neutral Learning transport/durable revocation routes.
        app.router.routes[:] = previous + [r for r in app.router.routes[len(previous):]
            if getattr(r,'path','').startswith(('/learning/','/oidc/resource/'))]

        @app.post('/auth/activity')
        def activity(request: Request, payload: dict = Body(default={})):
            if request.headers.get('origin') not in {None, self.origin, self.admin_origin}:
                raise HTTPException(403, 'Unapproved activity origin')
            if not request.cookies.get('fp_app'):
                raise HTTPException(401, 'Browser session required')
            self.resource_identity(request)
            now = int(time.time())
            idle = payload.get('idleForSeconds', 0)
            if set(payload) - {'idleForSeconds'} or type(idle) is not int or not 0 <= idle < 1800:
                raise HTTPException(422, 'Invalid activity age')
            with self.engine.begin() as db:
                db.execute(update(browser_activity).where(browser_activity.c.hash == sha(request.cookies.get('fp_app', '')), browser_activity.c.last_activity < now-idle).values(last_activity=now-idle))
                db.execute(update(app_sessions).where(app_sessions.c.hash == sha(request.cookies.get('fp_app', ''))).values(expires=now+43200))
                db.execute(update(self.sessions).where(self.sessions.c.hash == sha(request.cookies.get(app.state.session_cookie, ''))).values(expires=now+43200))
                db.execute(delete(browser_activity).where(browser_activity.c.last_activity < now - 86400))
            response = JSONResponse({'idleSeconds': 1800}, headers={'Cache-Control': 'no-store'})
            for name in ['fp_app', app.state.session_cookie]:
                response.set_cookie(name, request.cookies.get(name, ''), secure=not self.development,
                                    httponly=True, samesite='lax', max_age=43200)
            return response

        @app.middleware('http')
        async def keycloak_authority(request, call_next):
            path = request.url.path
            if path.startswith(('/auth/email/','/auth/social/','/auth/mobile/','/auth/native/')) or path in {'/auth/register','/auth/login','/auth/recover','/auth/change','/auth/recovery/reissue','/auth/offline/verify','/learning/native-launch','/learning/native-consume'}:
                return JSONResponse({'detail':'Continue through FarmerPlus Keycloak sign-in','startUrl':'/oidc/web/login'},409)
            return await call_next(request)

        @app.get('/oidc/config')
        def config():
            return {'enabled':True,'provider':'keycloak','issuer':self.issuer,'webSignIn':self.origin+'/oidc/web/login',
                'androidClientId':os.getenv('FARMER_ANDROID_CLIENT_ID'),'androidRedirect':os.getenv('FARMER_ANDROID_REDIRECT'),
                'learningUrl':os.getenv('FARMER_LEARNING_ORIGIN'),'environment':self.environment}

        @app.get('/oidc/appearance.css')
        def appearance():
            return FileResponse(Path(__file__).parent/'identity/keycloak/retry.css', media_type='text/css')

        @app.get('/oidc/web/login')
        async def login(request:Request, provider:str='', register:bool=False, destination:str='pwa', cmid:int=0):
            if destination == 'admin' and getattr(getattr(app.state, 'admin_auth', None), 'enabled', False):
                return RedirectResponse(self.admin_origin + '/admin/login', 303)
            if destination not in {'pwa', 'learning', 'admin'}:
                raise HTTPException(400, 'Choose FarmerPlus, Learning or administration as the sign-in destination')
            if destination == 'learning':
                validate_url(os.environ.get('FARMER_LEARNING_ORIGIN', ''), self.development)
            if cmid < 0 or cmid > 2147483647:
                raise HTTPException(400, 'Invalid Learning activity')
            flow_origin = self.admin_origin if destination == 'admin' else self.origin
            # Set flow cookies on the same host that receives the callback.
            # Only configured origins are used; Host never chooses a return URL.
            if request.headers.get('host') != urlsplit(flow_origin).netloc:
                return RedirectResponse(flow_origin+'/oidc/web/login?'+urlencode({
                    'destination':destination, 'cmid':cmid, 'provider':provider,
                    'register':'true' if register else 'false'}),303)
            rp=self.web_rp()
            try: await self.metadata(rp)
            except HTTPException: return self.sign_in_retry(503, 'unavailable')
            options = {}
            if provider:
                if provider not in {'google','apple'} or os.getenv('FARMER_KEYCLOAK_'+provider.upper()+'_ENABLED')!='1':
                    return self.sign_in_retry(503, 'provider')
                options['kc_idp_hint']=provider
            if register: options['prompt']='create'
            data=await rp.create_authorization_url(redirect_uri=flow_origin+'/oidc/web/callback',**options)
            data['callback_origin'] = flow_origin
            data['destination'] = destination
            data['cmid'] = cmid
            flow,_,browser=self.new_flow(request,'web',data,csrf_override=data['state'],lifetime=self.web_flow_lifetime)
            response=self.redirect(data['url'])
            for name,value in [('fp_oidc_browser',browser),('fp_oidc_client',flow)]:
                response.set_cookie(name,value,secure=not self.development,httponly=True,samesite='lax',max_age=self.web_flow_lifetime)
            recovery = self.cipher.encrypt(compact({'state': sha(data['state']),
                'destination': destination, 'cmid': cmid}).encode()).decode()
            response.set_cookie('fp_oidc_return', recovery, secure=not self.development,
                                httponly=True, samesite='lax', max_age=43200)
            return response

        @app.get('/oidc/web/callback')
        async def callback(request:Request):
            try:
                payload=self.consume_web_flow(request,request.query_params.get('state',''))
            except HTTPException:
                # Back/reload may revisit a consumed callback. Existing access
                # must still pass full session and token validation; never
                # exchange the authorization code again or trust URL targets.
                try:
                    receipt = json.loads(self.cipher.decrypt(
                        request.cookies.get('fp_oidc_completed', '').encode(),
                        ttl=self.web_flow_lifetime))
                    if (receipt['state'] != sha(request.query_params.get('state', ''))
                            or receipt['code'] != sha(request.query_params.get('code', ''))
                            or receipt['session'] != sha(request.cookies.get('fp_app', ''))):
                        raise ValueError('Different callback or browser session')
                    await asyncio.to_thread(self.resource_identity, request)
                except Exception:
                    pass
                else:
                    return RedirectResponse(receipt['target'], 303,
                                            headers={'Cache-Control': 'no-store'})
                return self.restart_web_flow(request)
            if request.query_params.get('error') or not request.query_params.get('code'):
                return self.sign_in_retry(401)
            flow_origin = payload.get('callback_origin', self.origin)
            expected_origin = self.admin_origin if payload.get('destination') == 'admin' else self.origin
            if flow_origin != expected_origin or request.headers.get('host') != urlsplit(flow_origin).netloc:
                return self.sign_in_retry(401)
            try:
                rp=self.web_rp(); await self.metadata(rp)
                rp.server_metadata['id_token_signing_alg_values_supported']=['RS256']
                token=await rp.fetch_access_token(redirect_uri=flow_origin+'/oidc/web/callback',code=request.query_params['code'],code_verifier=payload['code_verifier'])
                claims=await rp.parse_id_token(token,nonce=payload['nonce'],claims_options={'iss':{'essential':True,'value':self.issuer},'aud':{'essential':True,'value':self.client_id},'exp':{'essential':True},'nonce':{'essential':True,'value':payload['nonce']}},leeway=5)
                if claims.get('azp',self.client_id)!=self.client_id: raise ValueError()
            except Exception:
                return self.restart_web_flow(request, 401)
            profile=await asyncio.to_thread(self.gateway.admin,'GET','/users/'+quote(claims['sub'],safe=''))
            if profile.get('enabled') is not True or profile.get('id') != claims['sub']:
                raise HTTPException(401,'Identity is unavailable')
            user=await asyncio.to_thread(self.prepare_profile,profile)
            # The first login may predate the readonly stable-ID attribute. Renew
            # after assigning it so Moodle and the API receive the same claim.
            from authlib.integrations.httpx_client import AsyncOAuth2Client
            try:
                async with AsyncOAuth2Client(self.client_id,self.client_secret,token_endpoint_auth_method='client_secret_basic',timeout=15) as client:
                    renewed=await client.refresh_token(self.token_endpoint,refresh_token=token['refresh_token'])
            except Exception:
                raise HTTPException(503,'Sign-in renewal is temporarily unavailable; retry sign-in') from None
            token={**token,**renewed}
            verified,value=await asyncio.to_thread(self.introspect,token['access_token'],'farmerplus-api',['farm:read'],self.client_id)
            if verified['id']!=user['id'] or value['sub']!=claims['sub']:
                raise HTTPException(401,'Token identities do not match')
            target = (os.environ['FARMER_LEARNING_ORIGIN'].rstrip('/') + '/auth/farmerplusoidc/login.php?continue=1&cmid=' + str(payload.get('cmid', 0))
                      if payload.get('destination') == 'learning' else self.admin_origin+'/admin'
                      if payload.get('destination') == 'admin' else self.origin+'/auth/callback')
            response=RedirectResponse(target,303)
            with self.engine.begin() as db:
                state=self.state(db,user['id'],True)
                if state['suspended']: raise HTTPException(401,'Account is suspended')
                # The browser-bound authorization flow has proved the new account.
                # Retire only cookies presented by this browser, then rotate both
                # sessions. Owner-scoped saved work and other devices stay intact.
                retire_browser_sessions(db,request,self.sessions,
                                        app.state.session_cookie,keycloak_sessions)
                self.issue_session(db,user,response)
                key=secrets.token_urlsafe(32)
                db.execute(insert(app_sessions).values(hash=sha(key),owner=user['id'],client=self.client_id,epoch=state['epoch'],sealed=self.cipher.encrypt(compact(token).encode()).decode(),expires=int(time.time())+43200))
                db.execute(insert(keycloak_sessions).values(hash=sha(key),subject=claims['sub'],sid=claims.get('sid','')))
                db.execute(insert(browser_activity).values(hash=sha(key),last_activity=int(time.time())))
            response.set_cookie('fp_app',key,secure=not self.development,httponly=True,samesite='lax',max_age=43200)
            receipt = self.cipher.encrypt(compact({
                'state': sha(request.query_params.get('state', '')),
                'code': sha(request.query_params.get('code', '')),
                'session': sha(key), 'target': target,
            }).encode()).decode()
            response.set_cookie('fp_oidc_completed', receipt, secure=not self.development,
                                httponly=True, samesite='lax', max_age=self.web_flow_lifetime)
            response.delete_cookie('fp_oidc_client')
            response.delete_cookie('fp_oidc_return')
            response.delete_cookie('fp_oidc_restart')
            return response

        @app.get('/learning/provisioning')
        def status(request:Request):
            user=self.resource_identity(request)
            return self.provisioning_status(user['id'])

        @app.get('/account')
        def account():
            return RedirectResponse(self.issuer+'/account/',303)

        @app.post('/oidc/backchannel')
        async def backchannel(request:Request):
            raw=await request.body()
            if len(raw)>32768: raise HTTPException(413,'Logout request too large')
            from urllib.parse import parse_qs
            values=parse_qs(raw.decode('utf-8'))
            signed=values.get('logout_token',[''])[0]
            try:
                keys=await asyncio.to_thread(self.gateway.request,'GET',self.gateway.protocol+'/certs')
                claims=JsonWebToken(['RS256']).decode(signed,keys,claims_options={'iss':{'essential':True,'value':self.issuer},'aud':{'essential':True,'value':self.client_id},'iat':{'essential':True}})
                claims.validate(leeway=5)
                self.apply_logout(dict(claims))
            except Exception:
                raise HTTPException(400,'Logout could not be verified') from None
            return {}

        @app.get('/oidc/logout')
        def logout(request:Request):
            # Local authenticated POST logout queues server-to-server Keycloak
            # logout first; this redirect also clears the realm browser session.
            return RedirectResponse(self.gateway.protocol+'/logout?'+urlencode({'client_id':self.client_id,'post_logout_redirect_uri':self.origin+'/auth/callback'}),303)
