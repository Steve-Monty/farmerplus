from sqlalchemy import insert, select
from test_oidc import identity
from operations import staff, changes

def test_view_only_support_and_required_reason(identity):
    app, provider, login = identity
    admin, admin_owner = login('admin', True)
    support, support_owner = login('support', True)
    _, owner = login('farmer')
    with app.state.engine.begin() as db:
        db.execute(insert(staff).values(owner=support_owner,role='support'))
    assert support.get('/admin/api/farmers').status_code==200
    body={'firstname':'Updated','lastname':'Farmer','email':None,'role':'farmer'}
    assert support.put('/admin/identity/people/'+owner,json=body).status_code==403
    del admin.headers['X-Change-Reason']
    assert admin.put('/admin/identity/people/'+owner,json=body).status_code==422
    admin.headers['X-Change-Reason']='Farmer requested correction during support call'
    assert admin.put('/admin/identity/people/'+owner,json=body).status_code==200
    with app.state.engine.connect() as db:
        rows=db.execute(select(changes)).mappings().all()
        assert len(rows)==1 and rows[0]['actor']==admin_owner
    assert support.post('/auth/native/login',json={'username':'support','password':'Fixture-only-Password'}).status_code in {401,403}
