"""Fixed-destination Learning transport. Never logs passwords, assertions or tokens."""
import hashlib
import hmac
import json
import os
import secrets
import time
import urllib.parse
import urllib.request
from fastapi import HTTPException

HOST = 'https://learn.agritec.earth'

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

def post(path, fields):
    try:
        req = urllib.request.Request(HOST + path, data=urllib.parse.urlencode(fields).encode())
        with urllib.request.build_opener(NoRedirect).open(req, timeout=25) as r:
            raw = r.read(4 * 1024 * 1024 + 1)
        if len(raw) > 4 * 1024 * 1024:
            raise ValueError()
        result = json.loads(raw)
        if isinstance(result, dict) and any(k in result for k in ('error', 'exception')):
            raise ValueError()
        return result
    except Exception:
        raise HTTPException(503, 'Learning is temporarily unavailable. Saved lessons remain available.') from None

def password_login(username, password):
    data = post('/login/token.php', {'username': username, 'password': password, 'service': 'moodle_mobile_app'})
    if not isinstance(data.get('token'), str):
        raise HTTPException(401, 'Invalid username or password')
    site = read(data['token'], 'core_webservice_get_site_info', {})
    if not isinstance(site.get('userid'), int) or site['userid'] <= 0 or site.get('siteurl', '').rstrip('/') != HOST:
        raise HTTPException(401, 'Learning identity could not be verified')
    return {'token': data['token'], 'site': site}

def read(token, function, params):
    return post('/webservice/rest/server.php', {**params, 'wstoken': token, 'wsfunction': function, 'moodlewsrestformat': 'json'})

def configured():
    return len(os.getenv('FARMER_LEARNING_BRIDGE_SECRET', '')) >= 64

def assertion(action, student_id, payload, secret, audience=HOST, clock=None, nonce=None):
    now = int(time.time()) if clock is None else clock
    body = json.dumps({'iss': 'farmerplus', 'aud': audience, 'iat': now, 'exp': now + 60,
                       'nonce': nonce or secrets.token_hex(16), 'action': action,
                       'student_id': student_id, 'payload': payload}, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()
    return body, hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()

def call(action, student_id, payload=None):
    if not configured():
        raise HTTPException(503, 'Learning connection is awaiting the reviewed platform update. Your account and farm tools are ready.')
    body, signature = assertion(action, student_id, payload or {}, os.environ['FARMER_LEARNING_BRIDGE_SECRET'])
    try:
        req = urllib.request.Request(HOST + '/auth/farmerplus/bridge.php', data=body,
                                     headers={'Content-Type': 'application/json', 'X-FarmerPlus-Signature': signature})
        with urllib.request.build_opener(NoRedirect).open(req, timeout=25) as r:
            result = json.loads(r.read(100000))
        if not result.get('ok'):
            raise ValueError()
        return result
    except Exception:
        raise HTTPException(503, 'Learning connection could not finish. Try again when connected; saved lessons are kept.') from None
