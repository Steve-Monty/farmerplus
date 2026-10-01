"""Additive identity schema migration with a durable version/checksum journal.

No identity ownership is migrated here. Existing app/Moodle records are preserved.
Destructive rollback is deliberately not automatic; restore into a separate database.
"""
import hashlib
from sqlalchemy import MetaData,Table,Column,String,Text,select,insert,text
from sqlalchemy.schema import CreateTable
def apply_additive_schema(engine, metadata, version, description):
    journal_meta = MetaData()
    journal = Table('farmerplus_schema_migrations', journal_meta,
        Column('version', String(64), primary_key=True), Column('checksum', String(64), nullable=False),
        Column('description', Text, nullable=False))
    statements = '\n'.join(str(CreateTable(t).compile(dialect=engine.dialect)) for t in metadata.sorted_tables)
    checksum = hashlib.sha256(statements.encode()).hexdigest()
    with engine.begin() as db:
        if db.dialect.name == 'postgresql': db.execute(text('SELECT pg_advisory_xact_lock(748521932)'))
        journal_meta.create_all(db)
        previous = db.execute(select(journal).where(journal.c.version == version)).mappings().first()
        if previous and previous['checksum'] != checksum: raise RuntimeError('Schema checksum changed without a new migration version')
        if not previous:
            metadata.create_all(db)
            db.execute(insert(journal).values(version=version, checksum=checksum, description=description))
    return {'version': version, 'checksum': checksum}

def apply_identity_schema(engine,metadata):
    journal_meta=MetaData()
    journal=Table('farmerplus_schema_migrations',journal_meta,Column('version',String(64),primary_key=True),Column('checksum',String(64),nullable=False),Column('description',Text,nullable=False))
    version='20260912_01_hydra_identity'
    statements='\n'.join(str(CreateTable(t).compile(dialect=engine.dialect)) for t in metadata.sorted_tables)
    checksum=hashlib.sha256(statements.encode()).hexdigest()
    with engine.begin() as db:
        if db.dialect.name=='postgresql':db.execute(text('SELECT pg_advisory_xact_lock(748521932)'))
        journal_meta.create_all(db)
        previous=db.execute(select(journal).where(journal.c.version==version)).mappings().first()
        if previous and previous['checksum']!=checksum:raise RuntimeError('Identity schema changed without a new migration version; deployment stopped')
        if not previous:
            metadata.create_all(db)
            db.execute(insert(journal).values(version=version,checksum=checksum,description='Add dedicated identity policy, protected sessions, audit, recovery reviews and durable revocation tables; retain existing accounts'))
        return {'version':version,'checksum':checksum}
