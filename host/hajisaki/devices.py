"""Independent software device credentials; no hardware identity or biometric claim.

Integration: construct DeviceRegistry(store, config.token, config.device); authenticate
the raw bearer token together with X-Haji-Device and return the DevicePrincipal.
Mount registry.router(authenticate). Recheck registry.is_active(principal) while
streaming, after Store.on_commit wakeups. Call issue_browser only AFTER the existing
same-Windows-owner, actual-loopback, Origin and no-forwarded-header checks succeed.

Only a SHA-256 digest of each high-entropy token is stored in SQLite. Enrollment and
local browser pairing return the fresh token once; list/auth/revocation never do.
The protected bootstrap pairing file remains the local source for its token, and
startup never clears a recorded revocation. Keep private issue results out of logs.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import sqlite3
from dataclasses import dataclass, field
from typing import Callable, Literal

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator

from .config import protect_credentials, secure_data_directory
from .store import Store, now, uid

Role = Literal["owner", "companion"]
_UNRECOGNIZED = "还没有认出这台设备，请先与主机配对。"
_OWNER_ONLY = "只有主人钥匙能登记、查看或收回设备。"
_PRIVATE_HEADERS = {"Cache-Control": "no-store", "Pragma": "no-cache"}


def _token_digest(token: str) -> str:
    return hashlib.sha256(b"HajiSaki-device-token-v1\0" + token.encode("utf-8")).hexdigest()


def _label(value: str) -> str:
    if not isinstance(value, str):
        raise ValueError("Device name must be text")
    value = value.strip()
    if not 1 <= len(value) <= 80 or any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("Device name must contain 1 to 80 printable characters")
    value.encode("utf-8", errors="strict")
    return value


@dataclass(frozen=True)
class DevicePrincipal:
    device_id: str
    name: str
    role: Role
    created_at: str
    bootstrap: bool
    credential_digest: str = field(repr=False)

    def public(self) -> dict:
        return {"id": self.device_id, "name": self.name, "role": self.role,
                "created_at": self.created_at, "bootstrap": self.bootstrap}


class Enrollment(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    name: str = Field(min_length=1, max_length=80)
    role: Role = "companion"

    @field_validator("name")
    @classmethod
    def valid_name(cls, value: str) -> str:
        return _label(value)


class DeviceRegistry:
    def __init__(self, store: Store, bootstrap_token: str, bootstrap_device: str):
        if (not isinstance(bootstrap_token, str) or not 32 <= len(bootstrap_token) <= 512
                or not isinstance(bootstrap_device, str) or not 1 <= len(bootstrap_device) <= 256):
            raise ValueError("Invalid bootstrap pairing configuration")
        self.store = store
        digest = _token_digest(bootstrap_token)
        with store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("""CREATE TABLE IF NOT EXISTS paired_devices (
                id TEXT PRIMARY KEY, name TEXT NOT NULL,
                token_hash TEXT NOT NULL UNIQUE CHECK(length(token_hash)=64),
                role TEXT NOT NULL CHECK(role IN ('owner','companion')),
                created_at TEXT NOT NULL, revoked_at TEXT,
                bootstrap INTEGER NOT NULL DEFAULT 0 CHECK(bootstrap IN (0,1)))""")
            db.execute("CREATE UNIQUE INDEX IF NOT EXISTS paired_devices_bootstrap ON paired_devices(bootstrap) WHERE bootstrap=1")
            existing = db.execute("SELECT * FROM paired_devices WHERE bootstrap=1").fetchone()
            if existing is not None and existing["id"] != bootstrap_device:
                raise ValueError("Changing the bootstrap device ID requires an explicit owner migration")
            if existing is None:
                collision = db.execute("SELECT id FROM paired_devices WHERE id=?", (bootstrap_device,)).fetchone()
                if collision:
                    raise ValueError("Bootstrap identity conflicts with a registered device")
                db.execute("INSERT INTO paired_devices VALUES(?,?,?,'owner',?,NULL,1)",
                           (bootstrap_device, "主机引导钥匙", digest, now()))
            elif not hmac.compare_digest(existing["token_hash"], digest):
                # A local token-file rotation changes its digest, never resurrects a revoked identity.
                db.execute("UPDATE paired_devices SET token_hash=? WHERE id=?", (digest, bootstrap_device))

    @staticmethod
    def _public(row: sqlite3.Row | dict) -> dict:
        return {"id": row["id"], "name": row["name"], "role": row["role"],
                "created_at": row["created_at"], "revoked_at": row["revoked_at"],
                "bootstrap": bool(row["bootstrap"])}

    @staticmethod
    def _matches(row: sqlite3.Row | dict | None, digest: str) -> bool:
        expected = row["token_hash"] if row is not None else "0" * 64
        matched = hmac.compare_digest(expected, digest)
        return row is not None and matched and row["revoked_at"] is None

    def authenticate(self, raw_token: str, device_id: str) -> DevicePrincipal:
        if (not isinstance(raw_token, str) or not 32 <= len(raw_token) <= 512
                or not isinstance(device_id, str) or not 1 <= len(device_id) <= 256):
            raise HTTPException(401, _UNRECOGNIZED)
        try:
            digest = _token_digest(raw_token)
        except UnicodeError as exc:
            raise HTTPException(401, _UNRECOGNIZED) from exc
        row = self.store.one("SELECT * FROM paired_devices WHERE id=?", (device_id,))
        if not self._matches(row, digest):
            raise HTTPException(401, _UNRECOGNIZED)
        return DevicePrincipal(row["id"], row["name"], row["role"], row["created_at"],
                               bool(row["bootstrap"]), digest)

    def is_active(self, principal: DevicePrincipal) -> bool:
        if not isinstance(principal, DevicePrincipal):
            return False
        row = self.store.one("SELECT token_hash,revoked_at,role FROM paired_devices WHERE id=?", (principal.device_id,))
        return self._matches(row, principal.credential_digest) and row["role"] == principal.role

    def _require_owner(self, db: sqlite3.Connection, principal: DevicePrincipal):
        if not isinstance(principal, DevicePrincipal):
            raise HTTPException(403, _OWNER_ONLY)
        row = db.execute("SELECT token_hash,revoked_at,role FROM paired_devices WHERE id=?", (principal.device_id,)).fetchone()
        if not self._matches(row, principal.credential_digest):
            raise HTTPException(401, _UNRECOGNIZED)
        if row["role"] != "owner":
            raise HTTPException(403, _OWNER_ONLY)

    @staticmethod
    def _issue(db: sqlite3.Connection, name: str, role: Role) -> dict:
        if not isinstance(role, str) or role not in {"owner", "companion"}:
            raise ValueError("Unknown device role")
        device_id, token, stamp = "device-" + uid(), secrets.token_urlsafe(48), now()
        db.execute("INSERT INTO paired_devices VALUES(?,?,?,?,?,NULL,0)",
                   (device_id, name, _token_digest(token), role, stamp))
        # This dictionary is the one-time private response, not a public device record.
        return {"device": device_id, "token": token, "name": name, "role": role,
                "created_at": stamp, "revoked_at": None, "bootstrap": False}

    def list_devices(self, principal: DevicePrincipal) -> list[dict]:
        with self.store.connect() as db:
            db.execute("BEGIN")
            self._require_owner(db, principal)
            rows = db.execute("SELECT * FROM paired_devices ORDER BY created_at,id").fetchall()
            return [self._public(row) for row in rows]

    def enroll(self, principal: DevicePrincipal, name: str, role: Role = "companion") -> dict:
        name = _label(name)
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            self._require_owner(db, principal)
            return self._issue(db, name, role)

    def issue_browser(self, label: str = "这台电脑的浏览器") -> dict:
        """Local owner-authorized entry; caller MUST first pass the app's Windows SID gate.

        This method is deliberately absent from the device-management router. It grants
        a new owner credential for the current local browser instead of revealing the
        bootstrap credential. Calling it is not itself proof of Windows-user identity.
        """
        label = _label(label)
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            return self._issue(db, label, "owner")

    def revoke(self, principal: DevicePrincipal, device_id: str) -> dict:
        if not isinstance(device_id, str) or not 1 <= len(device_id) <= 256:
            raise HTTPException(404, "这台设备还没写进琴房名册。")
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            self._require_owner(db, principal)
            row = db.execute("SELECT * FROM paired_devices WHERE id=?", (device_id,)).fetchone()
            if row is None:
                raise HTTPException(404, "这台设备还没写进琴房名册。")
            if row["revoked_at"] is None:
                if row["role"] == "owner":
                    owners = db.execute("SELECT count(*) FROM paired_devices WHERE role='owner' AND revoked_at IS NULL").fetchone()[0]
                    if owners <= 1:
                        raise HTTPException(409, "请先留下一把可用的主人钥匙，再收回这一把。")
                db.execute("UPDATE paired_devices SET revoked_at=? WHERE id=?", (now(), device_id))
                row = db.execute("SELECT * FROM paired_devices WHERE id=?", (device_id,)).fetchone()
            return self._public(row)

    def enroll_to_file(self, principal: DevicePrincipal, name: str, role: Role = "companion") -> dict:
        """Local provisioning alternative: return only metadata/path, never the raw token.

        The protected file is written before the SQLite transaction commits. Failure
        leaves no active credential; any partial private file is retained, not erased.
        This filesystem operation is not exposed through an HTTP route.
        """
        name = _label(name)
        data_root = self.store.path.parent.resolve()
        directory = (data_root / "device-provisioning").resolve()
        if not directory.is_relative_to(data_root):
            raise ValueError("Private provisioning directory escaped the data directory")
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            self._require_owner(db, principal)
            secure_data_directory(directory)
            issued = self._issue(db, name, role)
            path = directory / (issued["device"] + ".json")
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                json.dump(issued, output, ensure_ascii=True, indent=2)
                output.write("\n")
                output.flush()
                os.fsync(output.fileno())
            protect_credentials(path)
            row = db.execute("SELECT * FROM paired_devices WHERE id=?", (issued["device"],)).fetchone()
            return {"device": self._public(row), "file": str(path)}

    def router(self, authenticate: Callable) -> APIRouter:
        router = APIRouter(prefix="/api/devices")

        @router.get("")
        async def listing(principal: DevicePrincipal = Depends(authenticate)):
            return JSONResponse({"devices": self.list_devices(principal)}, headers=_PRIVATE_HEADERS)

        @router.post("", status_code=201)
        async def enrollment(body: Enrollment, principal: DevicePrincipal = Depends(authenticate)):
            issued = self.enroll(principal, body.name, body.role)
            return JSONResponse(issued, status_code=201, headers=_PRIVATE_HEADERS)

        @router.post("/{device_id}/revoke")
        async def revocation(device_id: str, principal: DevicePrincipal = Depends(authenticate)):
            return JSONResponse(self.revoke(principal, device_id), headers=_PRIVATE_HEADERS)

        return router
