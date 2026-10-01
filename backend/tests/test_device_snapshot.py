import pytest
from pydantic import ValidationError
from operations import SyncReport
from test_admin_workspace import workspace
from sqlalchemy import select
from admin_farmer import inventory


def test_device_snapshot_persists_downloaded_apps_settings_and_version(workspace, monkeypatch):
    app, admin, client, _, _, farmer, _, _ = workspace
    owner = farmer['owner']
    monkeypatch.setattr(app.state.oidc, 'resource_identity', lambda _: {'id': owner, 'admin': False})
    body = {'device': '00000000-0000-0000-0000-000000000001', 'version': '1.2.3+45',
            'installedApps': [{'id': 'soil-notebook', 'version': 7}],
            'pendingChanges': 2, 'conflicts': 1,
            'settings': {'weatherEnabled': True, 'gpsCountry': 'South Africa'}}
    response = client.post('/sync/complete', json=body)
    assert response.status_code == 200, response.text
    import json
    with app.state.engine.connect() as db:
        saved = json.loads(db.execute(select(inventory.c.payload).where(
            inventory.c.owner == owner)).scalar_one())
    assert saved['apps'] == body['installedApps']
    assert saved['settings'] == body['settings']
    assert saved['pending'] == 2 and saved['conflicts'] == 1
    report = admin.get('/admin/api/v2/farmers/' + owner + '/apps').json()
    assert any(row['id'] == 'soil-notebook' for row in report['apps'])
    assert report['devices'][0]['settings'] == body['settings']
    assert report['devices'][0]['version'] == body['version']
    assert admin.get('/admin/api/v2/farmers/' + owner + '/apps/soil-notebook/history').status_code == 200


@pytest.mark.parametrize('settings', [
    {'syncToken': 'secret'}, {'weatherEnabled': {'nested': 'value'}},
    {'gpsCountry': 'x' * 33000},
])
def test_snapshot_rejects_secrets_and_unbounded_values(settings):
    with pytest.raises(ValidationError):
        SyncReport(device='00000000-0000-0000-0000-000000000001',
                   version='1', settings=settings)
