"""Email/password and upstream social sign-in for the FarmerPlus PWA.

Legacy username accounts remain owned by app.py.  This module deliberately uses
separate identity tables so an email found on an older profile is never treated
as proof that the new account owns that profile.
"""
from __future__ import annotations

import hashlib
import hmac
import os
import re
import secrets
import smtplib
import ssl
import time
from dataclasses import dataclass
from email.message import EmailMessage
from typing import Protocol
from urllib.parse import quote
from uuid import uuid4

from authlib.integrations.base_client.errors import OAuthError
from authlib.integrations.starlette_client import OAuth
from fastapi import HTTPException, Request, Response
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import Boolean, Column, Integer, MetaData, String, Table, Text, delete, insert, select, update
from sqlalchemy.exc import IntegrityError
from starlette.middleware.sessions import SessionMiddleware

from schema_migrations import apply_additive_schema


metadata = MetaData()
email_accounts = Table(
    "pwa_email_accounts", metadata,
    Column("owner", String(36), primary_key=True),
    Column("email", String(254), unique=True, nullable=False),
    Column("verified", Boolean, nullable=False, default=False),
    Column("created", Integer, nullable=False),
    Column("verified_at", Integer),
)
email_tokens = Table(
    "pwa_email_tokens", metadata,
    Column("hash", String(64), primary_key=True),
    Column("owner", String(36), nullable=False),
    Column("purpose", String(16), nullable=False),
    Column("created", Integer, nullable=False),
    Column("expires", Integer, nullable=False),
)
email_deliveries = Table(
    "pwa_email_deliveries", metadata,
    Column("id", String(36), primary_key=True),
    Column("owner", String(36)),
    Column("purpose", String(16), nullable=False),
    Column("intended_recipient", String(254), nullable=False),
    Column("outbound_recipient", String(254), nullable=False),
    Column("test_override", Boolean, nullable=False),
    Column("status", String(16), nullable=False),
    Column("created", Integer, nullable=False),
    Column("error", String(180)),
)
social_accounts = Table(
    "pwa_social_accounts", metadata,
    Column("provider", String(16), primary_key=True),
    Column("subject", String(255), primary_key=True),
    Column("owner", String(36), unique=True, nullable=False),
    Column("email", String(254), nullable=False),
    Column("created", Integer, nullable=False),
)


EMAIL_RE = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]+$")
TRUE_VALUES = {"1", "true", "yes", "on"}
FALSE_VALUES = {"0", "false", "no", "off", ""}


def _flag(name: str, default: bool = False) -> bool:
    raw = os.getenv(name, "true" if default else "false").strip().lower()
    if raw in TRUE_VALUES:
        return True
    if raw in FALSE_VALUES:
        return False
    raise RuntimeError(f"{name} must be true or false")


def normalize_email(value: str) -> str:
    result = value.strip().lower()
    if len(result) > 254 or not EMAIL_RE.fullmatch(result):
        raise HTTPException(422, "Enter a valid email address")
    return result


def token_hash(value: str) -> str:
    return hashlib.sha256(("farmerplus-pwa-token-v1:" + value).encode()).hexdigest()


def safe_return_path(value: str | None) -> str:
    value = value or "/auth/callback"
    if not value.startswith("/") or value.startswith("//") or "\\" in value or "\x00" in value:
        raise HTTPException(422, "Return path must be a local application path")
    return value


class EmailRegistration(BaseModel):
    model_config = ConfigDict(extra="forbid")
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=1, max_length=256)
    firstname: str = Field(default="", max_length=100)
    lastname: str = Field(default="", max_length=100)


class EmailLogin(BaseModel):
    model_config = ConfigDict(extra="forbid")
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=1, max_length=256)


class EmailAddress(BaseModel):
    model_config = ConfigDict(extra="forbid")
    email: str = Field(min_length=3, max_length=254)


class TokenConfirmation(BaseModel):
    model_config = ConfigDict(extra="forbid")
    token: str = Field(min_length=32, max_length=256)


class PasswordReset(TokenConfirmation):
    password: str = Field(min_length=1, max_length=256)


@dataclass(frozen=True)
class OutboundEmail:
    intended_recipient: str
    outbound_recipient: str
    subject: str
    text: str
    html: str
    purpose: str
    test_override: bool


class EmailSender(Protocol):
    configured: bool
    test_mode: bool

    def outbound_recipient(self, intended: str) -> str: ...
    def send(self, message: OutboundEmail) -> None: ...


class SMTP2GOSender:
    """SMTP transport. Credentials are read only from the process environment."""

    def __init__(self):
        self.host = os.getenv("SMTP2GO_HOST", "mail.smtp2go.com").strip()
        try:
            self.port = int(os.getenv("SMTP2GO_PORT", "587"))
        except ValueError as exc:
            raise RuntimeError("SMTP2GO_PORT must be a number") from exc
        self.username = os.getenv("SMTP2GO_USERNAME", "").strip()
        self.password = os.getenv("SMTP2GO_PASSWORD", "")
        self.from_email = os.getenv("SMTP_FROM_EMAIL", "").strip()
        self.from_name = os.getenv("SMTP_FROM_NAME", "FarmerPlus").strip() or "FarmerPlus"
        supplied = [bool(self.username), bool(self.password), bool(self.from_email)]
        # Deployment templates may safely provide non-secret host/user/from
        # values before the secret is provisioned.  Status remains explicitly
        # unconfigured and mail endpoints fail closed until every value exists.
        self.configured = all(supplied)
        self.test_mode = _flag("TEST_EMAIL_MODE")
        self.test_recipient = os.getenv("TEST_EMAIL_RECIPIENT", "").strip().lower()
        environment = os.getenv("FARMER_ENVIRONMENT", "staging").strip().lower()
        if self.test_mode and not EMAIL_RE.fullmatch(self.test_recipient):
            raise RuntimeError("TEST_EMAIL_RECIPIENT is required when TEST_EMAIL_MODE=true")
        if environment in {"production", "prod"} and self.test_mode:
            raise RuntimeError("TEST_EMAIL_MODE cannot be enabled in production")

    def outbound_recipient(self, intended: str) -> str:
        return self.test_recipient if self.test_mode else intended

    def send(self, message: OutboundEmail) -> None:
        if not self.configured:
            raise RuntimeError("SMTP2GO is not configured")
        mail = EmailMessage()
        mail["From"] = f"{self.from_name} <{self.from_email}>"
        mail["To"] = message.outbound_recipient
        mail["Subject"] = message.subject
        mail.set_content(message.text)
        mail.add_alternative(message.html, subtype="html")
        tls = ssl.create_default_context()
        if self.port == 465:
            with smtplib.SMTP_SSL(self.host, self.port, timeout=15, context=tls) as client:
                client.login(self.username, self.password)
                client.send_message(mail)
        else:
            with smtplib.SMTP(self.host, self.port, timeout=15) as client:
                client.ehlo()
                client.starttls(context=tls)
                client.ehlo()
                client.login(self.username, self.password)
                client.send_message(mail)


class RecordingEmailSender:
    """Explicit test double; application code never selects this implicitly."""

    configured = True

    def __init__(self, test_mode: bool = True, recipient: str = "test-recipient@example.invalid"):
        self.test_mode = test_mode
        self.recipient = recipient
        self.messages: list[OutboundEmail] = []

    def outbound_recipient(self, intended: str) -> str:
        return self.recipient if self.test_mode else intended

    def send(self, message: OutboundEmail) -> None:
        self.messages.append(message)


class AuthlibSocialGateway:
    def __init__(self, app):
        self.oauth = OAuth()
        self.configured: dict[str, bool] = {}
        definitions = {
            "google": (
                "GOOGLE_OIDC_CLIENT_ID", "GOOGLE_OIDC_CLIENT_SECRET",
                "https://accounts.google.com/.well-known/openid-configuration", "openid email profile",
            ),
            "apple": (
                "APPLE_OIDC_CLIENT_ID", "APPLE_OIDC_CLIENT_SECRET",
                "https://appleid.apple.com/.well-known/openid-configuration", "openid email name",
            ),
        }
        for provider, (id_name, secret_name, metadata_url, scope) in definitions.items():
            client_id, client_secret = os.getenv(id_name, "").strip(), os.getenv(secret_name, "").strip()
            if bool(client_id) != bool(client_secret):
                raise RuntimeError(f"{id_name} and {secret_name} must be configured together")
            enabled = bool(client_id and client_secret)
            self.configured[provider] = enabled
            if enabled:
                client_kwargs = {"scope": scope}
                if provider == "apple":
                    client_kwargs["token_endpoint_auth_method"] = "client_secret_post"
                self.oauth.register(
                    provider,
                    client_id=client_id,
                    client_secret=client_secret,
                    server_metadata_url=metadata_url,
                    client_kwargs=client_kwargs,
                )
        if any(self.configured.values()):
            session_secret = os.getenv("FARMER_OAUTH_SESSION_SECRET", "")
            if len(session_secret) < 32:
                raise RuntimeError("FARMER_OAUTH_SESSION_SECRET must contain at least 32 characters when social sign-in is configured")
            apple_enabled = self.configured.get("apple", False)
            public_https = os.getenv("FARMER_PUBLIC_URL", "").startswith("https://")
            if apple_enabled and not public_https:
                raise RuntimeError("FARMER_PUBLIC_URL must use HTTPS when Apple sign-in is configured")
            app.add_middleware(
                SessionMiddleware, secret_key=session_secret,
                same_site="none" if apple_enabled else "lax",
                https_only=apple_enabled or public_https,
            )

    async def begin(self, provider: str, request: Request, callback: str):
        client = self.oauth.create_client(provider)
        if not client:
            raise HTTPException(503, f"{provider.title()} sign-in is not configured")
        parameters = {"nonce": secrets.token_urlsafe(24)}
        if provider == "apple":
            parameters["response_mode"] = "form_post"
        return await client.authorize_redirect(request, callback, **parameters)

    async def complete(self, provider: str, request: Request) -> dict:
        client = self.oauth.create_client(provider)
        if not client:
            raise HTTPException(503, f"{provider.title()} sign-in is not configured")
        try:
            token = await client.authorize_access_token(request)
        except OAuthError as exc:
            raise HTTPException(401, "Social sign-in was not accepted") from exc
        except Exception as exc:
            raise HTTPException(503, "Social identity provider is unavailable") from exc
        claims = token.get("userinfo") or {}
        subject = str(claims.get("sub", ""))
        email = str(claims.get("email", ""))
        verified = claims.get("email_verified")
        if provider == "google" and verified not in {True, "true", "True", 1}:
            raise HTTPException(403, "Google did not confirm this email address")
        if not subject or not email:
            raise HTTPException(403, "The identity provider did not return a usable verified profile")
        return {
            "subject": subject,
            "email": normalize_email(email),
            "firstname": str(claims.get("given_name", ""))[:100],
            "lastname": str(claims.get("family_name", ""))[:100],
        }


class EmailAuthentication:
    def __init__(
        self, app, engine, users, sessions, contacts, students,
        password_hash, password_matches, validate_password, issue_session,
        issue_recovery, student, throttle, sender: EmailSender | None = None,
        social_gateway=None,
    ):
        self.app, self.engine = app, engine
        self.users, self.sessions, self.contacts, self.students = users, sessions, contacts, students
        self.password_hash, self.password_matches = password_hash, password_matches
        self.validate_password, self.issue_session = validate_password, issue_session
        self.issue_recovery, self.student, self.throttle = issue_recovery, student, throttle
        self.sender = sender or SMTP2GOSender()
        self.pwa_url = os.getenv("FARMER_PWA_PUBLIC_URL", "http://127.0.0.1:5173").rstrip("/")
        environment = os.getenv("FARMER_ENVIRONMENT", "staging").strip().lower()
        if environment in {"production", "prod"} and not self.pwa_url.startswith("https://"):
            raise RuntimeError("FARMER_PWA_PUBLIC_URL must use HTTPS in production")
        self.public_url = os.getenv("FARMER_PUBLIC_URL", "http://127.0.0.1:8088").rstrip("/")
        self.social = social_gateway or AuthlibSocialGateway(app)
        self.schema = apply_additive_schema(
            engine, metadata, "20260922_01_pwa_auth",
            "Add isolated PWA email accounts, one-use email tokens, delivery evidence and upstream social identities",
        )
        self.mount()

    def profile(self, owner: str) -> dict | None:
        with self.engine.connect() as db:
            email = db.execute(select(email_accounts).where(email_accounts.c.owner == owner)).mappings().first()
            if email:
                return {"email": email["email"], "verified": bool(email["verified"]), "accountKind": "email"}
            social = db.execute(select(social_accounts).where(social_accounts.c.owner == owner)).mappings().first()
            if social:
                return {"email": social["email"], "verified": True, "accountKind": social["provider"]}
        return None

    def _require_mail(self):
        if not self.sender.configured:
            raise HTTPException(503, "Authentication email is not configured on this server")

    def _new_token(self, db, owner: str, purpose: str, lifetime: int) -> str:
        db.execute(delete(email_tokens).where(email_tokens.c.owner == owner, email_tokens.c.purpose == purpose))
        raw = secrets.token_urlsafe(32)
        db.execute(insert(email_tokens).values(
            hash=token_hash(raw), owner=owner, purpose=purpose,
            created=int(time.time()), expires=int(time.time()) + lifetime,
        ))
        return raw

    def _message(self, recipient: str, purpose: str, token: str) -> OutboundEmail:
        if purpose == "verify":
            path, subject, action = "/auth/verify", "Verify your FarmerPlus email", "Verify email"
            explanation = "Confirm this email address to finish creating your FarmerPlus account."
        else:
            path, subject, action = "/auth/reset", "Reset your FarmerPlus password", "Reset password"
            explanation = "Use this one-time link to choose a new FarmerPlus password."
        link = f"{self.pwa_url}{path}?token={quote(token, safe='')}"
        outbound = self.sender.outbound_recipient(recipient)
        return OutboundEmail(
            intended_recipient=recipient,
            outbound_recipient=outbound,
            subject=subject,
            text=f"{explanation}\n\n{link}\n\nIf you did not request this, you can ignore this message.",
            html=(f"<p>{explanation}</p><p><a href=\"{link}\">{action}</a></p>"
                  "<p>If you did not request this, you can ignore this message.</p>"),
            purpose=purpose,
            test_override=bool(self.sender.test_mode),
        )

    def _deliver(self, owner: str, message: OutboundEmail):
        delivery_id = str(uuid4())
        with self.engine.begin() as db:
            db.execute(insert(email_deliveries).values(
                id=delivery_id, owner=owner, purpose=message.purpose,
                intended_recipient=message.intended_recipient,
                outbound_recipient=message.outbound_recipient,
                test_override=message.test_override, status="pending", created=int(time.time()),
            ))
        try:
            self.sender.send(message)
        except Exception:
            with self.engine.begin() as db:
                db.execute(update(email_deliveries).where(email_deliveries.c.id == delivery_id).values(
                    status="failed", error="SMTP delivery failed",
                ))
            raise HTTPException(502, "Authentication email could not be delivered; try again") from None
        with self.engine.begin() as db:
            db.execute(update(email_deliveries).where(email_deliveries.c.id == delivery_id).values(status="sent", error=None))

    def _consume_token(self, db, raw: str, purpose: str):
        row = db.execute(select(email_tokens).where(
            email_tokens.c.hash == token_hash(raw),
            email_tokens.c.purpose == purpose,
            email_tokens.c.expires > int(time.time()),
        )).mappings().first()
        if not row:
            raise HTTPException(400, "This link is invalid or expired")
        removed = db.execute(delete(email_tokens).where(email_tokens.c.hash == row["hash"]))
        if removed.rowcount != 1:
            raise HTTPException(400, "This link has already been used")
        return row

    def _create_user(self, db, username: str, password: str, firstname: str, lastname: str, provider: str):
        owner = str(uuid4())
        db.execute(insert(self.users).values(
            id=owner, username=username, password=self.password_hash(password), admin=False, serial=0,
        ))
        mapped = self.student(db, owner)
        db.execute(update(self.students).where(self.students.c.owner == owner).values(
            firstname=firstname.strip(), lastname=lastname.strip(), provider=provider,
        ))
        self.issue_recovery(db, owner)
        return owner, mapped

    def mount(self):
        app = self.app

        @app.get("/auth/providers")
        def providers():
            if getattr(app.state.oidc, 'provider', None) == 'keycloak':
                return {
                    'authority': 'keycloak',
                    'keycloak': {'configured': True, 'startUrl': '/oidc/web/login', 'registrationUrl': '/oidc/web/login?register=true'},
                    'email': {'configured': True, 'verificationRequired': True, 'deliveryMode': 'identity-provider'},
                    **{name: {'configured': os.getenv('FARMER_KEYCLOAK_'+name.upper()+'_ENABLED') == '1',
                        'startUrl': '/oidc/web/login?provider='+name if os.getenv('FARMER_KEYCLOAK_'+name.upper()+'_ENABLED') == '1' else None}
                        for name in ('google', 'apple')},
                }
            return {
                "email": {
                    "configured": bool(self.sender.configured),
                    "verificationRequired": True,
                    "deliveryMode": "test-redirect" if self.sender.test_mode else "direct",
                },
                "google": {
                    "configured": bool(self.social.configured.get("google")),
                    "startUrl": "/auth/social/google/start" if self.social.configured.get("google") else None,
                },
                "apple": {
                    "configured": bool(self.social.configured.get("apple")),
                    "startUrl": "/auth/social/apple/start" if self.social.configured.get("apple") else None,
                },
            }

        @app.post("/auth/email/register", status_code=201)
        def register(body: EmailRegistration, request: Request):
            self._require_mail()
            email = normalize_email(body.email)
            self.validate_password(body.password)
            self.throttle(request, "email-register:" + email, force=True, limit=6)
            try:
                with self.engine.begin() as db:
                    username = "email:" + hashlib.sha256(email.encode()).hexdigest()[:32]
                    owner, _ = self._create_user(db, username, body.password, body.firstname, body.lastname, "email")
                    db.execute(insert(email_accounts).values(
                        owner=owner, email=email, verified=False, created=int(time.time()), verified_at=None,
                    ))
                    db.execute(insert(self.contacts).values(owner=owner, email=email, verified=False))
                    token = self._new_token(db, owner, "verify", 24 * 3600)
            except IntegrityError:
                raise HTTPException(409, "An account already exists for this email address") from None
            self._deliver(owner, self._message(email, "verify", token))
            return {"created": True, "verificationRequired": True}

        @app.post("/auth/email/login")
        def login(body: EmailLogin, request: Request, response: Response):
            email = normalize_email(body.email)
            self.throttle(request, "email-login:" + email, force=True)
            self.throttle(request, "login-all", force=True, limit=120)
            with self.engine.begin() as db:
                account = db.execute(select(email_accounts).where(email_accounts.c.email == email)).mappings().first()
                user = db.execute(select(self.users).where(self.users.c.id == account["owner"])).mappings().first() if account else None
                if not user:
                    self.password_hash(body.password, b"0000000000000000")
                    raise HTTPException(401, "Invalid email or password")
                state = app.state.oidc.state(db, user["id"], True)
                if state["suspended"] or not self.password_matches(body.password, user["password"]):
                    raise HTTPException(401, "Invalid email or password")
                if not account["verified"]:
                    raise HTTPException(403, "Verify your email address before signing in")
                existing = app.state.oidc.central(request, db)
                if existing and existing["id"] != user["id"]:
                    raise HTTPException(409, "Sign out of the current browser account before changing people")
                result = self.issue_session(db, user, response)
            return {**result, "verified": True, "accountKind": "email"}

        @app.post("/auth/email/verification/request")
        def request_verification(body: EmailAddress, request: Request):
            self._require_mail()
            email = normalize_email(body.email)
            self.throttle(request, "email-verification:" + email, force=True, limit=6)
            with self.engine.begin() as db:
                account = db.execute(select(email_accounts).where(email_accounts.c.email == email)).mappings().first()
                token = self._new_token(db, account["owner"], "verify", 24 * 3600) if account and not account["verified"] else None
            if token:
                self._deliver(account["owner"], self._message(email, "verify", token))
            return {"accepted": True}

        @app.post("/auth/email/verification/confirm")
        def confirm_verification(body: TokenConfirmation):
            with self.engine.begin() as db:
                token = self._consume_token(db, body.token, "verify")
                db.execute(update(email_accounts).where(email_accounts.c.owner == token["owner"]).values(
                    verified=True, verified_at=int(time.time()),
                ))
                db.execute(update(self.contacts).where(self.contacts.c.owner == token["owner"]).values(verified=True))
            return {"verified": True}

        @app.post("/auth/email/password/forgot")
        def forgot_password(body: EmailAddress, request: Request):
            self._require_mail()
            email = normalize_email(body.email)
            self.throttle(request, "email-forgot:" + email, force=True, limit=6)
            with self.engine.begin() as db:
                account = db.execute(select(email_accounts).where(
                    email_accounts.c.email == email, email_accounts.c.verified.is_(True),
                )).mappings().first()
                token = self._new_token(db, account["owner"], "reset", 30 * 60) if account else None
            if token:
                self._deliver(account["owner"], self._message(email, "reset", token))
            return {"accepted": True}

        @app.post("/auth/email/password/reset")
        def reset_password(body: PasswordReset, request: Request):
            self.validate_password(body.password)
            self.throttle(request, "email-reset", force=True, limit=12)
            with self.engine.begin() as db:
                token = self._consume_token(db, body.token, "reset")
                app.state.oidc.state(db, token["owner"], True)
                db.execute(update(self.users).where(self.users.c.id == token["owner"]).values(
                    password=self.password_hash(body.password),
                ))
                app.state.oidc.queue_revoke(db, owner=token["owner"])
                self.issue_recovery(db, token["owner"])
            return {"reset": True, "sessionsRevoked": True}

        @app.get("/auth/social/{provider}/start")
        async def social_start(provider: str, request: Request, returnTo: str = "/auth/callback"):
            if provider not in {"google", "apple"}:
                raise HTTPException(404, "Social provider is not supported")
            safe_return_path(returnTo)
            callback = f"{self.public_url}/auth/social/{provider}/callback"
            return await self.social.begin(provider, request, callback)

        @app.api_route("/auth/social/{provider}/callback", methods=["GET", "POST"])
        async def social_callback(provider: str, request: Request):
            if provider not in {"google", "apple"}:
                raise HTTPException(404, "Social provider is not supported")
            profile = await self.social.complete(provider, request)
            with self.engine.begin() as db:
                linked = db.execute(select(social_accounts).where(
                    social_accounts.c.provider == provider,
                    social_accounts.c.subject == profile["subject"],
                )).mappings().first()
                if linked:
                    owner = linked["owner"]
                    user = db.execute(select(self.users).where(self.users.c.id == owner)).mappings().one()
                else:
                    username = "social:" + provider + ":" + hashlib.sha256(profile["subject"].encode()).hexdigest()[:24]
                    owner, _ = self._create_user(
                        db, username, secrets.token_urlsafe(48), profile["firstname"], profile["lastname"], provider,
                    )
                    db.execute(insert(social_accounts).values(
                        provider=provider, subject=profile["subject"], owner=owner,
                        email=profile["email"], created=int(time.time()),
                    ))
                    db.execute(insert(self.contacts).values(owner=owner, email=profile["email"], verified=True))
                    user = db.execute(select(self.users).where(self.users.c.id == owner)).mappings().one()
                response = RedirectResponse(f"{self.pwa_url}/auth/callback", 303)
                self.issue_session(db, user, response)
            return response
