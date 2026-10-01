from uuid import uuid4
from sqlalchemy import select, update, func
from fastapi import HTTPException
import pytest
from test_admin_workspace import workspace
from push_notifications import registrations, messages, outbox, quiet, now

def registration(**kw):
    return {'deviceId':str(uuid4()),'token':'test-token-'+str(uuid4()),'permission':'authorized',
            'version':'0.1.4+4017',**kw}

def identity(app, monkeypatch, owner):
    monkeypatch.setattr(app.state.oidc,'resource_identity',lambda r:{'id':owner,'admin':False})

def notification(**kw):
    return {'eventId':str(uuid4()),'title':'Course available','body':'Open Learning for current enrolments.',**kw}

def test_registration_ack_rotation_and_owner_isolation(workspace,monkeypatch):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    identity(app,monkeypatch,fi['owner']);b=registration()
    assert farmer.put('/notifications/registration',json=b).json()['ack']=='y'
    assert farmer.put('/notifications/registration',json={**b,'token':'rotated-token-'+str(uuid4())}).status_code==200
    identity(app,monkeypatch,oi['owner'])
    assert other.put('/notifications/registration',json=b).status_code==409
    other.delete('/notifications/registration/'+b['deviceId'])
    with app.state.engine.connect() as db:assert db.scalar(select(registrations.c.active)) is True
    data=admin.get('/admin/api/v2/farmers/'+fi['owner']+'/notifications').json()
    assert 'token' not in str(data) and len(data['devices'])==1
    assert farmer.get('/admin/api/v2/farmers/'+fi['owner']+'/notifications').status_code==403

def test_inbox_idempotence_targeting_fetch_and_receipts(workspace,monkeypatch):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    identity(app,monkeypatch,fi['owner'])
    one,two=registration(),registration()
    farmer.put('/notifications/registration',json=one);farmer.put('/notifications/registration',json=two)
    route='/admin/api/v2/farmers/'+fi['owner']+'/notifications'
    b=notification(deviceId=one['deviceId']);result=admin.post(route,json=b)
    assert result.status_code==200,result.text
    mid=result.json()['id'];assert admin.post(route,json=b).json()['id']==mid
    assert admin.post(route,json={**b,'body':'changed'}).status_code==409
    assert admin.post(route,json=notification(deviceId=str(uuid4()))).status_code==404
    assert admin.post(route,json=notification(destination='https://evil.test')).status_code==422
    assert len(farmer.get('/notifications').json()['items'])==1
    assert farmer.get('/notifications/'+mid).json()['owner']==fi['owner']
    assert farmer.post('/notifications/'+mid+'/read').json()['ack']=='y'
    identity(app,monkeypatch,oi['owner'])
    assert other.get('/notifications/'+mid).status_code==404
    assert other.post('/notifications/'+mid+'/read').status_code==404
    calls=[]
    app.state.push.run_once(lambda token,data,ttl:(calls.append((token,data,ttl)) or ('accepted',None)))
    assert len(calls)==1 and calls[0][0]==one['token']
    assert set(calls[0][1])=={'notificationId','schemaVersion'}
    result=admin.get(route).json()['deliveries'][0]
    assert result['state']=='accepted' and result['opened'] and result['read']
    assert app.state.push.run_once(lambda *a:pytest.fail('duplicate delivery'))==0

def test_worker_retry_revocation_preferences_and_expiry(workspace,monkeypatch):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    identity(app,monkeypatch,fi['owner']);b=registration();farmer.put('/notifications/registration',json=b)
    route='/admin/api/v2/farmers/'+fi['owner']+'/notifications'
    admin.post(route,json=notification())
    app.state.push.run_once(lambda *args:('retry','FCM_503'))
    with app.state.engine.begin() as db:
        assert db.scalar(select(outbox.c.state))=='retry'
        db.execute(update(outbox).values(next_at=0))
    farmer.delete('/notifications/registration/'+b['deviceId'])
    app.state.push.run_once(lambda *args:pytest.fail('sent to revoked device'))
    with app.state.engine.connect() as db:assert db.scalar(select(outbox.c.state))=='suppressed'
    farmer.put('/notifications/registration',json={**b,'preferences':{'general':False}})
    admin.post(route,json=notification())
    app.state.push.run_once(lambda *args:pytest.fail('ignored preferences'))
    assert quiet({'quietStart':22,'quietEnd':7,'utcOffsetMinutes':120},21*3600000)
    assert not quiet({'quietStart':22,'quietEnd':7,'utcOffsetMinutes':120},12*3600000)
    farmer.put('/notifications/registration',json=b)
    admin.post(route,json=notification())
    with app.state.engine.begin() as db:db.execute(update(outbox).where(outbox.c.state=='pending').values(expires=0))
    app.state.push.run_once(lambda *args:pytest.fail('sent expired message'))
    with app.state.engine.connect() as db:assert db.scalar(select(func.count()).select_from(outbox).where(outbox.c.state=='expired'))==1

def test_invalid_token_disabled_and_inbox_without_device(workspace,monkeypatch):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    identity(app,monkeypatch,fi['owner'])
    route='/admin/api/v2/farmers/'+fi['owner']+'/notifications'
    assert admin.post(route,json=notification()).status_code==200
    assert len(farmer.get('/notifications').json()['items'])==1
    b=registration();farmer.put('/notifications/registration',json=b)
    admin.post(route,json=notification())
    app.state.push.run_once(lambda *a:('unregistered','UNREGISTERED'))
    with app.state.engine.connect() as db:
        assert db.scalar(select(registrations.c.active)) is False
        assert db.scalar(select(registrations.c.token))==''
