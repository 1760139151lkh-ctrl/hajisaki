"""Fetch the official Android platform/build tools needed by this project's APK build."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

ROOT=Path(__file__).resolve().parents[3]
BASE='https://dl.google.com/android/repository/'

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk',type=Path,default=ROOT/'tooling/android-sdk')
    args=parser.parse_args()
    args.sdk.mkdir(parents=True,exist_ok=True)
    downloads=ROOT/'tooling/android-downloads';downloads.mkdir(parents=True,exist_ok=True)
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({'http':'http://127.0.0.1:10808','https':'http://127.0.0.1:10808'}))
    index=opener.open(BASE+'repository2-3.xml',timeout=45).read()
    (downloads/'repository2-3.xml').write_bytes(index)
    tree=ET.fromstring(index)
    packages={item.attrib['path']:item for item in tree if item.tag.endswith('remotePackage')}
    receipt=[]
    for name in ['platforms;android-36','build-tools;36.0.0','platform-tools']:
        item=packages[name]
        archives=item.find('archives').findall('archive')
        archive=next(a for a in archives if a.findtext('host-os') in (None,'windows'))
        complete=archive.find('complete');url=complete.findtext('url');checksum=complete.find('checksum')
        target=downloads/Path(url).name
        expected=checksum.text.strip();algorithm=checksum.attrib.get('type','sha1')
        valid=target.is_file() and hashlib.new(algorithm,target.read_bytes()).hexdigest()==expected
        if not valid:
            print('Downloading '+name+' from Google',flush=True)
            with opener.open(BASE+url,timeout=90) as response,target.open('wb') as output:
                while chunk:=response.read(1024*1024):output.write(chunk)
        actual=hashlib.new(algorithm,target.read_bytes()).hexdigest()
        if actual!=expected:raise ValueError('Official package checksum mismatch: '+name)
        destination=args.sdk/Path(*name.split(';'))
        destination.mkdir(parents=True,exist_ok=True)
        with zipfile.ZipFile(target) as archive_file:
            for entry in archive_file.infolist():
                parts=Path(entry.filename).parts[1:]
                if not parts:continue
                resolved=(destination/Path(*parts)).resolve()
                if not resolved.is_relative_to(destination.resolve()):raise ValueError('SDK archive path escaped destination')
                if entry.is_dir():resolved.mkdir(parents=True,exist_ok=True)
                else:
                    resolved.parent.mkdir(parents=True,exist_ok=True)
                    with archive_file.open(entry) as source,resolved.open('wb') as output:
                        import shutil
                        shutil.copyfileobj(source,output)
        receipt.append({'package':name,'url':BASE+url,'archive':str(target),'bytes':target.stat().st_size,'checksum':actual,'algorithm':algorithm})
        print('Ready '+name,flush=True)
    (downloads/'packages.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2),encoding='utf-8')

if __name__=='__main__':main()
