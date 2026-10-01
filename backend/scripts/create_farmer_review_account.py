"""Create or reuse the disposable local farmer QA account without sending email.

The fixture is bound to the ignored, isolated local-development database. Its
generated password is written only to farmer-review-account.json and is never
printed. Verification uses the explicit in-memory email test double.
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
from email_auth import RecordingEmailSender, email_accounts
from fastapi.testclient import TestClient
from sqlalchemy import select

email = 'farmer-review@example.invalid'
saved = data / 'farmer-review-account.json'
sender = RecordingEmailSender()
app = create_app(data_dir=data, testing=True, email_sender=sender)
client = TestClient(app)


def require_farmer(owner: str) -> None:
    with app.state.engine.connect() as db:
        row = db.execute(select(users.c.id, users.c.admin).where(users.c.id == owner)).mappings().first()
    if not row or row['admin']:
        raise SystemExit('Local farmer fixture is unavailable or has unexpected privileges.')


try:
    if saved.exists():
        try:
            credentials = json.loads(saved.read_text(encoding='utf-8'))
            if credentials.get('email') != email or not isinstance(credentials.get('password'), str):
                raise ValueError
        except (OSError, ValueError, json.JSONDecodeError):
            raise SystemExit('Local farmer credentials file is invalid; it was left unchanged.') from None
        signed_in = client.post('/auth/email/login', json=credentials)
        if signed_in.status_code != 200:
            raise SystemExit('Local farmer fixture could not be verified; no account was changed.')
        owner = signed_in.json()['owner']
        require_farmer(owner)
        if sender.messages:
            raise SystemExit('Unexpected fixture email activity.')
    else:
        with app.state.engine.connect() as db:
            exists = db.scalar(select(email_accounts.c.owner).where(email_accounts.c.email == email))
        if exists:
            raise SystemExit('Local farmer account exists but its credentials file is missing; no account was changed.')
        password = 'FarmerReview-' + secrets.token_urlsafe(24) + '-Aa'
        response = client.post('/auth/email/register', json={
            'email': email,
            'password': password,
            'firstname': 'Farmer',
            'lastname': 'Review',
        })
        if response.status_code != 201 or len(sender.messages) != 1:
            raise SystemExit(f'Local farmer fixture registration failed: HTTP {response.status_code}')
        match = re.search(r'[?&]token=([^\s]+)', sender.messages[0].text)
        if not match or client.post('/auth/email/verification/confirm', json={'token': match.group(1)}).status_code != 200:
            raise SystemExit('Local farmer fixture verification failed.')
        signed_in = client.post('/auth/email/login', json={'email': email, 'password': password})
        if signed_in.status_code != 200:
            raise SystemExit('Local farmer fixture sign-in failed.')
        owner = signed_in.json()['owner']
        require_farmer(owner)
        temporary = saved.with_suffix('.tmp')
        temporary.write_text(json.dumps({'email': email, 'password': password}, indent=2), encoding='utf-8')
        os.replace(temporary, saved)
    print(json.dumps({'email': email, 'owner': owner}))
finally:
    client.close()
    app.state.engine.dispose()
