"""Capture the owned Android guest for focused visual inspection."""
import argparse
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[3]
parser=argparse.ArgumentParser();parser.add_argument('name');args=parser.parse_args()
if not args.name.replace('-','').isalnum():parser.error('Use a plain capture name')
adb=[str(ROOT/'tooling/android-sdk/platform-tools/adb.exe'),'-P','5038','-s','127.0.0.1:16544']
def run(*command):
    result=subprocess.run(adb+list(command),shell=False,creationflags=subprocess.CREATE_NO_WINDOW,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    return result
folder=ROOT/'runtime/android';folder.mkdir(parents=True,exist_ok=True)
run('shell','uiautomator','dump','/sdcard/hajisaki-ui.xml')
tree=run('shell','cat','/sdcard/hajisaki-ui.xml');tree.check_returncode();(folder/(args.name+'.xml')).write_bytes(tree.stdout)
shot=run('exec-out','screencap','-p');shot.check_returncode();(folder/(args.name+'.png')).write_bytes(shot.stdout)
for node in ET.fromstring(tree.stdout).iter('node'):
    text=node.get('text') or node.get('content-desc')
    if node.get('class')=='android.widget.EditText':text='[editable field]'
    if text and node.get('bounds')!='[0,0][0,0]':print(node.get('class'),text[:120],node.get('bounds'))
print('Image',folder/(args.name+'.png'))
