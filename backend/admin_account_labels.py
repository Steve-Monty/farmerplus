"""Explicit account classification; never guess from usernames or delete accounts."""
import time
from typing import Literal
from fastapi import Request, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import MetaData, Table, Column, String, Integer, BigInteger, select, insert, update
from sqlalchemy.exc import IntegrityError
from schema_migrations import apply_additive_schema

meta=MetaData()
labels=Table('admin_account_labels',meta,Column('owner',String(36),primary_key=True),
    Column('classification',String(16),nullable=False),Column('revision',Integer,nullable=False),
    Column('updated',BigInteger,nullable=False),Column('actor',String(36),nullable=False),
    Column('reason',String(500),nullable=False))
class Label(BaseModel):
    model_config=ConfigDict(extra='forbid')
    classification:Literal['unknown','production','test']
    revision:int=Field(ge=0)
    reason:str=Field(min_length=3,max_length=500)

def mount(ws):
    apply_additive_schema(ws.engine,meta,'20260916_08_admin_account_labels','Explicit audited account classification')
    @ws.app.get('/admin/api/v2/farmers/{owner}/classification')
    def read(owner:str,request:Request,tenant:str=''):
        ctx=ws.authorize(ws.identity(request),tenant);ws.owner(ctx,owner)
        with ws.engine.connect() as db:r=db.execute(select(labels).where(labels.c.owner==owner)).mappings().first()
        return {'classification':'unknown','revision':0,**(dict(r) if r else {}),'canEdit':ctx['platform'] and ctx['canWrite']}
    @ws.app.post('/admin/api/v2/farmers/{owner}/classification')
    def save(owner:str,body:Label,request:Request,tenant:str=''):
        ctx=ws.authorize(ws.identity(request),tenant);ws.owner(ctx,owner)
        if not ctx['platform'] or not ctx['canWrite']:raise HTTPException(403,'Platform administrator required')
        if len(body.reason.strip())<3:raise HTTPException(422,'Explain the classification change')
        values=dict(classification=body.classification,revision=body.revision+1,updated=int(time.time()*1000),actor=ctx['actor']['id'],reason=body.reason.strip())
        try:
            with ws.engine.begin() as db:
                if body.revision==0:db.execute(insert(labels).values(owner=owner,**values))
                elif not db.execute(update(labels).where(labels.c.owner==owner,labels.c.revision==body.revision).values(**values)).rowcount:raise HTTPException(409,'Classification changed; refresh before saving')
                ws.log(db,ctx,'account_classification',owner,{'classification':body.classification,'reason':body.reason.strip(),'revision':values['revision']})
        except IntegrityError:raise HTTPException(409,'Classification changed; refresh before saving')
        return values
