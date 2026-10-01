"""Desktop administration of server-synchronised farmer records."""
import json
from pathlib import Path
from fastapi import Depends, HTTPException, Query, Request
from fastapi.responses import FileResponse, RedirectResponse
from sqlalchemy import select, func
from geometry import validate, measures


def area_summary(data):
    """Never present a phone-supplied measurement as verified geometry."""
    mapped = None
    try:
        points = data.get('points', [])
        validate(points)
        mapped = measures(points)[0] / 10000
    except (ValueError, TypeError, KeyError):
        pass
    manual = data.get('manualAreaHa')
    if isinstance(manual, bool) or not isinstance(manual, (int, float)) or not 0 < manual < float('inf'):
        manual = None
    return {'mappedHa': mapped, 'declaredHa': manual, 'source': 'Mapped' if mapped is not None else 'Entered manually' if manual is not None else 'Not mapped'}


def register_admin_portal(app, engine, users, students, contacts, records, media, admin):
    root = Path(__file__).resolve().parent

    @app.get('/admin')
    def portal(request: Request):
        local_admin = app.state.admin_auth
        person = local_admin.current(request) if local_admin.enabled else app.state.oidc.central(request)
        if not person:
            if local_admin.enabled:
                return RedirectResponse('/admin/login', 303)
            if getattr(app.state.oidc, 'provider', None) == 'keycloak':
                return RedirectResponse('/oidc/web/login?destination=admin', 303)
            return RedirectResponse('/admin/identity', 303)
        app.state.workspace.authorize(person,request.query_params.get('tenant',''))
        return FileResponse(root / 'static' / 'admin.html')

    @app.get('/admin/api/farmers')
    def directory(q: str = Query('', max_length=100), page: int = Query(1, ge=1), user=Depends(admin)):
        scope = users.c.admin.is_(False)
        if q.strip():
            scope = scope & (users.c.username.ilike('%' + q.strip().replace('%', r'\%').replace('_', r'\_') + '%', escape='\\'))
        with engine.connect() as db:
            total = db.scalar(select(func.count()).select_from(users).where(scope))
            account_rows = db.execute(select(users.c.id, users.c.username).where(scope).order_by(users.c.username).offset((page-1)*30).limit(30)).mappings().all()
            people = []
            for account in account_rows:
                mapped = db.execute(select(students).where(students.c.owner == account['id'])).mappings().first()
                contact = db.execute(select(contacts).where(contacts.c.owner == account['id'])).mappings().first()
                counts = dict(db.execute(select(records.c.kind, func.count()).where(records.c.owner == account['id'], records.c.deleted.is_(False)).group_by(records.c.kind)).all())
                last = db.scalar(select(func.max(records.c.updated)).where(records.c.owner == account['id']))
                people.append({'id':account['id'], 'username':account['username'], 'name':' '.join(filter(None,[mapped['firstname'],mapped['lastname']])) if mapped else '', 'studentId':mapped['student_id'] if mapped else None, 'email':contact['email'] if contact else None, 'counts':counts, 'lastSyncedRecord':last})
                farm_rows = db.execute(select(records.c.data).where(records.c.owner == account['id'], records.c.kind == 'farm', records.c.deleted.is_(False))).scalars().all()
                areas = [area_summary(json.loads(value)) for value in farm_rows]
                people[-1]['farmArea'] = {'mappedHa': sum(a['mappedHa'] for a in areas if a['mappedHa'] is not None), 'mappedCount': sum(a['mappedHa'] is not None for a in areas), 'unmappedCount': sum(a['mappedHa'] is None for a in areas)}
                people[-1]['health'] = app.state.operations.health(db, account['id'])
            totals = {'farmers':db.scalar(select(func.count()).select_from(users).where(users.c.admin.is_(False))), 'farms':db.scalar(select(func.count()).select_from(records.join(users, records.c.owner == users.c.id)).where(users.c.admin.is_(False), records.c.kind == 'farm', records.c.deleted.is_(False))), 'fields':db.scalar(select(func.count()).select_from(records.join(users, records.c.owner == users.c.id)).where(users.c.admin.is_(False), records.c.kind == 'field', records.c.deleted.is_(False)))}
        return {'people':people, 'total':total, 'page':page, 'pageSize':30, 'totals':totals, 'administrator':user['username']}

    @app.get('/admin/api/farmers/{owner}')
    def farmer(owner: str, page: int = Query(1, ge=1), user=Depends(admin)):
        with engine.begin() as db:
            account = db.execute(select(users.c.id, users.c.username, users.c.admin).where(users.c.id == owner)).mappings().first()
            if not account or account['admin']:
                raise HTTPException(404, 'Farmer not found')
            mapped = db.execute(select(students).where(students.c.owner == owner)).mappings().first()
            contact = db.execute(select(contacts).where(contacts.c.owner == owner)).mappings().first()
            total = db.scalar(select(func.count()).select_from(records).where(records.c.owner == owner, records.c.deleted.is_(False)))
            rows = db.execute(select(records).where(records.c.owner == owner, records.c.deleted.is_(False)).order_by(records.c.kind, records.c.id).offset((page-1)*100).limit(100)).mappings().all()
            app.state.oidc.log(db, user['id'], 'admin_farmer_view', owner, 'success')
        return {'username':account['username'], 'identity':{key:mapped[key] for key in ['student_id','firstname','lastname','moodle_id']} if mapped else {}, 'contact':{'email':contact['email'], 'verified':contact['verified']} if contact else None, 'records':[{'id':r['id'],'kind':r['kind'],'data':json.loads(r['data']),'area':area_summary(json.loads(r['data'])) if r['kind'] in {'farm','field'} else None,'version':r['version'],'updated':r['updated']} for r in rows], 'total':total, 'page':page, 'pageSize':100}

    @app.get('/admin/api/farmers/{owner}/media/{digest}')
    def attachment(owner: str, digest: str, user=Depends(admin)):
        from fastapi import Response
        with engine.begin() as db:
            person=db.execute(select(users.c.id).where(users.c.id==owner,users.c.admin.is_(False))).first()
            if not person:raise HTTPException(404,'Farmer not found')
            row=db.execute(select(media).where(media.c.owner==owner,media.c.hash==digest,media.c.complete.is_(True))).mappings().first()
            if not row:raise HTTPException(404,'Attachment is not synchronised')
            app.state.oidc.log(db,user['id'],'admin_attachment_download',owner,'success')
            return Response(bytes(row['body']),media_type='application/octet-stream',headers={'Content-Disposition':f'attachment; filename="{digest if len(digest)==64 and all(c in "0123456789abcdef" for c in digest) else "attachment"}.bin"'})
