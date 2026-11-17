"""Install a quiet per-user Windows logon task without copying account credentials.

The task runs as the signed-in owner, so Antigravity can use that owner's keyring.
This is a logon task, not a claim of a pre-login Windows service.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
NAME = 'HajiSaki-' + hashlib.sha256(str(ROOT).lower().encode()).hexdigest()[:10]
NS = 'http://schemas.microsoft.com/windows/2004/02/mit/task'


def command(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(list(args), shell=False, creationflags=subprocess.CREATE_NO_WINDOW,
                          capture_output=True, timeout=30)


def decoded(value: bytes) -> str:
    if value.startswith((b'\xff\xfe', b'\xfe\xff')):
        return value.decode('utf-16')
    if value[:80].count(b'\0') > 10:
        return value.decode('utf-16-le')
    for codec in ('utf-8', 'mbcs'):
        try:
            return value.decode(codec)
        except UnicodeError:
            pass
    return value.decode('utf-8', errors='replace')


def owned_task() -> bool:
    existing = command('schtasks.exe', '/Query', '/TN', NAME, '/XML')
    if existing.returncode:
        return False
    # schtasks writes its display output in the OEM code page. Reading the registered
    # UTF-16 definition preserves Chinese project paths instead of accepting '?'.
    registered = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32' / 'Tasks' / NAME
    try:
        parsed = ET.fromstring(registered.read_bytes())
    except OSError:
        parsed = ET.fromstring(decoded(existing.stdout).strip())
    action = parsed.find(f'.//{{{NS}}}Exec')
    expected = str(ROOT / 'tools' / 'supervisor.py')
    if action is None or expected not in (action.findtext(f'{{{NS}}}Arguments') or ''):
        raise RuntimeError('The task name belongs to another action; it will not be overwritten.')
    return True


def task_xml(destination: Path) -> None:
    sys.path.insert(0, str(ROOT / 'host'))
    from hajisaki.config import _current_windows_sid, secure_data_directory
    secure_data_directory(destination.parent)
    interpreter = ROOT / '.venv' / 'Scripts' / 'pythonw.exe'
    if not interpreter.is_file():
        raise RuntimeError('Create the project .venv first.')
    ET.register_namespace('', NS)
    task = ET.Element(f'{{{NS}}}Task', version='1.2')

    def add(parent, tag: str, text: str | None = None, **attributes):
        element = ET.SubElement(parent, f'{{{NS}}}{tag}', **attributes)
        element.text = text
        return element

    info = add(task, 'RegistrationInfo')
    add(info, 'Description', '哈基祥私人琴房：以当前用户身份静默启动，不保存 Windows 或 Google 密码。')
    triggers = add(task, 'Triggers')
    trigger = add(triggers, 'LogonTrigger')
    add(trigger, 'Enabled', 'true')
    sid = _current_windows_sid()
    add(trigger, 'UserId', sid)
    principals = add(task, 'Principals')
    principal = add(principals, 'Principal', id='Owner')
    add(principal, 'UserId', sid)
    add(principal, 'LogonType', 'InteractiveToken')
    add(principal, 'RunLevel', 'LeastPrivilege')
    settings = add(task, 'Settings')
    for key, value in {'MultipleInstancesPolicy': 'IgnoreNew', 'DisallowStartIfOnBatteries': 'false',
                       'StopIfGoingOnBatteries': 'false', 'AllowHardTerminate': 'false',
                       'StartWhenAvailable': 'true', 'AllowStartOnDemand': 'true', 'Enabled': 'true',
                       'Hidden': 'true', 'ExecutionTimeLimit': 'PT0S'}.items():
        add(settings, key, value)
    actions = add(task, 'Actions', Context='Owner')
    execute = add(actions, 'Exec')
    add(execute, 'Command', str(interpreter))
    add(execute, 'Arguments', subprocess.list2cmdline([str(ROOT / 'tools' / 'supervisor.py'), 'run']))
    add(execute, 'WorkingDirectory', str(ROOT))
    ET.ElementTree(task).write(destination, encoding='utf-16', xml_declaration=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['install', 'status', 'run', 'disable'])
    args = parser.parse_args()
    if os.name != 'nt':
        parser.error('This entry point is for Windows.')
    sys.stdout.reconfigure(encoding='utf-8')
    if args.action == 'install':
        existing = owned_task()
        manifest = ROOT / 'runtime' / 'windows-logon-task.xml'
        task_xml(manifest)
        values = ['schtasks.exe', '/Create', '/TN', NAME, '/XML', str(manifest)]
        if existing:
            values.append('/F')
        result = command(*values)
    elif args.action == 'status':
        if not owned_task():
            print('No HajiSaki logon task is installed for this project.')
            return 1
        registered = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32' / 'Tasks' / NAME
        parsed = ET.fromstring(registered.read_bytes())
        def value(tag: str):
            return parsed.findtext(f'.//{{{NS}}}{tag}')
        print(json.dumps({'task': NAME, 'enabled': value('Enabled'), 'command': value('Command'),
                          'arguments': value('Arguments'), 'logon_type': value('LogonType'),
                          'run_level': value('RunLevel'), 'hidden': value('Hidden')}, ensure_ascii=False, indent=2))
        return 0
    else:
        if not owned_task():
            print('No HajiSaki logon task is installed for this project.')
            return 1
        result = command('schtasks.exe', '/Run', '/TN', NAME) if args.action == 'run' else command('schtasks.exe', '/Change', '/TN', NAME, '/Disable')
    print(decoded(result.stdout).strip())
    if result.stderr:
        print(decoded(result.stderr).strip(), file=sys.stderr)
    if result.returncode:
        print('No permission change was attempted. The independent manual launcher remains available.', file=sys.stderr)
    else:
        print(json.dumps({'task': NAME, 'action': args.action, 'project': str(ROOT)}, ensure_ascii=False))
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
