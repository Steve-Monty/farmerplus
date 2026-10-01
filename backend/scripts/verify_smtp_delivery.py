"""Opt-in live authentication delivery check. Never runs in the normal test suite.

Run with the backend virtualenv and --send-test-emails. Sends exactly one
verification and one password-reset message to the configured test recipient.
Tokens and credentials are never printed or included in the saved evidence.
"""
from pathlib import Path
from dataclasses import replace
import argparse
import json
import os
import re
import secrets
import sys
from datetime import datetime, timezone

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--send-test-emails', action='store_true', required=True)
parser.parse_args()
root = Path(__file__).resolve().parents[1]
for line in (root / '.env').read_text(encoding='utf-8-sig').splitlines():
    if '=' in line and not line.lstrip().startswith('#'):
        key, value = line.split('=', 1)
        os.environ[key.strip()] = value.strip().strip('"').strip("'")
if os.environ.get('TEST_EMAIL_MODE', '').lower() != 'true':
    raise SystemExit('Refusing live check: TEST_EMAIL_MODE must be true.')
if os.environ.get('TEST_EMAIL_RECIPIENT', '').lower() != 'steve@informationcapital.co.za':
    raise SystemExit('Refusing live check: use the designated test recipient.')
data = root / '.local-development' / 'smtp-delivery-check'
data.mkdir(parents=True, exist_ok=True)
os.environ['FARMER_DATA_DIR'] = str(data)
os.environ['DATABASE_URL'] = f'sqlite:///{(data / "farmer.sqlite").as_posix()}'
sys.path.insert(0, str(root))
from app import app
from email_auth import SMTP2GOSender, email_deliveries
from fastapi.testclient import TestClient
from sqlalchemy import select

class DeliveryProbe:
    def __init__(self):
        self.transport = SMTP2GOSender()
        self.configured = self.transport.configured
        self.test_mode = self.transport.test_mode
        self.last_token = None

    def outbound_recipient(self, intended):
        return self.transport.outbound_recipient(intended)

    def send(self, message):
        match = re.search(r'[?&]token=([^\s]+)', message.text)
        assert match, 'Expected one-time authentication token'
        self.last_token = match.group(1)
        message = replace(message,
            subject='[Delivery test - no action needed] ' + message.subject,
            text='This automated local development test requires no action.\n\n' + message.text,
            html='<p>This automated local development test requires no action.</p>' + message.html)
        self.transport.send(message)

probe = DeliveryProbe()
if not probe.configured:
    raise SystemExit('SMTP2GO sending configuration is incomplete.')
app.state.email_auth.sender = probe
client = TestClient(app)
email = f'smtp-check-{secrets.token_hex(6)}@example.invalid'
password = 'Test-' + secrets.token_urlsafe(24) + 'aA'
replacement = 'Reset-' + secrets.token_urlsafe(24) + 'aA'
checks = {}

def check(name, response, expected):
    checks[name] = response.status_code == expected
    if not checks[name]:
        raise RuntimeError(f'{name} failed with HTTP {response.status_code}')

check('register_and_send_verification', client.post('/auth/email/register', json={'email': email, 'password': password}), 201)
verification_token = probe.last_token
check('verify_email', client.post('/auth/email/verification/confirm', json={'token': verification_token}), 200)
check('verification_token_cannot_replay', client.post('/auth/email/verification/confirm', json={'token': verification_token}), 400)
check('login', client.post('/auth/email/login', json={'email': email, 'password': password}), 200)
check('request_and_send_reset', client.post('/auth/email/password/forgot', json={'email': email}), 200)
check('reset_password', client.post('/auth/email/password/reset', json={'token': probe.last_token, 'password': replacement}), 200)
check('reset_revokes_session', client.get('/auth/me'), 401)
check('old_password_rejected', client.post('/auth/email/login', json={'email': email, 'password': password}), 401)
check('replacement_password_works', client.post('/auth/email/login', json={'email': email, 'password': replacement}), 200)
check('logout', client.post('/auth/logout'), 200)
with app.state.engine.connect() as db:
    deliveries = list(db.execute(select(email_deliveries).where(email_deliveries.c.intended_recipient == email)).mappings())
checks['two_sent_messages'] = len(deliveries) == 2 and all(row['status'] == 'sent' for row in deliveries)
checks['both_redirected_only_to_test_recipient'] = all(row['outbound_recipient'] == 'steve@informationcapital.co.za' and row['test_override'] for row in deliveries)
assert all(checks.values())
report = {'time': datetime.now(timezone.utc).isoformat(), 'checks': checks, 'messageCount': len(deliveries), 'deliveryEvidence': 'SMTP server accepted; recipient inbox arrival must be checked separately'}
evidence = root / 'evidence'
evidence.mkdir(parents=True, exist_ok=True)
(evidence / 'smtp-delivery.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps(report, indent=2))

