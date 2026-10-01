"""Scoped administrator operations. Farmer records remain owned by their source account."""
from __future__ import annotations

import csv
import hashlib
import io
import json
import math
import os
import re
import time
from collections import Counter, defaultdict
from datetime import datetime, timezone
from uuid import uuid4, uuid5, NAMESPACE_URL

from fastapi import Depends, HTTPException, Query, Request
from fastapi.responses import Response
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import (MetaData, Table, Column, String, Integer, BigInteger, Boolean,
                        Text, select, insert, update, func)
from sqlalchemy.schema import CreateTable
from admin_portal import area_summary
from geometry import validate, measures
from operations import devices
from admin_geo import centre, distance_km, parse_near, hexagons
from admin_locations import annotate_locations

metadata = MetaData()
tasks = Table('admin_work_items', metadata,
    Column('id', String(36), primary_key=True), Column('scope', String(64), nullable=False),
    Column('owner', String(36), nullable=False), Column('farm', String(36), nullable=False),
    Column('title', String(200), nullable=False), Column('notes', Text, nullable=False),
    Column('assignee', String(36), nullable=False), Column('status', String(20), nullable=False),
    Column('priority', String(16), nullable=False), Column('due', String(10), nullable=False),
    Column('revision', Integer, nullable=False), Column('created', BigInteger, nullable=False),
    Column('updated', BigInteger, nullable=False), Column('actor', String(36), nullable=False))
saved = Table('admin_saved_views', metadata, Column('id', String(36), primary_key=True),
    Column('actor', String(36), nullable=False), Column('scope', String(64), nullable=False),
    Column('name', String(100), nullable=False), Column('filters', Text, nullable=False))
audit = Table('admin_workspace_audit', metadata, Column('id', String(36), primary_key=True),
    Column('scope', String(64), nullable=False), Column('actor', String(36), nullable=False),
    Column('action', String(60), nullable=False), Column('target', String(100), nullable=False),
    Column('at', BigInteger, nullable=False), Column('details', Text, nullable=False))
campaigns = Table('admin_campaigns', metadata, Column('id', String(36), primary_key=True),
    Column('scope', String(64), nullable=False), Column('actor', String(36), nullable=False),
    Column('title', String(160), nullable=False), Column('body', Text, nullable=False),
    Column('recipients', Text, nullable=False), Column('status', String(20), nullable=False),
    Column('created', BigInteger, nullable=False), Column('sent', BigInteger), Column('revision', Integer, nullable=False))
deliveries = Table('admin_message_receipts', metadata, Column('campaign', String(36), primary_key=True),
    Column('owner', String(36), primary_key=True), Column('record', String(36), nullable=False),
    Column('queued', BigInteger, nullable=False), Column('delivered', BigInteger), Column('read', BigInteger))
snapshots = Table('admin_metric_snapshots', metadata, Column('scope', String(64), primary_key=True),
    Column('day', String(10), primary_key=True), Column('data', Text, nullable=False), Column('at', BigInteger, nullable=False))
schedules = Table('admin_report_schedules', metadata, Column('id', String(36), primary_key=True),
    Column('actor', String(36), nullable=False), Column('scope', String(64), nullable=False),
    Column('name', String(100), nullable=False), Column('filters', Text, nullable=False),
    Column('hours', Integer, nullable=False), Column('enabled', Boolean, nullable=False),
    Column('next_run', BigInteger, nullable=False), Column('last_run', BigInteger), Column('error', Text, nullable=False))
exports = Table('admin_report_exports', metadata, Column('id', String(36), primary_key=True),
    Column('actor', String(36), nullable=False), Column('scope', String(64), nullable=False),
    Column('schedule', String(36), nullable=False), Column('name', String(100), nullable=False),
    Column('created', BigInteger, nullable=False), Column('body', Text, nullable=False))

def stamp(): return int(time.time() * 1000)
def canonical(value): return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)
def milliseconds(value):
    try: return int(datetime.fromisoformat(str(value).replace('Z', '+00:00')).timestamp()*1000)
    except (TypeError, ValueError): return 0
def text_value(value): return str(value or '').strip()
def csv_value(value):
    value = str(value if value is not None else '')
    return "'" + value if value.lstrip().startswith(('=', '+', '-', '@')) else value

class Input(BaseModel):
    model_config = ConfigDict(extra='forbid')

class WorkInput(Input):
    owner: str = Field(default='', max_length=36)
    farm: str = Field(default='', max_length=36)
    title: str = Field(min_length=1, max_length=200)
    notes: str = Field(default='', max_length=8000)
    assignee: str = Field(default='', max_length=36)
    status: str = Field(default='Open', pattern='^(Open|In progress|Resolved)$')
    priority: str = Field(default='Normal', pattern='^(Normal|High)$')
    due: str = Field(default='', pattern=r'^(|\d{4}-\d{2}-\d{2})$')
    revision: int = Field(default=0, ge=0)

class ViewInput(Input):
    name: str = Field(min_length=1, max_length=100)
    filters: dict = Field(default_factory=dict)

class CampaignInput(Input):
    title: str = Field(min_length=1, max_length=160)
    body: str = Field(min_length=1, max_length=4000)
    recipients: list[str] = Field(min_length=1, max_length=500)

class ScheduleInput(ViewInput):
    hours: int = Field(default=24, ge=1, le=720)
    enabled: bool = True

class QueryInput(Input):
    question: str = Field(min_length=1, max_length=300)

class Workspace:
    def __init__(self, app, users, students, contacts, records, media, identity):
        self.app, self.engine = app, app.state.engine
        self.users, self.students, self.contacts = users, students, contacts
        self.records, self.media, self.identity = records, media, identity
        self.migrate()
        self.mount()
        from admin_farmer import FarmerReporting
        self.farmer_reporting = FarmerReporting(self)

    def migrate(self):
        from schema_migrations import apply_additive_schema
        apply_additive_schema(self.engine, metadata, '20260915_01_admin_workspace',
                              'Administrator tasks, views, campaigns, receipts, snapshots and scheduled exports')

    def log(self, db, ctx, action, target='', details=None):
        db.execute(insert(audit).values(id=str(uuid4()), scope=ctx['scope'], actor=ctx['actor']['id'],
            action=action, target=target, at=stamp(), details=canonical(details or {})))

    def authorize(self, user, tenant='', write=False):
        if not user: raise HTTPException(401, 'Sign in to FarmerPlus')
        with self.engine.connect() as db:
            role = self.app.state.operations.role(db, user)
            tenancy = getattr(self.app.state, 'tenancy', None)
            choices = []
            platform = bool(user['admin']) and role in {'admin', 'support'}
            if tenancy:
                from tenancy import control, tenants, members
                root = db.scalar(select(control.c.superadmin).where(control.c.id == 1))
                if root: platform = root == user['id']
                if platform:
                    choices = [dict(r) for r in db.execute(select(tenants.c.id, tenants.c.name).where(tenants.c.active.is_(True))).mappings()]
                else:
                    choices = [dict(r) for r in db.execute(select(tenants.c.id, tenants.c.name).join(members, members.c.tenant == tenants.c.id)
                        .where(members.c.owner == user['id'], members.c.role == 'admin', members.c.active.is_(True), tenants.c.active.is_(True))).mappings()]
            if not platform and not choices: raise HTTPException(403, 'Administrator access is required')
            if not tenant: tenant = 'all' if platform else choices[0]['id']
            if tenant == 'all' and not platform: raise HTTPException(403, 'Select an authorised organisation')
            if tenant != 'all' and tenant not in {r['id'] for r in choices}: raise HTTPException(403, 'Organisation access is not permitted')
            if write and role == 'support': raise HTTPException(403, 'Support access is view only')
            query = select(self.users.c.id).where(self.users.c.admin.is_(False))
            if tenant != 'all':
                query = query.join(members, members.c.owner == self.users.c.id).where(members.c.tenant == tenant, members.c.active.is_(True))
            owners = list(db.execute(query).scalars())
        return {'actor': user, 'scope': tenant, 'owners': owners, 'platform': platform,
                'role': 'Support' if role == 'support' else 'Platform administrator' if platform else 'Organisation administrator',
                'canWrite': role != 'support', 'organisations': ([{'id':'all','name':'All organisations'}] if platform else []) + choices}

    def owner(self, ctx, owner):
        if owner not in ctx['owners']: raise HTTPException(404, 'Farmer is not available in this organisation')

    def staff(self, ctx):
        with self.engine.connect() as db:
            rows = [dict(r) for r in db.execute(select(self.users.c.id, self.users.c.username).where(self.users.c.admin.is_(True))).mappings()]
            if ctx['scope'] != 'all':
                from tenancy import members
                ids = set(db.execute(select(members.c.owner).where(members.c.tenant == ctx['scope'], members.c.role == 'admin', members.c.active.is_(True))).scalars())
                rows = [dict(r) for r in db.execute(select(self.users.c.id, self.users.c.username).where(self.users.c.id.in_(ids))).mappings()]
        return rows

    def dataset(self, ctx):
        with self.engine.connect() as db:
            people = {r['id']:dict(r) for r in db.execute(select(self.users.c.id, self.users.c.username).where(self.users.c.id.in_(ctx['owners']))).mappings()}
            for p in people.values(): p.update(name='', studentId='', email='', records=[], lastSync=None, appVersion=None)
            for row in db.execute(select(self.students).where(self.students.c.owner.in_(ctx['owners']))).mappings():
                people[row['owner']].update(name=' '.join(filter(None,[row['firstname'],row['lastname']])),studentId=row['student_id'])
            for row in db.execute(select(self.contacts).where(self.contacts.c.owner.in_(ctx['owners']))).mappings():
                people[row['owner']]['email'] = row['email']
            for row in db.execute(select(devices).where(devices.c.owner.in_(ctx['owners'])).order_by(devices.c.last_sync.desc())).mappings():
                p=people[row['owner']]
                if p['lastSync'] is None: p.update(lastSync=row['last_sync'], appVersion=row['version'])
            from push_notifications import registrations
            from phone_reports import reports as phone_reports
            for p in people.values(): p.update(lastContact=p['lastSync'], versionSource='Device sync' if p['appVersion'] else None)
            for row in db.execute(select(registrations.c.owner,registrations.c.version,registrations.c.updated).where(registrations.c.owner.in_(ctx['owners'])).order_by(registrations.c.updated)).mappings():
                p=people[row['owner']]
                if row['updated'] > (p['lastContact'] or 0):
                    p['lastContact']=row['updated']
                    if row['version']:p.update(appVersion=row['version'],versionSource='Push registration')
            for row in db.execute(select(phone_reports).where(phone_reports.c.owner.in_(ctx['owners'])).order_by(phone_reports.c.received)).mappings():
                p=people[row['owner']]; facts=json.loads(row['payload']).get('technical',{})
                if row['received'] > (p['lastContact'] or 0):
                    p['lastContact']=row['received']
                    if facts.get('versionName'):p.update(appVersion=str(facts['versionName'])+'+'+str(facts.get('versionCode','')),versionSource='Phone snapshot')
            from admin_account_labels import labels
            for p in people.values():p['accountType']='unknown'
            for row in db.execute(select(labels).where(labels.c.owner.in_(ctx['owners']))).mappings():people[row['owner']]['accountType']=row['classification']
            rows = []
            for row in db.execute(select(self.records).where(self.records.c.owner.in_(ctx['owners']),self.records.c.deleted.is_(False))).mappings():
                r = dict(row); r['data'] = json.loads(r['data']); p = people[r['owner']]
                r.update(farmer=p['name'] or p['username'], username=p['username'], lastSync=p['lastSync'], appVersion=p['appVersion'])
                if r['kind'] in {'farm','field'}:
                    r['area'] = area_summary(r['data'])
                    r['mapping'] = 'Mapped' if r['area']['mappedHa'] is not None else 'Needs repair' if r['data'].get('points') else 'Unmapped'
                else: r['mapping'] = 'Mapped' if r['kind']=='pin' else ''
                rows.append(r); p['records'].append(r)
        for p in people.values():
            farms = [r for r in p['records'] if r['kind']=='farm']
            p.update(farms=len(farms),fields=sum(r['kind']=='field' for r in p['records']),mapped=sum(r['mapping']=='Mapped' for r in farms),
                     mappedHa=sum(r['area']['mappedHa'] or 0 for r in farms),countries=sorted({r['data'].get('country') for r in p['records'] if r['kind'] in {'farm','profile','pin'} and r['data'].get('country')}))
        annotate_locations(list(people.values()))
        return list(people.values()), rows

    def filtered(self, people, rows, q='', mapping='', sync='', kind='', country='', days=30, bbox='', near='', crop='', cell='', farmStatus='', accountType='', location='', **unused):
        if location not in {'','available','unavailable'}:raise HTTPException(422,'Invalid location filter')
        if farmStatus not in {'','none','has'}:raise HTTPException(422,'Invalid farm status')
        if accountType not in {'','production','test','unknown','exclude-test'}:raise HTTPException(422,'Invalid account type')
        needle = q.strip().casefold()
        cutoff = stamp() - int(days)*86400000
        def matches(p):
            if location and p.get('locationAvailable',False)!=(location=='available'):return False
            if accountType=='exclude-test' and p['accountType']=='test':return False
            if accountType in {'production','test','unknown'} and p['accountType']!=accountType:return False
            if farmStatus=='none' and p['farms']!=0:return False
            if farmStatus=='has' and p['farms']==0:return False
            text = ' '.join([p['name'],p['username'],p['studentId'],p['email']] + [text_value(r['data'].get('name') or r['data'].get('title')) for r in p['records']])
            if needle and needle not in text.casefold(): return False
            if sync=='never' and p['lastSync'] is not None: return False
            if sync=='recent' and (p['lastSync'] or 0)<cutoff: return False
            if sync=='older' and (p['lastSync'] is None or p['lastSync']>=cutoff): return False
            if country and country.casefold() not in {c.casefold() for c in p['countries']}: return False
            if mapping and not any(r['mapping']==mapping for r in p['records'] if r['kind'] in {'farm','field'}): return False
            return True
        selected = [p for p in people if matches(p)]; ids={p['id'] for p in selected}
        selected_rows = [r for r in rows if r['owner'] in ids and (not kind or r['kind']==kind) and (not mapping or r['mapping']==mapping)]
        if kind:selected=[p for p in selected if p['id'] in {r['owner'] for r in selected_rows}]
        if country:
            farms={(r['owner'],r['id']) for r in rows if r['kind']=='farm' and str(r['data'].get('country','')).casefold()==country.casefold()}
            selected_rows=[r for r in selected_rows if (r['owner'],r['id']) in farms or (r['owner'],r['data'].get('farmId')) in farms or r['kind'] in {'profile','pin'}]
        if crop:
            crop_rows=[r for r in rows if str(r['data'].get('crop','')).casefold()==crop.casefold()]
            crop_farms={(r['owner'],r['id'] if r['kind']=='farm' else r['data'].get('farmId')) for r in crop_rows}
            selected_rows=[r for r in selected_rows if (r['owner'],r['id']) in crop_farms or (r['owner'],r['data'].get('farmId')) in crop_farms or r in crop_rows]
            selected=[p for p in selected if p['id'] in {r['owner'] for r in selected_rows}]
        if bbox:
            try:
                west,south,east,north=map(float,bbox.split(','))
                if not all(math.isfinite(x) for x in [west,south,east,north]) or not -180<=west<east<=180 or not -85<=south<north<=85:raise ValueError()
            except (ValueError,AttributeError):raise HTTPException(422,'Use a valid map area')
            inside=[]
            for r in selected_rows:
                f=self.feature(r)
                if not f:continue
                points=[f['geometry']['coordinates']] if f['geometry']['type']=='Point' else f['geometry']['coordinates'][0]
                if min(p[0] for p in points)<=east and max(p[0] for p in points)>=west and min(p[1] for p in points)<=north and max(p[1] for p in points)>=south:inside.append(r)
            selected_rows=inside;selected=[p for p in selected if p['id'] in {r['owner'] for r in inside}]
        nearby=parse_near(near)
        if nearby:
            lon,lat,radius=nearby
            selected_rows=[r for r in selected_rows if (f:=self.feature(r)) and distance_km([lon,lat],centre(f))<=radius]
            selected=[p for p in selected if p['id'] in {r['owner'] for r in selected_rows}]
        if cell:
            import h3
            if not h3.is_valid_cell(cell):raise HTTPException(422,'Select a valid H3 cell')
            resolution=h3.get_resolution(cell)
            selected_rows=[r for r in selected_rows if r['kind']=='farm' and (f:=self.feature(r)) and h3.latlng_to_cell(centre(f)[1],centre(f)[0],resolution)==cell]
            selected=[p for p in selected if p['id'] in {r['owner'] for r in selected_rows}]
        return selected, selected_rows

    def quality(self, rows):
        issues=[]; fingerprints={}
        for r in rows:
            data=r['data']; label=data.get('name') or data.get('title') or r['kind']
            def add(rule, title, severity='Review'):
                issues.append({'id':r['owner']+':'+r['id']+':'+rule,'owner':r['owner'],'farm':r['id'] if r['kind']=='farm' else data.get('farmId',''),
                    'record':r['id'],'farmer':r['farmer'],'title':title,'recordName':label,'rule':rule,'severity':severity,'kind':r['kind']})
            if r['mapping']=='Needs repair': add('geometry','Boundary needs repair','Action')
            if r['mapping']=='Unmapped': add('unmapped','Boundary has not been mapped','Coverage')
            if r['kind'] in {'harvest','stock'} and not data.get('unit'): add('unit','Quantity has no unit','Action')
            if r['kind']=='sale' and not re.fullmatch('[A-Z]{3}',str(data.get('currency',''))): add('currency','Sale has no valid currency','Action')
            if r['kind']=='farm' and r['mapping']=='Mapped':
                # Ring-order independent candidate check; never silently merge records.
                key=canonical(sorted((p.get('lat'),p.get('lon')) for p in data['points'] if isinstance(p,dict)))
                if key in fingerprints: add('duplicate','Same boundary as another farm; review ownership')
                else: fingerprints[key]=r['id']
        return issues

    def attention(self, ctx, rows):
        items=[{**i,'source':'Data quality','action':'Open farmer profile'} for i in self.quality(rows) if i['severity']=='Action']
        with self.engine.connect() as db:
            work=db.execute(select(tasks).where(tasks.c.scope==ctx['scope'], tasks.c.status!='Resolved').order_by(tasks.c.created)).mappings()
            for r in work: items.append({**dict(r),'source':'Work item','action':'Review task','farmer':'','severity':r['priority']})
            if ctx['platform'] and ctx['scope']=='all':
                from oidc import recovery_reviews, outbox, rp_delivery
                for r in db.execute(select(recovery_reviews).order_by(recovery_reviews.c.created.desc()).limit(100)).mappings():
                    if r.get('status') in {'pending','requested'}:
                        items.append({'id':r['id'],'title':'Account recovery review','source':'Accounts and access','action':'Review account','owner':r.get('owner',''),'severity':'High'})
                pending=db.execute(select(rp_delivery).where(rp_delivery.c.acknowledged.is_(None))).mappings().all()
                if pending: items.append({'id':'revocations','title':f'{len(pending)} remote revocation deliveries pending','source':'Accounts and access','action':'Review delivery','owner':'','severity':'High'})
        return items

    def summary(self, ctx, people, rows):
        farms=[r for r in rows if r['kind']=='farm']; cutoff=stamp()-30*86400000
        return {'farmers':len(people),'withoutFarm':sum(p['farms']==0 for p in people),'farms':len(farms),'fields':sum(r['kind']=='field' for r in rows),
            'mappedFarms':sum(r['mapping']=='Mapped' for r in farms),'mappedHa':sum(r['area']['mappedHa'] or 0 for r in farms),
            'declaredHa':sum(r['area']['declaredHa'] or 0 for r in farms),'recentSync':sum((p['lastSync'] or 0)>=cutoff for p in people),
            'neverSynced':sum(p['lastSync'] is None for p in people),'attention':len(self.attention(ctx,rows)),
            'areaDefinition':'Sum of mapped farm areas; excludes fields. Overlaps may exist. Not surveyed land.'}

    def feature(self, r):
        d=r['data']
        if r.get('hideOnMap'):return None
        if r['kind'] not in {'farm','field','pin'}: return None
        if r['kind']=='pin':
            try:
                lon,lat=float(d['lon']),float(d['lat'])
                if not math.isfinite(lon+lat) or not -180<=lon<=180 or not -85<=lat<=85: return None
            except (KeyError,ValueError,TypeError): return None
            geom={'type':'Point','coordinates':[lon,lat]}
        else:
            if r['mapping']!='Mapped': return None
            ring=[[p['lon'],p['lat']] for p in d['points']]; ring.append(ring[0]); geom={'type':'Polygon','coordinates':[ring]}
        return {'type':'Feature','id':r['id'],'geometry':geom,'properties':{'owner':r['owner'],'name':d.get('name',r['kind']),
            'farmer':r['farmer'],'kind':r['kind'],'farmId':d.get('farmId'),'areaType':d.get('areaType'),'country':d.get('country',''),'crop':d.get('crop',''),
            'placeColor':r.get('placeColor'),'placeType':d.get('type'),
            'areaM2':(r.get('area',{}).get('mappedHa') or 0)*10000,'updated':r['updated'],'version':r['version'],'lastSync':r['lastSync']}}

    def csv(self, people):
        out=io.StringIO(); writer=csv.writer(out)
        writer.writerow(['Farmer','Username','FarmerPlus ID','Farms','Fields','Mapped farms','Mapped farm hectares','Last successful sync','App version'])
        for p in people:
            writer.writerow([csv_value(v) for v in [p['name'],p['username'],p['studentId'],p['farms'],p['fields'],p['mapped'],round(p['mappedHa'],3),
                datetime.fromtimestamp(p['lastSync']/1000,timezone.utc).isoformat() if p['lastSync'] else '',p['appVersion']]])
        return out.getvalue()

    def valid_filters(self, filters):
        allowed={'q','mapping','sync','kind','country','days','view','columns','bbox','near','cell','crop','mode','resolution','period','layer','sort','direction','page','farmStatus','accountType','location','basemap','overlay','overlayDate'}
        if filters.get('accountType','') not in {'','production','test','unknown','exclude-test'}:raise HTTPException(422,'Invalid account type')
        if filters.get('location','') not in {'','available','unavailable'}:raise HTTPException(422,'Invalid location filter')
        if filters.get('basemap','street') not in {'street','roadmap','satellite','hybrid','terrain'}:raise HTTPException(422,'Invalid basemap')
        if filters.get('overlay','') not in {'','rainfall','vegetation'}:raise HTTPException(422,'Invalid overlay')
        if filters.get('farmStatus','') not in {'','none','has'}:raise HTTPException(422,'Invalid farm status')
        if set(filters)-allowed or len(canonical(filters))>4000: raise HTTPException(422,'Unsupported saved filter')
        if 'days' in filters and (type(filters['days']) is not int or not 1<=filters['days']<=365): raise HTTPException(422,'Days must be between 1 and 365')
        for key in {'q','mapping','sync','kind','country','view','layer','mode','near','bbox','cell','crop','period','resolution'} & filters.keys():
            if not isinstance(filters[key],str) or len(filters[key])>200: raise HTTPException(422,'Invalid filter value')
        if 'sort' in filters and filters['sort'] not in ['name','farms','mappedHa','lastSync']: raise HTTPException(422,'Invalid sort')
        if 'direction' in filters and filters['direction'] not in ['asc','desc']: raise HTTPException(422,'Invalid sort direction')
        if 'page' in filters and (type(filters['page']) is not int or not 1<=filters['page']<=100000): raise HTTPException(422,'Invalid page')
        if 'columns' in filters and (not isinstance(filters['columns'],list) or any(c not in ['identity','land','area','sync'] for c in filters['columns'])): raise HTTPException(422,'Invalid columns')
        return filters

    def mount(self):
        app=self.app
        def context(request:Request, tenant:str='', user=Depends(self.identity)):
            return self.authorize(user,tenant,request.method not in {'GET','HEAD','OPTIONS'} and request.url.path not in {'/admin/api/v2/query','/admin/api/v2/places'})
        self.context_dependency=context
        from admin_map_layers import mount as mount_map_layers
        mount_map_layers(self)
        from admin_google_maps import mount as mount_google_maps
        mount_google_maps(self)

        @app.get('/admin/api/v2/context')
        def context_view(ctx=Depends(context)):
            with self.engine.connect() as db:
                person=db.execute(select(self.students).where(self.students.c.owner==ctx['actor']['id'])).mappings().first()
                contact=db.execute(select(self.contacts).where(self.contacts.c.owner==ctx['actor']['id'],self.contacts.c.verified.is_(True))).mappings().first()
            name=' '.join(filter(None,[person['firstname'],person['lastname']])).strip() if person else ''
            return {k:v for k,v in ctx.items() if k not in {'owners','actor'}} | {'username':ctx['actor']['username'],
                'actorLabel':name or (contact['email'] if contact else ctx['actor']['username']),
                'actorEmail':contact['email'] if contact else None,
                'actorId':ctx['actor']['id'],'staff':self.staff(ctx),'environment':os.getenv('FARMER_ADMIN_ENVIRONMENT','Local / test'),
                'release':'2026.09 Operations','marketCoverage':'South Africa · grains and fresh produce'}

        @app.get('/admin/api/v2/overview')
        def overview(ctx=Depends(context)):
            people,rows=self.dataset(ctx); counts=self.summary(ctx,people,rows)
            activity=sorted([{'title':r['data'].get('title') or r['data'].get('name') or r['kind'],'kind':r['kind'],
                'farmer':r['farmer'],'owner':r['owner'],'at':r['updated']} for r in rows],key=lambda r:r['at'],reverse=True)[:8]
            with self.engine.connect() as db:
                history=[{'day':r['day'],**json.loads(r['data'])} for r in db.execute(select(snapshots).where(snapshots.c.scope==ctx['scope']).order_by(snapshots.c.day).limit(90)).mappings()]
            from admin_community import reporting_health
            return {'totals':counts,'attention':self.attention(ctx,rows),'activity':activity,'history':history,'reporting':reporting_health(self.engine,ctx['owners']),
                    'countries':sorted({c for p in people for c in p['countries']}),'checkedAt':stamp()}

        @app.get('/admin/api/v2/farmers')
        def directory(q:str=Query('',max_length=200), mapping:str='', sync:str='', country:str='', days:int=Query(30,ge=1,le=365),
                      sort:str='name', direction:str='asc', bbox:str='',near:str='',crop:str='',kind:str='',cell:str='',farmStatus:str='',accountType:str='',location:str='',page:int=Query(1,ge=1), pageSize:int=Query(25,ge=1,le=100),ctx=Depends(context)):
            people,rows=self.dataset(ctx); people,_=self.filtered(people,rows,q=q,mapping=mapping,sync=sync,country=country,days=days,bbox=bbox,near=near,crop=crop,kind=kind,cell=cell,farmStatus=farmStatus,accountType=accountType,location=location)
            key=sort if sort in {'farms','fields','mappedHa','lastSync','appVersion'} else 'name'
            people.sort(key=lambda p:(p[key] or (p['username'] if key=='name' else '' if key=='appVersion' else 0)),reverse=direction=='desc')
            return {'people':[{k:v for k,v in p.items() if k!='records'} for p in people[(page-1)*pageSize:page*pageSize]],'total':len(people),'page':page,'pageSize':pageSize,'checkedAt':stamp()}

        @app.get('/admin/api/v2/farmers/{owner}')
        def profile(owner:str,ctx=Depends(context)):
            self.owner(ctx,owner); people,rows=self.dataset({**ctx,'owners':[owner]}); person=people[0]
            with self.engine.begin() as db:
                self.log(db,ctx,'farmer_view',owner)
                work=[dict(r) for r in db.execute(select(tasks).where(tasks.c.scope==ctx['scope'],tasks.c.owner==owner).order_by(tasks.c.updated.desc())).mappings()]
            return {'person':person,'quality':self.quality(rows),'work':work,'checkedAt':stamp()}

        @app.get('/admin/api/v2/farmers/{owner}/media/{digest}')
        def attachment(owner:str,digest:str,ctx=Depends(context)):
            self.owner(ctx,owner)
            if not re.fullmatch('[a-f0-9]{64}',digest): raise HTTPException(404,'Attachment not found')
            with self.engine.begin() as db:
                row=db.execute(select(self.media).where(self.media.c.owner==owner,self.media.c.hash==digest,self.media.c.complete.is_(True))).mappings().first()
                if not row: raise HTTPException(404,'Attachment is not synchronised')
                self.log(db,ctx,'attachment_download',owner)
                return Response(bytes(row['body']),media_type='application/octet-stream',headers={'Content-Disposition':f'attachment; filename="{digest}.bin"'})

        @app.get('/admin/api/v2/map')
        def map_data(q:str=Query('',max_length=200),mapping:str='',sync:str='',kind:str='',country:str='',bbox:str='',days:int=Query(30,ge=1,le=365),
                     layer:str='',resolution:int=Query(5,ge=2,le=9),near:str='',crop:str='',cell:str='',farmStatus:str='',accountType:str='',location:str='',ctx=Depends(context)):
            people,rows=self.dataset(ctx)
            crops=sorted({str(r['data']['crop']) for r in rows if r['data'].get('crop')})
            countries=sorted({c for p in people for c in p['countries']})
            people,rows=self.filtered(people,rows,q=q,mapping=mapping,sync=sync,kind=kind,country=country,days=days,bbox=bbox,near=near,crop=crop,cell=cell,farmStatus=farmStatus,accountType=accountType,location=location)
            features=[f for r in rows if (f:=self.feature(r))]
            total=len(features); farms=[f for f in features if f['properties']['kind']=='farm']
            nearby=parse_near(near)
            if nearby:
                for f in features:f['properties']['distanceKm']=round(distance_km(nearby[:2],centre(f)),2)
                features.sort(key=lambda f:f['properties']['distanceKm'])
            else:features.sort(key=lambda f:(f['properties']['name'].casefold(),str(f['id'])))
            # Truncate once; list, density cells and displayed metrics share these same records.
            displayed=features[:10000]; cells=hexagons(displayed,resolution)
            return {'type':'FeatureCollection','features':cells if layer=='hex' else displayed,'hexagons':cells,
                    'total':total,'truncated':total>10000,'returned':len(displayed),
                    'farms':len(farms),'farmers':len({f['properties']['owner'] for f in features}),
                    'matchingFarmers':len(people),'unlocatedFarmers':sum(not p['locationAvailable'] for p in people),
                    'people':[{'id':p['id'],'name':p['name'] or p['username'],'farms':p['farms'],'locationStatus':p['locationStatus']} for p in people[:250]],
                    'mappedHa':sum(f['properties']['areaM2'] for f in farms)/10000,
                    'unmapped':sum(r['mapping']=='Unmapped' for r in rows),'invalid':sum(r['mapping']=='Needs repair' for r in rows),
                    'countries':countries,'crops':crops,'checkedAt':stamp()}

        @app.get('/admin/api/v2/map/export')
        def map_export(q:str='',mapping:str='',sync:str='',kind:str='',country:str='',bbox:str='',days:int=Query(30,ge=1,le=365),
                       layer:str='',resolution:int=Query(5,ge=2,le=9),near:str='',crop:str='',cell:str='',farmStatus:str='',accountType:str='',location:str='',ctx=Depends(context)):
            data=map_data(q=q,mapping=mapping,sync=sync,kind=kind,country=country,bbox=bbox,days=days,layer=layer,resolution=resolution,near=near,crop=crop,cell=cell,farmStatus=farmStatus,accountType=accountType,location=location,ctx=ctx)
            with self.engine.begin() as db:self.log(db,ctx,'map_export','',{'features':len(data['features'])})
            return Response(canonical(data),media_type='application/geo+json',headers={'Content-Disposition':'attachment; filename="farmerplus-map.geojson"'})

        @app.get('/admin/api/v2/quality')
        def quality(ctx=Depends(context)):
            _,rows=self.dataset(ctx); return {'issues':self.quality(rows),'checkedAt':stamp()}

        @app.get('/admin/api/v2/work')
        def work(ctx=Depends(context)):
            with self.engine.connect() as db:
                return {'items':[dict(r) for r in db.execute(select(tasks).where(tasks.c.scope==ctx['scope']).order_by(tasks.c.updated.desc())).mappings()]}

        def validate_work(ctx,body):
            if body.owner: self.owner(ctx,body.owner)
            if body.farm:
                if not body.owner: raise HTTPException(422,'Select a farmer for this farm')
                with self.engine.connect() as db:
                    if not db.execute(select(self.records.c.id).where(self.records.c.owner==body.owner,self.records.c.id==body.farm,self.records.c.kind=='farm',self.records.c.deleted.is_(False))).first(): raise HTTPException(422,'Farm does not belong to this farmer')
            if body.assignee and body.assignee not in {r['id'] for r in self.staff(ctx)}: raise HTTPException(422,'Select an administrator in this organisation')
            if body.due:
                try: datetime.strptime(body.due,'%Y-%m-%d')
                except ValueError: raise HTTPException(422,'Enter a real due date')
            if not body.title.strip(): raise HTTPException(422,'Enter a task title')

        @app.post('/admin/api/v2/work',status_code=201)
        def create_work(body:WorkInput,ctx=Depends(context)):
            validate_work(ctx,body); row=body.model_dump(exclude={'revision'})|{'id':str(uuid4()),'scope':ctx['scope'],'actor':ctx['actor']['id'],'created':stamp(),'updated':stamp(),'revision':1}
            with self.engine.begin() as db: db.execute(insert(tasks).values(**row)); self.log(db,ctx,'work_created',row['id'])
            return row

        @app.put('/admin/api/v2/work/{key}')
        def edit_work(key:str,body:WorkInput,ctx=Depends(context)):
            validate_work(ctx,body)
            with self.engine.begin() as db:
                result=db.execute(update(tasks).where(tasks.c.id==key,tasks.c.scope==ctx['scope'],tasks.c.revision==body.revision)
                    .values(**body.model_dump(exclude={'revision'}),revision=body.revision+1,updated=stamp()))
                if not result.rowcount: raise HTTPException(409,'Task changed. Refresh and review the latest version.')
                self.log(db,ctx,'work_updated',key)
            return {'saved':True,'revision':body.revision+1}

        @app.get('/admin/api/v2/views')
        def views(ctx=Depends(context)):
            with self.engine.connect() as db:
                return {'views':[{**dict(r),'filters':json.loads(r['filters'])} for r in db.execute(select(saved).where(saved.c.actor==ctx['actor']['id'],saved.c.scope==ctx['scope'])).mappings()]}

        @app.post('/admin/api/v2/views',status_code=201)
        def save_view(body:ViewInput,ctx=Depends(context)):
            self.valid_filters(body.filters); key=str(uuid4())
            with self.engine.begin() as db: db.execute(insert(saved).values(id=key,actor=ctx['actor']['id'],scope=ctx['scope'],name=body.name,filters=canonical(body.filters)))
            return {'id':key}

        @app.get('/admin/api/v2/campaigns')
        def campaign_list(ctx=Depends(context)):
            with self.engine.connect() as db:
                result=[]
                for row in db.execute(select(campaigns).where(campaigns.c.scope==ctx['scope']).order_by(campaigns.c.created.desc())).mappings():
                    recs=db.execute(select(deliveries).where(deliveries.c.campaign==row['id'])).mappings().all()
                    recipient_ids=json.loads(row['recipients'])
                    recipient_names=[{'id':r['id'],'name':' '.join(filter(None,[r['firstname'],r['lastname']])) or r['username']} for r in db.execute(select(self.users.c.id,self.users.c.username,self.students.c.firstname,self.students.c.lastname).outerjoin(self.students,self.students.c.owner==self.users.c.id).where(self.users.c.id.in_(recipient_ids),self.users.c.id.in_(ctx['owners']))).mappings()]
                    result.append({**dict(row),'recipients':recipient_ids,'recipientDetails':recipient_names,'delivery':{'queued':len(recs),'delivered':sum(r['delivered'] is not None for r in recs),'read':sum(r['read'] is not None for r in recs)}})
                return {'campaigns':result}

        @app.post('/admin/api/v2/campaigns',status_code=201)
        def draft_campaign(body:CampaignInput,ctx=Depends(context)):
            recipients=sorted(set(body.recipients))
            for owner in recipients: self.owner(ctx,owner)
            row=body.model_dump()|{'id':str(uuid4()),'scope':ctx['scope'],'actor':ctx['actor']['id'],'recipients':canonical(recipients),'status':'Draft','created':stamp(),'sent':None,'revision':1}
            with self.engine.begin() as db: db.execute(insert(campaigns).values(**row));self.log(db,ctx,'campaign_drafted',row['id'],{'recipients':len(recipients)})
            return {**row,'recipients':recipients}

        @app.post('/admin/api/v2/campaigns/{key}/send')
        def send_campaign(key:str,ctx=Depends(context)):
            with self.engine.begin() as db:
                # Claim with a write before reading, also serialising SQLite sends.
                db.execute(update(campaigns).where(campaigns.c.id==key,campaigns.c.scope==ctx['scope']).values(revision=campaigns.c.revision))
                row=db.execute(select(campaigns).where(campaigns.c.id==key,campaigns.c.scope==ctx['scope']).with_for_update()).mappings().first()
                if not row: raise HTTPException(404,'Campaign not found')
                if row['status']=='Sent': return {'sent':True,'replayed':True}
                recipients=json.loads(row['recipients'])
                for owner in recipients: self.owner(ctx,owner)
                now=datetime.now(timezone.utc).isoformat()
                # Existing phone routes support task messages; each campaign creates an explicit farmer task.
                for owner in recipients:
                    tid=str(uuid5(NAMESPACE_URL,f'farmerplus:campaign:{key}:{owner}:task'))
                    mid=str(uuid5(NAMESPACE_URL,f'farmerplus:campaign:{key}:{owner}:inbox'))
                    values=[(tid,'task',{'title':row['title'],'notes':row['body'],'completed':False,'source':'FarmerPlus administration'}),
                            (mid,'inbox',{'source':'FarmerPlus','title':row['title'],'action':'Open message','route':'task:'+tid,'priority':'normal','read':False,'completed':False})]
                    db.execute(update(self.users).where(self.users.c.id==owner).values(serial=self.users.c.serial+1))
                    if db.scalar(select(func.count()).select_from(self.records).where(self.records.c.owner==owner))>9998:
                        raise HTTPException(413,'A recipient has reached the account record limit; no messages were sent')
                    for rid,kind,data in values:
                        db.execute(insert(self.records).values(owner=owner,id=rid,kind=kind,data=canonical(data),version=1,deleted=False,updated=now))
                    db.execute(insert(deliveries).values(campaign=key,owner=owner,record=mid,queued=stamp()))
                    if getattr(app.state, 'push', None):
                        from push_notifications import Notification
                        app.state.push.enqueue(db, owner, Notification(eventId=mid,
                            title=row['title'], body=row['body'], destination='task', resourceId=tid))
                db.execute(update(campaigns).where(campaigns.c.id==key).values(status='Sent',sent=stamp(),revision=row['revision']+1))
                self.log(db,ctx,'campaign_sent',key,{'recipients':len(recipients)})
            return {'sent':True,'recipients':len(recipients)}

        @app.get('/admin/api/v2/audit')
        def audit_list(ctx=Depends(context)):
            with self.engine.connect() as db:
                rows=[dict(r) for r in db.execute(select(audit).where(audit.c.scope==ctx['scope']).order_by(audit.c.at.desc()).limit(200)).mappings()]
            return {'events':rows}

        @app.get('/admin/api/v2/export')
        def export(q:str='',mapping:str='',sync:str='',country:str='',bbox:str='',near:str='',crop:str='',kind:str='',cell:str='',farmStatus:str='',accountType:str='',location:str='',days:int=Query(30,ge=1,le=365),ctx=Depends(context)):
            people,rows=self.dataset(ctx);people,_=self.filtered(people,rows,q=q,mapping=mapping,sync=sync,country=country,bbox=bbox,near=near,crop=crop,kind=kind,cell=cell,days=days,farmStatus=farmStatus,accountType=accountType,location=location)
            with self.engine.begin() as db:self.log(db,ctx,'directory_export','',{'rows':len(people)})
            return Response(self.csv(people),media_type='text/csv',headers={'Content-Disposition':'attachment; filename="farmerplus-farmers.csv"'})

        @app.get('/admin/api/v2/reports')
        def reports(ctx=Depends(context)):
            with self.engine.connect() as db:
                return {'schedules':[dict(r) for r in db.execute(select(schedules).where(schedules.c.actor==ctx['actor']['id'],schedules.c.scope==ctx['scope'])).mappings()],
                        'exports':[dict(r) for r in db.execute(select(exports.c.id,exports.c.name,exports.c.created).where(exports.c.actor==ctx['actor']['id'],exports.c.scope==ctx['scope']).order_by(exports.c.created.desc()).limit(50)).mappings()]}

        @app.post('/admin/api/v2/reports',status_code=201)
        def schedule(body:ScheduleInput,ctx=Depends(context)):
            self.valid_filters(body.filters); row=body.model_dump()|{'id':str(uuid4()),'actor':ctx['actor']['id'],'scope':ctx['scope'],'filters':canonical(body.filters),'next_run':stamp(),'last_run':None,'error':''}
            with self.engine.begin() as db:db.execute(insert(schedules).values(**row));self.log(db,ctx,'report_scheduled',row['id'])
            return {'id':row['id']}

        @app.post('/admin/api/v2/reports/{key}/toggle')
        def toggle_report(key:str,ctx=Depends(context)):
            with self.engine.begin() as db:
                row=db.execute(select(schedules).where(schedules.c.id==key,schedules.c.actor==ctx['actor']['id'],schedules.c.scope==ctx['scope'])).mappings().first()
                if not row:raise HTTPException(404,'Report not found')
                db.execute(update(schedules).where(schedules.c.id==key).values(enabled=not row['enabled']))
            return {'enabled':not row['enabled']}

        @app.get('/admin/api/v2/reports/{key}/download')
        def download_report(key:str,ctx=Depends(context)):
            with self.engine.connect() as db:
                row=db.execute(select(exports).where(exports.c.id==key,exports.c.actor==ctx['actor']['id'],exports.c.scope==ctx['scope'])).mappings().first()
                if not row:raise HTTPException(404,'Report not found')
            return Response(row['body'],media_type='text/csv',headers={'Content-Disposition':'attachment; filename="farmerplus-report.csv"'})

        @app.post('/admin/api/v2/reports/run')
        def run_reports(ctx=Depends(context)):
            return self.run_jobs(ctx['actor']['id'],ctx['scope'])

        @app.post('/admin/api/v2/query')
        def query(body:QueryInput,ctx=Depends(context)):
            question=body.question.casefold(); filters={}; reasons=[]
            if 'unmapped' in question or 'without boundar' in question: filters['mapping']='Unmapped';reasons.append('Boundary has not been mapped')
            if 'repair' in question or 'invalid' in question: filters['mapping']='Needs repair';reasons.append('Stored boundary needs repair')
            if 'never sync' in question or 'no sync report' in question: filters['sync']='never';reasons.append('No successful device report recorded')
            elif 'recent' in question or 'older' in question: filters['sync']='older' if 'no recent' in question or 'older' in question else 'recent';reasons.append('30-day successful device report window')
            people,rows=self.dataset(ctx)
            for country in sorted({c for p in people for c in p['countries']},key=len,reverse=True):
                if country.casefold() in question: filters['country']=country;reasons.append('Farm country: '+country);break
            if not filters:return {'supported':False,'explanation':'Try “Show unmapped farms”, “Farmers with no sync report”, or “Boundaries needing repair”. This assistant opens explicit filters and does not guess facts.'}
            selected,_=self.filtered(people,rows,**filters)
            return {'supported':True,'filters':filters,'count':len(selected),'explanation':'; '.join(reasons),'source':'Current organisation-scoped FarmerPlus records','checkedAt':stamp()}

    def record_delivery(self, db, owner, record_id, read=False):
        if read:
            db.execute(update(deliveries).where(deliveries.c.owner==owner,deliveries.c.record==record_id,deliveries.c.delivered.is_(None)).values(delivered=stamp()))
        values={'read':stamp()} if read else {'delivered':stamp()}
        column=deliveries.c.read if read else deliveries.c.delivered
        db.execute(update(deliveries).where(deliveries.c.owner==owner,deliveries.c.record==record_id,column.is_(None)).values(**values))

    def run_jobs(self, actor_id=None, scope=None):
        now=stamp();count=0;failed=0
        with self.engine.connect() as db:
            query=select(schedules).where(schedules.c.enabled.is_(True),schedules.c.next_run<=now)
            if actor_id:query=query.where(schedules.c.actor==actor_id,schedules.c.scope==scope)
            due=[dict(r) for r in db.execute(query).mappings()]
        for job in due:
            try:
                with self.engine.connect() as db:user=db.execute(select(self.users).where(self.users.c.id==job['actor'])).mappings().first()
                ctx=self.authorize(dict(user) if user else None,job['scope'],write=True)
                people,rows=self.dataset(ctx);selected,_=self.filtered(people,rows,**json.loads(job['filters']))
                body=self.csv(selected)
                with self.engine.begin() as db:
                    claim=db.execute(update(schedules).where(schedules.c.id==job['id'],schedules.c.next_run==job['next_run'],schedules.c.enabled.is_(True)).values(next_run=now+job['hours']*3600000,last_run=now,error=''))
                    if not claim.rowcount:continue
                    db.execute(insert(exports).values(id=str(uuid4()),actor=job['actor'],scope=job['scope'],schedule=job['id'],name=job['name'],created=now,body=body))
                    totals=self.summary(ctx,people,rows);day=datetime.now(timezone.utc).date().isoformat()
                    exists=db.execute(select(snapshots.c.day).where(snapshots.c.scope==job['scope'],snapshots.c.day==day)).first()
                    if not exists:db.execute(insert(snapshots).values(scope=job['scope'],day=day,data=canonical(totals),at=now))
                count+=1
            except Exception:
                failed+=1
                with self.engine.begin() as db:db.execute(update(schedules).where(schedules.c.id==job['id']).values(error='Report could not run. Check current access and source availability.',next_run=now+3600000))
        return {'completed':count,'failed':failed}
