"""Range-capable browser media without putting a bearer credential in a URL."""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import re
import secrets
import time
from urllib.parse import quote

import anyio
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse

from .devices import DevicePrincipal


@dataclass
class MediaSession:
    principal: DevicePrincipal
    artifact_id: str
    expires_at: float


class MediaSessions:
    def __init__(self, artifacts, devices):
        self.artifacts, self.devices = artifacts, devices
        self.sessions: dict[str, MediaSession] = {}

    @staticmethod
    def _digest(value: str) -> str:
        return hashlib.sha256(value.encode()).hexdigest()

    @staticmethod
    def _range(header: str | None, size: int) -> tuple[int, int, int]:
        if not header:
            return 0, max(-1, size - 1), 200
        match = re.fullmatch(r'bytes=(\d*)-(\d*)', header)
        if not match or (not match[1] and not match[2]) or not size:
            raise HTTPException(416, '这段原件的范围没有对齐。', headers={'Content-Range': f'bytes */{size}'})
        if not match[1]:
            length = int(match[2])
            start, end = max(0, size - length), size - 1
        else:
            start = int(match[1])
            end = min(int(match[2]) if match[2] else size - 1, size - 1)
        if start < 0 or start > end or start >= size:
            raise HTTPException(416, '这段原件的范围没有对齐。', headers={'Content-Range': f'bytes */{size}'})
        return start, end, 206

    def router(self, authenticate) -> APIRouter:
        router = APIRouter(prefix='/api')

        @router.post('/artifacts/{ident}/media-session')
        async def issue(ident: str, request: Request, principal: DevicePrincipal = Depends(authenticate)):
            artifact = self.artifacts.get(ident)
            if not artifact:
                raise HTTPException(404, '这份原件暂时没有找到。')
            stamp = time.time()
            self.sessions = {key: value for key, value in self.sessions.items() if value.expires_at > stamp}
            if len(self.sessions) >= 1024:
                raise HTTPException(429, '打开的原件有些多，请先合上几页。')
            secret = secrets.token_urlsafe(32)
            expires = stamp + 1800
            self.sessions[self._digest(secret)] = MediaSession(principal, ident, expires)
            # Cookie paths separate devices even when two tabs share one browser profile.
            path = f'/api/media/{principal.device_id}/{ident}'
            response = JSONResponse({'url': path, 'expires_at': expires}, headers={'Cache-Control': 'no-store'})
            response.set_cookie('haji_media', secret, max_age=1800, path=path,
                                httponly=True, secure=request.url.scheme == 'https', samesite='strict')
            return response

        @router.api_route('/media/{device}/{ident}', methods=['GET', 'HEAD'])
        async def read(device: str, ident: str, request: Request, download: bool = False):
            origin = request.headers.get('origin')
            if (request.headers.get('sec-fetch-site', 'same-origin') != 'same-origin'
                    or (origin and origin != str(request.base_url).rstrip('/'))):
                raise HTTPException(403, '请从琴房里的原件打开这一页。')
            session = self.sessions.get(self._digest(request.cookies.get('haji_media', '')))
            if (not session or session.expires_at <= time.time() or session.artifact_id != ident
                    or session.principal.device_id != device or not self.devices.is_active(session.principal)):
                raise HTTPException(401, '这一页的查看许可已结束，请重新打开原件。')
            artifact = self.artifacts.get(ident)
            if not artifact:
                raise HTTPException(404, '这份原件暂时没有找到。')
            path = self.artifacts.object_path(artifact['sha256'])
            if not path.is_file() or path.stat().st_size != artifact['size']:
                raise HTTPException(404, '这份原件还没有完整收好。')
            etag = '"' + artifact['sha256'] + '"'
            declared_mime = artifact['mime'].split(';', 1)[0].strip().lower()
            mime = declared_mime if re.fullmatch(r'[a-z0-9.+-]+/[a-z0-9.+-]+', declared_mime) else 'application/octet-stream'
            inline = not download and (mime.startswith(('audio/', 'video/')) or mime in {
                'application/pdf', 'image/png', 'image/jpeg', 'image/webp', 'image/gif', 'image/avif', 'image/bmp'})
            wanted = request.headers.get('range')
            if request.headers.get('if-range') not in {None, etag}:
                wanted = None
            start, end, status = self._range(wanted, artifact['size'])
            headers = {'Content-Length': str(end - start + 1), 'Accept-Ranges': 'bytes', 'ETag': etag,
                       'Cache-Control': 'private, no-store', 'X-Content-Type-Options': 'nosniff',
                       'Content-Disposition': ("inline" if inline else "attachment") + "; filename*=UTF-8''" + quote(artifact['name']),
                       'Content-Security-Policy': "sandbox; default-src 'none'"}
            if status == 206:
                headers['Content-Range'] = f'bytes {start}-{end}/{artifact["size"]}'
            if request.method == 'HEAD':
                return Response(status_code=status, media_type=mime, headers=headers)

            async def chunks():
                async with await anyio.open_file(path, 'rb') as source:
                    await source.seek(start)
                    remaining = end - start + 1
                    while remaining:
                        if not self.devices.is_active(session.principal):
                            return
                        block = await source.read(min(256 * 1024, remaining))
                        if not block:
                            return
                        remaining -= len(block)
                        yield block

            return StreamingResponse(chunks(), status_code=status, media_type=mime, headers=headers)

        return router
