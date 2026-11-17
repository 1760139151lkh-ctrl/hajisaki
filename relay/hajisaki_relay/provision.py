from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import ipaddress
import json
import os
import secrets
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

from .phone import write_private


def protect_directory(path: Path):
    if os.name != "nt":
        path.chmod(0o700)
        return
    # Establish owner + SYSTEM ACL before generating any secret material.
    result = subprocess.run(["whoami", "/user", "/fo", "csv", "/nh"], shell=False,
                            capture_output=True, text=True, check=True,
                            creationflags=subprocess.CREATE_NO_WINDOW)
    sid = next(csv.reader(result.stdout.strip().splitlines()))[1]
    if not sid.startswith("S-1-"):
        raise ValueError("Unable to resolve current user SID")
    subprocess.run(["icacls", str(path), "/inheritance:r", "/grant:r", f"*{sid}:(OI)(CI)F",
                    "/grant:r", "*S-1-5-18:(OI)(CI)F"], shell=False, capture_output=True,
                   check=True, creationflags=subprocess.CREATE_NO_WINDOW)


def private_key(key) -> bytes:
    return key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                             serialization.NoEncryption())


def certificate(subject: str, key, issuer, issuer_key, ca: bool = False,
                server_name: str | None = None, days: int = 90):
    current = datetime.now(timezone.utc)
    builder = (x509.CertificateBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, subject)]))
               .issuer_name(issuer).public_key(key.public_key()).serial_number(x509.random_serial_number())
               .not_valid_before(current - timedelta(minutes=5)).not_valid_after(current + timedelta(days=days))
               .add_extension(x509.BasicConstraints(ca=ca, path_length=0 if ca else None), critical=True)
               .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False,
                                            key_encipherment=False, data_encipherment=False,
                                            key_agreement=False, key_cert_sign=ca, crl_sign=ca,
                                            encipher_only=False, decipher_only=False), critical=True)
               .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False))
    if not ca:
        builder = builder.add_extension(x509.ExtendedKeyUsage([
            ExtendedKeyUsageOID.SERVER_AUTH if server_name else ExtendedKeyUsageOID.CLIENT_AUTH]), critical=False)
        builder = builder.add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(issuer_key.public_key()), critical=False)
        if server_name:
            try:
                name = x509.IPAddress(ipaddress.ip_address(server_name))
            except ValueError:
                name = x509.DNSName(server_name)
            builder = builder.add_extension(x509.SubjectAlternativeName([name]), critical=False)
    return builder.sign(issuer_key, hashes.SHA256())


def provision(args):
    root = Path(args.directory).expanduser().resolve()
    if not args.relay_name or any(char in args.relay_name for char in "/?#@ "):
        raise ValueError("Supply a relay DNS hostname or IP, without scheme or path")
    if not 1 <= args.port <= 65535:
        raise ValueError("Invalid relay port")
    if args.http_port is not None and (not 1 <= args.http_port <= 65535 or args.http_port == args.port):
        raise ValueError("HTTP ingress needs a distinct valid port")
    if args.development:
        try:
            if not ipaddress.ip_address(args.relay_name).is_loopback:
                raise ValueError("Development requires loopback IP")
        except ValueError as exc:
            raise ValueError("Development requires loopback IP") from exc
    pairing = None
    if args.pairing_file:
        pairing = json.loads(Path(args.pairing_file).read_text(encoding="utf-8"))
        if not isinstance(pairing.get("token"), str) or len(pairing["token"]) < 32 or not pairing.get("device"):
            raise ValueError("Invalid gateway pairing file")
        pairing = {key: pairing[key] for key in ("token", "device")}
    root.mkdir(parents=True, exist_ok=False)  # Never overwrite a live deployment or its keys.
    protect_directory(root)
    for role in ("relay", "host", "phone", "authority"):
        (root / role).mkdir()
    channel = secrets.token_urlsafe(24)
    tokens = {role: secrets.token_urlsafe(32) for role in ("host", "phone")}
    master = base64.b64encode(os.urandom(32)).decode("ascii")
    mode = "development" if args.development else "production"
    host_name = f"[{args.relay_name}]" if ":" in args.relay_name else args.relay_name
    origin = f"{'ws' if args.development else 'wss'}://{host_name}:{args.port}"
    configurations = {
        "relay": {"role": "relay", "mode": mode, "channel": channel,
                  **{role + "_token_sha256": hashlib.sha256(token.encode()).hexdigest() for role, token in tokens.items()}},
        "host": {"role": "host", "mode": mode, "channel": channel, "channel_token": tokens["host"],
                 "master_key": master, "relay_url": origin, "gateway_url": args.gateway,
                 "journal": "requests.sqlite3"},
        "phone": {"role": "phone", "mode": mode, "channel": channel, "channel_token": tokens["phone"],
                  "master_key": master, "relay_url": origin, "state_dir": "state",
                  "gateway_pairing": pairing or {}},
    }
    if args.http_port is not None:
        configurations["relay"]["http_port"] = args.http_port
        configurations["phone"]["https_url"] = f"{'http' if args.development else 'https'}://{host_name}:{args.http_port}"
    if not args.development:
        ca_key = ec.generate_private_key(ec.SECP256R1())
        ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "HajiSaki private relay CA")])
        ca = certificate("HajiSaki private relay CA", ca_key, ca_name, ca_key, ca=True, days=3650)
        ca_bytes = ca.public_bytes(serialization.Encoding.PEM)
        write_private(root / "authority" / "ca-key.pem", private_key(ca_key))
        write_private(root / "authority" / "ca.pem", ca_bytes)
        for role in ("relay", "host", "phone"):
            key = ec.generate_private_key(ec.SECP256R1())
            cert = certificate("HajiSaki " + role, key, ca.subject, ca_key,
                               server_name=args.relay_name if role == "relay" else None)
            if role == "relay":
                spki = cert.public_key().public_bytes(serialization.Encoding.DER,
                                                     serialization.PublicFormat.SubjectPublicKeyInfo)
                configurations["phone"]["server_public_key_sha256"] = base64.b64encode(hashlib.sha256(spki).digest()).decode("ascii")
            write_private(root / role / "ca.pem", ca_bytes)
            write_private(root / role / "key.pem", private_key(key))
            write_private(root / role / "cert.pem", cert.public_bytes(serialization.Encoding.PEM))
            configurations[role].update({"ca": "ca.pem", "certificate": "cert.pem", "private_key": "key.pem"})
    for role, config in configurations.items():
        write_private(root / role / "config.json", (json.dumps(config, indent=2) + "\n").encode("utf-8"))
    print(json.dumps({"directory": str(root), "mode": mode,
                      "roles": ["relay", "host", "phone"], "gateway_pairing_included": pairing is not None}, ensure_ascii=True))


def main():
    parser = argparse.ArgumentParser(description="Provision independent private relay credentials without displaying secrets")
    parser.add_argument("--directory", required=True)
    parser.add_argument("--relay-name", required=True)
    parser.add_argument("--port", type=int, default=9443)
    parser.add_argument("--http-port", type=int, help="Optional opaque HTTPS phone ingress; distinct from host WSS port")
    parser.add_argument("--gateway", default="http://127.0.0.1:8765")
    parser.add_argument("--pairing-file")
    parser.add_argument("--development", action="store_true")
    args = parser.parse_args()
    try:
        provision(args)
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        parser.exit(1, type(exc).__name__ + ": provisioning did not complete; existing files were not replaced.\n")


if __name__ == "__main__":
    main()
