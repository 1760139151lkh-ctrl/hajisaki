"""Run project commands without opening console windows on Windows.

Usage: python tools/run.py [--cwd PATH] [--timeout SECONDS] -- command args...
For background operation use the project's dedicated supervisor instead.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cwd', type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument('--timeout', type=float, default=120)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command and command[0] == '--':
        command = command[1:]
    if not command:
        parser.error('a command is required')
    executable = shutil.which(command[0]) or command[0]
    if pathlib.Path(executable).suffix.lower() in ('.cmd', '.bat'):
        if pathlib.Path(executable).name.lower() in ('npm.cmd', 'npx.cmd'):
            name = 'npm-cli.js' if pathlib.Path(executable).name.lower() == 'npm.cmd' else 'npx-cli.js'
            cli = pathlib.Path(executable).parent / 'node_modules' / 'npm' / 'bin' / name
            command = [shutil.which('node') or 'node', str(cli), *command[1:]]
        else:
            parser.error('invoke the underlying executable instead of a batch wrapper')
    else:
        command[0] = executable
    try:
        result = subprocess.run(
            command, cwd=args.cwd.resolve(), shell=False,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0,
            timeout=args.timeout or None, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        sys.stdout.buffer.write(result.stdout)
        sys.stderr.buffer.write(result.stderr)
        return result.returncode
    except subprocess.TimeoutExpired:
        print(f'Command exceeded {args.timeout:g} seconds.', file=sys.stderr)
        return 124
    except OSError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
