from __future__ import annotations

import argparse
import asyncio
import hashlib
import hmac
import json
import logging
from dataclasses import dataclass
from http import HTTPStatus

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from starlette.requests import ClientDisconnect
import uvicorn

from websockets.exceptions import ConnectionClosed
from websockets.legacy.server import WebSocketServerProtocol, serve

from .config import allowed_origins, load, local_path, loopback, tls_context
from .protocol import MAX_FRAME, MAX_INFLIGHT, ProtocolError, inspect_frame, now_ms

LOG = logging.getLogger("hajisaki.relay")


class PeerUnavailable(ConnectionError):
    pass


@dataclass
class Pending:
    expiry: int
    result: asyncio.Future[bytes] | None = None


class Relay:
    """Single private channel; never receives the E2E key or gateway credentials."""
    def __init__(self, config: dict):
        self.config = config
        self.peers: dict[str, WebSocketServerProtocol] = {}
        self.pending: dict[str, Pending] = {}
        self.http_waiters = 0
        self.paths = {f"/v1/channels/{config['channel']}/{role}": role for role in ("host", "phone")}
        for role in ("host", "phone"):
            value = config.get(role + "_token_sha256", "")
            if len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
                raise ValueError("Relay requires SHA-256 role-token digests")

    def authorized(self, role: str | None, supplied: str) -> bool:
        if role not in {"host", "phone"} or not supplied.startswith("Bearer "):
            return False
        digest = hashlib.sha256(supplied.removeprefix("Bearer ").encode()).hexdigest()
        return hmac.compare_digest(digest, self.config[role + "_token_sha256"])

    async def authenticate(self, path, headers):
        role = self.paths.get(path)
        try:
            supplied = headers.get("Authorization", "")
        except Exception:
            supplied = ""
        if not self.authorized(role, supplied):
            return HTTPStatus.UNAUTHORIZED, [("Content-Type", "text/plain")], b"Channel authentication required.\n"
        if role in self.peers:
            return HTTPStatus.CONFLICT, [("Content-Type", "text/plain")], b"Role already connected.\n"
        return None

    def expire_pending(self):
        for request_id, item in list(self.pending.items()):
            if item.expiry < now_ms():
                self.pending.pop(request_id, None)
                if item.result is not None and not item.result.done():
                    item.result.set_exception(PeerUnavailable("request_expired"))

    @staticmethod
    def http_failure(status: int, code: str, request_id: str | None = None) -> JSONResponse:
        payload = {"transport": code}
        if request_id:
            payload["id"] = request_id
        return JSONResponse(payload, status_code=status,
                            headers={"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"})

    async def http_request(self, channel: str, request: Request) -> Response:
        if channel != self.config["channel"] or not self.authorized("phone", request.headers.get("authorization", "")):
            return self.http_failure(401, "channel_authentication_required")
        if (request.headers.get("content-type", "").split(";", 1)[0].strip().lower() != "application/octet-stream"
                or request.headers.get("content-encoding", "identity") != "identity"):
            return self.http_failure(415, "binary_frame_required")
        try:
            declared = int(request.headers.get("content-length", "0"))
        except ValueError:
            return self.http_failure(400, "invalid_content_length")
        if not 0 <= declared <= MAX_FRAME:
            return self.http_failure(413, "frame_too_large")
        if self.http_waiters >= MAX_INFLIGHT:
            return self.http_failure(429, "busy")
        self.http_waiters += 1
        deadline = asyncio.get_running_loop().time() + 45
        request_id, waiting = None, None
        try:
            buffer = bytearray()
            async with asyncio.timeout(10):
                async for chunk in request.stream():
                    if len(buffer) + len(chunk) > MAX_FRAME:
                        return self.http_failure(413, "frame_too_large")
                    buffer.extend(chunk)
            frame = bytes(buffer)
            try:
                header = inspect_frame(frame, "request")
            except ProtocolError:
                return self.http_failure(400, "invalid_transport_frame")
            request_id = header.request_id
            self.expire_pending()
            if request_id in self.pending:
                # Relay cannot decrypt to decide whether two envelopes have the same plaintext.
                return self.http_failure(409, "request_inflight", request_id)
            if len(self.pending) >= MAX_INFLIGHT:
                return self.http_failure(429, "busy", request_id)
            host = self.peers.get("host")
            if host is None:
                return self.http_failure(503, "host_offline", request_id)
            result = asyncio.get_running_loop().create_future()
            waiting = Pending(header.expires_ms, result)
            self.pending[request_id] = waiting
            async with asyncio.timeout(max(0, deadline - asyncio.get_running_loop().time())):
                await asyncio.wait_for(host.send(frame), 10)
                response = await result
            return Response(response, media_type="application/octet-stream",
                            headers={"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"})
        except TimeoutError:
            return self.http_failure(504, "transport_timeout", request_id)
        except (ConnectionClosed, PeerUnavailable, ClientDisconnect):
            return self.http_failure(503, "peer_unavailable", request_id)
        finally:
            self.http_waiters -= 1
            if request_id and waiting is not None and self.pending.get(request_id) is waiting:
                self.pending.pop(request_id, None)
            if waiting is not None and waiting.result is not None and not waiting.result.done():
                waiting.result.cancel()
            elif waiting is not None and waiting.result is not None and not waiting.result.cancelled():
                waiting.result.exception()  # Consume a peer failure even if sending failed before awaiting it.

    def http_app(self) -> FastAPI:
        app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
        app.add_api_route("/v1/channels/{channel}/request", self.http_request, methods=["POST"])
        return app

    async def control(self, peer, code: str, request_id: str | None = None):
        # This is untrusted transport status, never an authenticated API response.
        message = {"transport": code}
        if request_id:
            message["id"] = request_id
        try:
            await asyncio.wait_for(peer.send(json.dumps(message, separators=(",", ":"))), 5)
        except (ConnectionClosed, TimeoutError):
            pass

    async def handler(self, websocket):
        role = self.paths[websocket.path]
        if role in self.peers:
            await websocket.close(1008, "Role already connected")
            return
        self.peers[role] = websocket
        LOG.info("%s connected", role)
        await self.control(websocket, "connected")
        try:
            async for frame in websocket:
                try:
                    header = inspect_frame(frame, "request" if role == "phone" else "response")
                except ProtocolError:
                    await websocket.close(1008, "Invalid transport frame")
                    break
                self.expire_pending()
                other = self.peers.get("host" if role == "phone" else "phone")
                if role == "phone":
                    if other is None:
                        await self.control(websocket, "host_offline", header.request_id)
                        continue
                    if header.request_id not in self.pending and len(self.pending) >= MAX_INFLIGHT:
                        await self.control(websocket, "busy", header.request_id)
                        continue
                    existing = self.pending.get(header.request_id)
                    if existing and existing.result is not None:
                        await self.control(websocket, "busy", header.request_id)
                        continue
                    self.pending[header.request_id] = Pending(header.expires_ms)
                elif header.request_id not in self.pending:
                    continue
                elif (waiting := self.pending[header.request_id]).result is not None:
                    if not waiting.result.done():
                        waiting.result.set_result(frame)
                    self.pending.pop(header.request_id, None)
                    continue
                if other:
                    try:
                        await asyncio.wait_for(other.send(frame), 10)
                    except (ConnectionClosed, TimeoutError):
                        await self.control(websocket, "peer_unavailable", header.request_id)
                if role == "host":
                    self.pending.pop(header.request_id, None)
        except ConnectionClosed:
            pass
        finally:
            if self.peers.get(role) is websocket:
                self.peers.pop(role, None)
            if role == "phone":
                self.pending = {key: item for key, item in self.pending.items() if item.result is not None}
            else:
                phone = self.peers.get("phone")
                for request_id, item in list(self.pending.items()):
                    if item.result is not None and not item.result.done():
                        item.result.set_exception(PeerUnavailable("host_offline"))
                    elif phone is not None:
                        await self.control(phone, "host_offline", request_id)
                self.pending.clear()
            LOG.info("%s disconnected", role)


async def run(config: dict, bind: str, port: int):
    if config["mode"] == "development" and not loopback(bind):
        raise ValueError("Development relay may only bind a loopback IP")
    relay = Relay(config)
    http_port = config.get("http_port")
    if http_port is not None and (type(http_port) is not int or not 1 <= http_port <= 65535 or http_port == port):
        raise ValueError("http_port must be a distinct valid port")
    async with serve(relay.handler, bind, port, ssl=tls_context(config, server=True),
                     process_request=relay.authenticate, origins=allowed_origins(config), compression=None,
                     max_size=MAX_FRAME, max_queue=2, ping_interval=15, ping_timeout=20,
                     close_timeout=5, open_timeout=10, server_header=None):
        LOG.info("Relay ready, mode=%s, bind=%s, port=%s", config["mode"], bind, port)
        if http_port is None:
            await asyncio.Future()
        else:
            production = config["mode"] == "production"
            http_config = uvicorn.Config(relay.http_app(), host=bind, port=http_port,
                                         proxy_headers=False, server_header=False, access_log=False,
                                         log_config=None, log_level="warning", limit_concurrency=16, backlog=16,
                                         timeout_keep_alive=5, timeout_graceful_shutdown=5, ws="none",
                                         ssl_certfile=str(local_path(config, "certificate")) if production else None,
                                         ssl_keyfile=str(local_path(config, "private_key")) if production else None,
                                         ssl_context_factory=(lambda _config, _default: tls_context(config, server=True))
                                         if production else None)
            LOG.info("Opaque HTTP ingress ready, mode=%s, bind=%s, port=%s", config["mode"], bind, http_port)
            await uvicorn.Server(http_config).serve()


def main():
    parser = argparse.ArgumentParser(description="Opaque HajiSaki relay (production requires mTLS)")
    parser.add_argument("--config", required=True)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9443)
    parser.add_argument("--development", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    logging.getLogger("websockets").setLevel(logging.WARNING)
    try:
        asyncio.run(run(load(args.config, "relay", args.development), args.bind, args.port))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
