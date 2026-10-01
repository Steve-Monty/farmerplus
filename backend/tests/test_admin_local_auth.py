import re
import time

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from sqlalchemy import select, update

from app import create_app, users
from admin_auth import COOKIE, CSRF, credentials, sessions
from scripts.provision_admin_login import provision
from test_keycloak_identity import kc


def enable(app, monkeypatch):
    from admin_auth import AdminAuthentication
    monkeypatch.setenv('FARMER_ADMIN_LOCAL_LOGIN', '1')
    app.state.admin_auth = AdminAuthentication(app, users, app.state.oidc.password_matches, app.state.oidc.throttle)
    provision(app, 'operator@example.test', 'Test@12')


def login(client, password='Test@12'):
    page = client.get('/admin/login')
    csrf = client.cookies['fp_admin_login_csrf']
    return client.post('/admin/login', data={'username':'operator@example.test','password':password,'csrf':csrf}, follow_redirects=False)


def test_local_admin_is_independent_and_csrf_protected(kc, monkeypatch):
    app, service, client = kc
    enable(app, monkeypatch)
    def unavailable(*args, **kwargs):
        raise AssertionError('Administration must not call Keycloak')
    monkeypatch.setattr(service.gateway, 'admin', unavailable)
    monkeypatch.setattr(service.gateway, 'inspect', unavailable)
    monkeypatch.setattr(service, 'resource_identity', unavailable)
    assert client.get('/admin', follow_redirects=False).headers['location'] == '/admin/login'
    assert client.get('/admin/api/v2/farmers').status_code == 401
    assert client.get('/oidc/web/login?destination=admin', follow_redirects=False).headers['location'].endswith('/admin/login')
    assert login(client, 'wrong').status_code == 401
    response = login(client)
    assert response.status_code == 303
    assert 'HttpOnly' in response.headers.get_list('set-cookie')[0]
    for route in ['/admin', '/admin/account', '/admin/identity', '/admin/api/v2/context', '/admin/api/v2/farmers', '/admin/api/v2/overview', '/admin/api/v2/apps', '/admin/tenants']:
        result = client.get(route)
        assert result.status_code == 200, (route, result.text[:200])
    body = {'name':'Saved test view','filters':{}}
    assert client.post('/admin/api/v2/views', json=body).status_code == 403
    headers = {'X-CSRF-Token':client.cookies[CSRF]}
    assert client.post('/admin/api/v2/views', json=body, headers=headers).status_code == 201
    assert client.post('/admin/api/v2/views', json=body, headers={**headers,'Origin':'https://evil.example'}).status_code == 403
    assert client.post('/admin/logout', headers=headers).status_code == 200
    assert client.get('/admin/api/v2/context').status_code == 401


def test_suspension_expiry_rotation_and_only_one_login(kc, monkeypatch):
    app, service, client = kc
    enable(app, monkeypatch)
    assert client.post('/admin/login', data={'username':'operator@example.test','password':'Test@12'}).status_code == 403
    assert login(client).status_code == 303
    old = client.cookies[COOKIE]
    assert login(client).status_code == 303
    replay = TestClient(app, base_url=str(client.base_url))
    replay.cookies.set(COOKIE, old)
    assert replay.get('/admin/api/v2/context').status_code == 401
    with app.state.engine.begin() as db:
        db.execute(update(sessions).values(expires=int(time.time())-1))
    assert client.get('/admin/api/v2/context').status_code == 401
    provision(app, 'other@example.test', 'Different@12')
    assert login(client).status_code == 401
    with app.state.engine.connect() as db:
        assert len(db.execute(select(credentials)).all()) == 1
        assert len(db.execute(select(users).where(users.c.admin.is_(True))).all()) == 1


def test_mobile_session_cannot_enter_admin_and_admin_cannot_enter_mobile(kc, monkeypatch):
    app, service, client = kc
    enable(app, monkeypatch)
    monkeypatch.setattr(service, 'central', lambda request: {'id':'mobile-user','admin':True})
    assert client.get('/admin/api/v2/context').status_code == 401
    assert login(client).status_code == 303
    def reject(request):
        raise HTTPException(401, 'Mobile login required')
    monkeypatch.setattr(service, 'resource_identity', reject)
    assert client.get('/api/v1/apps').status_code == 401
    assert client.get('/sync/pull').status_code == 401
    assert client.get('/auth/providers').json()['authority'] == 'keycloak'


def test_admin_login_rate_limit(kc, monkeypatch):
    app, _, client = kc
    enable(app, monkeypatch)
    for _ in range(8):
        assert login(client, 'wrong').status_code == 401
    assert login(client, 'wrong').status_code == 429
