"""Server-observed sync health and restricted web support access."""
import time
import json
from typing import Any
from fastapi import HTTPException, Request
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import MetaData, Table, Column, String, Integer, Text, select, insert, update

meta = MetaData()
staff = Table('web_staff_roles', meta, Column('owner', String(36), primary_key=True), Column('role', String(16), nullable=False))
devices = Table('farmer_devices', meta, Column('owner', String(36), primary_key=True), Column('device', String(36), primary_key=True), Column('version', String(64), nullable=False), Column('last_sync', Integer, nullable=False))
changes = Table('admin_change_reasons', meta, Column('id', String(36), primary_key=True), Column('actor', String(36), nullable=False), Column('path', Text, nullable=False), Column('reason', Text, nullable=False), Column('created', Integer, nullable=False))

class InstalledApp(BaseModel):
    id: str = Field(pattern=r'^[a-z][a-z0-9-]{1,63}$')
    version: int = Field(ge=1, le=1000000)

class BrowserCapabilities(BaseModel):
    model_config = {'extra': 'forbid'}
    userAgent: str | None = Field(default=None, max_length=1024)
    cookiesEnabled: bool | None = None
    logicalProcessors: int | None = Field(default=None, ge=1, le=4096)
    maxTouchPoints: int | None = Field(default=None, ge=0, le=256)
    approximateMemoryGb: float | None = Field(default=None, gt=0, le=65536, allow_inf_nan=False)
    platform: str = Field(max_length=100)
    language: str = Field(max_length=64)
    online: bool
    screenWidth: int = Field(ge=0, le=100000)
    screenHeight: int = Field(ge=0, le=100000)
    pixelRatio: float = Field(gt=0, le=100, allow_inf_nan=False)
    timezoneOffsetMinutes: int = Field(ge=-840, le=840)
    standalone: bool

class SyncReport(BaseModel):
    settings: dict[str, Any] = Field(default_factory=dict)
    browser: BrowserCapabilities | None = None
    device: str = Field(pattern=r'^[a-f0-9-]{36}$')
    version: str = Field(min_length=1, max_length=64, pattern=r'^[a-zA-Z0-9.+_-]+$')
    receivedInboxIds: list[str] = Field(default_factory=list, max_length=2000)
    installedApps: list[InstalledApp] | None = Field(default=None, max_length=32)
    pendingChanges: int | None = Field(default=None, ge=0, le=1000000)
    conflicts: int | None = Field(default=None, ge=0, le=1000000)

    @field_validator('settings')
    @classmethod
    def safe_settings(cls, value):
        allowed = {'weatherEnabled', 'weatherHere', 'selectedFarm', 'areaUnit',
                   'mappingLanguage', 'reminders', 'syncMode', 'wallpaperPreset',
                   'homeHighContrast', 'animateIcons', 'launcherOrder', 'appOrder',
                   'glassOpacity', 'themeMode', 'preferredMapLayer', 'activeMapPack',
                   'mapEnabled', 'pushOptIn', 'backgroundSync', 'gpsCountry', 'customWallpaper'}
        if set(value) - allowed or len(json.dumps(value, allow_nan=False)) > 32768:
            raise ValueError('Unsupported or oversized device settings')
        if any(not (v is None or type(v) in (str, bool, int, float) or
                    isinstance(v, list) and len(v) <= 32 and
                    all(isinstance(item, str) and len(item) <= 64 for item in v))
               for v in value.values()):
            raise ValueError('Invalid device setting value')
        return value

class Operations:
    def __init__(self, app, identity=None):
        self.app, self.engine = app, app.state.engine
        meta.create_all(self.engine)

        @app.post('/sync/complete')
        def complete(body: SyncReport, request: Request):
            user = identity(request) if identity else app.state.oidc.resource_identity(request)
            if user['admin']: raise HTTPException(403, 'Farmer mobile sync only')
            with self.engine.begin() as db:
                app.state.oidc.state(db, user['id'], True)
                condition = (devices.c.owner == user['id']) & (devices.c.device == body.device)
                existing = db.execute(select(devices).where(condition)).first()
                values = {'version': body.version, 'last_sync': int(time.time()*1000)}
                if existing: db.execute(update(devices).where(condition).values(**values))
                else: db.execute(insert(devices).values(owner=user['id'], device=body.device, **values))
                from admin_farmer import record_inventory
                record_inventory(db,user['id'],body)
                if getattr(app.state,'workspace',None):
                    from admin_workspace import deliveries
                    # Older clients report no IDs: successful sync alone is not delivery.
                    db.execute(update(deliveries).where(deliveries.c.owner==user['id'],deliveries.c.record.in_(body.receivedInboxIds),deliveries.c.delivered.is_(None))
                        .values(delivered=int(time.time()*1000)))
            return {'recorded': True}

    def role(self, db, user):
        if not user['admin']: return 'farmer'
        return db.scalar(select(staff.c.role).where(staff.c.owner == user['id'])) or 'admin'

    def authorize(self, request, user, write=False):
        from uuid import uuid4
        with self.engine.begin() as db:
            tenancy = getattr(self.app.state, 'tenancy', None)
            if tenancy:
                from tenancy import control
                platform_owner = db.scalar(select(control.c.superadmin).where(control.c.id == 1))
                if platform_owner and platform_owner != user['id']:
                    raise HTTPException(403, 'Platform administration is restricted to the Superadmin; use tenant tools')
            role = self.role(db, user)
            if role not in {'admin', 'support'}: raise HTTPException(403, 'Web staff access required')
            if write and role != 'admin': raise HTTPException(403, 'Support access is view only')
            if write and request.url.path.startswith('/admin/identity/people/'):
                reason = request.headers.get('x-change-reason', '').strip()
                if not 10 <= len(reason) <= 500: raise HTTPException(422, 'Provide a reason of 10-500 characters for this account change')
                # This is an attempted change; existing identity audit records its outcome.
                db.execute(insert(changes).values(id=str(uuid4()), actor=user['id'], path=request.url.path, reason=reason, created=int(time.time()*1000)))
        return role

    def health(self, db, owner):
        rows = db.execute(select(devices).where(devices.c.owner==owner).order_by(devices.c.last_sync.desc()).limit(20)).mappings().all()
        return {'lastSuccessfulSync': rows[0]['last_sync'] if rows else None, 'appVersion': rows[0]['version'] if rows else None,
                'devices': [{'version':r['version'], 'lastSuccessfulSync':r['last_sync']} for r in rows]}
