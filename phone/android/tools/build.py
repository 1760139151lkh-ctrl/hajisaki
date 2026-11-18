"""Build and self-sign the real Android APK with the project SDK and JDK."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

PROJECT=Path(__file__).resolve().parents[1]
ROOT=PROJECT.parents[1]
STAGE=Path('C:/Users/17601/HajiSakiAndroidBuild')
FLAGS=subprocess.CREATE_NO_WINDOW

def run(args,cwd,env=None):
    result=subprocess.run([str(a) for a in args],cwd=cwd,env=env,shell=False,creationflags=FLAGS,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    decoded=result.stdout.decode('utf-8',errors='replace')
    with (STAGE/'build.log').open('a',encoding='utf-8') as log:log.write(decoded+'\n')
    print(decoded[-2200:],flush=True)
    if result.returncode:raise SystemExit(result.returncode)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bootstrap', type=Path, default=ROOT/'runtime/mobile/app-bootstrap.json')
    parser.add_argument('--previous-origin', help='Prior address for this same paired host')
    args = parser.parse_args()
    marker=STAGE/'.hajisaki-android-build'
    if STAGE.exists() and (not marker.is_file() or marker.read_text(encoding='utf-8')!=str(PROJECT)):
        raise ValueError('Android stage belongs to another project')
    STAGE.mkdir(exist_ok=True);marker.write_text(str(PROJECT),encoding='utf-8')
    from send2trash import send2trash
    frontend=ROOT/'studio/dist-android'
    if frontend.exists():send2trash(str(frontend.resolve()))
    run([sys.executable,ROOT/'tools/run.py','--cwd',ROOT/'studio','--timeout','0','--','npm','run','build','--','--outDir','dist-android'],ROOT)
    # Vite's manifest omits worker entry files. Package the complete fresh build.
    files={str(path.relative_to(frontend)) for path in frontend.rglob('*') if path.is_file()}
    web=PROJECT/'android/app/src/main/assets/public'
    if web.exists():
        if not web.resolve().is_relative_to(PROJECT.resolve()):raise ValueError('Web assets escaped Android project')
        send2trash(str(web.resolve()))
    web.mkdir(parents=True)
    for name in files:
        source=frontend/name
        if source.is_file():
            dest=web/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,dest)
    for name in ['avatars-youth','scenes-user','audio','icons','stickers-web','scenes-web']:
        source=ROOT/'shared/assets'/name
        if source.is_dir():shutil.copytree(source,web/'artwork'/name,dirs_exist_ok=True)
    staged_web=STAGE/'android/app/src/main/assets/public'
    if staged_web.exists():send2trash(str(staged_web.resolve()))
    shutil.copytree(PROJECT/'android',STAGE/'android',dirs_exist_ok=True,ignore=shutil.ignore_patterns('build','.gradle'))
    shutil.copytree(PROJECT/'node_modules',STAGE/'node_modules',dirs_exist_ok=True)
    bootstrap=args.bootstrap
    if bootstrap.exists():
        bootstrap_data = json.loads(bootstrap.read_text(encoding='utf-8'))
        if args.previous_origin:
            bootstrap_data['previousOrigin'] = args.previous_origin
        (STAGE/'android/app/src/main/assets/mobile-bootstrap.json').write_text(json.dumps(bootstrap_data), encoding='utf-8')
    sdk=STAGE/'sdk'
    shutil.copytree(ROOT/'tooling/android-sdk',sdk,dirs_exist_ok=True)
    (STAGE/'android/local.properties').write_text('sdk.dir='+str(sdk.resolve()).replace('\\','/').replace(':','\\:')+'\n',encoding='utf-8')
    props=STAGE/'android/gradle.properties'
    props.write_text(props.read_text(encoding='utf-8')+'\norg.gradle.daemon=false\norg.gradle.jvmargs=-Xmx2048m\nsystemProp.http.proxyHost=127.0.0.1\nsystemProp.http.proxyPort=10808\nsystemProp.https.proxyHost=127.0.0.1\nsystemProp.https.proxyPort=10808\n',encoding='utf-8')
    wrapper=STAGE/'android/gradle/wrapper/gradle-wrapper.properties'
    wrapper.write_text(wrapper.read_text().replace('-all.zip','-bin.zip').replace('networkTimeout=10000','networkTimeout=120000'),encoding='utf-8')
    license_node=ET.parse(ROOT/'tooling/android-downloads/repository2-3.xml').getroot()
    licenses=sdk/'licenses';licenses.mkdir(exist_ok=True)
    for node in license_node:
        if node.tag.endswith('license'):
            text=''.join(node.itertext());(licenses/node.attrib['id']).write_text(hashlib.sha1(text.encode()).hexdigest()+'\n',encoding='ascii')
    env=os.environ.copy();env['ANDROID_HOME']=str(sdk.resolve())
    print('Compiling Android release APK',flush=True)
    run([STAGE/'android/gradlew.bat','assembleRelease','--no-daemon'],STAGE/'android',env)
    signing=Path('C:/Users/17601/HajiSakiAndroidSigning');signing.mkdir(parents=True,exist_ok=True)
    password=signing/'keystore-password.txt';key=signing/'hajisaki.jks'
    if not password.exists():password.write_text(secrets.token_hex(32),encoding='ascii')
    env['HAJI_ANDROID_SIGNING_PASSWORD']=password.read_text(encoding='ascii')
    if not key.exists():run(['keytool','-genkeypair','-keystore',key,'-storepass:env','HAJI_ANDROID_SIGNING_PASSWORD','-keypass:env','HAJI_ANDROID_SIGNING_PASSWORD','-alias','hajisaki','-keyalg','RSA','-keysize','3072','-validity','10000','-dname','CN=HajiSaki,O=Personal,C=CN'],ROOT,env)
    sys.path.insert(0,str(ROOT/'host'))
    from hajisaki.config import protect_credentials
    protect_credentials(password);protect_credentials(key)
    tools=next((sdk/'build-tools').glob('*/aapt2.exe')).parent
    unsigned=STAGE/'android/app/build/outputs/apk/release/app-release-unsigned.apk'
    aligned=STAGE/'hajisaki-aligned.apk'
    run([tools/'zipalign.exe','-f','4',unsigned,aligned],ROOT)
    target=STAGE/'hajisaki-android.apk'
    signer=tools/'lib/apksigner.jar'
    run(['java','-jar',signer,'sign','--ks',key,'--ks-key-alias','hajisaki','--ks-pass','file:'+str(password),'--out',target,aligned],ROOT,env)
    run(['java','-jar',signer,'verify','--verbose',target],ROOT)
    release=ROOT/'releases/hajisaki-android.apk';shutil.copy2(target,release);target=release
    record={'artifact':target.name,'bytes':target.stat().st_size,'sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'package':'com.hajisaki.android','min_sdk':24,'target_sdk':36,'signing':'project self-signed release key; not Play/AppGallery publication','web_files':len(files)}
    (target.with_suffix('.manifest.json')).write_text(json.dumps(record,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(record,ensure_ascii=False),flush=True)

if __name__=='__main__':main()
