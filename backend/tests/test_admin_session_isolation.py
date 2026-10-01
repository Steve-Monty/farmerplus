import time
from fastapi.testclient import TestClient
from sqlalchemy import update
from app import create_app,users,sessions
from test_api import account

def test_preview_cookie_cannot_be_overwritten_by_another_local_app(tmp_path):
    app=create_app(data_dir=tmp_path,testing=True,session_cookie='farmer_preview_8186')
    client,identity=account(app,'isolated-admin')
    with app.state.engine.begin() as db:db.execute(update(users).where(users.c.id==identity['owner']).values(admin=True))
    assert client.cookies.get('farmer_preview_8186')
    # Browsers share ordinary host cookies across ports. Simulate the other app.
    client.cookies.set('farmer_session','unrelated-local-app-session')
    for route in ['/admin','/admin/api/v2/context','/admin/api/v2/quality','/admin/identity/context']:
        assert client.get(route).status_code==200
    assert client.post('/auth/logout').status_code==200
    assert client.get('/admin/api/v2/context').status_code==401
    app.state.engine.dispose()

def test_session_still_expires_and_anonymous_access_is_denied(tmp_path):
    app=create_app(data_dir=tmp_path,testing=True,session_cookie='farmer_preview_8186')
    client,identity=account(app,'expiry-admin')
    with app.state.engine.begin() as db:
        db.execute(update(users).where(users.c.id==identity['owner']).values(admin=True))
        db.execute(update(sessions).where(sessions.c.owner==identity['owner']).values(expires=int(time.time())-1))
    assert client.get('/admin/api/v2/context').status_code==401
    assert TestClient(app).get('/admin/api/v2/context').status_code==401
    page=TestClient(app).get('/admin/identity')
    assert page.status_code==200 and 'admin-wordmark.png' in page.text
    assert 'Cancel sign-in' not in page.text
    app.state.engine.dispose()
