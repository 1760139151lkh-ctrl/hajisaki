"""Capture actual page-image API responses for visual inspection, without altering the PDF."""
from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path
import urllib.request


def main() -> None:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact',required=True)
    parser.add_argument('--credentials',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--origin',default='http://127.0.0.1:8765')
    args=parser.parse_args()
    credentials=json.loads(args.credentials.read_text(encoding='utf-8'))
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    args.output.mkdir(parents=True,exist_ok=True)
    page,total=0,1
    while page<total:
        url=args.origin+'/api/artifacts/'+args.artifact+'/page-image?page='+str(page)+'&width=2048'
        request=urllib.request.Request(url,headers={'Authorization':'Bearer '+credentials['token'],'X-Haji-Device':credentials['device']})
        with opener.open(request,timeout=30) as response: result=json.load(response)
        if not result.get('supported'): raise RuntimeError(result.get('reason','The page was not available.'))
        total=result['pages']
        path=args.output/('page-'+str(page+1)+('.png' if result['mime']=='image/png' else '.jpg'))
        path.write_bytes(base64.b64decode(result['image_base64'],validate=True))
        print(json.dumps({'page':page+1,'pages':total,'width':result['width'],'height':result['height'],'path':str(path),'bytes':path.stat().st_size},ensure_ascii=False))
        page+=1


if __name__=='__main__': main()
