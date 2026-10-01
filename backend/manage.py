"""Local administrator provisioning. No default privileged account is created."""
import argparse
import os
from pathlib import Path
from sqlalchemy import select,update


def update_role(engine, users, action, identifier):
    with engine.begin() as db:
        if action in {'grant-email-admin','revoke-email-admin'}:
            from email_auth import email_accounts
            owner=db.scalar(select(email_accounts.c.owner).where(email_accounts.c.email==identifier.strip().lower(),email_accounts.c.verified.is_(True)))
        else:
            owner=db.scalar(select(users.c.id).where(users.c.username==identifier.strip().lower()))
        if not owner:return False
        db.execute(update(users).where(users.c.id==owner).values(admin=action.startswith('grant-')))
    return True


def main():
    environment=Path(__file__).resolve().parent/'.env'
    if environment.is_file():
        for line in environment.read_text(encoding='utf-8').splitlines():
            value=line.strip()
            if not value or value.startswith('#') or '=' not in value:continue
            name,setting=value.split('=',1)
            if name.strip().replace('_','a').isalnum():os.environ.setdefault(name.strip(),setting)
    from app import app,users
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['grant-admin','revoke-admin','grant-email-admin','revoke-email-admin'])
    parser.add_argument('identifier',help='Legacy username, or verified email for an email action')
    args=parser.parse_args()
    if not update_role(app.state.engine,users,args.action,args.identifier):
        parser.error('Create and verify this account first through the matching sign-in flow.')
    print('Administrator role updated for the named local account.')


if __name__=='__main__':main()
