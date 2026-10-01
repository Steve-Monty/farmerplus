import json
from uuid import uuid4
from sqlalchemy import insert, select
from test_admin_workspace import workspace
from community import memberships, events, DEMO_CODE, POLICY
from push_notifications import registrations


def test_phone_choices_and_coop_ack_visible_in_admin(workspace, monkeypatch):
    app, admin, farmer, other, ai, fi, oi, farm = workspace
    owner = fi['owner']
    monkeypatch.setattr(app.state.oidc, 'resource_identity', lambda r: {'id': owner, 'admin': False})
    def choice(enabled, **extra):
        return dict(eventId=str(uuid4()), enabled=enabled, policy=POLICY, **extra)
    route = '/admin/api/v2/farmers/' + owner + '/sharing'
    for enabled in [True, False, True]:
        result = farmer.put('/sharing/preferences/finance', json=choice(enabled))
        assert result.status_code == 200 and result.json()['saved']
        row = next(c for c in admin.get(route).json()['choices'] if c['category'] == 'finance')
        assert row['explicit'] and row['enabled'] is enabled and row['updated']
    generation = str(uuid4())
    ack = farmer.put('/coops/installation', json=choice(True, installation=generation))
    assert ack.status_code == 200 and ack.json()['owner'] == owner
    coop = farmer.get('/coops/resolve', params={'code': DEMO_CODE}).json()
    recipient = coop['sharing']
    payload = choice(True, installation=generation)
    payload['policy'] = recipient['policy']
    assert farmer.put('/sharing/recipients/' + recipient['id'] + '/consent', json=payload).status_code == 200
    assert next(r for r in admin.get(route).json()['recipients'] if r['id'] == recipient['id'])['effective']
    assert farmer.put('/coops/installation', json=choice(False, installation=generation)).status_code == 200
    result = admin.get(route).json()
    assert not next(r for r in result['recipients'] if r['id'] == recipient['id'])['effective']
    assert not next(c for c in result['choices'] if c['category'] == 'cooperatives')['enabled']

def test_coop_inventory_history_and_sharing_scope(workspace,monkeypatch):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    owner=fi['owner']; route='/admin/api/v2/farmers/'+owner
    monkeypatch.setattr(app.state.oidc,'resource_identity',lambda r:{'id':owner,'admin':False})
    # Legacy 4019 payload must work without changing the phone.
    response=farmer.post('/sync/complete',json={'device':str(uuid4()),'version':'0.1.4+4019','installedApps':[{'id':'coop','version':1}]})
    assert response.status_code==200,response.text
    c=admin.get(route+'/apps').json()['apps'][0]
    assert c['id']=='coop' and c['installed'] and not c['hasSyncedData']
    with app.state.engine.begin() as db:
        db.execute(insert(memberships).values(owner=owner,coop='demo-avocado-tarlton',status='left',payment_status='not_required',updated=100,terms_revision=1))
        db.execute(insert(events).values(owner=owner,id=str(uuid4()),fingerprint='a'*64,action='coop.leave',target='demo-avocado-tarlton',at=100,policy=POLICY,result=json.dumps({'status':'left'})))
    assert admin.get(route+'/apps').json()['apps'][0]['hasSyncedData']
    h=admin.get(route+'/apps/coop/history').json()
    assert h['total']==1 and h['memberships'][0]['status']=='left' and h['events'][0]['demo']
    s=admin.get(route+'/sharing').json()
    assert len(s['choices'])==5 and all(not c['enabled'] and not c['explicit'] for c in s['choices'])
    for suffix in ['/sharing','/apps/coop/history','/classification']:
        assert other.get(route+suffix).status_code==403
    assert admin.post(route+'/sharing',json={}).status_code==405

def test_no_farm_filters_exports_and_labels(workspace):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    assert admin.get('/admin/api/v2/overview').json()['totals']['withoutFarm']==1
    r=admin.get('/admin/api/v2/farmers?farmStatus=none').json()
    assert r['total']==1 and r['people'][0]['id']==oi['owner']
    assert admin.get('/admin/api/v2/export?farmStatus=none').text.count('\n')==2
    assert not admin.get('/admin/api/v2/map?farmStatus=none').json()['features']
    assert admin.get('/admin/api/v2/farmers?farmStatus=bad').status_code==422
    route='/admin/api/v2/farmers/'+oi['owner']+'/classification'
    body={'classification':'test','revision':0,'reason':'Synthetic QA account'}
    assert admin.post(route,json=body).status_code==200
    assert admin.post(route,json=body).status_code==409
    assert admin.get('/admin/api/v2/farmers?accountType=exclude-test').json()['total']==1
    assert admin.get('/admin/api/v2/farmers?accountType=test').json()['people'][0]['id']==oi['owner']
    assert admin.get('/admin/api/v2/export?accountType=test').text.count('\n')==2
    assert farmer.post(route,json=body).status_code==403

def test_contact_is_not_successful_sync_and_no_token_exposed(workspace):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    from push_notifications import Registration
    body=Registration(deviceId=uuid4(),token='synthetic-token-do-not-expose',permission='authorized',version='0.1.4+4019',preferences={'quietStart':22,'quietEnd':7,'utcOffsetMinutes':120})
    app.state.push.register(fi['owner'],body)
    route='/admin/api/v2/farmers/'+fi['owner']
    p=admin.get(route).json()['person']
    assert p['lastSync'] is None and p['lastContact'] and p['appVersion']=='0.1.4+4019'
    n=admin.get(route+'/notifications')
    assert n.json()['devices'][0]['preferences']['quietStart']==22
    assert 'synthetic-token-do-not-expose' not in n.text and 'token_hash' not in n.text
