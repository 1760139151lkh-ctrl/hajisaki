"""Authenticated, narrowly routed mobile ingress; never exposes local owner/agent endpoints."""
from __future__ import annotations
import argparse
import asyncio
import hashlib
import json
from pathlib import Path
import re
import secrets
import sqlite3
import time

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, StreamingResponse
from starlette.background import BackgroundTask
from pydantic import BaseModel, ConfigDict, Field
import uvicorn

ROOT=Path(__file__).resolve().parents[1]
DATA=ROOT/'runtime/mobile'
DATA.mkdir(parents=True,exist_ok=True)
DB=DATA/'gateway.sqlite3'
ID=r'[A-Za-z0-9_-]{1,128}'
ROUTES=[('GET',r'/api/(health|status|models|conversations|memories|settings|artifacts|reminders|inbox)'),
 ('POST',r'/api/(conversations|memories|uploads|reminders)'),('POST',r'/api/settings/update'),
 ('GET',rf'/api/conversations/{ID}/(messages|events|origin|composer|threads|arenas)'),
 ('POST',rf'/api/conversations/{ID}/(messages|fork|update|tone|compact|threads|arenas)'),
 ('POST',rf'/api/runs/{ID}/stop'),('GET',rf'/api/uploads/{ID}'),('PUT',rf'/api/uploads/{ID}'),
 ('POST',rf'/api/uploads/{ID}/(complete|restart)'),('GET',rf'/api/artifacts/{ID}/(content|inspect|text|search|sheet|page-image|thumbnail|image-info)'),
 ('POST',rf'/api/artifacts/{ID}/media-session'),('GET',rf'/api/messages/{ID}/(tasks|selection)'),
 ('POST',rf'/api/messages/{ID}/tasks/[0-9]+/update'),('GET',rf'/api/conversations/{ID}/pins'),
 ('POST',rf'/api/conversations/{ID}/pins'),('DELETE',rf'/api/pins/{ID}'),
 ('GET',rf'/api/arenas/{ID}'),('POST',rf'/api/arenas/{ID}/(resume|vote|reveal|stop)'),
 ('GET',r'/api/references/(roots|history)'),('GET',rf'/api/references/roots/{ID}/entries'),('POST',r'/api/references/snapshots'),
 ('GET',r'/api/speech/(status|hotwords)'),('POST',r'/api/speech/(transcriptions|clean)'),
 ('GET',rf'/api/speech/transcriptions/{ID}'),('POST',rf'/api/speech/transcriptions/{ID}/stop'),
 ('POST',r'/api/image-studio/(preview|export)')]
ROUTES=[(method,re.compile(path)) for method,path in ROUTES]
ROUTES += [(method,re.compile(pattern)) for method,pattern in [
 ('GET',r'/api/export'),('POST',rf'/api/memories/{ID}/update'),('DELETE',rf'/api/memories/{ID}'),
 ('PATCH',r'/api/settings'),('PATCH',rf'/api/memories/{ID}'),('PATCH',rf'/api/conversations/{ID}'),
 ('PUT',r'/api/speech/hotwords'),('POST',rf'/api/inbox/{ID}/read'),
 ('PATCH',rf'/api/reminders/{ID}'),
 ('POST',rf'/api/reminders/{ID}/update'),('GET',rf'/api/diagnostics/{ID}'),('GET',rf'/api/messages/{ID}/raw'),
 ('GET',rf'/api/media/{ID}/{ID}'),('HEAD',rf'/api/media/{ID}/{ID}')]]
app=FastAPI(docs_url=None,redoc_url=None,openapi_url=None)
join_lock=asyncio.Lock()

def connect():
    db=sqlite3.connect(DB,timeout=15);db.row_factory=sqlite3.Row;return db

with connect() as db:
    db.execute('CREATE TABLE IF NOT EXISTS invitations(digest TEXT PRIMARY KEY,expires REAL NOT NULL,instance TEXT,credential TEXT)')

class Join(BaseModel):
    model_config=ConfigDict(extra='forbid')
    code:str=Field(min_length=20,max_length=200)
    instance:str=Field(min_length=4,max_length=200)

@app.get('/health')
def health():return {'status':'ok','service':'hajisaki-mobile'}

@app.post('/join')
async def join(body:Join):
    async with join_lock:
        return await claim_invitation(body)

async def claim_invitation(body:Join):
    digest=hashlib.sha256(body.code.encode()).hexdigest()
    with connect() as db:
        row=db.execute('SELECT * FROM invitations WHERE digest=?',(digest,)).fetchone()
        if not row or row['expires']<time.time():raise HTTPException(403,'连接码已到期，请换一份新的。')
        if row['instance'] and row['instance']!=body.instance:raise HTTPException(403,'这份连接码已经交给另一台设备。')
        if row['credential']:return json.loads(row['credential'])
        owner=json.loads((ROOT/'runtime/pairing.json').read_text(encoding='utf-8'))
        async with httpx.AsyncClient(trust_env=False,timeout=20) as client:
            response=await client.post('http://127.0.0.1:8765/api/devices',headers={'Authorization':'Bearer '+owner['token'],'X-Haji-Device':owner['device']},json={'name':'Android手机','role':'companion'})
        if response.status_code not in (200,201):raise HTTPException(503,'主机暂时没有接好，请稍后重试。')
        credential=response.json()
        db.execute('UPDATE invitations SET instance=?,credential=? WHERE digest=?',(body.instance,json.dumps(credential),digest))
        return credential

@app.api_route('/api/{path:path}',methods=['GET','HEAD','POST','PUT','PATCH','DELETE'])
async def proxy(path:str,request:Request):
    route='/api/'+path
    if not any(method==request.method and rule.fullmatch(route) for method,rule in ROUTES):raise HTTPException(403,'这个入口不向手机开放。')
    headers={key:value for key,value in request.headers.items() if key.lower() in {'authorization','x-haji-device','content-type','range','if-range','x-haji-platform','x-haji-features','cookie'}}
    body=await request.body()
    if len(body)>9*1024*1024:raise HTTPException(413,'这一段传送太长，请分段送出。')
    client=httpx.AsyncClient(trust_env=False,timeout=90)
    try:
        response=await client.send(client.build_request(request.method,'http://127.0.0.1:8765'+route,params=request.query_params,headers=headers,content=body),stream=True)
    except httpx.HTTPError:
        await client.aclose();raise HTTPException(503,'主机的连接暂时松开了，请稍后再试。')
    async def close():
        await response.aclose();await client.aclose()
    outgoing={key:value for key,value in response.headers.items() if key in {'content-type','content-disposition','etag','accept-ranges','content-range','content-length','content-encoding'}}
    result=StreamingResponse(response.aiter_raw(),status_code=response.status_code,headers=outgoing,background=BackgroundTask(close))
    for cookie in response.headers.get_list('set-cookie'):
        result.headers.append('set-cookie',cookie.replace('SameSite=strict','SameSite=none')+'; Secure')
    return result

@app.get('/download/{key}/hajisaki.apk')
def download(key:str):
    config=json.loads((DATA/'delivery.json').read_text(encoding='utf-8'))
    if not secrets.compare_digest(key,config['download_key']):raise HTTPException(404)
    file=ROOT/'releases/hajisaki-android.apk'
    if not file.is_file():raise HTTPException(503,'安装包正在准备。')
    return FileResponse(file,media_type='application/vnd.android.package-archive',filename='hajisaki.apk',headers={'Cache-Control':'no-store','X-Robots-Tag':'noindex'})

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=8766);args=parser.parse_args()
    uvicorn.run(app,host='127.0.0.1',port=args.port,proxy_headers=False)
