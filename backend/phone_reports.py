"""Owner-scoped, idempotent phone diagnostics. ACK follows transaction commit."""
import hashlib,json,time
from uuid import UUID
from typing import Literal
from pydantic import BaseModel,ConfigDict,Field,field_validator
from fastapi import Depends,HTTPException,Query,Request
from sqlalchemy import MetaData,Table,Column,String,Text,BigInteger,select,insert,desc
from sqlalchemy.exc import IntegrityError
from schema_migrations import apply_additive_schema

meta=MetaData()
reports=Table('farmer_phone_reports',meta,Column('owner',String(36),primary_key=True),Column('device',String(36),primary_key=True),Column('report',String(36),primary_key=True),Column('digest',String(64),nullable=False),Column('payload',Text,nullable=False),Column('received',BigInteger,nullable=False))
FIELDS=set('manufacturer brand model product device board hardware bootloader androidVersion sdk securityPatch buildId buildDisplay buildFingerprint buildType buildTags buildTime kernel architecture supportedAbis supported64BitAbis supported32BitAbis processors is64Bit appHeapMaxBytes appHeapUsedBytes totalRamBytes availableRamBytes lowMemory ramThresholdBytes storageTotalBytes storageFreeBytes storageAvailableBytes externalStorageTotalBytes externalStorageAvailableBytes batteryPercent batteryStatus batteryHealth batteryTemperatureC batteryVoltageMv batteryTechnology batteryPlugged batteryPresent powerSave interactive uptimeMs elapsedRealtimeMs widthPixels heightPixels densityDpi density scaledDensity xdpi ydpi refreshRate fontScale locale timezone timezoneOffsetMinutes autoTime autoTimezone developerOptions adbEnabled screenTimeoutMs deviceSecure keyguardLocked encryptionStatus networkConnected networkValidated networkMetered networkRoaming networkVpn downstreamKbps upstreamKbps transports locationEnabled notificationsEnabled cameraFeature microphoneFeature gpsFeature nfcFeature bluetoothFeature touchscreenFeature biometricFeature installer packageName versionName versionCode targetSdk minSdk debuggable firstInstallTime lastUpdateTime apkBytes'.split())
PERMISSIONS=set('camera microphone fineLocation coarseLocation backgroundLocation notifications bluetoothConnect readMediaImages readMediaAudio readMediaVideo'.split())
FIELDS.update({'phoneIdentifier','phoneIdentifierType','androidId'})
class Strict(BaseModel):model_config=ConfigDict(extra='forbid')
class PhoneReport(Strict):
    schemaVersion:Literal[1]=1
    reportId:UUID
    deviceId:UUID
    capturedAt:int=Field(ge=0)
    technical:dict[str,str|int|float|bool|None]=Field(max_length=100)
    permissions:dict[str,Literal['granted','denied','not_required','unavailable']]=Field(max_length=16)
    unavailable:list[Literal['imei','hardwareSerial','macAddress','rootAttestation']]=Field(default_factory=list,max_length=4)
    @field_validator('technical')
    @classmethod
    def facts(cls,v):
        import math
        if any(k not in FIELDS or isinstance(x,str) and len(x)>512 or isinstance(x,float) and not math.isfinite(x) for k,x in v.items()):raise ValueError('Unsupported technical field')
        return v
    @field_validator('permissions')
    @classmethod
    def permissions_known(cls,v):
        if set(v)-PERMISSIONS:raise ValueError('Unsupported permission')
        return v

class PhoneReporting:
    def __init__(self,ws):
        self.ws,self.engine=ws,ws.engine
        apply_additive_schema(self.engine,meta,'20260916_04_phone_reports','Acknowledged owner-scoped technical phone snapshots')
        self.mount()
    def save(self,owner,body):
        payload=json.dumps(body.model_dump(mode='json'),sort_keys=True,separators=(',',':'),allow_nan=False)
        if len(payload.encode())>32768:raise HTTPException(413,'Phone report too large')
        digest=hashlib.sha256(payload.encode()).hexdigest();device=str(body.deviceId);rid=str(body.reportId)
        condition=(reports.c.owner==owner)&(reports.c.device==device)&(reports.c.report==rid)
        def existing(db):return db.execute(select(reports).where(condition)).mappings().first()
        try:
            with self.engine.begin() as db:
                row=existing(db)
                if not row:
                    # Cap newly created reports to one per device per 30 seconds; retries are never throttled.
                    previous=db.scalar(select(reports.c.received).where(reports.c.owner==owner,reports.c.device==device).order_by(desc(reports.c.received)).limit(1))
                    received=int(time.time()*1000)
                    if previous and received-previous<30000:raise HTTPException(429,'Retry this report shortly')
                    db.execute(insert(reports).values(owner=owner,device=device,report=rid,digest=digest,payload=payload,received=received))
                    row={'digest':digest,'received':received}
                if row['digest']!=digest:raise HTTPException(409,'Report ID already contains different data')
        except IntegrityError:
            with self.engine.connect() as db:row=existing(db)
            if not row or row['digest']!=digest:raise HTTPException(409,'Conflicting phone report')
        return {'ack':'y','reportId':rid,'deviceId':device,'owner':owner,'receivedAt':row['received']}
    def mount(self):
        app=self.ws.app
        @app.post('/sync/phone-report')
        def submit(body:PhoneReport,request:Request):
            user=app.state.oidc.resource_identity(request)
            if user['admin']:raise HTTPException(403,'Farmer phone reports only')
            with self.engine.begin() as db:app.state.oidc.state(db,user['id'],True)
            return self.save(user['id'],body)
        def context(request:Request,tenant:str=''):return self.ws.authorize(self.ws.identity(request),tenant)
        @app.get('/admin/api/v2/farmers/{owner}/phones')
        def phones(owner:str,page:int=Query(1,ge=1),ctx=Depends(context)):
            self.ws.owner(ctx,owner)
            from sqlalchemy import func
            with self.engine.connect() as db:
                total=db.scalar(select(func.count()).select_from(reports).where(reports.c.owner==owner))
                rows=list(db.execute(select(reports).where(reports.c.owner==owner).order_by(desc(reports.c.received),reports.c.report).offset((page-1)*10).limit(10)).mappings())
            return {'reports':[{'reportId':r['report'],'deviceId':r['device'],'receivedAt':r['received'],'ack':'y',**json.loads(r['payload'])} for r in rows],'total':total,'page':page,'pageSize':10,'authority':'Device-reported snapshot; not independently attested'}
