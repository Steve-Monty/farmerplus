"""Independent administration credentials and sessions; no identity-provider calls."""
import hashlib
import hmac
import os
import secrets
import time
from pathlib import Path
from urllib.parse import urlsplit

from fastapi import HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from jinja2 import Environment, FileSystemLoader, select_autoescape
from sqlalchemy import MetaData, Table, Column, String, Text, Integer, select, insert, delete

from schema_migrations import apply_additive_schema

meta = MetaData()
credentials = Table('admin_local_credentials', meta,
    Column('owner', String(36), primary_key=True), Column('password', Text, nullable=False))
sessions = Table('admin_local_sessions', meta,
    Column('hash', String(64), primary_key=True), Column('owner', String(36), nullable=False),
    Column('csrf', String(64), nullable=False), Column('expires', Integer, nullable=False))
COOKIE = 'fp_admin_session'
CSRF = 'fp_admin_csrf'

def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


class AdminAuthentication:
    def __init__(self, app, users, password_matches, throttle):
        self.app, self.engine, self.users = app, app.state.engine, users
        self.password_matches, self.throttle = password_matches, throttle
        self.enabled = os.getenv('FARMER_ADMIN_LOCAL_LOGIN') == '1'
        self.secure = os.getenv('FARMER_SECURE_COOKIES') == '1'
        self.origin = os.getenv('FARMER_PUBLIC_URL', '').rstrip('/')
        self.templates = Environment(loader=FileSystemLoader(Path(__file__).parent / 'templates'), autoescape=select_autoescape())
        if self.enabled:
            apply_additive_schema(self.engine, meta, '20260927_01_admin_local_login', 'Independent administrator credentials and sessions')
            self.mount()

    def check_origin(self, request):
        expected = self.origin or str(request.base_url).rstrip('/')
        if self.origin and request.url.netloc != urlsplit(self.origin).netloc:
            raise HTTPException(403, 'Open administration at its configured address')
        if request.headers.get('origin', expected) != expected or request.headers.get('sec-fetch-site') == 'cross-site':
            raise HTTPException(403, 'Request origin was not accepted')

    def current(self, request):
        if not self.enabled:
            return None
        self.check_origin(request)
        token = request.cookies.get(COOKIE, '')
        if not token:
            return None
        from oidc import security
        with self.engine.connect() as db:
            row = db.execute(select(self.users, sessions.c.csrf).join(sessions, sessions.c.owner == self.users.c.id)
                .join(credentials, credentials.c.owner == self.users.c.id)
                .where(sessions.c.hash == digest(token), sessions.c.expires > int(time.time()), self.users.c.admin.is_(True))).mappings().first()
            if not row:
                return None
            state = db.execute(select(security.c.suspended).where(security.c.owner == row['id'])).first()
            if state and state[0]:
                return None
        return dict(row)

    def require(self, request):
        user = self.current(request)
        if not user:
            raise HTTPException(401, 'Sign in to administration')
        if request.method not in {'GET', 'HEAD', 'OPTIONS'}:
            value = request.headers.get('x-csrf-token', '')
            if not value or not hmac.compare_digest(digest(value), user['csrf']):
                raise HTTPException(403, 'Refresh administration and try again')
        return user

    def page(self, request, *, user=None, error='', status=200):
        csrf = secrets.token_urlsafe(32)
        response = HTMLResponse(self.templates.get_template('admin_local_login.html').render(user=user, error=error, csrf=csrf), status_code=status)
        response.set_cookie('fp_admin_login_csrf', csrf, httponly=True, secure=self.secure, samesite='strict', max_age=1800, path='/admin')
        response.headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
        response.headers['Cache-Control'] = 'no-store'
        return response

    def logout(self, request):
        user = self.require(request)
        with self.engine.begin() as db:
            db.execute(delete(sessions).where(sessions.c.hash == digest(request.cookies.get(COOKIE, ''))))
            self.app.state.oidc.log(db, user['id'], 'admin_logout', user['id'], 'success')
        response = JSONResponse({'signedOut': True})
        response.delete_cookie(COOKIE, path='/')
        response.delete_cookie(CSRF, path='/')
        return response

    def mount(self):
        app = self.app
        # Provider identity-management pages must not become another admin login.
        app.router.routes[:] = [r for r in app.router.routes if not getattr(r, 'path', '').startswith('/admin/identity')]

        @app.get('/admin/login')
        @app.get('/admin/identity')
        @app.get('/admin/account')
        def login_page(request: Request):
            self.check_origin(request)
            return self.page(request, user=self.current(request))

        @app.post('/admin/login')
        async def login(request: Request):
            self.check_origin(request)
            form = await request.form()
            csrf = str(form.get('csrf', ''))
            if not csrf or not hmac.compare_digest(csrf, request.cookies.get('fp_admin_login_csrf', '')):
                return self.page(request, error='Refresh the page and try again.', status=403)
            username = str(form.get('username', '')).strip().lower()
            password = str(form.get('password', ''))
            if not 3 <= len(username) <= 64 or not 1 <= len(password) <= 256:
                return self.page(request, error='Enter your username and password.', status=401)
            self.throttle(request, 'admin-login:' + username, force=True, limit=8)
            from oidc import security
            with self.engine.begin() as db:
                row = db.execute(select(self.users, credentials.c.password.label('admin_password'))
                    .join(credentials, credentials.c.owner == self.users.c.id)
                    .where(self.users.c.username == username, self.users.c.admin.is_(True))).mappings().first()
                # Equal-cost verification for unknown usernames.
                encoded = row['admin_password'] if row else '00' * 16 + ':' + '00' * 32
                valid = self.password_matches(password, encoded)
                suspended = db.scalar(select(security.c.suspended).where(security.c.owner == row['id'])) if row else False
                if not row or not valid or suspended:
                    return self.page(request, error='Username or password was not accepted.', status=401)
                token, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
                db.execute(delete(sessions).where((sessions.c.expires <= int(time.time())) | (sessions.c.hash == digest(request.cookies.get(COOKIE, '')))))
                db.execute(insert(sessions).values(hash=digest(token), owner=row['id'], csrf=digest(csrf), expires=int(time.time()) + 12 * 3600))
                app.state.oidc.log(db, row['id'], 'admin_login', row['id'], 'success')
            response = RedirectResponse('/admin', 303)
            response.set_cookie(COOKIE, token, httponly=True, secure=self.secure, samesite='strict', max_age=12 * 3600, path='/')
            response.set_cookie(CSRF, csrf, httponly=False, secure=self.secure, samesite='strict', max_age=12 * 3600, path='/')
            response.delete_cookie('fp_admin_login_csrf', path='/admin')
            return response

        @app.post('/admin/logout')
        def logout(request: Request):
            return self.logout(request)
