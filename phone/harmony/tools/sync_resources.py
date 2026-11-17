"""Copy approved project assets and the offline renderer into the native module.

This is packaging, not image editing. Originals and native full-resolution files
are preserved. Reads assets_pipeline/native-resources.json, written after visual
approval, rather than guessing whether a generated image is final.
"""
from __future__ import annotations
import json
import filecmp
import pathlib
import shutil
import sys
import argparse
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[3]
NATIVE = ROOT / 'phone' / 'harmony' / 'entry' / 'src' / 'main' / 'resources' / 'base'


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--recycle-obsolete', action='store_true')
    parser.add_argument('--stage', action='append', type=pathlib.Path, default=[],
                        help='Also reconcile a marked HajiSaki ASCII native build stage.')
    args = parser.parse_args()
    manifest = ROOT / 'assets_pipeline' / 'native-resources.json'
    if not manifest.is_file():
        print('Approved native resource manifest is not ready: assets_pipeline/native-resources.json')
        return 2
    entries = json.loads(manifest.read_text(encoding='utf-8'))
    media = NATIVE / 'media'
    media.mkdir(parents=True, exist_ok=True)
    for name, relative in entries.items():
        source = (ROOT / relative).resolve()
        if not source.is_relative_to(ROOT) or not source.is_file():
            raise ValueError(f'Asset is outside this project or missing: {relative}')
        if not name.replace('_', '').isalnum() or source.suffix.lower() not in ('.png', '.webp', '.jpg', '.svg'):
            raise ValueError(f'Invalid native resource mapping: {name}')
        target = media / (name + source.suffix.lower())
        shutil.copy2(source, target)
        print(f'{target.relative_to(ROOT)} ({source.stat().st_size} bytes)')
    icon = ROOT / 'phone' / 'harmony' / 'AppScope' / 'resources' / 'base' / 'media' / 'app_icon.svg'
    shutil.copy2(icon, media / 'app_icon.svg')
    renderer = ROOT / 'studio' / 'dist'
    if not (renderer / 'render-frame.html').is_file():
        print('Offline render-frame.html build is not yet available.')
        return 3
    destination = NATIVE.parent / 'rawfile' / 'renderer'
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(renderer / 'render-frame.html', destination / 'render-frame.html')
    manifest_path=renderer / '.vite/manifest.json'
    chunks=json.loads(manifest_path.read_text(encoding='utf-8'))
    pending=['render-frame.html']
    visited=set()
    required={'render-frame.html'}
    while pending:
        key=pending.pop()
        if key in visited: continue
        visited.add(key)
        entry=chunks[key]
        required.add(entry['file'])
        required.update(entry.get('css',[]))
        required.update(entry.get('assets',[]))
        pending.extend(entry.get('imports',[]))
        pending.extend(entry.get('dynamicImports',[]))
    for relative in sorted(required):
        source=(renderer/relative).resolve()
        target=(destination/relative).resolve()
        if not source.is_relative_to(renderer.resolve()) or not target.is_relative_to(destination.resolve()):
            raise ValueError('Renderer manifest path escaped its root.')
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(source,target)
    (ROOT/'phone/harmony/renderer-assets.json').write_text(json.dumps(sorted(required),indent=2),encoding='utf-8')
    if args.recycle_obsolete:
        from send2trash import send2trash
        recycled=[]
        targets=[(destination,ROOT)]
        project=ROOT/'phone/harmony'
        for argument in args.stage:
            stage=argument.absolute()
            marker=stage/'.hajisaki-native-build'
            if (stage.resolve()!=stage or not marker.is_file()
                    or pathlib.Path(marker.read_text(encoding='utf-8')).resolve()!=project):
                raise ValueError('Cleanup stage does not identify this native project.')
            targets.append((stage/'harmony/entry/src/main/resources/rawfile/renderer',stage))
        for target, boundary in targets:
            for path in sorted((target/'assets').rglob('*')):
                if not path.is_file(): continue
                relative=path.relative_to(target).as_posix()
                if relative in required: continue
                original=renderer/relative
                # Only unchanged copies of known task-built assets are disposable.
                if not original.is_file() or not filecmp.cmp(path,original,shallow=False): continue
                resolved=path.resolve()
                if not resolved.is_relative_to(target.resolve()) or not resolved.is_relative_to(boundary.resolve()):
                    raise ValueError('Cleanup target escaped the named renderer directory.')
                size=resolved.stat().st_size
                send2trash(str(resolved))
                recycled.append({'path':str(resolved),'bytes':size})
                print(f'Recycle Bin: {resolved} ({size/1024:.1f} KB)')
        stamp=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        report=ROOT/('phone/docs/native-renderer-cleanup-'+stamp+'.json')
        report.parent.mkdir(parents=True,exist_ok=True)
        report.write_text(json.dumps({'destination':'Windows Recycle Bin','files':recycled,
          'logical_bytes':sum(item['bytes'] for item in recycled),'freed_space_claimed':False},indent=2),encoding='utf-8')
    print('Offline renderer copied with its bundled asset closure.')
    audio = ROOT / 'shared/assets/audio'
    if audio.is_dir():
        shutil.copytree(audio, NATIVE.parent / 'rawfile/audio', dirs_exist_ok=True)
        print('Original audio cues copied into rawfile/audio.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
