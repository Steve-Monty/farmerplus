"""Disposable loopback UI fixture. Never imported by production app."""
import sys, tempfile
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from app import create_app, users
from fastapi.testclient import TestClient
from fastapi.staticfiles import StaticFiles
from sqlalchemy import update
from uuid import uuid4
from miniapp_api import allow_verified_frame_scripts
import uvicorn

directory=tempfile.TemporaryDirectory(prefix='farmer-miniapp-qa-')
app=create_app(data_dir=Path(directory.name),testing=True)
@app.middleware('http')
async def preview_headers(request,call_next):
    response=await call_next(request)
    if request.url.path == '/index.html':
        response.headers['Content-Security-Policy']="default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; img-src 'self' data: blob:; worker-src 'self' blob:; connect-src 'self'; object-src 'none'"
        response=await allow_verified_frame_scripts(response)
    return response
client=TestClient(app)
credentials={'username':'animal-preview','password':'Local-QA-Only123'}
client.post('/auth/register',json=credentials)
client.post('/auth/login',json=credentials)
owner=client.get('/auth/me').json()['owner']
with app.state.engine.begin() as db:
    db.execute(update(users).where(users.c.id==owner).values(admin=True))
farm=str(uuid4())
for kind,key,data in [('farm',farm,{'name':'Tarlton Farm · test','points':[]}),('field',str(uuid4()),{'name':'House 2','farmId':farm,'areaType':'Poultry house','points':[]}),('field',str(uuid4()),{'name':'House 3','farmId':farm,'areaType':'Poultry house','points':[]})]:
    response=client.post('/sync/push',json={'id':key,'op_id':str(uuid4()),'kind':kind,'base_version':0,'data':data})
    assert response.status_code==200,response.text
@app.get('/qa/fixture')
def fixture():
    return {'owner':owner,'credentials':credentials,'records':client.get('/sync/pull').json()['records']}
app.mount('/',StaticFiles(directory='C:/Farmer PWA/build/miniapp-preview',html=True),name='qa-ui')
if __name__=='__main__':uvicorn.run(app,host='127.0.0.1',port=5187)
