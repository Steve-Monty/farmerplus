"""Explicit, scoped source ingestion. No credentials or arbitrary fetch URLs from browsers."""
from __future__ import annotations
import csv
import hashlib
import io
import json
import math
import os
import re
import calendar
import time
from threading import Lock
from datetime import datetime, timedelta, timezone
from uuid import uuid4
import httpx
from fastapi import Depends, HTTPException, Query
from fastapi.responses import Response
from pydantic import Field
from sqlalchemy import MetaData, Table, Column, String, Text, BigInteger, Integer, Boolean, select, insert, update
from admin_workspace import Input, canonical, stamp

meta=MetaData()
sources=Table('admin_data_sources',meta,Column('scope',String(64),primary_key=True),Column('provider',String(32),primary_key=True),
    Column('enabled',Boolean,nullable=False),Column('revision',Integer,nullable=False),Column('checked',BigInteger),Column('error',Text,nullable=False))
observations=Table('admin_source_observations',meta,Column('id',String(64),primary_key=True),Column('scope',String(64),nullable=False),
    Column('provider',String(32),nullable=False),Column('owner',String(36),nullable=False),Column('farm',String(36),nullable=False),
    Column('observed',String(40),nullable=False),Column('imported',BigInteger,nullable=False),Column('data',Text,nullable=False))
jobs=Table('admin_source_jobs',meta,Column('id',String(36),primary_key=True),Column('scope',String(64),nullable=False),
    Column('provider',String(32),nullable=False),Column('actor',String(36),nullable=False),Column('at',BigInteger,nullable=False),
    Column('status',String(20),nullable=False),Column('count',Integer,nullable=False),Column('message',Text,nullable=False))

CATALOG={
 'places':dict(name='Place search',source='Geoapify',url='https://www.geoapify.com/address-autocomplete/',env=['FARMER_GEOAPIFY_KEY'],mode='Map service',
    purpose='Search public towns, addresses and places from the Atlas. Private farmer searches never go to this provider.',resolution='Place coordinates; not cadastral boundaries',setup='Register a free Geoapify project, retain attribution, and configure a server-side key. Free tier includes 3,000 credits/day; review current terms.',privacy='Only text entered in the separate Places search is sent to Geoapify.'),
 'weather':dict(name='Weather forecast',source='Open-Meteo',url='https://open-meteo.com/en/docs',env=['FARMER_OPENMETEO_KEY'],mode='API + import',
    purpose='Seven-day temperature, rainfall and wind forecast at a mapped farm.',resolution='Model grid; not a farm weather station',setup='Add a commercial Open-Meteo API key to the server. Review the provider licence before enabling.',privacy='Sends the farm centre to Open-Meteo.'),
 'rainfall':dict(name='Rainfall history',source='CHIRPS v3 · Climate Hazards Center',url='https://www.chc.ucsb.edu/data/chirps3',env=[],mode='Public raster + import',
    purpose='Monthly rainfall at the farm centre. Compare observations with the same calendar month.',resolution='0.05° grid; centroid sample',setup='No account required. Choose a completed month with a final published raster. Data may arrive weeks after month end.',privacy='Reads a public raster; does not send farm coordinates to an API.'),
 'vegetation':dict(name='Vegetation condition',source='Copernicus Sentinel-2',url='https://documentation.dataspace.copernicus.eu/APIs/SentinelHub/Statistical.html',env=['FARMER_COPERNICUS_CLIENT_ID','FARMER_COPERNICUS_CLIENT_SECRET'],mode='API + import',
    purpose='Cloud-masked NDVI over the mapped boundary, with valid-pixel coverage.',resolution='20 m processing grid; monthly window',setup='Create a Copernicus Data Space OAuth client and set both server environment variables. Check quota and processing terms.',privacy='Sends the mapped boundary to Copernicus.'),
 'fire':dict(name='Nearby fire detections',source='NASA FIRMS · VIIRS NOAA-20',url='https://firms.modaps.eosdis.nasa.gov/api/area/',env=['FARMER_FIRMS_MAP_KEY'],mode='API + import',
    purpose='Recent satellite heat detections in the farm bounding box plus 0.1° margin. Not an emergency-warning service.',resolution='VIIRS nominal 375 m detection; three-day window',setup='Request a NASA FIRMS MAP_KEY and add it to the server.',privacy='Sends the farm-area bounding box to NASA FIRMS.'),
 'water':dict(name='Water use',source='FAO WaPOR v3',url='https://www.fao.org/in-action/remote-sensing-for-water-productivity/wapor-data-access/en',env=[],mode='Public raster + import',
    purpose='Actual evapotranspiration and interception at the farm centre for a selected dekad.',resolution='L1 300 m grid; centroid sample, not irrigation-meter readings',setup='No account required. Enter the published raster period as YYYY-MM-D1, D2 or D3.',privacy='Reads a public FAO raster. No farm-boundary upload.'),
 'climate':dict(name='Climate history',source='NASA POWER',url='https://power.larc.nasa.gov/docs/services/api/temporal/daily/',env=[],mode='Public API + import',
    purpose='Daily temperature, rainfall and solar radiation for a selected completed month. Regional climate context, not a forecast.',resolution='Nearest 1° reference point sampled from NASA source grids; not a farm weather station',setup='No account required. Choose a completed month since 1984. Missing observations remain gaps.',privacy='Sends a rounded 1° reference location and requested dates to NASA POWER, not farm boundaries.'),
 'learning':dict(name='Learning outcomes',source='FarmerPlus Learning · Moodle',url='https://learn.agritec.earth',env=['FARMER_MOODLE_REPORT_TOKEN'],mode='API + import',
    purpose='Official course enrolment and completion for an existing linked Moodle identity.',resolution='Course completion; latest server response',setup='Provision a read-only Moodle web-service token with enrolment and completion reporting access. This is separate from learner sign-in.',privacy='Sends the linked Moodle user ID only to FarmerPlus Learning.'),
 'markets':dict(name='South African market prices',source='Your licensed market source',url='https://www.jse.co.za/trade/derivative-market/commodity-derivatives',env=[],mode='Import',
    purpose='Grains and fresh produce by commodity, market, grade, date, currency and unit. No mixed-unit averages.',resolution='A quoted market / grade / unit, not a farm-gate guarantee',setup='Import a permitted CSV from your grain or fresh-produce source. Retain licence and market attribution. No live price subscription is connected.',privacy='Imported rows stay within the selected organisation.'),
 'soil':dict(name='Soil laboratory results',source='Your laboratory',url='',env=[],mode='Import',purpose='Sample-level soil results with test method, depth and units.',resolution='A sample, not a whole-farm soil map',setup='Import a laboratory CSV with sample ID, test method and depth. Do not infer treatment from a single result.',privacy='Imported results stay within the selected organisation.'),
 'sensors':dict(name='Field sensors',source='Your device provider',url='',env=[],mode='Import',purpose='Device observations with timestamps and units; gaps are not zero.',resolution='Instrument location and measurement',setup='Import timestamped device data with a stable sensor ID. A device API can post the same import contract using an authorised session.',privacy='Imported results stay within the selected organisation.'),
 'cooperatives':dict(name='Cooperative directory',source='Attributed external directory',url='https://maps.coop',env=[],mode='Import',purpose='A separate contextual Atlas layer. Directory coverage is not a census or FarmerPlus membership.',resolution='Directory coordinates; verify locally',setup='Import a permitted directory CSV with name, latitude, longitude and source date. Retain licence attribution, including ODC-By for Cooperative World Map data.',privacy='External directory rows remain separate from FarmerPlus records.')}

FIELDS=['observedAt','metric','value','unit','source','sourceUrl','licence','resolution','quality','owner','farm','commodity','market','grade','currency','country','sampleId','method','depth','sensorId','name','lat','lon']
class SourceInput(Input):
    enabled:bool
    revision:int=Field(default=0,ge=0)
class ImportInput(Input):
    csv:str=Field(min_length=1,max_length=180000)
    commit:bool=False
class RefreshInput(Input):
    owner:str=Field(min_length=1,max_length=36)
    farm:str=Field(default='',max_length=36)
    period:str=Field(default='',max_length=20)
class PlaceInput(Input):
    text:str=Field(min_length=3,max_length=160)

ACCOUNT_LINKS={
 'places':('Free registration','https://myprojects.geoapify.com/'),
 'vegetation':('Free registration with quotas','https://dataspace.copernicus.eu/'),
 'fire':('Free email map key','https://firms.modaps.eosdis.nasa.gov/api/map_key/'),
 'weather':('Paid commercial subscription','https://open-meteo.com/en/pricing'),
 'learning':('Existing system access','https://learn.agritec.earth'),
}

def finite(value):
    try:
        result=float(value)
        if not math.isfinite(result):raise ValueError()
        return result
    except (ValueError,TypeError):raise ValueError('Use a finite numeric value')

def date_value(value):
    try:
        parsed=datetime.fromisoformat(value.replace('Z','+00:00'))
        if parsed.tzinfo is None:
            if len(value)!=10:raise ValueError()
            parsed=parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc).isoformat()
    except (ValueError,TypeError):raise ValueError('Use an ISO date or a timestamp with timezone')

class Providers:
    def __init__(self,workspace):
        self.ws=workspace;self.engine=workspace.engine
        self.place_lock=Lock();self.place_cache={};self.place_limits={}
        self.climate_lock=Lock();self.climate_cache={}
        from schema_migrations import apply_additive_schema
        apply_additive_schema(self.engine,meta,'20260915_02_admin_sources','Scoped source configuration, observations and ingestion history')
        self.mount()

    def catalog(self,provider):
        if provider not in CATALOG:raise HTTPException(404,'Unknown source')
        return CATALOG[provider]

    def normalized(self,provider,row,ctx):
        if set(row)-set(FIELDS):raise ValueError('Unexpected CSV columns; use the source template')
        row={k:str(v or '').strip() for k,v in row.items() if v is not None}
        for key in ['observedAt','metric','unit','source','licence','resolution','quality']:
            if not row.get(key):raise ValueError('Missing '+key)
        if any(len(v)>1000 for v in row.values()):raise ValueError('A cell exceeds 1,000 characters')
        if row.get('sourceUrl') and (not row['sourceUrl'].startswith('https://') or '@' in row['sourceUrl']):raise ValueError('Source URL must be a public HTTPS attribution link')
        row['observedAt']=date_value(row['observedAt'])
        owner=row.get('owner','');farm=row.get('farm','')
        if owner:self.ws.owner(ctx,owner)
        if farm:
            if not owner:raise ValueError('Farm requires its owner ID')
            self.farm(ctx,owner,farm)
        if provider not in {'markets','cooperatives'} and not owner:raise ValueError('A farmer owner ID is required')
        if provider!='cooperatives':row['value']=finite(row.get('value'))
        if provider=='markets':
            for key in ['commodity','market','grade','currency','country']:
                if not row.get(key):raise ValueError('Missing '+key)
            if row['country'].casefold() not in {'south africa','za','zaf'}:raise ValueError('This release supports South African market coverage')
            row['country']='South Africa'
            if not re.fullmatch('[A-Z]{3}',row['currency']):raise ValueError('Use a three-letter currency code')
            if row['value']<0:raise ValueError('A price cannot be negative')
        if provider=='soil':
            for k in ['sampleId','method','depth']:
                if not row.get(k):raise ValueError('Missing '+k)
        if provider=='sensors' and not row.get('sensorId'):raise ValueError('Missing sensorId')
        if provider in {'cooperatives','fire'} or row.get('lat') or row.get('lon'):
            row['lat']=finite(row.get('lat'));row['lon']=finite(row.get('lon'))
            if not -85<=row['lat']<=85 or not -180<=row['lon']<=180:raise ValueError('Coordinates are outside the map range')
        if provider=='cooperatives' and not row.get('name'):raise ValueError('Missing cooperative name')
        row['ingestion']='Imported; source supplied by administrator'
        return row

    def save(self,ctx,provider,rows,method):
        added=0
        with self.engine.begin() as db:
            # Serialize per scope/provider for safe, idempotent imports on SQLite and Postgres.
            exists=db.execute(select(sources).where(sources.c.scope==ctx['scope'],sources.c.provider==provider)).first()
            if not exists:db.execute(insert(sources).values(scope=ctx['scope'],provider=provider,enabled=False,revision=1,error=''))
            db.execute(update(sources).where(sources.c.scope==ctx['scope'],sources.c.provider==provider).values(checked=stamp(),error=''))
            for row in rows:
                key=hashlib.sha256(canonical([ctx['scope'],provider,row]).encode()).hexdigest()
                if db.execute(select(observations.c.id).where(observations.c.id==key)).first():continue
                db.execute(insert(observations).values(id=key,scope=ctx['scope'],provider=provider,owner=row.get('owner',''),farm=row.get('farm',''),
                    observed=row['observedAt'],imported=stamp(),data=canonical(row)));added+=1
            db.execute(insert(jobs).values(id=str(uuid4()),scope=ctx['scope'],provider=provider,actor=ctx['actor']['id'],at=stamp(),status='Completed',count=added,message=f'{method}: {added} new rows; {len(rows)-added} already present.'))
            self.ws.log(db,ctx,'source_'+method,provider,{'added':added})
        return {'added':added,'duplicates':len(rows)-added}

    def farm(self,ctx,owner,key):
        self.ws.owner(ctx,owner)
        _,rows=self.ws.dataset({**ctx,'owners':[owner]})
        farm=next((r for r in rows if r['kind']=='farm' and r['id']==key),None)
        if not farm:raise HTTPException(422,'Select a farm belonging to this farmer')
        return farm

    def refresh(self,provider,body,ctx):
        cat=self.catalog(provider)
        self.ws.owner(ctx,body.owner)
        if cat['mode'] in {'Import','Map service'}:raise HTTPException(422,'Use this source through its import or map-search interface')
        if any(not os.getenv(e) for e in cat['env']):raise HTTPException(409,'Server credentials are not configured. See source setup; never paste keys into this interface.')
        farm=None;lat=lon=None
        if provider!='learning':
            farm=self.farm(ctx,body.owner,body.farm)
            feature=self.ws.feature(farm)
            if not feature:raise HTTPException(422,'A valid mapped farm boundary is required')
            points=feature['geometry']['coordinates'][0][:-1]
            # Geographic vertex mean is an approximate centre, not a surveyed centroid.
            lon=sum(p[0] for p in points)/len(points);lat=sum(p[1] for p in points)/len(points)
        def row(metric,value,unit,at,**extra):
            return {'owner':body.owner,'farm':body.farm,'metric':metric,'value':finite(value),'unit':unit,'observedAt':date_value(at),
                'source':cat['source'],'sourceUrl':cat['url'],'licence':'Provider terms; see source link','resolution':cat['resolution'],
                'quality':'Provider observation; not field-verified','ingestion':'API',**extra}
        with httpx.Client(timeout=25,follow_redirects=False) as client:
            def get(url,**kwargs):
                response=client.get(url,**kwargs);response.raise_for_status();return response.json()
            if provider=='weather':
                data=get('https://customer-api.open-meteo.com/v1/forecast',params={'apikey':os.environ['FARMER_OPENMETEO_KEY'],'latitude':lat,'longitude':lon,'daily':'temperature_2m_max,temperature_2m_min,precipitation_sum,wind_speed_10m_max','timezone':'UTC','forecast_days':7})
                return [row(metric,v,data['daily_units'][metric],at,quality='Forecast, not observed weather') for metric,values in data['daily'].items() if metric!='time' for at,v in zip(data['daily']['time'],values) if v is not None]
            if provider=='climate':
                if not re.fullmatch(r'\d{4}-(0[1-9]|1[0-2])',body.period):raise HTTPException(422,'Enter a completed month as YYYY-MM')
                start=datetime.strptime(body.period,'%Y-%m')
                if start.year<1984 or start>=datetime.now().replace(day=1,hour=0,minute=0,second=0,microsecond=0):raise HTTPException(422,'Choose a completed month since 1984')
                end=start.replace(day=calendar.monthrange(start.year,start.month)[1])
                reference=(round(lon),round(lat),body.period)
                # Share a regional reference across nearby farms, not repeated sub-grid requests.
                with self.climate_lock:
                    cached=self.climate_cache.get(reference)
                    if cached and time.monotonic()-cached[0]<86400:data=cached[1]
                    else:
                        data=get('https://power.larc.nasa.gov/api/temporal/daily/point',params={'parameters':'T2M,T2M_MAX,T2M_MIN,PRECTOTCORR,ALLSKY_SFC_SW_DWN','community':'AG','longitude':reference[0],'latitude':reference[1],'start':start.strftime('%Y%m%d'),'end':end.strftime('%Y%m%d'),'format':'JSON','time-standard':'UTC'})
                        if len(self.climate_cache)>=128:self.climate_cache.pop(next(iter(self.climate_cache)))
                        self.climate_cache[reference]=(time.monotonic(),data)
                missing=data.get('header',{}).get('fill_value',-999);result=[]
                for metric,values in data['properties']['parameter'].items():
                    unit=data['parameters'][metric]['units']
                    for day,value in values.items():
                        if value is None or value==missing:continue
                        at=datetime.strptime(day,'%Y%m%d').date().isoformat()
                        result.append(row(metric,value,unit,at,quality='NASA regional estimate; not measured on this farm',referenceLon=reference[0],referenceLat=reference[1],licence='NASA POWER open data; acknowledgment required'))
                return result
            if provider=='fire':
                bbox=','.join(str(round(v,5)) for v in [max(-180,min(p[0] for p in points)-.1),max(-85,min(p[1] for p in points)-.1),min(180,max(p[0] for p in points)+.1),min(85,max(p[1] for p in points)+.1)])
                response=client.get(f'https://firms.modaps.eosdis.nasa.gov/api/area/csv/{os.environ["FARMER_FIRMS_MAP_KEY"]}/VIIRS_NOAA20_NRT/{bbox}/3');response.raise_for_status()
                values=list(csv.DictReader(io.StringIO(response.text)))
                if len(values)>10000:raise ValueError('Source returned too many observations')
                return [row('Fire radiative power',r['frp'],'MW',r['acq_date']+'T'+r['acq_time'].zfill(4)[:2]+':'+r['acq_time'].zfill(4)[2:]+':00Z',lat=finite(r['latitude']),lon=finite(r['longitude']),quality='Satellite detection; confidence '+r['confidence']) for r in values]
            if provider=='vegetation':
                token=client.post('https://identity.dataspace.copernicus.eu/auth/realms/CDSE/protocol/openid-connect/token',data={'grant_type':'client_credentials','client_id':os.environ['FARMER_COPERNICUS_CLIENT_ID'],'client_secret':os.environ['FARMER_COPERNICUS_CLIENT_SECRET']});token.raise_for_status()
                end=datetime.now(timezone.utc);start=end-timedelta(days=30)
                script='''//VERSION=3
function setup(){return {input:[{bands:["B04","B08","SCL","dataMask"]}],output:[{id:"ndvi",bands:1},{id:"dataMask",bands:1}]};}
function evaluatePixel(s){let ok=s.dataMask && [4,5,6,7].includes(s.SCL) && s.B08+s.B04>0;return {ndvi:[ok?(s.B08-s.B04)/(s.B08+s.B04):0],dataMask:[ok?1:0]};}'''
                response=client.post('https://sh.dataspace.copernicus.eu/statistics/v1',headers={'Authorization':'Bearer '+token.json()['access_token']},json={'input':{'bounds':{'geometry':feature['geometry']},'data':[{'type':'sentinel-2-l2a'}]},'aggregation':{'timeRange':{'from':start.isoformat(),'to':end.isoformat()},'aggregationInterval':{'of':'P1D'},'resx':.00018,'resy':.00018,'evalscript':script}});response.raise_for_status()
                result=[]
                for period in response.json().get('data',[]):
                    stats=period['outputs']['ndvi']['bands']['B0']['stats'];total=stats.get('sampleCount',0);valid=total-stats.get('noDataCount',0)
                    if valid and stats.get('mean') is not None:result.append(row('NDVI',stats['mean'],'index',period['interval']['from'],validPixelPercent=round(100*valid/total,1),quality='Cloud masked; partial coverage is possible'))
                return result
            if provider=='learning':
                with self.engine.connect() as db:person=db.execute(select(self.ws.students).where(self.ws.students.c.owner==body.owner)).mappings().first()
                if not person or not person['moodle_id']:raise HTTPException(409,'This farmer has no linked Moodle identity')
                def moodle(function,**params):
                    r=client.post('https://learn.agritec.earth/webservice/rest/server.php',data={'wstoken':os.environ['FARMER_MOODLE_REPORT_TOKEN'],'wsfunction':function,'moodlewsrestformat':'json',**params});r.raise_for_status();data=r.json()
                    if isinstance(data,dict) and 'exception' in data:raise ValueError('Moodle rejected the reporting request')
                    return data
                courses=moodle('core_enrol_get_users_courses',userid=person['moodle_id']);result=[]
                for course in courses[:50]:
                    state=moodle('core_completion_get_course_completion_status',courseid=course['id'],userid=person['moodle_id'])['completionstatus']
                    result.append(row(course['fullname'],1 if state['completed'] else 0,'completed',datetime.now(timezone.utc).isoformat(),courseId=course['id'],quality='Official Moodle completion at refresh time'))
                return result
        if provider=='rainfall':
            if not re.fullmatch(r'\d{4}-\d{2}',body.period):raise HTTPException(422,'Enter a published month as YYYY-MM')
            try:period=datetime.strptime(body.period,'%Y-%m')
            except ValueError:raise HTTPException(422,'Enter a real completed month')
            if not 1981<=period.year<=datetime.now().year or period>=datetime.now().replace(day=1,hour=0,minute=0,second=0,microsecond=0):raise HTTPException(422,'Select a completed month since 1981')
            url=f'https://data.chc.ucsb.edu/products/CHIRPS/v3.0/monthly/global/tifs/chirps-v3.0.{period:%Y.%m}.tif'
            value=self.raster(url,lon,lat)
            return [row('Monthly rainfall',value,'mm/month',period.date().isoformat(),quality='CHIRPS v3 final monthly raster; grid estimate',ingestion='Public raster')]
        if provider=='water':
            if not re.fullmatch(r'20\d{2}-(0[1-9]|1[0-2])-D[123]',body.period):raise HTTPException(422,'Enter a published WaPOR dekad as YYYY-MM-D1, D2 or D3')
            if datetime.strptime(body.period[:7]+f'-{1+(int(body.period[-1])-1)*10:02d}','%Y-%m-%d')>=datetime.now():raise HTTPException(422,'Select a completed WaPOR period')
            code='L1-AETI-D';url=f'https://storage.googleapis.com/fao-gismgr-wapor-3-data/DATA/WAPOR-3/MAPSET/{code}/WAPOR-3.{code}.{body.period}.tif'
            value=self.raster(url,lon,lat)
            return [row('Actual evapotranspiration and interception',value,'mm/day',body.period[:7]+f'-{1+(int(body.period[-1])-1)*10:02d}',quality='WaPOR dekadal daily mean; grid estimate',ingestion='Public raster')]
        raise HTTPException(422,'Unsupported refresh')

    def raster(self,url,lon,lat):
        import rasterio
        from rasterio.warp import transform
        # Constructed URLs only. No browser-supplied path, GDAL config or raster upload.
        with rasterio.Env(GDAL_HTTP_TIMEOUT='25',GDAL_HTTP_MAX_RETRY='0',GDAL_DISABLE_READDIR_ON_OPEN='EMPTY_DIR',CPL_VSIL_CURL_ALLOWED_EXTENSIONS='.tif'):
            with rasterio.open('/vsicurl/'+url) as dataset:
                x,y=transform('EPSG:4326',dataset.crs,[lon],[lat])
                value=next(dataset.sample([(x[0],y[0])],indexes=1,masked=True))[0]
                if getattr(value,'mask',False):raise ValueError('No data at this location')
                return finite(float(value)*dataset.scales[0]+dataset.offsets[0])

    def mount(self):
        app=self.ws.app;context=self.ws.context_dependency
        @app.post('/admin/api/v2/places')
        def places(body:PlaceInput,ctx=Depends(context)):
            # POST keeps typed locations out of URL/access logs; read-only authorization.
            with self.engine.connect() as db:enabled=db.scalar(select(sources.c.enabled).where(sources.c.scope==ctx['scope'],sources.c.provider=='places'))
            if not os.getenv('FARMER_GEOAPIFY_KEY') or not enabled:raise HTTPException(409,'Place search needs a Geoapify key and activation in Data & integrations. Farmer search works without it.')
            query=body.text.strip()
            if len(query)<3:raise HTTPException(422,'Enter at least three characters')
            now=time.monotonic();key=hashlib.sha256(canonical([ctx['scope'],query.casefold()]).encode()).hexdigest()
            with self.place_lock:
                cached=self.place_cache.get(key)
                if cached and now-cached[0]<86400:return cached[1]
                window=[t for t in self.place_limits.get(ctx['actor']['id'],[]) if now-t<60]
                if len(window)>=30:raise HTTPException(429,'Place-search limit reached. Wait one minute and try again.')
                self.place_limits[ctx['actor']['id']]=window+[now]
            try:
                with httpx.Client(timeout=12,follow_redirects=False) as client:
                    response=client.get('https://api.geoapify.com/v1/geocode/autocomplete',params={'text':query,'apiKey':os.environ['FARMER_GEOAPIFY_KEY'],'format':'json','limit':6,'lang':'en','bias':'countrycode:za'})
                    response.raise_for_status();rows=[]
                    for item in response.json().get('results',[])[:6]:
                        lon,lat=finite(item['lon']),finite(item['lat'])
                        if -180<=lon<=180 and -85<=lat<=85:rows.append({'label':str(item.get('formatted','Place'))[:300],'lon':lon,'lat':lat,'country':str(item.get('country',''))[:100]})
            except Exception:raise HTTPException(502,'Place search is unavailable. Your farmer records are unaffected; check the provider quota and configuration.')
            result={'places':rows,'attribution':'Powered by Geoapify · OpenStreetMap contributors'}
            with self.place_lock:
                if len(self.place_cache)>=500:self.place_cache.pop(next(iter(self.place_cache)))
                self.place_cache[key]=(now,result)
            return result

        @app.get('/admin/api/v2/map/observations')
        def map_observations(provider:str,period:str='',ctx=Depends(context)):
            self.catalog(provider)
            if period and not re.fullmatch(r'\d{4}-(0[1-9]|1[0-2])',period):raise HTTPException(422,'Use YYYY-MM for the observation month')
            query=select(observations).where(observations.c.scope==ctx['scope'],observations.c.provider==provider,
                (observations.c.owner=='')|observations.c.owner.in_(ctx['owners']))
            if period:query=query.where(observations.c.observed.startswith(period))
            with self.engine.connect() as db:
                rows=[dict(r)|{'data':json.loads(r['data'])} for r in db.execute(query.order_by(observations.c.observed.desc(),observations.c.imported.desc()).limit(5001)).mappings()]
            return {'observations':rows[:5000],'truncated':len(rows)>5000,'period':period,'checkedAt':stamp()}

        @app.get('/admin/api/v2/sources')
        def listing(ctx=Depends(context)):
            with self.engine.connect() as db:
                configs={r['provider']:dict(r) for r in db.execute(select(sources).where(sources.c.scope==ctx['scope'])).mappings()}
                recent=[dict(r) for r in db.execute(select(jobs).where(jobs.c.scope==ctx['scope']).order_by(jobs.c.at.desc()).limit(30)).mappings()]
            return {'sources':[{'id':key,**cat,'access':ACCOUNT_LINKS.get(key,('No registration' if cat['mode']!='Import' else 'Permitted data import',''))[0],
                'registerUrl':ACCOUNT_LINKS.get(key,('',''))[1],'configured':all(os.getenv(e) for e in cat['env']),
                **configs.get(key,{'enabled':False,'revision':0,'checked':None,'error':''})} for key,cat in CATALOG.items()],'jobs':recent}

        @app.put('/admin/api/v2/sources/{provider}')
        def configure(provider:str,body:SourceInput,ctx=Depends(context)):
            cat=self.catalog(provider)
            if body.enabled and (cat['mode']=='Import' or any(not os.getenv(e) for e in cat['env'])):raise HTTPException(409,'Live refresh is not configured. CSV import is available without enabling a connector.')
            with self.engine.begin() as db:
                current=db.execute(select(sources).where(sources.c.scope==ctx['scope'],sources.c.provider==provider)).mappings().first()
                if current:
                    changed=db.execute(update(sources).where(sources.c.scope==ctx['scope'],sources.c.provider==provider,sources.c.revision==body.revision).values(enabled=body.enabled,revision=body.revision+1))
                    if not changed.rowcount:raise HTTPException(409,'Source changed; refresh and review it')
                elif body.revision==0:db.execute(insert(sources).values(scope=ctx['scope'],provider=provider,enabled=body.enabled,revision=1,error=''))
                else:raise HTTPException(409,'Refresh the source configuration')
                self.ws.log(db,ctx,'source_configured',provider,{'enabled':body.enabled})
            return {'saved':True}

        @app.get('/admin/api/v2/sources/{provider}/template')
        def template(provider:str,ctx=Depends(context)):
            if self.catalog(provider)['mode']=='Map service':raise HTTPException(422,'Place search does not import observations')
            return Response(','.join(FIELDS)+'\r\n',media_type='text/csv',headers={'Content-Disposition':f'attachment; filename="farmerplus-{provider}-template.csv"'})

        @app.post('/admin/api/v2/sources/{provider}/import')
        def ingest(provider:str,body:ImportInput,ctx=Depends(context)):
            if self.catalog(provider)['mode']=='Map service':raise HTTPException(422,'Place search does not import observations')
            reader=csv.DictReader(io.StringIO(body.csv.lstrip('\ufeff')))
            if not reader.fieldnames or len(reader.fieldnames)!=len(set(reader.fieldnames)):raise HTTPException(422,'Use a CSV with unique column headers')
            rows=[];errors=[]
            for i,raw in enumerate(reader,2):
                if i>501:raise HTTPException(422,'Import at most 500 rows per batch')
                try:rows.append(self.normalized(provider,raw,ctx))
                except ValueError as exc:errors.append({'row':i,'message':str(exc)})
            if not rows and not errors:errors.append({'row':2,'message':'No data rows found'})
            if errors:return {'valid':False,'errors':errors[:50],'count':len(rows),'preview':rows[:10]}
            if not body.commit:return {'valid':True,'errors':[],'count':len(rows),'preview':rows[:10]}
            return {'valid':True,**self.save(ctx,provider,rows,'import')}

        @app.post('/admin/api/v2/sources/{provider}/refresh')
        def refresh(provider:str,body:RefreshInput,ctx=Depends(context)):
            self.catalog(provider)
            with self.engine.connect() as db:enabled=db.scalar(select(sources.c.enabled).where(sources.c.scope==ctx['scope'],sources.c.provider==provider))
            if not enabled:raise HTTPException(409,'Review source terms and privacy, then enable live refresh')
            try:return self.save(ctx,provider,self.refresh(provider,body,ctx),'refresh')
            except HTTPException:raise
            except Exception:
                message='Source refresh failed. Check credentials, quota, selected period and coverage. Previous observations are retained.'
                with self.engine.begin() as db:
                    db.execute(update(sources).where(sources.c.scope==ctx['scope'],sources.c.provider==provider).values(error=message))
                    db.execute(insert(jobs).values(id=str(uuid4()),scope=ctx['scope'],provider=provider,actor=ctx['actor']['id'],at=stamp(),status='Failed',count=0,message=message))
                raise HTTPException(502,message)

        @app.get('/admin/api/v2/observations')
        def read_observations(provider:str='',owner:str='',farm:str='',limit:int=Query(200,ge=1,le=1000),before:str=Query('',max_length=64),before_id:str=Query('',max_length=64),ctx=Depends(context)):
            query=select(observations).where(observations.c.scope==ctx['scope'])
            if provider:self.catalog(provider);query=query.where(observations.c.provider==provider)
            if owner:self.ws.owner(ctx,owner);query=query.where(observations.c.owner==owner)
            if farm:query=query.where(observations.c.farm==farm)
            query=query.where((observations.c.owner=='')|observations.c.owner.in_(ctx['owners']))
            if bool(before)!=bool(before_id):raise HTTPException(422,'Both history cursor fields are required')
            if before:query=query.where((observations.c.observed<before)|((observations.c.observed==before)&(observations.c.id<before_id)))
            with self.engine.connect() as db:rows=[dict(r)|{'data':json.loads(r['data'])} for r in db.execute(query.order_by(observations.c.observed.desc(),observations.c.id.desc()).limit(limit+1)).mappings()]
            more=len(rows)>limit;page=rows[:limit]
            return {'observations':page,'truncated':more,'nextCursor':{'before':page[-1]['observed'],'before_id':page[-1]['id']} if more else None,'checkedAt':stamp()}
