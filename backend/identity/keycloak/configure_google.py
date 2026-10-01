"""Configure Google's Keycloak broker using operator-only environment secrets."""
import os
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
from keycloak_identity import KeycloakGateway


def configure():
    gateway=KeycloakGateway(os.environ['FARMER_OIDC_ISSUER'].rstrip('/'),'unused','unused',
        os.environ['FARMER_KEYCLOAK_BROKER_ADMIN_CLIENT_ID'],os.environ['FARMER_KEYCLOAK_BROKER_ADMIN_CLIENT_SECRET'])
    config={'alias':'google','providerId':'google','enabled':True,'trustEmail':True,'storeToken':False,
        'firstBrokerLoginFlowAlias':'first broker login','config':{
            'clientId':os.environ['GOOGLE_OIDC_CLIENT_ID'],'clientSecret':os.environ['GOOGLE_OIDC_CLIENT_SECRET'],
            'defaultScope':'openid profile email','syncMode':'IMPORT'}}
    existing=gateway.admin('GET','/identity-provider/instances')
    if any(p['alias']=='google' for p in existing):gateway.admin('PUT','/identity-provider/instances/google',json=config)
    else:gateway.admin('POST','/identity-provider/instances',json=config)


if __name__=='__main__':
    try:configure()
    except Exception:
        print('Google broker setup failed; check protected operator configuration.',file=sys.stderr);sys.exit(1)
    print('Google broker configured. Validate live sign-in before enabling the PWA shortcut.')
