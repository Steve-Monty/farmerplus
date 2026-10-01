import json
from uuid import uuid4
from sqlalchemy import insert, update, select, func
from test_admin_workspace import workspace
from test_push_notifications import identity
from community import POLICY, DEMO_CODE, recipients, memberships, events, coops

def install_coop(client, enabled=True, generation=None):
    generation=generation or str(uuid4())
    body={**choice(enabled),'installation':generation}
    result=client.put('/coops/installation',json=body)
    assert result.status_code==200,result.text
    return generation,body

def approve_coop(client,generation):
    coop=client.get('/coops/resolve',params={'code':DEMO_CODE}).json()
    sharing=coop['sharing']
    response=client.put('/sharing/recipients/'+sharing['id']+'/consent',json={
        **choice(True),'installation':generation,'policy':sharing['policy']})
    assert response.status_code==200,response.text
    return coop

def choice(enabled=False, **kw):
    return dict(eventId=str(uuid4()), enabled=enabled, policy=POLICY, **kw)

def test_consent_defaults_scope_idempotence_revocation(workspace, monkeypatch):
    app, admin, farmer, other, ai, fi, oi, farm = workspace
    identity(app, monkeypatch, fi['owner'])
    assert set(farmer.get('/sharing/preferences').json()['choices'].values()) == {False}
    assert all(not r['approved'] for r in farmer.get('/sharing/recipients').json()['items'])
    with app.state.engine.begin() as db:
        db.execute(insert(recipients).values(id='test', name='Named test recipient', category='finance', purpose='Test application', fields=json.dumps(['name']), policy=POLICY, enabled=True))
    route='/sharing/recipients/test'
    assert farmer.get(route+'/export').status_code == 403
    assert farmer.put(route+'/consent',json=choice(True)).status_code == 409
    body=choice(True)
    assert farmer.put('/sharing/preferences/finance',json=body).status_code == 200
    assert farmer.put('/sharing/preferences/finance',json=body).status_code == 200
    assert farmer.put('/sharing/preferences/finance',json={**body,'enabled':False}).status_code == 409
    assert farmer.put(route+'/consent',json=choice(True)).status_code == 200
    result=farmer.get(route+'/export')
    assert result.status_code == 200, result.text
    assert result.json()['transmitted'] is False
    assert 'androidId' not in result.text
    identity(app, monkeypatch, oi['owner'])
    assert other.get(route+'/export').status_code == 403
    assert not other.get('/sharing/preferences').json()['choices']['finance']
    identity(app, monkeypatch, fi['owner'])
    assert farmer.put('/sharing/preferences/finance',json=choice(False)).status_code == 200
    assert farmer.get(route+'/export').status_code == 403
    farmer.put('/sharing/preferences/finance',json=choice(True))
    assert farmer.get(route+'/export').status_code == 403

def test_qr_memberships_and_isolation(workspace, monkeypatch):
    app, admin, farmer, other, ai, fi, oi, farm = workspace
    identity(app,monkeypatch,fi['owner'])
    assert farmer.get('/coops/resolve',params={'code':'Best Scanner'}).status_code == 400
    coop=farmer.get('/coops/resolve',params={'code':DEMO_CODE}).json()
    assert coop['demo'] and coop['annual_minor']==100 and coop['currency']=='USD'
    path='/coops/'+coop['id']+'/membership'
    body=dict(eventId=str(uuid4()), action='join', termsRevision=1, confirmed=True)
    assert farmer.post(path,json={**body,'confirmed':False}).status_code == 400
    assert farmer.post(path,json={**body,'termsRevision':2}).status_code == 409
    assert farmer.post(path,json=body).status_code == 403
    generation,_=install_coop(farmer)
    approve_coop(farmer,generation)
    assert farmer.post(path,json=body).json()['status']=='demo_member'
    assert farmer.post(path,json=body).status_code == 200
    assert farmer.post(path,json={**body,'action':'leave'}).status_code == 409
    with app.state.engine.connect() as db:
        assert db.scalar(select(func.count()).select_from(memberships))==1
        assert db.scalar(select(func.count()).select_from(events).where(events.c.action=='coop.join'))==1
    identity(app,monkeypatch,oi['owner'])
    assert other.get('/coops/memberships').json()['items']==[]
    assert other.post(path,json={**body,'eventId':str(uuid4()),'action':'leave'}).status_code==404
    identity(app,monkeypatch,fi['owner'])
    assert farmer.post(path,json={**body,'eventId':str(uuid4()),'action':'leave'}).json()['status']=='left'
    with app.state.engine.begin() as db: db.execute(update(coops).values(demo=False))
    assert farmer.post(path,json={**body,'eventId':str(uuid4())}).status_code==409

def test_recipient_policy_and_fields_fail_closed(workspace,monkeypatch):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    identity(app,monkeypatch,fi['owner'])
    with app.state.engine.begin() as db:
        db.execute(insert(recipients).values(id='test',name='Test recipient',category='government',purpose='Named purpose',fields=json.dumps(['name']),policy=POLICY,enabled=True))
    farmer.put('/sharing/preferences/government',json=choice(True))
    assert farmer.put('/sharing/recipients/test/consent',json=choice(True)).status_code==200
    with app.state.engine.begin() as db:db.execute(update(recipients).values(policy='new-policy'))
    assert farmer.get('/sharing/recipients/test/export').status_code==403
    assert farmer.put('/sharing/recipients/test/consent',json=choice(True)).status_code==409
    body={**choice(True),'policy':'new-policy'}
    assert farmer.put('/sharing/recipients/test/consent',json=body).status_code==200
    with app.state.engine.begin() as db:db.execute(update(recipients).values(fields=json.dumps(['androidId'])))
    assert farmer.get('/sharing/recipients/test/export').status_code==403
    monkeypatch.setattr(app.state.oidc,'resource_identity',lambda r:{'id':ai['owner'],'admin':True})
    assert admin.get('/sharing/preferences').status_code==403
    assert admin.get('/coops/memberships').status_code==403

def test_coop_locked_installation_reinstall_and_changed_scope(workspace,monkeypatch):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    identity(app,monkeypatch,fi['owner'])
    path='/sharing/recipients/coop:demo-avocado-tarlton'
    assert farmer.put('/sharing/preferences/cooperatives',json=choice(True)).status_code==409
    generation,body=install_coop(farmer)
    assert farmer.put('/coops/installation',json=body).status_code==200
    assert farmer.get('/sharing/preferences').json()['choices']['cooperatives'] is True
    assert farmer.get(path+'/export').status_code==403
    coop=approve_coop(farmer,generation)
    assert farmer.get(path+'/export').status_code==200
    assert farmer.get('/coops/'+coop['id']+'/details').json()['sharing']['approved'] is True
    # Changed exact fields invalidate consent even when an operator forgets to change the policy string.
    with app.state.engine.begin() as db:
        db.execute(update(recipients).where(recipients.c.id=='coop:demo-avocado-tarlton').values(fields=json.dumps(['name'])))
    assert farmer.get(path+'/export').status_code==403
    assert farmer.put(path+'/consent',json={**choice(True),'installation':generation,'policy':coop['sharing']['policy']}).status_code==409
    approve_coop(farmer,generation)
    install_coop(farmer,False)
    assert farmer.get('/sharing/preferences').json()['choices']['cooperatives'] is False
    assert farmer.get(path+'/export').status_code==403
    new_generation,_=install_coop(farmer)
    assert farmer.get(path+'/export').status_code==403
    current=farmer.get('/coops/resolve',params={'code':DEMO_CODE}).json()
    assert farmer.put(path+'/consent',json={**choice(True),'installation':generation,'policy':current['sharing']['policy']}).status_code==409
    approve_coop(farmer,new_generation)
    assert farmer.get(path+'/export').status_code==200
    # A remove/reinstall while offline can arrive as a new generation, and must revoke old approval.
    install_coop(farmer)
    assert farmer.get(path+'/export').status_code==403
    identity(app,monkeypatch,oi['owner'])
    assert other.get('/sharing/preferences').json()['choices']['cooperatives'] is False
    assert other.get(path+'/export').status_code==403
