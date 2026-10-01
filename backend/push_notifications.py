"""Durable owner-scoped inbox and leased FCM outbox. No credentials in payloads/logs."""
import hashlib
import json
import os
import time
from uuid import UUID, uuid4
from typing import Literal
from fastapi import HTTPException, Query, Request
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import (MetaData, Table, Column, String, Text, BigInteger, Integer,
                        Boolean, select, insert, update, func, or_)
from schema_migrations import apply_additive_schema

meta = MetaData()
registrations = Table('push_registrations', meta,
    Column('device', String(36), primary_key=True), Column('owner', String(36), nullable=False, index=True),
    Column('token', Text, nullable=False), Column('token_hash', String(64), nullable=False, unique=True),
    Column('permission', String(20), nullable=False), Column('version', String(80), nullable=False),
    Column('preferences', Text, nullable=False), Column('updated', BigInteger, nullable=False),
    Column('active', Boolean, nullable=False))
messages = Table('push_inbox', meta,
    Column('id', String(36), primary_key=True), Column('owner', String(36), nullable=False, index=True),
    Column('event_key', String(128), nullable=False, unique=True), Column('category', String(20), nullable=False),
    Column('title', String(160), nullable=False), Column('body', Text, nullable=False),
    Column('destination', String(20), nullable=False), Column('resource', String(128), nullable=False),
    Column('created', BigInteger, nullable=False), Column('opened', BigInteger), Column('read', BigInteger))
outbox = Table('push_outbox', meta,
    Column('id', String(36), primary_key=True), Column('message', String(36), nullable=False, index=True),
    Column('device', String(36), nullable=False), Column('owner', String(36), nullable=False),
    Column('state', String(24), nullable=False), Column('attempts', Integer, nullable=False),
    Column('next_at', BigInteger, nullable=False), Column('expires', BigInteger, nullable=False),
    Column('lease', String(36)), Column('accepted', BigInteger), Column('error', String(80)))

def now(): return int(time.time() * 1000)
def encoded(value): return json.dumps(value, sort_keys=True, separators=(',', ':'))

class Input(BaseModel):
    model_config = ConfigDict(extra='forbid')

class Preferences(Input):
    learning: bool = True
    planner: bool = True
    account: bool = True
    general: bool = True
    quietStart: int | None = Field(default=None, ge=0, le=23)
    quietEnd: int | None = Field(default=None, ge=0, le=23)
    utcOffsetMinutes: int = Field(default=0, ge=-840, le=840)

class Registration(Input):
    deviceId: UUID
    token: str = Field(min_length=20, max_length=4096, pattern=r'^\S+$')
    permission: Literal['authorized', 'denied', 'notDetermined', 'provisional']
    version: str = Field(max_length=80)
    preferences: Preferences = Field(default_factory=Preferences)

class Notification(Input):
    eventId: UUID
    title: str = Field(min_length=1, max_length=160)
    body: str = Field(min_length=1, max_length=4000)
    category: Literal['learning', 'planner', 'account', 'general'] = 'general'
    destination: Literal['inbox', 'task', 'learning'] = 'inbox'
    resourceId: str = Field(default='', max_length=128, pattern=r'^[A-Za-z0-9_-]*$')
    deviceId: UUID | None = None

def quiet(preferences, at):
    start, end = preferences.get('quietStart'), preferences.get('quietEnd')
    if start is None or end is None or start == end: return False
    hour = ((at // 60000 + preferences.get('utcOffsetMinutes', 0)) // 60) % 24
    return start <= hour < end if start < end else hour >= start or hour < end

class PushNotifications:
    def __init__(self, ws):
        self.ws, self.engine = ws, ws.engine
        apply_additive_schema(self.engine, meta, '20260916_05_push_inbox',
                              'Owner inbox, device registrations and leased push delivery outbox')
        self.mount()

    def register(self, owner, body):
        device, token_hash = str(body.deviceId), hashlib.sha256(body.token.encode()).hexdigest()
        with self.engine.begin() as db:
            # Serialize concurrent registration writes for the same authenticated owner.
            db.execute(update(self.ws.users).where(self.ws.users.c.id == owner).values(serial=self.ws.users.c.serial))
            # Ownership transfers require explicit revocation, not possession of a device UUID.
            old = db.execute(select(registrations).where(or_(registrations.c.device == device,
                registrations.c.token_hash == token_hash))).mappings().all()
            if any(r['owner'] != owner for r in old):
                raise HTTPException(409, 'Create a fresh push installation after switching accounts')
            if any(r['device'] != device for r in old): raise HTTPException(409, 'Registration already assigned')
            values = dict(owner=owner, token=body.token, token_hash=token_hash,
                          permission=body.permission, version=body.version,
                          preferences=encoded(body.preferences.model_dump()), updated=now(), active=True)
            if old: db.execute(update(registrations).where(registrations.c.device == device).values(**values))
            else: db.execute(insert(registrations).values(device=device, **values))
        return {'ack': 'y', 'deviceId': device, 'owner': owner}

    def enqueue(self, db, owner, body):
        key = owner + ':' + str(body.eventId)
        prior = db.execute(select(messages).where(messages.c.event_key == key)).mappings().first()
        if prior:
            if any(prior[k] != v for k,v in {'title':body.title,'body':body.body,
                'category':body.category,'destination':body.destination,'resource':body.resourceId}.items()):
                raise HTTPException(409, 'Event already has different content')
            return prior['id']
        if body.destination == 'task':
            r = self.ws.records
            if not db.scalar(select(r.c.id).where(r.c.id == body.resourceId, r.c.owner == owner,
                    r.c.kind == 'task', r.c.deleted.is_(False))): raise HTTPException(404, 'Task not available')
        # Learning destination opens the authoritative enrolled-course list, not arbitrary URLs.
        targets = list(db.execute(select(registrations).where(registrations.c.owner == owner,
            registrations.c.active.is_(True))).mappings())
        if body.deviceId:
            targets = [r for r in targets if r['device'] == str(body.deviceId)]
            if not targets: raise HTTPException(404, 'Device not available')
        mid, at = str(uuid4()), now()
        db.execute(insert(messages).values(id=mid, owner=owner, event_key=key, category=body.category,
            title=body.title, body=body.body, destination=body.destination, resource=body.resourceId, created=at))
        for r in targets:
            db.execute(insert(outbox).values(id=str(uuid4()), message=mid, device=r['device'], owner=owner,
                state='pending', attempts=0, next_at=at, expires=at+86400000))
        return mid

    def mount(self):
        app = self.ws.app
        def owner(request):
            user = app.state.oidc.resource_identity(request)
            if user['admin']: raise HTTPException(403, 'Farmer account required')
            return user['id']

        @app.put('/notifications/registration')
        def register(body: Registration, request: Request): return self.register(owner(request), body)

        @app.delete('/notifications/registration/{device}')
        def revoke(device: UUID, request: Request):
            uid = owner(request)
            with self.engine.begin() as db:
                db.execute(update(registrations).where(registrations.c.device == str(device),
                    registrations.c.owner == uid).values(active=False, token='', updated=now()))
            return {'ack': 'y'}

        @app.get('/notifications')
        def inbox(request: Request, before: int = Query(default=9223372036854775807, ge=0), beforeId: str = ''):
            uid = owner(request)
            with self.engine.connect() as db:
                rows = [dict(r) for r in db.execute(select(messages).where(messages.c.owner == uid,
                    or_(messages.c.created < before, (messages.c.created == before) & (messages.c.id > beforeId)))
                    .order_by(messages.c.created.desc(), messages.c.id).limit(100)).mappings()]
            return {'items': rows, 'fetchedAt': now()}

        @app.get('/notifications/{mid}')
        def message(mid: UUID, request: Request):
            uid = owner(request)
            with self.engine.begin() as db:
                condition = (messages.c.id == str(mid)) & (messages.c.owner == uid)
                row = db.execute(select(messages).where(condition)).mappings().first()
                if not row: raise HTTPException(404, 'Notification not available for this account')
                db.execute(update(messages).where(condition, messages.c.opened.is_(None)).values(opened=now()))
                result = dict(row)
                if row['destination'] == 'task':
                    r = self.ws.records
                    record = db.execute(select(r).where(r.c.id == row['resource'], r.c.owner == uid,
                        r.c.deleted.is_(False))).mappings().first()
                    result['latestRecord'] = {**dict(record), 'data': json.loads(record['data'])} if record else None
                return result

        @app.post('/notifications/{mid}/read')
        def read(mid: UUID, request: Request):
            uid = owner(request)
            with self.engine.begin() as db:
                condition = (messages.c.id == str(mid)) & (messages.c.owner == uid)
                event = db.scalar(select(messages.c.event_key).where(condition))
                if not event: raise HTTPException(404, 'Notification not available')
                db.execute(update(messages).where(condition, messages.c.read.is_(None)).values(read=now()))
                self.ws.record_delivery(db, uid, event.split(':')[-1], read=True)
            return {'ack': 'y'}

        @app.post('/admin/api/v2/farmers/{uid}/notifications')
        def send(uid: str, body: Notification, request: Request, tenant: str = ''):
            ctx = self.ws.authorize(self.ws.identity(request), tenant, write=True)
            self.ws.owner(ctx, uid)
            with self.engine.begin() as db:
                # Durable per-recipient throttling; no private message bodies in audit.
                db.execute(update(self.ws.users).where(self.ws.users.c.id == uid).values(serial=self.ws.users.c.serial))
                count = db.scalar(select(func.count()).select_from(messages).where(messages.c.owner == uid,
                    messages.c.created > now()-60000))
                prior = db.scalar(select(messages.c.id).where(messages.c.event_key == uid+':'+str(body.eventId)))
                if count >= 10 and not prior: raise HTTPException(429, 'Notification rate limit reached')
                mid = self.enqueue(db, uid, body)
                self.ws.log(db, ctx, 'notification.queued', uid, {'notificationId': mid})
            return {'id': mid, 'state': 'queued', 'deliveryGuaranteed': False}

        @app.get('/admin/api/v2/farmers/{uid}/notifications')
        def diagnostics(uid: str, request: Request, tenant: str = ''):
            ctx = self.ws.authorize(self.ws.identity(request), tenant)
            self.ws.owner(ctx, uid)
            with self.engine.connect() as db:
                devices = [dict(r) for r in db.execute(select(registrations.c.device, registrations.c.permission,
                    registrations.c.version, registrations.c.updated, registrations.c.active, registrations.c.preferences).where(registrations.c.owner == uid)).mappings()]
                jobs = [dict(r) for r in db.execute(select(outbox, messages.c.opened, messages.c.read)
                    .join(messages, messages.c.id == outbox.c.message).where(outbox.c.owner == uid)
                    .order_by(outbox.c.next_at.desc()).limit(50)).mappings()]
            for device in devices: device['preferences'] = json.loads(device['preferences'])
            return {'devices': devices, 'deliveries': jobs,
                    'configured': bool(os.getenv('FARMER_FCM_PROJECT')), 'acceptedIsDelivered': False}

    def run_once(self, sender, limit=50):
        """CAS leases support multiple workers; retries are at-least-once (client deduplicates)."""
        at = now()
        with self.engine.connect() as db:
            ids = list(db.execute(select(outbox.c.id).where(outbox.c.state.in_(['pending','retry','sending']),
                outbox.c.next_at <= at).limit(limit)).scalars())
        for jid in ids:
            lease = str(uuid4())
            with self.engine.begin() as db:
                claimed = db.execute(update(outbox).where(outbox.c.id == jid,
                    outbox.c.state.in_(['pending','retry','sending']), outbox.c.next_at <= at)
                    .values(state='sending', lease=lease, next_at=at+120000))
                if not claimed.rowcount: continue
                job = db.execute(select(outbox).where(outbox.c.id == jid)).mappings().one()
                reg = db.execute(select(registrations).where(registrations.c.device == job['device'])).mappings().first()
                msg = db.execute(select(messages).where(messages.c.id == job['message'])).mappings().one()
            state, error, accepted, delay = 'suppressed', None, None, 0
            prefs = json.loads(reg['preferences']) if reg else {}
            if job['expires'] <= at: state = 'expired'
            elif reg and reg['active'] and reg['owner'] == job['owner'] and reg['token'] and \
                    reg['permission'] in ('authorized','provisional') and prefs.get(msg['category'],True):
                if quiet(prefs, at): state, delay = 'retry', 900000
                else:
                    state, error = sender(reg['token'], {'notificationId': msg['id'], 'schemaVersion': '1'},
                                          max(0, (job['expires']-at)//1000))
                    if state == 'accepted': accepted = now()
                    elif state == 'retry': delay = min(3600000, 30000 * 2**min(job['attempts'],7))
            with self.engine.begin() as db:
                db.execute(update(outbox).where(outbox.c.id == jid, outbox.c.lease == lease).values(
                    state=state, error=error, accepted=accepted, attempts=job['attempts']+1,
                    next_at=now()+delay, lease=None))
                if state == 'unregistered' and reg:
                    db.execute(update(registrations).where(registrations.c.device == reg['device'],
                        registrations.c.token_hash == reg['token_hash']).values(active=False, token=''))
        return len(ids)

def fcm_sender(token, data, ttl):
    """ADC belongs to the server. Generic lock-screen content protects shared phones."""
    import google.auth
    from google.auth.transport.requests import AuthorizedSession
    import requests
    project = os.environ['FARMER_FCM_PROJECT']
    credentials, _ = google.auth.default(scopes=['https://www.googleapis.com/auth/firebase.messaging'])
    try:
        with AuthorizedSession(credentials) as session:
            response = session.post(f'https://fcm.googleapis.com/v1/projects/{project}/messages:send',
                json={'message': {'token': token, 'notification': {'title': 'FarmerPlus',
                    'body': 'You have an update. Open FarmerPlus to view it.'}, 'data': data,
                    'android': {'priority':'normal','ttl':f'{ttl}s',
                        'notification': {'channel_id':'farmerplus_updates','tag': data['notificationId']}}}}, timeout=20)
        if response.status_code == 200: return 'accepted', None
        details = response.json().get('error',{}).get('details',[])
        if any(d.get('errorCode') == 'UNREGISTERED' for d in details): return 'unregistered','UNREGISTERED'
        if response.status_code == 429 or response.status_code >= 500: return 'retry',f'FCM_{response.status_code}'
        return 'failed',f'FCM_{response.status_code}'
    except (requests.RequestException, ValueError): return 'retry','FCM_TRANSPORT'

if __name__ == '__main__':
    if not os.getenv('FARMER_FCM_PROJECT'): raise SystemExit('FARMER_FCM_PROJECT is not configured')
    from app import app
    service = app.state.push
    while True:
        service.run_once(fcm_sender)
        time.sleep(5)
