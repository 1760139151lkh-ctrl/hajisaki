from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import struct
import time
import uuid
from dataclasses import dataclass

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

MAGIC = b"HSR1"
MAX_BODY = 4 * 1024 * 1024
MAX_META = 16 * 1024
MAX_HEADER = 1024
MAX_FRAME = 6 + MAX_HEADER + 4 + MAX_META + MAX_BODY + 16
MAX_INFLIGHT = 8
LIFETIME_MS = 120_000
CLOCK_SKEW_MS = 30_000
ID_RE = re.compile(r"[0-9a-f]{32}")
CHANNEL_RE = re.compile(r"[A-Za-z0-9_-]{20,64}")


class ProtocolError(ValueError):
    pass


def now_ms() -> int:
    return time.time_ns() // 1_000_000


def encode_json(value: dict) -> bytes:
    return json.dumps(value, separators=(",", ":"), sort_keys=True,
                      ensure_ascii=True, allow_nan=False).encode("ascii")


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ProtocolError("Duplicate JSON key")
        result[key] = value
    return result


def decode_json(data: bytes) -> dict:
    try:
        value = json.loads(data, object_pairs_hook=_unique,
                           parse_constant=lambda _: (_ for _ in ()).throw(ProtocolError("Invalid JSON number")))
    except (ValueError, UnicodeDecodeError, RecursionError) as exc:
        raise ProtocolError("Invalid JSON") from exc
    if not isinstance(value, dict):
        raise ProtocolError("Expected JSON object")
    return value


@dataclass(frozen=True)
class Header:
    kind: str
    request_id: str
    issued_ms: int
    expires_ms: int
    nonce: bytes
    raw: bytes
    ciphertext: bytes


def inspect_frame(frame: bytes, expected_kind: str | None = None, *, allow_expired: bool = False) -> Header:
    if not isinstance(frame, bytes) or not 24 <= len(frame) <= MAX_FRAME or frame[:4] != MAGIC:
        raise ProtocolError("Invalid frame")
    length = struct.unpack("!H", frame[4:6])[0]
    if not 1 <= length <= MAX_HEADER or len(frame) < 6 + length + 16:
        raise ProtocolError("Invalid header length")
    raw = frame[6:6 + length]
    item = decode_json(raw)
    if set(item) != {"v", "kind", "id", "iat", "exp", "nonce"} or type(item["v"]) is not int or item["v"] != 1:
        raise ProtocolError("Unsupported header")
    if not isinstance(item["kind"], str) or item["kind"] not in {"request", "response"} or (expected_kind and item["kind"] != expected_kind):
        raise ProtocolError("Wrong direction")
    if not isinstance(item["id"], str) or not ID_RE.fullmatch(item["id"]):
        raise ProtocolError("Invalid request ID")
    issued, expires, stamp = item["iat"], item["exp"], now_ms()
    if (type(issued) is not int or type(expires) is not int or not 0 < expires - issued <= LIFETIME_MS
            or issued > stamp + CLOCK_SKEW_MS or (expires < stamp and not allow_expired)):
        raise ProtocolError("Expired frame or clock mismatch")
    try:
        nonce = base64.b64decode(item["nonce"], validate=True)
    except (ValueError, TypeError) as exc:
        raise ProtocolError("Invalid nonce") from exc
    if len(nonce) != 12:
        raise ProtocolError("Invalid nonce length")
    return Header(item["kind"], item["id"], issued, expires, nonce, raw, frame[6 + length:])


class Cipher:
    def __init__(self, channel: str, master_key: str):
        if not CHANNEL_RE.fullmatch(channel):
            raise ProtocolError("Invalid channel")
        try:
            secret = base64.b64decode(master_key, validate=True)
        except (ValueError, TypeError) as exc:
            raise ProtocolError("Invalid encryption key") from exc
        if len(secret) != 32:
            raise ProtocolError("AES-256 requires 32 key bytes")
        self.channel = channel.encode("ascii")
        self.keys = {
            direction: HKDF(algorithm=hashes.SHA256(), length=32,
                            salt=hashlib.sha256(self.channel).digest(),
                            info=b"HajiSaki/relay/v1/" + direction.encode("ascii")).derive(secret)
            for direction in ("request", "response")
        }

    def seal(self, kind: str, request_id: str, metadata: dict, body: bytes = b"") -> bytes:
        if kind not in self.keys or not ID_RE.fullmatch(request_id):
            raise ProtocolError("Invalid direction or ID")
        meta = encode_json(metadata)
        if len(meta) > MAX_META or len(body) > MAX_BODY:
            raise ProtocolError("Payload exceeds transport bound")
        nonce, issued = os.urandom(12), now_ms()
        header = encode_json({"v": 1, "kind": kind, "id": request_id, "iat": issued,
                              "exp": issued + LIFETIME_MS, "nonce": base64.b64encode(nonce).decode("ascii")})
        plain = struct.pack("!I", len(meta)) + meta + body
        encrypted = AESGCM(self.keys[kind]).encrypt(nonce, plain, self.channel + b"\0" + header)
        return MAGIC + struct.pack("!H", len(header)) + header + encrypted

    def open(self, frame: bytes, kind: str, *, allow_expired: bool = False) -> tuple[Header, dict, bytes, str]:
        # Expiry bypass is only for authenticating locally persisted ciphertext before renewal.
        # Network receivers always retain the default strict expiry check.
        header = inspect_frame(frame, kind, allow_expired=allow_expired)
        try:
            plain = AESGCM(self.keys[kind]).decrypt(header.nonce, header.ciphertext,
                                                    self.channel + b"\0" + header.raw)
        except InvalidTag as exc:
            raise ProtocolError("Frame authentication failed") from exc
        if len(plain) < 4:
            raise ProtocolError("Missing metadata")
        size = struct.unpack("!I", plain[:4])[0]
        if not 1 <= size <= MAX_META or len(plain) < 4 + size or len(plain) - 4 - size > MAX_BODY:
            raise ProtocolError("Invalid plaintext length")
        return header, decode_json(plain[4:4 + size]), plain[4 + size:], hashlib.sha256(plain).hexdigest()


def new_id() -> str:
    return uuid.uuid4().hex
