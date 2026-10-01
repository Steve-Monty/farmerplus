"""Create a clearly named local QA account, without sending email.

This fixture is deliberately bound to the isolated local development database.
It cannot run against a configured remote database. The generated password is
saved only in an ignored local file, never printed. Verification here is a test
fixture step; live email delivery is covered by verify_smtp_delivery.py.
"""
from pathlib import Path
import json
import os
import re
import secrets
import sys

root = Path(__file__).resolve().parents[1]
data = root / '.local-development'
data.mkdir(exist_ok=True)
os.environ['FARMER_DATA_DIR'] = str(data)
os.environ['DATABASE_URL'] = f'sqlite:///{(data / "farmer.sqlite").as_posix()}'
os.environ['FARMER_ENVIRONMENT'] = 'testing'
sys.path.insert(0, str(root))
from app import create_app, users
from email_auth import RecordingEmailSender
from fastapi.testclient import TestClient
from sqlalchemy import update

saved = data / 'review-account.json'
if saved.exists():
    raise SystemExit('Local review account already exists; its ignored credentials file is available.')
sender = RecordingEmailSender()
app = create_app(data_dir=data, testing=True, email_sender=sender)
client = TestClient(app)
email = 'local-review@example.invalid'
password = 'Review-' + secrets.token_urlsafe(24) + '-Aa'
r = client.post('/auth/email/register', json={'email': email, 'password': password, 'firstname': 'Local', 'lastname': 'Review'})
if r.status_code != 201:
    raise SystemExit(f'Local fixture registration failed: HTTP {r.status_code}')
token = re.search(r'[?&]token=([^\s]+)', sender.messages[-1].text).group(1)
assert client.post('/auth/email/verification/confirm', json={'token': token}).status_code == 200
signed_in = client.post('/auth/email/login', json={'email': email, 'password': password})
assert signed_in.status_code == 200
owner = signed_in.json()['owner']
with app.state.engine.begin() as db:
    db.execute(update(users).where(users.c.id == owner).values(admin=True))
saved.write_text(json.dumps({'email': email, 'password': password}, indent=2), encoding='utf-8')
print('Created verified local review account and local admin access in the isolated development database. No email sent.')
