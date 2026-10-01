"""Narrow, idempotent update of an existing realm; never reimports users/clients.

Install the farmerplus theme image before applying. Supply a short-lived operator
token in a private file. Default is read-only; --apply requires deployment approval.
"""
import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote
import httpx


def upgrade(client, base, backup_dir=None, apply=False):
    def call(method, path, **kwargs):
        r = client.request(method, base + path, **kwargs)
        if r.status_code >= 300:
            raise RuntimeError(f'Keycloak {method} {path.split("?")[0]} failed ({r.status_code})')
        return r.json() if r.content else None
    realm = call('GET', '')
    flow = realm['registrationFlow']
    executions = call('GET', '/authentication/flows/' + quote(flow, safe='') + '/executions')
    passwords = [e for e in executions if e.get('providerId') == 'registration-password-action']
    if len(passwords) != 1 or passwords[0].get('requirement') != 'REQUIRED':
        raise RuntimeError('Review the active registration flow: exactly one REQUIRED password validation is needed')
    execution = passwords[0]
    config_id = execution.get('authenticationConfig')
    config = call('GET', '/authentication/config/' + config_id) if config_id else None
    profile = call('GET', '/users/profile')
    fields = ['loginTheme', 'accessCodeLifespanLogin', 'accessCodeLifespanUserAction', 'verifyEmail', 'passwordPolicy']
    policy = realm.get('passwordPolicy') or ''
    if not re.search(r'(^|\s+and\s+)length\((?:8|12)\)(?=\s+and\s+|$)',policy):
        raise RuntimeError('Review the active password policy before changing its minimum length')
    policy = re.sub(r'(?<!\w)length\((?:8|12)\)', 'length(8)', policy, count=1)
    snapshot = {'realm': {k: realm.get(k) for k in fields}, 'registrationFlow': flow,
                'executionId': execution['id'], 'config': config, 'profile': profile}
    if not apply:
        return {'mode':'review', 'flow':flow, 'passwordExecutionRequired':True,
                'themeBefore':realm.get('loginTheme'), 'themeAfter':'farmerplus',
                'collectPasswordAtRegistration':True, 'emailVerification':True, 'flowSeconds':1800,
                'passwordPolicyAfter':policy}
    if not backup_dir:
        raise ValueError('A private backup directory is required')
    backup_dir = Path(backup_dir); backup_dir.mkdir(parents=True, exist_ok=True)
    backup = backup_dir / ('registration-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ') + '.json')
    # Snapshot excludes SMTP/client secrets and contains only fields changed here.
    with backup.open('x', encoding='utf-8') as handle: json.dump(snapshot, handle, indent=2)
    merged = dict(config or {'alias':'farmerplus-registration-password', 'config':{}})
    merged['config'] = {**merged.get('config', {}), 'always_set_password_on_register_form':'true'}
    if config_id:
        call('PUT', '/authentication/config/' + config_id, json=merged)
    else:
        call('POST', '/authentication/executions/' + execution['id'] + '/config', json=merged)
    for attribute in profile['attributes']:
        if attribute['name'] in {'firstName','lastName'}:
            attribute['displayName'] = '${' + attribute['name'] + '}'
    call('PUT', '/users/profile', json=profile)
    call('PUT', '', json={'loginTheme':'farmerplus', 'accessCodeLifespanLogin':1800,
                         'accessCodeLifespanUserAction':1800, 'verifyEmail':True, 'passwordPolicy':policy})
    return {'mode':'applied', 'backup':str(backup), 'flow':flow}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--issuer', required=True)
    parser.add_argument('--token-file', type=Path, required=True)
    parser.add_argument('--backup-dir', type=Path)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    from keycloak_identity import validate_url
    issuer = validate_url(args.issuer, development=args.issuer.startswith('http://127.0.0.1:'))
    host, realm = issuer.rsplit('/realms/', 1)
    with httpx.Client(timeout=30, headers={'Authorization':'Bearer ' + args.token_file.read_text().strip()}) as client:
        print(json.dumps(upgrade(client, host+'/admin/realms/'+quote(realm,safe=''), args.backup_dir, args.apply)))
