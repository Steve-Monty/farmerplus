from test_api import service, account, op


def test_places_and_crop_seasons_roundtrip_with_owned_context(service):
    client, _ = account(service, 'places-seasons')
    farm = op(kind='farm', data={'name': 'Farm One'})
    area = op(kind='field', data={'name': 'Craal', 'farmId': farm['id']})
    for record in [farm, area]:
        assert client.post('/sync/push', json=record).status_code == 200
    place = op(kind='pin', data={'name': 'North gate', 'type': 'Gate',
        'farmId': farm['id'], 'fieldId': area['id'], 'lat': -26.0565, 'lon': 28.0697,
        'color': '#007f78'})
    season = op(kind='season', data={'name': 'Spring maize', 'crop': 'Maize',
        'farmId': farm['id'], 'fieldId': area['id'], 'start': '2026-09-17', 'status': 'Planned'})
    for record in [place, season]:
        response = client.post('/sync/push', json=record)
        assert response.status_code == 200, response.text
        assert client.post('/sync/push', json=record).json() == response.json()
    received = {r['id']: r for r in client.get('/sync/pull').json()['records']}
    assert received[place['id']]['data']['farmId'] == farm['id']
    assert not received[place['id']]['data'].get('fieldId')
    assert received[place['id']]['data']['lat'] == -26.0565
    assert received[place['id']]['data']['color'] == '#007f78'
    assert received[season['id']]['data']['fieldId'] == area['id']
    assert received[season['id']]['data']['crop'] == 'Maize'
    assert all(received[r['id']]['version'] == 1 for r in [place, season])
    other, _ = account(service, 'other-places-seasons')
    assert other.get('/sync/pull').json()['records'] == []
    for record in [place, season]:
        assert other.post('/sync/push', json=op(kind=record['kind'], data=record['data'])).status_code == 422


def test_online_signin_location_updates_one_registration_record(service):
    client, _ = account(service, 'signin-location')
    registration = op(kind='pin', data={
        'name': 'Registration location', 'purpose': 'registration',
        'lat': -26.0565, 'lon': 28.0697, 'accuracy': 12,
        'capturedAt': '2026-09-17T14:00:00Z',
        'source': 'Device GPS — verified online sign-in'})
    first = client.post('/sync/push', json=registration)
    assert first.status_code == 200
    changed = op(
        id=registration['id'], kind='pin', base_version=1,
        data={**registration['data'], 'lat': -26.0570,
              'capturedAt': '2026-09-17T15:00:00Z'})
    second = client.post('/sync/push', json=changed)
    assert second.status_code == 200
    assert second.json()['record']['version'] == 2
    received = [r for r in client.get('/sync/pull').json()['records']
                if r['kind'] == 'pin' and r['data'].get('purpose') == 'registration']
    assert len(received) == 1
    assert received[0]['id'] == registration['id']
    assert received[0]['data']['lat'] == -26.0570
