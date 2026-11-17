"""Refresh the local gateway catalog from the installed subscription CLI."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-dir', type=Path, default=Path(os.environ.get('HAJI_DATA_DIR', ROOT / 'runtime')))
    parser.add_argument('--agy', default=os.environ.get('HAJI_AGY_PATH') or shutil.which('agy') or str(Path.home() / 'AppData/Local/agy/bin/agy.exe'))
    args = parser.parse_args()
    result = subprocess.run([args.agy, 'models'], shell=False, capture_output=True,
                            creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0, timeout=60)
    if result.returncode:
        print('The CLI did not return its model catalog. Existing catalog retained.')
        return result.returncode
    catalog = []
    for line in result.stdout.decode('utf-8', errors='replace').splitlines():
        if '\t' not in line:
            continue
        ident, name = line.split('\t', 1)
        effort = ident.rsplit('-', 1)[-1]
        efforts = [effort] if effort in {'low', 'medium', 'high', 'xhigh', 'max'} else ['medium']
        catalog.append({'id': ident.strip(), 'name': name.strip(), 'efforts': efforts})
    if not catalog:
        print('No recognized model entries returned. Existing catalog retained.')
        return 1
    args.data_dir.mkdir(parents=True, exist_ok=True)
    (args.data_dir / 'models.json').write_text(json.dumps(catalog, ensure_ascii=False, indent=2), encoding='utf-8')
    print(f'Updated {len(catalog)} discovered model entries. This does not prove generation availability.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
