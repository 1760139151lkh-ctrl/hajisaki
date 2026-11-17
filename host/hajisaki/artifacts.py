from __future__ import annotations

import hashlib
import mimetypes
import os
import re
import stat
import struct
import threading
import zipfile
from pathlib import Path, PurePosixPath

from .config import Config
from .store import Store, now, uid


class TransferError(ValueError):
    pass


def safe_name(value: str) -> str:
    value = value.replace("\\", "/").split("/")[-1]
    value = re.sub(r'[\x00-\x1f<>:"|?*]', "_", value).strip(" .")[:180]
    return value or "未命名文件"


class Artifacts:
    def __init__(self, config: Config, store: Store):
        self.config = config
        self.store = store
        self.root = config.data_dir / "objects"
        self.pending = config.data_dir / "uploads"
        self.root.mkdir(exist_ok=True)
        self.pending.mkdir(exist_ok=True)
        self.lock = threading.RLock()

    def object_path(self, digest: str) -> Path:
        if not re.fullmatch(r"[a-f0-9]{64}", digest):
            raise TransferError("文件指纹不完整，请重新选择文件。")
        return self.root / digest[:2] / digest

    @staticmethod
    def public(row: dict) -> dict:
        return {**row, "url": f"/api/artifacts/{row['id']}/content"}

    def get(self, artifact_id: str) -> dict | None:
        row = self.store.one("SELECT * FROM artifacts WHERE id=?", (artifact_id,))
        return self.public(row) if row else None

    def begin(self, name: str, size: int, digest: str, mime: str) -> dict:
        target = self.object_path(digest)
        if size < 0 or size > self.config.max_upload:
            raise TransferError("这份文件超过当前文件柜容量限制。")
        with self.lock, self.store.connect() as db:
            existing = db.execute("SELECT * FROM artifacts WHERE sha256=? AND size=? LIMIT 1", (digest, size)).fetchone()
            if existing and target.is_file() and target.stat().st_size == size:
                # Preserve each user's original filename even when content is shared.
                ident = uid()
                db.execute("INSERT INTO artifacts VALUES(?,?,?,?,?,?)", (ident, safe_name(name), size, mime, digest, now()))
                artifact = self.public(dict(db.execute("SELECT * FROM artifacts WHERE id=?", (ident,)).fetchone()))
                return {"id": None, "offset": size, "complete": True, "artifact": artifact}
            pending = db.execute("SELECT * FROM uploads WHERE sha256=? AND size=? AND artifact_id IS NULL ORDER BY created_at DESC LIMIT 1", (digest, size)).fetchone()
            if pending:
                row = dict(pending)
                path = self.pending / row["id"]
                source = path if path.exists() else target
                actual = source.stat().st_size if source.exists() else 0
                # A crash can occur between fsync and committing offset: disk is authoritative.
                if actual > size:
                    raise TransferError("上次传输长度不一致，请查看主机文件柜。")
                db.execute("UPDATE uploads SET offset=? WHERE id=?", (actual, row["id"]))
                return {"id": row["id"], "offset": actual, "complete": False}
            ident = uid()
            db.execute("INSERT INTO uploads VALUES(?,?,?,?,?,0,NULL,?)", (ident, safe_name(name), size, digest, mime, now()))
            (self.pending / ident).touch(exist_ok=False)
            return {"id": ident, "offset": 0, "complete": False}

    def append(self, ident: str, offset: int, content: bytes) -> dict:
        with self.lock, self.store.connect() as db:
            row = db.execute("SELECT * FROM uploads WHERE id=?", (ident,)).fetchone()
            if not row:
                raise KeyError(ident)
            if row["artifact_id"]:
                raise TransferError("这份文件已收好，无需重复传送。")
            path = self.pending / ident
            actual = path.stat().st_size if path.exists() else 0
            if offset != actual:
                raise TransferError(f"接续位置应为 {actual}，请重新读取上传进度。")
            if len(content) > self.config.chunk_size or actual + len(content) > row["size"]:
                raise TransferError("这一段文件太长，请缩小分段后继续。")
            with path.open("ab") as output:
                output.write(content)
                output.flush()
                os.fsync(output.fileno())
            new_offset = actual + len(content)
            db.execute("UPDATE uploads SET offset=? WHERE id=?", (new_offset, ident))
            return {"offset": new_offset}

    def progress(self, ident: str) -> dict:
        with self.lock, self.store.connect() as db:
            row = db.execute("SELECT * FROM uploads WHERE id=?", (ident,)).fetchone()
            if not row:
                raise KeyError(ident)
            offset = row["offset"]
            if not row["artifact_id"]:
                pending = self.pending / ident
                committed = self.object_path(row["sha256"])
                source = pending if pending.exists() else committed
                offset = source.stat().st_size if source.exists() else 0
                if offset > row["size"]:
                    raise TransferError("上次传送的长度不一致，请从头重新传送。")
                if offset != row["offset"]:
                    db.execute("UPDATE uploads SET offset=? WHERE id=?", (offset, ident))
            artifact = None
            if row["artifact_id"]:
                artifact = self.public(dict(db.execute("SELECT * FROM artifacts WHERE id=?", (row["artifact_id"],)).fetchone()))
            return {"id": ident, "offset": offset, "size": row["size"], "complete": row["artifact_id"] is not None, "artifact": artifact}

    def complete(self, ident: str) -> dict:
        with self.lock:
            row = self.store.one("SELECT * FROM uploads WHERE id=?", (ident,))
            if not row:
                raise KeyError(ident)
            if row["artifact_id"]:
                return self.get(row["artifact_id"])
            path = self.pending / ident
            target = self.object_path(row["sha256"])
            # Recover an interrupted finalize after the atomic move.
            source = path if path.exists() else target
            if not source.exists() or source.stat().st_size != row["size"]:
                raise TransferError("文件还没传完，我会保留已收到的部分。")
            with source.open("rb") as input_file:
                actual_hash = hashlib.file_digest(input_file, "sha256").hexdigest()
            if actual_hash != row["sha256"]:
                raise TransferError("这份文件的指纹没有对上，请重新选择原文件。")
            target.parent.mkdir(exist_ok=True)
            if source != target:
                if target.exists():
                    # The completed duplicate is disposable, but never permanently delete it.
                    from send2trash import send2trash
                    send2trash(str(source))
                else:
                    source.rename(target)
            artifact_id = uid()
            with self.store.connect() as db:
                db.execute("INSERT INTO artifacts VALUES(?,?,?,?,?,?)", (artifact_id, row["name"], row["size"], row["mime"], actual_hash, now()))
                db.execute("UPDATE uploads SET artifact_id=?,offset=? WHERE id=?", (artifact_id, row["size"], ident))
            return self.get(artifact_id)

    def import_file(self, path: Path) -> dict:
        size = path.stat().st_size
        with path.open("rb") as input_file:
            digest = hashlib.file_digest(input_file, "sha256").hexdigest()
        state = self.begin(path.name, size, digest, mimetypes.guess_type(path.name)[0] or "application/octet-stream")
        if state["complete"]:
            return state["artifact"]
        with path.open("rb") as input_file:
            input_file.seek(state["offset"])
            while chunk := input_file.read(self.config.chunk_size):
                state["offset"] = self.append(state["id"], state["offset"], chunk)["offset"]
        return self.complete(state["id"])

    def inspect(self, artifact: dict) -> dict:
        path = self.object_path(artifact["sha256"])
        if not zipfile.is_zipfile(path):
            return {"kind": "file", "size": artifact["size"], "extracted": False}
        # Bound directory allocation before ZipFile builds its in-memory entry table.
        with path.open("rb") as source:
            source.seek(max(0, artifact["size"] - 65557))
            tail = source.read(65557)
        marker = tail.rfind(b"PK\x05\x06")
        if marker < 0 or len(tail) - marker < 22:
            raise TransferError("这个盒子的目录没有收齐，暂不展开。")
        _, disk, directory_disk, local_count, count, directory_size, directory_offset, comment_length = struct.unpack(
            "<4s4H2LH", tail[marker:marker + 22])
        if marker + 22 + comment_length != len(tail):
            raise TransferError("这个盒子的目录边界不完整，暂不展开。")
        if (disk or directory_disk or local_count != count or count == 65535
                or directory_size == 0xFFFFFFFF or directory_offset == 0xFFFFFFFF):
            raise TransferError("原件已收好；当前目录检查尚不展开分卷或 ZIP64 总目录。")
        if count > 10000 or directory_size > 4 * 1024**2 or directory_offset + directory_size > artifact["size"]:
            raise TransferError("这个盒子的目录超过安全展开范围，原件仍可下载。")
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            if len(entries) > 10000:
                raise TransferError("这个盒子里的文件太多，暂不展开。")
            total = 0
            names = set()
            result = []
            for info in entries:
                normalized = info.filename.replace("\\", "/")
                pure = PurePosixPath(normalized)
                mode = info.external_attr >> 16
                if (pure.is_absolute() or ".." in pure.parts or ":" in normalized or "\x00" in normalized
                        or len(normalized) > 1000
                        or len(pure.parts) > 12 or stat.S_ISLNK(mode)
                        or normalized.casefold() in names):
                    raise TransferError("盒子里有越界或重叠的路径，我先替你拦下了。")
                names.add(normalized.casefold())
                total += info.file_size
                if total > 2 * 1024**3 or info.file_size / max(info.compress_size, 1) > 200:
                    raise TransferError("这个盒子展开后会异常膨胀，我先替你拦下了。")
                if info.flag_bits & 1:
                    raise TransferError("这份压缩包有密码，请先提供可读取的文件。")
                result.append({"name": normalized, "size": info.file_size, "directory": info.is_dir()})
        return {"kind": "zip", "entries": result, "expanded_size": total, "extracted": False,
                "nested_archives": "not expanded"}
