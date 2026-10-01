"""Opt-in protocol smoke test against a loopback Keycloak fixture, not production.

Requires the isolated realm and private smoke-secrets.json prepared locally.
Exercises real discovery, code+PKCE, signed ID token validation and refresh.
Never prints authorization codes, tokens, passwords or profile payloads.
"""
import json
import os
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit

import httpx
from cryptography.fernet import Fernet
from fastapi.testclient import TestClient

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))


class Form(HTMLParser):
    def __init__(self):super().__init__();self.action=None;self.inputs={}
    def handle_starttag(self,tag,attrs):
        attrs=dict(attrs)
        if tag=='form' and attrs.get('id')=='kc-form-login':self.action=attrs['action']
        if tag=='input' and attrs.get('name') and attrs.get('type')=='hidden':self.inputs[attrs['name']]=attrs.get('value','')


def run():
    private=ROOT/'.local-development/keycloak-tools/smoke-secrets.json'
    secrets=json.loads(private.read_text(encoding='utf-8'))
    values={'FARMER_IDENTITY_PROVIDER':'keycloak','FARMER_ENVIRONMENT':'staging','FARMER_KEYCLOAK_LOOPBACK':'1',
        'FARMER_OIDC_ISSUER':'http://127.0.0.1:8180/realms/farmerplus','FARMER_PWA_PUBLIC_URL':'http://127.0.0.1:8189',
        'FARMER_PUBLIC_URL':'http://127.0.0.1:8189','FARMER_WEB_CLIENT_ID':'farmerplus-pwa',
        'FARMER_WEB_CLIENT_SECRET':secrets['farmerplus-pwa'],'FARMER_LEARNING_CLIENT_ID':'farmerplus-learning',
        'FARMER_KEYCLOAK_ADMIN_CLIENT_ID':'farmerplus-provisioner','FARMER_KEYCLOAK_ADMIN_CLIENT_SECRET':secrets['farmerplus-provisioner'],
        'FARMER_OIDC_STORAGE_KEY':Fernet.generate_key().decode(),'FARMER_SECURE_COOKIES':'0'}
    os.environ.update(values)
    from tempfile import TemporaryDirectory
    from app import create_app
    from keycloak_identity import provisions
    from sqlalchemy import select
    with TemporaryDirectory(prefix='farmerplus-keycloak-',ignore_cleanup_errors=True) as directory:
        app=create_app(data_dir=Path(directory),testing=True)
        s=app.state.oidc
        client=TestClient(app,base_url=values['FARMER_PWA_PUBLIC_URL'])
        start=client.get('/oidc/web/login',follow_redirects=False)
        assert start.status_code==303,'Authorization start failed'
        with httpx.Client(follow_redirects=False,timeout=20) as browser:
            login=browser.get(start.headers['location'])
            form=Form();form.feed(login.text)
            assert form.action,'Keycloak login form missing'
            response=browser.post(form.action,data={**form.inputs,'username':'keycloak-smoke@example.invalid','password':secrets['learner']})
            assert response.status_code in (302,303),'Keycloak login did not redirect'
            target=response.headers['location']
            assert target.startswith(values['FARMER_PWA_PUBLIC_URL']+'/oidc/web/callback?'),'Unexpected callback'
            callback=client.get(target,follow_redirects=False)
            if callback.status_code!=303:
                # Application errors are intentionally generic and contain no tokens.
                raise AssertionError('Backend callback failed: '+callback.text[:300])
        me=client.get('/auth/me')
        assert me.status_code==200 and me.json()['accountKind']=='keycloak','Canonical session failed'
        assert me.json()['verified'] is True
        assert client.get('/sync/pull').status_code==200,'Authenticated sync failed'
        with app.state.engine.connect() as db:
            row=db.execute(select(provisions)).mappings().one()
            assert row['status']=='pending' and row['revision']==1
        assert client.get('/learning/provisioning').json()['status']=='pending'
        assert client.post('/auth/email/login',json={}).status_code==409
        replay=client.get(target,follow_redirects=False)
        assert replay.status_code==403,'Callback replay accepted'
        # Refresh forced independently from the callback refresh.
        from oidc import app_sessions,compact
        from sqlalchemy import update
        with app.state.engine.begin() as db:
            session=db.execute(select(app_sessions)).mappings().one()
            stored=json.loads(s.cipher.decrypt(session['sealed'].encode()))
            stored['expires_at']=0
            db.execute(update(app_sessions).values(sealed=s.cipher.encrypt(compact(stored).encode()).decode()))
        assert client.get('/auth/me').status_code==200,'Refresh failed'
        logout=client.post('/auth/logout')
        assert logout.status_code==200 and logout.json()['endSessionUrl']=='/oidc/logout'
        assert client.get('/auth/me').status_code==401,'Logout left the local session active'
        app.state.engine.dispose()
    print('PASS: real Keycloak code + PKCE, ID token, account mapping, provisioning queue, session, sync, replay rejection, refresh and logout.')


if __name__=='__main__':run()
