"""Export a bounded, self-contained native relay profile without printing secrets."""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import secrets

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.x509.oid import ExtendedKeyUsageOID

from .config import https_origin, load, local_path
from .phone import write_private
from .protocol import Cipher
from .provision import protect_directory


MAX_BUNDLE_BYTES = 32768


def export_profile(config: dict, directory: Path, pairing: dict) -> Path:
    if config["mode"] != "production":
        raise ValueError("Native profiles require production TLS credentials")
    origin = https_origin(config)
    if not re.fullmatch(r"[A-Za-z0-9_-]{40,128}", config["channel_token"]):
        raise ValueError("Invalid phone channel token")
    # Validate the existing protocol key using the production codec itself.
    Cipher(config["channel"], config["master_key"])
    token, device = pairing.get("token"), pairing.get("device")
    if (not isinstance(token, str) or not re.fullmatch(r"[\x21-\x7e]{32,128}", token)
            or not isinstance(device, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", device)):
        raise ValueError("A current device pairing file is required for profile authentication")
    pin = config.get("server_public_key_sha256", "")
    decoded_pin = base64.b64decode(pin, validate=True)
    if len(decoded_pin) != 32 or base64.b64encode(decoded_pin).decode("ascii") != pin:
        raise ValueError("Provisioned server public-key pin is missing")
    ca_bytes = local_path(config, "ca").read_bytes()
    cert_bytes = local_path(config, "certificate").read_bytes()
    ca = x509.load_pem_x509_certificate(ca_bytes)
    cert = x509.load_pem_x509_certificate(cert_bytes)
    cert.verify_directly_issued_by(ca)
    if not ca.extensions.get_extension_for_class(x509.BasicConstraints).value.ca:
        raise ValueError("Issuer must be a CA")
    if ExtendedKeyUsageOID.CLIENT_AUTH not in cert.extensions.get_extension_for_class(x509.ExtendedKeyUsage).value:
        raise ValueError("Phone certificate must permit client authentication")
    now = datetime.now(timezone.utc)
    if not (ca.not_valid_before_utc <= now < ca.not_valid_after_utc
            and cert.not_valid_before_utc <= now < cert.not_valid_after_utc):
        raise ValueError("Certificates must be currently valid")
    source_password = config.get("private_key_password")
    key = serialization.load_pem_private_key(local_path(config, "private_key").read_bytes(),
                                            password=source_password.encode("utf-8") if source_password else None)
    public_format = (serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    if key.public_key().public_bytes(*public_format) != cert.public_key().public_bytes(*public_format):
        raise ValueError("Phone certificate and private key do not match")
    password = secrets.token_urlsafe(32)
    encrypted = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                  serialization.BestAvailableEncryption(password.encode("ascii")))
    credentials = {"channelToken": config["channel_token"], "masterKeyBase64": config["master_key"],
                   "serverPublicKeySha256": pin, "keyPassword": password}
    files = {"caPem": ca_bytes.decode("ascii"), "certificatePem": cert_bytes.decode("ascii"),
             "encryptedPrivateKeyPem": encrypted.decode("ascii")}
    profile = {"kind": "hajisaki-relay", "version": 1, "device": device,
               "relay": {"origin": origin, "channel": config["channel"], "development": False},
               "credentials": credentials, "files": files}
    canonical = json.dumps(profile, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode("utf-8")
    profile["authentication"] = base64.b64encode(hmac.new(token.encode("ascii"),
        b"HajiSaki/native-relay/v1\0" + canonical, hashlib.sha256).digest()).decode("ascii")
    encoded = (json.dumps(profile, ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    if len(encoded) > MAX_BUNDLE_BYTES:
        raise ValueError("Native profile exceeds 32 KiB")
    directory = directory.expanduser().absolute()
    directory.mkdir(parents=True, exist_ok=False)
    protect_directory(directory)
    destination = directory / "hajisaki-relay.hsr.json"
    write_private(destination, encoded)
    return destination


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--pairing-file", required=True, help="Current companion device credential; never included in the output")
    args = parser.parse_args()
    try:
        config = load(args.config, "phone", False)
        pairing = json.loads(Path(args.pairing_file).read_text(encoding="utf-8"))
        destination = export_profile(config, args.directory, pairing)
        print(json.dumps({"file": str(destination), "bytes": destination.stat().st_size,
                          "mode": config["mode"], "device_bound": True, "gateway_token_included": False}, ensure_ascii=True))
    except (OSError, ValueError, TypeError, InvalidSignature, x509.ExtensionNotFound) as exc:
        parser.exit(1, type(exc).__name__ + ": native profile export did not complete; existing files were not replaced.\n")


if __name__ == "__main__":
    main()
