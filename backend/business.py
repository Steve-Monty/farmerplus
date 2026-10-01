"""Farm input and harvest integrity; call while holding the owner's write lock."""
import json
import math
import re
from datetime import date
from sqlalchemy import select

KINDS={'season','stock','stockmove','harvest','sale'}
def validate(db,records,owner,key,kind,data,deleted):
    if not deleted and kind in {'diary','task','calculation','pin'}:
        def context_record(identifier,expected):
            row=db.execute(select(records.c.data).where(records.c.owner==owner,records.c.id==str(identifier),records.c.kind==expected,records.c.deleted==False)).first()
            if not row:raise ValueError('The selected farm or area is unavailable')
            return json.loads(row[0])
        if data.get('fieldId'):
            area=context_record(data['fieldId'],'field')
            if not data.get('farmId'):data['farmId']=area['farmId']
            if area['farmId']!=data.get('farmId'):raise ValueError('Area belongs to another farm')
        if data.get('farmId'):context_record(data['farmId'],'farm')
        if kind=='pin':
            # Resolve legacy area links above, then store places at farm level.
            data.pop('fieldId',None)
            for name,maximum in [('lat',85),('lon',180)]:
                v=data.get(name)
                if isinstance(v,bool) or not isinstance(v,(int,float)) or not math.isfinite(v) or abs(v)>maximum:raise ValueError('Invalid place coordinates')
    if kind not in KINDS|{'farm','field'}:return
    if deleted and kind in {'farm','field','season'}:
        reference={'farm':'farmId','field':'fieldId','season':'seasonId'}[kind]
        for row in db.execute(select(records.c.data).where(records.c.owner==owner,records.c.deleted==False,records.c.id!=key)):
            if json.loads(row[0]).get(reference)==key:raise ValueError(f'Remove or reassign related records before deleting this {kind}')
    if kind not in KINDS:return
    if not deleted:
        if kind in {'stock','harvest','season'} and (not isinstance(data.get('name'),str) or not 1<=len(data['name'].strip())<=200):raise ValueError('Enter a record name of 1-200 characters')
        for field in ['date','start','expiry']:
            if data.get(field):
                if not isinstance(data[field],str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}',data[field]):raise ValueError('Use a valid calendar date')
                date.fromisoformat(data[field])
    previous=db.execute(select(records.c.data).where(records.c.owner==owner,records.c.id==key)).first()
    if previous and kind in {'stockmove','sale'}:
        prior=json.loads(previous[0]);field='stockId' if kind=='stockmove' else 'harvestId'
        if prior.get(field)!=data.get(field) or prior.get('farmId')!=data.get('farmId'):raise ValueError('A saved movement must keep its original item and farm')
    def parent(identifier,expected):
        row=db.execute(select(records.c.data).where(records.c.owner==owner,records.c.id==str(identifier),records.c.kind==expected,records.c.deleted==False)).first()
        if not row:raise ValueError(f'The related {expected} record is unavailable')
        return json.loads(row[0])
    def related(type,field,value):
        rows=db.execute(select(records.c.data).where(records.c.owner==owner,records.c.kind==type,records.c.deleted==False,records.c.id!=key)).all()
        return [d for r in rows if (d:=json.loads(r[0])).get(field)==value]
    def number(field,zero=False):
        v=data.get(field)
        if isinstance(v,bool) or not isinstance(v,(int,float)) or not math.isfinite(v) or (v<0 if zero else v<=0):raise ValueError(f'Invalid {field}')
        return v
    if not deleted:
        parent(data.get('farmId'),'farm')
        for field,type in [('fieldId','field'),('seasonId','season')]:
            if data.get(field) and parent(data[field],type).get('farmId')!=data['farmId']:raise ValueError(f'The {type} belongs to another farm')
        if data.get('seasonId'):
            season=parent(data['seasonId'],'season')
            if season.get('fieldId') and season.get('fieldId')!=data.get('fieldId'):raise ValueError('Choose the field assigned to this season')
    if kind=='stock':
        if not deleted and (not isinstance(data.get('unit'),str) or not data['unit'].strip()):raise ValueError('Choose a stock unit')
        moves=related('stockmove','stockId',key)
        if deleted and moves:raise ValueError('Remove stock movements before deleting their item')
        old=db.execute(select(records.c.data).where(records.c.owner==owner,records.c.id==key)).first()
        if old and moves:
            old=json.loads(old[0])
            if old.get('unit')!=data.get('unit') or old.get('farmId')!=data.get('farmId'):raise ValueError('Keep the unit and farm of an item with movements')
    if kind=='stockmove':
        item=parent(data.get('stockId'),'stock')
        if item.get('farmId')!=data.get('farmId'):raise ValueError('Stock item belongs to another farm')
        delta=data.get('delta')
        if isinstance(delta,bool) or not isinstance(delta,(float,int)) or not math.isfinite(delta) or not delta:raise ValueError('Invalid stock movement quantity')
        balance=sum(r['delta'] for r in related('stockmove','stockId',data['stockId']))+(0 if deleted else delta)
        if balance < -1e-8:raise ValueError('Stock used exceeds stock received')
    if kind=='harvest':
        if not deleted and (not isinstance(data.get('unit'),str) or not data['unit'].strip()):raise ValueError('Choose a harvest unit')
        sales=related('sale','harvestId',key)
        if deleted and sales:raise ValueError('Remove sales before deleting their harvest')
        if not deleted and sum(r['quantity'] for r in sales)>number('quantity')+1e-8:raise ValueError('Harvest is smaller than linked sales')
        old=db.execute(select(records.c.data).where(records.c.owner==owner,records.c.id==key)).first()
        if old and sales:
            old=json.loads(old[0])
            if old.get('unit')!=data.get('unit') or old.get('farmId')!=data.get('farmId'):raise ValueError('Keep the unit and farm of a harvest with sales')
    if kind=='sale' and not deleted:
        harvest=parent(data.get('harvestId'),'harvest')
        if harvest.get('farmId')!=data.get('farmId'):raise ValueError('Harvest belongs to another farm')
        quantity=number('quantity');price=number('unitPrice',zero=True)
        if not re.fullmatch('[A-Z]{3}',data.get('currency','')):raise ValueError('Invalid currency code')
        if data.get('payment') not in {'Paid','Unpaid'}:raise ValueError('Invalid payment status')
        sold=sum(r['quantity'] for r in related('sale','harvestId',data['harvestId']))+quantity
        if sold>harvest['quantity']+1e-8:raise ValueError('Sale exceeds the unsold harvest quantity')
        data['unit']=harvest['unit'];data['total']=round(quantity*price,2)
    if kind=='season' and not deleted and data.get('status') not in {'Planned','Active','Closed'}:raise ValueError('Invalid season status')
