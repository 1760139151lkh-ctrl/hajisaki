"""Run encrypted backups, verification and non-overwriting restores.

Examples from project root:
  .venv/Scripts/python.exe host/tools/maintenance.py install-dependencies
  .venv/Scripts/python.exe host/tools/maintenance.py --data-dir runtime backup
  .venv/Scripts/python.exe host/tools/maintenance.py --data-dir runtime list
  .venv/Scripts/python.exe host/tools/maintenance.py --data-dir runtime verify ID
  .venv/Scripts/python.exe host/tools/maintenance.py --data-dir runtime restore ID NEW_DIRECTORY

Daily defaults: 03:00 America/Los_Angeles, enabled per the product charter.
Override repository/key_file/timezone/hour/minute/enabled in the selected
instance's maintenance-settings.json. The private key is never printed or
included in a snapshot. Same-volume backups do not protect against disk loss.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "host"))
from hajisaki.maintenance import BackupSettings, EncryptedBackup, QuietMaintenance


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data-dir", type=Path, default=Path(os.environ.get("HAJI_DATA_DIR", PROJECT_ROOT / "runtime")))
    subcommands = parser.add_subparsers(dest="command", required=True)
    subcommands.add_parser("install-dependencies")
    subcommands.add_parser("status")
    subcommands.add_parser("backup")
    subcommands.add_parser("list")
    verify = subcommands.add_parser("verify")
    verify.add_argument("backup_id")
    restore = subcommands.add_parser("restore")
    restore.add_argument("backup_id")
    restore.add_argument("destination", type=Path)
    args = parser.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")
    if args.command == "install-dependencies":
        expected = PROJECT_ROOT / ".venv"
        if not Path(sys.executable).resolve().is_relative_to(expected.resolve()):
            raise SystemExit("Use the project .venv interpreter for this optional dependency installation.")
        result = subprocess.run([sys.executable, "-m", "pip", "install", "cryptography>=46,<52"],
                                shell=False, creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
                                env={**os.environ, "PYTHONUTF8": "1"})
        return result.returncode
    settings = BackupSettings.load(args.data_dir)
    backup = EncryptedBackup(settings, PROJECT_ROOT)
    if args.command == "status":
        result = QuietMaintenance(args.data_dir, PROJECT_ROOT).status()
    elif args.command == "list":
        result = {"snapshots": [json.loads(path.read_text(encoding="utf-8")) for path in sorted((settings.repository / "snapshots").glob("*.json"))]}
    elif args.command == "backup":
        result = backup.backup()
    elif args.command == "verify":
        result = backup.verify(args.backup_id)
    else:
        result = backup.restore(args.backup_id, args.destination)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
