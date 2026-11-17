"""Unpack the verified public Windows SDK components without global installation."""
from __future__ import annotations

import hashlib
import argparse
import json
import pathlib
import shutil
import tarfile
import zipfile


def main() -> None:
    root = pathlib.Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=pathlib.Path, default=root / 'downloads' / 'ohos-sdk-windows_linux-public_20260829.tar.gz')
    parser.add_argument('--checksum-file', type=pathlib.Path)
    args = parser.parse_args()
    archive = args.archive.resolve()
    if args.checksum_file:
        expected = args.checksum_file.read_text(encoding='utf-8').split()[0].lower()
    else:
        manifest = json.loads(archive.with_name(archive.name + '.json').read_text(encoding='utf-8'))
        expected = manifest['sha256']
    with archive.open('rb') as source:
        if hashlib.file_digest(source, 'sha256').hexdigest() != expected:
            raise RuntimeError('SDK archive differs from verified download')
    components = root / 'downloads' / 'windows-components'
    components.mkdir(exist_ok=True)
    destination = root / 'openharmony-sdk'
    with tarfile.open(archive, 'r:gz') as bundle:
        for item in bundle:
            name = pathlib.PurePosixPath(item.name)
            if 'windows' not in name.parts or not name.name.endswith('.zip'):
                continue
            if name.name.split('-')[0] not in {'ets', 'js', 'native', 'toolchains', 'previewer'}:
                continue
            package_path = components / name.name
            source = bundle.extractfile(item)
            if source is None:
                raise RuntimeError(f'Missing component data: {name}')
            with source, package_path.open('wb') as target:
                shutil.copyfileobj(source, target)
            with zipfile.ZipFile(package_path) as package:
                manifests = [entry for entry in package.namelist() if entry.endswith('oh-uni-package.json')]
                if len(manifests) != 1:
                    raise RuntimeError(f'Unexpected component metadata: {name}')
                component_info = json.loads(package.read(manifests[0]))
                api = str(component_info['apiVersion'])
                if not api.isdigit():
                    raise RuntimeError('Invalid SDK API directory')
                directory_version = str(component_info.get('platformVersion', api)) if int(api) >= 26 else api
                if any(not part.isdigit() for part in directory_version.split('.')):
                    raise RuntimeError('Invalid SDK platform directory')
                api_root = (destination / directory_version).resolve()
                for entry in package.namelist():
                    if not (api_root / entry).resolve().is_relative_to(api_root):
                        raise RuntimeError(f'Archive member escapes SDK directory: {entry}')
                api_root.mkdir(parents=True, exist_ok=True)
                package.extractall(api_root)
            print(json.dumps({'component': component_info, 'path': str(api_root)}, ensure_ascii=False), flush=True)
    print('Public SDK components extracted; no HarmonyOS vendor SDK was substituted.', flush=True)


if __name__ == '__main__':
    main()
