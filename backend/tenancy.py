"""Tenant control plane and explicitly simulated, balanced wallet settlement.

No blockchain is called by this module. Monetary amounts are integer minor units;
rates are integer basis points. Existing Moodle balances are never guessed/copied.
"""
import hashlib
import json
import os
import re
import time
from pathlib import Path
from uuid import uuid4
from urllib.parse import urlsplit

from fastapi import Depends, HTTPException, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field, ConfigDict
from sqlalchemy import (MetaData, Table, Column, String, Integer, BigInteger,
                        Boolean, Text, UniqueConstraint, select, insert, update)
from sqlalchemy.schema import CreateTable

metadata = MetaData()
control = Table('fp_platform_control', metadata, Column('id', Integer, primary_key=True),
    Column('superadmin', String(36)), Column('revision', Integer, nullable=False))
tenants = Table('fp_tenants', metadata, Column('id', String(36), primary_key=True),
    Column('slug', String(60), unique=True, nullable=False), Column('name', String(120), nullable=False),
    Column('logo', Text, nullable=False), Column('platform_bps', Integer, nullable=False),
    Column('offline', Boolean, nullable=False), Column('active', Boolean, nullable=False),
    Column('revision', Integer, nullable=False), Column('created', BigInteger, nullable=False))
members = Table('fp_tenant_members', metadata,
    Column('tenant', String(36), primary_key=True), Column('owner', String(36), primary_key=True),
    Column('role', String(20), nullable=False), Column('active', Boolean, nullable=False),
    Column('commission_bps', Integer, nullable=False))
instances = Table('fp_learning_instances', metadata,
    Column('id', String(60), primary_key=True), Column('tenant', String(36), unique=True, nullable=False),
    Column('origin', String(255), unique=True, nullable=False), Column('enabled', Boolean, nullable=False))
courses = Table('fp_commerce_courses', metadata,
    Column('id', String(36), primary_key=True), Column('tenant', String(36), nullable=False),
    Column('instance', String(60), nullable=False), Column('courseid', Integer, nullable=False),
    Column('creator', String(36), nullable=False), Column('title', String(200), nullable=False),
    Column('price', BigInteger, nullable=False), Column('currency', String(3), nullable=False),
    Column('published', Boolean, nullable=False), Column('offline', Boolean, nullable=False),
    Column('revision', Integer, nullable=False),
    UniqueConstraint('instance', 'courseid'))
wallets = Table('fp_wallets', metadata, Column('id', String(160), primary_key=True),
    Column('balance', BigInteger, nullable=False))
transactions = Table('fp_wallet_transactions', metadata, Column('id', String(36), primary_key=True),
    Column('tenant', String(36), nullable=False), Column('actor', String(36), nullable=False),
    Column('key', String(160), unique=True, nullable=False), Column('fingerprint', String(64), nullable=False),
    Column('kind', String(20), nullable=False), Column('details', Text, nullable=False),
    Column('created', BigInteger, nullable=False))
entries = Table('fp_wallet_entries', metadata, Column('transaction', String(36), primary_key=True),
    Column('position', Integer, primary_key=True), Column('wallet', String(160), nullable=False),
    Column('amount', BigInteger, nullable=False), Column('description', String(100), nullable=False))
entitlements = Table('fp_paid_entitlements', metadata,
    Column('owner', String(36), primary_key=True), Column('course', String(36), primary_key=True),
    Column('transaction', String(36), nullable=False), Column('active', Boolean, nullable=False),
    Column('learning_status', String(30), nullable=False))
audit = Table('fp_tenant_audit', metadata, Column('id', String(36), primary_key=True),
    Column('actor', String(36), nullable=False), Column('tenant', String(36), nullable=False),
    Column('action', String(40), nullable=False), Column('details', Text, nullable=False),
    Column('created', BigInteger, nullable=False))


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'))


def split_payment(price, commission_bps, platform_bps):
    if any(type(v) is not int for v in (price, commission_bps, platform_bps)):
        raise ValueError('Integer minor units and basis points required')
    if not 0 <= price <= 10**12 or not all(0 <= v <= 10000 for v in (commission_bps, platform_bps)):
        raise ValueError('Price or percentage outside supported range')
    commission = (price * commission_bps + 5000) // 10000
    platform = (commission * platform_bps + 5000) // 10000
    return dict(price=price, creator=price-commission, commission=commission,
                platform=platform, tenant=commission-platform)


class Input(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)


class TenantInput(Input):
    name: str = Field(min_length=1, max_length=120)
    slug: str = Field(pattern=r'^[a-z][a-z0-9-]{1,59}$')
    logo: str = Field(default='', max_length=255)
    platform_bps: int = Field(ge=0, le=10000)
    offline: bool = False
    active: bool = True


class MemberInput(Input):
    owner: str = Field(min_length=1, max_length=36)
    role: str = Field(pattern=r'^(admin|creator|student)$')
    commission_bps: int = Field(default=2000, ge=0, le=10000)
    active: bool = True


class CourseInput(Input):
    instance: str = Field(min_length=1, max_length=60)
    courseid: int = Field(gt=0)
    creator: str = Field(min_length=1, max_length=36)
    title: str = Field(min_length=1, max_length=200)
    price: int = Field(ge=0, le=10**12)
    currency: str = Field(pattern=r'^(ZAR|USD|EUR|GBP)$')
    published: bool = False
    offline: bool = True


class PurchaseInput(Input):
    course: str = Field(min_length=1, max_length=36)
    key: str = Field(pattern=r'^[a-zA-Z0-9_-]{8,80}$')
    revision: int = Field(gt=0)


class FundInput(Input):
    owner: str = Field(min_length=1, max_length=36)
    currency: str = Field(pattern=r'^(ZAR|USD|EUR|GBP)$')
    amount: int = Field(gt=0, le=10**10)
    key: str = Field(pattern=r'^[a-zA-Z0-9_-]{8,80}$')


class CoursePolicyInput(Input):
    revision: int = Field(gt=0)
    price: int = Field(ge=0, le=10**12)
    published: bool
    offline: bool


def valid_logo(path):
    return not path or (bool(re.fullmatch(r'/static/[a-zA-Z0-9_/-]+\.(png|jpg|webp|svg)', path))
                        and '//' not in path)


class Tenancy:
    def __init__(self, app, users, identity, admin, testing=False):
        self.app, self.engine, self.users = app, app.state.engine, users
        self.test_wallet = testing or os.getenv('FARMER_WALLET_MODE') == 'test'
        # Additive, separately versioned tables; never alter the identity migration checksum.
        with self.engine.begin() as db:
            if db.dialect.name == 'postgresql':
                from sqlalchemy import text
                db.execute(text('SELECT pg_advisory_xact_lock(748521934)'))
            migration_meta = MetaData()
            journal = Table('fp_tenant_migrations', migration_meta,
                Column('version', String(64), primary_key=True), Column('checksum', String(64), nullable=False))
            migration_meta.create_all(db)
            version = '20260914_01_tenant_test_ledger'
            checksum = hashlib.sha256('\n'.join(str(CreateTable(t).compile(dialect=db.dialect))
                for t in metadata.sorted_tables).encode()).hexdigest()
            prior = db.execute(select(journal).where(journal.c.version == version)).mappings().first()
            if prior and prior['checksum'] != checksum:
                raise RuntimeError('Tenant schema drift: a new migration is required')
            if not prior:
                metadata.create_all(db)
                db.execute(insert(journal).values(version=version, checksum=checksum))
            if not db.execute(select(control).where(control.c.id == 1)).first():
                db.execute(insert(control).values(id=1, superadmin=None, revision=0))
            if not db.execute(select(tenants).where(tenants.c.id == 'farmerplus')).first():
                db.execute(insert(tenants).values(id='farmerplus', slug='farmerplus', name='FarmerPlus',
                    logo='', platform_bps=0, offline=True, active=True, revision=1, created=int(time.time())))
                # Existing accounts belong to the pre-existing FarmerPlus tenant only.
                for user in db.execute(select(users.c.id, users.c.admin)).mappings():
                    staff_role = app.state.operations.role(db, user)
                    db.execute(insert(members).values(tenant='farmerplus', owner=user['id'],
                        role='admin' if staff_role == 'admin' else 'student', active=True, commission_bps=2000))
        self.mount(identity, admin)

    def lock(self, db):
        # Serialises balance/policy mutations, including SQLite test mode.
        db.execute(update(control).where(control.c.id == 1).values(revision=control.c.revision+1))

    def is_super(self, db, owner):
        return db.scalar(select(control.c.superadmin).where(control.c.id == 1)) == owner

    def check(self, db, user, tenant, roles=None):
        row = db.execute(select(tenants).where(tenants.c.id == tenant)).mappings().first()
        if not row:
            raise HTTPException(404, 'Tenant not found')
        if self.is_super(db, user['id']):
            return dict(row)
        member = db.execute(select(members).where(members.c.tenant == tenant,
            members.c.owner == user['id'], members.c.active.is_(True))).mappings().first()
        if not row['active'] or not member or (roles and member['role'] not in roles):
            raise HTTPException(403, 'Access to this tenant is not permitted')
        return dict(row)

    def log(self, db, actor, tenant, action, details):
        db.execute(insert(audit).values(id=str(uuid4()), actor=actor, tenant=tenant, action=action,
            details=canonical(details), created=int(time.time())))

    def register_farmerplus(self, db, owner):
        if not db.execute(select(members).where(members.c.tenant == 'farmerplus', members.c.owner == owner)).first():
            db.execute(insert(members).values(tenant='farmerplus', owner=owner, role='student',
                active=True, commission_bps=2000))

    def context(self, user, tenant=None):
        with self.engine.connect() as db:
            if tenant is None:
                allowed = db.execute(select(members.c.tenant).join(tenants, tenants.c.id == members.c.tenant)
                    .where(members.c.owner == user['id'], members.c.active.is_(True), tenants.c.active.is_(True))).scalars().all()
                if len(allowed) != 1:
                    raise HTTPException(409, 'Select an authorised tenant')
                tenant = allowed[0]
            return self.check(db, user, tenant)

    def learning_instance(self, tenant):
        with self.engine.connect() as db:
            row = db.execute(select(instances).where(instances.c.tenant == tenant, instances.c.enabled.is_(True))).mappings().first()
        if row:
            return dict(row)
        if tenant == 'farmerplus':
            origin = os.getenv('FARMER_LEARNING_ORIGIN', '')
            if origin:
                return {'id': 'farmerplus-learning', 'tenant': tenant, 'origin': origin, 'enabled': True}
        raise HTTPException(503, 'This tenant has no verified Learning instance configured')

    def configure_instance(self, tenant, instance_id, origin):
        # Operator-only API, deliberately not exposed as an arbitrary URL admin form (SSRF boundary).
        u = urlsplit(origin)
        if u.scheme != 'https' or not u.hostname or u.username or u.password or u.query or u.fragment or u.path or u.port:
            raise ValueError('Exact HTTPS origin required')
        with self.engine.begin() as db:
            self.lock(db)
            if not db.execute(select(tenants).where(tenants.c.id == tenant)).first():
                raise ValueError('Unknown tenant')
            db.execute(insert(instances).values(id=instance_id, tenant=tenant, origin=origin, enabled=True))

    def wallet(self, db, wallet):
        value = db.scalar(select(wallets.c.balance).where(wallets.c.id == wallet))
        if value is None:
            db.execute(insert(wallets).values(id=wallet, balance=0))
            return 0
        return value

    def post(self, db, tenant, actor, key, kind, details, movements):
        fingerprint = hashlib.sha256(canonical({'tenant': tenant, 'kind': kind, 'details': details}).encode()).hexdigest()
        old = db.execute(select(transactions).where(transactions.c.key == key)).mappings().first()
        if old:
            if old['fingerprint'] != fingerprint:
                raise HTTPException(409, 'Payment reference already used for different instructions')
            return json.loads(old['details']) | {'id': old['id'], 'mode': 'test', 'replayed': True}
        if sum(v for _, v, _ in movements) != 0:
            raise ValueError('Unbalanced settlement')
        if not self.test_wallet:
            raise HTTPException(503, 'Wallet provider is not configured; no funds moved')
        txid = str(uuid4())
        # Check net effects; the gross-commission credit and platform deduction stay linked.
        totals = {}
        for wallet, amount, _ in movements:
            totals[wallet] = totals.get(wallet, 0) + amount
        for wallet, amount in totals.items():
            balance = self.wallet(db, wallet)
            if balance + amount < 0 and not wallet.startswith('test-funding:'):
                raise HTTPException(409, 'Insufficient available balance; no funds moved')
        db.execute(insert(transactions).values(id=txid, tenant=tenant, actor=actor, key=key,
            fingerprint=fingerprint, kind=kind, details=canonical(details), created=int(time.time())))
        for i, (wallet, amount, label) in enumerate(movements):
            db.execute(insert(entries).values(transaction=txid, position=i, wallet=wallet, amount=amount, description=label))
        for wallet, amount in totals.items():
            db.execute(update(wallets).where(wallets.c.id == wallet).values(balance=wallets.c.balance+amount))
        return details | {'id': txid, 'mode': 'test', 'replayed': False}

    def mount(self, identity, admin):
        app = self.app

        def superuser(user=Depends(admin)):
            with self.engine.connect() as db:
                if not self.is_super(db, user['id']):
                    raise HTTPException(403, 'Platform Superadmin access required')
            return user

        @app.post('/admin/api/platform/bootstrap')
        def bootstrap(user=Depends(admin)):
            with self.engine.begin() as db:
                self.lock(db)
                owner = db.scalar(select(control.c.superadmin).where(control.c.id == 1))
                if owner and owner != user['id']:
                    raise HTTPException(409, 'A platform Superadmin already exists')
                db.execute(update(control).where(control.c.id == 1).values(superadmin=user['id']))
                self.log(db, user['id'], 'farmerplus', 'superadmin_bootstrap', {})
            return {'configured': True}

        @app.get('/tenants')
        def own_tenants(user=Depends(identity)):
            with self.engine.connect() as db:
                root = self.is_super(db, user['id'])
                query = select(tenants) if root else select(tenants).join(members, members.c.tenant == tenants.c.id).where(
                    members.c.owner == user['id'], members.c.active.is_(True), tenants.c.active.is_(True))
                result = [dict(r) for r in db.execute(query.order_by(tenants.c.name)).mappings()]
                configured = bool(db.scalar(select(control.c.superadmin).where(control.c.id == 1)))
            return {'tenants': result, 'superadmin': root, 'bootstrapAvailable': bool(user['admin']) and not configured,
                    'walletMode': 'test' if self.test_wallet else 'unconfigured'}

        @app.post('/admin/api/tenants')
        def create(body: TenantInput, user=Depends(superuser)):
            with self.engine.begin() as db:
                self.lock(db)
                if db.execute(select(tenants.c.id).where(tenants.c.slug == body.slug)).first():
                    raise HTTPException(409, 'Tenant name in URL already exists')
                tid = str(uuid4())
                values = body.model_dump()
                if not valid_logo(values['logo']):
                    raise HTTPException(422, 'Use an approved local logo asset')
                db.execute(insert(tenants).values(id=tid, **values, revision=1, created=int(time.time())))
                self.log(db, user['id'], tid, 'tenant_created', values)
                return {'id': tid}

        @app.put('/admin/api/tenants/{tenant}')
        def edit(tenant: str, body: TenantInput, user=Depends(superuser)):
            with self.engine.begin() as db:
                self.lock(db)
                self.check(db, user, tenant)
                if db.execute(select(tenants.c.id).where(tenants.c.slug == body.slug, tenants.c.id != tenant)).first():
                    raise HTTPException(409, 'Tenant name in URL already exists')
                if not valid_logo(body.logo):
                    raise HTTPException(422, 'Use an approved local logo asset')
                db.execute(update(tenants).where(tenants.c.id == tenant).values(**body.model_dump(), revision=tenants.c.revision+1))
                self.log(db, user['id'], tenant, 'tenant_updated', body.model_dump())
            return {'saved': True}

        @app.get('/tenants/{tenant}/members')
        def list_members(tenant: str, user=Depends(identity)):
            with self.engine.connect() as db:
                self.check(db, user, tenant, {'admin'})
                rows = db.execute(select(members, self.users.c.username).join(self.users, self.users.c.id == members.c.owner).where(members.c.tenant == tenant)).mappings()
                return {'members': [dict(r) for r in rows]}

        @app.put('/tenants/{tenant}/members')
        def put_member(tenant: str, body: MemberInput, user=Depends(identity)):
            with self.engine.begin() as db:
                self.lock(db)
                self.check(db, user, tenant, {'admin'})
                if not db.execute(select(self.users.c.id).where(self.users.c.id == body.owner)).first():
                    raise HTTPException(404, 'Verified account not found')
                if body.role == 'admin' and not self.is_super(db, user['id']):
                    raise HTTPException(403, 'Only Superadmin assigns tenant administrators')
                old = db.execute(select(members).where(members.c.tenant == tenant, members.c.owner == body.owner)).mappings().first()
                if old and old['role'] == 'admin' and not self.is_super(db, user['id']):
                    raise HTTPException(403, 'Only Superadmin changes tenant administrators')
                values = body.model_dump()
                if old:
                    db.execute(update(members).where(members.c.tenant == tenant, members.c.owner == body.owner).values(**values))
                else:
                    # Adding an existing account across organisations is a platform operation,
                    # not account discovery via name/email or an unverified tenant invitation.
                    if not self.is_super(db, user['id']):
                        raise HTTPException(403, 'Superadmin must approve a new tenant membership')
                    db.execute(insert(members).values(tenant=tenant, **values))
                self.log(db, user['id'], tenant, 'member_updated', values)
            return {'saved': True}

        @app.get('/tenants/{tenant}/courses')
        def catalogue(tenant: str, user=Depends(identity)):
            with self.engine.connect() as db:
                self.check(db, user, tenant)
                rows = db.execute(select(courses).where(courses.c.tenant == tenant, courses.c.published.is_(True))).mappings()
                return {'courses': [dict(r) for r in rows]}

        @app.get('/tenants/{tenant}/managed-courses')
        def managed_courses(tenant: str, user=Depends(identity)):
            with self.engine.connect() as db:
                self.check(db, user, tenant, {'admin', 'creator'})
                query = select(courses).where(courses.c.tenant == tenant)
                role = db.scalar(select(members.c.role).where(members.c.tenant == tenant, members.c.owner == user['id']))
                if role == 'creator' and not self.is_super(db, user['id']):
                    query = query.where(courses.c.creator == user['id'])
                return {'courses': [dict(r) for r in db.execute(query).mappings()]}

        @app.put('/tenants/{tenant}/courses/{course_id}')
        def course_policy(tenant: str, course_id: str, body: CoursePolicyInput, user=Depends(identity)):
            with self.engine.begin() as db:
                self.lock(db)
                self.check(db, user, tenant, {'admin', 'creator'})
                row = db.execute(select(courses).where(courses.c.id == course_id, courses.c.tenant == tenant)).mappings().first()
                if not row: raise HTTPException(404, 'Course not found')
                role = db.scalar(select(members.c.role).where(members.c.tenant == tenant, members.c.owner == user['id']))
                if role == 'creator' and row['creator'] != user['id'] and not self.is_super(db, user['id']):
                    raise HTTPException(403, 'Creators can only change their own courses')
                if body.revision != row['revision']: raise HTTPException(409, 'Course changed; reload before saving')
                db.execute(update(courses).where(courses.c.id == course_id).values(price=body.price,
                    published=body.published, offline=body.offline, revision=row['revision']+1))
                # Unpublishing stops new purchases, not previously acquired access.
                self.log(db, user['id'], tenant, 'course_policy_changed', {'course': course_id, **body.model_dump()})
                return {'saved': True, 'revision': row['revision']+1}

        @app.post('/tenants/{tenant}/courses')
        def register_course(tenant: str, body: CourseInput, user=Depends(identity)):
            with self.engine.begin() as db:
                self.lock(db)
                self.check(db, user, tenant, {'admin', 'creator'})
                creator = db.execute(select(members).where(members.c.tenant == tenant, members.c.owner == body.creator,
                    members.c.active.is_(True), members.c.role == 'creator')).mappings().first()
                if not creator:
                    raise HTTPException(422, 'An active tenant creator is required')
                actor = db.execute(select(members.c.role).where(members.c.tenant == tenant, members.c.owner == user['id'])).scalar()
                if not self.is_super(db, user['id']) and actor == 'creator' and body.creator != user['id']:
                    raise HTTPException(403, 'A creator may only price their own course')
                registered = self.learning_instance(tenant)
                if body.instance != registered['id']:
                    raise HTTPException(422, 'Course must use this tenant’s registered Learning instance')
                if db.execute(select(courses.c.id).where(courses.c.instance == body.instance, courses.c.courseid == body.courseid)).first():
                    raise HTTPException(409, 'Course already registered')
                cid = str(uuid4())
                db.execute(insert(courses).values(id=cid, tenant=tenant, **body.model_dump(), revision=1))
                self.log(db, user['id'], tenant, 'course_registered', {'id': cid, **body.model_dump()})
                return {'id': cid}

        @app.get('/wallets')
        def balances(user=Depends(identity)):
            with self.engine.connect() as db:
                prefix = f'person:{user["id"]}:'
                rows = db.execute(select(wallets).where(wallets.c.id.startswith(prefix))).mappings()
                return {'mode': 'test' if self.test_wallet else 'unconfigured', 'wallets': [dict(r) for r in rows]}

        @app.get('/tenants/{tenant}/finance')
        def finance(tenant: str, user=Depends(identity)):
            with self.engine.connect() as db:
                self.check(db, user, tenant, {'admin'})
                rows = [dict(r) for r in db.execute(select(wallets).where(wallets.c.id.startswith(f'tenant:{tenant}:'))).mappings()]
                if self.is_super(db, user['id']):
                    rows += [dict(r) for r in db.execute(select(wallets).where(wallets.c.id.startswith('platform:'))).mappings()]
                txs = [dict(r) for r in db.execute(select(transactions).where(transactions.c.tenant == tenant).order_by(transactions.c.created.desc()).limit(100)).mappings()]
                for tx in txs:
                    tx['details'] = json.loads(tx['details'])
                    tx['entries'] = [dict(r) for r in db.execute(select(entries).where(entries.c.transaction == tx['id']).order_by(entries.c.position)).mappings()]
                return {'mode': 'test' if self.test_wallet else 'unconfigured', 'wallets': rows, 'transactions': txs}

        @app.post('/tenants/{tenant}/test-funding')
        def fund(tenant: str, body: FundInput, user=Depends(superuser)):
            with self.engine.begin() as db:
                self.lock(db)
                self.check(db, user, tenant)
                if not db.execute(select(members).where(members.c.tenant == tenant, members.c.owner == body.owner, members.c.active.is_(True))).first():
                    raise HTTPException(422, 'Funding requires an active tenant member')
                return self.post(db, tenant, user['id'], f'fund:{user["id"]}:{body.key}', 'funding', body.model_dump(), [
                    (f'test-funding:{body.currency}', -body.amount, 'Synthetic funding source'),
                    (f'person:{body.owner}:{body.currency}', body.amount, 'Test funds added')])

        @app.post('/tenants/{tenant}/purchase')
        def purchase(tenant: str, body: PurchaseInput, user=Depends(identity)):
            with self.engine.begin() as db:
                self.lock(db)
                policy = self.check(db, user, tenant)
                key = f'purchase:{user["id"]}:{body.key}'
                previous = db.execute(select(transactions).where(transactions.c.key == key)).mappings().first()
                if previous:
                    details = json.loads(previous['details'])
                    if previous['tenant'] != tenant or details['course'] != body.course or details['course_revision'] != body.revision:
                        raise HTTPException(409, 'Payment reference used for another purchase')
                    return details | {'id': previous['id'], 'mode': 'test', 'replayed': True}
                course = db.execute(select(courses).where(courses.c.id == body.course, courses.c.tenant == tenant,
                    courses.c.published.is_(True))).mappings().first()
                if not course or not policy['active']:
                    raise HTTPException(404, 'Course is not available for purchase')
                if course['revision'] != body.revision:
                    raise HTTPException(409, 'Course price changed; review the current price')
                creator = db.execute(select(members).where(members.c.tenant == tenant, members.c.owner == course['creator'],
                    members.c.active.is_(True), members.c.role == 'creator')).mappings().first()
                if not creator:
                    raise HTTPException(409, 'Creator is not available for settlement')
                own = db.execute(select(entitlements).where(entitlements.c.owner == user['id'], entitlements.c.course == body.course)).mappings().first()
                if own and own['active']:
                    return {'id': own['transaction'], 'alreadyPurchased': True, 'charged': 0, 'learningStatus': own['learning_status']}
                amounts = split_payment(course['price'], creator['commission_bps'], policy['platform_bps'])
                currency = course['currency']
                details = amounts | {'course': body.course, 'course_revision': body.revision, 'creator_owner': course['creator'],
                    'currency': currency, 'commission_bps': creator['commission_bps'], 'platform_bps': policy['platform_bps'],
                    'policy_revision': policy['revision'], 'learningStatus': 'pending_enrolment'}
                movements = [(f'person:{user["id"]}:{currency}', -amounts['price'], 'Course purchase'),
                    (f'person:{course["creator"]}:{currency}', amounts['creator'], 'Creator earnings'),
                    (f'tenant:{tenant}:{currency}', amounts['commission'], 'Gross tenant commission'),
                    (f'tenant:{tenant}:{currency}', -amounts['platform'], 'Platform share deducted'),
                    (f'platform:{currency}', amounts['platform'], 'Platform share received')]
                result = self.post(db, tenant, user['id'], key, 'purchase', details, movements)
                values = dict(transaction=result['id'], active=True, learning_status='pending_enrolment')
                if own:
                    db.execute(update(entitlements).where(entitlements.c.owner == user['id'], entitlements.c.course == body.course).values(**values))
                else:
                    db.execute(insert(entitlements).values(owner=user['id'], course=body.course, **values))
                return result

        @app.post('/tenants/{tenant}/refund/{transaction}')
        def refund(tenant: str, transaction: str, user=Depends(identity)):
            with self.engine.begin() as db:
                self.lock(db)
                self.check(db, user, tenant, {'admin'})
                old = db.execute(select(transactions).where(transactions.c.id == transaction,
                    transactions.c.tenant == tenant, transactions.c.kind == 'purchase')).mappings().first()
                if not old:
                    raise HTTPException(404, 'Purchase not found')
                original = json.loads(old['details'])
                movement = [(r['wallet'], -r['amount'], 'Refund: '+r['description']) for r in db.execute(
                    select(entries).where(entries.c.transaction == transaction).order_by(entries.c.position)).mappings()]
                result = self.post(db, tenant, user['id'], 'refund:'+transaction, 'refund', {'original': transaction, 'amounts': original}, movement)
                db.execute(update(entitlements).where(entitlements.c.owner == old['actor'], entitlements.c.course == original['course'],
                    entitlements.c.transaction == transaction).values(active=False, learning_status='refund_review'))
                return result

        @app.get('/admin/tenants')
        def administration(user=Depends(identity)):
            with self.engine.connect() as db:
                role = db.execute(select(members.c.role).where(members.c.owner == user['id'], members.c.role == 'admin', members.c.active.is_(True))).first()
                if not role and not user['admin'] and not self.is_super(db, user['id']):
                    raise HTTPException(403, 'Tenant administration access required')
            return FileResponse(Path(__file__).parent/'static'/'tenants.html')
