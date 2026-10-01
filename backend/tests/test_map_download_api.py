import hashlib
from concurrent.futures import Future
from fastapi.testclient import TestClient
from test_oidc import identity
from test_native_access import provision
import map_packs
from map_download_api import ATTRIBUTION, LICENSE, MapDownloads


class Immediate:
    def submit(self, fn, *args):
        fn(*args)
        return Future()


def test_map_auth_owner_isolation_and_verified_download(identity, monkeypatch, tmp_path):
    app, client, owner, session = provision(identity)
    headers = {'Authorization': 'Bearer ' + session['access_token']}
    cli = tmp_path / 'pmtiles'
    cli.touch()
    monkeypatch.setattr(map_packs, 'CLI', cli)
    monkeypatch.setattr(map_packs, 'latest', lambda: '20260914.pmtiles')
    content = b'PMTiles\x03' + b'fixture map bytes' * 10
    monkeypatch.setattr(map_packs, 'run', lambda r, key, path: path.write_bytes(content))
    service = app.state.map_downloads
    service.pool.shutdown()
    service.pool = Immediate()
    region = dict(lat=-29.8, lon=30.9, radius=1, zoom=12)
    assert client.post('/maps/prepare', json=region).status_code == 401
    estimate = client.post('/maps/estimate', json=region, headers=headers).json()
    assert estimate['build'] == estimate['sourceBuild'] == '20260914.pmtiles'
    assert estimate['attribution'] == ATTRIBUTION
    assert estimate['license'] == LICENSE
    job = client.post('/maps/prepare', json=region, headers=headers)
    assert job.status_code == 200, job.text
    job = job.json()
    assert job['state'] == 'ready' and 'owner' not in job
    assert job['build'] == job['sourceBuild'] == '20260914.pmtiles'
    assert job['attribution'] == ATTRIBUTION
    assert job['license'] == LICENSE
    assert job['sha256'] == hashlib.sha256(content).hexdigest()
    status = client.get('/maps/jobs/' + job['id'], headers=headers).json()
    assert status['attribution'] == ATTRIBUTION and status['license'] == LICENSE
    assert client.get('/maps/files/' + job['id'], headers=headers).content == content
    assert client.get('/maps/jobs/../../etc/passwd', headers=headers).status_code != 200
    # A server restart reuses a verified ready archive for the same owner.
    restarted = MapDownloads(service.root.parent)
    restored = restarted.prepare(owner, map_packs.Region(**region))
    assert restored['id'] == job['id']
    assert restored['sourceBuild'] == '20260914.pmtiles'
    assert restored['attribution'] == ATTRIBUTION and restored['license'] == LICENSE
    try:
        restarted.status('another-farmer', job['id'])
        assert False, 'Another farmer must not see the region metadata'
    except Exception as error:
        assert error.status_code == 404
    restarted.pool.shutdown()


def test_failed_extract_never_reports_ready(identity, monkeypatch, tmp_path):
    app, client, owner, session = provision(identity)
    cli = tmp_path / 'pmtiles'
    cli.touch()
    monkeypatch.setattr(map_packs, 'CLI', cli)
    monkeypatch.setattr(map_packs, 'latest', lambda: '20260914.pmtiles')
    monkeypatch.setattr(map_packs, 'run', lambda r, key, path: path.write_bytes(b'broken'))
    service = app.state.map_downloads
    service.pool.shutdown()
    service.pool = Immediate()
    headers = {'Authorization': 'Bearer ' + session['access_token']}
    job = client.post('/maps/prepare', json=dict(lat=0, lon=0, radius=1, zoom=12), headers=headers).json()
    assert job['state'] == 'failed'
    assert client.get('/maps/files/' + job['id'], headers=headers).status_code == 409
    assert not list(service.root.glob('*.pmtiles'))
