"""Opt-in real OIDC acceptance for the local PWA proxy; never prints credentials."""
import json
import os
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import httpx

ORIGIN = 'http://127.0.0.1:5173'


class Form(HTMLParser):
    def __init__(self):
        super().__init__()
        self.action = None
        self.hidden = {}

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag == 'form' and attributes.get('id') == 'kc-form-login':
            self.action = attributes.get('action')
        if tag == 'input' and attributes.get('type') == 'hidden' and attributes.get('name'):
            self.hidden[attributes['name']] = attributes.get('value', '')


def run():
    path = Path(os.environ['FARMER_KEYCLOAK_ACCEPTANCE_CREDENTIALS'])
    credentials = json.loads(path.read_text())
    with httpx.Client(timeout=30, follow_redirects=False) as browser:
        providers = browser.get(ORIGIN + '/auth/providers').json()
        assert providers['authority'] == 'keycloak'
        assert providers['google']['configured'] is True
        start = browser.get(ORIGIN + '/oidc/web/login')
        assert start.status_code == 303
        destination = urlsplit(start.headers['location'])
        assert destination.hostname == 'auth.agritec.earth'
        assert parse_qs(destination.query)['redirect_uri'] == [ORIGIN + '/oidc/web/callback']
        login = browser.get(start.headers['location'])
        form = Form()
        form.feed(login.text)
        assert form.action
        response = browser.post(form.action, data={
            **form.hidden, 'username': credentials['email'],
            'password': credentials['password'],
        })
        assert response.status_code in (302, 303)
        callback = response.headers['location']
        assert callback.startswith(ORIGIN + '/oidc/web/callback?')
        response = browser.get(callback)
        assert response.status_code == 303, f'Local OIDC callback failed: {response.status_code}'
        me = browser.get(ORIGIN + '/auth/me')
        assert me.status_code == 200 and me.json()['accountKind'] == 'keycloak'
        assert browser.get(ORIGIN + '/learning/provisioning').json()['status'] == 'ready'
        courses = browser.get(ORIGIN + '/learning/courses')
        assert courses.status_code == 200, (
            f'Learning API rejected loopback client: {courses.status_code} '
            + str(courses.json().get('detail', ''))
        )
        assert browser.get(callback).status_code == 403
        logout = browser.post(ORIGIN + '/auth/logout', headers={'Origin': ORIGIN})
        assert logout.status_code == 200
        assert browser.get(ORIGIN + '/auth/me').status_code == 401
    print('PASS: loopback Keycloak login, browser callback, Learning and logout')


if __name__ == '__main__':
    run()
