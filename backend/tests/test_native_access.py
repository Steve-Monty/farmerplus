import time
from fastapi.testclient import TestClient
from sqlalchemy import update
from test_oidc import identity, spec
from oidc import security


def provision(identity):
    app, provider, login = identity
    admin, _ = login('admin', True)
    _, owner = login('farmer')
    assert admin.post('/admin/identity/applications', json=spec(allowed_roles=['farmer'],scopes=['openid','farmerplus.identity','farm:read','farm:write'])).status_code == 200
    client = TestClient(app, base_url='https://app.farmerplus.test')
    result = client.post('/auth/native/login', json={'username':'FARMER','password':'Fixture-only-Password'})
    assert result.status_code == 200, result.text
    assert not result.cookies
    return app, client, owner, result.json()['oidcSession']


def test_native_role_rotation_retry_reuse_and_revocation(identity):
    app, c, owner, session = provision(identity)
    assert c.post('/auth/native/login', json={'username':'admin','password':'Fixture-only-Password'}).status_code == 401
    assert c.post('/auth/native/login', json={'username':'farmer','password':'wrong'}).status_code == 401
    headers = {'Authorization':'Bearer '+session['access_token']}
    assert c.get('/auth/me', headers=headers).status_code == 200
    assert c.get('/admin/api/farmers', headers=headers).status_code == 403
    body = {'refresh_token':session['refresh_token'], 'request_id':'a'*40}
    rotated = c.post('/auth/native/refresh', json=body)
    assert rotated.status_code == 200, rotated.text
    assert c.post('/auth/native/refresh', json=body).json() == rotated.json()
    assert c.get('/auth/me', headers=headers).status_code == 401
    headers = {'Authorization':'Bearer '+rotated.json()['access_token']}
    assert c.get('/auth/me', headers=headers).status_code == 200
    assert c.post('/auth/native/refresh', json={**body,'request_id':'b'*40}).status_code == 401
    assert c.get('/auth/me', headers=headers).status_code == 401


def test_native_epoch_expiry_logout_and_client_disable(identity):
    app, c, owner, session = provision(identity)
    headers = {'Authorization':'Bearer '+session['access_token']}
    with app.state.engine.begin() as db:
        db.execute(update(security).where(security.c.owner==owner).values(epoch=1))
    assert c.get('/auth/me', headers=headers).status_code == 401

    assert c.post('/auth/native/refresh', json={'refresh_token':session['refresh_token'],'request_id':'a'*40}).status_code == 401
    session = c.post('/auth/native/login', json={'username':'farmer','password':'Fixture-only-Password'}).json()['oidcSession']
    headers = {'Authorization':'Bearer '+session['access_token']}
    assert c.post('/auth/logout', headers=headers).status_code == 200
    assert c.get('/auth/me', headers=headers).status_code == 401



def test_learning_handoff_single_use_scope_and_parent_revocation(identity, monkeypatch):
    from test_oidc import spec
    from fastapi import HTTPException
    import pytest
    app, provider, login = identity
    admin, _ = login('administrator', True)
    _, owner = login('learner')
    monkeypatch.setenv('FARMER_NATIVE_LEARNING_ENABLED','1')
    monkeypatch.setenv('FARMER_LEARNING_ORIGIN','https://learn.farmerplus.test')
    monkeypatch.setenv('FARMER_LEARNING_INTROSPECTION_SECRET','fixture-service-secret-'+'x'*32)
    policy = spec(allowed_roles=['farmer'],scopes=['openid','farmerplus.identity','farm:read','farm:write','learning:courses:read','learning:content:read'],audiences=['farmerplus-api','farmerplus-learning-api'])
    assert admin.post('/admin/identity/applications',json=policy).status_code==200
    c = TestClient(app,base_url='https://app.farmerplus.test')
    session = c.post('/auth/native/login',json={'username':'learner','password':'Fixture-only-Password'}).json()['oidcSession']
    headers = {'Authorization':'Bearer '+session['access_token']}
    launch = c.post('/learning/native-launch',headers=headers,json={'cmid':12})
    assert launch.status_code==200, launch.text
    body = {'ticket':launch.json()['ticket']}
    assert c.post('/learning/native-consume',json=body).status_code==403
    service = {'Authorization':'Bearer fixture-service-secret-'+'x'*32}
    consumed = c.post('/learning/native-consume',headers=service,json=body)
    assert consumed.status_code==200, consumed.text
    assert consumed.json()['cmid']==12
    assert c.post('/learning/native-consume',headers=service,json=body).status_code==401
    token = consumed.json()['access_token']
    user, _ = app.state.native.introspect(token,'farmerplus-learning-api',['learning:courses:read'])
    assert user['id']==owner
    with pytest.raises(HTTPException): app.state.native.introspect(token,'farmerplus-api',['farm:read'])
    with app.state.engine.begin() as db: db.execute(update(security).where(security.c.owner==owner).values(epoch=1))
    with pytest.raises(HTTPException): app.state.native.introspect(token,'farmerplus-learning-api',['learning:courses:read'])
