from __future__ import annotations

import json
import csv
import os
import secrets
import shutil
import ipaddress
import subprocess
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit


PROJECT_ROOT = Path(__file__).resolve().parents[2]


def _current_windows_sid() -> str:
    identity = subprocess.run(["whoami.exe", "/user", "/fo", "csv", "/nh"], shell=False,
        creationflags=subprocess.CREATE_NO_WINDOW, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, encoding="utf-8", errors="replace", check=True)
    sid = next(csv.reader(identity.stdout.strip().splitlines()))[-1]
    if not sid.startswith("S-1-5-"):
        raise ValueError("Cannot identify the current account for private pairing storage.")
    return sid


def protect_credentials(path: Path) -> None:
    """Private file ACL; chmod alone does not remove inherited Windows read grants."""
    if os.name != "nt":
        path.chmod(0o600)
        return
    sid = _current_windows_sid()
    subprocess.run(["icacls.exe", str(path), "/inheritance:r", "/grant:r", f"*{sid}:F",
                    "*S-1-5-18:F", "*S-1-5-32-544:F"], shell=False,
        creationflags=subprocess.CREATE_NO_WINDOW, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)


def secure_data_directory(path: Path) -> Path:
    """Restrict a dedicated HajiSaki data directory, never a user/profile/project root."""
    path = Path(path).expanduser().resolve()
    user_root = Path.home().resolve()
    forbidden = {Path(path.anchor), user_root, PROJECT_ROOT,
                 user_root / "Desktop", user_root / "Documents", user_root / "Downloads",
                 user_root / "AppData", user_root / "AppData/Local"}
    if path in forbidden:
        raise ValueError("Choose a dedicated HajiSaki data directory, not a shared parent folder.")
    path.mkdir(parents=True, exist_ok=True)
    if os.name != "nt":
        path.chmod(0o700)
        return path
    sid = _current_windows_sid()
    subprocess.run(["icacls.exe", str(path), "/inheritance:r", "/grant:r", f"*{sid}:(OI)(CI)F",
                    "*S-1-5-18:(OI)(CI)F", "*S-1-5-32-544:(OI)(CI)F"], shell=False,
        creationflags=subprocess.CREATE_NO_WINDOW, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    return path


@dataclass(frozen=True)
class Config:
    data_dir: Path
    provider: str
    agy_path: str | None
    token: str
    device: str
    proxy_url: str | None = None
    max_upload: int = 16 * 1024**3
    chunk_size: int = 8 * 1024**2
    max_parallel: int = 3
    port: int = 8765
    turbo: bool = False

    @classmethod
    def load(cls) -> "Config":
        default = Path(os.environ.get("LOCALAPPDATA", Path.home() / ".local/share")) / "HajiSaki"
        data = Path(os.environ.get("HAJI_DATA_DIR", str(default))).expanduser().resolve()
        secure_data_directory(data)
        credentials = data / "pairing.json"
        if not credentials.exists():
            payload = {"token": secrets.token_urlsafe(48), "device": "owner-device"}
            try:
                with credentials.open("x", encoding="utf-8") as file:
                    json.dump(payload, file, indent=2)
            except FileExistsError:
                pass
        protect_credentials(credentials)
        pairing = json.loads(credentials.read_text(encoding="utf-8"))
        token = str(pairing.get("token", ""))
        device = str(pairing.get("device", ""))
        if len(token) < 32 or not device:
            raise ValueError("Pairing configuration requires a strong token and a device identifier.")
        candidate = Path.home() / "AppData/Local/agy/bin/agy.exe"
        agy = os.environ.get("HAJI_AGY_PATH") or shutil.which("agy")
        if not agy and candidate.is_file():
            agy = str(candidate)
        provider = os.environ.get("HAJI_PROVIDER", "acp")
        if provider not in {"agy", "acp", "development"}:
            raise ValueError("HAJI_PROVIDER must be agy, acp or development.")
        if provider == 'agy':
            provider = 'acp'  # Legacy spelling, same intact Antigravity harness.
        proxy = os.environ.get("HAJI_PROXY_URL") or None
        if proxy:
            parts = urlsplit(proxy)
            local = parts.hostname == "localhost"
            try:
                local = local or ipaddress.ip_address(parts.hostname or "").is_loopback
            except ValueError:
                pass
            if parts.scheme not in {"http", "https"} or not local or not parts.port:
                raise ValueError("HAJI_PROXY_URL must be a loopback HTTP(S) proxy with an explicit port.")
        port = int(os.environ.get("HAJI_PORT", "8765"))
        if not 1024 <= port <= 65535:
            raise ValueError("HAJI_PORT must be between 1024 and 65535.")
        settings_file = data / 'host-settings.json'
        host_settings = json.loads(settings_file.read_text(encoding='utf-8')) if settings_file.is_file() else {}
        turbo = host_settings.get('turbo') is True
        return cls(data, provider, agy, token, device, proxy, port=port, turbo=turbo)

