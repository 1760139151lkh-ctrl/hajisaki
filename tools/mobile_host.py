"""Start the authenticated mobile ingress and an outbound HTTPS connection, independently of Codex."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import subprocess
import sys
import time
import urllib.request
import psutil

ROOT=Path(__file__).resolve().parents[1]
DATA=ROOT/'runtime/mobile'
VERSION='2026.11.0'
SHA256='d5c1d82031da6253dcdcff64c944cd0fe063016edeb2e4fd088075fc9bd52d0a'
FLAGS=subprocess.CREATE_NO_WINDOW

def alive(pid):
    if not isinstance(pid,int) or pid<=0:return False
    try:return psutil.Process(pid).is_running()
    except psutil.Error:return False

def main():
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['start','status']);parser.add_argument('--restart-gateway',action='store_true');parser.add_argument('--invite-name');args=parser.parse_args()
    if args.invite_name and not re.fullmatch(r'[a-z0-9-]{1,40}',args.invite_name):parser.error('Invitation name must use lowercase letters, digits or hyphens')
    DATA.mkdir(parents=True,exist_ok=True)
    state_file=DATA/'host.json';state=json.loads(state_file.read_text()) if state_file.exists() else {}
    if args.action=='status':
        print(json.dumps({'gateway_alive':alive(state.get('gateway_pid',-1)),'tunnel_alive':alive(state.get('tunnel_pid',-1)),'origin':state.get('origin')},ensure_ascii=False));return
    if args.restart_gateway and alive(state.get('gateway_pid',-1)):
        process=psutil.Process(state['gateway_pid'])
        if str(ROOT/'tools/mobile_gateway.py').lower() not in ' '.join(process.cmdline()).lower():raise RuntimeError('Gateway PID ownership changed')
        for child in process.children(recursive=True):child.terminate()
        process.terminate();psutil.wait_procs([process],timeout=5)
        state.pop('gateway_pid',None)
    tools=ROOT/'tooling/cloudflared';tools.mkdir(parents=True,exist_ok=True)
    binary=tools/'cloudflared.exe'
    if not binary.exists() or hashlib.sha256(binary.read_bytes()).hexdigest()!=SHA256:
        url=f'https://github.com/cloudflare/cloudflared/releases/download/{VERSION}/cloudflared-windows-amd64.exe'
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({'https':'http://127.0.0.1:10808'}))
        with opener.open(url,timeout=90) as response,binary.open('wb') as output:
            while chunk:=response.read(1024*1024):output.write(chunk)
        if hashlib.sha256(binary.read_bytes()).hexdigest()!=SHA256:raise ValueError('Official cloudflared SHA256 mismatch')
    if not alive(state.get('gateway_pid',-1)):
        log=(DATA/'gateway.log').open('ab')
        proc=subprocess.Popen([sys.executable,'-X','utf8','-B',str(ROOT/'tools/mobile_gateway.py')],cwd=ROOT,shell=False,creationflags=FLAGS,stdin=subprocess.DEVNULL,stdout=log,stderr=log)
        state['gateway_pid']=proc.pid;state_file.write_text(json.dumps(state),encoding='utf-8')
    if not alive(state.get('tunnel_pid',-1)):
        name='tunnel-'+str(int(time.time()))+'.log';log=(DATA/name).open('ab')
        proc=subprocess.Popen([str(binary),'tunnel','--url','http://127.0.0.1:8766','--protocol','http2','--no-autoupdate'],cwd=ROOT,shell=False,creationflags=FLAGS,stdin=subprocess.DEVNULL,stdout=log,stderr=log)
        state.update(tunnel_pid=proc.pid,tunnel_log=name);state_file.write_text(json.dumps(state),encoding='utf-8')
    for _ in range(60):
        text=(DATA/state['tunnel_log']).read_text(encoding='utf-8',errors='replace')
        found=re.search(r'https://[a-z0-9-]+\.trycloudflare\.com',text)
        if found:state['origin']=found[0];break
        if not alive(state['tunnel_pid']):raise RuntimeError('Outbound connection exited; inspect tunnel log')
        time.sleep(1)
    if not state.get('origin'):raise RuntimeError('Outbound address not returned; retain process and inspect its existing log')
    state_file.write_text(json.dumps(state,indent=2),encoding='utf-8')
    db=sqlite3.connect(DATA/'gateway.sqlite3')
    db.execute('CREATE TABLE IF NOT EXISTS invitations(digest TEXT PRIMARY KEY,expires REAL NOT NULL,instance TEXT,credential TEXT)')
    for name in ['app-bootstrap','qa-bootstrap']+([args.invite_name] if args.invite_name else []):
        path=DATA/(name+'.json')
        if not path.exists():
            code=secrets.token_urlsafe(32);db.execute('INSERT INTO invitations(digest,expires) VALUES(?,?)',(hashlib.sha256(code.encode()).hexdigest(),time.time()+7*86400))
            path.write_text(json.dumps({'origin':state['origin'],'code':code}),encoding='utf-8')
    db.commit();db.close()
    delivery=DATA/'delivery.json'
    if not delivery.exists():delivery.write_text(json.dumps({'download_key':secrets.token_urlsafe(32)}),encoding='utf-8')
    sys.path.insert(0,str(ROOT/'host'))
    from hajisaki.config import protect_credentials,secure_data_directory
    secure_data_directory(DATA)
    for path in DATA.glob('*.json'):protect_credentials(path)
    print(json.dumps({'origin':state['origin'],'gateway_pid':state['gateway_pid'],'tunnel_pid':state['tunnel_pid'],'bootstrap_files':'runtime/mobile/{app,qa}-bootstrap.json'},ensure_ascii=False))

if __name__=='__main__':main()
