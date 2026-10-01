"""Device inventory, attributable record history and cached Moodle reporting."""
import json, os, time
from uuid import uuid4
from concurrent.futures import ThreadPoolExecutor
import httpx
from fastapi import Depends, HTTPException, Query, Request
from sqlalchemy import MetaData, Table, Column, String, Text, BigInteger, Integer, select, insert, update, delete, or_, text
from schema_migrations import apply_additive_schema

APPS = {
 'diary': ('Farm Diary', ['diary']), 'planner': ('My Planner', ['task']),
 'calculator': ('Farm Calculator', ['calculation']), 'guides': ('Farm Guides', ['guideprogress']),
 'stock': ('Input Stock', ['stock','stockmove']), 'harvest': ('Harvest & Sales', ['harvest','sale']),
 'coop': ('Coop', [])}
meta=MetaData()
links=Table('farmer_moodle_reporting_links',meta,Column('owner',String(36),primary_key=True),Column('moodle_id',Integer,nullable=False),Column('checked',BigInteger,nullable=False))
inventory=Table('farmer_app_inventory',meta,Column('owner',String(36),primary_key=True),Column('device',String(36),primary_key=True),Column('payload',Text,nullable=False),Column('reported',BigInteger,nullable=False))
learning=Table('farmer_learning_reports',meta,Column('owner',String(36),primary_key=True),Column('moodle_id',Integer,nullable=False),Column('payload',Text,nullable=False),Column('checked',BigInteger),Column('attempted',BigInteger),Column('next_run',BigInteger,nullable=False),Column('failures',Integer,nullable=False),Column('error',Text,nullable=False),Column('lease_until',BigInteger,nullable=False))
worker=Table('farmer_reporting_worker',meta,Column('id',String(32),primary_key=True),Column('heartbeat',BigInteger,nullable=False))
provenance=Table('farmer_record_provenance',meta,Column('owner',String(36),primary_key=True),Column('record',String(36),primary_key=True),Column('version',Integer,primary_key=True),Column('app',String(32),nullable=False),Column('device',String(36),nullable=False),Column('received',BigInteger,nullable=False))
def now():return int(time.time()*1000)
def migrate(engine):
    apply_additive_schema(engine,meta,'20260916_03_farmer_reporting','Device app inventory, verified Moodle reporting links and record provenance')
    if engine.dialect.name=='postgresql':
        with engine.begin() as db:
            db.execute(text('SELECT pg_advisory_xact_lock(748521932)'))
            for table,column in [('farmer_devices','last_sync'),('admin_change_reasons','created')]:
                typ=db.scalar(text('SELECT data_type FROM information_schema.columns WHERE table_name=:t AND column_name=:c'),{'t':table,'c':column})
                if typ=='integer':db.execute(text(f'ALTER TABLE {table} ALTER COLUMN {column} TYPE BIGINT'))
def record_provenance(db,owner,op,version):
    if not op.sourceAppId:return
    if op.sourceAppId not in APPS or op.kind not in APPS[op.sourceAppId][1]:raise HTTPException(422,'App does not own this record type')
    db.execute(insert(provenance).values(owner=owner,record=str(op.id),version=version,app=op.sourceAppId,device=str(op.deviceId or ''),received=now()))
def record_inventory(db,owner,body):
    if body.installedApps is None:return
    apps=[x.model_dump() for x in body.installedApps]
    if len({x['id'] for x in apps})!=len(apps):raise HTTPException(422,'Duplicate app in inventory')
    values={'payload':json.dumps({'apps':apps,'pending':body.pendingChanges,'conflicts':body.conflicts,'browser':body.browser.model_dump() if body.browser else None,'settings':body.settings}),'reported':now()}
    where=(inventory.c.owner==owner)&(inventory.c.device==body.device)
    if db.execute(select(inventory.c.owner).where(where)).first():db.execute(update(inventory).where(where).values(**values))
    else:db.execute(insert(inventory).values(owner=owner,device=body.device,**values))

class FarmerReporting:
    def __init__(self,ws):
        self.ws,self.engine=ws,ws.engine
        migrate(self.engine)
        from admin_account_labels import mount
        mount(ws)
        self.pool=ThreadPoolExecutor(max_workers=2,thread_name_prefix='moodle-report')
        self.mount()
        from phone_reports import PhoneReporting
        self.phone_reporting=PhoneReporting(ws)
    def linked(self,owner):
        with self.engine.connect() as db:
            person=db.execute(select(self.ws.students).where(self.ws.students.c.owner==owner)).mappings().first()
            link=db.execute(select(links).where(links.c.owner==owner)).mappings().first()
        if person and link:return {**dict(person),'moodle_id':link['moodle_id']}
        return person
    def sync_links(self):
        response=httpx.post('https://learn.agritec.earth/auth/farmerplusoidc/reporting.php',data={'token':os.environ['FARMER_MOODLE_REPORT_TOKEN']},timeout=20)
        response.raise_for_status();mappings=response.json()['mappings']
        assert isinstance(mappings,list)
        by={m['farmerplusId']:int(m['moodleId']) for m in mappings}
        assert len(by)==len(mappings) and len(set(by.values()))==len(by)
        with self.engine.begin() as db:
            people=list(db.execute(select(self.ws.students.c.owner,self.ws.students.c.student_id)).all())
            db.execute(delete(links))
            for owner,sid in people:
                if sid in by:db.execute(insert(links).values(owner=owner,moodle_id=by[sid],checked=now()))
    def read(self,owner):
        person=self.linked(owner)
        with self.engine.connect() as db:r=db.execute(select(learning).where(learning.c.owner==owner)).mappings().first()
        linked=bool(person and person['moodle_id'])
        if r and (not linked or r['moodle_id']!=person['moodle_id']):r=None
        return {'linked':linked,'configured':bool(os.getenv('FARMER_MOODLE_REPORT_TOKEN')),'courses':json.loads(r['payload']) if r else [],'checkedAt':r['checked'] if r else None,'attemptedAt':r['attempted'] if r else None,'error':r['error'] if r else '', 'refreshing':bool(r and r['lease_until']>now()),'stale':not r or not r['checked'] or now()-r['checked']>3600000,'authority':'Moodle','nextCheck':r['next_run'] if r else None}
    def enqueue(self,owner):
        person=self.linked(owner)
        if not person or not person['moodle_id']:return False
        if not os.getenv('FARMER_MOODLE_REPORT_TOKEN'):return False
        self.ensure(owner,person['moodle_id'])
        with self.engine.begin() as db:
            result=db.execute(update(learning).where(learning.c.owner==owner,learning.c.lease_until<=now()).values(lease_until=now()+180000,attempted=now()))
        if not result.rowcount:return False
        self.pool.submit(self.refresh,owner,person['moodle_id'])
        return True
    def ensure(self,owner,mid):
        from sqlalchemy.exc import IntegrityError
        try:
            with self.engine.begin() as db:
                r=db.execute(select(learning).where(learning.c.owner==owner)).mappings().first()
                values=dict(moodle_id=mid,payload='[]',checked=None,attempted=None,next_run=0,failures=0,error='',lease_until=0)
                if not r:db.execute(insert(learning).values(owner=owner,**values))
                elif r['moodle_id']!=mid:db.execute(update(learning).where(learning.c.owner==owner).values(**values))
        except IntegrityError:pass
    def fetch(self,mid):
        def call(client,fn,**params):
            response=client.post('https://learn.agritec.earth/webservice/rest/server.php',data={'wstoken':os.environ['FARMER_MOODLE_REPORT_TOKEN'],'wsfunction':fn,'moodlewsrestformat':'json',**params})
            response.raise_for_status();result=response.json()
            if isinstance(result,dict) and ('exception' in result or 'errorcode' in result):raise ValueError('Moodle reporting request rejected')
            return result
        with httpx.Client(timeout=20,follow_redirects=False) as client:
            courses=call(client,'core_enrol_get_users_courses',userid=mid,returnusercount=0)
            if not isinstance(courses,list):raise ValueError('Invalid Moodle course response')
            results=[];deadline=time.monotonic()+100
            for c in courses:
                complete=None;completedAt=None;issue=''
                if time.monotonic()>deadline:raise TimeoutError('Reporting deadline')
                if c.get('enablecompletion') and not c.get('completionhascriteria',True):issue='Course completion criteria are not configured in Moodle'
                elif c.get('enablecompletion'):
                    try:
                        state=call(client,'core_completion_get_course_completion_status',courseid=c['id'],userid=mid)['completionstatus']
                        complete=bool(state['completed'])
                        completedAt=state.get('timecompleted',0)*1000 or None
                    except (ValueError,KeyError,httpx.HTTPError):issue='Completion reporting unavailable for this course'
                progress=c.get('progress')
                if isinstance(progress,bool) or not isinstance(progress,(int,float)) or not 0<=progress<=100:progress=None
                state='Completed' if complete is True else 'In progress' if progress is not None and progress>0 else 'Not started' if progress==0 else 'Completion not tracked' if not c.get('enablecompletion') else 'Status unavailable'
                results.append({'id':c['id'],'name':c['fullname'],'status':state,'progress':progress,'completed':complete,'completedAt':completedAt,'lastAccess':(c.get('lastaccess') or 0)*1000 or None,'startDate':(c.get('startdate') or 0)*1000 or None,'endDate':(c.get('enddate') or 0)*1000 or None,'error':issue,'url':'https://learn.agritec.earth/course/view.php?id='+str(int(c['id']))})
            return results
    def refresh(self,owner,mid):
        try:
            courses=self.fetch(mid)
            with self.engine.begin() as db:db.execute(update(learning).where(learning.c.owner==owner,learning.c.moodle_id==mid).values(payload=json.dumps(courses,allow_nan=False),checked=now(),next_run=now()+900000,failures=0,error='',lease_until=0))
        except Exception:
            with self.engine.begin() as db:
                count=db.scalar(select(learning.c.failures).where(learning.c.owner==owner)) or 0
                db.execute(update(learning).where(learning.c.owner==owner,learning.c.moodle_id==mid).values(failures=count+1,error='Moodle could not be refreshed. Previous results are retained.',next_run=now()+min(3600000,60000*2**min(count,6)),lease_until=0))
    def run_jobs(self):
        with self.engine.begin() as db:
            if db.execute(select(worker).where(worker.c.id=='moodle')).first():db.execute(update(worker).where(worker.c.id=='moodle').values(heartbeat=now()))
            else:db.execute(insert(worker).values(id='moodle',heartbeat=now()))
        if not os.getenv('FARMER_MOODLE_REPORT_TOKEN'):return 0
        self.sync_links()
        with self.engine.connect() as db:
            owners=list(db.execute(select(self.ws.users.c.id).where(self.ws.users.c.admin.is_(False))).scalars())
        people=[(owner,p['moodle_id']) for owner in owners if (p:=self.linked(owner)) and p['moodle_id']]
        for owner,mid in people:self.ensure(owner,mid)
        allowed={p[0] for p in people}
        with self.engine.connect() as db:due=list(db.execute(select(learning.c.owner).where(learning.c.owner.in_(allowed),learning.c.next_run<=now(),learning.c.lease_until<=now()).order_by(learning.c.next_run).limit(2)).scalars())
        return sum(self.enqueue(owner) for owner in due if owner in allowed)
    def apps(self,owner):
        from operations import devices
        with self.engine.connect() as db:
            reports=[dict(r) for r in db.execute(select(inventory).where(inventory.c.owner==owner)).mappings()]
            deviceRows=[dict(r) for r in db.execute(select(devices).where(devices.c.owner==owner)).mappings()]
            records=[dict(r) for r in db.execute(select(self.ws.records).where(self.ws.records.c.owner==owner)).mappings()]
        by={r['device']:r for r in reports}
        result=[]
        reported_ids={a['id'] for r in reports for a in json.loads(r['payload'])['apps']}
        all_apps={**APPS, **{key:(key,[]) for key in reported_ids if key not in APPS}}
        for key,(name,kinds) in all_apps.items():
            installed=[r for r in reports if any(a['id']==key for a in json.loads(r['payload'])['apps'])]
            rows=[r for r in records if r['kind'] in kinds]
            if key=='coop':
                from admin_community import coop_history
                coop=coop_history(self.engine,owner)
                if installed or coop['memberships'] or coop['total']:
                    result.append({'id':key,'name':name,'installed':bool(installed) if reports else None,
                        'devices':len(installed),'inventoryAt':max((r['reported'] for r in reports),default=None),
                        'recordCount':coop['total'],'hasSyncedData':bool(coop['memberships'] or coop['total']),
                        'lastRecordAt':coop['lastRecordAt'],'attribution':'Cooperative service'})
                continue
            if not installed and not rows:continue
            result.append({'id':key,'name':name,'installed':bool(installed) if reports else None,'devices':len(installed),'inventoryAt':max((r['reported'] for r in reports),default=None),'recordCount':sum(not r['deleted'] for r in rows),'hasSyncedData':bool(rows),'lastRecordAt':max((r['updated'] for r in rows),default=None),'attribution':'Record type'})
        return {'apps':result,'inventoryKnown':bool(reports),'devices':[{'id':r['device'],'version':r['version'],'lastSync':r['last_sync'],'inventoryAt':by.get(r['device'],{}).get('reported'),'apps':json.loads(by[r['device']]['payload'])['apps'] if r['device'] in by else None,'pending':json.loads(by[r['device']]['payload']).get('pending') if r['device'] in by else None,'conflicts':json.loads(by[r['device']]['payload']).get('conflicts') if r['device'] in by else None,'browser':json.loads(by[r['device']]['payload']).get('browser') if r['device'] in by else None,'settings':json.loads(by[r['device']]['payload']).get('settings',{}) if r['device'] in by else {}} for r in deviceRows]}
    def history(self,owner,app,page):
        if app not in APPS:
            if not any(row['id']==app for row in self.apps(owner)['apps']):
                raise HTTPException(404,'App not found')
            return {'records':[], 'total':0, 'page':page, 'pageSize':25,
                    'attribution':'Downloaded mini-app inventory; activity is managed by the mini-app service.'}
        if app=='coop':
            from admin_community import coop_history
            return coop_history(self.engine,owner,page)
        from app import receipts
        kinds=APPS[app][1];events={}
        with self.engine.connect() as db:
            sources={(r['record'],r['version']):dict(r) for r in db.execute(select(provenance).where(provenance.c.owner==owner,provenance.c.app==app)).mappings()}
            for raw in db.execute(select(receipts.c.response).where(receipts.c.owner==owner)).scalars():
                try:r=json.loads(raw)['record']
                except (KeyError,ValueError,TypeError):continue
                if r.get('kind') in kinds:events[(r['id'],r['version'])]=r
            for row in db.execute(select(self.ws.records).where(self.ws.records.c.owner==owner,self.ws.records.c.kind.in_(kinds))).mappings():
                r=dict(row);r['data']=json.loads(r['data']);events.setdefault((r['id'],r['version']),r)
        rows=sorted(events.values(),key=lambda r:(r.get('updated',''),r.get('version',0)),reverse=True)
        for r in rows:r.update(owner=owner,provenance=sources.get((r['id'],r['version'])))
        return {'records':rows[(page-1)*25:page*25],'total':len(rows),'page':page,'pageSize':25,'attribution':'App inferred from record type; earlier device identity was not recorded.'}
    def mount(self):
        app=self.ws.app
        def context(request:Request,tenant:str=''):return self.ws.authorize(self.ws.identity(request),tenant)
        @app.get('/admin/api/v2/farmers/{owner}/sharing')
        def sharing(owner:str,ctx=Depends(context)):
            from admin_community import sharing as report
            self.ws.owner(ctx,owner)
            return report(self.engine,owner)
        @app.get('/admin/api/v2/farmers/{owner}/apps')
        def apps(owner:str,ctx=Depends(context)):
            self.ws.owner(ctx,owner);return self.apps(owner)
        @app.get('/admin/api/v2/farmers/{owner}/apps/{app_id}/history')
        def history(owner:str,app_id:str,page:int=Query(1,ge=1),ctx=Depends(context)):
            self.ws.owner(ctx,owner);return self.history(owner,app_id,page)
        @app.get('/admin/api/v2/farmers/{owner}/learning')
        def report(owner:str,ctx=Depends(context)):
            self.ws.owner(ctx,owner);return self.read(owner)
        @app.post('/admin/api/v2/farmers/{owner}/learning/refresh')
        def refresh(owner:str,ctx=Depends(context)):
            self.ws.owner(ctx,owner)
            if not ctx['canWrite']:raise HTTPException(403,'Support access is view only')
            result=self.read(owner)
            if not result['linked']:raise HTTPException(409,'This farmer has no linked Moodle identity')
            if not result['configured']:raise HTTPException(409,'Moodle reporting is not configured')
            if result['attemptedAt'] and now()-result['attemptedAt']<60000:return result
            self.enqueue(owner)
            with self.engine.begin() as db:self.ws.log(db,ctx,'learning_refresh',owner)
            return self.read(owner)
        @app.get('/admin/api/v2/learning')
        def overview(ctx=Depends(context)):
            with self.engine.connect() as db:
                rows=[dict(r) for r in db.execute(select(learning).where(learning.c.owner.in_(ctx['owners']))).mappings()]
                heartbeat=db.scalar(select(worker.c.heartbeat).where(worker.c.id=='moodle'))
            names={p['id']:p['name'] or p['username'] for p in self.ws.dataset(ctx)[0]}
            return {'configured':bool(os.getenv('FARMER_MOODLE_REPORT_TOKEN')),'heartbeat':heartbeat,'people':[{'owner':r['owner'],'name':names.get(r['owner'],''),'checkedAt':r['checked'],'error':r['error'],'courses':json.loads(r['payload'])} for r in rows]}
