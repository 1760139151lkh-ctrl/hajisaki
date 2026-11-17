"""Private incremental backups; SQLite snapshots and authenticated encrypted chunks.

The source instance remains live. Restore only creates a new dedicated directory.
No backup rotation, deletion, overwrite restore, or model/API service is involved.
"""

from __future__ import annotations

import asyncio
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, time as local_time, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import sqlite3
import subprocess
import sys
import time
import uuid
from zoneinfo import ZoneInfo

from .config import protect_credentials, secure_data_directory


CHUNK_SIZE = 4 * 1024 * 1024
MAX_MANIFEST = 32 * 1024 * 1024
MAGIC = b"HJSB1"
DATA_FOLDERS = ("speech", "notes", "workspaces", "exports")
CONFIG_FILES = ("pairing.json", "host-settings.json", "models.json", "speech-settings.json", "maintenance-settings.json")


class BackupError(ValueError):
    pass


def _json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".writing")
    with temporary.open("x", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, allow_nan=False)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    temporary.replace(path)


def _load(path: Path, default=None):
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


@contextmanager
def _database(path: Path, timeout: int = 30):
    connection = sqlite3.connect(str(path), timeout=timeout)
    try:
        with connection:
            yield connection
    finally:
        connection.close()


def _relative(value: str) -> str:
    if not isinstance(value, str) or "\\" in value or ":" in value or any(ord(c) < 32 for c in value):
        raise BackupError("Invalid backup path")
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts or any(part in {".", ".."} or part.endswith((".", " ")) for part in path.parts):
        raise BackupError("Invalid backup path")
    reserved = {"CON", "PRN", "AUX", "NUL"} | {f"{prefix}{number}" for prefix in ("COM", "LPT") for number in range(1, 10)}
    if any(part.split(".")[0].upper() in reserved for part in path.parts):
        raise BackupError("Reserved backup path")
    return path.as_posix()


@dataclass(frozen=True)
class BackupSettings:
    data_dir: Path
    repository: Path
    key_file: Path
    timezone_name: str = "America/Los_Angeles"
    hour: int = 3
    minute: int = 0
    enabled: bool = True

    @classmethod
    def load(cls, data_dir: Path) -> "BackupSettings":
        data = Path(data_dir).expanduser().resolve()
        identity = hashlib.sha256(str(data).casefold().encode()).hexdigest()[:16]
        base = Path(os.environ.get("LOCALAPPDATA", Path.home() / ".local/share"))
        values = _load(data / "maintenance-settings.json", {})
        allowed = {"repository", "key_file", "timezone", "hour", "minute", "enabled"}
        if not isinstance(values, dict) or set(values) - allowed:
            raise BackupError("Unknown maintenance setting")
        previous = _load(data / ".maintenance" / "last-success.json", {})
        settings = cls(
            data_dir=data,
            repository=Path(values.get("repository", previous.get("repository", base / "HajiSakiBackups" / identity))).expanduser().resolve(),
            key_file=Path(values.get("key_file", previous.get("key_file", base / "HajiSakiBackupKeys" / (identity + ".key")))).expanduser().resolve(),
            timezone_name=values.get("timezone", "America/Los_Angeles"),
            hour=values.get("hour", 3), minute=values.get("minute", 0), enabled=values.get("enabled", True),
        )
        ZoneInfo(settings.timezone_name)
        if type(settings.hour) is not int or type(settings.minute) is not int or not 0 <= settings.hour <= 23 or not 0 <= settings.minute <= 59:
            raise BackupError("Invalid daily backup time")
        if type(settings.enabled) is not bool:
            raise BackupError("enabled must be boolean")
        if settings.repository.is_relative_to(data) or data.is_relative_to(settings.repository):
            raise BackupError("Backup repository must be outside the source instance")
        if settings.key_file.is_relative_to(settings.repository) or settings.key_file.is_relative_to(data):
            raise BackupError("The encryption key must be outside both source and backup repository")
        return settings


@contextmanager
def _repository_lock(repository: Path):
    secure_data_directory(repository)
    with (repository / "writer.lock").open("a+b") as handle:
        handle.seek(0, os.SEEK_END)
        if not handle.tell():
            handle.write(b"0")
            handle.flush()
        handle.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise BackupError("Another backup writer is already working") from error
        try:
            yield
        finally:
            handle.seek(0)
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def _writer_busy(repository: Path) -> bool:
    """Inspect the OS-held lock, including a worker from an older gateway."""
    path = repository / "writer.lock"
    if not path.exists():
        return False
    with path.open("r+b") as handle:
        handle.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return True
        if os.name == "nt":
            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    return False


class EncryptedBackup:
    def __init__(self, settings: BackupSettings, project_root: Path):
        self.settings = settings
        self.project_root = Path(project_root).resolve()
        self._verified: set[str] = set()
        self.new_bytes = 0
        self.reused_bytes = 0

    def _crypto(self, create_key: bool):
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        from cryptography.hazmat.primitives.kdf.hkdf import HKDF
        path = self.settings.key_file
        if not path.exists():
            if not create_key:
                raise BackupError("The private backup key is unavailable")
            secure_data_directory(path.parent)
            with path.open("xb") as handle:
                handle.write(secrets.token_bytes(32))
                handle.flush()
                os.fsync(handle.fileno())
        protect_credentials(path)
        key = path.read_bytes()
        if len(key) != 32:
            raise BackupError("The private backup key has an invalid length")
        self.key_id = hashlib.sha256(key).hexdigest()[:24]
        self.chunk_cipher = AESGCM(HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=b"HajiSaki backup chunks v1").derive(key))
        self.manifest_cipher = AESGCM(HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=b"HajiSaki backup manifest v1").derive(key))

    @staticmethod
    def _seal(cipher, content: bytes, aad: bytes) -> bytes:
        nonce = secrets.token_bytes(12)
        return MAGIC + nonce + cipher.encrypt(nonce, content, aad)

    @staticmethod
    def _open(cipher, content: bytes, aad: bytes) -> bytes:
        if len(content) < 33 or not content.startswith(MAGIC):
            raise BackupError("Invalid encrypted backup object")
        return cipher.decrypt(content[5:17], content[17:], aad)

    def _chunk_path(self, digest: str) -> Path:
        if not re.fullmatch(r"[a-f0-9]{64}", digest):
            raise BackupError("Invalid chunk digest")
        return self.settings.repository / "objects" / self.key_id / digest[:2] / (digest + ".bin")

    def _chunk(self, digest: str, size: int) -> bytes:
        if type(size) is not int or not 0 < size <= CHUNK_SIZE:
            raise BackupError("Invalid chunk length")
        path = self._chunk_path(digest)
        if path.stat().st_size != size + 33:
            raise BackupError("Encrypted chunk length mismatch")
        aad = f"HajiSaki/chunk/v1/{digest}/{size}".encode()
        content = self._open(self.chunk_cipher, path.read_bytes(), aad)
        if len(content) != size or hashlib.sha256(content).hexdigest() != digest:
            raise BackupError("Backup chunk integrity mismatch")
        return content

    def _put_chunk(self, content: bytes) -> dict:
        digest = hashlib.sha256(content).hexdigest()
        size = len(content)
        path = self._chunk_path(digest)
        if path.exists():
            if digest not in self._verified:
                self._chunk(digest, size)
            self.reused_bytes += size
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            aad = f"HajiSaki/chunk/v1/{digest}/{size}".encode()
            encrypted = self._seal(self.chunk_cipher, content, aad)
            temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".partial")
            with temporary.open("xb") as handle:
                handle.write(encrypted)
                handle.flush()
                os.fsync(handle.fileno())
            temporary.resolve().relative_to(self.settings.repository)
            path.resolve().relative_to(self.settings.repository)
            temporary.rename(path)
            self.new_bytes += len(encrypted)
        self._verified.add(digest)
        return {"sha256": digest, "size": size}

    def _pack_file(self, source: Path, relative: str, expected_size: int | None = None, expected_sha: str | None = None) -> dict:
        relative = _relative(relative)
        if source.is_symlink() or not source.is_file():
            raise BackupError("A required source file is unavailable or linked")
        resolved = source.resolve()
        if not (resolved.is_relative_to(self.settings.data_dir) or resolved.is_relative_to(self.settings.repository / "staging")
                or resolved == self.project_root / "runtime" / "speech-settings.json"):
            raise BackupError("Source path escapes the selected instance")
        for attempt in range(3):
            digest = hashlib.sha256()
            chunks, size = [], 0
            with source.open("rb") as handle:
                before = os.fstat(handle.fileno())
                while content := handle.read(CHUNK_SIZE):
                    digest.update(content)
                    size += len(content)
                    chunks.append(self._put_chunk(content))
                after = os.fstat(handle.fileno())
            if (before.st_size, before.st_mtime_ns) == (after.st_size, after.st_mtime_ns) and size == after.st_size:
                break
        else:
            raise BackupError("A source file is still changing; the snapshot was not committed")
        if expected_size is not None and size != expected_size:
            raise BackupError("An original artifact has an unexpected length")
        if expected_sha is not None and digest.hexdigest() != expected_sha:
            raise BackupError("An original artifact failed its SHA-256 check")
        return {"path": relative, "size": size, "sha256": digest.hexdigest(), "mtime_ns": after.st_mtime_ns, "chunks": chunks}

    @staticmethod
    def _database_check(path: Path) -> dict:
        with _database(path) as db:
            if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise BackupError("SQLite integrity check failed")
            if db.execute("PRAGMA foreign_key_check").fetchone() is not None:
                raise BackupError("SQLite foreign key check failed")
            exists = db.execute("SELECT 1 FROM sqlite_master WHERE name='message_search'").fetchone()
            if exists:
                db.execute("INSERT INTO message_search(message_search,rank) VALUES('integrity-check',1)")
            counts = {}
            for name in ("conversations", "messages", "events", "memories", "artifacts", "settings"):
                if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone():
                    counts[name] = db.execute(f'SELECT count(*) FROM "{name}"').fetchone()[0]
            return counts

    def backup(self) -> dict:
        settings = self.settings
        source_db = settings.data_dir / "hajisaki.sqlite3"
        if not source_db.is_file():
            raise BackupError("The selected host instance has no database")
        started = time.monotonic()
        backup_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:12]
        with _repository_lock(settings.repository):
            self._crypto(True)
            staging = settings.repository / "staging" / backup_id
            staging.mkdir(parents=True)
            snapshot = staging / "hajisaki.sqlite3"
            with _database(source_db, timeout=60) as db:
                db.execute("PRAGMA busy_timeout=60000")
                db.execute("PRAGMA synchronous=FULL")
                db.execute("VACUUM INTO ?", (str(snapshot),))
            with _database(snapshot) as db:
                db.execute("PRAGMA journal_mode=DELETE")
                artifacts = db.execute("SELECT DISTINCT sha256,size FROM artifacts ORDER BY sha256").fetchall()
                artifact_ids = {row[0] for row in db.execute("SELECT id FROM artifacts")}
                pending = db.execute("SELECT id,size,sha256 FROM uploads WHERE artifact_id IS NULL").fetchall()
            files = []
            for digest, size in artifacts:
                if not re.fullmatch(r"[a-f0-9]{64}", digest) or type(size) is not int or size < 0:
                    raise BackupError("Invalid artifact metadata in database snapshot")
                source = settings.data_dir / "objects" / digest[:2] / digest
                files.append(self._pack_file(source, f"objects/{digest[:2]}/{digest}", size, digest))
            for ident, size, digest in pending:
                if not re.fullmatch(r"[a-f0-9]{32}", ident) or not re.fullmatch(r"[a-f0-9]{64}", digest) or type(size) is not int or size < 0:
                    raise BackupError("Invalid pending upload identifier")
                source = settings.data_dir / "uploads" / ident
                if not source.is_file():
                    source = settings.data_dir / "objects" / digest[:2] / digest
                packed = self._pack_file(source, f"uploads/{ident}")
                if packed["size"] > size:
                    raise BackupError("Pending upload exceeds its declared size")
                files.append(packed)
                with _database(snapshot) as db:
                    db.execute("UPDATE uploads SET offset=? WHERE id=?", (packed["size"], ident))
            for name in CONFIG_FILES:
                source = settings.data_dir / name
                if source.is_file():
                    files.append(self._pack_file(source, name))
            shared_speech = self.project_root / "runtime" / "speech-settings.json"
            if shared_speech.is_file() and shared_speech.parent.resolve() != settings.data_dir:
                files.append(self._pack_file(shared_speech, "project-settings/speech-settings.json"))
            for folder in DATA_FOLDERS:
                base = settings.data_dir / folder
                if not base.exists():
                    continue
                job_states = {}
                for source in sorted(base.rglob("*")):
                    if source.is_symlink():
                        raise BackupError("Linked source paths are not followed")
                    if not source.is_file() or source.name.endswith((".writing", ".log")):
                        continue
                    if folder == "speech" and source.name not in {"hotwords.json", "metadata.json", "segments.jsonl", "result.json", "state.json"} and not source.name.startswith("original."):
                        continue
                    relative = source.relative_to(settings.data_dir).as_posix()
                    parts = PurePosixPath(relative).parts
                    if folder == "speech" and len(parts) >= 4 and parts[1] == "jobs":
                        job_id = parts[2]
                        if job_id not in job_states:
                            job_states[job_id] = _load(base / "jobs" / job_id / "state.json", {})
                        captured_state = job_states[job_id]
                        if captured_state.get("artifact", {}).get("id") not in artifact_ids and captured_state:
                            continue  # Its source artifact was created after the database snapshot.
                    if folder == "speech" and source.name == "state.json" and len(parts) >= 4 and parts[1] == "jobs":
                        state = dict(captured_state)
                        final_path = str(PurePosixPath(relative).parent / "result.json")
                        captured_final = any(item["path"] == final_path for item in files)
                        if state.get("status") in {"queued", "running"} or (state.get("status") == "completed" and not captured_final):
                            state["status"] = "interrupted"
                            state["detail"] = "这段未完成转写来自备份，原音已保留，请重新发起转写。"
                        state["worker_pid"] = None
                        normalized = staging / "portable" / relative
                        _json(normalized, state)
                        source = normalized
                    files.append(self._pack_file(source, relative))
            with _database(snapshot) as db:
                # messages uses an implicit rowid; VACUUM may renumber it.
                if db.execute("SELECT 1 FROM sqlite_master WHERE name='message_search'").fetchone():
                    db.execute("INSERT INTO message_search(message_search) VALUES('rebuild')")
            counts = self._database_check(snapshot)
            files.append(self._pack_file(snapshot, "hajisaki.sqlite3"))
            manifest = {"format": 1, "id": backup_id, "created_at": datetime.now(timezone.utc).isoformat(),
                        "key_id": self.key_id, "chunk_size": CHUNK_SIZE, "files": files, "database_counts": counts,
                        "source_scope": "one configured host instance; referenced CAS, pending uploads, user data and settings",
                        "consistency": "SQLite transaction snapshot; stable individual sidecar versions; unfinished speech tasks normalized to interrupted without restoring stale process IDs",
                        "excluded": ["other host instances", "unreferenced CAS", "diagnostic logs", "browser probes", "model caches", "backup keys", "worker request paths"]}
            encoded = json.dumps(manifest, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode()
            if len(encoded) > MAX_MANIFEST:
                raise BackupError("Manifest exceeds the supported size")
            encrypted = self._seal(self.manifest_cipher, encoded, f"HajiSaki/manifest/v1/{backup_id}/{self.key_id}".encode())
            directory = settings.repository / "snapshots"
            directory.mkdir(exist_ok=True)
            manifest_path = directory / (backup_id + ".manifest")
            with manifest_path.open("xb") as handle:
                handle.write(encrypted)
                handle.flush()
                os.fsync(handle.fileno())
            report = {"format": 1, "id": backup_id, "status": "complete", "created_at": manifest["created_at"],
                      "key_id": self.key_id, "manifest_sha256": hashlib.sha256(encrypted).hexdigest(),
                      "files": len(files), "source_bytes": sum(item["size"] for item in files),
                      "new_encrypted_bytes": self.new_bytes + len(encrypted), "reused_plaintext_bytes": self.reused_bytes,
                      "elapsed_seconds": round(time.monotonic() - started, 3), "database_counts": counts,
                      "repository": str(settings.repository), "key_file": str(settings.key_file)}
            staging_bytes = sum(path.stat().st_size for path in staging.rglob("*") if path.is_file())
            _json(directory / (backup_id + ".json"), report)
            _json(settings.data_dir / ".maintenance" / "last-success.json", report)
            # Plaintext staging is disposable only after the encrypted commit exists.
            from send2trash import send2trash
            staging.resolve().relative_to(settings.repository)
            send2trash(str(staging))
            report["recycled_staging"] = {"name": "staging/" + backup_id, "bytes": staging_bytes}
            return report

    def _manifest(self, backup_id: str) -> dict:
        if not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z-[a-f0-9]{12}", backup_id):
            raise BackupError("Invalid backup identifier")
        self._crypto(False)
        path = self.settings.repository / "snapshots" / (backup_id + ".manifest")
        report = _load(path.with_suffix(".json"))
        if not report or report.get("status") != "complete" or report.get("key_id") != self.key_id:
            raise BackupError("This snapshot is uncommitted or uses another private key")
        if path.stat().st_size > MAX_MANIFEST + 33:
            raise BackupError("Encrypted manifest is too large")
        encrypted = path.read_bytes()
        if hashlib.sha256(encrypted).hexdigest() != report["manifest_sha256"]:
            raise BackupError("Encrypted manifest integrity mismatch")
        manifest = json.loads(self._open(self.manifest_cipher, encrypted, f"HajiSaki/manifest/v1/{backup_id}/{self.key_id}".encode()))
        if manifest.get("format") != 1 or manifest.get("id") != backup_id or manifest.get("key_id") != self.key_id:
            raise BackupError("Invalid authenticated manifest identity")
        seen = set()
        for item in manifest["files"]:
            relative = _relative(item["path"])
            if relative.casefold() in seen or type(item["size"]) is not int or item["size"] < 0:
                raise BackupError("Invalid or duplicate manifest entry")
            seen.add(relative.casefold())
            if not re.fullmatch(r"[a-f0-9]{64}", item["sha256"]) or sum(chunk["size"] for chunk in item["chunks"]) != item["size"]:
                raise BackupError("Invalid authenticated file digest or length")
        if "hajisaki.sqlite3" not in seen:
            raise BackupError("Snapshot has no database")
        return manifest

    def verify(self, backup_id: str) -> dict:
        started = time.monotonic()
        manifest = self._manifest(backup_id)
        total = 0
        for item in manifest["files"]:
            digest = hashlib.sha256()
            for chunk in item["chunks"]:
                content = self._chunk(chunk["sha256"], chunk["size"])
                digest.update(content)
                total += len(content)
            if digest.hexdigest() != item["sha256"]:
                raise BackupError("Restored file ordering or digest mismatch")
        return {"id": backup_id, "status": "verified", "files": len(manifest["files"]), "verified_bytes": total,
                "elapsed_seconds": round(time.monotonic() - started, 3)}

    def restore(self, backup_id: str, destination: Path) -> dict:
        target = Path(destination).expanduser().resolve()
        if target.exists() or target.is_relative_to(self.settings.data_dir) or target.is_relative_to(self.settings.repository):
            raise BackupError("Restore requires a new directory outside source and backup repository")
        manifest = self._manifest(backup_id)
        target.mkdir(parents=True, exist_ok=False)
        secure_data_directory(target)
        _json(target / "restore-report.json", {"status": "incomplete", "backup_id": backup_id})
        started = time.monotonic()
        total = 0
        for item in manifest["files"]:
            path = target.joinpath(*PurePosixPath(item["path"]).parts)
            path.resolve().relative_to(target)
            path.parent.mkdir(parents=True, exist_ok=True)
            digest = hashlib.sha256()
            with path.open("xb") as handle:
                for chunk in item["chunks"]:
                    content = self._chunk(chunk["sha256"], chunk["size"])
                    handle.write(content)
                    digest.update(content)
                    total += len(content)
                handle.flush()
                os.fsync(handle.fileno())
            if path.stat().st_size != item["size"] or digest.hexdigest() != item["sha256"]:
                raise BackupError("A restored file failed integrity verification")
            os.utime(path, ns=(item["mtime_ns"], item["mtime_ns"]))
        counts = self._database_check(target / "hajisaki.sqlite3")
        if counts != manifest["database_counts"]:
            raise BackupError("Restored database summary differs from snapshot")
        report = {"status": "complete", "backup_id": backup_id, "destination": str(target),
                  "files": len(manifest["files"]), "restored_bytes": total, "database_counts": counts,
                  "elapsed_seconds": round(time.monotonic() - started, 3),
                  "note": "Restored into a new private directory; no running host was switched or overwritten."}
        _json(target / "restore-report.json", report)
        return report


class QuietMaintenance:
    """Daily catch-up scheduler; heavy I/O and crypto remain in a separate process."""

    def __init__(self, data_dir: Path, project_root: Path):
        self.data_dir = Path(data_dir).resolve()
        self.project_root = Path(project_root).resolve()
        self._stop = asyncio.Event()
        self._task = None
        self._process = None

    def status(self) -> dict:
        settings = BackupSettings.load(self.data_dir)
        previous = _load(self.data_dir / ".maintenance" / "last-success.json", {})
        return {"enabled": settings.enabled, "timezone": settings.timezone_name,
                "daily_time": f"{settings.hour:02d}:{settings.minute:02d}",
                "encryption_available": importlib.util.find_spec("cryptography") is not None,
                "running": (self._process is not None and self._process.poll() is None) or _writer_busy(settings.repository),
                "last_success": {key: previous[key] for key in ("id", "created_at", "files", "source_bytes") if key in previous},
                "off_device_copy": False}

    async def start(self) -> None:
        if self._task is None:
            self._task = asyncio.create_task(self._run())

    async def _run(self) -> None:
        while not self._stop.is_set():
            try:
                settings = BackupSettings.load(self.data_dir)
                now = datetime.now(ZoneInfo(settings.timezone_name))
                due = datetime.combine(now.date(), local_time(settings.hour, settings.minute), now.tzinfo)
                last = _load(self.data_dir / ".maintenance" / "last-success.json", {})
                last_time = datetime.fromisoformat(last["created_at"]).astimezone(now.tzinfo) if last else None
                attempt = _load(self.data_dir / ".maintenance" / "last-attempt.json", {})
                retry_ready = time.time() - attempt.get("time", 0) >= 900
                running = (self._process is not None and self._process.poll() is None) or _writer_busy(settings.repository)
                installed = importlib.util.find_spec("cryptography") is not None
                if installed and settings.enabled and now >= due and (last_time is None or last_time < due) and retry_ready and not running:
                    directory = self.data_dir / ".maintenance"
                    directory.mkdir(parents=True, exist_ok=True)
                    _json(directory / "last-attempt.json", {"time": time.time(), "timezone": settings.timezone_name})
                    with (directory / "worker.log").open("ab") as log:
                        self._process = subprocess.Popen(
                            [sys.executable, str(self.project_root / "host/tools/maintenance.py"), "--data-dir", str(self.data_dir), "backup"],
                            cwd=self.project_root, shell=False,
                            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
                            stdout=log, stderr=subprocess.STDOUT, env={**os.environ, "PYTHONUTF8": "1"},
                        )
            except Exception as error:
                _json(self.data_dir / ".maintenance" / "scheduler-diagnostic.json", {"type": type(error).__name__, "message": str(error)})
            try:
                await asyncio.wait_for(self._stop.wait(), timeout=30)
            except asyncio.TimeoutError:
                pass

    async def close(self) -> None:
        self._stop.set()
        if self._task is not None:
            await self._task
        # An already-running backup completes independently; never terminate it
        # merely because the gateway lifecycle is ending.
