"""Render a separate FarmerPlus realm. Secrets are supplied by deployment only.

Usage: python identity/keycloak/realm.py --output <private deployment directory>/farmerplus-realm.json
The resulting file includes client secrets; never commit or serve it.
"""
import argparse
import json
import os
from pathlib import Path


def realm(pwa, learning, secrets):
    def property_mapper(name, attribute, claim, kind='String'):
        return {'name': name, 'protocol': 'openid-connect', 'protocolMapper': 'oidc-usermodel-property-mapper',
            'config': {'user.attribute': attribute, 'claim.name': claim, 'jsonType.label': kind,
                'id.token.claim': 'true', 'access.token.claim': 'true', 'userinfo.token.claim': 'true', 'introspection.token.claim': 'true'}}
    # An explicit clientScopes import replaces defaults. Include the standard
    # claims needed to verify and provision email and social registrations.
    scopes = [
        {'name': 'basic', 'protocol': 'openid-connect', 'attributes': {'include.in.token.scope': 'false'}, 'protocolMappers': [
            {'name': 'sub', 'protocol': 'openid-connect', 'protocolMapper': 'oidc-sub-mapper',
             'config': {'access.token.claim': 'true', 'introspection.token.claim': 'true'}},
            {'name': 'auth_time', 'protocol': 'openid-connect', 'protocolMapper': 'oidc-usersessionmodel-note-mapper',
             'config': {'user.session.note': 'AUTH_TIME', 'claim.name': 'auth_time', 'jsonType.label': 'long',
                        'id.token.claim': 'true', 'access.token.claim': 'true', 'introspection.token.claim': 'true'}}]},
        {'name': 'profile', 'protocol': 'openid-connect', 'attributes': {'include.in.token.scope': 'true'}, 'protocolMappers': [
            property_mapper('given name', 'firstName', 'given_name'),
            property_mapper('family name', 'lastName', 'family_name'),
            property_mapper('username', 'username', 'preferred_username')]},
        {'name': 'email', 'protocol': 'openid-connect', 'attributes': {'include.in.token.scope': 'true'}, 'protocolMappers': [
            property_mapper('email', 'email', 'email'),
            property_mapper('email verified', 'emailVerified', 'email_verified', 'boolean')]},
    ]
    for name in ['farmerplus.identity','farm:read','farm:write','learning:courses:read','learning:content:read']:
        mappers = []
        if name == 'farmerplus.identity':
            mappers = [{'name':'immutable-farmer-id','protocol':'openid-connect','protocolMapper':'oidc-usermodel-attribute-mapper',
                'config':{'user.attribute':'farmerplus_id','claim.name':'farmerplus_id','jsonType.label':'String',
                    'id.token.claim':'true','access.token.claim':'true','userinfo.token.claim':'true','introspection.token.claim':'true'}}]
        scopes.append({'name':name,'protocol':'openid-connect','attributes':{'include.in.token.scope':'true'},'protocolMappers':mappers})
    def audience(name):
        return {'name':name,'protocol':'openid-connect','protocolMapper':'oidc-audience-mapper','config':{
            'included.custom.audience':name,'access.token.claim':'true','id.token.claim':'false','introspection.token.claim':'true'}}
    def client(name, origin, callback, scope_names):
        return {'clientId':name,'protocol':'openid-connect','publicClient':False,'secret':secrets[name],
            'standardFlowEnabled':True,'implicitFlowEnabled':False,'directAccessGrantsEnabled':False,
            'fullScopeAllowed':False,'redirectUris':[origin+callback],
            'attributes':{'pkce.code.challenge.method':'S256','post.logout.redirect.uris':origin+('/auth/callback' if name=='farmerplus-pwa' else '/auth/farmerplusoidc/signedout.php'),
                'backchannel.logout.session.required':'true',
                'backchannel.logout.url':origin+('/auth/farmerplusoidc/backchannel.php' if name=='farmerplus-learning' else '/oidc/backchannel')},
            'defaultClientScopes':['basic','profile','email','farmerplus.identity',*scope_names],
            # The backend confidential client introspects both PWA and Learning
            # tokens; Keycloak 26.7 requires it in their explicit audience.
            'protocolMappers':[audience('farmerplus-learning-api'),audience('farmerplus-pwa'),*([audience('farmerplus-api')] if name=='farmerplus-pwa' else [])]}
    profile = {'attributes':[
        {'name':'username','validations':{'length':{'min':3,'max':255}},'permissions':{'view':['admin','user'],'edit':['admin','user']}},
        {'name':'email','required':{'roles':['user']},'validations':{'email':{},'length':{'max':254}},'permissions':{'view':['admin','user'],'edit':['admin','user']}},
        *[{'name':name,'displayName':'${'+name+'}','required':{'roles':['user']},'validations':{'length':{'min':1,'max':100}},'permissions':{'view':['admin','user'],'edit':['admin','user']}} for name in ['firstName','lastName']],
        {'name':'farmerplus_id','validations':{'pattern':{'pattern':'^[a-f0-9]{32}$'}},'permissions':{'view':['admin'],'edit':['admin']}}
    ]}  # Omitted/null means disabled; Keycloak has no DISABLED enum value.
    return {'realm':'farmerplus','enabled':True,'displayName':'FarmerPlus','registrationAllowed':True,
        'loginTheme':'farmerplus','emailTheme':'farmerplus','registrationFlow':'farmerplus-registration',
        'accessCodeLifespanLogin':1800,'accessCodeLifespanUserAction':1800,
        'authenticatorConfig':[{'alias':'farmerplus-registration-password','config':{'always_set_password_on_register_form':'true'}}],
        'authenticationFlows':[
            {'alias':'farmerplus-registration','providerId':'basic-flow','topLevel':True,'builtIn':False,
             'authenticationExecutions':[{'authenticator':'registration-page-form','authenticatorFlow':True,
                 'requirement':'REQUIRED','priority':10,'flowAlias':'farmerplus-registration-form'}]},
            {'alias':'farmerplus-registration-form','providerId':'form-flow','topLevel':False,'builtIn':False,
             'authenticationExecutions':[
                 {'authenticator':'registration-user-creation','authenticatorFlow':False,'requirement':'REQUIRED','priority':10},
                 {'authenticator':'registration-password-action','authenticatorFlow':False,'requirement':'REQUIRED','priority':20,
                  'authenticatorConfig':'farmerplus-registration-password'}]}],
        'registrationEmailAsUsername':True,'loginWithEmailAllowed':True,'duplicateEmailsAllowed':False,
        'verifyEmail':True,'resetPasswordAllowed':True,'rememberMe':True,'bruteForceProtected':True,
        'passwordPolicy':'length(8) and notUsername(undefined) and notEmail(undefined)',
        'sslRequired':'external','accessTokenLifespan':300,'ssoSessionIdleTimeout':1800,'ssoSessionMaxLifespan':2592000,
        'ssoSessionIdleTimeoutRememberMe':1800,'ssoSessionMaxLifespanRememberMe':2592000,
        'eventsEnabled':True,'eventsExpiration':604800,'adminEventsEnabled':True,'adminEventsDetailsEnabled':False,
        'clientScopes':scopes,'clients':[
            client('farmerplus-pwa',pwa,'/oidc/web/callback',['farm:read','farm:write','learning:courses:read','learning:content:read']),
            client('farmerplus-learning',learning,'/auth/farmerplusoidc/callback.php',['learning:courses:read','learning:content:read']),
            {'clientId':'farmerplus-provisioner','protocol':'openid-connect','publicClient':False,'secret':secrets['farmerplus-provisioner'],
                'serviceAccountsEnabled':True,'standardFlowEnabled':False,'directAccessGrantsEnabled':False,'fullScopeAllowed':True}],
        'users':[{'username':'service-account-farmerplus-provisioner','enabled':True,'serviceAccountClientId':'farmerplus-provisioner',
            'clientRoles':{'realm-management':['view-users','query-users','manage-users']}}],
        'components':{'org.keycloak.userprofile.UserProfileProvider':[{'name':'declarative-user-profile','providerId':'declarative-user-profile',
            'config':{'kc.user.profile.config':[json.dumps(profile)]}}]},
        'identityProviders':[]}


if __name__ == '__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--output',required=True);args=parser.parse_args()
    value=realm(os.environ['FARMER_PWA_PUBLIC_URL'].rstrip('/'),os.environ['FARMER_LEARNING_ORIGIN'].rstrip('/'),
        {'farmerplus-pwa':os.environ['FARMER_WEB_CLIENT_SECRET'],'farmerplus-learning':os.environ['FARMER_LEARNING_CLIENT_SECRET'],
            'farmerplus-provisioner':os.environ['FARMER_KEYCLOAK_ADMIN_CLIENT_SECRET']})
    Path(args.output).write_text(json.dumps(value,indent=2),encoding='utf-8')
    print('FarmerPlus realm rendered; output contains deployment secrets.')
