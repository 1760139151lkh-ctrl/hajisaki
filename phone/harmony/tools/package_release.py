"""Copy an actual unsigned native build into this project's releases directory."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import zipfile


def digest(path: Path) -> str:
    value=hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024*1024),b''):
            value.update(chunk)
    return value.hexdigest()


def main() -> None:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage',required=True,type=Path)
    parser.add_argument('--product',choices=['openharmony','preview'],default='openharmony')
    args=parser.parse_args()
    project=Path(__file__).resolve().parents[1]
    root=project.parent.parent
    stage=args.stage.resolve()
    marker=stage/'.hajisaki-native-build'
    if not marker.is_file() or Path(marker.read_text(encoding='utf-8')).resolve()!=project:
        raise ValueError('Build stage does not identify this native project.')
    native=stage/'harmony'
    artifact=native/f'entry/build/{args.product}/outputs/default/entry-default-unsigned.hap'
    with zipfile.ZipFile(artifact) as archive:
        module=json.loads(archive.read('module.json'))
        if not any(name.endswith('.abc') for name in archive.namelist()):
            raise ValueError('HAP has no compiled Ark bytecode.')
    destination=root/'releases'
    destination.mkdir(exist_ok=True)
    stem=f'hajisaki-{args.product}-api26-unsigned'
    target=destination/(stem+'.hap')
    shutil.copy2(artifact,target)
    sources={}
    for source in native.rglob('*'):
        relative=source.relative_to(native)
        if not source.is_file() or any(part in {'.hvigor','build','oh_modules','node_modules','__pycache__'} for part in relative.parts):
            continue
        sources[relative.as_posix()]=digest(source)
    log=native/'.hvigor/outputs/build-logs/build.log'
    if log.is_file(): shutil.copy2(log,destination/(stem+'.build.log'))
    record={'artifact':target.name,'bytes':target.stat().st_size,'sha256':digest(target),
            'product':args.product,'signing':'unsigned','module':module,
            'workspace_project':project.relative_to(root).as_posix(),
            'source_tree':'exact staged build inputs; OpenHarmony deviceTypes conversion is included',
            'storage':'temporary memory, explicitly labelled preview' if args.product=='preview' else 'encrypted S3 RDB',
            'verification':'actual compiler and packager output; device installation and hardware acceptance remain separate',
            'source_sha256':sources}
    (destination/(stem+'.manifest.json')).write_text(json.dumps(record,ensure_ascii=False,indent=2),encoding='utf-8')
    print(f'{target} ({target.stat().st_size} bytes)')


if __name__=='__main__': main()
