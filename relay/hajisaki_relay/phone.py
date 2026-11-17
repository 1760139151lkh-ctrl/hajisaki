from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
from pathlib import Path

import httpx

from websockets.legacy.client import connect
from websockets.exceptions import WebSocketException

from .config import https_origin, load, local_path, tls_context, websocket_url
from .protocol import Cipher, ID_RE, MAX_BODY, MAX_FRAME, ProtocolError, encode_json, new_id, now_ms


def write_private(path: Path, data: bytes):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


class PhoneTransport:
    """Reference phone-side transport; all gateway credentials stay inside AEAD."""
    def __init__(self, config: dict):
        self.config = config
        self.cipher = Cipher(config["channel"], config["master_key"])
        self.state = local_path(config, "state_dir", "state")

    def prepare(self, method: str, path: str, body: bytes = b"", headers: dict | None = None,
                request_id: str | None = None) -> tuple[str, bytes]:
        request_id = request_id or new_id()
        if not ID_RE.fullmatch(request_id):
            raise ValueError("Request ID must be 32 lowercase hex characters")
        pairing = self.config.get("gateway_pairing", {})
        if not pairing.get("token") or not pairing.get("device"):
            raise ValueError("Phone configuration needs securely provisioned gateway_pairing")
        merged = {"authorization": "Bearer " + pairing["token"], "x-haji-device": pairing["device"]}
        for key, value in (headers or {}).items():
            if key.lower() in {"authorization", "x-haji-device"}:
                raise ValueError("Pairing headers come from private configuration")
            merged[key.lower()] = value
        frame = self.cipher.seal("request", request_id, {"method": method, "path": path, "headers": merged}, body)
        write_private(self.state / "outbox" / (request_id + ".request.bin"), frame)
        return request_id, frame

    def retry_frame(self, request_id: str) -> bytes:
        if not ID_RE.fullmatch(request_id):
            raise ValueError("Invalid request ID")
        path = self.state / "outbox" / (request_id + ".request.bin")
        if path.stat().st_size > MAX_FRAME:
            raise ProtocolError("Saved request exceeds frame bound")
        header, metadata, body, _ = self.cipher.open(path.read_bytes(), "request", allow_expired=True)
        if header.request_id != request_id:
            raise ProtocolError("Stored request ID mismatch")
        # Fresh expiry and nonce, exact same authenticated ID and content. Journal prevents re-execution.
        renewed = self.cipher.seal("request", request_id, metadata, body)
        write_private(self.state / "outbox" / (request_id + ".renew." + str(now_ms()) + ".bin"), renewed)
        return renewed

    async def exchange(self, frame: bytes) -> tuple[dict, bytes, bytes]:
        if self.config.get("https_url"):
            return await self.exchange_http(frame)
        request, _, _, digest = self.cipher.open(frame, "request")
        async with connect(websocket_url(self.config), ssl=tls_context(self.config),
                           extra_headers={"Authorization": "Bearer " + self.config["channel_token"]},
                           max_size=MAX_FRAME, max_queue=2, compression=None, open_timeout=10,
                           close_timeout=5, ping_interval=15, ping_timeout=20) as websocket:
            await websocket.send(frame)
            async with asyncio.timeout(45):
                async for response in websocket:
                    if isinstance(response, str):
                        # Relay can only describe transport availability; never trust this as API data.
                        if len(response) <= 1024:
                            try:
                                message = json.loads(response)
                            except ValueError:
                                continue
                            if (isinstance(message, dict) and message.get("id") == request.request_id
                                    and isinstance(message.get("transport"), str)
                                    and message.get("transport") in {"host_offline", "busy", "peer_unavailable"}):
                                raise ConnectionError("Relay reports transport unavailable; preserve request ID for retry")
                        continue
                    header, metadata, body, _ = self.cipher.open(response, "response")
                    if header.request_id != request.request_id:
                        continue
                    if (set(metadata) != {"status", "headers", "request_digest", "outcome_uncertain"}
                            or metadata["request_digest"] != digest
                            or type(metadata["status"]) is not int or not 100 <= metadata["status"] <= 599
                            or not isinstance(metadata["headers"], dict)
                            or type(metadata["outcome_uncertain"]) is not bool):
                        raise ProtocolError("Response does not match this request")
                    return metadata, body, response
        raise ConnectionError("Channel closed before an authenticated response")

    async def exchange_http(self, frame: bytes) -> tuple[dict, bytes, bytes]:
        request, _, _, digest = self.cipher.open(frame, "request")
        endpoint = https_origin(self.config) + f"/v1/channels/{self.config['channel']}/request"
        async with httpx.AsyncClient(verify=tls_context(self.config) or True, trust_env=False,
                                      follow_redirects=False, timeout=httpx.Timeout(50, connect=10)) as client:
            async with asyncio.timeout(55):
                async with client.stream("POST", endpoint, content=frame,
                                         headers={"Authorization": "Bearer " + self.config["channel_token"],
                                                  "Content-Type": "application/octet-stream",
                                                  "Accept-Encoding": "identity"}) as response:
                    if response.status_code != 200:
                        raise ConnectionError("Relay transport response unavailable; preserve request ID")
                    if (response.headers.get("content-type", "").split(";", 1)[0] != "application/octet-stream"
                            or response.headers.get("content-encoding", "identity") != "identity"):
                        raise ProtocolError("Expected an opaque binary transport response")
                    buffer = bytearray()
                    async for chunk in response.aiter_raw():
                        if len(buffer) + len(chunk) > MAX_FRAME:
                            raise ProtocolError("Response frame exceeds bound")
                        buffer.extend(chunk)
        result = bytes(buffer)
        header, metadata, body, _ = self.cipher.open(result, "response")
        if (header.request_id != request.request_id
                or set(metadata) != {"status", "headers", "request_digest", "outcome_uncertain"}
                or metadata["request_digest"] != digest
                or type(metadata["status"]) is not int or not 100 <= metadata["status"] <= 599
                or not isinstance(metadata["headers"], dict) or type(metadata["outcome_uncertain"]) is not bool):
            raise ProtocolError("Response does not match this request")
        return metadata, body, result

    def save_result(self, request_id: str, meta: dict, body: bytes, frame: bytes) -> Path:
        directory = self.state / "responses" / request_id / hashlib.sha256(frame).hexdigest()[:16]
        directory.mkdir(parents=True, exist_ok=True)
        # Preserve separate authenticated outcomes (e.g. busy then retry); never overwrite evidence.
        for name, data in (("response.bin", frame), ("metadata.json", encode_json(meta)), ("body", body)):
            target = directory / name
            if target.exists():
                if target.read_bytes() != data:
                    raise ProtocolError("Saved response differs; inspect outcome before changing the request ID")
            else:
                write_private(target, data)
        return directory / "body"


async def command(args):
    transport = PhoneTransport(load(args.config, "phone", args.development))
    if args.action == "retry":
        request_id, frame = args.request_id, transport.retry_frame(args.request_id)
    else:
        body = b""
        if args.body_file:
            source = Path(args.body_file)
            if source.stat().st_size > MAX_BODY:
                raise ValueError("Request body must be at most 4 MiB")
            body = source.read_bytes()
        headers = {}
        if body or args.content_type:
            headers["content-type"] = args.content_type or ("application/octet-stream" if args.method == "PUT" else "application/json")
        if args.byte_range:
            headers["range"] = args.byte_range
        if args.if_range:
            headers["if-range"] = args.if_range
        request_id, frame = transport.prepare(args.method, args.path, body, headers, args.request_id)
    # Only the opaque ID is printed before I/O so interruption can be retried without duplicate effects.
    print(json.dumps({"request_id": request_id}), flush=True)
    meta, body, response = await transport.exchange(frame)
    output = transport.save_result(request_id, meta, body, response)
    print(json.dumps({"status": meta["status"], "outcome_uncertain": meta["outcome_uncertain"],
                      "bytes": len(body), "body_file": str(output)}, ensure_ascii=True))


def main():
    parser = argparse.ArgumentParser(description="Reference encrypted phone transport (no tokens in CLI arguments)")
    parser.add_argument("--config", required=True)
    parser.add_argument("--development", action="store_true")
    actions = parser.add_subparsers(dest="action", required=True)
    request = actions.add_parser("request")
    request.add_argument("method", choices=["GET", "POST", "PUT", "PATCH", "DELETE"])
    request.add_argument("path")
    request.add_argument("--request-id")
    request.add_argument("--body-file")
    request.add_argument("--content-type")
    request.add_argument("--range", dest="byte_range")
    request.add_argument("--if-range")
    retry = actions.add_parser("retry")
    retry.add_argument("request_id")
    args = parser.parse_args()
    try:
        asyncio.run(command(args))
    except (OSError, ValueError, TimeoutError, WebSocketException, httpx.HTTPError) as exc:
        # No URL/header/body dump; saved request remains available for reconciliation.
        parser.exit(1, type(exc).__name__ + ": request not completed; inspect saved request and channel availability.\n")


if __name__ == "__main__":
    main()
