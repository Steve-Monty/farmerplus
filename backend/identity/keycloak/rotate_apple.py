"""Rotate Apple's expiring client-secret JWT through the Keycloak Admin API.

Run daily with an operator-only Keycloak client that can manage identity
providers. Private key remains in a secret file. No credential is printed.
"""
import os
import sys
import time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
from authlib.jose import jwt
from keycloak_identity import KeycloakGateway


def configure():
    issuer=os.environ['FARMER_OIDC_ISSUER'].rstrip('/')
    gateway=KeycloakGateway(issuer,'unused','unused',os.environ['FARMER_KEYCLOAK_BROKER_ADMIN_CLIENT_ID'],os.environ['FARMER_KEYCLOAK_BROKER_ADMIN_CLIENT_SECRET'])
    now=int(time.time())
    secret=jwt.encode({'alg':'ES256','kid':os.environ['FARMER_APPLE_KEY_ID']},
        {'iss':os.environ['FARMER_APPLE_TEAM_ID'],'iat':now,'exp':now+7*86400,
            'aud':'https://appleid.apple.com','sub':os.environ['FARMER_APPLE_SERVICES_ID']},
        Path(os.environ['FARMER_APPLE_PRIVATE_KEY_FILE']).read_bytes()).decode()
    config={'alias':'apple','providerId':'farmerplus-apple','enabled':True,'trustEmail':True,
        'storeToken':False,'linkOnly':False,'firstBrokerLoginFlowAlias':'first broker login',
        'config':{'clientId':os.environ['FARMER_APPLE_SERVICES_ID'],'clientSecret':secret,
            'authorizationUrl':'https://appleid.apple.com/auth/authorize','tokenUrl':'https://appleid.apple.com/auth/token',
            'jwksUrl':'https://appleid.apple.com/auth/keys','issuer':'https://appleid.apple.com',
            'validateSignature':'true','useJwksUrl':'true','clientAuthMethod':'client_secret_post',
            'defaultScope':'openid email name','syncMode':'IMPORT','disableUserInfo':'true','disableNonce':'false'}}
    providers=gateway.admin('GET','/identity-provider/instances')
    if any(p['alias']=='apple' for p in providers):gateway.admin('PUT','/identity-provider/instances/apple',json=config)
    else:gateway.admin('POST','/identity-provider/instances',json=config)


if __name__=='__main__':
    try:
        configure()
    except Exception:
        print('Apple broker rotation failed; check protected configuration and provider access.',file=sys.stderr)
        sys.exit(1)
    print('Apple broker configured; secret expires in seven days. Run rotation daily.')
