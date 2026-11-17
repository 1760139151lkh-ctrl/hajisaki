"""Build with a supplied DevEco toolchain or the project-local official tools.

Default is the vendor HarmonyOS 26 product. --product openharmony and
--product legacyDiagnostic are explicitly separate portability diagnostics.
They must not be reported as Huawei native target/device acceptance.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from datetime import datetime, timezone


def sync_renderer_mirror(project: Path, launch_project: Path, stage: Path, record: Path) -> None:
    """Hashed renderer bundles are a mirror, not an accumulating build archive."""
    relative = Path('entry/src/main/resources/rawfile/renderer')
    source, target = project / relative, launch_project / relative
    if not source.is_dir() or not target.is_dir():
        return
    expected = {path.relative_to(source) for path in source.rglob('*') if path.is_file()}
    obsolete = [path for path in target.rglob('*') if path.is_file() and path.relative_to(target) not in expected]
    entries = []
    for path in obsolete:
        resolved = path.resolve()
        if path.is_symlink() or not resolved.is_relative_to(stage) or not resolved.is_relative_to(target.resolve()):
            raise ValueError('A stale renderer path escaped the marked build stage.')
        entries.append({'path':str(resolved), 'bytes':resolved.stat().st_size})
    if not entries:
        return
    # The project already declares Send2Trash in its host environment. Never
    # replace this with unlink/rmtree, including for compiled mirror files.
    from send2trash import send2trash
    record.parent.mkdir(parents=True, exist_ok=True)
    previous = json.loads(record.read_text(encoding='utf-8')) if record.is_file() else []
    batch = {'stage':str(stage), 'time':datetime.now(timezone.utc).isoformat(), 'files':entries, 'completed':False}
    previous.append(batch)
    record.write_text(json.dumps(previous, ensure_ascii=False, indent=2), encoding='utf-8')
    send2trash([entry['path'] for entry in entries])
    batch['completed'] = True
    record.write_text(json.dumps(previous, ensure_ascii=False, indent=2), encoding='utf-8')
    print(f'Recycled {len(entries)} obsolete staged renderer files ({sum(entry["bytes"] for entry in entries)} bytes); record: {record}', flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--product', choices=['default', 'openharmony', 'preview', 'legacyDiagnostic'], default='default')
    parser.add_argument('--hvigor', type=Path)
    parser.add_argument('--sdk', type=Path)
    parser.add_argument('--java', type=Path)
    parser.add_argument('--task', default='assembleHap')
    parser.add_argument('--build-dir', type=Path,
                        help='ASCII staging directory when Hvigor rejects the source path. Source remains unchanged.')
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    root = project.parent.parent
    launch_project = project
    if args.build_dir:
        stage = args.build_dir.absolute()
        if not str(stage).isascii() or stage.resolve() != stage:
            raise ValueError('Build directory must have an ASCII, non-symlink path.')
        marker = stage / '.hajisaki-native-build'
        if stage.exists() and not marker.is_file():
            raise ValueError('Build directory exists without the project marker; refusing to overwrite.')
        if marker.is_file() and Path(marker.read_text(encoding='utf-8')).resolve() != project:
            raise ValueError('Build directory marker belongs to a different project.')
        stage.mkdir(parents=True, exist_ok=True)
        marker.write_text(str(project), encoding='utf-8')
        launch_project = stage / 'harmony'
        shutil.copytree(project, launch_project, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns('.hvigor', 'build', 'oh_modules', 'node_modules', '__pycache__'))
        sync_renderer_mirror(project,launch_project,stage,root/'runtime'/f'native-stage-recycle-{args.product}.json')
        if args.product != 'default':
            module_path = launch_project / 'entry/src/main/module.json5'
            module = json.loads(module_path.read_text(encoding='utf-8'))
            module['module']['deviceTypes'] = ['default']
            module_path.write_text(json.dumps(module, ensure_ascii=False, indent=2), encoding='utf-8')
            print('OpenHarmony diagnostic device type: default (Huawei phone manifest unchanged).')
        if args.product == 'preview':
            app_path = launch_project / 'AppScope/app.json5'
            app = json.loads(app_path.read_text(encoding='utf-8'))
            app['app']['bundleName'] = 'com.hajisaki.companion.preview'
            app_path.write_text(json.dumps(app, ensure_ascii=False, indent=2), encoding='utf-8')
            print('Explicit preview product: temporary memory storage; production product unchanged.')
        icon_dir = launch_project / 'entry/src/main/resources/base/media'
        icon_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(launch_project / 'AppScope/resources/base/media/app_icon.svg', icon_dir / 'app_icon.svg')
    hvigor = args.hvigor or root / 'tooling/command-line-tools/hvigor/bin/hvigorw.js'
    if not hvigor.is_file():
        print('Supply --hvigor with DevEco Studio hvigor/bin/hvigorw.js.', file=sys.stderr)
        return 2
    env = os.environ.copy()
    if args.java:
        env['JAVA_HOME'] = str(args.java.resolve())
    elif not env.get('JAVA_HOME'):
        choices = sorted(Path('C:/Program Files/Microsoft').glob('jdk-21*')) if os.name == 'nt' else []
        if choices:
            env['JAVA_HOME'] = str(choices[-1])
    if args.sdk:
        env['DEVECO_SDK_HOME' if args.product == 'default' else 'OHOS_BASE_SDK_HOME'] = str(args.sdk.absolute())
    elif args.product != 'default':
        env['OHOS_BASE_SDK_HOME'] = str(root / 'tooling/openharmony-sdk')
    command = [shutil.which('node') or 'node', str(hvigor.resolve()), args.task,
               '--mode', 'module', '-p', 'module=entry@default', '-p', f'product={args.product}',
               '-p', 'buildMode=debug', '--no-daemon']
    result = subprocess.run(command, cwd=launch_project, env=env, shell=False,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    sys.stdout.buffer.write(result.stdout)
    print(f'Native build exit: {result.returncode}; project: {launch_project}', flush=True)
    log = launch_project / '.hvigor/outputs/build-logs/build.log'
    if result.returncode and log.is_file():
        print('\n'.join(log.read_text(encoding='utf-8', errors='replace').splitlines()[-65:]))
    return result.returncode


if __name__ == '__main__':
    sys.exit(main())
