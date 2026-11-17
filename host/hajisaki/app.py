from __future__ import annotations

import asyncio
import ipaddress
import json
import os
import shutil
import socket
import time
import zipfile
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal
from urllib.parse import urlsplit

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ConfigDict, Field
from starlette.exceptions import HTTPException as StarletteHTTPException

from .artifacts import Artifacts, TransferError
from .config import Config, PROJECT_ROOT
from .provider import Runner
from .documents import Documents
from .reminders import Reminders
from .speech_routes import build_speech_router
from .local_identity import same_windows_user
from .context import Context
from .composer import ToneId, COMPACTION_REQUEST
from .devices import DeviceRegistry, DevicePrincipal
from .maintenance import QuietMaintenance
from .media import MediaSessions
from .agent_tools import AgentTools
from .image_studio import ImageStudio
from .references import References
from .branches import Branches
from .cards import Cards
from .store import Store, encoded, now, uid


config = Config.load()
store = Store(config.data_dir / "hajisaki.sqlite3")
artifacts = Artifacts(config, store)
documents = Documents(artifacts)
image_studio = ImageStudio(artifacts)
references = References(artifacts,store)
context = Context(store, config.data_dir)
devices = DeviceRegistry(store, config.token, config.device)
cards = Cards(store, artifacts)
media_sessions = MediaSessions(artifacts, devices)
agent_tools = AgentTools(config, store, artifacts, documents, image_studio)
runner = Runner(config, store, artifacts, context, agent_tools)
branches = Branches(store, runner, context)
runner.branches = branches
reminders = Reminders(store)
maintenance = QuietMaintenance(config.data_dir, PROJECT_ROOT)
stream_waiters: set[asyncio.Event] = set()


def wake_streams() -> None:
    for waiter in tuple(stream_waiters):
        waiter.set()


@asynccontextmanager
async def lifespan(_: FastAPI):
    loop = asyncio.get_running_loop()
    store.on_commit = lambda: loop.call_soon_threadsafe(wake_streams)
    store.recover()
    context.reconcile_native()
    reminders.start()
    await speech_manager.start()
    await maintenance.start()
    yield
    await reminders.close()
    await speech_manager.close()
    await maintenance.close()
    await runner.close()
    store.on_commit = None


app = FastAPI(title="HajiSaki", version="0.1.0", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


class Body(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ConversationCreate(Body):
    title: str = Field(default="新的乐章", min_length=1, max_length=160)
    group: str = Field(default="专属日常", max_length=40)


class ConversationPatch(Body):
    title: str | None = Field(default=None, min_length=1, max_length=160)
    group: str | None = Field(default=None, max_length=40)
    pinned: bool | None = None
    archived: bool | None = None


class MessageCreate(Body):
    content: str = Field(max_length=500000)
    client_id: str = Field(min_length=1, max_length=128)
    model: str = Field(default="default", max_length=160)
    effort: Literal["low", "medium", "high", "xhigh", "max"] = "medium"
    attachments: list[str] = Field(default_factory=list, max_length=100)
    tone_id: ToneId | None = None


class CompactCreate(Body):
    operation_id: str = Field(min_length=1,max_length=100,pattern=r'^[A-Za-z0-9_-]+$')
    model: str = Field(default='default',max_length=160)
    effort: Literal['low','medium','high','xhigh','max'] = 'medium'


class Fork(Body):
    message_id: str
    title: str | None = Field(default=None, min_length=1, max_length=160)


class Memory(Body):
    content: str = Field(min_length=1, max_length=20000)


class Personality(Body):
    formality: int = Field(default=65, ge=0, le=100)
    detail: int = Field(default=50, ge=0, le=100)
    teasing: int = Field(default=25, ge=0, le=100)


class Settings(Body):
    theme: Literal["auto", "night", "day"] | None = None
    transparency: Literal["companion", "balanced", "studio"] | None = None
    personality: Personality | None = None
    sound: bool | None = None


class Upload(Body):
    name: str = Field(min_length=1, max_length=1000)
    size: int = Field(ge=0)
    sha256: str = Field(pattern=r"^[a-fA-F0-9]{64}$")
    mime: str = Field(default="application/octet-stream", max_length=200,
                      pattern=r"^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*$")


class Delivery(Body):
    path: str = Field(min_length=1, max_length=1000)
    kind: Literal["file", "image", "interactive"] = "file"


class Progress(Body):
    text: str = Field(min_length=1, max_length=1000)


def refuse(code: int, message: str):
    raise HTTPException(code, message)


async def authenticate(request: Request) -> DevicePrincipal:
    supplied = request.headers.get("authorization", "")
    device = request.headers.get("x-haji-device", "")
    scheme, separator, token = supplied.partition(" ")
    if not separator or scheme.lower() != "bearer":
        refuse(401, "还没有认出这台设备，请先与主机配对。")
    principal = devices.authenticate(token, device)
    request.state.device = principal
    return principal


app.include_router(reminders.router(authenticate))
app.include_router(context.router(authenticate))
app.include_router(devices.router(authenticate))
app.include_router(media_sessions.router(authenticate))
app.include_router(image_studio.router(authenticate))
app.include_router(references.router(authenticate))
app.include_router(agent_tools.router())
app.include_router(cards.router(authenticate))
speech_router, speech_manager = build_speech_router(config, artifacts, authenticate)
app.include_router(speech_router)


@app.middleware("http")
async def security(request: Request, call_next):
    host = urlsplit("//" + request.headers.get("host", "")).hostname
    allowed = {"localhost", "127.0.0.1", "::1"}
    allowed.update(value.strip() for value in os.environ.get("HAJI_ALLOWED_HOSTS", "").split(",") if value.strip())
    if host not in allowed:
        return JSONResponse({"detail": "这条入口尚未配对。"}, status_code=400)
    if request.method in {"POST", "PATCH", "PUT"}:
        limit = config.chunk_size if request.url.path.startswith("/api/uploads/") else 2 * 1024**2
        parts = []
        length = 0
        async for part in request.stream():
            length += len(part)
            if length > limit:
                return JSONResponse({"detail": "这一段内容太长，请分段送来。"}, status_code=413)
            parts.append(part)
        request._body = b"".join(parts)
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Permissions-Policy"] = "geolocation=(), camera=(self), microphone=(self)"
    if request.url.path == "/render-frame.html":
        response.headers["X-Frame-Options"] = "SAMEORIGIN"
        response.headers["Content-Security-Policy"] = "frame-ancestors 'self'"
    else:
        response.headers["X-Frame-Options"] = "DENY"
        if request.url.path in {"/", "/index.html"}:
            response.headers["Content-Security-Policy"] = "frame-src blob:; object-src 'none'"
    if request.url.path.startswith("/api/"):
        response.headers["Cache-Control"] = "no-store"
    return response


@app.exception_handler(RequestValidationError)
async def invalid_input(_: Request, __: RequestValidationError):
    return JSONResponse({"detail": "这一页有一项还没填妥，请检查后再送来。"}, status_code=422)


@app.exception_handler(StarletteHTTPException)
async def http_error(_: Request, exc: StarletteHTTPException):
    detail = exc.detail
    if detail in {"Not Found", "Method Not Allowed"}:
        detail = "这条小路暂时没有通向琴房，请回到上一页。"
    return JSONResponse({"detail": detail}, status_code=exc.status_code, headers=exc.headers)


@app.exception_handler(Exception)
async def unexpected_error(_: Request, exc: Exception):
    diagnostics = config.data_dir / "diagnostics"
    diagnostics.mkdir(exist_ok=True)
    (diagnostics / f"gateway-{uid()}.txt").write_text(f"{type(exc).__name__}: {exc}", encoding="utf-8")
    return JSONResponse({"detail": "琴房里有一页暂时没有接好，请稍后再来。已保存的文字仍在原处。"}, status_code=500)


@app.exception_handler(TransferError)
async def transfer_error(_: Request, exc: TransferError):
    return JSONResponse({"detail": str(exc)}, status_code=409)


@app.exception_handler(KeyError)
async def missing(_: Request, __: KeyError):
    return JSONResponse({"detail": "这份记录暂时没有找到。"}, status_code=404)


def conversation(ident: str) -> dict:
    row = store.one("SELECT * FROM conversations WHERE id=?", (ident,))
    if row is None:
        refuse(404, "这一页还没有收进琴房。")
    return row


def create_conversation(title: str, group: str) -> dict:
    ident, stamp = uid(), now()
    with store.connect() as db:
        db.execute("INSERT INTO conversations VALUES(?,?,?,0,0,?,?,NULL)", (ident, title, group, stamp, stamp))
    return Store.conversation(conversation(ident))


@app.get("/api/health")
async def health():
    return {"status": "ok", "service": "hajisaki"}


@app.post("/api/local-pair")
async def local_pair(request: Request):
    try:
        loopback = request.client and ipaddress.ip_address(request.client.host).is_loopback
    except ValueError:
        loopback = False
    origin = request.headers.get("origin", "")
    pairing_host = urlsplit("//" + request.headers.get("host", "")).hostname
    try:
        consent = await request.json()
    except ValueError:
        consent = None
    if (not loopback or pairing_host not in {"localhost", "127.0.0.1", "::1"}
            or origin != str(request.base_url).rstrip("/")
            or request.headers.get("sec-fetch-site", "same-origin") != "same-origin"
            or any(name == "forwarded" or name.startswith("x-forwarded-") for name in request.headers)
            or consent != {"consent": True}):
        refuse(403, "请在这台电脑的琴房页面确认连接。")
    owner = await asyncio.to_thread(same_windows_user, request.client.host, request.client.port,
                                   request.url.port or (443 if request.url.scheme == "https" else 80))
    if not owner:
        refuse(403, "请使用运行琴房的 Windows 账户连接，或手动输入私有配对口令。")
    return devices.issue_browser()


@app.get("/api/status", dependencies=[Depends(authenticate)])
async def status():
    usage = shutil.disk_usage(config.data_dir)
    proxy_reachable = None
    if config.proxy_url:
        proxy_parts = urlsplit(config.proxy_url)
        try:
            connection = await asyncio.to_thread(socket.create_connection, (proxy_parts.hostname, proxy_parts.port), 0.5)
            connection.close()
            proxy_reachable = True
        except OSError:
            proxy_reachable = False
    return {"provider": runner.status(), "host": {
        "uptime_seconds": round(time.monotonic() - runner.started, 1),
        "active_runs": len(runner.tasks), "free_bytes": usage.free,
        "database_bytes": store.path.stat().st_size,
        "proxy_configured": bool(config.proxy_url), "proxy_reachable": proxy_reachable,
        "proxy_egress_verified": False,
        "binding": "loopback by default", "time": now(),
    }, "reminders": reminders.status(), "maintenance": maintenance.status(), "capabilities": {"durable_replay": True, "resumable_uploads": True, "max_upload_bytes": config.max_upload,
        "chunk_size": config.chunk_size, "native_live_view": False, "biometric_approval": False,
        "host_file_mutation": False, "raw_audio_model_input": False, "dual_tunnel": False,
        "native_cli_harness": config.provider != 'development',
        "native_cli_tools": config.provider != 'development',
        "native_cli_permissions": ('turbo' if config.turbo else 'inherited') if config.provider != 'development' else None,
        "turbo": config.turbo and config.provider != 'development',
        "app_host_file_mutation_api": False,
        "provider_images": config.provider == "acp", "attachment_text_excerpts": True, "artifact_delivery_api": True,
        "image_editing_api": True,
        "image_preview_api": True, "agent_image_read": config.provider == "acp",
        "host_code_references": True, "historical_references": True,
        "composer_templates": True, "conversation_tones": True, "context_compaction": config.provider!='development',
        "conversation_threads": True, "arena_comparison": config.provider!='development',
        "agent_delivery_tools_enabled": config.provider == "acp", "offline_client": "client-dependent",
        **{key:bool(value and config.provider=="acp") for key,value in agent_tools.exports.capabilities().items()}}}


@app.get("/api/models", dependencies=[Depends(authenticate)])
async def models():
    return {"models": runner.models()}


@app.get("/api/conversations", dependencies=[Depends(authenticate)])
async def conversations(q: str = "", group: str = "", archived: bool = False):
    conditions, params = ["c.archived=?"], [int(archived)]
    if group and group != "全部":
        conditions.append("c.group_name=?")
        params.append(group)
    if q:
        conditions.append("(c.title LIKE ? ESCAPE '\\' OR EXISTS(SELECT 1 FROM messages m WHERE m.conversation_id=c.id AND m.content LIKE ? ESCAPE '\\'))")
        term = "%" + q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
        params.extend([term, term])
    rows = store.all("SELECT c.*,latest.id AS preview_message_id,latest.content AS preview_content FROM conversations c LEFT JOIN messages latest ON latest.rowid=(SELECT rowid FROM messages WHERE conversation_id=c.id ORDER BY created_at DESC,rowid DESC LIMIT 1) WHERE "
                     + " AND ".join(conditions) + " ORDER BY c.pinned DESC,c.updated_at DESC", tuple(params))
    visible_rows = []
    for row in rows:
        message_id = row.pop("preview_message_id")
        content = row.pop("preview_content") or ""
        row["preview"] = store.public_content(message_id, content)[:160]
        if q and q.casefold() not in row["title"].casefold():
            matches = store.all("SELECT id,content FROM messages WHERE conversation_id=? AND content LIKE ? ESCAPE '\\'", (row["id"], term))
            if not any(q.casefold() in store.public_content(item["id"], item["content"]).casefold() for item in matches):
                continue
        visible_rows.append(row)
    origins = {row['id']:{'branch_parent_id':row['parent_id'],'branch_kind':row['kind']} for row in store.all(
        "SELECT id,parent_id,'thread' AS kind FROM conversation_threads UNION ALL SELECT s.conversation_id AS id,a.parent_id,'arena' AS kind FROM arena_sides s JOIN arenas a ON a.id=s.arena_id")}
    return {"conversations": [{**Store.conversation(row),**origins.get(row['id'],{})} for row in visible_rows]}


@app.post("/api/conversations", dependencies=[Depends(authenticate)])
async def add_conversation(body: ConversationCreate):
    return create_conversation(body.title, body.group)


@app.post("/api/conversations/{ident}/update", dependencies=[Depends(authenticate)])
@app.patch("/api/conversations/{ident}", dependencies=[Depends(authenticate)])
async def change_conversation(ident: str, body: ConversationPatch):
    conversation(ident)
    changes = body.model_dump(exclude_none=True)
    if changes:
        values = {"group_name" if k == "group" else k: v for k, v in changes.items()}
        values["updated_at"] = now()
        with store.connect() as db:
            db.execute("UPDATE conversations SET " + ",".join(f"{key}=?" for key in values) + " WHERE id=?", (*values.values(), ident))
    return Store.conversation(conversation(ident))


@app.get("/api/conversations/{ident}/messages", dependencies=[Depends(authenticate)])
async def messages(ident: str):
    conversation(ident)
    with store.connect() as db:
        db.execute("BEGIN")
        rows = db.execute("SELECT * FROM messages WHERE conversation_id=? ORDER BY created_at,rowid", (ident,)).fetchall()
        active = db.execute("SELECT id,status,assistant_message_id FROM runs WHERE conversation_id=? AND status IN ('queued','running','stopping')", (ident,)).fetchone()
        cursor = db.execute("SELECT COALESCE(MAX(seq),0) FROM events WHERE conversation_id=?", (ident,)).fetchone()[0]
    return {"messages": [store.public_message(row) for row in rows], "active_run": dict(active) if active else None, "cursor": cursor}


@app.post("/api/conversations/{ident}/messages", dependencies=[Depends(authenticate)])
async def send_message(ident: str, body: MessageCreate, request: Request):
    conversation(ident)
    if not body.content.strip() and not body.attachments:
        refuse(422, "先留下一句话，或带一份文件来吧。")
    existing = store.one("SELECT * FROM messages WHERE conversation_id=? AND client_id=?", (ident, body.client_id))
    if existing:
        prior_ids = [item["id"] for item in json.loads(existing["attachments"])]
        old_run = store.one("SELECT id,model,effort FROM runs WHERE user_message_id=?", (existing["id"],))
        if (existing["content"] != body.content or prior_ids != body.attachments
                or not old_run or old_run["model"] != body.model or old_run["effort"] != body.effort
                or (body.tone_id is not None and context.run_tone_id(old_run['id'])!=body.tone_id)):
            refuse(409, "这封信的编号已经使用过，请换一个编号再送来。")
        return {"message": Store.message(existing), "run_id": old_run["id"]}
    catalog = {model["id"]: model for model in runner.models()}
    if body.model not in catalog or (body.model != 'default' and body.effort not in catalog[body.model]["efforts"]):
        refuse(422, "这个模型或思考档位还没有接通，请重新选择。")
    attached = []
    for artifact_id in body.attachments:
        artifact = artifacts.get(artifact_id)
        if not artifact:
            refuse(404, "有一份附件还没有收齐，请先完成传送。")
        attached.append(artifact)
    with store.connect() as db:
        existing = db.execute("SELECT * FROM messages WHERE conversation_id=? AND client_id=?", (ident, body.client_id)).fetchone()
        if existing:
            old_run = db.execute("SELECT id,model,effort FROM runs WHERE user_message_id=?", (existing["id"],)).fetchone()
            if (existing["content"] != body.content or json.loads(existing["attachments"]) != attached
                    or not old_run or old_run["model"] != body.model or old_run["effort"] != body.effort
                    or (body.tone_id is not None and context.run_tone_id(old_run['id'])!=body.tone_id)):
                refuse(409, "这封信的编号已经使用过，请换一个编号再送来。")
            return {"message": Store.message(existing), "run_id": old_run["id"]}
        active = db.execute("SELECT id FROM runs WHERE conversation_id=? AND status IN ('queued','running','stopping')", (ident,)).fetchone()
        if active:
            refuse(409, "这一段还在写。你可以先停下，再接着补充。")
        user_id, assistant_id, run_id, stamp = uid(), uid(), uid(), now()
        db.execute("INSERT INTO messages VALUES(?,?,?,?,?,?,?,?)", (user_id, ident, "user", body.content, "completed", stamp, encoded(attached), body.client_id))
        db.execute("INSERT INTO messages VALUES(?,?,?,?,?,?,?,NULL)", (assistant_id, ident, "assistant", "", "queued", now(), "[]"))
        db.execute("INSERT INTO runs VALUES(?,?,?,?,?,?,?,?,NULL,NULL)", (run_id, ident, user_id, assistant_id, "queued", body.model, body.effort, stamp))
        db.execute("UPDATE conversations SET updated_at=? WHERE id=?", (stamp, ident))
        features = sorted({'artifact-links-v1', 'native-cards-v1'} &
                          {value.strip() for value in request.headers.get('x-haji-features', '')[:256].split(',')})
        platform = request.headers.get("x-haji-platform", "").strip().lower()
        platform = platform if platform in {"ipados", "harmony", "web"} else None
        store.event(db, ident, run_id, "system", "message_created", {"message_id": user_id, "assistant_message_id": assistant_id,
                                                                  "client_features": features,
                                                                  "client_platform": platform,
                                                                  "tone_id":body.tone_id or context.tone_id(ident)})
    run = store.one("SELECT * FROM runs WHERE id=?", (run_id,))
    runner.start(run)
    return {"message": Store.message(store.one("SELECT * FROM messages WHERE id=?", (user_id,))), "run_id": run_id,
            "assistant_message_id": assistant_id}


app.include_router(branches.router(authenticate,
    lambda ident, body, request: send_message(ident, MessageCreate(**body), request)))


@app.post('/api/conversations/{ident}/compact', dependencies=[Depends(authenticate)])
async def compact_context(ident: str, body: CompactCreate):
    conversation(ident)
    with store.connect() as db:
        previous = db.execute('''SELECT c.id,c.run_id,r.user_message_id,r.assistant_message_id,r.model,r.effort
            FROM context_compactions c JOIN runs r ON r.id=c.run_id
            WHERE c.conversation_id=? AND c.operation_id=?''',(ident,body.operation_id)).fetchone()
        if previous:
            if previous['model']!=body.model or previous['effort']!=body.effort:
                refuse(409,'这次整理的编号已经使用过，请重新选择。')
            return {'message':store.public_message(db.execute('SELECT * FROM messages WHERE id=?',(previous['user_message_id'],)).fetchone()),
                    'run_id':previous['run_id'],'assistant_message_id':previous['assistant_message_id'],'compaction_id':previous['id']}
        catalog = {item['id']:item for item in runner.models()}
        if body.model not in catalog or (body.model != 'default' and body.effort not in catalog[body.model]['efforts']):
            refuse(422,'这个模型或思考档位还没有接通，请重新选择。')
        if config.provider=='development':
            refuse(409,'整理上下文需要接回真实模型，当前演练不会改动上下文。')
        if db.execute("SELECT id FROM runs WHERE conversation_id=? AND status IN ('queued','running','stopping')",(ident,)).fetchone():
            refuse(409,'这一段还在写，等它写完或停笔后再整理。')
        cutoff = db.execute('SELECT id FROM messages WHERE conversation_id=? ORDER BY rowid DESC LIMIT 1',(ident,)).fetchone()
        if not cutoff or not db.execute('SELECT id FROM messages WHERE conversation_id=? AND length(trim(content))>0 LIMIT 1',(ident,)).fetchone():
            refuse(422,'这一页还没有需要整理的对话。')
        compaction_id,user_id,assistant_id,run_id,stamp = uid(),uid(),uid(),uid(),now()
        db.execute('INSERT INTO messages VALUES(?,?,?,?,?,?,?,?)',
                   (user_id,ident,'user',COMPACTION_REQUEST,'completed',stamp,'[]','compact-'+body.operation_id))
        db.execute('INSERT INTO messages VALUES(?,?,?,?,?,?,?,NULL)',(assistant_id,ident,'assistant','','queued',now(),'[]'))
        db.execute('INSERT INTO runs VALUES(?,?,?,?,?,?,?,?,NULL,NULL)',(run_id,ident,user_id,assistant_id,'queued',body.model,body.effort,stamp))
        db.execute('''INSERT INTO context_compactions(id,conversation_id,run_id,operation_id,previous_provider_id,cutoff_message_id,created_at)
            VALUES(?,?,?,?,?,?,?)''',(compaction_id,ident,run_id,body.operation_id,
                                   db.execute('SELECT provider_id FROM conversations WHERE id=?',(ident,)).fetchone()['provider_id'],cutoff['id'],stamp))
        db.execute('UPDATE conversations SET updated_at=? WHERE id=?',(stamp,ident))
        store.event(db,ident,run_id,'system','message_created',{'message_id':user_id,'assistant_message_id':assistant_id,
                    'client_features':[],'tone_id':context.tone_id(ident),'action':'compact','compaction_id':compaction_id})
    run = store.one('SELECT * FROM runs WHERE id=?',(run_id,))
    runner.start(run)
    return {'message':store.public_message(store.one('SELECT * FROM messages WHERE id=?',(user_id,))),
            'run_id':run_id,'assistant_message_id':assistant_id,'compaction_id':compaction_id}


@app.get("/api/conversations/{ident}/events", dependencies=[Depends(authenticate)])
async def events(ident: str, after: int = 0, limit: int = 500):
    conversation(ident)
    rows = store.all("SELECT * FROM events WHERE conversation_id=? AND seq>? ORDER BY seq LIMIT ?", (ident, max(0, after), min(max(1, limit), 1000)))
    rows = [store.public_event(row) for row in rows]
    return {"events": rows, "cursor": rows[-1]["seq"] if rows else max(0, after), "has_more": len(rows) == min(max(1, limit), 1000)}


@app.post("/api/runs/{ident}/stop", dependencies=[Depends(authenticate)])
async def stop(ident: str):
    run = store.one("SELECT * FROM runs WHERE id=?", (ident,))
    if not run:
        refuse(404, "这一段演奏没有找到。")
    await runner.stop(run)
    return {"status": store.one("SELECT status FROM runs WHERE id=?", (ident,))["status"]}


@app.get("/api/conversations/{ident}/stream", dependencies=[Depends(authenticate)])
async def stream(ident: str, request: Request, after: int = 0):
    conversation(ident)
    principal = request.state.device
    try:
        cursor = max(0, after, int(request.headers.get("last-event-id", "0")))
    except ValueError:
        refuse(422, "接续的页码不完整，请重新打开这一页。")

    async def generate():
        nonlocal cursor
        waiter = asyncio.Event()
        stream_waiters.add(waiter)
        try:
            yield ": connected\n\n"
            while devices.is_active(principal) and not await request.is_disconnected():
                # Clear before reading committed state: a later commit cannot be missed.
                waiter.clear()
                rows = store.all("SELECT * FROM events WHERE conversation_id=? AND seq>? ORDER BY seq LIMIT 64", (ident, cursor))
                if rows:
                    for row in rows:
                        if not devices.is_active(principal):
                            return
                        row = store.public_event(row)
                        cursor = row["seq"]
                        yield f"id: {cursor}\nevent: haji\ndata: {encoded(row)}\n\n"
                    continue
                try:
                    await asyncio.wait_for(waiter.wait(), timeout=15)
                except asyncio.TimeoutError:
                    yield ": heartbeat\n\n"
        finally:
            stream_waiters.discard(waiter)

    return StreamingResponse(generate(), media_type="text/event-stream", headers={
        "Cache-Control": "no-cache, no-store", "X-Accel-Buffering": "no", "Connection": "keep-alive",
    })


@app.post("/api/conversations/{ident}/fork", dependencies=[Depends(authenticate)])
async def fork(ident: str, body: Fork):
    original = conversation(ident)
    rows = store.all("SELECT * FROM messages WHERE conversation_id=? ORDER BY created_at,rowid", (ident,))
    endpoint = next((index for index, item in enumerate(rows) if item["id"] == body.message_id), None)
    if endpoint is None:
        refuse(404, "分岔的这一页不在当前乐章里。")
    target = create_conversation(body.title or (original["title"][:150] + " · 另一乐章"), original["group_name"])
    with store.connect() as db:
        cloned = {}
        db.execute('INSERT OR IGNORE INTO conversation_tones SELECT ?,tone_id FROM conversation_tones WHERE conversation_id=?',
                   (target['id'],ident))
        for row in rows[:endpoint + 1]:
            cloned[row["id"]] = uid()
            db.execute("INSERT INTO messages VALUES(?,?,?,?,?,?,?,NULL)", (cloned[row["id"]], target["id"], row["role"], store.public_message(row)["content"],
                       row["status"] if row["status"] not in {"queued", "streaming"} else "stopped", row["created_at"], row["attachments"]))
            db.execute("INSERT INTO message_tasks SELECT ?,item_index,checked,updated_at FROM message_tasks WHERE message_id=?",
                       (cloned[row["id"]], row["id"]))
        for pin in db.execute("SELECT * FROM context_pins WHERE conversation_id=?", (ident,)).fetchall():
            if pin["kind"] == "message" and pin["target_id"] not in cloned:
                continue
            pin_target = cloned.get(pin["target_id"]) if pin["kind"] == "message" else pin["target_id"]
            db.execute("INSERT INTO context_pins VALUES(?,?,?,?,?,?)", (uid(), target["id"], pin["kind"], pin_target, pin["content"], pin["created_at"]))
    return target


@app.get("/api/memories", dependencies=[Depends(authenticate)])
async def memories(q: str = ""):
    rows = store.all("SELECT * FROM memories ORDER BY updated_at DESC")
    return {"memories": [row for row in rows if q.casefold() in row["content"].casefold()]}


@app.post("/api/memories", dependencies=[Depends(authenticate)])
async def add_memory(body: Memory):
    ident, stamp = uid(), now()
    with store.connect() as db:
        db.execute("INSERT INTO memories VALUES(?,?,?,?)", (ident, body.content, stamp, stamp))
    return store.one("SELECT * FROM memories WHERE id=?", (ident,))


@app.post("/api/memories/{ident}/update", dependencies=[Depends(authenticate)])
@app.patch("/api/memories/{ident}", dependencies=[Depends(authenticate)])
async def change_memory(ident: str, body: Memory):
    with store.connect() as db:
        result = db.execute("UPDATE memories SET content=?,updated_at=? WHERE id=?", (body.content, now(), ident))
        if result.rowcount == 0:
            refuse(404, "这枚记忆音符没有找到。")
    return store.one("SELECT * FROM memories WHERE id=?", (ident,))


@app.delete("/api/memories/{ident}", dependencies=[Depends(authenticate)])
async def remove_memory(ident: str):
    from send2trash import send2trash
    with store.connect() as db:
        row = db.execute("SELECT * FROM memories WHERE id=?", (ident,)).fetchone()
        if not row:
            refuse(404, "这枚记忆音符没有找到。")
        # Materialize the record solely to transfer this deleted item to the OS Recycle Bin.
        deleted = config.data_dir / f"memory-{ident}-{uid()}.json"
        deleted.write_text(encoded(dict(row)), encoding="utf-8")
        try:
            send2trash(str(deleted))
        except Exception:
            refuse(503, "回收站暂时没有接住这枚音符，记忆仍保留在原处。")
        db.execute("DELETE FROM memories WHERE id=?", (ident,))
    return {"status": "recycled"}


@app.get("/api/settings", dependencies=[Depends(authenticate)])
async def settings():
    return store.settings()


@app.post("/api/settings/update", dependencies=[Depends(authenticate)])
@app.patch("/api/settings", dependencies=[Depends(authenticate)])
async def change_settings(body: Settings):
    changes = body.model_dump(exclude_none=True)
    with store.connect() as db:
        for key, value in changes.items():
            db.execute("INSERT INTO settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, encoded(value)))
    return store.settings()


@app.get("/api/artifacts", dependencies=[Depends(authenticate)])
async def all_artifacts():
    return {"artifacts": [Artifacts.public(row) for row in store.all("SELECT * FROM artifacts ORDER BY created_at DESC")]}


@app.post("/api/uploads", dependencies=[Depends(authenticate)])
async def upload(body: Upload):
    return await asyncio.to_thread(artifacts.begin, body.name, body.size, body.sha256.lower(), body.mime)


@app.put("/api/uploads/{ident}", dependencies=[Depends(authenticate)])
async def chunk(ident: str, request: Request, offset: int):
    return await asyncio.to_thread(artifacts.append, ident, offset, await request.body())


@app.post("/api/uploads/{ident}/complete", dependencies=[Depends(authenticate)])
async def finish_upload(ident: str):
    return await asyncio.to_thread(artifacts.complete, ident)


@app.get("/api/uploads/{ident}", dependencies=[Depends(authenticate)])
async def upload_progress(ident: str):
    return await asyncio.to_thread(artifacts.progress, ident)


@app.post("/api/uploads/{ident}/restart", dependencies=[Depends(authenticate)])
async def restart_upload(ident: str):
    from send2trash import send2trash
    with artifacts.lock, store.connect() as db:
        row = db.execute("SELECT * FROM uploads WHERE id=?", (ident,)).fetchone()
        if not row or row["artifact_id"]:
            refuse(409, "这份传送不能从头续写。")
        path = artifacts.pending / ident
        if path.exists():
            send2trash(str(path))
        path.touch(exist_ok=False)
        db.execute("UPDATE uploads SET offset=0 WHERE id=?", (ident,))
    return {"id": ident, "offset": 0, "complete": False}


@app.get("/api/artifacts/{ident}/content", dependencies=[Depends(authenticate)])
async def download(ident: str):
    artifact = artifacts.get(ident)
    if not artifact:
        refuse(404, "这份文件暂时没有找到。")
    path = artifacts.object_path(artifact["sha256"])
    if not path.is_file():
        refuse(404, "这份文件的原件暂时不在文件柜里。")
    return FileResponse(path, filename=artifact["name"], media_type=artifact["mime"],
                        headers={"ETag": '"' + artifact["sha256"] + '"'})


@app.get("/api/artifacts/{ident}/inspect", dependencies=[Depends(authenticate)])
async def inspect_artifact(ident: str):
    artifact = artifacts.get(ident)
    if not artifact:
        refuse(404, "这份文件暂时没有找到。")
    return await asyncio.to_thread(artifacts.inspect, artifact)


@app.get("/api/artifacts/{ident}/text", dependencies=[Depends(authenticate)])
async def artifact_text(ident: str, offset: int = 0, limit: int = 8000, page: int = 0):
    artifact = artifacts.get(ident)
    if not artifact:
        refuse(404, "这份文件暂时没有找到。")
    return await asyncio.to_thread(documents.excerpt, artifact, offset, limit, page)


@app.get("/api/artifacts/{ident}/search", dependencies=[Depends(authenticate)])
async def artifact_search(ident: str, q: str, offset: int = 0, limit: int = 20):
    artifact = artifacts.get(ident)
    if not artifact:
        refuse(404, "这份文件暂时没有找到。")
    return await asyncio.to_thread(documents.search, artifact, q, offset, limit)


@app.get('/api/artifacts/{ident}/sheet', dependencies=[Depends(authenticate)])
async def artifact_sheet(ident: str, sheet: int = 0, offset: int = 0, limit: int = 20):
    artifact = artifacts.get(ident)
    if not artifact: refuse(404,'这份工作簿暂时没有找到。')
    return await asyncio.to_thread(documents.sheet_page,artifact,sheet,offset,limit)


@app.get('/api/artifacts/{ident}/page-image', dependencies=[Depends(authenticate)])
async def artifact_page_image(ident: str, page: int = 0, width: int = 1600):
    artifact = artifacts.get(ident)
    if not artifact: refuse(404,'这份原件暂时没有找到。')
    return await asyncio.to_thread(documents.pdf_page,artifact,page,width)


@app.post("/api/runs/{ident}/deliver", dependencies=[Depends(authenticate)])
async def deliver(ident: str, body: Delivery):
    run = store.one("SELECT * FROM runs WHERE id=?", (ident,))
    if not run:
        refuse(404, "这一段演奏没有找到。")
    base = (config.data_dir / "workspaces").resolve()
    outputs = base / run["conversation_id"] / "outputs" / ident
    resolved_root = outputs.resolve()
    path = (outputs / body.path).resolve()
    if Path(body.path).is_absolute() or not resolved_root.is_relative_to(base) or not path.is_relative_to(resolved_root):
        refuse(403, "这份原件不在本次演奏的交付目录里。")
    if not path.is_file():
        refuse(404, "这份原件还没有写完，请先放进本次交付目录。")
    if body.kind == "image":
        with path.open("rb") as file:
            signature = file.read(16)
        if not (signature.startswith(b"\x89PNG\r\n\x1a\n") or signature.startswith(b"\xff\xd8\xff")
                or signature.startswith((b"GIF87a", b"GIF89a")) or signature[8:12] == b"WEBP"):
            refuse(422, "这份文件还不是可展示的图片。")
    artifact = await asyncio.to_thread(artifacts.import_file, path)
    with store.connect() as db:
        row = db.execute("SELECT attachments FROM messages WHERE id=?", (run["assistant_message_id"],)).fetchone()
        attached = json.loads(row["attachments"])
        attached.append(artifact)
        db.execute("UPDATE messages SET attachments=? WHERE id=?", (encoded(attached), run["assistant_message_id"]))
        store.event(db, run["conversation_id"], ident, "L4", "artifact", {"artifact": artifact, "kind": body.kind})
    return artifact


@app.post("/api/runs/{ident}/progress", dependencies=[Depends(authenticate)])
async def progress(ident: str, body: Progress):
    run = store.one("SELECT * FROM runs WHERE id=?", (ident,))
    if not run:
        refuse(404, "这一段演奏没有找到。")
    store.emit(run, "L3", "narration", {"text": body.text})
    return {"status": "recorded"}


@app.get("/api/diagnostics/{ident}", dependencies=[Depends(authenticate)])
async def provider_detail(ident: str):
    row = store.one("SELECT * FROM provider_diagnostics WHERE id=?", (ident,))
    if not row:
        refuse(404, "这一条主机记录暂时没有找到。")
    return row


@app.get("/api/messages/{ident}/raw", dependencies=[Depends(authenticate)])
async def raw_message(ident: str):
    row = store.one("SELECT * FROM messages WHERE id=?", (ident,))
    if not row:
        refuse(404, "这页手稿暂时没有找到。")
    return {"message": Store.message(row), "provider_diagnostics": store.all("SELECT * FROM provider_diagnostics WHERE message_id=? ORDER BY created_at", (ident,))}


def export_library() -> Path:
    folder = config.data_dir / "exports"
    folder.mkdir(exist_ok=True)
    target = folder / f"hajisaki-{uid()}.zip"
    # One consistent read transaction, then copy immutable CAS objects without holding the DB lock.
    with store.connect() as db:
        db.execute("BEGIN")
        payload = {table: [dict(row) for row in db.execute("SELECT * FROM " + table)]
                   for table in ("conversations", "messages", "runs", "events", "memories", "settings", "artifacts", "reminders", "reminder_deliveries", "context_pins", "message_tasks", "provider_diagnostics", "conversation_tones", "context_compactions", "conversation_contexts", "conversation_threads", "arenas", "arena_sides", "branch_artifacts", "card_votes")}
    with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED, allowZip64=True) as output:
        output.writestr("library.json", json.dumps(payload, ensure_ascii=False, indent=2))
        for conv in payload["conversations"]:
            text = f"# {conv['title']}\n\n"
            for item in payload["messages"]:
                if item["conversation_id"] == conv["id"]:
                    text += f"## {'你' if item['role'] == 'user' else '哈基祥'} · {item['created_at']}\n\n{item['content']}\n\n"
                    for asset in json.loads(item["attachments"]):
                        text += f"[{asset['name']}](../attachments/{asset['id']}/{asset['name']})\n\n"
            output.writestr(f"conversations/{conv['id']}.md", text)
        for artifact in payload["artifacts"]:
            source = artifacts.object_path(artifact["sha256"])
            if not source.is_file():
                raise TransferError("有一份原件暂时不在文件柜，完整导出已暂停。")
            output.write(source, f"attachments/{artifact['id']}/{artifact['name']}")
        for arcname, source in speech_manager.export_entries():
            output.write(source, arcname)
    return target


@app.get("/api/export", dependencies=[Depends(authenticate)])
async def export():
    target = await asyncio.to_thread(export_library)
    return FileResponse(target, media_type="application/zip", filename="哈基祥-记忆与原件.zip")


asset_dir = PROJECT_ROOT / "shared/assets"
if asset_dir.is_dir():
    app.mount("/artwork", StaticFiles(directory=asset_dir), name="artwork")
studio_dir = PROJECT_ROOT / "studio/dist"
if studio_dir.is_dir():
    app.mount("/", StaticFiles(directory=studio_dir, html=True), name="studio")
