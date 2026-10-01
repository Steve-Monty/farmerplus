"""Read-only, tenant-scoped views of farmer-owned community settings."""
import json
from sqlalchemy import select, func
from community import preferences, recipients, grants, coops, memberships, events, POLICY, Community
from fastapi import HTTPException

CATEGORY_NAMES = {'government': 'Government', 'finance': 'Finance Providers',
                  'insurance': 'Insurance Providers', 'cooperatives': 'Cooperatives', 'inputs': 'Input Suppliers'}

def reporting_health(engine, owners):
    from admin_farmer import inventory, learning
    from phone_reports import reports
    from push_notifications import registrations
    items=[]
    with engine.connect() as db:
        for name,table,timestamp in [('App inventories',inventory,inventory.c.reported),
            ('Phone snapshots',reports,reports.c.received),('Cooperative activity',events,events.c.at),
            ('Sharing choices',preferences,preferences.c.updated),('Push registrations',registrations,registrations.c.updated),
            ('Moodle reports',learning,learning.c.checked)]:
            conditions=[table.c.owner.in_(owners)]
            if table is events:conditions.append(events.c.action.in_(['coop.join','coop.leave']))
            count,last=db.execute(select(func.count(),func.max(timestamp)).where(*conditions)).one()
            item=dict(name=name,records=count,lastReceived=last,status='Received' if last else 'No report received')
            if table is learning:
                failures=db.scalar(select(func.count()).select_from(learning).where(learning.c.owner.in_(owners),learning.c.error!=''))
                if failures:item['status']=str(failures)+' refresh errors · cached data retained'
            items.append(item)
    return items

def sharing(engine, owner):
    with engine.connect() as db:
        choices = {r['category']: dict(r) for r in db.execute(select(preferences).where(preferences.c.owner == owner)).mappings()}
        consent = {r['recipient']: dict(r) for r in db.execute(select(grants).where(grants.c.owner == owner)).mappings()}
        organisations = [dict(r) for r in db.execute(select(recipients)).mappings()]
        # Use the same fail-closed gate as actual disclosure, including Coop
        # installation and current terms, without mounting or migrating anything.
        gate = object.__new__(Community)
        effective = {}
        for recipient in organisations:
            try:
                gate.allowed(db, owner, recipient['id'])
                effective[recipient['id']] = True
            except HTTPException:
                effective[recipient['id']] = False
    return {'policy': POLICY, 'choices': [dict(category=k, name=v,
        enabled=choices.get(k, {}).get('enabled', False), explicit=k in choices,
        updated=choices.get(k, {}).get('updated'), policy=choices.get(k, {}).get('policy'))
        for k, v in CATEGORY_NAMES.items()], 'recipients': [dict(id=r['id'], name=r['name'],
        category=r['category'], purpose=r['purpose'], fields=json.loads(r['fields']),
        consent=consent.get(r['id'], {}).get('enabled', False), updated=consent.get(r['id'], {}).get('updated'),
        effective=effective[r['id']])
        for r in organisations if r['enabled'] or r['id'] in consent]}

def coop_history(engine, owner, page=1):
    with engine.connect() as db:
        catalogue = {r['id']: dict(r) for r in db.execute(select(coops)).mappings()}
        current = [dict(r) for r in db.execute(select(memberships).where(memberships.c.owner == owner)).mappings()]
        history = [dict(r) for r in db.execute(select(events).where(events.c.owner == owner,
            events.c.action.in_(['coop.join', 'coop.leave'])).order_by(events.c.at.desc(), events.c.id)).mappings()]
    def info(key):
        r = catalogue.get(key, {})
        return dict(name=r.get('name', key), demo=r.get('demo', False), currency=r.get('currency'), annualMinor=r.get('annual_minor'))
    return {'type': 'coop', 'memberships': [{**r, **info(r['coop'])} for r in current],
        'events': [dict(id=r['id'], action=r['action'], at=r['at'], **info(r['target']),
            status=json.loads(r['result']).get('status'), policy=r['policy']) for r in history[(page-1)*25:page*25]],
        'total': len(history), 'page': page, 'pageSize': 25,
        'lastRecordAt': max([r['at'] for r in history] + [r['updated'] for r in current], default=None),
        'attribution': 'Server-confirmed cooperative activity. Demo membership is not real enrolment or payment.'}
