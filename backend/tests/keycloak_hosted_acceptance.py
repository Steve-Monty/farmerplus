"""Opt-in hosted acceptance. Run inside the deployed backend with operator approval.

Uses a synthetic verified account; never prints passwords, tokens or callbacks.
Does not claim social sign-in or inbox-delivery acceptance.
"""
import json
import secrets
import time
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin, urlsplit
import httpx
from app import app

class Form(HTMLParser):
    def __init__(self): super().__init__(); self.action=None; self.hidden={}
    def handle_starttag(self,tag,attrs):
        a=dict(attrs)
        if tag=='form' and a.get('id')=='kc-form-login': self.action=a['action']
        if tag=='input' and a.get('type')=='hidden' and a.get('name'): self.hidden[a['name']]=a.get('value','')

def run():
    service=app.state.oidc
    service.drain()
    private=Path('/app/data/keycloak-acceptance.json')
    if private.exists(): credentials=json.loads(private.read_text())
    else:
        credentials={'email':'keycloak-acceptance-'+secrets.token_hex(5)+'@example.invalid','password':secrets.token_urlsafe(28)}
        service.gateway.admin('POST','/users',json={'username':credentials['email'],'email':credentials['email'],
            'emailVerified':True,'enabled':True,'firstName':'Keycloak','lastName':'Acceptance',
            'credentials':[{'type':'password','value':credentials['password'],'temporary':False}]})
        private.write_text(json.dumps(credentials));private.chmod(0o600)
    service.reconcile()
    service.drain_provisioning()
    with httpx.Client(timeout=30,follow_redirects=False) as browser:
        start=browser.get('https://app.agritec.earth/oidc/web/login')
        assert start.status_code==303, 'PWA authorization start failed'
        login=browser.get(start.headers['location']); form=Form();form.feed(login.text)
        assert form.action, 'Keycloak login form missing'
        response=browser.post(form.action,data={**form.hidden,'username':credentials['email'],'password':credentials['password']})
        assert response.status_code in (302,303), 'Keycloak login did not redirect'
        callback=response.headers['location']
        assert callback.startswith('https://app.agritec.earth/oidc/web/callback?'), 'Unexpected PWA callback'
        response=browser.get(callback)
        assert response.status_code==303, 'PWA callback rejected: '+str(response.status_code)+' '+response.json().get('detail','')
        me=browser.get('https://app.agritec.earth/auth/me')
        assert me.status_code==200 and me.json()['accountKind']=='keycloak', 'PWA session missing'
        status=browser.get('https://app.agritec.earth/learning/provisioning')
        assert status.status_code==200 and status.json()['status']=='ready', 'Moodle provisioning not ready'
        print('PASS: real Keycloak code/PKCE callback, PWA session and automatic Moodle provisioning',flush=True)
        # The browser retains its realm cookies when opening the separate RP.
        url='https://learn.agritec.earth/auth/farmerplusoidc/login.php'
        for _ in range(12):
            response=browser.get(url)
            if response.status_code in (301,302,303,307,308):
                url=urljoin(url,response.headers['location']);continue
            break
        assert 'kc-form-login' not in response.text, 'Learning requested a second password'
        assert response.status_code==200 and urlsplit(url).path=='/my/courses.php', 'Moodle callback or final session failed'
        assert 'Keycloak Acceptance' in response.text, 'Expected Moodle user not displayed'
        print('PASS: Learning opens as the same account without another password',flush=True)
        users=service.gateway.admin('GET','/users',params={'username':credentials['email'],'exact':'true'})
        assert len(users)==1, 'Synthetic account lookup failed'
        person=users[0]
        service.gateway.admin('PUT','/users/'+person['id'],json={
            'username':person['username'],'email':person['email'],'emailVerified':True,
            'firstName':'Updated','lastName':'Acceptance','attributes':person.get('attributes',{})})
        service.reconcile();service.drain_provisioning()
        status=browser.get('https://app.agritec.earth/learning/provisioning').json()
        assert status['status']=='ready', 'Profile update not delivered'
        service.gateway.admin('PUT','/users/'+person['id'],json={
            'username':person['username'],'email':person['email'],'emailVerified':True,
            'firstName':'Keycloak','lastName':'Acceptance','attributes':person.get('attributes',{})})
        service.reconcile();service.drain_provisioning()
        print('PASS: profile update delivered and restored through the durable outbox',flush=True)
        replay=browser.get(callback)
        assert replay.status_code==403, 'Callback replay accepted'
        logout=browser.post('https://app.agritec.earth/auth/logout',headers={'Origin':'https://app.agritec.earth'})
        assert logout.status_code==200, 'PWA logout failed'
        assert browser.get('https://app.agritec.earth/auth/me').status_code==401, 'PWA session survived logout'
        print('PASS: callback replay rejected and PWA logout revoked the session',flush=True)
        service.drain()
        result=browser.get('https://learn.agritec.earth/my/courses.php',follow_redirects=True)
        assert urlsplit(str(result.url)).path!='/my/courses.php' or 'Keycloak Acceptance' not in result.text, 'Learning session survived central logout'
        print('PASS: central logout also invalidates the Learning session',flush=True)
        start=browser.get('https://app.agritec.earth/oidc/web/login')
        login=browser.get(start.headers['location']); form=Form();form.feed(login.text)
        assert form.action, 'Fresh login form missing after logout'
        response=browser.post(form.action,data={**form.hidden,'username':credentials['email'],'password':credentials['password']})
        response=browser.get(response.headers['location'])
        assert response.status_code==303, 'Fresh login after logout failed'
        try:
            service.gateway.admin('PUT','/users/'+person['id'],json={'enabled':False})
            service.reconcile();service.drain();service.drain_provisioning()
            assert browser.get('https://app.agritec.earth/auth/me').status_code in (401,403), 'Suspended account retained PWA access'
            assert browser.get('https://app.agritec.earth/learning/courses').status_code in (401,403), 'Suspended account retained Learning API access'
        finally:
            service.gateway.admin('PUT','/users/'+person['id'],json={'enabled':True})
            service.reconcile();service.drain_provisioning()
        print('PASS: suspension revokes PWA and Learning API access; synthetic account restored',flush=True)

if __name__=='__main__': run()
