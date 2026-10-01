"""Authenticated, bounded imagery proxy. No arbitrary URLs or provider secrets."""
from collections import OrderedDict
from datetime import date, timedelta
from threading import BoundedSemaphore, Lock
import time
import httpx
from fastapi import Depends, HTTPException, Query
from fastapi.responses import Response

LAYERS = {
    'rainfall': ('IMERG_Precipitation_Rate', 6),
    'vegetation': ('MODIS_Terra_NDVI_8Day', 9),
}
_cache = OrderedDict()
_lock = Lock()
_slots = BoundedSemaphore(4)


def mount(workspace):
    @workspace.app.get('/admin/api/v2/environment-tiles/{layer}/{z}/{x}/{y}.png')
    def tile(layer: str, z: int, x: int, y: int, observed: str = Query('', max_length=10),
             ctx=Depends(workspace.context_dependency)):
        if layer not in LAYERS: raise HTTPException(404, 'Unknown overlay')
        name, maxzoom = LAYERS[layer]
        if not 0 <= z <= maxzoom or not 0 <= x < 2**z or not 0 <= y < 2**z:
            raise HTTPException(422, 'Invalid tile')
        try:
            day = date.fromisoformat(observed) if observed else date.today()-timedelta(days=2)
            if not date(2001,1,1) <= day <= date.today(): raise ValueError()
        except ValueError: raise HTTPException(422, 'Choose a valid observation date')
        key=(layer,z,x,y,day.isoformat())
        with _lock:
            cached=_cache.get(key)
            if cached and cached[0]>time.monotonic():
                _cache.move_to_end(key)
                return Response(cached[1],media_type='image/png')
        if not _slots.acquire(timeout=15):raise HTTPException(503,'Overlay is busy; retry shortly')
        try:
            url=f'https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/{name}/default/{day}/GoogleMapsCompatible_Level{maxzoom}/{z}/{y}/{x}.png'
            with httpx.Client(timeout=12,follow_redirects=False) as client:
                with client.stream('GET',url) as reply:
                    if reply.status_code!=200:raise HTTPException(502,'Overlay unavailable for this date')
                    body=bytearray()
                    for chunk in reply.iter_bytes():
                        body.extend(chunk)
                        if len(body)>1048576:raise HTTPException(502,'Unexpected overlay response')
            if not body.startswith(b'\x89PNG\r\n\x1a\n'):raise HTTPException(502,'Overlay did not return an image')
            body=bytes(body)
            with _lock:
                _cache[key]=(time.monotonic()+3600,body)
                while len(_cache)>64:_cache.popitem(last=False)
            return Response(body,media_type='image/png')
        except httpx.HTTPError:
            raise HTTPException(502,'Overlay provider unavailable') from None
        finally:_slots.release()
