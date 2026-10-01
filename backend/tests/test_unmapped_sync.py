from test_api import service, account, op, poly


def test_unmapped_area_sync_retry_and_parent_edit(service):
    client, _ = account(service, 'unmapped-area')
    farm = op(kind='farm', data={'name': 'Farm', 'points': poly([(0, 0), (4, 0), (4, 4), (0, 4)])})
    assert client.post('/sync/push', json=farm).status_code == 200
    field = op(kind='field', data={'name': 'Craal', 'farmId': farm['id'], 'manualAreaHa': 2})
    first = client.post('/sync/push', json=field)
    assert first.status_code == 200, first.text
    assert first.json()['record']['data']['manualAreaHa'] == 2
    assert client.post('/sync/push', json=field).json() == first.json()
    update = op(id=farm['id'], kind='farm', base_version=1, data={**farm['data'], 'name': 'Renamed farm'})
    assert client.post('/sync/push', json=update).status_code == 200
    invalid = op(kind='field', data={**field['data'], 'points': poly([(0, 0), (1, 1)])})
    assert client.post('/sync/push', json=invalid).status_code == 422
    outside = op(kind='field', data={**field['data'], 'points': poly([(8, 8), (9, 8), (9, 9)])})
    assert client.post('/sync/push', json=outside).status_code == 422
    deletion = op(id=farm['id'], kind='farm', base_version=2, data=update['data'], deleted=True)
    assert client.post('/sync/push', json=deletion).status_code == 422


def test_unmapped_parent_allows_unmapped_child_only(service):
    client, _ = account(service, 'unmapped-parent')
    farm = op(kind='farm', data={'name': 'Unmapped farm'})
    assert client.post('/sync/push', json=farm).status_code == 200
    child = {'name': 'Area', 'farmId': farm['id'], 'points': []}
    assert client.post('/sync/push', json=op(kind='field', data=child)).status_code == 200
    assert client.post('/sync/push', json=op(kind='field', data={**child, 'points': poly([(0, 0), (1, 0), (1, 1)])})).status_code == 422


def test_unmapped_area_still_requires_owned_parent(service):
    owner, _ = account(service, 'area-owner')
    other, _ = account(service, 'area-other')
    farm = op(kind='farm', data={'name': 'Owned farm'})
    assert owner.post('/sync/push', json=farm).status_code == 200
    assert other.post('/sync/push', json=op(kind='field', data={'name': 'Area', 'farmId': farm['id']})).status_code == 422
