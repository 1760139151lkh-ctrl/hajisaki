"""Install the optional speech dependencies into the project's existing venv."""

from pathlib import Path
import os
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
interpreter = ROOT / ".venv" / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python")
if not interpreter.is_file():
    raise SystemExit("Create the project .venv first; this command never modifies system Python.")
flags = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0
with (ROOT / "speech" / "environment-install.log").open("a", encoding="utf-8") as log:
    result = subprocess.run(
        [str(interpreter), "-m", "pip", "install", "-r", str(ROOT / "speech" / "requirements.txt")],
        cwd=ROOT, shell=False, creationflags=flags, stdout=log, stderr=subprocess.STDOUT,
        env={**os.environ, "PYTHONUTF8": "1"},
    )
print(f"Optional speech dependency installation exit code: {result.returncode}")
raise SystemExit(result.returncode)
