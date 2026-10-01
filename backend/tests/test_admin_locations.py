from test_admin_workspace import workspace
from test_api import op


def test_registration_pin_suppressed_but_retained_and_location_filters(workspace):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    pin=op(kind='pin',data={'name':'Registration location','lat':-26,'lon':29,'accuracy':8,'purpose':'registration'})
    assert farmer.post('/sync/push',json=pin).status_code==200
    otherpin=op(kind='pin',data={'name':'Registration location','lat':-26.5,'lon':29.5})
    assert other.post('/sync/push',json=otherpin).status_code==200
    result=admin.get('/admin/api/v2/map').json()
    assert {f['id'] for f in result['features']}=={farm['id'],otherpin['id']}
    assert result['matchingFarmers']==2 and result['unlocatedFarmers']==0
    profile=admin.get('/admin/api/v2/farmers/'+fi['owner']).json()['person']
    assert profile['registrationLocation']['lat']==-26
    assert any(r['id']==pin['id'] for r in profile['records'])
    result=admin.get('/admin/api/v2/map',params={'farmStatus':'none'}).json()
    assert [f['id'] for f in result['features']]==[otherpin['id']]
    for route in ['map','farmers','export']:
        assert admin.get('/admin/api/v2/'+route,params={'location':'invalid'}).status_code==422
    assert admin.get('/admin/api/v2/farmers',params={'location':'unavailable'}).json()['total']==0
    # Filtering to pin records must never resurrect an obsolete map marker.
    assert pin['id'] not in {f['id'] for f in admin.get('/admin/api/v2/map?kind=pin').json()['features']}


def test_unlocated_stays_in_directory_and_country_uses_profile(workspace):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    result=admin.get('/admin/api/v2/map?farmStatus=none').json()
    assert result['matchingFarmers']==1 and result['unlocatedFarmers']==1 and not result['features']
    assert admin.get('/admin/api/v2/farmers?location=unavailable').json()['total']==1
    assert other.post('/sync/push',json=op(kind='profile',data={'name':'Unmapped person','country':'Kenya'})).status_code==200
    assert other.post('/sync/push',json=op(kind='pin',data={'lat':1,'lon':36})).status_code==200
    assert admin.get('/admin/api/v2/map?country=Kenya').json()['farmers']==1
    assert admin.get('/admin/api/v2/farmers?country=Kenya').json()['total']==1


def test_farm_places_remain_visible_alongside_boundary_and_registration_is_separate(workspace):
    app,admin,farmer,other,ai,fi,oi,farm=workspace
    registration=op(kind='pin',data={'name':'Registration location','lat':-26,'lon':29,'purpose':'registration'})
    gate=op(kind='pin',data={'name':'North gate','type':'Gate','color':'#007f78','farmId':farm['id'],'lat':-26.1,'lon':29.1})
    water=op(kind='pin',data={'name':'Water point','type':'Water point','farmId':farm['id'],'lat':-26.2,'lon':29.2})
    for record in [registration,gate,water]:
        assert farmer.post('/sync/push',json=record).status_code==200
    features=admin.get('/admin/api/v2/map').json()['features']
    assert {f['id'] for f in features} == {farm['id'],gate['id'],water['id']}
    place_features={f['id']:f for f in features if f['properties']['kind']=='pin'}
    assert place_features[gate['id']]['properties']['placeColor']=='#007f78'
    assert place_features[gate['id']]['properties']['placeColor']!=place_features[water['id']]['properties']['placeColor']
    assert {f['id'] for f in admin.get('/admin/api/v2/map?kind=pin').json()['features']} == {gate['id'],water['id']}
    person=admin.get('/admin/api/v2/farmers/'+fi['owner']).json()['person']
    assert person['registrationLocation']['lat']==-26
    assert person['farms']==1
