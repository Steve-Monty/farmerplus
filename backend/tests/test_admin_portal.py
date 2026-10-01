from fastapi.testclient import TestClient
from sqlalchemy import update
from app import create_app, users
from test_api import account, op
from admin_portal import area_summary


def test_area_uses_geometry_and_keeps_declared_area_separate():
    data={'points':[{'lat':0,'lon':0},{'lat':0,'lon':.01},{'lat':.01,'lon':.01},{'lat':.01,'lon':0}], 'areaM2':999999999, 'manualAreaHa':99}
    result=area_summary(data)
    assert 123 < result['mappedHa'] < 124
    assert result['declaredHa']==99
    assert area_summary({'areaM2':0})['source']=='Not mapped'
    assert area_summary({'manualAreaHa':10})=={'mappedHa':None,'declaredHa':10,'source':'Entered manually'}


def test_admin_directory_requires_role_and_keeps_farmer_scope(tmp_path):
    app=create_app(data_dir=tmp_path,testing=True)
    farmer, person=account(app,'test-farmer')
    second, _=account(app,'another-farmer')
    administrator, identity=account(app,'administrator')
    with app.state.engine.begin() as db:
        db.execute(update(users).where(users.c.id==identity['owner']).values(admin=True))
    item=op(kind='diary',data={'title':'Field visit','notes':'Inspected irrigation'})
    assert farmer.post('/sync/push',json=item).status_code==200
    assert TestClient(app).get('/admin/api/farmers').status_code==401
    assert farmer.get('/admin/api/farmers').status_code==403
    assert farmer.get('/admin/api/farmers/'+person['owner']).status_code==403
    listing=administrator.get('/admin/api/farmers').json()
    assert listing['total']==2
    assert listing['totals']['farmers']==2
    assert 'password' not in str(listing)
    detail=administrator.get('/admin/api/farmers/'+person['owner']).json()
    assert detail['records'][0]['data']['notes']=='Inspected irrigation'
    assert 'password' not in str(detail)
    assert second.get('/sync/pull').json()['records']==[]
    assert administrator.get('/admin/api/farmers?q=test-farmer').json()['total']==1
    assert administrator.get('/admin/api/farmers?page=0').status_code==422
    assert administrator.get('/admin').status_code==200
    static=administrator.get('/static/admin.js')
    assert static.status_code==200
    assert static.headers['cache-control']=='no-cache'
    assert administrator.get('/static/favicon.svg').status_code==200
    assert administrator.get('/favicon.ico').status_code==200
    assert TestClient(app).get('/',follow_redirects=False).headers['location']=='/admin'
    app.state.engine.dispose()
