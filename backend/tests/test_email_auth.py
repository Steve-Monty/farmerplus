import re

import pytest
from fastapi.responses import RedirectResponse
from fastapi.testclient import TestClient
from sqlalchemy import select

from app import contacts, create_app, users
from email_auth import RecordingEmailSender, SMTP2GOSender, email_accounts, email_deliveries
from manage import update_role


AUTH_ENV = [
    "SMTP2GO_USERNAME", "SMTP2GO_PASSWORD", "SMTP_FROM_EMAIL", "TEST_EMAIL_MODE",
    "TEST_EMAIL_RECIPIENT", "GOOGLE_OIDC_CLIENT_ID", "GOOGLE_OIDC_CLIENT_SECRET",
    "APPLE_OIDC_CLIENT_ID", "APPLE_OIDC_CLIENT_SECRET", "FARMER_OAUTH_SESSION_SECRET",
]


def clean_auth_env(monkeypatch):
    for name in AUTH_ENV:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("FARMER_ENVIRONMENT", "staging")
    monkeypatch.setenv("FARMER_PWA_PUBLIC_URL", "http://127.0.0.1:5173")
    monkeypatch.setenv("FARMER_PUBLIC_URL", "http://127.0.0.1:8088")


@pytest.fixture
def email_service(tmp_path, monkeypatch):
    clean_auth_env(monkeypatch)
    sender = RecordingEmailSender(recipient="redirect@example.invalid")
    app = create_app(data_dir=tmp_path, testing=True, email_sender=sender)
    return app, TestClient(app), sender


def token_from(message):
    match = re.search(r"[?&]token=([^\s]+)", message.text)
    assert match
    return match.group(1)


def register_and_verify(client, sender, email="new.farmer@example.invalid"):
    registered = client.post("/auth/email/register", json={
        "email": email, "password": "SecurePass", "firstname": "New", "lastname": "Farmer",
    })
    assert registered.status_code == 201
    assert registered.json() == {"created": True, "verificationRequired": True}
    assert sender.messages[-1].intended_recipient == email
    assert sender.messages[-1].outbound_recipient == "redirect@example.invalid"
    assert sender.messages[-1].test_override is True
    token = token_from(sender.messages[-1])
    confirmed = client.post("/auth/email/verification/confirm", json={"token": token})
    assert confirmed.status_code == 200
    assert confirmed.json() == {"verified": True}
    assert client.post("/auth/email/verification/confirm", json={"token": token}).status_code == 400


def test_email_registration_verification_login_reset_and_delivery_evidence(email_service):
    app, client, sender = email_service
    register_and_verify(client, sender)

    signed_in = client.post("/auth/email/login", json={
        "email": "NEW.FARMER@example.invalid", "password": "SecurePass",
    })
    assert signed_in.status_code == 200
    assert signed_in.json()["verified"] is True
    assert signed_in.json()["accountKind"] == "email"
    assert "farmer_session" in signed_in.headers["set-cookie"]
    me = client.get("/auth/me")
    assert me.status_code == 200
    assert me.json()["email"] == "new.farmer@example.invalid"
    assert me.json()["verified"] is True
    assert me.json()["accountKind"] == "email"

    assert client.post("/auth/email/password/forgot", json={"email": "new.farmer@example.invalid"}).json() == {"accepted": True}
    reset_token = token_from(sender.messages[-1])
    reset = client.post("/auth/email/password/reset", json={"token": reset_token, "password": "ReplacementPass"})
    assert reset.status_code == 200
    assert reset.json() == {"reset": True, "sessionsRevoked": True}
    assert client.get("/auth/me").status_code == 401
    assert client.post("/auth/email/login", json={"email": "new.farmer@example.invalid", "password": "SecurePass"}).status_code == 401
    assert client.post("/auth/email/login", json={"email": "new.farmer@example.invalid", "password": "ReplacementPass"}).status_code == 200
    assert client.post("/auth/email/password/reset", json={"token": reset_token, "password": "AnotherPass"}).status_code == 400

    with app.state.engine.connect() as db:
        deliveries = db.execute(select(email_deliveries).order_by(email_deliveries.c.created)).mappings().all()
    assert [row["purpose"] for row in deliveries] == ["verify", "reset"]
    assert all(row["intended_recipient"] == "new.farmer@example.invalid" for row in deliveries)
    assert all(row["outbound_recipient"] == "redirect@example.invalid" for row in deliveries)
    assert all(row["status"] == "sent" and row["test_override"] for row in deliveries)


def test_unverified_login_generic_requests_and_unconfigured_provider(tmp_path, monkeypatch):
    clean_auth_env(monkeypatch)
    sender = RecordingEmailSender()
    app = create_app(data_dir=tmp_path, testing=True, email_sender=sender)
    client = TestClient(app)
    assert client.post("/auth/email/register", json={"email": "pending@example.invalid", "password": "SecurePass"}).status_code == 201
    login = client.post("/auth/email/login", json={"email": "pending@example.invalid", "password": "SecurePass"})
    assert login.status_code == 403
    assert client.post("/auth/email/password/forgot", json={"email": "missing@example.invalid"}).json() == {"accepted": True}
    assert client.post("/auth/email/verification/request", json={"email": "missing@example.invalid"}).json() == {"accepted": True}
    providers = client.get("/auth/providers").json()
    assert providers["google"] == {"configured": False, "startUrl": None}
    assert providers["apple"] == {"configured": False, "startUrl": None}
    assert client.get("/auth/social/google/start", follow_redirects=False).status_code == 503


def test_new_email_account_never_links_matching_legacy_contact(email_service):
    app, client, sender = email_service
    legacy = client.post("/auth/register", json={
        "username": "legacy_farmer", "email": "shared@example.invalid", "password": "LegacyPass",
    })
    assert legacy.status_code == 201
    legacy_owner = legacy.json()["owner"]
    register_and_verify(client, sender, "shared@example.invalid")
    current = client.post("/auth/email/login", json={"email": "shared@example.invalid", "password": "SecurePass"})
    assert current.status_code == 200
    assert current.json()["owner"] != legacy_owner
    with app.state.engine.connect() as db:
        assert len(db.execute(select(contacts).where(contacts.c.email == "shared@example.invalid")).all()) == 2


def test_email_registration_fails_cleanly_when_smtp_is_unconfigured(tmp_path, monkeypatch):
    clean_auth_env(monkeypatch)
    app = create_app(data_dir=tmp_path, testing=True)
    client = TestClient(app)
    assert client.get("/auth/providers").json()["email"]["configured"] is False
    response = client.post("/auth/email/register", json={"email": "no-mail@example.invalid", "password": "SecurePass"})
    assert response.status_code == 503
    with app.state.engine.connect() as db:
        assert db.execute(select(email_accounts)).first() is None


def test_test_recipient_override_is_rejected_in_production(monkeypatch):
    clean_auth_env(monkeypatch)
    monkeypatch.setenv("FARMER_ENVIRONMENT", "production")
    monkeypatch.setenv("SMTP2GO_USERNAME", "configured-user")
    monkeypatch.setenv("SMTP2GO_PASSWORD", "configured-password")
    monkeypatch.setenv("SMTP_FROM_EMAIL", "sender@example.invalid")
    monkeypatch.setenv("TEST_EMAIL_MODE", "true")
    monkeypatch.setenv("TEST_EMAIL_RECIPIENT", "redirect@example.invalid")
    with pytest.raises(RuntimeError, match="cannot be enabled in production"):
        SMTP2GOSender()


class FakeSocialGateway:
    configured = {"google": True, "apple": False}

    async def begin(self, provider, request, callback):
        return RedirectResponse("https://accounts.example.test/authorize", 303)

    async def complete(self, provider, request):
        return {
            "subject": "provider-subject-1", "email": "same@example.invalid",
            "firstname": "Social", "lastname": "Farmer",
        }


def test_social_callback_creates_isolated_verified_account(tmp_path, monkeypatch):
    clean_auth_env(monkeypatch)
    app = create_app(
        data_dir=tmp_path, testing=True, email_sender=RecordingEmailSender(),
        social_gateway=FakeSocialGateway(),
    )
    client = TestClient(app)
    legacy = client.post("/auth/register", json={
        "username": "same_legacy", "email": "same@example.invalid", "password": "LegacyPass",
    }).json()
    start = client.get("/auth/social/google/start", follow_redirects=False)
    assert start.status_code == 303
    callback = client.get("/auth/social/google/callback", follow_redirects=False)
    assert callback.status_code == 303
    assert callback.headers["location"] == "http://127.0.0.1:5173/auth/callback"
    me = client.get("/auth/me")
    assert me.status_code == 200
    assert me.json()["owner"] != legacy["owner"]
    assert me.json()["verified"] is True
    assert me.json()["accountKind"] == "google"
    assert me.json()["email"] == "same@example.invalid"


def test_verified_email_administrator_can_use_local_admin_login(email_service):
    app, _, sender = email_service
    account = TestClient(app)
    register_and_verify(account, sender, "operator@example.invalid")
    assert update_role(app.state.engine, users, 'grant-email-admin', 'OPERATOR@example.invalid') is True
    anonymous = TestClient(app)
    entry = anonymous.get('/admin', follow_redirects=False)
    assert entry.status_code == 303
    assert entry.headers['location'] == '/admin/identity'
    page = anonymous.get('/admin/identity')
    assert 'data-account="admin-email"' in page.text
    assert 'data-account="admin-legacy"' in page.text
    signed_in = anonymous.post('/auth/email/login', json={'email':'operator@example.invalid','password':'SecurePass'})
    assert signed_in.status_code == 200
    dashboard = anonymous.get('/admin')
    assert dashboard.status_code == 200
    assert 'Operations map' in dashboard.text
    account_page = anonymous.get('/account')
    assert 'Email: operator@example.invalid' in account_page.text
    assert 'email:' not in account_page.text
    assert 'id="account-logout"' in account_page.text
    context = anonymous.get('/admin/api/v2/context').json()
    assert context['actorLabel'] == 'New Farmer'
    assert context['actorEmail'] == 'operator@example.invalid'
    assert context['username'].startswith('email:')
    assert update_role(app.state.engine, users, 'revoke-email-admin', 'operator@example.invalid') is True
    assert anonymous.get('/admin').status_code == 403
    assert anonymous.post('/auth/logout').status_code == 200
    assert anonymous.get('/admin', follow_redirects=False).headers['location'] == '/admin/identity'
