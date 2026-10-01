"""Replace this browser's sessions after a verified OIDC callback.

Call only after state, PKCE, nonce, issuer and account checks have succeeded.
Other browsers and the previous account's stored records are unaffected.
"""
from sqlalchemy import delete

from oidc import app_sessions, session_auth, sha


def retire_browser_sessions(db, request, central_sessions, session_cookie, bindings):
    central_token = request.cookies.get(session_cookie)
    if central_token:
        hashed = sha(central_token)
        db.execute(delete(session_auth).where(session_auth.c.hash == hashed))
        db.execute(delete(central_sessions).where(central_sessions.c.hash == hashed))
    app_token = request.cookies.get('fp_app')
    if app_token:
        hashed = sha(app_token)
        db.execute(delete(bindings).where(bindings.c.hash == hashed))
        db.execute(delete(app_sessions).where(app_sessions.c.hash == hashed))
