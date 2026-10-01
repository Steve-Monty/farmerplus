"""Provision an explicitly requested administrator in the isolated local DB.

Credentials arrive through process environment only, never source or output.
Verification/reset emails are captured in memory for this local setup operation.
This script cannot select a remote or production database.
"""
from pathlib import Path
import http.cookiejar
import json
import os
import re
import sys
import urllib.request

root = Path(__file__).resolve().parents[1]
data = root / '.local-development'
data.mkdir(exist_ok=True)
email = os.environ.pop('FARMER_LOCAL_ADMIN_EMAIL').strip().lower()
password = os.environ.pop('FARMER_LOCAL_ADMIN_PASSWORD')
os.environ['FARMER_DATA_DIR'] = str(data)
os.environ['DATABASE_URL'] = f'sqlite:///{(data / "farmer.sqlite").as_posix()}'
os.environ['FARMER_ENVIRONMENT'] = 'testing'
sys.path.insert(0, str(root))

from app import create_app, users
from email_auth import RecordingEmailSender
from fastapi.testclient import TestClient
from sqlalchemy import update

sender = RecordingEmailSender()
application = create_app(data_dir=data, testing=True, email_sender=sender)

def successful(response, codes=(200,)):
    if response.status_code not in codes:
        raise RuntimeError(f'Local provisioning failed with HTTP {response.status_code}')
    return response

def latest_token():
    match = re.search(r'[?&]token=([^\s]+)', sender.messages[-1].text)
    if match is None:
        raise RuntimeError('Local provisioning token was unavailable')
    return match.group(1)

with TestClient(application) as client:
    registered = client.post('/auth/email/register', json={
        'email': email, 'password': password, 'firstname': 'Steve',
    })
    if registered.status_code == 201:
        successful(client.post('/auth/email/verification/confirm', json={'token': latest_token()}))
    elif registered.status_code == 409:
        before = len(sender.messages)
        successful(client.post('/auth/email/verification/request', json={'email': email}))
        if len(sender.messages) > before:
            successful(client.post('/auth/email/verification/confirm', json={'token': latest_token()}))
        successful(client.post('/auth/email/password/forgot', json={'email': email}))
        successful(client.post('/auth/email/password/reset', json={
            'token': latest_token(), 'password': password,
        }))
    else:
        successful(registered, (201,))
    signed_in = successful(client.post('/auth/email/login', json={'email': email, 'password': password}))
    owner = signed_in.json()['owner']
    with application.state.engine.begin() as db:
        db.execute(update(users).where(users.c.id == owner).values(admin=True))

# Verify the running server, not only the in-process setup application.
base = 'http://127.0.0.1:8088'
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
request = urllib.request.Request(base + '/auth/email/login',
    data=json.dumps({'email': email, 'password': password}).encode(),
    headers={'Content-Type': 'application/json', 'Origin': base}, method='POST')
with opener.open(request, timeout=15) as response:
    assert response.status == 200
with opener.open(base + '/admin', timeout=15) as response:
    assert response.status == 200 and 'Operations map' in response.read().decode()
print(f'Local administrator ready: {email}. Live sign-in and operations dashboard verified. No email sent; password not stored in a file.')
