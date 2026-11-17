"""Enroll one companion through the local owner API; keep its key in a private file."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import urllib.request

ROOT=Path(__file__).resolve().parents[1]


def main() -> None:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--name',required=True)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args()
    output=args.output.resolve()
    if output.exists():
        raise SystemExit('The credential/receipt file already exists; inspect it and the device list before enrolling again.')
    sys.path.insert(0,str(ROOT/'host'))
    from hajisaki.config import protect_credentials
    owner=json.loads((ROOT/'runtime/pairing.json').read_text(encoding='utf-8'))
    output.parent.mkdir(parents=True,exist_ok=True)
    with output.open('x',encoding='utf-8') as receipt:
        receipt.write(json.dumps({'status':'enrollment-pending','name':args.name},ensure_ascii=False))
    protect_credentials(output)
    request=urllib.request.Request('http://127.0.0.1:8765/api/devices',
        data=json.dumps({'name':args.name,'role':'companion'},ensure_ascii=False).encode('utf-8'),
        headers={'Authorization':'Bearer '+owner['token'],'X-Haji-Device':owner['device'],'Content-Type':'application/json'},method='POST')
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request,timeout=20) as response: issued=json.load(response)
    output.write_text(json.dumps(issued,ensure_ascii=False,indent=2),encoding='utf-8')
    protect_credentials(output)
    print(json.dumps({'device':issued['device'],'name':issued['name'],'role':issued['role'],'credential_file':str(output)},ensure_ascii=False))


if __name__=='__main__': main()
