from concurrent.futures import ThreadPoolExecutor
from fastapi.testclient import TestClient
from test_api import service,account,op,poly

def farm(c):
    value=op(kind='farm',data={'name':'Test farm','points':poly([(0,0),(5,0),(5,5),(0,5)])})
    assert c.post('/sync/push',json=value).status_code==200
    return value

def test_stock_transactions_no_negative_balance_or_parent_deletion(service):
    c,identity=account(service,'stocktest');f=farm(c)
    stock=op(kind='stock',data={'name':'Seed','unit':'kg','farmId':f['id']})
    assert c.post('/sync/push',json=stock).status_code==200
    receipt=op(kind='stockmove',data={'stockId':stock['id'],'farmId':f['id'],'delta':10})
    assert c.post('/sync/push',json=receipt).status_code==200
    def spend(i):
        with TestClient(service) as s:return s.post('/sync/push',headers={'Authorization':'Bearer '+identity['token']},json=op(kind='stockmove',data={'stockId':stock['id'],'farmId':f['id'],'delta':-7})).status_code
    with ThreadPoolExecutor(2) as pool:result=list(pool.map(spend,[1,2]))
    assert sorted(result)==[200,422]
    assert c.post('/sync/push',json=op(id=f['id'],kind='farm',data=f['data'],base_version=1,deleted=True)).status_code==422
    assert c.post('/sync/push',json=op(id=stock['id'],kind='stock',data={**stock['data'],'unit':'litres'},base_version=1)).status_code==422

def test_harvest_sale_limits_currency_totals_and_payment_update(service):
    c,_=account(service,'harvesttest');f=farm(c)
    h=op(kind='harvest',data={'name':'Maize','unit':'kg','quantity':20,'farmId':f['id'],'date':'2026-09-12'})
    assert c.post('/sync/push',json=h).status_code==200
    sale=op(kind='sale',data={'harvestId':h['id'],'farmId':f['id'],'quantity':11,'unitPrice':12.5,'currency':'ZAR','payment':'Unpaid','total':0})
    r=c.post('/sync/push',json=sale);assert r.status_code==200 and r.json()['record']['data']['total']==137.5
    assert c.post('/sync/push',json=op(kind='sale',data={**sale['data'],'quantity':10})).status_code==422
    assert c.post('/sync/push',json=op(id=sale['id'],kind='sale',data={**sale['data'],'payment':'Paid'},base_version=1)).status_code==200
    assert c.post('/sync/push',json=op(id=h['id'],kind='harvest',data={**h['data'],'quantity':5},base_version=1)).status_code==422
    assert c.post('/sync/push',json=op(kind='harvest',data={**h['data'],'date':'2026-02-30'})).status_code==422

def test_season_field_link_cannot_cross_fields(service):
    c,_=account(service,'seasontest');f=farm(c)
    a=op(kind='field',data={'name':'A','farmId':f['id'],'points':poly([(0,0),(1,0),(1,1),(0,1)])})
    b=op(kind='field',data={**a['data'],'name':'B'})
    for r in [a,b]:assert c.post('/sync/push',json=r).status_code==200
    season=op(kind='season',data={'name':'Summer','farmId':f['id'],'fieldId':a['id'],'status':'Active'})
    assert c.post('/sync/push',json=season).status_code==200
    harvest=op(kind='harvest',data={'name':'Maize','farmId':f['id'],'fieldId':b['id'],'seasonId':season['id'],'unit':'kg','quantity':10})
    assert c.post('/sync/push',json=harvest).status_code==422
    assert c.post('/sync/push',json={**harvest,'data':{**harvest['data'],'fieldId':a['id']}}).status_code==200
    assert c.post('/sync/push',json=op(id=season['id'],kind='season',data=season['data'],base_version=1,deleted=True)).status_code==422
