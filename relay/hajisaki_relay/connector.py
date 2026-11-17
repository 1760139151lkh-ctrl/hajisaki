from __future__ import annotations

import argparse
import asyncio
import hashlib
import logging
import random
import re
import sqlite3
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

import httpx
from websockets.exceptions import ConnectionClosed, WebSocketException
from websockets.legacy.client import connect

from .config import gateway_origin, load, local_path, tls_context, websocket_url
from .protocol import (Cipher, MAX_BODY, MAX_FRAME, MAX_INFLIGHT, ProtocolError,
                       encode_json, now_ms)

LOG = logging.getLogger("hajisaki.connector")
IDENT = r"[A-Za-z0-9_-]{1,80}"
# Explicitly excludes local-pair, internal agent deliver/progress, arbitrary paths and future APIs.
ROUTES = [
    ("GET", r"/api/(health|status|models|conversations|memories|settings|artifacts|reminders|inbox)"),
    ("POST", r"/api/(conversations|memories|uploads|reminders)"),
    ("PATCH", r"/api/settings"),
    ("POST", r"/api/settings/update"),
    ("PATCH", rf"/api/(conversations|memories|reminders)/{IDENT}"),
    ("POST", rf"/api/(conversations|memories|reminders)/{IDENT}/update"),
    ("DELETE", rf"/api/memories/{IDENT}"),
    ("GET", rf"/api/conversations/{IDENT}/(messages|events)"),
    ("POST", rf"/api/conversations/{IDENT}/(messages|fork)"),
    ('GET', rf'/api/conversations/{IDENT}/cards/{IDENT}'),
    ('POST', rf'/api/conversations/{IDENT}/cards/{IDENT}/vote'),
    ("POST", rf"/api/runs/{IDENT}/stop"),
    ("GET", rf"/api/uploads/{IDENT}"),
    ("PUT", rf"/api/uploads/{IDENT}"),
    ("POST", rf"/api/uploads/{IDENT}/(complete|restart)"),
    ("GET", rf"/api/artifacts/{IDENT}/(content|inspect|text|search|sheet|page-image|thumbnail|image-info)"),
    ("POST", rf"/api/inbox/{IDENT}/read"),
    ("GET", r"/api/speech/(status|hotwords)"),
    ("PUT", r"/api/speech/hotwords"),
    ("POST", r"/api/speech/(transcriptions|clean)"),
    ("POST", r"/api/image-studio/(preview|export)"),
    ("GET", r"/api/references/(roots|history)"),
    ("GET", rf"/api/references/roots/{IDENT}/entries"),
    ("POST", r"/api/references/snapshots"),
    ("GET", r"/api/composer/catalog"),
    ("GET", rf"/api/conversations/{IDENT}/composer"),
    ("POST", rf"/api/conversations/{IDENT}/(tone|compact)"),
    ("GET", rf"/api/messages/{IDENT}/selection"),
    ("GET", rf"/api/conversations/{IDENT}/(threads|arenas|origin)"),
    ("POST", rf"/api/conversations/{IDENT}/(threads|arenas)"),
    ("GET", rf"/api/arenas/{IDENT}"),
    ("POST", rf"/api/arenas/{IDENT}/(resume|reveal|vote|stop)"),
    ("GET", rf"/api/speech/transcriptions/{IDENT}"),
    ("POST", rf"/api/speech/transcriptions/{IDENT}/stop"),
]
ROUTES = [(method, re.compile(path)) for method, path in ROUTES]
REQUEST_HEADERS = {"authorization", "x-haji-device", "x-haji-features", "x-haji-platform", "content-type", "range", "if-range"}
RESPONSE_HEADERS = {"content-type", "content-range", "content-disposition", "etag", "accept-ranges"}
QUERY_KEYS = {"q", "group", "after", "offset", "limit", "page", "unread", "sheet", "width", "path"}
READ_RESERVE = 64 * 1024
ARTIFACT_CONTENT = re.compile(rf"/api/artifacts/{IDENT}/content")
STRONG_ARTIFACT_ETAG = re.compile(r'"[0-9a-f]{64}"')


class RequestRejected(ValueError):
    def __init__(self, status: int, code: str):
        self.status, self.code = status, code
        super().__init__(code)


def validate_request(meta: dict, body: bytes) -> tuple[str, str, dict[str, str]]:
    if set(meta) != {"method", "path", "headers"}:
        raise RequestRejected(400, "invalid_request_metadata")
    method, target, headers = meta["method"], meta["path"], meta["headers"]
    if not isinstance(method, str) or not isinstance(target, str) or len(target) > 4096:
        raise RequestRejected(400, "invalid_request_target")
    if any(ord(char) < 32 or ord(char) == 127 for char in target) or "\\" in target:
        raise RequestRejected(400, "invalid_request_target")
    try:
        target.encode("utf-8", errors="strict")
        parts = urlsplit(target)
    except (ValueError, UnicodeError) as exc:
        raise RequestRejected(400, "invalid_request_target") from exc
    if parts.scheme or parts.netloc or parts.fragment or "%" in parts.path or "//" in parts.path:
        raise RequestRejected(403, "route_not_allowed")
    if not any(method == verb and pattern.fullmatch(parts.path) for verb, pattern in ROUTES):
        raise RequestRejected(403, "route_not_allowed")
    try:
        query = parse_qsl(parts.query, keep_blank_values=True, strict_parsing=True,
                          encoding="utf-8", errors="strict", max_num_fields=8)
    except ValueError as exc:
        raise RequestRejected(400, "invalid_query") from exc
    if any(key not in QUERY_KEYS for key, _ in query) or len({key for key, _ in query}) != len(query):
        raise RequestRejected(400, "query_not_allowed")
    if not isinstance(headers, dict) or len(headers) > len(REQUEST_HEADERS):
        raise RequestRejected(400, "invalid_headers")
    normalized = {}
    for name, value in headers.items():
        if (not isinstance(name, str) or not isinstance(value, str) or name.lower() not in REQUEST_HEADERS
                or name.lower() in normalized or len(value) > 4096 or not value.isascii()
                or any(ord(char) < 32 or ord(char) == 127 for char in value)):
            raise RequestRejected(400, "header_not_allowed")
        normalized[name.lower()] = value
    if (not normalized.get("authorization", "").startswith("Bearer ")
            or not normalized.get("x-haji-device")):
        raise RequestRejected(401, "gateway_pairing_required")
    if method in {"GET", "DELETE"} and body:
        raise RequestRejected(400, "body_not_allowed")
    uploading = method == "PUT" and re.fullmatch(rf"/api/uploads/{IDENT}", parts.path)
    if not uploading and len(body) > 2 * 1024 * 1024:
        raise RequestRejected(413, "request_too_large")
    if len(body) > MAX_BODY:
        raise RequestRejected(413, "upload_chunk_too_large")
    downloading = bool(ARTIFACT_CONTENT.fullmatch(parts.path))
    if downloading:
        match = re.fullmatch(r"bytes=(0|[1-9][0-9]{0,18})-(0|[1-9][0-9]{0,18})", normalized.get("range", ""))
        if not match or not 0 < int(match[2]) - int(match[1]) + 1 <= MAX_BODY:
            raise RequestRejected(400, "bounded_single_range_required")
        if "if-range" in normalized and not STRONG_ARTIFACT_ETAG.fullmatch(normalized["if-range"]):
            raise RequestRejected(400, "strong_artifact_etag_required")
    elif "range" in normalized or "if-range" in normalized:
        raise RequestRejected(400, "range_only_for_artifacts")
    return method, target, normalized


class Journal:
    """Durable mutation receipts and immutable-range anchors; ordinary GETs never accumulate."""
    def __init__(self, path: Path, limit_bytes: int = 512 * 1024 * 1024):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("""CREATE TABLE IF NOT EXISTS requests (
            id TEXT PRIMARY KEY, digest TEXT NOT NULL, created_ms INTEGER NOT NULL,
            state TEXT NOT NULL, response BLOB)""")
        columns = {row[1] for row in self.db.execute("PRAGMA table_info(requests)")}
        for name in ("read_etag", "read_hash"):
            if name not in columns:
                self.db.execute(f"ALTER TABLE requests ADD COLUMN {name} TEXT")
        self.db.commit()
        self.limit_bytes = limit_bytes

    def known_digest(self, request_id: str) -> str | None:
        row = self.db.execute("SELECT digest FROM requests WHERE id=?", (request_id,)).fetchone()
        return row[0] if row else None

    def reserve(self, request_id: str, digest: str, read_only: bool = False) -> tuple[str, bytes | None]:
        row = self.db.execute("SELECT digest,state,response FROM requests WHERE id=?", (request_id,)).fetchone()
        if row:
            return ("conflict", None) if row[0] != digest else (row[1], row[2])
        pages = self.db.execute("PRAGMA page_count").fetchone()[0]
        page_size = self.db.execute("PRAGMA page_size").fetchone()[0]
        pending = self.db.execute("SELECT count(*) FROM requests WHERE state='pending'").fetchone()[0]
        reads = self.db.execute("SELECT count(*) FROM requests WHERE state='read_pending'").fetchone()[0]
        reservation = READ_RESERVE if read_only else MAX_FRAME
        if pages * page_size + pending * MAX_FRAME + reads * READ_RESERVE + reservation > self.limit_bytes:
            return "full", None
        self.db.execute("INSERT INTO requests(id,digest,created_ms,state) VALUES(?,?,?,?)",
                        (request_id, digest, now_ms(), "read_pending" if read_only else "pending"))
        self.db.commit()  # Commit before any HTTP effect; never re-forward an interrupted claim.
        return "new", None

    def finish(self, request_id: str, response: bytes):
        self.db.execute("UPDATE requests SET state='complete',response=? WHERE id=?", (response, request_id))
        self.db.commit()

    def read_anchor(self, request_id: str) -> tuple[str | None, str | None]:
        row = self.db.execute("SELECT read_etag,read_hash FROM requests WHERE id=?", (request_id,)).fetchone()
        return row[0], row[1]

    def pin_read(self, request_id: str, etag: str):
        current, _ = self.read_anchor(request_id)
        if current and current != etag:
            raise RequestRejected(409, "artifact_representation_changed")
        if current is None:
            self.db.execute("UPDATE requests SET read_etag=? WHERE id=?", (etag, request_id))
            self.db.commit()  # Pin identity before reading/delivering any response body.

    def finish_read(self, request_id: str, receipt: bytes, body_hash: str):
        self.db.execute("UPDATE requests SET state='read_complete',response=?,read_hash=? WHERE id=?",
                        (receipt, body_hash, request_id))
        self.db.commit()

    def close(self):
        self.db.close()


class Connector:
    def __init__(self, config: dict):
        self.config = config
        self.cipher = Cipher(config["channel"], config["master_key"])
        self.origin = gateway_origin(config)
        self.journal = Journal(local_path(config, "journal", "requests.sqlite3"))
        self.active: dict[str, tuple[str, asyncio.Task]] = {}
        self.http = httpx.AsyncClient(trust_env=False, follow_redirects=False,
                                      headers={"Accept-Encoding": "identity"},
                                      timeout=httpx.Timeout(30, connect=3),
                                      limits=httpx.Limits(max_connections=MAX_INFLIGHT, max_keepalive_connections=4))

    def error(self, request_id: str, digest: str, status: int, code: str, uncertain: bool = False) -> bytes:
        return self.cipher.seal("response", request_id,
                                {"status": status, "headers": {"content-type": "application/json"},
                                 "request_digest": digest, "outcome_uncertain": uncertain},
                                encode_json({"transport_error": code}))

    async def forward(self, meta: dict, body: bytes, read_id: str | None = None) -> tuple[dict, bytes]:
        method, target, headers = validate_request(meta, body)
        pinned_etag, saved_hash = self.journal.read_anchor(read_id) if read_id else (None, None)
        if pinned_etag:
            headers["if-range"] = pinned_etag
        async with self.http.stream(method, self.origin + target, headers=headers, content=body) as response:
            # Redirects are never followed. A bounded artifact range must remain a partial response.
            if 300 <= response.status_code < 400:
                raise RequestRejected(502, "gateway_redirect_refused")
            if "range" in headers and response.status_code == 200:
                raise RequestRejected(409 if "if-range" in headers else 502,
                                      "artifact_representation_changed" if "if-range" in headers else "gateway_ignored_range")
            range_length = None
            if read_id and response.status_code == 206:
                etag = response.headers.get("etag", "")
                interval = re.fullmatch(r"bytes ([0-9]+)-([0-9]+)/([0-9]+)", response.headers.get("content-range", ""))
                requested = re.fullmatch(r"bytes=([0-9]+)-([0-9]+)", headers["range"])
                if not STRONG_ARTIFACT_ETAG.fullmatch(etag) or not interval:
                    raise RequestRejected(502, "immutable_artifact_identity_required")
                start, end, total = map(int, interval.groups())
                if (start != int(requested[1]) or end != min(int(requested[2]), total - 1)
                        or not 0 <= start <= end < total):
                    raise RequestRejected(502, "artifact_range_mismatch")
                if headers.get("if-range") and headers["if-range"] != etag:
                    raise RequestRejected(409, "artifact_representation_changed")
                self.journal.pin_read(read_id, etag)
                range_length = end - start + 1
            elif read_id and pinned_etag:
                raise RequestRejected(409, "anchored_artifact_unavailable")
            if response.headers.get("content-encoding", "identity") != "identity":
                raise RequestRejected(502, "encoded_response_refused")
            try:
                declared = int(response.headers.get("content-length", "0"))
            except ValueError as exc:
                raise RequestRejected(502, "invalid_response_length") from exc
            if declared > MAX_BODY:
                raise RequestRejected(413, "response_requires_smaller_page")
            chunks, length = [], 0
            async for chunk in response.aiter_raw():
                length += len(chunk)
                if length > MAX_BODY:
                    raise RequestRejected(413, "response_requires_smaller_page")
                chunks.append(chunk)
            payload = b"".join(chunks)
            if range_length is not None and range_length != length:
                raise RequestRejected(502, "artifact_range_length_mismatch")
            if saved_hash and hashlib.sha256(payload).hexdigest() != saved_hash:
                raise RequestRejected(409, "artifact_content_changed")
            if read_id and response.status_code != 206 and length > 8192:
                raise RequestRejected(502, "artifact_error_response_too_large")
            safe_headers = {name: value for name, value in response.headers.items()
                            if name in RESPONSE_HEADERS and len(value) <= 4096}
            return {"status": response.status_code, "headers": safe_headers, "outcome_uncertain": False}, payload

    async def send(self, websocket, frame: bytes):
        try:
            await asyncio.wait_for(websocket.send(frame), 10)
        except (ConnectionClosed, TimeoutError):
            # Durable response can be fetched by resending the exact original request.
            pass

    def renew_response(self, frame: bytes) -> bytes:
        header, metadata, body, _ = self.cipher.open(frame, "response", allow_expired=True)
        return self.cipher.seal("response", header.request_id, metadata, body)

    async def revalidate_cached_access(self, headers: dict[str, str]) -> None:
        # A transport receipt is not a perpetual authorization grant. Ask the live gateway
        # on every delivery, using only the credentials inside this authenticated request.
        # Do not read or retain the status body, and never cache the authorization result.
        probe_headers = {name: headers[name] for name in ("authorization", "x-haji-device")}
        try:
            async with asyncio.timeout(5):
                async with self.http.stream("GET", self.origin + "/api/status", headers=probe_headers) as response:
                    if response.status_code in {401, 403}:
                        raise RequestRejected(response.status_code, "gateway_access_revoked_or_invalid")
                    if response.status_code != 200:
                        raise RequestRejected(503, "gateway_authentication_unavailable")
        except (httpx.HTTPError, OSError, TimeoutError):
            raise RequestRejected(503, "gateway_authentication_unavailable") from None

    async def handle(self, websocket, request_id: str, meta: dict, body: bytes, digest: str):
        try:
            method, target, headers = validate_request(meta, body)
        except RequestRejected as exc:
            await self.send(websocket, self.error(request_id, digest, exc.status, exc.code))
            return
        read_only = method == "GET" and bool(ARTIFACT_CONTENT.fullmatch(urlsplit(target).path))
        fresh_read = method == "GET" and not read_only
        if fresh_read:
            # Polls are current-state reads, not execution receipts. Keep old records intact,
            # and refuse collisions with a previously recorded mutation/range identity.
            known = self.journal.known_digest(request_id)
            if known is not None and known != digest:
                await self.send(websocket, self.error(request_id, digest, 409,
                                                     "request_id_reused_with_different_content"))
                return
            state, cached = "fresh_read", None
        else:
            state, cached = self.journal.reserve(request_id, digest, read_only)
        if state == "complete":
            try:
                await self.revalidate_cached_access(headers)
            except RequestRejected as exc:
                await self.send(websocket, self.error(request_id, digest, exc.status, exc.code, method != "GET"))
                return  # Preserve the original receipt; never re-forward this mutation.
            await self.send(websocket, self.renew_response(cached))
            return
        if state not in {"new", "read_pending", "read_complete", "fresh_read"}:
            code = {"conflict": "request_id_reused_with_different_content", "pending": "prior_outcome_requires_reconciliation",
                    "full": "journal_capacity_reached"}[state]
            await self.send(websocket, self.error(request_id, digest, 507 if state == "full" else 409, code, state == "pending"))
            return
        try:
            async with asyncio.timeout(30):
                metadata, payload = await self.forward(meta, body, request_id if read_only else None)
            metadata["request_digest"] = digest
            if state == "read_complete":
                _, saved_metadata, _, _ = self.cipher.open(cached, "response", allow_expired=True)
                metadata = saved_metadata  # Preserve the original authenticated response headers/status.
            encrypted = self.cipher.seal("response", request_id, metadata, payload)
            if read_only and metadata["status"] == 206:
                receipt = self.cipher.seal("response", request_id, metadata)
                self.journal.finish_read(request_id, receipt, hashlib.sha256(payload).hexdigest())
            elif read_only:
                self.journal.finish(request_id, encrypted)
        except RequestRejected as exc:
            encrypted = self.error(request_id, digest, exc.status, exc.code, meta["method"] not in {"GET"})
        except (httpx.HTTPError, TimeoutError):
            encrypted = self.error(request_id, digest, 504, "gateway_result_unavailable", meta["method"] != "GET")
        except (OSError, ProtocolError):
            encrypted = self.error(request_id, digest, 502, "gateway_result_unavailable", meta["method"] != "GET")
        if not read_only and not fresh_read:
            self.journal.finish(request_id, encrypted)  # Durable mutation outcome before delivery.
        # A failed read keeps its identity pin/receipt and can safely retry; no mutation is repeated.
        await self.send(websocket, encrypted)

    async def connection(self, websocket):
        async for frame in websocket:
            if isinstance(frame, str):
                continue  # Relay status is neither authenticated content nor an execution command.
            try:
                header, meta, body, digest = self.cipher.open(frame, "request")
            except ProtocolError:
                LOG.warning("Rejected unauthenticated or expired request")
                continue
            existing = self.active.get(header.request_id)
            if existing:
                if existing[0] != digest:
                    await self.send(websocket, self.error(header.request_id, digest, 409, "request_id_reused_with_different_content"))
                else:
                    # A reconnect may arrive while the original HTTP call still owns the claim.
                    # Await that existing task, then deliver its durable result on this connection.
                    try:
                        await asyncio.shield(existing[1])
                    except Exception:
                        pass
                    await self.handle(websocket, header.request_id, meta, body, digest)
                continue
            if len(self.active) >= MAX_INFLIGHT:
                await self.send(websocket, self.error(header.request_id, digest, 429, "host_busy"))
                continue
            task = asyncio.create_task(self.handle(websocket, header.request_id, meta, body, digest))
            self.active[header.request_id] = (digest, task)
            task.add_done_callback(lambda done, key=header.request_id: self.task_done(key, done))

    def task_done(self, key: str, task: asyncio.Task):
        self.active.pop(key, None)
        if not task.cancelled() and task.exception() is not None:
            # Do not print exceptions containing URLs, credentials, bodies or local paths.
            LOG.error("Request processing interrupted; durable claim retained")

    async def run(self):
        delay = 1.0
        try:
            while True:
                try:
                    async with connect(websocket_url(self.config), ssl=tls_context(self.config),
                                       extra_headers={"Authorization": "Bearer " + self.config["channel_token"]},
                                       max_size=MAX_FRAME, max_queue=2, compression=None,
                                       ping_interval=15, ping_timeout=20, close_timeout=5, open_timeout=10) as websocket:
                        LOG.info("Outbound host channel connected, mode=%s", self.config["mode"])
                        delay = 1.0
                        await self.connection(websocket)
                except (OSError, WebSocketException, TimeoutError):
                    LOG.warning("Outbound host channel unavailable; retrying")
                await asyncio.sleep(delay + random.uniform(0, .3))
                delay = min(delay * 2, 15)
        finally:
            if self.active:
                await asyncio.gather(*(entry[1] for entry in self.active.values()), return_exceptions=True)
            await self.http.aclose()
            self.journal.close()


def main():
    parser = argparse.ArgumentParser(description="Windows outbound encrypted HajiSaki connector")
    parser.add_argument("--config", required=True)
    parser.add_argument("--development", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    logging.getLogger("websockets").setLevel(logging.WARNING)
    logging.getLogger("httpx").setLevel(logging.WARNING)
    try:
        asyncio.run(Connector(load(args.config, "host", args.development)).run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
