from test_admin_workspace import workspace
from fastapi.testclient import TestClient
import admin_google_maps as gm

def test_map_credentials_stay_private_and_viewport_scoped(workspace,monkeypatch):
    app,admin,farmer,*_=workspace
    monkeypatch.setattr(gm,'key',lambda:'synthetic-never-public-key')
    gm._sessions.clear()
    calls=[]
    class Reply:
        def __init__(self,data):self.data=data
        def json(self):return self.data
    def request(path,params,body=None):
        calls.append((path,params,body))
        if path=='v1/createSession':return Reply({'session':'private-session','expiry':9999999999,'tileWidth':256,'tileHeight':256,'imageFormat':'jpeg'})
        return Reply({'copyright':'Google Maps synthetic attribution','maxZoomRects':[{'maxZoom':19,'north':85,'south':-85,'east':180,'west':-180}]})
    monkeypatch.setattr(gm,'request',request)
    route='/admin/api/v2/google-maps/viewport'
    assert TestClient(app).get(route).status_code==401
    assert farmer.get(route).status_code==403
    response=admin.get(route,params={'kind':'hybrid'})
    assert response.status_code==200 and response.json()['tileSize']==256
    assert 'private-session' not in response.text and 'never-public' not in response.text
    assert calls[0][2]['layerTypes']==['layerRoadmap']
    assert admin.get(route,params={'kind':'unknown'}).status_code==422
    assert admin.get(route,params={'north':-50,'south':20}).status_code==422
    assert admin.get('/admin/api/v2/google-maps/tiles/satellite/3/999/2').status_code==422
    assert not any(secret in admin.get('/admin/api/v2/google-maps/config').text for secret in ['private-session','never-public'])

def test_environment_proxy_rejects_invalid_scope_and_tiles(workspace):
    app,admin,farmer,*_=workspace
    route='/admin/api/v2/environment-tiles/rainfall/3/2/2.png'
    assert TestClient(app).get(route).status_code==401
    assert farmer.get(route).status_code==403
    assert admin.get(route,params={'observed':'invalid'}).status_code==422
    assert admin.get('/admin/api/v2/environment-tiles/rainfall/19/2/2.png').status_code==422
    assert admin.get('/admin/api/v2/environment-tiles/unknown/3/2/2.png').status_code==404

def test_key_configuration_is_admin_only_and_never_returned(workspace,monkeypatch,tmp_path):
    app,admin,farmer,*_=workspace
    path=tmp_path/'key'
    monkeypatch.setenv('FARMER_GOOGLE_MAPS_KEY_FILE',str(path))
    route='/admin/api/v2/google-maps/config'
    secret='AIza'+'x'*35
    assert TestClient(app).post(route,json={'key':secret}).status_code==401
    assert farmer.post(route,json={'key':secret}).status_code==403
    assert not path.exists()
    assert admin.post(route,json={'key':'invalid'}).status_code==422
    response=admin.post(route,json={'key':secret})
    assert response.status_code==200
    assert path.read_text()==secret
    assert secret not in response.text
    response=admin.get(route)
    assert response.json()['configured'] is True
    assert secret not in response.text
