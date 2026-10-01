from test_api import service,account,op,poly
from fastapi.testclient import TestClient
from sqlalchemy import update
from app import users

def test_unmapped_areas_and_private_world_map(service):
    client,identity=account(service,'mapowner')
    stranger,_=account(service,'mapstranger')
    farm=op(kind='farm',data={'name':'My farm'})
    assert client.post('/sync/push',json=farm).status_code==200
    area=op(kind='field',data={'name':'Paddock','farmId':farm['id'],'points':[]})
    assert client.post('/sync/push',json=area).status_code==200
    diary=op(data={'title':'Area activity','fieldId':area['id']})
    assert client.post('/sync/push',json=diary).status_code==200
    assert client.get('/map/geojson').json()['unmapped']==2
    assert TestClient(service).get('/map/geojson').status_code==401
    assert client.get('/admin/map/geojson').status_code==403
    assert stranger.get('/map/geojson').json()['features']==[]
    farm_data={**farm['data'],'points':poly([(0,0),(4,0),(4,4),(0,4)])}
    result=client.post('/sync/push',json=op(id=farm['id'],kind='farm',base_version=1,data=farm_data))
    assert result.status_code==200
    area_data={**area['data'],'points':poly([(1,1),(2,1),(2,2),(1,2)])}
    assert client.post('/sync/push',json=op(id=area['id'],kind='field',base_version=1,data=area_data)).status_code==200
    visible=client.get('/map/geojson').json()['features']
    assert len(visible)==2 and all(f['properties']['version']==2 for f in visible)
    assert all(f['geometry']['coordinates'][0][0]==f['geometry']['coordinates'][0][-1] for f in visible)
    changed={**area_data,'name':'Renamed paddock','points':poly([(1,1),(3,1),(3,2),(1,2)])}
    assert client.post('/sync/push',json=op(id=area['id'],kind='field',base_version=2,data=changed)).status_code==200
    feature=next(f for f in client.get('/map/geojson').json()['features'] if f['id']==area['id'])
    assert feature['properties']['name']=='Renamed paddock'
    assert feature['properties']['version']==3
    assert feature['geometry']['coordinates'][0][1]==[.003,.001]
    # Removal of geometry keeps identity/history but removes it from the map.
    assert client.post('/sync/push',json=op(id=area['id'],kind='field',base_version=3,data={**changed,'points':[]})).status_code==200
    assert len(client.get('/map/geojson').json()['features'])==1
    with service.state.engine.begin() as db:
        db.execute(update(users).where(users.c.username=='mapowner').values(admin=True))
    assert client.get('/admin/map/geojson').status_code==200

def test_context_integrity_and_pins(service):
    client,_=account(service,'places')
    f=op(kind='farm',data={'name':'One'});g=op(kind='farm',data={'name':'Two'})
    for item in [f,g]:assert client.post('/sync/push',json=item).status_code==200
    a=op(kind='field',data={'name':'Area','farmId':f['id']})
    assert client.post('/sync/push',json=a).status_code==200
    assert client.post('/sync/push',json=op(data={'title':'Wrong farm','farmId':g['id'],'fieldId':a['id']})).status_code==422
    pin=op(kind='pin',data={'name':'Gate','type':'Gate','farmId':f['id'],'lat':-29.8,'lon':30.9})
    assert client.post('/sync/push',json=pin).status_code==200
    assert client.get('/map/geojson').json()['features'][0]['geometry']['type']=='Point'
    assert client.post('/sync/push',json=op(kind='pin',data={**pin['data'],'lat':100})).status_code==422

