"""Loopback-only map preparation helper. Not a public tile proxy.
Deploy behind authenticated/rate-limited infrastructure before remote use.
Only the fixed public Protomaps daily archive is read; user URLs are never executed.
"""
import hashlib,json,math,os,re,subprocess,threading,time,urllib.request
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from fastapi import FastAPI,HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel,Field

ROOT=Path(__file__).resolve().parent
CACHE=ROOT/'data'/'map-packs'
CACHE.mkdir(parents=True,exist_ok=True)
CLI=Path(os.getenv('PMTILES_CLI',str(ROOT.parent/'tooling'/'pmtiles'/'pmtiles.exe')))
LIMIT=500*1024*1024
jobs={}
lock=threading.Lock()
pool=ThreadPoolExecutor(max_workers=1)
app=FastAPI(title='FarmerPlus local map preparation')

class Region(BaseModel):
    lat:float=Field(ge=-80,le=80,allow_inf_nan=False)
    lon:float=Field(ge=-180,le=180,allow_inf_nan=False)
    radius:int=Field(ge=1,le=10)
    zoom:int=Field(ge=12,le=15)

def bounds(r):
    dy=r.radius/111.195;dx=dy/math.cos(math.radians(r.lat))
    box=[r.lon-dx,r.lat-dy,r.lon+dx,r.lat+dy]
    if box[0]<-180 or box[2]>180:raise ValueError('Date-line regions are not supported')
    return box

def latest():
    request=urllib.request.Request('https://build-metadata.protomaps.dev/builds.json',headers={'User-Agent':'FarmerPlus-Map-Preparation/1.0','Accept':'application/json'})
    with urllib.request.urlopen(request,timeout=15) as f:items=json.load(f)
    items=items if isinstance(items,list) else items['builds']
    rows=[x for x in items if re.fullmatch(r'\d{8}\.pmtiles',x.get('key',''))]
    return sorted(rows,key=lambda x:x['key'],reverse=True)[0]['key']

def run(r,key,path,dry=False):
    args=[str(CLI),'extract','https://build.protomaps.com/'+key,str(path),'--bbox='+','.join(str(x) for x in bounds(r)),'--minzoom=0','--maxzoom='+str(r.zoom)]
    if dry:args+=['--dry-run']
    out=subprocess.run(args,capture_output=True,text=True,timeout=120 if dry else 900,env={**os.environ,'GOMEMLIMIT':'192MiB'},creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
    if out.returncode:raise ValueError('Map source could not be read. Try again later.')
    return out.stdout+'\n'+out.stderr

@app.post('/estimate')
def estimate(r:Region):
    if not CLI.is_file():raise HTTPException(503,'Map preparation is not configured on this server.')
    try:
        key=latest();out=run(r,key,CACHE/'estimate.pmtiles',True)
        matches=re.findall(r'archive size(?: of)?\s+([\d.]+)\s*([kMGT]?B)',out,re.I)
        if not matches:
            # Never fabricate a byte estimate from radius.
            return {'build':key,'bounds':bounds(r),'estimatedBytes':None,'note':'Exact size will be shown after preparation.'}
        value,unit=matches[-1]
        multiplier={'b':1,'kb':1000,'mb':1000000,'gb':1000000000,'tb':1000000000000}[unit.lower()]
        return {'build':key,'bounds':bounds(r),'estimatedBytes':int(float(value)*multiplier)}
    except Exception as e:raise HTTPException(503,str(e)) from None

def prepare(identifier,r,key):
    path=CACHE/(identifier+'.pmtiles')
    try:
        run(r,key,path)
        if path.stat().st_size>LIMIT:
            path.unlink();raise ValueError('Region exceeds 500 MB. Choose less detail.')
        with path.open('rb') as f:
            if f.read(7)!=b'PMTiles':raise ValueError('Invalid map archive')
        digest=hashlib.file_digest(path.open('rb'),'sha256').hexdigest()
        jobs[identifier].update(state='ready',bytes=path.stat().st_size,sha256=digest)
    except Exception as e:
        if path.exists():path.unlink()
        jobs[identifier].update(state='failed',error=str(e))

@app.post('/prepare')
def start(r:Region):
    if not CLI.is_file():raise HTTPException(503,'Map preparation is not configured.')
    try:key=latest()
    except Exception:raise HTTPException(503,'Cannot check the latest map build.') from None
    identifier=hashlib.sha256((r.model_dump_json()+key).encode()).hexdigest()[:32]
    with lock:
        if identifier not in jobs or jobs[identifier]['state']=='failed':
            if sum(x['state']=='preparing' for x in jobs.values())>=3:raise HTTPException(429,'Map preparation is busy. Try again shortly.')
            jobs[identifier]={'id':identifier,'state':'preparing','build':key,'bounds':bounds(r),'radius':r.radius,'zoom':r.zoom}
            pool.submit(prepare,identifier,r,key)
    return jobs[identifier]

@app.get('/jobs/{identifier}')
def status(identifier:str):
    if identifier not in jobs:raise HTTPException(404,'Map job not found; prepare again.')
    return jobs[identifier]

@app.get('/files/{identifier}')
def download(identifier:str):
    job=status(identifier)
    if job['state']!='ready':raise HTTPException(409,'Map is not ready')
    return FileResponse(CACHE/(identifier+'.pmtiles'),media_type='application/octet-stream',filename=identifier+'.pmtiles')
