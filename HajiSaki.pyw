"""Double-click to start the private gateway without opening a terminal."""
from pathlib import Path
import os
import subprocess
import sys

root = Path(__file__).resolve().parent
interpreter = root / '.venv' / 'Scripts' / 'pythonw.exe'
if not interpreter.exists():
    interpreter = Path(sys.executable)
(root / 'runtime').mkdir(exist_ok=True)
with (root / 'runtime' / 'launcher.log').open('ab') as output:
    subprocess.Popen([str(interpreter), str(root / 'tools' / 'supervisor.py'), 'start'],
                     cwd=root, shell=False, creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0,
                     stdout=output, stderr=output, stdin=subprocess.DEVNULL)
