"""Ask Gemini through the existing authenticated CLI; retain the original research response."""
from pathlib import Path
import argparse
import json
import os
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('--conversation');parser.add_argument('--request',type=Path);args=parser.parse_args()
WORK=Path('C:/Users/17601/HajiSakiGeminiConsult')
marker=WORK/'.hajisaki-persona-consult'
if WORK.exists() and (not marker.exists() or marker.read_text('utf-8')!=str(ROOT)):
    raise RuntimeError('Consultation workspace belongs to another task')
WORK.mkdir(exist_ok=True);marker.write_text(str(ROOT),encoding='utf-8')
for name in ['research.md','current-prompts.md','consultation-request.md']:
    shutil.copy2(ROOT/'docs/persona'/name,WORK/name)
prompt=args.request.read_text('utf-8') if args.request else '\n\n'.join((WORK/name).read_text('utf-8') for name in ['consultation-request.md','research.md','current-prompts.md'])
env=os.environ.copy()
env.update(HTTP_PROXY='http://127.0.0.1:10808',HTTPS_PROXY='http://127.0.0.1:10808',ALL_PROXY='http://127.0.0.1:10808',NO_PROXY='127.0.0.1,localhost,::1')
for key in ['GEMINI_API_KEY','GOOGLE_API_KEY','GOOGLE_GENAI_USE_VERTEXAI']:env.pop(key,None)
executable=shutil.which('agy')
if not executable:raise RuntimeError('The authenticated Gemini-capable CLI is unavailable')
command=[executable,'--model','gemini-4-hydrogen-xhigh','--effort','xhigh','--mode','plan','--output-format','stream-json']
if args.conversation:command+=['--conversation',args.conversation]
command+=['--print',prompt]
destination=ROOT/'runtime/persona-consultation/gemini-hydrogen.jsonl'
destination.parent.mkdir(parents=True,exist_ok=True)
if destination.exists():raise RuntimeError('Inspect the existing Hydrogen consultation before starting another one')
print('Consulting Gemini 4 Hydrogen (XHigh) through authenticated Antigravity CLI',flush=True)
with destination.open('wb') as output:
    process=subprocess.Popen(command,cwd=WORK,env=env,shell=False,creationflags=subprocess.CREATE_NO_WINDOW,
        stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT)
    (WORK/'process.json').write_text(json.dumps({'pid':process.pid,'command':command[:-1]+['<consultation-request-and-source-context>'],'output':str(destination)}),encoding='utf-8')
    process.communicate()
print('CLI exit',process.returncode,'response bytes',destination.stat().st_size,flush=True)
if process.returncode:raise SystemExit(process.returncode)
