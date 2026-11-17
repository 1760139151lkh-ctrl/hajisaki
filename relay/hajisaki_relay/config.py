from __future__ import annotations

import ipaddress
import json
import ssl
from pathlib import Path
from urllib.parse import urlsplit

from .protocol import CHANNEL_RE


def load(path: str, role: str, development: bool) -> dict:
    source = Path(path).expanduser().resolve()
    config = json.loads(source.read_text(encoding="utf-8"))
    if config.get("role") != role or not CHANNEL_RE.fullmatch(config.get("channel", "")):
        raise ValueError("Wrong configuration role or channel")
    if config.get("mode") not in {"production", "development"}:
        raise ValueError("Configuration must declare production or development")
    if development != (config["mode"] == "development"):
        raise ValueError("Development configuration requires explicit --development; production cannot be downgraded")
    config["_directory"] = source.parent
    if role != "relay":
        parts = urlsplit(config.get("relay_url", ""))
        if (parts.scheme != ("ws" if development else "wss") or not parts.hostname or not parts.port
                or parts.username or parts.password or parts.path not in {"", "/"} or parts.query or parts.fragment):
            raise ValueError("relay_url must be a bare ws/wss origin with explicit port")
        if development and not loopback(parts.hostname):
            raise ValueError("Unencrypted development transport must stay on loopback")
        if not isinstance(config.get("channel_token"), str) or len(config["channel_token"]) < 40:
            raise ValueError("A strong role token is required")
        if role == "phone" and config.get("https_url"):
            https_origin(config)
    return config


def loopback(host: str) -> bool:
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def local_path(config: dict, key: str, default: str | None = None) -> Path:
    path = Path(config.get(key, default) or "")
    return (path if path.is_absolute() else config["_directory"] / path).resolve()


def tls_context(config: dict, server: bool = False) -> ssl.SSLContext | None:
    if config["mode"] == "development":
        return None
    for key in ("ca", "certificate", "private_key"):
        if not config.get(key) or not local_path(config, key).is_file():
            raise ValueError("Production needs CA, certificate and private key files")
    context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH if server else ssl.Purpose.SERVER_AUTH,
                                         cafile=str(local_path(config, "ca")))
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.maximum_version = ssl.TLSVersion.TLSv1_3
    context.verify_mode = ssl.CERT_REQUIRED
    if not server:
        context.check_hostname = True
    context.load_cert_chain(str(local_path(config, "certificate")), str(local_path(config, "private_key")))
    return context


def gateway_origin(config: dict) -> str:
    value = config.get("gateway_url", "http://127.0.0.1:8765")
    parts = urlsplit(value)
    if (parts.scheme != "http" or not parts.hostname or not loopback(parts.hostname) or not parts.port
            or parts.username or parts.password or parts.path not in {"", "/"} or parts.query or parts.fragment):
        raise ValueError("Gateway must be a fixed HTTP loopback IP origin with explicit port")
    return value.rstrip("/")


def websocket_url(config: dict) -> str:
    role = "phone" if config["role"] == "phone" else "host"
    return config["relay_url"].rstrip("/") + f"/v1/channels/{config['channel']}/{role}"


def https_origin(config: dict) -> str:
    value = config.get("https_url", "")
    parts = urlsplit(value)
    if (parts.scheme != ("http" if config["mode"] == "development" else "https")
            or not parts.hostname or not parts.port or parts.username or parts.password
            or parts.path not in {"", "/"} or parts.query or parts.fragment):
        raise ValueError("https_url must be a bare HTTP(S) origin with explicit port")
    if config["mode"] == "development" and not loopback(parts.hostname):
        raise ValueError("Development HTTP ingress must stay on loopback")
    return value.rstrip("/")


def allowed_origins(config: dict) -> list[str | None]:
    configured = config.get("allowed_origins", [])
    if not isinstance(configured, list) or len(configured) > 8:
        raise ValueError("allowed_origins must contain at most eight exact origins")
    result: list[str | None] = [None]
    for origin in configured:
        if (not isinstance(origin, str) or not origin.isascii() or len(origin) > 512 or "*" in origin
                or any(ord(char) < 33 or ord(char) == 127 for char in origin)):
            raise ValueError("Invalid allowed origin")
        parts = urlsplit(origin)
        if (parts.scheme != ("http" if config["mode"] == "development" else "https")
                or not parts.hostname or parts.username or parts.password or parts.path or parts.query or parts.fragment
                or (parts.port is not None and not 1 <= parts.port <= 65535)):
            raise ValueError("Allowed origins must be exact HTTP(S) origins without a path")
        if config["mode"] == "development" and not loopback(parts.hostname):
            raise ValueError("Development origins must use a loopback IP")
        if origin not in result:
            result.append(origin)
    return result
