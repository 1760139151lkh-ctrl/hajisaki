"""Read installed native SDK CLI capabilities and attached-device status."""
from __future__ import annotations

import argparse
from pathlib import Path
import subprocess


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hdc', type=Path, required=True)
    parser.add_argument('--previewer', type=Path, required=True)
    args = parser.parse_args()
    for executable, arguments in ((args.hdc, ['list', 'targets']), (args.previewer, ['-h'])):
        # Keep an explicitly selected ASCII SDK alias: HDC inspects its launch
        # path and can warn when a junction is resolved back to a Unicode path.
        executable = executable.absolute()
        if not executable.is_file():
            raise FileNotFoundError(executable)
        print(f'{executable.name}: {" ".join(arguments)}', flush=True)
        result = subprocess.run([str(executable), *arguments], cwd=executable.parent,
                                shell=False, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=20, creationflags=subprocess.CREATE_NO_WINDOW)
        print(result.stdout.decode('utf-8', errors='replace'), end='', flush=True)
        print(f'Exit: {result.returncode}', flush=True)


if __name__ == '__main__':
    main()
