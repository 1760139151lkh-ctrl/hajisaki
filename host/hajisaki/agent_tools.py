"""Run-scoped engineering tools: bounded attachment reads and new artifacts only."""
from __future__ import annotations

import asyncio
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import stat
import threading
import time
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from .artifacts import Artifacts, TransferError
from .config import Config
from .documents import Documents
from .image_studio import ImageStudio, ImageEdit
from .exports import ExportJobs, ExportError, PdfInput, SpreadsheetInput, ZipInput, MAX_PACKAGE_BYTES, MAX_EXPORT_INPUT
from .store import Store, encoded, now
from .cards import CreateCardInput, CARD_SUFFIX, MAX_CARD_BYTES


MAX_TEXT_BYTES = 1024 * 1024
MAX_OUTPUT_FILES = 64
GRANT_LIFETIME_SECONDS = 6 * 60 * 60
TEXT_EXTENSIONS = frozenset({
    ".md", ".markdown", ".txt", ".json", ".jsonl", ".csv", ".tsv", ".html", ".htm",
    ".css", ".js", ".mjs", ".ts", ".tsx", ".jsx", ".py", ".ets", ".java", ".kt",
    ".go", ".rs", ".c", ".cpp", ".h", ".hpp", ".sql", ".yaml", ".yml", ".toml", ".xml", ".svg",
})
IDENTIFIER = re.compile(r"^[0-9a-f]{32}$")
SECRET = re.compile(r"^[A-Za-z0-9_-]{64}$")


class ToolBody(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class ExcerptInput(ToolBody):
    artifact_id: str = Field(pattern=r"^[0-9a-f]{32}$")
    offset: int = Field(default=0, ge=0, le=2**63 - 1)
    page: int = Field(default=0, ge=0, le=1000000)
    limit: int = Field(default=8000, ge=4, le=32000)


class SearchInput(ToolBody):
    artifact_id: str = Field(pattern=r"^[0-9a-f]{32}$")
    query: str = Field(min_length=1, max_length=200)
    offset: int = Field(default=0, ge=0, le=2**63 - 1)
    limit: int = Field(default=20, ge=1, le=100)


class ImageReadInput(ToolBody):
    artifact_id: str = Field(pattern=r'^[0-9a-f]{32}$')
    page: int = Field(default=0, ge=0, le=1000000)


class CreateTextInput(ToolBody):
    name: str = Field(min_length=1, max_length=180)
    content: str = Field(max_length=MAX_TEXT_BYTES)


class DeliveryInput(ToolBody):
    path: str = Field(min_length=1, max_length=1000)
    kind: Literal["file", "image", "interactive"] = "file"


class ProgressInput(ToolBody):
    text: str = Field(min_length=1, max_length=1000)


@dataclass(frozen=True)
class AgentGrant:
    run_id: str
    digest: str


def denied(status: int, message: str) -> None:
    raise HTTPException(status, message)


class AgentTools:
    def __init__(self, config: Config, store: Store, artifacts: Artifacts, documents: Documents, image_studio: ImageStudio | None = None):
        self.config, self.store, self.artifacts, self.documents = config, store, artifacts, documents
        self.data_dir = config.data_dir.resolve()
        self.lock = threading.RLock()
        self.exports = ExportJobs(config.data_dir)
        self.image_studio = image_studio or ImageStudio(artifacts)
        with store.connect() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS agent_tool_grants (
                    run_id TEXT PRIMARY KEY REFERENCES runs(id), token_digest TEXT NOT NULL,
                    expires_at REAL NOT NULL, enabled INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS agent_tool_outputs (
                    run_id TEXT NOT NULL REFERENCES runs(id), name TEXT NOT NULL COLLATE NOCASE,
                    artifact_id TEXT REFERENCES artifacts(id), size INTEGER NOT NULL, created_at TEXT NOT NULL,
                    PRIMARY KEY(run_id,name)
                );
            """)

    def issue(self, run: dict, enabled: bool = False) -> dict:
        """Issue/rotate a private grant. Never serialize the return value in model logs."""
        if not isinstance(enabled, bool):
            raise ValueError("The agent grant enabled flag must be a boolean.")
        run_id = run.get("id", "")
        if not IDENTIFIER.fullmatch(run_id):
            raise ValueError("A gateway run identifier is required.")
        token = secrets.token_urlsafe(48)
        digest = hashlib.sha256(token.encode("ascii")).hexdigest()
        expires = time.time() + GRANT_LIFETIME_SECONDS
        with self.store.connect() as db:
            current = db.execute("SELECT status FROM runs WHERE id=?", (run_id,)).fetchone()
            if not current or current["status"] not in {"queued", "running"}:
                raise ValueError("Only a queued or running gateway run can receive an agent grant.")
            db.execute("""INSERT INTO agent_tool_grants VALUES(?,?,?,?,?)
                ON CONFLICT(run_id) DO UPDATE SET token_digest=excluded.token_digest,
                    expires_at=excluded.expires_at,enabled=excluded.enabled,created_at=excluded.created_at""",
                       (run_id, digest, expires, int(enabled), now()))
        return {"token": token, "run_id": run_id, "enabled": bool(enabled),
                "expires_at": datetime.fromtimestamp(expires, timezone.utc).isoformat()}

    def revoke(self, run_id: str) -> None:
        with self.store.connect() as db:
            db.execute("UPDATE agent_tool_grants SET enabled=0,expires_at=0 WHERE run_id=?", (run_id,))

    def _active(self, grant: AgentGrant, db: sqlite3.Connection | None = None) -> dict:
        query = """SELECT r.*,g.token_digest,g.expires_at,g.enabled FROM runs r
            JOIN agent_tool_grants g ON g.run_id=r.id WHERE r.id=?"""
        row = dict(db.execute(query, (grant.run_id,)).fetchone() or {}) if db else self.store.one(query, (grant.run_id,))
        if not row or not hmac.compare_digest(row["token_digest"], grant.digest):
            denied(401, "本次工具授权没有对上，请由主机重新接好。")
        if row["expires_at"] <= time.time() or row["status"] not in {"queued", "running"}:
            denied(403, "这一段演奏已经收笔，工具授权也已结束。")
        if not row["enabled"]:
            denied(403, "本次工具仍在观察阶段，还没有放行执行。")
        return row

    async def authorize(self, run_id: str, request: Request) -> AgentGrant:
        try:
            local = request.client and ipaddress.ip_address(request.client.host).is_loopback
        except ValueError:
            local = False
        supplied = request.headers.get("x-haji-agent", "")
        if not local or not IDENTIFIER.fullmatch(run_id) or not SECRET.fullmatch(supplied):
            denied(401, "这条工具入口只接受主机本次演奏的授权。")
        grant = AgentGrant(run_id, hashlib.sha256(supplied.encode("ascii")).hexdigest())
        self._active(grant)
        return grant

    @staticmethod
    async def _body(request: Request, schema: type[BaseModel], maximum: int = 8192) -> BaseModel:
        if request.headers.get("content-type", "").split(";", 1)[0].strip().lower() != "application/json":
            denied(415, "工具请求需要完整的 JSON 参数。")
        pieces, size = [], 0
        async for piece in request.stream():
            size += len(piece)
            if size > maximum:
                denied(413, "这一份工具参数太长，请缩小后再送来。")
            pieces.append(piece)
        try:
            return schema.model_validate(json.loads(b"".join(pieces)))
        except (ValueError, UnicodeError, ValidationError):
            denied(422, "工具参数有一项没有填妥，请核对后再送来。")

    def _artifact(self, grant: AgentGrant, artifact_id: str) -> tuple[dict, dict]:
        with self.store.connect() as db:
            run = self._active(grant, db)
            attached = db.execute("""SELECT 1 FROM messages m,json_each(m.attachments) a
                WHERE m.conversation_id=? AND json_extract(a.value,'$.id')=? LIMIT 1""",
                                  (run["conversation_id"], artifact_id)).fetchone()
            pinned = None
            if not attached and db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='context_pins'").fetchone():
                pinned = db.execute("SELECT 1 FROM context_pins WHERE conversation_id=? AND kind='artifact' AND target_id=? LIMIT 1",
                                    (run["conversation_id"], artifact_id)).fetchone()
            if not attached and not pinned and db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='branch_artifacts'").fetchone():
                attached = db.execute('SELECT 1 FROM branch_artifacts WHERE conversation_id=? AND artifact_id=?',
                                      (run['conversation_id'],artifact_id)).fetchone()
            if not attached and not pinned:
                denied(403, "这份原件没有交给当前乐章，暂时不能读取。")
            row = db.execute("SELECT * FROM artifacts WHERE id=?", (artifact_id,)).fetchone()
            if not row:
                denied(404, "这份原件暂时没有找到。")
        return run, Artifacts.public(dict(row))

    def _audit(self, grant: AgentGrant, name: str, summary: str, detail: dict | None = None) -> None:
        with self.store.connect() as db:
            run = self._active(grant, db)
            self.store.event(db, run["conversation_id"], run["id"], "L2", "tool", {
                "name": name, "state": "DONE", "summary": summary, "detail": detail or {},
            })

    def read_attachment_excerpt(self, grant: AgentGrant, body: ExcerptInput) -> dict:
        _, artifact = self._artifact(grant, body.artifact_id)
        result = self.documents.excerpt(artifact, body.offset, body.limit, body.page)
        self._audit(grant, "read_attachment_excerpt", "已读这一页原件" if result.get("supported") else "这份原件暂时没有展开",
                    {"artifact_id": artifact["id"], "page": body.page, "offset": body.offset,
                     "characters": len(result.get("text", "")), "supported": bool(result.get("supported"))})
        return {"artifact_id": artifact["id"], "name": artifact["name"], **result}

    def read_attachment_image(self, grant: AgentGrant, body: ImageReadInput) -> dict:
        _, artifact = self._artifact(grant,body.artifact_id)
        self._regular(self.artifacts.object_path(artifact['sha256']))
        is_pdf = self.documents.kind(artifact) == 'pdf'
        if is_pdf:
            result = self.documents.pdf_page(artifact,body.page,1600)
        elif artifact['mime'] in {'image/png','image/jpeg','image/webp'}:
            result = self.image_studio.preview(ImageEdit(source_id=artifact['id']))
        elif artifact['mime'] == 'image/gif':
            result = self.image_studio.thumbnail(artifact['id'],960)
        else:
            denied(422,'这份原件还不能作为图片展开，请按文字读取或保存原件。')
        if not result.get('supported'):
            denied(422,result.get('reason','这一张画面暂时没有展开。'))
        # This receipt records an authorized tool read of actual pixels, not a
        # claim that the model understood them or completed a visual review.
        with self.store.connect() as db:
            run = self._active(grant,db)
            payload = {'artifact':artifact,'status':'pixels_returned_by_tool','source_sha256':artifact['sha256'],
                       'width':result['width'],'height':result['height']}
            if is_pdf: payload['page'] = body.page
            if result.get('animated'): payload['animated'] = True
            self.store.event(db,run['conversation_id'],run['id'],'L4','image_tool_read',payload)
            self.store.event(db,run['conversation_id'],run['id'],'L2','tool',{
                'name':'read_attachment_image','state':'DONE',
                'summary':f'已取出第{body.page+1}页画面' if is_pdf else '已取出附件画面',
                'detail':{'artifact_id':artifact['id'],'page':body.page if is_pdf else None,
                          'width':result['width'],'height':result['height']}})
        return {'artifact_id':artifact['id'],'name':artifact['name'],'source_sha256':artifact['sha256'],
                **({'page':body.page} if is_pdf else {}), **result}

    def search_attachment_text(self, grant: AgentGrant, body: SearchInput) -> dict:
        _, artifact = self._artifact(grant, body.artifact_id)
        result = self.documents.search(artifact, body.query, body.offset, body.limit)
        self._audit(grant, "search_attachment_text", "已找过这一段文字", {
            "artifact_id": artifact["id"], "matches": len(result["matches"]), "scanned_bytes": result["scanned_bytes"],
        })
        return {"artifact_id": artifact["id"], "name": artifact["name"], **result}

    @staticmethod
    def _basename(name: str) -> str:
        if (not name or name != name.strip() or name.endswith((".", " ")) or len(name.encode("utf-8")) > 240
                or re.search(r'[\x00-\x1f<>:"/\\|?*\u202a-\u202e\u2066-\u2069]', name)
                or name in {".", ".."}):
            denied(422, "请给原件一个不含路径或特殊控制符的文件名。")
        reserved = name.split(".", 1)[0].upper()
        if reserved in {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(1, 10)), *(f"LPT{i}" for i in range(1, 10))}:
            denied(422, "这个文件名由系统保留，请换一个名字。")
        return name

    @staticmethod
    def _regular(path: Path, *, directory: bool = False) -> os.stat_result:
        metadata = path.lstat()
        if (stat.S_ISLNK(metadata.st_mode)
                or getattr(metadata, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)):
            denied(403, "交付目录不能通过链接指向别处。")
        if directory and not stat.S_ISDIR(metadata.st_mode):
            denied(403, "本次交付目录没有保持为普通文件夹。")
        if not directory and (not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1):
            denied(403, "这份原件必须是交付目录里的普通独立文件。")
        return metadata

    def output_directory(self, grant: AgentGrant) -> Path:
        """The current run's real delivery directory for native CLI file tools."""
        with self.lock:
            return self._outputs(self._active(grant))

    def _outputs(self, run: dict) -> Path:
        if not IDENTIFIER.fullmatch(run["conversation_id"]) or not IDENTIFIER.fullmatch(run["id"]):
            denied(403, "本次交付目录的编号不完整。")
        current = self.data_dir
        self._regular(current, directory=True)
        for component in ("workspaces", run["conversation_id"], "outputs", run["id"]):
            current = current / component
            current.mkdir(exist_ok=True)
            self._regular(current, directory=True)
            if current.resolve() != current or not current.resolve().is_relative_to(self.data_dir):
                denied(403, "本次交付目录越过了主机工作范围。")
        return current

    def _attach(self, grant: AgentGrant, artifact: dict, name: str, kind: str, tool_name: str, details: dict | None = None) -> dict:
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            run = self._active(grant, db)
            row = db.execute("SELECT attachments FROM messages WHERE id=?", (run["assistant_message_id"],)).fetchone()
            if not row:
                denied(409, "这一页回复已经不在原处，请从当前乐章继续。")
            attached = json.loads(row["attachments"])
            if not any(item["id"] == artifact["id"] for item in attached):
                attached.append(artifact)
                db.execute("UPDATE messages SET attachments=? WHERE id=?", (encoded(attached), run["assistant_message_id"]))
                self.store.event(db, run["conversation_id"], run["id"], "L4", "artifact", {"artifact": artifact, "kind": kind})
            db.execute("""INSERT INTO agent_tool_outputs VALUES(?,?,?,?,?) ON CONFLICT(run_id,name)
                DO UPDATE SET artifact_id=excluded.artifact_id,size=excluded.size""",
                       (run["id"], name, artifact["id"], artifact["size"], now()))
            self.store.event(db, run["conversation_id"], run["id"], "L2", "tool", {
                "name": tool_name, "state": "DONE", "summary": "原件已送到这一页",
                "detail": {"artifact_id": artifact["id"], "name": artifact["name"], "size": artifact["size"], **(details or {})},
            })
        return artifact

    def create_interactive_card(self, grant: AgentGrant, body: CreateCardInput) -> dict:
        name = self._basename(body.name)
        if not name.lower().endswith(CARD_SUFFIX):
            denied(422, '原生卡片请使用 .hajicard.json 文件名。')
        content = body.card.model_dump_json()
        if len(content.encode('utf-8')) > MAX_CARD_BYTES:
            denied(413, '这一组卡片太长，请拆成几组。')
        return self.create_text_artifact(grant, CreateTextInput(name=name, content=content), tool_name='create_interactive_card')

    def create_text_artifact(self, grant: AgentGrant, body: CreateTextInput, *, tool_name: str = 'create_text_artifact') -> dict:
        name = self._basename(body.name)
        if Path(name).suffix.lower() not in TEXT_EXTENSIONS:
            denied(422, "当前工坊只新建文字、文档和源代码原件。")
        content = body.content.encode("utf-8")
        if len(content) > MAX_TEXT_BYTES:
            denied(413, "单份新原件最多 1 MiB UTF-8 文字，请拆成几份。")
        if name.lower().endswith(CARD_SUFFIX):
            # The text tool cannot bypass the structured card contract.
            from .cards import CardDefinition
            if len(content) > MAX_CARD_BYTES:
                denied(413, '这一组卡片太长，请拆成几组。')
            try:
                CardDefinition.model_validate(json.loads(content))
            except (ValueError, UnicodeError):
                denied(422, '这张原生卡片的结构还没有填妥。')
        with self.lock:
            run = self._active(grant)
            root = self._outputs(run)
            target = root / name
            with self.store.connect() as db:
                self._active(grant, db)
                count = db.execute("SELECT COUNT(*) FROM agent_tool_outputs WHERE run_id=?", (run["id"],)).fetchone()[0]
                if count >= MAX_OUTPUT_FILES:
                    denied(409, "这一段演奏的原件已经达到 64 份，请另开一段继续。")
                if target.exists() or target.is_symlink() or db.execute("SELECT 1 FROM agent_tool_outputs WHERE run_id=? AND name=?", (run["id"], name)).fetchone():
                    denied(409, "这个名字已经有原件了，请换一个新名字；原件不会覆盖。")
                db.execute("INSERT INTO agent_tool_outputs VALUES(?,?,NULL,?,?)", (run["id"], name, len(content), now()))
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
            try:
                descriptor = os.open(target, flags, 0o600)
                with os.fdopen(descriptor, "wb") as file:
                    self._regular(target)
                    if target.resolve().parent != root:
                        denied(403, "这份原件越过了本次交付目录。")
                    file.write(content)
                    file.flush()
                    os.fsync(file.fileno())
            except FileExistsError:
                denied(409, "这个名字已经有原件了，请换一个新名字；原件不会覆盖。")
            artifact = self.artifacts.import_file(target)
            kind = 'interactive-card' if name.lower().endswith(CARD_SUFFIX) else 'interactive' if Path(name).suffix.lower() in {'.html', '.htm'} else 'file'
            return self._attach(grant, artifact, name, kind, tool_name)

    def _reserve_export(self, grant: AgentGrant, name: str, suffix: str) -> tuple[dict, Path]:
        name = self._basename(name)
        if Path(name).suffix.lower() != suffix:
            denied(422, "请使用与成品格式一致的文件扩展名。")
        with self.lock:
            run = self._active(grant)
            root = self._outputs(run)
            with self.store.connect() as db:
                self._active(grant, db)
                if db.execute("SELECT COUNT(*) FROM agent_tool_outputs WHERE run_id=?", (run["id"],)).fetchone()[0] >= MAX_OUTPUT_FILES:
                    denied(409, "这一段演奏的原件已经达到64份，请另开一段继续。")
                target = root / name
                if target.exists() or target.is_symlink() or db.execute("SELECT 1 FROM agent_tool_outputs WHERE run_id=? AND name=?", (run["id"], name)).fetchone():
                    denied(409, "这个名字已经有原件了，请换一个新名字；原件不会覆盖。")
                db.execute("INSERT INTO agent_tool_outputs VALUES(?,?,NULL,0,?)", (run["id"], name, now()))
            return run, root

    def _export(self, grant: AgentGrant, name: str, kind: str, payload: dict, tool_name: str) -> dict:
        _, root = self._reserve_export(grant, name, {"pdf":".pdf","xlsx":".xlsx","zip":".zip"}[kind])
        result = self.exports.run(kind, payload, root, lambda: self._active(grant))
        self._active(grant)
        target = root / name
        self._regular(target)
        if target.resolve().parent != root:
            denied(403, "这份成品越过了本次交付目录。")
        artifact = self.artifacts.import_file(target)
        return self._attach(grant, artifact, name, "file", tool_name, result)

    def create_pdf_artifact(self, grant: AgentGrant, body: PdfInput) -> dict:
        if not self.exports.capabilities()["pdf_export"]:
            denied(409, "主机还没有接好PDF导出依赖或中文字体，请先保留文字原件。")
        return self._export(grant, body.name, "pdf", body.model_dump(), "create_pdf_artifact")

    def create_spreadsheet_artifact(self, grant: AgentGrant, body: SpreadsheetInput) -> dict:
        if not self.exports.capabilities()["xlsx_export"]:
            denied(409, "主机还没有接好工作簿导出依赖，请先保留表格原文。")
        return self._export(grant, body.name, "xlsx", body.model_dump(), "create_spreadsheet_artifact")

    def create_zip_artifact(self, grant: AgentGrant, body: ZipInput) -> dict:
        sources, total = [], 0
        for ident in body.artifact_ids:
            _, artifact = self._artifact(grant, ident)
            if Path(artifact["name"]).suffix.lower() in {".zip",".7z",".rar",".tar",".gz",".bz2",".xz",".zst"}:
                denied(422, "归档盒暂不嵌套其他压缩包，请直接选择里面的普通原件。")
            name = self._basename(artifact["name"])
            path = self.artifacts.object_path(artifact["sha256"])
            self._regular(path)
            total += artifact["size"]
            if total > MAX_PACKAGE_BYTES:
                denied(413, "本次归档原件合计最多64MiB，请分成几个盒子。")
            sources.append({"name":name,"path":str(path),"size":artifact["size"],"sha256":artifact["sha256"]})
        counts = {}
        for source in sources: counts[source["name"].casefold()] = counts.get(source["name"].casefold(), 0) + 1
        for index, source in enumerate(sources, 1):
            if counts[source["name"].casefold()] > 1: source["name"] = f'{index:02d}/' + source["name"]
        return self._export(grant, body.name, "zip", {"name":body.name,"sources":sources}, "create_zip_artifact")

    def deliver(self, grant: AgentGrant, body: DeliveryInput) -> dict:
        with self.lock:
            run = self._active(grant)
            root = self._outputs(run)
            relative = Path(body.path)
            if (relative.is_absolute() or relative.drive or not relative.parts or len(relative.parts) > 8
                    or any(part in {".", ".."} for part in relative.parts) or "\\" in body.path and os.name != "nt"):
                denied(403, "工具只能交付本次目录内的原件。")
            target = root
            for index, component in enumerate(relative.parts):
                self._basename(component)
                target = target / component
                try:
                    self._regular(target, directory=index < len(relative.parts) - 1)
                except FileNotFoundError:
                    denied(404, "这份原件还没有放进本次交付目录。")
            if not target.resolve().is_relative_to(root):
                denied(403, "工具只能交付本次目录内的原件。")
            output_key = relative.as_posix()
            existing = self.store.one("SELECT artifact_id FROM agent_tool_outputs WHERE run_id=? AND name=?", (run["id"], output_key))
            if existing and not existing["artifact_id"]:
                denied(409, "这份原件还没有完整写好，暂时不能交付。")
            if existing:
                artifact = self.artifacts.get(existing["artifact_id"])
                if artifact:
                    return artifact
            if body.kind == "image":
                with target.open("rb") as file:
                    signature = file.read(16)
                if not (signature.startswith(b"\x89PNG\r\n\x1a\n") or signature.startswith(b"\xff\xd8\xff")
                        or signature.startswith((b"GIF87a", b"GIF89a")) or signature[:4] == b"RIFF" and signature[8:12] == b"WEBP"):
                    denied(422, "这份原件不是当前能展示的图片。")
            artifact = self.artifacts.import_file(target)
            return self._attach(grant, artifact, output_key, body.kind, "deliver_" + body.kind)

    def send_progress_note(self, grant: AgentGrant, body: ProgressInput) -> dict:
        text = body.text.strip()
        if not text:
            denied(422, "进展短句还没有写下内容。")
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            run = self._active(grant, db)
            self.store.event(db, run["conversation_id"], run["id"], "L3", "narration", {"text": text})
        return {"status": "recorded"}

    async def _invoke(self, method, grant: AgentGrant, body: BaseModel) -> dict:
        try:
            return await asyncio.to_thread(method, grant, body)
        except HTTPException:
            raise
        except TransferError as exc:
            denied(409, str(exc))
        except ExportError as exc:
            self._active(grant)
            denied(409, str(exc))
        except (OSError, UnicodeError, ValueError):
            denied(409, "这一份原件暂时没有处理好，已存在的文件仍在原处。")

    def router(self) -> APIRouter:
        router = APIRouter(prefix="/internal/agent/{run_id}", include_in_schema=False)

        @router.post("/read-attachment-excerpt")
        async def excerpt(request: Request, grant: AgentGrant = Depends(self.authorize)):
            return await self._invoke(self.read_attachment_excerpt, grant, await self._body(request, ExcerptInput))

        @router.post("/search-attachment-text")
        async def search(request: Request, grant: AgentGrant = Depends(self.authorize)):
            return await self._invoke(self.search_attachment_text, grant, await self._body(request, SearchInput))

        @router.post('/read-attachment-image')
        async def image(request: Request, grant: AgentGrant = Depends(self.authorize)):
            return await self._invoke(self.read_attachment_image,grant,await self._body(request,ImageReadInput))

        @router.post("/create-text-artifact")
        async def create(request: Request, grant: AgentGrant = Depends(self.authorize)):
            return await self._invoke(self.create_text_artifact, grant, await self._body(request, CreateTextInput, 2 * MAX_TEXT_BYTES + 8192))

        @router.post('/create-interactive-card')
        async def card(request: Request, grant: AgentGrant = Depends(self.authorize)):
            return await self._invoke(self.create_interactive_card, grant, await self._body(request, CreateCardInput, 2 * MAX_CARD_BYTES + 8192))

        @router.post("/create-pdf-artifact")
        async def pdf(request: Request, grant: AgentGrant = Depends(self.authorize)):
            return await self._invoke(self.create_pdf_artifact, grant, await self._body(request, PdfInput, 2 * MAX_EXPORT_INPUT + 8192))

        @router.post("/create-spreadsheet-artifact")
        async def spreadsheet(request: Request, grant: AgentGrant = Depends(self.authorize)):
            return await self._invoke(self.create_spreadsheet_artifact, grant, await self._body(request, SpreadsheetInput, 2 * MAX_EXPORT_INPUT + 8192))

        @router.post("/create-zip-artifact")
        async def package(request: Request, grant: AgentGrant = Depends(self.authorize)):
            return await self._invoke(self.create_zip_artifact, grant, await self._body(request, ZipInput, 2 * MAX_EXPORT_INPUT + 8192))

        @router.post("/deliver")
        async def deliver(request: Request, grant: AgentGrant = Depends(self.authorize)):
            return await self._invoke(self.deliver, grant, await self._body(request, DeliveryInput))

        @router.post("/progress")
        async def progress(request: Request, grant: AgentGrant = Depends(self.authorize)):
            return await self._invoke(self.send_progress_note, grant, await self._body(request, ProgressInput))

        return router
