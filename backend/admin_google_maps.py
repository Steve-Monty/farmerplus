"""Google's official Map Tiles API; key and sessions remain server-side."""
import math
import os
import time
from pathlib import Path
from threading import Lock, BoundedSemaphore
from collections import defaultdict
import httpx
from fastapi import Depends, HTTPException, Query
from fastapi.responses import Response
from pydantic import BaseModel, SecretStr, ConfigDict
import re

class KeyInput(BaseModel):
    model_config=ConfigDict(extra='forbid')
    key: SecretStr

_sessions={}
_lock=Lock()
_slots=BoundedSemaphore(12)
_usage=defaultdict(lambda: [0,0])
TYPES={'roadmap','satellite','hybrid','terrain'}

def key():
    try:return Path(os.getenv('FARMER_GOOGLE_MAPS_KEY_FILE','/run/secrets/farmerplus-maps/key')).read_text().strip()
    except OSError:return ''

def budget(actor):
    minute=int(time.time()//60)
    with _lock:
        if _usage[actor][0]!=minute:_usage[actor]=[minute,0]
        _usage[actor][1]+=1
        if _usage[actor][1]>1200:raise HTTPException(429,'Map request limit reached; please wait a minute')
        if len(_usage)>1000:
            for a in list(_usage):
                if _usage[a][0]<minute-1:del _usage[a]

def request(path,params,body=None):
    secret=key()
    if not secret:raise HTTPException(503,'Google Maps setup is not complete')
    if not _slots.acquire(blocking=False):raise HTTPException(503,'Map service is busy; retry shortly')
    try:
        with httpx.Client(timeout=12,follow_redirects=False) as client:
            r=client.request('POST' if body else 'GET','https://tile.googleapis.com/'+path,params={**params,'key':secret},json=body)
        if r.status_code!=200:raise HTTPException(502,'Google Maps could not supply this view; check coverage or API setup')
        return r
    except httpx.HTTPError:raise HTTPException(502,'Google Maps is temporarily unavailable') from None
    finally:_slots.release()

def session(kind):
    if kind not in TYPES:raise HTTPException(422,'Unknown Google map type')
    # Session tokens may be retained; map imagery is never stored on the server.
    with _lock:
        existing=_sessions.get(kind)
        if existing and existing['expiry']>time.time()+60:return existing
    body={'mapType':'satellite' if kind=='hybrid' else kind,'language':'en-US','region':'ZA'}
    if kind in {'hybrid','terrain'}:body['layerTypes']=['layerRoadmap']
    try:
        data=request('v1/createSession',{},body).json()
        result={'session':data['session'],'expiry':float(data['expiry']),
                'tileWidth':int(data['tileWidth']),'tileHeight':int(data['tileHeight']),
                'imageFormat':data['imageFormat']}
        if result['tileWidth'] not in {256,512}:raise ValueError()
    except (ValueError,KeyError,TypeError):raise HTTPException(502,'Unexpected Google Maps session response') from None
    with _lock:_sessions[kind]=result
    return result

def mount(ws):
    @ws.app.get('/admin/api/v2/google-maps/config')
    def config(ctx=Depends(ws.context_dependency)):
        return {'configured':bool(key()),'canConfigure':ctx['platform'] and ctx['canWrite']}

    @ws.app.post('/admin/api/v2/google-maps/config')
    def configure(body:KeyInput,ctx=Depends(ws.context_dependency)):
        if not ctx['platform'] or not ctx['canWrite']:raise HTTPException(403,'Platform administrator required')
        value=body.key.get_secret_value().strip()
        if not re.fullmatch(r'AIza[A-Za-z0-9_-]{35}',value):raise HTTPException(422,'Enter a valid Google API key')
        path=Path(os.getenv('FARMER_GOOGLE_MAPS_KEY_FILE','/run/secrets/farmerplus-maps/key'))
        # A private mounted directory is provisioned by the deployment, never by a user path.
        if not path.parent.is_dir():raise HTTPException(503,'Private Maps storage is not provisioned')
        with _lock:
            temp=path.with_name('key.pending')
            fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
            with os.fdopen(fd,'w') as stream:stream.write(value)
            os.replace(temp,path);_sessions.clear()
        with ws.engine.begin() as db:ws.log(db,ctx,'google_maps_configured',details={'provider':'Google Map Tiles'})
        return {'configured':True}

    @ws.app.get('/admin/api/v2/google-maps/viewport')
    def viewport(kind:str='satellite',zoom:int=Query(4,ge=0,le=22),north:float=Query(85,ge=-85,le=85),
                 south:float=Query(-85,ge=-85,le=85),east:float=Query(179.99,ge=-180,le=180),
                 west:float=Query(-179.99,ge=-180,le=180),ctx=Depends(ws.context_dependency)):
        if not all(math.isfinite(v) for v in [north,south,east,west]) or south>=north:raise HTTPException(422,'Invalid viewport')
        budget(ctx['actor']['id']);s=session(kind)
        try:
            data=request('tile/v1/viewport',{'session':s['session'],'zoom':zoom,'north':north,'south':south,'east':east,'west':west}).json()
            return {'copyright':str(data['copyright']), 'maxZoomRects':data.get('maxZoomRects',[]),'tileSize':s['tileWidth']}
        except (ValueError,KeyError,TypeError):raise HTTPException(502,'Google Maps attribution unavailable') from None

    @ws.app.get('/admin/api/v2/google-maps/tiles/{kind}/{z}/{x}/{y}')
    def tile(kind:str,z:int,x:int,y:int,ctx=Depends(ws.context_dependency)):
        if not 0<=z<=22 or not 0<=x<2**z or not 0<=y<2**z:raise HTTPException(422,'Invalid tile')
        budget(ctx['actor']['id']);s=session(kind)
        r=request(f'v1/2dtiles/{z}/{x}/{y}',{'session':s['session']})
        body=r.content
        if len(body)>2097152 or not (body.startswith(b'\xff\xd8') or body.startswith(b'\x89PNG\r\n\x1a\n')):raise HTTPException(502,'Unexpected map image')
        # No persistence, prefetch, offline packs, or exports of Google imagery.
        return Response(body,media_type='image/png' if body.startswith(b'\x89PNG') else 'image/jpeg',headers={'Cache-Control':'no-store'})
