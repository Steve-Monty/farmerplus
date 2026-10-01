"""Provision the sole local administrator from JSON on stdin. Never echo credentials."""
import json
import sys
from pathlib import Path
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def provision(app, username, password):
    from app import users, students, contacts, password_hash
    from admin_auth import credentials, sessions
    from sqlalchemy import select, insert, update, delete
    from operations import staff
    if not app.state.admin_auth.enabled:
        raise ValueError('Enable FARMER_ADMIN_LOCAL_LOGIN before provisioning')
    username = username.strip().lower()
    if not 3 <= len(username) <= 64 or not 1 <= len(password) <= 256:
        raise ValueError('Invalid credential lengths')
    with app.state.engine.begin() as db:
        row = db.execute(select(users).where(users.c.username == username)).mappings().first()
        if row and row['password'] != '!admin-only':
            raise ValueError('An existing non-administration account has this username; review before changing it')
        owner = row['id'] if row else str(uuid4())
        # Existing farmer records remain intact. Only the named operator has admin access.
        db.execute(update(users).values(admin=False))
        if not row:
            db.execute(insert(users).values(id=owner, username=username, password='!admin-only', admin=True, serial=0))
            db.execute(insert(students).values(owner=owner, student_id=uuid4().hex, provider='local', firstname='', lastname=''))
            db.execute(insert(contacts).values(owner=owner, email=username, verified=True))
        else:
            db.execute(update(users).where(users.c.id == owner).values(admin=True))
        db.execute(delete(credentials))
        db.execute(insert(credentials).values(owner=owner, password=password_hash(password)))
        db.execute(delete(sessions))
        db.execute(delete(staff).where(staff.c.owner == owner))
        db.execute(insert(staff).values(owner=owner, role='admin'))
        app.state.oidc.state(db, owner, True)
        if getattr(app.state, 'tenancy', None):
            from tenancy import control
            row = db.execute(select(control).where(control.c.id == 1)).first()
            if row:
                db.execute(update(control).where(control.c.id == 1).values(superadmin=owner))
        app.state.oidc.log(db, owner, 'admin_local_provisioned', owner, 'success')
    return owner


if __name__ == '__main__':
    from app import app
    data = json.load(sys.stdin)
    provision(app, data['username'], data['password'])
    print('Sole local administrator provisioned; existing records retained.')
