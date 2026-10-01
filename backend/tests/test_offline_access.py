import time
from fastapi.testclient import TestClient
from test_oidc import identity, spec


def native(identity):
    app, provider, login = identity
    admin, _ = login('admin_offline', True)
    farmer, owner = login('offline_farmer')
    assert admin.post('/admin/identity/applications', json=spec(scopes=['openid','farmerplus.identity','farm:read','farm:write'])).status_code == 200
    with app.state.engine.begin() as db:
        subject = app.state.oidc.mapped(db, owner)['student_id']
    provider.token = {'active':True,'sub':subject,'client_id':'fixture-native','aud':['farmerplus-api'],
                      'scope':'farm:read farm:write','exp':int(time.time())+300,'ext':{'account_epoch':0}}
    client = TestClient(app, base_url='https://app.farmerplus.test', headers={'Authorization':'Bearer fixture-offline-token'})
    return app, provider, farmer, client, owner, subject


def test_verifier_requires_native_session_and_current_password(identity):
    app, provider, browser, client, owner, subject = native(identity)
    body = {'current_password':'Fixture-only-Password'}
    assert browser.post('/auth/offline/verify', json=body).status_code == 403
    assert client.post('/auth/offline/verify', json={'current_password':'Wrong-Password'}).status_code == 401
    response = client.post('/auth/offline/verify', json=body)
    assert response.status_code == 200
    assert response.json() == {'verified':True,'owner':owner,'studentId':subject,'username':'offline_farmer','credentialEpoch':0}
    assert 'password' not in response.text and 'salt' not in response.text
    assert response.headers['cache-control'] == 'no-store'
    provider.token['client_id'] = 'other'
    assert client.post('/auth/offline/verify', json=body).status_code == 401


def test_password_change_proof_advances_version_and_old_session_is_rejected(identity):
    app, provider, browser, client, owner, subject = native(identity)
    changed = client.post('/auth/change', json={'current_password':'Fixture-only-Password','password':'New-Fixture-Password'})
    assert changed.status_code == 200
    assert changed.json()['verified'] is True
    assert changed.json()['credentialEpoch'] == 1
    assert changed.json()['studentId'] == subject
    assert client.get('/auth/me').status_code == 401
    assert client.post('/auth/offline/verify', json={'current_password':'Fixture-only-Password'}).status_code == 401
    provider.token['ext']['account_epoch'] = 1
    assert client.get('/auth/me').json()['credentialEpoch'] == 1
    assert client.post('/auth/offline/verify', json={'current_password':'Fixture-only-Password'}).status_code == 401
    assert client.post('/auth/offline/verify', json={'current_password':'New-Fixture-Password'}).json()['credentialEpoch'] == 1


def test_password_verification_rate_limited(identity):
    app, provider, browser, client, owner, subject = native(identity)
    statuses = [client.post('/auth/offline/verify', json={'current_password':'Wrong-Password'}).status_code for _ in range(13)]
    assert statuses[:12] == [401]*12
    assert statuses[-1] == 429
