"""Owner-scoped sharing consent and cooperative membership. No payment or external send."""
import hashlib
import json
import time
from uuid import UUID, uuid4
from typing import Literal
from fastapi import HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import MetaData, Table, Column, String, Text, Boolean, BigInteger, Integer, select, insert, update
from schema_migrations import apply_additive_schema

POLICY = '20260916-sharing-v1'
CATEGORIES = {'government', 'finance', 'insurance', 'cooperatives', 'inputs'}
DEMO_CODE = 'farmerplus:coop:v1:demo-avocado-tarlton'
meta = MetaData()
preferences = Table('sharing_preferences', meta, Column('owner', String(36), primary_key=True),
    Column('category', String(24), primary_key=True), Column('enabled', Boolean, nullable=False),
    Column('updated', BigInteger, nullable=False), Column('policy', String(64), nullable=False))
events = Table('community_events', meta, Column('owner', String(36), primary_key=True),
    Column('id', String(36), primary_key=True), Column('fingerprint', String(64), nullable=False),
    Column('action', String(32), nullable=False), Column('target', String(128), nullable=False),
    Column('at', BigInteger, nullable=False), Column('policy', String(64), nullable=False),
    Column('result', Text, nullable=False))
recipients = Table('sharing_recipients', meta, Column('id', String(64), primary_key=True),
    Column('name', String(200), nullable=False), Column('category', String(24), nullable=False),
    Column('purpose', Text, nullable=False), Column('fields', Text, nullable=False),
    Column('policy', String(64), nullable=False), Column('enabled', Boolean, nullable=False))
grants = Table('sharing_grants', meta, Column('owner', String(36), primary_key=True),
    Column('recipient', String(64), primary_key=True), Column('enabled', Boolean, nullable=False),
    Column('policy', String(64), nullable=False), Column('updated', BigInteger, nullable=False))
coops = Table('cooperatives', meta, Column('id', String(64), primary_key=True),
    Column('code', String(200), unique=True, nullable=False), Column('name', String(200), nullable=False),
    Column('currency', String(3), nullable=False), Column('annual_minor', Integer, nullable=False),
    Column('terms', Text, nullable=False), Column('revision', Integer, nullable=False),
    Column('demo', Boolean, nullable=False), Column('active', Boolean, nullable=False))
memberships = Table('cooperative_memberships', meta, Column('owner', String(36), primary_key=True),
    Column('coop', String(64), primary_key=True), Column('status', String(24), nullable=False),
    Column('payment_status', String(24), nullable=False), Column('updated', BigInteger, nullable=False),
    Column('terms_revision', Integer, nullable=False))
installation_meta = MetaData()
installations = Table('cooperative_installations', installation_meta,
    Column('owner', String(36), primary_key=True), Column('generation', String(36), nullable=False),
    Column('enabled', Boolean, nullable=False), Column('updated', BigInteger, nullable=False))

class Input(BaseModel):
    model_config = ConfigDict(extra='forbid')
class Choice(Input):
    eventId: UUID
    enabled: bool
    policy: str = Field(max_length=64)
    installation: UUID | None = None
class InstallationChoice(Choice):
    installation: UUID
class MemberChoice(Input):
    eventId: UUID
    action: Literal['join', 'leave']
    termsRevision: int = Field(ge=1)
    confirmed: bool

def stamp(): return int(time.time()*1000)
def encode(value): return json.dumps(value,sort_keys=True,separators=(',',':'),default=str)

class Community:
    def __init__(self, ws):
        self.ws,self.engine=ws,ws.engine
        apply_additive_schema(self.engine,meta,'20260916_06_community','Sharing choices, named consent and cooperative memberships')
        apply_additive_schema(self.engine,installation_meta,'20260916_07_coop_installation','Coop installation and revocable sharing')
        with self.engine.begin() as db:
            # Serialize the one explicitly fictional demonstration entry during API/worker startup.
            if db.dialect.name=='postgresql':
                from sqlalchemy import text
                db.execute(text('SELECT pg_advisory_xact_lock(748521933)'))
            if not db.scalar(select(coops.c.id).where(coops.c.id=='demo-avocado-tarlton')):
                db.execute(insert(coops).values(id='demo-avocado-tarlton',code=DEMO_CODE,
                    name='Avocado Cooperative of Tarlton',currency='USD',annual_minor=100,
                    terms='Demonstration only. No real cooperative membership, payment, renewal or external data sharing is created.',
                    revision=1,demo=True,active=True))
            if not db.scalar(select(recipients.c.id).where(recipients.c.id=='coop:demo-avocado-tarlton')):
                db.execute(insert(recipients).values(id='coop:demo-avocado-tarlton',
                    name='Avocado Cooperative of Tarlton',category='cooperatives',
                    purpose='Demonstrate cooperative membership within FarmerPlus. No data is sent to a real cooperative.',
                    fields=encode(['name','country','productionCategory']),policy=POLICY,enabled=True))
        self.mount()

    def owner(self, request):
        user=self.ws.app.state.oidc.resource_identity(request)
        if user['admin']: raise HTTPException(403,'Farmer account required')
        return user['id']

    def transaction(self, owner, body, action, target, perform):
        key=str(body.eventId);fingerprint=hashlib.sha256(encode({'action':action,'target':target,'body':body.model_dump(exclude_none=True)}).encode()).hexdigest()
        with self.engine.begin() as db:
            db.execute(update(self.ws.users).where(self.ws.users.c.id==owner).values(serial=self.ws.users.c.serial))
            previous=db.execute(select(events).where(events.c.owner==owner,events.c.id==key)).mappings().first()
            if previous:
                if previous['fingerprint']!=fingerprint:raise HTTPException(409,'Request identifier already used')
                return json.loads(previous['result'])
            result=perform(db)
            db.execute(insert(events).values(owner=owner,id=key,fingerprint=fingerprint,action=action,target=target,
                at=stamp(),policy=POLICY,result=encode(result)))
            return result

    def effective_policy(self, db, row):
        if row['category'] != 'cooperatives': return row['policy']
        coop=db.execute(select(coops).where(coops.c.id==row['id'].removeprefix('coop:'))).mappings().first()
        return hashlib.sha256(encode({'recipient':dict(row),'cooperative':dict(coop) if coop else None}).encode()).hexdigest()

    def recipient_view(self, db, owner, row):
        item=dict(row);item['fields']=json.loads(item['fields']);item['policy']=self.effective_policy(db,row)
        coop=db.execute(select(coops).where(coops.c.id==row['id'].removeprefix('coop:'))).mappings().first() if row['category']=='cooperatives' else None
        item['demo']=bool(coop and coop['demo'])
        try:self.allowed(db,owner,row['id']);item['approved']=True
        except HTTPException:item['approved']=False
        return item

    def allowed(self, db, owner, rid):
        """Fail-closed gateway: every new third-party disclosure must pass this check."""
        r=db.execute(select(recipients).where(recipients.c.id==rid,recipients.c.enabled.is_(True))).mappings().first()
        if not r:raise HTTPException(403,'Recipient is not configured for sharing')
        choice=db.scalar(select(preferences.c.enabled).where(preferences.c.owner==owner,preferences.c.category==r['category']))
        g=db.execute(select(grants).where(grants.c.owner==owner,grants.c.recipient==rid)).mappings().first()
        if r['category']=='cooperatives' and not db.scalar(select(installations.c.enabled).where(installations.c.owner==owner)):
            raise HTTPException(403,'Install Coop before sharing')
        if not choice or not g or not g['enabled'] or g['policy']!=self.effective_policy(db,r):
            raise HTTPException(403,'Current category and named-recipient consent required')
        return r

    def mount(self):
        app=self.ws.app
        @app.get('/sharing/preferences')
        def read_choices(request:Request):
            owner=self.owner(request)
            with self.engine.connect() as db:
                values={c:False for c in CATEGORIES}
                values.update({r['category']:r['enabled'] for r in db.execute(select(preferences).where(preferences.c.owner==owner)).mappings()})
            return {'choices':values,'policy':POLICY}

        @app.put('/coops/installation')
        def installation(body:InstallationChoice,request:Request):
            owner=self.owner(request)
            if body.policy!=POLICY:raise HTTPException(409,'Review the current sharing explanation')
            def save(db):
                condition=installations.c.owner==owner
                old=db.execute(select(installations).where(condition)).mappings().first()
                generation=str(body.installation)
                if not old or old['generation']!=generation or not body.enabled:
                    ids=select(recipients.c.id).where(recipients.c.category=='cooperatives')
                    db.execute(update(grants).where(grants.c.owner==owner,grants.c.recipient.in_(ids)).values(enabled=False,updated=stamp()))
                values=dict(generation=generation,enabled=body.enabled,updated=stamp())
                if old:db.execute(update(installations).where(condition).values(**values))
                else:db.execute(insert(installations).values(owner=owner,**values))
                condition=(preferences.c.owner==owner)&(preferences.c.category=='cooperatives')
                values=dict(enabled=body.enabled,updated=stamp(),policy=POLICY)
                if db.scalar(select(preferences.c.owner).where(condition)):db.execute(update(preferences).where(condition).values(**values))
                else:db.execute(insert(preferences).values(owner=owner,category='cooperatives',**values))
                return {'saved':True,'owner':owner,'enabled':body.enabled,'installation':generation}
            return self.transaction(owner,body,'coop.installation','coop',save)

        @app.put('/sharing/preferences/{category}')
        def save_choice(category:str,body:Choice,request:Request):
            owner=self.owner(request)
            if category not in CATEGORIES:raise HTTPException(404,'Unknown sharing category')
            if category=='cooperatives':raise HTTPException(409,'Cooperative sharing is managed by installing or removing Coop')
            if body.policy!=POLICY:raise HTTPException(409,'Review the current sharing explanation')
            def save(db):
                condition=(preferences.c.owner==owner)&(preferences.c.category==category)
                values=dict(enabled=body.enabled,updated=stamp(),policy=POLICY)
                if db.scalar(select(preferences.c.owner).where(condition)):db.execute(update(preferences).where(condition).values(**values))
                else:db.execute(insert(preferences).values(owner=owner,category=category,**values))
                if not body.enabled:
                    ids=select(recipients.c.id).where(recipients.c.category==category)
                    db.execute(update(grants).where(grants.c.owner==owner,grants.c.recipient.in_(ids)).values(enabled=False,updated=stamp()))
                return {'saved':True,'enabled':body.enabled,'owner':owner}
            return self.transaction(owner,body,'sharing.choice',category,save)

        @app.get('/sharing/recipients')
        def named_recipients(request:Request):
            owner=self.owner(request)
            with self.engine.connect() as db:
                result=[]
                for row in db.execute(select(recipients).where(recipients.c.enabled.is_(True))).mappings():
                    result.append(self.recipient_view(db,owner,row))
            return {'items':result}

        @app.put('/sharing/recipients/{rid}/consent')
        def recipient_consent(rid:str,body:Choice,request:Request):
            owner=self.owner(request)
            def save(db):
                row=db.execute(select(recipients).where(recipients.c.id==rid,recipients.c.enabled.is_(True))).mappings().first()
                if not row:raise HTTPException(404,'Recipient unavailable')
                policy=self.effective_policy(db,row)
                if body.enabled and body.policy!=policy:raise HTTPException(409,'Recipient terms changed; review again')
                if body.enabled and row['category']=='cooperatives':
                    installed=db.execute(select(installations).where(installations.c.owner==owner)).mappings().first()
                    if not installed or not installed['enabled'] or installed['generation']!=str(body.installation):
                        raise HTTPException(409,'Coop installation changed; reopen Coop and review sharing')
                enabled=db.scalar(select(preferences.c.enabled).where(preferences.c.owner==owner,preferences.c.category==row['category']))
                if body.enabled and not enabled:raise HTTPException(409,'Enable this category before approving the recipient')
                condition=(grants.c.owner==owner)&(grants.c.recipient==rid)
                values=dict(enabled=body.enabled,policy=policy,updated=stamp())
                if db.scalar(select(grants.c.owner).where(condition)):db.execute(update(grants).where(condition).values(**values))
                else:db.execute(insert(grants).values(owner=owner,recipient=rid,**values))
                return {'saved':True,'owner':owner}
            return self.transaction(owner,body,'sharing.recipient',rid,save)

        @app.get('/sharing/recipients/{rid}/export')
        def export(rid:str,request:Request):
            # Explicit allowlist: technical phone identifiers, financial records and media never leak.
            owner=self.owner(request)
            with self.engine.connect() as db:
                recipient=self.allowed(db,owner,rid)
                fields=set(json.loads(recipient['fields']))
                if not fields or not fields.issubset({'name','country','productionCategory'}):
                    raise HTTPException(403,'Recipient data scope is not supported')
                record=db.execute(select(self.ws.records.c.data).where(self.ws.records.c.owner==owner,
                    self.ws.records.c.kind=='profile',self.ws.records.c.deleted.is_(False))).scalar()
                profile=json.loads(record) if record else {}
                profile['productionCategory']=profile.get('primaryActivity',profile.get('productionCategory'))
                return {'recipient':recipient['name'],'purpose':recipient['purpose'],
                    'data':{k:profile[k] for k in sorted(fields) if k in profile},'transmitted':False}

        @app.get('/coops/resolve')
        def resolve(request:Request,code:str=''):
            owner=self.owner(request)
            if len(code)>200 or not code.startswith('farmerplus:coop:v1:'):raise HTTPException(400,'Not a FarmerPlus cooperative QR code')
            with self.engine.connect() as db:
                row=db.execute(select(coops).where(coops.c.code==code,coops.c.active.is_(True))).mappings().first()
                if not row:raise HTTPException(404,'Cooperative invitation unavailable or expired')
                result=dict(row)
                recipient=db.execute(select(recipients).where(recipients.c.id=='coop:'+row['id'],recipients.c.enabled.is_(True))).mappings().first()
                result['sharing']=self.recipient_view(db,owner,recipient) if recipient else None
                return result

        @app.get('/coops/{cid}/details')
        def details(cid:str,request:Request):
            owner=self.owner(request)
            with self.engine.connect() as db:
                row=db.execute(select(coops).where(coops.c.id==cid,coops.c.active.is_(True))).mappings().first()
                if not row:raise HTTPException(404,'Cooperative unavailable')
                result=dict(row)
                recipient=db.execute(select(recipients).where(recipients.c.id=='coop:'+cid,recipients.c.enabled.is_(True))).mappings().first()
                result['sharing']=self.recipient_view(db,owner,recipient) if recipient else None
                return result

        @app.get('/coops/memberships')
        def list_memberships(request:Request):
            owner=self.owner(request)
            with self.engine.connect() as db:
                rows=[dict(r) for r in db.execute(select(memberships,coops.c.name,coops.c.demo,coops.c.currency,coops.c.annual_minor,coops.c.revision)
                    .join(coops,coops.c.id==memberships.c.coop).where(memberships.c.owner==owner)).mappings()]
            return {'items':rows}

        @app.post('/coops/{cid}/membership')
        def change_membership(cid:str,body:MemberChoice,request:Request):
            owner=self.owner(request)
            if not body.confirmed:raise HTTPException(400,'Explicit confirmation required')
            def save(db):
                coop=db.execute(select(coops).where(coops.c.id==cid)).mappings().first()
                if not coop:raise HTTPException(404,'Cooperative unavailable')
                if body.action=='join' and (not coop['active'] or coop['revision']!=body.termsRevision):raise HTTPException(409,'Invitation or terms changed; scan and review again')
                # Only the requested demonstration is enabled; real contracts/payments require separate approval.
                if not coop['demo']:raise HTTPException(409,'Real cooperative enrolment is not enabled')
                if body.action=='join':self.allowed(db,owner,'coop:'+cid)
                condition=(memberships.c.owner==owner)&(memberships.c.coop==cid)
                old=db.execute(select(memberships).where(condition)).mappings().first()
                if body.action=='leave' and not old:raise HTTPException(404,'No membership to leave')
                status='demo_member' if body.action=='join' else 'left'
                values=dict(status=status,payment_status='demo_no_payment',updated=stamp(),terms_revision=coop['revision'])
                if old and old['status']==status:return {'saved':True,'status':status,'owner':owner}
                if old:db.execute(update(memberships).where(condition).values(**values))
                else:db.execute(insert(memberships).values(owner=owner,coop=cid,**values))
                return {'saved':True,'status':status,'owner':owner}
            return self.transaction(owner,body,'coop.'+body.action,cid,save)
