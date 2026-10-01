"""Authenticated, bounded map extraction for the FarmerPlus test server.

Only Protomaps' fixed daily archive is fetched. Downloaded phone copies are
independent of this server cache and are never expired by this service.
"""
import hashlib
import json
import shutil
import threading
import time
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from fastapi import Depends, HTTPException, Request
from fastapi.responses import FileResponse
import map_packs as source

ATTRIBUTION = '© OpenStreetMap contributors · Protomaps · Natural Earth'
LICENSE = 'OpenStreetMap ODbL 1.0; Protomaps/PMTiles and Natural Earth source terms apply'


class MapDownloads:
    def __init__(self, root):
        self.root = Path(root) / 'prepared-maps'
        self.root.mkdir(parents=True, exist_ok=True)
        self.jobs = {}
        self.lock = threading.Lock()
        self.pool = ThreadPoolExecutor(max_workers=1)
        self.build = None
        self.checked = 0

    def latest(self):
        if not source.CLI.is_file():
            raise HTTPException(503, 'Map downloads are not available on this server yet.')
        with self.lock:
            if not self.build or time.monotonic() - self.checked > 3600:
                try:
                    self.build = source.latest()
                    self.checked = time.monotonic()
                except Exception:
                    raise HTTPException(503, 'The map source is unavailable. Please retry later.') from None
            return self.build

    @staticmethod
    def public(job):
        result = {k: v for k, v in job.items() if k not in {'owner', 'started'}}
        # Additive defaults keep prepared manifests from an older test build
        # usable while making the licensing and exact source build explicit.
        result['sourceBuild'] = result.get('sourceBuild') or result.get('build')
        result['attribution'] = ATTRIBUTION
        result['license'] = LICENSE
        return result

    def prepare(self, owner, region):
        key = self.latest()
        try:
            box = source.bounds(region)
        except ValueError as e:
            raise HTTPException(422, str(e)) from None
        identifier = hashlib.sha256((owner + region.model_dump_json() + key).encode()).hexdigest()[:32]
        with self.lock:
            existing = self.jobs.get(identifier)
            if existing and existing['state'] in {'queued', 'preparing', 'ready'}:
                return self.public(existing)
            if len(self.jobs) >= 1024 and not existing:
                raise HTTPException(503, 'The map server is busy. Please retry later.')
            manifest = self.root / (identifier + '.json')
            target = self.root / (identifier + '.pmtiles')
            if manifest.is_file() and target.is_file():
                saved = json.loads(manifest.read_text(encoding='utf-8'))
                if saved.get('owner') == owner and target.stat().st_size == saved.get('bytes'):
                    self.jobs[identifier] = saved
                    return self.public(saved)
            pending = [j for j in self.jobs.values() if j['state'] in {'queued', 'preparing'}]
            if len(pending) >= 3 or any(j['owner'] == owner for j in pending):
                raise HTTPException(429, 'A map is already being prepared. Please retry shortly.')
            size = sum(p.stat().st_size for p in self.root.glob('*.pmtiles'))
            if size + (len(pending) + 1) * source.LIMIT > 4 * 1024**3 or shutil.disk_usage(self.root).free < 1024**3:
                raise HTTPException(503, 'Map server storage is full. Existing phone maps are unaffected.')
            job = dict(id=identifier, owner=owner, state='queued', started=time.time(),
                       build=key, sourceBuild=key, attribution=ATTRIBUTION, license=LICENSE,
                       bounds=box, radius=region.radius, zoom=region.zoom)
            self.jobs[identifier] = job
            self.pool.submit(self.extract, identifier, region, key)
            return self.public(job)

    def extract(self, identifier, region, key):
        path = self.root / (identifier + '.pmtiles')
        job = self.jobs[identifier]
        try:
            job.update(state='preparing', started=time.time())
            source.run(region, key, path)
            size = path.stat().st_size
            if size < 127 or size > source.LIMIT:
                raise ValueError('Map size is unsupported. Choose a smaller area or less detail.')
            with path.open('rb') as stream:
                if stream.read(8) != b'PMTiles\x03':
                    raise ValueError('The map archive could not be verified.')
                stream.seek(0)
                sha = hashlib.file_digest(stream, 'sha256').hexdigest()
            ready = {**job, 'bytes': size, 'sha256': sha, 'state': 'ready'}
            manifest = self.root / (identifier + '.json')
            manifest.write_text(json.dumps(ready), encoding='utf-8')
            job.update(ready)
        except Exception:
            path.unlink(missing_ok=True)
            job.update(state='failed', error='Map preparation could not finish. Please retry with a smaller area or less detail.')

    def status(self, owner, identifier):
        job = self.jobs.get(identifier)
        if not job or job['owner'] != owner:
            raise HTTPException(404, 'Map preparation was not found. Please prepare again.')
        return self.public(job)


def register_map_downloads(app, root, identity, throttle):
    service = MapDownloads(root)
    app.state.map_downloads = service

    def farmer(request: Request):
        user = identity(request)
        if user['admin']:
            raise HTTPException(403, 'Use a farmer account for mobile maps.')
        return user

    @app.post('/maps/estimate')
    def estimate(region: source.Region, request: Request, user=Depends(farmer)):
        throttle(request, 'map-estimate:' + user['id'], force=True)
        build = service.latest()
        return dict(build=build, sourceBuild=build, attribution=ATTRIBUTION, license=LICENSE, estimatedBytes=None,
                    note='Exact file size is shown before download.')

    @app.post('/maps/prepare')
    def prepare(region: source.Region, request: Request, user=Depends(farmer)):
        throttle(request, 'map-prepare:' + user['id'], force=True)
        return service.prepare(user['id'], region)

    @app.get('/maps/jobs/{identifier}')
    def status(identifier: str, user=Depends(farmer)):
        return service.status(user['id'], identifier)

    @app.get('/maps/files/{identifier}')
    def download(identifier: str, user=Depends(farmer)):
        job = service.status(user['id'], identifier)
        if job['state'] != 'ready':
            raise HTTPException(409, 'Map is not ready yet.')
        return FileResponse(service.root / (job['id'] + '.pmtiles'), media_type='application/octet-stream')
